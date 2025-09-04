#!/bin/bash
# anticheat_secure.sh - Enhanced security system for The Blockheads server
# Improved for new users: Better error messages, fixed file locking issues

# Enhanced Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m' # No Color

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
LOG_FILE="$1"
PORT="$2"
LOG_DIR=$(dirname "$LOG_FILE")
ADMIN_OFFENSES_FILE="$LOG_DIR/admin_offenses_$PORT.json"
AUTHORIZED_ADMINS_FILE="$LOG_DIR/authorized_admins.txt"
AUTHORIZED_MODS_FILE="$LOG_DIR/authorized_mods.txt"
SCREEN_SERVER="blockheads_server_$PORT"

# Function to validate player names - ENHANCED TO DETECT SPACES/EMPTY NAMES
is_valid_player_name() {
    local player_name="$1"
    
    # Check if name is empty or contains only spaces
    if [[ -z "$player_name" || "$player_name" =~ ^[[:space:]]+$ ]]; then
        return 1
    fi
    
    # Check if name contains any spaces or special characters
    if [[ "$player_name" =~ [[:space:]] || ! "$player_name" =~ ^[a-zA-Z0-9_]+$ ]]; then
        return 1
    fi
    
    return 0
}

# Function to safely read JSON files with locking
read_json_file() {
    local file_path="$1"
    if [ ! -f "$file_path" ]; then
        print_error "JSON file not found: $file_path"
        echo "{}"
        return 1
    fi
    
    # Use flock with proper file descriptor handling
    flock -s 200 cat "$file_path" 200>"${file_path}.lock"
}

# Function to safely write JSON files with locking
write_json_file() {
    local file_path="$1"
    local content="$2"
    
    if [ ! -f "$file_path" ]; then
        print_error "JSON file not found: $file_path"
        return 1
    fi
    
    # Use flock with proper file descriptor handling
    flock -x 200 echo "$content" > "$file_path" 200>"${file_path}.lock"
    return $?
}

# Function to initialize authorization files
initialize_authorization_files() {
    [ ! -f "$AUTHORIZED_ADMINS_FILE" ] && touch "$AUTHORIZED_ADMINS_FILE" && print_success "Created authorized admins file: $AUTHORIZED_ADMINS_FILE"
    [ ! -f "$AUTHORIZED_MODS_FILE" ] && touch "$AUTHORIZED_MODS_FILE" && print_success "Created authorized mods file: $AUTHORIZED_MODS_FILE"
}

