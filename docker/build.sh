#!/usr/bin/env sh
#
# Build ghcr.io/warrenbrowse/warren-vpn with the daemon version resolved HERE,
# outside the Dockerfile.
#
# Why this script exists: a RUN that asks the GitHub API for "the latest
# release" hides that answer from Docker's cache key. The identical build
# command, run again a month and a daemon release later, reuses the cached
# layer and ships the old daemon, with nothing in the output to tell the two
# runs apart. Resolving the version out here puts it in a build-arg, which is
# part of the cache key; the Dockerfile refuses an unpinned build for the
# same reason.
#
#   ./docker/build.sh                              latest beta release
#   ./docker/build.sh --channel prod               latest prod release
#   ./docker/build.sh --version 1.2.1
#   ./docker/build.sh --local-deb                  from docker/local-debs/
#   ./docker/build.sh -t warren-vpn:test -- --no-cache
#
# Anything after `--` is passed to `docker build` unchanged.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

WARREN_INSTALL_LIB=1
export WARREN_INSTALL_LIB
# The image build sources this file on its own, for warren_local_deb, with the
# installer library already loaded and no repo layout around it.
if ! command -v warren_tag_prefix > /dev/null 2>&1; then
	# shellcheck source=../scripts/install.sh
	. "$REPO_DIR/scripts/install.sh"
fi

# The newest release version of a channel's series, read from a list of tag
# names on stdin. Fails when that series has no release, rather than falling
# back to the other channel's (one image publish carries exactly one channel).
warren_version_from_tags() { # <channel>
	vft_prefix="$(warren_tag_prefix "$1")" || return 1
	vft_tag="$(warren_latest_tag "$vft_prefix")"
	[ -n "$vft_tag" ] || return 1
	printf '%s\n' "${vft_tag#"$vft_prefix"}"
}

# The .deb to unpack when building from a local directory. Refuses to choose:
# two candidates for one architecture means the answer to "which daemon does
# this image ship" is a guess, which is the failure the version pinning above
# exists to prevent.
warren_local_deb() { # <dir> <targetarch>
	wld_matches=""
	wld_count=0
	for wld_deb in "$1"/warren-vpn-daemon*_"$2".deb; do
		[ -f "$wld_deb" ] || continue
		wld_matches="$wld_matches $wld_deb"
		wld_count=$((wld_count + 1))
	done
	if [ "$wld_count" -eq 0 ]; then
		echo "no warren-vpn-daemon*_$2.deb in $1" >&2
		return 1
	fi
	if [ "$wld_count" -gt 1 ]; then
		echo "several .deb match warren-vpn-daemon*_$2.deb in $1:$wld_matches" >&2
		echo "keep exactly one: which daemon this image ships must not be a guess" >&2
		return 1
	fi
	printf '%s\n' "${wld_matches# }"
}

# The arguments handed to `docker build`, in one place so the version can
# never be dropped from them.
warren_build_args() { # <channel> <version> <tag> [local]
	if [ "${4:-}" = "local" ]; then
		printf -- '--build-arg LOCAL_DEB=1 -f docker/Dockerfile -t %s .\n' "$3"
		return 0
	fi
	printf -- '--build-arg WARREN_CHANNEL=%s --build-arg WARREN_DAEMON_VERSION=%s -f docker/Dockerfile -t %s .\n' \
		"$1" "$2" "$3"
}

# What an operator is left with when the releases cannot be listed. There is
# no version to bake into the image then, and the two ways out (pin one, or
# authenticate the read so it stops being rationed) are worth more to them
# than the HTTP status the build died on.
warren_resolve_failure() { # warren_resolve_failure <channel>
	printf 'cannot list the %s daemon releases of %s\n' "$1" "$REPO"
	printf 'pin one with --version <x.y.z>, or set GH_TOKEN or GITHUB_TOKEN to a token that can read that repository (an authenticated gh works too)\n'
}

# Sourced by the unit tests, which want the functions and nothing else.
if [ "${WARREN_BUILD_LIB:-0}" = "1" ]; then
	return 0 2> /dev/null || exit 0
fi

# ---------------------------------------------------------------------------
# Everything below runs only when this file is executed.
# ---------------------------------------------------------------------------

CHANNEL=beta
VERSION=""
TAG=""
LOCAL=""

while [ $# -gt 0 ]; do
	case "$1" in
		--channel) CHANNEL="$2"; shift 2 ;;
		--version) VERSION="$2"; shift 2 ;;
		-t | --tag) TAG="$2"; shift 2 ;;
		--local-deb) LOCAL=local; shift ;;
		--) shift; break ;;
		-h | --help) sed -n '2,20p' "$0"; exit 0 ;;
		*) echo "unknown argument: $1" >&2; exit 1 ;;
	esac
done

warren_tag_prefix "$CHANNEL" > /dev/null || { echo "unknown channel: $CHANNEL" >&2; exit 1; }

if [ -z "$TAG" ]; then
	case "$CHANNEL" in
		beta) TAG="ghcr.io/warrenbrowse/warren-vpn:beta" ;;
		*) TAG="ghcr.io/warrenbrowse/warren-vpn:latest" ;;
	esac
fi

if [ -z "$LOCAL" ] && [ -z "$VERSION" ]; then
	echo "resolving the latest $CHANNEL daemon release"
	TAGS="$(warren_release_tags "$REPO")" \
		|| { warren_resolve_failure "$CHANNEL" >&2; exit 1; }
	VERSION="$(printf '%s\n' "$TAGS" | warren_version_from_tags "$CHANNEL")" \
		|| { echo "no $CHANNEL daemon release found in $REPO" >&2; exit 1; }
fi

if [ -n "$LOCAL" ]; then
	echo "building $TAG from docker/local-debs/"
else
	echo "building $TAG from $CHANNEL daemon $VERSION"
fi

# The build arguments name the Dockerfile and the context relative to the
# repository root, so run from there whatever the caller's cwd is.
cd "$REPO_DIR"
# Word splitting is the interface: warren_build_args prints one argument list,
# and none of its values can contain a space.
# shellcheck disable=SC2046
exec docker build $(warren_build_args "$CHANNEL" "$VERSION" "$TAG" "$LOCAL") "$@"
