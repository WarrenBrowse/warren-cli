#!/bin/sh
# Smoke and live tests for the warren-vpn container image.
#
#   ./docker/test-image.sh [image]              offline assertions only
#   WARREN_TEST_MNEMONIC_FILE=... ./docker/test-image.sh [image]
#                                               adds the live end-to-end run
#
# Offline tests assert the entrypoint's own refusal paths, so they need no
# account, no network and no privileges. The live test needs a subscribed
# recovery phrase and really connects to the Warren network.
set -u

IMAGE=${1:-warren-vpn:test}
PLATFORM_ARGS=${WARREN_TEST_PLATFORM:+--platform "$WARREN_TEST_PLATFORM"}
FAILED=0

say() { printf '== %s\n' "$*"; }
pass() { printf 'PASS %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*"; FAILED=1; }

# shellcheck disable=SC2086  # PLATFORM_ARGS is deliberately word-split
drun() { docker run --rm $PLATFORM_ARGS "$@"; }

say "offline: entrypoint refuses when /dev/net/tun is missing"
out=$(drun "$IMAGE" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "no /dev/net/tun"; then
    pass "refused without tun device"
else
    fail "expected a tun refusal, got rc=$rc: $out"
fi

say "offline: entrypoint refuses without a mnemonic"
out=$(drun --cap-add NET_ADMIN --device /dev/net/tun "$IMAGE" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "no WARREN_MNEMONIC"; then
    pass "refused without mnemonic"
else
    fail "expected a mnemonic refusal, got rc=$rc: $out"
fi

say "offline: healthcheck is unhealthy when the daemon is not running"
if drun --entrypoint /usr/local/bin/warren-healthcheck "$IMAGE" >/dev/null 2>&1; then
    fail "healthcheck reported healthy with no daemon"
else
    pass "healthcheck unhealthy without daemon"
fi

if [ -z "${WARREN_TEST_MNEMONIC_FILE:-}" ]; then
    say "live tests skipped (set WARREN_TEST_MNEMONIC_FILE to run them)"
    [ "$FAILED" -eq 0 ] && say "offline tests all green"
    exit "$FAILED"
fi

[ -r "$WARREN_TEST_MNEMONIC_FILE" ] || { fail "WARREN_TEST_MNEMONIC_FILE unreadable"; exit 1; }

NAME="warren-test-$$"
cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM

say "live: bring the tunnel up (this dials the real Warren network)"
# shellcheck disable=SC2086
docker run -d --name "$NAME" $PLATFORM_ARGS \
    --cap-add NET_ADMIN --device /dev/net/tun \
    -v "$WARREN_TEST_MNEMONIC_FILE:/run/secrets/warren_mnemonic:ro" \
    -e WARREN_MNEMONIC_FILE=/run/secrets/warren_mnemonic \
    -e WARREN_PORT_FORWARD_INTERNAL_PORT=56881 \
    -e WARREN_PORT_FORWARD_UP_COMMAND='printf %s {{PORT}} > /tmp/warren/up_ran' \
    ${WARREN_TEST_EXTRA_ENV:-} \
    "$IMAGE" >/dev/null || { fail "docker run failed"; exit 1; }

i=0
until [ "$(docker inspect -f '{{.State.Health.Status}}' "$NAME" 2>/dev/null)" = "healthy" ]; do
    i=$((i + 1))
    if [ "$i" -gt 60 ]; then
        fail "container never became healthy"; docker logs "$NAME" | tail -40; exit 1
    fi
    if [ "$(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null)" != "true" ]; then
        fail "container exited during bring-up"; docker logs "$NAME" | tail -40; exit 1
    fi
    sleep 5
done
pass "container healthy (tunnel Connected)"

say "live: egress rides the tunnel"
tunnel_ip=$(docker exec "$NAME" curl -fsS --max-time 20 https://icanhazip.com 2>/dev/null | tr -d '[:space:]')
if [ -n "$tunnel_ip" ]; then
    pass "egress OK via $tunnel_ip"
else
    fail "no egress through the tunnel"
fi

say "live: kill switch blocks when disconnected"
docker exec "$NAME" warren disconnect --wait >/dev/null 2>&1
if docker exec "$NAME" curl -fsS --max-time 10 https://icanhazip.com >/dev/null 2>&1; then
    fail "traffic escaped while disconnected (kill switch broken)"
else
    pass "no egress while disconnected"
fi
docker exec "$NAME" warren connect --wait >/dev/null 2>&1 || fail "reconnect failed"

say "live: port forwarding grants a public port and runs the up-command"
i=0
port=""
while [ "$i" -le 24 ]; do
    port=$(docker exec "$NAME" cat /tmp/warren/forwarded_port 2>/dev/null || true)
    [ -n "$port" ] && break
    i=$((i + 1)); sleep 5
done
if [ -n "$port" ] && [ "$port" -ge 49152 ] && [ "$port" -le 65535 ]; then
    pass "public port granted: $port"
else
    fail "no forwarded port granted"
fi
up_marker=$(docker exec "$NAME" cat /tmp/warren/up_ran 2>/dev/null || true)
if [ -n "$up_marker" ]; then
    pass "up-command ran with port $up_marker"
else
    fail "up-command did not run"
fi

say "live: clean shutdown on docker stop"
if docker stop -t 30 "$NAME" >/dev/null && [ "$(docker inspect -f '{{.State.ExitCode}}' "$NAME")" = "0" ]; then
    pass "clean shutdown"
else
    fail "unclean shutdown (exit $(docker inspect -f '{{.State.ExitCode}}' "$NAME" 2>/dev/null))"
fi

[ "$FAILED" -eq 0 ] && say "all tests green"
exit "$FAILED"
