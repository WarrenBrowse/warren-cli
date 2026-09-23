#!/usr/bin/env bash
#
# Tests for the macOS headless installer (macos/install-macos.sh): where it
# puts what root runs, and the ownership check that refuses a bundle or a
# destination another account can change. scripts/install.sh carries the same
# check for the uninstaller it runs as root, and both copies go through the
# same battery here.
#
#   bash macos/test-install-macos.sh
#
# Needs no root: the directories stand in for root's own by trusting the
# account running the test, and "another account" is any other uid.

set -uo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WARREN_INSTALL_LIB=1
export WARREN_INSTALL_LIB

failures=0
checks=0
ok() {
	checks=$((checks + 1))
	printf '  ok   %s\n' "$1"
}
fail() {
	checks=$((checks + 1))
	failures=$((failures + 1))
	printf '  FAIL %s\n' "$1"
}
private() { # private <description> <path> [uid]
	if warren_path_is_private "$2" "${3:-$ME}"; then ok "$1"; else fail "$1 (offender: $WARREN_OFFENDER)"; fi
}
refused() { # refused <description> <expected offender> <path> [uid]
	if warren_path_is_private "$3" "${4:-$ME}"; then
		fail "$1 (accepted)"
	elif [ "$WARREN_OFFENDER" != "$2" ]; then
		fail "$1 (offender: $WARREN_OFFENDER, expected $2)"
	else
		ok "$1"
	fi
}

# Run as root, every directory the test makes is root's and passes whatever
# the check does, so they are handed to a stand-in account first.
if [ "$(id -u)" -eq 0 ]; then
	ME=4240
	own() { chown -R "$ME:$ME" "$@"; }
else
	ME="$(id -u)"
	own() { :; }
fi
OTHER=4242
[ "$ME" != "$OTHER" ] || OTHER=4243
TMP="$(mktemp -d)"
TMP="$(cd -P "$TMP" && pwd -P)"
trap 'chmod -R u+rwx "$TMP" 2> /dev/null; rm -rf "$TMP"' EXIT

# The battery every copy of warren_path_is_private goes through.
battery() {
	local t="$TMP/$1"
	mkdir -p "$t"
	chmod 0755 "$t"
	mkdir -m 0755 "$t/private" "$t/loose-parent" "$t/loose-parent/child"
	printf '#!/bin/sh\n' > "$t/private/uninstall.sh"
	chmod 0755 "$t/private/uninstall.sh"
	own "$t"

	private "a directory only root and the trusted account can write is private" "$t/private"
	private "so is a file in it" "$t/private/uninstall.sh"
	refused "a directory another account owns is not" "$t/private" "$t/private" "$OTHER"

	chmod 0775 "$t/private"
	if [ "$(ls -ldn "$t/private" | awk '{ print $4 }')" != 0 ]; then
		refused "a directory its group may write is not" "$t/private" "$t/private"
	fi
	chmod 0757 "$t/private"
	refused "a directory everyone may write is not" "$t/private" "$t/private"
	chmod 1757 "$t/private"
	private "unless the sticky bit keeps others off the entries they do not own" "$t/private"
	chmod 0755 "$t/private"

	chmod 0757 "$t/private/uninstall.sh"
	refused "a file everyone may write is not" "$t/private/uninstall.sh" "$t/private/uninstall.sh"
	chmod 0755 "$t/private/uninstall.sh"

	chmod 0757 "$t/loose-parent"
	refused "every ancestor is judged, not only the directory named" "$t/loose-parent" "$t/loose-parent/child"
	chmod 0755 "$t/loose-parent"

	ln -s "$t/private" "$t/link-to-private"
	private "a symbolic link to a directory is judged by where it leads" "$t/link-to-private"
	chmod 0757 "$t/private"
	refused "and refused for the directory it leads to" "$t/private" "$t/link-to-private"
	chmod 0755 "$t/private"
	ln -s "$t/private/uninstall.sh" "$t/private/link.sh"
	own "$t/private/link.sh"
	refused "a file that is a symbolic link is refused" "$t/private/link.sh" "$t/private/link.sh"
	refused "so is a path that does not exist" "$t/nowhere" "$t/nowhere"

	if [ "$(uname -s)" = Darwin ]; then
		chmod +a "everyone allow add_file" "$t/private"
		refused "an ACL that lets another account write is refused" "$t/private" "$t/private"
		chmod -N "$t/private"
		chmod +a "everyone deny delete" "$t/private"
		private "an ACL that only denies grants nothing" "$t/private"
		chmod -N "$t/private"
	elif command -v setfacl > /dev/null 2>&1 && setfacl -m "u:$OTHER:rwx" "$t/private" 2> /dev/null; then
		refused "an ACL that lets another account write is refused" "$t/private" "$t/private"
		setfacl -b "$t/private"
	else
		echo "  skip the ACL cases: no setfacl on this host"
	fi
}

echo "macos/install-macos.sh"
# shellcheck source=./install-macos.sh
. "$SCRIPT_DIR/install-macos.sh"
set +e
battery install-macos

