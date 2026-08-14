#!/usr/bin/env sh
#
# Install the Warren headless daemon + CLI from an extracted
# warren-headless-*-linux-<arch> bundle, on a distribution the .deb and .rpm do
# not reach: Arch, Void, Gentoo, Artix, Slackware, NixOS outside the flake, and
# any host whose package manager we do not build for.
#
#   tar xzf warren-headless-1.1.14-linux-x86_64.tar.gz
#   cd warren-headless-1.1.14-linux-x86_64
#   sudo ./install.sh
#
# Uninstall:  sudo ./install.sh --uninstall
#
# The installed layout is identical to the .deb, so support instructions, log
# paths and the problem reporter behave the same however Warren was installed.
# The service integration is chosen from the init system actually running:
# systemd, OpenRC and sysvinit are wired up; anything else installs the files
# and prints how to start the daemon.

set -eu

BIN_DIR="/usr/bin"
RES_DIR="/opt/Warren VPN/resources"
SYSTEMD_DIR="/usr/lib/systemd/system"
INITD_DIR="/etc/init.d"
SUPERVISE_DIR="/usr/lib/warren-vpn"
BASH_COMPLETION_DIR="/usr/share/bash-completion/completions"
ZSH_COMPLETION_DIR="/usr/share/zsh/site-functions"
FISH_COMPLETION_DIR="/usr/share/fish/vendor_completions.d"

BINS="warren warren-daemon warren-exclude"
RESOURCE_BINS="warren-setup warren-problem-report"

err() {
	printf '\033[0;31m[error]\033[0m %s\n' "$*" >&2
	exit 1
}
info() { printf '\033[0;34m[info]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[warn]\033[0m %s\n' "$*" >&2; }

[ "$(id -u)" -eq 0 ] || err "run as root (prefix with sudo)."
[ "$(uname -s)" = "Linux" ] || err "this installer targets Linux."

# Which supervisor actually runs on this host. PID 1 is the authority: several
# distributions ship the systemctl binary on a host booted with something else,
# and a package that trusts `command -v systemctl` writes units nothing reads.
detect_init() {
	if [ -d /run/systemd/system ]; then
		echo systemd
	elif [ -d /run/openrc ] || { [ -x /sbin/openrc-run ] && command -v rc-update > /dev/null 2>&1; }; then
		echo openrc
	elif [ -d "$INITD_DIR" ] && command -v start-stop-daemon > /dev/null 2>&1; then
		echo sysvinit
	else
		echo unknown
	fi
}

INIT="$(detect_init)"

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--uninstall" ]; then
	case "$INIT" in
		systemd)
			systemctl disable --now warren-daemon.service 2> /dev/null || true
			systemctl disable warren-early-boot-blocking.service 2> /dev/null || true
			rm -f "$SYSTEMD_DIR/warren-daemon.service" \
				"$SYSTEMD_DIR/warren-early-boot-blocking.service"
			systemctl daemon-reload 2> /dev/null || true
			;;
		openrc)
			rc-service warren-daemon stop 2> /dev/null || true
			rc-update del warren-daemon default 2> /dev/null || true
			rm -f "$INITD_DIR/warren-daemon"
			;;
		sysvinit)
			"$INITD_DIR/warren-daemon" stop 2> /dev/null || true
			if command -v update-rc.d > /dev/null 2>&1; then
				update-rc.d -f warren-daemon remove 2> /dev/null || true
				update-rc.d -f warren-early-boot-blocking remove 2> /dev/null || true
			fi
			rm -f "$INITD_DIR/warren-daemon" "$INITD_DIR/warren-early-boot-blocking"
			rm -rf "$SUPERVISE_DIR"
			;;
		*)
			warn "no known init system; stop warren-daemon yourself if it is running."
			;;
	esac

	for b in $BINS; do rm -f "$BIN_DIR/$b"; done
	rm -f "$BIN_DIR/warren-problem-report"
	rm -rf "$(dirname "$RES_DIR")"
	rm -f "$BASH_COMPLETION_DIR/warren" \
		"$ZSH_COMPLETION_DIR/_warren" \
		"$FISH_COMPLETION_DIR/warren.fish"
	info "Warren headless uninstalled. Settings and logs under /etc/warren-vpn*,"
	info "/var/log/warren-vpn* and /var/cache/warren-vpn* are left in place."
	exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

