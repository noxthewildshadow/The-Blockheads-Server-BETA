#!/bin/bash

# rank_patcher.sh - Complete Player Management System for The Blockheads
# Monitors console.log and manages players.log as central authority

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

# Configuration
BASE_DIR="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves"
CONSOLE_LOG="$1"
WORLD_ID="$2"
PORT="$3"

# Extract world ID from console log path if not provided
if [ -z "$WORLD_ID" ] && [ -n "$CONSOLE_LOG" ]; then
    WORLD_ID=$(echo "$CONSOLE_LOG" | grep -oE 'saves/[^/]+' | cut -d'/' -f2)
fi

# Validate parameters
if [ -z "$CONSOLE_LOG" ] || [ -z "$WORLD_ID" ]; then
    print_error "Usage: $0 <console_log_path> [world_id] [port]"
    print_status "Example: $0 /path/to/console.log world123 12153"
    exit 1
fi

# File paths
PLAYERS_LOG="$BASE_DIR/$WORLD_ID/players.log"
ADMIN_LIST="$BASE_DIR/$WORLD_ID/adminlist.txt"
MOD_LIST="$BASE_DIR/$WORLD_ID/modlist.txt"
WHITELIST="$BASE_DIR/$WORLD_ID/whitelist.txt"
BLACKLIST="$BASE_DIR/$WORLD_ID/blacklist.txt"
CLOUD_ADMIN_LIST="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/cloudWideOwnedAdminlist.txt"

# Screen session for server commands
SCREEN_SERVER="blockheads_server_${PORT:-12153}"

# Cooldown configuration
COMMAND_COOLDOWN=0.5
PASSWORD_TIMEOUT=30
IP_VERIFY_TIMEOUT=30
IP_BAN_DURATION=30

# Track connected players and their states
declare -A connected_players
declare -A player_ip_map
declare -A password_pending
declare -A ip_verify_pending
declare -A ip_banned_times
declare -A last_command_time
declare -A player_join_time
declare -A player_original_rank

# Function to send commands to server with cooldown
send_server_command() {
    local command="$1"
    local current_time=$(date +%s)
    
    # Check cooldown
    if [ -n "${last_command_time[$command]}" ]; then
        local time_diff=$((current_time - last_command_time[$command]))
        if [ $time_diff -lt ${COMMAND_COOLDOWN%.*} ]; then
            sleep $((COMMAND_COOLDOWN%.* - time_diff))
        fi
    fi
    
    if screen -S "$SCREEN_SERVER" -X stuff "$command$(printf \\r)" 2>/dev/null; then
        print_success "Sent command: $command"
        last_command_time[$command]=$(date +%s)
        return 0
    else
        print_error "Failed to send command: $command"
        return 1
    fi
}

# Function to clear chat
clear_chat() {
    send_server_command "/clear"
    sleep "$COMMAND_COOLDOWN"
}

# Function to remove player from privilege lists when disconnected (CORREGIDA)
remove_player_from_lists() {
    local player_name="$1"
    
    print_status "Removing $player_name from privilege lists due to disconnection"
    
    # Remove only from privilege lists, NOT from whitelist/blacklist
    # Remove from adminlist.txt
    if [ -f "$ADMIN_LIST" ]; then
        temp_file=$(mktemp)
        head -n 2 "$ADMIN_LIST" > "$temp_file"
        tail -n +3 "$ADMIN_LIST" 2>/dev/null | grep -v "^$player_name$" >> "$temp_file"
        mv "$temp_file" "$ADMIN_LIST"
    fi
    
    # Remove from modlist.txt
    if [ -f "$MOD_LIST" ]; then
        temp_file=$(mktemp)
        head -n 2 "$MOD_LIST" > "$temp_file"
        tail -n +3 "$MOD_LIST" 2>/dev/null | grep -v "^$player_name$" >> "$temp_file"
        mv "$temp_file" "$MOD_LIST"
    fi
    
    # Remove from cloudWideOwnedAdminlist.txt
    if [ -f "$CLOUD_ADMIN_LIST" ]; then
        temp_file=$(mktemp)
        head -n 2 "$CLOUD_ADMIN_LIST" > "$temp_file"
        tail -n +3 "$CLOUD_ADMIN_LIST" 2>/dev/null | grep -v "^$player_name$" >> "$temp_file"
        mv "$temp_file" "$CLOUD_ADMIN_LIST"
    fi
    
    # NO remover de whitelist.txt y blacklist.txt - estas son persistentes
    # whitelist y blacklist se mantienen incluso cuando el jugador se desconecta
    
    print_success "Removed $player_name from privilege lists (admin/mod/super)"
}

# Function to restore player rank if IP is verified (NUEVA)
restore_player_rank() {
    local player_name="$1"
    
    if [ -n "${player_original_rank[$player_name]}" ]; then
        local original_rank="${player_original_rank[$player_name]}"
        read_players_log
        
        # Only restore if player has password and verified IP
        local password="${players_data["$player_name,password"]}"
        local ip="${players_data["$player_name,ip"]}"
        
        if [ "$password" != "NONE" ] && [ "$ip" != "UNKNOWN" ]; then
            print_status "Restoring original rank $original_rank to $player_name"
            update_players_log "$player_name" "rank" "$original_rank"
            
            # Apply the rank commands
            case "$original_rank" in
                "ADMIN")
                    send_server_command "/admin $player_name"
                    ;;
                "MOD")
                    send_server_command "/mod $player_name"
                    ;;
                "SUPER")
                    if ! tail -n +3 "$CLOUD_ADMIN_LIST" 2>/dev/null | grep -q "^$player_name$"; then
                        echo "$player_name" >> "$CLOUD_ADMIN_LIST"
                    fi
                    send_server_command "/admin $player_name"
                    ;;
            esac
        fi
        
        # Clear the stored original rank
        unset player_original_rank["$player_name"]
    fi
}

