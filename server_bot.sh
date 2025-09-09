#!/bin/bash

# Color codes for output (ASCII escape sequences)
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
print_header() { echo -e "${PURPLE}================================================================"; echo -e "$1"; echo -e "===============================================================${NC}"; }
print_step() { echo -e "${CYAN}[STEP]${NC} $1"; }

# Require jq
if ! command -v jq &> /dev/null; then
    echo -e "${RED}ERROR: jq is required but not installed. Please install jq first.${NC}"
    exit 1
fi

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

# Validate player names (only A-Z a-z 0-9 and underscore)
is_valid_player_name() {
    local player_name=$(echo "$1" | xargs)
    [[ "$player_name" =~ ^[a-zA-Z0-9_]+$ ]]
}

# Init variables
[ $# -ge 2 ] && PORT="$2" || PORT="12153"
LOG_DIR=$(dirname "$1")
ECONOMY_FILE="$LOG_DIR/economy_data_$PORT.json"
SCREEN_SERVER="blockheads_server_$PORT"
AUTHORIZED_ADMINS_FILE="$LOG_DIR/authorized_admins.txt"
AUTHORIZED_MODS_FILE="$LOG_DIR/authorized_mods.txt"
ADMIN_PIPE_GLOBAL="/tmp/blockheads_admin_pipe_global_$PORT"

# Initialize economy files
initialize_economy() {
    [ ! -f "$ECONOMY_FILE" ] && echo '{"players": {}, "transactions": []}' > "$ECONOMY_FILE"
    [ ! -f "$AUTHORIZED_ADMINS_FILE" ] && touch "$AUTHORIZED_ADMINS_FILE"
    [ ! -f "$AUTHORIZED_MODS_FILE" ] && touch "$AUTHORIZED_MODS_FILE"
}

# Check if player is in list
is_player_in_list() {
    local player_name="$1" list_type="$2"
    local list_file="$LOG_DIR/${list_type}list.txt"
    [ -f "$list_file" ] && grep -v "^[[:space:]]*#" "$list_file" 2>/dev/null | grep -q -i "^$player_name$"
}

# Safe add to authorized file (with flock + dedupe)
add_authorized() {
    local file="$1" name="$2"
    mkdir -p "$(dirname "$file")"
    ( flock -x 200
      touch "$file"
      grep -i -x -q "$name" "$file" 2>/dev/null || echo "$name" >> "$file"
    ) 200>"${file}.lock"
    sort -fu "$file" -o "$file"
}

# Sanitize name strictly for server commands: keep [A-Za-z0-9_]
sanitize_name_strict() {
    local s="$1"
    printf '%s' "$s" | sed 's/[^A-Za-z0-9_]//g'
}

# Add player if new
add_player_if_new() {
    local player_name="$1"
    ! is_valid_player_name "$player_name" && return 1

    local current_data
    current_data=$(read_json_file "$ECONOMY_FILE")
    local player_exists
    player_exists=$(echo "$current_data" | jq --arg player "$player_name" '.players | has($player)')

    [ "$player_exists" = "false" ] && {
        current_data=$(echo "$current_data" | jq --arg player "$player_name" \
            '.players[$player] = {"tickets": 0, "last_login": 0, "last_welcome_time": 0, "last_help_time": 0, "last_greeting_time": 0, "purchases": []}')
        write_json_file "$ECONOMY_FILE" "$current_data"
        give_first_time_bonus "$player_name"
        return 0
    }
    return 1
}

# Give first time bonus
give_first_time_bonus() {
    local player_name="$1" current_time=$(date +%s) time_str="$(date '+%Y-%m-%d %H:%M:%S')"
    local current_data
    current_data=$(read_json_file "$ECONOMY_FILE")
    current_data=$(echo "$current_data" | jq --arg player "$player_name" '.players[$player].tickets = 1')
    current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson time "$current_time" '.players[$player].last_login = $time')
    current_data=$(echo "$current_data" | jq --arg player "$player_name" --arg time "$time_str" \
        '.transactions += [{"player": $player, "type": "welcome_bonus", "tickets": 1, "time": $time}]')
    write_json_file "$ECONOMY_FILE" "$current_data"
    print_success "Gave first time bonus to $player_name"
}

