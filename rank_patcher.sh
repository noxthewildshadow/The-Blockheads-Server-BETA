#!/bin/bash

# rank_patcher.sh - Complete player management system for The Blockheads server
# Monitors console.log and manages players.log as central authority for ranks, passwords, and IP verification

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
NC='\033[0m'

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
    echo -e "${PURPLE}================================================================================${NC}"
    echo -e "${PURPLE}$1${NC}"
    echo -e "${PURPLE}================================================================================${NC}"
}

print_step() {
    echo -e "${CYAN}[STEP]${NC} $1"
}

# Configuration - GNUstep compatible paths
LOG_FILE="$1"
PORT="$2"
LOG_DIR=$(dirname "$LOG_FILE")
WORLD_ID=$(basename "$LOG_DIR")
PLAYERS_LOG="$LOG_DIR/players.log"
ADMIN_LIST="$LOG_DIR/adminlist.txt"
MOD_LIST="$LOG_DIR/modlist.txt"
WHITELIST="$LOG_DIR/whitelist.txt"
BLACKLIST="$LOG_DIR/blacklist.txt"
CLOUD_ADMIN_LIST="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/cloudWideOwnedAdminlist.txt"
SCREEN_SERVER="blockheads_server_$PORT"

# Track active players and their states
declare -A PLAYER_IPS
declare -A PLAYER_PASSWORD_TIMERS
declare -A PLAYER_IP_VERIFICATION_TIMERS
declare -A PLAYER_LAST_SEEN
declare -A PLAYER_RANK_CHANGES
declare -A PLAYER_BLACKLIST_CHANGES

# Function to send command to server
send_server_command() {
    local command="$1"
    if screen -S "$SCREEN_SERVER" -X stuff "$command$(printf \\r)" 2>/dev/null; then
        print_success "Sent command: $command"
        return 0
    else
        print_error "Could not send command to server: $command"
        return 1
    fi
}

# Function to send message to player with cooldown
send_player_message() {
    local player="$1"
    local message="$2"
    sleep 0.5
    send_server_command "say $message"
}

# Function to clear chat with cooldown
clear_chat_with_cooldown() {
    send_server_command "/clear"
    sleep 0.5
}

