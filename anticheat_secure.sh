#!/bin/bash

# =============================================================================
# THE BLOCKHEADS ANTICHEAT & SERVER BOT - SISTEMA COMPLETO
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
SCREEN_SERVER="blockheads_server_$PORT"

# Server list files
ADMIN_LIST="$LOG_DIR/adminlist.txt"
MOD_LIST="$LOG_DIR/modlist.txt"
BLACK_LIST="$LOG_DIR/blacklist.txt"

# Track player messages for spam detection
declare -A player_message_times
declare -A player_message_counts

# Track admin commands for spam detection
declare -A admin_last_command_time
declare -A admin_command_count

# Track IP change grace periods
declare -A ip_change_grace_periods
declare -A ip_change_pending_players

# Track banned players for periodic kicking
declare -A banned_players

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

# Function to initialize players.log with proper format
initialize_players_log() {
    [ ! -f "$PLAYERS_LOG" ] && touch "$PLAYERS_LOG"
    # Ensure the file has the proper header/format
    if [ ! -s "$PLAYERS_LOG" ] || ! head -n 1 "$PLAYERS_LOG" | grep -q "^#"; then
        echo "# Format: NAME|IP|RANK|PASSWORD|BAN_STATUS|TICKETS|PASSWORD_CHANGE_ATTEMPTS|IP_CHANGE_ATTEMPTS" > "$PLAYERS_LOG"
    fi
}

# Function to update player info in players.log
update_player_info() {
    local player_name="$1" player_ip="$2" player_rank="$3" player_password="$4" \
          ban_status="$5" tickets="$6" pwd_attempts="$7" ip_attempts="$8"
    
    # Set default values if not provided
    player_rank="${player_rank:-NONE}"
    player_password="${player_password:-NONE}"
    ban_status="${ban_status:-NONE}"
    tickets="${tickets:-0}"
    pwd_attempts="${pwd_attempts:-0}"
    ip_attempts="${ip_attempts:-0}"
    
    # Remove existing entry
    sed -i "/^$player_name|/d" "$PLAYERS_LOG"
    
    # Add new entry
    echo "$player_name|$player_ip|$player_rank|$player_password|$ban_status|$tickets|$pwd_attempts|$ip_attempts" >> "$PLAYERS_LOG"
    
    print_success "Updated player info: $player_name (IP: $player_ip, Rank: $player_rank, Ban: $ban_status, Tickets: $tickets)"
    
    # Sync with server lists
    sync_player_lists "$player_name" "$player_rank" "$ban_status"
}

