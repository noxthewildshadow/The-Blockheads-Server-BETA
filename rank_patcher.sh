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
declare -A player_password_reminder_sent
declare -A active_timers
declare -A current_player_ranks
declare -A current_blacklisted_players
declare -A current_whitelisted_players
declare -A super_admin_disconnect_timers
declare -A pending_ranks
declare -A list_files_initialized
declare -A disconnect_timers
declare -A last_command_time
declare -A list_cleanup_timers
declare -A admin_players
declare -A mod_players

DEBUG_LOG_ENABLED=0

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
    if [ -z "$trimmed_name" ] || [ ${#trimmed_name} -lt 3 ]; then
        return 1
    fi
    
    if [ ${#trimmed_name} -gt 16 ]; then
        return 1
    fi
    
    if ! [[ "$trimmed_name" =~ [^[:space:]] ]]; then
        return 1
    fi
    
    if [[ "$trimmed_name" =~ ^[\\\/\|\<\>\:\"\?\*]+$ ]]; then
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

handle_invalid_player_name() {
    local player_name="$1" player_ip="$2" player_hash="${3:-unknown}"
    
    print_error "INVALID PLAYER NAME DETECTED: '$player_name' (IP: $player_ip, Hash: $player_hash)"
    
    local safe_name=$(sanitize_name_for_command "$player_name")
    
    (
        sleep 3
        execute_server_command "WARNING: Invalid player name '$player_name'! Names must be 3-16 alphanumeric characters, no spaces/symbols or nullbytes!"
        
        sleep 1
        
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

setup_paths() {
    local port="$1"
    
    if [ -f "world_id_$port.txt" ]; then
        WORLD_ID=$(cat "world_id_$port.txt")
        print_success "Found world ID: $WORLD_ID for port $port"
    else
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
    PATCH_DEBUG_LOG="$BASE_SAVES_DIR/$WORLD_ID/patch_debug.log"
    SCREEN_SESSION="blockheads_server_$port"
    
    [ ! -f "$PLAYERS_LOG" ] && touch "$PLAYERS_LOG"
    [ ! -f "$PATCH_DEBUG_LOG" ] && touch "$PATCH_DEBUG_LOG"
    
    print_status "Players log: $PLAYERS_LOG"
    print_status "Console log: $CONSOLE_LOG"
    print_status "Debug log: $PATCH_DEBUG_LOG"
    print_status "Screen session: $SCREEN_SESSION"
}

execute_server_command() {
    local command="$1"
    local max_retries=3
    local retry_count=0
    
    while [ $retry_count -lt $max_retries ]; do
        local current_time=$(date +%s)
        local last_time=${last_command_time["$SCREEN_SESSION"]:-0}
        local time_diff=$((current_time - last_time))
        
        if [ $time_diff -lt 1 ]; then
            local sleep_time=$((1 - time_diff))
            sleep $sleep_time
        fi
        
        if send_server_command "$SCREEN_SESSION" "$command"; then
            last_command_time["$SCREEN_SESSION"]=$(date +%s)
            return 0
        else
            ((retry_count++))
            if [ $retry_count -lt $max_retries ]; then
                sleep 1
            fi
        fi
    done
    
    print_error "Failed to execute server command after $max_retries attempts: $command"
    return 1
}

send_server_command() {
    local screen_session="$1"
    local command="$2"
    
    if screen -S "$screen_session" -p 0 -X stuff "$command$(printf \\r)" 2>/dev/null; then
        return 0
    else
        print_error "Failed to send command to screen session: $screen_session"
        return 1
    fi
}

safe_execute_command() {
    local command="$1"
    local description="$2"
    
    if ! execute_server_command "$command"; then
        print_error "Failed to execute: $description - $command"
        return 1
    fi
    return 0
}

screen_session_exists() {
    screen -list | grep -q "$1"
}

get_player_info() {
    local player_name="$1"
    if [ -f "$PLAYERS_LOG" ]; then
        while IFS='|' read -r name first_ip password rank whitelisted blacklisted; do
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

create_list_if_needed() {
    local rank="$1"
    local world_dir="$BASE_SAVES_DIR/$WORLD_ID"
    
    case "$rank" in
        "MOD")
            local mod_list="$world_dir/modlist.txt"
            if [ ! -f "$mod_list" ] || [ ! -s "$mod_list" ]; then
                safe_execute_command "/mod CREATE_LIST" "Create MOD list with CREATE_LIST"
                (
                    sleep 2
                    safe_execute_command "/unmod CREATE_LIST" "Remove CREATE_LIST from MOD list"
                ) &
            fi
            ;;
        "ADMIN"|"SUPER")
            local admin_list="$world_dir/adminlist.txt"
            if [ ! -f "$admin_list" ] || [ ! -s "$admin_list" ]; then
                safe_execute_command "/admin CREATE_LIST" "Create ADMIN list with CREATE_LIST"
                (
                    sleep 2
                    safe_execute_command "/unadmin CREATE_LIST" "Remove CREATE_LIST from ADMIN list"
                ) &
            fi
            ;;
    esac
}

start_rank_application_timer() {
    local player_name="$1"
    
    (
        sleep 4
        if [ -n "${connected_players[$player_name]}" ] && [ "${player_verification_status[$player_name]}" = "verified" ]; then
            local player_info=$(get_player_info "$player_name")
            if [ -n "$player_info" ]; then
                local rank=$(echo "$player_info" | cut -d'|' -f3)
                if [ "$rank" != "NONE" ]; then
                    create_list_if_needed "$rank"
                fi
            fi
        fi
    ) &
    
    (
        sleep 5
        if [ -n "${connected_players[$player_name]}" ] && [ "${player_verification_status[$player_name]}" = "verified" ]; then
            apply_rank_to_connected_player "$player_name"
        fi
    ) &
    
    active_timers["rank_application_$player_name"]=$!
}

start_disconnect_timer() {
    local player_name="$1"
    
    (
        sleep 8
        remove_player_rank "$player_name"
        
        sleep 2
        cleanup_empty_lists
        
        unset disconnect_timers["$player_name"]
    ) &
    
    disconnect_timers["$player_name"]=$!
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

remove_player_rank() {
    local player_name="$1"
    
    local player_info=$(get_player_info "$player_name")
    if [ -n "$player_info" ]; then
        local rank=$(echo "$player_info" | cut -d'|' -f3)
        
        case "$rank" in
            "MOD")
                safe_execute_command "/unmod $player_name" "Remove MOD rank from $player_name"
                unset mod_players["$player_name"]
                ;;
            "ADMIN")
                safe_execute_command "/unadmin $player_name" "Remove ADMIN rank from $player_name"
                unset admin_players["$player_name"]
                ;;
            "SUPER")
                safe_execute_command "/unadmin $player_name" "Remove ADMIN rank from SUPER $player_name"
                unset admin_players["$player_name"]
                start_super_disconnect_timer "$player_name"
                ;;
        esac
    fi
}

cleanup_empty_lists() {
    local world_dir="$BASE_SAVES_DIR/$WORLD_ID"
    local admin_list="$world_dir/adminlist.txt"
    local mod_list="$world_dir/modlist.txt"
    
    # Solo eliminar adminlist.txt si no hay jugadores ADMIN/SUPER conectados
    if [ ${#admin_players[@]} -eq 0 ] && [ -f "$admin_list" ]; then
        # Verificar una vez más que no hay administradores conectados
        local has_admin_connected=0
        for player in "${!connected_players[@]}"; do
            local player_info=$(get_player_info "$player")
            if [ -n "$player_info" ]; then
                local rank=$(echo "$player_info" | cut -d'|' -f3)
                if [ "$rank" = "ADMIN" ] || [ "$rank" = "SUPER" ]; then
                    has_admin_connected=1
                    break
                fi
            fi
        done
        
        if [ $has_admin_connected -eq 0 ]; then
            rm -f "$admin_list"
        fi
    fi
    
    # Solo eliminar modlist.txt si no hay jugadores MOD conectados
    if [ ${#mod_players[@]} -eq 0 ] && [ -f "$mod_list" ]; then
        # Verificar una vez más que no hay moderadores conectados
        local has_mod_connected=0
        for player in "${!connected_players[@]}"; do
            local player_info=$(get_player_info "$player")
            if [ -n "$player_info" ]; then
                local rank=$(echo "$player_info" | cut -d'|' -f3)
                if [ "$rank" = "MOD" ]; then
                    has_mod_connected=1
                    break
                fi
            fi
        done
        
        if [ $has_mod_connected -eq 0 ]; then
            rm -f "$mod_list"
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
    
    local first_ip=$(echo "$player_info" | cut -d'|' -f1)
    local password=$(echo "$player_info" | cut -d'|' -f2)
    local rank=$(echo "$player_info" | cut -d'|' -f3)
    local whitelisted=$(echo "$player_info" | cut -d'|' -f4)
    local blacklisted=$(echo "$player_info" | cut -d'|' -f5)
    local current_ip="${player_ip_map[$player_name]}"
    
    if [ "$password" = "NONE" ]; then
        return
    fi
    
    case "$rank" in
        "MOD")
            safe_execute_command "/mod $player_name" "Apply MOD rank to $player_name"
            current_player_ranks["$player_name"]="$rank"
            mod_players["$player_name"]=1
            ;;
        "ADMIN")
            safe_execute_command "/admin $player_name" "Apply ADMIN rank to $player_name"
            current_player_ranks["$player_name"]="$rank"
            admin_players["$player_name"]=1
            ;;
        "SUPER")
            safe_execute_command "/admin $player_name" "Apply ADMIN rank to SUPER $player_name"
            add_to_cloud_admin "$player_name"
            current_player_ranks["$player_name"]="$rank"
            admin_players["$player_name"]=1
            ;;
    esac
    
    if [ "$whitelisted" = "YES" ] && [ -n "$current_ip" ] && [ "$current_ip" != "UNKNOWN" ]; then
        safe_execute_command "/whitelist $current_ip" "Whitelist IP $current_ip for $player_name"
    fi
    
    if [ "$blacklisted" = "YES" ]; then
        safe_execute_command "/ban $player_name" "Ban blacklisted player $player_name"
        if [ -n "$current_ip" ] && [ "$current_ip" != "UNKNOWN" ]; then
            safe_execute_command "/ban $current_ip" "Ban IP $current_ip for blacklisted player $player_name"
        fi
    fi
}

sync_lists_from_players_log() {
    if [ -z "${list_files_initialized["$WORLD_ID"]}" ]; then
        force_reload_all_lists
        list_files_initialized["$WORLD_ID"]=1
    fi
    
    if [ -f "$PLAYERS_LOG" ]; then
        while IFS='|' read -r name first_ip password rank whitelisted blacklisted; do
            name=$(echo "$name" | xargs)
            first_ip=$(echo "$first_ip" | xargs)
            rank=$(echo "$rank" | xargs)
            whitelisted=$(echo "$whitelisted" | xargs)
            blacklisted=$(echo "$blacklisted" | xargs)
            
            if [ -z "${connected_players[$name]}" ]; then
                continue
            fi
            
            if [ "${player_verification_status[$name]}" != "verified" ]; then
                if [ "$rank" != "NONE" ]; then
                    pending_ranks["$name"]="$rank"
                fi
                continue
            fi
            
            local current_ip="${player_ip_map[$name]}"
            
            local current_rank="${current_player_ranks[$name]}"
            if [ "$current_rank" != "$rank" ]; then
                apply_rank_changes "$name" "$current_rank" "$rank"
                current_player_ranks["$name"]="$rank"
            fi
            
            local current_blacklisted="${current_blacklisted_players[$name]}"
            if [ "$current_blacklisted" != "$blacklisted" ]; then
                handle_blacklist_change "$name" "$blacklisted"
                current_blacklisted_players["$name"]="$blacklisted"
            fi
            
            local current_whitelisted="${current_whitelisted_players[$name]}"
            if [ "$current_whitelisted" != "$whitelisted" ]; then
                handle_whitelist_change "$name" "$whitelisted" "$current_ip"
                current_whitelisted_players["$name"]="$whitelisted"
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
        first_ip=$(echo "$first_ip" | xargs)
        password=$(echo "$password" | xargs)
        rank=$(echo "$rank" | xargs)
        whitelisted=$(echo "$whitelisted" | xargs)
        blacklisted=$(echo "$blacklisted" | xargs)
        
        if [ -z "${connected_players[$name]}" ]; then
            continue
        fi
        
        if [ "$rank" != "NONE" ]; then
            case "$rank" in
                "MOD")
                    safe_execute_command "/mod $name" "Force reload MOD rank for $name"
                    mod_players["$name"]=1
                    ;;
                "ADMIN")
                    safe_execute_command "/admin $name" "Force reload ADMIN rank for $name"
                    admin_players["$name"]=1
                    ;;
                "SUPER")
                    safe_execute_command "/admin $name" "Force reload ADMIN rank for SUPER $name"
                    add_to_cloud_admin "$name"
                    admin_players["$name"]=1
                    ;;
            esac
        fi
        
        if [ "$whitelisted" = "YES" ] && [ "$first_ip" != "UNKNOWN" ]; then
            safe_execute_command "/whitelist $first_ip" "Force whitelist IP $first_ip for $name"
        fi
        
        if [ "$blacklisted" = "YES" ]; then
            safe_execute_command "/ban $name" "Force ban blacklisted player $name"
            if [ "$first_ip" != "UNKNOWN" ]; then
                safe_execute_command "/ban $first_ip" "Force ban IP $first_ip for blacklisted player $name"
            fi
        fi
        
    done < "$PLAYERS_LOG"
}

apply_pending_ranks() {
    local player_name="$1"
    
    if [ -n "${pending_ranks[$player_name]}" ]; then
        local pending_rank="${pending_ranks[$player_name]}"
        
        case "$pending_rank" in
            "ADMIN")
                safe_execute_command "/admin $player_name" "Apply pending ADMIN rank to $player_name"
                admin_players["$player_name"]=1
                ;;
            "MOD")
                safe_execute_command "/mod $player_name" "Apply pending MOD rank to $player_name"
                mod_players["$player_name"]=1
                ;;
            "SUPER")
                add_to_cloud_admin "$player_name"
                safe_execute_command "/admin $player_name" "Apply pending ADMIN rank to SUPER $player_name"
                admin_players["$player_name"]=1
                ;;
        esac
        
        current_player_ranks["$player_name"]="$pending_rank"
        unset pending_ranks["$player_name"]
    fi
}

handle_whitelist_change() {
    local player_name="$1" whitelisted="$2" current_ip="$3"
    
    if [ "$whitelisted" = "YES" ] && [ -n "$current_ip" ] && [ "$current_ip" != "UNKNOWN" ]; then
        safe_execute_command "/whitelist $current_ip" "Whitelist IP $current_ip for $player_name"
    elif [ "$whitelisted" = "NO" ] && [ -n "$current_ip" ] && [ "$current_ip" != "UNKNOWN" ]; then
        safe_execute_command "/unwhitelist $current_ip" "Remove IP $current_ip from whitelist for $player_name"
    fi
}

apply_rank_changes() {
    local player_name="$1" old_rank="$2" new_rank="$3"
    
    case "$old_rank" in
        "ADMIN")
            safe_execute_command "/unadmin $player_name" "Remove ADMIN rank from $player_name"
            unset admin_players["$player_name"]
            ;;
        "MOD")
            safe_execute_command "/unmod $player_name" "Remove MOD rank from $player_name"
            unset mod_players["$player_name"]
            ;;
        "SUPER")
            start_super_disconnect_timer "$player_name"
            safe_execute_command "/unadmin $player_name" "Remove ADMIN rank from SUPER $player_name"
            unset admin_players["$player_name"]
            ;;
    esac
    
    sleep 1
    
    if [ "$new_rank" != "NONE" ]; then
        case "$new_rank" in
            "ADMIN")
                safe_execute_command "/admin $player_name" "Apply ADMIN rank to $player_name"
                admin_players["$player_name"]=1
                ;;
            "MOD")
                safe_execute_command "/mod $player_name" "Apply MOD rank to $player_name"
                mod_players["$player_name"]=1
                ;;
            "SUPER")
                add_to_cloud_admin "$player_name"
                safe_execute_command "/admin $player_name" "Apply ADMIN rank to SUPER $player_name"
                admin_players["$player_name"]=1
                ;;
        esac
    fi
}

