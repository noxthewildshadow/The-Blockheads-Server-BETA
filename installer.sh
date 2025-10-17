#!/bin/bash
# Este script DEBE ejecutarse como root (con sudo)
set -e

# --- Colores ---
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

# --- Funciones de Impresión ---
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

# --- Comprobación de Root ---
if [ "$EUID" -ne 0 ]; then
    print_error "This script requires root privileges. Please run with: sudo $0"
    exit 1
fi

# --- Encontrar el usuario original que ejecutó sudo ---
ORIGINAL_USER=${SUDO_USER:-$USER}
USER_HOME=$(getent passwd "$ORIGINAL_USER" | cut -d: -f6)
[ -z "$USER_HOME" ] && USER_HOME="/home/$ORIGINAL_USER" # Fallback

# --- URLs y Archivos ---
SERVER_URL="https://web.archive.org/web/20240309015235if_/https://majicdave.com/share/blockheads_server171.tar.gz"
TEMP_FILE="/tmp/blockheads_server171.tar.gz"
SERVER_BINARY="blockheads_server171"

RANK_PATCHER_URL="https://raw.githubusercontent.com/noxthewildshadow/The-Blockheads-Server-BETA/main/rank_patcher.sh"

# --- Listas de Paquetes (con ngrep añadido) ---
declare -a PACKAGES_DEBIAN=(
    'git' 'cmake' 'ninja-build' 'clang' 'patchelf' 'libgnustep-base-dev' 'libobjc4' 
    'libgnutls28-dev' 'libgcrypt20-dev' 'libxml2' 'libffi-dev' 'libnsl-dev' 'zlib1g' 
    'libicu-dev' 'libstdc++6' 'libgcc-s1' 'wget' 'curl' 'tar' 'grep' 'screen' 'lsof'
    'inotify-tools' 'ngrep' 'binutils'
)

declare -a PACKAGES_ARCH=(
    'base-devel' 'git' 'cmake' 'ninja' 'clang' 'patchelf' 'gnustep-base' 'gcc-libs' 
    'gnutls' 'libgcrypt' 'libxml2' 'libffi' 'libnsl' 'zlib' 'icu' 'libdispatch' 
    'wget' 'curl' 'tar' 'grep' 'screen' 'lsof' 'inotify-tools' 'ngrep' 'binutils'
)

print_header "THE BLOCKHEADS LINUX SERVER INSTALLER (AUTOMATED)"
echo -e "${CYAN}Welcome! This script will install the server, dependencies, and${NC}"
echo -e "${CYAN}the custom server manager with an INTERACTIVE packet sniffer.${NC}"
echo

# --- Funciones de Instalación ---

find_library() {
    local SEARCH=$1
    local LIBRARY=$(ldconfig -p | grep -F "$SEARCH" -m 1 | awk '{print $NF}' | head -1)
    [ -z "$LIBRARY" ] && return 1
    printf '%s' "$LIBRARY"
}

install_packages() {
    [ ! -f /etc/os-release ] && print_error "Could not detect the operating system" && return 1
    
    source /etc/os-release
    
    print_progress "Updating package lists..."
    case $ID in
        debian|ubuntu|pop)
            if ! apt-get update >/dev/null 2>&1; then
                print_error "Failed to update package list"
                return 1
            fi
            
            print_step "Installing packages for Debian/Ubuntu..."
            for package in "${PACKAGES_DEBIAN[@]}"; do
                if ! apt-get install -y "$package" >/dev/null 2>&1; then
                    print_warning "Failed to install $package"
                else
                    print_progress "Installed $package"
                fi
            done
            ;;
        arch)
            print_step "Installing packages for Arch Linux..."
            if ! pacman -Sy --noconfirm --needed "${PACKAGES_ARCH[@]}" >/dev/null 2>&1; then
                print_error "Failed to install Arch Linux packages"
                return 1
            fi
            ;;
        *)
            print_error "Unsupported operating system: $ID"
            return 1
            ;;
    esac
    
    return 0
}

