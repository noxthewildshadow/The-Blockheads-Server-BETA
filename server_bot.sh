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
PLAYERS_LOG="$LOG_DIR/players.log"

# Function to initialize economy
initialize_economy() {
    [ ! -f "$ECONOMY_FILE" ] && echo '{"players": {}, "transactions": []}' > "$ECONOMY_FILE"
}

# Function to sync players.log with list files (same as in anticheat)
sync_list_files() {
    local list_type="$1"
    local list_file="$LOG_DIR/${list_type}list.txt"
    
    [ ! -f "$PLAYERS_LOG" ] && return
    
    # Clear the list file
    echo "# Usernames in this file are granted ${list_type} privileges" > "$list_file"
    echo "# This file is automatically synced from players.log" >> "$list_file"
    
    # Add players with the appropriate rank
    while IFS='|' read -r name ip rank password ban_status; do
        if [ "$rank" = "$list_type" ]; then
            echo "$name" >> "$list_file"
        fi
    done < "$PLAYERS_LOG"
    
    print_success "Synced ${list_type}list.txt with players.log"
}

# Function to update player info in players.log (same as in anticheat)
update_player_info() {
    local player_name="$1" player_ip="$2" player_rank="$3" player_password="$4" ban_status="${5:-NONE}"
    if [ -f "$PLAYERS_LOG" ]; then
        # Remove existing entry
        sed -i "/^$player_name|/Id" "$PLAYERS_LOG"
        # Add new entry
        echo "$player_name|$player_ip|$player_rank|$player_password|$ban_status" >> "$PLAYERS_LOG"
        print_success "Updated player info in registry: $player_name -> IP: $player_ip, Rank: $player_rank, Password: $player_password, Ban: $ban_status"
        
        # Sync list files after update
        sync_list_files "admin"
        sync_list_files "mod"
    fi
}

# Function to get player info from players.log (same as in anticheat)
get_player_info() {
    local player_name="$1"
    if [ -f "$PLAYERS_LOG" ]; then
        while IFS='|' read -r name ip rank password ban_status; do
            if [ "$name" = "$player_name" ]; then
                echo "$ip|$rank|$password|$ban_status"
                return 0
            fi
        done < <(grep -i "^$player_name|" "$PLAYERS_LOG")
    fi
    echo ""
}

# Function to get player rank (same as in anticheat)
get_player_rank() {
    local player_name="$1"
    local player_info=$(get_player_info "$player_name")
    if [ -n "$player_info" ]; then
        local rank=$(echo "$player_info" | cut -d'|' -f2)
        echo "$rank"
    else
        echo "NONE"
    fi
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
    local player_name="$1" item="$2"
    local current_data=$(read_json_file "$ECONOMY_FILE")
    local has_item=$(echo "$current_data" | jq --arg player "$player_name" --arg item "$item" '.players[$player].purchases | index($item) != null')
    [ "$has_item" = "true" ]
}

# Function to add purchase
add_purchase() {
    local player_name="$1" item="$2"
    local current_data=$(read_json_file "$ECONOMY_FILE")
    current_data=$(echo "$current_data" | jq --arg player "$player_name" --arg item "$item" '.players[$player].purchases += [$item]')
    write_json_file "$ECONOMY_FILE" "$current_data"
}

# Function to process give rank command
process_give_rank() {
    local giver_name="$1" target_player="$2" rank_type="$3"
    local current_data=$(read_json_file "$ECONOMY_FILE")
    local giver_tickets=$(echo "$current_data" | jq -r --arg player "$giver_name" '.players[$player].tickets // 0')
    giver_tickets=${giver_tickets:-0}
    
    local cost=0
    [ "$rank_type" = "admin" ] && cost=140
    [ "$rank_type" = "mod" ] && cost=70
    
    [ "$giver_tickets" -lt "$cost" ] && {
        send_server_command "$giver_name, you need $cost tickets to give $rank_type rank, but you only have $giver_tickets."
        return 1
    }
    
    ! is_valid_player_name "$target_player" && {
        send_server_command "$giver_name, invalid player name: $target_player"
        return 1
    }
    
    local new_tickets=$((giver_tickets - cost))
    current_data=$(echo "$current_data" | jq --arg player "$giver_name" --argjson tickets "$new_tickets" '.players[$player].tickets = $tickets')
    
    local time_str="$(date '+%Y-%m-%d %H:%M:%S')"
    current_data=$(echo "$current_data" | jq --arg giver "$giver_name" --arg target "$target_player" \
        --arg rank "$rank_type" --argjson cost "$cost" --arg time "$time_str" \
        '.transactions += [{"giver": $giver, "recipient": $target, "type": "rank_gift", "rank": $rank, "tickets": -$cost, "time": $time}]')
    
    write_json_file "$ECONOMY_FILE" "$current_data"
    
    # Update players.log with the new rank
    local target_info=$(get_player_info "$target_player")
    if [ -n "$target_info" ]; then
        local target_ip=$(echo "$target_info" | cut -d'|' -f1)
        local target_password=$(echo "$target_info" | cut -d'|' -f3)
        local ban_status=$(echo "$target_info" | cut -d'|' -f4)
        update_player_info "$target_player" "$target_ip" "$rank_type" "$target_password" "$ban_status"
    else
        # If player doesn't exist in players.log, create entry
        local target_ip=$(get_ip_by_name "$target_player")
        update_player_info "$target_player" "$target_ip" "$rank_type" "NONE" "NONE"
    fi
    
    # Apply the rank in-game
    screen -S "$SCREEN_SERVER" -p 0 -X stuff "/$rank_type $target_player$(printf \\r)"
    
    send_server_command "Congratulations! $giver_name has gifted $rank_type rank to $target_player for $cost tickets."
    send_server_command "$giver_name, your new ticket balance: $new_tickets"
    return 0
}

