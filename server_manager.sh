#!/bin/bash

# ==============================================================================
# THE BLOCKHEADS SERVER MANAGER - FINAL VERSION
# ==============================================================================

# --- COLORS ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# --- LOGGING HELPERS ---
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

# --- CONFIGURATION ---
SERVER_BINARY="./blockheads_server171"
DEFAULT_PORT=12153
PATCHES_DIR="patches"

# --- DEPENDENCY INSTALLATION ---
install_dependencies() {
    print_header "INSTALLING REQUIRED DEPENDENCIES"
    if ! command -v ldd &> /dev/null; then
        print_step "Installing ldd utility..."
        if command -v apt-get &> /dev/null; then sudo apt-get update && sudo apt-get install -y binutils
        elif command -v yum &> /dev/null; then sudo yum install -y binutils
        elif command -v dnf &> /dev/null; then sudo dnf install -y binutils
        elif command -v pacman &> /dev/null; then sudo pacman -Sy --noconfirm binutils
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
        elif command -v yum &> /dev/null; then
            print_step "Installing dependencies on RHEL/CentOS..."
            sudo yum install -y epel-release
            for lib in $missing_libs; do
                case "$lib" in
                    libdispatch.so.0) sudo yum install -y libdispatch || sudo yum install -y libdispatch-devel ;;
                    libobjc.so.4) sudo yum install -y libobjc ;;
                esac
            done
        elif command -v dnf &> /dev/null; then
            print_step "Installing dependencies on Fedora..."
            sudo dnf install -y epel-release
            for lib in $missing_libs; do
                case "$lib" in
                    libdispatch.so.0) sudo dnf install -y libdispatch || sudo dnf install -y libdispatch-devel ;;
                    libobjc.so.4) sudo dnf install -y libobjc ;;
                esac
            done
        elif command -v pacman &> /dev/null; then
            print_step "Installing dependencies on Arch Linux..."
            for lib in $missing_libs; do
                case "$lib" in
                    libdispatch.so.0) sudo pacman -Sy --noconfirm libdispatch ;;
                    libobjc.so.4) sudo pacman -Sy --noconfirm libobjc ;;
                esac
            done
        fi
    fi
    return 0
}

# --- LIBRARY CHECK ---
check_and_fix_libraries() {
    print_header "CHECKING SYSTEM LIBRARIES"
    if [ ! -f "$SERVER_BINARY" ]; then print_error "Server binary not found: $SERVER_BINARY"; return 1; fi
    if ! command -v ldd &> /dev/null; then print_error "ldd command not found. Please install binutils."; return 1; fi
    
    print_step "Checking library dependencies for $SERVER_BINARY..."
    local lib_error=$(ldd "$SERVER_BINARY" 2>&1 | grep -i "error\|not found\|cannot")
    
    if [ -n "$lib_error" ]; then
        if ! install_dependencies; then
            local lib_paths=""
            if [ -d "/usr/lib/x86_64-linux-gnu" ]; then lib_paths="/usr/lib/x86_64-linux-gnu:$lib_paths"; fi
            if [ -d "/usr/lib64" ]; then lib_paths="/usr/lib64:$lib_paths"; fi
            if [ -d "/usr/lib" ]; then lib_paths="/usr/lib:$lib_paths"; fi
            if [ -d "/lib/x86_64-linux-gnu" ]; then lib_paths="/lib/x86_64-linux-gnu:$lib_paths"; fi
            export LD_LIBRARY_PATH="$lib_paths:$LD_LIBRARY_PATH"
        fi
    fi
    return 0
}

# --- UTILS ---
screen_session_exists() { screen -list | grep -q "$1"; }
is_port_in_use() { lsof -Pi ":$1" -sTCP:LISTEN -t >/dev/null 2>&1; }

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
    local port="$1"
    print_warning "Freeing port $port..."
    local pids=$(lsof -ti ":$port")
    if [ -n "$pids" ]; then kill -9 $pids 2>/dev/null; fi
    local screen_server="blockheads_server_$port"
    local screen_patcher="blockheads_manager_$port"
    if screen_session_exists "$screen_server"; then screen -S "$screen_server" -X quit 2>/dev/null; fi
    if screen_session_exists "$screen_patcher"; then screen -S "$screen_patcher" -X quit 2>/dev/null; fi
    sleep 2
    if is_port_in_use "$port"; then return 1; else return 0; fi
}

cleanup_server_lists() {
    local world_id="$1"
    (
        sleep 5
        local world_dir="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves/$world_id"
        rm -f "$world_dir/adminlist.txt" "$world_dir/modlist.txt"
    ) &
}

