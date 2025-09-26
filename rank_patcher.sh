#!/bin/bash
# rank_patcher.sh - Centralized player management system for The Blockheads server

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_status() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_header() {
    echo -e "${MAGENTA}================================================================"
    echo -e "$1"
    echo -e "===============================================================${NC}"
}

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USER_HOME="$HOME"
BASE_SAVES_DIR="$USER_HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves"

# Function to find the world directory
find_world_directory() {
    local world_dir=""
    
    # Check if world ID is provided as argument
    if [ $# -eq 1 ] && [ -n "$1" ]; then
        world_dir="$BASE_SAVES_DIR/$1"
        [ -d "$world_dir" ] && echo "$world_dir" && return 0
    fi
    
    # Auto-detect world directory
    if [ -d "$BASE_SAVES_DIR" ]; then
        # Find first directory that looks like a world
        for dir in "$BASE_SAVES_DIR"/*; do
            if [ -d "$dir" ] && [[ "$(basename "$dir")" =~ ^[a-f0-9]{32}$ ]]; then
                world_dir="$dir"
                break
            fi
        done
    fi
    
    [ -z "$world_dir" ] && print_error "No world directory found" && return 1
    echo "$world_dir"
}

# Function to get world ID from directory
get_world_id() {
    local world_dir="$1"
    basename "$world_dir"
}

# Function to initialize players.log
initialize_players_log() {
    local world_dir="$1"
    local players_log="$world_dir/players.log"
    
    if [ ! -f "$players_log" ]; then
        print_status "Creating players.log in $world_dir"
        touch "$players_log"
        echo "# Player Name | First IP | Password | Rank | Whitelisted | Blacklisted" > "$players_log"
        echo "# Format: PLAYER_NAME | IP | PASSWORD | RANK | WHITELISTED | BLACKLISTED" >> "$players_log"
        print_success "players.log created successfully"
    fi
}

# Function to skip first two lines of a file
skip_header() {
    tail -n +3 "$1" 2>/dev/null
}

# Function to sync lists from players.log
sync_lists_from_players_log() {
    local world_dir="$1"
    local players_log="$world_dir/players.log"
    
    [ ! -f "$players_log" ] && return 1
    
    # Initialize list files if they don't exist
    local admin_list="$world_dir/adminlist.txt"
    local mod_list="$world_dir/modlist.txt"
    local whitelist="$world_dir/whitelist.txt"
    local blacklist="$world_dir/blacklist.txt"
    
    for list_file in "$admin_list" "$mod_list" "$whitelist" "$blacklist"; do
        if [ ! -f "$list_file" ]; then
            echo "# Usernames in this file are granted special privileges" > "$list_file"
            echo "# Add one username per line" >> "$list_file"
        fi
    done
    
    # Clear existing content (keeping headers)
    echo "# Usernames in this file are granted special privileges" > "$admin_list"
    echo "# Add one username per line" >> "$admin_list"
    
    echo "# Usernames in this file are granted special privileges" > "$mod_list"
    echo "# Add one username per line" >> "$mod_list"
    
    echo "# Usernames in this file are granted special privileges" > "$whitelist"
    echo "# Add one username per line" >> "$whitelist"
    
    echo "# Usernames in this file are granted special privileges" > "$blacklist"
    echo "# Add one username per line" >> "$blacklist"
    
    # Process players.log and update lists
    while IFS='|' read -r player_name ip password rank whitelisted blacklisted; do
        # Clean variables
        player_name=$(echo "$player_name" | xargs)
        ip=$(echo "$ip" | xargs)
        rank=$(echo "$rank" | xargs)
        whitelisted=$(echo "$whitelisted" | xargs)
        blacklisted=$(echo "$blacklisted" | xargs)
        
        # Skip unknown or invalid entries
        [ "$player_name" = "UNKNOWN" ] || [ -z "$player_name" ] && continue
        [ "$ip" = "UNKNOWN" ] && continue
        
        # Add to appropriate lists based on rank and status
        case "$rank" in
            "ADMIN")
                echo "$player_name" >> "$admin_list"
                ;;
            "MOD")
                echo "$player_name" >> "$mod_list"
                ;;
            "SUPER")
                echo "$player_name" >> "$admin_list"
                # Also add to global admin list
                local global_admin_list="$USER_HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/cloudWideOwnedAdminlist.txt"
                mkdir -p "$(dirname "$global_admin_list")"
                if [ ! -f "$global_admin_list" ]; then
                    echo "# Cloud-wide admin list" > "$global_admin_list"
                    echo "# Add one username per line" >> "$global_admin_list"
                fi
                if ! grep -q "^$player_name$" "$global_admin_list"; then
                    echo "$player_name" >> "$global_admin_list"
                fi
                ;;
        esac
        
        # Handle whitelist/blacklist
        if [ "$whitelisted" = "YES" ]; then
            echo "$player_name" >> "$whitelist"
        fi
        
        if [ "$blacklisted" = "YES" ]; then
            echo "$player_name" >> "$blacklist"
        fi
    done < <(skip_header "$players_log")
    
    print_success "Lists synchronized from players.log"
}

# Function to send command to server
send_server_command() {
    local command="$1"
    local world_id="$2"
    local screen_session="blockheads_server_$world_id"
    
    # Wait cooldown
    sleep 0.5
    
    if screen -list | grep -q "$screen_session"; then
        screen -S "$screen_session" -X stuff "$command$(printf \\r)"
        print_status "Sent command: $command"
    else
        print_warning "Server session not found: $screen_session"
    fi
}

# Function to process rank changes
process_rank_changes() {
    local world_dir="$1"
    local players_log="$world_dir/players.log"
    local world_id="$2"
    
    [ ! -f "$players_log" ] && return 1
    
    # This function would compare previous and current state to detect changes
    # For simplicity, we'll implement the change detection in the main loop
    print_status "Checking for rank changes..."
}

# Function to handle password commands
handle_password_command() {
    local player_name="$1"
    local password="$2"
    local confirm_password="$3"
    local world_id="$4"
    
    # Validate password
    if [ "${#password}" -lt 7 ] || [ "${#password}" -gt 16 ]; then
        send_server_command "/clear" "$world_id"
        send_server_command "Password must be between 7 and 16 characters" "$world_id"
        return 1
    fi
    
    if [ "$password" != "$confirm_password" ]; then
        send_server_command "/clear" "$world_id"
        send_server_command "Passwords do not match" "$world_id"
        return 1
    fi
    
    # Update players.log
    local world_dir="$BASE_SAVES_DIR/$world_id"
    local players_log="$world_dir/players.log"
    
    if [ -f "$players_log" ]; then
        # Check if player exists
        if grep -q "^$player_name |" "$players_log"; then
            # Update existing player
            sed -i "s/^$player_name | [^|]* | [^|]* |/$player_name | UNKNOWN | $password |/" "$players_log"
        else
            # Add new player
            echo "$player_name | UNKNOWN | $password | NONE | NO | NO" >> "$players_log"
        fi
        
        send_server_command "/clear" "$world_id"
        send_server_command "Password set successfully!" "$world_id"
        return 0
    else
        send_server_command "/clear" "$world_id"
        send_server_command "Error: players.log not found" "$world_id"
        return 1
    fi
}

# Function to handle IP change verification
handle_ip_change() {
    local player_name="$1"
    local password="$2"
    local new_ip="$3"
    local world_id="$4"
    
    local world_dir="$BASE_SAVES_DIR/$world_id"
    local players_log="$world_dir/players.log"
    
    [ ! -f "$players_log" ] && return 1
    
    # Verify password
    local stored_password=$(grep "^$player_name |" "$players_log" | cut -d'|' -f3 | xargs)
    if [ "$stored_password" != "$password" ]; then
        send_server_command "/clear" "$world_id"
        send_server_command "Invalid password" "$world_id"
        return 1
    fi
    
    # Update IP in players.log
    sed -i "s/^$player_name | [^|]* |/$player_name | $new_ip |/" "$players_log"
    
    send_server_command "/clear" "$world_id"
    send_server_command "IP address updated successfully!" "$world_id"
    return 0
}

# Function to handle password change
handle_password_change() {
    local player_name="$1"
    local old_password="$2"
    local new_password="$3"
    local world_id="$4"
    
    local world_dir="$BASE_SAVES_DIR/$world_id"
    local players_log="$world_dir/players.log"
    
    [ ! -f "$players_log" ] && return 1
    
    # Verify old password
    local stored_password=$(grep "^$player_name |" "$players_log" | cut -d'|' -f3 | xargs)
    if [ "$stored_password" != "$old_password" ]; then
        send_server_command "/clear" "$world_id"
        send_server_command "Invalid old password" "$world_id"
        return 1
    fi
    
    # Validate new password
    if [ "${#new_password}" -lt 7 ] || [ "${#new_password}" -gt 16 ]; then
        send_server_command "/clear" "$world_id"
        send_server_command "New password must be between 7 and 16 characters" "$world_id"
        return 1
    fi
    
    # Update password
    sed -i "s/^$player_name | [^|]* | [^|]* |/$player_name | UNKNOWN | $new_password |/" "$players_log"
    
    send_server_command "/clear" "$world_id"
    send_server_command "Password changed successfully!" "$world_id"
    return 0
}

# Function to monitor console.log for commands
monitor_console_log() {
    local world_dir="$1"
    local world_id="$2"
    local console_log="$world_dir/console.log"
    
    [ ! -f "$console_log" ] && return 1
    
    print_status "Monitoring console.log for commands..."
    
    # Track last processed line
    local last_line=$(wc -l < "$console_log" 2>/dev/null || echo 0)
    
    while true; do
        sleep 1
        
        # Check if console.log exists and has new content
        if [ ! -f "$console_log" ]; then
            sleep 5
            continue
        fi
        
        local current_line=$(wc -l < "$console_log" 2>/dev/null || echo 0)
        
        if [ "$current_line" -gt "$last_line" ]; then
            # Process new lines
            local new_lines=$((current_line - last_line))
            tail -n "$new_lines" "$console_log" | while IFS= read -r line; do
                # Detect player commands in chat
                if [[ "$line" =~ ([a-zA-Z0-9_]+):\ !password\ ([^\ ]+)\ ([^\ ]+) ]]; then
                    local player_name="${BASH_REMATCH[1]}"
                    local password="${BASH_REMATCH[2]}"
                    local confirm_password="${BASH_REMATCH[3]}"
                    
                    print_status "Detected password command from $player_name"
                    handle_password_command "$player_name" "$password" "$confirm_password" "$world_id"
                    
                elif [[ "$line" =~ ([a-zA-Z0-9_]+):\ !ip_change\ ([^\ ]+) ]]; then
                    local player_name="${BASH_REMATCH[1]}"
                    local password="${BASH_REMATCH[2]}"
                    # Extract IP from the connection line (this would need more sophisticated parsing)
                    local new_ip="UNKNOWN"  # This would need to be extracted from connection logs
                    
                    print_status "Detected IP change request from $player_name"
                    handle_ip_change "$player_name" "$password" "$new_ip" "$world_id"
                    
                elif [[ "$line" =~ ([a-zA-Z0-9_]+):\ !change_psw\ ([^\ ]+)\ ([^\ ]+) ]]; then
                    local player_name="${BASH_REMATCH[1]}"
                    local old_password="${BASH_REMATCH[2]}"
                    local new_password="${BASH_REMATCH[3]}"
                    
                    print_status "Detected password change from $player_name"
                    handle_password_change "$player_name" "$old_password" "$new_password" "$world_id"
                fi
                
                # Detect player connections to update IP
                if [[ "$line" =~ Player\ Connected\ ([a-zA-Z0-9_]+)\ \|\ ([0-9.]+) ]]; then
                    local player_name="${BASH_REMATCH[1]}"
                    local ip_address="${BASH_REMATCH[2]}"
                    
                    print_status "Player connected: $player_name from $ip_address"
                    update_player_ip "$player_name" "$ip_address" "$world_id"
                fi
            done
            
            last_line="$current_line"
        fi
    done
}

# Function to update player IP in players.log
update_player_ip() {
    local player_name="$1"
    local ip_address="$2"
    local world_id="$3"
    
    local world_dir="$BASE_SAVES_DIR/$world_id"
    local players_log="$world_dir/players.log"
    
    [ ! -f "$players_log" ] && return 1
    
    # Check if player exists
    if grep -q "^$player_name |" "$players_log"; then
        # Get current IP
        local current_ip=$(grep "^$player_name |" "$players_log" | cut -d'|' -f2 | xargs)
        
        if [ "$current_ip" = "UNKNOWN" ]; then
            # First time connection, set IP
            sed -i "s/^$player_name | UNKNOWN |/$player_name | $ip_address |/" "$players_log"
            print_success "Set IP for $player_name: $ip_address"
        elif [ "$current_ip" != "$ip_address" ]; then
            # IP changed, require verification
            print_warning "IP change detected for $player_name: $current_ip -> $ip_address"
            send_server_command "IP change detected! Please verify with !ip_change YOUR_PASSWORD within 30 seconds" "$world_id"
            
            # Schedule kick if not verified within 30 seconds
            (
                sleep 30
                # Check if IP was updated
                local updated_ip=$(grep "^$player_name |" "$players_log" | cut -d'|' -f2 | xargs)
                if [ "$updated_ip" != "$ip_address" ]; then
                    send_server_command "/kick $player_name" "$world_id"
                    send_server_command "/ban $ip_address" "$world_id"
                    print_warning "Kicked and banned $player_name for unverified IP change"
                    
                    # Unban after 30 seconds
                    (
                        sleep 30
                        # This would need server command to unban IP
                        print_status "Auto-unbanning IP: $ip_address"
                    ) &
                fi
            ) &
        fi
    else
        # New player, add to players.log
        echo "$player_name | $ip_address | NONE | NONE | NO | NO" >> "$players_log"
        print_success "Added new player: $player_name"
        
        # Request password creation
        send_server_command "Welcome $player_name! Please create a password with !password NEW_PASSWORD CONFIRM_PASSWORD within 60 seconds" "$world_id"
        
        # Schedule kick if no password created
        (
            sleep 60
            local player_password=$(grep "^$player_name |" "$players_log" | cut -d'|' -f3 | xargs)
            if [ "$player_password" = "NONE" ]; then
                send_server_command "/kick $player_name" "$world_id"
                print_warning "Kicked $player_name for not creating password"
            fi
        ) &
    fi
}

# Function to monitor players.log for changes
monitor_players_log() {
    local world_dir="$1"
    local world_id="$2"
    local players_log="$world_dir/players.log"
    
    [ ! -f "$players_log" ] && return 1
    
    print_status "Monitoring players.log for changes..."
    
    local last_hash=$(md5sum "$players_log" 2>/dev/null | cut -d' ' -f1)
    
    while true; do
        sleep 1
        
        local current_hash=$(md5sum "$players_log" 2>/dev/null | cut -d' ' -f1)
        
        if [ "$current_hash" != "$last_hash" ]; then
            print_status "players.log changed, processing updates..."
            
            # Sync lists
            sync_lists_from_players_log "$world_dir"
            
            # Process rank changes (simplified implementation)
            process_rank_changes_simple "$world_dir" "$world_id"
            
            last_hash="$current_hash"
        fi
    done
}

# Simplified rank change processor
process_rank_changes_simple() {
    local world_dir="$1"
    local world_id="$2"
    local players_log="$world_dir/players.log"
    
    [ ! -f "$players_log" ] && return 1
    
    # This is a simplified version - in a real implementation you would track previous state
    while IFS='|' read -r player_name ip password rank whitelisted blacklisted; do
        player_name=$(echo "$player_name" | xargs)
        rank=$(echo "$rank" | xargs)
        blacklisted=$(echo "$blacklisted" | xargs)
        
        [ -z "$player_name" ] || [ "$player_name" = "UNKNOWN" ] && continue
        
        # Handle blacklist changes
        if [ "$blacklisted" = "YES" ]; then
            send_server_command "/unmod $player_name" "$world_id"
            send_server_command "/unadmin $player_name" "$world_id"
            send_server_command "/ban $player_name" "$world_id"
            send_server_command "/ban $ip" "$world_id"
            print_warning "Blacklisted player: $player_name"
        fi
        
        # Handle rank changes (simplified)
        case "$rank" in
            "ADMIN")
                send_server_command "/admin $player_name" "$world_id"
                ;;
            "MOD")
                send_server_command "/mod $player_name" "$world_id"
                ;;
            "SUPER")
                # Handle super admin
                local global_admin_list="$USER_HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/cloudWideOwnedAdminlist.txt"
                mkdir -p "$(dirname "$global_admin_list")"
                if [ ! -f "$global_admin_list" ] || ! grep -q "^$player_name$" <(skip_header "$global_admin_list"); then
                    echo "$player_name" >> "$global_admin_list"
                fi
                send_server_command "/admin $player_name" "$world_id"
                ;;
            "NONE")
                # Demote if previously had rank
                send_server_command "/unmod $player_name" "$world_id"
                send_server_command "/unadmin $player_name" "$world_id"
                ;;
        esac
    done < <(skip_header "$players_log")
}

# Main function
main() {
    print_header "THE BLOCKHEADS RANK PATCHER"
    
    # Find world directory
    local world_dir
    world_dir=$(find_world_directory "$1")
    [ $? -ne 0 ] && exit 1
    
    local world_id=$(get_world_id "$world_dir")
    
    print_status "World directory: $world_dir"
    print_status "World ID: $world_id"
    
    # Initialize players.log
    initialize_players_log "$world_dir"
    
    # Initial sync
    sync_lists_from_players_log "$world_dir"
    
    # Start monitoring processes
    monitor_console_log "$world_dir" "$world_id" &
    local console_monitor_pid=$!
    
    monitor_players_log "$world_dir" "$world_id" &
    local players_monitor_pid=$!
    
    print_success "Rank patcher started successfully"
    print_status "Monitoring console.log and players.log"
    print_status "Press Ctrl+C to stop"
    
    # Wait for processes
    wait $console_monitor_pid $players_monitor_pid
}

# Handle script termination
cleanup() {
    print_status "Stopping rank patcher..."
    kill $(jobs -p) 2>/dev/null
    print_success "Rank patcher stopped"
    exit 0
}

trap cleanup EXIT INT TERM

# Start main function
if [ $# -eq 1 ]; then
    main "$1"
else
    main
fi
