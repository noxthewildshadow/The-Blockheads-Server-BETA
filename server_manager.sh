#!/bin/bash

# Color codes for output
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

print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_status() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_step() { echo -e "${CYAN}[STEP]${NC} $1"; }
print_progress() { echo -e "${MAGENTA}[PROGRESS]${NC} $1"; }
print_header() {
    echo -e "${PURPLE}================================================================================${NC}"
    echo -e "${PURPLE}$1${NC}"
    echo -e "${PURPLE}================================================================================${NC}"
}

# Server binary and default port
SERVER_BINARY="./blockheads_server171"
DEFAULT_PORT=12153
RANK_PATCHER_SCRIPT="./rank_patcher.sh"

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
    
    [ -d "$saves_dir/$world_id" ] || {
        print_error "World '$world_id' does not exist in: $saves_dir/"
        echo ""
        print_warning "To create a world: ${GREEN}./blockheads_server171 -n${NC}"
        print_warning "After creating the world, press ${YELLOW}CTRL+C${NC} to exit"
        return 1
    }
    
    return 0
}

# Function to check if rank_patcher.sh exists
check_rank_patcher() {
    if [ ! -f "$RANK_PATCHER_SCRIPT" ]; then
        print_error "Rank patcher script not found: $RANK_PATCHER_SCRIPT"
        print_warning "Please download it from GitHub or ensure it's in the current directory"
        return 1
    fi
    
    if [ ! -x "$RANK_PATCHER_SCRIPT" ]; then
        chmod +x "$RANK_PATCHER_SCRIPT"
        print_status "Made rank patcher executable"
    fi
    
    return 0
}

# Function to free port
free_port() {
    local port="$1"
    print_warning "Freeing port $port..."
    
    local pids=$(lsof -ti ":$port")
    [ -n "$pids" ] && kill -9 $pids 2>/dev/null
    
    local screen_server="blockheads_server_$port"
    local screen_patcher="rank_patcher_$port"
    
    screen_session_exists "$screen_server" && screen -S "$screen_server" -X quit 2>/dev/null
    screen_session_exists "$screen_patcher" && screen -S "$screen_patcher" -X quit 2>/dev/null
    
    sleep 2
    ! is_port_in_use "$port"
}

# Function to start rank patcher
start_rank_patcher() {
    local world_id="$1"
    local port="$2"
    
    local SCREEN_PATCHER="rank_patcher_$port"
    
    # Check if rank patcher is already running
    if screen_session_exists "$SCREEN_PATCHER"; then
        print_warning "Rank patcher already running for port $port, restarting..."
        screen -S "$SCREEN_PATCHER" -X quit 2>/dev/null
        sleep 2
    fi
    
    # Start rank patcher in screen session
    screen -dmS "$SCREEN_PATCHER" bash -c "
        echo 'Starting Rank Patcher for world: $world_id on port: $port';
        cd '$PWD';
        ./rank_patcher.sh;
        echo 'Rank Patcher stopped';
        sleep 5
    "
    
    # Wait for rank patcher to initialize
    sleep 3
    
    if screen_session_exists "$SCREEN_PATCHER"; then
        print_success "Rank patcher started successfully for world $world_id"
        return 0
    else
        print_error "Failed to start rank patcher"
        return 1
    fi
}

# Function to stop rank patcher
stop_rank_patcher() {
    local port="$1"
    
    if [ -z "$port" ]; then
        print_step "Stopping all rank patchers..."
        for patcher_session in $(screen -list | grep "rank_patcher_" | awk -F. '{print $1}'); do
            screen -S "$patcher_session" -X quit 2>/dev/null
            print_success "Stopped rank patcher: $patcher_session"
        done
    else
        local screen_patcher="rank_patcher_$port"
        if screen_session_exists "$screen_patcher"; then
            screen -S "$screen_patcher" -X quit 2>/dev/null
            print_success "Stopped rank patcher for port $port"
        else
            print_warning "Rank patcher was not running for port $port"
        fi
    fi
}

