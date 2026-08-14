#!/usr/bin/env sh
#
# Unit tests for the resolution logic of scripts/install.sh.
#
# The installer's job is to name the one artifact that fits the machine in
# front of it. Every part of that name comes from somewhere else (the release
# channel, `uname -m`, the packaging format, the tag series), so the whole
# thing is wrong the moment one of those conventions moves, and the symptom is
# a 404 on someone else's server. These assertions pin the conventions.
#
#   sh scripts/test-install.sh
#
# Sourcing the installer with WARREN_INSTALL_LIB=1 loads the functions and
# stops before anything is downloaded or written.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

WARREN_INSTALL_LIB=1
export WARREN_INSTALL_LIB
# shellcheck source=./install.sh
. "$SCRIPT_DIR/install.sh"

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

check_fails() { # check_fails <description> <command...>
	checks=$((checks + 1))
	if "$@" > /dev/null 2>&1; then
		printf '  FAIL %s (it succeeded)\n' "$1"
		failures=$((failures + 1))
	else
		printf '  ok   %s\n' "$1"
	fi
}

echo "tag series"
check "prod tags carry the bare prefix" \
	"daemon-v" "$(warren_tag_prefix prod)"
check "beta tags carry their own prefix, so the series never mix" \
	"daemon-beta-v" "$(warren_tag_prefix beta)"
check_fails "an unknown channel has no series" warren_tag_prefix staging

echo "artifact environment token"
check "prod artifacts carry no token" "" "$(warren_env_tag prod)"
check "beta artifacts are marked beta" "-beta" "$(warren_env_tag beta)"

echo "architecture spellings"
check "deb calls x86_64 amd64" "amd64" "$(warren_arch x86_64 deb)"
check "rpm calls it x86_64" "x86_64" "$(warren_arch x86_64 rpm)"
check "so does the tarball" "x86_64" "$(warren_arch x86_64 tar)"
check "amd64 is the same machine" "amd64" "$(warren_arch amd64 deb)"
check "deb calls aarch64 arm64" "arm64" "$(warren_arch aarch64 deb)"
check "rpm calls it aarch64" "aarch64" "$(warren_arch aarch64 rpm)"
check "macOS reports arm64 for the same machine" "aarch64" "$(warren_arch arm64 tar)"
check_fails "32-bit ARM is not shipped" warren_arch armv7l deb
check_fails "riscv64 is not shipped" warren_arch riscv64 deb

echo "release assets"
check "beta deb" \
	"warren-vpn-daemon-beta_1.1.14_amd64.deb" \
	"$(warren_asset Linux deb 1.1.14 beta x86_64)"
check "beta rpm on ARM" \
	"warren-vpn-daemon-beta_1.1.14_aarch64.rpm" \
	"$(warren_asset Linux rpm 1.1.14 beta aarch64)"
check "prod deb drops the token" \
	"warren-vpn-daemon_2.0.0_amd64.deb" \
	"$(warren_asset Linux deb 2.0.0 prod x86_64)"
check "generic Linux tarball" \
	"warren-headless-beta-1.1.14-linux-x86_64.tar.gz" \
	"$(warren_asset Linux tar 1.1.14 beta x86_64)"
check "macOS is one universal bundle whatever the host reports" \
	"warren-headless-beta-1.1.14-macos-universal.tar.gz" \
	"$(warren_asset Darwin tar 1.1.14 beta x86_64)"
check "and the same one on Apple Silicon" \
	"warren-headless-beta-1.1.14-macos-universal.tar.gz" \
	"$(warren_asset Darwin tar 1.1.14 beta arm64)"
check_fails "there is no macOS .deb" warren_asset Darwin deb 1.1.14 beta arm64
check_fails "there is no Windows artifact here" warren_asset Windows tar 1.1.14 beta x86_64

echo "newest tag of a series"
# The regression this guards: a lexicographic sort puts 1.9.1 after 1.11.0 and
# would install an older CLI than the one already published.
check "1.11.0 beats 1.9.1, which a lexicographic sort gets backwards" \
	"daemon-beta-v1.11.0" \
	"$(printf 'daemon-beta-v1.9.1\ndaemon-beta-v1.11.0\ndaemon-beta-v1.8.5\n' \
		| warren_latest_tag daemon-beta-v)"
check "the prod prefix never matches a beta tag" \
	"daemon-v1.2.1" \
	"$(printf 'daemon-beta-v1.11.0\ndaemon-v1.2.1\n' | warren_latest_tag daemon-v)"
check "the beta prefix never matches a prod tag" \
	"daemon-beta-v1.1.14" \
	"$(printf 'daemon-beta-v1.1.14\ndaemon-v9.9.9\n' | warren_latest_tag daemon-beta-v)"
check "an empty series resolves to nothing rather than to the other one" \
	"" \
	"$(printf 'daemon-beta-v1.1.14\n' | warren_latest_tag daemon-v)"

printf '\n%d checks, %d failure(s)\n' "$checks" "$failures"
[ "$failures" -eq 0 ]
