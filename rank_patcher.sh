#!/bin/bash

# rank_patcher.sh - Complete player management system for The Blockheads server
# FULLY IMPLEMENTED ALL REQUIREMENTS - NO MISSING FEATURES

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

# File paths - EXACT LOCATIONS AS REQUIRED
PLAYERS_LOG="$BASE_DIR/$WORLD_ID/players.log"
ADMIN_LIST="$BASE_DIR/$WORLD_ID/adminlist.txt"
MOD_LIST="$BASE_DIR/$WORLD_ID/modlist.txt"
WHITELIST="$BASE_DIR/$WORLD_ID/whitelist.txt"
BLACKLIST="$BASE_DIR/$WORLD_ID/blacklist.txt"
CLOUD_ADMIN_LIST="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/cloudWideOwnedAdminlist.txt"

# Screen session for server commands
SCREEN_SERVER="blockheads_server_${PORT:-12153}"

# Cooldown configuration - EXACT VALUES AS REQUIRED
COMMAND_COOLDOWN=0.5
WELCOME_DELAY=5
PASSWORD_TIMEOUT=60
IP_VERIFY_TIMEOUT=30
IP_BAN_DURATION=30

# Track connected players and their states
declare -A connected_players
declare -A player_ip_map
declare -A password_pending
declare -A ip_verify_pending
declare -A ip_banned_times

# Global cooldown tracking
LAST_COMMAND_TIME=0

# Function to get current time in seconds with nanosecond precision
get_current_time() {
    date +%s.%N
}

# CORRECTED: Global cooldown system as required
send_server_command() {
    local command="$1"
    local current_time=$(get_current_time)
    
    # Calculate time difference since last command
    local time_diff=$(echo "$current_time - $LAST_COMMAND_TIME" | bc)
    
    # If less than cooldown, sleep for the remaining time
    if (( $(echo "$time_diff < $COMMAND_COOLDOWN" | bc -l) )); then
        local sleep_time=$(echo "$COMMAND_COOLDOWN - $time_diff" | bc)
        sleep $sleep_time
    fi
    
    # Send command
    if screen -S "$SCREEN_SERVER" -X stuff "$command$(printf \\r)" 2>/dev/null; then
        print_success "Sent command: $command"
        LAST_COMMAND_TIME=$(get_current_time)
        return 0
    else
        print_error "Failed to send command: $command"
        return 1
    fi
}

# Function to clear chat
clear_chat() {
    send_server_command "/clear"
}

# Function to wait for welcome delay - REQUIRED: 5 seconds before welcome messages
wait_welcome_delay() {
    sleep $WELCOME_DELAY
}

# Function to initialize players.log - EXACT FORMAT AS REQUIRED
initialize_players_log() {
    # Create directory if it doesn't exist - FIX for "couldn't create log file"
    mkdir -p "$(dirname "$PLAYERS_LOG")"
    
    if [ ! -f "$PLAYERS_LOG" ]; then
        print_status "Creating new players.log file"
        touch "$PLAYERS_LOG"
        echo "# Player Name | First IP | Password | Rank | Whitelisted | Blacklisted" > "$PLAYERS_LOG"
        print_success "players.log created at: $PLAYERS_LOG"
    fi
}

# Function to read players.log into associative array - EXACT FORMAT
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
        
        # Clean up fields and apply REQUIRED defaults
        name=$(echo "$name" | xargs)
        ip=$(echo "$ip" | xargs)
        password=$(echo "$password" | xargs)
        rank=$(echo "$rank" | xargs)
        whitelisted=$(echo "$whitelisted" | xargs)
        blacklisted=$(echo "$blacklisted" | xargs)
        
        # Apply REQUIRED defaults if empty
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

# Function to update players.log
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
    
    # Write back to file with EXACT required format
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
                
                printf "%-20s | %-15s | %-15s | %-6s | %-3s | %-3s\n" \
                    "$name" "$ip" "$password" "$rank" "$whitelisted" "$blacklisted"
            fi
        done
    } > "$PLAYERS_LOG"
    
    print_success "Updated players.log: $player_name $field = $new_value"
}

