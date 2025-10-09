#!/bin/bash

# =============================================================================
# CONFIGURACIÓN Y CONSTANTES
# =============================================================================

# Colores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# Configuración de rutas
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOME_DIR="$HOME"
BASE_SAVES_DIR="$HOME_DIR/GNUstep/Library/ApplicationSupport/TheBlockheads/saves"

# Variables globales
PLAYERS_LOG=""
CONSOLE_LOG=""
SCREEN_SESSION=""
WORLD_ID=""
PORT=""
PATCH_DEBUG_LOG=""

# Arrays para gestión de estado
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

DEBUG_LOG_ENABLED=1

# =============================================================================
# FUNCIONES DE UTILIDAD
# =============================================================================

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

log_debug() {
    if [ $DEBUG_LOG_ENABLED -eq 1 ]; then
        local message="$1"
        local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        echo "$timestamp $message" >> "$PATCH_DEBUG_LOG"
        echo -e "${CYAN}[DEBUG]${NC} $message"
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

screen_session_exists() {
    screen -list | grep -q "$1"
}

# =============================================================================
# GESTIÓN DE ARCHIVOS Y RUTAS
# =============================================================================

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
    
    log_debug "=== RANK PATCHER STARTED ==="
    log_debug "World ID: $WORLD_ID"
    log_debug "Port: $port"
    log_debug "Players log: $PLAYERS_LOG"
    log_debug "Console log: $CONSOLE_LOG"
    log_debug "Debug log: $PATCH_DEBUG_LOG"
    log_debug "Screen session: $SCREEN_SESSION"
    
    print_status "Players log: $PLAYERS_LOG"
    print_status "Console log: $CONSOLE_LOG"
    print_status "Debug log: $PATCH_DEBUG_LOG"
    print_status "Screen session: $SCREEN_SESSION"
}

# =============================================================================
# GESTIÓN DE COMANDOS DEL SERVIDOR
# =============================================================================

execute_server_command() {
    local command="$1"
    local current_time=$(date +%s)
    local last_time=${last_command_time["$SCREEN_SESSION"]:-0}
    local time_diff=$((current_time - last_time))
    
    if [ $time_diff -lt 1 ]; then
        local sleep_time=$((1 - time_diff))
        sleep $sleep_time
    fi
    
    log_debug "Executing server command: $command"
    send_server_command "$SCREEN_SESSION" "$command"
    last_command_time["$SCREEN_SESSION"]=$(date +%s)
}

send_server_command() {
    local screen_session="$1"
    local command="$2"
    log_debug "Sending command to screen session $screen_session: $command"
    if screen -S "$screen_session" -p 0 -X stuff "$command$(printf \\r)" 2>/dev/null; then
        log_debug "Command sent successfully: $command"
        return 0
    else
        log_debug "FAILED to send command: $command"
        return 1
    fi
}

# =============================================================================
# GESTIÓN DE DATOS DE JUGADORES
# =============================================================================

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
        log_debug "Updated player in players.log: $player_name | $first_ip | $password | $rank | $whitelisted | $blacklisted"
    fi
}

# =============================================================================
# VERIFICACIÓN DE IP Y SEGURIDAD
# =============================================================================

verify_player_ip() {
    local player_name="$1" current_ip="$2"
    local player_info=$(get_player_info "$player_name")
    
    if [ -z "$player_info" ]; then
        log_debug "New player $player_name - automatic verification"
        return 0  # Nuevo jugador, verificado automáticamente
    fi
    
    local first_ip=$(echo "$player_info" | cut -d'|' -f1)
    
    if [ "$first_ip" = "UNKNOWN" ]; then
        log_debug "First connection for $player_name - automatic verification"
        return 0
    fi
    
    if [ "$first_ip" = "$current_ip" ]; then
        log_debug "IP match for $player_name - verified"
        return 0
    fi
    
    log_debug "IP mismatch for $player_name: DB=$first_ip, Current=$current_ip - NOT verified"
    return 1
}

handle_ip_verification_required() {
    local player_name="$1" current_ip="$2"
    
    log_debug "Starting IP verification process for $player_name"
    
    execute_server_command "SECURITY ALERT: $player_name, your IP has changed!"
    sleep 1
    execute_server_command "Verify with !ip_change YOUR_PASSWORD within 25 seconds!"
    sleep 1
    execute_server_command "Else you'll get kicked and temporary IP ban for 30 seconds."
    
    # Timer para verificación
    (
        sleep 25
        if [ -n "${connected_players[$player_name]}" ] && [ "${player_verification_status[$player_name]}" != "verified" ]; then
            log_debug "IP verification failed for $player_name, kicking and banning"
            execute_server_command "/kick \"$player_name\""
            execute_server_command "/ban $current_ip"
            
            (
                sleep 30
                execute_server_command "/unban $current_ip"
                log_debug "Auto-unbanned IP: $current_ip"
            ) &
        fi
    ) &
}