# Function to validate password
validate_password() {
    local password="$1"
    local confirm="$2"
    
    if [ "$password" != "$confirm" ]; then
        echo "PASSWORDS_DO_NOT_MATCH"
        return 1
    fi
    
    local len=${#password}
    if [ $len -lt 7 ] || [ $len -gt 16 ]; then
        echo "PASSWORD_LENGTH_INVALID"
        return 1
    fi
    
    echo "PASSWORD_VALID"
    return 0
}

# Function to get current timestamp
get_timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

# Emergency repair function for players.log
emergency_repair_players_log() {
    if [ ! -f "$PLAYERS_LOG" ]; then
        return 0
    fi
    
    print_header "EMERGENCY PLAYERS.LOG REPAIR"
    
    # Backup original
    local backup_file="${PLAYERS_LOG}.backup.$(date +%Y%m%d_%H%M%S)"
    cp "$PLAYERS_LOG" "$backup_file"
    print_success "Backup created: $backup_file"
    
    # Parse and fix the specific format shown in the problem
    local temp_file="${PLAYERS_LOG}.fixed"
    rm -f "$temp_file" 2>/dev/null
    
    # Process each line and convert to correct format
    while IFS= read -r line || [ -n "$line" ]; do
        # Remove leading numbers and spaces
        line=$(echo "$line" | sed 's/^[0-9]*//' | sed 's/^[[:space:]]*//')
        
        # Replace multiple spaces with single pipe and convert to uppercase
        line=$(echo "$line" | sed 's/[[:space:]]*|[[:space:]]*/|/g' | tr '[:lower:]' '[:upper:]')
        
        # Count pipes to validate format
        local pipe_count=$(echo "$line" | tr -cd '|' | wc -c)
        
        if [ $pipe_count -eq 5 ]; then
            echo "$line" >> "$temp_file"
        else
            print_warning "Skipping unrepairable line: $line"
        fi
    done < "$PLAYERS_LOG"
    
    # Replace original if we have valid content
    if [ -f "$temp_file" ] && [ -s "$temp_file" ]; then
        mv "$temp_file" "$PLAYERS_LOG"
        print_success "Emergency repair completed successfully"
    else
        print_error "Emergency repair failed - restoring backup"
        mv "$backup_file" "$PLAYERS_LOG"
    fi
}

# Function to clean and format existing players.log
clean_players_log() {
    if [ ! -f "$PLAYERS_LOG" ]; then
        return 0
    fi
    
    print_step "Cleaning and formatting players.log..."
    
    local temp_file="${PLAYERS_LOG}.clean"
    declare -A processed_players
    
    # Read and process each line
    while IFS= read -r line || [ -n "$line" ]; do
        # Clean the line and split by pipe
        line=$(echo "$line" | tr -d ' ' | tr '[:lower:]' '[:upper:]')
        
        # Count pipes to validate format
        local pipe_count=$(echo "$line" | tr -cd '|' | wc -c)
        
        if [ $pipe_count -eq 5 ]; then
            # Correct format, process normally
            local player_name=$(echo "$line" | cut -d'|' -f1)
            local ip=$(echo "$line" | cut -d'|' -f2)
            local password=$(echo "$line" | cut -d'|' -f3)
            local rank=$(echo "$line" | cut -d'|' -f4)
            local whitelisted=$(echo "$line" | cut -d'|' -f5)
            local blacklisted=$(echo "$line" | cut -d'|' -f6)
            
            # Validate and correct fields
            [ -z "$ip" ] && ip="UNKNOWN"
            [ -z "$password" ] && password="NONE"
            [ -z "$rank" ] && rank="NONE"
            [ -z "$whitelisted" ] && whitelisted="NO"
            [ -z "$blacklisted" ] && blacklisted="NO"
            
            # Only keep the first record of each player
            if [ -z "${processed_players[$player_name]}" ]; then
                echo "${player_name}|${ip}|${password}|${rank}|${whitelisted}|${blacklisted}" >> "$temp_file"
                processed_players["$player_name"]=1
            fi
        else
            print_warning "Skipping invalid line in players.log: $line"
        fi
    done < "$PLAYERS_LOG"
    
    # Replace original file if lines were processed
    if [ -f "$temp_file" ]; then
        mv "$temp_file" "$PLAYERS_LOG"
        print_success "players.log cleaned and formatted successfully"
    fi
}

# Function to initialize players.log
initialize_players_log() {
    if [ ! -f "$PLAYERS_LOG" ]; then
        print_step "Creating players.log file..."
        mkdir -p "$(dirname "$PLAYERS_LOG")"
        touch "$PLAYERS_LOG"
        print_success "Created players.log: $PLAYERS_LOG"
    else
        print_step "Players.log exists - cleaning and formatting..."
        clean_players_log
    fi
    
    # Verify file format
    if [ -s "$PLAYERS_LOG" ]; then
        print_step "Verifying players.log format..."
        local invalid_lines=0
        while IFS= read -r line || [ -n "$line" ]; do
            local pipe_count=$(echo "$line" | tr -cd '|' | wc -c)
            if [ $pipe_count -ne 5 ]; then
                ((invalid_lines++))
                print_warning "Invalid format in line: $line"
            fi
        done < "$PLAYERS_LOG"
        
        if [ $invalid_lines -gt 0 ]; then
            print_error "Found $invalid_lines lines with invalid format in players.log"
            print_step "Attempting to repair..."
            clean_players_log
        else
            print_success "players.log format is correct"
        fi
    fi
}

# Function to find player in players.log
find_player() {
    local player_name="$1"
    player_name=$(echo "$player_name" | tr '[:lower:]' '[:upper:]' | tr -d ' ')
    grep -i "^$player_name|" "$PLAYERS_LOG" 2>/dev/null | head -1
}

# Function to get player field
get_player_field() {
    local player_name="$1"
    local field_num="$2"
    local record=$(find_player "$player_name")
    if [ -n "$record" ]; then
        echo "$record" | cut -d'|' -f"$field_num" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
    else
        echo ""
    fi
}

# Function to update player record - CORRECTED FORMAT
update_player() {
    local player_name="$1"
    local ip="$2"
    local password="$3"
    local rank="$4"
    local whitelisted="$5"
    local blacklisted="$6"
    
    local existing_record=$(find_player "$player_name")
    
    # Create temp file
    local temp_file="${PLAYERS_LOG}.tmp"
    [ -f "$PLAYERS_LOG" ] && cp "$PLAYERS_LOG" "$temp_file" 2>/dev/null || touch "$temp_file"
    
    if [ -n "$existing_record" ]; then
        # Update existing record - KEEP CURRENT VALUES IF NEW ONES NOT PROVIDED
        local current_name=$(get_player_field "$player_name" 1)
        local current_ip=$(get_player_field "$player_name" 2)
        local current_password=$(get_player_field "$player_name" 3)
        local current_rank=$(get_player_field "$player_name" 4)
        local current_whitelisted=$(get_player_field "$player_name" 5)
        local current_blacklisted=$(get_player_field "$player_name" 6)
        
        # Only update provided fields (not empty)
        [ -z "$ip" ] && ip="$current_ip"
        [ -z "$password" ] && password="$current_password"
        [ -z "$rank" ] && rank="$current_rank"
        [ -z "$whitelisted" ] && whitelisted="$current_whitelisted"
        [ -z "$blacklisted" ] && blacklisted="$current_blacklisted"
        
        # Remove old record
        grep -v -i "^$player_name|" "$temp_file" > "${temp_file}.2" 2>/dev/null && mv "${temp_file}.2" "$temp_file"
    else
        # Set defaults for new players - EXACT FORMAT
        [ -z "$ip" ] && ip="UNKNOWN"
        [ -z "$password" ] && password="NONE"
        [ -z "$rank" ] && rank="NONE"
        [ -z "$whitelisted" ] && whitelisted="NO"
        [ -z "$blacklisted" ] && blacklisted="NO"
    fi
    
    # CONVERT TO UPPERCASE AND CLEAN - EXACT FORMAT REQUIRED
    player_name=$(echo "$player_name" | tr '[:lower:]' '[:upper:]' | tr -d ' ')
    ip=$(echo "$ip" | tr '[:lower:]' '[:upper:]' | tr -d ' ')
    password=$(echo "$password" | tr '[:lower:]' '[:upper:]' | tr -d ' ')
    rank=$(echo "$rank" | tr '[:lower:]' '[:upper:]' | tr -d ' ')
    whitelisted=$(echo "$whitelisted" | tr '[:lower:]' '[:upper:]' | tr -d ' ')
    blacklisted=$(echo "$blacklisted" | tr '[:lower:]' '[:upper:]' | tr -d ' ')
    
    # Format validations
    [ "$ip" = "UNKNOWN" ] || [ -z "$ip" ] && ip="UNKNOWN"
    [ "$password" = "NONE" ] || [ -z "$password" ] && password="NONE"
    [ "$rank" = "NONE" ] || [ -z "$rank" ] && rank="NONE"
    [ "$whitelisted" = "NO" ] || [ -z "$whitelisted" ] && whitelisted="NO"
    [ "$blacklisted" = "NO" ] || [ -z "$blacklisted" ] && blacklisted="NO"
    
    # Write new record in exact format
    echo "${player_name}|${ip}|${password}|${rank}|${whitelisted}|${blacklisted}" >> "$temp_file"
    
    # Replace original file
    mv "$temp_file" "$PLAYERS_LOG" 2>/dev/null
    print_success "Player record updated: $player_name"
    
    # Track changes for later handling
    local old_rank=$(get_player_field "$player_name" 4)
    local old_blacklisted=$(get_player_field "$player_name" 6)
    
    if [ -n "$old_rank" ] && [ "$old_rank" != "$rank" ]; then
        PLAYER_RANK_CHANGES["$player_name"]="$old_rank|$rank"
    fi
    
    if [ -n "$old_blacklisted" ] && [ "$old_blacklisted" != "$blacklisted" ]; then
        PLAYER_BLACKLIST_CHANGES["$player_name"]="$old_blacklisted|$blacklisted"
    fi
}

# Function to handle rank changes
handle_rank_change() {
    local player_name="$1"
    local old_rank="$2"
    local new_rank="$3"
    
    print_step "Processing rank change: $player_name $old_rank -> $new_rank"
    
    case "$new_rank" in
        "ADMIN")
            case "$old_rank" in
                "NONE"|"MOD")
                    send_server_command "/admin $player_name"
                    print_success "Promoted $player_name to ADMIN"
                    ;;
            esac
            ;;
        "MOD")
            case "$old_rank" in
                "NONE")
                    send_server_command "/mod $player_name"
                    print_success "Promoted $player_name to MOD"
                    ;;
            esac
            ;;
        "SUPER")
            # Create cloud admin list if not exists (respecting first line)
            if [ ! -f "$CLOUD_ADMIN_LIST" ]; then
                mkdir -p "$(dirname "$CLOUD_ADMIN_LIST")"
                echo "# Usernames in this file are granted admin rights across all worlds" > "$CLOUD_ADMIN_LIST"
            fi
            
            # Add player to cloud admin list (ignore first line)
            local temp_cloud="${CLOUD_ADMIN_LIST}.tmp"
            head -1 "$CLOUD_ADMIN_LIST" > "$temp_cloud" 2>/dev/null
            grep -v "^#" "$CLOUD_ADMIN_LIST" 2>/dev/null | grep -v "^$player_name$" >> "$temp_cloud" 2>/dev/null
            echo "$player_name" >> "$temp_cloud"
            mv "$temp_cloud" "$CLOUD_ADMIN_LIST" 2>/dev/null
            print_success "Added $player_name to cloud admin list"
            ;;
        "NONE")
            case "$old_rank" in
                "ADMIN")
                    send_server_command "/unadmin $player_name"
                    print_success "Demoted $player_name from ADMIN to NONE"
                    ;;
                "MOD")
                    send_server_command "/unmod $player_name"
                    print_success "Demoted $player_name from MOD to NONE"
                    ;;
                "SUPER")
                    # Remove from cloud admin list (ignore first line)
                    if [ -f "$CLOUD_ADMIN_LIST" ]; then
                        local temp_cloud="${CLOUD_ADMIN_LIST}.tmp"
                        head -1 "$CLOUD_ADMIN_LIST" > "$temp_cloud" 2>/dev/null
                        grep -v "^#" "$CLOUD_ADMIN_LIST" 2>/dev/null | grep -v "^$player_name$" >> "$temp_cloud" 2>/dev/null
                        
                        # Remove file if empty (only contains header)
                        if [ $(wc -l < "$temp_cloud" 2>/dev/null) -le 1 ]; then
                            rm -f "$CLOUD_ADMIN_LIST"
                            rm -f "$temp_cloud"
                            print_success "Removed empty cloud admin list"
                        else
                            mv "$temp_cloud" "$CLOUD_ADMIN_LIST" 2>/dev/null
                            print_success "Removed $player_name from cloud admin list"
                        fi
                    fi
                    ;;
            esac
            ;;
    esac
}

