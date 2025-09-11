#!/bin/bash

# =============================================================================
# THE BLOCKHEADS SERVER MANAGEMENT SYSTEM
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
PLAYERS_LOG="$LOG_DIR/players.log"
ECONOMY_FILE="$LOG_DIR/economy_data_$PORT.json"
SCREEN_SERVER="blockheads_server_$PORT"
IP_CHANGE_ATTEMPTS_FILE="$LOG_DIR/ip_change_attempts.json"
PASSWORD_CHANGE_ATTEMPTS_FILE="$LOG_DIR/password_change_attempts.json"

# Track player messages for spam detection
declare -A player_message_times
declare -A player_message_counts

# Track admin commands for spam detection
declare -A admin_last_command_time
declare -A admin_command_count

# Track IP change grace periods
declare -A ip_change_grace_periods
declare -A ip_change_pending_players

# Function to sync players.log with list files
sync_list_files() {
    local list_type="$1"
    local list_file="$LOG_DIR/${list_type}.txt"
    
    [ ! -f "$PLAYERS_LOG" ] && return
    
    # Clear the list file
    echo "# Usernames in this file are granted ${list_type} privileges" > "$list_file"
    echo "# This file is automatically synced from players.log" >> "$list_file"
    
    # Add players with the appropriate rank
    while IFS='|' read -r name ip rank password ban_status; do
        if [ "$list_type" = "blacklist" ] && [ "$ban_status" = "Blacklisted" ]; then
            echo "$name" >> "$list_file"
        elif [ "$rank" = "$list_type" ]; then
            echo "$name" >> "$list_file"
        fi
    done < "$PLAYERS_LOG"
}

# Function to sync all list files
sync_all_list_files() {
    sync_list_files "admin"
    sync_list_files "mod"
    sync_list_files "blacklist"
}

