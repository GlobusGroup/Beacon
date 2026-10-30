import Foundation

enum PortAllocator {
    /// Picks the lowest port in `range` that no other project has reserved and
    /// that nothing is currently listening on.
    ///
    /// Reserved-but-idle ports stay reserved: a project's dev server is down far
    /// more often than it is up, and handing its port to someone else while it
    /// sleeps is exactly the churn this whole app exists to stop.
    static func allocate(in range: ClosedRange<Int>, avoiding taken: Set<Int>) -> Int? {
        for port in range where !taken.contains(port) {
            if isAvailable(port) { return port }
        }
        return nil
    }

    /// True when we can bind the port right now.
    ///
    /// Binding 127.0.0.1 is enough to detect a listener on 0.0.0.0 as well —
    /// the kernel refuses the overlap either way round.
    static func isAvailable(_ port: Int) -> Bool {
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
        return bound == 0
    }

    /// True when a dev server is actually up on this port right now.
    static func isListening(_ port: Int) -> Bool {
        !isAvailable(port)
    }
}
