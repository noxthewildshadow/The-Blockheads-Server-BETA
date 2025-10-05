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
SECURITY_DEBUG_LOG=""

declare -A connected_players
declare -A player_ip_map
declare -A active_timers
declare -A dangerous_command_offenders

log_debug() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "$timestamp $message" >> "$SECURITY_DEBUG_LOG"
    echo -e "${CYAN}[SECURITY_DEBUG]${NC} $message"
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
    SECURITY_DEBUG_LOG="$BASE_SAVES_DIR/$WORLD_ID/security_debug.log"
    SCREEN_SESSION="blockheads_server_$port"
    
    [ ! -f "$PLAYERS_LOG" ] && touch "$PLAYERS_LOG"
    [ ! -f "$SECURITY_DEBUG_LOG" ] && touch "$SECURITY_DEBUG_LOG"
    
    log_debug "=== SECURITY FEATURES STARTED ==="
    log_debug "World ID: $WORLD_ID"
    log_debug "Port: $port"
    log_debug "Players log: $PLAYERS_LOG"
    log_debug "Console log: $CONSOLE_LOG"
    log_debug "Security debug log: $SECURITY_DEBUG_LOG"
    log_debug "Screen session: $SCREEN_SESSION"
    
    print_status "Players log: $PLAYERS_LOG"
    print_status "Console log: $CONSOLE_LOG"
    print_status "Security debug log: $SECURITY_DEBUG_LOG"
    print_status "Screen session: $SCREEN_SESSION"
}

