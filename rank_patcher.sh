#!/bin/bash

# rank_patcher.sh - Player management system for The Blockheads server

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

PASSWORD_TIMEOUT=60
IP_VERIFY_TIMEOUT=30
SUPER_REMOVE_DELAY=15

declare -A connected_players
declare -A player_ip_map
declare -A password_pending
declare -A ip_verify_pending
declare -A password_timers
declare -A ip_verify_timers
declare -A ip_verified
declare -A super_remove_timers

# Variables para el estado de players.log
declare -A current_players_data
declare -A previous_players_data

# Nueva variable para cambios pendientes
declare -A pending_rank_changes

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
        print_success "Command sent to server: $command"
        echo "$(date '+%Y-%m-%d %H:%M:%S') - COMMAND SENT: $command" >> "/tmp/rank_patcher_commands.log"
        return 0
    else
        print_error "Failed to send command: $command"
        return 1
    fi
}

kick_player() {
    local player_name="$1"
    local reason="$2"
    
    print_warning "Kicking player: $player_name - Reason: $reason"
    send_server_command "/kick $player_name"
}

clear_chat() {
    send_server_command "/clear"
}

initialize_players_log() {
    if [ ! -f "$PLAYERS_LOG" ]; then
        print_status "Creating new players.log file"
        mkdir -p "$(dirname "$PLAYERS_LOG")"
        touch "$PLAYERS_LOG"
        echo "# Player Name | First IP | Password | Rank | Whitelisted | Blacklisted" > "$PLAYERS_LOG"
        print_success "players.log created at: $PLAYERS_LOG"
    fi
}

read_players_log() {
    if [ ! -f "$PLAYERS_LOG" ]; then
        print_error "players.log not found: $PLAYERS_LOG"
        return 1
    fi
    
    # Limpiar array actual
    for key in "${!current_players_data[@]}"; do
        unset current_players_data["$key"]
    done
    
    local line_count=0
    while IFS='|' read -r name ip password rank whitelisted blacklisted; do
        [[ "$name" =~ ^# ]] && continue
        [[ -z "$name" ]] && continue
        
        # Limpiar espacios y normalizar nombres
        name=$(echo "$name" | xargs | tr '[:lower:]' '[:upper:]')
        ip=$(echo "$ip" | xargs)
        password=$(echo "$password" | xargs)
        rank=$(echo "$rank" | xargs | tr '[:lower:]' '[:upper:]')
        whitelisted=$(echo "$whitelisted" | xargs | tr '[:lower:]' '[:upper:]')
        blacklisted=$(echo "$blacklisted" | xargs | tr '[:lower:]' '[:upper:]')
        
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
            ((line_count++))
        fi
    done < "$PLAYERS_LOG"
    
    return 0
}

update_players_log() {
    local player_name="$1" field="$2" new_value="$3"
    
    if [ -z "$player_name" ] || [ -z "$field" ]; then
        print_error "Invalid parameters for update_players_log"
        return 1
    fi
    
    # Normalizar nombre
    player_name=$(echo "$player_name" | tr '[:lower:]' '[:upper:]')
    
    read_players_log
    
    case "$field" in
        "ip") current_players_data["$player_name,ip"]="$new_value" ;;
        "password") current_players_data["$player_name,password"]="$new_value" ;;
        "rank") 
            current_players_data["$player_name,rank"]=$(echo "$new_value" | tr '[:lower:]' '[:upper:]")
            ;;
        "whitelisted") 
            current_players_data["$player_name,whitelisted"]=$(echo "$new_value" | tr '[:lower:]' '[:upper:]')
            ;;
        "blacklisted") 
            current_players_data["$player_name,blacklisted"]=$(echo "$new_value" | tr '[:lower:]' '[:upper:]")
            ;;
        *) print_error "Unknown field: $field"; return 1 ;;
    esac
    
    {
        echo "# Player Name | First IP | Password | Rank | Whitelisted | Blacklisted"
        
        for key in "${!current_players_data[@]}"; do
            if [[ "$key" == *,name ]]; then
                local name="${current_players_data[$key]}"
                local ip="${current_players_data["$name,ip"]:-UNKNOWN}"
                local password="${current_players_data["$name,password"]:-NONE}"
                local rank="${current_players_data["$name,rank"]:-NONE}"
                local whitelisted="${current_players_data["$name,whitelisted"]:-NO}"
                local blacklisted="${current_players_data["$name,blacklisted"]:-NO}"
                
                echo "$name | $ip | $password | $rank | $whitelisted | $blacklisted"
            fi
        done
    } > "$PLAYERS_LOG"
    
    print_success "Updated players.log: $player_name $field = $new_value"
}