# =============================================================================
# GESTIÓN DE RANGOS Y LISTAS
# =============================================================================

create_list_if_needed() {
    local rank="$1"
    local world_dir="$BASE_SAVES_DIR/$WORLD_ID"
    
    log_debug "Checking list creation for rank: $rank"
    
    # Verificar si hay al menos un jugador VERIFICADO con este rango
    local has_verified_player_with_rank=0
    for player in "${!connected_players[@]}"; do
        if [ "${player_verification_status[$player]}" = "verified" ]; then
            local player_info=$(get_player_info "$player")
            if [ -n "$player_info" ]; then
                local player_rank=$(echo "$player_info" | cut -d'|' -f3)
                if [ "$player_rank" = "$rank" ]; then
                    has_verified_player_with_rank=1
                    log_debug "Found verified player $player with rank $rank - will create list"
                    break
                fi
            fi
        fi
    done
    
    if [ $has_verified_player_with_rank -eq 0 ]; then
        log_debug "NO verified players with rank $rank connected - skipping list creation"
        return
    fi
    
    case "$rank" in
        "MOD")
            local mod_list="$world_dir/modlist.txt"
            if [ ! -f "$mod_list" ]; then
                log_debug "Creating modlist.txt using CREATE_LIST"
                execute_server_command "/mod CREATE_LIST"
                (
                    sleep 2
                    execute_server_command "/unmod CREATE_LIST"
                    log_debug "Removed CREATE_LIST from modlist"
                ) &
            else
                log_debug "modlist.txt already exists, skipping creation"
            fi
            ;;
        "ADMIN"|"SUPER")
            local admin_list="$world_dir/adminlist.txt"
            if [ ! -f "$admin_list" ]; then
                log_debug "Creating adminlist.txt using CREATE_LIST"
                execute_server_command "/admin CREATE_LIST"
                if [ "$rank" = "SUPER" ]; then
                    add_to_cloud_admin "CREATE_LIST"
                fi
                (
                    sleep 2
                    execute_server_command "/unadmin CREATE_LIST"
                    if [ "$rank" = "SUPER" ]; then
                        remove_from_cloud_admin "CREATE_LIST"
                    fi
                    log_debug "Removed CREATE_LIST from adminlist"
                ) &
            else
                log_debug "adminlist.txt already exists, skipping creation"
            fi
            ;;
    esac
}

apply_rank_to_connected_player() {
    local player_name="$1"
    
    if [ -z "${connected_players[$player_name]}" ]; then
        log_debug "Player $player_name is not connected, skipping rank application"
        return
    fi
    
    if [ "${player_verification_status[$player_name]}" != "verified" ]; then
        log_debug "Player $player_name not verified, skipping rank application"
        return
    fi
    
    local player_info=$(get_player_info "$player_name")
    if [ -z "$player_info" ]; then
        log_debug "No player info found for $player_name"
        return
    fi
    
    local first_ip=$(echo "$player_info" | cut -d'|' -f1)
    local password=$(echo "$player_info" | cut -d'|' -f2)
    local rank=$(echo "$player_info" | cut -d'|' -f3)
    local whitelisted=$(echo "$player_info" | cut -d'|' -f4)
    local blacklisted=$(echo "$player_info" | cut -d'|' -f5)
    local current_ip="${player_ip_map[$player_name]}"
    
    log_debug "Applying rank to verified player: $player_name (Rank: $rank)"
    
    if [ "$password" = "NONE" ]; then
        log_debug "Player $player_name has no password, skipping rank application"
        return
    fi
    
    case "$rank" in
        "MOD")
            execute_server_command "/mod $player_name"
            current_player_ranks["$player_name"]="$rank"
            ;;
        "ADMIN")
            execute_server_command "/admin $player_name"
            current_player_ranks["$player_name"]="$rank"
            ;;
        "SUPER")
            execute_server_command "/admin $player_name"
            add_to_cloud_admin "$player_name"
            current_player_ranks["$player_name"]="$rank"
            ;;
    esac
    
    if [ "$whitelisted" = "YES" ] && [ -n "$current_ip" ] && [ "$current_ip" != "UNKNOWN" ]; then
        execute_server_command "/whitelist $current_ip"
    fi
    
    if [ "$blacklisted" = "YES" ]; then
        execute_server_command "/ban $player_name"
        if [ -n "$current_ip" ] && [ "$current_ip" != "UNKNOWN" ]; then
            execute_server_command "/ban $current_ip"
        fi
    fi
}

