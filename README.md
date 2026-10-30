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

In a script:

```bash
PORT=$(beacon port) npm run dev
```

### Subdomains come free

`anything.shop.test` resolves and routes to `shop` without being registered —
DNS answers for the whole subtree and the TLS certificate carries a wildcard.
Use `--alias` only when you want a genuinely different name to reach the same
project.

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

## Layout

```
Package.swift            daemon, CLI, shared library
Sources/beacond/         DNS, proxy, certificates, registry, control socket
Sources/beacon/          the CLI
Beacon/                  the menu bar app (Xcode target)
Beacon/Shared/           models and IPC, compiled into both the app and the package
Beacon.xcodeproj         the app
```

`Beacon/Shared` is a SwiftPM target *and* part of the app's synchronized file
group, so the app and the service share one definition of the wire format
without the Xcode project needing a package reference.
