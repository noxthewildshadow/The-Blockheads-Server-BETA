#!/bin/bash

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

HOME_DIR="$HOME"
BASE_SAVES_DIR="$HOME_DIR/GNUstep/Library/ApplicationSupport/TheBlockheads/saves"

PLAYERS_LOG=""
CONSOLE_LOG=""
SCREEN_SESSION=""
WORLD_ID=""
PORT=""
PATCH_DEBUG_LOG=""

declare -A connected_players
declare -A player_ip_map
declare -A player_verification_status
declare -A active_timers
declare -A current_player_ranks
declare -A pending_ranks
declare -A list_files_initialized
declare -A disconnect_timers
declare -A last_command_time
declare -A rank_already_applied

DEBUG_LOG_ENABLED=1

log_debug() {
    if [ $DEBUG_LOG_ENABLED -eq 1 ]; then
        local message="$1"
        local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        echo "$timestamp $message" >> "$PATCH_DEBUG_LOG"
    fi
}

is_valid_player_name() {
    local name="$1"
    
    if [[ -z "$name" ]] || [[ "$name" =~ ^[[:space:]]+$ ]]; then
        return 1
    fi
    
    if echo "$name" | grep -q -P "[\\x00-\\x1F\\x7F]"; then
        return 1
    fi
    
    if [[ "$name" =~ ^[[:space:]]+ ]] || [[ "$name" =~ [[:space:]]+$ ]]; then
        return 1
    fi
    
    if [[ "$name" =~ [[:space:]] ]]; then
        return 1
    fi
    
    if [[ "$name" =~ [\\\/\|\<\>\:\"\?\*] ]]; then
        return 1
    fi
    
    local trimmed_name=$(echo "$name" | xargs)
    if [ -z "$trimmed_name" ] || [ ${#trimmed_name} -lt 3 ] || [ ${#trimmed_name} -gt 16 ]; then
        return 1
    fi
    
    if ! [[ "$trimmed_name" =~ ^[a-zA-Z0-9_]+$ ]]; then
        return 1
    fi
    
    return 0
}

extract_real_name() {
    local name="$1"
    if [[ "$name" =~ ^[0-9]+\]\ (.+)$ ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo "$name"
    fi
}

sanitize_name_for_command() {
    local name="$1"
    if [ -z "$name" ]; then
        echo "$name"
        return
    fi
    echo "$name" | sed 's/\\/\\\\/g; s/"/\\"/g; s/`/\\`/g; s/\$/\\$/g'
}

execute_server_command() {
    local command="$1"
    local current_time=$(date +%s)
    local last_time=${last_command_time["$SCREEN_SESSION"]:-0}
    local time_diff=$((current_time - last_time))
    
    if [ $time_diff -lt 1 ]; then
        local sleep_time=$(bc <<< "1 - $time_diff")
        sleep $sleep_time
    fi
    
    log_debug "Executing server command: $command"
    send_server_command "$SCREEN_SESSION" "$command"
    last_command_time["$SCREEN_SESSION"]=$(date +%s)
}

send_server_command() {
    local screen_session="$1"
    local command="$2"
    
    if screen -S "$screen_session" -p 0 -X stuff "$command$(printf \\r)" 2>/dev/null; then
        return 0
    else
        log_debug "FAILED to send command to screen: $screen_session"
        return 1
    fi
}

screen_session_exists() {
    screen -list | grep -q "\.$1"
}

get_player_info() {
    local player_name="$1"
    if [ -f "$PLAYERS_LOG" ]; then
        while IFS='|' read -r name first_ip password rank whitelisted blacklisted; do
            name=$(echo "$name" | xargs)
            if [ "$name" = "$player_name" ]; then
                echo "$first_ip|$password|$rank|$whitelisted|$blacklisted"
                return 0
            fi
        done < <(grep -i "^$player_name|" "$PLAYERS_LOG")
    fi
    echo ""
}

update_player_info() {
    local player_name="$1" first_ip="$2" password="$3" rank="$4" whitelisted="${5:-NO}" blacklisted="${6:-NO}"
    
    player_name=$(echo "$player_name" | tr '[:lower:]' '[:upper:]')
    first_ip=$(echo "$first_ip" | tr '[:lower:]' '[:upper:]')
    rank=$(echo "$rank" | tr '[:lower:]' '[:upper:]')
    whitelisted=$(echo "$whitelisted" | tr '[:lower:]' '[:upper:]')
    blacklisted=$(echo "$blacklisted" | tr '[:lower:]' '[:upper:]')
    
    [ -z "$first_ip" ] && first_ip="UNKNOWN"
    [ -z "$password" ] && password="NONE"
    [ -z "$rank" ] && rank="NONE"
    [ -z "$whitelisted" ] && whitelisted="NO"
    [ -z "$blacklisted" ] && blacklisted="NO"
    
    if [ -f "$PLAYERS_LOG" ]; then
        sed -i "/^$player_name|/Id" "$PLAYERS_LOG"
        echo "$player_name|$first_ip|$password|$rank|$whitelisted|$blacklisted" >> "$PLAYERS_LOG"
    fi
}

add_to_cloud_admin() {
    local player_name="$1"
    local cloud_file="$HOME_DIR/GNUstep/Library/ApplicationSupport/TheBlockheads/cloudWideOwnedAdminlist.txt"
    
    [ ! -f "$cloud_file" ] && touch "$cloud_file"
    
    if ! grep -q "^$player_name$" "$cloud_file" 2>/dev/null; then
        echo "$player_name" >> "$cloud_file"
    fi
}

remove_from_cloud_admin() {
    local player_name="$1"
    local cloud_file="$HOME_DIR/GNUstep/Library/ApplicationSupport/TheBlockheads/cloudWideOwnedAdminlist.txt"
    
    if [ -f "$cloud_file" ]; then
        local temp_file=$(mktemp)
        grep -v "^$player_name$" "$cloud_file" > "$temp_file"
        
        if [ -s "$temp_file" ]; then
            mv "$temp_file" "$cloud_file"
        else
            rm -f "$cloud_file"
            rm -f "$temp_file"
        fi
    fi
}

start_rank_application_timer() {
    local player_name="$1"
    
    if [ -n "${connected_players[$player_name]}" ] && [ "${player_verification_status[$player_name]}" = "verified" ]; then
        local player_info=$(get_player_info "$player_name")
        if [ -n "$player_info" ]; then
            local rank=$(echo "$player_info" | cut -d'|' -f3)
            if [ "$rank" != "NONE" ]; then
                (
                    sleep 1
                    if [ -n "${connected_players[$player_name]}" ] && [ "${player_verification_status[$player_name]}" = "verified" ]; then
                        apply_rank_to_connected_player "$player_name"
                    fi
                ) &
                
                active_timers["rank_application_$player_name"]=$!
            fi
        fi
    fi
}

apply_rank_to_connected_player() {
    local player_name="$1"
    
    if [ -z "${connected_players[$player_name]}" ]; then
        return
    fi
    
    if [ "${player_verification_status[$player_name]}" != "verified" ]; then
        return
    fi
    
    local player_info=$(get_player_info "$player_name")
    if [ -z "$player_info" ]; then
        return
    fi
    
    local password=$(echo "$player_info" | cut -d'|' -f2)
    local rank=$(echo "$player_info" | cut -d'|' -f3)
    
    if [ "$password" = "NONE" ]; then
        return
    fi
    
    if [ -n "${rank_already_applied[$player_name]}" ] && [ "${rank_already_applied[$player_name]}" = "$rank" ]; then
        return
    fi
    
    case "$rank" in
        "MOD")
            execute_server_command "/mod $player_name"
            current_player_ranks["$player_name"]="$rank"
            rank_already_applied["$player_name"]="$rank"
            ;;
        "ADMIN")
            execute_server_command "/admin $player_name"
            current_player_ranks["$player_name"]="$rank"
            rank_already_applied["$player_name"]="$rank"
            ;;
        "SUPER")
            execute_server_command "/admin $player_name"
            add_to_cloud_admin "$player_name"
            current_player_ranks["$player_name"]="$rank"
            rank_already_applied["$player_name"]="$rank"
            ;;
    esac
}

start_disconnect_timer() {
    local player_name="$1"
    
    if [ "${player_verification_status[$player_name]}" != "verified" ]; then
        (
            sleep 1
            remove_player_rank "$player_name"
            unset disconnect_timers["$player_name"]
        ) &
        disconnect_timers["$player_name"]=$!
    else
        (
            sleep 10
            remove_player_rank "$player_name"
            unset disconnect_timers["$player_name"]
        ) &
        disconnect_timers["$player_name"]=$!
    fi
}

remove_player_rank() {
    local player_name="$1"
    
    local player_info=$(get_player_info "$player_name")
    if [ -n "$player_info" ]; then
        local rank=$(echo "$player_info" | cut -d'|' -f3)
        
        case "$rank" in
            "MOD")
                execute_server_command "/unmod $player_name"
                ;;
            "ADMIN")
                execute_server_command "/unadmin $player_name"
                ;;
            "SUPER")
                execute_server_command "/unadmin $player_name"
                remove_from_cloud_admin "$player_name"
                ;;
        esac
        
        unset rank_already_applied["$player_name"]
    fi
}

