# Installing Warren on a headless / server machine

This guide installs the Warren VPN **daemon + CLI** on a machine with no desktop
environment. No Electron, no GUI.

There are two ways: install a **prebuilt artifact** (recommended), or **build
from source**.

---

## What is published, per release

| Artifact | Installs on |
|---|---|
| `warren-vpn-daemon-beta_<ver>_amd64.deb`, `_arm64.deb` | Debian, Ubuntu, Mint, Pop!\_OS, Raspberry Pi OS, anything with dpkg |
| `warren-vpn-daemon-beta_<ver>_x86_64.rpm`, `_aarch64.rpm` | Fedora, RHEL, Alma, Rocky, openSUSE, anything with rpm |
| `warren-headless-beta-<ver>-linux-x86_64.tar.gz`, `-aarch64.tar.gz` | Arch, Void, Gentoo, Artix, Slackware, NixOS, any other glibc Linux |
| `warren-headless-beta-<ver>-macos-universal.tar.gz` | macOS, Apple Silicon and Intel |
| `warren-headless-beta-<ver>-windows-x64.zip` | Windows 10/11 x64 (and ARM64 under emulation) |
| `SHA256SUMS` | what the installers verify a download against |

Prod-channel releases carry the same set without the `-beta` token. The channel
that is live today is **beta**; the production API host is not open yet.

### Architecture and libc

x86_64 and 64-bit ARM are published, on every format. 32-bit ARM and riscv64 are
not: build from source (Option B) if you need one.

Everything is linked against **glibc**. A musl host (Alpine and anything built
on it) cannot run these binaries, and the installer says so rather than letting
the dynamic loader fail with a message that names neither Warren nor the reason.
Run Warren in a glibc container there, or build from source against musl.

---

## Option A: install a prebuilt artifact (recommended)

### One command, Linux or macOS

```bash
curl -fsSL https://raw.githubusercontent.com/WarrenBrowse/warren-cli/main/scripts/install.sh | sudo sh
```

It resolves the newest release of the channel, picks the artifact that fits the
machine (`.deb`, `.rpm` or the tarball, for this architecture), verifies it
against the release `SHA256SUMS`, installs binaries, resources, shell
completions and the service, and starts the daemon.

```bash
CHANNEL=prod  … | sudo CHANNEL=prod sh   # the production series, once it opens
VERSION=1.1.14 … | sudo VERSION=1.1.14 sh  # pin a version
sudo sh install.sh ./warren-vpn-daemon-beta_1.1.14_amd64.deb   # an already downloaded file
sudo sh install.sh --uninstall
```

### By hand, Debian / Ubuntu

```bash
sudo dpkg -i warren-vpn-daemon-beta_<version>_amd64.deb || sudo apt-get -f install
# 64-bit ARM: warren-vpn-daemon-beta_<version>_arm64.deb
```

### By hand, Fedora / RHEL / openSUSE

```bash
sudo rpm -i warren-vpn-daemon-beta_<version>_x86_64.rpm
# or: sudo dnf install ./warren-vpn-daemon-beta_<version>_x86_64.rpm
# 64-bit ARM: warren-vpn-daemon-beta_<version>_aarch64.rpm
```

### By hand, any other Linux (Arch, Void, Gentoo, Slackware, NixOS, ...)

```bash
tar xzf warren-headless-beta-<version>-linux-x86_64.tar.gz
cd warren-headless-beta-<version>-linux-x86_64
sudo ./install.sh
# uninstall: sudo ./install.sh --uninstall
```

The tarball installs to the same paths as the `.deb` and wires up whichever
service manager the host actually runs:

| init system | what it installs |
|---|---|
| systemd | `warren-daemon.service`, `warren-early-boot-blocking.service` |
| OpenRC | `/etc/init.d/warren-daemon` (supervise-daemon, restarts forever) |
| sysvinit | `/etc/init.d/warren-daemon` + a supervisor standing in for `Restart=always` |
| anything else | the files, and the command to run the daemon yourself |

The daemon exits **fail-closed**: on a crash the kernel firewall is left
blocking. Whatever supervises it must restart it forever, never give up after a
burst of failures. All three integrations above do; a hand-rolled one must too.

### macOS

```bash
tar xzf warren-headless-beta-<version>-macos-universal.tar.gz
cd warren-headless-beta-<version>-macos-universal
sudo ./install.sh                # binaries + launchd service
# uninstall: sudo ./install.sh --uninstall
```

One universal bundle covers Apple Silicon and Intel. Binaries land in
`/usr/local/bin`, resources in `/usr/local/share/warren/resources`, and the
daemon runs under launchd (`com.warren.daemon`, logs at
`/var/log/warren-daemon.log`).

### Windows

> The Warren QUIC tunnel is not yet validated on Windows. Account and CLI
> control-plane operations work; system-VPN connect is experimental.

In an **elevated** PowerShell, either straight from the repo:

