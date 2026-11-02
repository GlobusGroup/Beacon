import BeaconKit
import BeaconTunnel
import Foundation
import NIOCore
import NIOPosix
import NIOSSL

/// What `beacon relay` and `beacon share` configure. Kept apart from
/// config.json because it holds the token, so it is readable by root only.
struct RelaySettings: Codable {
    var url: String?
    var token: String?
    var shares: [TunnelShare] = []

    var isConfigured: Bool { !(url ?? "").isEmpty && !(token ?? "").isEmpty }
}

/// The address a tunnel dials, parsed from whatever form the user typed:
/// `beacon.cab`, `wss://beacon.cab`, or `ws://127.0.0.1:8090` for testing.
struct RelayTarget: Equatable {
    var tls: Bool
    var host: String
    var port: Int
    var path: String

    init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "wss://" + text }
        guard let components = URLComponents(string: text),
              let host = components.host, !host.isEmpty
        else { return nil }

        switch components.scheme?.lowercased() {
        case "wss", "https": tls = true
        case "ws", "http": tls = false
        default: return nil
        }
        self.host = host
        port = components.port ?? (tls ? 443 : 80)
        path = (components.path.isEmpty || components.path == "/") ? TunnelProtocol.path : components.path
    }

    var hostHeader: String { port == (tls ? 443 : 80) ? host : "\(host):\(port)" }
}

/// Keeps one tunnel open to the relay while anything is shared, and connects
/// each public request that arrives down it to the project's dev server.
///
/// Settings and the published status are guarded by `lock`, since the control
/// socket reads them from its own threads. The connection itself lives on
/// `loop`, and so does every dev-server connection it makes.
final class TunnelClient: @unchecked Sendable {
    private let loop: EventLoop
    private let registry: Registry

    private let lock = NSLock()
    private var settings: RelaySettings
    private var status: RelayStatus
    /// From the relay's last answer, by share name.
    private var confirmed: [String: TunnelShareStatus] = [:]

    // On `loop` only.
    private var channel: Channel?
    private var mux: TunnelMux?
    private var connectedTo: (target: RelayTarget, token: String)?
    private var retryDelay: TimeAmount = .seconds(1)
    private var retry: Scheduled<Void>?
    /// Bumped whenever a connection is abandoned, so its late callbacks are ignored.
    private var generation = 0
    private lazy var tlsContext: NIOSSLContext? = try? NIOSSLContext(configuration: .makeClientConfiguration())

    init(group: EventLoopGroup, registry: Registry) {
        self.loop = group.next()
        self.registry = registry
        self.settings = Self.load()
        self.status = RelayStatus(url: nil, hasToken: false, state: .off)
        lock.withLock { publishLocked(state: settings.isConfigured ? .idle : .off) }
    }

    func start() {
        loop.execute { self.reconcile() }
    }

    // MARK: - Control (any thread)

    var currentStatus: RelayStatus {
        lock.withLock { status }
    }

    func setRelay(_ spec: RelaySpec) throws -> RelayStatus {
        if let url = spec.url, !url.isEmpty, RelayTarget(url) == nil {
            throw BeaconClientError(
                code: "bad_relay_url",
                message: "'\(url)' isn't a relay address. Use a domain like beacon.cab, or a wss:// URL."
            )
        }
        return try mutate { settings in
            if let url = spec.url { settings.url = url.isEmpty ? nil : url }
            if let token = spec.token { settings.token = token.isEmpty ? nil : token }
        }
    }

    func share(_ spec: ShareSpec) throws -> RelayStatus {
        guard let site = registry.site(named: spec.name) else {
            throw BeaconClientError(code: "unknown_site", message: "No project named '\(spec.name)'.")
        }
        guard lock.withLock({ settings.isConfigured }) else {
            throw BeaconClientError(
                code: "relay_not_configured",
                message: "No relay is set up. Run `beacon relay --url beacon.cab --token <token>` first."
            )
        }
        let password = spec.password.flatMap { $0.isEmpty ? nil : $0 }
        return try mutate { settings in
            settings.shares.removeAll { $0.name == site.name }
            settings.shares.append(TunnelShare(name: site.name, password: password))
            settings.shares.sort { $0.name < $1.name }
        }
    }

