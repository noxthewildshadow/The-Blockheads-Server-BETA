#!/bin/bash

# rank_patcher.sh - Sistema de gestión de rangos y autenticación para The Blockheads
# Script que monitorea players.log y console.log para gestionar rangos, contraseñas y verificaciones de IP

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

# Directorio base del servidor
USER_HOME="$HOME"
BASE_DIR="$USER_HOME/GNUstep/Library/ApplicationSupport/TheBlockheads"
SAVES_DIR="$BASE_DIR/saves"

# Archivos de listas del servidor
ADMIN_LIST="$BASE_DIR/adminlist.txt"
MOD_LIST="$BASE_DIR/modlist.txt"
WHITE_LIST="$BASE_DIR/whitelist.txt"
BLACK_LIST="$BASE_DIR/blacklist.txt"
CLOUD_ADMIN_LIST="$BASE_DIR/cloudWideOwnedAdminlist.txt"

# Cooldowns
MONITOR_DELAY=0.25
MESSAGE_DELAY=0.5
IP_VERIFY_TIMEOUT=30
PASSWORD_SET_TIMEOUT=60

# Variables globales
declare -A PLAYER_IPS
declare -A PLAYER_PASSWORDS
declare -A PLAYER_RANKS
declare -A PLAYER_WHITELIST
declare -A PLAYER_BLACKLIST
declare -A PLAYER_VERIFIED_IPS
declare -A PLAYER_JOIN_TIMES
declare -A PLAYER_IP_CHANGE_TIMES
declare -A PLAYER_CURRENT_IPS
declare -A PLAYER_WORLDS

# =============================================================================
# FUNCIONES DE LOGGING Y UTILIDADES
# =============================================================================

print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_status() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_debug() { echo -e "${CYAN}[DEBUG]${NC} $1"; }

# Función para esperar cooldown
wait_cooldown() {
    sleep "$MESSAGE_DELAY"
}

# Función para enviar comando al servidor
send_command() {
    local world_id="$1"
    local command="$2"
    local console_file="$SAVES_DIR/${world_id}/console.log"
    
    # Simular entrada de comando (depende de cómo el servidor acepte comandos)
    echo "$command" >> "$console_file"
    print_debug "Comando enviado: $command"
}

# Función para limpiar chat
clear_chat() {
    local world_id="$1"
    send_command "$world_id" "/clear"
}

# =============================================================================
# FUNCIONES DE MANEJO DE ARCHIVOS
# =============================================================================

# Ignorar primeras 2 líneas de archivos de lista
read_list_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        tail -n +3 "$file"
    else
        touch "$file"
        echo "# Server managed list" > "$file"
        echo "# Do not edit manually" >> "$file"
    fi
}

write_list_file() {
    local file="$1"
    local content="$2"
    echo "# Server managed list" > "$file"
    echo "# Do not edit manually" >> "$file"
    echo "$content" >> "$file"
}

# =============================================================================
# FUNCIONES DE players.log
# =============================================================================

# Encontrar el primer mundo disponible para players.log
find_first_world() {
    for world_dir in "$SAVES_DIR"/*/; do
        if [[ -d "$world_dir" && "$world_dir" != "$SAVES_DIR/*/" ]]; then
            local world_id=$(basename "$world_dir")
            echo "$world_id"
            return 0
        fi
    done
    echo ""
    return 1
}

# Obtener ruta de players.log
get_players_log_path() {
    local world_id=$(find_first_world)
    if [[ -n "$world_id" ]]; then
        echo "$SAVES_DIR/$world_id/players.log"
    else
        echo ""
    fi
}

# Inicializar players.log
init_players_log() {
    local players_log=$(get_players_log_path)
    if [[ -n "$players_log" && ! -f "$players_log" ]]; then
        echo "# Players database - DO NOT EDIT MANUALLY" > "$players_log"
        echo "# Format: PLAYER_NAME | FIRST_IP | PASSWORD | RANK | WHITELISTED | BLACKLISTED" >> "$players_log"
        print_success "players.log creado en: $players_log"
    fi
}

