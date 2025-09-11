#!/bin/bash

# =============================================================================
# THE BLOCKHEADS SERVER ECONOMY BOT
# =============================================================================

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

# Function definitions
print_status() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_header() {
    echo -e "${PURPLE}================================================================"
    echo -e "$1"
    echo -e "===============================================================${NC}"
}
print_step() { echo -e "${CYAN}[STEP]${NC} $1"; }

# Validate jq is installed
if ! command -v jq &> /dev/null; then
    echo -e "${RED}ERROR: jq is required but not installed. Please install jq first.${NC}"
    exit 1
fi

# Function to extract real player name from ID-prefixed format
extract_real_name() {
    local name="$1"
    # Remove any numeric prefix with bracket (e.g., "12345] ")
    if [[ "$name" =~ ^[0-9]+\]\ (.+)$ ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo "$name"
    fi
}

# Function to validate player names
is_valid_player_name() {
    local player_name=$(echo "$1" | xargs)
    [[ "$player_name" =~ ^[a-zA-Z0-9_]+$ ]]
}

# Initialize variables
[ $# -ge 2 ] && PORT="$2" || PORT="12153"
LOG_DIR=$(dirname "$1")
SCREEN_SERVER="blockheads_server_$PORT"
PLAYERS_LOG="$LOG_DIR/players.log"

# Function to get player info from players.log
get_player_info() {
    local player_name="$1"
    if [ -f "$PLAYERS_LOG" ]; then
        while IFS='|' read -r name ip rank password bans tickets; do
            if [ "$name" = "$player_name" ]; then
                echo "$ip|$rank|$password|$bans|$tickets"
                return 0
            fi
        done < <(grep -i "^$player_name|" "$PLAYERS_LOG")
    fi
    echo ""
}

# Function to update player info in players.log
update_player_info() {
    local player_name="$1" player_ip="$2" player_rank="$3" player_password="$4" player_bans="$5" player_tickets="$6"
    if [ -f "$PLAYERS_LOG" ]; then
        # Remove existing entry
        sed -i "/^$player_name|/Id" "$PLAYERS_LOG"
        # Add new entry with all fields
        echo "$player_name|$player_ip|$player_rank|$player_password|$player_bans|$player_tickets" >> "$PLAYERS_LOG"
        print_success "Updated player info in registry: $player_name -> IP: $player_ip, Rank: $player_rank, Password: $player_password, Bans: $player_bans, Tickets: $player_tickets"
    fi
}

# Function to get player rank from players.log
get_player_rank() {
    local player_name="$1"
    local player_info=$(get_player_info "$player_name")
    if [ -n "$player_info" ]; then
        local rank=$(echo "$player_info" | cut -d'|' -f2)
        echo "$rank"
    else
        echo "NONE"
    fi
}

# Function to get player tickets from players.log
get_player_tickets() {
    local player_name="$1"
    local player_info=$(get_player_info "$player_name")
    if [ -n "$player_info" ]; then
        local tickets=$(echo "$player_info" | cut -d'|' -f6)
        echo "${tickets:-0}"
    else
        echo "0"
    fi
}

# Function to update player tickets in players.log
update_player_tickets() {
    local player_name="$1" new_tickets="$2"
    local player_info=$(get_player_info "$player_name")
    if [ -n "$player_info" ]; then
        local registered_ip=$(echo "$player_info" | cut -d'|' -f1)
        local registered_rank=$(echo "$player_info" | cut -d'|' -f2)
        local registered_password=$(echo "$player_info" | cut -d'|' -f3)
        local registered_bans=$(echo "$player_info" | cut -d'|' -f4)
        update_player_info "$player_name" "$registered_ip" "$registered_rank" "$registered_password" "$registered_bans" "$new_tickets"
    fi
}

# Function to add player if new
add_player_if_new() {
    local player_name="$1" player_ip="$2"
    ! is_valid_player_name "$player_name" && return 1
    
    local player_info=$(get_player_info "$player_name")
    
    [ -z "$player_info" ] && {
        update_player_info "$player_name" "$player_ip" "NONE" "NONE" "NONE" "0"
        give_first_time_bonus "$player_name"
        return 0
    }
    return 1
}

# Function to give first time bonus
give_first_time_bonus() {
    local player_name="$1" time_str="$(date '+%Y-%m-%d %H:%M:%S')"
    local current_tickets=$(get_player_tickets "$player_name")
    local new_tickets=$((current_tickets + 1))
    update_player_tickets "$player_name" "$new_tickets"
    send_server_command "$player_name, welcome to the server! You received 1 ticket as a welcome bonus."
    print_success "Granted welcome bonus to $player_name (Total: $new_tickets)"
}

# Function to grant login ticket
grant_login_ticket() {
    local player_name="$1" current_time=$(date +%s)
    local player_info=$(get_player_info "$player_name")
    
    if [ -n "$player_info" ]; then
        local last_login=0
        # For now, we'll just give a ticket without checking last login time
        local current_tickets=$(get_player_tickets "$player_name")
        local new_tickets=$((current_tickets + 1))
        
        update_player_tickets "$player_name" "$new_tickets"
        print_success "Granted 1 ticket to $player_name (Total: $new_tickets)"
        send_server_command "$player_name, you received 1 ticket for logging in! Total tickets: $new_tickets"
    fi
}

# Function to show welcome message
show_welcome_message() {
    local player_name="$1" is_new_player="$2" force_send="${3:-0}"
    ! is_valid_player_name "$player_name" && return
    
    if [ "$is_new_player" = "true" ]; then
        send_server_command "Hello $player_name! Welcome to the server. Type !help to check available commands."
    else
        send_server_command "Welcome back $player_name! Type !help to see available commands."
    fi
}

# Function to send server command
send_server_command() {
    if screen -S "$SCREEN_SERVER" -p 0 -X stuff "$1$(printf \\r)" 2>/dev/null; then
        print_success "Sent message to server: $1"
        return 0
    else
        print_error "Could not send message to server"
        return 1
    fi
}

# Function to check if player has purchased an item
has_purchased() {
    local player_name="$1" item="$2"
    local player_info=$(get_player_info "$player_name")
    if [ -n "$player_info" ]; then
        local rank=$(echo "$player_info" | cut -d'|' -f2)
        if [ "$item" = "mod" ] && [ "$rank" = "mod" ]; then
            return 0
        elif [ "$item" = "admin" ] && [ "$rank" = "admin" ]; then
            return 0
        fi
    fi
    return 1
}

# Function to process give rank command
process_give_rank() {
    local giver_name="$1" target_player="$2" rank_type="$3"
    local giver_tickets=$(get_player_tickets "$giver_name")
    
    local cost=0
    [ "$rank_type" = "admin" ] && cost=140
    [ "$rank_type" = "mod" ] && cost=70
    
    [ "$giver_tickets" -lt "$cost" ] && {
        send_server_command "$giver_name, you need $cost tickets to give $rank_type rank, but you only have $giver_tickets."
        return 1
    }
    
    ! is_valid_player_name "$target_player" && {
        send_server_command "$giver_name, invalid player name: $target_player"
        return 1
    }
    
    local new_tickets=$((giver_tickets - cost))
    update_player_tickets "$giver_name" "$new_tickets"
    
    # Update target player's rank
    local target_info=$(get_player_info "$target_player")
    if [ -n "$target_info" ]; then
        local target_ip=$(echo "$target_info" | cut -d'|' -f1)
        local target_password=$(echo "$target_info" | cut -d'|' -f3)
        local target_bans=$(echo "$target_info" | cut -d'|' -f4)
        local target_tickets=$(echo "$target_info" | cut -d'|' -f5)
        update_player_info "$target_player" "$target_ip" "$rank_type" "$target_password" "$target_bans" "$target_tickets"
    else
        # If target doesn't exist in players.log, create entry
        local target_ip=$(get_ip_by_name "$target_player")
        update_player_info "$target_player" "$target_ip" "$rank_type" "NONE" "NONE" "0"
    fi
    
    # Update server ranks
    screen -S "$SCREEN_SERVER" -p 0 -X stuff "/$rank_type $target_player$(printf \\r)"
    
    send_server_command "Congratulations! $giver_name has gifted $rank_type rank to $target_player for $cost tickets."
    send_server_command "$giver_name, your new ticket balance: $new_tickets"
    return 0
}

# Function to process message
process_message() {
    local player_name="$1" message="$2"
    ! is_valid_player_name "$player_name" && return
    
    local player_tickets=$(get_player_tickets "$player_name")
    
    case "$message" in
        "!tickets"|"ltickets")
            send_server_command "$player_name, you have $player_tickets tickets."
            ;;
        "!buy_mod")
            (has_purchased "$player_name" "mod") && {
                send_server_command "$player_name, you already have MOD rank."
            } || [ "$player_tickets" -ge 50 ] && {
                local new_tickets=$((player_tickets - 50))
                update_player_tickets "$player_name" "$new_tickets"
                
                # Update player rank
                local player_info=$(get_player_info "$player_name")
                local registered_ip=$(echo "$player_info" | cut -d'|' -f1)
                local registered_password=$(echo "$player_info" | cut -d'|' -f3)
                local registered_bans=$(echo "$player_info" | cut -d'|' -f4)
                update_player_info "$player_name" "$registered_ip" "mod" "$registered_password" "$registered_bans" "$new_tickets"
                
                # Update server
                screen -S "$SCREEN_SERVER" -p 0 -X stuff "/mod $player_name$(printf \\r)"
                send_server_command "Congratulations $player_name! You have been promoted to MOD for 50 tickets. Remaining tickets: $new_tickets"
            } || send_server_command "$player_name, you need $((50 - player_tickets)) more tickets to buy MOD rank."
            ;;
        "!buy_admin")
            (has_purchased "$player_name" "admin") && {
                send_server_command "$player_name, you already have ADMIN rank."
            } || [ "$player_tickets" -ge 100 ] && {
                local new_tickets=$((player_tickets - 100))
                update_player_tickets "$player_name" "$new_tickets"
                
                # Update player rank
                local player_info=$(get_player_info "$player_name")
                local registered_ip=$(echo "$player_info" | cut -d'|' -f1)
                local registered_password=$(echo "$player_info" | cut -d'|' -f3)
                local registered_bans=$(echo "$player_info" | cut -d'|' -f4)
                update_player_info "$player_name" "$registered_ip" "admin" "$registered_password" "$registered_bans" "$new_tickets"
                
                # Update server
                screen -S "$SCREEN_SERVER" -p 0 -X stuff "/admin $player_name$(printf \\r)"
                send_server_command "Congratulations $player_name! You have been promoted to ADMIN for 100 tickets. Remaining tickets: $new_tickets"
            } || send_server_command "$player_name, you need $((100 - player_tickets)) more tickets to buy ADMIN rank."
            ;;
        "!give_admin "*)
            [[ "$message" =~ !give_admin\ ([a-zA-Z0-9_]+) ]] && \
            process_give_rank "$player_name" "${BASH_REMATCH[1]}" "admin" || \
            send_server_command "Usage: !give_admin PLAYER_NAME"
            ;;
        "!give_mod "*)
            [[ "$message" =~ !give_mod\ ([a-zA-Z0-9_]+) ]] && \
            process_give_rank "$player_name" "${BASH_REMATCH[1]}" "mod" || \
            send_server_command "Usage: !give_mod PLAYER_NAME"
            ;;
        "!set_admin"|"!set_mod")
            send_server_command "$player_name, these commands are only available to server console operators."
            ;;
        "!help")
            send_server_command "Available commands:"
            send_server_command "!tickets - Check your tickets"
            send_server_command "!buy_mod - Buy MOD rank for 50 tickets"
            send_server_command "!buy_admin - Buy ADMIN rank for 100 tickets"
            send_server_command "!give_mod PLAYER - Gift MOD rank (70 tickets)"
            send_server_command "!give_admin PLAYER - Gift ADMIN rank (140 tickets)"
            ;;
    esac
}