    func unshare(_ name: String) throws -> RelayStatus {
        let slug = Site.slug(name)
        guard lock.withLock({ settings.shares.contains { $0.name == slug } }) else {
            throw BeaconClientError(code: "not_shared", message: "'\(name)' isn't shared.")
        }
        return try mutate { settings in
            settings.shares.removeAll { $0.name == slug }
        }
    }

    private func mutate(_ change: (inout RelaySettings) -> Void) throws -> RelayStatus {
        let snapshot = try lock.withLock { () -> RelayStatus in
            var updated = settings
            change(&updated)
            try Self.save(updated)
            settings = updated
            publishLocked(state: status.state)
            return status
        }
        loop.execute { self.reconcile() }
        return snapshot
    }

    // MARK: - Connection (on loop)

    /// Brings the connection in line with the settings: open while anything
    /// is shared, closed otherwise, redialled if the relay or token changed.
    private func reconcile() {
        let settings = lock.withLock { self.settings }
        guard settings.isConfigured, !settings.shares.isEmpty,
              let target = RelayTarget(settings.url!), let token = settings.token
        else {
            disconnect()
            update(state: settings.isConfigured ? .idle : .off, error: nil)
            return
        }

        if let current = connectedTo, current.target == target, current.token == token {
            if let mux {
                announce(on: mux)
            } else if channel == nil, retry != nil {
                // Waiting out a backoff. Someone just asked for something, so try now.
                retry?.cancel()
                retry = nil
                connect(to: target, token: token)
            }
            return
        }

        disconnect()
        retryDelay = .seconds(1)
        connect(to: target, token: token)
    }

    private func disconnect() {
        generation += 1
        retry?.cancel()
        retry = nil
        channel?.close(promise: nil)
        channel = nil
        mux = nil
        connectedTo = nil
    }

