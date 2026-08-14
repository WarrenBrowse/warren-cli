#!/bin/sh
# Warren VPN container entrypoint: start the daemon, bring the tunnel up from
# env, then supervise. The container dies when the daemon dies (fail-closed:
# the netns and its firewall die together, nothing can leak past a dead netns).
#
# Env contract (documented in docs/DOCKER.md):
#   WARREN_MNEMONIC / WARREN_MNEMONIC_FILE   recovery phrase (file wins)
#   WARREN_VOUCHER / WARREN_VOUCHER_FILE     optional voucher to redeem
#   WARREN_RELAY_LOCATION                    e.g. "fi" or "fi hel"
#   WARREN_LOCKDOWN=on|off                   kill switch, default on
#   WARREN_LAN=allow|block                   default allow (sidecars need it)
#   WARREN_ALLOW_INACTIVE=on                 keep going without a subscription
#   WARREN_CONNECT_TIMEOUT                   seconds, default 90
#   WARREN_PORT_FORWARD_INTERNAL_PORT        enables NAT-PMP forwarding
#   WARREN_PORT_FORWARD_PROTOCOL             tcp|udp|both, default both
#   WARREN_PORT_FORWARD_EXTERNAL_PORT        suggested public port, default 0
#   WARREN_PORT_FORWARD_LIFETIME             seconds, exit clamps to [60,3600]
#   WARREN_PORT_FORWARD_MATCH_INTERNAL=on|off  default on: after a grant of
#       public port P, re-point the rule to internal P so the app can listen
#       and announce on the same port (what torrent clients need); the
#       up-command tells the app which port that is
#   WARREN_PORT_FORWARD_UP_COMMAND           run on grant, {{PORT}} substituted
#   WARREN_PORT_FORWARD_DOWN_COMMAND         run on shutdown/regrant
#   WARREN_PORT_FORWARD_STATUS_FILE          default /tmp/warren/forwarded_port
set -u

