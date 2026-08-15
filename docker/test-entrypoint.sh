#!/usr/bin/env sh
#
# Unit tests for the container entrypoint's helpers.
#
# The entrypoint is the only thing standing between an operator's env and a
# daemon that must never leak, so the parts that decide something (which
# status line is ours, which rules to clear, how long a hook may run) are
# written as pure functions and pinned here. Nothing below starts a daemon,
# touches the network or needs privileges.
#
#   sh docker/test-entrypoint.sh
#
# Sourcing the entrypoint with WARREN_ENTRYPOINT_LIB=1 loads the functions
# and stops before anything is started.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT INT TERM
WARREN_HOOK_STATE_DIR="$TMP"
export WARREN_HOOK_STATE_DIR
# Set before sourcing: the entrypoint derives the watcher's state-file paths
# from it, and the tests drive that state directly.
WARREN_PORT_FORWARD_STATUS_FILE="$TMP/forwarded_port"
export WARREN_PORT_FORWARD_STATUS_FILE

WARREN_ENTRYPOINT_LIB=1
export WARREN_ENTRYPOINT_LIB
# shellcheck source=./entrypoint.sh
. "$SCRIPT_DIR/entrypoint.sh"

failures=0
checks=0

check() { # check <description> <expected> <actual>
	checks=$((checks + 1))
	if [ "$2" = "$3" ]; then
		printf '  ok   %s\n' "$1"
	else
		printf '  FAIL %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"
		failures=$((failures + 1))
	fi
}

check_contains() { # check_contains <description> <needle> <haystack>
	checks=$((checks + 1))
	case "$3" in
	*"$2"*) printf '  ok   %s\n' "$1" ;;
	*)
		printf '  FAIL %s\n       expected to contain: %s\n       actual: %s\n' "$1" "$2" "$3"
		failures=$((failures + 1))
		;;
	esac
}

check_true() { # check_true <description> <condition...>
	checks=$((checks + 1))
	description="$1"
	shift
	if "$@" > /dev/null 2>&1; then
		printf '  ok   %s\n' "$description"
	else
		printf '  FAIL %s\n' "$description"
		failures=$((failures + 1))
	fi
}

check_fails() { # check_fails <description> <command...>
	checks=$((checks + 1))
	description="$1"
	shift
	if "$@" > /dev/null 2>&1; then
		printf '  FAIL %s (it succeeded)\n' "$description"
		failures=$((failures + 1))
	else
		printf '  ok   %s\n' "$description"
	fi
}

echo "closed-set knobs"
# A mistyped kill switch used to mean "off": the entrypoint compared against
# the exact string "on" and took everything else as a request to disable it,
# so `WARREN_LOCKDOWN=ON` egressed real traffic while the log claimed the
# operator had asked for it. The CLI itself refuses "ON"; so must this.
check_true "a documented value is accepted" require_one_of WARREN_LOCKDOWN on on off
check_fails "a mistyped value is refused" require_one_of WARREN_LOCKDOWN ON on off
check_fails "an empty value is refused" require_one_of WARREN_LOCKDOWN "" on off
out="$(require_one_of WARREN_LOCKDOWN ON on off 2>&1 || true)"
check_contains "the refusal names the knob and the value it was given" \
	"WARREN_LOCKDOWN must be one of: on off (got 'ON')" "$out"
check_true "a knob with its own vocabulary keeps it" require_one_of WARREN_LAN block allow block

echo "connect failures"
# `timeout N warren connect --wait` fails for two very different reasons, and
# reporting both as "did not come up within 90s" sent an operator looking for
# a slow network while the daemon had refused in under a second.
check "a command the timeout had to kill is reported as a timeout" \
	"tunnel did not come up within 90s" \
	"$(connect_failure 124 90)"
check "any other failure is reported with its exit status" \
	"connect failed (exit 1); see the daemon log above" \
	"$(connect_failure 1 90)"

echo "which mapping line is ours"
# The daemon prints one line per configured rule. Acting on any MAPPED line
# makes a second rule look like a new grant for ours, which flip-flops the
# status file and the hooks forever.
check "our own rule's grant is the granted port" \
	"51413" \
	"$(mapping_public_port '6881/TCP+UDP: MAPPED, public port 51413' 6881)"
check "another rule's grant is not ours" \
	"" \
	"$(mapping_public_port '6881/TCP+UDP: MAPPED, public port 51413' 51413)"
check "a rule whose internal port merely shares a prefix is not ours" \
	"" \
	"$(mapping_public_port '68810/TCP+UDP: MAPPED, public port 51413' 6881)"
check "a mapping still being requested grants nothing" \
	"" \
	"$(mapping_public_port '6881/TCP+UDP: requesting...' 6881)"
