#!/bin/bash

# =============================================================================
# CONFIGURACIÓN Y CONSTANTES
# =============================================================================

# Colores para output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly MAGENTA='\033[0;35m'
readonly NC='\033[0m'

# Directorios base
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly HOME_DIR="$HOME"
readonly BASE_SAVES_DIR="$HOME_DIR/GNUstep/Library/ApplicationSupport/TheBlockheads/saves"

# Variables globales
PLAYERS_LOG=""
CONSOLE_LOG=""
PATCH_DEBUG_LOG=""
SCREEN_SESSION=""
WORLD_ID=""
PORT=""

# Arrays para gestión de estado
declare -A connected_players
declare -A player_ip_map
declare -A player_verification_status
declare -A active_timers
declare -A current_player_ranks
declare -A current_blacklisted_players
declare -A current_whitelisted_players
declare -A super_admin_disconnect_timers
declare -A pending_ranks
declare -A list_files_initialized
declare -A disconnect_timers
declare -A last_command_time

# Configuración
DEBUG_LOG_ENABLED=1

# =============================================================================
# FUNCIONES DE LOGGING Y OUTPUT
# =============================================================================

print_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
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

# =============================================================================
# FUNCIONES DE VALIDACIÓN Y SEGURIDAD
# =============================================================================

