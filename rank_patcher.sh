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

DEBUG_LOG_ENABLED=1

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
        log_debug "Updated player in players.log: $player_name | $first_ip | $password | $rank | $whitelisted | $blacklisted"
    fi
}

# FUNCIÓN MEJORADA: Verificar si un jugador está verificado
is_player_verified() {
    local player_name="$1"
    local current_ip="${player_ip_map[$player_name]}"
    
    if [ -z "$current_ip" ] || [ "$current_ip" = "UNKNOWN" ]; then
        log_debug "is_player_verified: $player_name - IP vacía o UNKNOWN"
        return 1
    fi
    
    local player_info=$(get_player_info "$player_name")
    if [ -n "$player_info" ]; then
        local first_ip=$(echo "$player_info" | cut -d'|' -f1)
        
        # Verificar si la IP actual coincide con la IP registrada
        if [ "$first_ip" = "$current_ip" ]; then
            log_debug "is_player_verified: $player_name - IP COINCIDE ($first_ip = $current_ip) - VERIFICADO"
            return 0
        fi
        
        # Verificar si el jugador ha sido verificado manualmente
        if [ "${player_verification_status[$player_name]}" = "verified" ]; then
            log_debug "is_player_verified: $player_name - VERIFICADO MANUALMENTE"
            return 0
        fi
    fi
    
    log_debug "is_player_verified: $player_name - NO VERIFICADO (IP registrada: $first_ip, IP actual: $current_ip)"
    return 1
}

# FUNCIÓN COMPLETAMENTE REESCRITA: Solo crear listas para jugadores verificados
create_list_if_needed() {
    local player_name="$1"
    local rank="$2"
    local world_dir="$BASE_SAVES_DIR/$WORLD_ID"
    
    log_debug "create_list_if_needed: Verificando si se debe crear lista para $player_name con rango $rank"
    
    # VERIFICACIÓN CRÍTICA: Si el jugador no está verificado, NO CREAR LISTAS
    if ! is_player_verified "$player_name"; then
        log_debug "create_list_if_needed: JUGADOR NO VERIFICADO - NO SE CREARÁN LISTAS para $player_name"
        return
    fi
    
    # Verificar si hay al menos un jugador VERIFICADO con este rango antes de crear la lista
    local has_verified_player_with_rank=0
    for player in "${!connected_players[@]}"; do
        if is_player_verified "$player"; then
            local player_info=$(get_player_info "$player")
            if [ -n "$player_info" ]; then
                local player_rank=$(echo "$player_info" | cut -d'|' -f3)
                if [ "$player_rank" = "$rank" ]; then
                    has_verified_player_with_rank=1
                    log_debug "create_list_if_needed: Jugador verificado $player con rango $rank - se creará lista"
                    break
                fi
            fi
        fi
    done
    
    if [ $has_verified_player_with_rank -eq 0 ]; then
        log_debug "create_list_if_needed: NO hay jugadores VERIFICADOS con rango $rank - NO se creará lista"
        return
    fi
    
    log_debug "create_list_if_needed: CREANDO lista para rango $rank (jugadores verificados encontrados)"
    
    case "$rank" in
        "MOD")
            local mod_list="$world_dir/modlist.txt"
            if [ ! -f "$mod_list" ]; then
                log_debug "CREANDO modlist.txt usando CREATE_LIST"
                execute_server_command "/mod CREATE_LIST"
                (
                    sleep 2
                    execute_server_command "/unmod CREATE_LIST"
                    log_debug "Removed CREATE_LIST from modlist"
                ) &
            else
                log_debug "modlist.txt ya existe, omitiendo creación"
            fi
            ;;
        "ADMIN"|"SUPER")
            local admin_list="$world_dir/adminlist.txt"
            if [ ! -f "$admin_list" ]; then
                log_debug "CREANDO adminlist.txt usando CREATE_LIST"
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
                log_debug "adminlist.txt ya existe, omitiendo creación"
            fi
            ;;
    esac
}

# FUNCIÓN MODIFICADA: Solo iniciar timer de rango si está verificado
start_rank_application_timer() {
    local player_name="$1"
    
    log_debug "start_rank_application_timer: Iniciando para $player_name"
    
    # VERIFICACIÓN CRÍTICA: Solo crear lista y aplicar rango si el jugador está VERIFICADO
    if [ -n "${connected_players[$player_name]}" ] && is_player_verified "$player_name"; then
        local player_info=$(get_player_info "$player_name")
        if [ -n "$player_info" ]; then
            local rank=$(echo "$player_info" | cut -d'|' -f3)
            if [ "$rank" != "NONE" ]; then
                log_debug "start_rank_application_timer: Jugador $player_name VERIFICADO con rango $rank - creando lista si es necesario"
                
                # Pasar el nombre del jugador a create_list_if_needed para verificación adicional
                create_list_if_needed "$player_name" "$rank"
                
                # Paso 2: Esperar 5 segundos y aplicar el rango solo si está verificado
                (
                    sleep 5
                    if [ -n "${connected_players[$player_name]}" ] && is_player_verified "$player_name"; then
                        log_debug "start_rank_application_timer: Timer de 5 segundos completado, aplicando rango a jugador verificado: $player_name"
                        apply_rank_to_connected_player "$player_name"
                    else
                        log_debug "start_rank_application_timer: Timer de 5 segundos completado pero $player_name no verificado o desconectado"
                    fi
                ) &
                
                active_timers["rank_application_$player_name"]=$!
            else
                log_debug "start_rank_application_timer: Jugador $player_name verificado pero sin rango, omitiendo aplicación"
            fi
        fi
    else
        log_debug "start_rank_application_timer: JUGADOR NO VERIFICADO - NO se creará lista NI se aplicará rango para $player_name"
    fi
}

