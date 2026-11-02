import Foundation

/// Everything that touches the system outside Beacon's own directories:
/// `/etc/resolver`, `/Library/LaunchDaemons`, the System keychain, `/usr/local/bin`.
///
/// Shared between the daemon (which re-syncs resolvers when the TLD list
/// changes) and the installers in the CLI and the menu bar app.
public enum BeaconInstaller {
    /// Marks resolver files as ours so uninstalling never deletes someone else's.
    public static let resolverMarker = "# Managed by Beacon — safe to delete"

    public static var isRoot: Bool { geteuid() == 0 }

    // MARK: - DNS resolvers

    /// Writes `/etc/resolver/<tld>` for each managed TLD and removes the ones we
    /// previously wrote that are no longer wanted. Requires root.
    @discardableResult
    public static func syncResolvers(tlds: [String], dnsPort: Int) -> [String] {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: BeaconPaths.resolverDir, withIntermediateDirectories: true)

        let contents = """
        \(resolverMarker)
        nameserver 127.0.0.1
        port \(dnsPort)

        """

        var written: [String] = []
        for tld in tlds {
            let path = BeaconPaths.resolverFile(for: tld)
            if (try? contents.write(toFile: path, atomically: true, encoding: .utf8)) != nil {
                written.append(tld)
            }
        }

        // Drop stale files, but only ones carrying our marker.
        if let existing = try? fm.contentsOfDirectory(atPath: BeaconPaths.resolverDir) {
            for file in existing where !tlds.contains(file) {
                let path = BeaconPaths.resolverFile(for: file)
                guard let body = try? String(contentsOfFile: path, encoding: .utf8),
                      body.contains(resolverMarker) else { continue }
                try? fm.removeItem(atPath: path)
            }
        }

