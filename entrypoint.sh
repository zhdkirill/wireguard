#!/usr/bin/env bash
set -Eeuo pipefail

wg_interface=${WG_INTERFACE:-wg0}
relay_enabled=${RELAY_ENABLED:-false}
config=/etc/wireguard/${wg_interface}.conf
owned=0
owned_index=
probe_owned=0
relay_pid=

log() { printf 'wireguard: %s\n' "$*" >&2; }
die() { log "$*"; exit 1; }

valid_ipv4() {
  local ip=$1 part
  local -a parts
  [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  IFS=. read -r -a parts <<< "$ip"
  for part in "${parts[@]}"; do
    (( ${#part} <= 3 && 10#$part <= 255 )) || return 1
    [[ $part == 0 || $part != 0* ]] || return 1
  done
}

valid_port() {
  [[ $1 =~ ^[1-9][0-9]{0,4}$ ]] && (( 10#$1 <= 65535 ))
}

valid_cidr() {
  local ip prefix
  [[ $1 == */* ]] || return 1
  ip=${1%/*}
  prefix=${1#*/}
  valid_ipv4 "$ip" && [[ $prefix =~ ^(0|[1-9][0-9]?)$ ]] && (( 10#$prefix <= 32 ))
}

validate() {
  [[ $wg_interface =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,14}$ ]] || die 'WG_INTERFACE must start with a letter or digit and use 1-15 letters, digits, underscores, or hyphens'
  [[ $relay_enabled == true || $relay_enabled == false ]] || die 'RELAY_ENABLED must be true or false'
  [[ -f $config ]] || die "missing configuration: $config"
  [[ -r $config ]] || die "configuration is unreadable: $config (check numeric ownership and mode)"
  if grep -Eiq '^[[:space:]]*SaveConfig[[:space:]]*=[[:space:]]*true([[:space:]]*(#.*)?)?$' "$config"; then
    die 'SaveConfig=true is incompatible with a read-only configuration mount'
  fi
  wg-quick strip "$wg_interface" >/dev/null 2>&1 || die 'invalid WireGuard configuration'
  if [[ $relay_enabled == true ]]; then
    : "${RELAY_BIND_IP:?RELAY_BIND_IP is required when RELAY_ENABLED=true}"
    : "${RELAY_PORT:?RELAY_PORT is required when RELAY_ENABLED=true}"
    : "${RELAY_TARGET_HOST:?RELAY_TARGET_HOST is required when RELAY_ENABLED=true}"
    : "${RELAY_TARGET_PORT:?RELAY_TARGET_PORT is required when RELAY_ENABLED=true}"
    : "${RELAY_ALLOWED_SOURCE_CIDR:?RELAY_ALLOWED_SOURCE_CIDR is required when RELAY_ENABLED=true}"
    valid_ipv4 "$RELAY_BIND_IP" && [[ $RELAY_BIND_IP != 0.0.0.0 ]] || die 'RELAY_BIND_IP must be a tunnel IPv4 address, not a wildcard'
    valid_port "$RELAY_PORT" || die 'RELAY_PORT must be in 1-65535'
    [[ ${#RELAY_TARGET_HOST} -le 253 && $RELAY_TARGET_HOST =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]] || die 'RELAY_TARGET_HOST must be an IPv4 address or DNS name of at most 253 characters'
    valid_port "$RELAY_TARGET_PORT" || die 'RELAY_TARGET_PORT must be in 1-65535'
    valid_cidr "$RELAY_ALLOWED_SOURCE_CIDR" || die 'RELAY_ALLOWED_SOURCE_CIDR must be an IPv4 CIDR'
  fi
}

cleanup() {
  local result=$?
  trap - EXIT TERM INT
  if [[ -n $relay_pid ]]; then
    kill "$relay_pid" 2>/dev/null || true
    wait "$relay_pid" 2>/dev/null || true
  fi
  if (( owned )); then
    if [[ ! -r /sys/class/net/$wg_interface/ifindex ]] || [[ $(cat "/sys/class/net/$wg_interface/ifindex") != "$owned_index" ]]; then
      log "interface $wg_interface was removed or replaced; refusing to remove another interface"
      (( result != 0 )) || result=1
    elif ! wg-quick down "$wg_interface" >/dev/null 2>&1; then
      log "failed to remove instance-owned interface $wg_interface"
      (( result != 0 )) || result=1
    fi
  elif (( probe_owned )); then
    if ! ip link del dev "$wg_interface" 2>/dev/null; then
      log "failed to remove probe interface $wg_interface"
      (( result != 0 )) || result=1
    fi
  fi
  exit "$result"
}

status() {
  [[ $wg_interface =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,14}$ ]] || die 'invalid WG_INTERFACE'
  if wg show "$wg_interface" public-key >/dev/null 2>&1; then
    printf 'mode=kernel interface=%s state=present\n' "$wg_interface"
  else
    printf 'mode=kernel interface=%s state=absent\n' "$wg_interface"
    return 1
  fi
  if [[ $relay_enabled == true ]]; then
    if ss -H -lnt "sport = :${RELAY_PORT:-0}" 2>/dev/null | grep -Fq "${RELAY_BIND_IP:-invalid}:${RELAY_PORT:-0}"; then
      printf 'relay=listening bind=%s:%s\n' "$RELAY_BIND_IP" "$RELAY_PORT"
    else
      printf 'relay=not-listening\n'
      return 1
    fi
  else
    printf 'relay=disabled\n'
  fi
}

if [[ ${1:-} == status ]]; then
  status
  exit
fi
[[ $# == 0 ]] || die 'usage: entrypoint.sh [status]'
validate
trap cleanup EXIT
trap 'exit 0' TERM INT

if ip link show dev "$wg_interface" >/dev/null 2>&1; then
  die "interface $wg_interface already exists; refusing to change it"
fi
if ! ip link add dev "$wg_interface" type wireguard 2>/dev/null; then
  die 'cannot create a kernel WireGuard interface (check host support and NET_ADMIN)'
fi
probe_owned=1
if ! ip link del dev "$wg_interface" 2>/dev/null; then
  die "cannot remove probe interface $wg_interface"
fi
probe_owned=0
if ! wg-quick up "$wg_interface" >/dev/null 2>&1; then
  die "wg-quick failed for $wg_interface (check config, routes, hooks, and permissions)"
fi
owned=1
owned_index=$(cat "/sys/class/net/$wg_interface/ifindex")
log "mode=kernel interface=$wg_interface state=ready"

if [[ $relay_enabled == true ]]; then
  if ! ip -o -4 addr show dev "$wg_interface" | awk '{print $4}' | cut -d/ -f1 | grep -Fxq -- "$RELAY_BIND_IP"; then
    die 'RELAY_BIND_IP is not assigned to the WireGuard interface'
  fi
  # Allow delayed replies after a peer half-closes its input stream.
  socat -t 30 "TCP4-LISTEN:${RELAY_PORT},bind=${RELAY_BIND_IP},reuseaddr,fork,range=${RELAY_ALLOWED_SOURCE_CIDR}" \
    "TCP4:${RELAY_TARGET_HOST}:${RELAY_TARGET_PORT}" &
  relay_pid=$!
  for _ in 1 2 3 4 5; do
    if ! kill -0 "$relay_pid" 2>/dev/null; then
      die 'relay process exited during startup'
    fi
    if ss -H -lnt "sport = :${RELAY_PORT}" | grep -Fq "${RELAY_BIND_IP}:${RELAY_PORT}"; then
      log "relay=listening bind=${RELAY_BIND_IP}:${RELAY_PORT}"
      break
    fi
    sleep 1
  done
  ss -H -lnt "sport = :${RELAY_PORT}" | grep -Fq "${RELAY_BIND_IP}:${RELAY_PORT}" || die 'relay did not become ready'
fi

while :; do
  [[ -r /sys/class/net/$wg_interface/ifindex ]] && [[ $(cat "/sys/class/net/$wg_interface/ifindex") == "$owned_index" ]] || die "interface $wg_interface disappeared or was replaced"
  if [[ -n $relay_pid ]] && ! kill -0 "$relay_pid" 2>/dev/null; then
    die 'relay process exited unexpectedly'
  fi
  sleep 2 & wait $!
done
