#!/bin/bash

BASE_DIR="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves"
CONSOLE_LOG="$1"
WORLD_ID="$2"
PORT="$3"

if [ -z "$WORLD_ID" ] && [ -n "$CONSOLE_LOG" ]; then
    WORLD_ID=$(echo "$CONSOLE_LOG" | grep -oE 'saves/[^/]+' | cut -d'/' -f2)
fi

if [ -z "$CONSOLE_LOG" ] || [ -z "$WORLD_ID" ]; then
    echo "Usage: $0 <console_log_path> [world_id] [port]"
    echo "Example: $0 /path/to/console.log world123 12153"
    exit 1
fi

PLAYERS_LOG="$BASE_DIR/$WORLD_ID/players.log"
ADMIN_LIST="$BASE_DIR/$WORLD_ID/adminlist.txt"
MOD_LIST="$BASE_DIR/$WORLD_ID/modlist.txt"
WHITELIST="$BASE_DIR/$WORLD_ID/whitelist.txt"
BLACKLIST="$BASE_DIR/$WORLD_ID/blacklist.txt"
CLOUD_ADMIN_LIST="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/cloudWideOwnedAdminlist.txt"

SCREEN_SERVER="blockheads_server_${PORT:-12153}"

COMMAND_COOLDOWN=0.5
PASSWORD_TIMEOUT=60
IP_VERIFY_TIMEOUT=30
IP_BAN_DURATION=30
WELCOME_DELAY=5
LIST_SYNC_INTERVAL=5

declare -A connected_players
declare -A player_ip_map
declare -A password_pending
declare -A ip_verify_pending
declare -A ip_banned_times
declare -A last_warning_time

send_server_command() {
    local command="$1"
    sleep "$COMMAND_COOLDOWN"
    screen -S "$SCREEN_SERVER" -X stuff "$command$(printf \\r)" 2>/dev/null
}

kick_player() {
    local player_name="$1"
    screen -S "$SCREEN_SERVER" -X stuff "/kick $player_name$(printf \\r)"
    sleep "$COMMAND_COOLDOWN"
}

clear_chat() {
    send_server_command "/clear"
}

initialize_players_log() {
    if [ ! -f "$PLAYERS_LOG" ]; then
        mkdir -p "$(dirname "$PLAYERS_LOG")"
        touch "$PLAYERS_LOG"
        echo "# Player Name | First IP | Password | Rank | Whitelisted | Blacklisted" > "$PLAYERS_LOG"
    fi
}

read_players_log() {
    declare -gA players_data
    if [ ! -f "$PLAYERS_LOG" ]; then
        return 1
    fi
    
    while IFS='|' read -r name ip password rank whitelisted blacklisted; do
        [[ "$name" =~ ^# ]] && continue
        [[ -z "$name" ]] && continue
        
        name=$(echo "$name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        ip=$(echo "$ip" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        password=$(echo "$password" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        rank=$(echo "$rank" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        whitelisted=$(echo "$whitelisted" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        blacklisted=$(echo "$blacklisted" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        
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

update_players_log() {
    local player_name="$1" field="$2" new_value="$3"
    
    if [ -z "$player_name" ] || [ -z "$field" ]; then
        return 1
    fi
    
    read_players_log
    
    case "$field" in
        "ip") players_data["$player_name,ip"]="$new_value" ;;
        "password") players_data["$player_name,password"]="$new_value" ;;
        "rank") players_data["$player_name,rank"]="$new_value" ;;
        "whitelisted") players_data["$player_name,whitelisted"]="$new_value" ;;
        "blacklisted") players_data["$player_name,blacklisted"]="$new_value" ;;
        *) return 1 ;;
    esac
    
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
                echo "$name | $ip | $password | $rank | $whitelisted | $blacklisted"
            fi
        done
    } > "$PLAYERS_LOG"
}

add_new_player() {
    local player_name="$1" player_ip="$2"
    
    if [ -z "$player_name" ] || [ -z "$player_ip" ]; then
        return 1
    fi
    
    read_players_log
    if [ -n "${players_data["$player_name,name"]}" ]; then
        return 0
    fi
    
    players_data["$player_name,name"]="$player_name"
    players_data["$player_name,ip"]="$player_ip"
    players_data["$player_name,password"]="NONE"
    players_data["$player_name,rank"]="NONE"
    players_data["$player_name,whitelisted"]="NO"
    players_data["$player_name,blacklisted"]="NO"
    
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
                echo "$name | $ip | $password | $rank | $whitelisted | $blacklisted"
            fi
        done
    } > "$PLAYERS_LOG"
}

is_ip_verified() {
    local player_name="$1"
    local current_ip="$2"
    
    read_players_log
    local stored_ip="${players_data["$player_name,ip"]}"
    
    if [ "$stored_ip" = "UNKNOWN" ] || [ "$stored_ip" = "$current_ip" ]; then
        return 0
    fi
    
    return 1
}

