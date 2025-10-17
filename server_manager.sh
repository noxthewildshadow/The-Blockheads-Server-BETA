#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

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
    local port="$1"
    print_warning "Freeing port $port..."

    local pids=$(lsof -ti ":$port")
    if [ -n "$pids" ]; then
        kill -9 $pids 2>/dev/null
    fi

    local screen_server="blockheads_server_$port"
    local screen_patcher="blockheads_patcher_$port"

    if screen_session_exists "$screen_server"; then
        screen -S "$screen_server" -X quit 2>/dev/null
    fi

    if screen_session_exists "$screen_patcher"; then
        screen -S "$screen_patcher" -X quit 2>/dev/null
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
    local port="$2"

    (
        sleep 5
        local world_dir="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves/$world_id"
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

    if screen_session_exists "$SCREEN_SERVER"; then
        screen -S "$SCREEN_SERVER" -X quit 2>/dev/null
    fi

    if screen_session_exists "$SCREEN_PATCHER"; then
        screen -S "$SCREEN_PATCHER" -X quit 2>/dev/null
    fi

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

    local start_script=$(mktemp)
    # --- Modificación Mínima: Usar 'script' para entrada/salida correcta ---
    # Esto es necesario para que puedas escribir comandos en la consola del server
    local loop_script="./run_server_loop_$port.sh"
    cat > "$start_script" << EOF
#!/bin/bash
cd '$PWD'
export LD_LIBRARY_PATH="$LD_LIBRARY_PATH"
# Usar 'script' para crear un pseudo-terminal
script -q -c "$loop_script '$world_id' '$port' '$log_file'" /dev/null
EOF

    cat > "$loop_script" << LOOP_EOF
#!/bin/bash
world_id="\$1"
port="\$2"
log_file="\$3"
while true; do
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Starting server..."
    # Ejecutar directamente
    if ./blockheads_server171 -o "\$world_id" -p \$port; then
        echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Server closed normally"
    else
        exit_code=\$?
        echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Server failed with code: \$exit_code"
        # Usar el log real para verificar puerto en uso
        if [ -f "\$log_file" ] && tail -n 5 "\$log_file" | grep -q "port.*already in use"; then
             echo "[\$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Port already in use. Will not retry."
             break
        fi
    fi
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Restarting in 5 seconds..."
    sleep 5
done
LOOP_EOF

    chmod +x "$start_script"
    chmod +x "$loop_script"

    # Usar screen -L para loggear la salida de 'script'
    if screen -L -Logfile "$log_file" -dmS "$SCREEN_SERVER" bash -c "exec $start_script"; then
        print_success "Server screen session created successfully"
        (sleep 10; rm -f "$start_script" "$loop_script") & # Limpiar ambos
    else
        print_error "Failed to create screen session for server"
        rm -f "$start_script" "$loop_script"
        return 1
    fi

    cleanup_server_lists "$world_id" "$port"

    print_step "Waiting for server to start..."

    local wait_time=0
    # Esperar a que el log exista y tenga contenido
    while [ ! -s "$log_file" ] && [ $wait_time -lt 20 ]; do
        sleep 1
        ((wait_time++))
    done

    if [ ! -s "$log_file" ]; then
        print_warning "Could not detect log file activity. Server may not have started."
        # No retornar error aquí, dejar que el usuario verifique
    fi

    local server_ready=false
    print_status "Checking server log for ready message (up to 30s)..."
    for i in {1..30}; do # Reducido tiempo de espera
        if [ -f "$log_file" ] && grep -q -E "World load complete|Server started|Ready for connections|using seed:|save delay:" "$log_file"; then
            server_ready=true
            break
        fi
        echo -n "."
        sleep 1
    done
    echo

    if [ "$server_ready" = false ]; then
        print_warning "Server ready message not detected in log."
        if ! screen_session_exists "$SCREEN_SERVER"; then
            print_error "Server screen session not found after timeout!"
            return 1
        fi
    else
        print_success "Server started successfully!"
    fi

    print_step "Starting rank patcher..."
    # Verificar si el script existe antes de intentar iniciarlo
    if [ -f "./rank_patcher.sh" ]; then
        if screen -dmS "$SCREEN_PATCHER" bash -c "cd '$PWD' && ./rank_patcher.sh '$port'"; then
            print_success "Rank patcher screen session created: $SCREEN_PATCHER"
        else
            print_warning "Failed to create rank patcher screen session"
        fi
    else
         print_warning "rank_patcher.sh not found. Skipping."
    fi

    local server_started=0
    local patcher_started=0

    if screen_session_exists "$SCREEN_SERVER"; then server_started=1; fi
    if screen_session_exists "$SCREEN_PATCHER"; then patcher_started=1; fi

    if [ "$server_started" -eq 1 ]; then # Solo mostrar éxito si el servidor principal está OK
        print_header "SERVER AND RANK PATCHER STARTED" # Título original
        print_success "World: $world_id"
        print_success "Port: $port"
        echo ""
        print_status "To view server console: ${CYAN}screen -r $SCREEN_SERVER${NC}"
        if [ "$patcher_started" -eq 1 ]; then
             print_status "To view rank patcher: ${CYAN}screen -r $SCREEN_PATCHER${NC}"
        else
             print_warning "Rank patcher session '$SCREEN_PATCHER' NOT found!"
        fi
        echo ""
        print_warning "To exit console without stopping server: ${YELLOW}CTRL+A, D${NC}"
    else
        print_error "Server session '$SCREEN_SERVER' failed to start correctly!"
        print_warning "Check log: $log_file"
    fi
}


