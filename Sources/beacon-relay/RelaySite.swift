import Crypto
import Foundation

/// The Beacon website, served on the relay's apex in place of the small card.
///
/// Read into memory once at startup: it is a handful of small files, and the
/// relay never has to touch the disk per request. Only files directly under
/// the site directory or one folder down, with extensions a browser needs,
/// are ever served, so nothing else in the image is reachable.
final class RelaySite {
    private struct File {
        let contentType: String
        let body: [UInt8]
        let cacheControl: String
        let etag: String
    }

    private static let types: [String: String] = [
        "html": "text/html; charset=utf-8",
        "css": "text/css; charset=utf-8",
        "js": "text/javascript; charset=utf-8",
        "svg": "image/svg+xml",
        "webp": "image/webp",
        "png": "image/png",
        "ico": "image/x-icon",
    ]

    private let files: [String: File]
    let directory: String

    var fileCount: Int { files.count }

    /// Throws when the directory has no index.html.
    init(directory: String) throws {
        self.directory = directory
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        let manager = FileManager.default
        var files: [String: File] = [:]

        func build(_ data: Data, ext: String) -> File? {
            guard let type = Self.types[ext] else { return nil }
            // Pages revalidate (cheaply, by ETag) so a redeploy shows at once.
            // Everything else is linked from them with ?v=<hash>, so it can be
            // cached hard, including by a CDN such as Cloudflare in front of
            // the relay: a changed file gets a new URL.
            let cache = ext == "html" ? "no-cache" : "public, max-age=86400"
            return File(contentType: type, body: Array(data), cacheControl: cache, etag: "\"\(Self.digest(data))\"")
        }

        var html: [String: Data] = [:]
        let top = (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for url in top {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let entries = isDirectory
                ? ((try? manager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []).map {
                    ($0, "/\(url.lastPathComponent)/\($0.lastPathComponent)")
                }
                : [(url, "/\(url.lastPathComponent)")]
            for (file, path) in entries {
                let ext = file.pathExtension.lowercased()
                guard let data = manager.contents(atPath: file.path) else { continue }
                if ext == "html" { html[path] = data } else if let built = build(data, ext: ext) { files[path] = built }
            }
        }

        // Point every page's links at the current version of each file.
        for (path, data) in html {
            var text = String(decoding: data, as: UTF8.self)
            for (asset, built) in files {
                let name = String(asset.dropFirst())
                let version = built.etag.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                for quote in ["\"", "'"] {
                    text = text.replacingOccurrences(of: "=\(quote)\(name)\(quote)", with: "=\(quote)\(name)?v=\(version)\(quote)")
                }
            }
            files[path] = build(Data(text.utf8), ext: "html")
        }

        guard files["/index.html"] != nil else {
            throw RelayConfig.Problem.invalid("BEACON_SITE_DIR (\(directory)) has no index.html.")
        }
        self.files = files
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// A complete response for `GET` or `HEAD`, or nil when the site has no
    /// such file, so the caller can answer as it would without a site.
    func response(method: String, path: String, ifNoneMatch: String?) -> [UInt8]? {
        guard method == "GET" || method == "HEAD" else { return nil }
        let decoded = path.removingPercentEncoding ?? path
        let key = decoded == "/" ? "/index.html" : decoded
        guard let file = files[key] else { return nil }

        if let ifNoneMatch, ifNoneMatch.split(separator: ",").contains(where: {
            $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "W/", with: "") == file.etag
        }) {
            let head = "HTTP/1.1 304 Not Modified\r\nETag: \(file.etag)\r\nCache-Control: \(file.cacheControl)\r\nConnection: close\r\n\r\n"
            return Array(head.utf8)
        }

        var head = "HTTP/1.1 200 OK\r\n"
        head += "Content-Type: \(file.contentType)\r\n"
        head += "Content-Length: \(file.body.count)\r\n"
        head += "Cache-Control: \(file.cacheControl)\r\n"
        head += "ETag: \(file.etag)\r\n"
        head += "X-Content-Type-Options: nosniff\r\n"
        head += "Referrer-Policy: strict-origin-when-cross-origin\r\n"
        head += "Connection: close\r\n\r\n"
        return Array(head.utf8) + (method == "HEAD" ? [] : file.body)
    }
}