sync_server_lists() {
    read_players_log
    
    for list_file in "$ADMIN_LIST" "$MOD_LIST" "$WHITELIST" "$BLACKLIST"; do
        > "$list_file"
    done
    
    > "$CLOUD_ADMIN_LIST"
    
    for key in "${!players_data[@]}"; do
        if [[ "$key" == *,name ]]; then
            local name="${players_data[$key]}"
            local ip="${players_data["$name,ip"]}"
            local rank="${players_data["$name,rank"]}"
            local whitelisted="${players_data["$name,whitelisted"]}"
            local blacklisted="${players_data["$name,blacklisted"]}"
            local current_ip="${player_ip_map[$name]}"
            
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
}

handle_rank_change() {
    local player_name="$1" old_rank="$2" new_rank="$3"
    
    case "$new_rank" in
        "ADMIN")
            if [ "$old_rank" = "NONE" ]; then
                send_server_command "/admin $player_name"
            fi
            ;;
        "MOD")
            if [ "$old_rank" = "NONE" ]; then
                send_server_command "/mod $player_name"
            fi
            ;;
        "SUPER")
            if ! tail -n +3 "$CLOUD_ADMIN_LIST" 2>/dev/null | grep -q "^$player_name$"; then
                echo "$player_name" >> "$CLOUD_ADMIN_LIST"
            fi
            ;;
        "NONE")
            if [ "$old_rank" = "ADMIN" ]; then
                send_server_command "/unadmin $player_name"
            elif [ "$old_rank" = "MOD" ]; then
                send_server_command "/unmod $player_name"
            elif [ "$old_rank" = "SUPER" ]; then
                temp_file=$(mktemp)
                tail -n +3 "$CLOUD_ADMIN_LIST" 2>/dev/null | grep -v "^$player_name$" > "$temp_file"
                mv "$temp_file" "$CLOUD_ADMIN_LIST"
            fi
            ;;
    esac
}

handle_blacklist_change() {
    local player_name="$1" blacklisted="$2" player_ip="$3"
    
    if [ "$blacklisted" = "YES" ]; then
        read_players_log
        local rank="${players_data["$player_name,rank"]}"
        
        if [ "$rank" = "SUPER" ] && [ -n "${connected_players[$player_name]}" ]; then
            send_server_command "/stop"
            sleep 2
        fi
        
        if [ "$rank" = "MOD" ]; then
            send_server_command "/unmod $player_name"
        elif [ "$rank" = "ADMIN" ] || [ "$rank" = "SUPER" ]; then
            send_server_command "/unadmin $player_name"
        fi
        
        if [ "$rank" = "SUPER" ]; then
            temp_file=$(mktemp)
            tail -n +3 "$CLOUD_ADMIN_LIST" 2>/dev/null | grep -v "^$player_name$" > "$temp_file"
            mv "$temp_file" "$CLOUD_ADMIN_LIST"
        fi
        
        send_server_command "/ban $player_name"
        
        if [ "$player_ip" != "UNKNOWN" ]; then
            send_server_command "/ban $player_ip"
            ip_banned_times["$player_ip"]=$(date +%s)
        fi
    fi
}

auto_unban_ips() {
    local current_time=$(date +%s)
    
    for ip in "${!ip_banned_times[@]}"; do
        local ban_time="${ip_banned_times[$ip]}"
        if [ $((current_time - ban_time)) -ge $IP_BAN_DURATION ]; then
            send_server_command "/unban $ip"
            unset ip_banned_times["$ip"]
        fi
    done
}

