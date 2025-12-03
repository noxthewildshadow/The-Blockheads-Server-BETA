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
    # ... (Código original de dependencias sin cambios) ...
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
        fi
    fi
    
    print_step "Checking for missing libraries..."
    local missing_libs=$(ldd "$SERVER_BINARY" 2>/dev/null | grep "not found" | awk '{print $1}' | tr '\n' ' ')
    
    if [ -n "$missing_libs" ]; then
        if command -v apt-get &> /dev/null; then
            print_step "Installing dependencies on Debian/Ubuntu..."
            sudo apt-get update
            for lib in $missing_libs; do
                case "$lib" in
                    libdispatch.so.0) sudo apt-get install -y libdispatch-dev || sudo apt-get install -y libdispatch0 ;;
                    libobjc.so.4) sudo apt-get install -y libobjc4 ;;
                    libgnustep-base.so.1.28) sudo apt-get install -y gnustep-base-runtime ;;
                    libpthread.so.0|libc.so.6|libm.so.6|libdl.so.2) sudo apt-get install -y libc6 ;;
                    *) sudo apt-get install -y "lib${lib%.*}" || sudo apt-get install -y "${lib%.*}" ;;
                esac
            done
        elif command -v pacman &> /dev/null; then
             print_step "Installing dependencies on Arch Linux..."
             sudo pacman -Sy --noconfirm libdispatch libobjc
        fi
    fi
    return 0
}

check_and_fix_libraries() {
    # ... (Código original sin cambios) ...
    print_header "CHECKING SYSTEM LIBRARIES"
    if [ ! -f "$SERVER_BINARY" ]; then
        print_error "Server binary not found: $SERVER_BINARY"
        return 1
    fi
    # ... (Resto de la función igual) ...
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
        echo ""
        print_warning "To create a world: ${GREEN}./blockheads_server171 -n${NC}"
        print_warning "After creating the world, press ${YELLOW}CTRL+C${NC} to exit"
        return 1
    fi
    return 0
}

free_port() {
    # ... (Código original sin cambios) ...
    local port="$1"
    print_warning "Freeing port $port..."
    local pids=$(lsof -ti ":$port")
    if [ -n "$pids" ]; then kill -9 $pids 2>/dev/null; fi
    
    local screen_server="blockheads_server_$port"
    local screen_patcher="blockheads_patcher_$port"
    
    if screen_session_exists "$screen_server"; then screen -S "$screen_server" -X quit 2>/dev/null; fi
    if screen_session_exists "$screen_patcher"; then screen -S "$screen_patcher" -X quit 2>/dev/null; fi
    
    sleep 2
    if is_port_in_use "$port"; then return 1; else return 0; fi
}

