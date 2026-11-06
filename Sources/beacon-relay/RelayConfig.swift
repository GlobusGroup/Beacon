import BeaconTunnel
import Foundation

/// Everything the relay is told through its environment, usually a `.env`
/// file read by Docker Compose.
struct RelayConfig {
    /// The apex the relay owns, e.g. `relay.example.com`. Shares live one level below it.
    var domain: String
    /// Port the relay listens on for plain HTTP from Traefik.
    var port: Int
    /// What browsers see. Traefik terminates TLS, so this is `https` in production.
    var publicScheme: String
    var publicPort: Int
    /// Take the client address from `X-Forwarded-For`. Only safe when the relay
    /// is reachable through the proxy alone, as it is on a Docker network.
    var trustForwardedFor: Bool
    /// Token → label. The label names whoever holds the token and namespaces
    /// their hostnames: `shop` shared with label `dean` is `shop-dean.<domain>`.
    var tokens: [(token: String, label: String)]
    /// Labels from `tokens` that may create and revoke tokens through the
    /// relay's admin API.
    var admins: Set<String>
    /// Where tokens created through the admin API are kept. A volume in Docker.
    var dataDir: String
    var verbose: Bool
    /// What the apex shows a browser: the Beacon website, or the small card.
    var home: Home
    /// Where the website's files are. The image ships them in /srv/site.
    var siteDir: String

    enum Home: String {
        /// The Beacon landing page from `site/`, falling back to the card if
        /// the files aren't there.
        case site
        /// The one-card page that says what the server is.
        case card
    }

    enum Problem: Error, CustomStringConvertible {
        case missing(String)
        case invalid(String)

        var description: String {
            switch self {
            case .missing(let message), .invalid(let message): return message
            }
        }
    }

    static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) throws -> RelayConfig {
        guard let rawDomain = env["BEACON_DOMAIN"], !rawDomain.isEmpty else {
            throw Problem.missing("BEACON_DOMAIN isn't set. It should be the apex the relay owns, e.g. relay.example.com.")
        }
        let domain = rawDomain.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased()

        let scheme = (env["BEACON_PUBLIC_SCHEME"] ?? "https").lowercased()
        guard scheme == "https" || scheme == "http" else {
            throw Problem.invalid("BEACON_PUBLIC_SCHEME should be https or http, not '\(scheme)'.")
        }

        let rawHome = (env["BEACON_HOME"] ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        guard let home = rawHome.isEmpty ? .site : Home(rawValue: rawHome) else {
            throw Problem.invalid("BEACON_HOME should be site or card, not '\(rawHome)'.")
        }

        let tokens = try parseTokens(env["BEACON_TOKENS"] ?? "")
        let admins = try parseAdmins(env["BEACON_ADMINS"] ?? "", tokens: tokens)

        return RelayConfig(
            domain: domain,
            port: Int(env["PORT"] ?? "") ?? 8080,
            publicScheme: scheme,
            publicPort: Int(env["BEACON_PUBLIC_PORT"] ?? "") ?? (scheme == "https" ? 443 : 80),
            trustForwardedFor: (env["BEACON_TRUST_FORWARDED_FOR"] ?? "true").lowercased() != "false",
            tokens: tokens,
            admins: admins,
            dataDir: (env["BEACON_DATA_DIR"] ?? "").isEmpty ? "/data" : env["BEACON_DATA_DIR"]!,
            verbose: (env["BEACON_VERBOSE"] ?? "").lowercased() == "true",
            home: home,
            siteDir: (env["BEACON_SITE_DIR"] ?? "").isEmpty ? "/srv/site" : env["BEACON_SITE_DIR"]!
        )
    }

    /// `BEACON_TOKENS=dean:tok_abc,sam:tok_def`. Whitespace and newlines also
    /// separate entries, so a long list can be wrapped.
    static func parseTokens(_ raw: String) throws -> [(token: String, label: String)] {
        let entries = raw.split { $0 == "," || $0.isWhitespace }
        var out: [(token: String, label: String)] = []
        var labels = Set<String>()

        for entry in entries {
            let parts = entry.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, !parts[1].isEmpty else {
                throw Problem.invalid("BEACON_TOKENS entries look like label:token. '\(entry.prefix(12))…' doesn't.")
            }
            let label = parts[0].lowercased()
            guard Hostnames.isLabel(label) else {
                throw Problem.invalid("Token label '\(label)' must be lowercase letters, digits and single hyphens.")
            }
            guard parts[1].count >= 16 else {
                throw Problem.invalid("The token for '\(label)' is shorter than 16 characters. Use something like `openssl rand -hex 24`.")
            }
            guard labels.insert(label).inserted else {
                throw Problem.invalid("Token label '\(label)' is used twice.")
            }
            out.append((token: parts[1], label: label))
        }

        guard !out.isEmpty else {
            throw Problem.missing("BEACON_TOKENS is empty, so nobody could connect. Add label:token pairs.")
        }
        return out
    }

    /// `BEACON_ADMINS=dean,sam`: labels from `BEACON_TOKENS`, comma or
    /// whitespace separated. Naming the label rather than repeating the token
    /// keeps each secret in one place.
    static func parseAdmins(_ raw: String, tokens: [(token: String, label: String)]) throws -> Set<String> {
        let known = Set(tokens.map(\.label))
        var admins = Set<String>()
        for entry in raw.split(whereSeparator: { $0 == "," || $0.isWhitespace }) {
            let label = entry.lowercased()
            guard known.contains(label) else {
                throw Problem.invalid("BEACON_ADMINS names '\(label)', which isn't a label in BEACON_TOKENS.")
            }
            admins.insert(label)
        }
        return admins
    }
}

enum Hostnames {
    /// A DNS label: 1–63 lowercase letters, digits and hyphens, not starting
    /// or ending with a hyphen.
    static func isLabel(_ value: String) -> Bool {
        guard (1...63).contains(value.count),
              value.first != "-", value.last != "-"
        else { return false }
        return value.allSatisfy { ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") || $0 == "-" }
    }

    /// `Host` without the port, lowercased.
    static func normalise(_ host: String) -> String {
        var host = host.lowercased()
        if host.hasPrefix("[") {
            // [::1]:8080
            if let end = host.firstIndex(of: "]") { host = String(host[...end]) }
        } else if let colon = host.lastIndex(of: ":") {
            host = String(host[..<colon])
        }
        return host.hasSuffix(".") ? String(host.dropLast()) : host
    }
}