# Function to process message
process_message() {
    local player_name="$1" message="$2"
    ! is_valid_player_name "$player_name" && return
    
    local current_data=$(read_json_file "$ECONOMY_FILE")
    local player_tickets=$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].tickets // 0')
    player_tickets=${player_tickets:-0}
    
    case "$message" in
        "!tickets"|"ltickets")
            send_server_command "$player_name, you have $player_tickets tickets."
            ;;
        "!buy_mod")
            (has_purchased "$player_name" "mod" || [ "$(get_player_rank "$player_name")" = "mod" ]) && {
                send_server_command "$player_name, you already have MOD rank."
            } || [ "$player_tickets" -ge 50 ] && {
                local new_tickets=$((player_tickets - 50))
                current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson tickets "$new_tickets" '.players[$player].tickets = $tickets')
                add_purchase "$player_name" "mod"
                local time_str="$(date '+%Y-%m-%d %H:%M:%S')"
                current_data=$(echo "$current_data" | jq --arg player "$player_name" --arg time "$time_str" \
                    '.transactions += [{"player": $player, "type": "purchase", "item": "mod", "tickets": -50, "time": $time}]')
                write_json_file "$ECONOMY_FILE" "$current_data"
                
                # Update players.log with the new rank
                local player_info=$(get_player_info "$player_name")
                if [ -n "$player_info" ]; then
                    local player_ip=$(echo "$player_info" | cut -d'|' -f1)
                    local player_password=$(echo "$player_info" | cut -d'|' -f3)
                    local ban_status=$(echo "$player_info" | cut -d'|' -f4)
                    update_player_info "$player_name" "$player_ip" "mod" "$player_password" "$ban_status"
                else
                    # If player doesn't exist in players.log, create entry
                    local player_ip=$(get_ip_by_name "$player_name")
                    update_player_info "$player_name" "$player_ip" "mod" "NONE" "NONE"
                fi
                
                # Apply the rank in-game
                screen -S "$SCREEN_SERVER" -p 0 -X stuff "/mod $player_name$(printf \\r)"
                send_server_command "Congratulations $player_name! You have been promoted to MOD for 50 tickets. Remaining tickets: $new_tickets"
            } || send_server_command "$player_name, you need $((50 - player_tickets)) more tickets to buy MOD rank."
            ;;
        "!buy_admin")
            (has_purchased "$player_name" "admin" || [ "$(get_player_rank "$player_name")" = "admin" ]) && {
                send_server_command "$player_name, you already have ADMIN rank."
            } || [ "$player_tickets" -ge 100 ] && {
                local new_tickets=$((player_tickets - 100))
                current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson tickets "$new_tickets" '.players[$player].tickets = $tickets')
                add_purchase "$player_name" "admin"
                local time_str="$(date '+%Y-%m-%d %H:%M:%S')"
                current_data=$(echo "$current_data" | jq --arg player "$player_name" --arg time "$time_str" \
                    '.transactions += [{"player": $player, "type": "purchase", "item": "admin", "tickets": -100, "time": $time}]')
                write_json_file "$ECONOMY_FILE" "$current_data"
                
                # Update players.log with the new rank
                local player_info=$(get_player_info "$player_name")
                if [ -n "$player_info" ]; then
                    local player_ip=$(echo "$player_info" | cut -d'|' -f1)
                    local player_password=$(echo "$player_info" | cut -d'|' -f3)
                    local ban_status=$(echo "$player_info" | cut -d'|' -f4)
                    update_player_info "$player_name" "$player_ip" "admin" "$player_password" "$ban_status"
                else
                    # If player doesn't exist in players.log, create entry
                    local player_ip=$(get_ip_by_name "$player_name")
                    update_player_info "$player_name" "$player_ip" "admin" "NONE" "NONE"
                fi
                
                # Apply the rank in-game
                screen -S "$SCREEN_SERVER" -p 0 -X stuff "/admin $player_name$(printf \\r)"
                send_server_command "Congratulations $player_name! You have been promoted to ADMIN for 100 tickets. Remaining tickets: $new_tickets"
            } || send_server_command "$player_name, you need $((100 - player_tickets)) more tickets to buy ADMIN rank."
            ;;
        "!give_admin "*)
            [[ "$message" =~ !give_admin\ ([a-zA-Z0-9_]+) ]] && \
            process_give_rank "$player_name" "${BASH_REMATCH[1]}" "admin" || \
            send_server_command "Usage: !give_admin PLAYER_NAME"
            ;;
        "!give_mod "*)
            [[ "$message" =~ !give_mod\ ([a-zA-Z0-9_]+) ]] && \
            process_give_rank "$player_name" "${BASH_REMATCH[1]}" "mod" || \
            send_server_command "Usage: !give_mod PLAYER_NAME"
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

