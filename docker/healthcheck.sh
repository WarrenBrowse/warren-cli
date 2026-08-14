#!/bin/sh
# Docker HEALTHCHECK: healthy = the daemon answers and the tunnel state is
# Connected. WARREN_HEALTH_TARGET (a URL) adds a real egress probe on top;
# leave it unset to avoid periodic clear-signal traffic to a fixed host.
set -u

state=$(/usr/bin/warren status 2>/dev/null | head -1) || exit 1
case "$state" in
Connected*) ;;
*) echo "tunnel state: ${state:-daemon unreachable}"; exit 1 ;;
esac

if [ -n "${WARREN_HEALTH_TARGET:-}" ]; then
    curl -fsS --max-time 10 -o /dev/null "$WARREN_HEALTH_TARGET" || {
        echo "egress probe to WARREN_HEALTH_TARGET failed"
        exit 1
    }
fi
exit 0
