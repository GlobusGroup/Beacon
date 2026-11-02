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
do {
    config = try RelayConfig.fromEnvironment()
} catch {
    FileHandle.standardError.write(Data("beacon-relay: \(error)\n".utf8))
    exit(2)
}
RelayLog.verbose = config.verbose

// One event loop: all routing state lives on it, so nothing needs a lock.
// A relay spends its time copying bytes, which one core does plenty of.
let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
let hub = RelayHub(config: config)

let server = try ServerBootstrap(group: group)
    .serverChannelOption(ChannelOptions.backlog, value: 256)
    .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
    .childChannelOption(ChannelOptions.tcpOption(.tcp_nodelay), value: 1)
    .childChannelInitializer { channel in
        channel.pipeline.addHandler(RelayFrontendHandler(hub: hub, config: config))
    }
    .bind(host: "0.0.0.0", port: config.port)
    .wait()

let labels = config.tokens.map(\.label).joined(separator: ", ")
RelayLog.info("beacon-relay listening on :\(config.port) for \(config.domain) (\(config.publicScheme)). Tokens: \(labels).")

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
