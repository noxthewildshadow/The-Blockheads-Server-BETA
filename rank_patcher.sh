#!/bin/bash

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

print_error() { echo -e "${RED}[RANK_PATCHER_ERROR]${NC} $1"; }
print_success() { echo -e "${GREEN}[RANK_PATCHER_SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[RANK_PATCHER_WARNING]${NC} $1"; }
print_status() { echo -e "${BLUE}[RANK_PATCHER_INFO]${NC} $1"; }
print_debug() { echo -e "${CYAN}[RANK_PATCHER_DEBUG]${NC} $1"; }

# Configuration
WORLD_ID="$1"
PORT="$2"
SAVES_DIR="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads"
WORLD_DIR="$SAVES_DIR/saves/$WORLD_ID"
PLAYERS_LOG="$WORLD_DIR/players.log"
CONSOLE_LOG="$WORLD_DIR/console.log"
ADMIN_LIST="$WORLD_DIR/adminlist.txt"
MOD_LIST="$WORLD_DIR/modlist.txt"
WHITE_LIST="$WORLD_DIR/whitelist.txt"
BLACK_LIST="$WORLD_DIR/blacklist.txt"
CLOUD_ADMIN_LIST="$SAVES_DIR/cloudWideOwnedAdminlist.txt"

# Create necessary directories and files
mkdir -p "$WORLD_DIR"
mkdir -p "$SAVES_DIR"
touch "$PLAYERS_LOG" "$CONSOLE_LOG" "$ADMIN_LIST" "$MOD_LIST" "$WHITE_LIST" "$BLACK_LIST" "$CLOUD_ADMIN_LIST"

# Player tracking arrays
declare -A PLAYER_DATA
declare -A PLAYER_COOLDOWNS
declare -A PLAYER_JOIN_TIMES
declare -A PLAYER_IP_VERIFICATION
declare -A PLAYER_HASHES

# Load existing player data
load_player_data() {
    if [ ! -f "$PLAYERS_LOG" ]; then
        return
    fi
    
    while IFS='|' read -r name first_ip current_ip password rank whitelisted blacklisted; do
        name=$(echo "$name" | xargs)
        first_ip=$(echo "$first_ip" | xargs)
        current_ip=$(echo "$current_ip" | xargs)
        password=$(echo "$password" | xargs)
        rank=$(echo "$rank" | xargs)
        whitelisted=$(echo "$whitelisted" | xargs)
        blacklisted=$(echo "$blacklisted" | xargs)
        
        if [ -n "$name" ] && [ "$name" != "UNKNOWN" ]; then
            PLAYER_DATA["${name}_first_ip"]="$first_ip"
            PLAYER_DATA["${name}_current_ip"]="$current_ip"
            PLAYER_DATA["${name}_password"]="$password"
            PLAYER_DATA["${name}_rank"]="$rank"
            PLAYER_DATA["${name}_whitelisted"]="$whitelisted"
            PLAYER_DATA["${name}_blacklisted"]="$blacklisted"
        fi
    done < "$PLAYERS_LOG"
}

# Save player data to file
save_player_data() {
    > "$PLAYERS_LOG"
    for key in "${!PLAYER_DATA[@]}"; do
        if [[ $key == *"_first_ip" ]]; then
            player_name="${key%_first_ip}"
            first_ip="${PLAYER_DATA[${player_name}_first_ip]}"
            current_ip="${PLAYER_DATA[${player_name}_current_ip]:-UNKNOWN}"
            password="${PLAYER_DATA[${player_name}_password]:-NONE}"
            rank="${PLAYER_DATA[${player_name}_rank]:-NONE}"
            whitelisted="${PLAYER_DATA[${player_name}_whitelisted]:-NO}"
            blacklisted="${PLAYER_DATA[${player_name}_blacklisted]:-NO}"
            
            echo "$player_name | $first_ip | $current_ip | $password | $rank | $whitelisted | $blacklisted" >> "$PLAYERS_LOG"
        fi
    done
}

