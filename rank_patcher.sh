#!/bin/bash

# rank_patcher.sh - Complete player management system for The Blockheads server
# Compatible with Ubuntu 22.04 Server and GNUstep

set -e

# Enhanced Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
ORANGE='\033[0;33m'
PURPLE='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

# Function to print status messages
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_header() {
    echo -e "${PURPLE}================================================================================${NC}"
    echo -e "${PURPLE}$1${NC}"
    echo -e "${PURPLE}================================================================================${NC}"
}

print_step() {
    echo -e "${CYAN}[STEP]${NC} $1"
}

print_progress() {
    echo -e "${MAGENTA}[PROGRESS]${NC} $1"
}

# Configuration
WORLD_ID="$1"
PORT="$2"
SCREEN_SERVER="blockheads_server_$PORT"
BASE_DIR="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads"
SAVES_DIR="$BASE_DIR/saves"
WORLD_DIR="$SAVES_DIR/$WORLD_ID"

# Core files
PLAYERS_LOG="$WORLD_DIR/players.log"
CONSOLE_LOG="$WORLD_DIR/console.log"
ADMIN_LIST="$WORLD_DIR/adminlist.txt"
MOD_LIST="$WORLD_DIR/modlist.txt"
WHITELIST="$WORLD_DIR/whitelist.txt"
BLACKLIST="$WORLD_DIR/blacklist.txt"
CLOUD_ADMIN_LIST="$BASE_DIR/cloudWideOwnedAdminlist.txt"

# Temporary files
TEMP_PLAYERS="/tmp/players_temp_$$.log"
TEMP_CONSOLE="/tmp/console_temp_$$.log"

# Track connected players
declare -A CONNECTED_PLAYERS
declare -A PLAYER_IPS
declare -A PASSWORD_TIMERS
declare -A IP_VERIFICATION_TIMERS

# Function to send command to server screen
send_server_command() {
    local command="$1"
    print_progress "Sending command to server: $command"
    if screen -S "$SCREEN_SERVER" -X stuff "$command$(printf \\r)" 2>/dev/null; then
        return 0
    else
        print_error "Failed to send command to server screen: $SCREEN_SERVER"
        return 1
    fi
}

# Function to wait for cooldown
cooldown() {
    sleep 0.5
}

# Function to clear chat
clear_chat() {
    send_server_command "/clear"
}

