import Foundation

/// Sharing a project on the public internet through a Beacon relay, e.g.
/// `https://shop-dean.relay.example.com`. The daemon keeps one tunnel open to the
/// relay while anything is shared.

/// A request to share one project.
public struct ShareSpec: Codable, Sendable {
    public var name: String
    /// Visitors must give this password (any username). Nil or empty: public.
    public var password: String?

    public init(name: String, password: String? = nil) {
        self.name = name
        self.password = password
    }
}

/// Where the relay is and the token to present. Fields left nil are kept as
/// they are; an empty `url` turns sharing off.
public struct RelaySpec: Codable, Sendable {
    public var url: String?
    public var token: String?

    public init(url: String? = nil, token: String? = nil) {
        self.url = url
        self.token = token
    }
}

public struct RelayStatus: Codable, Sendable, Hashable {
    public enum State: String, Codable, Sendable {
        /// No relay configured.
        case off
        /// Configured, but nothing is shared, so no tunnel is open.
        case idle
        case connecting
        case connected
        /// The last attempt failed; `error` says why. Retried automatically.
        case failed
    }

    public var url: String?
    public var hasToken: Bool
    public var state: State
    /// The token's label on the relay, which every public hostname ends in.
    public var label: String?
    public var error: String?
    public var shares: [SharedProject]

    public init(
        url: String?, hasToken: Bool, state: State, label: String? = nil,
        error: String? = nil, shares: [SharedProject] = []
    ) {
        self.url = url
        self.hasToken = hasToken
        self.state = state
        self.label = label
        self.error = error
        self.shares = shares
    }

    public func share(named name: String) -> SharedProject? {
        shares.first { $0.name == name }
    }
}

public struct SharedProject: Codable, Sendable, Hashable {
    public var name: String
    /// Set once the relay has confirmed the hostname.
    public var publicURL: String?
    public var passwordProtected: Bool
    public var error: String?

    public init(name: String, publicURL: String? = nil, passwordProtected: Bool, error: String? = nil) {
        self.name = name
        self.publicURL = publicURL
        self.passwordProtected = passwordProtected
        self.error = error
    }
}
