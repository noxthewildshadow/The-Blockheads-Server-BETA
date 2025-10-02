#!/bin/bash

# server_manager.sh - Complete server management for The Blockheads
# Compatible with Ubuntu 22.04 Server and GNUstep

set -e

# Enhanced Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
ORANGE='\033[0;33m'
PURPLE='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

# Function to print status messages
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_header() {
    echo -e "${PURPLE}================================================================================${NC}"
    echo -e "${PURPLE}$1${NC}"
    echo -e "${PURPLE}================================================================================${NC}"
}

print_step() {
    echo -e "${CYAN}[STEP]${NC} $1"
}

print_progress() {
    echo -e "${MAGENTA}[PROGRESS]${NC} $1"
}

# Configuration
SERVER_BINARY="./blockheads_server171"
DEFAULT_PORT=12153
RANK_PATCHER="./rank_patcher.sh"

# Function to check if screen session exists
screen_session_exists() {
    screen -list | grep -q "$1" 2>/dev/null
}

# Function to check if port is in use
is_port_in_use() {
    lsof -Pi ":$1" -sTCP:LISTEN -t >/dev/null 2>&1
}

# Function to check if world exists
check_world_exists() {
    local world_id="$1"
    local saves_dir="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves"
    
    if [ ! -d "$saves_dir/$world_id" ]; then
        print_error "World '$world_id' does not exist in: $saves_dir/"
        echo ""
        print_warning "To create a world: ${GREEN}./blockheads_server171 -n${NC}"
        print_warning "After creating the world, press ${YELLOW}CTRL+C${NC} to exit"
        return 1
    fi
    
    return 0
}

# Function to free port
free_port() {
    local port="$1"
    print_warning "Freeing port $port..."
    
    # Kill processes using the port
    local pids
    pids=$(lsof -ti ":$port")
    if [ -n "$pids" ]; then
        kill -9 $pids 2>/dev/null
    fi
    
    # Kill screen sessions for this port
    local screen_server="blockheads_server_$port"
    local screen_patcher="blockheads_patcher_$port"
    
    if screen_session_exists "$screen_server"; then
        screen -S "$screen_server" -X quit 2>/dev/null
    fi
    
    if screen_session_exists "$screen_patcher"; then
        screen -S "$screen_patcher" -X quit 2>/dev/null
    fi
    
    sleep 2
    
    # Verify port is free
    if is_port_in_use "$port"; then
        print_error "Could not free port $port"
        return 1
    fi
    
    print_success "Port $port freed successfully"
    return 0
}

