#!/usr/bin/env bash
set -Eeuo pipefail

trap 'echo "Error on line $LINENO. Exit code: $?" >&2' ERR

INSTALL_DIR="/opt/vkturn-vps-setup"
export DEBIAN_FRONTEND=noninteractive

WDTT_SOURCE_REPO="${WDTT_SOURCE_REPO:-https://github.com/amurcanov/proxy-turn-vk-android.git}"
WDTT_SOURCE_REF="${WDTT_SOURCE_REF:-main}"
WDTT_GO_VERSION="${WDTT_GO_VERSION:-1.26.4}"
WDTT_DTLS_PORT="${WDTT_DTLS_PORT:-56000}"
WDTT_WG_PORT="${WDTT_WG_PORT:-56001}"
WDTT_SSH_PORT="${WDTT_SSH_PORT:-22}"
WDTT_DNS="${WDTT_DNS:-1.1.1.1,1.0.0.1}"
WDTT_NO_FIREWALL="${WDTT_NO_FIREWALL:-0}"

[ "$(id -u)" -eq 0 ] || { echo "Please run as root"; exit 1; }

apt-get update
apt-get install -y ca-certificates curl git gettext-base openssl iproute2 iptables procps

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

mkdir -p "$INSTALL_DIR/build" "$INSTALL_DIR/data"

cat > "$INSTALL_DIR/build/Dockerfile" <<'DOCKERFILE'
ARG GO_VERSION=1.26.4
FROM golang:${GO_VERSION}-bookworm AS builder

ARG WDTT_SOURCE_REPO=https://github.com/amurcanov/proxy-turn-vk-android.git
ARG WDTT_SOURCE_REF=main

RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates git \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN git init . \
  && git remote add origin "$WDTT_SOURCE_REPO" \
  && git fetch --depth=1 origin "$WDTT_SOURCE_REF" \
  && git checkout --force FETCH_HEAD \
  && test -f go.mod \
  && test -f server.go \
  && go mod download \
  && CGO_ENABLED=0 GOOS=linux go build -mod=mod -trimpath -ldflags="-s -w" -o /wdtt-server server.go

FROM debian:bookworm-slim
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates iproute2 iptables procps \
  && rm -rf /var/lib/apt/lists/*
COPY --from=builder /wdtt-server /usr/local/bin/wdtt-server
VOLUME ["/etc/wdtt"]
DOCKERFILE

cat > "$INSTALL_DIR/run-wdtt.sh" <<'RUNWDTT'
#!/bin/sh
set -u

ip link show wdtt0 >/dev/null 2>&1 && ip link del wdtt0 >/dev/null 2>&1 || true
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true

if [ "${WDTT_NO_FIREWALL:-0}" != "1" ]; then
  WAN="$(ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')"

  iptables -w -C INPUT -p udp --dport "${WDTT_DTLS_PORT}" -m comment --comment WDTT_DOCKER -j ACCEPT 2>/dev/null || \
    iptables -w -I INPUT -p udp --dport "${WDTT_DTLS_PORT}" -m comment --comment WDTT_DOCKER -j ACCEPT 2>/dev/null || true
  iptables -w -C INPUT -p udp --dport "${WDTT_WG_PORT}" -m comment --comment WDTT_DOCKER -j ACCEPT 2>/dev/null || \
    iptables -w -I INPUT -p udp --dport "${WDTT_WG_PORT}" -m comment --comment WDTT_DOCKER -j ACCEPT 2>/dev/null || true
  iptables -w -C INPUT -p tcp --dport "${WDTT_SSH_PORT:-22}" -m comment --comment WDTT_DOCKER -j ACCEPT 2>/dev/null || \
    iptables -w -I INPUT -p tcp --dport "${WDTT_SSH_PORT:-22}" -m comment --comment WDTT_DOCKER -j ACCEPT 2>/dev/null || true
  iptables -w -C FORWARD -i wdtt0 -m comment --comment WDTT_DOCKER -j ACCEPT 2>/dev/null || \
    iptables -w -I FORWARD -i wdtt0 -m comment --comment WDTT_DOCKER -j ACCEPT 2>/dev/null || true
  iptables -w -C FORWARD -o wdtt0 -m comment --comment WDTT_DOCKER -j ACCEPT 2>/dev/null || \
    iptables -w -I FORWARD -o wdtt0 -m comment --comment WDTT_DOCKER -j ACCEPT 2>/dev/null || true

  if [ -n "$WAN" ]; then
    iptables -w -t nat -C POSTROUTING -s "${WDTT_SUBNET:-10.66.66.0/24}" -o "$WAN" -m comment --comment WDTT_DOCKER -j MASQUERADE 2>/dev/null || \
      iptables -w -t nat -A POSTROUTING -s "${WDTT_SUBNET:-10.66.66.0/24}" -o "$WAN" -m comment --comment WDTT_DOCKER -j MASQUERADE 2>/dev/null || true
  fi
fi

exec /usr/local/bin/wdtt-server \
  -listen="0.0.0.0:${WDTT_DTLS_PORT}" \
  -wg-port="${WDTT_WG_PORT}" \
  -config-dir=/etc/wdtt \
  -password="${WDTT_PASSWORD}" \
  -admin="${WDTT_ADMIN_ID:-}" \
  -bot-token="${WDTT_BOT_TOKEN:-}" \
  -dns="${WDTT_DNS}"
RUNWDTT
chmod 0755 "$INSTALL_DIR/run-wdtt.sh"

cat > "$INSTALL_DIR/docker-compose.yml.in" <<'COMPOSE'
services:
  wdtt:
    build:
      context: ./build
      dockerfile: Dockerfile
      args:
        GO_VERSION: "$WDTT_GO_VERSION"
        WDTT_SOURCE_REPO: "$WDTT_SOURCE_REPO"
        WDTT_SOURCE_REF: "$WDTT_SOURCE_REF"
    image: vkturn-wdtt-server:local
    container_name: wdtt
    restart: unless-stopped
    network_mode: host
    privileged: true
    devices:
      - /dev/net/tun:/dev/net/tun
    env_file:
      - ./.env
    volumes:
      - ./data:/etc/wdtt
      - ./run-wdtt.sh:/usr/local/bin/run-wdtt.sh:ro
    entrypoint: ["/usr/local/bin/run-wdtt.sh"]
COMPOSE

export WDTT_GO_VERSION WDTT_SOURCE_REPO WDTT_SOURCE_REF
envsubst '$WDTT_GO_VERSION $WDTT_SOURCE_REPO $WDTT_SOURCE_REF' \
  < "$INSTALL_DIR/docker-compose.yml.in" \
  > "$INSTALL_DIR/docker-compose.yml"
rm -f "$INSTALL_DIR/docker-compose.yml.in"

cat > "$INSTALL_DIR/.env" <<EOF
WDTT_PASSWORD=$WDTT_PASSWORD
WDTT_DTLS_PORT=$WDTT_DTLS_PORT
WDTT_WG_PORT=$WDTT_WG_PORT
WDTT_SSH_PORT=$WDTT_SSH_PORT
WDTT_DNS=$WDTT_DNS
WDTT_ADMIN_ID=${WDTT_ADMIN_ID:-}
WDTT_BOT_TOKEN=${WDTT_BOT_TOKEN:-}
WDTT_NO_FIREWALL=$WDTT_NO_FIREWALL
WDTT_SUBNET=10.66.66.0/24
EOF
chmod 600 "$INSTALL_DIR/.env"

sysctl -w net.ipv4.ip_forward=1 >/dev/null || true
docker compose -f "$INSTALL_DIR/docker-compose.yml" up -d --build

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
