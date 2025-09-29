#!/bin/bash

# rank_patcher.sh - Optimized player management system for The Blockheads

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
NC='\033[0m'

print_status() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_header() {
    echo -e "${PURPLE}================================================================"
    echo -e "$1"
    echo -e "===============================================================${NC}"
}

# Configuración
BASE_DIR="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves"
CONSOLE_LOG="$1"
WORLD_ID="$2"
PORT="$3"

if [ -z "$WORLD_ID" ] && [ -n "$CONSOLE_LOG" ]; then
    WORLD_ID=$(echo "$CONSOLE_LOG" | grep -oE 'saves/[^/]+' | cut -d'/' -f2)
fi

if [ -z "$CONSOLE_LOG" ] || [ -z "$WORLD_ID" ]; then
    print_error "Usage: $0 <console_log_path> [world_id] [port]"
    print_status "Example: $0 /path/to/console.log world123 12153"
    exit 1
fi

PLAYERS_LOG="$BASE_DIR/$WORLD_ID/players.log"
ADMIN_LIST="$BASE_DIR/$WORLD_ID/adminlist.txt"
MOD_LIST="$BASE_DIR/$WORLD_ID/modlist.txt"
WHITELIST="$BASE_DIR/$WORLD_ID/whitelist.txt"
BLACKLIST="$BASE_DIR/$WORLD_ID/blacklist.txt"
CLOUD_ADMIN_LIST="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/cloudWideOwnedAdminlist.txt"

SCREEN_SERVER="blockheads_server_${PORT:-12153}"

# Timeouts
PASSWORD_TIMEOUT=60
IP_VERIFY_TIMEOUT=30

# Arrays para tracking
declare -A connected_players
declare -A player_ip_map
declare -A password_pending
declare -A ip_verify_pending
declare -A password_timers
declare -A ip_verify_timers
declare -A ip_verified
declare -A current_players_data
declare -A previous_players_data

# Función para enviar comandos al servidor
send_server_command() {
    local command="$1"
    
    if [ -z "$command" ]; then
        print_error "Cannot send empty command to server"
        return 1
    fi
    
    if ! screen -list | grep -q "$SCREEN_SERVER"; then
        print_error "Screen session not found: $SCREEN_SERVER"
        return 1
    fi
    
    if screen -S "$SCREEN_SERVER" -p 0 -X stuff "$command$(printf \\r)"; then
        print_success "Command sent: $command"
        echo "$(date '+%Y-%m-%d %H:%M:%S') - COMMAND: $command" >> "/tmp/rank_patcher_commands.log"
        return 0
    else
        print_error "Failed to send command: $command"
        return 1
    fi
}

