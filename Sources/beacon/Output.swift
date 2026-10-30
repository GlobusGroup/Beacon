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

    static func fail(_ message: String) -> Never {
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
        print("")
    }
}
