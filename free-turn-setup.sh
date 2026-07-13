#!/usr/bin/env bash
set -Eeuo pipefail

trap 'echo "Error on line $LINENO. Exit code: $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${FREE_TURN_INSTALL_DIR:-/opt/free-turn-proxy}"
TEMPLATE_DIR="$SCRIPT_DIR/templates_for_script"
WG_DIR="${FREE_TURN_WG_DIR:-/etc/wireguard}"
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
  sudo bash free-turn-setup.sh --print-qr [vk-link-or-hash]
  sudo bash free-turn-setup.sh --add-client [client-id]
  sudo bash free-turn-setup.sh --remove-client <client-id>
  sudo bash free-turn-setup.sh --list-clients
  sudo bash free-turn-setup.sh --status
  sudo bash free-turn-setup.sh --logs
  sudo bash free-turn-setup.sh --restart
  sudo bash free-turn-setup.sh --update
  sudo bash free-turn-setup.sh --rotate-obf-key [vk-link-or-hash]

Options:
  --vk-link <value>       VK call link/hash for the generated iOS import link.
  --client-id <value>     Client ID for generated import links.
  --connections <1-50>    iOS connection count for the generated import link.
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
      --print-qr)
        ACTION="print-qr"
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
      --rotate-obf-key)
        ACTION="rotate-obf-key"
        shift
        if [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then
          FREE_TURN_VK_LINK="$1"
          shift
        fi
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
  validate_android_link_config
  case "$FREE_TURN_OBF_PROFILE" in
    rtpopus|rtpopus2|rtpopus3) ;;
    none) die "iOS SRTP-WRAP-S import link requires rtpopus, rtpopus2 or rtpopus3." ;;
    *) die "Unsupported FREE_TURN_OBF_PROFILE: $FREE_TURN_OBF_PROFILE" ;;
  esac
}

validate_android_link_config() {
  FREE_TURN_OBF_PROFILE="$(printf '%s' "$FREE_TURN_OBF_PROFILE" | tr '[:upper:]' '[:lower:]')"
  [ "$FREE_TURN_SETUP_WG" = "1" ] || die "Import links can be printed only for the local WireGuard backend setup."
  valid_port "$FREE_TURN_LISTEN_PORT" || die "FREE_TURN_LISTEN_PORT must be 1-65535."
  case "$FREE_TURN_OBF_PROFILE" in
    rtpopus|rtpopus2|rtpopus3) valid_hex64 "$FREE_TURN_OBF_KEY" || die "FREE_TURN_OBF_KEY must be 64 hex chars." ;;
    none) ;;
    *) die "Unsupported FREE_TURN_OBF_PROFILE: $FREE_TURN_OBF_PROFILE" ;;
  esac
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

clients_dir() {
  printf '%s/clients' "$INSTALL_DIR"
}

client_conf_file() {
  local id="$1"
  printf '%s/%s.conf' "$(clients_dir)" "$id"
}

server_wg_conf_file() {
  printf '%s/%s.conf' "$WG_DIR" "$FREE_TURN_WG_IFACE"
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
  [ -r "$file" ] || return 1
  awk -v key="$key" '
    $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      value=$0
      sub("^[[:space:]]*" key "[[:space:]]*=[[:space:]]*", "", value)
      sub(/[[:space:]\r]+$/, "", value)
      print value
      found=1
      exit
    }
    END { exit found ? 0 : 1 }
  ' "$file"
}