# Cargar datos de players.log a memoria
load_players_data() {
    local players_log=$(get_players_log_path)
    if [[ -z "$players_log" || ! -f "$players_log" ]]; then
        return 1
    fi
    
    # Limpiar arrays
    PLAYER_IPS=()
    PLAYER_PASSWORDS=()
    PLAYER_RANKS=()
    PLAYER_WHITELIST=()
    PLAYER_BLACKLIST=()
    PLAYER_VERIFIED_IPS=()
    
    while IFS='|' read -r name ip password rank whitelisted blacklisted; do
        # Limpiar espacios
        name=$(echo "$name" | xargs)
        ip=$(echo "$ip" | xargs)
        password=$(echo "$password" | xargs)
        rank=$(echo "$rank" | xargs)
        whitelisted=$(echo "$whitelisted" | xargs)
        blacklisted=$(echo "$blacklisted" | xargs)
        
        # Saltar líneas de comentario
        if [[ "$name" == "#"* ]] || [[ -z "$name" ]]; then
            continue
        fi
        
        PLAYER_IPS["$name"]="$ip"
        PLAYER_PASSWORDS["$name"]="$password"
        PLAYER_RANKS["$name"]="$rank"
        PLAYER_WHITELIST["$name"]="$whitelisted"
        PLAYER_BLACKLIST["$name"]="$blacklisted"
        
        # Marcar IP como verificada si no es UNKNOWN
        if [[ "$ip" != "UNKNOWN" ]]; then
            PLAYER_VERIFIED_IPS["$name"]="$ip"
        fi
        
    done < <(grep -v "^#" "$players_log")
}

# Actualizar players.log desde memoria
update_players_log() {
    local players_log=$(get_players_log_path)
    if [[ -z "$players_log" ]]; then
        return 1
    fi
    
    # Crear backup
    cp "$players_log" "$players_log.backup" 2>/dev/null
    
    # Reconstruir archivo
    echo "# Players database - DO NOT EDIT MANUALLY" > "$players_log"
    echo "# Format: PLAYER_NAME | FIRST_IP | PASSWORD | RANK | WHITELISTED | BLACKLISTED" >> "$players_log"
    
    for player in "${!PLAYER_IPS[@]}"; do
        local ip="${PLAYER_IPS[$player]}"
        local password="${PLAYER_PASSWORDS[$player]:-NONE}"
        local rank="${PLAYER_RANKS[$player]:-NONE}"
        local whitelisted="${PLAYER_WHITELIST[$player]:-NO}"
        local blacklisted="${PLAYER_BLACKLIST[$player]:-NO}"
        
        echo "$player | $ip | $password | $rank | $whitelisted | $blacklisted" >> "$players_log"
    done
}

# =============================================================================
# FUNCIONES DE SINCRONIZACIÓN DE LISTAS
# =============================================================================

# Sincronizar listas del servidor con players.log
sync_server_lists() {
    # Admin list - solo jugadores con IP verificada y rango ADMIN
    local admin_content=""
    for player in "${!PLAYER_RANKS[@]}"; do
        if [[ "${PLAYER_RANKS[$player]}" == "ADMIN" && -n "${PLAYER_VERIFIED_IPS[$player]}" ]]; then
            admin_content+="$player"$'\n'
        fi
    done
    write_list_file "$ADMIN_LIST" "$admin_content"
    
    # Mod list - solo jugadores con IP verificada y rango MOD
    local mod_content=""
    for player in "${!PLAYER_RANKS[@]}"; do
        if [[ "${PLAYER_RANKS[$player]}" == "MOD" && -n "${PLAYER_VERIFIED_IPS[$player]}" ]]; then
            mod_content+="$player"$'\n'
        fi
    done
    write_list_file "$MOD_LIST" "$mod_content"
    
    # Whitelist
    local whitelist_content=""
    for player in "${!PLAYER_WHITELIST[@]}"; do
        if [[ "${PLAYER_WHITELIST[$player]}" == "YES" ]]; then
            whitelist_content+="$player"$'\n'
        fi
    done
    write_list_file "$WHITE_LIST" "$whitelist_content"
    
    # Blacklist
    local blacklist_content=""
    for player in "${!PLAYER_BLACKLIST[@]}"; do
        if [[ "${PLAYER_BLACKLIST[$player]}" == "YES" ]]; then
            blacklist_content+="$player"$'\n'
        fi
    done
    write_list_file "$BLACK_LIST" "$blacklist_content"
}

