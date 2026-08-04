# Cutting a headless release

The GUI-less Warren artifacts are produced by the **`release-daemon.yml`**
workflow in the [warren-app](https://github.com/WarrenBrowse/warren-app) repo
(not yet public; it owns the build toolchain, the self-hosted runners, and the
`mullvad-build-env` composite action). This repo (`warren-cli`) only provides
the install glue and docs.

## Pipeline

`warren-app/.github/workflows/release-daemon.yml` has three jobs:

| Job | Runner | Output |
|---|---|---|
| `linux` | self-hosted Linux x64 | `warren-vpn-daemon_<ver>_<arch>.deb` + `.rpm` via `build.sh --daemon-only --optimize` |
| `macos` | self-hosted macOS arm64 | `warren-headless-macos-<arch>.tar.gz` (binaries + resources + `macos/` installer) |
| `windows` | self-hosted Windows x64 | `warren-headless-windows-x64.zip` (binaries + resources + `windows/` installer) |

The exact runner labels live in the workflow file in `warren-app`.

The macOS/Windows jobs check this repo out to bundle the install scripts from
`macos/` and `windows/`. All three jobs **publish their artifacts to a release in
`warren-cli`** (the public-facing distribution repo), not in warren-app, so the
public install one-liner only needs `warren-cli` to be public.

## Versioning

A `daemon-vX.Y.Z` tag emits a **clean** version (`X.Y.Z`, no `-dev-<hash>`): the
workflow writes `dist-assets/desktop-product-version.txt` and creates a *local*
`vX.Y.Z` tag at build time so `mullvad-version` drops the suffix, without pushing
`vX.Y.Z`, so the GUI `release.yml` (triggered by `v*.*.*`) is **not** fired. An
`-rc` suffix (`daemon-vX.Y.Z-rc1`) keeps the `-dev` version.

## How to release

1. From `warren-app` (on `main`), tag and push:
   ```bash
   git tag daemon-v1.2.1
   git push origin daemon-v1.2.1
   ```
2. The three jobs build and attach their artifacts to a **draft** release
   `daemon-v1.2.1` **in `warren-cli`**.
3. Review and publish that warren-cli release. `scripts/install.sh` then resolves
   it automatically (it picks the latest `daemon-v*` release).

## Required secrets (on `warren-app`)

- `WARREN_CORE_RO_TOKEN`: read access to `warren-core` + `warrenguard` (and, for
  the mac/win jobs, to check out `warren-cli`).
- `WARREN_CLI_RELEASE_TOKEN`: token with **contents:write** on `warren-cli`, used
  to publish the artifacts there. (A fine-grained PAT or GitHub App token.)

Signing/notarization secrets are optional; without them the artifacts are
unsigned (acceptable until Warren has signing accounts, same posture as the
GUI `release.yml`).

## Local dry-run

Linux packaging can be exercised on a Linux host (or the self-hosted runner)
without CI:

```bash
./scripts/build-daemon-only.sh        # → warren-app/dist/warren-vpn-daemon_*.deb
```