start_super_disconnect_timer() {
    local player_name="$1"
    
    (
        sleep 10
        
        local has_other_super_admins=0
        for connected_player in "${!connected_players[@]}"; do
            if [ "$connected_player" != "$player_name" ]; then
                local player_info=$(get_player_info "$connected_player")
                if [ -n "$player_info" ]; then
                    local rank=$(echo "$player_info" | cut -d'|' -f3)
                    if [ "$rank" = "SUPER" ]; then
                        has_other_super_admins=1
                        break
                    fi
                fi
            fi
        done
        
        if [ $has_other_super_admins -eq 0 ]; then
            remove_from_cloud_admin "$player_name"
        fi
        
        unset super_admin_disconnect_timers["$player_name"]
    ) &
    
    super_admin_disconnect_timers["$player_name"]=$!
}

cancel_super_disconnect_timer() {
    local player_name="$1"
    
    if [ -n "${super_admin_disconnect_timers[$player_name]}" ]; then
        local pid="${super_admin_disconnect_timers[$player_name]}"
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
        fi
        unset super_admin_disconnect_timers["$player_name"]
    fi
}

add_to_cloud_admin() {
    local player_name="$1"
    local cloud_file="$HOME_DIR/GNUstep/Library/ApplicationSupport/TheBlockheads/cloudWideOwnedAdminlist.txt"
    
    [ ! -f "$cloud_file" ] && touch "$cloud_file"
    
    local first_line=$(head -1 "$cloud_file")
    > "$cloud_file"
    [ -n "$first_line" ] && echo "$first_line" >> "$cloud_file"
    
    if ! grep -q "^$player_name$" "$cloud_file" 2>/dev/null; then
        echo "$player_name" >> "$cloud_file"
    fi
}

