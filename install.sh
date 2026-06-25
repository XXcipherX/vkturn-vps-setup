#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_VERSION="0.1.0"

WDTT_SOURCE_REPO_DEFAULT="https://github.com/amurcanov/proxy-turn-vk-android.git"
WDTT_SOURCE_REF_DEFAULT="main"
WDTT_GO_VERSION_DEFAULT="1.25.0"

WDTT_INSTALL_ROOT="${WDTT_INSTALL_ROOT:-/opt/wdtt}"
WDTT_SOURCE_DIR="${WDTT_SOURCE_DIR:-$WDTT_INSTALL_ROOT/source}"
WDTT_GO_ROOT="${WDTT_GO_ROOT:-$WDTT_INSTALL_ROOT/go}"
WDTT_CONFIG_DIR="${WDTT_CONFIG_DIR:-/etc/wdtt}"
WDTT_LIB_DIR="${WDTT_LIB_DIR:-/usr/local/lib/wdtt}"
WDTT_BIN="${WDTT_BIN:-/usr/local/bin/wdtt-server}"
WDTT_ENV_FILE="${WDTT_ENV_FILE:-$WDTT_CONFIG_DIR/wdtt.env}"
WDTT_FIREWALL_SCRIPT="${WDTT_FIREWALL_SCRIPT:-$WDTT_LIB_DIR/apply-firewall.sh}"

ACTION="install"
PASSWORD="${WDTT_PASSWORD:-}"
VK_LINK="${WDTT_VK_LINK:-}"
PUBLIC_HOST="${WDTT_PUBLIC_HOST:-}"
DTLS_PORT="${WDTT_DTLS_PORT:-56000}"
WG_PORT="${WDTT_WG_PORT:-56001}"
SSH_PORT="${WDTT_SSH_PORT:-22}"
DNS_SERVERS="${WDTT_DNS:-1.1.1.1,1.0.0.1}"
ADMIN_ID="${WDTT_ADMIN_ID:-}"
BOT_TOKEN="${WDTT_BOT_TOKEN:-}"
SOURCE_REPO="${WDTT_SOURCE_REPO:-$WDTT_SOURCE_REPO_DEFAULT}"
SOURCE_REF="${WDTT_SOURCE_REF:-$WDTT_SOURCE_REF_DEFAULT}"
GO_VERSION="${WDTT_GO_VERSION:-$WDTT_GO_VERSION_DEFAULT}"
NO_FIREWALL="${WDTT_NO_FIREWALL:-0}"
PURGE="0"

