#!/bin/bash

# =============================================================================
# THE BLOCKHEADS SERVER ECONOMY BOT
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

# Check jq
if ! command -v jq &> /dev/null; then
    echo -e "${RED}ERROR: jq is required but not installed. Install jq and retry.${NC}"
    exit 1
fi

# Arguments
LOG_FILE="$1"
PORT="${2:-12153}"
LOG_DIR=$(dirname "$LOG_FILE")
ECONOMY_FILE="$LOG_DIR/economy_data_${PORT}.json"
SCREEN_SERVER="blockheads_server_${PORT}"
AUTHORIZED_ADMINS_FILE="$LOG_DIR/authorized_admins.txt"
AUTHORIZED_MODS_FILE="$LOG_DIR/authorized_mods.txt"

# Simple JSON file read/write (with basic lock)
read_json_file() {
    local path="$1"
    [ ! -f "$path" ] && echo "{}" && return 0
    exec 200<"$path"
    flock -s 200
    cat "$path"
    flock -u 200
    exec 200>&-
}

write_json_file() {
    local path="$1" content="$2"
    touch "$path"
    exec 200>"${path}.lock"
    flock -x 200
    printf "%s" "$content" > "$path"
    flock -u 200
    exec 200>&-
}

# Validate player name
is_valid_player_name() {
    local p
    p="$(echo "$1" | xargs)"
    [[ "$p" =~ ^[A-Za-z0-9_]{1,16}$ ]]
}

# Initialize economy file
initialize_economy() {
    [ -f "$ECONOMY_FILE" ] || echo '{"players": {}, "transactions": []}' > "$ECONOMY_FILE"
}

# Add player if new
add_player_if_new() {
    local player="$1"
    ! is_valid_player_name "$player" && return 1
    local content
    content=$(read_json_file "$ECONOMY_FILE")
    local exists
    exists=$(echo "$content" | jq --arg p "$player" '.players | has($p)')
    if [ "$exists" = "false" ]; then
        content=$(echo "$content" | jq --arg p "$player" '.players[$p] = {"tickets": 0, "last_login": 0, "last_welcome_time": 0, "last_help_time": 0, "last_greeting_time": 0, "purchases": []}')
        write_json_file "$ECONOMY_FILE" "$content"
        give_first_time_bonus "$player"
        return 0
    fi
    return 1
}

give_first_time_bonus() {
    local player="$1"
    local now time_str
    now=$(date +%s)
    time_str="$(date '+%Y-%m-%d %H:%M:%S')"
    local content
    content=$(read_json_file "$ECONOMY_FILE")
    content=$(echo "$content" | jq --arg p "$player" '.players[$p].tickets = 1')
    content=$(echo "$content" | jq --arg p "$player" --arg t "$time_str" '.transactions += [{"player": $p, "type": "welcome_bonus", "tickets": 1, "time": $t}]')
    write_json_file "$ECONOMY_FILE" "$content"
    print_success "Gave first time bonus to $player"
}

grant_login_ticket() {
    local player="$1"
    local now time_str
    now=$(date +%s)
    time_str="$(date '+%Y-%m-%d %H:%M:%S')"
    local content
    content=$(read_json_file "$ECONOMY_FILE")
    local last_login
    last_login=$(echo "$content" | jq -r --arg p "$player" '.players[$p].last_login // 0')
    last_login=${last_login:-0}
    if [ "$last_login" -eq 0 ] || [ $((now - last_login)) -ge 3600 ]; then
        local tickets
        tickets=$(echo "$content" | jq -r --arg p "$player" '.players[$p].tickets // 0')
        tickets=${tickets:-0}
        local newtickets=$((tickets + 1))
        content=$(echo "$content" | jq --arg p "$player" --argjson t "$newtickets" --arg time_str "$time_str" '.players[$p].tickets = $t | .players[$p].last_login = ($time_str | strptime("%Y-%m-%d %H:%M:%S") | mktime)')
        content=$(echo "$content" | jq --arg p "$player" --arg time_str "$time_str" '.transactions += [{"player": $p, "type": "login_bonus", "tickets": 1, "time": $time_str}]')
        write_json_file "$ECONOMY_FILE" "$content"
        print_success "Granted 1 ticket to $player"
    else
        print_warning "$player must wait for next ticket"
    fi
}