# Function to validate password
validate_password() {
    local password="$1"
    local length=${#password}
    
    if [ "$length" -lt 7 ] || [ "$length" -gt 16 ]; then
        echo "Password must be between 7 and 16 characters"
        return 1
    fi
    
    if [[ ! "$password" =~ ^[a-zA-Z0-9_@#%&*+-=]+$ ]]; then
        echo "Password can only contain letters, numbers and: _@#%&*+-="
        return 1
    fi
    
    return 0
}

# Function to find player in players.log
find_player() {
    local player_name="$1"
    local players_file="${2:-$PLAYERS_LOG}"
    
    if [ ! -f "$players_file" ]; then
        return 1
    fi
    
    # Case insensitive search
    grep -i "^$player_name|" "$players_file" | head -1
}

# Function to update player record
update_player() {
    local player_name="$1"
    local field="$2"
    local value="$3"
    
    if [ ! -f "$PLAYERS_LOG" ]; then
        print_error "players.log does not exist"
        return 1
    fi
    
    # Create temp file
    local temp_file="/tmp/players_update_$$.log"
    
    # Update the specific field for the player
    awk -F'|' -v player="$player_name" -v field="$field" -v value="$value" '
    BEGIN { OFS="|"; IGNORECASE=1 }
    $1 == player {
        if (field == "name") $1 = value
        if (field == "ip") $2 = value
        if (field == "password") $3 = value
        if (field == "rank") $4 = value
        if (field == "whitelisted") $5 = value
        if (field == "blacklisted") $6 = value
    }
    { print }
    ' "$PLAYERS_LOG" > "$temp_file"
    
    # Replace original file
    mv "$temp_file" "$PLAYERS_LOG"
    print_success "Updated $field for $player_name to $value"
}

# Function to add new player
add_new_player() {
    local player_name="$1"
    local ip_address="$2"
    
    # Convert to uppercase for consistency
    player_name=$(echo "$player_name" | tr '[:lower:]' '[:upper:]')
    
    if find_player "$player_name"; then
        print_warning "Player $player_name already exists in players.log"
        return 1
    fi
    
    local entry="$player_name|$ip_address|NONE|NONE|NO|NO"
    echo "$entry" >> "$PLAYERS_LOG"
    print_success "Added new player: $entry"
}

# Function to sync lists from players.log
sync_lists_from_players() {
    print_step "Synchronizing lists from players.log..."
    
    # Clear existing lists (but preserve first line)
    if [ -f "$ADMIN_LIST" ]; then
        local admin_first_line=$(head -1 "$ADMIN_LIST")
        echo "$admin_first_line" > "$ADMIN_LIST"
    fi
    
    if [ -f "$MOD_LIST" ]; then
        local mod_first_line=$(head -1 "$MOD_LIST")
        echo "$mod_first_line" > "$MOD_LIST"
    fi
    
    if [ -f "$WHITELIST" ]; then
        local whitelist_first_line=$(head -1 "$WHITELIST")
        echo "$whitelist_first_line" > "$WHITELIST"
    fi
    
    if [ -f "$BLACKLIST" ]; then
        local blacklist_first_line=$(head -1 "$BLACKLIST")
        echo "$blacklist_first_line" > "$BLACKLIST"
    fi
    
    # Read players.log and update lists for connected and verified players
    while IFS='|' read -r name ip password rank whitelisted blacklisted; do
        # Remove leading/trailing spaces
        name=$(echo "$name" | xargs)
        ip=$(echo "$ip" | xargs)
        password=$(echo "$password" | xargs)
        rank=$(echo "$rank" | xargs)
        whitelisted=$(echo "$whitelisted" | xargs)
        blacklisted=$(echo "$blacklisted" | xargs)
        
        # Check if player is connected and IP verified
        if [[ "${CONNECTED_PLAYERS[$name]}" == "true" && "$ip" != "UNKNOWN" && "$ip" == "${PLAYER_IPS[$name]}" ]]; then
            # Add to appropriate lists based on rank and status
            if [ "$rank" == "ADMIN" ] && [ "$blacklisted" != "YES" ]; then
                echo "$name" >> "$ADMIN_LIST"
            elif [ "$rank" == "MOD" ] && [ "$blacklisted" != "YES" ]; then
                echo "$name" >> "$MOD_LIST"
            fi
            
            if [ "$whitelisted" == "YES" ]; then
                echo "$name" >> "$WHITELIST"
            fi
            
            if [ "$blacklisted" == "YES" ]; then
                echo "$name" >> "$BLACKLIST"
            fi
        fi
    done < "$PLAYERS_LOG"
    
    print_success "Lists synchronized from players.log"
}

# Function to handle rank changes
handle_rank_change() {
    local player_name="$1"
    local old_rank="$2"
    local new_rank="$3"
    
    print_step "Processing rank change for $player_name: $old_rank -> $new_rank"
    
    case "$new_rank" in
        "ADMIN")
            if [ "$old_rank" == "NONE" ]; then
                cooldown
                send_server_command "/admin $player_name"
                print_success "Promoted $player_name to ADMIN"
            fi
            ;;
        "MOD")
            if [ "$old_rank" == "NONE" ]; then
                cooldown
                send_server_command "/mod $player_name"
                print_success "Promoted $player_name to MOD"
            fi
            ;;
        "SUPER")
            # Create cloud admin list if it doesn't exist
            if [ ! -f "$CLOUD_ADMIN_LIST" ]; then
                echo "# Cloud Wide Owned Admin List" > "$CLOUD_ADMIN_LIST"
                print_success "Created cloudWideOwnedAdminlist.txt"
            fi
            
            # Add player to cloud admin list (skip first line)
            if ! tail -n +2 "$CLOUD_ADMIN_LIST" | grep -q "^$player_name$"; then
                echo "$player_name" >> "$CLOUD_ADMIN_LIST"
                print_success "Added $player_name to cloudWideOwnedAdminlist.txt"
            fi
            ;;
        "NONE")
            if [ "$old_rank" == "ADMIN" ]; then
                cooldown
                send_server_command "/unadmin $player_name"
                print_success "Demoted $player_name from ADMIN to NONE"
            elif [ "$old_rank" == "MOD" ]; then
                cooldown
                send_server_command "/unmod $player_name"
                print_success "Demoted $player_name from MOD to NONE"
            elif [ "$old_rank" == "SUPER" ]; then
                # Remove from cloud admin list
                if [ -f "$CLOUD_ADMIN_LIST" ]; then
                    local temp_file="/tmp/cloud_admin_$$.txt"
                    head -1 "$CLOUD_ADMIN_LIST" > "$temp_file"
                    grep -v "^$player_name$" <(tail -n +2 "$CLOUD_ADMIN_LIST") >> "$temp_file"
                    mv "$temp_file" "$CLOUD_ADMIN_LIST"
                    print_success "Removed $player_name from cloudWideOwnedAdminlist.txt"
                    
                    # Delete file if empty (except first line)
                    if [ $(wc -l < "$CLOUD_ADMIN_LIST") -le 1 ]; then
                        rm -f "$CLOUD_ADMIN_LIST"
                        print_success "Removed empty cloudWideOwnedAdminlist.txt"
                    fi
                fi
            fi
            ;;
    esac
    
    # Sync lists after rank change
    sync_lists_from_players
}

