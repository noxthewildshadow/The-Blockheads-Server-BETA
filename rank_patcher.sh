#!/bin/bash

# rank_patcher.sh - The Blockheads Server Rank Management System
# Completely fixed version based on old project analysis

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

print_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_status() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_debug() { [ "$DEBUG" = "true" ] && echo -e "${CYAN}[DEBUG]${NC} $1"; }

# Configuration
SERVER_HOME="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads"
SCREEN_SESSION=""
WORLD_ID=""
CURRENT_PORT=""

# Global arrays for player management
declare -A player_data
declare -A player_current_ips
declare -A player_connection_time
declare -A active_timers

# Function to wait for cooldown
wait_cooldown() {
    sleep 0.5
}

# Function to send command to server screen
send_server_command() {
    local command="$1"
    
    if [ -n "$SCREEN_SESSION" ] && screen -list | grep -q "$SCREEN_SESSION"; then
        screen -S "$SCREEN_SESSION" -p 0 -X stuff "$command"$'\n'
        print_debug "Sent command: $command"
        return 0
    else
        print_error "Screen session not found: $SCREEN_SESSION"
        return 1
    fi
}

# Function to clear chat
clear_chat() {
    send_server_command "/clear"
}

# Function to send message to player
send_player_message() {
    local player="$1"
    local message="$2"
    send_server_command "/msg $player $message"
}

