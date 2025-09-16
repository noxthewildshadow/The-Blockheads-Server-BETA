#!/bin/bash
# =============================================================================
# THE BLOCKHEADS ANTICHEAT SECURITY SYSTEM V2 (JSON-BASED)
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
SCREEN_SERVER="blockheads_server_$PORT"
DATA_FILE="$LOG_DIR/data.json"
DATA_LOCK_FILE="${DATA_FILE}.lock"

# --- Asociative arrays for runtime tracking (not persistent) ---
declare -A player_message_times
declare -A player_message_counts
declare -A admin_last_command_time
declare -A admin_command_count
declare -A ip_change_grace_periods
declare -A ip_change_pending_players
declare -A ip_mismatch_announced
declare -A grace_period_pids

# =============================================================================
# DATA MANAGEMENT & SECURITY (JSON)
# =============================================================================

# Function to create a lock file to prevent race conditions
lock_file() {
    while ! mkdir "$DATA_LOCK_FILE" 2>/dev/null; do
        sleep 0.1
    done
}

# Function to remove the lock file
unlock_file() {
    rmdir "$DATA_LOCK_FILE"
}

# Function to create rolling backups of the data file
backup_data_file() {
    [ -f "${DATA_FILE}.bak2" ] && mv -f "${DATA_FILE}.bak2" "${DATA_FILE}.bak3"
    [ -f "${DATA_FILE}.bak1" ] && mv -f "${DATA_FILE}.bak1" "${DATA_FILE}.bak2"
    [ -f "$DATA_FILE" ] && cp -f "$DATA_FILE" "${DATA_FILE}.bak1"
}

# Function to safely read the entire data.json file
read_data() {
    lock_file
    cat "$DATA_FILE"
    unlock_file
}

# Function to safely write data to data.json, creating backups first
write_data() {
    local json_data="$1"
    lock_file
    backup_data_file
    # Use a temporary file and jq to validate/prettify, preventing corruption
    if echo "$json_data" | jq '.' > "${DATA_FILE}.tmp" 2>/dev/null; then
        mv -f "${DATA_FILE}.tmp" "$DATA_FILE"
    else
        print_error "FATAL: Attempted to write invalid JSON. Write operation aborted to prevent corruption."
        print_error "Restoring from the latest backup..."
        [ -f "${DATA_FILE}.bak1" ] && cp -f "${DATA_FILE}.bak1" "$DATA_FILE"
        rm -f "${DATA_FILE}.tmp"
    fi
    unlock_file
}

# Function to initialize the data.json file if it doesn't exist or is empty
initialize_data_file() {
    if [ ! -f "$DATA_FILE" ] || [ ! -s "$DATA_FILE" ]; then
        echo "{}" > "$DATA_FILE"
        print_status "Created/Initialized main data file: $DATA_FILE"
    fi
}

# Function to sync lists (admin, mod, blacklist, whitelist) from data.json
# This function is the bridge between our JSON database and the server's flat files.
sync_lists_from_json() {
    local admin_list_file="$LOG_DIR/adminlist.txt"
    local mod_list_file="$LOG_DIR/modlist.txt"
    local blacklist_file="$LOG_DIR/blacklist.txt"
    local whitelist_file="$LOG_DIR/whitelist.txt"
    
    local data=$(read_data)

    # Rebuild adminlist.txt
    {
        echo "Usernames in this file are admins."
        echo "$data" | jq -r 'to_entries[] | select(.value.rank == "ADMIN") | .key'
    } > "$admin_list_file"

    # Rebuild modlist.txt
    {
        echo "Usernames in this file are mods."
        echo "$data" | jq -r 'to_entries[] | select(.value.rank == "MOD") | .key'
    } > "$mod_list_file"

    # Rebuild blacklist.txt
    {
        echo "Usernames/Device IDs in this file are blacklisted."
        echo "$data" | jq -r 'to_entries[] | select(.value.blacklisted == true) | .key'
    } > "$blacklist_file"

    # Rebuild whitelist.txt
    {
        echo "Usernames in this file are whitelisted."
        echo "$data" | jq -r 'to_entries[] | select(.value.whitelisted == true) | .key'
    } > "$whitelist_file"

    print_status "Synchronized server list files from data.json"
}

# =============================================================================
# PLAYER DATA HELPERS (JSON-INTERACTIVE)
# =============================================================================