# Function to handle blacklist changes
handle_blacklist_change() {
    local player_name="$1"
    local blacklisted="$2"
    local player_ip="$3"
    
    if [ "$blacklisted" == "YES" ]; then
        print_step "Blacklisting player: $player_name"
        
        # Remove ranks first
        cooldown
        send_server_command "/unmod $player_name"
        cooldown
        send_server_command "/unadmin $player_name"
        
        # Ban player and IP
        cooldown
        send_server_command "/ban $player_name"
        cooldown
        send_server_command "/ban $player_ip"
        
        # Remove from cloud admin list if SUPER
        local player_record=$(find_player "$player_name")
        local current_rank=$(echo "$player_record" | cut -d'|' -f4 | xargs)
        
        if [ "$current_rank" == "SUPER" ]; then
            cooldown
            send_server_command "/stop"
            
            if [ -f "$CLOUD_ADMIN_LIST" ]; then
                local temp_file="/tmp/cloud_admin_$$.txt"
                head -1 "$CLOUD_ADMIN_LIST" > "$temp_file"
                grep -v "^$player_name$" <(tail -n +2 "$CLOUD_ADMIN_LIST") >> "$temp_file"
                mv "$temp_file" "$CLOUD_ADMIN_LIST"
                
                # Delete file if empty
                if [ $(wc -l < "$CLOUD_ADMIN_LIST") -le 1 ]; then
                    rm -f "$CLOUD_ADMIN_LIST"
                fi
            fi
        fi
        
        print_success "Blacklisted $player_name and banned IP $player_ip"
    fi
    
    sync_lists_from_players
}

# Function to monitor players.log for changes
monitor_players_log() {
    print_header "STARTING PLAYERS.LOG MONITOR"
    
    local last_checksum=""
    
    while true; do
        if [ -f "$PLAYERS_LOG" ]; then
            local current_checksum=$(md5sum "$PLAYERS_LOG" 2>/dev/null | cut -d' ' -f1)
            
            if [ "$current_checksum" != "$last_checksum" ]; then
                print_progress "Detected change in players.log"
                
                # Process changes
                process_players_log_changes
                
                last_checksum="$current_checksum"
            fi
        fi
        
        sleep 1
    done
}

# Function to process changes in players.log
process_players_log_changes() {
    # This would compare with previous state and detect specific changes
    # For now, we'll just sync the lists
    sync_lists_from_players
}

