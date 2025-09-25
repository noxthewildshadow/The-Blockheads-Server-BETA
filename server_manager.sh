#!/bin/bash

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
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

print_step() {
    echo -e "${CYAN}[STEP]${NC} $1"
}

print_header() {
    echo -e "${MAGENTA}================================================================================${NC}"
    echo -e "${MAGENTA}$1${NC}"
    echo -e "${MAGENTA}================================================================================${NC}"
}

# Server binary and default port
SERVER_BINARY="./blockheads_server171"
RANK_PATCHER="./rank_patcher.sh"
DEFAULT_PORT=12153

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

# Function to start server
start_server() {
    local world_id="$1"
    local port="${2:-$DEFAULT_PORT}"
    
    local SCREEN_SERVER="blockheads_server_$port"
    local SCREEN_PATCHER="rank_patcher_$port"
    
    [ ! -f "$SERVER_BINARY" ] && {
        print_error "Server binary not found: $SERVER_BINARY"
        return 1
    }
    
    [ ! -f "$RANK_PATCHER" ] && {
        print_error "Rank patcher not found: $RANK_PATCHER"
        print_warning "Please download it using the installer or manually"
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
    
    # Create startup script for server
    cat > /tmp/start_server_$$.sh << EOF
#!/bin/bash
cd '$PWD'
echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Starting Blockheads server for world: $world_id on port: $port"
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
echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Server process ended"
EOF
    
    chmod +x /tmp/start_server_$$.sh
    
    # Create startup script for rank patcher
    cat > /tmp/start_patcher_$$.sh << EOF
#!/bin/bash
cd '$PWD'
echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Starting rank patcher for world: $world_id, port: $port"
while true; do
    if ./rank_patcher.sh '$world_id' '$port'; then
        echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Rank patcher exited normally"
    else
        exit_code=\$?
        echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Rank patcher failed with code: \$exit_code"
    fi
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Restarting rank patcher in 5 seconds..."
    sleep 5
done
EOF
    
    chmod +x /tmp/start_patcher_$$.sh
    
    # Start server in screen session
    print_step "Starting server in screen session: $SCREEN_SERVER"
    screen -dmS "$SCREEN_SERVER" /tmp/start_server_$$.sh
    
    # Wait a moment for server to start creating files
    sleep 5
    
    # Start rank patcher in separate screen session
    print_step "Starting rank patcher in screen session: $SCREEN_PATCHER"
    screen -dmS "$SCREEN_PATCHER" /tmp/start_patcher_$$.sh
    
    # Clean up temp files after they're used
    (sleep 10; rm -f /tmp/start_server_$$.sh /tmp/start_patcher_$$.sh) &
    
    print_step "Waiting for server to start..."
    
    local wait_time=0
    while [ ! -f "$log_file" ] && [ $wait_time -lt 20 ]; do
        sleep 1
        ((wait_time++))
    done
    
    [ ! -f "$log_file" ] && {
        print_error "Could not create log file. Server may not have started."
        return 1
    }
    
    local server_ready=false
    local patcher_ready=false
    
    for i in {1..30}; do
        # Check server startup
        if grep -q "World load complete\|Server started\|Ready for connections\|using seed:\|save delay:" "$log_file"; then
            server_ready=true
        fi
        
        # Check if rank patcher is running
        if screen_session_exists "$SCREEN_PATCHER"; then
            patcher_ready=true
        fi
        
        [ "$server_ready" = true ] && [ "$patcher_ready" = true ] && break
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
    
    if [ "$patcher_ready" = true ]; then
        print_success "Rank patcher started successfully!"
    else
        print_warning "Rank patcher may not have started correctly"
    fi
    
    print_header "SERVER STARTED SUCCESSFULLY!"
    print_success "World: $world_id"
    print_success "Port: $port"
    print_success "Server Session: $SCREEN_SERVER"
    print_success "Rank Patcher Session: $SCREEN_PATCHER"
    echo ""
    print_status "To view server console: ${CYAN}screen -r $SCREEN_SERVER${NC}"
    print_status "To view rank patcher: ${CYAN}screen -r $SCREEN_PATCHER${NC}"
    echo ""
    print_warning "To exit console without stopping server: ${YELLOW}CTRL+A, D${NC}"
    print_warning "To stop the server: ${YELLOW}./server_manager.sh stop $port${NC}"
}

# Function to stop server
stop_server() {
    local port="$1"
    
    if [ -z "$port" ]; then
        print_header "STOPPING ALL SERVERS AND RANK PATCHERS"
        print_step "Stopping all servers and rank patchers..."
        
        # Stop all server sessions
        local server_count=0
        for server_session in $(screen -list | grep "blockheads_server_" | awk -F. '{print $1}' | sort -u); do
            screen -S "$server_session" -X quit 2>/dev/null
            print_success "Stopped server: $server_session"
            ((server_count++))
        done
        
        # Stop all rank patcher sessions
        local patcher_count=0
        for patcher_session in $(screen -list | grep "rank_patcher_" | awk -F. '{print $1}' | sort -u); do
            screen -S "$patcher_session" -X quit 2>/dev/null
            print_success "Stopped rank patcher: $patcher_session"
            ((patcher_count++))
        done
        
        # Kill any remaining processes
        pkill -f "$SERVER_BINARY" 2>/dev/null || true
        pkill -f "$RANK_PATCHER" 2>/dev/null || true
        
        # Clean up world ID files
        rm -f world_id_*.txt 2>/dev/null || true
        
        print_success "Stopped $server_count servers and $patcher_count rank patchers."
    else
        print_header "STOPPING SERVER ON PORT $port"
        print_step "Stopping server and rank patcher on port $port..."
        
        local screen_server="blockheads_server_$port"
        local screen_patcher="rank_patcher_$port"
        local stopped_count=0
        
        if screen_session_exists "$screen_server"; then
            screen -S "$screen_server" -X quit 2>/dev/null
            print_success "Stopped server: $screen_server"
            ((stopped_count++))
        else
            print_warning "Server was not running on port $port."
        fi
        
        if screen_session_exists "$screen_patcher"; then
            screen -S "$screen_patcher" -X quit 2>/dev/null
            print_success "Stopped rank patcher: $screen_patcher"
            ((stopped_count++))
        else
            print_warning "Rank patcher was not running on port $port."
        fi
        
        # Kill any remaining processes for this port
        pkill -f "$SERVER_BINARY.*$port" 2>/dev/null || true
        pkill -f "$RANK_PATCHER.*$port" 2>/dev/null || true
        
        # Clean up world ID file for this port
        rm -f "world_id_$port.txt" 2>/dev/null || true
        
        if [ $stopped_count -gt 0 ]; then
            print_success "Stopped $stopped_count processes for port $port."
        else
            print_warning "No processes were running on port $port."
        fi
    fi
}

# Function to restart server
restart_server() {
    local world_id="$1"
    local port="${2:-$DEFAULT_PORT}"
    
    print_header "RESTARTING SERVER - WORLD: $world_id, PORT: $port"
    
    stop_server "$port"
    sleep 3
    start_server "$world_id" "$port"
}

# Function to list servers
list_servers() {
    print_header "LIST OF RUNNING SERVERS AND RANK PATCHERS"
    
    local servers=$(screen -list | grep "blockheads_server_" | awk -F. '{print $1}' | sed 's/blockheads_server_/Port: /' | sort -u)
    local patchers=$(screen -list | grep "rank_patcher_" | awk -F. '{print $1}' | sed 's/rank_patcher_/Port: /' | sort -u)
    
    if [ -z "$servers" ] && [ -z "$patchers" ]; then
        print_warning "No servers or rank patchers are currently running."
    else
        if [ -n "$servers" ]; then
            print_status "Running servers:"
            echo -e "${GREEN}$servers${NC}" | while read -r server; do
                print_status "  $server"
            done
        else
            print_warning "No servers are running."
        fi
        
        if [ -n "$patchers" ]; then
            print_status "Running rank patchers:"
            echo -e "${CYAN}$patchers${NC}" | while read -r patcher; do
                print_status "  $patcher"
            done
        else
            print_warning "No rank patchers are running."
        fi
    fi
    
    print_header "END OF LIST"
}

# Function to show detailed status
show_status() {
    local port="$1"
    
    if [ -z "$port" ]; then
        print_header "THE BLOCKHEADS SERVER STATUS - ALL SERVERS"
        
        local servers=$(screen -list | grep "blockheads_server_" | awk -F. '{print $1}' | sed 's/blockheads_server_//' | sort -u)
        
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
                    print_error "Rank Patcher: STOPPED"
                fi
                
                if [ -f "world_id_$server_port.txt" ]; then
                    local WORLD_ID=$(cat "world_id_$server_port.txt" 2>/dev/null)
                    print_status "World: ${CYAN}$WORLD_ID${NC}"
                else
                    print_warning "World: Not configured"
                fi
                
                # Show port usage
                if is_port_in_use "$server_port"; then
                    print_status "Port $server_port: IN USE"
                else
                    print_warning "Port $server_port: NOT IN USE"
                fi
                echo ""
            done <<< "$servers"
        fi
    else
        print_header "THE BLOCKHEADS SERVER STATUS - PORT $port"
        
        local screen_server="blockheads_server_$port"
        local screen_patcher="rank_patcher_$port"
        
        if screen_session_exists "$screen_server"; then
            print_success "Server: RUNNING"
            print_status "Session: $screen_server"
        else
            print_error "Server: STOPPED"
        fi
        
        if screen_session_exists "$screen_patcher"; then
            print_success "Rank Patcher: RUNNING"
            print_status "Session: $screen_patcher"
        else
            print_error "Rank Patcher: STOPPED"
        fi
        
        if [ -f "world_id_$port.txt" ]; then
            local WORLD_ID=$(cat "world_id_$port.txt" 2>/dev/null)
            print_status "World: ${CYAN}$WORLD_ID${NC}"
            
            if screen_session_exists "$screen_server"; then
                print_status "To view server console: ${CYAN}screen -r $screen_server${NC}"
            fi
            if screen_session_exists "$screen_patcher"; then
                print_status "To view rank patcher: ${CYAN}screen -r $screen_patcher${NC}"
            fi
        else
            print_warning "World: Not configured for port $port"
        fi
        
        # Show port usage
        if is_port_in_use "$port"; then
            print_status "Port $port: IN USE"
        else
            print_warning "Port $port: NOT IN USE"
        fi
    fi
    
    print_header "END OF STATUS"
}

# Function to show logs
show_logs() {
    local port="$1"
    local lines="${2:-50}"
    
    if [ -z "$port" ]; then
        print_error "You must specify a PORT to view logs"
        echo ""
        print_status "Usage: $0 logs PORT [LINES]"
        print_status "Example: $0 logs 12153 100"
        return 1
    fi
    
    local world_id=""
    if [ -f "world_id_$port.txt" ]; then
        world_id=$(cat "world_id_$port.txt" 2>/dev/null)
    else
        print_error "No world configured for port $port"
        return 1
    fi
    
    local log_file="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves/$world_id/console.log"
    
    if [ ! -f "$log_file" ]; then
        print_error "Log file not found: $log_file"
        return 1
    fi
    
    print_header "SERVER LOGS - PORT: $port, WORLD: $world_id (last $lines lines)"
    tail -n "$lines" "$log_file"
}

# Function to show usage
show_usage() {
    print_header "THE BLOCKHEADS SERVER MANAGER WITH RANK PATCHER"
    print_status "Usage: $0 [command] [options]"
    echo ""
    print_status "Available commands:"
    echo -e " ${GREEN}start${NC}   [WORLD_NAME] [PORT]    - Start server with rank patcher"
    echo -e " ${RED}stop${NC}    [PORT]                 - Stop server and rank patcher"
    echo -e " ${YELLOW}restart${NC} [WORLD_NAME] [PORT]    - Restart server and rank patcher"
    echo -e " ${CYAN}status${NC}  [PORT]                 - Show server and rank patcher status"
    echo -e " ${CYAN}logs${NC}    [PORT] [LINES]         - Show server logs (default: 50 lines)"
    echo -e " ${YELLOW}list${NC}                         - List all running servers and rank patchers"
    echo -e " ${YELLOW}help${NC}                         - Show this help"
    echo ""
    print_status "Examples:"
    echo -e " ${GREEN}$0 start MyWorld 12153${NC}"
    echo -e " ${GREEN}$0 start MyWorld${NC}          (uses default port 12153)"
    echo -e " ${RED}$0 stop${NC}                   (stops all servers and rank patchers)"
    echo -e " ${RED}$0 stop 12153${NC}             (stops server and rank patcher on port 12153)"
    echo -e " ${YELLOW}$0 restart MyWorld 12153${NC}"
    echo -e " ${CYAN}$0 status${NC}                (shows status of all servers and rank patchers)"
    echo -e " ${CYAN}$0 status 12153${NC}          (shows status on port 12153)"
    echo -e " ${CYAN}$0 logs 12153 100${NC}        (shows last 100 lines of logs)"
    echo -e " ${YELLOW}$0 list${NC}                (lists all running servers and rank patchers)"
    echo ""
    print_warning "First create a world: ./blockheads_server171 -n"
    print_warning "After creating the world, press CTRL+C to exit"
    echo ""
    print_status "Rank Patcher Features:"
    echo -e " ${CYAN}• Player authentication with IP verification${NC}"
    echo -e " ${CYAN}• Password protection for players${NC}"
    echo -e " ${CYAN}• Automated rank management (ADMIN, MOD, SUPER)${NC}"
    echo -e " ${CYAN}• Real-time monitoring of player lists${NC}"
}

# Check if required files exist
check_requirements() {
    if [ ! -f "$SERVER_BINARY" ]; then
        print_error "Server binary not found: $SERVER_BINARY"
        print_warning "Please run the installer first or ensure the binary exists"
        return 1
    fi
    
    if [ ! -x "$SERVER_BINARY" ]; then
        print_warning "Server binary is not executable, fixing permissions..."
        chmod +x "$SERVER_BINARY" || {
            print_error "Failed to make server binary executable"
            return 1
        }
    fi
    
    if [ ! -f "$RANK_PATCHER" ]; then
        print_warning "Rank patcher not found: $RANK_PATCHER"
        print_warning "Some features will be disabled"
    elif [ ! -x "$RANK_PATCHER" ]; then
        print_warning "Rank patcher is not executable, fixing permissions..."
        chmod +x "$RANK_PATCHER" || print_error "Failed to make rank patcher executable"
    fi
    
    return 0
}

# Main execution
case "$1" in
    start)
        check_requirements || exit 1
        [ -z "$2" ] && print_error "You must specify a WORLD_NAME" && show_usage && exit 1
        start_server "$2" "$3"
        ;;
    stop)
        stop_server "$2"
        ;;
    restart)
        check_requirements || exit 1
        [ -z "$2" ] && print_error "You must specify a WORLD_NAME" && show_usage && exit 1
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
    help|--help|-h|"")
        show_usage
        ;;
    *)
        print_error "Unknown command: $1"
        echo ""
        show_usage
        exit 1
        ;;
esac
