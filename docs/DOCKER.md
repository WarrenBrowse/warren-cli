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
| `WARREN_VOUCHER_FILE` / `WARREN_VOUCHER` | | voucher redeemed at start; a redeem failure only warns (already-redeemed is normal on restart) |
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
| `WARREN_PORT_FORWARD_DOWN_COMMAND` | | run when the port is released or replaced, `{{PORT}}` substituted |
| `WARREN_PORT_FORWARD_STATUS_FILE` | `/tmp/warren/forwarded_port` | the granted public port, one decimal, rewritten on change |

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
it deliberately.

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
# from the repo root, latest release of the live (beta) channel:
docker build -f docker/Dockerfile -t warren-vpn .
# pin a channel and version:
docker build -f docker/Dockerfile \
  --build-arg WARREN_CHANNEL=prod --build-arg WARREN_DAEMON_VERSION=1.2.1 \
  -t warren-vpn .
# from a locally built .deb (see docs/INSTALL-SERVER.md, Option B):
cp warren-vpn-daemon*_*.deb docker/local-debs/
docker build -f docker/Dockerfile --build-arg LOCAL_DEB=1 -t warren-vpn .
```

`docker/test-image.sh` runs the offline smoke tests (no account needed);
with `WARREN_TEST_MNEMONIC_FILE` pointing at a subscribed phrase it also runs
the live end-to-end checks (connect, egress, kill switch, port forward).