# --- MODIFICADO: Esta función AHORA CREA el server_manager.sh ---
create_and_download_scripts() {
    print_step "Downloading rank patcher..."
    if wget --timeout=30 --tries=3 -O "rank_patcher.sh" "$RANK_PATCHER_URL" 2>/dev/null; then
        chmod +x "rank_patcher.sh"
        print_success "Rank patcher downloaded successfully"
    else
        print_error "Failed to download rank patcher"
        return 1
    fi
    
    print_step "Creating custom server_manager.sh (interactive sniffer)..."
    
    # --- INICIO: server_manager.sh EMBEBIDO ---
    cat > "server_manager.sh" << 'EOF_MANAGER'
#!/bin/bash

# --- Colores para la salida ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

# --- Funciones de Impresión ---
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

# --- Variables Globales ---
SERVER_BINARY="./blockheads_server171"
DEFAULT_PORT=12153

# --- Función para instalar dependencias de librerías ---
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
                    libdispatch.so.0)
                        sudo apt-get install -y libdispatch-dev || sudo apt-get install -y libdispatch0
                        ;;
                    libobjc.so.4)
                        sudo apt-get install -y libobjc4
                        ;;
                    libgnustep-base.so.1.28)
                        sudo apt-get install -y gnustep-base-runtime
                        ;;
                    libpthread.so.0|libc.so.6|libm.so.6|libdl.so.2)
                        sudo apt-get install -y libc6
                        ;;
                    *)
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
                        sudo yum install -y libdispatch || sudo yum install -y libdispatch-devel
                        ;;
                    libobjc.so.4)
                        sudo yum install -y libobjc
                        ;;
                esac
            done
        elif command -v dnf &> /dev/null; then
            print_step "Installing dependencies on Fedora..."
            sudo dnf install -y epel-release
            for lib in $missing_libs; do
                case "$lib" in
                    libdispatch.so.0)
                        sudo dnf install -y libdispatch || sudo dnf install -y libdispatch-devel
                        ;;
                    libobjc.so.4)
                        sudo dnf install -y libobjc
                        ;;
                esac
            done
        elif command -v pacman &> /dev/null; then
            print_step "Installing dependencies on Arch Linux..."
            for lib in $missing_libs; do
                case "$lib" in
                    libdispatch.so.0)
                        sudo pacman -Sy --noconfirm libdispatch
                        ;;
                    libobjc.so.4)
                        sudo pacman -Sy --noconfirm libobjc
                        ;;
                esac
            done
        fi
    fi
    
    return 0
}

# --- Función para chequear librerías ---
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
        if ! install_dependencies; then
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
        fi
    fi
    
    return 0
}

# --- Funciones de Utilidad ---
screen_session_exists() {
    screen -list | grep -q "$1"
}

is_port_in_use() {
    lsof -Pi ":$1" -sTCP:LISTEN -t >/dev/null 2>&1
}

check_world_exists() {
    # El script del instalador guarda todo en el directorio actual,
    # pero el binario del servidor guarda los mundos en el $HOME del USUARIO.
    # Debemos encontrar el $HOME del usuario que corre el script (no root)
    local ORIGINAL_USER_HOME=$(getent passwd "${SUDO_USER:-$USER}" | cut -d: -f6)
    [ -z "$ORIGINAL_USER_HOME" ] && ORIGINAL_USER_HOME="/home/${SUDO_USER:-$USER}"
    
    local world_id="$1"
    local saves_dir="$ORIGINAL_USER_HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves"
    
    if [ ! -d "$saves_dir/$world_id" ]; then
        print_error "World '$world_id' does not exist in: $saves_dir/"
        echo ""
        print_warning "To create a world: ${GREEN}./blockheads_server171 -n${NC}"
        print_warning "After creating the world, press ${YELLOW}CTRL+C${NC} to exit"
        return 1
    fi
    
    return 0
}