# Function to handle blacklist changes
handle_blacklist_change() {
    local player_name="$1"
    local old_blacklisted="$2"
    local new_blacklisted="$3"
    
    if [ "$new_blacklisted" = "YES" ]; then
        local player_record=$(find_player "$player_name")
        local ip=$(get_player_field "$player_name" 2)
        local rank=$(get_player_field "$player_name" 4)
        
        print_step "Blacklisting player: $player_name (Rank: $rank, IP: $ip)"
        
        # Remove privileges first in correct order: /unmod, /unadmin, /ban NAME, /ban IP
        case "$rank" in
            "MOD")
                send_server_command "/unmod $player_name"
                send_server_command "/unadmin $player_name"
                ;;
            "ADMIN")
                send_server_command "/unadmin $player_name"
                ;;
            "SUPER")
                # For SUPER admins, stop if connected first
                send_server_command "/stop"
                # Remove from cloud admin list (ignore first line)
                if [ -f "$CLOUD_ADMIN_LIST" ]; then
                    local temp_cloud="${CLOUD_ADMIN_LIST}.tmp"
                    head -1 "$CLOUD_ADMIN_LIST" > "$temp_cloud" 2>/dev/null
                    grep -v "^#" "$CLOUD_ADMIN_LIST" 2>/dev/null | grep -v "^$player_name$" >> "$temp_cloud" 2>/dev/null
                    
                    # Remove file if empty (only contains header)
                    if [ $(wc -l < "$temp_cloud" 2>/dev/null) -le 1 ]; then
                        rm -f "$CLOUD_ADMIN_LIST"
                        rm -f "$temp_cloud"
                    else
                        mv "$temp_cloud" "$CLOUD_ADMIN_LIST" 2>/dev/null
                    fi
                fi
                ;;
        esac
        
        # Apply bans in order
        send_server_command "/ban $player_name"
        if [ "$ip" != "UNKNOWN" ]; then
            send_server_command "/ban $ip"
        fi
        
        print_success "Blacklisted player: $player_name"
    fi
}