# Function to start server with rank patcher
start_server() {
    local world_id="$1"
    local port="${2:-$DEFAULT_PORT}"
    
    local SCREEN_SERVER="blockheads_server_$port"
    local SCREEN_PATCHER="blockheads_patcher_$port"
    
    if [ ! -f "$SERVER_BINARY" ]; then
        print_error "Server binary not found: $SERVER_BINARY"
        return 1
    fi
    
    check_world_exists "$world_id" || return 1
    
    if is_port_in_use "$port"; then
        print_warning "Port $port is in use."
        if ! free_port "$port"; then
            print_error "Could not free port $port"
            return 1
        fi
    fi
    
    # Clean up previous sessions
    if screen_session_exists "$SCREEN_SERVER"; then
        screen -S "$SCREEN_SERVER" -X quit 2>/dev/null
    fi
    
    if screen_session_exists "$SCREEN_PATCHER"; then
        screen -S "$SCREEN_PATCHER" -X quit 2>/dev/null
    fi
    
    sleep 1
    
    local log_dir="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves/$world_id"
    local log_file="$log_dir/console.log"
    mkdir -p "$log_dir"
    
    print_header "STARTING SERVER - WORLD ID: $world_id, PORT: $port"
    
    # Save world ID for this port
    echo "$world_id" > "world_id_$port.txt"
    
    # Create startup script for server
    cat > "/tmp/start_server_$$.sh" << EOF
#!/bin/bash
cd '$PWD'
echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Starting The Blockheads Server..."
echo "[\$(date '+%Y-%m-%d %H:%M:%S')] World ID: $world_id"
echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Port: $port"

while true; do
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
    
    chmod +x "/tmp/start_server_$$.sh"
    
    # Start server in screen session
    screen -dmS "$SCREEN_SERVER" "/tmp/start_server_$$.sh"
    (sleep 10; rm -f "/tmp/start_server_$$.sh") &
    
    print_step "Waiting for server to start..."
    
    local wait_time=0
    while [ ! -f "$log_file" ] && [ $wait_time -lt 15 ]; do
        sleep 1
        wait_time=$((wait_time + 1))
    done
    
    if [ ! -f "$log_file" ]; then
        print_error "Could not create log file. Server may not have started."
        return 1
    fi
    
    local server_ready=false
    for i in {1..30}; do
        if grep -q "World load complete\|Server started\|Ready for connections\|using seed:\|save delay:" "$log_file"; then
            server_ready=true
            break
        fi
        sleep 1
    done
    
    if [ "$server_ready" = false ]; then
        print_warning "Server did not show complete startup messages"
        if ! screen_session_exists "$SCREEN_SERVER"; then
            print_error "Server screen session not found"
            return 1
        fi
    else
        print_success "Server started successfully!"
    fi
    
    # Start rank patcher
    print_step "Starting rank patcher..."
    
    # Wait a bit for server to be fully ready
    sleep 3
    
    # Verify rank_patcher.sh exists and is executable
    if [ ! -f "$RANK_PATCHER" ]; then
        print_error "Rank patcher not found: $RANK_PATCHER"
        return 1
    fi
    
    if [ ! -x "$RANK_PATCHER" ]; then
        print_warning "Rank patcher not executable, fixing permissions..."
        chmod +x "$RANK_PATCHER"
    fi
    
    # Create startup script for rank patcher
    cat > "/tmp/start_patcher_$$.sh" << EOF
#!/bin/bash
cd '$PWD'
echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Starting Rank Patcher..."
echo "[\$(date '+%Y-%m-%d %H:%M:%S')] World ID: $world_id"
echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Port: $port"

./rank_patcher.sh '$world_id' '$port'
EOF
    
    chmod +x "/tmp/start_patcher_$$.sh"
    
    # Start rank patcher in screen session
    screen -dmS "$SCREEN_PATCHER" "/tmp/start_patcher_$$.sh"
    (sleep 10; rm -f "/tmp/start_patcher_$$.sh") &
    
    # Verify both processes started
    local server_started=0
    local patcher_started=0
    
    if screen_session_exists "$SCREEN_SERVER"; then
        server_started=1
    fi
    
    if screen_session_exists "$SCREEN_PATCHER"; then
        patcher_started=1
    fi
    
    if [ "$server_started" -eq 1 ] && [ "$patcher_started" -eq 1 ]; then
        print_header "SERVER AND RANK PATCHER STARTED SUCCESSFULLY!"
        print_success "World ID: $world_id"
        print_success "Port: $port"
        echo ""
        print_status "To view server console: ${CYAN}screen -r $SCREEN_SERVER${NC}"
        print_status "To view rank patcher: ${CYAN}screen -r $SCREEN_PATCHER${NC}"
        echo ""
        print_warning "To exit console without stopping server: ${YELLOW}CTRL+A, D${NC}"
        print_header "SERVER MANAGEMENT SYSTEM IS NOW ACTIVE"
        
        # Save the configuration for later reference
        echo "world_id=$world_id" > "server_config_$port.conf"
        echo "port=$port" >> "server_config_$port.conf"
        echo "start_time=$(date '+%Y-%m-%d %H:%M:%S')" >> "server_config_$port.conf"
        
    else
        print_warning "Could not verify all screen sessions"
        print_status "Server started: $server_started, Rank Patcher started: $patcher_started"
        
        if [ "$server_started" -eq 0 ]; then
            print_error "Server failed to start. Check logs in: $log_file"
        fi
        if [ "$patcher_started" -eq 0 ]; then
            print_error "Rank patcher failed to start."
        fi
    fi
}

# Function to stop server
stop_server() {
    local port="$1"
    
    if [ -z "$port" ]; then
        print_header "STOPPING ALL SERVERS AND RANK PATCHERS"
        print_step "Stopping all servers and rank patchers..."
        
        # Stop all servers
        for server_session in $(screen -list | grep "blockheads_server_" | awk -F. '{print $1}'); do
            screen -S "$server_session" -X quit 2>/dev/null
            print_success "Stopped server: $server_session"
        done
        
        # Stop all rank patchers
        for patcher_session in $(screen -list | grep "blockheads_patcher_" | awk -F. '{print $1}'); do
            screen -S "$patcher_session" -X quit 2>/dev/null
            print_success "Stopped rank patcher: $patcher_session"
        done
        
        # Kill any remaining processes
        pkill -f "$SERVER_BINARY" 2>/dev/null || true
        pkill -f "rank_patcher.sh" 2>/dev/null || true
        
        # Clean up world ID files and configs
        rm -f world_id_*.txt server_config_*.conf 2>/dev/null || true
        
        print_success "All servers and rank patchers stopped."
    else
        print_header "STOPPING SERVER AND RANK PATCHER ON PORT $port"
        print_step "Stopping server and rank patcher on port $port..."
        
        local screen_server="blockheads_server_$port"
        local screen_patcher="blockheads_patcher_$port"
        
        if screen_session_exists "$screen_server"; then
            screen -S "$screen_server" -X quit 2>/dev/null
            print_success "Server stopped on port $port."
        else
            print_warning "Server was not running on port $port."
        fi
        
        if screen_session_exists "$screen_patcher"; then
            screen -S "$screen_patcher" -X quit 2>/dev/null
            print_success "Rank patcher stopped on port $port."
        else
            print_warning "Rank patcher was not running on port $port."
        fi
        
        # Kill any remaining processes for this port
        pkill -f "$SERVER_BINARY.*$port" 2>/dev/null || true
        pkill -f "rank_patcher.sh.*$port" 2>/dev/null || true
        
        # Clean up world ID file and config for this port
        rm -f "world_id_$port.txt" "server_config_$port.conf" 2>/dev/null || true
        
        print_success "Server and rank patcher cleanup completed for port $port."
    fi
}