log() { printf '[wdtt-setup] %s\n' "$*"; }
die() { printf '[wdtt-setup] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
vkturn-vps-setup install.sh

Usage:
  sudo bash install.sh install --password PASS [--vk-link VK_JOIN_URL_OR_HASH]
  sudo bash install.sh status
  sudo bash install.sh logs
  sudo bash install.sh link --vk-link VK_JOIN_URL_OR_HASH
  sudo bash install.sh uninstall [--purge]

Main options:
  --password PASS       WDTT main tunnel password. Required for first install.
  --vk-link VALUE       VK call join URL or bare hash. Used to print iOS link.
  --host VALUE          Public IP or domain for the iOS link.
  --dtls-port PORT      Public WDTT DTLS/WRAP-A UDP port. Default: 56000.
  --wg-port PORT        Internal WireGuard UDP port. Default: 56001.
  --ssh-port PORT       SSH TCP port to keep allowed in iptables. Default: 22.
  --dns VALUE           DNS sent to clients, comma-separated. Default: 1.1.1.1,1.0.0.1.
  --admin-id VALUE      Optional Telegram admin ID for WDTT access manager.
  --bot-token VALUE     Optional Telegram bot token for WDTT access manager.
  --source-repo URL     Source repo to build wdtt-server from.
  --source-ref REF      Branch, tag, or commit. Default: main.
  --go-version VERSION  Go version used if system Go is too old. Default: 1.25.0.
  --no-firewall         Do not install or apply iptables rules.
  --purge               With uninstall: remove /etc/wdtt too.

Environment variables mirror the option names, for example:
  WDTT_PASSWORD, WDTT_VK_LINK, WDTT_PUBLIC_HOST, WDTT_DTLS_PORT, WDTT_WG_PORT.
USAGE
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      install|status|logs|link|uninstall)
        ACTION="$1"
        shift
        ;;
      -h|--help|help)
        usage
        exit 0
        ;;
      --password)
        PASSWORD="${2:-}"
        shift 2
        ;;
      --password=*)
        PASSWORD="${1#*=}"
        shift
        ;;
      --vk-link|--vk-hash)
        VK_LINK="${2:-}"
        shift 2
        ;;
      --vk-link=*|--vk-hash=*)
        VK_LINK="${1#*=}"
        shift
        ;;
      --host|--public-host|--domain)
        PUBLIC_HOST="${2:-}"
        shift 2
        ;;
      --host=*|--public-host=*|--domain=*)
        PUBLIC_HOST="${1#*=}"
        shift
        ;;
      --dtls-port)
        DTLS_PORT="${2:-}"
        shift 2
        ;;
      --dtls-port=*)
        DTLS_PORT="${1#*=}"
        shift
        ;;
      --wg-port)
        WG_PORT="${2:-}"
        shift 2
        ;;
      --wg-port=*)
        WG_PORT="${1#*=}"
        shift
        ;;
      --ssh-port)
        SSH_PORT="${2:-}"
        shift 2
        ;;
      --ssh-port=*)
        SSH_PORT="${1#*=}"
        shift
        ;;
      --dns)
        DNS_SERVERS="${2:-}"
        shift 2
        ;;
      --dns=*)
        DNS_SERVERS="${1#*=}"
        shift
        ;;
      --admin-id)
        ADMIN_ID="${2:-}"
        shift 2
        ;;
      --admin-id=*)
        ADMIN_ID="${1#*=}"
        shift
        ;;
      --bot-token)
        BOT_TOKEN="${2:-}"
        shift 2
        ;;
      --bot-token=*)
        BOT_TOKEN="${1#*=}"
        shift
        ;;
      --source-repo|--repo)
        SOURCE_REPO="${2:-}"
        shift 2
        ;;
      --source-repo=*|--repo=*)
        SOURCE_REPO="${1#*=}"
        shift
        ;;
      --source-ref|--ref)
        SOURCE_REF="${2:-}"
        shift 2
        ;;
      --source-ref=*|--ref=*)
        SOURCE_REF="${1#*=}"
        shift
        ;;
      --go-version)
        GO_VERSION="${2:-}"
        shift 2
        ;;
      --go-version=*)
        GO_VERSION="${1#*=}"
        shift
        ;;
      --no-firewall)
        NO_FIREWALL="1"
        shift
        ;;
      --purge)
        PURGE="1"
        shift
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done
}

need_root() {
  [ "$(id -u)" -eq 0 ] || die "Run as root: sudo bash install.sh $ACTION ..."
}

validate_port() {
  local name="$1" value="$2"
  case "$value" in
    ''|*[!0-9]*) die "$name must be a number from 1 to 65535, got: $value" ;;
  esac
  [ "$value" -ge 1 ] && [ "$value" -le 65535 ] || die "$name must be in range 1..65535, got: $value"
}

validate_password() {
  [ -n "$PASSWORD" ] || die "WDTT password is required. Pass --password or set WDTT_PASSWORD."
  [ "${#PASSWORD}" -ge 8 ] || die "Password is too short. Use at least 8 characters."
  [ "${#PASSWORD}" -le 128 ] || die "Password is too long. Use 128 characters or fewer."
  if ! printf '%s' "$PASSWORD" | grep -Eq '^[A-Za-z0-9._-]+$'; then
    die "For iOS wdtt:// links, use only A-Z, a-z, 0-9, dot, underscore and dash in the password."
  fi
}

validate_inputs() {
  validate_port "WDTT_DTLS_PORT" "$DTLS_PORT"
  validate_port "WDTT_WG_PORT" "$WG_PORT"
  validate_port "WDTT_SSH_PORT" "$SSH_PORT"
  [ -n "$DNS_SERVERS" ] || die "DNS list must not be empty."
  if printf '%s' "$DNS_SERVERS" | grep -q '[[:space:]]'; then
    die "DNS list must not contain whitespace. Use comma-separated values."
  fi
}

