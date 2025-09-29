#!/bin/bash

# rank_patcher.sh - Complete player management system for The Blockheads server
# VERSIÓN COMPLETAMENTE CORREGIDA: Formato de log y envío de comandos

# Enhanced Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

# Function to print status messages
print_status() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_header() {
    echo -e "${PURPLE}================================================================"
    echo -e "$1"
    echo -e "===============================================================${NC}"
}

# Configuration
BASE_DIR="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves"
CONSOLE_LOG="$1"
WORLD_ID="$2"
PORT="$3"

# Extract world ID from console log path if not provided
if [ -z "$WORLD_ID" ] && [ -n "$CONSOLE_LOG" ]; then
    WORLD_ID=$(echo "$CONSOLE_LOG" | grep -oE 'saves/[^/]+' | cut -d'/' -f2)
fi

# Validate parameters
if [ -z "$CONSOLE_LOG" ] || [ -z "$WORLD_ID" ]; then
    print_error "Usage: $0 <console_log_path> [world_id] [port]"
    print_status "Example: $0 /path/to/console.log world123 12153"
    exit 1
fi

# File paths
PLAYERS_LOG="$BASE_DIR/$WORLD_ID/players.log"
ADMIN_LIST="$BASE_DIR/$WORLD_ID/adminlist.txt"
MOD_LIST="$BASE_DIR/$WORLD_ID/modlist.txt"
WHITELIST="$BASE_DIR/$WORLD_ID/whitelist.txt"
BLACKLIST="$BASE_DIR/$WORLD_ID/blacklist.txt"
CLOUD_ADMIN_LIST="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/cloudWideOwnedAdminlist.txt"

# Screen session for server commands
SCREEN_SERVER="blockheads_server_${PORT:-12153}"

# Cooldown configuration
COMMAND_COOLDOWN=1
PASSWORD_TIMEOUT=60
IP_VERIFY_TIMEOUT=30
IP_BAN_DURATION=30
WELCOME_DELAY=5
LIST_SYNC_INTERVAL=5

# Track connected players and their states
declare -A connected_players
declare -A player_ip_map
declare -A password_pending
declare -A ip_verify_pending
declare -A ip_banned_times

# Function to send commands to server with proper cooldown
send_server_command() {
    local command="$1"
    
    # Apply cooldown before sending command
    sleep "$COMMAND_COOLDOWN"
    
    print_status "Enviando comando al servidor: $command"
    
    # Enviar comando directamente a la sesión de screen
    if screen -S "$SCREEN_SERVER" -X stuff "$command"$(printf \\r) 2>/dev/null; then
        print_success "Comando enviado exitosamente: $command"
        return 0
    else
        print_error "Error al enviar comando: $command"
        return 1
    fi
}

# Function to kick player
kick_player() {
    local player_name="$1"
    local reason="$2"
    
    print_warning "Expulsando jugador: $player_name - Razón: $reason"
    send_server_command "/kick $player_name"
}

# Function to clear chat
clear_chat() {
    send_server_command "/clear"
}

# Function to initialize players.log with EXACT format
initialize_players_log() {
    if [ ! -f "$PLAYERS_LOG" ]; then
        print_status "Creando nuevo archivo players.log"
        mkdir -p "$(dirname "$PLAYERS_LOG")"
        touch "$PLAYERS_LOG"
        echo "# Player Name | First IP | Password | Rank | Whitelisted | Blacklisted" > "$PLAYERS_LOG"
        print_success "players.log creado en: $PLAYERS_LOG"
    else
        print_status "players.log ya existe: $PLAYERS_LOG"
    fi
}

