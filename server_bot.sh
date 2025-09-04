#!/bin/bash

# Enhanced Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Function to print status messages
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

# Function to validate player names - ENHANCED TO DETECT SPACES/EMPTY NAMES
is_valid_player_name() {
    local player_name="$1"
    
    # Check if name is empty or contains only spaces
    if [[ -z "$player_name" || "$player_name" =~ ^[[:space:]]+$ ]]; then
        return 1
    fi
    
    # Check if name contains any spaces or special characters
    if [[ "$player_name" =~ [[:space:]] || ! "$player_name" =~ ^[a-zA-Z0-9_]+$ ]]; then
        return 1
    fi
    
    return 0
}

# Function to safely read JSON files with locking
read_json_file() {
    local file_path="$1"
    if [ ! -f "$file_path" ]; then
        print_error "JSON file not found: $file_path"
        echo "{}"
        return 1
    fi
    
    # Use flock with proper file descriptor handling
    flock -s 200 cat "$file_path" 200>"${file_path}.lock"
}

# Function to safely write JSON files with locking
write_json_file() {
    local file_path="$1"
    local content="$2"
    
    if [ ! -f "$file_path" ]; then
        print_error "JSON file not found: $file_path"
        return 1
    fi
    
    # Use flock with proper file descriptor handling
    flock -x 200 echo "$content" > "$file_path" 200>"${file_path}.lock"
    return $?
}

# Bot configuration - now supports multiple servers
if [ $# -ge 2 ]; then
    PORT="$2"
    LOG_DIR=$(dirname "$1")
    ECONOMY_FILE="$LOG_DIR/economy_data_$PORT.json"
    SCREEN_SERVER="blockheads_server_$PORT"
else
    LOG_DIR=$(dirname "$1")
    ECONOMY_FILE="$LOG_DIR/economy_data.json"
    SCREEN_SERVER="blockheads_server"
fi

# Authorization files
AUTHORIZED_ADMINS_FILE="$LOG_DIR/authorized_admins.txt"
AUTHORIZED_MODS_FILE="$LOG_DIR/authorized_mods.txt"

# Function to add player to authorized list
add_to_authorized() {
    local player_name="$1" list_type="$2"
    local auth_file="$LOG_DIR/authorized_${list_type}s.txt"
    
    [ ! -f "$auth_file" ] && print_error "Authorization file not found: $auth_file" && return 1
    
    if ! grep -q -i "^$player_name$" "$auth_file"; then
        echo "$player_name" >> "$auth_file"
        print_success "Added $player_name to authorized ${list_type}s"
        return 0
    else
        print_warning "$player_name is already in authorized ${list_type}s"
        return 1
    fi
}

initialize_economy() {
    [ ! -f "$ECONOMY_FILE" ] && echo '{"players": {}, "transactions": []}' > "$ECONOMY_FILE" &&
    print_success "Economy data file created: $ECONOMY_FILE"
}

is_player_in_list() {
    local player_name="$1" list_type="$2"
    local list_file="$LOG_DIR/${list_type}list.txt"
    
    [ -f "$list_file" ] && grep -v "^[[:space:]]*#" "$list_file" 2>/dev/null | grep -q -i "^$player_name$" && return 0
    return 1
}

add_player_if_new() {
    local player_name="$1"
    local current_data=$(read_json_file "$ECONOMY_FILE")
    local player_exists=$(echo "$current_data" | jq --arg player "$player_name" '.players | has($player)')
    
    if [ "$player_exists" = "false" ]; then
        current_data=$(echo "$current_data" | jq --arg player "$player_name" \
            '.players[$player] = {"tickets": 0, "last_login": 0, "last_welcome_time": 0, "last_help_time": 0, "last_greeting_time": 0, "purchases": []}')
        write_json_file "$ECONOMY_FILE" "$current_data"
        print_success "Added new player: $player_name"
        give_first_time_bonus "$player_name"
        return 0
    fi
    return 1
}

give_first_time_bonus() {
    local player_name="$1" current_time=$(date +%s) time_str="$(date '+%Y-%m-%d %H:%M:%S')"
    local current_data=$(read_json_file "$ECONOMY_FILE")
    current_data=$(echo "$current_data" | jq --arg player "$player_name" '.players[$player].tickets = 1')
    current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson time "$current_time" '.players[$player].last_login = $time')
    current_data=$(echo "$current_data" | jq --arg player "$player_name" --arg time "$time_str" \
        '.transactions += [{"player": $player, "type": "welcome_bonus", "tickets": 1, "time": $time}]')
    write_json_file "$ECONOMY_FILE" "$current_data"
    print_success "Gave first-time bonus to $player_name"
}

