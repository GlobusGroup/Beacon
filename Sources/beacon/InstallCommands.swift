import ArgumentParser
import BeaconKit
import Foundation

extension BeaconCLI {
    struct Install: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Install Beacon's background service.",
            discussion: """
            Copies the daemon into /usr/local/libexec/beacon, registers it with \
            launchd so it survives reboots, writes the /etc/resolver entries that \
            point your TLDs at Beacon, and trusts its root certificate.

            Needs administrator rights. Run it with sudo, or let it ask.
            """
        )

        @Flag(name: .long, help: "Don't install the `beacon` command into /usr/local/bin.")
        var skipCli = false

        func run() throws {
            guard let daemon = BeaconInstaller.locateBinary(named: "beacond") else {
                Output.fail("""
                Couldn't find the `beacond` binary next to this command.
                Build it first with `swift build -c release`, then run \
                `sudo .build/release/beacon install`.
                """)
            }
            let cli = skipCli ? nil : BeaconInstaller.locateBinary(named: "beacon")
            let script = BeaconInstaller.installScript(daemonSource: daemon, cliSource: cli)

            print("Installing Beacon's background service…")
            let result: ShellResult
            if BeaconInstaller.isRoot {
                result = Shell.run("/bin/sh", ["-c", script])
            } else {
                result = Shell.runAsAdmin(
                    script: script,
                    prompt: "Beacon needs administrator rights to serve projects on ports 80 and 443."
                )
            }

            guard result.succeeded else {
                Output.fail("Install failed: \(result.message)")
            }

            guard waitForDaemon() else {
                Output.fail("""
                The service was installed but didn't come up. \
                Check \(BeaconPaths.logFile) for what went wrong.
                """)
            }

            let status = try? BeaconCLI.client.status()
            print("")
            print("  \(Output.green("●")) Beacon is running.")
            print("")
            if let status {
                print("  Domains ending \(status.tlds.map { ".\($0)" }.joined(separator: ", ")) now resolve to this machine.")
            }
            print("  Register your first project:  \(Output.bold("beacon register"))")
            trustCertificate()
            print("")
        }

        /// macOS asks the user to approve this with Touch ID or a password, so
        /// it can't be folded into the privileged script above.
        private func trustCertificate() {
            guard !BeaconInstaller.isCATrusted() else { return }
            print("  Approve the certificate prompt to enable https:// links…")

            let result = BeaconInstaller.trustCA()
            if BeaconInstaller.isCATrusted() {
                print("  \(Output.green("✓")) https:// links are trusted.")
                return
            }
            print("")
            print("  \(Output.yellow("One thing left:")) https:// isn't trusted yet.")
            print("  \(result.message.isEmpty ? "The prompt was dismissed." : result.message)")
            print("  Run \(Output.bold("beacon trust")) as yourself when you're at this Mac.")
        }

        /// launchd returns before the daemon has bound its socket.
        private func waitForDaemon(timeout: TimeInterval = 10) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if BeaconCLI.client.daemonIsReachable { return true }
                usleep(200_000)
            }
            return false
        }
    }

    struct Uninstall: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Remove Beacon's background service, resolvers and certificate."
        )

        @Flag(name: .long, help: "Also delete the registry of projects.")
        var purge = false

        func run() throws {
            // Per-user trust first: it needs the certificate file, which the
            // root script below may delete, and root can't reach the user's
            // login keychain anyway.
            print("Removing Beacon's certificate from your login keychain…")
            let untrust = BeaconInstaller.untrustCA()
            if untrust.wasCancelled {
                Output.fail("Uninstall stopped: the certificate prompt was dismissed. Nothing was removed.")
            }

            var script = BeaconInstaller.uninstallScript()
            if purge {
                script += "; rm -rf '\(BeaconPaths.supportDir)'"
            }

            print("Removing the background service (macOS will ask for your password)…")
            let result = BeaconInstaller.isRoot
                ? Shell.run("/bin/sh", ["-c", script])
                : Shell.runAsAdmin(
                    script: script,
                    prompt: "Beacon needs administrator rights to remove its background service."
                  )

            guard result.succeeded else {
                Output.fail("Uninstall failed: \(result.message)")
            }
            print("Beacon removed.\(purge ? "" : " Your registered projects are still in \(BeaconPaths.supportDir).")")
        }
    }

    struct Restart: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Restart the background service.")

        func run() throws {
            // The daemon exits on request and launchd's KeepAlive restarts it,
            // so this needs no password.
            let client = BeaconCLI.client
            BeaconCLI.perform { try client.restart() }
            _ = client.waitUntilUnreachable()
            guard client.waitUntilReachable() else {
                Output.fail("The service stopped but didn't come back. Check \(BeaconPaths.logFile).")
            }
            print("Restarted.")
        }
    }
}
