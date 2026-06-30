#!/usr/bin/env bash
#
# Install the Warren headless daemon + CLI on macOS from an extracted
# warren-headless-macos-<arch> bundle. Run from inside that directory:
#
#   tar xzf warren-headless-macos-arm64.tar.gz
#   cd warren-headless-macos-arm64
#   sudo ./install-macos.sh
#
# Uninstall:  sudo ./install-macos.sh --uninstall

set -euo pipefail

BIN_DIR="/usr/local/bin"
RES_DIR="/usr/local/share/warren/resources"
PLIST_SRC="com.warren.daemon.plist"
PLIST_DST="/Library/LaunchDaemons/com.warren.daemon.plist"
BINS="warren warren-daemon warren-setup warren-problem-report"

[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }
[ "$(uname -s)" = "Darwin" ] || { echo "macOS only" >&2; exit 1; }

if [ "${1:-}" = "--uninstall" ]; then
    launchctl bootout system "$PLIST_DST" 2>/dev/null || launchctl unload "$PLIST_DST" 2>/dev/null || true
    rm -f "$PLIST_DST"
    for b in $BINS; do rm -f "$BIN_DIR/$b"; done
    rm -rf "$(dirname "$RES_DIR")"
    echo "Warren headless uninstalled."
    exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "Installing binaries to $BIN_DIR ..."
install -d "$BIN_DIR" "$RES_DIR"
for b in $BINS; do install -m 0755 "bin/$b" "$BIN_DIR/$b"; done

echo "Installing resources to $RES_DIR ..."
cp -R resources/. "$RES_DIR/"

echo "Installing launchd service ..."
install -m 0644 "$PLIST_SRC" "$PLIST_DST"
chown root:wheel "$PLIST_DST"
launchctl bootout system "$PLIST_DST" 2>/dev/null || true
launchctl bootstrap system "$PLIST_DST" 2>/dev/null || launchctl load "$PLIST_DST"

echo "Done. The daemon is running. Try:"
echo "    warren account create && warren status"
