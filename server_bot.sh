#!/bin/bash
# =============================================================================
# THE BLOCKHEADS SERVER ECONOMY BOT WITH RANK UPDATES AND SUPERADMINS FEATURES
# =============================================================================

# Load common functions
source blockheads_common.sh

# Validate jq is installed
if ! command -v jq &> /dev/null; then
    echo -e "${RED}ERROR: jq is required but not installed. Please install jq first.${NC}"
    exit 1
fi

# Initialize variables
[ $# -ge 2 ] && PORT="$2" || PORT="12153"
LOG_DIR=$(dirname "$1")
ECONOMY_FILE="$LOG_DIR/economy_data_$PORT.json"
SCREEN_SERVER="blockheads_server_$PORT"
PLAYERS_LOG="$LOG_DIR/players.log"
SUPERADMINS_FILE="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/cloudWideOwnedAdminlist.txt"
SAVES_DIR="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves"

# List files to manage
BLACKLIST_FILE="$LOG_DIR/blacklist.txt"
ADMINLIST_FILE="$LOG_DIR/adminlist.txt"
MODLIST_FILE="$LOG_DIR/modlist.txt"
WHITELIST_FILE="$LOG_DIR/whitelist.txt"

# Ensure superadminslist.txt exists
[ ! -f "$SUPERADMINS_FILE" ] && touch "$SUPERADMINS_FILE"

# Function to cleanup list files on startup/shutdown
cleanup_list_files() {
    local lists=("$BLACKLIST_FILE" "$ADMINLIST_FILE" "$MODLIST_FILE" "$WHITELIST_FILE")
    
    for list_file in "${lists[@]}"; do
        if [ -f "$list_file" ]; then
            > "$list_file"  # Empty the file
            print_success "Cleaned up: $(basename "$list_file")"
        else
            touch "$list_file"
            print_status "Created empty: $(basename "$list_file")"
        fi
    done
}

# Function to initialize economy
initialize_economy() {
    [ ! -f "$ECONOMY_FILE" ] && echo '{"players": {}, "transactions": []}' > "$ECONOMY_FILE"
    
    # Cleanup list files on startup
    cleanup_list_files
}

# Function to check if player is in list using players.log
is_player_in_list() {
    local player_name="$1" list_type="$2"
    local player_info=$(get_player_info "$player_name")
    if [ -n "$player_info" ]; then
        local rank=$(echo "$player_info" | cut -d'|' -f4)
        if [ "$list_type" = "admin" ] && [ "$rank" = "ADMIN" ]; then
            return 0
        elif [ "$list_type" = "mod" ] && [ "$rank" = "MOD" ]; then
            return 0
        fi
    fi
    return 1
}

# Function to update player info in players.log (7-field format)
update_player_info() {
    local player_name="$1" player_ip="$2" player_rank="$3" player_password="${4:-NONE}"
    local whitelisted="NO" blacklisted="NO"

    if [ -f "$PLAYERS_LOG" ]; then
        # Read current entry if exists
        local current_entry=$(grep -i "^$player_name|" "$PLAYERS_LOG")
        if [ -n "$current_entry" ]; then
            # Extract current fields
            local first_ip=$(echo "$current_entry" | cut -d'|' -f2)
            local current_ip=$(echo "$current_entry" | cut -d'|' -f3)
            local password=$(echo "$current_entry" | cut -d'|' -f4)
            local rank=$(echo "$current_entry" | cut -d'|' -f5)
            local whitelisted=$(echo "$current_entry" | cut -d'|' -f6)
            local blacklisted=$(echo "$current_entry" | cut -d'|' -f7)

            # Update fields we care about
            [ -n "$player_ip" ] && [ "$player_ip" != "unknown" ] && current_ip="$player_ip"
            if [ -z "$first_ip" ] || [ "$first_ip" = "unknown" ]; then
                first_ip="$player_ip"
            fi
            [ -n "$player_rank" ] && rank="$player_rank"
            [ "$player_password" != "NONE" ] && password="$player_password"

            # Replace entry
            sed -i "/^$player_name|/Id" "$PLAYERS_LOG"
            echo "$player_name|$first_ip|$current_ip|$password|$rank|$whitelisted|$blacklisted" >> "$PLAYERS_LOG"
            print_success "Updated player info in registry: $player_name -> First IP: $first_ip, Current IP: $current_ip, Password: $password, Rank: $rank, Whitelisted: $whitelisted, Blacklisted: $blacklisted"
        else
            # Create new entry
            echo "$player_name|$player_ip|$player_ip|$player_password|$player_rank|$whitelisted|$blacklisted" >> "$PLAYERS_LOG"
            print_success "Added player to registry: $player_name -> IP: $player_ip, Rank: $player_rank, Password: $player_password"
        fi
    fi
}

# Function to get player info from players.log (7-field format)
get_player_info() {
    local player_name="$1"
    if [ -f "$PLAYERS_LOG" ]; then
        while IFS='|' read -r name first_ip current_ip password rank whitelisted blacklisted; do
            if [ "$name" = "$player_name" ]; then
                echo "$first_ip|$current_ip|$password|$rank|$whitelisted|$blacklisted"
                return 0
            fi
        done < <(grep -i "^$player_name|" "$PLAYERS_LOG")
    fi
    echo ""
}

# Function to update player rank in players.log
update_player_rank() {
    local player_name="$1" new_rank="$2"
    local player_info=$(get_player_info "$player_name")
    
    if [ -n "$player_info" ]; then
        local first_ip=$(echo "$player_info" | cut -d'|' -f1)
        local current_ip=$(echo "$player_info" | cut -d'|' -f2)
        local password=$(echo "$player_info" | cut -d'|' -f3)
        local whitelisted=$(echo "$player_info" | cut -d'|' -f5)
        local blacklisted=$(echo "$player_info" | cut -d'|' -f6)
        update_player_info "$player_name" "$current_ip" "$new_rank" "$password"
        print_success "Updated player rank in registry: $player_name -> $new_rank"
    else
        print_error "Player $player_name not found in registry. Cannot update rank."
    fi
}

# Function to add player if new
add_player_if_new() {
    local player_name="$1" player_ip="$2"
    ! is_valid_player_name "$player_name" && return 1
    
    local current_data=$(read_json_file "$ECONOMY_FILE")
    local player_exists=$(echo "$current_data" | jq --arg player "$player_name" '.players | has($player)')
    
    [ "$player_exists" = "false" ] && {
        current_data=$(echo "$current_data" | jq --arg player "$player_name" \
            '.players[$player] = {"tickets": 0, "last_login": 0, "last_welcome_time": 0, "last_help_time": 0, "last_greeting_time": 0, "purchases": []}')
        write_json_file "$ECONOMY_FILE" "$current_data"
        
        # Add player to players.log if not exists
        if [ -z "$(get_player_info "$player_name")" ]; then
            update_player_info "$player_name" "$player_ip" "NONE" "NONE"
        fi
        
        give_first_time_bonus "$player_name"
        return 0
    }
    return 1
}

# Function to give first time bonus
give_first_time_bonus() {
    local player_name="$1" current_time=$(date +%s) time_str="$(date '+%Y-%m-%d %H:%M:%S')"
    local current_data=$(read_json_file "$ECONOMY_FILE")
    current_data=$(echo "$current_data" | jq --arg player "$player_name" '.players[$player].tickets = 1')
    current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson time "$current_time" '.players[$player].last_login = $time')
    current_data=$(echo "$current_data" | jq --arg player "$player_name" --arg time "$time_str" \
        '.transactions += [{"player": $player, "type": "welcome_bonus", "tickets": 1, "time": $time}]')
    write_json_file "$ECONOMY_FILE" "$current_data"
}

