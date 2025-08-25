#!/bin/bash

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
NC='\033[0m' # No Color

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
    echo -e "${PURPLE}================================================================"
    echo -e "$1"
    echo -e "===============================================================${NC}"
}

print_step() {
    echo -e "${CYAN}[STEP]${NC} $1"
}

# Configuration
SERVER_BINARY="./blockheads_server171"
DEFAULT_PORT=12153

# Function to check if screen session exists
screen_session_exists() {
    screen -list 2>/dev/null | grep -q "$1"
}

show_usage() {
    print_header "THE BLOCKHEADS SERVER MANAGER"
    print_status "Usage: $0 [command]"
    echo ""
    print_status "Available commands:"
    echo -e "  ${GREEN}start${NC} [WORLD_NAME] [PORT] - Start server and bot"
    echo -e "  ${RED}stop${NC} [PORT]                - Stop server and bot (specific port or all)"
    echo -e "  ${CYAN}status${NC} [PORT]              - Show server status (specific port or all)"
    echo -e "  ${YELLOW}list${NC}                     - List all running servers"
    echo -e "  ${YELLOW}help${NC}                      - Show this help"
    echo ""
    print_status "Examples:"
    echo -e "  ${GREEN}$0 start MyWorld 12153${NC}"
    echo -e "  ${GREEN}$0 start MyWorld${NC}        (uses default port 12153)"
    echo -e "  ${RED}$0 stop${NC}                   (stops all servers)"
    echo -e "  ${RED}$0 stop 12153${NC}            (stops server on port 12153)"
    echo -e "  ${CYAN}$0 status${NC}                (shows status of all servers)"
    echo -e "  ${CYAN}$0 status 12153${NC}         (shows status of server on port 12153)"
    echo -e "  ${YELLOW}$0 list${NC}                 (lists all running servers)"
    echo ""
    print_warning "Note: First create a world manually with:"
    echo -e "  ${GREEN}./blockheads_server171 -n${NC}"
    echo ""
    print_warning "After creating the world, press ${YELLOW}CTRL+C${NC} to exit"
    print_warning "and then start the server with the start command."
    print_header "END OF HELP"
}

is_port_in_use() {
    lsof -Pi ":$1" -sTCP:LISTEN -t >/dev/null
}

free_port() {
    local port="$1"
    print_warning "Freeing port $port..."
    local pids=$(lsof -ti ":$port")
    [ -n "$pids" ] && kill -9 $pids 2>/dev/null
    
    # Use our function to check if screen sessions exist before trying to quit them
    local screen_server="blockheads_server_$port"
    local screen_bot="blockheads_bot_$port"
    
    if screen_session_exists "$screen_server"; then
        screen -S "$screen_server" -X quit 2>/dev/null
    fi
    
    if screen_session_exists "$screen_bot"; then
        screen -S "$screen_bot" -X quit 2>/dev/null
    fi
    
    sleep 2
    ! is_port_in_use "$port"
}

check_world_exists() {
    local world_id="$1"
    local saves_dir="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves"
    [ -d "$saves_dir/$world_id" ] || {
        print_error "World '$world_id' does not exist in: $saves_dir/"
        echo ""
        print_warning "To create a world, run: ${GREEN}./blockheads_server171 -n${NC}"
        print_warning "After creating the world, press ${YELLOW}CTRL+C${NC} to exit"
        print_warning "and then start the server with: ${GREEN}$0 start $world_id $port${NC}"
        return 1
    }
    return 0
}