# --- Función para liberar puerto (modificada para sniffer) ---
free_port() {
    local port="$1"
    print_warning "Freeing port $port..."
    
    local pids=$(lsof -ti ":$port" 2>/dev/null)
    if [ -n "$pids" ]; then
        kill -9 $pids 2>/dev/null
    fi
    
    local screen_server="blockheads_server_$port"
    local screen_patcher="blockheads_patcher_$port"
    local screen_sniffer="blockheads_sniffer_$port" # <-- AÑADIDO
    
    if screen_session_exists "$screen_server"; then
        screen -S "$screen_server" -X quit 2>/dev/null
    fi
    
    if screen_session_exists "$screen_patcher"; then
        screen -S "$screen_patcher" -X quit 2>/dev/null
    fi

    if screen_session_exists "$screen_sniffer"; then # <-- AÑADIDO
        screen -S "$screen_sniffer" -X quit 2>/dev/null
    fi
    
    sleep 2
    if is_port_in_use "$port"; then
        return 1
    else
        return 0
    fi
}

cleanup_server_lists() {
    local ORIGINAL_USER_HOME=$(getent passwd "${SUDO_USER:-$USER}" | cut -d: -f6)
    [ -z "$ORIGINAL_USER_HOME" ] && ORIGINAL_USER_HOME="/home/${SUDO_USER:-$USER}"

    local world_id="$1"
    local port="$2"
    
    (
        sleep 5
        local world_dir="$ORIGINAL_USER_HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves/$world_id"
        local admin_list="$world_dir/adminlist.txt"
        local mod_list="$world_dir/modlist.txt"
        
        if [ -f "$admin_list" ]; then
            rm -f "$admin_list"
        fi
        
        if [ -f "$mod_list" ]; then
            rm -f "$mod_list"
        fi
    ) &
}

