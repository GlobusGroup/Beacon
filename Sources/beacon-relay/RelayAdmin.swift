import BeaconTunnel
import Foundation

// The relay's admin API, on the apex domain, for tokens whose label is in
// BEACON_ADMINS or that were created as admin tokens:
//
//   GET    /_admin/tokens          → {"tokens": [RelayAdminToken]}
//   POST   /_admin/tokens          ← RelayAdminCreate
//                                  → 201 {"token": RelayAdminToken, "secret": "…"}
//   DELETE /_admin/tokens/<label>  → {"ok": true}
//
// Every request carries `Authorization: Bearer <token>`. Failures answer
// {"error": {"code": "…", "message": "…"}}. Beacon's daemon is the client; the
// matching types on its side are in Beacon/Shared/Relay.swift.

struct RelayAdminToken: Codable {
    enum Source: String, Codable {
        /// From BEACON_TOKENS. Can only be changed by redeploying.
        case environment
        /// Created through this API.
        case relay
    }

    var label: String
    var note: String?
    var admin: Bool
    var source: Source
    var createdAt: Date?
    var createdBy: String?
    /// A Mac holding this token has a tunnel open right now.
    var connected: Bool
    /// Public URLs it's serving right now.
    var shares: [String]
}

struct RelayAdminCreate: Codable {
    var label: String
    var note: String?
    var admin: Bool?
}

enum RelayAdmin {
    static let prefix = "/_admin/"
    /// Bodies are a label and a note; anything bigger is a mistake.
    static let maxBody = 16 * 1024

    private struct Created: Encodable {
        var token: RelayAdminToken
        var secret: String
    }

    private struct Listing: Encodable {
        var tokens: [RelayAdminToken]
    }

    private struct Failure: Encodable {
        struct Detail: Encodable { var code: String; var message: String }
        var error: Detail
    }

    /// Answers one admin request with a complete HTTP response.
    static func handle(
        method: String, path: String, bearer: String?, body: Data,
        tokens: RelayTokens, hub: RelayHub
    ) -> String {
        guard let bearer, let caller = tokens.identity(forToken: bearer) else {
            return failure("401 Unauthorized", "bad_token", "That token isn't one this relay accepts.")
        }
        guard caller.admin else {
            return failure("403 Forbidden", "not_admin", "The token labelled '\(caller.label)' isn't an admin token.")
        }

        let parts = path.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        do {
            switch (method, parts.count, parts.first) {
            case ("GET", 1, "tokens"):
                return json("200 OK", Listing(tokens: tokens.list(hub: hub)))

            case ("POST", 1, "tokens"):
                guard let request = try? decoder.decode(RelayAdminCreate.self, from: body) else {
                    return failure("400 Bad Request", "bad_body", #"Send JSON like {"label":"sam","note":"Sam's laptop"}."#)
                }
                let (record, secret) = try tokens.create(request, by: caller.label)
                RelayLog.info("\(caller.label) created a\(record.admin ? "n admin" : "") token for '\(record.label)'.")
                let info = tokens.list(hub: hub).first { $0.label == record.label }!
                return json("201 Created", Created(token: info, secret: secret))

            case ("DELETE", 2, "tokens"):
                let label = parts[1].lowercased()
                try tokens.revoke(label, by: caller.label)
                hub.disconnect(label: label)
                RelayLog.info("\(caller.label) revoked the token for '\(label)'.")
                return json("200 OK", ["ok": true])

            default:
                return failure("404 Not Found", "unknown_endpoint", "There's no \(method) \(path) here.")
            }
        } catch let problem as RelayTokens.Problem {
            return failure(problem.status, problem.code, problem.message)
        } catch {
            return failure("500 Internal Server Error", "internal", "\(error)")
        }
    }

    static func failure(_ status: String, _ code: String, _ message: String) -> String {
        json(status, Failure(error: .init(code: code, message: message)))
    }

    private static func json<T: Encodable>(_ status: String, _ value: T) -> String {
        let body = (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return RelayPages.json(status, body)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder = JSONDecoder()
}
