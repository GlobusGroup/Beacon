import BeaconKit
import Foundation
import NIOCore
import NIOPosix
import NIOSSL

/// Holds the TLS context so it can be swapped when certificates are reissued
/// without tearing down the listener.
final class TLSContextBox: @unchecked Sendable {
    private let lock = NSLock()
    private var context: NIOSSLContext?

    func update(_ material: CertificateAuthority.Material) throws {
        let certificates = try NIOSSLCertificate.fromPEMBytes(Array(material.certificateChainPEM.utf8))
        let key = try NIOSSLPrivateKey(bytes: Array(material.privateKeyPEM.utf8), format: .pem)

        var configuration = TLSConfiguration.makeServerConfiguration(
            certificateChain: certificates.map { .certificate($0) },
            privateKey: .privateKey(key)
        )
        // Beacon proxies HTTP/1.1. Offering h2 would let browsers speak a
        // protocol this proxy can't read a Host header out of.
        configuration.applicationProtocols = ["http/1.1"]

        let built = try NIOSSLContext(configuration: configuration)
        lock.lock()
        context = built
        lock.unlock()
    }

    var current: NIOSSLContext? {
        lock.lock()
        defer { lock.unlock() }
        return context
    }
}

/// Browser side of a proxied connection.
final class ProxyFrontendHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private enum State {
        /// Reading the first head, so we don't know where this connection goes yet.
        case resolving
        case connecting
        case relaying(Channel)
        case closed
    }

    private let routes: RouteTable
    private let scheme: String
    private let listenPort: Int

    private var state: State = .resolving
    private var rewriter: RequestRewriter?
    /// Rewritten bytes produced before the upstream connection was ready.
    private var queued: ByteBuffer?

    init(routes: RouteTable, scheme: String, listenPort: Int) {
        self.routes = routes
        self.scheme = scheme
        self.listenPort = listenPort
    }

    func channelActive(context: ChannelHandlerContext) {
        rewriter = RequestRewriter(
            allocator: context.channel.allocator,
            scheme: scheme,
            listenPort: listenPort,
            clientIP: context.channel.remoteAddress?.ipAddress ?? "127.0.0.1"
        )
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if case .closed = state { return }
        guard let rewriter else { return }
        var incoming = unwrapInboundIn(data)
        rewriter.append(&incoming)

        var produced: ByteBuffer
        switch rewriter.drain(allocator: context.channel.allocator) {
        case .forward(let bytes):
            produced = bytes
        case .malformed(let reason):
            state = .closed
            ProxyResponder.send(
                on: context.channel,
                status: "400 Bad Request",
                title: "Beacon couldn't read that request",
                detail: "The proxy gave up because \(reason)."
            )
            return
        }

        switch state {
        case .closed:
            return

        case .relaying(let upstream):
            if produced.readableBytes > 0 {
                upstream.writeAndFlush(produced, promise: nil)
            }

        case .connecting:
            enqueue(&produced, allocator: context.channel.allocator)

        case .resolving:
            enqueue(&produced, allocator: context.channel.allocator)
            guard let host = rewriter.host else { return }
            guard let site = routes.site(forHost: host) else {
                state = .closed
                ProxyResponder.sendUnknownHost(
                    on: context.channel, host: host, known: routes.sites, scheme: scheme
                )
                return
            }
            openUpstream(channel: context.channel, site: site)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        if case .relaying(let upstream) = state, upstream.isActive {
            upstream.close(promise: nil)
        }
        state = .closed
        context.fireChannelInactive()
    }

    /// When the browser stops draining, stop pulling from the dev server.
    func channelWritabilityChanged(context: ChannelHandlerContext) {
        guard case .relaying(let upstream) = state else { return }
        let writable = context.channel.isWritable
        upstream.setOption(ChannelOptions.autoRead, value: writable).whenFailure { _ in }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        Log.debug("Frontend error: \(error)")
        context.close(promise: nil)
    }

    // MARK: -

    private func enqueue(_ bytes: inout ByteBuffer, allocator: ByteBufferAllocator) {
        guard bytes.readableBytes > 0 else { return }
        if queued == nil {
            queued = bytes
        } else {
            queued!.writeBuffer(&bytes)
        }
    }

    private func openUpstream(channel: Channel, site: Site) {
        state = .connecting

        ClientBootstrap(group: channel.eventLoop)
            .channelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
            .channelInitializer { upstream in
                upstream.pipeline.addHandler(ProxyBackendHandler(frontend: channel))
            }
            .connect(host: "127.0.0.1", port: site.port)
            .whenComplete { [self] result in
                switch result {
                case .success(let upstream):
                    state = .relaying(upstream)
                    if let pending = queued {
                        queued = nil
                        upstream.writeAndFlush(pending, promise: nil)
                    }
                case .failure:
                    state = .closed
                    queued = nil
                    ProxyResponder.sendUpstreamDown(on: channel, site: site)
                }
            }
    }
}

/// Dev-server side of a proxied connection.
final class ProxyBackendHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let frontend: Channel

    init(frontend: Channel) {
        self.frontend = frontend
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        frontend.writeAndFlush(unwrapInboundIn(data), promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if frontend.isActive { frontend.close(promise: nil) }
        context.fireChannelInactive()
    }

    /// When the dev server stops draining, stop pulling from the browser.
    func channelWritabilityChanged(context: ChannelHandlerContext) {
        let writable = context.channel.isWritable
        frontend.setOption(ChannelOptions.autoRead, value: writable).whenFailure { _ in }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        Log.debug("Backend error: \(error)")
        context.close(promise: nil)
    }
}

/// Binds the two listeners that front every project.
struct ProxyServer {
    let group: EventLoopGroup
    let routes: RouteTable
    let tls: TLSContextBox
    let httpPort: Int
    let httpsPort: Int

    func start() throws -> [Channel] {
        let plain = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(
                    ProxyFrontendHandler(routes: routes, scheme: "http", listenPort: httpPort)
                )
            }
            .bind(host: "0.0.0.0", port: httpPort)
            .wait()
        Log.info("HTTP proxy listening on :\(httpPort)")

        let secure = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
            .childChannelInitializer { channel in
                guard let context = tls.current else {
                    return channel.close()
                }
                do {
                    try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: context))
                    try channel.pipeline.syncOperations.addHandler(
                        ProxyFrontendHandler(routes: routes, scheme: "https", listenPort: httpsPort)
                    )
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }
            .bind(host: "0.0.0.0", port: httpsPort)
            .wait()
        Log.info("HTTPS proxy listening on :\(httpsPort)")

        return [plain, secure]
    }
}