# Grant login ticket (once per hour)
grant_login_ticket() {
    local player_name="$1" current_time=$(date +%s) time_str="$(date '+%Y-%m-%d %H:%M:%S')"
    local current_data
    current_data=$(read_json_file "$ECONOMY_FILE")
    local last_login
    last_login=$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].last_login // 0')
    last_login=${last_login:-0}

    if [ "$last_login" -eq 0 ] || [ $((current_time - last_login)) -ge 3600 ]; then
        local current_tickets
        current_tickets=$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].tickets // 0')
        current_tickets=${current_tickets:-0}
        local new_tickets=$((current_tickets + 1))

        current_data=$(echo "$current_data" | jq --arg player "$player_name" \
            --argjson tickets "$new_tickets" --argjson time "$current_time" --arg time_str "$time_str" \
            '.players[$player].tickets = $tickets | 
             .players[$player].last_login = $time |
             .transactions += [{"player": $player, "type": "login_bonus", "tickets": 1, "time": $time_str}]')

        write_json_file "$ECONOMY_FILE" "$current_data"
        print_success "Granted 1 ticket to $player_name (Total: $new_tickets)"
    else
        local next_login=$((last_login + 3600))
        local time_left=$((next_login - current_time))
        print_warning "$player_name must wait $((time_left / 60)) minutes for next ticket"
    fi
}

# Show welcome message with cooldowns
show_welcome_message() {
    local player_name="$1" is_new_player="$2" force_send="${3:-0}"
    ! is_valid_player_name "$player_name" && return

    local current_time=$(date +%s)
    local current_data
    current_data=$(read_json_file "$ECONOMY_FILE")
    local last_welcome_time
    last_welcome_time=$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].last_welcome_time // 0')
    last_welcome_time=${last_welcome_time:-0}

    if [ "$force_send" -eq 1 ] || [ "$last_welcome_time" -eq 0 ] || [ $((current_time - last_welcome_time)) -ge 180 ]; then
        if [ "$is_new_player" = "true" ]; then
            send_server_command "Hello $player_name! Welcome to the server. Type !help to check available commands."
        else
            local last_greeting_time
            last_greeting_time=$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].last_greeting_time // 0')
            if [ $((current_time - last_greeting_time)) -ge 600 ]; then
                send_server_command "Welcome back $player_name! Type !help to see available commands."
                current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson time "$current_time" '.players[$player].last_greeting_time = $time')
                write_json_file "$ECONOMY_FILE" "$current_data"
            fi
        fi
        current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson time "$current_time" '.players[$player].last_welcome_time = $time')
        write_json_file "$ECONOMY_FILE" "$current_data"
    else
        print_warning "Skipping welcome for $player_name due to cooldown"
    fi
}

# Screen helpers and send_server_command
screen_session_exists() {
    local session="$1"
    screen -ls 2>/dev/null | grep -qE "\.${session}(\s|\)|$)"
}
send_server_command() {
    if screen_session_exists "$SCREEN_SERVER"; then
        if screen -S "$SCREEN_SERVER" -p 0 -X stuff "$1$(printf \\r)" 2>/dev/null; then
            print_success "Sent message to server: $1"
            return 0
        else
            print_error "Could not send message to server"
            return 1
        fi
    else
        print_error "Screen session $SCREEN_SERVER does not exist"
        return 1
    fi
}

# Check purchases
has_purchased() {
    local player_name="$1" item="$2"
    local current_data
    current_data=$(read_json_file "$ECONOMY_FILE")
    local has_item
    has_item=$(echo "$current_data" | jq --arg player "$player_name" --arg item "$item" '.players[$player].purchases | index($item) != null')
    [ "$has_item" = "true" ]
}

