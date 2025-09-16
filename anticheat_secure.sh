#!/bin/bash
# =============================================================================
# THE BLOCKHEADS ANTICHEAT SECURITY SYSTEM WITH IP VERIFICATION - JSON VERSION
# =============================================================================

# Load common functions
source blockheads_common.sh

# Validate jq is installed
if ! command -v jq &> /dev/null; then
    echo -e "${RED}ERROR: jq is required but not installed. Please install jq first.${NC}"
    exit 1
fi

# Initialize variables
LOG_FILE="$1"
PORT="$2"
LOG_DIR=$(dirname "$LOG_FILE")
DATA_FILE="$LOG_DIR/data.json"
SCREEN_SERVER="blockheads_server_$PORT"

# Track player messages for spam detection
declare -A player_message_times
declare -A player_message_counts

# Track admin commands for spam detection
declare -A admin_last_command_time
declare -A admin_command_count

# Track IP change grace periods
declare -A ip_change_grace_periods
declare -A ip_change_pending_players

# Track IP mismatch announcements to prevent duplicates
declare -A ip_mismatch_announced

# Track grace period timer PIDs to cancel them on verification
declare -A grace_period_pids

# Function to initialize data.json
initialize_data_json() {
    if [ ! -f "$DATA_FILE" ]; then
        echo '{"players": {}, "version": "1.0"}' > "$DATA_FILE"
        print_success "Created new data.json file"
    fi
    
    # Create backup directory
    local backup_dir="$LOG_DIR/backups"
    mkdir -p "$backup_dir"
}

