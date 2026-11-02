import ArgumentParser
import BeaconKit
import Foundation

// Managing who may use the relay, for whoever holds an admin token. The daemon
// makes the calls with the token it keeps, so it never has to be typed again.

extension BeaconCLI {
    struct RelayTokens: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "tokens",
            abstract: "List everyone who can use the relay. Needs an admin token."
        )

        @OptionGroup var options: Relay.Options

        func run() throws {
            let json = options.json
            let tokens = BeaconCLI.perform { try BeaconCLI.client.relayTokens() }
            if json {
                Output.json(tokens)
                return
            }
            print("")
            for token in tokens {
                let dot = token.connected ? Output.green("●") : Output.dim("○")
                var tags: [String] = []
                if token.admin { tags.append("admin") }
                if token.source == .environment { tags.append("BEACON_TOKENS") }
                let tagText = tags.isEmpty ? "" : Output.dim("  " + tags.joined(separator: " · "))
                print("  \(dot) \(Output.bold(token.label.padding(toLength: 16, withPad: " ", startingAt: 0)))\(token.note ?? "")\(tagText)")
                for url in token.shares {
                    print("      \(Output.dim(url))")
                }
            }
            print("")
        }
    }

    struct RelayInviteCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "invite",
            abstract: "Make a token for someone new, as a .beacon file. Needs an admin token.",
            discussion: """
            Writes <label>.beacon, holding the relay's address and the new token. \
            Send it to them: opening it in Beacon fills in Settings → Sharing. \
            The token isn't shown again, so keep the file until they have it.
            """
        )

        @Argument(help: "Their label, which ends every URL they share: shop-<label>.<domain>.")
        var label: String

        @Option(name: .long, help: "Who it's for, e.g. \"Sam's MacBook\".")
        var note: String?

        @Flag(name: .long, help: "Let them manage tokens too.")
        var admin = false

        @Option(name: [.short, .long], help: "Where to write the file. Defaults to ./<label>.beacon.")
        var output: String?

        func run() throws {
            let invite = BeaconCLI.perform {
                try BeaconCLI.client.createRelayToken(RelayTokenSpec(label: label, note: note, admin: admin))
            }
            let path = output ?? "\(invite.label).\(RelayInvite.fileExtension)"
            BeaconCLI.perform {
                try invite.encoded().write(to: URL(fileURLWithPath: path), options: .atomic)
                chmod(path, 0o600)
            }
            print("")
            print("  \(Output.green("●")) Made a token for \(Output.bold(invite.label))")
            print("  \(Output.dim("File "))      \(path)")
            print("")
            print("  Send them the file. Opening it in Beacon fills in the relay settings.")
            print("")
        }
    }

    struct RelayRevoke: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "revoke",
            abstract: "Revoke someone's token and close their tunnel. Needs an admin token."
        )

        @Argument(help: "The token's label.")
        var label: String

        func run() throws {
            BeaconCLI.perform { try BeaconCLI.client.revokeRelayToken(label: label) }
            print("Revoked \(Output.bold(label)). Their shares are offline.")
        }
    }
}
