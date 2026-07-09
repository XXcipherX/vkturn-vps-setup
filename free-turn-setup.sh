#!/usr/bin/env bash
set -Eeuo pipefail

trap 'echo "Error on line $LINENO. Exit code: $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="${FREE_TURN_INSTALL_DIR:-/opt/free-turn-proxy}"
TEMPLATE_DIR="$SCRIPT_DIR/templates_for_script"
export DEBIAN_FRONTEND=noninteractive

FREE_TURN_IMAGE="${FREE_TURN_IMAGE:-ghcr.io/samosvalishe/free-turn-proxy:latest}"
FREE_TURN_LISTEN_PORT="${FREE_TURN_LISTEN_PORT:-56000}"
FREE_TURN_MODE="${FREE_TURN_MODE:-udp}"
FREE_TURN_CONNECT_ADDR="${FREE_TURN_CONNECT_ADDR:-127.0.0.1:51820}"
FREE_TURN_OBF_PROFILE="${FREE_TURN_OBF_PROFILE:-rtpopus3}"
FREE_TURN_OBF_TIMING="${FREE_TURN_OBF_TIMING:-}"
FREE_TURN_DEBUG="${FREE_TURN_DEBUG:-false}"
FREE_TURN_SETUP_WG="${FREE_TURN_SETUP_WG:-1}"
FREE_TURN_WG_IFACE="${FREE_TURN_WG_IFACE:-wgfreeturn}"
FREE_TURN_WG_PORT="${FREE_TURN_WG_PORT:-51820}"
FREE_TURN_WG_CIDR="${FREE_TURN_WG_CIDR:-10.13.13.0/24}"
FREE_TURN_WG_SERVER_ADDRESS="${FREE_TURN_WG_SERVER_ADDRESS:-10.13.13.1}"
FREE_TURN_WG_CLIENT_ADDRESS="${FREE_TURN_WG_CLIENT_ADDRESS:-10.13.13.2}"
FREE_TURN_WG_DNS="${FREE_TURN_WG_DNS:-1.1.1.1}"
FREE_TURN_WG_CLIENT_ENDPOINT="${FREE_TURN_WG_CLIENT_ENDPOINT:-127.0.0.1:9000}"
FREE_TURN_VK_LINK="${FREE_TURN_VK_LINK:-}"
FREE_TURN_NUM_CONNECTIONS="${FREE_TURN_NUM_CONNECTIONS:-30}"
FREE_TURN_ENABLE_CLIENTS_FILE="${FREE_TURN_ENABLE_CLIENTS_FILE:-1}"
FREE_TURN_NO_FIREWALL="${FREE_TURN_NO_FIREWALL:-0}"
FREE_TURN_PUBLIC_HOST="${FREE_TURN_PUBLIC_HOST:-}"
FREE_TURN_CLIENT_COMMENT="${FREE_TURN_CLIENT_COMMENT:-ios-srtp-wrap-s}"

log() { printf '[free-turn-setup] %s\n' "$*"; }
die() { printf '[free-turn-setup] ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Please run as root."

for f in free-turn-compose free-turn-env; do
  [ -f "$TEMPLATE_DIR/$f" ] || die "Missing required template: $f"
done

valid_port() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

valid_endpoint() {
  printf '%s' "$1" | grep -Eq '^[^[:space:]/]+:[0-9]{1,5}$'
}

valid_hex64() {
  printf '%s' "$1" | grep -Eq '^[0-9a-fA-F]{64}$'
}

valid_client_id() {
  printf '%s' "$1" | grep -Eq '^[A-Za-z0-9._:-]{1,255}$'
}

ensure_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    return 0
  fi
  log "Installing Docker..."
  local installer
  installer="$(mktemp)"
  curl -fsSL https://get.docker.com -o "$installer"
  bash "$installer"
  rm -f "$installer"
}

install_packages() {
  apt-get update
  apt-get install -y ca-certificates curl gettext-base openssl iproute2 iptables procps
  if [ "$FREE_TURN_SETUP_WG" = "1" ]; then
    apt-get install -y wireguard-tools
  fi
}