# Function to create backup of data.json
backup_data_json() {
    local backup_dir="$LOG_DIR/backups"
    mkdir -p "$backup_dir"
    
    # Keep only 3 most recent backups
    local backup_files=("$backup_dir"/data.json.bak.*)
    if [ ${#backup_files[@]} -ge 3 ]; then
        # Sort by modification time and remove oldest
        ls -t "$backup_dir"/data.json.bak.* | tail -n +4 | xargs rm -f --
    fi
    
    # Create new backup
    local timestamp=$(date +%Y%m%d_%H%M%S)
    cp "$DATA_FILE" "$backup_dir/data.json.bak.$timestamp"
}

# Function to read data.json with locking
read_data_json() {
    [ ! -f "$DATA_FILE" ] && initialize_data_json
    flock -s 200 cat "$DATA_FILE" 200>"${DATA_FILE}.lock"
}

# Function to write data.json with locking and backup
write_data_json() {
    local data="$1"
    [ ! -f "$DATA_FILE" ] && initialize_data_json
    
    # Create backup before writing
    backup_data_json
    
    flock -x 200 echo "$data" > "$DATA_FILE" 200>"${DATA_FILE}.lock"
    
    # Update list files after writing to JSON
    update_list_files
}

# Function to update list files from data.json
update_list_files() {
    local data=$(read_data_json)
    
    # Update adminlist.txt
    echo "# Usernames in this file are granted admin privileges" > "$LOG_DIR/adminlist.txt"
    echo "$data" | jq -r '.players | to_entries[] | select(.value.rank == "admin") | .key' >> "$LOG_DIR/adminlist.txt"
    
    # Update modlist.txt
    echo "# Usernames in this file are granted mod privileges" > "$LOG_DIR/modlist.txt"
    echo "$data" | jq -r '.players | to_entries[] | select(.value.rank == "mod") | .key' >> "$LOG_DIR/modlist.txt"
    
    # Update blacklist.txt
    echo "# Usernames in this file are blacklisted" > "$LOG_DIR/blacklist.txt"
    echo "$data" | jq -r '.players | to_entries[] | select(.value.blacklisted == "TRUE") | .key' >> "$LOG_DIR/blacklist.txt"
    
    # Update whitelist.txt
    echo "# Usernames in this file are whitelisted" > "$LOG_DIR/whitelist.txt"
    echo "$data" | jq -r '.players | to_entries[] | select(.value.whitelisted == "TRUE") | .key' >> "$LOG_DIR/whitelist.txt"
}

# Function to check if a player name is valid
is_valid_player_name() {
    local name="$1"
    # Check for empty name
    if [[ -z "$name" ]]; then
        return 1
    fi
    
    # Check for spaces at beginning or end
    if [[ "$name" =~ ^[[:space:]]+ ]] || [[ "$name" =~ [[:space:]]+$ ]]; then
        return 1
    fi
    
    # Check for invalid characters (only allow letters, numbers, and underscores)
    if [[ "$name" =~ [^a-zA-Z0-9_] ]]; then
        return 1
    fi
    
    return 0
}

# Function to schedule clear and multiple messages
schedule_clear_and_messages() {
    local messages=("$@")
    # Clear chat immediately
    screen -S "$SCREEN_SERVER" -p 0 -X stuff "/clear$(printf \\r)" 2>/dev/null
    # Send messages after 2 seconds
    (
        sleep 2
        for msg in "${messages[@]}"; do
            send_server_command "$SCREEN_SERVER" "$msg"
        done
    ) &
}

# Function to get player data
get_player_data() {
    local player_name="$1"
    local data=$(read_data_json)
    echo "$data" | jq -r --arg player "$player_name" '.players[$player] // "{}"'
}

# Function to set player data
set_player_data() {
    local player_name="$1"
    local player_data="$2"
    local data=$(read_data_json)
    data=$(echo "$data" | jq --arg player "$player_name" --argjson pdata "$player_data" '.players[$player] = $pdata')
    write_data_json "$data"
}

# Function to update player IP
update_player_ip() {
    local player_name="$1" player_ip="$2"
    local player_data=$(get_player_data "$player_name")
    
    if [ "$player_data" != "{}" ]; then
        player_data=$(echo "$player_data" | jq --arg ip "$player_ip" '.ip = $ip')
        set_player_data "$player_name" "$player_data"
    else
        # Create new player entry
        local new_player=$(jq -n \
            --arg ip "$player_ip" \
            --arg password "NONE" \
            --arg rank "NONE" \
            --arg blacklisted "NONE" \
            --arg whitelisted "NONE" \
            --argjson economy '{"tickets": 0, "last_login": 0}' \
            --argjson offenses '{"admin_offenses": 0, "ip_change_attempts": 0, "password_change_attempts": 0}' \
            '{
                ip: $ip,
                password: $password,
                rank: $rank,
                blacklisted: $blacklisted,
                whitelisted: $whitelisted,
                economy: $economy,
                offenses: $offenses
            }')
        set_player_data "$player_name" "$new_player"
    fi
}

# Function to update player rank
update_player_rank() {
    local player_name="$1" new_rank="$2"
    local player_data=$(get_player_data "$player_name")
    
    if [ "$player_data" != "{}" ]; then
        player_data=$(echo "$player_data" | jq --arg rank "$new_rank" '.rank = $rank')
        set_player_data "$player_name" "$player_data"
        print_success "Updated player rank: $player_name -> $new_rank"
    else
        print_error "Player $player_name not found in registry. Cannot update rank."
    fi
}

# Function to update player password
update_player_password() {
    local player_name="$1" new_password="$2"
    local player_data=$(get_player_data "$player_name")
    
    if [ "$player_data" != "{}" ]; then
        player_data=$(echo "$player_data" | jq --arg password "$new_password" '.password = $password')
        set_player_data "$player_name" "$player_data"
        print_success "Updated password for $player_name"
    else
        print_error "Player $player_name not found in registry. Cannot update password."
    fi
}

# Function to update player economy
update_player_economy() {
    local player_name="$1" economy_data="$2"
    local player_data=$(get_player_data "$player_name")
    
    if [ "$player_data" != "{}" ]; then
        player_data=$(echo "$player_data" | jq --argjson economy "$economy_data" '.economy = $economy')
        set_player_data "$player_name" "$player_data"
    else
        print_error "Player $player_name not found in registry. Cannot update economy."
    fi
}

# Function to update player offenses
update_player_offenses() {
    local player_name="$1" offenses_data="$2"
    local player_data=$(get_player_data "$player_name")
    
    if [ "$player_data" != "{}" ]; then
        player_data=$(echo "$player_data" | jq --argjson offenses "$offenses_data" '.offenses = $offenses')
        set_player_data "$player_name" "$player_data"
    else
        print_error "Player $player_name not found in registry. Cannot update offenses."
    fi
}

# Function to record admin offense
record_admin_offense() {
    local admin_name="$1" current_time=$(date +%s)
    local player_data=$(get_player_data "$admin_name")
    
    if [ "$player_data" != "{}" ]; then
        local offenses_data=$(echo "$player_data" | jq -r '.offenses')
        local current_offenses=$(echo "$offenses_data" | jq -r '.admin_offenses // 0')
        local last_offense_time=$(echo "$offenses_data" | jq -r '.last_admin_offense // 0')
        
        [ $((current_time - last_offense_time)) -gt 300 ] && current_offenses=0
        current_offenses=$((current_offenses + 1))
        
        offenses_data=$(echo "$offenses_data" | jq \
            --argjson count "$current_offenses" \
            --argjson time "$current_time" \
            '.admin_offenses = $count | .last_admin_offense = $time')
        
        update_player_offenses "$admin_name" "$offenses_data"
        print_warning "Recorded offense #$current_offenses for admin $admin_name"
        return $current_offenses
    else
        print_error "Admin $admin_name not found in registry"
        return 1
    fi
}

# Function to clear admin offenses
clear_admin_offenses() {
    local admin_name="$1"
    local player_data=$(get_player_data "$admin_name")
    
    if [ "$player_data" != "{}" ]; then
        local offenses_data=$(echo "$player_data" | jq -r '.offenses')
        offenses_data=$(echo "$offenses_data" | jq '.admin_offenses = 0 | .last_admin_offense = 0')
        update_player_offenses "$admin_name" "$offenses_data"
    fi
}

# Function to record IP change attempt
record_ip_change_attempt() {
    local player_name="$1"
    local player_data=$(get_player_data "$player_name")
    
    if [ "$player_data" != "{}" ]; then
        local offenses_data=$(echo "$player_data" | jq -r '.offenses')
        local current_attempts=$(echo "$offenses_data" | jq -r '.ip_change_attempts // 0')
        current_attempts=$((current_attempts + 1))
        
        offenses_data=$(echo "$offenses_data" | jq --argjson attempts "$current_attempts" '.ip_change_attempts = $attempts')
        update_player_offenses "$player_name" "$offenses_data"
    fi
}

# Function to record password change attempt
record_password_change_attempt() {
    local player_name="$1"
    local player_data=$(get_player_data "$player_name")
    
    if [ "$player_data" != "{}" ]; then
        local offenses_data=$(echo "$player_data" | jq -r '.offenses')
        local current_attempts=$(echo "$offenses_data" | jq -r '.password_change_attempts // 0')
        current_attempts=$((current_attempts + 1))
        
        offenses_data=$(echo "$offenses_data" | jq --argjson attempts "$current_attempts" '.password_change_attempts = $attempts')
        update_player_offenses "$player_name" "$offenses_data"
    fi
}

# Function to get player IP by name
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
        gsub(/^[ \t]+|[ \t]+$/, "", ip)
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
    
    # Start grace period countdown and store PID
    (
        sleep 30
        if [ -n "${ip_change_grace_periods[$player_name]}" ]; then
            print_warning "IP change grace period expired for $player_name - kicking player"
            send_server_command "$SCREEN_SERVER" "/kick $player_name"
            unset ip_change_grace_periods["$player_name"]
            unset ip_change_pending_players["$player_name"]
            unset grace_period_pids["$player_name"]
        fi
    ) &
    grace_period_pids["$player_name"]=$!
    
    # Send warning message to player after 5 seconds
    (
        sleep 5
        if is_player_connected "$player_name" && is_in_grace_period "$player_name"; then
            send_server_command "$SCREEN_SERVER" "WARNING: $player_name, your IP has changed from the registered one!"
            send_server_command "$SCREEN_SERVER" "You have 30 seconds to verify your identity with: !ip_change YOUR_CURRENT_PASSWORD"
            send_server_command "$SCREEN_SERVER" "If you don't verify, you will be kicked from the server."
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
        unset grace_period_pids["$player_name"]
        return 1
    fi
}

# Function to validate IP change
validate_ip_change() {
    local player_name="$1" password="$2" current_ip="$3"
    local player_data=$(get_player_data "$player_name")
    
    if [ "$player_data" = "{}" ]; then
        print_error "Player $player_name not found in registry"
        schedule_clear_and_messages "ERROR: $player_name, you are not registered in the system." "Use !ip_psw to set a password first." "Example: !ip_psw mypassword123 mypassword123"
        return 1
    fi
    
    local registered_password=$(echo "$player_data" | jq -r '.password')
    local registered_rank=$(echo "$player_data" | jq -r '.rank')
    
    if [ "$registered_password" != "$password" ]; then
        print_error "Invalid password for IP change: $player_name"
        schedule_clear_and_messages "ERROR: $player_name, the password is incorrect." "Usage: !ip_change YOUR_CURRENT_PASSWORD"
        return 1
    fi
    
    # Update IP in data.json
    update_player_ip "$player_name" "$current_ip"
    print_success "IP updated for $player_name: $current_ip"
    
    # End grace period and cancel kick by killing the timer process
    if [ -n "${grace_period_pids[$player_name]}" ]; then
        kill "${grace_period_pids[$player_name]}" 2>/dev/null
        unset grace_period_pids["$player_name"]
    fi
    unset ip_change_grace_periods["$player_name"]
    unset ip_change_pending_players["$player_name"]
    
    # Send success message
    schedule_clear_and_messages "SUCCESS: $player_name, your IP has been verified and updated!" "Your new IP address is: $current_ip"
    
    return 0
}

# Function to handle password creation
handle_password_creation() {
    local player_name="$1" password="$2" confirm_password="$3" player_ip="$4"
    local player_data=$(get_player_data "$player_name")

    # If player exists in registry, check if they already have a password
    if [ "$player_data" != "{}" ]; then
        local registered_password=$(echo "$player_data" | jq -r '.password')
        if [ "$registered_password" != "NONE" ]; then
            print_warning "Player $player_name already has a password set."
            schedule_clear_and_messages "ERROR: $player_name, you already have a password set." "If you want to change it, use: !ip_psw_change OLD_PASSWORD NEW_PASSWORD"
            return 1
        fi
    fi

    # Validate password
    if [ ${#password} -lt 6 ]; then
        schedule_clear_and_messages "ERROR: $player_name, password must be at least 6 characters." "Example: !ip_psw mypassword123 mypassword123"
        return 1
    fi

    if [ "$password" != "$confirm_password" ]; then
        schedule_clear_and_messages "ERROR: $player_name, passwords do not match." "You must enter the same password twice to confirm it." "Example: !ip_psw mypassword123 mypassword123"
        return 1
    fi

    # Update password
    if [ "$player_data" != "{}" ]; then
        update_player_password "$player_name" "$password"
    else
        # Create new player entry with password
        local new_player=$(jq -n \
            --arg ip "$player_ip" \
            --arg password "$password" \
            --arg rank "NONE" \
            --arg blacklisted "NONE" \
            --arg whitelisted "NONE" \
            --argjson economy '{"tickets": 0, "last_login": 0}' \
            --argjson offenses '{"admin_offenses": 0, "ip_change_attempts": 0, "password_change_attempts": 0}' \
            '{
                ip: $ip,
                password: $password,
                rank: $rank,
                blacklisted: $blacklisted,
                whitelisted: $whitelisted,
                economy: $economy,
                offenses: $offenses
            }')
        set_player_data "$player_name" "$new_player"
    fi

    schedule_clear_and_messages "SUCCESS: $player_name, your IP password has been set successfully." "You can now use !ip_change YOUR_PASSWORD if your IP changes."
    return 0
}

# Function to handle password change
handle_password_change() {
    local player_name="$1" old_password="$2" new_password="$3"
    local player_data=$(get_player_data "$player_name")
    
    if [ "$player_data" = "{}" ]; then
        print_error "Player $player_name not found in registry"
        schedule_clear_and_messages "ERROR: $player_name, you don't have a password set." "Use !ip_psw to generate one first." "Example: !ip_psw mypassword123 mypassword123"
        return 1
    fi
    
    local registered_password=$(echo "$player_data" | jq -r '.password')
    
    # Verify old password matches
    if [ "$registered_password" != "$old_password" ]; then
        print_error "Invalid old password for $player_name"
        schedule_clear_and_messages "ERROR: $player_name, the old password is incorrect." "Usage: !ip_psw_change OLD_PASSWORD NEW_PASSWORD"
        return 1
    fi
    
    # Check password change attempts
    local current_time=$(date +%s)
    local offenses_data=$(echo "$player_data" | jq -r '.offenses')
    local current_attempts=$(echo "$offenses_data" | jq -r '.password_change_attempts // 0')
    local last_attempt_time=$(echo "$offenses_data" | jq -r '.last_password_change_attempt // 0')
    
    # Reset counter if more than 1 hour has passed
    [ $((current_time - last_attempt_time)) -gt 3600 ] && current_attempts=0
    
    current_attempts=$((current_attempts + 1))
    offenses_data=$(echo "$offenses_data" | jq \
        --argjson attempts "$current_attempts" \
        --argjson time "$current_time" \
        '.password_change_attempts = $attempts | .last_password_change_attempt = $time')
    
    update_player_offenses "$player_name" "$offenses_data"
    
    if [ $current_attempts -gt 3 ]; then
        print_error "Password change limit exceeded for $player_name"
        schedule_clear_and_messages "ERROR: $player_name, you've exceeded the password change limit (3 times per hour)." "Please wait before trying again."
        return 1
    fi
    
    # Validate new password
    if [ ${#new_password} -lt 6 ]; then
        schedule_clear_and_messages "ERROR: $player_name, new password must be at least 6 characters." "Example: !ip_psw_change oldpass newpassword123"
        return 1
    fi
    
    # Update password
    update_player_password "$player_name" "$new_password"
    
    schedule_clear_and_messages "SUCCESS: $player_name, your password has been changed successfully." "You can now use !ip_change NEW_PASSWORD if your IP changes."
    
    return 0
}

# Function to check for username theft with IP verification
check_username_theft() {
    local player_name="$1" player_ip="$2"
    
    # Skip if player name is invalid
    ! is_valid_player_name "$player_name" && return 0
    
    # Check if player exists in data.json
    local player_data=$(get_player_data "$player_name")
    
    if [ "$player_data" != "{}" ]; then
        # Player exists, check if IP matches
        local registered_ip=$(echo "$player_data" | jq -r '.ip')
        local registered_rank=$(echo "$player_data" | jq -r '.rank')
        local registered_password=$(echo "$player_data" | jq -r '.password')
        
        if [ "$registered_ip" != "$player_ip" ]; then
            # IP doesn't match - check if player has password
            if [ "$registered_password" = "NONE" ]; then
                # No password set - remind player to set one after 5 seconds (only once)
                print_warning "IP changed for $player_name but no password set (old IP: $registered_ip, new IP: $player_ip)"
                # Only show announcement once per player connection
                if [[ -z "${ip_mismatch_announced[$player_name]}" ]]; then
                    ip_mismatch_announced["$player_name"]=1
                    (
                        sleep 5
                        # Check if player is still connected before sending message
                        if is_player_connected "$player_name"; then
                            send_server_command "$SCREEN_SERVER" "WARNING: $player_name, your IP has changed but you don't have a password set."
                            send_server_command "$SCREEN_SERVER" "Use !ip_psw PASSWORD CONFIRM_PASSWORD to set your password, or you may lose access to your account."
                            send_server_command "$SCREEN_SERVER" "Example: !ip_psw mypassword123 mypassword123"
                        fi
                    ) &
                fi
                # Update IP in registry
                update_player_ip "$player_name" "$player_ip"
            else
                # Password set - start grace period (only if not already started)
                if [[ -z "${ip_change_grace_periods[$player_name]}" ]]; then
                    print_warning "IP changed for $player_name (old IP: $registered_ip, new IP: $player_ip)"
                    # Start grace period immediately
                    start_ip_change_grace_period "$player_name" "$player_ip"
                fi
            fi
        else
            # IP matches - update rank if needed
            local current_rank=$(get_player_rank "$player_name")
            if [ "$current_rank" != "$registered_rank" ]; then
                update_player_rank "$player_name" "$current_rank"
            fi
        fi
    else
        # New player - add to data.json with no password
        local rank=$(get_player_rank "$player_name")
        local new_player=$(jq -n \
            --arg ip "$player_ip" \
            --arg password "NONE" \
            --arg rank "$rank" \
            --arg blacklisted "NONE" \
            --arg whitelisted "NONE" \
            --argjson economy '{"tickets": 0, "last_login": 0}' \
            --argjson offenses '{"admin_offenses": 0, "ip_change_attempts": 0, "password_change_attempts": 0}' \
            '{
                ip: $ip,
                password: $password,
                rank: $rank,
                blacklisted: $blacklisted,
                whitelisted: $whitelisted,
                economy: $economy,
                offenses: $offenses
            }')
        set_player_data "$player_name" "$new_player"
        print_success "Added new player to registry: $player_name ($player_ip) with rank: $rank"
        
        # Remind player to set password after 5 seconds (only once)
        if [[ -z "${ip_mismatch_announced[$player_name]}" ]]; then
            ip_mismatch_announced["$player_name"]=1
            (
                sleep 5
                # Check if player is still connected before sending message
                if is_player_connected "$player_name"; then
                    send_server_command "$SCREEN_SERVER" "WARNING: $player_name, you don't have a password set for IP verification."
                    send_server_command "$SCREEN_SERVER" "Use !ip_psw PASSWORD CONFIRM_PASSWORD to set your password, or you may lose access to your account if your IP changes."
                    send_server_command "$SCREEN_SERVER" "Example: !ip_psw mypassword123 mypassword123"
                fi
            ) &
        fi
    fi
    
    return 0
}

# Function to check if a player is currently connected
is_player_connected() {
    local player_name="$1"
    # Check if player is in the current player list
    if screen -S "$SCREEN_SERVER" -p 0 -X stuff "/list$(printf \\r)" 2>/dev/null; then
        # Give the server a moment to process the command
        sleep 0.5
        # Check the log for the player name in the list
        if tail -n 10 "$LOG_FILE" | grep -q "$player_name"; then
            return 0
        fi
    fi
    return 1
}

# Function to get player rank from list files
get_player_rank() {
    local player_name="$1"
    local data=$(read_data_json)
    echo "$data" | jq -r --arg player "$player_name" '.players[$player].rank // "NONE"'
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
                send_server_command "$SCREEN_SERVER" "WARNING: $player_name, sensitive commands are restricted during IP verification."
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
                send_server_command "$SCREEN_SERVER" "/ban $player_ip"
                send_server_command "$SCREEN_SERVER" "WARNING: $player_name (IP: $player_ip) was banned for spamming"
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
                    send_server_command "$SCREEN_SERVER" "/ban $player_ip"
                    send_server_command "$SCREEN_SERVER" "WARNING: $player_name (IP: $player_ip) was banned for attempting dangerous commands"
                    return 1
                else
                    send_server_command "$SCREEN_SERVER" "WARNING: $player_name, dangerous commands are restricted!"
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
        send_server_command "$SCREEN_SERVER" "WARNING: Admin $player_name attempted unauthorized rank assignment!"
        local command_type=""
        [ "$command" = "/admin" ] && command_type="admin"
        [ "$command" = "/mod" ] && command_type="mod"
        if [ -n "$command_type" ]; then
            screen -S "$SCREEN_SERVER" -p 0 -X stuff "/un${command_type} $target_player$(printf \\r)" 2>/dev/null
            # Update player rank in data.json
            update_player_rank "$target_player" "NONE"
        fi
        record_admin_offense "$player_name"
        local offense_count=$?
        if [ "$offense_count" -eq 1 ]; then
            send_server_command "$SCREEN_SERVER" "$player_name, this is your first warning! Only the server console can assign ranks."
        elif [ "$offense_count" -eq 2 ]; then
            send_server_command "$SCREEN_SERVER" "$player_name, this is your second warning! One more and you will be demoted to mod."
        elif [ "$offense_count" -ge 3 ]; then
            print_warning "THIRD OFFENSE: Admin $player_name is being demoted to mod"
            # Demote to mod
            update_player_rank "$player_name" "mod"
            clear_admin_offenses "$player_name"
        fi
    else
        print_warning "Non-admin player $player_name attempted to use $command on $target_player"
        send_server_command "$SCREEN_SERVER" "$player_name, you don't have permission to assign ranks."
        if [ "$command" = "/admin" ]; then
            screen -S "$SCREEN_SERVER" -p 0 -X stuff "/unadmin $target_player$(printf \\r)" 2>/dev/null
            # Update player rank in data.json
            update_player_rank "$target_player" "NONE"
        elif [ "$command" = "/mod" ]; then
            screen -S "$SCREEN_SERVER" -p 0 -X stuff "/unmod $target_player$(printf \\r)" 2>/dev/null
            # Update player rank in data.json
            update_player_rank "$target_player" "NONE"
        fi
    fi
}

# Function to process console commands
process_console_command() {
    local command="$1"
    local data=$(read_data_json)
    
    case "$command" in
        /KICK*)
            [[ "$command" =~ /KICK\ ([a-zA-Z0-9_]+) ]] && {
                local target_player="${BASH_REMATCH[1]}"
                send_server_command "$SCREEN_SERVER" "/kick $target_player"
                print_success "Kicked player: $target_player"
            }
            ;;
        /BAN*)
            [[ "$command" =~ /BAN\ ([a-zA-Z0-9_]+) ]] && {
                local target_player="${BASH_REMATCH[1]}"
                local player_data=$(get_player_data "$target_player")
                if [ "$player_data" != "{}" ]; then
                    player_data=$(echo "$player_data" | jq '.blacklisted = "TRUE"')
                    set_player_data "$target_player" "$player_data"
                    send_server_command "$SCREEN_SERVER" "/ban $target_player"
                    print_success "Banned player: $target_player"
                else
                    print_error "Player $target_player not found in registry"
                fi
            }
            ;;
        /BAN-NO-DEVICE*)
            [[ "$command" =~ /BAN-NO-DEVICE\ ([a-zA-Z0-9_]+) ]] && {
                local target_player="${BASH_REMATCH[1]}"
                local player_data=$(get_player_data "$target_player")
                if [ "$player_data" != "{}" ]; then
                    player_data=$(echo "$player_data" | jq '.blacklisted = "TRUE"')
                    set_player_data "$target_player" "$player_data"
                    send_server_command "$SCREEN_SERVER" "/ban $target_player"
                    print_success "Banned player (no device): $target_player"
                else
                    print_error "Player $target_player not found in registry"
                fi
            }
            ;;
        /UNBAN*)
            [[ "$command" =~ /UNBAN\ ([a-zA-Z0-9_]+) ]] && {
                local target_player="${BASH_REMATCH[1]}"
                local player_data=$(get_player_data "$target_player")
                if [ "$player_data" != "{}" ]; then
                    player_data=$(echo "$player_data" | jq '.blacklisted = "NONE"')
                    set_player_data "$target_player" "$player_data"
                    send_server_command "$SCREEN_SERVER" "/unban $target_player"
                    print_success "Unbanned player: $target_player"
                else
                    print_error "Player $target_player not found in registry"
                fi
            }
            ;;
        /WHITELIST*)
            [[ "$command" =~ /WHITELIST\ ([a-zA-Z0-9_]+) ]] && {
                local target_player="${BASH_REMATCH[1]}"
                local player_data=$(get_player_data "$target_player")
                if [ "$player_data" != "{}" ]; then
                    player_data=$(echo "$player_data" | jq '.whitelisted = "TRUE"')
                    set_player_data "$target_player" "$player_data"
                    print_success "Whitelisted player: $target_player"
                else
                    print_error "Player $target_player not found in registry"
                fi
            }
            ;;
        /UNWHITELIST*)
            [[ "$command" =~ /UNWHITELIST\ ([a-zA-Z0-9_]+) ]] && {
                local target_player="${BASH_REMATCH[1]}"
                local player_data=$(get_player_data "$target_player")
                if [ "$player_data" != "{}" ]; then
                    player_data=$(echo "$player_data" | jq '.whitelisted = "NONE"')
                    set_player_data "$target_player" "$player_data"
                    print_success "Unwhitelisted player: $target_player"
                else
                    print_error "Player $target_player not found in registry"
                fi
            }
            ;;
        /MOD*)
            [[ "$command" =~ /MOD\ ([a-zA-Z0-9_]+) ]] && {
                local target_player="${BASH_REMATCH[1]}"
                update_player_rank "$target_player" "mod"
                send_server_command "$SCREEN_SERVER" "/mod $target_player"
                print_success "Set player as mod: $target_player"
            }
            ;;
        /UNMOD*)
            [[ "$command" =~ /UNMOD\ ([a-zA-Z0-9_]+) ]] && {
                local target_player="${BASH_REMATCH[1]}"
                update_player_rank "$target_player" "NONE"
                send_server_command "$SCREEN_SERVER" "/unmod $target_player"
                print_success "Removed mod from player: $target_player"
            }
            ;;
        /ADMIN*)
            [[ "$command" =~ /ADMIN\ ([a-zA-Z0-9_]+) ]] && {
                local target_player="${BASH_REMATCH[1]}"
                update_player_rank "$target_player" "admin"
                send_server_command "$SCREEN_SERVER" "/admin $target_player"
                print_success "Set player as admin: $target_player"
            }
            ;;
        /UNADMIN*)
            [[ "$command" =~ /UNADMIN\ ([a-zA-Z0-9_]+) ]] && {
                local target_player="${BASH_REMATCH[1]}"
                update_player_rank "$target_player" "NONE"
                send_server_command "$SCREEN_SERVER" "/unadmin $target_player"
                print_success "Removed admin from player: $target_player"
            }
            ;;
        /CLEAR-BLACKLIST*)
            # Clear all blacklisted players
            data=$(echo "$data" | jq '.players |= map_values(if .blacklisted == "TRUE" then .blacklisted = "NONE" else . end)')
            write_data_json "$data"
            print_success "Cleared blacklist"
            ;;
        /CLEAR-WHITELIST*)
            # Clear all whitelisted players
            data=$(echo "$data" | jq '.players |= map_values(if .whitelisted == "TRUE" then .whitelisted = "NONE" else . end)')
            write_data_json "$data"
            print_success "Cleared whitelist"
            ;;
        /CLEAR-MODLIST*)
            # Clear all mod ranks
            data=$(echo "$data" | jq '.players |= map_values(if .rank == "mod" then .rank = "NONE" else . end)')
            write_data_json "$data"
            print_success "Cleared mod list"
            ;;
        /CLEAR-ADMINLIST*)
            # Clear all admin ranks
            data=$(echo "$data" | jq '.players |= map_values(if .rank == "admin" then .rank = "NONE" else . end)')
            write_data_json "$data"
            print_success "Cleared admin list"
            ;;
        *)
            print_error "Unknown console command: $command"
            ;;
    esac
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
    # Kill all grace period timers
    for pid in "${grace_period_pids[@]}"; do
        kill "$pid" 2>/dev/null
    done
    rm -f "${DATA_FILE}.lock" 2>/dev/null
    exit 0
}