# Update server lists based on players.log (ignorar primeras 2 líneas)
update_server_lists() {
    # Limpiar listas pero mantener las 2 primeras líneas
    for list_file in "$ADMIN_LIST" "$MOD_LIST" "$WHITE_LIST" "$BLACK_LIST"; do
        if [ -f "$list_file" ]; then
            local temp_file=$(mktemp)
            # Mantener las 2 primeras líneas
            head -n 2 "$list_file" > "$temp_file" 2>/dev/null || true
            # Agregar nuevos nombres desde la línea 3
            tail -n +3 "$temp_file" > "$list_file" 2>/dev/null || true
            rm -f "$temp_file"
        else
            # Crear archivo con 2 líneas vacías
            echo -e "\n" > "$list_file"
        fi
    done
    
    # Agregar jugadores a las listas
    for key in "${!PLAYER_DATA[@]}"; do
        if [[ $key == *"_rank" ]]; then
            player_name="${key%_rank}"
            rank="${PLAYER_DATA[$key]}"
            whitelisted="${PLAYER_DATA[${player_name}_whitelisted]}"
            blacklisted="${PLAYER_DATA[${player_name}_blacklisted]}"
            current_ip="${PLAYER_DATA[${player_name}_current_ip]}"
            
            # Solo agregar a listas si está verificado y no está blacklisted
            if [ "$current_ip" != "UNKNOWN" ] && [ "$blacklisted" = "NO" ]; then
                case "$rank" in
                    "ADMIN") 
                        echo "$player_name" >> "$ADMIN_LIST"
                        ;;
                    "MOD") 
                        echo "$player_name" >> "$MOD_LIST"
                        ;;
                    "SUPER") 
                        echo "$player_name" >> "$ADMIN_LIST"
                        echo "$player_name" >> "$CLOUD_ADMIN_LIST"
                        ;;
                esac
                
                if [ "$whitelisted" = "YES" ]; then
                    echo "$player_name" >> "$WHITE_LIST"
                fi
            fi
            
            if [ "$blacklisted" = "YES" ]; then
                echo "$player_name" >> "$BLACK_LIST"
                echo "$current_ip" >> "$BLACK_LIST" 2>/dev/null || true
            fi
        fi
    done
}

# Execute server command
server_command() {
    local cmd="$1"
    local screen_session="blockheads_server_$PORT"
    
    if screen -list | grep -q "$screen_session"; then
        screen -S "$screen_session" -X stuff "$cmd^M"
        return 0
    else
        print_error "Server screen session not found: $screen_session"
        return 1
    fi
}

# Send chat message (sin /)
chat_message() {
    local message="$1"
    server_command "$message"
}

# Monitor console.log for player commands
monitor_console() {
    local last_size=0
    
    while true; do
        if [ -f "$CONSOLE_LOG" ]; then
            local current_size=$(stat -c%s "$CONSOLE_LOG" 2>/dev/null || echo 0)
            
            if [ "$current_size" -gt "$last_size" ]; then
                local new_content=$(tail -c +$((last_size + 1)) "$CONSOLE_LOG" 2>/dev/null || echo "")
                
                while IFS= read -r line; do
                    [ -n "$line" ] && process_console_line "$line"
                done <<< "$new_content"
                
                last_size=$current_size
            fi
        fi
        
        sleep 0.25
    done
}

