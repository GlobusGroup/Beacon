import Combine
import Sparkle
import SwiftUI

/// Sparkle, which keeps Beacon.app itself up to date from the appcast attached
/// to the latest GitHub release (`SUFeedURL` in Beacon-Info.plist). It
/// replaces the app only: the installed service is updated separately, by
/// `BeaconModel.serviceOutdated` and the Update step in Settings.
@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    /// False while a check is already under way.
    @Published private(set) var canCheckForUpdates = false
    /// Sparkle is running. Off in debug builds.
    let isActive: Bool

    private let controller: SPUStandardUpdaterController

    private init() {
        #if DEBUG
        // Debug builds carry the released version, so Sparkle would offer to
        // replace them with the published app. Release builds only.
        let start = false
        #else
        let start = true
        #endif
        isActive = start
        controller = SPUStandardUpdaterController(
            startingUpdater: start, updaterDelegate: nil, userDriverDelegate: nil
        )
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$canCheckForUpdates)
    }

    var checksAutomatically: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            controller.updater.automaticallyChecksForUpdates = newValue
        }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
