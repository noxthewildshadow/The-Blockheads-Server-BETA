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

# --- Función para instalar dependencias (Simplificada, ya que debería hacerlo el installer.sh) ---
install_dependencies() {
    print_warning "Dependency installation should be handled by installer.sh"
    print_status "Checking for ldd..."
    if ! command -v ldd &> /dev/null; then
         print_error "ldd not found. Please run the main installer script or install 'binutils'."
         return 1
    fi
    # Podrías añadir comprobaciones básicas de librerías aquí si es necesario
    return 0
}

check_and_fix_libraries() {
    print_header "CHECKING SYSTEM LIBRARIES"

    if [ ! -f "$SERVER_BINARY" ]; then
        print_error "Server binary not found: $SERVER_BINARY"
        return 1
    fi

    if ! command -v ldd &> /dev/null; then
        print_error "ldd command not found. Please install binutils via installer."
        return 1
    fi

    print_step "Checking library dependencies for $SERVER_BINARY..."

    # Solo advertir, no intentar instalar
    local lib_error=$(ldd "$SERVER_BINARY" 2>&1 | grep -i "not found\|cannot open")
    if [ -n "$lib_error" ]; then
        print_warning "Missing libraries detected by ldd:"
        echo "$lib_error"
        print_warning "Please run the main installer script or install dependencies manually."
        # Intentar establecer LD_LIBRARY_PATH como fallback
        local lib_paths=""
         if [ -d "/usr/lib/x86_64-linux-gnu" ]; then lib_paths="/usr/lib/x86_64-linux-gnu:$lib_paths"; fi
         if [ -d "/usr/lib64" ]; then lib_paths="/usr/lib64:$lib_paths"; fi
         if [ -d "/usr/lib" ]; then lib_paths="/usr/lib:$lib_paths"; fi
         if [ -d "/lib/x86_64-linux-gnu" ]; then lib_paths="/lib/x86_64-linux-gnu:$lib_paths"; fi
         if [ -d "/lib64" ]; then lib_paths="/lib64:$lib_paths"; fi
         if [ -d "/lib" ]; then lib_paths="/lib:$lib_paths"; fi
         export LD_LIBRARY_PATH="${lib_paths%/}:${LD_LIBRARY_PATH}" # Quitar ':' final si existe
         print_status "Attempting to set LD_LIBRARY_PATH=$LD_LIBRARY_PATH"
    fi

    return 0
}

screen_session_exists() {
    screen -list | grep -q "\.$1\s" # Buscar nombre exacto con punto y espacio
}

is_port_in_use() {
    lsof -Pi ":$1" -sTCP:LISTEN -t >/dev/null 2>&1
}

check_world_exists() {
    local world_id="$1"
    # Usar $HOME directamente, este script corre como usuario normal
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
    print_warning "Attempting to free port $port..."

    local pids=$(lsof -ti ":$port" -sTCP:LISTEN 2>/dev/null)
    if [ -n "$pids" ]; then
        print_warning "Killing processes listening on port $port: $pids"
        kill -9 $pids 2>/dev/null || print_error "Failed to kill processes $pids"
    fi

    # Buscar screens asociadas al puerto y cerrarlas
    local screen_server="blockheads_server_$port"
    local screen_patcher="blockheads_patcher_$port"

    if screen_session_exists "$screen_server"; then
        print_warning "Closing screen session: $screen_server"
        screen -S "$screen_server" -X quit 2>/dev/null || print_error "Failed to close screen $screen_server"
    fi

    if screen_session_exists "$screen_patcher"; then
        print_warning "Closing screen session: $screen_patcher"
        screen -S "$screen_patcher" -X quit 2>/dev/null || print_error "Failed to close screen $screen_patcher"
    fi

    sleep 1 # Dar tiempo a que los procesos terminen

    # Verificar si el puerto sigue en uso
    if is_port_in_use "$port"; then
        print_error "Could not free port $port. Manual intervention might be needed."
        return 1
    else
        print_success "Port $port seems free now."
        return 0
    fi
}