add_new_player() {
    local player_name="$1" player_ip="$2"
    
    if [ -z "$player_name" ] || [ -z "$player_ip" ]; then
        print_error "Invalid parameters for add_new_player"
        return 1
    fi
    
    # Normalizar nombre
    player_name=$(echo "$player_name" | tr '[:lower:]' '[:upper:]')
    
    read_players_log
    if [ -n "${current_players_data["$player_name,name"]}" ]; then
        print_warning "Player already exists: $player_name"
        return 0
    fi
    
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
                local ip="${current_players_data["$name,ip"]:-UNKNOWN}"
                local password="${current_players_data["$name,password"]:-NONE}"
                local rank="${current_players_data["$name,rank"]:-NONE}"
                local whitelisted="${current_players_data["$name,whitelisted"]:-NO}"
                local blacklisted="${current_players_data["$name,blacklisted"]:-NO}"
                
                echo "$name | $ip | $password | $rank | $whitelisted | $blacklisted"
            fi
        done
    } > "$PLAYERS_LOG"
    
    print_success "Added new player: $player_name ($player_ip)"
}

is_ip_verified() {
    local player_name="$1"
    local current_ip="$2"
    
    # Normalizar nombre
    player_name=$(echo "$player_name" | tr '[:lower:]' '[:upper:]')
    
    read_players_log
    local stored_ip="${current_players_data["$player_name,ip"]}"
    
    if [ "$stored_ip" = "UNKNOWN" ] || [ "$stored_ip" = "$current_ip" ]; then
        return 0
    fi
    
    return 1
}

# Función mejorada para aplicar rangos inmediatamente cuando sea posible
apply_rank_commands() {
    local player_name="$1" rank="$2"
    
    # Normalizar nombre y rango
    player_name=$(echo "$player_name" | tr '[:lower:]' '[:upper:]')
    rank=$(echo "$rank" | tr '[:lower:]' '[:upper:]')
    
    print_status "Applying rank commands for $player_name: $rank"
    
    case "$rank" in
        "ADMIN")
            send_server_command "/admin $player_name"
            send_server_command "/unmod $player_name"
            remove_player_from_cloud_list "$player_name"
            cancel_super_remove_timer "$player_name"
            print_success "✓ ADMIN rank commands sent for $player_name"
            ;;
        "MOD")
            send_server_command "/mod $player_name"
            send_server_command "/unadmin $player_name"
            remove_player_from_cloud_list "$player_name"
            cancel_super_remove_timer "$player_name"
            print_success "✓ MOD rank commands sent for $player_name"
            ;;
        "SUPER")
            send_server_command "/unadmin $player_name"
            send_server_command "/unmod $player_name"
            add_player_to_cloud_list "$player_name"
            cancel_super_remove_timer "$player_name"
            print_success "✓ SUPER rank commands sent for $player_name"
            ;;
        "NONE")
            send_server_command "/unadmin $player_name"
            send_server_command "/unmod $player_name"
            remove_player_from_cloud_list "$player_name"
            cancel_super_remove_timer "$player_name"
            print_success "✓ Rank removal commands sent for $player_name"
            ;;
        *)
            print_warning "Unknown rank: $rank for $player_name"
            return 1
            ;;
    esac
    return 0
}

