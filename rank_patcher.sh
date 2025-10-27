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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
        # echo -e "${CYAN}[DEBUG]${NC} $message" # Descomentar para debug en consola
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
            execute_server_command "/mod \"$player_name\""
            current_player_ranks["$player_name"]="$rank"
            rank_already_applied["$player_name"]="$rank"
            ;;
        "ADMIN")
            execute_server_command "/admin \"$player_name\""
            current_player_ranks["$player_name"]="$rank"
            rank_already_applied["$player_name"]="$rank"
            ;;
        "SUPER")
            execute_server_command "/admin \"$player_name\""
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
                execute_server_command "/unmod \"$player_name\""
                ;;
            "ADMIN")
                execute_server_command "/unadmin \"$player_name\""
                ;;
            "SUPER")
                execute_server_command "/unadmin \"$player_name\""
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
                execute_server_command "/admin \"$player_name\""
                ;;
            "MOD")
                execute_server_command "/mod \"$player_name\""
                ;;
            "SUPER")
                add_to_cloud_admin "$player_name"
                execute_server_command "/admin \"$player_name\""
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
                    execute_server_command "/kick \"$player_name\""
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
                        execute_server_command "/kick \"$player_name\""
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

handle_password_creation() {
    local player_name="$1" password="$2" confirm_password="$3"
    
    execute_server_command "/clear"
    
    local player_info=$(get_player_info "$player_name")
    if [ -n "$player_info" ]; then
        local current_password=$(echo "$player_info" | cut -d'|' -f2)
        if [ "$current_password" != "NONE" ]; then
            # [CORRECCIÓN] Usar execute_server_command
            execute_server_command "ERROR: $player_name, you already have a password set. Use !change_psw to change it."
            return 1
        fi
    fi
    
    if [ ${#password} -lt 7 ] || [ ${#password} -gt 16 ]; then
        # [CORRECCIÓN] Usar execute_server_command
        execute_server_command "ERROR: $player_name, password must be between 7 and 16 characters."
        return 1
    fi
    
    if [ "$password" != "$confirm_password" ]; then
        # [CORRECCIÓN] Usar execute_server_command
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
        
        # [CORRECCIÓN] Usar execute_server_command
        execute_server_command "SUCCESS: $player_name, password set successfully."
        return 0
    else
        # [CORRECCIÓN] Usar execute_server_command
        execute_server_command "ERROR: $player_name, player not found in registry."
        return 1
    fi
}

handle_password_change() {
    local player_name="$1" old_password="$2" new_password="$3"
    
    execute_server_command "/clear"
    
    if [ ${#new_password} -lt 7 ] || [ ${#new_password} -gt 16 ]; then
        # [CORRECCIÓN] Usar execute_server_command
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
            # [CORRECCIÓN] Usar execute_server_command
            execute_server_command "ERROR: $player_name, old password is incorrect."
            return 1
        fi
        
        update_player_info "$player_name" "$first_ip" "$new_password" "$rank" "$whitelisted" "$blacklisted"
        
        # [CORRECCIÓN] Usar execute_server_command
        execute_server_command "SUCCESS: $player_name, your password has been changed successfully."
        return 0
    else
        # [CORRECCIÓN] Usar execute_server_command
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
            # [CORRECCIÓN] Usar execute_server_command
            execute_server_command "ERROR: $player_name, password is incorrect."
            return 1
        fi
        
        update_player_info "$player_name" "$current_ip" "$current_password" "$rank" "$whitelisted" "$blacklisted"
        player_verification_status["$player_name"]="verified"
        
        cancel_player_timers "$player_name"
        
        execute_server_command "SECURITY: $player_name IP verification successful."
        
        apply_pending_ranks "$player_name"
        
        start_rank_application_timer "$player_name"
        
        sync_lists_from_players_log
        
        # [CORRECCIÓN] Usar execute_server_command
        execute_server_command "SUCCESS: $player_name, your IP has been verified and updated."
        return 0
    else
        # [CORRECCIÓN] Usar execute_server_command
        execute_server_command "ERROR: $player_name, player not found in registry."
        return 1
    fi
}

cancel_player_timers() {
    local player_name="$1"
    
    local timer_types=("password_reminder" "password_kick" "ip_grace" "rank_application")
    
    for timer_type in "${timer_types[@]}"; do
        local timer_key="${timer_type}_${player_name}"
        if [ -n "${active_timers[$timer_key]}" ]; then
            local pid="${active_timers[$timer_key]}"
            if kill -0 "$pid" 2>/dev/null; then
                kill "$pid" 2>/dev/null
            fi
            unset active_timers["$timer_key"]
        fi
    done
    
    cancel_disconnect_timer "$player_name"
}

sync_lists_from_players_log() {
    if [ -z "${list_files_initialized["$WORLD_ID"]}" ]; then
        force_reload_all_lists
        list_files_initialized["$WORLD_ID"]=1
        return
    fi
    
    if [ -f "$PLAYERS_LOG" ]; then
        while IFS='|' read -r name first_ip password rank whitelisted blacklisted; do
            name=$(echo "$name" | xargs)
            rank=$(echo "$rank" | xargs)
            
            if [ -z "${connected_players[$name]}" ]; then
                continue
            fi
            
            if [ "${player_verification_status[$name]}" != "verified" ]; then
                if [ "$rank" != "NONE" ]; then
                    pending_ranks["$name"]="$rank"
                fi
                continue
            fi
            
            local current_rank="${current_player_ranks[$name]}"
            if [ "$current_rank" != "$rank" ]; then
                apply_rank_changes "$name" "$current_rank" "$rank"
                current_player_ranks["$name"]="$rank"
            fi
            
        done < "$PLAYERS_LOG"
    fi
}

force_reload_all_lists() {
    if [ ! -f "$PLAYERS_LOG" ]; then
        return
    fi
    
    while IFS='|' read -r name first_ip password rank whitelisted blacklisted; do
        name=$(echo "$name" | xargs)
        rank=$(echo "$rank" | xargs)
        
        if [ -z "${connected_players[$name]}" ]; then
            continue
        fi
        
        if [ "${player_verification_status[$name]}" != "verified" ]; then
            continue
        fi
        
        if [ "$rank" != "NONE" ]; then
            apply_rank_to_connected_player "$name"
        fi
        
    done < "$PLAYERS_LOG"
}

apply_rank_changes() {
    local player_name="$1" old_rank="$2" new_rank="$3"
    
    case "$old_rank" in
        "ADMIN")
            execute_server_command "/unadmin \"$player_name\""
            ;;
        "MOD")
            execute_server_command "/unmod \"$player_name\""
            ;;
        "SUPER")
            execute_server_command "/unadmin \"$player_name\""
            remove_from_cloud_admin "$player_name"
            ;;
    esac
    
    sleep 1
    
    if [ "$new_rank" != "NONE" ] && [ "${player_verification_status[$player_name]}" = "verified" ]; then
        unset rank_already_applied["$player_name"]
        
        case "$new_rank" in
            "ADMIN")
                execute_server_command "/admin \"$player_name\""
                current_player_ranks["$player_name"]="$new_rank"
                rank_already_applied["$player_name"]="$new_rank"
                ;;
            "MOD")
                execute_server_command "/mod \"$player_name\""
                current_player_ranks["$player_name"]="$new_rank"
                rank_already_applied["$player_name"]="$new_rank"
                ;;
            "SUPER")
                add_to_cloud_admin "$player_name"
                execute_server_command "/admin \"$player_name\""
                current_player_ranks["$player_name"]="$new_rank"
                rank_already_applied["$player_name"]="$new_rank"
                ;;
        esac
    fi
}

