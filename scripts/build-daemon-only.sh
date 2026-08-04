#!/usr/bin/env bash
#
# Build the GUI-less Warren packages (warren-vpn-daemon .deb / .rpm) by driving
# warren-app's own `build.sh --daemon-only`. This repo never forks warren-app
# code; it only orchestrates the upstream build.
#
# Usage:
#   ./scripts/build-daemon-only.sh [--optimize] [extra build.sh args...]
#
# Multi-arch on a Linux host (build.sh reads the TARGETS env array):
#   TARGETS="x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu" \
#     ./scripts/build-daemon-only.sh
#
# Output: <warren-app>/dist/warren-vpn-daemon_<version>_<arch>.deb (+ .rpm)
#
# Env:
#   WARREN_APP_DIR   path to the warren-app checkout (default: ../warren-app)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

WARREN_APP_DIR="${WARREN_APP_DIR:-$(cd "$REPO_ROOT/.." && pwd)/warren-app}"

die() { printf '\033[0;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[0;34m[info]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[warn]\033[0m %s\n' "$*" >&2; }

# --- platform guard ----------------------------------------------------------
# warren-exclude is Linux-only and the package targets Linux, so packaging must
# run on a Linux host. Cross-compiling from macOS via build.sh is not supported
# (it uses plain `cargo`, not `cross`); use the release CI or a Linux box/Docker.
if [[ "$(uname -s)" != "Linux" ]]; then
    die "daemon-only packaging must run on a Linux host (warren-exclude is Linux-only).
       Use .github/workflows/release.yml, a Linux machine, or a Linux container
       that mounts warren-app + warren-core + warrenguard."
fi

# --- sibling checkouts -------------------------------------------------------
[[ -x "$WARREN_APP_DIR/build.sh" ]] || die "warren-app not found at: $WARREN_APP_DIR
       set WARREN_APP_DIR to your warren-app checkout."

SIBLINGS_ROOT="$(cd "$WARREN_APP_DIR/.." && pwd)"
for sib in warren-core warrenguard; do
    [[ -d "$SIBLINGS_ROOT/$sib" ]] || die "missing sibling checkout: $SIBLINGS_ROOT/$sib"
done

# Warn (do not touch) if siblings are not at the SHA warren-app pins.
check_pin() {
    local repo="$1" pinfile="$2"
    [[ -f "$pinfile" ]] || return 0
    local want have
    want="$(tr -d '[:space:]' < "$pinfile")"
    have="$(git -C "$SIBLINGS_ROOT/$repo" rev-parse HEAD 2>/dev/null || echo '?')"
    if [[ "$have" != "$want" ]]; then
        warn "$repo is at ${have:0:12}, warren-app pins ${want:0:12}, build may differ."
    fi
}
check_pin warren-core "$WARREN_APP_DIR/.warren-core-version"
check_pin warrenguard "$WARREN_APP_DIR/.warrenguard-version"

# --- tooling -----------------------------------------------------------------
command -v cargo  >/dev/null || die "cargo not found"
command -v protoc >/dev/null || die "protoc not found"
cargo deb --version          >/dev/null 2>&1 || die "run: cargo install cargo-deb"
cargo generate-rpm --version >/dev/null 2>&1 || die "run: cargo install cargo-generate-rpm"

# --- build -------------------------------------------------------------------
info "building daemon-only packages via $WARREN_APP_DIR/build.sh"
cd "$WARREN_APP_DIR"
./build.sh --daemon-only "$@"

info "artifacts:"
ls -1 "$WARREN_APP_DIR"/dist/warren-vpn-daemon_* 2>/dev/null || warn "no artifacts in dist/"