# Function to process admin command
process_admin_command() {
    local command="$1"
    
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
        
        local current_tickets=$(get_player_tickets "$player_name")
        local new_tickets=$((current_tickets + tickets_to_add))
        
        update_player_tickets "$player_name" "$new_tickets"
        print_success "Added $tickets_to_add tickets to $player_name (Total: $new_tickets)"
        send_server_command "$player_name received $tickets_to_add tickets from admin! Total: $new_tickets"
    elif [[ "$command" =~ ^!set_mod\ ([a-zA-Z0-9_]+)$ ]]; then
        local player_name="${BASH_REMATCH[1]}"
        ! is_valid_player_name "$player_name" && print_error "Invalid player name: $player_name" && return 1
        
        print_success "Setting $player_name as MOD"
        # Update players.log
        local player_info=$(get_player_info "$player_name")
        if [ -n "$player_info" ]; then
            local registered_ip=$(echo "$player_info" | cut -d'|' -f1)
            local registered_password=$(echo "$player_info" | cut -d'|' -f3)
            local registered_bans=$(echo "$player_info" | cut -d'|' -f4)
            local registered_tickets=$(echo "$player_info" | cut -d'|' -f5)
            update_player_info "$player_name" "$registered_ip" "mod" "$registered_password" "$registered_bans" "$registered_tickets"
        else
            # If player doesn't exist in players.log, create entry
            local player_ip=$(get_ip_by_name "$player_name")
            update_player_info "$player_name" "$player_ip" "mod" "NONE" "NONE" "0"
        fi
        # Update server
        screen -S "$SCREEN_SERVER" -p 0 -X stuff "/mod $player_name$(printf \\r)"
        send_server_command "$player_name has been set as MOD by server console!"
    elif [[ "$command" =~ ^!set_admin\ ([a-zA-Z0-9_]+)$ ]]; then
        local player_name="${BASH_REMATCH[1]}"
        ! is_valid_player_name "$player_name" && print_error "Invalid player name: $player_name" && return 1
        
        print_success "Setting $player_name as ADMIN"
        # Update players.log
        local player_info=$(get_player_info "$player_name")
        if [ -n "$player_info" ]; then
            local registered_ip=$(echo "$player_info" | cut -d'|' -f1)
            local registered_password=$(echo "$player_info" | cut -d'|' -f3)
            local registered_bans=$(echo "$player_info" | cut -d'|' -f4)
            local registered_tickets=$(echo "$player_info" | cut -d'|' -f5)
            update_player_info "$player_name" "$registered_ip" "admin" "$registered_password" "$registered_bans" "$registered_tickets"
        else
            # If player doesn't exist in players.log, create entry
            local player_ip=$(get_ip_by_name "$player_name")
            update_player_info "$player_name" "$player_ip" "admin" "NONE" "NONE" "0"
        fi
        # Update server
        screen -S "$SCREEN_SERVER" -p 0 -X stuff "/admin $player_name$(printf \\r)"
        send_server_command "$player_name has been set as ADMIN by server console!"
    else
        print_error "Unknown admin command: $command"
    fi
}

