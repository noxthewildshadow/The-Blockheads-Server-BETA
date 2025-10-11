#!/bin/bash

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

SERVER_BINARY="./blockheads_server171"
DEFAULT_PORT=12153

install_dependencies() {
    print_header "INSTALLING REQUIRED DEPENDENCIES"
    
    if ! command -v ldd &> /dev/null; then
        print_step "Installing ldd utility..."
        if command -v apt-get &> /dev/null; then
            sudo apt-get update && sudo apt-get install -y binutils
        elif command -v yum &> /dev/null; then
            sudo yum install -y binutils
        elif command -v dnf &> /dev/null; then
            sudo dnf install -y binutils
        elif command -v pacman &> /dev/null; then
            sudo pacman -Sy --noconfirm binutils
        else
            print_warning "Cannot automatically install ldd. Please install binutils package manually."
        fi
    fi
    
    print_step "Checking for missing libraries..."
    local missing_libs=$(ldd "$SERVER_BINARY" 2>/dev/null | grep "not found" | awk '{print $1}' | tr '\n' ' ')
    
    if [ -n "$missing_libs" ]; then
        print_warning "Missing libraries detected: $missing_libs"
        
        if command -v apt-get &> /dev/null; then
            print_step "Installing dependencies on Debian/Ubuntu..."
            sudo apt-get update
            for lib in $missing_libs; do
                case "$lib" in
                    libdispatch.so.0)
                        print_step "Installing libdispatch..."
                        sudo apt-get install -y libdispatch-dev || sudo apt-get install -y libdispatch0
                        ;;
                    libobjc.so.4)
                        print_step "Installing libobjc4..."
                        sudo apt-get install -y libobjc4
                        ;;
                    libgnustep-base.so.1.28)
                        print_step "Installing gnustep-base..."
                        sudo apt-get install -y gnustep-base-runtime
                        ;;
                    libpthread.so.0|libc.so.6|libm.so.6|libdl.so.2)
                        print_step "Installing basic libraries..."
                        sudo apt-get install -y libc6
                        ;;
                    *)
                        print_warning "Unknown library: $lib - attempting to find package..."
                        sudo apt-get install -y "lib${lib%.*}" || sudo apt-get install -y "${lib%.*}"
                        ;;
                esac
            done
        elif command -v yum &> /dev/null; then
            print_step "Installing dependencies on RHEL/CentOS..."
            sudo yum install -y epel-release
            for lib in $missing_libs; do
                case "$lib" in
                    libdispatch.so.0)
                        print_step "Installing libdispatch..."
                        sudo yum install -y libdispatch || sudo yum install -y libdispatch-devel
                        ;;
                    libobjc.so.4)
                        print_step "Installing libobjc..."
                        sudo yum install -y libobjc
                        ;;
                    *)
                        print_warning "Unknown library: $lib"
                        ;;
                esac
            done
        elif command -v dnf &> /dev/null; then
            print_step "Installing dependencies on Fedora..."
            sudo dnf install -y epel-release
            for lib in $missing_libs; do
                case "$lib" in
                    libdispatch.so.0)
                        print_step "Installing libdispatch..."
                        sudo dnf install -y libdispatch || sudo dnf install -y libdispatch-devel
                        ;;
                    libobjc.so.4)
                        print_step "Installing libobjc..."
                        sudo dnf install -y libobjc
                        ;;
                    *)
                        print_warning "Unknown library: $lib"
                        ;;
                esac
            done
        elif command -v pacman &> /dev/null; then
            print_step "Installing dependencies on Arch Linux..."
            for lib in $missing_libs; do
                case "$lib" in
                    libdispatch.so.0)
                        print_step "Installing libdispatch..."
                        sudo pacman -Sy --noconfirm libdispatch
                        ;;
                    libobjc.so.4)
                        print_step "Installing libobjc..."
                        sudo pacman -Sy --noconfirm libobjc
                        ;;
                    *)
                        print_warning "Unknown library: $lib"
                        ;;
                esac
            done
        else
            print_error "Cannot automatically install dependencies on this system."
            print_status "Please install the following libraries manually: $missing_libs"
            return 1
        fi
        
        print_step "Verifying library installation..."
        local still_missing=$(ldd "$SERVER_BINARY" 2>/dev/null | grep "not found" | awk '{print $1}' | tr '\n' ' ')
        if [ -n "$still_missing" ]; then
            print_error "Still missing libraries: $still_missing"
            print_status "You may need to install these manually or use LD_LIBRARY_PATH"
            return 1
        else
            print_success "All dependencies installed successfully!"
        fi
    else
        print_success "No missing libraries detected."
    fi
    
    return 0
}

