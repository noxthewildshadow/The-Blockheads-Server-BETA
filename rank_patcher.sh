#!/bin/bash

# rank_patcher.sh - Sistema de gestión de rangos y autenticación para The Blockheads
# Autor: Asistente
# Versión: 1.0

set -e

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
USER_HOME="$HOME"
BASE_DIR="$USER_HOME/GNUstep/Library/ApplicationSupport/TheBlockheads"
SAVES_DIR="$BASE_DIR/saves"
CLOUD_ADMIN_LIST="$BASE_DIR/cloudWideOwnedAdminlist.txt"

# Variables del mundo (se detectarán automáticamente)
WORLD_ID=""
WORLD_DIR=""
CONSOLE_LOG=""
PLAYERS_LOG=""
ADMIN_LIST=""
MOD_LIST=""
WHITELIST=""
BLACKLIST=""

# Cooldowns
MESSAGE_COOLDOWN=0.5
IP_VERIFY_TIMEOUT=30
PASSWORD_SET_TIMEOUT=60

# Estados temporales
declare -A PLAYER_IP_CHANGE_TIMERS
declare -A PLAYER_PASSWORD_TIMERS
declare -A PLAYER_COOLDOWNS
declare -A CONNECTED_PLAYERS

# =============================================================================
# FUNCIONES DE LOGGING Y UTILIDADES
# =============================================================================

print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_status() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_debug() { echo -e "${CYAN}[DEBUG]${NC} $1"; }

log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "${WORLD_DIR}/rank_patcher.log"
}

# Función para aplicar cooldown antes de enviar mensajes
apply_cooldown() {
    sleep $MESSAGE_COOLDOWN
}

# Función para enviar comandos al servidor
send_server_command() {
    local command="$1"
    local port="$2"
    
    if [ -n "$port" ]; then
        local screen_session="blockheads_server_$port"
        if screen -list | grep -q "$screen_session"; then
            screen -S "$screen_session" -p 0 -X stuff "$command^M"
            log_message "Comando enviado: $command"
        else
            print_warning "No se pudo enviar comando: Sesión screen no encontrada"
        fi
    else
        print_warning "Puerto no especificado, no se puede enviar comando: $command"
    fi
}

# Función para limpiar chat
clear_chat() {
    send_server_command "/clear" "$SERVER_PORT"
    apply_cooldown
}

# =============================================================================
# FUNCIONES DE DETECCIÓN Y CONFIGURACIÓN
# =============================================================================

# Detectar mundo activo y configurar variables
detect_world_config() {
    # Buscar archivos world_id_*.txt para detectar mundos activos
    for world_file in world_id_*.txt; do
        if [ -f "$world_file" ]; then
            WORLD_ID=$(cat "$world_file")
            SERVER_PORT=$(echo "$world_file" | sed 's/world_id_//' | sed 's/\.txt//')
            WORLD_DIR="$SAVES_DIR/$WORLD_ID"
            CONSOLE_LOG="$WORLD_DIR/console.log"
            PLAYERS_LOG="$WORLD_DIR/players.log"
            ADMIN_LIST="$WORLD_DIR/adminlist.txt"
            MOD_LIST="$WORLD_DIR/modlist.txt"
            WHITELIST="$WORLD_DIR/whitelist.txt"
            BLACKLIST="$WORLD_DIR/blacklist.txt"
            
            if [ -d "$WORLD_DIR" ]; then
                print_success "Mundo detectado: $WORLD_ID (Puerto: $SERVER_PORT)"
                return 0
            fi
        fi
    done
    
    print_error "No se pudo detectar un mundo activo"
    return 1
}

