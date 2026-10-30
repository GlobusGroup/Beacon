import AppKit
import SwiftUI

enum WindowID {
    static let setup = "setup"
    static let addProject = "add-project"
}

/// Opens Beacon's windows in front of whatever the user was doing.
///
/// Beacon has no Dock icon, so it is never the active app on its own. Without
/// activating first, SwiftUI opens the window *behind* the frontmost app —
/// which is why Settings appeared to do nothing. SwiftUI also creates the
/// window a runloop turn later, so it's ordered front once it exists.
@MainActor
enum AppWindows {
    static func open(_ id: String, with openWindow: OpenWindowAction) {
        NSApp.activate()
        openWindow(id: id)
        orderFront { $0.identifier?.rawValue.hasPrefix(id) == true }
    }

    static func openSettings(with openSettings: OpenSettingsAction) {
        NSApp.activate()
        openSettings()
        orderFront { $0.identifier?.rawValue.contains("Settings") == true }
    }

    private static func orderFront(where matches: @escaping (NSWindow) -> Bool) {
        for delay in [0.0, 0.1, 0.3] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let window = NSApp.windows.first(where: matches) else { return }
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
            }
        }
    }
}
