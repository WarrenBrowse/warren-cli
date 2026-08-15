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
#   WARREN_PORT_HOOK_TIMEOUT                 seconds a hook may run, default 30
#   WARREN_PORT_HOOK_SHUTDOWN_TIMEOUT        same on the stop path, default 5
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

# A knob whose vocabulary is closed: anything else is an operator typo, and a
# typo must stop the container rather than be translated into a working call
# with a different meaning. `WARREN_LOCKDOWN=ON` used to read as "off" and
# egress real traffic with the kill switch down; the CLI refuses "ON", so the
# entrypoint must not turn it into a valid `lockdown-mode set off`.
require_one_of() { # <name> <value> <allowed...>
    ro_name="$1"; ro_value="$2"
    shift 2
    for ro_allowed in "$@"; do
        [ "$ro_value" = "$ro_allowed" ] && return 0
    done
    log "ERROR: $ro_name must be one of: $* (got '$ro_value')"
    return 1
}

# Why the connect failed, from the status `timeout(1)` returned. 124 is the
# one status that means the command was still running when the budget ran
# out; everything else is the CLI refusing in its own time, and calling that a
# timeout sends the operator after a cause that is a minute and a half from
# the truth.
connect_failure() { # <exit status> <timeout seconds>
    case "$1" in
    124) printf 'tunnel did not come up within %ss\n' "$2" ;;
    *) printf 'connect failed (exit %s); see the daemon log above\n' "$1" ;;
    esac
}

# The port watcher runs in a background subshell, so the granted port is
# shared through the status file, never through a shell variable.
granted_port() {
    [ -r "$WARREN_PORT_FORWARD_STATUS_FILE" ] && cat "$WARREN_PORT_FORWARD_STATUS_FILE" || true
}

# Run an operator hook under a hard time bound. A hook that never returns
# would freeze the watcher (it stops consuming status lines, so no later
# grant is ever seen) and, on the stop path, burn the whole container grace
# period before the disconnect runs. The bound is a shell watchdog rather
# than timeout(1) so the same code is exercised by the unit tests on any
# POSIX host; SIGTERM first, SIGKILL five seconds later. Like timeout(1), it
# signals the command it started, not that command's own descendants: what
# is guaranteed is that the watcher (or the stop path) gets control back.
run_port_hook() {
    hook_cmd="$1"; hook_port="$2"; hook_name="$3"
    hook_budget="${4:-${WARREN_PORT_HOOK_TIMEOUT:-30}}"
    [ -n "$hook_cmd" ] || return 0
    resolved=$(printf '%s' "$hook_cmd" | sed "s/{{PORT}}/$hook_port/g")
    hook_marker="${WARREN_HOOK_STATE_DIR:-/tmp}/warren-hook-$hook_name-$$.killed"
    rm -f "$hook_marker"
    log "running port-forward $hook_name command"
    # Own process group where setsid exists (it does in the image), so the
    # kill below reaches what the hook itself started. Signalling only the
    # shell leaves the real work running past its budget: an operator hook is
    # usually a curl or a pipeline, not a single builtin.
    if command -v setsid > /dev/null 2>&1; then
        setsid sh -c "$resolved" &
    else
        sh -c "$resolved" &
    fi
    hook_pid=$!
    # The watchdog writes nothing to the caller's stdout: a background process
    # holding that pipe keeps a command substitution around it waiting, long
    # after the hook it watches is gone.
    (
        hook_left="$hook_budget"
        while [ "$hook_left" -gt 0 ]; do
            kill -0 "$hook_pid" 2>/dev/null || exit 0
            sleep 1
            hook_left=$((hook_left - 1))
        done
        kill -0 "$hook_pid" 2>/dev/null || exit 0
        : > "$hook_marker"
        kill -TERM "-$hook_pid" 2>/dev/null || kill -TERM "$hook_pid" 2>/dev/null
        sleep 5
        kill -KILL "-$hook_pid" 2>/dev/null || kill -KILL "$hook_pid" 2>/dev/null
    ) > /dev/null 2>&1 &
    hook_watchdog=$!
    hook_rc=0
    wait "$hook_pid" 2>/dev/null || hook_rc=$?
    kill "$hook_watchdog" 2>/dev/null || true
    wait "$hook_watchdog" 2>/dev/null || true
    if [ -f "$hook_marker" ]; then
        rm -f "$hook_marker"
        log "WARNING: port-forward $hook_name command timed out after ${hook_budget}s and was killed"
    elif [ "$hook_rc" -ne 0 ]; then
        log "WARNING: port-forward $hook_name command failed (exit $hook_rc)"
    fi
    return 0
}

# The public port granted to OUR rule, or nothing. The daemon prints one
# status line per configured rule, so a line is only ours when its internal
# port is the one this container currently forwards; acting on any MAPPED
# line makes a second rule look like a new grant and flip-flops the status
# file, the hooks and the rule list forever.
mapping_public_port() {
    map_line="$1"; map_internal="$2"
    case "$map_line" in
    *": MAPPED, public port "*) ;;
    *) return 0 ;;
    esac
    [ "${map_line%%/*}" = "$map_internal" ] || return 0
    printf '%s\n' "${map_line##*public port }"
}