# Function to list available worlds
list_worlds() {
    local saves_dir="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves"
    
    if [ ! -d "$saves_dir" ]; then
        print_error "No saves directory found at: $saves_dir"
        print_warning "Create a world first with: ./blockheads_server171 -n"
        return 1
    fi
    
    print_header "AVAILABLE WORLDS"
    
    local found_worlds=0
    for dir in "$saves_dir"/*; do
        if [ -d "$dir" ] && [ -f "$dir/world.info" ]; then
            local world_id
            world_id=$(basename "$dir")
            local world_name
            world_name=$(grep -i "name" "$dir/world.info" 2>/dev/null | cut -d'=' -f2 | tr -d ' ' | tr -d '"')
            local world_size
            world_size=$(grep -i "size" "$dir/world.info" 2>/dev/null | cut -d'=' -f2 | tr -d ' ' | tr -d '"')
            local expert_mode
            expert_mode=$(grep -i "expert" "$dir/world.info" 2>/dev/null | cut -d'=' -f2 | tr -d ' ' | tr -d '"')
            
            if [ -n "$world_name" ]; then
                print_status "World: $world_name"
                print_status "  ID: $world_id"
                print_status "  Size: $world_size"
                print_status "  Expert Mode: ${expert_mode:-No}"
                echo ""
                found_worlds=1
            fi
        fi
    done
    
    if [ "$found_worlds" -eq 0 ]; then
        print_warning "No worlds found. Create one with: ./blockheads_server171 -n"
        print_warning "After creating the world, press CTRL+C to exit"
    fi
}

# Function to list running servers
list_servers() {
    print_header "LIST OF RUNNING SERVERS AND RANK PATCHERS"
    
    local servers
    servers=$(screen -list | grep "blockheads_server_" | awk -F. '{print $1}' | sed 's/blockheads_server_/ - Port: /')
    local patchers
    patchers=$(screen -list | grep "blockheads_patcher_" | awk -F. '{print $1}' | sed 's/blockheads_patcher_/ - Port: /')
    
    if [ -z "$servers" ] && [ -z "$patchers" ]; then
        print_warning "No servers or rank patchers are currently running."
    else
        if [ -n "$servers" ]; then
            print_status "Running servers:"
            while IFS= read -r server; do
                print_status " $server"
            done <<< "$servers"
            echo ""
        fi
        
        if [ -n "$patchers" ]; then
            print_status "Running rank patchers:"
            while IFS= read -r patcher; do
                print_status " $patcher"
            done <<< "$patchers"
        fi
    fi
    
    print_header "END OF LIST"
}

# Function to show detailed status
show_status() {
    local port="$1"
    
    if [ -z "$port" ]; then
        print_header "THE BLOCKHEADS SERVER STATUS - ALL SERVERS"
        
        local servers
        servers=$(screen -list | grep "blockheads_server_" | awk -F. '{print $1}' | sed 's/blockheads_server_//')
        
        if [ -z "$servers" ]; then
            print_error "No servers are currently running."
        else
            while IFS= read -r server_port; do
                print_header "PORT $server_port STATUS"
                
                if screen_session_exists "blockheads_server_$server_port"; then
                    print_success "Server: RUNNING"
                else
                    print_error "Server: STOPPED"
                fi
                
                if screen_session_exists "blockheads_patcher_$server_port"; then
                    print_success "Rank patcher: RUNNING"
                else
                    print_error "Rank patcher: STOPPED"
                fi
                
                if [ -f "world_id_$server_port.txt" ]; then
                    local WORLD_ID
                    WORLD_ID=$(cat "world_id_$server_port.txt" 2>/dev/null)
                    print_status "World ID: ${CYAN}$WORLD_ID${NC}"
                fi
                
                if [ -f "server_config_$server_port.conf" ]; then
                    local START_TIME
                    START_TIME=$(grep "start_time" "server_config_$server_port.conf" 2>/dev/null | cut -d'=' -f2)
                    
                    if [ -n "$START_TIME" ]; then
                        print_status "Start Time: ${YELLOW}$START_TIME${NC}"
                    fi
                fi
                
                if screen_session_exists "blockheads_server_$server_port"; then
                    print_status "To view server console: ${CYAN}screen -r blockheads_server_$server_port${NC}"
                fi
                
                if screen_session_exists "blockheads_patcher_$server_port"; then
                    print_status "To view rank patcher: ${CYAN}screen -r blockheads_patcher_$server_port${NC}"
                fi
                
                echo ""
            done <<< "$servers"
        fi
    else
        print_header "THE BLOCKHEADS SERVER STATUS - PORT $port"
        
        if screen_session_exists "blockheads_server_$port"; then
            print_success "Server: RUNNING"
        else
            print_error "Server: STOPPED"
        fi
        
        if screen_session_exists "blockheads_patcher_$port"; then
            print_success "Rank patcher: RUNNING"
        else
            print_error "Rank patcher: STOPPED"
        fi
        
        if [ -f "world_id_$port.txt" ]; then
            local WORLD_ID
            WORLD_ID=$(cat "world_id_$port.txt" 2>/dev/null)
            print_status "World ID: ${CYAN}$WORLD_ID${NC}"
        else
            print_warning "World ID: Not configured"
        fi
        
        if [ -f "server_config_$port.conf" ]; then
            local START_TIME
            START_TIME=$(grep "start_time" "server_config_$port.conf" 2>/dev/null | cut -d'=' -f2)
            
            if [ -n "$START_TIME" ]; then
                print_status "Start Time: ${YELLOW}$START_TIME${NC}"
            fi
        fi
        
        if screen_session_exists "blockheads_server_$port"; then
            print_status "To view server console: ${CYAN}screen -r blockheads_server_$port${NC}"
        fi
        
        if screen_session_exists "blockheads_patcher_$port"; then
            print_status "To view rank patcher: ${CYAN}screen -r blockheads_patcher_$port${NC}"
        fi
    fi
    
    print_header "END OF STATUS"
}

# Function to show usage
show_usage() {
    print_header "THE BLOCKHEADS SERVER MANAGER WITH RANK PATCHER"
    print_status "Usage: $0 [command]"
    echo ""
    print_status "Available commands:"
    echo -e " ${GREEN}start${NC} <WORLD_ID> [PORT]    - Start server with rank patcher"
    echo -e " ${RED}stop${NC} [PORT]                   - Stop server and rank patcher (specific port or all)"
    echo -e " ${CYAN}status${NC} [PORT]                - Show server and rank patcher status"
    echo -e " ${YELLOW}list${NC}                       - List all running servers and rank patchers"
    echo -e " ${YELLOW}worlds${NC}                     - List all available worlds"
    echo -e " ${YELLOW}help${NC}                       - Show this help"
    echo ""
    print_status "Examples:"
    echo -e " ${GREEN}$0 start 6f4edaf5a311a2bbc96ed0cd5b45736a 12154${NC}"
    echo -e " ${GREEN}$0 start 6f4edaf5a311a2bbc96ed0cd5b45736a${NC}   (uses default port 12153)"
    echo -e " ${RED}$0 stop${NC}                      (stops all servers and rank patchers)"
    echo -e " ${RED}$0 stop 12154${NC}               (stops server and rank patcher on port 12154)"
    echo -e " ${CYAN}$0 status${NC}                   (shows status of all servers)"
    echo -e " ${CYAN}$0 status 12154${NC}            (shows status of server on port 12154)"
    echo -e " ${YELLOW}$0 list${NC}                    (lists all running servers and rank patchers)"
    echo -e " ${YELLOW}$0 worlds${NC}                  (lists all available worlds)"
    echo ""
    print_warning "First create a world: ${GREEN}./blockheads_server171 -n${NC}"
    print_warning "After creating the world, press ${YELLOW}CTRL+C${NC} to exit"
    print_warning "Then start the server with rank patcher using the start command"
    echo ""
    print_status "Default port: ${YELLOW}12153${NC}"
    print_status "Rank patcher automatically manages: players.log, adminlist.txt, modlist.txt, etc."
}

# Main execution
case "$1" in
    start)
        if [ -z "$2" ]; then
            print_error "You must specify a WORLD_ID"
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
    worlds)
        list_worlds
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