grant_login_ticket() {
    local player_name="$1" current_time=$(date +%s) time_str="$(date '+%Y-%m-%d %H:%M:%S')"
    local current_data=$(read_json_file "$ECONOMY_FILE")
    local last_login=$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].last_login // 0')
    last_login=${last_login:-0}
    
    if [ "$last_login" -eq 0 ] || [ $((current_time - last_login)) -ge 3600 ]; then
        local current_tickets=$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].tickets // 0')
        current_tickets=${current_tickets:-0}
        local new_tickets=$((current_tickets + 1))
        
        # Combine all updates into a single jq command
        current_data=$(echo "$current_data" | jq --arg player "$player_name" \
            --argjson tickets "$new_tickets" --argjson time "$current_time" --arg time_str "$time_str" \
            '.players[$player].tickets = $tickets | 
             .players[$player].last_login = $time |
             .transactions += [{"player": $player, "type": "login_bonus", "tickets": 1, "time": $time_str}]')
        
        write_json_file "$ECONOMY_FILE" "$current_data"
        print_success "Granted 1 ticket to $player_name for logging in (Total: $new_tickets)"
    else
        local next_login=$((last_login + 3600))
        local time_left=$((next_login - current_time))
        print_warning "$player_name must wait $((time_left / 60)) minutes for next ticket"
    fi
}

show_welcome_message() {
    local player_name="$1" is_new_player="$2" force_send="${3:-0}"
    local current_time=$(date +%s)
    local current_data=$(read_json_file "$ECONOMY_FILE")
    local last_welcome_time=$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].last_welcome_time // 0')
    last_welcome_time=${last_welcome_time:-0}
    
    if [ "$force_send" -eq 1 ] || [ "$last_welcome_time" -eq 0 ] || [ $((current_time - last_welcome_time)) -ge 180 ]; then
        if [ "$is_new_player" = "true" ]; then
            send_server_command "Hello $player_name! Welcome to the server. Type !help to check available commands."
        else
            local last_greeting_time=$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].last_greeting_time // 0')
            if [ $((current_time - last_greeting_time)) -ge 600 ]; then
                send_server_command "Welcome back $player_name! Type !help to see available commands."
                # Update last_greeting_time to prevent spam
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

send_server_command() {
    if screen -S "$SCREEN_SERVER" -X stuff "$1$(printf \\r)" 2>/dev/null; then
        print_success "Sent message to server: $1"
    else
        print_error "Could not send message to server. Is the server running?"
    fi
}

has_purchased() {
    local player_name="$1" item="$2"
    local current_data=$(read_json_file "$ECONOMY_FILE")
    local has_item=$(echo "$current_data" | jq --arg player "$player_name" --arg item "$item" '.players[$player].purchases | index($item) != null')
    [ "$has_item" = "true" ] && return 0 || return 1
}

add_purchase() {
    local player_name="$1" item="$2"
    local current_data=$(read_json_file "$ECONOMY_FILE")
    current_data=$(echo "$current_data" | jq --arg player "$player_name" --arg item "$item" '.players[$player].purchases += [$item]')
    write_json_file "$ECONOMY_FILE" "$current_data"
}

