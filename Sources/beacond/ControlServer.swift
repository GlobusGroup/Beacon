import BeaconKit
import Foundation
import NIOCore
import NIOPosix

/// Answers requests from the `beacon` CLI and the menu bar app.
final class ControlService: @unchecked Sendable {
    private let registry: Registry
    private let runner: ProjectRunner
    private let tunnel: TunnelClient
    private let startedAt = Date()
    private let httpPort: Int
    private let httpsPort: Int
    private let dnsPort: Int

    init(
        registry: Registry, runner: ProjectRunner, tunnel: TunnelClient,
        httpPort: Int, httpsPort: Int, dnsPort: Int
    ) {
        self.registry = registry
        self.runner = runner
        self.tunnel = tunnel
        self.httpPort = httpPort
        self.httpsPort = httpsPort
        self.dnsPort = dnsPort
    }

    /// Requests that wait on the network, and so mustn't run on an event loop.
    static func blocks(_ op: BeaconRequest.Op) -> Bool {
        [.relayTokens, .createRelayToken, .revokeRelayToken].contains(op)
    }

    func handle(_ request: BeaconRequest) -> BeaconResponse {
        do {
            switch request.op {
            case .ping:
                return BeaconResponse()

            case .status:
                return BeaconResponse(status: DaemonStatus(
                    version: BeaconPaths.version,
                    pid: getpid(),
                    httpPort: httpPort,
                    httpsPort: httpsPort,
                    dnsPort: dnsPort,
                    tlds: registry.currentConfig.tlds,
                    resolversInstalled: BeaconInstaller.installedResolvers(),
                    siteCount: registry.allSites.count,
                    startedAt: startedAt
                ))

            case .list:
                return BeaconResponse(sites: registry.allSites)

            case .info:
                guard let name = request.name else {
                    return .failure("missing_name", "Which project?")
                }
                guard let site = registry.site(named: name) else {
                    return .failure("unknown_site", "No project named '\(name)'.")
                }
                return BeaconResponse(site: site)

            case .register:
                guard let spec = request.register else {
                    return .failure("missing_spec", "No registration details were sent.")
                }
                return BeaconResponse(site: try registry.register(spec))

            case .unregister:
                guard let name = request.name else {
                    return .failure("missing_name", "Which project?")
                }
                return BeaconResponse(site: try registry.unregister(name: name))

            case .getConfig:
                return BeaconResponse(config: registry.currentConfig)

            case .restart:
                // Answer first, then exit; launchd's KeepAlive restarts us.
                // This is why restarting needs no authorisation at all.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    Log.info("Restart requested; exiting for launchd to respawn.")
                    try? FileManager.default.removeItem(atPath: BeaconPaths.socketPath)
                    exit(0)
                }
                return BeaconResponse()

            case .start, .stop, .runStatus:
                guard let name = request.name else {
                    return .failure("missing_name", "Which project?")
                }
                guard let site = registry.site(named: name) else {
                    return .failure("unknown_site", "No project named '\(name)'.")
                }
                switch request.op {
                case .start: return BeaconResponse(run: try runner.start(site))
                case .stop: return BeaconResponse(run: runner.stop(site))
                default: return BeaconResponse(run: runner.status(for: site))
                }

            case .share:
                guard let spec = request.share else {
                    return .failure("missing_share", "Which project?")
                }
                return BeaconResponse(relay: try tunnel.share(spec))

            case .unshare:
                guard let name = request.name else {
                    return .failure("missing_name", "Which project?")
                }
                return BeaconResponse(relay: try tunnel.unshare(name))

            case .relayStatus:
                return BeaconResponse(relay: tunnel.currentStatus)

            case .setRelay:
                guard let spec = request.relay else {
                    return .failure("missing_relay", "No relay settings were sent.")
                }
                return BeaconResponse(relay: try tunnel.setRelay(spec))

            case .relayTokens:
                return BeaconResponse(relayTokens: try tunnel.adminClient().list())

            case .createRelayToken:
                guard let spec = request.relayToken else {
                    return .failure("missing_token_spec", "Who is the token for?")
                }
                return BeaconResponse(invite: try tunnel.adminClient().create(spec))

            case .revokeRelayToken:
                guard let name = request.name else {
                    return .failure("missing_name", "Which token?")
                }
                try tunnel.adminClient().revoke(name)
                return BeaconResponse()

            case .setConfig:
                guard let config = request.config else {
                    return .failure("missing_config", "No configuration was sent.")
                }
                return BeaconResponse(config: try registry.updateConfig(config))
            }
        } catch let error as BeaconClientError {
            return .failure(error.code, error.message, details: error.details)
        } catch {
            return .failure("internal_error", error.localizedDescription)
        }
    }
}

final class ControlHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let service: ControlService
    private var pending = ByteBuffer()

    init(service: ControlService) {
        self.service = service
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        pending.writeBuffer(&incoming)

        // Requests are newline-delimited JSON, one per line.
        while let newline = pending.readableBytesView.firstIndex(of: 0x0A) {
            let length = newline - pending.readableBytesView.startIndex
            guard let line = pending.readSlice(length: length) else { break }
            pending.moveReaderIndex(forwardBy: 1)
            pending.discardReadBytes()
            respond(to: line, context: context)
        }

        if pending.readableBytes > 1 << 20 {
            context.close(promise: nil)
        }
    }

    private func respond(to line: ByteBuffer, context: ChannelHandlerContext) {
        let bytes = line.getBytes(at: line.readerIndex, length: line.readableBytes) ?? []
        let request: BeaconRequest
        do {
            request = try BeaconJSON.decoder.decode(BeaconRequest.self, from: Data(bytes))
        } catch {
            write(.failure("bad_request", "Couldn't decode that request: \(error.localizedDescription)"), context: context)
            return
        }

        guard ControlService.blocks(request.op) else {
            write(service.handle(request), context: context)
            return
        }
        let service = self.service
        let loop = context.eventLoop
        nonisolated(unsafe) let context = context
        DispatchQueue.global().async {
            let response = service.handle(request)
            loop.execute { self.write(response, context: context) }
        }
    }

    private func write(_ response: BeaconResponse, context: ChannelHandlerContext) {
        guard var payload = try? BeaconJSON.encoder.encode(response) else {
            context.close(promise: nil)
            return
        }
        payload.append(0x0A)

        var out = context.channel.allocator.buffer(capacity: payload.count)
        out.writeBytes(payload)
        context.writeAndFlush(wrapOutboundOut(out), promise: nil)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        Log.debug("Control error: \(error)")
        context.close(promise: nil)
    }
}

struct ControlServer {
    let group: EventLoopGroup
    let service: ControlService
    let path: String

    func start() throws -> Channel {
        // launchd restarts can leave the old socket file behind.
        try? FileManager.default.removeItem(atPath: path)

        let channel = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 64)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(ControlHandler(service: service))
            }
            .bind(unixDomainSocketPath: path)
            .wait()

        // The daemon runs as root; the CLI and the menu bar app do not. Group
        // access for `staff` lets any logged-in developer register a project
        // without sudo, while keeping the socket off-limits to other accounts.
        chmod(path, 0o660)
        if let staff = getgrnam("staff") {
            chown(path, 0, staff.pointee.gr_gid)
        }

        Log.info("Control socket at \(path)")
        return channel
    }
}
