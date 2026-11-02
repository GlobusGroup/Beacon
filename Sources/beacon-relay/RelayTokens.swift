import BeaconTunnel
import Crypto
import Foundation

/// Who a presented token belongs to.
struct RelayIdentity {
    var label: String
    var admin: Bool
}

/// Every token the relay accepts: the fixed ones from `BEACON_TOKENS`, and the
/// ones admins have created since, which live in `<data dir>/tokens.json`.
///
/// Created tokens are stored as SHA-256 digests. The relay only ever needs to
/// recognise a token, so a leaked data volume doesn't hand out working ones.
///
/// Only touched from the relay's single event loop, like `RelayHub`.
final class RelayTokens {
    struct Record: Codable {
        var label: String
        /// Who the token is for, in the admin's words.
        var note: String?
        var admin: Bool
        var createdAt: Date
        var createdBy: String
        /// Hex SHA-256 of the token.
        var digest: String
    }

    private struct File: Codable {
        var version = 1
        var tokens: [Record]
    }

    struct Problem: Error {
        var status: String
        var code: String
        var message: String
    }

    private let config: RelayConfig
    private let path: String
    private var records: [Record]

    init(config: RelayConfig) throws {
        self.config = config
        self.path = config.dataDir + "/tokens.json"
        records = try Self.load(path)

        let fixed = Set(config.tokens.map(\.label))
        for record in records where fixed.contains(record.label) {
            RelayLog.warn("'\(record.label)' is in both BEACON_TOKENS and \(path); the BEACON_TOKENS one wins.")
        }
        records.removeAll { fixed.contains($0.label) }
    }

    var count: Int { config.tokens.count + records.count }

    /// Every token is checked, fixed and created, so the time taken doesn't
    /// reveal which, if any, came close.
    func identity(forToken presented: String) -> RelayIdentity? {
        var match: RelayIdentity?
        for entry in config.tokens where constantTimeEquals(entry.token, presented) {
            match = RelayIdentity(label: entry.label, admin: config.admins.contains(entry.label))
        }
        let digest = Self.digest(presented)
        for record in records where constantTimeEquals(record.digest, digest) {
            match = match ?? RelayIdentity(label: record.label, admin: record.admin)
        }
        return match
    }

    // MARK: - Admin

    func list(hub: RelayHub) -> [RelayAdminToken] {
        let fixed = config.tokens.map { entry in
            RelayAdminToken(
                label: entry.label, note: nil, admin: config.admins.contains(entry.label),
                source: .environment, createdAt: nil, createdBy: nil,
                connected: hub.isConnected(label: entry.label), shares: hub.publicURLs(label: entry.label)
            )
        }
        let created = records.map { record in
            RelayAdminToken(
                label: record.label, note: record.note, admin: record.admin,
                source: .relay, createdAt: record.createdAt, createdBy: record.createdBy,
                connected: hub.isConnected(label: record.label), shares: hub.publicURLs(label: record.label)
            )
        }
        return (fixed + created).sorted { $0.label < $1.label }
    }

    /// Makes a token and saves it. The token itself is returned this once and
    /// never again.
    func create(_ request: RelayAdminCreate, by creator: String) throws -> (Record, String) {
        let label = request.label.trimmingCharacters(in: .whitespaces).lowercased()
        guard Hostnames.isLabel(label) else {
            throw Problem(status: "400 Bad Request", code: "bad_label",
                          message: "'\(label)' can't be a label. Use lowercase letters, digits and single hyphens.")
        }
        guard !config.tokens.contains(where: { $0.label == label }), !records.contains(where: { $0.label == label }) else {
            throw Problem(status: "409 Conflict", code: "label_taken", message: "There's already a token labelled '\(label)'.")
        }

        let token = Self.generate()
        let note = request.note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let record = Record(
            label: label, note: (note ?? "").isEmpty ? nil : String(note!.prefix(200)),
            admin: request.admin ?? false, createdAt: Date(), createdBy: creator, digest: Self.digest(token)
        )
        try save(records + [record])
        records.append(record)
        return (record, token)
    }

    func revoke(_ label: String, by revoker: String) throws {
        if config.tokens.contains(where: { $0.label == label }) {
            throw Problem(status: "409 Conflict", code: "fixed_token",
                          message: "'\(label)' is set in BEACON_TOKENS. Take it out there and redeploy to revoke it.")
        }
        guard records.contains(where: { $0.label == label }) else {
            throw Problem(status: "404 Not Found", code: "unknown_label", message: "There's no token labelled '\(label)'.")
        }
        guard label != revoker else {
            throw Problem(status: "409 Conflict", code: "own_token", message: "You can't revoke the token you're using.")
        }
        let remaining = records.filter { $0.label != label }
        try save(remaining)
        records = remaining
    }

    // MARK: - Storage

    private static func load(_ path: String) throws -> [Record] {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        do {
            return try decoder.decode(File.self, from: data).tokens
        } catch {
            throw RelayConfig.Problem.invalid("\(path) couldn't be read: \(error). Fix or remove it.")
        }
    }

    private func save(_ records: [Record]) throws {
        do {
            let data = try encoder.encode(File(tokens: records))
            try FileManager.default.createDirectory(atPath: config.dataDir, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            chmod(path, 0o600)
        } catch {
            RelayLog.error("Couldn't save \(path): \(error)")
            throw Problem(status: "500 Internal Server Error", code: "save_failed",
                          message: "The relay couldn't save its tokens to \(config.dataDir). Is it a writable volume?")
        }
    }

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// 24 random bytes as hex, the same shape as `openssl rand -hex 24`.
    private static func generate() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<24).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
    }

    private static func digest(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