# Function to process admin command
process_admin_command() {
    local command="$1" current_data=$(read_json_file "$ECONOMY_FILE")
    
    if [[ "$command" =~ ^!send_ticket\ ([a-zA-Z0-9_]+)\ ([0-9]+)$ ]]; then
        local player_name="${BASH_REMATCH[1]}" tickets_to_add="${BASH_REMATCH[2]}"
        
        ! is_valid_player_name "$player_name" && {
            print_error "Invalid player name: $player_name"
            return 1
        }
        
        [[ ! "$tickets_to_add" =~ ^[0-9]+$ ]] || [ "$tickets_to_add" -le 0 ] && {
            print_error "Invalid ticket amount: $tickets_to_add"
            return 1
        }
        
        local player_exists=$(echo "$current_data" | jq --arg player "$player_name" '.players | has($player)')
        [ "$player_exists" = "false" ] && print_error "Player $player_name not found" && return 1
        
        local current_tickets=$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].tickets // 0')
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
        ! is_valid_player_name "$player_name" && print_error "Invalid player name: $player_name" && return 1
        
        print_success "Setting $player_name as MOD"
        
        # Update players.log with the new rank
        local player_info=$(get_player_info "$player_name")
        if [ -n "$player_info" ]; then
            local player_ip=$(echo "$player_info" | cut -d'|' -f1)
            local player_password=$(echo "$player_info" | cut -d'|' -f3)
            local ban_status=$(echo "$player_info" | cut -d'|' -f4)
            update_player_info "$player_name" "$player_ip" "mod" "$player_password" "$ban_status"
        else
            # If player doesn't exist in players.log, create entry
            local player_ip=$(get_ip_by_name "$player_name")
            update_player_info "$player_name" "$player_ip" "mod" "NONE" "NONE"
        fi
        
        # Apply the rank in-game
        screen -S "$SCREEN_SERVER" -p 0 -X stuff "/mod $player_name$(printf \\r)"
        send_server_command "$player_name has been set as MOD by server console!"
    elif [[ "$command" =~ ^!set_admin\ ([a-zA-Z0-9_]+)$ ]]; then
        local player_name="${BASH_REMATCH[1]}"
        ! is_valid_player_name "$player_name" && print_error "Invalid player name: $player_name" && return 1
        
        print_success "Setting $player_name as ADMIN"
        
        # Update players.log with the new rank
        local player_info=$(get_player_info "$player_name")
        if [ -n "$player_info" ]; then
            local player_ip=$(echo "$player_info" | cut -d'|' -f1)
            local player_password=$(echo "$player_info" | cut -d'|' -f3)
            local ban_status=$(echo "$player_info" | cut -d'|' -f4)
            update_player_info "$player_name" "$player_ip" "admin" "$player_password" "$ban_status"
        else
            # If player doesn't exist in players.log, create entry
            local player_ip=$(get_ip_by_name "$player_name")
            update_player_info "$player_name" "$player_ip" "admin" "NONE" "NONE"
        fi
        
        # Apply the rank in-game
        screen -S "$SCREEN_SERVER" -p 0 -X stuff "/admin $player_name$(printf \\r)"
        send_server_command "$player_name has been set as ADMIN by server console!"
    else
        print_error "Unknown admin command: $command"
    fi
}

