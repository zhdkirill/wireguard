#!/usr/bin/env bash
set -Eeuo pipefail

source /usr/local/lib/wireguard/wireguard.sh
source /usr/local/lib/wireguard/relay.sh

wg_interface=${WG_INTERFACE:-wg0}
wireguard_valid_name "$wg_interface" || { printf 'invalid WG_INTERFACE\n' >&2; exit 1; }

if wg show "$wg_interface" public-key >/dev/null 2>&1; then
  printf 'mode=kernel interface=%s state=present\n' "$wg_interface"
else
  printf 'mode=kernel interface=%s state=absent\n' "$wg_interface"
  exit 1
fi

if [[ ${RELAY_ENABLED:-false} == true ]]; then
  if relay_is_listening; then
    printf 'relay=listening bind=%s:%s\n' "$RELAY_BIND_IP" "$RELAY_PORT"
  else
    printf 'relay=not-listening\n'
    exit 1
  fi
else
  printf 'relay=disabled\n'
fi
