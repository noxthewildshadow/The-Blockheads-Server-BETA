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
AUTHORIZED_BLACKLIST_FILE="authorized_blacklist.txt"
SCAN_INTERVAL=5
SERVER_WELCOME_WINDOW=15
TAIL_LINES=500

# Function to initialize authorization files
initialize_authorization_files() {
    local world_dir=$(dirname "$LOG_FILE")
    local auth_admins="$world_dir/$AUTHORIZED_ADMINS_FILE"
    local auth_mods="$world_dir/$AUTHORIZED_MODS_FILE"
    local auth_blacklist="$world_dir/$AUTHORIZED_BLACKLIST_FILE"
    
    [ ! -f "$auth_admins" ] && touch "$auth_admins" && print_success "Created authorized admins file: $auth_admins"
    [ ! -f "$auth_mods" ] && touch "$auth_mods" && print_success "Created authorized mods file: $auth_mods"
    [ ! -f "$auth_blacklist" ] && touch "$auth_blacklist" && print_success "Created authorized blacklist file: $auth_blacklist"
    
    # Add default banned players (xero and packets) if they don't exist
    if [ -f "$auth_blacklist" ]; then
        if ! grep -q -i "^xero$" "$auth_blacklist"; then
            echo "xero" >> "$auth_blacklist"
            print_success "Added xero to authorized blacklist"
        fi
        if ! grep -q -i "^packets$" "$auth_blacklist"; then
            echo "packets" >> "$auth_blacklist"
            print_success "Added packets to authorized blacklist"
        fi
    fi
}

