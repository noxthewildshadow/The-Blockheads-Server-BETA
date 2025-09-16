#!/bin/bash
set -e

SERVER_BINARY="./blockheads_server171"
DEFAULT_PORT=12153

step() { echo "[STEP] $1"; }
done_step() { echo "[DONE] $1"; }
err() { echo "[ERROR] $1" >&2; exit 1; }

is_port_in_use() {
  lsof -Pi ":$1" -sTCP:LISTEN -t >/dev/null 2>&1
}

start_server() {
  local world_name="$1"
  local port="${2:-$DEFAULT_PORT}"
  local session="blockheads_server_$port"

  step "Preparing to start server for world '$world_name' on port $port"

  [ -z "$world_name" ] && err "WORLD_NAME is required"

  [ ! -f "$SERVER_BINARY" ] && err "Server binary not found: $SERVER_BINARY"

  if is_port_in_use "$port"; then
    err "Port $port is already in use"
  fi

  save_dir="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves/$world_name"
  mkdir -p "$save_dir" >/dev/null 2>&1 || err "Failed to create save directory"

  # start detached screen session with auto-restart loop
  screen -dmS "$session" bash -c "
    cd '$PWD'
    while true; do
      exec $SERVER_BINARY -o '$world_name' -p $port
      sleep 5
    done
  " >/dev/null 2>&1 || err "Failed to start screen session"

  # check session started
  if screen -ls | grep -q "$session"; then
    done_step "Server started in background (screen: $session)"
    echo "[INFO] Attach: screen -r $session"
  else
    err "Screen session not found after start"
  fi
}

stop_server() {
  local port="$1"

  if [ -z "$port" ]; then
    step "Stopping all blockheads servers started by this manager"
    pkill -f "$SERVER_BINARY" >/dev/null 2>&1 || true
    for s in $(screen -ls | awk '/blockheads_server_/{print $1}' 2>/dev/null); do
      screen -S "$s" -X quit >/dev/null 2>&1 || true
    done
    done_step "All servers stop requested"
  else
    local session="blockheads_server_$port"
    step "Stopping server on port $port (screen: $session)"
    screen -S "$session" -X quit >/dev/null 2>&1 || true
    pkill -f "$SERVER_BINARY.*-p $port" >/dev/null 2>&1 || true
    done_step "Stop requested for port $port"
  fi
}

show_usage() {
  cat <<EOF
Usage: $0 command [ARGS]

Commands:
  start WORLD_NAME [PORT]  - Start server (world name required)
  stop [PORT]              - Stop server(s). If PORT omitted, stops all.
  help                     - Show this help
EOF
}

case "$1" in
  start) start_server "$2" "$3" ;;
  stop)  stop_server "$2" ;;
  help|--help|-h|"") show_usage ;;
  *) show_usage ;;
esac