# Process console line for commands
process_console_line() {
    local line="$1"
    
    # Check for player chat messages - formato: JUGADOR: mensaje
    if [[ "$line" =~ ([A-Za-z0-9_]+):[[:space:]]+(!.+) ]]; then
        local player_name="${BASH_REMATCH[1]}"
        local message="${BASH_REMATCH[2]}"
        
        process_player_command "$player_name" "$message"
    fi
    
    # Check for player connections
    if [[ "$line" =~ .*" - Player Connected "(.*)" | "(.*)" | "(.*) ]]; then
        local player_name="${BASH_REMATCH[1]}"
        local player_ip="${BASH_REMATCH[2]}"
        local player_hash="${BASH_REMATCH[3]}"
        
        handle_player_connect "$player_name" "$player_ip" "$player_hash"
    fi
    
    # Check for player disconnections
    if [[ "$line" =~ .*" - Client disconnected:"(.*) ]]; then
        local player_hash="${BASH_REMATCH[1]}"
        handle_player_disconnect "$player_hash"
    fi
}

# Handle player connection
handle_player_connect() {
    local player_name="$1"
    local player_ip="$2"
    local player_hash="$3"
    
    print_status "Player connected: $player_name ($player_ip) - Hash: $player_hash"
    
    # Guardar hash del jugador
    PLAYER_HASHES["$player_hash"]="$player_name"
    
    # Record join time
    PLAYER_JOIN_TIMES["$player_name"]=$(date +%s)
    
    # Verificar si el jugador ya existe en players.log
    local existing_data=0
    if [ -n "${PLAYER_DATA[${player_name}_first_ip]}" ]; then
        existing_data=1
    fi
    
    if [ "$existing_data" -eq 0 ]; then
        # Jugador nuevo
        PLAYER_DATA["${player_name}_first_ip"]="$player_ip"
        PLAYER_DATA["${player_name}_current_ip"]="$player_ip"
        PLAYER_DATA["${player_name}_password"]="NONE"
        PLAYER_DATA["${player_name}_rank"]="NONE"
        PLAYER_DATA["${player_name}_whitelisted"]="NO"
        PLAYER_DATA["${player_name}_blacklisted"]="NO"
        
        chat_message "Welcome $player_name! Please set your password with !password NEW_PASSWORD CONFIRM_PASSWORD within 60 seconds."
        chat_message "You have 60 seconds to set your password or you will be kicked."
    else
        # Jugador existente - NO SOBRESCRIBIR RANGO, solo actualizar IP
        local stored_first_ip="${PLAYER_DATA[${player_name}_first_ip]}"
        local stored_current_ip="${PLAYER_DATA[${player_name}_current_ip]}"
        
        # Verificar si la IP ha cambiado
        if [ "$stored_first_ip" != "$player_ip" ] && [ "$stored_first_ip" != "UNKNOWN" ]; then
            # IP ha cambiado - requerir verificación
            PLAYER_IP_VERIFICATION["$player_name"]="PENDING"
            PLAYER_DATA["${player_name}_current_ip"]="$player_ip"
            
            chat_message "IP change detected for $player_name! Verify with !ip_change YOUR_PASSWORD within 30 seconds."
            chat_message "You have 30 seconds to verify your IP or you will be temporarily banned."
        else
            # IP coincide o es la primera vez - actualizar IP actual
            PLAYER_DATA["${player_name}_current_ip"]="$player_ip"
            PLAYER_IP_VERIFICATION["$player_name"]="VERIFIED"
        fi
    fi
    
    save_player_data
    update_server_lists
    
    # Aplicar rango actual al jugador
    apply_player_rank "$player_name"
}

# Handle player disconnect
handle_player_disconnect() {
    local player_hash="$1"
    local player_name="${PLAYER_HASHES[$player_hash]}"
    
    if [ -n "$player_name" ]; then
        print_status "Player disconnected: $player_name ($player_hash)"
        unset PLAYER_HASHES["$player_hash"]
        unset PLAYER_JOIN_TIMES["$player_name"]
        unset PLAYER_IP_VERIFICATION["$player_name"]
    else
        print_status "Player disconnected: $player_hash"
    fi
}