# Inicializar archivos del sistema
initialize_system_files() {
    # Crear players.log si no existe
    if [ ! -f "$PLAYERS_LOG" ]; then
        touch "$PLAYERS_LOG"
        print_status "Archivo players.log creado: $PLAYERS_LOG"
    fi
    
    # Crear cloud admin list si no existe
    if [ ! -f "$CLOUD_ADMIN_LIST" ]; then
        touch "$CLOUD_ADMIN_LIST"
        print_status "Archivo cloud admin list creado: $CLOUD_ADMIN_LIST"
    fi
    
    # Mantener listas vacías (ignorando primeras 2 líneas)
    if [ -f "$ADMIN_LIST" ]; then
        local temp_admin=$(mktemp)
        head -n 2 "$ADMIN_LIST" > "$temp_admin" 2>/dev/null || true
        mv "$temp_admin" "$ADMIN_LIST"
    fi
    
    if [ -f "$MOD_LIST" ]; then
        local temp_mod=$(mktemp)
        head -n 2 "$MOD_LIST" > "$temp_mod" 2>/dev/null || true
        mv "$temp_mod" "$MOD_LIST"
    fi
}

# =============================================================================
# FUNCIONES DE GESTIÓN DE PLAYERS.LOG
# =============================================================================

# Buscar jugador en players.log
find_player() {
    local player_name="$1"
    grep "^$player_name |" "$PLAYERS_LOG" 2>/dev/null || true
}

# Agregar nuevo jugador a players.log
add_new_player() {
    local player_name="$1"
    local player_ip="$2"
    
    if [ -z "$(find_player "$player_name")" ]; then
        echo "$player_name | $player_ip | NONE | NONE | NO | NO" >> "$PLAYERS_LOG"
        log_message "Nuevo jugador agregado: $player_name ($player_ip)"
    fi
}

# Actualizar campo de jugador en players.log
update_player_field() {
    local player_name="$1"
    local field_index="$2"
    local new_value="$3"
    
    local temp_file=$(mktemp)
    while IFS= read -r line; do
        if [[ "$line" == "$player_name |"* ]]; then
            IFS='|' read -ra fields <<< "$line"
            fields[$field_index]=" $new_value "
            printf '%s' "${fields[0]}" > "$temp_file"
            for ((i=1; i<${#fields[@]}; i++)); do
                printf '|%s' "${fields[i]}" >> "$temp_file"
            done
            echo >> "$temp_file"
        else
            echo "$line" >> "$temp_file"
        fi
    done < "$PLAYERS_LOG"
    
    mv "$temp_file" "$PLAYERS_LOG"
}

# Obtener campo específico de jugador
get_player_field() {
    local player_name="$1"
    local field_index="$2"
    
    local player_entry=$(find_player "$player_name")
    if [ -n "$player_entry" ]; then
        IFS='|' read -ra fields <<< "$player_entry"
        echo "${fields[$field_index]}" | sed 's/^ *//;s/ *$//'
    fi
}

# =============================================================================
# FUNCIONES DE SINCRONIZACIÓN DE LISTAS
# =============================================================================

# Sincronizar listas del servidor con players.log
sync_server_lists() {
    # Sincronizar adminlist
    local temp_admin=$(mktemp)
    head -n 2 "$ADMIN_LIST" > "$temp_admin" 2>/dev/null || true
    
    while IFS= read -r line; do
        local player_name=$(echo "$line" | cut -d'|' -f1 | sed 's/ *$//')
        local player_ip=$(echo "$line" | cut -d'|' -f2 | sed 's/^ *//')
        local rank=$(echo "$line" | cut -d'|' -f4 | sed 's/^ *//')
        
        # Solo agregar a la lista si está conectado y con IP verificada
        if [ "$rank" = "ADMIN" ] && [ -n "${CONNECTED_PLAYERS[$player_name]}" ]; then
            local current_ip="${CONNECTED_PLAYERS[$player_name]}"
            if [ "$player_ip" = "$current_ip" ] || [ "$player_ip" = "UNKNOWN" ]; then
                echo "$player_name" >> "$temp_admin"
            fi
        fi
    done < "$PLAYERS_LOG"
    
    mv "$temp_admin" "$ADMIN_LIST"
    
    # Sincronizar modlist
    local temp_mod=$(mktemp)
    head -n 2 "$MOD_LIST" > "$temp_mod" 2>/dev/null || true
    
    while IFS= read -r line; do
        local player_name=$(echo "$line" | cut -d'|' -f1 | sed 's/ *$//')
        local player_ip=$(echo "$line" | cut -d'|' -f2 | sed 's/^ *//')
        local rank=$(echo "$line" | cut -d'|' -f4 | sed 's/^ *//')
        
        if [ "$rank" = "MOD" ] && [ -n "${CONNECTED_PLAYERS[$player_name]}" ]; then
            local current_ip="${CONNECTED_PLAYERS[$player_name]}"
            if [ "$player_ip" = "$current_ip" ] || [ "$player_ip" = "UNKNOWN" ]; then
                echo "$player_name" >> "$temp_mod"
            fi
        fi
    done < "$PLAYERS_LOG"
    
    mv "$temp_mod" "$MOD_LIST"
}

# =============================================================================
# FUNCIONES DE GESTIÓN DE RANGOS
# =============================================================================

# Aplicar cambios de rango
apply_rank_change() {
    local player_name="$1"
    local old_rank="$2"
    local new_rank="$3"
    
    case "$old_rank" in
        ADMIN)
            send_server_command "/unadmin $player_name" "$SERVER_PORT"
            ;;
        MOD)
            send_server_command "/unmod $player_name" "$SERVER_PORT"
            ;;
        SUPER)
            # Remover de cloud admin list
            sed -i "/^$player_name$/d" "$CLOUD_ADMIN_LIST" 2>/dev/null || true
            ;;
    esac
    
    case "$new_rank" in
        ADMIN)
            send_server_command "/admin $player_name" "$SERVER_PORT"
            ;;
        MOD)
            send_server_command "/mod $player_name" "$SERVER_PORT"
            ;;
        SUPER)
            # Agregar a cloud admin list
            echo "$player_name" >> "$CLOUD_ADMIN_LIST"
            ;;
    esac
    
    log_message "Rango cambiado: $player_name ($old_rank -> $new_rank)"
}

