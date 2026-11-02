import Foundation

/// How to bring a project up: the shell command to run in its directory, and
/// what to expect from it.
///
/// Every command runs with `PORT` (and `BEACON_PORT`) set to the project's
/// reserved port, so a dev server that honours `$PORT` lands where the proxy
/// is already pointing without any flags.
public struct RunSpec: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case dockerCompose
        case dockerComposeAndNode
        case node
        case laravel
        case rails
        case django
        case custom
    }

    public var kind: Kind
    /// A shell command, run with the project directory as its working directory.
    public var command: String
    /// The command exits once the project is up (`docker compose up -d`), so
    /// a clean exit means "now wait for the port" rather than "it stopped".
    public var detached: Bool
    /// Run to bring a detached project down again.
    public var stopCommand: String?
    /// A rough first guess at start-up time, in seconds, until Beacon has
    /// timed a real start. Only drives the progress bar.
    public var expectedSeconds: Double

    public init(
        kind: Kind,
        command: String,
        detached: Bool = false,
        stopCommand: String? = nil,
        expectedSeconds: Double = 10
    ) {
        self.kind = kind
        self.command = command
        self.detached = detached
        self.stopCommand = stopCommand
        self.expectedSeconds = expectedSeconds
    }

    /// A user-supplied command. Treated as a foreground dev server.
    public static func custom(_ command: String) -> RunSpec {
        RunSpec(kind: .custom, command: command, expectedSeconds: 15)
    }

    /// What to call it in a sentence: "Docker Compose", "npm".
    public var label: String {
        switch kind {
        case .dockerCompose: return "Docker Compose"
        case .dockerComposeAndNode: return "Docker Compose and Node"
        case .node: return "Node"
        case .laravel: return "Laravel"
        case .rails: return "Rails"
        case .django: return "Django"
        case .custom: return "custom command"
        }
    }
}

/// Works out how a project runs by looking at the files in its directory.
///
/// Guesses only from things that are unambiguous — a compose file, a
/// `package.json` with a `dev` script, `artisan`, `bin/rails`, `manage.py`.
/// Anything else needs an explicit `beacon register --run "<command>"`.
public enum RunDetector {
    public static func detect(in path: String, port: Int) -> RunSpec? {
        let fm = FileManager.default
        func exists(_ file: String) -> Bool { fm.fileExists(atPath: path + "/" + file) }

        let compose = ["compose.yaml", "compose.yml", "docker-compose.yml", "docker-compose.yaml"]
            .first(where: exists)
        let node = nodeCommand(in: path)

        if let compose {
            let composeUp = "docker compose -f \(compose) up -d"
            let composeStop = "docker compose -f \(compose) stop"
            // When the compose file publishes the project's port, the app
            // itself is a container. Otherwise compose is usually the database
            // and friends, and the app is the Node server alongside it.
            if let node, !composePublishes(port: port, file: path + "/" + compose) {
                return RunSpec(
                    kind: .dockerComposeAndNode,
                    command: "\(composeUp) && \(node.command)",
                    stopCommand: composeStop,
                    expectedSeconds: node.expectedSeconds + 15
                )
            }
            return RunSpec(
                kind: .dockerCompose,
                command: composeUp,
                detached: true,
                stopCommand: composeStop,
                expectedSeconds: 45
            )
        }

        if let node { return node }

        if exists("artisan") {
            return RunSpec(kind: .laravel, command: "php artisan serve --host=127.0.0.1 --port=$PORT", expectedSeconds: 4)
        }
        if exists("bin/dev") && exists("bin/rails") {
            // Foreman and Overmind both honour $PORT for the web process.
            return RunSpec(kind: .rails, command: "bin/dev", expectedSeconds: 12)
        }
        if exists("bin/rails") {
            return RunSpec(kind: .rails, command: "bin/rails server -b 127.0.0.1 -p $PORT", expectedSeconds: 10)
        }
        if exists("manage.py") {
            let python = exists(".venv/bin/python") ? ".venv/bin/python"
                : exists("venv/bin/python") ? "venv/bin/python" : "python3"
            return RunSpec(kind: .django, command: "\(python) manage.py runserver 127.0.0.1:$PORT", expectedSeconds: 6)
        }
        return nil
    }

