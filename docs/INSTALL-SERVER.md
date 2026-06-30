# Installing Warren on a headless / server machine

This guide installs the Warren VPN **daemon + CLI** on a Linux machine with no
desktop environment. No Electron, no GUI.

There are two ways: install a **prebuilt package** (recommended), or **build from
source**.

---

## Option A — Install a prebuilt package (recommended)

> Prebuilt `.deb` / `.rpm` are produced by this repo's release pipeline. Until a
> release is published, use Option B.

### Debian / Ubuntu

```bash
sudo dpkg -i warren-vpn-daemon_<version>_amd64.deb || sudo apt-get -f install
```

### Fedora / RHEL

```bash
sudo rpm -i warren-vpn-daemon_<version>_x86_64.rpm
# or: sudo dnf install ./warren-vpn-daemon_<version>_x86_64.rpm
```

### One-liner

```bash
curl -fsSL https://raw.githubusercontent.com/WarrenBrowse/warren-cli/main/scripts/install.sh | sudo sh
```

It resolves the latest `daemon-v*` release, downloads the right `.deb`/`.rpm`,
installs the binaries + `warren-daemon` systemd unit + resources + completions, and
enables the service.

> **While the repos are private** the download needs GitHub auth: install on a host
> with `gh` logged in (`gh auth login`), or pass a token —
> `curl -fsSL …/install.sh | sudo GH_TOKEN=<token> sh`. Once a release is made
> public, the token-less one-liner works.

---

## Option B — Build from source

Requires a sibling checkout of `warren-app` and **its** siblings `warren-core`
and `warrenguard`, plus `cargo`, `protoc`, `cargo-deb`, `cargo-generate-rpm`.

```
dev/
├── warren-app/        # the source of truth (daemon + CLI)
├── warren-core/       # at the SHA in warren-app/.warren-core-version
├── warrenguard/       # at the SHA in warren-app/.warrenguard-version
└── warren-cli/        # this repo
```

### Native build on a Linux host

```bash
cd warren-cli
./scripts/build-daemon-only.sh
# → warren-app/dist/warren-vpn-daemon_<version>_<arch>.deb (+ .rpm)

# multi-arch:
TARGETS="x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu" \
  ./scripts/build-daemon-only.sh
```

Packaging must run on **Linux** (`warren-exclude` is Linux-only). From macOS,
build in a Linux container that mounts `warren-app` + `warren-core` +
`warrenguard`, or just let the release CI produce the artifacts.

### Just the binaries (no packaging)

```bash
cd warren-app
cargo build --release -p mullvad-daemon -p mullvad-cli
sudo WARREN_RESOURCE_DIR="$PWD/dist-assets" ./target/release/warren-daemon -vv &
./target/release/warren status
```

---

## macOS (headless)

Download `warren-headless-macos-<arch>.tar.gz` from the release, then:

```bash
tar xzf warren-headless-macos-arm64.tar.gz
cd warren-headless-macos-arm64
sudo ./install-macos.sh          # installs binaries + launchd service
# uninstall: sudo ./install-macos.sh --uninstall
```

Binaries land in `/usr/local/bin`, resources in `/usr/local/share/warren/resources`,
and the daemon runs under launchd (`com.warren.daemon`, logs at
`/var/log/warren-daemon.log`).

## Windows (experimental)

> The Warren QUIC tunnel is not yet validated on Windows. Account/CLI
> control-plane operations work; system-VPN connect is experimental.

Download `warren-headless-windows-x64.zip`, then in an **elevated** PowerShell:

```powershell
Expand-Archive warren-headless-windows-x64.zip
cd warren-headless-windows-x64
.\install-windows.ps1            # installs to %ProgramFiles%\Warren + registers a service
# uninstall: .\install-windows.ps1 -Uninstall
```

---

## First use

```bash
# 1. Create (or restore) an identity
warren account create
warren warren mnemonic export                 # back up the 12 words offline!
# restore instead:  warren warren mnemonic import "word1 word2 ... word12"

# 2. Add credit (buy on the Warren website → you receive a voucher)
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

## Managing the service

```bash
systemctl status warren-daemon
sudo systemctl restart warren-daemon          # after `warren warren api-url set …`
journalctl -u warren-daemon -f                # daemon logs
```

## Uninstall

```bash
sudo systemctl disable --now warren-daemon
sudo apt-get remove warren-vpn-daemon         # or: sudo rpm -e warren-vpn-daemon
```

## Notes & caveats

- The daemon **must run as root** (TUN device, firewall, routing, DNS).
- The control socket is `/var/run/warren-vpn`. Non-root use can be granted by
  group membership (inherited from the Mullvad model).
- Tunnel is validated on **Linux and macOS**; Windows is untested for the Warren
  QUIC tunnel.
- The IP/account observed at `api.warrenbrowse.com` is a **test network**; use a
  subscribed test wallet only.
