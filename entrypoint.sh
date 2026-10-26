#!/usr/bin/env bash
set -euo pipefail

wg_interface=${WG_INTERFACE:-wg0}
relay_enabled=${RELAY_ENABLED:-false}
wg_started=false
relay_pid=

die() { printf 'wireguard: %s\n' "$*" >&2; exit 1; }

[[ ${1:-} != status ]] || exec /usr/local/bin/wireguard-status
[[ $# == 0 ]] || die 'usage: entrypoint.sh [status]'

valid_port() {
  [[ $1 =~ ^[1-9][0-9]{0,4}$ ]] && (( 10#$1 <= 65535 ))
}

valid_cidr() {
  local address=${1%/*} prefix=${1#*/} octet
  local -a octets
  [[ $1 =~ ^([0-9]+\.){3}[0-9]+/(0|[1-9][0-9]?)$ ]] || return 1
  (( 10#$prefix <= 32 )) || return 1
  IFS=. read -r -a octets <<< "$address"
  for octet in "${octets[@]}"; do
    [[ $octet == 0 || $octet != 0* ]] || return 1
    (( ${#octet} <= 3 && 10#$octet <= 255 )) || return 1
  done
}

cleanup() {
  local result=$?
  trap - EXIT TERM INT

  if [[ -n $relay_pid ]]; then
    kill "$relay_pid" 2>/dev/null || true
    wait "$relay_pid" 2>/dev/null || true
  fi

  if [[ $wg_started == true ]] && wg show "$wg_interface" public-key >/dev/null 2>&1; then
    wg-quick down "$wg_interface" || result=1
  fi
  exit "$result"
}

[[ $wg_interface =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,14}$ ]] || die 'invalid WG_INTERFACE'
config=/etc/wireguard/$wg_interface.conf
[[ -f $config ]] || die "missing configuration: $config"
[[ -r $config ]] || die "configuration is unreadable: $config (check numeric ownership and mode)"
if grep -Eiq '^[[:space:]]*SaveConfig[[:space:]]*=[[:space:]]*true([[:space:]]*(#.*)?)?$' "$config"; then
  die 'SaveConfig=true is incompatible with a read-only configuration mount'
fi
[[ $relay_enabled == true || $relay_enabled == false ]] || die 'RELAY_ENABLED must be true or false'
if [[ $relay_enabled == true ]]; then
  : "${RELAY_BIND_IP:?RELAY_BIND_IP is required when RELAY_ENABLED=true}"
  : "${RELAY_PORT:?RELAY_PORT is required when RELAY_ENABLED=true}"
  : "${RELAY_TARGET_HOST:?RELAY_TARGET_HOST is required when RELAY_ENABLED=true}"
  : "${RELAY_TARGET_PORT:?RELAY_TARGET_PORT is required when RELAY_ENABLED=true}"
  : "${RELAY_ALLOWED_SOURCE_CIDR:?RELAY_ALLOWED_SOURCE_CIDR is required when RELAY_ENABLED=true}"
  [[ $RELAY_BIND_IP =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ && $RELAY_BIND_IP != 0.0.0.0 ]] || die 'RELAY_BIND_IP must be a tunnel IPv4 address, not a wildcard'
  valid_port "$RELAY_PORT" || die 'RELAY_PORT must be in 1-65535'
  valid_port "$RELAY_TARGET_PORT" || die 'RELAY_TARGET_PORT must be in 1-65535'
  [[ ${#RELAY_TARGET_HOST} -le 253 && $RELAY_TARGET_HOST =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]] || die 'RELAY_TARGET_HOST must be an IPv4 address or DNS name of at most 253 characters'
  valid_cidr "$RELAY_ALLOWED_SOURCE_CIDR" || die 'RELAY_ALLOWED_SOURCE_CIDR must be an IPv4 CIDR'
fi

trap cleanup EXIT
trap 'exit 0' TERM INT

wg-quick up "$wg_interface"
wg_started=true
ip -o link show dev "$wg_interface" type wireguard | grep -q . || die "interface $wg_interface is not native WireGuard"

if [[ $relay_enabled == true ]]; then
  if ! ip -o -4 addr show dev "$wg_interface" | awk '{print $4}' | cut -d/ -f1 | grep -Fxq -- "$RELAY_BIND_IP"; then
    die 'RELAY_BIND_IP is not assigned to the WireGuard interface'
  fi
  # Allow delayed replies after a peer half-closes its input stream.
  socat -t 30 "TCP4-LISTEN:${RELAY_PORT},bind=${RELAY_BIND_IP},reuseaddr,fork,range=${RELAY_ALLOWED_SOURCE_CIDR}" \
    "TCP4:${RELAY_TARGET_HOST}:${RELAY_TARGET_PORT}" &
  relay_pid=$!
fi

while :; do
  wg show "$wg_interface" public-key >/dev/null 2>&1 || die "interface $wg_interface disappeared"
  if [[ -n $relay_pid ]] && ! kill -0 "$relay_pid" 2>/dev/null; then
    die 'relay process exited unexpectedly'
  fi
  # Waiting on a background sleep lets Bash handle termination immediately.
  sleep 2 & wait $!
done