remove_from_cloud_admin() {
    local player_name="$1"
    local cloud_file="$HOME_DIR/GNUstep/Library/ApplicationSupport/TheBlockheads/cloudWideOwnedAdminlist.txt"
    
    if [ -f "$cloud_file" ]; then
        local first_line=$(head -1 "$cloud_file")
        local temp_file=$(mktemp)
        
        [ -n "$first_line" ] && echo "$first_line" > "$temp_file"
        grep -v "^$player_name$" "$cloud_file" | tail -n +2 >> "$temp_file"
        
        if [ $(wc -l < "$temp_file") -le 1 ] || [ $(wc -l < "$temp_file") -eq 1 -a -z "$first_line" ]; then
            rm -f "$cloud_file"
        else
            mv "$temp_file" "$cloud_file"
        fi
    fi
}

handle_blacklist_change() {
    local player_name="$1" blacklisted="$2"
    
    local player_info=$(get_player_info "$player_name")
    if [ -n "$player_info" ]; then
        local first_ip=$(echo "$player_info" | cut -d'|' -f1)
        local password=$(echo "$player_info" | cut -d'|' -f2)
        local rank=$(echo "$player_info" | cut -d'|' -f3)
        local current_ip="${player_ip_map[$player_name]}"
        
        if [ "$blacklisted" = "YES" ]; then
            case "$rank" in
                "MOD")
                    safe_execute_command "/unmod $player_name" "Remove MOD rank from blacklisted $player_name"
                    unset mod_players["$player_name"]
                    ;;
                "ADMIN"|"SUPER")
                    safe_execute_command "/unadmin $player_name" "Remove ADMIN rank from blacklisted $player_name"
                    unset admin_players["$player_name"]
                    if [ "$rank" = "SUPER" ]; then
                        remove_from_cloud_admin "$player_name"
                    fi
                    ;;
            esac
            
            safe_execute_command "/ban $player_name" "Ban blacklisted player $player_name"
            if [ -n "$current_ip" ] && [ "$current_ip" != "UNKNOWN" ]; then
                safe_execute_command "/ban $current_ip" "Ban IP $current_ip for blacklisted player $player_name"
            fi
        else
            safe_execute_command "/unban $player_name" "Unban player $player_name"
            if [ -n "$current_ip" ] && [ "$current_ip" != "UNKNOWN" ]; then
                safe_execute_command "/unban $current_ip" "Unban IP $current_ip for $player_name"
            fi
        fi
    fi
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
                sleep 2
                for player in "${!connected_players[@]}"; do
                    apply_rank_to_connected_player "$player"
                done
                last_admin_checksum="$current_admin_checksum"
            fi
        fi
        
        if [ -f "$mod_list" ]; then
            local current_mod_checksum=$(md5sum "$mod_list" 2>/dev/null | cut -d' ' -f1)
            if [ "$current_mod_checksum" != "$last_mod_checksum" ]; then
                sleep 2
                for player in "${!connected_players[@]}"; do
                    apply_rank_to_connected_player "$player"
                done
                last_mod_checksum="$current_mod_checksum"
            fi
        fi
        
        sleep 5
    done
}