# Helper to get player name as a JSON key (always uppercase)
get_player_key() {
    echo "$1" | tr '[:lower:]' '[:upper:]'
}

# Check if a player exists in data.json
player_exists() {
    local player_key=$(get_player_key "$1")
    [ "$(read_data | jq --arg key "$player_key" 'has($key)')" = "true" ]
}

# Get a player's entire data object as a JSON string
get_player_data() {
    local player_key=$(get_player_key "$1")
    read_data | jq --arg key "$player_key" '.[$key]'
}

# Get a specific value from a player's data
# Usage: get_player_value "PlayerName" ".rank"
get_player_value() {
    local player_key=$(get_player_key "$1")
    local field_path="$2"
    read_data | jq -r --arg key "$player_key" '.[$key]'"$field_path"
}

# Create a new player entry in data.json
create_new_player() {
    local player_name="$1"
    local player_ip="$2"
    local player_key=$(get_player_key "$player_name")

    local new_player_json=$(jq -n \
        --arg ip "$player_ip" \
        '{
            "ips": [$ip],
            "password": "NONE",
            "rank": "NONE",
            "blacklisted": false,
            "whitelisted": false,
            "economy": 0,
            "ip_change_attempts": {"count": 0, "last_attempt": 0},
            "password_change_attempts": {"count": 0, "last_attempt": 0},
            "admin_offenses": {"count": 0, "last_offense": 0}
        }')

    local current_data=$(read_data)
    local updated_data=$(echo "$current_data" | jq --arg key "$player_key" --argjson value "$new_player_json" '.[$key] = $value')
    write_data "$updated_data"
    print_success "Registered new player in database: $player_name"
}

# Generic function to update a player's data field
# Usage: update_player_data "PlayerName" ".rank" '"ADMIN"' (note the extra quotes for JSON strings)
# Usage: update_player_data "PlayerName" ".economy" 100
# Usage: update_player_data "PlayerName" ".blacklisted" true
update_player_data() {
    local player_name="$1"
    local field_path="$2"
    local new_value_json="$3" # Must be a valid JSON value (e.g., '"string"', 123, true)
    local player_key=$(get_player_key "$player_name")

    if ! player_exists "$player_name"; then
        print_error "Cannot update non-existent player: $player_name"
        return 1
    fi

    local current_data=$(read_data)
    local updated_data=$(echo "$current_data" | jq --arg key "$player_key" --argjson value "$new_value_json" '.[$key]'"$field_path"' = $value')
    write_data "$updated_data"
    
    # If a critical field was changed, trigger a sync with the server's txt files
    if [[ "$field_path" == *".rank"* || "$field_path" == *".blacklisted"* || "$field_path" == *".whitelisted"* ]]; then
        sync_lists_from_json
    fi
}


# =============================================================================
# CORE ANTICHEAT & MANAGEMENT LOGIC
# =============================================================================

# Function to check if a player name is valid
is_valid_player_name() {
    [[ -n "$1" && ! "$1" =~ ^[[:space:]] && ! "$1" =~ [[:space:]]$ && "$1" =~ ^[a-zA-Z0-9_]+$ ]]
}

# Function to schedule clear and multiple messages
schedule_clear_and_messages() {
    local messages=("$@")
    screen -S "$SCREEN_SERVER" -p 0 -X stuff "/clear$(printf \\r)" 2>/dev/null
    (
        sleep 2
        for msg in "${messages[@]}"; do
            send_server_command "$SCREEN_SERVER" "$msg"
        done
    ) &
}

# Function to get current IP from server log
get_ip_by_name() {
    local name="$1"
    [ -z "$LOG_FILE" ] || [ ! -f "$LOG_FILE" ] && { echo "unknown"; return 1; }
    grep "Player Connected ${name}" "$LOG_FILE" | tail -1 | cut -d'|' -f2 | tr -d ' '
}

# --- All original functions are now refactored to use the JSON helpers ---

