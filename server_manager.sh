#!/bin/bash
# Este script se ejecuta como un USUARIO NORMAL (ej: fer)
# NO ejecutar con sudo

# --- Colores ---
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

# --- Funciones de Utilidad ---
screen_session_exists() {
    screen -list | grep -q "$1"
}

is_port_in_use() {
    lsof -Pi ":$1" -sTCP:LISTEN -t >/dev/null 2>&1
}

# --- Usa $HOME directamente ---
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

# --- Función para liberar puerto ---
free_port() {
    local port="$1"
    print_warning "Freeing port $port..."

    local pids=$(lsof -ti ":$port" 2>/dev/null)
    if [ -n "$pids" ]; then
        kill -9 $pids 2>/dev/null
    fi

    local screen_server="blockheads_server_$port"
    local screen_patcher="blockheads_patcher_$port"
    local screen_sniffer="blockheads_sniffer_$port"

    if screen_session_exists "$screen_server"; then
        screen -S "$screen_server" -X quit 2>/dev/null
    fi

    if screen_session_exists "$screen_patcher"; then
        screen -S "$screen_patcher" -X quit 2>/dev/null
    fi

    if screen_session_exists "$screen_sniffer"; then
        screen -S "$screen_sniffer" -X quit 2>/dev/null
    fi

    sleep 2
    if is_port_in_use "$port"; then
        return 1
    else
        return 0
    fi
}

# --- Usa $HOME directamente ---
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