stop_server() {
    local port="$1"

    if [ -z "$port" ]; then
        print_header "STOPPING ALL SERVERS"

        # Buscar y detener screens
        local sessions_to_stop=$(screen -list | grep -E "blockheads_(server|patcher)_" | awk '{print $1}')
        if [ -z "$sessions_to_stop" ]; then
            print_warning "No relevant screen sessions found."
        else
            for server_session in $sessions_to_stop; do
                 print_status "Stopping $server_session..."
                 screen -S "$server_session" -X quit 2>/dev/null
            done
            print_success "Sent stop command to relevant screen sessions."
        fi

        # Matar procesos residuales
        print_status "Killing residual processes..."
        pkill -f "$SERVER_BINARY" 2>/dev/null || true
        pkill -f "rank_patcher.sh" 2>/dev/null || true
        # Limpiar archivos temporales
        rm -f world_id_*.txt run_server_loop_*.sh 2>/dev/null || true

        print_success "All servers and rank patchers stopped."
    else
        print_header "STOPPING SERVER ON PORT $port"

        local screen_server="blockheads_server_$port"
        local screen_patcher="blockheads_patcher_$port"

        if screen_session_exists "$screen_server"; then
            print_status "Stopping server session: $screen_server"
            screen -S "$screen_server" -X quit 2>/dev/null
            print_success "Server stopped on port $port."
        else
            print_warning "Server was not running on port $port."
        fi

        if screen_session_exists "$screen_patcher"; then
             print_status "Stopping patcher session: $screen_patcher"
            screen -S "$screen_patcher" -X quit 2>/dev/null
            print_success "Rank patcher stopped on port $port."
        else
            print_warning "Rank patcher was not running on port $port."
        fi

        # Matar residuales específicos
        print_status "Killing residual processes for port $port..."
        pkill -f "$SERVER_BINARY.*-p $port" 2>/dev/null || true
        pkill -f "rank_patcher.sh '$port'" 2>/dev/null || true
        # Limpiar archivos específicos
        rm -f "world_id_$port.txt" "run_server_loop_$port.sh" 2>/dev/null || true
    fi
}

list_servers() {
    print_header "LIST OF RUNNING SERVERS (via screen)"

    # Buscar screens activas
    local running_screens=$(screen -list | grep -E "blockheads_(server|patcher)_")

    if [ -z "$running_screens" ]; then
        print_warning "No Blockheads screen sessions are currently running."
    else
        print_status "Currently running screen sessions:"
        # Formatear la salida
        echo "$running_screens" | awk '{
            session_name = $1;
            sub(/^[0-9]+\./, "", session_name); # Quitar PID si existe
            split(session_name, parts, "_");
            type = parts[2];
            port = parts[3];
            printf "  - Port: %-5s | Type: %-7s | Screen Name: %s\n", port, type, session_name;
        }' | sort -k3n # Ordenar por puerto

        echo ""
        print_status "Use 'screen -r <Screen Name>' to attach."
    fi
}

