#!/bin/bash

# server_manager.sh - Enhanced server manager with complete rank_patcher integration
# VERSIÓN COMPLETA Y CORREGIDA

# Enhanced Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

# Function to print status messages
print_status() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_header() {
    echo -e "${PURPLE}================================================================"
    echo -e "$1"
    echo -e "===============================================================${NC}"
}

print_step() { echo -e "${CYAN}[STEP]${NC} $1"; }

# Configuration
SERVER_BINARY="./blockheads_server171"
DEFAULT_PORT=12153
BASE_DIR="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves"

# Function to check if screen session exists
screen_session_exists() {
    screen -list | grep -q "$1" 2>/dev/null
}

# Function to check if port is in use
is_port_in_use() {
    lsof -Pi ":$1" -sTCP:LISTEN -t >/dev/null 2>/dev/null
}

# Function to check if world exists
check_world_exists() {
    local world_id="$1"
    
    if [ ! -d "$BASE_DIR/$world_id" ]; then
        print_error "El mundo '$world_id' no existe en: $BASE_DIR/"
        echo ""
        print_warning "Para crear un mundo: ${GREEN}./blockheads_server171 -n${NC}"
        print_warning "Después de crear el mundo, presiona ${YELLOW}CTRL+C${NC} para salir"
        return 1
    fi
    
    return 0
}

