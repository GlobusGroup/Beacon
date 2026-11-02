import BeaconTunnel
import Foundation
import NIOCore

/// One Mac's tunnel: who it is, and the hostnames it currently answers for.
final class RelaySession {
    let label: String
    let mux: TunnelMux
    let remote: String
    /// Hostname → share, for everything this session currently holds.
    var routes: [String: TunnelShare] = [:]
    /// The last set the Mac asked for, so it can be re-answered if another
    /// session takes a hostname away.
    var requested: [TunnelShare] = []

    init(label: String, mux: TunnelMux, remote: String) {
        self.label = label
        self.mux = mux
        self.remote = remote
    }
}

/// Which hostname belongs to which tunnel.
///
/// The relay runs a single event loop, and this is only touched from it, so
/// there is no locking anywhere in the relay.
final class RelayHub {
    struct Route {
        let session: RelaySession
        let share: TunnelShare
    }

    private let config: RelayConfig
    private var routes: [String: Route] = [:]
    private var sessions: [ObjectIdentifier: RelaySession] = [:]

    init(config: RelayConfig) {
        self.config = config
    }

    func route(for host: String) -> Route? { routes[host] }

    var sessionCount: Int { sessions.count }
    var routeCount: Int { routes.count }

    func hostname(share: String, label: String) -> String {
        "\(share)-\(label).\(config.domain)"
    }

    func publicURL(for host: String) -> String {
        let defaultPort = config.publicScheme == "https" ? 443 : 80
        let port = config.publicPort == defaultPort ? "" : ":\(config.publicPort)"
        return "\(config.publicScheme)://\(host)\(port)"
    }

    func isConnected(label: String) -> Bool {
        sessions.values.contains { $0.label == label }
    }

    func publicURLs(label: String) -> [String] {
        sessions.values.filter { $0.label == label }
            .flatMap(\.routes.keys)
            .filter { routes[$0]?.session.label == label }
            .sorted()
            .map(publicURL(for:))
    }

    /// Drops every tunnel opened with a label's token, once it's revoked.
    func disconnect(label: String) {
        for session in sessions.values where session.label == label {
            session.mux.channel.close(promise: nil)
        }
    }

    // MARK: - Sessions

    func attach(_ session: RelaySession) {
        sessions[ObjectIdentifier(session)] = session
        RelayLog.info("\(session.label) connected from \(session.remote).")

        session.mux.onText = { [weak self, weak session] text in
            guard let self, let session else { return }
            guard let message = try? JSONDecoder().decode(TunnelClientMessage.self, from: Data(text.utf8)) else {
                RelayLog.warn("\(session.label) sent an unreadable control message.")
                return
            }
            self.update(session, shares: message.shares)
        }
        session.mux.onClose = { [weak self, weak session] in
            guard let self, let session else { return }
            self.detach(session)
        }
    }

    private func detach(_ session: RelaySession) {
        sessions[ObjectIdentifier(session)] = nil
        for host in session.routes.keys where routes[host]?.session === session {
            routes[host] = nil
        }
        session.routes = [:]
        RelayLog.info("\(session.label) disconnected.")
    }

    /// Replaces everything a session shares with `shares`, and tells it the outcome.
    private func update(_ session: RelaySession, shares: [TunnelShare]) {
        session.requested = shares
        var wanted: [String: TunnelShare] = [:]
        var statuses: [TunnelShareStatus] = []
        var displaced: [RelaySession] = []

        for share in shares {
            let name = share.name.lowercased()
            guard Hostnames.isLabel(name) else {
                statuses.append(TunnelShareStatus(name: share.name, error: "'\(share.name)' isn't a usable hostname label."))
                continue
            }
            let label = "\(name)-\(session.label)"
            guard label.count <= 63 else {
                statuses.append(TunnelShareStatus(name: share.name, error: "\(label) is longer than the 63 characters DNS allows."))
                continue
            }
            let host = "\(label).\(config.domain)"

            if let holder = routes[host]?.session, holder !== session {
                // The same person reconnecting from a second Mac, or from this
                // one before the old tunnel has timed out: the newest wins.
                // Someone else's hostname that merely spells the same, though,
                // is never taken over.
                guard holder.label == session.label else {
                    statuses.append(TunnelShareStatus(name: share.name, error: "\(host) is already in use by someone else."))
                    continue
                }
                holder.routes[host] = nil
                displaced.append(holder)
            }

            wanted[host] = TunnelShare(name: name, password: share.password.flatMap { $0.isEmpty ? nil : $0 })
            statuses.append(TunnelShareStatus(name: share.name, url: publicURL(for: host)))
        }

        for host in session.routes.keys where wanted[host] == nil && routes[host]?.session === session {
            routes[host] = nil
        }
        for (host, share) in wanted {
            routes[host] = Route(session: session, share: share)
        }
        session.routes = wanted

        let summary = wanted.keys.sorted().joined(separator: " ")
        RelayLog.info("\(session.label) shares: \(summary.isEmpty ? "nothing" : summary)")
        session.mux.sendJSON(TunnelRelayMessage(label: session.label, shares: statuses))

        for holder in displaced where holder !== session {
            reannounce(holder)
        }
    }

    /// Tells a session which of its shares it lost to a newer connection.
    private func reannounce(_ session: RelaySession) {
        let statuses = session.requested.map { share -> TunnelShareStatus in
            let host = hostname(share: share.name.lowercased(), label: session.label)
            if session.routes[host] != nil {
                return TunnelShareStatus(name: share.name, url: publicURL(for: host))
            }
            return TunnelShareStatus(name: share.name, error: "Shared from another connection with the same token.")
        }
        session.mux.sendJSON(TunnelRelayMessage(label: session.label, shares: statuses))
    }
}

enum RelayLog {
    nonisolated(unsafe) static var verbose = false
    private static let lock = NSLock()

    static func debug(_ message: @autoclosure () -> String) {
        guard verbose else { return }
        emit("debug", message())
    }

    static func info(_ message: @autoclosure () -> String) { emit("info", message()) }
    static func warn(_ message: @autoclosure () -> String) { emit("warn", message()) }
    static func error(_ message: @autoclosure () -> String) { emit("error", message()) }

    private static func emit(_ level: String, _ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        lock.lock()
        FileHandle.standardError.write(Data("\(stamp) [\(level)] \(message)\n".utf8))
        lock.unlock()
    }
}
