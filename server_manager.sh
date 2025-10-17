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
PYTHON_FILTER_SCRIPT="./filter_unique_ngrep.py" # <-- Nombre del script Python

# --- Funciones de Utilidad ---
screen_session_exists() { screen -list | grep -q "$1"; }
is_port_in_use() { lsof -Pi ":$1" -sTCP:LISTEN -t >/dev/null 2>&1; }
check_world_exists() {
    local world_id="$1"; local saves_dir="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves"
    if [ ! -d "$saves_dir/$world_id" ]; then print_error "World '$world_id' not in $saves_dir/"; print_warning "Create with: ./$SERVER_BINARY -n"; return 1; fi; return 0;
}
free_port() {
    local port="$1"; print_warning "Freeing port $port..."; local pids=$(lsof -ti ":$port" 2>/dev/null); if [ -n "$pids" ]; then kill -9 $pids 2>/dev/null; fi
    local s_srv="blockheads_server_$port"; local s_ptc="blockheads_patcher_$port"; local s_snf="blockheads_sniffer_$port"
    if screen_session_exists "$s_srv"; then screen -S "$s_srv" -X quit 2>/dev/null; fi; if screen_session_exists "$s_ptc"; then screen -S "$s_ptc" -X quit 2>/dev/null; fi
    if screen_session_exists "$s_snf"; then screen -S "$s_snf" -X quit 2>/dev/null; fi; sleep 1; if is_port_in_use "$port"; then return 1; else return 0; fi
}
cleanup_server_lists() {
    local world_id="$1"; ( sleep 5; local dir="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves/$world_id"; rm -f "$dir/adminlist.txt" "$dir/modlist.txt" ) &
}

