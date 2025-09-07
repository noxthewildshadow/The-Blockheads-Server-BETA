#!/bin/bash
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
BOLD='\033[1m'
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

LOG_FILE="$1"
PORT="$2"
LOG_DIR=$(dirname "$LOG_FILE")
ADMIN_OFFENSES_FILE="$LOG_DIR/admin_offenses_$PORT.json"
AUTHORIZED_ADMINS_FILE="$LOG_DIR/authorized_admins.txt"
AUTHORIZED_MODS_FILE="$LOG_DIR/authorized_mods.txt"
SCREEN_SERVER="blockheads_server_$PORT"

# Función mejorada para validar nombres de jugador
is_valid_player_name() {
    local player_name="$1"
    
    # Eliminar espacios en blanco al principio y final
    player_name=$(echo "$player_name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    
    # Verificar si está vacío después de recortar
    [[ -z "$player_name" ]] && return 1
    
    # Verificar longitud mínima y máxima
    [[ ${#player_name} -lt 2 || ${#player_name} -gt 16 ]] && return 1
    
    # Verificar caracteres válidos (solo letras, números, guiones bajos y guiones)
    [[ ! "$player_name" =~ ^[a-zA-Z0-9_-]+$ ]] && return 1
    
    # Verificar que no comience ni termine con guión o guión bajo
    [[ "$player_name" =~ ^[-_] || "$player_name" =~ [-_]$ ]] && return 1
    
    # Verificar que no tenga caracteres de control o barras invertidas
    if echo "$player_name" | grep -q '\\'; then
        return 1
    fi
    
    # Verificar que no tenga espacios internos múltiples
    [[ "$player_name" =~ [[:space:]]{2,} ]] && return 1
    
    return 0
}

# Función mejorada para manejar nombres inválidos
handle_invalid_player_name() {
    local player_name="$1" player_ip="$2" player_hash="$3"
    
    # Mostrar información detallada del nombre inválido
    local clean_name=$(echo "$player_name" | sed 's/\\/\\\\/g')
    
    print_warning "INVALID PLAYER NAME: '$clean_name' (IP: $player_ip, Hash: $player_hash)"
    send_server_command "WARNING: Invalid player name '$clean_name'! You will be banned for 5 seconds."
    
    # Ban inmediato
    print_warning "Banning player with invalid name: '$clean_name' (IP: $player_ip)"
    send_server_command "/ban $player_ip"
    
    # Programar el unban después de 5 segundos
    (
        sleep 5
        send_server_command "/unban $player_ip"
        print_success "Unbanned IP: $player_ip"
    ) &
    
    return 0
}

read_json_file() {
    local file_path="$1"
    [ ! -f "$file_path" ] && echo "{}" && return 1
    flock -s 200 cat "$file_path" 200>"${file_path}.lock"
}

write_json_file() {
    local file_path="$1" content="$2"
    [ ! -f "$file_path" ] && return 1
    flock -x 200 echo "$content" > "$file_path" 200>"${file_path}.lock"
}

initialize_authorization_files() {
    [ ! -f "$AUTHORIZED_ADMINS_FILE" ] && touch "$AUTHORIZED_ADMINS_FILE"
    [ ! -f "$AUTHORIZED_MODS_FILE" ] && touch "$AUTHORIZED_MODS_FILE"
}

validate_authorization() {
    local admin_list="$LOG_DIR/adminlist.txt"
    local mod_list="$LOG_DIR/modlist.txt"
    
    [ -f "$admin_list" ] && while IFS= read -r admin; do
        [[ -n "$admin" && ! "$admin" =~ ^[[:space:]]*# && ! "$admin" =~ "Usernames in this file" ]] && \
        ! grep -q -i "^$admin$" "$AUTHORIZED_ADMINS_FILE" && \
        send_server_command "/unadmin $admin" && \
        remove_from_list_file "$admin" "admin"
    done < <(grep -v "^[[:space:]]*#" "$admin_list" 2>/dev/null || true)
    
    [ -f "$mod_list" ] && while IFS= read -r mod; do
        [[ -n "$mod" && ! "$mod" =~ ^[[:space:]]*# && ! "$mod" =~ "Usernames in this file" ]] && \
        ! grep -q -i "^$mod$" "$AUTHORIZED_MODS_FILE" && \
        send_server_command "/unmod $mod" && \
        remove_from_list_file "$mod" "mod"
    done < <(grep -v "^[[:space:]]*#" "$mod_list" 2>/dev/null || true)
}

initialize_admin_offenses() {
    [ ! -f "$ADMIN_OFFENSES_FILE" ] && echo '{}' > "$ADMIN_OFFENSES_FILE"
}

record_admin_offense() {
    local admin_name="$1" current_time=$(date +%s)
    local offenses_data=$(read_json_file "$ADMIN_OFFENSES_FILE" 2>/dev/null || echo '{}')
    local current_offenses=$(echo "$offenses_data" | jq -r --arg admin "$admin_name" '.[$admin]?.count // 0')
    local last_offense_time=$(echo "$offenses_data" | jq -r --arg admin "$admin_name" '.[$admin]?.last_offense // 0')
    
    [ $((current_time - last_offense_time)) -gt 300 ] && current_offenses=0
    current_offenses=$((current_offenses + 1))
    
    offenses_data=$(echo "$offenses_data" | jq --arg admin "$admin_name" \
        --argjson count "$current_offenses" --argjson time "$current_time" \
        '.[$admin] = {"count": $count, "last_offense": $time}')
    
    write_json_file "$ADMIN_OFFENSES_FILE" "$offenses_data"
    print_warning "Recorded offense #$current_offenses for admin $admin_name"
    return $current_offenses
}

clear_admin_offenses() {
    local admin_name="$1"
    local offenses_data=$(read_json_file "$ADMIN_OFFENSES_FILE" 2>/dev/null || echo '{}')
    offenses_data=$(echo "$offenses_data" | jq --arg admin "$admin_name" 'del(.[$admin])')
    write_json_file "$ADMIN_OFFENSES_FILE" "$offenses_data"
}

remove_from_list_file() {
    local player_name="$1" list_type="$2"
    local list_file="$LOG_DIR/${list_type}list.txt"
    [ ! -f "$list_file" ] && return 1
    grep -v "^[[:space:]]*#" "$list_file" 2>/dev/null | grep -q -i "^$player_name$" && \
    sed -i "/^$player_name$/Id" "$list_file"
}

send_delayed_uncommands() {
    local target_player="$1" command_type="$2"
    (
        sleep 2; send_server_command_silent "/un${command_type} $target_player"
        sleep 2; send_server_command_silent "/un${command_type} $target_player"
        sleep 1; send_server_command_silent "/un${command_type} $target_player"
        remove_from_list_file "$target_player" "$command_type"
    ) &
}

send_server_command_silent() {
    screen -S "$SCREEN_SERVER" -X stuff "$1$(printf \\r)" 2>/dev/null
}

send_server_command() {
    screen -S "$SCREEN_SERVER" -X stuff "$1$(printf \\r)" 2>/dev/null && \
    print_success "Sent message to server: $1" || \
    print_error "Could not send message to server"
}

is_player_in_list() {
    local player_name="$1" list_type="$2"
    local list_file="$LOG_DIR/${list_type}list.txt"
    [ -f "$list_file" ] && grep -v "^[[:space:]]*#" "$list_file" 2>/dev/null | grep -q -i "^$player_name$"
}

handle_unauthorized_command() {
    local player_name="$1" command="$2" target_player="$3"
    
    if is_player_in_list "$player_name" "admin"; then
        print_error "UNAUTHORIZED COMMAND: Admin $player_name attempted to use $command on $target_player"
        send_server_command "WARNING: Admin $player_name attempted unauthorized rank assignment!"
        
        local command_type=""
        [ "$command" = "/admin" ] && command_type="admin"
        [ "$command" = "/mod" ] && command_type="mod"
        
        if [ -n "$command_type" ]; then
            send_server_command_silent "/un${command_type} $target_player"
            remove_from_list_file "$target_player" "$command_type"
            send_delayed_uncommands "$target_player" "$command_type"
        fi
        
        record_admin_offense "$player_name"
        local offense_count=$?
        
        if [ "$offense_count" -eq 1 ]; then
            send_server_command "$player_name, this is your first warning! Only the server console can assign ranks."
        elif [ "$offense_count" -eq 2 ]; then
            print_warning "SECOND OFFENSE: Admin $player_name is being demoted to mod"
            
            echo "$player_name" >> "$AUTHORIZED_MODS_FILE"
            sed -i "/^$player_name$/Id" "$AUTHORIZED_ADMINS_FILE"
            
            send_server_command_silent "/unadmin $player_name"
            remove_from_list_file "$player_name" "admin"
            
            send_server_command "/mod $player_name"
            send_server_command "ALERT: Admin $player_name has been demoted to moderator for unauthorized commands!"
            
            clear_admin_offenses "$player_name"
        fi
    else
        print_warning "Non-admin player $player_name attempted to use $command on $target_player"
        send_server_command "$player_name, you don't have permission to assign ranks."
        
        if [ "$command" = "/admin" ]; then
            send_server_command_silent "/unadmin $target_player"
            remove_from_list_file "$target_player" "admin"
            send_delayed_uncommands "$target_player" "admin"
        elif [ "$command" = "/mod" ]; then
            send_server_command_silent "/unmod $target_player"
            remove_from_list_file "$target_player" "mod"
            send_delayed_uncommands "$target_player" "mod"
        fi
    fi
}

filter_server_log() {
    while read line; do
        [[ "$line" == *"Server closed"* || "$line" == *"Starting server"* || \
          ("$line" == *"SERVER: say"* && "$line" == *"Welcome"*) || \
          "$line" == *"adminlist.txt"* || "$line" == *"modlist.txt"* ]] && continue
        echo "$line"
    done
}

cleanup() {
    print_status "Cleaning up anticheat..."
    kill $(jobs -p) 2>/dev/null
    rm -f "${ADMIN_OFFENSES_FILE}.lock" 2>/dev/null
    exit 0
}

monitor_log() {
    local log_file="$1"
    LOG_FILE="$log_file"

    initialize_authorization_files
    initialize_admin_offenses

    (
        while true; do 
            sleep 3
            validate_authorization
        done
    ) &
    local validation_pid=$!

    trap cleanup EXIT INT TERM

    print_header "STARTING ANTICHEAT SECURITY SYSTEM"
    print_status "Monitoring: $log_file"
    print_status "Port: $PORT"
    print_status "Log directory: $LOG_DIR"
    print_header "SECURITY SYSTEM ACTIVE"

    tail -n 0 -F "$log_file" 2>/dev/null | filter_server_log | while read line; do
        # Patrón mejorado para detectar conexiones de jugadores
        if [[ "$line" =~ Player\ Connected\ ([^|]+)\ \|\ ([0-9a-fA-F.:]+)\ \|\ ([0-9a-f]+) ]]; then
            local player_name="${BASH_REMATCH[1]}" player_ip="${BASH_REMATCH[2]}" player_hash="${BASH_REMATCH[3]}"
            
            # Limpiar el nombre de espacios en blanco
            player_name=$(echo "$player_name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            
            # Verificación EXPLÍCITA para barras invertidas
            if echo "$player_name" | grep -q '\\'; then
                handle_invalid_player_name "$player_name" "$player_ip" "$player_hash"
                continue
            fi
            
            if ! is_valid_player_name "$player_name"; then
                handle_invalid_player_name "$player_name" "$player_ip" "$player_hash"
                continue
            fi
            
            print_success "Player connected: $player_name (IP: $player_ip)"
        fi

        # Patrón mejorado para detectar comandos de administrador/moderador
        if [[ "$line" =~ ([^:]+):\ \/(admin|mod)\ ([^[:space:]]+) ]]; then
            local command_user="${BASH_REMATCH[1]}" command_type="${BASH_REMATCH[2]}" target_player="${BASH_REMATCH[3]}"
            
            # Limpiar los nombres
            command_user=$(echo "$command_user" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            target_player=$(echo "$target_player" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            
            # Verificación adicional para nombres con barras invertidas
            if echo "$command_user" | grep -q '\\' || echo "$target_player" | grep -q '\\'; then
                print_warning "Invalid player name with backslash in command: $command_user or $target_player"
                continue
            fi
            
            # Validar ambos nombres
            if ! is_valid_player_name "$command_user" || ! is_valid_player_name "$target_player"; then
                print_warning "Invalid player name in command: $command_user or $target_player"
                continue
            fi
            
            [ "$command_user" != "SERVER" ] && handle_unauthorized_command "$command_user" "/$command_type" "$target_player"
        fi
        
        # Detectar desconexiones de jugadores
        if [[ "$line" =~ Player\ Disconnected\ ([^[:space:]]+) ]]; then
            local player_name="${BASH_REMATCH[1]}"
            
            # Limpiar el nombre de espacios en blanco
            player_name=$(echo "$player_name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            
            # Verificación adicional para nombres con barras invertidas
            if echo "$player_name" | grep -q '\\'; then
                print_warning "Player with invalid name disconnected: $player_name"
                continue
            fi
            
            # Solo mostrar mensaje si el nombre es válido
            if is_valid_player_name "$player_name"; then
                print_warning "Player disconnected: $player_name"
            else
                print_warning "Player with invalid name disconnected: $player_name"
            fi
        fi
    done

    wait
    kill $validation_pid 2>/dev/null
}

show_usage() {
    print_header "ANTICHEAT SECURITY SYSTEM - USAGE"
    print_status "Usage: $0 <server_log_file> [port]"
    print_status "Example: $0 /path/to/console.log 12153"
    echo ""
    print_warning "Note: This script should be run alongside the server"
}

if [ $# -eq 1 ] || [ $# -eq 2 ]; then
    if [ ! -f "$LOG_FILE" ]; then
        print_error "Log file not found: $LOG_FILE"
        print_status "Waiting for log file to be created..."
        
        local wait_time=0
        while [ ! -f "$LOG_FILE" ] && [ $wait_time -lt 30 ]; do
            sleep 1
            ((wait_time++))
        done
        
        if [ ! -f "$LOG_FILE" ]; then
            print_error "Log file never appeared: $LOG_FILE"
            exit 1
        fi
    fi
    
    monitor_log "$1"
else
    show_usage
    exit 1
fi