# Función mejorada para verificar y aplicar rangos
check_and_apply_player_ranks() {
    local player_name="$1"
    
    # Normalizar nombre
    player_name=$(echo "$player_name" | tr '[:lower:]' '[:upper:]')
    
    print_header "CHECKING AND APPLYING RANKS FOR: $player_name"
    
    read_players_log
    local rank="${current_players_data["$player_name,rank"]}"
    local whitelisted="${current_players_data["$player_name,whitelisted"]}"
    local blacklisted="${current_players_data["$player_name,blacklisted"]}"
    local current_ip="${player_ip_map[$player_name]}"
    local stored_ip="${current_players_data["$player_name,ip"]}"
    
    print_status "Player: $player_name"
    print_status "Rank: $rank, Whitelisted: $whitelisted, Blacklisted: $blacklisted"
    print_status "Stored IP: $stored_ip, Current IP: $current_ip"
    print_status "Connected: ${connected_players[$player_name]:-NO}"
    print_status "IP Verified: $(is_ip_verified "$player_name" "$current_ip" && echo "YES" || echo "NO")"
    
    # Verificar si el jugador está conectado
    if [ -z "${connected_players[$player_name]}" ]; then
        print_warning "Player $player_name is not connected - cannot apply ranks"
        # Guardar cambio pendiente para cuando se conecte
        pending_rank_changes["$player_name"]=1
        return 1
    fi
    
    # Verificar si la IP está verificada
    if ! is_ip_verified "$player_name" "$current_ip"; then
        print_warning "IP not verified for $player_name - stored: $stored_ip, current: $current_ip"
        # Guardar cambio pendiente para cuando se verifique la IP
        pending_rank_changes["$player_name"]=1
        return 1
    fi
    
    print_success "Player $player_name is connected and IP verified - applying ranks"
    
    # Aplicar comandos de rango
    if ! apply_rank_commands "$player_name" "$rank"; then
        print_error "Failed to apply rank commands for $player_name"
        return 1
    fi
    
    # Aplicar comandos de whitelist/blacklist
    if [ "$whitelisted" = "YES" ]; then
        print_status "Whitelisting $player_name"
        send_server_command "/whitelist $player_name"
        print_success "✓ Whitelist command sent for $player_name"
    else
        print_status "Unwhitelisting $player_name"
        send_server_command "/unwhitelist $player_name"
        print_success "✓ Unwhitelist command sent for $player_name"
    fi
    
    if [ "$blacklisted" = "YES" ]; then
        print_status "Blacklisting $player_name"
        send_server_command "/ban-no-device $player_name"
        if [ -n "$current_ip" ] && [ "$current_ip" != "UNKNOWN" ]; then
            send_server_command "/ban-no-device $current_ip"
            print_success "✓ IP ban command sent for $current_ip"
        fi
        print_success "✓ Blacklist commands sent for $player_name"
    else
        print_status "Unbanning $player_name"
        send_server_command "/unban $player_name"
        if [ -n "$current_ip" ] && [ "$current_ip" != "UNKNOWN" ]; then
            send_server_command "/unban $current_ip"
            print_success "✓ IP unban command sent for $current_ip"
        fi
        print_success "✓ Unban commands sent for $player_name"
    fi
    
    # Sincronizar listas del servidor
    sync_server_lists
    
    # Limpiar cambio pendiente
    unset pending_rank_changes["$player_name"]
    
    print_success "✓ All rank commands applied for $player_name"
    return 0
}

# Nueva función para verificar cambios pendientes cuando un jugador se conecta
check_pending_changes() {
    local player_name="$1"
    
    # Normalizar nombre
    player_name=$(echo "$player_name" | tr '[:lower:]' '[:upper:]')
    
    if [ -n "${pending_rank_changes[$player_name]}" ]; then
        print_status "Checking pending rank changes for $player_name"
        check_and_apply_player_ranks "$player_name"
    fi
}

start_password_timeout() {
    local player_name="$1"
    
    print_warning "Starting password timeout for $player_name (60 seconds)"
    
    if [ -n "${password_timers[$player_name]}" ]; then
        kill "${password_timers[$player_name]}" 2>/dev/null
    fi
    
    (
        sleep $PASSWORD_TIMEOUT
        if [ -n "${password_pending[$player_name]}" ]; then
            print_warning "Password timeout reached for $player_name - kicking player"
            kick_player "$player_name" "No password set within 60 seconds"
            unset password_pending["$player_name"]
            unset password_timers["$player_name"]
        fi
    ) &
    password_timers["$player_name"]=$!
}