# Function to check and correct admin/mod/black lists
validate_authorization() {
    local world_dir=$(dirname "$LOG_FILE")
    local auth_admins="$world_dir/$AUTHORIZED_ADMINS_FILE"
    local auth_mods="$world_dir/$AUTHORIZED_MODS_FILE"
    local auth_blacklist="$world_dir/$AUTHORIZED_BLACKLIST_FILE"
    local admin_list="$world_dir/adminlist.txt"
    local mod_list="$world_dir/modlist.txt"
    local black_list="$world_dir/blacklist.txt"
    
    # Check adminlist.txt against authorized_admins.txt
    if [ -f "$admin_list" ]; then
        while IFS= read -r admin; do
            if [[ -n "$admin" && ! "$admin" =~ ^[[:space:]]*# && ! "$admin" =~ "Usernames in this file" ]]; then
                if ! grep -q -i "^$admin$" "$auth_admins"; then
                    print_warning "Unauthorized admin detected: $admin"
                    send_server_command_silent "/unadmin $admin"
                    remove_from_list_file "$admin" "admin"
                    print_success "Removed unauthorized admin: $admin"
                fi
            fi
        done < <(grep -v "^[[:space:]]*#" "$admin_list")
    fi
    
    # Check modlist.txt against authorized_mods.txt
    if [ -f "$mod_list" ]; then
        while IFS= read -r mod; do
            if [[ -n "$mod" && ! "$mod" =~ ^[[:space:]]*# && ! "$mod" =~ "Usernames in this file" ]]; then
                if ! grep -q -i "^$mod$" "$auth_mods"; then
                    print_warning "Unauthorized mod detected: $mod"
                    send_server_command_silent "/unmod $mod"
                    remove_from_list_file "$mod" "mod"
                    print_success "Removed unauthorized mod: $mod"
                fi
            fi
        done < <(grep -v "^[[:space:]]*#" "$mod_list")
    fi
    
    # Check blacklist.txt against authorized_blacklist.txt
    if [ -f "$black_list" ] && [ -f "$auth_blacklist" ]; then
        # First, ensure all authorized banned players are in blacklist.txt
        while IFS= read -r banned_player; do
            if [[ -n "$banned_player" && ! "$banned_player" =~ ^[[:space:]]*# ]]; then
                if ! grep -v "^[[:space:]]*#" "$black_list" | grep -q -i "^$banned_player$"; then
                    print_warning "Authorized banned player $banned_player not found in blacklist.txt, adding..."
                    send_server_command_silent "/ban $banned_player"
                    # Also add to blacklist.txt file directly
                    echo "$banned_player" >> "$black_list"
                    print_success "Added $banned_player to blacklist.txt"
                fi
            fi
        done < <(grep -v "^[[:space:]]*#" "$auth_blacklist")
        
        # Second, remove any players from blacklist.txt that aren't in authorized_blacklist.txt
        while IFS= read -r banned_player; do
            if [[ -n "$banned_player" && ! "$banned_player" =~ ^[[:space:]]*# && ! "$banned_player" =~ "Usernames in this file" ]]; then
                if ! grep -q -i "^$banned_player$" "$auth_blacklist"; then
                    print_warning "Non-authorized banned player detected: $banned_player"
                    send_server_command_silent "/unban $banned_player"
                    remove_from_list_file "$banned_player" "black"
                    print_success "Removed non-authorized banned player: $banned_player"
                fi
            fi
        done < <(grep -v "^[[:space:]]*#" "$black_list")
    fi
}

# Function to add player to authorized list
add_to_authorized() {
    local player_name="$1" list_type="$2"
    local world_dir=$(dirname "$LOG_FILE")
    local auth_file="$world_dir/authorized_${list_type}s.txt"
    
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

# Function to remove player from authorized list
remove_from_authorized() {
    local player_name="$1" list_type="$2"
    local world_dir=$(dirname "$LOG_FILE")
    local auth_file="$world_dir/authorized_${list_type}s.txt"
    local lower_player_name=$(echo "$player_name" | tr '[:upper:]' '[:lower:]')
    
    [ ! -f "$auth_file" ] && print_error "Authorization file not found: $auth_file" && return 1
    
    if grep -q -i "^$lower_player_name$" "$auth_file"; then
        sed -i "/^$lower_player_name$/Id" "$auth_file"
        print_success "Removed $player_name from authorized ${list_type}s"
        return 0
    else
        print_warning "Player $player_name not found in authorized ${list_type}s"
        return 1
    fi
}

# Initialize admin offenses tracking
initialize_admin_offenses() {
    [ ! -f "$ADMIN_OFFENSES_FILE" ] && echo '{}' > "$ADMIN_OFFENSES_FILE" && 
    print_success "Admin offenses tracking file created: $ADMIN_OFFENSES_FILE"
}

# Function to record admin offense
record_admin_offense() {
    local admin_name="$1" current_time=$(date +%s)
    local offenses_data=$(cat "$ADMIN_OFFENSES_FILE" 2>/dev/null || echo '{}')
    local current_offenses=$(echo "$offenses_data" | jq -r --arg admin "$admin_name" '.[$admin]?.count // 0')
    local last_offense_time=$(echo "$offenses_data" | jq -r --arg admin "$admin_name" '.[$admin]?.last_offense // 0')
    
    [ $((current_time - last_offense_time)) -gt 300 ] && current_offenses=0
    current_offenses=$((current_offenses + 1))
    
    offenses_data=$(echo "$offenses_data" | jq --arg admin "$admin_name" \
        --argjson count "$current_offenses" --argjson time "$current_time" \
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
    local player_name="$1" list_type="$2"
    local world_dir=$(dirname "$LOG_FILE")
    local list_file="$world_dir/${list_type}list.txt"
    local lower_player_name=$(echo "$player_name" | tr '[:upper:]' '[:lower:]')
    
    [ ! -f "$list_file" ] && print_error "List file not found: $list_file" && return 1
    
    if grep -v "^[[:space:]]*#" "$list_file" | grep -q "^$lower_player_name$"; then
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
    local target_player="$1" command_type="$2"
    (
        sleep 2; send_server_command_silent "/un${command_type} $target_player"
        sleep 2; send_server_command_silent "/un${command_type} $target_player"
        sleep 1; send_server_command_silent "/un${command_type} $target_player"
        remove_from_list_file "$target_player" "$command_type"
    ) &
}

# Silent version of send_server_command
send_server_command_silent() {
    screen -S "$SCREEN_SERVER" -X stuff "$1$(printf \\r)" 2>/dev/null
}

initialize_economy() {
    [ ! -f "$ECONOMY_FILE" ] && echo '{"players": {}, "transactions": []}' > "$ECONOMY_FILE" &&
    print_success "Economy data file created: $ECONOMY_FILE"
    initialize_admin_offenses
}

is_player_in_list() {
    local player_name="$1" list_type="$2"
    local world_dir=$(dirname "$LOG_FILE")
    local list_file="$world_dir/${list_type}list.txt"
    local lower_player_name=$(echo "$player_name" | tr '[:upper:]' '[:lower:]')
    
    [ -f "$list_file" ] && grep -v "^[[:space:]]*#" "$list_file" | grep -q "^$lower_player_name$" && return 0
    return 1
}

add_player_if_new() {
    local player_name="$1"
    local current_data=$(cat "$ECONOMY_FILE")
    local player_exists=$(echo "$current_data" | jq --arg player "$player_name" '.players | has($player)')
    
    if [ "$player_exists" = "false" ]; then
        current_data=$(echo "$current_data" | jq --arg player "$player_name" \
            '.players[$player] = {"tickets": 0, "last_login": 0, "last_welcome_time": 0, "last_help_time": 0, "last_greeting_time": 0, "purchases": []}')
        echo "$current_data" > "$ECONOMY_FILE"
        print_success "Added new player: $player_name"
        give_first_time_bonus "$player_name"
        return 0
    fi
    return 1
}

give_first_time_bonus() {
    local player_name="$1" current_time=$(date +%s) time_str="$(date '+%Y-%m-%d %H:%M:%S')"
    local current_data=$(cat "$ECONOMY_FILE")
    current_data=$(echo "$current_data" | jq --arg player "$player_name" '.players[$player].tickets = 1')
    current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson time "$current_time" '.players[$player].last_login = $time')
    current_data=$(echo "$current_data" | jq --arg player "$player_name" --arg time "$time_str" \
        '.transactions += [{"player": $player, "type": "welcome_bonus", "tickets": 1, "time": $time}]')
    echo "$current_data" > "$ECONOMY_FILE"
    print_success "Gave first-time bonus to $player_name"
}

grant_login_ticket() {
    local player_name="$1" current_time=$(date +%s) time_str="$(date '+%Y-%m-%d %H:%M:%S')"
    local current_data=$(cat "$ECONOMY_FILE")
    local last_login=$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].last_login // 0')
    last_login=${last_login:-0}
    
    if [ "$last_login" -eq 0 ] || [ $((current_time - last_login)) -ge 3600 ]; then
        local current_tickets=$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].tickets // 0')
        current_tickets=${current_tickets:-0}
        local new_tickets=$((current_tickets + 1))
        current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson tickets "$new_tickets" '.players[$player].tickets = $tickets')
        current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson time "$current_time" '.players[$player].last_login = $time')
        current_data=$(echo "$current_data" | jq --arg player "$player_name" --arg time "$time_str" \
            '.transactions += [{"player": $player, "type": "login_bonus", "tickets": 1, "time": $time}]')
        echo "$current_data" > "$ECONOMY_FILE"
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
    local current_data=$(cat "$ECONOMY_FILE")
    local last_welcome_time=$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].last_welcome_time // 0')
    last_welcome_time=${last_welcome_time:-0}
    
    if [ "$force_send" -eq 1 ] || [ "$last_welcome_time" -eq 0 ] || [ $((current_time - last_welcome_time)) -ge 180 ]; then
        if [ "$is_new_player" = "true" ]; then
            send_server_command "Hello $player_name! Welcome to the server. Type !tickets to check your ticket balance."
        else
            local last_greeting_time=$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].last_greeting_time // 0')
            if [ $((current_time - last_greeting_time)) -ge 600 ]; then
                send_server_command "Welcome back $player_name! Type !economy_help to see economy commands."
                # Update last_greeting_time to prevent spam
                current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson time "$current_time" '.players[$player].last_greeting_time = $time')
            fi
        fi
        current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson time "$current_time" '.players[$player].last_welcome_time = $time')
        echo "$current_data" > "$ECONOMY_FILE"
    else
        print_warning "Skipping welcome for $player_name due to cooldown"
    fi
}

show_help_if_needed() {
    local player_name="$1" current_time=$(date +%s)
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
    if screen -S "$SCREEN_SERVER" -X stuff "$1$(printf \\r)" 2>/dev/null; then
        print_success "Sent message to server: $1"
    else
        print_error "Could not send message to server. Is the server running?"
    fi
}

has_purchased() {
    local player_name="$1" item="$2"
    local current_data=$(cat "$ECONOMY_FILE")
    local has_item=$(echo "$current_data" | jq --arg player "$player_name" --arg item "$item" '.players[$player].purchases | index($item) != null')
    [ "$has_item" = "true" ] && return 0 || return 1
}

add_purchase() {
    local player_name="$1" item="$2"
    local current_data=$(cat "$ECONOMY_FILE")
    current_data=$(echo "$current_data" | jq --arg player "$player_name" --arg item "$item" '.players[$player].purchases += [$item]')
    echo "$current_data" > "$ECONOMY_FILE"
}

# Function to handle unauthorized admin/mod commands
handle_unauthorized_command() {
    local player_name="$1" command="$2" target_player="$3"
    
    if is_player_in_list "$player_name" "admin"; then
        print_error "UNAUTHORIZED COMMAND: Admin $player_name attempted to use $command on $target_player"
        send_server_command "WARNING: Admin $player_name attempted unauthorized rank assignment!"
        
        local command_type=""
        [ "$command" = "/admin" ] && command_type="admin"
        [ "$command" = "/mod" ] && command_type="mod"
        
        if [ -n "$command_type" ]; then
            send_server_command_silent "/un${command_type} $target_player"
            remove_from_list_file "$target_player" "$command_type"
            print_success "Revoked ${command_type} rank from $target_player"
            send_delayed_uncommands "$target_player" "$command_type"
        fi
        
        record_admin_offense "$player_name"
        local offense_count=$?
        
        if [ "$offense_count" -eq 1 ]; then
            send_server_command "$player_name, this is your first warning! Only the server console can assign ranks using !set_admin or !set_mod."
            print_warning "First offense recorded for admin $player_name"
        elif [ "$offense_count" -eq 2 ]; then
            print_warning "SECOND OFFENSE: Admin $player_name is being demoted to mod for unauthorized command usage"
            
            # First add to authorized mods before removing admin privileges
            add_to_authorized "$player_name" "mod"
            
            # Remove from authorized admins
            remove_from_authorized "$player_name" "admin"
            
            # Remove admin privileges
            send_server_command_silent "/unadmin $player_name"
            remove_from_list_file "$player_name" "admin"
            
            # Assign mod rank - ensure the player is added to modlist before sending the command
            send_server_command "/mod $player_name"
            send_server_command "ALERT: Admin $player_name has been demoted to moderator for repeatedly attempting unauthorized admin commands!"
            send_server_command "Only the server console can assign ranks using !set_admin or !set_mod."
            
            # Clear offenses after punishment
            clear_admin_offenses "$player_name"
        fi
    else
        print_warning "Non-admin player $player_name attempted to use $command on $target_player"
        send_server_command "$player_name, you don't have permission to assign ranks."
        
        if [ "$command" = "/admin" ]; then
            send_server_command_silent "/unadmin $target_player"
            remove_from_list_file "$target_player" "admin"
            send_delayed_uncommands "$target_player" "admin"
        elif [ "$command" = "/mod" ]; then
            send_server_command_silent "/unmod $target_player"
            remove_from_list_file "$target_player" "mod"
            send_delayed_uncommands "$target_player" "mod"
        fi
    fi
}

process_message() {
    local player_name="$1" message="$2"
    local current_data=$(cat "$ECONOMY_FILE")
    local player_tickets=$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].tickets // 0')
    player_tickets=${player_tickets:-0}
    
    case "$message" in
        "hi"|"hello"|"Hi"|"Hello"|"hola"|"Hola")
            local current_time=$(date +%s)
            local last_greeting_time=$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].last_greeting_time // 0')
            
            # 10-minute cooldown for greetings
            if [ "$last_greeting_time" -eq 0 ] || [ $((current_time - last_greeting_time)) -ge 600 ]; then
                send_server_command "Hello $player_name! Welcome to the server. Type !tickets to check your ticket balance."
                # Update last_greeting_time
                current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson time "$current_time" '.players[$player].last_greeting_time = $time')
                echo "$current_data" > "$ECONOMY_FILE"
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
                echo "$current_data" > "$ECONOMY_FILE"
                
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
                echo "$current_data" > "$ECONOMY_FILE"
                
                # First add to authorized admins, then assign rank
                add_to_authorized "$player_name" "admin"
                screen -S "$SCREEN_SERVER" -X stuff "/admin $player_name$(printf \\r)"
                send_server_command "Congratulations $player_name! You have been promoted to ADMIN for 100 tickets. Remaining tickets: $new_tickets"
            else
                send_server_command "$player_name, you need $((100 - player_tickets)) more tickets to buy ADMIN rank."
            fi
            ;;
        "!set_admin"|"!set_mod")
            send_server_command "$player_name, these commands are only available to server console operators."
            ;;
        "!economy_help")
            send_server_command "Economy commands:"
            send_server_command "!tickets - Check your tickets"
            send_server_command "!buy_mod - Buy MOD rank for 50 tickets"
            send_server_command "!buy_admin - Buy ADMIN rank for 100 tickets"
            ;;
    esac
}