# Function to process give_rank commands
process_give_rank() {
    local giver_name="$1" target_player="$2" rank_type="$3"
    local current_data=$(read_json_file "$ECONOMY_FILE")
    local giver_tickets=$(echo "$current_data" | jq -r --arg player "$giver_name" '.players[$player].tickets // 0')
    giver_tickets=${giver_tickets:-0}
    
    local cost=0
    [ "$rank_type" = "admin" ] && cost=140
    [ "$rank_type" = "mod" ] && cost=70
    
    if [ "$giver_tickets" -lt "$cost" ]; then
        send_server_command "$giver_name, you need $cost tickets to give $rank_type rank, but you only have $giver_tickets."
        return 1
    fi
    
    # Validate target player name
    if ! is_valid_player_name "$target_player"; then
        send_server_command "$giver_name, invalid player name: $target_player"
        return 1
    fi
    
    # Deduct tickets from giver
    local new_tickets=$((giver_tickets - cost))
    current_data=$(echo "$current_data" | jq --arg player "$giver_name" --argjson tickets "$new_tickets" '.players[$player].tickets = $tickets')
    
    # Record transaction
    local time_str="$(date '+%Y-%m-%d %H:%M:%S')"
    current_data=$(echo "$current_data" | jq --arg giver "$giver_name" --arg target "$target_player" \
        --arg rank "$rank_type" --argjson cost "$cost" --arg time "$time_str" \
        '.transactions += [{"giver": $giver, "recipient": $target, "type": "rank_gift", "rank": $rank, "tickets": -$cost, "time": $time}]')
    
    write_json_file "$ECONOMY_FILE" "$current_data"
    
    # Add to authorized list and assign rank
    add_to_authorized "$target_player" "$rank_type"
    screen -S "$SCREEN_SERVER" -X stuff "/$rank_type $target_player$(printf \\r)"
    
    send_server_command "Congratulations! $giver_name has gifted $rank_type rank to $target_player for $cost tickets."
    send_server_command "$giver_name, your new ticket balance: $new_tickets"
    return 0
}