# Function to initialize players.log with correct format (CORREGIDA)
initialize_players_log() {
    if [ ! -f "$PLAYERS_LOG" ]; then
        print_status "Creating new players.log file"
        mkdir -p "$(dirname "$PLAYERS_LOG")"
        echo "# Player Name | First IP | Password | Rank | Whitelisted | Blacklisted" > "$PLAYERS_LOG"
        echo "# Format: PLAYER_NAME | IP | PASSWORD | RANK | WHITELISTED | BLACKLISTED" >> "$PLAYERS_LOG"
        print_success "players.log created at: $PLAYERS_LOG"
    else
        # Reformat existing file to remove extra spaces
        temp_file=$(mktemp)
        {
            echo "# Player Name | First IP | Password | Rank | Whitelisted | Blacklisted"
            echo "# Format: PLAYER_NAME | IP | PASSWORD | RANK | WHITELISTED | BLACKLISTED"
            
            # Re-read and reformat existing data
            if [ -f "$PLAYERS_LOG" ]; then
                while IFS='|' read -r name ip password rank whitelisted blacklisted; do
                    # Skip header lines and empty lines
                    if [[ "$name" =~ ^# ]] || [ -z "$(echo "$name" | xargs)" ]; then
                        continue
                    fi
                    
                    # Clean up fields
                    name=$(echo "$name" | xargs)
                    ip=$(echo "$ip" | xargs)
                    password=$(echo "$password" | xargs)
                    rank=$(echo "$rank" | xargs)
                    whitelisted=$(echo "$whitelisted" | xargs)
                    blacklisted=$(echo "$blacklisted" | xargs)
                    
                    # Apply defaults
                    [ -z "$name" ] && name="UNKNOWN"
                    [ -z "$ip" ] && ip="UNKNOWN"
                    [ -z "$password" ] && password="NONE"
                    [ -z "$rank" ] && rank="NONE"
                    [ -z "$whitelisted" ] && whitelisted="NO"
                    [ -z "$blacklisted" ] && blacklisted="NO"
                    
                    if [ "$name" != "UNKNOWN" ]; then
                        printf "%s | %s | %s | %s | %s | %s\n" \
                            "$name" "$ip" "$password" "$rank" "$whitelisted" "$blacklisted"
                    fi
                done < "$PLAYERS_LOG"
            fi
        } > "$temp_file"
        
        mv "$temp_file" "$PLAYERS_LOG"
        print_success "players.log reformatted to remove extra spaces"
    fi
}

# Function to read players.log into associative array (CORREGIDA)
read_players_log() {
    declare -gA players_data
    local line_count=0
    
    if [ ! -f "$PLAYERS_LOG" ]; then
        print_error "players.log not found: $PLAYERS_LOG"
        return 1
    fi
    
    while IFS='|' read -r name ip password rank whitelisted blacklisted; do
        # Skip header lines and empty lines
        if [[ "$name" =~ ^# ]] || [ -z "$(echo "$name" | xargs)" ]; then
            continue
        fi
        
        # Clean up fields and apply correct defaults
        name=$(echo "$name" | xargs)
        ip=$(echo "$ip" | xargs)
        password=$(echo "$password" | xargs)
        rank=$(echo "$rank" | xargs)
        whitelisted=$(echo "$whitelisted" | xargs)
        blacklisted=$(echo "$blacklisted" | xargs)
        
        # Apply required defaults
        [ -z "$name" ] && name="UNKNOWN"
        [ -z "$ip" ] && ip="UNKNOWN"
        [ -z "$password" ] && password="NONE"
        [ -z "$rank" ] && rank="NONE"
        [ -z "$whitelisted" ] && whitelisted="NO"
        [ -z "$blacklisted" ] && blacklisted="NO"
        
        if [ "$name" != "UNKNOWN" ]; then
            players_data["$name,name"]="$name"
            players_data["$name,ip"]="$ip"
            players_data["$name,password"]="$password"
            players_data["$name,rank"]="$rank"
            players_data["$name,whitelisted"]="$whitelisted"
            players_data["$name,blacklisted"]="$blacklisted"
        fi
    done < "$PLAYERS_LOG"
}

# Function to update players.log with correct format (CORREGIDA)
update_players_log() {
    local player_name="$1" field="$2" new_value="$3"
    
    if [ -z "$player_name" ] || [ -z "$field" ]; then
        print_error "Invalid parameters for update_players_log"
        return 1
    fi
    
    # Read current data
    read_players_log
    
    # Update the field
    case "$field" in
        "ip") players_data["$player_name,ip"]="$new_value" ;;
        "password") players_data["$player_name,password"]="$new_value" ;;
        "rank") players_data["$player_name,rank"]="$new_value" ;;
        "whitelisted") players_data["$player_name,whitelisted"]="$new_value" ;;
        "blacklisted") players_data["$player_name,blacklisted"]="$new_value" ;;
        *) print_error "Unknown field: $field"; return 1 ;;
    esac
    
    # Write back to file with CORRECT format (sin espacios extra)
    {
        echo "# Player Name | First IP | Password | Rank | Whitelisted | Blacklisted"
        echo "# Format: PLAYER_NAME | IP | PASSWORD | RANK | WHITELISTED | BLACKLISTED"
        
        for key in "${!players_data[@]}"; do
            if [[ "$key" == *,name ]]; then
                local name="${players_data[$key]}"
                local ip="${players_data["$name,ip"]:-UNKNOWN}"
                local password="${players_data["$name,password"]:-NONE}"
                local rank="${players_data["$name,rank"]:-NONE}"
                local whitelisted="${players_data["$name,whitelisted"]:-NO}"
                local blacklisted="${players_data["$name,blacklisted"]:-NO}"
                
                # FORMATO CORREGIDO: sin espacios extra
                printf "%s | %s | %s | %s | %s | %s\n" \
                    "$name" "$ip" "$password" "$rank" "$whitelisted" "$blacklisted"
            fi
        done
    } > "$PLAYERS_LOG"
    
    print_success "Updated players.log: $player_name $field = $new_value"
}

