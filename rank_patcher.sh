#!/bin/bash

# rank_patcher.sh - Player management system for The Blockheads server

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

print_status() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_header() {
    echo -e "${PURPLE}================================================================"
    echo -e "$1"
    echo -e "===============================================================${NC}"
}

BASE_DIR="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves"
CONSOLE_LOG="$1"
WORLD_ID="$2"
PORT="$3"

if [ -z "$WORLD_ID" ] && [ -n "$CONSOLE_LOG" ]; then
    WORLD_ID=$(echo "$CONSOLE_LOG" | grep -oE 'saves/[^/]+' | cut -d'/' -f2)
fi

if [ -z "$CONSOLE_LOG" ] || [ -z "$WORLD_ID" ]; then
    print_error "Usage: $0 <console_log_path> [world_id] [port]"
    print_status "Example: $0 /path/to/console.log world123 12153"
    exit 1
fi

PLAYERS_LOG="$BASE_DIR/$WORLD_ID/players.log"
ADMIN_LIST="$BASE_DIR/$WORLD_ID/adminlist.txt"
MOD_LIST="$BASE_DIR/$WORLD_ID/modlist.txt"
WHITELIST="$BASE_DIR/$WORLD_ID/whitelist.txt"
BLACKLIST="$BASE_DIR/$WORLD_ID/blacklist.txt"
CLOUD_ADMIN_LIST="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/cloudWideOwnedAdminlist.txt"

SCREEN_SERVER="blockheads_server_${PORT:-12153}"

PASSWORD_TIMEOUT=60
IP_VERIFY_TIMEOUT=30
SUPER_REMOVE_DELAY=15

declare -A connected_players
declare -A player_ip_map
declare -A password_pending
declare -A ip_verify_pending
declare -A password_timers
declare -A ip_verify_timers
declare -A ip_verified
declare -A last_player_states
declare -A super_remove_timers

send_server_command() {
    local command="$1"
    
    if ! screen -list | grep -q "$SCREEN_SERVER"; then
        print_error "Screen session not found: $SCREEN_SERVER"
        return 1
    fi
    
    if screen -S "$SCREEN_SERVER" -p 0 -X stuff "$command$(printf \\r)"; then
        print_success "Command sent to server: $command"
        return 0
    else
        print_error "Failed to send command to server: $command"
        return 1
    fi
}

kick_player() {
    local player_name="$1"
    local reason="$2"
    
    print_warning "Kicking player: $player_name - Reason: $reason"
    send_server_command "/kick $player_name"
}

clear_chat() {
    send_server_command "/clear"
}

initialize_players_log() {
    if [ ! -f "$PLAYERS_LOG" ]; then
        print_status "Creating new players.log file"
        mkdir -p "$(dirname "$PLAYERS_LOG")"
        touch "$PLAYERS_LOG"
        echo "# Player Name | First IP | Password | Rank | Whitelisted | Blacklisted" > "$PLAYERS_LOG"
        print_success "players.log created at: $PLAYERS_LOG"
    fi
}