check "a failed mapping grants nothing" \
	"" \
	"$(mapping_public_port '6881/TCP+UDP: failed (port in use)' 6881)"
check "a MAPPED line carrying no public port grants nothing" \
	"" \
	"$(mapping_public_port '6881/TCP+UDP: MAPPED' 6881)"

# The port is spliced into a sed script and then into `sh -c`, so it must be
# digits before it reaches either: a status line reading `public port 1;id`
# would otherwise run `id` with the hook's privileges, and a value carrying a
# slash would corrupt the substitution.
check "a public port that is not a number grants nothing" \
	"" \
	"$(mapping_public_port '6881/TCP+UDP: MAPPED, public port 1;id' 6881 2>/dev/null)"
check "a public port with a slash in it grants nothing" \
	"" \
	"$(mapping_public_port '6881/TCP+UDP: MAPPED, public port 5/1' 6881 2>/dev/null)"
check_contains "and the refusal is logged" \
	"public port is not a number" \
	"$(mapping_public_port '6881/TCP+UDP: MAPPED, public port 1;id' 6881 2>&1 >/dev/null)"

echo "configured rule identities"
# `enable --internal-port` upserts, and the rules are persisted in the
# settings dir, so a re-pointed rule from a previous run survives a restart
# and coexists with the configured one. Clearing them needs their identity
# back out of the CLI's own listing.
check "every rule is recovered with the CLI's protocol spelling" \
	"6881 both
51413 udp
80 tcp" \
	"$(printf 'Port forwarding: on\nRequested lifetime: 3600s\nRules:\n  6881/TCP+UDP internal 6881 -> external auto\n  51413/UDP internal 51413 -> external 51413\n  80/TCP internal 80 -> external auto\n' | parse_forward_rules)"
check "a listing with no rules yields no identity" \
	"" \
	"$(printf 'Port forwarding: off\nRequested lifetime: 3600s\nRules: none\n' | parse_forward_rules)"

echo "port hooks"
check "an empty hook is a no-op" "" "$(run_port_hook "" 51413 up)"

run_port_hook "printf %s {{PORT}} >$TMP/ran" 51413 up >/dev/null 2>&1
check "the hook runs with {{PORT}} substituted" "51413" "$(cat "$TMP/ran")"

out="$(run_port_hook 'exit 3' 51413 up 2>&1)"
check_contains "a failing hook is reported, not swallowed" "up command failed" "$out"
check_true "a failing hook does not abort the watcher" run_port_hook 'exit 3' 51413 up

# A hook that never returns used to be awaited forever: the watcher stopped
# consuming status lines (no later grant was ever seen) and, on the stop
# path, the whole container grace period was burnt before the disconnect.
# What is bounded is when the CALLER gets control back, so these two go
# through a file: a capture pipe stays open as long as any descendant of the
# hook still holds it, which is a property of the hook, not of the bound.
start="$(date +%s)"
WARREN_PORT_HOOK_TIMEOUT=1 run_port_hook 'sleep 60' 51413 up > "$TMP/up.log" 2>&1
elapsed=$(($(date +%s) - start))
check_contains "a hook that never returns is killed and says so" "timed out" "$(cat "$TMP/up.log")"
check_true "and the caller has control back within the budget" [ "$elapsed" -lt 15 ]

start="$(date +%s)"
run_port_hook 'sleep 60' 51413 down 1 > "$TMP/down.log" 2>&1
elapsed=$(($(date +%s) - start))
check_contains "the shutdown path can ask for a smaller budget" "timed out" "$(cat "$TMP/down.log")"
check_true "which is honoured" [ "$elapsed" -lt 15 ]

# An operator hook is a curl or a pipeline, so the shell that runs it is
# rarely the process doing the work. Where the image can put the hook in its
# own process group, the budget applies to that whole group.
if command -v setsid > /dev/null 2>&1; then
	run_port_hook "sh -c 'sleep 3; printf x >$TMP/orphan' & wait" 51413 up 1 \
		> "$TMP/orphan.log" 2>&1
	sleep 5
	check "what the hook started is killed with it" "" "$(cat "$TMP/orphan" 2>/dev/null || true)"
else
	echo "  skip what the hook started is killed with it (no setsid on this host)"
fi


echo "the port watcher"
# The watcher is the whole feature: it turns a status line into a status file,
# a hook and a re-pointed rule. It drives the CLI through warren_cli, so a
# test can record the calls and replay a status stream in their place.
CALLS="$TMP/cli-calls"
FEED=""
warren_cli() {
	case "$*" in
	"port-forward status --watch") printf '%s' "$FEED" ;;
	*) printf '%s\n' "$*" >> "$CALLS" ;;
	esac
}
# Both hooks append to one file, so their ordering is an assertion.
WARREN_PORT_FORWARD_UP_COMMAND="echo up:{{PORT}} >>$TMP/order"
WARREN_PORT_FORWARD_DOWN_COMMAND="echo down:{{PORT}} >>$TMP/order"
export WARREN_PORT_FORWARD_UP_COMMAND WARREN_PORT_FORWARD_DOWN_COMMAND

