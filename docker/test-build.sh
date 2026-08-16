#!/usr/bin/env sh
#
# Unit tests for docker/build.sh, which resolves the daemon version OUTSIDE
# the Dockerfile.
#
# Resolving "the latest release" inside a RUN hides the answer from Docker's
# cache key: the same build command, run again after a daemon release, reuses
# the cached layer and reships the old daemon with nothing in the output to
# say so. The version has to reach the build as a build-arg, which is what
# these assertions pin.
#
#   sh docker/test-build.sh

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

WARREN_BUILD_LIB=1
export WARREN_BUILD_LIB
# shellcheck source=./build.sh
. "$SCRIPT_DIR/build.sh"

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
	description="$1"
	shift
	if "$@" > /dev/null 2>&1; then
		printf '  FAIL %s (it succeeded)\n' "$description"
		failures=$((failures + 1))
	else
		printf '  ok   %s\n' "$description"
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

tags() {
	printf 'daemon-beta-v1.9.1\ndaemon-beta-v1.11.0\ndaemon-v1.2.1\n'
}

echo "version resolution"
check "the newest release of the live series wins" \
	"1.11.0" "$(tags | warren_version_from_tags beta)"
check "the prod series resolves its own newest release" \
	"1.2.1" "$(tags | warren_version_from_tags prod)"
resolve_from() { # resolve_from <channel> <tag list>
	printf '%s\n' "$2" | warren_version_from_tags "$1"
}
check_fails "an empty series resolves to nothing rather than the other one" \
	resolve_from prod "daemon-beta-v1.1.14"
check_fails "an unknown channel has no series" \
	resolve_from staging "daemon-beta-v1.1.14"

echo "build arguments"
# The one property that matters: the resolved version is part of the build
# command, so it is part of Docker's cache key.
check "the resolved version is pinned as a build-arg" \
	"--build-arg WARREN_CHANNEL=beta --build-arg WARREN_DAEMON_VERSION=1.11.0 -f docker/Dockerfile -t warren-vpn:beta ." \
	"$(warren_build_args beta 1.11.0 warren-vpn:beta)"
check "a local .deb build carries no version to resolve" \
	"--build-arg LOCAL_DEB=1 -f docker/Dockerfile -t warren-vpn:test ." \
	"$(warren_build_args beta "" warren-vpn:test local)"


echo "local .deb selection"
# The same invariant as the version pinning above, for the local path: a build
# must never quietly pick which daemon it ships. `ls | head -1` took the
# alphabetically first match, so two versions in docker/local-debs/ reshipped
# the older one with nothing in the output to tell the runs apart.
LOCAL_DIR="$(mktemp -d)"
trap 'rm -rf "$LOCAL_DIR"' EXIT INT TERM
check_fails "an empty directory has nothing to unpack" \
	warren_local_deb "$LOCAL_DIR" arm64
: > "$LOCAL_DIR/warren-vpn-daemon-beta_1.1.15_arm64.deb"
check "the one matching .deb is the one that ships" \
	"$LOCAL_DIR/warren-vpn-daemon-beta_1.1.15_arm64.deb" \
	"$(warren_local_deb "$LOCAL_DIR" arm64)"
check_fails "another architecture is not a match" \
	warren_local_deb "$LOCAL_DIR" amd64
: > "$LOCAL_DIR/warren-vpn-daemon-beta_1.2.0_arm64.deb"
check_fails "two candidates are refused rather than guessed" \
	warren_local_deb "$LOCAL_DIR" arm64
check_contains "and the refusal names them" "1.2.0_arm64.deb" \
	"$(warren_local_deb "$LOCAL_DIR" arm64 2>&1 || true)"

echo "resolving a version against the releases API"
# The documented `./docker/build.sh -t ...` died on an empty version whenever
# the API refused: the read was anonymous, unconditionally, and an anonymous
# read is rationed to 60 requests an hour per source IP (a VPN exit, or an
# office, is one address for all of it). Two agents ended up pinning the
# version by hand. curl and gh are stubbed here, so nothing below touches the
# network.
STUBS="$(mktemp -d)"
trap 'rm -rf "$LOCAL_DIR" "$STUBS"' EXIT INT TERM
cat > "$STUBS/curl" << EOF
#!/bin/sh
[ -f "$STUBS/curl-refuses" ] && exit 22
printf '{"tag_name": "daemon-beta-v1.9.1"}\n{"tag_name": "daemon-beta-v1.11.0"}\n{"tag_name": "daemon-v1.2.1"}\n'
EOF
cat > "$STUBS/gh" << 'EOF'
#!/bin/sh
[ "$1" = auth ] && exit 1
exit 1
EOF
chmod +x "$STUBS/curl" "$STUBS/gh"
PATH="$STUBS:$PATH"

check "the newest release of the channel is what the build pins" \
	"1.11.0" "$(warren_release_tags "$REPO" | warren_version_from_tags beta)"
check "and the other channel resolves its own series" \
	"1.2.1" "$(warren_release_tags "$REPO" | warren_version_from_tags prod)"

: > "$STUBS/curl-refuses"
check_fails "an API that refuses stops the build rather than resolving nothing" \
	warren_release_tags "$REPO"
rm -f "$STUBS/curl-refuses"

# What the operator is left with when it refuses: two agents had to read the
# script to find out that --version exists.
check_contains "the refusal offers the version pin" "--version" \
	"$(warren_resolve_failure beta)"
check_contains "and names the token variable to set" "GH_TOKEN" \
	"$(warren_resolve_failure beta)"
check_contains "and its alternative" "GITHUB_TOKEN" \
	"$(warren_resolve_failure beta)"

printf '\n%d checks, %d failure(s)\n' "$checks" "$failures"
[ "$failures" -eq 0 ]