# Function to extract real player name from ID-prefixed format
extract_real_name() {
    local name="$1"
    # Remove any numeric prefix with bracket (e.g., "12345] ")
    if [[ "$name" =~ ^[0-9]+\]\ (.+)$ ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo "$name"
    fi
}

# Function to generate random alphanumeric password
generate_random_password() {
    local length=7
    tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$length"
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

# Function to record IP change attempt
record_ip_change_attempt() {
    local player_name="$1" current_time=$(date +%s)
    local attempts_data=$(read_json_file "$IP_CHANGE_ATTEMPTS_FILE" 2>/dev/null || echo '{}')
    local current_attempts=$(echo "$attempts_data" | jq -r --arg player "$player_name" '.[$player]?.attempts // 0')
    local last_attempt_time=$(echo "$attempts_data" | jq -r --arg player "$player_name" '.[$player]?.last_attempt // 0')
    
    # Reset counter if more than 1 hour has passed
    [ $((current_time - last_attempt_time)) -gt 3600 ] && current_attempts=0
    
    current_attempts=$((current_attempts + 1))
    attempts_data=$(echo "$attempts_data" | jq --arg player "$player_name" \
        --argjson attempts "$current_attempts" --argjson time "$current_time" \
        '.[$player] = {"attempts": $attempts, "last_attempt": $time}')
    
    write_json_file "$IP_CHANGE_ATTEMPTS_FILE" "$attempts_data"
    return $current_attempts
}

# Function to record password change attempt
record_password_change_attempt() {
    local player_name="$1" current_time=$(date +%s)
    local attempts_data=$(read_json_file "$PASSWORD_CHANGE_ATTEMPTS_FILE" 2>/dev/null || echo '{}')
    local current_attempts=$(echo "$attempts_data" | jq -r --arg player "$player_name" '.[$player]?.attempts // 0')
    local last_attempt_time=$(echo "$attempts_data" | jq -r --arg player "$player_name" '.[$player]?.last_attempt // 0')
    
    # Reset counter if more than 1 hour has passed
    [ $((current_time - last_attempt_time)) -gt 3600 ] && current_attempts=0
    
    current_attempts=$((current_attempts + 1))
    attempts_data=$(echo "$attempts_data" | jq --arg player "$player_name" \
        --argjson attempts "$current_attempts" --argjson time "$current_time" \
        '.[$player] = {"attempts": $attempts, "last_attempt": $time}')
    
    write_json_file "$PASSWORD_CHANGE_ATTEMPTS_FILE" "$attempts_data"
    return $current_attempts
}

# Function to check for illegal characters in player names
has_illegal_characters() {
    local name="$1"
    # Check for backslashes, symbols, spaces and other illegal characters
    if [[ "$name" =~ [\\/\$\(\)\;\\\`\*\"\'\<\>\&\|\s] ]]; then
        return 0  # Has illegal characters
    fi
    return 1  # No illegal characters
}

# Function to validate player names
is_valid_player_name() {
    local player_name="$1"
    player_name=$(echo "$player_name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [[ -z "$player_name" ]] && return 1
    
    # Check for illegal characters first
    if has_illegal_characters "$player_name"; then
        return 1
    fi
    
    # Then check if it matches the valid pattern
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
    
    # Special handling for names with backslashes
    local safe_name=$(echo "$player_name" | sed 's/\\/\\\\/g')
    
    if [ -n "$player_ip" ] && [ "$player_ip" != "unknown" ]; then
        send_server_command "/ban $player_ip"
        # Kick the player after banning
        send_server_command "/kick $safe_name"
        (
            sleep 5
            send_server_command "/unban $player_ip"
            print_success "Unbanned IP: $player_ip"
        ) &
    else
        # Fallback: ban by name if IP is not available
        send_server_command "/ban $safe_name"
        send_server_command "/kick $safe_name"
    fi
    return 0
}

# Function to initialize authorization files
initialize_authorization_files() {
    [ ! -f "$PLAYERS_LOG" ] && touch "$PLAYERS_LOG"
    [ ! -f "$IP_CHANGE_ATTEMPTS_FILE" ] && echo "{}" > "$IP_CHANGE_ATTEMPTS_FILE"
    [ ! -f "$PASSWORD_CHANGE_ATTEMPTS_FILE" ] && echo "{}" > "$PASSWORD_CHANGE_ATTEMPTS_FILE"
    
    # Sync list files with players.log
    sync_all_list_files
}

# Function to initialize economy
initialize_economy() {
    [ ! -f "$ECONOMY_FILE" ] && echo '{"players": {}, "transactions": []}' > "$ECONOMY_FILE"
}

# Function to add player to economy if new
add_player_if_new() {
    local player_name="$1"
    ! is_valid_player_name "$player_name" && return 1
    
    local current_data=$(read_json_file "$ECONOMY_FILE")
    local player_exists=$(echo "$current_data" | jq --arg player "$player_name" '.players | has($player)')
    
    [ "$player_exists" = "false" ] && {
        current_data=$(echo "$current_data" | jq --arg player "$player_name" \
            '.players[$player] = {"tickets": 0, "last_login": 0, "last_welcome_time": 0, "last_help_time": 0, "last_greeting_time": 0, "purchases": []}')
        write_json_file "$ECONOMY_FILE" "$current_data"
        give_first_time_bonus "$player_name"
        return 0
    }
    return 1
}

# Function to give first time bonus
give_first_time_bonus() {
    local player_name="$1" current_time=$(date +%s) time_str="$(date '+%Y-%m-%d %H:%M:%S')"
    local current_data=$(read_json_file "$ECONOMY_FILE")
    current_data=$(echo "$current_data" | jq --arg player "$player_name" '.players[$player].tickets = 1')
    current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson time "$current_time" '.players[$player].last_login = $time')
    current_data=$(echo "$current_data" | jq --arg player "$player_name" --arg time "$time_str" \
        '.transactions += [{"player": $player, "type": "welcome_bonus", "tickets": 1, "time": $time}]')
    write_json_file "$ECONOMY_FILE" "$current_data"
}

# Function to grant login ticket
grant_login_ticket() {
    local player_name="$1" current_time=$(date +%s) time_str="$(date '+%Y-%m-%d %H:%M:%S')"
    local current_data=$(read_json_file "$ECONOMY_FILE")
    local last_login=$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].last_login // 0')
    last_login=${last_login:-0}
    
    [ "$last_login" -eq 0 ] || [ $((current_time - last_login)) -ge 3600 ] && {
        local current_tickets=$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].tickets // 0')
        current_tickets=${current_tickets:-0}
        local new_tickets=$((current_tickets + 1))
        
        current_data=$(echo "$current_data" | jq --arg player "$player_name" \
            --argjson tickets "$new_tickets" --argjson time "$current_time" --arg time_str "$time_str" \
            '.players[$player].tickets = $tickets | 
             .players[$player].last_login = $time |
             .transactions += [{"player": $player, "type": "login_bonus", "tickets": 1, "time": $time_str}]')
        
        write_json_file "$ECONOMY_FILE" "$current_data"
        print_success "Granted 1 ticket to $player_name (Total: $new_tickets)"
    } || {
        local next_login=$((last_login + 3600))
        local time_left=$((next_login - current_time))
        print_warning "$player_name must wait $((time_left / 60)) minutes for next ticket"
    }
}

# Function to show welcome message
show_welcome_message() {
    local player_name="$1" is_new_player="$2" force_send="${3:-0}"
    ! is_valid_player_name "$player_name" && return
    
    local current_time=$(date +%s)
    local current_data=$(read_json_file "$ECONOMY_FILE")
    local last_welcome_time=$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].last_welcome_time // 0')
    last_welcome_time=${last_welcome_time:-0}
    
    # 30-second cooldown for welcome messages
    [ "$force_send" -eq 1 ] || [ "$last_welcome_time" -eq 0 ] || [ $((current_time - last_welcome_time)) -ge 30 ] && {
        [ "$is_new_player" = "true" ] && {
            send_server_command "Hello $player_name! Welcome to the server. Type !help to check available commands."
        } || {
            local last_greeting_time=$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].last_greeting_time // 0')
            [ $((current_time - last_greeting_time)) -ge 600 ] && {
                send_server_command "Welcome back $player_name! Type !help to see available commands."
                current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson time "$current_time" '.players[$player].last_greeting_time = $time')
                write_json_file "$ECONOMY_FILE" "$current_data"
            }
        }
        current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson time "$current_time" '.players[$player].last_welcome_time = $time')
        write_json_file "$ECONOMY_FILE" "$current_data"
    } || print_warning "Skipping welcome for $player_name due to cooldown"
}

# Function to validate authorization
validate_authorization() {
    # Sync list files with players.log to ensure consistency
    sync_all_list_files
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
    local list_file="$LOG_DIR/${list_type}.txt"
    [ ! -f "$list_file" ] && return 1
    if grep -v "^[[:space:]]*#" "$list_file" 2>/dev/null | grep -q -i "^$player_name$"; then
        sed -i "/^$player_name$/Id" "$list_file"
        return 0
    fi
    return 1
}

# Function to update player info in players.log
update_player_info() {
    local player_name="$1" player_ip="$2" player_rank="$3" player_password="$4" ban_status="${5:-NONE}"
    if [ -f "$PLAYERS_LOG" ]; then
        # Remove existing entry
        sed -i "/^$player_name|/Id" "$PLAYERS_LOG"
        # Add new entry
        echo "$player_name|$player_ip|$player_rank|$player_password|$ban_status" >> "$PLAYERS_LOG"
        
        # Sync list files after update
        sync_all_list_files
    fi
}

# Function to get player info from players.log
get_player_info() {
    local player_name="$1"
    if [ -f "$PLAYERS_LOG" ]; then
        while IFS='|' read -r name ip rank password ban_status; do
            if [ "$name" = "$player_name" ]; then
                echo "$ip|$rank|$password|$ban_status"
                return 0
            fi
        done < <(grep -i "^$player_name|" "$PLAYERS_LOG")
    fi
    echo ""
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
    local list_file="$LOG_DIR/${list_type}.txt"
    [ -f "$list_file" ] && grep -v "^[[:space:]]*#" "$list_file" 2>/dev/null | grep -q -i "^$player_name$"
}

# Function to get player rank
get_player_rank() {
    local player_name="$1"
    local player_info=$(get_player_info "$player_name")
    if [ -n "$player_info" ]; then
        local rank=$(echo "$player_info" | cut -d'|' -f2)
        echo "$rank"
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

# Function to start IP change grace period
start_ip_change_grace_period() {
    local player_name="$1" player_ip="$2"
    local grace_end=$(( $(date +%s) + 30 ))
    ip_change_grace_periods["$player_name"]=$grace_end
    ip_change_pending_players["$player_name"]="$player_ip"
    print_warning "Started IP change grace period for $player_name (30 seconds)"
    
    # Send warning message to player
    send_server_command "WARNING: $player_name, your IP has changed from the registered one!"
    send_server_command "You have 30 seconds to verify your identity with: !ip_change YOUR_CURRENT_PASSWORD"
    send_server_command "If you don't verify, you will be kicked from the server."
    
    # Start grace period countdown
    (
        sleep 30
        if [ -n "${ip_change_grace_periods[$player_name]}" ]; then
            print_warning "IP change grace period expired for $player_name - kicking player"
            send_server_command "/kick $player_name"
            unset ip_change_grace_periods["$player_name"]
            unset ip_change_pending_players["$player_name"]
        fi
    ) &
}

# Function to check if player is in IP change grace period
is_in_grace_period() {
    local player_name="$1"
    local current_time=$(date +%s)
    if [ -n "${ip_change_grace_periods[$player_name]}" ] && [ ${ip_change_grace_periods["$player_name"]} -gt $current_time ]; then
        return 0
    else
        # Clean up if grace period has expired
        unset ip_change_grace_periods["$player_name"]
        unset ip_change_pending_players["$player_name"]
        return 1
    fi
}

# Function to validate IP change
validate_ip_change() {
    local player_name="$1" password="$2" current_ip="$3"
    local player_info=$(get_player_info "$player_name")
    
    if [ -z "$player_info" ]; then
        print_error "Player $player_name not found in registry"
        return 1
    fi
    
    local registered_ip=$(echo "$player_info" | cut -d'|' -f1)
    local registered_rank=$(echo "$player_info" | cut -d'|' -f2)
    local registered_password=$(echo "$player_info" | cut -d'|' -f3)
    local ban_status=$(echo "$player_info" | cut -d'|' -f4)
    
    if [ "$registered_password" != "$password" ]; then
        print_error "Invalid password for IP change: $player_name"
        return 1
    fi
    
    # Update IP in players.log
    update_player_info "$player_name" "$current_ip" "$registered_rank" "$registered_password" "$ban_status"
    print_success "IP updated for $player_name: $current_ip"
    
    # End grace period
    unset ip_change_grace_periods["$player_name"]
    unset ip_change_pending_players["$player_name"]
    
    # Send success message
    send_server_command "SUCCESS: $player_name, your IP has been verified and updated!"
    
    # Clear chat after 5 seconds to hide password
    (
        sleep 5
        send_server_command_silent "/clear"
        print_success "Chat cleared after IP change verification"
    ) &
    
    return 0
}

# Function to handle password generation
handle_password_generation() {
    local player_name="$1" player_ip="$2"
    local player_info=$(get_player_info "$player_name")
    local player_rank=$(get_player_rank "$player_name")
    
    # Generate random password
    local new_password=$(generate_random_password)
    
    if [ -z "$player_info" ]; then
        # New player - add to players.log
        update_player_info "$player_name" "$player_ip" "$player_rank" "$new_password" "NONE"
    else
        # Existing player - update password
        local registered_ip=$(echo "$player_info" | cut -d'|' -f1)
        local registered_rank=$(echo "$player_info" | cut -d'|' -f2)
        local ban_status=$(echo "$player_info" | cut -d'|' -f4)
        update_player_info "$player_name" "$registered_ip" "$registered_rank" "$new_password" "$ban_status"
    fi
    
    # Send password to player
    send_server_command "$player_name, your new password is: $new_password"
    send_server_command "Please save this password securely. You will need it if your IP changes."
    send_server_command "The chat will be cleared in 25 seconds to protect your password."
    
    # Schedule chat clearance
    (
        sleep 25
        send_server_command_silent "/clear"
        print_success "Chat cleared for password protection"
    ) &
    
    return 0
}

# Function to handle password change
handle_password_change() {
    local player_name="$1" old_password="$2"
    local player_info=$(get_player_info "$player_name")
    
    if [ -z "$player_info" ]; then
        print_error "Player $player_name not found in registry"
        send_server_command "$player_name, you don't have a password set. Use !ip_psw to generate one."
        return 1
    fi
    
    local registered_ip=$(echo "$player_info" | cut -d'|' -f1)
    local registered_rank=$(echo "$player_info" | cut -d'|' -f2)
    local registered_password=$(echo "$player_info" | cut -d'|' -f3)
    local ban_status=$(echo "$player_info" | cut -d'|' -f4)
    
    if [ "$registered_password" != "$old_password" ]; then
        print_error "Invalid old password for $player_name"
        send_server_command "$player_name, the old password is incorrect."
        return 1
    fi
    
    # Check password change attempts
    record_password_change_attempt "$player_name"
    local attempt_count=$?
    
    if [ $attempt_count -gt 3 ]; then
        print_error "Password change limit exceeded for $player_name"
        send_server_command "$player_name, you've exceeded the password change limit (3 times per hour)."
        return 1
    fi
    
    # Generate new password
    local new_password=$(generate_random_password)
    update_player_info "$player_name" "$registered_ip" "$registered_rank" "$new_password" "$ban_status"
    
    # Send new password to player
    send_server_command "$player_name, your new password is: $new_password"
    send_server_command "Please save this password securely. You will need it if your IP changes."
    send_server_command "The chat will be cleared in 25 seconds to protect your password."
    
    # Schedule chat clearance
    (
        sleep 25
        send_server_command_silent "/clear"
        print_success "Chat cleared for password protection"
    ) &
    
    return 0
}

# Function to check for username theft with IP verification
check_username_theft() {
    local player_name="$1" player_ip="$2"
    
    # Skip if player name is invalid
    ! is_valid_player_name "$player_name" && return 0
    
    # Check if player exists in players.log
    local player_info=$(get_player_info "$player_name")
    
    if [ -n "$player_info" ]; then
        # Player exists, check if IP matches
        local registered_ip=$(echo "$player_info" | cut -d'|' -f1)
        local registered_rank=$(echo "$player_info" | cut -d'|' -f2)
        local registered_password=$(echo "$player_info" | cut -d'|' -f3)
        local ban_status=$(echo "$player_info" | cut -d'|' -f4)
        
        # Check if player is blacklisted
        if [ "$ban_status" = "Blacklisted" ]; then
            print_error "Blacklisted player $player_name tried to connect. Banning..."
            send_server_command "/ban $player_ip"
            send_server_command "/kick $player_name"
            return 1
        fi
        
        if [ "$registered_ip" != "$player_ip" ]; then
            # IP doesn't match - check if player has password
            if [ "$registered_password" = "NONE" ]; then
                # No password set - remind player to set one after 5 seconds
                print_warning "IP changed for $player_name but no password set (old IP: $registered_ip, new IP: $player_ip)"
                (
                    sleep 5
                    send_server_command "WARNING: $player_name, your IP has changed but you don't have a password set."
                    send_server_command "Use !ip_psw to generate a password, or you may lose access to your account."
                ) &
                # Update IP in registry
                update_player_info "$player_name" "$player_ip" "$registered_rank" "$registered_password" "$ban_status"
            else
                # Password set - start grace period
                print_warning "IP changed for $player_name (old IP: $registered_ip, new IP: $player_ip)"
                start_ip_change_grace_period "$player_name" "$player_ip"
            fi
        else
            # IP matches - update rank if needed
            local current_rank=$(get_player_rank "$player_name")
            if [ "$current_rank" != "$registered_rank" ]; then
                update_player_info "$player_name" "$player_ip" "$current_rank" "$registered_password" "$ban_status"
            fi
        fi
    else
        # New player - add to players.log with no password
        local rank=$(get_player_rank "$player_name")
        update_player_info "$player_name" "$player_ip" "$rank" "NONE" "NONE"
        print_success "Added new player to registry: $player_name ($player_ip) with rank: $rank"
        
        # Remind player to set password after 5 seconds
        (
            sleep 5
            send_server_command "WARNING: $player_name, you don't have a password set for IP verification."
            send_server_command "Use !ip_psw to generate a password, or you may lose access to your account if your IP changes."
        ) &
    fi
    
    return 0
}

# Function to detect spam and dangerous commands
check_dangerous_activity() {
    local player_name="$1" message="$2" current_time=$(date +%s)
    
    # Skip if player name is invalid or is server
    ! is_valid_player_name "$player_name" || [ "$player_name" = "SERVER" ] && return 0
    
    # Check if player is in grace period - restrict sensitive commands
    if is_in_grace_period "$player_name"; then
        # List of restricted commands during grace period
        local restricted_commands="!give_admin !give_mod !buy_admin !buy_mod /stop /admin /mod /clear /clear-blacklist /clear-adminlist /clear-modlist /clear-whitelist"
        
        for cmd in $restricted_commands; do
            if [[ "$message" == "$cmd"* ]]; then
                print_error "RESTRICTED COMMAND: $player_name attempted to use $cmd during IP change grace period"
                send_server_command "WARNING: $player_name, sensitive commands are restricted during IP verification."
                return 1
            fi
        done
    fi
    
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
    
    if [ "$(get_player_rank "$player_name")" = "admin" ]; then
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
            send_server_command "$player_name, this is your second warning! One more and you will be demoted to mod."
        elif [ "$offense_count" -ge 3 ]; then
            print_warning "THIRD OFFENSE: Admin $player_name is being demoted to mod for multiple unauthorized rank assignment attempts"
            # Remove from admin files
            remove_from_list_file "$player_name" "admin"
            send_server_command_silent "/unadmin $player_name"
            # Add to mod files
            local player_info=$(get_player_info "$player_name")
            local registered_ip=$(echo "$player_info" | cut -d'|' -f1)
            local registered_password=$(echo "$player_info" | cut -d'|' -f3)
            local ban_status=$(echo "$player_info" | cut -d'|' -f4)
            update_player_info "$player_name" "$registered_ip" "mod" "$registered_password" "$ban_status"
            send_server_command "$player_name has been demoted to MOD for multiple unauthorized rank assignment attempts."
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

# Function to check if player has purchased an item
has_purchased() {
    local player_name="$1" item="$2"
    local current_data=$(read_json_file "$ECONOMY_FILE")
    local has_item=$(echo "$current_data" | jq --arg player "$player_name" --arg item "$item" '.players[$player].purchases | index($item) != null')
    [ "$has_item" = "true" ]
}

# Function to add purchase
add_purchase() {
    local player_name="$1" item="$2"
    local current_data=$(read_json_file "$ECONOMY_FILE")
    current_data=$(echo "$current_data" | jq --arg player "$player_name" --arg item "$item" '.players[$player].purchases += [$item]')
    write_json_file "$ECONOMY_FILE" "$current_data"
}

# Function to process give rank command
process_give_rank() {
    local giver_name="$1" target_player="$2" rank_type="$3"
    local current_data=$(read_json_file "$ECONOMY_FILE")
    local giver_tickets=$(echo "$current_data" | jq -r --arg player "$giver_name" '.players[$player].tickets // 0')
    giver_tickets=${giver_tickets:-0}
    
    local cost=0
    [ "$rank_type" = "admin" ] && cost=140
    [ "$rank_type" = "mod" ] && cost=70
    
    [ "$giver_tickets" -lt "$cost" ] && {
        send_server_command "$giver_name, you need $cost tickets to give $rank_type rank, but you only have $giver_tickets."
        return 1
    }
    
    ! is_valid_player_name "$target_player" && {
        send_server_command "$giver_name, invalid player name: $target_player"
        return 1
    }
    
    local new_tickets=$((giver_tickets - cost))
    current_data=$(echo "$current_data" | jq --arg player "$giver_name" --argjson tickets "$new_tickets" '.players[$player].tickets = $tickets')
    
    local time_str="$(date '+%Y-%m-%d %H:%M:%S')"
    current_data=$(echo "$current_data" | jq --arg giver "$giver_name" --arg target "$target_player" \
        --arg rank "$rank_type" --argjson cost "$cost" --arg time "$time_str" \
        '.transactions += [{"giver": $giver, "recipient": $target, "type": "rank_gift", "rank": $rank, "tickets": -$cost, "time": $time}]')
    
    write_json_file "$ECONOMY_FILE" "$current_data"
    
    # Update players.log with the new rank
    local target_info=$(get_player_info "$target_player")
    if [ -n "$target_info" ]; then
        local target_ip=$(echo "$target_info" | cut -d'|' -f1)
        local target_password=$(echo "$target_info" | cut -d'|' -f3)
        local ban_status=$(echo "$target_info" | cut -d'|' -f4)
        update_player_info "$target_player" "$target_ip" "$rank_type" "$target_password" "$ban_status"
    else
        # If player doesn't exist in players.log, create entry
        local target_ip=$(get_ip_by_name "$target_player")
        update_player_info "$target_player" "$target_ip" "$rank_type" "NONE" "NONE"
    fi
    
    # Apply the rank in-game
    screen -S "$SCREEN_SERVER" -p 0 -X stuff "/$rank_type $target_player$(printf \\r)"
    
    send_server_command "Congratulations! $giver_name has gifted $rank_type rank to $target_player for $cost tickets."
    send_server_command "$giver_name, your new ticket balance: $new_tickets"
    return 0
}

# Function to process economy message
process_economy_message() {
    local player_name="$1" message="$2"
    ! is_valid_player_name "$player_name" && return
    
    local current_data=$(read_json_file "$ECONOMY_FILE")
    local player_tickets=$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].tickets // 0')
    player_tickets=${player_tickets:-0}
    
    case "$message" in
        "!tickets"|"ltickets")
            send_server_command "$player_name, you have $player_tickets tickets."
            ;;
        "!buy_mod")
            (has_purchased "$player_name" "mod" || [ "$(get_player_rank "$player_name")" = "mod" ]) && {
                send_server_command "$player_name, you already have MOD rank."
            } || [ "$player_tickets" -ge 50 ] && {
                local new_tickets=$((player_tickets - 50))
                current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson tickets "$new_tickets" '.players[$player].tickets = $tickets')
                add_purchase "$player_name" "mod"
                local time_str="$(date '+%Y-%m-%d %H:%M:%S')"
                current_data=$(echo "$current_data" | jq --arg player "$player_name" --arg time "$time_str" \
                    '.transactions += [{"player": $player, "type": "purchase", "item": "mod", "tickets": -50, "time": $time}]')
                write_json_file "$ECONOMY_FILE" "$current_data"
                
                # Update players.log with the new rank
                local player_info=$(get_player_info "$player_name")
                if [ -n "$player_info" ]; then
                    local player_ip=$(echo "$player_info" | cut -d'|' -f1)
                    local player_password=$(echo "$player_info" | cut -d'|' -f3)
                    local ban_status=$(echo "$player_info" | cut -d'|' -f4)
                    update_player_info "$player_name" "$player_ip" "mod" "$player_password" "$ban_status"
                else
                    # If player doesn't exist in players.log, create entry
                    local player_ip=$(get_ip_by_name "$player_name")
                    update_player_info "$player_name" "$player_ip" "mod" "NONE" "NONE"
                fi
                
                # Apply the rank in-game
                screen -S "$SCREEN_SERVER" -p 0 -X stuff "/mod $player_name$(printf \\r)"
                send_server_command "Congratulations $player_name! You have been promoted to MOD for 50 tickets. Remaining tickets: $new_tickets"
            } || send_server_command "$player_name, you need $((50 - player_tickets)) more tickets to buy MOD rank."
            ;;
        "!buy_admin")
            (has_purchased "$player_name" "admin" || [ "$(get_player_rank "$player_name")" = "admin" ]) && {
                send_server_command "$player_name, you already have ADMIN rank."
            } || [ "$player_tickets" -ge 100 ] && {
                local new_tickets=$((player_tickets - 100))
                current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson tickets "$new_tickets" '.players[$player].tickets = $tickets')
                add_purchase "$player_name" "admin"
                local time_str="$(date '+%Y-%m-%d %H:%M:%S')"
                current_data=$(echo "$current_data" | jq --arg player "$player_name" --arg time "$time_str" \
                    '.transactions += [{"player": $player, "type": "purchase", "item": "admin", "tickets": -100, "time": $time}]')
                write_json_file "$ECONOMY_FILE" "$current_data"
                
                # Update players.log with the new rank
                local player_info=$(get_player_info "$player_name")
                if [ -n "$player_info" ]; then
                    local player_ip=$(echo "$player_info" | cut -d'|' -f1)
                    local player_password=$(echo "$player_info" | cut -d'|' -f3)
                    local ban_status=$(echo "$player_info" | cut -d'|' -f4)
                    update_player_info "$player_name" "$player_ip" "admin" "$player_password" "$ban_status"
                else
                    # If player doesn't exist in players.log, create entry
                    local player_ip=$(get_ip_by_name "$player_name")
                    update_player_info "$player_name" "$player_ip" "admin" "NONE" "NONE"
                fi
                
                # Apply the rank in-game
                screen -S "$SCREEN_SERVER" -p 0 -X stuff "/admin $player_name$(printf \\r)"
                send_server_command "Congratulations $player_name! You have been promoted to ADMIN for 100 tickets. Remaining tickets: $new_tickets"
            } || send_server_command "$player_name, you need $((100 - player_tickets)) more tickets to buy ADMIN rank."
            ;;
        "!give_admin "*)
            [[ "$message" =~ !give_admin\ ([a-zA-Z0-9_]+) ]] && \
            process_give_rank "$player_name" "${BASH_REMATCH[1]}" "admin" || \
            send_server_command "Usage: !give_admin PLAYER_NAME"
            ;;
        "!give_mod "*)
            [[ "$message" =~ !give_mod\ ([a-zA-Z0-9_]+) ]] && \
            process_give_rank "$player_name" "${BASH_REMATCH[1]}" "mod" || \
            send_server_command "Usage: !give_mod PLAYER_NAME"
            ;;
        "!help")
            send_server_command "Available commands:"
            send_server_command "!tickets - Check your tickets"
            send_server_command "!buy_mod - Buy MOD rank for 50 tickets"
            send_server_command "!buy_admin - Buy ADMIN rank for 100 tickets"
            send_server_command "!give_mod PLAYER - Gift MOD rank (70 tickets)"
            send_server_command "!give_admin PLAYER - Gift ADMIN rank (140 tickets)"
            send_server_command "!ip_psw - Generate IP verification password"
            send_server_command "!ip_psw_change OLD_PASSWORD - Change IP verification password"
            send_server_command "!ip_change PASSWORD - Verify IP change with password"
            ;;
    esac
}

# Function to process admin command
process_admin_command() {
    local command="$1" current_data=$(read_json_file "$ECONOMY_FILE")
    
    if [[ "$command" =~ ^!send_ticket\ ([a-zA-Z0-9_]+)\ ([0-9]+)$ ]]; then
        local player_name="${BASH_REMATCH[1]}" tickets_to_add="${BASH_REMATCH[2]}"
        
        ! is_valid_player_name "$player_name" && {
            print_error "Invalid player name: $player_name"
            return 1
        }
        
        [[ ! "$tickets_to_add" =~ ^[0-9]+$ ]] || [ "$tickets_to_add" -le 0 ] && {
            print_error "Invalid ticket amount: $tickets_to_add"
            return 1
        }
        
        local player_exists=$(echo "$current_data" | jq --arg player "$player_name" '.players | has($player)')
        [ "$player_exists" = "false" ] && print_error "Player $player_name not found" && return 1
        
        local current_tickets=$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].tickets // 0')
        current_tickets=${current_tickets:-0}
        local new_tickets=$((current_tickets + tickets_to_add))
        
        current_data=$(echo "$current_data" | jq --arg player "$player_name" \
            --argjson tickets "$new_tickets" --arg time_str "$(date '+%Y-%m-%d %H:%M:%S')" \
            --argjson amount "$tickets_to_add" \
            '.players[$player].tickets = $tickets |
             .transactions += [{"player": $player, "type": "admin_gift", "tickets": $amount, "time": $time_str}]')
        
        write_json_file "$ECONOMY_FILE" "$current_data"
        print_success "Added $tickets_to_add tickets to $player_name (Total: $new_tickets)"
        send_server_command "$player_name received $tickets_to_add tickets from admin! Total: $new_tickets"
    elif [[ "$command" =~ ^!set_mod\ ([a-zA-Z0-9_]+)$ ]]; then
        local player_name="${BASH_REMATCH[1]}"
        ! is_valid_player_name "$player_name" && print_error "Invalid player name: $player_name" && return 1
        
        print_success "Setting $player_name as MOD"
        
        # Update players.log with the new rank
        local player_info=$(get_player_info "$player_name")
        if [ -n "$player_info" ]; then
            local player_ip=$(echo "$player_info" | cut -d'|' -f1)
            local player_password=$(echo "$player_info" | cut -d'|' -f3)
            local ban_status=$(echo "$player_info" | cut -d'|' -f4)
            update_player_info "$player_name" "$player_ip" "mod" "$player_password" "$ban_status"
        else
            # If player doesn't exist in players.log, create entry
            local player_ip=$(get_ip_by_name "$player_name")
            update_player_info "$player_name" "$player_ip" "mod" "NONE" "NONE"
        fi
        
        # Apply the rank in-game
        screen -S "$SCREEN_SERVER" -p 0 -X stuff "/mod $player_name$(printf \\r)"
        send_server_command "$player_name has been set as MOD by server console!"
    elif [[ "$command" =~ ^!set_admin\ ([a-zA-Z0-9_]+)$ ]]; then
        local player_name="${BASH_REMATCH[1]}"
        ! is_valid_player_name "$player_name" && print_error "Invalid player name: $player_name" && return 1
        
        print_success "Setting $player_name as ADMIN"
        
        # Update players.log with the new rank
        local player_info=$(get_player_info "$player_name")
        if [ -n "$player_info" ]; then
            local player_ip=$(echo "$player_info" | cut -d'|' -f1)
            local player_password=$(echo "$player_info" | cut -d'|' -f3)
            local ban_status=$(echo "$player_info" | cut -d'|' -f4)
            update_player_info "$player_name" "$player_ip" "admin" "$player_password" "$ban_status"
        else
            # If player doesn't exist in players.log, create entry
            local player_ip=$(get_ip_by_name "$player_name")
            update_player_info "$player_name" "$player_ip" "admin" "NONE" "NONE"
        fi
        
        # Apply the rank in-game
        screen -S "$SCREEN_SERVER" -p 0 -X stuff "/admin $player_name$(printf \\r)"
        send_server_command "$player_name has been set as ADMIN by server console!"
    else
        print_error "Unknown admin command: $command"
    fi
}

# Function to check if server sent welcome recently
server_sent_welcome_recently() {
    local player_name="$1"
    [ -z "$LOG_FILE" ] || [ ! -f "$LOG_FILE" ] && return 1
    local player_lc=$(echo "$player_name" | tr '[:upper:]' '[:lower:]')
    
    tail -n 100 "$LOG_FILE" 2>/dev/null | grep -i "server:.*welcome.*$player_lc" | head -1 | grep -q . && return 0
    
    local current_time=$(date +%s)
    local current_data=$(read_json_file "$ECONOMY_FILE")
    local last_welcome_time=$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].last_welcome_time // 0')
    
    [ "$last_welcome_time" -gt 0 ] && [ $((current_time - last_welcome_time)) -le 30 ] && return 0
    
    return 1
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
    print_status "Cleaning up..."
    kill $(jobs -p) 2>/dev/null
    rm -f "${ADMIN_OFFENSES_FILE}.lock" 2>/dev/null
    rm -f "${IP_CHANGE_ATTEMPTS_FILE}.lock" 2>/dev/null
    rm -f "${PASSWORD_CHANGE_ATTEMPTS_FILE}.lock" 2>/dev/null
    rm -f "${ECONOMY_FILE}.lock" 2>/dev/null
    exit 0
}

# Function to monitor log
monitor_log() {
    local log_file="$1"
    LOG_FILE="$log_file"
    initialize_authorization_files
    initialize_admin_offenses
    initialize_economy
    
    # Start validation process in background
    (
        while true; do 
            sleep 30
            validate_authorization
        done
    ) &
    local validation_pid=$!
    
    trap cleanup EXIT INT TERM
    
    print_header "STARTING BLOCKHEADS SERVER MANAGEMENT SYSTEM"
    print_status "Monitoring: $log_file"
    print_status "Port: $PORT"
    print_status "Log directory: $LOG_DIR"
    print_header "SECURITY AND ECONOMY SYSTEMS ACTIVE"
    
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
            player_name=$(extract_real_name "$player_name")
            player_name=$(echo "$player_name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            
            # Check for illegal characters first
            if has_illegal_characters "$player_name"; then
                handle_invalid_player_name "$player_name" "$player_ip" "$player_hash"
                continue
            fi
            
            if ! is_valid_player_name "$player_name"; then
                handle_invalid_player_name "$player_name" "$player_ip" "$player_hash"
                continue
            fi
            
            # Check for username theft with IP verification
            if ! check_username_theft "$player_name" "$player_ip"; then
                continue
            fi
            
            print_success "Player connected: $player_name (IP: $player_ip)"

            local is_new_player="false"
            add_player_if_new "$player_name" && is_new_player="true"

            sleep 3

            ! server_sent_welcome_recently "$player_name" && \
            show_welcome_message "$player_name" "$is_new_player" 1 || \
            print_warning "Server already welcomed $player_name"

            [ "$is_new_player" = "false" ] && grant_login_ticket "$player_name"
        fi

        if [[ "$line" =~ ([^:]+):\ \/(admin|mod)\ ([^[:space:]]+) ]]; then
            local command_user="${BASH_REMATCH[1]}" command_type="${BASH_REMATCH[2]}" target_player="${BASH_REMATCH[3]}"
            command_user=$(extract_real_name "$command_user")
            command_user=$(echo "$command_user" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            target_player=$(extract_real_name "$target_player")
            target_player=$(echo "$target_player" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            
            # Check for illegal characters in command user
            if has_illegal_characters "$command_user"; then
                local ipu=$(get_ip_by_name "$command_user")
                handle_invalid_player_name "$command_user" "$ipu" ""
                continue
            fi
            
            # Check for illegal characters in target player
            if has_illegal_characters "$target_player"; then
                print_error "Admin $command_user attempted to assign rank to invalid player: $target_player"
                handle_unauthorized_command "$command_user" "/$command_type" "$target_player"
                continue
            fi
            
            if ! is_valid_player_name "$command_user"; then
                local ipu2=$(get_ip_by_name "$command_user")
                handle_invalid_player_name "$command_user" "$ipu2" ""
                continue
            fi
            
            if ! is_valid_player_name "$target_player"; then
                print_error "Admin $command_user attempted to assign rank to invalid player: $target_player"
                handle_unauthorized_command "$command_user" "/$command_type" "$target_player"
                continue
            fi
            
            [ "$command_user" != "SERVER" ] && handle_unauthorized_command "$command_user" "/$command_type" "$target_player"
        fi

        if [[ "$line" =~ Player\ Disconnected\ (.+) ]]; then
            local player_name="${BASH_REMATCH[1]}"
            player_name=$(extract_real_name "$player_name")
            player_name=$(echo "$player_name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            
            # Check for illegal characters
            if has_illegal_characters "$player_name"; then
                print_warning "Player with invalid name disconnected: $player_name"
                continue
            fi
            
            if is_valid_player_name "$player_name"; then
                print_warning "Player disconnected: $player_name"
            else
                print_warning "Player with invalid name disconnected: $player_name"
            fi
            
            # Clean up grace period if player disconnects
            unset ip_change_grace_periods["$player_name"]
            unset ip_change_pending_players["$player_name"]
        fi

        # Check for chat messages and dangerous commands
        if [[ "$line" =~ ([a-zA-Z0-9_]+):\ (.+)$ ]]; then
            local player_name="${BASH_REMATCH[1]}" message="${BASH_REMATCH[2]}"
            player_name=$(extract_real_name "$player_name")
            player_name=$(echo "$player_name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            
            # Check for illegal characters
            if has_illegal_characters "$player_name"; then
                continue
            fi
            
            if ! is_valid_player_name "$player_name"; then
                continue
            fi
            
            # Handle IP change and password commands
            case "$message" in
                "!ip_psw")
                    handle_password_generation "$player_name" "$player_ip"
                    ;;
                "!ip_psw_change "*)
                    if [[ "$message" =~ !ip_psw_change\ (.+)$ ]]; then
                        local old_password="${BASH_REMATCH[1]}"
                        handle_password_change "$player_name" "$old_password"
                    else
                        send_server_command "Usage: !ip_psw_change OLD_PASSWORD"
                    fi
                    ;;
                "!ip_change "*)
                    if is_in_grace_period "$player_name"; then
                        if [[ "$message" =~ !ip_change\ (.+)$ ]]; then
                            local password="${BASH_REMATCH[1]}"
                            local current_ip="${ip_change_pending_players[$player_name]}"
                            validate_ip_change "$player_name" "$password" "$current_ip"
                        else
                            send_server_command "Usage: !ip_change YOUR_CURRENT_PASSWORD"
                        fi
                    else
                        send_server_command "$player_name, you don't have a pending IP change verification."
                    fi
                    ;;
                *)
                    # Check for dangerous activity
                    check_dangerous_activity "$player_name" "$message"
                    
                    # Process economy commands
                    process_economy_message "$player_name" "$message"
                    ;;
            esac
        fi
        
        # Process admin commands from console
        if [[ "$line" =~ SERVER:\ (.+)$ ]]; then
            local admin_command="${BASH_REMATCH[1]}"
            [[ "$admin_command" == "!send_ticket "* || "$admin_command" == "!set_mod "* || "$admin_command" == "!set_admin "* ]] && \
            process_admin_command "$admin_command"
        fi
    done
    
    kill $validation_pid 2>/dev/null
}

# Function to show usage
show_usage() {
    print_header "BLOCKHEADS SERVER MANAGEMENT SYSTEM - USAGE"
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
