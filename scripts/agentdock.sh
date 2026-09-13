set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$ROOT_DIR/config.yaml"
RUNTIME="$ROOT_DIR/.runtime"
COMPOSE="$RUNTIME/compose.yaml"
PROFILE="$RUNTIME/tunnel-profile.yaml"
TOKEN_FILE="$RUNTIME/agentdock.token"
PID_FILE="$RUNTIME/tunnel-client.pid"
LOG_FILE="$RUNTIME/tunnel-client.log"

fail() { echo "ERROR: $*" >&2; exit 1; }

cfg() {
  local key="$1" line value
  line="$(grep -E "^[[:space:]]*${key}[[:space:]]*:" "$CONFIG" | tail -n1 || true)"
  [ -n "$line" ] || fail "Missing config key: $key"
  value="${line#*:}"
  value="$(printf '%s' "$value" | sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//')"
  case "$value" in
    \'*\'|\"*\") value="${value:1:${#value}-2}" ;;
  esac
  printf '%s' "$value"
}

load_config() {
  [ -f "$CONFIG" ] || {
    cp "$ROOT_DIR/config.example.yaml" "$CONFIG"
    fail "Created config.yaml. Edit it, then run again."
  }
  TUNNEL_ID="$(cfg tunnel_id)"
  RUNTIME_API_KEY="$(cfg runtime_api_key)"
  PORT="$(cfg agentdock_port)"
  WORKSPACE="$(cfg workspace_path)"
  [ "$TUNNEL_ID" != "TUNNEL_ID_HERE" ] || fail "Set tunnel_id in config.yaml"
  [ "$RUNTIME_API_KEY" != "RUNTIME_API_KEY_HERE" ] || fail "Set runtime_api_key in config.yaml"
  [ "$WORKSPACE" != "CHANGE_ME" ] || fail "Set workspace_path in config.yaml"
  [ -d "$WORKSPACE" ] || mkdir -p "$WORKSPACE"
  WORKSPACE="$(cd "$WORKSPACE" && pwd -P)"
}

require_tools() {
  command -v docker >/dev/null 2>&1 || fail "Docker CLI not found. See README."
  docker info >/dev/null 2>&1 || fail "Docker Engine is not running. See README."
  docker compose version >/dev/null 2>&1 || fail "Docker Compose plugin not found. See README."
  command -v tunnel-client >/dev/null 2>&1 || fail "tunnel-client not found in PATH. See README."
}

random_token() {
  if command -v openssl >/dev/null 2>&1; then openssl rand -hex 32; else od -An -N32 -tx1 /dev/urandom | tr -d ' \n'; fi
}

prepare_runtime() {
  mkdir -p "$RUNTIME"
  chmod 700 "$RUNTIME" 2>/dev/null || true
  local token
  token="$(cat "$TOKEN_FILE" 2>/dev/null || true)"
  [ -n "$token" ] || { token="$(random_token)"; printf '%s' "$token" > "$TOKEN_FILE"; chmod 600 "$TOKEN_FILE" 2>/dev/null || true; }
  local escaped="${WORKSPACE//\'/\'\'}"
  cat > "$COMPOSE" <<EOF
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
    healthcheck:
      test: ["CMD", "agentdock-healthcheck"]
      interval: 15s
      timeout: 5s
      start_period: 10s
      retries: 4
volumes:
  agentdock_home:
EOF
  cat > "$PROFILE" <<EOF
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
  chmod 600 "$COMPOSE" "$PROFILE" 2>/dev/null || true
}

pid_alive() {
  [ -f "$PID_FILE" ] || return 1
  local p
  p="$(cat "$PID_FILE" 2>/dev/null || true)"
  [ -n "$p" ] && kill -0 "$p" 2>/dev/null
}

install_cmd() {
  load_config
  require_tools
  prepare_runtime
  docker compose -f "$COMPOSE" pull
  echo "Installed. Next: ./agentdock start"
}

start_cmd() {
  load_config
  require_tools
  prepare_runtime
  docker compose -f "$COMPOSE" up -d
  local token
  token="$(cat "$TOKEN_FILE")"
  export CONTROL_PLANE_API_KEY="$RUNTIME_API_KEY"
  export AGENTDOCK_BEARER_HEADER="Bearer $token"
  if ! pid_alive; then
    nohup tunnel-client run --profile-file "$PROFILE" >> "$LOG_FILE" 2>&1 </dev/null &
    echo $! > "$PID_FILE"
    sleep 2
    pid_alive || fail "tunnel-client failed. Run ./agentdock logs"
  fi
  echo "AgentDock : RUNNING  http://127.0.0.1:${PORT}/mcp"
  echo "Tunnel    : RUNNING  ${TUNNEL_ID}"
  echo "Workspace : ${WORKSPACE}"
}

stop_cmd() {
  if pid_alive; then kill "$(cat "$PID_FILE")" 2>/dev/null || true; fi
  rm -f "$PID_FILE"
  if [ -f "$COMPOSE" ] && command -v docker >/dev/null 2>&1; then docker compose -f "$COMPOSE" down; fi
  echo "Stopped."
}

status_cmd() {
  load_config
  local a="STOPPED" t="STOPPED"
  curl -fsS "http://127.0.0.1:${PORT}/healthz" >/dev/null 2>&1 && a="RUNNING" || true
  pid_alive && t="RUNNING" || true
  echo "AgentDock : $a"
  echo "Tunnel    : $t"
  echo "MCP       : http://127.0.0.1:${PORT}/mcp"
  echo "Workspace : ${WORKSPACE}"
}

logs_cmd() {
  [ -f "$COMPOSE" ] && docker compose -f "$COMPOSE" logs --tail 100 agentdock || true
  [ -f "$LOG_FILE" ] && { echo "--- tunnel-client ---"; tail -n 100 "$LOG_FILE"; }
}

case "${1:-help}" in
  install) install_cmd ;;
  start) start_cmd ;;
  stop) stop_cmd ;;
  restart) stop_cmd; start_cmd ;;
  status) status_cmd ;;
  logs) logs_cmd ;;
  update) load_config; require_tools; prepare_runtime; docker compose -f "$COMPOSE" pull; echo "Updated AgentDock image." ;;
  *) echo "Usage: ./agentdock {install|start|stop|restart|status|logs|update}" ;;
esac
