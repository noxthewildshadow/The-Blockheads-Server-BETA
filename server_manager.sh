#!/bin/bash

# server_manager.sh - The Blockheads Server Management Script
# Fixed version with improved server startup detection

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
ORANGE='\033[0;33m'
NC='\033[0m'

print_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_status() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_header() { echo -e "${MAGENTA}=== $1 ===${NC}"; }

# Configuration
SERVER_BINARY="./blockheads_server171"
DEFAULT_PORT=12155
SERVER_HOME="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads"
RANK_PATCHER="./rank_patcher.sh"

# Function to check if screen session exists
screen_session_exists() {
    screen -list | grep -q "$1"
}

# Function to check if port is in use
is_port_in_use() {
    lsof -Pi ":$1" -sTCP:LISTEN -t >/dev/null 2>&1
}

# Function to free port
free_port() {
    local port="$1"
    print_warning "Freeing port $port..."
    
    # Kill processes using the port
    local pids=$(lsof -ti ":$port")
    if [ -n "$pids" ]; then
        kill -9 $pids 2>/dev/null
        print_status "Killed processes on port $port"
    fi
    
    # Kill screen session for this port
    local screen_name="blockheads_server_$port"
    if screen_session_exists "$screen_name"; then
        screen -S "$screen_name" -X quit 2>/dev/null
        print_status "Closed screen session: $screen_name"
    fi
    
    sleep 3
    if ! is_port_in_use "$port"; then
        print_success "Port $port freed successfully"
        return 0
    else
        print_error "Could not free port $port"
        return 1
    fi
}

# Function to start rank patcher
start_rank_patcher() {
    if [ ! -f "$RANK_PATCHER" ]; then
        print_error "Rank patcher not found: $RANK_PATCHER"
        return 1
    fi
    
    if ! chmod +x "$RANK_PATCHER"; then
        print_error "Failed to make rank patcher executable"
        return 1
    fi
    
    # Check if rank patcher is already running
    if pgrep -f "rank_patcher.sh" > /dev/null; then
        print_status "Rank patcher is already running"
        return 0
    fi
    
    # Start rank patcher in background
    nohup "$RANK_PATCHER" >> rank_patcher.log 2>&1 &
    local patcher_pid=$!
    
    # Wait a bit and check if it's running
    sleep 5
    if ps -p $patcher_pid > /dev/null 2>&1; then
        print_success "Rank patcher started (PID: $patcher_pid)"
        echo "$patcher_pid" > rank_patcher.pid
        return 0
    else
        print_error "Rank patcher failed to start - check rank_patcher.log"
        return 1
    fi
}

# Function to stop rank patcher
stop_rank_patcher() {
    local killed_something=false
    
    # Kill using PID file
    if [ -f "rank_patcher.pid" ]; then
        local patcher_pid=$(cat rank_patcher.pid)
        if kill -0 "$patcher_pid" 2>/dev/null; then
            kill "$patcher_pid" 2>/dev/null
            print_success "Stopped rank patcher (PID: $patcher_pid)"
            killed_something=true
        fi
        rm -f rank_patcher.pid
    fi
    
    # Force kill any remaining processes
    if pkill -f "rank_patcher.sh" 2>/dev/null; then
        print_status "Cleaned up rank patcher processes"
        killed_something=true
    fi
    
    # Cleanup log file
    rm -f rank_patcher.log 2>/dev/null
    
    if [ "$killed_something" = false ]; then
        print_status "No rank patcher processes found"
    fi
}

# Function to check if world exists
check_world_exists() {
    local world_id="$1"
    local world_dir="$SERVER_HOME/saves/$world_id"
    
    if [ ! -d "$world_dir" ]; then
        print_error "World '$world_id' does not exist in: $SERVER_HOME/saves/"
        print_warning "To create a world, run: $SERVER_BINARY -n"
        print_warning "After world creation, press Ctrl+C to exit"
        return 1
    fi
    
    return 0
}