# Send server command
send_server_command() {
    if screen -S "$SCREEN_SERVER" -p 0 -X stuff "$1$(printf \\r)" 2>/dev/null; then
        print_success "Sent to server: $1"
        return 0
    else
        print_error "Could not send to server: $1"
        return 1
    fi
}

# Purchase helpers
has_purchased() {
    local player="$1" item="$2"
    local content
    content=$(read_json_file "$ECONOMY_FILE")
    local has
    has=$(echo "$content" | jq --arg p "$player" --arg item "$item" '.players[$p].purchases | index($item) != null')
    [ "$has" = "true" ]
}

add_purchase() {
    local player="$1" item="$2"
    local content
    content=$(read_json_file "$ECONOMY_FILE")
    content=$(echo "$content" | jq --arg p "$player" --arg item "$item" '.players[$p].purchases += [$item]')
    write_json_file "$ECONOMY_FILE" "$content"
}

# Process give rank from tickets
process_give_rank() {
    local giver="$1" target="$2" rank="$3"
    local content
    content=$(read_json_file "$ECONOMY_FILE")
    local g_tickets
    g_tickets=$(echo "$content" | jq -r --arg p "$giver" '.players[$p].tickets // 0')
    g_tickets=${g_tickets:-0}
    local cost=0
    [ "$rank" = "admin" ] && cost=140
    [ "$rank" = "mod" ] && cost=70
    if [ "$g_tickets" -lt "$cost" ]; then
        send_server_command "$giver, you need $cost tickets but have $g_tickets."
        return 1
    fi
    ! is_valid_player_name "$target" && { send_server_command "$giver, invalid player name: $target"; return 1; }
    local newtickets=$((g_tickets - cost))
    content=$(echo "$content" | jq --arg p "$giver" --argjson t "$newtickets" '.players[$p].tickets = $t')
    local time_str
    time_str="$(date '+%Y-%m-%d %H:%M:%S')"
    content=$(echo "$content" | jq --arg g "$giver" --arg target "$target" --arg r "$rank" --arg time_str "$time_str" --argjson cost "$cost" '.transactions += [{"giver": $g, "recipient": $target, "type": "rank_gift", "rank": $r, "tickets": -$cost, "time": $time_str}]')
    write_json_file "$ECONOMY_FILE" "$content"
    # Persist authorized file and issue server command
    echo "$target" >> "$LOG_DIR/authorized_${rank}s.txt"
    send_server_command "/${rank} ${target}"
    send_server_command "Congratulations! ${giver} gifted ${rank} to ${target}. Tickets left: ${newtickets}"
}

# Process chat commands
process_message() {
    local player="$1" message="$2"
    ! is_valid_player_name "$player" && return
    case "$message" in
        "!tickets"|"ltickets")
            local content
            content=$(read_json_file "$ECONOMY_FILE")
            local t
            t=$(echo "$content" | jq -r --arg p "$player" '.players[$p].tickets // 0')
            send_server_command "$player, you have ${t} tickets."
            ;;
        "!buy_mod")
            if has_purchased "$player" "mod" || grep -qi "^${player}$" "$AUTHORIZED_MODS_FILE" 2>/dev/null; then
                send_server_command "$player, you already have MOD rank."
            else
                local content
                content=$(read_json_file "$ECONOMY_FILE")
                local t
                t=$(echo "$content" | jq -r --arg p "$player" '.players[$p].tickets // 0')
                if [ "$t" -ge 50 ]; then
                    local newt=$((t - 50))
                    content=$(echo "$content" | jq --arg p "$player" --argjson nt "$newt" '.players[$p].tickets = $nt')
                    add_purchase "$player" "mod"
                    write_json_file "$ECONOMY_FILE" "$content"
                    echo "$player" >> "$AUTHORIZED_MODS_FILE"
                    send_server_command "/mod $player"
                    send_server_command "Congratulations $player! Promoted to MOD. Tickets left: $newt"
                else
                    send_server_command "$player, you need $((50 - t)) more tickets to buy MOD."
                fi
            fi
            ;;
        "!buy_admin")
            if has_purchased "$player" "admin" || grep -qi "^${player}$" "$AUTHORIZED_ADMINS_FILE" 2>/dev/null; then
                send_server_command "$player, you already have ADMIN rank."
            else
                local content
                content=$(read_json_file "$ECONOMY_FILE")
                local t
                t=$(echo "$content" | jq -r --arg p "$player" '.players[$p].tickets // 0')
                if [ "$t" -ge 100 ]; then
                    local newt=$((t - 100))
                    content=$(echo "$content" | jq --arg p "$player" --argjson nt "$newt" '.players[$p].tickets = $nt')
                    add_purchase "$player" "admin"
                    write_json_file "$ECONOMY_FILE" "$content"
                    echo "$player" >> "$AUTHORIZED_ADMINS_FILE"
                    send_server_command "/admin $player"
                    send_server_command "Congratulations $player! Promoted to ADMIN. Tickets left: $newt"
                else
                    send_server_command "$player, you need $((100 - t)) more tickets to buy ADMIN."
                fi
            fi
            ;;
        "!give_admin "*)
            if [[ "$message" =~ ^!give_admin[[:space:]]+([A-Za-z0-9_]{1,16})$ ]]; then
                process_give_rank "$player" "${BASH_REMATCH[1]}" "admin"
            else
                send_server_command "Usage: !give_admin PLAYER"
            fi
            ;;
        "!give_mod "*)
            if [[ "$message" =~ ^!give_mod[[:space:]]+([A-Za-z0-9_]{1,16})$ ]]; then
                process_give_rank "$player" "${BASH_REMATCH[1]}" "mod"
            else
                send_server_command "Usage: !give_mod PLAYER"
            fi
            ;;
        "!help")
            send_server_command "Available commands: !tickets, !buy_mod, !buy_admin, !give_mod, !give_admin"
            ;;
    esac
}

