#!/usr/bin/env bash
set -Eeuo pipefail

source /usr/local/lib/wireguard/wireguard.sh
source /usr/local/lib/wireguard/relay.sh

wg_interface=${WG_INTERFACE:-wg0}
relay_enabled=${RELAY_ENABLED:-false}
wg_owned_index=
relay_pid=

log() { printf 'wireguard: %s\n' "$*" >&2; }
die() { log "$*"; exit 1; }

cleanup() {
  local result=$? cleanup_result
  trap - EXIT TERM INT

  if [[ -n $relay_pid ]]; then
    kill "$relay_pid" 2>/dev/null || true
    wait "$relay_pid" 2>/dev/null || true
  fi

  if [[ -n $wg_owned_index ]]; then
    if wireguard_stop "$wg_interface" "$wg_owned_index"; then
      :
    else
      cleanup_result=$?
      log "failed to clean up interface $wg_interface"
      # Preserve the original failure; use the cleanup error on an otherwise clean exit.
      if (( result == 0 )); then result=$cleanup_result; fi
    fi
  fi
  exit "$result"
}

start_wireguard() {
  wg-quick up "$wg_interface"
  wg_owned_index=$(wireguard_index "$wg_interface")
  wireguard_require_native "$wg_interface"
  log "mode=kernel interface=$wg_interface state=ready"
}

start_relay() {
  relay_check_bind "$wg_interface"
  relay_run &
  relay_pid=$!
  relay_wait_ready "$relay_pid"
  log "relay=listening bind=${RELAY_BIND_IP}:${RELAY_PORT}"
}

monitor() {
  while :; do
    wireguard_is_owned "$wg_interface" "$wg_owned_index" || die "interface $wg_interface disappeared or was replaced"
    if [[ -n $relay_pid ]] && ! kill -0 "$relay_pid" 2>/dev/null; then
      die 'relay process exited unexpectedly'
    fi
    sleep 2 & wait $!
  done
}

main() {
  if [[ ${1:-} == status ]]; then
    exec /usr/local/bin/wireguard-status
  fi
  [[ $# == 0 ]] || die 'usage: entrypoint.sh [status]'

  wireguard_validate_config "$wg_interface"
  [[ $relay_enabled == true || $relay_enabled == false ]] || die 'RELAY_ENABLED must be true or false'
  if [[ $relay_enabled == true ]]; then relay_validate; fi

  trap cleanup EXIT
  trap 'exit 0' TERM INT

  start_wireguard
  if [[ $relay_enabled == true ]]; then start_relay; fi
  monitor
}

main "$@"
