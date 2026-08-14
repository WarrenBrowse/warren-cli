# warren-cli: rules for Claude Code

Distribution layer for the headless Warren client: install scripts, service
units, packaging docs and the public release home. This repo deliberately
contains no CLI source code. The `warren` CLI and `warren-daemon` live in
`warren-app` (a Mullvad fork).

**A CLI release rides on every app release, and the release is published, not
drafted.** `warren-app/.github/workflows/release-daemon.yml` is a reusable
workflow that its `release.yml` calls on every `v*` / `beta-v*` tag, and the
app's publish job requires it. It builds the headless artifacts (Linux
.deb/.rpm/tarball for both architectures, a universal macOS tarball, a Windows
zip), writes `SHA256SUMS`, asserts the set is complete and publishes the release
HERE, which `scripts/install.sh` resolves. A `daemon-v*` (prod) or
`daemon-beta-v*` (beta) tag triggers the same workflow to cut the CLI alone.

The two things that made this necessary, and that a change here must not undo:
the artifacts used to be tagged on their own series and their own cadence, so
this repo served a June build while the app shipped weekly; and the pipeline
left a DRAFT release, which the installer cannot see at all (a draft's asset
URLs answer 404 and the API does not list it).

> Shared Warren rules (single source of truth: WarrenBrowse/warren-workspace).
> They resolve when this repo is checked out inside the workspace (mani sync);
> cloned standalone, the imports just warn harmlessly.
@../shared/rules/00-conventions.md
@../shared/rules/10-tdd.md
@../shared/rules/20-errors-secrets.md
@../shared/rules/30-git-commits.md

## Repo-specific rules

- Never add or fork client source code here. Route CLI/daemon/packaging/release
  changes per the where-to-edit table in `CONTRIBUTING.md`; this repo owns only
  `scripts/`, `linux/`, `macos/`, `windows/`, `docker/` and `docs/`.
- Local check before commit: `git ls-files -z '*.sh' | xargs -0 shellcheck -S warning`
  and `sh scripts/test-install.sh`. CI (`.github/workflows/ci.yml`) runs both
  plus PSScriptAnalyzer on `windows/`, and builds nothing;
  `.github/workflows/docker.yml` builds and publishes the container image from
  the released .deb (docs/DOCKER.md).
- The installer resolves an artifact NAME out of conventions owned by the
  release pipeline in warren-app. Change one side and the other 404s on
  someone else's server, so both halves are pinned by `scripts/test-install.sh`;
  its resolution functions are sourceable (`WARREN_INSTALL_LIB=1`) precisely so
  nothing else has to re-implement them.
- Local packaging (`./scripts/build-daemon-only.sh`) drives
  `warren-app/build.sh --daemon-only` and must run on Linux; from macOS use the
  release CI or a Linux container.
