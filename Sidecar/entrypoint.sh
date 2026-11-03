#!/bin/sh
# Fetches Beacon's root certificate from the Mac, writes a CA bundle that
# trusts it into /trust, then forwards ports 80 and 443 to Beacon untouched.
# Compose gives this container the project's domains as network aliases, so
# other services that look them up land here. See README.md.
set -eu

HOST="${BEACON_HOST:-host.docker.internal}"
HTTP_PORT="${BEACON_HTTP_PORT:-80}"
HTTPS_PORT="${BEACON_HTTPS_PORT:-443}"
TRUST=/trust
CA_URL="http://$HOST:$HTTP_PORT/__beacon/ca.pem"

log() { echo "beacon-sidecar: $*"; }

# Prints the CA to stdout, or fails if Beacon didn't hand back a certificate.
fetch_ca() {
    pem="$(wget -q -T 5 -O - "$CA_URL" 2>/dev/null)" || return 1
    case "$pem" in
        *"BEGIN CERTIFICATE"*) printf '%s\n' "$pem" ;;
        *) return 1 ;;
    esac
}

# Writes each file next to its final name and renames it, so a service never
# reads a half-written bundle.
write_bundle() {
    printf '%s\n' "$1" > "$TRUST/.beacon-ca.pem"
    cat /etc/ssl/certs/ca-certificates.crt "$TRUST/.beacon-ca.pem" > "$TRUST/.bundle"
    mv "$TRUST/.beacon-ca.pem" "$TRUST/beacon-ca.pem"
    # Debian, Ubuntu and Alpine read this path. Fedora and RHEL don't, and
    # get there through the SSL_CERT_FILE that `beacon docker init` sets.
    mv "$TRUST/.bundle" "$TRUST/ca-certificates.crt"
}

if ! touch "$TRUST/.writable" 2>/dev/null; then
    log "can't write to $TRUST. If the beacon-trust volume was created by another"
    log "container first, remove it (docker compose down -v) and start again."
    exit 1
fi
rm -f "$TRUST/.writable"

until ca="$(fetch_ca)"; do
    log "waiting for Beacon at $CA_URL (is it running on the host?)"
    sleep 2
done
write_bundle "$ca"
log "trust bundle ready"

socat TCP-LISTEN:80,fork,reuseaddr "TCP:$HOST:$HTTP_PORT" &
http_pid=$!
socat TCP-LISTEN:443,fork,reuseaddr "TCP:$HOST:$HTTPS_PORT" &
https_pid=$!
trap 'kill "$http_pid" "$https_pid" 2>/dev/null; exit 0' TERM INT

touch /tmp/ready
log "forwarding :80 and :443 to Beacon at $HOST"

# Watches the forwarders, and picks up a new CA if Beacon makes one (after a
# reinstall, say). Restarting the services is still needed for them to see it.
ticks=0
while kill -0 "$http_pid" 2>/dev/null && kill -0 "$https_pid" 2>/dev/null; do
    sleep 1
    ticks=$((ticks + 1))
    [ "$ticks" -lt 60 ] && continue
    ticks=0
    if latest="$(fetch_ca)" && [ "$latest" != "$(cat "$TRUST/beacon-ca.pem")" ]; then
        write_bundle "$latest"
        log "Beacon's certificate changed; bundle updated. Restart your services to pick it up."
    fi
done

log "a forwarder stopped; exiting"
exit 1