# --- MAIN LOGIC ---
start_server() {
    local world_id="$1"
    local port="${2:-$DEFAULT_PORT}"
    local SCREEN_SERVER="blockheads_server_$port"
    local SCREEN_MANAGER="blockheads_manager_$port"
    
    if [ ! -f "$SERVER_BINARY" ]; then print_error "Server binary not found"; return 1; fi
    if ! check_and_fix_libraries; then print_warning "Proceeding with library issues - server may fail to start"; fi
    if ! check_world_exists "$world_id"; then return 1; fi
    if is_port_in_use "$port"; then
        print_warning "Port $port is in use."
        if ! free_port "$port"; then print_error "Could not free port $port"; return 1; fi
    fi
    
    if screen_session_exists "$SCREEN_SERVER"; then screen -S "$SCREEN_SERVER" -X quit 2>/dev/null; fi
    if screen_session_exists "$SCREEN_MANAGER"; then screen -S "$SCREEN_MANAGER" -X quit 2>/dev/null; fi
    sleep 1
    
    local log_dir="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves/$world_id"
    local log_file="$log_dir/console.log"
    mkdir -p "$log_dir"
    
    print_header "STARTING SERVER - WORLD: $world_id, PORT: $port"
    echo "$world_id" > "world_id_$port.txt"
    print_step "Starting server in screen session: $SCREEN_SERVER"
    
    if ! command -v screen >/dev/null 2>&1; then
        print_error "Screen command not found. Please install screen."
        return 1
    fi
    
    # 1. Ask Rank Manager
    echo -n -e "${YELLOW}Start Rank Manager (Security & Ranks)? (y/N): ${NC}"
    read use_rank_manager < /dev/tty
    
    # ==========================================================================
    # PATCH DETECTION (CRITICAL FIRST, THEN OPTIONAL)
    # ==========================================================================
    local PRELOAD_STR=""
    local PATCH_LIST=""
    local HAS_WORLD_MODE_PATCH=false
    local HAS_WORLD_SIZE_PATCH=false
    
    if [ -d "$PATCHES_DIR" ]; then
        print_status "Scanning '$PATCHES_DIR' for security patches..."
        
        # --- A. CRITICAL PATCHES (Auto-Enable) ---
        if [ -d "$PATCHES_DIR/critical" ]; then
            shopt -s nullglob
            for critical_patch in "$PATCHES_DIR/critical/"*.so; do
                if [ -z "$PATCH_LIST" ]; then PATCH_LIST="$PWD/$critical_patch"; else PATCH_LIST="$PATCH_LIST:$PWD/$critical_patch"; fi
                
                local p_name=$(basename "$critical_patch")
                print_success "Critical Patch Detected: [$p_name]"
                
                # Flag special patches for later configuration
                if [[ "$p_name" == "change_world_mode.so" ]]; then HAS_WORLD_MODE_PATCH=true; fi
                if [[ "$p_name" == "change_world_size.so" ]]; then HAS_WORLD_SIZE_PATCH=true; fi
            done
            shopt -u nullglob
        fi
        
        # --- B. OPTIONAL PATCHES & MODS (Ask User) ---
        shopt -s nullglob
        for patch_path in "$PATCHES_DIR/optional/"*.so "$PATCHES_DIR/mods/"*.so; do
            [ ! -f "$patch_path" ] && continue
            local optional_name=$(basename "$patch_path")
            
            echo -n -e "${YELLOW}Enable patch/mod [${optional_name}]? (y/N): ${NC}"
            read answer < /dev/tty
            
            if [[ "$answer" =~ ^[Yy]$ ]]; then
                if [ -z "$PATCH_LIST" ]; then PATCH_LIST="$PWD/$patch_path"; else PATCH_LIST="$PATCH_LIST:$PWD/$patch_path"; fi
                print_success "Enabled: $optional_name"
            else
                print_status "Skipped: $optional_name"
            fi
        done
        shopt -u nullglob
    else
        print_warning "Patches directory '$PATCHES_DIR' not found. No patches loaded."
    fi
    
    if [ -n "$PATCH_LIST" ]; then PRELOAD_STR="LD_PRELOAD=\"$PATCH_LIST\""; fi

    # ==========================================================================
    # FINAL CONFIGURATIONS (MODE & SIZE) - MOVED TO END
    # ==========================================================================
    local BH_MODE_VAR=""
    # IMPORTANTE: Inicializamos las variables de tamaño como UNSET para asegurar Opción 1.
    local WORLD_SIZE_VARS="unset BH_MUL; unset BH_RAW"

    # Configurar World Mode si existe el parche
    if [ "$HAS_WORLD_MODE_PATCH" = true ]; then
        echo -e "\n${CYAN}>>> CONFIGURING WORLD MODE (change_world_mode.so)${NC}"
        echo -e "1) ${GREEN}Keep Current/Normal${NC}"
        echo -e "2) ${CYAN}Force Vanilla (Removes Custom Rules)${NC}"
        echo -e "3) ${RED}Force Expert${NC}"
        echo -e "4) ${MAGENTA}Convert to Custom Rules${NC}"
        echo -n "Select option [1]: "
        read wm_opt < /dev/tty
        
        case $wm_opt in
            2) BH_MODE_VAR="export BH_MODE='VANILLA'" ;;
            3) BH_MODE_VAR="export BH_MODE='EXPERT'" ;;
            4) BH_MODE_VAR="export BH_MODE='CUSTOM'" ;;
            *) BH_MODE_VAR="unset BH_MODE" ;;
        esac
    fi

    # Configurar World Size si existe el parche
    if [ "$HAS_WORLD_SIZE_PATCH" = true ]; then
        echo -e "\n${MAGENTA}>>> CONFIGURING WORLD SIZE (change_world_size.so)${NC}"
        echo -e "1) ${GREEN}Normal Size (Default)${NC}"
        echo -e "2) ${YELLOW}Custom Multiplier (e.g., 4x)${NC}"
        echo -e "3) ${RED}Exact Macro Count (Raw)${NC}"
        echo -n "Select world size option [1]: "
        read ws_opt < /dev/tty
        
        if [[ "$ws_opt" == "2" || "$ws_opt" == "3" ]]; then
            echo -e ""
            echo -e "${RED}╔══════════════════════════════════════════════════════════════════╗${NC}"
            echo -e "${RED}║                    ⚠️  CRITICAL WARNING  ⚠️                        ║${NC}"
            echo -e "${RED}╠══════════════════════════════════════════════════════════════════╣${NC}"
            echo -e "${RED}║ [!] EXISTING WORLDS:                                             ║${NC}"
            echo -e "${RED}║     Forcing size WILL CORRUPT the map (Cliffs, Broken Chunks).   ║${NC}"
            echo -e "${RED}║                                                                  ║${NC}"
            echo -e "${RED}║ [✓] NEW WORLDS:                                                  ║${NC}"
            echo -e "${RED}║     This patch is STABLE and SAFE for generating new maps.       ║${NC}"
            echo -e "${RED}╚══════════════════════════════════════════════════════════════════╝${NC}"
            echo -n -e "${YELLOW}Force size change? (y/N): ${NC}"
            read force_answer < /dev/tty
            
            if [[ "$force_answer" =~ ^[Yy]$ ]]; then
                case $ws_opt in
                    2)
                        echo -n "Enter multiplier (e.g. 4): "
                        read ws_mul < /dev/tty
                        WORLD_SIZE_VARS="export BH_MUL='$ws_mul'"
                        ;;
                    3)
                        echo -n "Enter raw macro count (e.g. 128): "
                        read ws_raw < /dev/tty
                        WORLD_SIZE_VARS="export BH_RAW='$ws_raw'"
                        ;;
                esac
            else
                # Usuario canceló o eligió opción 1 (implícitamente) -> Limpiamos vars
                WORLD_SIZE_VARS="unset BH_MUL; unset BH_RAW"
            fi
        else
            # Opción 1 seleccionada -> Limpiamos vars explícitamente
            WORLD_SIZE_VARS="unset BH_MUL; unset BH_RAW"
        fi
    fi
    # ==========================================================================

    local start_script=$(mktemp)
    cat > "$start_script" << EOF
