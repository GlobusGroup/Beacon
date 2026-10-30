#if DEBUG
import AppKit
import SwiftUI

/// Renders every screen, in every interesting state, in light and dark, to
/// PNGs — so the interface can be reviewed without clicking through it, and
/// without a display at all.
///
///   Beacon.app/Contents/MacOS/Beacon --snapshots /path/to/dir
@MainActor
enum SnapshotRenderer {
    static var requestedDirectory: URL? {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--snapshots"), flag + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[flag + 1])
    }

    static func run(into directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let projects = [
            Site(name: "studio", domain: "studio.test", port: 3101, path: "/Users/dean/projects/studio"),
            Site(name: "api", domain: "api.test", port: 3102, path: "/Users/dean/projects/api"),
            Site(name: "shop", domain: "shop.test", port: 3103, path: "/Users/dean/projects/shop"),
        ]

        let fresh = BeaconModel(previewRunning: false, trusted: false)
        let installed = BeaconModel(previewRunning: true, trusted: false, sites: projects, onlinePorts: [3101])
        let installing = BeaconModel(previewRunning: false, trusted: false, activity: .installing)
        let ready = BeaconModel(previewRunning: true, trusted: true, sites: projects, onlinePorts: [3101, 3102])
        let readyEmpty = BeaconModel(previewRunning: true, trusted: true)
        let withNotice = BeaconModel(
            previewRunning: true, trusted: true, sites: projects, onlinePorts: [3101],
            notice: "Couldn't remove shop.test: the service didn't answer. Restart it from Settings."
        )

        var shots: [(String, AnyView, BeaconModel)] = [
            ("menu-1-not-installed", AnyView(MenuPanel()), fresh),
            ("menu-2-certificate-pending", AnyView(MenuPanel()), installed),
            ("menu-3-ready", AnyView(MenuPanel()), ready),
            ("menu-4-empty", AnyView(MenuPanel()), readyEmpty),
            ("menu-5-notice", AnyView(MenuPanel()), withNotice),
            ("setup-1-fresh", AnyView(SetupView()), fresh),
            ("setup-2-installing", AnyView(SetupView()), installing),
            ("setup-3-step-two", AnyView(SetupView()), installed),
            ("setup-4-done", AnyView(SetupView()), ready),
            ("add-project", AnyView(AddProjectView()), ready),
            ("settings-installed", AnyView(SettingsPanel()), installed),
            ("settings-not-installed", AnyView(SettingsPanel()), fresh),
        ]
        for action in [PrivilegedAction.install, .trust, .uninstall] {
            shots.append(("explainer-\(action.rawValue)", AnyView(PermissionExplainer(action: action) { _ in }), ready))
        }

        for (name, view, model) in shots {
            for dark in [false, true] {
                render(view, model: model, dark: dark,
                       to: directory.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
            }
        }
    }

    private static func render(_ view: AnyView, model: BeaconModel, dark: Bool, to url: URL) {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        let root = view
            .environmentObject(model)
            // The popover's own material isn't available offscreen; window
            // background is the closest stand-in.
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light)

        let hosting = NSHostingView(rootView: root)
        hosting.appearance = appearance
        let size = hosting.fittingSize
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.appearance = appearance
        window.contentView = hosting
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
