import BeaconKit
import Foundation

/// The hostname lookup the proxy consults on every connection.
///
/// Read far more often than it is written, and read from several event loops at
/// once, so writes swap a whole immutable dictionary rather than mutating.
final class RouteTable: @unchecked Sendable {
    private let lock = NSLock()
    private var routes: [String: Site] = [:]
    private var siteList: [Site] = []

    func update(from snapshot: RegistrySnapshot) {
        let newRoutes = snapshot.routes
        lock.lock()
        routes = newRoutes
        siteList = snapshot.sites
        lock.unlock()
    }

    /// Resolves a Host header to a project.
    ///
    /// Falls back to the parent domain so `api.myproject.test` and
    /// `anything.myproject.test` reach `myproject` without being registered —
    /// the DNS side already answers for them.
    func site(forHost rawHost: String) -> Site? {
        var host = rawHost.lowercased()
        if host.hasPrefix("[") {
            // IPv6 literal: [::1]:8080
            if let close = host.firstIndex(of: "]") {
                host = String(host[host.index(after: host.startIndex)..<close])
            }
        } else if let colon = host.lastIndex(of: ":") {
            host = String(host[..<colon])
        }
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "."))

        lock.lock()
        defer { lock.unlock() }

        if let exact = routes[host] { return exact }

        var parts = host.split(separator: ".")
        while parts.count > 2 {
            parts.removeFirst()
            if let parent = routes[parts.joined(separator: ".")] { return parent }
        }
        return nil
    }

    var sites: [Site] {
        lock.lock()
        defer { lock.unlock() }
        return siteList
    }
}