# =============================================================================
# FUNCIONES DE GESTIÓN DE RANGOS
# =============================================================================

# Aplicar cambios de rango
apply_rank_changes() {
    local players_log=$(get_players_log_path)
    local old_checksum="$1"
    local new_checksum="$2"
    
    if [[ "$old_checksum" == "$new_checksum" ]]; then
        return 0
    fi
    
    # Recargar datos
    load_players_data
    
    for player in "${!PLAYER_RANKS[@]}"; do
        local current_rank="${PLAYER_RANKS[$player]}"
        local world_id="${PLAYER_WORLDS[$player]}"
        
        if [[ -z "$world_id" ]]; then
            continue
        fi
        
        # Verificar cambios de rango y aplicar acciones
        case "$current_rank" in
            "ADMIN")
                if [[ "${PLAYER_PREV_RANKS[$player]}" != "ADMIN" ]]; then
                    wait_cooldown
                    send_command "$world_id" "/admin $player"
                    print_status "Rango ADMIN asignado a: $player"
                fi
                ;;
            "MOD")
                if [[ "${PLAYER_PREV_RANKS[$player]}" != "MOD" ]]; then
                    wait_cooldown
                    send_command "$world_id" "/mod $player"
                    print_status "Rango MOD asignado a: $player"
                fi
                ;;
            "SUPER")
                if [[ "${PLAYER_PREV_RANKS[$player]}" != "SUPER" ]]; then
                    # Agregar a cloudWideOwnedAdminlist.txt
                    if [[ ! -f "$CLOUD_ADMIN_LIST" ]]; then
                        touch "$CLOUD_ADMIN_LIST"
                    fi
                    if ! grep -q "$player" "$CLOUD_ADMIN_LIST"; then
                        echo "$player" >> "$CLOUD_ADMIN_LIST"
                    fi
                    print_status "Rango SUPER asignado a: $player"
                fi
                ;;
            "NONE")
                # Remover rangos anteriores
                if [[ "${PLAYER_PREV_RANKS[$player]}" == "ADMIN" ]]; then
                    wait_cooldown
                    send_command "$world_id" "/unadmin $player"
                    print_status "Rango ADMIN removido de: $player"
                elif [[ "${PLAYER_PREV_RANKS[$player]}" == "MOD" ]]; then
                    wait_cooldown
                    send_command "$world_id" "/unmod $player"
                    print_status "Rango MOD removido de: $player"
                elif [[ "${PLAYER_PREV_RANKS[$player]}" == "SUPER" ]]; then
                    # Remover de cloudWideOwnedAdminlist.txt
                    if [[ -f "$CLOUD_ADMIN_LIST" ]]; then
                        sed -i "/^$player$/d" "$CLOUD_ADMIN_LIST"
                    fi
                    print_status "Rango SUPER removido de: $player"
                fi
                ;;
        esac
        
        # Manejar blacklist
        if [[ "${PLAYER_BLACKLIST[$player]}" == "YES" && "${PLAYER_PREV_BLACKLIST[$player]}" != "YES" ]]; then
            wait_cooldown
            send_command "$world_id" "/unmod $player"
            wait_cooldown
            send_command "$world_id" "/unadmin $player"
            wait_cooldown
            send_command "$world_id" "/ban $player"
            wait_cooldown
            send_command "$world_id" "/ban ${PLAYER_IPS[$player]}"
            
            if [[ "${PLAYER_PREV_RANKS[$player]}" == "SUPER" ]]; then
                wait_cooldown
                send_command "$world_id" "/stop"
                if [[ -f "$CLOUD_ADMIN_LIST" ]]; then
                    sed -i "/^$player$/d" "$CLOUD_ADMIN_LIST"
                fi
            fi
            
            print_warning "Jugador $player agregado a blacklist"
        fi
    done
    
    # Sincronizar listas del servidor
    sync_server_lists
}

# =============================================================================
# FUNCIONES DE PROCESAMIENTO DE COMANDOS
# =============================================================================