# --- Función para iniciar (MODIFICADA para sniffer con log único) ---
start_server() {
    local world_id="$1"
    local port="${2:-$DEFAULT_PORT}"

    local SCREEN_SERVER="blockheads_server_$port"
    local SCREEN_PATCHER="blockheads_patcher_$port"
    local SCREEN_SNIFFER="blockheads_sniffer_$port"

    if [ ! -f "$SERVER_BINARY" ]; then
        print_error "Server binary not found: $SERVER_BINARY"
        print_warning "Please run the installer script first."
        return 1
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
    if screen_session_exists "$SCREEN_SERVER"; then screen -S "$SCREEN_SERVER" -X quit 2>/dev/null; fi
    if screen_session_exists "$SCREEN_PATCHER"; then screen -S "$SCREEN_PATCHER" -X quit 2>/dev/null; fi
    if screen_session_exists "$SCREEN_SNIFFER"; then screen -S "$SCREEN_SNIFFER" -X quit 2>/dev/null; fi

    sleep 1

    # --- Usa $HOME directamente ---
    local log_dir="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves/$world_id"
    local log_file="$log_dir/console.log"
    local packet_log_file="$log_dir/packet_dump.log" # <-- Archivo para paquetes únicos
    mkdir -p "$log_dir"
    # Asegurarse de que el usuario actual sea el propietario
    chown -R "$USER:$USER" "$HOME/GNUstep" 2>/dev/null || true
    # Limpiar log de paquetes anterior si existe
    rm -f "$packet_log_file"
    touch "$packet_log_file"
    chown "$USER:$USER" "$packet_log_file" 2>/dev/null || true

    print_header "STARTING SERVER - WORLD: $world_id, PORT: $port"

    echo "$world_id" > "world_id_$port.txt"

    print_step "Starting server in screen session: $SCREEN_SERVER"

    if ! command -v screen >/dev/null 2>&1; then
        print_error "Screen command not found. Please run the installer script."
        return 1
    fi

    # Script temporal para el bucle de reinicio del servidor
    local start_script=$(mktemp)
    # --- CORRECCIÓN: Usar 'script' para simular TTY y capturar entrada/salida ---
    cat > "$start_script" << EOF
#!/bin/bash
cd '$PWD'
export LD_LIBRARY_PATH="$LD_LIBRARY_PATH"
# Usar 'script' para crear un pseudo-terminal
# Esto permite que 'tee' funcione correctamente y que la entrada manual funcione.
script -q -c "./run_server_loop.sh '$world_id' '$port' '$log_file'" /dev/null
EOF

    # Script interno para el bucle real (llamado por 'script')
    cat > "./run_server_loop.sh" << LOOP_EOF
#!/bin/bash
world_id="\$1"
port="\$2"
log_file="\$3"
while true; do
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Starting server..."
    # Ejecutar directamente (sin tee aquí, 'script' lo captura)
    if ./blockheads_server171 -o "\$world_id" -p \$port; then
        echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Server closed normally"
    else
        exit_code=\$?
        echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Server failed with code: \$exit_code"
        # Comprobar si el log existe antes de usar tail
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
    chmod +x "./run_server_loop.sh"

    # Iniciar servidor usando el script temporal que llama a 'script'
    if screen -L -Logfile "$log_file" -dmS "$SCREEN_SERVER" bash -c "exec $start_script"; then
        print_success "Server screen session created successfully"
        (sleep 10; rm -f "$start_script" "./run_server_loop.sh") & # Limpiar ambos scripts
    else
        print_error "Failed to create screen session for server"
        rm -f "$start_script" "./run_server_loop.sh"
        return 1
    fi

    cleanup_server_lists "$world_id" "$port"

    print_step "Waiting for server to start..."

    local wait_time=0
    # Esperar a que el log file se cree por 'screen -L'
    while [ ! -f "$log_file" ] && [ $wait_time -lt 20 ]; do
        sleep 1
        ((wait_time++))
    done

    if [ ! -f "$log_file" ]; then
        print_error "Could not detect log file ($log_file). Server might have failed."
        # No retornar error necesariamente, podría estar tardando
    fi

    local server_ready=false
    print_status "Checking server log ($log_file) for ready message..."
    for i in {1..45}; do # Aumentar tiempo de espera
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
            print_error "Server screen session not found. Startup likely failed."
            return 1
        fi
         print_warning "Proceeding anyway, but check server status manually."
    else
        print_success "Server started successfully!"
    fi

    # Iniciar Patcher
    print_step "Starting rank patcher..."
    if [ -f "./rank_patcher.sh" ]; then
        if screen -dmS "$SCREEN_PATCHER" bash -c "cd '$PWD' && ./rank_patcher.sh '$port'"; then
            print_success "Rank patcher screen session created: $SCREEN_PATCHER"
        else
            print_warning "Failed to create rank patcher screen session"
        fi
    else
        print_warning "rank_patcher.sh not found. Skipping."
    fi

    # --- INICIO: BLOQUE MODIFICADO PARA SNIFFER CON LOG ÚNICO ---
    print_step "Starting packet sniffer (logging unique packets)..."
    if ! command -v ngrep >/dev/null 2>&1; then
        print_error "ngrep command not found. Please run installer."
    elif ! command -v awk >/dev/null 2>&1; then
         print_error "awk command not found. Cannot filter unique packets."
    else
        # Comando ngrep + awk para filtrar únicos y guardar en log
        # Usamos -x para salida hexadecimal, que es más fácil de parsear y comparar
        local ngrep_awk_cmd="sudo ngrep -x -q -d any port $port | awk 'BEGIN{RS=\"#\\s*\\n\"; ORS=RT; pkt_count=0} { header = \$0; getline body; gsub(/[[:space:]]/,\"\",body); if (body != \"\" && !(body in seen)) { seen[body]=1; pkt_count++; printf \"%s\", header RT body \"\\n\"} } END { print \"Logged \" pkt_count \" unique packets.\" >> \"/dev/stderr\" }' >> '$packet_log_file' 2>&1"

        if screen -dmS "$SCREEN_SNIFFER" bash -c "$ngrep_awk_cmd"; then
            print_success "Packet sniffer screen session created: $SCREEN_SNIFFER"
            print_status "Unique packets logged to: ${CYAN}$packet_log_file${NC}"
            # La screen estará vacía, ya que todo se redirige al archivo
        else
            print_error "Failed to create packet sniffer screen session."
            print_warning "Did you configure ${YELLOW}passwordless sudo${NC} with the installer?"
        fi
    fi
    # --- FIN: BLOQUE MODIFICADO ---

    local server_started=0
    local patcher_started=0
    local sniffer_started=0

    if screen_session_exists "$SCREEN_SERVER"; then server_started=1; fi
    if screen_session_exists "$SCREEN_PATCHER"; then patcher_started=1; fi
    if screen_session_exists "$SCREEN_SNIFFER"; then sniffer_started=1; fi

    print_header "SERVER STARTUP COMPLETE"
    print_success "World: $world_id"
    print_success "Port: $port"
    echo ""
    if [ "$server_started" -eq 1 ]; then
        print_status "Server Console: ${CYAN}screen -r $SCREEN_SERVER${NC}"
    else
        print_error "Server FAILED to start."
    fi
    if [ "$patcher_started" -eq 1 ]; then
        print_status "Rank Patcher:   ${CYAN}screen -r $SCREEN_PATCHER${NC}"
    else
        print_warning "Rank Patcher FAILED to start."
    fi
    if [ "$sniffer_started" -eq 1 ]; then
        print_status "Packet Log:     ${CYAN}tail -f $packet_log_file${NC}"
        # print_status " (Sniffer screen '$SCREEN_SNIFFER' is intentionally blank)"
    else
        print_warning "Packet Sniffer FAILED to start."
    fi
    echo ""
    print_warning "To detach from screen: ${YELLOW}CTRL+A, D${NC}"
}

