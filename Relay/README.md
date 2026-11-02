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

The main README has the [step-by-step guide](../README.md#run-your-own-relay):
DNS, a wildcard certificate in Traefik, tokens, and the compose file and
`.env` for your server or hosting panel.

The image is built by GitHub Actions
([`relay-image.yml`](../.github/workflows/relay-image.yml)) and pushed to
`ghcr.io/globusgroup/beacon-relay`:

- every push to `main` that touches the relay gets tag `main`
- every `v1.2.3` tag gets tags `1.2.3` and `1.2`
- every build gets the commit's short SHA

To build the image yourself, from the package root:
`docker build -f Relay/Dockerfile -t ghcr.io/globusgroup/beacon-relay:dev .`

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
