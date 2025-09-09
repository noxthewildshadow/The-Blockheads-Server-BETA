#!/bin/bash

# =============================================================================
# THE BLOCKHEADS ANTICHEAT SECURITY SYSTEM
# =============================================================================

# ASCII-only color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

print_status() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_header() {
    echo -e "================================================================"
    echo -e "$1"
    echo -e "================================================================"
}

# Check for jq
if ! command -v jq &> /dev/null; then
    echo -e "${RED}ERROR: jq is required but not installed. Install jq and retry.${NC}"
    exit 1
fi

# Arguments
LOG_FILE="$1"
PORT="$2"
LOG_DIR=$(dirname "$LOG_FILE")
SCREEN_SERVER="blockheads_server_${PORT:-12153}"

# Files for persistence
ADMIN_OFFENSES_FILE="$LOG_DIR/admin_offenses_${PORT:-12153}.json"
AUTHORIZED_ADMINS_FILE="$LOG_DIR/authorized_admins.txt"
AUTHORIZED_MODS_FILE="$LOG_DIR/authorized_mods.txt"
PLAYERS_LOG="$LOG_DIR/players.log"
TEMP_IP_BANS_FILE="$LOG_DIR/temp_ip_bans_${PORT:-12153}.json"

# In-memory maps for command spam detection
declare -A last_command_time
declare -A command_count

# -------------------------
# Helper: JSON file read/write with flock
# -------------------------
read_json_file() {
    local path="$1"
    if [ ! -f "$path" ]; then
        echo "{}"
        return 0
    fi
    # Use flock for safe concurrent reads
    exec 200<"$path"
    flock -s 200
    cat "$path"
    flock -u 200
    exec 200>&-
}

write_json_file() {
    local path="$1"
    local content="$2"
    touch "$path"
    exec 200>"${path}.lock"
    flock -x 200
    printf "%s" "$content" > "$path"
    flock -u 200
    exec 200>&-
}

# -------------------------
# Initialize files
# -------------------------
initialize_files() {
    [ -f "$AUTHORIZED_ADMINS_FILE" ] || touch "$AUTHORIZED_ADMINS_FILE"
    [ -f "$AUTHORIZED_MODS_FILE" ] || touch "$AUTHORIZED_MODS_FILE"
    [ -f "$PLAYERS_LOG" ] || touch "$PLAYERS_LOG"
    [ -f "$ADMIN_OFFENSES_FILE" ] || echo '{}' > "$ADMIN_OFFENSES_FILE"
    [ -f "$TEMP_IP_BANS_FILE" ] || echo '{}' > "$TEMP_IP_BANS_FILE"
}

# -------------------------
# Player name validation
# Allows letters numbers underscore, 1-16 chars
# -------------------------
is_valid_player_name() {
    local name="$1"
    name="$(echo "$name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    if [[ "$name" =~ ^[A-Za-z0-9_]{1,16}$ ]]; then
        return 0
    fi
    return 1
}

# -------------------------
# Update players.log rank
# Format in players.log: player|ip|rank
# -------------------------
update_player_rank() {
    local player="$1" new_rank="$2" player_ip="$3"
    # Remove any existing line for the player (case-insensitive)
    if [ -f "$PLAYERS_LOG" ]; then
        sed -i "/^${player}|/Id" "$PLAYERS_LOG"
    fi
    # Append new entry
    echo "${player}|${player_ip}|${new_rank}" >> "$PLAYERS_LOG"
    print_success "Updated players.log: ${player} -> ${new_rank}"
}

# -------------------------
# Admin offenses tracking
# Returns offense count via stdout
# -------------------------
record_admin_offense() {
    local admin="$1"
    local now
    now=$(date +%s)
    local content
    content=$(read_json_file "$ADMIN_OFFENSES_FILE")
    # get current count and last time
    local current_count
    current_count=$(echo "$content" | jq -r --arg a "$admin" '.[$a].count // 0')
    local last_time
    last_time=$(echo "$content" | jq -r --arg a "$admin" '.[$a].last_offense // 0')
    # reset if last offense older than 300s (5 minutes)
    if [ -z "$last_time" ] || [ "$((now - last_time))" -gt 300 ]; then
        current_count=0
    fi
    current_count=$((current_count + 1))
    content=$(echo "$content" | jq --arg a "$admin" --argjson c "$current_count" --argjson t "$now" '.[$a] = {"count": $c, "last_offense": $t}')
    write_json_file "$ADMIN_OFFENSES_FILE" "$content"
    print_warning "Recorded offense for admin ${admin}: count=${current_count}"
    printf "%d" "$current_count"
}

