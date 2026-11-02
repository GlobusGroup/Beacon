import BeaconTunnel
import Foundation
import NIOCore

/// Every connection that reaches the relay starts here.
///
/// The first request head decides what the connection is:
/// - a Mac opening its tunnel (`GET /_tunnel` on the apex, with a token),
/// - a visitor to a share (`<share>-<label>.<domain>`), relayed down a tunnel,
/// - anything else, answered with a small page.
///
/// Traefik pools its connections to the relay and would happily send one
/// visitor's request after another's, for different hosts, down the same one.
/// So a relayed connection carries exactly one request: its head is rewritten
/// with `Connection: close`, and nothing after that request is forwarded.
/// Routing, auth and `X-Forwarded-For` are therefore always per request.
final class RelayFrontendHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private enum State {
        case reading
        case relaying(TunnelMux, UInt32)
        case closed
    }

    private let hub: RelayHub
    private let config: RelayConfig
    private let tokens: RelayTokens
    private var state: State = .reading
    private var raw = ByteBuffer()
    private var rewriter: RequestRewriter?

    init(hub: RelayHub, config: RelayConfig, tokens: RelayTokens) {
        self.hub = hub
        self.config = config
        self.tokens = tokens
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)

        switch state {
        case .closed:
            return

        case .relaying(let mux, let id):
            guard let rewriter else { return }
            rewriter.append(&incoming)
            forward(rewriter.drain(allocator: context.channel.allocator), mux: mux, id: id, context: context)

        case .reading:
            raw.writeBuffer(&incoming)
            guard let head = HTTPHead.parse(raw) else {
                if raw.readableBytes > HTTPHead.maxSize {
                    reply(context, RelayPages.badRequest("The request head was larger than \(HTTPHead.maxSize / 1024)KB."))
                }
                return
            }
            dispatch(head, context: context)
        }
    }

    private func dispatch(_ head: HTTPHead, context: ChannelHandlerContext) {
        guard let rawHost = head.host else {
            reply(context, RelayPages.badRequest("The request had no Host header."))
            return
        }
        let host = Hostnames.normalise(rawHost)
        let path = String(head.target.prefix { $0 != "?" })

        if let route = hub.route(for: host) {
            relay(head, host: host, route: route, context: context)
            return
        }

        let isShareHost = host.hasSuffix("." + config.domain)
        if !isShareHost && path == TunnelProtocol.path {
            openTunnel(head, context: context)
            return
        }
        if !isShareHost && path.hasPrefix(RelayAdmin.prefix) {
            admin(head, path: path, context: context)
            return
        }
        if !isShareHost && path == "/healthz" {
            reply(context, RelayPages.health(sessions: hub.sessionCount, routes: hub.routeCount))
            return
        }
        if isShareHost {
            reply(context, RelayPages.notShared(host: host))
            return
        }
        reply(context, RelayPages.home(domain: config.domain))
    }

    // MARK: - Visitors

    private func relay(_ head: HTTPHead, host: String, route: RelayHub.Route, context: ChannelHandlerContext) {
        if let password = route.share.password, !Self.authorised(head, password: password) {
            reply(context, RelayPages.unauthorised(host: host))
            return
        }

        let rewriter = RequestRewriter(
            allocator: context.channel.allocator,
            scheme: config.publicScheme,
            listenPort: config.publicPort,
            clientIP: context.channel.remoteAddress?.ipAddress ?? "0.0.0.0",
            trustForwardedFor: config.trustForwardedFor,
            maxRequests: 1,
            closeConnection: true
        )
        self.rewriter = rewriter
        rewriter.append(&raw)
        raw = ByteBuffer()

        let id = route.session.mux.open(share: route.share.name, channel: context.channel)
        state = .relaying(route.session.mux, id)
        RelayLog.debug("\(head.method) \(host)\(head.target) → \(route.session.label) stream \(id)")
        forward(rewriter.drain(allocator: context.channel.allocator), mux: route.session.mux, id: id, context: context)
    }

    private func forward(_ outcome: RequestRewriter.Outcome, mux: TunnelMux, id: UInt32, context: ChannelHandlerContext) {
        switch outcome {
        case .forward(let bytes):
            if bytes.readableBytes > 0 { mux.send(id, bytes) }
        case .malformed(let reason):
            RelayLog.debug("Dropping a malformed request: \(reason)")
            mux.close(id)
            state = .closed
        }
    }

    /// Basic auth with any username: the share has one password, not accounts.
    private static func authorised(_ head: HTTPHead, password: String) -> Bool {
        guard let header = head.value(of: "Authorization"),
              header.lowercased().hasPrefix("basic "),
              let decoded = Data(base64Encoded: String(header.dropFirst(6)).trimmingCharacters(in: .whitespaces)),
              let credentials = String(data: decoded, encoding: .utf8),
              let colon = credentials.firstIndex(of: ":")
        else { return false }
        return constantTimeEquals(String(credentials[credentials.index(after: colon)...]), password)
    }

    // MARK: - Tunnels

    private func openTunnel(_ head: HTTPHead, context: ChannelHandlerContext) {
        guard head.value(of: "Upgrade")?.lowercased() == "websocket",
              let key = head.value(of: "Sec-WebSocket-Key")
        else {
            reply(context, RelayPages.badRequest("Tunnels open with a WebSocket upgrade."))
            return
        }

        let bearer = Self.bearer(head)
        let remote = forwardedClient(head) ?? context.channel.remoteAddress?.ipAddress ?? "?"
        guard let bearer, let label = tokens.identity(forToken: bearer)?.label else {
            RelayLog.warn("Rejected a tunnel from \(remote): \(bearer == nil ? "no token" : "unknown token").")
            reply(context, RelayPages.rejectedToken())
            return
        }

        raw.moveReaderIndex(forwardBy: head.byteLength)
        let leftover = raw
        raw = ByteBuffer()
        state = .closed

        var response = context.channel.allocator.buffer(capacity: 160)
        response.writeString(WebSocketHandshake.serverResponse(key: key))
        context.writeAndFlush(wrapOutboundOut(response), promise: nil)

        let channel = context.channel
        do {
            context.pipeline.syncOperations.removeHandler(context: context, promise: nil)
            let mux = try TunnelMux.install(on: channel, masksFrames: false, leftover: leftover)
            hub.attach(RelaySession(label: label, mux: mux, remote: remote))
        } catch {
            RelayLog.error("Couldn't set up a tunnel for \(label): \(error)")
            channel.close(promise: nil)
        }
    }

    private static func bearer(_ head: HTTPHead) -> String? {
        head.value(of: "Authorization").flatMap { value -> String? in
            guard value.lowercased().hasPrefix("bearer ") else { return nil }
            return String(value.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        }
    }

    // MARK: - Admin

    /// Waits for the whole body, then answers. Called again from `channelRead`
    /// as more of it arrives, since the connection stays in `.reading`.
    private func admin(_ head: HTTPHead, path: String, context: ChannelHandlerContext) {
        if head.value(of: "Transfer-Encoding") != nil {
            reply(context, RelayAdmin.failure("411 Length Required", "no_length", "Send the body with a Content-Length."))
            return
        }
        let length = Int(head.value(of: "Content-Length") ?? "0") ?? -1
        guard (0...RelayAdmin.maxBody).contains(length) else {
            reply(context, RelayAdmin.failure("413 Content Too Large", "too_large", "Admin requests are small JSON bodies."))
            return
        }
        guard raw.readableBytes >= head.byteLength + length else { return }

        let body = Data(raw.getBytes(at: raw.readerIndex + head.byteLength, length: length) ?? [])
        reply(context, RelayAdmin.handle(
            method: head.method, path: path, bearer: Self.bearer(head), body: body, tokens: tokens, hub: hub
        ))
    }

    private func forwardedClient(_ head: HTTPHead) -> String? {
        guard config.trustForwardedFor, let forwarded = head.value(of: "X-Forwarded-For") else { return nil }
        return forwarded.split(separator: ",").last.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: -

    func channelInactive(context: ChannelHandlerContext) {
        if case .relaying(let mux, let id) = state {
            mux.close(id)
        }
        state = .closed
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        RelayLog.debug("Connection error: \(error)")
        context.close(promise: nil)
    }

    private func reply(_ context: ChannelHandlerContext, _ page: String) {
        state = .closed
        var out = context.channel.allocator.buffer(capacity: page.utf8.count)
        out.writeString(page)
        let channel = context.channel
        context.writeAndFlush(wrapOutboundOut(out)).whenComplete { _ in
            channel.close(promise: nil)
        }
    }
}
