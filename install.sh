#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_VERSION="0.3.0"

WDTT_SOURCE_REPO_DEFAULT="https://github.com/XXcipherX/proxy-turn-vk-android.git"
WDTT_SOURCE_REF_DEFAULT="main-new"
WDTT_GO_VERSION_DEFAULT="1.26.5"

WDTT_INSTALL_ROOT="${WDTT_INSTALL_ROOT:-/opt/wdtt}"
WDTT_SOURCE_DIR="${WDTT_SOURCE_DIR:-$WDTT_INSTALL_ROOT/source}"
WDTT_GO_ROOT="${WDTT_GO_ROOT:-$WDTT_INSTALL_ROOT/go}"
WDTT_CONFIG_DIR="${WDTT_CONFIG_DIR:-/etc/wdtt}"
WDTT_LIB_DIR="${WDTT_LIB_DIR:-/usr/local/lib/wdtt}"
WDTT_BIN="${WDTT_BIN:-/usr/local/bin/wdtt-server}"
WDTT_ENV_FILE="${WDTT_ENV_FILE:-$WDTT_CONFIG_DIR/wdtt.env}"
WDTT_FIREWALL_SCRIPT="${WDTT_FIREWALL_SCRIPT:-$WDTT_LIB_DIR/apply-firewall.sh}"
WDTT_RUN_SCRIPT="${WDTT_RUN_SCRIPT:-$WDTT_LIB_DIR/run-wdtt.sh}"

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
PURGE="0"
PREVIOUS_DTLS_PORT=""
PREVIOUS_WG_PORT=""
PREVIOUS_SSH_PORT=""
PREVIOUS_SUBNET="10.66.66.0/24"

PASSWORD_SET=0; [ "${WDTT_PASSWORD+x}" = "x" ] && PASSWORD_SET=1
VK_LINK_SET=0; [ "${WDTT_VK_LINK+x}" = "x" ] && VK_LINK_SET=1
PUBLIC_HOST_SET=0; [ "${WDTT_PUBLIC_HOST+x}" = "x" ] && PUBLIC_HOST_SET=1
DTLS_PORT_SET=0; [ "${WDTT_DTLS_PORT+x}" = "x" ] && DTLS_PORT_SET=1
WG_PORT_SET=0; [ "${WDTT_WG_PORT+x}" = "x" ] && WG_PORT_SET=1
SSH_PORT_SET=0; [ "${WDTT_SSH_PORT+x}" = "x" ] && SSH_PORT_SET=1
DNS_SERVERS_SET=0; [ "${WDTT_DNS+x}" = "x" ] && DNS_SERVERS_SET=1
ADMIN_ID_SET=0; [ "${WDTT_ADMIN_ID+x}" = "x" ] && ADMIN_ID_SET=1
BOT_TOKEN_SET=0; [ "${WDTT_BOT_TOKEN+x}" = "x" ] && BOT_TOKEN_SET=1
SOURCE_REPO_SET=0; [ "${WDTT_SOURCE_REPO+x}" = "x" ] && SOURCE_REPO_SET=1
SOURCE_REF_SET=0; [ "${WDTT_SOURCE_REF+x}" = "x" ] && SOURCE_REF_SET=1
GO_VERSION_SET=0; [ "${WDTT_GO_VERSION+x}" = "x" ] && GO_VERSION_SET=1

log() { printf '[wdtt-setup] %s\n' "$*"; }
die() { printf '[wdtt-setup] ERROR: %s\n' "$*" >&2; exit 1; }