clear_admin_offenses() {
    local admin="$1"
    local content
    content=$(read_json_file "$ADMIN_OFFENSES_FILE")
    content=$(echo "$content" | jq --arg a "$admin" 'del(.[$a])')
    write_json_file "$ADMIN_OFFENSES_FILE" "$content"
}

# -------------------------
# Temporary IP bans (5 minutes or custom)
# Stored in TEMP_IP_BANS_FILE as { "ip": expiry_timestamp, ... }
# -------------------------
ban_ip_temp() {
    local ip="$1"
    local duration="$2" # seconds
    local reason="$3"
    [ -z "$duration" ] && duration=300
    local now expiry
    now=$(date +%s)
    expiry=$((now + duration))
    local content
    content=$(read_json_file "$TEMP_IP_BANS_FILE")
    content=$(echo "$content" | jq --arg ip "$ip" --argjson e "$expiry" '.[$ip] = $e')
    write_json_file "$TEMP_IP_BANS_FILE" "$content"
    # Issue server ban command (ban by IP)
    send_server_command "/ban $ip"
    print_warning "Temp banned IP $ip until $(date -d "@$expiry" '+%Y-%m-%d %H:%M:%S') reason: $reason"
    # Schedule unban in background
    (
        sleep "$duration"
        send_server_command "/unban $ip"
        # remove from file
        local c
        c=$(read_json_file "$TEMP_IP_BANS_FILE")
        c=$(echo "$c" | jq --arg ip "$ip" 'del(.[$ip])')
        write_json_file "$TEMP_IP_BANS_FILE" "$c"
        print_success "Temp ban expired and removed for IP $ip"
    ) &
}

is_ip_currently_banned() {
    local ip="$1"
    local now
    now=$(date +%s)
    local content expiry
    content=$(read_json_file "$TEMP_IP_BANS_FILE")
    expiry=$(echo "$content" | jq -r --arg ip "$ip" '.[$ip] // 0')
    if [ -n "$expiry" ] && [ "$expiry" -gt "$now" ]; then
        printf "%s" "$expiry"
        return 0
    fi
    return 1
}

# -------------------------
# Send server commands through screen
# -------------------------
send_server_command() {
    if screen -S "$SCREEN_SERVER" -p 0 -X stuff "$1$(printf \\r)" 2>/dev/null; then
        print_success "Sent to server: $1"
        return 0
    else
        print_error "Could not send to server: $1"
        return 1
    fi
}

send_server_command_silent() {
    screen -S "$SCREEN_SERVER" -p 0 -X stuff "$1$(printf \\r)" 2>/dev/null
}

# -------------------------
# Remove player from admin/mod list file helper
# -------------------------
remove_from_list_file() {
    local player="$1" type="$2" file="$LOG_DIR/${type}list.txt"
    [ ! -f "$file" ] && return 1
    # case-insensitive remove
    sed -i "/^${player}$/Id" "$file"
    return 0
}

# -------------------------
# Check if a player is in admin/mod list
# -------------------------
is_player_in_list_file() {
    local player="$1" type="$2" file="$LOG_DIR/${type}list.txt"
    [ -f "$file" ] && grep -v "^[[:space:]]*#" "$file" 2>/dev/null | grep -qi "^$player$"
}

# -------------------------
# Get player IP from log file (best-effort)
# -------------------------
get_ip_by_name() {
    local name="$1"
    if [ -z "$LOG_FILE" ] || [ ! -f "$LOG_FILE" ]; then
        echo "unknown"
        return 1
    fi
    # scan log for recent "Player Connected" lines mentioning the name
    awk -F'|' -v pname="$name" '
    /Player Connected/ {
        line=$0
        # try to split on | if log has that format
        if (index(line, "|") > 0) {
            # crude parse: take last field as ip if possible
            # fallback: print unknown
        }
    } END { print "unknown" }' "$LOG_FILE"
    # fallback unknown
    echo "unknown"
}

