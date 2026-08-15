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

echo "which identity is running"
# A state volume wins over WARREN_MNEMONIC: the entrypoint skips the login
# when the volume already holds an identity, so a phrase rotated in the
# compose file changes nothing and the container keeps running as the old
# account. Telling the two apart is a comparison of the phrases themselves,
# in the form the daemon stores them.
check_true "the same phrase written differently is the same identity" \
	same_phrase "Word One  Two" "word one two"
check_fails "a different phrase is a different identity" \
	same_phrase "word one two" "word one three"
check_fails "no stored phrase is not a match" same_phrase "" "word one two"

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

# The wiring, not just the helper: only the kill switch was checked end to end,
# so deleting the WARREN_ALLOW_INACTIVE, WARREN_PORT_FORWARD_MATCH_INTERNAL or
# WARREN_PORT_FORWARD_PROTOCOL line turned nothing red. The supervision knobs
# were read straight from the environment with no check at all, and a
# non-numeric one makes `[ "$x" -ge "$y" ]` an error rather than a false: a
# typo in WARREN_PORT_WATCHER_MAX_RESTARTS removed the give-up path instead of
# moving it, and the watcher restarted forever.
knobs_with() { # knobs_with <name> <value>
	( export "$1=$2"; validate_knobs )
}
check_true "the defaults every container runs with are accepted" validate_knobs
check_fails "a mistyped kill switch is refused before anything starts" \
	knobs_with WARREN_LOCKDOWN ON
check_fails "a mistyped LAN policy is refused" knobs_with WARREN_LAN Allow
check_fails "a mistyped subscription override is refused" \
	knobs_with WARREN_ALLOW_INACTIVE yes
check_fails "a mistyped match-internal is refused" \
	knobs_with WARREN_PORT_FORWARD_MATCH_INTERNAL true
check_fails "a protocol the CLI does not know is refused" \
	knobs_with WARREN_PORT_FORWARD_PROTOCOL sctp
check_fails "a restart budget that is not a number is refused" \
	knobs_with WARREN_PORT_WATCHER_MAX_RESTARTS many
check_fails "a backoff that is not a number is refused" \
	knobs_with WARREN_PORT_WATCHER_BACKOFF 2s
check_fails "a healthy window that is not a number is refused" \
	knobs_with WARREN_PORT_WATCHER_HEALTHY_SECS 1m
check_fails "a hook budget that is not a number is refused" \
	knobs_with WARREN_PORT_HOOK_TIMEOUT 30s
check_fails "a shutdown hook budget that is not a number is refused" \
	knobs_with WARREN_PORT_HOOK_SHUTDOWN_TIMEOUT 5s
out="$(knobs_with WARREN_PORT_WATCHER_MAX_RESTARTS many 2>&1 || true)"
check_contains "and the numeric refusal names the knob and the value" \
	"WARREN_PORT_WATCHER_MAX_RESTARTS must be a whole number (got 'many')" "$out"

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

# A hook child inherits the entrypoint's environment. The phrase itself was
# never exported, but the pointer to it was: WARREN_MNEMONIC_FILE named a file
# the child could read.
WARREN_MNEMONIC=phrase WARREN_MNEMONIC_FILE=/run/secrets/m \
	WARREN_VOUCHER=code WARREN_VOUCHER_FILE=/run/secrets/v
export WARREN_MNEMONIC WARREN_MNEMONIC_FILE WARREN_VOUCHER WARREN_VOUCHER_FILE
strip_secrets_from_environment
run_port_hook "env >$TMP/hookenv" 51413 up > /dev/null 2>&1
check "no secret, and no pointer to one, reaches a hook child" \
	"0" "$(grep -c -E '^WARREN_(MNEMONIC|VOUCHER)' "$TMP/hookenv" || true)"

