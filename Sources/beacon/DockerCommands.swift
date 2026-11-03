import ArgumentParser
import BeaconKit
import Foundation

extension BeaconCLI {
    struct Docker: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Let a Docker Compose project's containers reach Beacon domains.",
            subcommands: [Init.self]
        )
    }
}

// MARK: - docker init

extension BeaconCLI.Docker {
    /// Inside a container `shop.test` resolves to the container's own
    /// loopback, and Beacon's certificate isn't trusted. Rather than ask people
    /// to change Docker's settings, this adds a sidecar to the project: it takes
    /// the domains as network aliases, forwards to Beacon on the Mac, and hands
    /// every service a CA bundle that trusts Beacon. See Sidecar/README.md.
    struct Init: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "init",
            abstract: "Add Beacon's sidecar to the compose project in this directory.",
            discussion: """
            Writes the override file Compose loads on its own, named to match your \
            compose file (compose.override.yaml for compose.yaml, and so on). If you already have \
            an override file of your own, it writes compose.beacon.yml instead and \
            says how to load it. Safe to re-run after adding services or aliases.

            Network aliases can't be wildcards, so subdomains the containers call \
            need --domain.
            """
        )

        @Argument(help: "Project name. Defaults to the current directory's name.")
        var name: String?

        @Option(name: .customLong("service"), parsing: .singleValue,
                help: "Only give this service the domains and trust. Repeatable. Defaults to every service.")
        var services: [String] = []

        @Option(name: .customLong("domain"), parsing: .singleValue,
                help: "Another name to answer for, e.g. api.shop.test. Repeatable.")
        var domains: [String] = []

        @Option(name: .customLong("project"), parsing: .singleValue,
                help: "Another Beacon project the containers call. Repeatable.")
        var projects: [String] = []

        @Option(name: .long, help: "File to write. Defaults to the override file Compose loads on its own.")
        var file: String?

        @Option(name: .long, help: "Sidecar image.")
        var image = Sidecar.defaultImage

        @Flag(name: .long, help: "Print the file instead of writing it.")
        var stdout = false

        @Flag(name: .long, help: "Print the result as JSON.")
        var json = false

        func run() throws {
            let site = BeaconCLI.perform { try BeaconCLI.client.info(name: name ?? CurrentDirectory.name) }
            let others = projects.map { project in BeaconCLI.perform { try BeaconCLI.client.info(name: project) } }
            let names = unique(([site] + others).flatMap { [$0.domain] + $0.aliases } + domains)

            let project = try ComposeProject.load()
            let unknown = services.filter { project.services[$0] == nil }
            if !unknown.isEmpty {
                Output.fail("""
                No service called \(unknown.joined(separator: ", ")) in this compose project. \
                It has: \(project.serviceNames.joined(separator: ", ")).
                """)
            }
            let targets = services.isEmpty ? project.serviceNames : services
            guard !targets.isEmpty else {
                Output.fail("This compose project has no services yet.")
            }

            let status = try? BeaconCLI.client.status()
            let contents = Sidecar.override(
                image: image,
                domains: names,
                services: targets.map { ($0, project.services[$0]!) },
                httpPort: status?.httpPort ?? 80,
                httpsPort: status?.httpsPort ?? 443
            )

            if stdout {
                print(contents, terminator: "")
                return
            }

            let destination = OverrideFile.choose(explicit: file)
            try contents.write(toFile: destination.path, atomically: true, encoding: .utf8)
            let hostMode = targets.filter { project.services[$0]?.networkMode == "host" }

            if json {
                var result: [String: Any] = [
                    "file": destination.path,
                    "image": image,
                    "domains": names,
                    "services": targets,
                    "loadedAutomatically": destination.loadHint == nil,
                ]
                if let hint = destination.loadHint { result["hint"] = hint }
                if !hostMode.isEmpty { result["warnings"] = hostMode.map(hostModeWarning) }
                Output.json(EmptyObject(), adding: result)
                return
            }

            print("Wrote \(Output.bold(destination.path)).")
            print("")
            print("  \(Output.dim("Domains "))  \(names.joined(separator: "  "))")
            print("  \(Output.dim("Services"))  \(targets.joined(separator: "  "))")
            print("")
            if let hint = destination.loadHint {
                print("Compose won't load this file on its own. Start the project with:")
                print("  \(Output.bold(hint))")
            } else {
                print("Start the project as usual (\(Output.bold("docker compose up"))) and the services")
                print("can call \(Output.bold("https://\(site.domain)")) with no -k.")
            }
            hostMode.map(hostModeWarning).forEach(Output.warn)
        }

        private func hostModeWarning(_ service: String) -> String {
            "\(service) uses network_mode: host, so it can't see the sidecar's domains. It still gets the CA bundle."
        }

        private func unique(_ names: [String]) -> [String] {
            var seen = Set<String>()
            return names.map { $0.lowercased() }.filter { seen.insert($0).inserted }
        }
    }
}

private struct EmptyObject: Encodable {}

// MARK: - reading the compose project

/// What `docker compose config` says about the project, which is the only
/// reliable way to read it: it has already merged every file, profile and
/// variable the way `docker compose up` will.
struct ComposeProject {
    struct Service {
        var networks: [String]
        var networkMode: String?
    }

    var services: [String: Service]

    /// Sorted, and without the sidecar itself, which shows up on a re-run once
    /// the override file is loaded.
    var serviceNames: [String] {
        services.keys.filter { $0 != Sidecar.serviceName }.sorted()
    }

