import Foundation
import NIOCore
import NIOWebSocket

/// Carries many byte streams over one WebSocket, in both directions.
///
/// Each stream pairs a tunnel stream ID with a local `Channel`: on the relay,
/// the public connection; on the Mac, the connection to the dev server. Bytes
/// read from that channel go out as DATA frames, DATA frames arriving for the
/// stream are written to it.
///
/// Flow control is per stream. A sender may have `TunnelProtocol.streamWindow`
/// bytes unacknowledged; beyond that it stops reading its local channel until
/// a WINDOW frame says the far side has written them onward. One slow browser
/// therefore can't make the other end buffer without limit, and can't stall
/// the other streams sharing the WebSocket.
///
/// Everything here runs on the WebSocket channel's event loop, and every
/// stream channel must live on that same loop.
public final class TunnelMux {
    private final class Stream {
        var channel: Channel?
        /// DATA that arrived before `channel` was attached.
        var pending: [ByteBuffer] = []
        /// Bytes we may still send before waiting for a WINDOW.
        var credit = TunnelProtocol.streamWindow
        /// Bytes written onward but not yet acknowledged to the sender.
        var unacknowledged = 0
    }

    public let channel: Channel
    private let masksFrames: Bool
    private var streams: [UInt32: Stream] = [:]
    private var nextStreamID: UInt32 = 1
    private var keepalive: RepeatedTask?
    /// Wall-clock, not `NIODeadline`: on macOS the monotonic clock stops while
    /// the Mac sleeps, so a tunnel that died during a long sleep would look
    /// freshly heard from on wake and linger for another full timeout.
    private var lastHeard = Date()

    /// The far side opened a stream. The payload is the share name.
    public var onOpen: ((UInt32, String) -> Void)?
    /// A text (control) message arrived.
    public var onText: ((String) -> Void)?
    /// The WebSocket is gone; every stream has been closed.
    public var onClose: (() -> Void)?

    /// - Parameter masksFrames: true on the connecting (client) side, which the
    ///   WebSocket protocol requires to mask what it sends.
    public init(channel: Channel, masksFrames: Bool) {
        self.channel = channel
        self.masksFrames = masksFrames
    }

    public var eventLoop: EventLoop { channel.eventLoop }
    public var streamCount: Int { streams.count }

    // MARK: - Streams

    /// Opens a stream for a local channel that already exists. Relay side.
    @discardableResult
    public func open(share: String, channel local: Channel) -> UInt32 {
        let id = nextStreamID
        nextStreamID &+= 1
        let stream = Stream()
        stream.channel = local
        streams[id] = stream

        var payload = channel.allocator.buffer(capacity: share.utf8.count)
        payload.writeString(share)
        sendFrame(TunnelFrame(kind: .open, stream: id, payload: payload))
        return id
    }

    /// Hands a stream the far side opened its local channel, once connected.
    /// Anything that arrived in the meantime is written now.
    public func attach(_ id: UInt32, channel local: Channel) {
        guard let stream = streams[id] else {
            local.close(promise: nil)
            return
        }
        stream.channel = local
        let pending = stream.pending
        stream.pending = []
        for chunk in pending { deliver(chunk, to: stream, id: id) }
    }

    public func isOpen(_ id: UInt32) -> Bool { streams[id] != nil }

    /// Sends bytes read from the stream's local channel.
    public func send(_ id: UInt32, _ bytes: ByteBuffer) {
        guard let stream = streams[id] else { return }
        var bytes = bytes
        while bytes.readableBytes > 0 {
            let chunk = bytes.readSlice(length: min(bytes.readableBytes, TunnelProtocol.maxChunk))!
            stream.credit -= chunk.readableBytes
            sendFrame(TunnelFrame(kind: .data, stream: id, payload: chunk))
        }
        if stream.credit <= 0 {
            stream.channel?.setOption(ChannelOptions.autoRead, value: false).whenFailure { _ in }
        }
    }

    /// Ends a stream from this side and closes its local channel.
    public func close(_ id: UInt32) {
        guard let stream = streams.removeValue(forKey: id) else { return }
        sendFrame(TunnelFrame(kind: .close, stream: id))
        stream.channel?.close(promise: nil)
    }

    /// Writes a complete response straight back down a stream, then ends it.
    /// For the Mac to answer when there's no dev server to hand the stream to.
    public func respond(_ id: UInt32, with bytes: ByteBuffer) {
        send(id, bytes)
        close(id)
    }

    // MARK: - Control

    public func sendText(_ text: String) {
        var data = channel.allocator.buffer(capacity: text.utf8.count)
        data.writeString(text)
        write(WebSocketFrame(fin: true, opcode: .text, maskKey: mask(), data: data))
    }