# Function to sync lists from players.log (respecting first line)
sync_lists_from_players_log() {
    print_step "Syncing lists from players.log..."
    
    # Ensure directory exists
    mkdir -p "$(dirname "$ADMIN_LIST")"
    
    # Clear existing lists but preserve first line
    if [ -f "$ADMIN_LIST" ]; then
        local admin_header=$(head -1 "$ADMIN_LIST")
        echo "$admin_header" > "${ADMIN_LIST}.tmp"
    else
        echo "# Usernames in this file are granted admin rights" > "${ADMIN_LIST}.tmp"
    fi
    
    if [ -f "$MOD_LIST" ]; then
        local mod_header=$(head -1 "$MOD_LIST")
        echo "$mod_header" > "${MOD_LIST}.tmp"
    else
        echo "# Usernames in this file are granted moderator rights" > "${MOD_LIST}.tmp"
    fi
    
    # Process players.log - only add players with verified IP and not blacklisted
    while IFS='|' read -r player_name ip password rank whitelisted blacklisted; do
        # Clean up variables
        player_name=$(echo "$player_name" | tr -d ' ')
        ip=$(echo "$ip" | tr -d ' ')
        rank=$(echo "$rank" | tr -d ' ')
        whitelisted=$(echo "$whitelisted" | tr -d ' ')
        blacklisted=$(echo "$blacklisted" | tr -d ' ')
        
        # Only add to lists if IP is verified and not blacklisted
        if [ "$ip" != "UNKNOWN" ] && [ "$blacklisted" = "NO" ]; then
            case "$rank" in
                "ADMIN"|"SUPER")
                    if ! grep -q "^$player_name$" "${ADMIN_LIST}.tmp" 2>/dev/null; then
                        echo "$player_name" >> "${ADMIN_LIST}.tmp"
                    fi
                    ;;
                "MOD")
                    if ! grep -q "^$player_name$" "${MOD_LIST}.tmp" 2>/dev/null; then
                        echo "$player_name" >> "${MOD_LIST}.tmp"
                    fi
                    ;;
            esac
        fi
    done < "$PLAYERS_LOG"
    
    # Update the actual lists
    mv "${ADMIN_LIST}.tmp" "$ADMIN_LIST" 2>/dev/null
    mv "${MOD_LIST}.tmp" "$MOD_LIST" 2>/dev/null
    
    print_success "Lists synchronized from players.log"
}