cleanup_server_lists() {
    local world_id="$1"
    local port="$2" # Port no usado aquí pero mantenido por consistencia

    (
        sleep 5 # Esperar a que el servidor cree los archivos si es necesario
        local world_dir="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves/$world_id"
        local admin_list="$world_dir/adminlist.txt"
        local mod_list="$world_dir/modlist.txt"

        print_status "Checking for admin/mod lists to clean up in $world_dir..."
        if [ -f "$admin_list" ]; then
            print_warning "Removing existing adminlist.txt"
            rm -f "$admin_list"
        fi

        if [ -f "$mod_list" ]; then
            print_warning "Removing existing modlist.txt"
            rm -f "$mod_list"
        fi
    ) & # Ejecutar en segundo plano
}

start_server() {
    local world_id="$1"
    local port="${2:-$DEFAULT_PORT}"

    local SCREEN_SERVER="blockheads_server_$port"
    local SCREEN_PATCHER="blockheads_patcher_$port"

    if [ ! -f "$SERVER_BINARY" ]; then
        print_error "Server binary not found: $SERVER_BINARY"
        print_warning "Please run the installer script first."
        return 1
    fi

    # Comprobar librerías al inicio
    if ! check_and_fix_libraries; then
        print_warning "Library check failed or reported issues. Server might not start."
        # No salir, intentar continuar
    fi

    if ! check_world_exists "$world_id"; then
        return 1
    fi

    if is_port_in_use "$port"; then
        print_warning "Port $port is in use."
        read -p "Do you want to attempt to free it? (y/N): " -n 1 -r REPLY
        echo # Mover a nueva línea
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            if ! free_port "$port"; then
                return 1
            fi
        else
            print_error "Port $port is occupied. Aborting."
            return 1
        fi
    fi

    # Limpiar sesiones screen previas si existen
    if screen_session_exists "$SCREEN_SERVER"; then
        print_warning "Terminating existing screen session: $SCREEN_SERVER"
        screen -S "$SCREEN_SERVER" -X quit 2>/dev/null
    fi
    if screen_session_exists "$SCREEN_PATCHER"; then
         print_warning "Terminating existing screen session: $SCREEN_PATCHER"
        screen -S "$SCREEN_PATCHER" -X quit 2>/dev/null
    fi
    sleep 1 # Pequeña pausa

    # Configurar logs
    local log_dir="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves/$world_id"
    local log_file="$log_dir/console.log"
    mkdir -p "$log_dir"
    # Asegurar permisos correctos en el directorio GNUstep
    chown -R "$USER:$USER" "$HOME/GNUstep" 2>/dev/null || true

    print_header "STARTING SERVER - WORLD: $world_id, PORT: $port"

    # Guardar ID del mundo asociado al puerto
    echo "$world_id" > "world_id_$port.txt"

    print_step "Starting server in screen session: $SCREEN_SERVER"

    if ! command -v screen >/dev/null 2>&1; then
        print_error "Screen command not found. Please install screen (via installer)."
        return 1
    fi

    # Script temporal para el bucle de reinicio
    local start_script=$(mktemp)
    local loop_script="./run_server_loop_$port.sh" # Script de loop por puerto
    cat > "$start_script" << EOF
#!/bin/bash
cd '$PWD'
export LD_LIBRARY_PATH="$LD_LIBRARY_PATH"
# Usar 'script' para simular TTY
script -q -c "$loop_script '$world_id' '$port' '$log_file'" /dev/null
EOF

    cat > "$loop_script" << LOOP_EOF
#!/bin/bash
world_id="\$1"
port="\$2"
log_file="\$3"
while true; do
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Starting server $world_id on port $port..." >> "\$log_file" # Loggear inicio
    # Ejecutar binario directamente, 'script' captura la salida
    if ./$SERVER_BINARY -o "\$world_id" -p \$port; then
        echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Server closed normally" >> "\$log_file"
    else
        exit_code=\$?
        echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Server failed with code: \$exit_code" >> "\$log_file"
        # Comprobar causa del fallo en el log
        if [ -f "\$log_file" ] && tail -n 5 "\$log_file" | grep -q "port.*already in use"; then
             echo "[\$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Port already in use. Will not retry." >> "\$log_file"
             break # Salir del bucle si el puerto está en uso
        fi
    fi
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Restarting in 5 seconds..." >> "\$log_file"
    sleep 5
done
LOOP_EOF

    chmod +x "$start_script"
    chmod +x "$loop_script"

    # Iniciar screen usando screen -L para loggear
    # Usar el nombre de archivo directamente con -Logfile
    if screen -L -Logfile "$log_file" -dmS "$SCREEN_SERVER" bash -c "exec $start_script"; then
        print_success "Server screen session '$SCREEN_SERVER' created successfully."
        # Limpiar scripts temporales en segundo plano
        (sleep 10; rm -f "$start_script" "$loop_script") &
    else
        print_error "Failed to create screen session for server"
        rm -f "$start_script" "$loop_script"
        return 1
    fi

    # Limpiar listas de admin/mod
    cleanup_server_lists "$world_id" "$port"

    print_step "Waiting for server to fully start..."

    local wait_time=0
    # Esperar a que el log file se cree por 'screen -L'
    while [ ! -s "$log_file" ] && [ $wait_time -lt 20 ]; do # Esperar a que no esté vacío
        print_status "Waiting for log file ($log_file) to be created/populated... ($wait_time/20)"
        sleep 1
        ((wait_time++))
    done

    if [ ! -s "$log_file" ]; then
        print_warning "Log file ($log_file) not created or is empty after 20 seconds. Server might have failed."
        # No retornar error necesariamente, podría estar tardando mucho
    fi

    local server_ready=false
    print_status "Checking server log ($log_file) for ready message (up to 45s)..."
    for i in {1..45}; do
         # Asegurarse de que el archivo exista antes de hacer grep
         if [ -f "$log_file" ] && grep -q -E "World load complete|Server started|Ready for connections|using seed:|save delay:" "$log_file"; then
            server_ready=true
            break
         fi
         echo -n "." # Mostrar progreso
         sleep 1
    done
    echo # Nueva línea después de los puntos

    if [ "$server_ready" = false ]; then
        print_warning "Server ready message not detected in log after 45 seconds."
        if ! screen_session_exists "$SCREEN_SERVER"; then
            print_error "Server screen session '$SCREEN_SERVER' not found. Startup likely failed."
            print_warning "Check the log file: $log_file"
            return 1
        fi
         print_warning "Proceeding anyway, but check server status and log manually."
    else
        print_success "Server seems to have started successfully!"
    fi

    # Iniciar Rank Patcher si existe
    if [ -f "./rank_patcher.sh" ]; then
        print_step "Starting rank patcher in screen session: $SCREEN_PATCHER"
        if screen -dmS "$SCREEN_PATCHER" bash -c "cd '$PWD' && ./rank_patcher.sh '$port'"; then
            print_success "Rank patcher screen session '$SCREEN_PATCHER' created."
        else
            print_warning "Failed to create screen session for rank patcher."
        fi
    else
        print_warning "rank_patcher.sh not found. Skipping."
    fi

    # Comprobación final
    local server_started=0
    local patcher_started=0
    if screen_session_exists "$SCREEN_SERVER"; then server_started=1; fi
    if screen_session_exists "$SCREEN_PATCHER"; then patcher_started=1; fi

    print_header "STARTUP COMPLETE"
    print_success "World: $world_id / Port: $port"
    echo ""
    if [ "$server_started" -eq 1 ]; then
        print_status "To view server console: ${CYAN}screen -r $SCREEN_SERVER${NC}"
    else
         print_error "Server session '$SCREEN_SERVER' NOT found!"
    fi
     if [ "$patcher_started" -eq 1 ]; then
        print_status "To view rank patcher:   ${CYAN}screen -r $SCREEN_PATCHER${NC}"
    else
         print_warning "Rank patcher session '$SCREEN_PATCHER' NOT found!"
    fi
    echo ""
    print_warning "To exit console without stopping server: ${YELLOW}CTRL+A, D${NC}"

}

