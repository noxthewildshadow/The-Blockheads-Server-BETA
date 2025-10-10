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
declare -A active_timers
declare -A current_player_ranks
declare -A pending_ranks
declare -A disconnect_timers
declare -A last_command_time
declare -A ip_verification_timers
declare -A temp_banned_players

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
    [[ "$name" =~ ^[a-zA-Z0-9_]{3,16}$ ]] && return 0
    return 1
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
    if screen -S "$SCREEN_SESSION" -p 0 -X stuff "$command$(printf \\r)" 2>/dev/null; then
        log_debug "Command sent successfully: $command"
        last_command_time["$SCREEN_SESSION"]=$(date +%s)
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
        return 0
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

start_ip_verification_process() {
    local player_name="$1" current_ip="$2"
    
    log_debug "Starting IP verification process for $player_name"
    
    # Esperar 5 segundos antes de mostrar la advertencia
    (
        sleep 5
        
        if [ -z "${connected_players[$player_name]}" ] || [ "${player_verification_status[$player_name]}" = "verified" ]; then
            log_debug "Player $player_name verified or disconnected, skipping IP verification warning"
            return
        fi
        
        log_debug "Sending IP verification warning to $player_name"
        execute_server_command "SECURITY ALERT: $player_name, your IP has changed!"
        sleep 1
        execute_server_command "Verify with !ip_change YOUR_PASSWORD within 25 seconds!"
        sleep 1
        execute_server_command "Else you'll get kicked and temporary IP ban for 30 seconds."
        
        # Iniciar temporizador de expiración (25 segundos)
        start_ip_verification_timeout "$player_name" "$current_ip"
        
    ) &
    
    ip_verification_timers["warning_$player_name"]=$!
}

start_ip_verification_timeout() {
    local player_name="$1" current_ip="$2"
    
    log_debug "Starting IP verification timeout for $player_name (25 seconds)"
    
    (
        sleep 25
        
        if [ -z "${connected_players[$player_name]}" ] || [ "${player_verification_status[$player_name]}" = "verified" ]; then
            log_debug "Player $player_name verified or disconnected, skipping IP verification timeout"
            return
        fi
        
        log_debug "IP verification timeout reached for $player_name, kicking and banning"
        
        # Marcar como baneado temporalmente
        temp_banned_players["$player_name"]=1
        
        # Limpiar listas inmediatamente
        cleanup_lists_for_unverified_player "$player_name"
        
        execute_server_command "/kick \"$player_name\""
        execute_server_command "/ban $current_ip"
        
        # Programar desbaneo automático
        (
            sleep 30
            execute_server_command "/unban $current_ip"
            unset temp_banned_players["$player_name"]
            log_debug "Auto-unbanned IP: $current_ip"
        ) &
        
    ) &
    
    ip_verification_timers["timeout_$player_name"]=$!
}

# =============================================================================
# GESTIÓN DE ARCHIVOS DE LISTAS
# =============================================================================

read_adminlist() {
    local world_dir="$BASE_SAVES_DIR/$WORLD_ID"
    local admin_list="$world_dir/adminlist.txt"
    
    [ ! -f "$admin_list" ] && echo "" && return
    cat "$admin_list" | grep -v -e '^$' -e '^CREATE_LIST$' | tr '\n' '|'
}

write_adminlist() {
    local world_dir="$BASE_SAVES_DIR/$WORLD_ID"
    local admin_list="$world_dir/adminlist.txt"
    local content="$1"
    
    if [ -z "$content" ]; then
        [ -f "$admin_list" ] && rm -f "$admin_list"
        log_debug "Removed adminlist.txt"
        return
    fi
    
    echo "$content" | tr '|' '\n' > "$admin_list"
    log_debug "Updated adminlist.txt: $content"
}

read_modlist() {
    local world_dir="$BASE_SAVES_DIR/$WORLD_ID"
    local mod_list="$world_dir/modlist.txt"
    
    [ ! -f "$mod_list" ] && echo "" && return
    cat "$mod_list" | grep -v -e '^$' -e '^CREATE_LIST$' | tr '\n' '|'
}

write_modlist() {
    local world_dir="$BASE_SAVES_DIR/$WORLD_ID"
    local mod_list="$world_dir/modlist.txt"
    local content="$1"
    
    if [ -z "$content" ]; then
        [ -f "$mod_list" ] && rm -f "$mod_list"
        log_debug "Removed modlist.txt"
        return
    fi
    
    echo "$content" | tr '|' '\n' > "$mod_list"
    log_debug "Updated modlist.txt: $content"
}