is_valid_player_name() {
    local name="$1"
    
    # Validaciones básicas
    [[ -z "$name" || "$name" =~ ^[[:space:]]+$ ]] && return 1
    [[ ${#name} -lt 3 || ${#name} -gt 16 ]] && return 1
    [[ "$name" =~ [[:space:]] ]] && return 1
    [[ "$name" =~ [\\\/\|\<\>\:\"\?\*] ]] && return 1
    
    # Solo caracteres alfanuméricos y underscore
    [[ ! "$name" =~ ^[a-zA-Z0-9_]+$ ]] && return 1
    
    return 0
}

extract_real_name() {
    local name="$1"
    [[ "$name" =~ ^[0-9]+\]\ (.+)$ ]] && echo "${BASH_REMATCH[1]}" || echo "$name"
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
        execute_server_command "WARNING: Invalid player name '$player_name'! Names must be 3-16 alphanumeric characters, no spaces/symbols!"
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
}

# =============================================================================
# CONFIGURACIÓN DE RUTAS Y ENTORNO
# =============================================================================

setup_paths() {
    local port="$1"
    
    # Determinar WORLD_ID
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
    
    # Configurar rutas de archivos
    PLAYERS_LOG="$BASE_SAVES_DIR/$WORLD_ID/players.log"
    CONSOLE_LOG="$BASE_SAVES_DIR/$WORLD_ID/console.log"
    PATCH_DEBUG_LOG="$BASE_SAVES_DIR/$WORLD_ID/patch_debug.log"
    SCREEN_SESSION="blockheads_server_$port"
    
    # Crear archivos si no existen
    [ ! -f "$PLAYERS_LOG" ] && touch "$PLAYERS_LOG"
    [ ! -f "$PATCH_DEBUG_LOG" ] && touch "$PATCH_DEBUG_LOG"
    
    # Log inicial
    log_debug "=== RANK PATCHER STARTED ==="
    log_debug "World ID: $WORLD_ID | Port: $port"
    log_debug "Players log: $PLAYERS_LOG | Console log: $CONSOLE_LOG"
    log_debug "Screen session: $SCREEN_SESSION"
    
    print_status "Monitoring session: $SCREEN_SESSION"
}

# =============================================================================
# COMUNICACIÓN CON EL SERVIDOR
# =============================================================================

screen_session_exists() {
    screen -list | grep -q "$1"
}

send_server_command() {
    local screen_session="$1"
    local command="$2"
    
    log_debug "Sending command to $screen_session: $command"
    if screen -S "$screen_session" -p 0 -X stuff "$command$(printf \\r)" 2>/dev/null; then
        log_debug "Command sent successfully"
        return 0
    else
        log_debug "FAILED to send command"
        return 1
    fi
}

execute_server_command() {
    local command="$1"
    local current_time=$(date +%s)
    local last_time=${last_command_time["$SCREEN_SESSION"]:-0}
    local time_diff=$((current_time - last_time))
    
    # Rate limiting: mínimo 1 segundo entre comandos
    [ $time_diff -lt 1 ] && sleep $((1 - time_diff))
    
    log_debug "Executing server command: $command"
    send_server_command "$SCREEN_SESSION" "$command"
    last_command_time["$SCREEN_SESSION"]=$(date +%s)
}

# =============================================================================
# GESTIÓN DE DATOS DE JUGADORES
# =============================================================================

get_player_info() {
    local player_name="$1"
    [ ! -f "$PLAYERS_LOG" ] && return
    
    while IFS='|' read -r name first_ip password rank whitelisted blacklisted; do
        name=$(echo "$name" | xargs)
        [ "$name" = "$player_name" ] && echo "$first_ip|$password|$rank|$whitelisted|$blacklisted" && return 0
    done < <(grep -i "^$player_name|" "$PLAYERS_LOG")
    
    echo ""
}

update_player_info() {
    local player_name="$1" first_ip="$2" password="$3" rank="$4" whitelisted="${5:-NO}" blacklisted="${6:-NO}"
    
    # Normalizar valores
    player_name=$(echo "$player_name" | tr '[:lower:]' '[:upper:]')
    first_ip=$(echo "$first_ip" | tr '[:lower:]' '[:upper:]')
    rank=$(echo "$rank" | tr '[:lower:]' '[:upper:]')
    whitelisted=$(echo "$whitelisted" | tr '[:lower:]' '[:upper:]')
    blacklisted=$(echo "$blacklisted" | tr '[:lower:]' '[:upper:]')
    
    # Valores por defecto
    [ -z "$first_ip" ] && first_ip="UNKNOWN"
    [ -z "$password" ] && password="NONE"
    [ -z "$rank" ] && rank="NONE"
    [ -z "$whitelisted" ] && whitelisted="NO"
    [ -z "$blacklisted" ] && blacklisted="NO"
    
    # Actualizar archivo
    if [ -f "$PLAYERS_LOG" ]; then
        sed -i "/^$player_name|/Id" "$PLAYERS_LOG"
        echo "$player_name|$first_ip|$password|$rank|$whitelisted|$blacklisted" >> "$PLAYERS_LOG"
        log_debug "Updated player: $player_name | $first_ip | $password | $rank | $whitelisted | $blacklisted"
    fi
}

# =============================================================================
# GESTIÓN DE RANGOS Y LISTAS
# =============================================================================

create_list_if_needed() {
    local rank="$1"
    local world_dir="$BASE_SAVES_DIR/$WORLD_ID"
    
    log_debug "Creating list for rank: $rank"
    
    # Verificar si hay jugadores verificados con este rango
    local has_verified_player=0
    for player in "${!connected_players[@]}"; do
        if [ "${player_verification_status[$player]}" = "verified" ]; then
            local player_info=$(get_player_info "$player")
            [ -n "$player_info" ] && [ "$(echo "$player_info" | cut -d'|' -f3)" = "$rank" ] && has_verified_player=1 && break
        fi
    done
    
    [ $has_verified_player -eq 0 ] && log_debug "No verified players with rank $rank connected" && return
    
    case "$rank" in
        "MOD")
            local mod_list="$world_dir/modlist.txt"
            [ ! -f "$mod_list" ] && execute_server_command "/mod CREATE_LIST" && (
                sleep 2
                execute_server_command "/unmod CREATE_LIST"
                log_debug "Created and cleaned modlist"
            ) &
            ;;
        "ADMIN"|"SUPER")
            local admin_list="$world_dir/adminlist.txt"
            [ ! -f "$admin_list" ] && execute_server_command "/admin CREATE_LIST" && (
                sleep 2
                execute_server_command "/unadmin CREATE_LIST"
                log_debug "Created and cleaned adminlist"
            ) &
            ;;
    esac
}

apply_rank_to_connected_player() {
    local player_name="$1"
    
    [ -z "${connected_players[$player_name]}" ] && log_debug "Player $player_name not connected" && return
    [ "${player_verification_status[$player_name]}" != "verified" ] && log_debug "Player $player_name not verified" && return
    
    local player_info=$(get_player_info "$player_name")
    [ -z "$player_info" ] && log_debug "No player info for $player_name" && return
    
    local first_ip=$(echo "$player_info" | cut -d'|' -f1)
    local password=$(echo "$player_info" | cut -d'|' -f2)
    local rank=$(echo "$player_info" | cut -d'|' -f3)
    local whitelisted=$(echo "$player_info" | cut -d'|' -f4)
    local blacklisted=$(echo "$player_info" | cut -d'|' -f5)
    local current_ip="${player_ip_map[$player_name]}"
    
    [ "$password" = "NONE" ] && log_debug "Player $player_name has no password" && return
    
    log_debug "Applying rank $rank to $player_name"
    
    case "$rank" in
        "MOD") execute_server_command "/mod $player_name" ;;
        "ADMIN") execute_server_command "/admin $player_name" ;;
        "SUPER")
            execute_server_command "/admin $player_name"
            add_to_cloud_admin "$player_name"
            ;;
    esac
    
    current_player_ranks["$player_name"]="$rank"
    
    # Gestión de whitelist/blacklist
    [ "$whitelisted" = "YES" ] && [ -n "$current_ip" ] && [ "$current_ip" != "UNKNOWN" ] && execute_server_command "/whitelist $current_ip"
    [ "$blacklisted" = "YES" ] && execute_server_command "/ban $player_name" && [ -n "$current_ip" ] && [ "$current_ip" != "UNKNOWN" ] && execute_server_command "/ban $current_ip"
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
            start_super_disconnect_timer "$player_name"
            ;;
    esac
    
    log_debug "Removed rank $rank from $player_name"
}

