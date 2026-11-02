# beacon-relay

The public end of `beacon share`. Each Mac running Beacon keeps one outbound
WebSocket open to the relay; visitors to `https://shop-dean.beacon.cab` are
relayed down it to the project's dev server. Nothing on the Mac listens on the
internet, so no port forwarding or firewall changes are needed.

```
browser ──https──▶ Traefik ──http──▶ beacon-relay ══ WebSocket ══▶ beacond ──▶ 127.0.0.1:3104
                  (TLS, *.beacon.cab)    (routes by Host)        (on the Mac)
```

## Setting it up

### 1. DNS (Cloudflare)

Two records, both **DNS only** (grey cloud), pointing at the server:

| Type | Name | Content |
| --- | --- | --- |
| `A` | `beacon.cab` | server IP |
| `A` | `*` | server IP |

The relay never creates DNS records. The wildcard makes every name resolve,
and the relay decides which ones are live.

### 2. A wildcard certificate in Traefik

Traefik needs a certificate covering `beacon.cab` and `*.beacon.cab`. Wildcards
can only be issued through the DNS challenge, so Traefik needs a Cloudflare API
token with **Zone → DNS → Edit** on the `beacon.cab` zone, passed to Traefik as
`CF_DNS_API_TOKEN`. If your Traefik already has a Cloudflare resolver, reuse
it. Otherwise, add one to Traefik's static configuration:

```yaml
certificatesResolvers:
  cloudflare:
    acme:
      email: you@example.com
      storage: /letsencrypt/acme.json
      dnsChallenge:
        provider: cloudflare
```

The compose file's labels ask that resolver for both names.

### 3. Tokens and start

The image is built by GitHub Actions
([`relay-image.yml`](../.github/workflows/relay-image.yml)) and pushed to
`ghcr.io/globusgroup/beacon-relay`:

- every push to `main` that touches the relay → tag `main`
- every `v1.2.3` tag → tags `1.2.3` and `1.2`
- every build → the commit's short SHA

The server needs only this directory's `docker-compose.yml` and a `.env`:

```bash
cp .env.example .env    # set IMAGE_TAG, BEACON_DOMAIN and BEACON_TOKENS
docker compose pull && docker compose up -d
curl https://beacon.cab/healthz
```

While the package is private on GHCR, log the server in once with a token
that has `read:packages`: `docker login ghcr.io -u <github user>`.

To build the image yourself instead, from the package root:
`docker build -f Relay/Dockerfile -t ghcr.io/globusgroup/beacon-relay:dev .`

`BEACON_TOKENS` is a list of `label:token` pairs:

```
BEACON_TOKENS=dean:3f9c…,sam:81aa…
```

The label is whoever holds the token. It appears in the logs and namespaces
their URLs: Dean sharing `shop` gets `shop-dean.beacon.cab`, Sam sharing `shop`
gets `shop-sam.beacon.cab`. Generate tokens with `openssl rand -hex 24`. To
revoke one, remove it and run `docker compose up -d`; the relay keeps no other
state, so a restart costs nothing but a few seconds of reconnects.

Match `TRAEFIK_NETWORK`, `TRAEFIK_ENTRYPOINT` and `TRAEFIK_CERTRESOLVER` in
`.env` to your Traefik setup. The labels use Traefik v3 rule syntax.

### 4. On each Mac

```bash
beacon relay --url beacon.cab --token <their token>
beacon share shop                    # → https://shop-dean.beacon.cab
beacon share shop --password hunter2 # visitors must give it (any username)
beacon unshare shop
beacon relay                         # what's shared, and the tunnel's state
```

## How it behaves

- **One request per relayed connection.** Traefik pools its connections to the
  relay and would send different visitors' requests, for different hosts, down
  the same one. So the relay forwards exactly one request per connection,
  rewritten with `Connection: close`. Routing, password checks and
  `X-Forwarded-For` are therefore decided per request. Browsers keep their
  keep-alive connection to Traefik as usual.
- **Forwarding headers** are set by the relay: `X-Forwarded-Proto: https`,
  `-Host`, `-Port: 443`, and `-For` taken from the last entry Traefik appended.
  Anything a visitor sent as `X-Forwarded-*` is dropped. `Host` is left as the
  public name.
- **WebSockets, SSE and streaming** pass through. After an upgrade the
  connection is a plain byte relay.
- **Flow control** is per stream, with a 512KB window, so one slow download
  can't make either end buffer without limit or stall other visitors.
- **Reconnects.** The Mac pings every 20 seconds and redials with backoff (up
  to 30 seconds) if the tunnel drops. A rejected token is retried every minute.
  Sharing survives daemon restarts and sleep.
- **Same label, two connections.** If the same token shares the same project
  from a second connection, the newest one takes it over, which is what a Mac
  reconnecting after a network change needs. A different label can never take
  a hostname over.

## Things to know

- **Dev servers that check `Host`** must allow the relay's domain. Vite:
  `server.allowedHosts: ['.beacon.cab']`. Rails: `config.hosts << ".beacon.cab"`.
- **Traefik's read timeout.** Traefik v3 defaults
  `entryPoints.<name>.transport.respondingTimeouts.readTimeout` to 60s. If
  `beacon relay` shows the tunnel reconnecting about once a minute, set it to
  `0` on the entrypoint. The tunnel recovers either way; this just stops the
  churn.
- **Shares are public** unless given `--password`. Anyone with the URL reaches
  the dev server, including its debug pages.

## Configuration

| Variable | Default | |
| --- | --- | --- |
| `BEACON_DOMAIN` | required | The apex, e.g. `beacon.cab` |
| `BEACON_TOKENS` | required | `label:token` pairs; tokens 16+ characters |
| `PORT` | `8080` | Where the relay listens |
| `BEACON_PUBLIC_SCHEME` | `https` | Scheme visitors use, for URLs and `X-Forwarded-Proto` |
| `BEACON_PUBLIC_PORT` | `443` | Port visitors use |
| `BEACON_TRUST_FORWARDED_FOR` | `true` | Read the client address from `X-Forwarded-For`. Only safe behind a proxy |
| `BEACON_VERBOSE` | `false` | Log every relayed request |

## Running it locally

From the package root, with no Traefik and no TLS:

```bash
swift build --product beacon-relay
BEACON_DOMAIN=beacon.cab BEACON_TOKENS=dean:$(openssl rand -hex 24) \
  BEACON_PUBLIC_SCHEME=http BEACON_PUBLIC_PORT=8090 PORT=8090 \
  BEACON_TRUST_FORWARDED_FOR=false .build/debug/beacon-relay
```

Point a Mac at it with `beacon relay --url ws://127.0.0.1:8090 --token …`, and
reach a share with
`curl --resolve shop-dean.beacon.cab:8090:127.0.0.1 http://shop-dean.beacon.cab:8090/`.