# Apply rank to player
apply_player_rank() {
    local player_name="$1"
    local rank="${PLAYER_DATA[${player_name}_rank]}"
    local blacklisted="${PLAYER_DATA[${player_name}_blacklisted]}"
    
    if [ "$blacklisted" = "YES" ]; then
        server_command "/unmod $player_name"
        server_command "/unadmin $player_name"
        server_command "/ban $player_name"
        return
    fi
    
    case "$rank" in
        "ADMIN")
            server_command "/admin $player_name"
            server_command "/unmod $player_name"
            ;;
        "MOD")
            server_command "/mod $player_name"
            server_command "/unadmin $player_name"
            ;;
        "SUPER")
            server_command "/admin $player_name"
            server_command "/unmod $player_name"
            echo "$player_name" >> "$CLOUD_ADMIN_LIST"
            ;;
        "NONE"|*)
            server_command "/unadmin $player_name"
            server_command "/unmod $player_name"
            ;;
    esac
}

# Process player commands
process_player_command() {
    local player_name="$1"
    local message="$2"
    
    case "$message" in
        !password*)
            handle_password_set "$player_name" "$message"
            ;;
        !ip_change*)
            handle_ip_change "$player_name" "$message"
            ;;
        !change_psw*)
            handle_password_change "$player_name" "$message"
            ;;
    esac
}

# Handle password set command
handle_password_set() {
    local player_name="$1"
    local message="$2"
    
    # Extract password and confirmation
    if [[ "$message" =~ !password[[:space:]]+([^[:space:]]+)[[:space:]]+([^[:space:]]+) ]]; then
        local password="${BASH_REMATCH[1]}"
        local confirm="${BASH_REMATCH[2]}"
        
        # Clear chat for security
        server_command "/clear"
        sleep 0.5
        
        # Validate password
        if [ "${#password}" -lt 7 ]; then
            chat_message "Error: Password must be at least 7 characters long."
            return
        fi
        
        if [ "${#password}" -gt 16 ]; then
            chat_message "Error: Password must be at most 16 characters long."
            return
        fi
        
        if [ "$password" != "$confirm" ]; then
            chat_message "Error: Passwords do not match."
            return
        fi
        
        # Set password
        PLAYER_DATA["${player_name}_password"]="$password"
        PLAYER_IP_VERIFICATION["$player_name"]="VERIFIED"
        save_player_data
        
        chat_message "Password set successfully for $player_name! Your IP is now verified."
        print_success "Player $player_name set password successfully"
        
        # Aplicar rango después de establecer contraseña
        apply_player_rank "$player_name"
    else
        chat_message "Usage: !password NEW_PASSWORD CONFIRM_PASSWORD"
    fi
}

# Handle IP change verification
handle_ip_change() {
    local player_name="$1"
    local message="$2"
    
    if [[ "$message" =~ !ip_change[[:space:]]+(.+) ]]; then
        local password="${BASH_REMATCH[1]}"
        
        # Clear chat for security
        server_command "/clear"
        sleep 0.5
        
        local stored_password="${PLAYER_DATA[${player_name}_password]}"
        
        if [ "$stored_password" = "NONE" ]; then
            chat_message "Error: You need to set a password first with !password."
            return
        fi
        
        if [ "$password" = "$stored_password" ]; then
            # IP verified successfully
            PLAYER_IP_VERIFICATION["$player_name"]="VERIFIED"
            chat_message "IP verification successful for $player_name!"
            unset PLAYER_COOLDOWNS["$player_name"]
            print_success "Player $player_name verified IP change"
        else
            chat_message "Error: Incorrect password for $player_name."
        fi
    else
        chat_message "Usage: !ip_change YOUR_PASSWORD"
    fi
}

