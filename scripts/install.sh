#!/usr/bin/env sh
#
# Warren headless installer: resolves the right artifact for this machine from
# the warren-cli GitHub releases, verifies it against the release's signed
# SHA256SUMS and installs it (daemon + CLI, no GUI). It needs OpenSSL 3.0 or
# OpenSSH 8.1 to check the signature, and refuses to install without either.
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

# curl, carrying GH_TOKEN or GITHUB_TOKEN when one is set. The header travels
# on stdin as curl configuration: the installer runs as root, and a command
# line is readable by every account on the host.
warren_curl() { # warren_curl <curl arguments...>
	wc_token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
	if [ -n "$wc_token" ]; then
		printf 'header = "Authorization: Bearer %s"\n' "$wc_token" | curl -K - "$@"
	else
		curl "$@"
	fi
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
	# The read and the parse are two steps because curl's status is the one
	# that says the API refused; a pipeline would report sed's instead.
	_releases="$(warren_curl -fsSL "https://api.github.com/repos/$1/releases?per_page=100")" \
		|| return 1
	printf '%s\n' "$_releases" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p'
}

# ---------------------------------------------------------------------------
# Proof of origin. SHA256SUMS comes from the same release as the package, so on
# its own it only proves the download is whole; anyone able to publish the
# package could publish a matching list. The list is therefore signed with the
# Warren release key (the Ed25519 key that also signs the desktop app's
# updates, kept offline), and nothing installs unless that signature verifies
# against the key pinned below.
#
# The signature is SHA256SUMS.sshsig, an SSH signature (PROTOCOL.sshsig) in
# namespace WARREN_SUMS_DOMAIN, made in the release pipeline by
# `ssh-keygen -Y sign` (warren-app ci/sign-headless-sums.sh). Two stock tools
# can check it, and the first one this host can run is used:
#
#   openssl     3.0 or newer: rebuilds the bytes an SSH signature covers and
#               verifies the Ed25519 signature inside it
#   ssh-keygen  OpenSSH 8.1 or newer: `ssh-keygen -Y verify` (macOS, whose
#               LibreSSL has no Ed25519, and Debian 11 or Ubuntu 20.04, whose
#               OpenSSL 1.1.1 cannot verify a raw Ed25519 message)
#
# The namespace binds the signature to this purpose: the same key's signature
# over anything else (an app update manifest) never passes for a checksum list.
# ---------------------------------------------------------------------------

WARREN_SUMS_DOMAIN='warren-cli-sha256sums/1'
# The same public key twice, in the form each verifier reads. Its canonical
# hex form is the line in warren-app's
# mullvad-update/warren-trusted-metadata-signing-pubkeys; test-install.sh
# asserts both of these decode to it.
WARREN_SIGNING_KEY_PEM='-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEAD2hLskWs1aaExGfMybkrtdqiJS7xLommhYO4BuolYKA=
-----END PUBLIC KEY-----'
WARREN_SIGNING_KEY_SSH='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA9oS7JFrNWmhMRnzMm5K7XaoiUu8S6JpoWDuAbqJWCg'

# True when this host's openssl verifies an Ed25519 signature over a message.
# Probed rather than read off a version string, since LibreSSL answers
# `openssl version` too, and the probe demands a refusal as well as an
# acceptance: a tool that says yes to everything must never become the
# verifier.
warren_openssl_ed25519() {
	command -v openssl > /dev/null 2>&1 || return 1
	woe_dir="$(mktemp -d)" || return 1
	woe_status=1
	if openssl genpkey -algorithm ed25519 -out "$woe_dir/key" > /dev/null 2>&1 \
		&& openssl pkey -in "$woe_dir/key" -pubout -out "$woe_dir/pub" > /dev/null 2>&1 \
		&& printf 'probe' > "$woe_dir/good" \
		&& printf 'probf' > "$woe_dir/bad" \
		&& openssl pkeyutl -sign -inkey "$woe_dir/key" -rawin \
			-in "$woe_dir/good" -out "$woe_dir/sig" > /dev/null 2>&1 \
		&& openssl pkeyutl -verify -pubin -inkey "$woe_dir/pub" -rawin \
			-in "$woe_dir/good" -sigfile "$woe_dir/sig" > /dev/null 2>&1 \
		&& ! openssl pkeyutl -verify -pubin -inkey "$woe_dir/pub" -rawin \
			-in "$woe_dir/bad" -sigfile "$woe_dir/sig" > /dev/null 2>&1; then
		woe_status=0
	fi
	rm -rf "$woe_dir"
	return "$woe_status"
}

