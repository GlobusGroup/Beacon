import ArgumentParser
import BeaconKit
import Foundation

@main
struct BeaconCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "beacon",
        abstract: "Local domains and reserved ports for your projects.",
        discussion: """
        Beacon gives every project a stable local domain and a port that never \
        changes. Ask for one with `beacon register`, point your dev server at the \
        port it hands back, and share the domain.
        """,
        version: BeaconPaths.version,
        subcommands: [
            Register.self, List.self, Info.self, Port.self, URLCommand.self,
            Unregister.self, Open.self, Start.self, Stop.self, Logs.self, Share.self, Unshare.self, Relay.self, Docker.self,
            Status.self, Config.self,
            Install.self, Uninstall.self, Restart.self, Trust.self, AgentGuide.self,
        ],
        defaultSubcommand: List.self
    )

    static let client = BeaconClient()

    /// Every command funnels failures through here so the CLI never dumps a
    /// Swift error description at someone.
    static func perform<T>(_ work: () throws -> T) -> T {
        do {
            return try work()
        } catch let error as BeaconClientError {
            Output.fail(error.message)
        } catch {
            Output.fail(error.localizedDescription)
        }
    }
}

// MARK: - register

extension BeaconCLI {
    struct Register: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Claim a local domain and a reserved port for a project.",
            discussion: """
            Safe to run repeatedly: the same project name always gets the same \
            port back, so this can live in a setup script.

            With no name, the current directory's name is used.

            --port asks for a specific port. Beacon accepts it unless another \
            project already holds it (error code port_taken) or Beacon itself \
            listens on it (port_reserved_by_beacon). Either way the error names \
            a free port to ask for instead. With --json, errors are printed to \
            stdout as {"ok": false, "error": {"code", "message", "hint", ...}} \
            and the exit status is 1.
            """
        )

        @Argument(help: "Project name. Defaults to the current directory's name.")
        var name: String?

        @Option(name: .shortAndLong, help: "Local domain. Defaults to <name>.test.")
        var domain: String?

        @Option(name: .shortAndLong, help: "Ask for a specific port. Refused if another project already holds it.")
        var port: Int?

        @Option(help: "Project directory. Defaults to the current directory.")
        var path: String?

        @Option(name: .customLong("alias"), parsing: .singleValue,
                help: "Extra domain routed to the same port. Repeatable.")
        var aliases: [String] = []

        @Flag(name: .long, help: "Hand out http:// links instead of https://.")
        var http = false

        @Flag(name: .long, help: "Allocate a fresh port even if this project already has one.")
        var reassign = false

        @Option(name: .customLong("run"), help: ArgumentHelp(
            "Command that starts the project, run in its directory with $PORT set. 'auto' goes back to detecting it.",
            valueName: "command"
        ))
        var runCommand: String?

        @Flag(name: .long, help: "Print the result as JSON.")
        var json = false

        func run() throws {
            let resolvedName = name ?? CurrentDirectory.name
            let previous = try? BeaconCLI.client.info(name: resolvedName)

            let site: Site
            do {
                site = try BeaconCLI.client.register(RegisterSpec(
                    name: resolvedName,
                    domain: domain,
                    port: port,
                    path: path ?? FileManager.default.currentDirectoryPath,
                    aliases: aliases.isEmpty ? nil : aliases,
                    secure: http ? false : nil,
                    reassign: reassign,
                    run: runCommand
                ))
            } catch let error as BeaconClientError {
                let hint = retryHint(for: error, name: resolvedName)
                if json { Output.failJSON(error, hint: hint) }
                Output.fail(error.message + (hint.map { "\n  try: \($0)" } ?? ""))
            } catch {
                let wrapped = BeaconClientError(code: "error", message: error.localizedDescription)
                if json { Output.failJSON(wrapped) }
                Output.fail(wrapped.message)
            }

            let running = PortProbe.isListening(site.port)
            let warnings = warnings(for: site, previous: previous, running: running)

            if json {
                var extra: [String: Any] = [:]
                if let previous, previous.port != site.port { extra["previousPort"] = previous.port }
                if !warnings.isEmpty { extra["warnings"] = warnings }
                Output.json(site, adding: extra)
            } else {
                if let previous, previous.port != site.port {
                    print("Moved \(Output.bold(site.name)) from port \(previous.port) to \(Output.bold(String(site.port))).")
                }
                Output.describe(site, running: running)
                warnings.forEach(Output.warn)
            }
        }

        /// A command that should succeed where this one didn't, spelled out so
        /// an agent can run it rather than reason about the error text.
        private func retryHint(for error: BeaconClientError, name: String) -> String? {
            switch error.code {
            case "port_taken", "port_reserved_by_beacon":
                guard let suggested = error.details?["suggestedPort"] else {
                    return "beacon register \(name) --json"
                }
                return "beacon register \(name) --port \(suggested) --json"
            case "bad_port":
                return "beacon register \(name) --json"
            default:
                return nil
            }
        }

        private func warnings(for site: Site, previous: Site?, running: Bool) -> [String] {
            var warnings: [String] = []
            if site.port < 1024 {
                warnings.append(
                    "Port \(site.port) is below 1024; most dev servers can't bind it without root."
                )
            }
            // A listener on a port this project only just claimed is probably
            // someone else's server, and the domain will show it.
            if running, previous?.port != site.port {
                warnings.append("""
                Something is already listening on port \(site.port). If it isn't this project's \
                dev server, stop it, or \(site.domain) will show the wrong app.
                """)
            }
            return warnings
        }
    }
}

// MARK: - reading

extension BeaconCLI {
    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show every registered project.")

        @Flag(name: .long, help: "Print as JSON.")
        var json = false