# Function to handle !psw command
handle_password_set() {
    local player_name="$1"
    local password="$2"
    local confirm_password="$3"
    
    print_step "Processing password set for $player_name"
    
    # Clear chat immediately
    clear_chat
    
    # Wait cooldown
    cooldown
    
    # Validate passwords match
    if [ "$password" != "$confirm_password" ]; then
        send_server_command "Password confirmation does not match. Please try again."
        return 1
    fi
    
    # Validate password requirements
    local validation_result=$(validate_password "$password")
    if [ $? -ne 0 ]; then
        send_server_command "Error: $validation_result"
        return 1
    fi
    
    # Update player record
    update_player "$player_name" "password" "$password"
    
    # Send success message
    send_server_command "Password set successfully for $player_name"
    print_success "Password set for $player_name"
    
    return 0
}

# Function to handle !change_psw command
handle_password_change() {
    local player_name="$1"
    local old_password="$2"
    local new_password="$3"
    
    print_step "Processing password change for $player_name"
    
    # Clear chat immediately
    clear_chat
    
    # Wait cooldown
    cooldown
    
    # Verify old password
    local player_record=$(find_player "$player_name")
    local current_password=$(echo "$player_record" | cut -d'|' -f3 | xargs)
    
    if [ "$current_password" != "$old_password" ]; then
        send_server_command "Current password is incorrect."
        return 1
    fi
    
    # Validate new password
    local validation_result=$(validate_password "$new_password")
    if [ $? -ne 0 ]; then
        send_server_command "Error: $validation_result"
        return 1
    fi
    
    # Update password
    update_player "$player_name" "password" "$new_password"
    
    send_server_command "Password changed successfully for $player_name"
    print_success "Password changed for $player_name"
    
    return 0
}

# Function to handle !ip_change command
handle_ip_change() {
    local player_name="$1"
    local current_password="$2"
    local new_ip="$3"
    
    print_step "Processing IP change for $player_name"
    
    # Clear chat immediately
    clear_chat
    
    # Wait cooldown
    cooldown
    
    # Verify password
    local player_record=$(find_player "$player_name")
    local stored_password=$(echo "$player_record" | cut -d'|' -f3 | xargs)
    
    if [ "$stored_password" != "$current_password" ]; then
        send_server_command "Password is incorrect. IP change failed."
        return 1
    fi
    
    # Update IP
    update_player "$player_name" "ip" "$new_ip"
    
    send_server_command "IP address updated successfully for $player_name"
    print_success "IP updated for $player_name to $new_ip"
    
    return 0
}

# Function to monitor console.log for commands
monitor_console_log() {
    print_header "STARTING CONSOLE.LOG MONITOR"
    
    # Create console.log if it doesn't exist
    touch "$CONSOLE_LOG"
    
    # Monitor the console log for player commands
    tail -n 0 -F "$CONSOLE_LOG" | while read line; do
        # Detect player connections
        if [[ "$line" =~ Player\ Connected\ ([a-zA-Z0-9_]+)\ \|\ ([0-9.]+) ]]; then
            local player_name="${BASH_REMATCH[1]}"
            local player_ip="${BASH_REMATCH[2]}"
            
            handle_player_connect "$player_name" "$player_ip"
        fi
        
        # Detect player disconnections
        if [[ "$line" =~ Player\ Disconnected\ ([a-zA-Z0-9_]+) ]]; then
            local player_name="${BASH_REMATCH[1]}"
            
            handle_player_disconnect "$player_name"
        fi
        
        # Detect chat messages and commands
        if [[ "$line" =~ ([a-zA-Z0-9_]+):\ (.+) ]]; then
            local player_name="${BASH_REMATCH[1]}"
            local message="${BASH_REMATCH[2]}"
            
            process_player_message "$player_name" "$message"
        fi
    done
}

