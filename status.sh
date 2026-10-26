#!/usr/bin/env bash
set -euo pipefail

wg_interface=${WG_INTERFACE:-wg0}
[[ $wg_interface =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,14}$ ]] || { printf 'invalid WG_INTERFACE\n' >&2; exit 1; }

if ip -o link show dev "$wg_interface" type wireguard 2>/dev/null | grep -q .; then
  printf 'mode=kernel interface=%s state=present\n' "$wg_interface"
else
  printf 'mode=kernel interface=%s state=absent\n' "$wg_interface"
  exit 1
fi

if [[ ${RELAY_ENABLED:-false} == true ]]; then
  if ss -H -lnt "sport = :${RELAY_PORT:?}" |
    awk -v endpoint="${RELAY_BIND_IP:?}:${RELAY_PORT}" '$4 == endpoint { found=1 } END { exit !found }'; then
    printf 'relay=listening bind=%s:%s\n' "$RELAY_BIND_IP" "$RELAY_PORT"
  else
    printf 'relay=not-listening\n'
    exit 1
  fi
else
  printf 'relay=disabled\n'
fi
