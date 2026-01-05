#!/bin/bash

# ==============================================================================
# THE BLOCKHEADS SERVER MANAGER - FIXED
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
    # PATCH DETECTION
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
    
    if [ -n "$PATCH_LIST" ]; then 
        PRELOAD_STR="LD_PRELOAD=\"$PATCH_LIST\"" 
    fi

    # ==========================================================================
    # CONFIGURATIONS (MODE & SIZE) - MOVED TO END
    # ==========================================================================
    local BH_MODE_VAR=""
    # IMPORTANTE: Inicializamos las variables de tamaño como UNSET para asegurar Opción 1.
    local WORLD_SIZE_VARS="unset BH_MUL; unset BH_RAW"

    if [ "$HAS_WORLD_MODE_PATCH" = true ]; then
        echo -e "\n${CYAN}>>> CONFIGURING WORLD MODE (change_world_mode.so)${NC}"
        echo -e "1) ${GREEN}Keep Current/Normal${NC}"
        echo -e "2) ${CYAN}Force Vanilla (Removes Custom Rules)${NC}"
        echo -e "3) ${RED}Force Expert${NC}"
        echo -e "4) ${MAGENTA}Convert to Custom Rules${NC}"
        echo -n "Select option [1]: "
        read m_opt < /dev/tty
        case $m_opt in
            2) BH_MODE_VAR="export BH_MODE='VANILLA'" ;;
            3) BH_MODE_VAR="export BH_MODE='EXPERT'" ;;
            4) BH_MODE_VAR="export BH_MODE='CUSTOM'" ;;
            *) BH_MODE_VAR="unset BH_MODE" ;;
        esac
    fi

    if [ "$HAS_WORLD_SIZE_PATCH" = true ]; then
        echo -e "\n${MAGENTA}>>> CONFIGURING WORLD SIZE (change_world_size.so)${NC}"
        echo -e "1) ${GREEN}Normal Size (Default / Respect Savefile)${NC}"
        echo -e "2) ${YELLOW}Custom Multiplier (e.g., 4x)${NC}"
        echo -e "3) ${RED}Exact Macro Count (Raw)${NC}"
        echo -n "Select option [1]: "
        read s_opt < /dev/tty
        
        if [[ "$s_opt" == "2" || "$s_opt" == "3" ]]; then
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
                case $s_opt in
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
                WORLD_SIZE_VARS="unset BH_MUL; unset BH_RAW"
            fi
        else
            # Opción 1: Unset explícito
            WORLD_SIZE_VARS="unset BH_MUL; unset BH_RAW"
        fi
    fi

    # Wrapper Script
    local start_script=$(mktemp)
    cat > "$start_script" << EOF
#!/bin/bash
cd '$PWD'
export LD_LIBRARY_PATH="$LD_LIBRARY_PATH"
$BH_MODE_VAR
$WORLD_SIZE_VARS
while true; do
    echo "[Run] Starting..."
    $PRELOAD_STR ./blockheads_server171 -o '$world_id' -p $port 2>&1 | tee -a '$log_file'
    echo "Restarting in 5s..."
    sleep 5
done
EOF
    chmod +x "$start_script"
    
    screen -dmS "$SCREEN_SERVER" bash -c "exec $start_script"
    (sleep 5; rm -f "$start_script"; cleanup_server_lists "$world_id") &
    
    print_step "Waiting for logs..."
    local w=0
    while [ ! -f "$log_file" ] && [ $w -lt 10 ]; do sleep 1; ((w++)); done
    
    if screen_session_exists "$SCREEN_SERVER"; then
        print_success "Server running."
    else
        print_error "Server failed."
        return 1
    fi
    
    if [[ "$use_rank_manager" =~ ^[Yy]$ ]]; then
        if [ -x "./rank_manager.sh" ]; then
            screen -dmS "$SCREEN_MANAGER" bash -c "cd '$PWD' && ./rank_manager.sh '$port'"
            print_success "Rank Manager running."
        fi
    fi
    
    print_header "SERVER STARTED SUCCESSFULLY!"
    print_success "World: $world_id"
    print_success "Port: $port"
    if [ -n "$PATCH_LIST" ]; then print_status "Patches Active."; fi
    echo ""
    print_status "Console: screen -r $SCREEN_SERVER"
    echo ""
}

stop_server() {
    if [ -z "$1" ]; then
        for s in $(screen -list | grep "blockheads_" | awk -F. '{print $1}'); do screen -S "$s" -X quit; done
        pkill -f "$SERVER_BINARY"; rm -f world_id_*.txt
        print_success "Stopped all."
    else
        free_port "$1"
        rm -f "world_id_$1.txt"
        print_success "Stopped port $1."
    fi
}

install_deps() {
    if command -v apt-get &> /dev/null; then
        sudo apt-get update && sudo apt-get install -y screen binutils libdispatch-dev libobjc4 gnustep-base-runtime libc6
    else
        print_error "Manual install required."
    fi
}

case "$1" in
    start) [ -z "$2" ] && exit 1; start_server "$2" "$3" ;;
    stop) stop_server "$2" ;;
    status|list) screen -list | grep "blockheads_" ;;
    install-deps) install_deps ;;
    *) echo "Usage: $0 {start|stop|status|install-deps}" ;;
esac