B="$TMP/bundle"
mkdir -m 0755 "$B" "$B/bin"
printf '#!/bin/sh\n' > "$B/bin/warren-daemon"
chmod 0755 "$B/bin/warren-daemon"
own "$B"
if warren_tree_is_private "$B" "$ME"; then ok "a bundle nobody else can change installs"; else fail "a bundle nobody else can change installs (offender: $WARREN_OFFENDER)"; fi
chmod 0666 "$B/bin/warren-daemon"
if ! warren_tree_is_private "$B" "$ME" && [ "$WARREN_OFFENDER" = "$B/bin/warren-daemon" ]; then
	ok "a bundle holding a file everyone may write is refused, naming the file"
else
	fail "a bundle holding a file everyone may write is refused, naming the file (offender: ${WARREN_OFFENDER:-none})"
fi
chmod 0755 "$B/bin/warren-daemon"
if ! warren_tree_is_private "$B" "$OTHER"; then ok "so is a bundle another account owns"; else fail "so is a bundle another account owns"; fi

# What launchd runs as root, and what it reads, must be what the script
# installs under PREFIX, and PREFIX must be none of Homebrew's.
plist="$SCRIPT_DIR/com.warren.daemon.plist"
program="$(sed -n '/<key>ProgramArguments<\/key>/,/<\/array>/p' "$plist" | sed -n 's|.*<string>\(/[^<]*\)</string>.*|\1|p' | head -n 1)"
resources="$(sed -n '/<key>WARREN_RESOURCE_DIR<\/key>/{n;p;}' "$plist" | sed -n 's|.*<string>\([^<]*\)</string>.*|\1|p')"
[ "$program" = "$BIN_DIR/warren-daemon" ] && ok "launchd runs the daemon the script installs ($program)" \
	|| fail "launchd runs the daemon the script installs (plist: ${program:-none}, script: $BIN_DIR/warren-daemon)"
[ "$resources" = "$RES_DIR" ] && ok "and points it at the resources the script installs" \
	|| fail "and points it at the resources the script installs (plist: ${resources:-none}, script: $RES_DIR)"
case "$PREFIX/" in
	/usr/local/* | /opt/homebrew/*) fail "the prefix is outside Homebrew's (it is $PREFIX)" ;;
	*) ok "the prefix is outside Homebrew's" ;;
esac

# The old layout goes only where it really is: a legacy directory that is a
# symbolic link could send root's rm into the new installation or elsewhere.
L="$TMP/legacy"
mkdir -p "$L/share/warren" "$L/bin" "$L/elsewhere"
printf 'old\n' > "$L/bin/warren-daemon"
printf 'keep\n' > "$L/elsewhere/warren-daemon"
LEGACY_SHARE_DIR="$L/share/warren" LEGACY_BIN_DIR="$L/bin" remove_legacy_layout
if [ ! -e "$L/bin/warren-daemon" ] && [ ! -e "$L/share/warren" ]; then
	ok "the old layout is removed"
else
	fail "the old layout is removed"
fi
mkdir -p "$L/share/warren"
ln -s "$L/elsewhere" "$L/bin-link"
LEGACY_SHARE_DIR="$L/share/warren" LEGACY_BIN_DIR="$L/bin-link" remove_legacy_layout
if [ -e "$L/elsewhere/warren-daemon" ]; then
	ok "but never through a legacy directory that is a symbolic link"
else
	fail "but never through a legacy directory that is a symbolic link"
fi

# Run as root, the installer must resolve nothing through the caller's PATH:
# Homebrew puts directories another account owns in front of it.
if [ "$(head -n 1 "$SCRIPT_DIR/install-macos.sh")" = '#!/bin/bash' ]; then
	ok "the installer names its shell by absolute path"
else
	fail "the installer names its shell by absolute path"
fi
if [ "$(id -u)" -ne 0 ]; then
	mkdir -p "$TMP/planted"
	printf '#!/bin/sh\necho 0\n' > "$TMP/planted/id"
	printf '#!/bin/sh\necho Darwin\n' > "$TMP/planted/uname"
	chmod +x "$TMP/planted/id" "$TMP/planted/uname"
	said="$(env -u WARREN_INSTALL_LIB PATH="$TMP/planted:$PATH" bash "$SCRIPT_DIR/install-macos.sh" 2>&1)"
	case "$said" in
		"run with sudo"*) ok "a planted id on the caller's PATH does not pass for root" ;;
		*) fail "a planted id on the caller's PATH does not pass for root (said: $said)" ;;
	esac
fi

echo "scripts/install.sh"
# shellcheck source=../scripts/install.sh
. "$REPO_DIR/scripts/install.sh"
set +e
battery install-sh
if [ "$(head -n 1 "$REPO_DIR/scripts/install.sh")" = '#!/bin/sh' ]; then
	ok "the installer names its shell by absolute path"
else
	fail "the installer names its shell by absolute path"
fi
if [ "$(uname -s)" = Darwin ] && [ "$(id -u)" -ne 0 ]; then
	said="$(env -u WARREN_INSTALL_LIB PATH="$TMP/planted:$PATH" sh "$REPO_DIR/scripts/install.sh" --uninstall 2>&1)"
	case "$said" in
		*"run as root"*) ok "on macOS, a planted id on the caller's PATH does not pass for root" ;;
		*) fail "on macOS, a planted id on the caller's PATH does not pass for root (said: $said)" ;;
	esac
fi

printf '\n%d checks, %d failure(s)\n' "$checks" "$failures"
[ "$failures" -eq 0 ]