# Function to read players.log into associative array
read_players_log() {
    declare -gA players_data
    
    if [ ! -f "$PLAYERS_LOG" ]; then
        print_error "players.log no encontrado: $PLAYERS_LOG"
        return 1
    fi
    
    while IFS='|' read -r name ip password rank whitelisted blacklisted; do
        # Skip header lines and empty lines
        [[ "$name" =~ ^# ]] && continue
        [[ -z "$name" ]] && continue
        
        # Clean up fields and apply EXACT defaults - NO EXTRA SPACES
        name=$(echo "$name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        ip=$(echo "$ip" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        password=$(echo "$password" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        rank=$(echo "$rank" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        whitelisted=$(echo "$whitelisted" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        blacklisted=$(echo "$blacklisted" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        
        # Apply required EXACT defaults
        [ -z "$name" ] && name="UNKNOWN"
        [ -z "$ip" ] && ip="UNKNOWN"
        [ -z "$password" ] && password="NONE"
        [ -z "$rank" ] && rank="NONE"
        [ -z "$whitelisted" ] && whitelisted="NO"
        [ -z "$blacklisted" ] && blacklisted="NO"
        
        if [ "$name" != "UNKNOWN" ]; then
            players_data["$name,name"]="$name"
            players_data["$name,ip"]="$ip"
            players_data["$name,password"]="$password"
            players_data["$name,rank"]="$rank"
            players_data["$name,whitelisted"]="$whitelisted"
            players_data["$name,blacklisted"]="$blacklisted"
        fi
    done < "$PLAYERS_LOG"
}

# Function to update players.log with EXACT format - NO EXTRA SPACES
update_players_log() {
    local player_name="$1" field="$2" new_value="$3"
    
    if [ -z "$player_name" ] || [ -z "$field" ]; then
        print_error "Parámetros inválidos para update_players_log"
        return 1
    fi
    
    # Read current data
    read_players_log
    
    # Update the field
    case "$field" in
        "ip") players_data["$player_name,ip"]="$new_value" ;;
        "password") players_data["$player_name,password"]="$new_value" ;;
        "rank") players_data["$player_name,rank"]="$new_value" ;;
        "whitelisted") players_data["$player_name,whitelisted"]="$new_value" ;;
        "blacklisted") players_data["$player_name,blacklisted"]="$new_value" ;;
        *) print_error "Campo desconocido: $field"; return 1 ;;
    esac
    
    # Write back to file with EXACT format - NO EXTRA SPACES
    {
        echo "# Player Name | First IP | Password | Rank | Whitelisted | Blacklisted"
        
        for key in "${!players_data[@]}"; do
            if [[ "$key" == *,name ]]; then
                local name="${players_data[$key]}"
                local ip="${players_data["$name,ip"]:-UNKNOWN}"
                local password="${players_data["$name,password"]:-NONE}"
                local rank="${players_data["$name,rank"]:-NONE}"
                local whitelisted="${players_data["$name,whitelisted"]:-NO}"
                local blacklisted="${players_data["$name,blacklisted"]:-NO}"
                
                # FORMATO EXACTO: Sin espacios extra, separadores exactos
                echo "$name | $ip | $password | $rank | $whitelisted | $blacklisted"
            fi
        done
    } > "$PLAYERS_LOG"
    
    print_success "players.log actualizado: $player_name $field = $new_value"
}

# Function to add new player to players.log with EXACT format
add_new_player() {
    local player_name="$1" player_ip="$2"
    
    if [ -z "$player_name" ] || [ -z "$player_ip" ]; then
        print_error "Parámetros inválidos para add_new_player"
        return 1
    fi
    
    # Check if player already exists
    read_players_log
    if [ -n "${players_data["$player_name,name"]}" ]; then
        print_warning "El jugador ya existe: $player_name"
        return 0
    fi
    
    # Add new player with EXACT defaults
    players_data["$player_name,name"]="$player_name"
    players_data["$player_name,ip"]="$player_ip"
    players_data["$player_name,password"]="NONE"
    players_data["$player_name,rank"]="NONE"
    players_data["$player_name,whitelisted"]="NO"
    players_data["$player_name,blacklisted"]="NO"
    
    # Write back to file with EXACT format
    {
        echo "# Player Name | First IP | Password | Rank | Whitelisted | Blacklisted"
        
        for key in "${!players_data[@]}"; do
            if [[ "$key" == *,name ]]; then
                local name="${players_data[$key]}"
                local ip="${players_data["$name,ip"]:-UNKNOWN}"
                local password="${players_data["$name,password"]:-NONE}"
                local rank="${players_data["$name,rank"]:-NONE}"
                local whitelisted="${players_data["$name,whitelisted"]:-NO}"
                local blacklisted="${players_data["$name,blacklisted"]:-NO}"
                
                # FORMATO EXACTO: Sin espacios extra
                echo "$name | $ip | $password | $rank | $whitelisted | $blacklisted"
            fi
        done
    } > "$PLAYERS_LOG"
    
    print_success "Nuevo jugador agregado: $player_name ($player_ip)"
}

