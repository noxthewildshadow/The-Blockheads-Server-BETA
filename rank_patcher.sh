#!/bin/bash

# rank_patcher.sh - Complete player management system for The Blockheads server
# VERSIÓN CORREGIDA: /kick funcionando correctamente

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
PASSWORD_TIMEOUT=60
IP_VERIFY_TIMEOUT=30
IP_BAN_DURATION=30
WELCOME_DELAY=5
LIST_SYNC_INTERVAL=5
WARNING_INTERVAL=10

# Track connected players and their states
declare -A connected_players
declare -A player_ip_map
declare -A password_pending
declare -A ip_verify_pending
declare -A ip_banned_times
declare -A last_warning_time

# Function to send commands to server with proper cooldown
send_server_command() {
    local command="$1"
    
    # Apply cooldown before sending command
    sleep "$COMMAND_COOLDOWN"
    
    if screen -S "$SCREEN_SERVER" -X stuff "$command$(printf \\r)" 2>/dev/null; then
        print_success "Sent command: $command"
        return 0
    else
        print_error "Failed to send command: $command"
        return 1
    fi
}

# Function to kick player - SIMPLIFICADO
kick_player() {
    local player_name="$1"
    local reason="$2"
    
    print_warning "Kicking player: $player_name - Reason: $reason"
    # Enviar comando KICK directamente sin mensajes adicionales
    screen -S "$SCREEN_SERVER" -X stuff "/kick $player_name$(printf \\r)"
    sleep "$COMMAND_COOLDOWN"
    print_success "Kick command sent for: $player_name"
}

# Function to clear chat
clear_chat() {
    send_server_command "/clear"
}

# Function to initialize players.log with EXACT format
initialize_players_log() {
    if [ ! -f "$PLAYERS_LOG" ]; then
        print_status "Creating new players.log file"
        mkdir -p "$(dirname "$PLAYERS_LOG")"
        touch "$PLAYERS_LOG"
        echo "# Player Name | First IP | Password | Rank | Whitelisted | Blacklisted" > "$PLAYERS_LOG"
        print_success "players.log created at: $PLAYERS_LOG"
    fi
}

