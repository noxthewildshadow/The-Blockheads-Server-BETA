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
SAVES_DIR="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves"

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

screen_session_exists() {
    screen -list | grep -q "\.$1"
}

is_port_in_use() {
    lsof -Pi ":$1" -sTCP:LISTEN -t >/dev/null 2>&1
}

check_world_exists() {
    local world_id="$1"
    
    if [ ! -d "$SAVES_DIR/$world_id" ]; then
        print_error "World '$world_id' does not exist in: $SAVES_DIR/"
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
    if [ -n "$pids" ]; then
        kill -9 $pids 2>/dev/null
    fi
    
    local screen_server="blockheads_server_$port"
    local screen_patcher="blockheads_patcher_$port"
    local screen_restore="blockheads_restore_$port" # Añadido para el monitor de restauración
    
    if screen_session_exists "$screen_server"; then
        screen -S "$screen_server" -X quit 2>/dev/null
    fi
    
    if screen_session_exists "$screen_patcher"; then
        screen -S "$screen_patcher" -X quit 2>/dev/null
    fi

    if screen_session_exists "$screen_restore"; then # Añadido
        screen -S "$screen_restore" -X quit 2>/dev/null
    fi
    
    sleep 2
    if is_port_in_use "$port"; then
        return 1
    else
        return 0
    fi
}

cleanup_server_lists() {
    local world_id="$1"
    
    print_step "Cleaning up old admin/mod lists for $world_id..."
    local world_dir="$SAVES_DIR/$world_id"
    local admin_list="$world_dir/adminlist.txt"
    local mod_list="$world_dir/modlist.txt"
    
    if [ -f "$admin_list" ]; then
        rm -f "$admin_list"
        print_status "Removed old adminlist.txt"
    fi
    
    if [ -f "$mod_list" ]; then
        rm -f "$mod_list"
        print_status "Removed old modlist.txt"
    fi
}

# ##################################################################
# ### NUEVA FUNCIÓN DE RESTAURACIÓN ###
# ##################################################################
run_restore_monitor() {
    local world_id="$1"
    local port="$2"
    local restore_seconds="$3"
    local world_dir="$SAVES_DIR/$world_id"
    local backup_dir="/tmp/BH_BACKUP_${world_id}_${port}"
    local log_file="$world_dir/console.log"
    local screen_server="blockheads_server_$port"
    local player_has_joined=0
    local three_min_timer_pid=""

    print_header "STARTING RESTORE MONITOR"
    print_status "World: $world_id"
    print_status "Port: $port"
    print_status "Interval: $restore_seconds seconds"
    print_status "Backup Dir: $backup_dir"
    print_status "Log File: $log_file"
    print_status "Monitoring for connections..."

    if ! command -v inotifywait &> /dev/null; then
        print_error "inotify-tools (inotifywait) is not installed. Restore monitor cannot run."
        print_error "Please run: sudo apt-get install inotify-tools"
        return 1
    fi

    # Asegurarse de que el log exista (el servidor tarda en crearlo)
    while [ ! -f "$log_file" ]; do
        sleep 1
    done

    # Bucle principal de monitoreo
    tail -n 0 -F "$log_file" | while read -r line; do
        
        # Trigger 2: Si un jugador se conecta, iniciar timer de 3 minutos
        if [[ "$line" =~ "Player Connected" ]]; then
            print_status "RESTORE: Player Connected. Starting 3-minute kick timer."
            player_has_joined=1
            
            # Iniciar temporizador de 3 minutos (180s)
            (
                sleep 180
                print_warning "RESTORE: 3-minute limit reached. Forcing server stop and restore."
                # Matar el servidor
                if screen_session_exists "$screen_server"; then
                    screen -S "$screen_server" -X quit 2>/dev/null
                fi
                # La restauración ocurrirá en el bucle 'while true' de start_server
            ) &
            three_min_timer_pid=$!
        fi

        # Trigger 1: Si un jugador se desconecta Y un jugador había entrado
        if [[ "$line" =~ "Player Disconnected" ]] && [ $player_has_joined -eq 1 ]; then
            print_status "RESTORE: Player Disconnected."
            
            # Cancelar el timer de 3 minutos si estaba activo
            if [ -n "$three_min_timer_pid" ]; then
                if kill -0 "$three_min_timer_pid" 2>/dev/null; then
                    kill "$three_min_timer_pid" 2>/dev/null
                    print_status "RESTORE: 3-minute timer cancelled."
                fi
                three_min_timer_pid=""
            fi

            print_status "RESTORE: Waiting $restore_seconds seconds to restore..."
            sleep "$restore_seconds"
            
            print_warning "RESTORE: Time's up. Forcing server stop and restore."
            # Matar el servidor
            if screen_session_exists "$screen_server"; then
                screen -S "$screen_server" -X quit 2>/dev/null
            fi
            # La restauración ocurrirá en el bucle 'while true' de start_server
            
            # Resetear la marca para el próximo ciclo
            player_has_joined=0
        fi
    done
}

