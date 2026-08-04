# warren-cli

**The headless / server distribution of the Warren VPN command-line client.**

## TL;DR: install in one command (Linux)

```bash
curl -fsSL https://raw.githubusercontent.com/WarrenBrowse/warren-cli/main/scripts/install.sh | sudo sh
```

Then: `warren account create && warren connect`.

Warren already ships a full-featured Rust CLI (`warren`) and a privileged daemon
(`warren-daemon`) inside the
[warren-app](https://github.com/WarrenBrowse/warren-app) repo (a Mullvad VPN
fork). They build and run **without the Electron GUI** and are perfectly suited to
servers, containers and SSH-only machines.

This repo does **not** re-implement the CLI. It is the **distribution layer**:
clear server-install docs, a release pipeline that produces ready-to-install
packages, and a one-line installer, so an operator never has to compile ~900
crates themselves.

> **Why not a new SDK-based CLI?** Because the existing `warren` CLI already does
> everything we need (account creation, mnemonic import/export, voucher redemption,
> server selection, connect/disconnect, kill-switch, split-tunnel, multihop,
> NAT-PMP) and runs headless today. Building a parallel CLI on `warren-sdk-rs`
> would be redundant. See [`docs/SPEC.md`](docs/SPEC.md) for the full rationale.

## What you get

A `warren-vpn-daemon` package (`.deb` / `.rpm`) containing:

| Path | What |
|---|---|
| `/usr/bin/warren` | the CLI |
| `/usr/bin/warren-daemon` | the privileged daemon (systemd service) |
| `/usr/bin/warren-exclude` | split-tunnel helper (Linux) |
| `/usr/lib/systemd/system/warren-daemon.service` | the service unit |
| `/opt/Warren VPN/resources/` | runtime resources (`ca.crt`, relay bootstrap, …) |
| shell completions | bash / zsh / fish |

The package `conflicts` with the desktop `warren-vpn` package: it is the
GUI-less counterpart.

## Quick start (once a package is installed)

```bash
warren account create                 # generate identity (BIP39 mnemonic)
warren warren mnemonic export         # back up the recovery phrase, keep it safe
# buy credit on the Warren website (Lightning / Monero / card) -> you get a voucher
warren account redeem <VOUCHER>       # add time to the account
warren account get                    # show address + expiry
warren relay list                     # browse available exits
warren relay set location FR          # pick a country (or: FR Paris)
warren connect                        # bring the tunnel up
warren status                         # show tunnel state
```

> Buying credit is a web-checkout flow (same as the desktop app): the website
> issues a voucher, which you apply with `warren account redeem`. Restore an
> existing account on a new machine with `warren warren mnemonic import "<12 words>"`.

## Install

```bash
# Linux server (resolves the latest daemon-v* release and installs it):
curl -fsSL https://raw.githubusercontent.com/WarrenBrowse/warren-cli/main/scripts/install.sh | sudo sh
```

The published Linux packages currently target amd64/x86_64 only; on an ARM
server, build from source (see below). Full walkthrough incl. macOS/Windows:
[`docs/INSTALL-SERVER.md`](docs/INSTALL-SERVER.md).

## Building the packages

The real packages are produced by **warren-app**'s `release-daemon.yml` workflow on
the self-hosted runners (this repo's `.github/workflows/ci.yml` only lints).
Locally on a Linux host:

```bash
# On a Linux host → dist/warren-vpn-daemon_<ver>_<arch>.deb (+ .rpm):
./scripts/build-daemon-only.sh

# Multi-arch (build.sh reads the TARGETS env array):
TARGETS="x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu" \
  ./scripts/build-daemon-only.sh
```

The script drives `warren-app/build.sh --daemon-only`;
warren-app is the single source of truth and is never forked here. Packaging must
run on **Linux** (`warren-exclude` is Linux-only); from macOS, use the release CI
or a Linux container.

### Build prerequisites

Building from source requires access to the `warren-app`, `warren-core` and
`warrenguard` repositories, which are not yet public. Until they are, the
prebuilt packages above are the way to install.

- A sibling `warren-app` checkout (override with `WARREN_APP_DIR`), plus its own
  siblings `warren-core` and `warrenguard` at the SHAs pinned in
  `warren-app/.warren-core-version` and `.warrenguard-version`.
- `cargo` + `protoc`, and `cargo install cargo-deb cargo-generate-rpm`.
- For cross-builds: Docker and `cargo install cross`.

## Releases

Headless artifacts are built by **warren-app**'s `release-daemon.yml` workflow on
the self-hosted runners (it reuses the same build env as the GUI release):

- **Linux**: `warren-vpn-daemon_<ver>_<arch>.deb` / `.rpm` (`build.sh --daemon-only`)
- **macOS**: `warren-headless-macos-<arch>.tar.gz` (binaries + launchd installer)
- **Windows**: `warren-headless-windows-x64.zip` (binaries + service installer, experimental)

Cut a release by pushing a `daemon-v*` tag in `warren-app`. See
[`docs/RELEASE.md`](docs/RELEASE.md).

## Status

- ✅ `warren` + `warren-daemon` build standalone (no Electron) and run, validated.
- ✅ Mullvad→Warren CLI branding (`warren --version` → `warren x.y.z`).
- ✅ CI green on all three OSes; Linux `.deb`/`.rpm`, macOS tarball, Windows zip.
- ✅ First release published:
  [`daemon-v1.2.1`](https://github.com/WarrenBrowse/warren-cli/releases/tag/daemon-v1.2.1)
  (clean `1.2.1`, all four artifacts).
- 🚧 Signing / notarization: pending (artifacts are unsigned, like the GUI).
- ⏸️ Windows system-VPN tunnel is untested upstream; control-plane works.

## License

The distributed binaries originate from `warren-app` and are **AGPL-3.0-or-later**.
The scripts and docs in this repo are under the same license.
