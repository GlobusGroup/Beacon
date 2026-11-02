# Beacon

Local domains and reserved ports for your projects, on macOS.

Beacon replaces the bit of Laravel Herd that maps a project to a domain. You ask
it for a port, it gives you one and keeps it; `myproject.test` then serves
whatever is listening on that port, over HTTP and HTTPS, with no port in the URL.

```
$ cd ~/projects/shop
$ beacon register

  shop  ● running
  URL        https://shop.test
  Plain      http://shop.test
  Port       3104  ← bind your dev server here
  Path       /Users/you/projects/shop
```

## Why a registry

The port is the point. A project asks once and gets the same number back
forever, so the number can be committed to a `.env`, a `vite.config.js` or a
setup script without anyone having to remember which project owns 3000 this
week. Beacon never reassigns a reserved port, even while that project's dev
server is down.

That also makes it safe for a coding agent to call: `beacon register --json` is
idempotent, so an agent can run it at the start of every session, point the dev
server at the port it gets, and hand you `https://shop.test` instead of
`http://localhost:49213`.

## Install

Build the app with `make app` (or open `Beacon.xcodeproj` and run it), then
open `Beacon.app`. The daemon and the `beacon` command are bundled inside it,
under `Contents/Helpers`.

On first launch a setup window walks through two one-time steps. Each one is
introduced by Beacon before macOS asks anything, so no system dialog appears
unannounced:

1. **Install the background service** — macOS shows *"Allow administrator
   access for Beacon?"* and asks for your password. This registers the daemon
   with `launchd`, writes `/etc/resolver/test`, and installs `beacon` into
   `/usr/local/bin`.
2. **Trust Beacon's certificate** — macOS asks you to confirm a change to your
   certificate trust settings, with Touch ID or your password, so `https://`
   works. It's a separate step for a reason; see below.

After that, nothing asks for a password again: adding projects, changing
settings and restarting the service all go through the daemon's socket.

Uninstall from **Settings → Uninstall Beacon…**, or from a terminal:

```bash
beacon uninstall          # add --purge to also forget your projects
```

Terminal-only install, without the app:

```bash
make install
```

### Why the password panel, not Touch ID

The administrator prompt can't offer Touch ID. Installing a root service goes
through `AuthorizationExecuteWithPrivileges`, whose dialog is password-only;
Laravel Herd asks for a typed password at the same point, for the same reason.
Its note that macOS "could not verify" Beacon appears because builds aren't
notarised. The certificate step is per-user and does accept Touch ID.

## Using it

```bash
beacon register                 # register the current directory
beacon register shop            # …or a name
beacon register shop --domain shop.test --port 3000
beacon register shop --alias admin --alias api

beacon list                     # every project, and which are running
beacon info shop
beacon port shop                # just the number, for scripts
beacon url shop                 # just the URL
beacon open shop
beacon unregister shop

beacon restart                  # no sudo needed
beacon status                   # is the service healthy?
beacon config --add-tld dev     # own another TLD
beacon config --port-range 4000-4999
```

