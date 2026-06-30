# Cutting a headless release

The GUI-less Warren artifacts are produced by the **`release-daemon.yml`**
workflow in the [`warren-app`](../../warren-app) repo (it owns the build
toolchain, the self-hosted runners, and the `mullvad-build-env` composite
action). This repo (`warren-cli`) only provides the install glue and docs.

## Pipeline

`warren-app/.github/workflows/release-daemon.yml` has three jobs:

| Job | Runner | Output |
|---|---|---|
| `linux` | `[self-hosted, Linux, X64, macstudio-rosetta]` | `warren-vpn-daemon_<ver>_<arch>.deb` + `.rpm` via `build.sh --daemon-only --optimize` |
| `macos` | `[self-hosted, macOS, ARM64]` | `warren-headless-macos-<arch>.tar.gz` (binaries + resources + `macos/` installer) |
| `windows` | `[self-hosted, Windows, X64]` | `warren-headless-windows-x64.zip` (binaries + resources + `windows/` installer) |

The macOS/Windows jobs check this repo out to bundle the install scripts from
`macos/` and `windows/`.

## How to release

1. Ensure the desired version is set in `warren-app/dist-assets/desktop-product-version.txt`
   (or push a `vX.Y.Z` tag — `mullvad-build-env` stamps the version from a
   `vX.Y.Z` tag, but `release-daemon` triggers on `daemon-v*`, so set the file).
2. From `warren-app`:
   ```bash
   git tag daemon-v1.2.1
   git push origin daemon-v1.2.1
   ```
3. The three jobs attach their artifacts to a **draft** GitHub Release on the
   tag. Review and publish it.
4. `warren-cli`'s `scripts/install.sh` resolves the latest release of
   `WarrenBrowse/warren-cli`; either mirror the assets there or adjust the
   `REPO` constant to point at `WarrenBrowse/warren-app`.

## Required secrets (on `warren-app`)

- `WARREN_CORE_RO_TOKEN` — read access to `warren-core` + `warrenguard` (and, for
  the mac/win jobs, to check out `warren-cli`).

Signing/notarization secrets are optional; without them the artifacts are
unsigned (acceptable until Warren has signing accounts — same posture as the
GUI `release.yml`).

## Local dry-run

Linux packaging can be exercised on a Linux host (or the self-hosted runner)
without CI:

```bash
./scripts/build-daemon-only.sh        # → warren-app/dist/warren-vpn-daemon_*.deb
```
