#!/usr/bin/env bash
set -Eeuo pipefail

trap 'echo "[csqtt-docker-setup] Error on line $LINENO. Exit code: $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${CSQTT_INSTALL_DIR:-/opt/csqtt-docker}"
ENV_FILE="$INSTALL_DIR/.env"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
SYSCTL_FILE="/etc/sysctl.d/99-csqtt-docker.conf"
PREREQ_DIR="/usr/local/lib/csqtt-docker"
PREREQ_SCRIPT="$PREREQ_DIR/prepare.sh"
PREREQ_UNIT="/etc/systemd/system/csqtt-docker-prereq.service"
export DEBIAN_FRONTEND=noninteractive

CSQTT_VK_HASHES_SET=0; [ "${CSQTT_VK_HASHES+x}" = x ] && CSQTT_VK_HASHES_SET=1
CSQTT_PUBLIC_HOST_SET=0; [ "${CSQTT_PUBLIC_HOST+x}" = x ] && CSQTT_PUBLIC_HOST_SET=1

CSQTT_DOCKER_IMAGE="${CSQTT_DOCKER_IMAGE:-}"
CSQTT_MAIN_PASSWORD="${CSQTT_MAIN_PASSWORD:-}"
CSQTT_WEB_USER="${CSQTT_WEB_USER:-}"
CSQTT_WEB_PASS="${CSQTT_WEB_PASS:-}"
CSQTT_FEC="${CSQTT_FEC:-}"
CSQTT_PUBLIC_HOST="${CSQTT_PUBLIC_HOST:-}"
CSQTT_PEER_PORT="${CSQTT_PEER_PORT:-}"
CSQTT_WEB_PORT="${CSQTT_WEB_PORT:-}"
CSQTT_VK_HASHES="${CSQTT_VK_HASHES:-}"
CSQTT_SUBNET="10.66.67.0/24"

PREVIOUS_PEER_PORT=""
PREVIOUS_WEB_PORT=""
PREVIOUS_SUBNET="$CSQTT_SUBNET"

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

  PREVIOUS_PEER_PORT="$(saved_value CSQTT_PEER_PORT)"
  PREVIOUS_WEB_PORT="$(saved_value CSQTT_WEB_PORT)"
  PREVIOUS_SUBNET="$(saved_value CSQTT_SUBNET)"
  PREVIOUS_SUBNET="${PREVIOUS_SUBNET:-$CSQTT_SUBNET}"

  CSQTT_DOCKER_IMAGE="${CSQTT_DOCKER_IMAGE:-$(saved_value CSQTT_DOCKER_IMAGE)}"
  CSQTT_DOCKER_IMAGE="${CSQTT_DOCKER_IMAGE:-$(saved_compose_image)}"
  CSQTT_WEB_USER="${CSQTT_WEB_USER:-$(saved_value CSQTT_WEB_USER)}"
  CSQTT_WEB_PASS="${CSQTT_WEB_PASS:-$(saved_value CSQTT_WEB_PASS)}"
  CSQTT_FEC="${CSQTT_FEC:-$(saved_value CSQTT_FEC)}"
  CSQTT_PEER_PORT="${CSQTT_PEER_PORT:-$PREVIOUS_PEER_PORT}"
  CSQTT_WEB_PORT="${CSQTT_WEB_PORT:-$PREVIOUS_WEB_PORT}"
  [ "$CSQTT_PUBLIC_HOST_SET" = 1 ] || CSQTT_PUBLIC_HOST="$(saved_value CSQTT_PUBLIC_HOST)"
  [ "$CSQTT_VK_HASHES_SET" = 1 ] || CSQTT_VK_HASHES="$(saved_value CSQTT_VK_HASHES)"
}

trim_whitespace() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