# Function to grant login ticket
grant_login_ticket() {
    local player_name="$1" current_time=$(date +%s) time_str="$(date '+%Y-%m-%d %H:%M:%S')"
    local current_data=$(read_json_file "$ECONOMY_FILE")
    local last_login=$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].last_login // 0')
    last_login=${last_login:-0}
    
    [ "$last_login" -eq 0 ] || [ $((current_time - last_login)) -ge 3600 ] && {
        local current_tickets=$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].tickets // 0')
        current_tickets=${current_tickets:-0}
        local new_tickets=$((current_tickets + 1))
        
        current_data=$(echo "$current_data" | jq --arg player "$player_name" \
            --argjson tickets "$new_tickets" --argjson time "$current_time" --arg time_str "$time_str" \
            '.players[$player].tickets = $tickets | 
             .players[$player].last_login = $time |
             .transactions += [{"player": $player, "type": "login_bonus", "tickets": 1, "time": $time_str}]')
        
        write_json_file "$ECONOMY_FILE" "$current_data"
        print_success "Granted 1 ticket to $player_name (Total: $new_tickets)"
    } || {
        local next_login=$((last_login + 3600))
        local time_left=$((next_login - current_time))
        print_warning "$player_name must wait $((time_left / 60)) minutes for next ticket"
    }
}