# Function to check if IP is verified for a player
is_ip_verified() {
    local player_name="$1"
    local current_ip="$2"
    
    read_players_log
    local stored_ip="${players_data["$player_name,ip"]}"
    
    # If stored IP is UNKNOWN or matches current IP, consider verified
    if [ "$stored_ip" = "UNKNOWN" ] || [ "$stored_ip" = "$current_ip" ]; then
        return 0
    fi
    
    # IP doesn't match and not UNKNOWN - requires verification
    return 1
}

# Function to sync server lists from players.log - EMPTY FILES
sync_server_lists() {
    print_status "Sincronizando listas del servidor desde players.log..."
    
    # Read current player data
    read_players_log
    
    # Clear existing lists COMPLETELY - EMPTY FILES
    for list_file in "$ADMIN_LIST" "$MOD_LIST" "$WHITELIST" "$BLACKLIST"; do
        # Create empty file (no headers, no content)
        > "$list_file"
    done
    
    # Sync cloud admin list - EMPTY FILE
    > "$CLOUD_ADMIN_LIST"
    
    # Add players to appropriate lists based on rank and status
    # Only add if IP is verified and player is connected
    for key in "${!players_data[@]}"; do
        if [[ "$key" == *,name ]]; then
            local name="${players_data[$key]}"
            local ip="${players_data["$name,ip"]}"
            local rank="${players_data["$name,rank"]}"
            local whitelisted="${players_data["$name,whitelisted"]}"
            local blacklisted="${players_data["$name,blacklisted"]}"
            local current_ip="${player_ip_map[$name]}"
            
            # Only apply ranks if IP is verified AND player is connected
            if [ -n "${connected_players[$name]}" ] && is_ip_verified "$name" "$current_ip"; then
                case "$rank" in
                    "ADMIN")
                        echo "$name" >> "$ADMIN_LIST"
                        ;;
                    "MOD")
                        echo "$name" >> "$MOD_LIST"
                        ;;
                    "SUPER")
                        echo "$name" >> "$CLOUD_ADMIN_LIST"
                        ;;
                esac
                
                if [ "$whitelisted" = "YES" ]; then
                    echo "$name" >> "$WHITELIST"
                fi
                
                if [ "$blacklisted" = "YES" ]; then
                    echo "$name" >> "$BLACKLIST"
                fi
            fi
        fi
    done
    
    print_success "Listas del servidor sincronizadas"
}

# Function to handle rank changes with proper cooldowns
handle_rank_change() {
    local player_name="$1" old_rank="$2" new_rank="$3"
    
    case "$new_rank" in
        "ADMIN")
            if [ "$old_rank" = "NONE" ]; then
                send_server_command "/admin $player_name"
                print_success "Promovido $player_name a ADMIN"
            fi
            ;;
        "MOD")
            if [ "$old_rank" = "NONE" ]; then
                send_server_command "/mod $player_name"
                print_success "Promovido $player_name a MOD"
            fi
            ;;
        "SUPER")
            # For SUPER rank, add to cloud admin list
            if ! tail -n +3 "$CLOUD_ADMIN_LIST" 2>/dev/null | grep -q "^$player_name$"; then
                echo "$player_name" >> "$CLOUD_ADMIN_LIST"
                print_success "Agregado $player_name a la lista de administradores global"
            fi
            ;;
        "NONE")
            if [ "$old_rank" = "ADMIN" ]; then
                send_server_command "/unadmin $player_name"
                print_success "Degradado $player_name de ADMIN a NONE"
            elif [ "$old_rank" = "MOD" ]; then
                send_server_command "/unmod $player_name"
                print_success "Degradado $player_name de MOD a NONE"
            elif [ "$old_rank" = "SUPER" ]; then
                # Remove from cloud admin list
                temp_file=$(mktemp)
                tail -n +3 "$CLOUD_ADMIN_LIST" 2>/dev/null | grep -v "^$player_name$" > "$temp_file"
                mv "$temp_file" "$CLOUD_ADMIN_LIST"
                print_success "Removido $player_name de la lista de administradores global"
            fi
            ;;
    esac
}

