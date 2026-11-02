import AppKit
import Combine
import Foundation
import SwiftUI

/// What happened when the user went through a permission step. Dismissing a
/// macOS prompt is a choice, so it gets its own case rather than an error.
enum ActionOutcome: Equatable {
    case succeeded
    case cancelled
    case failed(String)
}

/// A part of Settings to point the user at when something else opens it.
enum SettingsHighlight: Hashable {
    /// The background service row, with its Update button.
    case service
}

/// The things that make macOS ask the user for permission. Each one is
/// introduced by `PermissionExplainer` before the system prompt appears.
enum PrivilegedAction: String, Identifiable {
    case install
    /// Reinstalling the service from this copy of the app, after Sparkle has
    /// updated the app and left the older service running.
    case update
    case trust
    case uninstall

    var id: String { rawValue }
}

/// The menu bar app's view of the daemon.
///
/// Every call into `BeaconClient` blocks on a socket, so all of them run off
/// the main actor and publish their results back onto it.
@MainActor
final class BeaconModel: ObservableObject {
    enum Activity: Equatable {
        case installing, trusting, restarting, uninstalling, saving
    }

    @Published private(set) var sites: [Site] = []
    @Published private(set) var running: Set<Int> = []
    @Published private(set) var status: DaemonStatus?
    @Published private(set) var config: BeaconConfig = .default
    @Published private(set) var caTrusted = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var activity: Activity?
    /// The last thing that went wrong outside a setup step, shown in the menu.
    @Published var notice: String?
    /// Starts asked for from the menu, by project name, while they're under
    /// way and afterwards, so a failure or a Stop button stays visible.
    @Published private(set) var runs: [String: RunStatus] = [:]
    /// Projects Beacon knows how to start.
    @Published private(set) var runnable: Set<String> = []
    /// Set just before opening Settings from elsewhere, so Settings scrolls
    /// to that row and tints it. Settings clears it after a moment.
    @Published var settingsHighlight: SettingsHighlight?
    /// The tunnel to the relay and what's shared through it. Nil while the
    /// daemon is down, or when it predates sharing.
    @Published private(set) var relay: RelayStatus?

    private let client = BeaconClient()
    private var timer: Timer?
    /// Faster than the main poll, and only alive while something is starting.
    private var runTimer: Timer?

    var isRunning: Bool { status != nil }

    /// Every managed TLD has its resolver file in place.
    var resolverActive: Bool {
        guard let status else { return false }
        return status.tlds.allSatisfy { status.resolversInstalled.contains($0) }
    }

    var needsSetup: Bool { !isRunning || !caTrusted }

    /// The running service isn't the one this app carries, usually because
    /// Sparkle updated the app. Different rather than older: a downgraded app
    /// should put its own service back too.
    var serviceOutdated: Bool {
        guard let status else { return false }
        return status.version != BeaconPaths.version
    }

