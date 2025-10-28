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
WORLD_DIR="" 

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

DELETE_TIMER_PID=""

DEBUG_LOG_ENABLED=1

log_debug() {
    if [ $DEBUG_LOG_ENABLED -eq 1 ]; then
        local message="$1"
        local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        echo "$timestamp $message" >> "$PATCH_DEBUG_LOG"
        # echo -e "${CYAN}[DEBUG]${NC} $message" # Descomentar para debug en consola
    fi
}

start_file_deletion_loop() {
    # Si ya está corriendo, no hacer nada
    if [ -n "$DELETE_TIMER_PID" ] && kill -0 "$DELETE_TIMER_PID" 2>/dev/null; then
        log_debug "Deletion loop is already running."
        return
    fi
    
    # Inicia el loop en segundo plano
    (
        while true; do
            log_debug "Loop: Attempting to delete rank files (if they exist)..."
            rm -f "$WORLD_DIR/adminlist.txt"
            rm -f "$WORLD_DIR/modlist.txt"
            sleep 5
        done
    ) &
    DELETE_TIMER_PID=$!
    log_debug "Started deletion loop (PID: $DELETE_TIMER_PID)"
}

stop_file_deletion_loop() {
    # Si el loop está corriendo, mátalo
    if [ -n "$DELETE_TIMER_PID" ] && kill -0 "$DELETE_TIMER_PID" 2>/dev/null; then
        log_debug "Stopping deletion loop (PID: $DELETE_TIMER_PID)..."
        kill "$DELETE_TIMER_PID" 2>/dev/null
        wait "$DELETE_TIMER_PID" 2>/dev/null # Espera a que termine para evitar race conditions
        DELETE_TIMER_PID=""
    else
        log_debug "Deletion loop is not running or already stopped."
    fi
}