normalize_vk_hashes() {
  local raw="$1" value result="" existing
  local -a values normalized=()
  raw="$(trim_whitespace "$raw")"
  [ -n "$raw" ] || return 0
  IFS=',' read -r -a values <<< "$raw"
  [ "${#values[@]}" -le 6 ] || die "CSQTT_VK_HASHES accepts at most six VK call hashes."

  for value in "${values[@]}"; do
    value="$(trim_whitespace "$value")"
    value="${value%%\?*}"
    value="${value%%#*}"
    while [ "${value%/}" != "$value" ]; do value="${value%/}"; done
    value="${value##*/}"
    [ "${#value}" -ge 16 ] || die "Each VK call hash must contain at least 16 characters."
    [[ "$value" =~ ^[A-Za-z0-9._~-]+$ ]] || die "VK call hashes contain unsupported characters."
    for existing in "${normalized[@]}"; do
      [ "$existing" != "$value" ] || die "CSQTT_VK_HASHES contains a duplicate hash."
    done
    normalized+=("$value")
  done

  for value in "${normalized[@]}"; do
    [ -z "$result" ] || result+=","
    result+="$value"
  done
  printf '%s' "$result"
}

validate_port() {
  local name="$1" value="$2"
  case "$value" in
    ''|*[!0-9]*) die "$name must be a number from 1 to 65535, got: $value" ;;
  esac
  [ "$value" -ge 1 ] && [ "$value" -le 65535 ] || die "$name must be in range 1..65535, got: $value"
}

validate_ipv4_address() {
  local value="$1" octets=() octet
  IFS='.' read -r -a octets <<< "$value"
  [ "${#octets[@]}" -eq 4 ] || return 1
  for octet in "${octets[@]}"; do
    case "$octet" in ''|*[!0-9]*) return 1 ;; esac
    if [ "$octet" != 0 ] && [ "${octet#0}" != "$octet" ]; then return 1; fi
    [ "$octet" -le 255 ] || return 1
  done
}

