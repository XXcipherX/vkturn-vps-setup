#!/usr/bin/env bash
set -Eeuo pipefail

trap 'echo "Error on line $LINENO. Exit code: $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/opt/vkturn-vps-setup"
ENV_FILE="$INSTALL_DIR/.env"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
export DEBIAN_FRONTEND=noninteractive

WDTT_VK_LINK_SET=0; [ "${WDTT_VK_LINK+x}" = x ] && WDTT_VK_LINK_SET=1
WDTT_PUBLIC_HOST_SET=0; [ "${WDTT_PUBLIC_HOST+x}" = x ] && WDTT_PUBLIC_HOST_SET=1
WDTT_ADMIN_ID_SET=0; [ "${WDTT_ADMIN_ID+x}" = x ] && WDTT_ADMIN_ID_SET=1
WDTT_BOT_TOKEN_SET=0; [ "${WDTT_BOT_TOKEN+x}" = x ] && WDTT_BOT_TOKEN_SET=1

WDTT_DOCKER_IMAGE="${WDTT_DOCKER_IMAGE:-}"
WDTT_PASSWORD="${WDTT_PASSWORD:-}"
WDTT_VK_LINK="${WDTT_VK_LINK:-}"
WDTT_PUBLIC_HOST="${WDTT_PUBLIC_HOST:-}"
WDTT_DTLS_PORT="${WDTT_DTLS_PORT:-}"
WDTT_WG_PORT="${WDTT_WG_PORT:-}"
WDTT_SSH_PORT="${WDTT_SSH_PORT:-}"
WDTT_DNS="${WDTT_DNS:-}"
WDTT_ADMIN_ID="${WDTT_ADMIN_ID:-}"
WDTT_BOT_TOKEN="${WDTT_BOT_TOKEN:-}"
WDTT_NO_FIREWALL="${WDTT_NO_FIREWALL:-}"
WDTT_SUBNET="${WDTT_SUBNET:-}"

PREVIOUS_DTLS_PORT=""
PREVIOUS_WG_PORT=""
PREVIOUS_SSH_PORT=""
PREVIOUS_SUBNET="10.66.66.0/24"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

saved_value() {
  local key="$1"
  [ -f "$ENV_FILE" ] || return 0
  awk -v key="$key" 'index($0, key "=") == 1 { sub("^[^=]*=", ""); print; exit }' "$ENV_FILE"
}

saved_compose_image() {
  [ -f "$COMPOSE_FILE" ] || return 0
  awk '$1 == "image:" { print $2; exit }' "$COMPOSE_FILE"
}

load_saved_config() {
  [ -f "$ENV_FILE" ] || return 0

  PREVIOUS_DTLS_PORT="$(saved_value WDTT_DTLS_PORT)"
  PREVIOUS_WG_PORT="$(saved_value WDTT_WG_PORT)"
  PREVIOUS_SSH_PORT="$(saved_value WDTT_SSH_PORT)"
  PREVIOUS_SUBNET="$(saved_value WDTT_SUBNET)"
  PREVIOUS_SUBNET="${PREVIOUS_SUBNET:-10.66.66.0/24}"

  WDTT_DOCKER_IMAGE="${WDTT_DOCKER_IMAGE:-$(saved_value WDTT_DOCKER_IMAGE)}"
  WDTT_DOCKER_IMAGE="${WDTT_DOCKER_IMAGE:-$(saved_compose_image)}"
  WDTT_PASSWORD="${WDTT_PASSWORD:-$(saved_value WDTT_PASSWORD)}"
  [ "$WDTT_VK_LINK_SET" = 1 ] || WDTT_VK_LINK="$(saved_value WDTT_VK_HASH)"
  [ "$WDTT_PUBLIC_HOST_SET" = 1 ] || WDTT_PUBLIC_HOST="$(saved_value WDTT_PUBLIC_HOST)"
  WDTT_DTLS_PORT="${WDTT_DTLS_PORT:-$PREVIOUS_DTLS_PORT}"
  WDTT_WG_PORT="${WDTT_WG_PORT:-$PREVIOUS_WG_PORT}"
  WDTT_SSH_PORT="${WDTT_SSH_PORT:-$PREVIOUS_SSH_PORT}"
  WDTT_DNS="${WDTT_DNS:-$(saved_value WDTT_DNS)}"
  [ "$WDTT_ADMIN_ID_SET" = 1 ] || WDTT_ADMIN_ID="$(saved_value WDTT_ADMIN_ID)"
  [ "$WDTT_BOT_TOKEN_SET" = 1 ] || WDTT_BOT_TOKEN="$(saved_value WDTT_BOT_TOKEN)"
  WDTT_NO_FIREWALL="${WDTT_NO_FIREWALL:-$(saved_value WDTT_NO_FIREWALL)}"
  WDTT_SUBNET="${WDTT_SUBNET:-$PREVIOUS_SUBNET}"
}

