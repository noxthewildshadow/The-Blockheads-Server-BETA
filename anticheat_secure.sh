#!/bin/bash
# =============================================================================
# THE BLOCKHEADS ANTICHEAT SECURITY SYSTEM WITH IP VERIFICATION
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
ADMIN_OFFENSES_FILE="$LOG_DIR/admin_offenses_$PORT.json"
PLAYERS_LOG="$LOG_DIR/players.log"
SCREEN_SERVER="blockheads_server_$PORT"
IP_CHANGE_ATTEMPTS_FILE="$LOG_DIR/ip_change_attempts.json"
PASSWORD_CHANGE_ATTEMPTS_FILE="$LOG_DIR/password_change_attempts.json"
SUPERADMINS_GLOBAL_FILE="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/cloudWideOwnedAdminlist.txt"

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

# Track active verified players
declare -A active_verified_players

# Track last sync time to avoid redundant operations
LAST_SYNC_TIME=0
SYNC_INTERVAL=0.5  # Sync every 0.5 seconds

# Track last known ranks to detect changes
declare -A last_known_ranks

# Function to check if a player name is valid (only letters, numbers, and underscores)
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

# Function to initialize authorization files
initialize_authorization_files() {
    [ ! -f "$PLAYERS_LOG" ] && touch "$PLAYERS_LOG"
    [ ! -f "$IP_CHANGE_ATTEMPTS_FILE" ] && echo "{}" > "$IP_CHANGE_ATTEMPTS_FILE"
    [ ! -f "$PASSWORD_CHANGE_ATTEMPTS_FILE" ] && echo "{}" > "$PASSWORD_CHANGE_ATTEMPTS_FILE"
    
    # Clear all list files on startup (they will be populated with active players only)
    local list_files=("adminlist.txt" "modlist.txt" "whitelist.txt" "blacklist.txt" "cloudwideownedadminlist.txt")
    for list_file in "${list_files[@]}"; do
        local full_path="$LOG_DIR/$list_file"
        if [ -f "$full_path" ]; then
            > "$full_path"  # Clear the file but keep it existing
            print_success "Cleared $list_file on startup"
        fi
    done
    
    # Initialize last known ranks from players.log
    if [ -f "$PLAYERS_LOG" ]; then
        while IFS='|' read -r name first_ip current_ip password rank whitelisted blacklisted; do
            [ -n "$name" ] && [ -n "$rank" ] && last_known_ranks["$name"]="$rank"
        done < "$PLAYERS_LOG"
    fi
}

# Function to validate authorization
validate_authorization() {
    # This function now only validates active players
    local admin_list="$LOG_DIR/adminlist.txt"
    local mod_list="$LOG_DIR/modlist.txt"
    local super_list="$LOG_DIR/cloudwideownedadminlist.txt"
    
    # Clear the lists first (they will be repopulated with active verified players)
    > "$admin_list"
    > "$mod_list"
    > "$super_list"
    
    # Populate lists only with active verified players
    for player_name in "${!active_verified_players[@]}"; do
        local player_info=$(get_player_info "$player_name")
        if [ -n "$player_info" ]; then
            local rank=$(echo "$player_info" | cut -d'|' -f4)
            if [ "$rank" = "SUPER" ]; then
                echo "$player_name" >> "$super_list"
                echo "$player_name" >> "$admin_list"  # SUPER también son ADMIN
            elif [ "$rank" = "ADMIN" ]; then
                echo "$player_name" >> "$admin_list"
            elif [ "$rank" = "MOD" ]; then
                echo "$player_name" >> "$mod_list"
            fi
        fi
    done
    
    print_success "Updated authorization lists with active verified players only"
}

# Function to check for rank changes and update immediately
check_and_update_rank_changes() {
    local player_name="$1"
    local current_rank="$2"
    
    # Check if rank has changed
    if [[ "${last_known_ranks[$player_name]}" != "$current_rank" ]]; then
        print_warning "Rank change detected for $player_name: ${last_known_ranks[$player_name]} -> $current_rank"
        last_known_ranks["$player_name"]="$current_rank"
        
        # If player is active and verified, update lists immediately
        if [[ -n "${active_verified_players[$player_name]}" ]] && is_player_connected "$player_name"; then
            print_success "Immediate rank update for active player: $player_name -> $current_rank"
            sync_single_player_to_lists "$player_name" "$current_rank"
            return 0
        fi
    fi
    
    return 1
}

