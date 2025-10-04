#!/bin/bash
# =============================================================================
# THE BLOCKHEADS RANK PATCHER - CENTRAL PLAYER MANAGEMENT SYSTEM
# =============================================================================

# Color codes for output
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

# Global variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOME_DIR="$HOME"
BASE_SAVES_DIR="$HOME_DIR/GNUstep/Library/ApplicationSupport/TheBlockheads/saves"
PLAYERS_LOG=""
CONSOLE_LOG=""
SCREEN_SESSION=""
WORLD_ID=""
PORT=""
PATCH_DEBUG_LOG=""

# Track connected players and their states
declare -A connected_players
declare -A player_ip_map
declare -A player_verification_status
declare -A player_password_reminder_sent
declare -A active_timers
declare -A current_player_ranks
declare -A current_blacklisted_players
declare -A current_whitelisted_players
declare -A super_admin_disconnect_timers  # NUEVO: Para timer de 15 segundos de SUPER

# Function to log debug information
log_debug() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "$timestamp $message" >> "$PATCH_DEBUG_LOG"
    echo -e "${CYAN}[DEBUG]${NC} $message"
}

# Function to find world directory and set paths
setup_paths() {
    local port="$1"
    
    # Try to find world ID from port
    if [ -f "world_id_$port.txt" ]; then
        WORLD_ID=$(cat "world_id_$port.txt")
        print_success "Found world ID: $WORLD_ID for port $port"
    else
        # Find the most recent world directory
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
    
    # Create logs if they don't exist
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

# Function to execute server command with cooldown
execute_server_command() {
    local command="$1"
    log_debug "Executing server command: $command"
    send_server_command "$SCREEN_SESSION" "$command"
    sleep 0.5  # Cooldown as required
}

# Function to send command to screen session
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

# Function to check if screen session exists
screen_session_exists() {
    screen -list | grep -q "$1"
}

# Function to validate player name
is_valid_player_name() {
    local name="$1"
    [[ "$name" =~ ^[a-zA-Z0-9_]{1,16}$ ]]
}

# Function to get player info from players.log
get_player_info() {
    local player_name="$1"
    if [ -f "$PLAYERS_LOG" ]; then
        while IFS='|' read -r name first_ip password rank whitelisted blacklisted; do
            # Clean up fields from spaces
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

# Function to update player info in players.log
update_player_info() {
    local player_name="$1" first_ip="$2" password="$3" rank="$4" whitelisted="${5:-NO}" blacklisted="${6:-NO}"
    
    # Convert to uppercase as required
    player_name=$(echo "$player_name" | tr '[:lower:]' '[:upper:]')
    first_ip=$(echo "$first_ip" | tr '[:lower:]' '[:upper:]')
    password=$(echo "$password" | tr '[:lower:]' '[:upper:]')
    rank=$(echo "$rank" | tr '[:lower:]' '[:upper:]')
    whitelisted=$(echo "$whitelisted" | tr '[:lower:]' '[:upper:]')
    blacklisted=$(echo "$blacklisted" | tr '[:lower:]' '[:upper:]')
    
    # Handle UNKNOWN and NONE values
    [ -z "$first_ip" ] && first_ip="UNKNOWN"
    [ -z "$password" ] && password="NONE"
    [ -z "$rank" ] && rank="NONE"
    [ -z "$whitelisted" ] && whitelisted="NO"
    [ -z "$blacklisted" ] && blacklisted="NO"
    
    if [ -f "$PLAYERS_LOG" ]; then
        # Remove existing entry
        sed -i "/^$player_name|/Id" "$PLAYERS_LOG"
        # Add new entry with proper format
        echo "$player_name|$first_ip|$password|$rank|$whitelisted|$blacklisted" >> "$PLAYERS_LOG"
        log_debug "Updated player in players.log: $player_name | $first_ip | $password | $rank | $whitelisted | $blacklisted"
    fi
}

# Function to sync lists from players.log using SERVER COMMANDS only
sync_lists_from_players_log() {
    log_debug "Syncing lists from players.log using server commands..."
    
    # Process players.log - ONLY for verified and connected players
    if [ -f "$PLAYERS_LOG" ]; then
        while IFS='|' read -r name first_ip password rank whitelisted blacklisted; do
            # Clean fields
            name=$(echo "$name" | xargs)
            first_ip=$(echo "$first_ip" | xargs)
            rank=$(echo "$rank" | xargs)
            whitelisted=$(echo "$whitelisted" | xargs)
            blacklisted=$(echo "$blacklisted" | xargs)
            
            # Skip if player is not connected OR not IP verified
            if [ -z "${connected_players[$name]}" ] || [ "${player_verification_status[$name]}" != "verified" ]; then
                continue
            fi
            
            # Get current IP for connected player
            local current_ip="${player_ip_map[$name]}"
            
            # Handle rank changes using SERVER COMMANDS
            local current_rank="${current_player_ranks[$name]}"
            if [ "$current_rank" != "$rank" ]; then
                log_debug "Rank change detected for $name: $current_rank -> $rank"
                apply_rank_changes "$name" "$current_rank" "$rank"
                current_player_ranks["$name"]="$rank"
            fi
            
            # Handle blacklist changes using SERVER COMMANDS
            local current_blacklisted="${current_blacklisted_players[$name]}"
            if [ "$current_blacklisted" != "$blacklisted" ]; then
                log_debug "Blacklist change detected for $name: $current_blacklisted -> $blacklisted"
                handle_blacklist_change "$name" "$blacklisted"
                current_blacklisted_players["$name"]="$blacklisted"
            fi
            
            # Handle whitelist changes using SERVER COMMANDS
            local current_whitelisted="${current_whitelisted_players[$name]}"
            if [ "$current_whitelisted" != "$whitelisted" ]; then
                log_debug "Whitelist change detected for $name: $current_whitelisted -> $whitelisted"
                handle_whitelist_change "$name" "$whitelisted" "$current_ip"
                current_whitelisted_players["$name"]="$whitelisted"
            fi
            
        done < "$PLAYERS_LOG"
    fi
    
    log_debug "Completed syncing lists using server commands"
}

# Function to handle whitelist changes using SERVER COMMANDS
handle_whitelist_change() {
    local player_name="$1" whitelisted="$2" current_ip="$3"
    
    log_debug "Handling whitelist change via server commands: $player_name -> $whitelisted (IP: $current_ip)"
    
    if [ "$whitelisted" = "YES" ] && [ -n "$current_ip" ] && [ "$current_ip" != "UNKNOWN" ]; then
        log_debug "Adding IP to whitelist: $current_ip for player $player_name"
        execute_server_command "/whitelist $current_ip"
    elif [ "$whitelisted" = "NO" ] && [ -n "$current_ip" ] && [ "$current_ip" != "UNKNOWN" ]; then
        log_debug "Removing IP from whitelist: $current_ip for player $player_name"
        execute_server_command "/unwhitelist $current_ip"
    fi
}

# Function to apply rank changes using server commands
apply_rank_changes() {
    local player_name="$1" old_rank="$2" new_rank="$3"
    
    log_debug "Applying rank change via server commands: $player_name from $old_rank to $new_rank"
    
    # Remove old rank
    case "$old_rank" in
        "ADMIN")
            execute_server_command "/unadmin $player_name"
            ;;
        "MOD")
            execute_server_command "/unmod $player_name"
            ;;
        "SUPER")
            # NUEVO: Iniciar timer de 15 segundos en lugar de eliminar inmediatamente
            start_super_disconnect_timer "$player_name"
            execute_server_command "/unadmin $player_name"
            ;;
    esac
    
    # Add new rank
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
    
    # Reload lists after changes
    execute_server_command "/load-lists"
}