process_message() {
    local player_name="$1" message="$2"
    local current_data=$(read_json_file "$ECONOMY_FILE")
    local player_tickets=$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].tickets // 0')
    player_tickets=${player_tickets:-0}
    
    case "$message" in
        "hi"|"hello"|"Hi"|"Hello"|"hola"|"Hola")
            local current_time=$(date +%s)
            local last_greeting_time=$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].last_greeting_time // 0')
            
            # 10-minute cooldown for greetings
            if [ "$last_greeting_time" -eq 0 ] || [ $((current_time - last_greeting_time)) -ge 600 ]; then
                send_server_command "Hello $player_name! Welcome to the server. Type !help to check available commands."
                # Update last_greeting_time
                current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson time "$current_time" '.players[$player].last_greeting_time = $time')
                write_json_file "$ECONOMY_FILE" "$current_data"
            else
                print_warning "Skipping greeting for $player_name due to cooldown"
            fi
            ;;
        "!tickets")
            send_server_command "$player_name, you have $player_tickets tickets."
            ;;
        "!buy_mod")
            if has_purchased "$player_name" "mod" || is_player_in_list "$player_name" "mod"; then
                send_server_command "$player_name, you already have MOD rank. No need to purchase again."
            elif [ "$player_tickets" -ge 50 ]; then
                local new_tickets=$((player_tickets - 50))
                current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson tickets "$new_tickets" '.players[$player].tickets = $tickets')
                add_purchase "$player_name" "mod"
                local time_str="$(date '+%Y-%m-%d %H:%M:%S')"
                current_data=$(echo "$current_data" | jq --arg player "$player_name" --arg time "$time_str" \
                    '.transactions += [{"player": $player, "type": "purchase", "item": "mod", "tickets": -50, "time": $time}]')
                write_json_file "$ECONOMY_FILE" "$current_data"
                
                # First add to authorized mods, then assign rank
                add_to_authorized "$player_name" "mod"
                screen -S "$SCREEN_SERVER" -X stuff "/mod $player_name$(printf \\r)"
                send_server_command "Congratulations $player_name! You have been promoted to MOD for 50 tickets. Remaining tickets: $new_tickets"
            else
                send_server_command "$player_name, you need $((50 - player_tickets)) more tickets to buy MOD rank."
            fi
            ;;
        "!buy_admin")
            if has_purchased "$player_name" "admin" || is_player_in_list "$player_name" "admin"; then
                send_server_command "$player_name, you already have ADMIN rank. No need to purchase again."
            elif [ "$player_tickets" -ge 100 ]; then
                local new_tickets=$((player_tickets - 100))
                current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson tickets "$new_tickets" '.players[$player].tickets = $tickets')
                add_purchase "$player_name" "admin"
                local time_str="$(date '+%Y-%m-%d %H:%M:%S')"
                current_data=$(echo "$current_data" | jq --arg player "$player_name" --arg time "$time_str" \
                    '.transactions += [{"player": $player, "type": "purchase", "item": "admin", "tickets": -100, "time": $time}]')
                write_json_file "$ECONOMY_FILE" "$current_data"
                
                # First add to authorized admins, then assign rank
                add_to_authorized "$player_name" "admin"
                screen -S "$SCREEN_SERVER" -X stuff "/admin $player_name$(printf \\r)"
                send_server_command "Congratulations $player_name! You have been promoted to ADMIN for 100 tickets. Remaining tickets: $new_tickets"
            else
                send_server_command "$player_name, you need $((100 - player_tickets)) more tickets to buy ADMIN rank."
            fi
            ;;
        "!give_admin "*)
            if [[ "$message" =~ !give_admin\ ([a-zA-Z0-9_]+) ]]; then
                local target_player="${BASH_REMATCH[1]}"
                process_give_rank "$player_name" "$target_player" "admin"
            else
                send_server_command "Usage: !give_admin PLAYER_NAME"
            fi
            ;;
        "!give_mod "*)
            if [[ "$message" =~ !give_mod\ ([a-zA-Z0-9_]+) ]]; then
                local target_player="${BASH_REMATCH[1]}"
                process_give_rank "$player_name" "$target_player" "mod"
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

process_admin_command() {
    local command="$1" current_data=$(read_json_file "$ECONOMY_FILE")
    
    if [[ "$command" =~ ^!send_ticket\ ([a-zA-Z0-9_]+)\ ([0-9]+)$ ]]; then
        local player_name="${BASH_REMATCH[1]}" tickets_to_add="${BASH_REMATCH[2]}"
        
        # Validate player name
        if ! is_valid_player_name "$player_name"; then
            print_error "Invalid player name: $player_name"
            return 1
        fi
        
        # Validate ticket amount
        if [[ ! "$tickets_to_add" =~ ^[0-9]+$ ]] || [ "$tickets_to_add" -le 0 ]; then
            print_error "Invalid ticket amount: $tickets_to_add"
            return 1
        fi
        
        local player_exists=$(echo "$current_data" | jq --arg player "$player_name" '.players | has($player)')
        [ "$player_exists" = "false" ] && print_error "Player $player_name not found in economy system" && return 1
        
        local current_tickets=$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].tickets // 0')
        current_tickets=${current_tickets:-0}
        local new_tickets=$((current_tickets + tickets_to_add))
        
        # Combine all updates into a single jq command
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
        
        # Validate player name
        if ! is_valid_player_name "$player_name"; then
            print_error "Invalid player name: $player_name"
            return 1
        fi
        
        print_success "Setting $player_name as MOD"
        # First add to authorized mods, then assign rank
        add_to_authorized "$player_name" "mod"
        screen -S "$SCREEN_SERVER" -X stuff "/mod $player_name$(printf \\r)"
        send_server_command "$player_name has been set as MOD by server console!"
    elif [[ "$command" =~ ^!set_admin\ ([a-zA-Z0-9_]+)$ ]]; then
        local player_name="${BASH_REMATCH[1]}"
        
        # Validate player name
        if ! is_valid_player_name "$player_name"; then
            print_error "Invalid player name: $player_name"
            return 1
        fi
        
        print_success "Setting $player_name as ADMIN"
        # First add to authorized admins, then assign rank
        add_to_authorized "$player_name" "admin"
        screen -S "$SCREEN_SERVER" -X stuff "/admin $player_name$(printf \\r)"
        send_server_command "$player_name has been set as ADMIN by server console!"
    else
        print_error "Unknown admin command: $command"
        print_status "Available admin commands:"
        echo -e "!send_ticket <player> <amount>"
        echo -e "!set_mod <player> (console only)"
        echo -e "!set_admin <player> (console only)"
    fi
}