is_valid_player_name() {
    local name="$1"
    
    # Bloquea nombres vacíos, solo espacios, caracteres de control, espacios al inicio/final o internos
    if [[ -z "$name" ]] || [[ "$name" =~ ^[[:space:]]+$ ]] || \
       echo "$name" | grep -q -P "[\\x00-\\x1F\\x7F]" || \
       [[ "$name" =~ ^[[:space:]]+ ]] || [[ "$name" =~ [[:space:]]+$ ]] || \
       [[ "$name" =~ [[:space:]] ]] || [[ "$name" =~ [\\\/\|\<\>\:\"\?\*] ]]; then
        return 1
    fi
    
    # Verifica longitud y caracteres permitidos
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
    # Extrae el nombre después de '[ID] ' si existe
    if [[ "$name" =~ ^[0-9]+\]\ (.+)$ ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo "$name"
    fi
}

sanitize_name_for_command() {
    # Escapa caracteres especiales para usar en comandos de screen
    local name="$1"
    echo "$name" | sed 's/\\/\\\\/g; s/"/\\"/g; s/`/\\`/g; s/\$/\\$/g'
}

execute_server_command() {
    local command="$1"
    local current_time=$(date +%s)
    local last_time=${last_command_time["$SCREEN_SESSION"]:-0}
    local time_diff=$((current_time - last_time))
    
    # Rate limiting: Espera si ha pasado menos de 1 segundo desde el último comando
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
    
    # Envía el comando a la sesión de screen
    if screen -S "$screen_session" -p 0 -X stuff "$command$(printf \\r)" 2>/dev/null; then
        return 0
    else
        log_debug "FAILED to send command to screen: $screen_session"
        return 1
    fi
}

screen_session_exists() {
    # Verifica si una sesión de screen con ese nombre existe
    screen -list | grep -q "\.$1"
}

get_player_info() {
    local player_name="$1"
    # Busca la información del jugador en players.log
    if [ -f "$PLAYERS_LOG" ]; then
        # Usa grep para eficiencia, luego procesa la línea encontrada
        local line=$(grep -i "^$player_name|" "$PLAYERS_LOG" | head -n 1)
        if [ -n "$line" ]; then
             # Extrae los campos
             IFS='|' read -r name first_ip password rank whitelisted blacklisted <<< "$line"
             echo "$first_ip|$password|$rank|$whitelisted|$blacklisted"
             return 0
        fi
    fi
    echo "" # Retorna vacío si no se encuentra
    return 1
}

update_player_info() {
    local player_name="$1" first_ip="$2" password="$3" rank="$4" whitelisted="${5:-NO}" blacklisted="${6:-NO}"
    
    # Normaliza los datos (mayúsculas, valores por defecto)
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
    
    # Actualiza players.log: borra la línea vieja (si existe) y añade la nueva
    if [ -f "$PLAYERS_LOG" ]; then
        # -i.bak crea un backup por seguridad, puedes quitar '.bak' si no lo quieres
        sed -i.bak "/^$player_name|/Id" "$PLAYERS_LOG" 
        echo "$player_name|$first_ip|$password|$rank|$whitelisted|$blacklisted" >> "$PLAYERS_LOG"
    fi
}

add_to_cloud_admin() {
    local player_name="$1"
    local cloud_file="$HOME_DIR/GNUstep/Library/ApplicationSupport/TheBlockheads/cloudWideOwnedAdminlist.txt"
    
    # Añade el jugador a la lista cloud si no está ya
    [ ! -f "$cloud_file" ] && touch "$cloud_file"
    if ! grep -q "^$player_name$" "$cloud_file" 2>/dev/null; then
        echo "$player_name" >> "$cloud_file"
    fi
}

remove_from_cloud_admin() {
    local player_name="$1"
    local cloud_file="$HOME_DIR/GNUstep/Library/ApplicationSupport/TheBlockheads/cloudWideOwnedAdminlist.txt"
    
    # Elimina al jugador de la lista cloud si existe
    if [ -f "$cloud_file" ]; then
        local temp_file=$(mktemp)
        # Copia todas las líneas EXCEPTO la del jugador al archivo temporal
        grep -v "^$player_name$" "$cloud_file" > "$temp_file" 
        # Si el archivo temporal tiene contenido, reemplaza el original
        if [ -s "$temp_file" ]; then
            mv "$temp_file" "$cloud_file"
        else 
            # Si no, borra ambos (el original quedó vacío)
            rm -f "$cloud_file"
            rm -f "$temp_file"
        fi
    fi
}

start_rank_application_timer() {
    local player_name="$1"
    
    # Aplica el rango inmediatamente si el jugador está conectado y verificado
    if [ -n "${connected_players[$player_name]}" ] && [ "${player_verification_status[$player_name]}" == "verified" ]; then
        local player_info=$(get_player_info "$player_name")
        if [ -n "$player_info" ]; then
            local rank=$(echo "$player_info" | cut -d'|' -f3)
            if [ "$rank" != "NONE" ]; then
                log_debug "Applying rank for $player_name immediately."
                # Llama directamente, sin temporizador
                apply_rank_to_connected_player "$player_name"
            fi
        fi
    fi
}

apply_rank_to_connected_player() {
    local player_name="$1"
    
    # Doble check: ¿Sigue conectado y verificado?
    if [ -z "${connected_players[$player_name]}" ] || [ "${player_verification_status[$player_name]}" != "verified" ]; then
        return
    fi
    
    local player_info=$(get_player_info "$player_name")
    # ¿Tiene info y contraseña (no es NONE)?
    if [ -z "$player_info" ] || [ "$(echo "$player_info" | cut -d'|' -f2)" == "NONE" ]; then
         return
    fi
    
    local rank=$(echo "$player_info" | cut -d'|' -f3)
    
    # ¿Ya se aplicó el rango en esta sesión?
    if [ -n "${rank_already_applied[$player_name]}" ] && [ "${rank_already_applied[$player_name]}" = "$rank" ]; then
        log_debug "Rank $rank for $player_name already applied this session. Skipping."
        return
    fi
    
    # Si tiene rango válido, detener el loop de borrado ANTES de crear el archivo
    if [ "$rank" == "MOD" ] || [ "$rank" == "ADMIN" ] || [ "$rank" == "SUPER" ]; then
        log_debug "Verified ranked player $player_name is online. Stopping deletion loop."
        stop_file_deletion_loop
        # Pausa crucial para evitar condición de carrera con el loop terminando
        sleep 0.2
    fi

    # Aplica el rango con el comando del servidor
    case "$rank" in
        "MOD")
            execute_server_command "/mod $player_name"
            current_player_ranks["$player_name"]="$rank" # Actualiza el estado interno
            rank_already_applied["$player_name"]="$rank" # Marca como aplicado para esta sesión
            ;;
        "ADMIN")
            execute_server_command "/admin $player_name"
            current_player_ranks["$player_name"]="$rank"
            rank_already_applied["$player_name"]="$rank"
            ;;
        "SUPER")
            execute_server_command "/admin $player_name" # SUPER usa /admin
            add_to_cloud_admin "$player_name" # Y también se añade a la lista cloud
            current_player_ranks["$player_name"]="$rank"
            rank_already_applied["$player_name"]="$rank"
            ;;
    esac
}

start_disconnect_timer() {
    local player_name="$1"
    local rank="$2"
    
    # Lógica de 1 segundo (jugadores no verificados o expulsados)
    if [ "${player_verification_status[$player_name]}" != "verified" ]; then
        (
            sleep 1
            # 1. Quitar rango (si lo tenía temporalmente)
            remove_player_rank "$player_name" "$rank"
            
            # 2. Limpiar estado (esto ya se hizo inmediatamente en monitor_console_log)
            # log_debug "Cleaning state for unverified player $player_name"
            # unset connected_players["$player_name"] ... etc

            # 3. Comprobar si reactivar loop de borrado
            check_and_restart_deletion_loop
            
            unset disconnect_timers["$player_name"]
        ) &
        disconnect_timers["$player_name"]=$!
    else
        # Lógica de 10 segundos (jugadores verificados)
        (
            sleep 10
            # 1. Quitar rango
            remove_player_rank "$player_name" "$rank"
            
            # 2. Limpiar estado (esto ya se hizo inmediatamente en monitor_console_log)
            # log_debug "Cleaning state for verified player $player_name after 10s grace"
            # unset connected_players["$player_name"] ... etc

            # 3. Comprobar si reactivar loop de borrado
            check_and_restart_deletion_loop
            
            unset disconnect_timers["$player_name"]
        ) &
        disconnect_timers["$player_name"]=$!
    fi
}


check_and_restart_deletion_loop() {
    local ranked_player_online=0
    
    # Revisa TODOS los jugadores actualmente marcados como conectados
    for player in "${!connected_players[@]}"; do
        # ¿Está verificado?
        if [ "${player_verification_status[$player]}" == "verified" ]; then
            # ¿Tiene rango según players.log?
            local info=$(get_player_info "$player")
            local rank=$(echo "$info" | cut -d'|' -f3)
            if [ "$rank" != "NONE" ]; then
                ranked_player_online=1
                break # Encontramos uno, no hace falta seguir
            fi
        fi
    done
    
    # Si NINGÚN jugador conectado Y verificado tiene rango, reactivar el loop
    if [ $ranked_player_online -eq 0 ]; then
        log_debug "Last verified ranked player disconnected. Restarting deletion loop."
        start_file_deletion_loop
    else
        log_debug "Ranked player left, but others are still online. Deletion loop remains stopped."
    fi
}

remove_player_rank() {
    local player_name="$1"
    local rank="$2" # Rango que tenía al desconectarse
    
    # Ejecuta el comando /unadmin o /unmod si tenía rango
    if [ -n "$rank" ] && [ "$rank" != "NONE" ]; then
        case "$rank" in
            "MOD")
                execute_server_command "/unmod $player_name"
                ;;
            "ADMIN")
                execute_server_command "/unadmin $player_name"
                ;;
            "SUPER")
                execute_server_command "/unadmin $player_name"
                remove_from_cloud_admin "$player_name" # SUPER también se quita de la cloud
                ;;
        esac
    fi
    # El estado 'rank_already_applied' se limpia al desconectar en monitor_console_log
}

