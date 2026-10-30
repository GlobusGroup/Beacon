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

/// The three things that make macOS ask the user for permission. Each one is
/// introduced by `PermissionExplainer` before the system prompt appears.
enum PrivilegedAction: String, Identifiable {
    case install
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

    private let client = BeaconClient()
    private var timer: Timer?

    var isRunning: Bool { status != nil }

    /// Every managed TLD has its resolver file in place.
    var resolverActive: Bool {
        guard let status else { return false }
        return status.tlds.allSatisfy { status.resolversInstalled.contains($0) }
    }

    var needsSetup: Bool { !isRunning || !caTrusted }

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
        sites: [Site] = [],
        onlinePorts: Set<Int> = [],
        activity: Activity? = nil,
        notice: String? = nil
    ) {
        self.status = previewRunning
            ? DaemonStatus(
                version: BeaconPaths.version, pid: 4242, httpPort: 80, httpsPort: 443, dnsPort: 53535,
                tlds: ["test"], resolversInstalled: ["test"], siteCount: sites.count,
                startedAt: Date().addingTimeInterval(-3600)
              )
            : nil
        self.caTrusted = trusted
        self.sites = sites
        self.running = onlinePorts
        self.activity = activity
        self.notice = notice
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
            return (status, sites, config, running, trusted)
        }.value

        status = snapshot.0
        sites = snapshot.1
        config = snapshot.2
        running = snapshot.3
        caTrusted = snapshot.4
        hasLoaded = true
    }

    func isUp(_ site: Site) -> Bool { running.contains(site.port) }

    // MARK: - Permission steps

    func perform(_ action: PrivilegedAction, purge: Bool = false) async -> ActionOutcome {
        switch action {
        case .install: return await installService()
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

    func register(name: String, domain: String?, path: String?, secure: Bool) async -> Result<Site, BeaconClientError> {
        let client = self.client
        let spec = RegisterSpec(
            name: name,
            domain: domain?.isEmpty == true ? nil : domain,
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
