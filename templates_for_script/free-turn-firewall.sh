#!/bin/sh
set -eu

: "${FREE_TURN_LISTEN_PORT:?FREE_TURN_LISTEN_PORT is required}"

iptables -w -C INPUT -p udp --dport "$FREE_TURN_LISTEN_PORT" -m comment --comment FREE_TURN_PROXY -j ACCEPT 2>/dev/null || \
  iptables -w -I INPUT -p udp --dport "$FREE_TURN_LISTEN_PORT" -m comment --comment FREE_TURN_PROXY -j ACCEPT
