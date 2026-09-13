#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$ROOT_DIR/config.yaml"
RUNTIME="$ROOT_DIR/.runtime"
BIN_DIR="$RUNTIME/bin"
COMPOSE="$RUNTIME/compose.yaml"
PROFILE="$RUNTIME/tunnel-profile.yaml"
TOKEN_FILE="$RUNTIME/agentdock.token"
MODE_FILE="$RUNTIME/deployment.txt"
TUNNEL_PID="$RUNTIME/tunnel-client.pid"
TUNNEL_LOG="$RUNTIME/tunnel-client.log"
NATIVE_PID="$RUNTIME/agentdock-native.pid"
NATIVE_LOG="$RUNTIME/agentdock-native.log"
NATIVE_HOME="$RUNTIME/agentdock-home"
TUNNEL_BIN="$BIN_DIR/tunnel-client"
NATIVE_BIN="$BIN_DIR/agentdock"

fail(){ echo "ERROR: $*" >&2; exit 1; }

cfg(){
  local key="$1" line value
  line="$(grep -E "^[[:space:]]*${key}[[:space:]]*:" "$CONFIG" | tail -n1 || true)"
  [ -n "$line" ] || return 1
  value="${line#*:}"
  value="$(printf '%s' "$value" | sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//')"
  case "$value" in \'*\'|\"*\") value="${value:1:${#value}-2}";; esac
  printf '%s' "$value"
}

load_config(){
  [ -f "$CONFIG" ] || { cp "$ROOT_DIR/config.example.yaml" "$CONFIG"; fail "Created config.yaml. Edit it, then run again."; }
  MODE="$(cfg deployment_mode || printf auto)"; MODE="$(printf '%s' "$MODE"|tr '[:upper:]' '[:lower:]')"
  case "$MODE" in auto|docker|native) ;; *) fail "deployment_mode must be auto, docker, or native";; esac
  TUNNEL_ID="$(cfg tunnel_id)"; RUNTIME_API_KEY="$(cfg runtime_api_key)"; PORT="$(cfg agentdock_port)"; WORKSPACE="$(cfg workspace_path)"
  [ "$TUNNEL_ID" != TUNNEL_ID_HERE ] || fail "Set tunnel_id in config.yaml"
  [ "$RUNTIME_API_KEY" != RUNTIME_API_KEY_HERE ] || fail "Set runtime_api_key in config.yaml"
  [ "$WORKSPACE" != CHANGE_ME ] || fail "Set workspace_path in config.yaml"
  case "$PORT" in ''|*[!0-9]*) fail "Invalid agentdock_port";; esac
  [ -d "$WORKSPACE" ] || mkdir -p "$WORKSPACE"
  WORKSPACE="$(cd "$WORKSPACE" && pwd -P)"
}

platform(){ case "$(uname -s)" in Linux) printf linux;; Darwin) printf darwin;; *) fail "Unsupported OS: $(uname -s)";; esac; }
arch(){ case "$(uname -m)" in x86_64|amd64) printf amd64;; arm64|aarch64) printf arm64;; *) fail "Unsupported architecture: $(uname -m)";; esac; }
random_token(){ if command -v openssl >/dev/null 2>&1; then openssl rand -hex 32; else od -An -N32 -tx1 /dev/urandom|tr -d ' \n'; fi; }

latest_asset_url(){
  local repo="$1" regex="$2"
  command -v curl >/dev/null 2>&1 || fail "curl is required"
  curl -fsSL -H 'Accept: application/vnd.github+json' -H 'User-Agent: agentdock-secure-tunnel' "https://api.github.com/repos/${repo}/releases/latest" |
    grep -o '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]*"' |
    sed -E 's/.*"(https:[^"]+)"/\1/' |
    grep -E "$regex" | head -n1
}

extract_archive(){
  local archive="$1" dest="$2"
  rm -rf "$dest"; mkdir -p "$dest"
  case "$archive" in *.zip) command -v unzip >/dev/null 2>&1 || fail "unzip is required"; unzip -q "$archive" -d "$dest";; *.tar.gz|*.tgz) tar -xzf "$archive" -C "$dest";; *) fail "Unsupported archive: $archive";; esac
}

install_tunnel_client(){
  local force="${1:-}"
  mkdir -p "$BIN_DIR"
  [ ! -x "$TUNNEL_BIN" ] || [ "$force" = force ] || return 0
  echo "Installing tunnel-client locally..."
  local os a url archive tmp
  os="$(platform)"; a="$(arch)"
  url="$(latest_asset_url openai/tunnel-client "tunnel-client-runtime-cloudflared-v.*-${os}-${a}\\.(zip|tar\\.gz)$")"
  [ -n "$url" ] || fail "No tunnel-client release asset found for ${os}/${a}"
  archive="$RUNTIME/$(basename "$url")"; tmp="$RUNTIME/tunnel-extract"
  curl -fL "$url" -o "$archive"; extract_archive "$archive" "$tmp"
  local found; found="$(find "$tmp" -type f -name 'tunnel-client*' ! -name '*.sha256' | head -n1)"
  [ -n "$found" ] || fail "tunnel-client binary not found in archive"
  cp "$found" "$TUNNEL_BIN"; chmod 700 "$TUNNEL_BIN"; rm -rf "$archive" "$tmp"
}

