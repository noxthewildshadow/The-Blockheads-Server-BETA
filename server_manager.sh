#!/bin/bash
set -e

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

print_status() {
    echo -e "${BLUE}[INFO]${NC} $1";
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1";
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1";
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1";
}

print_header() {
    echo -e "${PURPLE}================================================================================${NC}"
    echo -e "${PURPLE}$1${NC}"
    echo -e "${PURPLE}================================================================================${NC}"
}

print_step() {
    echo -e "${CYAN}[STEP]${NC} $1";
}

print_progress() {
    echo -e "${MAGENTA}[PROGRESS]${NC} $1";
}

# Check if running as root
[ "$EUID" -ne 0 ] && print_error "This script requires root privileges." && exit 1

ORIGINAL_USER=${SUDO_USER:-$USER}
USER_HOME=$(getent passwd "$ORIGINAL_USER" | cut -d: -f6)

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
    local saves_dir="$USER_HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves"
    
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
    
    # Check if rank patcher script exists
    if [ ! -f "$RANK_PATCHER_SCRIPT" ]; then
        print_warning "Rank patcher script not found: $RANK_PATCHER_SCRIPT"
        print_warning "Continuing without rank patcher..."
        return 1
    fi
    
    chmod +x "$RANK_PATCHER_SCRIPT" 2>/dev/null || true
    
    # Check if already running
    if screen_session_exists "$SCREEN_PATCHER"; then
        print_status "Rank patcher already running for port $port"
        return 0
    fi
    
    print_step "Starting rank patcher for world $world_id on port $port..."
    
    # Create rank patcher startup script
    cat > /tmp/start_patcher_$$.sh << EOF
#!/bin/bash
cd '$PWD'
echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Starting rank patcher for world $world_id..."
./rank_patcher.sh
EOF
    
    chmod +x /tmp/start_patcher_$$.sh
    
    # Start rank patcher in screen session
    if screen -dmS "$SCREEN_PATCHER" /tmp/start_patcher_$$.sh; then
        print_success "Rank patcher started successfully"
        (sleep 10; rm -f /tmp/start_patcher_$$.sh) &
    else
        print_error "Failed to start rank patcher"
        rm -f /tmp/start_patcher_$$.sh
        return 1
    fi
    
    return 0
}

# Function to start server
start_server() {
    local world_id="$1"
    local port="${2:-$DEFAULT_PORT}"
    
    local SCREEN_SERVER="blockheads_server_$port"
    
    [ ! -f "$SERVER_BINARY" ] && {
        print_error "Server binary not found: $SERVER_BINARY"
        print_warning "Please run the installer first or ensure the binary exists"
        return 1
    }
    
    chmod +x "$SERVER_BINARY" 2>/dev/null || true
    
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
    sleep 1
    
    local log_dir="$USER_HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves/$world_id"
    local log_file="$log_dir/console.log"
    mkdir -p "$log_dir"
    
    print_header "STARTING SERVER - WORLD: $world_id, PORT: $port"
    
    # Save world ID for this port
    echo "$world_id" > "world_id_$port.txt"
    
    # Create server startup script
    cat > /tmp/start_server_$$.sh << EOF
#!/bin/bash
cd '$PWD'
echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Starting Blockheads server..."
echo "World: $world_id"
echo "Port: $port"
echo "Server Binary: $SERVER_BINARY"
echo ""

# Set proper environment variables
export HOME="$USER_HOME"
export USER="$ORIGINAL_USER"

# Start the server with proper error handling
while true; do
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Starting server process..."
    
    if ./blockheads_server171 -o '$world_id' -p $port 2>&1 | tee -a '$log_file'; then
        echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Server exited normally"
    else
        exit_code=\$?
        echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Server process failed with exit code: \$exit_code"
        
        # Check for specific errors
        if tail -n 10 '$log_file' | grep -q "port.*already in use"; then
            echo "[\$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Port $port is already in use. Cannot start server."
            break
        fi
        
        if tail -n 10 '$log_file' | grep -q "Error.*world"; then
            echo "[\$(date '+%Y-%m-%d %H:%M:%S')] ERROR: World '$world_id' not found or corrupted."
            break
        fi
    fi
    
    # Check if we should restart or exit
    if [ -f "stop_server_$port.flag" ]; then
        echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Stop flag detected. Exiting..."
        rm -f "stop_server_$port.flag"
        break
    fi
    
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Restarting server in 5 seconds..."
    sleep 5
done

echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Server process ended"
EOF
    
    chmod +x /tmp/start_server_$$.sh
    
    # Start server in screen session
    print_step "Starting server in screen session: $SCREEN_SERVER"
    
    if screen -dmS "$SCREEN_SERVER" /tmp/start_server_$$.sh; then
        print_success "Server screen session created successfully"
        (sleep 10; rm -f /tmp/start_server_$$.sh) &
    else
        print_error "Failed to create server screen session"
        rm -f /tmp/start_server_$$.sh
        return 1
    fi
    
    print_step "Waiting for server to initialize..."
    
    local wait_time=0
    local max_wait=30
    local server_ready=false
    
    while [ $wait_time -lt $max_wait ]; do
        # Check if log file is being created and has content
        if [ -f "$log_file" ] && tail -n 5 "$log_file" | grep -q -E "World load complete|Server started|Ready for connections|using seed:|save delay:"; then
            server_ready=true
            break
        fi
        
        # Check if screen session is still alive
        if ! screen_session_exists "$SCREEN_SERVER"; then
            print_error "Server screen session died unexpectedly"
            if [ -f "$log_file" ]; then
                print_step "Last log entries:"
                tail -n 10 "$log_file" | while read line; do
                    print_error "  $line"
                done
            fi
            return 1
        fi
        
        sleep 1
        ((wait_time++))
        print_progress "Waiting... ${wait_time}s"
    done
    
    if [ "$server_ready" = false ]; then
        print_warning "Server startup taking longer than expected"
        if screen_session_exists "$SCREEN_SERVER"; then
            print_status "Server is starting in background. Check logs for details."
        else
            print_error "Server failed to start. Check console logs."
            return 1
        fi
    else
        print_success "Server started successfully!"
    fi
    
    # Start rank patcher
    start_rank_patcher "$world_id" "$port"
    
    # Verify server is running
    local server_started=0
    screen_session_exists "$SCREEN_SERVER" && server_started=1
    
    if [ "$server_started" -eq 1 ]; then
        print_header "SERVER STARTED SUCCESSFULLY!"
        print_success "World: $world_id"
        print_success "Port: $port"
        print_success "Screen Session: $SCREEN_SERVER"
        echo ""
        print_status "To view server console: ${CYAN}screen -r $SCREEN_SERVER${NC}"
        print_status "To view rank patcher: ${CYAN}screen -r rank_patcher_$port${NC}"
        echo ""
        print_warning "To exit console without stopping server: ${YELLOW}CTRL+A, D${NC}"
        print_warning "List all screen sessions: ${YELLOW}screen -ls${NC}"
    else
        print_warning "Server may not be fully started. Check status with: $0 status $port"
    fi
    
    return 0
}