# Identities (internal port + CLI protocol name) of the rules the daemon has
# configured, read from `warren port-forward get` on stdin.
parse_forward_rules() {
    while IFS= read -r rule_line; do
        case "$rule_line" in
        *" internal "*" -> external "*) ;;
        *) continue ;;
        esac
        rule_head="${rule_line%% internal *}"
        while [ "${rule_head# }" != "$rule_head" ]; do rule_head="${rule_head# }"; done
        case "${rule_head##*/}" in
        UDP) rule_proto=udp ;;
        TCP) rule_proto=tcp ;;
        TCP+UDP) rule_proto=both ;;
        *) continue ;;
        esac
        printf '%s %s\n' "${rule_head%%/*}" "$rule_proto"
    done
}

# Sourced by the unit tests, which want the functions and nothing else.
if [ "${WARREN_ENTRYPOINT_LIB:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi

# ---------------------------------------------------------------------------
# Everything below runs only when this file is executed.
# ---------------------------------------------------------------------------

MNEMONIC=$(read_secret WARREN_MNEMONIC_FILE WARREN_MNEMONIC)
VOUCHER=$(read_secret WARREN_VOUCHER_FILE WARREN_VOUCHER)
unset WARREN_MNEMONIC WARREN_VOUCHER

ALLOW_INACTIVE="${WARREN_ALLOW_INACTIVE:-off}"
require_one_of WARREN_ALLOW_INACTIVE "$ALLOW_INACTIVE" on off || exit 1
require_one_of WARREN_PORT_FORWARD_MATCH_INTERNAL \
    "${WARREN_PORT_FORWARD_MATCH_INTERNAL:-on}" on off || exit 1
require_one_of WARREN_PORT_FORWARD_PROTOCOL \
    "${WARREN_PORT_FORWARD_PROTOCOL:-both}" tcp udp both || exit 1

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
shutdown() {
    trap '' TERM INT
    log "shutting down"
    last_port=$(granted_port)
    if [ -n "$last_port" ]; then
        # Strictly under the container stop grace period: the disconnect below
        # is what tears the tunnel down cleanly, and it must still get to run.
        run_port_hook "${WARREN_PORT_FORWARD_DOWN_COMMAND:-}" "$last_port" down \
            "${WARREN_PORT_HOOK_SHUTDOWN_TIMEOUT:-5}"
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
elif [ "$ALLOW_INACTIVE" = "on" ]; then
    log "WARNING: subscription not active; continuing (WARREN_ALLOW_INACTIVE=on), traffic will not egress"
else
    fatal "subscription not active: redeem a voucher (WARREN_VOUCHER) or set WARREN_ALLOW_INACTIVE=on"
fi

# ---- settings --------------------------------------------------------------
require_one_of WARREN_LAN "${WARREN_LAN}" allow block || exit 1
warren_cli lan set "${WARREN_LAN}" >/dev/null || fatal "lan set ${WARREN_LAN} failed"

# The operator's own value goes to the CLI, so no typo can ever be read as a
# request to disable the kill switch.
require_one_of WARREN_LOCKDOWN "${WARREN_LOCKDOWN}" on off || exit 1
warren_cli lockdown-mode set "${WARREN_LOCKDOWN}" >/dev/null \
    || fatal "lockdown-mode set ${WARREN_LOCKDOWN} failed"
if [ "${WARREN_LOCKDOWN}" = "on" ]; then
    log "kill switch on (lockdown mode)"
else
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
connect_rc=0
timeout "${WARREN_CONNECT_TIMEOUT}" /usr/bin/warren connect --wait || connect_rc=$?
[ "$connect_rc" -eq 0 ] \
    || fatal "$(connect_failure "$connect_rc" "${WARREN_CONNECT_TIMEOUT}")"
warren_cli status | head -2

# ---- port forwarding -------------------------------------------------------
# The daemon renews the NAT-PMP mapping; the granted public port can change
# across epochs, so a watcher keeps the status file and the up-command in
# sync, gluetun-style (VPN_PORT_FORWARDING_UP_COMMAND equivalent).
if [ -n "${WARREN_PORT_FORWARD_INTERNAL_PORT:-}" ]; then
    # The daemon persists its rules in the settings dir, and `enable
    # --internal-port` upserts rather than replaces, so a rule this container
    # re-pointed in a previous run comes back alongside the configured one.
    # Two rules burn two of the five fleet-wide entitlement slots and make
    # every status update look like a port change. One container forwards one
    # port: start from an empty rule list, always.
    warren_cli port-forward get 2>/dev/null | parse_forward_rules \
        | while read -r stale_internal stale_proto; do
        log "clearing stale forward rule ${stale_internal}/${stale_proto}"
        warren_cli port-forward remove \
            --internal-port "$stale_internal" \
            --protocol "$stale_proto" >/dev/null 2>&1 || true
    done

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
            port=$(mapping_public_port "$line" "$(cat "$INTERNAL_FILE")")
            if [ -n "$port" ]; then
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
            else
                case "$line" in
                *": failed"* | *rate-limited*) log "port-forward status: $line" ;;
                esac
            fi
        done
    }
    port_watcher &
fi

log "up and supervising"
wait "$DAEMON_PID"
rc=$?
log "warren-daemon exited (code $rc)"
exit "$rc"