server_sent_welcome_recently() {
    local player_name="$1"
    [ -z "$LOG_FILE" ] || [ ! -f "$LOG_FILE" ] && return 1
    local player_lc=$(echo "$player_name" | tr '[:upper:]' '[:lower:]')
    
    # Check for server welcome messages in the last 100 lines
    if tail -n 100 "$LOG_FILE" 2>/dev/null | grep -i "server:.*welcome.*$player_lc" | head -1 | grep -q .; then
        return 0
    fi
    
    # Check economy data for last welcome time
    local current_time=$(date +%s)
    local current_data=$(read_json_file "$ECONOMY_FILE")
    local last_welcome_time=$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].last_welcome_time // 0')
    
    # If we have welcomed in the last 30 seconds, then return true (already welcomed)
    if [ "$last_welcome_time" -gt 0 ] && [ $((current_time - last_welcome_time)) -le 30 ]; then
        return 0
    fi
    
    return 1
}

filter_server_log() {
    while read line; do
        [[ "$line" == *"Server closed"* || "$line" == *"Starting server"* || \
          ("$line" == *"SERVER: say"* && "$line" == *"Welcome"*) || \
          "$line" == *"adminlist.txt"* || "$line" == *"modlist.txt"* ]] && continue
        echo "$line"
    done
}

# Cleanup function for signal handling
cleanup() {
    print_status "Cleaning up..."
    rm -f "$admin_pipe" 2>/dev/null
    # Kill background processes
    kill $(jobs -p) 2>/dev/null
    # Clean up lock files
    rm -f "${ECONOMY_FILE}.lock" 2>/dev/null
    print_status "Cleanup done."
    exit 0
}

# Function to handle invalid player names
handle_invalid_player_name() {
    local raw_player_name="$1"
    local player_ip="$2"
    local player_name_trimmed="$3"
    
    # Check if player name is invalid (empty, only spaces, or contains spaces)
    if ! is_valid_player_name "$player_name_trimmed"; then
        print_warning "INVALID PLAYER NAME DETECTED: '$raw_player_name' (IP: $player_ip)"
        send_server_command "WARNING: Empty player names are not allowed!"
        send_server_command "Kicking player with empty name in 3 seconds..."
        
        # Wait 3 seconds and then kick the player
        (
            sleep 3
            # Use the exact player name with all spaces for the kick command
            # This ensures players with spaces in their names are properly kicked
            send_server_command "/kick \"$raw_player_name\""
            print_success "Kicked player with invalid name: '$raw_player_name'"
        ) &
        
        return 1
    fi
    
    return 0
}