strip_hash() {
  local value="$1"
  value="${value%%\?*}"
  value="${value%%#*}"
  while [ "${value%/}" != "$value" ]; do value="${value%/}"; done
  value="${value##*/}"
  case "$value" in ''|call|join) value="VK_HASH" ;; esac
  printf '%s' "$value"
}

validate_port() {
  local name="$1" value="$2"
  case "$value" in
    ''|*[!0-9]*) die "$name must be a number from 1 to 65535, got: $value" ;;
  esac
  [ "$value" -ge 1 ] && [ "$value" -le 65535 ] || die "$name must be in range 1..65535, got: $value"
}

validate_ipv4_cidr() {
  local value="$1" address prefix octet
  local -a octets
  case "$value" in
    */*) address="${value%/*}"; prefix="${value##*/}" ;;
    *) die "WDTT_SUBNET must be an IPv4 CIDR." ;;
  esac
  case "$prefix" in ''|*[!0-9]*) die "WDTT_SUBNET has an invalid prefix." ;; esac
  [ "$prefix" -le 32 ] || die "WDTT_SUBNET prefix must be in range 0..32."
  IFS=. read -r -a octets <<< "$address"
  [ "${#octets[@]}" -eq 4 ] || die "WDTT_SUBNET must contain a valid IPv4 address."
  for octet in "${octets[@]}"; do
    case "$octet" in ''|*[!0-9]*) die "WDTT_SUBNET must contain a valid IPv4 address." ;; esac
    [ "$octet" -le 255 ] || die "WDTT_SUBNET must contain a valid IPv4 address."
  done
}

validate_no_whitespace() {
  local name="$1" value="$2"
  if printf '%s' "$value" | grep -q '[[:space:]]'; then
    die "$name must not contain whitespace."
  fi
}

install_packages() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    apt-get install -y ca-certificates curl gettext-base openssl iproute2 iptables procps
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y ca-certificates curl gettext openssl iproute iptables procps-ng
  elif command -v yum >/dev/null 2>&1; then
    yum install -y ca-certificates curl gettext openssl iproute iptables procps-ng
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm --needed ca-certificates curl gettext openssl iproute2 iptables procps-ng
  else
    die "Unsupported Linux distribution: apt, dnf, yum, or pacman is required."
  fi
}