# NUEVA FUNCIÓN: Timer de 15 segundos para SUPER al desconectarse
start_super_disconnect_timer() {
    local player_name="$1"
    
    log_debug "Starting 15-second disconnect timer for SUPER admin: $player_name"
    
    (
        sleep 15
        log_debug "15-second timer completed, removing SUPER admin $player_name from cloud"
        remove_from_cloud_admin "$player_name"
        unset super_admin_disconnect_timers["$player_name"]
    ) &
    
    super_admin_disconnect_timers["$player_name"]=$!
    log_debug "Started 15-second disconnect timer for SUPER $player_name (PID: ${super_admin_disconnect_timers[$player_name]})"
}

# NUEVA FUNCIÓN: Cancelar timer de desconexión de SUPER si se reconecta
cancel_super_disconnect_timer() {
    local player_name="$1"
    
    if [ -n "${super_admin_disconnect_timers[$player_name]}" ]; then
        local pid="${super_admin_disconnect_timers[$player_name]}"
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            log_debug "Cancelled SUPER disconnect timer for $player_name (PID: $pid)"
        fi
        unset super_admin_disconnect_timers["$player_name"]
    fi
}

# Function to add player to cloud admin list
add_to_cloud_admin() {
    local player_name="$1"
    local cloud_file="$HOME_DIR/GNUstep/Library/ApplicationSupport/TheBlockheads/cloudWideOwnedAdminlist.txt"
    
    [ ! -f "$cloud_file" ] && touch "$cloud_file"
    
    local first_line=$(head -1 "$cloud_file")
    > "$cloud_file"
    [ -n "$first_line" ] && echo "$first_line" >> "$cloud_file"
    
    if ! grep -q "^$player_name$" "$cloud_file" 2>/dev/null; then
        echo "$player_name" >> "$cloud_file"
        log_debug "Added $player_name to cloud admin list"
    fi
}