read_cloud_adminlist() {
    local cloud_file="$HOME_DIR/GNUstep/Library/ApplicationSupport/TheBlockheads/cloudWideOwnedAdminlist.txt"
    
    [ ! -f "$cloud_file" ] && echo "" && return
    cat "$cloud_file" | grep -v -e '^$' -e '^CREATE_LIST$' | tr '\n' '|'
}

write_cloud_adminlist() {
    local cloud_file="$HOME_DIR/GNUstep/Library/ApplicationSupport/TheBlockheads/cloudWideOwnedAdminlist.txt"
    local content="$1"
    
    if [ -z "$content" ]; then
        [ -f "$cloud_file" ] && rm -f "$cloud_file"
        log_debug "Removed cloud admin file"
        return
    fi
    
    echo "$content" | tr '|' '\n' > "$cloud_file"
    log_debug "Updated cloud admin file: $content"
}

# =============================================================================
# VERIFICACIÓN Y LIMPIEZA DE LISTAS
# =============================================================================

cleanup_lists_for_unverified_player() {
    local player_name="$1"
    
    log_debug "Cleaning up lists for unverified player: $player_name"
    
    local player_info=$(get_player_info "$player_name")
    [ -z "$player_info" ] && return
    
    local rank=$(echo "$player_info" | cut -d'|' -f3)
    [ "$rank" = "NONE" ] && return
    
    log_debug "Cleaning lists for $player_name (Rank: $rank)"
    
    case "$rank" in
        "MOD")
            cleanup_modlist_if_no_verified_players "$player_name"
            ;;
        "ADMIN")
            cleanup_adminlist_if_no_verified_players "$player_name"
            ;;
        "SUPER")
            cleanup_adminlist_if_no_verified_players "$player_name"
            cleanup_cloud_adminlist_if_no_verified_players "$player_name"
            ;;
    esac
}

cleanup_modlist_if_no_verified_players() {
    local unverified_player="$1"
    local world_dir="$BASE_SAVES_DIR/$WORLD_ID"
    local mod_list="$world_dir/modlist.txt"
    
    [ ! -f "$mod_list" ] && return
    
    local has_other_verified_mod=0
    for player in "${!connected_players[@]}"; do
        [ "$player" = "$unverified_player" ] && continue
        [ "${player_verification_status[$player]}" != "verified" ] && continue
        
        local player_info=$(get_player_info "$player")
        [ -z "$player_info" ] && continue
        
        local player_rank=$(echo "$player_info" | cut -d'|' -f3)
        if [ "$player_rank" = "MOD" ]; then
            has_other_verified_mod=1
            log_debug "Found other verified MOD: $player - keeping modlist.txt"
            break
        fi
    done
    
    if [ $has_other_verified_mod -eq 0 ]; then
        rm -f "$mod_list"
        log_debug "Removed modlist.txt (no verified MODs connected)"
    fi
}

cleanup_adminlist_if_no_verified_players() {
    local unverified_player="$1"
    local world_dir="$BASE_SAVES_DIR/$WORLD_ID"
    local admin_list="$world_dir/adminlist.txt"
    
    [ ! -f "$admin_list" ] && return
    
    local has_other_verified_admin=0
    for player in "${!connected_players[@]}"; do
        [ "$player" = "$unverified_player" ] && continue
        [ "${player_verification_status[$player]}" != "verified" ] && continue
        
        local player_info=$(get_player_info "$player")
        [ -z "$player_info" ] && continue
        
        local player_rank=$(echo "$player_info" | cut -d'|' -f3)
        if [ "$player_rank" = "ADMIN" ] || [ "$player_rank" = "SUPER" ]; then
            has_other_verified_admin=1
            log_debug "Found other verified ADMIN/SUPER: $player - keeping adminlist.txt"
            break
        fi
    done
    
    if [ $has_other_verified_admin -eq 0 ]; then
        rm -f "$admin_list"
        log_debug "Removed adminlist.txt (no verified ADMINS connected)"
    fi
}