# True when this host's ssh-keygen verifies SSH signatures (OpenSSH >= 8.1),
# probed the same way.
warren_sshsig_capable() {
	command -v ssh-keygen > /dev/null 2>&1 || return 1
	wsc_dir="$(mktemp -d)" || return 1
	wsc_status=1
	if ssh-keygen -q -t ed25519 -N '' -C probe -f "$wsc_dir/key" > /dev/null 2>&1 \
		&& printf 'probe' > "$wsc_dir/good" \
		&& ssh-keygen -q -Y sign -f "$wsc_dir/key" -n probe "$wsc_dir/good" > /dev/null 2>&1 \
		&& wsc_pub="$(cat "$wsc_dir/key.pub")" \
		&& printf 'probe %s\n' "$wsc_pub" > "$wsc_dir/signers" \
		&& ssh-keygen -Y verify -f "$wsc_dir/signers" -I probe -n probe \
			-s "$wsc_dir/good.sig" < "$wsc_dir/good" > /dev/null 2>&1 \
		&& ! printf 'probf' | ssh-keygen -Y verify -f "$wsc_dir/signers" -I probe -n probe \
			-s "$wsc_dir/good.sig" > /dev/null 2>&1; then
		wsc_status=0
	fi
	rm -rf "$wsc_dir"
	return "$wsc_status"
}

# Verifies an Ed25519 SSH signature with openssl alone. An SSH signature signs
# "SSHSIG" + namespace + reserved + hash algorithm + H(message), each field a
# length-prefixed string, and ends with the 64 signature bytes. Those bytes are
# checked against a blob rebuilt here from the pinned namespace and the
# message, never read from the signature file, so nothing in the file can
# change what is verified.
warren_openssl_verify_sshsig() { # <message> <sshsig> <public key PEM> <work dir>
	# shellcheck disable=SC2059 # the format is the length byte, in octal
	{
		printf 'SSHSIG\000\000\000'
		printf "\\$(printf '%03o' "${#WARREN_SUMS_DOMAIN}")"
		printf '%s' "$WARREN_SUMS_DOMAIN"
		printf '\000\000\000\000\000\000\000\006sha512\000\000\000\100'
		openssl dgst -sha512 -binary < "$1"
	} > "$4/signed" || return 1
	sed '/^-----/d' "$2" | tr -d '\r\n' | openssl base64 -d -A > "$4/sshsig.bin" || return 1
	tail -c 64 "$4/sshsig.bin" > "$4/signature" || return 1
	openssl pkeyutl -verify -pubin -inkey "$3" -rawin \
		-in "$4/signed" -sigfile "$4/signature" > /dev/null 2>&1
}

# Verifies <dir>/SHA256SUMS against <dir>/SHA256SUMS.sshsig and the pinned key
# with the first verifier this host can run, openssl first. Says why on stderr
# when it refuses.
#
# Every step is checked explicitly rather than left to `set -e`, which a
# caller's `||` switches off inside the function.
warren_verify_sums() { # warren_verify_sums <dir>
	wvs_dir="$1"
	if [ ! -s "$wvs_dir/SHA256SUMS" ]; then
		echo "the release carries no SHA256SUMS" >&2
		return 1
	fi
	if [ ! -s "$wvs_dir/SHA256SUMS.sshsig" ]; then
		echo "the release carries no SHA256SUMS.sshsig, so nothing proves Warren published it" >&2
		return 1
	fi
	if warren_openssl_ed25519; then
		wvs_tool=openssl
	elif warren_sshsig_capable; then
		wvs_tool=ssh-keygen
	else
		echo "this host cannot verify an Ed25519 signature: install OpenSSL 3.0 or newer (package openssl) or OpenSSH 8.1 or newer (package openssh-client), then run this again" >&2
		return 1
	fi
	wvs_tmp="$(mktemp -d)" || return 1
	wvs_status=1
	if [ "$wvs_tool" = openssl ]; then
		if printf '%s\n' "$WARREN_SIGNING_KEY_PEM" > "$wvs_tmp/key.pem" \
			&& warren_openssl_verify_sshsig "$wvs_dir/SHA256SUMS" "$wvs_dir/SHA256SUMS.sshsig" \
				"$wvs_tmp/key.pem" "$wvs_tmp"; then
			wvs_status=0
		fi
	else
		if printf 'warren-release %s\n' "$WARREN_SIGNING_KEY_SSH" > "$wvs_tmp/signers" \
			&& ssh-keygen -Y verify -f "$wvs_tmp/signers" -I warren-release -n "$WARREN_SUMS_DOMAIN" \
				-s "$wvs_dir/SHA256SUMS.sshsig" < "$wvs_dir/SHA256SUMS" > /dev/null 2>&1; then
			wvs_status=0
		fi
	fi
	rm -rf "$wvs_tmp"
	[ "$wvs_status" -eq 0 ] \
		|| echo "SHA256SUMS does not carry a valid signature by the Warren release key (checked with $wvs_tool)" >&2
	return "$wvs_status"
}

# The one sha256 the list gives for <asset>, lowercase. No entry, several, or a
# malformed one is a refusal: the signed list is the statement of what the
# release contains, and a file it does not vouch for exactly once is not in it.
warren_sums_entry() { # warren_sums_entry <SHA256SUMS> <asset>
	wse_hash="$(awk -v a="$2" '$2 == a || $2 == "*" a { print $1 }' "$1")" || return 1
	case "$wse_hash" in
		"" | *[!0-9a-fA-F]*) return 1 ;;
	esac
	[ "${#wse_hash}" -eq 64 ] || return 1
	printf '%s\n' "$wse_hash" | tr 'A-F' 'a-f'
}