# FUNCIÓN MODIFICADA: Solo limpiar listas basado en jugadores verificados
cleanup_empty_lists_after_disconnect() {
    local disconnected_player="$1"
    local world_dir="$BASE_SAVES_DIR/$WORLD_ID"
    local admin_list="$world_dir/adminlist.txt"
    local mod_list="$world_dir/modlist.txt"
    
    local has_admin_connected=0
    local has_mod_connected=0
    local has_super_connected=0
    
    log_debug "cleanup_empty_lists_after_disconnect: Limpiando listas después de desconexión de $disconnected_player"
    
    # Verificar si hay otros jugadores VERIFICADOS conectados con los rangos
    for player in "${!connected_players[@]}"; do
        if [ "$player" = "$disconnected_player" ]; then
            continue
        fi
        
        # Solo contar jugadores VERIFICADOS
        if ! is_player_verified "$player"; then
            continue
        fi
        
        local player_info=$(get_player_info "$player")
        if [ -n "$player_info" ]; then
            local rank=$(echo "$player_info" | cut -d'|' -f3)
            case "$rank" in
                "ADMIN")
                    has_admin_connected=1
                    log_debug "cleanup_empty_lists: Admin verificado conectado: $player"
                    ;;
                "MOD")
                    has_mod_connected=1
                    log_debug "cleanup_empty_lists: Mod verificado conectado: $player"
                    ;;
                "SUPER")
                    has_admin_connected=1
                    has_super_connected=1
                    log_debug "cleanup_empty_lists: Super Admin verificado conectado: $player"
                    ;;
            esac
        fi
    done
    
    log_debug "cleanup_empty_lists: Admin conectados: $has_admin_connected, Mod conectados: $has_mod_connected, Super conectados: $has_super_connected"
    
    # Eliminar listas solo si no hay jugadores VERIFICADOS con ese rango conectados
    if [ $has_admin_connected -eq 0 ] && [ -f "$admin_list" ]; then
        rm -f "$admin_list"
        log_debug "ELIMINADO adminlist.txt (no hay admins verificados conectados)"
    else
        log_debug "MANTENIENDO adminlist.txt (hay admins verificados conectados)"
    fi
    
    if [ $has_mod_connected -eq 0 ] && [ -f "$mod_list" ]; then
        rm -f "$mod_list"
        log_debug "ELIMINADO modlist.txt (no hay mods verificados conectados)"
    else
        log_debug "MANTENIENDO modlist.txt (hay mods verificados conectados)"
    fi
    
    # Para la lista cloud, usar la misma lógica que para adminlist
    if [ $has_super_connected -eq 0 ]; then
        remove_cloud_admin_file_if_empty
    fi
}

remove_cloud_admin_file_if_empty() {
    local cloud_file="$HOME_DIR/GNUstep/Library/ApplicationSupport/TheBlockheads/cloudWideOwnedAdminlist.txt"
    
    if [ -f "$cloud_file" ]; then
        # Contar líneas válidas (excluyendo líneas vacías y la línea especial CREATE_LIST)
        local valid_lines=$(grep -v -e '^$' -e '^CREATE_LIST$' "$cloud_file" | wc -l)
        
        if [ $valid_lines -eq 0 ]; then
            rm -f "$cloud_file"
            log_debug "ELIMINADO archivo cloud admin (no hay super admins restantes)"
        else
            log_debug "MANTENIENDO archivo cloud admin (todavía tiene $valid_lines super admin(s) válidos)"
        fi
    fi
}

cancel_disconnect_timer() {
    local player_name="$1"
    
    if [ -n "${disconnect_timers[$player_name]}" ]; then
        local pid="${disconnect_timers[$player_name]}"
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            log_debug "cancel_disconnect_timer: Timer cancelado para $player_name (PID: $pid)"
        fi
        unset disconnect_timers["$player_name"]
    fi
}

remove_player_rank() {
    local player_name="$1"
    
    log_debug "remove_player_rank: Removiendo rango para jugador desconectado: $player_name"
    
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
                # Para SUPER, remover inmediatamente de la lista cloud
                remove_from_cloud_admin "$player_name"
                # Iniciar timer para verificar si hay otros SUPER admins
                start_super_disconnect_timer "$player_name"
                ;;
        esac
        
        log_debug "remove_player_rank: Rango $rank removido para jugador desconectado: $player_name"
    fi
}

