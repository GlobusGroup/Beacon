import BeaconKit
import Foundation
import NIOCore

/// Beacon's own error pages.
///
/// These are the pages a developer sees when something is wrong with their
/// setup, so they say what happened and what to type next rather than just
/// showing a status code.
enum ProxyResponder {
    static func send(
        on channel: Channel, status: String, title: String, detail: String,
        chip: (label: String, tone: String)? = nil, name: String? = nil,
        hint: String? = nil, script: String? = nil
    ) {
        let body = page(
            status: status, title: title, detail: detail, hint: hint, chip: chip, name: name, script: script
        )
        write(on: channel, status: status, contentType: "text/html; charset=utf-8", body: Array(body.utf8))
    }

    static func sendJSON<T: Encodable>(on channel: Channel, status: String, _ value: T) {
        let body = (try? BeaconJSON.encoder.encode(value)).map(Array.init) ?? Array("{}".utf8)
        write(on: channel, status: status, contentType: "application/json", body: body)
    }

    /// A whole error page as raw HTTP, for writing somewhere other than a
    /// browser connection — down a tunnel stream, say.
    static func response(status: String, title: String, detail: String, hint: String? = nil) -> [UInt8] {
        let body = page(status: status, title: title, detail: detail, hint: hint, script: nil)
        return httpResponse(status: status, contentType: "text/html; charset=utf-8", body: Array(body.utf8))
    }

    static func write(on channel: Channel, status: String, contentType: String, body bytes: [UInt8]) {
        let response = httpResponse(status: status, contentType: contentType, body: bytes)
        var buffer = channel.allocator.buffer(capacity: response.count)
        buffer.writeBytes(response)
        channel.writeAndFlush(buffer).whenComplete { _ in
            channel.close(promise: nil)
        }
    }

    private static func httpResponse(status: String, contentType: String, body bytes: [UInt8]) -> [UInt8] {
        let head = """
        HTTP/1.1 \(status)\r
        Content-Type: \(contentType)\r
        Content-Length: \(bytes.count)\r
        Cache-Control: no-store\r
        Connection: close\r
        \r

        """
        return Array(head.utf8) + bytes
    }

    static func sendUnknownHost(on channel: Channel, host: String, known: [Site], scheme: String) {
        let shown = host.isEmpty ? "(no Host header)" : host
        let hint: String
        if known.isEmpty {
            hint = "No projects are registered yet. Run <code>beacon register &lt;name&gt;</code> to claim a domain and a port."
        } else {
            let items = known
                .map {
                    "<li><a href=\"\(escape($0.url))\"><span class=\"domain\">\(escape($0.domain))</span>"
                        + "<span class=\"port\">localhost:\($0.port)</span></a></li>"
                }
                .joined()
            hint = "<ul class=\"sites\">\(items)</ul>"
        }

        send(
            on: channel,
            status: "404 Not Found",
            title: "No project at \(escape(shown))",
            detail: known.isEmpty ? "Nothing is registered for that domain." : "Beacon routes these projects:",
            hint: hint
        )
    }

    /// The page for a project whose dev server isn't up. When Beacon knows
    /// how to start the project it offers to, then follows the start through
    /// `/__beacon/status` and reloads once the port answers.
    static func sendUpstreamDown(on channel: Channel, site: Site, run: RunStatus) {
        sendLaunchPage(
            on: channel, site: site, run: run, action: "start",
            title: "\(escape(site.name)) isn't running",
            chip: (label: "Offline", tone: "offline"),
            detail: "Nothing is listening on port <code>\(site.port)</code>"
        )
    }

    /// The page for a dev server that accepted the connection and closed it
    /// without replying: still running, but broken. Offers a restart.
    static func sendNotResponding(on channel: Channel, site: Site, run: RunStatus) {
        sendLaunchPage(
            on: channel, site: site, run: run, action: "restart",
            title: "\(escape(site.name)) isn't responding",
            chip: (label: "Not responding", tone: "failed"),
            detail: "Something is listening on port <code>\(site.port)</code>, but it closed the connection without a reply"
        )
    }

