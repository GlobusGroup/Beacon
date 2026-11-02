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
        /// Bring a project up with its run command.
        case start
        /// Stop a project Beacon started.
        case stop
        case runStatus
        /// Make a project reachable through the relay.
        case share
        case unshare
        case relayStatus
        /// Point Beacon at a relay, or turn sharing off.
        case setRelay
        /// List the tokens the relay accepts. Needs an admin token.
        case relayTokens
        /// Make a token on the relay, for someone new. Needs an admin token.
        case createRelayToken
        /// Revoke the token labelled `name`. Needs an admin token.
        case revokeRelayToken
    }

    public var op: Op
    public var name: String?
    public var register: RegisterSpec?
    public var config: BeaconConfig?
    public var share: ShareSpec?
    public var relay: RelaySpec?
    public var relayToken: RelayTokenSpec?

    public init(
        op: Op, name: String? = nil, register: RegisterSpec? = nil, config: BeaconConfig? = nil,
        share: ShareSpec? = nil, relay: RelaySpec? = nil, relayToken: RelayTokenSpec? = nil
    ) {
        self.op = op
        self.name = name
        self.register = register
        self.config = config
        self.share = share
        self.relay = relay
        self.relayToken = relayToken
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
    /// Shell command that starts the project. An empty string, or `auto`,
    /// goes back to detecting it from the project directory.
    public var run: String?

    public init(
        name: String,
        domain: String? = nil,
        port: Int? = nil,
        path: String? = nil,
        aliases: [String]? = nil,
        secure: Bool? = nil,
        reassign: Bool? = nil,
        run: String? = nil
    ) {
        self.name = name
        self.domain = domain
        self.port = port
        self.path = path
        self.aliases = aliases
        self.secure = secure
        self.reassign = reassign
        self.run = run
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
    /// Machine-readable context for a failure, e.g. who owns a contested port
    /// and which port to try instead. Keys are stable; values are strings.
    public var errorDetails: [String: String]?
    public var site: Site?
    public var sites: [Site]?
    public var status: DaemonStatus?
    public var config: BeaconConfig?
    public var run: RunStatus?
    public var relay: RelayStatus?
    public var relayTokens: [RelayToken]?
    /// A token just created on the relay. Its only appearance anywhere.
    public var invite: RelayInvite?

    public init(
        ok: Bool = true, errorCode: String? = nil, error: String? = nil,
        errorDetails: [String: String]? = nil,
        site: Site? = nil, sites: [Site]? = nil,
        status: DaemonStatus? = nil, config: BeaconConfig? = nil,
        run: RunStatus? = nil, relay: RelayStatus? = nil,
        relayTokens: [RelayToken]? = nil, invite: RelayInvite? = nil
    ) {
        self.ok = ok
        self.errorCode = errorCode
        self.error = error
        self.errorDetails = errorDetails
        self.site = site
        self.sites = sites
        self.status = status
        self.config = config
        self.run = run
        self.relay = relay
        self.relayTokens = relayTokens
        self.invite = invite
    }

    public static func failure(
        _ code: String, _ message: String, details: [String: String]? = nil
    ) -> BeaconResponse {
        BeaconResponse(ok: false, errorCode: code, error: message, errorDetails: details)
    }
}

public struct BeaconClientError: LocalizedError, Sendable {
    public let code: String
    public let message: String
    public let details: [String: String]?
    public init(code: String, message: String, details: [String: String]? = nil) {
        self.code = code
        self.message = message
        self.details = details
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