# Validar contraseña
validate_password() {
    local password="$1"
    local confirm="$2"
    
    if [[ "$password" != "$confirm" ]]; then
        echo "Las contraseñas no coinciden"
        return 1
    fi
    
    if [[ ${#password} -lt 7 || ${#password} -gt 16 ]]; then
        echo "La contraseña debe tener entre 7 y 16 caracteres"
        return 1
    fi
    
    return 0
}

# Procesar comando !password
process_password_command() {
    local player="$1"
    local world_id="$2"
    local password="$3"
    local confirm="$4"
    
    clear_chat "$world_id"
    wait_cooldown
    
    local validation_result=$(validate_password "$password" "$confirm")
    if [[ $? -ne 0 ]]; then
        send_command "$world_id" "msg $player $validation_result"
        return 1
    fi
    
    # Actualizar contraseña en players.log
    PLAYER_PASSWORDS["$player"]="$password"
    update_players_log
    
    send_command "$world_id" "msg $player Contraseña establecida correctamente"
    print_success "Contraseña establecida para: $player"
    return 0
}

# Procesar comando !ip_change
process_ip_change_command() {
    local player="$1"
    local world_id="$2"
    local password="$3"
    
    clear_chat "$world_id"
    wait_cooldown
    
    # Verificar contraseña
    if [[ "${PLAYER_PASSWORDS[$player]}" != "$password" ]]; then
        send_command "$world_id" "msg $player Contraseña incorrecta"
        return 1
    fi
    
    # Actualizar IP verificada
    local current_ip="${PLAYER_CURRENT_IPS[$player]}"
    PLAYER_IPS["$player"]="$current_ip"
    PLAYER_VERIFIED_IPS["$player"]="$current_ip"
    unset PLAYER_IP_CHANGE_TIMES["$player"]
    update_players_log
    sync_server_lists
    
    send_command "$world_id" "msg $player IP verificada correctamente"
    print_success "IP verificada para: $player ($current_ip)"
    return 0
}

# Procesar comando !change_psw
process_change_password_command() {
    local player="$1"
    local world_id="$2"
    local old_password="$3"
    local new_password="$4"
    
    clear_chat "$world_id"
    wait_cooldown
    
    # Verificar contraseña actual
    if [[ "${PLAYER_PASSWORDS[$player]}" != "$old_password" ]]; then
        send_command "$world_id" "msg $player Contraseña actual incorrecta"
        return 1
    fi
    
    # Validar nueva contraseña
    local validation_result=$(validate_password "$new_password" "$new_password")
    if [[ $? -ne 0 ]]; then
        send_command "$world_id" "msg $player $validation_result"
        return 1
    fi
    
    # Actualizar contraseña
    PLAYER_PASSWORDS["$player"]="$new_password"
    update_players_log
    
    send_command "$world_id" "msg $player Contraseña cambiada correctamente"
    print_success "Contraseña cambiada para: $player"
    return 0
}

# =============================================================================
# FUNCIONES DE MONITOREO
# =============================================================================

# Procesar nuevas conexiones de jugadores
process_player_connection() {
    local world_id="$1"
    local player_name="$2"
    local player_ip="$3"
    local player_id="$4"
    
    PLAYER_CURRENT_IPS["$player_name"]="$player_ip"
    PLAYER_WORLDS["$player_name"]="$world_id"
    
    # Verificar si es un jugador nuevo
    if [[ -z "${PLAYER_IPS[$player_name]}" ]]; then
        # Jugador nuevo
        PLAYER_IPS["$player_name"]="$player_ip"
        PLAYER_PASSWORDS["$player_name"]="NONE"
        PLAYER_RANKS["$player_name"]="NONE"
        PLAYER_WHITELIST["$player_name"]="NO"
        PLAYER_BLACKLIST["$player_name"]="NO"
        PLAYER_JOIN_TIMES["$player_name"]=$(date +%s)
        update_players_log
        
        # Pedir contraseña si no tiene
        if [[ "${PLAYER_PASSWORDS[$player_name]}" == "NONE" ]]; then
            wait_cooldown
            send_command "$world_id" "msg $player_name Bienvenido! Usa !password tu_contraseña confirmar_contraseña para crear tu contraseña. Tienes 1 minuto."
        fi
    else
        # Jugador existente - verificar IP
        local stored_ip="${PLAYER_IPS[$player_name]}"
        if [[ "$stored_ip" != "UNKNOWN" && "$stored_ip" != "$player_ip" ]]; then
            PLAYER_IP_CHANGE_TIMES["$player_name"]=$(date +%s)
            wait_cooldown
            send_command "$world_id" "msg $player_name IP cambiada detectada. Usa !ip_change tu_contraseña en 30 segundos."
        fi
    fi
}

# Procesar desconexiones de jugadores
process_player_disconnection() {
    local player_name="$1"
    local player_id="$2"
    
    unset PLAYER_CURRENT_IPS["$player_name"]
    unset PLAYER_WORLDS["$player_name"]
    unset PLAYER_JOIN_TIMES["$player_name"]
    unset PLAYER_IP_CHANGE_TIMES["$player_name"]
}

# Monitorear archivo console.log de un mundo
monitor_world_console() {
    local world_id="$1"
    local console_log="$SAVES_DIR/$world_id/console.log"
    
    if [[ ! -f "$console_log" ]]; then
        print_warning "console.log no encontrado para mundo: $world_id"
        return 1
    fi
    
    # Usar inotifywait para monitorear cambios
    while inotifywait -q -e modify "$console_log" 2>/dev/null; do
        # Procesar nuevas líneas
        while read -r line; do
            # Detectar conexión de jugador
            if echo "$line" | grep -q "Player Connected"; then
                local player_info=$(echo "$line" | sed -n 's/.*Player Connected \(.*\) | \(.*\) | \(.*\)/\1|\2|\3/p')
                IFS='|' read -r player_name player_ip player_id <<< "$player_info"
                process_player_connection "$world_id" "$player_name" "$player_ip" "$player_id"
            
            # Detectar desconexión de jugador
            elif echo "$line" | grep -q "Client disconnected"; then
                local player_id=$(echo "$line" | sed -n 's/.*Client disconnected:\(.*\)/\1/p')
                for player in "${!PLAYER_CURRENT_IPS[@]}"; do
                    if [[ "${PLAYER_IDS[$player]}" == "$player_id" ]]; then
                        process_player_disconnection "$player" "$player_id"
                        break
                    fi
                done
            
            # Detectar comandos de chat
            elif echo "$line" | grep -q ": !"; then
                local player_name=$(echo "$line" | cut -d':' -f1 | xargs)
                local message=$(echo "$line" | cut -d'!' -f2- | xargs)
                
                case "$message" in
                    password*)
                        local args=$(echo "$message" | cut -d' ' -f2-)
                        local password=$(echo "$args" | cut -d' ' -f1)
                        local confirm=$(echo "$args" | cut -d' ' -f2)
                        process_password_command "$player_name" "$world_id" "$password" "$confirm"
                        ;;
                    ip_change*)
                        local password=$(echo "$message" | cut -d' ' -f2)
                        process_ip_change_command "$player_name" "$world_id" "$password"
                        ;;
                    change_psw*)
                        local args=$(echo "$message" | cut -d' ' -f2-)
                        local old_password=$(echo "$args" | cut -d' ' -f1)
                        local new_password=$(echo "$args" | cut -d' ' -f2)
                        process_change_password_command "$player_name" "$world_id" "$old_password" "$new_password"
                        ;;
                esac
            fi
        done < <(tail -n 1 "$console_log")
        
        sleep "$MONITOR_DELAY"
    done
}