show_status() {
    local port="$1"

    if [ -z "$port" ]; then
        print_header "THE BLOCKHEADS SERVER STATUS - ALL CONFIGURED SERVERS"
        local configured_ports=$(ls world_id_*.txt 2>/dev/null | sed -n 's/world_id_\(.*\).txt/\1/p')

        if [ -z "$configured_ports" ]; then
            print_error "No servers configured (no world_id_*.txt files found)."
             # Mostrar screens activas aunque no haya configuración
            list_servers
            return
        fi

        local any_running=0
        for p in $configured_ports; do
            local world_id=$(cat "world_id_$p.txt" 2>/dev/null || echo "Unknown")
            local server_running="${RED}STOPPED${NC}"
            local patcher_running="${RED}STOPPED${NC}"

            if screen_session_exists "blockheads_server_$p"; then server_running="${GREEN}RUNNING${NC}"; any_running=1; fi
            if screen_session_exists "blockheads_patcher_$p"; then patcher_running="${GREEN}RUNNING${NC}"; any_running=1; fi

            echo "----------------------------------------"
            print_status "Port: ${YELLOW}$p${NC} (World: ${CYAN}$world_id${NC})"
            echo -e "  Server Status: $server_running"
            echo -e "  Patcher Status: $patcher_running"
        done
         echo "----------------------------------------"
         if [ "$any_running" -eq 0 ]; then
              print_warning "No configured servers seem to be running."
         fi
         # Comprobar screens huérfanas
         print_status "Checking for potentially orphaned screens..."
         list_servers

    else
        print_header "THE BLOCKHEADS SERVER STATUS - PORT $port"
        local server_running="${RED}STOPPED${NC}"
        local patcher_running="${RED}STOPPED${NC}"
        local world_id="Not configured via world_id file"
        local log_status="N/A"

        if screen_session_exists "blockheads_server_$port"; then server_running="${GREEN}RUNNING${NC}"; fi
        if screen_session_exists "blockheads_patcher_$port"; then patcher_running="${GREEN}RUNNING${NC}"; fi

        if [ -f "world_id_$port.txt" ]; then
            world_id=$(cat "world_id_$port.txt" 2>/dev/null)
            local log_file="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves/$world_id/console.log"
            if [ -f "$log_file" ]; then
                 # Mostrar tamaño del log
                 log_status="Exists (${CYAN}$(du -sh "$log_file" | cut -f1)${NC})"
            else
                log_status="${YELLOW}Not found${NC}"
            fi
        fi

        echo -e "  World: ${CYAN}$world_id${NC}"
        echo -e "  Server Status: $server_running"
        echo -e "  Patcher Status: $patcher_running"
        echo -e "  Console Log: $log_status"
        echo ""

        if [ "$server_running" != "${RED}STOPPED${NC}" ]; then
            print_status "View Server Console: ${CYAN}screen -r blockheads_server_$port${NC}"
        fi
         if [ "$patcher_running" != "${RED}STOPPED${NC}" ]; then
            print_status "View Rank Patcher:   ${CYAN}screen -r blockheads_patcher_$port${NC}"
        fi
         if [ "$world_id" != "Not configured via world_id file" ] && [ "$log_status" != "${YELLOW}Not found${NC}" ]; then
             print_status "View Server Log:     ${CYAN}tail -f $log_file${NC}"
         fi
    fi
}