watch() { # watch <status line>
	FEED="$1
"
	: > "$CALLS"
	: > "$TMP/order"
	port_watcher > /dev/null 2>&1
}

printf '6881\n' > "$INTERNAL_FILE"
printf '0\n' > "$EXTERNAL_FILE"
rm -f "$WARREN_PORT_FORWARD_STATUS_FILE"

watch '6881/TCP+UDP: MAPPED, public port 51413'
check "a grant lands in the status file" "51413" "$(cat "$WARREN_PORT_FORWARD_STATUS_FILE")"
check "a grant runs the up hook with the granted port" "up:51413" "$(cat "$TMP/order")"
# The application must be able to listen AND announce on one port, so the rule
# is re-pointed to the granted one; one slot at a time, remove before enable.
check "a grant re-points the rule to the granted port" \
	"port-forward remove --internal-port 6881 --protocol both
port-forward enable --internal-port 51413 --protocol both --external-port 51413" \
	"$(cat "$CALLS")"
check "and the watcher tracks the rule it now owns" "51413" "$(cat "$INTERNAL_FILE")"

watch '51413/TCP+UDP: MAPPED, public port 51413'
check "the same port again touches nothing" "" "$(cat "$CALLS")$(cat "$TMP/order")"

watch '51413/TCP+UDP: MAPPED, public port 60000'
check "a new port runs the down hook for the old one before the up hook" \
	"down:51413
up:60000" "$(cat "$TMP/order")"
check "and the new port lands in the status file" "60000" "$(cat "$WARREN_PORT_FORWARD_STATUS_FILE")"

# `enable` upserts, so enabling after a remove that failed leaves the old rule
# beside the new one: two rules, two of the five entitlement slots, and a
# status file that flip-flops between two grants.
warren_cli() {
	case "$*" in
	"port-forward status --watch") printf '%s' "$FEED" ;;
	"port-forward remove"*) printf '%s\n' "$*" >> "$CALLS"; return 1 ;;
	*) printf '%s\n' "$*" >> "$CALLS" ;;
	esac
}
watch '60000/TCP+UDP: MAPPED, public port 49999'
check "a remove that failed does not enable a second rule" \
	"port-forward remove --internal-port 60000 --protocol both" "$(cat "$CALLS")"
check "and the watcher keeps naming the rule it still owns" "60000" "$(cat "$INTERNAL_FILE")"

# The exit can stop announcing our port (a pinned port taken by someone else
# ends `failed` after ten minutes of retries). Nothing used to act on that: the
# hooks stayed silent and the status file kept naming a dead port forever.
check_true "our own rule failing is a lost mapping" \
	mapping_lost '6881/TCP+UDP: failed (port in use)' 6881
check_true "our own rule going disabled is a lost mapping" \
	mapping_lost '6881/TCP+UDP: disabled' 6881
check_fails "another rule failing is not ours" \
	mapping_lost '6881/TCP+UDP: failed (port in use)' 51413
check_fails "a live mapping is not a lost one" \
	mapping_lost '6881/TCP+UDP: MAPPED, public port 51413' 6881

warren_cli() {
	case "$*" in
	"port-forward status --watch") printf '%s' "$FEED" ;;
	*) printf '%s\n' "$*" >> "$CALLS" ;;
	esac
}
printf '60000\n' > "$INTERNAL_FILE"
printf '60000\n' > "$EXTERNAL_FILE"
printf '60000\n' > "$WARREN_PORT_FORWARD_STATUS_FILE"
watch '60000/TCP+UDP: failed (suggested port in use)'
check "a lost mapping tells the application, once" "down:60000" "$(cat "$TMP/order")"
check "and stops naming a port the exit no longer maps" "" "$(cat "$WARREN_PORT_FORWARD_STATUS_FILE")"
# The pin is what failed, so asking for it again would fail the same way: the
# rule goes back to a server pick and the next grant re-points onto it.
check "and asks for a server-picked port instead of the pin that failed" \
	"port-forward enable --internal-port 60000 --protocol both --external-port 0" \
	"$(cat "$CALLS")"
watch '60000/TCP+UDP: failed (suggested port in use)'
check "a repeated failure for the same rule changes nothing more" "" "$(cat "$CALLS")$(cat "$TMP/order")"

printf '\n%d checks, %d failure(s)\n' "$checks" "$failures"
[ "$failures" -eq 0 ]
