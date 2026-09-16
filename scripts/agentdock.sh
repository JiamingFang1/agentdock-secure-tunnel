#!/usr/bin/env bash
set -Eeuo pipefail
# Report only location and status, never BASH_COMMAND (which may contain a key).
trap 'rc=$?; printf "ERROR: agentdock.sh stopped at line %s (exit %s). See the message above.\n" "$LINENO" "$rc" >&2; exit "$rc"' ERR

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

read_workspaces_raw() {
  awk '
    function trim(s){gsub(/^[ \t]+|[ \t]+$/, "", s); return s}
    function unquote(s){s=trim(s); if((substr(s,1,1)=="\047" && substr(s,length(s),1)=="\047") || (substr(s,1,1)=="\"" && substr(s,length(s),1)=="\"")) s=substr(s,2,length(s)-2); return s}
    function emit(){if(path!="" || name!=""){if(mode=="")mode="rw"; print name "|" path "|" mode}}
    function assign(s, k, v){k=s; sub(/:.*/,"",k); k=trim(k); v=s; sub(/^[^:]*:/,"",v); v=unquote(v); if(k=="name")name=v; else if(k=="path")path=v; else if(k=="mode")mode=v}
    /^workspaces:[[:space:]]*$/ {inws=1; next}
    inws && /^[^[:space:]-]/ {emit(); exit}
    inws && /^[[:space:]]*-[[:space:]]*(name|path|mode)[[:space:]]*:/ {
      emit(); name=""; path=""; mode="rw"; s=$0; sub(/^[[:space:]]*-[[:space:]]*/,"",s); assign(s); next
    }
    inws && /^[[:space:]]+(name|path|mode)[[:space:]]*:/ {s=$0; assign(s); next}
    END{if(inws)emit()}
  ' "$CONFIG"
}

auto_workspace_name() {
  local path="$1" trimmed name
  trimmed="${path%/}"
  [ -n "$trimmed" ] || fail "Cannot derive workspace name from path: $path"
  name="${trimmed##*/}"
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || fail "Cannot use directory name '$name' as a workspace name. Add an explicit name using only letters, numbers, '.', '_' or '-'."
  printf '%s' "$name"
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

  local raw normalized="" seen="|" found=0 name path mode final_name
  raw="$(read_workspaces_raw)"
  [ -n "$raw" ] || fail "At least one workspace is required"

  while IFS='|' read -r name path mode; do
    [ -n "$path" ] || fail "Workspace has an empty path"
    case "$mode" in rw|ro) ;; *) fail "Workspace mode must be rw or ro for path: $path" ;; esac
    final_name="$name"
    [ -n "$final_name" ] || final_name="$(auto_workspace_name "$path")"
    [[ "$final_name" =~ ^[A-Za-z0-9._-]+$ ]] || fail "Invalid workspace name: $final_name"
    case "$seen" in *"|$final_name|"*) fail "Duplicate workspace name: $final_name" ;; esac
    seen="${seen}${final_name}|"
    [ -d "$path" ] || mkdir -p "$path" 2>/dev/null || fail "Workspace does not exist and could not be created: $path"
    [ "$final_name" = "$DEFAULT_WORKSPACE" ] && found=1
    normalized+="${final_name}|${path}|${mode}"$'\n'
  done <<< "$raw"

  WORKSPACES="${normalized%$'\n'}"
  [ "$found" -eq 1 ] || fail "default_workspace '$DEFAULT_WORKSPACE' is not defined. With no explicit name, use the source directory's final name."
}

workspace_path_by_name() {
  local wanted="$1" name path mode
  while IFS='|' read -r name path mode; do
    [ "$name" = "$wanted" ] && { printf '%s' "$path"; return; }
  done <<< "$WORKSPACES"
  fail "Unknown workspace: $wanted"
}

workspace_mode_by_name() {
  local wanted="$1" name path mode
  while IFS='|' read -r name path mode; do
    [ "$name" = "$wanted" ] && { printf '%s' "$mode"; return; }
  done <<< "$WORKSPACES"
  fail "Unknown workspace: $wanted"
}

random_token() {
  if command -v openssl >/dev/null 2>&1; then openssl rand -hex 32; else od -An -N32 -tx1 /dev/urandom | tr -d ' \n'; fi
}

