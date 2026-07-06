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