# Function to monitor players.log for changes
monitor_players_log() {
    local last_checksum=""
    
    while true; do
        if [ -f "$PLAYERS_LOG" ]; then
            local current_checksum=$(md5sum "$PLAYERS_LOG" 2>/dev/null | cut -d' ' -f1)
            
            if [ "$current_checksum" != "$last_checksum" ] && [ -n "$current_checksum" ]; then
                print_step "Detected change in players.log - processing changes"
                
                # Process rank changes
                for player in "${!PLAYER_RANK_CHANGES[@]}"; do
                    local change="${PLAYER_RANK_CHANGES[$player]}"
                    local old_rank=$(echo "$change" | cut -d'|' -f1)
                    local new_rank=$(echo "$change" | cut -d'|' -f2)
                    handle_rank_change "$player" "$old_rank" "$new_rank"
                done
                
                # Process blacklist changes
                for player in "${!PLAYER_BLACKLIST_CHANGES[@]}"; do
                    local change="${PLAYER_BLACKLIST_CHANGES[$player]}"
                    local old_blacklisted=$(echo "$change" | cut -d'|' -f1)
                    local new_blacklisted=$(echo "$change" | cut -d'|' -f2)
                    handle_blacklist_change "$player" "$old_blacklisted" "$new_blacklisted"
                done
                
                # Clear processed changes
                PLAYER_RANK_CHANGES=()
                PLAYER_BLACKLIST_CHANGES=()
                
                # Sync lists
                sync_lists_from_players_log
                last_checksum="$current_checksum"
            fi
        fi
        
        sleep 1
    done
}

