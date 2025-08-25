#!/bin/bash

# Enhanced Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
ORANGE='\033[0;33m'
PURPLE='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Function to print status messages
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_header() {
    echo -e "${PURPLE}================================================================"
    echo -e "$1"
    echo -e "===============================================================${NC}"
}

print_step() {
    echo -e "${CYAN}[STEP]${NC} $1"
}

# Bot configuration - now supports multiple servers
if [ $# -ge 2 ]; then
    PORT="$2"
    ECONOMY_FILE="economy_data_$PORT.json"
    ADMIN_OFFENSES_FILE="admin_offenses_$PORT.json"
    SCREEN_SERVER="blockheads_server_$PORT"
else
    ECONOMY_FILE="economy_data.json"
    ADMIN_OFFENSES_FILE="admin_offenses.json"
    SCREEN_SERVER="blockheads_server"
fi

SCAN_INTERVAL=5
SERVER_WELCOME_WINDOW=15
TAIL_LINES=500

# Initialize admin offenses tracking
initialize_admin_offenses() {
    if [ ! -f "$ADMIN_OFFENSES_FILE" ]; then
        echo '{}' > "$ADMIN_OFFENSES_FILE"
        print_success "Admin offenses tracking file created: $ADMIN_OFFENSES_FILE"
    fi
}

# Function to record admin offense
record_admin_offense() {
    local admin_name="$1"
    local current_time=$(date +%s)
    local offenses_data=$(cat "$ADMIN_OFFENSES_FILE" 2>/dev/null || echo '{}')
    
    # Get current offenses for this admin
    local current_offenses=$(echo "$offenses_data" | jq -r --arg admin "$admin_name" '.[$admin]?.count // 0')
    local last_offense_time=$(echo "$offenses_data" | jq -r --arg admin "$admin_name" '.[$admin]?.last_offense // 0')
    
    # Check if previous offense was more than 5 minutes ago
    if [ $((current_time - last_offense_time)) -gt 300 ]; then
        # Reset count if it's been more than 5 minutes
        current_offenses=0
    fi
    
    # Increment offense count
    current_offenses=$((current_offenses + 1))
    
    # Update offenses data
    offenses_data=$(echo "$offenses_data" | jq --arg admin "$admin_name" \
        --argjson count "$current_offenses" \
        --argjson time "$current_time" \
        '.[$admin] = {"count": $count, "last_offense": $time}')
    
    echo "$offenses_data" > "$ADMIN_OFFENSES_FILE"
    print_warning "Recorded offense #$current_offenses for admin $admin_name"
    
    return $current_offenses
}

# Function to clear admin offenses
clear_admin_offenses() {
    local admin_name="$1"
    local offenses_data=$(cat "$ADMIN_OFFENSES_FILE" 2>/dev/null || echo '{}')
    
    offenses_data=$(echo "$offenses_data" | jq --arg admin "$admin_name" 'del(.[$admin])')
    echo "$offenses_data" > "$ADMIN_OFFENSES_FILE"
    print_success "Cleared offenses for admin $admin_name"
}

# Function to remove player from list file
remove_from_list_file() {
    local player_name="$1"
    local list_type="$2"  # "admin" or "mod"
    
    # Get world directory from log file path
    local world_dir=$(dirname "$LOG_FILE")
    local list_file="$world_dir/${list_type}list.txt"
    local lower_player_name=$(echo "$player_name" | tr '[:upper:]' '[:lower:]')
    
    # Check if the list file exists
    if [ ! -f "$list_file" ]; then
        print_error "List file not found: $list_file"
        return 1
    fi
    
    # Remove the player from the list file
    if grep -q "^$lower_player_name$" "$list_file"; then
        # Use sed to remove the player name (case-insensitive)
        sed -i "/^$lower_player_name$/Id" "$list_file"
        print_success "Removed $player_name from ${list_type}list.txt"
        return 0
    else
        print_warning "Player $player_name not found in ${list_type}list.txt"
        return 1
    fi
}

# Function to send delayed unadmin/unmod commands
send_delayed_uncommands() {
    local target_player="$1"
    local command_type="$2"  # "admin" or "mod"
    
    (
        sleep 2
        send_server_command "/un${command_type} $target_player"
        print_status "Sent first /un${command_type} command for $target_player after 2 seconds"
        
        sleep 2
        send_server_command "/un${command_type} $target_player"
        print_status "Sent second /un${command_type} command for $target_player after 4 seconds"
        
        sleep 1
        send_server_command "/un${command_type} $target_player"
        print_status "Sent third /un${command_type} command for $target_player after 5 seconds"
        
        # Also remove from the list file after the final command
        remove_from_list_file "$target_player" "$command_type"
    ) &
}

initialize_economy() {
    if [ ! -f "$ECONOMY_FILE" ]; then
        echo '{"players": {}, "transactions": []}' > "$ECONOMY_FILE"
        print_success "Economy data file created: $ECONOMY_FILE"
    fi
    initialize_admin_offenses
}

is_player_in_list() {
    local player_name="$1"
    local list_type="$2"
    local world_dir=$(dirname "$LOG_FILE")
    local list_file="$world_dir/${list_type}list.txt"
    local lower_player_name=$(echo "$player_name" | tr '[:upper:]' '[:lower:]')
    if [ -f "$list_file" ]; then
        if grep -q "^$lower_player_name$" "$list_file"; then
            return 0
        fi
    fi
    return 1
}

add_player_if_new() {
    local player_name="$1"
    local current_data=$(cat "$ECONOMY_FILE")
    local player_exists=$(echo "$current_data" | jq --arg player "$player_name" '.players | has($player)')
    if [ "$player_exists" = "false" ]; then
        current_data=$(echo "$current_data" | jq --arg player "$player_name" '.players[$player] = {"tickets": 0, "last_login": 0, "last_welcome_time": 0, "last_help_time": 0, "purchases": []}')
        echo "$current_data" > "$ECONOMY_FILE"
        print_success "Added new player: $player_name"
        give_first_time_bonus "$player_name"
        return 0
    fi
    return 1
}

give_first_time_bonus() {
    local player_name="$1"
    local current_data=$(cat "$ECONOMY_FILE")
    local current_time=$(date +%s)
    local time_str="$(date '+%Y-%m-%d %H:%M:%S')"
    current_data=$(echo "$current_data" | jq --arg player "$player_name" '.players[$player].tickets = 1')
    current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson time "$current_time" '.players[$player].last_login = $time')
    current_data=$(echo "$current_data" | jq --arg player "$player_name" --arg time "$time_str" '.transactions += [{"player": $player, "type": "welcome_bonus", "tickets": 1, "time": $time}]')
    echo "$current_data" > "$ECONOMY_FILE"
    print_success "Gave first-time bonus to $player_name"
}