    private static func sendLaunchPage(
        on channel: Channel, site: Site, run: RunStatus, action: String,
        title: String, chip: (label: String, tone: String), detail: String
    ) {
        guard let command = run.command else {
            let lead = action == "restart"
                ? "Restart its dev server. To let Beacon do it from here:"
                : "To start it from here:"
            send(
                on: channel, status: "502 Bad Gateway", title: title, detail: detail, chip: chip,
                hint: """
                <p class="muted">\(lead) \
                <code>beacon register \(escape(site.name)) --run "&lt;command&gt;"</code></p>
                """
            )
            return
        }
        let verb = action == "restart" ? "Restart" : "Start"

        let initial = (try? BeaconJSON.encoder.encode(run))
            .map { String(decoding: $0, as: UTF8.self) } ?? "null"

        // The command sits in the button's tooltip: there if you want to
        // know what will run, out of the way if you don't.
        send(
            on: channel, status: "502 Bad Gateway", title: title, detail: detail, chip: chip, name: site.name,
            hint: """
            <section id="launch">
              <button id="start" type="button" title="Runs: \(escape(command))">\(verb) \(escape(site.name))</button>
            </section>
            <section id="progress" hidden>
              <div class="status"><span class="spinner" aria-hidden="true"></span><span id="phase">Starting…</span><span id="elapsed" class="muted"></span></div>
              <div class="bar" role="progressbar" aria-valuemin="0" aria-valuemax="100"><div id="fill"></div></div>
              <p id="latest" class="latest"></p>
              <p id="error" class="error" hidden></p>
              <details id="output">
                <summary>Output</summary>
                <pre id="log"></pre>
              </details>
              <button id="retry" type="button" hidden>Try again</button>
            </section>
            """,
            script: startScript(initial: initial, action: action)
        )
    }

