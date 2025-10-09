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
declare -A unverified_rank_players
declare -A ip_verification_timers

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

start_ip_verification_warning() {
    local player_name="$1" current_ip="$2"
    
    log_debug "Starting IP verification warning timer for $player_name"
    
    (
        sleep 5  # Esperar 5 segundos antes de mostrar la advertencia
        
        # Verificar si el jugador sigue conectado y no verificado
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
        
        # Iniciar temporizador de expiración de verificación (25 segundos)
        start_ip_verification_timeout "$player_name" "$current_ip"
        
    ) &
    
    ip_verification_timers["warning_$player_name"]=$!
}

start_ip_verification_timeout() {
    local player_name="$1" current_ip="$2"
    
    log_debug "Starting IP verification timeout for $player_name (25 seconds)"
    
    (
        sleep 25  # 25 segundos para verificar
        
        # Verificar si el jugador sigue conectado y no verificado
        if [ -z "${connected_players[$player_name]}" ] || [ "${player_verification_status[$player_name]}" = "verified" ]; then
            log_debug "Player $player_name verified or disconnected, skipping IP verification timeout"
            return
        fi
        
        log_debug "IP verification timeout reached for $player_name, kicking and banning"
        execute_server_command "/kick \"$player_name\""
        execute_server_command "/ban $current_ip"
        
        # Programar desbaneo automático después de 30 segundos
        (
            sleep 30
            execute_server_command "/unban $current_ip"
            log_debug "Auto-unbanned IP: $current_ip"
        ) &
        
    ) &
    
    ip_verification_timers["timeout_$player_name"]=$!
}

# =============================================================================
# GESTIÓN DE ARCHIVOS DE LISTAS (OPERACIONES ATÓMICAS)
# =============================================================================

# Función para leer adminlist.txt
read_adminlist() {
    local world_dir="$BASE_SAVES_DIR/$WORLD_ID"
    local admin_list="$world_dir/adminlist.txt"
    
    if [ ! -f "$admin_list" ]; then
        echo ""
        return
    fi
    
    cat "$admin_list" | grep -v -e '^$' -e '^CREATE_LIST$' | tr '\n' '|'
}

# Función para escribir adminlist.txt
write_adminlist() {
    local world_dir="$BASE_SAVES_DIR/$WORLD_ID"
    local admin_list="$world_dir/adminlist.txt"
    local content="$1"
    
    if [ -z "$content" ]; then
        # Si no hay contenido, eliminar el archivo si existe
        [ -f "$admin_list" ] && rm -f "$admin_list"
        log_debug "Removed adminlist.txt (empty content)"
        return
    fi
    
    # Convertir el contenido separado por | a líneas
    echo "$content" | tr '|' '\n' > "$admin_list"
    log_debug "Updated adminlist.txt with content: $content"
}

# Función para leer modlist.txt
read_modlist() {
    local world_dir="$BASE_SAVES_DIR/$WORLD_ID"
    local mod_list="$world_dir/modlist.txt"
    
    if [ ! -f "$mod_list" ]; then
        echo ""
        return
    fi
    
    cat "$mod_list" | grep -v -e '^$' -e '^CREATE_LIST$' | tr '\n' '|'
}

# Función para escribir modlist.txt
write_modlist() {
    local world_dir="$BASE_SAVES_DIR/$WORLD_ID"
    local mod_list="$world_dir/modlist.txt"
    local content="$1"
    
    if [ -z "$content" ]; then
        [ -f "$mod_list" ] && rm -f "$mod_list"
        log_debug "Removed modlist.txt (empty content)"
        return
    fi
    
    echo "$content" | tr '|' '\n' > "$mod_list"
    log_debug "Updated modlist.txt with content: $content"
}

# Función para leer cloudwideownedadminlist.txt
read_cloud_adminlist() {
    local cloud_file="$HOME_DIR/GNUstep/Library/ApplicationSupport/TheBlockheads/cloudWideOwnedAdminlist.txt"
    
    if [ ! -f "$cloud_file" ]; then
        echo ""
        return
    fi
    
    cat "$cloud_file" | grep -v -e '^$' -e '^CREATE_LIST$' | tr '\n' '|'
}

# Función para escribir cloudwideownedadminlist.txt
write_cloud_adminlist() {
    local cloud_file="$HOME_DIR/GNUstep/Library/ApplicationSupport/TheBlockheads/cloudWideOwnedAdminlist.txt"
    local content="$1"
    
    if [ -z "$content" ]; then
        [ -f "$cloud_file" ] && rm -f "$cloud_file"
        log_debug "Removed cloud admin file (empty content)"
        return
    fi
    
    echo "$content" | tr '|' '\n' > "$cloud_file"
    log_debug "Updated cloud admin file with content: $content"
}

