import ArgumentParser
import BeaconKit
import Foundation

/// `beacon status --json`, which pairs the daemon's view with the trust state
/// only this process can determine.
struct StatusReport: Encodable {
    var daemon: DaemonStatus
    var caTrusted: Bool
}

extension BeaconCLI {
    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show whether Beacon is installed and healthy."
        )

        @Flag(name: .long, help: "Print as JSON.")
        var json = false

        func run() throws {
            guard let status = try? BeaconCLI.client.status() else {
                if json {
                    Output.json(["installed": false])
                } else {
                    print("")
                    print("  \(Output.red("●")) Beacon isn't running.")
                    print("")
                    print("  Install it with \(Output.bold("sudo beacon install"))")
                    print("")
                }
                throw ExitCode(1)
            }

            if json {
                // Trust is per-user, so it is answered here rather than by the
                // daemon, which runs as root and has no login keychain.
                Output.json(StatusReport(daemon: status, caTrusted: BeaconInstaller.isCATrusted()))
                return
            }

            let uptime = Int(Date().timeIntervalSince(status.startedAt))
            print("")
            print("  \(Output.green("●")) Beacon \(status.version) \(Output.dim("· pid \(status.pid) · up \(format(uptime))"))")
            print("")
            print("  \(label("Domains"))\(status.tlds.map { ".\($0)" }.joined(separator: "  "))")
            print("  \(label("Resolvers"))\(resolverState(status))")
            print("  \(label("HTTPS"))\(BeaconInstaller.isCATrusted() ? Output.green("trusted") : Output.yellow("not trusted yet — run `beacon trust`"))")
            print("  \(label("Listening")):\(status.httpPort)  :\(status.httpsPort)  \(Output.dim("dns :\(status.dnsPort)"))")
            print("  \(label("Projects"))\(status.siteCount)")
            print("")
        }

        private func resolverState(_ status: DaemonStatus) -> String {
            let missing = status.tlds.filter { !status.resolversInstalled.contains($0) }
            guard missing.isEmpty else {
                return Output.yellow("missing for \(missing.map { ".\($0)" }.joined(separator: " "))")
            }
            return Output.green("installed")
        }

        private func label(_ text: String) -> String {
            Output.dim(text.padding(toLength: 12, withPad: " ", startingAt: 0))
        }

        private func format(_ seconds: Int) -> String {
            if seconds < 60 { return "\(seconds)s" }
            if seconds < 3600 { return "\(seconds / 60)m" }
            if seconds < 86400 { return "\(seconds / 3600)h" }
            return "\(seconds / 86400)d"
        }
    }

    struct Config: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show or change which TLDs Beacon owns and which ports it hands out."
        )

        @Option(name: .long, help: "Start routing another TLD, e.g. `dev`.")
        var addTld: String?

        @Option(name: .long, help: "Stop routing a TLD.")
        var removeTld: String?

        @Option(name: .long, help: "Port range for new projects, e.g. `3100-3999`.")
        var portRange: String?

        @Option(name: .long, help: "Scheme used for new projects: http or https.")
        var defaultScheme: String?

        @Flag(name: .long, help: "Print as JSON.")
        var json = false

        func run() throws {
            var config = BeaconCLI.perform { try BeaconCLI.client.config() }
            var changed = false

            if let addTld {
                let tld = addTld.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased()
                if !config.tlds.contains(tld) {
                    config.tlds.append(tld)
                    changed = true
                }
            }
            if let removeTld {
                let tld = removeTld.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased()
                config.tlds.removeAll { $0 == tld }
                changed = true
            }
            if let portRange {
                let parts = portRange.split(separator: "-")
                guard parts.count == 2, let low = Int(parts[0]), let high = Int(parts[1]) else {
                    Output.fail("Port range should look like `3100-3999`.")
                }
                config.portRangeStart = low
                config.portRangeEnd = high
                changed = true
            }
            if let defaultScheme {
                switch defaultScheme.lowercased() {
                case "https": config.defaultSecure = true
                case "http": config.defaultSecure = false
                default: Output.fail("Scheme should be `http` or `https`.")
                }
                changed = true
            }

            if changed {
                config = BeaconCLI.perform { try BeaconCLI.client.setConfig(config) }
            }

            if json {
                Output.json(config)
                return
            }

            print("")
            print("  \(Output.dim("TLDs          "))\(config.tlds.map { ".\($0)" }.joined(separator: "  "))")
            print("  \(Output.dim("Port range    "))\(config.portRangeStart)-\(config.portRangeEnd)")
            print("  \(Output.dim("New projects  "))\(config.defaultSecure ? "https" : "http")")
            print("")
            if changed {
                print(Output.dim("  Changes are live. DNS cache was flushed."))
                print("")
            }
        }
    }

    struct Trust: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Trust Beacon's root certificate so https:// links are accepted.",
            discussion: """
            macOS asks you to approve this with Touch ID or your password, so run \
            it as yourself while logged in at the machine — not with sudo, and \
            not over SSH.
            """
        )

        func run() throws {
            guard FileManager.default.fileExists(atPath: BeaconPaths.caCertFile) else {
                Output.fail("Beacon hasn't generated a certificate authority yet. Start the service first.")
            }

            if BeaconInstaller.isCATrusted() {
                print("Beacon's root certificate is already trusted.")
                return
            }

            print("Approve the prompt macOS is about to show…")
            let result = BeaconInstaller.trustCA()

            // The prompt can be dismissed, so trust the verdict, not the exit code.
            guard BeaconInstaller.isCATrusted() else {
                Output.fail("""
                That didn't take. \(result.message.isEmpty ? "The prompt was dismissed." : result.message)

                This has to run as you, in a session you're logged into — \
                `sudo beacon trust` and SSH both fail, because root has no \
                login keychain to put the certificate in.
                """)
            }
            print("Trusted. Restart your browser if a tab is still complaining.")
        }
    }
}