grant_login_ticket() {
    local player_name="$1"
    local current_time=$(date +%s)
    local time_str="$(date '+%Y-%m-%d %H:%M:%S')"
    local current_data=$(cat "$ECONOMY_FILE")
    local last_login=$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].last_login // 0')
    last_login=${last_login:-0}
    if [ "$last_login" -eq 0 ] || [ $((current_time - last_login)) -ge 3600 ]; then
        local current_tickets=$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].tickets // 0')
        current_tickets=${current_tickets:-0}
        local new_tickets=$((current_tickets + 1))
        current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson tickets "$new_tickets" '.players[$player].tickets = $tickets')
        current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson time "$current_time" '.players[$player].last_login = $time')
        current_data=$(echo "$current_data" | jq --arg player "$player_name" --arg time "$time_str" '.transactions += [{"player": $player, "type": "login_bonus", "tickets": 1, "time": $time}]')
        echo "$current_data" > "$ECONOMY_FILE"
        print_success "Granted 1 ticket to $player_name for logging in (Total: $new_tickets)"
        send_server_command "$player_name, you received 1 login ticket! You now have $new_tickets tickets."
    else
        local next_login=$((last_login + 3600))
        local time_left=$((next_login - current_time))
        print_warning "$player_name must wait $((time_left / 60)) minutes for next ticket"
    fi
}

show_welcome_message() {
    local player_name="$1"
    local is_new_player="$2"
    local force_send="${3:-0}"
    local current_time=$(date +%s)
    local current_data=$(cat "$ECONOMY_FILE")
    local last_welcome_time=$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].last_welcome_time // 0')
    last_welcome_time=${last_welcome:-0}
    if [ "$force_send" -eq 1 ] || [ "$last_welcome_time" -eq 0 ] || [ $((current_time - last_welcome_time)) -ge 180 ]; then
        if [ "$is_new_player" = "true" ]; then
            send_server_command "Hello $player_name! Welcome to the server. Type !tickets to check your ticket balance."
        else
            send_server_command "Welcome back $player_name! Type !economy_help to see economy commands."
        fi
        current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson time "$current_time" '.players[$player].last_welcome_time = $time')
        echo "$current_data" > "$ECONOMY_FILE"
    else
        print_warning "Skipping welcome for $player_name due to cooldown (use force to override)"
    fi
}