cancel_disconnect_timer() {
    local player_name="$1"
    
    if [ -n "${disconnect_timers[$player_name]}" ]; then
        local pid="${disconnect_timers[$player_name]}"
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
        fi
        unset disconnect_timers["$player_name"]
    fi
}

apply_pending_ranks() {
    local player_name="$1"
    
    if [ -n "${pending_ranks[$player_name]}" ]; then
        local pending_rank="${pending_ranks[$player_name]}"
        
        if [ "${player_verification_status[$player_name]}" != "verified" ]; then
            return
        fi
        
        case "$pending_rank" in
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
        
        current_player_ranks["$player_name"]="$pending_rank"
        rank_already_applied["$player_name"]="$pending_rank"
        unset pending_ranks["$player_name"]
    fi
}

start_password_reminder_timer() {
    local player_name="$1"
    
    (
        sleep 5
        if [ -n "${connected_players[$player_name]}" ]; then
            local player_info=$(get_player_info "$player_name")
            if [ -n "$player_info" ]; then
                local password=$(echo "$player_info" | cut -d'|' -f2)
                if [ "$password" = "NONE" ]; then
                    execute_server_command "SECURITY: $player_name, set your password within 60 seconds!"
                    execute_server_command "Example of use: !psw Mypassword123 Mypassword123"
                fi
            fi
        fi
    ) &
    
    active_timers["password_reminder_$player_name"]=$!
}