# One marker path per hook INVOCATION: $$ is the same in every subshell, so
# the watcher's down hook and the shutdown down hook shared a path and could
# each report the other's timeout.
run_port_hook 'true' 51413 down > /dev/null 2>&1
# hook_marker is set by run_port_hook, in this shell.
# shellcheck disable=SC2154
first_marker="$hook_marker"
run_port_hook 'true' 51413 down > /dev/null 2>&1
check "each hook invocation gets its own kill marker" \
	"different" \
	"$([ "$first_marker" != "$hook_marker" ] && echo different || echo shared)"

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
	# The watchdog escalates SIGTERM to SIGKILL five seconds later, but it is
	# reaped the instant the hook LEADER dies, so a descendant that ignores
	# SIGTERM used to outlive the budget with nothing left to kill it.
	run_port_hook "sh -c 'trap \"\" TERM; sleep 4; printf x >$TMP/residual' & wait" \
		51413 up 1 > "$TMP/residual.log" 2>&1
	sleep 6
	check "a descendant that ignores SIGTERM does not outlive the budget" \
		"" "$(cat "$TMP/residual" 2>/dev/null || true)"
else
	echo "  skip what the hook started is killed with it (no setsid on this host)"
	echo "  skip a descendant that ignores SIGTERM does not outlive the budget"
fi


echo "the port watcher"
# The watcher is the whole feature: it turns a status line into a status file,
# a hook and a re-pointed rule. It drives the CLI through warren_cli, so a
# test can record the calls and replay a status stream in their place.
CALLS="$TMP/cli-calls"
FEED=""
# The status stream is a system boundary (a long-lived CLI process), so it is
# the one thing replaced here; every other CLI call is recorded as it is made.
port_forward_stream() { printf '%s' "$FEED"; }
warren_cli() { printf '%s\n' "$*" >> "$CALLS"; }
# Both hooks append to one file, so their ordering is an assertion.
WARREN_PORT_FORWARD_UP_COMMAND="echo up:{{PORT}} >>$TMP/order"
WARREN_PORT_FORWARD_DOWN_COMMAND="echo down:{{PORT}} >>$TMP/order"
export WARREN_PORT_FORWARD_UP_COMMAND WARREN_PORT_FORWARD_DOWN_COMMAND

watch() { # watch <status line>
	FEED="$1
"
	: > "$CALLS"
	: > "$TMP/order"
	port_watcher > "$TMP/watch.log" 2>&1
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

warren_cli() { printf '%s\n' "$*" >> "$CALLS"; }
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

# The daemon can refuse the enable after the remove has already happened, and
# the container then holds no rule at all: one slot, but an empty one, and no
# later status line would ever mention it again.
warren_cli() {
	case "$*" in
	"port-forward enable --internal-port 49999"*) printf '%s\n' "$*" >> "$CALLS"; return 1 ;;
	*) printf '%s\n' "$*" >> "$CALLS" ;;
	esac
}
printf '6881\n' > "$INTERNAL_FILE"
printf '7000\n' > "$EXTERNAL_FILE"
rm -f "$WARREN_PORT_FORWARD_STATUS_FILE"
watch '6881/TCP+UDP: MAPPED, public port 49999'
check "an enable that failed puts the rule it removed back" \
	"port-forward remove --internal-port 6881 --protocol both
port-forward enable --internal-port 49999 --protocol both --external-port 49999
port-forward enable --internal-port 6881 --protocol both --external-port 7000" \
	"$(cat "$CALLS")"
check "and the watcher keeps naming the rule it owns" "6881" "$(cat "$INTERNAL_FILE")"
check_contains "and says so" "restoring internal port 6881" "$(cat "$TMP/watch.log")"

warren_cli() {
	case "$*" in
	"port-forward enable"*) printf '%s\n' "$*" >> "$CALLS"; return 1 ;;
	*) printf '%s\n' "$*" >> "$CALLS" ;;
	esac
}
printf '6881\n' > "$INTERNAL_FILE"
printf '7000\n' > "$EXTERNAL_FILE"
rm -f "$WARREN_PORT_FORWARD_STATUS_FILE"
watch '6881/TCP+UDP: MAPPED, public port 49999'
check_contains "a restore the daemon refuses too is reported" \
	"could not be restored" "$(cat "$TMP/watch.log")"