# -------------------------
# When an admin attempts an unauthorized /admin or /mod
# This function enforces warnings and demotion policy.
# It NEVER bans the target player.
# -------------------------
handle_unauthorized_command() {
    local actor="$1" command="$2" target="$3"
    local actor_ip
    actor_ip=$(get_ip_by_name "$actor")

    print_warning "UNAUTHORIZED COMMAND: ${actor} attempted ${command} on ${target}"
    # Notify server (friendly)
    send_server_command "WARNING: Admin ${actor} attempted unauthorized rank assignment!"

    # Ensure we do not ban the target. If the target had been added incorrectly, remove rank lines.
    if [ "$command" = "/admin" ]; then
        send_server_command_silent "/unadmin $target"
        remove_from_list_file "$target" "admin"
    elif [ "$command" = "/mod" ]; then
        send_server_command_silent "/unmod $target"
        remove_from_list_file "$target" "mod"
    fi

    # Record offense and get count (echoed)
    local offense_count
    offense_count=$(record_admin_offense "$actor")
    # offense_count is a number in stdout
    if [ "$offense_count" -eq 1 ]; then
        send_server_command "NOTICE: ${actor}, this is your FIRST warning. Only server console can assign ranks."
    elif [ "$offense_count" -eq 2 ]; then
        send_server_command "NOTICE: ${actor}, this is your SECOND warning. Stop attempting to assign ranks manually."
    else
        # Third or more: demote to mod
        print_warning "THIRD OFFENSE: Demoting admin ${actor} to mod"
        # Remove from authorized admins, add to authorized mods
        # Remove admin from authorized_admins.txt (case-insensitive)
        if grep -qi "^${actor}$" "$AUTHORIZED_ADMINS_FILE" 2>/dev/null; then
            sed -i "/^${actor}$/Id" "$AUTHORIZED_ADMINS_FILE"
        fi
        # Add to authorized_mods.txt if not present
        if ! grep -qi "^${actor}$" "$AUTHORIZED_MODS_FILE" 2>/dev/null; then
            echo "$actor" >> "$AUTHORIZED_MODS_FILE"
        fi
        # Send server commands to update live server
        send_server_command_silent "/unadmin $actor"
        send_server_command "/mod $actor"
        # Update players.log to reflect demotion
        update_player_rank "$actor" "mod" "$actor_ip"
        clear_admin_offenses "$actor"
        send_server_command "ALERT: Admin ${actor} has been demoted to moderator for repeated unauthorized rank assignments."
    fi
}

# -------------------------
# Check for spam of commands (messages starting with '/')
# If more than 1 command in 1 second -> temp ban IP for 5 minutes (300s)
# -------------------------
check_command_spam() {
    local player="$1"
    local message="$2"
    local now
    now=$(date +%s)
    # Only consider messages that start with '/'
    if [[ "$message" =~ ^/ ]]; then
        local last_time="${last_command_time[$player]:-0}"
        local count="${command_count[$player]:-0}"
        if [ "$((now - last_time))" -le 1 ]; then
            count=$((count + 1))
            command_count[$player]="$count"
            last_command_time[$player]="$now"
            if [ "$count" -gt 1 ]; then
                # Spam detected: ban IP for 5 minutes
                local player_ip
                player_ip=$(get_ip_by_name "$player")
                if [ -z "$player_ip" ] || [ "$player_ip" = "unknown" ]; then
                    print_warning "SPAM detected from $player but IP unknown. Not banning IP."
                else
                    print_error "SPAM DETECTED: $player sent $count commands in 1 second. Temp banning IP $player_ip"
                    ban_ip_temp "$player_ip" 300 "command spam by $player"
                    send_server_command "NOTICE: $player has been temporarily banned for command spam (5 minutes)."
                fi
            fi
        else
            # Reset counter
            last_command_time[$player]="$now"
            command_count[$player]=1
        fi
    fi
}

