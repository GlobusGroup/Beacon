import ArgumentParser
import BeaconKit
import Foundation

extension BeaconCLI {
    struct Share: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Put a project on a public URL through your Beacon relay.",
            discussion: """
            The project gets <name>-<label>.<relay domain>, where the label is the \
            one your token carries on the relay, e.g. https://shop-dean.relay.example.com. \
            The URL stays the same every time you share it.

            Beacon keeps sharing it, across restarts, until `beacon unshare`. Run \
            `beacon relay` once first to say which relay to use.

            Dev servers that check the Host header need to allow the relay's \
            domain: in Vite, `server.allowedHosts: ['.relay.example.com']`.
            """
        )

        @Argument(help: "Project name. Defaults to the current directory's name.")
        var name: String?

        @Option(name: .long, help: "Ask visitors for this password (any username).")
        var password: String?

        @Flag(name: .long, help: "Print the result as JSON.")
        var json = false

        func run() throws {
            let site = BeaconCLI.perform { try BeaconCLI.client.info(name: name ?? CurrentDirectory.name) }
            let status = BeaconCLI.perform {
                try BeaconCLI.client.share(ShareSpec(name: site.name, password: password))
            }
            let settled = waitForRelay(name: site.name, initial: status)
            let shared = settled?.share(named: site.name)

            if json {
                Output.json(shared ?? SharedProject(name: site.name, passwordProtected: password != nil))
                if shared?.publicURL == nil { throw ExitCode(1) }
                return
            }

            if let error = shared?.error {
                Output.fail(error)
            }
            guard let url = shared?.publicURL else {
                let reason = settled?.error ?? "The relay hasn't answered yet."
                print("")
                print("  \(Output.yellow("●")) \(Output.bold(site.name)) will be shared once the relay answers.")
                print("  \(Output.dim(reason))")
                print("")
                print("  Check on it with \(Output.bold("beacon relay")).")
                print("")
                return
            }

            print("")
            print("  \(Output.green("●")) \(Output.bold(site.name)) is public")
            print("  \(Output.dim("URL "))       \(Output.bold(url))")
            print("  \(Output.dim("Serves"))     \(site.origin)")
            if shared?.passwordProtected == true {
                print("  \(Output.dim("Access"))     password required")
            }
            print("")
            if !PortProbe.isListening(site.port) {
                Output.warn("nothing is listening on port \(site.port), so visitors will see an error page until it starts.")
            }
        }

        /// The daemon answers before the relay does. Give the relay a moment so
        /// the URL can be printed rather than promised.
        private func waitForRelay(name: String, initial: RelayStatus?) -> RelayStatus? {
            var status = initial
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline {
                if let share = status?.share(named: name), share.publicURL != nil || share.error != nil {
                    return status
                }
                if status?.state == .failed, Date() > deadline.addingTimeInterval(-6) { return status }
                usleep(200_000)
                status = (try? BeaconCLI.client.relayStatus()) ?? status
            }
            return status
        }
    }

    struct Unshare: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Take a project off its public URL.")

        @Argument(help: "Project name. Defaults to the current directory's name.")
        var name: String?

        func run() throws {
            let resolved = name ?? CurrentDirectory.name
            _ = BeaconCLI.perform { try BeaconCLI.client.unshare(name: resolved) }
            print("Stopped sharing \(Output.bold(Site.slug(resolved))).")
        }
    }

    struct Relay: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show or set the relay that public URLs come from.",
            discussion: """
            beacon relay --url relay.example.com --token <token>

            The token comes from whoever runs the relay. It's stored readable by \
            root only, and sent to nothing but the relay.
            """
        )

        @Option(name: .long, help: "The relay's domain, e.g. relay.example.com, or a wss:// URL.")
        var url: String?

        @Option(name: .long, help: "Your token for that relay.")
        var token: String?

        @Flag(name: .long, help: "Forget the relay and stop sharing everything.")
        var off = false

        @Flag(name: .long, help: "Print as JSON.")
        var json = false

        func run() throws {
            var status: RelayStatus?
            if off {
                status = BeaconCLI.perform { try BeaconCLI.client.setRelay(RelaySpec(url: "", token: "")) }
            } else if url != nil || token != nil {
                status = BeaconCLI.perform { try BeaconCLI.client.setRelay(RelaySpec(url: url, token: token)) }
                // Give a fresh connection a moment, so the answer says whether the token worked.
                if status?.shares.isEmpty == false {
                    for _ in 0..<25 where status?.state == .connecting {
                        usleep(200_000)
                        status = (try? BeaconCLI.client.relayStatus()) ?? status
                    }
                }
            } else {
                status = BeaconCLI.perform { try BeaconCLI.client.relayStatus() }
            }

            guard let status else { Output.fail("The daemon didn't report the relay's state.") }
            if json {
                Output.json(status)
                return
            }

            print("")
            print("  \(stateLine(status))")
            if let relay = status.url {
                print("  \(label("Relay"))\(relay)")
                print("  \(label("Token"))\(status.hasToken ? "set" + (status.label.map { Output.dim("  (label \($0))") } ?? "") : Output.yellow("not set"))")
            }
            if let error = status.error, status.state != .connected {
                print("  \(label("Problem"))\(Output.yellow(error))")
            }
            if !status.shares.isEmpty {
                print("")
                for share in status.shares {
                    let lock = share.passwordProtected ? Output.dim("  password") : ""
                    if let url = share.publicURL {
                        print("  \(Output.bold(share.name.padding(toLength: 18, withPad: " ", startingAt: 0)))\(url)\(lock)")
                    } else {
                        let note = share.error.map(Output.yellow) ?? Output.dim("waiting for the relay")
                        print("  \(Output.bold(share.name.padding(toLength: 18, withPad: " ", startingAt: 0)))\(note)")
                    }
                }
            }
            print("")
            if status.state == .off {
                print("  Set one up with \(Output.bold("beacon relay --url relay.example.com --token <token>")).")
                print("")
            } else if status.shares.isEmpty {
                print("  Nothing is shared. Share a project with \(Output.bold("beacon share")).")
                print("")
            }
        }

        private func stateLine(_ status: RelayStatus) -> String {
            switch status.state {
            case .off: return "\(Output.dim("○")) No relay configured"
            case .idle: return "\(Output.dim("○")) Relay configured \(Output.dim("· no tunnel open, nothing is shared"))"
            case .connecting: return "\(Output.yellow("●")) Connecting to the relay…"
            case .connected: return "\(Output.green("●")) Connected"
            case .failed: return "\(Output.red("●")) Can't reach the relay \(Output.dim("· retrying"))"
            }
        }

        private func label(_ text: String) -> String {
            Output.dim(text.padding(toLength: 12, withPad: " ", startingAt: 0))
        }
    }
}