# Function to add new player to players.log with correct format (CORREGIDA)
add_new_player() {
    local player_name="$1" player_ip="$2"
    
    if [ -z "$player_name" ] || [ -z "$player_ip" ]; then
        print_error "Invalid parameters for add_new_player"
        return 1
    fi
    
    # Check if player already exists
    read_players_log
    if [ -n "${players_data["$player_name,name"]}" ]; then
        print_warning "Player already exists: $player_name"
        return 0
    fi
    
    # Add new player with correct defaults
    players_data["$player_name,name"]="$player_name"
    players_data["$player_name,ip"]="$player_ip"
    players_data["$player_name,password"]="NONE"
    players_data["$player_name,rank"]="NONE"
    players_data["$player_name,whitelisted"]="NO"
    players_data["$player_name,blacklisted"]="NO"
    
    # Write back to file with CORRECT format
    {
        echo "# Player Name | First IP | Password | Rank | Whitelisted | Blacklisted"
        echo "# Format: PLAYER_NAME | IP | PASSWORD | RANK | WHITELISTED | BLACKLISTED"
        
        for key in "${!players_data[@]}"; do
            if [[ "$key" == *,name ]]; then
                local name="${players_data[$key]}"
                local ip="${players_data["$name,ip"]:-UNKNOWN}"
                local password="${players_data["$name,password"]:-NONE}"
                local rank="${players_data["$name,rank"]:-NONE}"
                local whitelisted="${players_data["$name,whitelisted"]:-NO}"
                local blacklisted="${players_data["$name,blacklisted"]:-NO}"
                
                # FORMATO CORREGIDO
                printf "%s | %s | %s | %s | %s | %s\n" \
                    "$name" "$ip" "$password" "$rank" "$whitelisted" "$blacklisted"
            fi
        done
    } > "$PLAYERS_LOG"
    
    print_success "Added new player: $player_name ($player_ip)"
}

# Function to sync server lists from players.log (CORREGIDA - whitelist/blacklist persistentes)
sync_server_lists() {
    print_status "Syncing server lists from players.log..."
    
    # Read current player data
    read_players_log
    
    # Clear existing privilege lists but keep first 2 lines (headers)
    for list_file in "$ADMIN_LIST" "$MOD_LIST"; do
        if [ -f "$list_file" ]; then
            # Keep first two lines (headers) only
            if head -n 2 "$list_file" > "${list_file}.tmp" 2>/dev/null; then
                if [ -s "${list_file}.tmp" ]; then
                    mv "${list_file}.tmp" "$list_file"
                else
                    # Create default headers if file is empty
                    echo "# Usernames in this file are considered admins" > "$list_file"
                    echo "# One username per line" >> "$list_file"
                fi
            else
                # Create with headers if file doesn't exist
                echo "# Usernames in this file are considered admins" > "$list_file"
                echo "# One username per line" >> "$list_file"
            fi
        else
            # Create with headers
            mkdir -p "$(dirname "$list_file")"
            echo "# Usernames in this file are considered admins" > "$list_file"
            echo "# One username per line" >> "$list_file"
        fi
    done
    
    # Sync cloud admin list (ignore first 2 lines)
    if [ ! -f "$CLOUD_ADMIN_LIST" ]; then
        mkdir -p "$(dirname "$CLOUD_ADMIN_LIST")"
        echo "# Cloud-wide admin list" > "$CLOUD_ADMIN_LIST"
        echo "# These players have SUPER rank across all worlds" >> "$CLOUD_ADMIN_LIST"
    else
        # Keep only first 2 lines
        if head -n 2 "$CLOUD_ADMIN_LIST" > "${CLOUD_ADMIN_LIST}.tmp" 2>/dev/null; then
            mv "${CLOUD_ADMIN_LIST}.tmp" "$CLOUD_ADMIN_LIST" 2>/dev/null || true
        fi
    fi
    
    # Para whitelist y blacklist, mantenerlas persistentes - no limpiarlas completamente
    # Solo asegurarse de que existan con headers si no existen
    for list_file in "$WHITELIST" "$BLACKLIST"; do
        if [ ! -f "$list_file" ]; then
            mkdir -p "$(dirname "$list_file")"
            echo "# Usernames in this file are whitelisted" > "$WHITELIST"
            echo "# One username per line" >> "$WHITELIST"
            echo "# Usernames in this file are blacklisted" > "$BLACKLIST"
            echo "# One username per line" >> "$BLACKLIST"
        fi
    done
    
    # Add players to appropriate lists ONLY if they have password and verified IP
    for key in "${!players_data[@]}"; do
        if [[ "$key" == *,name ]]; then
            local name="${players_data[$key]}"
            local ip="${players_data["$name,ip"]}"
            local password="${players_data["$name,password"]}"
            local rank="${players_data["$name,rank"]}"
            local whitelisted="${players_data["$name,whitelisted"]}"
            local blacklisted="${players_data["$name,blacklisted"]}"
            
            # SOLO agregar a listas de privilegios si tiene contraseña y IP verificada
            if [ "$password" != "NONE" ] && [ "$ip" != "UNKNOWN" ]; then
                case "$rank" in
                    "ADMIN")
                        if ! tail -n +3 "$ADMIN_LIST" 2>/dev/null | grep -q "^$name$"; then
                            echo "$name" >> "$ADMIN_LIST"
                        fi
                        ;;
                    "MOD")
                        if ! tail -n +3 "$MOD_LIST" 2>/dev/null | grep -q "^$name$"; then
                            echo "$name" >> "$MOD_LIST"
                        fi
                        ;;
                    "SUPER")
                        if ! tail -n +3 "$CLOUD_ADMIN_LIST" 2>/dev/null | grep -q "^$name$"; then
                            echo "$name" >> "$CLOUD_ADMIN_LIST"
                        fi
                        ;;
                esac
            else
                # Si no tiene password o IP verificada, asegurar que el rango sea NONE
                if [ "$rank" != "NONE" ]; then
                    print_warning "Player $name lacks password or IP verification - resetting rank to NONE"
                    update_players_log "$name" "rank" "NONE"
                fi
            fi
            
            # Para whitelist y blacklist, mantenerlas siempre sincronizadas con players.log
            # sin importar si el jugador está conectado o no
            if [ "$whitelisted" = "YES" ]; then
                if ! tail -n +3 "$WHITELIST" 2>/dev/null | grep -q "^$name$"; then
                    echo "$name" >> "$WHITELIST"
                fi
            else
                # Remover de whitelist si ya no está whitelisted
                if tail -n +3 "$WHITELIST" 2>/dev/null | grep -q "^$name$"; then
                    temp_file=$(mktemp)
                    head -n 2 "$WHITELIST" > "$temp_file"
                    tail -n +3 "$WHITELIST" 2>/dev/null | grep -v "^$name$" >> "$temp_file"
                    mv "$temp_file" "$WHITELIST"
                fi
            fi
            
            if [ "$blacklisted" = "YES" ]; then
                if ! tail -n +3 "$BLACKLIST" 2>/dev/null | grep -q "^$name$"; then
                    echo "$name" >> "$BLACKLIST"
                fi
            else
                # Remover de blacklist si ya no está blacklisted
                if tail -n +3 "$BLACKLIST" 2>/dev/null | grep -q "^$name$"; then
                    temp_file=$(mktemp)
                    head -n 2 "$BLACKLIST" > "$temp_file"
                    tail -n +3 "$BLACKLIST" 2>/dev/null | grep -v "^$name$" >> "$temp_file"
                    mv "$temp_file" "$BLACKLIST"
                fi
            fi
        fi
    done
    
    print_success "Server lists synced"
}

