#!/bin/bash

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_step() {
    echo -e "${CYAN}[STEP]${NC} $1"
}

print_header() {
    echo -e "${MAGENTA}================================================================================${NC}"
    echo -e "${MAGENTA}$1${NC}"
    echo -e "${MAGENTA}================================================================================${NC}"
}

# Configuration
USER_HOME="$HOME"
APPLICATION_SUPPORT="$USER_HOME/GNUstep/Library/ApplicationSupport/TheBlockheads"
SAVES_DIR="$APPLICATION_SUPPORT/saves"

# Function to wait for cooldown
cooldown() {
    sleep 0.5
}

# Function to send command to server
send_command() {
    local command="$1"
    local world_dir="$2"
    
    cooldown
    echo "$command" >> "$world_dir/console.log"
    print_status "Sent command: $command"
}

# Function to get current world directory
get_world_dir() {
    local world_id=""
    
    # Look for active world directories
    for dir in "$SAVES_DIR"/*; do
        if [ -d "$dir" ] && [[ "$dir" =~ [0-9a-f]{32} ]]; then
            if [ -f "$dir/console.log" ]; then
                world_id=$(basename "$dir")
                break
            fi
        fi
    done
    
    echo "$world_id"
}

# Function to create players.log if it doesn't exist
create_players_log() {
    local world_dir="$1"
    local players_log="$world_dir/players.log"
    
    if [ ! -f "$players_log" ]; then
        print_step "Creating players.log file..."
        touch "$players_log"
        print_success "players.log created at: $players_log"
    fi
}

# Function to ignore first two lines of a file
ignore_first_two_lines() {
    tail -n +3 "$1"
}

# Function to sync_lists from players.log
sync_lists() {
    local world_dir="$1"
    local players_log="$world_dir/players.log"
    
    # Clear lists but keep structure (first two lines)
    for list in adminlist modlist whitelist blacklist; do
        local list_file="$world_dir/$list.txt"
        if [ -f "$list_file" ]; then
            head -n 2 "$list_file" > "${list_file}.tmp"
            mv "${list_file}.tmp" "$list_file"
        fi
    done
    
    # Sync from players.log
    while IFS='|' read -r player ip password rank whitelisted blacklisted; do
        # Clean variables
        player=$(echo "$player" | xargs)
        ip=$(echo "$ip" | xargs)
        rank=$(echo "$rank" | xargs)
        whitelisted=$(echo "$whitelisted" | xargs)
        blacklisted=$(echo "$blacklisted" | xargs)
        
        # Skip unknown or invalid entries
        [[ "$player" == "UNKNOWN" ]] && continue
        [[ "$ip" == "UNKNOWN" ]] && continue
        
        # Add to appropriate lists based on rank and status
        case "$rank" in
            "ADMIN")
                echo "$player" >> "$world_dir/adminlist.txt"
                ;;
            "MOD")
                echo "$player" >> "$world_dir/modlist.txt"
                ;;
            "SUPER")
                # Also add to adminlist for super users
                echo "$player" >> "$world_dir/adminlist.txt"
                ;;
        esac
        
        # Handle whitelist/blacklist
        if [[ "$whitelisted" == "YES" ]]; then
            echo "$player" >> "$world_dir/whitelist.txt"
        fi
        
        if [[ "$blacklisted" == "YES" ]]; then
            echo "$player" >> "$world_dir/blacklist.txt"
        fi
        
    done < <(ignore_first_two_lines "$players_log")
    
    print_success "Lists synchronized from players.log"
}

# Function to handle rank changes
handle_rank_changes() {
    local world_dir="$1"
    local players_log="$world_dir/players.log"
    local temp_file="/tmp/players_temp.$$"
    
    # Create temp copy for comparison
    cp "$players_log" "$temp_file"
    
    # Monitor for changes
    inotifywait -q -e modify "$players_log" | while read; do
        print_step "players.log modified - checking for changes..."
        
        # Compare and find changes
        while IFS='|' read -r player ip password new_rank new_whitelisted new_blacklisted; do
            player=$(echo "$player" | xargs)
            new_rank=$(echo "$new_rank" | xargs)
            
            # Find old rank from temp file
            old_entry=$(grep "^$player|" "$temp_file" | head -1)
            if [ -n "$old_entry" ]; then
                IFS='|' read -r old_player old_ip old_password old_rank old_whitelisted old_blacklisted <<< "$old_entry"
                old_rank=$(echo "$old_rank" | xargs)
                
                # Handle rank changes
                if [[ "$new_rank" != "$old_rank" ]]; then
                    case "$old_rank:$new_rank" in
                        "NONE:ADMIN")
                            send_command "/admin $player" "$world_dir"
                            ;;
                        "NONE:MOD")
                            send_command "/mod $player" "$world_dir"
                            ;;
                        "NONE:SUPER"|"ADMIN:SUPER"|"MOD:SUPER")
                            # Add to cloudWideOwnedAdminlist.txt
                            local cloud_list="$APPLICATION_SUPPORT/cloudWideOwnedAdminlist.txt"
                            if [ ! -f "$cloud_list" ]; then
                                touch "$cloud_list"
                                echo "# Cloud Wide Admin List" >> "$cloud_list"
                                echo "# Managed by rank_patcher.sh" >> "$cloud_list"
                            fi
                            if ! grep -q "$player" <(ignore_first_two_lines "$cloud_list"); then
                                echo "$player" >> "$cloud_list"
                            fi
                            send_command "/admin $player" "$world_dir"
                            ;;
                        "ADMIN:NONE")
                            send_command "/unadmin $player" "$world_dir"
                            ;;
                        "MOD:NONE")
                            send_command "/unmod $player" "$world_dir"
                            ;;
                        "SUPER:NONE"|"SUPER:ADMIN"|"SUPER:MOD")
                            # Remove from cloudWideOwnedAdminlist.txt
                            local cloud_list="$APPLICATION_SUPPORT/cloudWideOwnedAdminlist.txt"
                            if [ -f "$cloud_list" ]; then
                                grep -v "$player" <(ignore_first_two_lines "$cloud_list") > "${cloud_list}.tmp"
                                head -n 2 "$cloud_list" > "${cloud_list}.new"
                                cat "${cloud_list}.tmp" >> "${cloud_list}.new"
                                mv "${cloud_list}.new" "$cloud_list"
                                rm "${cloud_list}.tmp"
                            fi
                            
                            if [[ "$new_rank" == "NONE" ]]; then
                                send_command "/unadmin $player" "$world_dir"
                            fi
                            ;;
                    esac
                fi
                
                # Handle blacklist changes
                new_blacklisted=$(echo "$new_blacklisted" | xargs)
                old_blacklisted=$(echo "$old_blacklisted" | xargs)
                
                if [[ "$new_blacklisted" == "YES" && "$old_blacklisted" != "YES" ]]; then
                    if [[ "$old_rank" == "SUPER" ]]; then
                        send_command "/stop" "$world_dir"
                        cooldown
                    fi
                    
                    send_command "/unmod $player" "$world_dir"
                    cooldown
                    send_command "/unadmin $player" "$world_dir"
                    cooldown
                    send_command "/ban $player" "$world_dir"
                    cooldown
                    send_command "/ban $ip" "$world_dir"
                    
                    if [[ "$old_rank" == "SUPER" ]]; then
                        local cloud_list="$APPLICATION_SUPPORT/cloudWideOwnedAdminlist.txt"
                        if [ -f "$cloud_list" ]; then
                            grep -v "$player" <(ignore_first_two_lines "$cloud_list") > "${cloud_list}.tmp"
                            head -n 2 "$cloud_list" > "${cloud_list}.new"
                            cat "${cloud_list}.tmp" >> "${cloud_list}.new"
                            mv "${cloud_list}.new" "$cloud_list"
                            rm "${cloud_list}.tmp"
                        fi
                    fi
                fi
            fi
        done < <(ignore_first_two_lines "$players_log")
        
        # Update temp file
        cp "$players_log" "$temp_file"
        sync_lists "$world_dir"
    done
    
    rm -f "$temp_file"
}

# Function to monitor console.log for commands
monitor_console() {
    local world_dir="$1"
    local console_log="$world_dir/console.log"
    local players_log="$world_dir/players.log"
    
    # Create console.log if it doesn't exist
    touch "$console_log"
    
    # Track active players and their IPs
    declare -A player_ips
    declare -A password_timers
    declare -A ip_change_timers
    
    # Monitor console.log
    tail -F "$console_log" | while read line; do
        # Detect player connections
        if [[ "$line" =~ "Player Connected" ]]; then
            if [[ "$line" =~ ([A-Za-z0-9_]+)\ \|\ ([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)\ \|\ ([a-f0-9]+)$ ]]; then
                player="${BASH_REMATCH[1]}"
                current_ip="${BASH_REMATCH[2]}"
                player_hash="${BASH_REMATCH[3]}"
                
                player_ips["$player"]="$current_ip"
                
                # Check if player exists in players.log
                player_entry=$(grep "^$player|" "$players_log" | head -1)
                
                if [ -z "$player_entry" ]; then
                    # New player - add to players.log
                    echo "$player | $current_ip | NONE | NONE | NO | NO" >> "$players_log"
                    
                    # Request password creation
                    send_command "/clear" "$world_dir"
                    cooldown
                    send_command "/msg $player Please create a password using: !password YOUR_PASSWORD CONFIRM_PASSWORD" "$world_dir"
                    
                    # Set timer for password creation (1 minute)
                    password_timers["$player"]=$(date -d "+1 minute" +%s)
                    
                else
                    # Existing player - check IP and password
                    IFS='|' read -r stored_player stored_ip stored_password stored_rank stored_whitelisted stored_blacklisted <<< "$player_entry"
                    
                    stored_ip=$(echo "$stored_ip" | xargs)
                    stored_password=$(echo "$stored_password" | xargs)
                    
                    # Check IP change
                    if [[ "$stored_ip" != "UNKNOWN" && "$stored_ip" != "$current_ip" ]]; then
                        send_command "/clear" "$world_dir"
                        cooldown
                        send_command "/msg $player IP change detected! Verify with: !ip_change YOUR_PASSWORD" "$world_dir"
                        send_command "/msg $player You have 30 seconds to verify your new IP." "$world_dir"
                        
                        # Set timer for IP verification (30 seconds)
                        ip_change_timers["$player"]=$(date -d "+30 seconds" +%s)
                    fi
                    
                    # Check if player has no password
                    if [[ "$stored_password" == "NONE" ]]; then
                        send_command "/clear" "$world_dir"
                        cooldown
                        send_command "/msg $player Please create a password using: !password YOUR_PASSWORD CONFIRM_PASSWORD" "$world_dir"
                        
                        # Set timer for password creation (1 minute)
                        password_timers["$player"]=$(date -d "+1 minute" +%s)
                    fi
                fi
            fi
        fi
        
        # Detect chat messages and commands
        if [[ "$line" =~ ([A-Za-z0-9_]+):\ (![a-z_]+) ]]; then
            player="${BASH_REMATCH[1]}"
            full_command="${BASH_REMATCH[2]}"
            
            # Handle !password command
            if [[ "$full_command" =~ !password\ ([A-Za-z0-9]+)\ ([A-Za-z0-9]+) ]]; then
                password1="${BASH_REMATCH[1]}"
                password2="${BASH_REMATCH[2]}"
                
                handle_password_command "$player" "$password1" "$password2" "$world_dir"
            fi
            
            # Handle !ip_change command
            if [[ "$full_command" =~ !ip_change\ ([A-Za-z0-9]+) ]]; then
                password="${BASH_REMATCH[1]}"
                handle_ip_change_command "$player" "$password" "$world_dir"
            fi
            
            # Handle !change_psw command
            if [[ "$full_command" =~ !change_psw\ ([A-Za-z0-9]+)\ ([A-Za-z0-9]+) ]]; then
                old_password="${BASH_REMATCH[1]}"
                new_password="${BASH_REMATCH[2]}"
                handle_change_password_command "$player" "$old_password" "$new_password" "$world_dir"
            fi
        fi
        
        # Check timers
        current_time=$(date +%s)
        
        # Check password timers
        for player in "${!password_timers[@]}"; do
            if [ "$current_time" -gt "${password_timers[$player]}" ]; then
                send_command "/kick $player" "$world_dir"
                send_command "/msg $player You were kicked for not creating a password. Please reconnect and create one." "$world_dir"
                unset password_timers["$player"]
            fi
        done
        
        # Check IP change timers
        for player in "${!ip_change_timers[@]}"; do
            if [ "$current_time" -gt "${ip_change_timers[$player]}" ]; then
                ip="${player_ips[$player]}"
                send_command "/kick $player" "$world_dir"
                send_command "/ban $ip" "$world_dir"
                send_command "/msg $player IP change not verified. Banned for 30 seconds." "$world_dir"
                
                # Schedule unban after 30 seconds
                (
                    sleep 30
                    send_command "/unban $ip" "$world_dir"
                ) &
                
                unset ip_change_timers["$player"]
            fi
        done
        
    done
}

# Function to handle password creation
handle_password_command() {
    local player="$1"
    local password1="$2"
    local password2="$3"
    local world_dir="$4"
    local players_log="$world_dir/players.log"
    
    send_command "/clear" "$world_dir"
    cooldown
    
    # Validate password
    if [[ "$password1" != "$password2" ]]; then
        send_command "/msg $player Error: Passwords do not match." "$world_dir"
        return 1
    fi
    
    if [[ ${#password1} -lt 7 || ${#password1} -gt 16 ]]; then
        send_command "/msg $player Error: Password must be 7-16 characters." "$world_dir"
        return 1
    fi
    
    # Update players.log
    if [ -f "$players_log" ]; then
        temp_file="/tmp/players_update.$$"
        
        while IFS= read -r line; do
            if [[ "$line" =~ ^$player\| ]]; then
                IFS='|' read -r old_player old_ip old_password old_rank old_whitelisted old_blacklisted <<< "$line"
                echo "$player | $old_ip | $password1 | $old_rank | $old_whitelisted | $old_blacklisted" >> "$temp_file"
            else
                echo "$line" >> "$temp_file"
            fi
        done < "$players_log"
        
        mv "$temp_file" "$players_log"
        
        send_command "/msg $player Password created successfully!" "$world_dir"
        
        # Clear password timer
        unset password_timers["$player"]
    else
        send_command "/msg $player Error: System not ready. Please try again." "$world_dir"
    fi
}

# Function to handle IP change verification
handle_ip_change_command() {
    local player="$1"
    local password="$2"
    local world_dir="$3"
    local players_log="$world_dir/players.log"
    local current_ip="${player_ips[$player]}"
    
    send_command "/clear" "$world_dir"
    cooldown
    
    if [ -f "$players_log" ]; then
        player_entry=$(grep "^$player|" "$players_log" | head -1)
        
        if [ -n "$player_entry" ]; then
            IFS='|' read -r stored_player stored_ip stored_password stored_rank stored_whitelisted stored_blacklisted <<< "$player_entry"
            
            stored_password=$(echo "$stored_password" | xargs)
            
            if [[ "$stored_password" == "$password" ]]; then
                # Update IP in players.log
                temp_file="/tmp/players_update.$$"
                
                while IFS= read -r line; do
                    if [[ "$line" =~ ^$player\| ]]; then
                        echo "$player | $current_ip | $stored_password | $stored_rank | $stored_whitelisted | $stored_blacklisted" >> "$temp_file"
                    else
                        echo "$line" >> "$temp_file"
                    fi
                done < "$players_log"
                
                mv "$temp_file" "$players_log"
                
                send_command "/msg $player IP verification successful!" "$world_dir"
                
                # Clear IP change timer
                unset ip_change_timers["$player"]
            else
                send_command "/msg $player Error: Incorrect password." "$world_dir"
            fi
        else
            send_command "/msg $player Error: Player not found." "$world_dir"
        fi
    else
        send_command "/msg $player Error: System not ready. Please try again." "$world_dir"
    fi
}

# Function to handle password change
handle_change_password_command() {
    local player="$1"
    local old_password="$2"
    local new_password="$3"
    local world_dir="$4"
    local players_log="$world_dir/players.log"
    
    send_command "/clear" "$world_dir"
    cooldown
    
    # Validate new password
    if [[ ${#new_password} -lt 7 || ${#new_password} -gt 16 ]]; then
        send_command "/msg $player Error: New password must be 7-16 characters." "$world_dir"
        return 1
    fi
    
    if [ -f "$players_log" ]; then
        player_entry=$(grep "^$player|" "$players_log" | head -1)
        
        if [ -n "$player_entry" ]; then
            IFS='|' read -r stored_player stored_ip stored_password stored_rank stored_whitelisted stored_blacklisted <<< "$player_entry"
            
            stored_password=$(echo "$stored_password" | xargs)
            
            if [[ "$stored_password" == "$old_password" ]]; then
                # Update password in players.log
                temp_file="/tmp/players_update.$$"
                
                while IFS= read -r line; do
                    if [[ "$line" =~ ^$player\| ]]; then
                        echo "$player | $stored_ip | $new_password | $stored_rank | $stored_whitelisted | $stored_blacklisted" >> "$temp_file"
                    else
                        echo "$line" >> "$temp_file"
                    fi
                done < "$players_log"
                
                mv "$temp_file" "$players_log"
                
                send_command "/msg $player Password changed successfully!" "$world_dir"
            else
                send_command "/msg $player Error: Old password is incorrect." "$world_dir"
            fi
        else
            send_command "/msg $player Error: Player not found." "$world_dir"
        fi
    else
        send_command "/msg $player Error: System not ready. Please try again." "$world_dir"
    fi
}

# Main function
main() {
    print_header "THE BLOCKHEADS RANK PATCHER"
    
    # Wait for world to be created
    print_step "Waiting for world creation..."
    
    while true; do
        world_id=$(get_world_dir)
        
        if [ -n "$world_id" ]; then
            world_dir="$SAVES_DIR/$world_id"
            print_success "Found world: $world_id"
            break
        fi
        
        sleep 5
    done
    
    # Create players.log if it doesn't exist
    create_players_log "$world_dir"
    
    # Initial sync of lists
    sync_lists "$world_dir"
    
    print_step "Starting monitoring processes..."
    
    # Start rank change monitoring in background
    handle_rank_changes "$world_dir" &
    
    # Start console monitoring in background
    monitor_console "$world_dir" &
    
    print_success "Rank patcher is now running!"
    print_status "Monitoring world: $world_id"
    print_status "Players log: $world_dir/players.log"
    print_status "Console log: $world_dir/console.log"
    
    # Wait for background processes
    wait
}

# Check dependencies
check_dependencies() {
    local deps=("inotifywait" "tail" "grep" "sed")
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            print_error "Missing dependency: $dep"
            print_status "Please install: inotify-tools"
            exit 1
        fi
    done
}

# Run main function
check_dependencies
main
