#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  echo "SMOKE FAIL: $*" >&2
  exit 1
}

pass() {
  echo "SMOKE OK: $*"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command is missing: $1"
}

assert_contains() {
  local file="$1" text="$2"
  grep -Fq -- "$text" "$file" || fail "$file does not contain: $text"
}

assert_no_unresolved() {
  local pattern="$1"
  shift
  if grep -nE -- "$pattern" "$@"; then
    fail "rendered files contain unresolved template variables"
  fi
}

check_shell_syntax() {
  local file interpreter
  while IFS= read -r -d '' file; do
    interpreter="$(head -n 1 "$file")"
    case "$interpreter" in
      '#!/bin/sh'*) sh -n "$file" ;;
      *) bash -n "$file" ;;
    esac
    shellcheck --severity=error "$file"
  done < <(find "$ROOT" -type f -name '*.sh' -print0)
  pass "all shell scripts pass parser and ShellCheck error-level checks"
}

check_systemd_installer() {
  local out="$TMP_ROOT/systemd"
  mkdir -p "$out"

  (
    export WDTT_INSTALL_ROOT="$out/opt/wdtt"
    export WDTT_SOURCE_DIR="$out/opt/wdtt/source"
    export WDTT_GO_ROOT="$out/opt/wdtt/go"
    export WDTT_CONFIG_DIR="$out/etc/wdtt"
    export WDTT_LIB_DIR="$out/usr/local/lib/wdtt"
    export WDTT_BIN="$out/usr/local/bin/wdtt-server"
    export WDTT_ENV_FILE="$out/etc/wdtt/wdtt.env"
    export WDTT_FIREWALL_SCRIPT="$out/usr/local/lib/wdtt/apply-firewall.sh"
    export WDTT_RUN_SCRIPT="$out/usr/local/lib/wdtt/run-wdtt.sh"
    export WDTT_NO_FIREWALL_BIN="$out/usr/local/lib/wdtt/no-firewall-bin"

    # shellcheck source=../install.sh
    source "$ROOT/install.sh"
    PASSWORD=smoke-test-password
    PUBLIC_HOST=example.com
    DTLS_PORT=56000
    WG_PORT=56001
    SSH_PORT=22
    DNS_SERVERS=1.1.1.1,1.0.0.1
    validate_inputs
    validate_password
    write_env_file
    write_firewall_script
    write_runtime_script

    bash -n "$WDTT_FIREWALL_SCRIPT"
    bash -n "$WDTT_RUN_SCRIPT"
    [ "$(stat -c '%a' "$WDTT_ENV_FILE")" = 600 ] || fail "systemd environment file is not mode 600"
    assert_contains "$WDTT_FIREWALL_SCRIPT" 'block_external_wg "$WG"'
    assert_contains "$WDTT_FIREWALL_SCRIPT" 'add_input_udp "$DTLS"'
    assert_contains "$WDTT_FIREWALL_SCRIPT" '-I INPUT 1 -i "$IFACE"'
    assert_contains "$WDTT_FIREWALL_SCRIPT" '-I FORWARD 1 -i "$IFACE" -o "$IFACE"'
    assert_contains "$WDTT_FIREWALL_SCRIPT" '-s "$SUBNET" -o "$wan"'
    assert_contains "$WDTT_FIREWALL_SCRIPT" '--ctstate RELATED,ESTABLISHED'
    assert_contains "$WDTT_RUN_SCRIPT" "export PATH=\"$WDTT_NO_FIREWALL_BIN\""
    assert_contains "$WDTT_RUN_SCRIPT" '-password="${WDTT_PASSWORD}"'

    if (DTLS_PORT=56000; WG_PORT=56000; validate_inputs >/dev/null 2>&1); then
      fail "systemd installer accepted colliding DTLS and WG ports"
    fi
  )

  assert_contains "$ROOT/install.sh" 'https://github.com/XXcipherX/proxy-turn-vk-android.git'
  assert_contains "$ROOT/install.sh" 'WDTT_SOURCE_REF_DEFAULT="main-new"'
  assert_contains "$ROOT/install.sh" 'app/src/main/assets/linux-server'
  assert_contains "$ROOT/install.sh" 'ExecStart=$WDTT_RUN_SCRIPT'
  assert_contains "$ROOT/install.sh" 'UMask=0077'
  assert_contains "$ROOT/examples/wdtt.env.example" 'WDTT_SOURCE_REF=main-new'
  pass "systemd installer validation and generated helpers"
}

