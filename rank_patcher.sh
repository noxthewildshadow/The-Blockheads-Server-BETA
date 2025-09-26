#!/bin/bash

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
ORANGE='\033[0;33m'
NC='\033[0m'

print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_status() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_step() { echo -e "${CYAN}[STEP]${NC} $1"; }
print_debug() { echo -e "${MAGENTA}[DEBUG]${NC} $1"; }

# Configuration
USER_HOME="$HOME"
BASE_DIR="$USER_HOME/GNUstep/Library/ApplicationSupport/TheBlockheads"
SAVES_DIR="$BASE_DIR/saves"
CLOUD_ADMIN_FILE="$BASE_DIR/cloudWideOwnedAdminlist.txt"

# Cooldown between commands (in seconds)
COMMAND_COOLDOWN=0.5
PASSWORD_TIMEOUT=60
IP_VERIFY_TIMEOUT=30

# Global variables
declare -A PLAYER_DATA
declare -A PENDING_ACTIONS
declare -A PASSWORD_TIMEOUTS
declare -A IP_VERIFY_TIMEOUTS
declare -A LAST_COMMAND_TIME

# Function to get current timestamp
get_timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

# Function to sleep with cooldown check
cooldown_sleep() {
    sleep "$COMMAND_COOLDOWN"
}

# Function to send command to server
send_command() {
    local world_id="$1"
    local command="$2"
    local console_file="$SAVES_DIR/${world_id}/console.log"
    
    if [[ -f "$console_file" ]]; then
        echo "$command" >> "$console_file"
        print_debug "Sent command: $command to world $world_id"
    fi
}

# Function to clear chat for a player
clear_chat() {
    local world_id="$1"
    local player_name="$2"
    send_command "$world_id" "/clear $player_name"
}

# Function to validate password
validate_password() {
    local password="$1"
    local password_len=${#password}
    
    if [[ $password_len -lt 7 || $password_len -gt 16 ]]; then
        echo "Password must be between 7 and 16 characters"
        return 1
    fi
    
    if [[ ! "$password" =~ ^[a-zA-Z0-9!@#$%^&*()_+\-=\[\]{};':"\\|,.<>\/?]+$ ]]; then
        echo "Password contains invalid characters"
        return 1
    fi
    
    return 0
}

# Function to read players.log
read_players_log() {
    local players_file="$1"
    declare -n data_ref="$2"
    
    data_ref=()
    if [[ -f "$players_file" ]]; then
        while IFS='|' read -r name ip password rank whitelisted blacklisted; do
            # Clean up the fields
            name=$(echo "$name" | xargs)
            ip=$(echo "$ip" | xargs)
            password=$(echo "$password" | xargs)
            rank=$(echo "$rank" | xargs)
            whitelisted=$(echo "$whitelisted" | xargs)
            blacklisted=$(echo "$blacklisted" | xargs)
            
            if [[ -n "$name" && "$name" != "UNKNOWN" ]]; then
                data_ref["$name"]="$name|$ip|$password|$rank|$whitelisted|$blacklisted"
            fi
        done < <(grep -v '^#' "$players_file" | grep -v '^$')
    fi
}

# Function to update players.log entry
update_player_entry() {
    local players_file="$1"
    local player_name="$2"
    local field="$3"
    local new_value="$4"
    
    if [[ ! -f "$players_file" ]]; then
        print_error "Players log file not found: $players_file"
        return 1
    fi
    
    # Create backup
    cp "$players_file" "${players_file}.bak"
    
    # Find and update the specific entry
    local updated=0
    local temp_file=$(mktemp)
    
    while IFS= read -r line; do
        if echo "$line" | grep -q "|" && echo "$line" | cut -d'|' -f1 | xargs | grep -q "^$player_name$"; then
            IFS='|' read -r name ip password rank whitelisted blacklisted <<< "$line"
            
            case "$field" in
                "ip") ip="$new_value" ;;
                "password") password="$new_value" ;;
                "rank") rank="$new_value" ;;
                "whitelisted") whitelisted="$new_value" ;;
                "blacklisted") blacklisted="$new_value" ;;
                *) print_error "Invalid field: $field"; return 1 ;;
            esac
            
            echo "$name | $ip | $password | $rank | $whitelisted | $blacklisted" >> "$temp_file"
            updated=1
        else
            echo "$line" >> "$temp_file"
        fi
    done < "$players_file"
    
    if [[ $updated -eq 1 ]]; then
        mv "$temp_file" "$players_file"
        print_success "Updated $player_name's $field to $new_value"
    else
        rm "$temp_file"
        print_error "Player $player_name not found in players.log"
        return 1
    fi
}