execute_server_command() {
    local command="$1"
    log_debug "Executing server command: $command"
    send_server_command "$SCREEN_SESSION" "$command"
    sleep 0.5
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

validate_player_name() {
    local player_name="$1"
    
    if [[ ! "$player_name" =~ ^[a-zA-Z0-9_]+$ ]]; then
        log_debug "Invalid player name detected: $player_name - contains special characters"
        return 1
    fi
    
    if [[ "$player_name" =~ [[:space:]] ]]; then
        log_debug "Invalid player name detected: $player_name - contains spaces"
        return 1
    fi
    
    if [[ "$player_name" =~ [/\\\|\!\@\#\$\%\^\&\*\(\)\+\=\{\}\[\]\:\;\'\<\>\,\.\?] ]]; then
        log_debug "Invalid player name detected: $player_name - contains forbidden characters"
        return 1
    fi
    
    if [ ${#player_name} -lt 1 ] || [ ${#player_name} -gt 16 ]; then
        log_debug "Invalid player name detected: $player_name - invalid length (${#player_name} chars)"
        return 1
    fi
    
    log_debug "Valid player name: $player_name"
    return 0
}

start_name_validation_timer() {
    local player_name="$1"
    
    log_debug "Starting name validation timers for: $player_name"
    
    (
        log_debug "Name warning timer started for: $player_name"
        sleep 5
        
        if [ -n "${connected_players[$player_name]}" ]; then
            log_debug "Sending name warning to: $player_name"
            execute_server_command "SECURITY WARNING: $player_name, your username contains invalid characters! You will be kicked in 5 seconds if you don't change it to only letters, numbers, and underscores."
        fi
    ) &
    
    active_timers["name_warning_$player_name"]=$!
    
    (
        log_debug "Name kick timer started for: $player_name"
        sleep 10
        
        if [ -n "${connected_players[$player_name]}" ]; then
            log_debug "Kicking player for invalid name: $player_name"
            execute_server_command "/kick $player_name"
        fi
    ) &
    
    active_timers["name_kick_$player_name"]=$!
    
    log_debug "Started name validation timers for $player_name"
}

cancel_name_validation_timers() {
    local player_name="$1"
    
    if [ -n "${active_timers["name_warning_$player_name"]}" ]; then
        local pid="${active_timers["name_warning_$player_name"]}"
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            log_debug "Cancelled name warning timer for $player_name (PID: $pid)"
        fi
        unset active_timers["name_warning_$player_name"]
    fi
    
    if [ -n "${active_timers["name_kick_$player_name"]}" ]; then
        local pid="${active_timers["name_kick_$player_name"]}"
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            log_debug "Cancelled name kick timer for $player_name (PID: $pid)"
        fi
        unset active_timers["name_kick_$player_name"]
    fi
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

validate_list_entries() {
    local list_file="$1"
    local list_type="$2"
    
    if [ ! -f "$list_file" ]; then
        return 0
    fi
    
    local temp_file=$(mktemp)
    local needs_update=false
    
    while IFS= read -r line; do
        line=$(echo "$line" | xargs)
        
        if [ -z "$line" ]; then
            continue
        fi
        
        local player_info=$(get_player_info "$line")
        
        if [ -z "$player_info" ]; then
            log_debug "Unauthorized entry found in $list_type: $line - Player not in players.log"
            needs_update=true
            continue
        fi
        
        local first_ip=$(echo "$player_info" | cut -d'|' -f1)
        local password=$(echo "$player_info" | cut -d'|' -f2)
        local rank=$(echo "$player_info" | cut -d'|' -f3)
        local whitelisted=$(echo "$player_info" | cut -d'|' -f4)
        local blacklisted=$(echo "$player_info" | cut -d'|' -f5)
        
        if [ "$blacklisted" = "YES" ]; then
            log_debug "Blacklisted player found in $list_type: $line - Removing"
            needs_update=true
            continue
        fi
        
        if [ "$list_type" = "adminlist" ] && [ "$rank" != "ADMIN" ] && [ "$rank" != "SUPER" ]; then
            log_debug "Unauthorized player found in adminlist: $line - Rank: $rank"
            needs_update=true
            continue
        fi
        
        if [ "$list_type" = "modlist" ] && [ "$rank" != "MOD" ]; then
            log_debug "Unauthorized player found in modlist: $line - Rank: $rank"
            needs_update=true
            continue
        fi
        
        if [ -z "${connected_players[$line]}" ]; then
            log_debug "Player not connected but in $list_type: $line - Keeping for now"
            echo "$line" >> "$temp_file"
            continue
        fi
        
        local current_ip="${player_ip_map[$line]}"
        if [ "$first_ip" != "UNKNOWN" ] && [ "$first_ip" != "$current_ip" ]; then
            log_debug "IP mismatch for player in $list_type: $line - First IP: $first_ip, Current IP: $current_ip"
            needs_update=true
            continue
        fi
        
        echo "$line" >> "$temp_file"
        
    done < "$list_file"
    
    if [ "$needs_update" = true ]; then
        log_debug "Updating $list_type file - removing unauthorized entries"
        cat "$temp_file" > "$list_file"
        execute_server_command "/load-lists"
    fi
    
    rm -f "$temp_file"
}

monitor_lists() {
    local world_dir="$BASE_SAVES_DIR/$WORLD_ID"
    local admin_list="$world_dir/adminlist.txt"
    local mod_list="$world_dir/modlist.txt"
    
    local last_admin_checksum=""
    local last_mod_checksum=""
    
    while true; do
        if [ -f "$admin_list" ]; then
            local current_admin_checksum=$(md5sum "$admin_list" 2>/dev/null | cut -d' ' -f1)
            if [ "$current_admin_checksum" != "$last_admin_checksum" ]; then
                log_debug "Detected change in adminlist.txt - validating entries"
                validate_list_entries "$admin_list" "adminlist"
                last_admin_checksum="$current_admin_checksum"
            fi
        fi
        
        if [ -f "$mod_list" ]; then
            local current_mod_checksum=$(md5sum "$mod_list" 2>/dev/null | cut -d' ' -f1)
            if [ "$current_mod_checksum" != "$last_mod_checksum" ]; then
                log_debug "Detected change in modlist.txt - validating entries"
                validate_list_entries "$mod_list" "modlist"
                last_mod_checksum="$current_mod_checksum"
            fi
        fi
        
        sleep 1
    done
}

handle_dangerous_command() {
    local player_name="$1"
    local command="$2"
    
    log_debug "Dangerous command detected from $player_name: $command"
    
    if [ -n "${dangerous_command_offenders[$player_name]}" ]; then
        log_debug "Player $player_name already being processed for dangerous command"
        return
    fi
    
    dangerous_command_offenders["$player_name"]="$command"
    
    (
        log_debug "Dangerous command warning timer started for: $player_name"
        sleep 5
        
        if [ -n "${connected_players[$player_name]}" ]; then
            log_debug "Sending dangerous command warning to: $player_name"
            execute_server_command "SECURITY ALERT: $player_name, you have been detected using dangerous commands! You will be banned for 24 hours in 5 seconds."
        fi
    ) &
    
    active_timers["dangerous_warning_$player_name"]=$!
    
    (
        log_debug "Dangerous command ban timer started for: $player_name"
        sleep 10
        
        if [ -n "${connected_players[$player_name]}" ]; then
            log_debug "Banning player for dangerous command: $player_name"
            local current_ip="${player_ip_map[$player_name]}"
            
            execute_server_command "/ban $player_name"
            if [ -n "$current_ip" ] && [ "$current_ip" != "UNKNOWN" ]; then
                execute_server_command "/ban $current_ip"
            fi
            
            (
                sleep 86400
                execute_server_command "/unban $player_name"
                if [ -n "$current_ip" ] && [ "$current_ip" != "UNKNOWN" ]; then
                    execute_server_command "/unban $current_ip"
                fi
                log_debug "24-hour ban expired for: $player_name"
            ) &
        fi
        
        unset dangerous_command_offenders["$player_name"]
    ) &
    
    active_timers["dangerous_ban_$player_name"]=$!
    
    log_debug "Started dangerous command timers for $player_name"
}

cancel_dangerous_command_timers() {
    local player_name="$1"
    
    if [ -n "${active_timers["dangerous_warning_$player_name"]}" ]; then
        local pid="${active_timers["dangerous_warning_$player_name"]}"
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            log_debug "Cancelled dangerous command warning timer for $player_name (PID: $pid)"
        fi
        unset active_timers["dangerous_warning_$player_name"]
    fi
    
    if [ -n "${active_timers["dangerous_ban_$player_name"]}" ]; then
        local pid="${active_timers["dangerous_ban_$player_name"]}"
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            log_debug "Cancelled dangerous command ban timer for $player_name (PID: $pid)"
        fi
        unset active_timers["dangerous_ban_$player_name"]
    fi
    
    unset dangerous_command_offenders["$player_name"]
}

monitor_console_log() {
    print_header "STARTING SECURITY CONSOLE MONITOR"
    log_debug "Starting security console log monitor"
    
    local wait_time=0
    while [ ! -f "$CONSOLE_LOG" ] && [ $wait_time -lt 30 ]; do
        sleep 1
        ((wait_time++))
        [ $((wait_time % 5)) -eq 0 ] && log_debug "Waiting for console.log to be created..."
    done
    
    if [ ! -f "$CONSOLE_LOG" ]; then
        log_debug "ERROR: Console log never appeared: $CONSOLE_LOG"
        return 1
    fi
    
    log_debug "Console log found, starting security monitoring"
    
    tail -n 0 -F "$CONSOLE_LOG" | while read -r line; do
        if [[ "$line" =~ Player\ Connected\ (.+)\ \|\ ([0-9a-fA-F.:]+)\ \|\ ([0-9a-f]+) ]]; then
            local player_name="${BASH_REMATCH[1]}"
            local player_ip="${BASH_REMATCH[2]}"
            
            player_name=$(echo "$player_name" | xargs)
            
            connected_players["$player_name"]=1
            player_ip_map["$player_name"]="$player_ip"
            
            log_debug "Player connected for security check: $player_name ($player_ip)"
            
            if ! validate_player_name "$player_name"; then
                log_debug "Invalid player name detected, starting validation timers: $player_name"
                start_name_validation_timer "$player_name"
            else
                log_debug "Valid player name: $player_name"
            fi
        fi
        
        if [[ "$line" =~ Player\ Disconnected\ (.+) ]]; then
            local player_name="${BASH_REMATCH[1]}"
            player_name=$(echo "$player_name" | xargs)
            
            log_debug "Player disconnected: $player_name"
            
            unset connected_players["$player_name"]
            unset player_ip_map["$player_name"]
            
            cancel_name_validation_timers "$player_name"
            cancel_dangerous_command_timers "$player_name"
        fi
        
        if [[ "$line" =~ ([a-zA-Z0-9_]+):\ /\ *stop ]]; then
            local player_name="${BASH_REMATCH[1]}"
            player_name=$(echo "$player_name" | xargs)
            
            if [ -n "${connected_players[$player_name]}" ]; then
                log_debug "Dangerous command /stop detected from: $player_name"
                handle_dangerous_command "$player_name" "/stop"
            fi
        fi
        
        if [[ "$line" =~ ([a-zA-Z0-9_]+):\ /\ *clear-adminlist ]]; then
            local player_name="${BASH_REMATCH[1]}"
            player_name=$(echo "$player_name" | xargs)
            
            if [ -n "${connected_players[$player_name]}" ]; then
                log_debug "Dangerous command /clear-adminlist detected from: $player_name"
                handle_dangerous_command "$player_name" "/clear-adminlist"
            fi
        fi
        
        if [[ "$line" =~ ([a-zA-Z0-9_]+):\ /\ *clear-modlist ]]; then
            local player_name="${BASH_REMATCH[1]}"
            player_name=$(echo "$player_name" | xargs)
            
            if [ -n "${connected_players[$player_name]}" ]; then
                log_debug "Dangerous command /clear-modlist detected from: $player_name"
                handle_dangerous_command "$player_name" "/clear-modlist"
            fi
        fi
        
        if [[ "$line" =~ ([a-zA-Z0-9_]+):\ /\ *clear-blacklist ]]; then
            local player_name="${BASH_REMATCH[1]}"
            player_name=$(echo "$player_name" | xargs)
            
            if [ -n "${connected_players[$player_name]}" ]; then
                log_debug "Dangerous command /clear-blacklist detected from: $player_name"
                handle_dangerous_command "$player_name" "/clear-blacklist"
            fi
        fi
        
        if [[ "$line" =~ ([a-zA-Z0-9_]+):\ /\ *clear-whitelist ]]; then
            local player_name="${BASH_REMATCH[1]}"
            player_name=$(echo "$player_name" | xargs)
            
            if [ -n "${connected_players[$player_name]}" ]; then
                log_debug "Dangerous command /clear-whitelist detected from: $player_name"
                handle_dangerous_command "$player_name" "/clear-whitelist"
            fi
        fi
    done
}

cancel_all_timers() {
    log_debug "Cancelling all security timers"
    
    for timer_key in "${!active_timers[@]}"; do
        local pid="${active_timers[$timer_key]}"
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            log_debug "Cancelled timer: $timer_key (PID: $pid)"
        fi
    done
    
    active_timers=()
    dangerous_command_offenders=()
}

cleanup() {
    print_header "CLEANING UP SECURITY FEATURES"
    log_debug "=== SECURITY CLEANUP STARTED ==="
    
    jobs -p | xargs kill -9 2>/dev/null
    
    cancel_all_timers
    
    log_debug "=== SECURITY CLEANUP COMPLETED ==="
    print_success "Security features cleanup completed"
    exit 0
}

main() {
    if [ $# -lt 1 ]; then
        print_error "Usage: $0 <port>"
        print_status "Example: $0 12153"
        exit 1
    fi
    
    PORT="$1"
    
    print_header "THE BLOCKHEADS SECURITY FEATURES"
    print_status "Starting security features for port: $PORT"
    
    trap cleanup EXIT INT TERM
    
    if ! setup_paths "$PORT"; then
        exit 1
    fi
    
    if ! screen_session_exists "$SCREEN_SESSION"; then
        print_error "Server screen session not found: $SCREEN_SESSION"
        print_status "Please start the server first using server_manager.sh"
        exit 1
    fi
    
    print_step "Starting console.log security monitor..."
    monitor_console_log &
    
    print_step "Starting list files security monitor..."
    monitor_lists &
    
    print_header "SECURITY FEATURES ARE NOW RUNNING"
    print_status "Monitoring: $CONSOLE_LOG"
    print_status "Managing: $PLAYERS_LOG"
    print_status "Security debug log: $SECURITY_DEBUG_LOG"
    print_status "Server session: $SCREEN_SESSION"
    print_status "Security Features Active:"
    print_status "  - Player name validation"
    print_status "  - List integrity protection"
    print_status "  - Dangerous command detection"
    
    wait
}

main "$@"