install_system_dependencies() {
    print_header "INSTALLING SYSTEM DEPENDENCIES (Manual)"
    print_warning "This command requires root privileges (sudo)."
    # Comprobar si ya es root
    if [ "$EUID" -eq 0 ]; then
        print_error "Do not run '$0 install-deps' directly as root. Run the main installer.sh."
        return 1
    elif ! command -v sudo &> /dev/null; then
         print_error "'sudo' is required. Cannot proceed."
         return 1
    fi


    if command -v apt-get &> /dev/null; then
        print_step "Installing dependencies on Debian/Ubuntu..."
        sudo apt-get update
        # Usar la lista original del installer, excluyendo git/cmake/etc.
        sudo apt-get install -y screen binutils libdispatch-dev libobjc4 gnustep-base-runtime libc6 lsof inotify-tools patchelf
    elif command -v yum &> /dev/null; then
        print_step "Installing dependencies on RHEL/CentOS..."
        sudo yum install -y epel-release
        sudo yum install -y screen binutils libdispatch libobjc lsof inotify-tools patchelf
    elif command -v dnf &> /dev/null; then
        print_step "Installing dependencies on Fedora..."
        sudo dnf install -y epel-release # Puede no ser necesario
        sudo dnf install -y screen binutils libdispatch libobjc lsof inotify-tools patchelf
    elif command -v pacman &> /dev/null; then
        print_step "Installing dependencies on Arch Linux..."
        sudo pacman -Sy --noconfirm screen binutils libdispatch libobjc lsof inotify-tools patchelf
    else
        print_error "Cannot automatically install dependencies on this system."
        return 1
    fi

    print_success "Attempted to install system dependencies!"
    return 0
}

show_usage() {
    print_header "THE BLOCKHEADS SERVER MANAGER"
    print_status "Usage: $0 [command]"
    echo ""
    print_status "Available commands:"
    echo -e " ${GREEN}start${NC} [WORLD_NAME] [PORT] - Start server with rank patcher"
    echo -e " ${RED}stop${NC} [PORT]           - Stop server and rank patcher (all if no port)"
    echo -e " ${CYAN}status${NC} [PORT]         - Show server status (all configured if no port)"
    echo -e " ${YELLOW}list${NC}               - List all running server screen sessions"
    echo -e " ${MAGENTA}install-deps${NC}      - Manually install system dependencies (requires sudo)"
    echo -e " ${YELLOW}help${NC}               - Show this help"
    echo ""
    print_status "Examples:"
    echo -e " ${GREEN}$0 start MyWorld 12153${NC}"
    echo -e " ${GREEN}$0 start MyWorld${NC} (uses default port $DEFAULT_PORT)"
    echo -e " ${RED}$0 stop${NC}"
    echo -e " ${RED}$0 stop 12153${NC}"
    echo -e " ${CYAN}$0 status${NC}"
    echo -e " ${CYAN}$0 status 12153${NC}"
    echo -e " ${YELLOW}$0 list${NC}"
    echo -e " ${MAGENTA}sudo $0 install-deps${NC}" # Mostrar cómo se usaría
    echo ""
    print_warning "First create a world: ./blockheads_server171 -n"
    print_warning "After creating the world, press CTRL+C to exit"
}

# --- Manejador de Comandos ---
# Ejecutar como usuario normal
if [ "$EUID" -eq 0 ]; then
    # Permitir install-deps si se llama explícitamente como root
    if [ "$1" == "install-deps" ]; then
        install_system_dependencies
        exit $?
    else
        print_error "Do not run server_manager.sh as root (except for 'install-deps'). Run as your normal user."
        exit 1
    fi
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
         # Requerir sudo explícitamente si no se es root
         if ! command -v sudo &> /dev/null; then
             print_error "'sudo' is required to run install-deps."
             exit 1
         fi
         print_warning "This command requires root privileges. Running with sudo..."
         sudo "$0" install-deps_internal # Llamada interna como root
         ;;
    install-deps_internal) # Llamada interna ejecutada por sudo
         # Asegurarse de ser root ahora
         if [ "$EUID" -ne 0 ]; then
             print_error "Internal error: install-deps_internal called without root."
             exit 1
         fi
         install_system_dependencies
         ;;
    help|--help|-h|*)
        show_usage
        ;;
    *)
         print_error "Unknown command: $1"
         show_usage
         exit 1
         ;;
esac