# Function to show welcome message
show_welcome_message() {
    local player_name="$1" is_new_player="$2" force_send="${3:-0}"
    ! is_valid_player_name "$player_name" && return
    
    local current_time=$(date +%s)
    local current_data=$(read_json_file "$ECONOMY_FILE")
    local last_welcome_time=$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].last_welcome_time // 0')
    last_welcome_time=${last_welcome_time:-0}
    
    # 30-second cooldown for welcome messages
    [ "$force_send" -eq 1 ] || [ "$last_welcome_time" -eq 0 ] || [ $((current_time - last_welcome_time)) -ge 30 ] && {
        if [ "$is_new_player" = "true" ]; then
            # Mensaje consolidado para nuevo jugador
            send_server_command "$SCREEN_SERVER" "Welcome $player_name! Type !help to see available commands: !tickets, !buy_mod, !buy_admin, !give_mod, !give_admin"
        else
            local last_greeting_time=$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].last_greeting_time // 0')
            [ $((current_time - last_greeting_time)) -ge 600 ] && {
                # Mensaje consolidado para jugador existente
                send_server_command "$SCREEN_SERVER" "Welcome back $player_name! Commands: !tickets (check balance), !buy_mod (50 tickets), !buy_admin (100 tickets)"
                current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson time "$current_time" '.players[$player].last_greeting_time = $time')
                write_json_file "$ECONOMY_FILE" "$current_data"
            }
        fi
        current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson time "$current_time" '.players[$player].last_welcome_time = $time')
        write_json_file "$ECONOMY_FILE" "$current_data"
    } || print_warning "Skipping welcome for $player_name due to cooldown"
}

# Function to check if player has purchased an item
has_purchased() {
    local player_name="$1" item="$2"
    local current_data=$(read_json_file "$ECONOMY_FILE")
    local has_item=$(echo "$current_data" | jq --arg player "$player_name" --arg item "$item" '.players[$player].purchases | index($item) != null')
    [ "$has_item" = "true" ]
}

# Function to add purchase
add_purchase() {
    local player_name="$1" item="$2"
    local current_data=$(read_json_file "$ECONOMY_FILE")
    current_data=$(echo "$current_data" | jq --arg player "$player_name" --arg item "$item" '.players[$player].purchases += [$item]')
    write_json_file "$ECONOMY_FILE" "$current_data"
}