# --- Función para iniciar (MODIFICADA para usar Python) ---
start_server() {
    local world_id="$1"
    local port="${2:-$DEFAULT_PORT}"

    local SCREEN_SERVER="blockheads_server_$port"
    local SCREEN_PATCHER="blockheads_patcher_$port"
    local SCREEN_SNIFFER="blockheads_sniffer_$port"

    if [ ! -f "$SERVER_BINARY" ]; then print_error "Server binary not found: $SERVER_BINARY"; print_warning "Run installer."; return 1; fi
    if ! check_world_exists "$world_id"; then return 1; fi
    if is_port_in_use "$port"; then print_warning "Port $port is in use."; if ! free_port "$port"; then print_error "Could not free port $port"; return 1; fi; fi

    # Limpieza
    if screen_session_exists "$SCREEN_SERVER"; then screen -S "$SCREEN_SERVER" -X quit 2>/dev/null; fi
    if screen_session_exists "$SCREEN_PATCHER"; then screen -S "$SCREEN_PATCHER" -X quit 2>/dev/null; fi
    if screen_session_exists "$SCREEN_SNIFFER"; then screen -S "$SCREEN_SNIFFER" -X quit 2>/dev/null; fi
    sleep 1

    local log_dir="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves/$world_id"
    local log_file="$log_dir/console.log"
    local packet_log_file="$log_dir/packet_dump.log" # <-- Archivo para paquetes únicos
    mkdir -p "$log_dir"
    chown -R "$USER:$USER" "$HOME/GNUstep" 2>/dev/null || true
    # Limpiar log de paquetes anterior
    rm -f "$packet_log_file"
    touch "$packet_log_file"
    chown "$USER:$USER" "$packet_log_file" 2>/dev/null || true

    print_header "STARTING SERVER - WORLD: $world_id, PORT: $port"
    echo "$world_id" > "world_id_$port.txt"

    print_step "Starting server in screen session: $SCREEN_SERVER"
    if ! command -v screen >/dev/null 2>&1; then print_error "Screen not found."; return 1; fi

    # Script para loop del servidor (usando 'script' para tty)
    local start_script=$(mktemp); local loop_script="./run_server_loop.sh"
    cat > "$start_script" << EOF
#!/bin/bash
cd '$PWD' && script -q -c "$loop_script '$world_id' '$port' '$log_file'" /dev/null
EOF
    cat > "$loop_script" << LOOP_EOF
#!/bin/bash
world_id="\$1"; port="\$2"; log_file="\$3"
while true; do echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Starting server..."; if ./$SERVER_BINARY -o "\$world_id" -p \$port; then echo "[\$(date)] Server closed normally"; else exit_code=\$?; echo "[\$(date)] Server failed: \$exit_code"; if [ -f "\$log_file" ] && tail -n 5 "\$log_file" | grep -q "port.*already in use"; then echo "[ERROR] Port in use. Won't retry."; break; fi; fi; echo "[INFO] Restarting in 5s..."; sleep 5; done
LOOP_EOF
    chmod +x "$start_script"; chmod +x "$loop_script"

    # Iniciar servidor usando screen -L para log
    if screen -L -Logfile "$log_file" -dmS "$SCREEN_SERVER" bash -c "exec $start_script"; then
        print_success "Server screen session created."
         (sleep 10; rm -f "$start_script" "$loop_script") & # Limpiar scripts temporales
    else
        print_error "Failed to create screen session for server."; rm -f "$start_script" "$loop_script"; return 1;
    fi

    cleanup_server_lists "$world_id" "$port"

    print_step "Waiting for server to start..."
    local wait_time=0; while [ ! -f "$log_file" ] && [ $wait_time -lt 20 ]; do sleep 1; ((wait_time++)); done
    if [ ! -f "$log_file" ]; then print_warning "Log file ($log_file) not created after 20s."; fi # No salir, solo advertir

    local server_ready=false; print_status "Checking log ($log_file)...";
    for i in {1..45}; do if [ -f "$log_file" ] && grep -q -E "World load complete|Server started|Ready for connections|using seed:|save delay:" "$log_file"; then server_ready=true; break; fi; echo -n "."; sleep 1; done; echo
    if [ "$server_ready" = false ]; then print_warning "Ready message not found."; if ! screen_session_exists "$SCREEN_SERVER"; then print_error "Server screen died."; return 1; fi; else print_success "Server started!"; fi

    # Iniciar Patcher
    print_step "Starting rank patcher..."
    if [ -f "./rank_patcher.sh" ]; then
        if screen -dmS "$SCREEN_PATCHER" bash -c "cd '$PWD' && ./rank_patcher.sh '$port'"; then print_success "Rank patcher screen created: $SCREEN_PATCHER"; else print_warning "Failed to start rank patcher screen"; fi
    else print_warning "rank_patcher.sh not found."; fi

    # --- INICIO: BLOQUE MODIFICADO PARA USAR PYTHON ---
    print_step "Starting packet sniffer (logging unique packets via Python)..."
    local sniffer_cmd="" # Comando a ejecutar en screen
    local python_executable=$(command -v python3 || command -v python) # Encontrar python3 o python

    if ! command -v ngrep >/dev/null 2>&1; then print_error "ngrep not found.";
    elif [ -z "$python_executable" ]; then print_error "Python not found.";
    elif [ ! -f "$PYTHON_FILTER_SCRIPT" ]; then print_error "$PYTHON_FILTER_SCRIPT not found.";
    else
        # Comando: ngrep (-x para hex) pipes to python script, which appends unique packets to log
        # Usar $python_executable encontrado
        # Redirigir stderr del script python al log principal para debug
        sniffer_cmd="sudo ngrep -x -q -d any port $port | '$python_executable' '$PYTHON_FILTER_SCRIPT' >> '$packet_log_file' 2>> '$log_file'"

        if screen -dmS "$SCREEN_SNIFFER" bash -c "$sniffer_cmd"; then
            print_success "Packet sniffer screen session created: $SCREEN_SNIFFER"
            print_status "Unique packets logged to: ${CYAN}$packet_log_file${NC}"
             # Hacer el log legible por el usuario normal si fue creado por root via sudo
             sudo chown "$USER":"$USER" "$packet_log_file" 2>/dev/null || true
        else
            print_error "Failed to create packet sniffer screen session."
            print_warning "Did you configure ${YELLOW}passwordless sudo${NC} with the installer?"
            sniffer_cmd="" # Falló el inicio
        fi
    fi
    # --- FIN: BLOQUE MODIFICADO ---

    local server_started=0; local patcher_started=0; local sniffer_started=0
    if screen_session_exists "$SCREEN_SERVER"; then server_started=1; fi
    if screen_session_exists "$SCREEN_PATCHER"; then patcher_started=1; fi
    # Verificar si el comando sniffer se asignó y la screen existe
    if [ -n "$sniffer_cmd" ] && screen_session_exists "$SCREEN_SNIFFER"; then sniffer_started=1; fi

    print_header "SERVER STARTUP COMPLETE"
    print_success "World: $world_id, Port: $port"
    echo ""
    if [ "$server_started" -eq 1 ]; then print_status "Server Console: ${CYAN}screen -r $SCREEN_SERVER${NC}"; else print_error "Server FAILED."; fi
    if [ "$patcher_started" -eq 1 ]; then print_status "Rank Patcher:   ${CYAN}screen -r $SCREEN_PATCHER${NC}"; else print_warning "Rank Patcher FAILED."; fi
    if [ "$sniffer_started" -eq 1 ]; then print_status "Packet Log:     ${CYAN}tail -f $packet_log_file${NC}"; else print_warning "Packet Sniffer FAILED."; fi
    echo ""
    print_warning "To detach from screen: ${YELLOW}CTRL+A, D${NC}"
}