# Función para leer players.log
read_players_log() {
    if [ ! -f "$PLAYERS_LOG" ]; then
        print_error "players.log not found: $PLAYERS_LOG"
        return 1
    fi
    
    # Limpiar array actual
    for key in "${!current_players_data[@]}"; do
        unset current_players_data["$key"]
    done
    
    while IFS='|' read -r name ip password rank whitelisted blacklisted; do
        [[ "$name" =~ ^# ]] && continue
        [[ -z "$name" ]] && continue
        
        # Limpiar espacios
        name=$(echo "$name" | xargs)
        ip=$(echo "$ip" | xargs)
        password=$(echo "$password" | xargs)
        rank=$(echo "$rank" | xargs)
        whitelisted=$(echo "$whitelisted" | xargs)
        blacklisted=$(echo "$blacklisted" | xargs)
        
        # Valores por defecto
        [ -z "$name" ] && name="UNKNOWN"
        [ -z "$ip" ] && ip="UNKNOWN"
        [ -z "$password" ] && password="NONE"
        [ -z "$rank" ] && rank="NONE"
        [ -z "$whitelisted" ] && whitelisted="NO"
        [ -z "$blacklisted" ] && blacklisted="NO"
        
        if [ "$name" != "UNKNOWN" ]; then
            current_players_data["$name,name"]="$name"
            current_players_data["$name,ip"]="$ip"
            current_players_data["$name,password"]="$password"
            current_players_data["$name,rank"]="$rank"
            current_players_data["$name,whitelisted"]="$whitelisted"
            current_players_data["$name,blacklisted"]="$blacklisted"
        fi
    done < "$PLAYERS_LOG"
    
    return 0
}

# Verificar si IP está verificada
is_ip_verified() {
    local player_name="$1"
    local current_ip="$2"
    
    read_players_log
    local stored_ip="${current_players_data["$player_name,ip"]}"
    
    if [ "$stored_ip" = "UNKNOWN" ] || [ "$stored_ip" = "$current_ip" ]; then
        ip_verified["$player_name"]=1
        return 0
    fi
    
    ip_verified["$player_name"]=0
    return 1
}

# Timeouts
start_password_timeout() {
    local player_name="$1"
    
    print_warning "Password timeout started for $player_name (60s)"
    
    if [ -n "${password_timers[$player_name]}" ]; then
        kill "${password_timers[$player_name]}" 2>/dev/null
    fi
    
    (
        sleep $PASSWORD_TIMEOUT
        if [ -n "${password_pending[$player_name]}" ]; then
            print_warning "Password timeout reached for $player_name - kicking"
            send_server_command "/kick $player_name"
            unset password_pending["$player_name"]
            unset password_timers["$player_name"]
        fi
    ) &
    password_timers["$player_name"]=$!
}

start_ip_verify_timeout() {
    local player_name="$1" player_ip="$2"
    
    print_warning "IP verification timeout started for $player_name (30s)"
    
    if [ -n "${ip_verify_timers[$player_name]}" ]; then
        kill "${ip_verify_timers[$player_name]}" 2>/dev/null
    fi
    
    (
        sleep $IP_VERIFY_TIMEOUT
        if [ -n "${ip_verify_pending[$player_name]}" ]; then
            print_warning "IP verification timeout reached for $player_name"
            send_server_command "/kick $player_name"
            send_server_command "/ban $player_ip"
            unset ip_verify_pending["$player_name"]
            unset ip_verify_timers["$player_name"]
        fi
    ) &
    ip_verify_timers["$player_name"]=$!
}

# Manejo de listas cloud
add_player_to_cloud_list() {
    local player_name="$1"
    
    if [ ! -f "$CLOUD_ADMIN_LIST" ]; then
        touch "$CLOUD_ADMIN_LIST"
    fi
    
    if ! grep -q "^$player_name$" "$CLOUD_ADMIN_LIST" 2>/dev/null; then
        echo "$player_name" >> "$CLOUD_ADMIN_LIST"
        print_success "Added $player_name to cloud admin list"
    fi
}

remove_player_from_cloud_list() {
    local player_name="$1"
    
    if [ -f "$CLOUD_ADMIN_LIST" ]; then
        temp_file=$(mktemp)
        grep -v "^$player_name$" "$CLOUD_ADMIN_LIST" > "$temp_file"
        mv "$temp_file" "$CLOUD_ADMIN_LIST"
        print_success "Removed $player_name from cloud admin list"
    fi
}

# Aplicar rangos y listas al jugador
apply_player_ranks() {
    local player_name="$1"
    
    if [ -z "${connected_players[$player_name]}" ] || [ "${ip_verified[$player_name]}" != "1" ]; then
        print_warning "Cannot apply ranks to $player_name - not connected or IP not verified"
        return 1
    fi
    
    read_players_log
    local rank="${current_players_data["$player_name,rank"]}"
    local whitelisted="${current_players_data["$player_name,whitelisted"]}"
    local blacklisted="${current_players_data["$player_name,blacklisted"]}"
    local current_ip="${player_ip_map[$player_name]}"
    
    print_status "Applying ranks to $player_name: Rank=$rank, Whitelisted=$whitelisted, Blacklisted=$blacklisted"
    
    # Aplicar rangos
    case "$rank" in
        "ADMIN")
            send_server_command "/admin $player_name"
            send_server_command "/unmod $player_name"
            remove_player_from_cloud_list "$player_name"
            ;;
        "MOD")
            send_server_command "/mod $player_name"
            send_server_command "/unadmin $player_name"
            remove_player_from_cloud_list "$player_name"
            ;;
        "SUPER")
            send_server_command "/unadmin $player_name"
            send_server_command "/unmod $player_name"
            add_player_to_cloud_list "$player_name"
            ;;
        "NONE")
            send_server_command "/unadmin $player_name"
            send_server_command "/unmod $player_name"
            remove_player_from_cloud_list "$player_name"
            ;;
    esac
    
    # Aplicar whitelist/blacklist
    if [ "$whitelisted" = "YES" ]; then
        send_server_command "/whitelist $player_name"
    else
        send_server_command "/unwhitelist $player_name"
    fi
    
    if [ "$blacklisted" = "YES" ]; then
        send_server_command "/ban-no-device $player_name"
        if [ "$current_ip" != "UNKNOWN" ]; then
            send_server_command "/ban-no-device $current_ip"
        fi
    else
        send_server_command "/unban $player_name"
        if [ "$current_ip" != "UNKNOWN" ]; then
            send_server_command "/unban $current_ip"
        fi
    fi
    
    print_success "Applied all ranks and lists to $player_name"
    return 0
}

