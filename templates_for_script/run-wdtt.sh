#!/bin/sh
set -eu

: "${WDTT_PASSWORD:?WDTT_PASSWORD is required}"
: "${WDTT_DTLS_PORT:?WDTT_DTLS_PORT is required}"
: "${WDTT_WG_PORT:?WDTT_WG_PORT is required}"
: "${WDTT_DNS:?WDTT_DNS is required}"

COMMENT=WDTT_DOCKER
SUBNET=10.66.66.0/24
SERVER_PID=""

delete_iptables_rule() {
  table="$1"
  shift
  attempts=0
  while [ "$attempts" -lt 5 ]; do
    if [ "$table" = filter ]; then
      iptables -w -D "$@" 2>/dev/null || break
    else
      iptables -w -t "$table" -D "$@" 2>/dev/null || break
    fi
    attempts=$((attempts + 1))
  done
}

delete_ip6tables_rule() {
  command -v ip6tables >/dev/null 2>&1 || return 0
  attempts=0
  while [ "$attempts" -lt 5 ]; do
    ip6tables -w -D "$@" 2>/dev/null || break
    attempts=$((attempts + 1))
  done
}

cleanup_rules() {
  command -v iptables >/dev/null 2>&1 || return 0
  for comment in WDTT_DOCKER WDTT_MANAGED; do
    delete_iptables_rule filter INPUT -p udp --dport "$WDTT_DTLS_PORT" -m comment --comment "$comment" -j ACCEPT
    delete_iptables_rule filter INPUT -p udp --dport "$WDTT_WG_PORT" -m comment --comment "$comment" -j ACCEPT
    delete_iptables_rule filter INPUT ! -i lo -p udp --dport "$WDTT_WG_PORT" -m comment --comment "$comment" -j DROP
    delete_iptables_rule filter INPUT -i wdtt0 -m comment --comment "$comment" -j DROP
    delete_ip6tables_rule INPUT ! -i lo -p udp --dport "$WDTT_WG_PORT" -m comment --comment "$comment" -j DROP
    if [ -n "${WDTT_SSH_PORT:-}" ]; then
      delete_iptables_rule filter INPUT -p tcp --dport "$WDTT_SSH_PORT" -m comment --comment "$comment" -j ACCEPT
    fi
    delete_iptables_rule filter FORWARD -i wdtt0 -m comment --comment "$comment" -j ACCEPT
    delete_iptables_rule filter FORWARD -o wdtt0 -m comment --comment "$comment" -j ACCEPT
    delete_iptables_rule filter FORWARD -o wdtt0 -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment "$comment" -j ACCEPT
    delete_iptables_rule filter FORWARD -i wdtt0 -o wdtt0 -m comment --comment "$comment" -j DROP
    delete_iptables_rule filter FORWARD -i wdtt0 -m comment --comment "$comment" -j DROP
    delete_iptables_rule filter FORWARD -o wdtt0 -m comment --comment "$comment" -j DROP
    delete_iptables_rule mangle FORWARD -s "$SUBNET" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "$comment" -j TCPMSS --clamp-mss-to-pmtu
    delete_iptables_rule mangle FORWARD -d "$SUBNET" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "$comment" -j TCPMSS --clamp-mss-to-pmtu
    for iface_path in /sys/class/net/*; do
      [ -e "$iface_path" ] || continue
      iface="${iface_path##*/}"
      delete_iptables_rule filter FORWARD -i wdtt0 -s "$SUBNET" -o "$iface" -m comment --comment "$comment" -j ACCEPT
      delete_iptables_rule filter FORWARD -i "$iface" -o wdtt0 -d "$SUBNET" -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment "$comment" -j ACCEPT
      delete_iptables_rule nat POSTROUTING -s "$SUBNET" -o "$iface" -m comment --comment "$comment" -j MASQUERADE
    done
  done
}

apply_rules() {
  command -v iptables >/dev/null 2>&1 || {
    echo "iptables is required by the current WDTT server" >&2
    return 1
  }

  iptables -w -C INPUT -p udp --dport "$WDTT_DTLS_PORT" -m comment --comment "$COMMENT" -j ACCEPT 2>/dev/null || \
    iptables -w -I INPUT -p udp --dport "$WDTT_DTLS_PORT" -m comment --comment "$COMMENT" -j ACCEPT
  iptables -w -C INPUT ! -i lo -p udp --dport "$WDTT_WG_PORT" -m comment --comment "$COMMENT" -j DROP 2>/dev/null || \
    iptables -w -I INPUT 1 ! -i lo -p udp --dport "$WDTT_WG_PORT" -m comment --comment "$COMMENT" -j DROP
  if command -v ip6tables >/dev/null 2>&1 && [ -s /proc/net/if_inet6 ]; then
    ip6tables -w -C INPUT ! -i lo -p udp --dport "$WDTT_WG_PORT" -m comment --comment "$COMMENT" -j DROP 2>/dev/null || \
      ip6tables -w -I INPUT 1 ! -i lo -p udp --dport "$WDTT_WG_PORT" -m comment --comment "$COMMENT" -j DROP
  fi
  iptables -w -t mangle -C FORWARD -s "$SUBNET" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "$COMMENT" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
    iptables -w -t mangle -I FORWARD -s "$SUBNET" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "$COMMENT" -j TCPMSS --clamp-mss-to-pmtu
  iptables -w -t mangle -C FORWARD -d "$SUBNET" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "$COMMENT" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
    iptables -w -t mangle -I FORWARD -d "$SUBNET" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "$COMMENT" -j TCPMSS --clamp-mss-to-pmtu
}

handle_signal() {
  signal="$1"
  trap - HUP INT TERM
  if [ -n "$SERVER_PID" ]; then
    kill "-$signal" "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  case "$signal" in
    HUP) exit 129 ;;
    INT) exit 130 ;;
    TERM) exit 143 ;;
  esac
}

trap 'cleanup_rules || true' EXIT
trap 'handle_signal HUP' HUP
trap 'handle_signal INT' INT
trap 'handle_signal TERM' TERM

ip link show wdtt0 >/dev/null 2>&1 && ip link del wdtt0 >/dev/null 2>&1 || true
sysctl -w net.ipv4.ip_forward=1 >/dev/null
cleanup_rules
apply_rules

/usr/local/bin/wdtt-server \
  -listen="0.0.0.0:${WDTT_DTLS_PORT}" \
  -wg-port="${WDTT_WG_PORT}" \
  -config-dir=/etc/wdtt \
  -password="${WDTT_PASSWORD}" \
  -admin="${WDTT_ADMIN_ID:-}" \
  -bot-token="${WDTT_BOT_TOKEN:-}" \
  -dns="${WDTT_DNS}" &
SERVER_PID=$!

set +e
wait "$SERVER_PID"
status=$?
set -e
exit "$status"