read_players_log() {
    declare -gA players_data
    
    if [ ! -f "$PLAYERS_LOG" ]; then
        print_error "players.log not found: $PLAYERS_LOG"
        return 1
    fi
    
    while IFS='|' read -r name ip password rank whitelisted blacklisted; do
        [[ "$name" =~ ^# ]] && continue
        [[ -z "$name" ]] && continue
        
        name=$(echo "$name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        ip=$(echo "$ip" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        password=$(echo "$password" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        rank=$(echo "$rank" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        whitelisted=$(echo "$whitelisted" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        blacklisted=$(echo "$blacklisted" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        
        [ -z "$name" ] && name="UNKNOWN"
        [ -z "$ip" ] && ip="UNKNOWN"
        [ -z "$password" ] && password="NONE"
        [ -z "$rank" ] && rank="NONE"
        [ -z "$whitelisted" ] && whitelisted="NO"
        [ -z "$blacklisted" ] && blacklisted="NO"
        
        if [ "$name" != "UNKNOWN" ]; then
            players_data["$name,name"]="$name"
            players_data["$name,ip"]="$ip"
            players_data["$name,password"]="$password"
            players_data["$name,rank"]="$rank"
            players_data["$name,whitelisted"]="$whitelisted"
            players_data["$name,blacklisted"]="$blacklisted"
        fi
    done < "$PLAYERS_LOG"
}

update_players_log() {
    local player_name="$1" field="$2" new_value="$3"
    
    if [ -z "$player_name" ] || [ -z "$field" ]; then
        print_error "Invalid parameters for update_players_log"
        return 1
    fi
    
    read_players_log
    
    case "$field" in
        "ip") players_data["$player_name,ip"]="$new_value" ;;
        "password") players_data["$player_name,password"]="$new_value" ;;
        "rank") players_data["$player_name,rank"]="$new_value" ;;
        "whitelisted") players_data["$player_name,whitelisted"]="$new_value" ;;
        "blacklisted") players_data["$player_name,blacklisted"]="$new_value" ;;
        *) print_error "Unknown field: $field"; return 1 ;;
    esac
    
    {
        echo "# Player Name | First IP | Password | Rank | Whitelisted | Blacklisted"
        
        for key in "${!players_data[@]}"; do
            if [[ "$key" == *,name ]]; then
                local name="${players_data[$key]}"
                local ip="${players_data["$name,ip"]:-UNKNOWN}"
                local password="${players_data["$name,password"]:-NONE}"
                local rank="${players_data["$name,rank"]:-NONE}"
                local whitelisted="${players_data["$name,whitelisted"]:-NO}"
                local blacklisted="${players_data["$name,blacklisted"]:-NO}"
                
                echo "$name | $ip | $password | $rank | $whitelisted | $blacklisted"
            fi
        done
    } > "$PLAYERS_LOG"
    
    print_success "Updated players.log: $player_name $field = $new_value"
}

add_new_player() {
    local player_name="$1" player_ip="$2"
    
    if [ -z "$player_name" ] || [ -z "$player_ip" ]; then
        print_error "Invalid parameters for add_new_player"
        return 1
    fi
    
    read_players_log
    if [ -n "${players_data["$player_name,name"]}" ]; then
        print_warning "Player already exists: $player_name"
        return 0
    fi
    
    players_data["$player_name,name"]="$player_name"
    players_data["$player_name,ip"]="$player_ip"
    players_data["$player_name,password"]="NONE"
    players_data["$player_name,rank"]="NONE"
    players_data["$player_name,whitelisted"]="NO"
    players_data["$player_name,blacklisted"]="NO"
    
    {
        echo "# Player Name | First IP | Password | Rank | Whitelisted | Blacklisted"
        
        for key in "${!players_data[@]}"; do
            if [[ "$key" == *,name ]]; then
                local name="${players_data[$key]}"
                local ip="${players_data["$name,ip"]:-UNKNOWN}"
                local password="${players_data["$name,password"]:-NONE}"
                local rank="${players_data["$name,rank"]:-NONE}"
                local whitelisted="${players_data["$name,whitelisted"]:-NO}"
                local blacklisted="${players_data["$name,blacklisted"]:-NO}"
                
                echo "$name | $ip | $password | $rank | $whitelisted | $blacklisted"
            fi
        done
    } > "$PLAYERS_LOG"
    
    print_success "Added new player: $player_name ($player_ip)"
}

is_ip_verified() {
    local player_name="$1"
    local current_ip="$2"
    
    read_players_log
    local stored_ip="${players_data["$player_name,ip"]}"
    
    if [ "$stored_ip" = "UNKNOWN" ] || [ "$stored_ip" = "$current_ip" ]; then
        ip_verified["$player_name"]=1
        return 0
    fi
    
    ip_verified["$player_name"]=0
    return 1
}

start_password_timeout() {
    local player_name="$1"
    
    print_warning "Starting password timeout for $player_name (60 seconds)"
    
    if [ -n "${password_timers[$player_name]}" ]; then
        kill "${password_timers[$player_name]}" 2>/dev/null
    fi
    
    (
        sleep $PASSWORD_TIMEOUT
        if [ -n "${password_pending[$player_name]}" ]; then
            print_warning "Password timeout reached for $player_name - kicking player"
            kick_player "$player_name" "No password set within 60 seconds"
            unset password_pending["$player_name"]
            unset password_timers["$player_name"]
        fi
    ) &
    password_timers["$player_name"]=$!
}