validate_password() {
    local password="$1"
    local length=${#password}
    
    if [ $length -lt 7 ] || [ $length -gt 16 ]; then
        echo "Password must be between 7 and 16 characters"
        return 1
    fi
    
    if ! echo "$password" | grep -qE '^[A-Za-z0-9!@#$%^_+-=]+$'; then
        echo "Password contains invalid characters. Only letters, numbers and !@#$%^_+-= are allowed"
        return 1
    fi
    
    return 0
}

handle_password_command() {
    local player_name="$1" password="$2" confirm_password="$3"
    
    if [ "$password" != "$confirm_password" ]; then
        send_server_command "Passwords do not match"
        return 1
    fi
    
    local validation_result
    validation_result=$(validate_password "$password")
    if [ $? -ne 0 ]; then
        send_server_command "$validation_result"
        return 1
    fi
    
    update_players_log "$player_name" "password" "$password"
    send_server_command "Password set successfully for $player_name"
    unset password_pending["$player_name"]
    unset last_warning_time["$player_name"]
    return 0
}

handle_ip_change() {
    local player_name="$1" provided_password="$2" current_ip="$3"
    
    read_players_log
    local stored_password="${players_data["$player_name,password"]}"
    
    if [ "$stored_password" = "NONE" ]; then
        send_server_command "No password set for $player_name. Use !password first."
        return 1
    fi
    
    if [ "$provided_password" != "$stored_password" ]; then
        send_server_command "Incorrect password for IP verification"
        return 1
    fi
    
    update_players_log "$player_name" "ip" "$current_ip"
    send_server_command "IP address verified and updated for $player_name"
    unset ip_verify_pending["$player_name"]
    return 0
}

send_welcome_message() {
    local player_name="$1" is_new_player="$2"
    sleep "$WELCOME_DELAY"
    
    if [ "$is_new_player" = "true" ]; then
        send_server_command "Welcome $player_name! Please set a password using: !password YOUR_PASSWORD CONFIRM_PASSWORD"
        send_server_command "You have 60 seconds to set your password or you will be kicked."
    else
        send_server_command "Welcome back $player_name!"
    fi
}

send_ip_warning() {
    local player_name="$1"
    sleep "$WELCOME_DELAY"
    send_server_command "IP change detected for $player_name. Verify with: !ip_change YOUR_PASSWORD"
    send_server_command "You have 30 seconds to verify your IP or you will be kicked and IP banned."
}

send_password_warning() {
    local player_name="$1" time_left="$2"
    send_server_command "WARNING $player_name: You have $time_left seconds to set your password with !password YOUR_PASSWORD CONFIRM_PASSWORD or you will be kicked!"
}

monitor_console_log() {
    echo "Starting rank_patcher monitoring"
    echo "World: $WORLD_ID"
    echo "Console log: $CONSOLE_LOG"
    echo "Players log: $PLAYERS_LOG"
    
    initialize_players_log
    sync_server_lists
    
    tail -n 0 -F "$CONSOLE_LOG" | while read line; do
        if echo "$line" | grep -q "Player Connected"; then
            local player_name=$(echo "$line" | sed -n 's/.*Player Connected \([^ |]*\) .*/\1/p')
            local player_ip=$(echo "$line" | sed -n 's/.*Player Connected [^ |]* | \([0-9.]*\) .*/\1/p')
            
            if [ -n "$player_name" ] && [ -n "$player_ip" ]; then
                echo "Player connected: $player_name ($player_ip)"
                connected_players["$player_name"]=1
                player_ip_map["$player_name"]="$player_ip"
                
                read_players_log
                if [ -z "${players_data["$player_name,name"]}" ]; then
                    add_new_player "$player_name" "$player_ip"
                    send_welcome_message "$player_name" "true" &
                    password_pending["$player_name"]=$(date +%s)
                    last_warning_time["$player_name"]=0
                else
                    local stored_ip="${players_data["$player_name,ip"]}"
                    local stored_password="${players_data["$player_name,password"]}"
                    
                    if [ "$stored_ip" != "$player_ip" ] && [ "$stored_ip" != "UNKNOWN" ]; then
                        send_ip_warning "$player_name" &
                        ip_verify_pending["$player_name"]=$(date +%s)
                    fi
                    
                    if [ "$stored_password" = "NONE" ]; then
                        send_welcome_message "$player_name" "false" &
                        password_pending["$player_name"]=$(date +%s)
                        last_warning_time["$player_name"]=0
                    fi
                fi
                sync_server_lists
            fi
            continue
        fi
        
        if [[ "$line" =~ Player\ Disconnected\ ([a-zA-Z0-9_]+) ]]; then
            local player_name="${BASH_REMATCH[1]}"
            echo "Player disconnected: $player_name"
            unset connected_players["$player_name"]
            unset player_ip_map["$player_name"]
            unset password_pending["$player_name"]
            unset ip_verify_pending["$player_name"]
            unset last_warning_time["$player_name"]
            sync_server_lists
            continue
        fi
        
        if [[ "$line" =~ ([a-zA-Z0-9_]+):\ (.+)$ ]]; then
            local player_name="${BASH_REMATCH[1]}"
            local message="${BASH_REMATCH[2]}"
            [ "$player_name" = "SERVER" ] && continue
            
            case "$message" in
                "!password "*)
                    if [[ "$message" =~ !password\ ([^ ]+)\ ([^ ]+) ]]; then
                        local password="${BASH_REMATCH[1]}"
                        local confirm_password="${BASH_REMATCH[2]}"
                        clear_chat
                        if [ "$password" != "$confirm_password" ]; then
                            send_server_command "Passwords do not match"
                        else
                            update_players_log "$player_name" "password" "$password"
                            send_server_command "Password set successfully for $player_name"
                            unset password_pending["$player_name"]
                            unset last_warning_time["$player_name"]
                        fi
                    else
                        send_server_command "Usage: !password NEW_PASSWORD CONFIRM_PASSWORD"
                    fi
                    ;;
                "!ip_change "*)
                    if [[ "$message" =~ !ip_change\ ([^ ]+) ]]; then
                        local password="${BASH_REMATCH[1]}"
                        local current_ip="${player_ip_map[$player_name]}"
                        clear_chat
                        read_players_log
                        local stored_password="${players_data["$player_name,password"]}"
                        if [ "$stored_password" = "NONE" ]; then
                            send_server_command "No password set for $player_name. Use !password first."
                        elif [ "$password" != "$stored_password" ]; then
                            send_server_command "Incorrect password for IP verification"
                        else
                            update_players_log "$player_name" "ip" "$current_ip"
                            send_server_command "IP address verified and updated for $player_name"
                            unset ip_verify_pending["$player_name"]
                        fi
                    else
                        send_server_command "Usage: !ip_change YOUR_PASSWORD"
                    fi
                    ;;
            esac
        fi
    done
}

