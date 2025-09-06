#!/bin/bash
# anticheat_secure.sh - Centralized security system for The Blockheads server
# Intercepts all ! commands, validates permissions, and forwards authorized commands

# Enhanced Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m' # No Color

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
LOG_FILE="$1"
PORT="$2"
LOG_DIR=$(dirname "$LOG_FILE")
ADMIN_OFFENSES_FILE="$LOG_DIR/admin_offenses_$PORT.json"
AUTHORIZED_ADMINS_FILE="$LOG_DIR/authorized_admins.txt"
AUTHORIZED_MODS_FILE="$LOG_DIR/authorized_mods.txt"
SCREEN_SERVER="blockheads_server_$PORT"
SECURITY_LOG="$LOG_DIR/security_$PORT.log"

# Command mapping and permissions
declare -A COMMAND_MAPPING=(
    ["!CLEAR-ADMINLIST"]="/CLEAR-ADMINLIST"
    ["!CLEAR-MODLIST"]="/CLEAR-MODLIST"
    ["!CLEAR-WHITELIST"]="/CLEAR-WHITELIST"
    ["!CLEAR-BLACKLIST"]="/CLEAR-BLACKLIST"
    ["!RESET-OWNER"]="/RESET-OWNER"
    ["!UNADMIN"]="/UNADMIN"
    ["!ADMIN"]="/ADMIN"
    ["!UNMOD"]="/UNMOD"
    ["!MOD"]="/MOD"
    ["!LOAD-LISTS"]="/LOAD-LISTS"
    ["!LIST-ADMINLIST"]="/LIST-ADMINLIST"
    ["!LIST-MODLIST"]="/LIST-MODLIST"
    ["!STOP"]="/STOP"
    ["!DEBUG-LOG"]="/DEBUG-LOG"
    ["!LIST-WHITELIST"]="/LIST-WHITELIST"
    ["!LIST-BLACKLIST"]="/LIST-BLACKLIST"
    ["!UNWHITELIST"]="/UNWHITELIST"
    ["!WHITELIST"]="/WHITELIST"
    ["!UNBAN"]="/UNBAN"
    ["!BAN-NO-DEVICE"]="/BAN-NO-DEVICE"
    ["!BAN"]="/BAN"
    ["!KICK"]="/KICK"
    ["!PLAYERS"]="/PLAYERS"
    ["!HELP-S"]="/HELP"
)

# Admin-only commands
declare -A ADMIN_ONLY_COMMANDS=(
    ["!CLEAR-ADMINLIST"]=1
    ["!CLEAR-MODLIST"]=1
    ["!CLEAR-WHITELIST"]=1
    ["!CLEAR-BLACKLIST"]=1
    ["!RESET-OWNER"]=1
    ["!UNADMIN"]=1
    ["!ADMIN"]=1
    ["!UNMOD"]=1
    ["!MOD"]=1
    ["!LOAD-LISTS"]=1
    ["!UNWHITELIST"]=1
    ["!WHITELIST"]=1
    ["!UNBAN"]=1
    ["!BAN-NO-DEVICE"]=1
)

# Mod allowed commands
declare -A MOD_ALLOWED_COMMANDS=(
    ["!LIST-ADMINLIST"]=1
    ["!LIST-MODLIST"]=1
    ["!LIST-WHITELIST"]=1
    ["!LIST-BLACKLIST"]=1
    ["!BAN"]=1
    ["!KICK"]=1
    ["!PLAYERS"]=1
    ["!HELP-S"]=1
)

# Public commands
declare -A PUBLIC_COMMANDS=(
    ["!HELP"]=1
)

# Function to validate player names
is_valid_player_name() {
    local player_name="$1"
    # Remove leading/trailing spaces first
    player_name=$(echo "$player_name" | xargs)
    [[ "$player_name" =~ ^[a-zA-Z0-9_]{3,20}$ ]]
}