# Function to find world directory
find_world_directory() {
    local saves_dir="$SERVER_HOME/saves"
    
    for world in "$saves_dir"/*; do
        if [ -f "$world/console.log" ]; then
            WORLD_ID=$(basename "$world")
            print_success "Found world: $WORLD_ID"
            
            # Extract port from console.log
            if [ -f "$world/console.log" ]; then
                local port_line=$(grep "Loading world.*on port" "$world/console.log" | head -1)
                if [[ "$port_line" =~ on\ port\ ([0-9]+) ]]; then
                    CURRENT_PORT="${BASH_REMATCH[1]}"
                    print_success "Server port: $CURRENT_PORT"
                fi
            fi
            return 0
        fi
    done
    
    print_error "No world with console.log found"
    return 1
}

# Function to find screen session
find_screen_session() {
    local session=$(screen -list | grep "blockheads_server" | awk -F. '{print $1}' | head -1)
    if [ -n "$session" ]; then
        echo "$session"
        return 0
    fi
    return 1
}

# Function to initialize players.log
initialize_players_log() {
    local world_dir="$SERVER_HOME/saves/$WORLD_ID"
    local players_log="$world_dir/players.log"
    
    if [ ! -f "$players_log" ]; then
        print_status "Creating players.log..."
        echo "# PLAYER_NAME | IP | PASSWORD | RANK | WHITELISTED | BLACKLISTED" > "$players_log"
        print_success "players.log created"
    fi
}

# Function to load player data
load_player_data() {
    local world_dir="$SERVER_HOME/saves/$WORLD_ID"
    local players_log="$world_dir/players.log"
    
    if [ ! -f "$players_log" ]; then
        print_warning "players.log not found"
        return
    fi
    
    # Clear existing data
    player_data=()
    
    # Load from file (skip header)
    while IFS='|' read -r name ip password rank whitelisted blacklisted; do
        # Clean and uppercase
        name=$(echo "$name" | xargs | tr '[:lower:]' '[:upper:]')
        ip=$(echo "$ip" | xargs | tr '[:lower:]' '[:upper:]')
        password=$(echo "$password" | xargs | tr '[:lower:]' '[:upper:]')
        rank=$(echo "$rank" | xargs | tr '[:lower:]' '[:upper:]')
        whitelisted=$(echo "$whitelisted" | xargs | tr '[:lower:]' '[:upper:]')
        blacklisted=$(echo "$blacklisted" | xargs | tr '[:lower:]' '[:upper:]')
        
        # Skip header/empty
        if [[ "$name" == "# PLAYER_NAME" || -z "$name" ]]; then
            continue
        fi
        
        # Set defaults
        ip="${ip:-UNKNOWN}"
        password="${password:-NONE}"
        rank="${rank:-NONE}"
        whitelisted="${whitelisted:-NO}"
        blacklisted="${blacklisted:-NO}"
        
        # Store in array
        player_data["$name"]="$ip|$password|$rank|$whitelisted|$blacklisted"
        
    done < <(tail -n +2 "$players_log")
    
    print_success "Loaded ${#player_data[@]} players"
}

# Function to save player data
save_player_data() {
    local world_dir="$SERVER_HOME/saves/$WORLD_ID"
    local players_log="$world_dir/players.log"
    local temp_file=$(mktemp)
    
    # Write header
    echo "# PLAYER_NAME | IP | PASSWORD | RANK | WHITELISTED | BLACKLISTED" > "$temp_file"
    
    # Write player data
    for player in "${!player_data[@]}"; do
        IFS='|' read -r ip password rank whitelisted blacklisted <<< "${player_data[$player]}"
        echo "$player | $ip | $password | $rank | $whitelisted | $blacklisted" >> "$temp_file"
    done
    
    # Atomic replace
    mv "$temp_file" "$players_log"
}

# Function to update player info
update_player_info() {
    local player="$1" ip="$2" password="$3" rank="$4" whitelisted="$5" blacklisted="$6"
    
    player=$(echo "$player" | tr '[:lower:]' '[:upper:]')
    ip=$(echo "$ip" | tr '[:lower:]' '[:upper:]')
    password=$(echo "$password" | tr '[:lower:]' '[:upper:]')
    rank=$(echo "$rank" | tr '[:lower:]' '[:upper:]')
    whitelisted=$(echo "$whitelisted" | tr '[:lower:]' '[:upper:]')
    blacklisted=$(echo "$blacklisted" | tr '[:lower:]' '[:upper:]')
    
    # Set defaults
    ip="${ip:-UNKNOWN}"
    password="${password:-NONE}"
    rank="${rank:-NONE}"
    whitelisted="${whitelisted:-NO}"
    blacklisted="${blacklisted:-NO}"
    
    # Store in array
    player_data["$player"]="$ip|$password|$rank|$whitelisted|$blacklisted"
    
    save_player_data
    print_debug "Updated player: $player"
}

# Function to get player info
get_player_info() {
    local player="$1"
    player=$(echo "$player" | tr '[:lower:]' '[:upper:]')
    echo "${player_data[$player]}"
}

# Function to get player field
get_player_field() {
    local player="$1" field="$2"
    local info=$(get_player_info "$player")
    IFS='|' read -r ip password rank whitelisted blacklisted <<< "$info"
    
    case $field in
        "ip") echo "$ip" ;;
        "password") echo "$password" ;;
        "rank") echo "$rank" ;;
        "whitelisted") echo "$whitelisted" ;;
        "blacklisted") echo "$blacklisted" ;;
        *) echo "" ;;
    esac
}

# Function to update server lists
update_server_lists() {
    local world_dir="$SERVER_HOME/saves/$WORLD_ID"
    
    update_admin_list "$world_dir/adminlist.txt"
    update_mod_list "$world_dir/modlist.txt"
    update_whitelist "$world_dir/whitelist.txt"
    update_blacklist "$world_dir/blacklist.txt"
    update_cloud_admin_list
}

# Function to update admin list
update_admin_list() {
    local file="$1"
    local temp_file=$(mktemp)
    
    # Preserve first line
    if [ -f "$file" ] && [ -s "$file" ]; then
        head -n 1 "$file" > "$temp_file"
    else
        echo "ADMIN LIST" > "$temp_file"
    fi
    
    # Add verified ADMIN players
    for player in "${!player_data[@]}"; do
        local ip=$(get_player_field "$player" "ip")
        local rank=$(get_player_field "$player" "rank")
        local blacklisted=$(get_player_field "$player" "blacklisted")
        
        if [[ "$ip" != "UNKNOWN" && "$rank" == "ADMIN" && "$blacklisted" != "YES" ]]; then
            echo "$player" >> "$temp_file"
        fi
    done
    
    mv "$temp_file" "$file"
}

# Function to update mod list
update_mod_list() {
    local file="$1"
    local temp_file=$(mktemp)
    
    # Preserve first line
    if [ -f "$file" ] && [ -s "$file" ]; then
        head -n 1 "$file" > "$temp_file"
    else
        echo "MOD LIST" > "$temp_file"
    fi
    
    # Add verified MOD players
    for player in "${!player_data[@]}"; do
        local ip=$(get_player_field "$player" "ip")
        local rank=$(get_player_field "$player" "rank")
        local blacklisted=$(get_player_field "$player" "blacklisted")
        
        if [[ "$ip" != "UNKNOWN" && "$rank" == "MOD" && "$blacklisted" != "YES" ]]; then
            echo "$player" >> "$temp_file"
        fi
    done
    
    mv "$temp_file" "$file"
}

# Function to update whitelist
update_whitelist() {
    local file="$1"
    local temp_file=$(mktemp)
    
    # Preserve first line
    if [ -f "$file" ] && [ -s "$file" ]; then
        head -n 1 "$file" > "$temp_file"
    else
        echo "WHITELIST" > "$temp_file"
    fi
    
    # Add verified whitelisted players
    for player in "${!player_data[@]}"; do
        local ip=$(get_player_field "$player" "ip")
        local whitelisted=$(get_player_field "$player" "whitelisted")
        
        if [[ "$ip" != "UNKNOWN" && "$whitelisted" == "YES" ]]; then
            echo "$player" >> "$temp_file"
        fi
    done
    
    mv "$temp_file" "$file"
}

# Function to update blacklist
update_blacklist() {
    local file="$1"
    local temp_file=$(mktemp)
    
    # Preserve first line
    if [ -f "$file" ] && [ -s "$file" ]; then
        head -n 1 "$file" > "$temp_file"
    else
        echo "BLACKLIST" > "$temp_file"
    fi
    
    # Add blacklisted players
    for player in "${!player_data[@]}"; do
        local blacklisted=$(get_player_field "$player" "blacklisted")
        
        if [[ "$blacklisted" == "YES" ]]; then
            echo "$player" >> "$temp_file"
        fi
    done
    
    mv "$temp_file" "$file"
}

# Function to update cloud admin list
update_cloud_admin_list() {
    local cloud_file="$SERVER_HOME/cloudWideOwnedAdminlist.txt"
    local temp_file=$(mktemp)
    local has_super=false
    
    # Preserve first line
    if [ -f "$cloud_file" ] && [ -s "$cloud_file" ]; then
        head -n 1 "$cloud_file" > "$temp_file"
    else
        echo "CLOUD WIDE ADMIN LIST" > "$temp_file"
    fi
    
    # Add SUPER players
    for player in "${!player_data[@]}"; do
        local rank=$(get_player_field "$player" "rank")
        local blacklisted=$(get_player_field "$player" "blacklisted")
        
        if [[ "$rank" == "SUPER" && "$blacklisted" != "YES" ]]; then
            echo "$player" >> "$temp_file"
            has_super=true
        fi
    done
    
    # Only keep file if SUPER admins exist
    if [ "$has_super" = true ]; then
        mv "$temp_file" "$cloud_file"
    else
        rm -f "$cloud_file" 2>/dev/null
        rm -f "$temp_file" 2>/dev/null
    fi
}

# Function to handle rank changes
handle_rank_change() {
    local player="$1" old_rank="$2" new_rank="$3"
    
    print_status "Rank change: $player $old_rank -> $new_rank"
    
    case "$new_rank" in
        "ADMIN")
            if [[ "$old_rank" == "NONE" ]]; then
                wait_cooldown
                send_server_command "/admin $player"
            fi
            ;;
        "MOD")
            if [[ "$old_rank" == "NONE" ]]; then
                wait_cooldown
                send_server_command "/mod $player"
            fi
            ;;
        "SUPER")
            update_cloud_admin_list
            ;;
        "NONE")
            if [[ "$old_rank" == "ADMIN" ]]; then
                wait_cooldown
                send_server_command "/unadmin $player"
            elif [[ "$old_rank" == "MOD" ]]; then
                wait_cooldown
                send_server_command "/unmod $player"
            elif [[ "$old_rank" == "SUPER" ]]; then
                update_cloud_admin_list
            fi
            ;;
    esac
    
    update_server_lists
}

# Function to handle blacklist changes
handle_blacklist_change() {
    local player="$1" old_status="$2" new_status="$3"
    
    if [[ "$new_status" == "YES" ]]; then
        print_status "Blacklisting: $player"
        
        # Remove privileges
        wait_cooldown
        send_server_command "/unmod $player"
        wait_cooldown
        send_server_command "/unadmin $player"
        
        # Ban player and IP
        wait_cooldown
        send_server_command "/ban $player"
        local ip=$(get_player_field "$player" "ip")
        if [[ "$ip" != "UNKNOWN" ]]; then
            wait_cooldown
            send_server_command "/ban $ip"
        fi
        
        # Remove from cloud admin if SUPER
        if [[ $(get_player_field "$player" "rank") == "SUPER" ]]; then
            wait_cooldown
            send_server_command "/stop"
            update_cloud_admin_list
        fi
    fi
    
    update_server_lists
}

# Function to monitor players.log
monitor_players_log() {
    local world_dir="$SERVER_HOME/saves/$WORLD_ID"
    local players_log="$world_dir/players.log"
    local last_hash=""
    
    print_status "Monitoring players.log..."
    
    while true; do
        if [ ! -f "$players_log" ]; then
            sleep 1
            continue
        fi
        
        local current_hash=$(md5sum "$players_log" 2>/dev/null | cut -d' ' -f1)
        
        if [[ "$current_hash" != "$last_hash" ]]; then
            print_debug "players.log changed"
            
            # Backup old data
            declare -A old_ranks
            declare -A old_blacklisted
            for player in "${!player_data[@]}"; do
                old_ranks["$player"]=$(get_player_field "$player" "rank")
                old_blacklisted["$player"]=$(get_player_field "$player" "blacklisted")
            done
            
            # Reload data
            load_player_data
            
            # Check for changes
            for player in "${!player_data[@]}"; do
                local new_rank=$(get_player_field "$player" "rank")
                local old_rank="${old_ranks[$player]}"
                local new_blacklisted=$(get_player_field "$player" "blacklisted")
                local old_blacklisted="${old_blacklisted[$player]}"
                
                if [[ "$new_rank" != "$old_rank" ]]; then
                    handle_rank_change "$player" "$old_rank" "$new_rank"
                fi
                
                if [[ "$new_blacklisted" != "$old_blacklisted" ]]; then
                    handle_blacklist_change "$player" "$old_blacklisted" "$new_blacklisted"
                fi
            done
            
            last_hash="$current_hash"
        fi
        
        sleep 1
    done
}

# Function to extract player connection
extract_player_connection() {
    local line="$1"
    # Format: "PLOT_HEAVEN - Player Connected THE_WILD_SHADOW | 187.233.203.236 | 4bfa1c98bac22c53d7f5ababad64438b"
    if [[ "$line" =~ ([A-Za-z0-9_]+)\ -\ Player\ Connected\ ([A-Za-z0-9_]+)\ \|\ ([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)\ \|\ [a-f0-9]+ ]]; then
        local world="${BASH_REMATCH[1]}"
        local player="${BASH_REMATCH[2]}"
        local ip="${BASH_REMATCH[3]}"
        echo "$player" "$ip"
        return 0
    fi
    return 1
}

# Function to extract chat message
extract_chat_message() {
    local line="$1"
    # Format: "2025-09-21 16:49:47.146 blockheads_server171[739070:739070] TAOTAO83465: Hi"
    if [[ "$line" =~ [0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]+\ [^\ ]+\]\ ([A-Za-z0-9_]+):\ (.+) ]]; then
        local player="${BASH_REMATCH[1]}"
        local message="${BASH_REMATCH[2]}"
        echo "$player" "$message"
        return 0
    fi
    return 1
}

# Function to schedule timer
schedule_timer() {
    local id="$1" delay="$2" command="$3"
    
    # Cancel existing timer
    cancel_timer "$id"
    
    # Schedule new timer
    (
        sleep "$delay"
        eval "$command"
    ) &
    active_timers["$id"]=$!
}

# Function to cancel timer
cancel_timer() {
    local id="$1"
    if [ -n "${active_timers[$id]}" ]; then
        kill "${active_timers[$id]}" 2>/dev/null
        unset active_timers["$id"]
    fi
}

# Function to handle player connection
handle_player_connection() {
    local player="$1" ip="$2"
    
    player=$(echo "$player" | tr '[:lower:]' '[:upper:]')
    print_status "Player connected: $player ($ip)"
    
    # Store current IP
    player_current_ips["$player"]="$ip"
    player_connection_time["$player"]=$(date +%s)
    
    # Get stored player info
    local stored_ip=$(get_player_field "$player" "ip")
    local stored_password=$(get_player_field "$player" "password")
    
    # Initialize if new player
    if [ -z "$stored_ip" ]; then
        update_player_info "$player" "UNKNOWN" "NONE" "NONE" "NO" "NO"
        stored_ip="UNKNOWN"
        stored_password="NONE"
    fi
    
    # Check IP change
    if [[ "$stored_ip" != "UNKNOWN" && "$stored_ip" != "$ip" ]]; then
        print_warning "IP changed for $player: $stored_ip -> $ip"
        
        # Set IP to UNKNOWN pending verification
        update_player_info "$player" "UNKNOWN" "$stored_password" "$(get_player_field "$player" "rank")" "$(get_player_field "$player" "whitelisted")" "$(get_player_field "$player" "blacklisted")"
        
        # Schedule IP verification warnings
        schedule_timer "ip_warn_$player" 5 "send_player_message \"$player\" \"IP change detected! Verify within 25s: !ip_change YOUR_PASSWORD\""
        schedule_timer "ip_kick_$player" 30 "handle_ip_verification_failed \"$player\" \"$ip\""
        
    else
        # Update IP if was UNKNOWN
        if [[ "$stored_ip" == "UNKNOWN" ]]; then
            update_player_info "$player" "$ip" "$stored_password" "$(get_player_field "$player" "rank")" "$(get_player_field "$player" "whitelisted")" "$(get_player_field "$player" "blacklisted")"
            print_success "IP verified: $player -> $ip"
        fi
        
        # Check password requirement
        if [[ "$stored_password" == "NONE" ]]; then
            schedule_timer "pwd_warn_$player" 5 "send_player_message \"$player\" \"Set password within 60s: !psw PASSWORD CONFIRM_PASSWORD\""
            schedule_timer "pwd_kick_$player" 65 "handle_password_timeout \"$player\""
        fi
    fi
    
    update_server_lists
}

# Function to handle IP verification failure
handle_ip_verification_failed() {
    local player="$1" ip="$2"
    
    if [[ $(get_player_field "$player" "ip") == "UNKNOWN" ]]; then
        print_warning "IP verification failed for $player"
        wait_cooldown
        send_server_command "/kick $player"
        wait_cooldown
        send_server_command "/ban $ip"
        
        # Auto-unban after 30s
        schedule_timer "unban_$player" 30 "send_server_command \"/unban $ip\""
    fi
}

# Function to handle password timeout
handle_password_timeout() {
    local player="$1"
    
    if [[ $(get_player_field "$player" "password") == "NONE" ]]; then
        print_warning "Password timeout for $player"
        wait_cooldown
        send_server_command "/kick $player"
    fi
}

# Function to handle password command
handle_password_command() {
    local player="$1" password="$2" confirm="$3"
    
    # Clear chat immediately
    clear_chat
    
    # Validate input
    if [[ -z "$password" || -z "$confirm" ]]; then
        wait_cooldown
        send_player_message "$player" "Usage: !psw PASSWORD CONFIRM_PASSWORD"
        return 1
    fi
    
    if [[ ${#password} -lt 7 || ${#password} -gt 16 ]]; then
        wait_cooldown
        send_player_message "$player" "Password must be 7-16 characters"
        return 1
    fi
    
    if [[ "$password" != "$confirm" ]]; then
        wait_cooldown
        send_player_message "$player" "Passwords don't match"
        return 1
    fi
    
    # Update password
    update_player_info "$player" "$(get_player_field "$player" "ip")" "$password" "$(get_player_field "$player" "rank")" "$(get_player_field "$player" "whitelisted")" "$(get_player_field "$player" "blacklisted")"
    
    # Cancel password timers
    cancel_timer "pwd_warn_$player"
    cancel_timer "pwd_kick_$player"
    
    wait_cooldown
    send_player_message "$player" "Password set successfully!"
    return 0
}

# Function to handle IP change command
handle_ip_change_command() {
    local player="$1" current_password="$2"
    
    # Clear chat immediately
    clear_chat
    
    # Validate input
    if [[ -z "$current_password" ]]; then
        wait_cooldown
        send_player_message "$player" "Usage: !ip_change YOUR_PASSWORD"
        return 1
    fi
    
    # Verify password
    local stored_password=$(get_player_field "$player" "password")
    if [[ "$stored_password" != "$current_password" ]]; then
        wait_cooldown
        send_player_message "$player" "Incorrect password"
        return 1
    fi
    
    # Update IP
    local current_ip="${player_current_ips[$player]}"
    update_player_info "$player" "$current_ip" "$stored_password" "$(get_player_field "$player" "rank")" "$(get_player_field "$player" "whitelisted")" "$(get_player_field "$player" "blacklisted")"
    
    # Cancel IP timers
    cancel_timer "ip_warn_$player"
    cancel_timer "ip_kick_$player"
    
    wait_cooldown
    send_player_message "$player" "IP verified successfully!"
    return 0
}

# Function to handle password change command
handle_password_change_command() {
    local player="$1" old_password="$2" new_password="$3"
    
    # Clear chat immediately
    clear_chat
    
    # Validate input
    if [[ -z "$old_password" || -z "$new_password" ]]; then
        wait_cooldown
        send_player_message "$player" "Usage: !change_psw OLD_PASSWORD NEW_PASSWORD"
        return 1
    fi
    
    # Verify old password
    local stored_password=$(get_player_field "$player" "password")
    if [[ "$stored_password" != "$old_password" ]]; then
        wait_cooldown
        send_player_message "$player" "Incorrect old password"
        return 1
    fi
    
    if [[ ${#new_password} -lt 7 || ${#new_password} -gt 16 ]]; then
        wait_cooldown
        send_player_message "$player" "New password must be 7-16 characters"
        return 1
    fi
    
    # Update password
    update_player_info "$player" "$(get_player_field "$player" "ip")" "$new_password" "$(get_player_field "$player" "rank")" "$(get_player_field "$player" "whitelisted")" "$(get_player_field "$player" "blacklisted")"
    
    wait_cooldown
    send_player_message "$player" "Password changed successfully!"
    return 0
}

# Function to monitor console.log
monitor_console_log() {
    local world_dir="$SERVER_HOME/saves/$WORLD_ID"
    local console_log="$world_dir/console.log"
    
    print_status "Monitoring console.log..."
    
    # Wait for file to exist
    while [ ! -f "$console_log" ]; do
        sleep 1
    done
    
    # Monitor file
    tail -n 0 -f "$console_log" | while read -r line; do
        # Check for player connections
        local connection_info=$(extract_player_connection "$line")
        if [[ -n "$connection_info" ]]; then
            read -r player ip <<< "$connection_info"
            handle_player_connection "$player" "$ip"
        fi
        
        # Check for chat messages
        local chat_data=$(extract_chat_message "$line")
        if [[ -n "$chat_data" ]]; then
            read -r player message <<< "$chat_data"
            player=$(echo "$player" | tr '[:lower:]' '[:upper:]')
            
            # Handle commands
            case "$message" in
                "!psw "*)
                    read -r cmd password confirm <<< "$message"
                    handle_password_command "$player" "$password" "$confirm"
                    ;;
                "!ip_change "*)
                    read -r cmd current_password <<< "$message"
                    handle_ip_change_command "$player" "$current_password"
                    ;;
                "!change_psw "*)
                    read -r cmd old_password new_password <<< "$message"
                    handle_password_change_command "$player" "$old_password" "$new_password"
                    ;;
            esac
        fi
    done
}

# Function to cleanup
cleanup() {
    print_status "Cleaning up..."
    for timer in "${active_timers[@]}"; do
        kill "$timer" 2>/dev/null
    done
    exit 0
}

# Main function
main() {
    print_status "Starting Rank Patcher..."
    
    # Set trap
    trap cleanup SIGINT SIGTERM
    
    # Find screen session
    SCREEN_SESSION=$(find_screen_session)
    if [ -z "$SCREEN_SESSION" ]; then
        print_error "No server screen session found"
        exit 1
    fi
    
    # Find world
    if ! find_world_directory; then
        exit 1
    fi
    
    # Initialize
    initialize_players_log
    load_player_data
    update_server_lists
    
    print_success "Rank Patcher started"
    print_status "World: $WORLD_ID"
    print_status "Screen: $SCREEN_SESSION"
    
    # Start monitors
    monitor_players_log &
    monitor_console_log &
    
    # Wait
    wait
}

# Run
main "$@"
