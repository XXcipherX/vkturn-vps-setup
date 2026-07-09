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
ACTION="install"
ACTION_ARG=""
ROTATE_WG_KEYS=0
FREE_TURN_CLIENT_ID_OVERRIDE=0
FREE_TURN_NUM_CONNECTIONS_OVERRIDE=0

log() { printf '[free-turn-setup] %s\n' "$*"; }
die() { printf '[free-turn-setup] ERROR: %s\n' "$*" >&2; exit 1; }

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

usage() {
  cat <<EOF
Usage:
  sudo bash free-turn-setup.sh
  sudo bash free-turn-setup.sh --print-link [vk-link-or-hash]
  sudo bash free-turn-setup.sh --add-client [client-id]
  sudo bash free-turn-setup.sh --remove-client <client-id>
  sudo bash free-turn-setup.sh --list-clients
  sudo bash free-turn-setup.sh --status
  sudo bash free-turn-setup.sh --logs
  sudo bash free-turn-setup.sh --restart
  sudo bash free-turn-setup.sh --update

Options:
  --vk-link <value>       VK call link/hash for generated iOS import link.
  --client-id <value>     Client ID for generated iOS import link.
  --connections <1-50>    iOS connection count for generated link.
  --rotate-keys           Regenerate WireGuard keys during install.
  -h, --help              Show this help.
EOF
}

require_arg() {
  [ $# -ge 2 ] && [ -n "$2" ] || die "Missing value for $1."
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --print-link)
        ACTION="print-link"
        shift
        if [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then
          FREE_TURN_VK_LINK="$1"
          shift
        fi
        ;;
      --add-client)
        ACTION="add-client"
        shift
        if [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then
          ACTION_ARG="$1"
          shift
        fi
        ;;
      --remove-client)
        require_arg "$1" "${2:-}"
        ACTION="remove-client"
        ACTION_ARG="$2"
        shift 2
        ;;
      --list-clients)
        ACTION="list-clients"
        shift
        ;;
      --status)
        ACTION="status"
        shift
        ;;
      --logs)
        ACTION="logs"
        shift
        ;;
      --restart)
        ACTION="restart"
        shift
        ;;
      --update)
        ACTION="update"
        shift
        ;;
      --vk-link)
        require_arg "$1" "${2:-}"
        FREE_TURN_VK_LINK="$2"
        shift 2
        ;;
      --connections)
        require_arg "$1" "${2:-}"
        FREE_TURN_NUM_CONNECTIONS="$2"
        FREE_TURN_NUM_CONNECTIONS_OVERRIDE=1
        shift 2
        ;;
      --client-id)
        require_arg "$1" "${2:-}"
        FREE_TURN_CLIENT_ID="$2"
        FREE_TURN_CLIENT_ID_OVERRIDE=1
        shift 2
        ;;
      --rotate-keys)
        ROTATE_WG_KEYS=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done
}

require_templates() {
  local f
  for f in free-turn-compose free-turn-env; do
    [ -f "$TEMPLATE_DIR/$f" ] || die "Missing required template: $f"
  done
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

validate_link_config() {
  FREE_TURN_OBF_PROFILE="$(printf '%s' "$FREE_TURN_OBF_PROFILE" | tr '[:upper:]' '[:lower:]')"
  [ "$FREE_TURN_SETUP_WG" = "1" ] || die "iOS import link can be printed only for the local WireGuard backend setup."
  valid_port "$FREE_TURN_LISTEN_PORT" || die "FREE_TURN_LISTEN_PORT must be 1-65535."
  case "$FREE_TURN_OBF_PROFILE" in
    rtpopus|rtpopus2|rtpopus3) ;;
    none) die "iOS SRTP-WRAP-S import link requires rtpopus, rtpopus2 or rtpopus3." ;;
    *) die "Unsupported FREE_TURN_OBF_PROFILE: $FREE_TURN_OBF_PROFILE" ;;
  esac
  valid_hex64 "$FREE_TURN_OBF_KEY" || die "FREE_TURN_OBF_KEY must be 64 hex chars."
  case "$FREE_TURN_NUM_CONNECTIONS" in ''|*[!0-9]*) die "FREE_TURN_NUM_CONNECTIONS must be numeric." ;; esac
  [ "$FREE_TURN_NUM_CONNECTIONS" -ge 1 ] && [ "$FREE_TURN_NUM_CONNECTIONS" -le 50 ] || die "FREE_TURN_NUM_CONNECTIONS must be 1-50."
  valid_client_id "$FREE_TURN_CLIENT_ID" || die "FREE_TURN_CLIENT_ID must be 1-255 chars: A-Z, a-z, 0-9, dot, underscore, colon or dash."
}