    public func sendJSON<T: Encodable>(_ value: T) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        sendText(String(decoding: data, as: UTF8.self))
    }

    /// Pings every `interval` and drops the connection when nothing at all has
    /// been heard for `timeout`. A tunnel through a NAT or a proxy can die
    /// without either end being told; this is how the Mac finds out.
    public func startKeepalive(interval: TimeAmount, timeout: TimeAmount) {
        keepalive = eventLoop.scheduleRepeatedTask(initialDelay: interval, delay: interval) { [weak self] _ in
            guard let self else { return }
            let silentFor = Date().timeIntervalSince(self.lastHeard)
            if silentFor > Double(timeout.nanoseconds) / 1_000_000_000 {
                self.channel.close(promise: nil)
                return
            }
            self.write(WebSocketFrame(fin: true, opcode: .ping, maskKey: self.mask(), data: self.channel.allocator.buffer(capacity: 0)))
        }
    }

    // MARK: - Inbound

    func receive(_ frame: WebSocketFrame) {
        lastHeard = Date()
        switch frame.opcode {
        case .binary:
            guard let decoded = TunnelFrame.decode(frame.unmaskedData) else { return }
            handle(decoded)
        case .text:
            var data = frame.unmaskedData
            if let text = data.readString(length: data.readableBytes) { onText?(text) }
        case .ping:
            write(WebSocketFrame(fin: true, opcode: .pong, maskKey: mask(), data: frame.unmaskedData))
        case .connectionClose:
            channel.close(promise: nil)
        default:
            break
        }
    }

    private func handle(_ frame: TunnelFrame) {
        switch frame.kind {
        case .open:
            guard streams[frame.stream] == nil else { return }
            streams[frame.stream] = Stream()
            let share = frame.payload.flatMap { $0.getString(at: $0.readerIndex, length: $0.readableBytes) } ?? ""
            onOpen?(frame.stream, share)

        case .data:
            guard let stream = streams[frame.stream], let payload = frame.payload else { return }
            if stream.channel == nil {
                stream.pending.append(payload)
            } else {
                deliver(payload, to: stream, id: frame.stream)
            }

        case .close:
            guard let stream = streams.removeValue(forKey: frame.stream) else { return }
            stream.pending = []
            // Flush whatever is queued, then close: a response that just
            // finished must reach the browser in full.
            stream.channel?.writeAndFlush(channel.allocator.buffer(capacity: 0)).whenComplete { _ in
                stream.channel?.close(promise: nil)
            }

        case .window:
            guard let stream = streams[frame.stream],
                  var payload = frame.payload,
                  let granted = payload.readInteger(as: UInt32.self)
            else { return }
            let wasStalled = stream.credit <= 0
            stream.credit += Int(granted)
            if wasStalled && stream.credit > 0 {
                stream.channel?.setOption(ChannelOptions.autoRead, value: true).whenFailure { _ in }
            }
        }
    }

    private func deliver(_ bytes: ByteBuffer, to stream: Stream, id: UInt32) {
        guard let local = stream.channel else { return }
        let count = bytes.readableBytes
        local.writeAndFlush(bytes).whenSuccess { [weak self] in
            self?.acknowledge(id, count)
        }
    }

    /// Grants the sender more room once a quarter of the window has drained.
    private func acknowledge(_ id: UInt32, _ count: Int) {
        guard let stream = streams[id] else { return }
        stream.unacknowledged += count
        guard stream.unacknowledged >= TunnelProtocol.streamWindow / 4 else { return }
        var payload = channel.allocator.buffer(capacity: 4)
        payload.writeInteger(UInt32(stream.unacknowledged))
        stream.unacknowledged = 0
        sendFrame(TunnelFrame(kind: .window, stream: id, payload: payload))
    }

    func didClose() {
        keepalive?.cancel()
        keepalive = nil
        let open = streams
        streams = [:]
        for stream in open.values { stream.channel?.close(promise: nil) }
        onClose?()
        onClose = nil
    }

    // MARK: - Outbound

    private func sendFrame(_ frame: TunnelFrame) {
        write(WebSocketFrame(
            fin: true, opcode: .binary, maskKey: mask(),
            data: frame.encoded(allocator: channel.allocator)
        ))
    }

    private func write(_ frame: WebSocketFrame) {
        guard channel.isActive else { return }
        channel.writeAndFlush(frame, promise: nil)
    }

    private func mask() -> WebSocketMaskingKey? {
        masksFrames ? .random() : nil
    }
}

// MARK: - Pipeline

extension TunnelMux {
    /// Turns a channel that has just finished the WebSocket handshake into a
    /// tunnel. `leftover` is anything read past the end of the handshake.
    public static func install(
        on channel: Channel, masksFrames: Bool, leftover: ByteBuffer?
    ) throws -> TunnelMux {
        let mux = TunnelMux(channel: channel, masksFrames: masksFrames)
        let decoder = ByteToMessageHandler(WebSocketFrameDecoder(maxFrameSize: TunnelProtocol.maxWebSocketFrame))
        try channel.pipeline.syncOperations.addHandlers([
            WebSocketFrameEncoder(),
            decoder,
            TunnelSocketHandler(mux: mux),
        ])
        if let leftover, leftover.readableBytes > 0 {
            channel.pipeline.fireChannelRead(leftover)
        }
        return mux
    }
}

/// Sits at the end of the WebSocket channel's pipeline.
final class TunnelSocketHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame

    private let mux: TunnelMux

    init(mux: TunnelMux) {
        self.mux = mux
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        mux.receive(unwrapInboundIn(data))
    }

    func channelInactive(context: ChannelHandlerContext) {
        mux.didClose()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

/// Bridges a plain TCP channel into a tunnel stream: what it reads is sent,
/// and when it closes, the stream ends.
public final class TunnelStreamHandler: ChannelInboundHandler {
    public typealias InboundIn = ByteBuffer

    private let mux: TunnelMux
    private let id: UInt32

    public init(mux: TunnelMux, id: UInt32) {
        self.mux = mux
        self.id = id
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        mux.send(id, unwrapInboundIn(data))
    }

    public func channelInactive(context: ChannelHandlerContext) {
        mux.close(id)
        context.fireChannelInactive()
    }

    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}