remove_player_rank() {
    local player_name="$1"
    
    log_debug "Removing rank for disconnected player: $player_name"
    
    local player_info=$(get_player_info "$player_name")
    if [ -n "$player_name" ]; then
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
                start_super_disconnect_timer "$player_name"
                ;;
        esac
        
        log_debug "Removed rank $rank for disconnected player: $player_name"
    fi
}

# =============================================================================
# GESTIÓN DE LISTAS CLOUD
# =============================================================================

add_to_cloud_admin() {
    local player_name="$1"
    local cloud_file="$HOME_DIR/GNUstep/Library/ApplicationSupport/TheBlockheads/cloudWideOwnedAdminlist.txt"
    
    [ ! -f "$cloud_file" ] && touch "$cloud_file"
    
    if ! grep -q "^$player_name$" "$cloud_file" 2>/dev/null; then
        echo "$player_name" >> "$cloud_file"
        log_debug "Added $player_name to cloud admin list"
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
            log_debug "Removed $player_name from cloud admin list"
        else
            rm -f "$cloud_file"
            rm -f "$temp_file"
            log_debug "Removed cloud admin file (no super admins left after removing $player_name)"
        fi
    fi
}

remove_cloud_admin_file_if_empty() {
    local cloud_file="$HOME_DIR/GNUstep/Library/ApplicationSupport/TheBlockheads/cloudWideOwnedAdminlist.txt"
    
    if [ -f "$cloud_file" ]; then
        local valid_lines=$(grep -v -e '^$' -e '^CREATE_LIST$' "$cloud_file" | wc -l)
        
        if [ $valid_lines -eq 0 ]; then
            rm -f "$cloud_file"
            log_debug "Removed cloud admin file (no super admins left)"
        else
            log_debug "Cloud admin file still has $valid_lines valid super admin(s), keeping file"
        fi
    fi
}

# =============================================================================
# TEMPORIZADORES Y PROGRAMACIÓN
# =============================================================================

start_rank_application_timer() {
    local player_name="$1"
    
    log_debug "Starting rank application timer for: $player_name (Verification: ${player_verification_status[$player_name]})"
    
    if [ -n "${connected_players[$player_name]}" ] && [ "${player_verification_status[$player_name]}" = "verified" ]; then
        local player_info=$(get_player_info "$player_name")
        if [ -n "$player_info" ]; then
            local rank=$(echo "$player_info" | cut -d'|' -f3)
            if [ "$rank" != "NONE" ]; then
                log_debug "Player $player_name is verified with rank $rank, creating list if needed"
                create_list_if_needed "$rank"
                
                (
                    sleep 5
                    if [ -n "${connected_players[$player_name]}" ] && [ "${player_verification_status[$player_name]}" = "verified" ]; then
                        log_debug "5-second timer completed, applying rank to verified player: $player_name"
                        apply_rank_to_connected_player "$player_name"
                    else
                        log_debug "5-second timer completed but player $player_name not verified or disconnected"
                    fi
                ) &
                
                active_timers["rank_application_$player_name"]=$!
            else
                log_debug "Player $player_name is verified but has no rank, skipping rank application"
            fi
        fi
    else
        log_debug "Player $player_name not verified or disconnected, skipping list creation AND rank application"
    fi
}

start_disconnect_timer() {
    local player_name="$1"
    
    log_debug "Starting disconnect timer for: $player_name"
    
    (
        sleep 10
        log_debug "10-second disconnect timer completed, removing rank for: $player_name"
        remove_player_rank "$player_name"
        
        sleep 5
        log_debug "15-second timer completed, cleaning up lists for: $player_name"
        cleanup_empty_lists_after_disconnect "$player_name"
        
        unset disconnect_timers["$player_name"]
    ) &
    
    disconnect_timers["$player_name"]=$!
    log_debug "Started disconnect timer for $player_name (PID: ${disconnect_timers[$player_name]})"
}