[ -f bin/warren-daemon ] || err "run this from inside the extracted bundle directory."

# ---------------------------------------------------------------------------
# Refuse the situations that install cleanly and then fail
# ---------------------------------------------------------------------------

# Shared libraries the daemon needs that this host does not have.
#
# `ldd` prints one line per dependency and marks an unresolved one "not found".
# Reading it back is the only check that stays correct as the dependency set
# changes, which a hardcoded list would not.
warren_missing_libs() { # warren_missing_libs   (ldd output on stdin)
	awk '/not found/ { print $1 }'
}
if [ -n "$(find /lib /lib64 -maxdepth 1 -name 'ld-musl-*' -print -quit 2> /dev/null)" ] \
	&& [ ! -e /lib64/ld-linux-x86-64.so.2 ] && [ ! -e /lib/ld-linux-aarch64.so.1 ]; then
	err "this host uses musl (Alpine and derivatives); the Warren binaries are built
       against glibc and cannot run here. Install gcompat at your own risk, or
       run Warren in a glibc container."
fi

# A tarball resolves no dependencies, unlike the .deb and the .rpm, whose
# package managers refuse an install whose Depends are unmet. Without this the
# files land, the service is wired up, and the daemon dies at load with
# "libdbus-1.so.3: cannot open shared object file", which names neither Warren
# nor the package to install. The distributions this tarball targets are exactly
# the ones where a minimal server install has no dbus.
if command -v ldd > /dev/null 2>&1; then
	MISSING="$(ldd bin/warren-daemon 2> /dev/null | warren_missing_libs)"
	if [ -n "$MISSING" ]; then
		printf '\033[0;31m[error]\033[0m the daemon needs shared libraries this host does not have:\n' >&2
		for lib in $MISSING; do printf '         %s\n' "$lib" >&2; done
		printf '       Install them, then run this script again. libdbus-1.so.3 comes from:\n' >&2
		printf '         Arch/Artix   pacman -S dbus\n' >&2
		printf '         Void         xbps-install -S dbus\n' >&2
		printf '         Gentoo       emerge sys-apps/dbus\n' >&2
		printf '         Slackware    the dbus package of your release\n' >&2
		printf '       Nothing has been installed.\n' >&2
		exit 1
	fi
else
	warn "no ldd on this host; cannot check the daemon's shared libraries. If it
       fails to start, look for a 'cannot open shared object file' error."
fi

# A package-managed install owns the same paths. Overwriting them from a
# tarball leaves the package manager convinced its own files are intact.
if command -v dpkg-query > /dev/null 2>&1 \
	&& dpkg-query -W -f='${Status}' warren-vpn-daemon 2> /dev/null | grep -q '^install ok installed'; then
	err "the warren-vpn-daemon package is already installed; remove it first
       (apt-get remove warren-vpn-daemon) or update it with the .deb instead."
fi
if command -v rpm > /dev/null 2>&1 && rpm -q warren-vpn-daemon > /dev/null 2>&1; then
	err "the warren-vpn-daemon package is already installed; remove it first
       (rpm -e warren-vpn-daemon) or update it with the .rpm instead."
fi

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------
if [ -f BUNDLE-INFO ]; then
	info "installing $(sed -n 's/^version=//p' BUNDLE-INFO) (product env: $(sed -n 's/^product_env=//p' BUNDLE-INFO))"
fi