    /// `npm run dev`, or whichever package manager the lockfile points at,
    /// with a port flag for dev servers known to ignore `$PORT`.
    static func nodeCommand(in path: String) -> RunSpec? {
        let fm = FileManager.default
        guard let data = fm.contents(atPath: path + "/package.json"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = json["scripts"] as? [String: String]
        else { return nil }

        guard let script = ["dev", "start", "serve"].first(where: { scripts[$0] != nil }),
              let body = scripts[script]
        else { return nil }

        func exists(_ file: String) -> Bool { fm.fileExists(atPath: path + "/" + file) }
        let manager: String
        if exists("bun.lockb") || exists("bun.lock") {
            manager = "bun"
        } else if exists("pnpm-lock.yaml") {
            manager = "pnpm"
        } else if exists("yarn.lock") {
            manager = "yarn"
        } else {
            manager = "npm"
        }

        // Vite, Astro and Nuxt pick their own port unless told; Next, CRA and
        // most Express apps read $PORT. Vite may also bind only ::1 for
        // "localhost", which the proxy (dialling 127.0.0.1) can't reach.
        // Only npm needs `--` to pass flags on.
        var flags = ""
        if body.contains("vite") {
            flags = "--host 127.0.0.1 --port $PORT --strictPort"
        } else if body.contains("astro") || body.contains("nuxt") {
            flags = "--port $PORT"
        }
        if !flags.isEmpty && manager == "npm" { flags = "-- " + flags }

        var command = "\(manager) run \(script)" + (flags.isEmpty ? "" : " " + flags)
        var expected = body.contains("next") ? 15.0 : 8.0
        if !exists("node_modules") {
            command = "\(manager) install && " + command
            expected += 30
        }
        return RunSpec(kind: .node, command: command, expectedSeconds: expected)
    }

    /// A compose file "publishes" the port if it maps it explicitly or maps
    /// `$PORT` / `$BEACON_PORT`, which Beacon sets for every command it runs.
    private static func composePublishes(port: Int, file: String) -> Bool {
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return false }
        return text.contains("\(port):")
            || text.contains("${PORT")
            || text.contains("${BEACON_PORT")
            || text.contains("$PORT:")
            || text.contains("$BEACON_PORT:")
    }
}

/// Where a project's start-up stands, as reported to the CLI, the app and the
/// "isn't running" page.
public struct RunStatus: Codable, Sendable {
    public enum State: String, Codable, Sendable {
        /// Nothing listening, and Beacon isn't trying to change that.
        case stopped
        case starting
        case running
        case failed
    }

    public var name: String
    public var state: State
    /// The command Beacon runs (or would run) for this project, if it knows one.
    public var command: String?
    public var label: String?
    /// One short line on what's happening now.
    public var phase: String?
    public var message: String?
    public var startedAt: Date?
    public var elapsed: Double?
    public var expectedSeconds: Double?
    /// The tail of the command's output.
    public var log: [String]
    public var logFile: String?

    public init(
        name: String, state: State, command: String? = nil, label: String? = nil,
        phase: String? = nil, message: String? = nil, startedAt: Date? = nil,
        elapsed: Double? = nil, expectedSeconds: Double? = nil,
        log: [String] = [], logFile: String? = nil
    ) {
        self.name = name
        self.state = state
        self.command = command
        self.label = label
        self.phase = phase
        self.message = message
        self.startedAt = startedAt
        self.elapsed = elapsed
        self.expectedSeconds = expectedSeconds
        self.log = log
        self.logFile = logFile
    }
}