# Function to record an admin offense
record_admin_offense() {
    local admin_name="$1"
    local current_time=$(date +%s)
    
    if ! player_exists "$admin_name"; then return 0; fi

    local player_data=$(get_player_data "$admin_name")
    local current_offenses=$(echo "$player_data" | jq -r '.admin_offenses.count // 0')
    local last_offense_time=$(echo "$player_data" | jq -r '.admin_offenses.last_offense // 0')
    
    # Reset count if the last offense was more than 5 minutes ago
    [ $((current_time - last_offense_time)) -gt 300 ] && current_offenses=0
    current_offenses=$((current_offenses + 1))
    
    local new_offenses_json=$(jq -n --argjson count "$current_offenses" --argjson time "$current_time" '{"count": $count, "last_offense": $time}')
    
    update_player_data "$admin_name" ".admin_offenses" "$new_offenses_json"
    
    print_warning "Recorded offense #$current_offenses for admin $admin_name"
    return $current_offenses
}

# Function to clear admin offenses
clear_admin_offenses() {
    local admin_name="$1"
    if player_exists "$admin_name"; then
        update_player_data "$admin_name" ".admin_offenses" '{"count": 0, "last_offense": 0}'
    fi
}

# Function to handle unauthorized /admin or /mod commands by players
handle_unauthorized_command() {
    local player_name="$1" command="$2" target_player="$3"
    local player_rank=$(get_player_value "$player_name" ".rank")
    
    # Always undo the rank change immediately
    local command_type=""
    [[ "$command" == "/admin" ]] && command_type="admin"
    [[ "$command" == "/mod" ]] && command_type="mod"
    if [ -n "$command_type" ]; then
        send_server_command "$SCREEN_SERVER" "/un${command_type} $target_player"
        # Since this was an unauthorized command, ensure our DB is correct
        if player_exists "$target_player"; then
            update_player_data "$target_player" ".rank" '"NONE"'
        fi
    fi
    
    if [ "$player_rank" = "ADMIN" ]; then
        print_error "UNAUTHORIZED COMMAND: Admin $player_name attempted to use $command on $target_player"
        record_admin_offense "$player_name"
        local offense_count=$?

        case $offense_count in
            1) send_server_command "$SCREEN_SERVER" "$player_name, first warning! Only the console can assign ranks.";;
            2) send_server_command "$SCREEN_SERVER" "$player_name, second warning! One more offense will result in demotion.";;
            *)
                print_warning "THIRD OFFENSE: Demoting Admin $player_name to Mod"
                send_server_command "$SCREEN_SERVER" "/unadmin $player_name"
                send_server_command "$SCREEN_SERVER" "/mod $player_name"
                update_player_data "$player_name" ".rank" '"MOD"' # This will sync files
                clear_admin_offenses "$player_name"
                ;;
        esac
    else
        print_warning "Non-admin $player_name attempted to use $command on $target_player"
        send_server_command "$SCREEN_SERVER" "$player_name, you do not have permission to assign ranks."
    fi
}

# Function to check for username theft and manage new players
check_username_theft() {
    local player_name="$1" player_ip="$2"
    
    ! is_valid_player_name "$player_name" && return 0
    
    if player_exists "$player_name"; then
        # Player is registered, verify IP
        local player_data=$(get_player_data "$player_name")
        local registered_ip=$(echo "$player_data" | jq -r '.ips[0]') # Check against the primary IP
        local password=$(echo "$player_data" | jq -r '.password')

        if [ "$registered_ip" != "$player_ip" ]; then
            # IP MISMATCH
            if [ "$password" = "NONE" ]; then
                # No password set, update IP and warn player to set one
                print_warning "IP changed for $player_name (no password). Old: $registered_ip, New: $player_ip"
                update_player_data "$player_name" ".ips" "[\"$player_ip\"]"
                if [[ -z "${ip_mismatch_announced[$player_name]}" ]]; then
                    ip_mismatch_announced["$player_name"]=1
                    (
                        sleep 5
                        send_server_command "$SCREEN_SERVER" "WARNING: $player_name, your IP has changed."
                        send_server_command "$SCREEN_SERVER" "Set a password with !ip_psw PASSWORD PASSWORD to protect your account."
                    ) &
                fi
            else
                # Password is set, start grace period for verification
                if [[ -z "${ip_change_grace_periods[$player_name]}" ]]; then
                    print_warning "IP MISMATCH for $player_name. Starting verification grace period."
                    start_ip_change_grace_period "$player_name" "$player_ip"
                fi
            fi
        fi
    else
        # New player, create a record for them
        create_new_player "$player_name" "$player_ip"
        # Remind new player to set a password
        (
            sleep 5
            send_server_command "$SCREEN_SERVER" "Welcome, $player_name! Protect your account by setting a password."
            send_server_command "$SCREEN_SERVER" "Use: !ip_psw mypassword mypassword"
        ) &
    fi
}