handle_invalid_player_name() {
    local player_name="$1" player_ip="$2" player_hash="${3:-unknown}"
    
    print_error "INVALID PLAYER NAME DETECTED: '$player_name' (IP: $player_ip, Hash: $player_hash)"
    log_debug "INVALID PLAYER NAME DETECTED: '$player_name' (IP: $player_ip, Hash: $player_hash)"
    
    local safe_name=$(sanitize_name_for_command "$player_name")
    
    (
        sleep 3
        execute_server_command "WARNING: Invalid player name '$player_name'! Names must be 3-16 alphanumeric characters, no spaces/symbols or nullbytes!"
        
        execute_server_command "WARNING: You will be kicked and IP banned in 3 seconds for 60 seconds."
        sleep 3

        if [ -n "$player_ip" ] && [ "$player_ip" != "unknown" ]; then
            execute_server_command "/ban $player_ip"
            execute_server_command "/kick \"$safe_name\""
            print_warning "Banned invalid player name: '$player_name' (IP: $player_ip) for 60 seconds"
            
            (
                sleep 60
                execute_server_command "/unban $player_ip"
                print_success "Unbanned IP: $player_ip"
            ) &
        else
            execute_server_command "/ban \"$safe_name\""
            execute_server_command "/kick \"$safe_name\""
            print_warning "Banned invalid player name: '$player_name' (fallback to name ban)"
        fi
    ) &
    
    return 1
}

