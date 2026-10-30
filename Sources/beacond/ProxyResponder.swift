import BeaconKit
import Foundation
import NIOCore

/// Beacon's own error pages.
///
/// These are the pages a developer sees when something is wrong with their
/// setup, so they say what happened and what to type next rather than just
/// showing a status code.
enum ProxyResponder {
    static func send(on channel: Channel, status: String, title: String, detail: String, hint: String? = nil) {
        let body = page(status: status, title: title, detail: detail, hint: hint)
        let bytes = Array(body.utf8)
        let head = """
        HTTP/1.1 \(status)\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(bytes.count)\r
        Cache-Control: no-store\r
        Connection: close\r
        \r

        """

        var buffer = channel.allocator.buffer(capacity: head.utf8.count + bytes.count)
        buffer.writeString(head)
        buffer.writeBytes(bytes)
        channel.writeAndFlush(buffer).whenComplete { _ in
            channel.close(promise: nil)
        }
    }

    static func sendUnknownHost(on channel: Channel, host: String, known: [Site], scheme: String) {
        let shown = host.isEmpty ? "(no Host header)" : host
        let hint: String
        if known.isEmpty {
            hint = "No projects are registered yet. Run <code>beacon register &lt;name&gt;</code> to claim a domain and a port."
        } else {
            let items = known
                .map { "<li><a href=\"\($0.url)\">\($0.domain)</a> <span class=\"port\">→ localhost:\($0.port)</span></li>" }
                .joined()
            hint = "<p>Beacon currently routes:</p><ul class=\"sites\">\(items)</ul>"
        }

        send(
            on: channel,
            status: "404 Not Found",
            title: "Beacon doesn't know <code>\(escape(shown))</code>",
            detail: "Nothing is registered for that domain.",
            hint: hint
        )
    }

    static func sendUpstreamDown(on channel: Channel, site: Site) {
        let startHint = site.path.map { "<p class=\"path\">\(escape($0))</p>" } ?? ""
        send(
            on: channel,
            status: "502 Bad Gateway",
            title: "<code>\(escape(site.name))</code> isn't running",
            detail: "Beacon holds port <strong>\(site.port)</strong> for this project, but nothing is listening on it.",
            hint: """
            <p>Start the project's dev server on port \(site.port) and reload.</p>\(startHint)
            <p class="muted">The port is reserved — it won't be handed to another project while this one is down.</p>
            """
        )
    }

    private static func page(status: String, title: String, detail: String, hint: String?) -> String {
        """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Beacon — \(escape(status))</title>
        <style>
          :root {
            color-scheme: light dark;
            --bg: #fbfbfd; --fg: #1d1d1f; --muted: #6e6e73;
            --card: #ffffff; --line: #e3e3e6; --accent: #e8833a;
          }
          @media (prefers-color-scheme: dark) {
            :root { --bg: #161618; --fg: #f2f2f4; --muted: #9a9aa0;
                    --card: #1f1f22; --line: #2e2e33; }
          }
          * { box-sizing: border-box; }
          body { margin: 0; min-height: 100vh; display: grid; place-items: center;
                 padding: 24px; background: var(--bg); color: var(--fg);
                 font: 15px/1.6 ui-sans-serif, -apple-system, system-ui, sans-serif; }
          main { width: 100%; max-width: 560px; background: var(--card);
                 border: 1px solid var(--line); border-radius: 14px; padding: 28px 30px; }
          .mark { display: inline-flex; align-items: center; gap: 8px;
                  font-size: 12px; letter-spacing: .08em; text-transform: uppercase;
                  color: var(--muted); margin-bottom: 18px; }
          .dot { width: 9px; height: 9px; border-radius: 50%; background: var(--accent); }
          h1 { font-size: 20px; line-height: 1.35; margin: 0 0 10px; font-weight: 600; }
          p { margin: 0 0 12px; }
          .muted { color: var(--muted); font-size: 13.5px; }
          .path { color: var(--muted); font-size: 13px; word-break: break-all; }
          code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: .92em;
                 background: color-mix(in srgb, var(--fg) 8%, transparent);
                 padding: 2px 6px; border-radius: 5px; }
          ul.sites { list-style: none; padding: 0; margin: 12px 0 0;
                     border-top: 1px solid var(--line); }
          ul.sites li { display: flex; justify-content: space-between; gap: 12px;
                        padding: 9px 0; border-bottom: 1px solid var(--line); }
          ul.sites a { color: inherit; text-decoration: none; font-weight: 500; }
          ul.sites a:hover { text-decoration: underline; }
          .port { color: var(--muted); font-family: ui-monospace, Menlo, monospace; font-size: 13px; }
          footer { margin-top: 22px; color: var(--muted); font-size: 12.5px; }
        </style>
        </head>
        <body>
        <main>
          <div class="mark"><span class="dot"></span> Beacon</div>
          <h1>\(title)</h1>
          <p>\(detail)</p>
          \(hint ?? "")
          <footer>\(escape(status)) · <code>beacon list</code> shows every registered project</footer>
        </main>
        </body>
        </html>
        """
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