is_public_ipv4_address() {
  local value="$1" octets=() first second
  validate_ipv4_address "$value" || return 1
  IFS='.' read -r -a octets <<< "$value"
  first=$((10#${octets[0]})); second=$((10#${octets[1]}))
  [ "$first" -ne 0 ] && [ "$first" -ne 10 ] && [ "$first" -ne 127 ] && [ "$first" -lt 224 ] || return 1
  { [ "$first" -ne 169 ] || [ "$second" -ne 254 ]; } || return 1
  { [ "$first" -ne 172 ] || [ "$second" -lt 16 ] || [ "$second" -gt 31 ]; } || return 1
  { [ "$first" -ne 192 ] || [ "$second" -ne 168 ]; } || return 1
  { [ "$first" -ne 100 ] || [ "$second" -lt 64 ] || [ "$second" -gt 127 ]; } || return 1
}

validate_public_dns_name() {
  local value="${1,,}" labels=() label
  [ "${#value}" -le 253 ] || return 1
  [ "$value" != localhost ] && [[ "$value" == *.* ]] || return 1
  case "$value" in .*|*.) return 1 ;; esac
  IFS='.' read -r -a labels <<< "$value"
  for label in "${labels[@]}"; do
    [ -n "$label" ] && [ "${#label}" -le 63 ] || return 1
    [[ "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || return 1
  done
}

validate_public_host_value() {
  local value="$1"
  [ -n "$value" ] || return 0
  if [[ "$value" =~ ^[0-9.]+$ ]]; then
    is_public_ipv4_address "$value"
  else
    validate_public_dns_name "$value"
  fi
}

validate_no_whitespace() {
  local name="$1" value="$2"
  printf '%s' "$value" | grep -q '[[:space:]]' && die "$name must not contain whitespace."
  return 0
}

validate_secret_value() {
  local name="$1" password="$2" lower weak classes=0 index char
  local -A distinct=()
  [ "${#password}" -ge 16 ] || die "$name is too short. Use at least 16 characters."
  [ "${#password}" -le 128 ] || die "$name is too long. Use 128 characters or fewer."
  [[ "$password" =~ ^[A-Za-z0-9._-]+$ ]] || \
    die "$name may contain only A-Z, a-z, 0-9, dot, underscore and dash."
  [[ "$password" =~ [a-z] ]] && classes=$((classes + 1))
  [[ "$password" =~ [A-Z] ]] && classes=$((classes + 1))
  [[ "$password" =~ [0-9] ]] && classes=$((classes + 1))
  [[ "$password" =~ [._-] ]] && classes=$((classes + 1))
  [ "$classes" -ge 2 ] || die "$name must use at least two character classes."
  for ((index = 0; index < ${#password}; index++)); do
    char="${password:index:1}"
    distinct["$char"]=1
  done
  [ "${#distinct[@]}" -ge 8 ] || die "$name must use at least eight distinct characters."
  lower="${password,,}"
  for weak in password changeme qwerty letmein 123456 adminadmin; do
    [[ "$lower" != *"$weak"* ]] || die "$name contains a common weak pattern."
  done
}

validate_config() {
  validate_port CSQTT_PEER_PORT "$CSQTT_PEER_PORT"
  validate_port CSQTT_WEB_PORT "$CSQTT_WEB_PORT"
  [ "$CSQTT_PEER_PORT" != "$CSQTT_WEB_PORT" ] || die "CSQTT_PEER_PORT and CSQTT_WEB_PORT must be different."
  [ -z "$CSQTT_MAIN_PASSWORD" ] || validate_secret_value CSQTT_MAIN_PASSWORD "$CSQTT_MAIN_PASSWORD"
  validate_secret_value CSQTT_WEB_PASS "$CSQTT_WEB_PASS"
  validate_no_whitespace CSQTT_DOCKER_IMAGE "$CSQTT_DOCKER_IMAGE"
  validate_no_whitespace CSQTT_PUBLIC_HOST "$CSQTT_PUBLIC_HOST"
  validate_no_whitespace CSQTT_WEB_USER "$CSQTT_WEB_USER"
  [[ "$CSQTT_DOCKER_IMAGE" =~ ^[A-Za-z0-9._/:@-]+$ ]] || die "CSQTT_DOCKER_IMAGE contains unsupported characters."
  [[ "$CSQTT_WEB_USER" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || die "CSQTT_WEB_USER contains unsupported characters."
  validate_public_host_value "$CSQTT_PUBLIC_HOST" || \
    die "CSQTT_PUBLIC_HOST must be a public IPv4 address or valid public DNS name."
  case "$CSQTT_FEC" in safe|off) ;; *) die "CSQTT_FEC must be safe or off." ;; esac
  CSQTT_VK_HASHES="$(normalize_vk_hashes "$CSQTT_VK_HASHES")"
}

install_packages() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    apt-get install -y ca-certificates curl gettext-base kmod openssl iproute2 iptables procps
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y ca-certificates curl gettext kmod openssl iproute iptables procps-ng
  elif command -v yum >/dev/null 2>&1; then
    yum install -y ca-certificates curl gettext kmod openssl iproute iptables procps-ng
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm --needed ca-certificates curl gettext kmod openssl iproute2 iptables procps-ng
  else
    die "Unsupported Linux distribution: apt, dnf, yum, or pacman is required."
  fi
}

ensure_docker() {
  if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
    local installer
    installer="$(mktemp)"
    curl -fsSL https://get.docker.com -o "$installer"
    bash "$installer"
    rm -f "$installer"
  fi
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now docker >/dev/null
  elif command -v service >/dev/null 2>&1; then
    service docker start >/dev/null
  fi
  docker info >/dev/null 2>&1 || die "Docker daemon is not available."
}

ensure_tun_device() {
  if [ ! -c /dev/net/tun ]; then
    modprobe tun >/dev/null 2>&1 || true
    mkdir -p /dev/net
    [ -c /dev/net/tun ] || mknod /dev/net/tun c 10 200
  fi
  [ -c /dev/net/tun ] || die "/dev/net/tun is not available on this VPS."
  chmod 666 /dev/net/tun 2>/dev/null || true
}

install_boot_prerequisite() {
  ensure_tun_device
  touch /run/xtables.lock
  chmod 600 /run/xtables.lock
  command -v systemctl >/dev/null 2>&1 || return 0

  mkdir -p "$PREREQ_DIR"
  printf '%s\n' \
    '#!/bin/sh' \
    'set -eu' \
    'if [ ! -c /dev/net/tun ]; then' \
    '  command -v modprobe >/dev/null 2>&1 && modprobe tun || true' \
    '  mkdir -p /dev/net' \
    '  [ -c /dev/net/tun ] || mknod /dev/net/tun c 10 200' \
    'fi' \
    '[ -c /dev/net/tun ]' \
    'chmod 666 /dev/net/tun 2>/dev/null || true' \
    'touch /run/xtables.lock' \
    'chmod 600 /run/xtables.lock' > "$PREREQ_SCRIPT"
  chmod 0755 "$PREREQ_SCRIPT"

  printf '%s\n' \
    '[Unit]' \
    'Description=Prepare TUN for the CSQTT Docker container' \
    'After=local-fs.target' \
    'Before=docker.service' \
    '' \
    '[Service]' \
    'Type=oneshot' \
    'RemainAfterExit=yes' \
    "ExecStart=$PREREQ_SCRIPT" \
    '' \
    '[Install]' \
    'RequiredBy=docker.service' > "$PREREQ_UNIT"
  chmod 0644 "$PREREQ_UNIT"
  systemctl daemon-reload
  systemctl enable csqtt-docker-prereq.service >/dev/null
  systemctl start csqtt-docker-prereq.service
}

write_sysctl_config() {
  printf '%s\n' \
    'net.ipv4.ip_forward = 1' \
    'net.core.rmem_max = 33554432' \
    'net.core.wmem_max = 33554432' > "$SYSCTL_FILE"
  sysctl -p "$SYSCTL_FILE" >/dev/null || true
  [ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)" = 1 ] || \
    die "IPv4 forwarding could not be enabled."
}

managed_container_exists() {
  [ "$(docker inspect --format '{{ index .Config.Labels "io.github.xxcipherx.vkturn-vps-setup" }}' csqtt 2>/dev/null || true)" = csqtt ]
}

assert_no_foreign_runtime() {
  if docker inspect csqtt >/dev/null 2>&1 && ! managed_container_exists; then
    die "A Docker container named csqtt exists but is not managed by this installer."
  fi
  if ! managed_container_exists; then
    if ss -H -lun "sport = :$CSQTT_PEER_PORT" 2>/dev/null | grep -q .; then
      die "UDP/$CSQTT_PEER_PORT is already in use by another runtime."
    fi
    if ss -H -ltn "sport = :$CSQTT_WEB_PORT" 2>/dev/null | grep -q .; then
      die "TCP/$CSQTT_WEB_PORT is already in use by another runtime."
    fi
    if ip link show csqtt1 >/dev/null 2>&1; then
      die "The csqtt1 interface already exists and is not owned by this installer."
    fi
  fi
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

cleanup_firewall_rules_for() {
  local peer="$1" web="$2" subnet="$3" iface
  command -v iptables >/dev/null 2>&1 || return 0
  [ -n "$peer" ] && delete_iptables_rule filter INPUT -p udp --dport "$peer" -m comment --comment CSQTT_DOCKER -j ACCEPT
  [ -n "$web" ] && delete_iptables_rule filter INPUT -p tcp --dport "$web" -m comment --comment CSQTT_DOCKER -j ACCEPT
  delete_iptables_rule filter INPUT -i csqtt1 -s "$subnet" -m comment --comment CSQTT_DOCKER -j ACCEPT
  delete_iptables_rule filter FORWARD -i csqtt1 -m comment --comment CSQTT_DOCKER -j ACCEPT
  delete_iptables_rule filter FORWARD -o csqtt1 -m comment --comment CSQTT_DOCKER -j ACCEPT
  delete_iptables_rule mangle FORWARD -s "$subnet" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment CSQTT_DOCKER -j TCPMSS --clamp-mss-to-pmtu
  delete_iptables_rule mangle FORWARD -d "$subnet" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment CSQTT_DOCKER -j TCPMSS --clamp-mss-to-pmtu
  for iface in $(ls /sys/class/net 2>/dev/null || true); do
    delete_iptables_rule nat POSTROUTING -s "$subnet" -o "$iface" -m comment --comment CSQTT_DOCKER -j MASQUERADE
  done
}

backup_state() {
  local backup_dir="$INSTALL_DIR/backups/csqtt-$(date -u +%Y%m%dT%H%M%SZ)-$$" file found=0
  for file in csqtt.db csqtt.db-wal csqtt.db-shm passwords.json passwords.json.imported deploy-overrides.json web_cert.pem web_key.pem; do
    [ -f "$INSTALL_DIR/data/$file" ] && found=1
  done
  [ -f "$ENV_FILE" ] && found=1
  [ "$found" -eq 1 ] || return 0

  mkdir -p "$backup_dir"
  chmod 700 "$INSTALL_DIR/backups" "$backup_dir"
  for file in csqtt.db csqtt.db-wal csqtt.db-shm passwords.json passwords.json.imported deploy-overrides.json web_cert.pem web_key.pem; do
    [ -f "$INSTALL_DIR/data/$file" ] && cp -p -- "$INSTALL_DIR/data/$file" "$backup_dir/$file"
  done
  [ -f "$ENV_FILE" ] && cp -p -- "$ENV_FILE" "$backup_dir/csqtt.env"
  chmod 600 "$backup_dir"/*
  echo "Backed up CSQTT state to $backup_dir"
}

write_deploy_override() {
  local target="$INSTALL_DIR/data/deploy-overrides.json"
  if [ -z "$CSQTT_MAIN_PASSWORD" ]; then
    rm -f -- "$target"
    return 0
  fi
  printf '{"main_password":"%s","device_id":""}\n' "$CSQTT_MAIN_PASSWORD" > "$target"
  chmod 0600 "$target"
}

preflight_image() {
  local revision
  revision="$(docker run --rm --entrypoint /usr/local/bin/csqtt "$CSQTT_DOCKER_IMAGE" --protocol-revision 2>/dev/null || true)"
  [ "$revision" = CSQTT-WIRE-3 ] || die "The selected image does not report CSQTT-WIRE-3."
  docker run --rm --entrypoint /bin/sh "$CSQTT_DOCKER_IMAGE" -ec \
    'command -v ip >/dev/null; command -v iptables >/dev/null' || \
    die "The selected image is missing required network tools."
}

detect_public_host() {
  local ip=""
  if [ -n "$CSQTT_PUBLIC_HOST" ]; then
    printf '%s' "$CSQTT_PUBLIC_HOST"
    return 0
  fi
  ip="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  is_public_ipv4_address "$ip" || return 1
  printf '%s' "$ip"
}

build_csqtt_link() {
  local host="$1" hashes
  printf 'csqtt://connect?v=2&host=%s&peer=%s&password=%s' \
    "$host" "$CSQTT_PEER_PORT" "$CSQTT_MAIN_PASSWORD"
  if [ -n "$CSQTT_VK_HASHES" ]; then
    hashes="${CSQTT_VK_HASHES//,/+}"
    printf '&hashes=%s' "$hashes"
  fi
}

wait_for_ready() {
  local attempt=0 state="" running="" pid="" restarts="" code="" web_ready=0
  while [ "$attempt" -lt 45 ]; do
    state="$(docker inspect --format '{{.State.Status}}|{{.State.Running}}|{{.State.Pid}}|{{.RestartCount}}' csqtt 2>/dev/null || true)"
    IFS='|' read -r state running pid restarts <<< "$state"
    case "$state" in
      running)
        code="$(curl -k -sS -o /dev/null -w '%{http_code}' --connect-timeout 1 --max-time 2 \
          "https://127.0.0.1:$CSQTT_WEB_PORT/" 2>/dev/null || true)"
        web_ready=0
        case "$code" in 200|401) web_ready=1 ;; esac
        if [ "$running" = true ] && [ "${pid:-0}" -gt 1 ] && ip link show csqtt1 >/dev/null 2>&1 && \
           ss -H -lun "sport = :$CSQTT_PEER_PORT" 2>/dev/null | grep -q . && [ "$web_ready" = 1 ]; then
          sleep 2
          [ "$(docker inspect --format '{{.State.Running}}|{{.State.Pid}}|{{.RestartCount}}' csqtt 2>/dev/null || true)" = "true|$pid|$restarts" ] && return 0
        fi
        ;;
      restarting|created) ;;
      exited|dead)
        docker logs --tail 100 csqtt >&2 2>/dev/null || true
        die "CSQTT container stopped before becoming ready."
        ;;
    esac
    sleep 1
    attempt=$((attempt + 1))
  done
  docker logs --tail 100 csqtt >&2 2>/dev/null || true
  die "CSQTT did not become ready within 45 seconds (state: ${state:-missing})."
}

main() {
  [ "$(id -u)" -eq 0 ] || die "Please run as root."
  for file in csqtt-compose csqtt-env run-csqtt.sh; do
    [ -f "$SCRIPT_DIR/templates_for_script/$file" ] || die "Missing required template: $file"
  done

  load_saved_config
  CSQTT_DOCKER_IMAGE="${CSQTT_DOCKER_IMAGE:-ghcr.io/xxcipherx/csqtt-server:latest}"
  CSQTT_WEB_USER="${CSQTT_WEB_USER:-admin}"
  CSQTT_FEC="${CSQTT_FEC:-safe}"
  CSQTT_PEER_PORT="${CSQTT_PEER_PORT:-46000}"
  CSQTT_WEB_PORT="${CSQTT_WEB_PORT:-46002}"

  install_packages
  ensure_docker
  install_boot_prerequisite

  local input_main_password="" input_web_user="" input_web_password=""
  local input_hashes="" input_public_host="" input_peer_port="" input_web_port=""
  if [ -f "$INSTALL_DIR/data/csqtt.db" ] || [ -f "$INSTALL_DIR/data/passwords.json" ]; then
    read -rsp "Enter a new CSQTT main password (empty = keep the database value): " input_main_password
    CSQTT_MAIN_PASSWORD="${input_main_password:-$CSQTT_MAIN_PASSWORD}"
  else
    read -rsp "Enter CSQTT main password (empty = generate): " input_main_password
    CSQTT_MAIN_PASSWORD="${input_main_password:-${CSQTT_MAIN_PASSWORD:-$(openssl rand -hex 24)}}"
  fi
  echo

  read -erp "Enter web panel login [$CSQTT_WEB_USER]: " input_web_user
  CSQTT_WEB_USER="${input_web_user:-$CSQTT_WEB_USER}"
  if [ -n "$CSQTT_WEB_PASS" ]; then
    read -rsp "Enter web panel password (empty = keep current): " input_web_password
  else
    read -rsp "Enter web panel password (empty = generate): " input_web_password
  fi
  echo
  CSQTT_WEB_PASS="${input_web_password:-${CSQTT_WEB_PASS:-$(openssl rand -hex 24)}}"

  read -erp "Enter 1-6 VK call links/hashes separated by commas, or leave empty to keep current: " input_hashes
  CSQTT_VK_HASHES="${input_hashes:-$CSQTT_VK_HASHES}"
  read -erp "Enter public IP/domain for the csqtt:// link, or leave empty to keep current/auto-detect: " input_public_host
  CSQTT_PUBLIC_HOST="${input_public_host:-$CSQTT_PUBLIC_HOST}"
  read -erp "Enter public CSQTT UDP port [$CSQTT_PEER_PORT]: " input_peer_port
  CSQTT_PEER_PORT="${input_peer_port:-$CSQTT_PEER_PORT}"
  read -erp "Enter web panel TCP port [$CSQTT_WEB_PORT]: " input_web_port
  CSQTT_WEB_PORT="${input_web_port:-$CSQTT_WEB_PORT}"

  validate_config
  assert_no_foreign_runtime

  echo "Pulling the CSQTT image before stopping the active installation..."
  docker pull "$CSQTT_DOCKER_IMAGE"
  preflight_image

  if [ -f "$COMPOSE_FILE" ]; then
    docker compose -f "$COMPOSE_FILE" down
  fi
  backup_state
  cleanup_firewall_rules_for "$PREVIOUS_PEER_PORT" "$PREVIOUS_WEB_PORT" "$PREVIOUS_SUBNET"

  ss -H -lun "sport = :$CSQTT_PEER_PORT" 2>/dev/null | grep -q . && \
    die "UDP/$CSQTT_PEER_PORT remained busy after the previous stack stopped."
  ss -H -ltn "sport = :$CSQTT_WEB_PORT" 2>/dev/null | grep -q . && \
    die "TCP/$CSQTT_WEB_PORT remained busy after the previous stack stopped."
  ip link show csqtt1 >/dev/null 2>&1 && ip link del csqtt1 >/dev/null 2>&1 || true

  mkdir -p "$INSTALL_DIR/data" "$INSTALL_DIR/backups"
  chmod 700 "$INSTALL_DIR/data" "$INSTALL_DIR/backups"
  write_deploy_override
  cp "$SCRIPT_DIR/templates_for_script/run-csqtt.sh" "$INSTALL_DIR/run-csqtt.sh"
  chmod 0755 "$INSTALL_DIR/run-csqtt.sh"

  export CSQTT_DOCKER_IMAGE CSQTT_WEB_USER CSQTT_WEB_PASS
  export CSQTT_FEC CSQTT_PUBLIC_HOST CSQTT_PEER_PORT CSQTT_WEB_PORT
  export CSQTT_VK_HASHES CSQTT_SUBNET
  envsubst '$CSQTT_DOCKER_IMAGE' \
    < "$SCRIPT_DIR/templates_for_script/csqtt-compose" > "$COMPOSE_FILE"
  envsubst '$CSQTT_DOCKER_IMAGE $CSQTT_WEB_USER $CSQTT_WEB_PASS $CSQTT_FEC $CSQTT_PUBLIC_HOST $CSQTT_PEER_PORT $CSQTT_WEB_PORT $CSQTT_VK_HASHES' \
    < "$SCRIPT_DIR/templates_for_script/csqtt-env" > "$ENV_FILE"
  chmod 0600 "$ENV_FILE"

  write_sysctl_config
  docker compose -f "$COMPOSE_FILE" up -d
  wait_for_ready

  local host="" link=""
  host="$(detect_public_host || true)"
  echo
  if [ -n "$host" ] && [ -n "$CSQTT_MAIN_PASSWORD" ]; then
    link="$(build_csqtt_link "$host")"
    echo "$link"
    echo
    echo "Web panel: https://$host:$CSQTT_WEB_PORT/"
  else
    if [ -z "$host" ]; then
      echo "Public host could not be detected; set CSQTT_PUBLIC_HOST and rerun the installer before generating a csqtt:// link."
      echo "Web panel: https://SERVER_IP:$CSQTT_WEB_PORT/"
    else
      echo "The existing main password was kept in the database, so it is not available to print a link. Use the web panel to manage client links."
      echo "Web panel: https://$host:$CSQTT_WEB_PORT/"
    fi
  fi
  echo "Web login: $CSQTT_WEB_USER"
  printf 'Web password: %s\n' "$CSQTT_WEB_PASS"
  echo "The printed main-password link binds to the first device that connects. Create a separate client password in the web panel for every additional device."
  echo "Compose file: $COMPOSE_FILE"
  echo "Logs: docker compose -f $COMPOSE_FILE logs -f"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
