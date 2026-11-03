# beacon-sidecar

Lets containers in a Docker Compose project call Beacon domains like
`https://shop.test`, with normal certificate checks.

You don't write the compose config for it yourself. Run this in the project:

```bash
beacon docker init
```

## Why it's needed

Without it, two things go wrong inside a container:

1. **The name points at the container.** Docker Desktop hands the lookup to
   macOS, and Beacon answers `127.0.0.1`. Inside a container that's the
   container's own loopback, so nothing answers on port 443.
2. **The certificate isn't trusted.** Your keychain trusts Beacon's root
   certificate, but each image has its own list of trusted roots.

Beacon can't fix the first one in its DNS server. Docker proxies container
traffic onto the Mac, so a container's lookup arrives from `127.0.0.1`, the
same as your browser's.

## How it works

```
web container ──https://shop.test──▶ beacon sidecar ══ TCP ══▶ Beacon on the Mac ──▶ 127.0.0.1:3104
               (network alias)       :80 / :443                  host.docker.internal:443
```

- **Names.** The sidecar takes the project's domains as network aliases on
  every network the services use. Docker's own DNS answers those names with
  the sidecar's address, so the services' DNS settings stay as they are.
- **Traffic.** The sidecar forwards ports 80 and 443 to Beacon on the Mac as
  raw TCP. It doesn't decrypt anything: Beacon still terminates TLS and
  routes by `Host`, exactly as it does for your browser.
- **Trust.** On start, the sidecar fetches Beacon's root certificate from
  `http://host.docker.internal/__beacon/ca.pem`. It adds it to the usual
  public roots and writes the result to the `beacon-trust` volume. Every other
  service mounts that volume read-only as `/etc/ssl/certs`, and gets
  `SSL_CERT_FILE`, `REQUESTS_CA_BUNDLE` and `NODE_EXTRA_CA_CERTS` pointing
  into it.
- **Start order.** The image's health check passes once the bundle is written,
  and each service waits for it with `depends_on: condition: service_healthy`.
  If Beacon isn't running yet, the sidecar keeps retrying.
- **New certificates.** Once a minute the sidecar checks Beacon's root
  certificate again and rewrites the bundle if it changed (after a reinstall,
  say). Restart the services so they pick it up.

Tested with curl on Alpine, Python on Debian, Node on Alpine and curl on
Fedora.

## `beacon docker init`

It reads the project with `docker compose config`, which has already merged
your files, profiles and variables, and writes the override file Compose
loads by itself. That's `compose.override.yaml`, or `docker-compose.override.yml`
to match your compose file. Your own files aren't touched, and Compose merges
the services' existing `environment`, `volumes` and `depends_on` with the new
entries.

```bash
beacon docker init                          # every service, this project's domain and aliases
beacon docker init --service web            # only some services; repeatable
beacon docker init --domain api.shop.test   # subdomains the containers call; repeatable
beacon docker init --project auth           # another Beacon project they call; repeatable
beacon docker init --stdout                 # print instead of writing
```

If you already have an override file of your own, it writes
`compose.beacon.yml` instead, and prints the `COMPOSE_FILE=…` line to load
it. Re-run it after adding services or aliases; it replaces only a file it
wrote itself.

## Things to know

- **Subdomains need listing.** Network aliases can't be wildcards, so
  `admin.shop.test` only works from a container if you pass it with
  `--domain`.
- **`network_mode: host` services** can't see the aliases. They still get the
  CA bundle.
- **Certificates baked into an image** are hidden, because the volume
  replaces `/etc/ssl/certs`. If a service needs a corporate root certificate,
  leave it out with `--service` and add Beacon's certificate to that image
  yourself.
- **Java** keeps its own trust store, so it doesn't read the bundle. Import
  `/etc/ssl/certs/beacon-ca.pem` with `keytool`.
- **Other runtimes.** `host-gateway` works with Docker Desktop, OrbStack and
  Colima. The sidecar reaches the Mac through `host.docker.internal`; set
  `BEACON_HOST` if your runtime calls it something else.

## Settings

| Variable | Default | What it's for |
| --- | --- | --- |
| `BEACON_HOST` | `host.docker.internal` | Where Beacon is |
| `BEACON_HTTP_PORT` | `80` | Beacon's HTTP port; also where the CA is fetched from |
| `BEACON_HTTPS_PORT` | `443` | Beacon's HTTPS port |

`beacon docker init` sets the ports when Beacon isn't on 80 and 443, as with
`make dev`.

## The image

Built by GitHub Actions
([`sidecar-image.yml`](../.github/workflows/sidecar-image.yml)) for amd64 and
arm64, and pushed to `ghcr.io/globusgroup/beacon-sidecar`:

- every push to `main` that touches `Sidecar/` gets tag `main`
- every `v1.2.3` tag gets tags `1.2.3` and `1.2`

`beacon docker init` writes the `major.minor` tag of the Beacon it came with.

To build the image yourself:

```bash
docker build -t ghcr.io/globusgroup/beacon-sidecar:dev Sidecar
beacon docker init --image ghcr.io/globusgroup/beacon-sidecar:dev
```
