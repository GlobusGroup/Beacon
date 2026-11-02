import Foundation

/// Complete HTTP responses for the requests the relay answers itself.
/// Every one closes the connection; see `RelayFrontendHandler`.
enum RelayPages {
    static func home(domain: String) -> String {
        html("200 OK", title: "Beacon relay", detail: """
        This server hands out public URLs under <code>\(escape(domain))</code> for projects \
        running on Macs with Beacon. Share one with <code>beacon share</code>.
        """)
    }

    static func notShared(host: String) -> String {
        html("404 Not Found", title: "Nothing is shared here", detail: """
        <code>\(escape(host))</code> isn't shared right now. The Mac sharing it may be \
        asleep or offline, or the project was unshared.
        """)
    }

    static func unauthorised(host: String) -> String {
        html("401 Unauthorized", title: "Password required", detail: """
        <code>\(escape(host))</code> is shared with a password. Ask whoever sent you the link for it.
        """, extraHeaders: ["WWW-Authenticate: Basic realm=\"\(host.replacingOccurrences(of: "\"", with: ""))\", charset=\"UTF-8\""])
    }

    static func rejectedToken() -> String {
        plain("401 Unauthorized", "That token isn't one this relay accepts.\n")
    }

    static func badRequest(_ reason: String) -> String {
        plain("400 Bad Request", reason + "\n")
    }

    static func health(sessions: Int, routes: Int) -> String {
        response("200 OK", contentType: "application/json", body: #"{"ok":true,"tunnels":\#(sessions),"shares":\#(routes)}"#)
    }

    // MARK: -

    private static func plain(_ status: String, _ body: String) -> String {
        response(status, contentType: "text/plain; charset=utf-8", body: body)
    }

    private static func html(_ status: String, title: String, detail: String, extraHeaders: [String] = []) -> String {
        let body = """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(title))</title>
        <style>
          :root { color-scheme: light dark; --canvas: #F5F3EE; --surface: #FFFFFF; --line: #E4E1DA;
                  --text: #181C20; --secondary: #5B636C; --tint: #F1EEE7; --signal: #F5B544; }
          @media (prefers-color-scheme: dark) {
            :root { --canvas: #181C20; --surface: #22262B; --line: #30353B; --text: #F5F3EE;
                    --secondary: #9AA2AB; --tint: #1C2024; }
          }
          * { box-sizing: border-box; }
          body { margin: 0; min-height: 100vh; display: grid; place-items: center; padding: 32px 16px;
                 background: var(--canvas); color: var(--text);
                 font: 15px/1.5 -apple-system, BlinkMacSystemFont, system-ui, sans-serif; }
          .page { width: 100%; max-width: 480px; }
          .brand { margin: 0 0 24px 4px; font-weight: 700; letter-spacing: -.01em; display: flex; align-items: center; gap: 8px; }
          .brand i { width: 10px; height: 10px; border-radius: 50%; background: var(--signal); }
          main { background: var(--surface); border: 1px solid var(--line); border-radius: 12px; padding: 24px; }
          h1 { font-size: 24px; line-height: 1.25; font-weight: 600; margin: 0 0 8px; }
          p { margin: 0; color: var(--secondary); }
          code { font: 13px ui-monospace, "SF Mono", Menlo, monospace; background: var(--tint);
                 border: 1px solid var(--line); padding: 1px 6px; border-radius: 5px; color: var(--text);
                 overflow-wrap: anywhere; }
          footer { margin: 16px 4px 0; color: var(--secondary); font: 12px ui-monospace, Menlo, monospace; }
        </style>
        </head>
        <body>
        <div class="page">
          <div class="brand"><i></i>Beacon</div>
          <main><h1>\(escape(title))</h1><p>\(detail)</p></main>
          <footer>\(escape(status))</footer>
        </div>
        </body>
        </html>
        """
        return response(status, contentType: "text/html; charset=utf-8", body: body, extraHeaders: extraHeaders)
    }

    private static func response(_ status: String, contentType: String, body: String, extraHeaders: [String] = []) -> String {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.utf8.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n"
        for header in extraHeaders { head += header + "\r\n" }
        return head + "\r\n" + body
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