    private func connect(to target: RelayTarget, token: String) {
        generation += 1
        let attempt = generation
        connectedTo = (target, token)
        update(state: .connecting, error: lock.withLock { status.error })

        let tls = target.tls ? tlsContext : nil
        if target.tls && tls == nil {
            failed(attempt, "Couldn't set up TLS for the relay connection.")
            return
        }

        let key = WebSocketHandshake.randomKey()
        let request = WebSocketHandshake.clientRequest(
            host: target.hostHeader, path: target.path, key: key, token: token
        )

        ClientBootstrap(group: loop)
            .connectTimeout(.seconds(10))
            .channelOption(ChannelOptions.tcpOption(.tcp_nodelay), value: 1)
            .channelInitializer { [self] channel in
                do {
                    if let tls {
                        try channel.pipeline.syncOperations.addHandler(
                            NIOSSLClientHandler(context: tls, serverHostname: target.host)
                        )
                    }
                    try channel.pipeline.syncOperations.addHandler(TunnelHandshakeHandler(
                        request: request, key: key
                    ) { [self] result in
                        handshakeFinished(attempt, channel: channel, result: result)
                    })
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }
            .connect(host: target.host, port: target.port)
            .whenComplete { [self] result in
                guard attempt == generation else {
                    if case .success(let channel) = result { channel.close(promise: nil) }
                    return
                }
                switch result {
                case .success(let channel):
                    self.channel = channel
                    channel.closeFuture.whenComplete { [self] _ in disconnected(attempt) }
                case .failure(let error):
                    failed(attempt, "Couldn't reach \(target.hostHeader): \(Self.describe(error)).")
                }
            }
    }

    private func handshakeFinished(_ attempt: Int, channel: Channel, result: Result<ByteBuffer, TunnelHandshakeHandler.Failure>) {
        guard attempt == generation else {
            channel.close(promise: nil)
            return
        }
        switch result {
        case .failure(let failure):
            update(state: .failed, error: failure.message)
            if failure.rejectedToken { retryDelay = .seconds(60) }
            channel.close(promise: nil)

        case .success(let leftover):
            do {
                let mux = try TunnelMux.install(on: channel, masksFrames: true, leftover: leftover)
                mux.onOpen = { [weak self, weak mux] id, share in
                    guard let self, let mux else { return }
                    self.openStream(id, share: share, mux: mux)
                }
                mux.onText = { [weak self] text in self?.relayAnswered(text) }
                mux.startKeepalive(interval: .seconds(20), timeout: .seconds(60))
                self.mux = mux
                retryDelay = .seconds(1)
                Log.info("Tunnel open to \(connectedTo?.target.hostHeader ?? "relay").")
                update(state: .connected, error: nil)
                announce(on: mux)
            } catch {
                update(state: .failed, error: "Couldn't start the tunnel: \(error)")
                channel.close(promise: nil)
            }
        }
    }

    private func disconnected(_ attempt: Int) {
        guard attempt == generation else { return }
        if mux != nil {
            Log.warn("Tunnel to the relay closed; reconnecting.")
            update(state: .connecting, error: "Lost the connection to the relay. Reconnecting…")
        }
        channel = nil
        mux = nil
        scheduleRetry()
    }

    private func failed(_ attempt: Int, _ message: String) {
        guard attempt == generation else { return }
        Log.warn(message)
        update(state: .failed, error: message)
        channel = nil
        mux = nil
        scheduleRetry()
    }

    private func scheduleRetry() {
        guard let current = connectedTo, retry == nil else { return }
        let delay = retryDelay
        retryDelay = .nanoseconds(min(retryDelay.nanoseconds * 2, TimeAmount.seconds(30).nanoseconds))
        if delay > .seconds(30) { retryDelay = delay }
        retry = loop.scheduleTask(in: delay) { [self] in
            retry = nil
            guard channel == nil else { return }
            connect(to: current.target, token: current.token)
        }
    }

    // MARK: - Traffic

    private func announce(on mux: TunnelMux) {
        let shares = lock.withLock { settings.shares }
        mux.sendJSON(TunnelClientMessage(shares: shares))
    }

    private func relayAnswered(_ text: String) {
        guard let message = try? JSONDecoder().decode(TunnelRelayMessage.self, from: Data(text.utf8)) else {
            Log.warn("The relay sent an unreadable message.")
            return
        }
        lock.withLock {
            confirmed = Dictionary(message.shares.map { ($0.name, $0) }, uniquingKeysWith: { _, last in last })
            status.label = message.label
            publishLocked(state: status.state)
        }
        for share in message.shares {
            if let url = share.url {
                Log.info("Shared \(share.name) at \(url)")
            } else if let error = share.error {
                Log.warn("Couldn't share \(share.name): \(error)")
            }
        }
    }

    /// A visitor arrived for `share`. Connect them to its dev server.
    private func openStream(_ id: UInt32, share: String, mux: TunnelMux) {
        let isShared = lock.withLock { settings.shares.contains { $0.name == share } }
        guard isShared, let site = registry.site(named: share) else {
            mux.respond(id, with: page(
                mux, status: "404 Not Found",
                title: "Nothing is shared here",
                detail: "This project isn't shared any more."
            ))
            return
        }

        ClientBootstrap(group: loop)
            .connectTimeout(.seconds(5))
            .channelOption(ChannelOptions.tcpOption(.tcp_nodelay), value: 1)
            .channelInitializer { channel in
                channel.pipeline.addHandler(TunnelStreamHandler(mux: mux, id: id))
            }
            .connect(host: "127.0.0.1", port: site.port)
            .whenComplete { [self] result in
                switch result {
                case .success(let channel):
                    mux.attach(id, channel: channel)
                case .failure:
                    Log.debug("Shared \(site.name) isn't listening on :\(site.port).")
                    mux.respond(id, with: page(
                        mux, status: "502 Bad Gateway",
                        title: "\(site.name) isn't running",
                        detail: "The Mac sharing this project is online, but its dev server isn't answering. Ask whoever shared it to start it."
                    ))
                }
            }
    }

    private func page(_ mux: TunnelMux, status: String, title: String, detail: String) -> ByteBuffer {
        let bytes = ProxyResponder.response(status: status, title: ProxyResponder.escape(title), detail: ProxyResponder.escape(detail))
        var buffer = mux.channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        return buffer
    }

    // MARK: - Status

    private func update(state: RelayStatus.State, error: String?) {
        lock.withLock {
            status.error = error
            publishLocked(state: state)
        }
    }

    private func publishLocked(state: RelayStatus.State) {
        status = RelayStatus(
            url: settings.url,
            hasToken: !(settings.token ?? "").isEmpty,
            // Configuring a relay is enough to leave `off`, before any tunnel opens.
            state: settings.isConfigured ? (state == .off ? .idle : state) : .off,
            label: status.label,
            error: settings.isConfigured ? status.error : nil,
            shares: settings.shares.map { share in
                let answer = confirmed[share.name]
                return SharedProject(
                    name: share.name,
                    publicURL: answer?.url,
                    passwordProtected: share.password != nil,
                    error: answer?.error
                )
            }
        )
    }

    private static func describe(_ error: Error) -> String {
        if let io = error as? IOError { return String(cString: strerror(io.errnoCode)).lowercased() }
        if let connection = error as? NIOConnectionError {
            if connection.dnsAError != nil || connection.dnsAAAAError != nil, connection.connectionErrors.isEmpty {
                return "the name didn't resolve"
            }
            if let first = connection.connectionErrors.first?.error { return describe(first) }
        }
        if error is ChannelError { return "the connection timed out" }
        return "\(error)"
    }

    // MARK: - Persistence

    private static func load() -> RelaySettings {
        guard let data = FileManager.default.contents(atPath: BeaconPaths.relayFile),
              let settings = try? BeaconJSON.decoder.decode(RelaySettings.self, from: data)
        else { return RelaySettings() }
        return settings
    }

    private static func save(_ settings: RelaySettings) throws {
        let data = try BeaconJSON.prettyEncoder.encode(settings)
        try FileManager.default.createDirectory(atPath: BeaconPaths.supportDir, withIntermediateDirectories: true)
        let url = URL(fileURLWithPath: BeaconPaths.relayFile)
        try data.write(to: url, options: .atomic)
        chmod(BeaconPaths.relayFile, 0o600)
    }
}

/// Performs the client half of the WebSocket handshake on a fresh connection,
/// then steps aside.
final class TunnelHandshakeHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    struct Failure: Error {
        var message: String
        var rejectedToken = false
    }

