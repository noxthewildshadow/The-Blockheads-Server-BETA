#!/bin/bash

# rank_patcher.sh - Complete Player Management System for The Blockheads
# Monitors console.log and manages players.log as central authority

# Enhanced Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

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

# Configuration
BASE_DIR="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves"
CONSOLE_LOG="$1"
WORLD_ID="$2"
PORT="$3"

# Extract world ID from console log path if not provided
if [ -z "$WORLD_ID" ] && [ -n "$CONSOLE_LOG" ]; then
    WORLD_ID=$(echo "$CONSOLE_LOG" | grep -oE 'saves/[^/]+' | cut -d'/' -f2)
fi

# Validate parameters
if [ -z "$CONSOLE_LOG" ] || [ -z "$WORLD_ID" ]; then
    print_error "Usage: $0 <console_log_path> [world_id] [port]"
    print_status "Example: $0 /path/to/console.log world123 12153"
    exit 1
fi

# File paths
PLAYERS_LOG="$BASE_DIR/$WORLD_ID/players.log"
ADMIN_LIST="$BASE_DIR/$WORLD_ID/adminlist.txt"
MOD_LIST="$BASE_DIR/$WORLD_ID/modlist.txt"
WHITELIST="$BASE_DIR/$WORLD_ID/whitelist.txt"
BLACKLIST="$BASE_DIR/$WORLD_ID/blacklist.txt"
CLOUD_ADMIN_LIST="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/cloudWideOwnedAdminlist.txt"

# Screen session for server commands
SCREEN_SERVER="blockheads_server_${PORT:-12153}"

# Cooldown configuration
COMMAND_COOLDOWN=0.5
PASSWORD_TIMEOUT=30
IP_VERIFY_TIMEOUT=30
IP_BAN_DURATION=30

# Track connected players and their states
declare -A connected_players
declare -A player_ip_map
declare -A password_pending
declare -A ip_verify_pending
declare -A ip_banned_times
declare -A last_command_time
declare -A player_join_time
declare -A player_original_rank
declare -A player_verified

# Function to send commands to server with cooldown
send_server_command() {
    local command="$1"
    local current_time=$(date +%s)
    
    # Check cooldown
    if [ -n "${last_command_time[$command]}" ]; then
        local time_diff=$((current_time - last_command_time[$command]))
        if [ $time_diff -lt ${COMMAND_COOLDOWN%.*} ]; then
            sleep $((COMMAND_COOLDOWN%.* - time_diff))
        fi
    fi
    
    if screen -S "$SCREEN_SERVER" -X stuff "$command$(printf \\r)" 2>/dev/null; then
        print_success "Sent command: $command"
        last_command_time[$command]=$(date +%s)
        return 0
    else
        print_error "Failed to send command: $command"
        return 1
    fi
}

# Function to clear chat
clear_chat() {
    send_server_command "/clear"
    sleep "$COMMAND_COOLDOWN"
}

# Function to remove player from privilege lists when disconnected
remove_player_from_lists() {
    local player_name="$1"
    
    print_status "Removing $player_name from privilege lists due to disconnection"
    
    # Remove only from privilege lists, NOT from whitelist/blacklist
    # Remove from adminlist.txt
    if [ -f "$ADMIN_LIST" ]; then
        # Create empty file without any comments
        > "$ADMIN_LIST"
    fi
    
    # Remove from modlist.txt
    if [ -f "$MOD_LIST" ]; then
        # Create empty file without any comments
        > "$MOD_LIST"
    fi
    
    # Remove from cloudWideOwnedAdminlist.txt
    if [ -f "$CLOUD_ADMIN_LIST" ]; then
        # Create empty file without any comments
        > "$CLOUD_ADMIN_LIST"
    fi
    
    print_success "Removed $player_name from privilege lists (admin/mod/super)"
}

