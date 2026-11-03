# beacon-sidecar: lets containers reach Beacon domains over trusted HTTPS.
# Built by .github/workflows/sidecar-image.yml. To build it yourself:
#   docker build -t ghcr.io/globusgroup/beacon-sidecar:dev Sidecar

FROM alpine:3.20
RUN apk add --no-cache ca-certificates socat \
 && adduser -S -H -s /sbin/nologin beacon \
 && mkdir /trust && chown beacon /trust
# The bundle every other service mounts as /etc/ssl/certs. A named volume
# copies this directory's owner, so the sidecar can write to it without root.
VOLUME /trust
COPY --chmod=755 entrypoint.sh /usr/local/bin/beacon-sidecar
USER beacon
EXPOSE 80 443
HEALTHCHECK --interval=2s --timeout=2s --start-period=60s --retries=3 \
  CMD test -f /tmp/ready
ENTRYPOINT ["/usr/local/bin/beacon-sidecar"]