# Filter log to relevant lines
filter_server_log() {
    while read -r line; do
        [[ "$line" == *"Server closed"* || "$line" == *"Starting server"* || "$line" == *"adminlist.txt"* || "$line" == *"modlist.txt"* ]] && continue
        # Show lines with player connect/disconnect or chat lines
        if [[ "$line" == *"Player Connected"* || "$line" == *"Player Disconnected"* || "$line" =~ ^[A-Za-z0-9_]+:[[:space:]] ]]; then
            echo "$line"
        fi
    done
}

# Cleanup
cleanup() {
    print_status "Cleaning up economy bot..."
    kill $(jobs -p) 2>/dev/null
    rm -f "${ECONOMY_FILE}.lock" 2>/dev/null
    exit 0
}

monitor_log() {
    local log_file="$1"
    LOG_FILE="$log_file"
    initialize_economy
    trap cleanup EXIT INT TERM

    print_header "ECONOMY BOT START"
    print_status "Monitoring: $log_file"

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
        if [[ "$line" =~ Player\ Connected\ (.+)\ \|\ ([0-9a-fA-F.:]+)\ \|\ ([0-9a-f]+) ]]; then
            local pname="${BASH_REMATCH[1]}"
            local pip="${BASH_REMATCH[2]}"
            pname="$(echo "$pname" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
            [ "$pname" = "SERVER" ] && continue
            if ! is_valid_player_name "$pname"; then
                print_warning "Skipping invalid player name: $pname"
                continue
            fi
            print_success "Player connected: $pname"
            local is_new="false"
            add_player_if_new "$pname" && is_new="true"
            sleep 2
            [ "$is_new" = "false" ] && grant_login_ticket "$pname"
            continue
        fi

        if [[ "$line" =~ Player\ Disconnected\ ([A-Za-z0-9_]+) ]]; then
            local pname="${BASH_REMATCH[1]}"
            print_warning "Player disconnected: $pname"
            continue
        fi

        if [[ "$line" =~ ^([A-Za-z0-9_]+):\ (.+)$ ]]; then
            local pname="${BASH_REMATCH[1]}"
            local msg="${BASH_REMATCH[2]}"
            [ "$pname" = "SERVER" ] && continue
            ! is_valid_player_name "$pname" && { print_warning "Skipping invalid message from $pname"; continue; }
            print_status "Chat: $pname: $msg"
            add_player_if_new "$pname"
            process_message "$pname" "$msg"
            continue
        fi
    done
}

show_usage() {
    print_header "ECONOMY BOT - USAGE"
    print_status "Usage: $0 <server_log_file> [port]"
    print_status "Example: $0 /path/to/console.log 12153"
}

# Main
if [ $# -lt 1 ]; then
    show_usage
    exit 1
fi

monitor_log "$1"