# Function to process give rank command
process_give_rank() {
    local giver_name="$1" target_player="$2" rank_type="$3"
    local current_data=$(read_json_file "$ECONOMY_FILE")
    local giver_tickets=$(echo "$current_data" | jq -r --arg player "$giver_name" '.players[$player].tickets // 0')
    giver_tickets=${giver_tickets:-0}
    
    local cost=0
    [ "$rank_type" = "admin" ] && cost=140
    [ "$rank_type" = "mod" ] && cost=70
    
    [ "$giver_tickets" -lt "$cost" ] && {
        send_server_command "$SCREEN_SERVER" "$giver_name, you need $cost tickets to give $rank_type rank, but you only have $giver_tickets."
        return 1
    }
    
    ! is_valid_player_name "$target_player" && {
        send_server_command "$SCREEN_SERVER" "$giver_name, invalid player name: $target_player"
        return 1
    }
    
    local new_tickets=$((giver_tickets - cost))
    current_data=$(echo "$current_data" | jq --arg player "$giver_name" --argjson tickets "$new_tickets" '.players[$player].tickets = $tickets')
    
    local time_str="$(date '+%Y-%m-%d %H:%M:%S')"
    current_data=$(echo "$current_data" | jq --arg giver "$giver_name" --arg target "$target_player" \
        --arg rank "$rank_type" --argjson cost "$cost" --arg time "$time_str" \
        '.transactions += [{"giver": $giver, "recipient": $target, "type": "rank_gift", "rank": $rank, "tickets": -$cost, "time": $time}]')
    
    write_json_file "$ECONOMY_FILE" "$current_data"
    
    # Update player rank in players.log - THE KEY CHANGE
    update_player_rank "$target_player" "$(echo "$rank_type" | tr '[:lower:]' '[:upper:]')"
    
    send_server_command "$SCREEN_SERVER" "Congratulations! $giver_name has gifted $rank_type rank to $target_player for $cost tickets."
    send_server_command "$SCREEN_SERVER" "$giver_name, your new ticket balance: $new_tickets"
    return 0
}