load_env_file() {
  [ -f "$WDTT_ENV_FILE" ] || return 0
  # The file is created by this installer and kept shell-compatible.
  # shellcheck disable=SC1090
  . "$WDTT_ENV_FILE"
  [ -z "$PASSWORD" ] && PASSWORD="${WDTT_PASSWORD:-}"
  [ -z "$PUBLIC_HOST" ] && PUBLIC_HOST="${WDTT_PUBLIC_HOST:-}"
  DTLS_PORT="${WDTT_DTLS_PORT:-$DTLS_PORT}"
  WG_PORT="${WDTT_WG_PORT:-$WG_PORT}"
  SSH_PORT="${WDTT_SSH_PORT:-$SSH_PORT}"
  DNS_SERVERS="${WDTT_DNS:-$DNS_SERVERS}"
  ADMIN_ID="${WDTT_ADMIN_ID:-$ADMIN_ID}"
  BOT_TOKEN="${WDTT_BOT_TOKEN:-$BOT_TOKEN}"
  SOURCE_REPO="${WDTT_SOURCE_REPO:-$SOURCE_REPO}"
  SOURCE_REF="${WDTT_SOURCE_REF:-$SOURCE_REF}"
}

detect_os() {
  [ -f /etc/os-release ] || die "/etc/os-release not found."
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-unknown}"
  case "$OS_ID" in
    ubuntu|debian|linuxmint|pop) PKG_MGR="apt" ;;
    fedora) PKG_MGR="dnf" ;;
    centos|rhel|rocky|almalinux|oracle)
      PKG_MGR="yum"
      command -v dnf >/dev/null 2>&1 && PKG_MGR="dnf"
      ;;
    arch|manjaro|endeavouros) PKG_MGR="pacman" ;;
    *) die "Unsupported Linux distribution: $OS_ID" ;;
  esac
  log "OS: ${PRETTY_NAME:-$OS_ID}; package manager: $PKG_MGR"
}

install_packages() {
  log "Installing base packages..."
  case "$PKG_MGR" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      apt-get install -y ca-certificates curl git tar openssl iproute2 iptables nftables procps psmisc
      ;;
    dnf)
      dnf install -y ca-certificates curl git tar openssl iproute iptables nftables procps-ng psmisc
      ;;
    yum)
      yum install -y ca-certificates curl git tar openssl iproute iptables nftables procps-ng psmisc
      ;;
    pacman)
      pacman -Sy --noconfirm --needed ca-certificates curl git tar openssl iproute2 iptables nftables procps-ng psmisc
      ;;
  esac
}

version_ge() {
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
}

system_go_version() {
  command -v go >/dev/null 2>&1 || return 1
  go version | awk '{print $3}' | sed 's/^go//'
}

go_arch() {
  case "$(uname -m)" in
    x86_64|amd64) printf 'amd64' ;;
    aarch64|arm64) printf 'arm64' ;;
    *) die "Unsupported CPU architecture for automatic Go install: $(uname -m)" ;;
  esac
}

ensure_go() {
  local current=""
  if current="$(system_go_version 2>/dev/null)" && version_ge "$current" "$GO_VERSION"; then
    GO_BIN="$(command -v go)"
    log "Using system Go $current at $GO_BIN"
    return 0
  fi

  local arch tarball tmp url
  arch="$(go_arch)"
  url="https://go.dev/dl/go${GO_VERSION}.linux-${arch}.tar.gz"
  tmp="$(mktemp -d)"
  tarball="$tmp/go.tgz"

  log "Installing Go $GO_VERSION for linux-$arch into $WDTT_GO_ROOT..."
  mkdir -p "$WDTT_INSTALL_ROOT"
  curl -fL --retry 3 --connect-timeout 15 -o "$tarball" "$url"
  rm -rf "$WDTT_GO_ROOT"
  tar -C "$WDTT_INSTALL_ROOT" -xzf "$tarball"
  rm -rf "$tmp"

  GO_BIN="$WDTT_GO_ROOT/bin/go"
  [ -x "$GO_BIN" ] || die "Go binary was not installed at $GO_BIN"
  log "Using bundled Go: $("$GO_BIN" version)"
}

fetch_source() {
  log "Fetching WDTT source: $SOURCE_REPO ($SOURCE_REF)"
  mkdir -p "$WDTT_INSTALL_ROOT"
  if [ -d "$WDTT_SOURCE_DIR/.git" ]; then
    git -C "$WDTT_SOURCE_DIR" remote set-url origin "$SOURCE_REPO"
    git -C "$WDTT_SOURCE_DIR" fetch --tags --prune origin
  else
    rm -rf "$WDTT_SOURCE_DIR"
    git clone "$SOURCE_REPO" "$WDTT_SOURCE_DIR"
  fi

  if git -C "$WDTT_SOURCE_DIR" rev-parse --verify --quiet "$SOURCE_REF^{commit}" >/dev/null; then
    git -C "$WDTT_SOURCE_DIR" checkout --force "$SOURCE_REF"
  else
    git -C "$WDTT_SOURCE_DIR" fetch --depth=1 origin "$SOURCE_REF" || true
    git -C "$WDTT_SOURCE_DIR" checkout --force "$SOURCE_REF" 2>/dev/null || git -C "$WDTT_SOURCE_DIR" checkout --force FETCH_HEAD
  fi
  local source_commit
  source_commit="$(git -C "$WDTT_SOURCE_DIR" rev-parse --short HEAD)"
  log "WDTT source commit: $source_commit"
  [ -f "$WDTT_SOURCE_DIR/server.go" ] || die "server.go not found in $WDTT_SOURCE_DIR"
  [ -f "$WDTT_SOURCE_DIR/go.mod" ] || die "go.mod not found in $WDTT_SOURCE_DIR"
}