# =============================================================================
# GESTIÓN DE CLOUD ADMIN
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
    
    [ ! -f "$cloud_file" ] && return
    
    local temp_file=$(mktemp)
    grep -v "^$player_name$" "$cloud_file" > "$temp_file"
    
    if [ -s "$temp_file" ]; then
        mv "$temp_file" "$cloud_file"
        log_debug "Removed $player_name from cloud admin list"
    else
        rm -f "$cloud_file" "$temp_file"
        log_debug "Removed empty cloud admin file"
    fi
}

remove_cloud_admin_file_if_empty() {
    local cloud_file="$HOME_DIR/GNUstep/Library/ApplicationSupport/TheBlockheads/cloudWideOwnedAdminlist.txt"
    
    [ ! -f "$cloud_file" ] && return
    
    local valid_lines=$(grep -v -e '^$' -e '^CREATE_LIST$' "$cloud_file" | wc -l)
    
    if [ $valid_lines -eq 0 ]; then
        rm -f "$cloud_file"
        log_debug "Removed cloud admin file (empty)"
    else
        log_debug "Cloud admin file has $valid_lines valid entries"
    fi
}

# =============================================================================
# TEMPORIZADORES Y GESTIÓN DE TIEMPO
# =============================================================================

start_rank_application_timer() {
    local player_name="$1"
    
    log_debug "Starting rank application timer for: $player_name"
    
    [ -z "${connected_players[$player_name]}" ] && log_debug "Player $player_name not connected" && return
    [ "${player_verification_status[$player_name]}" != "verified" ] && log_debug "Player $player_name not verified" && return
    
    local player_info=$(get_player_info "$player_name")
    [ -z "$player_info" ] && return
    
    local rank=$(echo "$player_info" | cut -d'|' -f3)
    [ "$rank" = "NONE" ] && log_debug "Player $player_name has no rank" && return
    
    create_list_if_needed "$rank"
    
    (
        sleep 5
        if [ -n "${connected_players[$player_name]}" ] && [ "${player_verification_status[$player_name]}" = "verified" ]; then
            log_debug "Applying rank to verified player: $player_name"
            apply_rank_to_connected_player "$player_name"
        else
            log_debug "Player $player_name not verified or disconnected"
        fi
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
        cleanup_empty_lists_after_disconnect "$player_name"
        
        unset disconnect_timers["$player_name"]
    ) &
    
    disconnect_timers["$player_name"]=$!
}

start_super_disconnect_timer() {
    local player_name="$1"
    
    log_debug "Starting SUPER disconnect timer for: $player_name"
    
    (
        sleep 10
        
        local has_other_super_admins=0
        for connected_player in "${!connected_players[@]}"; do
            [ "$connected_player" = "$player_name" ] && continue
            [ "${player_verification_status[$connected_player]}" != "verified" ] && continue
            
            local player_info=$(get_player_info "$connected_player")
            [ -n "$player_info" ] && [ "$(echo "$player_info" | cut -d'|' -f3)" = "SUPER" ] && has_other_super_admins=1 && break
        done
        
        [ $has_other_super_admins -eq 0 ] && remove_cloud_admin_file_if_empty
        
        unset super_admin_disconnect_timers["$player_name"]
    ) &
    
    super_admin_disconnect_timers["$player_name"]=$!
}

cancel_timer() {
    local timer_array="$1"
    local player_name="$2"
    
    eval "local pid=\"\${${timer_array}[\$player_name]}\""
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && kill "$pid" 2>/dev/null && log_debug "Cancelled timer for $player_name"
    eval "unset ${timer_array}[\$player_name]"
}