    static func load() throws -> ComposeProject {
        let result = Shell.run("/usr/bin/env", ["docker", "compose", "config", "--format", "json"])
        guard result.succeeded else {
            if result.status == 127 || result.message.contains("No such file") {
                Output.fail("Docker isn't installed, or `docker` isn't on your PATH.")
            }
            Output.fail("`docker compose config` failed here:\n\(result.message)")
        }
        guard let object = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any],
              let raw = object["services"] as? [String: [String: Any]]
        else {
            Output.fail("Couldn't read the output of `docker compose config`.")
        }

        var services: [String: Service] = [:]
        for (name, definition) in raw {
            let mode = definition["network_mode"] as? String
            // A service with no networks key is on the project's default network.
            let networks = (definition["networks"] as? [String: Any]).map { Array($0.keys).sorted() }
            services[name] = Service(
                networks: mode == nil ? (networks ?? ["default"]) : [],
                networkMode: mode
            )
        }
        return ComposeProject(services: services)
    }
}

// MARK: - the file

enum Sidecar {
    static let serviceName = "beacon"
    static let volumeName = "beacon-trust"
    static let header = "# Generated by `beacon docker init`"

    /// Tracks Beacon's minor version, so a CLI only ever writes an image that
    /// speaks to the daemon it came with.
    static var defaultImage: String {
        let minor = BeaconPaths.version.split(separator: ".").prefix(2).joined(separator: ".")
        return "ghcr.io/globusgroup/beacon-sidecar:\(minor)"
    }

    static func override(
        image: String, domains: [String], services: [(String, ComposeProject.Service)],
        httpPort: Int, httpsPort: Int
    ) -> String {
        let networks = Array(Set(services.flatMap { $0.1.networks })).sorted()

        var lines = [
            "\(header) (Beacon \(BeaconPaths.version)).",
            "# Re-running it replaces this file, so make changes with its options.",
            "#",
            "# The beacon service answers for \(domains.first ?? "your domains") on the compose network and",
            "# forwards to Beacon on your Mac. Every other service gets a CA bundle in",
            "# /etc/ssl/certs that trusts Beacon's certificate as well as the usual ones.",
            "",
            "services:",
            "  \(serviceName):",
            "    image: \(image)",
            "    restart: unless-stopped",
            "    extra_hosts:",
            "      - \"host.docker.internal:host-gateway\"",
        ]
        if httpPort != 80 || httpsPort != 443 {
            lines += [
                "    environment:",
                "      BEACON_HTTP_PORT: \"\(httpPort)\"",
                "      BEACON_HTTPS_PORT: \"\(httpsPort)\"",
            ]
        }
        lines += [
            "    volumes:",
            "      - \(volumeName):/trust",
            "    networks:",
        ]
        for network in networks.isEmpty ? ["default"] : networks {
            lines += ["      \(network):", "        aliases:"]
            lines += domains.map { "          - \"\($0)\"" }
        }

        for (name, _) in services {
            lines += [
                "",
                "  \(name):",
                "    depends_on:",
                "      \(serviceName):",
                "        condition: service_healthy",
                // nocopy: otherwise whichever service Compose creates first
                // copies its own certificates into the empty volume, as root.
                "    volumes:",
                "      - type: volume",
                "        source: \(volumeName)",
                "        target: /etc/ssl/certs",
                "        read_only: true",
                "        volume:",
                "          nocopy: true",
                "    environment:",
                // Runtimes that keep their own list of roots instead of the system's.
                "      NODE_EXTRA_CA_CERTS: /etc/ssl/certs/beacon-ca.pem",
                "      REQUESTS_CA_BUNDLE: /etc/ssl/certs/ca-certificates.crt",
                "      SSL_CERT_FILE: /etc/ssl/certs/ca-certificates.crt",
            ]
        }

        lines += ["", "volumes:", "  \(volumeName):", ""]
        return lines.joined(separator: "\n")
    }
}

/// Where the generated file goes. Compose only picks an override file up by
/// itself when it's named after the compose file and COMPOSE_FILE isn't set;
/// anywhere else, the caller needs telling how to load it.
struct OverrideFile {
    var path: String
    var loadHint: String?

    static let composeFiles = ["compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml"]
    static let fallback = "compose.beacon.yml"

    static func choose(explicit: String?) -> OverrideFile {
        let fm = FileManager.default
        let environment = ProcessInfo.processInfo.environment["COMPOSE_FILE"]
        let base = composeFiles.first(where: fm.fileExists(atPath:))
        guard environment != nil || base != nil else {
            Output.fail("There's no compose file in this directory. Run this where compose.yaml is.")
        }

        let automatic = base.map {
            ($0 as NSString).deletingPathExtension + ".override." + ($0 as NSString).pathExtension
        }
        let path: String
        if let explicit {
            path = explicit
        } else if environment == nil, let automatic, !fm.fileExists(atPath: automatic) || isOurs(automatic) {
            path = automatic
        } else {
            path = fallback
        }

        // What Compose reads today, which the new file has to be added to.
        let current: String
        if let environment {
            current = environment
        } else if let base, let automatic, fm.fileExists(atPath: automatic), automatic != path {
            current = "\(base):\(automatic)"
        } else {
            current = base ?? ""
        }
        let loaded = environment.map { $0.split(separator: ":").contains(Substring(path)) } ?? (path == automatic)
        return OverrideFile(path: path, loadHint: loaded ? nil : "COMPOSE_FILE=\(current):\(path) docker compose up")
    }

    private static func isOurs(_ path: String) -> Bool {
        (try? String(contentsOfFile: path, encoding: .utf8))?.hasPrefix(Sidecar.header) ?? false
    }
}