# Function to handle rank changes with cooldown (CORREGIDA)
handle_rank_change() {
    local player_name="$1" old_rank="$2" new_rank="$3"
    
    # Si no hay cambio real, salir
    if [ "$old_rank" = "$new_rank" ]; then
        return 0
    fi
    
    sleep "$COMMAND_COOLDOWN"  # Respect cooldown
    
    # Caso 1: De ADMIN a MOD
    if [ "$old_rank" = "ADMIN" ] && [ "$new_rank" = "MOD" ]; then
        send_server_command "/unadmin $player_name"
        sleep "$COMMAND_COOLDOWN"
        send_server_command "/mod $player_name"
        print_success "Changed $player_name from ADMIN to MOD"
        return 0
    fi
    
    # Caso 2: De MOD a ADMIN
    if [ "$old_rank" = "MOD" ] && [ "$new_rank" = "ADMIN" ]; then
        send_server_command "/unmod $player_name"
        sleep "$COMMAND_COOLDOWN"
        send_server_command "/admin $player_name"
        print_success "Changed $player_name from MOD to ADMIN"
        return 0
    fi
    
    # Caso 3: De ADMIN a NONE
    if [ "$old_rank" = "ADMIN" ] && [ "$new_rank" = "NONE" ]; then
        send_server_command "/unadmin $player_name"
        print_success "Removed ADMIN rank from $player_name"
        return 0
    fi
    
    # Caso 4: De MOD a NONE
    if [ "$old_rank" = "MOD" ] && [ "$new_rank" = "NONE" ]; then
        send_server_command "/unmod $player_name"
        print_success "Removed MOD rank from $player_name"
        return 0
    fi
    
    # Caso 5: De SUPER a cualquier cosa (excepto SUPER)
    if [ "$old_rank" = "SUPER" ] && [ "$new_rank" != "SUPER" ]; then
        # Remove from cloud admin list
        temp_file=$(mktemp)
        head -n 2 "$CLOUD_ADMIN_LIST" > "$temp_file"
        tail -n +3 "$CLOUD_ADMIN_LIST" 2>/dev/null | grep -v "^$player_name$" >> "$temp_file"
        mv "$temp_file" "$CLOUD_ADMIN_LIST"
        
        # También quitar admin/mod si corresponde
        if [ "$new_rank" = "NONE" ]; then
            send_server_command "/unadmin $player_name"
            print_success "Removed SUPER and ADMIN rank from $player_name"
        elif [ "$new_rank" = "MOD" ]; then
            send_server_command "/unadmin $player_name"
            sleep "$COMMAND_COOLDOWN"
            send_server_command "/mod $player_name"
            print_success "Changed $player_name from SUPER to MOD"
        fi
        return 0
    fi
    
    # Caso 6: De NONE a ADMIN
    if [ "$old_rank" = "NONE" ] && [ "$new_rank" = "ADMIN" ]; then
        send_server_command "/admin $player_name"
        print_success "Promoted $player_name to ADMIN"
        return 0
    fi
    
    # Caso 7: De NONE a MOD
    if [ "$old_rank" = "NONE" ] && [ "$new_rank" = "MOD" ]; then
        send_server_command "/mod $player_name"
        print_success "Promoted $player_name to MOD"
        return 0
    fi
    
    # Caso 8: De cualquier cosa a SUPER
    if [ "$new_rank" = "SUPER" ]; then
        # Primero quitar rangos anteriores si existen
        if [ "$old_rank" = "ADMIN" ]; then
            send_server_command "/unadmin $player_name"
            sleep "$COMMAND_COOLDOWN"
        elif [ "$old_rank" = "MOD" ]; then
            send_server_command "/unmod $player_name"
            sleep "$COMMAND_COOLDOWN"
        fi
        
        # Agregar a cloud admin list
        if ! tail -n +3 "$CLOUD_ADMIN_LIST" 2>/dev/null | grep -q "^$player_name$"; then
            echo "$player_name" >> "$CLOUD_ADMIN_LIST"
            print_success "Added $player_name to cloud-wide admin list (SUPER)"
        fi
        
        # También dar admin privileges
        send_server_command "/admin $player_name"
        return 0
    fi
    
    print_warning "Unhandled rank change: $player_name from $old_rank to $new_rank"
}

