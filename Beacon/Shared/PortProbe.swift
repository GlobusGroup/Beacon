import Foundation

public enum PortProbe {
    /// True when a dev server is listening on this port right now: something
    /// accepts a connection on 127.0.0.1, which is exactly what the proxy
    /// needs to reach it.
    ///
    /// Connects rather than binds. A bind also fails while connections from
    /// a server that has since exited sit in TIME_WAIT, so a dead project
    /// looked "running" for a minute or so after it stopped.
    public static func isListening(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        // Non-blocking, so a server whose accept queue is full can't hang the
        // caller for the length of a TCP connect timeout.
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        var addr = loopback(port)
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        var pending = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        // No answer in time on loopback means a listener too busy to accept,
        // which is still a listener.
        guard poll(&pending, 1, 300) > 0 else { return true }
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
        return error == 0
    }

    /// True when this port can't be handed to a new project because
    /// something holds it, listening or not. Tries to bind: that's the
    /// question a new dev server will face.
    public static func isTaken(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = loopback(port)
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        // Only "in use" counts. Ports below 1024 refuse an unprivileged bind
        // with EACCES whether or not anything is there.
        return bound != 0 && errno == EADDRINUSE
    }

    private static func loopback(_ port: Int) -> sockaddr_in {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        return addr
    }
}
