# warren-cli: rules for Claude Code

Distribution layer for the headless Warren client: install scripts, service
units, packaging docs and the public release home. This repo deliberately
contains no CLI source code. The `warren` CLI and `warren-daemon` live in
`warren-app` (a Mullvad fork); pushing a `daemon-vX.Y.Z` tag there runs
`warren-app/.github/workflows/release-daemon.yml`, which builds the headless
artifacts (Linux .deb/.rpm, macOS tarball, Windows zip) and publishes them as a
draft `daemon-v*` release on THIS repo, which `scripts/install.sh` resolves.

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
  `scripts/`, `macos/`, `windows/` and `docs/`.
- Local check before commit: `shellcheck -S warning scripts/*.sh macos/*.sh`.
  CI (`.github/workflows/ci.yml`) runs ShellCheck plus PSScriptAnalyzer on
  `windows/` and builds nothing.
- Local packaging (`./scripts/build-daemon-only.sh`) drives
  `warren-app/build.sh --daemon-only` and must run on Linux; from macOS use the
  release CI or a Linux container.
