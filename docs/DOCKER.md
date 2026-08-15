# Warren VPN in Docker

`ghcr.io/warrenbrowse/warren-vpn` runs the headless Warren client (the same
`warren-daemon` + `warren` CLI the server packages install) inside a container,
in the shape popularized by gluetun: one container owns the tunnel, the kill
switch and the network namespace; everything that must ride the VPN joins that
namespace with `network_mode: "service:warren"` (compose) or as a pod sidecar
(Kubernetes).

Because Warren is neither WireGuard nor OpenVPN, generic VPN containers cannot
carry it; this image is the supported way to run Warren on anything that runs
containers: Linux servers, Synology (Container Manager), QNAP (Container
Station), Unraid, TrueNAS, Kubernetes.

## Image tags: one per release channel

The shared release-channel contract applies: one image publish carries exactly
one channel, and the two series never overwrite each other.

| channel | release series | image tags |
|---|---|---|
| beta (the live network today) | `daemon-beta-v*` | `:beta-<ver>`, rolling `:beta` |
| prod (opens with production) | `daemon-v*` | `:<ver>`, rolling `:latest` |

Use `:beta` until production opens; the examples do. The container itself is
channel-neutral glue: the channel is baked into the daemon binaries the image
repackages (API host, state paths, firewall id), never into the entrypoint.

