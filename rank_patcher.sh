#!/bin/bash
# =============================================================================
# THE BLOCKHEADS RANK PATCHER - CENTRAL PLAYER MANAGEMENT SYSTEM
# =============================================================================

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
print_step() { echo -e "${CYAN}[STEP]${NC} $1"; }
print_header() {
    echo -e "${MAGENTA}================================================================================${NC}"
    echo -e "${MAGENTA}$1${NC}"
    echo -e "${MAGENTA}================================================================================${NC}"
}

# Global variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOME_DIR="$HOME"
BASE_SAVES_DIR="$HOME_DIR/GNUstep/Library/ApplicationSupport/TheBlockheads/saves"
PLAYERS_LOG=""
CONSOLE_LOG=""
SCREEN_SESSION=""
WORLD_ID=""
PORT=""

# Track connected players and their states
declare -A connected_players
declare -A player_ip_map
declare -A player_password_timers
declare -A player_ip_grace_timers
declare -A player_verification_status
declare -A player_password_reminder_sent
declare -A player_kick_timers

# Function to find world directory and set paths
setup_paths() {
    local port="$1"
    
    # Try to find world ID from port
    if [ -f "world_id_$port.txt" ]; then
        WORLD_ID=$(cat "world_id_$port.txt")
        print_success "Found world ID: $WORLD_ID for port $port"
    else
        # Find the most recent world directory
        WORLD_ID=$(find "$BASE_SAVES_DIR" -maxdepth 1 -type d -name "*" | grep -v "^$BASE_SAVES_DIR$" | head -1 | xargs basename)
        if [ -n "$WORLD_ID" ]; then
            echo "$WORLD_ID" > "world_id_$port.txt"
            print_success "Auto-detected world ID: $WORLD_ID"
        else
            print_error "No world found. Please create a world first."
            exit 1
        fi
    fi
    
    PLAYERS_LOG="$BASE_SAVES_DIR/$WORLD_ID/players.log"
    CONSOLE_LOG="$BASE_SAVES_DIR/$WORLD_ID/console.log"
    SCREEN_SESSION="blockheads_server_$port"
    
    # Create players.log if it doesn't exist
    [ ! -f "$PLAYERS_LOG" ] && touch "$PLAYERS_LOG"
    
    # Initialize list files as EMPTY (keeping only first line)
    initialize_list_files
    
    print_status "Players log: $PLAYERS_LOG"
    print_status "Console log: $CONSOLE_LOG"
    print_status "Screen session: $SCREEN_SESSION"
}

# Function to initialize list files as empty (keeping only first line)
initialize_list_files() {
    local world_dir="$BASE_SAVES_DIR/$WORLD_ID"
    local cloud_file="$HOME_DIR/GNUstep/Library/ApplicationSupport/TheBlockheads/cloudWideOwnedAdminlist.txt"
    
    # List of files to initialize
    local list_files=(
        "$world_dir/adminlist.txt"
        "$world_dir/modlist.txt" 
        "$world_dir/whitelist.txt"
        "$world_dir/blacklist.txt"
    )
    
    for file_path in "${list_files[@]}"; do
        if [ -f "$file_path" ]; then
            local first_line=$(head -1 "$file_path")
            > "$file_path"  # Empty the file
            [ -n "$first_line" ] && echo "$first_line" >> "$file_path"
            print_success "Initialized as empty: $(basename "$file_path")"
        else
            touch "$file_path"
            print_status "Created empty: $(basename "$file_path")"
        fi
    done
    
    # Cloud admin file should be empty initially
    if [ -f "$cloud_file" ]; then
        local first_line=$(head -1 "$cloud_file")
        > "$cloud_file"
        [ -n "$first_line" ] && echo "$first_line" >> "$cloud_file"
    else
        touch "$cloud_file"
    fi
    
    print_success "All list files initialized as empty"
}

# Function to execute server command with cooldown
execute_server_command() {
    local command="$1"
    print_status "Executing server command: $command"
    send_server_command "$SCREEN_SESSION" "$command"
    sleep 0.5  # Cooldown as required
}

# Function to send command to screen session
send_server_command() {
    local screen_session="$1"
    local command="$2"
    if screen -S "$screen_session" -p 0 -X stuff "$command$(printf \\r)" 2>/dev/null; then
        print_success "Sent command to server: $command"
        return 0
    else
        print_error "Could not send command to server"
        return 1
    fi
}