# Add purchase
add_purchase() {
    local player_name="$1" item="$2"
    local current_data
    current_data=$(read_json_file "$ECONOMY_FILE")
    current_data=$(echo "$current_data" | jq --arg player "$player_name" --arg item "$item" '.players[$player].purchases += [$item]')
    write_json_file "$ECONOMY_FILE" "$current_data"
}

# Process give rank (gift)
process_give_rank() {
    local giver_name="$1" target_player="$2" rank_type="$3"
    local current_data
    current_data=$(read_json_file "$ECONOMY_FILE")
    local giver_tickets
    giver_tickets=$(echo "$current_data" | jq -r --arg player "$giver_name" '.players[$player].tickets // 0')
    giver_tickets=${giver_tickets:-0}

    local cost=0
    [ "$rank_type" = "admin" ] && cost=140
    [ "$rank_type" = "mod" ] && cost=70

    if [ "$giver_tickets" -lt "$cost" ]; then
        send_server_command "$giver_name, you need $cost tickets to give $rank_type rank, but you only have $giver_tickets."
        return 1
    fi

    if ! is_valid_player_name "$target_player"; then
        send_server_command "$giver_name, invalid player name: $target_player"
        return 1
    fi

    local new_tickets=$((giver_tickets - cost))
    current_data=$(echo "$current_data" | jq --arg player "$giver_name" --argjson tickets "$new_tickets" '.players[$player].tickets = $tickets')

    local time_str
    time_str="$(date '+%Y-%m-%d %H:%M:%S')"
    current_data=$(echo "$current_data" | jq --arg giver "$giver_name" --arg target "$target_player" \
        --arg rank "$rank_type" --argjson cost "$cost" --arg time "$time_str" \
        '.transactions += [{"giver": $giver, "recipient": $target, "type": "rank_gift", "rank": $rank, "tickets": -$cost, "time": $time}]')

    write_json_file "$ECONOMY_FILE" "$current_data"

    local safe_target
    safe_target=$(sanitize_name_strict "$target_player")
    if [ "$rank_type" = "admin" ]; then
        add_authorized "$AUTHORIZED_ADMINS_FILE" "$safe_target"
    else
        add_authorized "$AUTHORIZED_MODS_FILE" "$safe_target"
    fi

    send_server_command "/$rank_type $safe_target"
    send_server_command "Congratulations! $giver_name has gifted $rank_type rank to $safe_target for $cost tickets."
    send_server_command "$giver_name, your new ticket balance: $new_tickets"
    return 0
}

