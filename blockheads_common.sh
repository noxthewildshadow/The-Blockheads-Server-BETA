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

# Function to check if player is super admin
is_super_admin() {
    local player_name="$1"
    local super_admin_file="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/superadminslist.txt"
    if [ ! -f "$super_admin_file" ]; then
        return 1
    fi
    grep -q -i "^[[:space:]]*$player_name[[:space:]]*$" "$super_admin_file"
}
