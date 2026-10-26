#!/usr/bin/env bash
set -Eeuo pipefail

image=${IMAGE:-wireguard:test}
prefix=wg-test-$$
work=$(mktemp -d)
network=${prefix}-net
server=${prefix}-server
client=${prefix}-client
fixture=${prefix}-ssh
holder=${prefix}-holder
umask 077

cleanup() {
  docker rm -f "$holder" "$client" "$server" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ready() {
  local name=$1 expected=$2
  for _ in $(seq 1 15); do
    if docker exec "$name" /usr/local/bin/entrypoint.sh status 2>/dev/null | grep -q "$expected"; then
      return 0
    fi
    sleep 1
  done
  docker logs "$name" >&2 || true
  fail "$name did not become ready"
}

docker network create "$network" >/dev/null
docker build -q -t "$fixture" --build-arg "BASE_IMAGE=$image" -f tests/sshd.Dockerfile . >/dev/null
server_key=$(docker run --rm --entrypoint wg "$image" genkey)
client_key=$(docker run --rm --entrypoint wg "$image" genkey)
server_pub=$(printf '%s\n' "$server_key" | docker run --rm -i --entrypoint wg "$image" pubkey)
client_pub=$(printf '%s\n' "$client_key" | docker run --rm -i --entrypoint wg "$image" pubkey)

cat >"$work/server.conf" <<EOF
[Interface]
PrivateKey = $server_key
Address = 10.77.0.1/30
ListenPort = 51820
PostUp = printf 'wg-up-stdout\n'; printf 'wg-up-stderr\n' >&2
PostDown = printf 'wg-down-stdout\n'; printf 'wg-down-stderr\n' >&2

[Peer]
PublicKey = $client_pub
AllowedIPs = 10.77.0.2/32
EOF
chmod 0600 "$work/server.conf"
server_before=$(sha256sum "$work/server.conf" | cut -d' ' -f1)
# The container runs as root with only NET_ADMIN; it must own the protected file.
sudo chown 0:0 "$work/server.conf"
docker run -d --name "$server" --network "$network" --cap-add NET_ADMIN \
  -v "$work/server.conf:/etc/wireguard/wg0.conf:ro" "$fixture" >/dev/null
ready "$server" 'relay=disabled'
docker logs "$server" 2>&1 | grep -q '^wg-up-stdout$' || fail 'wg-quick stdout was hidden'
docker logs "$server" 2>&1 | grep -q '^wg-up-stderr$' || fail 'wg-quick stderr was hidden'
docker exec "$server" /usr/local/bin/wireguard-status | grep -q 'relay=disabled' || fail 'standalone status failed'
server_ip=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$network\").IPAddress}}" "$server")

cat >"$work/client.conf" <<EOF
[Interface]
PrivateKey = $client_key
Address = 10.77.0.2/30

[Peer]
PublicKey = $server_pub
Endpoint = $server_ip:51820
AllowedIPs = 10.77.0.1/32
PersistentKeepalive = 1
EOF
chmod 0600 "$work/client.conf"
before=$(sha256sum "$work/client.conf" | cut -d' ' -f1)
cp "$work/client.conf" "$work/unreadable.conf"
sudo chown 0:0 "$work/client.conf"

docker run -d --name "$client" --network "$network" --cap-drop ALL --cap-add NET_ADMIN \
  -v "$work/client.conf:/etc/wireguard/wg0.conf:ro" \
  -e RELAY_ENABLED=true -e RELAY_BIND_IP=10.77.0.2 -e RELAY_PORT=2222 \
  -e "RELAY_TARGET_HOST=$server_ip" -e RELAY_TARGET_PORT=22 \
  -e RELAY_ALLOWED_SOURCE_CIDR=10.77.0.1/32 "$image" >/dev/null
ready "$client" 'relay=listening'
docker exec "$client" ip -d link show wg0 | grep -q wireguard || fail 'interface is not native WireGuard'

# Exchange real data and require a recorded handshake.
docker exec -d "$server" sh -c 'nc -l -p 9876 > /tmp/wg-data'
docker exec "$client" sh -c 'printf tunnel-data | nc -w 3 10.77.0.1 9876'
for _ in $(seq 1 10); do
  if docker exec "$server" cat /tmp/wg-data 2>/dev/null | grep -q '^tunnel-data$'; then break; fi
  sleep 1
done
docker exec "$server" cat /tmp/wg-data | grep -q '^tunnel-data$' || fail 'tunnel data missing'
docker exec "$client" wg show wg0 latest-handshakes | awk '{if ($2 > 0) found=1} END {exit !found}' || fail 'no WireGuard handshake'