set_env_value() {
  local key="$1" value="$2" file="${3:-$(env_file)}"
  [ -f "$file" ] || die "Env file not found: $file"
  if grep -Eq "^${key}=" "$file"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$file"
  else
    printf '%s=%s\n' "$key" "$value" >> "$file"
  fi
  chmod 600 "$file"
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

client_id_exists() {
  local id="$1"
  read_client_ids "$(clients_file)" | grep -Fxq "$id"
}

add_client_id_to_allowlist() {
  local id="$1" ids existing
  ids=()
  if [ -f "$(clients_file)" ]; then
    while IFS= read -r existing; do
      ids+=("$existing")
    done < <(read_client_ids "$(clients_file)")
  fi
  ids+=("$id")
  write_client_ids "$(clients_file)" "${ids[@]}"
  enable_clients_file_in_env
}

remove_client_id_from_allowlist() {
  local id="$1" ids existing removed
  [ -f "$(clients_file)" ] || die "Clients file not found: $(clients_file)"
  ids=()
  removed=0
  while IFS= read -r existing; do
    if [ "$existing" = "$id" ]; then
      removed=1
      continue
    fi
    ids+=("$existing")
  done < <(read_client_ids "$(clients_file)")
  [ "$removed" -eq 1 ] || die "Client ID not found: $id"
  write_client_ids "$(clients_file)" "${ids[@]}"
}

wg_public_from_private() {
  printf '%s' "$1" | wg pubkey
}

server_wg_address() {
  local conf addr
  conf="$(server_wg_conf_file)"
  addr="$(read_conf_value "$conf" "Address" || true)"
  printf '%s' "${addr%%/*}"
}

next_client_address() {
  local conf server_ip prefix used_octets octet
  conf="$(server_wg_conf_file)"
  [ -f "$conf" ] || die "WireGuard server config not found: $conf"
  server_ip="$(server_wg_address)"
  [ -n "$server_ip" ] || die "Could not read WireGuard server address."
  prefix="${server_ip%.*}"

  used_octets="$(awk -F= -v prefix="$prefix" '
    $1 ~ /^[[:space:]]*AllowedIPs[[:space:]]*$/ {
      value=$2
      gsub(/[[:space:]]/, "", value)
      split(value, parts, ",")
      for (i in parts) {
        addr=parts[i]
        if (index(addr, prefix ".") == 1 && addr ~ /\/32$/) {
          addr=substr(addr, length(prefix) + 2)
          sub("/32$", "", addr)
          if (addr ~ /^[0-9]+$/) print addr
        }
      }
    }
  ' "$conf")"

  for octet in $(seq 2 254); do
    if ! printf '%s\n' "$used_octets" | grep -Fxq "$octet"; then
      printf '%s.%s' "$prefix" "$octet"
      return 0
    fi
  done
  die "No free WireGuard client IPs left in $prefix.0/24."
}

append_wg_peer() {
  local id="$1" public_key="$2" address="$3" conf
  conf="$(server_wg_conf_file)"
  [ -f "$conf" ] || die "WireGuard server config not found: $conf"
  if grep -Fq "$public_key" "$conf"; then
    return 0
  fi
  {
    printf '\n[Peer]\n'
    printf '# free-turn-client: %s\n' "$id"
    printf 'PublicKey = %s\n' "$public_key"
    printf 'AllowedIPs = %s/32\n' "$address"
  } >> "$conf"
  chmod 600 "$conf"
}

remove_wg_peer_by_public_key() {
  local public_key="$1" conf tmp
  conf="$(server_wg_conf_file)"
  [ -f "$conf" ] || die "WireGuard server config not found: $conf"
  tmp="$conf.tmp.$$"
  awk -v pub="$public_key" '
    function flush() {
      if (in_peer && keep) {
        printf "%s", block
      }
      block=""
      in_peer=0
      keep=1
    }
    BEGIN { in_peer=0; keep=1; block="" }
    /^\[Peer\][[:space:]]*$/ {
      flush()
      in_peer=1
      keep=1
      block=$0 ORS
      next
    }
    /^\[/ {
      flush()
      print
      next
    }
    {
      if (in_peer) {
        block=block $0 ORS
        line=$0
        sub(/^[[:space:]]*/, "", line)
        if (line ~ /^PublicKey[[:space:]]*=/) {
          sub(/^PublicKey[[:space:]]*=[[:space:]]*/, "", line)
          sub(/[[:space:]]*$/, "", line)
          if (line == pub) keep=0
        }
      } else {
        print
      }
    }
    END { flush() }
  ' "$conf" > "$tmp"
  mv "$tmp" "$conf"
  chmod 600 "$conf"
}

apply_wg_peer_runtime() {
  local public_key="$1" address="$2"
  command -v wg >/dev/null 2>&1 || return 0
  wg show "$FREE_TURN_WG_IFACE" >/dev/null 2>&1 || return 0
  wg set "$FREE_TURN_WG_IFACE" peer "$public_key" allowed-ips "$address/32" || true
}

remove_wg_peer_runtime() {
  local public_key="$1"
  command -v wg >/dev/null 2>&1 || return 0
  wg show "$FREE_TURN_WG_IFACE" >/dev/null 2>&1 || return 0
  wg set "$FREE_TURN_WG_IFACE" peer "$public_key" remove || true
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

write_client_wg_conf() {
  local id="$1" private_key="$2" address="$3" path="$4"
  mkdir -p "$(dirname "$path")"
  export FREE_TURN_WG_CLIENT_PRIVATE_KEY="$private_key"
  export FREE_TURN_WG_CLIENT_ADDRESS="$address"
  export FREE_TURN_WG_DNS FREE_TURN_WG_SERVER_PUBLIC_KEY FREE_TURN_WG_CLIENT_ENDPOINT
  envsubst '$FREE_TURN_WG_CLIENT_PRIVATE_KEY $FREE_TURN_WG_CLIENT_ADDRESS $FREE_TURN_WG_DNS $FREE_TURN_WG_SERVER_PUBLIC_KEY $FREE_TURN_WG_CLIENT_ENDPOINT' \
    < "$TEMPLATE_DIR/free-turn-client-wg.conf" \
    > "$path"
  chmod 600 "$path"
}

ensure_client_store() {
  local default_id legacy_conf stored_conf
  mkdir -p "$(clients_dir)"

  default_id="$FREE_TURN_CLIENT_ID"
  if [ -z "$default_id" ]; then
    default_id="$(read_client_ids "$(clients_file)" | head -n 1 || true)"
  fi
  [ -n "$default_id" ] || return 0

  legacy_conf="$INSTALL_DIR/wireguard-client.conf"
  stored_conf="$(client_conf_file "$default_id")"
  if [ -f "$legacy_conf" ] && [ ! -f "$stored_conf" ]; then
    cp "$legacy_conf" "$stored_conf"
    chmod 600 "$stored_conf"
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

  local server_conf client_conf server_priv server_pub client_priv client_pub wan
  mkdir -p "$WG_DIR" "$INSTALL_DIR"
  chmod 700 "$WG_DIR"

  server_conf="$WG_DIR/$FREE_TURN_WG_IFACE.conf"
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
  ensure_client_store

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
  printf '%s' "$1" | awk 'BEGIN { ORS="" } {
    if (NR > 1) printf "\\n"
    out = ""
    for (i = 1; i <= length($0); i++) {
      c = substr($0, i, 1)
      if (c == "\\") out = out "\\\\"
      else if (c == "\"") out = out "\\\""
      else out = out c
    }
    printf "%s", out
  }'
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
  ensure_client_store
  client_conf="$(client_conf_file "$FREE_TURN_CLIENT_ID")"
  if [ ! -f "$client_conf" ] && [ "$FREE_TURN_CLIENT_ID_OVERRIDE" != "1" ]; then
    client_conf="$INSTALL_DIR/wireguard-client.conf"
  fi
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

build_android_wireguard_config() {
  printf '[Interface]\nPrivateKey = %s\nAddress = %s/32\nDNS = %s\n\n[Peer]\nPublicKey = %s\nAllowedIPs = 0.0.0.0/0, ::/0\nEndpoint = %s\nPersistentKeepalive = 25' \
    "$FREE_TURN_WG_CLIENT_PRIVATE_KEY" \
    "$FREE_TURN_WG_CLIENT_ADDRESS" \
    "$FREE_TURN_WG_DNS" \
    "$FREE_TURN_WG_SERVER_PUBLIC_KEY" \
    "$FREE_TURN_WG_CLIENT_ENDPOINT"
}

build_android_connection_link() {
  [ "$FREE_TURN_SETUP_WG" = "1" ] || return 1

  # VK TURN limits allocations per credentials cache. Keep Android's first
  # connection conservative instead of copying the higher iOS stream count.
  local peer_host wg_conf json android_connections=10 android_streams_per_cred=10
  peer_host="$(public_host)"
  wg_conf="$(build_android_wireguard_config)"

  case "$FREE_TURN_OBF_PROFILE" in
    rtpopus|rtpopus2|rtpopus3)
      valid_hex64 "$FREE_TURN_OBF_KEY" || return 1
      json="$(printf '{"v":1,"provider":"vk","peer":"%s:%s","obf":"%s","key":"%s","n":%s,"spc":%s,"cid":"%s","name":"free-turn-proxy","wg":"%s"}' \
        "$(json_escape "$peer_host")" \
        "$FREE_TURN_LISTEN_PORT" \
        "$(json_escape "$FREE_TURN_OBF_PROFILE")" \
        "$(json_escape "$FREE_TURN_OBF_KEY")" \
        "$android_connections" \
        "$android_streams_per_cred" \
        "$(json_escape "$FREE_TURN_CLIENT_ID")" \
        "$(json_escape "$wg_conf")")"
      ;;
    none)
      json="$(printf '{"v":1,"provider":"vk","peer":"%s:%s","n":%s,"spc":%s,"cid":"%s","name":"free-turn-proxy","wg":"%s"}' \
        "$(json_escape "$peer_host")" \
        "$FREE_TURN_LISTEN_PORT" \
        "$android_connections" \
        "$android_streams_per_cred" \
        "$(json_escape "$FREE_TURN_CLIENT_ID")" \
        "$(json_escape "$wg_conf")")"
      ;;
    *) return 1 ;;
  esac

  printf 'freeturn://%s' "$(printf '%s' "$json" | base64url_no_pad)"
}

