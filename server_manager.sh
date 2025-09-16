#!/bin/bash

source blockheads_common.sh

SERVER_BINARY="./blockheads_server171"
DEFAULT_PORT=12153

screen_session_exists() {
    screen -list 2>/dev/null | grep -q "$1"
}

is_port_in_use() {
    lsof -Pi ":$1" -sTCP:LISTEN -t >/dev/null
}

start_server() {
    local world_id="$1"
    local port="${2:-$DEFAULT_PORT}"
    local SCREEN_SERVER="blockheads_server_$port"

    [ ! -f "$SERVER_BINARY" ] && {
        print_error "Server binary not found"
        return 1
    }

    is_port_in_use "$port" && {
        print_error "Port $port is in use"
        return 1
    }

    local log_dir="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves/$world_id"
    mkdir -p "$log_dir"

    print_status "Starting server - World: $world_id, Port: $port"
    
    screen -dmS "$SCREEN_SERVER" bash -c "
        cd '$PWD'
        while true; do
            ./blockheads_server171 -o '$world_id' -p $port
            sleep 5
        done
    "

    print_success "Server started successfully!"
    print_status "To view console: screen -r $SCREEN_SERVER"
}

stop_server() {
    local port="$1"
    
    if [ -z "$port" ]; then
        print_status "Stopping all servers..."
        pkill -f "$SERVER_BINARY" 2>/dev/null
        for session in $(screen -list | grep "blockheads_server_" | awk -F. '{print $1}'); do
            screen -S "$session" -X quit 2>/dev/null
        done
    else
        local screen_server="blockheads_server_$port"
        screen -S "$screen_server" -X quit 2>/dev/null
        pkill -f "$SERVER_BINARY.*$port" 2>/dev/null
    fi
    
    print_success "Server stopped"
}

show_usage() {
    echo "Usage: $0 [command]"
    echo "Commands:"
    echo "  start [WORLD_NAME] [PORT] - Start server"
    echo "  stop [PORT]               - Stop server"
    echo "  help                      - Show this help"
}

case "$1" in
    start)
        [ -z "$2" ] && print_error "World name required" && exit 1
        start_server "$2" "$3"
        ;;
    stop)
        stop_server "$2"
        ;;
    *)
        show_usage
        ;;
esac