**Availability: the published image is not public yet.** Until the GHCR package
is made public, a plain `docker pull ghcr.io/warrenbrowse/warren-vpn:beta`
answers `unauthorized`. Build it locally under that exact name (see
[Building locally](#building-locally)) so every command and example below runs
unchanged:

```bash
./docker/build.sh -t ghcr.io/warrenbrowse/warren-vpn:beta
```

This section will switch to the direct pull once the package is public.

## Quick start

```bash
printf '%s' "your 12 or 24 word recovery phrase" > warren_mnemonic.txt
docker run -d --name warren \
  --cap-add NET_ADMIN --device /dev/net/tun \
  -v "$PWD/warren_mnemonic.txt:/run/secrets/warren_mnemonic:ro" \
  -e WARREN_MNEMONIC_FILE=/run/secrets/warren_mnemonic \
  ghcr.io/warrenbrowse/warren-vpn:beta

# Anything else through the tunnel:
docker run --rm --network container:warren curlimages/curl https://icanhazip.com
```

The container exits when the tunnel cannot be established (bad phrase, no
subscription, no network); use `restart: unless-stopped` and read
`docker logs warren`. When the daemon dies the namespace dies with it: there
is no window where traffic can bypass a dead kill switch.

Compose examples live in `docker/examples/`:
[`docker-compose.yml`](../docker/examples/docker-compose.yml) (minimal),
[`docker-compose.qbittorrent.yml`](../docker/examples/docker-compose.qbittorrent.yml)
(port forwarding with the up-command hook),
[`k8s-sidecar.yaml`](../docker/examples/k8s-sidecar.yaml) (Kubernetes).

## Environment reference

| variable | default | meaning |
|---|---|---|
| `WARREN_MNEMONIC_FILE` / `WARREN_MNEMONIC` | | recovery phrase; the file variant wins and is the one to use (a plain env var is visible in `docker inspect`) |
| `WARREN_VOUCHER_FILE` / `WARREN_VOUCHER` | | voucher redeemed at start; a redeem failure only warns (already-redeemed is normal on restart). The CLI takes the code as an argument, so it is readable in the container's process list for as long as the redeem runs; the recovery phrase is not (it goes in on stdin) |
| `WARREN_RELAY_LOCATION` | any | exit constraint, passed to `warren relay set location` verbatim (e.g. `fi`, `fi hel`) |
| `WARREN_LOCKDOWN` | `on` | kill switch (lockdown mode). Leave it on |
| `WARREN_LAN` | `allow` | local network sharing; sidecars and published ports need it |
| `WARREN_ALLOW_INACTIVE` | `off` | `on` keeps the container up without an active subscription (tunnel connects, traffic will not egress) |
| `WARREN_CONNECT_TIMEOUT` | `90` | seconds to wait for the first connect |
| `WARREN_HEALTH_TARGET` | | optional URL; when set the health check also probes real egress against it |
| `WARREN_PORT_FORWARD_INTERNAL_PORT` | | setting it enables NAT-PMP port forwarding for that internal port |
| `WARREN_PORT_FORWARD_PROTOCOL` | `both` | `tcp`, `udp` or `both` |
| `WARREN_PORT_FORWARD_EXTERNAL_PORT` | `0` | suggested public port (49152-65535), 0 lets the exit pick |
| `WARREN_PORT_FORWARD_LIFETIME` | | requested mapping lifetime in seconds, exit clamps to [60, 3600] |
| `WARREN_PORT_FORWARD_MATCH_INTERNAL` | `on` | after a grant of public port P, re-point the rule to internal P so the app can listen and announce on the same port (torrent clients need this) |
| `WARREN_PORT_FORWARD_UP_COMMAND` | | run (via `sh -c`, inside this container) each time a public port is granted, `{{PORT}}` substituted |
| `WARREN_PORT_FORWARD_DOWN_COMMAND` | | run with the port that is going away, `{{PORT}}` substituted: when a new grant replaces it, when the exit stops serving the mapping, and at shutdown |
| `WARREN_PORT_FORWARD_STATUS_FILE` | `/tmp/warren/forwarded_port` | the granted public port, one decimal, rewritten on change |
| `WARREN_PORT_HOOK_TIMEOUT` | `30` | seconds a hook may run before it, and what it started, are killed (SIGTERM, then SIGKILL 5s later) |
| `WARREN_PORT_HOOK_SHUTDOWN_TIMEOUT` | `5` | same bound on the stop path; keep it well under the orchestrator's stop grace so the disconnect still runs |

Every knob with a closed vocabulary (`on`/`off`, `allow`/`block`,
`tcp`/`udp`/`both`) refuses a value it does not know and the container stops:
`WARREN_LOCKDOWN=ON` is a typo, and reading it as `off` would run the whole
container with the kill switch down while the log reported a value nobody set.

## Port forwarding

Warren's port forwarding is NAT-PMP with entitlement credentials (5 ports per
subscription fleet-wide, public range 49152-65535). In this image:

1. `WARREN_PORT_FORWARD_INTERNAL_PORT=6881` enables it.
2. When the exit grants a public port, the entrypoint writes it to
   `/tmp/warren/forwarded_port` and runs your
   `WARREN_PORT_FORWARD_UP_COMMAND` with `{{PORT}}` replaced, so you can push
   the port into the application, gluetun-style:

   ```yaml
   - >-
     WARREN_PORT_FORWARD_UP_COMMAND=curl -fsS --retry 10 --retry-connrefused
     --data-urlencode 'json={"listen_port":{{PORT}},"random_port":false,"upnp":false}'
     http://127.0.0.1:8080/api/v2/app/setPreferences
   ```

3. With `WARREN_PORT_FORWARD_MATCH_INTERNAL=on` (the default) the forward
   rule is then re-pointed to that same port, so after one convergence step
   the application listens, announces and is reachable on one identical port.
   Set it to `off` to keep a fixed internal port instead.

The granted port can change when the mapping is re-established; the watcher
re-runs the down/up commands and rewrites the status file each time.

When the exit stops serving the mapping (a `failed` or `disabled` status line
for this container's rule), the down command runs once, the status file is
emptied so nothing keeps reading a port that no longer exists, and the rule
goes back to a server-picked public port. That last step matters because a
pinned port is a contract the daemon never substitutes: the rule the re-point
installs asks for one exact port, and if another client is holding it the
mapping stays failed for the container's whole life unless something asks for
a different one.

Three things the container guarantees around those hooks:

- **One rule per container.** The daemon persists its forward rules, and
  `enable` upserts rather than replaces, so a rule re-pointed by a previous
  run would come back next to the configured one. The entrypoint clears the
  rule list before enabling, so the container always holds exactly one of the
  five fleet-wide entitlement slots and the watcher never sees two different
  granted ports competing.
- **A hook cannot hang the container.** Hooks run under
  `WARREN_PORT_HOOK_TIMEOUT` (30s) and are killed past it. Without that bound
  a hook that never returns stops the watcher from consuming status updates,
  so every later grant is ignored while the status file keeps announcing a
  port the exit no longer maps.
- **The status line has to be ours.** The daemon prints one line per rule;
  only the line whose internal port is the one this container forwards drives
  the status file and the hooks.
- **The watcher cannot die quietly.** It is restarted with a growing backoff
  and each restart is logged. Five quick deaths in a row stop the container
  (down command, disconnect, non-zero exit): a container that has lost port
  tracking keeps an application pointed at a port the exit can reassign, and
  nothing else in the stack would notice.

The example's up-command talks to qBittorrent's Web API, which needs a
session: it logs in first, with credentials from a `.env` file. Recent
qBittorrent authenticates localhost too, and the linuxserver image sets a
random temporary WebUI password on first start, so an unauthenticated POST
gets a 403 and the only symptom is one `WARNING: port-forward up command
failed` line under a container that stays healthy.

## Health

The Docker `HEALTHCHECK` (and the Kubernetes probes in the example) run
`warren status` and require `Connected`. Compose consumers should gate on it:

```yaml
depends_on:
  warren:
    condition: service_healthy
```

`WARREN_HEALTH_TARGET=https://example.org` adds a real egress probe. It is
off by default: a periodic fetch to a fixed host is a fingerprint, opt into
it deliberately. It also makes the health check slower (`curl --max-time 10`
on top of the daemon query), so raise the probe timeouts if you enable it:
the Docker `HEALTHCHECK` already allows 15s, while the Kubernetes default
`timeoutSeconds` is 1 and the example manifest raises it explicitly.

## Sharing the namespace: two ordering traps

**Restarting warren replaces the network namespace.** Docker gives the
restarted container a new one, and every service that joined the old one keeps
a handle on a destroyed namespace: no connectivity, no error, indefinitely.
The warren container does exit when the tunnel cannot be established, so this
is a normal event, not an edge case. `depends_on` orders the start and does
not follow a restart, so after any warren restart the joined services must be
restarted too:

```bash
docker compose restart qbittorrent
```

**In Kubernetes, ordinary pod containers start concurrently.** A warren listed
under `containers` therefore races the workload, which egresses with the
node's real IP for the whole bring-up (daemon boot, login, subscription check,
connect), before any firewall rule exists in the pod netns. The example
manifest declares warren as a **native sidecar** (an `initContainer` with
`restartPolicy: Always`, Kubernetes 1.29 or newer): the kubelet starts it
first, holds the workload containers until its `startupProbe` passes, and
restarts it in place. On an older cluster there is no equivalent primitive:
either the workload blocks on its own gate (an init container running
`/usr/local/bin/warren-healthcheck`) or it carries that leak window on every
pod start, rollout and reschedule. A `startupProbe` on the warren container
gates nothing but that container.

## State, secrets, caveats

- **Mnemonic storage degrades to a plaintext file in containers.** The daemon
  seals the phrase with `systemd-creds` (TPM2) on real hosts; inside a
  container that machinery does not exist, so it falls back to a root-only
  plaintext file under `/etc/warren-vpn-beta` (beta) or `/etc/warren-vpn`
  (prod). Prefer `WARREN_MNEMONIC_FILE` with a compose/Kubernetes secret, do
  not bake the phrase into images or env defaults, and treat any persisted
  state volume as secret material.
- **State volume is optional.** Persist `/etc/warren-vpn-beta` and
  `/var/cache/warren-vpn-beta` (drop `-beta` on the prod image) to keep
  login, settings and the relay cache across recreates; or persist nothing
  and let the entrypoint log in from the secret every start (the container
  is then fully disposable).
- The image needs `--cap-add NET_ADMIN` and `--device /dev/net/tun`; it uses
  nftables inside its own namespace and never touches the host firewall.
- DNS inside the namespace is rewritten to the in-tunnel resolver by the
  daemon (static resolv.conf backend; no DBus in the container).
- Architectures: `linux/amd64` and `linux/arm64` (both are built natively by
  the daemon release pipeline; the image manifest carries whichever arches
  the packaged release shipped).

## Building locally

```bash
# latest release of the live (beta) channel:
./docker/build.sh -t warren-vpn
# pin a channel and version:
./docker/build.sh --channel prod --version 1.2.1 -t warren-vpn
# from a locally built .deb (see docs/INSTALL-SERVER.md, Option B):
cp warren-vpn-daemon*_*.deb docker/local-debs/
./docker/build.sh --local-deb -t warren-vpn
```

`docker/build.sh` resolves the release version and passes it to the build as
`--build-arg WARREN_DAEMON_VERSION`, because that is what puts the daemon
version in Docker's cache key. Resolving "the latest release" from inside the
Dockerfile would not: the same `docker build` command, run again after a
daemon release, would reuse the cached layer and reship the daemon downloaded
weeks earlier, with nothing in the output to tell the two runs apart. The
Dockerfile therefore refuses a build that pins no version.

Tests, none of which needs an account or a network:

```bash
sh docker/test-entrypoint.sh   # the entrypoint's helpers
sh docker/test-build.sh        # version resolution and build arguments
sh docker/test-examples.sh     # the example manifests (needs ruby)
```

`docker/test-image.sh` runs the offline smoke tests against a built image;
with `WARREN_TEST_MNEMONIC_FILE` pointing at a subscribed phrase it also runs
the live end-to-end checks (connect, egress, kill switch, port forward).
