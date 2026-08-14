# Cutting a headless release

The GUI-less Warren artifacts are produced by the **`release-daemon.yml`**
workflow in the [warren-app](https://github.com/WarrenBrowse/warren-app) repo
(not yet public; it owns the build toolchain, the self-hosted runners, and the
`mullvad-build-env` composite action). This repo (`warren-cli`) provides the
install glue, the service units and the docs.

## A CLI release rides on every app release

`release-daemon.yml` is a reusable workflow that `warren-app`'s `release.yml`
calls on **every** `v*` / `beta-v*` tag, and the app's publish job requires it
to have succeeded. So a new app version always ships the matching CLI, at the
same version, built from the same commit. Nobody has to remember a second tag.

That coupling exists because the alternative was tried: the headless artifacts
had their own tag series and their own cadence, so `warren-cli` served a June
build while the app shipped weekly, and when the production API host was
retired that build was left pointing at a host answering 410.

Cutting the CLI **alone** is still possible when there is no app release to
make: push a `daemon-v*` (prod) or `daemon-beta-v*` (beta) tag on `warren-app`.
It triggers the same workflow through the same path.

## What a release contains

| Job | Runner | Output |
|---|---|---|
| `linux` | self-hosted Linux x64 | `warren-vpn-daemon[-beta]_<ver>_amd64.deb`, `_x86_64.rpm`, `warren-headless[-beta]-<ver>-linux-x86_64.tar.gz` |
| `linux-arm64` | self-hosted Linux arm64 | the same three for `arm64` / `aarch64` |
| `macos` | self-hosted macOS arm64 | `warren-headless[-beta]-<ver>-macos-universal.tar.gz` (both slices, `lipo`-joined) |
| `windows` | self-hosted Windows | `warren-headless[-beta]-<ver>-windows-x64.zip` |
| `finalise` | self-hosted Linux x64 | `SHA256SUMS`, and the **published** (non-draft) release |

The two Linux jobs each build on their own architecture; nothing is
cross-compiled. Every job publishes to a release in `warren-cli`, not in
warren-app, so the public install one-liner only needs `warren-cli` to be
public.

`finalise` is what makes a release visible: a draft release's asset URLs answer
404 and the API does not list it, so `scripts/install.sh` cannot see one. It
also asserts the artifact set is complete before publishing, because a build
job that succeeds while uploading nothing leaves a hole only the user on that
platform ever finds.

**Every platform gates**, Windows included since `daemon-beta-v1.1.15`. A
release is the whole artifact set or it is not a release: one advertising
Windows while silently shipping without its zip is the failure nobody notices
until a user cannot find their build.

## Channels

The tag shape picks the channel, and one run publishes exactly one of them
(shared rule `50-release-channels.md`):

| app tag | standalone tag | warren-cli release | artifacts |
|---|---|---|---|
| `v1.2.3` | `daemon-v1.2.3` | `daemon-v1.2.3`, latest | `warren-vpn-daemon_…`, `warren-headless-…` |
| `beta-v1.2.3` | `daemon-beta-v1.2.3` | `daemon-beta-v1.2.3`, pre-release | `warren-vpn-daemon-beta_…`, `warren-headless-beta-…` |

The two series are independent and never sort together. A beta release never
becomes the prod "latest", so an installer resolving the prod channel can never
be handed a beta build.

## Versioning

**The app and the headless client share one version space per channel.** A
number is used once, by whichever series claims it first, so a `1.1.15` app
build and a `1.1.15` CLI build can never be two different trees. Both release
paths run `warren-app/ci/check-release-version.sh`, which refuses a version that
regresses or that the other series already used, and names the next free number.

So a standalone CLI release takes the next number and the app's next release
skips past it. The guard also sorts with `sort -V`, never lexicographically:
`1.9.1` reads as newer than `1.11.0` otherwise, and that shipped a version
regression once.

A release version IS its tag. On a standalone `daemon-[beta-]vX.Y.Z` tag the
`stamp-headless-version` action writes `dist-assets/desktop-product-version.txt`
and creates a *local* `vX.Y.Z` tag so `mullvad-version` drops its `-dev-<hash>`
suffix; that tag is never pushed, so the GUI `release.yml` is not fired. A
version with a pre-release suffix (`daemon-vX.Y.Z-rc1`) keeps the `-dev`
version and is built but never published.

## Required secrets (on `warren-app`)

- `WARREN_CORE_RO_TOKEN`: read access to the sibling repos, and to check out
  `warren-cli` for the install assets.
- `WARREN_CLI_RELEASE_TOKEN`: token with **contents:write** on `warren-cli`,
  used to publish the artifacts and finalise the release there.

Signing/notarization secrets are optional; without them the artifacts are
unsigned (same posture as the GUI `release.yml`).

## Local dry-run

Linux packaging can be exercised on a Linux host without CI:

```bash
./scripts/build-daemon-only.sh        # -> warren-app/dist/warren-vpn-daemon*.deb
```

The installer's own resolution logic is testable anywhere:

```bash
sh scripts/test-install.sh
```