detect_wan_iface() {
  ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}'
}

ask() {
  local var="$1" prompt="$2" default_value="$3" value
  read -erp "$prompt [$default_value]: " value
  printf -v "$var" '%s' "${value:-$default_value}"
}

ask_yes_no() {
  local var="$1" prompt="$2" default_value="$3" value normalized default_label
  case "$(printf '%s' "$default_value" | tr '[:upper:]' '[:lower:]')" in
    y|yes|1|true|да|д) default_value="y"; default_label="Y/n" ;;
    *) default_value="n"; default_label="y/N" ;;
  esac
  read -erp "$prompt [$default_label]: " value
  value="${value:-$default_value}"
  normalized="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
  case "$normalized" in
    y|yes|1|true|да|д) printf -v "$var" '%s' "1" ;;
    n|no|0|false|нет|н) printf -v "$var" '%s' "0" ;;
    *) die "Expected yes/no, got: $value" ;;
  esac
}

prompt_config() {
  ask_yes_no FREE_TURN_SETUP_WG "Create local WireGuard backend on this VPS?" "${FREE_TURN_SETUP_WG}"
  ask FREE_TURN_LISTEN_PORT "Public free-turn-proxy UDP port" "$FREE_TURN_LISTEN_PORT"
  ask FREE_TURN_MODE "Backend mode: udp or tcp" "$FREE_TURN_MODE"

  if [ "$FREE_TURN_SETUP_WG" = "1" ]; then
    ask FREE_TURN_WG_PORT "Local WireGuard backend UDP port" "$FREE_TURN_WG_PORT"
    FREE_TURN_CONNECT_ADDR="127.0.0.1:$FREE_TURN_WG_PORT"
  else
    ask FREE_TURN_CONNECT_ADDR "Existing backend address host:port" "$FREE_TURN_CONNECT_ADDR"
  fi

  ask FREE_TURN_OBF_PROFILE "OBF profile: rtpopus, rtpopus2, rtpopus3 or none" "$FREE_TURN_OBF_PROFILE"
  read -erp "OBF key hex, empty = generate: " input_obf_key
  FREE_TURN_OBF_KEY="${FREE_TURN_OBF_KEY:-${input_obf_key:-$(openssl rand -hex 32)}}"
  read -erp "Client ID, empty = generate: " input_client_id
  FREE_TURN_CLIENT_ID="${FREE_TURN_CLIENT_ID:-${input_client_id:-$(openssl rand -hex 16)}}"
  ask FREE_TURN_VK_LINK "VK call link/hash for printed iOS link, empty = placeholder" "$FREE_TURN_VK_LINK"
  ask FREE_TURN_NUM_CONNECTIONS "iOS connections count" "$FREE_TURN_NUM_CONNECTIONS"
  ask_yes_no FREE_TURN_ENABLE_CLIENTS_FILE "Enable server allowlist for this Client ID?" "$FREE_TURN_ENABLE_CLIENTS_FILE"
  ask FREE_TURN_PUBLIC_HOST "Public IP/domain for printed iOS values, empty = auto" "$FREE_TURN_PUBLIC_HOST"
  ask_yes_no FREE_TURN_NO_FIREWALL "Skip host firewall rule for public UDP port?" "$FREE_TURN_NO_FIREWALL"
}

