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

TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT INT TERM

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
	cf_description="$1"
	shift
	if "$@" > /dev/null 2>&1; then
		printf '  FAIL %s (it succeeded)\n' "$cf_description"
		failures=$((failures + 1))
	else
		printf '  ok   %s\n' "$cf_description"
	fi
}

check_succeeds() { # check_succeeds <description> <command...>
	checks=$((checks + 1))
	cs_description="$1"
	shift
	if "$@" > "$TEST_TMP/out" 2>&1; then
		printf '  ok   %s\n' "$cs_description"
	else
		printf '  FAIL %s\n       %s\n' "$cs_description" "$(cat "$TEST_TMP/out")"
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

echo "proof of origin"
# The installer runs as root and SHA256SUMS comes from the same release as the
# package, so only the signature over that list separates "GitHub served these
# files" from "Warren published them". Every way it can be missing, wrong or
# unverifiable must stop the install.
#
# The real pins are swapped for a throwaway key made here, through the library
# mode, which is the only way a pin can be replaced.
POO="$TEST_TMP/origin"
mkdir "$POO"

# The openssl path needs OpenSSL 3. macOS ships LibreSSL without Ed25519, so a
# Homebrew openssl is looked for too.
SIGNER_OPENSSL=""
for candidate in openssl /opt/homebrew/bin/openssl /usr/local/opt/openssl/bin/openssl; do
	if ( PATH="$(dirname "$(command -v "$candidate" || echo /nonexistent)"):$PATH" warren_openssl_ed25519 ); then
		SIGNER_OPENSSL="$(command -v "$candidate")"
		break
	fi
done
if [ -z "$SIGNER_OPENSSL" ] || ! command -v ssh-keygen > /dev/null 2>&1; then
	echo "  FAIL these tests need OpenSSL 3 and ssh-keygen from OpenSSH 8.1" >&2
	exit 1
fi

# The pins as the installer ships them, before any test replaces them. Their
# one canonical form is the hex line of warren-app's
# mullvad-update/warren-trusted-metadata-signing-pubkeys.
RELEASE_KEY_HEX=0f684bb245acd5a684c467ccc9b92bb5daa2252ef12e89a68583b806ea2560a0
SHIPPED_PEM="${WARREN_SIGNING_KEY_PEM:-}"
SHIPPED_SSH="${WARREN_SIGNING_KEY_SSH:-}"
raw_key_of_pem() {
	printf '%s\n' "$1" | "$SIGNER_OPENSSL" pkey -pubin -outform DER 2> /dev/null \
		| tail -c 32 | od -An -tx1 | tr -d ' \n'
}
raw_key_of_ssh() {
	printf '%s' "$1" | awk '{ print $2 }' | "$SIGNER_OPENSSL" base64 -d -A 2> /dev/null \
		| tail -c 32 | od -An -tx1 | tr -d ' \n'
}
check "the PEM pin is the Warren release key" "$RELEASE_KEY_HEX" "$(raw_key_of_pem "$SHIPPED_PEM")"
check "the OpenSSH pin is the same key" "$RELEASE_KEY_HEX" "$(raw_key_of_ssh "$SHIPPED_SSH")"
check "and it is named as an ed25519 key" "ssh-ed25519" "${SHIPPED_SSH%% *}"
check "signatures are bound to the checksum list of a warren-cli release" \
	"warren-cli-sha256sums/1" "${WARREN_SUMS_DOMAIN:-}"

ssh-keygen -q -t ed25519 -N '' -C test -f "$POO/release.key"
ssh-keygen -q -t ed25519 -N '' -C other -f "$POO/other.key"

# Pins an OpenSSH public key in both of the forms the installer carries.
pin_key() { # pin_key <openssh public key file>
	WARREN_SIGNING_KEY_SSH="$(awk '{ print $1, $2 }' "$1")"
	{
		# The DER prefix of an Ed25519 SubjectPublicKeyInfo, then the key.
		printf '\060\052\060\005\006\003\053\145\160\003\041\000'
		awk '{ print $2 }' "$1" | "$SIGNER_OPENSSL" base64 -d -A | tail -c 32
	} > "$POO/spki.der"
	WARREN_SIGNING_KEY_PEM="$("$SIGNER_OPENSSL" pkey -pubin -inform DER -in "$POO/spki.der")"
}
pin_key "$POO/release.key.pub"

sign_ssh() { # sign_ssh <key> <file> <signature out> [namespace]
	cp "$2" "$POO/to-sign"
	rm -f "$POO/to-sign.sig"
	ssh-keygen -q -Y sign -f "$1" -n "${4:-$WARREN_SUMS_DOMAIN}" "$POO/to-sign" > /dev/null 2>&1
	mv "$POO/to-sign.sig" "$3"
}
sha256_of() { # sha256_of <file>
	"$SIGNER_OPENSSL" dgst -sha256 -r "$1" | awk '{ print $1 }'
}
sha256_line() { # sha256_line <file>, as sha256sum writes it
	printf '%s  %s\n' "$(sha256_of "$1")" "$(basename "$1")"
}
set_sums_entry() { # set_sums_entry <dir> <hash>: what the list says the package hashes to
	awk -v a="$ASSET" -v h="$2" '$2 == a { print h "  " a; next } { print }' \
		"$1/SHA256SUMS" > "$POO/sums"
	mv "$POO/sums" "$1/SHA256SUMS"
}

# A release as the pipeline publishes it, rebuilt for every case so a case can
# break it without leaking into the next one.
ASSET=warren-vpn-daemon-beta_1.2.3_amd64.deb
release() { # release <dir>
	rm -rf "$1"
	mkdir "$1"
	printf 'the package\n' > "$1/$ASSET"
	printf 'another platform\n' > "$1/warren-headless-beta-1.2.3-macos-universal.tar.gz"
	{
		sha256_line "$1/$ASSET"
		sha256_line "$1/warren-headless-beta-1.2.3-macos-universal.tar.gz"
	} > "$1/SHA256SUMS"
	sign_ssh "$POO/release.key" "$1/SHA256SUMS" "$1/SHA256SUMS.sshsig"
}
resign() { # resign <dir>, after a case rewrote SHA256SUMS on purpose
	sign_ssh "$POO/release.key" "$1/SHA256SUMS" "$1/SHA256SUMS.sshsig"
}

# The two verifier paths, forced by what PATH offers. A stub stands for a tool
# that is there but cannot do the job: LibreSSL or OpenSSL 1.1.1, an OpenSSH
# older than 8.1.
mkdir "$POO/openssl-ok" "$POO/openssl-none" "$POO/sshsig-none" "$POO/hash-none" \
	"$POO/openssl-yes" "$POO/sshsig-yes" "$POO/sshsig-refuses-release"
ln -s "$SIGNER_OPENSSL" "$POO/openssl-ok/openssl"
printf '#!/bin/sh\necho "Algorithm ed25519 not found" >&2\nexit 1\n' > "$POO/openssl-none/openssl"
printf '#!/bin/sh\necho "unknown option -- Y" >&2\nexit 1\n' > "$POO/sshsig-none/ssh-keygen"
printf '#!/bin/sh\nexit 1\n' > "$POO/hash-none/sha256sum"
printf '#!/bin/sh\nexit 1\n' > "$POO/hash-none/shasum"
# Tools that do everything right except refuse a bad signature: a verifier
# must prove it can say no.
cat > "$POO/openssl-yes/openssl" << EOF
#!/bin/sh
case "\$*" in *"pkeyutl -verify"*) exit 0 ;; esac
exec "$SIGNER_OPENSSL" "\$@"
EOF
cat > "$POO/sshsig-yes/ssh-keygen" << EOF
#!/bin/sh
case "\$*" in *"-Y verify"*) exit 0 ;; esac
exec "$(command -v ssh-keygen)" "\$@"
EOF
# A capable ssh-keygen that refuses every release signature, to tell which
# verifier decided.
cat > "$POO/sshsig-refuses-release/ssh-keygen" << EOF
#!/bin/sh
case "\$*" in *"-I warren-release"*) exit 1 ;; esac
exec "$(command -v ssh-keygen)" "\$@"
EOF
chmod +x "$POO"/*/*
OPENSSL_ONLY="$POO/openssl-ok:$POO/sshsig-none"
SSH_ONLY="$POO/openssl-none"
NEITHER="$POO/openssl-none:$POO/sshsig-none"

verify() { # verify <PATH prefix> <release dir>; the refusal lands in $POO/why
	(
		PATH="$1:$PATH"
		warren_verify_asset "$2" "$ASSET"
	) 2> "$POO/why"
}
REL="$POO/release"

# testdata/signed-sums was made by the release pipeline's own signer
# (warren-app ci/sign-headless-sums.sh) with a fixed test key, and warren-app's
# ci/test-sign-headless-sums.sh pins the same bytes: this is where the two
# repositories agree on the format.
pipeline_fixture_verifies() { # pipeline_fixture_verifies <PATH prefix>
	(
		PATH="$1:$PATH"
		WARREN_SIGNING_KEY_PEM='-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEAyFOtDwzSthmuqSzuxP1Wok1kmdWEznklfkXP2BObYKc=
-----END PUBLIC KEY-----'
		WARREN_SIGNING_KEY_SSH='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMhTrQ8M0rYZrqks7sT9VqJNZJnVhM55JX5Fz9gTm2Cn'
		warren_verify_sums "$SCRIPT_DIR/testdata/signed-sums"
	)
}
check_succeeds "openssl verifies what the release pipeline signs" pipeline_fixture_verifies "$OPENSSL_ONLY"
check_succeeds "so does ssh-keygen" pipeline_fixture_verifies "$SSH_ONLY"

release "$REL"
check_succeeds "openssl verifies a release signed by the pinned key" verify "$OPENSSL_ONLY" "$REL"
check_succeeds "ssh-keygen verifies it where openssl cannot" verify "$SSH_ONLY" "$REL"
check_succeeds "openssl is the verifier whenever it can be" \
	verify "$POO/openssl-ok:$POO/sshsig-refuses-release" "$REL"

release "$REL"
printf 'a package from somewhere else\n' > "$REL/$ASSET"
set_sums_entry "$REL" "$(sha256_of "$REL/$ASSET")"
check_fails "a checksum list rewritten to match another package fails openssl" \
	verify "$OPENSSL_ONLY" "$REL"
check_contains "saying the signature is not the release key's" \
	"not carry a valid signature by the Warren release key" "$(cat "$POO/why")"
check_fails "and fails ssh-keygen" verify "$SSH_ONLY" "$REL"

release "$REL"
rm "$REL/SHA256SUMS.sshsig"
check_fails "a release without its signature is refused" verify "$OPENSSL_ONLY" "$REL"
check_contains "naming the missing file" "no SHA256SUMS.sshsig" "$(cat "$POO/why")"
release "$REL"
rm "$REL/SHA256SUMS"
check_fails "a release without SHA256SUMS is refused" verify "$OPENSSL_ONLY" "$REL"
check_contains "saying so" "no SHA256SUMS" "$(cat "$POO/why")"

release "$REL"
grep -v "$ASSET" "$REL/SHA256SUMS" > "$POO/sums" && mv "$POO/sums" "$REL/SHA256SUMS"
resign "$REL"
check_fails "a package the signed list does not name is refused" verify "$OPENSSL_ONLY" "$REL"
check_contains "saying so" "does not list $ASSET" "$(cat "$POO/why")"
release "$REL"
printf '%s  %s\n' "$(sha256_of "$REL/SHA256SUMS.sshsig")" "$ASSET" >> "$REL/SHA256SUMS"
resign "$REL"
check_fails "and so is one it names twice" verify "$OPENSSL_ONLY" "$REL"

release "$REL"
printf 'truncated' > "$REL/$ASSET"
check_fails "a package that does not match its signed checksum is refused" \
	verify "$OPENSSL_ONLY" "$REL"
check_contains "as a checksum mismatch" "checksum mismatch" "$(cat "$POO/why")"

release "$REL"
pin_key "$POO/other.key.pub"
check_fails "a release signed by another key fails openssl" verify "$OPENSSL_ONLY" "$REL"
check_fails "and fails ssh-keygen" verify "$SSH_ONLY" "$REL"
pin_key "$POO/release.key.pub"

release "$REL"
sign_ssh "$POO/release.key" "$REL/SHA256SUMS" "$REL/SHA256SUMS.sshsig" file
check_fails "the right key signing for another purpose fails openssl" verify "$OPENSSL_ONLY" "$REL"
check_fails "and fails ssh-keygen" verify "$SSH_ONLY" "$REL"

release "$REL"
check_fails "a host with neither verifier refuses to install" verify "$NEITHER" "$REL"
check_contains "and says what to install" "OpenSSH" "$(cat "$POO/why")"
check_fails "an openssl that accepts anything is not a verifier" \
	verify "$POO/openssl-yes:$POO/sshsig-none" "$REL"
check_fails "nor is such an ssh-keygen" verify "$POO/openssl-none:$POO/sshsig-yes" "$REL"

check_fails "a host with no sha256 tool refuses to install" \
	verify "$POO/hash-none:$POO/openssl-none" "$REL"
check_contains "and says so" "no sha256sum, shasum or openssl" "$(cat "$POO/why")"

echo "listing the releases"
# Both the installer and docker/build.sh ask GitHub which releases exist, and
# an anonymous read is rationed to 60 requests an hour per source IP, so it
# answers 403 once that is spent. That has to be a failure with something to
# act on, not an empty listing that reads as "this channel has no release",
# and a token in the environment has to be used when there is one. curl and gh
# are stubbed, so nothing here touches the network.
STUBS="$TEST_TMP/stubs"
mkdir "$STUBS"
cat > "$STUBS/curl" << EOF
#!/bin/sh
printf '%s\n' "\$*" > "$STUBS/curl-args"
: > "$STUBS/curl-config"
case "\$*" in *"-K -"*) cat > "$STUBS/curl-config" ;; esac
[ -f "$STUBS/curl-refuses" ] && exit 22
printf '{"tag_name": "daemon-beta-v1.11.0"}\n{"tag_name": "daemon-v1.2.1"}\n'
EOF
cat > "$STUBS/gh" << EOF
#!/bin/sh
if [ "\$1" = auth ]; then [ -f "$STUBS/gh-authenticated" ]; exit \$?; fi
printf '%s\n' "\$*" > "$STUBS/gh-args"
printf 'daemon-beta-v1.9.1\n'
EOF
chmod +x "$STUBS/curl" "$STUBS/gh"
PATH="$STUBS:$PATH"

tags_with_token() { # tags_with_token <variable> <value>
	( export "$1=$2"; warren_release_tags WarrenBrowse/warren-cli )
}

check "every release tag comes out of the API payload" \
	"daemon-beta-v1.11.0 daemon-v1.2.1" \
	"$(warren_release_tags WarrenBrowse/warren-cli | tr '\n' ' ' | sed 's/ $//')"
check_contains "an anonymous read is what a public repo needs" \
	"api.github.com/repos/WarrenBrowse/warren-cli/releases" "$(cat "$STUBS/curl-args")"
check "and it carries no authorization it does not have" "0" \
	"$(cat "$STUBS/curl-args" "$STUBS/curl-config" | grep -c Authorization || true)"

tags_with_token GH_TOKEN stub-token > /dev/null
check_contains "GH_TOKEN authenticates the read" "Authorization: Bearer stub-token" \
	"$(cat "$STUBS/curl-config")"
# The installer runs as root, and every account on the host can read its
# command lines.
check "without ever appearing on curl's command line" "0" \
	"$(grep -c stub-token "$STUBS/curl-args" || true)"
tags_with_token GITHUB_TOKEN other-stub-token > /dev/null
check_contains "so does GITHUB_TOKEN" "Authorization: Bearer other-stub-token" \
	"$(cat "$STUBS/curl-config")"

: > "$STUBS/curl-refuses"
check_fails "an API that refuses is a failure, not an empty listing" \
	warren_release_tags WarrenBrowse/warren-cli
rm -f "$STUBS/curl-refuses"

: > "$STUBS/gh-authenticated"
check "an authenticated gh answers before the anonymous API, private repo or not" \
	"daemon-beta-v1.9.1" "$(warren_release_tags WarrenBrowse/warren-cli)"
check_contains "asking that repository for its releases" \
	"release list -R WarrenBrowse/warren-cli" "$(cat "$STUBS/gh-args")"
rm -f "$STUBS/gh-authenticated"

printf '\n%d checks, %d failure(s)\n' "$checks" "$failures"
[ "$failures" -eq 0 ]