print_link_command() {
  load_existing_stack_config
  load_existing_wireguard_config
  validate_android_link_config

  echo "Android free-turn-proxy import link:"
  echo "$(build_android_connection_link)"
  if [ "$FREE_TURN_OBF_PROFILE" != "none" ]; then
    echo
    echo "iOS import link:"
    echo "$(build_ios_connection_link)"
  else
    echo
    echo "iOS import link skipped: SRTP-WRAP-S import requires rtpopus, rtpopus2 or rtpopus3."
  fi
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
    echo "Android turn-proxy-android import link:"
    echo "$(build_android_connection_link)"
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
  local id client_priv client_pub client_addr server_conf server_priv client_conf next_id
  [ -f "$(compose_file)" ] || die "Installed compose file not found: $(compose_file)"
  load_existing_stack_config
  [ "$FREE_TURN_SETUP_WG" = "1" ] || die "--add-client requires the local WireGuard backend setup."
  command -v wg >/dev/null 2>&1 || die "wireguard-tools is required for --add-client."
  [ -f "$TEMPLATE_DIR/free-turn-client-wg.conf" ] || die "Missing required template: free-turn-client-wg.conf"
  ensure_client_store

  id="${1:-}"
  if [ -z "$id" ]; then
    id="$(openssl rand -hex 16)"
  fi
  valid_client_id "$id" || die "Invalid Client ID: $id"
  if client_id_exists "$id" || [ -f "$(client_conf_file "$id")" ]; then
    die "Client already exists: $id"
  fi

  server_conf="$(server_wg_conf_file)"
  server_priv="$(read_conf_value "$server_conf" "PrivateKey" || true)"
  [ -n "$server_priv" ] || die "Could not read WireGuard server private key."
  FREE_TURN_WG_SERVER_PUBLIC_KEY="$(wg_public_from_private "$server_priv")"

  client_priv="$(wg genkey)"
  client_pub="$(wg_public_from_private "$client_priv")"
  client_addr="$(next_client_address)"
  client_conf="$(client_conf_file "$id")"

  write_client_wg_conf "$id" "$client_priv" "$client_addr" "$client_conf"
  append_wg_peer "$id" "$client_pub" "$client_addr"
  apply_wg_peer_runtime "$client_pub" "$client_addr"
  add_client_id_to_allowlist "$id"
  restart_compose_if_available

  FREE_TURN_CLIENT_ID="$id"
  FREE_TURN_WG_CLIENT_PRIVATE_KEY="$client_priv"
  FREE_TURN_WG_CLIENT_ADDRESS="$client_addr"
  next_id="$(read_client_ids "$(clients_file)" | head -n 1 || true)"
  if [ -n "$next_id" ]; then
    set_env_value FREE_TURN_CLIENT_ID "$next_id"
  fi

  echo "Client added:"
  echo "  Client ID: $id"
  echo "  WireGuard address: $client_addr/32"
  echo "  WireGuard config: $client_conf"
  echo
  if [ "$FREE_TURN_OBF_PROFILE" != "none" ]; then
    echo "iOS import link:"
    echo "$(build_ios_connection_link)"
  else
    echo "iOS import link skipped: SRTP-WRAP-S import requires rtpopus, rtpopus2 or rtpopus3."
  fi
  echo
  echo "Android turn-proxy-android import link:"
  echo "$(build_android_connection_link)"
}