# Function to sync a single player to lists (for immediate updates)
sync_single_player_to_lists() {
    local player_name="$1" rank="$2"
    local player_info=$(get_player_info "$player_name")
    
    if [ -z "$player_info" ]; then
        return 1
    fi
    
    local current_ip=$(echo "$player_info" | cut -d'|' -f2)
    local whitelisted=$(echo "$player_info" | cut -d'|' -f5)
    local blacklisted=$(echo "$player_info" | cut -d'|' -f6)
    
    local admin_list="$LOG_DIR/adminlist.txt"
    local mod_list="$LOG_DIR/modlist.txt"
    local super_list="$LOG_DIR/cloudwideownedadminlist.txt"
    local white_list="$LOG_DIR/whitelist.txt"
    local black_list="$LOG_DIR/blacklist.txt"
    
    # Remove player from all rank lists first
    remove_from_list_file "$player_name" "admin"
    remove_from_list_file "$player_name" "mod"
    remove_from_list_file "$player_name" "cloudwideownedadmin"
    
    # Add to appropriate rank list
    case "$rank" in
        "SUPER")
            echo "$player_name" >> "$super_list"
            echo "$player_name" >> "$admin_list"
            send_server_command "$SCREEN_SERVER" "/admin $player_name"
            ;;
        "ADMIN")
            echo "$player_name" >> "$admin_list"
            send_server_command "$SCREEN_SERVER" "/admin $player_name"
            ;;
        "MOD")
            echo "$player_name" >> "$mod_list"
            send_server_command "$SCREEN_SERVER" "/mod $player_name"
            ;;
        *)
            # Player has no rank, ensure they are removed
            send_server_command "$SCREEN_SERVER" "/unadmin $player_name"
            send_server_command "$SCREEN_SERVER" "/unmod $player_name"
            ;;
    esac
    
    # Handle whitelist/blacklist
    if [ "$whitelisted" = "YES" ]; then
        echo "$player_name" >> "$white_list"
        send_server_command "$SCREEN_SERVER" "/whitelist $current_ip"
    else
        if grep -q "^$player_name$" "$white_list" 2>/dev/null; then
            send_server_command "$SCREEN_SERVER" "/unwhitelist $current_ip"
        fi
    fi
    
    if [ "$blacklisted" = "YES" ]; then
        echo "$player_name" >> "$black_list"
        send_server_command "$SCREEN_SERVER" "/ban $current_ip"
        send_server_command "$SCREEN_SERVER" "/ban $player_name"
    else
        if grep -q "^$player_name$" "$black_list" 2>/dev/null; then
            send_server_command "$SCREEN_SERVER" "/unban $current_ip"
            send_server_command "$SCREEN_SERVER" "/unban $player_name"
        fi
    fi
    
    return 0
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
    write_json_file "$ADMIN_OFFENSES_FILE" "$offsets_data"
    print_warning "Recorded offense #$current_offenses for admin $admin_name"
    return $current_offenses
}