# Function to remove player from cloud admin list
remove_from_cloud_admin() {
    local player_name="$1"
    local cloud_file="$HOME_DIR/GNUstep/Library/ApplicationSupport/TheBlockheads/cloudWideOwnedAdminlist.txt"
    
    if [ -f "$cloud_file" ]; then
        local first_line=$(head -1 "$cloud_file")
        local temp_file=$(mktemp)
        
        # Keep first line and remove the player
        [ -n "$first_line" ] && echo "$first_line" > "$temp_file"
        grep -v "^$player_name$" "$cloud_file" | tail -n +2 >> "$temp_file"
        
        # If only first line remains, remove the file
        if [ $(wc -l < "$temp_file") -le 1 ] || [ $(wc -l < "$temp_file") -eq 1 -a -z "$first_line" ]; then
            rm -f "$cloud_file"
            log_debug "Removed cloud admin file (no super admins)"
        else
            mv "$temp_file" "$cloud_file"
        fi
        
        log_debug "Removed $player_name from cloud admin list"
    fi
}

# Function to handle blacklist changes using SERVER COMMANDS
handle_blacklist_change() {
    local player_name="$1" blacklisted="$2"
    
    log_debug "Handling blacklist change via server commands: $player_name -> $blacklisted"
    
    local player_info=$(get_player_info "$player_name")
    if [ -n "$player_info" ]; then
        local first_ip=$(echo "$player_info" | cut -d'|' -f1)
        local password=$(echo "$player_info" | cut -d'|' -f2)
        local rank=$(echo "$player_info" | cut -d'|' -f3)
        local current_ip="${player_ip_map[$player_name]}"
        
        if [ "$blacklisted" = "YES" ]; then
            # Remove from roles and ban using SERVER COMMANDS
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
            
            # Ban player and IP using SERVER COMMANDS
            execute_server_command "/ban $player_name"
            if [ -n "$current_ip" ] && [ "$current_ip" != "UNKNOWN" ]; then
                execute_server_command "/ban $current_ip"
            fi
            
            log_debug "Blacklisted player via server commands: $player_name"
        else
            # Unban player and IP using SERVER COMMANDS
            execute_server_command "/unban $player_name"
            if [ -n "$current_ip" ] && [ "$current_ip" != "UNKNOWN" ]; then
                execute_server_command "/unban $current_ip"
            fi
            log_debug "Removed $player_name from blacklist via server commands"
        fi
        
        # Reload lists
        execute_server_command "/load-lists"
    fi
}

# Function to monitor players.log for changes
monitor_players_log() {
    local last_checksum=""
    local temp_file=$(mktemp)
    
    # Save initial state
    [ -f "$PLAYERS_LOG" ] && cp "$PLAYERS_LOG" "$temp_file"
    
    # Initialize current state tracking
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
                log_debug "Detected change in players.log - processing changes via server commands..."
                process_players_log_changes "$temp_file"
                last_checksum="$current_checksum"
                cp "$PLAYERS_LOG" "$temp_file"
            fi
        fi
        
        sleep 1
    done
    
    rm -f "$temp_file"
}

