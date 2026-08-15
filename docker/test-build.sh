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
	if "$@" > /dev/null 2>&1; then
		printf '  FAIL %s (it succeeded)\n' "$1"
		failures=$((failures + 1))
	else
		printf '  ok   %s\n' "$1"
	fi
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

printf '\n%d checks, %d failure(s)\n' "$checks" "$failures"
[ "$failures" -eq 0 ]