# --- Función para iniciar (modificada para sniffer) ---
start_server() {
    local world_id="$1"
    local port="${2:-$DEFAULT_PORT}"
    
    # Nombres de las 3 sesiones de screen
    local SCREEN_SERVER="blockheads_server_$port"
    local SCREEN_PATCHER="blockheads_patcher_$port"
    local SCREEN_SNIFFER="blockheads_sniffer_$port" # <-- AÑADIDO
    
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
    
    # Limpieza de sesiones anteriores
    if screen_session_exists "$SCREEN_SERVER"; then
        screen -S "$SCREEN_SERVER" -X quit 2>/dev/null
    fi
    if screen_session_exists "$SCREEN_PATCHER"; then
        screen -S "$SCREEN_PATCHER" -X quit 2>/dev/null
    fi
    if screen_session_exists "$SCREEN_SNIFFER"; then # <-- AÑADIDO
        screen -S "$SCREEN_SNIFFER" -X quit 2>/dev/null
    fi
    
    sleep 1
    
    # Definición de archivos de log
    local ORIGINAL_USER_HOME=$(getent passwd "${SUDO_USER:-$USER}" | cut -d: -f6)
    [ -z "$ORIGINAL_USER_HOME" ] && ORIGINAL_USER_HOME="/home/${SUDO_USER:-$USER}"
    local log_dir="$ORIGINAL_USER_HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves/$world_id"
    local log_file="$log_dir/console.log"
    # --- packet_log_file ya no es necesario ---
    mkdir -p "$log_dir"
    # Asegurarse de que el usuario original sea el propietario
    chown -R "${SUDO_USER:-$USER}:${SUDO_USER:-$USER}" "$ORIGINAL_USER_HOME/GNUstep" 2>/dev/null || true
    
    print_header "STARTING SERVER - WORLD: $world_id, PORT: $port"
    
    echo "$world_id" > "world_id_$port.txt"
    
    print_step "Starting server in screen session: $SCREEN_SERVER"
    
    if ! command -v screen >/dev/null 2>&1; then
        print_error "Screen command not found. Please install screen."
        return 1
    fi
    
    # Script temporal para el bucle de reinicio del servidor
    local start_script=$(mktemp)
    cat > "$start_script" << EOF
#!/bin/bash
cd '$PWD'
export LD_LIBRARY_PATH="$LD_LIBRARY_PATH"
while true; do
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Starting server..."
    # Ejecutar el servidor como el usuario original, no como root
    if sudo -u "${SUDO_USER:-$USER}" ./blockheads_server171 -o '$world_id' -p $port 2>&1 | tee -a '$log_file'; then
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
    
    chmod +x "$start_script"
    
    # Iniciar servidor
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
    else
        print_success "Server started successfully!"
    fi
    
    # Iniciar Patcher (como usuario original)
    print_step "Starting rank patcher..."
    if screen -dmS "$SCREEN_PATCHER" bash -c "cd '$PWD' && sudo -u '${SUDO_USER:-$USER}' ./rank_patcher.sh '$port'"; then
        print_success "Rank patcher screen session created: $SCREEN_PATCHER"
    else
        print_warning "Failed to create rank patcher screen session"
    fi

    # --- INICIO: BLOQUE MODIFICADO PARA SNIFFER INTERACTIVO ---
    print_step "Starting packet sniffer (interactive)..."
    if ! command -v ngrep >/dev/null 2>&1; then
        print_error "ngrep command not found. Cannot start sniffer."
        print_warning "Run '${YELLOW}$0 install-deps${NC}' to install ngrep."
    else
        # Inicia ngrep interactivamente dentro de la screen. No se usará -q (quiet)
        # No se redirige a un archivo.
        if screen -dmS "$SCREEN_SNIFFER" bash -c "sudo ngrep -d any -W byline port $port"; then
            print_success "Packet sniffer screen session created: $SCREEN_SNIFFER"
            print_status "Packets will be visible in: ${CYAN}screen -r $SCREEN_SNIFFER${NC}"
        else
            print_error "Failed to create packet sniffer screen session."
            print_warning "This script should have configured passwordless sudo, but it might have failed."
        fi
    fi
    # --- FIN: BLOQUE MODIFICADO ---
    
    local server_started=0
    local patcher_started=0
    local sniffer_started=0 # <-- AÑADIDO
    
    if screen_session_exists "$SCREEN_SERVER"; then server_started=1; fi
    if screen_session_exists "$SCREEN_PATCHER"; then patcher_started=1; fi
    if screen_session_exists "$SCREEN_SNIFFER"; then sniffer_started=1; fi
    
    if [ "$server_started" -eq 1 ] && [ "$patcher_started" -eq 1 ]; then
        print_header "SERVER, PATCHER, AND SNIFFER STARTED!"
        print_success "World: $world_id"
        print_success "Port: $port"
        echo ""
        print_status "To view server console: ${CYAN}screen -r $SCREEN_SERVER${NC}"
        print_status "To view rank patcher: ${CYAN}screen -r $SCREEN_PATCHER${NC}"
        if [ "$sniffer_started" -eq 1 ]; then # <-- AÑADIDO
            print_status "To view packet sniffer: ${CYAN}screen -r $SCREEN_SNIFFER${NC}"
        fi
        echo ""
        print_warning "To exit console without stopping server: ${YELLOW}CTRL+A, D${NC}"
    fi
}

# --- Función para detener (modificada para sniffer) ---
stop_server() {
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
        
        for sniffer_session in $(screen -list | grep "blockheads_sniffer_" | awk -F. '{print $1}'); do # <-- AÑADIDO
            screen -S "$sniffer_session" -X quit 2>/dev/null
            print_success "Stopped packet sniffer: $sniffer_session"
        done
        
        pkill -f "$SERVER_BINARY" 2>/dev/null || true
        
        rm -f world_id_*.txt 2>/dev/null || true
        
        print_success "All servers, rank patchers, and sniffers stopped."
    else
        print_header "STOPPING SERVER ON PORT $port"
        
        local screen_server="blockheads_server_$port"
        local screen_patcher="blockheads_patcher_$port"
        local screen_sniffer="blockheads_sniffer_$port" # <-- AÑADIDO
        
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
        
        if screen_session_exists "$screen_sniffer"; then # <-- AÑADIDO
            screen -S "$screen_sniffer" -X quit 2>/dev/null
            print_success "Packet sniffer stopped on port $port."
        else
            print_warning "Packet sniffer was not running on port $port."
        fi
        
        pkill -f "$SERVER_BINARY.*$port" 2>/dev/null || true
        
        rm -f "world_id_$port.txt" 2>/dev/null || true
    fi
}