# Sincronizar listas del servidor
sync_server_lists() {
    print_status "Syncing server lists from players.log..."
    
    read_players_log
    
    # Limpiar listas
    > "$ADMIN_LIST"
    > "$MOD_LIST"
    > "$WHITELIST"
    > "$BLACKLIST"
    
    # Llenar listas basado en players.log para jugadores conectados y verificados
    for key in "${!current_players_data[@]}"; do
        if [[ "$key" == *,name ]]; then
            local name="${current_players_data[$key]}"
            local rank="${current_players_data["$name,rank"]}"
            local whitelisted="${current_players_data["$name,whitelisted"]}"
            local blacklisted="${current_players_data["$name,blacklisted"]}"
            
            # Solo agregar a listas si está conectado y verificado
            if [ -n "${connected_players[$name]}" ] && [ "${ip_verified[$name]}" = "1" ]; then
                case "$rank" in
                    "ADMIN") echo "$name" >> "$ADMIN_LIST" ;;
                    "MOD") echo "$name" >> "$MOD_LIST" ;;
                esac
                
                [ "$whitelisted" = "YES" ] && echo "$name" >> "$WHITELIST"
                [ "$blacklisted" = "YES" ] && echo "$name" >> "$BLACKLIST"
            fi
        fi
    done
    
    print_success "Server lists synced"
}