# FUNCIÓN MODIFICADA: Solo aplicar rango si está verificado
apply_rank_to_connected_player() {
    local player_name="$1"
    
    if [ -z "${connected_players[$player_name]}" ]; then
        log_debug "apply_rank_to_connected_player: Jugador $player_name no conectado, omitiendo"
        return
    fi
    
    if ! is_player_verified "$player_name"; then
        log_debug "apply_rank_to_connected_player: JUGADOR NO VERIFICADO - NO se aplicará rango a $player_name"
        return
    fi
    
    local player_info=$(get_player_info "$player_name")
    if [ -z "$player_info" ]; then
        log_debug "apply_rank_to_connected_player: No se encontró información para $player_name"
        return
    fi
    
    local first_ip=$(echo "$player_info" | cut -d'|' -f1)
    local password=$(echo "$player_info" | cut -d'|' -f2)
    local rank=$(echo "$player_info" | cut -d'|' -f3)
    local whitelisted=$(echo "$player_info" | cut -d'|' -f4)
    local blacklisted=$(echo "$player_info" | cut -d'|' -f5)
    local current_ip="${player_ip_map[$player_name]}"
    
    log_debug "apply_rank_to_connected_player: Aplicando rango a jugador verificado: $player_name (Rango: $rank)"
    
    if [ "$password" = "NONE" ]; then
        log_debug "apply_rank_to_connected_player: Jugador $player_name sin contraseña, omitiendo aplicación de rango"
        return
    fi
    
    case "$rank" in
        "MOD")
            execute_server_command "/mod $player_name"
            current_player_ranks["$player_name"]="$rank"
            log_debug "apply_rank_to_connected_player: Rango MOD aplicado a $player_name"
            ;;
        "ADMIN")
            execute_server_command "/admin $player_name"
            current_player_ranks["$player_name"]="$rank"
            log_debug "apply_rank_to_connected_player: Rango ADMIN aplicado a $player_name"
            ;;
        "SUPER")
            execute_server_command "/admin $player_name"
            add_to_cloud_admin "$player_name"
            current_player_ranks["$player_name"]="$rank"
            log_debug "apply_rank_to_connected_player: Rango SUPER aplicado a $player_name"
            ;;
    esac
    
    if [ "$whitelisted" = "YES" ] && [ -n "$current_ip" ] && [ "$current_ip" != "UNKNOWN" ]; then
        execute_server_command "/whitelist $current_ip"
        log_debug "apply_rank_to_connected_player: IP $current_ip agregada a whitelist para $player_name"
    fi
    
    if [ "$blacklisted" = "YES" ]; then
        execute_server_command "/ban $player_name"
        if [ -n "$current_ip" ] && [ "$current_ip" != "UNKNOWN" ]; then
            execute_server_command "/ban $current_ip"
        fi
        log_debug "apply_rank_to_connected_player: Jugador $player_name baneado"
    fi
}

# FUNCIÓN MODIFICADA: Solo sincronizar listas para jugadores verificados
sync_lists_from_players_log() {
    log_debug "sync_lists_from_players_log: Sincronizando listas desde players.log..."
    
    if [ -z "${list_files_initialized["$WORLD_ID"]}" ]; then
        log_debug "sync_lists_from_players_log: Primera sincronización para mundo $WORLD_ID, forzando recarga completa"
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
            
            # VERIFICACIÓN CRÍTICA: Solo aplicar rangos si el jugador está VERIFICADO
            if ! is_player_verified "$name"; then
                log_debug "sync_lists_from_players_log: JUGADOR NO VERIFICADO - OMITIENDO aplicación de rango para $name"
                if [ "$rank" != "NONE" ]; then
                    pending_ranks["$name"]="$rank"
                    log_debug "sync_lists_from_players_log: Rango pendiente guardado para $name: $rank"
                fi
                continue
            fi
            
            local current_ip="${player_ip_map[$name]}"
            
            local current_rank="${current_player_ranks[$name]}"
            if [ "$current_rank" != "$rank" ]; then
                log_debug "sync_lists_from_players_log: Cambio de rango detectado para $name: $current_rank -> $rank"
                apply_rank_changes "$name" "$current_rank" "$rank"
                current_player_ranks["$name"]="$rank"
            fi
            
            local current_blacklisted="${current_blacklisted_players[$name]}"
            if [ "$current_blacklisted" != "$blacklisted" ]; then
                log_debug "sync_lists_from_players_log: Cambio en blacklist detectado para $name: $current_blacklisted -> $blacklisted"
                handle_blacklist_change "$name" "$blacklisted"
                current_blacklisted_players["$name"]="$blacklisted"
            fi
            
            local current_whitelisted="${current_whitelisted_players[$name]}"
            if [ "$current_whitelisted" != "$whitelisted" ]; then
                log_debug "sync_lists_from_players_log: Cambio en whitelist detectado para $name: $current_whitelisted -> $whitelisted"
                handle_whitelist_change "$name" "$whitelisted" "$current_ip"
                current_whitelisted_players["$name"]="$whitelisted"
            fi
            
        done < "$PLAYERS_LOG"
    fi
    
    log_debug "sync_lists_from_players_log: Sincronización completada"
}