        flushDNSCache()
        return written
    }

    /// TLDs that currently have a Beacon-owned resolver file.
    public static func installedResolvers() -> [String] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: BeaconPaths.resolverDir) else { return [] }
        return files.filter { file in
            guard let body = try? String(contentsOfFile: BeaconPaths.resolverFile(for: file), encoding: .utf8)
            else { return false }
            return body.contains(resolverMarker)
        }.sorted()
    }

    public static func removeAllResolvers() {
        for tld in installedResolvers() {
            try? FileManager.default.removeItem(atPath: BeaconPaths.resolverFile(for: tld))
        }
        flushDNSCache()
    }

    public static func flushDNSCache() {
        Shell.run("/usr/bin/dscacheutil", ["-flushcache"])
        Shell.run("/usr/bin/killall", ["-HUP", "mDNSResponder"])
    }

    // MARK: - Certificate authority trust

    public static let caCommonName = "Beacon Local CA"

    /// Whether macOS actually *trusts* the root, not merely whether a copy of
    /// it is sitting in a keychain. Those are different things, and only the
    /// first one makes `https://myproject.test` work.
    public static func isCATrusted() -> Bool {
        guard FileManager.default.fileExists(atPath: BeaconPaths.caCertFile) else { return false }
        let verify = ["/usr/bin/security", "verify-cert", "-c", BeaconPaths.caCertFile, "-p", "ssl"]
        // Trust is per-user. Under `sudo beacon install`, asking as root would
        // always say no, so ask as the person who ran sudo.
        let result: ShellResult
        if isRoot, let user = ProcessInfo.processInfo.environment["SUDO_USER"], user != "root" {
            result = Shell.run("/usr/bin/sudo", ["-u", user, "-H"] + verify)
        } else {
            result = Shell.run(verify[0], Array(verify.dropFirst()))
        }
        // verify-cert exits 0 either way, so the verdict has to be read.
        return !(result.stdout + result.stderr).contains("CSSMERR")
    }

    /// The command that trusts Beacon's root.
    ///
    /// Note what this does *not* do: it never runs as root, and it never
    /// touches the System keychain. Writing admin-domain trust settings goes
    /// through an authorisation right that macOS refuses outside a GUI session
    /// — it fails with "no user interaction was possible" even when you are
    /// already root, which makes it unusable from an installer or a daemon.
    ///
    /// Trusting the root for the logged-in user instead needs no privileges,
    /// prompts once with Touch ID or a password, and is what actually makes
    /// Safari and Chrome accept `https://myproject.test`.
    public static func trustScript() -> String {
        "/usr/bin/security add-trusted-cert -r trustRoot "
            + "-k \"$HOME/Library/Keychains/login.keychain-db\" '\(BeaconPaths.caCertFile)'"
    }

    /// Trusts the root as the logged-in user.
    ///
    /// When called from a process that is already root — `sudo beacon install`
    /// — it steps back down to the user who invoked sudo, because root has no
    /// login keychain to put this in.
    @discardableResult
    public static func trustCA() -> ShellResult {
        guard isRoot else {
            return Shell.run("/bin/sh", ["-c", trustScript()])
        }
        guard let user = ProcessInfo.processInfo.environment["SUDO_USER"], user != "root" else {
            return ShellResult(
                status: 1, stdout: "",
                stderr: "Can't trust a certificate as root. Run `beacon trust` as yourself."
            )
        }
        return Shell.run("/usr/bin/sudo", ["-u", user, "-H", "/bin/sh", "-c", trustScript()])
    }

    /// Removes Beacon's root from the logged-in user's trust settings and
    /// login keychain. Runs as the user, for the same reason `trustCA` does:
    /// root has no login keychain.
    public static func untrustScript() -> String {
        let keychain = "\"$HOME/Library/Keychains/login.keychain-db\""
        return [
            "[ -f '\(BeaconPaths.caCertFile)' ] && /usr/bin/security remove-trusted-cert '\(BeaconPaths.caCertFile)' 2>/dev/null",
            "for h in $(/usr/bin/security find-certificate -a -c '\(caCommonName)' -Z \(keychain) 2>/dev/null | awk '/SHA-1/ {print $3}'); do /usr/bin/security delete-certificate -Z \"$h\" \(keychain) >/dev/null; done",
            "true",
        ].joined(separator: "; ")
    }

    @discardableResult
    public static func untrustCA() -> ShellResult {
        guard isRoot else {
            return Shell.run("/bin/sh", ["-c", untrustScript()])
        }
        guard let user = ProcessInfo.processInfo.environment["SUDO_USER"], user != "root" else {
            return ShellResult(status: 0, stdout: "", stderr: "")
        }
        return Shell.run("/usr/bin/sudo", ["-u", user, "-H", "/bin/sh", "-c", untrustScript()])
    }

    // MARK: - launchd

    public static func launchDaemonPlist() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(BeaconPaths.label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(BeaconPaths.daemonBinary)</string>
                <string>run</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>ProcessType</key>
            <string>Interactive</string>
            <key>StandardOutPath</key>
            <string>\(BeaconPaths.logFile)</string>
            <key>StandardErrorPath</key>
            <string>\(BeaconPaths.logFile)</string>
        </dict>
        </plist>
        """
    }

    public static var daemonIsLoaded: Bool {
        Shell.run("/bin/launchctl", ["print", "system/\(BeaconPaths.label)"]).succeeded
    }

    public static func bootstrapDaemon() -> ShellResult {
        Shell.run("/bin/launchctl", ["bootout", "system/\(BeaconPaths.label)"])
        return Shell.run("/bin/launchctl", ["bootstrap", "system", BeaconPaths.launchDaemonPlist])
    }

    public static func bootoutDaemon() -> ShellResult {
        Shell.run("/bin/launchctl", ["bootout", "system/\(BeaconPaths.label)"])
    }

    public static func kickstartDaemon() -> ShellResult {
        Shell.run("/bin/launchctl", ["kickstart", "-k", "system/\(BeaconPaths.label)"])
    }

    // MARK: - Locating the binaries to install

    /// Finds `beacond` and `beacon` next to whatever is running right now —
    /// a SwiftPM build directory, an installed prefix, or `Beacon.app/Contents/Helpers`.
    public static func locateBinary(named name: String) -> String? {
        var candidates: [String] = []

        let exe = URL(fileURLWithPath: CommandLine.arguments.first ?? "")
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
        candidates.append(exe.appendingPathComponent(name).path)

        // Where the app's build phase embeds them.
        candidates.append(
            Bundle.main.bundleURL
                .appendingPathComponent("Contents/Helpers")
                .appendingPathComponent(name).path
        )
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent(name).path)
        }
        candidates.append(
            Bundle.main.bundleURL
                .appendingPathComponent("Contents/Resources")
                .appendingPathComponent(name).path
        )
        candidates.append("/usr/local/libexec/beacon/\(name)")
        candidates.append("/usr/local/bin/\(name)")

        return candidates.first(where: isExecutable(exactlyAt:))
    }

    /// Like `isExecutableFile(atPath:)`, but the file name must match case and all.
    /// APFS is usually case-insensitive, so inside the app `Contents/MacOS/beacon`
    /// would otherwise find the app's own `Beacon` executable and install that
    /// as the CLI, where its signature (sealed to the bundle) no longer verifies.
    static func isExecutable(exactlyAt path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: path),
              let siblings = try? fm.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        else { return false }
        return siblings.contains(url.lastPathComponent)
    }

    /// The script that performs a full install. Run it as root directly, or hand
    /// it to `Shell.runAsAdmin` to get the system authorisation prompt.
    /// The app's fingerprint of the daemon and CLI sources, written by the
    /// embed build phase. Nil outside the app, e.g. for `make install`.
    public static func bundledFingerprint() -> String? {
        Bundle.main.url(forResource: "service-fingerprint", withExtension: nil).flatMap(readFingerprint(at:))
    }

    public static func installedFingerprint() -> String? {
        readFingerprint(at: URL(fileURLWithPath: BeaconPaths.installedFingerprint))
    }

    private static func readFingerprint(at url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func installScript(daemonSource: String, cliSource: String?, fingerprintSource: String? = nil) -> String {
        var lines = [
            "set -e",
            "mkdir -p /usr/local/libexec/beacon",
            "mkdir -p '\(BeaconPaths.supportDir)'",
            "mkdir -p '\(BeaconPaths.certsDir)'",
            "mkdir -p /usr/local/bin",
            "/bin/launchctl bootout system/\(BeaconPaths.label) 2>/dev/null || true",
            "cp -f '\(daemonSource)' '\(BeaconPaths.daemonBinary)'",
            "chown root:wheel '\(BeaconPaths.daemonBinary)'",
            "chmod 755 '\(BeaconPaths.daemonBinary)'",
        ]
        if let cliSource {
            lines += [
                "cp -f '\(cliSource)' '\(BeaconPaths.cliBinary)'",
                "chmod 755 '\(BeaconPaths.cliBinary)'",
            ]
        }
        // Without one, drop any old fingerprint rather than vouch for a
        // daemon it doesn't describe.
        if let fingerprintSource {
            lines += [
                "cp -f '\(fingerprintSource)' '\(BeaconPaths.installedFingerprint)'",
                "chmod 644 '\(BeaconPaths.installedFingerprint)'",
            ]
        } else {
            lines.append("rm -f '\(BeaconPaths.installedFingerprint)'")
        }
        lines += [
            "'\(BeaconPaths.daemonBinary)' write-plist > '\(BeaconPaths.launchDaemonPlist)'",
            "chown root:wheel '\(BeaconPaths.launchDaemonPlist)'",
            "chmod 644 '\(BeaconPaths.launchDaemonPlist)'",
            "/bin/launchctl bootstrap system '\(BeaconPaths.launchDaemonPlist)'",
            // The daemon generates the root on its first run; `beacon install`
            // waits for it and trusts it afterwards, as the user.
            "for i in $(seq 1 50); do [ -f '\(BeaconPaths.caCertFile)' ] && break; sleep 0.2; done",
        ]
        return lines.joined(separator: " && ")
    }

    public static func uninstallScript() -> String {
        [
            "/bin/launchctl bootout system/\(BeaconPaths.label) 2>/dev/null || true",
            "rm -f '\(BeaconPaths.launchDaemonPlist)'",
            "rm -rf /usr/local/libexec/beacon",
            "rm -f '\(BeaconPaths.cliBinary)'",
            "rm -f '\(BeaconPaths.socketPath)'",
            "for f in \(BeaconPaths.resolverDir)/*; do grep -q 'Managed by Beacon' \"$f\" 2>/dev/null && rm -f \"$f\"; done",
            "/usr/bin/security delete-certificate -c '\(caCommonName)' -t /Library/Keychains/System.keychain 2>/dev/null || true",
            "/usr/bin/dscacheutil -flushcache",
            "/usr/bin/killall -HUP mDNSResponder 2>/dev/null || true",
        ].joined(separator: "; ")
    }
}