# Function to restore player rank if IP is verified
restore_player_rank() {
    local player_name="$1"
    
    if [ -n "${player_original_rank[$player_name]}" ]; then
        local original_rank="${player_original_rank[$player_name]}"
        read_players_log
        
        # Only restore if player has password and verified IP
        local password="${players_data["$player_name,password"]}"
        local ip="${players_data["$player_name,ip"]}"
        
        if [ "$password" != "NONE" ] && [ "$ip" != "UNKNOWN" ]; then
            print_status "Restoring original rank $original_rank to $player_name"
            update_players_log "$player_name" "rank" "$original_rank"
            
            # Apply the rank commands
            case "$original_rank" in
                "ADMIN")
                    send_server_command "/admin $player_name"
                    ;;
                "MOD")
                    send_server_command "/mod $player_name"
                    ;;
                "SUPER")
                    echo "$player_name" >> "$CLOUD_ADMIN_LIST"
                    send_server_command "/admin $player_name"
                    ;;
            esac
            
            # Mark player as verified
            player_verified["$player_name"]=1
            print_success "Rank $original_rank restored for $player_name"
        fi
        
        # Clear the stored original rank
        unset player_original_rank["$player_name"]
    fi
}

# Function to initialize players.log with correct format
initialize_players_log() {
    if [ ! -f "$PLAYERS_LOG" ]; then
        print_status "Creating new players.log file"
        mkdir -p "$(dirname "$PLAYERS_LOG")"
        echo "# Player Name | First IP | Password | Rank | Whitelisted | Blacklisted" > "$PLAYERS_LOG"
        echo "# Format: PLAYER_NAME | IP | PASSWORD | RANK | WHITELISTED | BLACKLISTED" >> "$PLAYERS_LOG"
        print_success "players.log created at: $PLAYERS_LOG"
    else
        # Reformat existing file to remove extra spaces
        temp_file=$(mktemp)
        {
            echo "# Player Name | First IP | Password | Rank | Whitelisted | Blacklisted"
            echo "# Format: PLAYER_NAME | IP | PASSWORD | RANK | WHITELISTED | BLACKLISTED"
            
            if [ -f "$PLAYERS_LOG" ]; then
                while IFS='|' read -r name ip password rank whitelisted blacklisted; do
                    if [[ "$name" =~ ^# ]] || [ -z "$(echo "$name" | xargs)" ]; then
                        continue
                    fi
                    
                    name=$(echo "$name" | xargs)
                    ip=$(echo "$ip" | xargs)
                    password=$(echo "$password" | xargs)
                    rank=$(echo "$rank" | xargs)
                    whitelisted=$(echo "$whitelisted" | xargs)
                    blacklisted=$(echo "$blacklisted" | xargs)
                    
                    [ -z "$name" ] && name="UNKNOWN"
                    [ -z "$ip" ] && ip="UNKNOWN"
                    [ -z "$password" ] && password="NONE"
                    [ -z "$rank" ] && rank="NONE"
                    [ -z "$whitelisted" ] && whitelisted="NO"
                    [ -z "$blacklisted" ] && blacklisted="NO"
                    
                    if [ "$name" != "UNKNOWN" ]; then
                        printf "%s | %s | %s | %s | %s | %s\n" \
                            "$name" "$ip" "$password" "$rank" "$whitelisted" "$blacklisted"
                    fi
                done < "$PLAYERS_LOG"
            fi
        } > "$temp_file"
        
        mv "$temp_file" "$PLAYERS_LOG"
        print_success "players.log reformatted to remove extra spaces"
    fi
}

# Function to read players.log into associative array
read_players_log() {
    declare -gA players_data
    
    if [ ! -f "$PLAYERS_LOG" ]; then
        print_error "players.log not found: $PLAYERS_LOG"
        return 1
    fi
    
    while IFS='|' read -r name ip password rank whitelisted blacklisted; do
        if [[ "$name" =~ ^# ]] || [ -z "$(echo "$name" | xargs)" ]; then
            continue
        fi
        
        name=$(echo "$name" | xargs)
        ip=$(echo "$ip" | xargs)
        password=$(echo "$password" | xargs)
        rank=$(echo "$rank" | xargs)
        whitelisted=$(echo "$whitelisted" | xargs)
        blacklisted=$(echo "$blacklisted" | xargs)
        
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

# Function to update players.log with correct format
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
        echo "# Format: PLAYER_NAME | IP | PASSWORD | RANK | WHITELISTED | BLACKLISTED"
        
        for key in "${!players_data[@]}"; do
            if [[ "$key" == *,name ]]; then
                local name="${players_data[$key]}"
                local ip="${players_data["$name,ip"]:-UNKNOWN}"
                local password="${players_data["$name,password"]:-NONE}"
                local rank="${players_data["$name,rank"]:-NONE}"
                local whitelisted="${players_data["$name,whitelisted"]:-NO}"
                local blacklisted="${players_data["$name,blacklisted"]:-NO}"
                
                printf "%s | %s | %s | %s | %s | %s\n" \
                    "$name" "$ip" "$password" "$rank" "$whitelisted" "$blacklisted"
            fi
        done
    } > "$PLAYERS_LOG"
    
    print_success "Updated players.log: $player_name $field = $new_value"
}

# Function to add new player to players.log with correct format
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
        echo "# Format: PLAYER_NAME | IP | PASSWORD | RANK | WHITELISTED | BLACKLISTED"
        
        for key in "${!players_data[@]}"; do
            if [[ "$key" == *,name ]]; then
                local name="${players_data[$key]}"
                local ip="${players_data["$name,ip"]:-UNKNOWN}"
                local password="${players_data["$name,password"]:-NONE}"
                local rank="${players_data["$name,rank"]:-NONE}"
                local whitelisted="${players_data["$name,whitelisted"]:-NO}"
                local blacklisted="${players_data["$name,blacklisted"]:-NO}"
                
                printf "%s | %s | %s | %s | %s | %s\n" \
                    "$name" "$ip" "$password" "$rank" "$whitelisted" "$blacklisted"
            fi
        done
    } > "$PLAYERS_LOG"
    
    print_success "Added new player: $player_name ($player_ip)"
}

# Function to sync server lists from players.log
sync_server_lists() {
    print_status "Syncing server lists from players.log..."
    
    read_players_log
    
    # Clear existing privilege lists - crear archivos VACÍOS sin comentarios
    for list_file in "$ADMIN_LIST" "$MOD_LIST"; do
        > "$list_file"
    done
    
    > "$CLOUD_ADMIN_LIST"
    > "$WHITELIST"
    > "$BLACKLIST"
    
    for key in "${!players_data[@]}"; do
        if [[ "$key" == *,name ]]; then
            local name="${players_data[$key]}"
            local ip="${players_data["$name,ip"]}"
            local password="${players_data["$name,password"]}"
            local rank="${players_data["$name,rank"]}"
            local whitelisted="${players_data["$name,whitelisted"]}"
            local blacklisted="${players_data["$name,blacklisted"]}"
            
            if [ "$password" != "NONE" ] && [ "$ip" != "UNKNOWN" ] && [ -n "${player_verified[$name]}" ]; then
                case "$rank" in
                    "ADMIN") echo "$name" >> "$ADMIN_LIST" ;;
                    "MOD") echo "$name" >> "$MOD_LIST" ;;
                    "SUPER") echo "$name" >> "$CLOUD_ADMIN_LIST" ;;
                esac
            else
                if [ "$rank" != "NONE" ]; then
                    print_warning "Player $name lacks password or IP verification - resetting rank to NONE"
                    update_players_log "$name" "rank" "NONE"
                fi
            fi
            
            if [ "$whitelisted" = "YES" ]; then
                echo "$name" >> "$WHITELIST"
            fi
            
            if [ "$blacklisted" = "YES" ]; then
                echo "$name" >> "$BLACKLIST"
            fi
        fi
    done
    
    print_success "Server lists synced"
}

