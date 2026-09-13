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
NATIVE_PID="$RUNTIME/agentdock-native.pid"
TUNNEL_LOG="$RUNTIME/tunnel-client.log"
NATIVE_LOG="$RUNTIME/agentdock-native.log"
NATIVE_HOME="$RUNTIME/agentdock-home"

fail() { echo "ERROR: $*" >&2; exit 1; }
strip_quotes() {
  local v="$1"
  v="$(printf '%s' "$v" | sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//')"
  case "$v" in \'*\'|\"*\") v="${v:1:${#v}-2}" ;; esac
  printf '%s' "$v"
}
top_cfg() {
  local key="$1" line
  line="$(awk -v k="$key" 'BEGIN{ws=0} /^workspaces:[[:space:]]*$/ {ws=1} !ws && $0 ~ "^[[:space:]]*" k "[[:space:]]*:" {print; exit}' "$CONFIG")"
  [ -n "$line" ] || fail "Missing config key: $key"
  strip_quotes "${line#*:}"
}
read_workspaces() {
  awk '
    function trim(s){gsub(/^[ \t]+|[ \t]+$/, "", s); return s}
    function unquote(s){s=trim(s); if((substr(s,1,1)=="\047" && substr(s,length(s),1)=="\047") || (substr(s,1,1)=="\"" && substr(s,length(s),1)=="\"")) s=substr(s,2,length(s)-2); return s}
    function emit(){if(name!=""){if(mode=="")mode="rw"; print name "\t" path "\t" mode}}
    /^workspaces:[[:space:]]*$/ {inws=1; next}
    inws && /^[^[:space:]-]/ {emit(); exit}
    inws && /^[[:space:]]*-[[:space:]]+name[[:space:]]*:/ {emit(); name=$0; sub(/^[^:]*:/,"",name); name=unquote(name); path=""; mode="rw"; next}
    inws && /^[[:space:]]+path[[:space:]]*:/ {path=$0; sub(/^[^:]*:/,"",path); path=unquote(path); next}
    inws && /^[[:space:]]+mode[[:space:]]*:/ {mode=$0; sub(/^[^:]*:/,"",mode); mode=unquote(mode); next}
    END{if(inws)emit()}
  ' "$CONFIG"
}
load_config() {
  [ -f "$CONFIG" ] || { cp "$ROOT_DIR/config.example.yaml" "$CONFIG"; fail "Created config.yaml. Edit it, then run again."; }
  DEPLOYMENT_MODE="$(top_cfg deployment_mode)"
  TUNNEL_ID="$(top_cfg tunnel_id)"
  RUNTIME_API_KEY="$(top_cfg runtime_api_key)"
  PORT="$(top_cfg agentdock_port)"
  DEFAULT_WORKSPACE="$(top_cfg default_workspace)"
  case "$DEPLOYMENT_MODE" in auto|docker|native) ;; *) fail "deployment_mode must be auto, docker, or native" ;; esac
  [ "$TUNNEL_ID" != "TUNNEL_ID_HERE" ] || fail "Set tunnel_id in config.yaml"
  [ "$RUNTIME_API_KEY" != "RUNTIME_API_KEY_HERE" ] || fail "Set runtime_api_key in config.yaml"
  [[ "$PORT" =~ ^[0-9]+$ ]] || fail "agentdock_port must be numeric"
  [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || fail "agentdock_port out of range"
  WORKSPACES="$(read_workspaces)"
  [ -n "$WORKSPACES" ] || fail "At least one workspace is required"
  local found=0
  while IFS=$'\t' read -r name path mode; do
    [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || fail "Invalid workspace name: $name"
    [ -n "$path" ] || fail "Workspace $name has empty path"
    case "$mode" in rw|ro) ;; *) fail "Workspace $name mode must be rw or ro" ;; esac
    [ "$name" = "$DEFAULT_WORKSPACE" ] && found=1
    [ -d "$path" ] || mkdir -p "$path" 2>/dev/null || fail "Workspace does not exist and could not be created: $path"
  done <<< "$WORKSPACES"
  [ "$found" -eq 1 ] || fail "default_workspace '$DEFAULT_WORKSPACE' is not defined under workspaces"
}
workspace_path_by_name() {
  local wanted="$1"
  while IFS=$'\t' read -r name path mode; do [ "$name" = "$wanted" ] && { printf '%s' "$path"; return; }; done <<< "$WORKSPACES"
  fail "Unknown workspace: $wanted"
}
random_token() { if command -v openssl >/dev/null 2>&1; then openssl rand -hex 32; else od -An -N32 -tx1 /dev/urandom | tr -d ' \n'; fi; }
get_token() { mkdir -p "$RUNTIME"; chmod 700 "$RUNTIME" 2>/dev/null || true; [ -s "$TOKEN_FILE" ] || { random_token > "$TOKEN_FILE"; chmod 600 "$TOKEN_FILE" 2>/dev/null || true; }; cat "$TOKEN_FILE"; }
os_name() { case "$(uname -s)" in Darwin) echo darwin;; Linux) echo linux;; *) fail "Unsupported OS";; esac; }
arch_name() { case "$(uname -m)" in x86_64|amd64) echo amd64;; arm64|aarch64) echo arm64;; *) fail "Unsupported architecture";; esac; }
latest_asset_url() {
  local repo="$1" pattern="$2"
  curl -fsSL -H 'User-Agent: agentdock-secure-tunnel' "https://api.github.com/repos/$repo/releases/latest" | grep 'browser_download_url' | cut -d '"' -f 4 | grep -E "$pattern" | head -n1
}
install_tunnel_client() {
  mkdir -p "$BIN_DIR"; [ -x "$BIN_DIR/tunnel-client" ] && return 0
  local os arch url archive tmp
  os="$(os_name)"; arch="$(arch_name)"
  if [ "$os" = darwin ]; then pattern="tunnel-client-runtime-cloudflared-v.+-darwin-${arch}\\.tar\\.gz$"; else pattern="tunnel-client-runtime-cloudflared-v.+-linux-${arch}\\.tar\\.gz$"; fi
  url="$(latest_asset_url openai/tunnel-client "$pattern")"; [ -n "$url" ] || fail "Unable to locate tunnel-client release asset"
  archive="$RUNTIME/tunnel-client.tar.gz"; tmp="$RUNTIME/tunnel-extract"; rm -rf "$tmp"; mkdir -p "$tmp"
  curl -fL "$url" -o "$archive"; tar -xzf "$archive" -C "$tmp"
  local bin; bin="$(find "$tmp" -type f -name 'tunnel-client*' ! -name '*.sha256' | head -n1)"; [ -n "$bin" ] || fail "tunnel-client binary not found"
  cp "$bin" "$BIN_DIR/tunnel-client"; chmod +x "$BIN_DIR/tunnel-client"; rm -rf "$archive" "$tmp"
}
install_native_agentdock() {
  mkdir -p "$BIN_DIR" "$NATIVE_HOME"; [ -x "$BIN_DIR/agentdock" ] && return 0
  local os arch pattern url archive tmp
  os="$(os_name)"; arch="$(arch_name)"; pattern="agentdock_${os}_${arch}\\.tar\\.gz$"
  url="$(latest_asset_url uvwt/agentdock "$pattern")"; [ -n "$url" ] || fail "Unable to locate AgentDock release asset"
  archive="$RUNTIME/agentdock.tar.gz"; tmp="$RUNTIME/agentdock-extract"; rm -rf "$tmp"; mkdir -p "$tmp"
  curl -fL "$url" -o "$archive"; tar -xzf "$archive" -C "$tmp"
  local bin; bin="$(find "$tmp" -type f -name agentdock | head -n1)"; [ -n "$bin" ] || fail "AgentDock binary not found"
  cp "$bin" "$BIN_DIR/agentdock"; chmod +x "$BIN_DIR/agentdock"; rm -rf "$archive" "$tmp"
}
docker_ready() { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; }
select_mode() {
  [ "$DEPLOYMENT_MODE" = native ] && { echo native; return; }
  docker_ready && { echo docker; return; }
  [ "$DEPLOYMENT_MODE" = docker ] && fail "Docker mode requested but Docker Engine/Compose is unavailable"
  echo "Docker is not available. Docker mode is recommended for host-directory isolation." >&2
  printf 'Continue with native AgentDock? Native mode has NO container directory isolation. [y/N] ' >&2
  read -r answer
  case "$answer" in y|Y|yes|YES) echo native;; *) fail "Install/start Docker Engine, or set deployment_mode: native";; esac
}
write_profile() {
  local token="$1"
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
}
write_compose() {
  local token="$1" default_container="/workspaces/${DEFAULT_WORKSPACE}"
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
      AGENTDOCK_DEFAULT_DIR: "${default_container}"
    volumes:
      - agentdock_home:/home/agentdock/.agentdock
EOF
  while IFS=$'\t' read -r name path mode; do
    escaped="${path//\'/\'\'}"
    printf "      - '%s:/workspaces/%s:%s'\n" "$escaped" "$name" "$mode" >> "$COMPOSE"
  done <<< "$WORKSPACES"
  cat >> "$COMPOSE" <<EOF
    security_opt:
      - no-new-privileges:true
volumes:
  agentdock_home:
EOF
}
pid_alive() { [ -f "$1" ] && kill -0 "$(cat "$1" 2>/dev/null)" 2>/dev/null; }
start_native() {
  local token="$1" default_path
  install_native_agentdock; default_path="$(workspace_path_by_name "$DEFAULT_WORKSPACE")"
  echo "WARNING: native mode cannot enforce workspace mounts or ro/rw isolation; all entries are informational." >&2
  if ! pid_alive "$NATIVE_PID"; then
    AGENTDOCK_HOST=127.0.0.1 AGENTDOCK_PORT="$PORT" AGENTDOCK_HOME="$NATIVE_HOME" AGENTDOCK_DEFAULT_DIR="$default_path" AGENTDOCK_AUTH_TOKEN="$token" AGENTDOCK_OAUTH_ENABLED=false \
      nohup "$BIN_DIR/agentdock" >> "$NATIVE_LOG" 2>&1 </dev/null & echo $! > "$NATIVE_PID"
  fi
}
start_tunnel() {
  local token="$1"
  if ! pid_alive "$TUNNEL_PID"; then
    CONTROL_PLANE_API_KEY="$RUNTIME_API_KEY" AGENTDOCK_BEARER_HEADER="Bearer $token" nohup "$BIN_DIR/tunnel-client" run --profile-file "$PROFILE" >> "$TUNNEL_LOG" 2>&1 </dev/null & echo $! > "$TUNNEL_PID"
    sleep 2; pid_alive "$TUNNEL_PID" || fail "tunnel-client failed; run logs"
  fi
}
wait_agentdock() { for _ in $(seq 1 50); do curl -fsS "http://127.0.0.1:${PORT}/healthz" >/dev/null 2>&1 && return 0; sleep .5; done; fail "AgentDock health check failed"; }
install_cmd() {
  load_config; mkdir -p "$RUNTIME" "$BIN_DIR"; install_tunnel_client; mode="$(select_mode)"; token="$(get_token)"; write_profile "$token"; printf '%s' "$mode" > "$MODE_FILE"
  if [ "$mode" = docker ]; then write_compose "$token"; docker compose -f "$COMPOSE" pull; else install_native_agentdock; fi
  echo "Installed in $mode mode. Default workspace: $DEFAULT_WORKSPACE"
}
start_cmd() {
  load_config; install_tunnel_client; [ -f "$MODE_FILE" ] || fail "Run install first"; mode="$(cat "$MODE_FILE")"; token="$(get_token)"; write_profile "$token"
  if [ "$mode" = docker ]; then write_compose "$token"; docker compose -f "$COMPOSE" up -d --force-recreate; else start_native "$token"; fi
  wait_agentdock; start_tunnel "$token"
  echo "AgentDock : RUNNING"; echo "Tunnel    : RUNNING"; echo "Mode      : $mode"; echo "Default   : $DEFAULT_WORKSPACE"; echo "MCP       : http://127.0.0.1:${PORT}/mcp"
}
stop_cmd() {
  pid_alive "$TUNNEL_PID" && kill "$(cat "$TUNNEL_PID")" 2>/dev/null || true; rm -f "$TUNNEL_PID"
  if [ -f "$MODE_FILE" ]; then mode="$(cat "$MODE_FILE")"; if [ "$mode" = docker ] && [ -f "$COMPOSE" ] && command -v docker >/dev/null 2>&1; then docker compose -f "$COMPOSE" down; fi; if [ "$mode" = native ] && pid_alive "$NATIVE_PID"; then kill "$(cat "$NATIVE_PID")" 2>/dev/null || true; fi; fi
  rm -f "$NATIVE_PID"; echo "Stopped."
}
status_cmd() {
  load_config; a=STOPPED; t=STOPPED; curl -fsS "http://127.0.0.1:${PORT}/healthz" >/dev/null 2>&1 && a=RUNNING || true; pid_alive "$TUNNEL_PID" && t=RUNNING || true; mode="$(cat "$MODE_FILE" 2>/dev/null || echo 'NOT INSTALLED')"
  echo "AgentDock : $a"; echo "Tunnel    : $t"; echo "Mode      : $mode"; echo "Default   : $DEFAULT_WORKSPACE"; echo "MCP       : http://127.0.0.1:${PORT}/mcp"
}
logs_cmd() { [ -f "$MODE_FILE" ] && [ "$(cat "$MODE_FILE")" = docker ] && [ -f "$COMPOSE" ] && docker compose -f "$COMPOSE" logs --tail 100 agentdock || true; [ -f "$NATIVE_LOG" ] && tail -n 100 "$NATIVE_LOG"; [ -f "$TUNNEL_LOG" ] && tail -n 100 "$TUNNEL_LOG"; }
apply_cmd() { stop_cmd; start_cmd; }
update_cmd() { load_config; install_tunnel_client; [ -f "$MODE_FILE" ] || fail "Run install first"; if [ "$(cat "$MODE_FILE")" = docker ]; then token="$(get_token)"; write_compose "$token"; docker compose -f "$COMPOSE" pull; else rm -f "$BIN_DIR/agentdock"; install_native_agentdock; fi; }

case "${1:-help}" in
  install) install_cmd ;;
  start) start_cmd ;;
  stop) stop_cmd ;;
  restart|apply) apply_cmd ;;
  status) status_cmd ;;
  logs) logs_cmd ;;
  update) update_cmd ;;
  *) echo "Usage: ./agentdock {install|start|stop|restart|apply|status|logs|update}" ;;
esac