# Function to sync lists from players.log
sync_server_lists() {
    local world_id="$1"
    local world_dir="$SAVES_DIR/$world_id"
    
    # Skip if world directory doesn't exist
    [[ ! -d "$world_dir" ]] && return 1
    
    # Arrays to hold names for each list
    declare -a admin_list
    declare -a mod_list
    declare -a white_list
    declare -a black_list
    
    # Read players.log for this world
    local players_file="$world_dir/players.log"
    if [[ ! -f "$players_file" ]]; then
        return 1
    fi
    
    # Process each player
    while IFS='|' read -r name ip password rank whitelisted blacklisted; do
        name=$(echo "$name" | xargs)
        ip=$(echo "$ip" | xargs)
        rank=$(echo "$rank" | xargs)
        whitelisted=$(echo "$whitelisted" | xargs)
        blacklisted=$(echo "$blacklisted" | xargs)
        
        # Only include players with verified IP (not UNKNOWN)
        if [[ "$ip" != "UNKNOWN" && "$ip" != "" ]]; then
            if [[ "$blacklisted" == "YES" ]]; then
                black_list+=("$name")
            elif [[ "$whitelisted" == "YES" ]]; then
                white_list+=("$name")
            fi
            
            if [[ "$rank" == "ADMIN" ]]; then
                admin_list+=("$name")
            elif [[ "$rank" == "MOD" ]]; then
                mod_list+=("$name")
            fi
        fi
    done < <(grep -v '^#' "$players_file" | grep -v '^$')
    
    # Update adminlist.txt (skip first two lines)
    local admin_file="$world_dir/adminlist.txt"
    if [[ -f "$admin_file" ]]; then
        local temp_admin=$(mktemp)
        head -n 2 "$admin_file" > "$temp_admin"
        printf "%s\n" "${admin_list[@]}" >> "$temp_admin"
        mv "$temp_admin" "$admin_file"
    fi
    
    # Update modlist.txt (skip first two lines)
    local mod_file="$world_dir/modlist.txt"
    if [[ -f "$mod_file" ]]; then
        local temp_mod=$(mktemp)
        head -n 2 "$mod_file" > "$temp_mod"
        printf "%s\n" "${mod_list[@]}" >> "$temp_mod"
        mv "$temp_mod" "$mod_file"
    fi
    
    # Update whitelist.txt (skip first two lines)
    local white_file="$world_dir/whitelist.txt"
    if [[ -f "$white_file" ]]; then
        local temp_white=$(mktemp)
        head -n 2 "$white_file" > "$temp_white"
        printf "%s\n" "${white_list[@]}" >> "$temp_white"
        mv "$temp_white" "$white_file"
    fi
    
    # Update blacklist.txt (skip first two lines)
    local black_file="$world_dir/blacklist.txt"
    if [[ -f "$black_file" ]]; then
        local temp_black=$(mktemp)
        head -n 2 "$black_file" > "$temp_black"
        printf "%s\n" "${black_list[@]}" >> "$temp_black"
        mv "$temp_black" "$black_file"
    fi
}

# Function to handle rank changes
handle_rank_change() {
    local world_id="$1"
    local player_name="$2"
    local old_rank="$3"
    local new_rank="$4"
    local player_ip="$5"
    
    print_status "Rank change for $player_name: $old_rank -> $new_rank"
    
    # Apply cooldown
    cooldown_sleep
    
    case "$new_rank" in
        "ADMIN")
            if [[ "$old_rank" == "NONE" ]]; then
                send_command "$world_id" "/admin $player_name"
                print_success "Promoted $player_name to ADMIN"
            fi
            ;;
        "MOD")
            if [[ "$old_rank" == "NONE" ]]; then
                send_command "$world_id" "/mod $player_name"
                print_success "Promoted $player_name to MOD"
            fi
            ;;
        "SUPER")
            # Add to cloud-wide admin list
            if [[ ! -f "$CLOUD_ADMIN_FILE" ]]; then
                touch "$CLOUD_ADMIN_FILE"
            fi
            if ! grep -q "^$player_name$" "$CLOUD_ADMIN_FILE"; then
                echo "$player_name" >> "$CLOUD_ADMIN_FILE"
                print_success "Added $player_name to cloud-wide admin list"
            fi
            ;;
        "NONE")
            case "$old_rank" in
                "ADMIN")
                    send_command "$world_id" "/unadmin $player_name"
                    print_success "Demoted $player_name from ADMIN to NONE"
                    ;;
                "MOD")
                    send_command "$world_id" "/unmod $player_name"
                    print_success "Demoted $player_name from MOD to NONE"
                    ;;
                "SUPER")
                    # Remove from cloud-wide admin list
                    if [[ -f "$CLOUD_ADMIN_FILE" ]]; then
                        sed -i "/^$player_name$/d" "$CLOUD_ADMIN_FILE"
                        print_success "Removed $player_name from cloud-wide admin list"
                    fi
                    ;;
            esac
            ;;
    esac
}