# Function to handle rank changes with cooldown
handle_rank_change() {
    local player_name="$1" old_rank="$2" new_rank="$3"
    
    if [ "$old_rank" = "$new_rank" ]; then
        return 0
    fi
    
    sleep "$COMMAND_COOLDOWN"
    
    if [ "$old_rank" = "ADMIN" ] && [ "$new_rank" = "MOD" ]; then
        send_server_command "/unadmin $player_name"
        sleep "$COMMAND_COOLDOWN"
        send_server_command "/mod $player_name"
        print_success "Changed $player_name from ADMIN to MOD"
        return 0
    fi
    
    if [ "$old_rank" = "MOD" ] && [ "$new_rank" = "ADMIN" ]; then
        send_server_command "/unmod $player_name"
        sleep "$COMMAND_COOLDOWN"
        send_server_command "/admin $player_name"
        print_success "Changed $player_name from MOD to ADMIN"
        return 0
    fi
    
    if [ "$old_rank" = "ADMIN" ] && [ "$new_rank" = "NONE" ]; then
        send_server_command "/unadmin $player_name"
        print_success "Removed ADMIN rank from $player_name"
        return 0
    fi
    
    if [ "$old_rank" = "MOD" ] && [ "$new_rank" = "NONE" ]; then
        send_server_command "/unmod $player_name"
        print_success "Removed MOD rank from $player_name"
        return 0
    fi
    
    if [ "$old_rank" = "SUPER" ] && [ "$new_rank" != "SUPER" ]; then
        > "$CLOUD_ADMIN_LIST"
        
        if [ "$new_rank" = "NONE" ]; then
            send_server_command "/unadmin $player_name"
            print_success "Removed SUPER and ADMIN rank from $player_name"
        elif [ "$new_rank" = "MOD" ]; then
            send_server_command "/unadmin $player_name"
            sleep "$COMMAND_COOLDOWN"
            send_server_command "/mod $player_name"
            print_success "Changed $player_name from SUPER to MOD"
        fi
        return 0
    fi
    
    if [ "$old_rank" = "NONE" ] && [ "$new_rank" = "ADMIN" ]; then
        send_server_command "/admin $player_name"
        print_success "Promoted $player_name to ADMIN"
        return 0
    fi
    
    if [ "$old_rank" = "NONE" ] && [ "$new_rank" = "MOD" ]; then
        send_server_command "/mod $player_name"
        print_success "Promoted $player_name to MOD"
        return 0
    fi
    
    if [ "$new_rank" = "SUPER" ]; then
        if [ "$old_rank" = "ADMIN" ]; then
            send_server_command "/unadmin $player_name"
            sleep "$COMMAND_COOLDOWN"
        elif [ "$old_rank" = "MOD" ]; then
            send_server_command "/unmod $player_name"
            sleep "$COMMAND_COOLDOWN"
        fi
        
        echo "$player_name" >> "$CLOUD_ADMIN_LIST"
        print_success "Added $player_name to cloud-wide admin list (SUPER)"
        send_server_command "/admin $player_name"
        return 0
    fi
    
    print_warning "Unhandled rank change: $player_name from $old_rank to $new_rank"
}