# Manejo de comandos de chat
handle_password_command() {
    local player_name="$1" password="$2" confirm_password="$3"
    
    if [ "$password" != "$confirm_password" ]; then
        send_server_command "Passwords do not match"
        return 1
    fi
    
    if [ ${#password} -lt 7 ] || [ ${#password} -gt 16 ]; then
        send_server_command "Password must be 7-16 characters"
        return 1
    fi
    
    if ! echo "$password" | grep -qE '^[A-Za-z0-9!@#$%^_+-=]+$'; then
        send_server_command "Invalid characters in password"
        return 1
    fi
    
    # Actualizar players.log
    read_players_log
    current_players_data["$player_name,password"]="$password"
    
    {
        echo "# Player Name | First IP | Password | Rank | Whitelisted | Blacklisted"
        for key in "${!current_players_data[@]}"; do
            if [[ "$key" == *,name ]]; then
                local name="${current_players_data[$key]}"
                local ip="${current_players_data["$name,ip"]}"
                local password="${current_players_data["$name,password"]}"
                local rank="${current_players_data["$name,rank"]}"
                local whitelisted="${current_players_data["$name,whitelisted"]}"
                local blacklisted="${current_players_data["$name,blacklisted"]}"
                echo "$name | $ip | $password | $rank | $whitelisted | $blacklisted"
            fi
        done
    } > "$PLAYERS_LOG"
    
    send_server_command "Password set successfully for $player_name"
    
    # Cancelar timeout
    if [ -n "${password_timers[$player_name]}" ]; then
        kill "${password_timers[$player_name]}" 2>/dev/null
        unset password_timers["$player_name"]
    fi
    unset password_pending["$player_name"]
    
    return 0
}

handle_ip_change() {
    local player_name="$1" provided_password="$2" current_ip="$3"
    
    read_players_log
    local stored_password="${current_players_data["$player_name,password"]}"
    
    if [ "$stored_password" = "NONE" ]; then
        send_server_command "No password set for $player_name"
        return 1
    fi
    
    if [ "$provided_password" != "$stored_password" ]; then
        send_server_command "Incorrect password"
        return 1
    fi
    
    # Actualizar IP en players.log
    current_players_data["$player_name,ip"]="$current_ip"
    
    {
        echo "# Player Name | First IP | Password | Rank | Whitelisted | Blacklisted"
        for key in "${!current_players_data[@]}"; do
            if [[ "$key" == *,name ]]; then
                local name="${current_players_data[$key]}"
                local ip="${current_players_data["$name,ip"]}"
                local password="${current_players_data["$name,password"]}"
                local rank="${current_players_data["$name,rank"]}"
                local whitelisted="${current_players_data["$name,whitelisted"]}"
                local blacklisted="${current_players_data["$name,blacklisted"]}"
                echo "$name | $ip | $password | $rank | $whitelisted | $blacklisted"
            fi
        done
    } > "$PLAYERS_LOG"
    
    send_server_command "IP verified and updated for $player_name"
    
    # Cancelar timeout y marcar como verificado
    if [ -n "${ip_verify_timers[$player_name]}" ]; then
        kill "${ip_verify_timers[$player_name]}" 2>/dev/null
        unset ip_verify_timers["$player_name"]
    fi
    unset ip_verify_pending["$player_name"]
    ip_verified["$player_name"]=1
    
    # Aplicar rangos ahora que la IP está verificada
    apply_player_ranks "$player_name"
    sync_server_lists
    
    return 0
}

# Monitoreo de players.log con inotifywait
monitor_players_log() {
    if ! command -v inotifywait &> /dev/null; then
        print_error "inotifywait not found. Install inotify-tools:"
        print_error "Ubuntu/Debian: sudo apt install inotify-tools"
        print_error "CentOS/RHEL: sudo yum install inotify-tools"
        exit 1
    fi
    
    print_header "Starting players.log monitoring with inotifywait"
    
    # Estado inicial
    read_players_log
    for key in "${!current_players_data[@]}"; do
        previous_players_data["$key"]="${current_players_data[$key]}"
    done
    
    inotifywait -m -e modify "$PLAYERS_LOG" --format '%w %e' | while read file event; do
        sleep 0.01
        
        # Guardar estado anterior
        declare -A old_players_data
        for key in "${!current_players_data[@]}"; do
            old_players_data["$key"]="${current_players_data[$key]}"
        done
        
        # Leer nuevo estado
        read_players_log
        
        # Detectar cambios y aplicar
        local changes_detected=0
        for key in "${!current_players_data[@]}"; do
            if [[ "$key" == *,name ]]; then
                local player_name="${current_players_data[$key]}"
                local current_rank="${current_players_data["$player_name,rank"]}"
                local current_whitelisted="${current_players_data["$player_name,whitelisted"]}"
                local current_blacklisted="${current_players_data["$player_name,blacklisted"]}"
                
                local old_rank="${old_players_data["$player_name,rank"]:-NONE}"
                local old_whitelisted="${old_players_data["$player_name,whitelisted"]:-NO}"
                local old_blacklisted="${old_players_data["$player_name,blacklisted"]:-NO}"
                
                # Detectar cambios
                if [ "$current_rank" != "$old_rank" ] || \
                   [ "$current_whitelisted" != "$old_whitelisted" ] || \
                   [ "$current_blacklisted" != "$old_blacklisted" ]; then
                   
                    print_header "CHANGES DETECTED for $player_name"
                    [ "$current_rank" != "$old_rank" ] && \
                        print_status "Rank: $old_rank -> $current_rank"
                    [ "$current_whitelisted" != "$old_whitelisted" ] && \
                        print_status "Whitelist: $old_whitelisted -> $current_whitelisted"
                    [ "$current_blacklisted" != "$old_blacklisted" ] && \
                        print_status "Blacklist: $old_blacklisted -> $current_blacklisted"
                    
                    changes_detected=1
                    apply_player_ranks "$player_name"
                fi
            fi
        done
        
        if [ $changes_detected -eq 1 ]; then
            sync_server_lists
            print_success "All changes processed and server lists synced"
        fi
        
        # Actualizar estado anterior
        for key in "${!current_players_data[@]}"; do
            previous_players_data["$key"]="${current_players_data[$key]}"
        done
    done
}

# Monitoreo del console.log
monitor_console_log() {
    print_header "Starting console.log monitoring"
    
    # Esperar a que el archivo exista
    local wait_time=0
    while [ ! -f "$CONSOLE_LOG" ] && [ $wait_time -lt 30 ]; do
        sleep 1
        ((wait_time++))
    done
    
    if [ ! -f "$CONSOLE_LOG" ]; then
        print_error "Console log not found: $CONSOLE_LOG"
        return 1
    fi
    
    tail -n 0 -F "$CONSOLE_LOG" | while read line; do
        # Detectar conexión de jugador
        if [[ "$line" =~ Player\ Connected\ ([a-zA-Z0-9_]+)\ \|\ ([0-9a-fA-F.:]+)\ \|\ ([0-9a-f]+) ]]; then
            local player_name="${BASH_REMATCH[1]}"
            local player_ip="${BASH_REMATCH[2]}"
            
            print_success "Player connected: $player_name ($player_ip)"
            
            connected_players["$player_name"]=1
            player_ip_map["$player_name"]="$player_ip"
            
            # Verificar si el jugador existe en players.log
            read_players_log
            if [ -z "${current_players_data["$player_name,name"]}" ]; then
                # Nuevo jugador - agregar a players.log
                print_status "New player detected - adding to players.log"
                current_players_data["$player_name,name"]="$player_name"
                current_players_data["$player_name,ip"]="$player_ip"
                current_players_data["$player_name,password"]="NONE"
                current_players_data["$player_name,rank"]="NONE"
                current_players_data["$player_name,whitelisted"]="NO"
                current_players_data["$player_name,blacklisted"]="NO"
                
                {
                    echo "# Player Name | First IP | Password | Rank | Whitelisted | Blacklisted"
                    for key in "${!current_players_data[@]}"; do
                        if [[ "$key" == *,name ]]; then
                            local name="${current_players_data[$key]}"
                            local ip="${current_players_data["$name,ip"]}"
                            local password="${current_players_data["$name,password"]}"
                            local rank="${current_players_data["$name,rank"]}"
                            local whitelisted="${current_players_data["$name,whitelisted"]}"
                            local blacklisted="${current_players_data["$name,blacklisted"]}"
                            echo "$name | $ip | $password | $rank | $whitelisted | $blacklisted"
                        fi
                    done
                } > "$PLAYERS_LOG"
                
                ip_verified["$player_name"]=1
                password_pending["$player_name"]=1
                start_password_timeout "$player_name"
                send_server_command "Welcome $player_name! Set password with: !password YOUR_PASSWORD CONFIRM_PASSWORD"
                
            else
                # Jugador existente - verificar IP
                if is_ip_verified "$player_name" "$player_ip"; then
                    print_success "IP verified for $player_name"
                    ip_verified["$player_name"]=1
                    
                    # Aplicar rangos inmediatamente
                    apply_player_ranks "$player_name"
                else
                    print_warning "IP change detected for $player_name"
                    ip_verified["$player_name"]=0
                    ip_verify_pending["$player_name"]=1
                    start_ip_verify_timeout "$player_name" "$player_ip"
                    send_server_command "SECURITY ALERT: $player_name, verify IP with: !ip_change YOUR_PASSWORD"
                    
                    # Remover rangos temporalmente
                    send_server_command "/unadmin $player_name"
                    send_server_command "/unmod $player_name"
                fi
                
                # Verificar si necesita password
                local stored_password="${current_players_data["$player_name,password"]}"
                if [ "$stored_password" = "NONE" ]; then
                    password_pending["$player_name"]=1
                    start_password_timeout "$player_name"
                    send_server_command "Welcome $player_name! Set password with: !password YOUR_PASSWORD CONFIRM_PASSWORD"
                fi
            fi
            
            sync_server_lists
            continue
        fi
        
        # Detectar desconexión
        if [[ "$line" =~ Player\ Disconnected\ ([a-zA-Z0-9_]+) ]]; then
            local player_name="${BASH_REMATCH[1]}"
            
            print_warning "Player disconnected: $player_name"
            
            # Limpiar datos del jugador
            unset connected_players["$player_name"]
            unset player_ip_map["$player_name"]
            unset ip_verified["$player_name"]
            
            # Cancelar timeouts
            if [ -n "${password_timers[$player_name]}" ]; then
                kill "${password_timers[$player_name]}" 2>/dev/null
                unset password_timers["$player_name"]
            fi
            if [ -n "${ip_verify_timers[$player_name]}" ]; then
                kill "${ip_verify_timers[$player_name]}" 2>/dev/null
                unset ip_verify_timers["$player_name"]
            fi
            
            unset password_pending["$player_name"]
            unset ip_verify_pending["$player_name"]
            
            # Re-sincronizar listas
            sync_server_lists
            continue
        fi
        
        # Detectar comandos de chat
        if [[ "$line" =~ ([a-zA-Z0-9_]+):\ (.+)$ ]]; then
            local player_name="${BASH_REMATCH[1]}"
            local message="${BASH_REMATCH[2]}"
            
            [ "$player_name" = "SERVER" ] && continue
            
            case "$message" in
                "!password "*)
                    if [[ "$message" =~ !password\ ([^ ]+)\ ([^ ]+) ]]; then
                        local password="${BASH_REMATCH[1]}"
                        local confirm_password="${BASH_REMATCH[2]}"
                        print_status "Password command from $player_name"
                        handle_password_command "$player_name" "$password" "$confirm_password"
                    else
                        send_server_command "Usage: !password NEW_PASSWORD CONFIRM_PASSWORD"
                    fi
                    ;;
                "!ip_change "*)
                    if [[ "$message" =~ !ip_change\ ([^ ]+) ]]; then
                        local password="${BASH_REMATCH[1]}"
                        local current_ip="${player_ip_map[$player_name]}"
                        print_status "IP change command from $player_name"
                        handle_ip_change "$player_name" "$password" "$current_ip"
                    else
                        send_server_command "Usage: !ip_change YOUR_PASSWORD"
                    fi
                    ;;
            esac
        fi
    done
}