start_ip_verify_timeout() {
    local player_name="$1" player_ip="$2"
    
    print_warning "Starting IP verification timeout for $player_name (30 seconds)"
    
    if [ -n "${ip_verify_timers[$player_name]}" ]; then
        kill "${ip_verify_timers[$player_name]}" 2>/dev/null
    fi
    
    (
        sleep $IP_VERIFY_TIMEOUT
        if [ -n "${ip_verify_pending[$player_name]}" ]; then
            print_warning "IP verification timeout reached for $player_name - kicking and banning IP"
            kick_player "$player_name" "IP verification failed within 30 seconds"
            send_server_command "/ban $player_ip"
            unset ip_verify_pending["$player_name"]
            unset ip_verify_timers["$player_name"]
        fi
    ) &
    ip_verify_timers["$player_name"]=$!
}

start_super_remove_timer() {
    local player_name="$1"
    
    print_warning "Starting SUPER remove timer for $player_name (15 seconds)"
    
    if [ -n "${super_remove_timers[$player_name]}" ]; then
        kill "${super_remove_timers[$player_name]}" 2>/dev/null
    fi
    
    (
        sleep $SUPER_REMOVE_DELAY
        remove_player_from_cloud_list "$player_name"
        unset super_remove_timers["$player_name"]
    ) &
    super_remove_timers["$player_name"]=$!
}

cancel_super_remove_timer() {
    local player_name="$1"
    
    if [ -n "${super_remove_timers[$player_name]}" ]; then
        kill "${super_remove_timers[$player_name]}" 2>/dev/null
        unset super_remove_timers["$player_name"]
        print_success "Cancelled SUPER remove timer for $player_name"
    fi
}

send_password_reminder() {
    local player_name="$1"
    
    (
        sleep 5
        if [ -n "${password_pending[$player_name]}" ]; then
            send_server_command "Welcome $player_name! Please set a password using: !password YOUR_PASSWORD CONFIRM_PASSWORD within 60 seconds."
        fi
    ) &
}

send_ip_warning() {
    local player_name="$1"
    
    (
        sleep 5
        if [ -n "${ip_verify_pending[$player_name]}" ]; then
            send_server_command "SECURITY ALERT: $player_name, your IP has changed! Verify with: !ip_change YOUR_PASSWORD within 30 seconds or you will be kicked and IP banned."
        fi
    ) &
}

