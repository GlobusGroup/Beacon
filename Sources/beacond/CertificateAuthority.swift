import BeaconKit
import Crypto
import Foundation
import SwiftASN1
import X509

/// Beacon's own certificate authority.
///
/// The root is generated once and trusted in the System keychain. From then on
/// a single leaf certificate covers every registered domain, reissued whenever
/// the site list changes. One leaf rather than per-site certificates keeps the
/// TLS path dead simple: no SNI dispatch, one context, swapped atomically.
struct CertificateAuthority {
    /// Apple rejects TLS server certificates valid for more than 398 days,
    /// including ones chaining to a locally trusted root.
    static let leafLifetime: TimeInterval = 380 * 24 * 60 * 60
    static let rootLifetime: TimeInterval = 10 * 365 * 24 * 60 * 60
    /// Reissue before the leaf gets close enough to expiry to bite.
    static let renewalWindow: TimeInterval = 30 * 24 * 60 * 60

    struct Material {
        var certificateChainPEM: String
        var privateKeyPEM: String
    }

    private static let manifestPath = BeaconPaths.certsDir + "/leaf-domains.json"

    // MARK: - Root

    /// Loads the root, creating it the first time. The private key is written
    /// 0600 and never leaves `/Library/Application Support/Beacon/certs`.
    static func loadOrCreateRoot() throws -> (certificate: Certificate, key: Certificate.PrivateKey) {
        try FileManager.default.createDirectory(
            atPath: BeaconPaths.certsDir, withIntermediateDirectories: true
        )

        if let certPEM = try? String(contentsOfFile: BeaconPaths.caCertFile, encoding: .utf8),
           let keyPEM = try? String(contentsOfFile: BeaconPaths.caKeyFile, encoding: .utf8),
           let certificate = try? Certificate(pemEncoded: certPEM),
           let key = try? P256.Signing.PrivateKey(pemRepresentation: keyPEM) {
            return (certificate, Certificate.PrivateKey(key))
        }

        Log.info("Generating Beacon's root certificate authority.")

        let p256 = P256.Signing.PrivateKey()
        let key = Certificate.PrivateKey(p256)
        let name = try DistinguishedName {
            CommonName(BeaconInstaller.caCommonName)
            OrganizationName("Beacon")
        }

        let now = Date()
        let certificate = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: key.publicKey,
            notValidBefore: now.addingTimeInterval(-3600),
            notValidAfter: now.addingTimeInterval(rootLifetime),
            issuer: name,
            subject: name,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 1))
                Critical(KeyUsage(keyCertSign: true, cRLSign: true))
                SubjectKeyIdentifier(hash: key.publicKey)
            },
            issuerPrivateKey: key
        )

        try write(
            try certificate.serializeAsPEM().pemString,
            to: BeaconPaths.caCertFile,
            permissions: 0o644
        )
        try write(p256.pemRepresentation, to: BeaconPaths.caKeyFile, permissions: 0o600)

        return (certificate, key)
    }

    // MARK: - Leaf

    /// Returns TLS material covering `domains`, reusing what is on disk when it
    /// already covers them and isn't near expiry.
    static func material(for domains: [String]) throws -> Material {
        let wanted = normalise(domains)

        if let existing = try? loadLeaf(), covers(wanted, manifest: existing.domains),
           existing.expiry.timeIntervalSinceNow > renewalWindow {
            return existing.material
        }

        return try issueLeaf(for: wanted)
    }

    private static func issueLeaf(for domains: [String]) throws -> Material {
        let (rootCertificate, rootKey) = try loadOrCreateRoot()

        let p256 = P256.Signing.PrivateKey()
        let key = Certificate.PrivateKey(p256)
        let subject = try DistinguishedName {
            CommonName("Beacon Local Sites")
            OrganizationName("Beacon")
        }

        var names: [GeneralName] = domains.map { .dnsName($0) }
        names.append(.ipAddress(ASN1OctetString(contentBytes: [127, 0, 0, 1])))

        let now = Date()
        let leaf = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: key.publicKey,
            notValidBefore: now.addingTimeInterval(-3600),
            notValidAfter: now.addingTimeInterval(leafLifetime),
            issuer: rootCertificate.subject,
            subject: subject,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                Critical(KeyUsage(digitalSignature: true, keyEncipherment: true))
                try ExtendedKeyUsage([.serverAuth])
                SubjectAlternativeNames(names)
                SubjectKeyIdentifier(hash: key.publicKey)
            },
            issuerPrivateKey: rootKey
        )

        let chain = try leaf.serializeAsPEM().pemString + "\n"
            + rootCertificate.serializeAsPEM().pemString + "\n"

        try write(chain, to: BeaconPaths.leafCertFile, permissions: 0o644)
        try write(p256.pemRepresentation, to: BeaconPaths.leafKeyFile, permissions: 0o600)
        try write(
            String(decoding: try BeaconJSON.prettyEncoder.encode(domains), as: UTF8.self),
            to: manifestPath,
            permissions: 0o644
        )

        Log.info("Issued TLS certificate for \(domains.count) name(s).")
        return Material(certificateChainPEM: chain, privateKeyPEM: p256.pemRepresentation)
    }

    private struct StoredLeaf {
        var material: Material
        var domains: [String]
        var expiry: Date
    }

    private static func loadLeaf() throws -> StoredLeaf {
        let chain = try String(contentsOfFile: BeaconPaths.leafCertFile, encoding: .utf8)
        let key = try String(contentsOfFile: BeaconPaths.leafKeyFile, encoding: .utf8)
        let manifestData = try Data(contentsOf: URL(fileURLWithPath: manifestPath))
        let domains = try BeaconJSON.decoder.decode([String].self, from: manifestData)

        // The chain's first certificate is the leaf.
        guard let firstEnd = chain.range(of: "-----END CERTIFICATE-----") else {
            throw BeaconClientError(code: "bad_cert", message: "Stored certificate chain is malformed.")
        }
        let leafPEM = String(chain[chain.startIndex..<firstEnd.upperBound])
        let leaf = try Certificate(pemEncoded: leafPEM)

        return StoredLeaf(
            material: Material(certificateChainPEM: chain, privateKeyPEM: key),
            domains: domains,
            expiry: leaf.notValidAfter
        )
    }

    private static func covers(_ wanted: [String], manifest: [String]) -> Bool {
        Set(wanted).isSubset(of: Set(manifest))
    }

    /// Adds the wildcard for each domain so `api.myproject.test` works without
    /// a separate registration, and always includes localhost.
    private static func normalise(_ domains: [String]) -> [String] {
        var out = Set<String>(["localhost"])
        for domain in domains {
            let lower = domain.lowercased()
            out.insert(lower)
            out.insert("*." + lower)
        }
        return out.sorted()
    }

    private static func write(_ contents: String, to path: String, permissions: Int16) throws {
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: permissions)], ofItemAtPath: path
        )
    }
}