remove_client_command() {
  local id conf legacy_conf client_priv client_pub first_remaining legacy_priv
  load_existing_stack_config
  [ "$FREE_TURN_SETUP_WG" = "1" ] || die "--remove-client requires the local WireGuard backend setup."
  command -v wg >/dev/null 2>&1 || die "wireguard-tools is required for --remove-client."
  ensure_client_store

  id="$1"
  valid_client_id "$id" || die "Invalid Client ID: $id"
  client_id_exists "$id" || die "Client ID not found: $id"
  conf="$(client_conf_file "$id")"
  [ -f "$conf" ] || die "WireGuard client config not found: $conf"

  client_priv="$(read_conf_value "$conf" "PrivateKey" || true)"
  [ -n "$client_priv" ] || die "Could not read client private key: $conf"
  client_pub="$(wg_public_from_private "$client_priv")"

  remove_wg_peer_by_public_key "$client_pub"
  remove_wg_peer_runtime "$client_pub"
  remove_client_id_from_allowlist "$id"

  legacy_conf="$INSTALL_DIR/wireguard-client.conf"
  if [ -f "$legacy_conf" ]; then
    legacy_priv="$(read_conf_value "$legacy_conf" "PrivateKey" || true)"
    if [ "$legacy_priv" = "$client_priv" ]; then
      rm -f "$legacy_conf"
    fi
  fi
  rm -f "$conf"

  first_remaining="$(read_client_ids "$(clients_file)" | head -n 1 || true)"
  if [ -n "$first_remaining" ]; then
    set_env_value FREE_TURN_CLIENT_ID "$first_remaining"
  else
    set_env_value FREE_TURN_CLIENT_ID ""
  fi

  restart_compose_if_available
  echo "Client removed: $id"
}