# -------------------------
# Check dangerous commands from ranked players (stop/shutdown etc.)
# If attempted, record admin offense; on 3rd offense demote.
# -------------------------
check_dangerous_activity() {
    local player="$1" message="$2"
    # Skip SERVER
    [ "$player" = "SERVER" ] && return 0
    # Only consider valid names
    ! is_valid_player_name "$player" && return 0

    # Check if IP is currently temp-banned; if so kick immediately
    local player_ip
    player_ip=$(get_ip_by_name "$player")
    if is_ip_currently_banned "$player_ip" >/dev/null 2>&1; then
        local expiry
        expiry=$(is_ip_currently_banned "$player_ip" 2>/dev/null || true)
        send_server_command "/kick $player"
        print_warning "Player $player (IP $player_ip) attempted action while temp-banned until $expiry. Kicked."
        return 1
    fi

    # Command spam detection (commands starting with '/')
    check_command_spam "$player" "$message"

    # Dangerous commands check (only for ranked players)
    local rank="NONE"
    if grep -qi "^${player}$" "$AUTHORIZED_ADMINS_FILE" 2>/dev/null; then
        rank="admin"
    elif grep -qi "^${player}$" "$AUTHORIZED_MODS_FILE" 2>/dev/null; then
        rank="mod"
    fi

    if [ "$rank" != "NONE" ]; then
        local dangerous_list="/stop /shutdown /restart /banall /kickall /op /deop /save-off"
        for cmd in $dangerous_list; do
            if [[ "$message" == "$cmd"* ]]; then
                print_error "DANGEROUS COMMAND ATTEMPT: $player ($rank) -> $message"
                local count
                count=$(record_admin_offense "$player")
                if [ "$count" -lt 3 ]; then
                    send_server_command "WARNING: $player, dangerous commands are restricted. Offense $count."
                else
                    # On 3rd offense demote
                    print_warning "Demoting $player to mod due to repeated dangerous commands"
                    if grep -qi "^${player}$" "$AUTHORIZED_ADMINS_FILE" 2>/dev/null; then
                        sed -i "/^${player}$/Id" "$AUTHORIZED_ADMINS_FILE"
                    fi
                    if ! grep -qi "^${player}$" "$AUTHORIZED_MODS_FILE" 2>/dev/null; then
                        echo "$player" >> "$AUTHORIZED_MODS_FILE"
                    fi
                    send_server_command_silent "/unadmin $player"
                    send_server_command "/mod $player"
                    update_player_rank "$player" "mod" "$player_ip"
                    clear_admin_offenses "$player"
                    send_server_command "ALERT: $player has been demoted to moderator for repeated dangerous attempts."
                fi
                return 1
            fi
        done
    fi

    return 0
}

# -------------------------
# Sanitize and extract a valid player name from arbitrary text
# Returns empty string if none found
# -------------------------
extract_valid_name() {
    local text="$1"
    if [[ "$text" =~ ([A-Za-z0-9_]{1,16}) ]]; then
        printf "%s" "${BASH_REMATCH[1]}"
    else
        printf ""
    fi
}

# -------------------------
# Log filter to reduce noise
# -------------------------
filter_server_log() {
    while read -r line; do
        # Skip some generic lines
        [[ "$line" == *"Server closed"* || "$line" == *"Starting server"* || "$line" == *"adminlist.txt"* || "$line" == *"modlist.txt"* ]] && continue
        echo "$line"
    done
}