process_admin_command() {
    local command="$1" current_data=$(cat "$ECONOMY_FILE")
    
    if [[ "$command" =~ ^!send_ticket\ ([a-zA-Z0-9_]+)\ ([0-9]+)$ ]]; then
        local player_name="${BASH_REMATCH[1]}" tickets_to_add="${BASH_REMATCH[2]}"
        local player_exists=$(echo "$current_data" | jq --arg player "$player_name" '.players | has($player)')
        [ "$player_exists" = "false" ] && print_error "Player $player_name not found in economy system" && return
        
        local current_tickets=$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].tickets // 0')
        current_tickets=${current_tickets:-0}
        local new_tickets=$((current_tickets + tickets_to_add))
        current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson tickets "$new_tickets" '.players[$player].tickets = $tickets')
        local time_str="$(date '+%Y-%m-%d %H:%M:%S')"
        current_data=$(echo "$current_data" | jq --arg player "$player_name" --arg time "$time_str" --argjson amount "$tickets_to_add" \
            '.transactions += [{"player": $player, "type": "admin_gift", "tickets": $amount, "time": $time}]')
        echo "$current_data" > "$ECONOMY_FILE"
        print_success "Added $tickets_to_add tickets to $player_name (Total: $new_tickets)"
        send_server_command "$player_name received $tickets_to_add tickets from admin! Total: $new_tickets"
    elif [[ "$command" =~ ^!set_mod\ ([a-zA-Z0-9_]+)$ ]]; then
        local player_name="${BASH_REMATCH[1]}"
        print_success "Setting $player_name as MOD"
        # First add to authorized mods, then assign rank
        add_to_authorized "$player_name" "mod"
        screen -S "$SCREEN_SERVER" -X stuff "/mod $player_name$(printf \\r)"
        send_server_command "$player_name has been set as MOD by server console!"
    elif [[ "$command" =~ ^!set_admin\ ([a-zA-Z0-9_]+)$ ]]; then
        local player_name="${BASH_REMATCH[1]}"
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
    local player_name="$1" conn_epoch="${2:-0}"
    [ -z "$LOG_FILE" ] || [ ! -f "$LOG_FILE" ] && return 1
    local player_lc=$(echo "$player_name" | tr '[:upper:]' '[:lower:]')
    tail -n "$TAIL_LINES" "$LOG_FILE" 2>/dev/null | grep -i "server:.*welcome.*$player_lc" | head -1 | grep -q . && return 0
    return 1
}

