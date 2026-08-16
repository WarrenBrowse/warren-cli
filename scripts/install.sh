#!/usr/bin/env sh
#
# Warren headless installer: resolves the right artifact for this machine from
# the warren-cli GitHub releases, verifies it against the release's SHA256SUMS
# and installs it (daemon + CLI, no GUI).
#
#   curl -fsSL https://raw.githubusercontent.com/WarrenBrowse/warren-cli/main/scripts/install.sh | sudo sh
#
# Linux and macOS. On Windows use windows/install-windows.ps1.
#
#   CHANNEL=prod sh install.sh        install from the production series
#   VERSION=1.1.14 sh install.sh      pin a version instead of the newest
#   sh install.sh ./warren-....deb    install a package already downloaded
#   sh install.sh --uninstall         remove an installation made by this script
#
# What it picks, per host:
#
#   Linux, dpkg + apt      .deb        Debian, Ubuntu, Mint, Pop!_OS, ...
#   Linux, rpm             .rpm        Fedora, RHEL, Alma, Rocky, openSUSE, ...
#   Linux, anything else   tarball     Arch, Void, Gentoo, Artix, Slackware, ...
#   macOS                  tarball     universal, Apple Silicon and Intel
#
# The tarball wires up systemd, OpenRC or sysvinit, whichever the host runs.

set -eu

# Where the headless releases live. The pipeline in warren-app publishes them
# to this public distribution repo. Override with REPO=...
REPO="${REPO:-WarrenBrowse/warren-cli}"

err() {
	printf '\033[0;31m[error]\033[0m %s\n' "$*" >&2
	exit 1
}
info() { printf '\033[0;34m[info]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[warn]\033[0m %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# Resolution. No writes, no exits on success, and only warren_release_tags
# talks to the network. scripts/test-install.sh sources this file and asserts
# on them, so a rename of a release artifact is caught here rather than by the
# first user to run the one-liner.
# ---------------------------------------------------------------------------

# Release channel -> the tag prefix of its series on warren-cli.
#
# The two series are independent and never sort together (the shared release
# contract), so each one is resolved on its own prefix.
warren_tag_prefix() { # warren_tag_prefix <prod|beta>
	case "$1" in
		prod) echo "daemon-v" ;;
		beta) echo "daemon-beta-v" ;;
		*) return 1 ;;
	esac
}

# Release channel -> the token every artifact of that channel carries after the
# product name (warren-vpn-daemon-beta_..., warren-headless-beta-...).
warren_env_tag() { # warren_env_tag <prod|beta>
	case "$1" in
		prod) echo "" ;;
		beta) echo "-beta" ;;
		*) return 1 ;;
	esac
}

# `uname -m` -> the spelling this packaging format uses for it. The three
# formats disagree on every 64-bit architecture we ship, which is exactly the
# kind of thing that is wrong until someone runs it on an ARM host.
warren_arch() { # warren_arch <uname -m> <deb|rpm|tar>
	case "$1" in
		x86_64 | amd64)
			case "$2" in
				deb) echo amd64 ;;
				*) echo x86_64 ;;
			esac
			;;
		aarch64 | arm64)
			case "$2" in
				deb) echo arm64 ;;
				*) echo aarch64 ;;
			esac
			;;
		*) return 1 ;;
	esac
}

# The release asset to download, given everything resolved above.
warren_asset() { # warren_asset <os> <format> <version> <channel> <uname -m>
	_os="$1"
	_format="$2"
	_version="$3"
	_env_tag="$(warren_env_tag "$4")" || return 1
	_arch="$(warren_arch "$5" "$_format")" || return 1

	case "$_os:$_format" in
		Linux:deb) echo "warren-vpn-daemon${_env_tag}_${_version}_${_arch}.deb" ;;
		Linux:rpm) echo "warren-vpn-daemon${_env_tag}_${_version}_${_arch}.rpm" ;;
		Linux:tar) echo "warren-headless${_env_tag}-${_version}-linux-${_arch}.tar.gz" ;;
		# One universal bundle covers both Mac architectures, so the arch this
		# host reports never reaches the asset name.
		Darwin:tar) echo "warren-headless${_env_tag}-${_version}-macos-universal.tar.gz" ;;
		*) return 1 ;;
	esac
}