get_token() {
  mkdir -p "$RUNTIME"
  chmod 700 "$RUNTIME" 2>/dev/null || true
  [ -s "$TOKEN_FILE" ] || { random_token > "$TOKEN_FILE"; chmod 600 "$TOKEN_FILE" 2>/dev/null || true; }
  cat "$TOKEN_FILE"
}

install_tunnel_client() {
  [ -x "$BIN_DIR/tunnel-client" ] || fail "tunnel-client is missing. Run ./agentdock so bootstrap-tunnel.sh can install it."
}

install_native_agentdock() {
  command -v python3 >/dev/null 2>&1 || fail "Python 3 is required for verified release downloads. Install Python 3, then retry."
  mkdir -p "$BIN_DIR" "$NATIVE_HOME"
  python3 "$ROOT_DIR/scripts/download-release.py" agentdock "$BIN_DIR/agentdock" "$@"
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

runtime_uid_gid() {
  local uid gid
  uid="$(id -u)"; gid="$(id -g)"
  [ "$uid" != 0 ] || fail "Docker mode must be launched from a non-root host user so workspace ownership can be preserved."
  printf '%s:%s' "$uid" "$gid"
}

check_workspace_access() {
  local name path mode
  while IFS='|' read -r name path mode; do
    [ -r "$path" ] || fail "Current user cannot read workspace '$name': $path"
    [ -x "$path" ] || fail "Current user cannot enter workspace '$name': $path"
    if [ "$mode" = rw ]; then [ -w "$path" ] || fail "Current user cannot write workspace '$name' configured as rw: $path"; fi
  done <<< "$WORKSPACES"
}

write_profile() {
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
  local token="$1" identity uid gid safe_root default_mode default_dir name path mode escaped
  identity="$(runtime_uid_gid)"; uid="${identity%%:*}"; gid="${identity##*:}"
  safe_root="/home/agentdock/AgentDock"
  check_workspace_access
  default_mode="$(workspace_mode_by_name "$DEFAULT_WORKSPACE")"
  [ "$default_mode" = rw ] || fail "default_workspace '$DEFAULT_WORKSPACE' must use mode: rw because AgentDock secures its default directory at startup."
  default_dir="${safe_root}/workspaces/${DEFAULT_WORKSPACE}"

  cat > "$COMPOSE" <<EOF
services:
  agentdock-init:
    image: ghcr.io/uvwt/agentdock:latest
    user: "0:0"
    entrypoint: ["/bin/sh", "-c"]
    command: ["chown -R ${uid}:${gid} /home/agentdock/.agentdock /home/agentdock/AgentDock && chmod 700 /home/agentdock/.agentdock /home/agentdock/AgentDock"]
    restart: "no"
    volumes:
      - agentdock_home:/home/agentdock/.agentdock
      - agentdock_root:/home/agentdock/AgentDock

  agentdock:
    image: ghcr.io/uvwt/agentdock:latest
    container_name: agentdock-secure-tunnel
    restart: unless-stopped
    depends_on:
      agentdock-init:
        condition: service_completed_successfully
    user: "${uid}:${gid}"
    ports:
      - "127.0.0.1:${PORT}:8765"
    environment:
      HOME: "/home/agentdock"
      AGENTDOCK_HOME: "/home/agentdock/.agentdock"
      AGENTDOCK_HOST: "0.0.0.0"
      AGENTDOCK_PORT: "8765"
      AGENTDOCK_OAUTH_ENABLED: "false"
      AGENTDOCK_AUTH_TOKEN: "${token}"
      AGENTDOCK_DEFAULT_DIR: "${default_dir}"
    volumes:
      - agentdock_home:/home/agentdock/.agentdock
      - agentdock_root:/home/agentdock/AgentDock
EOF

  while IFS='|' read -r name path mode; do
    escaped="${path//\'/\'\'}"
    printf "      - '%s:%s/workspaces/%s:%s'\n" "$escaped" "$safe_root" "$name" "$mode" >> "$COMPOSE"
  done <<< "$WORKSPACES"

  cat >> "$COMPOSE" <<EOF
    security_opt:
      - no-new-privileges:true
volumes:
  agentdock_home:
  agentdock_root:
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
    : > "$TUNNEL_LOG"
    CONTROL_PLANE_API_KEY="$RUNTIME_API_KEY" AGENTDOCK_BEARER_HEADER="Bearer $token" nohup "$BIN_DIR/tunnel-client" run --profile-file "$PROFILE" >> "$TUNNEL_LOG" 2>&1 </dev/null & echo $! > "$TUNNEL_PID"
    sleep 2; pid_alive "$TUNNEL_PID" || fail "tunnel-client failed; run logs"
  fi
}

wait_agentdock() {
  for _ in $(seq 1 50); do curl -fsS --connect-timeout 2 --max-time 3 "http://127.0.0.1:${PORT}/healthz" >/dev/null 2>&1 && return 0; sleep .5; done
  fail "AgentDock health check failed"
}

install_cmd() {
  echo "==> Checking configuration" >&2
  load_config; mkdir -p "$RUNTIME" "$BIN_DIR"; install_tunnel_client
  local mode token
  echo "==> Selecting deployment mode" >&2
  mode="$(select_mode)"; token="$(get_token)"; write_profile
  if [ "$mode" = docker ]; then
    echo "==> Pulling AgentDock Docker image" >&2
    write_compose "$token"; docker compose -f "$COMPOSE" pull
  else
    echo "==> Installing native AgentDock (no container directory isolation)" >&2
    install_native_agentdock
  fi
  printf '%s' "$mode" > "$MODE_FILE"
  echo "Installed in $mode mode. Default workspace: $DEFAULT_WORKSPACE"
}

start_cmd() {
  load_config; install_tunnel_client; [ -f "$MODE_FILE" ] || fail "Run install first"
  local mode token
  mode="$(cat "$MODE_FILE")"; token="$(get_token)"; write_profile
  if [ "$mode" = docker ]; then write_compose "$token"; docker compose -f "$COMPOSE" up -d --force-recreate; else start_native "$token"; fi
  wait_agentdock; start_tunnel "$token"
  echo "AgentDock : RUNNING"; echo "Tunnel    : RUNNING"; echo "Mode      : $mode"; echo "Default   : $DEFAULT_WORKSPACE -> /home/agentdock/AgentDock/workspaces/$DEFAULT_WORKSPACE"; echo "MCP       : http://127.0.0.1:${PORT}/mcp"
}

stop_cmd() {
  pid_alive "$TUNNEL_PID" && kill "$(cat "$TUNNEL_PID")" 2>/dev/null || true
  rm -f "$TUNNEL_PID"
  if [ -f "$MODE_FILE" ]; then
    local mode
    mode="$(cat "$MODE_FILE")"
    if [ "$mode" = docker ] && [ -f "$COMPOSE" ] && command -v docker >/dev/null 2>&1; then docker compose -f "$COMPOSE" down; fi
    if [ "$mode" = native ] && pid_alive "$NATIVE_PID"; then kill "$(cat "$NATIVE_PID")" 2>/dev/null || true; fi
  fi
  rm -f "$NATIVE_PID"; echo "Stopped."
}

status_cmd() {
  load_config
  local a=STOPPED t=STOPPED mode
  curl -fsS --connect-timeout 2 --max-time 3 "http://127.0.0.1:${PORT}/healthz" >/dev/null 2>&1 && a=RUNNING || true
  pid_alive "$TUNNEL_PID" && t=RUNNING || true
  mode="$(cat "$MODE_FILE" 2>/dev/null || echo 'NOT INSTALLED')"
  echo "AgentDock : $a"; echo "Tunnel    : $t"; echo "Mode      : $mode"; echo "Default   : $DEFAULT_WORKSPACE"; echo "MCP       : http://127.0.0.1:${PORT}/mcp"
}

logs_cmd() {
  [ -f "$MODE_FILE" ] && [ "$(cat "$MODE_FILE")" = docker ] && [ -f "$COMPOSE" ] && docker compose -f "$COMPOSE" logs --tail 100 agentdock || true
  [ -f "$NATIVE_LOG" ] && tail -n 100 "$NATIVE_LOG"
  [ -f "$TUNNEL_LOG" ] && tail -n 100 "$TUNNEL_LOG"
  return 0
}

apply_cmd() { stop_cmd; start_cmd; }

update_cmd() {
  load_config; install_tunnel_client; [ -f "$MODE_FILE" ] || fail "Run install first"
  if [ "$(cat "$MODE_FILE")" = docker ]; then
    local token
    token="$(get_token)"; write_compose "$token"; docker compose -f "$COMPOSE" pull
  else
    install_native_agentdock --force
  fi
}

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