start_super_disconnect_timer() {
    local player_name="$1"
    
    log_debug "Starting 10-second SUPER disconnect timer for: $player_name"
    
    (
        sleep 10
        log_debug "10-second SUPER timer completed, checking if other VERIFIED SUPER admins are connected"
        
        local has_other_super_admins=0
        for connected_player in "${!connected_players[@]}"; do
            if [ "$connected_player" != "$player_name" ]; then
                if [ "${player_verification_status[$connected_player]}" != "verified" ]; then
                    continue
                fi
                
                local player_info=$(get_player_info "$connected_player")
                if [ -n "$player_info" ]; then
                    local rank=$(echo "$player_info" | cut -d'|' -f3)
                    if [ "$rank" = "SUPER" ]; then
                        has_other_super_admins=1
                        log_debug "Found other VERIFIED SUPER admin connected: $connected_player"
                        break
                    fi
                fi
            fi
        done
        
        if [ $has_other_super_admins -eq 0 ]; then
            log_debug "No other VERIFIED SUPER admins connected, removing cloud admin file"
            remove_cloud_admin_file_if_empty
        else
            log_debug "Other VERIFIED SUPER admins still connected, keeping cloud admin file"
        fi
        
        unset super_admin_disconnect_timers["$player_name"]
    ) &
    
    super_admin_disconnect_timers["$player_name"]=$!
    log_debug "Started SUPER disconnect timer for $player_name (PID: ${super_admin_disconnect_timers[$player_name]})"
}

cancel_disconnect_timer() {
    local player_name="$1"
    
    if [ -n "${disconnect_timers[$player_name]}" ]; then
        local pid="${disconnect_timers[$player_name]}"
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            log_debug "Cancelled disconnect timer for $player_name (PID: $pid)"
        fi
        unset disconnect_timers["$player_name"]
    fi
}

cancel_super_disconnect_timer() {
    local player_name="$1"
    
    if [ -n "${super_admin_disconnect_timers[$player_name]}" ]; then
        local pid="${super_admin_disconnect_timers[$player_name]}"
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            log_debug "Cancelled SUPER disconnect timer for $player_name (PID: $pid)"
        fi
        unset super_admin_disconnect_timers["$player_name"]
    fi
}

# =============================================================================
# LIMPIEZA Y MANTENIMIENTO DE LISTAS
# =============================================================================

cleanup_empty_lists_after_disconnect() {
    local disconnected_player="$1"
    local world_dir="$BASE_SAVES_DIR/$WORLD_ID"
    local admin_list="$world_dir/adminlist.txt"
    local mod_list="$world_dir/modlist.txt"
    
    local has_admin_connected=0
    local has_mod_connected=0
    local has_super_connected=0
    
    for player in "${!connected_players[@]}"; do
        if [ "$player" = "$disconnected_player" ]; then
            continue
        fi
        
        if [ "${player_verification_status[$player]}" != "verified" ]; then
            continue
        fi
        
        local player_info=$(get_player_info "$player")
        if [ -n "$player_info" ]; then
            local rank=$(echo "$player_info" | cut -d'|' -f3)
            case "$rank" in
                "ADMIN")
                    has_admin_connected=1
                    ;;
                "MOD")
                    has_mod_connected=1
                    ;;
                "SUPER")
                    has_admin_connected=1
                    has_super_connected=1
                    ;;
            esac
        fi
    done
    
    log_debug "List cleanup check - Admin connected: $has_admin_connected, Mod connected: $has_mod_connected, Super connected: $has_super_connected"
    
    if [ $has_admin_connected -eq 0 ] && [ -f "$admin_list" ]; then
        rm -f "$admin_list"
        log_debug "Removed adminlist.txt (no verified admins connected)"
    fi
    
    if [ $has_mod_connected -eq 0 ] && [ -f "$mod_list" ]; then
        rm -f "$mod_list"
        log_debug "Removed modlist.txt (no verified mods connected)"
    fi
    
    if [ $has_super_connected -eq 0 ]; then
        remove_cloud_admin_file_if_empty
    fi
}

# =============================================================================
# SINCRONIZACIÓN DE LISTAS
# =============================================================================

sync_lists_from_players_log() {
    log_debug "Syncing lists from players.log using server commands..."
    
    if [ -z "${list_files_initialized["$WORLD_ID"]}" ]; then
        log_debug "First sync for world $WORLD_ID, forcing complete reload"
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
                log_debug "SKIPPING rank application for $name - IP not verified (Status: ${player_verification_status[$name]})"
                if [ "$rank" != "NONE" ]; then
                    pending_ranks["$name"]="$rank"
                    log_debug "Saved pending rank for $name: $rank"
                fi
                continue
            fi
            
            local current_ip="${player_ip_map[$name]}"
            
            local current_rank="${current_player_ranks[$name]}"
            if [ "$current_rank" != "$rank" ]; then
                log_debug "Rank change detected for $name: $current_rank -> $rank"
                apply_rank_changes "$name" "$current_rank" "$rank"
                current_player_ranks["$name"]="$rank"
            fi
            
            local current_blacklisted="${current_blacklisted_players[$name]}"
            if [ "$current_blacklisted" != "$blacklisted" ]; then
                log_debug "Blacklist change detected for $name: $current_blacklisted -> $blacklisted"
                handle_blacklist_change "$name" "$blacklisted"
                current_blacklisted_players["$name"]="$blacklisted"
            fi
            
            local current_whitelisted="${current_whitelisted_players[$name]}"
            if [ "$current_whitelisted" != "$whitelisted" ]; then
                log_debug "Whitelist change detected for $name: $current_whitelisted -> $whitelisted"
                handle_whitelist_change "$name" "$whitelisted" "$current_ip"
                current_whitelisted_players["$name"]="$whitelisted"
            fi
            
        done < "$PLAYERS_LOG"
    fi
    
    log_debug "Completed syncing lists using server commands"
}