# Newest tag of one series, reading the repo's tags from stdin.
#
# Never the listing order and never a plain `sort`: version tags sort
# LEXICOGRAPHICALLY, where 1.9.1 lands after 1.11.0 and hides the real latest.
# That mistake shipped a version regression once already, which is why the
# prefix is stripped before the sort and put back after.
warren_latest_tag() { # warren_latest_tag <prefix>   (tags on stdin)
	grep "^$1[0-9]" | sed "s|^$1||" | sort -V | tail -n1 | sed "s|^|$1|"
}

# The packaging format to install on this host. PID 1 and the package database
# decide, not the distribution's name.
warren_format() { # warren_format <os>
	case "$1" in
		Darwin) echo tar ;;
		Linux)
			if command -v dpkg > /dev/null 2>&1 && command -v apt-get > /dev/null 2>&1; then
				echo deb
			elif command -v rpm > /dev/null 2>&1; then
				echo rpm
			else
				echo tar
			fi
			;;
		*) return 1 ;;
	esac
}

# Every release tag of the distribution repo, one per line. Shared with
# docker/build.sh, which resolves the daemon version it bakes into an image
# through it, so how a read is authenticated is decided in one place.
#
# An authenticated gh answers first: it also works while the repo, or a
# release in it, is private. Otherwise the API is read with GH_TOKEN or
# GITHUB_TOKEN when one is set, and anonymously when none is. An anonymous
# read is budgeted at 60 requests an hour per source IP, shared by everyone
# behind that address, so a 403 arrives often enough to matter. It fails here,
# so a caller can tell "that channel has no release" from "the API would not
# say", which is the difference between a bad argument and a busy hour.
warren_release_tags() { # warren_release_tags <owner/repo>
	if command -v gh > /dev/null 2>&1 && gh auth status > /dev/null 2>&1; then
		gh release list -R "$1" --limit 100 --json tagName -q '.[].tagName'
		return $?
	fi
	_token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
	# The read and the parse are two steps because curl's status is the one
	# that says the API refused; a pipeline would report sed's instead.
	_releases="$(curl -fsSL ${_token:+-H "Authorization: Bearer $_token"} \
		"https://api.github.com/repos/$1/releases?per_page=100")" || return 1
	printf '%s\n' "$_releases" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p'
}

# Sourced by the test script, which wants the functions and nothing else.
if [ "${WARREN_INSTALL_LIB:-0}" = "1" ]; then
	return 0 2> /dev/null || exit 0
fi

# ---------------------------------------------------------------------------
# Everything below runs only when this file is executed.
# ---------------------------------------------------------------------------

OS="$(uname -s)"
case "$OS" in
	Linux | Darwin) ;;
	*) err "unsupported operating system: $OS. On Windows use windows/install-windows.ps1." ;;
esac

# Beta is the default because it is the only channel that exists: the whole
# live Warren stack is the beta one, and the production API host answers 410
# until the production stack opens. Flip this default in the same change that
# opens it; `CHANNEL=prod` already works.
CHANNEL="${CHANNEL:-beta}"
case "$CHANNEL" in
	prod | beta) ;;
	*) err "CHANNEL must be prod or beta, got: $CHANNEL" ;;
esac

[ "$(id -u)" -eq 0 ] || err "run as root (prefix with sudo)."

FORMAT="$(warren_format "$OS")" || err "cannot determine a packaging format for $OS."

# --- uninstall -------------------------------------------------------------
if [ "${1:-}" = "--uninstall" ]; then
	removed=0
	if [ "$OS" = Darwin ]; then
		[ -x /usr/local/share/warren/uninstall.sh ] \
			&& /usr/local/share/warren/uninstall.sh --uninstall && removed=1
	else
		if command -v dpkg-query > /dev/null 2>&1 \
			&& dpkg-query -W -f='${Status}' warren-vpn-daemon 2> /dev/null | grep -q 'ok installed'; then
			apt-get remove -y warren-vpn-daemon && removed=1
		elif command -v rpm > /dev/null 2>&1 && rpm -q warren-vpn-daemon > /dev/null 2>&1; then
			rpm -e warren-vpn-daemon && removed=1
		elif [ -x "/opt/Warren VPN/uninstall.sh" ]; then
			"/opt/Warren VPN/uninstall.sh" --uninstall && removed=1
		fi
	fi
	[ "$removed" -eq 1 ] || err "no Warren headless installation found."
	exit 0
fi

# --- a package supplied on the command line --------------------------------
if [ "$#" -ge 1 ] && [ -f "$1" ]; then
	PKG_FILE="$1"
	case "$PKG_FILE" in
		*.deb) FORMAT=deb ;;
		*.rpm) FORMAT=rpm ;;
		*.tar.gz) FORMAT=tar ;;
		*) err "unrecognised package: $PKG_FILE (expected .deb, .rpm or .tar.gz)" ;;
	esac
