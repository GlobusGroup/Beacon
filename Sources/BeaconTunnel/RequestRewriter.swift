import Foundation
import NIOCore

/// Rewrites the forwarding headers on **every** request travelling up a
/// connection, not just the first.
///
/// Browsers reuse a connection for dozens of requests. A proxy that only
/// stamps `X-Forwarded-Proto` on the first one leaves a framework generating
/// `http://` links for a page the user is viewing over `https://` — which is
/// the exact breakage this proxy exists to avoid. So the request direction is
/// tracked as a stream: head, body (sized or chunked), head, body, and so on.
///
/// The response direction is never parsed. Beacon has no opinion about what
/// comes back, so SSE, HTTP/1.0 responses and anything else pass through
/// untouched.
///
/// Once the connection stops being HTTP — a WebSocket upgrade, or CONNECT —
/// the rewriter switches to `raw` and copies bytes verbatim for good.
public final class RequestRewriter {
    public enum Outcome {
        /// Bytes ready to go upstream. May be empty if more input is needed.
        case forward(ByteBuffer)
        /// The head was unparseable or implausibly large.
        case malformed(reason: String)
    }

    private enum Mode {
        case awaitingHead
        case body(remaining: Int)
        case chunkSize
        case chunkData(remaining: Int)
        case chunkTrailer
        case raw
    }

    private var mode: Mode = .awaitingHead
    private var buffer: ByteBuffer
    private let scheme: String
    private let listenPort: Int
    private let clientIP: String
    private let trustForwardedFor: Bool
    private let maxRequests: Int?
    private let closeConnection: Bool
    private var headsSeen = 0

    /// Host from the first request head, used to pick the upstream.
    public private(set) var host: String?
    /// The first request head on the connection, as the client sent it.
    public private(set) var firstHead: HTTPHead?

    /// - Parameters:
    ///   - trustForwardedFor: take the client address from the last entry of an
    ///     incoming `X-Forwarded-For`, for a rewriter sitting behind a proxy it trusts.
    ///   - maxRequests: stop forwarding after this many request heads. Later
    ///     input is held back, never written upstream.
    ///   - closeConnection: ask the upstream to close after each response.
    public init(
        allocator: ByteBufferAllocator, scheme: String, listenPort: Int, clientIP: String,
        trustForwardedFor: Bool = false, maxRequests: Int? = nil, closeConnection: Bool = false
    ) {
        self.buffer = allocator.buffer(capacity: 4096)
        self.scheme = scheme
        self.listenPort = listenPort
        self.clientIP = clientIP
        self.trustForwardedFor = trustForwardedFor
        self.maxRequests = maxRequests
        self.closeConnection = closeConnection
    }

    public func append(_ incoming: inout ByteBuffer) {
        buffer.writeBuffer(&incoming)
    }

    /// Consumes as much of the buffered input as it can, returning what should
    /// be written upstream.
    public func drain(allocator: ByteBufferAllocator) -> Outcome {
        var out = allocator.buffer(capacity: buffer.readableBytes + 256)

        loop: while true {
            switch mode {
            case .raw:
                if buffer.readableBytes > 0, var rest = buffer.readSlice(length: buffer.readableBytes) {
                    out.writeBuffer(&rest)
                }
                break loop

            case .awaitingHead:
                guard buffer.readableBytes > 0 else { break loop }
                if let maxRequests, headsSeen >= maxRequests { break loop }
                guard let head = HTTPHead.parse(buffer) else {
                    if buffer.readableBytes > HTTPHead.maxSize {
                        return .malformed(reason: "the request head exceeded \(HTTPHead.maxSize / 1024)KB")
                    }
                    break loop
                }
                if host == nil { host = head.host }
                if firstHead == nil { firstHead = head }
                guard let currentHost = head.host ?? host else {
                    return .malformed(reason: "the request had no Host header")
                }

                headsSeen += 1
                out.writeBytes(head.rewritten(
                    proto: scheme, host: currentHost, port: listenPort,
                    clientIP: clientAddress(for: head), closeConnection: closeConnection
                ))
                buffer.moveReaderIndex(forwardBy: head.byteLength)
                mode = framing(after: head)

            case .body(let remaining):
                let take = min(remaining, buffer.readableBytes)
                guard take > 0 else { break loop }
                if var slice = buffer.readSlice(length: take) { out.writeBuffer(&slice) }
                mode = remaining - take == 0 ? .awaitingHead : .body(remaining: remaining - take)

            case .chunkSize:
                guard let line = readLine(copyingInto: &out) else { break loop }
                // "1a3;ext=1" — only the hex prefix matters.
                let hex = line.prefix { $0 != ";" }.trimmingCharacters(in: .whitespaces)
                guard let size = Int(hex, radix: 16) else {
                    return .malformed(reason: "a chunked request had an unreadable chunk size")
                }
                // Chunk payloads are followed by their own CRLF.
                mode = size == 0 ? .chunkTrailer : .chunkData(remaining: size + 2)

            case .chunkData(let remaining):
                let take = min(remaining, buffer.readableBytes)
                guard take > 0 else { break loop }
                if var slice = buffer.readSlice(length: take) { out.writeBuffer(&slice) }
                mode = remaining - take == 0 ? .chunkSize : .chunkData(remaining: remaining - take)

            case .chunkTrailer:
                guard let line = readLine(copyingInto: &out) else { break loop }
                if line.isEmpty { mode = .awaitingHead }
            }
        }

        buffer.discardReadBytes()
        return .forward(out)
    }

    private func clientAddress(for head: HTTPHead) -> String {
        guard trustForwardedFor, let forwarded = head.value(of: "X-Forwarded-For") else { return clientIP }
        // The trusted proxy appends the address it saw, so the last entry is
        // the only one it vouches for.
        let last = forwarded.split(separator: ",").last.map { $0.trimmingCharacters(in: .whitespaces) }
        return last.flatMap { $0.isEmpty ? nil : $0 } ?? clientIP
    }

    /// How long this request's body is, or whether the connection stops being
    /// HTTP after this head.
    private func framing(after head: HTTPHead) -> Mode {
        let method = head.requestLine.prefix { $0 != " " }.uppercased()
        if method == "CONNECT" { return .raw }

        // A successful upgrade turns the connection into something else
        // entirely. Browsers only send this for WebSockets, which dev servers
        // accept; treating it as raw from here is the safe reading.
        if head.value(of: "Upgrade") != nil { return .raw }

        if let encoding = head.value(of: "Transfer-Encoding"),
           encoding.lowercased().contains("chunked") {
            return .chunkSize
        }
        if let length = head.value(of: "Content-Length").flatMap({ Int($0) }), length > 0 {
            return .body(remaining: length)
        }
        return .awaitingHead
    }

    /// Reads one CRLF-terminated line, copying it through unchanged.
    /// Returns nil when the line hasn't fully arrived.
    private func readLine(copyingInto out: inout ByteBuffer) -> String? {
        let view = buffer.readableBytesView
        guard let lf = view.firstIndex(of: 0x0A) else {
            if buffer.readableBytes > HTTPHead.maxSize { return "" }
            return nil
        }
        let length = lf - view.startIndex + 1
        guard var slice = buffer.readSlice(length: length) else { return nil }
        let text = slice.readString(length: length) ?? ""
        out.writeString(text)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