    /// Kept free of Swift interpolation apart from the initial status, so the
    /// JavaScript reads as JavaScript.
    private static func startScript(initial: String, action: String) -> String {
        let safeInitial = initial.replacingOccurrences(of: "</", with: "<\\/")
        return """
        const initial = \(safeInitial);
        const action = "\(action)";
        """ + #"""
        const $ = (id) => document.getElementById(id);
        let polling = false;
        let clockStart = 0, expected = 10;

        function show(status) {
          if (!status) return;
          if (status.state === "stopped") return;
          $("launch").hidden = true;
          $("progress").hidden = false;

          expected = status.expectedSeconds || expected;
          clockStart = performance.now() - (status.elapsed || 0) * 1000;
          $("phase").textContent = status.phase || "Starting…";
          const log = (status.log || []).join("\n");
          $("log").textContent = log;
          $("log").scrollTop = $("log").scrollHeight;
          $("latest").textContent = (status.log || []).slice(-1)[0] || "";
          const heading = document.querySelector("h1");
          const name = heading.dataset.name;
          const state = status.state === "failed" ? ["failed", "Failed", name + " didn't start"]
            : status.state === "running" ? ["online", "Online", name + " is up"]
            : ["starting", "Starting", "Starting " + name + "…"];
          $("chip").className = "chip " + state[0];
          $("chip").lastChild.textContent = state[1];
          heading.textContent = state[2];

          const failed = status.state === "failed";
          document.body.classList.toggle("failed", failed);
          $("error").hidden = !failed;
          $("retry").hidden = !failed;
          $("latest").hidden = failed;
          if (failed) {
            $("fill").style.width = "100%";
            $("error").textContent = status.message || "The project didn't start.";
            $("output").open = true;
            polling = false;
          }
          if (status.state === "running") {
            polling = false;
            document.body.classList.add("ready");
            $("fill").style.width = "100%";
            $("phase").textContent = "Up — loading…";
            $("detail").firstChild.textContent = "Listening on port ";
            setTimeout(() => location.reload(), 400);
          }
        }

        // Eases towards 95% around the expected start time, and never claims
        // to be done until the port actually answers.
        function tick() {
          if (!polling) return;
          const seconds = (performance.now() - clockStart) / 1000;
          const fraction = 0.95 * (1 - Math.exp(-1.6 * seconds / expected));
          $("fill").style.width = (fraction * 100).toFixed(1) + "%";
          $("elapsed").textContent = Math.floor(seconds) + "s";
          requestAnimationFrame(tick);
        }

        async function poll() {
          while (polling) {
            await new Promise((r) => setTimeout(r, 700));
            try {
              const response = await fetch("/__beacon/status", { cache: "no-store" });
              show(await response.json());
            } catch (e) {
              // The daemon restarting, or the network blipping; keep trying.
            }
          }
        }

        function follow(status) {
          show(status);
          if (status && status.state === "starting" && !polling) {
            polling = true;
            requestAnimationFrame(tick);
            poll();
          }
        }

        async function start() {
          $("start").disabled = true;
          $("retry").hidden = true;
          follow({ state: "starting", phase: "Asking Beacon to " + action + " it…", elapsed: 0, expectedSeconds: initial && initial.expectedSeconds });
          try {
            const response = await fetch("/__beacon/" + action, {
              method: "POST",
              headers: { "X-Beacon-Action": action },
            });
            const body = await response.json();
            if (!response.ok || body.ok === false) {
              polling = false;
              show({ state: "failed", message: body.error || "Beacon couldn't start it.", log: [] });
              return;
            }
            follow(body);
          } catch (e) {
            polling = false;
            show({ state: "failed", message: "Couldn't reach Beacon: " + e.message, log: [] });
          }
        }

        $("start").addEventListener("click", start);
        $("retry").addEventListener("click", start);
        // Someone else (another tab, the CLI) may already be starting it.
        if (initial && initial.state === "starting") follow(initial);
        else if (initial && initial.state === "failed") show(initial);
        """#
    }

    /// The shell every Beacon page shares, laid out to the brand guide:
    /// Canvas surface, one raised card, the wordmark above it, Signal reserved
    /// for the main action.
    private static func page(
        status: String, title: String, detail: String, hint: String?,
        chip: (label: String, tone: String)? = nil, name: String? = nil, script: String?
    ) -> String {
        let chipHTML = chip.map {
            "<span id=\"chip\" class=\"chip \($0.tone)\"><i></i><span>\(escape($0.label))</span></span>"
        } ?? ""
        let nameAttribute = name.map { " data-name=\"\(escape($0))\"" } ?? ""
        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Beacon — \(escape(status))</title>
        <style>
        \(styles)
        </style>
        </head>
        <body>
        <div class="page">
          <header class="brand">
            <picture>
              <source media="(prefers-color-scheme: dark)" srcset="\(BrandArtwork.symbol)">
              <img src="\(BrandArtwork.wordmark)" alt="Beacon"
                   width="\(BrandArtwork.wordmarkWidth)" height="\(BrandArtwork.wordmarkHeight)">
            </picture>
          </header>
          <main>
            <div class="heading">
              <h1\(nameAttribute)>\(title)</h1>
              \(chipHTML)
            </div>
            <p class="detail" id="detail">\(detail)</p>
            \(hint ?? "")
          </main>
          <footer>\(escape(status))</footer>
        </div>
        \(script.map { "<script>\($0)</script>" } ?? "")
        </body>
        </html>
        """
    }

