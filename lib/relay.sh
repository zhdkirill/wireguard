# Sourced functions only. Runtime inputs are RELAY_*; the caller owns the listener PID.

relay_valid_ipv4() {
  local ip=$1 part
  local -a parts
  [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  IFS=. read -r -a parts <<< "$ip"
  for part in "${parts[@]}"; do
    (( ${#part} <= 3 && 10#$part <= 255 )) || return 1
    [[ $part == 0 || $part != 0* ]] || return 1
  done
}

relay_valid_port() {
  [[ $1 =~ ^[1-9][0-9]{0,4}$ ]] && (( 10#$1 <= 65535 ))
}

relay_valid_cidr() {
  local ip=${1%/*} prefix=${1#*/}
  [[ $1 == */* ]] || return 1
  relay_valid_ipv4 "$ip" && [[ $prefix =~ ^(0|[1-9][0-9]?)$ ]] && (( 10#$prefix <= 32 ))
}

relay_validate() {
  : "${RELAY_BIND_IP:?RELAY_BIND_IP is required when RELAY_ENABLED=true}"
  : "${RELAY_PORT:?RELAY_PORT is required when RELAY_ENABLED=true}"
  : "${RELAY_TARGET_HOST:?RELAY_TARGET_HOST is required when RELAY_ENABLED=true}"
  : "${RELAY_TARGET_PORT:?RELAY_TARGET_PORT is required when RELAY_ENABLED=true}"
  : "${RELAY_ALLOWED_SOURCE_CIDR:?RELAY_ALLOWED_SOURCE_CIDR is required when RELAY_ENABLED=true}"
  relay_valid_ipv4 "$RELAY_BIND_IP" && [[ $RELAY_BIND_IP != 0.0.0.0 ]] || die 'RELAY_BIND_IP must be a tunnel IPv4 address, not a wildcard'
  relay_valid_port "$RELAY_PORT" || die 'RELAY_PORT must be in 1-65535'
  [[ ${#RELAY_TARGET_HOST} -le 253 && $RELAY_TARGET_HOST =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]] || die 'RELAY_TARGET_HOST must be an IPv4 address or DNS name of at most 253 characters'
  relay_valid_port "$RELAY_TARGET_PORT" || die 'RELAY_TARGET_PORT must be in 1-65535'
  relay_valid_cidr "$RELAY_ALLOWED_SOURCE_CIDR" || die 'RELAY_ALLOWED_SOURCE_CIDR must be an IPv4 CIDR'
}

relay_check_bind() {
  if ! ip -o -4 addr show dev "$1" | awk '{print $4}' | cut -d/ -f1 | grep -Fxq -- "$RELAY_BIND_IP"; then
    die 'RELAY_BIND_IP is not assigned to the WireGuard interface'
  fi
}

relay_is_listening() {
  ss -H -lnt "sport = :${RELAY_PORT:-0}" | grep -Fq "${RELAY_BIND_IP:-invalid}:${RELAY_PORT:-0}"
}

relay_run() {
  # Allow delayed replies after a peer half-closes its input stream.
  exec socat -t 30 "TCP4-LISTEN:${RELAY_PORT},bind=${RELAY_BIND_IP},reuseaddr,fork,range=${RELAY_ALLOWED_SOURCE_CIDR}" \
    "TCP4:${RELAY_TARGET_HOST}:${RELAY_TARGET_PORT}"
}

relay_wait_ready() {
  local listener_pid=$1 attempt
  for attempt in 1 2 3 4 5; do
    kill -0 "$listener_pid" 2>/dev/null || die 'relay process exited during startup'
    if relay_is_listening; then return 0; fi
    sleep 1
  done
  die 'relay did not become ready'
}