# Function to detect and handle invalid player names
handle_invalid_player_name() {
    local player_name="$1" player_ip="$2" player_hash="$3"
    
    # Trim spaces for validation
    local player_name_trimmed=$(echo "$player_name" | xargs)
    
    # Check if name is empty after trimming or contains invalid characters
    if [[ -z "$player_name_trimmed" ]]; then
        send_warning_message "$player_name" "Nombre inválido: contiene espacios. Corrige tu nombre y vuelve a conectarte."
        return 0
    elif [[ "$player_name" =~ [^a-zA-Z0-9_] ]]; then
        send_warning_message "$player_name" "Nombre inválido: contiene caracteres no permitidos."
        return 0
    elif [[ "$player_name" =~ $'\x00' ]]; then
        send_warning_message "$player_name" "Nombre inválido: contiene null bytes o caracteres de control."
        return 0
    fi
    return 1
}

# Function to send warning message and kick after 10ms
send_warning_message() {
    local player_name="$1" message="$2"
    
    # Check for duplicate warnings within 2 seconds
    local current_time=$(date +%s)
    local last_warning_time=$(get_last_warning_time "$player_name")
    
    if [ $((current_time - last_warning_time)) -le 2 ]; then
        print_warning "Skipping duplicate warning for $player_name"
        return
    fi
    
    # Send warning message
    send_server_command "say $message"
    
    # Schedule kick after 10ms
    (
        usleep 10000  # 10ms delay
        print_warning "Kicking player with invalid name: '$player_name'"
        send_server_command "/kick $player_name"
    ) &
    
    # Record warning time
    record_warning_time "$player_name" "$current_time"
}

# Function to get last warning time
get_last_warning_time() {
    local player_name="$1"
    local warning_file="$LOG_DIR/warnings_$PORT.json"
    
    if [ ! -f "$warning_file" ]; then
        echo "0"
        return
    fi
    
    jq -r --arg player "$player_name" '.[$player] // 0' "$warning_file" 2>/dev/null || echo "0"
}

# Function to record warning time
record_warning_time() {
    local player_name="$1" time="$2"
    local warning_file="$LOG_DIR/warnings_$PORT.json"
    
    if [ ! -f "$warning_file" ]; then
        echo "{}" > "$warning_file"
    fi
    
    local current_data=$(jq --arg player "$player_name" --argjson time "$time" '.[$player] = $time' "$warning_file")
    echo "$current_data" > "$warning_file"
}

# Function to safely read JSON files
read_json_file() {
    local file_path="$1"
    if [ ! -f "$file_path" ]; then
        print_error "JSON file not found: $file_path"
        echo "{}"
        return 1
    fi
    jq -r '.' "$file_path" 2>/dev/null || echo "{}"
}

# Function to safely write JSON files
write_json_file() {
    local file_path="$1"
    local content="$2"
    
    if [ ! -f "$file_path" ]; then
        print_error "JSON file not found: $file_path"
        return 1
    fi
    
    echo "$content" | jq '.' > "$file_path"
    return $?
}

# Function to initialize authorization files
initialize_authorization_files() {
    [ ! -f "$AUTHORIZED_ADMINS_FILE" ] && touch "$AUTHORIZED_ADMINS_FILE" && print_success "Created authorized admins file: $AUTHORIZED_ADMINS_FILE"
    [ ! -f "$AUTHORIZED_MODS_FILE" ] && touch "$AUTHORIZED_MODS_FILE" && print_success "Created authorized mods file: $AUTHORIZED_MODS_FILE"
}

# Function to check if player is admin
is_player_admin() {
    local player_name="$1"
    [ -f "$AUTHORIZED_ADMINS_FILE" ] && grep -q -i "^$player_name$" "$AUTHORIZED_ADMINS_FILE"
}

# Function to check if player is mod
is_player_mod() {
    local player_name="$1"
    [ -f "$AUTHORIZED_MODS_FILE" ] && grep -q -i "^$player_name$" "$AUTHORIZED_MODS_FILE"
}

# Function to send server command
send_server_command() {
    if screen -S "$SCREEN_SERVER" -X stuff "$1$(printf \\r)" 2>/dev/null; then
        print_success "Sent message to server: $1"
        return 0
    else
        print_error "Could not send message to server. Is the server running?"
        return 1
    fi
}