cancel_player_timers() {
    local player_name="$1"
    
    log_debug "Cancelling all timers for: $player_name"
    
    # Cancelar todos los tipos de temporizadores
    cancel_timer "active_timers" "password_reminder_$player_name"
    cancel_timer "active_timers" "password_kick_$player_name"
    cancel_timer "active_timers" "ip_grace_$player_name"
    cancel_timer "active_timers" "rank_application_$player_name"
    cancel_timer "disconnect_timers" "$player_name"
    cancel_timer "super_admin_disconnect_timers" "$player_name"
}

# =============================================================================
# GESTIÓN DE LISTAS Y SINCRONIZACIÓN
# =============================================================================

cleanup_empty_lists_after_disconnect() {
    local disconnected_player="$1"
    local world_dir="$BASE_SAVES_DIR/$WORLD_ID"
    local admin_list="$world_dir/adminlist.txt"
    local mod_list="$world_dir/modlist.txt"
    
    local has_admin_connected=0 has_mod_connected=0 has_super_connected=0
    
    # Verificar jugadores conectados verificados
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
    
    log_debug "List cleanup - Admin: $has_admin_connected, Mod: $has_mod_connected, Super: $has_super_connected"
    
    [ $has_admin_connected -eq 0 ] && [ -f "$admin_list" ] && rm -f "$admin_list" && log_debug "Removed adminlist.txt"
    [ $has_mod_connected -eq 0 ] && [ -f "$mod_list" ] && rm -f "$mod_list" && log_debug "Removed modlist.txt"
    [ $has_super_connected -eq 0 ] && remove_cloud_admin_file_if_empty
}

sync_lists_from_players_log() {
    log_debug "Syncing lists from players.log"
    
    # Inicialización única por mundo
    [ -z "${list_files_initialized["$WORLD_ID"]}" ] && force_reload_all_lists && list_files_initialized["$WORLD_ID"]=1
    
    [ ! -f "$PLAYERS_LOG" ] && return
    
    while IFS='|' read -r name first_ip password rank whitelisted blacklisted; do
        name=$(echo "$name" | xargs)
        first_ip=$(echo "$first_ip" | xargs)
        rank=$(echo "$rank" | xargs)
        whitelisted=$(echo "$whitelisted" | xargs)
        blacklisted=$(echo "$blacklisted" | xargs)
        
        [ -z "${connected_players[$name]}" ] && continue
        [ "${player_verification_status[$name]}" != "verified" ] && continue
        
        local current_ip="${player_ip_map[$name]}"
        local current_rank="${current_player_ranks[$name]}"
        
        # Aplicar cambios de rango
        [ "$current_rank" != "$rank" ] && apply_rank_changes "$name" "$current_rank" "$rank" && current_player_ranks["$name"]="$rank"
        
        # Aplicar cambios de blacklist/whitelist
        [ "${current_blacklisted_players[$name]}" != "$blacklisted" ] && handle_blacklist_change "$name" "$blacklisted"
        [ "${current_whitelisted_players[$name]}" != "$whitelisted" ] && handle_whitelist_change "$name" "$whitelisted" "$current_ip"
        
    done < "$PLAYERS_LOG"
}

force_reload_all_lists() {
    log_debug "=== FORCING COMPLETE RELOAD OF ALL LISTS ==="
    
    [ ! -f "$PLAYERS_LOG" ] && return
    
    while IFS='|' read -r name first_ip password rank whitelisted blacklisted; do
        name=$(echo "$name" | xargs)
        first_ip=$(echo "$first_ip" | xargs)
        password=$(echo "$password" | xargs)
        rank=$(echo "$rank" | xargs)
        whitelisted=$(echo "$whitelisted" | xargs)
        blacklisted=$(echo "$blacklisted" | xargs)
        
        [ -z "${connected_players[$name]}" ] && continue
        [ "${player_verification_status[$name]}" != "verified" ] && continue
        
        log_debug "Reloading player: $name (Rank: $rank)"
        
        case "$rank" in
            "MOD") execute_server_command "/mod $name" ;;
            "ADMIN") execute_server_command "/admin $name" ;;
            "SUPER")
                execute_server_command "/admin $name"
                add_to_cloud_admin "$name"
                ;;
        esac
        
        [ "$whitelisted" = "YES" ] && [ "$first_ip" != "UNKNOWN" ] && execute_server_command "/whitelist $first_ip"
        [ "$blacklisted" = "YES" ] && execute_server_command "/ban $name" && [ "$first_ip" != "UNKNOWN" ] && execute_server_command "/ban $first_ip"
        
    done < "$PLAYERS_LOG"
}