# Function to check if server sent welcome recently
server_sent_welcome_recently() {
    local player_name="$1"
    [ -z "$LOG_FILE" ] || [ ! -f "$LOG_FILE" ] && return 1
    local player_lc=$(echo "$player_name" | tr '[:upper:]' '[:lower:]')
    
    tail -n 100 "$LOG_FILE" 2>/dev/null | grep -i "server:.*welcome.*$player_lc" | head -1 | grep -q . && return 0
    
    local current_time=$(date +%s)
    local current_data=$(read_json_file "$ECONOMY_FILE")
    local last_welcome_time=$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].last_welcome_time // 0')
    
    [ "$last_welcome_time" -gt 0 ] && [ $((current_time - last_welcome_time)) -le 30 ] && return 0
    
    return 1
}

# Function to filter server log - only show relevant information
filter_server_log() {
    while read -r line; do
        # Filter out server spam and only show relevant information
        if [[ "$line" == *"Server closed"* || \
              "$line" == *"Starting server"* || \
              "$line" == *"World load complete"* || \
              "$line" == *"Exiting World"* || \
              "$line" == *"Loading world named"* || \
              "$line" == *"using seed:"* || \
              "$line" == *"save delay:"* || \
              "$line" == *"adminlist.txt"* || \
              "$line" == *"modlist.txt"* ]]; then
            continue
        fi

        # Show only player connections, disconnections, and chat messages
        if [[ "$line" == *"Player Connected"* || \
              "$line" == *"Player Disconnected"* || \
              "$line" == *"SERVER: say"* || \
              "$line" =~ [a-zA-Z0-9_]+:[[:space:]] || \
              "$line" =~ [a-zA-Z0-9_]+:[[:space:]]*[^[:space:]] ]]; then
            echo "$line"
        fi
    done
}

# Function to cleanup
cleanup() {
    print_status "Cleaning up..."
    rm -f "$admin_pipe" 2>/dev/null
    kill $(jobs -p) 2>/dev/null
    rm -f "${ECONOMY_FILE}.lock" 2>/dev/null
    exit 0
}

# Function to monitor log
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

    local admin_pipe="/tmp/blockheads_admin_pipe_$$"
    rm -f "$admin_pipe"
    mkfifo "$admin_pipe"

    # Admin command processor
    (
        while read -r admin_command < "$admin_pipe"; do
            print_status "Processing admin command: $admin_command"
            [[ "$admin_command" == "!send_ticket "* || "$admin_command" == "!set_mod "* || "$admin_command" == "!set_admin "* ]] && \
            process_admin_command "$admin_command" || \
            print_error "Unknown admin command"
            print_header "READY FOR NEXT COMMAND"
        done
    ) &

    # Admin command reader
    (
        while read -r admin_command; do
            echo "$admin_command" > "$admin_pipe"
        done
    ) &

    # Wait for log file to exist
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

    # Start monitoring the log
    tail -n 0 -F "$log_file" 2>/dev/null | filter_server_log | while read -r line; do
        if [[ "$line" =~ Player\ Connected\ (.+)\ \|\ ([0-9a-fA-F.:]+)\ \|\ ([0-9a-f]+) ]]; then
            local player_name="${BASH_REMATCH[1]}" player_ip="${BASH_REMATCH[2]}" player_hash="${BASH_REMATCH[3]}"
            player_name=$(extract_real_name "$player_name")
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

            ! server_sent_welcome_recently "$player_name" && \
            show_welcome_message "$player_name" "$is_new_player" 1 || \
            print_warning "Server already welcomed $player_name"

            [ "$is_new_player" = "false" ] && grant_login_ticket "$player_name"
            continue
        fi

        if [[ "$line" =~ Player\ Disconnected\ ([a-zA-Z0-9_]+) ]]; then
            local player_name="${BASH_REMATCH[1]}"
            player_name=$(extract_real_name "$player_name")
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
            player_name=$(extract_real_name "$player_name")
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

        # Skip other log lines to avoid spam
        # print_status "Other log line: $line"
    done

    rm -f "$admin_pipe"
}

# Function to show usage
show_usage() {
    print_header "ECONOMY BOT - USAGE"
    print_status "Usage: $0 <server_log_file> [port]"
    print_status "Example: $0 /path/to/console.log 12153"
    echo ""
    print_warning "Note: This script should be run alongside the server"
}

# Main execution
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