# A TCP half-close must preserve a reply delayed longer than socat's default drain.
docker exec -i "$server" sh -c 'cat > /tmp/halfclose.sh' <<'EOF'
cat > /tmp/halfclose-input
sleep 1
printf halfclose-response
EOF
docker exec -d "$server" socat -t 5 TCP4-LISTEN:22,reuseaddr 'EXEC:/bin/sh /tmp/halfclose.sh'
for _ in $(seq 1 10); do
  docker exec "$server" ss -H -lnt 'sport = :22' | grep -q ':22' && break
  sleep 1
done
reply=$(printf halfclose-request | docker exec -i "$server" socat -t 5 - TCP4:10.77.0.2:2222)
[[ $reply == halfclose-response ]] || fail 'half-close lost delayed response'
docker exec "$server" cat /tmp/halfclose-input | grep -q '^halfclose-request$' || fail 'half-close request missing'
for _ in $(seq 1 10); do
  if ! docker exec "$server" ss -H -lnt 'sport = :22' | grep -q ':22'; then break; fi
  sleep 1
done

docker exec "$server" sh -c 'mkdir -p /run/sshd /root/.ssh && chmod 700 /root/.ssh && ssh-keygen -q -N "" -f /tmp/id_ed25519 && cp /tmp/id_ed25519.pub /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys && ssh-keygen -A'
docker exec -d "$server" /usr/sbin/sshd -D -e -o PermitRootLogin=yes -o PasswordAuthentication=no -o PubkeyAuthentication=yes -o AllowTcpForwarding=yes
for _ in $(seq 1 10); do
  docker exec "$server" sh -c 'ssh-keyscan -T 1 -t ed25519 127.0.0.1 2>/dev/null' | grep -q ssh-ed25519 && break
  sleep 1
done
direct_key=$(docker exec "$server" sh -c 'ssh-keyscan -T 3 -t ed25519 127.0.0.1 2>/dev/null' | awk '$2=="ssh-ed25519" {print $3}')
relay_key=$(docker exec "$server" sh -c 'ssh-keyscan -T 3 -p 2222 -t ed25519 10.77.0.2 2>/dev/null' | awk '$2=="ssh-ed25519" {print $3}')
[[ -n $direct_key && $direct_key == "$relay_key" ]] || fail 'relay changed the SSH host identity'
client_ip=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$network\").IPAddress}}" "$client")
bridge_key=$(docker exec "$server" ssh-keyscan -T 2 -p 2222 -t ed25519 "$client_ip" 2>/dev/null || true)
[[ -z $bridge_key ]] || fail 'relay is reachable on the bridge address'
ssh_args=(-i /tmp/id_ed25519 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/tmp/known_hosts -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 -p 2222)
docker exec "$server" ssh "${ssh_args[@]}" root@10.77.0.2 true || fail 'SSH authentication through relay failed'
docker exec "$server" ssh "${ssh_args[@]}" root@10.77.0.2 true & a=$!
docker exec "$server" ssh "${ssh_args[@]}" root@10.77.0.2 true & b=$!
wait "$a" && wait "$b" || fail 'concurrent SSH sessions failed'

docker exec -d "$server" sh -c 'printf forwarded-data | nc -l -p 9877'
docker exec "$server" ssh "${ssh_args[@]}" -o ExitOnForwardFailure=yes -f -N \
  -L 127.0.0.1:19877:127.0.0.1:9877 root@10.77.0.2
docker exec "$server" sh -c 'timeout 5 nc 127.0.0.1 19877' | grep -q '^forwarded-data$' || fail 'SSH local forwarding failed'
if docker exec "$client" sh -c 'timeout 3 nc 10.77.0.2 2222' 2>/dev/null | grep -q '^SSH-'; then
  fail 'disallowed local source reached the SSH target'
fi

docker exec "$client" sh -c 'kill $(pidof socat)'
exit_code=$(timeout 15 docker wait "$client")
[[ $exit_code != 0 ]] || fail 'relay death did not fail the service'
docker run -d --name "$holder" --network "container:$server" --cap-drop ALL \
  --entrypoint sleep "$image" infinity >/dev/null
docker stop -t 5 "$server" >/dev/null
[[ $(docker inspect -f '{{.State.ExitCode}}' "$server") == 0 ]] || fail 'graceful stop failed'
docker logs "$server" 2>&1 | grep -q '^wg-down-stdout$' || fail 'wg-quick shutdown stdout was hidden'
docker logs "$server" 2>&1 | grep -q '^wg-down-stderr$' || fail 'wg-quick shutdown stderr was hidden'
if docker exec "$holder" ip link show dev wg0 >/dev/null 2>&1; then
  fail 'graceful stop left its interface in the shared namespace'