# Monitorear cambios en players.log
monitor_players_log() {
    local players_log=$(get_players_log_path)
    if [[ -z "$players_log" ]]; then
        return 1
    fi
    
    local last_checksum=$(md5sum "$players_log" 2>/dev/null | cut -d' ' -f1)
    
    while true; do
        sleep "$MONITOR_DELAY"
        
        if [[ ! -f "$players_log" ]]; then
            continue
        fi
        
        local current_checksum=$(md5sum "$players_log" 2>/dev/null | cut -d' ' -f1)
        
        if [[ "$last_checksum" != "$current_checksum" ]]; then
            # Guardar estado anterior antes de recargar
            declare -A PLAYER_PREV_RANKS
            declare -A PLAYER_PREV_BLACKLIST
            for player in "${!PLAYER_RANKS[@]}"; do
                PLAYER_PREV_RANKS["$player"]="${PLAYER_RANKS[$player]}"
                PLAYER_PREV_BLACKLIST["$player"]="${PLAYER_BLACKLIST[$player]}"
            done
            
            # Recargar datos y aplicar cambios
            load_players_data
            apply_rank_changes "$last_checksum" "$current_checksum"
            
            last_checksum="$current_checksum"
        fi
    done
}

# Verificar timeouts periódicamente
check_timeouts() {
    while true; do
        local current_time=$(date +%s)
        
        # Verificar timeout de contraseña (1 minuto)
        for player in "${!PLAYER_JOIN_TIMES[@]}"; do
            local join_time="${PLAYER_JOIN_TIMES[$player]}"
            local world_id="${PLAYER_WORLDS[$player]}"
            
            if [[ -n "$join_time" && -n "$world_id" ]]; then
                local time_diff=$((current_time - join_time))
                
                if [[ $time_diff -ge $PASSWORD_SET_TIMEOUT && "${PLAYER_PASSWORDS[$player]}" == "NONE" ]]; then
                    wait_cooldown
                    send_command "$world_id" "/kick $player"
                    send_command "$world_id" "msg $player Tiempo agotado para crear contraseña"
                    print_warning "Jugador $player expulsado por no crear contraseña"
                    unset PLAYER_JOIN_TIMES["$player"]
                fi
            fi
        done
        
        # Verificar timeout de IP change (30 segundos)
        for player in "${!PLAYER_IP_CHANGE_TIMES[@]}"; do
            local change_time="${PLAYER_IP_CHANGE_TIMES[$player]}"
            local world_id="${PLAYER_WORLDS[$player]}"
            local player_ip="${PLAYER_CURRENT_IPS[$player]}"
            
            if [[ -n "$change_time" && -n "$world_id" ]]; then
                local time_diff=$((current_time - change_time))
                
                if [[ $time_diff -ge $IP_VERIFY_TIMEOUT ]]; then
                    wait_cooldown
                    send_command "$world_id" "/kick $player"
                    wait_cooldown
                    send_command "$world_id" "/ban $player_ip"
                    print_warning "Jugador $player expulsado y IP $player_ip baneada por timeout de verificación"
                    unset PLAYER_IP_CHANGE_TIMES["$player"]
                    
                    # Programar desbaneo automático después de 30 segundos
                    (
                        sleep 30
                        send_command "$world_id" "/unban $player_ip"
                        print_status "IP $player_ip desbaneada automáticamente"
                    ) &
                fi
            fi
        done
        
        sleep 5
    done
}