# --- Función de listar ---
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

# --- Función de estado (modificada para sniffer) ---
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
                
                if screen_session_exists "blockheads_sniffer_$server_port"; then # <-- AÑADIDO
                    print_success "Packet Sniffer on port $server_port: RUNNING"
                else
                    print_error "Packet Sniffer on port $server_port: STOPPED"
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
        
        if screen_session_exists "blockheads_sniffer_$port"; then # <-- AÑADIDO
            print_success "Packet Sniffer: RUNNING"
        else
            print_error "Packet Sniffer: STOPPED"
        fi
        
        if [ -f "world_id_$port.txt" ]; then
            local WORLD_ID=$(cat "world_id_$port.txt" 2>/dev/null)
            print_status "Current world: ${CYAN}$WORLD_ID${NC}"
            
            if screen_session_exists "blockheads_server_$port"; then
                print_status "To view console: ${CYAN}screen -r blockheads_server_$port${NC}"
                print_status "To view rank patcher: ${CYAN}screen -r blockheads_patcher_$port${NC}"
                print_status "To view packet sniffer: ${CYAN}screen -r blockheads_sniffer_$port${NC}" # <-- AÑADIDO
            fi
        else
            print_warning "World: Not configured for port $port"
        fi
    fi
}

# --- Función de instalación de dependencias (modificada para ngrep) ---
install_system_dependencies() {
    print_header "INSTALLING SYSTEM DEPENDENCIES"
    
    if ! command -v sudo &> /dev/null; then
        print_error "sudo command not found. This script requires sudo to install packages."
        return 1
    fi

    if command -v apt-get &> /dev/null; then
        print_step "Installing dependencies on Debian/Ubuntu..."
        sudo apt-get update
        sudo apt-get install -y screen binutils libdispatch-dev libobjc4 gnustep-base-runtime libc6 ngrep # <-- ngrep AÑADIDO
    elif command -v yum &> /dev/null; then
        print_step "Installing dependencies on RHEL/CentOS..."
        sudo yum install -y epel-release
        sudo yum install -y screen binutils libdispatch libobjc ngrep # <-- ngrep AÑADIDO
    elif command -v dnf &> /dev/null; then
        print_step "Installing dependencies on Fedora..."
        sudo dnf install -y epel-release
        sudo dnf install -y screen binutils libdispatch libobjc ngrep # <-- ngrep AÑADIDO
    elif command -v pacman &> /dev/null; then
        print_step "Installing dependencies on Arch Linux..."
        sudo pacman -Sy --noconfirm screen binutils libdispatch libobjc ngrep # <-- ngrep AÑADIDO
    else
        print_error "Cannot automatically install dependencies on this system."
        return 1
    fi
    
    print_success "System dependencies installed successfully!"
    print_warning "Don't forget to configure ${YELLOW}passwordless sudo${NC} for ngrep if the installer fails to do so."
    return 0
}

# --- Función de Ayuda ---
show_usage() {
    print_header "THE BLOCKHEADS SERVER MANAGER"
    print_status "Usage: $0 [command]"
    echo ""
    print_status "Available commands:"
    echo -e " ${GREEN}start${NC} [WORLD_NAME] [PORT] - Start server with rank patcher & sniffer"
    echo -e " ${RED}stop${NC} [PORT] - Stop server, rank patcher & sniffer"
    echo -e " ${CYAN}status${NC} [PORT] - Show server status (includes sniffer)"
    echo -e " ${YELLOW}list${NC} - List all running servers"
    echo -e " ${MAGENTA}install-deps${NC} - Install system dependencies (includes ngrep)"
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

# --- Manejador de Comandos ---
# Este script está diseñado para ser CREADO por el instalador,
# por lo que el usuario final lo ejecutará con comandos como 'start', 'stop', etc.
# Si el script se ejecuta sin argumentos, muestra la ayuda.
if [ $# -eq 0 ]; then
    show_usage
    exit 0
fi

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
    *)
        show_usage
        ;;
esac
EOF_MANAGER
    # --- FIN: server_manager.sh EMBEBIDO ---
    
    chmod +x "server_manager.sh"
    print_success "Custom server_manager.sh (with sniffer) created successfully."
    return 0
}

