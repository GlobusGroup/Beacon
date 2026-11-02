# beacon-relay, built for Linux. Build from the package root:
#   docker build -f Relay/Dockerfile -t beacon-relay .

FROM swift:6.2-noble AS build
WORKDIR /src

# Resolve dependencies in their own layer so source edits don't refetch them.
COPY Package.swift Package.resolved ./
RUN swift package resolve

COPY Sources ./Sources
COPY Beacon/Shared ./Beacon/Shared
RUN swift build -c release --product beacon-relay --static-swift-stdlib \
 && cp "$(swift build -c release --show-bin-path)/beacon-relay" /beacon-relay

FROM ubuntu:noble
RUN useradd --system --no-create-home --shell /usr/sbin/nologin beacon \
 && mkdir /data && chown beacon /data
# Tokens made through the admin API. A named volume copies this directory's
# owner, so the relay can write to it without running as root.
VOLUME /data
COPY --from=build /beacon-relay /usr/local/bin/beacon-relay
USER beacon
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/beacon-relay"]