show_help_if_needed() {
    local player_name="$1"
    local current_time=$(date +%s)
    local current_data=$(cat "$ECONOMY_FILE")
    local last_help_time=$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].last_help_time // 0')
    last_help_time=${last_help_time:-0}
    if [ "$last_help_time" -eq 0 ] || [ $((current_time - last_help_time)) -ge 300 ]; then
        send_server_command "$player_name, type !economy_help to see economy commands."
        current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson time "$current_time" '.players[$player].last_help_time = $time')
        echo "$current_data" > "$ECONOMY_FILE"
    fi
}

send_server_command() {
    local message="$1"
    if screen -S "$SCREEN_SERVER" -X stuff "$message$(printf \\r)" 2>/dev/null; then
        print_success "Sent message to server: $message"
    else
        print_error "Could not send message to server. Is the server running?"
    fi
}

has_purchased() {
    local player_name="$1"
    local item="$2"
    local current_data=$(cat "$ECONOMY_FILE")
    local has_item=$(echo "$current_data" | jq --arg player "$player_name" --arg item "$item" '.players[$player].purchases | index($item) != null')
    if [ "$has_item" = "true" ]; then
        return 0
    else
        return 1
    fi
}

add_purchase() {
    local player_name="$1"
    local item="$2"
    local current_data=$(cat "$ECONOMY_FILE")
    current_data=$(echo "$current_data" | jq --arg player "$player_name" --arg item "$item" '.players[$player].purchases += [$item]')
    echo "$current_data" > "$ECONOMY_FILE"
}

# Function to handle unauthorized admin/mod commands
handle_unauthorized_command() {
    local player_name="$1"
    local command="$2"
    local target_player="$3"
    
    # Only track offenses for actual admins
    if is_player_in_list "$player_name" "admin"; then
        print_error "UNAUTHORIZED COMMAND: Admin $player_name attempted to use $command on $target_player"
        send_server_command "WARNING: Admin $player_name attempted unauthorized rank assignment!"
        
        # Determine command type
        local command_type=""
        if [ "$command" = "/admin" ]; then
            command_type="admin"
        elif [ "$command" = "/mod" ]; then
            command_type="mod"
        fi
        
        # Immediately revoke the rank that was attempted to be assigned
        if [ "$command_type" = "admin" ]; then
            send_server_command "/unadmin $target_player"
            # Also remove from adminlist.txt file directly
            remove_from_list_file "$target_player" "admin"
            print_success "Revoked admin rank from $target_player"
            
            # Send delayed unadmin commands
            send_delayed_uncommands "$target_player" "admin"
        elif [ "$command_type" = "mod" ]; then
            send_server_command "/unmod $target_player"
            # Also remove from modlist.txt file directly
            remove_from_list_file "$target_player" "mod"
            print_success "Revoked mod rank from $target_player"
            
            # Send delayed unmod commands
            send_delayed_uncommands "$target_player" "mod"
        fi
        
        # Record the offense
        record_admin_offense "$player_name"
        local offense_count=$?
        
        # First offense: warning
        if [ "$offense_count" -eq 1 ]; then
            send_server_command "$player_name, this is your first warning! Only the server console can assign ranks using !set_admin or !set_mod."
            print_warning "First offense recorded for admin $player_name"
        
        # Second offense within 5 minutes: demote to mod
        elif [ "$offense_count" -eq 2 ]; then
            print_warning "SECOND OFFENSE: Admin $player_name is being demoted to mod for unauthorized command usage"
            
            # Remove admin privileges
            send_server_command "/unadmin $player_name"
            remove_from_list_file "$player_name" "admin"
            
            # Assign mod rank
            send_server_command "/mod $player_name"
            send_server_command "ALERT: Admin $player_name has been demoted to moderator for repeatedly attempting unauthorized admin commands!"
            send_server_command "Only the server console can assign ranks using !set_admin or !set_mod."
            
            # Clear offenses after punishment
            clear_admin_offenses "$player_name"
        fi
    else
        # Non-admin players just get a warning and the command is blocked
        print_warning "Non-admin player $player_name attempted to use $command on $target_player"
        send_server_command "$player_name, you don't have permission to assign ranks. Only server admins can use !give_mod or !give_admin commands."
        
        # Immediately revoke the rank that was attempted to be assigned
        if [ "$command" = "/admin" ]; then
            send_server_command "/unadmin $target_player"
            # Also remove from adminlist.txt file directly
            remove_from_list_file "$target_player" "admin"
            
            # Send delayed unadmin commands
            send_delayed_uncommands "$target_player" "admin"
        elif [ "$command" = "/mod" ]; then
            send_server_command "/unmod $target_player"
            # Also remove from modlist.txt file directly
            remove_from_list_file "$target_player" "mod"
            
            # Send delayed unmod commands
            send_delayed_uncommands "$target_player" "mod"
        fi
    fi
}