start_ip_verify_timeout() {
    local player_name="$1" player_ip="$2"
    
    print_warning "Starting IP verification timeout for $player_name (30 seconds)"
    
    if [ -n "${ip_verify_timers[$player_name]}" ]; then
        kill "${ip_verify_timers[$player_name]}" 2>/dev/null
    fi
    
    (
        sleep $IP_VERIFY_TIMEOUT
        if [ -n "${ip_verify_pending[$player_name]}" ]; then
            print_warning "IP verification timeout reached for $player_name - kicking and banning IP"
            kick_player "$player_name" "IP verification failed within 30 seconds"
            send_server_command "/ban $player_ip"
            unset ip_verify_pending["$player_name"]
            unset ip_verify_timers["$player_name"]
        fi
    ) &
    ip_verify_timers["$player_name"]=$!
}

start_super_remove_timer() {
    local player_name="$1"
    
    print_warning "Starting SUPER remove timer for $player_name (15 seconds)"
    
    if [ -n "${super_remove_timers[$player_name]}" ]; then
        kill "${super_remove_timers[$player_name]}" 2>/dev/null
    fi
    
    (
        sleep $SUPER_REMOVE_DELAY
        remove_player_from_cloud_list "$player_name"
        unset super_remove_timers["$player_name"]
    ) &
    super_remove_timers["$player_name"]=$!
}

cancel_super_remove_timer() {
    local player_name="$1"
    
    if [ -n "${super_remove_timers[$player_name]}" ]; then
        kill "${super_remove_timers[$player_name]}" 2>/dev/null
        unset super_remove_timers["$player_name"]
        print_success "Cancelled SUPER remove timer for $player_name"
    fi
}

send_password_reminder() {
    local player_name="$1"
    
    (
        sleep 5
        if [ -n "${password_pending[$player_name]}" ]; then
            send_server_command "Welcome $player_name! Please set a password using: !password YOUR_PASSWORD CONFIRM_PASSWORD within 60 seconds."
        fi
    ) &
}

send_ip_warning() {
    local player_name="$1"
    
    (
        sleep 5
        if [ -n "${ip_verify_pending[$player_name]}" ]; then
            send_server_command "SECURITY ALERT: $player_name, your IP has changed! Verify with: !ip_change YOUR_PASSWORD within 30 seconds or you will be kicked and IP banned."
        fi
    ) &
}