cleanup_cloud_adminlist_if_no_verified_players() {
    local unverified_player="$1"
    local cloud_file="$HOME_DIR/GNUstep/Library/ApplicationSupport/TheBlockheads/cloudWideOwnedAdminlist.txt"
    
    [ ! -f "$cloud_file" ] && return
    
    local has_other_verified_super=0
    for player in "${!connected_players[@]}"; do
        [ "$player" = "$unverified_player" ] && continue
        [ "${player_verification_status[$player]}" != "verified" ] && continue
        
        local player_info=$(get_player_info "$player")
        [ -z "$player_info" ] && continue
        
        local player_rank=$(echo "$player_info" | cut -d'|' -f3)
        if [ "$player_rank" = "SUPER" ]; then
            has_other_verified_super=1
            log_debug "Found other verified SUPER: $player - keeping cloud admin file"
            break
        fi
    done
    
    if [ $has_other_verified_super -eq 0 ]; then
        rm -f "$cloud_file"
        log_debug "Removed cloud admin file (no verified SUPERs connected)"
    fi
}

# =============================================================================
# GESTIÓN DE RANGOS Y LISTAS PARA JUGADORES VERIFICADOS
# =============================================================================

create_list_if_needed() {
    local rank="$1"
    local world_dir="$BASE_SAVES_DIR/$WORLD_ID"
    
    log_debug "Checking list creation for rank: $rank"
    
    # Verificar si hay al menos un jugador VERIFICADO con este rango
    local has_verified_player_with_rank=0
    for player in "${!connected_players[@]}"; do
        [ "${player_verification_status[$player]}" != "verified" ] && continue
        
        local player_info=$(get_player_info "$player")
        [ -z "$player_info" ] && continue
        
        local player_rank=$(echo "$player_info" | cut -d'|' -f3)
        [ "$player_rank" = "$rank" ] && has_verified_player_with_rank=1 && break
    done
    
    [ $has_verified_player_with_rank -eq 0 ] && return
    
    case "$rank" in
        "MOD")
            local mod_list="$world_dir/modlist.txt"
            [ ! -f "$mod_list" ] && create_mod_list
            ;;
        "ADMIN"|"SUPER")
            local admin_list="$world_dir/adminlist.txt"
            [ ! -f "$admin_list" ] && create_admin_list "$rank"
            ;;
    esac
}

create_mod_list() {
    log_debug "Creating modlist.txt"
    execute_server_command "/mod CREATE_LIST"
    (
        sleep 2
        execute_server_command "/unmod CREATE_LIST"
        log_debug "Removed CREATE_LIST from modlist"
    ) &
}

create_admin_list() {
    local rank="$1"
    log_debug "Creating adminlist.txt"
    execute_server_command "/admin CREATE_LIST"
    [ "$rank" = "SUPER" ] && add_to_cloud_admin "CREATE_LIST"
    (
        sleep 2
        execute_server_command "/unadmin CREATE_LIST"
        [ "$rank" = "SUPER" ] && remove_from_cloud_admin "CREATE_LIST"
        log_debug "Removed CREATE_LIST from adminlist"
    ) &
}

apply_rank_to_verified_player() {
    local player_name="$1"
    
    [ -z "${connected_players[$player_name]}" ] && return
    [ "${player_verification_status[$player_name]}" != "verified" ] && return
    [ -n "${temp_banned_players[$player_name]}" ] && return
    
    local player_info=$(get_player_info "$player_name")
    [ -z "$player_info" ] && return
    
    local password=$(echo "$player_info" | cut -d'|' -f2)
    local rank=$(echo "$player_info" | cut -d'|' -f3)
    local whitelisted=$(echo "$player_info" | cut -d'|' -f4)
    local blacklisted=$(echo "$player_info" | cut -d'|' -f5)
    local current_ip="${player_ip_map[$player_name]}"
    
    [ "$password" = "NONE" ] && return
    [ "$rank" = "NONE" ] && return
    
    log_debug "Applying rank to verified player: $player_name (Rank: $rank)"
    
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
    
    [ "$whitelisted" = "YES" ] && [ -n "$current_ip" ] && [ "$current_ip" != "UNKNOWN" ] && execute_server_command "/whitelist $current_ip"
    [ "$blacklisted" = "YES" ] && execute_server_command "/ban $player_name"
}

# =============================================================================
# GESTIÓN DE LISTAS CLOUD
# =============================================================================