# Function to process message
process_message() {
    local player_name="$1" message="$2" player_ip="$3"
    ! is_valid_player_name "$player_name" && return
    
    # Check rate limiting
    if ! check_rate_limit "$player_name"; then
        print_warning "Rate limit exceeded for $player_name"
        send_server_command "$SCREEN_SERVER" "$player_name, you're sending commands too quickly. Please wait a minute."
        return
    fi
    
    local current_data=$(read_json_file "$ECONOMY_FILE")
    local player_tickets=$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].tickets // 0')
    player_tickets=${player_tickets:-0}
    
    case "$message" in
        "!tickets"|"ltickets")
            send_server_command "$SCREEN_SERVER" "$player_name, you have $player_tickets tickets."
            ;;
        "!buy_mod")
            (has_purchased "$player_name" "mod" || is_player_in_list "$player_name" "mod") && {
                send_server_command "$SCREEN_SERVER" "$player_name, you already have MOD rank."
            } || [ "$player_tickets" -ge 50 ] && {
                local new_tickets=$((player_tickets - 50))
                current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson tickets "$new_tickets" '.players[$player].tickets = $tickets')
                add_purchase "$player_name" "mod"
                local time_str="$(date '+%Y-%m-%d %H:%M:%S')"
                current_data=$(echo "$current_data" | jq --arg player "$player_name" --arg time "$time_str" \
                    '.transactions += [{"player": $player, "type": "purchase", "item": "mod", "tickets": -50, "time": $time}]')
                write_json_file "$ECONOMY_FILE" "$current_data"
                
                # Update player rank in players.log
                update_player_rank "$player_name" "MOD"
                
                send_server_command "$SCREEN_SERVER" "Congratulations $player_name! You have been promoted to MOD for 50 tickets. Remaining tickets: $new_tickets"
            } || send_server_command "$SCREEN_SERVER" "$player_name, you need $((50 - player_tickets)) more tickets to buy MOD rank."
            ;;
        "!buy_admin")
            (has_purchased "$player_name" "admin" || is_player_in_list "$player_name" "admin") && {
                send_server_command "$SCREEN_SERVER" "$player_name, you already have ADMIN rank."
            } || [ "$player_tickets" -ge 100 ] && {
                local new_tickets=$((player_tickets - 100))
                current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson tickets "$new_tickets" '.players[$player].tickets = $tickets')
                add_purchase "$player_name" "admin"
                local time_str="$(date '+%Y-%m-%d %H:%M:%S')"
                current_data=$(echo "$current_data" | jq --arg player "$player_name" --arg time "$time_str" \
                    '.transactions += [{"player": $player, "type": "purchase", "item": "admin", "tickets": -100, "time": $time}]')
                write_json_file "$ECONOMY_FILE" "$current_data"
                
                # Update player rank in players.log
                update_player_rank "$player_name" "ADMIN"
                
                send_server_command "$SCREEN_SERVER" "Congratulations $player_name! You have been promoted to ADMIN for 100 tickets. Remaining tickets: $new_tickets"
            } || send_server_command "$SCREEN_SERVER" "$player_name, you need $((100 - player_tickets)) more tickets to buy ADMIN rank."
            ;;
        "!give_admin "*)
            [[ "$message" =~ !give_admin\ ([a-zA-Z0-9_]+) ]] && \
            process_give_rank "$player_name" "${BASH_REMATCH[1]}" "admin" || \
            send_server_command "$SCREEN_SERVER" "Usage: !give_admin PLAYER_NAME"
            ;;
        "!give_mod "*)
            [[ "$message" =~ !give_mod\ ([a-zA-Z0-9_]+) ]] && \
            process_give_rank "$player_name" "${BASH_REMATCH[1]}" "mod" || \
            send_server_command "$SCREEN_SERVER" "Usage: !give_mod PLAYER_NAME"
            ;;
        "!set_admin"|"!set_mod")
            send_server_command "$SCREEN_SERVER" "$player_name, these commands are only available to server console operators."
            ;;
        "!help")
            # Mensaje de ayuda consolidado
            send_server_command "$SCREEN_SERVER" "Available commands: !tickets (check balance) | !buy_mod (50 tickets) | !buy_admin (100 tickets) | !give_mod PLAYER (70 tickets) | !give_admin PLAYER (140 tickets)"
            ;;
    esac
}

# Function to process admin command
process_admin_command() {
    local command="$1" current_data=$(read_json_file "$ECONOMY_FILE")
    
    if [[ "$command" =~ ^!send_ticket\ ([a-zA-Z0-9_]+)\ ([0-9]+)$ ]]; then
        local player_name="${BASH_REMATCH[1]}" tickets_to_add="${BASH_REMATCH[2]}"
        
        ! is_valid_player_name "$player_name" && {
            print_error "Invalid player name: $player_name"
            return 1
        }
        
        [[ ! "$tickets_to_add" =~ ^[0-9]+$ ]] || [ "$tickets_to_add" -le 0 ] && {
            print_error "Invalid ticket amount: $tickets_to_add"
            return 1
        }
        
        local player_exists=$(echo "$current_data" | jq --arg player "$player_name" '.players | has($player)')
        [ "$player_exists" = "false" ] && print_error "Player $player_name not found" && return 1
        
        local current_tickets=$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].tickets // 0')
        current_tickets=${current_tickets:-0}
        local new_tickets=$((current_tickets + tickets_to_add))
        
        current_data=$(echo "$current_data" | jq --arg player "$player_name" \
            --argjson tickets "$new_tickets" --arg time_str "$(date '+%Y-%m-%d %H:%M:%S')" \
            --argjson amount "$tickets_to_add" \
            '.players[$player].tickets = $tickets |
             .transactions += [{"player": $player, "type": "admin_gift", "tickets": $amount, "time": $time_str}]')
        
        write_json_file "$ECONOMY_FILE" "$current_data"
        print_success "Added $tickets_to_add tickets to $player_name (Total: $new_tickets)"
        send_server_command "$SCREEN_SERVER" "$player_name received $tickets_to_add tickets from admin! Total: $new_tickets"
    elif [[ "$command" =~ ^!set_mod\ ([a-zA-Z0-9_]+)$ ]]; then
        local player_name="${BASH_REMATCH[1]}"
        ! is_valid_player_name "$player_name" && print_error "Invalid player name: $player_name" && return 1
        
        print_success "Setting $player_name as MOD"
        
        # Update player rank in players.log
        update_player_rank "$player_name" "MOD"
        
        send_server_command "$SCREEN_SERVER" "$player_name has been set as MOD by server console!"
    elif [[ "$command" =~ ^!set_admin\ ([a-zA-Z0-9_]+)$ ]]; then
        local player_name="${BASH_REMATCH[1]}"
        ! is_valid_player_name "$player_name" && print_error "Invalid player name: $player_name" && return 1
        
        print_success "Setting $player_name as ADMIN"
        
        # Update player rank in players.log
        update_player_rank "$player_name" "ADMIN"
        
        send_server_command "$SCREEN_SERVER" "$player_name has been set as ADMIN by server console!"
    else
        print_error "Unknown admin command: $command"
    fi
}

