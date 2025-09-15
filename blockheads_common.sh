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
    
    # Create backup before reading
    local backup_file="${file_path}.bak.$(date +%s)"
    cp "$file_path" "$backup_file" 2>/dev/null || true
    
    # Read with locking
    flock -s 200 cat "$file_path" 200>"${file_path}.lock"
}

# Function to write JSON file with locking and atomic replace
write_json_file() {
    local file_path="$1" content="$2"
    [ ! -f "$file_path" ] && touch "$file_path"
    
    # Create backup
    local backup_file="${file_path}.bak.$(date +%s)"
    cp "$file_path" "$backfile_file" 2>/dev/null || true
    
    # Write with locking and atomic replace
    flock -x 200 echo "$content" > "${file_path}.tmp" 200>"${file_path}.lock"
    mv "${file_path}.tmp" "$file_path"
    
    # Remove old backups (keep last 5)
    ls -t "${file_path}.bak."* 2>/dev/null | tail -n +6 | xargs rm -f --
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
# DATA.JSON MANAGEMENT FUNCTIONS
# =============================================================================

# Function to initialize data.json
initialize_data_json() {
    local data_file="$1"
    [ ! -f "$data_file" ] && echo '{"players": {}, "transactions": []}' > "$data_file"
    sync_list_files "$data_file" "$(dirname "$data_file")"
}

# Function to sync list files from data.json
sync_list_files() {
    local data_file="$1"
    local log_dir="$2"
    
    [ ! -f "$data_file" ] && return

    # Sync adminlist
    jq -r '.players | to_entries[] | select(.value.rank == "admin") | .key' "$data_file" > "$log_dir/adminlist.txt" 2>/dev/null || true
    
    # Sync modlist
    jq -r '.players | to_entries[] | select(.value.rank == "mod") | .key' "$data_file" > "$log_dir/modlist.txt" 2>/dev/null || true
    
    # Sync blacklist
    jq -r '.players | to_entries[] | select(.value.blacklisted == "TRUE") | .key' "$data_file" > "$log_dir/blacklist.txt" 2>/dev/null || true
    
    # Sync whitelist
    jq -r '.players | to_entries[] | select(.value.whitelisted == "TRUE") | .key' "$data_file" > "$log_dir/whitelist.txt" 2>/dev/null || true
}

# Function to update player data in data.json
update_player_data() {
    local data_file="$1"
    local player="$2"
    local field="$3"
    local value="$4"
    
    local current_data=$(read_json_file "$data_file")
    current_data=$(echo "$current_data" | jq --arg player "$player" --arg field "$field" --arg value "$value" '
        .players[$player][$field] = $value
    ')
    write_json_file "$data_file" "$current_data"
    sync_list_files "$data_file" "$(dirname "$data_file")"
}

# Function to get player data from data.json
get_player_data() {
    local data_file="$1"
    local player="$2"
    local field="$3"
    
    read_json_file "$data_file" | jq -r --arg player "$player" --arg field "$field" '
        .players[$player][$field] // "NONE"
    '
}

# Function to update player info in data.json
update_player_info() {
    local data_file="$1"
    local player_name="$2"
    local player_ip="$3"
    local player_rank="$4"
    local player_password="$5"
    
    local current_data=$(read_json_file "$data_file")
    local player_exists=$(echo "$current_data" | jq --arg player "$player_name" '.players | has($player)')
    
    if [ "$player_exists" = "false" ]; then
        current_data=$(echo "$current_data" | jq --arg player "$player_name" \
            --arg ip "$player_ip" --arg rank "$player_rank" --arg password "$player_password" '
            .players[$player] = {
                "ip": $ip,
                "password": $password,
                "rank": $rank,
                "blacklisted": "NONE",
                "whitelisted": "NONE",
                "economy": {
                    "tickets": 0,
                    "last_login": 0,
                    "last_welcome_time": 0,
                    "last_help_time": 0,
                    "last_greeting_time": 0,
                    "purchases": []
                },
                "ip_change_attempts": {"count": 0, "last_attempt": 0},
                "password_change_attempts": {"count": 0, "last_attempt": 0},
                "admin_offenses": {"count": 0, "last_offense": 0}
            }
        ')
    else
        current_data=$(echo "$current_data" | jq --arg player "$player_name" \
            --arg ip "$player_ip" --arg rank "$player_rank" --arg password "$player_password" '
            .players[$player].ip = $ip |
            .players[$player].rank = $rank |
            .players[$player].password = $password
        ')
    fi
    
    write_json_file "$data_file" "$current_data"
    sync_list_files "$data_file" "$(dirname "$data_file")"
}

# Function to get player info from data.json
get_player_info() {
    local data_file="$1"
    local player_name="$2"
    
    local ip=$(get_player_data "$data_file" "$player_name" "ip")
    local rank=$(get_player_data "$data_file" "$player_name" "rank")
    local password=$(get_player_data "$data_file" "$player_name" "password")
    
    if [ "$ip" != "NONE" ]; then
        echo "$ip|$rank|$password"
        return 0
    fi
    
    echo ""
}

# Function to check if player is in list using data.json
is_player_in_list() {
    local data_file="$1"
    local player_name="$2"
    local list_type="$3"
    
    local value=$(get_player_data "$data_file" "$player_name" "$list_type")
    [ "$value" = "TRUE" ] && return 0
    
    # For backward compatibility with rank lists
    if [ "$list_type" = "admin" ] || [ "$list_type" = "mod" ]; then
        local rank=$(get_player_data "$data_file" "$player_name" "rank")
        [ "$rank" = "$list_type" ] && return 0
    fi
    
    return 1
}

# Function to record admin offense
record_admin_offense() {
    local data_file="$1"
    local admin_name="$2"
    local current_time=$(date +%s)
    
    local current_offenses=$(get_player_data "$data_file" "$admin_name" "admin_offenses.count")
    local last_offense_time=$(get_player_data "$data_file" "$admin_name" "admin_offenses.last_offense")
    
    [ "$current_offenses" = "NONE" ] && current_offenses=0
    [ "$last_offense_time" = "NONE" ] && last_offense_time=0
    
    [ $((current_time - last_offense_time)) -gt 300 ] && current_offenses=0
    current_offenses=$((current_offenses + 1))
    
    update_player_data "$data_file" "$admin_name" "admin_offenses.count" "$current_offenses"
    update_player_data "$data_file" "$admin_name" "admin_offenses.last_offense" "$current_time"
    
    print_warning "Recorded offense #$current_offenses for admin $admin_name"
    return $current_offenses
}

# Function to clear admin offenses
clear_admin_offenses() {
    local data_file="$1"
    local admin_name="$2"
    
    update_player_data "$data_file" "$admin_name" "admin_offenses.count" "0"
    update_player_data "$data_file" "$admin_name" "admin_offenses.last_offense" "0"
}

# Function to record IP change attempt
record_ip_change_attempt() {
    local data_file="$1"
    local player_name="$2"
    local current_time=$(date +%s)
    
    local current_attempts=$(get_player_data "$data_file" "$player_name" "ip_change_attempts.count")
    local last_attempt_time=$(get_player_data "$data_file" "$player_name" "ip_change_attempts.last_attempt")
    
    [ "$current_attempts" = "NONE" ] && current_attempts=0
    [ "$last_attempt_time" = "NONE" ] && last_attempt_time=0
    
    [ $((current_time - last_attempt_time)) -gt 3600 ] && current_attempts=0
    
    current_attempts=$((current_attempts + 1))
    
    update_player_data "$data_file" "$player_name" "ip_change_attempts.count" "$current_attempts"
    update_player_data "$data_file" "$player_name" "ip_change_attempts.last_attempt" "$current_time"
    
    return $current_attempts
}

# Function to record password change attempt
record_password_change_attempt() {
    local data_file="$1"
    local player_name="$2"
    local current_time=$(date +%s)
    
    local current_attempts=$(get_player_data "$data_file" "$player_name" "password_change_attempts.count")
    local last_attempt_time=$(get_player_data "$data_file" "$player_name" "password_change_attempts.last_attempt")
    
    [ "$current_attempts" = "NONE" ] && current_attempts=0
    [ "$last_attempt_time" = "NONE" ] && last_attempt_time=0
    
    [ $((current_time - last_attempt_time)) -gt 3600 ] && current_attempts=0
    
    current_attempts=$((current_attempts + 1))
    
    update_player_data "$data_file" "$player_name" "password_change_attempts.count" "$current_attempts"
    update_player_data "$data_file" "$player_name" "password_change_attempts.last_attempt" "$current_time"
    
    return $current_attempts
}