stop_server() {
    local port="$1"

    if [ -z "$port" ]; then
        print_header "STOPPING ALL SERVERS"
        local stopped_count=0
        # Buscar todas las screens relevantes
        local sessions_to_stop=$(screen -list | grep -E "blockheads_(server|patcher)_" | awk '{print $1}')
        if [ -z "$sessions_to_stop" ]; then
            print_warning "No relevant screen sessions found to stop."
        else
            for session in $sessions_to_stop; do
                 print_status "Stopping session: $session"
                 screen -S "$session" -X quit 2>/dev/null
                 ((stopped_count++))
            done
            print_success "Sent stop command to $stopped_count screen sessions."
        fi

        # Matar procesos residuales por nombre
        print_status "Killing residual processes..."
        pkill -f "$SERVER_BINARY" 2>/dev/null || true
        pkill -f "rank_patcher.sh" 2>/dev/null || true
        # Limpiar archivos de loop y world_id
        rm -f world_id_*.txt run_server_loop_*.sh 2>/dev/null || true

        print_success "All known servers and rank patchers stopped."
    else
        print_header "STOPPING SERVER ON PORT $port"

        local screen_server="blockheads_server_$port"
        local screen_patcher="blockheads_patcher_$port"
        local server_stopped=0
        local patcher_stopped=0

        if screen_session_exists "$screen_server"; then
            print_status "Stopping server session: $screen_server"
            screen -S "$screen_server" -X quit 2>/dev/null
            server_stopped=1
        else
            print_warning "Server session was not running on port $port."
        fi

        if screen_session_exists "$screen_patcher"; then
            print_status "Stopping patcher session: $screen_patcher"
            screen -S "$screen_patcher" -X quit 2>/dev/null
            patcher_stopped=1
        else
            print_warning "Rank patcher session was not running on port $port."
        fi

        # Matar procesos residuales específicamente para este puerto
        print_status "Killing residual processes for port $port..."
        pkill -f "$SERVER_BINARY.*-p $port" 2>/dev/null || true
        pkill -f "rank_patcher.sh '$port'" 2>/dev/null || true

        # Limpiar archivos específicos del puerto
        rm -f "world_id_$port.txt" "run_server_loop_$port.sh" 2>/dev/null || true

        if [ "$server_stopped" -eq 1 ] || [ "$patcher_stopped" -eq 1 ]; then
             print_success "Stopped services for port $port."
        fi
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
            sub(/^\s*[0-9]+\./, "", session_name); # Quitar PID inicial si existe
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
            # Comprobar si hay screens huérfanas de todas formas
            list_servers # Reutilizar list_servers para mostrar screens activas
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
         # Mostrar screens huérfanas
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

# --- Función de instalación de dependencias (Sólo llamada manual) ---
install_system_dependencies() {
    print_header "MANUAL SYSTEM DEPENDENCY INSTALLATION"
    print_warning "This command should ideally be run via the main installer.sh."
    print_warning "It requires root privileges (sudo)."

    if [ "$EUID" -eq 0 ]; then
         print_error "Do not run '$0 install-deps' directly as root. Run the main installer.sh instead."
         return 1
    elif ! command -v sudo &> /dev/null; then
        print_error "'sudo' command not found. Cannot install dependencies."
        return 1
    fi

    if command -v apt-get &> /dev/null; then
        print_step "Installing dependencies on Debian/Ubuntu..."
        sudo apt-get update
        sudo apt-get install -y screen binutils libdispatch-dev libobjc4 gnustep-base-runtime libc6 lsof inotify-tools patchelf # Quitado ngrep si no se usa
    elif command -v yum &> /dev/null; then
        print_step "Installing dependencies on RHEL/CentOS..."
        sudo yum install -y epel-release
        sudo yum install -y screen binutils libdispatch libobjc lsof inotify-tools patchelf
    elif command -v dnf &> /dev/null; then
        print_step "Installing dependencies on Fedora..."
        sudo dnf install -y epel-release # Puede no ser necesario en Fedora moderno
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
    # echo -e " ${MAGENTA}install-deps${NC}      - Manually install system dependencies (requires sudo)" # Ocultado o quitar si no se quiere
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
    # echo -e " ${MAGENTA}sudo $0 install-deps${NC}"
    echo ""
    print_warning "First create a world: ./blockheads_server171 -n"
    print_warning "After creating the world, press CTRL+C to exit"
}

# --- Manejador de Comandos ---
# Ejecutar como usuario normal
if [ "$EUID" -eq 0 ]; then
    print_error "Do not run server_manager.sh as root. Run it as your normal user."
    exit 1
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
        # install_system_dependencies # Ocultar o quitar si no se quiere que sea público
        print_warning "'install-deps' should be run via the main installer.sh"
        print_status "If needed manually, run: sudo $0 install-deps_confirm" # Ejemplo de comando oculto
        ;;
    install-deps_confirm) # Ejemplo de comando "oculto"
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