# Function to monitor log
monitor_log() {
    local log_file="$1"
    LOG_FILE="$log_file"
    initialize_data_json
    
    trap cleanup EXIT INT TERM
    
    print_header "STARTING ANTICHEAT SECURITY SYSTEM WITH IP VERIFICATION"
    print_status "Monitoring: $log_file"
    print_status "Port: $PORT"
    print_status "Log directory: $LOG_DIR"
    print_status "Data file: $DATA_FILE"
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
        exit 1
    fi
    
    # Start monitoring the log
    tail -n 0 -F "$log_file" 2>/dev/null | filter_server_log | while read -r line; do
        if [[ "$line" =~ Player\ Connected\ (.+)\ \|\ ([0-9a-fA-F.:]+)\ \|\ ([0-9a-f]+) ]]; then
            local player_name="${BASH_REMATCH[1]}" player_ip="${BASH_REMATCH[2]}" player_hash="${BASH_REMATCH[3]}"
            player_name=$(extract_real_name "$player_name")
            player_name=$(echo "$player_name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            
            # Check for illegal characters first
            if ! is_valid_player_name "$player_name"; then
                print_warning "INVALID PLAYER NAME: '$player_name' (IP: $player_ip, Hash: $player_hash)"
                send_server_command "$SCREEN_SERVER" "WARNING: Invalid player name '$player_name'! You will be banned for 5 seconds."
                print_warning "Banning player with invalid name: '$player_name' (IP: $player_ip)"
                
                # Special handling for names with backslashes
                local safe_name=$(echo "$player_name" | sed 's/\\/\\\\/g')
                
                if [ -n "$player_ip" ] && [ "$player_ip" != "unknown" ]; then
                    send_server_command "$SCREEN_SERVER" "/ban $player_ip"
                    # Kick the player after banning
                    send_server_command "$SCREEN_SERVER" "/kick $safe_name"
                    (
                        sleep 5
                        send_server_command "$SCREEN_SERVER" "/unban $player_ip"
                        print_success "Unbanned IP: $player_ip"
                    ) &
                else
                    # Fallback: ban by name if IP is not available
                    send_server_command "$SCREEN_SERVER" "/ban $safe_name"
                    send_server_command "$SCREEN_SERVER" "/kick $safe_name"
                fi
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
            if ! is_valid_player_name "$command_user"; then
                local ipu=$(get_ip_by_name "$command_user")
                print_warning "INVALID PLAYER NAME: '$command_user' (IP: $ipu)"
                send_server_command "$SCREEN_SERVER" "WARNING: Invalid player name '$command_user'! You will be banned for 5 seconds."
                print_warning "Banning player with invalid name: '$command_user' (IP: $ipu)"
                
                if [ -n "$ipu" ] && [ "$ipu" != "unknown" ]; then
                    send_server_command "$SCREEN_SERVER" "/ban $ipu"
                    send_server_command "$SCREEN_SERVER" "/kick $command_user"
                else
                    send_server_command "$SCREEN_SERVER" "/ban $command_user"
                    send_server_command "$SCREEN_SERVER" "/kick $command_user"
                fi
                continue
            fi
            
            # Check for illegal characters in target player
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
            if ! is_valid_player_name "$player_name"; then
                print_warning "Player with invalid name disconnected: $player_name"
                continue
            fi
            
            print_warning "Player disconnected: $player_name"
            
            # Clean up grace period and announcement tracking if player disconnects
            unset ip_change_grace_periods["$player_name"]
            unset ip_change_pending_players["$player_name"]
            unset ip_mismatch_announced["$player_name"]
            if [ -n "${grace_period_pids[$player_name]}" ]; then
                kill "${grace_period_pids[$player_name]}" 2>/dev/null
                unset grace_period_pids["$player_name"]
            fi
        fi

        # Check for chat messages and dangerous commands
        if [[ "$line" =~ ([a-zA-Z0-9_]+):\ (.+)$ ]]; then
            local player_name="${BASH_REMATCH[1]}" message="${BASH_REMATCH[2]}"
            player_name=$(extract_real_name "$player_name")
            player_name=$(echo "$player_name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            
            # Check for illegal characters
            if ! is_valid_player_name "$player_name"; then
                continue
            fi
            
            # Handle IP change and password commands
            case "$message" in
                "!ip_psw "*)
                    if [[ "$message" =~ !ip_psw\ ([^[:space:]]+)\ ([^[:space:]]+)$ ]]; then
                        local password="${BASH_REMATCH[1]}"
                        local confirm_password="${BASH_REMATCH[2]}"
                        local player_ip=$(get_ip_by_name "$player_name")
                        handle_password_creation "$player_name" "$password" "$confirm_password" "$player_ip"
                    else
                        schedule_clear_and_messages "ERROR: Invalid format for !ip_psw command." "Usage: !ip_psw PASSWORD CONFIRM_PASSWORD" "Example: !ip_psw mypassword123 mypassword123"
                    fi
                    ;;
                "!ip_psw_change "*)
                    if [[ "$message" =~ !ip_psw_change\ ([^[:space:]]+)\ ([^[:space:]]+)$ ]]; then
                        local old_password="${BASH_REMATCH[1]}"
                        local new_password="${BASH_REMATCH[2]}"
                        handle_password_change "$player_name" "$old_password" "$new_password"
                    else
                        schedule_clear_and_messages "ERROR: Invalid format for !ip_psw_change command." "Usage: !ip_psw_change OLD_PASSWORD NEW_PASSWORD" "Example: !ip_psw_change oldpass newpassword123"
                    fi
                    ;;
                "!ip_change "*)
                    if is_in_grace_period "$player_name"; then
                        if [[ "$message" =~ !ip_change\ (.+)$ ]]; then
                            local password="${BASH_REMATCH[1]}"
                            local current_ip="${ip_change_pending_players[$player_name]}"
                            validate_ip_change "$player_name" "$password" "$current_ip"
                        else
                            schedule_clear_and_messages "ERROR: Invalid format for !ip_change command." "Usage: !ip_change YOUR_CURRENT_PASSWORD" "Example: !ip_change mypassword123"
                        fi
                    else
                        schedule_clear_and_messages "ERROR: $player_name, you don't have a pending IP change verification." "This command is only available when your IP has changed and you need to verify your identity."
                    fi
                    ;;
                "!buy_admin"|"!buy_mod"|"!give_admin"|"!give_mod"|"!tickets"|"!help")
                    # These commands are handled by the economy bot
                    continue
                    ;;
                *)
                    # Check for dangerous activity
                    check_dangerous_activity "$player_name" "$message"
                    ;;
            esac
        fi
        
        # Check for console commands
        if [[ "$line" =~ console:\ (.+) ]]; then
            local command="${BASH_REMATCH[1]}"
            process_console_command "$command"
        fi
    done
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