# Function to handle whitelist changes (NUEVA)
handle_whitelist_change() {
    local player_name="$1" old_whitelisted="$2" new_whitelisted="$3"
    
    # Si no hay cambio real, salir
    if [ "$old_whitelisted" = "$new_whitelisted" ]; then
        return 0
    fi
    
    sleep "$COMMAND_COOLDOWN"  # Respect cooldown
    
    # Caso: NO → YES
    if [ "$old_whitelisted" = "NO" ] && [ "$new_whitelisted" = "YES" ]; then
        send_server_command "/whitelist $player_name"
        print_success "Added $player_name to whitelist"
        return 0
    fi
    
    # Caso: YES → NO
    if [ "$old_whitelisted" = "YES" ] && [ "$new_whitelisted" = "NO" ]; then
        send_server_command "/unwhitelist $player_name"
        print_success "Removed $player_name from whitelist"
        return 0
    fi
}

# Function to handle blacklist changes (CORREGIDA)
handle_blacklist_change() {
    local player_name="$1" old_blacklisted="$2" new_blacklisted="$3" player_ip="$4"
    
    # Si no hay cambio real, salir
    if [ "$old_blacklisted" = "$new_blacklisted" ]; then
        return 0
    fi
    
    sleep "$COMMAND_COOLDOWN"  # Respect cooldown
    
    # Caso: NO → YES (BANEAR)
    if [ "$old_blacklisted" = "NO" ] && [ "$new_blacklisted" = "YES" ]; then
        read_players_log
        local rank="${players_data["$player_name,rank"]}"
        
        # Special handling for SUPER rank - stop server first if connected
        if [ "$rank" = "SUPER" ] && [ -n "${connected_players[$player_name]}" ]; then
            print_warning "SUPER admin blacklisted - stopping server first"
            send_server_command "/stop"
            sleep 2
        fi
        
        # Remove privileges first
        if [ "$rank" = "MOD" ]; then
            send_server_command "/unmod $player_name"
            sleep "$COMMAND_COOLDOWN"
        elif [ "$rank" = "ADMIN" ] || [ "$rank" = "SUPER" ]; then
            send_server_command "/unadmin $player_name"
            sleep "$COMMAND_COOLDOWN"
        fi
        
        # Remove from cloud admin list if SUPER
        if [ "$rank" = "SUPER" ]; then
            temp_file=$(mktemp)
            head -n 2 "$CLOUD_ADMIN_LIST" > "$temp_file"
            tail -n +3 "$CLOUD_ADMIN_LIST" 2>/dev/null | grep -v "^$player_name$" >> "$temp_file"
            mv "$temp_file" "$CLOUD_ADMIN_LIST"
        fi
        
        # Ban player and IP
        send_server_command "/ban $player_name"
        
        if [ "$player_ip" != "UNKNOWN" ]; then
            sleep "$COMMAND_COOLDOWN"
            send_server_command "/ban $player_ip"
            # Track ban time for auto-unban
            ip_banned_times["$player_ip"]=$(date +%s)
        fi
        
        print_success "Banned player: $player_name ($player_ip)"
        return 0
    fi
    
    # Caso: YES → NO (DESBANEAR)
    if [ "$old_blacklisted" = "YES" ] && [ "$new_blacklisted" = "NO" ]; then
        send_server_command "/unban $player_name"
        
        if [ "$player_ip" != "UNKNOWN" ]; then
            sleep "$COMMAND_COOLDOWN"
            send_server_command "/unban $player_ip"
            # Remove from ban tracking
            unset ip_banned_times["$player_ip"]
        fi
        
        print_success "Unbanned player: $player_name ($player_ip)"
        return 0
    fi
}

# Function to auto-unban IP addresses after timeout
auto_unban_ips() {
    local current_time=$(date +%s)
    
    for ip in "${!ip_banned_times[@]}"; do
        local ban_time="${ip_banned_times[$ip]}"
        if [ $((current_time - ban_time)) -ge $IP_BAN_DURATION ]; then
            send_server_command "/unban $ip"
            print_status "Auto-unbanned IP: $ip"
            unset ip_banned_times["$ip"]
        fi
    done
}

