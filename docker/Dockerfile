# syntax=docker/dockerfile:1
# Warren VPN client container (gluetun-class): the headless warren-daemon +
# warren CLI from a released warren-vpn-daemon .deb, driven by an env-first
# entrypoint. Needs --cap-add NET_ADMIN and --device /dev/net/tun.
#
# The channel picks the release series and the artifact naming (shared
# release-channel contract); asset names are resolved through the same
# sourceable functions the installer uses, so the two cannot drift.
#
# The daemon version is a required build-arg: it is what makes the download
# part of Docker's cache key. Use docker/build.sh, which resolves the latest
# release of a channel and passes it:
#   ./docker/build.sh                    latest release of the live (beta) channel
#   ./docker/build.sh --channel prod
# Or pin it yourself:
#   docker build -f docker/Dockerfile \
#     --build-arg WARREN_CHANNEL=prod --build-arg WARREN_DAEMON_VERSION=1.2.1 \
#     -t warren-vpn .
# Build from a locally built .deb (drop it in docker/local-debs/ first):
#   docker build -f docker/Dockerfile --build-arg LOCAL_DEB=1 -t warren-vpn .

FROM debian:stable-slim AS unpack
ARG WARREN_CHANNEL=beta
ARG WARREN_DAEMON_VERSION=""
ARG TARGETARCH
ARG LOCAL_DEB=""
ARG DEB_URL=""
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*
COPY scripts/install.sh /warren-install-lib.sh
COPY docker/local-debs/ /local-debs/
RUN set -eu; \
    deb=""; \
    if [ -n "$LOCAL_DEB" ]; then \
      deb="$(ls /local-debs/warren-vpn-daemon*_"$TARGETARCH".deb 2>/dev/null | head -1)"; \
      [ -n "$deb" ] || { echo "LOCAL_DEB set but no warren-vpn-daemon*_$TARGETARCH.deb in docker/local-debs/" >&2; exit 1; }; \
    else \
      WARREN_INSTALL_LIB=1 . /warren-install-lib.sh; \
      case "$TARGETARCH" in \
        amd64) machine=x86_64 ;; \
        arm64) machine=aarch64 ;; \
        *) echo "unsupported TARGETARCH $TARGETARCH" >&2; exit 1 ;; \
      esac; \
      url="$DEB_URL"; \
      if [ -z "$url" ]; then \
        [ -n "$WARREN_DAEMON_VERSION" ] || { \
          echo "WARREN_DAEMON_VERSION is required." >&2; \
          echo "Resolving the latest release from inside this layer would be invisible to" >&2; \
          echo "Docker's cache key: the same build command, run again after a daemon" >&2; \
          echo "release, would reuse the cached layer and reship the old daemon. Run" >&2; \
          echo "./docker/build.sh (it resolves the version and passes it here), or pass" >&2; \
          echo "--build-arg WARREN_DAEMON_VERSION=x.y.z yourself." >&2; \
          exit 1; }; \
        prefix="$(warren_tag_prefix "$WARREN_CHANNEL")"; \
        asset="$(warren_asset Linux deb "$WARREN_DAEMON_VERSION" "$WARREN_CHANNEL" "$machine")"; \
        url="https://github.com/WarrenBrowse/warren-cli/releases/download/${prefix}${WARREN_DAEMON_VERSION}/${asset}"; \
      fi; \
      echo "fetching $url"; \
      deb=/tmp/warren.deb; \
      curl -fSL -o "$deb" "$url"; \
    fi; \
    dpkg-deb -x "$deb" /rootfs; \
    test -x /rootfs/usr/bin/warren-daemon; \
    test -x /rootfs/usr/bin/warren

FROM debian:stable-slim
# libdbus-1-3 is a hard runtime dependency of warren-daemon (the deb's
# `Depends`), and `dpkg-deb -x` in the unpack stage resolves no dependencies,
# so it must be installed explicitly or the daemon dies at load time with
# `libdbus-1.so.3: cannot open shared object file`.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       ca-certificates nftables iproute2 curl libdbus-1-3 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=unpack /rootfs/ /
COPY docker/entrypoint.sh /usr/local/bin/warren-entrypoint
COPY docker/healthcheck.sh /usr/local/bin/warren-healthcheck
RUN chmod 755 /usr/local/bin/warren-entrypoint /usr/local/bin/warren-healthcheck

ENV WARREN_LOCKDOWN=on \
    WARREN_LAN=allow \
    WARREN_CONNECT_TIMEOUT=90 \
    WARREN_PORT_FORWARD_STATUS_FILE=/tmp/warren/forwarded_port

LABEL org.opencontainers.image.title="Warren VPN" \
      org.opencontainers.image.description="Warren VPN client container: kill switch, NAT-PMP port forwarding, share the tunnel with network_mode: service:<name>" \
      org.opencontainers.image.source="https://github.com/WarrenBrowse/warren-cli" \
      org.opencontainers.image.licenses="AGPL-3.0-or-later"

# The tunnel takes a few seconds after daemon boot; be patient before
# declaring the container unhealthy so orchestrators do not flap it.
HEALTHCHECK --interval=60s --timeout=15s --start-period=120s --retries=2 \
  CMD ["/usr/local/bin/warren-healthcheck"]

ENTRYPOINT ["/usr/local/bin/warren-entrypoint"]