add_to_cloud_admin() {
    local player_name="$1"
    local current_cloud_list=$(read_cloud_adminlist)
    
    [[ "$current_cloud_list" == *"$player_name"* ]] && return
    
    if [ -z "$current_cloud_list" ]; then
        current_cloud_list="$player_name"
    else
        current_cloud_list="${current_cloud_list}|$player_name"
    fi
    
    write_cloud_adminlist "$current_cloud_list"
    log_debug "Added $player_name to cloud admin list"
}

remove_from_cloud_admin() {
    local player_name="$1"
    local current_cloud_list=$(read_cloud_adminlist)
    
    [[ "$current_cloud_list" != *"$player_name"* ]] && return
    
    local new_list=""
    IFS='|' read -ra players <<< "$current_cloud_list"
    for player in "${players[@]}"; do
        [ "$player" != "$player_name" ] && new_list="${new_list}|$player"
    done
    
    new_list="${new_list#|}"
    write_cloud_adminlist "$new_list"
    log_debug "Removed $player_name from cloud admin list"
}

# =============================================================================
# TEMPORIZADORES Y PROGRAMACIÓN
# =============================================================================

start_rank_application_timer() {
    local player_name="$1"
    
    log_debug "Starting rank application timer for: $player_name (Status: ${player_verification_status[$player_name]})"
    
    [ -z "${connected_players[$player_name]}" ] && return
    [ "${player_verification_status[$player_name]}" != "verified" ] && return
    [ -n "${temp_banned_players[$player_name]}" ] && return
    
    local player_info=$(get_player_info "$player_name")
    [ -z "$player_info" ] && return
    
    local rank=$(echo "$player_info" | cut -d'|' -f3)
    [ "$rank" = "NONE" ] && return
    
    log_debug "Scheduling rank application for $player_name in 5 seconds"
    
    (
        sleep 5
        
        [ -z "${connected_players[$player_name]}" ] && return
        [ "${player_verification_status[$player_name]}" != "verified" ] && return
        [ -n "${temp_banned_players[$player_name]}" ] && return
        
        log_debug "Applying rank to verified player: $player_name"
        create_list_if_needed "$rank"
        apply_rank_to_verified_player "$player_name"
    ) &
    
    active_timers["rank_application_$player_name"]=$!
}

start_disconnect_timer() {
    local player_name="$1"
    
    log_debug "Starting disconnect timer for: $player_name"
    
    (
        sleep 10
        log_debug "Removing rank for disconnected player: $player_name"
        remove_player_rank "$player_name"
        
        sleep 5
        log_debug "Cleaning up lists for: $player_name"
        cleanup_lists_after_disconnect "$player_name"
        
        unset disconnect_timers["$player_name"]
    ) &
    
    disconnect_timers["$player_name"]=$!
}

cleanup_lists_after_disconnect() {
    local disconnected_player="$1"
    local has_admin_connected=0 has_mod_connected=0 has_super_connected=0
    
    for player in "${!connected_players[@]}"; do
        [ "$player" = "$disconnected_player" ] && continue
        [ "${player_verification_status[$player]}" != "verified" ] && continue
        
        local player_info=$(get_player_info "$player")
        [ -z "$player_info" ] && continue
        
        local rank=$(echo "$player_info" | cut -d'|' -f3)
        case "$rank" in
            "ADMIN") has_admin_connected=1 ;;
            "MOD") has_mod_connected=1 ;;
            "SUPER") has_admin_connected=1; has_super_connected=1 ;;
        esac
    done
    
    [ $has_admin_connected -eq 0 ] && cleanup_adminlist_if_no_verified_players "$disconnected_player"
    [ $has_mod_connected -eq 0 ] && cleanup_modlist_if_no_verified_players "$disconnected_player"
    [ $has_super_connected -eq 0 ] && cleanup_cloud_adminlist_if_no_verified_players "$disconnected_player"
}

# =============================================================================
# CANCELACIÓN DE TEMPORIZADORES
# =============================================================================

cancel_all_player_timers() {
    local player_name="$1"
    
    log_debug "Cancelling all timers for player: $player_name"
    
    # Cancelar temporizadores activos
    for timer_key in "${!active_timers[@]}"; do
        [[ "$timer_key" == *"$player_name"* ]] && kill_timer "${active_timers[$timer_key]}" "$timer_key" active_timers
    done
    
    # Cancelar temporizadores de verificación de IP
    for timer_key in "${!ip_verification_timers[@]}"; do
        [[ "$timer_key" == *"$player_name"* ]] && kill_timer "${ip_verification_timers[$timer_key]}" "$timer_key" ip_verification_timers
    done
    
    # Cancelar temporizador de desconexión
    kill_timer "${disconnect_timers[$player_name]}" "$player_name" disconnect_timers
}