# --- Función para detener ---
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

        for sniffer_session in $(screen -list | grep "blockheads_sniffer_" | awk -F. '{print $1}'); do
            screen -S "$sniffer_session" -X quit 2>/dev/null
            print_success "Stopped packet sniffer: $sniffer_session"
        done

        # Matar procesos residuales
        pkill -f "$SERVER_BINARY" 2>/dev/null || true
        pkill -f "rank_patcher.sh" 2>/dev/null || true
        # Matar ngrep necesita sudo si el usuario no tiene permiso
        sudo pkill -f "ngrep.*port" 2>/dev/null || pkill -f "ngrep.*port" 2>/dev/null || true


        rm -f world_id_*.txt 2>/dev/null || true
        rm -f run_server_loop.sh 2>/dev/null || true # Limpiar script de loop
        print_success "All processes stopped."
    else
        print_header "STOPPING SERVER ON PORT $port"

        local screen_server="blockheads_server_$port"
        local screen_patcher="blockheads_patcher_$port"
        local screen_sniffer="blockheads_sniffer_$port"

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

        if screen_session_exists "$screen_sniffer"; then
            screen -S "$screen_sniffer" -X quit 2>/dev/null
            print_success "Packet sniffer stopped on port $port."
        else
            print_warning "Packet sniffer was not running on port $port."
        fi

        # Matar procesos residuales para este puerto
        pkill -f "$SERVER_BINARY.*-p $port" 2>/dev/null || true
        pkill -f "rank_patcher.sh '$port'" 2>/dev/null || true
        sudo pkill -f "ngrep.*port $port" 2>/dev/null || pkill -f "ngrep.*port $port" 2>/dev/null || true


        rm -f "world_id_$port.txt" 2>/dev/null || true
         rm -f run_server_loop.sh 2>/dev/null || true # Limpiar script de loop
    fi
}

# --- Función de listar ---
list_servers() {
    print_header "LIST OF RUNNING SERVERS"

    local running_servers=()
    local all_ports=$(ls world_id_*.txt 2>/dev/null | sed -n 's/world_id_\(.*\).txt/\1/p')

    if [ -z "$all_ports" ]; then
         print_warning "No configured servers found (no world_id_*.txt files)."
         # Comprobar si hay screens huérfanas
         local orphan_screens=$(screen -list | grep -E "blockheads_(server|patcher|sniffer)_" | awk '{print $1}')
         if [ -n "$orphan_screens" ]; then
              print_warning "Found potentially orphaned screen sessions:"
              echo "$orphan_screens"
              print_warning "Use 'screen -r <session_name>' or '$0 stop' to manage."
         fi
         return
    fi

    print_status "Checking status for configured ports..."
    for port in $all_ports; do
        local server_running="STOPPED"
        local patcher_running="STOPPED"
        local sniffer_running="STOPPED"
        local world_id=$(cat "world_id_$port.txt" 2>/dev/null || echo "Unknown")

        if screen_session_exists "blockheads_server_$port"; then server_running="${GREEN}RUNNING${NC}"; fi
        if screen_session_exists "blockheads_patcher_$port"; then patcher_running="${GREEN}RUNNING${NC}"; fi
        if screen_session_exists "blockheads_sniffer_$port"; then sniffer_running="${GREEN}RUNNING${NC}"; fi

        echo "----------------------------------------"
        print_status "Port: ${YELLOW}$port${NC} (World: ${CYAN}$world_id${NC})"
        echo -e "  Server: $server_running"
        echo -e "  Patcher: $patcher_running"
        echo -e "  Sniffer: $sniffer_running"
        running_servers+=("$port")

    done
    echo "----------------------------------------"

    # Comprobar screens huérfanas de nuevo
    local orphan_screens=$(screen -list | grep -E "blockheads_(server|patcher|sniffer)_" | awk '{print $1}' | grep -vFf <(printf "%s\n" "${running_servers[@]}" | sed -e 's/^/blockheads_server_/' -e 's/^/blockheads_patcher_/' -e 's/^/blockheads_sniffer_/'))
     if [ -n "$orphan_screens" ]; then
          print_warning "Found potentially orphaned screen sessions:"
          echo "$orphan_screens"
          print_warning "Use 'screen -r <session_name>' or '$0 stop' to manage."
     fi

}