# Process chat message commands
process_message() {
    local player_name="$1" message="$2"
    ! is_valid_player_name "$player_name" && return

    local current_data
    current_data=$(read_json_file "$ECONOMY_FILE")
    local player_tickets
    player_tickets=$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].tickets // 0')
    player_tickets=${player_tickets:-0}

    case "$message" in
        "!tickets"|"ltickets")
            send_server_command "$player_name, you have $player_tickets tickets."
            ;;
        "!buy_mod")
            if has_purchased "$player_name" "mod" || is_player_in_list "$player_name" "mod"; then
                send_server_command "$player_name, you already have MOD rank."
            elif [ "$player_tickets" -ge 50 ]; then
                local new_tickets=$((player_tickets - 50))
                current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson tickets "$new_tickets" '.players[$player].tickets = $tickets')
                add_purchase "$player_name" "mod"
                local time_str
                time_str="$(date '+%Y-%m-%d %H:%M:%S')"
                current_data=$(echo "$current_data" | jq --arg player "$player_name" --arg time "$time_str" \
                    '.transactions += [{"player": $player, "type": "purchase", "item": "mod", "tickets": -50, "time": $time}]')
                write_json_file "$ECONOMY_FILE" "$current_data"

                local safe_name
                safe_name=$(sanitize_name_strict "$player_name")
                add_authorized "$AUTHORIZED_MODS_FILE" "$safe_name"
                send_server_command "/mod $safe_name"
                send_server_command "Congratulations $player_name! You have been promoted to MOD for 50 tickets. Remaining tickets: $new_tickets"
            else
                send_server_command "$player_name, you need $((50 - player_tickets)) more tickets to buy MOD rank."
            fi
            ;;
        "!buy_admin")
            if has_purchased "$player_name" "admin" || is_player_in_list "$player_name" "admin"; then
                send_server_command "$player_name, you already have ADMIN rank."
            elif [ "$player_tickets" -ge 100 ]; then
                local new_tickets=$((player_tickets - 100))
                current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson tickets "$new_tickets" '.players[$player].tickets = $tickets')
                add_purchase "$player_name" "admin"
                local time_str
                time_str="$(date '+%Y-%m-%d %H:%M:%S')"
                current_data=$(echo "$current_data" | jq --arg player "$player_name" --arg time "$time_str" \
                    '.transactions += [{"player": $player, "type": "purchase", "item": "admin", "tickets": -100, "time": $time}]')
                write_json_file "$ECONOMY_FILE" "$current_data"

                local safe_name
                safe_name=$(sanitize_name_strict "$player_name")
                add_authorized "$AUTHORIZED_ADMINS_FILE" "$safe_name"
                send_server_command "/admin $safe_name"
                send_server_command "Congratulations $player_name! You have been promoted to ADMIN for 100 tickets. Remaining tickets: $new_tickets"
            else
                send_server_command "$player_name, you need $((100 - player_tickets)) more tickets to buy ADMIN rank."
            fi
            ;;
        "!give_admin "*)
            if [[ "$message" =~ !give_admin\ ([a-zA-Z0-9_]+) ]]; then
                process_give_rank "$player_name" "${BASH_REMATCH[1]}" "admin"
            else
                send_server_command "Usage: !give_admin PLAYER_NAME"
            fi
            ;;
        "!give_mod "*)
            if [[ "$message" =~ !give_mod\ ([a-zA-Z0-9_]+) ]]; then
                process_give_rank "$player_name" "${BASH_REMATCH[1]}" "mod"
            else
                send_server_command "Usage: !give_mod PLAYER_NAME"
            fi
            ;;
        "!set_admin"|"!set_mod")
            send_server_command "$player_name, these commands are only available to server console operators."
            ;;
        "!help")
            send_server_command "Available commands:"
            send_server_command "!tickets - Check your tickets"
            send_server_command "!buy_mod - Buy MOD rank for 50 tickets"
            send_server_command "!buy_admin - Buy ADMIN rank for 100 tickets"
            send_server_command "!give_mod PLAYER - Gift MOD rank (70 tickets)"
            send_server_command "!give_admin PLAYER - Gift ADMIN rank (140 tickets)"
            ;;
    esac
}