    /// Palette values from Brand/palette/beacon-colours.json; the dark
    /// surfaces and secondary text match the menu bar app's Theme.swift.
    private static let styles = """
      :root {
        color-scheme: light dark;
        --signal: #F5B544; --signal-hover: #EBA831; --ink: #181C20; --online: #38A88A; --failed: #D6453D;
        --canvas: #F5F3EE; --surface: #FFFFFF; --line: #E4E1DA; --text: #181C20;
        --secondary: #5B636C; --slate: #737C86; --tint: #F1EEE7; --selection: #FBE7C2;
      }
      @media (prefers-color-scheme: dark) {
        :root {
          --canvas: #181C20; --surface: #22262B; --line: #30353B; --text: #F5F3EE;
          --secondary: #9AA2AB; --tint: #1C2024; --selection: #4A3B1E; --failed: #F0645C;
        }
        .brand img { width: \(BrandArtwork.symbolWidth)px; height: \(BrandArtwork.symbolHeight)px; }
      }
      * { box-sizing: border-box; }
      body { margin: 0; min-height: 100vh; display: grid; place-items: center; padding: 32px 16px;
             background: var(--canvas); color: var(--text);
             font: 15px/1.5 -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
             -webkit-font-smoothing: antialiased; }
      .page { width: 100%; max-width: 480px; }
      .brand { margin: 0 0 24px 4px; }
      .brand img { display: block; }
      main { background: var(--surface); border: 1px solid var(--line); border-radius: 12px;
             padding: 24px; box-shadow: 0 1px 2px rgba(24, 28, 32, .04), 0 8px 24px rgba(24, 28, 32, .05); }
      .heading { display: flex; align-items: center; justify-content: space-between; gap: 16px; margin-bottom: 8px; }
      h1 { font-size: 24px; line-height: 1.25; font-weight: 600; letter-spacing: -.01em; margin: 0;
           overflow-wrap: anywhere; }
      p { margin: 0 0 16px; }
      .detail { color: var(--secondary); margin-bottom: 24px; }
      .muted { color: var(--secondary); font-size: 13px; }
      code, pre, .mono { font-family: ui-monospace, "SF Mono", SFMono-Regular, Menlo, monospace; }
      code { font-size: 13px; background: var(--tint); border: 1px solid var(--line);
             padding: 1px 6px; border-radius: 5px; color: var(--text); }
      footer { margin: 16px 4px 0; color: var(--secondary); font-size: 12px;
               font-family: ui-monospace, "SF Mono", Menlo, monospace; }

      .chip { display: inline-flex; align-items: center; gap: 6px; flex: none;
              font-size: 12px; font-weight: 500; color: var(--text); }
      .chip i { width: 8px; height: 8px; border-radius: 50%; box-sizing: border-box; }
      .chip.offline i { border: 1.5px solid var(--slate); }
      .chip.starting i { background: var(--signal); animation: pulse 1.2s ease-in-out infinite; }
      .chip.online i { background: var(--online); }
      .chip.failed i { background: var(--failed); }
      @keyframes pulse { 50% { opacity: .35; } }

      button { font: inherit; font-size: 14px; font-weight: 600; color: var(--ink); background: var(--signal);
               border: 0; border-radius: 8px; height: 36px; padding: 0 18px; cursor: pointer; }
      button:hover { background: var(--signal-hover); }
      button:focus-visible { outline: 2px solid var(--signal); outline-offset: 2px; }
      button:disabled { opacity: .55; cursor: default; }

      .status { display: flex; align-items: center; gap: 8px; margin-bottom: 8px; font-size: 13px; font-weight: 500; }
      .status #elapsed { margin-left: auto; color: var(--secondary); font-weight: 400;
                         font-variant-numeric: tabular-nums; }
      .spinner { width: 14px; height: 14px; border-radius: 50%; flex: none;
                 border: 2px solid var(--selection); border-top-color: var(--signal);
                 animation: spin .8s linear infinite; }
      @keyframes spin { to { transform: rotate(360deg); } }
      .bar { height: 4px; border-radius: 2px; overflow: hidden; margin-bottom: 8px; background: var(--tint); }
      #fill { height: 100%; width: 0; background: var(--signal); border-radius: 2px; transition: width .35s ease-out; }
      body.ready #fill { background: var(--online); }
      body.failed #fill { background: var(--failed); }
      body.ready .spinner, body.failed .spinner { display: none; }
      .latest { color: var(--secondary); font: 12px ui-monospace, "SF Mono", Menlo, monospace; min-height: 1.5em;
                margin-bottom: 16px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
      .error { color: var(--failed); font-size: 14px; }
      details { margin-bottom: 16px; }
      details summary { cursor: pointer; color: var(--secondary); font-size: 12px; font-weight: 500; }
      pre { font-size: 12px; line-height: 1.55; background: var(--tint); border: 1px solid var(--line);
            border-radius: 8px; padding: 8px 12px; margin: 8px 0 0; white-space: pre-wrap; word-break: break-word; }
      #log { max-height: 220px; overflow-y: auto; }

      ul.sites { list-style: none; padding: 0; margin: 0 -8px; }
      ul.sites li a { display: flex; align-items: center; justify-content: space-between; gap: 16px;
                      height: 44px; padding: 0 8px; border-radius: 7px; color: inherit; text-decoration: none; }
      ul.sites li a:hover { background: var(--selection); }
      ul.sites .domain { font-weight: 600; font-size: 14px; }
      ul.sites .port { color: var(--secondary); font: 13px ui-monospace, "SF Mono", Menlo, monospace; }
      @media (prefers-reduced-motion: reduce) {
        .spinner, .chip.starting i { animation: none; } #fill { transition: none; }
      }
    """

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