# Same for the fallback: a re-request the daemon refuses leaves the container
# with no mapping and nothing else would ask again.
printf '6881\n' > "$INTERNAL_FILE"
printf '7000\n' > "$EXTERNAL_FILE"
printf '7000\n' > "$WARREN_PORT_FORWARD_STATUS_FILE"
watch '6881/TCP+UDP: failed (suggested port in use)'
check_contains "a re-request the daemon refuses is reported" \
	"could not re-request a public port" "$(cat "$TMP/watch.log")"

# The pin that gets dropped can be the operator's own
# WARREN_PORT_FORWARD_EXTERNAL_PORT, seeded at boot by the entrypoint, and it
# is dropped for the container's whole life, so the log names the port being
# given up rather than only the rule that keeps going.
warren_cli() { printf '%s\n' "$*" >> "$CALLS"; }
WARREN_PORT_FORWARD_EXTERNAL_PORT=51413
printf '6881\n' > "$INTERNAL_FILE"
printf '%s\n' "$WARREN_PORT_FORWARD_EXTERNAL_PORT" > "$EXTERNAL_FILE"
printf '51413\n' > "$WARREN_PORT_FORWARD_STATUS_FILE"
watch '6881/TCP+UDP: failed (suggested port in use)'
check_contains "the public port the operator asked for is named when it is dropped" \
	"public port 51413 is not available" "$(cat "$TMP/watch.log")"
check "and the rule goes back to a server pick" \
	"port-forward enable --internal-port 6881 --protocol both --external-port 0" \
	"$(cat "$CALLS")"

echo "the watcher stops for good"
# `kill $WATCHER_PID` reached the supervisor only. The status stream and the
# read loop were the two halves of a pipeline, each a process of its own, and a
# background job shares the shell's process group so there was no group to
# signal instead: a grant arriving during the stop ran an up command after the
# down command and rewrote the status file the container was leaving behind.
STREAM="$TMP/stream-in"
rm -f "$STREAM"
mkfifo "$STREAM"
port_forward_stream() { exec cat "$STREAM"; }
warren_cli() { printf '%s\n' "$*" >> "$CALLS"; }
WARREN_PORT_FORWARD_MATCH_INTERNAL=off
export WARREN_PORT_FORWARD_MATCH_INTERNAL
printf '6881\n' > "$INTERNAL_FILE"
printf '0\n' > "$EXTERNAL_FILE"
rm -f "$WARREN_PORT_FORWARD_STATUS_FILE" "$WATCHER_STOPPING_FILE"
: > "$CALLS"
: > "$TMP/order"
supervise_port_watcher > /dev/null 2>&1 &
WATCHER_PID=$!
# Read-write: this never blocks waiting for the watcher to open the fifo, and
# never takes a SIGPIPE once the stream on the other end is killed.
exec 9<> "$STREAM"
printf '6881/TCP+UDP: MAPPED, public port 51413\n' >&9
i=0
while [ ! -s "$WARREN_PORT_FORWARD_STATUS_FILE" ] && [ "$i" -lt 20 ]; do
	sleep 1
	i=$((i + 1))
done
check "a running watcher acts on a grant" "up:51413" "$(cat "$TMP/order")"

stop_port_watcher
: > "$TMP/order"
: > "$CALLS"
printf '6881/TCP+UDP: MAPPED, public port 60000\n' >&9
sleep 2
check "a grant arriving during the stop runs no hook" "" "$(cat "$TMP/order")"
check "and does not rewrite the status file the container is leaving behind" \
	"51413" "$(cat "$WARREN_PORT_FORWARD_STATUS_FILE")"
check "and asks the CLI for nothing more" "" "$(cat "$CALLS")"
exec 9>&-
rm -f "$WATCHER_STOPPING_FILE"
WATCHER_PID=""