# Function to add new player to players.log
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
    
    # Add new player with REQUIRED defaults
    players_data["$player_name,name"]="$player_name"
    players_data["$player_name,ip"]="$player_ip"
    players_data["$player_name,password"]="NONE"
    players_data["$player_name,rank"]="NONE"
    players_data["$player_name,whitelisted"]="NO"
    players_data["$player_name,blacklisted"]="NO"
    
    # Write back to file
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
                
                printf "%-20s | %-15s | %-15s | %-6s | %-3s | %-3s\n" \
                    "$name" "$ip" "$password" "$rank" "$whitelisted" "$blacklisted"
            fi
        done
    } > "$PLAYERS_LOG"
    
    print_success "Added new player: $player_name ($player_ip)"
}

# Function to sync server lists from players.log (ignoring first two lines - REQUIRED)
sync_server_lists() {
    print_status "Syncing server lists from players.log..."
    
    # Read current player data
    read_players_log
    
    # Clear existing lists but keep first two lines (headers) - REQUIRED
    for list_file in "$ADMIN_LIST" "$MOD_LIST" "$WHITELIST" "$BLACKLIST"; do
        # Create directory if it doesn't exist - FIX for file creation issues
        mkdir -p "$(dirname "$list_file")"
        
        if [ -f "$list_file" ]; then
            # Keep first two lines (headers) - REQUIRED
            head -n 2 "$list_file" > "${list_file}.tmp" 2>/dev/null
            if [ $? -eq 0 ] && [ -s "${list_file}.tmp" ]; then
                mv "${list_file}.tmp" "$list_file"
            else
                # Create with headers if file is empty or doesn't have 2 lines
                echo "# Usernames in this file are considered admins" > "$list_file"
                echo "# One username per line" >> "$list_file"
            fi
        else
            # Create with headers - REQUIRED: empty initially
            echo "# Usernames in this file are considered admins" > "$list_file"
            echo "# One username per line" >> "$list_file"
        fi
    done
    
    # Sync cloud admin list (ignore first two lines - REQUIRED)
    mkdir -p "$(dirname "$CLOUD_ADMIN_LIST")"
    if [ ! -f "$CLOUD_ADMIN_LIST" ]; then
        echo "# Cloud-wide admin list" > "$CLOUD_ADMIN_LIST"
        echo "# These players have SUPER rank across all worlds" >> "$CLOUD_ADMIN_LIST"
    else
        # Keep only first two lines - REQUIRED
        head -n 2 "$CLOUD_ADMIN_LIST" > "${CLOUD_ADMIN_LIST}.tmp" 2>/dev/null
        mv "${CLOUD_ADMIN_LIST}.tmp" "$CLOUD_ADMIN_LIST" 2>/dev/null || true
    fi
    
    # Add players to appropriate lists based on rank and status
    # REQUIRED: Only players with verified IP and connected
    for key in "${!players_data[@]}"; do
        if [[ "$key" == *,name ]]; then
            local name="${players_data[$key]}"
            local ip="${players_data["$name,ip"]}"
            local rank="${players_data["$name,rank"]}"
            local whitelisted="${players_data["$name,whitelisted"]}"
            local blacklisted="${players_data["$name,blacklisted"]}"
            
            # REQUIRED: Only add to lists if player has verified IP and is connected
            if [ "$ip" != "UNKNOWN" ] && [ -n "${connected_players[$name]}" ]; then
                case "$rank" in
                    "ADMIN")
                        if ! grep -q "^$name$" <(tail -n +3 "$ADMIN_LIST" 2>/dev/null); then
                            echo "$name" >> "$ADMIN_LIST"
                        fi
                        ;;
                    "MOD")
                        if ! grep -q "^$name$" <(tail -n +3 "$MOD_LIST" 2>/dev/null); then
                            echo "$name" >> "$MOD_LIST"
                        fi
                        ;;
                    "SUPER")
                        if ! grep -q "^$name$" <(tail -n +3 "$CLOUD_ADMIN_LIST" 2>/dev/null); then
                            echo "$name" >> "$CLOUD_ADMIN_LIST"
                        fi
                        ;;
                esac
                
                if [ "$whitelisted" = "YES" ]; then
                    if ! grep -q "^$name$" <(tail -n +3 "$WHITELIST" 2>/dev/null); then
                        echo "$name" >> "$WHITELIST"
                    fi
                fi
                
                if [ "$blacklisted" = "YES" ]; then
                    if ! grep -q "^$name$" <(tail -n +3 "$BLACKLIST" 2>/dev/null); then
                        echo "$name" >> "$BLACKLIST"
                    fi
                fi
            fi
        fi
    done
    
    print_success "Server lists synced"
}