# Function to handle whitelist changes
handle_whitelist_change() {
    local player_name="$1" old_whitelisted="$2" new_whitelisted="$3"
    
    if [ "$old_whitelisted" = "$new_whitelisted" ]; then
        return 0
    fi
    
    sleep "$COMMAND_COOLDOWN"
    
    if [ "$old_whitelisted" = "NO" ] && [ "$new_whitelisted" = "YES" ]; then
        send_server_command "/whitelist $player_name"
        print_success "Added $player_name to whitelist"
        return 0
    fi
    
    if [ "$old_whitelisted" = "YES" ] && [ "$new_whitelisted" = "NO" ]; then
        send_server_command "/unwhitelist $player_name"
        print_success "Removed $player_name from whitelist"
        return 0
    fi
}

# Function to handle blacklist changes
handle_blacklist_change() {
    local player_name="$1" old_blacklisted="$2" new_blacklisted="$3" player_ip="$4"
    
    if [ "$old_blacklisted" = "$new_blacklisted" ]; then
        return 0
    fi
    
    sleep "$COMMAND_COOLDOWN"
    
    if [ "$old_blacklisted" = "NO" ] && [ "$new_blacklisted" = "YES" ]; then
        read_players_log
        local rank="${players_data["$player_name,rank"]}"
        
        if [ "$rank" = "SUPER" ] && [ -n "${connected_players[$player_name]}" ]; then
            print_warning "SUPER admin blacklisted - stopping server first"
            send_server_command "/stop"
            sleep 2
        fi
        
        if [ "$rank" = "MOD" ]; then
            send_server_command "/unmod $player_name"
            sleep "$COMMAND_COOLDOWN"
        elif [ "$rank" = "ADMIN" ] || [ "$rank" = "SUPER" ]; then
            send_server_command "/unadmin $player_name"
            sleep "$COMMAND_COOLDOWN"
        fi
        
        if [ "$rank" = "SUPER" ]; then
            > "$CLOUD_ADMIN_LIST"
        fi
        
        send_server_command "/ban $player_name"
        
        if [ "$player_ip" != "UNKNOWN" ]; then
            sleep "$COMMAND_COOLDOWN"
            send_server_command "/ban $player_ip"
            ip_banned_times["$player_ip"]=$(date +%s)
        fi
        
        print_success "Banned player: $player_name ($player_ip)"
        return 0
    fi
    
    if [ "$old_blacklisted" = "YES" ] && [ "$new_blacklisted" = "NO" ]; then
        send_server_command "/unban $player_name"
        
        if [ "$player_ip" != "UNKNOWN" ]; then
            sleep "$COMMAND_COOLDOWN"
            send_server_command "/unban $player_ip"
            unset ip_banned_times["$player_ip"]
        fi
        
        print_success "Unbanned player: $player_name ($player_ip)"
        return 0
    fi
}

