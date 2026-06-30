# Changelog

All notable changes to the `warren-cli` distribution are documented here.
This repo distributes the GUI-less Warren CLI + daemon; the CLI/daemon code
itself lives in [`warren-app`](https://github.com/WarrenBrowse/warren-app).

## [Unreleased]

### Added
- Initial headless distribution layer:
  - `docs/SPEC.md` — decision record (reuse `warren-app`'s CLI, no SDK fork).
  - `docs/INSTALL-SERVER.md` — Linux / macOS / Windows headless install guide.
  - `docs/RELEASE.md` — how the release pipeline works.
  - `scripts/build-daemon-only.sh` — wrapper over `warren-app/build.sh --daemon-only`.
  - `scripts/install.sh` — one-line installer (fetch package → install → enable).
  - `macos/` — launchd service + `install-macos.sh`.
  - `windows/install-windows.ps1` — Windows service installer (experimental).
  - `.github/workflows/ci.yml` — shellcheck + PSScriptAnalyzer lint.
- In `warren-app` (branch `warren-cli-headless`):
  - CLI branding: `warren --version` → `warren <ver>`; rebranded help title.
  - `.github/workflows/release-daemon.yml` — headless release pipeline
    (Linux `.deb`/`.rpm`, macOS tarball, Windows zip) on the self-hosted runners.

### Notes
- The Warren QUIC tunnel is validated on Linux and macOS; Windows is experimental.
- Artifacts are unsigned until signing/notarization accounts exist.