# FUNCIÓN MODIFICADA: Solo forzar recarga para jugadores verificados
force_reload_all_lists() {
    log_debug "=== FORZANDO RECARGA COMPLETA DE TODAS LAS LISTAS DESDE PLAYERS.LOG ==="
    
    if [ ! -f "$PLAYERS_LOG" ]; then
        log_debug "force_reload_all_lists: No se encontró players.log, omitiendo recarga"
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
        
        # VERIFICACIÓN CRÍTICA: SOLO recargar rangos para jugadores VERIFICADOS
        if ! is_player_verified "$name"; then
            log_debug "force_reload_all_lists: JUGADOR NO VERIFICADO - OMITIENDO recarga forzada para $name"
            continue
        fi
        
        if [ "$rank" != "NONE" ]; then
            log_debug "force_reload_all_lists: Recargando jugador desde players.log: $name (Rango: $rank)"
            
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
    
    log_debug "=== RECARGA COMPLETA DE TODAS LAS LISTAS FINALIZADA ==="
}

# FUNCIÓN MODIFICADA: Solo aplicar rangos pendientes si está verificado
apply_pending_ranks() {
    local player_name="$1"
    
    if [ -n "${pending_ranks[$player_name]}" ]; then
        local pending_rank="${pending_ranks[$player_name]}"
        log_debug "apply_pending_ranks: Aplicando rango pendiente para $player_name: $pending_rank"
        
        # Solo aplicar rangos pendientes si el jugador está VERIFICADO
        if ! is_player_verified "$player_name"; then
            log_debug "apply_pending_ranks: NO SE PUEDE aplicar rango pendiente para $player_name - NO VERIFICADO"
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
        log_debug "apply_pending_ranks: Rango pendiente $pending_rank aplicado exitosamente a $player_name"
    fi
}

handle_whitelist_change() {
    local player_name="$1" whitelisted="$2" current_ip="$3"
    
    log_debug "handle_whitelist_change: Manejando cambio de whitelist: $player_name -> $whitelisted (IP: $current_ip)"
    
    if [ "$whitelisted" = "YES" ] && [ -n "$current_ip" ] && [ "$current_ip" != "UNKNOWN" ]; then
        log_debug "handle_whitelist_change: Agregando IP a whitelist: $current_ip para jugador $player_name"
        execute_server_command "/whitelist $current_ip"
    elif [ "$whitelisted" = "NO" ] && [ -n "$current_ip" ] && [ "$current_ip" != "UNKNOWN" ]; then
        log_debug "handle_whitelist_change: Removiendo IP de whitelist: $current_ip para jugador $player_name"
        execute_server_command "/unwhitelist $current_ip"
    fi
}

