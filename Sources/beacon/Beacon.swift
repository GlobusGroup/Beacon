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
            Unregister.self, Open.self, Status.self, Config.self,
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
            """
        )

        @Argument(help: "Project name. Defaults to the current directory's name.")
        var name: String?

        @Option(name: .shortAndLong, help: "Local domain. Defaults to <name>.test.")
        var domain: String?

        @Option(name: .shortAndLong, help: "Ask for a specific port instead of letting Beacon choose.")
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

        @Flag(name: .long, help: "Print the result as JSON.")
        var json = false

        func run() throws {
            let resolvedName = name ?? FileManager.default.currentDirectoryPath
                .split(separator: "/").last.map(String.init) ?? "project"

            let site = BeaconCLI.perform {
                try BeaconCLI.client.register(RegisterSpec(
                    name: resolvedName,
                    domain: domain,
                    port: port,
                    path: path ?? FileManager.default.currentDirectoryPath,
                    aliases: aliases.isEmpty ? nil : aliases,
                    secure: http ? false : nil,
                    reassign: reassign
                ))
            }

            if json {
                Output.json(site)
            } else {
                Output.describe(site, running: PortProbe.isListening(site.port))
            }
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

enum CurrentDirectory {
    static var name: String {
        FileManager.default.currentDirectoryPath
            .split(separator: "/").last.map(String.init) ?? "project"
    }
}