# Process admin console commands
process_admin_command() {
    local command="$1" current_data
    current_data=$(read_json_file "$ECONOMY_FILE")

    if [[ "$command" =~ ^!send_ticket\ ([a-zA-Z0-9_]+)\ ([0-9]+)$ ]]; then
        local player_name="${BASH_REMATCH[1]}" tickets_to_add="${BASH_REMATCH[2]}"

        if ! is_valid_player_name "$player_name"; then
            print_error "Invalid player name: $player_name"
            return 1
        fi

        if ! [[ "$tickets_to_add" =~ ^[0-9]+$ ]] || [ "$tickets_to_add" -le 0 ]; then
            print_error "Invalid ticket amount: $tickets_to_add"
            return 1
        fi

        local player_exists
        player_exists=$(echo "$current_data" | jq --arg player "$player_name" '.players | has($player)')
        [ "$player_exists" = "false" ] && print_error "Player $player_name not found" && return 1

        local current_tickets
        current_tickets=$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].tickets // 0')
        current_tickets=${current_tickets:-0}
        local new_tickets=$((current_tickets + tickets_to_add))

        current_data=$(echo "$current_data" | jq --arg player "$player_name" \
            --argjson tickets "$new_tickets" --arg time_str "$(date '+%Y-%m-%d %H:%M:%S')" \
            --argjson amount "$tickets_to_add" \
            '.players[$player].tickets = $tickets |
             .transactions += [{"player": $player, "type": "admin_gift", "tickets": $amount, "time": $time_str}]')

        write_json_file "$ECONOMY_FILE" "$current_data"
        print_success "Added $tickets_to_add tickets to $player_name (Total: $new_tickets)"
        send_server_command "$player_name received $tickets_to_add tickets from admin! Total: $new_tickets"
    elif [[ "$command" =~ ^!set_mod\ ([a-zA-Z0-9_]+)$ ]]; then
        local player_name="${BASH_REMATCH[1]}"
        if ! is_valid_player_name "$player_name"; then
            print_error "Invalid player name: $player_name"
            return 1
        fi

        print_success "Setting $player_name as MOD"
        local safe_name
        safe_name=$(sanitize_name_strict "$player_name")
        add_authorized "$AUTHORIZED_MODS_FILE" "$safe_name"
        send_server_command "/mod $safe_name"
        send_server_command "$player_name has been set as MOD by server console!"
    elif [[ "$command" =~ ^!set_admin\ ([a-zA-Z0-9_]+)$ ]]; then
        local player_name="${BASH_REMATCH[1]}"
        if ! is_valid_player_name "$player_name"; then
            print_error "Invalid player name: $player_name"
            return 1
        fi

        print_success "Setting $player_name as ADMIN"
        local safe_name
        safe_name=$(sanitize_name_strict "$player_name")
        add_authorized "$AUTHORIZED_ADMINS_FILE" "$safe_name"
        send_server_command "/admin $safe_name"
        send_server_command "$player_name has been set as ADMIN by server console!"
    else
        print_error "Unknown admin command: $command"
    fi
}

# Check if server sent welcome recently
server_sent_welcome_recently() {
    local player_name="$1"
    [ -z "$LOG_FILE" ] || [ ! -f "$LOG_FILE" ] && return 1
    local player_lc
    player_lc=$(echo "$player_name" | tr '[:upper:]' '[:lower:]')

    tail -n 100 "$LOG_FILE" 2>/dev/null | grep -i "server:.*welcome.*$player_lc" | head -1 | grep -q . && return 0

    local current_time
    current_time=$(date +%s)
    local current_data
    current_data=$(read_json_file "$ECONOMY_FILE")
    local last_welcome_time
    last_welcome_time=$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].last_welcome_time // 0')

    [ "$last_welcome_time" -gt 0 ] && [ $((current_time - last_welcome_time)) -le 30 ] && return 0

    return 1
}

# Filter server log
filter_server_log() {
    while read -r line; do
        [[ "$line" == *"Server closed"* || "$line" == *"Starting server"* || ("$line" == *"SERVER: say"* && "$line" == *"Welcome"*) || "$line" == *"adminlist.txt"* || "$line" == *"modlist.txt"* ]] && continue
        echo "$line"
    done
}

# Cleanup
cleanup() {
    print_status "Cleaning up..."
    rm -f "$ADMIN_PIPE_GLOBAL" 2>/dev/null
    kill $(jobs -p) 2>/dev/null
    rm -f "${ECONOMY_FILE}.lock" 2>/dev/null
    exit 0
}