require_arg() {
  [ "$#" -ge 2 ] || die "$1 requires a value."
  case "$2" in
    --*) die "$1 requires a value, got another option: $2" ;;
  esac
}

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
  --ssh-port PORT       SSH TCP port saved for compatibility/cleanup. Default: 22.
  --dns VALUE           IPv4 DNS sent to clients, comma-separated. Default: 1.1.1.1,1.0.0.1.
  --admin-id VALUE      Optional Telegram admin ID for WDTT access manager.
  --bot-token VALUE     Optional Telegram bot token for WDTT access manager.
  --source-repo URL     Source repo to build wdtt-server from.
  --source-ref REF      Branch, tag, or commit. Default: main-new.
  --go-version VERSION  Go version used if system Go is too old. Default: 1.26.5.
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
        require_arg "$@"
        PASSWORD="${2:-}"
        PASSWORD_SET=1
        shift 2
        ;;
      --password=*)
        PASSWORD="${1#*=}"
        PASSWORD_SET=1
        shift
        ;;
      --vk-link|--vk-hash)
        require_arg "$@"
        VK_LINK="${2:-}"
        VK_LINK_SET=1
        shift 2
        ;;
      --vk-link=*|--vk-hash=*)
        VK_LINK="${1#*=}"
        VK_LINK_SET=1
        shift
        ;;
      --host|--public-host|--domain)
        require_arg "$@"
        PUBLIC_HOST="${2:-}"
        PUBLIC_HOST_SET=1
        shift 2
        ;;
      --host=*|--public-host=*|--domain=*)
        PUBLIC_HOST="${1#*=}"
        PUBLIC_HOST_SET=1
        shift
        ;;
      --dtls-port)
        require_arg "$@"
        DTLS_PORT="${2:-}"
        DTLS_PORT_SET=1
        shift 2
        ;;
      --dtls-port=*)
        DTLS_PORT="${1#*=}"
        DTLS_PORT_SET=1
        shift
        ;;
      --wg-port)
        require_arg "$@"
        WG_PORT="${2:-}"
        WG_PORT_SET=1
        shift 2
        ;;
      --wg-port=*)
        WG_PORT="${1#*=}"
        WG_PORT_SET=1
        shift
        ;;
      --ssh-port)
        require_arg "$@"
        SSH_PORT="${2:-}"
        SSH_PORT_SET=1
        shift 2
        ;;
      --ssh-port=*)
        SSH_PORT="${1#*=}"
        SSH_PORT_SET=1
        shift
        ;;
      --dns)
        require_arg "$@"
        DNS_SERVERS="${2:-}"
        DNS_SERVERS_SET=1
        shift 2
        ;;
      --dns=*)
        DNS_SERVERS="${1#*=}"
        DNS_SERVERS_SET=1
        shift
        ;;
      --admin-id)
        require_arg "$@"
        ADMIN_ID="${2:-}"
        ADMIN_ID_SET=1
        shift 2
        ;;
      --admin-id=*)
        ADMIN_ID="${1#*=}"
        ADMIN_ID_SET=1
        shift
        ;;
      --bot-token)
        require_arg "$@"
        BOT_TOKEN="${2:-}"
        BOT_TOKEN_SET=1
        shift 2
        ;;
      --bot-token=*)
        BOT_TOKEN="${1#*=}"
        BOT_TOKEN_SET=1
        shift
        ;;
      --source-repo|--repo)
        require_arg "$@"
        SOURCE_REPO="${2:-}"
        SOURCE_REPO_SET=1
        shift 2
        ;;
      --source-repo=*|--repo=*)
        SOURCE_REPO="${1#*=}"
        SOURCE_REPO_SET=1
        shift
        ;;
      --source-ref|--ref)
        require_arg "$@"
        SOURCE_REF="${2:-}"
        SOURCE_REF_SET=1
        shift 2
        ;;
      --source-ref=*|--ref=*)
        SOURCE_REF="${1#*=}"
        SOURCE_REF_SET=1
        shift
        ;;
      --go-version)
        require_arg "$@"
        GO_VERSION="${2:-}"
        GO_VERSION_SET=1
        shift 2
        ;;
      --go-version=*)
        GO_VERSION="${1#*=}"
        GO_VERSION_SET=1
        shift
        ;;
      --no-firewall|--with-firewall)
        die "$1 is no longer supported: the current WDTT server requires iptables and owns tunnel firewall/NAT rules."
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

validate_no_whitespace() {
  local name="$1" value="$2"
  if printf '%s' "$value" | grep -q '[[:space:]]'; then
    die "$name must not contain whitespace."
  fi
}

validate_safe_value() {
  local name="$1" value="$2"
  [ -z "$value" ] && return 0
  if ! printf '%s' "$value" | grep -Eq '^[A-Za-z0-9._:/,@+=-]*$'; then
    die "$name contains unsupported characters."
  fi
}

validate_public_host() {
  [ -z "$PUBLIC_HOST" ] && return 0
  validate_public_host_value "$PUBLIC_HOST" || \
    die "WDTT_PUBLIC_HOST must be a public IPv4 address or valid public DNS name without scheme, path or port."
}