# Function to stop server
stop_server() {
    local port="$1"
    
    if [ -z "$port" ]; then
        print_header "STOPPING ALL SERVERS AND RANK PATCHERS"
        print_step "Stopping all Blockheads services..."
        
        # Stop all servers
        for server_session in $(screen -list | grep "blockheads_server_" | awk -F. '{print $1}'); do
            # Extract port from session name
            local session_port=$(echo "$server_session" | sed 's/blockheads_server_//')
            print_step "Stopping server on port $session_port..."
            
            # Create stop flag
            touch "stop_server_${session_port}.flag"
            
            # Send quit command to screen
            screen -S "$server_session" -X quit 2>/dev/null && \
                print_success "Stopped server: $server_session" || \
                print_warning "Could not stop server: $server_session"
                
            # Stop corresponding rank patcher
            local patcher_session="rank_patcher_$session_port"
            if screen_session_exists "$patcher_session"; then
                screen -S "$patcher_session" -X quit 2>/dev/null && \
                    print_success "Stopped rank patcher: $patcher_session" || \
                    print_warning "Could not stop rank patcher: $patcher_session"
            fi
            
            # Clean up files
            rm -f "stop_server_${session_port}.flag" "world_id_${session_port}.txt" 2>/dev/null || true
        done
        
        # Kill any remaining processes
        pkill -f "$SERVER_BINARY" 2>/dev/null || true
        pkill -f "rank_patcher.sh" 2>/dev/null || true
        
        # Clean up all world ID files
        rm -f world_id_*.txt stop_server_*.flag 2>/dev/null || true
        
        print_success "All servers and rank patchers stopped."
    else
        print_header "STOPPING SERVER ON PORT $port"
        print_step "Stopping server on port $port..."
        
        local screen_server="blockheads_server_$port"
        local screen_patcher="rank_patcher_$port"
        
        # Create stop flag
        touch "stop_server_${port}.flag"
        
        if screen_session_exists "$screen_server"; then
            screen -S "$screen_server" -X quit 2>/dev/null
            print_success "Server stopped on port $port."
        else
            print_warning "Server was not running on port $port."
        fi
        
        if screen_session_exists "$screen_patcher"; then
            screen -S "$screen_patcher" -X quit 2>/dev/null
            print_success "Rank patcher stopped for port $port."
        fi
        
        # Kill any remaining processes
        pkill -f "$SERVER_BINARY.*$port" 2>/dev/null || true
        pkill -f "rank_patcher.sh" 2>/dev/null || true
        
        # Clean up files
        rm -f "stop_server_${port}.flag" "world_id_$port.txt" 2>/dev/null || true
        
        print_success "Server cleanup completed for port $port."
    fi
}