# Monitor log and act
monitor_log() {
    local log_file="$1"
    LOG_FILE="$log_file"

    initialize_economy

    trap cleanup EXIT INT TERM

    print_header "STARTING ECONOMY BOT"
    print_status "Monitoring: $log_file"
    print_status "Bot commands: !tickets, !buy_mod, !buy_admin, !give_mod, !give_admin, !help"
    print_status "Admin commands: !send_ticket <player> <amount>, !set_mod <player>, !set_admin <player>"
    print_header "READY FOR COMMANDS"

    rm -f "$ADMIN_PIPE_GLOBAL"
    mkfifo "$ADMIN_PIPE_GLOBAL"

    # Admin command processor
    (
        while read -r admin_command < "$ADMIN_PIPE_GLOBAL"; do
            print_status "Processing admin command: $admin_command"
            if [[ "$admin_command" == "!send_ticket "* || "$admin_command" == "!set_mod "* || "$admin_command" == "!set_admin "* ]]; then
                process_admin_command "$admin_command"
            else
                print_error "Unknown admin command"
            fi
            print_header "READY FOR NEXT COMMAND"
        done
    ) &

    # Admin command reader (stdin -> pipe)
    (
        while read -r admin_command; do
            echo "$admin_command" > "$ADMIN_PIPE_GLOBAL"
        done
    ) &

    # Wait for log file
    local wait_time=0
    while [ ! -f "$log_file" ] && [ $wait_time -lt 30 ]; do
        sleep 1
        ((wait_time++))
        [ $((wait_time % 5)) -eq 0 ] && print_status "Waiting for log file to be created..."
    done

    if [ ! -f "$log_file" ]; then
        print_error "Log file never appeared: $log_file"
        kill $(jobs -p) 2>/dev/null
        exit 1
    fi

    # Tail and process
    tail -n 0 -F "$log_file" 2>/dev/null | filter_server_log | while read -r line; do
        if [[ "$line" =~ Player\ Connected\ (.+)\ \|\ ([0-9a-fA-F.:]+)\ \|\ ([0-9a-f]+) ]]; then
            local player_name="${BASH_REMATCH[1]}" player_ip="${BASH_REMATCH[2]}" player_hash="${BASH_REMATCH[3]}"
            player_name=$(echo "$player_name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [ "$player_name" == "SERVER" ] && continue

            ! is_valid_player_name "$player_name" && {
                print_warning "Skipping invalid player name: '$player_name' (IP: $player_ip)"
                continue
            }

            print_success "Player connected: $player_name (IP: $player_ip)"

            local is_new_player="false"
            add_player_if_new "$player_name" && is_new_player="true"

            sleep 3

            if ! server_sent_welcome_recently "$player_name"; then
                show_welcome_message "$player_name" "$is_new_player" 1
            else
                print_warning "Server already welcomed $player_name"
            fi

            [ "$is_new_player" = "false" ] && grant_login_ticket "$player_name"
            continue
        fi

        if [[ "$line" =~ Player\ Disconnected\ ([a-zA-Z0-9_]+) ]]; then
            local player_name="${BASH_REMATCH[1]}"
            player_name=$(echo "$player_name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [ "$player_name" == "SERVER" ] && continue

            ! is_valid_player_name "$player_name" && {
                print_warning "Skipping invalid player name: '$player_name'"
                continue
            }

            print_warning "Player disconnected: $player_name"
            continue
        fi

        if [[ "$line" =~ ([a-zA-Z0-9_]+):\ (.+)$ ]]; then
            local player_name="${BASH_REMATCH[1]}" message="${BASH_REMATCH[2]}"
            player_name=$(echo "$player_name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [ "$player_name" == "SERVER" ] && continue

            ! is_valid_player_name "$player_name" && {
                print_warning "Skipping message from invalid player name: '$player_name'"
                continue
            }

            print_status "Chat: $player_name: $message"
            add_player_if_new "$player_name"
            process_message "$player_name" "$message"
            continue
        fi

        print_status "Other log line: $line"
    done

    rm -f "$ADMIN_PIPE_GLOBAL"
}

# Usage
show_usage() {
    print_header "ECONOMY BOT - USAGE"
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
    initialize_economy
    monitor_log "$1"
else
    show_usage
    exit 1
fi