ensure_qrencode() {
  if command -v qrencode >/dev/null 2>&1; then
    return 0
  fi
  log "Installing qrencode..."
  apt-get update
  apt-get install -y qrencode
}

print_qr_command() {
  local link
  load_existing_stack_config
  load_existing_wireguard_config
  validate_link_config
  link="$(build_ios_connection_link)"
  echo "iOS import link:"
  echo "$link"
  echo
  ensure_qrencode
  printf '%s' "$link" | qrencode -t ansiutf8
}

rotate_obf_key_command() {
  local new_key
  load_existing_stack_config
  new_key="$(openssl rand -hex 32)"
  set_env_value OBF_KEY "$new_key"
  FREE_TURN_OBF_KEY="$new_key"
  restart_compose_if_available

  echo "OBF key rotated."
  echo "New OBF key: $new_key"
  echo "Existing iOS import links must be re-generated."

  if [ "$FREE_TURN_SETUP_WG" = "1" ] && [ "$FREE_TURN_OBF_PROFILE" != "none" ]; then
    echo
    load_existing_wireguard_config
    validate_link_config
    echo "iOS import link:"
    echo "$(build_ios_connection_link)"
    echo
    echo "Android turn-proxy-android import link:"
    echo "$(build_android_connection_link)"
  fi
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

warn_item() {
  printf '  WARN %s\n' "$1"
}

health_check() {
  local failed compose listen_port firewall_service backend_port
  failed=0
  compose="$(compose_file)"
  listen_port="$FREE_TURN_LISTEN_PORT"
  firewall_service="free-turn-proxy-firewall.service"

  echo
  echo "Health check:"
  check_item "compose file exists" test -f "$compose" || failed=1
  check_item "container is running" bash -c '[ "$(docker inspect -f "{{.State.Running}}" free-turn-proxy 2>/dev/null)" = "true" ]' || failed=1
  check_item "UDP port $listen_port is listening" bash -c "ss -H -lun | grep -Eq '(^|[[:space:]])[^[:space:]]*:${listen_port}[[:space:]]'" || failed=1
  if [ "$FREE_TURN_SETUP_WG" = "1" ]; then
    check_item "WireGuard service is active" systemctl is-active --quiet "wg-quick@$FREE_TURN_WG_IFACE" || failed=1
    check_item "IPv4 forwarding is enabled" bash -c '[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" = "1" ]' || failed=1
    backend_port="${FREE_TURN_CONNECT_ADDR##*:}"
    if ss -H -lun 2>/dev/null | grep -Eq "(^|[[:space:]])([^[:space:]]*:)?${backend_port}[[:space:]]"; then
      warn_item "backend WireGuard UDP port $backend_port is listening; keep it closed in provider/firewall rules"
    fi
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
    print-qr)
      print_qr_command
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
    rotate-obf-key)
      rotate_obf_key_command
      ;;
    *)
      die "Unsupported action: $ACTION"
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