# ---
# --- COMIENZO DEL SCRIPT DE INSTALACIÓN
# ---

print_step "[1/8] Installing required packages (ngrep included)..."
if ! install_packages; then
    print_warning "Falling back to basic package installation..."
    if ! apt-get update -y >/dev/null 2>&1; then
        print_error "Failed to update package list"
        exit 1
    fi
    
    if ! apt-get install -y libgnustep-base1.28 libdispatch-dev patchelf wget curl tar screen lsof inotify-tools ngrep binutils >/dev/null 2>&1; then
        print_error "Failed to install essential packages"
        exit 1
    fi
fi
print_success "Core dependencies installed."

print_step "[2/8] Configuring passwordless sudo for sniffer..."
if ! command -v ngrep &> /dev/null; then
    print_warning "ngrep command not found. Skipping sudo configuration."
else
    NGREP_PATH=$(which ngrep)
    SUDOERS_FILE="/etc/sudoers.d/blockheads_sniffer"
    
    print_progress "Creating sudoers rule for $ORIGINAL_USER at $NGREP_PATH..."
    
    # Crear el archivo de regla de sudo
    echo "$ORIGINAL_USER ALL=(ALL) NOPASSWD: $NGREP_PATH" > "$SUDOERS_FILE"
    
    # Establecer permisos correctos
    chmod 440 "$SUDOERS_FILE"
    
    # Validar con visudo
    if visudo -c -f "$SUDOERS_FILE" >/dev/null 2>&1; then
        print_success "Passwordless sudo for ngrep configured successfully."
    else
        print_error "Failed to validate sudoers file. Removing."
        rm -f "$SUDOERS_FILE"
        print_warning "You will need to run 'sudo visudo' manually."
    fi
fi


print_step "[3/8] Downloading server archive from archive.org..."
print_progress "Downloading server binary (this may take a moment)..."
if wget --timeout=30 --tries=3 --show-progress "$SERVER_URL" -O "$TEMP_FILE" 2>/dev/null; then
    print_success "Download successful from archive.org"
else
    print_error "Failed to download server file from archive.org"
    exit 1
fi

print_step "[4/8] Extracting files..."
EXTRACT_DIR="/tmp/blockheads_extract_$$"
mkdir -p "$EXTRACT_DIR"

print_progress "Extracting server files..."
if ! tar -xzf "$TEMP_FILE" -C "$EXTRACT_DIR" >/dev/null 2>&1; then
    print_error "Failed to extract server files"
    rm -rf "$EXTRACT_DIR"
    exit 1
fi

