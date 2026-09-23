#!/bin/bash
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
#
# Everything root runs lives under PREFIX, a directory only root can change.
# /usr/local is out of the question: Homebrew on Intel Macs hands its
# subdirectories to the account that installed it, and a daemon that launchd
# runs as root from there is that account's to replace. The same holds for the
# bundle being installed, so both are checked before anything is copied.

set -euo pipefail

PREFIX="/opt/warren"
BIN_DIR="$PREFIX/bin"
RES_DIR="$PREFIX/resources"
PATHS_FILE="/etc/paths.d/warren"
ZSH_COMPLETION_DIR="/usr/local/share/zsh/site-functions"
FISH_COMPLETION_DIR="/usr/local/share/fish/vendor_completions.d"
BASH_COMPLETION_DIR="/usr/local/etc/bash_completion.d"
PLIST_SRC="com.warren.daemon.plist"
PLIST_DST="/Library/LaunchDaemons/com.warren.daemon.plist"
BINS="warren warren-daemon warren-setup warren-problem-report"
# Where releases before the move installed. Removed, never executed.
LEGACY_BIN_DIR="/usr/local/bin"
LEGACY_SHARE_DIR="/usr/local/share/warren"

# The first path, from <path> up to /, that an account other than root (or
# <uid>, when given) can change, left in WARREN_OFFENDER; true when there is
# none. A path is changeable when another account owns it, when a group other
# than gid 0 may write it, when everyone may write it without the sticky bit
# (which stops an account replacing entries it does not own, as in /tmp), or
# when an ACL grants a write the mode does not show. Directories are judged by
# their real path; a file that is a symbolic link is refused.
warren_path_is_private() { # warren_path_is_private <path> [uid]
    wpp_trusted="${2:-0}"
    WARREN_OFFENDER="$1"
    if [ -d "$1" ]; then
        wpp_path="$(cd -P -- "$1" 2> /dev/null && pwd -P)" || return 1
    else
        [ -e "$1" ] && [ ! -L "$1" ] || return 1
        wpp_path="$(cd -P -- "$(dirname -- "$1")" 2> /dev/null && pwd -P)" || return 1
        wpp_path="${wpp_path%/}/$(basename -- "$1")"
    fi
    while :; do
        WARREN_OFFENDER="$wpp_path"
        wpp_meta="$(ls -ldn -- "$wpp_path" 2> /dev/null)" || return 1
        wpp_mode="$(printf '%s\n' "$wpp_meta" | awk '{ print $1 }')"
        wpp_uid="$(printf '%s\n' "$wpp_meta" | awk '{ print $3 }')"
        wpp_gid="$(printf '%s\n' "$wpp_meta" | awk '{ print $4 }')"
        case "$wpp_uid" in
            0 | "$wpp_trusted") ;;
            *) return 1 ;;
        esac
        case "$wpp_mode" in
            ?????w*) [ "$wpp_gid" = 0 ] || return 1 ;;
        esac
        case "$wpp_mode" in
            ????????w[tT]*) ;;
            ????????w*) return 1 ;;
        esac
        case "$wpp_mode" in
            ??????????+*) return 1 ;;
        esac
        # macOS marks an ACL with a '+' only when no extended attribute takes
        # the '@' slot, so its entries are read instead. A deny entry (the
        # "everyone deny delete" on every home directory) grants nothing.
        if [ "$(uname -s)" = Darwin ]; then
            wpp_acl="$(ls -lnde -- "$wpp_path" 2> /dev/null | sed -n '2,$p')"
            if printf '%s\n' "$wpp_acl" | grep ' allow ' \
                | grep -E 'write|append|add_|delete|chown|security' > /dev/null; then
                return 1
            fi
        fi
        [ "$wpp_path" = / ] && break
        wpp_path="$(dirname -- "$wpp_path")"
    done
    WARREN_OFFENDER=""
    return 0
}

# warren_path_is_private for <dir> and for everything under it, so no file of
# a bundle can be rewritten by another account between extraction and copy.
warren_tree_is_private() { # warren_tree_is_private <dir> [uid]
    warren_path_is_private "$1" "${2:-0}" || return 1
    wtp_loose="$(find "$1" \( -perm -0020 -o -perm -0002 -o ! \( -user 0 -o -user "${2:-0}" \) \) \
        -print 2> /dev/null | head -n 1)"
    if [ -n "$wtp_loose" ]; then
        WARREN_OFFENDER="$wtp_loose"
        return 1
    fi
    return 0
}