force_reload_all_lists() {
    log_debug "=== FORCING COMPLETE RELOAD OF ALL LISTS FROM PLAYERS.LOG ==="
    
    if [ ! -f "$PLAYERS_LOG" ]; then
        log_debug "No players.log found, skipping reload"
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
        
        if [ "${player_verification_status[$name]}" != "verified" ]; then
            log_debug "SKIPPING force reload for $name - not verified"
            continue
        fi
        
        if [ "$rank" != "NONE" ]; then
            log_debug "Reloading player from players.log: $name (Rank: $rank)"
            
            case "$rank" in
                "MOD")
                    execute_server_command "/mod $name"
                    ;;
                "ADMIN")
                    execute_server_command "/admin $name"
                    ;;
                "SUPER")
                    execute_server_command "/admin $name"
                    add_to_cloud_admin "$name"
                    ;;
            esac
        fi
        
        if [ "$whitelisted" = "YES" ] && [ "$first_ip" != "UNKNOWN" ]; then
            execute_server_command "/whitelist $first_ip"
        fi
        
        if [ "$blacklisted" = "YES" ]; then
            execute_server_command "/ban $name"
            if [ "$first_ip" != "UNKNOWN" ]; then
                execute_server_command "/ban $first_ip"
            fi
        fi
        
    done < "$PLAYERS_LOG"
    
    log_debug "=== COMPLETE RELOAD OF ALL LISTS FINISHED ==="
}

# =============================================================================
# GESTIÓN DE CAMBIOS DE RANGOS
# =============================================================================

apply_rank_changes() {
    local player_name="$1" old_rank="$2" new_rank="$3"
    
    log_debug "Applying rank change via server commands: $player_name from $old_rank to $new_rank"
    
    case "$old_rank" in
        "ADMIN")
            execute_server_command "/unadmin $player_name"
            ;;
        "MOD")
            execute_server_command "/unmod $player_name"
            ;;
        "SUPER")
            start_super_disconnect_timer "$player_name"
            execute_server_command "/unadmin $player_name"
            ;;
    esac
    
    sleep 1
    
    if [ "$new_rank" != "NONE" ]; then
        if [ "${player_verification_status[$player_name]}" != "verified" ]; then
            log_debug "Cannot apply new rank to $player_name - not verified"
            return
        fi
        
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
    fi
}

apply_pending_ranks() {
    local player_name="$1"
    
    if [ -n "${pending_ranks[$player_name]}" ]; then
        local pending_rank="${pending_ranks[$player_name]}"
        log_debug "Applying pending rank for $player_name: $pending_rank"
        
        if [ "${player_verification_status[$player_name]}" != "verified" ]; then
            log_debug "Cannot apply pending rank for $player_name - not verified"
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
        unset pending_ranks["$player_name"]
        log_debug "Successfully applied pending rank $pending_rank to $player_name"
    fi
}

# =============================================================================
# GESTIÓN DE WHITELIST/BLACKLIST
# =============================================================================

handle_whitelist_change() {
    local player_name="$1" whitelisted="$2" current_ip="$3"
    
    log_debug "Handling whitelist change via server commands: $player_name -> $whitelisted (IP: $current_ip)"
    
    if [ "$whitelisted" = "YES" ] && [ -n "$current_ip" ] && [ "$current_ip" != "UNKNOWN" ]; then
        log_debug "Adding IP to whitelist: $current_ip for player $player_name"
        execute_server_command "/whitelist $current_ip"
    elif [ "$whitelisted" = "NO" ] && [ -n "$current_ip" ] && [ "$current_ip" != "UNKNOWN" ]; then
        log_debug "Removing IP from whitelist: $current_ip for player $player_name"
        execute_server_command "/unwhitelist $current_ip"
    fi
}