# ##################################################################
# ### FUNCIÓN START MODIFICADA ###
# ##################################################################
start_server() {
    local world_id="$1"
    local port="${2:-$DEFAULT_PORT}"
    local restore_mode=0
    local restore_seconds=0

    # Detectar modo /restore
    if [ "$3" = "/restore" ] && [ -n "$4" ]; then
        if [[ "$4" =~ ^[0-9]+$ ]] && [ "$4" -gt 0 ]; then
            restore_mode=1
            restore_seconds="$4"
            print_warning "RESTORE MODE ACTIVATED: World will restore every $restore_seconds seconds."
        else
            print_error "Invalid seconds for /restore. Must be a number greater than 0."
            return 1
        fi
    fi
    
    local SCREEN_SERVER="blockheads_server_$port"
    local SCREEN_PATCHER="blockheads_patcher_$port"
    local SCREEN_RESTORE="blockheads_restore_$port" # Nueva sesión
    
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
    
    if screen_session_exists "$SCREEN_SERVER"; then
        screen -S "$SCREEN_SERVER" -X quit 2>/dev/null
    fi
    
    if screen_session_exists "$SCREEN_PATCHER"; then
        screen -S "$SCREEN_PATCHER" -X quit 2>/dev/null
    fi

    if screen_session_exists "$SCREEN_RESTORE"; then
        screen -S "$SCREEN_RESTORE" -X quit 2>/dev/null
    fi
    
    # [MODIFICADO] Solo limpiar listas si NO estamos en modo restore
    if [ $restore_mode -eq 0 ]; then
        cleanup_server_lists "$world_id"
    else
        print_warning "RESTORE MODE: Skipping admin/mod list cleanup."
    fi
    
    sleep 1
    
    local log_dir="$SAVES_DIR/$world_id"
    local log_file="$log_dir/console.log"
    mkdir -p "$log_dir"
    
    # --- Lógica de Backup para /restore ---
    local backup_dir="/tmp/BH_BACKUP_${world_id}_${port}"
    if [ $restore_mode -eq 1 ]; then
        print_header "CREATING WORLD BACKUP FOR RESTORE"
        if [ -d "$backup_dir" ]; then
            print_step "Removing old backup directory..."
            rm -rf "$backup_dir"
        fi
        mkdir -p "$backup_dir"
        print_step "Copying world data to $backup_dir..."
        if cp -a "$log_dir/." "$backup_dir/"; then
            print_success "World backup created successfully."
        else
            print_error "Failed to create world backup. Aborting."
            return 1
        fi
    fi

    print_header "STARTING SERVER - WORLD: $world_id, PORT: $port"
    
    echo "$world_id" > "world_id_$port.txt"
    
    print_step "Starting server in screen session: $SCREEN_SERVER"
    
    if ! command -v screen >/dev/null 2>&1; then
        print_error "Screen command not found. Please install screen."
        return 1
    fi
    
    local start_script=$(mktemp)
    
    # [MODIFICADO] El script de inicio ahora tiene lógica de restauración
    if [ $restore_mode -eq 1 ]; then
        # Bucle para modo RESTORE
        cat > "$start_script" << EOF
#!/bin/bash
cd '$PWD'
export LD_LIBRARY_PATH="$LD_LIBRARY_PATH"
while true; do
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] (RESTORE) Starting server..."
    if ./blockheads_server171 -o '$world_id' -p $port 2>&1 | tee -a '$log_file'; then
        echo "[\$(date '+%Y-%m-%d %H:%M:%S')] (RESTORE) Server closed normally"
    else
        exit_code=\$?
        echo "[\$(date '+%Y-%m-%d %H:%M:%S')] (RESTORE) Server failed with code: \$exit_code"
    fi
    
    # --- LÓGICA DE RESTAURACIÓN ---
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] (RESTORE) Server stopped. Restoring world from backup..."
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] (RESTORE) Removing current world data..."
    rm -rf "$log_dir"/*
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] (RESTORE) Copying backup data from $backup_dir..."
    cp -a "$backup_dir/." "$log_dir/"
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] (RESTORE) Restoration complete."
    # --- FIN LÓGICA ---
    
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] (RESTORE) Restarting in 5 seconds..."
    sleep 5
done
EOF
    else
        # Bucle normal (con rank patcher)
        cat > "$start_script" << EOF
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
    fi
    
    chmod +x "$start_script"
    
    if screen -dmS "$SCREEN_SERVER" bash -c "exec $start_script"; then
        print_success "Server screen session created successfully"
        (sleep 10; rm -f "$start_script") &
    else
        print_error "Failed to create screen session for server"
        rm -f "$start_script"
        return 1
    fi
    
    print_step "Waiting for server to start..."
    
    local wait_time=0
    while [ ! -f "$log_file" ] && [ $wait_time -lt 15 ]; do
        sleep 1
        ((wait_time++))
    done
    
    if [ ! -f "$log_file" ]; then
        print_error "Could not create log file. Server may not have started."
        if ! screen_session_exists "$SCREEN_SERVER"; then
            print_error "Server screen session not found. Startup failed."
            return 1
        fi
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
        print_warning "Server log file did not confirm startup within 30s."
        if ! screen_session_exists "$SCREEN_SERVER"; then
            print_error "Server screen session '$SCREEN_SERVER' is NOT running. Server failed to start."
            print_error "Check the log file for details: $log_file"
            return 1
        else
            print_warning "Screen session is running, but readiness not confirmed. Proceeding anyway..."
        fi
    else
        print_success "Server started successfully and confirmed ready!"
    fi
    
    print_step "Verifying server screen session before starting monitor/patcher..."
    if ! screen_session_exists "$SCREEN_SERVER"; then
        print_error "Server screen '$SCREEN_SERVER' is not running. Cannot start monitor/patcher."
        print_error "El servidor falló al arrancar. Revisa el log: $log_file"
        return 1
    fi
    
    # [MODIFICADO] Iniciar el patcher O el monitor de restauración
    if [ $restore_mode -eq 1 ]; then
        print_step "Starting restore monitor..."

        # [CORRECCIÓN] Exportar TODAS las funciones necesarias, incluida run_restore_monitor
        local functions_to_export=$(declare -f print_header print_status print_warning print_error screen_session_exists run_restore_monitor)

        if screen -dmS "$SCREEN_RESTORE" bash -c "$functions_to_export; run_restore_monitor '$world_id' '$port' '$restore_seconds'"; then
            print_success "Restore monitor screen session created: $SCREEN_RESTORE"
        else
            print_warning "Failed to create restore monitor screen session"
        fi
    else
        print_step "Starting rank patcher..."
        if screen -dmS "$SCREEN_PATCHER" bash -c "cd '$PWD' && ./rank_patcher.sh '$port'"; then
            print_success "Rank patcher screen session created: $SCREEN_PATCHER"
        else
            print_warning "Failed to create rank patcher screen session"
        fi
    fi

    # --- Resumen Final ---
    local server_started=0
    local monitor_started=0
    
    if screen_session_exists "$SCREEN_SERVER"; then
        server_started=1
    fi
    
    if [ $restore_mode -eq 1 ]; then
        if screen_session_exists "$SCREEN_RESTORE"; then
            monitor_started=1
        fi
    else
        if screen_session_exists "$SCREEN_PATCHER"; then
            monitor_started=1
        fi
    fi

    if [ "$server_started" -eq 1 ] && [ "$monitor_started" -eq 1 ]; then
        if [ $restore_mode -eq 1 ]; then
            print_header "SERVER (RESTORE MODE) STARTED SUCCESSFULLY!"
            print_success "World: $world_id"
            print_success "Port: $port"
            print_warning "Rank Patcher: DISABLED (Restore Mode)"
            echo ""
            print_status "To view server console: ${CYAN}screen -r $SCREEN_SERVER${NC}"
            print_status "To view restore monitor: ${CYAN}screen -r $SCREEN_RESTORE${NC}"
        else
            print_header "SERVER AND RANK PATCHER STARTED SUCCESSFULLY!"
            print_success "World: $world_id"
            print_success "Port: $port"
            echo ""
            print_status "To view server console: ${CYAN}screen -r $SCREEN_SERVER${NC}"
            print_status "To view rank patchto: ${CYAN}screen -r $SCREEN_PATCHER${NC}"
        fi
        echo ""
        print_warning "To exit console without stopping server: ${YELLOW}CTRL+A, D${NC}"
    fi
}

stop_server() {
    local port="$1"
    
    if [ -z "$port" ]; then
        print_header "STOPPING ALL SERVERS"
        
        for server_session in $(screen -list | grep "blockheads_server_" | awk -F' ' '{print $1}' | cut -d. -f2); do
            screen -S "$server_session" -X quit 2>/dev/null
            print_success "Stopped server: $server_session"
        done
        
        for patcher_session in $(screen -list | grep "blockheads_patcher_" | awk -F' ' '{print $1}' | cut -d. -f2); do
            screen -S "$patcher_session" -X quit 2>/dev/null
            print_success "Stopped rank patcher: $patcher_session"
        done

        for restore_session in $(screen -list | grep "blockheads_restore_" | awk -F' ' '{print $1}' | cut -d. -f2); do
            screen -S "$restore_session" -X quit 2>/dev/null
            print_success "Stopped restore monitor: $restore_session"
        done
        
        pkill -f "$SERVER_BINARY" 2>/dev/null || true
        
        rm -f world_id_*.txt 2>/dev/null || true
        rm -rf /tmp/BH_BACKUP_* 2>/dev/null || true # Limpiar backups
        
        print_success "All servers, patchers, and monitors stopped. Backups cleaned."
    else
        print_header "STOPPING SERVER ON PORT $port"
        
        local screen_server="blockheads_server_$port"
        local screen_patcher="blockheads_patcher_$port"
        local screen_restore="blockheads_restore_$port"
        
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

        if screen_session_exists "$screen_restore"; then
            screen -S "$screen_restore" -X quit 2>/dev/null
            print_success "Restore monitor stopped on port $port."
        else
            print_warning "Restore monitor was not running on port $port."
        fi
        
        pkill -f "$SERVER_BINARY.*$port" 2>/dev/null || true
        
        rm -f "world_id_$port.txt" 2>/dev/null || true
        rm -rf "/tmp/BH_BACKUP_${port}" 2>/dev/null || true # Limpiar backup específico
    fi
}

list_servers() {
    print_header "LIST OF RUNNING SERVERS"
    
    local servers=$(screen -list | grep "blockheads_server_" | awk -F' ' '{print $1}' | cut -d. -f2 | sed 's/blockheads_server_/ - Port: /')
    
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
        
        local servers=$(screen -list | grep "blockheads_server_" | awk -F' ' '{print $1}' | cut -d. -f2 | sed 's/blockheads_server_//')
        
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
                elif screen_session_exists "blockheads_restore_$server_port"; then
                     print_warning "Restore Monitor on port $server_port: RUNNING (Rank Patcher DISABLED)"
                else
                    print_error "Rank patcher/monitor on port $server_port: STOPPED"
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
        elif screen_session_exists "blockheads_restore_$port"; then
            print_warning "Restore Monitor: RUNNING (Rank Patcher DISABLED)"
        else
            print_error "Rank patcher/monitor: STOPPED"
        fi
        
        if [ -f "world_id_$port.txt" ]; then
            local WORLD_ID=$(cat "world_id_$port.txt" 2>/dev/null)
            print_status "Current world: ${CYAN}$WORLD_ID${NC}"
            
            if screen_session_exists "blockheads_server_$port"; then
                print_status "To view console: ${CYAN}screen -r blockheads_server_$port${NC}"
                if screen_session_exists "blockheads_patcher_$port"; then
                    print_status "To view rank patcher: ${CYAN}screen -r blockheads_patcher_$port${NC}"
                elif screen_session_exists "blockheads_restore_$port"; then
                    print_status "To view restore monitor: ${CYAN}screen -r blockheads_restore_$port${NC}"
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
        # [MODIFICADO] Añadido inotify-tools
        sudo apt-get install -y screen binutils libdispatch-dev libobjc4 gnustep-base-runtime libc6 inotify-tools
    elif command -v yum &> /dev/null; then
        print_step "Installing dependencies on RHEL/CentOS..."
        sudo yum install -y epel-release
        sudo yum install -y screen binutils libdispatch libobjc inotify-tools
    elif command -v dnf &> /dev/null; then
        print_step "Installing dependencies on Fedora..."
        sudo dnf install -y epel-release
        sudo dnf install -y screen binutils libdispatch libobjc inotify-tools
    elif command -v pacman &> /dev/null; then
        print_step "Installing dependencies on Arch Linux..."
        sudo pacman -Sy --noconfirm screen binutils libdispatch libobjc inotify-tools
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
    echo -e " ${GREEN}start${NC} [WORLD_NAME] [PORT] - Start server with rank patcher"
    echo -e " ${GREEN}start${NC} [WORLD_NAME] [PORT] ${YELLOW}/restore [SECONDS]${NC} - Start server in restore mode"
    echo -e " ${RED}stop${NC} [PORT] - Stop server and rank patcher/monitor"
    echo -e " ${CYAN}status${NC} [PORT] - Show server status"
    echo -e " ${YELLOW}list${NC} - List all running servers"
    echo -e " ${MAGENTA}install-deps${NC} - Install system dependencies (includes inotify-tools)"
    echo -e " ${YELLOW}help${NC} - Show this help"
    echo ""
    print_status "Examples:"
    echo -e " ${GREEN}$0 start MyWorld 12153${NC}"
    echo -e " ${GREEN}$0 start MyWorld${NC} (uses default port 12153)"
    echo -e " ${GREEN}$0 start MyRestoreWorld 12154 /restore 30${NC} (Restores 30s after empty)"
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
        # Pasa todos los argumentos ($2, $3, $4, $5) a start_server
        start_server "$2" "$3" "$4" "$5"
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
