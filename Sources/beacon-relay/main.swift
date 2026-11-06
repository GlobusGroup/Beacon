import BeaconTunnel
import Foundation
import NIOCore
import NIOPosix

// beacon-relay: the public end of Beacon's tunnels.
//
// Configured entirely by environment (see RelayConfig). Serves plain HTTP and
// expects a proxy in front of it — Traefik, in the supplied compose file — to
// terminate TLS for the apex and its wildcard.

setvbuf(stdout, nil, _IOLBF, 0)

let config: RelayConfig
let tokens: RelayTokens
do {
    config = try RelayConfig.fromEnvironment()
    tokens = try RelayTokens(config: config)
} catch {
    FileHandle.standardError.write(Data("beacon-relay: \(error)\n".utf8))
    exit(2)
}
RelayLog.verbose = config.verbose

// The website on the apex, unless BEACON_HOME=card. A missing site isn't
// fatal: the relay's job is the tunnels, so it falls back to the card.
let site: RelaySite?
if config.home == .site {
    do {
        site = try RelaySite(directory: config.siteDir)
    } catch {
        RelayLog.warn("Showing the plain card on \(config.domain): \(error)")
        site = nil
    }
} else {
    site = nil
}

// One event loop: all routing state lives on it, so nothing needs a lock.
// A relay spends its time copying bytes, which one core does plenty of.
let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
let hub = RelayHub(config: config)

let server = try ServerBootstrap(group: group)
    .serverChannelOption(ChannelOptions.backlog, value: 256)
    .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
    .childChannelOption(ChannelOptions.tcpOption(.tcp_nodelay), value: 1)
    .childChannelInitializer { channel in
        channel.pipeline.addHandler(RelayFrontendHandler(hub: hub, config: config, tokens: tokens, site: site))
    }
    .bind(host: "0.0.0.0", port: config.port)
    .wait()

let labels = config.tokens.map { config.admins.contains($0.label) ? "\($0.label) (admin)" : $0.label }.joined(separator: ", ")
RelayLog.info("beacon-relay listening on :\(config.port) for \(config.domain) (\(config.publicScheme)). Tokens: \(labels), plus \(tokens.count - config.tokens.count) created in \(config.dataDir). Home page: \(site.map { "website, \($0.fileCount) files from \($0.directory)" } ?? "card").")

let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termination.setEventHandler {
    RelayLog.info("Shutting down.")
    exit(0)
}
termination.resume()
signal(SIGTERM, SIG_IGN)
signal(SIGPIPE, SIG_IGN)

_ = server
dispatchMain()
