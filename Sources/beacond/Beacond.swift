import ArgumentParser
import BeaconKit
import Foundation
import NIOCore
import NIOPosix

@main
struct Beacond: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "beacond",
        abstract: "Beacon's background service: DNS, reverse proxy and the project registry.",
        version: BeaconPaths.version,
        subcommands: [Run.self, WritePlist.self],
        defaultSubcommand: Run.self
    )
}

extension Beacond {
    struct Run: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Run the daemon in the foreground.")

        @Option(name: .long, help: "Port for plain HTTP.")
        var httpPort: Int = 80

        @Option(name: .long, help: "Port for HTTPS.")
        var httpsPort: Int = 443

        @Option(name: .long, help: "Port the DNS responder listens on.")
        var dnsPort: Int = 53535

        @Flag(name: .shortAndLong, help: "Log every DNS query and proxied request.")
        var verbose = false

        func run() throws {
            Log.verbose = verbose
            Log.info("Beacon \(BeaconPaths.version) starting (pid \(getpid())).")

            if !BeaconInstaller.isRoot && (httpPort < 1024 || httpsPort < 1024) {
                Log.warn("Not running as root — binding ports \(httpPort)/\(httpsPort) will fail.")
            }

            let registry = Registry()
            registry.daemonPorts = [httpPort, httpsPort, dnsPort]
            let routes = RouteTable()
            let tls = TLSContextBox()
            let runner = ProjectRunner()

            try prepare(registry: registry, routes: routes, tls: tls)

            let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
            defer { try? group.syncShutdownGracefully() }
            let tunnel = TunnelClient(group: group, registry: registry)

            // Reissue certificates and refresh routing whenever a project is
            // added, removed or moved to a different domain.
            registry.onChange = { snapshot in
                routes.update(from: snapshot)
                refreshCertificates(for: snapshot, tls: tls)
                if BeaconInstaller.isRoot {
                    BeaconInstaller.syncResolvers(tlds: snapshot.config.tlds, dnsPort: dnsPort)
                }
            }

            var channels: [Channel] = []
            channels += try DNSServer(group: group, port: dnsPort).start()
            channels += try ProxyServer(
                group: group, routes: routes, tls: tls, runner: runner,
                httpPort: httpPort, httpsPort: httpsPort
            ).start()
            channels.append(try ControlServer(
                group: group,
                service: ControlService(
                    registry: registry,
                    runner: runner,
                    tunnel: tunnel,
                    httpPort: httpPort,
                    httpsPort: httpsPort,
                    dnsPort: dnsPort
                ),
                path: BeaconPaths.socketPath
            ).start())

            tunnel.start()
            Log.info("Ready. \(registry.allSites.count) project(s) routed.")

            // launchd sends SIGTERM; tidy the socket so the next start is clean.
            let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
            termination.setEventHandler {
                Log.info("Shutting down.")
                try? FileManager.default.removeItem(atPath: BeaconPaths.socketPath)
                Beacond.exit()
            }
            termination.resume()
            signal(SIGTERM, SIG_IGN)
            signal(SIGPIPE, SIG_IGN)

            dispatchMain()
        }

        /// One-time setup before any listener opens.
        private func prepare(registry: Registry, routes: RouteTable, tls: TLSContextBox) throws {
            let snapshot = registry.snapshot
            routes.update(from: snapshot)

            _ = try CertificateAuthority.loadOrCreateRoot()
            refreshCertificates(for: snapshot, tls: tls)

            guard BeaconInstaller.isRoot else {
                Log.warn("Not root: skipping resolver and keychain setup.")
                return
            }

            let installed = BeaconInstaller.syncResolvers(
                tlds: snapshot.config.tlds, dnsPort: dnsPort
            )
            Log.info("Resolvers installed for: \(installed.map { ".\($0)" }.joined(separator: " "))")

            // Trusting the root is deliberately not attempted here. It needs
            // the Security Agent, which has no session to draw in from a
            // daemon; `beacon trust` and the menu bar app do it instead.
            if !BeaconInstaller.isCATrusted() {
                Log.warn("Root certificate isn't trusted yet — run `beacon trust`.")
            }
        }

        private func refreshCertificates(for snapshot: RegistrySnapshot, tls: TLSContextBox) {
            let domains = snapshot.sites.flatMap(\.allDomains)
            do {
                let material = try CertificateAuthority.material(for: domains)
                try tls.update(material)
            } catch {
                Log.error("Couldn't prepare TLS material: \(error)")
            }
        }
    }

    struct WritePlist: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "write-plist",
            abstract: "Print the launchd property list to stdout."
        )

        func run() throws {
            print(BeaconInstaller.launchDaemonPlist())
        }
    }
}