cancel_disconnect_timer() {
    local player_name="$1"
    
    # Si hay un temporizador de desconexión activo para este jugador, mátalo
    if [ -n "${disconnect_timers[$player_name]}" ]; then
        log_debug "Canceling disconnect timer for $player_name (reconnected)."
        local pid="${disconnect_timers[$player_name]}"
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
        fi
        unset disconnect_timers["$player_name"]
    fi
}

apply_pending_ranks() {
    local player_name="$1"
    
    # Si hay un rango pendiente y el jugador ahora está verificado
    if [ -n "${pending_ranks[$player_name]}" ]; then
        local pending_rank="${pending_ranks[$player_name]}"
        
        if [ "${player_verification_status[$player_name]}" != "verified" ]; then
            return
        fi
        
        # Detener loop de borrado y aplicar rango
        log_debug "Verified ranked player $player_name is online (from pending). Stopping deletion loop."
        stop_file_deletion_loop
        sleep 0.2 # Pausa contra race condition

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
        
        # Actualizar estado interno y borrar el rango pendiente
        current_player_ranks["$player_name"]="$pending_rank"
        rank_already_applied["$player_name"]="$pending_rank"
        unset pending_ranks["$player_name"]
    fi
}

start_password_reminder_timer() {
    local player_name="$1"
    
    # Inicia un temporizador que recordará al jugador poner contraseña si no tiene
    (
        sleep 5
        # ¿Sigue conectado?
        if [ -n "${connected_players[$player_name]}" ]; then
            local player_info=$(get_player_info "$player_name")
            if [ -n "$player_info" ]; then
                local password=$(echo "$player_info" | cut -d'|' -f2)
                # ¿No tiene contraseña?
                if [ "$password" = "NONE" ]; then
                    execute_server_command "SECURITY: $player_name, set your password within 60 seconds!"
                    execute_server_command "Example of use: !psw Mypassword123 Mypassword123"
                fi
            fi
        fi
    ) &
    # Guarda el PID del temporizador
    active_timers["password_reminder_$player_name"]=$!
}

start_password_kick_timer() {
    local player_name="$1"
    
    # Inicia un temporizador que expulsará al jugador si no pone contraseña en 60s
    (
        sleep 60
        # ¿Sigue conectado?
        if [ -n "${connected_players[$player_name]}" ]; then
            local player_info=$(get_player_info "$player_name")
            if [ -n "$player_info" ]; then
                local password=$(echo "$player_info" | cut -d'|' -f2)
                # ¿Sigue sin contraseña?
                if [ "$password" = "NONE" ]; then
                    execute_server_command "/kick $player_name"
                fi
            fi
        fi
    ) &
    # Guarda el PID del temporizador
    active_timers["password_kick_$player_name"]=$!
}