# =============================================================================
# VERIFICACIÓN Y LIMPIEZA DE LISTAS PARA JUGADORES NO VERIFICADOS
# =============================================================================

check_and_cleanup_unverified_lists() {
    local player_name="$1"
    
    log_debug "Checking list cleanup for unverified player: $player_name"
    
    local player_info=$(get_player_info "$player_name")
    if [ -z "$player_info" ]; then
        log_debug "No player info found for $player_name, skipping list cleanup"
        return
    fi
    
    local rank=$(echo "$player_info" | cut -d'|' -f3)
    
    if [ "$rank" = "NONE" ]; then
        log_debug "Player $player_name has no rank, skipping list cleanup"
        return
    fi
    
    log_debug "Player $player_name has rank $rank but is unverified, checking list cleanup"
    
    # Esperar 1 segundo antes de verificar
    (
        sleep 1
        
        # Verificar si el jugador sigue conectado y no verificado
        if [ -z "${connected_players[$player_name]}" ] || [ "${player_verification_status[$player_name]}" = "verified" ]; then
            log_debug "Player $player_name status changed, skipping list cleanup"
            return
        fi
        
        log_debug "Proceeding with list cleanup check for unverified player: $player_name (Rank: $rank)"
        
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
    ) &
}

cleanup_modlist_if_no_verified_players() {
    local unverified_player="$1"
    local world_dir="$BASE_SAVES_DIR/$WORLD_ID"
    local mod_list="$world_dir/modlist.txt"
    
    if [ ! -f "$mod_list" ]; then
        log_debug "modlist.txt doesn't exist, nothing to clean up"
        return
    fi
    
    # Verificar si hay otros jugadores VERIFICADOS con rango MOD conectados
    local has_other_verified_mod=0
    for player in "${!connected_players[@]}"; do
        if [ "$player" = "$unverified_player" ]; then
            continue
        fi
        
        if [ "${player_verification_status[$player]}" != "verified" ]; then
            continue
        fi
        
        local player_info=$(get_player_info "$player")
        if [ -n "$player_info" ]; then
            local player_rank=$(echo "$player_info" | cut -d'|' -f3)
            if [ "$player_rank" = "MOD" ]; then
                has_other_verified_mod=1
                log_debug "Found other VERIFIED MOD connected: $player - keeping modlist.txt"
                break
            fi
        fi
    done
    
    if [ $has_other_verified_mod -eq 0 ]; then
        log_debug "No other VERIFIED MOD players connected, removing modlist.txt"
        rm -f "$mod_list"
    else
        log_debug "Other VERIFIED MOD players still connected, keeping modlist.txt"
    fi
}

cleanup_adminlist_if_no_verified_players() {
    local unverified_player="$1"
    local world_dir="$BASE_SAVES_DIR/$WORLD_ID"
    local admin_list="$world_dir/adminlist.txt"
    
    if [ ! -f "$admin_list" ]; then
        log_debug "adminlist.txt doesn't exist, nothing to clean up"
        return
    fi
    
    # Verificar si hay otros jugadores VERIFICADOS con rango ADMIN o SUPER conectados
    local has_other_verified_admin=0
    for player in "${!connected_players[@]}"; do
        if [ "$player" = "$unverified_player" ]; then
            continue
        fi
        
        if [ "${player_verification_status[$player]}" != "verified" ]; then
            continue
        fi
        
        local player_info=$(get_player_info "$player")
        if [ -n "$player_info" ]; then
            local player_rank=$(echo "$player_info" | cut -d'|' -f3)
            if [ "$player_rank" = "ADMIN" ] || [ "$player_rank" = "SUPER" ]; then
                has_other_verified_admin=1
                log_debug "Found other VERIFIED ADMIN/SUPER connected: $player - keeping adminlist.txt"
                break
            fi
        fi
    done
    
    if [ $has_other_verified_admin -eq 0 ]; then
        log_debug "No other VERIFIED ADMIN/SUPER players connected, removing adminlist.txt"
        rm -f "$admin_list"
    else
        log_debug "Other VERIFIED ADMIN/SUPER players still connected, keeping adminlist.txt"
    fi
}