# Function to check if screen session exists
screen_session_exists() {
    screen -list | grep -q "$1"
}

# Function to validate player name
is_valid_player_name() {
    local name="$1"
    [[ "$name" =~ ^[a-zA-Z0-9_]{1,16}$ ]]
}

# Function to get player info from players.log
get_player_info() {
    local player_name="$1"
    if [ -f "$PLAYERS_LOG" ]; then
        while IFS='|' read -r name first_ip password rank whitelisted blacklisted; do
            # Clean up fields from spaces
            name=$(echo "$name" | xargs)
            first_ip=$(echo "$first_ip" | xargs)
            password=$(echo "$password" | xargs)
            rank=$(echo "$rank" | xargs)
            whitelisted=$(echo "$whitelisted" | xargs)
            blacklisted=$(echo "$blacklisted" | xargs)
            
            if [ "$name" = "$player_name" ]; then
                echo "$first_ip|$password|$rank|$whitelisted|$blacklisted"
                return 0
            fi
        done < <(grep -i "^$player_name|" "$PLAYERS_LOG")
    fi
    echo ""
}

# Function to update player info in players.log
update_player_info() {
    local player_name="$1" first_ip="$2" password="$3" rank="$4" whitelisted="${5:-NO}" blacklisted="${6:-NO}"
    
    # Convert to uppercase as required
    player_name=$(echo "$player_name" | tr '[:lower:]' '[:upper:]')
    first_ip=$(echo "$first_ip" | tr '[:lower:]' '[:upper:]')
    password=$(echo "$password" | tr '[:lower:]' '[:upper:]')
    rank=$(echo "$rank" | tr '[:lower:]' '[:upper:]')
    whitelisted=$(echo "$whitelisted" | tr '[:lower:]' '[:upper:]')
    blacklisted=$(echo "$blacklisted" | tr '[:lower:]' '[:upper:]')
    
    # Handle UNKNOWN and NONE values
    [ -z "$first_ip" ] && first_ip="UNKNOWN"
    [ -z "$password" ] && password="NONE"
    [ -z "$rank" ] && rank="NONE"
    [ -z "$whitelisted" ] && whitelisted="NO"
    [ -z "$blacklisted" ] && blacklisted="NO"
    
    if [ -f "$PLAYERS_LOG" ]; then
        # Remove existing entry
        sed -i "/^$player_name|/Id" "$PLAYERS_LOG"
        # Add new entry with proper format
        echo "$player_name|$first_ip|$password|$rank|$whitelisted|$blacklisted" >> "$PLAYERS_LOG"
        print_success "Updated player: $player_name | $first_ip | $password | $rank | $whitelisted | $blacklisted"
    fi
}

