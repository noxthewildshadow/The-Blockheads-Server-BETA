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

# Authorization files
AUTHORIZED_ADMINS_FILE="authorized_admins.txt"
AUTHORIZED_MODS_FILE="authorized_mods.txt"

SCAN_INTERVAL=5
SERVER_WELCOME_WINDOW=15
TAIL_LINES=500

# Function to initialize authorization files
initialize_authorization_files() {
    local world_dir=$(dirname "$LOG_FILE")
    local auth_admins="$world_dir/$AUTHORIZED_ADMINS_FILE"
    local auth_mods="$world_dir/$AUTHORIZED_MODS_FILE"
    
    if [ ! -f "$auth_admins" ]; then
        touch "$auth_admins"
        print_success "Created authorized admins file: $auth_admins"
    fi
    
    if [ ! -f "$auth_mods" ]; then
        touch "$auth_mods"
        print_success "Created authorized mods file: $auth_mods"
    fi
}

# Function to check and correct admin/mod lists
validate_authorization() {
    local world_dir=$(dirname "$LOG_FILE")
    local auth_admins="$world_dir/$AUTHORIZED_ADMINS_FILE"
    local auth_mods="$world_dir/$AUTHORIZED_MODS_FILE"
    local admin_list="$world_dir/adminlist.txt"
    local mod_list="$world_dir/modlist.txt"
    
    # Check adminlist.txt against authorized_admins.txt
    if [ -f "$admin_list" ]; then
        # Usar archivo temporal para evitar problemas con while read
        grep -v "^[[:space:]]*#" "$admin_list" | while IFS= read -r admin; do
            # Skip empty lines and comment-like lines
            if [[ -n "$admin" && ! "$admin" =~ ^[[:space:]]*# && ! "$admin" =~ "Usernames in this file" ]]; then
                if ! grep -q -i "^$admin$" "$auth_admins"; then
                    print_warning "Unauthorized admin detected: $admin"
                    send_server_command "/unadmin $admin"
                    remove_from_list_file "$admin" "admin"
                    print_success "Removed unauthorized admin: $admin"
                fi
            fi
        done
    fi
    
    # Check modlist.txt against authorized_mods.txt
    if [ -f "$mod_list" ]; then
        grep -v "^[[:space:]]*#" "$mod_list" | while IFS= read -r mod; do
            # Skip empty lines and comment-like lines
            if [[ -n "$mod" && ! "$mod" =~ ^[[:space:]]*# && ! "$mod" =~ "Usernames in this file" ]]; then
                if ! grep -q -i "^$mod$" "$auth_mods"; then
                    print_warning "Unauthorized mod detected: $mod"
                    send_server_command "/unmod $mod"
                    remove_from_list_file "$mod" "mod"
                    print_success "Removed unauthorized mod: $mod"
                fi
            fi
        done
    fi
}

# Function to add player to authorized list
add_to_authorized() {
    local player_name="$1"
    local list_type="$2"  # "admin" or "mod"
    local world_dir=$(dirname "$LOG_FILE")
    local auth_file="$world_dir/authorized_${list_type}s.txt"
    
    if [ ! -f "$auth_file" ]; then
        print_error "Authorization file not found: $auth_file"
        return 1
    fi
    
    # Add player if not already in the file
    if ! grep -q -i "^$player_name$" "$auth_file"; then
        echo "$player_name" >> "$auth_file"
        print_success "Added $player_name to authorized ${list_type}s"
        return 0
    else
        print_warning "$player_name is already in authorized ${list_type}s"
        return 1
    fi
}

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
    
    # Remove the player from the list file (only non-comment lines)
    if grep -v "^[[:space:]]*#" "$list_file" | grep -q "^$lower_player_name$"; then
        # Use sed to remove the player name (case-insensitive)
        sed -i "/^$lower_player_name$/Id" "$list_file"
        print_success "Removed $player_name from ${list_type}list.txt"
        return 0
    else
        print_warning "Player $player_name not found in ${list_type}list.txt"
        return 1
    fi
}

# Function to send delayed unadmin/unmod commands (SILENT VERSION)
send_delayed_uncommands() {
    local target_player="$1"
    local command_type="$2"  # "admin" or "mod"
    
    (
        sleep 2
        send_server_command_silent "/un${command_type} $target_player"
        
        sleep 2
        send_server_command_silent "/un${command_type} $target_player"
        
        sleep 1
        send_server_command_silent "/un${command_type} $target_player"
        
        # Also remove from the list file after the final command
        remove_from_list_file "$target_player" "$command_type"
    ) &
}

# Silent version of send_server_command
send_server_command_silent() {
    local message="$1"
    screen -S "$SCREEN_SERVER" -X stuff "$message$(printf \\r)" 2>/dev/null
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
        # Skip comment lines when checking
        if grep -v "^[[:space:]]*#" "$list_file" | grep -q "^$lower_player_name$"; then
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
    last_welcome_time=${last_welcome_time:-0}
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
            send_server_command_silent "/unadmin $target_player"
            # Also remove from adminlist.txt file directly
            remove_from_list_file "$target_player" "admin"
            print_success "Revoked admin rank from $target_player"
            
            # Send delayed unadmin commands (silent)
            send_delayed_uncommands "$target_player" "admin"
        elif [ "$command_type" = "mod" ]; then
            send_server_command_silent "/unmod $target_player"
            # Also remove from modlist.txt file directly
            remove_from_list_file "$target_player" "mod"
            print_success "Revoked mod rank from $target_player"
            
            # Send delayed unmod commands (silent)
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
            send_server_command_silent "/unadmin $player_name"
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
            send_server_command_silent "/unadmin $target_player"
            # Also remove from adminlist.txt file directly
            remove_from_list_file "$target_player" "admin"
            
            # Send delayed unadmin commands (silent)
            send_delayed_uncommands "$target_player" "admin"
        elif [ "$command" = "/mod" ]; then
            send_server_command_silent "/unmod $target_player"
            # Also remove from modlist.txt file directly
            remove_from_list_file "$target_player" "mod"
            
            # Send delayed unmod commands (silent)
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
                add_to_authorized "$player_name" "mod"
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
                add_to_authorized "$player_name" "admin"
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
                    add_to_authorized "$target_player" "mod"
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


                    screen -S "$SCREEN_SERVER" -X stuff "/mod $target_player$(printf \\r)"
                    add_to_authorized "$target_player" "mod"
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
                    add_to_authorized "$target_player" "admin"
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
