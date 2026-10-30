import Foundation

enum Log {
    nonisolated(unsafe) static var verbose = false
    private static let lock = NSLock()
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func debug(_ message: @autoclosure () -> String) {
        guard verbose else { return }
        emit("debug", message())
    }

    static func info(_ message: @autoclosure () -> String) { emit("info", message()) }
    static func warn(_ message: @autoclosure () -> String) { emit("warn", message()) }
    static func error(_ message: @autoclosure () -> String) { emit("error", message()) }

    private static func emit(_ level: String, _ message: String) {
        let line = "\(formatter.string(from: Date())) [\(level)] \(message)\n"
        lock.lock()
        FileHandle.standardError.write(Data(line.utf8))
        lock.unlock()
    }
}