# Function to get IP by name
get_ip_by_name() {
    local name="$1"
    if [ -z "$LOG_FILE" ] || [ ! -f "$LOG_FILE" ]; then
        echo "unknown"
        return 1
    fi
    awk -F'|' -v pname="$name" '
    /Player Connected/ {
        part=$1
        sub(/.*Player Connected[[:space:]]*/, "", part)
        gsub(/^[ \t]+|[ \t]+$/, "", part)
        ip=$2
        gsub(/^[ \t]+|[ \pt]+$/, "", ip)
        if (part == pname) { last_ip=ip }
    }
    END { if (last_ip) print last_ip; else print "unknown" }
    ' "$LOG_FILE"
}

# Function to check if server sent welcome recently
server_sent_welcome_recently() {
    local player_name="$1"
    [ -z "$LOG_FILE" ] || [ ! -f "$LOG_FILE" ] && return 1
    local player_lc=$(echo "$player_name" | tr '[:upper:]' '[:lower:]')
    
    tail -n 100 "$LOG_FILE" 2>/dev/null | grep -i "server:.*welcome.*$player_lc" | head -1 | grep -q . && return 0
    
    local current_time=$(date +%s)
    local current_data=$(read_json_file "$ECONOMY_FILE")
    local last_welcome_time=$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].last_welcome_time // 0')
    
    [ "$last_welcome_time" -gt 0 ] && [ $((current_time - last_welcome_time)) -le 30 ] && return 0
    
    return 1
}

# Function to filter server log - only show relevant information
filter_server_log() {
    while read -r line; do
        # Filter out server spam and only show relevant information
        if [[ "$line" == *"Server closed"* || \
              "$line" == *"Starting server"* || \
              "$line" == *"World load complete"* || \
              "$line" == *"Exiting World"* || \
              "$line" == *"Loading world named"* || \
              "$line" == *"using seed:"* || \
              "$line" == *"save delay:"* || \
              "$line" == *"adminlist.txt"* || \
              "$line" == *"modlist.txt"* ]]; then
            continue
        fi

        # Show only player connections, disconnections, and chat messages
        if [[ "$line" == *"Player Connected"* || \
              "$line" == *"Player Disconnected"* || \
              "$line" == *"SERVER: say"* || \
              "$line" =~ [a-zA-Z0-9_]+:[[:space:]] || \
              "$line" =~ [a-zA-Z0-9_]+:[[:space:]]*[^[:space:]] ]]; then
            echo "$line"
        fi
    done
}