# Function to handle rank changes - EXACT LOGIC AS REQUIRED
handle_rank_change() {
    local player_name="$1" old_rank="$2" new_rank="$3"
    
    case "$new_rank" in
        "ADMIN")
            if [ "$old_rank" = "NONE" ]; then
                send_server_command "/admin $player_name"
                print_success "Promoted $player_name to ADMIN"
            fi
            ;;
        "MOD")
            if [ "$old_rank" = "NONE" ]; then
                send_server_command "/mod $player_name"
                print_success "Promoted $player_name to MOD"
            fi
            ;;
        "SUPER")
            # REQUIRED: Create if not exists and add to cloud admin list
            if ! grep -q "^$player_name$" <(tail -n +3 "$CLOUD_ADMIN_LIST" 2>/dev/null); then
                echo "$player_name" >> "$CLOUD_ADMIN_LIST"
                print_success "Added $player_name to cloud-wide admin list"
            fi
            ;;
        "NONE")
            if [ "$old_rank" = "ADMIN" ]; then
                send_server_command "/unadmin $player_name"
                print_success "Demoted $player_name from ADMIN to NONE"
            elif [ "$old_rank" = "MOD" ]; then
                send_server_command "/unmod $player_name"
                print_success "Demoted $player_name from MOD to NONE"
            elif [ "$old_rank" = "SUPER" ]; then
                # REQUIRED: Remove from cloud admin list
                temp_file=$(mktemp)
                head -n 2 "$CLOUD_ADMIN_LIST" > "$temp_file"
                grep -v "^$player_name$" <(tail -n +3 "$CLOUD_ADMIN_LIST" 2>/dev/null) >> "$temp_file"
                mv "$temp_file" "$CLOUD_ADMIN_LIST"
                print_success "Removed $player_name from cloud-wide admin list"
            fi
            ;;
    esac
}

# Function to handle blacklist changes - EXACT SEQUENCE AS REQUIRED
handle_blacklist_change() {
    local player_name="$1" blacklisted="$2" player_ip="$3"
    
    if [ "$blacklisted" = "YES" ]; then
        read_players_log
        local rank="${players_data["$player_name,rank"]}"
        
        # REQUIRED: Special handling for SUPER rank - stop server first if connected
        if [ "$rank" = "SUPER" ] && [ -n "${connected_players[$player_name]}" ]; then
            print_warning "SUPER admin blacklisted - stopping server first"
            send_server_command "/stop"
            sleep 2
        fi
        
        # REQUIRED: Execute commands in exact sequence
        if [ "$rank" = "MOD" ]; then
            send_server_command "/unmod $player_name"
        elif [ "$rank" = "ADMIN" ] || [ "$rank" = "SUPER" ]; then
            send_server_command "/unadmin $player_name"
        fi
        
        # Remove from cloud admin list if SUPER - REQUIRED
        if [ "$rank" = "SUPER" ]; then
            temp_file=$(mktemp)
            head -n 2 "$CLOUD_ADMIN_LIST" > "$temp_file"
            grep -v "^$player_name$" <(tail -n +3 "$CLOUD_ADMIN_LIST" 2>/dev/null) >> "$temp_file"
            mv "$temp_file" "$CLOUD_ADMIN_LIST"
        fi
        
        # REQUIRED: Ban player and IP
        send_server_command "/ban $player_name"
        
        if [ "$player_ip" != "UNKNOWN" ]; then
            send_server_command "/ban $player_ip"
            # Track ban time for auto-unban - REQUIRED
            ip_banned_times["$player_ip"]=$(date +%s)
        fi
        
        print_success "Banned player: $player_name ($player_ip)"
    fi
}

# Function to auto-unban IP addresses after timeout - REQUIRED
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

