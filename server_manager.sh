#!/bin/bash
# =============================================================================
# THE BLOCKHEADS SERVER MANAGER
# =============================================================================

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

# Server binary
SERVER_BINARY="./blockheads_server171"
DEFAULT_PORT=12153

# Function to check if screen session exists
screen_session_exists() {
    screen -list | grep -q "blockheads_server" 2>/dev/null
}

# Function to check if port is in use
is_port_in_use() {
    lsof -Pi ":$1" -sTCP:LISTEN -t >/dev/null 2>&1
}

# Function to start server
start_server() {
    local world_id="$1"
    local port="${2:-$DEFAULT_PORT}"
    
    # Check if server binary exists
    if [ ! -f "$SERVER_BINARY" ]; then
        print_error "Server binary not found: $SERVER_BINARY"
        return 1
    fi
    
    # Check if world exists
    local saves_dir="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves"
    if [ ! -d "$saves_dir/$world_id" ]; then
        print_error "World '$world_id' does not exist"
        echo "Create a world first: ./blockheads_server171 -n"
        return 1
    fi
    
    # Check if port is available
    if is_port_in_use "$port"; then
        print_error "Port $port is already in use"
        return 1
    fi
    
    # Start server in screen session
    local session_name="blockheads_server_$port"
    if screen -list | grep -q "$session_name"; then
        screen -S "$session_name" -X quit
    fi
    
    screen -dmS "$session_name" ./blockheads_server171 -o "$world_id" -p "$port"
    
    print_success "Server started on port $port"
    echo "World: $world_id"
    echo "Screen session: $session_name"
    echo "To view console: screen -r $session_name"
    echo "To detach: Ctrl+A, D"
}

# Function to stop server
stop_server() {
    local port="$1"
    
    if [ -z "$port" ]; then
        # Stop all servers
        for session in $(screen -list | grep "blockheads_server_" | awk '{print $1}'); do
            screen -S "$session" -X quit
            print_success "Stopped server: $session"
        done
    else
        # Stop specific port
        local session_name="blockheads_server_$port"
        if screen -list | grep -q "$session_name"; then
            screen -S "$session_name" -X quit
            print_success "Stopped server on port $port"
        else
            print_warning "No server found on port $port"
        fi
    fi
}

# Function to show status
show_status() {
    echo "=== BLOCKHEADS SERVER STATUS ==="
    
    local servers=$(screen -list | grep "blockheads_server_" | awk '{print $1}')
    
    if [ -z "$servers" ]; then
        echo "No servers running"
    else
        echo "Running servers:"
        echo "$servers"
    fi
}

# Function to show usage
show_usage() {
    echo "=== BLOCKHEADS SERVER MANAGER ==="
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  start [WORLD_NAME] [PORT]  - Start server"
    echo "  stop [PORT]                 - Stop server (all if no port)"
    echo "  status                      - Show server status"
    echo "  help                        - Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 start MyWorld 12153"
    echo "  $0 start MyWorld           (uses port 12153)"
    echo "  $0 stop 12153"
    echo "  $0 stop                    (stops all servers)"
    echo "  $0 status"
}

# Main execution
case "$1" in
    start)
        if [ -z "$2" ]; then
            print_error "Please specify a world name"
            show_usage
            exit 1
        fi
        start_server "$2" "$3"
        ;;
    stop)
        stop_server "$2"
        ;;
    status)
        show_status
        ;;
    help|--help|-h|"")
        show_usage
        ;;
    *)
        print_error "Unknown command: $1"
        show_usage
        exit 1
        ;;
esac
