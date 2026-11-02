import Foundation

/// One project: a name, the local domain it answers on, and the port Beacon
/// reserved for it. The port is assigned once and never changes under the
/// project's feet — re-registering the same name returns the same port.
public struct Site: Codable, Hashable, Identifiable, Sendable {
    public var name: String
    public var domain: String
    public var port: Int
    /// Absolute path to the project directory, when the caller supplied one.
    public var path: String?
    /// Extra domains routed to the same port, e.g. `api.myproject.test`.
    public var aliases: [String]
    /// Whether links handed back to humans should be https.
    public var secure: Bool
    /// How to start the project, when someone set it explicitly. Otherwise
    /// Beacon detects it from the project directory each time; see `runSpec`.
    public var run: RunSpec?
    public var createdAt: Date

    public init(
        name: String,
        domain: String,
        port: Int,
        path: String? = nil,
        aliases: [String] = [],
        secure: Bool = true,
        run: RunSpec? = nil,
        createdAt: Date = Date()
    ) {
        self.name = name
        self.domain = domain
        self.port = port
        self.path = path
        self.aliases = aliases
        self.secure = secure
        self.run = run
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case name, domain, port, path, aliases, secure, run, createdAt
        case url, httpUrl, origin
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        domain = try container.decode(String.self, forKey: .domain)
        port = try container.decode(Int.self, forKey: .port)
        path = try container.decodeIfPresent(String.self, forKey: .path)
        aliases = try container.decodeIfPresent([String].self, forKey: .aliases) ?? []
        secure = try container.decodeIfPresent(Bool.self, forKey: .secure) ?? true
        run = try container.decodeIfPresent(RunSpec.self, forKey: .run)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }

    /// Encodes the derived URLs alongside the stored fields. Callers — scripts
    /// and coding agents especially — should never have to assemble a URL from
    /// a scheme and a domain themselves, and get it subtly wrong.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(domain, forKey: .domain)
        try container.encode(port, forKey: .port)
        try container.encodeIfPresent(path, forKey: .path)
        try container.encode(aliases, forKey: .aliases)
        try container.encode(secure, forKey: .secure)
        try container.encodeIfPresent(run, forKey: .run)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(url, forKey: .url)
        try container.encode(httpURL, forKey: .httpUrl)
        try container.encode(origin, forKey: .origin)
    }

    public var id: String { name }

    /// The URL a human or an LLM should be given. Never includes a port.
    public var url: String { (secure ? "https://" : "http://") + domain }
    public var httpURL: String { "http://" + domain }
    public var httpsURL: String { "https://" + domain }
    /// Where the project's own dev server must listen.
    public var origin: String { "http://127.0.0.1:\(port)" }

    /// How Beacon would start this project: the explicit command if one was
    /// set, otherwise whatever the project directory suggests.
    public var runSpec: RunSpec? {
        if let run { return run }
        guard let path else { return nil }
        return RunDetector.detect(in: path, port: port)
    }

    /// Every hostname that routes here.
    public var allDomains: [String] { [domain] + aliases }

    public var tld: String { Site.tld(of: domain) }

    public static func tld(of domain: String) -> String {
        String(domain.split(separator: ".").last ?? "")
    }

    /// Turns a free-form project name into a usable DNS label.
    public static func slug(_ raw: String) -> String {
        let lowered = raw.lowercased()
        var out = ""
        var lastWasDash = false
        for ch in lowered {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
                lastWasDash = false
            } else if !lastWasDash && !out.isEmpty {
                out.append("-")
                lastWasDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }
}

/// Daemon-wide settings. Editable from the menu bar app or `beacon config`.
public struct BeaconConfig: Codable, Hashable, Sendable {
    /// TLDs Beacon claims. A resolver file is installed for each one.
    public var tlds: [String]
    /// Inclusive port range new projects are allocated from.
    public var portRangeStart: Int
    public var portRangeEnd: Int
    /// Default scheme for newly registered sites.
    public var defaultSecure: Bool

    public static let `default` = BeaconConfig(
        tlds: ["test"],
        portRangeStart: 3100,
        portRangeEnd: 3999,
        defaultSecure: true
    )

    public init(tlds: [String], portRangeStart: Int, portRangeEnd: Int, defaultSecure: Bool) {
        self.tlds = tlds
        self.portRangeStart = portRangeStart
        self.portRangeEnd = portRangeEnd
        self.defaultSecure = defaultSecure
    }

    public var primaryTLD: String { tlds.first ?? "test" }
    public var portRange: ClosedRange<Int> {
        let lo = min(portRangeStart, portRangeEnd)
        let hi = max(portRangeStart, portRangeEnd)
        return lo...hi
    }
}
