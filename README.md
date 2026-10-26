# WireGuard client image

This image runs a kernel WireGuard interface in its container network namespace. It can also relay TCP traffic from that tunnel to a reachable SSH server. The relay forwards bytes; the destination SSH server retains its host key, authentication, and TCP-forwarding policy. A plain client remains the default.

The base is Alpine 3.24.3, pinned to its multi-platform image digest in `Dockerfile`. CI currently builds and tests `linux/amd64`. Published image digests appear in the release workflow's job summary. Use a tested `repository@sha256:...` reference for deployment; a tag can move. The source revision is stored in the OCI `org.opencontainers.image.revision` label, and CI records the installed package versions at build time. Package repositories can change between builds, so the final image digest is the immutable release identity.

## Runtime inputs

| Variable | Default | Meaning |
| --- | --- | --- |
| `WG_INTERFACE` | `wg0` | Interface name, 1–15 letters, digits, `_`, or `-`, starting with a letter or digit. The protected configuration must be `/etc/wireguard/<name>.conf`. |
| `RELAY_ENABLED` | `false` | Set to `true` for a TCP relay. |
| `RELAY_BIND_IP` | required for relay | IPv4 address assigned to the WireGuard interface. Never omitted or silently replaced with a wildcard. |
| `RELAY_PORT` | required for relay | TCP listen port, 1–65535. Use a high port such as `2222`. |
| `RELAY_TARGET_HOST` | required for relay | IPv4 address or DNS name reachable from the container. |
| `RELAY_TARGET_PORT` | required for relay | TCP destination port, 1–65535. |
| `RELAY_ALLOWED_SOURCE_CIDR` | required for relay | One IPv4 source CIDR permitted by the relay listener. |

The configuration uses ordinary `wg-quick` Linux semantics, including any hooks, addresses, DNS, and routes in the file. Supply only trusted administrator configuration. `SaveConfig=true` is rejected because the mount is read-only. A peer with `AllowedIPs = 0.0.0.0/0` can change the container's default route; the examples use narrow routes. The image does not add host routes or manage a host firewall.

Run as container UID 0 with `NET_ADMIN`. Tested narrow configurations can use `cap_drop: [ALL]` plus `cap_add: [NET_ADMIN]`. The host must support kernel WireGuard. Interface creation may trigger host module autoload; the image neither loads modules itself nor needs `SYS_MODULE` or `/dev/net/tun`. It does not use host networking, privileged mode, the Docker socket, or published host ports. The container's own `/run` and network namespace are writable; the configuration mount stays read-only. A `0600` file must be owned by numeric UID 0 if `DAC_OVERRIDE` is dropped. Do not make a private-key file world-readable to solve an ownership mismatch.

## Plain client

The file `/secure/wg0.conf` below is a placeholder path. Its private key and peer addresses belong in a protected local file, never in Compose YAML. The container's tunnel does not automatically expose a host service.

```yaml
services:
  wireguard:
    image: ${WIREGUARD_IMAGE} # set to a tested repository@sha256:... value
    cap_drop: [ALL]
    cap_add: [NET_ADMIN]
    volumes:
      - /secure/wg0.conf:/etc/wireguard/wg0.conf:ro
    restart: "no"
```

## Tunnel-bound SSH relay

Use an interface address and allowed peer source from your own WireGuard plan. Set `RELAY_TARGET_HOST` to an address reachable from the container's bridge namespace, such as the host's reachable LAN address. `127.0.0.1` in the container is the container itself. The destination must run its own SSH server and permit any desired `ssh -L` or other forwarding. Keep normal SSH host-key verification on the client. Agent forwarding is not required.

```yaml
services:
  wireguard:
    image: ${WIREGUARD_IMAGE} # tested repository@sha256:... value
    cap_drop: [ALL]
    cap_add: [NET_ADMIN]
    environment:
      RELAY_ENABLED: "true"
      RELAY_BIND_IP: "10.77.0.2"          # example tunnel address
      RELAY_PORT: "2222"
      RELAY_TARGET_HOST: "192.0.2.10"    # placeholder, reachable SSH server
      RELAY_TARGET_PORT: "22"
      RELAY_ALLOWED_SOURCE_CIDR: "10.77.0.1/32"
    volumes:
      - /secure/wg0.conf:/etc/wireguard/wg0.conf:ro
    restart: "no"
```

The relay accepts only the configured source CIDR and listens only on the configured tunnel address. IPv4 addresses, ports, and CIDR prefixes use ordinary decimal notation without leading zeroes. After one side closes its sending stream, the relay allows up to 30 seconds for the other side to finish sending. The destination SSH server sees a new TCP connection from the relay container's egress address, not the original tunnel peer address. Apply SSH account and key policy at that server. A high relay port avoids the need for `NET_BIND_SERVICE`.

## Startup, status, and shutdown

Startup validates the image inputs and configuration mount, runs `wg-quick up` once, and verifies that the resulting interface is native WireGuard. `wg-quick` handles configuration parsing, addresses, MTU, routes, DNS, and hooks, and reports its own errors. When enabled, the relay starts only after its bind address appears. The image includes no userspace WireGuard implementation. The entrypoint exits nonzero if setup fails, its owned interface disappears, or the relay listener dies. SIGTERM/SIGINT stops the relay and runs `wg-quick down` for the interface this instance created. Active relay connections end when the container stops.

`wg-quick` stdout and stderr, including hook output, go directly to the container logs during startup and shutdown. Tool errors may include configuration values. The wrapper also reports interface and listener readiness; the relay does not log forwarded SSH payload. To inspect current local state without private keys:

```sh
docker exec <container> wireguard-status
docker exec <container> ip -d link show wg0
docker exec <container> wg show wg0 latest-handshakes
```

`status` reports interface presence and the relay listening socket. A recent handshake indicates peer activity, but an old handshake can also mean an idle peer. Docker does not automatically restart an unhealthy but still running container. Validate reachability from the intended peer separately.

Runtime code is split by responsibility: `entrypoint.sh` owns startup, traps, process IDs and supervision; `lib/wireguard.sh` handles config-mount and interface checks; `lib/relay.sh` handles relay validation and listener operations; `status.sh` provides the `wireguard-status` command. The libraries define functions without performing startup work when sourced. `entrypoint.sh status` remains an alias for the standalone status command.

## Compatibility and CI

Existing `/etc/wireguard/wg0.conf` mounts work with the default plain-client mode. The new entrypoint exits when the interface cannot be created and cleans it up on shutdown. `SaveConfig=true` is no longer accepted. The image keeps `iptables` for existing trusted `wg-quick` hooks; the relay itself requires no NAT rules.

Pull requests build and run disposable Linux tests without registry credentials. Tests cover native interface creation, peer handshake and data, the plain client, relay binding and source restriction, delayed replies after TCP half-close, SSH identity/authentication/forwarding, concurrent sessions, child failure, read-only configuration, restart, and invalid inputs. Publication on `main` or a version tag waits for the tests and loads the exact tested image from a workflow artifact. Docker Hub publishes on `main`; GHCR publishes on `main` and version tags. A passing CI run proves behavior on its Linux runner, not on a particular NAS kernel or SSH policy.

To run the same tests on a disposable x86_64 Linux Docker host with kernel WireGuard available, build `wireguard:test` and run `bash tests/runtime.sh`. The harness requires passwordless `sudo` to set root ownership on protected mounts. It creates an isolated Docker bridge, two containers, disposable keys, and a test-only OpenSSH fixture; it removes those runtime resources at exit. Never run this harness against a production Docker context. Image builds fetch packages from Alpine repositories.