kill_timer() {
    local pid="$1" key="$2" array_name="$3"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null
        log_debug "Cancelled timer $key (PID: $pid)"
    fi
    unset ${array_name}["$key"]
}

# =============================================================================
# GESTIÓN DE CONTRASEÑAS
# =============================================================================

start_password_enforcement() {
    local player_name="$1"
    
    log_debug "Starting password enforcement for $player_name"
    
    # Recordatorio a los 5 segundos
    (
        sleep 5
        [ -z "${connected_players[$player_name]}" ] && return
        
        local player_info=$(get_player_info "$player_name")
        [ -z "$player_info" ] && return
        
        local password=$(echo "$player_info" | cut -d'|' -f2)
        [ "$password" != "NONE" ] && return
        
        execute_server_command "SECURITY: $player_name, set your password within 60 seconds!"
        sleep 1
        execute_server_command "Example: !psw Mypassword123 Mypassword123"
    ) &
    active_timers["password_reminder_$player_name"]=$!
    
    # Kick a los 60 segundos
    (
        sleep 60
        [ -z "${connected_players[$player_name]}" ] && return
        
        local player_info=$(get_player_info "$player_name")
        [ -z "$player_info" ] && return
        
        local password=$(echo "$player_info" | cut -d'|' -f2)
        [ "$password" != "NONE" ] && return
        
        execute_server_command "/kick $player_name"
        log_debug "Kicked $player_name for not setting password"
    ) &
    active_timers["password_kick_$player_name"]=$!
}

handle_password_creation() {
    local player_name="$1" password="$2" confirm_password="$3"
    
    log_debug "Password creation requested for $player_name"
    
    execute_server_command "/clear"
    
    if [ ${#password} -lt 7 ] || [ ${#password} -gt 16 ]; then
        execute_server_command "ERROR: $player_name, password must be 7-16 characters."
        return 1
    fi
    
    if [ "$password" != "$confirm_password" ]; then
        execute_server_command "ERROR: $player_name, passwords do not match."
        return 1
    fi
    
    local player_info=$(get_player_info "$player_name")
    if [ -n "$player_info" ]; then
        local first_ip=$(echo "$player_info" | cut -d'|' -f1)
        local current_password=$(echo "$player_info" | cut -d'|' -f2)
        local rank=$(echo "$player_info" | cut -d'|' -f3)
        local whitelisted=$(echo "$player_info" | cut -d'|' -f4)
        local blacklisted=$(echo "$player_info" | cut -d'|' -f5)
        
        cancel_all_player_timers "$player_name"
        update_player_info "$player_name" "$first_ip" "$password" "$rank" "$whitelisted" "$blacklisted"
        execute_server_command "SUCCESS: $player_name, password set successfully."
        return 0
    else
        execute_server_command "ERROR: $player_name, player not found in registry."
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
            execute_server_command "ERROR: $player_name, password is incorrect."
            return 1
        fi
        
        update_player_info "$player_name" "$current_ip" "$current_password" "$rank" "$whitelisted" "$blacklisted"
        player_verification_status["$player_name"]="verified"
        
        cancel_all_player_timers "$player_name"
        execute_server_command "SECURITY: $player_name IP verification successful."
        
        # Aplicar rangos pendientes
        apply_pending_ranks "$player_name"
        start_rank_application_timer "$player_name"
        
        execute_server_command "SUCCESS: $player_name, your IP has been verified and updated."
        return 0
    else
        execute_server_command "ERROR: $player_name, player not found in registry."
        return 1
    fi
}

# =============================================================================
# GESTIÓN DE RANGOS PENDIENTES
# =============================================================================

apply_pending_ranks() {
    local player_name="$1"
    
    if [ -n "${pending_ranks[$player_name]}" ]; then
        local pending_rank="${pending_ranks[$player_name]}"
        log_debug "Applying pending rank for $player_name: $pending_rank"
        
        [ "${player_verification_status[$player_name]}" != "verified" ] && return
        
        case "$pending_rank" in
            "ADMIN") execute_server_command "/admin $player_name" ;;
            "MOD") execute_server_command "/mod $player_name" ;;
            "SUPER")
                add_to_cloud_admin "$player_name"
                execute_server_command "/admin $player_name"
                ;;
        esac
        
        current_player_ranks["$player_name"]="$pending_rank"
        unset pending_ranks["$player_name"]
        log_debug "Applied pending rank $pending_rank to $player_name"
    fi
}