# Handle password change
handle_password_change() {
    local player_name="$1"
    local message="$2"
    
    if [[ "$message" =~ !change_psw[[:space:]]+([^[:space:]]+)[[:space:]]+([^[:space:]]+) ]]; then
        local old_password="${BASH_REMATCH[1]}"
        local new_password="${BASH_REMATCH[2]}"
        
        # Clear chat for security
        server_command "/clear"
        sleep 0.5
        
        local stored_password="${PLAYER_DATA[${player_name}_password]}"
        
        if [ "$stored_password" = "NONE" ]; then
            chat_message "Error: You don't have a password set yet."
            return
        fi
        
        if [ "$old_password" != "$stored_password" ]; then
            chat_message "Error: Old password is incorrect."
            return
        fi
        
        if [ "${#new_password}" -lt 7 ]; then
            chat_message "Error: New password must be at least 7 characters long."
            return
        fi
        
        if [ "${#new_password}" -gt 16 ]; then
            chat_message "Error: New password must be at most 16 characters long."
            return
        fi
        
        # Change password
        PLAYER_DATA["${player_name}_password"]="$new_password"
        save_player_data
        
        chat_message "Password changed successfully for $player_name!"
        print_success "Player $player_name changed password"
    else
        chat_message "Usage: !change_psw OLD_PASSWORD NEW_PASSWORD"
    fi
}

# Monitor players.log for manual changes
monitor_players_log() {
    local last_hash=$(md5sum "$PLAYERS_LOG" 2>/dev/null | cut -d' ' -f1)
    
    while true; do
        local current_hash=$(md5sum "$PLAYERS_LOG" 2>/dev/null | cut -d' ' -f1)
        
        if [ "$current_hash" != "$last_hash" ] || [ -z "$last_hash" ]; then
            print_status "players.log changed, applying updates..."
            
            # Recargar datos pero preservar información de sesión actual
            declare -A OLD_DATA=()
            for key in "${!PLAYER_DATA[@]}"; do
                OLD_DATA["$key"]="${PLAYER_DATA[$key]}"
            done
            
            load_player_data
            
            # Preservar IPs actuales de jugadores conectados
            for player_name in "${!PLAYER_JOIN_TIMES[@]}"; do
                if [ -n "${OLD_DATA[${player_name}_current_ip]}" ]; then
                    PLAYER_DATA["${player_name}_current_ip"]="${OLD_DATA[${player_name}_current_ip]}"
                fi
            done
            
            apply_rank_changes
            update_server_lists
            last_hash="$current_hash"
        fi
        
        sleep 1
    done
}

# Apply rank changes from players.log
apply_rank_changes() {
    for key in "${!PLAYER_DATA[@]}"; do
        if [[ $key == *"_rank" ]]; then
            local player_name="${key%_rank}"
            local current_rank="${PLAYER_DATA[$key]}"
            local blacklisted="${PLAYER_DATA[${player_name}_blacklisted]}"
            
            # Handle blacklist changes
            if [ "$blacklisted" = "YES" ]; then
                server_command "/unmod $player_name"
                server_command "/unadmin $player_name"
                server_command "/ban $player_name"
                local player_ip="${PLAYER_DATA[${player_name}_current_ip]}"
                if [ "$player_ip" != "UNKNOWN" ]; then
                    server_command "/ban $player_ip"
                fi
                
                # Remove from cloud admin list if SUPER
                if [ "$current_rank" = "SUPER" ]; then
                    sed -i "/^$player_name$/d" "$CLOUD_ADMIN_LIST" 2>/dev/null || true
                fi
            else
                # Handle rank changes
                case "$current_rank" in
                    "ADMIN")
                        server_command "/admin $player_name"
                        server_command "/unmod $player_name"
                        ;;
                    "MOD")
                        server_command "/mod $player_name"
                        server_command "/unadmin $player_name"
                        ;;
                    "SUPER")
                        server_command "/admin $player_name"
                        server_command "/unmod $player_name"
                        echo "$player_name" >> "$CLOUD_ADMIN_LIST"
                        ;;
                    "NONE")
                        server_command "/unadmin $player_name"
                        server_command "/unmod $player_name"
                        # Remove from cloud admin list if was SUPER
                        sed -i "/^$player_name$/d" "$CLOUD_ADMIN_LIST" 2>/dev/null || true
                        ;;
                esac
            fi
        fi
    done
}