        func run() throws {
            let sites = BeaconCLI.perform { try BeaconCLI.client.list() }
            if json { Output.json(sites) } else { SiteTable.render(sites) }
        }
    }

    struct Info: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show one project's domain and port.")

        @Argument(help: "Project name.")
        var name: String

        @Flag(name: .long, help: "Print as JSON.")
        var json = false

        func run() throws {
            let site = BeaconCLI.perform { try BeaconCLI.client.info(name: name) }
            if json {
                Output.json(site)
            } else {
                Output.describe(site, running: PortProbe.isListening(site.port))
            }
        }
    }

    /// Bare value commands, for `PORT=$(beacon port shop) npm run dev`.
    struct Port: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print just the port number, for use in scripts."
        )

        @Argument(help: "Project name. Defaults to the current directory's name.")
        var name: String?

        func run() throws {
            let site = BeaconCLI.perform {
                try BeaconCLI.client.info(name: name ?? CurrentDirectory.name)
            }
            print(site.port)
        }
    }

    struct URLCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "url",
            abstract: "Print just the project's URL, for use in scripts."
        )

        @Argument(help: "Project name. Defaults to the current directory's name.")
        var name: String?

        func run() throws {
            let site = BeaconCLI.perform {
                try BeaconCLI.client.info(name: name ?? CurrentDirectory.name)
            }
            print(site.url)
        }
    }

    struct Open: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Open the project in your browser.")

        @Argument(help: "Project name. Defaults to the current directory's name.")
        var name: String?

        func run() throws {
            let site = BeaconCLI.perform {
                try BeaconCLI.client.info(name: name ?? CurrentDirectory.name)
            }
            if !PortProbe.isListening(site.port) {
                FileHandle.standardError.write(Data(
                    (Output.yellow("warning: ")
                     + "nothing is listening on port \(site.port) yet.\n").utf8
                ))
            }
            Shell.run("/usr/bin/open", [site.url])
        }
    }

    struct Unregister: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Release a project's domain and port."
        )

        @Argument(help: "Project name.")
        var name: String

        func run() throws {
            BeaconCLI.perform { try BeaconCLI.client.unregister(name: name) }
            print("Released \(Output.bold(name)).")
        }
    }
}

// MARK: - running projects

extension BeaconCLI {
    struct Start: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Start a project with its run command and wait until it's up.",
            discussion: """
            Beacon runs the command as you, in the project directory, with $PORT \
            set to the project's port. Without --run on `beacon register`, the \
            command is detected: Docker Compose, a package.json dev script, \
            Laravel, Rails or Django.
            """
        )

        @Argument(help: "Project name. Defaults to the current directory's name.")
        var name: String?

        @Flag(name: .long, help: "Return as soon as the start is under way.")
        var noWait = false

        func run() throws {
            let project = name ?? CurrentDirectory.name
            var status = BeaconCLI.perform { try BeaconCLI.client.start(name: project) }
            if let command = status?.command {
                print(Output.dim("$ ") + command)
            }
            guard !noWait else { return }

            var shown = 0
            while let current = status, current.state == .starting {
                usleep(500_000)
                status = BeaconCLI.perform { try BeaconCLI.client.runStatus(name: project) }
                // The daemon only keeps the tail, so print what's new in it.
                let log = status?.log ?? []
                let fresh = log.count >= shown ? Array(log.suffix(from: min(shown, log.count))) : log
                for line in fresh { print(Output.dim("  │ ") + line) }
                shown = log.count
            }

            switch status?.state {
            case .running:
                let site = BeaconCLI.perform { try BeaconCLI.client.info(name: project) }
                print(Output.green("●") + " \(Output.bold(site.name)) is up at \(Output.bold(site.url))")
            case .failed:
                Output.fail(status?.message ?? "It didn't start.")
            default:
                Output.fail("It stopped before coming up.")
            }
        }
    }

    struct Stop: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Stop a project Beacon started, or its containers."
        )

        @Argument(help: "Project name. Defaults to the current directory's name.")
        var name: String?

        func run() throws {
            let project = name ?? CurrentDirectory.name
            BeaconCLI.perform { try BeaconCLI.client.stop(name: project) }
            print("Stopping \(Output.bold(project)).")
        }
    }

    struct Logs: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show the output of a project Beacon started.",
            discussion: """
            In a terminal it keeps following the output until you press Ctrl-C. \
            Anywhere else (a script, an agent) it prints the last lines and exits, \
            since nobody is there to stop it.
            """
        )

        @Argument(help: "Project name. Defaults to the current directory's name.")
        var name: String?

        @Option(name: [.customShort("n"), .long], help: "How many lines to show.")
        var lines = 100

        @Flag(inversion: .prefixedNo, help: "Keep following new output. Defaults to on in a terminal, off otherwise.")
        var follow: Bool?

        func run() throws {
            let site = BeaconCLI.perform {
                try BeaconCLI.client.info(name: name ?? CurrentDirectory.name)
            }
            let file = BeaconPaths.projectLog(for: site.name)
            guard FileManager.default.fileExists(atPath: file) else {
                Output.fail("Beacon hasn't started \(site.name) yet, so there's no output to show.")
            }
            let tail = Process()
            tail.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
            let following = follow ?? (isatty(STDOUT_FILENO) == 1)
            tail.arguments = ["-n", String(max(lines, 0))] + (following ? ["-f"] : []) + [file]
            try tail.run()
            tail.waitUntilExit()
        }
    }
}

enum CurrentDirectory {
    static var name: String {
        FileManager.default.currentDirectoryPath
            .split(separator: "/").last.map(String.init) ?? "project"
    }
}