fi
docker rm -f "$holder" >/dev/null
docker start "$server" >/dev/null
ready "$server" 'relay=disabled'
docker start "$client" >/dev/null
ready "$client" 'relay=listening'
docker exec "$client" ip link del dev wg0
exit_code=$(timeout 15 docker wait "$client")
[[ $exit_code != 0 ]] || fail 'interface loss did not fail the service'
docker stop -t 5 "$server" >/dev/null
after=$(sudo sha256sum "$work/client.conf" | cut -d' ' -f1)
[[ $before == "$after" ]] || fail 'read-only configuration changed'
server_after=$(sudo sha256sum "$work/server.conf" | cut -d' ' -f1)
[[ $server_before == "$server_after" ]] || fail 'server configuration changed on shutdown'

if timeout 15 docker run --rm --cap-drop ALL -v "$work/server.conf:/etc/wireguard/wg0.conf:ro" "$image" >"$work/no-cap.log" 2>&1; then
  fail 'startup succeeded without NET_ADMIN'
fi
grep -Eq 'Operation not permitted|Permission denied' "$work/no-cap.log" || fail 'native permission error was hidden'
if timeout 15 docker run --rm --cap-drop ALL --cap-add NET_ADMIN -e RELAY_ENABLED=invalid \
  -v "$work/server.conf:/etc/wireguard/wg0.conf:ro" "$image" >"$work/invalid.log" 2>&1; then
  fail 'invalid relay selector succeeded'
fi
grep -q 'RELAY_ENABLED must be true or false' "$work/invalid.log" || fail 'invalid selector error missing'
if timeout 15 docker run --rm --cap-drop ALL --cap-add NET_ADMIN -e RELAY_ENABLED=true \
  -e RELAY_BIND_IP=10.77.0.1 -e RELAY_PORT=2222 -e RELAY_TARGET_HOST=127.0.0.1 \
  -e RELAY_TARGET_PORT=22 -e RELAY_ALLOWED_SOURCE_CIDR=bad \
  -v "$work/server.conf:/etc/wireguard/wg0.conf:ro" "$image" >"$work/invalid-cidr.log" 2>&1; then
  fail 'invalid source CIDR succeeded'
fi
grep -q 'RELAY_ALLOWED_SOURCE_CIDR must be an IPv4 CIDR' "$work/invalid-cidr.log" || fail 'invalid CIDR error missing'
if timeout 15 docker run --rm --cap-drop ALL "$image" >"$work/missing.log" 2>&1; then
  fail 'missing configuration succeeded'
fi
grep -q 'missing configuration' "$work/missing.log" || fail 'missing config error missing'
if timeout 15 docker run --rm --cap-drop ALL --cap-add NET_ADMIN \
  -v "$work/unreadable.conf:/etc/wireguard/wg0.conf:ro" "$image" >"$work/unreadable.log" 2>&1; then
  fail 'wrong-owner 0600 configuration was readable with DAC_OVERRIDE dropped'
fi
grep -q 'configuration is unreadable' "$work/unreadable.log" || fail 'ownership error missing'
printf '[Interface]\nPrivateKey = deliberately-invalid-key\n' >"$work/malformed.conf"
sudo chown 0:0 "$work/malformed.conf"
if timeout 15 docker run --rm --cap-drop ALL --cap-add NET_ADMIN \
  -v "$work/malformed.conf:/etc/wireguard/wg0.conf:ro" "$image" >"$work/malformed.log" 2>&1; then
  fail 'malformed configuration succeeded'
fi
grep -Eiq 'key.*(length|format)|configuration parsing error' "$work/malformed.log" || fail 'WireGuard config diagnostic was hidden'
printf '[Interface]\nSaveConfig = true\n' >"$work/save.conf"
sudo chown 0:0 "$work/save.conf"
if timeout 15 docker run --rm --cap-drop ALL --cap-add NET_ADMIN \
  -v "$work/save.conf:/etc/wireguard/wg0.conf:ro" "$image" >"$work/save.log" 2>&1; then
  fail 'SaveConfig=true was accepted'
fi
grep -q 'SaveConfig=true is incompatible' "$work/save.log" || fail 'SaveConfig error missing'
printf 'PASS: kernel tunnel, relay SSH, forwarding, confinement, lifecycle, and validation\n'