```powershell
irm https://raw.githubusercontent.com/WarrenBrowse/warren-cli/main/windows/install-windows.ps1 | iex
```

or from a downloaded bundle:

```powershell
Expand-Archive warren-headless-beta-<version>-windows-x64.zip
cd warren-headless-beta-<version>-windows-x64
.\install-windows.ps1
# uninstall: .\install-windows.ps1 -Uninstall
```

Everything installs into `%ProgramFiles%\Warren`, and the daemon registers
*itself* as a service (`warren-daemon.exe --register-service`), which is what
gives it the right service name for its channel, its BFE and NSI dependencies,
its restart-forever failure actions and the unrestricted service SID the tunnel
needs. Windows on ARM runs the x64 binaries under emulation.

---

## Option B: build from source

Requires a sibling checkout of `warren-app` and **its** siblings, plus `cargo`,
`protoc`, `cargo-deb`, `cargo-generate-rpm`. Those repositories are not yet
public, so this path currently needs access to them; without it, use Option A.

```
dev/
├── warren-app/        # the source of truth (daemon + CLI)
├── warrenguard/       # at the SHA in warren-app/.warrenguard-version
├── warren-contract/   # at the SHA in warren-app/.warren-contract-version
├── warren-sdk-rs/     # at the SHA in warren-app/.warren-sdk-version
└── warren-cli/        # this repo
```

### Native build on a Linux host

```bash
cd warren-cli
./scripts/build-daemon-only.sh
# -> warren-app/dist/warren-vpn-daemon_<version>_<arch>.deb (+ .rpm)

# multi-arch:
TARGETS="x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu" \
  ./scripts/build-daemon-only.sh
```

Packaging must run on **Linux** (`warren-exclude` is Linux-only). From macOS,
build in a Linux container that mounts the sibling checkouts, or let the release
CI produce the artifacts.

The generic tarball is assembled by `warren-app/ci/build-headless-bundle.sh`,
which takes a checkout of this repo for the installers and service units:

```bash
cd warren-app
WARREN_PRODUCT_ENV=beta ./build.sh --daemon-only --optimize
WARREN_PRODUCT_ENV=beta bash ci/build-headless-bundle.sh linux 1.1.14 ../warren-cli
```

### Just the binaries (no packaging)

```bash
cd warren-app
cargo build --release -p mullvad-daemon -p mullvad-cli
sudo WARREN_RESOURCE_DIR="$PWD/dist-assets" ./target/release/warren-daemon -vv &
./target/release/warren status
```

---

## First use

```bash
# 1. Create (or restore) an identity
warren account create
warren warren mnemonic export                 # back up the 12 words offline!
# restore instead:  warren warren mnemonic import "word1 word2 ... word12"

# 2. Add credit (buy on the Warren website -> you receive a voucher)
warren account redeem <VOUCHER>
warren account get                            # address + expiry

# 3. Pick a server and connect
warren relay list
warren relay set location FR                  # or: FR Paris
warren connect --wait
warren status

# 4. Optional hardening
warren lockdown-mode set on                   # kill-switch: block traffic when down
```

## Which build am I running

```bash
warren version
```

The first three lines come from the binary itself and answer without a daemon:
the version, the product environment it was compiled for, and the API host that
environment resolves to. That is the fastest way to tell a beta install from a
prod one, and the only one that still works when the daemon will not start.

## Managing the service

```bash
systemctl status warren-daemon                # systemd
rc-service warren-daemon status               # OpenRC
/etc/init.d/warren-daemon status              # sysvinit
sudo launchctl print system/com.warren.daemon # macOS

journalctl -u warren-daemon -f                # daemon logs (systemd)
tail -f /var/log/warren-daemon.log            # OpenRC, sysvinit, macOS
```

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/WarrenBrowse/warren-cli/main/scripts/install.sh | sudo sh -s -- --uninstall
```

It removes a package install through the package manager and a tarball install
through the uninstaller the bundle left behind. Settings, logs and caches under
`/etc/warren-vpn*`, `/var/log/warren-vpn*` and `/var/cache/warren-vpn*` are kept
on purpose: an account's identity lives there.

## Notes and caveats

- The daemon **must run as root** (TUN device, firewall, routing, DNS).
- The control socket is `/var/run/warren-vpn` (`/var/run/warren-vpn-beta` for a
  beta build: the two environments never share state).
- One Warren daemon per machine. The headless packages conflict with every
  Warren desktop package, because both would claim the same runtime directory,
  the same management socket and the same firewall identity.
- The tunnel is validated on **Linux and macOS**; Windows is untested for the
  Warren QUIC tunnel.
- The daemon talks to `api.warrenbrowse.com` (prod) or
  `api.beta.warrenbrowse.com` (beta), whichever the binary was compiled for.
  During the public beta the beta channel is the live service and expects an
  account with an active subscription; the prod channel is not open yet.