# Function to read players.log into associative array
read_players_log() {
    declare -gA players_data
    
    if [ ! -f "$PLAYERS_LOG" ]; then
        print_error "players.log not found: $PLAYERS_LOG"
        return 1
    fi
    
    while IFS='|' read -r name ip password rank whitelisted blacklisted; do
        # Skip header lines and empty lines
        [[ "$name" =~ ^# ]] && continue
        [[ -z "$name" ]] && continue
        
        # Clean up fields and apply EXACT defaults - NO EXTRA SPACES
        name=$(echo "$name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        ip=$(echo "$ip" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        password=$(echo "$password" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        rank=$(echo "$rank" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        whitelisted=$(echo "$whitelisted" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        blacklisted=$(echo "$blacklisted" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        
        # Apply required EXACT defaults
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

# Function to update players.log with EXACT format - NO EXTRA SPACES
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
    
    # Write back to file with EXACT format - NO EXTRA SPACES
    {
        echo "# Player Name | First IP | Password | Rank | Whitelisted | Blacklisted"
        
        for key in "${!players_data[@]}"; do
            if [[ "$key" == *,name ]]; then
                local name="${players_data[$key]}"
                local ip="${players_data["$name,ip"]:-UNKNOWN}"
                local password="${players_data["$name,password"]:-NONE}"
                local rank="${players_data["$name,rank"]:-NONE}"
                local whitelisted="${players_data["$name,whitelisted"]:-NO}"
                local blacklisted="${players_data["$name,blacklisted"]:-NO}"
                
                # FORMATO EXACTO: Sin espacios extra, separadores exactos
                echo "$name | $ip | $password | $rank | $whitelisted | $blacklisted"
            fi
        done
    } > "$PLAYERS_LOG"
    
    print_success "Updated players.log: $player_name $field = $new_value"
}

# Function to add new player to players.log with EXACT format
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
    
    # Add new player with EXACT defaults
    players_data["$player_name,name"]="$player_name"
    players_data["$player_name,ip"]="$player_ip"
    players_data["$player_name,password"]="NONE"
    players_data["$player_name,rank"]="NONE"
    players_data["$player_name,whitelisted"]="NO"
    players_data["$player_name,blacklisted"]="NO"
    
    # Write back to file with EXACT format
    {
        echo "# Player Name | First IP | Password | Rank | Whitelisted | Blacklisted"
        
        for key in "${!players_data[@]}"; do
            if [[ "$key" == *,name ]]; then
                local name="${players_data[$key]}"
                local ip="${players_data["$name,ip"]:-UNKNOWN}"
                local password="${players_data["$name,password"]:-NONE}"
                local rank="${players_data["$name,rank"]:-NONE}"
                local whitelisted="${players_data["$name,whitelisted"]:-NO}"
                local blacklisted="${players_data["$name,blacklisted"]:-NO}"
                
                # FORMATO EXACTO: Sin espacios extra
                echo "$name | $ip | $password | $rank | $whitelisted | $blacklisted"
            fi
        done
    } > "$PLAYERS_LOG"
    
    print_success "Added new player: $player_name ($player_ip)"
}

# Function to check if IP is verified for a player
is_ip_verified() {
    local player_name="$1"
    local current_ip="$2"
    
    read_players_log
    local stored_ip="${players_data["$player_name,ip"]}"
    
    # If stored IP is UNKNOWN or matches current IP, consider verified
    if [ "$stored_ip" = "UNKNOWN" ] || [ "$stored_ip" = "$current_ip" ]; then
        return 0
    fi
    
    # IP doesn't match and not UNKNOWN - requires verification
    return 1
}

# Function to sync server lists from players.log - EMPTY FILES
sync_server_lists() {
    print_status "Syncing server lists from players.log..."
    
    # Read current player data
    read_players_log
    
    # Clear existing lists COMPLETELY - EMPTY FILES
    for list_file in "$ADMIN_LIST" "$MOD_LIST" "$WHITELIST" "$BLACKLIST"; do
        # Create empty file (no headers, no content)
        > "$list_file"
    done
    
    # Sync cloud admin list - EMPTY FILE
    > "$CLOUD_ADMIN_LIST"
    
    # Add players to appropriate lists based on rank and status
    # Only add if IP is verified and player is connected
    for key in "${!players_data[@]}"; do
        if [[ "$key" == *,name ]]; then
            local name="${players_data[$key]}"
            local ip="${players_data["$name,ip"]}"
            local rank="${players_data["$name,rank"]}"
            local whitelisted="${players_data["$name,whitelisted"]}"
            local blacklisted="${players_data["$name,blacklisted"]}"
            local current_ip="${player_ip_map[$name]}"
            
            # Only apply ranks if IP is verified AND player is connected
            if [ -n "${connected_players[$name]}" ] && is_ip_verified "$name" "$current_ip"; then
                case "$rank" in
                    "ADMIN")
                        echo "$name" >> "$ADMIN_LIST"
                        ;;
                    "MOD")
                        echo "$name" >> "$MOD_LIST"
                        ;;
                    "SUPER")
                        echo "$name" >> "$CLOUD_ADMIN_LIST"
                        ;;
                esac
                
                if [ "$whitelisted" = "YES" ]; then
                    echo "$name" >> "$WHITELIST"
                fi
                
                if [ "$blacklisted" = "YES" ]; then
                    echo "$name" >> "$BLACKLIST"
                fi
            fi
        fi
    done
    
    print_success "Server lists synced"
}

# Function to send welcome message after delay
send_welcome_message() {
    local player_name="$1" is_new_player="$2"
    
    # Wait 5 seconds before sending welcome message
    sleep "$WELCOME_DELAY"
    
    if [ "$is_new_player" = "true" ]; then
        send_server_command "Welcome $player_name! Please set a password using: !password YOUR_PASSWORD CONFIRM_PASSWORD"
        send_server_command "You have 60 seconds to set your password or you will be kicked."
    else
        send_server_command "Welcome back $player_name!"
    fi
}

# Function to send IP change warning after delay
send_ip_warning() {
    local player_name="$1"
    
    # Wait 5 seconds before sending warning
    sleep "$WELCOME_DELAY"
    
    send_server_command "IP change detected for $player_name. Verify with: !ip_change YOUR_PASSWORD"
    send_server_command "You have 30 seconds to verify your IP or you will be kicked and IP banned."
}

# Function to send password warning
send_password_warning() {
    local player_name="$1" time_left="$2"
    
    send_server_command "WARNING $player_name: You have $time_left seconds to set your password with !password YOUR_PASSWORD CONFIRM_PASSWORD or you will be kicked!"
}