log() { printf '%s [warren] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
fatal() { log "ERROR: $*"; exit 1; }

# Read a secret: the _FILE variant wins, trailing newline stripped, value
# never printed anywhere.
read_secret() {
    file_var="$1"; env_var="$2"
    file_val=$(eval "printf '%s' \"\${$file_var:-}\"")
    if [ -n "$file_val" ]; then
        { [ -f "$file_val" ] && [ -r "$file_val" ]; } || fatal "$file_var must point at a readable file"
        cat "$file_val"
    else
        eval "printf '%s' \"\${$env_var:-}\""
    fi
}

warren_cli() { /usr/bin/warren "$@"; }

MNEMONIC=$(read_secret WARREN_MNEMONIC_FILE WARREN_MNEMONIC)
VOUCHER=$(read_secret WARREN_VOUCHER_FILE WARREN_VOUCHER)
unset WARREN_MNEMONIC WARREN_VOUCHER

command -v nft >/dev/null 2>&1 || fatal "nft missing from the image"
[ -c /dev/net/tun ] || fatal "no /dev/net/tun: run with --device /dev/net/tun (and --cap-add NET_ADMIN)"

mkdir -p "$(dirname "$WARREN_PORT_FORWARD_STATUS_FILE")"

# ---- daemon ----------------------------------------------------------------
# The resource dir is channel-dependent ("Warren VPN" vs "Warren VPN Beta").
# The .deb's own service unit knows it, so read it from there instead of
# hardcoding one channel's path.
if [ -z "${WARREN_RESOURCE_DIR:-}" ]; then
    for unit in /usr/lib/systemd/system/warren-daemon*.service; do
        [ -r "$unit" ] || continue
        WARREN_RESOURCE_DIR=$(sed -n 's/^Environment="WARREN_RESOURCE_DIR=\(.*\)"$/\1/p' "$unit" | head -1)
        [ -n "$WARREN_RESOURCE_DIR" ] && export WARREN_RESOURCE_DIR && break
    done
fi

log "starting warren-daemon"
/usr/bin/warren-daemon -v --disable-stdout-timestamps &
DAEMON_PID=$!

i=0
until warren_cli status >/dev/null 2>&1; do
    i=$((i + 1))
    [ "$i" -le 30 ] || fatal "daemon management socket never came up"
    kill -0 "$DAEMON_PID" 2>/dev/null || fatal "warren-daemon exited during startup"
    sleep 1
done

# ---- shutdown path ---------------------------------------------------------
# The port watcher runs in a background subshell, so the granted port is
# shared through the status file, never through a shell variable.
granted_port() {
    [ -r "$WARREN_PORT_FORWARD_STATUS_FILE" ] && cat "$WARREN_PORT_FORWARD_STATUS_FILE" || true
}

run_port_hook() {
    hook_cmd="$1"; hook_port="$2"; hook_name="$3"
    [ -n "$hook_cmd" ] || return 0
    resolved=$(printf '%s' "$hook_cmd" | sed "s/{{PORT}}/$hook_port/g")
    log "running port-forward $hook_name command"
    if ! sh -c "$resolved"; then
        log "WARNING: port-forward $hook_name command failed"
    fi
}

shutdown() {
    trap '' TERM INT
    log "shutting down"
    last_port=$(granted_port)
    if [ -n "$last_port" ]; then
        run_port_hook "${WARREN_PORT_FORWARD_DOWN_COMMAND:-}" "$last_port" down
    fi
    warren_cli disconnect --wait >/dev/null 2>&1 || true
    kill "$DAEMON_PID" 2>/dev/null || true
    wait "$DAEMON_PID" 2>/dev/null || true
    exit 0
}
trap shutdown TERM INT

# ---- account ---------------------------------------------------------------
if warren_cli account get 2>/dev/null | grep -q '^Address:'; then
    log "already logged in (state volume)"
elif [ -n "$MNEMONIC" ]; then
    log "restoring identity from mnemonic"
    printf '%s\n' "$MNEMONIC" | warren_cli account login >/dev/null \
        || fatal "login failed: the recovery phrase must be 12 or 24 BIP39 words"
else
    fatal "not logged in and no WARREN_MNEMONIC[_FILE] provided"
fi
MNEMONIC=""

if [ -n "$VOUCHER" ]; then
    if warren_cli account redeem "$VOUCHER" >/dev/null 2>&1; then
        log "voucher redeemed"
    else
        log "WARNING: voucher redeem failed (already used, or invalid)"
    fi
    VOUCHER=""
fi

if warren_cli account get 2>/dev/null | grep -q '^Subscription: active'; then
    log "subscription active"
elif [ "${WARREN_ALLOW_INACTIVE:-off}" = "on" ]; then
    log "WARNING: subscription not active; continuing (WARREN_ALLOW_INACTIVE=on), traffic will not egress"
else
    fatal "subscription not active: redeem a voucher (WARREN_VOUCHER) or set WARREN_ALLOW_INACTIVE=on"
fi

# ---- settings --------------------------------------------------------------
warren_cli lan set "${WARREN_LAN}" >/dev/null || fatal "lan set ${WARREN_LAN} failed"

if [ "${WARREN_LOCKDOWN}" = "on" ]; then
    warren_cli lockdown-mode set on >/dev/null || fatal "enabling lockdown mode failed"
    log "kill switch on (lockdown mode)"
else
    warren_cli lockdown-mode set off >/dev/null || true
    log "WARNING: kill switch off (WARREN_LOCKDOWN=off)"
fi

if [ -n "${WARREN_RELAY_LOCATION:-}" ]; then
    # Word splitting is the interface: "fi hel" is two CLI arguments.
    # shellcheck disable=SC2086
    warren_cli relay set location ${WARREN_RELAY_LOCATION} >/dev/null \
        || fatal "relay set location ${WARREN_RELAY_LOCATION} failed"
    log "relay location: ${WARREN_RELAY_LOCATION}"
fi

# ---- connect ---------------------------------------------------------------
log "connecting (timeout ${WARREN_CONNECT_TIMEOUT}s)"
# timeout(1) execs its argument, so it cannot run the warren_cli shell
# function: call the binary directly.
timeout "${WARREN_CONNECT_TIMEOUT}" /usr/bin/warren connect --wait \
    || fatal "tunnel did not come up within ${WARREN_CONNECT_TIMEOUT}s"
warren_cli status | head -2

# ---- port forwarding -------------------------------------------------------
# The daemon renews the NAT-PMP mapping; the granted public port can change
# across epochs, so a watcher keeps the status file and the up-command in
# sync, gluetun-style (VPN_PORT_FORWARDING_UP_COMMAND equivalent).
if [ -n "${WARREN_PORT_FORWARD_INTERNAL_PORT:-}" ]; then
    set -- --internal-port "$WARREN_PORT_FORWARD_INTERNAL_PORT" \
        --protocol "${WARREN_PORT_FORWARD_PROTOCOL:-both}" \
        --external-port "${WARREN_PORT_FORWARD_EXTERNAL_PORT:-0}"
    if [ -n "${WARREN_PORT_FORWARD_LIFETIME:-}" ]; then
        set -- "$@" --lifetime "$WARREN_PORT_FORWARD_LIFETIME"
    fi
    warren_cli port-forward enable "$@" >/dev/null \
        || fatal "enabling port forwarding failed"
    log "port forwarding enabled (internal port ${WARREN_PORT_FORWARD_INTERNAL_PORT})"

    INTERNAL_FILE="${WARREN_PORT_FORWARD_STATUS_FILE}.internal"
    printf '%s\n' "$WARREN_PORT_FORWARD_INTERNAL_PORT" >"$INTERNAL_FILE"

    # After a grant of public port P with a different internal port, replace
    # the rule with internal=P (one slot at a time: remove, then enable) so
    # the app can listen AND announce on P. Skipped when
    # WARREN_PORT_FORWARD_MATCH_INTERNAL=off.
    match_internal() {
        new_port="$1"
        [ "${WARREN_PORT_FORWARD_MATCH_INTERNAL:-on}" = "on" ] || return 0
        current_internal=$(cat "$INTERNAL_FILE")
        [ "$new_port" != "$current_internal" ] || return 0
        log "re-pointing forward rule to internal port $new_port"
        warren_cli port-forward remove \
            --internal-port "$current_internal" \
            --protocol "${WARREN_PORT_FORWARD_PROTOCOL:-both}" >/dev/null 2>&1 || true
        if warren_cli port-forward enable \
            --internal-port "$new_port" \
            --protocol "${WARREN_PORT_FORWARD_PROTOCOL:-both}" \
            --external-port "$new_port" >/dev/null 2>&1; then
            printf '%s\n' "$new_port" >"$INTERNAL_FILE"
        else
            log "WARNING: re-pointing the forward rule failed; keeping internal port $current_internal"
        fi
    }

    port_watcher() {
        warren_cli port-forward status --watch 2>/dev/null | while IFS= read -r line; do
            case "$line" in
            *"MAPPED, public port "*)
                port=${line##*public port }
                previous=$(granted_port)
                if [ "$port" != "$previous" ]; then
                    if [ -n "$previous" ]; then
                        run_port_hook "${WARREN_PORT_FORWARD_DOWN_COMMAND:-}" "$previous" down
                    fi
                    printf '%s\n' "$port" >"${WARREN_PORT_FORWARD_STATUS_FILE}.tmp"
                    mv "${WARREN_PORT_FORWARD_STATUS_FILE}.tmp" "$WARREN_PORT_FORWARD_STATUS_FILE"
                    log "forwarded port granted: $port"
                    run_port_hook "${WARREN_PORT_FORWARD_UP_COMMAND:-}" "$port" up
                    match_internal "$port"
                fi
                ;;
            *": failed"* | *rate-limited*)
                log "port-forward status: $line"
                ;;
            esac
        done
    }
    port_watcher &
fi

log "up and supervising"
wait "$DAEMON_PID"
rc=$?
log "warren-daemon exited (code $rc)"
exit "$rc"