# Function to restart server
restart_server() {
    local port="$1"
    local world_id="$2"
    
    if [ -z "$port" ]; then
        print_error "Port is required for restart"
        show_usage
        return 1
    fi
    
    if [ -z "$world_id" ]; then
        # Get world ID from saved file
        if [ -f "world_id_$port.txt" ]; then
            world_id=$(cat "world_id_$port.txt")
        else
            print_error "World ID not found for port $port. Please specify world ID."
            show_usage
            return 1
        fi
    fi
    
    print_header "RESTARTING SERVER - WORLD: $world_id, PORT: $port"
    
    stop_server "$port"
    sleep 2
    start_server "$world_id" "$port"
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
                print_success " $server"
            done <<< "$servers"
        else
            print_warning "No servers running."
        fi
        
        echo ""
        
        if [ -n "$patchers" ]; then
            print_status "Running rank patchers:"
            while IFS= read -r patcher; do
                print_success " $patcher"
            done <<< "$patchers"
        else
            print_warning "No rank patchers running."
        fi
    fi
    
    print_header "END OF LIST"
}

# Function to show status with detailed information
show_status() {
    local port="$1"
    
    if [ -z "$port" ]; then
        print_header "THE BLOCKHEADS SERVER STATUS - ALL SERVERS"
        
        local servers=$(screen -list | grep "blockheads_server_" | awk -F. '{print $1}' | sed 's/blockheads_server_//')
        
        if [ -z "$servers" ]; then
            print_error "No servers are currently running."
        else
            while IFS= read -r server_port; do
                print_step "=== Port $server_port ==="
                
                if screen_session_exists "blockheads_server_$server_port"; then
                    print_success "Server: RUNNING"
                else
                    print_error "Server: STOPPED"
                fi
                
                if screen_session_exists "rank_patcher_$server_port"; then
                    print_success "Rank Patcher: RUNNING"
                else
                    print_warning "Rank Patcher: STOPPED"
                fi
                
                if [ -f "world_id_$server_port.txt" ]; then
                    local WORLD_ID=$(cat "world_id_$server_port.txt" 2>/dev/null)
                    print_status "World ID: ${CYAN}$WORLD_ID${NC}"
                else
                    print_warning "World ID: Not configured"
                fi
                
                # Check port usage
                if is_port_in_use "$server_port"; then
                    print_success "Port $server_port: IN USE"
                else
                    print_warning "Port $server_port: AVAILABLE"
                fi
                
                echo ""
            done <<< "$servers"
        fi
    else
        print_header "THE BLOCKHEADS SERVER STATUS - PORT $port"
        
        print_step "Basic Information:"
        if screen_session_exists "blockheads_server_$port"; then
            print_success "Server: RUNNING"
        else
            print_error "Server: STOPPED"
        fi
        
        if screen_session_exists "rank_patcher_$port"; then
            print_success "Rank Patcher: RUNNING"
        else
            print_warning "Rank Patcher: STOPPED"
        fi
        
        if [ -f "world_id_$port.txt" ]; then
            local WORLD_ID=$(cat "world_id_$port.txt" 2>/dev/null)
            print_status "World ID: ${CYAN}$WORLD_ID${NC}"
            
            # Check world directory
            local world_dir="$USER_HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves/$WORLD_ID"
            if [ -d "$world_dir" ]; then
                print_success "World Directory: EXISTS"
                
                # Check console log
                local console_log="$world_dir/console.log"
                if [ -f "$console_log" ]; then
                    local log_size=$(du -h "$console_log" | cut -f1)
                    print_status "Console Log: $console_log ($log_size)"
                    
                    # Show last connection if available
                    local last_conn=$(grep "Player Connected" "$console_log" | tail -n 1 | cut -d']' -f2- | sed 's/^ *//')
                    if [ -n "$last_conn" ]; then
                        print_status "Last Connection: $last_conn"
                    fi
                else
                    print_warning "Console Log: Not found"
                fi
                
                # Check players.log
                local players_log="$world_dir/players.log"
                if [ -f "$players_log" ]; then
                    local player_count=$(grep -v "^#" "$players_log" | grep -v "^$" | wc -l)
                    print_status "Registered Players: $player_count"
                fi
            else
                print_error "World Directory: NOT FOUND"
            fi
        else
            print_warning "World: Not configured for port $port"
        fi
        
        echo ""
        print_step "Connection Information:"
        if is_port_in_use "$port"; then
            print_success "Port $port: IN USE"
            local pid=$(lsof -ti ":$port")
            print_status "Process ID: $pid"
        else
            print_warning "Port $port: AVAILABLE"
        fi
        
        echo ""
        print_step "Management Commands:"
        print_status "View server console: ${CYAN}screen -r blockheads_server_$port${NC}"
        print_status "View rank patcher: ${CYAN}screen -r rank_patcher_$port${NC}"
        print_status "Stop server: ${RED}./server_manager.sh stop $port${NC}"
        print_status "Restart server: ${YELLOW}./server_manager.sh restart $port${NC}"
    fi
    
    print_header "END OF STATUS"
}