validate_config() {
  validate_port WDTT_DTLS_PORT "$WDTT_DTLS_PORT"
  validate_port WDTT_WG_PORT "$WDTT_WG_PORT"
  validate_port WDTT_SSH_PORT "$WDTT_SSH_PORT"
  [ "$WDTT_DTLS_PORT" != "$WDTT_WG_PORT" ] || die "WDTT_DTLS_PORT and WDTT_WG_PORT must be different."

  validate_no_whitespace WDTT_PASSWORD "$WDTT_PASSWORD"
  validate_no_whitespace WDTT_DOCKER_IMAGE "$WDTT_DOCKER_IMAGE"
  validate_no_whitespace WDTT_DNS "$WDTT_DNS"
  validate_no_whitespace WDTT_SUBNET "$WDTT_SUBNET"
  validate_no_whitespace WDTT_PUBLIC_HOST "$WDTT_PUBLIC_HOST"
  validate_no_whitespace WDTT_VK_HASH "$WDTT_VK_HASH"
  validate_no_whitespace WDTT_ADMIN_ID "$WDTT_ADMIN_ID"
  validate_no_whitespace WDTT_BOT_TOKEN "$WDTT_BOT_TOKEN"

  printf '%s\n' "$WDTT_PASSWORD" | grep -Eq '^[A-Za-z0-9._-]{8,128}$' || \
    die "Password must be 8-128 chars and contain only A-Z, a-z, 0-9, dot, underscore and dash."
  printf '%s\n' "$WDTT_DOCKER_IMAGE" | grep -Eq '^[A-Za-z0-9._/:@-]+$' || \
    die "WDTT_DOCKER_IMAGE contains unsupported characters."
  printf '%s\n' "$WDTT_DNS" | grep -Eq '^[A-Za-z0-9.,:]+$' || die "WDTT_DNS contains unsupported characters."
  validate_ipv4_cidr "$WDTT_SUBNET"
  printf '%s\n' "$WDTT_PUBLIC_HOST" | grep -Eq '^[A-Za-z0-9._-]*$' || \
    die "WDTT_PUBLIC_HOST must be an IP address or domain without scheme, path, or port."
  printf '%s\n' "$WDTT_VK_HASH" | grep -Eq '^[A-Za-z0-9._-]+$' || die "VK call hash contains unsupported characters."
  [ -z "$WDTT_ADMIN_ID" ] || printf '%s\n' "$WDTT_ADMIN_ID" | grep -Eq '^[0-9]+$' || die "WDTT_ADMIN_ID must be numeric."
  printf '%s\n' "$WDTT_BOT_TOKEN" | grep -Eq '^[A-Za-z0-9._:@-]*$' || die "WDTT_BOT_TOKEN contains unsupported characters."
  case "$WDTT_NO_FIREWALL" in 0|1) ;; *) die "WDTT_NO_FIREWALL must be 0 or 1." ;; esac
}

delete_iptables_rule() {
  local table="$1"
  shift
  for _ in 1 2 3 4 5; do
    if [ "$table" = filter ]; then
      iptables -w -D "$@" 2>/dev/null || break
    else
      iptables -w -t "$table" -D "$@" 2>/dev/null || break
    fi
  done
}

delete_ip6tables_rule() {
  command -v ip6tables >/dev/null 2>&1 || return 0
  for _ in 1 2 3 4 5; do
    ip6tables -w -D "$@" 2>/dev/null || break
  done
}

cleanup_firewall_rules_for() {
  command -v iptables >/dev/null 2>&1 || return 0
  local dtls="$1" wg="$2" ssh="$3" subnet="$4" comment iface
  for comment in WDTT_DOCKER WDTT_MANAGED; do
    if [ -n "$dtls" ]; then
      delete_iptables_rule filter INPUT -p udp --dport "$dtls" -m comment --comment "$comment" -j ACCEPT
    fi
    if [ -n "$wg" ]; then
      delete_iptables_rule filter INPUT -p udp --dport "$wg" -m comment --comment "$comment" -j ACCEPT
      delete_iptables_rule filter INPUT ! -i lo -p udp --dport "$wg" -m comment --comment "$comment" -j DROP
      delete_ip6tables_rule INPUT ! -i lo -p udp --dport "$wg" -m comment --comment "$comment" -j DROP
    fi
    if [ -n "$ssh" ]; then
      delete_iptables_rule filter INPUT -p tcp --dport "$ssh" -m comment --comment "$comment" -j ACCEPT
    fi
    delete_iptables_rule filter FORWARD -i wdtt0 -m comment --comment "$comment" -j ACCEPT
    delete_iptables_rule filter FORWARD -o wdtt0 -m comment --comment "$comment" -j ACCEPT
    delete_iptables_rule filter FORWARD -o wdtt0 -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment "$comment" -j ACCEPT
    delete_iptables_rule filter INPUT -i wdtt0 -m comment --comment "$comment" -j DROP
    delete_iptables_rule filter FORWARD -i wdtt0 -o wdtt0 -m comment --comment "$comment" -j DROP
    delete_iptables_rule filter FORWARD -i wdtt0 -m comment --comment "$comment" -j DROP
    delete_iptables_rule filter FORWARD -o wdtt0 -m comment --comment "$comment" -j DROP
    delete_iptables_rule mangle FORWARD -s "$subnet" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "$comment" -j TCPMSS --clamp-mss-to-pmtu
    delete_iptables_rule mangle FORWARD -d "$subnet" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "$comment" -j TCPMSS --clamp-mss-to-pmtu
    for iface in $(ls /sys/class/net 2>/dev/null || true); do
      delete_iptables_rule filter FORWARD -i wdtt0 -s "$subnet" -o "$iface" -m comment --comment "$comment" -j ACCEPT
      delete_iptables_rule filter FORWARD -i "$iface" -o wdtt0 -d "$subnet" -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment "$comment" -j ACCEPT
      delete_iptables_rule nat POSTROUTING -s "$subnet" -o "$iface" -m comment --comment "$comment" -j MASQUERADE
    done
  done
}