monitor_players_log() {
    local last_checksum=""
    local temp_file=$(mktemp)
    
    [ -f "$PLAYERS_LOG" ] && cp "$PLAYERS_LOG" "$temp_file"
    
    if [ -f "$PLAYERS_LOG" ]; then
        while IFS='|' read -r name first_ip password rank whitelisted blacklisted; do
            name=$(echo "$name" | xargs)
            rank=$(echo "$rank" | xargs)
            blacklisted=$(echo "$blacklisted" | xargs)
            whitelisted=$(echo "$whitelisted" | xargs)
            current_player_ranks["$name"]="$rank"
            current_blacklisted_players["$name"]="$blacklisted"
            current_whitelisted_players["$name"]="$whitelisted"
        done < "$PLAYERS_LOG"
    fi
    
    while true; do
        if [ -f "$PLAYERS_LOG" ]; then
            local current_checksum=$(md5sum "$PLAYERS_LOG" 2>/dev/null | cut -d' ' -f1)
            
            if [ "$current_checksum" != "$last_checksum" ]; then
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
        blacklisted=$(echo "$blacklisted" | xargs)
        whitelisted=$(echo "$whitelisted" | xargs)
        
        local previous_line=$(grep -i "^$name|" "$previous_file" 2>/dev/null | head -1)
        
        if [ -n "$previous_line" ]; then
            local prev_first_ip=$(echo "$previous_line" | cut -d'|' -f2 | xargs)
            local prev_password=$(echo "$previous_line" | cut -d'|' -f3 | xargs)
            local prev_rank=$(echo "$previous_line" | cut -d'|' -f4 | xargs)
            local prev_whitelisted=$(echo "$previous_line" | cut -d'|' -f5 | xargs)
            local prev_blacklisted=$(echo "$previous_line" | cut -d'|' -f6 | xargs)
            
            if [ "$prev_rank" != "$rank" ]; then
                apply_rank_changes "$name" "$prev_rank" "$rank"
            fi
            
            if [ "$prev_blacklisted" != "$blacklisted" ]; then
                handle_blacklist_change "$name" "$blacklisted"
            fi
            
            if [ "$prev_whitelisted" != "$whitelisted" ]; then
                local current_ip="${player_ip_map[$name]}"
                handle_whitelist_change "$name" "$whitelisted" "$current_ip"
            fi
        fi
    done < "$PLAYERS_LOG"
    
    sync_lists_from_players_log
}

