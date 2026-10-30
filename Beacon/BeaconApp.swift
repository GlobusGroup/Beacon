import SwiftUI

@main
struct BeaconApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @StateObject private var model = BeaconModel()

    /// Checked once, synchronously, so first-run setup opens with the app
    /// instead of after the first poll.
    private static let needsSetupAtLaunch = BeaconModel.setupNeededNow()

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

        Window("Add project", id: WindowID.addProject) {
            AddProjectView()
                .environmentObject(model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)

        Settings {
            SettingsPanel()
                .environmentObject(model)
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if let directory = SnapshotRenderer.requestedDirectory {
            MainActor.assumeIsolated { SnapshotRenderer.run(into: directory) }
            exit(0)
        }
        #endif
    }
}