# Function to handle blacklist changes with proper cooldowns
handle_blacklist_change() {
    local player_name="$1" blacklisted="$2" player_ip="$3"
    
    if [ "$blacklisted" = "YES" ]; then
        read_players_log
        local rank="${players_data["$player_name,rank"]}"
        
        # Special handling for SUPER rank - stop server first if connected
        if [ "$rank" = "SUPER" ] && [ -n "${connected_players[$player_name]}" ]; then
            print_warning "ADMIN SUPER en lista negra - deteniendo servidor primero"
            send_server_command "/stop"
            sleep 2
        fi
        
        # Remove privileges first
        if [ "$rank" = "MOD" ]; then
            send_server_command "/unmod $player_name"
        elif [ "$rank" = "ADMIN" ] || [ "$rank" = "SUPER" ]; then
            send_server_command "/unadmin $player_name"
        fi
        
        # Remove from cloud admin list if SUPER
        if [ "$rank" = "SUPER" ]; then
            temp_file=$(mktemp)
            tail -n +3 "$CLOUD_ADMIN_LIST" 2>/dev/null | grep -v "^$player_name$" > "$temp_file"
            mv "$temp_file" "$CLOUD_ADMIN_LIST"
        fi
        
        # Ban player and IP
        send_server_command "/ban $player_name"
        
        if [ "$player_ip" != "UNKNOWN" ]; then
            send_server_command "/ban $player_ip"
            # Track ban time for auto-unban
            ip_banned_times["$player_ip"]=$(date +%s)
        fi
        
        print_success "Jugador baneado: $player_name ($player_ip)"
    fi
}

# Function to auto-unban IP addresses after timeout
auto_unban_ips() {
    local current_time=$(date +%s)
    
    for ip in "${!ip_banned_times[@]}"; do
        local ban_time="${ip_banned_times[$ip]}"
        if [ $((current_time - ban_time)) -ge $IP_BAN_DURATION ]; then
            send_server_command "/unban $ip"
            print_status "IP auto-desbaneada: $ip"
            unset ip_banned_times["$ip"]
        fi
    done
}

