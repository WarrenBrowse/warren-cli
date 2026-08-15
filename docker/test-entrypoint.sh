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

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT INT TERM
WARREN_HOOK_STATE_DIR="$TMP"
export WARREN_HOOK_STATE_DIR

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

printf '\n%d checks, %d failure(s)\n' "$checks" "$failures"
[ "$failures" -eq 0 ]