# Function to handle player connection
handle_player_connect() {
    local player_name="$1"
    local player_ip="$2"
    
    print_success "Player connected: $player_name ($player_ip)"
    
    # Track connected player
    CONNECTED_PLAYERS["$player_name"]="true"
    PLAYER_IPS["$player_name"]="$player_ip"
    
    # Check if player exists in players.log
    if ! find_player "$player_name"; then
        # Add new player with UNKNOWN IP initially
        add_new_player "$player_name" "UNKNOWN"
    fi
    
    # Get player record
    local player_record=$(find_player "$player_name")
    local stored_ip=$(echo "$player_record" | cut -d'|' -f2 | xargs)
    local password=$(echo "$player_record" | cut -d'|' -f3 | xargs)
    local rank=$(echo "$player_record" | cut -d'|' -f4 | xargs)
    
    # Handle IP verification
    if [ "$stored_ip" == "UNKNOWN" ]; then
        # First time connection, set IP
        update_player "$player_name" "ip" "$player_ip"
        stored_ip="$player_ip"
    fi
    
    # Check if IP matches
    if [ "$stored_ip" != "$player_ip" ]; then
        handle_ip_mismatch "$player_name" "$stored_ip" "$player_ip"
    else
        # IP verified, sync lists
        sync_lists_from_players
    fi
    
    # Handle password requirement
    if [ "$password" == "NONE" ] && [ "$rank" == "NONE" ]; then
        handle_password_requirement "$player_name"
    fi
}

# Function to handle IP mismatch
handle_ip_mismatch() {
    local player_name="$1"
    local stored_ip="$2"
    local current_ip="$3"
    
    print_warning "IP mismatch for $player_name: stored=$stored_ip, current=$current_ip"
    
    # Notify player
    send_server_command "$player_name, your IP has changed. You have 25 seconds to verify with !ip_change CURRENT_PASSWORD"
    
    # Set verification timer
    IP_VERIFICATION_TIMERS["$player_name"]=$(date +%s)
    
    # Schedule IP verification check
    (
        sleep 25
        if [[ "${IP_VERIFICATION_TIMERS[$player_name]}" != "" ]]; then
            print_warning "IP verification timeout for $player_name"
            send_server_command "/kick $player_name"
            send_server_command "/ban $current_ip"
            
            # Unban after 30 seconds
            (
                sleep 30
                send_server_command "/unban $current_ip"
                print_success "Auto-unbanned IP $current_ip"
            ) &
        fi
    ) &
}

# Function to handle password requirement
handle_password_requirement() {
    local player_name="$1"
    
    print_step "Password required for $player_name"
    
    # Wait 5 seconds then send reminder
    (
        sleep 5
        if [[ "${CONNECTED_PLAYERS[$player_name]}" == "true" ]]; then
            send_server_command "$player_name, please set your password using !psw NEW_PASSWORD CONFIRM_PASSWORD within 60 seconds"
        fi
    ) &
    
    # Set password timer
    PASSWORD_TIMERS["$player_name"]=$(date +%s)
    
    # Schedule password requirement check
    (
        sleep 60
        if [[ "${PASSWORD_TIMERS[$player_name]}" != "" ]]; then
            local player_record=$(find_player "$player_name")
            local password=$(echo "$player_record" | cut -d'|' -f3 | xargs)
            
            if [ "$password" == "NONE" ]; then
                print_warning "Password not set for $player_name within timeout, kicking"
                send_server_command "/kick $player_name"
            fi
        fi
    ) &
}

# Function to handle player disconnect
handle_player_disconnect() {
    local player_name="$1"
    
    print_warning "Player disconnected: $player_name"
    
    # Remove from connected players
    unset CONNECTED_PLAYERS["$player_name"]
    unset PLAYER_IPS["$player_name"]
    unset PASSWORD_TIMERS["$player_name"]
    unset IP_VERIFICATION_TIMERS["$player_name"]
    
    # Sync lists (player is no longer connected)
    sync_lists_from_players
}