validate_password() {
    local password="$1"
    local length=${#password}
    
    if [ $length -lt 7 ] || [ $length -gt 16 ]; then
        echo "Password must be between 7 and 16 characters"
        return 1
    fi
    
    if ! echo "$password" | grep -qE '^[A-Za-z0-9!@#$%^_+-=]+$'; then
        echo "Password contains invalid characters. Only letters, numbers and !@#$%^_+-= are allowed"
        return 1
    fi
    
    return 0
}

handle_password_command() {
    local player_name="$1" password="$2" confirm_password="$3"
    
    clear_chat
    
    if [ "$password" != "$confirm_password" ]; then
        send_server_command "Passwords do not match"
        return 1
    fi
    
    local validation_result
    validation_result=$(validate_password "$password")
    if [ $? -ne 0 ]; then
        send_server_command "$validation_result"
        return 1
    fi
    
    update_players_log "$player_name" "password" "$password"
    send_server_command "Password set successfully for $player_name"
    
    if [ -n "${password_timers[$player_name]}" ]; then
        kill "${password_timers[$player_name]}" 2>/dev/null
        unset password_timers["$player_name"]
    fi
    unset password_pending["$player_name"]
    
    return 0
}

handle_ip_change() {
    local player_name="$1" provided_password="$2" current_ip="$3"
    
    clear_chat
    
    read_players_log
    local stored_password="${players_data["$player_name,password"]}"
    
    if [ "$stored_password" = "NONE" ]; then
        send_server_command "No password set for $player_name. Use !password first."
        return 1
    fi
    
    if [ "$provided_password" != "$stored_password" ]; then
        send_server_command "Incorrect password for IP verification"
        return 1
    fi
    
    update_players_log "$player_name" "ip" "$current_ip"
    send_server_command "IP address verified and updated for $player_name"
    
    if [ -n "${ip_verify_timers[$player_name]}" ]; then
        kill "${ip_verify_timers[$player_name]}" 2>/dev/null
        unset ip_verify_timers["$player_name"]
    fi
    unset ip_verify_pending["$player_name"]
    ip_verified["$player_name"]=1
    
    print_success "IP verified for $player_name - applying ranks"
    
    apply_player_ranks "$player_name"
    sync_server_lists
    
    return 0
}

add_player_to_cloud_list() {
    local player_name="$1"
    
    if [ ! -f "$CLOUD_ADMIN_LIST" ]; then
        touch "$CLOUD_ADMIN_LIST"
    fi
    
    # Check if player is already in the list (ignoring first line)
    if ! tail -n +2 "$CLOUD_ADMIN_LIST" | grep -q "^$player_name$"; then
        # Add player to cloud admin list
        echo "$player_name" >> "$CLOUD_ADMIN_LIST"
        print_success "Added $player_name to cloud admin list"
    fi
}

remove_player_from_cloud_list() {
    local player_name="$1"
    
    if [ -f "$CLOUD_ADMIN_LIST" ]; then
        # Remove player from cloud admin list (ignoring first line)
        temp_file=$(mktemp)
        head -n 1 "$CLOUD_ADMIN_LIST" > "$temp_file" 2>/dev/null
        tail -n +2 "$CLOUD_ADMIN_LIST" | grep -v "^$player_name$" >> "$temp_file"
        mv "$temp_file" "$CLOUD_ADMIN_LIST"
        print_success "Removed $player_name from cloud admin list"
    fi
}

apply_player_ranks() {
    local player_name="$1"
    
    read_players_log
    local rank="${players_data["$player_name,rank"]}"
    local whitelisted="${players_data["$player_name,whitelisted"]}"
    local blacklisted="${players_data["$player_name,blacklisted"]}"
    local current_ip="${player_ip_map[$player_name]}"
    
    if [ "${ip_verified[$player_name]}" = "1" ] && [ -n "${connected_players[$player_name]}" ]; then
        # Apply rank commands
        case "$rank" in
            "ADMIN")
                send_server_command "/admin $player_name"
                # Remove from MOD if was MOD before
                send_server_command "/unmod $player_name"
                # Remove from cloud admin list
                remove_player_from_cloud_list "$player_name"
                cancel_super_remove_timer "$player_name"
                print_success "Applied ADMIN rank to $player_name"
                ;;
            "MOD")
                send_server_command "/mod $player_name"
                # Remove from ADMIN if was ADMIN before
                send_server_command "/unadmin $player_name"
                # Remove from cloud admin list
                remove_player_from_cloud_list "$player_name"
                cancel_super_remove_timer "$player_name"
                print_success "Applied MOD rank to $player_name"
                ;;
            "SUPER")
                # Add to cloud admin list directly (no server command for SUPER)
                add_player_to_cloud_list "$player_name"
                # Remove from ADMIN and MOD
                send_server_command "/unadmin $player_name"
                send_server_command "/unmod $player_name"
                cancel_super_remove_timer "$player_name"
                print_success "Applied SUPER rank to $player_name"
                ;;
            "NONE")
                # Remove all ranks
                send_server_command "/unadmin $player_name"
                send_server_command "/unmod $player_name"
                # Remove from cloud admin list after delay if disconnected
                if [ -z "${connected_players[$player_name]}" ]; then
                    start_super_remove_timer "$player_name"
                else
                    remove_player_from_cloud_list "$player_name"
                    cancel_super_remove_timer "$player_name"
                fi
                print_success "Removed all ranks from $player_name"
                ;;
        esac
        
        # Apply whitelist/blacklist commands
        if [ "$whitelisted" = "YES" ]; then
            send_server_command "/whitelist $player_name"
            print_success "Whitelisted $player_name"
        else
            send_server_command "/unwhitelist $player_name"
            print_success "Unwhitelisted $player_name"
        fi
        
        if [ "$blacklisted" = "YES" ]; then
            send_server_command "/ban-no-device $player_name"
            if [ "$current_ip" != "UNKNOWN" ]; then
                send_server_command "/ban-no-device $current_ip"
            fi
            print_success "Banned $player_name"
        else
            send_server_command "/unban $player_name"
            if [ "$current_ip" != "UNKNOWN" ]; then
                send_server_command "/unban $current_ip"
            fi
            print_success "Unbanned $player_name"
        fi
    fi
}

