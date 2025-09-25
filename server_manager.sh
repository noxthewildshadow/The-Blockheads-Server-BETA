#!/bin/bash

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}
print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}
print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}
print_step() {
    echo -e "${CYAN}[STEP]${NC} $1"
}
print_header() {
    echo -e "${MAGENTA}================================================================================${NC}"
    echo -e "${MAGENTA}$1${NC}"
    echo -e "${MAGENTA}================================================================================${NC}"
}

# Configuración
SERVER_BINARY="./blockheads_server171"
RANK_PATCHER_SCRIPT="./rank_patcher.sh"
DEFAULT_PORT=12153

screen_session_exists() {
    screen -list | grep -q "$1" 2>/dev/null
}

is_port_in_use() {
    lsof -Pi ":$1" -sTCP:LISTEN -t >/dev/null 2>&1
}

check_world_exists() {
    local world_id="$1"
    local saves_dir="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves"
    
    [ -d "$saves_dir/$world_id" ] || {
        print_error "World '$world_id' does not exist in: $saves_dir/"
        echo ""
        print_warning "To create a world: ${GREEN}./blockheads_server171 -n${NC}"
        print_warning "After creating the world, press ${YELLOW}CTRL+C${NC} to exit"
        return 1
    }
    return 0
}

free_port() {
    local port="$1"
    print_warning "Freeing port $port..."
    local pids=$(lsof -ti ":$port")
    [ -n "$pids" ] && kill -9 $pids 2>/dev/null
    local screen_server="blockheads_server_$port"
    screen_session_exists "$screen_server" && screen -S "$screen_server" -X quit 2>/dev/null
    sleep 2
    ! is_port_in_use "$port"
}

# --- FUNCIÓN DE INICIO MODIFICADA ---
start_server() {
    local world_id="$1"
    local port="${2:-$DEFAULT_PORT}"
    local SCREEN_SERVER="blockheads_server_$port"
    local PATCHER_PID_FILE="/tmp/rank_patcher_${port}.pid"

    [ ! -f "$SERVER_BINARY" ] && { print_error "Server binary not found: $SERVER_BINARY"; return 1; }
    check_world_exists "$world_id" || return 1
    
    is_port_in_use "$port" && {
        print_warning "Port $port is in use."
        if ! free_port "$port"; then
            print_error "Could not free port $port"
            return 1
        fi
    }
    
    screen_session_exists "$SCREEN_SERVER" && screen -S "$SCREEN_SERVER" -X quit 2>/dev/null
    sleep 1
    
    local log_dir="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves/$world_id"
    local log_file="$log_dir/console.log"
    mkdir -p "$log_dir"
    
    print_header "STARTING SERVER - WORLD: $world_id, PORT: $port"
    echo "$world_id" > "world_id_$port.txt"
    
    # Inicia el servidor en una sesión de screen
    screen -dmS "$SCREEN_SERVER" bash -c "cd '$PWD'; ./blockheads_server171 -o '$world_id' -p $port 2>&1 | tee -a '$log_file'"

    print_step "Waiting for server to initialize..."
    sleep 5 # Espera básica para que el servidor empiece a generar logs

    # --- INICIA EL RANK PATCHER ---
    if [ -f "$RANK_PATCHER_SCRIPT" ]; then
        print_step "Starting Rank Patcher..."
        nohup "$RANK_PATCHER_SCRIPT" "$world_id" "$SCREEN_SERVER" > "/tmp/rank_patcher_${port}.log" 2>&1 &
        echo $! > "$PATCHER_PID_FILE"
        print_success "Rank Patcher is running in the background (PID: $(cat "$PATCHER_PID_FILE"))."
    else
        print_warning "rank_patcher.sh not found. Advanced features will be disabled."
    fi

    if screen_session_exists "$SCREEN_SERVER"; then
        print_header "SERVER STARTED SUCCESSFULLY!"
        print_success "World: $world_id | Port: $port"
        echo ""
        print_status "To view server console: ${CYAN}screen -r $SCREEN_SERVER${NC}"
        print_warning "To exit console without stopping server: ${YELLOW}CTRL+A, D${NC}"
    else
        print_error "Failed to start server screen session."
    fi
}