# Monitor player cooldowns and verification timeouts
monitor_player_timeouts() {
    while true; do
        local current_time=$(date +%s)
        
        for player_name in "${!PLAYER_JOIN_TIMES[@]}"; do
            local join_time="${PLAYER_JOIN_TIMES[$player_name]}"
            local time_connected=$((current_time - join_time))
            
            # Check password set timeout (60 seconds)
            if [ "${PLAYER_DATA[${player_name}_password]}" = "NONE" ] && [ "$time_connected" -gt 60 ]; then
                server_command "/kick $player_name"
                chat_message "$player_name was kicked for not setting a password within 60 seconds."
                unset PLAYER_JOIN_TIMES["$player_name"]
                unset PLAYER_IP_VERIFICATION["$player_name"]
                print_warning "Kicked $player_name for not setting password"
            fi
            
            # Check IP verification timeout (30 seconds) - solo si la IP cambió
            local stored_first_ip="${PLAYER_DATA[${player_name}_first_ip]}"
            local stored_current_ip="${PLAYER_DATA[${player_name}_current_ip]}"
            local verification_status="${PLAYER_IP_VERIFICATION[$player_name]}"
            
            if [ "$stored_first_ip" != "$stored_current_ip" ] && 
               [ "$stored_first_ip" != "UNKNOWN" ] && 
               [ "$stored_current_ip" != "UNKNOWN" ] &&
               [ "$verification_status" = "PENDING" ]; then
                
                if [ "$time_connected" -gt 30 ] && [ -z "${PLAYER_COOLDOWNS[$player_name]}" ]; then
                    server_command "/kick $player_name"
                    server_command "/ban $stored_current_ip"
                    chat_message "$player_name was banned for 30 seconds for not verifying IP change."
                    PLAYER_COOLDOWNS["$player_name"]=$current_time
                    print_warning "Kicked and temp-banned $player_name for IP verification timeout"
                fi
            fi
        done
        
        # Clean up old cooldowns
        for player_name in "${!PLAYER_COOLDOWNS[@]}"; do
            local cooldown_time="${PLAYER_COOLDOWNS[$player_name]}"
            if [ $((current_time - cooldown_time)) -gt 60 ]; then
                local player_ip="${PLAYER_DATA[${player_name}_current_ip]}"
                if [ "$player_ip" != "UNKNOWN" ]; then
                    server_command "/unban $player_ip"
                fi
                unset PLAYER_COOLDOWNS["$player_name"]
                print_status "Removed temp ban for $player_name"
            fi
        done
        
        sleep 5
    done
}

# Main function
main() {
    if [ -z "$WORLD_ID" ]; then
        print_error "Usage: $0 <world_id> [port]"
        exit 1
    fi
    
    if [ -z "$PORT" ]; then
        PORT=12153
    fi
    
    print_header "Starting Rank Patcher for World: $WORLD_ID, Port: $PORT"
    print_status "Players log: $PLAYERS_LOG"
    print_status "Console log: $CONSOLE_LOG"
    print_status "Cloud admin list: $CLOUD_ADMIN_LIST"
    
    # Load initial player data
    load_player_data
    update_server_lists
    
    # Start monitoring processes in background
    monitor_console &
    console_pid=$!
    monitor_players_log &
    players_log_pid=$!
    monitor_player_timeouts &
    timeouts_pid=$!
    
    print_success "Rank patcher started successfully with all monitors"
    print_status "Monitor PIDs: Console=$console_pid, PlayersLog=$players_log_pid, Timeouts=$timeouts_pid"
    
    # Wait for all background processes
    wait
}

# Trap signals to clean up background processes
cleanup() {
    print_status "Stopping rank patcher..."
    kill $console_pid $players_log_pid $timeouts_pid 2>/dev/null
    exit 0
}

trap cleanup EXIT INT TERM

# Start the main function
main "$@"