# Function to validate password (CORREGIDA)
validate_password() {
    local password="$1"
    local length=${#password}
    
    if [ $length -lt 7 ] || [ $length -gt 16 ]; then
        echo "Password must be between 7 and 16 characters"
        return 1
    fi
    
    # CARACTERES ESPECIALES CORRECTAMENTE ESCAPADOS
    if ! [[ "$password" =~ ^[a-zA-Z0-9!@#$%\&*()_+-=]+$ ]]; then
        echo "Password contains invalid characters"
        return 1
    fi
    
    return 0
}

# Function to handle password commands with clear and cooldown
handle_password_command() {
    local player_name="$1" password="$2" confirm_password="$3"
    
    clear_chat  # Clear chat first
    
    if [ "$password" != "$confirm_password" ]; then
        sleep "$COMMAND_COOLDOWN"
        send_server_command "Passwords do not match"
        return 1
    fi
    
    local validation_result=$(validate_password "$password")
    if [ $? -ne 0 ]; then
        sleep "$COMMAND_COOLDOWN"
        send_server_command "$validation_result"
        return 1
    fi
    
    # Update password in players.log
    update_players_log "$player_name" "password" "$password"
    sleep "$COMMAND_COOLDOWN"
    send_server_command "Password set successfully for $player_name"
    
    # Clear pending password and restore rank if IP is verified
    unset password_pending["$player_name"]
    
    # Check if IP is also verified, then restore rank
    read_players_log
    local ip="${players_data["$player_name,ip"]}"
    if [ "$ip" != "UNKNOWN" ] && [ -n "${player_original_rank[$player_name]}" ]; then
        restore_player_rank "$player_name"
    fi
    
    return 0
}

# Function to handle IP change verification with clear and cooldown
handle_ip_change() {
    local player_name="$1" provided_password="$2" current_ip="$3"
    
    clear_chat  # Clear chat first
    
    # Verify password
    read_players_log
    local stored_password="${players_data["$player_name,password"]}"
    
    if [ "$stored_password" = "NONE" ]; then
        sleep "$COMMAND_COOLDOWN"
        send_server_command "No password set for $player_name. Use !password first."
        return 1
    fi
    
    if [ "$provided_password" != "$stored_password" ]; then
        sleep "$COMMAND_COOLDOWN"
        send_server_command "Incorrect password for IP verification"
        return 1
    fi
    
    # Update IP in players.log
    update_players_log "$player_name" "ip" "$current_ip"
    sleep "$COMMAND_COOLDOWN"
    send_server_command "IP address verified and updated for $player_name"
    
    # Clear pending verification and restore rank if password is set
    unset ip_verify_pending["$player_name"]
    
    # Restore original rank now that IP is verified
    if [ -n "${player_original_rank[$player_name]}" ]; then
        restore_player_rank "$player_name"
    fi
    
    return 0
}

# Function to handle password change with clear and cooldown
handle_password_change() {
    local player_name="$1" old_password="$2" new_password="$3"
    
    clear_chat  # Clear chat first
    
    # Verify old password
    read_players_log
    local stored_password="${players_data["$player_name,password"]}"
    
    if [ "$stored_password" = "NONE" ]; then
        sleep "$COMMAND_COOLDOWN"
        send_server_command "No existing password found for $player_name"
        return 1
    fi
    
    if [ "$old_password" != "$stored_password" ]; then
        sleep "$COMMAND_COOLDOWN"
        send_server_command "Incorrect old password"
        return 1
    fi
    
    local validation_result=$(validate_password "$new_password")
    if [ $? -ne 0 ]; then
        sleep "$COMMAND_COOLDOWN"
        send_server_command "$validation_result"
        return 1
    fi
    
    # Update password
    update_players_log "$player_name" "password" "$new_password"
    sleep "$COMMAND_COOLDOWN"
    send_server_command "Password changed successfully for $player_name"
    return 0
}

# Function to check timeouts and kick players who don't verify (CORREGIDA)
check_timeouts() {
    local current_time=$(date +%s)
    
    # Check password setup timeouts
    for player in "${!password_pending[@]}"; do
        local start_time="${password_pending[$player]}"
        if [ $((current_time - start_time)) -ge $PASSWORD_TIMEOUT ]; then
            send_server_command "/kick $player"
            send_server_command "Player $player kicked for not setting password within $PASSWORD_TIMEOUT seconds"
            unset password_pending["$player"]
            print_warning "Kicked $player for password setup timeout"
        fi
    done
    
    # Check IP verification timeouts
    for player in "${!ip_verify_pending[@]}"; do
        local start_time="${ip_verify_pending[$player]}"
        if [ $((current_time - start_time)) -ge $IP_VERIFY_TIMEOUT ]; then
            send_server_command "/kick $player"
            send_server_command "Player $player kicked for not verifying IP within $IP_VERIFY_TIMEOUT seconds"
            unset ip_verify_pending["$player"]
            # Also remove stored original rank since verification failed
            unset player_original_rank["$player"]
            print_warning "Kicked $player for IP verification timeout"
        fi
    done
    
    # Auto-unban IPs after duration
    auto_unban_ips
}

# Function to monitor console.log for events (COMPLETAMENTE CORREGIDA)
monitor_console_log() {
    print_header "Starting rank_patcher monitoring"
    print_status "World: $WORLD_ID"
    print_status "Console log: $CONSOLE_LOG"
    print_status "Players log: $PLAYERS_LOG"
    
    # Initialize files
    initialize_players_log
    sync_server_lists
    
    # Monitor the log file
    tail -n 0 -F "$CONSOLE_LOG" | while read line; do
        # Detect player connections - FORMATO EXACTO: Player Connected NAME | IP | GUID
        if [[ "$line" =~ Player\ Connected\ ([a-zA-Z0-9_]+)\ \|\ ([0-9a-fA-F.:]+)\ \|\ ([a-f0-9]+) ]]; then
            local player_name="${BASH_REMATCH[1]}"
            local player_ip="${BASH_REMATCH[2]}"
            local player_guid="${BASH_REMATCH[3]}"
            
            print_success "Player connected: $player_name ($player_ip) - GUID: $player_guid"
            
            # Track join time
            player_join_time["$player_name"]=$(date +%s)
            
            # Add to connected players
            connected_players["$player_name"]=1
            player_ip_map["$player_name"]="$player_ip"
            
            # Check if player exists in players.log
            read_players_log
            if [ -z "${players_data["$player_name,name"]}" ]; then
                # New player - add to players.log
                add_new_player "$player_name" "$player_ip"
                
                # Request password setup with 30 second timeout
                send_server_command "Welcome $player_name! Please set a password within 30 seconds using: !password YOUR_PASSWORD CONFIRM_PASSWORD"
                password_pending["$player_name"]=$(date +%s)
                print_warning "New player - password required within $PASSWORD_TIMEOUT seconds"
                
            else
                # Existing player - check IP and password status
                local stored_ip="${players_data["$player_name,ip"]}"
                local stored_password="${players_data["$player_name,password"]}"
                local stored_rank="${players_data["$player_name,rank"]}"
                
                # Store original rank for potential restoration
                if [ "$stored_rank" != "NONE" ]; then
                    player_original_rank["$player_name"]="$stored_rank"
                fi
                
                # Check IP change - if IP doesn't match and stored IP is not UNKNOWN
                if [ "$stored_ip" != "$player_ip" ] && [ "$stored_ip" != "UNKNOWN" ]; then
                    # IP changed - require verification with 30 second timeout
                    send_server_command "IP change detected for $player_name. Verify within 30 seconds using: !ip_change YOUR_PASSWORD"
                    ip_verify_pending["$player_name"]=$(date +%s)
                    print_warning "IP change detected - verification required within $IP_VERIFY_TIMEOUT seconds"
                    
                    # Temporary set rank to NONE until verification
                    if [ "$stored_rank" != "NONE" ]; then
                        update_players_log "$player_name" "rank" "NONE"
                        # Remove from privilege lists immediately
                        case "$stored_rank" in
                            "ADMIN") send_server_command "/unadmin $player_name" ;;
                            "MOD") send_server_command "/unmod $player_name" ;;
                            "SUPER") 
                                send_server_command "/unadmin $player_name"
                                # Remove from cloud list temporarily
                                temp_file=$(mktemp)
                                head -n 2 "$CLOUD_ADMIN_LIST" > "$temp_file"
                                tail -n +3 "$CLOUD_ADMIN_LIST" 2>/dev/null | grep -v "^$player_name$" >> "$temp_file"
                                mv "$temp_file" "$CLOUD_ADMIN_LIST"
                                ;;
                        esac
                        print_warning "Temporarily removed ranks from $player_name pending IP verification"
                    fi
                fi
                
                # Check if password is set
                if [ "$stored_password" = "NONE" ]; then
                    send_server_command "Welcome back $player_name! Please set a password within 30 seconds using: !password YOUR_PASSWORD CONFIRM_PASSWORD"
                    password_pending["$player_name"]=$(date +%s)
                    print_warning "Existing player without password - setup required within $PASSWORD_TIMEOUT seconds"
                    
                    # Ensure rank is NONE if no password
                    if [ "$stored_rank" != "NONE" ]; then
                        update_players_log "$player_name" "rank" "NONE"
                        # Remove from privilege lists
                        case "$stored_rank" in
                            "ADMIN") send_server_command "/unadmin $player_name" ;;
                            "MOD") send_server_command "/unmod $player_name" ;;
                            "SUPER") 
                                send_server_command "/unadmin $player_name"
                                # Remove from cloud list
                                temp_file=$(mktemp)
                                head -n 2 "$CLOUD_ADMIN_LIST" > "$temp_file"
                                tail -n +3 "$CLOUD_ADMIN_LIST" 2>/dev/null | grep -v "^$player_name$" >> "$temp_file"
                                mv "$temp_file" "$CLOUD_ADMIN_LIST"
                                ;;
                        esac
                    fi
                else
                    # Player has password - check if IP is verified and restore rank if needed
                    if [ "$stored_ip" = "$player_ip" ] || [ "$stored_ip" = "UNKNOWN" ]; then
                        # IP matches or is not set yet - restore rank if they have one
                        if [ "$stored_rank" != "NONE" ]; then
                            # IP is verified or not set, restore rank
                            case "$stored_rank" in
                                "ADMIN") send_server_command "/admin $player_name" ;;
                                "MOD") send_server_command "/mod $player_name" ;;
                                "SUPER") 
                                    if ! tail -n +3 "$CLOUD_ADMIN_LIST" 2>/dev/null | grep -q "^$player_name$"; then
                                        echo "$player_name" >> "$CLOUD_ADMIN_LIST"
                                    fi
                                    send_server_command "/admin $player_name" 
                                    ;;
                            esac
                            print_success "Restored $stored_rank rank to $player_name"
                        fi
                    fi
                fi
            fi
            
            # Sync lists after connection
            sync_server_lists
            continue
        fi
        
        # Detect player disconnections - FORMATO EXACTO: Player Disconnected NAME
        if [[ "$line" =~ Player\ Disconnected\ ([a-zA-Z0-9_]+) ]]; then
            local player_name="${BASH_REMATCH[1]}"
            
            print_warning "Player disconnected: $player_name"
            
            # Remove from connected players and privilege lists only
            unset connected_players["$player_name"]
            unset player_ip_map["$player_name"]
            unset player_join_time["$player_name"]
            unset password_pending["$player_name"]
            unset ip_verify_pending["$player_name"]
            unset player_original_rank["$player_name"]
            
            # Remove only from privilege lists (admin/mod/super), NOT from whitelist/blacklist
            remove_player_from_lists "$player_name"
            
            # Sync lists after disconnection
            sync_server_lists
            continue
        fi
        
        # Detect chat messages and commands
        if [[ "$line" =~ ([a-zA-Z0-9_]+):\ (.+)$ ]]; then
            local player_name="${BASH_REMATCH[1]}"
            local message="${BASH_REMATCH[2]}"
            
            # Skip server messages
            if [ "$player_name" = "SERVER" ]; then
                continue
            fi
            
            # Process commands
            case "$message" in
                "!password "*)
                    if [[ "$message" =~ !password\ ([^ ]+)\ ([^ ]+) ]]; then
                        local password="${BASH_REMATCH[1]}"
                        local confirm_password="${BASH_REMATCH[2]}"
                        handle_password_command "$player_name" "$password" "$confirm_password"
                    else
                        send_server_command "Usage: !password NEW_PASSWORD CONFIRM_PASSWORD"
                    fi
                    ;;
                "!ip_change "*)
                    if [[ "$message" =~ !ip_change\ ([^ ]+) ]]; then
                        local password="${BASH_REMATCH[1]}"
                        local current_ip="${player_ip_map[$player_name]}"
                        handle_ip_change "$player_name" "$password" "$current_ip"
                    else
                        send_server_command "Usage: !ip_change YOUR_PASSWORD"
                    fi
                    ;;
                "!change_psw "*)
                    if [[ "$message" =~ !change_psw\ ([^ ]+)\ ([^ ]+) ]]; then
                        local old_password="${BASH_REMATCH[1]}"
                        local new_password="${BASH_REMATCH[2]}"
                        handle_password_change "$player_name" "$old_password" "$new_password"
                    else
                        send_server_command "Usage: !change_psw OLD_PASSWORD NEW_PASSWORD"
                    fi
                    ;;
            esac
        fi
    done
}