# Function to handle password setup
handle_password_setup() {
    local player_name="$1"
    local password="$2"
    local confirm_password="$3"
    
    # Clear chat immediately for security - ALWAYS CLEAR NO MATTER WHAT
    send_server_command "/clear"
    
    local validation_result=$(validate_password "$password" "$confirm_password")
    
    case "$validation_result" in
        "PASSWORD_VALID")
            update_player "$player_name" "" "$password" "" "" ""
            sleep 0.5
            send_player_message "$player_name" "Password set successfully! You can now use commands like !change_psw and !ip_change."
            print_success "Password set for $player_name"
            ;;
        "PASSWORDS_DO_NOT_MATCH")
            sleep 0.5
            send_player_message "$player_name" "ERROR: Passwords do not match. Usage: !psw PASSWORD CONFIRM_PASSWORD"
            ;;
        "PASSWORD_LENGTH_INVALID")
            sleep 0.5
            send_player_message "$player_name" "ERROR: Password must be between 7 and 16 characters."
            ;;
    esac
}

# Function to handle password change
handle_password_change() {
    local player_name="$1"
    local old_password="$2"
    local new_password="$3"
    
    # Clear chat immediately for security
    send_server_command "/clear"
    
    local current_password=$(get_player_field "$player_name" 3)
    
    if [ "$current_password" = "$old_password" ]; then
        local validation_result=$(validate_password "$new_password" "$new_password")
        
        case "$validation_result" in
            "PASSWORD_VALID")
                update_player "$player_name" "" "$new_password" "" "" ""
                sleep 0.5
                send_player_message "$player_name" "Password changed successfully!"
                print_success "Password changed for $player_name"
                ;;
            "PASSWORD_LENGTH_INVALID")
                sleep 0.5
                send_player_message "$player_name" "ERROR: New password must be between 7 and 16 characters."
                ;;
        esac
    else
        sleep 0.5
        send_player_message "$player_name" "ERROR: Current password is incorrect."
    fi
}

# Function to handle IP change verification
handle_ip_change() {
    local player_name="$1"
    local password="$2"
    
    # Clear chat immediately for security
    send_server_command "/clear"
    
    local current_password=$(get_player_field "$player_name" 3)
    local current_ip=$(get_player_field "$player_name" 2)
    local new_ip="${PLAYER_IPS[$player_name]}"
    
    if [ "$current_password" = "$password" ]; then
        if [ "$new_ip" != "$current_ip" ] && [ "$new_ip" != "UNKNOWN" ]; then
            update_player "$player_name" "$new_ip" "" "" "" ""
            sleep 0.5
            send_player_message "$player_name" "IP address updated successfully! New IP: $new_ip"
            print_success "IP updated for $player_name: $new_ip"
            
            # Cancel IP verification timer
            unset PLAYER_IP_VERIFICATION_TIMERS["$player_name"]
        else
            sleep 0.5
            send_player_message "$player_name" "ERROR: No IP change detected or IP is unknown."
        fi
    else
        sleep 0.5
        send_player_message "$player_name" "ERROR: Incorrect password."
    fi
}

# Function to check password requirement
check_password_requirement() {
    local player_name="$1"
    
    if [ -z "${PLAYER_PASSWORD_TIMERS[$player_name]}" ]; then
        PLAYER_PASSWORD_TIMERS["$player_name"]=$(date +%s)
        
        # Schedule password reminder after 5 seconds
        (
            sleep 5
            local password=$(get_player_field "$player_name" 3)
            
            if [ "$password" = "NONE" ] || [ -z "$password" ]; then
                send_player_message "$player_name" "REMINDER: Please set your password using: !psw YOUR_PASSWORD CONFIRM_PASSWORD"
                print_warning "Sent password reminder to $player_name"
            fi
        ) &
        
        # Schedule kick after 1 minute if no password
        (
            sleep 60
            local password=$(get_player_field "$player_name" 3)
            
            if [ "$password" = "NONE" ] || [ -z "$password" ]; then
                send_server_command "/kick $player_name"
                send_player_message "$player_name" "Kicked for not setting a password within 1 minute."
                print_warning "Kicked $player_name for not setting password"
            fi
        ) &
    fi
}