# Función principal
main() {
    print_header "THE BLOCKHEADS RANK PATCHER - OPTIMIZED"
    print_status "World: $WORLD_ID"
    print_status "Port: ${PORT:-12153}"
    print_status "Console: $CONSOLE_LOG"
    print_status "Players: $PLAYERS_LOG"
    
    # Verificar que screen session existe
    if ! screen -list | grep -q "$SCREEN_SERVER"; then
        print_error "Server screen session not found: $SCREEN_SERVER"
        exit 1
    fi
    
    # Inicializar players.log si no existe
    if [ ! -f "$PLAYERS_LOG" ]; then
        print_status "Creating players.log..."
        mkdir -p "$(dirname "$PLAYERS_LOG")"
        echo "# Player Name | First IP | Password | Rank | Whitelisted | Blacklisted" > "$PLAYERS_LOG"
    fi
    
    # Sincronización inicial
    sync_server_lists
    
    # Iniciar monitores
    print_header "STARTING MONITORS"
    
    monitor_console_log &
    local console_pid=$!
    
    monitor_players_log &
    local players_pid=$!
    
    print_success "Monitors started successfully"
    print_status "Console monitor PID: $console_pid"
    print_status "Players log monitor PID: $players_pid"
    
    # Esperar a que cualquier proceso termine
    wait -n
    print_error "One monitor stopped - terminating"
    
    kill $console_pid $players_pid 2>/dev/null
    exit 1
}

# Ejecutar
main "$@"