install_native_agentdock(){
  local force="${1:-}"
  mkdir -p "$BIN_DIR" "$NATIVE_HOME"
  [ ! -x "$NATIVE_BIN" ] || [ "$force" = force ] || return 0
  echo "Installing AgentDock locally (native mode)..."
  local os a url archive tmp ext
  os="$(platform)"; a="$(arch)"
  if [ "$os" = darwin ]; then ext='tar\.gz'; else ext='tar\.gz'; fi
  url="$(latest_asset_url uvwt/agentdock "agentdock_${os}_${a}\\.${ext}$")"
  [ -n "$url" ] || fail "No AgentDock release asset found for ${os}/${a}"
  archive="$RUNTIME/$(basename "$url")"; tmp="$RUNTIME/agentdock-extract"
  curl -fL "$url" -o "$archive"; extract_archive "$archive" "$tmp"
  local found; found="$(find "$tmp" -type f -name agentdock | head -n1)"
  [ -n "$found" ] || fail "AgentDock binary not found in archive"
  cp "$found" "$NATIVE_BIN"; chmod 700 "$NATIVE_BIN"; rm -rf "$archive" "$tmp"
}

docker_ok(){ command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; }
select_mode(){
  if [ "$MODE" = native ]; then printf native; return; fi
  if docker_ok; then printf docker; return; fi
  [ "$MODE" != docker ] || fail "Docker mode requested but Docker Engine/Compose is unavailable. Install Docker Engine and retry."
  echo >&2; echo "Docker was not found. Docker mode is recommended because it isolates AgentDock from other host directories." >&2
  if [ -t 0 ]; then
    printf 'Continue with native host installation instead? Native mode has NO container directory isolation. [y/N] ' >&2
    read -r answer
    case "$answer" in y|Y|yes|YES) printf native; return;; esac
  fi
  fail "Install/start Docker Engine and retry, or set deployment_mode: native explicitly."
}

ensure_token(){ mkdir -p "$RUNTIME"; chmod 700 "$RUNTIME" 2>/dev/null||true; local t; t="$(cat "$TOKEN_FILE" 2>/dev/null||true)"; [ -n "$t" ] || { t="$(random_token)"; printf '%s' "$t">"$TOKEN_FILE"; chmod 600 "$TOKEN_FILE"; }; printf '%s' "$t"; }
prepare_profile(){
  local token="$1"
  cat >"$PROFILE" <<EOF
config_version: 1
control_plane:
  tunnel_id: ${TUNNEL_ID}
  api_key: env:CONTROL_PLANE_API_KEY
mcp:
  server_urls:
    - channel: main
      url: http://127.0.0.1:${PORT}/mcp
  extra_headers:
    Authorization: env:AGENTDOCK_BEARER_HEADER
  discovery_extra_headers:
    Authorization: env:AGENTDOCK_BEARER_HEADER
admin_ui:
  open_browser: false
EOF
  chmod 600 "$PROFILE" 2>/dev/null||true
}
prepare_docker(){
  local token="$1" escaped="${WORKSPACE//\'/\'\'}"
  cat >"$COMPOSE" <<EOF
services:
  agentdock:
    image: ghcr.io/uvwt/agentdock:latest
    container_name: agentdock-secure-tunnel
    restart: unless-stopped
    ports:
      - "127.0.0.1:${PORT}:8765"
    environment:
      AGENTDOCK_HOST: "0.0.0.0"
      AGENTDOCK_PORT: "8765"
      AGENTDOCK_OAUTH_ENABLED: "false"
      AGENTDOCK_AUTH_TOKEN: "${token}"
      AGENTDOCK_DEFAULT_DIR: "/home/agentdock/AgentDock"
    volumes:
      - agentdock_home:/home/agentdock/.agentdock
      - '${escaped}:/home/agentdock/AgentDock'
    security_opt:
      - no-new-privileges:true
volumes:
  agentdock_home:
EOF
}
pid_alive(){ [ -f "$1" ] && kill -0 "$(cat "$1" 2>/dev/null)" 2>/dev/null; }
installed_mode(){ [ -f "$MODE_FILE" ] || fail "Run install first."; cat "$MODE_FILE"; }