# Function to monitor console.log for events - CORREGIDO: Detección mejorada
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
        # Detect player connections - FORMATO MEJORADO
        if echo "$line" | grep -q "Player Connected"; then
            # Extraer nombre del jugador e IP usando diferentes patrones
            local player_name=$(echo "$line" | sed -n 's/.*Player Connected \([^ |]*\) .*/\1/p')
            local player_ip=$(echo "$line" | sed -n 's/.*Player Connected [^ |]* | \([0-9.]*\) .*/\1/p')
            
            if [ -n "$player_name" ] && [ -n "$player_ip" ]; then
                print_success "Player connected: $player_name ($player_ip)"
                
                # Add to connected players
                connected_players["$player_name"]=1
                player_ip_map["$player_name"]="$player_ip"
                
                # Check if player exists in players.log
                read_players_log
                if [ -z "${players_data["$player_name,name"]}" ]; then
                    # New player - add to players.log
                    add_new_player "$player_name" "$player_ip"
                    
                    # Send welcome message after delay
                    send_welcome_message "$player_name" "true" &
                    password_pending["$player_name"]=$(date +%s)
                    last_warning_time["$player_name"]=0
                    print_status "New player $player_name added to password pending"
                else
                    # Existing player - check IP
                    local stored_ip="${players_data["$player_name,ip"]}"
                    local stored_password="${players_data["$player_name,password"]}"
                    
                    if [ "$stored_ip" != "$player_ip" ] && [ "$stored_ip" != "UNKNOWN" ]; then
                        # IP changed - require verification
                        send_ip_warning "$player_name" &
                        ip_verify_pending["$player_name"]=$(date +%s)
                        print_status "IP change detected for $player_name - verification required"
                    fi
                    
                    # Check if password is set
                    if [ "$stored_password" = "NONE" ]; then
                        send_welcome_message "$player_name" "false" &
                        password_pending["$player_name"]=$(date +%s)
                        last_warning_time["$player_name"]=0
                        print_status "Existing player $player_name has no password - added to pending"
                    fi
                fi
                
                # Sync lists after connection
                sync_server_lists
            fi
            continue
        fi
        
        # Detect player disconnections
        if [[ "$line" =~ Player\ Disconnected\ ([a-zA-Z0-9_]+) ]]; then
            local player_name="${BASH_REMATCH[1]}"
            
            print_warning "Player disconnected: $player_name"
            
            # Remove from connected players
            unset connected_players["$player_name"]
            unset player_ip_map["$player_name"]
            unset password_pending["$player_name"]
            unset ip_verify_pending["$player_name"]
            unset last_warning_time["$player_name"]
            
            # Sync lists after disconnection
            sync_server_lists
            continue
        fi
        
        # Detect chat messages and commands
        if [[ "$line" =~ ([a-zA-Z0-9_]+):\ (.+)$ ]]; then
            local player_name="${BASH_REMATCH[1]}"
            local message="${BASH_REMATCH[2]}"
            
            # Skip server messages
            [ "$player_name" = "SERVER" ] && continue
            
            # Process commands
            case "$message" in
                "!password "*)
                    if [[ "$message" =~ !password\ ([^ ]+)\ ([^ ]+) ]]; then
                        local password="${BASH_REMATCH[1]}"
                        local confirm_password="${BASH_REMATCH[2]}"
                        print_status "Password command received from $player_name"
                        # Clear chat first
                        clear_chat
                        # Handle password command
                        if [ "$password" != "$confirm_password" ]; then
                            send_server_command "Passwords do not match"
                        else
                            # Update password in players.log
                            update_players_log "$player_name" "password" "$password"
                            send_server_command "Password set successfully for $player_name"
                            # Remove from password pending
                            unset password_pending["$player_name"]
                            unset last_warning_time["$player_name"]
                            print_success "Password set for $player_name"
                        fi
                    else
                        send_server_command "Usage: !password NEW_PASSWORD CONFIRM_PASSWORD"
                    fi
                    ;;
                "!ip_change "*)
                    if [[ "$message" =~ !ip_change\ ([^ ]+) ]]; then
                        local password="${BASH_REMATCH[1]}"
                        local current_ip="${player_ip_map[$player_name]}"
                        # Clear chat first
                        clear_chat
                        # Verify password
                        read_players_log
                        local stored_password="${players_data["$player_name,password"]}"
                        
                        if [ "$stored_password" = "NONE" ]; then
                            send_server_command "No password set for $player_name. Use !password first."
                        elif [ "$provided_password" != "$stored_password" ]; then
                            send_server_command "Incorrect password for IP verification"
                        else
                            # Update IP in players.log
                            update_players_log "$player_name" "ip" "$current_ip"
                            send_server_command "IP address verified and updated for $player_name"
                            # Clear pending verification
                            unset ip_verify_pending["$player_name"]
                        fi
                    else
                        send_server_command "Usage: !ip_change YOUR_PASSWORD"
                    fi
                    ;;
            esac
        fi
    done
}