# Function to get player info from players.log
get_player_info() {
    local player_name="$1"
    if [ -f "$PLAYERS_LOG" ]; then
        while IFS='|' read -r name ip rank password ban_status tickets pwd_attempts ip_attempts; do
            # Skip comment lines
            [[ "$name" =~ ^# ]] && continue
            
            if [ "$name" = "$player_name" ]; then
                echo "$ip|$rank|$password|$ban_status|$tickets|$pwd_attempts|$ip_attempts"
                return 0
            fi
        done < <(grep -i "^$player_name|" "$PLAYERS_LOG")
    fi
    echo ""
}

# Function to sync player lists with server
sync_player_lists() {
    local player_name="$1" player_rank="$2" ban_status="$3"
    
    # Update admin list
    if [ "$player_rank" = "admin" ]; then
        if ! grep -q "^$player_name$" "$ADMIN_LIST" 2>/dev/null; then
            echo "$player_name" >> "$ADMIN_LIST"
            send_server_command_silent "/admin $player_name"
            print_success "Added $player_name to admin list"
        fi
    else
        if grep -q "^$player_name$" "$ADMIN_LIST" 2>/dev/null; then
            sed -i "/^$player_name$/d" "$ADMIN_LIST"
            send_server_command_silent "/unadmin $player_name"
            print_success "Removed $player_name from admin list"
        fi
    fi
    
    # Update mod list
    if [ "$player_rank" = "mod" ]; then
        if ! grep -q "^$player_name$" "$MOD_LIST" 2>/dev/null; then
            echo "$player_name" >> "$MOD_LIST"
            send_server_command_silent "/mod $player_name"
            print_success "Added $player_name to mod list"
        fi
    else
        if grep -q "^$player_name$" "$MOD_LIST" 2>/dev/null; then
            sed -i "/^$player_name$/d" "$MOD_LIST"
            send_server_command_silent "/unmod $player_name"
            print_success "Removed $player_name from mod list"
        fi
    fi
    
    # Update blacklist
    if [ "$ban_status" = "BAN" ]; then
        if ! grep -q "^$player_name$" "$BLACK_LIST" 2>/dev/null; then
            echo "$player_name" >> "$BLACK_LIST"
            # Get player IP for banning
            local player_info=$(get_player_info "$player_name")
            local player_ip=$(echo "$player_info" | cut -d'|' -f1)
            if [ -n "$player_ip" ] && [ "$player_ip" != "unknown" ]; then
                send_server_command_silent "/ban $player_ip"
                banned_players["$player_name"]=1
                print_success "Added $player_name to blacklist and banned IP"
            fi
        fi
    else
        if grep -q "^$player_name$" "$BLACK_LIST" 2>/dev/null; then
            sed -i "/^$player_name$/d" "$BLACK_LIST"
            # Get player IP for unbanning
            local player_info=$(get_player_info "$player_name")
            local player_ip=$(echo "$player_info" | cut -d'|' -f1)
            if [ -n "$player_ip" ] && [ "$player_ip" != "unknown" ]; then
                send_server_command_silent "/unban $player_ip"
                unset banned_players["$player_name"]
                print_success "Removed $player_name from blacklist and unbanned IP"
            fi
        fi
    fi
}

# Function to periodically kick banned players
kick_banned_players() {
    while true; do
        sleep 3
        for player in "${!banned_players[@]}"; do
            if [ -n "${banned_players[$player]}" ]; then
                send_server_command_silent "/kick $player"
            fi
        done
    done
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

# Function to send delayed uncommands
send_delayed_uncommands() {
    local target_player="$1" command_type="$2"
    (
        sleep 2; send_server_command_silent "/un${command_type} $target_player"
        sleep 2; send_server_command_silent "/un${command_type} $target_player"
        sleep 1; send_server_command_silent "/un${command_type} $target_player"
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

# Function to get player rank from players.log
get_player_rank() {
    local player_name="$1"
    local player_info=$(get_player_info "$player_name")
    if [ -n "$player_info" ]; then
        echo "$player_info" | cut -d'|' -f2
    else
        echo "NONE"
    fi
}

# Function to get player tickets from players.log
get_player_tickets() {
    local player_name="$1"
    local player_info=$(get_player_info "$player_name")
    if [ -n "$player_info" ]; then
        echo "$player_info" | cut -d'|' -f5
    else
        echo "0"
    fi
}

# Function to get IP by name from server log
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
    local tickets=$(echo "$player_info" | cut -d'|' -f5)
    local pwd_attempts=$(echo "$player_info" | cut -d'|' -f6)
    local ip_attempts=$(echo "$player_info" | cut -d'|' -f7)
    
    if [ "$registered_password" != "$password" ]; then
        print_error "Invalid password for IP change: $player_name"
        # Update IP change attempts
        ip_attempts=$((ip_attempts + 1))
        update_player_info "$player_name" "$registered_ip" "$registered_rank" "$registered_password" "$ban_status" "$tickets" "$pwd_attempts" "$ip_attempts"
        return 1
    fi
    
    # Update IP in players.log and reset attempts
    update_player_info "$player_name" "$current_ip" "$registered_rank" "$registered_password" "$ban_status" "$tickets" "$pwd_attempts" "0"
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
    local ban_status="NONE"
    local tickets="0"
    local pwd_attempts="0"
    local ip_attempts="0"
    
    if [ -n "$player_info" ]; then
        ban_status=$(echo "$player_info" | cut -d'|' -f4)
        tickets=$(echo "$player_info" | cut -d'|' -f5)
        pwd_attempts=$(echo "$player_info" | cut -d'|' -f6)
        ip_attempts=$(echo "$player_info" | cut -d'|' -f7)
    fi
    
    # Generate random password
    local new_password=$(generate_random_password)
    
    # Update player info
    update_player_info "$player_name" "$player_ip" "$player_rank" "$new_password" "$ban_status" "$tickets" "$pwd_attempts" "$ip_attempts"
    
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
    local tickets=$(echo "$player_info" | cut -d'|' -f5)
    local pwd_attempts=$(echo "$player_info" | cut -d'|' -f6)
    local ip_attempts=$(echo "$player_info" | cut -d'|' -f7)
    
    if [ "$registered_password" != "$old_password" ]; then
        print_error "Invalid old password for $player_name"
        # Update password change attempts
        pwd_attempts=$((pwd_attempts + 1))
        update_player_info "$player_name" "$registered_ip" "$registered_rank" "$registered_password" "$ban_status" "$tickets" "$pwd_attempts" "$ip_attempts"
        send_server_command "$player_name, the old password is incorrect."
        return 1
    fi
    
    # Check password change attempts (max 3 per hour)
    if [ "$pwd_attempts" -ge 3 ]; then
        print_error "Password change limit exceeded for $player_name"
        send_server_command "$player_name, you've exceeded the password change limit (3 times per hour)."
        return 1
    fi
    
    # Generate new password
    local new_password=$(generate_random_password)
    
    # Update player info with new password and reset attempts
    update_player_info "$player_name" "$registered_ip" "$registered_rank" "$new_password" "$ban_status" "$tickets" "0" "$ip_attempts"
    
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

# Function to handle rank purchase
handle_rank_purchase() {
    local player_name="$1" rank_type="$2" cost="$3"
    local player_info=$(get_player_info "$player_name")
    
    if [ -z "$player_info" ]; then
        print_error "Player $player_name not found in registry"
        send_server_command "$player_name, you need to register first with !ip_psw"
        return 1
    fi
    
    local registered_ip=$(echo "$player_info" | cut -d'|' -f1)
    local registered_rank=$(echo "$player_info" | cut -d'|' -f2)
    local registered_password=$(echo "$player_info" | cut -d'|' -f3)
    local ban_status=$(echo "$player_info" | cut -d'|' -f4)
    local tickets=$(echo "$player_info" | cut -d'|' -f5)
    local pwd_attempts=$(echo "$player_info" | cut -d'|' -f6)
    local ip_attempts=$(echo "$player_info" | cut -d'|' -f7)
    
    # Check if player already has this rank
    if [ "$registered_rank" = "$rank_type" ]; then
        send_server_command "$player_name, you already have $rank_type rank."
        return 1
    fi
    
    # Check if player has enough tickets
    if [ "$tickets" -lt "$cost" ]; then
        send_server_command "$player_name, you need $cost tickets to buy $rank_type rank, but you only have $tickets."
        return 1
    fi
    
    # Deduct tickets and update rank
    local new_tickets=$((tickets - cost))
    update_player_info "$player_name" "$registered_ip" "$rank_type" "$registered_password" "$ban_status" "$new_tickets" "$pwd_attempts" "$ip_attempts"
    
    # Send success message
    send_server_command "Congratulations $player_name! You have been promoted to $rank_type for $cost tickets. Remaining tickets: $new_tickets"
    
    return 0
}

# Function to grant login ticket
grant_login_ticket() {
    local player_name="$1" current_time=$(date +%s)
    local player_info=$(get_player_info "$player_name")
    
    if [ -z "$player_info" ]; then
        print_error "Player $player_name not found in registry"
        return 1
    fi
    
    local registered_ip=$(echo "$player_info" | cut -d'|' -f1)
    local registered_rank=$(echo "$player_info" | cut -d'|' -f2)
    local registered_password=$(echo "$player_info" | cut -d'|' -f3)
    local ban_status=$(echo "$player_info" | cut -d'|' -f4)
    local tickets=$(echo "$player_info" | cut -d'|' -f5)
    local pwd_attempts=$(echo "$player_info" | cut -d'|' -f6)
    local ip_attempts=$(echo "$player_info" | cut -d'|' -f7)
    local last_login=$(echo "$player_info" | cut -d'|' -f8)
    
    # Grant ticket if it's been more than 1 hour since last login
    if [ -z "$last_login" ] || [ $((current_time - last_login)) -ge 3600 ]; then
        local new_tickets=$((tickets + 1))
        update_player_info "$player_name" "$registered_ip" "$registered_rank" "$registered_password" "$ban_status" "$new_tickets" "$pwd_attempts" "$ip_attempts" "$current_time"
        send_server_command "$player_name, you received 1 login ticket! Total tickets: $new_tickets"
    else
        local next_login=$((last_login + 3600))
        local time_left=$((next_login - current_time))
        send_server_command "$player_name, you must wait $((time_left / 60)) minutes for your next ticket."
    fi
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
        local tickets=$(echo "$player_info" | cut -d'|' -f5)
        local pwd_attempts=$(echo "$player_info" | cut -d'|' -f6)
        local ip_attempts=$(echo "$player_info" | cut -d'|' -f7)
        
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
                update_player_info "$player_name" "$player_ip" "$registered_rank" "$registered_password" "$ban_status" "$tickets" "$pwd_attempts" "$ip_attempts"
            else
                # Password set - start grace period
                print_warning "IP changed for $player_name (old IP: $registered_ip, new IP: $player_ip)"
                start_ip_change_grace_period "$player_name" "$player_ip"
            fi
        else
            # IP matches - update rank if needed
            local current_rank=$(get_player_rank "$player_name")
            if [ "$current_rank" != "$registered_rank" ]; then
                update_player_info "$player_name" "$player_ip" "$current_rank" "$registered_password" "$ban_status" "$tickets" "$pwd_attempts" "$ip_attempts"
            fi
            
            # Grant login ticket
            grant_login_ticket "$player_name"
        fi
    else
        # New player - add to players.log with no password
        local rank=$(get_player_rank "$player_name")
        update_player_info "$player_name" "$player_ip" "$rank" "NONE" "NONE" "0" "0" "0"
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
                # Ban player and update players.log
                local player_info=$(get_player_info "$player_name")
                local registered_ip=$(echo "$player_info" | cut -d'|' -f1)
                local registered_rank=$(echo "$player_info" | cut -d'|' -f2)
                local registered_password=$(echo "$player_info" | cut -d'|' -f3)
                local tickets=$(echo "$player_info" | cut -d'|' -f5)
                local pwd_attempts=$(echo "$player_info" | cut -d'|' -f6)
                local ip_attempts=$(echo "$player_info" | cut -d'|' -f7)
                
                update_player_info "$player_name" "$registered_ip" "$registered_rank" "$registered_password" "BAN" "$tickets" "$pwd_attempts" "$ip_attempts"
                
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
                    # Ban player and update players.log
                    local player_info=$(get_player_info "$player_name")
                    local registered_ip=$(echo "$player_info" | cut -d'|' -f1)
                    local registered_rank=$(echo "$player_info" | cut -d'|' -f2)
                    local registered_password=$(echo "$player_info" | cut -d'|' -f3)
                    local tickets=$(echo "$player_info" | cut -d'|' -f5)
                    local pwd_attempts=$(echo "$player_info" | cut -d'|' -f6)
                    local ip_attempts=$(echo "$player_info" | cut -d'|' -f7)
                    
                    update_player_info "$player_name" "$registered_ip" "$registered_rank" "$registered_password" "BAN" "$tickets" "$pwd_attempts" "$ip_attempts"
                    
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
    
    local player_rank=$(get_player_rank "$player_name")
    if [ "$player_rank" = "admin" ]; then
        print_error "UNAUTHORIZED COMMAND: Admin $player_name attempted to use $command on $target_player"
        send_server_command "WARNING: Admin $player_name attempted unauthorized rank assignment!"
        local command_type=""
        [ "$command" = "/admin" ] && command_type="admin"
        [ "$command" = "/mod" ] && command_type="mod"
        if [ -n "$command_type" ]; then
            send_server_command_silent "/un${command_type} $target_player"
            send_delayed_uncommands "$target_player" "$command_type"
        fi
        record_admin_offense "$player_name"
        local offense_count=$?
        if [ "$offense_count" -eq 1 ]; then
            send_server_command "$player_name, this is your first warning! Only the server console can assign ranks."
        elif [ "$offense_count" -eq 2 ]; then
            send_server_command "$player_name, this is your second warning! One more and you will be demoted to mod."
        elif [ "$offense_count" -ge 3 ]; then
            print_warning "THIRD OFFENSE: Admin $player_name is being demoted to mod"
            # Update player rank to mod
            local player_info=$(get_player_info "$player_name")
            local registered_ip=$(echo "$player_info" | cut -d'|' -f1)
            local registered_password=$(echo "$player_info" | cut -d'|' -f3)
            local ban_status=$(echo "$player_info" | cut -d'|' -f4)
            local tickets=$(echo "$player_info" | cut -d'|' -f5)
            local pwd_attempts=$(echo "$player_info" | cut -d'|' -f6)
            local ip_attempts=$(echo "$player_info" | cut -d'|' -f7)
            
            update_player_info "$player_name" "$registered_ip" "mod" "$registered_password" "$ban_status" "$tickets" "$pwd_attempts" "$ip_attempts"
            clear_admin_offenses "$player_name"
        fi
    else
        print_warning "Non-admin player $player_name attempted to use $command on $target_player"
        send_server_command "$player_name, you don't have permission to assign ranks."
        if [ "$command" = "/admin" ]; then
            send_server_command_silent "/unadmin $target_player"
            send_delayed_uncommands "$target_player" "admin"
        elif [ "$command" = "/mod" ]; then
            send_server_command_silent "/unmod $target_player"
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

# Function to monitor players.log for changes and sync with server lists
monitor_players_log() {
    local last_modified=$(stat -c %Y "$PLAYERS_LOG" 2>/dev/null || stat -f %m "$PLAYERS_LOG")
    while true; do
        sleep 1
        local current_modified=$(stat -c %Y "$PLAYERS_LOG" 2>/dev/null || stat -f %m "$PLAYERS_LOG")
        if [ "$current_modified" -ne "$last_modified" ]; then
            print_status "players.log modified - syncing with server lists"
            last_modified=$current_modified
            
            # Read players.log and sync all players
            while IFS='|' read -r name ip rank password ban_status tickets pwd_attempts ip_attempts; do
                # Skip comment lines
                [[ "$name" =~ ^# ]] && continue
                [[ -z "$name" ]] && continue
                
                sync_player_lists "$name" "$rank" "$ban_status"
            done < "$PLAYERS_LOG"
        fi
    done
}

# Function to monitor log
monitor_log() {
    local log_file="$1"
    LOG_FILE="$log_file"
    initialize_players_log
    initialize_admin_offenses
    
    # Start players.log monitoring in background
    monitor_players_log &
    local monitor_pid=$!
    
    # Start banned players kicker in background
    kick_banned_players &
    local kicker_pid=$!
    
    trap cleanup EXIT INT TERM
    
    print_header "STARTING ANTICHEAT SECURITY SYSTEM WITH ENHANCED players.log MANAGEMENT"
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
        kill $monitor_pid $kicker_pid 2>/dev/null
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
                "!buy_admin")
                    handle_rank_purchase "$player_name" "admin" 100
                    ;;
                "!buy_mod")
                    handle_rank_purchase "$player_name" "mod" 50
                    ;;
                "!tickets")
                    local tickets=$(get_player_tickets "$player_name")
                    send_server_command "$player_name, you have $tickets tickets."
                    ;;
                *)
                    # Check for dangerous activity
                    check_dangerous_activity "$player_name" "$message"
                    ;;
            esac
        fi
    done
    
    kill $monitor_pid $kicker_pid 2>/dev/null
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