# Function to handle blacklist changes
handle_blacklist_change() {
    local world_id="$1"
    local player_name="$2"
    local old_status="$3"
    local new_status="$4"
    local player_ip="$5"
    
    if [[ "$new_status" == "YES" ]]; then
        print_status "Blacklisting player: $player_name"
        
        # Apply cooldown between commands
        cooldown_sleep
        send_command "$world_id" "/unmod $player_name"
        
        cooldown_sleep
        send_command "$world_id" "/unadmin $player_name"
        
        cooldown_sleep
        send_command "$world_id" "/ban $player_name"
        
        cooldown_sleep
        send_command "$world_id" "/ban $player_ip"
        
        # If player was SUPER, remove from cloud list
        local players_file="$SAVES_DIR/$world_id/players.log"
        if [[ -f "$players_file" ]]; then
            local player_data=$(grep "^$player_name |" "$players_file" | head -1)
            local rank=$(echo "$player_data" | cut -d'|' -f4 | xargs)
            if [[ "$rank" == "SUPER" ]]; then
                send_command "$world_id" "/stop"
                cooldown_sleep
                if [[ -f "$CLOUD_ADMIN_FILE" ]]; then
                    sed -i "/^$player_name$/d" "$CLOUD_ADMIN_FILE"
                fi
            fi
        fi
        
        print_success "Blacklisted $player_name and banned their IP"
    fi
}