echo "the watcher stays up"
# `port-forward status --watch` is a long-lived pipe. When it died the
# container stayed healthy and simply stopped tracking grants: the status file
# froze on a port the exit could reassign at any epoch, and nothing was logged.
TICKS="$TMP/ticks"
: > "$TICKS"
port_watcher() {
	printf 'tick\n' >> "$TICKS"
	# The second run lives long enough to count as healthy, which must clear
	# the restart budget: a container up for weeks is not a flapping watcher.
	# Two seconds against a threshold of two: a run that does nothing can
	# still measure one second by straddling a second boundary.
	[ "$(wc -l < "$TICKS")" -eq 2 ] && sleep 2
	return 0
}
port_watcher_fatal() { printf 'gave up after %s\n' "$1" >> "$TICKS"; }
WARREN_PORT_WATCHER_BACKOFF=0 \
	WARREN_PORT_WATCHER_HEALTHY_SECS=2 \
	WARREN_PORT_WATCHER_MAX_RESTARTS=3 \
	supervise_port_watcher > /dev/null 2>&1 || true
check "a watcher that keeps dying is restarted, then given up on loudly" \
	"tick tick tick tick gave up after 3" \
	"$(tr '\n' ' ' < "$TICKS" | sed 's/ $//')"

echo "the stop path"
# What the stop path guarantees: the down command runs for the port the
# container is giving up, the disconnect that tears the tunnel down runs after
# it and under a hard bound, and a container stopped by its own watcher exits
# non-zero. `timeout` is resolved through PATH, so a stub records the bound and
# the command instead of running the CLI.
STUB_BIN="$TMP/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/timeout" <<EOF
#!/bin/sh
printf '%s\n' "\$*" > "$TMP/disconnect"
printf 'disconnect\n' >> "$TMP/order"
EOF
chmod +x "$STUB_BIN/timeout"
PATH="$STUB_BIN:$PATH"

: > "$TMP/order"
: > "$TMP/disconnect"
rm -f "$WATCHER_FAILED_FILE" "$WATCHER_STOPPING_FILE"
printf '51413\n' > "$WARREN_PORT_FORWARD_STATUS_FILE"
# Both are read by shutdown() and stop_port_watcher(), in the sourced entrypoint.
# shellcheck disable=SC2034
WATCHER_PID=""
# shellcheck disable=SC2034
DAEMON_PID=""
rc=0
( shutdown ) > /dev/null 2>&1 || rc=$?
check "the down command runs for the port being given up, then the disconnect" \
	"down:51413
disconnect" "$(cat "$TMP/order")"
check "and the disconnect is bounded" \
	"10 /usr/bin/warren disconnect --wait" "$(cat "$TMP/disconnect")"
check "a requested stop exits zero" "0" "$rc"

: > "$WATCHER_FAILED_FILE"
rc=0
( shutdown ) > /dev/null 2>&1 || rc=$?
check "a stop the watcher forced exits non-zero" "1" "$rc"
rm -f "$WATCHER_FAILED_FILE" "$WATCHER_STOPPING_FILE"

echo "which identity the state volume holds"
# The stored phrase is the last line of `warren warren mnemonic export`, whose
# producer is warren-app's mullvad-cli `warren::mnemonic_export`: two warning
# lines, a blank one, then the phrase. A hint line appended below it there
# would make every restart with a state volume report a different identity,
# so the format the entrypoint depends on is pinned here too.
cat > "$STUB_BIN/timeout" <<EOF
#!/bin/sh
printf '%s\n' "\$*" > "$TMP/identity-args"
cat "$TMP/identity-out"
EOF
chmod +x "$STUB_BIN/timeout"
printf 'WARNING: anyone with this recovery phrase controls your Warren identity and its subscription.\nWrite it down offline. Never share it or store it in the cloud.\n\nword one two\n' \
	> "$TMP/identity-out"
check "the stored phrase is the last line the CLI prints" "word one two" "$(stored_identity)"
check "and the read is bounded" \
	"10 /usr/bin/warren warren mnemonic export" "$(cat "$TMP/identity-args")"
: > "$TMP/identity-out"
check "a read that produced nothing is not an identity" "" "$(stored_identity)"

printf '\n%d checks, %d failure(s)\n' "$checks" "$failures"
[ "$failures" -eq 0 ]