#!/bin/bash
cd '$PWD'
export LD_LIBRARY_PATH="$LD_LIBRARY_PATH"
$BH_MODE_VAR
$WORLD_SIZE_VARS
while true; do
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Starting server..."
    $PRELOAD_STR ./blockheads_server171 -o '$world_id' -p $port 2>&1 | tee -a '$log_file'
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
    
    # --- LOGICA RANK MANAGER OPCIONAL ---
    if [[ "$use_rank_manager" =~ ^[Yy]$ ]]; then
        print_step "Starting Rank Manager..."
        local manager_script="./rank_manager.sh"
        
        if [ ! -f "$manager_script" ]; then
            print_error "Rank Manager script not found: $manager_script"
            print_warning "Stopping server screen to prevent partial startup."
            screen -S "$SCREEN_SERVER" -X quit 2>/dev/null
            return 1
        fi
        
        if [ ! -x "$manager_script" ]; then
            print_warning "Rank Manager script is not executable. Attempting to fix..."
            chmod +x "$manager_script"
            if [ ! -x "$manager_script" ]; then
                print_error "Failed to make rank manager script executable."
                print_warning "Stopping server screen to prevent partial startup."
                screen -S "$SCREEN_SERVER" -X quit 2>/dev/null
                return 1
            fi
        fi
        
        if ! screen -dmS "$SCREEN_MANAGER" bash -c "cd '$PWD' && ./rank_manager.sh '$port'"; then
            print_error "Failed to create rank manager screen session (command failed)."
            print_warning "Stopping server screen to prevent partial startup."
            screen -S "$SCREEN_SERVER" -X quit 2>/dev/null
            return 1
        fi
        
        print_step "Verifying rank manager status..."
        sleep 2
        
        if ! screen_session_exists "$SCREEN_MANAGER"; then
            print_error "Rank manager screen session terminated immediately."
            print_error "This likely means '$manager_script' failed on launch."
            print_error "Please check '$manager_script' for errors."
            print_warning "Stopping server screen to prevent partial startup."
            screen -S "$SCREEN_SERVER" -X quit 2>/dev/null
            return 1
        fi
        print_success "Rank manager screen session created: $SCREEN_MANAGER"
    else
        print_status "Rank Manager skipped by user."
    fi
    # -------------------------------------
    
    print_header "SERVER STARTED SUCCESSFULLY!"
    print_success "World: $world_id"
    print_success "Port: $port"
    
    if [ -n "$PATCH_LIST" ]; then
        print_status "Active Security Patches: $PATCH_LIST"
    else
        print_warning "No security patches loaded."
    fi

    echo ""
    print_status "To view server console: ${CYAN}screen -r $SCREEN_SERVER${NC}"
    if [[ "$use_rank_manager" =~ ^[Yy]$ ]]; then
        print_status "To view rank manager: ${CYAN}screen -r $SCREEN_MANAGER${NC}"
    fi
    echo ""
    print_warning "To exit console without stopping server: ${YELLOW}CTRL+A, D${NC}"
}