monitor_log() {
    local log_file="$1"
    LOG_FILE="$log_file"

    initialize_economy

    # Set up signal handling
    trap cleanup EXIT INT TERM

    print_header "STARTING ECONOMY BOT"
    print_status "Monitoring: $log_file"
    print_status "Bot commands: !tickets, !buy_mod, !buy_admin, !give_mod, !give_admin, !help"
    print_status "Admin commands: !send_ticket <player> <amount>, !set_mod <player>, !set_admin <player>"
    print_header "IMPORTANT: Admin commands must be typed in THIS terminal, NOT in the game chat!"
    print_status "Type admin commands below and press Enter:"
    print_header "READY FOR COMMANDS"

    local admin_pipe="/tmp/blockheads_admin_pipe_$$"
    rm -f "$admin_pipe"
    mkfifo "$admin_pipe"

    # Background process to read admin commands from the pipe
    while read -r admin_command < "$admin_pipe"; then
        print_status "Processing admin command: $admin_command"
        if [[ "$admin_command" == "!send_ticket "* || "$admin_command" == "!set_mod "* || "$admin_command" == "!set_admin "* ]]; then
            process_admin_command "$admin_command"
        else
            print_error "Unknown admin command. Use: !send_ticket <player> <amount>, !set_mod <player>, or !set_admin <player>"
        fi
        print_header "READY FOR NEXT COMMAND"
    done &

    # Forward stdin to the admin pipe
    while read -r admin_command; do
        echo "$admin_command" > "$admin_pipe"
    done &

    declare -A welcome_shown

    # Monitor the log file
    tail -n 0 -F "$log_file" 2>/dev/null | filter_server_log | while read line; do
        # Detect player connections with invalid names
        if [[ "$line" =~ Player\ Connected\ ([^|]+)\ \|\ ([0-9a-fA-F.:]+) ]]; then
            local raw_player_name="${BASH_REMATCH[1]}"
            local player_ip="${BASH_REMATCH[2]}"
            [ "$raw_player_name" == "SERVER" ] && continue
            
            # Trim leading/trailing spaces from player name for validation
            local player_name_trimmed=$(echo "$raw_player_name" | xargs)
            
            # Check for invalid player names - use the original name with spaces
            if ! handle_invalid_player_name "$raw_player_name" "$player_ip" "$player_name_trimmed"; then
                continue
            fi

            # Use the trimmed name for economy functions
            local player_name="$player_name_trimmed"

            print_success "Player connected: $player_name (IP: $player_ip)"

            # Extract timestamp
            ts_str=$(echo "$line" | awk '{print $1" "$2}')
            ts_no_ms=${ts_str%.*}
            conn_epoch=$(date -d "$ts_no_ms" +%s 2>/dev/null || echo 0)

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
            [ "$player_name" == "SERVER" ] && continue
            
            # Validate player name
            if ! is_valid_player_name "$player_name"; then
                print_warning "Invalid player name detected: $player_name"
                continue
            fi
            
            print_warning "Player disconnected: $player_name"
            unset welcome_shown["$player_name"]
            continue
        fi

        if [[ "$line" =~ ([a-zA-Z0-9_]+):\ (.+)$ ]]; then
            local player_name="${BASH_REMATCH[1]}" message="${BASH_REMATCH[2]}"
            [ "$player_name" == "SERVER" ] && continue
            
            # Validate player name
            if ! is_valid_player_name "$player_name"; then
                print_warning "Invalid player name detected: $player_name"
                continue
            fi
            
            print_status "Chat: $player_name: $message"
            add_player_if_new "$player_name"
            process_message "$player_name" "$message"
            continue
        fi

        print_status "Other log line: $line"
    done

    wait
    rm -f "$admin_pipe"
}

# Show usage information for new users
show_usage() {
    print_header "ECONOMY BOT - USAGE"
    print_status "This script manages the server economy and player commands"
    print_status "Usage: $0 <server_log_file> [port]"
    print_status "Example: $0 /path/to/console.log 12153"
    echo ""
    print_warning "Note: This script should be run alongside the server"
    print_warning "It will automatically handle player commands and economy"
}

if [ $# -eq 1 ] || [ $# -eq 2 ]; then
    initialize_economy
    monitor_log "$1"
else
    show_usage
    exit 1
fi