monitor_players_log() {
    local last_checksum=""
    local temp_file=$(mktemp)
    
    [ -f "$PLAYERS_LOG" ] && cp "$PLAYERS_LOG" "$temp_file"
    
    if [ -f "$PLAYERS_LOG" ]; then
        while IFS='|' read -r name first_ip password rank whitelisted blacklisted; do
            name=$(echo "$name" | xargs)
            rank=$(echo "$rank" | xargs)
            current_player_ranks["$name"]="$rank"
        done < "$PLAYERS_LOG"
    fi
    
    while true; do
        if [ -f "$PLAYERS_LOG" ]; then
            local current_checksum=$(md5sum "$PLAYERS_LOG" 2>/dev/null | cut -d' ' -f1)
            
            if [ "$current_checksum" != "$last_checksum" ]; then
                log_debug "players.log change detected. Processing..."
                process_players_log_changes "$temp_file"
                last_checksum="$current_checksum"
                cp "$PLAYERS_LOG" "$temp_file"
            fi
        fi
        sleep 1
    done
    
    rm -f "$temp_file"
}

process_players_log_changes() {
    local previous_file="$1"
    
    if [ ! -f "$previous_file" ] || [ ! -f "$PLAYERS_LOG" ]; then
        sync_lists_from_players_log
        return
    fi
    
    while IFS='|' read -r name first_ip password rank whitelisted blacklisted; do
        name=$(echo "$name" | xargs)
        rank=$(echo "$rank" | xargs)
        
        local previous_line=$(grep -i "^$name|" "$previous_file" 2>/dev/null | head -1)
        
        if [ -n "$previous_line" ]; then
            local prev_rank=$(echo "$previous_line" | cut -d'|' -f4 | xargs)
            
            if [ "$prev_rank" != "$rank" ]; then
                log_debug "Rank change for $name: $prev_rank -> $rank"
                apply_rank_changes "$name" "$prev_rank" "$rank"
            fi
        fi
    done < "$PLAYERS_LOG"
    
    sync_lists_from_players_log
}

monitor_list_files() {
    local world_dir="$BASE_SAVES_DIR/$WORLD_ID"
    local admin_list="$world_dir/adminlist.txt"
    local mod_list="$world_dir/modlist.txt"
    
    local last_admin_checksum=""
    local last_mod_checksum=""
    
    while true; do
        if [ -f "$admin_list" ]; then
            local current_admin_checksum=$(md5sum "$admin_list" 2>/dev/null | cut -d' ' -f1)
            if [ "$current_admin_checksum" != "$last_admin_checksum" ]; then
                log_debug "adminlist.txt changed externally. Re-syncing..."
                sleep 2
                sync_lists_from_players_log
                last_admin_checksum="$current_admin_checksum"
            fi
        fi
        
        if [ -f "$mod_list" ]; then
            local current_mod_checksum=$(md5sum "$mod_list" 2>/dev/null | cut -d' ' -f1)
            if [ "$current_mod_checksum" != "$last_mod_checksum" ]; then
                log_debug "modlist.txt changed externally. Re-syncing..."
                sleep 2
                sync_lists_from_players_log
                last_mod_checksum="$current_mod_checksum"
            fi
        fi
        
        sleep 5
    done
}