# Function to sync lists from players.log (ONLY for verified players)
sync_lists_from_players_log() {
    local world_dir="$BASE_SAVES_DIR/$WORLD_ID"
    
    # List files to manage
    local ADMIN_LIST="$world_dir/adminlist.txt"
    local MOD_LIST="$world_dir/modlist.txt"
    local WHITE_LIST="$world_dir/whitelist.txt"
    local BLACK_LIST="$world_dir/blacklist.txt"
    local CLOUD_ADMIN_FILE="$HOME_DIR/GNUstep/Library/ApplicationSupport/TheBlockheads/cloudWideOwnedAdminlist.txt"
    
    # Clear existing lists (keeping first line as required)
    local admin_first_line=$(head -1 "$ADMIN_LIST")
    local mod_first_line=$(head -1 "$MOD_LIST")
    local white_first_line=$(head -1 "$WHITE_LIST")
    local black_first_line=$(head -1 "$BLACK_LIST")
    
    > "$ADMIN_LIST"
    > "$MOD_LIST"
    > "$WHITE_LIST"
    > "$BLACK_LIST"
    
    # Restore first lines
    [ -n "$admin_first_line" ] && echo "$admin_first_line" >> "$ADMIN_LIST"
    [ -n "$mod_first_line" ] && echo "$mod_first_line" >> "$MOD_LIST"
    [ -n "$white_first_line" ] && echo "$white_first_line" >> "$WHITE_LIST"
    [ -n "$black_first_line" ] && echo "$black_first_line" >> "$BLACK_LIST"
    
    # Clear cloud admin file (will be repopulated from SUPER admins)
    if [ -f "$CLOUD_ADMIN_FILE" ]; then
        local cloud_first_line=$(head -1 "$CLOUD_ADMIN_FILE")
        > "$CLOUD_ADMIN_FILE"
        [ -n "$cloud_first_line" ] && echo "$cloud_first_line" >> "$CLOUD_ADMIN_FILE"
    fi
    
    # Process players.log - ONLY add to lists if player is connected and verified
    if [ -f "$PLAYERS_LOG" ]; then
        while IFS='|' read -r name first_ip password rank whitelisted blacklisted; do
            # Clean fields
            name=$(echo "$name" | xargs)
            first_ip=$(echo "$first_ip" | xargs)
            rank=$(echo "$rank" | xargs)
            whitelisted=$(echo "$whitelisted" | xargs)
            blacklisted=$(echo "$blacklisted" | xargs)
            
            # Skip if player is not connected OR not IP verified
            if [ -z "${connected_players[$name]}" ] || [ "${player_verification_status[$name]}" != "verified" ]; then
                continue
            fi
            
            # Get current IP for connected player
            local current_ip="${player_ip_map[$name]}"
            
            # Add to appropriate lists based on rank and status
            case "$rank" in
                "ADMIN")
                    echo "$name" >> "$ADMIN_LIST"
                    ;;
                "MOD")
                    echo "$name" >> "$MOD_LIST"
                    ;;
                "SUPER")
                    # Add to cloud admin list
                    if ! grep -q "^$name$" "$CLOUD_ADMIN_FILE" 2>/dev/null; then
                        echo "$name" >> "$CLOUD_ADMIN_FILE"
                    fi
                    echo "$name" >> "$ADMIN_LIST"
                    ;;
            esac
            
            # Handle whitelist/blacklist
            if [ "$whitelisted" = "YES" ] && [ -n "$current_ip" ] && [ "$current_ip" != "UNKNOWN" ]; then
                echo "$current_ip" >> "$WHITE_LIST"
            fi
            
            if [ "$blacklisted" = "YES" ]; then
                echo "$name" >> "$BLACK_LIST"
                if [ -n "$current_ip" ] && [ "$current_ip" != "UNKNOWN" ]; then
                    echo "$current_ip" >> "$BLACK_LIST"
                fi
            fi
            
        done < "$PLAYERS_LOG"
    fi
    
    print_success "Synced lists from players.log (verified players only)"
}

# Function to apply rank changes using server commands
apply_rank_changes() {
    local player_name="$1" old_rank="$2" new_rank="$3"
    
    print_status "Applying rank change: $player_name from $old_rank to $new_rank"
    
    case "$old_rank" in
        "ADMIN")
            execute_server_command "/unadmin $player_name"
            ;;
        "MOD")
            execute_server_command "/unmod $player_name"
            ;;
        "SUPER")
            remove_from_cloud_admin "$player_name"
            execute_server_command "/unadmin $player_name"
            ;;
    esac
    
    case "$new_rank" in
        "ADMIN")
            execute_server_command "/admin $player_name"
            ;;
        "MOD")
            execute_server_command "/mod $player_name"
            ;;
        "SUPER")
            add_to_cloud_admin "$player_name"
            execute_server_command "/admin $player_name"
            ;;
    esac
    
    # Reload lists after changes
    execute_server_command "/load-lists"
}

# Function to add player to cloud admin list
add_to_cloud_admin() {
    local player_name="$1"
    local cloud_file="$HOME_DIR/GNUstep/Library/ApplicationSupport/TheBlockheads/cloudWideOwnedAdminlist.txt"
    
    [ ! -f "$cloud_file" ] && touch "$cloud_file"
    
    local first_line=$(head -1 "$cloud_file")
    > "$cloud_file"
    [ -n "$first_line" ] && echo "$first_line" >> "$cloud_file"
    
    if ! grep -q "^$player_name$" "$cloud_file" 2>/dev/null; then
        echo "$player_name" >> "$cloud_file"
        print_success "Added $player_name to cloud admin list"
    fi
}

