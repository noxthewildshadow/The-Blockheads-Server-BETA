#!/bin/bash

# server_manager.sh - The Blockheads Server Manager
# Completely fixed version

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_status() { echo -e "${BLUE}[INFO]${NC} $1"; }

# Configuration
SERVER_BINARY="./blockheads_server171"
DEFAULT_PORT=12155
RANK_PATCHER="./rank_patcher.sh"

# Function to check screen session
screen_session_exists() {
    screen -list | grep -q "$1"
}

# Function to check port usage
is_port_in_use() {
    lsof -Pi ":$1" -sTCP:LISTEN -t >/dev/null 2>&1
}

# Function to free port
free_port() {
    local port="$1"
    print_warning "Freeing port $port..."
    
    # Kill processes
    local pids=$(lsof -ti ":$port")
    [ -n "$pids" ] && kill -9 $pids 2>/dev/null
    
    # Kill screen session
    local screen_name="blockheads_server_$port"
    if screen_session_exists "$screen_name"; then
        screen -S "$screen_name" -X quit 2>/dev/null
    fi
    
    sleep 2
    ! is_port_in_use "$port"
}

# Function to start rank patcher
start_rank_patcher() {
    if [ ! -f "$RANK_PATCHER" ]; then
        print_error "Rank patcher not found"
        return 1
    fi
    
    chmod +x "$RANK_PATCHER"
    
    # Check if already running
    if pgrep -f "rank_patcher.sh" > /dev/null; then
        print_status "Rank patcher already running"
        return 0
    fi
    
    # Start
    nohup "$RANK_PATCHER" > rank_patcher.log 2>&1 &
    local pid=$!
    
    sleep 2
    if ps -p $pid > /dev/null; then
        print_success "Rank patcher started"
        echo "$pid" > rank_patcher.pid
        return 0
    else
        print_error "Rank patcher failed to start"
        return 1
    fi
}

# Function to stop rank patcher
stop_rank_patcher() {
    # Kill from PID file
    if [ -f "rank_patcher.pid" ]; then
        local pid=$(cat rank_patcher.pid)
        kill "$pid" 2>/dev/null
        rm -f rank_patcher.pid
    fi
    
    # Force kill
    pkill -f "rank_patcher.sh" 2>/dev/null
    rm -f rank_patcher.log 2>/dev/null
}

# Function to check world exists
check_world_exists() {
    local world_id="$1"
    local saves_dir="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves"
    
    if [ ! -d "$saves_dir/$world_id" ]; then
        print_error "World not found: $world_id"
        print_warning "Create world first: ./blockheads_server171 -n"
        return 1
    fi
    return 0
}

# Function to start server
start_server() {
    local world_id="$1"
    local port="${2:-$DEFAULT_PORT}"
    local screen_name="blockheads_server_$port"
    
    # Validation
    if [ ! -f "$SERVER_BINARY" ]; then
        print_error "Server binary not found"
        return 1
    fi
    
    chmod +x "$SERVER_BINARY"
    
    if ! check_world_exists "$world_id"; then
        return 1
    fi
    
    # Check port
    if is_port_in_use "$port"; then
        print_warning "Port $port in use"
        if ! free_port "$port"; then
            print_error "Could not free port"
            return 1
        fi
    fi
    
    # Kill existing session
    if screen_session_exists "$screen_name"; then
        screen -S "$screen_name" -X quit 2>/dev/null
        sleep 1
    fi
    
    print_status "Starting server: $world_id on port $port"
    
    # Create startup script
    local startup_script=$(mktemp)
    cat > "$startup_script" << EOF
#!/bin/bash
cd "$PWD"
echo "Starting Blockheads server..."
while true; do
    if ./blockheads_server171 -o "$world_id" -p "$port"; then
        echo "Server stopped normally"
        break
    else
        echo "Server crashed, restarting in 5s..."
        sleep 5
    fi
done
EOF
    
    chmod +x "$startup_script"
    
    # Start server
    screen -dmS "$screen_name" "$startup_script"
    rm -f "$startup_script"
    
    # Wait for startup
    print_status "Waiting for server..."
    local attempts=0
    while [ $attempts -lt 30 ]; do
        if screen_session_exists "$screen_name" && is_port_in_use "$port"; then
            break
        fi
        sleep 1
        ((attempts++))
    done
    
    if [ $attempts -ge 30 ]; then
        print_error "Server failed to start"
        return 1
    fi
    
    print_success "Server started"
    
    # Start rank patcher
    if start_rank_patcher; then
        print_success "Rank system activated"
    else
        print_warning "Rank patcher failed"
    fi
    
    # Save world ID
    echo "$world_id" > "world_id_$port.txt"
    
    print_success "Server ready: $world_id:$port"
    print_status "Console: screen -r $screen_name"
    return 0
}

# Function to stop server
stop_server() {
    local port="$1"
    
    if [ -z "$port" ]; then
        print_status "Stopping all servers..."
        
        # Stop rank patcher
        stop_rank_patcher
        
        # Stop all servers
        for session in $(screen -list | grep "blockheads_server_" | awk -F. '{print $1}'); do
            screen -S "$session" -X quit 2>/dev/null
            print_success "Stopped: $session"
        done
        
        # Cleanup
        pkill -f "$SERVER_BINARY" 2>/dev/null
        rm -f world_id_*.txt 2>/dev/null
        
    else
        print_status "Stopping server on port $port..."
        
        local screen_name="blockheads_server_$port"
        if screen_session_exists "$screen_name"; then
            screen -S "$screen_name" -X quit 2>/dev/null
            print_success "Server stopped"
        else
            print_warning "Server not running"
        fi
        
        # Stop rank patcher
        stop_rank_patcher
        
        # Cleanup
        pkill -f "$SERVER_BINARY.*$port" 2>/dev/null
        rm -f "world_id_$port.txt" 2>/dev/null
    fi
}

# Function to show status
show_status() {
    local port="$1"
    
    if [ -z "$port" ]; then
        print_status "All servers status:"
        
        local servers=$(screen -list | grep "blockheads_server_" | awk -F. '{print $1}' | sed 's/blockheads_server_//')
        
        if [ -z "$servers" ]; then
            print_warning "No servers running"
        else
            for server_port in $servers; do
                if screen_session_exists "blockheads_server_$server_port"; then
                    print_success "Port $server_port: RUNNING"
                    if [ -f "world_id_$server_port.txt" ]; then
                        local world_id=$(cat "world_id_$server_port.txt")
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
        print_status "Server status port $port:"
        
        local screen_name="blockheads_server_$port"
        if screen_session_exists "$screen_name"; then
            print_success "Status: RUNNING"
            if [ -f "world_id_$port.txt" ]; then
                local world_id=$(cat "world_id_$port.txt")
                print_status "World: $world_id"
            fi
        else
            print_error "Status: STOPPED"
        fi
        
        if pgrep -f "rank_patcher.sh" > /dev/null; then
            print_success "Rank patcher: RUNNING"
        else
            print_warning "Rank patcher: STOPPED"
        fi
    fi
}

# Function to show usage
show_usage() {
    echo "Blockheads Server Manager"
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  start <world> [port]    Start server"
    echo "  stop [port]             Stop server"
    echo "  status [port]           Show status"
    echo "  help                    Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 start MyWorld 12155"
    echo "  $0 start MyWorld"
    echo "  $0 stop 12155"
    echo "  $0 stop"
    echo "  $0 status"
}

# Main
case "${1:-help}" in
    start)
        if [ -z "$2" ]; then
            print_error "World name required"
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
    help|*)
        show_usage
        ;;
esac