handle_blacklist_change() {
    local player_name="$1" blacklisted="$2"
    
    log_debug "Handling blacklist change via server commands: $player_name -> $blacklisted"
    
    local player_info=$(get_player_info "$player_name")
    if [ -n "$player_info" ]; then
        local first_ip=$(echo "$player_info" | cut -d'|' -f1)
        local password=$(echo "$player_info" | cut -d'|' -f2)
        local rank=$(echo "$player_info" | cut -d'|' -f3)
        local current_ip="${player_ip_map[$player_name]}"
        
        if [ "$blacklisted" = "YES" ]; then
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
            
            log_debug "Blacklisted player via server commands: $player_name"
        else
            execute_server_command "/unban $player_name"
            if [ -n "$current_ip" ] && [ "$current_ip" != "UNKNOWN" ]; then
                execute_server_command "/unban $current_ip"
            fi
            log_debug "Removed $player_name from blacklist via server commands"
        fi
    fi
}

# =============================================================================
# GESTIÓN DE CONTRASEÑAS
# =============================================================================

start_password_reminder_timer() {
    local player_name="$1"
    
    (
        log_debug "Password reminder timer started for $player_name"
        sleep 5
        
        if [ -n "${connected_players[$player_name]}" ]; then
            local player_info=$(get_player_info "$player_name")
            if [ -n "$player_info" ]; then
                local password=$(echo "$player_info" | cut -d'|' -f2)
                if [ "$password" = "NONE" ]; then
                    log_debug "Sending password reminder to $player_name"
                    execute_server_command "SECURITY: $player_name, set your password within 60 seconds!"
                    sleep 1
                    execute_server_command "Example of use: !psw Mypassword123 Mypassword123"
                    player_password_reminder_sent["$player_name"]=1
                fi
            fi
        fi
        log_debug "Password reminder timer completed for $player_name"
    ) &
    
    active_timers["password_reminder_$player_name"]=$!
}

start_password_kick_timer() {
    local player_name="$1"
    
    (
        log_debug "Password kick timer started for $player_name"
        sleep 60
        
        if [ -n "${connected_players[$player_name]}" ]; then
            local player_info=$(get_player_info "$player_name")
            if [ -n "$player_info" ]; then
                local password=$(echo "$player_info" | cut -d'|' -f2)
                if [ "$password" = "NONE" ]; then
                    log_debug "Kicking $player_name for not setting password within 60 seconds"
                    execute_server_command "/kick $player_name"
                else
                    log_debug "Player $player_name set password, no kick needed"
                fi
            fi
        fi
        log_debug "Password kick timer completed for $player_name"
    ) &
    
    active_timers["password_kick_$player_name"]=$!
}

start_password_enforcement() {
    local player_name="$1"
    
    log_debug "Starting INDEPENDENT password enforcement for $player_name"
    
    start_password_reminder_timer "$player_name"
    start_password_kick_timer "$player_name"
}

