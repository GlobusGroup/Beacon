import Foundation

/// Talks to `beacond` over its Unix socket. Deliberately built on raw POSIX
/// calls rather than a networking framework: the CLI is invoked constantly by
/// shells and agents, and process start-up time is the whole user experience.
public struct BeaconClient: Sendable {
    public let socketPath: String
    public let timeout: TimeInterval

    public init(socketPath: String = BeaconPaths.socketPath, timeout: TimeInterval = 10) {
        self.socketPath = socketPath
        self.timeout = timeout
    }

    public var daemonIsReachable: Bool {
        (try? send(BeaconRequest(op: .ping))) != nil
    }

    public func send(_ request: BeaconRequest) throws -> BeaconResponse {
        guard FileManager.default.fileExists(atPath: socketPath) else {
            throw BeaconClientError(
                code: "daemon_not_running",
                message: "Beacon's daemon isn't running. Install it with `sudo beacon install`."
            )
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw BeaconClientError(code: "socket_failed", message: "socket(): \(errnoText())")
        }
        defer { close(fd) }

        var tv = timeval(
            tv_sec: Int(timeout),
            tv_usec: Int32((timeout - floor(timeout)) * 1_000_000)
        )
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathLength = MemoryLayout.size(ofValue: addr.sun_path)
        guard socketPath.utf8.count < pathLength else {
            throw BeaconClientError(code: "socket_path_too_long", message: "Socket path is too long.")
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { tuplePtr in
            tuplePtr.withMemoryRebound(to: CChar.self, capacity: pathLength) { dst in
                _ = strncpy(dst, socketPath, pathLength - 1)
            }
        }

        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            throw BeaconClientError(
                code: "daemon_not_running",
                message: "Couldn't reach Beacon's daemon (\(errnoText())). Try `sudo beacon restart`."
            )
        }

        var payload = try BeaconJSON.encoder.encode(request)
        payload.append(0x0A)
        try writeAll(fd, payload)

        let line = try readLine(fd)
        do {
            return try BeaconJSON.decoder.decode(BeaconResponse.self, from: line)
        } catch {
            throw BeaconClientError(
                code: "bad_response",
                message: "Daemon sent something unreadable: \(String(decoding: line, as: UTF8.self))"
            )
        }
    }

    /// Sends a request and unwraps the failure case into a thrown error.
    @discardableResult
    public func require(_ request: BeaconRequest) throws -> BeaconResponse {
        let response = try send(request)
        guard response.ok else {
            throw BeaconClientError(
                code: response.errorCode ?? "error",
                message: response.error ?? "Beacon refused the request.",
                details: response.errorDetails
            )
        }
        return response
    }

    // MARK: - Convenience

    public func list() throws -> [Site] {
        try require(BeaconRequest(op: .list)).sites ?? []
    }

    public func status() throws -> DaemonStatus? {
        try require(BeaconRequest(op: .status)).status
    }

    public func register(_ spec: RegisterSpec) throws -> Site {
        guard let site = try require(BeaconRequest(op: .register, register: spec)).site else {
            throw BeaconClientError(code: "bad_response", message: "Daemon returned no site.")
        }
        return site
    }

    public func unregister(name: String) throws {
        try require(BeaconRequest(op: .unregister, name: name))
    }

    public func info(name: String) throws -> Site {
        guard let site = try require(BeaconRequest(op: .info, name: name)).site else {
            throw BeaconClientError(code: "unknown_site", message: "No project named '\(name)'.")
        }
        return site
    }

    public func config() throws -> BeaconConfig {
        try require(BeaconRequest(op: .getConfig)).config ?? .default
    }

    public func setConfig(_ config: BeaconConfig) throws -> BeaconConfig {
        try require(BeaconRequest(op: .setConfig, config: config)).config ?? config
    }

    /// Starts the project's run command. Returns at once; poll `runStatus`.
    @discardableResult
    public func start(name: String) throws -> RunStatus? {
        try require(BeaconRequest(op: .start, name: name)).run
    }

    @discardableResult
    public func stop(name: String) throws -> RunStatus? {
        try require(BeaconRequest(op: .stop, name: name)).run
    }

    public func runStatus(name: String) throws -> RunStatus? {
        try require(BeaconRequest(op: .runStatus, name: name)).run
    }

    // MARK: Sharing

    @discardableResult
    public func share(_ spec: ShareSpec) throws -> RelayStatus? {
        try require(BeaconRequest(op: .share, share: spec)).relay
    }

    @discardableResult
    public func unshare(name: String) throws -> RelayStatus? {
        try require(BeaconRequest(op: .unshare, name: name)).relay
    }

    public func relayStatus() throws -> RelayStatus? {
        try require(BeaconRequest(op: .relayStatus)).relay
    }

    @discardableResult
    public func setRelay(_ spec: RelaySpec) throws -> RelayStatus? {
        try require(BeaconRequest(op: .setRelay, relay: spec)).relay
    }

    /// Asks the daemon to exit; launchd's KeepAlive starts a fresh one.
    /// Needs no password, unlike `launchctl kickstart`.
    public func restart() throws {
        try require(BeaconRequest(op: .restart))
    }

    /// Polls until the daemon answers. launchd returns before a freshly
    /// started daemon has bound its socket.
    public func waitUntilReachable(timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if daemonIsReachable { return true }
            usleep(200_000)
        }
        return false
    }

    /// Polls until the daemon stops answering, so a restart can be told apart
    /// from the old process still being up.
    public func waitUntilUnreachable(timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !daemonIsReachable { return true }
            usleep(100_000)
        }
        return false
    }

    // MARK: - Socket plumbing

    private func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            while offset < raw.count {
                let written = write(fd, base + offset, raw.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0 && errno == EINTR {
                    continue
                } else {
                    throw BeaconClientError(code: "write_failed", message: "write(): \(errnoText())")
                }
            }
        }
    }

    /// Reads until the first newline. Responses are a single line by contract.
    private func readLine(_ fd: Int32) throws -> Data {
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n > 0 {
                if let newline = buffer[0..<n].firstIndex(of: 0x0A) {
                    out.append(contentsOf: buffer[0..<newline])
                    return out
                }
                out.append(contentsOf: buffer[0..<n])
            } else if n == 0 {
                if out.isEmpty {
                    throw BeaconClientError(
                        code: "daemon_closed",
                        message: "The daemon closed the connection without answering."
                    )
                }
                return out
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                throw BeaconClientError(code: "timeout", message: "The daemon didn't answer in time.")
            } else {
                throw BeaconClientError(code: "read_failed", message: "read(): \(errnoText())")
            }
        }
    }

    private func errnoText() -> String {
        String(cString: strerror(errno))
    }
}