# =============================================================================
# MANEJO DE CAMBIOS DE ESTADO
# =============================================================================

apply_rank_changes() {
    local player_name="$1" old_rank="$2" new_rank="$3"
    
    log_debug "Applying rank change: $player_name from $old_rank to $new_rank"
    
    # Remover rango antiguo
    case "$old_rank" in
        "ADMIN") execute_server_command "/unadmin $player_name" ;;
        "MOD") execute_server_command "/unmod $player_name" ;;
        "SUPER")
            start_super_disconnect_timer "$player_name"
            execute_server_command "/unadmin $player_name"
            ;;
    esac
    
    sleep 1
    
    # Aplicar nuevo rango (solo si está verificado)
    [ "${player_verification_status[$player_name]}" != "verified" ] && return
    
    case "$new_rank" in
        "ADMIN") execute_server_command "/admin $player_name" ;;
        "MOD") execute_server_command "/mod $player_name" ;;
        "SUPER")
            add_to_cloud_admin "$player_name"
            execute_server_command "/admin $player_name"
            ;;
    esac
}

handle_whitelist_change() {
    local player_name="$1" whitelisted="$2" current_ip="$3"
    
    log_debug "Whitelist change: $player_name -> $whitelisted (IP: $current_ip)"
    
    if [ "$whitelisted" = "YES" ] && [ -n "$current_ip" ] && [ "$current_ip" != "UNKNOWN" ]; then
        execute_server_command "/whitelist $current_ip"
    elif [ "$whitelisted" = "NO" ] && [ -n "$current_ip" ] && [ "$current_ip" != "UNKNOWN" ]; then
        execute_server_command "/unwhitelist $current_ip"
    fi
}

handle_blacklist_change() {
    local player_name="$1" blacklisted="$2"
    
    log_debug "Blacklist change: $player_name -> $blacklisted"
    
    local player_info=$(get_player_info "$player_name")
    [ -z "$player_info" ] && return
    
    local first_ip=$(echo "$player_info" | cut -d'|' -f1)
    local password=$(echo "$player_info" | cut -d'|' -f2)
    local rank=$(echo "$player_info" | cut -d'|' -f3)
    local current_ip="${player_ip_map[$player_name]}"
    
    if [ "$blacklisted" = "YES" ]; then
        # Remover rangos
        case "$rank" in
            "MOD") execute_server_command "/unmod $player_name" ;;
            "ADMIN"|"SUPER")
                execute_server_command "/unadmin $player_name"
                [ "$rank" = "SUPER" ] && remove_from_cloud_admin "$player_name"
                ;;
        esac
        
        execute_server_command "/ban $player_name"
        [ -n "$current_ip" ] && [ "$current_ip" != "UNKNOWN" ] && execute_server_command "/ban $current_ip"
        
        log_debug "Blacklisted player: $player_name"
    else
        execute_server_command "/unban $player_name"
        [ -n "$current_ip" ] && [ "$current_ip" != "UNKNOWN" ] && execute_server_command "/unban $current_ip"
        log_debug "Removed $player_name from blacklist"
    fi
}

# =============================================================================
# GESTIÓN DE CONTRASEÑAS Y VERIFICACIÓN
# =============================================================================

start_password_enforcement() {
    local player_name="$1"
    
    log_debug "Starting password enforcement for: $player_name"
    
    # Recordatorio de contraseña
    (
        sleep 5
        [ -n "${connected_players[$player_name]}" ] && execute_server_command "SECURITY: $player_name, set your password within 60 seconds!" && \
        execute_server_command "Example: !psw Mypassword123 Mypassword123"
    ) &
    active_timers["password_reminder_$player_name"]=$!
    
    # Kick por falta de contraseña
    (
        sleep 60
        if [ -n "${connected_players[$player_name]}" ]; then
            local player_info=$(get_player_info "$player_name")
            [ -n "$player_info" ] && [ "$(echo "$player_info" | cut -d'|' -f2)" = "NONE" ] && execute_server_command "/kick $player_name"
        fi
    ) &
    active_timers["password_kick_$player_name"]=$!
}