build_server() {
  local tmp_bin
  tmp_bin="$(mktemp)"
  log "Building wdtt-server..."
  (
    cd "$WDTT_SOURCE_DIR"
    log "Downloading Go modules..."
    GOFLAGS= GOTOOLCHAIN=auto "$GO_BIN" mod download
    GOFLAGS= GOTOOLCHAIN=auto CGO_ENABLED=0 GOOS=linux "$GO_BIN" build -mod=mod -trimpath -ldflags="-s -w" -o "$tmp_bin" server.go
  )
  install -m 0755 "$tmp_bin" "$WDTT_BIN"
  rm -f "$tmp_bin"
  log "Installed $WDTT_BIN"
}

write_env_file() {
  log "Writing $WDTT_ENV_FILE"
  mkdir -p "$WDTT_CONFIG_DIR"
  umask 077
  cat > "$WDTT_ENV_FILE" <<EOF
WDTT_PASSWORD=$PASSWORD
WDTT_DTLS_PORT=$DTLS_PORT
WDTT_WG_PORT=$WG_PORT
WDTT_SSH_PORT=$SSH_PORT
WDTT_DNS=$DNS_SERVERS
WDTT_ADMIN_ID=$ADMIN_ID
WDTT_BOT_TOKEN=$BOT_TOKEN
WDTT_PUBLIC_HOST=$PUBLIC_HOST
WDTT_SOURCE_REPO=$SOURCE_REPO
WDTT_SOURCE_REF=$SOURCE_REF
WDTT_SUBNET=10.66.66.0/24
WDTT_IFACE=wdtt0
WDTT_IPT_COMMENT=WDTT_SETUP
EOF
  chmod 600 "$WDTT_ENV_FILE"
}

write_firewall_script() {
  [ "$NO_FIREWALL" = "1" ] && return 0
  log "Writing firewall helper: $WDTT_FIREWALL_SCRIPT"
  mkdir -p "$WDTT_LIB_DIR"
  cat > "$WDTT_FIREWALL_SCRIPT" <<EOF
#!/usr/bin/env bash
set -u

ENV_FILE="$WDTT_ENV_FILE"
[ -f "\$ENV_FILE" ] && . "\$ENV_FILE"

DTLS="\${WDTT_DTLS_PORT:-56000}"
WG="\${WDTT_WG_PORT:-56001}"
SSH="\${WDTT_SSH_PORT:-22}"
IFACE="\${WDTT_IFACE:-wdtt0}"
SUBNET="\${WDTT_SUBNET:-10.66.66.0/24}"
COMMENT="\${WDTT_IPT_COMMENT:-WDTT_SETUP}"

wan_iface() {
  ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if(\$i=="dev") {print \$(i+1); exit}}'
}

add_input_udp() {
  local port="\$1"
  iptables -C INPUT -p udp --dport "\$port" -m comment --comment "\$COMMENT" -j ACCEPT 2>/dev/null || \\
    iptables -I INPUT -p udp --dport "\$port" -m comment --comment "\$COMMENT" -j ACCEPT 2>/dev/null || true
}

add_input_tcp() {
  local port="\$1"
  iptables -C INPUT -p tcp --dport "\$port" -m comment --comment "\$COMMENT" -j ACCEPT 2>/dev/null || \\
    iptables -I INPUT -p tcp --dport "\$port" -m comment --comment "\$COMMENT" -j ACCEPT 2>/dev/null || true
}