remove_player_from_all_lists() {
    local player_name="$1"
    
    # Remove from admin list
    if [ -f "$ADMIN_LIST" ]; then
        temp_file=$(mktemp)
        grep -v "^$player_name$" "$ADMIN_LIST" > "$temp_file"
        mv "$temp_file" "$ADMIN_LIST"
    fi
    
    # Remove from mod list
    if [ -f "$MOD_LIST" ]; then
        temp_file=$(mktemp)
        grep -v "^$player_name$" "$MOD_LIST" > "$temp_file"
        mv "$temp_file" "$MOD_LIST"
    fi
    
    # Remove from whitelist
    if [ -f "$WHITELIST" ]; then
        temp_file=$(mktemp)
        grep -v "^$player_name$" "$WHITELIST" > "$temp_file"
        mv "$temp_file" "$WHITELIST"
    fi
    
    # Remove from blacklist
    if [ -f "$BLACKLIST" ]; then
        temp_file=$(mktemp)
        grep -v "^$player_name$" "$BLACKLIST" > "$temp_file"
        mv "$temp_file" "$BLACKLIST"
    fi
    
    # Remove from cloud admin list after delay
    start_super_remove_timer "$player_name"
    
    print_success "Removed $player_name from all server lists"
}

sync_server_lists() {
    print_status "Syncing server lists from players.log..."
    
    read_players_log
    
    # Clear all lists
    for list_file in "$ADMIN_LIST" "$MOD_LIST" "$WHITELIST" "$BLACKLIST"; do
        > "$list_file"
    done
    
    # Add players to appropriate lists based on their current state
    for key in "${!players_data[@]}"; do
        if [[ "$key" == *,name ]]; then
            local name="${players_data[$key]}"
            local ip="${players_data["$name,ip"]}"
            local rank="${players_data["$name,rank"]}"
            local whitelisted="${players_data["$name,whitelisted"]}"
            local blacklisted="${players_data["$name,blacklisted"]}"
            local current_ip="${player_ip_map[$name]}"
            
            # Only add to lists if IP is verified and player is connected
            if [ -n "${connected_players[$name]}" ] && [ "${ip_verified[$name]}" = "1" ]; then
                case "$rank" in
                    "ADMIN")
                        echo "$name" >> "$ADMIN_LIST"
                        ;;
                    "MOD")
                        echo "$name" >> "$MOD_LIST"
                        ;;
                esac
                
                if [ "$whitelisted" = "YES" ]; then
                    echo "$name" >> "$WHITELIST"
                fi
                
                if [ "$blacklisted" = "YES" ]; then
                    echo "$name" >> "$BLACKLIST"
                fi
            elif [ -n "${connected_players[$name]}" ] && [ -n "${ip_verify_pending[$name]}" ]; then
                print_warning "Player $name connected with different IP - rank privileges suspended until verification"
            fi
        fi
    done
    
    print_success "Server lists synced"
}