check_and_fix_libraries() {
    print_header "CHECKING SYSTEM LIBRARIES"
    
    if [ ! -f "$SERVER_BINARY" ]; then
        print_error "Server binary not found: $SERVER_BINARY"
        return 1
    fi
    
    if ! command -v ldd &> /dev/null; then
        print_error "ldd command not found. Please install binutils."
        return 1
    fi
    
    print_step "Checking library dependencies for $SERVER_BINARY..."
    
    local lib_error=$(ldd "$SERVER_BINARY" 2>&1 | grep -i "error\|not found\|cannot")
    
    if [ -n "$lib_error" ]; then
        print_warning "Library issues detected:"
        echo "$lib_error"
        echo ""
        
        print_step "Attempting to install missing dependencies..."
        if ! install_dependencies; then
            print_warning "Falling back to LD_LIBRARY_PATH workaround..."
            
            local lib_paths=""
            if [ -d "/usr/lib/x86_64-linux-gnu" ]; then
                lib_paths="/usr/lib/x86_64-linux-gnu:$lib_paths"
            fi
            if [ -d "/usr/lib64" ]; then
                lib_paths="/usr/lib64:$lib_paths"
            fi
            if [ -d "/usr/lib" ]; then
                lib_paths="/usr/lib:$lib_paths"
            fi
            if [ -d "/lib/x86_64-linux-gnu" ]; then
                lib_paths="/lib/x86_64-linux-gnu:$lib_paths"
            fi
            
            export LD_LIBRARY_PATH="$lib_paths:$LD_LIBRARY_PATH"
            print_status "Set LD_LIBRARY_PATH to: $LD_LIBRARY_PATH"
        fi
        
        print_step "Re-checking library dependencies..."
        ldd "$SERVER_BINARY" 2>/dev/null || {
            print_error "Library issues persist. The server may not start correctly."
            print_status "You may need to manually install the required libraries."
            return 1
        }
    else
        print_success "All libraries are available."
    fi
    
    return 0
}

screen_session_exists() {
    screen -list | grep -q "$1"
}

is_port_in_use() {
    lsof -Pi ":$1" -sTCP:LISTEN -t >/dev/null 2>&1
}

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

cleanup_server_lists() {
    local world_id="$1"
    local port="$2"
    
    print_step "Scheduled cleanup of adminlist.txt and modlist.txt in 5 seconds..."
    
    (
        sleep 5
        local world_dir="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves/$world_id"
        local admin_list="$world_dir/adminlist.txt"
        local mod_list="$world_dir/modlist.txt"
        
        if [ -f "$admin_list" ]; then
            rm -f "$admin_list"
            print_success "Cleaned up adminlist.txt for world $world_id"
        fi
        
        if [ -f "$mod_list" ]; then
            rm -f "$mod_list"
            print_success "Cleaned up modlist.txt for world $world_id"
        fi
        
        print_success "Server list cleanup completed for port $port"
    ) &
}

start_server() {
    local world_id="$1"
    local port="${2:-$DEFAULT_PORT}"
    
    local SCREEN_SERVER="blockheads_server_$port"
    local SCREEN_PATCHER="blockheads_patcher_$port"
    
    [ ! -f "$SERVER_BINARY" ] && {
        print_error "Server binary not found: $SERVER_BINARY"
        return 1
    }
    
    if ! check_and_fix_libraries; then
        print_warning "Proceeding with library issues - server may fail to start"
    fi
    
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
    
    echo "$world_id" > "world_id_$port.txt"
    
    cat > /tmp/start_server_$$.sh << EOF
#!/bin/bash
cd '$PWD'
export LD_LIBRARY_PATH="$LD_LIBRARY_PATH"
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
    
    print_step "Starting server in screen session: $SCREEN_SERVER"
    if command -v screen >/dev/null 2>&1; then
        if screen -dmS "$SCREEN_SERVER" /tmp/start_server_$$.sh; then
            print_success "Server screen session created successfully"
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
    
    cleanup_server_lists "$world_id" "$port"
    
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
        
        rm -f "world_id_$port.txt" 2>/dev/null || true
        
        print_success "Server cleanup completed for port $port."
    fi
}

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

install_system_dependencies() {
    print_header "INSTALLING SYSTEM DEPENDENCIES"
    
    if command -v apt-get &> /dev/null; then
        print_step "Installing dependencies on Debian/Ubuntu..."
        sudo apt-get update
        sudo apt-get install -y screen binutils libdispatch-dev libobjc4 gnustep-base-runtime libc6
    elif command -v yum &> /dev/null; then
        print_step "Installing dependencies on RHEL/CentOS..."
        sudo yum install -y epel-release
        sudo yum install -y screen binutils libdispatch libobjc
    elif command -v dnf &> /dev/null; then
        print_step "Installing dependencies on Fedora..."
        sudo dnf install -y epel-release
        sudo dnf install -y screen binutils libdispatch libobjc
    elif command -v pacman &> /dev/null; then
        print_step "Installing dependencies on Arch Linux..."
        sudo pacman -Sy --noconfirm screen binutils libdispatch libobjc
    else
        print_error "Cannot automatically install dependencies on this system."
        print_status "Please install manually: screen, binutils, libdispatch, libobjc"
        return 1
    fi
    
    print_success "System dependencies installed successfully!"
    return 0
}

show_usage() {
    print_header "THE BLOCKHEADS SERVER MANAGER"
    print_status "Usage: $0 [command]"
    echo ""
    print_status "Available commands:"
    echo -e " ${GREEN}start${NC} [WORLD_NAME] [PORT] - Start server with rank patcher"
    echo -e " ${RED}stop${NC} [PORT] - Stop server and rank patcher"
    echo -e " ${CYAN}status${NC} [PORT] - Show server status"
    echo -e " ${YELLOW}list${NC} - List all running servers"
    echo -e " ${MAGENTA}install-deps${NC} - Install system dependencies"
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
    echo -e " ${MAGENTA}$0 install-deps${NC} (installs system dependencies)"
    echo ""
    print_warning "First create a world: ./blockheads_server171 -n"
    print_warning "After creating the world, press CTRL+C to exit"
}

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
    install-deps)
        install_system_dependencies
        ;;
    help|--help|-h|*)
        show_usage
        ;;
esac
