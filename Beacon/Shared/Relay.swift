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

// MARK: - Managing the relay's tokens

/// A token the relay accepts, as its admin API lists it. Matches
/// `RelayAdminToken` in Sources/beacon-relay/RelayAdmin.swift field for field;
/// the daemon decodes the relay's JSON straight into this.
public struct RelayToken: Codable, Sendable, Hashable, Identifiable {
    public enum Source: String, Codable, Sendable {
        /// Set in the relay's BEACON_TOKENS. Only changed by redeploying it.
        case environment
        /// Created by an admin, and revocable from here.
        case relay
    }

    public var label: String
    public var note: String?
    public var admin: Bool
    public var source: Source
    public var createdAt: Date?
    public var createdBy: String?
    public var connected: Bool
    /// Public URLs it's serving right now.
    public var shares: [String]

    public var id: String { label }
}

/// What an admin asks the relay for.
public struct RelayTokenSpec: Codable, Sendable {
    public var label: String
    /// Who it's for, e.g. "Sam's MacBook".
    public var note: String?
    public var admin: Bool?

    public init(label: String, note: String? = nil, admin: Bool? = nil) {
        self.label = label
        self.note = note
        self.admin = admin
    }
}

/// The contents of a `.beacon` file: everything a new Mac needs to use a
/// relay. Opening one fills in Settings → Sharing.
public struct RelayInvite: Codable, Sendable, Hashable {
    public static let fileExtension = "beacon"
    public static let typeIdentifier = "com.globusgroup.beacon.invite"

    public var version: Int
    /// The relay's address, as the admin's own Mac reaches it.
    public var relay: String
    public var token: String
    public var label: String
    public var note: String?

    public init(relay: String, token: String, label: String, note: String? = nil) {
        self.version = 1
        self.relay = relay
        self.token = token
        self.label = label
        self.note = note
    }

    public func encoded() throws -> Data {
        try BeaconJSON.prettyEncoder.encode(self)
    }

    public static func read(from url: URL) throws -> RelayInvite {
        let data = try Data(contentsOf: url)
        guard let invite = try? BeaconJSON.decoder.decode(RelayInvite.self, from: data),
              !invite.relay.isEmpty, !invite.token.isEmpty
        else {
            throw BeaconClientError(code: "bad_invite", message: "\(url.lastPathComponent) isn't a Beacon relay file.")
        }
        return invite
    }
}