# Function to process player messages and commands
process_player_message() {
    local player_name="$1"
    local message="$2"
    
    print_progress "Chat: $player_name: $message"
    
    # Handle !psw command
    if [[ "$message" =~ ^!psw\ ([a-zA-Z0-9_@#%&*+-=]+)\ ([a-zA-Z0-9_@#%&*+-=]+)$ ]]; then
        local password="${BASH_REMATCH[1]}"
        local confirm_password="${BASH_REMATCH[2]}"
        
        handle_password_set "$player_name" "$password" "$confirm_password"
        
        # Clear password timer if set
        unset PASSWORD_TIMERS["$player_name"]
    fi
    
    # Handle !psw without confirmation (still clear chat)
    if [[ "$message" =~ ^!psw\ ([a-zA-Z0-9_@#%&*+-=]+)$ ]]; then
        clear_chat
        cooldown
        send_server_command "Usage: !psw PASSWORD CONFIRM_PASSWORD"
    fi
    
    # Handle !change_psw command
    if [[ "$message" =~ ^!change_psw\ ([a-zA-Z0-9_@#%&*+-=]+)\ ([a-zA-Z0-9_@#%&*+-=]+)$ ]]; then
        local old_password="${BASH_REMATCH[1]}"
        local new_password="${BASH_REMATCH[2]}"
        
        handle_password_change "$player_name" "$old_password" "$new_password"
    fi
    
    # Handle !ip_change command
    if [[ "$message" =~ ^!ip_change\ ([a-zA-Z0-9_@#%&*+-=]+)$ ]]; then
        local current_password="${BASH_REMATCH[1]}"
        local current_ip="${PLAYER_IPS[$player_name]}"
        
        handle_ip_change "$player_name" "$current_password" "$current_ip"
        
        # Clear IP verification timer
        unset IP_VERIFICATION_TIMERS["$player_name"]
    fi
}

# Function to initialize players.log
initialize_players_log() {
    print_header "INITIALIZING PLAYERS.LOG SYSTEM"
    
    # Check if world directory exists
    if [ ! -d "$WORLD_DIR" ]; then
        print_error "World directory does not exist: $WORLD_DIR"
        print_error "Please create a world first using: ./blockheads_server171 -n"
        exit 1
    fi
    
    # Create players.log if it doesn't exist
    if [ ! -f "$PLAYERS_LOG" ]; then
        print_step "Creating players.log..."
        touch "$PLAYERS_LOG"
        print_success "Created players.log: $PLAYERS_LOG"
    else
        print_success "players.log already exists: $PLAYERS_LOG"
    fi
    
    # Initialize other required files
    for list_file in "$ADMIN_LIST" "$MOD_LIST" "$WHITELIST" "$BLACKLIST"; do
        if [ ! -f "$list_file" ]; then
            print_step "Creating $(basename "$list_file")..."
            echo "# $(basename "$list_file" | sed 's/\.txt//' | tr '[:lower:]' '[:upper:]') List" > "$list_file"
            print_success "Created $list_file"
        fi
    done
    
    print_success "Player management system initialized"
}

# Main function
main() {
    print_header "THE BLOCKHEADS RANK PATCHER"
    print_status "World ID: $WORLD_ID"
    print_status "Port: $PORT"
    print_status "World Directory: $WORLD_DIR"
    
    # Validate parameters
    if [ -z "$WORLD_ID" ] || [ -z "$PORT" ]; then
        print_error "Usage: $0 <WORLD_ID> <PORT>"
        print_error "Example: $0 6f4edaf5a311a2bbc960d0cd5b45736a 12154"
        exit 1
    fi
    
    # Check if server screen session exists
    if ! screen -list | grep -q "$SCREEN_SERVER"; then
        print_error "Server screen session not found: $SCREEN_SERVER"
        print_error "Please start the server first using server_manager.sh"
        exit 1
    fi
    
    # Initialize system
    initialize_players_log
    
    # Start monitoring in background processes
    print_header "STARTING MONITORING PROCESSES"
    
    # Monitor console.log for commands
    monitor_console_log &
    local console_monitor_pid=$!
    
    # Monitor players.log for changes
    monitor_players_log &
    local players_monitor_pid=$!
    
    print_success "Rank patcher started successfully"
    print_status "Console monitor PID: $console_monitor_pid"
    print_status "Players monitor PID: $players_monitor_pid"
    print_header "RANK PATCHER IS NOW RUNNING"
    
    # Wait for background processes
    wait $console_monitor_pid
    wait $players_monitor_pid
}

# Signal handling
cleanup() {
    print_header "CLEANING UP RANK PATCHER"
    kill $(jobs -p) 2>/dev/null
    rm -f "$TEMP_PLAYERS" "$TEMP_CONSOLE"
    print_success "Cleanup completed"
    exit 0
}

trap cleanup EXIT INT TERM

# Start main function
main "$@"