# Function to clear admin offenses
clear_admin_offenses() {
    local admin_name="$1"
    local offenses_data=$(read_json_file "$ADMIN_OFFENSES_FILE" 2>/dev/null || echo '{}')
    offenses_data=$(echo "$offenses_data" | jq --arg admin "$admin_name" 'del(.[$admin])')
    write_json_file "$ADMIN_OFFENSES_FILE" "$offsets_data"
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

# Function to update player info in players.log
update_player_info() {
    local player_name="$1" first_ip="$2" current_ip="$3" password="$4" rank="$5" whitelisted="${6:-NO}" blacklisted="${7:-NO}"
    if [ -f "$PLAYERS_LOG" ]; then
        # Remove existing entry
        sed -i "/^$player_name|/Id" "$PLAYERS_LOG"
        # Add new entry
        echo "$player_name|$first_ip|$current_ip|$password|$rank|$whitelisted|$blacklisted" >> "$PLAYERS_LOG"
        print_success "Updated player info in registry: $player_name -> First IP: $first_ip, Current IP: $current_ip, Password: $password, Rank: $rank, Whitelisted: $whitelisted, Blacklisted: $blacklisted"
        
        # Check for rank change and update immediately if needed
        check_and_update_rank_changes "$player_name" "$rank"
    fi
}

# Function to get player info from players.log
get_player_info() {
    local player_name="$1"
    if [ -f "$PLAYERS_LOG" ]; then
        while IFS='|' read -r name first_ip current_ip password rank whitelisted blacklisted; do
            if [ "$name" = "$player_name" ]; then
                echo "$first_ip|$current_ip|$password|$rank|$whitelisted|$blacklisted"
                return 0
            fi
        done < <(grep -i "^$player_name|" "$PLAYERS_LOG")
    fi
    echo ""
}

# Function to update player rank in players.log
update_player_rank() {
    local player_name="$1" new_rank="$2"
    local player_info=$(get_player_info "$player_name")
    
    if [ -n "$player_info" ]; then
        local first_ip=$(echo "$player_info" | cut -d'|' -f1)
        local current_ip=$(echo "$player_info" | cut -d'|' -f2)
        local password=$(echo "$player_info" | cut -d'|' -f3)
        local whitelisted=$(echo "$player_info" | cut -d'|' -f5)
        local blacklisted=$(echo "$player_info" | cut -d'|' -f6)
        update_player_info "$player_name" "$first_ip" "$current_ip" "$password" "$new_rank" "$whitelisted" "$blacklisted"
        print_success "Updated player rank in registry: $player_name -> $new_rank"
        
        # Update immediately if player is active
        if [[ -n "${active_verified_players[$player_name]}" ]] && is_player_connected "$player_name"; then
            sync_single_player_to_lists "$player_name" "$new_rank"
        fi
    else
        print_error "Player $player_name not found in registry. Cannot update rank."
    fi
}

# Function to send delayed uncommands
send_delayed_uncommands() {
    local target_player="$1" command_type="$2"
    (
        sleep 2; screen -S "$SCREEN_SERVER" -p 0 -X stuff "/un${command_type} $target_player$(printf \\r)" 2>/dev/null
        sleep 2; screen -S "$SCREEN_SERVER" -p 0 -X stuff "/un${command_type} $target_player$(printf \\r)" 2>/dev/null
        sleep 1; screen -S "$SCREEN_SERVER" -p 0 -X stuff "/un${command_type} $target_player$(printf \\r)" 2>/dev/null
        remove_from_list_file "$target_player" "$command_type"
    ) &
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
    local player_info=$(get_player_info "$player_name")
    if [ -n "$player_info" ]; then
        echo "$player_info" | cut -d'|' -f4
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

# Function to handle password reminders for players with IP changes
handle_ip_change_reminder() {
    local player_name="$1" reminder_type="$2"
    
    case "$reminder_type" in
        "ip_changed_no_password")
            # Mensaje consolidado para cambio de IP sin contraseña
            send_server_command "$SCREEN_SERVER" "WARNING: $player_name, your IP has changed but you don't have a password set. Use !ip_psw PASSWORD CONFIRM_PASSWORD to set your password, or you may lose access to your account. Example: !ip_psw mypassword123 mypassword123"
            ;;
        "new_player_no_password")
            # Mensaje consolidado para jugador nuevo sin contraseña
            send_server_command "$SCREEN_SERVER" "REMINDER: $player_name, please set your password with !ip_psw to secure your account. Example: !ip_psw mypassword123 mypassword123"
            ;;
        "superadmin_reminder")
            # Mensaje consolidado para superadmin
            local player_info=$(get_player_info "$player_name")
            if [ -n "$player_info" ]; then
                local password=$(echo "$player_info" | cut -d'|' -f3)
                if [ "$password" = "NONE" ]; then
                    send_server_command "$SCREEN_SERVER" "SUPER ADMIN $player_name has joined the server! REMINDER: Please set your password with !ip_psw to secure your account."
                else
                    send_server_command "$SCREEN_SERVER" "SUPER ADMIN $player_name has joined the server!"
                fi
            fi
            ;;
    esac
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
    
    # Send consolidated warning message to player after 3 seconds
    (
        sleep 3
        if is_player_connected "$player_name" && is_in_grace_period "$player_name"; then
            send_server_command "$SCREEN_SERVER" "SECURITY ALERT: $player_name, your IP has changed! Verify with: !ip_change YOUR_PASSWORD within 30 seconds or you will be kicked."
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
    local player_info=$(get_player_info "$player_name")
    
    if [ -z "$player_info" ]; then
        print_error "Player $player_name not found in registry"
        schedule_clear_and_messages "ERROR: $player_name, you are not registered in the system." "Use !ip_psw to set a password first." "Example: !ip_psw mypassword123 mypassword123"
        return 1
    fi
    
    local registered_first_ip=$(echo "$player_info" | cut -d'|' -f1)
    local registered_current_ip=$(echo "$player_info" | cut -d'|' -f2)
    local registered_password=$(echo "$player_info" | cut -d'|' -f3)
    local registered_rank=$(echo "$player_info" | cut -d'|' -f4)
    local registered_whitelisted=$(echo "$player_info" | cut -d'|' -f5)
    local registered_blacklisted=$(echo "$player_info" | cut -d'|' -f6)
    
    if [ "$registered_password" != "$password" ]; then
        print_error "Invalid password for IP change: $player_name"
        schedule_clear_and_messages "ERROR: $player_name, the password is incorrect." "Usage: !ip_change YOUR_CURRENT_PASSWORD"
        return 1
    fi
    
    # Update IP in players.log
    update_player_info "$player_name" "$registered_first_ip" "$current_ip" "$registered_password" "$registered_rank" "$registered_whitelisted" "$registered_blacklisted"
    print_success "IP updated for $player_name: $current_ip"
    
    # Mark player as verified
    active_verified_players["$player_name"]=1
    
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
    local player_info=$(get_player_info "$player_name")

    # Si el jugador ya existe en el registro, verificar si ya tiene contraseña
    if [ -n "$player_info" ]; then
        local registered_password=$(echo "$player_info" | cut -d'|' -f3)
        if [ "$registered_password" != "NONE" ]; then
            print_warning "Player $player_name already has a password set."
            schedule_clear_and_messages "ERROR: $player_name, you already have a password set." "If you want to change it, use: !ip_psw_change OLD_PASSWORD NEW_PASSWORD"
            return 1
        fi
    fi

    # Validar contraseña
    if [ ${#password} -lt 6 ]; then
        schedule_clear_and_messages "ERROR: $player_name, password must be at least 6 characters." "Example: !ip_psw mypassword123 mypassword123"
        return 1
    fi

    if [ "$password" != "$confirm_password" ]; then
        schedule_clear_and_messages "ERROR: $player_name, passwords do not match." "You must enter the same password twice to confirm it." "Example: !ip_psw mypassword123 mypassword123"
        return 1
    fi

    # Actualizar contraseña
    if [ -n "$player_info" ]; then
        local first_ip=$(echo "$player_info" | cut -d'|' -f1)
        local current_ip=$(echo "$player_info" | cut -d'|' -f2)
        local rank=$(echo "$player_info" | cut -d'|' -f4)
        local whitelisted=$(echo "$player_info" | cut -d'|' -f5)
        local blacklisted=$(echo "$player_info" | cut -d'|' -f6)
        update_player_info "$player_name" "$first_ip" "$current_ip" "$password" "$rank" "$whitelisted" "$blacklisted"
    else
        local rank=$(get_player_rank "$player_name")
        update_player_info "$player_name" "$player_ip" "$player_ip" "$password" "$rank" "NO" "NO"
    fi

    # Mark player as verified
    active_verified_players["$player_name"]=1

    schedule_clear_and_messages "SUCCESS: $player_name, your IP password has been set successfully." "You can now use !ip_change YOUR_PASSWORD if your IP changes."
    return 0
}

# Function to handle password change
handle_password_change() {
    local player_name="$1" old_password="$2" new_password="$3"
    local player_info=$(get_player_info "$player_name")
    
    if [ -z "$player_info" ]; then
        print_error "Player $player_name not found in registry"
        schedule_clear_and_messages "ERROR: $player_name, you don't have a password set." "Use !ip_psw to generate one first." "Example: !ip_psw mypassword123 mypassword123"
        return 1
    fi
    
    local first_ip=$(echo "$player_info" | cut -d'|' -f1)
    local current_ip=$(echo "$player_info" | cut -d'|' -f2)
    local registered_password=$(echo "$player_info" | cut -d'|' -f3)
    local rank=$(echo "$player_info" | cut -d'|' -f4)
    local whitelisted=$(echo "$player_info" | cut -d'|' -f5)
    local blacklisted=$(echo "$player_info" | cut -d'|' -f6)
    
    # Verificar que la contraseña anterior coincida
    if [ "$registered_password" != "$old_password" ]; then
        print_error "Invalid old password for $player_name"
        schedule_clear_and_messages "ERROR: $player_name, the old password is incorrect." "Usage: !ip_psw_change OLD_PASSWORD NEW_PASSWORD"
        return 1
    fi
    
    # Verificar intentos de cambio de contraseña
    local current_time=$(date +%s)
    local attempts_data=$(read_json_file "$PASSWORD_CHANGE_ATTEMPTS_FILE" 2>/dev/null || echo '{}')
    local current_attempts=$(echo "$attempts_data" | jq -r --arg player "$player_name" '.[$player]?.attempts // 0')
    local last_attempt_time=$(echo "$attempts_data" | jq -r --arg player "$player_name" '.[$player]?.last_attempt // 0')
    
    # Reiniciar contador si ha pasado más de 1 hora
    [ $((current_time - last_attempt_time)) -gt 3600 ] && current_attempts=0
    
    current_attempts=$((current_attempts + 1))
    attempts_data=$(echo "$attempts_data" | jq --arg player "$player_name" \
        --argjson attempts "$current_attempts" --argjson time "$current_time" \
        '.[$player] = {"attempts": $attempts, "last_attempt": $time}')
    
    write_json_file "$PASSWORD_CHANGE_ATTEMPTS_FILE" "$attempts_data"
    
    if [ $current_attempts -gt 3 ]; then
        print_error "Password change limit exceeded for $player_name"
        schedule_clear_and_messages "ERROR: $player_name, you've exceeded the password change limit (3 times per hour)." "Please wait before trying again."
        return 1
    fi
    
    # Validar nueva contraseña
    if [ ${#new_password} -lt 6 ]; then
        schedule_clear_and_messages "ERROR: $player_name, new password must be at least 6 characters." "Example: !ip_psw_change oldpass newpassword123"
        return 1
    fi
    
    # Actualizar contraseña
    update_player_info "$player_name" "$first_ip" "$current_ip" "$new_password" "$rank" "$whitelisted" "$blacklisted"
    
    schedule_clear_and_messages "SUCCESS: $player_name, your password has been changed successfully." "You can now use !ip_change NEW_PASSWORD if your IP changes."
    
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
        local registered_first_ip=$(echo "$player_info" | cut -d'|' -f1)
        local registered_current_ip=$(echo "$player_info" | cut -d'|' -f2)
        local registered_password=$(echo "$player_info" | cut -d'|' -f3)
        local registered_rank=$(echo "$player_info" | cut -d'|' -f4)
        local registered_whitelisted=$(echo "$player_info" | cut -d'|' -f5)
        local registered_blacklisted=$(echo "$player_info" | cut -d'|' -f6)
        
        if [ "$registered_current_ip" != "$player_ip" ]; then
            # IP doesn't match - check if player has password
            if [ "$registered_password" = "NONE" ]; then
                # No password set - send consolidated reminder after 5 seconds (only once)
                print_warning "IP changed for $player_name but no password set (old IP: $registered_current_ip, new IP: $player_ip)"
                # Only show announcement once per player connection
                if [[ -z "${ip_mismatch_announced[$player_name]}" ]]; then
                    ip_mismatch_announced["$player_name"]=1
                    (
                        sleep 5
                        # Check if player is still connected before sending message
                        if is_player_connected "$player_name"; then
                            handle_ip_change_reminder "$player_name" "ip_changed_no_password"
                        fi
                    ) &
                fi
                # Update IP in registry
                update_player_info "$player_name" "$registered_first_ip" "$player_ip" "$registered_password" "$registered_rank" "$registered_whitelisted" "$registered_blacklisted"
            else
                # Password set - start grace period (only if not already started)
                if [[ -z "${ip_change_grace_periods[$player_name]}" ]]; then
                    print_warning "IP changed for $player_name (old IP: $registered_current_ip, new IP: $player_ip)"
                    # Start grace period immediately
                    start_ip_change_grace_period "$player_name" "$player_ip"
                fi
            fi
        else
            # IP matches - mark as verified immediately
            active_verified_players["$player_name"]=1
            
            # Update rank if needed and check for changes
            local current_rank=$(get_player_rank "$player_name")
            if [ "$current_rank" != "$registered_rank" ]; then
                update_player_info "$player_name" "$registered_first_ip" "$player_ip" "$registered_password" "$current_rank" "$registered_whitelisted" "$registered_blacklisted"
            else
                check_and_update_rank_changes "$player_name" "$current_rank"
            fi
        fi
    else
        # New player - add to players.log with no password
        local rank=$(get_player_rank "$player_name")
        update_player_info "$player_name" "$player_ip" "$player_ip" "NONE" "$rank" "NO" "NO"
        print_success "Added new player to registry: $player_name ($player_ip) with rank: $rank"
        
        # Send consolidated reminder after 5 seconds (only once)
        if [[ -z "${ip_mismatch_announced[$player_name]}" ]]; then
            ip_mismatch_announced["$player_name"]=1
            (
                sleep 5
                # Check if player is still connected before sending message
                if is_player_connected "$player_name"; then
                    handle_ip_change_reminder "$player_name" "new_player_no_password"
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
    
    if [ "$(get_player_rank "$player_name")" = "ADMIN" ]; then
        print_error "UNAUTHORIZED COMMAND: Admin $player_name attempted to use $command on $target_player"
        send_server_command "$SCREEN_SERVER" "WARNING: Admin $player_name attempted unauthorized rank assignment!"
        local command_type=""
        [ "$command" = "/admin" ] && command_type="admin"
        [ "$command" = "/mod" ] && command_type="mod"
        if [ -n "$command_type" ]; then
            screen -S "$SCREEN_SERVER" -p 0 -X stuff "/un${command_type} $target_player$(printf \\r)" 2>/dev/null
            remove_from_list_file "$target_player" "$command_type"
            send_delayed_uncommands "$target_player" "$command_type"
            # Update player rank in players.log
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
            # Remove from admin files
            remove_from_list_file "$player_name" "admin"
            screen -S "$SCREEN_SERVER" -p 0 -X stuff "/unadmin $player_name$(printf \\r)" 2>/dev/null
            # Add to mod files by updating players.log
            update_player_rank "$player_name" "MOD"
            clear_admin_offenses "$player_name"
        fi
    else
        print_warning "Non-admin player $player_name attempted to use $command on $target_player"
        send_server_command "$SCREEN_SERVER" "$player_name, you don't have permission to assign ranks."
        if [ "$command" = "/admin" ]; then
            screen -S "$SCREEN_SERVER" -p 0 -X stuff "/unadmin $target_player$(printf \\r)" 2>/dev/null
            remove_from_list_file "$target_player" "admin"
            send_delayed_uncommands "$target_player" "admin"
            # Update player rank in players.log
            update_player_rank "$target_player" "NONE"
        elif [ "$command" = "/mod" ]; then
            screen -S "$SCREEN_SERVER" -p 0 -X stuff "/unmod $target_player$(printf \\r)" 2>/dev/null
            remove_from_list_file "$target_player" "mod"
            send_delayed_uncommands "$target_player" "mod"
            # Update player rank in players.log
            update_player_rank "$target_player" "NONE"
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

# Function to sync players.log with list files (MODIFIED FOR ACTIVE PLAYERS ONLY) - HIGH FREQUENCY VERSION
sync_players_log_to_lists() {
    local current_time=$(date +%s)
    
    # Only sync if enough time has passed since last sync
    if (( $(echo "$current_time - $LAST_SYNC_TIME >= $SYNC_INTERVAL" | bc -l) )); then
        LAST_SYNC_TIME=$current_time
    else
        return  # Skip this sync, too soon
    fi
    
    [ ! -f "$PLAYERS_LOG" ] && return
    
    local admin_list="$LOG_DIR/adminlist.txt"
    local mod_list="$LOG_DIR/modlist.txt"
    local super_list="$LOG_DIR/cloudwideownedadminlist.txt"
    local white_list="$LOG_DIR/whitelist.txt"
    local black_list="$LOG_DIR/blacklist.txt"
    
    # Create temporary files for the new lists
    local new_admin_list=$(mktemp)
    local new_mod_list=$(mktemp)
    local new_super_list=$(mktemp)
    local new_white_list=$(mktemp)
    local new_black_list=$(mktemp)
    
    # Create temporary files for the old lists
    local old_admin_list=$(mktemp)
    local old_mod_list=$(mktemp)
    local old_super_list=$(mktemp)
    local old_white_list=$(mktemp)
    local old_black_list=$(mktemp)
    
    # Copy the old lists to temporary files for comparison
    [ -f "$admin_list" ] && cp "$admin_list" "$old_admin_list"
    [ -f "$mod_list" ] && cp "$mod_list" "$old_mod_list"
    [ -f "$super_list" ] && cp "$super_list" "$old_super_list"
    [ -f "$white_list" ] && cp "$white_list" "$old_white_list"
    [ -f "$black_list" ] && cp "$black_list" "$old_black_list"
    
    # Process each player in players.log ONLY IF THEY ARE ACTIVE AND VERIFIED
    while IFS='|' read -r name first_ip current_ip password rank whitelisted blacklisted; do
        # Skip invalid entries
        [ -z "$name" ] && continue
        
        # Check for rank changes
        check_and_update_rank_changes "$name" "$rank"
        
        # Only process if player is active and verified
        if [[ -n "${active_verified_players[$name]}" ]] && is_player_connected "$name"; then
            # Process rank
            if [ "$rank" = "SUPER" ]; then
                echo "$name" >> "$new_super_list"
                echo "$name" >> "$new_admin_list"  # SUPER también son ADMIN
                # Ensure the player is not in mod list
                if grep -q "^$name$" "$new_mod_list" 2>/dev/null; then
                    sed -i "/^$name$/d" "$new_mod_list"
                fi
            elif [ "$rank" = "ADMIN" ]; then
                echo "$name" >> "$new_admin_list"
                # Ensure the player is not in super list if they are no longer SUPER
                if grep -q "^$name$" "$new_super_list" 2>/dev/null; then
                    sed -i "/^$name$/d" "$new_super_list"
                fi
                # Ensure the player is not in mod list
                if grep -q "^$name$" "$new_mod_list" 2>/dev/null; then
                    sed -i "/^$name$/d" "$new_mod_list"
                fi
            elif [ "$rank" = "MOD" ]; then
                echo "$name" >> "$new_mod_list"
                # Ensure the player is not in admin or super lists
                if grep -q "^$name$" "$new_admin_list" 2>/dev/null; then
                    sed -i "/^$name$/d" "$new_admin_list"
                fi
                if grep -q "^$name$" "$new_super_list" 2>/dev/null; then
                    sed -i "/^$name$/d" "$new_super_list"
                fi
            else
                # Ensure the player is not in admin, mod or super lists
                if grep -q "^$name$" "$new_admin_list" 2>/dev/null; then
                    sed -i "/^$name$/d" "$new_admin_list"
                fi
                if grep -q "^$name$" "$new_mod_list" 2>/dev/null; then
                    sed -i "/^$name$/d" "$new_mod_list"
                fi
                if grep -q "^$name$" "$new_super_list" 2>/dev/null; then
                    sed -i "/^$name$/d" "$new_super_list"
                fi
            fi
            
            # Process whitelisted
            if [ "$whitelisted" = "YES" ]; then
                echo "$name" >> "$new_white_list"
                # Also whitelist the IP if not already whitelisted
                if ! grep -q "^$name$" "$old_white_list" 2>/dev/null; then
                    send_server_command "$SCREEN_SERVER" "/whitelist $current_ip"
                fi
            else
                # Also unwhitelist the IP if currently whitelisted
                if grep -q "^$name$" "$old_white_list" 2>/dev/null; then
                    send_server_command "$SCREEN_SERVER" "/unwhitelist $current_ip"
                fi
            fi
            
            # Process blacklisted
            if [ "$blacklisted" = "YES" ]; then
                echo "$name" >> "$new_black_list"
                # Also ban the IP and player if not already blacklisted
                if ! grep -q "^$name$" "$old_black_list" 2>/dev/null; then
                    send_server_command "$SCREEN_SERVER" "/ban $current_ip"
                    send_server_command "$SCREEN_SERVER" "/ban $name"
                fi
            else
                # Also unban the IP and player if currently blacklisted
                if grep -q "^$name$" "$old_black_list" 2>/dev/null; then
                    send_server_command "$SCREEN_SERVER" "/unban $current_ip"
                    send_server_command "$SCREEN_SERVER" "/unban $name"
                fi
            fi
        else
            # Player is not active or verified - remove from lists if they were previously there
            if grep -q "^$name$" "$old_admin_list" 2>/dev/null; then
                send_server_command "$SCREEN_SERVER" "/unadmin $name"
            fi
            if grep -q "^$name$" "$old_mod_list" 2>/dev/null; then
                send_server_command "$SCREEN_SERVER" "/unmod $name"
            fi
            if grep -q "^$name$" "$old_super_list" 2>/dev/null; then
                # No specific unsuper command, but remove from admin too
                send_server_command "$SCREEN_SERVER" "/unadmin $name"
            fi
            if grep -q "^$name$" "$old_white_list" 2>/dev/null; then
                send_server_command "$SCREEN_SERVER" "/unwhitelist $current_ip"
            fi
            if grep -q "^$name$" "$old_black_list" 2>/dev/null; then
                send_server_command "$SCREEN_SERVER" "/unban $current_ip"
                send_server_command "$SCREEN_SERVER" "/unban $name"
            fi
        fi
    done < "$PLAYERS_LOG"
    
    # Compare old and new admin lists to execute admin commands
    while read player; do
        if [ -n "$player" ] && ! grep -q "^$player$" "$old_admin_list" 2>/dev/null; then
            # This player is newly added to admin list
            send_server_command "$SCREEN_SERVER" "/admin $player"
        fi
    done < "$new_admin_list"
    
    while read player; do
        if [ -n "$player" ] && ! grep -q "^$player$" "$new_admin_list" 2>/dev/null; then
            # This player was removed from admin list
            send_server_command "$SCREEN_SERVER" "/unadmin $player"
        fi
    done < "$old_admin_list"
    
    # Compare old and new mod lists to execute mod commands
    while read player; do
        if [ -n "$player" ] && ! grep -q "^$player$" "$old_mod_list" 2>/dev/null; then
            # This player is newly added to mod list
            send_server_command "$SCREEN_SERVER" "/mod $player"
        fi
    done < "$new_mod_list"
    
    while read player; do
        if [ -n "$player" ] && ! grep -q "^$player$" "$new_mod_list" 2>/dev/null; then
            # This player was removed from mod list
            send_server_command "$SCREEN_SERVER" "/unmod $player"
        fi
    done < "$old_mod_list"
    
    # Compare old and new super lists to execute super admin commands
    while read player; do
        if [ -n "$player" ] && ! grep -q "^$player$" "$old_super_list" 2>/dev/null; then
            # This player is newly added to super list - also ensure they are admin
            send_server_command "$SCREEN_SERVER" "/admin $player"
        fi
    done < "$new_super_list"
    
    while read player; do
        if [ -n "$player" ] && ! grep -q "^$player$" "$new_super_list" 2>/dev/null; then
            # This player was removed from super list - remove admin if not in admin list
            if ! grep -q "^$player$" "$new_admin_list" 2>/dev/null; then
                send_server_command "$SCREEN_SERVER" "/unadmin $player"
            fi
        fi
    done < "$old_super_list"
    
    # Replace the old list files with the new ones
    cat "$new_admin_list" > "$admin_list" 2>/dev/null
    cat "$new_mod_list" > "$mod_list" 2>/dev/null
    cat "$new_super_list" > "$super_list" 2>/dev/null
    cat "$new_white_list" > "$white_list" 2>/dev/null
    cat "$new_black_list" > "$black_list" 2>/dev/null
    
    # Clean up temporary files
    rm -f "$new_admin_list" "$new_mod_list" "$new_super_list" "$new_white_list" "$new_black_list"
    rm -f "$old_admin_list" "$old_mod_list" "$old_super_list" "$old_white_list" "$old_black_list"
}

# Function to cleanup
cleanup() {
    print_status "Cleaning up anticheat..."
    
    # Remove all active players from lists on shutdown
    for player_name in "${!active_verified_players[@]}"; do
        remove_from_list_file "$player_name" "admin"
        remove_from_list_file "$player_name" "mod"
        remove_from_list_file "$player_name" "cloudwideownedadmin"
        # Note: Whitelist and blacklist are handled by the sync function
    done
    
    kill $(jobs -p) 2>/dev/null
    # Kill all grace period timers
    for pid in "${grace_period_pids[@]}"; do
        kill "$pid" 2>/dev/null
    done
    rm -f "${ADMIN_OFFENSES_FILE}.lock" 2>/dev/null
    rm -f "${IP_CHANGE_ATTEMPTS_FILE}.lock" 2>/dev/null
    rm -f "${PASSWORD_CHANGE_ATTEMPTS_FILE}.lock" 2>/dev/null
    exit 0
}

# Function to monitor log
monitor_log() {
    local log_file="$1"
    LOG_FILE="$log_file"
    initialize_authorization_files
    initialize_admin_offenses
    
    # Start high-frequency sync process in background (every 0.5 seconds)
    (
        while true; do
            sleep 0.5
            sync_players_log_to_lists
        done
    ) &
    local sync_pid=$!
    
    # Start validation process in background (every 30 seconds)
    (
        while true; do 
            sleep 30
            validate_authorization
        done
    ) &
    local validation_pid=$!
    
    trap cleanup EXIT INT TERM
    
    print_header "STARTING ANTICHEAT SECURITY SYSTEM WITH IP VERIFICATION"
    print_status "Monitoring: $log_file"
    print_status "Port: $PORT"
    print_status "Log directory: $LOG_DIR"
    print_status "Sync interval: ${SYNC_INTERVAL}s"
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
        kill $sync_pid 2>/dev/null
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
            
            # Remove player from active verified players and clean up
            unset active_verified_players["$player_name"]
            unset ip_change_grace_periods["$player_name"]
            unset ip_change_pending_players["$player_name"]
            unset ip_mismatch_announced["$player_name"]
            if [ -n "${grace_period_pids[$player_name]}" ]; then
                kill "${grace_period_pids[$player_name]}" 2>/dev/null
                unset grace_period_pids["$player_name"]
            fi
            
            # Immediately remove from lists
            remove_from_list_file "$player_name" "admin"
            remove_from_list_file "$player_name" "mod"
            remove_from_list_file "$player_name" "cloudwideownedadmin"
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
                *)
                    # Check for dangerous activity
                    check_dangerous_activity "$player_name" "$message"
                    ;;
            esac
        fi
    done
    
    kill $validation_pid 2>/dev/null
    kill $sync_pid 2>/dev/null
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