remove_player_rank() {
    local player_name="$1"
    
    log_debug "Removing rank for disconnected player: $player_name"
    
    local player_info=$(get_player_info "$player_name")
    [ -z "$player_info" ] && return
    
    local rank=$(echo "$player_info" | cut -d'|' -f3)
    
    case "$rank" in
        "MOD") execute_server_command "/unmod $player_name" ;;
        "ADMIN") execute_server_command "/unadmin $player_name" ;;
        "SUPER")
            execute_server_command "/unadmin $player_name"
            remove_from_cloud_admin "$player_name"
            ;;
    esac
    
    log_debug "Removed rank $rank from $player_name"
}

# =============================================================================
# GESTIÓN DE NOMBRES INVÁLIDOS
# =============================================================================

handle_invalid_player_name() {
    local player_name="$1" player_ip="$2"
    
    print_error "INVALID PLAYER NAME: '$player_name' (IP: $player_ip)"
    
    local safe_name=$(sanitize_name_for_command "$player_name")
    
    (
        sleep 3
        execute_server_command "WARNING: Invalid player name '$player_name'!"
        sleep 1
        execute_server_command "Kicking and IP banning for 60 seconds..."
        sleep 3

        if [ -n "$player_ip" ] && [ "$player_ip" != "unknown" ]; then
            execute_server_command "/ban $player_ip"
            execute_server_command "/kick \"$safe_name\""
            print_warning "Banned invalid name: '$player_name' (IP: $player_ip)"
            
            (
                sleep 60
                execute_server_command "/unban $player_ip"
                print_success "Unbanned IP: $player_ip"
            ) &
        else
            execute_server_command "/ban \"$safe_name\""
            execute_server_command "/kick \"$safe_name\""
            print_warning "Banned invalid name: '$player_name'"
        fi
    ) &
}

# =============================================================================
# MONITOR PRINCIPAL
# =============================================================================

monitor_console_log() {
    print_header "STARTING CONSOLE LOG MONITOR"
    
    local wait_time=0
    while [ ! -f "$CONSOLE_LOG" ] && [ $wait_time -lt 30 ]; do
        sleep 1
        ((wait_time++))
    done
    
    [ ! -f "$CONSOLE_LOG" ] && log_debug "Console log not found" && return 1
    
    log_debug "Console log found, starting monitoring"
    
    tail -n 0 -F "$CONSOLE_LOG" | while read -r line; do
        # Player Connected
        if [[ "$line" =~ Player\ Connected\ (.+)\ \|\ ([0-9a-fA-F.:]+)\ \|\ ([0-9a-f]+) ]]; then
            handle_player_connect "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
        
        # Player Disconnected
        elif [[ "$line" =~ Player\ Disconnected\ (.+) ]]; then
            handle_player_disconnect "${BASH_REMATCH[1]}"
        
        # Chat Commands
        elif [[ "$line" =~ ([a-zA-Z0-9_]+):\ (.+)$ ]]; then
            handle_chat_command "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
        fi
    done
}