monitor_console_log() {
    print_header "STARTING CONSOLE LOG MONITOR"
    
    local wait_time=0
    while [ ! -f "$CONSOLE_LOG" ] && [ $wait_time -lt 30 ]; do
        sleep 1
        ((wait_time++))
    done
    
    if [ ! -f "$CONSOLE_LOG" ]; then
        print_error "Console log file not found after 30s: $CONSOLE_LOG"
        return 1
    fi
    
    tail -n 0 -F "$CONSOLE_LOG" | while read -r line; do
        log_debug "CONSOLE: $line"
        if [[ "$line" =~ Player\ Connected\ (.+)\ \|\ ([0-9a-fA-F.:]+)\ \|\ ([0-9a-f]+) ]]; then
            local player_name="${BASH_REMATCH[1]}"
            local player_ip="${BASH_REMATCH[2]}"
            local player_hash="${BASH_REMATCH[3]}"
            
            player_name=$(extract_real_name "$player_name")
            player_name=$(echo "$player_name" | xargs | tr '[:lower:]' '[:upper:]')
            
            if ! is_valid_player_name "$player_name"; then
                handle_invalid_player_name "$player_name" "$player_ip" "$player_hash"
                continue
            fi
            
            log_debug "Player Connected: $player_name, IP: $player_ip"
            
            cancel_disconnect_timer "$player_name"
            
            connected_players["$player_name"]=1
            player_ip_map["$player_name"]="$player_ip"
            
            local player_info=$(get_player_info "$player_name")
            if [ -z "$player_info" ]; then
                log_debug "New player: $player_name. Creating entry."
                update_player_info "$player_name" "$player_ip" "NONE" "NONE" "NO" "NO"
                player_verification_status["$player_name"]="verified"
                current_player_ranks["$player_name"]="NONE"
                rank_already_applied["$player_name"]="NONE"
                start_password_enforcement "$player_name"
            else
                local first_ip=$(echo "$player_info" | cut -d'|' -f1)
                local password=$(echo "$player_info" | cut -d'|' -f2)
                local rank=$(echo "$player_info" | cut -d'|' -f3)
                
                current_player_ranks["$player_name"]="$rank"
                
                if [ "$first_ip" = "UNKNOWN" ]; then
                    log_debug "Updating IP for $player_name to $player_ip"
                    update_player_info "$player_name" "$player_ip" "$password" "$rank" "NO" "NO"
                    player_verification_status["$player_name"]="verified"
                elif [ "$first_ip" != "$player_ip" ]; then
                    log_debug "IP Mismatch for $player_name. Registered: $first_ip, Current: $player_ip"
                    player_verification_status["$player_name"]="pending"
                    
                    if [ "$rank" != "NONE" ]; then
                        log_debug "Removing rank for $player_name pending IP verification."
                        apply_rank_changes "$player_name" "$rank" "NONE"
                        pending_ranks["$player_name"]="$rank"
                    fi
                    
                    start_ip_grace_timer "$player_name" "$player_ip"
                else
                    log_debug "IP match for $player_name. Status: Verified."
                    player_verification_status["$player_name"]="verified"
                fi
                
                if [ "$password" = "NONE" ]; then
                    log_debug "No password for $player_name. Starting enforcement."
                    start_password_enforcement "$player_name"
                fi
                
                if [ "${player_verification_status[$player_name]}" = "verified" ]; then
                    start_rank_application_timer "$player_name"
                fi
            fi
            
            sync_lists_from_players_log
        fi
        
        if [[ "$line" =~ Player\ Disconnected\ (.+) ]]; then
            local player_name="${BASH_REMATCH[1]}"
            player_name=$(echo "$player_name" | xargs | tr '[:lower:]' '[:upper:]')
            
            if is_valid_player_name "$player_name"; then
                log_debug "Player Disconnected: $player_name"
                cancel_player_timers "$player_name"
                
                start_disconnect_timer "$player_name"
                
                unset connected_players["$player_name"]
                unset player_ip_map["$player_name"]
                unset player_verification_status["$player_name"]
                unset pending_ranks["$player_name"]
                unset rank_already_applied["$player_name"]
                
                sync_lists_from_players_log
            fi
        fi
        
        if [[ "$line" =~ ([a-zA-Z0-9_]+):\ (.+)$ ]]; then
            local player_name="${BASH_REMATCH[1]}"
            local message="${BASH_REMATCH[2]}"
            local current_ip="${player_ip_map[$player_name]}"
            
            player_name=$(echo "$player_name" | xargs | tr '[:lower:]' '[:upper:]')
            
            if is_valid_player_name "$player_name"; then
                case "$message" in
                    "!psw "*)
                        if [[ "$message" =~ !psw\ ([^[:space:]]+)\ ([^[:space:]]+)$ ]]; then
                            local password="${BASH_REMATCH[1]}"
                            local confirm_password="${BASH_REMATCH[2]}"
                            log_debug "$player_name trying to set password."
                            handle_password_creation "$player_name" "$password" "$confirm_password"
                        else
                            execute_server_command "/clear"
                            # [CORRECCIÓN] Usar execute_server_command
                            execute_server_command "ERROR: $player_name, invalid format! Example: !psw Mypassword123 Mypassword123"
                        fi
                        ;;
                    "!change_psw "*)
                        if [[ "$message" =~ !change_psw\ ([^[:space:]]+)\ ([^[:space:]]+)$ ]]; then
                            local old_password="${BASH_REMATCH[1]}"
                            local new_password="${BASH_REMATCH[2]}"
                            log_debug "$player_name trying to change password."
                            handle_password_change "$player_name" "$old_password" "$new_password"
                        else
                            execute_server_command "/clear"
                            # [CORRECCIÓN] Usar execute_server_command
                            execute_server_command "ERROR: $player_name, invalid format! Use: !change_psw OLD_PASSWORD NEW_PASSWORD"
                        fi
                        ;;
                    "!ip_change "*)
                        if [[ "$message" =~ !ip_change\ (.+)$ ]]; then
                            local password="${BASH_REMATCH[1]}"
                            log_debug "$player_name trying to verify IP."
                            handle_ip_change "$player_name" "$password" "$current_ip"
                        else
                            execute_server_command "/clear"
                            # [CORRECCIÓN] Usar execute_server_command
                            execute_server_command "ERROR: $player_name, invalid format! Use: !ip_change YOUR_PASSWORD"
                        fi
                        ;;
                esac
            fi
        fi
        
        if [[ "$line" =~ cleared\ (.+)\ list ]]; then
            log_debug "Server list cleared detected. Forcing reload."
            sleep 2
            force_reload_all_lists
        fi
    done
}

