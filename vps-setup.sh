#!/usr/bin/env bash
set -Eeuo pipefail

trap 'echo "Error on line $LINENO. Exit code: $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="/opt/vkturn-vps-setup"
export DEBIAN_FRONTEND=noninteractive

WDTT_DOCKER_IMAGE="${WDTT_DOCKER_IMAGE:-ghcr.io/xxcipherx/wdtt-server:latest}"
WDTT_DTLS_PORT="${WDTT_DTLS_PORT:-56000}"
WDTT_WG_PORT="${WDTT_WG_PORT:-56001}"
WDTT_SSH_PORT="${WDTT_SSH_PORT:-22}"
WDTT_DNS="${WDTT_DNS:-1.1.1.1,1.0.0.1}"
WDTT_NO_FIREWALL="${WDTT_NO_FIREWALL:-0}"

[ "$(id -u)" -eq 0 ] || { echo "Please run as root"; exit 1; }

for f in compose env run-wdtt.sh; do
  [ -f "$SCRIPT_DIR/templates_for_script/$f" ] || { echo "Missing required template: $f"; exit 1; }
done

apt-get update
apt-get install -y ca-certificates curl gettext-base openssl iproute2 iptables procps

if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
  installer="$(mktemp)"
  curl -fsSL https://get.docker.com -o "$installer"
  bash "$installer"
  rm -f "$installer"
fi

read -rsp "Enter WDTT password (empty = generate): " input_password
echo
WDTT_PASSWORD="${WDTT_PASSWORD:-${input_password:-$(openssl rand -hex 24 | cut -c1-28)}}"

read -erp "Enter VK call link/hash for printed wdtt:// link, or leave empty: " input_vk_link
WDTT_VK_LINK="${input_vk_link:-${WDTT_VK_LINK:-}}"
read -erp "Enter public IP/domain for wdtt:// link, or leave empty for auto-detect: " input_public_host
WDTT_PUBLIC_HOST="${input_public_host:-${WDTT_PUBLIC_HOST:-}}"
read -erp "Enter public WDTT UDP port [$WDTT_DTLS_PORT]: " input_dtls
WDTT_DTLS_PORT="${input_dtls:-$WDTT_DTLS_PORT}"
read -erp "Enter internal WireGuard UDP port [$WDTT_WG_PORT]: " input_wg
WDTT_WG_PORT="${input_wg:-$WDTT_WG_PORT}"
read -erp "Enter SSH TCP port to keep allowed in firewall [$WDTT_SSH_PORT]: " input_ssh
WDTT_SSH_PORT="${input_ssh:-$WDTT_SSH_PORT}"
read -erp "Manage host iptables/NAT rules for WDTT? [Y/n]: " input_fw
case "${input_fw,,}" in n|no) WDTT_NO_FIREWALL=1 ;; *) WDTT_NO_FIREWALL=0 ;; esac

case "$WDTT_DTLS_PORT:$WDTT_WG_PORT:$WDTT_SSH_PORT" in
  *[!0-9:]*|'') echo "Ports must be numeric"; exit 1 ;;
esac

if ! printf '%s' "$WDTT_PASSWORD" | grep -Eq '^[A-Za-z0-9._-]{8,128}$'; then
  echo "Password must be 8-128 chars and contain only A-Z, a-z, 0-9, dot, underscore and dash."
  exit 1
fi

if ! printf '%s' "$WDTT_DOCKER_IMAGE" | grep -Eq '^[A-Za-z0-9._/:@-]+$'; then
  echo "WDTT_DOCKER_IMAGE contains unsupported characters."
  exit 1
fi

mkdir -p "$INSTALL_DIR/data"
rm -rf "$INSTALL_DIR/build"

cp "$SCRIPT_DIR/templates_for_script/run-wdtt.sh" "$INSTALL_DIR/run-wdtt.sh"
chmod 0755 "$INSTALL_DIR/run-wdtt.sh"

export WDTT_DOCKER_IMAGE
envsubst '$WDTT_DOCKER_IMAGE' \
  < "$SCRIPT_DIR/templates_for_script/compose" \
  > "$INSTALL_DIR/docker-compose.yml"

export WDTT_PASSWORD WDTT_DTLS_PORT WDTT_WG_PORT WDTT_SSH_PORT WDTT_DNS WDTT_NO_FIREWALL
export WDTT_ADMIN_ID="${WDTT_ADMIN_ID:-}"
export WDTT_BOT_TOKEN="${WDTT_BOT_TOKEN:-}"
export WDTT_SUBNET="${WDTT_SUBNET:-10.66.66.0/24}"
envsubst '$WDTT_PASSWORD $WDTT_DTLS_PORT $WDTT_WG_PORT $WDTT_SSH_PORT $WDTT_DNS $WDTT_ADMIN_ID $WDTT_BOT_TOKEN $WDTT_NO_FIREWALL $WDTT_SUBNET' \
  < "$SCRIPT_DIR/templates_for_script/env" \
  > "$INSTALL_DIR/.env"
chmod 600 "$INSTALL_DIR/.env"

sysctl -w net.ipv4.ip_forward=1 >/dev/null || true
docker compose -f "$INSTALL_DIR/docker-compose.yml" pull
docker compose -f "$INSTALL_DIR/docker-compose.yml" up -d

strip_hash() {
  local s="$1"
  s="${s%%\?*}"
  s="${s%%#*}"
  while [ "${s%/}" != "$s" ]; do s="${s%/}"; done
  s="${s##*/}"
  case "$s" in ''|call|join) s="VK_HASH" ;; esac
  printf '%s' "$s"
}

host="${WDTT_PUBLIC_HOST:-$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')}"
host="${host:-YOUR_SERVER_IP}"
hash="$(strip_hash "$WDTT_VK_LINK")"

echo
echo "wdtt://$host:$WDTT_DTLS_PORT:$WDTT_WG_PORT:9000:$WDTT_PASSWORD:$hash"
echo
echo "Compose file: $INSTALL_DIR/docker-compose.yml"
echo "Logs: docker compose -f $INSTALL_DIR/docker-compose.yml logs -f"