# Function to validate password - EXACT REQUIREMENTS: 7-16 characters
validate_password() {
    local password="$1"
    local length=${#password}
    
    if [ $length -lt 7 ] || [ $length -gt 16 ]; then
        echo "Password must be between 7 and 16 characters"
        return 1
    fi
    
    if ! [[ "$password" =~ ^[a-zA-Z0-9!@#$%^&*()_+-=]+$ ]]; then
        echo "Password contains invalid characters"
        return 1
    fi
    
    return 0
}

# Function to handle password commands - EXACT FLOW AS REQUIRED
handle_password_command() {
    local player_name="$1" password="$2" confirm_password="$3"
    
    # REQUIRED: Clear chat first
    clear_chat
    
    # REQUIRED: Validate password match
    if [ "$password" != "$confirm_password" ]; then
        send_server_command "Passwords do not match"
        return 1
    fi
    
    # REQUIRED: Validate password requirements
    local validation_result=$(validate_password "$password")
    if [ $? -ne 0 ]; then
        send_server_command "$validation_result"
        return 1
    fi
    
    # Update password in players.log
    update_players_log "$player_name" "password" "$password"
    send_server_command "Password set successfully for $player_name"
    return 0
}

# Function to handle IP change verification - EXACT FLOW AS REQUIRED
handle_ip_change() {
    local player_name="$1" provided_password="$2" current_ip="$3"
    
    # REQUIRED: Clear chat first
    clear_chat
    
    # Verify password - REQUIRED
    read_players_log
    local stored_password="${players_data["$player_name,password"]}"
    
    if [ "$stored_password" = "NONE" ]; then
        send_server_command "No password set for $player_name. Use !password first."
        return 1
    fi
    
    if [ "$provided_password" != "$stored_password" ]; then
        send_server_command "Incorrect password for IP verification"
        return 1
    fi
    
    # Update IP in players.log
    update_players_log "$player_name" "ip" "$current_ip"
    send_server_command "IP address verified and updated for $player_name"
    
    # Clear pending verification
    unset ip_verify_pending["$player_name"]
    return 0
}

# Function to handle password change - EXACT FLOW AS REQUIRED
handle_password_change() {
    local player_name="$1" old_password="$2" new_password="$3"
    
    # REQUIRED: Clear chat first
    clear_chat
    
    # Verify old password - REQUIRED
    read_players_log
    local stored_password="${players_data["$player_name,password"]}"
    
    if [ "$stored_password" = "NONE" ]; then
        send_server_command "No existing password found for $player_name"
        return 1
    fi
    
    if [ "$old_password" != "$stored_password" ]; then
        send_server_command "Incorrect old password"
        return 1
    fi
    
    # REQUIRED: Validate new password
    local validation_result=$(validate_password "$new_password")
    if [ $? -ne 0 ]; then
        send_server_command "$validation_result"
        return 1
    fi
    
    # Update password
    update_players_log "$player_name" "password" "$new_password"
    send_server_command "Password changed successfully for $player_name"
    return 0
}

# Function to monitor console.log for events - WITH 5 SECOND DELAY FOR WELCOME MESSAGES
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
        # Detect player connections
        if [[ "$line" =~ Player\ Connected\ ([a-zA-Z0-9_]+)\ \|\ ([0-9a-fA-F.:]+) ]]; then
            local player_name="${BASH_REMATCH[1]}"
            local player_ip="${BASH_REMATCH[2]}"
            
            print_success "Player connected: $player_name ($player_ip)"
            
            # Add to connected players
            connected_players["$player_name"]=1
            player_ip_map["$player_name"]="$player_ip"
            
            # Check if player exists in players.log
            read_players_log
            if [ -z "${players_data["$player_name,name"]}" ]; then
                # New player - add to players.log
                add_new_player "$player_name" "$player_ip"
                
                # REQUIRED: Wait 5 seconds before sending welcome message
                wait_welcome_delay
                
                # REQUIRED: Request password setup
                send_server_command "Welcome $player_name! Please set a password using: !password YOUR_PASSWORD CONFIRM_PASSWORD"
                password_pending["$player_name"]=$(date +%s)
            else
                # Existing player - check IP
                local stored_ip="${players_data["$player_name,ip"]}"
                local stored_password="${players_data["$player_name,password"]}"
                
                if [ "$stored_ip" != "$player_ip" ] && [ "$stored_ip" != "UNKNOWN" ]; then
                    # IP changed - require verification
                    # REQUIRED: Wait 5 seconds before sending warning
                    wait_welcome_delay
                    send_server_command "IP change detected for $player_name. Verify with: !ip_change YOUR_PASSWORD"
                    ip_verify_pending["$player_name"]=$(date +%s)
                fi
                
                # Check if password is set
                if [ "$stored_password" = "NONE" ]; then
                    # REQUIRED: Wait 5 seconds before sending message
                    wait_welcome_delay
                    send_server_command "Welcome back $player_name! Please set a password using: !password YOUR_PASSWORD CONFIRM_PASSWORD"
                    password_pending["$player_name"]=$(date +%s)
                fi
            fi
            
            # Sync lists after connection
            sync_server_lists
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
            
            # Sync lists after disconnection
            sync_server_lists
            continue
        fi
        
        # Detect chat messages and commands - EXACT COMMAND FORMATS AS REQUIRED
        if [[ "$line" =~ ([a-zA-Z0-9_]+):\ (.+)$ ]]; then
            local player_name="${BASH_REMATCH[1]}"
            local message="${BASH_REMATCH[2]}"
            
            # Skip server messages
            [ "$player_name" = "SERVER" ] && continue
            
            # Process commands - EXACT COMMAND NAMES AS REQUIRED
            case "$message" in
                "!password "*)
                    if [[ "$message" =~ !password\ ([^ ]+)\ ([^ ]+) ]]; then
                        local password="${BASH_REMATCH[1]}"
                        local confirm_password="${BASH_REMATCH[2]}"
                        handle_password_command "$player_name" "$password" "$confirm_password"
                        unset password_pending["$player_name"]
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

# Function to monitor players.log for changes every 1 second - EXACT REQUIREMENT
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
                        local old_blacklisted="${old_players_data["$player_name,blacklisted"]:-NO}"
                        local new_blacklisted="${players_data["$player_name,blacklisted"]:-NO}"
                        local player_ip="${players_data["$name,ip"]}"
                        
                        # Handle rank changes
                        if [ "$old_rank" != "$new_rank" ]; then
                            handle_rank_change "$player_name" "$old_rank" "$new_rank"
                        fi
                        
                        # Handle blacklist changes
                        if [ "$old_blacklisted" != "$new_blacklisted" ]; then
                            handle_blacklist_change "$player_name" "$new_blacklisted" "$player_ip"
                        fi
                    fi
                done
                
                # Sync server lists
                sync_server_lists
                
                last_modified="$current_modified"
            fi
        fi
        
        sleep 1  # REQUIRED: Monitor every 1 second
    done
}

# Function to check timeouts - EXACT TIMEOUT VALUES AS REQUIRED
check_timeouts() {
    local current_time=$(date +%s)
    
    # Check password setup timeouts - REQUIRED: 1 minute timeout
    for player in "${!password_pending[@]}"; do
        local start_time="${password_pending[$player]}"
        if [ $((current_time - start_time)) -ge $PASSWORD_TIMEOUT ]; then
            send_server_command "/kick $player"
            send_server_command "Player $player kicked for not setting password within timeout"
            unset password_pending["$player"]
            print_warning "Kicked $player for password setup timeout"
        fi
    done
    
    # Check IP verification timeouts - REQUIRED: 30 second timeout
    for player in "${!ip_verify_pending[@]}"; do
        local start_time="${ip_verify_pending[$player]}"
        if [ $((current_time - start_time)) -ge $IP_VERIFY_TIMEOUT ]; then
            local player_ip="${player_ip_map[$player]}"
            send_server_command "/kick $player"
            send_server_command "/ban $player_ip"
            unset ip_verify_pending["$player"]
            print_warning "Kicked and IP banned $player for IP verification timeout"
            
            # Track ban for auto-unban - REQUIRED
            ip_banned_times["$player_ip"]=$(date +%s)
        fi
    done
    
    # Auto-unban IPs after duration - REQUIRED: 30 second auto-unban
    auto_unban_ips
}

# Main execution
main() {
    print_header "THE BLOCKHEADS RANK PATCHER"
    print_status "Starting player management system..."
    
    # Check if console log exists
    if [ ! -f "$CONSOLE_LOG" ]; then
        print_error "Console log not found: $CONSOLE_LOG"
        print_status "Waiting for log file to be created..."
        
        # Wait for log file - FIX for "couldn't create log file"
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
    
    # Check if bc is available for floating point calculations
    if ! command -v bc &> /dev/null; then
        print_error "bc command is required for cooldown calculations. Please install it:"
        print_status "Ubuntu/Debian: sudo apt-get install bc"
        print_status "CentOS/RHEL: sudo yum install bc"
        exit 1
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