compose_file() {
  printf '%s/docker-compose.yml' "$INSTALL_DIR"
}

env_file() {
  printf '%s/.env' "$INSTALL_DIR"
}

clients_file() {
  printf '%s/clients.json' "$INSTALL_DIR"
}

read_env_value() {
  local key="$1" file="${2:-$(env_file)}"
  [ -f "$file" ] || return 1
  awk -F= -v key="$key" '$1 == key {
    sub(/^[^=]*=/, "")
    print
    found=1
    exit
  } END { exit found ? 0 : 1 }' "$file"
}

read_conf_value() {
  local file="$1" key="$2"
  [ -f "$file" ] || return 1
  awk -F= -v key="$key" '
    $1 ~ "^[[:space:]]*" key "[[:space:]]*$" {
      value=$2
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]\r]+$/, "", value)
      print value
      found=1
      exit
    }
    END { exit found ? 0 : 1 }
  ' "$file"
}

read_client_ids() {
  local file="${1:-$(clients_file)}"
  [ -f "$file" ] || return 0
  awk -F\" '/^[[:space:]]*"[^"]+"[[:space:]]*:[[:space:]]*\{\},?[[:space:]]*$/ { print $2 }' "$file"
}

write_client_ids() {
  local file="${1:-$(clients_file)}"
  shift || true

  local tmp id first
  declare -A seen=()

  mkdir -p "$(dirname "$file")"
  tmp="$file.tmp.$$"
  {
    printf '{\n  "clients": {\n'
    first=1
    for id in "$@"; do
      [ -n "$id" ] || continue
      valid_client_id "$id" || die "Invalid Client ID: $id"
      [ -z "${seen[$id]+x}" ] || continue
      seen["$id"]=1
      if [ "$first" -eq 1 ]; then
        first=0
      else
        printf ',\n'
      fi
      printf '    "%s": {}' "$id"
    done
    printf '\n  }\n}\n'
  } > "$tmp"
  mv "$tmp" "$file"
  chmod 600 "$file"
}

enable_clients_file_in_env() {
  local file
  file="$(env_file)"
  [ -f "$file" ] || return 0
  if grep -Eq '^CLIENTS_FILE=$' "$file"; then
    sed -i 's|^CLIENTS_FILE=.*|CLIENTS_FILE=/app/clients.json|' "$file"
  fi
}

restart_compose_if_available() {
  local compose
  compose="$(compose_file)"
  [ -f "$compose" ] || return 0
  command -v docker >/dev/null 2>&1 || return 0
  docker compose -f "$compose" up -d --force-recreate >/dev/null 2>&1 || true
}

write_clients_file() {
  local path ids id
  path="$(clients_file)"

  if [ "$FREE_TURN_ENABLE_CLIENTS_FILE" = "1" ]; then
    FREE_TURN_CLIENTS_FILE="/app/clients.json"
    ids=()
    if [ -f "$path" ]; then
      while IFS= read -r id; do
        ids+=("$id")
      done < <(read_client_ids "$path")
    fi
    ids+=("$FREE_TURN_CLIENT_ID")
    write_client_ids "$path" "${ids[@]}"
  else
    FREE_TURN_CLIENTS_FILE=""
    write_client_ids "$path"
  fi
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
  export FREE_TURN_SETUP_WG FREE_TURN_WG_IFACE FREE_TURN_NUM_CONNECTIONS FREE_TURN_PUBLIC_HOST FREE_TURN_CLIENT_ID
  envsubst '$FREE_TURN_CONNECT_ADDR $FREE_TURN_LISTEN_PORT $FREE_TURN_SETUP_WG $FREE_TURN_WG_IFACE $FREE_TURN_NUM_CONNECTIONS $FREE_TURN_PUBLIC_HOST $FREE_TURN_MODE $FREE_TURN_OBF_PROFILE $FREE_TURN_OBF_KEY $FREE_TURN_OBF_TIMING $FREE_TURN_CLIENTS_FILE $FREE_TURN_CLIENT_ID $FREE_TURN_DEBUG' \
    < "$TEMPLATE_DIR/free-turn-env" \
    > "$(env_file)"
  chmod 600 "$(env_file)"
}

setup_wireguard_backend() {
  [ "$FREE_TURN_SETUP_WG" = "1" ] || return 0

  local wg_dir="/etc/wireguard"
  local server_conf client_conf server_priv server_pub client_priv client_pub wan
  mkdir -p "$wg_dir" "$INSTALL_DIR"
  chmod 700 "$wg_dir"

  server_conf="$wg_dir/$FREE_TURN_WG_IFACE.conf"
  client_conf="$INSTALL_DIR/wireguard-client.conf"
  if [ "$ROTATE_WG_KEYS" != "1" ] && [ -f "$server_conf" ] && [ -f "$client_conf" ]; then
    server_priv="$(read_conf_value "$server_conf" "PrivateKey" || true)"
    client_priv="$(read_conf_value "$client_conf" "PrivateKey" || true)"
    if [ -n "$server_priv" ] && [ -n "$client_priv" ]; then
      log "Reusing existing WireGuard keys. Use --rotate-keys to generate new ones."
    else
      server_priv=""
      client_priv=""
    fi
  else
    server_priv=""
    client_priv=""
  fi

  if [ -z "$server_priv" ] || [ -z "$client_priv" ]; then
    log "Generating new WireGuard keys..."
    server_priv="$(wg genkey)"
    client_priv="$(wg genkey)"
  fi

  server_pub="$(printf '%s' "$server_priv" | wg pubkey)"
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
    > "$server_conf"
  chmod 600 "$server_conf"

  envsubst '$FREE_TURN_WG_CLIENT_PRIVATE_KEY $FREE_TURN_WG_CLIENT_ADDRESS $FREE_TURN_WG_DNS $FREE_TURN_WG_SERVER_PUBLIC_KEY $FREE_TURN_WG_CLIENT_ENDPOINT' \
    < "$TEMPLATE_DIR/free-turn-client-wg.conf" \
    > "$client_conf"
  chmod 600 "$client_conf"

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

load_existing_stack_config() {
  local value listen_addr first_client

  [ -f "$(env_file)" ] || die "Installed config not found: $(env_file)"

  if value="$(read_env_value FREE_TURN_LISTEN_PORT)"; then
    FREE_TURN_LISTEN_PORT="$value"
  elif listen_addr="$(read_env_value LISTEN_ADDR)"; then
    FREE_TURN_LISTEN_PORT="${listen_addr##*:}"
  fi

  if value="$(read_env_value CONNECT_ADDR)"; then FREE_TURN_CONNECT_ADDR="$value"; fi
  if value="$(read_env_value MODE)"; then FREE_TURN_MODE="$value"; fi
  if value="$(read_env_value OBF_PROFILE)"; then FREE_TURN_OBF_PROFILE="$value"; fi
  if value="$(read_env_value OBF_KEY)"; then FREE_TURN_OBF_KEY="$value"; fi
  if value="$(read_env_value FREE_TURN_SETUP_WG)"; then FREE_TURN_SETUP_WG="$value"; fi
  if value="$(read_env_value FREE_TURN_WG_IFACE)"; then FREE_TURN_WG_IFACE="$value"; fi
  if [ "$FREE_TURN_NUM_CONNECTIONS_OVERRIDE" != "1" ]; then
    if value="$(read_env_value FREE_TURN_NUM_CONNECTIONS)"; then FREE_TURN_NUM_CONNECTIONS="$value"; fi
  fi
  if value="$(read_env_value FREE_TURN_PUBLIC_HOST)"; then FREE_TURN_PUBLIC_HOST="$value"; fi
  if [ "$FREE_TURN_CLIENT_ID_OVERRIDE" != "1" ]; then
    if value="$(read_env_value FREE_TURN_CLIENT_ID)"; then FREE_TURN_CLIENT_ID="$value"; fi
  fi

  if [ -z "${FREE_TURN_CLIENT_ID:-}" ] || [ "$FREE_TURN_CLIENT_ID" = "ios-srtp-wrap-s" ]; then
    first_client="$(read_client_ids "$(clients_file)" | head -n 1 || true)"
    if [ -n "$first_client" ]; then
      FREE_TURN_CLIENT_ID="$first_client"
    fi
  fi
  if [ -z "${FREE_TURN_CLIENT_ID:-}" ]; then
    FREE_TURN_CLIENT_ID="ios-client"
  fi
}

load_existing_wireguard_config() {
  local client_conf addr value
  client_conf="$INSTALL_DIR/wireguard-client.conf"
  [ -f "$client_conf" ] || die "WireGuard client config not found: $client_conf"

  FREE_TURN_WG_CLIENT_PRIVATE_KEY="$(read_conf_value "$client_conf" "PrivateKey" || true)"
  FREE_TURN_WG_SERVER_PUBLIC_KEY="$(read_conf_value "$client_conf" "PublicKey" || true)"
  addr="$(read_conf_value "$client_conf" "Address" || true)"
  FREE_TURN_WG_CLIENT_ADDRESS="${addr%%/*}"
  if value="$(read_conf_value "$client_conf" "DNS")"; then
    FREE_TURN_WG_DNS="$value"
  fi

  [ -n "$FREE_TURN_WG_CLIENT_PRIVATE_KEY" ] || die "Could not read client WireGuard private key."
  [ -n "$FREE_TURN_WG_SERVER_PUBLIC_KEY" ] || die "Could not read server WireGuard public key."
  [ -n "$FREE_TURN_WG_CLIENT_ADDRESS" ] || die "Could not read client WireGuard address."
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

print_link_command() {
  load_existing_stack_config
  load_existing_wireguard_config
  validate_link_config

  echo "iOS import link:"
  echo "$(build_ios_connection_link)"
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
    if [ "$FREE_TURN_OBF_PROFILE" != "none" ]; then
      local ios_link
      ios_link="$(build_ios_connection_link)"
      echo
      echo "iOS import link:"
      echo "$ios_link"
    else
      echo
      echo "iOS import link skipped: SRTP-WRAP-S import requires rtpopus, rtpopus2 or rtpopus3."
    fi
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

add_client_command() {
  local id path ids existing
  [ -f "$(compose_file)" ] || die "Installed compose file not found: $(compose_file)"
  id="${1:-}"
  if [ -z "$id" ]; then
    id="$(openssl rand -hex 16)"
  fi
  valid_client_id "$id" || die "Invalid Client ID: $id"

  path="$(clients_file)"
  ids=()
  if [ -f "$path" ]; then
    while IFS= read -r existing; do
      ids+=("$existing")
    done < <(read_client_ids "$path")
  fi
  ids+=("$id")
  write_client_ids "$path" "${ids[@]}"
  enable_clients_file_in_env
  restart_compose_if_available

  echo "Client ID added:"
  echo "$id"
}

remove_client_command() {
  local id path ids existing removed
  id="$1"
  valid_client_id "$id" || die "Invalid Client ID: $id"
  path="$(clients_file)"
  [ -f "$path" ] || die "Clients file not found: $path"

  ids=()
  removed=0
  while IFS= read -r existing; do
    if [ "$existing" = "$id" ]; then
      removed=1
      continue
    fi
    ids+=("$existing")
  done < <(read_client_ids "$path")

  [ "$removed" -eq 1 ] || die "Client ID not found: $id"
  write_client_ids "$path" "${ids[@]}"
  restart_compose_if_available
  echo "Client ID removed: $id"
}

list_clients_command() {
  local path
  path="$(clients_file)"
  [ -f "$path" ] || die "Clients file not found: $path"
  read_client_ids "$path"
}

check_item() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    printf '  OK   %s\n' "$name"
  else
    printf '  FAIL %s\n' "$name"
    return 1
  fi
}

health_check() {
  local failed compose listen_port firewall_service
  failed=0
  compose="$(compose_file)"
  listen_port="$FREE_TURN_LISTEN_PORT"
  firewall_service="free-turn-proxy-firewall.service"

  echo
  echo "Health check:"
  check_item "compose file exists" test -f "$compose" || failed=1
  check_item "container is running" bash -c '[ "$(docker inspect -f "{{.State.Running}}" free-turn-proxy 2>/dev/null)" = "true" ]' || failed=1
  check_item "UDP port $listen_port is listening" bash -c "ss -H -lun | grep -Eq '(^|[[:space:]])[^[:space:]]*:$listen_port[[:space:]]'" || failed=1
  if [ "$FREE_TURN_SETUP_WG" = "1" ]; then
    check_item "WireGuard service is active" systemctl is-active --quiet "wg-quick@$FREE_TURN_WG_IFACE" || failed=1
    check_item "IPv4 forwarding is enabled" bash -c '[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" = "1" ]' || failed=1
  fi
  check_item "clients.json exists" test -f "$(clients_file)" || failed=1
  if systemctl list-unit-files "$firewall_service" --no-legend 2>/dev/null | grep -q "$firewall_service"; then
    check_item "firewall helper is active" systemctl is-active --quiet "$firewall_service" || failed=1
  fi

  return "$failed"
}

status_command() {
  load_existing_stack_config
  if [ -f "$(compose_file)" ] && command -v docker >/dev/null 2>&1; then
    docker compose -f "$(compose_file)" ps || true
  fi
  health_check
}

logs_command() {
  [ -f "$(compose_file)" ] || die "Compose file not found: $(compose_file)"
  exec docker compose -f "$(compose_file)" logs -f
}

restart_command() {
  load_existing_stack_config
  if [ "$FREE_TURN_SETUP_WG" = "1" ]; then
    systemctl restart "wg-quick@$FREE_TURN_WG_IFACE"
  fi
  docker compose -f "$(compose_file)" restart free-turn-proxy || docker compose -f "$(compose_file)" up -d
  health_check
}

update_command() {
  load_existing_stack_config
  docker compose -f "$(compose_file)" pull
  docker compose -f "$(compose_file)" up -d
  health_check
}

main() {
  parse_args "$@"

  [ "$(id -u)" -eq 0 ] || die "Please run as root."

  case "$ACTION" in
    install)
      require_templates
      prompt_config
      validate_config
      install_packages
      ensure_docker
      write_compose_stack
      setup_wireguard_backend
      install_firewall_service
      docker compose -f "$(compose_file)" pull
      docker compose -f "$(compose_file)" up -d
      health_check || true
      print_summary
      ;;
    print-link)
      print_link_command
      ;;
    add-client)
      add_client_command "$ACTION_ARG"
      ;;
    remove-client)
      remove_client_command "$ACTION_ARG"
      ;;
    list-clients)
      list_clients_command
      ;;
    status)
      status_command
      ;;
    logs)
      logs_command
      ;;
    restart)
      restart_command
      ;;
    update)
      update_command
      ;;
    *)
      die "Unsupported action: $ACTION"
      ;;
  esac
}

main "$@"