start_ip_grace_timer() {
    local player_name="$1" current_ip="$2"
    
    log_debug "Starting IP grace timer for: $player_name with IP $current_ip"
    
    (
        sleep 5
        [ -z "${connected_players[$player_name]}" ] && return
        
        local player_info=$(get_player_info "$player_name")
        [ -z "$player_info" ] && return
        
        local first_ip=$(echo "$player_info" | cut -d'|' -f1)
        [ "$first_ip" = "UNKNOWN" ] || [ "$first_ip" = "$current_ip" ] && return
        
        execute_server_command "SECURITY ALERT: $player_name, your IP has changed!"
        execute_server_command "Verify with !ip_change + YOUR_PASSWORD within 25 seconds!"
        execute_server_command "Else you'll get kicked and temporal IP ban for 30 seconds."
        
        sleep 25
        
        if [ -n "${connected_players[$player_name]}" ] && [ "${player_verification_status[$player_name]}" != "verified" ]; then
            execute_server_command "/kick $player_name"
            execute_server_command "/ban $current_ip"
            
            (
                sleep 30
                execute_server_command "/unban $current_ip"
                log_debug "Auto-unbanned IP: $current_ip"
            ) &
        fi
    ) &
    
    active_timers["ip_grace_$player_name"]=$!
}

