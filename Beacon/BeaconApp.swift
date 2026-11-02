import SwiftUI

@main
struct BeaconApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @StateObject private var model = BeaconModel()

    /// Checked once, synchronously, so first-run setup opens with the app
    /// instead of after the first poll.
    private static let needsSetupAtLaunch: Bool = {
        #if DEBUG
        // Lets the first-run window be exercised on an installed machine.
        if CommandLine.arguments.contains("--show-setup") { return true }
        #endif
        return BeaconModel.setupNeededNow()
    }()

    var body: some Scene {
        MenuBarExtra {
            MenuPanel()
                .environmentObject(model)
        } label: {
            // The brand symbol as a template image, so macOS colours it for
            // light and dark menu bars. Dimmed while the service is down.
            Image(model.isRunning ? "MenuBarIcon" : "MenuBarIconInactive")
        }
        .menuBarExtraStyle(.window)

        Window("Set Up Beacon", id: WindowID.setup) {
            SetupView()
                .environmentObject(model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(Self.needsSetupAtLaunch ? .presented : .suppressed)
        // Opening a .beacon file mustn't bring this window up; AppDelegate takes it.
        .handlesExternalEvents(matching: [])

        Window("Add project", id: WindowID.addProject) {
            AddProjectView()
                .environmentObject(model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)
        .handlesExternalEvents(matching: [])

        Settings {
            SettingsPanel()
                .environmentObject(model)
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowCloseObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if let directory = SnapshotRenderer.requestedDirectory {
            MainActor.assumeIsolated { SnapshotRenderer.run(into: directory) }
            exit(0)
        }
        #endif

        // Drop back to menu-bar-only once the last Beacon window closes.
        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { notification in
            guard let window = notification.object as? NSWindow else { return }
            MainActor.assumeIsolated { AppWindows.windowWillClose(window) }
        }
    }

    /// A `.beacon` relay invite, double-clicked or dropped on the app.
    func application(_ application: NSApplication, open urls: [URL]) {
        let invites = urls.filter { $0.pathExtension.lowercased() == RelayInvite.fileExtension }
        MainActor.assumeIsolated { InviteInbox.receive(invites) }
    }

    /// Clicking the Dock icon while Beacon is a regular app, with its windows
    /// hidden behind others, should bring them back rather than do nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        true
    }
}