# Function to monitor superadmins
monitor_superadmins() {
    while true; do
        sleep 0.5
        [ ! -f "$SUPERADMINS_FILE" ] && continue
        
        # Read superadmins list
        mapfile -t superadmins < <(grep -v "^[[:space:]]*$" "$SUPERADMINS_FILE" 2>/dev/null | tr -d '\r')
        
        # Ensure all superadmins have SUPER rank in players.log
        for player in "${superadmins[@]}"; do
            player=$(echo "$player" | xargs)
            [ -z "$player" ] && continue
            
            # Check if player exists in players.log with SUPER rank
            local player_info=$(get_player_info "$player")
            if [ -n "$player_info" ]; then
                local current_rank=$(echo "$player_info" | cut -d'|' -f4)
                if [ "$current_rank" != "SUPER" ]; then
                    print_warning "Superadmin $player does not have SUPER rank. Updating..."
                    local first_ip=$(echo "$player_info" | cut -d'|' -f1)
                    local current_ip=$(echo "$player_info" | cut -d'|' -f2)
                    local password=$(echo "$player_info" | cut -d'|' -f3)
                    local whitelisted=$(echo "$player_info" | cut -d'|' -f5)
                    local blacklisted=$(echo "$player_info" | cut -d'|' -f6)
                    update_player_info "$player" "$current_ip" "SUPER" "$password"
                fi
            else
                # Player not found, add with SUPER rank
                print_warning "Superadmin $player not found in players.log. Adding..."
                update_player_info "$player" "unknown" "SUPER" "NONE"
            fi
        done
    done
}

# Function to handle superadmin connections
handle_superadmin_connection() {
    local player_name="$1" player_ip="$2"
    
    # Check if player is in superadmins list
    if [ -f "$SUPERADMINS_FILE" ] && grep -q "^$player_name$" "$SUPERADMINS_FILE" 2>/dev/null; then
        # Update players.log with SUPER rank
        update_player_rank "$player_name" "SUPER"
        
        # Send welcome message after 1.0 second
        (
            sleep 1.0
            local player_info=$(get_player_info "$player_name")
            if [ -n "$player_info" ]; then
                local password=$(echo "$player_info" | cut -d'|' -f3)
                if [ "$password" = "NONE" ]; then
                    send_server_command "$SCREEN_SERVER" "SUPER ADMIN $player_name has joined the server! REMINDER: Please set your password with !ip_psw to secure your account."
                else
                    send_server_command "$SCREEN_SERVER" "SUPER ADMIN $player_name has joined the server!"
                fi
            fi
        ) &
    fi
}

# Function to cleanup
cleanup() {
    print_status "Cleaning up..."
    
    # Cleanup list files on shutdown
    cleanup_list_files
    
    rm -f "$admin_pipe" 2>/dev/null
    kill $(jobs -p) 2>/dev/null
    rm -f "${ECONOMY_FILE}.lock" 2>/dev/null
    exit 0
}