start_ip_grace_timer() {
    local player_name="$1" current_ip="$2"
    
    # Temporizador para verificar cambio de IP
    (
        sleep 5 # Da 5 segundos para que aparezca el mensaje
        # ¿Sigue conectado?
        if [ -n "${connected_players[$player_name]}" ]; then
            local player_info=$(get_player_info "$player_name")
            if [ -n "$player_info" ]; then
                local first_ip=$(echo "$player_info" | cut -d'|' -f1)
                # ¿Es IP conocida y diferente a la actual?
                if [ "$first_ip" != "UNKNOWN" ] && [ "$first_ip" != "$current_ip" ]; then
                    # Avisa al jugador
                    execute_server_command "SECURITY ALERT: $player_name, your IP has changed!"
                    execute_server_command "Verify with !ip_change + YOUR_PASSWORD within 25 seconds!"
                    execute_server_command "Else you'll get kicked and a temporal ip ban for 30 seconds."
                    sleep 25 # Espera 25 segundos
                    # ¿Sigue conectado Y *no* se ha verificado?
                    if [ -n "${connected_players[$player_name]}" ] && [ "${player_verification_status[$player_name]}" != "verified" ]; then
                        # Expulsar y banear IP temporalmente
                        execute_server_command "/kick $player_name"
                        execute_server_command "/ban $current_ip"
                        # Iniciar temporizador para desbanear IP
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
    # Inicia los temporizadores de recordatorio y expulsión por falta de contraseña
    start_password_reminder_timer "$player_name"
    start_password_kick_timer "$player_name"
}

handle_password_creation() {
    local player_name="$1" password="$2" confirm_password="$3"
    
    execute_server_command "/clear" # Limpia el chat del jugador
    
    local player_info=$(get_player_info "$player_name")
    # ¿Ya tiene contraseña?
    if [ -n "$player_info" ] && [ "$(echo "$player_info" | cut -d'|' -f2)" != "NONE" ]; then
        execute_server_command "ERROR: $player_name, you already have a password set. Use !change_psw to change it."
        return 1
    fi
    
    # ¿Longitud válida?
    if [ ${#password} -lt 7 ] || [ ${#password} -gt 16 ]; then
        execute_server_command "ERROR: $player_name, password must be between 7 and 16 characters."
        return 1
    fi
    
    # ¿Contraseñas coinciden?
    if [ "$password" != "$confirm_password" ]; then
        execute_server_command "ERROR: $player_name, passwords do not match."
        return 1
    fi
    
    # Actualiza la info en players.log
    if [ -n "$player_info" ]; then
        # Extrae datos existentes para no perderlos
        local first_ip=$(echo "$player_info" | cut -d'|' -f1)
        local rank=$(echo "$player_info" | cut -d'|' -f3)
        local whitelisted=$(echo "$player_info" | cut -d'|' -f4)
        local blacklisted=$(echo "$player_info" | cut -d'|' -f5)
        
        # Cancela temporizadores de enforce (recordatorio/kick)
        cancel_player_timers "$player_name" 
        
        # Guarda la nueva contraseña
        update_player_info "$player_name" "$first_ip" "$password" "$rank" "$whitelisted" "$blacklisted"
        
        execute_server_command "SUCCESS: $player_name, password set successfully."
        # Si tenía rango, intenta aplicarlo ahora que tiene contraseña
        start_rank_application_timer "$player_name" 
        return 0
    else
        execute_server_command "ERROR: $player_name, player not found in registry."
        return 1
    fi
}

handle_password_change() {
    local player_name="$1" old_password="$2" new_password="$3"
    
    execute_server_command "/clear"
    
    # ¿Longitud válida?
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
        
        # ¿Contraseña antigua correcta?
        if [ "$current_password" != "$old_password" ]; then
            execute_server_command "ERROR: $player_name, old password is incorrect."
            return 1
        fi
        
        # Actualiza con la nueva contraseña
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
        # Extrae datos actuales
        local first_ip=$(echo "$player_info" | cut -d'|' -f1) # IP registrada (la "vieja")
        local current_password=$(echo "$player_info" | cut -d'|' -f2) # Contraseña registrada
        local rank=$(echo "$player_info" | cut -d'|' -f3)
        local whitelisted=$(echo "$player_info" | cut -d'|' -f4)
        local blacklisted=$(echo "$player_info" | cut -d'|' -f5)
        
        # ¿Contraseña correcta?
        if [ "$current_password" != "$password" ]; then
            execute_server_command "ERROR: $player_name, password is incorrect."
            return 1
        fi
        
        # Actualiza IP registrada a la IP actual
        update_player_info "$player_name" "$current_ip" "$current_password" "$rank" "$whitelisted" "$blacklisted"
        # Marca como verificado
        player_verification_status["$player_name"]="verified"
        
        # Cancela temporizadores (ej. el de gracia de IP)
        cancel_player_timers "$player_name" 
        
        execute_server_command "SECURITY: $player_name IP verification successful."
        
        # Intenta aplicar rangos pendientes ahora que está verificado
        apply_pending_ranks "$player_name"
        # Intenta aplicar rango normal (si no había pendiente)
        start_rank_application_timer "$player_name" 
        
        # Sincroniza por si acaso
        sync_lists_from_players_log 
        
        execute_server_command "SUCCESS: $player_name, your IP has been verified and updated."
        return 0
    else
        execute_server_command "ERROR: $player_name, player not found in registry."
        return 1
    fi
}

cancel_player_timers() {
    local player_name="$1"
    
    # Lista de tipos de temporizadores activos
    local timer_types=("password_reminder" "password_kick" "ip_grace" "rank_application")
    
    # Mata los PIDs de los temporizadores activos para este jugador
    for timer_type in "${timer_types[@]}"; do
        local timer_key="${timer_type}_${player_name}"
        if [ -n "${active_timers[$timer_key]}" ]; then
            local pid="${active_timers[$timer_key]}"
            if kill -0 "$pid" 2>/dev/null; then
                kill "$pid" 2>/dev/null
            fi
            unset active_timers["$timer_key"] # Borra la referencia
        fi
    done
    
    # Cancela también el temporizador de desconexión (si lo hubiera)
    cancel_disconnect_timer "$player_name" 
}

sync_lists_from_players_log() {
    # Si es la primera vez, recarga todo forzosamente
    if [ -z "${list_files_initialized["$WORLD_ID"]}" ]; then
        force_reload_all_lists
        list_files_initialized["$WORLD_ID"]=1
        return
    fi
    
    # Lee players.log línea por línea
    if [ -f "$PLAYERS_LOG" ]; then
        while IFS='|' read -r name first_ip password rank whitelisted blacklisted; do
            name=$(echo "$name" | xargs)
            rank=$(echo "$rank" | xargs)
            
            # ¿Está conectado?
            if [ -z "${connected_players[$name]}" ]; then
                continue # No, siguiente jugador
            fi
            
            # ¿Está verificado?
            if [ "${player_verification_status[$name]}" != "verified" ]; then
                # No, si tiene rango, marcarlo como pendiente
                if [ "$rank" != "NONE" ]; then
                    pending_ranks["$name"]="$rank"
                fi
                continue # Siguiente jugador
            fi
            
            # Verificado y conectado. ¿Su rango actual difiere del de players.log?
            local current_rank="${current_player_ranks[$name]}"
            if [ "$current_rank" != "$rank" ]; then
                # Sí, aplicar el cambio
                apply_rank_changes "$name" "$current_rank" "$rank"
                current_player_ranks["$name"]="$rank" # Actualizar estado interno
            fi
            
        done < "$PLAYERS_LOG"
    fi
}

force_reload_all_lists() {
    # Similar a sync, pero asume que todo necesita ser aplicado
    if [ ! -f "$PLAYERS_LOG" ]; then
        return
    fi
    
    while IFS='|' read -r name first_ip password rank whitelisted blacklisted; do
        name=$(echo "$name" | xargs)
        rank=$(echo "$rank" | xargs)
        
        # ¿Conectado y verificado?
        if [ -z "${connected_players[$name]}" ] || [ "${player_verification_status[$name]}" != "verified" ]; then
            continue
        fi
        
        # ¿Tiene rango? Aplicarlo.
        if [ "$rank" != "NONE" ]; then
            # Borrar estado previo para forzar la re-aplicación
            unset rank_already_applied["$name"] 
            apply_rank_to_connected_player "$name"
        fi
        
    done < "$PLAYERS_LOG"
}

apply_rank_changes() {
    local player_name="$1" old_rank="$2" new_rank="$3"
    
    # 1. Quitar el rango antiguo
    case "$old_rank" in
        "ADMIN")
            execute_server_command "/unadmin $player_name"
            ;;
        "MOD")
            execute_server_command "/unmod $player_name"
            ;;
        "SUPER")
            execute_server_command "/unadmin $player_name"
            remove_from_cloud_admin "$player_name"
            ;;
    esac
    
    sleep 1 # Pausa para que el servidor procese el comando anterior
    
    # 2. Aplicar el rango nuevo (si no es NONE y está verificado)
    if [ "$new_rank" != "NONE" ] && [ "${player_verification_status[$player_name]}" == "verified" ]; then
        unset rank_already_applied["$player_name"] # Asegura que se reaplique
        
        log_debug "Verified ranked player $player_name is online (from rank change). Stopping deletion loop."
        stop_file_deletion_loop
        sleep 0.2 # Pausa contra race condition
        
        case "$new_rank" in
            "ADMIN")
                execute_server_command "/admin $player_name"
                current_player_ranks["$player_name"]="$new_rank"
                rank_already_applied["$player_name"]="$new_rank"
                ;;
            "MOD")
                execute_server_command "/mod $player_name"
                current_player_ranks["$player_name"]="$new_rank"
                rank_already_applied["$player_name"]="$new_rank"
                ;;
            "SUPER")
                add_to_cloud_admin "$player_name"
                execute_server_command "/admin $player_name"
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
    
    # Nombre sanitizado para usar en comandos /kick o /ban si falla el baneo por IP
    local safe_name=$(sanitize_name_for_command "$player_name")
    
    # Ejecuta en segundo plano para no bloquear el script principal
    (
        sleep 3
        execute_server_command "WARNING: Invalid player name '$player_name'! Names must be 3-16 alphanumeric characters, no spaces/symbols or nullbytes!"
        
        execute_server_command "WARNING: You will be kicked and IP banned in 3 seconds for 60 seconds."
        sleep 3

        # Intenta banear por IP si la tenemos
        if [ -n "$player_ip" ] && [ "$player_ip" != "unknown" ]; then
            execute_server_command "/ban $player_ip"
            # Kick usa el nombre (sanitizado por si acaso)
            execute_server_command "/kick \"$safe_name\"" 
            print_warning "Banned invalid player name: '$player_name' (IP: $player_ip) for 60 seconds"
            # Temporizador para desbanear IP
            (
                sleep 60
                execute_server_command "/unban $player_ip"
                print_success "Unbanned IP: $player_ip"
            ) &
        else
            # Si no hay IP, banea por nombre (sanitizado) como fallback
            execute_server_command "/ban \"$safe_name\"" 
            execute_server_command "/kick \"$safe_name\""
            print_warning "Banned invalid player name: '$player_name' (fallback to name ban)"
        fi
    ) &
    
    return 1 # Indica error
}