process_message() {
    local player_name="$1"
    local message="$2"
    local current_data=$(cat "$ECONOMY_FILE")
    local player_tickets=$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].tickets // 0')
    player_tickets=${player_tickets:-0}
    case "$message" in
        "hi"|"hello"|"Hi"|"Hello"|"hola"|"Hola")
            send_server_command "Hello $player_name! Welcome to the server. Type !tickets to check your ticket balance."
            ;;
        "!tickets")
            send_server_command "$player_name, you have $player_tickets tickets."
            ;;
        "!buy_mod")
            if has_purchased "$player_name" "mod" || is_player_in_list "$player_name" "mod"; then
                send_server_command "$player_name, you already have MOD rank. No need to purchase again."
            elif [ "$player_tickets" -ge 10 ]; then
                local new_tickets=$((player_tickets - 10))
                local current_data=$(cat "$ECONOMY_FILE")
                current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson tickets "$new_tickets" '.players[$player].tickets = $tickets')
                add_purchase "$player_name" "mod"
                local time_str="$(date '+%Y-%m-%d %H:%M:%S')"
                current_data=$(echo "$current_data" | jq --arg player "$player_name" --arg time "$time_str" '.transactions += [{"player": $player, "type": "purchase", "item": "mod", "tickets": -10, "time": $time}]')
                echo "$current_data" > "$ECONOMY_FILE"
                
                screen -S "$SCREEN_SERVER" -X stuff "/mod $player_name$(printf \\r)"
                send_server_command "Congratulations $player_name! You have been promoted to MOD for 10 tickets. Remaining tickets: $new_tickets"
            else
                send_server_command "$player_name, you need $((10 - player_tickets)) more tickets to buy MOD rank."
            fi
            ;;
        "!buy_admin")
            if has_purchased "$player_name" "admin" || is_player_in_list "$player_name" "admin"; then
                send_server_command "$player_name, you already have ADMIN rank. No need to purchase again."
            elif [ "$player_tickets" -ge 20 ]; then
                local new_tickets=$((player_tickets - 20))
                local current_data=$(cat "$ECONOMY_FILE")
                current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson tickets "$new_tickets" '.players[$player].tickets = $tickets')
                add_purchase "$player_name" "admin"
                local time_str="$(date '+%Y-%m-%d %H:%M:%S')"
                current_data=$(echo "$current_data" | jq --arg player "$player_name" --arg time "$time_str" '.transactions += [{"player": $player, "type": "purchase", "item": "admin", "tickets": -20, "time": $time}]')
                echo "$current_data" > "$ECONOMY_FILE"
                
                screen -S "$SCREEN_SERVER" -X stuff "/admin $player_name$(printf \\r)"
                send_server_command "Congratulations $player_name! You have been promoted to ADMIN for 20 tickets. Remaining tickets: $new_tickets"
            else
                send_server_command "$player_name, you need $((20 - player_tickets)) more tickets to buy ADMIN rank."
            fi
            ;;
        "!give_mod")
            if [[ "$message" =~ ^!give_mod\ ([a-zA-Z0-9_]+)$ ]]; then
                local target_player="${BASH_REMATCH[1]}"
                if [ "$player_tickets" -ge 15 ]; then
                    local new_tickets=$((player_tickets - 15))
                    local current_data=$(cat "$ECONOMY_FILE")
                    current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson tickets "$new_tickets" '.players[$player].tickets = $tickets')
                    local time_str="$(date '+%Y-%m-%d %H:%M:%S')"
                    current_data=$(echo "$current_data" | jq --arg player "$player_name" --arg time "$time_str" --arg target "$target_player" '.transactions += [{"player": $player, "type": "gift_mod", "tickets": -15, "target": $target, "time": $time}]')
                    echo "$current_data" > "$ECONOMY_FILE"
                    
                    screen -S "$SCREEN_SERVER" -X stuff "/mod $target_player$(printf \\r)"
                    send_server_command "Congratulations! $player_name has gifted MOD rank to $target_player for 15 tickets."
                    send_server_command "$player_name, your remaining tickets: $new_tickets"
                else
                    send_server_command "$player_name, you need $((15 - player_tickets)) more tickets to gift MOD rank."
                fi
            else
                send_server_command "Usage: !give_mod PLAYERNAME"
            fi
            ;;
        "!give_admin")
            if [[ "$message" =~ ^!give_admin\ ([a-zA-Z0-9_]+)$ ]]; then
                local target_player="${BASH_REMATCH[1]}"
                if [ "$player_tickets" -ge 30 ]; then
                    local new_tickets=$((player_tickets - 30))
                    local current_data=$(cat "$ECONOMY_FILE")
                    current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson tickets "$new_tickets" '.players[$player].tickets = $tickets')
                    local time_str="$(date '+%Y-%m-%d %H:%M:%S')"
                    current_data=$(echo "$current_data" | jq --arg player "$player_name" --arg time "$time_str" --arg target "$target_player" '.transactions += [{"player": $player, "type": "gift_admin", "tickets": -30, "target": $target, "time": $time}]')
                    echo "$current_data" > "$ECONOMY_FILE"
                    
                    screen -S "$SCREEN_SERVER" -X stuff "/admin $target_player$(printf \\r)"
                    send_server_command "Congratulations! $player_name has gifted ADMIN rank to $target_player for 30 tickets."
                    send_server_command "$player_name, your remaining tickets: $new_tickets"
                else
                    send_server_command "$player_name, you need $((30 - player_tickets)) more tickets to gift ADMIN rank."
                fi
            else
                send_server_command "Usage: !give_admin PLAYERNAME"
            fi
            ;;
        "!set_admin"|"!set_mod")
            send_server_command "$player_name, these commands are only available to server console operators."
            send_server_command "Please use !give_admin or !give_mod instead if you want to gift ranks to other players."
            ;;
        "!economy_help")
            send_server_command "Economy commands:"
            send_server_command "!tickets - Check your tickets"
            send_server_command "!buy_mod - Buy MOD rank for 10 tickets"
            send_server_command "!buy_admin - Buy ADMIN rank for 20 tickets"
            send_server_command "!give_mod PLAYER - Gift MOD rank to another player for 15 tickets"
            send_server_command "!give_admin PLAYER - Gift ADMIN rank to another player for 30 tickets"
            ;;
    esac
}