cleanup_firewall_rules() {
  cleanup_firewall_rules_for "$WDTT_DTLS_PORT" "$WDTT_WG_PORT" "$WDTT_SSH_PORT" "$WDTT_SUBNET"
  if [ -n "$PREVIOUS_DTLS_PORT$PREVIOUS_WG_PORT$PREVIOUS_SSH_PORT" ]; then
    cleanup_firewall_rules_for "$PREVIOUS_DTLS_PORT" "$PREVIOUS_WG_PORT" "$PREVIOUS_SSH_PORT" "$PREVIOUS_SUBNET"
  fi
}

wait_for_ready() {
  local attempt=0 state=""
  while [ "$attempt" -lt 30 ]; do
    state="$(docker inspect --format '{{.State.Status}}' wdtt 2>/dev/null || true)"
    case "$state" in
      running)
        if docker logs wdtt 2>&1 | grep -F '[SERVER] Готов' >/dev/null; then
          sleep 2
          [ "$(docker inspect --format '{{.State.Status}}' wdtt 2>/dev/null || true)" = running ] || continue
          return 0
        fi
        ;;
      restarting|created) ;;
      exited|dead)
        docker logs --tail 100 wdtt >&2 2>/dev/null || true
        die "WDTT container stopped before becoming ready."
        ;;
    esac
    sleep 1
    attempt=$((attempt + 1))
  done
  docker logs --tail 100 wdtt >&2 2>/dev/null || true
  die "WDTT container did not report readiness within 30 seconds (state: ${state:-missing})."
}