# The layout of releases that installed under /usr/local, removed and never
# executed, and only where it really is: a legacy directory another account
# turned into a symbolic link would point root's rm at the new installation.
remove_legacy_layout() {
    [ -d "$LEGACY_SHARE_DIR" ] && [ ! -L "$LEGACY_SHARE_DIR" ] || return 0
    if [ -d "$LEGACY_BIN_DIR" ] && [ ! -L "$LEGACY_BIN_DIR" ]; then
        for b in $BINS; do rm -f "$LEGACY_BIN_DIR/$b"; done
    fi
    rm -rf "$LEGACY_SHARE_DIR"
}

# Sourced by macos/test-install-macos.sh, which wants the definitions only.
if [ "${WARREN_INSTALL_LIB:-0}" = "1" ]; then
    return 0 2> /dev/null || exit 0
fi

# Nothing below is looked up in the caller's PATH: Homebrew puts directories
# another account owns in front of it, and this runs as root.
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

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
    rm -f "$PLIST_DST" "$PATHS_FILE"
    rm -rf "$PREFIX"
    remove_legacy_layout
    rm -f "$ZSH_COMPLETION_DIR/_warren" \
        "$FISH_COMPLETION_DIR/warren.fish" \
        "$BASH_COMPLETION_DIR/warren"
    echo "Warren headless uninstalled. Settings and logs under"
    echo "/Library/Application Support/Warren VPN* and /var/log are left in place."
    exit 0
fi

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
cd "$SCRIPT_DIR"

[ -f bin/warren-daemon ] || {
    echo "run this from inside the extracted bundle directory" >&2
    exit 1
}

# The account that ran sudo may own the bundle it extracted; nobody else may.
if ! warren_tree_is_private "$SCRIPT_DIR" "${SUDO_UID:-0}"; then
    echo "refusing to install from $SCRIPT_DIR: $WARREN_OFFENDER can be changed by another account." >&2
    echo "Extract the bundle in a directory only you and root can write, then run this again." >&2
    exit 1
fi

if [ -f BUNDLE-INFO ]; then
    echo "Installing $(sed -n 's/^version=//p' BUNDLE-INFO) (product env: $(sed -n 's/^product_env=//p' BUNDLE-INFO))"
fi

[ ! -L "$PREFIX" ] || {
    echo "refusing to install: $PREFIX is a symbolic link" >&2
    exit 1
}
install -d -m 0755 -o root -g wheel "$PREFIX" "$BIN_DIR" "$RES_DIR"
if ! warren_path_is_private "$PREFIX"; then
    echo "refusing to install into $PREFIX: $WARREN_OFFENDER can be changed by an account other than root." >&2
    exit 1
fi

# Replacing the binary under a live daemon leaves a process whose firewall
# state no longer matches anything on disk.
launchctl bootout system "$PLIST_DST" 2> /dev/null || true

remove_legacy_layout

echo "Installing binaries to $BIN_DIR ..."
for b in $BINS; do install -m 0755 -o root -g wheel "bin/$b" "$BIN_DIR/$b"; done

echo "Installing resources to $RES_DIR ..."
cp -R resources/. "$RES_DIR/"
chown -R root:wheel "$RES_DIR"
chmod -R go-w "$RES_DIR"

# A tarball install leaves no receipt, so it has to leave the only thing that
# can undo it. scripts/install.sh --uninstall looks here.
install -m 0755 -o root -g wheel "${BASH_SOURCE[0]}" "$PREFIX/uninstall.sh"

# The CLI reaches every login shell's PATH through path_helper.
printf '%s\n' "$BIN_DIR" > "$PATHS_FILE"
chmod 0644 "$PATHS_FILE"

echo "Installing shell completions ..."
install -d "$ZSH_COMPLETION_DIR" "$FISH_COMPLETION_DIR" "$BASH_COMPLETION_DIR"
install -m 0644 completions/_warren "$ZSH_COMPLETION_DIR/_warren"
install -m 0644 completions/warren.fish "$FISH_COMPLETION_DIR/warren.fish"
install -m 0644 completions/warren.bash "$BASH_COMPLETION_DIR/warren"

echo "Installing launchd service ..."
install -m 0644 -o root -g wheel "$PLIST_SRC" "$PLIST_DST"
launchctl bootstrap system "$PLIST_DST" 2> /dev/null || launchctl load "$PLIST_DST"

echo "Done. The daemon is running. Open a new terminal (or use $BIN_DIR/warren), then try:"
echo "    warren account create && warren status"
