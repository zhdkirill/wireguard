# Sourced functions only. The caller owns lifecycle state and provides log/die.

wireguard_valid_name() {
  [[ $1 =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,14}$ ]]
}

wireguard_validate_config() {
  local interface=$1 config=/etc/wireguard/$1.conf
  wireguard_valid_name "$interface" || die 'WG_INTERFACE must start with a letter or digit and use 1-15 letters, digits, underscores, or hyphens'
  [[ -f $config ]] || die "missing configuration: $config"
  [[ -r $config ]] || die "configuration is unreadable: $config (check numeric ownership and mode)"
  if grep -Eiq '^[[:space:]]*SaveConfig[[:space:]]*=[[:space:]]*true([[:space:]]*(#.*)?)?$' "$config"; then
    die 'SaveConfig=true is incompatible with a read-only configuration mount'
  fi
}

wireguard_index() {
  cat "/sys/class/net/$1/ifindex"
}

wireguard_is_owned() {
  local interface=$1 expected_index=$2
  [[ -r /sys/class/net/$interface/ifindex ]] || return 1
  [[ $(wireguard_index "$interface") == "$expected_index" ]]
}

wireguard_require_native() {
  # Inspect the interface wg-quick created instead of creating a second probe interface.
  if ! ip -o link show dev "$1" type wireguard | grep -q .; then
    die "interface $1 is not a native WireGuard interface"
  fi
}

wireguard_stop() {
  local interface=$1 expected_index=$2
  if ! wireguard_is_owned "$interface" "$expected_index"; then
    log "interface $interface was removed or replaced; refusing to remove another interface"
    return 1
  fi
  wg-quick down "$interface"
}