start_password_kick_timer() {
    local player_name="$1"
    
    (
        sleep 60
        if [ -n "${connected_players[$player_name]}" ]; then
            local player_info=$(get_player_info "$player_name")
            if [ -n "$player_info" ]; then
                local password=$(echo "$player_info" | cut -d'|' -f2)
                if [ "$password" = "NONE" ]; then
                    execute_server_command "/kick $player_name"
                fi
            fi
        fi
    ) &
    
    active_timers["password_kick_$player_name"]=$!
}

start_ip_grace_timer() {
    local player_name="$1" current_ip="$2"
    
    (
        sleep 5
        if [ -n "${connected_players[$player_name]}" ]; then
            local player_info=$(get_player_info "$player_name")
            if [ -n "$player_info" ]; then
                local first_ip=$(echo "$player_info" | cut -d'|' -f1)
                if [ "$first_ip" != "UNKNOWN" ] && [ "$first_ip" != "$current_ip" ]; then
                    execute_server_command "SECURITY ALERT: $player_name, your IP has changed!"
                    execute_server_command "Verify with !ip_change + YOUR_PASSWORD within 25 seconds!"
                    execute_server_command "Else you'll get kicked and a temporal ip ban for 30 seconds."
                    sleep 25
                    if [ -n "${connected_players[$player_name]}" ] && [ "${player_verification_status[$player_name]}" != "verified" ]; then
                        execute_server_command "/kick $player_name"
                        execute_server_command "/ban $current_ip"
                        
                        (
                            sleep 30
                            execute_server_command "/unban $current_ip"
                        ) &
                    fi
                fi
            fi
        fi
    ) &
    
    active_timers["ip_grace_$player_name"]=$!
}

start_password_enforcement() {
    local player_name="$1"
    
    start_password_reminder_timer "$player_name"
    start_password_kick_timer "$player_name"
}

