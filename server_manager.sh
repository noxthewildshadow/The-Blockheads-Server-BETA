#!/bin/bash

# server_manager.sh
# This script manages The Blockheads server instances, including starting, stopping, and status checks.
# It launches the rank_patcher.sh script for each running server instance.

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# --- Output Functions ---
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

print_step() {
    echo -e "${CYAN}[STEP]${NC} $1"
}

print_header() {
    echo -e "${MAGENTA}================================================================================${NC}"
    echo -e "${MAGENTA}$1${NC}"
    echo -e "${MAGENTA}================================================================================${NC}"
}

# --- Configuration ---
SERVER_BINARY="./blockheads_server171"
DEFAULT_PORT=15151
SAVES_DIR="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves"
RANK_PATCHER_SCRIPT="./rank_patcher.sh"

# --- Utility Functions ---

# Checks if a screen session exists
screen_session_exists() {
    screen -list | grep -q "$1"
}

# Checks if a given port is in use
is_port_in_use() {
    lsof -iTCP:"$1" -sTCP:LISTEN -t >/dev/null
}

# Checks if the specified world directory exists
check_world_exists() {
    local world_id="$1"
    if [ ! -d "$SAVES_DIR/$world_id" ]; then
        print_error "World '$world_id' does not exist in: $SAVES_DIR/"
        echo
        print_warning "To list worlds: ${GREEN}${SERVER_BINARY} -l${NC}"
        print_warning "To create a world: ${GREEN}${SERVER_BINARY} -n${NC}"
        print_warning "After creating the world, press ${YELLOW}CTRL+C${NC} to exit the creation process."
        return 1
    fi
    return 0
}

# --- Core Functions ---

start_server() {
    local world_id="$1"
    local port="${2:-$DEFAULT_PORT}"
    local screen_session_name="blockheads_server_$port"

    # --- Pre-start Checks ---
    if [ ! -f "$SERVER_BINARY" ]; then
        print_error "Server binary not found: $SERVER_BINARY"
        return 1
    fi
    if [ ! -f "$RANK_PATCHER_SCRIPT" ]; then
        print_error "Rank patcher script not found: $RANK_PATCHER_SCRIPT. Make sure it is in the same directory."
        return 1
    fi
    if ! check_world_exists "$world_id"; then
        return 1
    fi
    if is_port_in_use "$port"; then
        print_error "Port $port is already in use. Stopping the existing server..."
        stop_server "$port"
        sleep 2
    fi
    if screen_session_exists "$screen_session_name"; then
        print_warning "A screen session named '$screen_session_name' already exists. Terminating it..."
        screen -S "$screen_session_name" -X quit
        sleep 1
    fi

    print_header "STARTING SERVER | WORLD: $world_id | PORT: $port"
    
    local log_dir="$SAVES_DIR/$world_id"
    local console_log="$log_dir/console.log"
    mkdir -p "$log_dir"
    # Clear old log to avoid reading past commands
    > "$console_log"

    print_step "Starting server in a detached screen session: $screen_session_name"
    
    # Start the server binary inside a screen session.
    # The output (stdout and stderr) is piped to tee, which writes to the console.log and also to the screen stdout.
    screen -dmS "$screen_session_name" bash -c \
    "'$PWD/$SERVER_BINARY' -o '$world_id' -p '$port' 2>&1 | tee '$console_log'"

    # --- Wait for Server to Initialize ---
    print_step "Waiting for server to initialize..."
    local ready=false
    for i in {1..20}; do
        if grep -q "World load complete" "$console_log"; then
            print_success "Server has loaded the world."
            ready=true
            break
        fi
        sleep 1
    done

    if [ "$ready" = false ]; then
        print_error "Server failed to start. Check the screen session for errors:"
        print_warning "To view console: ${CYAN}screen -r $screen_session_name${NC}"
        return 1
    fi

    # --- Launch Rank Patcher ---
    print_step "Launching the Rank Patcher in the same session..."
    # Use 'stuff' to send commands to the running screen session.
    # This runs the rank_patcher, passing the world_id and screen session name as arguments.
    screen -S "$screen_session_name" -p 0 -X stuff "$PWD/rank_patcher.sh '$world_id' '$screen_session_name' \n"

    print_success "Rank Patcher has been launched."
    echo
    print_header "SERVER AND RANK PATCHER ARE RUNNING"
    print_status "To view server console: ${CYAN}screen -r $screen_session_name${NC}"
    print_warning "To detach from the console without stopping the server, press: ${YELLOW}CTRL+A then D${NC}"
}

stop_server() {
    if [ -z "$1" ]; then
        # Stop all servers
        print_header "STOPPING ALL RUNNING SERVERS"
        local running_sessions=$(screen -list | grep "blockheads_server_" | awk '{print $1}')
        if [ -z "$running_sessions" ]; then
            print_warning "No servers are currently running."
            return
        fi
        for session in $running_sessions; do
            screen -S "$session" -X quit
            print_success "Stopped session: $session"
        done
        # Fallback to kill any lingering processes
        pkill -f "$SERVER_BINARY"
    else
        # Stop a specific server
        local port="$1"
        local screen_session_name="blockheads_server_$port"
        print_header "STOPPING SERVER ON PORT $port"
        if ! screen_session_exists "$screen_session_name"; then
            print_warning "No server found running on port $port."
        else
            screen -S "$screen_session_name" -X quit
            print_success "Server on port $port has been stopped."
        fi
         # Fallback to kill any lingering processes for that specific port
        local pid=$(lsof -iTCP:"$port" -sTCP:LISTEN -t)
        if [ -n "$pid" ]; then
            kill -9 "$pid"
        fi
    fi
}

show_status() {
    print_header "SERVER STATUS"
    local running_sessions=$(screen -list | grep "blockheads_server_")
    if [ -z "$running_sessions" ]; then
        print_warning "No Blockheads servers are currently running."
    else
        echo -e "${GREEN}Running Server Instances:${NC}"
        echo "$running_sessions" | while read -r line; do
            local session_name=$(echo "$line" | awk '{print $1}')
            local port=$(echo "$session_name" | awk -F_ '{print $3}')
            echo -e "  - ${CYAN}Session:${NC} $session_name | ${CYAN}Port:${NC} $port | ${GREEN}Status: RUNNING${NC}"
        done
    fi
}

show_usage() {
    print_header "THE BLOCKHEADS SERVER MANAGER"
    echo "This script helps you manage your Blockheads server."
    echo
    echo -e "${YELLOW}USAGE:${NC}"
    echo -e "  $0 ${GREEN}start${NC} <world_id> [port]"
    echo -e "  $0 ${RED}stop${NC} [port]"
    echo -e "  $0 ${CYAN}status${NC}"
    echo
    echo -e "${YELLOW}COMMANDS:${NC}"
    echo -e "  ${GREEN}start${NC}   - Starts a server for a given world. Uses port $DEFAULT_PORT if not specified."
    echo -e "  ${RED}stop${NC}    - Stops the server on a specific port. If no port is given, stops all servers."
    echo -e "  ${CYAN}status${NC}  - Shows all currently running server instances."
    echo
    echo -e "${YELLOW}EXAMPLES:${NC}"
    echo -e "  ./server_manager.sh start MyWorld"
    echo -e "  ./server_manager.sh start AnotherWorld 15152"
    echo -e "  ./server_manager.sh stop 15152"
    echo -e "  ./server_manager.sh stop"
}


# --- Main Logic ---
case "$1" in
    start)
        if [ -z "$2" ]; then
            print_error "You must specify a world_id to start the server."
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
    *)
        show_usage
        ;;
esac