# Function to process console commands
process_console_command() {
    local world_id="$1"
    local player_name="$2"
    local command="$3"
    local player_ip="$4"
    
    local players_file="$SAVES_DIR/$world_id/players.log"
    local current_time=$(date +%s)
    
    # Check command cooldown
    if [[ -n "${LAST_COMMAND_TIME["$player_name"]}" ]]; then
        local last_time=${LAST_COMMAND_TIME["$player_name"]}
        if (( current_time - last_time < 2 )); then
            send_command "$world_id" "msg $player_name Please wait before using another command"
            return
        fi
    fi
    LAST_COMMAND_TIME["$player_name"]=$current_time
    
    case "$command" in
        !password*)
            # Format: !password NEW_PASS CONFIRM_PASS
            local args=$(echo "$command" | cut -d' ' -f2-)
            local new_pass=$(echo "$args" | cut -d' ' -f1)
            local confirm_pass=$(echo "$args" | cut -d' ' -f2)
            
            clear_chat "$world_id" "$player_name"
            cooldown_sleep
            
            if [[ -z "$new_pass" || -z "$confirm_pass" ]]; then
                send_command "$world_id" "msg $player_name Usage: !password NEW_PASSWORD CONFIRM_PASSWORD"
                return
            fi
            
            if [[ "$new_pass" != "$confirm_pass" ]]; then
                send_command "$world_id" "msg $player_name Passwords do not match"
                return
            fi
            
            local validation_result=$(validate_password "$new_pass")
            if [[ $? -ne 0 ]]; then
                send_command "$world_id" "msg $player_name $validation_result"
                return
            fi
            
            # Update password in players.log
            if update_player_entry "$players_file" "$player_name" "password" "$new_pass"; then
                send_command "$world_id" "msg $player_name Password set successfully"
                # Clear any pending password timeout
                unset PASSWORD_TIMEOUTS["$player_name"]
            else
                send_command "$world_id" "msg $player_name Error setting password"
            fi
            ;;
            
        !ip_change*)
            # Format: !ip_change PASSWORD
            local password=$(echo "$command" | cut -d' ' -f2)
            
            clear_chat "$world_id" "$player_name"
            cooldown_sleep
            
            if [[ -z "$password" ]]; then
                send_command "$world_id" "msg $player_name Usage: !ip_change YOUR_PASSWORD"
                return
            fi
            
            # Verify password
            local player_data=$(grep "^$player_name |" "$players_file" | head -1)
            local stored_password=$(echo "$player_data" | cut -d'|' -f3 | xargs)
            
            if [[ "$password" != "$stored_password" ]]; then
                send_command "$world_id" "msg $player_name Incorrect password"
                return
            fi
            
            # Update IP address
            if update_player_entry "$players_file" "$player_name" "ip" "$player_ip"; then
                send_command "$world_id" "msg $player_name IP address verified successfully"
                # Clear IP verification timeout
                unset IP_VERIFY_TIMEOUTS["$player_name"]
            else
                send_command "$world_id" "msg $player_name Error verifying IP"
            fi
            ;;
            
        !change_psw*)
            # Format: !change_psw OLD_PASS NEW_PASS
            local args=$(echo "$command" | cut -d' ' -f2-)
            local old_pass=$(echo "$args" | cut -d' ' -f1)
            local new_pass=$(echo "$args" | cut -d' ' -f2)
            
            clear_chat "$world_id" "$player_name"
            cooldown_sleep
            
            if [[ -z "$old_pass" || -z "$new_pass" ]]; then
                send_command "$world_id" "msg $player_name Usage: !change_psw OLD_PASSWORD NEW_PASSWORD"
                return
            fi
            
            # Verify old password
            local player_data=$(grep "^$player_name |" "$players_file" | head -1)
            local stored_password=$(echo "$player_data" | cut -d'|' -f3 | xargs)
            
            if [[ "$old_pass" != "$stored_password" ]]; then
                send_command "$world_id" "msg $player_name Incorrect old password"
                return
            fi
            
            local validation_result=$(validate_password "$new_pass")
            if [[ $? -ne 0 ]]; then
                send_command "$world_id" "msg $player_name $validation_result"
                return
            fi
            
            # Update password
            if update_player_entry "$players_file" "$player_name" "password" "$new_pass"; then
                send_command "$world_id" "msg $player_name Password changed successfully"
            else
                send_command "$world_id" "msg $player_name Error changing password"
            fi
            ;;
    esac
}