# Function to check IP verification requirement
check_ip_verification() {
    local player_name="$1"
    local current_ip="$2"
    
    local stored_ip=$(get_player_field "$player_name" 2)
    
    if [ "$stored_ip" != "UNKNOWN" ] && [ "$current_ip" != "$stored_ip" ]; then
        if [ -z "${PLAYER_IP_VERIFICATION_TIMERS[$player_name]}" ]; then
            PLAYER_IP_VERIFICATION_TIMERS["$player_name"]=$(date +%s)
            
            # Notify player about IP change after 5 seconds
            (
                sleep 5
                send_player_message "$player_name" "SECURITY ALERT: IP change detected! You have 25 seconds to verify with: !ip_change YOUR_CURRENT_PASSWORD"
                send_player_message "$player_name" "Old IP: $stored_ip | New IP: $current_ip"
                print_warning "IP change detected for $player_name: $stored_ip -> $current_ip"
            ) &
            
            # Schedule kick and ban after 30 seconds total (25s after notification)
            (
                sleep 30
                if [ -n "${PLAYER_IP_VERIFICATION_TIMERS[$player_name]}" ]; then
                    send_server_command "/kick $player_name"
                    send_server_command "/ban $current_ip"
                    send_player_message "$player_name" "Kicked and IP banned for failing to verify IP change."
                    print_warning "Kicked and banned $player_name for IP verification failure"
                    
                    # Unban after 30 seconds
                    (
                        sleep 30
                        send_server_command "/unban $current_ip"
                        print_success "Auto-unbanned IP: $current_ip"
                    ) &
                    
                    unset PLAYER_IP_VERIFICATION_TIMERS["$player_name"]
                fi
            ) &
        fi
    fi
}

# Function to process chat commands from console.log
process_chat_command() {
    local player_name="$1"
    local message="$2"
    
    # Update last seen time
    PLAYER_LAST_SEEN["$player_name"]=$(date +%s)
    
    case "$message" in
        "!psw "*)
            local args=$(echo "$message" | cut -d' ' -f2-)
            local password1=$(echo "$args" | awk '{print $1}')
            local password2=$(echo "$args" | awk '{print $2}')
            
            # ALWAYS CLEAR CHAT even if command is incomplete
            send_server_command "/clear"
            
            if [ -n "$password1" ] && [ -n "$password2" ]; then
                handle_password_setup "$player_name" "$password1" "$password2"
            else
                sleep 0.5
                send_player_message "$player_name" "ERROR: Usage: !psw PASSWORD CONFIRM_PASSWORD"
            fi
            ;;
        "!change_psw "*)
            local args=$(echo "$message" | cut -d' ' -f2-)
            local old_password=$(echo "$args" | awk '{print $1}')
            local new_password=$(echo "$args" | awk '{print $2}')
            
            # ALWAYS CLEAR CHAT
            send_server_command "/clear"
            
            if [ -n "$old_password" ] && [ -n "$new_password" ]; then
                handle_password_change "$player_name" "$old_password" "$new_password"
            else
                sleep 0.5
                send_player_message "$player_name" "ERROR: Usage: !change_psw OLD_PASSWORD NEW_PASSWORD"
            fi
            ;;
        "!ip_change "*)
            local password=$(echo "$message" | cut -d' ' -f2)
            
            # ALWAYS CLEAR CHAT
            send_server_command "/clear"
            
            if [ -n "$password" ]; then
                handle_ip_change "$player_name" "$password"
            else
                sleep 0.5
                send_player_message "$player_name" "ERROR: Usage: !ip_change YOUR_CURRENT_PASSWORD"
            fi
            ;;
    esac
}