add_forward() {
  iptables -C FORWARD -i "\$IFACE" -m comment --comment "\$COMMENT" -j ACCEPT 2>/dev/null || \\
    iptables -I FORWARD -i "\$IFACE" -m comment --comment "\$COMMENT" -j ACCEPT 2>/dev/null || true
  iptables -C FORWARD -o "\$IFACE" -m comment --comment "\$COMMENT" -j ACCEPT 2>/dev/null || \\
    iptables -I FORWARD -o "\$IFACE" -m comment --comment "\$COMMENT" -j ACCEPT 2>/dev/null || true
}

add_nat() {
  local wan="\$1"
  [ -n "\$wan" ] || return 0
  iptables -t nat -C POSTROUTING -s "\$SUBNET" -o "\$wan" -m comment --comment "\$COMMENT" -j MASQUERADE 2>/dev/null || \\
    iptables -t nat -A POSTROUTING -s "\$SUBNET" -o "\$wan" -m comment --comment "\$COMMENT" -j MASQUERADE 2>/dev/null || true
}

add_mss_clamp() {
  iptables -t mangle -C FORWARD -s "\$SUBNET" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "\$COMMENT" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \\
    iptables -t mangle -I FORWARD -s "\$SUBNET" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "\$COMMENT" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
  iptables -t mangle -C FORWARD -d "\$SUBNET" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "\$COMMENT" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \\
    iptables -t mangle -I FORWARD -d "\$SUBNET" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "\$COMMENT" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
}

command -v iptables >/dev/null 2>&1 || exit 0
add_input_udp "\$DTLS"
add_input_udp "\$WG"
add_input_tcp "\$SSH"
add_forward
add_nat "\$(wan_iface)"
add_mss_clamp
EOF
  chmod 0755 "$WDTT_FIREWALL_SCRIPT"
}

write_systemd_units() {
  log "Writing systemd units"
  cat > /etc/systemd/system/wdtt-firewall.service <<EOF
[Unit]
Description=Apply firewall rules for WDTT
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$WDTT_FIREWALL_SCRIPT
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/wdtt.service <<EOF
[Unit]
Description=WDTT VPN Server
After=network-online.target wdtt-firewall.service
Wants=network-online.target wdtt-firewall.service

[Service]
Type=simple
EnvironmentFile=$WDTT_ENV_FILE
ExecStartPre=-/usr/bin/env bash -c 'ip link show wdtt0 >/dev/null 2>&1 && ip link del wdtt0 >/dev/null 2>&1 || true'
ExecStartPre=$WDTT_FIREWALL_SCRIPT
ExecStart=$WDTT_BIN -listen=0.0.0.0:\${WDTT_DTLS_PORT} -wg-port=\${WDTT_WG_PORT} -config-dir=$WDTT_CONFIG_DIR -password=\${WDTT_PASSWORD} -admin=\${WDTT_ADMIN_ID} -bot-token=\${WDTT_BOT_TOKEN} -dns=\${WDTT_DNS}
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
}

setup_sysctl() {
  log "Enabling IPv4 forwarding"
  mkdir -p /etc/sysctl.d
  cat > /etc/sysctl.d/99-wdtt.conf <<'EOF'
net.ipv4.ip_forward = 1
EOF
  sysctl -p /etc/sysctl.d/99-wdtt.conf >/dev/null || true
}

start_services() {
  command -v systemctl >/dev/null 2>&1 || die "systemctl not found. This installer requires systemd."
  systemctl daemon-reload
  if [ "$NO_FIREWALL" != "1" ]; then
    systemctl enable --now wdtt-firewall.service >/dev/null
  fi
  systemctl enable wdtt.service >/dev/null
  systemctl restart wdtt.service
  sleep 3
  if ! systemctl is-active --quiet wdtt.service; then
    journalctl -u wdtt -n 60 --no-pager >&2 || true
    die "wdtt.service did not become active."
  fi
  log "wdtt.service is active"
}

strip_vk_hash() {
  local s="$1"
  s="${s%%\?*}"
  s="${s%%#*}"
  s="${s##*/}"
  printf '%s' "$s"
}

detect_public_host() {
  if [ -n "$PUBLIC_HOST" ]; then
    printf '%s' "$PUBLIC_HOST"
    return 0
  fi
  if command -v curl >/dev/null 2>&1; then
    local ip
    ip="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
    if [ -n "$ip" ]; then
      printf '%s' "$ip"
      return 0
    fi
  fi
  hostname -I 2>/dev/null | awk '{print $1}'
}

