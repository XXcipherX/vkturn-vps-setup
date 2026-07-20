#!/bin/sh
set -eu

: "${FREE_TURN_LISTEN_PORT:?FREE_TURN_LISTEN_PORT is required}"
: "${FREE_TURN_SETUP_WG:=0}"
: "${FREE_TURN_WG_IFACE:=wgfreeturn}"
: "${FREE_TURN_WG_PORT:=51820}"

CHAIN=FREE_TURN_INPUT
COMMENT=FREE_TURN_PROXY

remove_rules() {
  firewall="$1"
  while "$firewall" -w -C INPUT -m comment --comment "$COMMENT" -j "$CHAIN" 2>/dev/null; do
    "$firewall" -w -D INPUT -m comment --comment "$COMMENT" -j "$CHAIN"
  done
  if "$firewall" -w -nL "$CHAIN" >/dev/null 2>&1; then
    "$firewall" -w -F "$CHAIN"
    "$firewall" -w -X "$CHAIN"
  fi
}

apply_rules() {
  firewall="$1"
  remove_rules "$firewall"
  [ "${2:-apply}" = "remove" ] && return 0

  "$firewall" -w -N "$CHAIN"
  if [ "$FREE_TURN_SETUP_WG" = "1" ]; then
    "$firewall" -w -A "$CHAIN" -i "$FREE_TURN_WG_IFACE" -j DROP
    "$firewall" -w -A "$CHAIN" ! -i lo -p udp --dport "$FREE_TURN_WG_PORT" -j DROP
  fi
  "$firewall" -w -A "$CHAIN" -p udp --dport "$FREE_TURN_LISTEN_PORT" -j ACCEPT
  "$firewall" -w -A "$CHAIN" -j RETURN
  "$firewall" -w -I INPUT 1 -m comment --comment "$COMMENT" -j "$CHAIN"
}

ACTION="${1:-apply}"
apply_rules iptables "$ACTION"
if command -v ip6tables >/dev/null 2>&1; then
  apply_rules ip6tables "$ACTION"
fi