# -------------------------
# Main monitor loop
# -------------------------
monitor_log() {
    local log_file="$1"
    LOG_FILE="$log_file"
    initialize_files

    print_header "ANTICHEAT SECURITY SYSTEM START"
    print_status "Monitoring: $log_file"
    print_status "Screen session: $SCREEN_SERVER"

    # Wait for log file
    local wait=0
    while [ ! -f "$log_file" ] && [ $wait -lt 30 ]; do
        sleep 1
        wait=$((wait + 1))
    done
    if [ ! -f "$log_file" ]; then
        print_error "Log file not found: $log_file"
        exit 1
    fi

    tail -n 0 -F "$log_file" 2>/dev/null | filter_server_log | while read -r line; do
        # Player Connected lines: try to parse "Player Connected NAME | IP | HASH" if available
        if [[ "$line" =~ Player\ Connected\ (.+)\ \|\ ([0-9a-fA-F.:]+)\ \|\ ([0-9a-f]+) ]]; then
            local pname="${BASH_REMATCH[1]}"
            local pip="${BASH_REMATCH[2]}"
            pname="$(echo "$pname" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
            # If IP is temp-banned, kick immediately
            if is_ip_currently_banned "$pip" >/dev/null 2>&1; then
                print_warning "Connection attempt from banned IP $pip for player $pname. Kicking."
                send_server_command "/kick $pname"
                continue
            fi
            # Add to players.log if new
            if ! grep -qi "^${pname}|" "$PLAYERS_LOG" 2>/dev/null; then
                # default rank NONE
                echo "${pname}|${pip}|NONE" >> "$PLAYERS_LOG"
                print_success "New player added to players.log: ${pname} (${pip})"
            fi
            print_success "Player connected: $pname (${pip})"
            continue
        fi

        # Admin rank command lines (handle both /admin and /mod)
        # Capture full rest of the line as target (to avoid malformed partial tokens)
        if [[ "$line" =~ ^([^:]+):\s*\/(admin|mod)\s+(.+)$ ]]; then
            local actor_raw="${BASH_REMATCH[1]}"
            local cmd="${BASH_REMATCH[2]}"
            local target_raw="${BASH_REMATCH[3]}"
            # Trim spaces
            actor_raw="$(echo "$actor_raw" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
            target_raw="$(echo "$target_raw" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
            # Extract valid player name from target_raw
            local target_name
            target_name=$(extract_valid_name "$target_raw")
            # If actor name is malformed, try to extract a valid name
            local actor_name
            actor_name=$(extract_valid_name "$actor_raw")
            if [ -z "$actor_name" ]; then
                # Actor name invalid - log and continue
                print_error "Malformed actor name in log: '$actor_raw' - ignoring"
                continue
            fi

            # If target was not found as a valid name, do NOT ban the target.
            # Treat as unauthorized attempt by actor.
            if [ -z "$target_name" ]; then
                print_warning "Actor $actor_name tried to assign rank to an invalid target: '$target_raw'. Recording offense."
                handle_unauthorized_command "$actor_name" "/${cmd}" "$target_raw"
                continue
            fi

            # If actor is SERVER skip
            [ "$actor_name" = "SERVER" ] && continue

            # If actor is not a real admin (not in authorized_admins) then treat as unauthorized
            if ! grep -qi "^${actor_name}$" "$AUTHORIZED_ADMINS_FILE" 2>/dev/null; then
                print_warning "Non-admin $actor_name attempted /${cmd} on $target_name"
                handle_unauthorized_command "$actor_name" "/${cmd}" "$target_name"
                continue
            fi

            # If actor is authorized admin but the assignment is not allowed by server policy (we want only console),
            # treat as unauthorized attempt by policy.
            print_warning "Authorized admin $actor_name attempted manual rank assignment /${cmd} on $target_name. Enforcing policy."
            handle_unauthorized_command "$actor_name" "/${cmd}" "$target_name"
            continue
        fi

        # Player disconnected
        if [[ "$line" =~ Player\ Disconnected\ (.+) ]]; then
            local pname="${BASH_REMATCH[1]}"
            pname="$(echo "$pname" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
            print_status "Player disconnected: $pname"
            continue
        fi

        # Chat or command messages like "NAME: message"
        if [[ "$line" =~ ^([A-Za-z0-9_]+):\ (.+)$ ]]; then
            local pname="${BASH_REMATCH[1]}"
            local msg="${BASH_REMATCH[2]}"
            # If IP is banned, kick on any activity
            local pip
            pip=$(get_ip_by_name "$pname")
            if is_ip_currently_banned "$pip" >/dev/null 2>&1; then
                print_warning "Player $pname (IP $pip) is temp-banned. Kicking on activity."
                send_server_command "/kick $pname"
                continue
            fi
            # Run checks: command spam and dangerous activity
            check_dangerous_activity "$pname" "$msg"
            continue
        fi

    done
}

# -------------------------
# Usage
# -------------------------
show_usage() {
    print_header "ANTICHEAT - USAGE"
    print_status "Usage: $0 <server_log_file> [port]"
    print_status "Example: $0 /path/to/console.log 12153"
}

# Main
if [ $# -lt 1 ]; then
    show_usage
    exit 1
fi

monitor_log "$1"