# Function to monitor console.log for player events and commands
monitor_console_log() {
    print_header "STARTING RANK PATCHER - WORLD: $WORLD_ID, PORT: $PORT"
    print_status "Monitoring: $LOG_FILE"
    print_status "Players log: $PLAYERS_LOG"
    print_status "Screen session: $SCREEN_SERVER"
    print_status "GNUstep path: $HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/"
    
    # Call emergency repair at startup
    emergency_repair_players_log
    
    # Wait for log file to be created if it doesn't exist
    if [ ! -f "$LOG_FILE" ]; then
        print_warning "Log file not found, waiting for it to be created..."
        local wait_count=0
        while [ ! -f "$LOG_FILE" ] && [ $wait_count -lt 60 ]; do
            sleep 1
            ((wait_count++))
        done
        
        if [ ! -f "$LOG_FILE" ]; then
            print_error "Log file never appeared: $LOG_FILE"
            print_error "Make sure the server is running and the world exists"
            exit 1
        fi
        print_success "Log file created: $LOG_FILE"
    fi
    
    # Initialize players.log
    initialize_players_log
    
    # Start monitoring players.log in background
    monitor_players_log &
    local monitor_pid=$!
    
    # Monitor console.log for player events
    tail -n 0 -F "$LOG_FILE" | while read line; do
        # Detect player connections - GNUstep format
        if [[ "$line" =~ Player\ Connected\ ([a-zA-Z0-9_]+)\ \|\ ([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+) ]]; then
            local player_name="${BASH_REMATCH[1]}"
            local player_ip="${BASH_REMATCH[2]}"
            
            print_success "Player connected: $player_name ($player_ip)"
            
            # Store current IP
            PLAYER_IPS["$player_name"]="$player_ip"
            PLAYER_LAST_SEEN["$player_name"]=$(date +%s)
            
            # Check if player exists in players.log
            local player_record=$(find_player "$player_name")
            if [ -z "$player_record" ]; then
                # New player - add to players.log with actual IP
                update_player "$player_name" "$player_ip" "NONE" "NONE" "NO" "NO"
                print_success "Added new player: $player_name"
            else
                # Player exists - update IP if different
                local stored_ip=$(get_player_field "$player_name" 2)
                if [ "$stored_ip" != "$player_ip" ] && [ "$stored_ip" != "UNKNOWN" ]; then
                    PLAYER_IPS["$player_name"]="$player_ip"
                    check_ip_verification "$player_name" "$player_ip"
                elif [ "$stored_ip" = "UNKNOWN" ]; then
                    # Update UNKNOWN IP to actual IP
                    update_player "$player_name" "$player_ip" "" "" "" ""
                fi
            fi
            
            # Check password requirement for players with NONE password
            local password=$(get_player_field "$player_name" 3)
            if [ "$password" = "NONE" ] || [ -z "$password" ]; then
                check_password_requirement "$player_name"
            fi
            
        # Detect player disconnections - GNUstep format
        elif [[ "$line" =~ Client\ disconnected:([a-f0-9]+) ]] || [[ "$line" =~ Player\ Disconnected\ ([a-zA-Z0-9_]+) ]]; then
            local player_name=""
            if [[ "$line" =~ Player\ Disconnected\ ([a-zA-Z0-9_]+) ]]; then
                player_name="${BASH_REMATCH[1]}"
            fi
            
            if [ -n "$player_name" ]; then
                print_warning "Player disconnected: $player_name"
                
                # Clean up timers
                unset PLAYER_PASSWORD_TIMERS["$player_name"]
                unset PLAYER_IP_VERIFICATION_TIMERS["$player_name"]
                unset PLAYER_LAST_SEEN["$player_name"]
            fi
            
        # Detect chat messages
        elif [[ "$line" =~ ([a-zA-Z0-9_]+):\ (.+) ]]; then
            local player_name="${BASH_REMATCH[1]}"
            local message="${BASH_REMATCH[2]}"
            
            # Skip server messages
            [ "$player_name" = "SERVER" ] && continue
            
            # Process commands
            if [[ "$message" == "!psw "* || "$message" == "!change_psw "* || "$message" == "!ip_change "* ]]; then
                print_step "Processing command from $player_name: $message"
                process_chat_command "$player_name" "$message"
            fi
        fi
    done
    
    # Cleanup
    kill $monitor_pid 2>/dev/null
}

# Cleanup function
cleanup() {
    print_status "Cleaning up rank patcher..."
    # Kill any background processes
    jobs -p | xargs -r kill 2>/dev/null
    print_status "Rank patcher stopped."
    exit 0
}

# Set trap for cleanup
trap cleanup EXIT INT TERM

# Main execution
if [ $# -eq 1 ] || [ $# -eq 2 ]; then
    # Verify GNUstep environment
    if [ ! -d "$HOME/GNUstep" ]; then
        print_warning "GNUstep directory not found, but continuing..."
    fi
    
    monitor_console_log
else
    print_error "Usage: $0 <console_log_file> [port]"
    print_status "Example: $0 \"$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves/WORLD_NAME/console.log\" 12153"
    print_status "Note: The log file should be in the world's save directory"
    exit 1
fi