# --- Función para detener ---
stop_server() {
    local port="$1"

    if [ -z "$port" ]; then
        print_header "STOPPING ALL SERVERS"
        # Detener screens
        screen -ls | grep -E "blockheads_(server|patcher|sniffer)_" | cut -d. -f1 | awk '{print $1}' | xargs -r -n 1 -I {} screen -S {} -X quit
        print_success "Sent quit command to all known screen sessions."
        sleep 1 # Dar tiempo a que cierren
        # Matar procesos residuales
        pkill -f "$SERVER_BINARY" 2>/dev/null || true
        pkill -f "rank_patcher.sh" 2>/dev/null || true
        sudo pkill -f "ngrep.*port" 2>/dev/null || pkill -f "ngrep.*port" 2>/dev/null || true
        pkill -f "$(basename "$PYTHON_FILTER_SCRIPT")" 2>/dev/null || true # Matar el script de filtro Python
        rm -f world_id_*.txt run_server_loop.sh 2>/dev/null || true
        print_success "All processes stopped and temp files removed."
    else
        print_header "STOPPING SERVER ON PORT $port"
        local s_srv="blockheads_server_$port"; local s_ptc="blockheads_patcher_$port"; local s_snf="blockheads_sniffer_$port"
        if screen_session_exists "$s_srv"; then screen -S "$s_srv" -X quit 2>/dev/null; print_success "Stopped server $port."; else print_warning "Server $port not running."; fi
        if screen_session_exists "$s_ptc"; then screen -S "$s_ptc" -X quit 2>/dev/null; print_success "Stopped patcher $port."; else print_warning "Patcher $port not running."; fi
        if screen_session_exists "$s_snf"; then screen -S "$s_snf" -X quit 2>/dev/null; print_success "Stopped sniffer $port."; else print_warning "Sniffer $port not running."; fi
        sleep 1
        # Matar procesos residuales para este puerto
        pkill -f "$SERVER_BINARY.*-p $port" 2>/dev/null || true
        pkill -f "rank_patcher.sh '$port'" 2>/dev/null || true
        # Matar ngrep específico y su script python asociado (más robusto)
        local ngrep_pid=$(pgrep -f "ngrep.*port $port" | head -n 1)
        if [ -n "$ngrep_pid" ]; then
            sudo kill "$ngrep_pid" 2>/dev/null || kill "$ngrep_pid" 2>/dev/null || true
            local filter_pid=$(ps -o pid= --ppid "$ngrep_pid" | head -n 1) # Buscar hijo directo (el pipe)
             if [ -n "$filter_pid" ]; then
                local python_pid=$(ps -o pid= --ppid "$filter_pid" | grep -v grep | head -n 1) # Buscar hijo del pipe (python)
                if [ -n "$python_pid" ]; then kill "$python_pid" 2>/dev/null || true; fi
             fi
        fi
        rm -f "world_id_$port.txt" run_server_loop.sh 2>/dev/null || true
    fi
}


# --- Función de listar ---
list_servers() {
    print_header "LIST OF RUNNING/CONFIGURED SERVERS"
    local running_servers=()
    local all_ports=$(ls world_id_*.txt 2>/dev/null | sed -n 's/world_id_\(.*\).txt/\1/p')

    if [ -z "$all_ports" ]; then print_warning "No configured servers found."; fi

    print_status "Checking status..."
    for port in $all_ports; do
        local srv_stat="${RED}STOPPED${NC}"; local ptc_stat="${RED}STOPPED${NC}"; local snf_stat="${RED}STOPPED${NC}"
        local world_id=$(cat "world_id_$port.txt" 2>/dev/null || echo "Unknown")
        if screen_session_exists "blockheads_server_$port"; then srv_stat="${GREEN}RUNNING${NC}"; fi
        if screen_session_exists "blockheads_patcher_$port"; then ptc_stat="${GREEN}RUNNING${NC}"; fi
        if screen_session_exists "blockheads_sniffer_$port"; then snf_stat="${GREEN}RUNNING${NC}"; fi
        echo "----------------------------------------"
        print_status "Port: ${YELLOW}$port${NC} (World: ${CYAN}$world_id${NC})"
        echo -e "  Server: $srv_stat | Patcher: $ptc_stat | Sniffer: $snf_stat"
        running_servers+=("$port")
    done
    echo "----------------------------------------"

    # Comprobar screens huérfanas
    local expected_screens=""
    for port in "${running_servers[@]}"; do expected_screens+=" blockheads_server_$port blockheads_patcher_$port blockheads_sniffer_$port"; done
    local current_screens=$(screen -ls | grep -E "blockheads_(server|patcher|sniffer)_" | awk '{print $1}')
    local orphan_screens=""
    for screen_name in $current_screens; do if [[ ! "$expected_screens" =~ "$screen_name" ]]; then orphan_screens+="$screen_name "; fi; done
    if [ -n "$orphan_screens" ]; then print_warning "Found orphaned screen sessions: $orphan_screens"; print_warning "Use '$0 stop' to clean up."; fi
}