validate_password() {
    local password="$1"
    local length=${#password}
    
    if [ $length -lt 7 ] || [ $length -gt 16 ]; then
        echo "Password must be between 7 and 16 characters"
        return 1
    fi
    
    if ! echo "$password" | grep -qE '^[A-Za-z0-9!@#$%^_+-=]+$'; then
        echo "Password contains invalid characters. Only letters, numbers and !@#$%^_+-= are allowed"
        return 1
    fi
    
    return 0
}

handle_password_command() {
    local player_name="$1" password="$2" confirm_password="$3"
    
    clear_chat
    
    if [ "$password" != "$confirm_password" ]; then
        send_server_command "Passwords do not match"
        return 1
    fi
    
    local validation_result
    validation_result=$(validate_password "$password")
    if [ $? -ne 0 ]; then
        send_server_command "$validation_result"
        return 1
    fi
    
    update_players_log "$player_name" "password" "$password"
    send_server_command "Password set successfully for $player_name"
    
    if [ -n "${password_timers[$player_name]}" ]; then
        kill "${password_timers[$player_name]}" 2>/dev/null
        unset password_timers["$player_name"]
    fi
    unset password_pending["$player_name"]
    
    return 0
}

handle_ip_change() {
    local player_name="$1" provided_password="$2" current_ip="$3"
    
    clear_chat
    
    read_players_log
    local stored_password="${current_players_data["$player_name,password"]}"
    
    if [ "$stored_password" = "NONE" ]; then
        send_server_command "No password set for $player_name. Use !password first."
        return 1
    fi
    
    if [ "$provided_password" != "$stored_password" ]; then
        send_server_command "Incorrect password for IP verification"
        return 1
    fi
    
    update_players_log "$player_name" "ip" "$current_ip"
    send_server_command "IP address verified and updated for $player_name"
    
    if [ -n "${ip_verify_timers[$player_name]}" ]; then
        kill "${ip_verify_timers[$player_name]}" 2>/dev/null
        unset ip_verify_timers["$player_name"]
    fi
    unset ip_verify_pending["$player_name"]
    
    print_success "IP verified for $player_name - applying ranks"
    check_and_apply_player_ranks "$player_name"
    
    return 0
}

add_player_to_cloud_list() {
    local player_name="$1"
    
    # Normalizar nombre
    player_name=$(echo "$player_name" | tr '[:lower:]' '[:upper:]')
    
    if [ ! -f "$CLOUD_ADMIN_LIST" ]; then
        touch "$CLOUD_ADMIN_LIST"
    fi
    
    # Check if player is already in the list (ignoring first line)
    if ! tail -n +2 "$CLOUD_ADMIN_LIST" | grep -q "^$player_name$"; then
        # Add player to cloud admin list
        echo "$player_name" >> "$CLOUD_ADMIN_LIST"
        print_success "Added $player_name to cloud admin list"
    fi
}

remove_player_from_cloud_list() {
    local player_name="$1"
    
    # Normalizar nombre
    player_name=$(echo "$player_name" | tr '[:lower:]' '[:upper:]')
    
    if [ -f "$CLOUD_ADMIN_LIST" ]; then
        # Remove player from cloud admin list (ignoring first line)
        temp_file=$(mktemp)
        head -n 1 "$CLOUD_ADMIN_LIST" > "$temp_file" 2>/dev/null
        tail -n +2 "$CLOUD_ADMIN_LIST" | grep -v "^$player_name$" >> "$temp_file"
        mv "$temp_file" "$CLOUD_ADMIN_LIST"
        print_success "Removed $player_name from cloud admin list"
    fi
}

remove_player_from_all_lists() {
    local player_name="$1"
    
    # Normalizar nombre
    player_name=$(echo "$player_name" | tr '[:lower:]' '[:upper:]')
    
    # Remove from admin list
    if [ -f "$ADMIN_LIST" ]; then
        temp_file=$(mktemp)
        grep -v "^$player_name$" "$ADMIN_LIST" > "$temp_file"
        mv "$temp_file" "$ADMIN_LIST"
    fi
    
    # Remove from mod list
    if [ -f "$MOD_LIST" ]; then
        temp_file=$(mktemp)
        grep -v "^$player_name$" "$MOD_LIST" > "$temp_file"
        mv "$temp_file" "$MOD_LIST"
    fi
    
    # Remove from whitelist
    if [ -f "$WHITELIST" ]; then
        temp_file=$(mktemp)
        grep -v "^$player_name$" "$WHITELIST" > "$temp_file"
        mv "$temp_file" "$WHITELIST"
    fi
    
    # Remove from blacklist
    if [ -f "$BLACKLIST" ]; then
        temp_file=$(mktemp)
        grep -v "^$player_name$" "$BLACKLIST" > "$temp_file"
        mv "$temp_file" "$BLACKLIST"
    fi
    
    # Remove from cloud admin list after delay
    start_super_remove_timer "$player_name"
    
    print_success "Removed $player_name from all server lists"
}

sync_server_lists() {
    print_status "Syncing server lists from players.log..."
    
    read_players_log
    
    # Clear all lists
    for list_file in "$ADMIN_LIST" "$MOD_LIST" "$WHITELIST" "$BLACKLIST"; do
        > "$list_file"
    done
    
    # Add players to appropriate lists based on their current state
    for key in "${!current_players_data[@]}"; do
        if [[ "$key" == *,name ]]; then
            local name="${current_players_data[$key]}"
            local ip="${current_players_data["$name,ip"]}"
            local rank="${current_players_data["$name,rank"]}"
            local whitelisted="${current_players_data["$name,whitelisted"]}"
            local blacklisted="${current_players_data["$name,blacklisted"]}"
            local current_ip="${player_ip_map[$name]}"
            
            # Only add to lists if IP is verified and player is connected
            if [ -n "${connected_players[$name]}" ]; then
                if is_ip_verified "$name" "$current_ip"; then
                    case "$rank" in
                        "ADMIN")
                            echo "$name" >> "$ADMIN_LIST"
                            ;;
                        "MOD")
                            echo "$name" >> "$MOD_LIST"
                            ;;
                    esac
                    
                    if [ "$whitelisted" = "YES" ]; then
                        echo "$name" >> "$WHITELIST"
                    fi
                    
                    if [ "$blacklisted" = "YES" ]; then
                        echo "$name" >> "$BLACKLIST"
                    fi
                else
                    print_warning "Player $name connected but IP not verified - not adding to lists"
                fi
            fi
        fi
    done
    
    print_success "Server lists synced"
}