# =============================================================================
# FUNCIÓN PRINCIPAL
# =============================================================================

main() {
    print_status "Iniciando rank_patcher.sh - Sistema de gestión de rangos"
    
    # Verificar que el directorio base existe
    if [[ ! -d "$BASE_DIR" ]]; then
        print_error "Directorio base no encontrado: $BASE_DIR"
        exit 1
    fi
    
    # Esperar a que exista al menos un mundo
    print_status "Esperando a que exista un mundo..."
    while [[ -z "$(find_first_world)" ]]; do
        sleep 5
    done
    
    # Inicializar players.log
    init_players_log
    
    # Cargar datos iniciales
    load_players_data
    sync_server_lists
    
    print_success "Sistema de rangos inicializado correctamente"
    
    # Iniciar monitores en background
    monitor_players_log &
    check_timeouts &
    
    # Monitorear cada mundo
    while true; do
        for world_dir in "$SAVES_DIR"/*/; do
            if [[ -d "$world_dir" && "$world_dir" != "$SAVES_DIR/*/" ]]; then
                local world_id=$(basename "$world_dir")
                if [[ ! -f "$SAVES_DIR/$world_id/.monitored" ]]; then
                    touch "$SAVES_DIR/$world_id/.monitored"
                    monitor_world_console "$world_id" &
                    print_status "Monitoreando mundo: $world_id"
                fi
            fi
        done
        sleep 10
    done
}

# Manejar señal de terminación
trap 'print_status "Deteniendo rank_patcher.sh..."; exit 0' INT TERM

# Ejecutar función principal
main "$@"