validate_ipv4_address() {
  local value="$1" octets=() octet
  IFS='.' read -r -a octets <<< "$value"
  [ "${#octets[@]}" -eq 4 ] || return 1
  for octet in "${octets[@]}"; do
    case "$octet" in
      ''|*[!0-9]*) return 1 ;;
    esac
    if [ "$octet" != "0" ] && [ "${octet#0}" != "$octet" ]; then
      return 1
    fi
    [ "$octet" -le 255 ] || return 1
  done
}

is_public_ipv4_address() {
  local value="$1" octets=() first second
  validate_ipv4_address "$value" || return 1
  IFS='.' read -r -a octets <<< "$value"
  first=$((10#${octets[0]}))
  second=$((10#${octets[1]}))
  [ "$first" -ne 0 ] && [ "$first" -ne 10 ] && [ "$first" -ne 127 ] && [ "$first" -lt 224 ] || return 1
  { [ "$first" -ne 169 ] || [ "$second" -ne 254 ]; } || return 1
  { [ "$first" -ne 172 ] || [ "$second" -lt 16 ] || [ "$second" -gt 31 ]; } || return 1
  { [ "$first" -ne 192 ] || [ "$second" -ne 168 ]; } || return 1
}

validate_public_dns_name() {
  local value="${1,,}" labels=() label
  [ "${#value}" -le 253 ] || return 1
  [ "$value" != "localhost" ] && [[ "$value" == *.* ]] || return 1
  case "$value" in .*|*.) return 1 ;; esac
  IFS='.' read -r -a labels <<< "$value"
  [ "${#labels[@]}" -ge 2 ] || return 1
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
    return
  fi
  validate_public_dns_name "$value"
}

validate_dns_servers() {
  local servers="$1" values=() server
  case "$servers" in
    ,*|*,|*,,*) die "WDTT_DNS must be a comma-separated list of IPv4 addresses without empty entries." ;;
  esac
  IFS=',' read -r -a values <<< "$servers"
  [ "${#values[@]}" -gt 0 ] || die "WDTT_DNS must contain at least one IPv4 address."
  for server in "${values[@]}"; do
    validate_ipv4_address "$server" || die "WDTT_DNS entry must be an IPv4 address, got: $server"
  done
}

validate_abs_path() {
  local name="$1" value="$2"
  [ -n "$value" ] || die "$name must not be empty."
  case "$value" in
    /*) ;;
    *) die "$name must be an absolute path, got: $value" ;;
  esac
  validate_no_whitespace "$name" "$value"
}

validate_safe_rm_path() {
  local name="$1" value="$2" abs=""
  validate_abs_path "$name" "$value"
  abs="$(readlink -m -- "$value" 2>/dev/null || printf '%s' "$value")"
  case "$abs" in
    /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/opt|/proc|/root|/run|/sbin|/sys|/tmp|/usr|/usr/bin|/usr/local|/usr/local/bin|/var)
      die "$name points to a protected path: $abs"
      ;;
  esac
}

validate_inputs() {
  validate_port "WDTT_DTLS_PORT" "$DTLS_PORT"
  validate_port "WDTT_WG_PORT" "$WG_PORT"
  validate_port "WDTT_SSH_PORT" "$SSH_PORT"
  [ -n "$DNS_SERVERS" ] || die "DNS list must not be empty."
  validate_no_whitespace "WDTT_DNS" "$DNS_SERVERS"
  validate_dns_servers "$DNS_SERVERS"
  [ -n "$SOURCE_REPO" ] || die "WDTT_SOURCE_REPO must not be empty."
  [ -n "$SOURCE_REF" ] || die "WDTT_SOURCE_REF must not be empty."
  validate_no_whitespace "WDTT_SOURCE_REPO" "$SOURCE_REPO"
  validate_no_whitespace "WDTT_SOURCE_REF" "$SOURCE_REF"
  validate_no_whitespace "WDTT_GO_VERSION" "$GO_VERSION"
  validate_no_whitespace "WDTT_BOT_TOKEN" "$BOT_TOKEN"
  validate_no_whitespace "WDTT_PUBLIC_HOST" "$PUBLIC_HOST"
  validate_safe_value "WDTT_DNS" "$DNS_SERVERS"
  validate_safe_value "WDTT_BOT_TOKEN" "$BOT_TOKEN"
  validate_safe_value "WDTT_PUBLIC_HOST" "$PUBLIC_HOST"
  validate_public_host
  validate_safe_value "WDTT_SOURCE_REPO" "$SOURCE_REPO"
  validate_safe_value "WDTT_SOURCE_REF" "$SOURCE_REF"
  validate_safe_value "WDTT_GO_VERSION" "$GO_VERSION"
  if [ -n "$ADMIN_ID" ] && ! printf '%s' "$ADMIN_ID" | grep -Eq '^[0-9]+$'; then
    die "WDTT_ADMIN_ID must be numeric."
  fi
  validate_safe_rm_path "WDTT_INSTALL_ROOT" "$WDTT_INSTALL_ROOT"
  validate_safe_rm_path "WDTT_SOURCE_DIR" "$WDTT_SOURCE_DIR"
  validate_safe_rm_path "WDTT_GO_ROOT" "$WDTT_GO_ROOT"
  validate_safe_rm_path "WDTT_CONFIG_DIR" "$WDTT_CONFIG_DIR"
  validate_safe_rm_path "WDTT_LIB_DIR" "$WDTT_LIB_DIR"
  validate_abs_path "WDTT_BIN" "$WDTT_BIN"
  validate_abs_path "WDTT_ENV_FILE" "$WDTT_ENV_FILE"
  validate_abs_path "WDTT_FIREWALL_SCRIPT" "$WDTT_FIREWALL_SCRIPT"
  validate_abs_path "WDTT_RUN_SCRIPT" "$WDTT_RUN_SCRIPT"
  [ "$DTLS_PORT" != "$WG_PORT" ] || die "WDTT_DTLS_PORT and WDTT_WG_PORT must be different."
}

load_env_file() {
  [ -f "$WDTT_ENV_FILE" ] || return 0
  # The file is created by this installer and kept shell-compatible.
  # shellcheck disable=SC1090
  . "$WDTT_ENV_FILE"
  PREVIOUS_DTLS_PORT="${WDTT_DTLS_PORT:-}"
  PREVIOUS_WG_PORT="${WDTT_WG_PORT:-}"
  PREVIOUS_SSH_PORT="${WDTT_SSH_PORT:-}"
  PREVIOUS_SUBNET="${WDTT_SUBNET:-10.66.66.0/24}"
  [ "$PASSWORD_SET" = "0" ] && PASSWORD="${WDTT_PASSWORD:-$PASSWORD}"
  [ "$PUBLIC_HOST_SET" = "0" ] && PUBLIC_HOST="${WDTT_PUBLIC_HOST:-$PUBLIC_HOST}"
  [ "$DTLS_PORT_SET" = "0" ] && DTLS_PORT="${WDTT_DTLS_PORT:-$DTLS_PORT}"
  [ "$WG_PORT_SET" = "0" ] && WG_PORT="${WDTT_WG_PORT:-$WG_PORT}"
  [ "$SSH_PORT_SET" = "0" ] && SSH_PORT="${WDTT_SSH_PORT:-$SSH_PORT}"
  [ "$DNS_SERVERS_SET" = "0" ] && DNS_SERVERS="${WDTT_DNS:-$DNS_SERVERS}"
  [ "$ADMIN_ID_SET" = "0" ] && ADMIN_ID="${WDTT_ADMIN_ID:-$ADMIN_ID}"
  [ "$BOT_TOKEN_SET" = "0" ] && BOT_TOKEN="${WDTT_BOT_TOKEN:-$BOT_TOKEN}"
  [ "$SOURCE_REPO_SET" = "0" ] && SOURCE_REPO="${WDTT_SOURCE_REPO:-$SOURCE_REPO}"
  [ "$SOURCE_REF_SET" = "0" ] && SOURCE_REF="${WDTT_SOURCE_REF:-$SOURCE_REF}"
  [ "$GO_VERSION_SET" = "0" ] && GO_VERSION="${WDTT_GO_VERSION:-$GO_VERSION}"
  unset WDTT_NO_FIREWALL WDTT_SUBNET
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
      apt-get install -y ca-certificates curl git tar openssl iproute2 iptables procps psmisc
      ;;
    dnf)
      dnf install -y ca-certificates curl git tar openssl iproute iptables procps-ng psmisc
      ;;
    yum)
      yum install -y ca-certificates curl git tar openssl iproute iptables procps-ng psmisc
      ;;
    pacman)
      pacman -Sy --noconfirm --needed ca-certificates curl git tar openssl iproute2 iptables procps-ng psmisc
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
    git -C "$WDTT_SOURCE_DIR" fetch --tags --prune origin
  fi

  if git -C "$WDTT_SOURCE_DIR" rev-parse --verify --quiet "refs/remotes/origin/$SOURCE_REF^{commit}" >/dev/null; then
    git -C "$WDTT_SOURCE_DIR" checkout --force -B "$SOURCE_REF" "refs/remotes/origin/$SOURCE_REF"
  elif git -C "$WDTT_SOURCE_DIR" rev-parse --verify --quiet "refs/tags/$SOURCE_REF^{commit}" >/dev/null; then
    git -C "$WDTT_SOURCE_DIR" checkout --force "refs/tags/$SOURCE_REF"
  elif git -C "$WDTT_SOURCE_DIR" rev-parse --verify --quiet "$SOURCE_REF^{commit}" >/dev/null; then
    git -C "$WDTT_SOURCE_DIR" checkout --force "$SOURCE_REF"
  else
    git -C "$WDTT_SOURCE_DIR" fetch --depth=1 origin "$SOURCE_REF"
    git -C "$WDTT_SOURCE_DIR" checkout --force FETCH_HEAD
  fi
  local source_commit
  source_commit="$(git -C "$WDTT_SOURCE_DIR" rev-parse --short HEAD)"
  log "WDTT source commit: $source_commit"
  SERVER_SOURCE_DIR="$WDTT_SOURCE_DIR/app/src/main/assets/linux-server"
  if [ ! -f "$SERVER_SOURCE_DIR/go.mod" ]; then
    die "Current WDTT server module not found at $SERVER_SOURCE_DIR"
  fi
  [ -f "$SERVER_SOURCE_DIR/main.go" ] || die "main.go not found in $SERVER_SOURCE_DIR"
}

build_server() {
  local tmp_bin
  tmp_bin="$(mktemp)"
  log "Building wdtt-server..."
  (
    cd "$SERVER_SOURCE_DIR"
    log "Downloading Go modules..."
    GOFLAGS= GOTOOLCHAIN=auto "$GO_BIN" mod download
    GOFLAGS= GOTOOLCHAIN=auto CGO_ENABLED=0 GOOS=linux "$GO_BIN" build -mod=readonly -trimpath -ldflags="-s -w -checklinkname=0" -o "$tmp_bin" .
  )
  install -m 0755 "$tmp_bin" "$WDTT_BIN"
  rm -f "$tmp_bin"
  log "Installed $WDTT_BIN"
}

backup_database() {
  local source="$WDTT_CONFIG_DIR/passwords.json" backup_dir="$WDTT_CONFIG_DIR/backups" backup
  [ -f "$source" ] || return 0
  mkdir -p "$backup_dir"
  chmod 700 "$backup_dir"
  backup="$backup_dir/passwords-$(date -u +%Y%m%dT%H%M%SZ)-$$.json"
  cp -p -- "$source" "$backup"
  chmod 600 "$backup"
  log "Backed up WDTT database to $backup"
}

write_env_file() {
  log "Writing $WDTT_ENV_FILE"
  mkdir -p "$WDTT_CONFIG_DIR"
  (
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
WDTT_GO_VERSION=$GO_VERSION
WDTT_IPT_COMMENT=WDTT_SETUP
EOF
  )
  chmod 600 "$WDTT_ENV_FILE"
}

write_firewall_script() {
  log "Writing firewall helper: $WDTT_FIREWALL_SCRIPT"
  mkdir -p "$WDTT_LIB_DIR"
  cat > "$WDTT_FIREWALL_SCRIPT" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

ENV_FILE="$WDTT_ENV_FILE"
[ -f "\$ENV_FILE" ] && . "\$ENV_FILE"

DTLS="\${WDTT_DTLS_PORT:-56000}"
WG="\${WDTT_WG_PORT:-56001}"
SUBNET=10.66.66.0/24
COMMENT="\${WDTT_IPT_COMMENT:-WDTT_SETUP}"

add_input_udp() {
  local port="\$1"
  iptables -w -C INPUT -p udp --dport "\$port" -m comment --comment "\$COMMENT" -j ACCEPT 2>/dev/null || \\
    iptables -w -I INPUT -p udp --dport "\$port" -m comment --comment "\$COMMENT" -j ACCEPT
}

block_external_wg() {
  local port="\$1"
  iptables -w -C INPUT ! -i lo -p udp --dport "\$port" -m comment --comment "\$COMMENT" -j DROP 2>/dev/null || \\
    iptables -w -I INPUT 1 ! -i lo -p udp --dport "\$port" -m comment --comment "\$COMMENT" -j DROP
  if command -v ip6tables >/dev/null 2>&1 && [ -s /proc/net/if_inet6 ]; then
    ip6tables -w -C INPUT ! -i lo -p udp --dport "\$port" -m comment --comment "\$COMMENT" -j DROP 2>/dev/null || \\
      ip6tables -w -I INPUT 1 ! -i lo -p udp --dport "\$port" -m comment --comment "\$COMMENT" -j DROP
  fi
}

add_mss_clamp() {
  iptables -w -t mangle -C FORWARD -s "\$SUBNET" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "\$COMMENT" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \\
    iptables -w -t mangle -I FORWARD -s "\$SUBNET" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "\$COMMENT" -j TCPMSS --clamp-mss-to-pmtu
  iptables -w -t mangle -C FORWARD -d "\$SUBNET" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "\$COMMENT" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \\
    iptables -w -t mangle -I FORWARD -d "\$SUBNET" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "\$COMMENT" -j TCPMSS --clamp-mss-to-pmtu
}

command -v iptables >/dev/null 2>&1 || { echo "iptables is required by the current WDTT server" >&2; exit 1; }
add_input_udp "\$DTLS"
block_external_wg "\$WG"
add_mss_clamp
EOF
  chmod 0755 "$WDTT_FIREWALL_SCRIPT"
}

write_runtime_script() {
  log "Writing WDTT runtime helper: $WDTT_RUN_SCRIPT"
  mkdir -p "$WDTT_LIB_DIR"
  rm -rf "$WDTT_LIB_DIR/no-firewall-bin"
  cat > "$WDTT_RUN_SCRIPT" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

ENV_FILE="$WDTT_ENV_FILE"
[ -f "\$ENV_FILE" ] && . "\$ENV_FILE"

exec "$WDTT_BIN" \\
  -listen="0.0.0.0:\${WDTT_DTLS_PORT}" \\
  -wg-port="\${WDTT_WG_PORT}" \\
  -config-dir="$WDTT_CONFIG_DIR" \\
  -password="\${WDTT_PASSWORD}" \\
  -admin="\${WDTT_ADMIN_ID:-}" \\
  -bot-token="\${WDTT_BOT_TOKEN:-}" \\
  -dns="\${WDTT_DNS}"
EOF
  chmod 0755 "$WDTT_RUN_SCRIPT"
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
ExecStart=$WDTT_RUN_SCRIPT
Restart=always
RestartSec=5
LimitNOFILE=65535
UMask=0077

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
  local attempt=0 pid_before="" pid_after="" started_at
  command -v systemctl >/dev/null 2>&1 || die "systemctl not found. This installer requires systemd."
  systemctl daemon-reload
  systemctl enable --now wdtt-firewall.service >/dev/null
  systemctl enable wdtt.service >/dev/null
  started_at="$(date +%s)"
  systemctl restart wdtt.service
  while [ "$attempt" -lt 30 ]; do
    if systemctl is-active --quiet wdtt.service && \
      journalctl -u wdtt.service --since "@$started_at" -o cat --no-pager 2>/dev/null | grep -Fq '[SERVER] Готов'; then
      pid_before="$(systemctl show wdtt.service --property=MainPID --value)"
      sleep 2
      pid_after="$(systemctl show wdtt.service --property=MainPID --value)"
      if [ -n "$pid_before" ] && [ "$pid_before" != "0" ] && [ "$pid_before" = "$pid_after" ] && \
        systemctl is-active --quiet wdtt.service; then
        log "wdtt.service reported readiness and remained active"
        return 0
      fi
    fi
    sleep 1
    attempt=$((attempt + 1))
  done
  journalctl -u wdtt.service -n 80 --no-pager >&2 || true
  die "wdtt.service did not report stable readiness within 30 seconds."
}

strip_vk_hash() {
  local s="$1"
  s="${s%%\?*}"
  s="${s%%#*}"
  while [ "${s%/}" != "$s" ]; do
    s="${s%/}"
  done
  s="${s##*/}"
  case "$s" in
    ''|call|join) s="" ;;
  esac
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
    if is_public_ipv4_address "$ip"; then
      printf '%s' "$ip"
      return 0
    fi
  fi
  return 1
}

