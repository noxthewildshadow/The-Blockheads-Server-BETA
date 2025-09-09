#!/bin/bash

# =============================================================================
# THE BLOCKHEADS SERVER ECONOMY BOT
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

# Validate jq is installed
if ! command -v jq &> /dev/null; then
    echo -e "${RED}ERROR: jq is required but not installed. Please install jq first.${NC}"
    exit 1
fi

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

# Function to validate player names
is_valid_player_name() {
    local player_name=$(echo "$1" | xargs)
    [[ "$player_name" =~ ^[a-zA-Z0-9_]+$ ]]
}

# Initialize variables
[ $# -ge 2 ] && PORT="$2" || PORT="12153"
LOG_DIR=$(dirname "$1")
ECONOMY_FILE="$LOG_DIR/economy_data_$PORT.json"
SCREEN_SERVER="blockheads_server_$PORT"
AUTHORIZED_ADMINS_FILE="$LOG_DIR/authorized_admins.txt"
AUTHORIZED_MODS_FILE="$LOG_DIR/authorized_mods.txt"

# Function to initialize economy
initialize_economy() {
    [ ! -f "$ECONOMY_FILE" ] && echo '{"players": {}, "transactions": []}' > "$ECONOMY_FILE"
}

# Function to check if player is in list
is_player_in_list() {
    local player_name="$1" list_type="$2"
    local list_file="$LOG_DIR/${list_type}list.txt"
    [ -f "$list_file" ] && grep -v "^[[:space:]]*#" "$list_file" 2>/dev/null | grep -q -i "^$player_name$"
}

# Function to add player if new
add_player_if_new() {
    local player_name="$1"
    ! is_valid_player_name "$player_name" && return 1
    
    local current_data=$(read_json_file "$ECONOMY_FILE")
    local player_exists=$(echo "$current_data" | jq --arg player "$player_name" '.players | has($player)')
    
    [ "$player_exists" = "false" ] && {
        current_data=$(echo "$current_data" | jq --arg player "$player_name" \
            '.players[$player] = {"tickets": 0, "last_login": 0, "last_welcome_time": 0, "last_help_time": 0, "last_greeting_time": 0, "purchases": []}')
        write_json_file "$ECONOMY_FILE" "$current_data"
        give_first_time_bonus "$player_name"
        return 0
    }
    return 1
}

# Function to give first time bonus
give_first_time_bonus() {
    local player_name="$1" current_time=$(date +%s) time_str="$(date '+%Y-%m-%d %H:%M:%S')"
    local current_data=$(read_json_file "$ECONOMY_FILE")
    current_data=$(echo "$current_data" | jq --arg player "$player_name" '.players[$player].tickets = 1')
    current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson time "$current_time" '.players[$player].last_login = $time')
    current_data=$(echo "$current_data" | jq --arg player "$player_name" --arg time "$time_str" \
        '.transactions += [{"player": $player, "type": "welcome_bonus", "tickets": 1, "time": $time}]')
    write_json_file "$ECONOMY_FILE" "$current_data"
}

# Function to grant login ticket
grant_login_ticket() {
    local player_name="$1" current_time=$(date +%s) time_str="$(date '+%Y-%m-%d %H:%M:%S')"
    local current_data=$(read_json_file "$ECONOMY_FILE")
    local last_login=$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].last_login // 0')
    last_login=${last_login:-0}
    
    [ "$last_login" -eq 0 ] || [ $((current_time - last_login)) -ge 3600 ] && {
        local current_tickets=$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].tickets // 0')
        current_tickets=${current_tickets:-0}
        local new_tickets=$((current_tickets + 1))
        
        current_data=$(echo "$current_data" | jq --arg player "$player_name" \
            --argjson tickets "$new_tickets" --argjson time "$current_time" --arg time_str "$time_str" \
            '.players[$player].tickets = $tickets | 
             .players[$player].last_login = $time |
             .transactions += [{"player": $player, "type": "login_bonus", "tickets": 1, "time": $time_str}]')
        
        write_json_file "$ECONOMY_FILE" "$current_data"
        print_success "Granted 1 ticket to $player_name (Total: $new_tickets)"
    } || {
        local next_login=$((last_login + 3600))
        local time_left=$((next_login - current_time))
        print_warning "$player_name must wait $((time_left / 60)) minutes for next ticket"
    }
}