validate_config() {
  FREE_TURN_MODE="$(printf '%s' "$FREE_TURN_MODE" | tr '[:upper:]' '[:lower:]')"
  FREE_TURN_OBF_PROFILE="$(printf '%s' "$FREE_TURN_OBF_PROFILE" | tr '[:upper:]' '[:lower:]')"
  valid_port "$FREE_TURN_LISTEN_PORT" || die "FREE_TURN_LISTEN_PORT must be 1-65535."
  case "$FREE_TURN_MODE" in udp|tcp) ;; *) die "FREE_TURN_MODE must be udp or tcp." ;; esac
  valid_endpoint "$FREE_TURN_CONNECT_ADDR" || die "FREE_TURN_CONNECT_ADDR must be host:port."
  case "$FREE_TURN_OBF_PROFILE" in none|rtpopus|rtpopus2|rtpopus3) ;; *) die "Unsupported FREE_TURN_OBF_PROFILE: $FREE_TURN_OBF_PROFILE" ;; esac
  if [ "$FREE_TURN_OBF_PROFILE" != "none" ]; then
    valid_hex64 "$FREE_TURN_OBF_KEY" || die "FREE_TURN_OBF_KEY must be 64 hex chars."
  fi
  if [ "$FREE_TURN_SETUP_WG" = "1" ]; then
    valid_port "$FREE_TURN_WG_PORT" || die "FREE_TURN_WG_PORT must be 1-65535."
    [ -f "$TEMPLATE_DIR/free-turn-wg.conf" ] || die "Missing required template: free-turn-wg.conf"
    [ -f "$TEMPLATE_DIR/free-turn-client-wg.conf" ] || die "Missing required template: free-turn-client-wg.conf"
  fi
  case "$FREE_TURN_NUM_CONNECTIONS" in ''|*[!0-9]*) die "FREE_TURN_NUM_CONNECTIONS must be numeric." ;; esac
  [ "$FREE_TURN_NUM_CONNECTIONS" -ge 1 ] && [ "$FREE_TURN_NUM_CONNECTIONS" -le 50 ] || die "FREE_TURN_NUM_CONNECTIONS must be 1-50."
  valid_client_id "$FREE_TURN_CLIENT_ID" || die "FREE_TURN_CLIENT_ID must be 1-255 chars: A-Z, a-z, 0-9, dot, underscore, colon or dash."
  if ! printf '%s' "$FREE_TURN_IMAGE" | grep -Eq '^[A-Za-z0-9._/:@-]+$'; then
    die "FREE_TURN_IMAGE contains unsupported characters."
  fi
}

write_clients_file() {
  if [ "$FREE_TURN_ENABLE_CLIENTS_FILE" = "1" ]; then
    FREE_TURN_CLIENTS_FILE="/app/clients.json"
    cat > "$INSTALL_DIR/clients.json" <<EOF
{
  "clients": {
    "$FREE_TURN_CLIENT_ID": {}
  }
}
EOF
  else
    FREE_TURN_CLIENTS_FILE=""
    printf '{\n  "clients": {}\n}\n' > "$INSTALL_DIR/clients.json"
  fi
  chmod 600 "$INSTALL_DIR/clients.json"
}

write_compose_stack() {
  mkdir -p "$INSTALL_DIR"
  write_clients_file

  export FREE_TURN_IMAGE
  envsubst '$FREE_TURN_IMAGE' \
    < "$TEMPLATE_DIR/free-turn-compose" \
    > "$INSTALL_DIR/docker-compose.yml"

  export FREE_TURN_CONNECT_ADDR FREE_TURN_LISTEN_PORT FREE_TURN_MODE
  export FREE_TURN_OBF_PROFILE FREE_TURN_OBF_KEY FREE_TURN_OBF_TIMING
  export FREE_TURN_CLIENTS_FILE FREE_TURN_DEBUG
  envsubst '$FREE_TURN_CONNECT_ADDR $FREE_TURN_LISTEN_PORT $FREE_TURN_MODE $FREE_TURN_OBF_PROFILE $FREE_TURN_OBF_KEY $FREE_TURN_OBF_TIMING $FREE_TURN_CLIENTS_FILE $FREE_TURN_DEBUG' \
    < "$TEMPLATE_DIR/free-turn-env" \
    > "$INSTALL_DIR/.env"
  chmod 600 "$INSTALL_DIR/.env"
}