stop_server() {
    local port="$1"
    
    if [ -z "$port" ]; then
        print_header "STOPPING ALL SERVERS"
        
        for server_session in $(screen -list | grep "blockheads_server_" | awk -F. '{print $1}'); do
            screen -S "$server_session" -X quit 2>/dev/null
            print_success "Stopped server: $server_session"
        done
        
        for manager_session in $(screen -list | grep "blockheads_manager_" | awk -F. '{print $1}'); do
            screen -S "$manager_session" -X quit 2>/dev/null
            print_success "Stopped rank manager: $manager_session"
        done
        
        pkill -f "$SERVER_BINARY" 2>/dev/null || true
        
        rm -f world_id_*.txt 2>/dev/null || true
        
        print_success "All servers and rank managers stopped."
    else
        print_header "STOPPING SERVER ON PORT $port"
        
        local screen_server="blockheads_server_$port"
        local screen_manager="blockheads_manager_$port"
        
        if screen_session_exists "$screen_server"; then
            screen -S "$screen_server" -X quit 2>/dev/null
            print_success "Server stopped on port $port."
        else
            print_warning "Server was not running on port $port."
        fi
        
        if screen_session_exists "$screen_manager"; then
            screen -S "$screen_manager" -X quit 2>/dev/null
            print_success "Rank manager stopped on port $port."
        else
            print_status "Rank manager was not running on port $port (or already stopped)."
        fi
        
        pkill -f "$SERVER_BINARY.*$port" 2>/dev/null || true
        
        rm -f "world_id_$port.txt" 2>/dev/null || true
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
                
                if screen_session_exists "blockheads_manager_$server_port"; then
                    print_success "Rank manager on port $server_port: RUNNING"
                else
                    print_warning "Rank manager on port $server_port: STOPPED/NOT ENABLED"
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
        
        if screen_session_exists "blockheads_manager_$port"; then
            print_success "Rank manager: RUNNING"
        else
            print_warning "Rank manager: STOPPED/NOT ENABLED"
        fi
        
        if [ -f "world_id_$port.txt" ]; then
            local WORLD_ID=$(cat "world_id_$port.txt" 2>/dev/null)
            print_status "Current world: ${CYAN}$WORLD_ID${NC}"
            
            if screen_session_exists "blockheads_server_$port"; then
                print_status "To view console: ${CYAN}screen -r blockheads_server_$port${NC}"
                if screen_session_exists "blockheads_manager_$port"; then
                    print_status "To view rank manager: ${CYAN}screen -r blockheads_manager_$port${NC}"
                fi
            fi
        else
            print_warning "World: Not configured for port $port"
        fi
    fi
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
    echo -e " ${GREEN}start${NC} [WORLD_NAME] [PORT] - Start server with rank manager"
    echo -e " ${RED}stop${NC} [PORT] - Stop server and rank manager"
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
    install-deps)
        install_system_dependencies
        ;;
    help|--help|-h|*)
        show_usage
        ;;
esac