check_docker_installer() {
  local out="$TMP_ROOT/docker"
  mkdir -p "$out/data"

  (
    # shellcheck source=../vps-setup.sh
    source "$ROOT/vps-setup.sh"
    WDTT_DOCKER_IMAGE=ghcr.io/xxcipherx/wdtt-server:latest
    WDTT_PASSWORD=smoke-test-password
    WDTT_VK_HASH=smoke_hash
    WDTT_PUBLIC_HOST=example.com
    WDTT_DTLS_PORT=56000
    WDTT_WG_PORT=56001
    WDTT_SSH_PORT=22
    WDTT_DNS=1.1.1.1,1.0.0.1
    WDTT_ADMIN_ID=
    WDTT_BOT_TOKEN=
    WDTT_NO_FIREWALL=0
    WDTT_SUBNET=10.66.66.0/24
    validate_config

    if (WDTT_DTLS_PORT=56000; WDTT_WG_PORT=56000; validate_config >/dev/null 2>&1); then
      fail "Docker installer accepted colliding DTLS and WG ports"
    fi
    if (WDTT_SUBNET=10.999.0.0/24; validate_config >/dev/null 2>&1); then
      fail "Docker installer accepted an invalid subnet"
    fi

    export WDTT_DOCKER_IMAGE WDTT_PASSWORD WDTT_VK_HASH WDTT_PUBLIC_HOST
    export WDTT_DTLS_PORT WDTT_WG_PORT WDTT_SSH_PORT WDTT_DNS WDTT_ADMIN_ID
    export WDTT_BOT_TOKEN WDTT_NO_FIREWALL WDTT_SUBNET
    envsubst < "$ROOT/templates_for_script/compose" > "$out/docker-compose.yml"
    envsubst < "$ROOT/templates_for_script/env" > "$out/.env"
  )

  cp "$ROOT/templates_for_script/run-wdtt.sh" "$out/run-wdtt.sh"
  sh -n "$out/run-wdtt.sh"
  docker compose --env-file "$out/.env" -f "$out/docker-compose.yml" config --quiet
  assert_no_unresolved '\$WDTT_[A-Z0-9_]+' "$out/.env" "$out/docker-compose.yml"

  if grep -Eq 'iptables .*(-I|-A) INPUT .*WDTT_WG_PORT.*-j ACCEPT' "$out/run-wdtt.sh"; then
    fail "Docker entrypoint exposes the internal WireGuard port"
  fi
  if grep -Eq 'iptables .*(-I|-A) INPUT .*WDTT_SSH_PORT.*-j ACCEPT' "$out/run-wdtt.sh"; then
    fail "Docker entrypoint changes SSH access policy"
  fi
  assert_contains "$out/run-wdtt.sh" '-I INPUT 1 ! -i lo -p udp --dport "$WDTT_WG_PORT"'
  assert_contains "$out/run-wdtt.sh" '-I INPUT 1 -i wdtt0'
  assert_contains "$out/run-wdtt.sh" '-I FORWARD 1 -i wdtt0 -o wdtt0'
  assert_contains "$out/run-wdtt.sh" '-s "$SUBNET" -o "$WAN"'
  assert_contains "$out/run-wdtt.sh" '--ctstate RELATED,ESTABLISHED'
  assert_contains "$out/run-wdtt.sh" "trap 'cleanup_rules || true' EXIT"
  assert_contains "$out/run-wdtt.sh" 'export PATH="$NO_FIREWALL_BIN"'
  assert_contains "$ROOT/vps-setup.sh" "grep -F '[SERVER] Готов'"
  assert_contains "$ROOT/vps-setup.sh" 'load_saved_config'
  assert_contains "$ROOT/vps-setup.sh" 'chmod 600 "$ENV_FILE"'
  pass "Docker installer validation, rendering, Compose config, and firewall invariants"
}