monitor_players_log() {
    local last_checksum=""
    local temp_file=$(mktemp) # Archivo temporal para comparar cambios
    
    # Copia inicial del archivo si existe
    [ -f "$PLAYERS_LOG" ] && cp "$PLAYERS_LOG" "$temp_file"
    
    # Carga inicial de rangos conocidos
    if [ -f "$PLAYERS_LOG" ]; then
        while IFS='|' read -r name first_ip password rank whitelisted blacklisted; do
            name=$(echo "$name" | xargs)
            rank=$(echo "$rank" | xargs)
            current_player_ranks["$name"]="$rank" # Guarda el rango actual conocido
        done < "$PLAYERS_LOG"
    fi
    
    # Bucle infinito para monitorear cambios
    while true; do
        if [ -f "$PLAYERS_LOG" ]; then
            # Calcula checksum actual
            local current_checksum=$(md5sum "$PLAYERS_LOG" 2>/dev/null | cut -d' ' -f1)
            
            # ¿Ha cambiado desde la última vez?
            if [ "$current_checksum" != "$last_checksum" ]; then
                log_debug "players.log change detected. Processing..."
                # Procesa los cambios comparando con la copia anterior
                process_players_log_changes "$temp_file"
                last_checksum="$current_checksum" # Actualiza checksum
                cp "$PLAYERS_LOG" "$temp_file" # Actualiza copia
            fi
        fi
        sleep 1 # Espera 1 segundo
    done
    
    rm -f "$temp_file" # Limpia el archivo temporal al salir (aunque no debería llegar aquí)
}

