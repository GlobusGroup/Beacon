import Foundation

/// What a caller wants done. One JSON object per line over the Unix socket.
/// Flat and self-describing on purpose: the wire format is something a human
/// (or an agent reading `beacon --debug`) can follow without a decoder ring.
public struct BeaconRequest: Codable, Sendable {
    public enum Op: String, Codable, Sendable {
        case ping
        case status
        case list
        case info
        case register
        case unregister
        case getConfig
        case setConfig
        case restart
    }

    public var op: Op
    public var name: String?
    public var register: RegisterSpec?
    public var config: BeaconConfig?

    public init(op: Op, name: String? = nil, register: RegisterSpec? = nil, config: BeaconConfig? = nil) {
        self.op = op
        self.name = name
        self.register = register
        self.config = config
    }
}

/// A port request. Everything but `name` is optional — the daemon fills in
/// sensible defaults so the minimal call is `{"op":"register","register":{"name":"myproject"}}`.
public struct RegisterSpec: Codable, Sendable {
    public var name: String
    public var domain: String?
    /// Ask for a specific port instead of letting Beacon choose.
    public var port: Int?
    public var path: String?
    public var aliases: [String]?
    public var secure: Bool?
    /// Allocate a fresh port even if this name already holds one.
    public var reassign: Bool?

    public init(
        name: String,
        domain: String? = nil,
        port: Int? = nil,
        path: String? = nil,
        aliases: [String]? = nil,
        secure: Bool? = nil,
        reassign: Bool? = nil
    ) {
        self.name = name
        self.domain = domain
        self.port = port
        self.path = path
        self.aliases = aliases
        self.secure = secure
        self.reassign = reassign
    }
}

public struct DaemonStatus: Codable, Sendable {
    public var version: String
    public var pid: Int32
    public var httpPort: Int
    public var httpsPort: Int
    public var dnsPort: Int
    public var tlds: [String]
    public var resolversInstalled: [String]
    public var siteCount: Int
    public var startedAt: Date

    public init(
        version: String, pid: Int32, httpPort: Int, httpsPort: Int, dnsPort: Int,
        tlds: [String], resolversInstalled: [String],
        siteCount: Int, startedAt: Date
    ) {
        self.version = version
        self.pid = pid
        self.httpPort = httpPort
        self.httpsPort = httpsPort
        self.dnsPort = dnsPort
        self.tlds = tlds
        self.resolversInstalled = resolversInstalled
        self.siteCount = siteCount
        self.startedAt = startedAt
    }
}

public struct BeaconResponse: Codable, Sendable {
    public var ok: Bool
    public var errorCode: String?
    public var error: String?
    public var site: Site?
    public var sites: [Site]?
    public var status: DaemonStatus?
    public var config: BeaconConfig?

    public init(
        ok: Bool = true, errorCode: String? = nil, error: String? = nil,
        site: Site? = nil, sites: [Site]? = nil,
        status: DaemonStatus? = nil, config: BeaconConfig? = nil
    ) {
        self.ok = ok
        self.errorCode = errorCode
        self.error = error
        self.site = site
        self.sites = sites
        self.status = status
        self.config = config
    }

    public static func failure(_ code: String, _ message: String) -> BeaconResponse {
        BeaconResponse(ok: false, errorCode: code, error: message)
    }
}

public struct BeaconClientError: LocalizedError, Sendable {
    public let code: String
    public let message: String
    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
    public var errorDescription: String? { message }
}

public enum BeaconJSON {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    public static let prettyEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