# Function to handle password creation (!ip_psw)
handle_password_creation() {
    local player_name="$1" password="$2" confirm_password="$3" player_ip="$4"

    if ! player_exists "$player_name"; then
        create_new_player "$player_name" "$player_ip"
    fi

    local current_password=$(get_player_value "$player_name" ".password")
    if [ "$current_password" != "NONE" ]; then
        schedule_clear_and_messages "ERROR: $player_name, you already have a password." "Use !ip_psw_change OLD_PASS NEW_PASS to change it."
        return 1
    fi
    
    if [ ${#password} -lt 6 ]; then
        schedule_clear_and_messages "ERROR: $player_name, password must be at least 6 characters."
        return 1
    fi

    if [ "$password" != "$confirm_password" ]; then
        schedule_clear_and_messages "ERROR: $player_name, passwords do not match."
        return 1
    fi
    
    # Note the extra quotes to make it a valid JSON string
    update_player_data "$player_name" ".password" "\"$password\""
    schedule_clear_and_messages "SUCCESS: $player_name, your account password has been set."
}

# Add other functions like start_ip_change_grace_period, validate_ip_change, etc. here
# They need to be refactored to use get_player_data and update_player_data
# For brevity, I will show the refactored `validate_ip_change` as a key example.

validate_ip_change() {
    local player_name="$1" password_attempt="$2" current_ip="$3"
    
    if ! player_exists "$player_name"; then
        schedule_clear_and_messages "ERROR: $player_name, you are not registered. Cannot verify IP."
        return 1
    fi

    local correct_password=$(get_player_value "$player_name" ".password")
    
    if [ "$correct_password" != "$password_attempt" ]; then
        schedule_clear_and_messages "ERROR: $player_name, incorrect password for IP verification."
        # Here you could add logic to track failed attempts from `ip_change_attempts` in JSON
        return 1
    fi

    # Success! Update the primary IP.
    update_player_data "$player_name" ".ips" "[\"$current_ip\"]"
    
    # End grace period
    if [ -n "${grace_period_pids[$player_name]}" ]; then
        kill "${grace_period_pids[$player_name]}" 2>/dev/null
        unset grace_period_pids["$player_name"]
    fi
    unset ip_change_grace_periods["$player_name"]
    unset ip_change_pending_players["$player_name"]
    
    schedule_clear_and_messages "SUCCESS: $player_name, your new IP has been verified and updated!"
}

# ...(rest of the functions like handle_password_change, check_dangerous_activity, etc. must be refactored similarly)...

# Function to cleanup on script exit
cleanup() {
    print_status "Cleaning up anticheat..."
    # Kill all background jobs spawned by this script
    kill $(jobs -p) 2>/dev/null
    # Ensure lock file is removed
    [ -d "$DATA_LOCK_FILE" ] && rmdir "$DATA_LOCK_FILE"
    exit 0
}


# =============================================================================
# MAIN LOG MONITORING LOOP
# =============================================================================
monitor_log() {
    local log_file="$1"
    LOG_FILE="$log_file"
    
    initialize_data_file
    sync_lists_from_json # Initial sync on startup
    
    trap cleanup EXIT INT TERM
    
    print_header "STARTING ANTICHEAT SECURITY SYSTEM V2 (JSON)"
    print_status "Monitoring: $log_file"
    print_status "Data file: $DATA_FILE"
    print_header "SECURITY SYSTEM ACTIVE"
    
    tail -n 0 -F "$log_file" | while read -r line; do
        # --- PLAYER CONNECTION & IP VERIFICATION ---
        if [[ "$line" == *"Player Connected"* ]]; then
            player_name=$(echo "$line" | cut -d'|' -f1 | sed 's/.*Player Connected //')
            player_ip=$(echo "$line" | cut -d'|' -f2 | tr -d ' ')
            check_username_theft "$player_name" "$player_ip"
            continue
        fi

        # --- PLAYER DISCONNECTION ---
        if [[ "$line" == *"Player Disconnected"* ]]; then
            player_name=$(echo "$line" | cut -d'|' -f1 | sed 's/.*Player Disconnected //')
            # Clear runtime announcement trackers for the disconnected player
            unset ip_mismatch_announced["$player_name"]
            continue
        fi

        # --- CONSOLE COMMAND HANDLER ---
        if [[ "$line" == "CONSOLE: "* ]]; then
            command_line=${line#CONSOLE: }
            command=$(echo "$command_line" | awk '{print $1}')
            command_lower=$(echo "$command" | tr '[:upper:]' '[:lower:]')
            target_player=$(echo "$command_line" | awk '{print $2}')

            handle_console_command "$command_lower" "$target_player"
            continue
        fi

        # --- PLAYER CHAT & COMMANDS ---
        if [[ "$line" =~ ^[A-Z0-9_]+: ]]; then
            player_name="${line%%:*}"
            message="${line#*: }"
            player_ip=$(get_ip_by_name "$player_name") # Get current IP for commands

            # ...(handler for !ip_psw, !ip_change, etc. goes here)...
            # Example for !ip_psw
            if [[ "$message" == "!ip_psw "* ]]; then
                parts=($message)
                handle_password_creation "$player_name" "${parts[1]}" "${parts[2]}" "$player_ip"
            fi
            # Example for !ip_change
            if [[ "$message" == "!ip_change "* ]]; then
                parts=($message)
                validate_ip_change "$player_name" "${parts[1]}" "$player_ip"
            fi
        fi

        # --- ADMIN/MOD COMMAND ABUSE DETECTION ---
        if [[ "$line" == *": /admin "* || "$line" == *": /mod "* ]]; then
            player_name="${line%%:*}"
            command=$(echo "$line" | awk -F': ' '{print $2}' | awk '{print $1}')
            target_player=$(echo "$line" | awk -F': ' '{print $2}' | awk '{print $2}')
            handle_unauthorized_command "$player_name" "$command" "$target_player"
        fi
    done
}

# Function to process commands sent from the console
handle_console_command() {
    local command="$1"
    local target_player="$2"

    if [ -z "$target_player" ] && [[ "$command" != "/clear-"* ]]; then
        return
    fi
    
    print_info "Processing console command: $command $target_player"

    case "$command" in
        "/admin")      update_player_data "$target_player" ".rank" '"ADMIN"';;
        "/unadmin")    update_player_data "$target_player" ".rank" '"NONE"';;
        "/mod")        update_player_data "$target_player" ".rank" '"MOD"';;
        "/unmod")
            # Only demote if they are actually a mod
            if [ "$(get_player_value "$target_player" ".rank")" == "MOD" ]; then
                 update_player_data "$target_player" ".rank" '"NONE"'
            fi
            ;;
        "/ban"|"/ban-no-device") update_player_data "$target_player" ".blacklisted" "true";;
        "/unban")               update_player_data "$target_player" ".blacklisted" "false";;
        "/whitelist")           update_player_data "$target_player" ".whitelisted" "true";;
        "/unwhitelist")         update_player_data "$target_player" ".whitelisted" "false";;
        "/clear-adminlist")
            local data=$(read_data)
            local updated_data=$(echo "$data" | jq 'to_entries | map(if .value.rank == "ADMIN" then .value.rank = "NONE" else . end) | from_entries')
            write_data "$updated_data" && sync_lists_from_json
            ;;
        "/clear-modlist")
            local data=$(read_data)
            local updated_data=$(echo "$data" | jq 'to_entries | map(if .value.rank == "MOD" then .value.rank = "NONE" else . end) | from_entries')
            write_data "$updated_data" && sync_lists_from_json
            ;;
        "/clear-blacklist")
            local data=$(read_data)
            local updated_data=$(echo "$data" | jq 'map_values(.blacklisted = false)')
            write_data "$updated_data" && sync_lists_from_json
            ;;
        "/clear-whitelist")
            local data=$(read_data)
            local updated_data=$(echo "$data" | jq 'map_values(.whitelisted = false)')
            write_data "$updated_data" && sync_lists_from_json
            ;;
    esac
}


# =============================================================================
# SCRIPT EXECUTION
# =============================================================================
if [ -z "$1" ] || [ -z "$2" ]; then
    echo "Usage: $0 <path_to_log_file> <port>"
    exit 1
fi

monitor_log "$@"
