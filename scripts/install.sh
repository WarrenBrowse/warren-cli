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

# Where releases are published. Override if artifacts live on warren-app:
#   REPO=WarrenBrowse/warren-app sh install.sh
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

    # --- resolve release tag -------------------------------------------------
    if [ -n "${VERSION:-}" ]; then
        TAG="v${VERSION#v}"
    else
        info "resolving latest release..."
        TAG="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
                 | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n1)"
        [ -n "$TAG" ] || err "no published release yet. Build locally: see docs/INSTALL-SERVER.md (Option B)."
    fi
    VER="${TAG#v}"
    ASSET="warren-vpn-daemon_${VER}_${ARCH}.${PKG}"
    URL="https://github.com/$REPO/releases/download/$TAG/$ASSET"

    PKG_FILE="$(mktemp -d)/$ASSET"
    info "downloading $ASSET ..."
    curl -fSL "$URL" -o "$PKG_FILE" || err "download failed: $URL"
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
