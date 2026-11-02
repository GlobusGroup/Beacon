import BeaconKit
import BeaconTunnel
import Foundation
import NIOCore

/// Beacon's own URLs under every project domain, used by the "isn't running"
/// page to start the project and follow its progress.
///
/// They live on the project's own origin so the page can call them with a
/// plain same-origin `fetch`, over whichever scheme it was loaded with.
enum BeaconEndpoint {
    static let prefix = "/__beacon/"

    static func handle(_ head: HTTPHead, site: Site, runner: ProjectRunner, on channel: Channel) {
        let path = head.target.split(separator: "?").first.map(String.init) ?? head.target

        switch (head.method, path) {
        case ("GET", prefix + "status"):
            ProxyResponder.sendJSON(on: channel, status: "200 OK", runner.status(for: site))

        case ("POST", prefix + "start"):
            // A custom header can't be sent cross-origin without a CORS
            // preflight, which Beacon never approves. That stops any other
            // page in the browser from starting projects behind your back.
            guard head.value(of: "X-Beacon-Action") == "start",
                  (head.value(of: "Sec-Fetch-Site") ?? "same-origin") == "same-origin"
            else {
                ProxyResponder.sendJSON(
                    on: channel, status: "403 Forbidden",
                    BeaconResponse.failure("forbidden", "Projects can only be started from Beacon's own page.")
                )
                return
            }
            do {
                ProxyResponder.sendJSON(on: channel, status: "202 Accepted", try runner.start(site))
            } catch let error as BeaconClientError {
                ProxyResponder.sendJSON(
                    on: channel, status: "409 Conflict", BeaconResponse.failure(error.code, error.message)
                )
            } catch {
                ProxyResponder.sendJSON(
                    on: channel, status: "500 Internal Server Error",
                    BeaconResponse.failure("internal_error", error.localizedDescription)
                )
            }

        default:
            ProxyResponder.sendJSON(
                on: channel, status: "404 Not Found",
                BeaconResponse.failure("not_found", "Beacon has nothing at \(path).")
            )
        }
    }
}