# Function to show welcome message
show_welcome_message() {
    local player_name="$1" is_new_player="$2" force_send="${3:-0}"
    ! is_valid_player_name "$player_name" && return
    
    local current_time=$(date +%s)
    local current_data=$(read_json_file "$ECONOMY_FILE")
    local last_welcome_time=$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].last_welcome_time // 0')
    last_welcome_time=${last_welcome_time:-0}
    
    # 30-second cooldown for welcome messages
    [ "$force_send" -eq 1 ] || [ "$last_welcome_time" -eq 0 ] || [ $((current_time - last_welcome_time)) -ge 30 ] && {
        [ "$is_new_player" = "true" ] && {
            send_server_command "Hello $player_name! Welcome to the server. Type !help to check available commands."
        } || {
            local last_greeting_time=$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].last_greeting_time // 0')
            [ $((current_time - last_greeting_time)) -ge 600 ] && {
                send_server_command "Welcome back $player_name! Type !help to see available commands."
                current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson time "$current_time" '.players[$player].last_greeting_time = $time')
                write_json_file "$ECONOMY_FILE" "$current_data"
            }
        }
        current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson time "$current_time" '.players[$player].last_welcome_time = $time')
        write_json_file "$ECONOMY_FILE" "$current_data"
    } || print_warning "Skipping welcome for $player_name due to cooldown"
}

# Function to send server command
send_server_command() {
    if screen -S "$SCREEN_SERVER" -p 0 -X stuff "$1$(printf \\r)" 2>/dev/null; then
        print_success "Sent message to server: $1"
        return 0
    else
        print_error "Could not send message to server"
        return 1
    fi
}

# Function to check if player has purchased an item
has_purchased() {
    local player_name="$1" item_name="$2"
    local current_data=$(read_json_file "$ECONOMY_FILE")
    local purchases=$(echo "$current_data" | jq --arg player "$player_name" '.players[$player].purchases[]' 2>/dev/null | sed 's/"//g')
    
    for item in $purchases; do
        [ "$item" == "$item_name" ] && return 0
    done
    return 1
}

# Function to get player tickets
get_player_tickets() {
    local player_name="$1"
    local current_data=$(read_json_file "$ECONOMY_FILE")
    echo $(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].tickets // 0')
}

# Function to update player tickets
update_player_tickets() {
    local player_name="$1" amount="$2"
    local current_data=$(read_json_file "$ECONOMY_FILE")
    local current_tickets=$(get_player_tickets "$player_name")
    local new_tickets=$((current_tickets + amount))
    
    if [ "$new_tickets" -lt 0 ]; then
        print_error "Insufficient tickets for $player_name"
        return 1
    fi
    
    current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson tickets "$new_tickets" '.players[$player].tickets = $tickets')
    write_json_file "$ECONOMY_FILE" "$current_data"
    print_success "Updated tickets for $player_name: $current_tickets -> $new_tickets"
    return 0
}

# Function to handle shop command
handle_shop() {
    local player_name="$1" args="$2"
    case "$args" in
        list)
            send_server_command "SERVER: Shop items: Golden Chest (10 tickets), Portal Chest (15 tickets)"
            ;;
        buy\ GoldenChest)
            handle_purchase "$player_name" "GoldenChest" 10
            ;;
        buy\ PortalChest)
            handle_purchase "$player_name" "PortalChest" 15
            ;;
        *)
            send_server_command "SERVER: Invalid shop command. Use '!shop list' or '!shop buy <item>'"
            ;;
    esac
}