# Function to remove player from cloud admin list
remove_from_cloud_admin() {
    local player_name="$1"
    local cloud_file="$HOME_DIR/GNUstep/Library/ApplicationSupport/TheBlockheads/cloudWideOwnedAdminlist.txt"
    
    if [ -f "$cloud_file" ]; then
        local first_line=$(head -1 "$cloud_file")
        local temp_file=$(mktemp)
        
        # Keep first line and remove the player
        [ -n "$first_line" ] && echo "$first_line" > "$temp_file"
        grep -v "^$player_name$" "$cloud_file" | tail -n +2 >> "$temp_file"
        
        # If only first line remains, remove the file
        if [ $(wc -l < "$temp_file") -le 1 ] || [ $(wc -l < "$temp_file") -eq 1 -a -z "$first_line" ]; then
            rm -f "$cloud_file"
            print_success "Removed cloud admin file (no super admins)"
        else
            mv "$temp_file" "$cloud_file"
        fi
        
        print_success "Removed $player_name from cloud admin list"
    fi
}

# Function to handle blacklist changes
handle_blacklist_change() {
    local player_name="$1" blacklisted="$2"
    local player_info=$(get_player_info "$player_name")
    
    if [ -n "$player_info" ]; then
        local first_ip=$(echo "$player_info" | cut -d'|' -f1)
        local password=$(echo "$player_info" | cut -d'|' -f2)
        local rank=$(echo "$player_info" | cut -d'|' -f3)
        local current_ip="${player_ip_map[$player_name]}"
        
        if [ "$blacklisted" = "YES" ]; then
            # Remove from roles and ban
            case "$rank" in
                "MOD")
                    execute_server_command "/unmod $player_name"
                    ;;
                "ADMIN"|"SUPER")
                    execute_server_command "/unadmin $player_name"
                    if [ "$rank" = "SUPER" ]; then
                        remove_from_cloud_admin "$player_name"
                    fi
                    ;;
            esac
            
            execute_server_command "/ban $player_name"
            if [ -n "$current_ip" ] && [ "$current_ip" != "UNKNOWN" ]; then
                execute_server_command "/ban $current_ip"
            fi
            
            print_success "Blacklisted player: $player_name"
        else
            # Unban player
            execute_server_command "/unban $player_name"
            if [ -n "$current_ip" ] && [ "$current_ip" != "UNKNOWN" ]; then
                execute_server_command "/unban $current_ip"
            fi
            print_success "Removed $player_name from blacklist"
        fi
        
        # Reload lists
        execute_server_command "/load-lists"
    fi
}

# Function to monitor players.log for changes
monitor_players_log() {
    local last_checksum=""
    local temp_file=$(mktemp)
    
    # Save initial state
    [ -f "$PLAYERS_LOG" ] && cp "$PLAYERS_LOG" "$temp_file"
    
    while true; do
        if [ -f "$PLAYERS_LOG" ]; then
            local current_checksum=$(md5sum "$PLAYERS_LOG" 2>/dev/null | cut -d' ' -f1)
            
            if [ "$current_checksum" != "$last_checksum" ]; then
                print_status "Detected change in players.log - processing changes..."
                process_players_log_changes "$temp_file"
                last_checksum="$current_checksum"
                cp "$PLAYERS_LOG" "$temp_file"
            fi
        fi
        
        sleep 1
    done
    
    rm -f "$temp_file"
}

# Function to process changes in players.log
process_players_log_changes() {
    local previous_file="$1"
    
    if [ ! -f "$previous_file" ] || [ ! -f "$PLAYERS_LOG" ]; then
        sync_lists_from_players_log
        return
    fi
    
    # Compare previous and current to detect specific changes
    while IFS='|' read -r name first_ip password rank whitelisted blacklisted; do
        name=$(echo "$name" | xargs)
        rank=$(echo "$rank" | xargs)
        blacklisted=$(echo "$blacklisted" | xargs)
        
        # Find previous state
        local previous_line=$(grep -i "^$name|" "$previous_file" 2>/dev/null | head -1)
        
        if [ -n "$previous_line" ]; then
            # Extract previous values
            local prev_first_ip=$(echo "$previous_line" | cut -d'|' -f2 | xargs)
            local prev_password=$(echo "$previous_line" | cut -d'|' -f3 | xargs)
            local prev_rank=$(echo "$previous_line" | cut -d'|' -f4 | xargs)
            local prev_whitelisted=$(echo "$previous_line" | cut -d'|' -f5 | xargs)
            local prev_blacklisted=$(echo "$previous_line" | cut -d'|' -f6 | xargs)
            
            # Check for rank changes
            if [ "$prev_rank" != "$rank" ]; then
                print_status "Rank change detected: $name from $prev_rank to $rank"
                apply_rank_changes "$name" "$prev_rank" "$rank"
            fi
            
            # Check for blacklist changes
            if [ "$prev_blacklisted" != "$blacklisted" ]; then
                print_status "Blacklist change detected: $name from $prev_blacklisted to $blacklisted"
                handle_blacklist_change "$name" "$blacklisted"
            fi
        fi
    done < "$PLAYERS_LOG"
    
    # Always sync lists after changes
    sync_lists_from_players_log
}

