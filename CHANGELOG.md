# Changelog

All notable changes to the `warren-cli` distribution are documented here.
This repo distributes the GUI-less Warren CLI + daemon; the CLI/daemon code
itself lives in [`warren-app`](https://github.com/WarrenBrowse/warren-app).

## [Unreleased]

### The CLI now ships with every app release

`release-daemon.yml` became a reusable workflow that `warren-app`'s
`release.yml` calls on every `v*` / `beta-v*` tag, and the app's publish job
requires it. A new app version therefore always ships the matching CLI, at the
same version, from the same commit. Pushing a `daemon-v*` / `daemon-beta-v*`
tag still cuts the CLI on its own when there is no app release to make.

The independent tag series was what let `warren-cli` serve a June build while
the app shipped weekly; by the time the production API host was retired, that
build was pointing at a host answering 410, and nothing said so.

The pipeline also **publishes** the release now. It used to leave a draft on
this repo, and a draft is invisible to `scripts/install.sh`: its asset URLs
answer 404 and the API does not list it. `finalise` asserts the artifact set is
complete, writes `SHA256SUMS` and flips the release.

### Channels

The tag shape picks the channel and one run publishes exactly one of them.
Beta artifacts carry a `-beta` token (`warren-vpn-daemon-beta_…`,
`warren-headless-beta-…`) and land on a `daemon-beta-v*` release marked
pre-release, so an installer resolving the prod channel can never be handed a
beta build. `scripts/install.sh` defaults to beta, which is the only live
channel today, and takes `CHANNEL=prod`.

### Any Linux, any 64-bit architecture

- New generic tarball `warren-headless[-beta]-<ver>-linux-{x86_64,aarch64}.tar.gz`
  for distributions the `.deb` and `.rpm` do not reach (Arch, Void, Gentoo,
  Artix, Slackware, NixOS). It carries the same payload as the `.deb` and wires
  up **systemd, OpenRC or sysvinit**, whichever the host actually runs, with the
  restart-forever contract the fail-closed daemon needs in all three.
- The installer refuses a musl host (Alpine) with a reason, instead of letting
  the dynamic loader fail with a message that names neither Warren nor the
  cause. These binaries are glibc-linked.

### Fixed in the artifacts themselves

- **macOS was arm64 only.** No Intel Mac could run the bundle, and nothing said
  so until the binary refused to exec. Both slices are now built and joined into
  one universal bundle, whose universality is asserted before it is published.
- **The macOS and Windows bundles shipped no relay lists.** The daemon parses
  `relays.json` at boot and loads its exit list from `warren-relays.json`;
  neither was in either bundle. The `.deb` and `.rpm` were missing the exit
  bootstrap too, so a fresh server install had no exits until its first fetch.
- **The Windows bundle shipped neither `winfw.dll` nor `wintun.dll`**, so the
  daemon could not arm the kill switch or create a tunnel adapter. It installed
  and then did nothing. Both ship now, alongside the split-tunnel driver,
  `warren-setup.exe` and `warren-problem-report.exe`, in one flat directory
  (the loader resolves `winfw.dll` next to the exe; the other two are opened
  from the resource directory).
- **The Windows installer registered its own service** under a name the daemon
  does not know, with none of the dependencies, failure actions or service SID
  the tunnel needs. It now calls `warren-daemon.exe --register-service` and lets
  the daemon register itself.
- The headless package now conflicts with every Warren desktop package, not just
  the prod one. A beta desktop install and a beta headless install claim the
  same runtime directory, management socket and firewall identity, and the loser
  is whichever daemon starts second, on a machine whose kill switch is armed.

### Added

- `linux/`: the OpenRC service and the tarball installer, alongside `macos/`
  and `windows/`.
- `scripts/test-install.sh`: unit tests for the installer's artifact resolution,
  run in CI. They pin the release naming conventions and the version sort that a
  lexicographic ordering gets backwards (1.9.1 after 1.11.0).
- Checksum verification in every installer, against the release `SHA256SUMS`.
- `warren version` states the compiled product environment and its API host
  before it tries to reach a daemon, which is the only way to tell which network
  a headless install targets when the daemon will not start.

## [1.2.1] and earlier

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
