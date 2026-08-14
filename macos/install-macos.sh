#!/usr/bin/env bash
#
# Install the Warren headless daemon + CLI on macOS from an extracted
# warren-headless-*-macos-universal bundle. Run from inside that directory:
#
#   tar xzf warren-headless-1.1.14-macos-universal.tar.gz
#   cd warren-headless-1.1.14-macos-universal
#   sudo ./install.sh
#
# Uninstall:  sudo ./install.sh --uninstall
#
# The bundle is universal, so the same archive installs on Apple Silicon and
# on Intel.

set -euo pipefail

BIN_DIR="/usr/local/bin"
SHARE_DIR="/usr/local/share/warren"
RES_DIR="$SHARE_DIR/resources"
ZSH_COMPLETION_DIR="/usr/local/share/zsh/site-functions"
FISH_COMPLETION_DIR="/usr/local/share/fish/vendor_completions.d"
BASH_COMPLETION_DIR="/usr/local/etc/bash_completion.d"
PLIST_SRC="com.warren.daemon.plist"
PLIST_DST="/Library/LaunchDaemons/com.warren.daemon.plist"
BINS="warren warren-daemon warren-setup warren-problem-report"

[ "$(id -u)" -eq 0 ] || {
    echo "run with sudo" >&2
    exit 1
}
[ "$(uname -s)" = "Darwin" ] || {
    echo "macOS only" >&2
    exit 1
}

if [ "${1:-}" = "--uninstall" ]; then
    launchctl bootout system "$PLIST_DST" 2> /dev/null || launchctl unload "$PLIST_DST" 2> /dev/null || true
    rm -f "$PLIST_DST"
    for b in $BINS; do rm -f "$BIN_DIR/$b"; done
    rm -f "$ZSH_COMPLETION_DIR/_warren" \
        "$FISH_COMPLETION_DIR/warren.fish" \
        "$BASH_COMPLETION_DIR/warren"
    rm -rf "$SHARE_DIR"
    echo "Warren headless uninstalled. Settings and logs under"
    echo "/Library/Application Support/Warren VPN* and /var/log are left in place."
    exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

[ -f bin/warren-daemon ] || {
    echo "run this from inside the extracted bundle directory" >&2
    exit 1
}

if [ -f BUNDLE-INFO ]; then
    echo "Installing $(sed -n 's/^version=//p' BUNDLE-INFO) (product env: $(sed -n 's/^product_env=//p' BUNDLE-INFO))"
fi

# Replacing the binary under a live daemon leaves a process whose firewall
# state no longer matches anything on disk.
launchctl bootout system "$PLIST_DST" 2> /dev/null || true

echo "Installing binaries to $BIN_DIR ..."
install -d "$BIN_DIR" "$RES_DIR"
for b in $BINS; do install -m 0755 "bin/$b" "$BIN_DIR/$b"; done

echo "Installing resources to $RES_DIR ..."
cp -R resources/. "$RES_DIR/"

echo "Installing shell completions ..."
install -d "$ZSH_COMPLETION_DIR" "$FISH_COMPLETION_DIR" "$BASH_COMPLETION_DIR"
install -m 0644 completions/_warren "$ZSH_COMPLETION_DIR/_warren"
install -m 0644 completions/warren.fish "$FISH_COMPLETION_DIR/warren.fish"
install -m 0644 completions/warren.bash "$BASH_COMPLETION_DIR/warren"

# A tarball install leaves no receipt, so it has to leave the only thing that
# can undo it. scripts/install.sh --uninstall looks here.
install -m 0755 "${BASH_SOURCE[0]}" "$SHARE_DIR/uninstall.sh"

echo "Installing launchd service ..."
install -m 0644 "$PLIST_SRC" "$PLIST_DST"
chown root:wheel "$PLIST_DST"
launchctl bootstrap system "$PLIST_DST" 2> /dev/null || launchctl load "$PLIST_DST"

echo "Done. The daemon is running. Try:"
echo "    warren account create && warren status"
