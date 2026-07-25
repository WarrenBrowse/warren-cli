# Warren CLI — Specification & Decision Record

Status: **accepted** · Date: 2026-06-30 · Owner: poka

## 1. Goal

Provide a robust, multi-platform, full-Rust way to use Warren entirely from the
command line — create an account, add credit, browse servers, connect — on
machines with no GUI (servers, containers, SSH).

## 2. Decision

**Reuse the existing `warren` CLI + `warren-daemon` from `warren-app`. Do not build
a new CLI, and do not consume `warren-sdk-rs`.**

Rationale:

- The existing `warren` CLI (Cargo package `mullvad-cli`) and `warren-daemon`
  (package `mullvad-daemon`) are **pure Rust, GUI-independent**, and already
  feature-complete. Building daemon + CLI only:

  ```bash
  cargo build --release -p mullvad-daemon -p mullvad-cli   # no node/npm, no Electron
  ```

  Validated on macOS (debug): both binaries build and run; `warren --version` →
  `mullvad-cli 1.2.1-dev`; the full command tree responds.

- A new SDK-native CLI would **duplicate** account/identity/discovery/datapath
  logic that already exists and works, and would lose the OS-level features that
  live only in the daemon (kill-switch, split-tunnel, content-blocking DNS,
  LAN rules, anti-censorship, custom lists). "Avoid redundancy" + "be
  feature-complete with the app" + "reuse warren-app" win over "consume the SDK",
  which was explicitly dropped as a requirement.

### Requirements trade-off

| Requirement (from brief) | Reuse `warren` | New SDK CLI |
|---|---|---|
| Full Rust | ✅ | ✅ |
| Multi-platform Win/Mac/Linux | ✅ (Linux/macOS validated; Win untested) | ✅ |
| Feature-complete vs the app | ✅ (it *is* the app's engine) | ⚠️ misses OS-level features |
| Avoid redundancy | ✅ | ❌ second CLI |
| Reuse warren-app | ✅ | ❌ |
| Consume the SDK | ❌ | ✅ (dropped requirement) |

## 3. Architecture (inherited from Mullvad)

Three independent components; the CLI and GUI are **both just clients**:

```
   warren (CLI)  ─┐
                  ├── gRPC over Unix socket  ──►  warren-daemon (root)
   Electron GUI  ─┘     /var/run/warren-vpn        owns tunnel + firewall +
                                                   routing + DNS + account
                                                          │  QUIC to exit
```

- **Identity**: BIP39 mnemonic → HKDF-SHA256 → Ed25519 → SS58 address (`wb…`).
  No account number, no email/password. The mnemonic *is* the account.
- **Account API**: signed `https://api.warrenbrowse.com/v1/*` on the prod channel,
  `https://api.beta.warrenbrowse.com/v1/*` on beta (Ed25519 request signatures:
  `X-Warren-{PubKey,Sig,Timestamp,Nonce}`). The host is baked into the
  `warren-app` binary at compile time via `WARREN_PRODUCT_ENV`, defaulting to
  prod; `warren-cli` packages whatever binary `warren-app` produces and does not
  select the channel itself.
- **Credit**: buy on the website (Lightning / Monero / card / on-chain) → the
  backend issues a **voucher** → `warren account redeem <voucher>` extends the
  subscription (`expires_at`). The CLI and the desktop app share this exact flow;
  neither buys in-app.
- **Discovery**: the daemon fetches and verifies the signed relay list from
  `/v1/exits` at boot and periodically.
- **Datapath**: privileged QUIC tunnel through a real TUN device, with firewall
  kill-switch, DNS and routing managed by the daemon (talpid). Needs root.

## 4. Command surface (existing `warren`, abridged)

```
account     create | login | logout | get | redeem <voucher>
warren      mnemonic {export|import} | api-url {get|set|unset} | n-connections {get|set|reset}
connect | disconnect | reconnect | status [listen]
relay       list | set location <country> [city] | set custom-list <name> | update
tunnel      ipv6 | quantum-resistant | wireguard | daita
dns         set default [--block-ads --block-trackers …] | set custom <ip…>
lockdown-mode {get|set}        # kill-switch
lan {get|set}                  # local network sharing
split-tunnel ...               # exclude apps/processes
auto-connect | anti-censorship | api-access | custom-list
import-settings | export-settings | factory-reset | reset-settings | version
```

## 5. Packaging

`warren-app/build.sh --daemon-only` already produces, via `cargo-deb` /
`cargo-generate-rpm`, a **GUI-less** package `warren-vpn-daemon` (`.deb` + `.rpm`)
that `conflicts` with the desktop `warren-vpn`. Contents:

- `/usr/bin/warren`, `/usr/bin/warren-daemon`, `/usr/bin/warren-exclude`
- `/usr/lib/systemd/system/warren-daemon.service` (`WARREN_RESOURCE_DIR` preset)
- `/opt/Warren VPN/resources/` (`ca.crt`, relay bootstrap, `warren-setup`, …)
- bash / zsh / fish completions

`warren-exclude` is Linux-only, so the package is a Linux target. Cross-builds
from macOS use the repo's `Cross.toml` (`x86_64-unknown-linux-gnu`, mounts the
sibling `warren-core`). macOS/Windows headless packaging is phase 2.

## 6. Scope of THIS repo

`warren-cli` is a **distribution + release + docs** layer over the upstream
`--daemon-only` path. It does not fork warren-app code. It provides:

1. `docs/INSTALL-SERVER.md` — the missing server-install guide.
2. `scripts/build-daemon-only.sh` — thin wrapper over `warren-app/build.sh`.
3. `scripts/install.sh` — one-line installer (fetch package → install → enable).
4. `.github/workflows/release.yml` — Linux CI producing the real artifacts.

## 7. Status & open items

Done:
- ✅ Branding polish: `warren --version` → `warren <ver>`, help title rebranded
  (`warren-app/mullvad-cli`: clap `name = "warren"` + Cargo description).
- ✅ Headless CI on the self-hosted runners: `warren-app/release-daemon.yml`
  builds Linux `.deb`/`.rpm`, a macOS tarball, and a Windows zip.
- ✅ Install glue for all three OSes (`scripts/`, `macos/`, `windows/`).

Open / phase 2:
- Publish the first release and decide where assets live (warren-app vs mirror to
  warren-cli); `install.sh` `REPO` is overridable accordingly.
- Signing/notarization (macOS `.pkg`, Windows Authenticode) once accounts exist.
- Validate the Windows system-VPN tunnel (untested upstream).
- `warren-core` SHA hygiene: warren-app pins `0d910732…`; reproducible builds must
  use that checkout (CI reads `.warren-core-version`).