# Function to check and correct admin/mod lists
validate_authorization() {
    local admin_list="$LOG_DIR/adminlist.txt"
    local mod_list="$LOG_DIR/modlist.txt"
    
    # Check adminlist.txt against authorized_admins.txt
    if [ -f "$admin_list" ]; then
        while IFS= read -r admin; do
            if [[ -n "$admin" && ! "$admin" =~ ^[[:space:]]*# && ! "$admin" =~ "Usernames in this file" ]]; then
                if ! grep -q -i "^$admin$" "$AUTHORIZED_ADMINS_FILE"; then
                    print_warning "Unauthorized admin detected: $admin"
                    send_server_command "/unadmin $admin"
                    remove_from_list_file "$admin" "admin"
                    print_success "Removed unauthorized admin: $admin"
                fi
            fi
        done < <(grep -v "^[[:space:]]*#" "$admin_list" 2>/dev/null || true)
    fi
    
    # Check modlist.txt against authorized_mods.txt
    if [ -f "$mod_list" ]; then
        while IFS= read -r mod; do
            if [[ -n "$mod" && ! "$mod" =~ ^[[:space:]]*# && ! "$mod" =~ "Usernames in this file" ]]; then
                if ! grep -q -i "^$mod$" "$AUTHORIZED_MODS_FILE"; then
                    print_warning "Unauthorized mod detected: $mod"
                    send_server_command "/unmod $mod"
                    remove_from_list_file "$mod" "mod"
                    print_success "Removed unauthorized mod: $mod"
                fi
            fi
        done < <(grep -v "^[[:space:]]*#" "$mod_list" 2>/dev/null || true)
    fi
}

# Function to add player to authorized list
add_to_authorized() {
    local player_name="$1" list_type="$2"
    local auth_file="$LOG_DIR/authorized_${list_type}s.txt"
    
    [ ! -f "$auth_file" ] && print_error "Authorization file not found: $auth_file" && return 1
    
    if ! grep -q -i "^$player_name$" "$auth_file"; then
        echo "$player_name" >> "$auth_file"
        print_success "Added $player_name to authorized ${list_type}s"
        return 0
    else
        print_warning "$player_name is already in authorized ${list_type}s"
        return 1
    fi
}

# Function to remove player from authorized list
remove_from_authorized() {
    local player_name="$1" list_type="$2"
    local auth_file="$LOG_DIR/authorized_${list_type}s.txt"
    
    [ ! -f "$auth_file" ] && print_error "Authorization file not found: $auth_file" && return 1
    
    # Use case-insensitive deletion with sed
    if grep -q -i "^$player_name$" "$auth_file"; then
        sed -i "/^$player_name$/Id" "$auth_file"
        print_success "Removed $player_name from authorized ${list_type}s"
        return 0
    else
        print_warning "Player $player_name not found in authorized ${list_type}s"
        return 1
    fi
}

# Initialize admin offenses tracking
initialize_admin_offenses() {
    [ ! -f "$ADMIN_OFFENSES_FILE" ] && echo '{}' > "$ADMIN_OFFENSES_FILE" && 
    print_success "Admin offenses tracking file created: $ADMIN_OFFENSES_FILE"
}

# Function to record admin offense
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

# Function to clear admin offenses
clear_admin_offenses() {
    local admin_name="$1"
    local offenses_data=$(read_json_file "$ADMIN_OFFENSES_FILE" 2>/dev/null || echo '{}')
    offenses_data=$(echo "$offenses_data" | jq --arg admin "$admin_name" 'del(.[$admin])')
    write_json_file "$ADMIN_OFFENSES_FILE" "$offenses_data"
    print_success "Cleared offenses for admin $admin_name"
}

# Function to remove player from list file
remove_from_list_file() {
    local player_name="$1" list_type="$2"
    local list_file="$LOG_DIR/${list_type}list.txt"
    
    [ ! -f "$list_file" ] && print_error "List file not found: $list_file" && return 1
    
    # Use case-insensitive deletion with sed
    if grep -v "^[[:space:]]*#" "$list_file" 2>/dev/null | grep -q -i "^$player_name$"; then
        sed -i "/^$player_name$/Id" "$list_file"
        print_success "Removed $player_name from ${list_type}list.txt"
        return 0
    else
        print_warning "Player $player_name not found in ${list_type}list.txt"
        return 1
    fi
}

# Function to send delayed unadmin/unmod commands (SILENT VERSION)
send_delayed_uncommands() {
    local target_player="$1" command_type="$2"
    (
        sleep 2; send_server_command_silent "/un${command_type} $target_player"
        sleep 2; send_server_command_silent "/un${command_type} $target_player"
        sleep 1; send_server_command_silent "/un${command_type} $target_player"
        remove_from_list_file "$target_player" "$command_type"
    ) &
}

# Silent version of send_server_command
send_server_command_silent() {
    screen -S "$SCREEN_SERVER" -X stuff "$1$(printf \\r)" 2>/dev/null
}

# Function to send server command
send_server_command() {
    if screen -S "$SCREEN_SERVER" -X stuff "$1$(printf \\r)" 2>/dev/null; then
        print_success "Sent message to server: $1"
    else
        print_error "Could not send message to server. Is the server running?"
    fi
}

# Function to check if player is in list
is_player_in_list() {
    local player_name="$1" list_type="$2"
    local list_file="$LOG_DIR/${list_type}list.txt"
    
    [ -f "$list_file" ] && grep -v "^[[:space:]]*#" "$list_file" 2>/dev/null | grep -q -i "^$player_name$" && return 0
    return 1
}

# Function to handle unauthorized admin/mod commands
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
            print_success "Revoked ${command_type} rank from $target_player"
            send_delayed_uncommands "$target_player" "$command_type"
        fi
        
        record_admin_offense "$player_name"
        local offense_count=$?
        
        if [ "$offense_count" -eq 1 ]; then
            send_server_command "$player_name, this is your first warning! Only the server console can assign ranks using !set_admin or !set_mod."
            print_warning "First offense recorded for admin $player_name"
        elif [ "$offense_count" -eq 2 ]; then
            print_warning "SECOND OFFENSE: Admin $player_name is being demoted to mod for unauthorized command usage"
            
            # First add to authorized mods before removing admin privileges
            add_to_authorized "$player_name" "mod"
            
            # Remove from authorized admins
            remove_from_authorized "$player_name" "admin"
            
            # Remove admin privileges
            send_server_command_silent "/unadmin $player_name"
            remove_from_list_file "$player_name" "admin"
            
            # Assign mod rank - ensure the player is added to modlist before sending the command
            send_server_command "/mod $player_name"
            send_server_command "ALERT: Admin $player_name has been demoted to moderator for repeatedly attempting unauthorized admin commands!"
            send_server_command "Only the server console can assign ranks using !set_admin or !set_mod."
            
            # Clear offenses after punishment
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

# Filter server log to exclude certain messages
filter_server_log() {
    while read line; do
        [[ "$line" == *"Server closed"* || "$line" == *"Starting server"* || \
          ("$line" == *"SERVER: say"* && "$line" == *"Welcome"*) || \
          "$line" == *"adminlist.txt"* || "$line" == *"modlist.txt"* ]] && continue
        echo "$line"
    done
}

# Cleanup function for signal handling
cleanup() {
    print_status "Cleaning up anticheat..."
    kill $(jobs -p) 2>/dev/null
    # Clean up lock files
    rm -f "${ADMIN_OFFENSES_FILE}.lock" 2>/dev/null
    print_status "Anticheat cleanup done."
    exit 0
}

# Function to detect and handle invalid player names
handle_invalid_player_name() {
    local player_name="$1" player_ip="$2"
    
    # Check if player name is invalid (empty, only spaces, or contains spaces)
    if ! is_valid_player_name "$player_name"; then
        print_warning "INVALID PLAYER NAME DETECTED: '$player_name' (IP: $player_ip)"
        send_server_command "WARNING: Empty player names are not allowed!"
        send_server_command "Kicking player with empty name in 3 seconds..."
        
        # Wait 3 seconds and then kick the player
        (
            sleep 3
            # Escape any special characters in the player name for the kick command
            local safe_player_name=$(printf '%q' "$player_name")
            send_server_command "/kick $safe_player_name"
            print_success "Kicked player with invalid name: $player_name"
        ) &
        
        return 1
    fi
    
    return 0
}

# Main anticheat monitoring function
monitor_log() {
    local log_file="$1"
    LOG_FILE="$log_file"

    initialize_authorization_files
    initialize_admin_offenses

    # Start authorization validation in background
    (
        while true; do 
            sleep 3
            validate_authorization
        done
    ) &
    local validation_pid=$!

    # Set up signal handling
    trap cleanup EXIT INT TERM

    print_header "STARTING ANTICHEAT SECURITY SYSTEM"
    print_status "Monitoring: $log_file"
    print_status "Port: $PORT"
    print_status "Log directory: $LOG_DIR"
    print_header "SECURITY SYSTEM ACTIVE"

    # Monitor the log file for unauthorized commands and invalid player names
    tail -n 0 -F "$log_file" 2>/dev/null | filter_server_log | while read line; do
        # Detect player connections with invalid names
        if [[ "$line" =~ Player\ Connected\ ([^|]+)\ \|\ ([0-9a-fA-F.:]+) ]]; then
            local player_name="${BASH_REMATCH[1]}" player_ip="${BASH_REMATCH[2]}"
            [ "$player_name" == "SERVER" ] && continue
            
            # Trim leading/trailing spaces from player name
            player_name=$(echo "$player_name" | xargs)
            
            # Check for invalid player names
            handle_invalid_player_name "$player_name" "$player_ip"
        fi

        # Detect unauthorized admin/mod commands
        if [[ "$line" =~ ([a-zA-Z0-9_]+):\ \/(admin|mod)\ ([a-zA-Z0-9_]+) ]]; then
            local command_user="${BASH_REMATCH[1]}" command_type="${BASH_REMATCH[2]}" target_player="${BASH_REMATCH[3]}"
            
            # Validate player names
            if ! is_valid_player_name "$command_user" || ! is_valid_player_name "$target_player"; then
                print_warning "Invalid player name in command: $command_user or $target_player"
                continue
            fi
            
            [ "$command_user" != "SERVER" ] && handle_unauthorized_command "$command_user" "/$command_type" "$target_player"
        fi
    done

    wait
    kill $validation_pid 2>/dev/null
}

# Show usage information for new users
show_usage() {
    print_header "ANTICHEAT SECURITY SYSTEM - USAGE"
    print_status "This script monitors for unauthorized admin/mod commands"
    print_status "Usage: $0 <server_log_file> [port]"
    print_status "Example: $0 /path/to/console.log 12153"
    echo ""
    print_warning "Note: This script should be run alongside the server"
    print_warning "It will automatically detect and prevent unauthorized rank assignments"
}

if [ $# -eq 1 ] || [ $# -eq 2 ]; then
    if [ ! -f "$LOG_FILE" ]; then
        print_error "Log file not found: $LOG_FILE"
        print_status "Waiting for log file to be created..."
        
        # Wait for log file to be created
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