# Function to show logs
show_logs() {
    local port="$1"
    local lines="${2:-50}"
    
    if [ -z "$port" ]; then
        print_error "Port is required for log viewing"
        show_usage
        return 1
    fi
    
    if [ ! -f "world_id_$port.txt" ]; then
        print_error "World ID not found for port $port"
        return 1
    fi
    
    local world_id=$(cat "world_id_$port.txt")
    local log_file="$USER_HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves/$world_id/console.log"
    
    if [ ! -f "$log_file" ]; then
        print_error "Log file not found: $log_file"
        return 1
    fi
    
    print_header "SERVER LOGS - WORLD: $world_id, PORT: $port (last $lines lines)"
    tail -n "$lines" "$log_file"
}

# Function to create new world
create_world() {
    print_header "CREATING NEW WORLD"
    
    [ ! -f "$SERVER_BINARY" ] && {
        print_error "Server binary not found: $SERVER_BINARY"
        return 1
    }
    
    print_step "Starting world creation process..."
    print_warning "After world creation completes, press ${YELLOW}CTRL+C${NC} to exit"
    echo ""
    print_status "Creating world with command: ${CYAN}./blockheads_server171 -n${NC}"
    echo ""
    
    # Start world creation
    if ./blockheads_server171 -n; then
        print_success "World creation process completed"
    else
        print_error "World creation failed"
        return 1
    fi
    
    echo ""
    print_step "Available worlds:"
    ./blockheads_server171 -l 2>/dev/null || {
        print_warning "Could not list worlds. Checking saves directory..."
        local saves_dir="$USER_HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves"
        if [ -d "$saves_dir" ]; then
            ls -la "$saves_dir" | grep -E "^d" | awk '{print $9}' | grep -v "^$"
        fi
    }
}

# Function to show usage
show_usage() {
    print_header "THE BLOCKHEADS SERVER MANAGER"
    print_status "Usage: $0 [command] [options]"
    echo ""
    print_status "Available commands:"
    echo -e " ${GREEN}start${NC} [WORLD_NAME] [PORT]     - Start server with rank patcher"
    echo -e " ${RED}stop${NC} [PORT]                   - Stop server and rank patcher"
    echo -e " ${YELLOW}restart${NC} [PORT] [WORLD_NAME] - Restart server (WORLD_NAME optional)"
    echo -e " ${CYAN}status${NC} [PORT]                - Show server status"
    echo -e " ${BLUE}logs${NC} [PORT] [LINES]          - Show server logs (default: 50 lines)"
    echo -e " ${MAGENTA}list${NC}                      - List all running servers"
    echo -e " ${ORANGE}create${NC}                     - Create a new world"
    echo -e " ${PURPLE}help${NC}                       - Show this help"
    echo ""
    print_status "Examples:"
    echo -e " ${GREEN}$0 start MyWorld 12153${NC}"
    echo -e " ${GREEN}$0 start MyWorld${NC}          (uses default port 12153)"
    echo -e " ${RED}$0 stop${NC}                    (stops all servers)"
    echo -e " ${RED}$0 stop 12153${NC}              (stops server on port 12153)"
    echo -e " ${YELLOW}$0 restart 12153${NC}          (restarts server, auto-detects world)"
    echo -e " ${YELLOW}$0 restart 12153 MyWorld${NC}  (restarts server with specified world)"
    echo -e " ${CYAN}$0 status${NC}                 (shows status of all servers)"
    echo -e " ${CYAN}$0 status 12153${NC}           (shows detailed status for port 12153)"
    echo -e " ${BLUE}$0 logs 12153 100${NC}         (shows last 100 lines of logs)"
    echo -e " ${MAGENTA}$0 list${NC}                 (lists all running servers)"
    echo -e " ${ORANGE}$0 create${NC}                (creates a new world)"
    echo ""
    print_warning "Note: First create a world using 'create' command or manually"
    print_warning "Manual creation: ./blockheads_server171 -n"
    print_warning "List worlds: ./blockheads_server171 -l"
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
        restart_server "$2" "$3"
        ;;
    status)
        show_status "$2"
        ;;
    logs)
        show_logs "$2" "$3"
        ;;
    list)
        list_servers
        ;;
    create)
        create_world
        ;;
    help|--help|-h|*)
        show_usage
        ;;
esac
