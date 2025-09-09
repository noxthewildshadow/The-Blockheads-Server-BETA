#!/bin/bash

# =============================================================================
# THE BLOCKHEADS ANTICHEAT SECURITY SYSTEM
# Formato players.log: NOMBRE_USUARIO | PRIMERA_IP_DEL_NOMBRE | RANGO
# Uso: ./anticheat.sh /ruta/a/console.log [port]
# Requisitos: bash >= 4, jq
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

# Output helpers
print_status() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_header() {
    echo -e "${PURPLE}================================================================"
    echo -e "$1"
    echo -e "===============================================================${NC}"
}

# Require jq for JSON admin_offenses persistence
if ! command -v jq &> /dev/null; then
    echo -e "${RED}ERROR: jq is required but not installed. Please install jq first.${NC}"
    exit 1
fi

# Init variables
LOG_FILE="$1"
PORT="$2"
LOG_DIR=$(dirname "$LOG_FILE")
ADMIN_OFFENSES_FILE="$LOG_DIR/admin_offenses_${PORT:-default}.json"
AUTHORIZED_ADMINS_FILE="$LOG_DIR/authorized_admins.txt"
AUTHORIZED_MODS_FILE="$LOG_DIR/authorized_mods.txt"
PLAYERS_LOG="$LOG_DIR/players.log"
ANTICHEAT_ACTIONS_LOG="$LOG_DIR/anticheat_actions.log"
SCREEN_SERVER="blockheads_server_${PORT:-default}"

# Spam detection structures (in-memory)
declare -A player_message_timestamps

# Config
SPAM_TIME_WINDOW=3      # 3 second window for spam detection
SPAM_MESSAGE_LIMIT=3    # Max messages allowed in the time window

# Validate player names: only A-Z a-z 0-9 and underscore, 1-16 chars
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

# Log acciones del anticheat
log_anticheat_action() {
    local action="$1"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $action" >> "$ANTICHEAT_ACTIONS_LOG"
}

# Handle invalid player names (temporary ban)
handle_invalid_player_name() {
    local player_name="$1" player_ip="$2" player_hash="$3"
    print_warning "Invalid player name detected: '$player_name' (IP: $player_ip)"
    log_anticheat_action "INVALID PLAYER NAME: '$player_name' (IP: $player_ip, Hash: $player_hash)"

    send_server_command "WARNING: Invalid player name '$player_name'! You will be banned temporarily."

    if [ -n "$player_ip" ] && [ "$player_ip" != "unknown" ]; then
        send_server_command "/ban $player_ip"
        log_anticheat_action "BANNED IP: $player_ip for invalid player name: $player_name"
        (
            sleep 5
            send_server_command "/unban $player_ip"
            log_anticheat_action "UNBANNED IP: $player_ip after 5 seconds"
        ) &
    else
        send_server_command "/ban $player_name"
        log_anticheat_action "BANNED NAME: $player_name for invalid player name"
    fi
    return 0
}

# JSON read/write with flock (safe)
read_json_file() {
    local file="$1"
    [ ! -f "$file" ] && echo '{}' > "$file"
    ( flock -s 200; cat "$file" ) 200>"${file}.lock"
}
write_json_file() {
    local file="$1" content="$2"
    [ ! -f "$file" ] && touch "$file"
    ( flock -x 200; printf '%s' "$content" > "$file" ) 200>"${file}.lock"
}

# Initialize auth files and players log
initialize_authorization_files() {
    [ ! -f "$AUTHORIZED_ADMINS_FILE" ] && touch "$AUTHORIZED_ADMINS_FILE"
    [ ! -f "$AUTHORIZED_MODS_FILE" ] && touch "$AUTHORIZED_MODS_FILE"
    [ ! -f "$PLAYERS_LOG" ] && touch "$PLAYERS_LOG"
    [ ! -f "$ANTICHEAT_ACTIONS_LOG" ] && touch "$ANTICHEAT_ACTIONS_LOG"
}

