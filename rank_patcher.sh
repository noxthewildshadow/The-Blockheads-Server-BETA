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

# Constantes de tiempo
CREATE_LIST_DELAY=1
RANK_APPLICATION_DELAY=5
DISCONNECT_TIMER_DELAY=15
IP_VERIFICATION_GRACE_PERIOD=25
PASSWORD_ENFORCEMENT_DELAY=60

# =============================================================================
# VARIABLES GLOBALES
# =============================================================================

# Archivos de log y configuración
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
declare -A player_password_reminder_sent
declare -A active_timers
declare -A current_player_ranks
declare -A current_blacklisted_players
declare -A current_whitelisted_players
declare -A pending_ranks
declare -A list_files_initialized
declare -A disconnect_timers
declare -A last_command_time
declare -A list_cleanup_timers

# Flags
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

# =============================================================================
# VALIDACIÓN Y SANEAMIENTO
# =============================================================================

is_valid_player_name() {
    local name="$1"
    
    # Validaciones básicas
    [[ -z "$name" ]] || [[ "$name" =~ ^[[:space:]]+$ ]] && return 1
    [[ ${#name} -lt 3 || ${#name} -gt 16 ]] && return 1
    [[ "$name" =~ [[:space:]] ]] && return 1
    [[ "$name" =~ [\\\/\|\<\>\:\"\?\*] ]] && return 1
    
    # Solo caracteres alfanuméricos y underscore
    [[ "$name" =~ ^[a-zA-Z0-9_]+$ ]] || return 1
    
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

# =============================================================================
# GESTIÓN DE ARCHIVOS Y RUTAS
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
    
    # Configurar rutas
    PLAYERS_LOG="$BASE_SAVES_DIR/$WORLD_ID/players.log"
    CONSOLE_LOG="$BASE_SAVES_DIR/$WORLD_ID/console.log"
    PATCH_DEBUG_LOG="$BASE_SAVES_DIR/$WORLD_ID/patch_debug.log"
    SCREEN_SESSION="blockheads_server_$port"
    
    # Crear archivos si no existen
    [ ! -f "$PLAYERS_LOG" ] && touch "$PLAYERS_LOG"
    [ ! -f "$PATCH_DEBUG_LOG" ] && touch "$PATCH_DEBUG_LOG"
    
    log_debug "=== RANK PATCHER STARTED ==="
    log_debug "World ID: $WORLD_ID | Port: $port"
    log_debug "Players log: $PLAYERS_LOG"
    log_debug "Console log: $CONSOLE_LOG"
    log_debug "Screen session: $SCREEN_SESSION"
}

# =============================================================================
# GESTIÓN DE COMANDOS DEL SERVIDOR
# =============================================================================

execute_server_command() {
    local command="$1"
    local current_time=$(date +%s)
    local last_time=${last_command_time["$SCREEN_SESSION"]:-0}
    local time_diff=$((current_time - last_time))
    
    # Rate limiting
    if [ $time_diff -lt 1 ]; then
        sleep $((1 - time_diff))
    fi
    
    log_debug "Executing server command: $command"
    send_server_command "$SCREEN_SESSION" "$command"
    last_command_time["$SCREEN_SESSION"]=$(date +%s)
}

send_server_command() {
    local screen_session="$1"
    local command="$2"
    
    if screen -S "$screen_session" -p 0 -X stuff "$command$(printf \\r)" 2>/dev/null; then
        log_debug "Command sent successfully: $command"
        return 0
    else
        log_debug "FAILED to send command: $command"
        return 1
    fi
}

screen_session_exists() {
    screen -list | grep -q "$1"
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
    
    # Normalizar valores
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
        # Eliminar entrada existente y agregar nueva
        sed -i "/^$player_name|/Id" "$PLAYERS_LOG"
        echo "$player_name|$first_ip|$password|$rank|$whitelisted|$blacklisted" >> "$PLAYERS_LOG"
        log_debug "Updated player: $player_name | $first_ip | $password | $rank | $whitelisted | $blacklisted"
    fi
}

# =============================================================================
# GESTIÓN DE LISTAS (ADMINLIST, MODLIST, CLOUD)
# =============================================================================

create_list_if_needed() {
    local rank="$1"
    local world_dir="$BASE_SAVES_DIR/$WORLD_ID"
    
    log_debug "Checking list creation for rank: $rank"
    
    # Verificar si hay jugadores verificados con este rango conectados
    if ! has_verified_players_with_rank "$rank"; then
        log_debug "No verified players with rank $rank connected - skipping list creation"
        return
    fi
    
    case "$rank" in
        "MOD")
            local mod_list="$world_dir/modlist.txt"
            if [ ! -f "$mod_list" ]; then
                log_debug "Creating modlist.txt using CREATE_LIST method"
                execute_server_command "/mod CREATE_LIST"
                schedule_list_cleanup "MOD" "CREATE_LIST"
            else
                log_debug "modlist.txt already exists"
            fi
            ;;
        "ADMIN"|"SUPER")
            local admin_list="$world_dir/adminlist.txt"
            if [ ! -f "$admin_list" ]; then
                log_debug "Creating adminlist.txt using CREATE_LIST method"
                execute_server_command "/admin CREATE_LIST"
                if [ "$rank" = "SUPER" ]; then
                    add_to_cloud_admin "CREATE_LIST"
                    schedule_cloud_cleanup "CREATE_LIST"
                fi
                schedule_list_cleanup "ADMIN" "CREATE_LIST"
            else
                log_debug "adminlist.txt already exists"
            fi
            ;;
    esac
}

schedule_list_cleanup() {
    local rank="$1" temp_name="$2"
    
    (
        sleep $CREATE_LIST_DELAY
        case "$rank" in
            "MOD")
                execute_server_command "/unmod $temp_name"
                ;;
            "ADMIN")
                execute_server_command "/unadmin $temp_name"
                ;;
        esac
        log_debug "Cleaned up temporary $rank list entry: $temp_name"
    ) &
}

schedule_cloud_cleanup() {
    local temp_name="$1"
    (
        sleep $CREATE_LIST_DELAY
        remove_from_cloud_admin "$temp_name"
        log_debug "Cleaned up temporary cloud admin entry: $temp_name"
    ) &
}

has_verified_players_with_rank() {
    local target_rank="$1"
    
    for player in "${!connected_players[@]}"; do
        if [ "${player_verification_status[$player]}" = "verified" ]; then
            local player_info=$(get_player_info "$player")
            if [ -n "$player_info" ]; then
                local rank=$(echo "$player_info" | cut -d'|' -f3)
                if [ "$rank" = "$target_rank" ]; then
                    log_debug "Found verified player with rank $target_rank: $player"
                    return 0
                fi
            fi
        fi
    done
    
    return 1
}

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
            log_debug "Removed cloud admin file (empty after removing $player_name)"
        fi
    fi
}

# =============================================================================
# GESTIÓN DE RANGOS Y APLICACIÓN
# =============================================================================

start_rank_application_timer() {
    local player_name="$1"
    
    log_debug "Starting rank application timer for: $player_name (Status: ${player_verification_status[$player_name]})"
    
    # Solo proceder si el jugador está verificado y conectado
    if [ -n "${connected_players[$player_name]}" ] && [ "${player_verification_status[$player_name]}" = "verified" ]; then
        local player_info=$(get_player_info "$player_name")
        if [ -n "$player_info" ]; then
            local rank=$(echo "$player_info" | cut -d'|' -f3)
            if [ "$rank" != "NONE" ]; then
                log_debug "Verified player $player_name has rank $rank - proceeding with list creation and rank application"
                
                # Paso 1: Crear lista si es necesario
                create_list_if_needed "$rank"
                
                # Paso 2: Aplicar rango después del delay
                (
                    sleep $RANK_APPLICATION_DELAY
                    if [ -n "${connected_players[$player_name]}" ] && [ "${player_verification_status[$player_name]}" = "verified" ]; then
                        log_debug "Applying rank to verified player: $player_name"
                        apply_rank_to_player "$player_name"
                    else
                        log_debug "Player $player_name not available for rank application"
                    fi
                ) &
                
                active_timers["rank_application_$player_name"]=$!
            fi
        fi
    else
        log_debug "Player $player_name not verified - skipping rank application timer"
    fi
}

apply_rank_to_player() {
    local player_name="$1"
    
    if [ -z "${connected_players[$player_name]}" ]; then
        log_debug "Player $player_name disconnected - skipping rank application"
        return
    fi
    
    if [ "${player_verification_status[$player_name]}" != "verified" ]; then
        log_debug "Player $player_name not verified - skipping rank application"
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
    
    log_debug "Applying rank $rank to verified player: $player_name"
    
    # Verificar que tenga contraseña
    if [ "$password" = "NONE" ]; then
        log_debug "Player $player_name has no password - skipping rank application"
        return
    fi
    
    # Aplicar rango según corresponda
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
    
    # Aplicar whitelist/blacklist
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

# =============================================================================
# GESTIÓN DE DESCONEXIONES Y LIMPIEZA
# =============================================================================

start_disconnect_timer() {
    local player_name="$1"
    
    log_debug "Starting disconnect timer for: $player_name"
    
    (
        log_debug "Disconnect timer started for $player_name - waiting $DISCONNECT_TIMER_DELAY seconds"
        sleep $DISCONNECT_TIMER_DELAY
        
        log_debug "Disconnect timer completed for $player_name - cleaning up"
        remove_player_rank "$player_name"
        cleanup_empty_lists_after_disconnect "$player_name"
        
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
            log_debug "Cancelled disconnect timer for $player_name"
        fi
        unset disconnect_timers["$player_name"]
    fi
}

remove_player_rank() {
    local player_name="$1"
    
    log_debug "Removing rank for disconnected player: $player_name"
    
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
        
        log_debug "Removed rank $rank from disconnected player: $player_name"
    fi
}

cleanup_empty_lists_after_disconnect() {
    local disconnected_player="$1"
    local world_dir="$BASE_SAVES_DIR/$WORLD_ID"
    
    log_debug "Cleaning up lists after disconnect: $disconnected_player"
    
    # Verificar jugadores verificados conectados por rango
    local has_admin=$(has_verified_players_with_rank "ADMIN")
    local has_super=$(has_verified_players_with_rank "SUPER") 
    local has_mod=$(has_verified_players_with_rank "MOD")
    
    log_debug "List cleanup status - Admin: $has_admin, Super: $has_super, Mod: $has_mod"
    
    # Eliminar listas solo si no hay jugadores verificados con ese rango
    if [ "$has_admin" = "false" ] && [ "$has_super" = "false" ]; then
        local admin_list="$world_dir/adminlist.txt"
        if [ -f "$admin_list" ]; then
            rm -f "$admin_list"
            log_debug "Removed adminlist.txt (no verified admins/supers connected)"
        fi
    fi
    
    if [ "$has_mod" = "false" ]; then
        local mod_list="$world_dir/modlist.txt"
        if [ -f "$mod_list" ]; then
            rm -f "$mod_list"
            log_debug "Removed modlist.txt (no verified mods connected)"
        fi
    fi
    
    # Para cloud admin, usar lógica separada
    if [ "$has_super" = "false" ]; then
        remove_cloud_admin_file_if_empty
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
            log_debug "Cloud admin file has $valid_lines valid entries - keeping"
        fi
    fi
}

# =============================================================================
# VERIFICACIÓN Y SEGURIDAD
# =============================================================================

handle_invalid_player_name() {
    local player_name="$1" player_ip="$2" player_hash="${3:-unknown}"
    
    print_error "INVALID PLAYER NAME: '$player_name' (IP: $player_ip, Hash: $player_hash)"
    
    local safe_name=$(sanitize_name_for_command "$player_name")
    
    (
        sleep 3
        execute_server_command "WARNING: Invalid player name '$player_name'! Names must be 3-16 alphanumeric characters."
        execute_server_command "WARNING: You will be kicked and IP banned in 3 seconds for 60 seconds."
        
        sleep 3

        if [ -n "$player_ip" ] && [ "$player_ip" != "unknown" ]; then
            execute_server_command "/ban $player_ip"
            execute_server_command "/kick \"$safe_name\""
            print_warning "Banned invalid player: '$player_name' (IP: $player_ip) for 60 seconds"
            
            (
                sleep 60
                execute_server_command "/unban $player_ip"
                print_success "Unbanned IP: $player_ip"
            ) &
        else
            execute_server_command "/ban \"$safe_name\""
            execute_server_command "/kick \"$safe_name\""
            print_warning "Banned invalid player name: '$player_name'"
        fi
    ) &
}

start_ip_verification_process() {
    local player_name="$1" current_ip="$2"
    
    log_debug "Starting IP verification process for: $player_name ($current_ip)"
    
    player_verification_status["$player_name"]="pending"
    
    (
        sleep 5
        if [ -n "${connected_players[$player_name]}" ] && [ "${player_verification_status[$player_name]}" = "pending" ]; then
            execute_server_command "SECURITY ALERT: $player_name, your IP has changed!"
            execute_server_command "Verify with !ip_change + YOUR_PASSWORD within $IP_VERIFICATION_GRACE_PERIOD seconds!"
            execute_server_command "Else you'll get kicked and a temporal ip ban for 30 seconds."
        fi
        
        sleep $IP_VERIFICATION_GRACE_PERIOD
        
        if [ -n "${connected_players[$player_name]}" ] && [ "${player_verification_status[$player_name]}" != "verified" ]; then
            log_debug "IP verification failed for $player_name, kicking and banning"
            execute_server_command "/kick $player_name"
            execute_server_command "/ban $current_ip"
            
            (
                sleep 30
                execute_server_command "/unban $current_ip"
                log_debug "Auto-unbanned IP: $current_ip"
            ) &
        fi
    ) &
    
    active_timers["ip_verification_$player_name"]=$!
}

verify_player_ip() {
    local player_name="$1" password="$2" current_ip="$3"
    
    log_debug "Verifying IP for player: $player_name"
    
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
        
        # Actualizar IP y marcar como verificado
        update_player_info "$player_name" "$current_ip" "$current_password" "$rank" "$whitelisted" "$blacklisted"
        player_verification_status["$player_name"]="verified"
        
        # Cancelar temporizador de verificación
        cancel_player_timer "ip_verification_$player_name"
        
        log_debug "IP verification successful for $player_name"
        execute_server_command "SECURITY: $player_name IP verification successful."
        
        # Aplicar rangos pendientes y iniciar proceso de aplicación de rango
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
# GESTIÓN DE CONTRASEÑAS
# =============================================================================

start_password_enforcement() {
    local player_name="$1"
    
    log_debug "Starting password enforcement for: $player_name"
    
    start_password_reminder_timer "$player_name"
    start_password_kick_timer "$player_name"
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
                    execute_server_command "SECURITY: $player_name, set your password within $PASSWORD_ENFORCEMENT_DELAY seconds!"
                    execute_server_command "Example: !psw Mypassword123 Mypassword123"
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
        sleep $PASSWORD_ENFORCEMENT_DELAY
        if [ -n "${connected_players[$player_name]}" ]; then
            local player_info=$(get_player_info "$player_name")
            if [ -n "$player_info" ]; then
                local password=$(echo "$player_info" | cut -d'|' -f2)
                if [ "$password" = "NONE" ]; then
                    log_debug "Kicking $player_name for not setting password"
                    execute_server_command "/kick $player_name"
                fi
            fi
        fi
    ) &
    
    active_timers["password_kick_$player_name"]=$!
}

handle_password_creation() {
    local player_name="$1" password="$2" confirm_password="$3"
    
    log_debug "Processing password creation for: $player_name"
    
    execute_server_command "/clear"
    
    # Validaciones
    if [ ${#password} -lt 7 ] || [ ${#password} -gt 16 ]; then
        execute_server_command "ERROR: $player_name, password must be between 7 and 16 characters."
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
        
        # Cancelar temporizadores de contraseña
        cancel_player_timer "password_reminder_$player_name"
        cancel_player_timer "password_kick_$player_name"
        
        # Actualizar información
        update_player_info "$player_name" "$first_ip" "$password" "$rank" "$whitelisted" "$blacklisted"
        
        execute_server_command "SUCCESS: $player_name, password set successfully."
        return 0
    else
        execute_server_command "ERROR: $player_name, player not found in registry."
        return 1
    fi
}

# =============================================================================
# GESTIÓN DE TEMPORIZADORES
# =============================================================================

cancel_player_timer() {
    local timer_key="$1"
    
    if [ -n "${active_timers[$timer_key]}" ]; then
        local pid="${active_timers[$timer_key]}"
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            log_debug "Cancelled timer: $timer_key (PID: $pid)"
        fi
        unset active_timers["$timer_key"]
    fi
}

cancel_all_player_timers() {
    local player_name="$1"
    
    log_debug "Cancelling all timers for: $player_name"
    
    cancel_player_timer "password_reminder_$player_name"
    cancel_player_timer "password_kick_$player_name"
    cancel_player_timer "ip_verification_$player_name"
    cancel_player_timer "rank_application_$player_name"
    cancel_disconnect_timer "$player_name"
}

# =============================================================================
# SINCRONIZACIÓN Y MONITOREO
# =============================================================================

apply_pending_ranks() {
    local player_name="$1"
    
    if [ -n "${pending_ranks[$player_name]}" ]; then
        local pending_rank="${pending_ranks[$player_name]}"
        
        if [ "${player_verification_status[$player_name]}" = "verified" ]; then
            log_debug "Applying pending rank for $player_name: $pending_rank"
            
            case "$pending_rank" in
                "ADMIN")
                    execute_server_command "/admin $player_name"
                    ;;
                "MOD")
                    execute_server_command "/mod $player_name"
                    ;;
                "SUPER")
                    execute_server_command "/admin $player_name"
                    add_to_cloud_admin "$player_name"
                    ;;
            esac
            
            current_player_ranks["$player_name"]="$pending_rank"
            unset pending_ranks["$player_name"]
        fi
    fi
}

monitor_console_log() {
    print_header "STARTING CONSOLE LOG MONITOR"
    
    # Esperar a que exista el archivo
    local wait_time=0
    while [ ! -f "$CONSOLE_LOG" ] && [ $wait_time -lt 30 ]; do
        sleep 1
        ((wait_time++))
    done
    
    if [ ! -f "$CONSOLE_LOG" ]; then
        print_error "Console log never appeared: $CONSOLE_LOG"
        return 1
    fi
    
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
    done
}

handle_player_connect() {
    local player_name="$1" player_ip="$2" player_hash="$3"
    
    player_name=$(extract_real_name "$player_name")
    player_name=$(echo "$player_name" | xargs)
    
    # Validar nombre
    if ! is_valid_player_name "$player_name"; then
        handle_invalid_player_name "$player_name" "$player_ip" "$player_hash"
        return
    fi
    
    log_debug "Player connected: $player_name ($player_ip)"
    
    # Cancelar temporizadores de desconexión previos
    cancel_disconnect_timer "$player_name"
    
    # Registrar jugador
    connected_players["$player_name"]=1
    player_ip_map["$player_name"]="$player_ip"
    
    # Manejar información del jugador
    local player_info=$(get_player_info "$player_name")
    if [ -z "$player_info" ]; then
        # Nuevo jugador
        handle_new_player "$player_name" "$player_ip"
    else
        # Jugador existente
        handle_existing_player "$player_name" "$player_ip" "$player_info"
    fi
}

handle_new_player() {
    local player_name="$1" player_ip="$2"
    
    log_debug "New player detected: $player_name"
    update_player_info "$player_name" "$player_ip" "NONE" "NONE" "NO" "NO"
    player_verification_status["$player_name"]="verified"
    start_password_enforcement "$player_name"
}

handle_existing_player() {
    local player_name="$1" player_ip="$2" player_info="$3"
    
    local first_ip=$(echo "$player_info" | cut -d'|' -f1)
    local password=$(echo "$player_info" | cut -d'|' -f2)
    local rank=$(echo "$player_info" | cut -d'|' -f3)
    
    log_debug "Existing player $player_name - First IP: $first_ip, Current IP: $player_ip, Rank: $rank"
    
    if [ "$first_ip" = "UNKNOWN" ]; then
        # Primera conexión real
        log_debug "First real connection for $player_name, updating IP"
        update_player_info "$player_name" "$player_ip" "$password" "$rank" "NO" "NO"
        player_verification_status["$player_name"]="verified"
    elif [ "$first_ip" != "$player_ip" ]; then
        # IP cambiada - requerir verificación
        log_debug "IP changed for $player_name, requiring verification"
        player_verification_status["$player_name"]="pending"
        
        # Remover rango temporalmente hasta verificación
        if [ "$rank" != "NONE" ]; then
            log_debug "Temporarily removing rank $rank until IP verification"
            remove_player_rank_immediately "$player_name" "$rank"
            pending_ranks["$player_name"]="$rank"
        fi
        
        start_ip_verification_process "$player_name" "$player_ip"
    else
        # IP coincide - verificado automáticamente
        player_verification_status["$player_name"]="verified"
    fi
    
    # Forzar contraseña si no tiene
    if [ "$password" = "NONE" ]; then
        start_password_enforcement "$player_name"
    fi
    
    # Iniciar proceso de aplicación de rango si está verificado
    if [ "${player_verification_status[$player_name]}" = "verified" ]; then
        start_rank_application_timer "$player_name"
    fi
}

remove_player_rank_immediately() {
    local player_name="$1" rank="$2"
    
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
    log_debug "Immediately removed rank $rank from $player_name"
}

handle_player_disconnect() {
    local player_name="$1"
    player_name=$(echo "$player_name" | xargs)
    
    if is_valid_player_name "$player_name"; then
        log_debug "Player disconnected: $player_name"
        
        # Cancelar todos los temporizadores activos
        cancel_all_player_timers "$player_name"
        
        # Iniciar temporizador de limpieza
        start_disconnect_timer "$player_name"
        
        # Limpiar estado
        unset connected_players["$player_name"]
        unset player_ip_map["$player_name"]
        unset player_verification_status["$player_name"]
        unset player_password_reminder_sent["$player_name"]
        unset pending_ranks["$player_name"]
    fi
}

handle_chat_command() {
    local player_name="$1" message="$2"
    local current_ip="${player_ip_map[$player_name]}"
    
    player_name=$(echo "$player_name" | xargs)
    
    if is_valid_player_name "$player_name"; then
        log_debug "Chat command from $player_name: $message"
        
        case "$message" in
            "!psw "*)
                if [[ "$message" =~ !psw\ ([^[:space:]]+)\ ([^[:space:]]+)$ ]]; then
                    handle_password_creation "$player_name" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
                else
                    execute_server_command "/clear"
                    execute_server_command "ERROR: $player_name, invalid format! Use: !psw Mypassword123 Mypassword123"
                fi
                ;;
            "!ip_change "*)
                if [[ "$message" =~ !ip_change\ (.+)$ ]]; then
                    verify_player_ip "$player_name" "${BASH_REMATCH[1]}" "$current_ip"
                else
                    execute_server_command "/clear"
                    execute_server_command "ERROR: $player_name, invalid format! Use: !ip_change YOUR_PASSWORD"
                fi
                ;;
        esac
    fi
}