handle_player_connect() {
    local player_name="$1" player_ip="$2" player_hash="$3"
    
    player_name=$(extract_real_name "$player_name")
    player_name=$(echo "$player_name" | xargs)
    
    if ! is_valid_player_name "$player_name"; then
        handle_invalid_player_name "$player_name" "$player_ip"
        return
    fi
    
    cancel_all_player_timers "$player_name"
    
    connected_players["$player_name"]=1
    player_ip_map["$player_name"]="$player_ip"
    
    log_debug "Player connected: $player_name ($player_ip)"
    
    local player_info=$(get_player_info "$player_name")
    if [ -z "$player_info" ]; then
        # Nuevo jugador
        log_debug "New player: $player_name"
        update_player_info "$player_name" "$player_ip" "NONE" "NONE" "NO" "NO"
        player_verification_status["$player_name"]="verified"
        start_password_enforcement "$player_name"
    else
        # Jugador existente
        local first_ip=$(echo "$player_info" | cut -d'|' -f1)
        local password=$(echo "$player_info" | cut -d'|' -f2)
        local rank=$(echo "$player_info" | cut -d'|' -f3)
        
        log_debug "Existing player: $player_name (IP: $first_ip -> $player_ip, Rank: $rank)"
        
        if [ "$first_ip" = "UNKNOWN" ]; then
            log_debug "First real connection, updating IP"
            update_player_info "$player_name" "$player_ip" "$password" "$rank" "NO" "NO"
            player_verification_status["$player_name"]="verified"
        elif verify_player_ip "$player_name" "$player_ip"; then
            log_debug "IP verified"
            player_verification_status["$player_name"]="verified"
        else
            log_debug "IP not verified, requiring verification"
            player_verification_status["$player_name"]="pending"
            
            if [ "$rank" != "NONE" ]; then
                pending_ranks["$player_name"]="$rank"
                # Limpiar listas después de 1 segundo si no hay otros jugadores verificados
                (
                    sleep 1
                    [ -n "${connected_players[$player_name]}" ] && [ "${player_verification_status[$player_name]}" = "pending" ] && \
                    cleanup_lists_for_unverified_player "$player_name"
                ) &
            fi
            
            start_ip_verification_process "$player_name" "$player_ip"
        fi
        
        [ "$password" = "NONE" ] && start_password_enforcement "$player_name"
        [ "${player_verification_status[$player_name]}" = "verified" ] && start_rank_application_timer "$player_name"
    fi
}

handle_player_disconnect() {
    local player_name="$1"
    player_name=$(echo "$player_name" | xargs)
    
    if is_valid_player_name "$player_name" && [ -z "${temp_banned_players[$player_name]}" ]; then
        log_debug "Player disconnected: $player_name"
        
        cancel_all_player_timers "$player_name"
        start_disconnect_timer "$player_name"
        
        unset connected_players["$player_name"]
        unset player_ip_map["$player_name"]
        unset player_verification_status["$player_name"]
        unset pending_ranks["$player_name"]
    elif [ -n "${temp_banned_players[$player_name]}" ]; then
        log_debug "Temp banned player disconnected: $player_name"
        unset connected_players["$player_name"]
        unset player_ip_map["$player_name"]
        unset player_verification_status["$player_name"]
        unset pending_ranks["$player_name"]
    fi
}

handle_chat_command() {
    local player_name="$1" message="$2"
    local current_ip="${player_ip_map[$player_name]}"
    
    player_name=$(echo "$player_name" | xargs)
    
    is_valid_player_name "$player_name" || return
    
    log_debug "Chat command from $player_name: $message"
    
    case "$message" in
        "!psw "*)
            if [[ "$message" =~ !psw\ ([^[:space:]]+)\ ([^[:space:]]+)$ ]]; then
                handle_password_creation "$player_name" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
            else
                execute_server_command "/clear"
                execute_server_command "ERROR: $player_name, use: !psw Mypassword123 Mypassword123"
            fi
            ;;
        "!ip_change "*)
            if [[ "$message" =~ !ip_change\ (.+)$ ]]; then
                handle_ip_change "$player_name" "${BASH_REMATCH[1]}" "$current_ip"
            else
                execute_server_command "/clear"
                execute_server_command "ERROR: $player_name, use: !ip_change YOUR_PASSWORD"
            fi
            ;;
    esac
}

# =============================================================================
# FUNCIÓN PRINCIPAL Y CLEANUP
# =============================================================================

cleanup() {
    print_header "CLEANING UP RANK PATCHER"
    log_debug "=== CLEANUP STARTED ==="
    
    jobs -p | xargs kill -9 2>/dev/null
    
    for array_name in active_timers disconnect_timers ip_verification_timers; do
        declare -n arr=$array_name
        for pid in "${arr[@]}"; do
            kill "$pid" 2>/dev/null
        done
    done
    
    log_debug "=== CLEANUP COMPLETED ==="
    print_success "Cleanup completed"
    exit 0
}

main() {
    [ $# -lt 1 ] && print_error "Usage: $0 <port>" && exit 1
    
    PORT="$1"
    
    print_header "THE BLOCKHEADS RANK PATCHER"
    print_status "Starting rank patcher for port: $PORT"
    
    trap cleanup EXIT INT TERM
    
    setup_paths "$PORT" || exit 1
    
    if ! screen_session_exists "$SCREEN_SESSION"; then
        print_error "Server screen session not found: $SCREEN_SESSION"
        exit 1
    fi
    
    monitor_console_log
    
    wait
}

main "$@"
