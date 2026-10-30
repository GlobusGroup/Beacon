import ArgumentParser
import BeaconKit
import Foundation

extension BeaconCLI {
    /// Emits the contract an coding agent should follow. The point of Beacon is
    /// that the agent asks for a port instead of inventing one, and then hands
    /// the human the domain instead of a localhost URL — so that instruction
    /// needs to live in the project, not in someone's memory.
    struct AgentGuide: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "agent-guide",
            abstract: "Print instructions to drop into CLAUDE.md or AGENTS.md.",
            discussion: """
            With --write, appends them to the agent instruction file in the \
            current directory, creating it if needed.
            """
        )

        @Option(name: .long, help: "File to append to. Defaults to CLAUDE.md, or AGENTS.md if that exists.")
        var file: String?

        @Flag(name: .long, help: "Write the guide to the file instead of printing it.")
        var write = false

        func run() throws {
            let text = guide()

            guard write else {
                print(text)
                return
            }

            let fm = FileManager.default
            let target = file ?? (fm.fileExists(atPath: "AGENTS.md") ? "AGENTS.md" : "CLAUDE.md")

            var existing = (try? String(contentsOfFile: target, encoding: .utf8)) ?? ""
            if existing.contains("<!-- beacon:start -->") {
                print("\(target) already has Beacon's instructions. Nothing to do.")
                return
            }
            if !existing.isEmpty && !existing.hasSuffix("\n") { existing += "\n" }
            if !existing.isEmpty { existing += "\n" }

            try (existing + text + "\n").write(toFile: target, atomically: true, encoding: .utf8)
            print("Added Beacon's instructions to \(Output.bold(target)).")
        }

        private func guide() -> String {
            let example = (try? BeaconCLI.client.config())?.primaryTLD ?? "test"
            return """
            <!-- beacon:start -->
            ## Local domain and port (Beacon)

            This machine runs Beacon, which owns local domains and hands out reserved ports.
            Never pick a port yourself and never hand the user a `localhost:NNNN` link.

            **Before running the dev server**, ask Beacon for this project's port:

            ```sh
            beacon register --json
            ```

            Run it from the project root. It is idempotent — the same project always
            gets the same port back — so it is safe in a setup script or on every run.
            It prints, for example:

            ```json
            {
              "name": "myproject",
              "domain": "myproject.\(example)",
              "port": 3246,
              "url": "https://myproject.\(example)"
            }
            ```

            Then:

            1. Configure the dev server to listen on `port` (bind `127.0.0.1`).
            2. Give the user **`url`** in every link, message and summary.
               Not `http://localhost:3246`.
            3. Use `url` for anything the app needs to know its own address:
               `APP_URL`, `VITE_DEV_SERVER_URL`, OAuth callbacks, webhook targets.

            Useful one-liners:

            ```sh
            beacon port            # just the number, e.g. 3246
            beacon url             # just the URL, e.g. https://myproject.\(example)
            beacon list            # every project, and which are running
            ```

            If `beacon` is not installed, say so and stop — do not fall back to a
            random port.
            <!-- beacon:end -->
            """
        }
    }
}