# Get player's declared rank (admin/mod/NONE)
get_player_rank() {
    local player_name="$1"
    if [ -f "$AUTHORIZED_ADMINS_FILE" ] && grep -q -i -x "$player_name" "$AUTHORIZED_ADMINS_FILE" 2>/dev/null; then
        echo "admin"
    elif [ -f "$AUTHORIZED_MODS_FILE" ] && grep -q -i -x "$player_name" "$AUTHORIZED_MODS_FILE" 2>/dev/null; then
        echo "mod"
    else
        echo "NONE"
    fi
}

# Check username theft: 0 ok, 1 regular (ban ip), 2 critical (stop + ban ip)
check_username_theft() {
    local player_name="$1" player_ip="$2"
    local stored_entry
    stored_entry=$(awk -F'|' -v name="$player_name" '
    BEGIN { IGNORECASE = 1 }
    {
        n=$1; gsub(/^[ \t]+|[ \t]+$/, "", n)
        if (n == name) { print $0; exit }
    }' "$PLAYERS_LOG" 2>/dev/null || true)

    if [ -n "$stored_entry" ]; then
        local stored_ip stored_rank
        stored_ip=$(echo "$stored_entry" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2}')
        stored_rank=$(echo "$stored_entry" | awk -极'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$3); print $3}')
        if [ "$stored_ip" != "$player_ip" ]; then
            if [ "$stored_rank" != "NONE" ]; then
                print_error "CRITICAL: Username theft detected! $player_name ($stored_rank) from IP $player_ip (expected: $stored_ip)"
                log_anticheat_action "CRITICAL USERNAME THEFT: $player_name ($stored_rank) from IP $player_ip (expected: $stored_ip)"
                send_server_command "/stop"
                send_server_command "/ban $player_ip"
                print_error "Server stopped and IP $player_ip banned due to username theft attempt on ranked account!"
                return 2
            else
                print_warning "Username theft detected! $player_name from IP $player_ip (expected: $stored_ip)"
                log_anticheat_action "USERNAME THEFT: $player_name from IP $player_ip (expected: $stored_ip)"
                send_server_command "/ban $player_ip"
                print_warning "IP $player_ip banned due to username theft attempt!"
                return 1
            fi
        fi
    fi
    return 0
}

# Update players.log atomically; always use "NAME | IP | RANK"
update_players_log() {
    local player_name="$1" player_ip="$2"
    (
        flock -x 200

        # ensure consistent format: trim fields when writing
        local player_rank
        player_rank=$(get_player_rank "$player_name")
        [ -z "$player_rank" ] && player_rank="NONE"

        # check existence (case-insensitive) using awk
        local exists
        exists=$(awk -F'|' -v name="$player_name" '
        BEGIN { IGNORECASE = 1; found = 0 }
        {
            n = $1; gsub(/^[ \t]+|[ \t]+$/, "", n)
            if (n == name) { found = 1; exit }
        }
        END { print found }' "$PLAYERS_LOG" 2>/dev/null || echo 0)

        if [ "$exists" -eq 1 ]; then
            # update first matching line
            awk -F'|' -v name="$player_name" -v ip="$player_ip" -极 rank="$player_rank" '
            BEGIN { IGNORECASE = 1; OFS = " | " }
            {
                n = $1; gsub(/^[ \t]+|[ \t]+$/, "", n)
                if (n == name && !printed) {
                    print name, ip, rank
                    printed = 1
                } else {
                    # print normalized fields to keep format consistent
                    f1 = $1; f2 = $2; f3 = $3
                    gsub(/^[ \t]+|[ \t]+$/, "", f1); gsub(/^[ \t]+|[ \t]+$/, "", f2); gsub(/^[ \t]+|[ \t]+$/, "", f3)
                    if (f1 == "") next
                    print f1, f2, f3
                }
            }' "$PLAYERS_LOG" > "${PLAYERS_LOG}.tmp" && mv "${PLAYERS_LOG}.tmp" "$PLAYERS_LOG"
        else
            # add new player guaranteed with spaces around |
            echo "${player_name} | ${player_ip} | ${player_rank}" >> "$PLAYERS_LOG"
        fi
    ) 200>"${PLAYERS_LOG}.lock"
}

# Sync authorized lists (source of truth: adminlist.txt / modlist.txt -> authorized_ files)
validate_authorization() {
    local admin_list="$LOG_DIR/adminlist.txt"
    local mod_list="$LOG_DIR/modlist.txt"

    if [ -f "$admin_list" ]; then
        while IFS= read -r admin || [ -n "$admin" ]; do
            admin=$(echo "$admin" | sed '极/^[[:space:]]*//;s/[[:space:]]*$//')
            [[ -z "$admin" || "$admin" =~ ^# ]] && continue
            if ! grep -q -i -x "$admin" "$AUTHORIZED_ADMINS_FILE"; then
                echo "$admin" >> "$AUTHORIZED_ADMINS_FILE"
            fi
        done < <(grep -v "^[[:space:]]*#" "$admin_list" 2>/dev/null || true)
    fi

    if [ -f "$mod_list" ]; then
        while IFS= read -r mod || [ -n "$mod" ]; do
            mod=$(echo "$mod" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [[ -z "$mod" || "$mod" =~ ^# ]] && continue
            if ! grep -q -i -x "$mod" "$AUTHORIZED_MODS_FILE"; then
                echo "$mod" >> "$AUTHORIZED_MODS_FILE"
            fi
        done < <(grep -v "^[[:space:]]*#" "$mod_list" 2>/dev/null || true)
    fi

    # Deduplicate and sort normalized files
    [ -f "$AUTHORIZED_ADMINS_FILE" ] && sort -fu "$AUTHORIZED_ADMINS_FILE" -o "$AUTHORIZED_ADMINS_FILE"
    [ -f "$AUTHORIZED_MODS_FILE" ] && sort -fu "$AUTHORIZED_MODS_FILE" -o "$AUTHORIZED_MODS_FILE"
}

# Admin offense persistence
initialize_admin_offenses() {
    [ ! -f "$ADMIN_OFFENSES_FILE极"] && echo '{}' > "$ADMIN_OFFENSES_FILE"
}
record_admin_offense() {
    local admin_name="$1"
    local current_time
    current_time=$(date +%s)
    local offenses_data
    offenses_data=$(read_json_file "$ADMIN_OFFENSES_FILE")
    local current_offenses
    current_offenses=$(echo "$offenses_data" | jq -r --arg admin "$admin_name" '.[$admin]?.count // 0')
    local last_offense_time
    last_offense_time=$(echo "$offenses_data" | jq -r --arg admin "$admin_name" '.[$admin]?.last_offense // 0')
    if [ $((current_time - last_offense_time)) -gt 300 ]; then
        current_offenses=0
    fi
    current_offenses=$((current_offenses + 1))
    offenses_data=$(echo "$offenses_data" | jq --arg admin "$admin_name" --argjson count "$current_offenses" --argjson time "$current_time" '.[$admin] = {"count": $count, "last_offense": $time}')
    write_json_file "$ADMIN_OFFENSES_FILE" "$offenses_data"
    log_anticheat_action "ADMIN OFFENSE: $admin_name - count: $current_offenses"
    echo "$current_offenses"
}
clear_admin_offenses() {
    local admin_name="$1"
    local offenses_data
    offenses_data=$(read_json_file "$ADMIN极OFFENSES_FILE")
    offenses_data=$(echo "$offenses_data" | jq --arg admin "$admin_name" 'del(.[$admin])')
    write_json_file "$ADMIN_OFFENSES_FILE" "$offenses_data"
    log_anticheat_action "CLEARED OFFENSES: $admin_name"
}

# Improved screen session check: look for ".sessionname" in screen -ls output
screen_session_exists() {
    local session="$1"
    screen -ls 2>/dev/null | grep -qE "\.${session}(\s|\)|$)"
}

# Send server commands
send_server_command() {
    if screen_session_exists "$SCREEN_SERVER"; then
        if screen -S "$SCREEN_SERVER" -p 0 -X stuff "$1$(printf \\r)" 2>/dev/null; then
            return 0
        else
            return 1
        fi
    else
        return 1
    fi
}

# Resolve IP by name: prefer players.log (case-insensitive), fallback to console log
get_ip_by_name() {
    local name="$1"
    if [ -f "$PLAYERS_LOG" ]; then
        local ip_from_log
        ip_from_log=$(awk -F'|' -v name="$name" 'BEGIN{IGNORECASE=1} {n=$1; gsub(/^[ \t]+|[ \t]+$/,"",n); if(n==name){ ip=$2; gsub(/^[ \t]+|[ \t]+$/,"",ip); print ip; exit}}' "$PLAYERS_LOG" 2>/dev/null || true)
        if [ -n "$ip_from_log" ] && [ "$ip_from_log" != "unknown" ]; then
            echo "$ip_from_log"
            return 0
        fi
    fi
    if [ -z "$LOG_FILE" ] || [ ! -f "$LOG_FILE" ]; then
        echo "unknown"; return 1
    fi
    awk -F'|' -v pname="$name" 'BEGIN{IGNORECASE=1} /Player Connected/ { part=$1; sub(/.*Player Connected[[:space:]]*/,"",part); gsub(/^[ \t]+|[ \t]+$/,"",part); ip=$2; gsub(/^[ \t]+|[ \t]+$/,"",ip); if(part==pname) last_ip=ip } END{ if(last_ip) print last_ip; else print "unknown" }' "$LOG_FILE"
}

# Ban by IP when possible
ban_player() {
    local player_name="$1" reason="$2"
    local player_ip
    player_ip=$(get_ip_by_name "$player_name")
    if [ -n "$player_ip" ] && [ "$player_ip" != "unknown" ]; then
        send_server_command "/ban $player_ip"
        print_success "Banned IP $player_ip for: $reason"
        log_anticheat_action "BANNED IP: $player_ip ($player_name) for: $reason"
    else
        send_server_command "/ban $player_name"
        print_success "Banned player $player_name for: $reason"
        log_anticheat_action "BANNED NAME: $player_name for: $reason"
    fi
}

# Handle unauthorized command
handle_unauthorized_command() {
    local player_name="$1" command="$2" target="$3"
    local player_ip
    player_ip=$(get_ip_by_name "$player_name")
    print_error "UNAUTHORIZED COMMAND: $player_name attempted $command $target"
    log_anticheat_action "UNAUTHORIZED COMMAND: $player_name ($player_ip) attempted $command $target"
    ban_player "$player_name" "attempting unauthorized command: $command $target"
}

# Detect spam & dangerous commands (returns 0 OK, non-zero if action taken)
detect_spam_and_dangerous_commands() {
    local line="$1"
    if [[ "$line" =~ ^([A-Za-z0-9_]{1,16}):[[:space:]]*(.+)$ ]]; then
        local player_name="${BASH_REMATCH[1]}" message="${BASH_REMATCH[2]}"
        player_name=$(echo "$player_name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        ! is_valid_player_name "$player_name" && return 0
        
        local current_time
        current_time=$(date +%s)
        
        # Initialize or update message timestamps for this player
        if [ -z "${player_message_timestamps[$player_name]}" ]; then
            player_message_timestamps["$player_name"]=$current_time
        else
            # Clean up old timestamps outside our window
            local timestamps=(${player_message_timestamps[$player_name]})
            local new_timestamps=()
            for ts in "${timestamps[@]}"; do
                if [ $((current_time - ts)) -le $SPAM_TIME_WINDOW ]; then
                    new_timestamps+=("$ts")
                fi
            done
            new_timestamps+=("$current_time")
            player_message_timestamps["$player_name"]="${new_timestamps[*]}"
            
            # Check if over limit
            if [ ${#new_timestamps[@]} -ge $SPAM_MESSAGE_LIMIT ]; then
                print_error "SPAM DETECTED: $player_name sent ${#new_timestamps[@]} messages in $SPAM_TIME_WINDOW seconds"
                ban_player "$player_name" "spamming the chat"
                send_server_command "WARNING: $player_name has been banned for spamming the chat!"
                # Reset timestamps after ban
                unset player_message_timestamps["$player_name"]
                return 1
            fi
        fi

        # Dangerous commands (includes admin/mod)
        if [[ "$message" =~ ^\/(stop|shutdown|restart|reload|admin|mod)\b ]]; then
            local player_rank ip offense_count
            player_rank=$(get_player_rank "$player_name")
            ip=$(get_ip_by_name "$player_name")
            print_error "DANGEROUS COMMAND ATTEMPT: $player_name attempted: $message (rank: $player_rank, ip: $ip)"
            if [ "$player_rank" != "NONE" ]; then
                offense_count=$(record_admin_offense "$player_name")
                if [ "$offense_count" -ge 2 ]; then
                    if [ -n "$ip" ] && [ "$ip" != "unknown" ]; then
                        send_server_command "/ban $ip"
                        send_server_command "WARNING: $player_name ($player_rank) has been banned for repeated dangerous commands (IP: $ip)!"
                        log_anticheat_action "BANNED RANKED: $player_name ($player_rank) IP:$ip for repeated dangerous commands"
                    else
                        send_server_command "/ban $player_name"
                    fi
                    clear_admin_offenses "$player_name"
                    return 1
                else
                    send_server_command "$player_name, this is your first warning! Do not use dangerous server commands from chat."
                    return 0
                fi
            else
                if [ -n "$ip" ] && [ "$ip" != "unknown" ]; then
                    send_server_command "/ban $ip"
                    send_server_command "WARNING: $player_name has been banned for attempting dangerous command (IP: $ip)!"
                    log_anticheat_action "BANNED NON-RANKED: $player_name IP:$ip for dangerous command: $message"
                else
                    send_server_command "/ban $player_name"
                fi
                return 1
            fi
        fi
    fi
    return 0
}

# Filter server log lines we don't want to process
filter_server_log() {
    while read -r line; do
        # skip some known noise
        if [[ "$line" == *"Server closed"* || "$line" == *"Starting server"* || "$line" == *"adminlist.txt"* || "$line" == *"modlist.txt"* ]]; then
            continue
        fi
        # skip server welcome messages "SERVER: say" that include "Welcome"
        if [[ "$line" == *"SERVER: say"* && "$line" == *"Welcome"* ]]; then
            continue
        fi
        echo "$line"
    done
}

# Cleanup on exit
cleanup() {
    print_status "Cleaning up anticheat..."
    kill $(jobs -p) 2>/dev/null
    rm -f "${ADMIN_OFFENSES_FILE}.lock" "${PLAYERS_LOG}.lock" "${AUTHORIZED_ADMINS_FILE}.lock" "${AUTHORIZED_MODS_FILE}.lock" 2>/dev/null
    exit 0
}

# Main monitoring loop
monitor_log() {
    local log_file="$1"
    LOG_FILE="$log_file"
    initialize_authorization_files
    initialize_admin_offenses

    # Background periodic validation
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
    print_status "Port: ${PORT:-(none)}"
    print_status "Log directory: $LOG_DIR"
    print_status "Spam threshold: $SPAM_MESSAGE_LIMIT messages per $SPAM_TIME_WINDOW seconds"
    print_header "SECURITY SYSTEM ACTIVE"

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

    # Use process substitution to avoid subshell for while-loop
    while read -r line; do
        # If detect did action, skip further processing of this line
        if ! detect_spam_and_dangerous_commands "$line"; then
            continue
        fi

        # Player Connected
        if [[ "$line" == *"Player Connected"* ]]; then
            local player_name player_ip player_hash theft_rc
            player_name=$(echo "$line" | awk -F'|' '{print $1}' | sed 's/.*Player Connected[[:space:]]*//; s/^[[:space:]]*//; s/[[:space:]]*$//')
            player_ip=$(echo "$line" | awk -F'|' '{print $2}' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
            player_hash=$(echo "$line" | awk -F'|' '{if (NF >= 3) print $3; else print ""}' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')

            if [[ "$player_name" == *\\* || "$player_name" == */* ]]; then
                handle_invalid_player_name "$player_name" "$player_ip" "$player_hash"
                continue
            fi
            if ! is_valid_player_name "$player_name"; then
                handle_invalid_player_name "$player_name" "$player_ip" "$player_hash"
                continue
            fi

            check_username_theft "$player_name" "$player_ip"
            theft_rc=$?
            if [ "$theft_rc" -eq 2 ]; then
                print_error "Critical username theft handled; stopping anticheat monitoring loop."
                break
            elif [ "$theft_rc" -eq 1 ]; then
                continue
            fi

            update_players_log "$player_name" "$player_ip"
            print_success "Player connected: $player_name (IP: $player_ip)"
        fi

        # Rank-change commands in chat: "USER: /admin TARGET" or "USER: /mod TARGET"
        if [[ "$line" =~ ^([^:]+):[[:space:]]*\/(admin|mod)[[:space:]]+([^[:space:]]+) ]]; then
            local command_user command_type target_player ipu ipt
            command_user=$(echo "${BASH_REMATCH[1]}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            command_type="${BASH_REMATCH[2]}"
            target_player=$(echo "${BASH_REMATCH[3]}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

            if [[ "$command_user" == *\\* || "$command_user" == */* ]]; then
                ipu=$(get_ip_by_name "$command_user")
                handle_invalid_player_name "$command_user" "$ip极" ""
                continue
            fi
            if [[ "$target_player" == *\\* || "$target_player" == */* ]]; then
                ipt=$(get_ip_by_name "$target_player")
                handle_invalid_player_name "$target_player" "$ipt" ""
                continue
            fi
            if ! is_valid_player_name "$command_user"; then
                ipu=$(get_ip_by_name "$command_user")
                handle_invalid_player_name "$command_user" "$ipu" ""
                continue
            fi
            if ! is_valid_player_name "$target_player"; then
                ipt=$(get_ip_by_name "$target_player")
                handle_invalid_player_name "$target_player" "$ipt" ""
                continue
            fi

            [ "$command_user" != "SERVER" ] && handle_unauthorized_command "$command_user" "/$command_type" "$target_player"
        fi

        # Player Disconnected
        if [[ "$line" == *"Player Disconnected"* ]]; then
            local pname
            pname=$(echo "$line" | sed 's/.*Player Disconnected[[:space:]]*//; s/^[[:space:]]*//; s/[[:space:]]*$//')
            if [[ "$pname" == *\\* || "$pname" == */* ]]; then
                print_warning "Player with invalid name disconnected: $pname"
                continue
            fi
            if is_valid_player_name "$pname"; then
                print_warning "Player disconnected: $pname"
            else
                print_warning "Player with invalid name disconnected: $pname"
            fi
        fi

    done < <(tail -n 0 -F "$log_file" 2>/dev/null | filter_server_log)

    kill $validation_pid 2>/dev/null
}

# Usage
show_usage() {
    print_header "ANTICHEAT SECURITY SYSTEM - USAGE"
    print_status "Usage: $0 <server_log_file> [port]"
    print_status "Example: $0 /path/to/console.log 12153"
    echo ""
    print_warning "Note: This script should be run alongside the server"
}

# Main
if [ $# -lt 1 ]; then
    show_usage
    exit 1
fi

if [ $# -eq 1 ] || [ $# -eq 2 ]; then
    if [ ! -f "$LOG_FILE" ]; then
        print_status "Log file not found: $LOG_FILE"
        print_status "Waiting for log file to be created..."
        wait_time=0
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
