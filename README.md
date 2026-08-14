<p align="center">
  <img src=".github/warren-logo.svg" alt="Warren" width="130"/>
</p>

# warren-cli

**The headless / server distribution of the Warren VPN command-line client.**

## TL;DR: install in one command (Linux and macOS)

```bash
curl -fsSL https://raw.githubusercontent.com/WarrenBrowse/warren-cli/main/scripts/install.sh | sudo sh
```

Windows, from an elevated PowerShell:

```powershell
irm https://raw.githubusercontent.com/WarrenBrowse/warren-cli/main/windows/install-windows.ps1 | iex
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

| Path | What |
|---|---|
| `/usr/bin/warren` | the CLI |
| `/usr/bin/warren-daemon` | the privileged daemon (a service, supervised) |
| `/usr/bin/warren-exclude` | split-tunnel helper (Linux) |
| `/opt/Warren VPN/resources/` | runtime resources (`ca.crt`, relay lists, the problem reporter) |
| service unit | systemd, OpenRC or sysvinit on Linux; launchd on macOS; the SCM on Windows |
| shell completions | bash / zsh / fish |

The package conflicts with every Warren desktop package: one Warren daemon per
machine, because two of them claim the same runtime directory, the same
management socket and the same firewall identity.

## Every machine, spelled out

| Host | Artifact |
|---|---|
| Debian, Ubuntu, Mint, Pop!\_OS, Raspberry Pi OS | `.deb` (amd64, arm64) |
| Fedora, RHEL, Alma, Rocky, openSUSE | `.rpm` (x86_64, aarch64) |
| Arch, Void, Gentoo, Artix, Slackware, NixOS, any other glibc Linux | generic tarball (x86_64, aarch64) |
| macOS, Apple Silicon and Intel | one universal tarball |
| Windows 10/11 x64, and ARM64 under emulation | zip |

The one-liner reads the host and picks for you. What is **not** covered: musl
systems (Alpine and derivatives), which the installer refuses with a reason
rather than a loader error, and 32-bit ARM and riscv64, which are not published.

Every artifact is checksummed in the release's `SHA256SUMS`, and every installer
verifies against it.

## Quick start (once a package is installed)

```bash
warren account create                 # generate identity (BIP39 mnemonic)
warren warren mnemonic export         # back up the recovery phrase, keep it safe
# during the free beta, use the voucher you received; purchases open with the paid service
warren account redeem <VOUCHER>       # add time to the account
warren account get                    # show address + expiry
warren relay list                     # browse available exits
warren relay set location FR          # pick a country (or: FR Paris)
warren connect                        # bring the tunnel up
warren status                         # show tunnel state
```

> Vouchers are how time reaches an account: apply one with `warren account
> redeem`. During the free beta they are handed out by the team; once the paid
> service opens, the web checkout issues them (Lightning / Monero / card, same
> flow as the desktop app). Restore an existing account on a new machine with
> `warren warren mnemonic import "<12 words>"`.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/WarrenBrowse/warren-cli/main/scripts/install.sh | sudo sh

CHANNEL=prod   # the production series, once it opens (beta is the live one today)
VERSION=1.1.14 # pin a version instead of the newest
sudo sh install.sh --uninstall
```

Full walkthrough, including the per-init-system service wiring and the Windows
path: [`docs/INSTALL-SERVER.md`](docs/INSTALL-SERVER.md).

`warren version` names the version, the compiled product environment and the API
host that environment resolves to, without needing the daemon to answer. That is
how you tell a beta install from a prod one when something is wrong.

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

**A CLI release rides on every app release, by design.** `release-daemon.yml` is
a reusable workflow that warren-app's `release.yml` calls on every `v*` /
`beta-v*` tag, and the app's publish job requires it to have succeeded. So the
CLI is always the same version as the app, built from the same commit. Cutting
the CLI alone stays possible: push a `daemon-v*` / `daemon-beta-v*` tag in
warren-app.

The tag shape picks the channel, and one run publishes exactly one of them.
Beta artifacts carry a `-beta` token and land on a pre-release, so an installer
resolving the prod channel can never be handed a beta build.

See [`docs/RELEASE.md`](docs/RELEASE.md).

## Status

- ✅ `warren` + `warren-daemon` build standalone (no Electron) and run, validated.
- ✅ Every artifact is checksummed and every installer verifies it.
- ✅ Linux `.deb` / `.rpm` / generic tarball, macOS universal tarball, Windows zip.
- ✅ Linux service wiring for systemd, OpenRC and sysvinit.
- ✅ Docker image `ghcr.io/warrenbrowse/warren-vpn` (kill switch, port-forward
  hooks, `network_mode: service:` sidecars): [`docs/DOCKER.md`](docs/DOCKER.md).
- 🚧 Signing / notarization: pending (artifacts are unsigned, like the GUI).
- ⏸️ Windows system-VPN tunnel is untested upstream; control-plane works.
- ❌ musl (Alpine): the binaries are glibc-linked; the installer says so.
- ❌ 32-bit ARM, riscv64: not published; build from source.

## License

The distributed binaries originate from `warren-app` and are **AGPL-3.0-or-later**.
The scripts and docs in this repo are under the same license.