handle_password_creation() {
    local player_name="$1" password="$2" confirm_password="$3"
    
    log_debug "Password creation for: $player_name"
    execute_server_command "/clear"
    
    # Validaciones
    if [ ${#password} -lt 7 ] || [ ${#password} -gt 16 ]; then
        send_server_command "$SCREEN_SESSION" "ERROR: $player_name, password must be 7-16 characters."
        return 1
    fi
    
    if [ "$password" != "$confirm_password" ]; then
        send_server_command "$SCREEN_SESSION" "ERROR: $player_name, passwords don't match."
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
        send_server_command "$SCREEN_SESSION" "ERROR: $player_name, player not found."
        return 1
    fi
}

handle_ip_change() {
    local player_name="$1" password="$2" current_ip="$3"
    
    log_debug "IP change verification for: $player_name"
    execute_server_command "/clear"
    
    local player_info=$(get_player_info "$player_name")
    if [ -n "$player_info" ]; then
        local first_ip=$(echo "$player_info" | cut -d'|' -f1)
        local current_password=$(echo "$player_info" | cut -d'|' -f2)
        local rank=$(echo "$player_info" | cut -d'|' -f3)
        local whitelisted=$(echo "$player_info" | cut -d'|' -f4)
        local blacklisted=$(echo "$player_info" | cut -d'|' -f5)
        
        if [ "$current_password" != "$password" ]; then
            send_server_command "$SCREEN_SESSION" "ERROR: $player_name, password incorrect."
            return 1
        fi
        
        update_player_info "$player_name" "$current_ip" "$current_password" "$rank" "$whitelisted" "$blacklisted"
        player_verification_status["$player_name"]="verified"
        cancel_player_timers "$player_name"
        
        execute_server_command "SECURITY: $player_name IP verification successful."
        apply_pending_ranks "$player_name"
        start_rank_application_timer "$player_name"
        sync_lists_from_players_log
        
        send_server_command "$SCREEN_SESSION" "SUCCESS: $player_name, IP verified and updated."
        return 0
    else
        send_server_command "$SCREEN_SESSION" "ERROR: $player_name, player not found."
        return 1
    fi
}

apply_pending_ranks() {
    local player_name="$1"
    
    [ -z "${pending_ranks[$player_name]}" ] && return
    [ "${player_verification_status[$player_name]}" != "verified" ] && return
    
    local pending_rank="${pending_ranks[$player_name]}"
    log_debug "Applying pending rank for $player_name: $pending_rank"
    
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
}

# =============================================================================
# MONITORES PRINCIPALES
# =============================================================================

monitor_players_log() {
    local last_checksum=""
    local temp_file=$(mktemp)
    
    [ -f "$PLAYERS_LOG" ] && cp "$PLAYERS_LOG" "$temp_file"
    
    # Cargar estado inicial
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
    
    # Monitoreo continuo
    while true; do
        if [ -f "$PLAYERS_LOG" ]; then
            local current_checksum=$(md5sum "$PLAYERS_LOG" 2>/dev/null | cut -d' ' -f1)
            
            if [ "$current_checksum" != "$last_checksum" ]; then
                log_debug "Detected change in players.log"
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
    
    [ ! -f "$previous_file" ] || [ ! -f "$PLAYERS_LOG" ] && sync_lists_from_players_log && return
    
    while IFS='|' read -r name first_ip password rank whitelisted blacklisted; do
        name=$(echo "$name" | xargs)
        rank=$(echo "$rank" | xargs)
        blacklisted=$(echo "$blacklisted" | xargs)
        whitelisted=$(echo "$whitelisted" | xargs)
        
        local previous_line=$(grep -i "^$name|" "$previous_file" 2>/dev/null | head -1)
        [ -z "$previous_line" ] && continue
        
        local prev_rank=$(echo "$previous_line" | cut -d'|' -f4 | xargs)
        local prev_blacklisted=$(echo "$previous_line" | cut -d'|' -f6 | xargs)
        local prev_whitelisted=$(echo "$previous_line" | cut -d'|' -f5 | xargs)
        
        [ "$prev_rank" != "$rank" ] && apply_rank_changes "$name" "$prev_rank" "$rank"
        [ "$prev_blacklisted" != "$blacklisted" ] && handle_blacklist_change "$name" "$blacklisted"
        [ "$prev_whitelisted" != "$whitelisted" ] && handle_whitelist_change "$name" "$whitelisted" "${player_ip_map[$name]}"
        
    done < "$PLAYERS_LOG"
    
    sync_lists_from_players_log
}

monitor_console_log() {
    print_header "STARTING CONSOLE LOG MONITOR"
    log_debug "Starting console log monitor"
    
    # Esperar a que exista el archivo
    local wait_time=0
    while [ ! -f "$CONSOLE_LOG" ] && [ $wait_time -lt 30 ]; do
        sleep 1
        ((wait_time++))
        [ $((wait_time % 5)) -eq 0 ] && log_debug "Waiting for console.log..."
    done
    
    [ ! -f "$CONSOLE_LOG" ] && log_debug "ERROR: Console log never appeared" && return 1
    
    log_debug "Console log found, starting monitoring"
    
    tail -n 0 -F "$CONSOLE_LOG" | while read -r line; do
        # Conexión de jugador
        if [[ "$line" =~ Player\ Connected\ (.+)\ \|\ ([0-9a-fA-F.:]+)\ \|\ ([0-9a-f]+) ]]; then
            handle_player_connect "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
        fi
        
        # Desconexión de jugador
        if [[ "$line" =~ Player\ Disconnected\ (.+) ]]; then
            handle_player_disconnect "${BASH_REMATCH[1]}"
        fi
        
        # Comandos de chat
        if [[ "$line" =~ ([a-zA-Z0-9_]+):\ (.+)$ ]]; then
            handle_chat_command "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
        fi
        
        # Limpieza de listas
        if [[ "$line" =~ cleared\ (.+)\ list ]]; then
            log_debug "Detected list clearance, reloading lists"
            sleep 2
            force_reload_all_lists
        fi
    done
}

handle_player_connect() {
    local player_name="$1" player_ip="$2" player_hash="$3"
    
    player_name=$(extract_real_name "$player_name")
    player_name=$(echo "$player_name" | xargs)
    
    if ! is_valid_player_name "$player_name"; then
        handle_invalid_player_name "$player_name" "$player_ip" "$player_hash"
        return
    fi
    
    cancel_timer "disconnect_timers" "$player_name"
    cancel_timer "super_admin_disconnect_timers" "$player_name"
    
    connected_players["$player_name"]=1
    player_ip_map["$player_name"]="$player_ip"
    
    log_debug "Player connected: $player_name ($player_ip)"
    
    local player_info=$(get_player_info "$player_name")
    if [ -z "$player_info" ]; then
        # Nuevo jugador
        update_player_info "$player_name" "$player_ip" "NONE" "NONE" "NO" "NO"
        player_verification_status["$player_name"]="verified"
        start_password_enforcement "$player_name"
    else
        # Jugador existente
        local first_ip=$(echo "$player_info" | cut -d'|' -f1)
        local password=$(echo "$player_info" | cut -d'|' -f2)
        local rank=$(echo "$player_info" | cut -d'|' -f3)
        local whitelisted=$(echo "$player_info" | cut -d'|' -f4)
        
        if [ "$first_ip" = "UNKNOWN" ]; then
            update_player_info "$player_name" "$player_ip" "$password" "$rank" "$whitelisted" "NO"
            player_verification_status["$player_name"]="verified"
        elif [ "$first_ip" != "$player_ip" ]; then
            player_verification_status["$player_name"]="pending"
            [ "$rank" != "NONE" ] && apply_rank_changes "$player_name" "$rank" "NONE" && pending_ranks["$player_name"]="$rank"
            start_ip_grace_timer "$player_name" "$player_ip"
        else
            player_verification_status["$player_name"]="verified"
        fi
        
        [ "$password" = "NONE" ] && start_password_enforcement "$player_name"
        [ "${player_verification_status[$player_name]}" = "verified" ] && start_rank_application_timer "$player_name"
    fi
    
    sync_lists_from_players_log
}

handle_player_disconnect() {
    local player_name="$1"
    player_name=$(echo "$player_name" | xargs)
    
    [ ! is_valid_player_name "$player_name" ] && return
    
    log_debug "Player disconnected: $player_name"
    cancel_player_timers "$player_name"
    start_disconnect_timer "$player_name"
    
    # Limpiar estado del jugador
    unset connected_players["$player_name"]
    unset player_ip_map["$player_name"]
    unset player_verification_status["$player_name"]
    unset pending_ranks["$player_name"]
    
    sync_lists_from_players_log
}

handle_chat_command() {
    local player_name="$1" message="$2"
    local current_ip="${player_ip_map[$player_name]}"
    
    player_name=$(echo "$player_name" | xargs)
    [ ! is_valid_player_name "$player_name" ] && return
    
    log_debug "Chat command from $player_name: $message"
    
    case "$message" in
        "!psw "*)
            if [[ "$message" =~ !psw\ ([^[:space:]]+)\ ([^[:space:]]+)$ ]]; then
                handle_password_creation "$player_name" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
            else
                execute_server_command "/clear"
                send_server_command "$SCREEN_SESSION" "ERROR: $player_name, use: !psw Mypassword123 Mypassword123"
            fi
            ;;
        "!ip_change "*)
            if [[ "$message" =~ !ip_change\ (.+)$ ]]; then
                handle_ip_change "$player_name" "${BASH_REMATCH[1]}" "$current_ip"
            else
                execute_server_command "/clear"
                send_server_command "$SCREEN_SESSION" "ERROR: $player_name, use: !ip_change YOUR_PASSWORD"
            fi
            ;;
    esac
}