process_players_log_changes() {
    local previous_file="$1" # La copia del archivo ANTES del cambio
    
    # Si falta algún archivo, resincroniza todo por si acaso
    if [ ! -f "$previous_file" ] || [ ! -f "$PLAYERS_LOG" ]; then
        sync_lists_from_players_log
        return
    fi
    
    # Lee el archivo NUEVO línea por línea
    while IFS='|' read -r name first_ip password rank whitelisted blacklisted; do
        name=$(echo "$name" | xargs)
        rank=$(echo "$rank" | xargs)
        
        # Busca la línea correspondiente en el archivo VIEJO
        local previous_line=$(grep -i "^$name|" "$previous_file" 2>/dev/null | head -1)
        
        # Si existía antes...
        if [ -n "$previous_line" ]; then
            # Extrae el rango ANTIGUO
            local prev_rank=$(echo "$previous_line" | cut -d'|' -f4 | xargs)
            
            # ¿El rango nuevo es diferente al antiguo?
            if [ "$prev_rank" != "$rank" ]; then
                log_debug "Rank change detected for $name: $prev_rank -> $rank"
                # Aplica el cambio (quitar viejo, poner nuevo si aplica)
                apply_rank_changes "$name" "$prev_rank" "$rank"
            fi
        fi
        # Si no existía antes, es un jugador nuevo, no hacemos nada aquí
    done < "$PLAYERS_LOG"
    
    # Llama a sync para asegurar consistencia general después de procesar cambios
    sync_lists_from_players_log
}

monitor_list_files() {
    local admin_list="$WORLD_DIR/adminlist.txt"
    local mod_list="$WORLD_DIR/modlist.txt"
    
    local last_admin_checksum=""
    local last_mod_checksum=""
    
    # Monitorea cambios externos en adminlist/modlist y resincroniza si ocurren
    while true; do
        # Comprueba adminlist
        if [ -f "$admin_list" ]; then
            local current_admin_checksum=$(md5sum "$admin_list" 2>/dev/null | cut -d' ' -f1)
            if [ "$current_admin_checksum" != "$last_admin_checksum" ]; then
                log_debug "adminlist.txt changed externally. Re-syncing..."
                sleep 2 # Espera por si el servidor aún está escribiendo
                sync_lists_from_players_log # Re-sincroniza con players.log
                last_admin_checksum="$current_admin_checksum" # Actualiza checksum
            fi
        else
            # Si el archivo no existe, resetea el checksum
             last_admin_checksum=""
        fi

        # Comprueba modlist
        if [ -f "$mod_list" ]; then
            local current_mod_checksum=$(md5sum "$mod_list" 2>/dev/null | cut -d' ' -f1)
            if [ "$current_mod_checksum" != "$last_mod_checksum" ]; then
                log_debug "modlist.txt changed externally. Re-syncing..."
                sleep 2
                sync_lists_from_players_log
                last_mod_checksum="$current_mod_checksum"
            fi
        else
            last_mod_checksum=""
        fi
        
        sleep 5 # Espera 5 segundos
    done
}