# Function to monitor log
monitor_log() {
    local log_file="$1"
    LOG_FILE="$log_file"

    initialize_economy

    # Start superadmins monitor in background
    monitor_superadmins &
    local superadmins_pid=$!

    trap cleanup EXIT INT TERM

    print_header "STARTING ECONOMY BOT"
    print_status "Monitoring: $log_file"
    print_status "Bot commands: !tickets, !buy_mod, !buy_admin, !give_mod, !give_admin, !help"
    print_status "Admin commands: !send_ticket <player> <amount>, !set_mod <player>, !set_admin <player>"
    print_header "READY FOR COMMANDS"

    local admin_pipe="/tmp/blockheads_admin_pipe_$$"
    rm -f "$admin_pipe"
    mkfifo "$admin_pipe"

    # Admin command processor
    (
        while read -r admin_command < "$admin_pipe"; do
            print_status "Processing admin command: $admin_command"
            [[ "$admin_command" == "!send_ticket "* || "$admin_command" == "!set_mod "* || "$admin_command" == "!set_admin "* ]] && \
            process_admin_command "$admin_command" || \
            print_error "Unknown admin command"
            print_header "READY FOR NEXT COMMAND"
        done
    ) &

    # Admin command reader
    (
        while read -r admin_command; do
            echo "$admin_command" > "$admin_pipe"
        done
    ) &

    # Wait for log file to exist
    local wait_time=0
    while [ ! -f "$log_file" ] && [ $wait_time -lt 30 ]; do
        sleep 1
        ((wait_time++))
        [ $((wait_time % 5)) -eq 0 ] && print_status "Waiting for log file to be created..."
    done
    
    if [ ! -f "$log_file" ]; then
        print_error "Log file never appeared: $log_file"
        kill $(jobs -p) 2>/dev/null
        kill $superadmins_pid 2>/dev/null
        exit 1
    fi

    # Start monitoring the log
    tail -n 0 -F "$log_file" 2>/dev/null | filter_server_log | while read -r line; do
        if [[ "$line" =~ Player\ Connected\ (.+)\ \|\ ([0-9a-fA-F.:]+)\ \|\ ([0-9a-f]+) ]]; then
            local player_name="${BASH_REMATCH[1]}" player_ip="${BASH_REMATCH[2]}" player_hash="${BASH_REMATCH[3]}"
            player_name=$(extract_real_name "$player_name")
            player_name=$(echo "$player_name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [ "$player_name" == "SERVER" ] && continue

            ! is_valid_player_name "$player_name" && {
                print_warning "Skipping invalid player name: '$player_name' (IP: $player_ip)"
                continue
            }

            print_success "Player connected: $player_name (IP: $player_ip)"

            local is_new_player="false"
            add_player_if_new "$player_name" "$player_ip" && is_new_player="true"

            # Handle superadmin connection
            handle_superadmin_connection "$player_name" "$player_ip"

            sleep 3

            ! server_sent_welcome_recently "$player_name" && \
            show_welcome_message "$player_name" "$is_new_player" 1 || \
            print_warning "Server already welcomed $player_name"

            [ "$is_new_player" = "false" ] && grant_login_ticket "$player_name"
            continue
        fi

        if [[ "$line" =~ Player\ Disconnected\ ([a-zA-Z0-9_]+) ]]; then
            local player_name="${BASH_REMATCH[1]}"
            player_name=$(extract_real_name "$player_name")
            player_name=$(echo "$player_name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [ "$player_name" == "SERVER" ] && continue
            
            ! is_valid_player_name "$player_name" && {
                print_warning "Skipping invalid player name: '$player_name'"
                continue
            }
            
            print_warning "Player disconnected: $player_name"
            continue
        fi

        if [[ "$line" =~ ([a-zA-Z0-9_]+):\ (.+)$ ]]; then
            local player_name="${BASH_REMATCH[1]}" message="${BASH_REMATCH[2]}"
            player_name=$(extract_real_name "$player_name")
            player_name=$(echo "$player_name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [ "$player_name" == "SERVER" ] && continue
            
            ! is_valid_player_name "$player_name" && {
                print_warning "Skipping message from invalid player name: '$player_name'"
                continue
            }
            
            print_status "Chat: $player_name: $message"
            
            # Get player IP for rank updates
            local player_ip=$(get_ip_by_name "$player_name")
            add_player_if_new "$player_name" "$player_ip"
            process_message "$player_name" "$message" "$player_ip"
            continue
        fi

        # Skip other log lines to avoid spam
        # print_status "Other log line: $line"
    done

    kill $superadmins_pid 2>/dev/null
    rm -f "$admin_pipe"
}

# Function to show usage
show_usage() {
    print_header "ECONOMY BOT - USAGE"
    print_status "Usage: $0 <server_log_file> [port]"
    print_status "Example: $0 /path/to/console.log 12153"
    echo ""
    print_warning "Note: This script should be run alongside the server"
}

# Main execution
if [ $# -lt 1 ]; then
    show_usage
    exit 1
fi

if [ $# -eq 1 ] || [ $# -eq 2 ]; then
    initialize_economy
    monitor_log "$1"
else
    show_usage
    exit 1
fi