monitor_list_files() {
    local world_dir="$BASE_SAVES_DIR/$WORLD_ID"
    local admin_list="$world_dir/adminlist.txt"
    local mod_list="$world_dir/modlist.txt"
    
    local last_admin_checksum="" last_mod_checksum=""
    
    while true; do
        if [ -f "$admin_list" ]; then
            local current_admin_checksum=$(md5sum "$admin_list" 2>/dev/null | cut -d' ' -f1)
            [ "$current_admin_checksum" != "$last_admin_checksum" ] && force_reload_all_lists && last_admin_checksum="$current_admin_checksum"
        fi
        
        if [ -f "$mod_list" ]; then
            local current_mod_checksum=$(md5sum "$mod_list" 2>/dev/null | cut -d' ' -f1)
            [ "$current_mod_checksum" != "$last_mod_checksum" ] && force_reload_all_lists && last_mod_checksum="$current_mod_checksum"
        fi
        
        sleep 5
    done
}

# =============================================================================
# FUNCIÓN PRINCIPAL Y CLEANUP
# =============================================================================

cleanup() {
    print_header "CLEANING UP RANK PATCHER"
    log_debug "=== CLEANUP STARTED ==="
    
    # Matar todos los procesos hijos
    jobs -p | xargs kill -9 2>/dev/null
    
    # Limpiar arrays de temporizadores
    for timer_key in "${!active_timers[@]}"; do
        kill "${active_timers[$timer_key]}" 2>/dev/null
    done
    
    for player_name in "${!disconnect_timers[@]}"; do
        kill "${disconnect_timers[$player_name]}" 2>/dev/null
    done
    
    for player_name in "${!super_admin_disconnect_timers[@]}"; do
        kill "${super_admin_disconnect_timers[$player_name]}" 2>/dev/null
    done
    
    log_debug "=== CLEANUP COMPLETED ==="
    print_success "Cleanup completed"
    exit 0
}

main() {
    [ $# -lt 1 ] && print_error "Usage: $0 <port>" && print_status "Example: $0 12153" && exit 1
    
    PORT="$1"
    
    print_header "THE BLOCKHEADS RANK PATCHER"
    print_status "Starting rank patcher for port: $PORT"
    
    trap cleanup EXIT INT TERM
    
    setup_paths "$PORT" || exit 1
    
    if ! screen_session_exists "$SCREEN_SESSION"; then
        print_error "Server screen session not found: $SCREEN_SESSION"
        print_status "Please start the server first using server_manager.sh"
        exit 1
    fi
    
    # Iniciar monitores en background
    print_step "Starting monitors..."
    monitor_players_log &
    monitor_console_log &
    monitor_list_files &
    
    print_header "RANK PATCHER IS NOW RUNNING"
    print_status "Monitoring: $CONSOLE_LOG"
    print_status "Session: $SCREEN_SESSION"
    print_status "World: $WORLD_ID"
    
    wait
}

main "$@"