# Function to send message to player
send_player_message() {
    local player_name="$1" message="$2"
    send_server_command "tell $player_name $message"
}

# Function to validate command input
validate_command_input() {
    local input="$1"
    
    # Check for null bytes
    if [[ "$input" =~ $'\x00' ]]; then
        print_error "Command contains null bytes"
        return 1
    fi
    
    # Check for control characters
    if [[ "$input" =~ [[:cntrl:]] && ! "$input" =~ $'\r' && ! "$input" =~ $'\n' ]]; then
        print_error "Command contains control characters"
        return 1
    fi
    
    # Check length
    if [ ${#input} -gt 256 ]; then
        print_error "Command too long"
        return 1
    fi
    
    return 0
}

# Function to normalize command
normalize_command() {
    local command="$1"
    # Convert to uppercase and replace variants
    command=$(echo "$command" | tr '[:lower:]' '[:upper:]' | tr '-' '_')
    echo "$command"
}

# Function to parse command and arguments
parse_command() {
    local message="$1"
    local command_args=()
    
    # Remove leading ! and split into command and arguments
    local clean_message=$(echo "$message" | sed 's/^!\s*//')
    read -ra command_args <<< "$clean_message"
    
    local command="${command_args[0]}"
    local args="${command_args[@]:1}"
    
    # Normalize command
    command=$(normalize_command "$command")
    
    echo "$command $args"
}

# Function to check command permissions
check_command_permissions() {
    local player_name="$1" command="$2"
    
    # Check if command exists
    if [ -z "${COMMAND_MAPPING["!$command"]}" ]; then
        print_error "Unknown command: !$command"
        return 1
    fi
    
    # Check public commands
    if [ -n "${PUBLIC_COMMANDS["!$command"]}" ]; then
        return 0
    fi
    
    # Check admin commands
    if [ -n "${ADMIN_ONLY_COMMANDS["!$command"]}" ]; then
        if is_player_admin "$player_name"; then
            return 0
        else
            print_error "Player $player_name not authorized for admin command: !$command"
            return 1
        fi
    fi
    
    # Check mod commands
    if [ -n "${MOD_ALLOWED_COMMANDS["!$command"]}" ]; then
        if is_player_admin "$player_name" || is_player_mod "$player_name"; then
            return 0
        else
            print_error "Player $player_name not authorized for mod command: !$command"
            return 1
        fi
    fi
    
    return 1
}

# Function to execute command
execute_command() {
    local player_name="$1" command="$2" args="$3"
    local server_command="${COMMAND_MAPPING["!$command"]}"
    
    # Replace placeholders if needed
    if [[ "$server_command" == *"PLAYER"* ]]; then
        server_command=$(echo "$server_command" | sed "s/PLAYER/$player_name/")
    fi
    
    # Add arguments
    if [ -n "$args" ]; then
        server_command="$server_command $args"
    fi
    
    # Send command to server
    send_server_command "$server_command"
}

# Function to log security event
log_security_event() {
    local timestamp=$(date -Iseconds)
    local player_name="$1"
    local command="$2"
    local args="$3"
    local status="$4"
    local reason="$5"
    
    echo "$timestamp | $player_name | !$command $args | $status | $reason" >> "$SECURITY_LOG"
}

# Filter server log to exclude certain messages
filter_server_log() {
    while read line; do
        [[ "$line" == *"Server closed"* || "$line" == *"Starting server"* || \
          ("$line" == *"SERVER: say"* && "$line" == *"Welcome"*) || \
          "$line" == *"adminlist.txt"* || "$line" == *"modlist.txt"* ]] && continue
        echo "$line"
    done
}

# Cleanup function for signal handling
cleanup() {
    print_status "Cleaning up anticheat..."
    kill $(jobs -p) 2>/dev/null
    print_status "Anticheat cleanup done."
    exit 0
}

# Main anticheat monitoring function
monitor_log() {
    local log_file="$1"
    LOG_FILE="$log_file"

    initialize_authorization_files

    # Create security log
    touch "$SECURITY_LOG"
    print_success "Security log created: $SECURITY_LOG"

    # Set up signal handling
    trap cleanup EXIT INT TERM

    print_header "STARTING CENTRALIZED SECURITY SYSTEM"
    print_status "Monitoring: $log_file"
    print_status "Port: $PORT"
    print_status "Log directory: $LOG_DIR"
    print_header "SECURITY SYSTEM ACTIVE"

    # Monitor the log file for commands and invalid player names
    tail -n 0 -F "$log_file" 2>/dev/null | filter_server_log | while read line; do
        # Detect player connections
        if [[ "$line" =~ Player\ Connected\ (.+)\ \|\ ([0-9a-fA-F.:]+)\ \|\ ([0-9a-f]+) ]]; then
            local player_name="${BASH_REMATCH[1]}" player_ip="${BASH_REMATCH[2]}" player_hash="${BASH_REMATCH[3]}"
            [ "$player_name" == "SERVER" ] && continue

            # Handle invalid player names
            if handle_invalid_player_name "$player_name" "$player_ip" "$player_hash"; then
                continue
            fi

            print_success "Player connected: $player_name (IP: $player_ip)"
            continue
        fi

        # Detect chat messages starting with !
        if [[ "$line" =~ ([a-zA-Z0-9_]+):\ \!(.+)$ ]]; then
            local player_name="${BASH_REMATCH[1]}" message="${BASH_REMATCH[2]}"
            [ "$player_name" == "SERVER" ] && continue

            # Validate player name
            if ! is_valid_player_name "$player_name"; then
                print_warning "Invalid player name in command: $player_name"
                continue
            fi

            # Parse command and arguments
            local parsed_command=$(parse_command "$message")
            local command=$(echo "$parsed_command" | awk '{print $1}')
            local args=$(echo "$parsed_command" | cut -d' ' -f2-)

            # Validate command input
            if ! validate_command_input "$message"; then
                print_error "Invalid command input from $player_name: $message"
                log_security_event "$player_name" "$command" "$args" "DENIED" "Invalid input"
                send_player_message "$player_name" "Comando inválido."
                continue
            fi

            # Check command permissions
            if check_command_permissions "$player_name" "$command"; then
                print_success "Command authorized: $player_name -> !$command $args"
                log_security_event "$player_name" "$command" "$args" "APPROVED" ""
                execute_command "$player_name" "$command" "$args"
            else
                print_error "Command denied: $player_name -> !$command $args"
                log_security_event "$player_name" "$command" "$args" "DENIED" "Insufficient permissions"
                
                if is_player_admin "$player_name" || is_player_mod "$player_name"; then
                    send_player_message "$player_name" "Solo administradores pueden ejecutar este comando."
                else
                    send_player_message "$player_name" "No tienes permiso para usar ese comando."
                fi
            fi
            continue
        fi

        print_status "Other log line: $line"
    done
}

# Show usage information
show_usage() {
    print_header "CENTRALIZED SECURITY SYSTEM - USAGE"
    print_status "This system intercepts all ! commands and validates permissions"
    print_status "Usage: $0 <server_log_file> [port]"
    print_status "Example: $0 /path/to/console.log 12153"
    echo ""
    print_warning "Note: This script should be run alongside the server"
    print_warning "It will intercept and validate all administrative commands"
}

if [ $# -eq 1 ] || [ $# -eq 2 ]; then
    if [ ! -f "$LOG_FILE" ]; then
        print_error "Log file not found: $LOG_FILE"
        print_status "Waiting for log file to be created..."
        
        # Wait for log file to be created
        local wait_time=0
        while [ ! -f "$LOG_FILE" ] && [ $wait_time -lt 30 ]; do
            sleep 1
            ((wait_time++))
        done
        
        if [ ! -f "$LOG_FILE" ]; then
            print_error "Log file never appeared: $LOG_FILE"
            exit 1
        fi
    fi
    
    monitor_log "$1"
else
    show_usage
    exit 1
fi