cleanup_server_lists() {
    local world_id="$1"
    local port="$2"
    (
        sleep 5
        local world_dir="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves/$world_id"
        rm -f "$world_dir/adminlist.txt" "$world_dir/modlist.txt"
    ) &
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
    
    if ! check_and_fix_libraries; then
        print_warning "Proceeding with library issues - server may fail to start"
    fi
    
    if ! check_world_exists "$world_id"; then
        return 1
    fi
    
    if is_port_in_use "$port"; then
        print_warning "Port $port is in use."
        if ! free_port "$port"; then
            print_error "Could not free port $port"
            return 1
        fi
    fi
    
    # Clean previous sessions
    if screen_session_exists "$SCREEN_SERVER"; then screen -S "$SCREEN_SERVER" -X quit 2>/dev/null; fi
    if screen_session_exists "$SCREEN_PATCHER"; then screen -S "$SCREEN_PATCHER" -X quit 2>/dev/null; fi
    
    sleep 1
    
    local log_dir="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves/$world_id"
    local log_file="$log_dir/console.log"
    mkdir -p "$log_dir"
    
    print_header "STARTING SERVER - WORLD: $world_id, PORT: $port"
    echo "$world_id" > "world_id_$port.txt"
    
    if ! command -v screen >/dev/null 2>&1; then
        print_error "Screen command not found. Please install screen."
        return 1
    fi
    
    # --- MODIFICADO: SISTEMA DE SELECCIÓN DE PARCHES ---
    local PRELOAD_LIST=""
    print_status "Configuring Patches..."

    # 1. Parche Crítico (Siempre activo si existe)
    if [ -f "name_exploit.so" ]; then
        PRELOAD_LIST="$PWD/name_exploit.so"
        print_success "Critical Patch [name_exploit] enabled."
    else
        print_warning "Critical Patch [name_exploit.so] NOT found!"
    fi

    # 2. Parches Opcionales (Selección interactiva)
    # Busca todos los .so excepto el name_exploit que ya cargamos
    for patch_file in *.so; do
        [ "$patch_file" == "name_exploit.so" ] && continue
        
        if [ -f "$patch_file" ]; then
            echo -n -e "${CYAN}Enable optional patch [${patch_file}]? (y/N): ${NC}"
            read choice
            if [[ "$choice" =~ ^[Yy]$ ]]; then
                if [ -n "$PRELOAD_LIST" ]; then
                    PRELOAD_LIST="$PRELOAD_LIST:$PWD/$patch_file"
                else
                    PRELOAD_LIST="$PWD/$patch_file"
                fi
                print_success "Enabled: $patch_file"
            else
                print_status "Skipped: $patch_file"
            fi
        fi
    done

    local ENV_VARS=""
    if [ -n "$PRELOAD_LIST" ]; then
        ENV_VARS="LD_PRELOAD=\"$PRELOAD_LIST\""
    fi
    # -----------------------------------------------------

    local start_script=$(mktemp)
    cat > "$start_script" << EOF
#!/bin/bash
cd '$PWD'
export LD_LIBRARY_PATH="$LD_LIBRARY_PATH"
while true; do
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Starting server..."
    # Inject dynamic patches
    $ENV_VARS ./blockheads_server171 -o '$world_id' -p $port 2>&1 | tee -a '$log_file'
    
    if [ \${PIPESTATUS[0]} -eq 0 ]; then
        echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Server closed normally"
    else
        echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Server failed/crashed."
    fi
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Restarting in 5 seconds..."
    sleep 5
done
EOF
    
    chmod +x "$start_script"
    
    if screen -dmS "$SCREEN_SERVER" bash -c "exec $start_script"; then
        print_success "Server screen session created successfully"
        (sleep 10; rm -f "$start_script") &
    else
        print_error "Failed to create screen session for server"
        rm -f "$start_script"
        return 1
    fi
    
    cleanup_server_lists "$world_id" "$port"
    
    print_step "Waiting for server to start..."
    local wait_time=0
    while [ ! -f "$log_file" ] && [ $wait_time -lt 15 ]; do
        sleep 1
        ((wait_time++))
    done
    
    if [ ! -f "$log_file" ]; then
        print_error "Could not create log file. Server may not have started."
        screen -S "$SCREEN_SERVER" -X quit 2>/dev/null
        return 1
    fi
    
    # ... (Resto del script igual para rank patcher) ...
    local server_ready=false
    for i in {1..30}; do
        if grep -q "World load complete\|Server started\|Ready for connections\|using seed:\|save delay:" "$log_file"; then
            server_ready=true
            break
        fi
        sleep 1
    done
    
    if [ "$server_ready" = false ]; then
        if ! screen_session_exists "$SCREEN_SERVER"; then
            print_error "Server screen session not found"
            return 1
        fi
        print_warning "Server log check timed out, but screen is running. Proceeding..."
    else
        print_success "Server started successfully!"
    fi

    # Iniciar Rank Patcher
    print_step "Starting rank patcher..."
    local patcher_script="./rank_patcher.sh"
    
    if [ ! -f "$patcher_script" ]; then
        print_error "Rank patcher script not found: $patcher_script"
        return 1
    fi
    chmod +x "$patcher_script"
    
    if ! screen -dmS "$SCREEN_PATCHER" bash -c "cd '$PWD' && ./rank_patcher.sh '$port'"; then
        print_error "Failed to create rank patcher screen session."
        return 1
    fi
    
    print_success "Rank patcher screen session created: $SCREEN_PATCHER"
    print_header "SERVER AND RANK PATCHER STARTED SUCCESSFULLY!"
    print_success "World: $world_id"
    print_success "Port: $port"
    if [ -n "$PRELOAD_LIST" ]; then
        print_status "Active Patches: $PRELOAD_LIST"
    fi
    echo ""
    print_status "To view server console: ${CYAN}screen -r $SCREEN_SERVER${NC}"
    print_status "To view rank patcher: ${CYAN}screen -r $SCREEN_PATCHER${NC}"
    echo ""
    print_warning "To exit console without stopping server: ${YELLOW}CTRL+A, D${NC}"
}

