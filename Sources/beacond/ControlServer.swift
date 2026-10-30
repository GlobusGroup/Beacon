import BeaconKit
import Foundation
import NIOCore
import NIOPosix

/// Answers requests from the `beacon` CLI and the menu bar app.
final class ControlService: @unchecked Sendable {
    private let registry: Registry
    private let startedAt = Date()
    private let httpPort: Int
    private let httpsPort: Int
    private let dnsPort: Int

    init(registry: Registry, httpPort: Int, httpsPort: Int, dnsPort: Int) {
        self.registry = registry
        self.httpPort = httpPort
        self.httpsPort = httpsPort
        self.dnsPort = dnsPort
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

            case .setConfig:
                guard let config = request.config else {
                    return .failure("missing_config", "No configuration was sent.")
                }
                return BeaconResponse(config: try registry.updateConfig(config))
            }
        } catch let error as BeaconClientError {
            return .failure(error.code, error.message)
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
        let response: BeaconResponse
        do {
            let request = try BeaconJSON.decoder.decode(BeaconRequest.self, from: Data(bytes))
            response = service.handle(request)
        } catch {
            response = .failure("bad_request", "Couldn't decode that request: \(error.localizedDescription)")
        }

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
