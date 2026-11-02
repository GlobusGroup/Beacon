import BeaconKit
import Foundation

/// The source of truth for which project owns which port and domain.
///
/// Every mutation persists immediately — the daemon can be killed at any moment
/// and a project must never come back with a different port.
final class Registry: @unchecked Sendable {
    private let lock = NSLock()
    private var sitesByName: [String: Site] = [:]
    private var config: BeaconConfig = .default

    /// Ports the daemon itself listens on (HTTP, HTTPS, DNS). No project may
    /// claim one: its dev server could never bind it, and the domain would
    /// route back into the proxy.
    var daemonPorts: Set<Int> = []

    /// Called after any change that affects routing or certificates.
    var onChange: (@Sendable (RegistrySnapshot) -> Void)?

    init() {
        load()
    }

    // MARK: - Reading

    var snapshot: RegistrySnapshot {
        lock.lock()
        defer { lock.unlock() }
        return makeSnapshotLocked()
    }

    var currentConfig: BeaconConfig {
        lock.lock()
        defer { lock.unlock() }
        return config
    }

    var allSites: [Site] {
        lock.lock()
        defer { lock.unlock() }
        return sitesByName.values.sorted { $0.name < $1.name }
    }

    func site(named name: String) -> Site? {
        lock.lock()
        defer { lock.unlock() }
        return sitesByName[Site.slug(name)]
    }

    // MARK: - Writing

    func updateConfig(_ newConfig: BeaconConfig) throws -> BeaconConfig {
        var sanitised = newConfig
        sanitised.tlds = newConfig.tlds
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased() }
            .filter { !$0.isEmpty }
        if sanitised.tlds.isEmpty { sanitised.tlds = BeaconConfig.default.tlds }
        guard sanitised.portRange.count >= 1 else {
            throw BeaconClientError(code: "bad_config", message: "The port range is empty.")
        }

        let changed = withLock { () -> RegistrySnapshot in
            config = sanitised
            persistConfigLocked()
            return makeSnapshotLocked()
        }