# Stop a running daemon before its binary is replaced: an in-place overwrite of
# a live daemon is how you get a process whose firewall state no longer matches
# any binary on disk.
case "$INIT" in
	systemd) systemctl stop warren-daemon.service 2> /dev/null || true ;;
	openrc) rc-service warren-daemon stop 2> /dev/null || true ;;
	sysvinit) [ -x "$INITD_DIR/warren-daemon" ] && "$INITD_DIR/warren-daemon" stop 2> /dev/null || true ;;
esac

info "installing binaries to $BIN_DIR"
install -d "$BIN_DIR" "$RES_DIR"
for b in $BINS; do install -m 0755 "bin/$b" "$BIN_DIR/$b"; done
# Split-tunnel helper: it re-executes a command outside the tunnel, which needs
# the daemon's privileges. Same setuid bit the .deb's postinst sets.
chmod u+s "$BIN_DIR/warren-exclude"

info "installing resources to $RES_DIR"
for b in $RESOURCE_BINS; do install -m 0755 "resources/$b" "$RES_DIR/$b"; done
for f in ca.crt relays.json warren-relays.json CHANGELOG.md; do
	[ -f "resources/$f" ] && install -m 0644 "resources/$f" "$RES_DIR/$f"
done
ln -sf "$RES_DIR/warren-problem-report" "$BIN_DIR/warren-problem-report"

# A tarball install leaves no package database entry, so it has to leave the
# only thing that can undo it. scripts/install.sh --uninstall looks here.
install -m 0755 "$0" "$(dirname "$RES_DIR")/uninstall.sh"

info "installing shell completions"
install -d "$BASH_COMPLETION_DIR" "$ZSH_COMPLETION_DIR" "$FISH_COMPLETION_DIR"
install -m 0644 completions/warren.bash "$BASH_COMPLETION_DIR/warren"
install -m 0644 completions/_warren "$ZSH_COMPLETION_DIR/_warren"
install -m 0644 completions/warren.fish "$FISH_COMPLETION_DIR/warren.fish"

case "$INIT" in
	systemd)
		info "wiring the systemd units"
		install -d "$SYSTEMD_DIR"
		install -m 0644 service/systemd/warren-daemon.service "$SYSTEMD_DIR/"
		install -m 0644 service/systemd/warren-early-boot-blocking.service "$SYSTEMD_DIR/"
		systemctl daemon-reload
		systemctl enable --now warren-daemon.service
		systemctl enable warren-early-boot-blocking.service || true
		;;
	openrc)
		info "wiring the OpenRC service"
		install -d "$INITD_DIR"
		install -m 0755 service/openrc/warren-daemon "$INITD_DIR/warren-daemon"
		rc-update add warren-daemon default
		rc-service warren-daemon start
		;;
	sysvinit)
		info "wiring the sysvinit services"
		install -d "$INITD_DIR" "$SUPERVISE_DIR"
		install -m 0755 service/sysvinit/warren-daemon "$INITD_DIR/warren-daemon"
		install -m 0755 service/sysvinit/warren-early-boot-blocking \
			"$INITD_DIR/warren-early-boot-blocking"
		install -m 0755 service/sysvinit/warren-daemon-supervise \
			"$SUPERVISE_DIR/warren-daemon-supervise"
		if command -v update-rc.d > /dev/null 2>&1; then
			update-rc.d warren-daemon defaults
			update-rc.d warren-early-boot-blocking defaults
		elif command -v chkconfig > /dev/null 2>&1; then
			chkconfig --add warren-daemon
			chkconfig --add warren-early-boot-blocking
		else
			warn "neither update-rc.d nor chkconfig found; enable $INITD_DIR/warren-daemon
       at boot the way this distribution expects."
		fi
		"$INITD_DIR/warren-daemon" start
		;;
	*)
		warn "no systemd, OpenRC or sysvinit detected. The files are installed, but
       nothing supervises the daemon. Start it with:

           WARREN_RESOURCE_DIR='$RES_DIR/' $BIN_DIR/warren-daemon -vv

       and add it to this system's own service manager. The daemon exits
       fail-closed, so it must be restarted forever, never given up on."
		;;
esac

info "done. Try:  warren account create  &&  warren status"
