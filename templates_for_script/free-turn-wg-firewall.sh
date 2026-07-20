#!/bin/sh
set -eu

ACTION="${1:?action is required}"
IFACE="${2:?WireGuard interface is required}"
CIDR="${3:?WireGuard CIDR is required}"
WAN="${4:?WAN interface is required}"
COMMENT=FREE_TURN_WG

delete_filter_rule() {
  while iptables -w -C FORWARD -m comment --comment "$COMMENT" "$@" 2>/dev/null; do
    iptables -w -D FORWARD -m comment --comment "$COMMENT" "$@"
  done
}

delete_nat_rule() {
  while iptables -w -t nat -C POSTROUTING -m comment --comment "$COMMENT" "$@" 2>/dev/null; do
    iptables -w -t nat -D POSTROUTING -m comment --comment "$COMMENT" "$@"
  done
}

remove_rules() {
  delete_filter_rule -i "$IFACE" -o "$IFACE" -j DROP
  delete_filter_rule -i "$IFACE" -s "$CIDR" -o "$WAN" -j ACCEPT
  delete_filter_rule -i "$WAN" -o "$IFACE" -d "$CIDR" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
  delete_filter_rule -i "$IFACE" -j DROP
  delete_filter_rule -o "$IFACE" -j DROP
  delete_nat_rule -s "$CIDR" -o "$WAN" -j MASQUERADE
}

remove_rules
[ "$ACTION" = "remove" ] && exit 0
[ "$ACTION" = "apply" ] || { echo "unknown action: $ACTION" >&2; exit 1; }

sysctl -q -w net.ipv4.ip_forward=1 >/dev/null

# Insert in reverse order so the same-interface isolation rule is evaluated first.
iptables -w -I FORWARD 1 -o "$IFACE" -m comment --comment "$COMMENT" -j DROP
iptables -w -I FORWARD 1 -i "$IFACE" -m comment --comment "$COMMENT" -j DROP
iptables -w -I FORWARD 1 -i "$WAN" -o "$IFACE" -d "$CIDR" -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment "$COMMENT" -j ACCEPT
iptables -w -I FORWARD 1 -i "$IFACE" -s "$CIDR" -o "$WAN" -m comment --comment "$COMMENT" -j ACCEPT
iptables -w -I FORWARD 1 -i "$IFACE" -o "$IFACE" -m comment --comment "$COMMENT" -j DROP
iptables -w -t nat -A POSTROUTING -s "$CIDR" -o "$WAN" -m comment --comment "$COMMENT" -j MASQUERADE
