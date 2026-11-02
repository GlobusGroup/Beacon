import Foundation

/// The instructions that tell a coding agent to ask Beacon for a port instead
/// of inventing one, and to hand the user the domain instead of a localhost
/// URL, plus the files agents read them from.
///
/// Shared by `beacon agent-guide` and the menu bar app's prompt, so both write
/// exactly the same block, between markers that make writing it idempotent.
public enum AgentInstructions {
    public static let startMarker = "<!-- beacon:start -->"
    public static let endMarker = "<!-- beacon:end -->"

    /// A coding agent with a user-wide instructions file, which it reads in
    /// every project.
    public struct Agent: Hashable, Sendable {
        public let name: String
        /// The agent's own settings directory. It exists once the agent has
        /// been used on this Mac, so that's how Beacon tells it's installed.
        public let directory: String
        public let file: String

        public var isInstalled: Bool {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory) && isDirectory.boolValue
        }

        public var hasInstructions: Bool { AgentInstructions.isPresent(in: file) }
    }

    /// Where an installed agent stands, for showing in the app.
    public struct AgentStatus: Hashable, Sendable {
        public let name: String
        public let file: String
        public let hasInstructions: Bool

        public init(name: String, file: String, hasInstructions: Bool) {
            self.name = name
            self.file = file
            self.hasInstructions = hasInstructions
        }
    }

    /// Claude Code reads `~/.claude/CLAUDE.md` and Codex reads
    /// `$CODEX_HOME/AGENTS.md` (`~/.codex` by default) in every session.
    public static func globalAgents(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [Agent] {
        // $HOME first, as the agents themselves do. NSHomeDirectory() reads the
        // user database and would ignore an overridden HOME.
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        let codexHome = environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.codex"
        return [
            Agent(name: "Claude Code", directory: home + "/.claude", file: home + "/.claude/CLAUDE.md"),
            Agent(name: "Codex", directory: codexHome, file: codexHome + "/AGENTS.md"),
        ]
    }

    /// The installed agents and whether each already has the instructions.
    public static func installedAgents() -> [AgentStatus] {
        globalAgents().filter(\.isInstalled).map {
            AgentStatus(name: $0.name, file: $0.file, hasInstructions: $0.hasInstructions)
        }
    }

    public static func isPresent(in file: String) -> Bool {
        ((try? String(contentsOfFile: file, encoding: .utf8)) ?? "").contains(startMarker)
    }

    public enum WriteResult: Sendable {
        case added
        case alreadyPresent
    }

    /// Appends the instructions to `file`, creating it if needed. Leaves the
    /// file alone if it already has them.
    @discardableResult
    public static func append(to file: String, tld: String) throws -> WriteResult {
        var existing = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
        if existing.contains(startMarker) { return .alreadyPresent }
        if !existing.isEmpty && !existing.hasSuffix("\n") { existing += "\n" }
        if !existing.isEmpty { existing += "\n" }
        try (existing + text(tld: tld) + "\n").write(toFile: file, atomically: true, encoding: .utf8)
        return .added
    }

    public static func text(tld example: String) -> String {
        """
        \(startMarker)
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

        If the project needs one particular port (a hard-coded OAuth callback,
        say), ask for it with `beacon register --port 3000 --json`. If another
        project already holds it, the command exits 1 and prints:

        ```json
        {
          "ok": false,
          "error": {
            "code": "port_taken",
            "message": "Port 3000 is already reserved for 'shop' (shop.\(example)). ...",
            "owner": "shop",
            "port": 3000,
            "suggestedPort": 3001,
            "hint": "beacon register myproject --port 3001 --json"
          }
        }
        ```

        Run `hint`, or drop `--port` and let Beacon choose. Never take a port
        from another project.

        Useful one-liners:

        ```sh
        beacon port            # just the number, e.g. 3246
        beacon url             # just the URL, e.g. https://myproject.\(example)
        beacon list            # every project, and which are running
        ```

        To put the project on a public URL, only when the user asks for it:

        ```sh
        beacon share --json        # → "publicURL": "https://myproject-<label>.<relay domain>"
        beacon share --password '…' --json
        beacon unshare             # when they're done; sharing persists until then
        ```

        It needs a relay set up first (`beacon relay` shows it). If none is, ask
        the user to run `beacon relay --url <domain> --token <token>` themselves,
        and don't guess either value. The dev server must accept the relay's
        domain as a Host (Vite: `server.allowedHosts`).

        If `beacon` is not installed, say so and stop — do not fall back to a
        random port.
        \(endMarker)
        """
    }
}