# Function to validate password
validate_password() {
    local password="$1"
    local length=${#password}
    
    if [ $length -lt 7 ] || [ $length -gt 16 ]; then
        echo "La contraseña debe tener entre 7 y 16 caracteres"
        return 1
    fi
    
    if ! echo "$password" | grep -qE '^[A-Za-z0-9!@#$%^_+-=]+$'; then
        echo "La contraseña contiene caracteres inválidos. Solo letras, números y !@#$%^_+-= están permitidos"
        return 1
    fi
    
    return 0
}

# Function to handle password commands
handle_password_command() {
    local player_name="$1" password="$2" confirm_password="$3"
    
    if [ "$password" != "$confirm_password" ]; then
        send_server_command "Las contraseñas no coinciden"
        return 1
    fi
    
    local validation_result
    validation_result=$(validate_password "$password")
    if [ $? -ne 0 ]; then
        send_server_command "$validation_result"
        return 1
    fi
    
    # Update password in players.log
    update_players_log "$player_name" "password" "$password"
    send_server_command "Contraseña establecida exitosamente para $player_name"
    
    # Remove from password pending
    unset password_pending["$player_name"]
    return 0
}

# Function to handle IP change verification
handle_ip_change() {
    local player_name="$1" provided_password="$2" current_ip="$3"
    
    # Verify password
    read_players_log
    local stored_password="${players_data["$player_name,password"]}"
    
    if [ "$stored_password" = "NONE" ]; then
        send_server_command "No hay contraseña establecida para $player_name. Usa !password primero."
        return 1
    fi
    
    if [ "$provided_password" != "$stored_password" ]; then
        send_server_command "Contraseña incorrecta para verificación de IP"
        return 1
    fi
    
    # Update IP in players.log
    update_players_log "$player_name" "ip" "$current_ip"
    send_server_command "Dirección IP verificada y actualizada para $player_name"
    
    # Clear pending verification
    unset ip_verify_pending["$player_name"]
    return 0
}

# Function to handle password change
handle_password_change() {
    local player_name="$1" old_password="$2" new_password="$3"
    
    # Verify old password
    read_players_log
    local stored_password="${players_data["$player_name,password"]}"
    
    if [ "$stored_password" = "NONE" ]; then
        send_server_command "No se encontró contraseña existente para $player_name"
        return 1
    fi
    
    if [ "$old_password" != "$stored_password" ]; then
        send_server_command "Contraseña antigua incorrecta"
        return 1
    fi
    
    local validation_result
    validation_result=$(validate_password "$new_password")
    if [ $? -ne 0 ]; then
        send_server_command "$validation_result"
        return 1
    fi
    
    # Update password
    update_players_log "$player_name" "password" "$new_password"
    send_server_command "Contraseña cambiada exitosamente para $player_name"
    return 0
}

# Function to send welcome message after delay
send_welcome_message() {
    local player_name="$1" is_new_player="$2"
    
    # Wait 5 seconds before sending welcome message
    sleep "$WELCOME_DELAY"
    
    if [ "$is_new_player" = "true" ]; then
        send_server_command "¡Bienvenido $player_name! Por favor establece una contraseña usando: !password TU_CONTRASEÑA CONFIRMAR_CONTRASEÑA"
    else
        send_server_command "¡Bienvenido de nuevo $player_name!"
    fi
}

# Function to send IP change warning after delay
send_ip_warning() {
    local player_name="$1"
    
    # Wait 5 seconds before sending warning
    sleep "$WELCOME_DELAY"
    
    send_server_command "Cambio de IP detectado para $player_name. Verifica con: !ip_change TU_CONTRASEÑA"
    send_server_command "Tienes 30 segundos para verificar tu IP o serás expulsado y baneado por IP."
}

# Function to monitor console.log for events - CORREGIDO: Formato exacto del log
monitor_console_log() {
    print_header "Iniciando monitoreo de rank_patcher"
    print_status "Mundo: $WORLD_ID"
    print_status "Log de consola: $CONSOLE_LOG"
    print_status "Log de jugadores: $PLAYERS_LOG"
    
    # Initialize files
    initialize_players_log
    sync_server_lists
    
    print_status "Monitoreando archivo de log: $CONSOLE_LOG"
    
    # Monitor the log file
    tail -n 0 -F "$CONSOLE_LOG" | while read line; do
        # Detect player connections - FORMATO CORREGIDO
        if [[ "$line" =~ Player\ Connected\ ([a-zA-Z0-9_]+)\ \|\ ([0-9\.]+)\ \|\ [a-f0-9]+ ]]; then
            local player_name="${BASH_REMATCH[1]}"
            local player_ip="${BASH_REMATCH[2]}"
            
            print_success "Jugador conectado: $player_name ($player_ip)"
            
            # Add to connected players
            connected_players["$player_name"]=1
            player_ip_map["$player_name"]="$player_ip"
            
            # Check if player exists in players.log
            read_players_log
            if [ -z "${players_data["$player_name,name"]}" ]; then
                # New player - add to players.log
                print_status "Nuevo jugador detectado: $player_name"
                add_new_player "$player_name" "$player_ip"
                
                # Send welcome message after delay
                send_welcome_message "$player_name" "true" &
                password_pending["$player_name"]=$(date +%s)
                print_status "Temporizador de contraseña iniciado para $player_name (60 segundos)"
            else
                # Existing player - check IP
                local stored_ip="${players_data["$player_name,ip"]}"
                local stored_password="${players_data["$player_name,password"]}"
                
                if [ "$stored_ip" != "$player_ip" ] && [ "$stored_ip" != "UNKNOWN" ]; then
                    # IP changed - require verification
                    print_warning "Cambio de IP detectado para $player_name: $stored_ip -> $player_ip"
                    send_ip_warning "$player_name" &
                    ip_verify_pending["$player_name"]=$(date +%s)
                    print_status "Temporizador de verificación de IP iniciado para $player_name (30 segundos)"
                fi
                
                # Check if password is set
                if [ "$stored_password" = "NONE" ]; then
                    send_welcome_message "$player_name" "false" &
                    password_pending["$player_name"]=$(date +%s)
                    print_status "Temporizador de contraseña iniciado para $player_name (60 segundos)"
                fi
            fi
            
            # Sync lists after connection
            sync_server_lists
            continue
        fi
        
        # Detect player disconnections
        if [[ "$line" =~ Player\ Disconnected\ ([a-zA-Z0-9_]+) ]]; then
            local player_name="${BASH_REMATCH[1]}"
            
            print_warning "Jugador desconectado: $player_name"
            
            # Remove from connected players
            unset connected_players["$player_name"]
            unset player_ip_map["$player_name"]
            unset password_pending["$player_name"]
            unset ip_verify_pending["$player_name"]
            
            # Sync lists after disconnection
            sync_server_lists
            continue
        fi
        
        # Detect chat messages and commands
        if [[ "$line" =~ ([a-zA-Z0-9_]+):\ (.+)$ ]]; then
            local player_name="${BASH_REMATCH[1]}"
            local message="${BASH_REMATCH[2]}"
            
            # Skip server messages
            [ "$player_name" = "SERVER" ] && continue
            
            # Process commands
            case "$message" in
                "!password "*)
                    if [[ "$message" =~ !password\ ([^ ]+)\ ([^ ]+) ]]; then
                        local password="${BASH_REMATCH[1]}"
                        local confirm_password="${BASH_REMATCH[2]}"
                        print_status "Comando de contraseña recibido de $player_name"
                        handle_password_command "$player_name" "$password" "$confirm_password"
                    else
                        send_server_command "Uso: !password NUEVA_CONTRASEÑA CONFIRMAR_CONTRASEÑA"
                    fi
                    ;;
                "!ip_change "*)
                    if [[ "$message" =~ !ip_change\ ([^ ]+) ]]; then
                        local password="${BASH_REMATCH[1]}"
                        local current_ip="${player_ip_map[$player_name]}"
                        print_status "Comando de cambio de IP recibido de $player_name"
                        handle_ip_change "$player_name" "$password" "$current_ip"
                    else
                        send_server_command "Uso: !ip_change TU_CONTRASEÑA"
                    fi
                    ;;
                "!change_psw "*)
                    if [[ "$message" =~ !change_psw\ ([^ ]+)\ ([^ ]+) ]]; then
                        local old_password="${BASH_REMATCH[1]}"
                        local new_password="${BASH_REMATCH[2]}"
                        print_status "Comando de cambio de contraseña recibido de $player_name"
                        handle_password_change "$player_name" "$old_password" "$new_password"
                    else
                        send_server_command "Uso: !change_psw CONTRASEÑA_ANTIGUA NUEVA_CONTRASEÑA"
                    fi
                    ;;
            esac
        fi
    done
}