process_admin_command() {
    local command="$1"
    local current_data=$(cat "$ECONOMY_FILE")
    if [[ "$command" =~ ^!send_ticket\ ([a-zA-Z0-9_]+)\ ([0-9]+)$ ]]; then
        local player_name="${BASH_REMATCH[1]}"
        local tickets_to_add="${BASH_REMATCH[2]}"
        local player_exists=$(echo "$current_data" | jq --arg player "$player_name" '.players | has($player)')
        if [ "$player_exists" = "false" ]; then
            print_error "Player $player_name not found in economy system"
            return
        fi
        local current_tickets=$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].tickets // 0')
        current_tickets=${current_tickets:-0}
        local new_tickets=$((current_tickets + tickets_to_add))
        current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson tickets "$new_tickets" '.players[$player].tickets = $tickets')
        local time_str="$(date '+%Y-%m-%d %H:%M:%S')"
        current_data=$(echo "$current_data" | jq --arg player "$player_name" --arg time "$time_str" --argjson amount "$tickets_to_add" '.transactions += [{"player": $player, "type": "admin_gift", "tickets": $amount, "time": $time}]')
        echo "$current_data" > "$ECONOMY_FILE"
        print_success "Added $tickets_to_add tickets to $player_name (Total: $new_tickets)"
        send_server_command "$player_name received $tickets_to_add tickets from admin! Total: $new_tickets"
    elif [[ "$command" =~ ^!set_mod\ ([a-zA-Z0-9_]+)$ ]]; then
        local player_name="${BASH_REMATCH[1]}"
        print_success "Setting $player_name as MOD"
        
        screen -S "$SCREEN_SERVER" -X stuff "/mod $player_name$(printf \\r)"
        send_server_command "$player_name has been set as MOD by server console!"
    elif [[ "$command" =~ ^!set_admin\ ([a-zA-Z0-9_]+)$ ]]; then
        local player_name="${BASH_REMATCH[1]}"
        print_success "Setting $player_name as ADMIN"
        
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
    local conn_epoch="${2:-0}"
    [ -z "$LOG_FILE" ] || [ ! -f "$LOG_FILE" ] && return 1

    local player_lc=$(echo "$player_name" | tr '[:upper:]' '[:lower:]')
    # Check the last few lines for a server welcome message
    local matches
    matches=$(tail -n "$TAIL_LINES" "$LOG_FILE" 2>/dev/null | grep -i "server:.*welcome.*$player_lc" | head -1)
    if [ -n "$matches" ]; then
        return 0
    fi
    return 1
}