# --- FUNCIÓN DE DETENCIÓN MODIFICADA ---
stop_server() {
    local port="$1"
    
    if [ -z "$port" ]; then
        print_header "STOPPING ALL SERVERS"
        for session in $(screen -list | grep "blockheads_server_" | awk -F. '{print $1}'); do
            local current_port=$(echo "$session" | sed 's/blockheads_server_//')
            stop_server "$current_port" # Llama a la función para cada servidor
        done
        print_success "All servers stopped."
    else
        print_header "STOPPING SERVER ON PORT $port"
        local screen_server="blockheads_server_$port"
        local PATCHER_PID_FILE="/tmp/rank_patcher_${port}.pid"

        # Detiene el rank patcher
        if [ -f "$PATCHER_PID_FILE" ]; then
            print_step "Stopping Rank Patcher for port $port..."
            kill "$(cat "$PATCHER_PID_FILE")" 2>/dev/null
            rm -f "$PATCHER_PID_FILE"
            print_success "Rank Patcher stopped."
        fi

        # Detiene el servidor del juego
        if screen_session_exists "$screen_server"; then
            screen -S "$screen_server" -X quit 2>/dev/null
            print_success "Server stopped on port $port."
        else
            print_warning "Server was not running on port $port."
        fi
        
        pkill -f "$SERVER_BINARY.*$port" 2>/dev/null || true
        rm -f "world_id_$port.txt" 2>/dev/null || true
        print_success "Server cleanup completed for port $port."
    fi
}

show_status() {
    print_header "THE BLOCKHEADS SERVER STATUS"
    local servers=$(screen -list | grep "blockheads_server_" | awk -F. '{print $1}' | sed 's/blockheads_server_//')
    
    if [ -z "$servers" ]; then
        print_error "No servers are currently running."
    else
        for port in $servers; do
            echo -e "${MAGENTA}--- STATUS FOR PORT $port ---${NC}"
            if screen_session_exists "blockheads_server_$port"; then
                print_success "Server: RUNNING"
                local WORLD_ID=$(cat "world_id_$port.txt" 2>/dev/null || echo "Unknown")
                print_status "World: ${CYAN}$WORLD_ID${NC}"
            else
                print_error "Server: STOPPED"
            fi
            
            local PATCHER_PID_FILE="/tmp/rank_patcher_${port}.pid"
            if [ -f "$PATCHER_PID_FILE" ] && ps -p "$(cat "$PATCHER_PID_FILE")" > /dev/null; then
                print_success "Rank Patcher: RUNNING"
            else
                print_error "Rank Patcher: STOPPED"
            fi
            echo ""
        done
    fi
}

show_usage() {
    print_header "THE BLOCKHEADS SERVER MANAGER"
    print_status "Usage: $0 [command]"
    echo ""
    print_status "Available commands:"
    echo -e " ${GREEN}start${NC} [WORLD_NAME] [PORT] - Start server"
    echo -e " ${RED}stop${NC} [PORT] - Stop a specific server or all servers"
    echo -e " ${CYAN}status${NC} - Show status of all running servers"
    echo ""
    print_status "Examples:"
    echo -e " ${GREEN}$0 start MyWorld 12153${NC}"
    echo -e " ${RED}$0 stop${NC} (stops all servers)"
    echo -e " ${RED}$0 stop 12153${NC}"
}

# --- Main execution ---
case "$1" in
    start)
        [ -z "$2" ] && print_error "You must specify a WORLD_NAME" && show_usage && exit 1
        start_server "$2" "$3"
        ;;
    stop)
        stop_server "$2"
        ;;
    status)
        show_status
        ;;
    *)
        show_usage
        ;;
esac