# Function to check server startup status
check_server_startup() {
    local world_id="$1"
    local port="$2"
    local screen_name="$3"
    
    local world_dir="$SERVER_HOME/saves/$world_id"
    local console_log="$world_dir/console.log"
    
    print_status "Checking server startup status..."
    
    # Check 1: Screen session exists
    if ! screen_session_exists "$screen_name"; then
        print_error "Screen session not found: $screen_name"
        return 1
    fi
    print_success "✓ Screen session active"
    
    # Check 2: Port is in use
    if ! is_port_in_use "$port"; then
        print_error "Port $port not in use"
        return 1
    fi
    print_success "✓ Port $port active"
    
    # Check 3: Console log exists and has content
    local log_attempts=0
    while [ ! -f "$console_log" ] && [ $log_attempts -lt 30 ]; do
        sleep 2
        ((log_attempts++))
    done
    
    if [ ! -f "$console_log" ]; then
        print_error "Console log not created: $console_log"
        return 1
    fi
    print_success "✓ Console log created"
    
    # Check 4: Server startup messages in log
    local startup_attempts=0
    while [ $startup_attempts -lt 30 ]; do
        if grep -q "World load complete\|Server started\|Ready for connections\|using seed:\|save delay:" "$console_log"; then
            print_success "✓ Server startup detected in logs"
            return 0
        fi
        sleep 2
        ((startup_attempts++))
    done
    
    print_error "Server startup not detected in logs within 60 seconds"
    return 1
}

# Function to start server
start_server() {
    local world_id="$1"
    local port="${2:-$DEFAULT_PORT}"
    local screen_name="blockheads_server_$port"
    
    # Validation
    if [ ! -f "$SERVER_BINARY" ]; then
        print_error "Server binary not found: $SERVER_BINARY"
        return 1
    fi
    
    if ! chmod +x "$SERVER_BINARY"; then
        print_error "Failed to make server binary executable"
        return 1
    fi
    
    # Check if world exists
    if ! check_world_exists "$world_id"; then
        return 1
    fi
    
    # Check port availability
    if is_port_in_use "$port"; then
        print_warning "Port $port is in use"
        if ! free_port "$port"; then
            print_error "Could not free port $port"
            return 1
        fi
    fi
    
    # Kill existing screen session
    if screen_session_exists "$screen_name"; then
        screen -S "$screen_name" -X quit 2>/dev/null
        sleep 2
    fi
    
    print_header "STARTING THE BLOCKHEADS SERVER"
    print_status "World: $world_id"
    print_status "Port: $port"
    print_status "Screen: $screen_name"
    
    # Create world directory if it doesn't exist
    local world_dir="$SERVER_HOME/saves/$world_id"
    mkdir -p "$world_dir"
    
    # Create startup script
    local startup_script=$(mktemp)
    cat > "$startup_script" << EOF
#!/bin/bash
cd "$PWD"
echo "=================================================================================="
echo "THE BLOCKHEADS SERVER"
echo "Started at: \$(date)"
echo "World: $world_id"
echo "Port: $port"
echo "Screen: $screen_name"
echo "=================================================================================="

# Set proper permissions and environment
export HOME="$HOME"
export USER="$USER"

echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Starting server process..."
echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Working directory: \$(pwd)"
echo "[\$(date '+%Y-%m-%d %H:%M:%S')] World directory: $world_dir"

# Start the server with error handling
while true; do
    if ./blockheads_server171 -o "$world_id" -p "$port"; then
        echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Server stopped normally"
        break
    else
        exit_code=\$?
        echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Server exited with code: \$exit_code"
        echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Restarting in 10 seconds..."
        sleep 10
    fi
done

echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Server process ended"
EOF
    
    chmod +x "$startup_script"
    
    # Start server in screen session
    print_status "Starting server in screen session..."
    if ! screen -dmS "$screen_name" "$startup_script"; then
        print_error "Failed to start screen session"
        rm -f "$startup_script"
        return 1
    fi
    
    # Cleanup temp file
    rm -f "$startup_script"
    
    # Wait for server to start with improved detection
    print_status "Waiting for server to start (this may take up to 60 seconds)..."
    
    if check_server_startup "$world_id" "$port" "$screen_name"; then
        print_success "Server started successfully"
    else
        print_error "Server failed to start properly"
        print_status "Check the server logs with: screen -r $screen_name"
        return 1
    fi
    
    # Start rank patcher
    print_status "Starting rank management system..."
    if start_rank_patcher; then
        print_success "Rank management system activated"
    else
        print_warning "Rank patcher failed to start - server will run without rank management"
    fi
    
    # Save world ID for this port
    echo "$world_id" > "world_id_$port.txt"
    
    print_header "SERVER IS NOW RUNNING"
    print_success "World: $world_id"
    print_success "Port: $port"
    print_success "Screen: $screen_name"
    print_status "To view console: screen -r $screen_name"
    print_status "To detach console: Ctrl+A, D"
    print_status "Rank patcher: Active"
    print_status "Player management: Enabled"
    echo ""
    print_warning "If you encounter issues, check: screen -r $screen_name"
    
    return 0
}

