import Foundation

public enum PortProbe {
    /// True when a dev server is actually listening on this port right now.
    ///
    /// Tries to bind rather than connect: binding gives an immediate answer
    /// with no handshake, and a server that accepts but never replies still
    /// counts as up.
    public static func isListening(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        // Only "in use" means a listener. Ports below 1024 refuse an
        // unprivileged bind with EACCES whether or not anything is there.
        return bound != 0 && errno == EADDRINUSE
    }
}
