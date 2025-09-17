#!/bin/bash
# =============================================================================
# BLOCKHEADS COMMON FUNCTIONS LIBRARY
# =============================================================================

# Color codes for output
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
print_step() { echo -e "${CYAN}[STEP]${NC} $1"; }

# Wget options for faster downloads
WGET_OPTIONS="--timeout=30 --tries=2 --dns-timeout=10 --connect-timeout=10 --read-timeout=30 -q"

# Function to validate player names
is_valid_player_name() {
    local player_name=$(echo "$1" | xargs)
    [[ "$player_name" =~ ^[a-zA-Z0-9_]{1,16}$ ]]
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

# Function to send server command
send_server_command() {
    local screen_session="$1" command="$2"
    if screen -S "$screen_session" -p 0 -X stuff "$command$(printf \\r)" 2>/dev/null; then
        print_success "Sent message to server: $command"
        return 0
    else
        print_error "Could not send message to server"
        return 1
    fi
}

# Function to check if screen session exists
screen_session_exists() {
    screen -list 2>/dev/null | grep -q "$1"
}

# Function to check if port is in use
is_port_in_use() {
    lsof -Pi ":$1" -sTCP:LISTEN -t >/dev/null
}

# Function to generate random alphanumeric password
generate_random_password() {
    local length=7
    tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$length"
}

# Function to sanitize input
sanitize_input() {
    local input="$1"
    echo "$input" | sed 's/[^a-zA-Z0-9_ ]//g'
}

# Rate limiting implementation
declare -A command_buckets
declare -A bucket_refill_times

check_rate_limit() {
    local player="$1"
    local current_time=$(date +%s)
    
    # Initialize bucket if missing or refill if needed
    if [[ -z "${command_buckets[$player]}" ]] || \
       [[ -z "${bucket_refill_times[$player]}" ]] || \
       (( current_time - bucket_refill_times[$player] >= 60 )); then
        command_buckets[$player]=5
        bucket_refill_times[$player]=$current_time
    fi
    
    if (( command_buckets[$player] > 0 )); then
        ((command_buckets[$player]--))
        return 0
    else
        return 1
    fi
}

# Function to acquire lock
acquire_lock() {
    local lock_file="$1"
    local timeout="${2:-10}"
    local start_time=$(date +%s)
    
    while [[ ! -f "$lock_file" ]] && (( $(date +%s) - start_time < timeout )); do
        (set -o noclobber; echo $$ > "$lock_file") 2>/dev/null && return 0
        sleep 0.1
    done
    
    return 1
}

# Function to release lock
release_lock() {
    local lock_file="$1"
    rm -f "$lock_file" 2>/dev/null
}

# Function to find library
find_library() {
    SEARCH=$1
    LIBRARY=$(ldconfig -p | grep -F "$SEARCH" -m 1 | awk '{print $NF}' | head -1)
    [ -z "$LIBRARY" ] && return 1
    printf '%s' "$LIBRARY"
}

# =============================================================================
# DATA.JSON FUNCTIONS
# =============================================================================

# Function to initialize data.json
initialize_data_json() {
    local data_file="$1"
    if [ ! -f "$data_file" ]; then
        echo '{"users": {}}' > "$data_file"
        print_success "Created new data.json file"
    fi
}

# Function to validate data.json schema
validate_data_json() {
    local data_file="$1"
    local temp_data
    
    # Check if file exists and is valid JSON
    if [ ! -f "$data_file" ]; then
        print_error "data.json does not exist"
        return 1
    fi
    
    if ! temp_data=$(read_json_file "$data_file"); then
        print_error "Failed to read data.json"
        return 1
    fi
    
    if ! jq -e . >/dev/null 2>&1 <<<"$temp_data"; then
        print_error "data.json contains invalid JSON"
        return 1
    fi
    
    # Check if users object exists
    if ! jq -e '.users' >/dev/null 2>&1 <<<"$temp_data"; then
        print_error "data.json missing users object"
        return 1
    fi
    
    return 0
}

# Function to restore from backup
restore_from_backup() {
    local data_file="$1"
    local backup_file
    
    for i in {1..3}; do
        backup_file="${data_file}.bak.$i"
        if [ -f "$backup_file" ] && validate_data_json "$backup_file"; then
            cp "$backup_file" "$data_file"
            print_success "Restored data.json from backup: $backup_file"
            return 0
        fi
    done
    
    print_error "No valid backup found, creating new data.json"
    echo '{"users": {}}' > "$data_file"
    return 1
}

# Function to rotate backups
rotate_backups() {
    local data_file="$1"
    
    # Remove oldest backup
    rm -f "${data_file}.bak.3" 2>/dev/null
    
    # Rotate backups
    for i in {2..1}; do
        if [ -f "${data_file}.bak.$i" ]; then
            mv "${data_file}.bak.$i" "${data_file}.bak.$((i+1))"
        fi
    done
    
    # Create new backup
    if [ -f "$data_file" ]; then
        cp "$data_file" "${data_file}.bak.1"
    fi
}

# Function to atomically write data.json
atomic_write_data_json() {
    local data_file="$1"
    local content="$2"
    local temp_file="${data_file}.tmp.$$"
    
    # Validate JSON before writing
    if ! jq -e . >/dev/null 2>&1 <<<"$content"; then
        print_error "Invalid JSON content, aborting write"
        return 1
    fi
    
    # Write to temporary file
    echo "$content" > "$temp_file"
    
    # Validate the written file
    if ! jq -e . >/dev/null 2>&1 <"$temp_file"; then
        print_error "Temporary file contains invalid JSON"
        rm -f "$temp_file"
        return 1
    fi
    
    # Rotate backups
    rotate_backups "$data_file"
    
    # Atomically replace the file
    if mv "$temp_file" "$data_file"; then
        print_success "Successfully updated data.json"
        return 0
    else
        print_error "Failed to replace data.json, restoring from backup"
        rm -f "$temp_file"
        restore_from_backup "$data_file"
        return 1
    fi
}

# Function to get user from data.json
get_user_data() {
    local data_file="$1"
    local username="$2"
    
    if ! validate_data_json "$data_file"; then
        print_error "data.json validation failed in get_user_data"
        echo "{}"
        return 1
    fi
    
    local data_content=$(read_json_file "$data_file")
    local user_data=$(echo "$data_content" | jq -r --arg user "$username" '.users[$user] // {}')
    echo "$user_data"
}

# Function to update user in data.json
update_user_data() {
    local data_file="$1"
    local username="$2"
    local updates="$3"
    
    if ! validate_data_json "$data_file"; then
        print_error "data.json validation failed in update_user_data"
        return 1
    fi
    
    local data_content=$(read_json_file "$data_file")
    local updated_data
    
    # Check if user exists
    local user_exists=$(echo "$data_content" | jq -r --arg user "$username" '.users | has($user)')
    
    if [ "$user_exists" = "true" ]; then
        # Update existing user
        updated_data=$(echo "$data_content" | jq --arg user "$username" --argjson updates "$updates" \
            '.users[$user] = (.users[$user] + $updates)')
    else
        # Create new user with default values
        local new_user=$(echo '{
            "username": "",
            "ip_first": "",
            "password": "NONE",
            "rank": "NONE",
            "blacklisted": false,
            "whitelisted": false,
            "economy": 0,
            "ip_change_attempts": 0,
            "password_change_attempts": 0,
            "admin_offenses": 0
        }' | jq --arg user "$username" --argjson updates "$updates" \
            '.username = $user | . + $updates')
        
        updated_data=$(echo "$data_content" | jq --arg user "$username" --argjson new_user "$new_user" \
            '.users[$user] = $new_user')
    fi
    
    # Atomically write the updated data
    if atomic_write_data_json "$data_file" "$updated_data"; then
        print_success "Updated user $username in data.json"
        return 0
    else
        print_error "Failed to update user $username in data.json"
        return 1
    fi
}

# Function to sync server files from data.json with command execution
sync_server_files() {
    local data_file="$1"
    local log_dir=$(dirname "$data_file")
    
    if ! validate_data_json "$data_file"; then
        print_error "data.json validation failed in sync_server_files"
        return 1
    fi
    
    local data_content=$(read_json_file "$data_file")
    
    # Create adminlist.txt and execute admin commands
    echo "# Usernames in this file will be granted admin privileges" > "${log_dir}/adminlist.txt"
    local admins=$(echo "$data_content" | jq -r '.users | to_entries[] | select(.value.rank == "admin") | .key')
    while IFS= read -r admin; do
        [ -n "$admin" ] && echo "$admin" >> "${log_dir}/adminlist.txt"
        # Execute admin command if not already admin
        screen -S "$SCREEN_SERVER" -p 0 -X stuff "/admin $admin$(printf \\r)" 2>/dev/null
    done <<< "$admins"
    
    # Create modlist.txt and execute mod commands
    echo "# Usernames in this file will be granted mod privileges" > "${log_dir}/modlist.txt"
    local mods=$(echo "$data_content" | jq -r '.users | to_entries[] | select(.value.rank == "mod") | .key')
    while IFS= read -r mod; do
        [ -n "$mod" ] && echo "$mod" >> "${log_dir}/modlist.txt"
        # Execute mod command if not already mod
        screen -S "$SCREEN_SERVER" -p 0 -X stuff "/mod $mod$(printf \\r)" 2>/dev/null
    done <<< "$mods"
    
    # Create blacklist.txt and execute ban commands
    echo "# Usernames in this file will be banned from the server" > "${log_dir}/blacklist.txt"
    local blacklisted=$(echo "$data_content" | jq -r '.users | to_entries[] | select(.value.blacklisted == true) | .key')
    while IFS= read -r banned; do
        [ -n "$banned" ] && echo "$banned" >> "${log_dir}/blacklist.txt"
        # Execute ban command if not already banned
        local ip=$(echo "$data_content" | jq -r --arg user "$banned" '.users[$user].ip_first // empty')
        if [ -n "$ip" ] && [ "$ip" != "unknown" ]; then
            screen -S "$SCREEN_SERVER" -p 0 -X stuff "/ban $ip$(printf \\r)" 2>/dev/null
        else
            screen -S "$SCREEN_SERVER" -p 0 -X stuff "/ban $banned$(printf \\r)" 2>/dev/null
        fi
    done <<< "$blacklisted"
    
    # Create whitelist.txt and execute whitelist commands
    echo "# Usernames in this file will be allowed to join the server" > "${log_dir}/whitelist.txt"
    local whitelisted=$(echo "$data_content" | jq -r '.users | to_entries[] | select(.value.whitelisted == true) | .key')
    while IFS= read -r allowed; do
        [ -n "$allowed" ] && echo "$allowed" >> "${log_dir}/whitelist.txt"
        # Execute whitelist command if not already whitelisted
        screen -S "$SCREEN_SERVER" -p 0 -X stuff "/whitelist $allowed$(printf \\r)" 2>/dev/null
    done <<< "$whitelisted"
    
    print_success "Synchronized server files and executed commands from data.json"
}

# Function to monitor data.json for changes and sync
monitor_data_changes() {
    local data_file="$1"
    local last_modified=$(stat -c %Y "$data_file" 2>/dev/null || stat -f %m "$data_file" 2>/dev/null)
    
    while true; do
        sleep 5
        local current_modified=$(stat -c %Y "$data_file" 2>/dev/null || stat -f %m "$data_file" 2>/dev/null)
        
        if [ "$current_modified" != "$last_modified" ]; then
            print_status "Detected changes in data.json, synchronizing..."
            sync_server_files "$data_file"
            last_modified="$current_modified"
        fi
    done
}

# Enhanced function to process server commands
process_server_command() {
    local data_file="$1"
    local command="$2"
    local target="$3"
    local issuer="$4"
    
    if ! validate_data_json "$data_file"; then
        print_error "data.json validation failed in process_server_command"
        return 1
    fi
    
    case "$command" in
        "/KICK")
            # Kick doesn't change data.json but we'll log it
            print_status "$issuer executed: $command $target"
            ;;
        "/BAN"|"/BAN-NO-DEVICE")
            update_user_data "$data_file" "$target" '{"blacklisted": true}'
            print_success "$issuer banned: $target"
            ;;
        "/UNBAN")
            update_user_data "$data_file" "$target" '{"blacklisted": false}'
            print_success "$issuer unbanned: $target"
            ;;
        "/WHITELIST")
            update_user_data "$data_file" "$target" '{"whitelisted": true}'
            print_success "$issuer whitelisted: $target"
            ;;
        "/UNWHITELIST")
            update_user_data "$data_file" "$target" '{"whitelisted": false}'
            print_success "$issuer unwhitelisted: $target"
            ;;
        "/MOD")
            update_user_data "$data_file" "$target" '{"rank": "mod"}'
            print_success "$issuer promoted to mod: $target"
            ;;
        "/UNMOD")
            update_user_data "$data_file" "$target" '{"rank": "NONE"}'
            print_success "$issuer demoted from mod: $target"
            ;;
        "/ADMIN")
            update_user_data "$data_file" "$target" '{"rank": "admin"}'
            print_success "$issuer promoted to admin: $target"
            ;;
        "/UNADMIN")
            update_user_data "$data_file" "$target" '{"rank": "NONE"}'
            print_success "$issuer demoted from admin: $target"
            ;;
        "/CLEAR-BLACKLIST")
            local data_content=$(read_json_file "$data_file")
            local updated_data=$(echo "$data_content" | jq '.users |= map_values(.blacklisted = false)')
            atomic_write_data_json "$data_file" "$updated_data"
            print_success "$issuer cleared blacklist"
            ;;
        "/CLEAR-WHITELIST")
            local data_content=$(read_json_file "$data_file")
            local updated_data=$(echo "$data_content" | jq '.users |= map_values(.whitelisted = false)')
            atomic_write_data_json "$data_file" "$updated_data"
            print_success "$issuer cleared whitelist"
            ;;
        "/CLEAR-MODLIST")
            local data_content=$(read_json_file "$data_file")
            local updated_data=$(echo "$data_content" | jq '.users |= map_values(if .rank == "mod" then .rank = "NONE" else . end)')
            atomic_write_data_json "$data_file" "$updated_data"
            print_success "$issuer cleared modlist"
            ;;
        "/CLEAR-ADMINLIST")
            local data_content=$(read_json_file "$data_file")
            local updated_data=$(echo "$data_content" | jq '.users |= map_values(if .rank == "admin" then .rank = "NONE" else . end)')
            atomic_write_data_json "$data_file" "$updated_data"
            print_success "$issuer cleared adminlist"
            ;;
        *)
            print_error "Unknown server command: $command"
            return 1
            ;;
    esac
    
    # Sync server files after modification
    sync_server_files "$data_file"
    return 0
}

# Function to find player by IP
find_player_by_ip() {
    local ip="$1"
    local data_file="$2"
    local data_content=$(read_json_file "$data_file")
    echo "$data_content" | jq -r --arg ip "$ip" '.users | to_entries[] | select(.value.ip_first == $ip) | .key'
}