# --- Función de estado ---
show_status() {
    local port="$1"
    if [ -z "$port" ]; then list_servers; else # Reutilizar list_servers si no hay puerto
        print_header "THE BLOCKHEADS SERVER STATUS - PORT $port"
        local srv_stat="${RED}STOPPED${NC}"; local ptc_stat="${RED}STOPPED${NC}"; local snf_stat="${RED}STOPPED${NC}"
        local world_id="Not configured"; local pkt_log_stat="N/A"
        if screen_session_exists "blockheads_server_$port"; then srv_stat="${GREEN}RUNNING${NC}"; fi
        if screen_session_exists "blockheads_patcher_$port"; then ptc_stat="${GREEN}RUNNING${NC}"; fi
        if screen_session_exists "blockheads_sniffer_$port"; then snf_stat="${GREEN}RUNNING${NC}"; fi
        if [ -f "world_id_$port.txt" ]; then
            world_id=$(cat "world_id_$port.txt" 2>/dev/null)
            local pkt_log="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves/$world_id/packet_dump.log"
            if [ -f "$pkt_log" ]; then pkt_log_stat="Exists (${CYAN}$(du -sh "$pkt_log" | cut -f1)${NC})"; else pkt_log_stat="${YELLOW}Not found${NC}"; fi
        fi
        echo -e "  World: ${CYAN}$world_id${NC}"
        echo -e "  Server Status: $srv_stat"; echo -e "  Patcher Status: $ptc_stat"; echo -e "  Sniffer Status: $snf_stat"
        echo -e "  Packet Log: $pkt_log_stat"; echo ""
        if [ "$srv_stat" != "${RED}STOPPED${NC}" ]; then print_status "View Server Console: ${CYAN}screen -r blockheads_server_$port${NC}"; fi
        if [ "$ptc_stat" != "${RED}STOPPED${NC}" ]; then print_status "View Rank Patcher:   ${CYAN}screen -r blockheads_patcher_$port${NC}"; fi
        if [ "$snf_stat" != "${RED}STOPPED${NC}" ] && [ "$world_id" != "Not configured" ]; then print_status "View Packet Log:     ${CYAN}tail -f $pkt_log${NC}"; fi
    fi
}

# --- Función de Ayuda ---
show_usage() {
    print_header "THE BLOCKHEADS SERVER MANAGER"
    print_status "Usage: $0 [command]"
    echo ""
    print_status "Available commands:"
    echo -e " ${GREEN}start${NC} [WORLD_NAME] [PORT] - Start server, patcher & unique packet logger"
    echo -e " ${RED}stop${NC} [PORT] - Stop all services for a port (or all if no port)"
    echo -e " ${CYAN}status${NC} [PORT] - Show status for a port (or all if no port)"
    echo -e " ${YELLOW}list${NC} - List running/configured servers"
    echo -e " ${YELLOW}help${NC} - Show this help"
    echo ""
    print_status "Examples:"
    echo -e " ${GREEN}$0 start MyWorld 12153${NC}"
    echo -e " ${RED}$0 stop 12153${NC}"
    echo -e " ${CYAN}$0 status 12153${NC}"
    echo ""
    print_warning "First create a world: ./$SERVER_BINARY -n (then CTRL+C)"
}

# --- Manejador de Comandos ---
if [ $# -eq 0 ]; then show_usage; exit 0; fi
case "$1" in
    start) if [ -z "$2" ]; then print_error "WORLD_NAME required"; show_usage; exit 1; fi; start_server "$2" "$3" ;;
    stop) stop_server "$2" ;;
    status) show_status "$2" ;;
    list) list_servers ;;
    help|--help|-h|*) show_usage ;;
    *) print_error "Unknown command: $1"; show_usage ;;
esac
