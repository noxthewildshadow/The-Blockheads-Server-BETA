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
MAGENTA='\033[0;35m'
NC='\033[0m'

print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_status() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_step() { echo -e "${CYAN}[STEP]${NC} $1"; }
print_header() {
    echo -e "${MAGENTA}================================================================================${NC}"
    echo -e "${MAGENTA}$1${NC}"
    echo -e "${MAGENTA}================================================================================${NC}"
}

# Server binary and default port
SERVER_BINARY="./blockheads_server171"
DEFAULT_PORT=12153

# Function to check if screen session exists
screen_session_exists() {
    screen -list | grep -q "$1"
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

# Function to free port
free_port() {
    local port="$1"
    print_warning "Freeing port $port..."
    
    local pids=$(lsof -ti ":$port")
    [ -n "$pids" ] && kill -9 $pids 2>/dev/null
    
    local screen_server="blockheads_server_$port"
    local screen_patcher="blockheads_patcher_$port"
    
    screen_session_exists "$screen_server" && screen -S "$screen_server" -X quit 2>/dev/null
    screen_session_exists "$screen_patcher" && screen -S "$screen_patcher" -X quit 2>/dev/null
    
    sleep 2
    ! is_port_in_use "$port"
}

# Function to start server
start_server() {
    local world_id="$1"
    local port="${2:-$DEFAULT_PORT}"
    
    local SCREEN_SERVER="blockheads_server_$port"
    local SCREEN_PATCHER="blockheads_patcher_$port"
    
    [ ! -f "$SERVER_BINARY" ] && {
        print_error "Server binary not found: $SERVER_BINARY"
        return 1
    }
    
    check_world_exists "$world_id" || return 1
    
    is_port_in_use "$port" && {
        print_warning "Port $port is in use."
        if ! free_port "$port"; then
            print_error "Could not free port $port"
            return 1
        fi
    }
    
    screen_session_exists "$SCREEN_SERVER" && screen -S "$SCREEN_SERVER" -X quit 2>/dev/null
    screen_session_exists "$SCREEN_PATCHER" && screen -S "$SCREEN_PATCHER" -X quit 2>/dev/null
    
    sleep 1
    
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
    
    # Start server in screen session
    print_step "Starting server in screen session: $SCREEN_SERVER"
    if command -v screen >/dev/null 2>&1; then
        if screen -dmS "$SCREEN_SERVER" /tmp/start_server_$$.sh; then
            print_success "Server screen session created successfully"
            # Clean up temporary script after delay
            (sleep 10; rm -f /tmp/start_server_$$.sh) &
        else
            print_error "Failed to create screen session for server"
            rm -f /tmp/start_server_$$.sh
            return 1
        fi
    else
        print_error "Screen command not found. Please install screen."
        rm -f /tmp/start_server_$$.sh
        return 1
    fi
    
    print_step "Waiting for server to start..."
    
    local wait_time=0
    while [ ! -f "$log_file" ] && [ $wait_time -lt 15 ]; do
        sleep 1
        ((wait_time++))
    done
    
    [ ! -f "$log_file" ] && {
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
    
    [ "$server_ready" = false ] && {
        print_warning "Server did not show complete startup messages"
        if ! screen_session_exists "$SCREEN_SERVER"; then
            print_error "Server screen session not found"
            return 1
        fi
    } || print_success "Server started successfully!"
    
    print_step "Starting rank patcher..."
    if screen -dmS "$SCREEN_PATCHER" bash -c "cd '$PWD' && echo 'Starting rank patcher for port $port...' && ./rank_patcher.sh '$port'"; then
        print_success "Rank patcher screen session created: $SCREEN_PATCHER"
    else
        print_warning "Failed to create rank patcher screen session"
    fi
    
    local server_started=0
    local patcher_started=0
    
    screen_session_exists "$SCREEN_SERVER" && server_started=1
    screen_session_exists "$SCREEN_PATCHER" && patcher_started=1
    
    if [ "$server_started" -eq 1 ] && [ "$patcher_started" -eq 1 ]; then
        print_header "SERVER AND RANK PATCHER STARTED SUCCESSFULLY!"
        print_success "World: $world_id"
        print_success "Port: $port"
        echo ""
        print_status "To view server console: ${CYAN}screen -r $SCREEN_SERVER${NC}"
        print_status "To view rank patcher: ${CYAN}screen -r $SCREEN_PATCHER${NC}"
        echo ""
        print_warning "To exit console without stopping server: ${YELLOW}CTRL+A, D${NC}"
    else
        print_warning "Could not verify all screen sessions"
    fi
}

# Function to stop server
stop_server() {
    local port="$1"
    
    if [ -z "$port" ]; then
        print_header "STOPPING ALL SERVERS"
        print_step "Stopping all servers and rank patchers..."
        
        for server_session in $(screen -list | grep "blockheads_server_" | awk -F. '{print $1}'); do
            screen -S "$server_session" -X quit 2>/dev/null
            print_success "Stopped server: $server_session"
        done
        
        for patcher_session in $(screen -list | grep "blockheads_patcher_" | awk -F. '{print $1}'); do
            screen -S "$patcher_session" -X quit 2>/dev/null
            print_success "Stopped rank patcher: $patcher_session"
        done
        
        pkill -f "$SERVER_BINARY" 2>/dev/null || true
        
        # Clean up world ID files
        rm -f world_id_*.txt 2>/dev/null || true
        
        print_success "All servers and rank patchers stopped."
    else
        print_header "STOPPING SERVER ON PORT $port"
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
        
        pkill -f "$SERVER_BINARY.*$port" 2>/dev/null || true
        
        # Clean up world ID file for this port
        rm -f "world_id_$port.txt" 2>/dev/null || true
        
        print_success "Server cleanup completed for port $port."
    fi
}

# Function to list servers
list_servers() {
    print_header "LIST OF RUNNING SERVERS"
    
    local servers=$(screen -list | grep "blockheads_server_" | awk -F. '{print $1}' | sed 's/blockheads_server_/ - Port: /')
    
    if [ -z "$servers" ]; then
        print_warning "No servers are currently running."
    else
        print_status "Running servers:"
        while IFS= read -r server; do
            print_status " $server"
        done <<< "$servers"
    fi
    
    print_header "END OF LIST"
}

# Function to show status
show_status() {
    local port="$1"
    
    if [ -z "$port" ]; then
        print_header "THE BLOCKHEADS SERVER STATUS - ALL SERVERS"
        
        local servers=$(screen -list | grep "blockheads_server_" | awk -F. '{print $1}' | sed 's/blockheads_server_//')
        
        if [ -z "$servers" ]; then
            print_error "No servers are currently running."
        else
            while IFS= read -r server_port; do
                if screen_session_exists "blockheads_server_$server_port"; then
                    print_success "Server on port $server_port: RUNNING"
                else
                    print_error "Server on port $server_port: STOPPED"
                fi
                
                if screen_session_exists "blockheads_patcher_$server_port"; then
                    print_success "Rank patcher on port $server_port: RUNNING"
                else
                    print_error "Rank patcher on port $server_port: STOPPED"
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
        
        if screen_session_exists "blockheads_patcher_$port"; then
            print_success "Rank patcher: RUNNING"
        else
            print_error "Rank patcher: STOPPED"
        fi
        
        if [ -f "world_id_$port.txt" ]; then
            local WORLD_ID=$(cat "world_id_$port.txt" 2>/dev/null)
            print_status "Current world: ${CYAN}$WORLD_ID${NC}"
            
            if screen_session_exists "blockheads_server_$port"; then
                print_status "To view console: ${CYAN}screen -r blockheads_server_$port${NC}"
                print_status "To view rank patcher: ${CYAN}screen -r blockheads_patcher_$port${NC}"
            fi
        else
            print_warning "World: Not configured for port $port"
        fi
    fi
    
    print_header "END OF STATUS"
}

# Function to show usage
show_usage() {
    print_header "THE BLOCKHEADS SERVER MANAGER"
    print_status "Usage: $0 [command]"
    echo ""
    print_status "Available commands:"
    echo -e " ${GREEN}start${NC} [WORLD_NAME] [PORT] - Start server with rank patcher"
    echo -e " ${RED}stop${NC} [PORT] - Stop server and rank patcher"
    echo -e " ${CYAN}status${NC} [PORT] - Show server status"
    echo -e " ${YELLOW}list${NC} - List all running servers"
    echo -e " ${YELLOW}help${NC} - Show this help"
    echo ""
    print_status "Examples:"
    echo -e " ${GREEN}$0 start MyWorld 12153${NC}"
    echo -e " ${GREEN}$0 start MyWorld${NC} (uses default port 12153)"
    echo -e " ${RED}$0 stop${NC} (stops all servers)"
    echo -e " ${RED}$0 stop 12153${NC} (stops server on port 12153)"
    echo -e " ${CYAN}$0 status${NC} (shows status of all servers)"
    echo -e " ${CYAN}$0 status 12153${NC} (shows status of server on port 12153)"
    echo -e " ${YELLOW}$0 list${NC} (lists all running servers)"
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
