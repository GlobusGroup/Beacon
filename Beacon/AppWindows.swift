import AppKit
import SwiftUI

enum WindowID {
    static let setup = "setup"
    static let addProject = "add-project"
    /// SwiftUI's own identifier for the Settings scene's window.
    static let settings = "com_apple_SwiftUI_Settings_window"
}

/// Keeps Beacon's windows in front while the user is working in them.
///
/// Beacon is a menu bar app (LSUIElement), and macOS treats those as guests:
/// no Dock icon, no Cmd-Tab entry, and `NSApp.activate()` is only a request
/// it is free to refuse. Whenever something else takes focus — a password
/// prompt, the certificate dialog, the folder picker, a click elsewhere —
/// focus goes back to the last *regular* app, and Beacon's window drops behind
/// with no way to get it back but the menu bar. Setup takes focus away at
/// every step, so it suffered most.
///
/// So while any Beacon window is open, Beacon becomes a regular app with a
/// Dock icon and a Cmd-Tab entry, and macOS hands focus back to it properly.
/// When the last window closes it goes back to living in the menu bar.
@MainActor
enum AppWindows {
    static func open(_ id: String, with openWindow: OpenWindowAction) {
        becomeRegularApp()
        openWindow(id: id)
        bringForward(id)
    }

    static func openSettings(with openSettings: OpenSettingsAction) {
        becomeRegularApp()
        openSettings()
        bringForward(WindowID.settings)
    }

    /// Brings a window back in front, e.g. once a macOS prompt it triggered
    /// has been answered, so the user sees the result where they left off.
    static func bringForward(_ id: String) {
        // SwiftUI creates a newly opened window a runloop turn later.
        for delay in [0.0, 0.1, 0.3] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let window = NSApp.windows.first(where: { matches($0, id) }) else { return }
                if window.isMiniaturized { window.deminiaturize(nil) }
                NSApp.activate()
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    /// Called whenever a Beacon window appears.
    static func becomeRegularApp() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate()
    }

    /// Called as a window closes. Returns to menu-bar-only once no Beacon
    /// window is left, minimised ones included, since those need the Dock.
    static func windowWillClose(_ closing: NSWindow) {
        guard isBeaconWindow(closing) else { return }
        DispatchQueue.main.async {
            let anyLeft = NSApp.windows.contains { window in
                window !== closing && isBeaconWindow(window) && (window.isVisible || window.isMiniaturized)
            }
            if !anyLeft && NSApp.activationPolicy() != .accessory {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    /// Setup, Add project and Settings — not the menu bar popover, sheets or
    /// system panels, which come and go with a window that's already counted.
    private static func isBeaconWindow(_ window: NSWindow) -> Bool {
        [WindowID.setup, WindowID.addProject, WindowID.settings].contains { matches(window, $0) }
    }

    private static func matches(_ window: NSWindow, _ id: String) -> Bool {
        window.identifier?.rawValue.hasPrefix(id) == true
    }
}
