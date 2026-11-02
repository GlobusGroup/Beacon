import Crypto
import Foundation
import NIOCore

/// The wire format between `beacond` on a Mac and `beacon-relay` on a server.
///
/// A Mac holds one WebSocket open to the relay. Text messages carry JSON
/// control traffic: the Mac says which projects it shares, the relay answers
/// with their public URLs. Binary messages carry `TunnelFrame`s, which
/// multiplex any number of byte streams, one per public connection.
public enum TunnelProtocol {
    public static let version = 1
    /// Where a Mac opens its tunnel, on the relay's apex domain.
    public static let path = "/_tunnel"
    /// Bytes either side may send on one stream before the other acknowledges them.
    public static let streamWindow = 512 * 1024
    /// Largest payload carried by a single DATA frame.
    public static let maxChunk = 64 * 1024
    /// Comfortably above `maxChunk` plus the frame header.
    public static let maxWebSocketFrame = 1 << 20
}

/// One unit of multiplexed traffic.
///
/// Layout: `[type: u8][stream: u32 big-endian][payload]`.
public struct TunnelFrame {
    public enum Kind: UInt8 {
        /// Relay → Mac: a public connection arrived. Payload is the share name.
        case open = 1
        /// Bytes for the stream, in either direction.
        case data = 2
        /// Either side: the stream is finished. No payload.
        case close = 3
        /// Either side: the sender has written this many more of the stream's
        /// bytes onward. Payload is a u32. Lets the other side send that much more.
        case window = 4
    }

    public var kind: Kind
    public var stream: UInt32
    public var payload: ByteBuffer?

    public init(kind: Kind, stream: UInt32, payload: ByteBuffer? = nil) {
        self.kind = kind
        self.stream = stream
        self.payload = payload
    }

    public func encoded(allocator: ByteBufferAllocator) -> ByteBuffer {
        var out = allocator.buffer(capacity: 5 + (payload?.readableBytes ?? 0))
        out.writeInteger(kind.rawValue)
        out.writeInteger(stream)
        if var payload { out.writeBuffer(&payload) }
        return out
    }

    public static func decode(_ buffer: ByteBuffer) -> TunnelFrame? {
        var buffer = buffer
        guard let raw = buffer.readInteger(as: UInt8.self),
              let kind = Kind(rawValue: raw),
              let stream = buffer.readInteger(as: UInt32.self)
        else { return nil }
        return TunnelFrame(kind: kind, stream: stream, payload: buffer.readableBytes > 0 ? buffer : nil)
    }
}

// MARK: - Control messages

/// A project the Mac wants reachable through the relay.
public struct TunnelShare: Codable, Sendable, Hashable {
    public var name: String
    /// When set, the relay demands HTTP basic auth with this password.
    public var password: String?

    public init(name: String, password: String? = nil) {
        self.name = name
        self.password = password
    }
}

/// Mac → relay. Always the complete set; anything missing stops being shared.
public struct TunnelClientMessage: Codable, Sendable {
    public var version: Int
    public var shares: [TunnelShare]

    public init(shares: [TunnelShare]) {
        self.version = TunnelProtocol.version
        self.shares = shares
    }
}

public struct TunnelShareStatus: Codable, Sendable, Hashable {
    public var name: String
    /// The public URL, once the relay has claimed a hostname for it.
    public var url: String?
    public var error: String?

    public init(name: String, url: String? = nil, error: String? = nil) {
        self.name = name
        self.url = url
        self.error = error
    }
}

/// Relay → Mac, in answer to every `TunnelClientMessage`.
public struct TunnelRelayMessage: Codable, Sendable {
    /// The token's label, which namespaces every hostname this Mac gets.
    public var label: String
    public var shares: [TunnelShareStatus]

    public init(label: String, shares: [TunnelShareStatus]) {
        self.label = label
        self.shares = shares
    }
}

// MARK: - Handshake

/// The two halves of a WebSocket opening handshake, done by hand because both
/// ends already parse HTTP heads themselves and need nothing else from HTTP.
public enum WebSocketHandshake {
    private static let guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    public static func randomKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        return Data(bytes).base64EncodedString()
    }

    public static func accept(for key: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data((key + guid).utf8))
        return Data(digest).base64EncodedString()
    }

    public static func serverResponse(key: String) -> String {
        "HTTP/1.1 101 Switching Protocols\r\n"
            + "Upgrade: websocket\r\n"
            + "Connection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: \(accept(for: key))\r\n"
            + "\r\n"
    }

    public static func clientRequest(host: String, path: String, key: String, token: String) -> String {
        "GET \(path) HTTP/1.1\r\n"
            + "Host: \(host)\r\n"
            + "Upgrade: websocket\r\n"
            + "Connection: Upgrade\r\n"
            + "Sec-WebSocket-Key: \(key)\r\n"
            + "Sec-WebSocket-Version: 13\r\n"
            + "Authorization: Bearer \(token)\r\n"
            + "User-Agent: beacond/\(TunnelProtocol.version)\r\n"
            + "\r\n"
    }
}

/// Compares secrets without leaking, through timing, how much of a guess was right.
public func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
    let a = Array(lhs.utf8)
    let b = Array(rhs.utf8)
    var difference = UInt8(a.count == b.count ? 0 : 1)
    for index in 0..<max(a.count, b.count) {
        let x = index < a.count ? a[index] : 0
        let y = index < b.count ? b[index] : 0
        difference |= x ^ y
    }
    return difference == 0
}