# Function to monitor console logs
monitor_console_logs() {
    while true; do
        # Find all world directories
        for world_dir in "$SAVES_DIR"/*/; do
            if [[ -d "$world_dir" ]]; then
                local world_id=$(basename "$world_dir")
                local console_log="$world_dir/console.log"
                local players_log="$world_dir/players.log"
                
                # Create players.log if it doesn't exist but console.log does
                if [[ -f "$console_log" && ! -f "$players_log" ]]; then
                    touch "$players_log"
                    print_status "Created players.log for world $world_id"
                fi
                
                # Monitor console.log for new entries
                if [[ -f "$console_log" ]]; then
                    # Get new lines since last check
                    local last_size=${LAST_CONSOLE_SIZE["$world_id"]:-0}
                    local current_size=$(stat -c%s "$console_log" 2>/dev/null || echo 0)
                    
                    if (( current_size > last_size )); then
                        # Read new lines
                        tail -c $((current_size - last_size)) "$console_log" | while IFS= read -r line; do
                            # Detect player connections
                            if echo "$line" | grep -q "Player Connected"; then
                                local player_name=$(echo "$line" | grep -oP 'Player Connected \K[^|]+' | xargs)
                                local player_ip=$(echo "$line" | grep -oP '\| [^|]+ \|' | cut -d'|' -f2 | xargs)
                                local player_id=$(echo "$line" | grep -oP '[a-f0-9]{32}$')
                                
                                if [[ -n "$player_name" && -n "$player_ip" ]]; then
                                    print_status "Player connected: $player_name ($player_ip) to world $world_id"
                                    
                                    # Check if player exists in players.log
                                    if grep -q "^$player_name |" "$players_log" 2>/dev/null; then
                                        # Player exists, check IP and password
                                        local player_data=$(grep "^$player_name |" "$players_log" | head -1)
                                        local stored_ip=$(echo "$player_data" | cut -d'|' -f2 | xargs)
                                        local stored_password=$(echo "$player_data" | cut -d'|' -f3 | xargs)
                                        local rank=$(echo "$player_data" | cut -d'|' -f4 | xargs)
                                        
                                        # IP verification check
                                        if [[ "$stored_ip" != "UNKNOWN" && "$stored_ip" != "$player_ip" ]]; then
                                            send_command "$world_id" "msg $player_name New IP detected! Verify with !ip_change YOUR_PASSWORD within 30 seconds"
                                            IP_VERIFY_TIMEOUTS["$player_name"]=$(date -d "+30 seconds" +%s)
                                        fi
                                        
                                        # Password check for NONE rank players
                                        if [[ "$rank" == "NONE" && "$stored_password" == "NONE" ]]; then
                                            send_command "$world_id" "msg $player_name Please set your password with !password NEW_PASS CONFIRM_PASS within 1 minute"
                                            PASSWORD_TIMEOUTS["$player_name"]=$(date -d "+60 seconds" +%s)
                                        fi
                                    else
                                        # New player - add to players.log
                                        echo "$player_name | $player_ip | NONE | NONE | NO | NO" >> "$players_log"
                                        send_command "$world_id" "msg $player_name Welcome! Set your password with !password NEW_PASS CONFIRM_PASS within 1 minute"
                                        PASSWORD_TIMEOUTS["$player_name"]=$(date -d "+60 seconds" +%s)
                                    fi
                                fi
                            fi
                            
                            # Detect chat messages with commands
                            if echo "$line" | grep -q "CHAT.*:" && echo "$line" | grep -q "!"; then
                                local player_name=$(echo "$line" | grep -oP 'CHAT - \K[^:]+' | xargs)
                                local chat_message=$(echo "$line" | grep -oP 'CHAT - [^:]+: \K.*')
                                local player_ip="UNKNOWN"
                                
                                # Get player IP from players.log
                                if [[ -f "$players_log" ]]; then
                                    local player_data=$(grep "^$player_name |" "$players_log" | head -1 2>/dev/null)
                                    if [[ -n "$player_data" ]]; then
                                        player_ip=$(echo "$player_data" | cut -d'|' -f2 | xargs)
                                    fi
                                fi
                                
                                if [[ -n "$player_name" && -n "$chat_message" ]]; then
                                    process_console_command "$world_id" "$player_name" "$chat_message" "$player_ip"
                                fi
                            fi
                        done
                        
                        LAST_CONSOLE_SIZE["$world_id"]=$current_size
                    fi
                fi
                
                # Sync server lists
                sync_server_lists "$world_id"
            fi
        done
        
        sleep 0.25
    done
}

# Function to monitor players.log for changes
monitor_players_log() {
    while true; do
        for world_dir in "$SAVES_DIR"/*/; do
            if [[ -d "$world_dir" ]]; then
                local world_id=$(basename "$world_dir")
                local players_log="$world_dir/players.log"
                
                if [[ -f "$players_log" ]]; then
                    local current_hash=$(md5sum "$players_log" 2>/dev/null | cut -d' ' -f1)
                    local last_hash=${PLAYERS_LOG_HASH["$world_id"]}
                    
                    if [[ "$current_hash" != "$last_hash" ]]; then
                        # File changed, process changes
                        declare -A current_data
                        read_players_log "$players_log" current_data
                        
                        for player in "${!current_data[@]}"; do
                            local new_entry="${current_data[$player]}"
                            local old_entry="${PLAYER_DATA["$world_id|$player"]}"
                            
                            if [[ "$new_entry" != "$old_entry" ]]; then
                                IFS='|' read -r name new_ip new_password new_rank new_whitelisted new_blacklisted <<< "$new_entry"
                                IFS='|' read -r name old_ip old_password old_rank old_whitelisted old_blacklisted <<< "$old_entry"
                                
                                # Clean values
                                new_rank=$(echo "$new_rank" | xargs)
                                old_rank=$(echo "$old_rank" | xargs)
                                new_blacklisted=$(echo "$new_blacklisted" | xargs)
                                old_blacklisted=$(echo "$old_blacklisted" | xargs)
                                
                                # Handle rank changes
                                if [[ "$new_rank" != "$old_rank" ]]; then
                                    handle_rank_change "$world_id" "$player" "$old_rank" "$new_rank" "$new_ip"
                                fi
                                
                                # Handle blacklist changes
                                if [[ "$new_blacklisted" != "$old_blacklisted" ]]; then
                                    handle_blacklist_change "$world_id" "$player" "$old_blacklisted" "$new_blacklisted" "$new_ip"
                                fi
                                
                                PLAYER_DATA["$world_id|$player"]="$new_entry"
                            fi
                        done
                        
                        PLAYERS_LOG_HASH["$world_id"]=$current_hash
                    fi
                fi
            fi
        done
        
        sleep 0.25
    done
}