setup_paths() {
    local port="$1"
    
    if [ -f "world_id_$port.txt" ]; then
        WORLD_ID=$(cat "world_id_$port.txt")
    else
        print_error "world_id_$port.txt not found. Rank patcher cannot determine world."
        print_error "This file should have been created by server_manager.sh"
        return 1
    fi
    
    if [ -z "$WORLD_ID" ]; then
        print_error "World ID file is empty. Cannot continue."
        return 1
    fi
    
    PLAYERS_LOG="$BASE_SAVES_DIR/$WORLD_ID/players.log"
    CONSOLE_LOG="$BASE_SAVES_DIR/$WORLD_ID/console.log"
    PATCH_DEBUG_LOG="$BASE_SAVES_DIR/$WORLD_ID/patch_debug.log"
    SCREEN_SESSION="blockheads_server_$port"
    
    [ ! -f "$PLAYERS_LOG" ] && touch "$PLAYERS_LOG"
    [ ! -f "$PATCH_DEBUG_LOG" ] && touch "$PATCH_DEBUG_LOG"
    
    return 0
}

cleanup() {
    print_header "CLEANING UP RANK PATCHER"
    
    jobs -p | xargs kill -9 2>/dev/null
    
    for timer_key in "${!active_timers[@]}"; do
        local pid="${active_timers[$timer_key]}"
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
        fi
    done
    
    for player_name in "${!disconnect_timers[@]}"; do
        local pid="${disconnect_timers[$player_name]}"
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
        fi
    done
    
    print_success "Cleanup completed"
    exit 0
}

main() {
    if [ $# -lt 1 ]; then
        print_error "Usage: $0 <port>"
        print_status "Example: $0 12153"
        exit 1
    fi
    
    PORT="$1"
    
    print_header "THE BLOCKHEADS RANK PATCHER"
    print_status "Starting rank patcher for port: $PORT"
    
    trap cleanup EXIT INT TERM
    
    if ! setup_paths "$PORT"; then
        exit 1
    fi
    
    log_debug "--- Rank Patcher Starting ---"
    
    if ! screen_session_exists "$SCREEN_SESSION"; then
        print_error "Server screen session not found: $SCREEN_SESSION"
        print_status "Please start the server first using server_manager.sh"
        log_debug "CRITICAL: Server screen $SCREEN_SESSION not found on start."
        exit 1
    fi
    
    print_step "Starting players.log monitor..."
    monitor_players_log &
    
    print_step "Starting console.log monitor..."
    monitor_console_log &
    
    print_step "Starting list files monitor..."
    monitor_list_files &
    
    print_header "RANK PATCHER IS NOW RUNNING"
    print_status "Monitoring: $CONSOLE_LOG"
    print_status "Managing: $PLAYERS_LOG"
    print_status "Debug log: $PATCH_DEBUG_LOG"
    print_status "Server session: $SCREEN_SESSION"
    log_debug "--- Rank Patcher is RUNNING ---"
    
    wait
}

main "$@"