stop_server() {
    # ... (Función original stop_server sin cambios) ...
    local port="$1"
    if [ -z "$port" ]; then
        print_header "STOPPING ALL SERVERS"
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
        local screen_server="blockheads_server_$port"
        local screen_patcher="blockheads_patcher_$port"
        
        if screen_session_exists "$screen_server"; then screen -S "$screen_server" -X quit 2>/dev/null; print_success "Server stopped."; fi
        if screen_session_exists "$screen_patcher"; then screen -S "$screen_patcher" -X quit 2>/dev/null; print_success "Rank patcher stopped."; fi
        
        pkill -f "$SERVER_BINARY.*$port" 2>/dev/null || true
        rm -f "world_id_$port.txt" 2>/dev/null || true
    fi
}

list_servers() {
    # ... (Función original list_servers sin cambios) ...
    print_header "LIST OF RUNNING SERVERS"
    local servers=$(screen -list | grep "blockheads_server_" | awk -F. '{print $1}' | sed 's/blockheads_server_/ - Port: /')
    if [ -z "$servers" ]; then print_warning "No servers are currently running."; else print_status "Running servers:"; echo "$servers"; fi
}

show_status() {
    # ... (Función original show_status sin cambios) ...
    local port="$1"
    if [ -z "$port" ]; then
        print_header "THE BLOCKHEADS SERVER STATUS - ALL SERVERS"
        local servers=$(screen -list | grep "blockheads_server_" | awk -F. '{print $1}' | sed 's/blockheads_server_//')
        if [ -z "$servers" ]; then print_error "No servers running."; else
            while IFS= read -r server_port; do
                if screen_session_exists "blockheads_server_$server_port"; then print_success "Server $server_port: RUNNING"; else print_error "Server $server_port: STOPPED"; fi
            done <<< "$servers"
        fi
    else
        print_header "STATUS PORT $port"
        if screen_session_exists "blockheads_server_$port"; then print_success "Server: RUNNING"; else print_error "Server: STOPPED"; fi
    fi
}

install_system_dependencies() {
    # ... (Función original sin cambios) ...
    print_header "INSTALLING SYSTEM DEPENDENCIES"
    sudo apt-get update && sudo apt-get install -y screen binutils libdispatch-dev libobjc4 gnustep-base-runtime libc6
}

show_usage() {
    # ... (Función original sin cambios) ...
    print_header "THE BLOCKHEADS SERVER MANAGER"
    print_status "Usage: $0 [command]"
    echo " Commands: start, stop, status, list, install-deps, help"
}

case "$1" in
    start)
        if [ -z "$2" ]; then print_error "Specify WORLD_NAME"; show_usage; exit 1; fi
        start_server "$2" "$3"
        ;;
    stop) stop_server "$2" ;;
    status) show_status "$2" ;;
    list) list_servers ;;
    install-deps) install_system_dependencies ;;
    help|--help|-h|*) show_usage ;;
esac