filter_server_log() {
    while read line; do
        [[ "$line" == *"Server closed"* || "$line" == *"Starting server"* || \
          ("$line" == *"SERVER: say"* && "$line" == *"Welcome"*) || \
          "$line" == *"adminlist.txt"* || "$line" == *"modlist.txt"* || "$line" == *"blacklist.txt"* ]] && continue
        echo "$line"
    done
}

monitor_log() {
    local log_file="$1"
    LOG_FILE="$log_file"

    initialize_authorization_files

    # Start authorization validation in background
    (
        while true; do sleep 3; validate_authorization; done
    ) &
    local validation_pid=$!

    print_header "STARTING ECONOMY BOT"
    print_status "Monitoring: $log_file"
    print_status "Bot commands: !tickets, !buy_mod, !buy_admin, !economy_help"
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
    tail -n 0 -F "$log_file" | filter_server_log | while read line; do
        # Detect player connections
        if [[ "$line" =~ Player\ Connected\ ([a-zA-Z0-9_]+)\ \|\ ([0-9a-fA-F.:]+) ]]; then
            local player_name="${BASH_REMATCH[1]}" player_ip="${BASH_REMATCH[2]}"
            [ "$player_name" == "SERVER" ] && continue

            print_success "Player connected: $player_name (IP: $player_ip)"

            # Extract timestamp
            ts_str=$(echo "$line" | awk '{print $1" "$2}')
            ts_no_ms=${ts_str%.*}
            conn_epoch=$(date -d "$ts_no_ms" +%s 2>/dev/null || echo 0)

            local is_new_player="false"
            add_player_if_new "$player_name" && is_new_player="true"

            sleep 3

            if ! server_sent_welcome_recently "$player_name" "$conn_epoch"; then
                show_welcome_message "$player_name" "$is_new_player" 1
            else
                print_warning "Server already welcomed $player_name"
            fi

            [ "$is_new_player" = "false" ] && grant_login_ticket "$player_name"
            continue
        fi

        # Detect unauthorized admin/mod commands
        if [[ "$line" =~ ([a-zA-Z0-9_]+):\ \/(admin|mod)\ ([a-zA-Z0-9_]+) ]]; then
            local command_user="${BASH_REMATCH[1]}" command_type="${BASH_REMATCH[2]}" target_player="${BASH_REMATCH[3]}"
            [ "$command_user" != "SERVER" ] && handle_unauthorized_command "$command_user" "/$command_type" "$target_player"
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
            local player_name="${BASH_REMATCH[1]}" message="${BASH_REMATCH[2]}"
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
    kill $validation_pid 2>/dev/null
}

if [ $# -eq 1 ] || [ $# -eq 2 ]; then
    initialize_economy
    monitor_log "$1"
else
    print_error "Usage: $0 <server_log_file> [port]"
    exit 1
fi