# Function to initialize world files
initialize_world_files() {
    local world_id="$1"
    local world_dir="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves/$world_id"
    
    # Create world directory if it doesn't exist
    mkdir -p "$world_dir"
    
    # Initialize adminlist.txt with header if it doesn't exist
    if [ ! -f "$world_dir/adminlist.txt" ]; then
        cat > "$world_dir/adminlist.txt" << 'EOF'
# Admin List
# Format: player_name
EOF
        print_status "Created adminlist.txt for world $world_id"
    fi
    
    # Initialize modlist.txt with header if it doesn't exist
    if [ ! -f "$world_dir/modlist.txt" ]; then
        cat > "$world_dir/modlist.txt" << 'EOF'
# Mod List
# Format: player_name
EOF
        print_status "Created modlist.txt for world $world_id"
    fi
    
    # Initialize whitelist.txt with header if it doesn't exist
    if [ ! -f "$world_dir/whitelist.txt" ]; then
        cat > "$world_dir/whitelist.txt" << 'EOF'
# Whitelist
# Format: player_name
EOF
        print_status "Created whitelist.txt for world $world_id"
    fi
    
    # Initialize blacklist.txt with header if it doesn't exist
    if [ ! -f "$world_dir/blacklist.txt" ]; then
        cat > "$world_dir/blacklist.txt" << 'EOF'
# Blacklist
# Format: player_name
EOF
        print_status "Created blacklist.txt for world $world_id"
    fi
    
    # Create empty players.log if it doesn't exist (will be managed by rank_patcher)
    if [ ! -f "$world_dir/players.log" ]; then
        touch "$world_dir/players.log"
        print_status "Created players.log for world $world_id"
    fi
}

# Function to start server
start_server() {
    local world_id="$1"
    local port="${2:-$DEFAULT_PORT}"
    
    local SCREEN_SERVER="blockheads_server_$port"
    
    [ ! -f "$SERVER_BINARY" ] && {
        print_error "Server binary not found: $SERVER_BINARY"
        return 1
    }
    
    # Check rank patcher availability
    if ! check_rank_patcher; then
        print_warning "Starting server without rank patcher..."
    fi
    
    check_world_exists "$world_id" || return 1
    
    is_port_in_use "$port" && {
        print_warning "Port $port is in use."
        if ! free_port "$port"; then
            print_error "Could not free port $port"
            return 1
        fi
    }
    
    # Stop any existing sessions
    screen_session_exists "$SCREEN_SERVER" && screen -S "$SCREEN_SERVER" -X quit 2>/dev/null
    stop_rank_patcher "$port"
    
    sleep 1
    
    # Initialize world files
    initialize_world_files "$world_id"
    
    local log_dir="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves/$world_id"
    local log_file="$log_dir/console.log"
    mkdir -p "$log_dir"
    
    print_header "STARTING SERVER - WORLD: $world_id, PORT: $port"
    
    # Save world ID for this port
    echo "$world_id" > "world_id_$port.txt"
    
    # Create startup script
    cat > /tmp/start_server_$$.sh << EOF
#!/bin/bash
cd '$PWD'
echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Starting Blockheads server..."
echo "[\$(date '+%Y-%m-%d %H:%M:%S')] World: $world_id"
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
    
    chmod +x /tmp/start_server_$$.sh
    
    # Start server in screen session
    screen -dmS "$SCREEN_SERVER" /tmp/start_server_$$.sh
    (sleep 10; rm -f /tmp/start_server_$$.sh) &
    
    print_step "Waiting for server to start..."
    
    local wait_time=0
    while [ ! -f "$log_file" ] && [ $wait_time -lt 15 ]; do
        sleep 1
        ((wait_time++))
    done
    
    [ ! -f "$log_file" ] && {
        print_error "Could not create log file. Server may not have started."
        return 1
    }
    
    local server_ready=false
    for i in {1..30}; do
        if grep -q "World load complete\|Server started\|Ready for connections\|using seed:\|save delay:" "$log_file"; then
            server_ready=true
            break
        fi
        sleep 1
    done
    
    # Start rank patcher after server is confirmed running
    if [ "$server_ready" = true ] && check_rank_patcher; then
        print_step "Starting rank patcher..."
        if start_rank_patcher "$world_id" "$port"; then
            print_success "Rank patcher started successfully"
        else
            print_warning "Rank patcher failed to start, but server is running"
        fi
    fi
    
    [ "$server_ready" = false ] && {
        print_warning "Server did not show complete startup messages"
        if ! screen_session_exists "$SCREEN_SERVER"; then
            print_error "Server screen session not found"
            return 1
        fi
    } || print_success "Server started successfully!"
    
    local server_started=0
    screen_session_exists "$SCREEN_SERVER" && server_started=1
    
    if [ "$server_started" -eq 1 ]; then
        print_header "SERVER STARTED SUCCESSFULLY!"
        print_success "World: $world_id"
        print_success "Port: $port"
        echo ""
        print_status "To view server console: ${CYAN}screen -r $SCREEN_SERVER${NC}"
        print_status "To view rank patcher: ${CYAN}screen -r rank_patcher_$port${NC}"
        echo ""
        print_warning "To exit console without stopping server: ${YELLOW}CTRL+A, D${NC}"
        echo ""
        print_header "RANK PATCHER FEATURES ENABLED"
        echo -e "${GREEN}✓ Player authentication system${NC}"
        echo -e "${GREEN}✓ Password protection${NC}"
        echo -e "${GREEN}✓ IP verification${NC}"
        echo -e "${GREEN}✓ Rank management (ADMIN/MOD/SUPER)${NC}"
        echo -e "${GREEN}✓ Real-time monitoring${NC}"
    else
        print_warning "Could not verify server screen session"
    fi
}