# The sha256 of <file>, lowercase, from whichever tool this host has.
warren_sha256() { # warren_sha256 <file>
	for ws_tool in sha256sum "shasum -a 256" "openssl dgst -sha256 -r"; do
		# shellcheck disable=SC2086 # the tool carries its own arguments
		ws_out="$($ws_tool "$1" 2> /dev/null)" || continue
		ws_hash="${ws_out%% *}"
		case "$ws_hash" in
			"" | *[!0-9a-fA-F]*) continue ;;
		esac
		[ "${#ws_hash}" -eq 64 ] || continue
		printf '%s\n' "$ws_hash" | tr 'A-F' 'a-f'
		return 0
	done
	return 1
}

# The whole proof for one downloaded file: <dir> holds <asset> and whatever of
# SHA256SUMS and SHA256SUMS.sshsig the release carried.
warren_verify_asset() { # warren_verify_asset <dir> <asset>
	warren_verify_sums "$1" || return 1
	if ! wva_want="$(warren_sums_entry "$1/SHA256SUMS" "$2")"; then
		echo "the signed SHA256SUMS does not list $2 exactly once" >&2
		return 1
	fi
	if ! wva_got="$(warren_sha256 "$1/$2")"; then
		echo "no sha256sum, shasum or openssl on this host to checksum $2" >&2
		return 1
	fi
	if [ "$wva_got" != "$wva_want" ]; then
		echo "checksum mismatch: $2 is not the file the signed SHA256SUMS lists" >&2
		return 1
	fi
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
# The operator vouches for this file; nothing here can say where it came from.
if [ "$#" -ge 1 ] && [ -f "$1" ]; then
	PKG_FILE="$1"
	case "$PKG_FILE" in
		*.deb) FORMAT=deb ;;
		*.rpm) FORMAT=rpm ;;
		*.tar.gz) FORMAT=tar ;;
		*) err "unrecognised package: $PKG_FILE (expected .deb, .rpm or .tar.gz)" ;;
	esac
	warn "installing $PKG_FILE as given: its origin is not verified."
else
	RAW_ARCH="$(uname -m)"
	warren_arch "$RAW_ARCH" "$FORMAT" > /dev/null 2>&1 \
		|| err "unsupported architecture: $RAW_ARCH (Warren ships x86_64 and aarch64)."

	# The download below is authenticated the same way the listing is: an
	# authenticated gh first, a token from the environment otherwise.
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
			warren_curl -fSL "https://github.com/$REPO/releases/download/$TAG/$1" -o "$2"
		fi
	}

	info "downloading $ASSET ($TAG)"
	download "$ASSET" "$PKG_FILE" || err "download failed for $ASSET in $TAG."

	# A file the release does not carry stays absent, and warren_verify_asset
	# names it when it refuses.
	for proof in SHA256SUMS SHA256SUMS.sshsig; do
		download "$proof" "$WORK/$proof" > /dev/null 2>&1 || rm -f "$WORK/$proof"
	done
	warren_verify_asset "$WORK" "$ASSET" \
		|| err "refusing to install $ASSET from $TAG: nothing proves Warren published it."
	info "signature and checksum verified."
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