cleanup_cloud_adminlist_if_no_verified_players() {
    local unverified_player="$1"
    local cloud_file="$HOME_DIR/GNUstep/Library/ApplicationSupport/TheBlockheads/cloudWideOwnedAdminlist.txt"
    
    if [ ! -f "$cloud_file" ]; then
        log_debug "cloud admin file doesn't exist, nothing to clean up"
        return
    fi
    
    # Verificar si hay otros jugadores VERIFICADOS con rango SUPER conectados
    local has_other_verified_super=0
    for player in "${!connected_players[@]}"; do
        if [ "$player" = "$unverified_player" ]; then
            continue
        fi
        
        if [ "${player_verification_status[$player]}" != "verified" ]; then
            continue
        fi
        
        local player_info=$(get_player_info "$player")
        if [ -n "$player_info" ]; then
            local player_rank=$(echo "$player_info" | cut -d'|' -f3)
            if [ "$player_rank" = "SUPER" ]; then
                has_other_verified_super=1
                log_debug "Found other VERIFIED SUPER connected: $player - keeping cloud admin file"
                break
            fi
        fi
    done
    
    if [ $has_other_verified_super -eq 0 ]; then
        log_debug "No other VERIFIED SUPER players connected, removing cloud admin file"
        rm -f "$cloud_file"
    else
        log_debug "Other VERIFIED SUPER players still connected, keeping cloud admin file"
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

# =============================================================================
# GESTIÓN DE LISTAS CLOUD
# =============================================================================

add_to_cloud_admin() {
    local player_name="$1"
    local current_cloud_list=$(read_cloud_adminlist)
    
    # Si el jugador ya está en la lista, no hacer nada
    if [[ "$current_cloud_list" == *"$player_name"* ]]; then
        log_debug "Player $player_name already in cloud admin list"
        return
    fi
    
    # Agregar el jugador a la lista
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
    
    # Si el jugador no está en la lista, no hacer nada
    if [[ "$current_cloud_list" != *"$player_name"* ]]; then
        log_debug "Player $player_name not in cloud admin list"
        return
    fi
    
    # Remover el jugador de la lista
    local new_list=""
    IFS='|' read -ra players <<< "$current_cloud_list"
    for player in "${players[@]}"; do
        if [ "$player" != "$player_name" ]; then
            if [ -z "$new_list" ]; then
                new_list="$player"
            else
                new_list="${new_list}|$player"
            fi
        fi
    done
    
    write_cloud_adminlist "$new_list"
    log_debug "Removed $player_name from cloud admin list"
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

# =============================================================================
# CANCELACIÓN DE TEMPORIZADORES
# =============================================================================

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

cancel_player_timers() {
    local player_name="$1"
    
    log_debug "Cancelling all timers for player: $player_name"
    
    # Cancelar todos los temporizadores activos
    for timer_key in "${!active_timers[@]}"; do
        if [[ "$timer_key" == *"$player_name"* ]]; then
            local pid="${active_timers[$timer_key]}"
            if kill -0 "$pid" 2>/dev/null; then
                kill "$pid" 2>/dev/null
                log_debug "Cancelled timer $timer_key for $player_name (PID: $pid)"
            fi
            unset active_timers["$timer_key"]
        fi
    done
    
    # Cancelar temporizadores de verificación de IP
    for timer_key in "${!ip_verification_timers[@]}"; do
        if [[ "$timer_key" == *"$player_name"* ]]; then
            local pid="${ip_verification_timers[$timer_key]}"
            if kill -0 "$pid" 2>/dev/null; then
                kill "$pid" 2>/dev/null
                log_debug "Cancelled IP verification timer $timer_key for $player_name (PID: $pid)"
            fi
            unset ip_verification_timers["$timer_key"]
        fi
    done
    
    cancel_disconnect_timer "$player_name"
}

# =============================================================================
# LIMPIEZA Y MANTENIMIENTO DE LISTAS
# =============================================================================

cleanup_empty_lists_after_disconnect() {
    local disconnected_player="$1"
    local world_dir="$BASE_SAVES_DIR/$WORLD_ID"
    
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
    
    # Usar las funciones de limpieza específicas
    if [ $has_admin_connected -eq 0 ]; then
        cleanup_adminlist_if_no_verified_players "$disconnected_player"
    fi
    
    if [ $has_mod_connected -eq 0 ]; then
        cleanup_modlist_if_no_verified_players "$disconnected_player"
    fi
    
    if [ $has_super_connected -eq 0 ]; then
        cleanup_cloud_adminlist_if_no_verified_players "$disconnected_player"
    fi
}

# =============================================================================
# GESTIÓN DE CONTRASEÑAS
# =============================================================================

start_password_reminder_timer() {
    local player_name="$1"
    
    (
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
                    log_debug "Kicking $player_name for not setting password within 60 seconds"
                    execute_server_command "/kick $player_name"
                fi
            fi
        fi
    ) &
    
    active_timers["password_kick_$player_name"]=$!
}

start_password_enforcement() {
    local player_name="$1"
    
    log_debug "Starting password enforcement for $player_name"
    
    start_password_reminder_timer "$player_name"
    start_password_kick_timer "$player_name"
}

handle_password_creation() {
    local player_name="$1" password="$2" confirm_password="$3"
    
    log_debug "Password creation requested for $player_name"
    
    execute_server_command "/clear"
    
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
        
        log_debug "IP verification successful for $player_name"
        execute_server_command "SECURITY: $player_name IP verification successful."
        
        # Aplicar rangos pendientes y listas ahora que está verificado
        apply_pending_ranks "$player_name"
        start_rank_application_timer "$player_name"
        
        send_server_command "$SCREEN_SESSION" "SUCCESS: $player_name, your IP has been verified and updated."
        return 0
    else
        send_server_command "$SCREEN_SESSION" "ERROR: $player_name, player not found in registry."
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
                ;;
        esac
        
        log_debug "Removed rank $rank for disconnected player: $player_name"
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
    
    return 1
}

# =============================================================================
# MONITORES PRINCIPALES
# =============================================================================

monitor_console_log() {
    print_header "STARTING CONSOLE LOG MONITOR"
    log_debug "Starting console log monitor"
    
    local wait_time=0
    while [ ! -f "$CONSOLE_LOG" ] && [ $wait_time -lt 30 ]; do
        sleep 1
        ((wait_time++))
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
                    log_debug "IP changed for $player_name: $first_ip -> $player_ip, requiring verification"
                    player_verification_status["$player_name"]="pending"
                    
                    if [ "$rank" != "NONE" ]; then
                        log_debug "Player has rank $rank but IP not verified - storing as pending and checking list cleanup"
                        pending_ranks["$player_name"]="$rank"
                        
                        # Iniciar verificación de limpieza de listas después de 1 segundo
                        check_and_cleanup_unverified_lists "$player_name"
                    fi
                    
                    # Iniciar advertencia de verificación de IP después de 5 segundos
                    start_ip_verification_warning "$player_name" "$player_ip"
                fi
                
                if [ "$password" = "NONE" ]; then
                    log_debug "Existing player $player_name has no password, starting enforcement"
                    start_password_enforcement "$player_name"
                fi
                
                if [ "${player_verification_status[$player_name]}" = "verified" ]; then
                    log_debug "Starting rank application timer for verified player: $player_name"
                    start_rank_application_timer "$player_name"
                else
                    log_debug "Player $player_name not verified, delaying rank application"
                fi
            fi
            
        elif [[ "$line" =~ Player\ Disconnected\ (.+) ]]; then
            local player_name="${BASH_REMATCH[1]}"
            player_name=$(echo "$player_name" | xargs)
            
            if is_valid_player_name "$player_name"; then
                log_debug "Player disconnected: $player_name"
                
                cancel_player_timers "$player_name"
                
                log_debug "Starting disconnect timer for: $player_name"
                start_disconnect_timer "$player_name"
                
                unset connected_players["$player_name"]
                unset player_ip_map["$player_name"]
                unset player_verification_status["$player_name"]
                unset player_password_reminder_sent["$player_name"]
                unset pending_ranks["$player_name"]
            fi
            
        elif [[ "$line" =~ ([a-zA-Z0-9_]+):\ (.+)$ ]]; then
            local player_name="${BASH_REMATCH[1]}"
            local message="${BASH_REMATCH[2]}"
            local current_ip="${player_ip_map[$player_name]}"
            
            player_name=$(echo "$player_name" | xargs)
            
            if is_valid_player_name "$player_name"; then
                log_debug "Chat command detected from $player_name: $message"
                
                case "$message" in
                    "!psw "*)
                        log_debug "Password set command detected from $player_name"
                        if [[ "$message" =~ !psw\ ([^[:space:]]+)\ ([^[:space:]]+)$ ]]; then
                            local password="${BASH_REMATCH[1]}"
                            local confirm_password="${BASH_REMATCH[2]}"
                            handle_password_creation "$player_name" "$password" "$confirm_password"
                        else
                            execute_server_command "/clear"
                            send_server_command "$SCREEN_SESSION" "ERROR: $player_name, invalid format! Example: !psw Mypassword123 Mypassword123"
                        fi
                        ;;
                    "!ip_change "*)
                        log_debug "IP change command detected from $player_name"
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
    
    for timer_key in "${!ip_verification_timers[@]}"; do
        local pid="${ip_verification_timers[$timer_key]}"
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
    
    print_step "Starting console.log monitor..."
    monitor_console_log &
    
    print_header "RANK PATCHER IS NOW RUNNING"
    print_status "Monitoring: $CONSOLE_LOG"
    print_status "Managing: $PLAYERS_LOG"
    print_status "Debug log: $PATCH_DEBUG_LOG"
    print_status "Server session: $SCREEN_SESSION"
    
    wait
}

main "$@"
