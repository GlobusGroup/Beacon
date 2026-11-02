import BeaconKit
import Foundation

enum Output {
    static let isTTY = isatty(STDOUT_FILENO) == 1

    static func style(_ text: String, _ code: String) -> String {
        isTTY ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text
    }

    static func bold(_ text: String) -> String { style(text, "1") }
    static func dim(_ text: String) -> String { style(text, "2") }
    static func green(_ text: String) -> String { style(text, "32") }
    static func yellow(_ text: String) -> String { style(text, "33") }
    static func red(_ text: String) -> String { style(text, "31") }

    static func json<T: Encodable>(_ value: T) {
        guard let data = try? BeaconJSON.prettyEncoder.encode(value) else { return }
        print(String(decoding: data, as: UTF8.self))
    }

    /// Encodes `value` and merges `extra` keys into the top-level object, so
    /// added context never changes the shape callers already parse.
    static func json<T: Encodable>(_ value: T, adding extra: [String: Any]) {
        guard !extra.isEmpty,
              let data = try? BeaconJSON.encoder.encode(value),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return json(value) }
        object.merge(extra) { _, new in new }
        guard let merged = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return json(value) }
        print(String(decoding: merged, as: UTF8.self))
    }

    /// The failure shape for `--json` callers: on stdout, so a caller piping
    /// stdout into a parser gets an answer instead of empty input.
    static func failJSON(_ error: BeaconClientError, hint: String? = nil) -> Never {
        var body: [String: Any] = ["code": error.code, "message": error.message]
        for (key, value) in error.details ?? [:] {
            body[key] = Int(value).map { $0 as Any } ?? value
        }
        if let hint { body["hint"] = hint }
        let object: [String: Any] = ["ok": false, "error": body]
        if let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) {
            print(String(decoding: data, as: UTF8.self))
        }
        fflush(stdout)
        exit(1)
    }

    static func warn(_ message: String) {
        fflush(stdout)
        FileHandle.standardError.write(Data((yellow("warning: ") + message + "\n").utf8))
    }

    static func fail(_ message: String) -> Never {
        fflush(stdout)
        FileHandle.standardError.write(Data((red("error: ") + message + "\n").utf8))
        exit(1)
    }

    /// The block printed after a successful registration. Spells out the one
    /// thing the caller has to do with the answer — bind to this port, hand out
    /// this URL — because the caller is often an agent acting on it directly.
    static func describe(_ site: Site, running: Bool) {
        let state = running ? green("● running") : dim("○ not running")
        print("")
        print("  \(bold(site.name))  \(state)")
        print("  \(dim("URL "))       \(bold(site.url))")
        if site.secure {
            print("  \(dim("Plain"))     \(site.httpURL)")
        }
        print("  \(dim("Port"))      \(bold(String(site.port)))  \(dim("← bind your dev server here"))")
        for alias in site.aliases {
            print("  \(dim("Alias"))     \(site.secure ? "https://" : "http://")\(alias)")
        }
        if let path = site.path {
            print("  \(dim("Path"))      \(path)")
        }
        if let run = site.runSpec {
            let source = site.run == nil ? dim("  (detected — \(run.label))") : ""
            print("  \(dim("Run"))       \(run.command)\(source)")
        }
        print("")
    }
}