# Function to monitor players.log for changes every 1 second (ACTUALIZADA)
monitor_players_log() {
    local last_modified=0
    
    while true; do
        if [ -f "$PLAYERS_LOG" ]; then
            local current_modified=$(stat -c %Y "$PLAYERS_LOG" 2>/dev/null || stat -f %m "$PLAYERS_LOG")
            
            if [ "$current_modified" -ne "$last_modified" ]; then
                print_status "players.log modified - processing changes"
                
                # Read previous state
                declare -A old_players_data
                for key in "${!players_data[@]}"; do
                    old_players_data["$key"]="${players_data[$key]}"
                done
                
                # Read new state
                read_players_log
                
                # Compare and handle changes
                for key in "${!players_data[@]}"; do
                    if [[ "$key" == *,name ]]; then
                        local player_name="${players_data[$key]}"
                        local old_rank="${old_players_data["$player_name,rank"]:-NONE}"
                        local new_rank="${players_data["$player_name,rank"]:-NONE}"
                        local old_whitelisted="${old_players_data["$player_name,whitelisted"]:-NO}"
                        local new_whitelisted="${players_data["$player_name,whitelisted"]:-NO}"
                        local old_blacklisted="${old_players_data["$player_name,blacklisted"]:-NO}"
                        local new_blacklisted="${players_data["$player_name,blacklisted"]:-NO}"
                        local player_ip="${players_data["$player_name,ip"]}"
                        local player_password="${players_data["$player_name,password"]}"
                        
                        # SOLO permitir cambios de rango si tiene password e IP verificada
                        if [ "$player_password" = "NONE" ] || [ "$player_ip" = "UNKNOWN" ]; then
                            if [ "$new_rank" != "NONE" ]; then
                                print_warning "Player $player_name lacks password or IP verification - resetting rank to NONE"
                                update_players_log "$player_name" "rank" "NONE"
                                continue
                            fi
                        fi
                        
                        # Handle rank changes (solo si tiene password e IP verificada)
                        if [ "$old_rank" != "$new_rank" ] && [ "$player_password" != "NONE" ] && [ "$player_ip" != "UNKNOWN" ]; then
                            handle_rank_change "$player_name" "$old_rank" "$new_rank"
                        fi
                        
                        # Handle whitelist changes
                        if [ "$old_whitelisted" != "$new_whitelisted" ]; then
                            handle_whitelist_change "$player_name" "$old_whitelisted" "$new_whitelisted"
                        fi
                        
                        # Handle blacklist changes
                        if [ "$old_blacklisted" != "$new_blacklisted" ]; then
                            handle_blacklist_change "$player_name" "$old_blacklisted" "$new_blacklisted" "$player_ip"
                        fi
                    fi
                done
                
                # Sync server lists
                sync_server_lists
                
                last_modified="$current_modified"
            fi
        fi
        
        sleep 1  # Check every 1 second as required
    done
}

# Main execution
main() {
    print_header "THE BLOCKHEADS RANK PATCHER"
    print_status "Starting player management system..."
    
    # Check if console log exists
    if [ ! -f "$CONSOLE_LOG" ]; then
        print_error "Console log not found: $CONSOLE_LOG"
        print_status "Waiting for log file to be created..."
        
        # Wait for log file
        local wait_time=0
        while [ ! -f "$CONSOLE_LOG" ] && [ $wait_time -lt 30 ]; do
            sleep 1
            wait_time=$((wait_time + 1))
        done
        
        if [ ! -f "$CONSOLE_LOG" ]; then
            print_error "Console log never appeared: $CONSOLE_LOG"
            exit 1
        fi
    fi
    
    # Start monitoring processes in background
    monitor_console_log &
    local console_pid=$!
    
    monitor_players_log &
    local players_pid=$!
    
    # Main loop for timeout checking
    while true; do
        check_timeouts
        sleep 5
    done
    
    # Wait for background processes (should never reach here)
    wait $console_pid $players_pid
}

# Start main function
main