# Function to process changes in players.log using SERVER COMMANDS
process_players_log_changes() {
    local previous_file="$1"
    
    if [ ! -f "$previous_file" ] || [ ! -f "$PLAYERS_LOG" ]; then
        sync_lists_from_players_log
        return
    fi
    
    # Compare previous and current to detect specific changes
    while IFS='|' read -r name first_ip password rank whitelisted blacklisted; do
        name=$(echo "$name" | xargs)
        rank=$(echo "$rank" | xargs)
        blacklisted=$(echo "$blacklisted" | xargs)
        whitelisted=$(echo "$whitelisted" | xargs)
        
        # Find previous state
        local previous_line=$(grep -i "^$name|" "$previous_file" 2>/dev/null | head -1)
        
        if [ -n "$previous_line" ]; then
            # Extract previous values
            local prev_first_ip=$(echo "$previous_line" | cut -d'|' -f2 | xargs)
            local prev_password=$(echo "$previous_line" | cut -d'|' -f3 | xargs)
            local prev_rank=$(echo "$previous_line" | cut -d'|' -f4 | xargs)
            local prev_whitelisted=$(echo "$previous_line" | cut -d'|' -f5 | xargs)
            local prev_blacklisted=$(echo "$previous_line" | cut -d'|' -f6 | xargs)
            
            # Check for rank changes
            if [ "$prev_rank" != "$rank" ]; then
                log_debug "Rank change detected via server commands: $name from $prev_rank to $rank"
                apply_rank_changes "$name" "$prev_rank" "$rank"
            fi
            
            # Check for blacklist changes
            if [ "$prev_blacklisted" != "$blacklisted" ]; then
                log_debug "Blacklist change detected via server commands: $name from $prev_blacklisted to $blacklisted"
                handle_blacklist_change "$name" "$blacklisted"
            fi
            
            # Check for whitelist changes
            if [ "$prev_whitelisted" != "$whitelisted" ]; then
                log_debug "Whitelist change detected via server commands: $name from $prev_whitelisted to $whitelisted"
                local current_ip="${player_ip_map[$name]}"
                handle_whitelist_change "$name" "$whitelisted" "$current_ip"
            fi
        fi
    done < "$PLAYERS_LOG"
    
    # Always sync lists after changes using SERVER COMMANDS
    sync_lists_from_players_log
}

# =============================================================================
# INDEPENDENT TIMER MANAGEMENT SYSTEM
# =============================================================================

# Function to cancel all timers for a player
cancel_player_timers() {
    local player_name="$1"
    
    log_debug "Cancelling all timers for player: $player_name"
    
    # Cancel password reminder timer
    if [ -n "${active_timers["password_reminder_$player_name"]}" ]; then
        local pid="${active_timers["password_reminder_$player_name"]}"
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            log_debug "Cancelled password reminder timer for $player_name (PID: $pid)"
        fi
        unset active_timers["password_reminder_$player_name"]
    fi
    
    # Cancel password kick timer
    if [ -n "${active_timers["password_kick_$player_name"]}" ]; then
        local pid="${active_timers["password_kick_$player_name"]}"
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            log_debug "Cancelled password kick timer for $player_name (PID: $pid)"
        fi
        unset active_timers["password_kick_$player_name"]
    fi
    
    # Cancel IP grace timer
    if [ -n "${active_timers["ip_grace_$player_name"]}" ]; then
        local pid="${active_timers["ip_grace_$player_name"]}"
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            log_debug "Cancelled IP grace timer for $player_name (PID: $pid)"
        fi
        unset active_timers["ip_grace_$player_name"]
    fi
    
    # NUEVO: Cancelar timer de desconexión de SUPER si se reconecta
    cancel_super_disconnect_timer "$player_name"
}

# INDEPENDENT PASSWORD REMINDER TIMER
start_password_reminder_timer() {
    local player_name="$1"
    
    (
        log_debug "Password reminder timer started for $player_name"
        sleep 5
        
        # Check if player still exists and needs password
        if [ -n "${connected_players[$player_name]}" ]; then
            local player_info=$(get_player_info "$player_name")
            if [ -n "$player_info" ]; then
                local password=$(echo "$player_info" | cut -d'|' -f2)
                if [ "$password" = "NONE" ]; then
                    log_debug "Sending password reminder to $player_name"
                    execute_server_command "SECURITY: $player_name, please set your password with !psw PASSWORD CONFIRM_PASSWORD within 60 seconds or you will be kicked."
                    player_password_reminder_sent["$player_name"]=1
                fi
            fi
        fi
        log_debug "Password reminder timer completed for $player_name"
    ) &
    
    active_timers["password_reminder_$player_name"]=$!
    log_debug "Started independent password reminder timer for $player_name (PID: ${active_timers["password_reminder_$player_name"]})"
}