monitor_players_log_changes() {
    print_header "Starting players.log monitoring with file polling"
    
    # Inicializar estado anterior
    read_players_log
    for key in "${!current_players_data[@]}"; do
        previous_players_data["$key"]="${current_players_data[$key]}"
    done
    
    local last_mod_time=$(stat -c %Y "$PLAYERS_LOG" 2>/dev/null || echo 0)
    
    while true; do
        # Verificar si el archivo ha sido modificado
        local current_mod_time=$(stat -c %Y "$PLAYERS_LOG" 2>/dev/null || echo 0)
        
        if [ "$current_mod_time" != "$last_mod_time" ]; then
            last_mod_time=$current_mod_time
            
            # Pequeña pausa para asegurar que el archivo se haya escrito completamente
            sleep 0.1
            
            print_status "players.log modified - checking for changes..."
            
            # Guardar estado actual antes de leer
            declare -A old_players_data
            for key in "${!current_players_data[@]}"; do
                old_players_data["$key"]="${current_players_data[$key]}"
            done
            
            # Leer nuevo estado
            if ! read_players_log; then
                print_error "Failed to read players.log"
                sleep 1
                continue
            fi
            
            # Detectar cambios y aplicar comandos
            local changes_detected=0
            for key in "${!current_players_data[@]}"; do
                if [[ "$key" == *,name ]]; then
                    local player_name="${current_players_data[$key]}"
                    local current_rank="${current_players_data["$player_name,rank"]}"
                    local current_whitelisted="${current_players_data["$player_name,whitelisted"]}"
                    local current_blacklisted="${current_players_data["$player_name,blacklisted"]}"
                    
                    local previous_rank="${old_players_data["$player_name,rank"]:-NONE}"
                    local previous_whitelisted="${old_players_data["$player_name,whitelisted"]:-NO}"
                    local previous_blacklisted="${old_players_data["$player_name,blacklisted"]:-NO}"
                    
                    # Verificar cambios de rank
                    if [ "$current_rank" != "$previous_rank" ]; then
                        print_header "🚨 RANK CHANGE DETECTED for $player_name: $previous_rank -> $current_rank"
                        changes_detected=1
                        check_and_apply_player_ranks "$player_name"
                    fi
                    
                    # Verificar cambios de whitelist
                    if [ "$current_whitelisted" != "$previous_whitelisted" ]; then
                        print_header "🚨 WHITELIST CHANGE DETECTED for $player_name: $previous_whitelisted -> $current_whitelisted"
                        changes_detected=1
                        check_and_apply_player_ranks "$player_name"
                    fi
                    
                    # Verificar cambios de blacklist
                    if [ "$current_blacklisted" != "$previous_blacklisted" ]; then
                        print_header "🚨 BLACKLIST CHANGE DETECTED for $player_name: $previous_blacklisted -> $current_blacklisted"
                        changes_detected=1
                        check_and_apply_player_ranks "$player_name"
                    fi
                fi
            done
            
            if [ $changes_detected -eq 1 ]; then
                print_success "✅ Changes detected and processed"
            fi
            
            # Actualizar estado anterior
            for key in "${!current_players_data[@]}"; do
                previous_players_data["$key"]="${current_players_data[$key]}"
            done
        fi
        
        # Polling cada 0.1 segundos
        sleep 0.1
    done
}

