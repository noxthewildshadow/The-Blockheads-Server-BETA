#!/bin/bash

# =============================================================================
# THE BLOCKHEADS ANTICHEAT SECURITY SYSTEM
# =============================================================================

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

# Function definitions
print_status() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_header() {
    echo -e "${PURPLE}================================================================"
    echo -e "$1"
    echo -e "===============================================================${NC}"
}

# Validate jq is installed
if ! command -v jq &> /dev/null; then
    echo -e "${RED}ERROR: jq is required but not installed. Please install jq first.${NC}"
    exit 1
fi

# Initialize variables
LOG_FILE="$1"
PORT="$2"
LOG_DIR=$(dirname "$LOG_FILE")
ADMIN_OFFENSES_FILE="$LOG_DIR/admin_offenses_$PORT.json"
AUTHORIZED_ADMINS_FILE="$LOG_DIR/authorized_admins.txt"
AUTHORIZED_MODS_FILE="$LOG_DIR/authorized_mods.txt"
PLAYERS_LOG="$LOG_DIR/players.log"
SCREEN_SERVER="blockheads_server_$PORT"

# Track player messages for spam detection
declare -A player_message_times
declare -A player_message_counts

# Function to validate player names
is_valid_player_name() {
    local player_name="$1"
    player_name=$(echo "$player_name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [[ -z "$player_name" ]] && return 1
    if [[ "$player_name" =~ ^[A-Za-z0-9_]{1,16}$ ]]; then
        return 0
    else
        return 1
    fi
}

# Function to handle invalid player names
handle_invalid_player_name() {
    local player_name="$1" player_ip="$2" player_hash="$3"
    local clean_name=$(echo "$player_name" | sed 's/\\/\\\\/g; s/"/\\"/g; s/'\''/\\'\''/g')
    print_warning "INVALID PLAYER NAME: '$clean_name' (IP: $player_ip, Hash: $player_hash)"
    send_server_command "WARNING: Invalid player name '$clean_name'! You will be banned for 5 seconds."
    print_warning "Banning player with invalid name: '$clean_name' (IP: $player_ip)"
    if [ -n "$player_ip" ] && [ "$player_ip" != "unknown" ]; then
        send_server_command "/ban $player_ip"
        # Kick the player after banning
        send_server_command "/kick $clean_name"
        (
            sleep 5
            send_server_command "/unban $player_ip"
            print_success "Unbanned IP: $player_ip"
        ) &
    else
        # Fallback: ban by name if IP is not available
        send_server_command "/ban $clean_name"
        send_server_command "/kick $clean_name"
    fi
    return 0
}

# Function to read JSON file with locking
read_json_file() {
    local file_path="$1"
    [ ! -f "$file_path" ] && echo "{}" > "$file_path" && echo "{}" && return 0
    flock -s 200 cat "$file_path" 200>"${file_path}.lock"
}

# Function to write JSON file with locking
write_json_file() {
    local file_path="$1" content="$2"
    [ ! -f "$file_path" ] && touch "$file_path"
    flock -x 200 echo "$content" > "$file_path" 200>"${file_path}.lock"
}

# Function to initialize authorization files
initialize_authorization_files() {
    [ ! -f "$AUTHORIZED_ADMINS_FILE" ] && touch "$AUTHORIZED_ADMINS_FILE"
    [ ! -f "$AUTHORIZED_MODS_FILE" ] && touch "$AUTHORIZED_MODS_FILE"
    [ ! -f "$PLAYERS_LOG" ] && touch "$PLAYERS_LOG"
}

# Function to validate authorization
validate_authorization() {
    local admin_list="$LOG_DIR/adminlist.txt"
    local mod_list="$LOG_DIR/modlist.txt"
    
    [ -f "$admin_list" ] && while IFS= read -r admin || [ -n "$admin" ]; do
        admin=$(echo "$admin" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [[ -z "$admin" || "$admin" =~ ^# || "$admin" =~ "Usernames in this file" ]] && continue
        if ! grep -q -i "^$admin$" "$AUTHORIZED_ADMINS_FILE"; then
            send_server_command "/unadmin $admin"
            remove_from_list_file "$admin" "admin"
        fi
    done < <(grep -v "^[[:space:]]*#" "$admin_list" 2>/dev/null || true)
    
    [ -f "$mod_list" ] && while IFS= read -r mod || [ -n "$mod" ]; do
        mod=$(echo "$mod" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [[ -z "$mod" || "$mod" =~ ^# || "$mod" =~ "Usernames in this file" ]] && continue
        if ! grep -q -i "^$mod$" "$AUTHORIZED_MODS_FILE"; then
            send_server_command "/unmod $mod"
            remove_from_list_file "$mod" "mod"
        fi
    done < <(grep -v "^[[:space:]]*#" "$mod_list" 2>/dev/null || true)
}

# Function to initialize admin offenses
initialize_admin_offenses() {
    [ ! -f "$ADMIN_OFFENSES_FILE" ] && echo '{}' > "$ADMIN_OFFENSES_FILE"
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
}

# Function to remove from list file
remove_from_list_file() {
    local player_name="$1" list_type="$2"
    local list_file="$LOG_DIR/${list_type}list.txt"
    [ ! -f "$list_file" ] && return 1
    if grep -v "^[[:space:]]*#" "$list_file" 2>/dev/null | grep -q -i "^$player_name$"; then
        sed -i "/^$player_name$/Id" "$list_file"
        return 0
    fi
    return 1
}

# Function to send delayed uncommands
send_delayed_uncommands() {
    local target_player="$1" command_type="$2"
    (
        sleep 2; send_server_command_silent "/un${command_type} $target_player"
        sleep 2; send_server_command_silent "/un${command_type} $target_player"
        sleep 1; send_server_command_silent "/un${command_type} $target_player"
        remove_from_list_file "$target_player" "$command_type"
    ) &
}

# Function to send server command silently
send_server_command_silent() {
    screen -S "$SCREEN_SERVER" -p 0 -X stuff "$1$(printf \\r)" 2>/dev/null
}

# Function to send server command
send_server_command() {
    if screen -S "$SCREEN_SERVER" -p 0 -X stuff "$1$(printf \\r)" 2>/dev/null; then
        print_success "Sent message to server: $1"
        return 0
    else
        print_error "Could not send message to server"
        return 1
    fi
}

# Function to check if player is in list
is_player_in_list() {
    local player_name="$1" list_type="$2"
    local list_file="$LOG_DIR/${list_type}list.txt"
    [ -f "$list_file" ] && grep -v "^[[:space:]]*#" "$list_file" 2>/dev/null | grep -q -i "^$player_name$"
}

# Function to get player rank
get_player_rank() {
    local player_name="$1"
    if is_player_in_list "$player_name" "admin"; then
        echo "admin"
    elif is_player_in_list "$player_name" "mod"; then
        echo "mod"
    else
        echo "NONE"
    fi
}

# Function to get IP by name
get_ip_by_name() {
    local name="$1"
    if [ -z "$LOG_FILE" ] || [ ! -f "$LOG_FILE" ]; then
        echo "unknown"
        return 1
    fi
    awk -F'|' -v pname="$name" '
    /Player Connected/ {
        part=$1
        sub(/.*Player Connected[[:space:]]*/, "", part)
        gsub(/^[ \t]+|[ \t]+$/, "", part)
        ip=$2
        gsub(/^[ \t]+|[ \pt]+$/, "", ip)
        if (part == pname) { last_ip=ip }
    }
    END { if (last_ip) print last_ip; else print "unknown" }
    ' "$LOG_FILE"
}

# Function to check for username theft
check_username_theft() {
    local player_name="$1" player_ip="$2"
    
    # Skip if player name is invalid
    ! is_valid_player_name "$player_name" && return 0
    
    # Check if player exists in players.log
    if grep -q -i "^$player_name|" "$PLAYERS_LOG"; then
        # Player exists, check if IP matches
        local registered_ip=$(grep -i "^$player_name|" "$PLAYERS_LOG" | head -1 | cut -d'|' -f2 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        local registered_rank=$(grep -i "^$player_name|" "$PLAYERS_LOG" | head -1 | cut -d'|' -f3 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        
        if [ "$registered_ip" != "$player_ip" ]; then
            # IP doesn't match - possible username theft
            print_error "USERNAME THEFT DETECTED: $player_name from IP $player_ip (registered IP: $registered_ip)"
            
            # Immediately kick the player using the stolen name
            send_server_command "/kick $player_name"
            print_error "Kicked player $player_name for username theft"
            
            if [ "$registered_rank" != "NONE" ]; then
                # Player has rank - critical security issue
                print_error "CRITICAL: Player with rank ($registered_rank) username theft detected!"
                # Ban the IP but don't stop the server
                send_server_command "/ban $player_ip"
                print_error "IP $player_ip banned due to username theft of ranked player"
                return 1
            else
                # Regular player - just ban the IP
                send_server_command "/ban $player_ip"
                print_error "IP $player_ip banned for username theft"
                return 1
            fi
        fi
    else
        # New player - add to players.log
        local rank=$(get_player_rank "$player_name")
        echo "$player_name|$player_ip|$rank" >> "$PLAYERS_LOG"
        print_success "Added new player to registry: $player_name ($player_ip) with rank: $rank"
    fi
    
    return 0
}

# Function to detect spam and dangerous commands
check_dangerous_activity() {
    local player_name="$1" message="$2" current_time=$(date +%s)
    
    # Skip if player name is invalid or is server
    ! is_valid_player_name "$player_name" || [ "$player_name" = "SERVER" ] && return 0
    
    # Get player IP for banning
    local player_ip=$(get_ip_by_name "$player_name")
    
    # Check for spam (more than 2 messages in 1 second)
    if [ -n "${player_message_times[$player_name]}" ]; then
        local last_time=${player_message_times[$player_name]}
        local count=${player_message_counts[$player_name]}
        
        if [ $((current_time - last_time)) -le 1 ]; then
            count=$((count + 1))
            player_message_counts[$player_name]=$count
            
            if [ $count -gt 2 ]; then
                print_error "SPAM DETECTED: $player_name sent $count messages in 1 second"
                send_server_command "/ban $player_ip"
                send_server_command "WARNING: $player_name (IP: $player_ip) was banned for spamming"
                return 1
            fi
        else
            # Reset counter if more than 1 second has passed
            player_message_counts[$player_name]=1
            player_message_times[$player_name]=$current_time
        fi
    else
        # First message from this player
        player_message_times[$player_name]=$current_time
        player_message_counts[$player_name]=1
    fi
    
    # Check for dangerous commands from ranked players
    local rank=$(get_player_rank "$player_name")
    if [ "$rank" != "NONE" ]; then
        # List of dangerous commands
        local dangerous_commands="/stop /shutdown /restart /banall /kickall /op /deop /save-off"
        
        for cmd in $dangerous_commands; do
            if [[ "$message" == "$cmd"* ]]; then
                print_error "DANGEROUS COMMAND: $player_name ($rank) attempted to use: $message"
                record_admin_offense "$player_name"
                local offense_count=$?
                
                if [ $offense_count -ge 2 ]; then
                    send_server_command "/ban $player_ip"
                    send_server_command "WARNING: $player_name (IP: $player_ip) was banned for attempting dangerous commands"
                    return 1
                else
                    send_server_command "WARNING: $player_name, dangerous commands are restricted!"
                    return 0
                fi
            fi
        done
    fi
    
    return 0
}

# Function to handle unauthorized command
handle_unauthorized_command() {
    local player_name="$1" command="$2" target_player="$3"
    local player_ip=$(get_ip_by_name "$player_name")
    
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

# Function to filter server log
filter_server_log() {
    while read -r line; do
        [[ "$line" == *"Server closed"* || "$line" == *"Starting server"* || \
          ("$line" == *"SERVER: say"* && "$line" == *"Welcome"*) || \
          "$line" == *"adminlist.txt"* || "$line" == *"modlist.txt"* ]] && continue
        echo "$line"
    done
}

# Function to cleanup
cleanup() {
    print_status "Cleaning up anticheat..."
    kill $(jobs -p) 2>/dev/null
    rm -f "${ADMIN_OFFENSES_FILE}.lock" 2>/dev/null
    exit 0
}

# Function to monitor log
monitor_log() {
    local log_file="$1"
    LOG_FILE="$log_file"
    initialize_authorization_files
    initialize_admin_offenses
    
    # Start validation process in background
    (
        while true; do 
            sleep 30
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
    
    # Wait for log file to exist
    local wait_time=0
    while [ ! -f "$log_file" ] && [ $wait_time -lt 30 ]; do
        sleep 1
        ((wait_time++))
        [ $((wait_time % 5)) -eq 0 ] && print_status "Waiting for log file to be created..."
    done
    
    if [ ! -f "$log_file" ]; then
        print_error "Log file never appeared: $log_file"
        kill $validation_pid 2>/dev/null
        exit 1
    fi
    
    # Start monitoring the log
    tail -n 0 -F "$log_file" 2>/dev/null | filter_server_log | while read -r line; do
        if [[ "$line" =~ Player\ Connected\ (.+)\ \|\ ([0-9a-fA-F.:]+)\ \|\ ([0-9a-f]+) ]]; then
            local player_name="${BASH_REMATCH[1]}" player_ip="${BASH_REMATCH[2]}" player_hash="${BASH_REMATCH[3]}"
            player_name=$(echo "$player_name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            
            if [[ "$player_name" == *\\* || "$player_name" == */* || "$player_name" == *\$* || "$player_name" == *\(* || "$player_name" == *\)* || "$player_name" == *\;* || "$player_name" == *\`* ]]; then
                handle_invalid_player_name "$player_name" "$player_ip" "$player_hash"
                continue
            fi
            
            if ! is_valid_player_name "$player_name"; then
                handle_invalid_player_name "$player_name" "$player_ip" "$player_hash"
                continue
            fi
            
            # Check for username theft
            if ! check_username_theft "$player_name" "$player_ip"; then
                continue
            fi
            
            print_success "Player connected: $player_name (IP: $player_ip)"
        fi

        if [[ "$line" =~ ([^:]+):\ \/(admin|mod)\ ([^[:space:]]+) ]]; then
            local command_user="${BASH_REMATCH[1]}" command_type="${BASH_REMATCH[2]}" target_player="${BASH_REMATCH[3]}"
            command_user=$(echo "$command_user" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            target_player=$(echo "$target_player" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            
            if [[ "$command_user" == *\\* || "$command_user" == */* || "$command_user" == *\$* || "$command_user" == *\(* || "$command_user" == *\)* || "$command_user" == *\;* || "$command_user" == *\`* ]]; then
                local ipu=$(get_ip_by_name "$command_user")
                handle_invalid_player_name "$command_user" "$ipu" ""
                continue
            fi
            
            if [[ "$target_player" == *\\* || "$target_player" == */* || "$target_player" == *\$* || "$target_player" == *\(* || "$target_player" == *\)* || "$target_player" == *\;* || "$target_player" == *\`* ]]; then
                local ipt=$(get_ip_by_name "$target_player")
                handle_invalid_player_name "$target_player" "$ipt" ""
                continue
            fi
            
            if ! is_valid_player_name "$command_user"; then
                local ipu2=$(get_ip_by_name "$command_user")
                handle_invalid_player_name "$command_user" "$ipu2" ""
                continue
            fi
            
            if ! is_valid_player_name "$target_player"; then
                local ipt2=$(get_ip_by_name "$target_player")
                handle_invalid_player_name "$target_player" "$ipt2" ""
                continue
            fi
            
            [ "$command_user" != "SERVER" ] && handle_unauthorized_command "$command_user" "/$command_type" "$target_player"
        fi

        if [[ "$line" =~ Player\ Disconnected\ (.+) ]]; then
            local player_name="${BASH_REMATCH[1]}"
            player_name=$(echo "$player_name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            
            if [[ "$player_name" == *\\* || "$player_name" == */* || "$player_name" == *\$* || "$player_name" == *\(* || "$player_name" == *\)* || "$player_name" == *\;* || "$player_name" == *\`* ]]; then
                print_warning "Player with invalid name disconnected: $player_name"
                continue
            fi
            
            if is_valid_player_name "$player_name"; then
                print_warning "Player disconnected: $player_name"
            else
                print_warning "Player with invalid name disconnected: $player_name"
            fi
        fi

        # Check for chat messages and dangerous commands
        if [[ "$line" =~ ([a-zA-Z0-9_]+):\ (.+)$ ]]; then
            local player_name="${BASH_REMATCH[1]}" message="${BASH_REMATCH[2]}"
            player_name=$(echo "$player_name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            
            if ! is_valid_player_name "$player_name"; then
                continue
            fi
            
            # Check for dangerous activity
            check_dangerous_activity "$player_name" "$message"
        fi
    done
    
    kill $validation_pid 2>/dev/null
}

# Function to show usage
show_usage() {
    print_header "ANTICHEAT SECURITY SYSTEM - USAGE"
    print_status "Usage: $0 <server_log_file> [port]"
    print_status "Example: $0 /path/to/console.log 12153"
    echo ""
    print_warning "Note: This script should be run alongside the server"
}

# Main execution
if [ $# -lt 1 ]; then
    show_usage
    exit 1
fi

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