setup_wireguard_backend() {
  [ "$FREE_TURN_SETUP_WG" = "1" ] || return 0

  local wg_dir="/etc/wireguard"
  local server_priv server_pub client_priv client_pub wan
  mkdir -p "$wg_dir" "$INSTALL_DIR"
  chmod 700 "$wg_dir"

  server_priv="$(wg genkey)"
  server_pub="$(printf '%s' "$server_priv" | wg pubkey)"
  client_priv="$(wg genkey)"
  client_pub="$(printf '%s' "$client_priv" | wg pubkey)"
  wan="$(detect_wan_iface)"
  [ -n "$wan" ] || die "Could not detect default WAN interface."

  systemctl stop "wg-quick@$FREE_TURN_WG_IFACE" >/dev/null 2>&1 || true
  ip link show "$FREE_TURN_WG_IFACE" >/dev/null 2>&1 && ip link del "$FREE_TURN_WG_IFACE" || true

  export FREE_TURN_WG_SERVER_PRIVATE_KEY="$server_priv"
  export FREE_TURN_WG_SERVER_PUBLIC_KEY="$server_pub"
  export FREE_TURN_WG_CLIENT_PRIVATE_KEY="$client_priv"
  export FREE_TURN_WG_CLIENT_PUBLIC_KEY="$client_pub"
  export FREE_TURN_WG_SERVER_ADDRESS FREE_TURN_WG_CLIENT_ADDRESS FREE_TURN_WG_PORT
  export FREE_TURN_WG_CIDR FREE_TURN_WAN_IFACE="$wan"
  export FREE_TURN_WG_DNS FREE_TURN_WG_CLIENT_ENDPOINT

  envsubst '$FREE_TURN_WG_SERVER_ADDRESS $FREE_TURN_WG_PORT $FREE_TURN_WG_SERVER_PRIVATE_KEY $FREE_TURN_WG_CLIENT_PUBLIC_KEY $FREE_TURN_WG_CLIENT_ADDRESS $FREE_TURN_WG_CIDR $FREE_TURN_WAN_IFACE' \
    < "$TEMPLATE_DIR/free-turn-wg.conf" \
    > "$wg_dir/$FREE_TURN_WG_IFACE.conf"
  chmod 600 "$wg_dir/$FREE_TURN_WG_IFACE.conf"

  envsubst '$FREE_TURN_WG_CLIENT_PRIVATE_KEY $FREE_TURN_WG_CLIENT_ADDRESS $FREE_TURN_WG_DNS $FREE_TURN_WG_SERVER_PUBLIC_KEY $FREE_TURN_WG_CLIENT_ENDPOINT' \
    < "$TEMPLATE_DIR/free-turn-client-wg.conf" \
    > "$INSTALL_DIR/wireguard-client.conf"
  chmod 600 "$INSTALL_DIR/wireguard-client.conf"

  sysctl -w net.ipv4.ip_forward=1 >/dev/null || true
  systemctl enable --now "wg-quick@$FREE_TURN_WG_IFACE"
}

install_firewall_service() {
  if [ "$FREE_TURN_NO_FIREWALL" = "1" ]; then
    systemctl disable --now free-turn-proxy-firewall.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/free-turn-proxy-firewall.service
    systemctl daemon-reload >/dev/null 2>&1 || true
    return 0
  fi

  [ -f "$TEMPLATE_DIR/free-turn-firewall.sh" ] || die "Missing required template: free-turn-firewall.sh"
  [ -f "$TEMPLATE_DIR/free-turn-firewall.service" ] || die "Missing required template: free-turn-firewall.service"

  mkdir -p /usr/local/lib/free-turn-proxy
  cp "$TEMPLATE_DIR/free-turn-firewall.sh" /usr/local/lib/free-turn-proxy/apply-firewall.sh
  chmod 0755 /usr/local/lib/free-turn-proxy/apply-firewall.sh

  export FREE_TURN_INSTALL_DIR="$INSTALL_DIR"
  envsubst '$FREE_TURN_INSTALL_DIR' \
    < "$TEMPLATE_DIR/free-turn-firewall.service" \
    > /etc/systemd/system/free-turn-proxy-firewall.service

  systemctl daemon-reload
  systemctl enable --now free-turn-proxy-firewall.service
}

public_host() {
  if [ -n "$FREE_TURN_PUBLIC_HOST" ]; then
    printf '%s' "$FREE_TURN_PUBLIC_HOST"
    return
  fi
  curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}' || printf 'YOUR_SERVER_IP'
}