# Function to monitor players.log for changes every 1 second
monitor_players_log() {
    local last_modified=0
    
    while true; do
        if [ -f "$PLAYERS_LOG" ]; then
            local current_modified=$(stat -c %Y "$PLAYERS_LOG" 2>/dev/null || stat -f %m "$PLAYERS_LOG")
            
            if [ "$current_modified" -ne "$last_modified" ]; then
                print_status "players.log modificado - procesando cambios"
                
                # Read previous state
                declare -A old_players_data
                for key in "${!players_data[@]}"; do
                    old_players_data["$key"]="${players_data[$key]}"
                done
                
                # Read new state
                read_players_log
                
                # Compare and handle changes
                for key in "${!players_data[@]}"; do
                    if [[ "$key" == *,name ]]; then
                        local player_name="${players_data[$key]}"
                        local old_rank="${old_players_data["$player_name,rank"]:-NONE}"
                        local new_rank="${players_data["$player_name,rank"]:-NONE}"
                        local old_blacklisted="${old_players_data["$player_name,blacklisted"]:-NO}"
                        local new_blacklisted="${players_data["$player_name,blacklisted"]:-NO}"
                        local player_ip="${players_data["$player_name,ip"]}"
                        
                        # Handle rank changes
                        if [ "$old_rank" != "$new_rank" ]; then
                            handle_rank_change "$player_name" "$old_rank" "$new_rank"
                        fi
                        
                        # Handle blacklist changes
                        if [ "$old_blacklisted" != "$new_blacklisted" ]; then
                            handle_blacklist_change "$player_name" "$new_blacklisted" "$player_ip"
                        fi
                    fi
                done
                
                # Sync server lists
                sync_server_lists
                
                last_modified="$current_modified"
            fi
        fi
        
        sleep 1
    done
}