main() {
  [ "$(id -u)" -eq 0 ] || die "Please run as root."

  for file in compose env run-wdtt.sh; do
    [ -f "$SCRIPT_DIR/templates_for_script/$file" ] || die "Missing required template: $file"
  done

  load_saved_config
  WDTT_DOCKER_IMAGE="${WDTT_DOCKER_IMAGE:-ghcr.io/xxcipherx/wdtt-server:latest}"
  WDTT_DTLS_PORT="${WDTT_DTLS_PORT:-56000}"
  WDTT_WG_PORT="${WDTT_WG_PORT:-56001}"
  WDTT_SSH_PORT="${WDTT_SSH_PORT:-22}"
  WDTT_DNS="${WDTT_DNS:-1.1.1.1,1.0.0.1}"
  WDTT_NO_FIREWALL="${WDTT_NO_FIREWALL:-0}"
  WDTT_SUBNET="${WDTT_SUBNET:-10.66.66.0/24}"

  install_packages

  if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
    local installer
    installer="$(mktemp)"
    curl -fsSL https://get.docker.com -o "$installer"
    bash "$installer"
    rm -f "$installer"
  fi
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now docker >/dev/null
  fi
  docker info >/dev/null 2>&1 || die "Docker daemon is not available."

  local input_password="" input_vk_link="" input_public_host="" input_dtls="" input_wg="" input_fw=""
  if [ -n "$WDTT_PASSWORD" ]; then
    read -rsp "Enter WDTT password (empty = keep current): " input_password
  else
    read -rsp "Enter WDTT password (empty = generate): " input_password
  fi
  echo
  WDTT_PASSWORD="${input_password:-${WDTT_PASSWORD:-$(openssl rand -hex 24 | cut -c1-28)}}"

  read -erp "Enter VK call link/hash for printed wdtt:// link, or leave empty to keep current: " input_vk_link
  WDTT_VK_LINK="${input_vk_link:-$WDTT_VK_LINK}"
  WDTT_VK_HASH="$(strip_hash "$WDTT_VK_LINK")"
  read -erp "Enter public IP/domain for wdtt:// link, or leave empty to keep current/auto-detect: " input_public_host
  WDTT_PUBLIC_HOST="${input_public_host:-$WDTT_PUBLIC_HOST}"
  read -erp "Enter public WDTT UDP port [$WDTT_DTLS_PORT]: " input_dtls
  WDTT_DTLS_PORT="${input_dtls:-$WDTT_DTLS_PORT}"
  read -erp "Enter internal WireGuard UDP port [$WDTT_WG_PORT]: " input_wg
  WDTT_WG_PORT="${input_wg:-$WDTT_WG_PORT}"

  if [ "$WDTT_NO_FIREWALL" = 1 ]; then
    read -erp "Manage host iptables/NAT rules for WDTT? [y/N]: " input_fw
    case "${input_fw,,}" in y|yes) WDTT_NO_FIREWALL=0 ;; *) WDTT_NO_FIREWALL=1 ;; esac
  else
    read -erp "Manage host iptables/NAT rules for WDTT? [Y/n]: " input_fw
    case "${input_fw,,}" in n|no) WDTT_NO_FIREWALL=1 ;; *) WDTT_NO_FIREWALL=0 ;; esac
  fi

  validate_config

  if [ -f "$COMPOSE_FILE" ]; then
    docker compose -f "$COMPOSE_FILE" down
  fi
  cleanup_firewall_rules

  mkdir -p "$INSTALL_DIR/data"
  rm -rf "$INSTALL_DIR/build"
  cp "$SCRIPT_DIR/templates_for_script/run-wdtt.sh" "$INSTALL_DIR/run-wdtt.sh"
  chmod 0755 "$INSTALL_DIR/run-wdtt.sh"

  export WDTT_DOCKER_IMAGE WDTT_PASSWORD WDTT_VK_HASH WDTT_PUBLIC_HOST
  export WDTT_DTLS_PORT WDTT_WG_PORT WDTT_SSH_PORT WDTT_DNS WDTT_NO_FIREWALL
  export WDTT_ADMIN_ID WDTT_BOT_TOKEN WDTT_SUBNET

  envsubst '$WDTT_DOCKER_IMAGE' \
    < "$SCRIPT_DIR/templates_for_script/compose" \
    > "$COMPOSE_FILE"
  envsubst '$WDTT_DOCKER_IMAGE $WDTT_PASSWORD $WDTT_VK_HASH $WDTT_PUBLIC_HOST $WDTT_DTLS_PORT $WDTT_WG_PORT $WDTT_SSH_PORT $WDTT_DNS $WDTT_ADMIN_ID $WDTT_BOT_TOKEN $WDTT_NO_FIREWALL $WDTT_SUBNET' \
    < "$SCRIPT_DIR/templates_for_script/env" \
    > "$ENV_FILE"
  chmod 600 "$ENV_FILE"

  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  docker compose -f "$COMPOSE_FILE" pull
  docker compose -f "$COMPOSE_FILE" up -d
  wait_for_ready

  local host hash
  host="${WDTT_PUBLIC_HOST:-$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')}"
  host="${host:-YOUR_SERVER_IP}"
  hash="$WDTT_VK_HASH"

  echo
  echo "wdtt://$host:$WDTT_DTLS_PORT:$WDTT_WG_PORT:9000:$WDTT_PASSWORD:$hash"
  echo
  echo "Compose file: $COMPOSE_FILE"
  echo "Logs: docker compose -f $COMPOSE_FILE logs -f"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