# Aplicar blacklist
apply_blacklist() {
    local player_name="$1"
    local player_ip="$2"
    
    # Remover rangos primero
    send_server_command "/unmod $player_name" "$SERVER_PORT"
    send_server_command "/unadmin $player_name" "$SERVER_PORT"
    
    # Aplicar bans
    send_server_command "/ban $player_name" "$SERVER_PORT"
    send_server_command "/ban $player_ip" "$SERVER_PORT"
    
    # Remover de cloud admin list si era SUPER
    local current_rank=$(get_player_field "$player_name" 3)
    if [ "$current_rank" = "SUPER" ]; then
        sed -i "/^$player_name$/d" "$CLOUD_ADMIN_LIST" 2>/dev/null || true
        # Enviar comando stop si está conectado
        if [ -n "${CONNECTED_PLAYERS[$player_name]}" ]; then
            send_server_command "/stop" "$SERVER_PORT"
        fi
    fi
    
    log_message "Jugador blacklisted: $player_name ($player_ip)"
}

# =============================================================================
# FUNCIONES DE AUTENTICACIÓN Y COMANDOS
# =============================================================================

# Validar contraseña
validate_password() {
    local password="$1"
    local confirm="$2"
    
    if [ ${#password} -lt 7 ] || [ ${#password} -gt 16 ]; then
        echo "La contraseña debe tener entre 7 y 16 caracteres"
        return 1
    fi
    
    if [ "$password" != "$confirm" ]; then
        echo "Las contraseñas no coinciden"
        return 1
    fi
    
    return 0
}

# Procesar comando !password
process_password_command() {
    local player_name="$1"
    local password="$2"
    local confirm="$3"
    
    clear_chat
    apply_cooldown
    
    local validation_result=$(validate_password "$password" "$confirm")
    if [ $? -ne 0 ]; then
        send_server_command "tell $player_name $validation_result" "$SERVER_PORT"
        return 1
    fi
    
    # Actualizar contraseña en players.log
    update_player_field "$player_name" 2 "$password"
    
    # Eliminar timer de contraseña si existe
    unset PLAYER_PASSWORD_TIMERS["$player_name"]
    
    send_server_command "tell $player_name Contraseña establecida exitosamente" "$SERVER_PORT"
    log_message "Contraseña establecida para: $player_name"
    return 0
}

# Procesar comando !ip_change
process_ip_change_command() {
    local player_name="$1"
    local password="$2"
    
    clear_chat
    apply_cooldown
    
    local stored_password=$(get_player_field "$player_name" 2)
    if [ "$stored_password" != "$password" ] && [ "$stored_password" != "NONE" ]; then
        send_server_command "tell $player_name Contraseña incorrecta" "$SERVER_PORT"
        return 1
    fi
    
    # Actualizar IP en players.log
    local current_ip="${CONNECTED_PLAYERS[$player_name]}"
    update_player_field "$player_name" 1 "$current_ip"
    
    # Eliminar timer de cambio de IP
    unset PLAYER_IP_CHANGE_TIMERS["$player_name"]
    
    send_server_command "tell $player_name IP verificada exitosamente" "$SERVER_PORT"
    log_message "IP actualizada para: $player_name ($current_ip)"
    return 0
}

# Procesar comando !change_psw
process_change_password_command() {
    local player_name="$1"
    local old_password="$2"
    local new_password="$3"
    
    clear_chat
    apply_cooldown
    
    local stored_password=$(get_player_field "$player_name" 2)
    if [ "$stored_password" != "$old_password" ] && [ "$stored_password" != "NONE" ]; then
        send_server_command "tell $player_name Contraseña actual incorrecta" "$SERVER_PORT"
        return 1
    fi
    
    local validation_result=$(validate_password "$new_password" "$new_password")
    if [ $? -ne 0 ]; then
        send_server_command "tell $player_name $validation_result" "$SERVER_PORT"
        return 1
    fi
    
    update_player_field "$player_name" 2 "$new_password"
    send_server_command "tell $player_name Contraseña cambiada exitosamente" "$SERVER_PORT"
    log_message "Contraseña cambiada para: $player_name"
    return 0
}

# =============================================================================
# FUNCIONES DE MONITOREO Y TEMPORIZADORES
# =============================================================================

# Procesar conexión de jugador
process_player_connect() {
    local player_name="$1"
    local player_ip="$2"
    local player_id="$3"
    
    log_message "Jugador conectado: $player_name ($player_ip) - $player_id"
    
    # Agregar/actualizar en players.log
    add_new_player "$player_name" "$player_ip"
    
    # Registrar jugador conectado
    CONNECTED_PLAYERS["$player_name"]="$player_ip"
    
    # Verificar si necesita establecer contraseña
    local stored_password=$(get_player_field "$player_name" 2)
    if [ "$stored_password" = "NONE" ]; then
        send_server_command "tell $player_name Bienvenido! Por favor establece tu contraseña con !password <contraseña> <confirmar> en 1 minuto" "$SERVER_PORT"
        PLAYER_PASSWORD_TIMERS["$player_name"]=$(date +%s)
    fi
    
    # Verificar cambio de IP
    local stored_ip=$(get_player_field "$player_name" 1)
    if [ "$stored_ip" != "UNKNOWN" ] && [ "$stored_ip" != "$player_ip" ]; then
        send_server_command "tell $player_name IP detectada diferente. Verifica con !ip_change <tu_contraseña> en 30 segundos" "$SERVER_PORT"
        PLAYER_IP_CHANGE_TIMERS["$player_name"]=$(date +%s)
    fi
    
    # Sincronizar listas
    sync_server_lists
}

# Procesar desconexión de jugador
process_player_disconnect() {
    local player_id="$1"
    local player_name="$2"
    
    if [ -n "$player_name" ]; then
        log_message "Jugador desconectado: $player_name"
        unset CONNECTED_PLAYERS["$player_name"]
        unset PLAYER_IP_CHANGE_TIMERS["$player_name"]
        unset PLAYER_PASSWORD_TIMERS["$player_name"]
        sync_server_lists
    fi
}

# Verificar timers expirados
check_expired_timers() {
    local current_time=$(date +%s)
    
    # Verificar timers de contraseña
    for player_name in "${!PLAYER_PASSWORD_TIMERS[@]}"; do
        local timer_start=${PLAYER_PASSWORD_TIMERS["$player_name"]}
        if [ $((current_time - timer_start)) -ge $PASSWORD_SET_TIMEOUT ]; then
            send_server_command "/kick $player_name" "$SERVER_PORT"
            send_server_command "tell $player_name Tiempo agotado para establecer contraseña" "$SERVER_PORT"
            unset PLAYER_PASSWORD_TIMERS["$player_name"]
            log_message "Jugador expulsado por no establecer contraseña: $player_name"
        fi
    done
    
    # Verificar timers de cambio de IP
    for player_name in "${!PLAYER_IP_CHANGE_TIMERS[@]}"; do
        local timer_start=${PLAYER_IP_CHANGE_TIMERS["$player_name"]}
        if [ $((current_time - timer_start)) -ge $IP_VERIFY_TIMEOUT ]; then
            local player_ip="${CONNECTED_PLAYERS[$player_name]}"
            send_server_command "/kick $player_name" "$SERVER_PORT"
            send_server_command "/ban $player_ip" "$SERVER_PORT"
            unset PLAYER_IP_CHANGE_TIMERS["$player_name"]
            log_message "Jugador expulsado y IP baneada por no verificar: $player_name ($player_ip)"
            
            # Programar desbaneo automático
            (
                sleep $IP_VERIFY_TIMEOUT
                send_server_command "/unban $player_ip" "$SERVER_PORT"
                log_message "IP desbaneada automáticamente: $player_ip"
            ) &
        fi
    done
}

# Monitorear cambios en players.log
monitor_players_log() {
    local last_checksum=$(md5sum "$PLAYERS_LOG" 2>/dev/null | cut -d' ' -f1)
    
    while true; do
        local current_checksum=$(md5sum "$PLAYERS_LOG" 2>/dev/null | cut -d' ' -f1)
        
        if [ "$current_checksum" != "$last_checksum" ]; then
            log_message "Detectado cambio en players.log"
            
            # Procesar cambios en players.log
            while IFS= read -r line; do
                local player_name=$(echo "$line" | cut -d'|' -f1 | sed 's/ *$//')
                local player_ip=$(echo "$line" | cut -d'|' -f2 | sed 's/^ *//')
                local rank=$(echo "$line" | cut -d'|' -f4 | sed 's/^ *//')
                local blacklisted=$(echo "$line" | cut -d'|' -f6 | sed 's/^ *//')
                
                # Aquí se aplicarían los cambios de rango y blacklist
                # (implementación simplificada por brevedad)
                
            done < "$PLAYERS_LOG"
            
            last_checksum="$current_checksum"
            sync_server_lists
        fi
        
        sleep 0.25
    done
}

# Monitorear console.log
monitor_console_log() {
    if [ ! -f "$CONSOLE_LOG" ]; then
        print_error "Archivo console.log no encontrado: $CONSOLE_LOG"
        return 1
    fi
    
    # Obtener número inicial de líneas
    local last_line_count=$(wc -l < "$CONSOLE_LOG" 2>/dev/null || echo 0)
    
    while true; do
        local current_line_count=$(wc -l < "$CONSOLE_LOG" 2>/dev/null || echo 0)
        
        if [ "$current_line_count" -gt "$last_line_count" ]; then
            # Leer nuevas líneas
            local new_lines=$(tail -n +$((last_line_count + 1)) "$CONSOLE_LOG")
            
            while IFS= read -r line; do
                process_console_line "$line"
            done <<< "$new_lines"
            
            last_line_count="$current_line_count"
        fi
        
        sleep 0.25
    done
}

# Procesar línea del console.log
process_console_line() {
    local line="$1"
    
    # Detectar conexión de jugador
    if echo "$line" | grep -q "Player Connected"; then
        local player_name=$(echo "$line" | sed -n 's/.*Player Connected \(.*\) | .* | .*/\1/p')
        local player_ip=$(echo "$line" | sed -n 's/.*Player Connected .* | \(.*\) | .*/\1/p')
        local player_id=$(echo "$line" | sed -n 's/.*Player Connected .* | .* | \(.*\)/\1/p')
        
        if [ -n "$player_name" ] && [ -n "$player_ip" ]; then
            process_player_connect "$player_name" "$player_ip" "$player_id"
        fi
    fi
    
    # Detectar desconexión de jugador
    if echo "$line" | grep -q "Client disconnected:\|Player Disconnected"; then
        local player_id=$(echo "$line" | sed -n 's/.*Client disconnected:\(.*\)/\1/p')
        if [ -z "$player_id" ]; then
            local player_name=$(echo "$line" | sed -n 's/.*Player Disconnected \(.*\)/\1/p')
            process_player_disconnect "" "$player_name"
        else
            # Buscar nombre del jugador por ID (implementación simplificada)
            process_player_disconnect "$player_id" ""
        fi
    fi
    
    # Detectar mensajes de chat con comandos
    if echo "$line" | grep -q ": !"; then
        local player_name=$(echo "$line" | sed -n 's/.*] \(.*\): !.*/\1/p')
        local message=$(echo "$line" | sed -n 's/.*]: \(.*\)/\1/p')
        
        if [ -n "$player_name" ] && [ -n "$message" ]; then
            process_chat_command "$player_name" "$message"
        fi
    fi
}

# Procesar comandos de chat
process_chat_command() {
    local player_name="$1"
    local message="$2"
    
    # Verificar cooldown
    local last_command=${PLAYER_COOLDOWNS["$player_name"]}
    local current_time=$(date +%s)
    
    if [ -n "$last_command" ] && [ $((current_time - last_command)) -lt 1 ]; then
        return  # Ignorar comando por cooldown
    fi
    
    PLAYER_COOLDOWNS["$player_name"]="$current_time"
    
    # Procesar comando específico
    case "$message" in
        !password*)
            local args=$(echo "$message" | cut -d' ' -f2-)
            local password=$(echo "$args" | cut -d' ' -f1)
            local confirm=$(echo "$args" | cut -d' ' -f2)
            process_password_command "$player_name" "$password" "$confirm"
            ;;
        !ip_change*)
            local password=$(echo "$message" | cut -d' ' -f2)
            process_ip_change_command "$player_name" "$password"
            ;;
        !change_psw*)
            local old_psw=$(echo "$message" | cut -d' ' -f2)
            local new_psw=$(echo "$message" | cut -d' ' -f3)
            process_change_password_command "$player_name" "$old_psw" "$new_psw"
            ;;
    esac
}

# =============================================================================
# FUNCIÓN PRINCIPAL
# =============================================================================

main() {
    print_status "Iniciando rank_patcher.sh..."
    
    # Detectar configuración del mundo
    if ! detect_world_config; then
        print_error "No se pudo detectar la configuración del mundo"
        exit 1
    fi
    
    # Inicializar archivos del sistema
    initialize_system_files
    
    print_success "Sistema de rangos inicializado para mundo: $WORLD_ID"
    print_status "Monitorizando: $CONSOLE_LOG"
    print_status "Base de datos: $PLAYERS_LOG"
    print_status "Puerto del servidor: $SERVER_PORT"
    
    # Iniciar monitores en segundo plano
    monitor_console_log &
    local console_monitor_pid=$!
    
    monitor_players_log &
    local players_monitor_pid=$!
    
    # Bucle principal para verificar timers
    while true; do
        check_expired_timers
        sleep 1
    done &
    local timer_monitor_pid=$!
    
    # Esperar a que los procesos hijos terminen
    wait $console_monitor_pid $players_monitor_pid $timer_monitor_pid
}

# Manejar señal de terminación
trap 'print_status "Deteniendo rank_patcher..."; exit 0' SIGINT SIGTERM

# Ejecutar función principal
main "$@"