`--port` (and the Port field in the app's Add project window) asks for a
specific port. Beacon accepts it unless another project already holds it
(`port_taken`) or Beacon listens on it itself (`port_reserved_by_beacon`). The
refusal names the owner and a free port to use instead. With `--json`, errors go
to stdout as `{"ok": false, "error": {"code", "message", "suggestedPort", "hint", …}}`,
where `hint` is a command that will succeed, and the exit status is 1.

In a script:

```bash
PORT=$(beacon port) npm run dev
```

### Starting projects from the browser

Open a project's domain while its dev server is down and Beacon's "isn't
running" page offers to start it. Click **Start**, and the page shows a
spinner, a progress bar and the command's output, then reloads into the app
once something answers on the port.

Beacon works out the command from the project directory:

| Found | Runs |
| --- | --- |
| `compose.yaml` / `docker-compose.yml` that publishes the port | `docker compose up -d` |
| a compose file and a `package.json` | `docker compose up -d && npm run dev` |
| `package.json` with `dev`, `start` or `serve` | `npm run dev` (or `pnpm`/`yarn`/`bun` by lockfile), with `--port $PORT` for Vite, Astro and Nuxt |
| `artisan` | `php artisan serve --port=$PORT` |
| `bin/dev` or `bin/rails` | `bin/dev`, or `bin/rails server -p $PORT` |
| `manage.py` | `python manage.py runserver 127.0.0.1:$PORT` |

Anything else, or to override the guess:

```bash
beacon register shop --run "make serve"   # 'auto' goes back to detecting
```

The command runs as the owner of the project directory, in a login shell
(so `nvm`, `asdf` and Docker are on the `PATH` as in a terminal), with
`PORT`, `BEACON_PORT` and `BEACON_URL` set. The same thing from a terminal:

```bash
beacon start shop      # waits until it's up, printing its output
beacon logs shop       # follow the output afterwards
beacon stop shop       # also runs `docker compose stop` for compose projects
```

The start endpoint only accepts requests from Beacon's own page: it needs a
custom header, which another site can't send without a CORS preflight
Beacon never approves.

### Subdomains come free

`anything.shop.test` resolves and routes to `shop` without being registered —
DNS answers for the whole subtree and the TLS certificate carries a wildcard.
Use `--alias` only when you want a genuinely different name to reach the same
project.

## Sharing on a public URL

With a [Beacon relay](Relay/README.md) running on a server you control, any
registered project can be put on the internet:

```bash
beacon relay --url beacon.cab --token <token>   # once
beacon share shop                               # → https://shop-dean.beacon.cab
beacon share shop --password hunter2            # basic auth, any username
beacon unshare shop
beacon relay                                    # tunnel state and what's shared
```

In the menu bar app, set the relay and token under **Settings → Sharing**,
then right-click a project and choose **Share on the internet…**. Shared
projects show a globe; the context menu copies or opens the public URL.

The daemon keeps one outbound WebSocket open to the relay while anything is
shared, and relays each visitor to the project's port, so nothing on the Mac
listens on the internet. The URL is `<project>-<label>.<domain>`, where the
label belongs to your token, so it's the same every time. Shares persist across
restarts until unshared. Dev servers that check `Host` need to allow the
relay's domain (Vite: `server.allowedHosts: ['.beacon.cab']`).

## Telling a coding agent about it

```bash
beacon agent-guide --write
```

Appends a short section to `CLAUDE.md` (or `AGENTS.md`) telling the agent to ask
Beacon for the port rather than inventing one, and to hand you the domain rather
than a `localhost` URL.

## How it works

| Piece | What it does |
| --- | --- |
| `beacond` | Root `launchd` service. Owns everything below. |
| DNS responder | Listens on `127.0.0.1:53535`. `/etc/resolver/<tld>` points macOS at it. Answers every name under a managed TLD with `127.0.0.1`. |
| Reverse proxy | Binds `:80` and `:443`. Reads each request's `Host`, looks up the project, relays to `127.0.0.1:<port>`. |
| Certificate authority | A local root trusted in your login keychain, plus one leaf certificate covering every registered domain, reissued when the list changes. |
| Registry | `/Library/Application Support/Beacon/sites.json`. Written on every change. |
| Control socket | `/var/run/beacon.sock`, group `staff`, so the CLI and the app work without `sudo`. |
| Tunnel client | While anything is shared, one WebSocket to the relay. Settings and token in `relay.json`, root-only. |

The proxy rewrites `X-Forwarded-Proto`, `-Host`, `-Port` and `-For` on **every**
request, not just the first on a connection — frameworks that generate absolute
URLs need that on each one. Anything the client sent as `X-Forwarded-*` is
dropped first. The response direction is never parsed, so streaming, SSE and
HTTP/1.0 responses pass through untouched. After a WebSocket upgrade or
`CONNECT`, the connection becomes a plain byte relay.

### Why trusting the certificate is its own step

Trust lives in **your** login keychain, not the system one, and `beacon trust`
runs as you rather than as root.

That isn't a shortcut. Writing system-wide trust settings goes through an
authorisation right that macOS only grants when it can put a dialog in front of
a logged-in person. A `launchd` daemon has no session to draw in, so it fails
with *"the authorization was denied since no user interaction was possible"* —
and so does `sudo security add-trusted-cert`, because being root doesn't
conjure a session either. Per-user trust needs no privileges, prompts once, and
is what Safari and Chrome actually consult.

The practical consequences:

- Run `beacon trust` **as yourself**, logged in at the Mac. Not with `sudo`, not
  over SSH.
- `beacon status` reports trust from whichever process asks, since the answer
  differs per user. The daemon never reports it.
- Another user account on the same Mac runs `beacon trust` once for themselves.

### Why `.test` and not `.local`

`.local` is reserved for mDNS/Bonjour. Using it for project domains means every
lookup races against multicast discovery and can collide with real devices on
the network. `.test` is reserved by the IETF for exactly this purpose and
resolves instantly. Add others with `beacon config --add-tld`.

## Developing

```bash
make dev
```

Runs the full stack on ports 8080/8443/15353 against a throwaway registry in
`/tmp/beacon-dev`. Nothing is installed and the real system is untouched. Drive
it with `BEACON_ROOT=/tmp/beacon-dev .build/release/beacon …`.

## Brand

`Brand/` holds the brand kit as supplied: the guide (`Beacon-Brand-Guide.pdf`),
logos, palette and the original concept board. The guide is the current
reference; the concept board's tagline has been dropped and shouldn't be reused.

The app icon, menu bar icon and in-app artwork are derived from it by
`swift Scripts/generate-brand-assets.swift`. Rerun that after updating the kit.

## Layout

```
Package.swift            daemon, CLI, shared library
Brand/                   brand kit v1.0: guide, logos, palette, concept board
Scripts/                 asset generator and the app's embed build phase
Sources/beacond/         DNS, proxy, certificates, registry, control socket
Sources/beacon/          the CLI
Sources/BeaconTunnel/    tunnel wire format and HTTP head handling, shared with the relay
Sources/beacon-relay/    the public relay server (Linux)
Relay/                   Dockerfile, compose file and setup guide for the relay
Beacon/                  the menu bar app (Xcode target)
Beacon/Shared/           models and IPC, compiled into both the app and the package
Beacon.xcodeproj         the app
```

`Beacon/Shared` is a SwiftPM target *and* part of the app's synchronized file
group, so the app and the service share one definition of the wire format
without the Xcode project needing a package reference.