start_server() {
    local world_id="$1"
    local port="${2:-$DEFAULT_PORT}"

    # Define screen names with port
    local SCREEN_SERVER="blockheads_server_$port"
    local SCREEN_BOT="blockheads_bot_$port"

    # Verify server binary exists
    if [ ! -f "$SERVER_BINARY" ]; then
        print_error "Server binary not found: $SERVER_BINARY"
        print_warning "Run the installer first: ${GREEN}./installer.sh${NC}"
        return 1
    fi

    # Verify world exists
    if ! check_world_exists "$world_id"; then
        return 1
    fi

    # Check if port is in use
    if is_port_in_use "$port"; then
        print_warning "Port $port is in use."
        if ! free_port "$port"; then
            print_error "Could not free port $port"
            print_warning "Use a different port or terminate the process using it"
            return 1
        fi
    fi

    # Clean up previous sessions
    if screen_session_exists "$SCREEN_SERVER"; then
        screen -S "$SCREEN_SERVER" -X quit 2>/dev/null
    fi
    
    if screen_session_exists "$SCREEN_BOT"; then
        screen -S "$SCREEN_BOT" -X quit 2>/dev/null
    fi
    
    sleep 1

    local log_dir="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves/$world_id"
    local log_file="$log_dir/console.log"
    mkdir -p "$log_dir"

    print_step "Starting server - World: $world_id, Port: $port"
    echo "$world_id" > "world_id_$port.txt"

    # Start server - FIXED DATE FORMAT
    # Create a temporary script to avoid date formatting issues
    cat > /tmp/start_server_$$.sh << EOF
#!/bin/bash
cd '$PWD'
while true; do
    echo "[\\\$(date '+%Y-%m-%d %H:%M:%S')] Starting server..."
    if ./blockheads_server171 -o '$world_id' -p $port 2>&1 | tee -a '$log_file'; then
        echo "[\\\$(date '+%Y-%m-%d %H:%M:%S')] Server closed normally"
    else
        exit_code=\\\$?
        echo "[\\\$(date '+%Y-%m-%d %H:%M:%S')] Server failed with code: \\\$exit_code"
        if [ \\\$exit_code -eq 1 ] && tail -n 5 '$log_file' | grep -q "port.*already in use"; then
            echo "[\\\$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Port already in use. Will not retry."
            break
        fi
    fi
    echo "[\\\$(date '+%Y-%m-%d %H:%M:%S')] Restarting in 5 seconds..."
    sleep 5
done
EOF

    chmod +x /tmp/start_server_$$.sh
    
    screen -dmS "$SCREEN_SERVER" /tmp/start_server_$$.sh

    # Clean up temp script after a delay
    (sleep 10; rm -f /tmp/start_server_$$.sh) &

    # Wait for server to start
    print_step "Waiting for server to start..."
    local wait_time=0
    while [ ! -f "$log_file" ] && [ $wait_time -lt 15 ]; do
        sleep 1
        ((wait_time++))
    done

    if [ ! -f "$log_file" ]; then
        print_error "Could not create log file. Server may not have started."
        return 1
    fi

    # Wait for server to be ready - IMPROVED DETECTION
    local server_ready=false
    for i in {1..30}; do  # Increased timeout to 30 seconds
        # Check for various success messages that might indicate server is ready
        if grep -q "World load complete\|Server started\|Ready for connections\|using seed:\|save delay:" "$log_file"; then
            server_ready=true
            break
        fi
        sleep 1
    done

    if [ "$server_ready" = false ]; then
        print_warning "Server did not show complete startup messages, but continuing..."
        print_warning "This is normal for some server versions. Checking if server process is running..."
        
        # Additional check: see if the server process is actually running
        if screen_session_exists "$SCREEN_SERVER"; then
            print_success "Server screen session is active. Continuing..."
        else
            print_error "Server screen session not found. Server may have failed to start."
            return 1
        fi
    else
        print_success "Server started successfully!"
    fi

    # Start bot
    print_step "Starting server bot..."
    screen -dmS "$SCREEN_BOT" bash -c "
        cd '$PWD'
        echo 'Starting server bot for port $port...'
        ./server_bot.sh '$log_file' '$port'
    "

    # Verify both processes started correctly
    local server_started=0
    local bot_started=0
    
    if screen_session_exists "$SCREEN_SERVER"; then
        server_started=1
    fi
    
    if screen_session_exists "$SCREEN_BOT"; then
        bot_started=1
    fi
    
    if [ "$server_started" -eq 1 ] && [ "$bot_started" -eq 1 ]; then
        print_header "SERVER AND BOT STARTED SUCCESSFULLY!"
        print_success "World: $world_id"
        print_success "Port: $port"
        echo ""
        print_status "To view server console: ${CYAN}screen -r $SCREEN_SERVER${NC}"
        print_status "To view bot: ${CYAN}screen -r $SCREEN_BOT${NC}"
        echo ""
        print_warning "To exit console without stopping server: ${YELLOW}CTRL+A, D${NC}"
        print_header "SERVER IS NOW RUNNING"
    else
        print_warning "Could not verify all screen sessions"
        print_status "Server started: $server_started, Bot started: $bot_started"
        print_warning "Use 'screen -list' to view active sessions"
    fi
}