# Function to get IP by name
get_ip_by_name() {
    local name="$1" log_file="$2"
    if [ -z "$log_file" ] || [ ! -f "$log_file" ]; then
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
    ' "$log_file"
}

# Function to check if server sent welcome recently
server_sent_welcome_recently() {
    local player_name="$1" log_file="$2"
    [ -z "$log_file" ] || [ ! -f "$log_file" ] && return 1
    local player_lc=$(echo "$player_name" | tr '[:upper:]' '[:lower:]')
    
    tail -n 100 "$log_file" 2>/dev/null | grep -i "server:.*welcome.*$player_lc" | head -1 | grep -q . && return 0
    
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

# Function to cleanup
cleanup() {
    print_status "Cleaning up..."
    rm -f "$admin_pipe" 2>/dev/null
    kill $(jobs -p) 2>/dev/null
    exit 0
}

# Function to monitor log
monitor_log() {
    local log_file="$1"
    LOG_FILE="$log_file"

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

            sleep 3

            ! server_sent_welcome_recently "$player_name" "$log_file" && \
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
            add_player_if_new "$player_name" "$player_ip"
            process_message "$player_name" "$message"
            continue
        fi

        # Skip other log lines to avoid spam
        # print_status "Other log line: $line"
    done

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
    monitor_log "$1"
else
    show_usage
    exit 1
fi