# INDEPENDENT PASSWORD KICK TIMER
start_password_kick_timer() {
    local player_name="$1"
    
    (
        log_debug "Password kick timer started for $player_name"
        sleep 60
        
        # Check if player still exists and needs password
        if [ -n "${connected_players[$player_name]}" ]; then
            local player_info=$(get_player_info "$player_name")
            if [ -n "$player_info" ]; then
                local password=$(echo "$player_info" | cut -d'|' -f2)
                if [ "$password" = "NONE" ]; then
                    log_debug "Kicking $player_name for not setting password within 60 seconds"
                    execute_server_command "/kick $player_name"
                else
                    log_debug "Player $player_name set password, no kick needed"
                fi
            fi
        fi
        log_debug "Password kick timer completed for $player_name"
    ) &
    
    active_timers["password_kick_$player_name"]=$!
    log_debug "Started independent password kick timer for $player_name (PID: ${active_timers["password_kick_$player_name"]})"
}

# INDEPENDENT IP GRACE PERIOD TIMER
start_ip_grace_timer() {
    local player_name="$1" current_ip="$2"
    
    (
        log_debug "IP grace timer started for $player_name with IP $current_ip"
        
        # Wait 5 seconds then send warning
        sleep 5
        if [ -n "${connected_players[$player_name]}" ]; then
            local player_info=$(get_player_info "$player_name")
            if [ -n "$player_info" ]; then
                local first_ip=$(echo "$player_info" | cut -d'|' -f1)
                if [ "$first_ip" != "UNKNOWN" ] && [ "$first_ip" != "$current_ip" ]; then
                    log_debug "IP change detected for $player_name: $first_ip -> $current_ip"
                    execute_server_command "SECURITY ALERT: $player_name, your IP has changed! Verify with !ip_change YOUR_PASSWORD within 25 seconds or you will be kicked and IP banned."
                    
                    # Wait 25 more seconds for verification
                    sleep 25
                    if [ -n "${connected_players[$player_name]}" ] && [ "${player_verification_status[$player_name]}" != "verified" ]; then
                        log_debug "IP verification failed for $player_name, kicking and banning"
                        execute_server_command "/kick $player_name"
                        execute_server_command "/ban $current_ip"
                        
                        # Auto-unban after 30 seconds
                        (
                            sleep 30
                            execute_server_command "/unban $current_ip"
                            log_debug "Auto-unbanned IP: $current_ip"
                        ) &
                    fi
                fi
            fi
        fi
        log_debug "IP grace timer completed for $player_name"
    ) &
    
    active_timers["ip_grace_$player_name"]=$!
    log_debug "Started independent IP grace timer for $player_name (PID: ${active_timers["ip_grace_$player_name"]})"
}

# Function to start password enforcement with INDEPENDENT timers
start_password_enforcement() {
    local player_name="$1"
    
    log_debug "Starting INDEPENDENT password enforcement for $player_name"
    
    # Start each timer as independent processes
    start_password_reminder_timer "$player_name"
    start_password_kick_timer "$player_name"
}

# =============================================================================
# COMMAND HANDLERS (IMMEDIATE EXECUTION)
# =============================================================================