# Function to cancel password kick timer
cancel_password_kick_timer() {
    local player_name="$1"
    
    # Cancel the main kick timer
    if [ -n "${player_kick_timers[$player_name]}" ]; then
        kill "${player_kick_timers[$player_name]}" 2>/dev/null
        unset player_kick_timers["$player_name"]
        print_status "Cancelled kick timer for $player_name"
    fi
    
    # Also cancel the reminder timer
    if [ -n "${player_password_timers[$player_name]}" ]; then
        kill "${player_password_timers[$player_name]}" 2>/dev/null
        unset player_password_timers["$player_name"]
    fi
}

# Function to handle password creation
handle_password_creation() {
    local player_name="$1" password="$2" confirm_password="$3"
    
    # Clear chat IMMEDIATELY to hide password
    send_server_command "$SCREEN_SESSION" "/clear"
    sleep 0.1  # Minimal delay for clear to process
    
    # Validate password length (7-16 characters)
    if [ ${#password} -lt 7 ] || [ ${#password} -gt 16 ]; then
        send_server_command "$SCREEN_SESSION" "ERROR: $player_name, password must be between 7 and 16 characters."
        return 1
    fi
    
    # Validate password confirmation
    if [ "$password" != "$confirm_password" ]; then
        send_server_command "$SCREEN_SESSION" "ERROR: $player_name, passwords do not match."
        return 1
    fi
    
    # Update player info
    local player_info=$(get_player_info "$player_name")
    if [ -n "$player_info" ]; then
        local first_ip=$(echo "$player_info" | cut -d'|' -f1)
        local current_password=$(echo "$player_info" | cut -d'|' -f2)
        local rank=$(echo "$player_info" | cut -d'|' -f3)
        local whitelisted=$(echo "$player_info" | cut -d'|' -f4)
        local blacklisted=$(echo "$player_info" | cut -d'|' -f5)
        
        # Cancel ALL timers immediately when password is set
        cancel_password_kick_timer "$player_name"
        
        # Update player with new password
        update_player_info "$player_name" "$first_ip" "$password" "$rank" "$whitelisted" "$blacklisted"
        
        send_server_command "$SCREEN_SESSION" "SUCCESS: $player_name, your password has been set successfully."
        return 0
    else
        send_server_command "$SCREEN_SESSION" "ERROR: $player_name, player not found in registry."
        return 1
    fi
}

# Function to handle password change
handle_password_change() {
    local player_name="$1" old_password="$2" new_password="$3"
    
    # Clear chat IMMEDIATELY
    send_server_command "$SCREEN_SESSION" "/clear"
    sleep 0.1
    
    # Validate new password length (7-16 characters)
    if [ ${#new_password} -lt 7 ] || [ ${#new_password} -gt 16 ]; then
        send_server_command "$SCREEN_SESSION" "ERROR: $player_name, new password must be between 7 and 16 characters."
        return 1
    fi
    
    local player_info=$(get_player_info "$player_name")
    if [ -n "$player_info" ]; then
        local first_ip=$(echo "$player_info" | cut -d'|' -f1)
        local current_password=$(echo "$player_info" | cut -d'|' -f2)
        local rank=$(echo "$player_info" | cut -d'|' -f3)
        local whitelisted=$(echo "$player_info" | cut -d'|' -f4)
        local blacklisted=$(echo "$player_info" | cut -d'|' -f5)
        
        # Verify old password
        if [ "$current_password" != "$old_password" ]; then
            send_server_command "$SCREEN_SESSION" "ERROR: $player_name, old password is incorrect."
            return 1
        fi
        
        # Update password
        update_player_info "$player_name" "$first_ip" "$new_password" "$rank" "$whitelisted" "$blacklisted"
        
        send_server_command "$SCREEN_SESSION" "SUCCESS: $player_name, your password has been changed successfully."
        return 0
    else
        send_server_command "$SCREEN_SESSION" "ERROR: $player_name, player not found in registry."
        return 1
    fi
}

# Function to handle IP change verification
handle_ip_change() {
    local player_name="$1" password="$2" current_ip="$3"
    
    # Clear chat IMMEDIATELY
    send_server_command "$SCREEN_SESSION" "/clear"
    sleep 0.1
    
    local player_info=$(get_player_info "$player_name")
    if [ -n "$player_info" ]; then
        local first_ip=$(echo "$player_info" | cut -d'|' -f1)
        local current_password=$(echo "$player_info" | cut -d'|' -f2)
        local rank=$(echo "$player_info" | cut -d'|' -f3)
        local whitelisted=$(echo "$player_info" | cut -d'|' -f4)
        local blacklisted=$(echo "$player_info" | cut -d'|' -f5)
        
        # Verify password
        if [ "$current_password" != "$password" ]; then
            send_server_command "$SCREEN_SESSION" "ERROR: $player_name, password is incorrect."
            return 1
        fi
        
        # Update IP and mark as verified
        update_player_info "$player_name" "$first_ip" "$current_password" "$rank" "$whitelisted" "$blacklisted"
        player_verification_status["$player_name"]="verified"
        
        # Cancel grace period timer
        if [ -n "${player_ip_grace_timers[$player_name]}" ]; then
            kill "${player_ip_grace_timers[$player_name]}" 2>/dev/null
            unset player_ip_grace_timers["$player_name"]
        fi
        
        # Sync lists now that player is verified
        sync_lists_from_players_log
        
        send_server_command "$SCREEN_SESSION" "SUCCESS: $player_name, your IP has been verified and updated."
        return 0
    else
        send_server_command "$SCREEN_SESSION" "ERROR: $player_name, player not found in registry."
        return 1
    fi
}

# Function to start password reminder and enforcement
start_password_enforcement() {
    local player_name="$1"
    
    # First reminder after 5 seconds
    player_password_timers["$player_name"]=$(
        (
            sleep 5
            if [ -n "${connected_players[$player_name]}" ]; then
                local player_info=$(get_player_info "$player_name")
                if [ -n "$player_info" ]; then
                    local password=$(echo "$player_info" | cut -d'|' -f2)
                    if [ "$password" = "NONE" ]; then
                        execute_server_command "SECURITY: $player_name, please set your password with !psw PASSWORD CONFIRM_PASSWORD within 60 seconds or you will be kicked."
                        player_password_reminder_sent["$player_name"]=1
                    fi
                fi
            fi
        ) &
        echo $!
    )
    
    # Schedule kick after 60 seconds
    player_kick_timers["$player_name"]=$(
        (
            sleep 60
            if [ -n "${connected_players[$player_name]}" ]; then
                local player_info=$(get_player_info "$player_name")
                if [ -n "$player_info" ]; then
                    local password=$(echo "$player_info" | cut -d'|' -f2)
                    if [ "$password" = "NONE" ]; then
                        execute_server_command "/kick $player_name"
                        print_warning "Kicked $player_name for not setting password within 60 seconds"
                    fi
                fi
            fi
        ) &
        echo $!
    )
}

# Function to start IP grace period
start_ip_grace_period() {
    local player_name="$1" current_ip="$2"
    
    player_ip_grace_timers["$player_name"]=$(
        (
            # Wait 5 seconds after connection
            sleep 5
            if [ -n "${connected_players[$player_name]}" ]; then
                local player_info=$(get_player_info "$player_name")
                if [ -n "$player_info" ]; then
                    local first_ip=$(echo "$player_info" | cut -d'|' -f1)
                    if [ "$first_ip" != "UNKNOWN" ] && [ "$first_ip" != "$current_ip" ]; then
                        execute_server_command "SECURITY ALERT: $player_name, your IP has changed! Verify with !ip_change YOUR_PASSWORD within 25 seconds or you will be kicked and IP banned."
                        
                        # Schedule kick and ban after 30 seconds total
                        (
                            sleep 25
                            if [ -n "${connected_players[$player_name]}" ] && [ "${player_verification_status[$player_name]}" != "verified" ]; then
                                execute_server_command "/kick $player_name"
                                execute_server_command "/ban $current_ip"
                                print_warning "Kicked and banned IP $current_ip for failed IP verification"
                                
                                # Unban after 30 seconds
                                (
                                    sleep 30
                                    execute_server_command "/unban $current_ip"
                                    print_success "Auto-unbanned IP: $current_ip"
                                ) &
                            fi
                        ) &
                    fi
                fi
            fi
        ) &
        echo $!
    )
}

# Function to monitor console.log for commands and connections
monitor_console_log() {
    print_header "STARTING CONSOLE LOG MONITOR"
    
    # Wait for console.log to exist
    local wait_time=0
    while [ ! -f "$CONSOLE_LOG" ] && [ $wait_time -lt 30 ]; do
        sleep 1
        ((wait_time++))
        [ $((wait_time % 5)) -eq 0 ] && print_status "Waiting for console.log to be created..."
    done
    
    if [ ! -f "$CONSOLE_LOG" ]; then
        print_error "Console log never appeared: $CONSOLE_LOG"
        return 1
    fi
    
    # Start monitoring
    tail -n 0 -F "$CONSOLE_LOG" | while read -r line; do
        # Player connection detection
        if [[ "$line" =~ Player\ Connected\ (.+)\ \|\ ([0-9a-fA-F.:]+)\ \|\ ([0-9a-f]+) ]]; then
            local player_name="${BASH_REMATCH[1]}"
            local player_ip="${BASH_REMATCH[2]}"
            
            # Clean player name
            player_name=$(echo "$player_name" | xargs)
            
            if is_valid_player_name "$player_name"; then
                connected_players["$player_name"]=1
                player_ip_map["$player_name"]="$player_ip"
                
                print_success "Player connected: $player_name ($player_ip)"
                
                # Check if player exists in players.log
                local player_info=$(get_player_info "$player_name")
                if [ -z "$player_info" ]; then
                    # New player - add to players.log with UNKNOWN first IP and NONE password
                    update_player_info "$player_name" "UNKNOWN" "NONE" "NONE" "NO" "NO"
                    player_verification_status["$player_name"]="pending"
                    start_password_enforcement "$player_name"
                else
                    # Existing player - check IP and start verification process
                    local first_ip=$(echo "$player_info" | cut -d'|' -f1)
                    local password=$(echo "$player_info" | cut -d'|' -f2)
                    
                    if [ "$first_ip" = "UNKNOWN" ]; then
                        # First connection - update IP and mark as verified
                        update_player_info "$player_name" "$player_ip" "$password" "NONE" "NO" "NO"
                        player_verification_status["$player_name"]="verified"
                    elif [ "$first_ip" != "$player_ip" ]; then
                        # IP changed - require verification
                        player_verification_status["$player_name"]="pending"
                        start_ip_grace_period "$player_name" "$player_ip"
                    else
                        # IP matches - mark as verified
                        player_verification_status["$player_name"]="verified"
                    fi
                    
                    # Password enforcement for existing players without password
                    if [ "$password" = "NONE" ]; then
                        start_password_enforcement "$player_name"
                    fi
                fi
                
                # Sync lists for connected player (will only add if verified)
                sync_lists_from_players_log
            fi
        fi
        
        # Player disconnection detection
        if [[ "$line" =~ Player\ Disconnected\ (.+) ]]; then
            local player_name="${BASH_REMATCH[1]}"
            player_name=$(echo "$player_name" | xargs)
            
            if is_valid_player_name "$player_name" ]; then
                unset connected_players["$player_name"]
                unset player_ip_map["$player_name"]
                unset player_verification_status["$player_name"]
                unset player_password_reminder_sent["$player_name"]
                
                # Cancel ALL timers
                cancel_password_kick_timer "$player_name"
                
                if [ -n "${player_ip_grace_timers[$player_name]}" ]; then
                    kill "${player_ip_grace_timers[$player_name]}" 2>/dev/null
                    unset player_ip_grace_timers["$player_name"]
                fi
                
                print_warning "Player disconnected: $player_name"
                
                # Update lists (remove from role lists since player disconnected)
                sync_lists_from_players_log
            fi
        fi
        
        # Chat command detection
        if [[ "$line" =~ ([a-zA-Z0-9_]+):\ (.+)$ ]]; then
            local player_name="${BASH_REMATCH[1]}"
            local message="${BASH_REMATCH[2]}"
            local current_ip="${player_ip_map[$player_name]}"
            
            player_name=$(echo "$player_name" | xargs)
            
            if is_valid_player_name "$player_name" ]; then
                case "$message" in
                    "!psw "*)
                        if [[ "$message" =~ !psw\ ([^[:space:]]+)\ ([^[:space:]]+)$ ]]; then
                            local password="${BASH_REMATCH[1]}"
                            local confirm_password="${BASH_REMATCH[2]}"
                            handle_password_creation "$player_name" "$password" "$confirm_password"
                        else
                            send_server_command "$SCREEN_SESSION" "/clear"
                            sleep 0.1
                            send_server_command "$SCREEN_SESSION" "ERROR: $player_name, invalid format. Use: !psw PASSWORD CONFIRM_PASSWORD"
                        fi
                        ;;
                    "!change_psw "*)
                        if [[ "$message" =~ !change_psw\ ([^[:space:]]+)\ ([^[:space:]]+)$ ]]; then
                            local old_password="${BASH_REMATCH[1]}"
                            local new_password="${BASH_REMATCH[2]}"
                            handle_password_change "$player_name" "$old_password" "$new_password"
                        else
                            send_server_command "$SCREEN_SESSION" "/clear"
                            sleep 0.1
                            send_server_command "$SCREEN_SESSION" "ERROR: $player_name, invalid format. Use: !change_psw OLD_PASSWORD NEW_PASSWORD"
                        fi
                        ;;
                    "!ip_change "*)
                        if [[ "$message" =~ !ip_change\ (.+)$ ]]; then
                            local password="${BASH_REMATCH[1]}"
                            handle_ip_change "$player_name" "$password" "$current_ip"
                        else
                            send_server_command "$SCREEN_SESSION" "/clear"
                            sleep 0.1
                            send_server_command "$SCREEN_SESSION" "ERROR: $player_name, invalid format. Use: !ip_change YOUR_PASSWORD"
                        fi
                        ;;
                esac
            fi
        fi
    done
}