handle_password_creation() {
    local player_name="$1" password="$2" confirm_password="$3"
    
    log_debug "IMMEDIATE: Password creation requested for $player_name"
    
    execute_server_command "/clear"
    
    log_debug "IMMEDIATE: Validating password for $player_name"
    
    if [ ${#password} -lt 7 ] || [ ${#password} -gt 16 ]; then
        log_debug "IMMEDIATE: Password validation failed: length invalid (${#password} chars)"
        send_server_command "$SCREEN_SESSION" "ERROR: $player_name, password must be between 7 and 16 characters."
        return 1
    fi
    
    if [ "$password" != "$confirm_password" ]; then
        log_debug "IMMEDIATE: Password validation failed: passwords don't match"
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
        
        log_debug "IMMEDIATE: Player info found for $player_name, cancelling ALL timers"
        
        cancel_player_timers "$player_name"
        
        log_debug "IMMEDIATE: Updating players.log with new password for $player_name"
        update_player_info "$player_name" "$first_ip" "$password" "$rank" "$whitelisted" "$blacklisted"
        
        log_debug "IMMEDIATE: Password set successfully for $player_name"
        send_server_command "$SCREEN_SESSION" "SUCCESS: $player_name, password set successfully."
        return 0
    else
        log_debug "IMMEDIATE: Player info NOT found for $player_name"
        send_server_command "$SCREEN_SESSION" "ERROR: $player_name, player not found in registry."
        return 1
    fi
}

handle_password_change() {
    local player_name="$1" old_password="$2" new_password="$3"
    
    log_debug "Password change requested for $player_name"
    
    execute_server_command "/clear"
    
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

# =============================================================================
# GESTIÓN DE VERIFICACIÓN MANUAL DE IP
# =============================================================================

handle_ip_change() {
    local player_name="$1" password="$2" current_ip="$3"
    
    log_debug "IP change verification requested for $player_name"
    
    execute_server_command "/clear"
    
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
        
        log_debug "IP verification successful for $player_name - cancelling kick/ban IP cooldown"
        execute_server_command "SECURITY: $player_name IP verification successful."
        
        log_debug "Applying pending ranks for $player_name after IP verification"
        apply_pending_ranks "$player_name"
        
        start_rank_application_timer "$player_name"
        
        sync_lists_from_players_log
        
        send_server_command "$SCREEN_SESSION" "SUCCESS: $player_name, your IP has been verified and updated."
        return 0
    else
        send_server_command "$SCREEN_SESSION" "ERROR: $player_name, player not found in registry."
        return 1
    fi
}

# =============================================================================
# GESTIÓN DE NOMBRES INVÁLIDOS
# =============================================================================

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

# =============================================================================
# CANCELACIÓN DE TEMPORIZADORES
# =============================================================================

cancel_player_timers() {
    local player_name="$1"
    
    log_debug "Cancelling all timers for player: $player_name"
    
    if [ -n "${active_timers["password_reminder_$player_name"]}" ]; then
        local pid="${active_timers["password_reminder_$player_name"]}"
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            log_debug "Cancelled password reminder timer for $player_name (PID: $pid)"
        fi
        unset active_timers["password_reminder_$player_name"]
    fi
    
    if [ -n "${active_timers["password_kick_$player_name"]}" ]; then
        local pid="${active_timers["password_kick_$player_name"]}"
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            log_debug "Cancelled password kick timer for $player_name (PID: $pid)"
        fi
        unset active_timers["password_kick_$player_name"]
    fi
    
    if [ -n "${active_timers["ip_grace_$player_name"]}" ]; then
        local pid="${active_timers["ip_grace_$player_name"]}"
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            log_debug "Cancelled IP grace timer for $player_name (PID: $pid)"
        fi
        unset active_timers["ip_grace_$player_name"]
    fi
    
    if [ -n "${active_timers["rank_application_$player_name"]}" ]; then
        local pid="${active_timers["rank_application_$player_name"]}"
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            log_debug "Cancelled rank application timer for $player_name (PID: $pid)"
        fi
        unset active_timers["rank_application_$player_name"]
    fi
    
    cancel_disconnect_timer "$player_name"
    cancel_super_disconnect_timer "$player_name"
}

# =============================================================================
# MONITORES PRINCIPALES
# =============================================================================

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
                log_debug "Detected change in players.log - processing changes via server commands..."
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
                log_debug "Rank change detected via server commands: $name from $prev_rank to $rank"
                apply_rank_changes "$name" "$prev_rank" "$rank"
            fi
            
            if [ "$prev_blacklisted" != "$blacklisted" ]; then
                log_debug "Blacklist change detected via server commands: $name from $prev_blacklisted to $blacklisted"
                handle_blacklist_change "$name" "$blacklisted"
            fi
            
            if [ "$prev_whitelisted" != "$whitelisted" ]; then
                log_debug "Whitelist change detected via server commands: $name from $prev_whitelisted to $whitelisted"
                local current_ip="${player_ip_map[$name]}"
                handle_whitelist_change "$name" "$whitelisted" "$current_ip"
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
                log_debug "Detected change in adminlist.txt - forcing reload from players.log"
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
                log_debug "Detected change in modlist.txt - forcing reload from players.log"
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

monitor_console_log() {
    print_header "STARTING CONSOLE LOG MONITOR"
    log_debug "Starting console log monitor"
    
    local wait_time=0
    while [ ! -f "$CONSOLE_LOG" ] && [ $wait_time -lt 30 ]; do
        sleep 1
        ((wait_time++))
        [ $((wait_time % 5)) -eq 0 ] && log_debug "Waiting for console.log to be created..."
    done
    
    if [ ! -f "$CONSOLE_LOG" ]; then
        log_debug "ERROR: Console log never appeared: $CONSOLE_LOG"
        return 1
    fi
    
    log_debug "Console log found, starting monitoring"
    
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
            
            log_debug "Player connected: $player_name ($player_ip)"
            
            local player_info=$(get_player_info "$player_name")
            if [ -z "$player_info" ]; then
                log_debug "New player detected: $player_name, adding to players.log with IP: $player_ip"
                update_player_info "$player_name" "$player_ip" "NONE" "NONE" "NO" "NO"
                player_verification_status["$player_name"]="verified"
                start_password_enforcement "$player_name"
            else
                local first_ip=$(echo "$player_info" | cut -d'|' -f1)
                local password=$(echo "$player_info" | cut -d'|' -f2)
                local rank=$(echo "$player_info" | cut -d'|' -f3)
                local whitelisted=$(echo "$player_info" | cut -d'|' -f4)
                
                log_debug "Existing player $player_name - First IP in DB: $first_ip, Current IP: $player_ip, Rank: $rank"
                
                if [ "$first_ip" = "UNKNOWN" ]; then
                    log_debug "First real connection for $player_name, updating IP from UNKNOWN to $player_ip"
                    update_player_info "$player_name" "$player_ip" "$password" "$rank" "$whitelisted" "NO"
                    player_verification_status["$player_name"]="verified"
                elif verify_player_ip "$player_name" "$player_ip"; then
                    log_debug "IP matches for $player_name, marking as verified"
                    player_verification_status["$player_name"]="verified"
                else
                    log_debug "IP changed for $player_name: $first_ip -> $player_ip, requiring verification - NO SE APLICARÁ RANGO"
                    player_verification_status["$player_name"]="pending"
                    
                    if [ "$rank" != "NONE" ]; then
                        log_debug "Removing current rank $rank from $player_name until IP verification"
                        apply_rank_changes "$player_name" "$rank" "NONE"
                        pending_ranks["$player_name"]="$rank"
                    fi
                    
                    handle_ip_verification_required "$player_name" "$player_ip"
                fi
                
                if [ "$password" = "NONE" ]; then
                    log_debug "Existing player $player_name has no password, starting enforcement"
                    start_password_enforcement "$player_name"
                fi
                
                if [ "${player_verification_status[$player_name]}" = "verified" ]; then
                    log_debug "Starting rank application timer for verified player: $player_name"
                    start_rank_application_timer "$player_name"
                else
                    log_debug "Player $player_name not verified, NO se iniciará temporizador de rango"
                fi
            fi
            
            log_debug "Forcing list reload due to player connection: $player_name"
            sync_lists_from_players_log
            
        fi
        
        if [[ "$line" =~ Player\ Disconnected\ (.+) ]]; then
            local player_name="${BASH_REMATCH[1]}"
            player_name=$(echo "$player_name" | xargs)
            
            if is_valid_player_name "$player_name"; then
                log_debug "Player disconnected: $player_name"
                
                cancel_player_timers "$player_name"
                
                log_debug "Starting 15-second disconnect timer for: $player_name"
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
                log_debug "IMMEDIATE: Chat command detected from $player_name: $message"
                
                case "$message" in
                    "!psw "*)
                        log_debug "IMMEDIATE: Password set command detected from $player_name"
                        if [[ "$message" =~ !psw\ ([^[:space:]]+)\ ([^[:space:]]+)$ ]]; then
                            local password="${BASH_REMATCH[1]}"
                            local confirm_password="${BASH_REMATCH[2]}"
                            log_debug "IMMEDIATE: Processing password set for $player_name: $password"
                            handle_password_creation "$player_name" "$password" "$confirm_password"
                        else
                            execute_server_command "/clear"
                            send_server_command "$SCREEN_SESSION" "ERROR: $player_name, invalid format! Example of use: !psw Mypassword123 Mypassword123"
                        fi
                        ;;
                    "!change_psw "*)
                        log_debug "IMMEDIATE: Password change command detected from $player_name"
                        if [[ "$message" =~ !change_psw\ ([^[:space:]]+)\ ([^[:space:]]+)$ ]]; then
                            local old_password="${BASH_REMATCH[1]}"
                            local new_password="${BASH_REMATCH[2]}"
                            handle_password_change "$player_name" "$old_password" "$new_password"
                        else
                            execute_server_command "/clear"
                            send_server_command "$SCREEN_SESSION" "ERROR: $player_name, invalid format! Use: !change_psw YOUR_OLD_PSW YOUR_NEW_PSW"
                        fi
                        ;;
                    "!ip_change "*)
                        log_debug "IMMEDIATE: IP change command detected from $player_name"
                        if [[ "$message" =~ !ip_change\ (.+)$ ]]; then
                            local password="${BASH_REMATCH[1]}"
                            handle_ip_change "$player_name" "$password" "$current_ip"
                        else
                            execute_server_command "/clear"
                            send_server_command "$SCREEN_SESSION" "ERROR: $player_name, invalid format! Use: !ip_change YOUR_PASSWORD"
                        fi
                        ;;
                esac
            fi
        fi
        
        if [[ "$line" =~ cleared\ (.+)\ list ]]; then
            log_debug "Detected list clearance: $line"
            sleep 2
            log_debug "Force reloading all lists after clearance detected"
            force_reload_all_lists
        fi
        
    done
}

# =============================================================================
# FUNCIÓN PRINCIPAL Y CLEANUP
# =============================================================================

cleanup() {
    print_header "CLEANING UP RANK PATCHER"
    log_debug "=== CLEANUP STARTED ==="
    
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
    
    log_debug "=== CLEANUP COMPLETED ==="
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