# Function to check timeouts - COMPLETAMENTE CORREGIDO
check_timeouts() {
    local current_time=$(date +%s)
    
    # Check password setup timeouts - 60 seconds
    for player in "${!password_pending[@]}"; do
        if [ -z "${password_pending[$player]}" ]; then
            continue
        fi
        
        local start_time="${password_pending[$player]}"
        local time_elapsed=$((current_time - start_time))
        
        print_status "Checking $player: $time_elapsed seconds elapsed"
        
        if [ $time_elapsed -ge $PASSWORD_TIMEOUT ]; then
            print_warning "PASSWORD TIMEOUT REACHED for $player - KICKING NOW"
            kick_player "$player" "No password set within 60 seconds"
            # Limpiar el jugador de todos los arrays
            unset connected_players["$player"]
            unset player_ip_map["$player"]
            unset password_pending["$player"]
            unset last_warning_time["$player"]
            print_success "Player $player kicked for password timeout"
        else
            # Send warnings
            local time_left=$((PASSWORD_TIMEOUT - time_elapsed))
            local last_warn="${last_warning_time[$player]:-0}"
            local time_since_last_warn=$((current_time - last_warn))
            
            # Send warnings at specific intervals
            if [ $time_left -le 50 ] && [ $time_left -gt 40 ] && [ $time_since_last_warn -ge 10 ]; then
                send_password_warning "$player" "$time_left"
                last_warning_time["$player"]=$current_time
            elif [ $time_left -le 40 ] && [ $time_left -gt 30 ] && [ $time_since_last_warn -ge 10 ]; then
                send_password_warning "$player" "$time_left"
                last_warning_time["$player"]=$current_time
            elif [ $time_left -le 30 ] && [ $time_left -gt 20 ] && [ $time_since_last_warn -ge 10 ]; then
                send_password_warning "$player" "$time_left"
                last_warning_time["$player"]=$current_time
            elif [ $time_left -le 20 ] && [ $time_left -gt 10 ] && [ $time_since_last_warn -ge 10 ]; then
                send_password_warning "$player" "$time_left"
                last_warning_time["$player"]=$current_time
            elif [ $time_left -le 10 ] && [ $time_since_last_warn -ge 5 ]; then
                send_password_warning "$player" "$time_left"
                last_warning_time["$player"]=$current_time
            fi
        fi
    done
    
    # Check IP verification timeouts - 30 seconds
    for player in "${!ip_verify_pending[@]}"; do
        if [ -z "${ip_verify_pending[$player]}" ]; then
            continue
        fi
        
        local start_time="${ip_verify_pending[$player]}"
        local time_elapsed=$((current_time - start_time))
        
        if [ $time_elapsed -ge $IP_VERIFY_TIMEOUT ]; then
            local player_ip="${player_ip_map[$player]}"
            print_warning "IP VERIFICATION TIMEOUT for $player - KICKING AND BANNING"
            kick_player "$player" "IP verification failed within 30 seconds"
            send_server_command "/ban $player_ip"
            # Limpiar el jugador de todos los arrays
            unset connected_players["$player"]
            unset player_ip_map["$player"]
            unset ip_verify_pending["$player"]
            # Track ban for auto-unban
            ip_banned_times["$player_ip"]=$(date +%s)
            print_success "Player $player kicked and IP banned for IP verification timeout"
        fi
    done
    
    # Auto-unban IPs after duration
    for ip in "${!ip_banned_times[@]}"; do
        local ban_time="${ip_banned_times[$ip]}"
        if [ $((current_time - ban_time)) -ge $IP_BAN_DURATION ]; then
            send_server_command "/unban $ip"
            print_status "Auto-unbanned IP: $ip"
            unset ip_banned_times["$ip"]
        fi
    done
}

# Function to periodically sync lists every 5 seconds
periodic_list_sync() {
    while true; do
        sleep "$LIST_SYNC_INTERVAL"
        print_status "Periodic list sync (every $LIST_SYNC_INTERVAL seconds)"
        sync_server_lists
    done
}

# Main execution - ESTRUCTURA SIMPLIFICADA
main() {
    print_header "THE BLOCKHEADS RANK PATCHER - KICK FIXED"
    print_status "Starting player management system..."
    
    # Check if console log exists
    if [ ! -f "$CONSOLE_LOG" ]; then
        print_error "Console log not found: $CONSOLE_LOG"
        print_status "Waiting for log file to be created..."
        
        # Wait for log file
        local wait_time=0
        while [ ! -f "$CONSOLE_LOG" ] && [ $wait_time -lt 30 ]; do
            sleep 1
            ((wait_time++))
        done
        
        if [ ! -f "$CONSOLE_LOG" ]; then
            print_error "Console log never appeared: $CONSOLE_LOG"
            exit 1
        fi
    fi
    
    # Initialize files
    initialize_players_log
    sync_server_lists
    
    # Start monitoring processes in background
    (
        print_status "Starting console log monitor..."
        monitor_console_log
    ) &
    local console_pid=$!
    
    (
        print_status "Starting periodic list sync..."
        periodic_list_sync
    ) &
    local sync_pid=$!
    
    # Main loop for timeout checking - MÁS FRECUENTE
    print_status "Starting timeout checker (runs every 2 seconds)..."
    while true; do
        check_timeouts
        sleep 2  # Verificar cada 2 segundos en lugar de 5
    done
    
    # Wait for background processes (should never reach here)
    wait $console_pid $sync_pid
}

# Start main function
main "$@"