print_ios_link() {
  local host hash
  host="$(detect_public_host)"
  [ -n "$host" ] || host="YOUR_SERVER_IP"
  hash="$(strip_vk_hash "$VK_LINK")"
  [ -n "$hash" ] || hash="VK_HASH"
  printf '\n'
  log "iOS import link:"
  printf 'wdtt://%s:%s:%s:9000:%s:%s\n' "$host" "$DTLS_PORT" "$WG_PORT" "$PASSWORD" "$hash"
  printf '\n'
  log "In the iOS app use SRTP-WRAP-A mode if importing manually."
}

install_wdtt() {
  need_root
  load_env_file
  validate_inputs
  validate_password
  detect_os
  install_packages
  ensure_go
  fetch_source
  build_server
  write_env_file
  setup_sysctl
  write_firewall_script
  write_systemd_units
  start_services
  print_ios_link
}

status_wdtt() {
  need_root
  load_env_file
  validate_inputs
  systemctl status wdtt --no-pager || true
  printf '\nListening UDP sockets:\n'
  ss -lunp 2>/dev/null | grep -E ":($DTLS_PORT|$WG_PORT)\\b" || true
  printf '\nRecent logs:\n'
  journalctl -u wdtt -n 40 --no-pager || true
}

logs_wdtt() {
  need_root
  journalctl -u wdtt -f
}

delete_iptables_rule() {
  local table="$1"
  shift
  for _ in 1 2 3 4 5; do
    if [ "$table" = "filter" ]; then
      iptables -D "$@" 2>/dev/null || break
    else
      iptables -t "$table" -D "$@" 2>/dev/null || break
    fi
  done
}

cleanup_firewall_rules() {
  command -v iptables >/dev/null 2>&1 || return 0
  local comment="${WDTT_IPT_COMMENT:-WDTT_SETUP}"
  local subnet="${WDTT_SUBNET:-10.66.66.0/24}"
  delete_iptables_rule filter INPUT -p udp --dport "$DTLS_PORT" -m comment --comment "$comment" -j ACCEPT
  delete_iptables_rule filter INPUT -p udp --dport "$WG_PORT" -m comment --comment "$comment" -j ACCEPT
  delete_iptables_rule filter INPUT -p tcp --dport "$SSH_PORT" -m comment --comment "$comment" -j ACCEPT
  delete_iptables_rule filter FORWARD -i wdtt0 -m comment --comment "$comment" -j ACCEPT
  delete_iptables_rule filter FORWARD -o wdtt0 -m comment --comment "$comment" -j ACCEPT
  delete_iptables_rule mangle FORWARD -s "$subnet" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "$comment" -j TCPMSS --clamp-mss-to-pmtu
  delete_iptables_rule mangle FORWARD -d "$subnet" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "$comment" -j TCPMSS --clamp-mss-to-pmtu
  for iface in $(ls /sys/class/net 2>/dev/null || true); do
    delete_iptables_rule nat POSTROUTING -s "$subnet" -o "$iface" -m comment --comment "$comment" -j MASQUERADE
  done
}

uninstall_wdtt() {
  need_root
  load_env_file
  validate_inputs
  systemctl stop wdtt.service 2>/dev/null || true
  systemctl disable wdtt.service 2>/dev/null || true
  systemctl stop wdtt-firewall.service 2>/dev/null || true
  systemctl disable wdtt-firewall.service 2>/dev/null || true
  rm -f /etc/systemd/system/wdtt.service /etc/systemd/system/wdtt-firewall.service
  systemctl daemon-reload 2>/dev/null || true
  ip link show wdtt0 >/dev/null 2>&1 && ip link del wdtt0 2>/dev/null || true
  pkill -x wdtt-server 2>/dev/null || true
  cleanup_firewall_rules
  rm -f "$WDTT_BIN"
  rm -rf "$WDTT_LIB_DIR"
  rm -f /etc/sysctl.d/99-wdtt.conf
  if [ "$PURGE" = "1" ]; then
    rm -rf "$WDTT_CONFIG_DIR" "$WDTT_INSTALL_ROOT"
    log "Uninstalled WDTT and removed config/source directories."
  else
    rm -rf "$WDTT_SOURCE_DIR"
    log "Uninstalled WDTT. Kept config/database in $WDTT_CONFIG_DIR."
  fi
}

link_only() {
  load_env_file
  validate_inputs
  validate_password
  print_ios_link
}

main() {
  parse_args "$@"
  case "$ACTION" in
    install) install_wdtt ;;
    status) status_wdtt ;;
    logs) logs_wdtt ;;
    link) link_only ;;
    uninstall) uninstall_wdtt ;;
    *) die "Unsupported action: $ACTION" ;;
  esac
}

main "$@"
