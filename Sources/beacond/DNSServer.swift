import NIOCore
import NIOPosix
import Foundation

/// A deliberately tiny authoritative DNS server.
///
/// macOS only sends us queries for the TLDs listed in `/etc/resolver`, so there
/// is no need to be a real resolver: anything that reaches this server is a
/// Beacon domain, and the answer is always the loopback address. That is also
/// why wildcards come free — `anything.myproject.test` resolves without the
/// project having to register it.
///
/// Running on a high port (not 53) keeps us out of the way of any real DNS
/// software; the resolver file carries a `port` directive to match.
enum DNSMessage {
    struct Question {
        var name: String
        var type: UInt16
        var `class`: UInt16
        /// Byte length of the question section, used to find the end of the query.
        var byteLength: Int
    }

    static let typeA: UInt16 = 1
    static let typeAAAA: UInt16 = 28
    static let classIN: UInt16 = 1

    /// Parses just enough of the query to answer it.
    static func parseQuestion(_ buffer: ByteBuffer) -> Question? {
        var reader = buffer
        guard reader.readableBytes >= 12 else { return nil }
        reader.moveReaderIndex(forwardBy: 12)

        var labels: [String] = []
        var consumed = 0
        while true {
            guard let length = reader.readInteger(as: UInt8.self) else { return nil }
            consumed += 1
            if length == 0 { break }
            // Compression pointers are illegal in a question; bail rather than loop.
            guard length & 0xC0 == 0 else { return nil }
            guard let label = reader.readString(length: Int(length)) else { return nil }
            consumed += Int(length)
            labels.append(label)
        }

        guard let type = reader.readInteger(as: UInt16.self),
              let qclass = reader.readInteger(as: UInt16.self) else { return nil }

        return Question(
            name: labels.joined(separator: "."),
            type: type,
            class: qclass,
            byteLength: consumed + 4
        )
    }

    /// Builds a reply that echoes the question and answers it with loopback.
    static func makeReply(
        to query: ByteBuffer,
        question: Question,
        allocator: ByteBufferAllocator
    ) -> ByteBuffer {
        var out = allocator.buffer(capacity: 128)

        let id = query.getInteger(at: query.readerIndex, as: UInt16.self) ?? 0
        let queryFlags = query.getInteger(at: query.readerIndex + 2, as: UInt16.self) ?? 0
        let recursionDesired = queryFlags & 0x0100

        // QR=1 (response), AA=1 (authoritative), RCODE=0, plus the caller's RD bit.
        let flags: UInt16 = 0x8400 | recursionDesired

        let answersIPv4 = question.type == typeA && question.class == classIN
        let answersIPv6 = question.type == typeAAAA && question.class == classIN
        let answerCount: UInt16 = (answersIPv4 || answersIPv6) ? 1 : 0

        out.writeInteger(id)
        out.writeInteger(flags)
        out.writeInteger(UInt16(1))            // QDCOUNT
        out.writeInteger(answerCount)          // ANCOUNT
        out.writeInteger(UInt16(0))            // NSCOUNT
        out.writeInteger(UInt16(0))            // ARCOUNT

        // Echo the question verbatim.
        if let questionBytes = query.getSlice(at: query.readerIndex + 12, length: question.byteLength) {
            out.writeImmutableBuffer(questionBytes)
        }

        if answerCount == 1 {
            out.writeInteger(UInt16(0xC00C))   // pointer back to the name at offset 12
            out.writeInteger(question.type)
            out.writeInteger(classIN)
            out.writeInteger(UInt32(60))       // TTL — short, so edits take effect fast
            if answersIPv4 {
                out.writeInteger(UInt16(4))
                out.writeBytes([127, 0, 0, 1])
            } else {
                out.writeInteger(UInt16(16))
                out.writeBytes([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]) // ::1
            }
        }

        return out
    }

    /// NOTIMP/FORMERR style refusal for anything we couldn't parse.
    static func makeFormatError(to query: ByteBuffer, allocator: ByteBufferAllocator) -> ByteBuffer {
        var out = allocator.buffer(capacity: 12)
        let id = query.getInteger(at: query.readerIndex, as: UInt16.self) ?? 0
        out.writeInteger(id)
        out.writeInteger(UInt16(0x8001))       // QR=1, RCODE=1 (FORMERR)
        out.writeInteger(UInt16(0))
        out.writeInteger(UInt16(0))
        out.writeInteger(UInt16(0))
        out.writeInteger(UInt16(0))
        return out
    }
}

final class DNSDatagramHandler: ChannelInboundHandler {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    typealias OutboundOut = AddressedEnvelope<ByteBuffer>

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)
        let reply: ByteBuffer

        if let question = DNSMessage.parseQuestion(envelope.data) {
            Log.debug("DNS \(question.name) type \(question.type)")
            reply = DNSMessage.makeReply(
                to: envelope.data,
                question: question,
                allocator: context.channel.allocator
            )
        } else {
            reply = DNSMessage.makeFormatError(
                to: envelope.data,
                allocator: context.channel.allocator
            )
        }

        context.writeAndFlush(
            wrapOutboundOut(AddressedEnvelope(remoteAddress: envelope.remoteAddress, data: reply)),
            promise: nil
        )
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        Log.debug("DNS datagram error: \(error)")
    }
}

/// DNS over TCP: the same payload behind a two-byte length prefix.
final class DNSStreamHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private var pending = ByteBuffer()

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        pending.writeBuffer(&incoming)

        while true {
            guard let length = pending.getInteger(at: pending.readerIndex, as: UInt16.self),
                  pending.readableBytes >= Int(length) + 2 else { return }
            pending.moveReaderIndex(forwardBy: 2)
            guard let message = pending.readSlice(length: Int(length)) else { return }
            pending.discardReadBytes()

            let body: ByteBuffer
            if let question = DNSMessage.parseQuestion(message) {
                body = DNSMessage.makeReply(
                    to: message, question: question, allocator: context.channel.allocator
                )
            } else {
                body = DNSMessage.makeFormatError(to: message, allocator: context.channel.allocator)
            }

            var framed = context.channel.allocator.buffer(capacity: body.readableBytes + 2)
            framed.writeInteger(UInt16(body.readableBytes))
            framed.writeImmutableBuffer(body)
            context.writeAndFlush(wrapOutboundOut(framed), promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

struct DNSServer {
    let group: EventLoopGroup
    let port: Int

    func start() throws -> [Channel] {
        let datagram = try DatagramBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                channel.pipeline.addHandler(DNSDatagramHandler())
            }
            .bind(host: "127.0.0.1", port: port)
            .wait()

        let stream = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 64)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(DNSStreamHandler())
            }
            .bind(host: "127.0.0.1", port: port)
            .wait()

        Log.info("DNS listening on 127.0.0.1:\(port) (UDP + TCP)")
        return [datagram, stream]
    }
}