# Function to free port
free_port() {
    local port="$1"
    print_warning "Liberando puerto $port..."
    
    local pids=$(lsof -ti ":$port" 2>/dev/null)
    if [ -n "$pids" ]; then
        kill -9 $pids 2>/dev/null
    fi
    
    local screen_server="blockheads_server_$port"
    local screen_patcher="rank_patcher_$port"
    
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

# Function to start rank_patcher
start_rank_patcher() {
    local world_id="$1" port="$2"
    local console_log="$BASE_DIR/$world_id/console.log"
    local screen_patcher="rank_patcher_$port"
    
    print_step "Iniciando rank_patcher para el mundo $world_id en puerto $port"
    
    # Wait for console log to be created by server
    local wait_time=0
    while [ ! -f "$console_log" ] && [ $wait_time -lt 30 ]; do
        sleep 1
        ((wait_time++))
    done
    
    if [ ! -f "$console_log" ]; then
        print_error "El log de consola nunca se creó: $console_log"
        return 1
    fi
    
    # Stop existing patcher
    if screen_session_exists "$screen_patcher"; then
        screen -S "$screen_patcher" -X quit 2>/dev/null
    fi
    sleep 1
    
    # Start rank_patcher in screen session
    screen -dmS "$screen_patcher" bash -c "
        cd '$PWD'
        echo 'Iniciando rank_patcher para el mundo $world_id en puerto $port'
        ./rank_patcher.sh '$console_log' '$world_id' '$port'
    "
    
    # Wait for patcher to start
    sleep 3
    
    if screen_session_exists "$screen_patcher"; then
        print_success "Rank patcher iniciado en sesión de screen: $screen_patcher"
        return 0
    else
        print_error "Error al iniciar rank patcher"
        return 1
    fi
}

# Function to start server
start_server() {
    local world_id="$1"
    local port="${2:-$DEFAULT_PORT}"
    
    local SCREEN_SERVER="blockheads_server_$port"
    
    if [ ! -f "$SERVER_BINARY" ]; then
        print_error "Binario del servidor no encontrado: $SERVER_BINARY"
        return 1
    fi
    
    if ! check_world_exists "$world_id"; then
        return 1
    fi
    
    if is_port_in_use "$port"; then
        print_warning "El puerto $port está en uso."
        if ! free_port "$port"; then
            print_error "No se pudo liberar el puerto $port"
            return 1
        fi
    fi
    
    if screen_session_exists "$SCREEN_SERVER"; then
        screen -S "$SCREEN_SERVER" -X quit 2>/dev/null
    fi
    
    sleep 1
    
    local log_dir="$BASE_DIR/$world_id"
    local log_file="$log_dir/console.log"
    mkdir -p "$log_dir"
    
    print_header "INICIANDO SERVIDOR - MUNDO: $world_id, PUERTO: $port"
    
    # Save world ID for this port
    echo "$world_id" > "world_id_$port.txt"
    
    # Create startup script
    cat > /tmp/start_server_$$.sh << EOF
#!/bin/bash
cd '$PWD'
while true; do
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Iniciando servidor..."
    if ./blockheads_server171 -o '$world_id' -p $port 2>&1 | tee -a '$log_file'; then
        echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Servidor cerrado normalmente"
    else
        exit_code=\$?
        echo "[\$(date '+%Y-%m-%d %H:%M:%S')] El servidor falló con código: \$exit_code"
        if [ \$exit_code -eq 1 ] && tail -n 5 '$log_file' | grep -q "port.*already in use"; then
            echo "[\$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Puerto ya en uso. No se reintentará."
            break
        fi
    fi
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Reiniciando en 5 segundos..."
    sleep 5
done
EOF
    
    chmod +x /tmp/start_server_$$.sh
    
    # Start server in screen session
    screen -dmS "$SCREEN_SERVER" /tmp/start_server_$$.sh
    (sleep 10; rm -f /tmp/start_server_$$.sh) &
    
    print_step "Esperando a que el servidor inicie..."
    
    local wait_time=0
    while [ ! -f "$log_file" ] && [ $wait_time -lt 15 ]; do
        sleep 1
        ((wait_time++))
    done
    
    if [ ! -f "$log_file" ]; then
        print_error "No se pudo crear el archivo de log. El servidor puede no haber iniciado."
        return 1
    fi
    
    local server_ready=false
    for i in {1..30}; do
        if grep -q "World load complete\|Server started\|Ready for connections\|using seed:\|save delay:" "$log_file" 2>/dev/null; then
            server_ready=true
            break
        fi
        sleep 1
    done
    
    if [ "$server_ready" = false ]; then
        print_warning "El servidor no mostró mensajes de inicio completos"
        if ! screen_session_exists "$SCREEN_SERVER"; then
            print_error "No se encontró la sesión de screen del servidor"
            return 1
        fi
    else
        print_success "¡Servidor iniciado exitosamente!"
    fi
    
    # Start rank_patcher after server is running
    print_step "Iniciando rank patcher..."
    if start_rank_patcher "$world_id" "$port"; then
        print_success "Rank patcher iniciado exitosamente"
    else
        print_warning "El rank patcher falló al iniciar (se reintentará)"
        sleep 10
        if start_rank_patcher "$world_id" "$port"; then
            print_success "Rank patcher iniciado en el reintento"
        else
            print_warning "El rank patcher sigue fallando"
        fi
    fi
    
    if screen_session_exists "$SCREEN_SERVER"; then
        print_header "¡SERVIDOR INICIADO EXITOSAMENTE!"
        print_success "Mundo: $world_id"
        print_success "Puerto: $port"
        echo ""
        print_status "Para ver la consola del servidor: ${CYAN}screen -r $SCREEN_SERVER${NC}"
        print_status "Para ver el rank patcher: ${CYAN}screen -r rank_patcher_$port${NC}"
        echo ""
        print_warning "Para salir de la consola sin detener el servidor: ${YELLOW}CTRL+A, D${NC}"
    else
        print_warning "No se pudo verificar la sesión de screen del servidor"
    fi
}

# Function to stop server
stop_server() {
    local port="$1"
    
    if [ -z "$port" ]; then
        print_header "DETENIENDO TODOS LOS SERVIDORES"
        print_step "Deteniendo todos los servidores y rank patchers..."
        
        # Stop all servers
        for server_session in $(screen -list | grep "blockheads_server_" | awk -F. '{print $1}' 2>/dev/null); do
            screen -S "$server_session" -X quit 2>/dev/null
            print_success "Servidor detenido: $server_session"
        done
        
        # Stop all patchers
        for patcher_session in $(screen -list | grep "rank_patcher_" | awk -F. '{print $1}' 2>/dev/null); do
            screen -S "$patcher_session" -X quit 2>/dev/null
            print_success "Rank patcher detenido: $patcher_session"
        done
        
        # Clean up world ID files
        rm -f world_id_*.txt 2>/dev/null || true
        
        print_success "Todos los servidores y rank patchers detenidos."
    else
        print_header "DETENIENDO SERVIDOR EN PUERTO $port"
        print_step "Deteniendo servidor y rank patcher en puerto $port..."
        
        local screen_server="blockheads_server_$port"
        local screen_patcher="rank_patcher_$port"
        
        if screen_session_exists "$screen_server"; then
            screen -S "$screen_server" -X quit 2>/dev/null
            print_success "Servidor detenido en puerto $port."
        else
            print_warning "El servidor no estaba ejecutándose en puerto $port."
        fi
        
        if screen_session_exists "$screen_patcher"; then
            screen -S "$screen_patcher" -X quit 2>/dev/null
            print_success "Rank patcher detenido en puerto $port."
        else
            print_warning "El rank patcher no estaba ejecutándose en puerto $port."
        fi
        
        # Clean up world ID file for this port
        rm -f "world_id_$port.txt" 2>/dev/null || true
        
        print_success "Limpieza del servidor completada para el puerto $port."
    fi
}

# Function to list servers
list_servers() {
    print_header "LISTA DE SERVIDORES EN EJECUCIÓN"
    
    local servers=$(screen -list | grep "blockheads_server_" | awk -F. '{print $1}' | sed 's/blockheads_server_/ - Puerto: /' 2>/dev/null)
    
    if [ -z "$servers" ]; then
        print_warning "No hay servidores ejecutándose actualmente."
    else
        print_status "Servidores en ejecución:"
        while IFS= read -r server; do
            print_status " $server"
        done <<< "$servers"
    fi
    
    print_header "FIN DE LA LISTA"
}

# Function to show status
show_status() {
    local port="$1"
    
    if [ -z "$port" ]; then
        print_header "ESTADO DEL SERVIDOR THE BLOCKHEADS - TODOS LOS SERVIDORES"
        
        local servers=$(screen -list | grep "blockheads_server_" | awk -F. '{print $1}' | sed 's/blockheads_server_//' 2>/dev/null)
        
        if [ -z "$servers" ]; then
            print_error "No hay servidores ejecutándose actualmente."
        else
            while IFS= read -r server_port; do
                if screen_session_exists "blockheads_server_$server_port"; then
                    print_success "Servidor en puerto $server_port: EJECUTÁNDOSE"
                else
                    print_error "Servidor en puerto $server_port: DETENIDO"
                fi
                
                if screen_session_exists "rank_patcher_$server_port"; then
                    print_success "Rank patcher en puerto $server_port: EJECUTÁNDOSE"
                else
                    print_error "Rank patcher en puerto $server_port: DETENIDO"
                fi
                
                if [ -f "world_id_$server_port.txt" ]; then
                    local WORLD_ID=$(cat "world_id_$server_port.txt" 2>/dev/null)
                    print_status "Mundo para puerto $server_port: ${CYAN}$WORLD_ID${NC}"
                fi
                echo ""
            done <<< "$servers"
        fi
    else
        print_header "ESTADO DEL SERVIDOR THE BLOCKHEADS - PUERTO $port"
        
        if screen_session_exists "blockheads_server_$port"; then
            print_success "Servidor: EJECUTÁNDOSE"
        else
            print_error "Servidor: DETENIDO"
        fi
        
        if screen_session_exists "rank_patcher_$port"; then
            print_success "Rank patcher: EJECUTÁNDOSE"
        else
            print_error "Rank patcher: DETENIDO"
        fi
        
        if [ -f "world_id_$port.txt" ]; then
            local WORLD_ID=$(cat "world_id_$port.txt" 2>/dev/null)
            print_status "Mundo actual: ${CYAN}$WORLD_ID${NC}"
            
            if screen_session_exists "blockheads_server_$port"; then
                print_status "Para ver la consola: ${CYAN}screen -r blockheads_server_$port${NC}"
                print_status "Para ver el rank patcher: ${CYAN}screen -r rank_patcher_$port${NC}"
            fi
        else
            print_warning "Mundo: No configurado para el puerto $port"
        fi
    fi
    
    print_header "FIN DEL ESTADO"
}

# Function to show usage
show_usage() {
    print_header "GESTOR DE SERVIDOR THE BLOCKHEADS"
    print_status "Uso: $0 [comando]"
    echo ""
    print_status "Comandos disponibles:"
    echo -e " ${GREEN}start${NC} [NOMBRE_MUNDO] [PUERTO] - Iniciar servidor con rank patcher"
    echo -e " ${RED}stop${NC} [PUERTO] - Detener servidor y rank patcher (puerto específico o todos)"
    echo -e " ${CYAN}status${NC} [PUERTO] - Mostrar estado del servidor (puerto específico o todos)"
    echo -e " ${YELLOW}list${NC} - Listar todos los servidores en ejecución"
    echo -e " ${YELLOW}help${NC} - Mostrar esta ayuda"
    echo ""
    print_status "Ejemplos:"
    echo -e " ${GREEN}$0 start MiMundo 12153${NC}"
    echo -e " ${GREEN}$0 start MiMundo${NC} (usa puerto por defecto 12153)"
    echo -e " ${RED}$0 stop${NC} (detiene todos los servidores y rank patchers)"
    echo -e " ${RED}$0 stop 12153${NC} (detiene servidor en puerto 12153)"
    echo -e " ${CYAN}$0 status${NC} (muestra estado de todos los servidores)"
    echo -e " ${CYAN}$0 status 12153${NC} (muestra estado del servidor en puerto 12153)"
    echo -e " ${YELLOW}$0 list${NC} (lista todos los servidores en ejecución)"
    echo ""
    print_warning "Primero crea un mundo: ./blockheads_server171 -n"
    print_warning "Después de crear el mundo, presiona CTRL+C para salir"
}

# Main execution
case "$1" in
    start)
        if [ -z "$2" ]; then
            print_error "Debes especificar un NOMBRE_MUNDO"
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
    help|--help|-h|*)
        show_usage
        ;;
esac
