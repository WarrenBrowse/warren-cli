# Contributing to warren-cli

`warren-cli` is a **distribution + docs** layer. It deliberately contains **no CLI
source code**: the `warren` CLI and `warren-daemon` live in
[warren-app](https://github.com/WarrenBrowse/warren-app) (a Mullvad VPN fork).
The `warren-app`, `warren-core` and `warrenguard` repositories are not yet
public, so changes routed there currently require access to them.
Read [`docs/SPEC.md`](docs/SPEC.md) before contributing.

## Where to make a change

| You want to change… | Edit it in… |
|---|---|
| CLI commands / behaviour / branding | `warren-app/mullvad-cli` |
| Daemon behaviour, tunnel, account API | `warren-app/mullvad-daemon` (+ `warren-core`) |
| Packaging contents (deb/rpm assets) | `warren-app/mullvad-daemon/Cargo.toml` `[package.metadata.deb]` |
| What goes into a tarball / zip bundle | `warren-app/ci/build-headless-bundle.sh` |
| Install scripts, service units, docs | **this repo** (`scripts/`, `linux/`, `macos/`, `windows/`, `docs/`) |
| Docker image (Dockerfile, entrypoint, examples) | **this repo** (`docker/`, published by `.github/workflows/docker.yml`, see `docs/DOCKER.md`) |
| Release pipeline | `warren-app/.github/workflows/release-daemon.yml` |

The split inside a bundle: `warren-app` owns the payload (binaries, resources,
the systemd units the .deb also ships), this repo owns the installers and the
service units for the init systems the packages do not cover (`linux/`).

## Local checks

```bash
shellcheck -S warning scripts/*.sh linux/*.sh macos/*.sh docker/*.sh
sh scripts/test-install.sh
# YAML: ruby -ryaml -e "YAML.load_file('.github/workflows/ci.yml')"
```

CI (`.github/workflows/ci.yml`) runs ShellCheck, the installer resolution tests
and PSScriptAnalyzer on every PR.

## Building locally

See [`docs/INSTALL-SERVER.md`](docs/INSTALL-SERVER.md) (Option B). Packaging must
run on Linux; from macOS use the release CI or a Linux container.

## Cutting a release

See [`docs/RELEASE.md`](docs/RELEASE.md): push a `daemon-v*` tag in `warren-app`.

## Conventions

- Keep this repo a thin wrapper: never fork CLI/daemon code here.
- Commit messages: single subject line, no body.
- Match the surrounding style in scripts and docs.