# Function to stop server
stop_server() {
    local port="$1"
    
    if [ -z "$port" ]; then
        print_header "STOPPING ALL BLOCKHEADS SERVERS"
        
        # Stop rank patcher first
        stop_rank_patcher
        
        # Stop all blockheads screen sessions
        local stopped_any=false
        for session in $(screen -list | grep "blockheads_server_" | awk -F. '{print $1}'); do
            screen -S "$session" -X quit 2>/dev/null
            print_success "Stopped: $session"
            stopped_any=true
        done
        
        # Kill any remaining processes
        if pkill -f "$SERVER_BINARY" 2>/dev/null; then
            print_status "Cleaned up server processes"
            stopped_any=true
        fi
        
        # Cleanup world ID files
        rm -f world_id_*.txt 2>/dev/null && print_status "Cleaned up world ID files"
        
        if [ "$stopped_any" = false ]; then
            print_status "No servers were running"
        fi
        
    else
        print_header "STOPPING SERVER ON PORT $port"
        local screen_name="blockheads_server_$port"
        
        if screen_session_exists "$screen_name"; then
            screen -S "$screen_name" -X quit 2>/dev/null
            print_success "Stopped server on port $port"
        else
            print_warning "Server not running on port $port"
        fi
        
        # Kill any processes on this port
        local pids=$(lsof -ti ":$port")
        if [ -n "$pids" ]; then
            kill -9 $pids 2>/dev/null
            print_status "Killed processes on port $port"
        fi
        
        # Stop rank patcher for this port
        stop_rank_patcher
        
        # Cleanup world ID file
        rm -f "world_id_$port.txt" 2>/dev/null && print_status "Removed world ID file"
    fi
    
    print_success "Server stop procedure completed"
}

# Function to show server status
show_status() {
    local port="$1"
    
    if [ -z "$port" ]; then
        print_header "BLOCKHEADS SERVERS STATUS"
        
        local servers=$(screen -list | grep "blockheads_server_" | awk -F. '{print $1}' | sed 's/blockheads_server_//')
        
        if [ -z "$servers" ]; then
            print_warning "No servers are currently running"
        else
            for server_port in $servers; do
                if screen_session_exists "blockheads_server_$server_port"; then
                    print_success "Port $server_port: RUNNING"
                    if [ -f "world_id_$server_port.txt" ]; then
                        local world_id=$(cat "world_id_$server_port.txt" 2>/dev/null)
                        print_status "  World: $world_id"
                    fi
                else
                    print_error "Port $server_port: STOPPED"
                fi
            done
        fi
        
        # Check rank patcher
        if pgrep -f "rank_patcher.sh" > /dev/null; then
            print_success "Rank patcher: RUNNING"
        else
            print_warning "Rank patcher: STOPPED"
        fi
        
    else
        print_header "SERVER STATUS - PORT $port"
        local screen_name="blockheads_server_$port"
        
        if screen_session_exists "$screen_name"; then
            print_success "Status: RUNNING"
            if [ -f "world_id_$port.txt" ]; then
                local world_id=$(cat "world_id_$port.txt" 2>/dev/null)
                print_status "World: $world_id"
            fi
            print_status "Screen: $screen_name"
            print_status "Console: screen -r $screen_name"
            
            # Check if server is responsive
            if is_port_in_use "$port"; then
                print_success "Network: PORT_ACTIVE"
            else
                print_error "Network: PORT_INACTIVE"
            fi
        else
            print_error "Status: STOPPED"
        fi
        
        # Check rank patcher
        if pgrep -f "rank_patcher.sh" > /dev/null; then
            print_success "Rank patcher: RUNNING"
        else
            print_warning "Rank patcher: STOPPED"
        fi
    fi
}

# Function to list running servers
list_servers() {
    print_header "RUNNING BLOCKHEADS SERVERS"
    
    local servers=$(screen -list | grep "blockheads_server_" | awk -F. '{print $1}' | sed 's/blockheads_server_/Port: /')
    
    if [ -z "$servers" ]; then
        print_warning "No servers are currently running"
    else
        while IFS= read -r server; do
            print_status "$server"
        done <<< "$servers"
    fi
}

# Function to show server console
show_console() {
    local port="$1"
    
    if [ -z "$port" ]; then
        print_error "Port required for console access"
        show_usage
        return 1
    fi
    
    local screen_name="blockheads_server_$port"
    
    if screen_session_exists "$screen_name"; then
        print_status "Attaching to server console (detach with Ctrl+A, D)"
        screen -r "$screen_name"
    else
        print_error "Server not running on port $port"
        return 1
    fi
}

