#!/bin/sh
set -eu

: "${CSQTT_WEB_USER:?CSQTT_WEB_USER is required}"
: "${CSQTT_WEB_PASS:?CSQTT_WEB_PASS is required}"
: "${CSQTT_FEC:?CSQTT_FEC is required}"
: "${CSQTT_PEER_PORT:?CSQTT_PEER_PORT is required}"
: "${CSQTT_WEB_PORT:?CSQTT_WEB_PORT is required}"

COMMENT=CSQTT_DOCKER
TUN_IFACE=csqtt1
SUBNET=10.66.67.0/24
XT_WAIT="${CSQTT_XT_WAIT:-2}"
SERVER_PID=""

delete_rule() {
  table="$1"
  shift
  attempts=0
  while [ "$attempts" -lt 5 ]; do
    if [ "$table" = filter ]; then
      iptables -w "$XT_WAIT" -D "$@" 2>/dev/null || break
    else
      iptables -w "$XT_WAIT" -t "$table" -D "$@" 2>/dev/null || break
    fi
    attempts=$((attempts + 1))
  done
}

cleanup_rules() {
  command -v iptables >/dev/null 2>&1 || return 0
  delete_rule filter INPUT -p udp --dport "$CSQTT_PEER_PORT" -m comment --comment "$COMMENT" -j ACCEPT
  delete_rule filter INPUT -p tcp --dport "$CSQTT_WEB_PORT" -m comment --comment "$COMMENT" -j ACCEPT
  delete_rule filter INPUT -i "$TUN_IFACE" -s "$SUBNET" -m comment --comment "$COMMENT" -j ACCEPT
  delete_rule filter FORWARD -i "$TUN_IFACE" -m comment --comment "$COMMENT" -j ACCEPT
  delete_rule filter FORWARD -o "$TUN_IFACE" -m comment --comment "$COMMENT" -j ACCEPT
  delete_rule mangle FORWARD -s "$SUBNET" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "$COMMENT" -j TCPMSS --clamp-mss-to-pmtu
  delete_rule mangle FORWARD -d "$SUBNET" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "$COMMENT" -j TCPMSS --clamp-mss-to-pmtu
  for iface_path in /sys/class/net/*; do
    [ -e "$iface_path" ] || continue
    iface="${iface_path##*/}"
    delete_rule nat POSTROUTING -s "$SUBNET" -o "$iface" -m comment --comment "$COMMENT" -j MASQUERADE
  done
}

is_ignored_wan_interface() {
  iface="${1%%@*}"
  case "$iface" in
    ""|lo|"$TUN_IFACE"|csqtp*|tun*|tap*|wg*|warp*|Warp*|WARP*|CloudflareWARP*|tailscale*|zt*|docker*|br-*|veth*|cni*|flannel*|virbr*|podman*|kube*|dummy*|ifb*) return 0 ;;
  esac
  return 1
}

detect_wan_interface() {
  fallback=""
  for candidate in $(ip -o -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); break}}'); do
    candidate="${candidate%%@*}"
    [ -n "$fallback" ] || fallback="$candidate"
    if ! is_ignored_wan_interface "$candidate" && ip link show "$candidate" >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  for candidate in $(ip -o -4 addr show scope global 2>/dev/null | awk '{sub(/@.*/, "", $2); print $2}'); do
    candidate="${candidate%%@*}"
    [ -n "$fallback" ] || fallback="$candidate"
    if ! is_ignored_wan_interface "$candidate" && ip link show "$candidate" >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  [ -n "$fallback" ] && printf '%s\n' "$fallback"
}

wait_for_network() {
  waited=0
  while [ "$waited" -lt 90 ]; do
    WAN_IFACE="$(detect_wan_interface || true)"
    if [ -n "$WAN_IFACE" ] && ip link show "$WAN_IFACE" >/dev/null 2>&1 && \
       ip -o -4 route show default 2>/dev/null | grep -q .; then
      return 0
    fi
    waited=$((waited + 1))
    sleep 1
  done
  echo "CSQTT could not determine the host WAN interface" >&2
  return 1
}

ensure_rule() {
  table="$1"
  chain="$2"
  shift 2
  if [ "$table" = filter ]; then
    iptables -w "$XT_WAIT" -C "$chain" "$@" 2>/dev/null || \
      iptables -w "$XT_WAIT" -I "$chain" 1 "$@"
  else
    iptables -w "$XT_WAIT" -t "$table" -C "$chain" "$@" 2>/dev/null || \
      iptables -w "$XT_WAIT" -t "$table" -I "$chain" 1 "$@"
  fi
}

apply_rules() {
  command -v ip >/dev/null 2>&1 || {
    echo "iproute2 is required by CSQTT" >&2
    return 1
  }
  command -v iptables >/dev/null 2>&1 || {
    echo "iptables is required by CSQTT" >&2
    return 1
  }

  ensure_rule filter INPUT -p udp --dport "$CSQTT_PEER_PORT" -m comment --comment "$COMMENT" -j ACCEPT
  ensure_rule filter INPUT -p tcp --dport "$CSQTT_WEB_PORT" -m comment --comment "$COMMENT" -j ACCEPT
  ensure_rule filter INPUT -i "$TUN_IFACE" -s "$SUBNET" -m comment --comment "$COMMENT" -j ACCEPT
  ensure_rule filter FORWARD -i "$TUN_IFACE" -m comment --comment "$COMMENT" -j ACCEPT
  ensure_rule filter FORWARD -o "$TUN_IFACE" -m comment --comment "$COMMENT" -j ACCEPT
  ensure_rule nat POSTROUTING -s "$SUBNET" -o "$WAN_IFACE" -m comment --comment "$COMMENT" -j MASQUERADE
  ensure_rule mangle FORWARD -s "$SUBNET" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "$COMMENT" -j TCPMSS --clamp-mss-to-pmtu
  ensure_rule mangle FORWARD -d "$SUBNET" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "$COMMENT" -j TCPMSS --clamp-mss-to-pmtu
}

cleanup_runtime() {
  cleanup_rules || true
  ip link show "$TUN_IFACE" >/dev/null 2>&1 && ip link del "$TUN_IFACE" >/dev/null 2>&1 || true
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

reload_tls() {
  [ -n "$SERVER_PID" ] && kill -USR1 "$SERVER_PID" 2>/dev/null || true
}

trap cleanup_runtime EXIT
trap 'handle_signal HUP' HUP
trap 'handle_signal INT' INT
trap 'handle_signal TERM' TERM
trap reload_tls USR1

wait_for_network
ip link show "$TUN_IFACE" >/dev/null 2>&1 && ip link del "$TUN_IFACE" >/dev/null 2>&1 || true
if [ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)" != 1 ]; then
  echo "Host IPv4 forwarding is disabled; rerun csqtt-docker-setup.sh on the VPS" >&2
  exit 1
fi
cleanup_rules
apply_rules

/usr/local/bin/csqtt \
  --listen "0.0.0.0:${CSQTT_PEER_PORT}" \
  --web-port "$CSQTT_WEB_PORT" \
  --config-dir /etc/csqtt &
SERVER_PID=$!

while :; do
  set +e
  wait "$SERVER_PID"
  status=$?
  set -e
  if [ "$status" -ge 128 ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    continue
  fi
  break
done
exit "$status"