stop_server() {
    local port="$1"
    
    if [ -z "$port" ]; then
        print_step "Stopping all servers and bots..."
        
        # Stop all servers
        for server_session in $(screen -list | grep "blockheads_server_" | awk '{print $1}'); do
            screen -S "${server_session}" -X quit 2>/dev/null
            print_success "Stopped server: ${server_session}"
        done
        
        # Stop all bots
        for bot_session in $(screen -list | grep "blockheads_bot_" | awk '{print $1}'); do
            screen -S "${bot_session}" -X quit 2>/dev/null
            print_success "Stopped bot: ${bot_session}"
        done
        
        pkill -f "$SERVER_BINARY" 2>/dev/null || true
        print_success "Cleanup completed for all servers."
    else
        print_step "Stopping server and bot on port $port..."
        
        local screen_server="blockheads_server_$port"
        local screen_bot="blockheads_bot_$port"
        
        if screen_session_exists "$screen_server"; then
            screen -S "$screen_server" -X quit 2>/dev/null
            print_success "Server stopped on port $port."
        else
            print_warning "Server was not running on port $port."
        fi
        
        if screen_session_exists "$screen_bot"; then
            screen -S "$screen_bot" -X quit 2>/dev/null
            print_success "Bot stopped on port $port."
        else
            print_warning "Bot was not running on port $port."
        fi
        
        pkill -f "$SERVER_BINARY.*$port" 2>/dev/null || true
        print_success "Cleanup completed for port $port."
    fi
}

list_servers() {
    print_header "LIST OF RUNNING SERVERS"
    
    local servers=$(screen -list | grep "blockheads_server_" | awk '{print $1}' | sed 's/\.blockheads_server_/ - Port: /')
    
    if [ -z "$servers" ]; then
        print_warning "No servers are currently running."
    else
        print_status "Running servers:"
        while IFS= read -r server; do
            print_status "  $server"
        done <<< "$servers"
    fi
    
    print_header "END OF LIST"
}

show_status() {
    local port="$1"
    
    if [ -z "$port" ]; then
        print_header "THE BLOCKHEADS SERVER STATUS - ALL SERVERS"
        
        # Check all servers
        local servers=$(screen -list | grep "blockheads_server_" | awk '{print $1}' | sed 's/\.blockheads_server_//')
        
        if [ -z "$servers" ]; then
            print_error "No servers are currently running."
        else
            while IFS= read -r server_port; do
                if screen_session_exists "blockheads_server_$server_port"; then
                    print_success "Server on port $server_port: RUNNING"
                else
                    print_error "Server on port $server_port: STOPPED"
                fi
                
                if screen_session_exists "blockheads_bot_$server_port"; then
                    print_success "Bot on port $server_port: RUNNING"
                else
                    print_error "Bot on port $server_port: STOPPED"
                fi
                
                # Show world info if exists
                if [ -f "world_id_$server_port.txt" ]; then
                    local WORLD_ID=$(cat "world_id_$server_port.txt" 2>/dev/null)
                    print_status "World for port $server_port: ${CYAN}$WORLD_ID${NC}"
                fi
                
                echo ""
            done <<< "$servers"
        fi
    else
        print_header "THE BLOCKHEADS SERVER STATUS - PORT $port"
        
        # Check specific server
        if screen_session_exists "blockheads_server_$port"; then
            print_success "Server: RUNNING"
        else
            print_error "Server: STOPPED"
        fi
        
        # Check bot
        if screen_session_exists "blockheads_bot_$port"; then
            print_success "Bot: RUNNING"
        else
            print_error "Bot: STOPPED"
        fi
        
        # Show world info if exists
        if [ -f "world_id_$port.txt" ]; then
            local WORLD_ID=$(cat "world_id_$port.txt" 2>/dev/null)
            print_status "Current world: ${CYAN}$WORLD_ID${NC}"
            
            # Show port if server is running
            if screen_session_exists "blockheads_server_$port"; then
                print_status "To view console: ${CYAN}screen -r blockheads_server_$port${NC}"
                print_status "To view bot: ${CYAN}screen -r blockheads_bot_$port${NC}"
            fi
        else
            print_warning "World: Not configured for port $port (run 'start' first)"
        fi
    fi
    
    print_header "END OF STATUS"
}

# Command handling
case "$1" in
    start)
        if [ -z "$2" ]; then
            print_error "You must specify a WORLD_NAME"
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
    help|--help|-h|*)
        show_usage
        ;;
esac