monitor_console_log() {
    print_header "STARTING CONSOLE LOG MONITOR"
    
    # Espera hasta 30s a que aparezca el log
    local wait_time=0
    while [ ! -f "$CONSOLE_LOG" ] && [ $wait_time -lt 30 ]; do
        sleep 1
        ((wait_time++))
    done
    
    if [ ! -f "$CONSOLE_LOG" ]; then
        print_error "Console log file not found after 30s: $CONSOLE_LOG"
        return 1
    fi
    
    # Lee el log línea por línea a medida que se escribe (-F sigue el archivo incluso si se rota)
    tail -n 0 -F "$CONSOLE_LOG" | while read -r line; do
        log_debug "CONSOLE: $line"
        
        # --- Detección de Conexión ---
        if [[ "$line" =~ Player\ Connected\ (.+)\ \|\ ([0-9a-fA-F.:]+)\ \|\ ([0-9a-f]+) ]]; then
            local player_name="${BASH_REMATCH[1]}"
            local player_ip="${BASH_REMATCH[2]}"
            local player_hash="${BASH_REMATCH[3]}"
            
            # Limpia y valida el nombre
            player_name=$(extract_real_name "$player_name")
            player_name=$(echo "$player_name" | xargs | tr '[:lower:]' '[:upper:]')
            
            if ! is_valid_player_name "$player_name"; then
                handle_invalid_player_name "$player_name" "$player_ip" "$player_hash"
                continue # Ignora el resto para este jugador inválido
            fi
            
            log_debug "Player Connected: $player_name, IP: $player_ip"
            
            # Si se estaba desconectando, cancela el temporizador
            cancel_disconnect_timer "$player_name"
            
            # Marca como conectado y guarda IP
            connected_players["$player_name"]=1
            player_ip_map["$player_name"]="$player_ip"
            
            # Obtiene info de players.log
            local player_info=$(get_player_info "$player_name")
            
            # Es un jugador nuevo?
            if [ -z "$player_info" ]; then
                log_debug "New player: $player_name. Creating entry."
                update_player_info "$player_name" "$player_ip" "NONE" "NONE" "NO" "NO"
                # Nuevo jugador está verificado por defecto (hasta que cambie de IP)
                player_verification_status["$player_name"]="verified" 
                current_player_ranks["$player_name"]="NONE"
                rank_already_applied["$player_name"]="NONE" # Asegura estado limpio
                # Inicia proceso para que ponga contraseña
                start_password_enforcement "$player_name"
            else
                # Jugador existente, extrae datos
                local first_ip=$(echo "$player_info" | cut -d'|' -f1)
                local password=$(echo "$player_info" | cut -d'|' -f2)
                local rank=$(echo "$player_info" | cut -d'|' -f3)
                
                # Guarda rango actual conocido
                current_player_ranks["$player_name"]="$rank"
                
                # ¿Primera vez o IP desconocida? Actualiza IP en players.log
                if [ "$first_ip" = "UNKNOWN" ]; then
                    log_debug "Updating IP for $player_name to $player_ip"
                    update_player_info "$player_name" "$player_ip" "$password" "$rank" "NO" "NO"
                    player_verification_status["$player_name"]="verified"
                # ¿IP registrada es diferente a la actual?
                elif [ "$first_ip" != "$player_ip" ]; then
                    log_debug "IP Mismatch for $player_name. Registered: $first_ip, Current: $player_ip"
                    player_verification_status["$player_name"]="pending" # Requiere verificación
                    
                    # Si tenía rango, quitarlo temporalmente y marcar como pendiente
                    if [ "$rank" != "NONE" ]; then
                        log_debug "Removing rank for $player_name pending IP verification."
                        apply_rank_changes "$player_name" "$rank" "NONE"
                        pending_ranks["$player_name"]="$rank"
                    fi
                    
                    # Inicia temporizador de gracia para verificar IP
                    start_ip_grace_timer "$player_name" "$player_ip"
                else
                    # IP coincide, está verificado
                    log_debug "IP match for $player_name. Status: Verified."
                    player_verification_status["$player_name"]="verified"
                fi
                
                # ¿No tiene contraseña? Iniciar proceso para que la ponga
                if [ "$password" = "NONE" ]; then
                    log_debug "No password for $player_name. Starting enforcement."
                    start_password_enforcement "$player_name"
                fi
                
                # Si está verificado, intentar aplicar rango inmediatamente
                if [ "${player_verification_status[$player_name]}" == "verified" ]; then
                    start_rank_application_timer "$player_name"
                fi
            fi
            
            # Sincroniza por si acaso hubo cambios externos
            sync_lists_from_players_log
        
        # --- Detección de Desconexión ---
        elif [[ "$line" =~ Player\ Disconnected\ (.+) ]]; then
            local player_name="${BASH_REMATCH[1]}"
            player_name=$(echo "$player_name" | xargs | tr '[:lower:]' '[:upper:]')
            
            # Solo procesar si el nombre es válido (ignorar desconexiones de inválidos)
            if is_valid_player_name "$player_name"; then
                log_debug "Player Disconnected: $player_name"
                
                # Obtener rango que tenía ANTES de limpiar estado
                local player_info=$(get_player_info "$player_name")
                local rank=$(echo "$player_info" | cut -d'|' -f3)

                # Cancelar temporizadores activos (kick, ip change, etc.)
                cancel_player_timers "$player_name"
                
                # Limpiar estado INMEDIATAMENTE
                log_debug "Cleaning state for $player_name immediately on disconnect."
                unset connected_players["$player_name"]
                unset player_ip_map["$player_name"]
                unset player_verification_status["$player_name"]
                unset pending_ranks["$player_name"]
                unset rank_already_applied["$player_name"]
                unset current_player_ranks["$player_name"]

                # Iniciar temporizador de desconexión (que hará /unadmin y check loop)
                start_disconnect_timer "$player_name" "$rank"
                
                # Sincronizar por si acaso
                sync_lists_from_players_log
            fi
        
        # --- Detección de Comandos de Chat ---
        elif [[ "$line" =~ ([a-zA-Z0-9_]+):\ (.+)$ ]]; then
            local player_name="${BASH_REMATCH[1]}"
            local message="${BASH_REMATCH[2]}"
            # Obtener IP actual del jugador (si está conectado)
            local current_ip="${player_ip_map[$player_name]}" 
            
            player_name=$(echo "$player_name" | xargs | tr '[:lower:]' '[:upper:]')
            
            # Procesar solo si el nombre es válido
            if is_valid_player_name "$player_name"; then
                # ¿El mensaje empieza con algún comando conocido?
                case "$message" in
                    "!psw "*) # Crear contraseña
                        # Extraer contraseñas con regex
                        if [[ "$message" =~ !psw\ ([^[:space:]]+)\ ([^[:space:]]+)$ ]]; then
                            local password="${BASH_REMATCH[1]}"
                            local confirm_password="${BASH_REMATCH[2]}"
                            log_debug "$player_name trying to set password."
                            handle_password_creation "$player_name" "$password" "$confirm_password"
                        else
                            # Formato incorrecto
                            execute_server_command "/clear"
                            execute_server_command "ERROR: $player_name, invalid format! Example: !psw MyPassword123 MyPassword123"
                        fi
                        ;;
                    "!change_psw "*) # Cambiar contraseña
                        if [[ "$message" =~ !change_psw\ ([^[:space:]]+)\ ([^[:space:]]+)$ ]]; then
                            local old_password="${BASH_REMATCH[1]}"
                            local new_password="${BASH_REMATCH[2]}"
                            log_debug "$player_name trying to change password."
                            handle_password_change "$player_name" "$old_password" "$new_password"
                        else
                            execute_server_command "/clear"
                            execute_server_command "ERROR: $player_name, invalid format! Use: !change_psw OLD_PASSWORD NEW_PASSWORD"
                        fi
                        ;;
                    "!ip_change "*) # Verificar cambio de IP
                        if [[ "$message" =~ !ip_change\ (.+)$ ]]; then
                            local password="${BASH_REMATCH[1]}"
                            log_debug "$player_name trying to verify IP."
                            handle_ip_change "$player_name" "$password" "$current_ip"
                        else
                            execute_server_command "/clear"
                            execute_server_command "ERROR: $player_name, invalid format! Use: !ip_change YOUR_PASSWORD"
                        fi
                        ;;
                esac
            fi
        
        # --- Detección de Limpieza de Listas (Ej: /clear-adminlist) ---
        elif [[ "$line" =~ cleared\ (.+)\ list ]]; then
            log_debug "Server list cleared detected ($line). Forcing reload."
            sleep 2 # Espera por si acaso
            force_reload_all_lists # Recarga los rangos de players.log para los conectados
        fi
    done
}