        onChange?(changed)
        return sanitised
    }

    func register(_ spec: RegisterSpec) throws -> Site {
        let name = Site.slug(spec.name)
        guard !name.isEmpty else {
            throw BeaconClientError(
                code: "bad_name",
                message: "'\(spec.name)' doesn't contain any letters or digits to build a name from."
            )
        }

        let result = try withLock { () -> (site: Site, snapshot: RegistrySnapshot) in
            let existing = sitesByName[name]
            let domain = try resolveDomainLocked(spec: spec, name: name, existing: existing)

            let aliases = (spec.aliases ?? existing?.aliases ?? [])
                .map { normaliseAliasLocked($0) }
                .filter { $0.caseInsensitiveCompare(domain) != .orderedSame }

            // No other project may already answer on any name this one claims.
            let claimed = Set(([domain] + aliases).map { $0.lowercased() })
            for (otherName, other) in sitesByName where otherName != name {
                let clash = other.allDomains.first { claimed.contains($0.lowercased()) }
                if let clash {
                    throw BeaconClientError(
                        code: "domain_taken",
                        message: "\(clash) already belongs to '\(otherName)' on port \(other.port)."
                    )
                }
            }

            let port = try resolvePortLocked(spec: spec, name: name, existing: existing)

            var run = existing?.run
            if let requested = spec.run?.trimmingCharacters(in: .whitespacesAndNewlines) {
                run = (requested.isEmpty || requested == "auto") ? nil : .custom(requested)
            }

            let site = Site(
                name: name,
                domain: domain,
                port: port,
                path: spec.path ?? existing?.path,
                aliases: Array(Set(aliases)).sorted(),
                secure: spec.secure ?? existing?.secure ?? config.defaultSecure,
                run: run,
                createdAt: existing?.createdAt ?? Date()
            )
            sitesByName[name] = site
            persistSitesLocked()
            return (site, makeSnapshotLocked())
        }

        onChange?(result.snapshot)
        return result.site
    }

    func unregister(name rawName: String) throws -> Site {
        let name = Site.slug(rawName)
        let result = try withLock { () -> (site: Site, snapshot: RegistrySnapshot) in
            guard let site = sitesByName.removeValue(forKey: name) else {
                throw BeaconClientError(code: "unknown_site", message: "No project named '\(rawName)'.")
            }
            persistSitesLocked()
            return (site, makeSnapshotLocked())
        }

        onChange?(result.snapshot)
        return result.site
    }

    /// Always releases the lock, including on the throwing paths — a leaked lock
    /// here wedges every later request.
    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    // MARK: - Domain and port resolution (callers hold the lock)

    private func resolveDomainLocked(spec: RegisterSpec, name: String, existing: Site?) throws -> String {
        guard let requested = spec.domain?.trimmingCharacters(in: .whitespaces), !requested.isEmpty else {
            return existing?.domain ?? "\(name).\(config.primaryTLD)"
        }
        let domain = normaliseDomainLocked(requested)
        let tld = Site.tld(of: domain)
        guard config.tlds.contains(tld) else {
            let managed = config.tlds.map { ".\($0)" }.joined(separator: ", ")
            throw BeaconClientError(
                code: "unmanaged_tld",
                message: """
                Beacon doesn't route .\(tld). It currently owns \(managed). \
                Add it with `sudo beacon config --add-tld \(tld)`.
                """
            )
        }
        return domain
    }

    /// Bare names get the primary TLD appended, so `--domain shop` means `shop.test`.
    private func normaliseDomainLocked(_ raw: String) -> String {
        var domain = raw.lowercased()
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if let range = domain.range(of: "://") {
            domain = String(domain[range.upperBound...])
        }
        if let slash = domain.firstIndex(of: "/") {
            domain = String(domain[..<slash])
        }
        if !domain.contains(".") {
            domain += ".\(config.primaryTLD)"
        }
        return domain
    }

    /// Aliases are usually subdomains someone typed loosely — `api.blog`, `admin`.
    /// Anything not already under a managed TLD gets the primary one appended,
    /// because an alias Beacon can't resolve is just a silent dead end.
    private func normaliseAliasLocked(_ raw: String) -> String {
        let domain = normaliseDomainLocked(raw)
        guard config.tlds.contains(Site.tld(of: domain)) else {
            return domain + "." + config.primaryTLD
        }
        return domain
    }

    private func resolvePortLocked(spec: RegisterSpec, name: String, existing: Site?) throws -> Int {
        let takenByOthers = Set(
            sitesByName.filter { $0.key != name }.values.map(\.port)
        )

        if let requested = spec.port {
            guard (1...65535).contains(requested) else {
                throw BeaconClientError(
                    code: "bad_port",
                    message: "\(requested) isn't a usable port. Pick one between 1 and 65535.",
                    details: ["port": String(requested)]
                )
            }
            if daemonPorts.contains(requested) {
                let suggestion = suggestPortLocked(near: requested, avoiding: takenByOthers)
                throw BeaconClientError(
                    code: "port_reserved_by_beacon",
                    message: """
                    Port \(requested) is one Beacon itself listens on, so no project can use it.\
                    \(suggestionSentence(suggestion))
                    """,
                    details: portDetails(requested: requested, suggestion: suggestion)
                )
            }
            if let owner = sitesByName.values.first(where: { $0.name != name && $0.port == requested }) {
                let suggestion = suggestPortLocked(near: requested, avoiding: takenByOthers)
                var details = portDetails(requested: requested, suggestion: suggestion)
                details["owner"] = owner.name
                details["ownerDomain"] = owner.domain
                throw BeaconClientError(
                    code: "port_taken",
                    message: """
                    Port \(requested) is already reserved for '\(owner.name)' (\(owner.domain)).\
                    \(suggestionSentence(suggestion))
                    """,
                    details: details
                )
            }
            return requested
        }

        // The whole point of the registry: the same project keeps its port.
        if let existing, spec.reassign != true, !takenByOthers.contains(existing.port) {
            return existing.port
        }

        guard let port = PortAllocator.allocate(
            in: config.portRange,
            avoiding: takenByOthers.union(existing.map { [$0.port] } ?? [])
        ) else {
            throw BeaconClientError(
                code: "no_ports",
                message: """
                No free port left between \(config.portRange.lowerBound) and \
                \(config.portRange.upperBound). Widen the range with \
                `sudo beacon config --port-range <start>-<end>`.
                """
            )
        }
        return port
    }

    /// The closest port at or above `port` that no project holds, Beacon
    /// doesn't use, and nothing is listening on. Falls back to the configured
    /// range when everything above is spoken for.
    private func suggestPortLocked(near port: Int, avoiding taken: Set<Int>) -> Int? {
        let avoid = taken.union(daemonPorts)
        let upper = min(65535, max(port, 1024) + 1000)
        if port <= upper,
           let nearby = PortAllocator.allocate(in: max(port, 1024)...upper, avoiding: avoid) {
            return nearby
        }
        return PortAllocator.allocate(in: config.portRange, avoiding: avoid)
    }

    private func suggestionSentence(_ suggestion: Int?) -> String {
        guard let suggestion else {
            return " Leave the port out and Beacon will choose a free one."
        }
        return " Port \(suggestion) is free. Ask for that one, or leave the port out and Beacon will choose."
    }

    private func portDetails(requested: Int, suggestion: Int?) -> [String: String] {
        var details = ["port": String(requested)]
        if let suggestion { details["suggestedPort"] = String(suggestion) }
        return details
    }

    // MARK: - Persistence

    private func makeSnapshotLocked() -> RegistrySnapshot {
        RegistrySnapshot(
            sites: sitesByName.values.sorted { $0.name < $1.name },
            config: config
        )
    }

    private func load() {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: BeaconPaths.supportDir, withIntermediateDirectories: true)

        if let data = fm.contents(atPath: BeaconPaths.configFile),
           let decoded = try? BeaconJSON.decoder.decode(BeaconConfig.self, from: data) {
            config = decoded
        } else {
            persistConfigLocked()
        }

        if let data = fm.contents(atPath: BeaconPaths.sitesFile),
           let decoded = try? BeaconJSON.decoder.decode([Site].self, from: data) {
            sitesByName = Dictionary(uniqueKeysWithValues: decoded.map { ($0.name, $0) })
            Log.info("Loaded \(decoded.count) site(s).")
        }
    }

    private func persistSitesLocked() {
        let sites = sitesByName.values.sorted { $0.name < $1.name }
        write(try? BeaconJSON.prettyEncoder.encode(sites), to: BeaconPaths.sitesFile)
    }

    private func persistConfigLocked() {
        write(try? BeaconJSON.prettyEncoder.encode(config), to: BeaconPaths.configFile)
    }

    private func write(_ data: Data?, to path: String) {
        guard let data else { return }
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            Log.error("Couldn't write \(path): \(error.localizedDescription)")
        }
    }
}

struct RegistrySnapshot: Sendable {
    var sites: [Site]
    var config: BeaconConfig

    /// Hostname (lowercased) to port, covering aliases too.
    var routes: [String: Site] {
        var map: [String: Site] = [:]
        for site in sites {
            for domain in site.allDomains {
                map[domain.lowercased()] = site
            }
        }
        return map
    }
}
