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

assert_not_contains() {
  local file="$1" text="$2"
  if grep -Fq -- "$text" "$file"; then
    fail "$file unexpectedly contains: $text"
  fi
}

assert_no_unresolved() {
  local pattern="$1"
  shift
  if grep -nE -- "$pattern" "$@"; then
    fail "rendered files contain unresolved template variables"
  fi
}

assert_before() {
  local file="$1" first="$2" second="$3" first_line second_line
  first_line="$(grep -nF -- "$first" "$file" | head -n1 | cut -d: -f1)"
  second_line="$(grep -nF -- "$second" "$file" | head -n1 | cut -d: -f1)"
  [ -n "$first_line" ] && [ -n "$second_line" ] && [ "$first_line" -lt "$second_line" ] || \
    fail "$file does not place '$first' before '$second'"
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

    # shellcheck source=../install.sh
    source "$ROOT/install.sh"
    PASSWORD=T7mK2_vQ9-pR4.xL
    PUBLIC_HOST=example.com
    DTLS_PORT=56000
    WG_PORT=56001
    SSH_PORT=22
    DNS_SERVERS=1.1.1.1,1.0.0.1
    validate_inputs
    validate_password

    if (PASSWORD=short-pass1; validate_password >/dev/null 2>&1); then
      fail "systemd installer accepted a password shorter than the server minimum"
    fi
    if (PASSWORD=abcdefghijklmnop; validate_password >/dev/null 2>&1); then
      fail "systemd installer accepted a password with only one character class"
    fi
    if (PASSWORD=aaaaaaaa1_______; validate_password >/dev/null 2>&1); then
      fail "systemd installer accepted fewer than eight distinct password characters"
    fi
    if (PASSWORD=Password1234____; validate_password >/dev/null 2>&1); then
      fail "systemd installer accepted a common weak password pattern"
    fi
    mkdir -p "$WDTT_CONFIG_DIR"
    printf '{"passwords":{},"devices":{}}\n' > "$WDTT_CONFIG_DIR/passwords.json"
    backup_database
    write_env_file
    write_firewall_script
    write_runtime_script

    bash -n "$WDTT_FIREWALL_SCRIPT"
    bash -n "$WDTT_RUN_SCRIPT"
    [ "$(stat -c '%a' "$WDTT_ENV_FILE")" = 600 ] || fail "systemd environment file is not mode 600"
    assert_contains "$WDTT_FIREWALL_SCRIPT" 'block_external_wg "$WG"'
    assert_contains "$WDTT_FIREWALL_SCRIPT" 'add_input_udp "$DTLS"'
    assert_contains "$WDTT_FIREWALL_SCRIPT" 'TCPMSS --clamp-mss-to-pmtu'
    assert_not_contains "$WDTT_FIREWALL_SCRIPT" 'INPUT -i "$IFACE"'
    assert_not_contains "$WDTT_FIREWALL_SCRIPT" 'FORWARD -i "$IFACE"'
    assert_not_contains "$WDTT_FIREWALL_SCRIPT" 'MASQUERADE'
    assert_not_contains "$WDTT_RUN_SCRIPT" 'export PATH='
    assert_contains "$WDTT_RUN_SCRIPT" '-password="${WDTT_PASSWORD}"'
    assert_contains "$WDTT_ENV_FILE" 'WDTT_GO_VERSION=1.26.5'
    [ "$(find "$WDTT_CONFIG_DIR/backups" -type f -name 'passwords-*.json' | wc -l)" -eq 1 ] || fail "systemd installer did not back up passwords.json"
    [ "$(stat -c '%a' "$WDTT_CONFIG_DIR/backups")" = 700 ] || fail "systemd backup directory is not mode 700"

    if (DTLS_PORT=56000; WG_PORT=56000; validate_inputs >/dev/null 2>&1); then
      fail "systemd installer accepted colliding DTLS and WG ports"
    fi
    if (DNS_SERVERS=2606:4700:4700::1111; validate_inputs >/dev/null 2>&1); then
      fail "systemd installer accepted an IPv6 DNS server"
    fi
    if (DNS_SERVERS=1.1.1.1,; validate_inputs >/dev/null 2>&1); then
      fail "systemd installer accepted an empty DNS entry"
    fi
    if (PUBLIC_HOST=192.168.1.10; validate_inputs >/dev/null 2>&1); then
      fail "systemd installer accepted a private public host"
    fi
    if (PUBLIC_HOST=bad_host.example; validate_inputs >/dev/null 2>&1); then
      fail "systemd installer accepted a malformed public DNS name"
    fi
    if (parse_args --no-firewall >/dev/null 2>&1); then
      fail "systemd installer accepted the removed no-firewall mode"
    fi
  )

  assert_contains "$ROOT/install.sh" 'https://github.com/XXcipherX/proxy-turn-vk-android.git'
  assert_contains "$ROOT/install.sh" 'WDTT_SOURCE_REF_DEFAULT="main-new"'
  assert_contains "$ROOT/install.sh" 'WDTT_GO_VERSION_DEFAULT="1.26.5"'
  assert_contains "$ROOT/install.sh" 'app/src/main/assets/linux-server'
  assert_contains "$ROOT/install.sh" 'ExecStart=$WDTT_RUN_SCRIPT'
  assert_contains "$ROOT/install.sh" 'UMask=0077'
  assert_contains "$ROOT/install.sh" "grep -Fq '[SERVER] Готов'"
  assert_contains "$ROOT/install.sh" 'property=MainPID'
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
    WDTT_PASSWORD=T7mK2_vQ9-pR4.xL
    WDTT_VK_HASH=smoke_hash
    WDTT_PUBLIC_HOST=example.com
    WDTT_DTLS_PORT=56000
    WDTT_WG_PORT=56001
    WDTT_SSH_PORT=22
    WDTT_DNS=1.1.1.1,1.0.0.1
    WDTT_ADMIN_ID=
    WDTT_BOT_TOKEN=
    WDTT_SUBNET=10.66.66.0/24
    validate_config

    if (WDTT_PASSWORD=short-pass1; validate_config >/dev/null 2>&1); then
      fail "Docker installer accepted a password shorter than the server minimum"
    fi
    if (WDTT_PASSWORD=abcdefghijklmnop; validate_config >/dev/null 2>&1); then
      fail "Docker installer accepted a password with only one character class"
    fi
    if (WDTT_PASSWORD=aaaaaaaa1_______; validate_config >/dev/null 2>&1); then
      fail "Docker installer accepted fewer than eight distinct password characters"
    fi
    if (WDTT_PASSWORD=Password1234____; validate_config >/dev/null 2>&1); then
      fail "Docker installer accepted a common weak password pattern"
    fi

    if (WDTT_DTLS_PORT=56000; WDTT_WG_PORT=56000; validate_config >/dev/null 2>&1); then
      fail "Docker installer accepted colliding DTLS and WG ports"
    fi
    if (WDTT_SUBNET=10.77.0.0/24; validate_config >/dev/null 2>&1); then
      fail "Docker installer accepted a subnet unsupported by server core"
    fi
    if (WDTT_DNS=2001:4860:4860::8888; validate_config >/dev/null 2>&1); then
      fail "Docker installer accepted an IPv6 DNS server"
    fi
    if (WDTT_DNS=1.1.1.1,; validate_config >/dev/null 2>&1); then
      fail "Docker installer accepted an empty DNS entry"
    fi
    if (WDTT_PUBLIC_HOST=10.0.0.1; validate_config >/dev/null 2>&1); then
      fail "Docker installer accepted a private public host"
    fi
    if (WDTT_PUBLIC_HOST=bad_host.example; validate_config >/dev/null 2>&1); then
      fail "Docker installer accepted a malformed public DNS name"
    fi

    INSTALL_DIR="$out"
    printf '{"passwords":{},"devices":{}}\n' > "$INSTALL_DIR/data/passwords.json"
    backup_database

    export WDTT_DOCKER_IMAGE WDTT_PASSWORD WDTT_VK_HASH WDTT_PUBLIC_HOST
    export WDTT_DTLS_PORT WDTT_WG_PORT WDTT_SSH_PORT WDTT_DNS WDTT_ADMIN_ID
    export WDTT_BOT_TOKEN WDTT_SUBNET
    envsubst < "$ROOT/templates_for_script/compose" > "$out/docker-compose.yml"
    envsubst < "$ROOT/templates_for_script/env" > "$out/.env"
  )

  cp "$ROOT/templates_for_script/run-wdtt.sh" "$out/run-wdtt.sh"
  sh -n "$out/run-wdtt.sh"
  docker compose --env-file "$out/.env" -f "$out/docker-compose.yml" config --quiet
  assert_no_unresolved '\$WDTT_[A-Z0-9_]+' "$out/.env" "$out/docker-compose.yml"
  assert_not_contains "$out/.env" 'WDTT_NO_FIREWALL='
  assert_not_contains "$out/.env" 'WDTT_SUBNET='
  assert_contains "$out/docker-compose.yml" 'driver: json-file'
  assert_contains "$out/docker-compose.yml" 'max-size: "10m"'
  assert_contains "$out/docker-compose.yml" 'max-file: "3"'

  if grep -Eq 'iptables .*(-I|-A) INPUT .*WDTT_WG_PORT.*-j ACCEPT' "$out/run-wdtt.sh"; then
    fail "Docker entrypoint exposes the internal WireGuard port"
  fi
  if grep -Eq 'iptables .*(-I|-A) INPUT .*WDTT_SSH_PORT.*-j ACCEPT' "$out/run-wdtt.sh"; then
    fail "Docker entrypoint changes SSH access policy"
  fi
  assert_contains "$out/run-wdtt.sh" '-I INPUT 1 ! -i lo -p udp --dport "$WDTT_WG_PORT"'
  assert_contains "$out/run-wdtt.sh" 'TCPMSS --clamp-mss-to-pmtu'
  assert_not_contains "$out/run-wdtt.sh" '-I INPUT 1 -i wdtt0'
  assert_not_contains "$out/run-wdtt.sh" 'iptables -w -I FORWARD'
  assert_not_contains "$out/run-wdtt.sh" '-A POSTROUTING'
  assert_contains "$out/run-wdtt.sh" "trap 'cleanup_rules || true' EXIT"
  assert_not_contains "$out/run-wdtt.sh" 'export PATH='
  assert_contains "$ROOT/vps-setup.sh" "grep -F '[SERVER] Готов'"
  assert_contains "$ROOT/vps-setup.sh" 'load_saved_config'
  assert_contains "$ROOT/vps-setup.sh" 'chmod 600 "$ENV_FILE"'
  assert_before "$ROOT/vps-setup.sh" 'docker pull "$WDTT_DOCKER_IMAGE"' 'docker compose -f "$COMPOSE_FILE" down'
  assert_not_contains "$ROOT/vps-setup.sh" 'hostname -I'
  [ "$(find "$out/backups" -type f -name 'passwords-*.json' | wc -l)" -eq 1 ] || fail "Docker installer did not back up passwords.json"
  [ "$(stat -c '%a' "$out/backups")" = 700 ] || fail "Docker backup directory is not mode 700"
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
  export FREE_TURN_NO_FIREWALL=0
  export FREE_TURN_NUM_CONNECTIONS=20
  export FREE_TURN_PUBLIC_HOST=example.com
  export FREE_TURN_MODE=udp
  export FREE_TURN_OBF_PROFILE=rtpopus3
  export FREE_TURN_OBF_KEY=00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff
  export FREE_TURN_OBF_TIMING=0
  export FREE_TURN_CLIENTS_FILE=/app/clients.json
  export FREE_TURN_CLIENT_ID=smoke-client
  export FREE_TURN_CLIENT_NAME=
  export FREE_TURN_VK_LINK=https://vk.ru/call/join/smoke-hash
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
    if ! (parse_args --add-client --client-name iphone --vk-link 'https://vk.ru/call/join/smoke-hash?from=test'; [ "$ACTION" = add-client ] && [ "$FREE_TURN_CLIENT_NAME" = iphone ] && [ "$FREE_TURN_VK_LINK_OVERRIDE" = 1 ]); then
      fail "Free Turn did not parse a named client creation"
    fi
    if ! (parse_args --name-client first-client "home iphone"; [ "$ACTION" = name-client ] && [ "$ACTION_ARG" = first-client ] && [ "$ACTION_ARG2" = "home iphone" ]); then
      fail "Free Turn did not parse an existing client name update"
    fi
    [ "$(normalize_vk_link 'https://vk.com/call/join/smoke-hash?from=test')" = 'https://vk.ru/call/join/smoke-hash' ] ||
      fail "Free Turn did not canonicalize the VK link"

    INSTALL_DIR="$out/vk-state"
    mkdir -p "$INSTALL_DIR"
    printf '%s\n' 'FREE_TURN_VK_LINK=https://vk.com/call/join/saved-hash' > "$(env_file)"
    FREE_TURN_VK_LINK=""
    FREE_TURN_VK_LINK_OVERRIDE=0
    load_existing_stack_config
    [ "$FREE_TURN_VK_LINK" = 'https://vk.ru/call/join/saved-hash' ] ||
      fail "Free Turn did not load the saved VK link"
    FREE_TURN_VK_LINK='https://vk.com/call/join/new-hash?from=test'
    FREE_TURN_VK_LINK_OVERRIDE=1
    load_existing_stack_config
    assert_contains "$(env_file)" 'FREE_TURN_VK_LINK=https://vk.ru/call/join/new-hash'
    if (FREE_TURN_LISTEN_PORT=70000; validate_config >/dev/null 2>&1); then
      fail "Free Turn installer accepted an invalid listen port"
    fi
    if (FREE_TURN_WG_PORT=56000; FREE_TURN_CONNECT_ADDR=127.0.0.1:56000; validate_config >/dev/null 2>&1); then
      fail "Free Turn installer accepted colliding public and backend ports"
    fi
    if (FREE_TURN_WG_IFACE='bad iface'; validate_config >/dev/null 2>&1); then
      fail "Free Turn installer accepted an invalid WireGuard interface"
    fi
    if (FREE_TURN_WG_CIDR=10.77.0.0/16; validate_config >/dev/null 2>&1); then
      fail "Free Turn installer accepted an unsupported WireGuard subnet prefix"
    fi
    if (FREE_TURN_NO_FIREWALL=1; validate_config >/dev/null 2>&1); then
      fail "Free Turn installer allowed the managed WireGuard backend without host firewall protection"
    fi

    printf '%s\n' \
      '[Interface]' \
      'PrivateKey = server-key' \
      '[Peer]' \
      'PublicKey = first-client' \
      'AllowedIPs = 10.77.0.2/32' \
      '[Peer]' \
      'PublicKey = second-client' \
      'AllowedIPs = 10.77.0.3/32' > "$out/existing-wg.conf"
    extract_wg_peers "$out/existing-wg.conf" "$out/preserved-peers.conf"
    assert_contains "$out/preserved-peers.conf" 'PublicKey = first-client'
    assert_contains "$out/preserved-peers.conf" 'PublicKey = second-client'
    assert_not_contains "$out/preserved-peers.conf" 'PrivateKey = server-key'

    INSTALL_DIR="$out/client-state"
    clear_clients_json
    upsert_client_record "$(clients_file)" first-client iphone
    upsert_client_record "$(clients_file)" second-client windows
    upsert_client_record "$(clients_file)" first-client ""
    [ "$(jq -r '.clients["first-client"].comment' "$(clients_file)")" = iphone ] ||
      fail "Free Turn client display name was not preserved"
    [ "$(read_client_ids "$(clients_file)" | wc -l)" -eq 2 ] ||
      fail "Free Turn named client records are not readable"
    if (upsert_client_record "$(clients_file)" third-client iphone >/dev/null 2>&1); then
      fail "Free Turn accepted a duplicate client display name"
    fi
    remove_client_id_from_allowlist second-client
    jq -e '.clients["first-client"].comment == "iphone" and (.clients | has("second-client") | not)' \
      "$(clients_file)" >/dev/null || fail "Free Turn client metadata update lost another record"
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
  assert_contains "$out/wg.conf" 'apply-wg-firewall.sh apply'
  assert_contains "$out/wg.conf" 'apply-wg-firewall.sh remove'
  assert_not_contains "$out/wg.conf" 'FORWARD -i %i -j ACCEPT'
  assert_contains "$out/firewall.service" 'EnvironmentFile=/opt/free-turn-proxy/.env'
  assert_contains "$out/firewall.service" 'ExecStop=/usr/local/lib/free-turn-proxy/apply-firewall.sh remove'
  assert_contains "$out/.env" 'FREE_TURN_VK_LINK=https://vk.ru/call/join/smoke-hash'
  assert_contains "$ROOT/templates_for_script/free-turn-firewall.sh" '! -i lo -p udp --dport "$FREE_TURN_WG_PORT" -j DROP'
  assert_contains "$ROOT/templates_for_script/free-turn-firewall.sh" '-i "$FREE_TURN_WG_IFACE" -j DROP'
  assert_contains "$ROOT/templates_for_script/free-turn-firewall.sh" 'apply_rules ip6tables "$ACTION"'
  assert_contains "$ROOT/templates_for_script/free-turn-wg-firewall.sh" '-i "$IFACE" -o "$IFACE" -m comment --comment "$COMMENT" -j DROP'
  assert_contains "$ROOT/templates_for_script/free-turn-wg-firewall.sh" '-i "$IFACE" -s "$CIDR" -o "$WAN"'
  assert_contains "$ROOT/templates_for_script/free-turn-wg-firewall.sh" 'COMMENT=FREE_TURN_WG'
  assert_contains "$ROOT/free-turn-setup.sh" 'FREE_TURN_NUM_CONNECTIONS="${FREE_TURN_NUM_CONNECTIONS:-10}"'
  assert_contains "$ROOT/free-turn-setup.sh" 'extract_wg_peers "$server_conf" "$peers_tmp"'
  assert_contains "$ROOT/free-turn-setup.sh" 'sync_client_server_public_key "$server_pub"'
  assert_contains "$ROOT/free-turn-setup.sh" 'sudo bash free-turn-setup.sh --name-client <client-id> <name>'
  assert_not_contains "$ROOT/free-turn-setup.sh" 'health_check || true'
  assert_not_contains "$ROOT/free-turn-setup.sh" 'up -d --force-recreate >/dev/null 2>&1 || true'
  pass "Free Turn validation, peer preservation, firewall invariants, and Compose rendering"
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
require_command jq
require_command docker
require_command git
docker compose version >/dev/null 2>&1 || fail "docker compose plugin is missing"

check_shell_syntax
check_systemd_installer
check_docker_installer
check_free_turn_installer
check_repository_contracts

echo "All repository smoke tests passed."