# Function to handle password creation - IMMEDIATE EXECUTION
handle_password_creation() {
    local player_name="$1" password="$2" confirm_password="$3"
    
    log_debug "IMMEDIATE: Password creation requested for $player_name"
    
    # Clear chat IMMEDIATELY to hide password
    log_debug "IMMEDIATE: Sending /clear command for $player_name"
    send_server_command "$SCREEN_SESSION" "/clear"
    
    # Validación inmediata
    log_debug "IMMEDIATE: Validating password for $player_name"
    
    # Validate password length (7-16 characters)
    if [ ${#password} -lt 7 ] || [ ${#password} -gt 16 ]; then
        log_debug "IMMEDIATE: Password validation failed: length invalid (${#password} chars)"
        send_server_command "$SCREEN_SESSION" "ERROR: $player_name, password must be between 7 and 16 characters."
        return 1
    fi
    
    # Validate password confirmation
    if [ "$password" != "$confirm_password" ]; then
        log_debug "IMMEDIATE: Password validation failed: passwords don't match"
        send_server_command "$SCREEN_SESSION" "ERROR: $player_name, passwords do not match."
        return 1
    fi
    
    # Update player info
    local player_info=$(get_player_info "$player_name")
    if [ -n "$player_info" ]; then
        local first_ip=$(echo "$player_info" | cut -d'|' -f1)
        local current_password=$(echo "$player_info" | cut -d'|' -f2)
        local rank=$(echo "$player_info" | cut -d'|' -f3)
        local whitelisted=$(echo "$player_info" | cut -d'|' -f4)
        local blacklisted=$(echo "$player_info" | cut -d'|' -f5)
        
        log_debug "IMMEDIATE: Player info found for $player_name, cancelling ALL timers"
        
        # Cancel ALL timers immediately when password is set
        cancel_player_timers "$player_name"
        
        # Update player with new password
        log_debug "IMMEDIATE: Updating players.log with new password for $player_name"
        update_player_info "$player_name" "$first_ip" "$password" "$rank" "$whitelisted" "$blacklisted"
        
        log_debug "IMMEDIATE: Password set successfully for $player_name"
        send_server_command "$SCREEN_SESSION" "SUCCESS: $player_name, your password has been set successfully."
        return 0
    else
        log_debug "IMMEDIATE: Player info NOT found for $player_name"
        send_server_command "$SCREEN_SESSION" "ERROR: $player_name, player not found in registry."
        return 1
    fi
}

# Function to handle password change
handle_password_change() {
    local player_name="$1" old_password="$2" new_password="$3"
    
    log_debug "Password change requested for $player_name"
    
    # Clear chat IMMEDIATELY
    send_server_command "$SCREEN_SESSION" "/clear"
    
    # Validate new password length (7-16 characters)
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
        
        # Verify old password
        if [ "$current_password" != "$old_password" ]; then
            send_server_command "$SCREEN_SESSION" "ERROR: $player_name, old password is incorrect."
            return 1
        fi
        
        # Update password
        update_player_info "$player_name" "$first_ip" "$new_password" "$rank" "$whitelisted" "$blacklisted"
        
        send_server_command "$SCREEN_SESSION" "SUCCESS: $player_name, your password has been changed successfully."
        return 0
    else
        send_server_command "$SCREEN_SESSION" "ERROR: $player_name, player not found in registry."
        return 1
    fi
}

# Function to handle IP change verification
handle_ip_change() {
    local player_name="$1" password="$2" current_ip="$3"
    
    log_debug "IP change verification requested for $player_name"
    
    # Clear chat IMMEDIATELY
    send_server_command "$SCREEN_SESSION" "/clear"
    
    local player_info=$(get_player_info "$player_name")
    if [ -n "$player_info" ]; then
        local first_ip=$(echo "$player_info" | cut -d'|' -f1)
        local current_password=$(echo "$player_info" | cut -d'|' -f2)
        local rank=$(echo "$player_info" | cut -d'|' -f3)
        local whitelisted=$(echo "$player_info" | cut -d'|' -f4)
        local blacklisted=$(echo "$player_info" | cut -d'|' -f5)
        
        # Verify password
        if [ "$current_password" != "$password" ]; then
            send_server_command "$SCREEN_SESSION" "ERROR: $player_name, password is incorrect."
            return 1
        fi
        
        # Update IP and mark as verified
        update_player_info "$player_name" "$first_ip" "$current_password" "$rank" "$whitelisted" "$blacklisted"
        player_verification_status["$player_name"]="verified"
        
        # Cancel grace period timer
        cancel_player_timers "$player_name"
        
        # NUEVO: Cancelar cooldown de /kick y /ban IP explícitamente
        log_debug "IP verification successful for $player_name - cancelling kick/ban IP cooldown"
        execute_server_command "SECURITY: $player_name IP verification successful. Kick/ban IP cooldown cancelled."
        
        # Sync lists now that player is verified using SERVER COMMANDS
        sync_lists_from_players_log
        
        send_server_command "$SCREEN_SESSION" "SUCCESS: $player_name, your IP has been verified and updated. All security restrictions lifted."
        return 0
    else
        send_server_command "$SCREEN_SESSION" "ERROR: $player_name, player not found in registry."
        return 1
    fi
}

# =============================================================================
# CONSOLE MONITOR (NON-BLOCKING) - CORREGIDO PARA EXTRAER IP
# =============================================================================

# Function to monitor console.log for commands and connections
monitor_console_log() {
    print_header "STARTING CONSOLE LOG MONITOR"
    log_debug "Starting console log monitor"
    
    # Wait for console.log to exist
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
    
    log_debug "Console log found, starting monitoring"
    
    # Start monitoring
    tail -n 0 -F "$CONSOLE_LOG" | while read -r line; do
        # Player connection detection - CORREGIDO para extraer IP correctamente
        if [[ "$line" =~ Player\ Connected\ (.+)\ \|\ ([0-9a-fA-F.:]+)\ \|\ ([0-9a-f]+) ]]; then
            local player_name="${BASH_REMATCH[1]}"
            local player_ip="${BASH_REMATCH[2]}"
            
            # Clean player name
            player_name=$(echo "$player_name" | xargs)
            
            if is_valid_player_name "$player_name"; then
                connected_players["$player_name"]=1
                player_ip_map["$player_name"]="$player_ip"
                
                log_debug "Player connected: $player_name ($player_ip)"
                
                # NUEVO: Cancelar timer de desconexión de SUPER si se reconecta
                cancel_super_disconnect_timer "$player_name"
                
                # Check if player exists in players.log
                local player_info=$(get_player_info "$player_name")
                if [ -z "$player_info" ]; then
                    # New player - add to players.log with REAL IP (not UNKNOWN)
                    log_debug "New player detected: $player_name, adding to players.log with IP: $player_ip"
                    update_player_info "$player_name" "$player_ip" "NONE" "NONE" "NO" "NO"
                    player_verification_status["$player_name"]="verified"  # New player with real IP is verified
                    start_password_enforcement "$player_name"
                else
                    # Existing player - check IP and start verification process
                    local first_ip=$(echo "$player_info" | cut -d'|' -f1)
                    local password=$(echo "$player_info" | cut -d'|' -f2)
                    local rank=$(echo "$player_info" | cut -d'|' -f3)
                    local whitelisted=$(echo "$player_info" | cut -d'|' -f4)
                    
                    log_debug "Existing player $player_name - First IP in DB: $first_ip, Current IP: $player_ip, Rank: $rank"
                    
                    if [ "$first_ip" = "UNKNOWN" ]; then
                        # First REAL connection - update IP and mark as verified
                        log_debug "First real connection for $player_name, updating IP from UNKNOWN to $player_ip"
                        update_player_info "$player_name" "$player_ip" "$password" "$rank" "$whitelisted" "NO"
                        player_verification_status["$player_name"]="verified"
                    elif [ "$first_ip" != "$player_ip" ]; then
                        # IP changed - require verification
                        log_debug "IP changed for $player_name: $first_ip -> $player_ip, requiring verification"
                        player_verification_status["$player_name"]="pending"
                        start_ip_grace_timer "$player_name" "$player_ip"
                    else
                        # IP matches - mark as verified
                        log_debug "IP matches for $player_name, marking as verified"
                        player_verification_status["$player_name"]="verified"
                    fi
                    
                    # Password enforcement for existing players without password
                    if [ "$password" = "NONE" ]; then
                        log_debug "Existing player $player_name has no password, starting enforcement"
                        start_password_enforcement "$player_name"
                    fi
                    
                    # NUEVO: Aplicar rango SUPER inmediatamente si está verificado y tiene contraseña
                    if [ "${player_verification_status[$player_name]}" = "verified" ] && [ "$password" != "NONE" ] && [ "$rank" = "SUPER" ]; then
                        log_debug "Verified SUPER admin $player_name connected, adding to cloud admin"
                        add_to_cloud_admin "$player_name"
                    fi
                fi
                
                # Sync lists for connected player using SERVER COMMANDS
                sync_lists_from_players_log
            fi
        fi
        
        # Player disconnection detection
        if [[ "$line" =~ Player\ Disconnected\ (.+) ]]; then
            local player_name="${BASH_REMATCH[1]}"
            player_name=$(echo "$player_name" | xargs)
            
            if is_valid_player_name "$player_name" ]; then
                log_debug "Player disconnected: $player_name"
                
                # Check if player was SUPER admin
                local player_info=$(get_player_info "$player_name")
                if [ -n "$player_info" ]; then
                    local rank=$(echo "$player_info" | cut -d'|' -f3)
                    if [ "$rank" = "SUPER" ]; then
                        log_debug "SUPER admin $player_name disconnected, starting 15-second timer for cloud admin removal"
                        # El timer se iniciará en apply_rank_changes cuando se quite el rango
                    fi
                fi
                
                unset connected_players["$player_name"]
                unset player_ip_map["$player_name"]
                unset player_verification_status["$player_name"]
                unset player_password_reminder_sent["$player_name"]
                
                # Cancel ALL timers except SUPER disconnect timer
                cancel_player_timers "$player_name"
                
                # Update lists using SERVER COMMANDS
                sync_lists_from_players_log
            fi
        fi
        
        # Chat command detection - IMMEDIATE PROCESSING
        if [[ "$line" =~ ([a-zA-Z0-9_]+):\ (.+)$ ]]; then
            local player_name="${BASH_REMATCH[1]}"
            local message="${BASH_REMATCH[2]}"
            local current_ip="${player_ip_map[$player_name]}"
            
            player_name=$(echo "$player_name" | xargs)
            
            if is_valid_player_name "$player_name" ]; then
                log_debug "IMMEDIATE: Chat command detected from $player_name: $message"
                
                case "$message" in
                    "!psw "*)
                        log_debug "IMMEDIATE: Password set command detected from $player_name"
                        if [[ "$message" =~ !psw\ ([^[:space:]]+)\ ([^[:space:]]+)$ ]]; then
                            local password="${BASH_REMATCH[1]}"
                            local confirm_password="${BASH_REMATCH[2]}"
                            log_debug "IMMEDIATE: Processing password set for $player_name: $password"
                            # Ejecutar inmediatamente en el mismo proceso
                            handle_password_creation "$player_name" "$password" "$confirm_password"
                        else
                            log_debug "IMMEDIATE: Invalid password command format from $player_name"
                            send_server_command "$SCREEN_SESSION" "/clear"
                            send_server_command "$SCREEN_SESSION" "ERROR: $player_name, invalid format. Use: !psw PASSWORD CONFIRM_PASSWORD"
                        fi
                        ;;
                    "!change_psw "*)
                        log_debug "IMMEDIATE: Password change command detected from $player_name"
                        if [[ "$message" =~ !change_psw\ ([^[:space:]]+)\ ([^[:space:]]+)$ ]]; then
                            local old_password="${BASH_REMATCH[1]}"
                            local new_password="${BASH_REMATCH[2]}"
                            handle_password_change "$player_name" "$old_password" "$new_password"
                        else
                            send_server_command "$SCREEN_SESSION" "/clear"
                            send_server_command "$SCREEN_SESSION" "ERROR: $player_name, invalid format. Use: !change_psw OLD_PASSWORD NEW_PASSWORD"
                        fi
                        ;;
                    "!ip_change "*)
                        log_debug "IMMEDIATE: IP change command detected from $player_name"
                        if [[ "$message" =~ !ip_change\ (.+)$ ]]; then
                            local password="${BASH_REMATCH[1]}"
                            handle_ip_change "$player_name" "$password" "$current_ip"
                        else
                            send_server_command "$SCREEN_SESSION" "/clear"
                            send_server_command "$SCREEN_SESSION" "ERROR: $player_name, invalid format. Use: !ip_change YOUR_PASSWORD"
                        fi
                        ;;
                esac
            fi
        fi
    done
}