# Function to stop server
stop_server() {
    local port="$1"
    
    if [ -z "$port" ]; then
        print_header "STOPPING ALL SERVERS AND RANK PATCHERS"
        print_step "Stopping all servers and rank patchers..."
        
        # Stop all rank patchers first
        stop_rank_patcher
        
        # Stop all servers
        for server_session in $(screen -list | grep "blockheads_server_" | awk -F. '{print $1}'); do
            screen -S "$server_session" -X quit 2>/dev/null
            print_success "Stopped server: $server_session"
        done
        
        pkill -f "$SERVER_BINARY" 2>/dev/null || true
        
        # Clean up world ID files
        rm -f world_id_*.txt 2>/dev/null || true
        
        print_success "All servers and rank patchers stopped."
    else
        print_header "STOPPING SERVER ON PORT $port"
        print_step "Stopping server and rank patcher on port $port..."
        
        # Stop rank patcher first
        stop_rank_patcher "$port"
        
        local screen_server="blockheads_server_$port"
        
        if screen_session_exists "$screen_server"; then
            screen -S "$screen_server" -X quit 2>/dev/null
            print_success "Server stopped on port $port."
        else
            print_warning "Server was not running on port $port."
        fi
        
        pkill -f "$SERVER_BINARY.*$port" 2>/dev/null || true
        
        # Clean up world ID file for this port
        rm -f "world_id_$port.txt" 2>/dev/null || true
        
        print_success "Server cleanup completed for port $port."
    fi
}

# Function to list servers
list_servers() {
    print_header "LIST OF RUNNING SERVERS AND RANK PATCHERS"
    
    local servers=$(screen -list | grep "blockheads_server_" | awk -F. '{print $1}' | sed 's/blockheads_server_/ - Port: /')
    local patchers=$(screen -list | grep "rank_patcher_" | awk -F. '{print $1}' | sed 's/rank_patcher_/ - Port: /')
    
    if [ -z "$servers" ] && [ -z "$patchers" ]; then
        print_warning "No servers or rank patchers are currently running."
    else
        if [ -n "$servers" ]; then
            print_status "Running servers:"
            while IFS= read -r server; do
                print_status " $server"
            done <<< "$servers"
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

# Function to show status
show_status() {
    local port="$1"
    
    if [ -z "$port" ]; then
        print_header "THE BLOCKHEADS SERVER STATUS - ALL SERVERS"
        
        local servers=$(screen -list | grep "blockheads_server_" | awk -F. '{print $1}' | sed 's/blockheads_server_//')
        local patchers=$(screen -list | grep "rank_patcher_" | awk -F. '{print $1}' | sed 's/rank_patcher_//')
        
        if [ -z "$servers" ] && [ -z "$patchers" ]; then
            print_error "No servers or rank patchers are currently running."
        else
            # Show servers status
            while IFS= read -r server_port; do
                if screen_session_exists "blockheads_server_$server_port"; then
                    print_success "Server on port $server_port: RUNNING"
                else
                    print_error "Server on port $server_port: STOPPED"
                fi
                
                if screen_session_exists "rank_patcher_$server_port"; then
                    print_success "Rank patcher on port $server_port: RUNNING"
                else
                    print_warning "Rank patcher on port $server_port: STOPPED"
                fi
                
                if [ -f "world_id_$server_port.txt" ]; then
                    local WORLD_ID=$(cat "world_id_$server_port.txt" 2>/dev/null)
                    print_status "World for port $server_port: ${CYAN}$WORLD_ID${NC}"
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
        
        if screen_session_exists "rank_patcher_$port"; then
            print_success "Rank patcher: RUNNING"
        else
            print_warning "Rank patcher: STOPPED"
        fi
        
        if [ -f "world_id_$port.txt" ]; then
            local WORLD_ID=$(cat "world_id_$port.txt" 2>/dev/null)
            print_status "Current world: ${CYAN}$WORLD_ID${NC}"
            
            if screen_session_exists "blockheads_server_$port"; then
                print_status "To view server console: ${CYAN}screen -r blockheads_server_$port${NC}"
            fi
            if screen_session_exists "rank_patcher_$port"; then
                print_status "To view rank patcher: ${CYAN}screen -r rank_patcher_$port${NC}"
            fi
        else
            print_warning "World: Not configured for port $port"
        fi
    fi
    
    print_header "END OF STATUS"
}

# Function to restart server
restart_server() {
    local world_id="$1"
    local port="${2:-$DEFAULT_PORT}"
    
    print_header "RESTARTING SERVER - WORLD: $world_id, PORT: $port"
    
    # Stop the server and rank patcher
    stop_server "$port"
    
    # Wait a moment
    sleep 3
    
    # Start the server again
    start_server "$world_id" "$port"
}

# Function to view logs
view_logs() {
    local port="$1"
    local log_type="$2"
    
    if [ -z "$port" ]; then
        print_error "Please specify a port to view logs"
        return 1
    fi
    
    local world_id=""
    if [ -f "world_id_$port.txt" ]; then
        world_id=$(cat "world_id_$port.txt")
    else
        print_error "No world configured for port $port"
        return 1
    fi
    
    local log_dir="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves/$world_id"
    
    case "${log_type:-console}" in
        "console")
            local log_file="$log_dir/console.log"
            ;;
        "players")
            local log_file="$log_dir/players.log"
            ;;
        *)
            print_error "Invalid log type. Use 'console' or 'players'"
            return 1
            ;;
    esac
    
    if [ ! -f "$log_file" ]; then
        print_error "Log file not found: $log_file"
        return 1
    fi
    
    print_header "VIEWING $log_type LOG - WORLD: $world_id, PORT: $port"
    tail -f "$log_file"
}