    private let request: String
    private let key: String
    private let completion: (Result<ByteBuffer, Failure>) -> Void
    private var buffer = ByteBuffer()
    private var finished = false

    init(request: String, key: String, completion: @escaping (Result<ByteBuffer, Failure>) -> Void) {
        self.request = request
        self.key = key
        self.completion = completion
    }

    func channelActive(context: ChannelHandlerContext) {
        var out = context.channel.allocator.buffer(capacity: request.utf8.count)
        out.writeString(request)
        context.writeAndFlush(wrapOutboundOut(out), promise: nil)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !finished else { return }
        var incoming = unwrapInboundIn(data)
        buffer.writeBuffer(&incoming)

        guard let head = HTTPHead.parse(buffer) else {
            if buffer.readableBytes > HTTPHead.maxSize { finish(context, .failure(Failure(message: "The relay sent an oversized reply."))) }
            return
        }
        let statusLine = head.requestLine
        let code = statusLine.split(separator: " ").dropFirst().first.map(String.init) ?? ""

        guard code == "101" else {
            switch code {
            case "401", "403":
                finish(context, .failure(Failure(message: "The relay rejected the token.", rejectedToken: true)))
            case "404":
                finish(context, .failure(Failure(message: "There's no Beacon relay at that address.")))
            default:
                finish(context, .failure(Failure(message: "The relay answered “\(statusLine)” instead of opening a tunnel.")))
            }
            return
        }
        guard head.value(of: "Sec-WebSocket-Accept") == WebSocketHandshake.accept(for: key) else {
            finish(context, .failure(Failure(message: "Something between Beacon and the relay mangled the WebSocket handshake.")))
            return
        }

        buffer.moveReaderIndex(forwardBy: head.byteLength)
        let leftover = buffer
        buffer = ByteBuffer()
        finished = true
        context.pipeline.syncOperations.removeHandler(context: context, promise: nil)
        completion(.success(leftover))
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !finished {
            finished = true
            completion(.failure(Failure(message: "The relay closed the connection during the handshake.")))
        }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if !finished {
            finish(context, .failure(Failure(message: "The relay connection failed: \(error).")))
        } else {
            context.fireErrorCaught(error)
        }
    }

    private func finish(_ context: ChannelHandlerContext, _ result: Result<ByteBuffer, Failure>) {
        guard !finished else { return }
        finished = true
        completion(result)
        context.close(promise: nil)
    }
}
