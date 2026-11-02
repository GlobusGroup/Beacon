import BeaconKit
import Foundation

/// Calls the relay's admin API (Sources/beacon-relay/RelayAdmin.swift) with
/// the token from relay.json. The daemon makes these calls for the app and the
/// CLI, so the token never has to leave the root-only file.
///
/// Blocking: call it off the event loops.
struct RelayAdminClient {
    let relay: String
    let token: String
    let base: URL

    /// Under the client's 10 second socket timeout, so a slow relay is
    /// reported as such rather than as the daemon not answering.
    private static let timeout: TimeInterval = 8

    init(relay: String, token: String, target: RelayTarget) {
        self.relay = relay
        self.token = token
        var components = URLComponents()
        components.scheme = target.tls ? "https" : "http"
        components.host = target.host
        components.port = target.port == (target.tls ? 443 : 80) ? nil : target.port
        components.path = "/_admin/"
        base = components.url!
    }

    private struct Listing: Decodable { var tokens: [RelayToken] }
    private struct Created: Decodable { var token: RelayToken; var secret: String }
    private struct Failure: Decodable {
        struct Detail: Decodable { var code: String; var message: String }
        var error: Detail
    }

    func list() throws -> [RelayToken] {
        try decode(Listing.self, from: send("GET", "tokens")).tokens
    }

    func create(_ spec: RelayTokenSpec) throws -> RelayInvite {
        let created = try decode(Created.self, from: send("POST", "tokens", body: BeaconJSON.encoder.encode(spec)))
        return RelayInvite(relay: relay, token: created.secret, label: created.token.label, note: created.token.note)
    }

    func revoke(_ label: String) throws {
        _ = try send("DELETE", "tokens/\(label)")
    }

    // MARK: -

    private func send(_ method: String, _ path: String, body: Data? = nil) throws -> Data {
        var request = URLRequest(url: base.appendingPathComponent(path), timeoutInterval: Self.timeout)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("beacond/\(BeaconPaths.version)", forHTTPHeaderField: "User-Agent")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var outcome: (Data?, URLResponse?, Error?)
        URLSession.shared.dataTask(with: request) { data, response, error in
            outcome = (data, response, error)
            done.signal()
        }.resume()
        done.wait()

        if let error = outcome.2 {
            throw BeaconClientError(code: "relay_unreachable", message: "Couldn't reach the relay: \(error.localizedDescription)")
        }
        guard let response = outcome.1 as? HTTPURLResponse, let data = outcome.0 else {
            throw BeaconClientError(code: "relay_unreachable", message: "The relay didn't answer.")
        }
        // A relay from before the admin API answers with its HTML home page.
        guard response.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("application/json") == true else {
            throw BeaconClientError(code: "relay_no_admin", message: "This relay is too old to manage tokens. Update it to the latest image.")
        }
        guard (200..<300).contains(response.statusCode) else {
            let failure = try? BeaconJSON.decoder.decode(Failure.self, from: data)
            throw BeaconClientError(
                code: failure.map { "relay_" + $0.error.code } ?? "relay_error",
                message: failure?.error.message ?? "The relay answered \(response.statusCode)."
            )
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try BeaconJSON.decoder.decode(type, from: data)
        } catch {
            throw BeaconClientError(code: "bad_relay_response", message: "The relay sent something unreadable.")
        }
    }
}