check_timeouts() {
    local current_time=$(date +%s)
    
    for player in "${!password_pending[@]}"; do
        if [ -z "${password_pending[$player]}" ]; then
            continue
        fi
        
        local start_time="${password_pending[$player]}"
        local time_elapsed=$((current_time - start_time))
        
        if [ $time_elapsed -ge $PASSWORD_TIMEOUT ]; then
            echo "PASSWORD TIMEOUT REACHED for $player - KICKING NOW"
            kick_player "$player" "No password set within 60 seconds"
            unset connected_players["$player"]
            unset player_ip_map["$player"]
            unset password_pending["$player"]
            unset last_warning_time["$player"]
        else
            local time_left=$((PASSWORD_TIMEOUT - time_elapsed))
            local last_warn="${last_warning_time[$player]:-0}"
            local time_since_last_warn=$((current_time - last_warn))
            
            if [ $time_left -le 50 ] && [ $time_left -gt 40 ] && [ $time_since_last_warn -ge 10 ]; then
                send_password_warning "$player" "$time_left"
                last_warning_time["$player"]=$current_time
            elif [ $time_left -le 40 ] && [ $time_left -gt 30 ] && [ $time_since_last_warn -ge 10 ]; then
                send_password_warning "$player" "$time_left"
                last_warning_time["$player"]=$current_time
            elif [ $time_left -le 30 ] && [ $time_left -gt 20 ] && [ $time_since_last_warn -ge 10 ]; then
                send_password_warning "$player" "$time_left"
                last_warning_time["$player"]=$current_time
            elif [ $time_left -le 20 ] && [ $time_left -gt 10 ] && [ $time_since_last_warn -ge 10 ]; then
                send_password_warning "$player" "$time_left"
                last_warning_time["$player"]=$current_time
            elif [ $time_left -le 10 ] && [ $time_since_last_warn -ge 5 ]; then
                send_password_warning "$player" "$time_left"
                last_warning_time["$player"]=$current_time
            fi
        fi
    done
    
    for player in "${!ip_verify_pending[@]}"; do
        if [ -z "${ip_verify_pending[$player]}" ]; then
            continue
        fi
        
        local start_time="${ip_verify_pending[$player]}"
        local time_elapsed=$((current_time - start_time))
        
        if [ $time_elapsed -ge $IP_VERIFY_TIMEOUT ]; then
            local player_ip="${player_ip_map[$player]}"
            echo "IP VERIFICATION TIMEOUT for $player - KICKING AND BANNING"
            kick_player "$player" "IP verification failed within 30 seconds"
            send_server_command "/ban $player_ip"
            unset connected_players["$player"]
            unset player_ip_map["$player"]
            unset ip_verify_pending["$player"]
            ip_banned_times["$player_ip"]=$(date +%s)
        fi
    done
    
    auto_unban_ips
}

periodic_list_sync() {
    while true; do
        sleep "$LIST_SYNC_INTERVAL"
        sync_server_lists
    done
}

main() {
    echo "THE BLOCKHEADS RANK PATCHER"
    echo "Starting player management system..."
    
    if [ ! -f "$CONSOLE_LOG" ]; then
        echo "Console log not found: $CONSOLE_LOG"
        echo "Waiting for log file to be created..."
        local wait_time=0
        while [ ! -f "$CONSOLE_LOG" ] && [ $wait_time -lt 30 ]; do
            sleep 1
            ((wait_time++))
        done
        
        if [ ! -f "$CONSOLE_LOG" ]; then
            echo "Console log never appeared: $CONSOLE_LOG"
            exit 1
        fi
    fi
    
    initialize_players_log
    sync_server_lists
    
    monitor_console_log &
    local console_pid=$!
    
    periodic_list_sync &
    local sync_pid=$!
    
    while true; do
        check_timeouts
        sleep 2
    done
    
    wait $console_pid $sync_pid
}

main "$@"