cancel_player_timers() {
    local player_name="$1"
    
    if [ -n "${active_timers["password_reminder_$player_name"]}" ]; then
        local pid="${active_timers["password_reminder_$player_name"]}"
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
        fi
        unset active_timers["password_reminder_$player_name"]
    fi
    
    if [ -n "${active_timers["password_kick_$player_name"]}" ]; then
        local pid="${active_timers["password_kick_$player_name"]}"
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
        fi
        unset active_timers["password_kick_$player_name"]
    fi
    
    if [ -n "${active_timers["ip_grace_$player_name"]}" ]; then
        local pid="${active_timers["ip_grace_$player_name"]}"
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
        fi
        unset active_timers["ip_grace_$player_name"]
    fi
    
    if [ -n "${active_timers["rank_application_$player_name"]}" ]; then
        local pid="${active_timers["rank_application_$player_name"]}"
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
        fi
        unset active_timers["rank_application_$player_name"]
    fi
    
    cancel_disconnect_timer "$player_name"
    cancel_super_disconnect_timer "$player_name"
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
                    sleep 1
                    execute_server_command "Example of use: !psw Mypassword123 Mypassword123"
                    player_password_reminder_sent["$player_name"]=1
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
                    safe_execute_command "/kick $player_name" "Kick $player_name for not setting password"
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
                    sleep 1
                    execute_server_command "Verify with !ip_change + YOUR_PASSWORD within 25 seconds!"
                    sleep 1
                    execute_server_command "Else you'll get kicked and a temporal ip ban for 30 seconds."
                    sleep 25
                    if [ -n "${connected_players[$player_name]}" ] && [ "${player_verification_status[$player_name]}" != "verified" ]; then
                        safe_execute_command "/kick $player_name" "Kick $player_name for failed IP verification"
                        safe_execute_command "/ban $current_ip" "Temporarily ban IP $current_ip for failed verification"
                        
                        (
                            sleep 30
                            safe_execute_command "/unban $current_ip" "Unban IP $current_ip after temporary ban"
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
    
    safe_execute_command "/clear" "Clear chat for password creation"
    
    if [ ${#password} -lt 7 ] || [ ${#password} -gt 16 ]; then
        send_server_command "$SCREEN_SESSION" "ERROR: $player_name, password must be between 7 and 16 characters."
        return 1
    fi
    
    if [ "$password" != "$confirm_password" ]; then
        send_server_command "$SCREEN_SESSION" "ERROR: $player_name, passwords do not match."
        return 1
    fi
    
    local player_info=$(get_player_info "$player_name")
    if [ -n "$player_info" ]; then
        local first_ip=$(echo "$player_info" | cut -d'|' -f1)
        local current_password=$(echo "$player_info" | cut -d'|' -f2)
        local rank=$(echo "$player_info" | cut -d'|' -f3)
        local whitelisted=$(echo "$player_info" | cut -d'|' -f4)
        local blacklisted=$(echo "$player_info" | cut -d'|' -f5)
        
        cancel_player_timers "$player_name"
        
        update_player_info "$player_name" "$first_ip" "$password" "$rank" "$whitelisted" "$blacklisted"
        
        send_server_command "$SCREEN_SESSION" "SUCCESS: $player_name, password set successfully."
        return 0
    else
        send_server_command "$SCREEN_SESSION" "ERROR: $player_name, player not found in registry."
        return 1
    fi
}

handle_password_change() {
    local player_name="$1" old_password="$2" new_password="$3"
    
    safe_execute_command "/clear" "Clear chat for password change"
    
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
        
        if [ "$current_password" != "$old_password" ]; then
            send_server_command "$SCREEN_SESSION" "ERROR: $player_name, old password is incorrect."
            return 1
        fi
        
        update_player_info "$player_name" "$first_ip" "$new_password" "$rank" "$whitelisted" "$blacklisted"
        
        send_server_command "$SCREEN_SESSION" "SUCCESS: $player_name, your password has been changed successfully."
        return 0
    else
        send_server_command "$SCREEN_SESSION" "ERROR: $player_name, player not found in registry."
        return 1
    fi
}

handle_ip_change() {
    local player_name="$1" password="$2" current_ip="$3"
    
    safe_execute_command "/clear" "Clear chat for IP change verification"
    
    local player_info=$(get_player_info "$player_name")
    if [ -n "$player_info" ]; then
        local first_ip=$(echo "$player_info" | cut -d'|' -f1)
        local current_password=$(echo "$player_info" | cut -d'|' -f2)
        local rank=$(echo "$player_info" | cut -d'|' -f3)
        local whitelisted=$(echo "$player_info" | cut -d'|' -f4)
        local blacklisted=$(echo "$player_info" | cut -d'|' -f5)
        
        if [ "$current_password" != "$password" ]; then
            send_server_command "$SCREEN_SESSION" "ERROR: $player_name, password is incorrect."
            return 1
        fi
        
        update_player_info "$player_name" "$current_ip" "$current_password" "$rank" "$whitelisted" "$blacklisted"
        player_verification_status["$player_name"]="verified"
        
        cancel_player_timers "$player_name"
        
        execute_server_command "SECURITY: $player_name IP verification successful."
        
        apply_pending_ranks "$player_name"
        
        apply_rank_to_connected_player "$player_name"
        
        sync_lists_from_players_log
        
        send_server_command "$SCREEN_SESSION" "SUCCESS: $player_name, your IP has been verified and updated."
        return 0
    else
        send_server_command "$SCREEN_SESSION" "ERROR: $player_name, player not found in registry."
        return 1
    fi
}

monitor_console_log() {
    print_header "STARTING CONSOLE LOG MONITOR"
    
    local wait_time=0
    while [ ! -f "$CONSOLE_LOG" ] && [ $wait_time -lt 30 ]; do
        sleep 1
        ((wait_time++))
    done
    
    if [ ! -f "$CONSOLE_LOG" ]; then
        print_error "Console log not found after 30 seconds: $CONSOLE_LOG"
        return 1
    fi
    
    tail -n 0 -F "$CONSOLE_LOG" | while read -r line; do
        if [[ "$line" =~ Player\ Connected\ (.+)\ \|\ ([0-9a-fA-F.:]+)\ \|\ ([0-9a-f]+) ]]; then
            local player_name="${BASH_REMATCH[1]}"
            local player_ip="${BASH_REMATCH[2]}"
            local player_hash="${BASH_REMATCH[3]}"
            
            player_name=$(extract_real_name "$player_name")
            player_name=$(echo "$player_name" | xargs)
            
            if ! is_valid_player_name "$player_name"; then
                handle_invalid_player_name "$player_name" "$player_ip" "$player_hash"
                continue
            fi
            
            cancel_disconnect_timer "$player_name"
            cancel_super_disconnect_timer "$player_name"
            
            connected_players["$player_name"]=1
            player_ip_map["$player_name"]="$player_ip"
            
            local player_info=$(get_player_info "$player_name")
            if [ -z "$player_info" ]; then
                update_player_info "$player_name" "$player_ip" "NONE" "NONE" "NO" "NO"
                player_verification_status["$player_name"]="verified"
                start_password_enforcement "$player_name"
            else
                local first_ip=$(echo "$player_info" | cut -d'|' -f1)
                local password=$(echo "$player_info" | cut -d'|' -f2)
                local rank=$(echo "$player_info" | cut -d'|' -f3)
                local whitelisted=$(echo "$player_info" | cut -d'|' -f4)
                
                if [ "$first_ip" = "UNKNOWN" ]; then
                    update_player_info "$player_name" "$player_ip" "$password" "$rank" "$whitelisted" "NO"
                    player_verification_status["$player_name"]="verified"
                elif [ "$first_ip" != "$player_ip" ]; then
                    player_verification_status["$player_name"]="pending"
                    
                    if [ "$rank" != "NONE" ]; then
                        apply_rank_changes "$player_name" "$rank" "NONE"
                        pending_ranks["$player_name"]="$rank"
                    fi
                    
                    start_ip_grace_timer "$player_name" "$player_ip"
                else
                    player_verification_status["$player_name"]="verified"
                fi
                
                if [ "$password" = "NONE" ]; then
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
            player_name=$(echo "$player_name" | xargs)
            
            if is_valid_player_name "$player_name"; then
                cancel_player_timers "$player_name"
                
                start_disconnect_timer "$player_name"
                
                unset connected_players["$player_name"]
                unset player_ip_map["$player_name"]
                unset player_verification_status["$player_name"]
                unset player_password_reminder_sent["$player_name"]
                unset pending_ranks["$player_name"]
                
                sync_lists_from_players_log
            fi
        fi
        
        if [[ "$line" =~ ([a-zA-Z0-9_]+):\ (.+)$ ]]; then
            local player_name="${BASH_REMATCH[1]}"
            local message="${BASH_REMATCH[2]}"
            local current_ip="${player_ip_map[$player_name]}"
            
            player_name=$(echo "$player_name" | xargs)
            
            if is_valid_player_name "$player_name"; then
                case "$message" in
                    "!psw "*)
                        if [[ "$message" =~ !psw\ ([^[:space:]]+)\ ([^[:space:]]+)$ ]]; then
                            local password="${BASH_REMATCH[1]}"
                            local confirm_password="${BASH_REMATCH[2]}"
                            handle_password_creation "$player_name" "$password" "$confirm_password"
                        else
                            safe_execute_command "/clear" "Clear chat for invalid password format"
                            send_server_command "$SCREEN_SESSION" "ERROR: $player_name, invalid format! Example of use: !psw Mypassword123 Mypassword123"
                        fi
                        ;;
                    "!change_psw "*)
                        if [[ "$message" =~ !change_psw\ ([^[:space:]]+)\ ([^[:space:]]+)$ ]]; then
                            local old_password="${BASH_REMATCH[1]}"
                            local new_password="${BASH_REMATCH[2]}"
                            handle_password_change "$player_name" "$old_password" "$new_password"
                        else
                            safe_execute_command "/clear" "Clear chat for invalid password change format"
                            send_server_command "$SCREEN_SESSION" "ERROR: $player_name, invalid format! Use: !change_psw YOUR_OLD_PSW YOUR_NEW_PSW"
                        fi
                        ;;
                    "!ip_change "*)
                        if [[ "$message" =~ !ip_change\ (.+)$ ]]; then
                            local password="${BASH_REMATCH[1]}"
                            handle_ip_change "$player_name" "$password" "$current_ip"
                        else
                            safe_execute_command "/clear" "Clear chat for invalid IP change format"
                            send_server_command "$SCREEN_SESSION" "ERROR: $player_name, invalid format! Use: !ip_change YOUR_PASSWORD"
                        fi
                        ;;
                esac
            fi
        fi
        
        if [[ "$line" =~ cleared\ (.+)\ list ]]; then
            sleep 2
            force_reload_all_lists
        fi
        
    done
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
    
    for player_name in "${!super_admin_disconnect_timers[@]}"; do
        local pid="${super_admin_disconnect_timers[$player_name]}"
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
        fi
    done
    
    for list_type in "${!list_cleanup_timers[@]}"; do
        local pid="${list_cleanup_timers[$list_type]}"
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
    
    if ! screen_session_exists "$SCREEN_SESSION"; then
        print_error "Server screen session not found: $SCREEN_SESSION"
        print_status "Please start the server first using server_manager.sh"
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
    
    wait
}

main "$@"