print_ios_link() {
  local host hash
  host="$(detect_public_host || true)"
  if [ -z "$host" ]; then
    printf '\n'
    log "Public host could not be detected; set WDTT_PUBLIC_HOST or --public-host before generating a wdtt:// link."
    return 0
  fi
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
  backup_database
  build_server
  if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet wdtt.service; then
    systemctl stop wdtt.service || die "Could not stop the running wdtt.service before replacing firewall rules."
  fi
  cleanup_firewall_rules
  write_env_file
  setup_sysctl
  write_firewall_script
  write_runtime_script
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
      iptables -w -D "$@" 2>/dev/null || break
    else
      iptables -w -t "$table" -D "$@" 2>/dev/null || break
    fi
  done
}

delete_ip6tables_rule() {
  command -v ip6tables >/dev/null 2>&1 || return 0
  for _ in 1 2 3 4 5; do
    ip6tables -w -D "$@" 2>/dev/null || break
  done
}

cleanup_firewall_rules_for() {
  command -v iptables >/dev/null 2>&1 || return 0
  local dtls="$1" wg="$2" ssh="$3" subnet="$4" comment iface
  for comment in WDTT_SETUP WDTT_MANAGED; do
    if [ -n "$dtls" ]; then
      delete_iptables_rule filter INPUT -p udp --dport "$dtls" -m comment --comment "$comment" -j ACCEPT
    fi
    if [ -n "$wg" ]; then
      delete_iptables_rule filter INPUT -p udp --dport "$wg" -m comment --comment "$comment" -j ACCEPT
      delete_iptables_rule filter INPUT ! -i lo -p udp --dport "$wg" -m comment --comment "$comment" -j DROP
      delete_ip6tables_rule INPUT ! -i lo -p udp --dport "$wg" -m comment --comment "$comment" -j DROP
    fi
    if [ -n "$ssh" ]; then
      delete_iptables_rule filter INPUT -p tcp --dport "$ssh" -m comment --comment "$comment" -j ACCEPT
    fi
    delete_iptables_rule filter FORWARD -i wdtt0 -m comment --comment "$comment" -j ACCEPT
    delete_iptables_rule filter FORWARD -o wdtt0 -m comment --comment "$comment" -j ACCEPT
    delete_iptables_rule filter FORWARD -o wdtt0 -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment "$comment" -j ACCEPT
    delete_iptables_rule filter INPUT -i wdtt0 -m comment --comment "$comment" -j DROP
    delete_iptables_rule filter FORWARD -i wdtt0 -o wdtt0 -m comment --comment "$comment" -j DROP
    delete_iptables_rule filter FORWARD -i wdtt0 -m comment --comment "$comment" -j DROP
    delete_iptables_rule filter FORWARD -o wdtt0 -m comment --comment "$comment" -j DROP
    delete_iptables_rule mangle FORWARD -s "$subnet" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "$comment" -j TCPMSS --clamp-mss-to-pmtu
    delete_iptables_rule mangle FORWARD -d "$subnet" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "$comment" -j TCPMSS --clamp-mss-to-pmtu
    for iface in $(ls /sys/class/net 2>/dev/null || true); do
      delete_iptables_rule filter FORWARD -i wdtt0 -s "$subnet" -o "$iface" -m comment --comment "$comment" -j ACCEPT
      delete_iptables_rule filter FORWARD -i "$iface" -o wdtt0 -d "$subnet" -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment "$comment" -j ACCEPT
      delete_iptables_rule nat POSTROUTING -s "$subnet" -o "$iface" -m comment --comment "$comment" -j MASQUERADE
    done
  done
}

cleanup_firewall_rules() {
  cleanup_firewall_rules_for "$DTLS_PORT" "$WG_PORT" "$SSH_PORT" "${WDTT_SUBNET:-10.66.66.0/24}"
  if [ -n "$PREVIOUS_DTLS_PORT$PREVIOUS_WG_PORT$PREVIOUS_SSH_PORT" ]; then
    cleanup_firewall_rules_for "$PREVIOUS_DTLS_PORT" "$PREVIOUS_WG_PORT" "$PREVIOUS_SSH_PORT" "$PREVIOUS_SUBNET"
  fi
  if command -v nft >/dev/null 2>&1; then
    nft delete table inet wdtt >/dev/null 2>&1 || true
  fi
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

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