# =============================================================================
# FUNCIONES PRINCIPALES
# =============================================================================

cleanup() {
    print_header "CLEANING UP RANK PATCHER"
    log_debug "=== CLEANUP STARTED ==="
    
    # Matar todos los procesos en segundo plano
    jobs -p | xargs kill -9 2>/dev/null
    
    # Limpiar temporizadores activos
    for timer_key in "${!active_timers[@]}"; do
        local pid="${active_timers[$timer_key]}"
        kill "$pid" 2>/dev/null
    done
    
    for player_name in "${!disconnect_timers[@]}"; do
        local pid="${disconnect_timers[$player_name]}"
        kill "$pid" 2>/dev/null
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
    
    # Configurar manejo de señales
    trap cleanup EXIT INT TERM
    
    # Configurar rutas
    if ! setup_paths "$PORT"; then
        exit 1
    fi
    
    # Verificar que la sesión de screen exista
    if ! screen_session_exists "$SCREEN_SESSION"; then
        print_error "Server screen session not found: $SCREEN_SESSION"
        print_status "Please start the server first using server_manager.sh"
        exit 1
    fi
    
    print_step "Starting console log monitor..."
    monitor_console_log &
    
    print_header "RANK PATCHER IS NOW RUNNING"
    print_status "Monitoring: $CONSOLE_LOG"
    print_status "Managing: $PLAYERS_LOG"
    print_status "Debug log: $PATCH_DEBUG_LOG"
    print_status "Server session: $SCREEN_SESSION"
    
    # Mantener el script corriendo
    wait
}

# Punto de entrada principal
main "$@"
