import ArgumentParser
import BeaconKit
import Foundation

extension BeaconCLI {
    /// Emits the contract an coding agent should follow. The point of Beacon is
    /// that the agent asks for a port instead of inventing one, and then hands
    /// the human the domain instead of a localhost URL — so that instruction
    /// needs to live where the agent reads it, not in someone's memory.
    struct AgentGuide: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "agent-guide",
            abstract: "Print instructions to drop into CLAUDE.md or AGENTS.md.",
            discussion: """
            With --write, appends them to the agent instruction file in the \
            current directory, creating it if needed. With --global, appends \
            them to Claude Code's and Codex's user-wide files instead \
            (~/.claude/CLAUDE.md and ~/.codex/AGENTS.md), so every project \
            gets them.
            """
        )

        @Option(name: .long, help: "File to append to. Defaults to CLAUDE.md, or AGENTS.md if that exists.")
        var file: String?

        @Flag(name: .long, help: "Write the guide to the file instead of printing it.")
        var write = false

        @Flag(name: .long, help: "Write the guide for Claude Code and Codex, for every project.")
        var global = false

        func validate() throws {
            if global && file != nil {
                throw ValidationError("--global writes to each agent's own file; leave out --file.")
            }
        }

        func run() throws {
            let tld = (try? BeaconCLI.client.config())?.primaryTLD ?? "test"

            if global {
                try writeGlobal(tld: tld)
                return
            }

            guard write else {
                print(AgentInstructions.text(tld: tld))
                return
            }

            let fm = FileManager.default
            let target = file ?? (fm.fileExists(atPath: "AGENTS.md") ? "AGENTS.md" : "CLAUDE.md")
            switch try AgentInstructions.append(to: target, tld: tld) {
            case .alreadyPresent:
                print("\(target) already has Beacon's instructions. Nothing to do.")
            case .added:
                print("Added Beacon's instructions to \(Output.bold(target)).")
            }
        }

        private func writeGlobal(tld: String) throws {
            let agents = AgentInstructions.globalAgents().filter(\.isInstalled)
            guard !agents.isEmpty else {
                Output.fail("""
                Neither Claude Code (~/.claude) nor Codex (~/.codex) is set up for this user. \
                Run one of them once, or use --write in a project instead.
                """)
            }
            for agent in agents {
                switch try AgentInstructions.append(to: agent.file, tld: tld) {
                case .alreadyPresent:
                    print("\(agent.name): \(agent.file) already has Beacon's instructions.")
                case .added:
                    print("\(agent.name): added Beacon's instructions to \(Output.bold(agent.file)).")
                }
            }
        }
    }
}