# --- Función de estado ---
show_status() {
    local port="$1"

    if [ -z "$port" ]; then
        # Reutilizar list_servers para el estado general
        list_servers
    else
        print_header "THE BLOCKHEADS SERVER STATUS - PORT $port"

        local server_running="${RED}STOPPED${NC}"
        local patcher_running="${RED}STOPPED${NC}"
        local sniffer_running="${RED}STOPPED${NC}"
        local world_id="Not configured"
        local packet_log_status="N/A"

        if screen_session_exists "blockheads_server_$port"; then server_running="${GREEN}RUNNING${NC}"; fi
        if screen_session_exists "blockheads_patcher_$port"; then patcher_running="${GREEN}RUNNING${NC}"; fi
        if screen_session_exists "blockheads_sniffer_$port"; then sniffer_running="${GREEN}RUNNING${NC}"; fi

        if [ -f "world_id_$port.txt" ]; then
            world_id=$(cat "world_id_$port.txt" 2>/dev/null)
             local packet_log_file="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves/$world_id/packet_dump.log"
             if [ -f "$packet_log_file" ]; then
                  packet_log_status="Exists (${CYAN}$(du -h "$packet_log_file" | cut -f1)${NC})"
             else
                  packet_log_status="${YELLOW}Not found${NC}"
             fi
        fi


        echo -e "  World: ${CYAN}$world_id${NC}"
        echo -e "  Server Status: $server_running"
        echo -e "  Patcher Status: $patcher_running"
        echo -e "  Sniffer Status: $sniffer_running"
        echo -e "  Packet Log: $packet_log_status"
        echo ""

        if [ "$server_running" != "${RED}STOPPED${NC}" ]; then
            print_status "View Server Console: ${CYAN}screen -r blockheads_server_$port${NC}"
        fi
         if [ "$patcher_running" != "${RED}STOPPED${NC}" ]; then
            print_status "View Rank Patcher:   ${CYAN}screen -r blockheads_patcher_$port${NC}"
        fi
         if [ "$sniffer_running" != "${RED}STOPPED${NC}" ]; then
             # La screen estará vacía, así que apuntamos al log
             if [ "$world_id" != "Not configured" ]; then
                print_status "View Packet Log:     ${CYAN}tail -f $packet_log_file${NC}"
             fi
        fi

    fi
}


# --- Función de Ayuda ---
show_usage() {
    print_header "THE BLOCKHEADS SERVER MANAGER"
    print_status "Usage: $0 [command]"
    echo ""
    print_status "Available commands:"
    echo -e " ${GREEN}start${NC} [WORLD_NAME] [PORT] - Start server, patcher & packet logger"
    echo -e " ${RED}stop${NC} [PORT] - Stop server, patcher & packet logger"
    echo -e " ${CYAN}status${NC} [PORT] - Show server status (includes logger)"
    echo -e " ${YELLOW}list${NC} - List all running/configured servers"
    echo -e " ${YELLOW}help${NC} - Show this help"
    echo ""
    print_status "Examples:"
    echo -e " ${GREEN}$0 start MyWorld 12153${NC}"
    echo -e " ${GREEN}$0 start MyWorld${NC} (uses default port $DEFAULT_PORT)"
    echo -e " ${RED}$0 stop${NC} (stops all servers)"
    echo -e " ${RED}$0 stop 12153${NC}"
    echo -e " ${CYAN}$0 status 12153${NC}"
    echo ""
    print_warning "First create a world: ./blockheads_server171 -n"
    print_warning "After creating the world, press CTRL+C to exit"
}

# --- Manejador de Comandos ---
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
    # install-deps quitado, es parte del installer.sh
    help|--help|-h|*)
        show_usage
        ;;
    *)
        print_error "Unknown command: $1"
        show_usage
        ;;
esac