# Function to auto-unban IP addresses after timeout
auto_unban_ips() {
    local current_time=$(date +%s)
    
    for ip in "${!ip_banned_times[@]}"; do
        local ban_time="${ip_banned_times[$ip]}"
        if [ $((current_time - ban_time)) -ge $IP_BAN_DURATION ]; then
            send_server_command "/unban $ip"
            print_status "Auto-unbanned IP: $ip"
            unset ip_banned_times["$ip"]
        fi
    done
}

# Function to validate password
validate_password() {
    local password="$1"
    local length=${#password}
    
    if [ $length -lt 7 ] || [ $length -gt 16 ]; then
        echo "Password must be between 7 and 16 characters"
        return 1
    fi
    
    if ! [[ "$password" =~ ^[a-zA-Z0-9!@#$%\&*()_+-=]+$ ]]; then
        echo "Password contains invalid characters"
        return 1
    fi
    
    return 0
}

# Function to handle password commands with clear and cooldown
handle_password_command() {
    local player_name="$1" password="$2" confirm_password="$3"
    
    clear_chat
    
    if [ "$password" != "$confirm_password" ]; then
        sleep "$COMMAND_COOLDOWN"
        send_server_command "Passwords do not match"
        return 1
    fi
    
    local validation_result=$(validate_password "$password")
    if [ $? -ne 0 ]; then
        sleep "$COMMAND_COOLDOWN"
        send_server_command "$validation_result"
        return 1
    fi
    
    update_players_log "$player_name" "password" "$password"
    sleep "$COMMAND_COOLDOWN"
    send_server_command "Password set successfully for $player_name"
    
    unset password_pending["$player_name"]
    
    read_players_log
    local ip="${players_data["$player_name,ip"]}"
    if [ "$ip" != "UNKNOWN" ] && [ -n "${player_original_rank[$player_name]}" ]; then
        restore_player_rank "$player_name"
    fi
    
    return 0
}

# Function to handle IP change verification with clear and cooldown
handle_ip_change() {
    local player_name="$1" provided_password="$2" current_ip="$3"
    
    clear_chat
    
    read_players_log
    local stored_password="${players_data["$player_name,password"]}"
    
    if [ "$stored_password" = "NONE" ]; then
        sleep "$COMMAND_COOLDOWN"
        send_server_command "No password set for $player_name. Use !password first."
        return 1
    fi
    
    if [ "$provided_password" != "$stored_password" ]; then
        sleep "$COMMAND_COOLDOWN"
        send_server_command "Incorrect password for IP verification"
        return 1
    fi
    
    update_players_log "$player_name" "ip" "$current_ip"
    sleep "$COMMAND_COOLDOWN"
    send_server_command "IP address verified and updated for $player_name"
    
    unset ip_verify_pending["$player_name"]
    player_verified["$player_name"]=1
    
    if [ -n "${player_original_rank[$player_name]}" ]; then
        restore_player_rank "$player_name"
    fi
    
    return 0
}

# Function to handle password change with clear and cooldown
handle_password_change() {
    local player_name="$1" old_password="$2" new_password="$3"
    
    clear_chat
    
    read_players_log
    local stored_password="${players_data["$player_name,password"]}"
    
    if [ "$stored_password" = "NONE" ]; then
        sleep "$COMMAND_COOLDOWN"
        send_server_command "No existing password found for $player_name"
        return 1
    fi
    
    if [ "$old_password" != "$stored_password" ]; then
        sleep "$COMMAND_COOLDOWN"
        send_server_command "Incorrect old password"
        return 1
    fi
    
    local validation_result=$(validate_password "$new_password")
    if [ $? -ne 0 ]; then
        sleep "$COMMAND_COOLDOWN"
        send_server_command "$validation_result"
        return 1
    fi
    
    update_players_log "$player_name" "password" "$new_password"
    sleep "$COMMAND_COOLDOWN"
    send_server_command "Password changed successfully for $player_name"
    return 0
}

# Function to check timeouts and kick players who don't verify (CORREGIDA - KICK FUNCIONA)
check_timeouts() {
    local current_time=$(date +%s)
    
    # Check password setup timeouts
    for player in "${!password_pending[@]}"; do
        local start_time="${password_pending[$player]}"
        local time_passed=$((current_time - start_time))
        
        if [ $time_passed -ge $PASSWORD_TIMEOUT ]; then
            print_error "KICKING $player for password setup timeout ($time_passed seconds)"
            send_server_command "/kick $player"
            send_server_command "Kicked: No password set within $PASSWORD_TIMEOUT seconds"
            unset password_pending["$player"]
            # Also remove from connected players
            unset connected_players["$player"]
            unset player_ip_map["$player"]
        else
            print_warning "Player $player has $((PASSWORD_TIMEOUT - time_passed)) seconds to set password"
        fi
    done
    
    # Check IP verification timeouts
    for player in "${!ip_verify_pending[@]}"; do
        local start_time="${ip_verify_pending[$player]}"
        local time_passed=$((current_time - start_time))
        
        if [ $time_passed -ge $IP_VERIFY_TIMEOUT ]; then
            print_error "KICKING $player for IP verification timeout ($time_passed seconds)"
            send_server_command "/kick $player"
            send_server_command "Kicked: IP not verified within $IP_VERIFY_TIMEOUT seconds"
            unset ip_verify_pending["$player"]
            unset player_original_rank["$player"]
            # Also remove from connected players
            unset connected_players["$player"]
            unset player_ip_map["$player"]
        else
            print_warning "Player $player has $((IP_VERIFY_TIMEOUT - time_passed)) seconds to verify IP"
        fi
    done
    
    auto_unban_ips
}

# Function to monitor console.log for events
monitor_console_log() {
    print_header "Starting rank_patcher monitoring"
    print_status "World: $WORLD_ID"
    print_status "Console log: $CONSOLE_LOG"
    print_status "Players log: $PLAYERS_LOG"
    
    initialize_players_log
    sync_server_lists
    
    # Create FIFO for non-blocking read
    local FIFO=$(mktemp -u)
    mkfifo "$FIFO"
    tail -n 0 -F "$CONSOLE_LOG" > "$FIFO" &
    local TAIL_PID=$!
    
    # Cleanup function
    cleanup() {
        kill $TAIL_PID 2>/dev/null
        rm -f "$FIFO"
        exit 0
    }
    trap cleanup EXIT
    
    # Main monitoring loop with timeout checking
    while true; do
        # Check timeouts every iteration
        check_timeouts
        
        # Read with timeout to avoid blocking
        if read -t 1 line < "$FIFO" 2>/dev/null; then
            # Process the line
            if [[ "$line" =~ Player\ Connected\ ([a-zA-Z0-9_]+)\ \|\ ([0-9a-fA-F.:]+)\ \|\ ([a-f0-9]+) ]]; then
                local player_name="${BASH_REMATCH[1]}"
                local player_ip="${BASH_REMATCH[2]}"
                local player_guid="${BASH_REMATCH[3]}"
                
                print_success "Player connected: $player_name ($player_ip)"
                
                player_join_time["$player_name"]=$(date +%s)
                connected_players["$player_name"]=1
                player_ip_map["$player_name"]="$player_ip"
                
                read_players_log
                if [ -z "${players_data["$player_name,name"]}" ]; then
                    add_new_player "$player_name" "$player_ip"
                    send_server_command "Welcome $player_name! Set password within 30s: !password YOUR_PASSWORD CONFIRM_PASSWORD"
                    password_pending["$player_name"]=$(date +%s)
                    print_warning "New player - password required within $PASSWORD_TIMEOUT seconds"
                else
                    local stored_ip="${players_data["$player_name,ip"]}"
                    local stored_password="${players_data["$player_name,password"]}"
                    local stored_rank="${players_data["$player_name,rank"]}"
                    
                    if [ "$stored_rank" != "NONE" ]; then
                        player_original_rank["$player_name"]="$stored_rank"
                    fi
                    
                    if [ "$stored_ip" != "$player_ip" ] && [ "$stored_ip" != "UNKNOWN" ]; then
                        send_server_command "IP change detected for $player_name. Verify within 30s: !ip_change YOUR_PASSWORD"
                        ip_verify_pending["$player_name"]=$(date +%s)
                        print_warning "IP change detected - verification required within $IP_VERIFY_TIMEOUT seconds"
                        
                        if [ "$stored_rank" != "NONE" ]; then
                            update_players_log "$player_name" "rank" "NONE"
                            case "$stored_rank" in
                                "ADMIN") send_server_command "/unadmin $player_name" ;;
                                "MOD") send_server_command "/unmod $player_name" ;;
                                "SUPER") 
                                    send_server_command "/unadmin $player_name"
                                    > "$CLOUD_ADMIN_LIST"
                                    ;;
                            esac
                            print_warning "Temporarily removed ranks from $player_name pending IP verification"
                        fi
                    else
                        player_verified["$player_name"]=1
                    fi
                    
                    if [ "$stored_password" = "NONE" ]; then
                        send_server_command "Welcome back $player_name! Set password within 30s: !password YOUR_PASSWORD CONFIRM_PASSWORD"
                        password_pending["$player_name"]=$(date +%s)
                        print_warning "Existing player without password - setup required within $PASSWORD_TIMEOUT seconds"
                        
                        if [ "$stored_rank" != "NONE" ]; then
                            update_players_log "$player_name" "rank" "NONE"
                            case "$stored_rank" in
                                "ADMIN") send_server_command "/unadmin $player_name" ;;
                                "MOD") send_server_command "/unmod $player_name" ;;
                                "SUPER") 
                                    send_server_command "/unadmin $player_name"
                                    > "$CLOUD_ADMIN_LIST"
                                    ;;
                            esac
                        fi
                    else
                        if [ -n "${player_verified[$player_name]}" ] && [ "$stored_rank" != "NONE" ]; then
                            case "$stored_rank" in
                                "ADMIN") 
                                    send_server_command "/admin $player_name"
                                    print_success "Restored ADMIN rank to $player_name"
                                    ;;
                                "MOD") 
                                    send_server_command "/mod $player_name"
                                    print_success "Restored MOD rank to $player_name"
                                    ;;
                                "SUPER") 
                                    echo "$player_name" >> "$CLOUD_ADMIN_LIST"
                                    send_server_command "/admin $player_name"
                                    print_success "Restored SUPER rank to $player_name"
                                    ;;
                            esac
                        fi
                    fi
                fi
                
                sync_server_lists
                
            elif [[ "$line" =~ Player\ Disconnected\ ([a-zA-Z0-9_]+) ]]; then
                local player_name="${BASH_REMATCH[1]}"
                
                print_warning "Player disconnected: $player_name"
                
                unset connected_players["$player_name"]
                unset player_ip_map["$player_name"]
                unset player_join_time["$player_name"]
                unset password_pending["$player_name"]
                unset ip_verify_pending["$player_name"]
                unset player_verified["$player_name"]
                
                remove_player_from_lists "$player_name"
                sync_server_lists
                
            elif [[ "$line" =~ ([a-zA-Z0-9_]+):\ (.+)$ ]]; then
                local player_name="${BASH_REMATCH[1]}"
                local message="${BASH_REMATCH[2]}"
                
                if [ "$player_name" = "SERVER" ]; then
                    continue
                fi
                
                case "$message" in
                    "!password "*)
                        if [[ "$message" =~ !password\ ([^ ]+)\ ([^ ]+) ]]; then
                            local password="${BASH_REMATCH[1]}"
                            local confirm_password="${BASH_REMATCH[2]}"
                            handle_password_command "$player_name" "$password" "$confirm_password"
                        else
                            send_server_command "Usage: !password NEW_PASSWORD CONFIRM_PASSWORD"
                        fi
                        ;;
                    "!ip_change "*)
                        if [[ "$message" =~ !ip_change\ ([^ ]+) ]]; then
                            local password="${BASH_REMATCH[1]}"
                            local current_ip="${player_ip_map[$player_name]}"
                            handle_ip_change "$player_name" "$password" "$current_ip"
                        else
                            send_server_command "Usage: !ip_change YOUR_PASSWORD"
                        fi
                        ;;
                    "!change_psw "*)
                        if [[ "$message" =~ !change_psw\ ([^ ]+)\ ([^ ]+) ]]; then
                            local old_password="${BASH_REMATCH[1]}"
                            local new_password="${BASH_REMATCH[2]}"
                            handle_password_change "$player_name" "$old_password" "$new_password"
                        else
                            send_server_command "Usage: !change_psw OLD_PASSWORD NEW_PASSWORD"
                        fi
                        ;;
                esac
            fi
        fi
    done
}