filter_server_log() {
    while read line; do
        if [[ "$line" == *"Server closed"* ]] || [[ "$line" == *"Starting server"* ]]; then
            continue
        fi
        if [[ "$line" == *"SERVER: say"* && "$line" == *"Welcome"* ]]; then
            continue
        fi
        echo "$line"
    done
}

monitor_log() {
    local log_file="$1"
    LOG_FILE="$log_file"

    print_header "STARTING ECONOMY BOT"
    print_status "Monitoring: $log_file"
    print_status "Bot commands: !tickets, !buy_mod, !buy_admin, !give_mod, !give_admin, !economy_help"
    print_status "Admin commands: !send_ticket <player> <amount>, !set_mod <player>, !set_admin <player>"
    print_header "IMPORTANT: Admin commands must be typed in THIS terminal, NOT in the game chat!"
    print_status "Type admin commands below and press Enter:"
    print_header "READY FOR COMMANDS"

    local admin_pipe="/tmp/blockheads_admin_pipe_$$"
    rm -f "$admin_pipe"
    mkfifo "$admin_pipe"

    # Background process to read admin commands from the pipe
    while read -r admin_command < "$admin_pipe"; do
        print_status "Processing admin command: $admin_command"
        if [[ "$admin_command" == "!send_ticket "* ]] || [[ "$admin_command" == "!set_mod "* ]] || [[ "$admin_command" == "!set_admin "* ]]; then
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
    tail -n 0 -F "$log_file" | filter_server_log | while read line; do
        # Detect player connections
        if [[ "$line" =~ Player\ Connected\ ([a-zA-Z0-9_]+)\ \|\ ([0-9a-fA-F.:]+) ]]; then
            local player_name="${BASH_REMATCH[1]}"
            local player_ip="${BASH_REMATCH[2]}"
            [ "$player_name" == "SERVER" ] && continue

            print_success "Player connected: $player_name (IP: $player_ip)"

            # Extract timestamp
            ts_str=$(echo "$line" | awk '{print $1" "$2}')
            ts_no_ms=${ts_str%.*}
            conn_epoch=$(date -d "$ts_no_ms" +%s 2>/dev/null || echo 0)

            local is_new_player="false"
            add_player_if_new "$player_name" && is_new_player="true"

            # Wait a bit for server welcome
            sleep 3

            if ! server_sent_welcome_recently "$player_name" "$conn_epoch"; then
                show_welcome_message "$player_name" "$is_new_player" 1
            else
                print_warning "Server already welcomed $player_name"
            fi

            # Grant login ticket for returning players
            [ "$is_new_player" = "false" ] && grant_login_ticket "$player_name"

            continue
        fi

        # Detect unauthorized admin/mod commands
        if [[ "$line" =~ ([a-zA-Z0-9_]+):\ \/(admin|mod)\ ([a-zA-Z0-9_]+) ]]; then
            local command_user="${BASH_REMATCH[1]}"
            local command_type="${BASH_REMATCH[2]}"
            local target_player="${BASH_REMATCH[3]}"
            
            if [ "$command_user" != "SERVER" ]; then
                handle_unauthorized_command "$command_user" "/$command_type" "$target_player"
            fi
            continue
        fi

        if [[ "$line" =~ Player\ Disconnected\ ([a-zA-Z0-9_]+) ]]; then
            local player_name="${BASH_REMATCH[1]}"
            [ "$player_name" == "SERVER" ] && continue
            print_warning "Player disconnected: $player_name"
            unset welcome_shown["$player_name"]
            continue
        fi

        if [[ "$line" =~ ([a-zA-Z0-9_]+):\ (.+)$ ]]; then
            local player_name="${BASH_REMATCH[1]}"
            local message="${BASH_REMATCH[2]}"
            [ "$player_name" == "SERVER" ] && continue
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

if [ $# -eq 1 ] || [ $# -eq 2 ]; then
    initialize_economy
    monitor_log "$1"
else
    print_error "Usage: $0 <server_log_file> [port]"
    exit 1
fi