setup_paths() {
    local port="$1"
    
    # Lee el ID del mundo desde el archivo creado por server_manager.sh
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
    
    # Define rutas globales basadas en el World ID
    WORLD_DIR="$BASE_SAVES_DIR/$WORLD_ID"
    PLAYERS_LOG="$WORLD_DIR/players.log"
    CONSOLE_LOG="$WORLD_DIR/console.log"
    PATCH_DEBUG_LOG="$WORLD_DIR/patch_debug.log"
    SCREEN_SESSION="blockheads_server_$port"
    
    # Crea archivos si no existen
    [ ! -f "$PLAYERS_LOG" ] && touch "$PLAYERS_LOG"
    [ ! -f "$PATCH_DEBUG_LOG" ] && touch "$PATCH_DEBUG_LOG"
    
    return 0
}

cleanup() {
    print_header "CLEANING UP RANK PATCHER"
    
    # Detiene el loop de borrado de 5 segundos
    stop_file_deletion_loop
    
    # Mata todos los procesos en segundo plano iniciados por este script
    jobs -p | xargs kill -9 2>/dev/null
    
    # Intenta matar PIDs de temporizadores activos (por si acaso)
    for timer_key in "${!active_timers[@]}"; do
        local pid="${active_timers[$timer_key]}"
        if kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null; fi
    done
    for player_name in "${!disconnect_timers[@]}"; do
        local pid="${disconnect_timers[$player_name]}"
        if kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null; fi
    done
    
    print_success "Cleanup completed"
    exit 0
}

main() {
    # Requiere el puerto como argumento
    if [ $# -lt 1 ]; then
        print_error "Usage: $0 <port>"
        print_status "Example: $0 12153"
        exit 1
    fi
    PORT="$1"
    
    print_header "THE BLOCKHEADS RANK PATCHER"
    print_status "Starting rank patcher for port: $PORT"
    
    # Asegura que cleanup() se llame al salir
    trap cleanup EXIT INT TERM
    
    # Configura las rutas
    if ! setup_paths "$PORT"; then
        exit 1
    fi
    
    log_debug "--- Rank Patcher Starting ---"
    
    # Verifica que la screen del servidor exista
    if ! screen_session_exists "$SCREEN_SESSION"; then
        print_error "Server screen session not found: $SCREEN_SESSION"
        print_status "Please start the server first using server_manager.sh"
        log_debug "CRITICAL: Server screen $SCREEN_SESSION not found on start."
        exit 1
    fi
    
    # Inicia el loop de borrado (estado seguro por defecto)
    print_step "Starting rank file deletion loop (Safe Mode)..."
    start_file_deletion_loop
    
    # Inicia los monitores en segundo plano
    print_step "Starting players.log monitor..."
    monitor_players_log &
    
    print_step "Starting console.log monitor..."
    monitor_console_log &
    
    print_step "Starting list files monitor..."
    monitor_list_files &
    
    # Muestra estado y espera a que los monitores terminen (lo cual no debería pasar)
    print_header "RANK PATCHER IS NOW RUNNING"
    print_status "Monitoring: $CONSOLE_LOG"
    print_status "Managing: $PLAYERS_LOG"
    print_status "Debug log: $PATCH_DEBUG_LOG"
    print_status "Server session: $SCREEN_SESSION"
    log_debug "--- Rank Patcher is RUNNING ---"
    
    wait # Espera a que terminen los procesos en segundo plano
}

# Ejecuta la función principal con los argumentos pasados al script
main "$@"
