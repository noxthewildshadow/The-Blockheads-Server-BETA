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
PATCH_BINARY="freight_car_patch.so" # New patch file
DEFAULT_PORT=12153

install_dependencies() {
    print_header "INSTALLING REQUIRED DEPENDENCIES"
    if ! command -v ldd &> /dev/null; then
        if command -v apt-get &> /dev/null; then sudo apt-get update && sudo apt-get install -y binutils; fi
        if command -v pacman &> /dev/null; then sudo pacman -Sy --noconfirm binutils; fi
    fi
    # (Simplified dependency check kept from original logic structure)
    print_success "Dependencies checked."
    return 0
}

check_and_fix_libraries() {
    print_header "CHECKING SYSTEM LIBRARIES"
    if [ ! -f "$SERVER_BINARY" ]; then
        print_error "Server binary not found: $SERVER_BINARY"
        return 1
    fi
    # Basic check
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
    if [ ! -d "$saves_dir/$world_id" ]; then
        print_error "World '$world_id' does not exist in: $saves_dir/"
        print_warning "To create a world: ./blockheads_server171 -n"
        return 1
    fi
    return 0
}

cleanup_server_lists() {
    local world_id="$1"
    local world_dir="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves/$world_id"
    rm -f "$world_dir/adminlist.txt" "$world_dir/modlist.txt" 2>/dev/null
}

start_server() {
    local world_id="$1"
    local port="${2:-$DEFAULT_PORT}"
    
    local SCREEN_SERVER="blockheads_server_$port"
    local SCREEN_PATCHER="blockheads_patcher_$port"
    
    if [ ! -f "$SERVER_BINARY" ]; then
        print_error "Server binary not found: $SERVER_BINARY"
        return 1
    fi
    
    if ! check_world_exists "$world_id"; then return 1; fi
    
    if is_port_in_use "$port"; then
        print_error "Port $port is in use."
        return 1
    fi
    
    local log_dir="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves/$world_id"
    local log_file="$log_dir/console.log"
    mkdir -p "$log_dir"
    
    print_header "STARTING SERVER - WORLD: $world_id, PORT: $port"
    echo "$world_id" > "world_id_$port.txt"
    
    # Check for the patch
    local PRELOAD_CMD=""
    if [ -f "$PWD/$PATCH_BINARY" ]; then
        print_status "Security Patch found: $PATCH_BINARY"
        PRELOAD_CMD="export LD_PRELOAD=\"$PWD/$PATCH_BINARY\""
    else
        print_warning "Security Patch NOT found. Server running unprotected."
    fi

    # Create the startup script with the LD_PRELOAD injection
    local start_script=$(mktemp)
    cat > "$start_script" << EOF
#!/bin/bash
cd '$PWD'
export LD_LIBRARY_PATH="$LD_LIBRARY_PATH"
$PRELOAD_CMD

while true; do
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Starting server..."
    if ./blockheads_server171 -o '$world_id' -p $port 2>&1 | tee -a '$log_file'; then
        echo "[\$(date)] Server closed normally"
    else
        echo "[\$(date)] Server failed. Restarting in 5s..."
    fi
    sleep 5
done
EOF
    
    chmod +x "$start_script"
    
    if screen -dmS "$SCREEN_SERVER" bash -c "exec $start_script"; then
        print_success "Server screen session created successfully"
        (sleep 10; rm -f "$start_script") &
    else
        print_error "Failed to create screen session"
        return 1
    fi
    
    cleanup_server_lists "$world_id"
    
    # Wait for log file
    sleep 2
    
    print_step "Starting rank patcher..."
    if ! screen -dmS "$SCREEN_PATCHER" bash -c "cd '$PWD' && ./rank_patcher.sh '$port'"; then
        print_error "Failed to start rank patcher."
    else
        print_success "Rank patcher started: $SCREEN_PATCHER"
    fi
    
    echo ""
    print_status "To view server console: screen -r $SCREEN_SERVER"
    print_status "To view rank patcher: screen -r $SCREEN_PATCHER"
}

stop_server() {
    local port="$1"
    if [ -z "$port" ]; then
        print_header "STOPPING ALL SERVERS"
        for server_session in $(screen -list | grep "blockheads_server_" | awk -F. '{print $1}'); do
            screen -S "$server_session" -X quit 2>/dev/null
        done
        for patcher_session in $(screen -list | grep "blockheads_patcher_" | awk -F. '{print $1}'); do
            screen -S "$patcher_session" -X quit 2>/dev/null
        done
        pkill -f "$SERVER_BINARY" 2>/dev/null || true
        rm -f world_id_*.txt 2>/dev/null || true
        print_success "All servers stopped."
    else
        print_header "STOPPING SERVER ON PORT $port"
        screen -S "blockheads_server_$port" -X quit 2>/dev/null
        screen -S "blockheads_patcher_$port" -X quit 2>/dev/null
        pkill -f "$SERVER_BINARY.*$port" 2>/dev/null || true
        rm -f "world_id_$port.txt" 2>/dev/null || true
        print_success "Server stopped on port $port."
    fi
}

list_servers() {
    print_header "LIST OF RUNNING SERVERS"
    screen -list | grep "blockheads_server_"
}

show_status() {
    local port="$1"
    if [ -z "$port" ]; then
        print_header "STATUS - ALL SERVERS"
        screen -list | grep blockheads
    else
        print_header "STATUS - PORT $port"
        if screen_session_exists "blockheads_server_$port"; then
            print_success "Server: RUNNING"
        else
            print_error "Server: STOPPED"
        fi
    fi
}

show_usage() {
    print_header "THE BLOCKHEADS SERVER MANAGER"
    echo -e " ${GREEN}start${NC} [WORLD_NAME] [PORT]"
    echo -e " ${RED}stop${NC} [PORT]"
    echo -e " ${CYAN}status${NC} [PORT]"
    echo -e " ${YELLOW}list${NC}"
    echo -e " ${MAGENTA}install-deps${NC}"
}

case "$1" in
    start)
        [ -z "$2" ] && print_error "Specify WORLD_NAME" && exit 1
        start_server "$2" "$3"
        ;;
    stop) stop_server "$2" ;;
    status) show_status "$2" ;;
    list) list_servers ;;
    install-deps) install_dependencies ;;
    *) show_usage ;;
esac