# Function to handle timeouts
handle_timeouts() {
    while true; do
        local current_time=$(date +%s)
        
        # Check password timeouts
        for player in "${!PASSWORD_TIMEOUTS[@]}"; do
            local timeout_time=${PASSWORD_TIMEOUTS["$player"]}
            if (( current_time >= timeout_time )); then
                # Find which world the player is in
                for world_dir in "$SAVES_DIR"/*/; do
                    if [[ -d "$world_dir" ]]; then
                        local world_id=$(basename "$world_dir")
                        local players_log="$world_dir/players.log"
                        
                        if [[ -f "$players_log" ]] && grep -q "^$player |" "$players_log"; then
                            local player_data=$(grep "^$player |" "$players_log" | head -1)
                            local password=$(echo "$player_data" | cut -d'|' -f3 | xargs)
                            
                            if [[ "$password" == "NONE" ]]; then
                                send_command "$world_id" "/kick $player"
                                send_command "$world_id" "msg $player Timeout: Please set your password before joining"
                                print_warning "Kicked $player for not setting password"
                            fi
                            
                            unset PASSWORD_TIMEOUTS["$player"]
                            break
                        fi
                    fi
                done
            fi
        done
        
        # Check IP verification timeouts
        for player in "${!IP_VERIFY_TIMEOUTS[@]}"; do
            local timeout_time=${IP_VERIFY_TIMEOUTS["$player"]}
            if (( current_time >= timeout_time )); then
                # Find which world the player is in
                for world_dir in "$SAVES_DIR"/*/; do
                    if [[ -d "$world_dir" ]]; then
                        local world_id=$(basename "$world_dir")
                        local players_log="$world_dir/players.log"
                        
                        if [[ -f "$players_log" ]] && grep -q "^$player |" "$players_log"; then
                            local player_data=$(grep "^$player |" "$players_log" | head -1)
                            local player_ip=$(echo "$player_data" | cut -d'|' -f2 | xargs)
                            
                            send_command "$world_id" "/kick $player"
                            send_command "$world_id" "/ban $player_ip"
                            print_warning "Kicked and temp-banned $player for IP verification timeout"
                            
                            # Unban after 30 seconds
                            (sleep 30; send_command "$world_id" "/unban $player_ip") &
                            
                            unset IP_VERIFY_TIMEOUTS["$player"]
                            break
                        fi
                    fi
                done
            fi
        done
        
        sleep 1
    done
}

# Main function
main() {
    print_header "THE BLOCKHEADS RANK PATCHER STARTING"
    print_status "Started at: $(get_timestamp)"
    print_status "Monitoring directory: $SAVES_DIR"
    
    # Create necessary directories
    mkdir -p "$SAVES_DIR"
    
    # Initialize global arrays
    declare -A LAST_CONSOLE_SIZE
    declare -A PLAYERS_LOG_HASH
    
    # Start monitoring processes in background
    monitor_console_logs &
    CONSOLE_MONITOR_PID=$!
    
    monitor_players_log &
    PLAYERS_MONITOR_PID=$!
    
    handle_timeouts &
    TIMEOUT_MONITOR_PID=$!
    
    print_success "Rank patcher started successfully with PID: $$"
    print_status "Console monitor PID: $CONSOLE_MONITOR_PID"
    print_status "Players log monitor PID: $PLAYERS_MONITOR_PID"
    print_status "Timeout monitor PID: $TIMEOUT_MONITOR_PID"
    
    # Wait for background processes
    wait $CONSOLE_MONITOR_PID $PLAYERS_MONITOR_PID $TIMEOUT_MONITOR_PID
}

# Trap signals for clean shutdown
trap 'print_header "SHUTTING DOWN RANK PATCHER"; kill $CONSOLE_MONITOR_PID $PLAYERS_MONITOR_PID $TIMEOUT_MONITOR_PID 2>/dev/null; exit 0' INT TERM EXIT

# Run main function
main
