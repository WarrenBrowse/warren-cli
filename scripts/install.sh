#!/usr/bin/env sh
#
# Warren headless installer. Fetches the latest warren-vpn-daemon package for this
# machine from GitHub Releases and installs it (daemon + CLI, no GUI).
#
#   curl -fsSL https://raw.githubusercontent.com/WarrenBrowse/warren-cli/main/scripts/install.sh | sudo sh
#
# A specific version can be forced with:  VERSION=1.2.1 sh install.sh
# A local package can be installed with:  sh install.sh ./warren-vpn-daemon_1.2.1_amd64.deb

set -eu

# Where the headless `daemon-v*` releases live. The CI (in warren-app) publishes
# the artifacts here, to the public-facing distribution repo. Override with REPO=…
REPO="${REPO:-WarrenBrowse/warren-cli}"
err() { printf '\033[0;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[0;34m[info]\033[0m %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || err "run as root (prefix with sudo)."
[ "$(uname -s)" = "Linux" ] || err "this installer targets Linux servers."

# --- pick package manager ----------------------------------------------------
if command -v dpkg >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1; then
    PKG=deb
elif command -v rpm >/dev/null 2>&1; then
    PKG=rpm
else
    err "no supported package manager (need dpkg/apt or rpm)."
fi

# --- install a locally supplied package, if given ----------------------------
if [ "$#" -ge 1 ] && [ -f "$1" ]; then
    PKG_FILE="$1"
else
    # --- map arch ------------------------------------------------------------
    RAW_ARCH="$(uname -m)"
    case "$RAW_ARCH" in
        x86_64|amd64)  DEB_ARCH=amd64;  RPM_ARCH=x86_64 ;;
        aarch64|arm64) DEB_ARCH=arm64;  RPM_ARCH=aarch64 ;;
        riscv64)       DEB_ARCH=riscv64; RPM_ARCH=riscv64 ;;
        *) err "unsupported architecture: $RAW_ARCH" ;;
    esac
    [ "$PKG" = deb ] && ARCH="$DEB_ARCH" || ARCH="$RPM_ARCH"

    # Headless releases are tagged `daemon-v<ver>` (distinct from the GUI `v<ver>`
    # releases that also live on warren-app). While the repo is private, the
    # GitHub CLI (`gh`, authenticated) is the reliable path; for a public repo a
    # token-less curl works too. An optional GH_TOKEN/GITHUB_TOKEN authenticates curl.
    GHTOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
    USE_GH=0
    if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then USE_GH=1; fi

    # --- resolve release tag -------------------------------------------------
    if [ -n "${VERSION:-}" ]; then
        TAG="daemon-v${VERSION#v}"
    elif [ "$USE_GH" -eq 1 ]; then
        info "resolving latest headless release via gh..."
        TAG="$(gh release list -R "$REPO" --limit 100 --json tagName -q '.[].tagName' 2>/dev/null \
                 | grep '^daemon-v' | head -n1)"
    else
        info "resolving latest headless release..."
        TAG="$(curl -fsSL ${GHTOKEN:+-H "Authorization: Bearer $GHTOKEN"} \
                 "https://api.github.com/repos/$REPO/releases?per_page=50" \
                 | sed -n 's/.*"tag_name": *"\(daemon-v[^"]*\)".*/\1/p' | head -n1)"
    fi
    [ -n "$TAG" ] || err "no published headless release found. Build locally: see docs/INSTALL-SERVER.md (Option B)."

    VER="${TAG#daemon-v}"
    ASSET="warren-vpn-daemon_${VER}_${ARCH}.${PKG}"
    PKG_FILE="$(mktemp -d)/$ASSET"
    info "downloading $ASSET ($TAG) ..."
    if [ "$USE_GH" -eq 1 ]; then
        gh release download "$TAG" -R "$REPO" -p "$ASSET" -O "$PKG_FILE" \
            || err "download failed for $ASSET in $TAG"
    else
        URL="https://github.com/$REPO/releases/download/$TAG/$ASSET"
        curl -fSL ${GHTOKEN:+-H "Authorization: Bearer $GHTOKEN"} "$URL" -o "$PKG_FILE" \
            || err "download failed: $URL (private repo? install gh + 'gh auth login', or set GH_TOKEN)"
    fi
fi

# --- install -----------------------------------------------------------------
info "installing $PKG_FILE ..."
if [ "$PKG" = deb ]; then
    dpkg -i "$PKG_FILE" || apt-get -f install -y
else
    rpm -Uvh --replacepkgs "$PKG_FILE" || dnf install -y "$PKG_FILE"
fi

systemctl enable --now warren-daemon 2>/dev/null || true
info "done. Try:  warren account create  &&  warren status"
