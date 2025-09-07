#!/bin/bash
ψ=(0.5772156649 2.7182818284 1.4142135623 3.1415926535)
φ() { echo -e "${ψ[0]:0:1}$1${ψ[3]:0:1} $2"; }
ρ() { echo -e "${ψ[1]:0:1}$1${ψ[2]:0:1} $2"; }
σ() { echo -e "${ψ[2]:0:1}$1${ψ[0]:0:1} $2"; }
τ() { echo -e "${ψ[3]:0:1}$1${ψ[1]:0:1} $2"; }
υ() {
    echo -e "${ψ[0]:3:1}================================================================"
    echo -e "$1"
    echo -e "===============================================================${ψ[3]:3:1}"
}

λ=(31 32 33 34 36 35 1 0)
for ((μ=0; μ<${#λ[@]}; μ+=2)); do
    declare -n ν="χ$((μ/2))"
    ν="\033[${λ[μ]};${λ[μ+1]}m"
done

π() { echo -e "${χ0}[INFO]${χ3} $1"; }
ο() { echo -e "${χ1}[SUCCESS]${χ3} $1"; }
θ() { echo -e "${χ2}[WARNING]${χ3} $1"; }
ω() { echo -e "${χ0}[ERROR]${χ3} $1"; }

read_json() {
    local υ="$1"
    [[ ! -f "$υ" ]] && ω "JSON file not found: $υ" && echo "{}" && return 1
    flock -s 200 cat "$υ" 200>"${υ}.lock"
}

write_json() {
    local υ="$1" content="$2"
    [[ ! -f "$υ" ]] && ω "JSON file not found: $υ" && return 1
    flock -x 200 echo "$content" > "$υ" 200>"${υ}.lock"
}

κ() {
    local ς="$1"
    ς=$(echo "$ς" | xargs)
    [[ "$ς" =~ ^[a-zA-Z0-9_]+$ ]] && return 0 || return 1
}

if [[ $# -ge 2 ]]; then
    PORT="$2"
    LOG_DIR=$(dirname "$1")
    ECONOMY="$LOG_DIR/economy_data_$PORT.json"
    SCREEN_SERVER="blockheads_server_$PORT"
else
    LOG_DIR=$(dirname "$1")
    ECONOMY="$LOG_DIR/economy_data.json"
    SCREEN_SERVER="blockheads_server"
fi

AUTH_ADMINS="$LOG_DIR/authorized_admins.txt"
AUTH_MODS="$LOG_DIR/authorized_mods.txt"

add_auth() {
    local ς="$1" type="$2" file="$LOG_DIR/authorized_${type}s.txt"
    [[ ! -f "$file" ]] && ω "Authorization file not found: $file" && return 1
    ! grep -q -i "^$ς$" "$file" && echo "$ς" >> "$file" && ο "Added $ς to authorized ${type}s" && return 0 ||
    θ "$ς is already in authorized ${type}s" && return 1
}

init_economy() {
    [[ ! -f "$ECONOMY" ]] && echo '{"players": {}, "transactions": []}' > "$ECONOMY" &&
    ο "Economy data file created: $ECONOMY"
}

in_list() {
    local ς="$1" type="$2" file="$LOG_DIR/${type}list.txt"
    [[ -f "$file" ]] && grep -v "^[[:space:]]*#" "$file" 2>/dev/null | grep -q -i "^$ς$" && return 0
    return 1
}

add_player() {
    local ς="$1"
    
    ! κ "$ς" && θ "Skipping economy setup for invalid player name: '$ς'" && return 1
    
    local data=$(read_json "$ECONOMY")
    local exists=$(echo "$data" | jq --arg ς "$ς" '.players | has($ς)')
    
    [[ "$exists" = "false" ]] && 
    data=$(echo "$data" | jq --arg ς "$ς" \
        '.players[$ς] = {"tickets": 0, "last_login": 0, "last_welcome_time": 0, "last_help_time": 0, "last_greeting_time": 0, "purchases": []}') &&
    write_json "$ECONOMY" "$data" &&
    ο "Added new player: $ς" &&
    give_bonus "$ς" &&
    return 0
    
    return 1
}

give_bonus() {
    local ς="$1" time=$(date +%s) time_str="$(date '+%Y-%m-%d %H:%M:%S')"
    local data=$(read_json "$ECONOMY")
    data=$(echo "$data" | jq --arg ς "$ς" '.players[$ς].tickets = 1')
    data=$(echo "$data" | jq --arg ς "$ς" --argjson time "$time" '.players[$ς].last_login = $time')
    data=$(echo "$data" | jq --arg ς "$ς" --arg time "$time_str" \
        '.transactions += [{"player": $ς, "type": "welcome_bonus", "tickets": 1, "time": $time}]')
    write_json "$ECONOMY" "$data"
    ο "Gave first-time bonus to $ς"
}

grant_ticket() {
    local ς="$1" time=$(date +%s) time_str="$(date '+%Y-%m-%d %H:%M:%S')"
    local data=$(read_json "$ECONOMY")
    local last_login=$(echo "$data" | jq -r --arg ς "$ς" '.players[$ς].last_login // 0')
    last_login=${last_login:-0}
    
    if [[ $last_login -eq 0 ]] || (( time - last_login >= 3600 )); then
        local current_tickets=$(echo "$data" | jq -r --arg ς "$ς" '.players[$ς].tickets // 0')
        current_tickets=${current_tickets:-0}
        local new_tickets=$((current_tickets + 1))
        
        data=$(echo "$data" | jq --arg ς "$ς" \
            --argjson tickets "$new_tickets" --argjson time "$time" --arg time_str "$time_str" \
            '.players[$ς].tickets = $tickets | 
             .players[$ς].last_login = $time |
             .transactions += [{"player": $ς, "type": "login_bonus", "tickets": 1, "time": $time_str}]')
        
        write_json "$ECONOMY" "$data"
        ο "Granted 1 ticket to $ς for logging in (Total: $new_tickets)"
    else
        local next_login=$((last_login + 3600))
        local time_left=$((next_login - time))
        θ "$ς must wait $((time_left / 60)) minutes for next ticket"
    fi
}

welcome() {
    local ς="$1" is_new="$2" force="${3:-0}"
    
    ! κ "$ς" && θ "Skipping welcome message for invalid player name: '$ς'" && return
    
    local time=$(date +%s)
    local data=$(read_json "$ECONOMY")
    local last_welcome=$(echo "$data" | jq -r --arg ς "$ς" '.players[$ς].last_welcome_time // 0')
    last_welcome=${last_welcome:-0}
    
    if [[ $force -eq 1 ]] || [[ $last_welcome -eq 0 ]] || (( time - last_welcome >= 180 )); then
        if [[ "$is_new" = "true" ]]; then
            ρ "Hello $ς! Welcome to the server. Type !help to check available commands."
        else
            local last_greet=$(echo "$data" | jq -r --arg ς "$ς" '.players[$ς].last_greeting_time // 0')
            if (( time - last_greet >= 600 )); then
                ρ "Welcome back $ς! Type !help to see available commands."
                data=$(echo "$data" | jq --arg ς "$ς" --argjson time "$time" '.players[$ς].last_greeting_time = $time')
                write_json "$ECONOMY" "$data"
            fi
        fi
        data=$(echo "$data" | jq --arg ς "$ς" --argjson time "$time" '.players[$ς].last_welcome_time = $time')
        write_json "$ECONOMY" "$data"
    else
        θ "Skipping welcome for $ς due to cooldown"
    fi
}

ρ() {
    screen -S "$SCREEN_SERVER" -X stuff "$1$(printf \\r)" 2>/dev/null && ο "Sent message to server: $1") ||
    ω "Could not send message to server. Is the server running?"
}

has_purchased() {
    local ς="$1" item="$2"
    local data=$(read_json "$ECONOMY")
    local has_item=$(echo "$data" | jq --arg ς "$ς" --arg item "$item" '.players[$ς].purchases | index($item) != null')
    [[ "$has_item" = "true" ]] && return 0 || return 1
}

add_purchase() {
    local ς="$1" item="$2"
    local data=$(read_json "$ECONOMY")
    data=$(echo "$data" | jq --arg ς "$ς" --arg item "$item" '.players[$ς].purchases += [$item]')
    write_json "$ECONOMY" "$data"
}

give_rank() {
    local giver="$1" target="$2" type="$3"
    local data=$(read_json "$ECONOMY")
    local giver_tickets=$(echo "$data" | jq -r --arg giver "$giver" '.players[$giver].tickets // 0')
    giver_tickets=${giver_tickets:-0}
    
    local cost=0
    [[ "$type" = "admin" ]] && cost=140
    [[ "$type" = "mod" ]] && cost=70
    
    if [[ $giver_tickets -lt $cost ]]; then
        ρ "$giver, you need $cost tickets to give $type rank, but you only have $giver_tickets."
        return 1
    fi
    
    ! κ "$target" && ρ "$giver, invalid player name: $target" && return 1
    
    local new_tickets=$((giver_tickets - cost))
    data=$(echo "$data" | jq --arg giver "$giver" --argjson tickets "$new_tickets" '.players[$giver].tickets = $tickets')
    
    local time_str="$(date '+%Y-%m-%d %H:%M:%S')"
    data=$(echo "$data" | jq --arg giver "$giver" --arg target "$target" \
        --arg type "$type" --argjson cost "$cost" --arg time "$time_str" \
        '.transactions += [{"giver": $giver, "recipient": $target, "type": "rank_gift", "rank": $type, "tickets": -$cost, "time": $time}]')
    
    write_json "$ECONOMY" "$data"
    
    add_auth "$target" "$type"
    screen -S "$SCREEN_SERVER" -X stuff "/$type $target$(printf \\r)"
    
    ρ "Congratulations! $giver has gifted $type rank to $target for $cost tickets."
    ρ "$giver, your new ticket balance: $new_tickets"
    return 0
}

process_msg() {
    local ς="$1" msg="$2"
    
    ! κ "$ς" && θ "Skipping message processing for invalid player name: '$ς'" && return
    
    local data=$(read_json "$ECONOMY")
    local tickets=$(echo "$data" | jq -r --arg ς "$ς" '.players[$ς].tickets // 0')
    tickets=${tickets:-0}
    
    case "$msg" in
        "!tickets"|"ltickets")
            ρ "$ς, you have $tickets tickets."
            ;;
        "!buy_mod")
            if has_purchased "$ς" "mod" || in_list "$ς" "mod"; then
                ρ "$ς, you already have MOD rank. No need to purchase again."
            elif [[ $tickets -ge 50 ]]; then
                local new_tickets=$((tickets - 50))
                data=$(echo "$data" | jq --arg ς "$ς" --argjson tickets "$new_tickets" '.players[$ς].tickets = $tickets')
                add_purchase "$ς" "mod"
                local time_str="$(date '+%Y-%m-%d %H:%M:%S')"
                data=$(echo "$data" | jq --arg ς "$ς" --arg time "$time_str" \
                    '.transactions += [{"player": $ς, "type": "purchase", "item": "mod", "tickets": -50, "time": $time}]')
                write_json "$ECONOMY" "$data"
                
                add_auth "$ς" "mod"
                screen -S "$SCREEN_SERVER" -X stuff "/mod $ς$(printf \\r)"
                ρ "Congratulations $ς! You have been promoted to MOD for 50 tickets. Remaining tickets: $new_tickets"
            else
                ρ "$ς, you need $((50 - tickets)) more tickets to buy MOD rank."
            fi
            ;;
        "!buy_admin")
            if has_purchased "$ς" "admin" || in_list "$ς" "admin"; then
                ρ "$ς, you already have ADMIN rank. No need to purchase again."
            elif [[ $tickets -ge 100 ]]; then
                local new_tickets=$((tickets - 100))
                data=$(echo "$data" | jq --arg ς "$ς" --argjson tickets "$new_tickets" '.players[$ς].tickets = $tickets')
                add_purchase "$ς" "admin"
                local time_str="$(date '+%Y-%m-%d %H:%M:%S')"
                data=$(echo "$data" | jq --arg ς "$ς" --arg time "$time_str" \
                    '.transactions += [{"player": $ς, "type": "purchase", "item": "admin", "tickets": -100, "time": $time}]')
                write_json "$ECONOMY" "$data"
                
                add_auth "$ς" "admin"
                screen -S "$SCREEN_SERVER" -X stuff "/admin $ς$(printf \\r)"
                ρ "Congratulations $ς! You have been promoted to ADMIN for 100 tickets. Remaining tickets: $new_tickets"
            else
                ρ "$ς, you need $((100 - tickets)) more tickets to buy ADMIN rank."
            fi
            ;;
        "!give_admin "*)
            [[ "$msg" =~ !give_admin\ ([a-zA-Z0-9_]+) ]] && give_rank "$ς" "${BASH_REMATCH[1]}" "admin" ||
            ρ "Usage: !give_admin PLAYER_NAME"
            ;;
        "!give_mod "*)
            [[ "$msg" =~ !give_mod\ ([a-zA-Z0-9_]+) ]] && give_rank "$ς" "${BASH_REMATCH[1]}" "mod" ||
            ρ "Usage: !give_mod PLAYER_NAME"
            ;;
        "!set_admin"|"!set_mod")
            ρ "$ς, these commands are only available to server console operators."
            ;;
        "!help")
            ρ "Available commands:"
            ρ "!tickets - Check your tickets"
            ρ "!buy_mod - Buy MOD rank for 50 tickets"
            ρ "!buy_admin - Buy ADMIN rank for 100 tickets"
            ρ "!give_mod PLAYER - Gift MOD rank (70 tickets)"
            ρ "!give_admin PLAYER - Gift ADMIN rank (140 tickets)"
            ;;
    esac
}

