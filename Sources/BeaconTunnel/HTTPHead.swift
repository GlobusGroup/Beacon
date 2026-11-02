import NIOCore
import Foundation

/// The small amount of HTTP parsing the proxy actually needs.
///
/// Beacon reads the request head to find the Host, rewrites the forwarding
/// headers, and from then on relays raw bytes. That keeps keep-alive, chunked
/// bodies, SSE, WebSocket upgrades and HTTP/2-over-TLS working without Beacon
/// having to understand any of them.
public struct HTTPHead {
    public var requestLine: String
    public var headers: [(name: String, value: String)]
    /// Total byte length of the head, including the blank line that ends it.
    public var byteLength: Int

    public static let terminator: [UInt8] = Array("\r\n\r\n".utf8)
    /// A head larger than this is not a request we want to serve.
    public static let maxSize = 64 * 1024

    public static func parse(_ buffer: ByteBuffer) -> HTTPHead? {
        let bytes = buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes) ?? []
        guard let end = find(terminator, in: bytes) else { return nil }

        let headBytes = Array(bytes[0..<end])
        guard let text = String(bytes: headBytes, encoding: .utf8) else { return nil }

        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst()
        guard requestLine.contains(" ") else { return nil }

        var headers: [(String, String)] = []
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon])
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            headers.append((name, value))
        }

        return HTTPHead(
            requestLine: requestLine,
            headers: headers,
            byteLength: end + terminator.count
        )
    }

    public func value(of name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    public var host: String? { value(of: "Host") }

    public var method: String { String(requestLine.prefix { $0 != " " }).uppercased() }

    /// The path and query, e.g. `/__beacon/status?x=1`.
    public var target: String {
        let parts = requestLine.split(separator: " ")
        return parts.count > 1 ? String(parts[1]) : ""
    }

    /// Re-emits the head with trustworthy forwarding headers.
    ///
    /// Anything the client sent as `X-Forwarded-*` is dropped first: Beacon is
    /// the edge here, so those values are ours to state, not the caller's to claim.
    ///
    /// `closeConnection` asks the upstream to close after answering, for a
    /// caller that must see exactly one request per connection. Upgrade
    /// requests keep their `Connection: Upgrade`.
    public func rewritten(
        proto: String, host: String, port: Int, clientIP: String, closeConnection: Bool = false
    ) -> [UInt8] {
        let replacingConnection = closeConnection && value(of: "Upgrade") == nil
        let hopByHop: Set<String> = ["connection", "keep-alive", "proxy-connection"]

        var out = requestLine + "\r\n"
        for header in headers {
            let name = header.name.lowercased()
            if name.hasPrefix("x-forwarded-") { continue }
            if replacingConnection && hopByHop.contains(name) { continue }
            out += "\(header.name): \(header.value)\r\n"
        }
        if replacingConnection { out += "Connection: close\r\n" }
        out += "X-Forwarded-For: \(clientIP)\r\n"
        out += "X-Forwarded-Proto: \(proto)\r\n"
        out += "X-Forwarded-Host: \(host)\r\n"
        out += "X-Forwarded-Port: \(port)\r\n"
        out += "X-Beacon: 1\r\n"
        out += "\r\n"
        return Array(out.utf8)
    }

    private static func find(_ needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard haystack.count >= needle.count else { return nil }
        let limit = haystack.count - needle.count
        var index = 0
        while index <= limit {
            if haystack[index] == needle[0] {
                var matched = true
                for offset in 1..<needle.count where haystack[index + offset] != needle[offset] {
                    matched = false
                    break
                }
                if matched { return index }
            }
            index += 1
        }
        return nil
    }
}