start_invalid_name_timers() {
    local player_name="$1"
    local player_ip="$2"
    
    (
        log_debug "INVALID NAME: Timer started for $player_name. Sleeping 5s."
        sleep 5
        
        log_debug "INVALID NAME: Sending warning to $player_name (IP: $player_ip)."
        execute_server_command "WARNING: $player_name, your name is invalid!"
        execute_server_command "Please reconnect with a valid name (3-16 chars, A-Z, 0-9, _)."
        execute_server_command "If you stay, you will be kicked+banned for 30s, every 30s."
        
        while true; do
            log_debug "INVALID NAME LOOP: Sleeping 30s before kicking $player_name."
            sleep 30
            
            log_debug "INVALID NAME LOOP: Kicking and temp-banning $player_name (IP: $player_ip) for 30s."
            execute_server_command "Kicked: Invalid name. Temp-banned for 30s."
            
            send_server_command "$SCREEN_SESSION" "/kick $player_name"
            send_server_command "$SCREEN_SESSION" "/ban $player_ip"
            
            (
                sleep 30
                execute_server_command "/unban $player_ip"
                log_debug "INVALID NAME LOOP: Unbanned $player_ip."
            ) &
        done
        
    ) &
    
    active_timers["invalid_name_$player_name"]=$!
    log_debug "Started invalid name timer loop for $player_name (PID: ${active_timers["invalid_name_$player_name"]})"
}


handle_password_creation() {
    local player_name="$1" password="$2" confirm_password="$3"
    
    execute_server_command "/clear"
    
    local player_info=$(get_player_info "$player_name")
    if [ -n "$player_info" ]; then
        local current_password=$(echo "$player_info" | cut -d'|' -f2)
        if [ "$current_password" != "NONE" ]; then
            execute_server_command "ERROR: $player_name, you already have a password set. Use !change_psw to change it."
            return 1
        fi
    fi
    
    if [ ${#password} -lt 7 ] || [ ${#password} -gt 16 ]; then
        execute_server_command "ERROR: $player_name, password must be between 7 and 16 characters."
        return 1
    fi
    
    if [ "$password" != "$confirm_password" ]; then
        execute_server_command "ERROR: $player_name, passwords do not match."
        return 1
    fi
    
    if [ -n "$player_info" ]; then
        local first_ip=$(echo "$player_info" | cut -d'|' -f1)
        local rank=$(echo "$player_info" | cut -d'|' -f3)
        local whitelisted=$(echo "$player_info" | cut -d'|' -f4)
        local blacklisted=$(echo "$player_info" | cut -d'|' -f5)
        
        cancel_player_timers "$player_name"
        
        update_player_info "$player_name" "$first_ip" "$password" "$rank" "$whitelisted" "$blacklisted"
        
        execute_server_command "SUCCESS: $player_name, password set successfully."
        return 0
    else
        execute_server_command "ERROR: $player_name, player not found in registry."
        return 1
    fi
}

handle_password_change() {
    local player_name="$1" old_password="$2" new_password="$3"
    
    execute_server_command "/clear"
    
    if [ ${#new_password} -lt 7 ] || [ ${#new_password} -gt 16 ]; then
        execute_server_command "ERROR: $player_name, new password must be between 7 and 16 characters."
        return 1
    fi
    
    local player_info=$(get_player_info "$player_name")
    if [ -n "$player_info" ]; then
        local first_ip=$(echo "$player_info" | cut -d'|' -f1)
        local current_password=$(echo "$player_info" | cut -d'|' -f2)
        local rank=$(echo "$player_info" | cut -d'|' -f3)
        local whitelisted=$(echo "$player_info" | cut -d'|' -f4)
        local blacklisted=$(echo "$player_info" | cut -d'|' -f5)
        
        if [ "$current_password" != "$old_password" ]; then
            execute_server_command "ERROR: $player_name, old password is incorrect."
            return 1
        fi
        
        update_player_info "$player_name" "$first_ip" "$new_password" "$rank" "$whitelisted" "$blacklisted"
        
        execute_server_command "SUCCESS: $player_name, your password has been changed successfully."
        return 0
    else
        execute_server_command "ERROR: $player_name, player not found in registry."
        return 1
    fi
}

handle_ip_change() {
    local player_name="$1" password="$2" current_ip="$3"
    
    execute_server_command "/clear"
    
    local player_info=$(get_player_info "$player_name")
    if [ -n "$player_info" ]; then
        local first_ip=$(echo "$player_info" | cut -d'|' -f1)
        local current_password=$(echo "$player_info" | cut -d'|' -f2)
        local rank=$(echo "$player_info" | cut -d'|' -f3)
        local whitelisted=$(echo "$player_info" | cut -d'|' -f4)
        local blacklisted=$(echo "$player_info" | cut -d'|' -f5)
        
        if [ "$current_password" != "$password" ]; then
            execute_server_command "ERROR: $player_name, password is incorrect."
            return