cp -r "$EXTRACT_DIR"/* ./
rm -rf "$EXTRACT_DIR"

if [ ! -f "$SERVER_BINARY" ]; then
    ALTERNATIVE_BINARY=$(find . -name "*blockheads*" -type f -executable | head -n 1)
    [ -n "$ALTERNATIVE_BINARY" ] && mv "$ALTERNATIVE_BINARY" "blockheads_server171" && SERVER_BINARY="blockheads_server171"
fi

if [ ! -f "$SERVER_BINARY" ]; then
    print_error "Server binary not found after extraction"
    exit 1
fi

chmod +x "$SERVER_BINARY"

print_step "[5/8] Applying comprehensive patchelf compatibility patches..."
declare -A LIBS=(
    ["libgnustep-base.so.1.24"]="$(find_library 'libgnustep-base.so' || echo 'libgnustep-base.so.1.28')"
    ["libobjc.so.4.6"]="$(find_library 'libobjc.so' || echo 'libobjc.so.4')"
    ["libgnutls.so.26"]="$(find_library 'libgnutls.so' || echo 'libgnutls.so.30')"
    ["libgcrypt.so.11"]="$(find_library 'libgcrypt.so' || echo 'libgcrypt.so.20')"
    ["libffi.so.6"]="$(find_library 'libffi.so' || echo 'libffi.so.8')"
    ["libicui18n.so.48"]="$(find_library 'libicui18n.so' || echo 'libicui18n.so.70')"
    ["libicuuc.so.48"]="$(find_library 'libicuuc.so' || echo 'libicuuc.so.70')"
    ["libicudata.so.48"]="$(find_library 'libicudata.so' || echo 'libicudata.so.70')"
    ["libdispatch.so"]="$(find_library 'libdispatch.so' || echo 'libdispatch.so.0')"
)

TOTAL_LIBS=${#LIBS[@]}
COUNT=0

for LIB in "${!LIBS[@]}"; do
    [ -z "${LIBS[$LIB]}" ] && continue
    COUNT=$((COUNT+1))
    
    if ! patchelf --replace-needed "$LIB" "${LIBS[$LIB]}" "$SERVER_BINARY" >/dev/null 2>&1; then
        print_warning "Failed to patch $LIB"
    fi
done

print_success "Compatibility patches applied ($COUNT/$TOTAL_LIBS libraries)"

print_step "[6/8] Testing server binary..."
# Ejecutar la prueba como el usuario original
if sudo -u "$ORIGINAL_USER" ./blockheads_server171 -h >/dev/null 2>&1; then
    print_success "Server binary test passed"
else
    print_warning "Server binary execution test failed - may need additional dependencies"
fi

print_step "[7/8] Creating custom server manager and downloading rank patcher..."
if ! create_and_download_scripts; then
    print_error "Failed to create/download helper scripts. Aborting."
    exit 1
fi

print_step "[8/8] Setting ownership and permissions..."
chown -R "$ORIGINAL_USER:$ORIGINAL_USER" . 2>/dev/null || true
chmod 755 "$SERVER_BINARY" "server_manager.sh" "rank_patcher.sh" 2>/dev/null || true

rm -f "$TEMP_FILE"

print_header "INSTALLATION COMPLETE"
echo -e "${GREEN}Server, patcher, and sniffer-manager installed!${NC}"
echo ""

print_header "SERVER BINARY INFORMATION"
echo ""
sudo -u "$ORIGINAL_USER" ./blockheads_server171 -h
echo ""
print_header "SERVER MANAGER INSTRUCTIONS"
print_warning "¡IMPORTANTE! Ejecuta los siguientes comandos como tu usuario normal, NO como root."
print_warning "Puedes salir de root ahora escribiendo: ${YELLOW}exit${NC}"
echo ""
echo -e "${GREEN}1. Create a world: ${CYAN}./blockheads_server171 -n${NC}"
print_warning "After creating the world, press CTRL+C to exit the creation process"
echo -e "${GREEN}2. See world list: ${CYAN}./blockheads_server171 -l${NC}"
echo -e "${GREEN}3. Start server: ${CYAN}./server_manager.sh start WORLD_ID YOUR_PORT${NC}"
echo -e "   (This will now also start an INTERACTIVE packet sniffer)"
echo -e "${GREEN}4. Stop server: ${CYAN}./server_manager.sh stop${NC}"
echo -e "${GREEN}5. Check status: ${CYAN}./server_manager.sh status${NC}"
echo ""

print_header "MULTI-SERVER SUPPORT"
echo -e "${GREEN}You can run multiple servers simultaneously:${NC}"
echo -e "${CYAN}./server_manager.sh start WorldID1 12153${NC}"
echo -e "${CYAN}./server_manager.sh start WorldID2 12154${NC}"
echo ""
echo -e "${YELLOW}Each server runs in its own screen session with its own patcher and sniffer.${NC}"

print_header "INSTALLATION COMPLETE"
echo -e "${GREEN}Your Blockheads server with rank management and packet sniffer is ready!${NC}"