test_server_communication() {
    print_header "TESTING SERVER COMMUNICATION"
    
    # Test 1: Verificar screen session
    print_status "Test 1: Checking screen session..."
    if screen -list | grep -q "$SCREEN_SERVER"; then
        print_success "✓ Screen session found: $SCREEN_SERVER"
    else
        print_error "✗ Screen session NOT found: $SCREEN_SERVER"
        return 1
    fi
    
    # Test 2: Enviar comando de prueba
    print_status "Test 2: Sending test command..."
    if send_server_command "echo 'RankPatcher test command received'"; then
        print_success "✓ Test command sent successfully"
    else
        print_error "✗ Test command failed"
        return 1
    fi
    
    print_success "✅ All server communication tests passed!"
    return 0
}

monitor_console_log() {
    print_header "Starting console.log monitoring"
    
    # Esperar a que el archivo exista
    local wait_time=0
    while [ ! -f "$CONSOLE_LOG" ] && [ $wait_time -lt 30 ]; do
        sleep 1
        ((wait_time++))
    done
    
    if [ ! -f "$CONSOLE_LOG" ]; then
        print_error "Console log never appeared: $CONSOLE_LOG"
        return 1
    fi
    
    tail -n 0 -F "$CONSOLE_LOG" | while read line; do
        # Detectar conexión de jugador - formato mejorado
        if [[ "$line" =~ Player\ Connected\ ([a-zA-Z0-9_]+)\ \|\ ([0-9a-fA-F.:]+)\ \|\ ([0-9a-f]+) ]]; then
            local player_name="${BASH_REMATCH[1]}"
            local player_ip="${BASH_REMATCH[2]}"
            local player_hash="${BASH_REMATCH[3]}"
            
            # Normalizar nombre
            player_name_upper=$(echo "$player_name" | tr '[:lower:]' '[:upper:]')
            
            print_success "Player connected: $player_name ($player_ip) - Hash: $player_hash"
            
            connected_players["$player_name_upper"]=1
            player_ip_map["$player_name_upper"]="$player_ip"
            
            # Cancel SUPER remove timer if player reconnects
            cancel_super_remove_timer "$player_name_upper"
            
            read_players_log
            if [ -z "${current_players_data["$player_name_upper,name"]}" ]; then
                add_new_player "$player_name" "$player_ip"
                
                # Marcar IP como verificada para nuevo jugador
                ip_verified["$player_name_upper"]=1
                password_pending["$player_name_upper"]=1
                start_password_timeout "$player_name_upper"
                send_password_reminder "$player_name_upper"
                
                # Aplicar rangos después de agregar nuevo jugador
                check_and_apply_player_ranks "$player_name_upper"
            else
                local stored_ip="${current_players_data["$player_name_upper,ip"]}"
                local stored_password="${current_players_data["$player_name_upper,password"]}"
                local stored_rank="${current_players_data["$player_name_upper,rank"]}"
                
                # Verificar IP y aplicar rangos inmediatamente
                if is_ip_verified "$player_name_upper" "$player_ip"; then
                    print_success "IP verified for $player_name - stored: $stored_ip, current: $player_ip"
                    ip_verified["$player_name_upper"]=1
                    
                    # Aplicar rangos SIEMPRE cuando el jugador se reconecta y la IP está verificada
                    print_status "Applying ranks for reconnected player: $player_name (Rank: $stored_rank)"
                    check_and_apply_player_ranks "$player_name_upper"
                    
                    # Verificar cambios pendientes
                    check_pending_changes "$player_name_upper"
                else
                    print_warning "IP change detected for $player_name: $stored_ip -> $player_ip"
                    ip_verified["$player_name_upper"]=0
                    ip_verify_pending["$player_name_upper"]=1
                    start_ip_verify_timeout "$player_name_upper" "$player_ip"
                    send_ip_warning "$player_name"
                    
                    # Remover rangos temporalmente hasta verificación
                    if [ "$stored_rank" = "ADMIN" ]; then
                        send_server_command "/unadmin $player_name"
                        print_warning "Temporarily removed ADMIN rank from $player_name pending IP verification"
                    elif [ "$stored_rank" = "MOD" ]; then
                        send_server_command "/unmod $player_name"
                        print_warning "Temporarily removed MOD rank from $player_name pending IP verification"
                    fi
                fi
                
                if [ "$stored_password" = "NONE" ]; then
                    password_pending["$player_name_upper"]=1
                    start_password_timeout "$player_name_upper"
                    send_password_reminder "$player_name"
                fi
            fi
            
            sync_server_lists
            continue
        fi
        
        # Detectar desconexión de jugador
        if [[ "$line" =~ Player\ Disconnected\ ([a-zA-Z0-9_]+) ]]; then
            local player_name="${BASH_REMATCH[1]}"
            local player_name_upper=$(echo "$player_name" | tr '[:lower:]' '[:upper:]')
            
            print_warning "Player disconnected: $player_name"
            
            # Remove player from all lists immediately
            remove_player_from_all_lists "$player_name_upper"
            
            unset connected_players["$player_name_upper"]
            unset player_ip_map["$player_name_upper"]
            unset ip_verified["$player_name_upper"]
            
            if [ -n "${password_timers[$player_name_upper]}" ]; then
                kill "${password_timers[$player_name_upper]}" 2>/dev/null
                unset password_timers["$player_name_upper"]
            fi
            if [ -n "${ip_verify_timers[$player_name_upper]}" ]; then
                kill "${ip_verify_timers[$player_name_upper]}" 2>/dev/null
                unset ip_verify_timers["$player_name_upper"]
            fi
            
            unset password_pending["$player_name_upper"]
            unset ip_verify_pending["$player_name_upper"]
            
            sync_server_lists
            continue
        fi
        
        # Detectar comandos de chat
        if [[ "$line" =~ ([a-zA-Z0-9_]+):\ (.+)$ ]]; then
            local player_name="${BASH_REMATCH[1]}"
            local message="${BASH_REMATCH[2]}"
            local player_name_upper=$(echo "$player_name" | tr '[:lower:]' '[:upper:]')
            
            [ "$player_name" = "SERVER" ] && continue
            
            case "$message" in
                "!password "*)
                    if [[ "$message" =~ !password\ ([^ ]+)\ ([^ ]+) ]]; then
                        local password="${BASH_REMATCH[1]}"
                        local confirm_password="${BASH_REMATCH[2]}"
                        print_status "Password command received from $player_name"
                        handle_password_command "$player_name" "$password" "$confirm_password"
                    else
                        send_server_command "Usage: !password NEW_PASSWORD CONFIRM_PASSWORD"
                    fi
                    ;;
                "!ip_change "*)
                    if [[ "$message" =~ !ip_change\ ([^ ]+) ]]; then
                        local password="${BASH_REMATCH[1]}"
                        local current_ip="${player_ip_map[$player_name_upper]}"
                        print_status "IP change command received from $player_name"
                        handle_ip_change "$player_name" "$password" "$current_ip"
                    else
                        send_server_command "Usage: !ip_change YOUR_PASSWORD"
                    fi
                    ;;
            esac
        fi
    done
}

main() {
    print_header "THE BLOCKHEADS RANK PATCHER - OPTIMIZED VERSION"
    print_status "World: $WORLD_ID"
    print_status "Port: ${PORT:-12153}"
    print_status "Console log: $CONSOLE_LOG"
    print_status "Players log: $PLAYERS_LOG"
    
    # Test de comunicación primero
    if ! test_server_communication; then
        print_error "Server communication test failed - cannot continue"
        exit 1
    fi
    
    initialize_players_log
    sync_server_lists
    
    # Iniciar monitores en paralelo
    print_header "STARTING MONITORS"
    
    monitor_console_log &
    local console_pid=$!
    
    monitor_players_log_changes &
    local players_pid=$!
    
    print_success "All monitors started successfully"
    print_status "Console monitor PID: $console_pid"
    print_status "Players log monitor PID: $players_pid"
    print_status "Commands log: /tmp/rank_patcher_commands.log"
    
    # Esperar a que cualquiera de los procesos termine
    wait -n
    print_error "One of the monitors stopped - terminating all processes"
    
    kill $console_pid $players_pid 2>/dev/null
    exit 1
}

main "$@"