# Function to show usage
show_usage() {
    print_header "THE BLOCKHEADS SERVER MANAGER WITH RANK PATCHER"
    print_status "Usage: $0 [command] [options]"
    echo ""
    print_status "Available commands:"
    echo -e " ${GREEN}start${NC} [WORLD_NAME] [PORT]    - Start server with rank patcher"
    echo -e " ${RED}stop${NC} [PORT]                   - Stop server and rank patcher"
    echo -e " ${CYAN}restart${NC} [WORLD_NAME] [PORT]  - Restart server and rank patcher"
    echo -e " ${BLUE}status${NC} [PORT]                - Show server status"
    echo -e " ${YELLOW}list${NC}                       - List all running servers"
    echo -e " ${MAGENTA}logs${NC} [PORT] [TYPE]        - View logs (console|players)"
    echo -e " ${YELLOW}help${NC}                       - Show this help"
    echo ""
    print_status "Examples:"
    echo -e " ${GREEN}$0 start MyWorld 12153${NC}"
    echo -e " ${GREEN}$0 start MyWorld${NC} (uses default port 12153)"
    echo -e " ${RED}$0 stop${NC} (stops all servers)"
    echo -e " ${RED}$0 stop 12153${NC} (stops server on port 12153)"
    echo -e " ${CYAN}$0 restart MyWorld 12153${NC}"
    echo -e " ${BLUE}$0 status${NC} (shows status of all servers)"
    echo -e " ${BLUE}$0 status 12153${NC} (shows status of server on port 12153)"
    echo -e " ${MAGENTA}$0 logs 12153 console${NC} (view console logs)"
    echo -e " ${MAGENTA}$0 logs 12153 players${NC} (view players.log)"
    echo -e " ${YELLOW}$0 list${NC} (lists all running servers)"
    echo ""
    print_header "RANK PATCHER FEATURES"
    echo -e "${GREEN}✓ Player authentication system${NC}"
    echo -e "${GREEN}✓ Password protection (7-16 characters)${NC}"
    echo -e "${GREEN}✓ IP verification with 30-second timeout${NC}"
    echo -e "${GREEN}✓ Rank management (ADMIN/MOD/SUPER/NONE)${NC}"
    echo -e "${GREEN}✓ Real-time monitoring of console logs${NC}"
    echo -e "${GREEN}✓ Automatic list synchronization${NC}"
    echo -e "${GREEN}✓ Chat commands: !password, !ip_change, !change_psw${NC}"
    echo ""
    print_warning "First create a world: ./blockheads_server171 -n"
    print_warning "After creating the world, press CTRL+C to exit"
}

# Main execution
case "$1" in
    start)
        [ -z "$2" ] && print_error "You must specify a WORLD_NAME" && show_usage && exit 1
        start_server "$2" "$3"
        ;;
    stop)
        stop_server "$2"
        ;;
    restart)
        [ -z "$2" ] && print_error "You must specify a WORLD_NAME" && show_usage && exit 1
        restart_server "$2" "$3"
        ;;
    status)
        show_status "$2"
        ;;
    list)
        list_servers
        ;;
    logs)
        view_logs "$2" "$3"
        ;;
    help|--help|-h|*)
        show_usage
        ;;
esac