else
	RAW_ARCH="$(uname -m)"
	warren_arch "$RAW_ARCH" "$FORMAT" > /dev/null 2>&1 \
		|| err "unsupported architecture: $RAW_ARCH (Warren ships x86_64 and aarch64)."

	# The download below is authenticated the same way the listing is: an
	# authenticated gh first, a token from the environment otherwise.
	GHTOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
	USE_GH=0
	if command -v gh > /dev/null 2>&1 && gh auth status > /dev/null 2>&1; then USE_GH=1; fi

	PREFIX="$(warren_tag_prefix "$CHANNEL")"

	if [ -n "${VERSION:-}" ]; then
		TAG="${PREFIX}${VERSION#v}"
	else
		info "resolving the latest $CHANNEL headless release..."
		TAGS="$(warren_release_tags "$REPO")" \
			|| err "cannot list the releases of $REPO. Pin one with VERSION=x.y.z, or set GH_TOKEN or GITHUB_TOKEN to a token that can read that repository."
		TAG="$(printf '%s\n' "$TAGS" | warren_latest_tag "$PREFIX")"
	fi
	[ -n "${TAG:-}" ] || err "no published $CHANNEL headless release found on $REPO."

	VER="${TAG#"$PREFIX"}"
	ASSET="$(warren_asset "$OS" "$FORMAT" "$VER" "$CHANNEL" "$RAW_ARCH")" \
		|| err "no artifact for $OS/$FORMAT/$RAW_ARCH."

	WORK="$(mktemp -d)"
	trap 'rm -rf "$WORK"' EXIT
	PKG_FILE="$WORK/$ASSET"

	download() { # download <asset> <destination>
		if [ "$USE_GH" -eq 1 ]; then
			gh release download "$TAG" -R "$REPO" -p "$1" -O "$2"
		else
			curl -fSL ${GHTOKEN:+-H "Authorization: Bearer $GHTOKEN"} \
				"https://github.com/$REPO/releases/download/$TAG/$1" -o "$2"
		fi
	}

	info "downloading $ASSET ($TAG)"
	download "$ASSET" "$PKG_FILE" || err "download failed for $ASSET in $TAG."

	# The artifact is fetched over TLS from GitHub, so the checksum is not the
	# only thing standing between the user and a bad file; it is what catches a
	# truncated download, which otherwise installs as a corrupt package.
	if download SHA256SUMS "$WORK/SHA256SUMS" 2> /dev/null; then
		expected="$(awk -v a="$ASSET" '$2 == a || $2 == "*" a { print $1 }' "$WORK/SHA256SUMS")"
		if [ -n "$expected" ]; then
			if command -v sha256sum > /dev/null 2>&1; then
				actual="$(sha256sum "$PKG_FILE" | awk '{print $1}')"
			elif command -v shasum > /dev/null 2>&1; then
				actual="$(shasum -a 256 "$PKG_FILE" | awk '{print $1}')"
			else
				actual=""
				warn "no sha256sum or shasum on this host; skipping the checksum check."
			fi
			[ -z "$actual" ] || [ "$actual" = "$expected" ] \
				|| err "checksum mismatch for $ASSET (expected $expected, got $actual)."
			[ -z "$actual" ] || info "checksum verified."
		else
			warn "$ASSET is not listed in SHA256SUMS; skipping the checksum check."
		fi
	else
		warn "no SHA256SUMS in $TAG; skipping the checksum check."
	fi
fi

# --- install ---------------------------------------------------------------
info "installing $PKG_FILE"
case "$FORMAT" in
	deb)
		dpkg -i "$PKG_FILE" || apt-get -f install -y
		;;
	rpm)
		rpm -Uvh --replacepkgs "$PKG_FILE" || dnf install -y "$PKG_FILE"
		;;
	tar)
		EXTRACT="$(mktemp -d)"
		tar xzf "$PKG_FILE" -C "$EXTRACT"
		BUNDLE="$(find "$EXTRACT" -maxdepth 1 -mindepth 1 -type d | head -n1)"
		[ -n "$BUNDLE" ] || err "the archive does not contain a bundle directory."
		[ -x "$BUNDLE/install.sh" ] || err "the bundle carries no install.sh."
		( cd "$BUNDLE" && ./install.sh )
		rm -rf "$EXTRACT"
		;;
esac

info "done. Try:  warren account create  &&  warren status"
