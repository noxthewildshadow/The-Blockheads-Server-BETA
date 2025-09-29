#!/bin/bash

SERVER_BINARY="./blockheads_server171"
DEFAULT_PORT=12153
BASE_DIR="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves"

screen_session_exists() {
    screen -list | grep -q "$1" 2>/dev/null
}

is_port_in_use() {
    lsof -Pi ":$1" -sTCP:LISTEN -t >/dev/null 2>/dev/null
}

check_world_exists() {
    local world_id="$1"
    if [ ! -d "$BASE_DIR/$world_id" ]; then
        echo "World '$world_id' does not exist in: $BASE_DIR/"
        echo ""
        echo "To create a world: ./blockheads_server171 -n"
        echo "After creating the world, press CTRL+C to exit"
        return 1
    fi
    return 0
}

free_port() {
    local port="$1"
    echo "Freeing port $port..."
    local pids=$(lsof -ti ":$port" 2>/dev/null)
    if [ -n "$pids" ]; then
        kill -9 $pids 2>/dev/null
    fi
    local screen_server="blockheads_server_$port"
    local screen_patcher="rank_patcher_$port"
    if screen_session_exists "$screen_server"; then
        screen -S "$screen_server" -X quit 2>/dev/null
    fi
    if screen_session_exists "$screen_patcher"; then
        screen -S "$screen_patcher" -X quit 2>/dev/null
    fi
    sleep 2
    if is_port_in_use "$port"; then
        return 1
    else
        return 0
    fi
}

start_rank_patcher() {
    local world_id="$1" port="$2"
    local console_log="$BASE_DIR/$world_id/console.log"
    local screen_patcher="rank_patcher_$port"
    local wait_time=0
    while [ ! -f "$console_log" ] && [ $wait_time -lt 30 ]; do
        sleep 1
        ((wait_time++))
    done
    if [ ! -f "$console_log" ]; then
        echo "Console log never created: $console_log"
        return 1
    fi
    if screen_session_exists "$screen_patcher"; then
        screen -S "$screen_patcher" -X quit 2>/dev/null
    fi
    sleep 1
    screen -dmS "$screen_patcher" bash -c "
        cd '$PWD'
        echo 'Starting rank_patcher for world $world_id on port $port'
        ./rank_patcher.sh '$console_log' '$world_id' '$port'
    "
    sleep 2
    if screen_session_exists "$screen_patcher"; then
        echo "Rank patcher started in screen session: $screen_patcher"
        return 0
    else
        echo "Failed to start rank patcher"
        return 1
    fi
}

start_server() {
    local world_id="$1"
    local port="${2:-$DEFAULT_PORT}"
    local SCREEN_SERVER="blockheads_server_$port"
    if [ ! -f "$SERVER_BINARY" ]; then
        echo "Server binary not found: $SERVER_BINARY"
        return 1
    fi
    if ! check_world_exists "$world_id"; then
        return 1
    fi
    if is_port_in_use "$port"; then
        echo "Port $port is in use."
        if ! free_port "$port"; then
            echo "Could not free port $port"
            return 1
        fi
    fi
    if screen_session_exists "$SCREEN_SERVER"; then
        screen -S "$SCREEN_SERVER" -X quit 2>/dev/null
    fi
    sleep 1
    local log_dir="$BASE_DIR/$world_id"
    local log_file="$log_dir/console.log"
    mkdir -p "$log_dir"
    echo "STARTING SERVER - WORLD: $world_id, PORT: $port"
    echo "$world_id" > "world_id_$port.txt"
    cat > /tmp/start_server_$$.sh << EOF
#!/bin/bash
cd '$PWD'
while true; do
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Starting server..."
    if ./blockheads_server171 -o '$world_id' -p $port 2>&1 | tee -a '$log_file'; then
        echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Server closed normally"
    else
        exit_code=\$?
        echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Server failed with code: \$exit_code"
        if [ \$exit_code -eq 1 ] && tail -n 5 '$log_file' | grep -q "port.*already in use"; then
            echo "[\$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Port already in use. Will not retry."
            break
        fi
    fi
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Restarting in 5 seconds..."
    sleep 5
done
EOF
    chmod +x /tmp/start_server_$$.sh
    screen -dmS "$SCREEN_SERVER" /tmp/start_server_$$.sh
    (sleep 10; rm -f /tmp/start_server_$$.sh) &
    echo "Waiting for server to start..."
    local wait_time=0
    while [ ! -f "$log_file" ] && [ $wait_time -lt 15 ]; do
        sleep 1
        ((wait_time++))
    done
    if [ ! -f "$log_file" ]; then
        echo "Could not create log file. Server may not have started."
        return 1
    fi
    local server_ready=false
    for i in {1..30}; do
        if grep -q "World load complete\|Server started\|Ready for connections\|using seed:\|save delay:" "$log_file" 2>/dev/null; then
            server_ready=true
            break
        fi
        sleep 1
    done
    if [ "$server_ready" = false ]; then
        echo "Server did not show complete startup messages"
        if ! screen_session_exists "$SCREEN_SERVER"; then
            echo "Server screen session not found"
            return 1
        fi
    else
        echo "Server started successfully!"
    fi
    echo "Starting rank patcher..."
    if start_rank_patcher "$world_id" "$port"; then
        echo "Rank patcher started successfully"
    else
        echo "Rank patcher failed to start (will retry)"
        sleep 10
        if start_rank_patcher "$world_id" "$port"; then
            echo "Rank patcher started on retry"
        else
            echo "Rank patcher still failed"
        fi
    fi
    if screen_session_exists "$SCREEN_SERVER"; then
        echo "SERVER STARTED SUCCESSFULLY!"
        echo "World: $world_id"
        echo "Port: $port"
        echo ""
        echo "To view server console: screen -r $SCREEN_SERVER"
        echo "To view rank patcher: screen -r rank_patcher_$port"
        echo ""
        echo "To exit console without stopping server: CTRL+A, D"
    else
        echo "Could not verify server screen session"
    fi
}