# Function to cleanup
cleanup() {
    print_header "CLEANING UP RANK PATCHER"
    log_debug "=== CLEANUP STARTED ==="
    
    # Kill all background processes
    jobs -p | xargs kill -9 2>/dev/null
    
    # Kill all timer processes
    for timer_key in "${!active_timers[@]}"; do
        local pid="${active_timers[$timer_key]}"
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            log_debug "Killed timer: $timer_key (PID: $pid)"
        fi
    done
    
    # NUEVO: Matar todos los timers de desconexión de SUPER
    for timer_key in "${!super_admin_disconnect_timers[@]}"; do
        local pid="${super_admin_disconnect_timers[$timer_key]}"
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            log_debug "Killed SUPER disconnect timer: $timer_key (PID: $pid)"
        fi
    done
    
    log_debug "=== CLEANUP COMPLETED ==="
    print_success "Cleanup completed"
    exit 0
}

# Main execution function
main() {
    if [ $# -lt 1 ]; then
        print_error "Usage: $0 <port>"
        print_status "Example: $0 12153"
        exit 1
    fi
    
    PORT="$1"
    
    print_header "THE BLOCKHEADS RANK PATCHER"
    print_status "Starting rank patcher for port: $PORT"
    
    # Setup trap for cleanup
    trap cleanup EXIT INT TERM
    
    # Setup paths
    if ! setup_paths "$PORT"; then
        exit 1
    fi
    
    # Check if server is running
    if ! screen_session_exists "$SCREEN_SESSION"; then
        print_error "Server screen session not found: $SCREEN_SESSION"
        print_status "Please start the server first using server_manager.sh"
        exit 1
    fi
    
    # Start monitoring processes
    print_step "Starting players.log monitor..."
    monitor_players_log &
    
    print_step "Starting console.log monitor..."
    monitor_console_log &
    
    print_header "RANK PATCHER IS NOW RUNNING"
    print_status "Monitoring: $CONSOLE_LOG"
    print_status "Managing: $PLAYERS_LOG"
    print_status "Debug log: $PATCH_DEBUG_LOG"
    print_status "Server session: $SCREEN_SESSION"
    
    # Wait for background processes
    wait
}

# Run main function with all arguments
main "$@"