process_admin() {
    local cmd="$1" data=$(read_json "$ECONOMY")
    
    if [[ "$cmd" =~ ^!send_ticket\ ([a-zA-Z0-9_]+)\ ([0-9]+)$ ]]; then
        local ς="${BASH_REMATCH[1]}" amount="${BASH_REMATCH[2]}"
        
        ! κ "$ς" && ω "Invalid player name: $ς" && return 1
        
        [[ ! "$amount" =~ ^[0-9]+$ ]] || [[ $amount -le 0 ]] && ω "Invalid ticket amount: $amount" && return 1
        
        local exists=$(echo "$data" | jq --arg ς "$ς" '.players | has($ς)')
        [[ "$exists" = "false" ]] && ω "Player $ς not found in economy system" && return 1
        
        local current_tickets=$(echo "$data" | jq -r --arg ς "$ς" '.players[$ς].tickets // 0')
        current_tickets=${current_tickets:-0}
        local new_tickets=$((current_tickets + amount))
        
        data=$(echo "$data" | jq --arg ς "$ς" \
            --argjson tickets "$new_tickets" --arg time_str "$(date '+%Y-%m-%d %H:%M:%S')" \
            --argjson amount "$amount" \
            '.players[$ς].tickets = $tickets |
             .transactions += [{"player": $ς, "type": "admin_gift", "tickets": $amount, "time": $time_str}]')
        
        write_json "$ECONOMY" "$data"
        ο "Added $amount tickets to $ς (Total: $new_tickets)"
        ρ "$ς received $amount tickets from admin! Total: $new_tickets"
    elif [[ "$cmd" =~ ^!set_mod\ ([a-zA-Z0-9_]+)$ ]]; then
        local ς="${BASH_REMATCH[1]}"
        
        ! κ "$ς" && ω "Invalid player name: $ς" && return 1
        
        ο "Setting $ς as MOD"
        add_auth "$ς" "mod"
        screen -S "$SCREEN_SERVER" -X stuff "/mod $ς$(printf \\r)"
        ρ "$ς has been set as MOD by server console!"
    elif [[ "$cmd" =~ ^!set_admin\ ([a-zA-Z0-9_]+)$ ]]; then
        local ς="${BASH_REMATCH[1]}"
        
        ! κ "$ς" && ω "Invalid player name: $ς" && return 1
        
        ο "Setting $ς as ADMIN"
        add_auth "$ς" "admin"
        screen -S "$SCREEN_SERVER" -X stuff "/admin $ς$(printf \\r)"
        ρ "$ς has been set as ADMIN by server console!"
    else
        ω "Unknown admin command: $cmd"
        π "Available admin commands:"
        echo -e "!send_ticket <player> <amount>"
        echo -e "!set_mod <player> (console only)"
        echo -e "!set_admin <player> (console only)"
    fi
}

server_welcomed() {
    local ς="$1"
    [[ -z "$LOG_FILE" ]] || [[ ! -f "$LOG_FILE" ]] && return 1
    local ς_lc=$(echo "$ς" | tr '[:upper:]' '[:lower:]')
    
    tail -n 100 "$LOG_FILE" 2>/dev/null | grep -i "server:.*welcome.*$ς_lc" | head -1 | grep -q . && return 0
    
    local time=$(date +%s)
    local data=$(read_json "$ECONOMY")
    local last_welcome=$(echo "$data" | jq -r --arg ς "$ς" '.players[$ς].last_welcome_time // 0')
    
    [[ $last_welcome -gt 0 ]] && (( time - last_welcome <= 30 )) && return 0
    
    return 1
}

filter_log() {
    while read line; do
        [[ "$line" == *"Server closed"* || "$line" == *"Starting server"* || \
          ("$line" == *"SERVER: say"* && "$line" == *"Welcome"*) || \
          "$line" == *"adminlist.txt"* || "$line" == *"modlist.txt"* ]] && continue
        echo "$line"
    done
}

cleanup() {
    π "Cleaning up..."
    rm -f "$admin_pipe" 2>/dev/null
    kill $(jobs -p) 2>/dev/null
    rm -f "${ECONOMY}.lock" 2>/dev/null
    π "Cleanup done."
    exit 0
}

monitor() {
    local log="$1"
    LOG_FILE="$log"

    init_economy

    trap cleanup EXIT INT TERM

    υ "STARTING ECONOMY BOT"
    π "Monitoring: $log"
    π "Bot commands: !tickets, !buy_mod, !buy_admin, !give_mod, !give_admin, !help"
    π "Admin commands: !send_ticket <player> <amount>, !set_mod <player>, !set_admin <player>"
    υ "IMPORTANT: Admin commands must be typed in THIS terminal, NOT in the game chat!"
    π "Type admin commands below and press Enter:"
    υ "READY FOR COMMANDS"

    local admin_pipe="/tmp/blockheads_admin_pipe_$$"
    rm -f "$admin_pipe"
    mkfifo "$admin_pipe"

    while read -r cmd < "$admin_pipe"; do
        π "Processing admin command: $cmd"
        if [[ "$cmd" == "!send_ticket "* || "$cmd" == "!set_mod "* || "$cmd" == "!set_admin "* ]]; then
            process_admin "$cmd"
        else
            ω "Unknown admin command. Use: !send_ticket <player> <amount>, !set_mod <player>, or !set_admin <player>"
        fi
        υ "READY FOR NEXT COMMAND"
    done &

    while read -r cmd; do
        echo "$cmd" > "$admin_pipe"
    done &

    declare -A welcome_shown

    tail -n 0 -F "$log" 2>/dev/null | filter_log | while read line; do
        if [[ "$line" =~ Player\ Connected\ (.+)\ \|\ ([0-9a-fA-F.:]+)\ \|\ ([0-9a-f]+) ]]; then
            local ς="${BASH_REMATCH[1]}" ι="${BASH_REMATCH[2]}" ο="${BASH_REMATCH[3]}"
            [[ "$ς" == "SERVER" ]] && continue

            ! κ "$ς" && θ "Skipping invalid player name: '$ς' (IP: $ι)" && continue

            ο "Player connected: $ς (IP: $ι)"

            local ts_str=$(echo "$line" | awk '{print $1" "$2}')
            local ts_no_ms=${ts_str%.*}
            local conn_epoch=$(date -d "$ts_no_ms" +%s 2>/dev/null || echo 0)

            local is_new="false"
            add_player "$ς" && is_new="true"

            sleep 3

            ! server_welcomed "$ς" && welcome "$ς" "$is_new" 1 || θ "Server already welcomed $ς"

            [[ "$is_new" = "false" ]] && grant_ticket "$ς"
            continue
        fi

        if [[ "$line" =~ Player\ Disconnected\ ([a-zA-Z0-9_]+) ]]; then
            local ς="${BASH_REMATCH[1]}"
            [[ "$ς" == "SERVER" ]] && continue
            
            ! κ "$ς" && θ "Skipping invalid player name: '$ς'" && continue
            
            θ "Player disconnected: $ς"
            unset welcome_shown["$ς"]
            continue
        fi

        if [[ "$line" =~ ([a-zA-Z0-9_]+):\ (.+)$ ]]; then
            local ς="${BASH_REMATCH[1]}" msg="${BASH_REMATCH[2]}"
            [[ "$ς" == "SERVER" ]] && continue
            
            ! κ "$ς" && θ "Skipping message from invalid player name: '$ς'" && continue
            
            π "Chat: $ς: $msg"
            add_player "$ς"
            process_msg "$ς" "$msg"
            continue
        fi

        π "Other log line: $line"
    done

    wait
    rm -f "$admin_pipe"
}

show_usage() {
    υ "ECONOMY BOT - USAGE"
    π "This script manages the server economy and player commands"
    π "Usage: $0 <server_log_file> [port]"
    π "Example: $0 /path/to/console.log 12153"
    echo ""
    θ "Note: This script should be run alongside the server"
    θ "It will automatically handle player commands and economy"
}

if [[ $# -eq 1 || $# -eq 2 ]]; then
    init_economy
    monitor "$1"
else
    show_usage
    exit 1
fi