# FUNCIÓN MODIFICADA: Solo aplicar cambios de rango si está verificado
apply_rank_changes() {
    local player_name="$1" old_rank="$2" new_rank="$3"
    
    log_debug "apply_rank_changes: Aplicando cambio de rango: $player_name de $old_rank a $new_rank"
    
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
        # VERIFICACIÓN CRÍTICA: Solo aplicar nuevo rango si el jugador está VERIFICADO
        if ! is_player_verified "$player_name"; then
            log_debug "apply_rank_changes: NO SE PUEDE aplicar nuevo rango a $player_name - NO VERIFICADO"
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

start_super_disconnect_timer() {
    local player_name="$1"
    
    log_debug "start_super_disconnect_timer: Iniciando timer de 10 segundos para SUPER: $player_name"
    
    (
        sleep 10
        log_debug "start_super_disconnect_timer: Timer de 10 segundos completado, verificando si hay otros SUPER admins VERIFICADOS conectados"
        
        local has_other_super_admins=0
        for connected_player in "${!connected_players[@]}"; do
            if [ "$connected_player" != "$player_name" ]; then
                # Solo contar jugadores VERIFICADOS
                if ! is_player_verified "$connected_player"; then
                    continue
                fi
                
                local player_info=$(get_player_info "$connected_player")
                if [ -n "$player_info" ]; then
                    local rank=$(echo "$player_info" | cut -d'|' -f3)
                    if [ "$rank" = "SUPER" ]; then
                        has_other_super_admins=1
                        log_debug "start_super_disconnect_timer: Encontrado otro SUPER admin VERIFICADO conectado: $connected_player"
                        break
                    fi
                fi
            fi
        done
        
        if [ $has_other_super_admins -eq 0 ]; then
            log_debug "start_super_disconnect_timer: No hay otros SUPER admins VERIFICADOS conectados, eliminando archivo cloud admin"
            remove_cloud_admin_file_if_empty
        else
            log_debug "start_super_disconnect_timer: Otros SUPER admins VERIFICADOS todavía conectados, manteniendo archivo cloud admin"
        fi
        
        unset super_admin_disconnect_timers["$player_name"]
    ) &
    
    super_admin_disconnect_timers["$player_name"]=$!
    log_debug "start_super_disconnect_timer: Timer SUPER iniciado para $player_name (PID: ${super_admin_disconnect_timers[$player_name]})"
}

cancel_super_disconnect_timer() {
    local player_name="$1"
    
    if [ -n "${super_admin_disconnect_timers[$player_name]}" ]; then
        local pid="${super_admin_disconnect_timers[$player_name]}"
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            log_debug "cancel_super_disconnect_timer: Timer SUPER cancelado para $player_name (PID: $pid)"
        fi
        unset super_admin_disconnect_timers["$player_name"]
    fi
}

add_to_cloud_admin() {
    local player_name="$1"
    local cloud_file="$HOME_DIR/GNUstep/Library/ApplicationSupport/TheBlockheads/cloudWideOwnedAdminlist.txt"
    
    [ ! -f "$cloud_file" ] && touch "$cloud_file"
    
    # Verificar si el jugador ya está en la lista
    if ! grep -q "^$player_name$" "$cloud_file" 2>/dev/null; then
        echo "$player_name" >> "$cloud_file"
        log_debug "add_to_cloud_admin: $player_name agregado a la lista cloud admin"
    fi
}

remove_from_cloud_admin() {
    local player_name="$1"
    local cloud_file="$HOME_DIR/GNUstep/Library/ApplicationSupport/TheBlockheads/cloudWideOwnedAdminlist.txt"
    
    if [ -f "$cloud_file" ]; then
        local temp_file=$(mktemp)
        
        # Filtrar el nombre del jugador, manteniendo todas las líneas excepto la del jugador específico
        grep -v "^$player_name$" "$cloud_file" > "$temp_file"
        
        # Verificar si el archivo temporal tiene contenido
        if [ -s "$temp_file" ]; then
            mv "$temp_file" "$cloud_file"
            log_debug "remove_from_cloud_admin: $player_name removido de la lista cloud admin"
        else
            rm -f "$cloud_file"
            rm -f "$temp_file"
            log_debug "remove_from_cloud_admin: Archivo cloud admin eliminado (no hay super admins restantes después de remover $player_name)"
        fi
    fi
}

handle_blacklist_change() {
    local player_name="$1" blacklisted="$2"
    
    log_debug "handle_blacklist_change: Manejando cambio de blacklist: $player_name -> $blacklisted"
    
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
            
            log_debug "handle_blacklist_change: Jugador $player_name blacklisteado"
        else
            execute_server_command "/unban $player_name"
            if [ -n "$current_ip" ] && [ "$current_ip" != "UNKNOWN" ]; then
                execute_server_command "/unban $current_ip"
            fi
            log_debug "handle_blacklist_change: $player_name removido de blacklist"
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
                log_debug "monitor_list_files: Cambio detectado en adminlist.txt - forzando recarga desde players.log"
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
                log_debug "monitor_list_files: Cambio detectado en modlist.txt - forzando recarga desde players.log"
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
                log_debug "monitor_players_log: Cambio detectado en players.log - procesando cambios..."
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
                log_debug "process_players_log_changes: Cambio de rango detectado: $name de $prev_rank a $rank"
                apply_rank_changes "$name" "$prev_rank" "$rank"
            fi
            
            if [ "$prev_blacklisted" != "$blacklisted" ]; then
                log_debug "process_players_log_changes: Cambio en blacklist detectado: $name de $prev_blacklisted a $blacklisted"
                handle_blacklist_change "$name" "$blacklisted"
            fi
            
            if [ "$prev_whitelisted" != "$whitelisted" ]; then
                log_debug "process_players_log_changes: Cambio en whitelist detectado: $name de $prev_whitelisted a $whitelisted"
                local current_ip="${player_ip_map[$name]}"
                handle_whitelist_change "$name" "$whitelisted" "$current_ip"
            fi
        fi
    done < "$PLAYERS_LOG"
    
    sync_lists_from_players_log
}

cancel_player_timers() {
    local player_name="$1"
    
    log_debug "cancel_player_timers: Cancelando todos los timers para: $player_name"
    
    if [ -n "${active_timers["password_reminder_$player_name"]}" ]; then
        local pid="${active_timers["password_reminder_$player_name"]}"
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            log_debug "cancel_player_timers: Timer de recordatorio de contraseña cancelado para $player_name (PID: $pid)"
        fi
        unset active_timers["password_reminder_$player_name"]
    fi
    
    if [ -n "${active_timers["password_kick_$player_name"]}" ]; then
        local pid="${active_timers["password_kick_$player_name"]}"
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            log_debug "cancel_player_timers: Timer de kick por contraseña cancelado para $player_name (PID: $pid)"
        fi
        unset active_timers["password_kick_$player_name"]
    fi
    
    if [ -n "${active_timers["ip_grace_$player_name"]}" ]; then
        local pid="${active_timers["ip_grace_$player_name"]}"
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            log_debug "cancel_player_timers: Timer de gracia de IP cancelado para $player_name (PID: $pid)"
        fi
        unset active_timers["ip_grace_$player_name"]
    fi
    
    if [ -n "${active_timers["rank_application_$player_name"]}" ]; then
        local pid="${active_timers["rank_application_$player_name"]}"
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            log_debug "cancel_player_timers: Timer de aplicación de rango cancelado para $player_name (PID: $pid)"
        fi
        unset active_timers["rank_application_$player_name"]
    fi
    
    cancel_disconnect_timer "$player_name"
    cancel_super_disconnect_timer "$player_name"
}

start_password_reminder_timer() {
    local player_name="$1"
    
    (
        log_debug "start_password_reminder_timer: Timer de recordatorio de contraseña iniciado para $player_name"
        sleep 5
        
        if [ -n "${connected_players[$player_name]}" ]; then
            local player_info=$(get_player_info "$player_name")
            if [ -n "$player_info" ]; then
                local password=$(echo "$player_info" | cut -d'|' -f2)
                if [ "$password" = "NONE" ]; then
                    log_debug "start_password_reminder_timer: Enviando recordatorio de contraseña a $player_name"
                    execute_server_command "SECURITY: $player_name, set your password within 60 seconds!"
                    sleep 1
                    execute_server_command "Example of use: !psw Mypassword123 Mypassword123"
                    player_password_reminder_sent["$player_name"]=1
                fi
            fi
        fi
        log_debug "start_password_reminder_timer: Timer de recordatorio de contraseña completado para $player_name"
    ) &
    
    active_timers["password_reminder_$player_name"]=$!
    log_debug "start_password_reminder_timer: Timer de recordatorio de contraseña independiente iniciado para $player_name (PID: ${active_timers["password_reminder_$player_name"]})"
}

start_password_kick_timer() {
    local player_name="$1"
    
    (
        log_debug "start_password_kick_timer: Timer de kick por contraseña iniciado para $player_name"
        sleep 60
        
        if [ -n "${connected_players[$player_name]}" ]; then
            local player_info=$(get_player_info "$player_name")
            if [ -n "$player_info" ]; then
                local password=$(echo "$player_info" | cut -d'|' -f2)
                if [ "$password" = "NONE" ]; then
                    log_debug "start_password_kick_timer: Kickeando $player_name por no establecer contraseña en 60 segundos"
                    execute_server_command "/kick $player_name"
                else
                    log_debug "start_password_kick_timer: Jugador $player_name estableció contraseña, no se necesita kick"
                fi
            fi
        fi
        log_debug "start_password_kick_timer: Timer de kick por contraseña completado para $player_name"
    ) &
    
    active_timers["password_kick_$player_name"]=$!
    log_debug "start_password_kick_timer: Timer de kick por contraseña independiente iniciado para $player_name (PID: ${active_timers["password_kick_$player_name"]})"
}

start_ip_grace_timer() {
    local player_name="$1" current_ip="$2"
    
    (
        log_debug "start_ip_grace_timer: Timer de gracia de IP iniciado para $player_name con IP $current_ip"
        
        sleep 5
        if [ -n "${connected_players[$player_name]}" ]; then
            local player_info=$(get_player_info "$player_name")
            if [ -n "$player_info" ]; then
                local first_ip=$(echo "$player_info" | cut -d'|' -f1)
                if [ "$first_ip" != "UNKNOWN" ] && [ "$first_ip" != "$current_ip" ]; then
                    log_debug "start_ip_grace_timer: Cambio de IP detectado para $player_name: $first_ip -> $current_ip"
                    execute_server_command "SECURITY ALERT: $player_name, your IP has changed!"
                    sleep 1
                    execute_server_command "Verify with !ip_change + YOUR_PASSWORD within 25 seconds!"
                    sleep 1
                    execute_server_command "Else you'll get kicked and a temporal ip ban for 30 seconds."
                    sleep 25
                    if [ -n "${connected_players[$player_name]}" ] && ! is_player_verified "$player_name"; then
                        log_debug "start_ip_grace_timer: Verificación de IP falló para $player_name, kickeando y baneando"
                        execute_server_command "/kick $player_name"
                        execute_server_command "/ban $current_ip"
                        
                        (
                            sleep 30
                            execute_server_command "/unban $current_ip"
                            log_debug "start_ip_grace_timer: IP auto-unbaneada: $current_ip"
                        ) &
                    fi
                fi
            fi
        fi
        log_debug "start_ip_grace_timer: Timer de gracia de IP completado para $player_name"
    ) &
    
    active_timers["ip_grace_$player_name"]=$!
    log_debug "start_ip_grace_timer: Timer de gracia de IP independiente iniciado para $player_name (PID: ${active_timers["ip_grace_$player_name"]})"
}

start_password_enforcement() {
    local player_name="$1"
    
    log_debug "start_password_enforcement: Iniciando enforcement de contraseña INDEPENDIENTE para $player_name"
    
    start_password_reminder_timer "$player_name"
    start_password_kick_timer "$player_name"
}

handle_password_creation() {
    local player_name="$1" password="$2" confirm_password="$3"
    
    log_debug "handle_password_creation: IMMEDIATE: Creación de contraseña solicitada para $player_name"
    
    execute_server_command "/clear"
    
    log_debug "handle_password_creation: IMMEDIATE: Validando contraseña para $player_name"
    
    if [ ${#password} -lt 7 ] || [ ${#password} -gt 16 ]; then
        log_debug "handle_password_creation: IMMEDIATE: Validación de contraseña falló: longitud inválida (${#password} caracteres)"
        send_server_command "$SCREEN_SESSION" "ERROR: $player_name, password must be between 7 and 16 characters."
        return 1
    fi
    
    if [ "$password" != "$confirm_password" ]; then
        log_debug "handle_password_creation: IMMEDIATE: Validación de contraseña falló: las contraseñas no coinciden"
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
        
        log_debug "handle_password_creation: IMMEDIATE: Información de jugador encontrada para $player_name, cancelando TODOS los timers"
        
        cancel_player_timers "$player_name"
        
        log_debug "handle_password_creation: IMMEDIATE: Actualizando players.log con nueva contraseña para $player_name"
        update_player_info "$player_name" "$first_ip" "$password" "$rank" "$whitelisted" "$blacklisted"
        
        log_debug "handle_password_creation: IMMEDIATE: Contraseña establecida exitosamente para $player_name"
        send_server_command "$SCREEN_SESSION" "SUCCESS: $player_name, password set successfully."
        return 0
    else
        log_debug "handle_password_creation: IMMEDIATE: Información de jugador NO encontrada para $player_name"
        send_server_command "$SCREEN_SESSION" "ERROR: $player_name, player not found in registry."
        return 1
    fi
}

handle_password_change() {
    local player_name="$1" old_password="$2" new_password="$3"
    
    log_debug "handle_password_change: Cambio de contraseña solicitado para $player_name"
    
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

handle_ip_change() {
    local player_name="$1" password="$2" current_ip="$3"
    
    log_debug "handle_ip_change: Verificación de cambio de IP solicitada para $player_name"
    
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
        
        log_debug "handle_ip_change: Verificación de IP exitosa para $player_name - cancelando kick/ban IP cooldown"
        execute_server_command "SECURITY: $player_name IP verification successful."
        
        log_debug "handle_ip_change: Aplicando rangos pendientes para $player_name después de verificación de IP"
        apply_pending_ranks "$player_name"
        
        # Ahora iniciar el temporizador de aplicación de rango para el jugador verificado
        start_rank_application_timer "$player_name"
        
        sync_lists_from_players_log
        
        send_server_command "$SCREEN_SESSION" "SUCCESS: $player_name, your IP has been verified and updated."
        return 0
    else
        send_server_command "$SCREEN_SESSION" "ERROR: $player_name, player not found in registry."
        return 1
    fi
}

monitor_console_log() {
    print_header "INICIANDO MONITOR DE CONSOLE LOG"
    log_debug "monitor_console_log: Iniciando monitor de console log"
    
    local wait_time=0
    while [ ! -f "$CONSOLE_LOG" ] && [ $wait_time -lt 30 ]; do
        sleep 1
        ((wait_time++))
        [ $((wait_time % 5)) -eq 0 ] && log_debug "monitor_console_log: Esperando que console.log sea creado..."
    done
    
    if [ ! -f "$CONSOLE_LOG" ]; then
        log_debug "monitor_console_log: ERROR: Console log nunca apareció: $CONSOLE_LOG"
        return 1
    fi
    
    log_debug "monitor_console_log: Console log encontrado, iniciando monitoreo"
    
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
            
            log_debug "monitor_console_log: Jugador conectado: $player_name ($player_ip)"
            
            local player_info=$(get_player_info "$player_name")
            if [ -z "$player_info" ]; then
                log_debug "monitor_console_log: Nuevo jugador detectado: $player_name, agregando a players.log con IP: $player_ip"
                update_player_info "$player_name" "$player_ip" "NONE" "NONE" "NO" "NO"
                player_verification_status["$player_name"]="verified"
                start_password_enforcement "$player_name"
            else
                local first_ip=$(echo "$player_info" | cut -d'|' -f1)
                local password=$(echo "$player_info" | cut -d'|' -f2)
                local rank=$(echo "$player_info" | cut -d'|' -f3)
                local whitelisted=$(echo "$player_info" | cut -d'|' -f4)
                
                log_debug "monitor_console_log: Jugador existente $player_name - Primera IP en DB: $first_ip, IP actual: $player_ip, Rango: $rank"
                
                if [ "$first_ip" = "UNKNOWN" ]; then
                    log_debug "monitor_console_log: Primera conexión real para $player_name, actualizando IP de UNKNOWN a $player_ip"
                    update_player_info "$player_name" "$player_ip" "$password" "$rank" "$whitelisted" "NO"
                    player_verification_status["$player_name"]="verified"
                elif [ "$first_ip" != "$player_ip" ]; then
                    log_debug "monitor_console_log: IP cambiada para $player_name: $first_ip -> $player_ip, requiriendo verificación - NO SE APLICARÁ RANGO"
                    player_verification_status["$player_name"]="pending"
                    
                    if [ "$rank" != "NONE" ]; then
                        log_debug "monitor_console_log: Removiendo rango actual $rank de $player_name hasta verificación de IP"
                        apply_rank_changes "$player_name" "$rank" "NONE"
                        pending_ranks["$player_name"]="$rank"
                    fi
                    
                    start_ip_grace_timer "$player_name" "$player_ip"
                else
                    log_debug "monitor_console_log: IP coincide para $player_name, marcando como verificado"
                    player_verification_status["$player_name"]="verified"
                fi
                
                if [ "$password" = "NONE" ]; then
                    log_debug "monitor_console_log: Jugador existente $player_name sin contraseña, iniciando enforcement"
                    start_password_enforcement "$player_name"
                fi
                
                # VERIFICACIÓN CRÍTICA: SOLO iniciar temporizador de rango si el jugador está VERIFICADO
                if is_player_verified "$player_name"; then
                    log_debug "monitor_console_log: Iniciando timer de aplicación de rango para jugador verificado: $player_name"
                    start_rank_application_timer "$player_name"
                else
                    log_debug "monitor_console_log: JUGADOR NO VERIFICADO - NO se iniciará timer de rango para $player_name"
                fi
            fi
            
            log_debug "monitor_console_log: Forzando recarga de lista debido a conexión de jugador: $player_name"
            sync_lists_from_players_log
            
        fi
        
        if [[ "$line" =~ Player\ Disconnected\ (.+) ]]; then
            local player_name="${BASH_REMATCH[1]}"
            player_name=$(echo "$player_name" | xargs)
            
            if is_valid_player_name "$player_name"; then
                log_debug "monitor_console_log: Jugador desconectado: $player_name"
                
                cancel_player_timers "$player_name"
                
                log_debug "monitor_console_log: Iniciando timer de desconexión de 15 segundos para: $player_name"
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
                log_debug "monitor_console_log: IMMEDIATE: Comando de chat detectado de $player_name: $message"
                
                case "$message" in
                    "!psw "*)
                        log_debug "monitor_console_log: IMMEDIATE: Comando de establecimiento de contraseña detectado de $player_name"
                        if [[ "$message" =~ !psw\ ([^[:space:]]+)\ ([^[:space:]]+)$ ]]; then
                            local password="${BASH_REMATCH[1]}"
                            local confirm_password="${BASH_REMATCH[2]}"
                            log_debug "monitor_console_log: IMMEDIATE: Procesando establecimiento de contraseña para $player_name: $password"
                            handle_password_creation "$player_name" "$password" "$confirm_password"
                        else
                            execute_server_command "/clear"
                            send_server_command "$SCREEN_SESSION" "ERROR: $player_name, invalid format! Example of use: !psw Mypassword123 Mypassword123"
                        fi
                        ;;
                    "!change_psw "*)
                        log_debug "monitor_console_log: IMMEDIATE: Comando de cambio de contraseña detectado de $player_name"
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
                        log_debug "monitor_console_log: IMMEDIATE: Comando de cambio de IP detectado de $player_name"
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
            log_debug "monitor_console_log: Limpieza de lista detectada: $line"
            sleep 2
            log_debug "monitor_console_log: Forzando recarga de todas las listas después de detectar limpieza"
            force_reload_all_lists
        fi
        
    done
}

start_disconnect_timer() {
    local player_name="$1"
    
    log_debug "start_disconnect_timer: Iniciando timer de desconexión para: $player_name"
    
    # Paso 1: Esperar 10 segundos y remover el rango del jugador
    (
        sleep 10
        log_debug "start_disconnect_timer: Timer de desconexión de 10 segundos completado, removiendo rango para: $player_name"
        remove_player_rank "$player_name"
        
        # Paso 2: Esperar 5 segundos adicionales y limpiar listas si es necesario
        sleep 5
        log_debug "start_disconnect_timer: Timer de 15 segundos completado, limpiando listas para: $player_name"
        cleanup_empty_lists_after_disconnect "$player_name"
        
        unset disconnect_timers["$player_name"]
    ) &
    
    disconnect_timers["$player_name"]=$!
    log_debug "start_disconnect_timer: Timer de desconexión iniciado para $player_name (PID: ${disconnect_timers[$player_name]})"
}

cleanup() {
    print_header "LIMPIANDO RANK PATCHER"
    log_debug "=== LIMPIEZA INICIADA ==="
    
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
    
    log_debug "=== LIMPIEZA COMPLETADA ==="
    print_success "Limpieza completada"
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
    print_status "Iniciando rank patcher para puerto: $PORT"
    
    trap cleanup EXIT INT TERM
    
    if ! setup_paths "$PORT"; then
        exit 1
    fi
    
    if ! screen_session_exists "$SCREEN_SESSION"; then
        print_error "No se encontró la sesión de screen del servidor: $SCREEN_SESSION"
        print_status "Por favor inicia el servidor primero usando server_manager.sh"
        exit 1
    fi
    
    print_step "Iniciando monitor de players.log..."
    monitor_players_log &
    
    print_step "Iniciando monitor de console.log..."
    monitor_console_log &
    
    print_step "Iniciando monitor de archivos de lista..."
    monitor_list_files &
    
    print_header "RANK PATCHER ESTÁ EJECUTÁNDOSE"
    print_status "Monitoreando: $CONSOLE_LOG"
    print_status "Gestionando: $PLAYERS_LOG"
    print_status "Debug log: $PATCH_DEBUG_LOG"
    print_status "Sesión del servidor: $SCREEN_SESSION"
    
    wait
}

main "$@"