strip_vk_hash() {
  local s="$1"
  s="${s%%\?*}"
  s="${s%%#*}"
  while [ "${s%/}" != "$s" ]; do s="${s%/}"; done
  s="${s##*/}"
  case "$s" in ''|call|join) s="VK_HASH" ;; esac
  printf '%s' "$s"
}

normalize_vk_link() {
  local s hash
  s="$1"
  if [ -z "$s" ]; then
    printf 'https://vk.com/call/join/VK_HASH'
    return
  fi
  case "$s" in
    http://*|https://*) printf '%s' "$s" ;;
    *) hash="$(strip_vk_hash "$s")"; printf 'https://vk.com/call/join/%s' "$hash" ;;
  esac
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

base64url_no_pad() {
  openssl base64 -A | tr '+/' '-_' | tr -d '='
}

build_ios_connection_link() {
  [ "$FREE_TURN_SETUP_WG" = "1" ] || return 1

  local peer_host vk_link json
  peer_host="$(public_host)"
  vk_link="$(normalize_vk_link "$FREE_TURN_VK_LINK")"

  json="$(printf '{"version":1,"type":"connection","settings":{"clientID":"%s","dnsServers":"%s","numConnections":%s,"obfProfile":"%s","peerAddress":"%s:%s","peerPublicKey":"%s","privateKey":"%s","tunnelAddress":"%s/24","useDTLS":true,"useSrtp":false,"useUDP":false,"useWrap":false,"useWrapA":false,"useWrapS":true,"vkLink":"%s","wrapKeyHex":"%s"}}' \
    "$(json_escape "$FREE_TURN_CLIENT_ID")" \
    "$(json_escape "$FREE_TURN_WG_DNS")" \
    "$FREE_TURN_NUM_CONNECTIONS" \
    "$(json_escape "$FREE_TURN_OBF_PROFILE")" \
    "$(json_escape "$peer_host")" \
    "$FREE_TURN_LISTEN_PORT" \
    "$(json_escape "$FREE_TURN_WG_SERVER_PUBLIC_KEY")" \
    "$(json_escape "$FREE_TURN_WG_CLIENT_PRIVATE_KEY")" \
    "$(json_escape "$FREE_TURN_WG_CLIENT_ADDRESS")" \
    "$(json_escape "$vk_link")" \
    "$(json_escape "$FREE_TURN_OBF_KEY")")"

  printf 'vkturnproxy://import?data=%s' "$(printf '%s' "$json" | base64url_no_pad)"
}

print_summary() {
  local host
  host="$(public_host)"
  echo
  echo "Free Turn Proxy is installed."
  echo
  echo "iOS SRTP-WRAP-S values:"
  echo "  Server mode: SRTP-WRAP-S"
  echo "  Peer address: $host:$FREE_TURN_LISTEN_PORT"
  echo "  OBF profile: $FREE_TURN_OBF_PROFILE"
  echo "  OBF key: $FREE_TURN_OBF_KEY"
  echo "  Client ID: $FREE_TURN_CLIENT_ID"
  echo "  Transport to VK TURN: TCP/TLS in client app unless you explicitly need UDP"
  if [ "$FREE_TURN_SETUP_WG" = "1" ]; then
    local ios_link
    ios_link="$(build_ios_connection_link)"
    echo
    echo "iOS import link:"
    echo "$ios_link"
    echo
    echo "WireGuard client config:"
    echo "  $INSTALL_DIR/wireguard-client.conf"
    echo "  Endpoint inside that config is $FREE_TURN_WG_CLIENT_ENDPOINT"
  else
    echo
    echo "Backend is external: $FREE_TURN_CONNECT_ADDR"
  fi
  echo
  echo "Compose file: $INSTALL_DIR/docker-compose.yml"
  echo "Logs: docker compose -f $INSTALL_DIR/docker-compose.yml logs -f"
}

prompt_config
validate_config
install_packages
ensure_docker
write_compose_stack
setup_wireguard_backend
install_firewall_service

docker compose -f "$INSTALL_DIR/docker-compose.yml" pull
docker compose -f "$INSTALL_DIR/docker-compose.yml" up -d

print_summary
