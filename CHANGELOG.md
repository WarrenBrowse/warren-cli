# Changelog

All notable changes to the `warren-cli` distribution are documented here.
This repo distributes the GUI-less Warren CLI + daemon; the CLI/daemon code
itself lives in [`warren-app`](https://github.com/WarrenBrowse/warren-app).

## [Unreleased]

### Added
- Initial headless distribution layer:
  - `docs/SPEC.md`: decision record (reuse `warren-app`'s CLI, no SDK fork).
  - `docs/INSTALL-SERVER.md`: Linux / macOS / Windows headless install guide.
  - `docs/RELEASE.md`: how the release pipeline works.
  - `scripts/build-daemon-only.sh`: wrapper over `warren-app/build.sh --daemon-only`.
  - `scripts/install.sh`: one-line installer (fetch package → install → enable).
  - `macos/`: launchd service + `install-macos.sh`.
  - `windows/install-windows.ps1`: Windows service installer (experimental).
  - `.github/workflows/ci.yml`: shellcheck + PSScriptAnalyzer lint.
- In `warren-app` (branch `warren-cli-headless`):
  - CLI branding: `warren --version` → `warren <ver>`; rebranded help title and
    `.deb`/`.rpm` package description.
  - `.github/workflows/release-daemon.yml`: headless release pipeline
    (Linux `.deb`/`.rpm`, macOS tarball, Windows zip) on the self-hosted runners.

### CI pipeline brought to green (validated on the self-hosted runners)
Bugs found and fixed while bringing the headless pipeline up:
- Linux runner lacked `cargo-deb` / `cargo-generate-rpm` → installed in the job.
- `build.sh | tee` masked failures (no `pipefail`) → added `set -o pipefail`.
- Windows `winfw` was built Debug while the release link wanted
  `x64-Release/winfw.lib` (LNK1181) → forced `CPP_BUILD_MODES=Release`.
- `cargo deb` rejects a `description` key in `[package.metadata.deb]` →
  use the package description + `extended-description`.
- RPM versions forbid `-`; dev builds carry `-dev-<sha>` → `build.sh` maps `-`→`~`
  for the rpm version.

First clean release built from `main` (`daemon-v1.2.1`): clean `1.2.1` version
(no `-dev` suffix): a `daemon-vX.Y.Z` tag now creates a local `v<ver>` tag at
build time so `mullvad-version` drops the suffix, without pushing `v<ver>` (so the
GUI `release.yml` is not triggered).

Validated artifacts:
- `warren-vpn-daemon_1.2.1_amd64.deb`, inspected: `/usr/bin/{warren,warren-daemon,
  warren-exclude}`, `warren-daemon.service`, resources, shell completions;
  `Conflicts: warren-vpn`; `Description: Warren VPN daemon …`.
- `warren-vpn-daemon_1.2.1_x86_64.rpm`, inspected: same payload.
- `warren-headless-macos-arm64.tar.gz`, inspected: binaries + resources +
  launchd installer; CI-built `warren --version` → `warren 1.2.1`.
- `warren-headless-windows-x64.zip`

### Notes
- The Warren QUIC tunnel is validated on Linux and macOS; Windows is experimental
  (builds and packages, tunnel untested upstream).
- Artifacts are unsigned until signing/notarization accounts exist.
- The `daemon-v*` tags are dev/rc builds (`<ver>` = `1.2.1-dev-<sha>`); cut a clean
  `1.2.1` release by stamping `dist-assets/desktop-product-version.txt` and tagging.