# Function to show server logs
show_logs() {
    local port="$1"
    local world_id="$2"
    
    if [ -z "$port" ] || [ -z "$world_id" ]; then
        print_error "Port and world ID required for log access"
        echo "Usage: $0 logs <port> <world_id>"
        return 1
    fi
    
    local log_file="$SERVER_HOME/saves/$world_id/console.log"
    
    if [ ! -f "$log_file" ]; then
        print_error "Log file not found: $log_file"
        return 1
    fi
    
    print_header "SERVER LOGS - $world_id (Port: $port)"
    tail -50 "$log_file"
}

# Function to debug server issues
debug_server() {
    local port="$1"
    
    print_header "SERVER DEBUG INFORMATION"
    
    if [ -n "$port" ]; then
        print_status "Debugging server on port: $port"
        local screen_name="blockheads_server_$port"
        
        # Check screen session
        if screen_session_exists "$screen_name"; then
            print_success "✓ Screen session: EXISTS ($screen_name)"
        else
            print_error "✗ Screen session: NOT_FOUND"
        fi
        
        # Check port
        if is_port_in_use "$port"; then
            print_success "✓ Port $port: IN_USE"
        else
            print_error "✗ Port $port: NOT_IN_USE"
        fi
        
        # Check world ID file
        if [ -f "world_id_$port.txt" ]; then
            local world_id=$(cat "world_id_$port.txt")
            print_success "✓ World ID: $world_id"
            
            # Check console log
            local log_file="$SERVER_HOME/saves/$world_id/console.log"
            if [ -f "$log_file" ]; then
                print_success "✓ Console log: EXISTS"
                print_status "Last 5 lines of log:"
                tail -5 "$log_file"
            else
                print_error "✗ Console log: NOT_FOUND"
            fi
        else
            print_error "✗ World ID file: NOT_FOUND"
        fi
    else
        print_status "General server debug information"
        
        # Check screen sessions
        local screens=$(screen -list | grep "blockheads_server_" | wc -l)
        print_status "Active server screens: $screens"
        
        # Check running processes
        local processes=$(pgrep -f "blockheads_server171" | wc -l)
        print_status "Blockheads processes: $processes"
        
        # Check rank patcher
        local patchers=$(pgrep -f "rank_patcher.sh" | wc -l)
        print_status "Rank patcher processes: $patchers"
    fi
}

# Function to show usage
show_usage() {
    print_header "THE BLOCKHEADS SERVER MANAGER"
    echo "Usage: $0 [command] [options]"
    echo ""
    echo "Commands:"
    echo "  start <world_id> [port]    Start server with world ID and optional port"
    echo "  stop [port]                Stop server (all servers if no port specified)"
    echo "  status [port]              Show server status"
    echo "  list                       List all running servers"
    echo "  console <port>             Attach to server console"
    echo "  logs <port> <world_id>     Show recent server logs"
    echo "  debug [port]               Debug server issues"
    echo "  help                       Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 start MyWorld 12155     # Start server with world 'MyWorld' on port 12155"
    echo "  $0 start MyWorld           # Start server with default port 12155"
    echo "  $0 stop 12155              # Stop server on port 12155"
    echo "  $0 stop                    # Stop all servers"
    echo "  $0 status                  # Show status of all servers"
    echo "  $0 console 12155           # Attach to console of server on port 12155"
    echo "  $0 logs 12155 MyWorld      # Show logs for world MyWorld on port 12155"
    echo "  $0 debug 12155             # Debug server on port 12155"
    echo "  $0 debug                   # General debug information"
    echo "  $0 list                    # List all running servers"
    echo ""
    echo "Important Notes:"
    echo "  - First create a world using: ./blockheads_server171 -n"
    echo "  - During world creation, press Ctrl+C to exit after world is created"
    echo "  - The rank patcher automatically starts with the server"
    echo "  - Player management features are enabled automatically"
    echo ""
    print_warning "Default port: $DEFAULT_PORT"
    print_warning "Server Home: $SERVER_HOME"
}

# Main execution
case "${1:-help}" in
    start)
        if [ -z "$2" ]; then
            print_error "World ID required"
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
    console)
        show_console "$2"
        ;;
    logs)
        show_logs "$2" "$3"
        ;;
    debug)
        debug_server "$2"
        ;;
    help|--help|-h)
        show_usage
        ;;
    *)
        print_error "Unknown command: $1"
        show_usage
        exit 1
        ;;
esac