check_free_turn_installer() {
  local out="$TMP_ROOT/free-turn"
  mkdir -p "$out"

  export FREE_TURN_IMAGE=ghcr.io/samosvalishe/free-turn-proxy:latest
  export FREE_TURN_CONNECT_ADDR=127.0.0.1:51820
  export FREE_TURN_LISTEN_PORT=56000
  export FREE_TURN_SETUP_WG=1
  export FREE_TURN_WG_IFACE=wgfreeturn
  export FREE_TURN_NUM_CONNECTIONS=20
  export FREE_TURN_PUBLIC_HOST=example.com
  export FREE_TURN_MODE=udp
  export FREE_TURN_OBF_PROFILE=rtpopus3
  export FREE_TURN_OBF_KEY=00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff
  export FREE_TURN_OBF_TIMING=0
  export FREE_TURN_CLIENTS_FILE=/app/clients.json
  export FREE_TURN_CLIENT_ID=smoke-client
  export FREE_TURN_DEBUG=0
  export FREE_TURN_WG_SERVER_ADDRESS=10.77.0.1
  export FREE_TURN_WG_PORT=51820
  export FREE_TURN_WG_SERVER_PRIVATE_KEY=server-private-key
  export FREE_TURN_WG_CLIENT_PUBLIC_KEY=client-public-key
  export FREE_TURN_WG_CLIENT_ADDRESS=10.77.0.2
  export FREE_TURN_WG_CIDR=10.77.0.0/24
  export FREE_TURN_WAN_IFACE=eth0
  export FREE_TURN_WG_CLIENT_PRIVATE_KEY=client-private-key
  export FREE_TURN_WG_DNS=1.1.1.1
  export FREE_TURN_WG_SERVER_PUBLIC_KEY=server-public-key
  export FREE_TURN_WG_CLIENT_ENDPOINT=example.com:51820
  export FREE_TURN_INSTALL_DIR=/opt/free-turn-proxy

  (
    # shellcheck source=../free-turn-setup.sh
    source "$ROOT/free-turn-setup.sh"
    validate_config
    if (FREE_TURN_LISTEN_PORT=70000; validate_config >/dev/null 2>&1); then
      fail "Free Turn installer accepted an invalid listen port"
    fi
  )

  envsubst < "$ROOT/templates_for_script/free-turn-compose" > "$out/docker-compose.yml"
  envsubst < "$ROOT/templates_for_script/free-turn-env" > "$out/.env"
  envsubst < "$ROOT/templates_for_script/free-turn-wg.conf" > "$out/wg.conf"
  envsubst < "$ROOT/templates_for_script/free-turn-client-wg.conf" > "$out/client.conf"
  envsubst < "$ROOT/templates_for_script/free-turn-firewall.service" > "$out/firewall.service"
  printf '{}\n' > "$out/clients.json"

  docker compose --env-file "$out/.env" -f "$out/docker-compose.yml" config --quiet
  assert_no_unresolved '\$FREE_TURN_[A-Z0-9_]+' \
    "$out/.env" "$out/docker-compose.yml" "$out/wg.conf" "$out/client.conf" "$out/firewall.service"
  assert_contains "$out/wg.conf" 'PostDown = iptables'
  assert_contains "$out/firewall.service" 'EnvironmentFile=/opt/free-turn-proxy/.env'
  pass "Free Turn templates render and Compose config validates"
}

check_repository_contracts() {
  local workflow="$ROOT/.github/workflows/smoke.yml" empty_tree
  empty_tree="$(git hash-object -t tree /dev/null)"
  git diff --check "$empty_tree" HEAD
  assert_contains "$workflow" 'push:'
  assert_contains "$workflow" 'pull_request:'
  assert_contains "$workflow" 'bash tests/smoke.sh'
  assert_contains "$ROOT/README.md" 'XXcipherX/proxy-turn-vk-android'
  assert_contains "$ROOT/README.md" 'tests/smoke.sh'
  pass "workflow triggers and README references"
}

require_command shellcheck
require_command envsubst
require_command docker
require_command git
docker compose version >/dev/null 2>&1 || fail "docker compose plugin is missing"

check_shell_syntax
check_systemd_installer
check_docker_installer
check_free_turn_installer
check_repository_contracts

echo "All repository smoke tests passed."