# Function to handle purchase
handle_purchase() {
    local player_name="$1" item_name="$2" cost="$3"
    local current_tickets=$(get_player_tickets "$player_name")
    local time_str="$(date '+%Y-%m-%d %H:%M:%S')"
    
    if [ "$current_tickets" -ge "$cost" ]; then
        if update_player_tickets "$player_name" "-$cost"; then
            local current_data=$(read_json_file "$ECONOMY_FILE")
            current_data=$(echo "$current_data" | jq --arg player "$player_name" --arg item "$item_name" --arg time "$time_str" \
                '.players[$player].purchases += [$item] | .transactions += [{"player": $player, "type": "purchase", "item": $item, "cost": '$cost', "time": $time}]')
            write_json_file "$ECONOMY_FILE" "$current_data"
            send_server_command "SERVER: $player_name has purchased a $item_name for $cost tickets! Check your inventory."
        fi
    else
        send_server_command "SERVER: Sorry $player_name, you need $cost tickets to buy a $item_name. You only have $current_tickets."
    fi
}

# Function to handle chat commands
handle_chat_command() {
    local player_name="$1" command="$2"
    
    case "$command" in
        \!shop*)
            handle_shop "$player_name" "${command#\!shop }"
            ;;
        \!tickets)
            local tickets=$(get_player_tickets "$player_name")
            send_server_command "SERVER: $player_name, you have $tickets tickets."
            ;;
        \!help)
            local current_time=$(date +%s)
            local current_data=$(read_json_file "$ECONOMY_FILE")
            local last_help_time=$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].last_help_time // 0')
            [ "$((current_time - last_help_time))" -ge 30 ] && {
                send_server_command "SERVER: Available commands: !tickets, !shop list, !shop buy <item>"
                current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson time "$current_time" '.players[$player].last_help_time = $time')
                write_json_file "$ECONOMY_FILE" "$current_data"
            } || {
                print_warning "Skipping help message for $player_name due to cooldown."
            }
            ;;
        /unadmin*|/unmod*|/admin*|/mod*)
            # Ignore rank commands as they are handled by anticheat_secure.sh
            return
            ;;
    esac
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

# Main monitoring loop
monitor_log() {
    local log_file="$1"
    initialize_economy
    
    print_header "STARTING ECONOMY BOT"
    print_status "Monitoring: $log_file"
    print_status "Port: $PORT"
    print_header "ECONOMY BOT ACTIVE"
    
    # Wait for log file to exist
    local wait_time=0
    while [ ! -f "$log_file" ] && [ $wait_time -lt 30 ]; do
        sleep 1
        ((wait_time++))
        [ $((wait_time % 5)) -eq 0 ] && print_status "Waiting for log file to be created..."
    done
    
    if [ ! -f "$log_file" ]; then
        print_error "Log file never appeared: $log_file"
        exit 1
    fi
    
    tail -n 0 -F "$log_file" 2>/dev/null | filter_server_log | while read -r line; do
        if [[ "$line" =~ Player\ Connected\ (.+)\ \|\ ([0-9a-fA-F.:]+)\ \|\ ([0-9a-f]+) ]]; then
            local player_name="${BASH_REMATCH[1]}" player_ip="${BASH_REMATCH[2]}"
            player_name=$(echo "$player_name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            
            if is_valid_player_name "$player_name"; then
                if add_player_if_new "$player_name"; then
                    show_welcome_message "$player_name" "true"
                else
                    show_welcome_message "$player_name" "false"
                fi
                grant_login_ticket "$player_name"
            fi
        fi

        if [[ "$line" =~ Player\ Disconnected\ (.+) ]]; then
            local player_name="${BASH_REMATCH[1]}"
            player_name=$(echo "$player_name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            is_valid_player_name "$player_name" && print_warning "Player disconnected: $player_name"
        fi

        if [[ "$line" =~ ([a-zA-Z0-9_]+):\ (.+)$ ]]; then
            local player_name="${BASH_REMATCH[1]}" message="${BASH_REMATCH[2]}"
            player_name=$(echo "$player_name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            
            is_valid_player_name "$player_name" && [[ "$message" == \!* ]] && handle_chat_command "$player_name" "$message"
        fi
    done
}

# Main execution
if [ $# -lt 1 ]; then
    show_usage
    exit 1
fi

if [ $# -eq 1 ] || [ $# -eq 2 ]; then
    monitor_log "$1"
else
    show_usage
    exit 1
fi