monitor_players_log_changes() {
    local current_time=$(date +%s)
    static last_check_time=0
    
    # Check for changes every 2 seconds
    if [ $((current_time - last_check_time)) -lt 2 ]; then
        return
    fi
    last_check_time=$current_time
    
    if [ ! -f "$PLAYERS_LOG" ]; then
        return
    fi
    
    # Read current state
    declare -A current_players_data
    read_players_log
    
    # Initialize last_player_states if empty
    if [ ${#last_player_states[@]} -eq 0 ]; then
        for key in "${!players_data[@]}"; do
            last_player_states["$key"]="${players_data[$key]}"
        done
        return
    fi
    
    # Detect changes and apply commands
    for key in "${!players_data[@]}"; do
        if [[ "$key" == *,name ]]; then
            local player_name="${players_data[$key]}"
            local current_rank="${players_data["$player_name,rank"]}"
            local current_whitelisted="${players_data["$player_name,whitelisted"]}"
            local current_blacklisted="${players_data["$player_name,blacklisted"]}"
            
            local last_rank="${last_player_states["$player_name,rank"]:-NONE}"
            local last_whitelisted="${last_player_states["$player_name,whitelisted"]:-NO}"
            local last_blacklisted="${last_player_states["$player_name,blacklisted"]:-NO}"
            
            # Check for rank changes
            if [ "$current_rank" != "$last_rank" ]; then
                print_status "Rank change detected for $player_name: $last_rank -> $current_rank"
                if [ -n "${connected_players[$player_name]}" ] && [ "${ip_verified[$player_name]}" = "1" ]; then
                    apply_player_ranks "$player_name"
                fi
            fi
            
            # Check for whitelist changes
            if [ "$current_whitelisted" != "$last_whitelisted" ]; then
                print_status "Whitelist change detected for $player_name: $last_whitelisted -> $current_whitelisted"
                if [ -n "${connected_players[$player_name]}" ] && [ "${ip_verified[$player_name]}" = "1" ]; then
                    apply_player_ranks "$player_name"
                fi
            fi
            
            # Check for blacklist changes
            if [ "$current_blacklisted" != "$last_blacklisted" ]; then
                print_status "Blacklist change detected for $player_name: $last_blacklisted -> $current_blacklisted"
                if [ -n "${connected_players[$player_name]}" ] && [ "${ip_verified[$player_name]}" = "1" ]; then
                    apply_player_ranks "$player_name"
                fi
            fi
        fi
    done
    
    # Update last known state
    for key in "${!players_data[@]}"; do
        last_player_states["$key"]="${players_data[$key]}"
    done
}

monitor_console_log() {
    print_header "Starting rank_patcher monitoring"
    print_status "World: $WORLD_ID"
    print_status "Console log: $CONSOLE_LOG"
    print_status "Players log: $PLAYERS_LOG"
    
    initialize_players_log
    sync_server_lists
    
    tail -n 0 -F "$CONSOLE_LOG" | while read line; do
        if [[ "$line" =~ Player\ Connected\ ([a-zA-Z0-9_]+)\ \|\ ([0-9a-fA-F.:]+)\ \|\ ([0-9a-f]+) ]]; then
            local player_name="${BASH_REMATCH[1]}"
            local player_ip="${BASH_REMATCH[2]}"
            local player_hash="${BASH_REMATCH[3]}"
            
            print_success "Player connected: $player_name ($player_ip) - Hash: $player_hash"
            
            connected_players["$player_name"]=1
            player_ip_map["$player_name"]="$player_ip"
            
            # Cancel SUPER remove timer if player reconnects
            cancel_super_remove_timer "$player_name"
            
            read_players_log
            if [ -z "${players_data["$player_name,name"]}" ]; then
                add_new_player "$player_name" "$player_ip"
                
                ip_verified["$player_name"]=1
                password_pending["$player_name"]=1
                start_password_timeout "$player_name"
                send_password_reminder "$player_name"
                
                apply_player_ranks "$player_name"
            else
                local stored_ip="${players_data["$player_name,ip"]}"
                local stored_password="${players_data["$player_name,password"]}"
                local stored_rank="${players_data["$player_name,rank"]}"
                
                if is_ip_verified "$player_name" "$player_ip"; then
                    print_success "IP verified for $player_name"
                    ip_verified["$player_name"]=1
                    
                    if [ "$stored_rank" != "NONE" ]; then
                        apply_player_ranks "$player_name"
                    fi
                else
                    print_warning "IP change detected for $player_name: $stored_ip -> $player_ip"
                    ip_verified["$player_name"]=0
                    ip_verify_pending["$player_name"]=1
                    start_ip_verify_timeout "$player_name" "$player_ip"
                    send_ip_warning "$player_name"
                    
                    if [ "$stored_rank" = "ADMIN" ]; then
                        send_server_command "/unadmin $player_name"
                        print_warning "Temporarily removed ADMIN rank from $player_name pending IP verification"
                    elif [ "$stored_rank" = "MOD" ]; then
                        send_server_command "/unmod $player_name"
                        print_warning "Temporarily removed MOD rank from $player_name pending IP verification"
                    fi
                fi
                
                if [ "$stored_password" = "NONE" ]; then
                    password_pending["$player_name"]=1
                    start_password_timeout "$player_name"
                    send_password_reminder "$player_name"
                fi
            fi
            
            sync_server_lists
            continue
        fi
        
        if [[ "$line" =~ Player\ Disconnected\ ([a-zA-Z0-9_]+) ]]; then
            local player_name="${BASH_REMATCH[1]}"
            
            print_warning "Player disconnected: $player_name"
            
            # Remove player from all lists immediately
            remove_player_from_all_lists "$player_name"
            
            unset connected_players["$player_name"]
            unset player_ip_map["$player_name"]
            unset ip_verified["$player_name"]
            
            if [ -n "${password_timers[$player_name]}" ]; then
                kill "${password_timers[$player_name]}" 2>/dev/null
                unset password_timers["$player_name"]
            fi
            if [ -n "${ip_verify_timers[$player_name]}" ]; then
                kill "${ip_verify_timers[$player_name]}" 2>/dev/null
                unset ip_verify_timers["$player_name"]
            fi
            
            unset password_pending["$player_name"]
            unset ip_verify_pending["$player_name"]
            
            sync_server_lists
            continue
        fi
        
        if [[ "$line" =~ ([a-zA-Z0-9_]+):\ (.+)$ ]]; then
            local player_name="${BASH_REMATCH[1]}"
            local message="${BASH_REMATCH[2]}"
            
            [ "$player_name" = "SERVER" ] && continue
            
            case "$message" in
                "!password "*)
                    if [[ "$message" =~ !password\ ([^ ]+)\ ([^ ]+) ]]; then
                        local password="${BASH_REMATCH[1]}"
                        local confirm_password="${BASH_REMATCH[2]}"
                        print_status "Password command received from $player_name"
                        handle_password_command "$player_name" "$password" "$confirm_password"
                    else
                        send_server_command "Usage: !password NEW_PASSWORD CONFIRM_PASSWORD"
                    fi
                    ;;
                "!ip_change "*)
                    if [[ "$message" =~ !ip_change\ ([^ ]+) ]]; then
                        local password="${BASH_REMATCH[1]}"
                        local current_ip="${player_ip_map[$player_name]}"
                        print_status "IP change command received from $player_name"
                        handle_ip_change "$player_name" "$password" "$current_ip"
                    else
                        send_server_command "Usage: !ip_change YOUR_PASSWORD"
                    fi
                    ;;
            esac
        fi
    done
}

periodic_tasks() {
    while true; do
        sleep 2
        sync_server_lists
        monitor_players_log_changes
    done
}

main() {
    print_header "THE BLOCKHEADS RANK PATCHER"
    print_status "Starting player management system..."
    
    if [ ! -f "$CONSOLE_LOG" ]; then
        print_error "Console log not found: $CONSOLE_LOG"
        print_status "Waiting for log file to be created..."
        
        local wait_time=0
        while [ ! -f "$CONSOLE_LOG" ] && [ $wait_time -lt 30 ]; do
            sleep 1
            ((wait_time++))
        done
        
        if [ ! -f "$CONSOLE_LOG" ]; then
            print_error "Console log never appeared: $CONSOLE_LOG"
            exit 1
        fi
    fi
    
    monitor_console_log &
    local console_pid=$!
    
    periodic_tasks &
    local tasks_pid=$!
    
    print_success "All monitoring processes started"
    print_status "Console PID: $console_pid"
    print_status "Tasks PID: $tasks_pid"
    
    wait $console_pid $tasks_pid
}

main "$@"