# Function to monitor players.log for changes every 1 second
monitor_players_log() {
    local last_modified=0
    
    while true; do
        if [ -f "$PLAYERS_LOG" ]; then
            local current_modified=$(stat -c %Y "$PLAYERS_LOG" 2>/dev/null || stat -f %m "$PLAYERS_LOG")
            
            if [ "$current_modified" -ne "$last_modified" ]; then
                print_status "players.log modified - processing changes"
                
                declare -A old_players_data
                for key in "${!players_data[@]}"; do
                    old_players_data["$key"]="${players_data[$key]}"
                done
                
                read_players_log
                
                for key in "${!players_data[@]}"; do
                    if [[ "$key" == *,name ]]; then
                        local player_name="${players_data[$key]}"
                        local old_rank="${old_players_data["$player_name,rank"]:-NONE}"
                        local new_rank="${players_data["$player_name,rank"]:-NONE}"
                        local old_whitelisted="${old_players_data["$player_name,whitelisted"]:-NO}"
                        local new_whitelisted="${players_data["$player_name,whitelisted"]:-NO}"
                        local old_blacklisted="${old_players_data["$player_name,blacklisted"]:-NO}"
                        local new_blacklisted="${players_data["$player_name,blacklisted"]:-NO}"
                        local player_ip="${players_data["$player_name,ip"]}"
                        local player_password="${players_data["$player_name,password"]}"
                        
                        if [ "$player_password" = "NONE" ] || [ "$player_ip" = "UNKNOWN" ] || [ -z "${player_verified[$player_name]}" ]; then
                            if [ "$new_rank" != "NONE" ]; then
                                print_warning "Player $player_name lacks password or IP verification - resetting rank to NONE"
                                update_players_log "$player_name" "rank" "NONE"
                                continue
                            fi
                        fi
                        
                        if [ "$old_rank" != "$new_rank" ] && [ "$player_password" != "NONE" ] && [ "$player_ip" != "UNKNOWN" ] && [ -n "${player_verified[$player_name]}" ]; then
                            handle_rank_change "$player_name" "$old_rank" "$new_rank"
                        fi
                        
                        if [ "$old_whitelisted" != "$new_whitelisted" ]; then
                            handle_whitelist_change "$player_name" "$old_whitelisted" "$new_whitelisted"
                        fi
                        
                        if [ "$old_blacklisted" != "$new_blacklisted" ]; then
                            handle_blacklist_change "$player_name" "$old_blacklisted" "$new_blacklisted" "$player_ip"
                        fi
                    fi
                done
                
                sync_server_lists
                last_modified="$current_modified"
            fi
        fi
        
        sleep 1
    done
}

# Main execution
main() {
    print_header "THE BLOCKHEADS RANK PATCHER"
    print_status "Starting player management system..."
    
    if [ ! -f "$CONSOLE_LOG" ]; then
        print_error "Console log not found: $CONSOLE_LOG"
        print_status "Waiting for log file to be created..."
        
        local wait_time=0
        while [ ! -f "$CONSOLE_LOG" ] && [ $wait_time -lt 30 ]; do
            sleep 1
            wait_time=$((wait_time + 1))
        done
        
        if [ ! -f "$CONSOLE_LOG" ]; then
            print_error "Console log never appeared: $CONSOLE_LOG"
            exit 1
        fi
    fi
    
    monitor_console_log &
    local console_pid=$!
    
    monitor_players_log &
    local players_pid=$!
    
    # Main loop for timeout checking - CORREGIDO: se ejecuta check_timeouts en monitor_console_log
    while true; do
        sleep 5
    done
    
    wait $console_pid $players_pid
}

# Start main function
main