stop_server() {
    local port="$1"
    if [ -z "$port" ]; then
        echo "STOPPING ALL SERVERS"
        echo "Stopping all servers and rank patchers..."
        for server_session in $(screen -list | grep "blockheads_server_" | awk -F. '{print $1}' 2>/dev/null); do
            screen -S "$server_session" -X quit 2>/dev/null
            echo "Stopped server: $server_session"
        done
        for patcher_session in $(screen -list | grep "rank_patcher_" | awk -F. '{print $1}' 2>/dev/null); do
            screen -S "$patcher_session" -X quit 2>/dev/null
            echo "Stopped rank patcher: $patcher_session"
        done
        rm -f world_id_*.txt 2>/dev/null || true
        echo "All servers and rank patchers stopped."
    else
        echo "STOPPING SERVER ON PORT $port"
        echo "Stopping server and rank patcher on port $port..."
        local screen_server="blockheads_server_$port"
        local screen_patcher="rank_patcher_$port"
        if screen_session_exists "$screen_server"; then
            screen -S "$screen_server" -X quit 2>/dev/null
            echo "Server stopped on port $port."
        else
            echo "Server was not running on port $port."
        fi
        if screen_session_exists "$screen_patcher"; then
            screen -S "$screen_patcher" -X quit 2>/dev/null
            echo "Rank patcher stopped on port $port."
        else
            echo "Rank patcher was not running on port $port."
        fi
        rm -f "world_id_$port.txt" 2>/dev/null || true
        echo "Server cleanup completed for port $port."
    fi
}

list_servers() {
    echo "LIST OF RUNNING SERVERS"
    local servers=$(screen -list | grep "blockheads_server_" | awk -F. '{print $1}' | sed 's/blockheads_server_/ - Port: /' 2>/dev/null)
    if [ -z "$servers" ]; then
        echo "No servers are currently running."
    else
        echo "Running servers:"
        while IFS= read -r server; do
            echo " $server"
        done <<< "$servers"
    fi
    echo "END OF LIST"
}

show_status() {
    local port="$1"
    if [ -z "$port" ]; then
        echo "THE BLOCKHEADS SERVER STATUS - ALL SERVERS"
        local servers=$(screen -list | grep "blockheads_server_" | awk -F. '{print $1}' | sed 's/blockheads_server_//' 2>/dev/null)
        if [ -z "$servers" ]; then
            echo "No servers are currently running."
        else
            while IFS= read -r server_port; do
                if screen_session_exists "blockheads_server_$server_port"; then
                    echo "Server on port $server_port: RUNNING"
                else
                    echo "Server on port $server_port: STOPPED"
                fi
                if screen_session_exists "rank_patcher_$server_port"; then
                    echo "Rank patcher on port $server_port: RUNNING"
                else
                    echo "Rank patcher on port $server_port: STOPPED"
                fi
                if [ -f "world_id_$server_port.txt" ]; then
                    local WORLD_ID=$(cat "world_id_$server_port.txt" 2>/dev/null)
                    echo "World for port $server_port: $WORLD_ID"
                fi
                echo ""
            done <<< "$servers"
        fi
    else
        echo "THE BLOCKHEADS SERVER STATUS - PORT $port"
        if screen_session_exists "blockheads_server_$port"; then
            echo "Server: RUNNING"
        else
            echo "Server: STOPPED"
        fi
        if screen_session_exists "rank_patcher_$port"; then
            echo "Rank patcher: RUNNING"
        else
            echo "Rank patcher: STOPPED"
        fi
        if [ -f "world_id_$port.txt" ]; then
            local WORLD_ID=$(cat "world_id_$port.txt" 2>/dev/null)
            echo "Current world: $WORLD_ID"
            if screen_session_exists "blockheads_server_$port"; then
                echo "To view console: screen -r blockheads_server_$port"
                echo "To view rank patcher: screen -r rank_patcher_$port"
            fi
        else
            echo "World: Not configured for port $port"
        fi
    fi
    echo "END OF STATUS"
}

show_usage() {
    echo "THE BLOCKHEADS SERVER MANAGER"
    echo "Usage: $0 [command]"
    echo ""
    echo "Available commands:"
    echo " start [WORLD_NAME] [PORT] - Start server with rank patcher"
    echo " stop [PORT] - Stop server and rank patcher (specific port or all)"
    echo " status [PORT] - Show server status (specific port or all)"
    echo " list - List all running servers"
    echo " help - Show this help"
    echo ""
    echo "Examples:"
    echo " $0 start MyWorld 12153"
    echo " $0 start MyWorld (uses default port 12153)"
    echo " $0 stop (stops all servers and rank patchers)"
    echo " $0 stop 12153 (stops server on port 12153)"
    echo " $0 status (shows status of all servers)"
    echo " $0 status 12153 (shows status of server on port 12153)"
    echo " $0 list (lists all running servers)"
    echo ""
    echo "First create a world: ./blockheads_server171 -n"
    echo "After creating the world, press CTRL+C to exit"
}

case "$1" in
    start)
        if [ -z "$2" ]; then
            echo "You must specify a WORLD_NAME"
            show_usage
            exit 1
        fi
        start_server "$2" "$3"
        ;;
    stop)
        stop_server "$2"
        ;;
    status)
        show_status "$2"
        ;;
    list)
        list_servers
        ;;
    help|--help|-h|*)
        show_usage
        ;;
esac