start_native(){
  local token="$1"; install_native_agentdock
  if ! pid_alive "$NATIVE_PID"; then
    AGENTDOCK_HOST=127.0.0.1 AGENTDOCK_PORT="$PORT" AGENTDOCK_HOME="$NATIVE_HOME" AGENTDOCK_DEFAULT_DIR="$WORKSPACE" AGENTDOCK_AUTH_TOKEN="$token" AGENTDOCK_OAUTH_ENABLED=false \
      nohup "$NATIVE_BIN" >>"$NATIVE_LOG" 2>&1 </dev/null & echo $! >"$NATIVE_PID"
  fi
}
start_tunnel(){
  local token="$1"
  if ! pid_alive "$TUNNEL_PID"; then
    CONTROL_PLANE_API_KEY="$RUNTIME_API_KEY" AGENTDOCK_BEARER_HEADER="Bearer $token" \
      nohup "$TUNNEL_BIN" run --profile-file "$PROFILE" >>"$TUNNEL_LOG" 2>&1 </dev/null & echo $! >"$TUNNEL_PID"
    sleep 2; pid_alive "$TUNNEL_PID" || fail "tunnel-client failed. Run logs."
  fi
}

install_cmd(){
  load_config; mkdir -p "$RUNTIME" "$BIN_DIR"; install_tunnel_client
  local chosen token; chosen="$(select_mode)"; token="$(ensure_token)"; prepare_profile "$token"; printf '%s' "$chosen">"$MODE_FILE"
  if [ "$chosen" = docker ]; then prepare_docker "$token"; docker compose -f "$COMPOSE" pull; echo "Installed in Docker mode."; else install_native_agentdock; echo "WARNING: Native mode has no container directory isolation."; fi
  echo "Next: ./agentdock start"
}
start_cmd(){
  load_config; install_tunnel_client; local chosen token; chosen="$(installed_mode)"; token="$(ensure_token)"; prepare_profile "$token"
  if [ "$chosen" = docker ]; then docker_ok || fail "Docker Engine is not running"; prepare_docker "$token"; docker compose -f "$COMPOSE" up -d; else start_native "$token"; fi
  local i; for i in $(seq 1 50); do curl -fsS "http://127.0.0.1:${PORT}/healthz" >/dev/null 2>&1 && break; sleep .5; [ "$i" -lt 50 ] || fail "AgentDock health check failed. Run logs."; done
  start_tunnel "$token"; echo "AgentDock : RUNNING  http://127.0.0.1:${PORT}/mcp"; echo "Tunnel    : RUNNING  ${TUNNEL_ID}"; echo "Mode      : ${chosen}"; echo "Workspace : ${WORKSPACE}"
}
stop_cmd(){
  pid_alive "$TUNNEL_PID" && kill "$(cat "$TUNNEL_PID")" 2>/dev/null||true; rm -f "$TUNNEL_PID"
  if [ -f "$MODE_FILE" ]; then case "$(installed_mode)" in docker) docker_ok && [ -f "$COMPOSE" ] && docker compose -f "$COMPOSE" down||true;; native) pid_alive "$NATIVE_PID" && kill "$(cat "$NATIVE_PID")" 2>/dev/null||true;; esac; fi
  rm -f "$NATIVE_PID"; echo "Stopped."
}
status_cmd(){
  load_config; local a=STOPPED t=STOPPED m='NOT INSTALLED'; curl -fsS "http://127.0.0.1:${PORT}/healthz" >/dev/null 2>&1&&a=RUNNING||true; pid_alive "$TUNNEL_PID"&&t=RUNNING||true; [ ! -f "$MODE_FILE" ]||m="$(installed_mode)"
  echo "AgentDock : $a"; echo "Tunnel    : $t"; echo "Mode      : $m"; echo "MCP       : http://127.0.0.1:${PORT}/mcp"; echo "Workspace : ${WORKSPACE}"
}
logs_cmd(){
  if [ -f "$MODE_FILE" ] && [ "$(installed_mode)" = docker ] && docker_ok && [ -f "$COMPOSE" ]; then docker compose -f "$COMPOSE" logs --tail 100 agentdock||true; fi
  [ -f "$NATIVE_LOG" ]&&{ echo '--- AgentDock native ---';tail -n100 "$NATIVE_LOG"; }||true
  [ -f "$TUNNEL_LOG" ]&&{ echo '--- tunnel-client ---';tail -n100 "$TUNNEL_LOG"; }||true
}
update_cmd(){ load_config; install_tunnel_client force; case "$(installed_mode)" in docker) docker compose -f "$COMPOSE" pull;; native) install_native_agentdock force;; esac; echo "Updated local runtime components."; }

case "${1:-help}" in install)install_cmd;;start)start_cmd;;stop)stop_cmd;;restart)stop_cmd;sleep 1;start_cmd;;status)status_cmd;;logs)logs_cmd;;update)update_cmd;;*)echo "Usage: ./agentdock {install|start|stop|restart|status|logs|update}";;esac