    init() {
        Task { await reload() }
        // Cheap enough to poll: a status call and one bind() per project.
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.reload() }
        }
    }

    deinit { timer?.invalidate() }

    #if DEBUG
    /// A model frozen in a given state, for previews and snapshot renders.
    /// It never talks to the daemon.
    init(
        previewRunning: Bool,
        trusted: Bool,
        serviceVersion: String = BeaconPaths.version,
        sites: [Site] = [],
        onlinePorts: Set<Int> = [],
        activity: Activity? = nil,
        notice: String? = nil,
        runs: [String: RunStatus] = [:],
        runnable: Set<String> = [],
        relay: RelayStatus? = nil,
        settingsHighlight: SettingsHighlight? = nil
    ) {
        self.status = previewRunning
            ? DaemonStatus(
                version: serviceVersion, pid: 4242, httpPort: 80, httpsPort: 443, dnsPort: 53535,
                tlds: ["test"], resolversInstalled: ["test"], siteCount: sites.count,
                startedAt: Date().addingTimeInterval(-3600)
              )
            : nil
        self.caTrusted = trusted
        self.sites = sites
        self.running = onlinePorts
        self.activity = activity
        self.notice = notice
        self.runs = runs
        self.runnable = runnable
        self.relay = relay
        self.settingsHighlight = settingsHighlight
        self.hasLoaded = true
    }
    #endif

    /// Answered synchronously at launch, so the setup window can be presented
    /// as the app opens rather than flashing up a moment later.
    nonisolated static func setupNeededNow() -> Bool {
        !BeaconClient().daemonIsReachable || !BeaconInstaller.isCATrusted()
    }

    // MARK: - Reading

    private var isReloading = false

    func reload() async {
        guard !isReloading else { return }
        isReloading = true
        defer { isReloading = false }

        let client = self.client
        let snapshot = await Task.detached {
            let status = try? client.status()
            let sites = (try? client.list()) ?? []
            let config = (try? client.config()) ?? .default
            let running = Set(sites.map(\.port).filter { PortProbe.isListening($0) })
            // Trust is per-user, so only this process can answer it.
            let trusted = BeaconInstaller.isCATrusted()
            // Detection reads the project directory, so it stays off the main actor.
            let runnable = Set(sites.filter { $0.runSpec != nil }.map(\.name))
            let relay = status == nil ? nil : (try? client.relayStatus()) ?? nil
            return (status, sites, config, running, trusted, runnable, relay)
        }.value

        status = snapshot.0
        sites = snapshot.1
        config = snapshot.2
        running = snapshot.3
        caTrusted = snapshot.4
        runnable = snapshot.5
        relay = snapshot.6
        hasLoaded = true

        // A project the menu started that has since gone down (or been
        // removed) no longer needs a Stop button.
        let names = Set(sites.map(\.name))
        runs = runs.filter { name, run in
            guard names.contains(name), let site = sites.first(where: { $0.name == name }) else { return false }
            return run.state != .running || running.contains(site.port)
        }
    }

    func isUp(_ site: Site) -> Bool { running.contains(site.port) }

    func run(for site: Site) -> RunStatus? { runs[site.name] }

    func canStart(_ site: Site) -> Bool { runnable.contains(site.name) }

    // MARK: - Starting and stopping projects

    func start(_ site: Site) async {
        let client = self.client
        let result: Result<RunStatus?, Error> = await Task.detached {
            Result { try client.start(name: site.name) }
        }.value

        switch result {
        case .success(let status):
            runs[site.name] = status
            if status?.state == .running { running.insert(site.port) }
            followRuns()
        case .failure(let error):
            notice = "Couldn't start \(site.name): \(error.localizedDescription)"
        }
    }

    func stop(_ site: Site) async {
        let client = self.client
        let failure: String? = await Task.detached {
            do {
                try client.stop(name: site.name)
                return nil
            } catch {
                return "Couldn't stop \(site.name): \(error.localizedDescription)"
            }
        }.value
        notice = failure
        runs[site.name] = nil
        // Dev servers take a moment to let go of the port.
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        await reload()
    }

    /// Opens the start's output, which `beacond` writes to a plain log file.
    func showOutput(_ site: Site) {
        let file = run(for: site)?.logFile ?? BeaconPaths.projectLog(for: site.name)
        guard FileManager.default.fileExists(atPath: file) else {
            notice = "Beacon hasn't started \(site.name) yet, so there's no output to show."
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: file))
    }

    private func followRuns() {
        guard runTimer == nil, runs.values.contains(where: { $0.state == .starting }) else { return }
        runTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshRuns() }
        }
    }

    private func refreshRuns() async {
        let starting = runs.values.filter { $0.state == .starting }.map(\.name)
        guard !starting.isEmpty else {
            runTimer?.invalidate()
            runTimer = nil
            return
        }

        let client = self.client
        let updates = await Task.detached {
            starting.compactMap { name in (try? client.runStatus(name: name)).flatMap { $0 } }
        }.value

        var cameUp = false
        for status in updates {
            runs[status.name] = status
            if status.state == .running { cameUp = true }
            if status.state == .failed {
                notice = "\(status.name) didn't start. \(status.message ?? "")"
            }
        }
        if cameUp { await reload() }
    }

    // MARK: - Sharing

    /// A daemon too old to know about sharing answers the request with an error.
    var daemonSupportsSharing: Bool { relay != nil }

    var relayConfigured: Bool { (relay?.state ?? .off) != .off }

    func shared(_ site: Site) -> SharedProject? { relay?.share(named: site.name) }

    /// Points the daemon at a relay. Nil fields are left as they are; empty
    /// strings clear them. Returns a message when it was refused.
    func setRelay(url: String?, token: String?) async -> String? {
        activity = .saving
        defer { activity = nil }

        let client = self.client
        let result: Result<RelayStatus?, Error> = await Task.detached {
            Result { try client.setRelay(RelaySpec(url: url, token: token)) }
        }.value

        switch result {
        case .success(let status):
            relay = status
            await followRelay { $0.state != .connecting }
            return nil
        case .failure(let error):
            return error.localizedDescription
        }
    }

    func share(_ site: Site, password: String?) async {
        let client = self.client
        let result: Result<RelayStatus?, Error> = await Task.detached {
            Result { try client.share(ShareSpec(name: site.name, password: password)) }
        }.value

        switch result {
        case .success(let status):
            relay = status
            await followRelay { status in
                guard let share = status.share(named: site.name) else { return true }
                return share.publicURL != nil || share.error != nil || status.state == .failed
            }
            if let error = shared(site)?.error {
                notice = "Couldn't share \(site.name): \(error)"
            }
        case .failure(let error):
            notice = "Couldn't share \(site.name): \(error.localizedDescription)"
        }
    }

    func unshare(_ site: Site) async {
        let client = self.client
        let result: Result<RelayStatus?, Error> = await Task.detached {
            Result { try client.unshare(name: site.name) }
        }.value

        switch result {
        case .success(let status): relay = status
        case .failure(let error): notice = "Couldn't stop sharing \(site.name): \(error.localizedDescription)"
        }
    }

    func openPublic(_ site: Site) {
        guard let address = shared(site)?.publicURL, let url = URL(string: address) else { return }
        NSWorkspace.shared.open(url)
    }

    /// The daemon answers before the relay does. Poll briefly so the public
    /// URL shows up as soon as the relay confirms it, rather than on the next
    /// three-second tick.
    private func followRelay(until settled: @escaping (RelayStatus) -> Bool) async {
        let client = self.client
        for _ in 0..<40 {
            if let relay, settled(relay) { return }
            try? await Task.sleep(nanoseconds: 200_000_000)
            relay = await Task.detached { (try? client.relayStatus()) ?? nil }.value ?? relay
        }
    }

    // MARK: - Permission steps

    func perform(_ action: PrivilegedAction, purge: Bool = false) async -> ActionOutcome {
        switch action {
        case .install, .update: return await installService()
        case .trust: return await trustCertificate()
        case .uninstall: return await uninstall(purge: purge)
        }
    }

    private func installService() async -> ActionOutcome {
        guard let daemon = BeaconInstaller.locateBinary(named: "beacond") else {
            return .failed("""
            This copy of Beacon is missing its background service. Rebuild the app, \
            or run `make install` from the project folder.
            """)
        }
        let cli = BeaconInstaller.locateBinary(named: "beacon")

        activity = .installing
        defer { activity = nil }

        let client = self.client
        let outcome: ActionOutcome = await Task.detached {
            let result = Shell.runAsAdmin(
                script: BeaconInstaller.installScript(daemonSource: daemon, cliSource: cli),
                prompt: "Beacon needs administrator access to serve projects on ports 80 and 443."
            )
            if result.wasCancelled { return .cancelled }
            guard result.succeeded else {
                return .failed("The install didn't finish: \(result.message)")
            }
            guard client.waitUntilReachable(timeout: 15) else {
                return .failed("The service installed but didn't start. Check \(BeaconPaths.logFile) for the reason.")
            }
            return .succeeded
        }.value

        await reload()
        return outcome
    }

    private func trustCertificate() async -> ActionOutcome {
        activity = .trusting
        defer { activity = nil }

        let outcome: ActionOutcome = await Task.detached {
            let result = BeaconInstaller.trustCA()
            // The prompt can be dismissed, so trust the verdict, not the exit code.
            if BeaconInstaller.isCATrusted() { return .succeeded }
            if result.wasCancelled { return .cancelled }
            return .failed(result.message.isEmpty ? "macOS didn't trust the certificate." : result.message)
        }.value

        await reload()
        return outcome
    }

    private func uninstall(purge: Bool) async -> ActionOutcome {
        activity = .uninstalling
        defer { activity = nil }

        let outcome: ActionOutcome = await Task.detached {
            // The certificate first: it needs the CA file, which purging deletes,
            // and only the user's own process can reach their login keychain.
            let untrust = BeaconInstaller.untrustCA()
            if untrust.wasCancelled { return .cancelled }

            var script = BeaconInstaller.uninstallScript()
            if purge { script += "; rm -rf '\(BeaconPaths.supportDir)'" }

            let result = Shell.runAsAdmin(
                script: script,
                prompt: "Beacon needs administrator access to remove its background service."
            )
            if result.wasCancelled { return .cancelled }
            guard result.succeeded else {
                return .failed("Uninstall didn't finish: \(result.message)")
            }
            return .succeeded
        }.value

        await reload()
        return outcome
    }

    // MARK: - Everyday actions (no permission needed)

    /// The daemon exits on request and launchd starts it again, so this never
    /// shows a password prompt.
    func restartService() async {
        activity = .restarting
        defer { activity = nil }

        let client = self.client
        let failure: String? = await Task.detached {
            do {
                try client.restart()
            } catch {
                return error.localizedDescription
            }
            _ = client.waitUntilUnreachable()
            return client.waitUntilReachable()
                ? nil
                : "The service stopped but didn't come back. Check \(BeaconPaths.logFile)."
        }.value

        notice = failure
        await reload()
    }

    func register(
        name: String, domain: String?, port: Int? = nil, path: String?, secure: Bool
    ) async -> Result<Site, BeaconClientError> {
        let client = self.client
        let spec = RegisterSpec(
            name: name,
            domain: domain?.isEmpty == true ? nil : domain,
            port: port,
            path: path,
            secure: secure
        )
        let result: Result<Site, BeaconClientError> = await Task.detached {
            do {
                return .success(try client.register(spec))
            } catch let error as BeaconClientError {
                return .failure(error)
            } catch {
                return .failure(BeaconClientError(code: "error", message: error.localizedDescription))
            }
        }.value
        await reload()
        return result
    }

    func remove(_ site: Site) async {
        let client = self.client
        let failure: String? = await Task.detached {
            do {
                try client.unregister(name: site.name)
                return nil
            } catch {
                return "Couldn't remove \(site.domain): \(error.localizedDescription)"
            }
        }.value
        notice = failure
        await reload()
    }

    func save(_ newConfig: BeaconConfig) async -> String? {
        activity = .saving
        defer { activity = nil }

        let client = self.client
        let failure: String? = await Task.detached {
            do {
                _ = try client.setConfig(newConfig)
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value
        await reload()
        return failure
    }

    // MARK: - Small things

    func open(_ site: Site) {
        guard let url = URL(string: site.url) else { return }
        NSWorkspace.shared.open(url)
    }

    func revealInFinder(_ site: Site) {
        guard let path = site.path else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