# Function to check timeouts - CORREGIDO: Ejecuta /kick directamente
check_timeouts() {
    local current_time=$(date +%s)
    
    # Check password setup timeouts - 60 seconds
    for player in "${!password_pending[@]}"; do
        local start_time="${password_pending[$player]}"
        local elapsed=$((current_time - start_time))
        
        if [ $elapsed -ge $PASSWORD_TIMEOUT ]; then
            print_warning "Tiempo de contraseña agotado para $player - expulsando jugador"
            kick_player "$player" "No se estableció contraseña en 60 segundos"
            unset password_pending["$player"]
        else
            print_status "Temporizador de contraseña para $player: $elapsed/$PASSWORD_TIMEOUT segundos"
        fi
    done
    
    # Check IP verification timeouts - 30 seconds
    for player in "${!ip_verify_pending[@]}"; do
        local start_time="${ip_verify_pending[$player]}"
        local elapsed=$((current_time - start_time))
        
        if [ $elapsed -ge $IP_VERIFY_TIMEOUT ]; then
            local player_ip="${player_ip_map[$player]}"
            print_warning "Tiempo de verificación de IP agotado para $player - expulsando y baneando IP"
            kick_player "$player" "Fallo en verificación de IP en 30 segundos"
            send_server_command "/ban $player_ip"
            unset ip_verify_pending["$player"]
            
            # Track ban for auto-unban
            ip_banned_times["$player_ip"]=$(date +%s)
        else
            print_status "Temporizador de IP para $player: $elapsed/$IP_VERIFY_TIMEOUT segundos"
        fi
    done
    
    # Auto-unban IPs after duration
    auto_unban_ips
}

# Function to periodically sync lists every 5 seconds
periodic_list_sync() {
    while true; do
        sleep "$LIST_SYNC_INTERVAL"
        print_status "Sincronización periódica de listas (cada $LIST_SYNC_INTERVAL segundos)"
        sync_server_lists
    done
}

# Main execution
main() {
    print_header "THE BLOCKHEADS RANK PATCHER - COMPLETAMENTE CORREGIDO"
    print_status "Iniciando sistema de gestión de jugadores..."
    
    # Check if console log exists
    if [ ! -f "$CONSOLE_LOG" ]; then
        print_error "Log de consola no encontrado: $CONSOLE_LOG"
        print_status "Esperando a que se cree el archivo de log..."
        
        # Wait for log file
        local wait_time=0
        while [ ! -f "$CONSOLE_LOG" ] && [ $wait_time -lt 30 ]; do
            sleep 1
            ((wait_time++))
        done
        
        if [ ! -f "$CONSOLE_LOG" ]; then
            print_error "El log de consola nunca apareció: $CONSOLE_LOG"
            exit 1
        fi
    fi
    
    # Start monitoring processes in background
    monitor_console_log &
    local console_pid=$!
    
    monitor_players_log &
    local players_pid=$!
    
    periodic_list_sync &
    local sync_pid=$!
    
    print_success "Todos los procesos de monitoreo iniciados"
    print_status "PID Consola: $console_pid"
    print_status "PID Players: $players_pid" 
    print_status "PID Sincronización: $sync_pid"
    
    # Main loop for timeout checking
    while true; do
        check_timeouts
        sleep 5
    done
    
    # Wait for background processes (should never reach here)
    wait $console_pid $players_pid $sync_pid
}

# Start main function
main "$@"
