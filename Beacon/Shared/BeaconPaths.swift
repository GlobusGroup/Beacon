import Foundation

/// Every filesystem location Beacon owns. Root-owned, outside the user's home,
/// so the daemon and the menu bar app agree regardless of who is logged in.
///
/// Setting `BEACON_ROOT` relocates everything that isn't an install target,
/// which is how the daemon can be exercised on high ports without touching
/// the real system.
public enum BeaconPaths {
    public static let label = "io.beacon.daemon"
    public static let version = "1.6.1"

    public static let sandboxRoot = ProcessInfo.processInfo.environment["BEACON_ROOT"]

    public static var supportDir: String {
        sandboxRoot.map { $0 + "/support" } ?? "/Library/Application Support/Beacon"
    }
    public static var socketPath: String {
        sandboxRoot.map { $0 + "/beacon.sock" } ?? "/var/run/beacon.sock"
    }
    public static var resolverDir: String {
        sandboxRoot.map { $0 + "/resolver" } ?? "/etc/resolver"
    }
    public static var logFile: String {
        sandboxRoot.map { $0 + "/beacon.log" } ?? "/var/log/beacon.log"
    }

    public static var sitesFile: String { supportDir + "/sites.json" }
    public static var configFile: String { supportDir + "/config.json" }
    /// Relay address, token and shared projects. Readable by root only: it holds the token.
    public static var relayFile: String { supportDir + "/relay.json" }
    public static var certsDir: String { supportDir + "/certs" }
    /// Output of the projects Beacon starts, one file per project.
    public static var projectLogsDir: String { supportDir + "/logs" }
    /// How long each project took to come up last time, for the progress bar.
    public static var startTimesFile: String { supportDir + "/start-times.json" }
    /// Projects the daemon started and is still running, so a restarted
    /// daemon can take them back instead of losing track of them.
    public static var runningJobsFile: String { supportDir + "/running-jobs.json" }

    public static func projectLog(for name: String) -> String { projectLogsDir + "/" + name + ".log" }

    public static var caCertFile: String { certsDir + "/beacon-ca.pem" }
    public static var caKeyFile: String { certsDir + "/beacon-ca.key" }
    public static var leafCertFile: String { certsDir + "/beacon-leaf.pem" }
    public static var leafKeyFile: String { certsDir + "/beacon-leaf.key" }

    // Install targets: fixed, so an installed daemon is always found in one place.
    public static let daemonBinary = "/usr/local/libexec/beacon/beacond"
    public static let cliBinary = "/usr/local/bin/beacon"
    public static let launchDaemonPlist = "/Library/LaunchDaemons/\(label).plist"
    /// The fingerprint of the sources the installed daemon was built from,
    /// copied from the app that installed it.
    public static let installedFingerprint = "/usr/local/libexec/beacon/service-fingerprint"

    public static func resolverFile(for tld: String) -> String { resolverDir + "/" + tld }
}