# Function to cleanup
cleanup() {
    print_header "CLEANING UP RANK PATCHER"
    
    # Kill all background processes
    jobs -p | xargs kill -9 2>/dev/null
    
    # Kill all timer processes
    for pid in "${player_password_timers[@]}"; do
        kill "$pid" 2>/dev/null
    done
    
    for pid in "${player_ip_grace_timers[@]}"; do
        kill "$pid" 2>/dev/null
    done
    
    for pid in "${player_kick_timers[@]}"; do
        kill "$pid" 2>/dev/null
    done
    
    print_success "Cleanup completed"
    exit 0
}

# Main execution function
main() {
    if [ $# -lt 1 ]; then
        print_error "Usage: $0 <port>"
        print_status "Example: $0 12153"
        exit 1
    fi
    
    PORT="$1"
    
    print_header "THE BLOCKHEADS RANK PATCHER"
    print_status "Starting rank patcher for port: $PORT"
    
    # Setup trap for cleanup
    trap cleanup EXIT INT TERM
    
    # Setup paths
    if ! setup_paths "$PORT"; then
        exit 1
    fi
    
    # Check if server is running
    if ! screen_session_exists "$SCREEN_SESSION"; then
        print_error "Server screen session not found: $SCREEN_SESSION"
        print_status "Please start the server first using server_manager.sh"
        exit 1
    fi
    
    # Start monitoring processes
    print_step "Starting players.log monitor..."
    monitor_players_log &
    
    print_step "Starting console.log monitor..."
    monitor_console_log &
    
    print_header "RANK PATCHER IS NOW RUNNING"
    print_status "Monitoring: $CONSOLE_LOG"
    print_status "Managing: $PLAYERS_LOG"
    print_status "Server session: $SCREEN_SESSION"
    
    # Wait for background processes
    wait
}

# Run main function with all arguments
main "$@"
