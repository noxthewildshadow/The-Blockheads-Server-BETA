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
step() { echo -e "${χ3}[STEP]${χ3} $1"; }

SERVER="./blockheads_server171"
PORT=12153

screen_exists() {
    screen -list 2>/dev/null | grep -q "$1"
}

show_usage() {
    υ "THE BLOCKHEADS SERVER MANAGER"
    π "Usage: $0 [command]"
    echo ""
    π "Available commands:"
    echo -e "  ${χ1}start${χ3} [WORLD_NAME] [PORT] - Start server, bot and anticheat"
    echo -e "  ${χ0}stop${χ3} [PORT]                - Stop server, bot and anticheat"
    echo -e "  ${χ3}status${χ3} [PORT]              - Show server status"
    echo -e "  ${χ2}list${χ3}                     - List all running servers"
    echo -e "  ${χ2}help${χ3}                      - Show this help"
    echo ""
    π "Examples:"
    echo -e "  ${χ1}$0 start MyWorld 12153${χ3}"
    echo -e "  ${χ1}$0 start MyWorld${χ3}        (uses default port $PORT)"
    echo -e "  ${χ0}$0 stop${χ3}                   (stops all servers)"
    echo -e "  ${χ0}$0 stop 12153${χ3}            (stops server on port 12153)"
    echo -e "  ${χ3}$0 status${χ3}                (shows status of all servers)"
    echo -e "  ${χ3}$0 status 12153${χ3}         (shows status of server on port 12153)"
    echo -e "  ${χ2}$0 list${χ3}                 (lists all running servers)"
    echo ""
    θ "Note: First create a world manually with:"
    echo -e "  ${χ1}./blockheads_server171 -n${χ3}"
    echo ""
    θ "After creating the world, press ${χ2}CTRL+C${χ3} to exit"
    θ "and then start the server with the start command."
    υ "END OF HELP"
}

port_in_use() {
    lsof -Pi ":$1" -sTCP:LISTEN -t >/dev/null
}

free_port() {
    local port="$1"
    θ "Freeing port $port..."
    local pids=$(lsof -ti ":$port")
    [[ -n "$pids" ]] && kill -9 $pids 2>/dev/null
    
    local screen_server="blockheads_server_$port"
    local screen_bot="blockheads_bot_$port"
    local screen_anticheat="blockheads_anticheat_$port"
    
    screen_exists "$screen_server" && screen -S "$screen_server" -X quit 2>/dev/null
    screen_exists "$screen_bot" && screen -S "$screen_bot" -X quit 2>/dev/null
    screen_exists "$screen_anticheat" && screen -S "$screen_anticheat" -X quit 2>/dev/null
    
    sleep 2
    ! port_in_use "$port"
}

check_world() {
    local world="$1"
    local saves="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves"
    [[ -d "$saves/$world" ]] || {
        ω "World '$world' does not exist in: $saves/"
        echo ""
        θ "To create a world, run: ${χ1}./blockheads_server171 -n${χ3}"
        θ "After creating the world, press ${χ2}CTRL+C${χ3} to exit"
        θ "and then start the server with: ${χ1}$0 start $world $port${χ3}"
        return 1
    }
    return 0
}

start_server() {
    local world="$1"
    local port="${2:-$PORT}"

    local screen_server="blockheads_server_$port"
    local screen_bot="blockheads_bot_$port"
    local screen_anticheat="blockheads_anticheat_$port"

    [[ ! -f "$SERVER" ]] && ω "Server binary not found: $SERVER" && 
    θ "Run the installer first: ${χ1}./installer.sh${χ3}" && return 1

    check_world "$world" || return 1

    if port_in_use "$port"; then
        θ "Port $port is in use."
        free_port "$port" || {
            ω "Could not free port $port"
            θ "Use a different port or terminate the process using it"
            return 1
        }
    fi

    screen_exists "$screen_server" && screen -S "$screen_server" -X quit 2>/dev/null
    screen_exists "$screen_bot" && screen -S "$screen_bot" -X quit 2>/dev/null
    screen_exists "$screen_anticheat" && screen -S "$screen_anticheat" -X quit 2>/dev/null
    
    sleep 1

    local log_dir="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves/$world"
    local log_file="$log_dir/console.log"
    mkdir -p "$log_dir"

    step "Starting server - World: $world, Port: $port"
    echo "$world" > "world_id_$port.txt"

    cat > /tmp/start_server_$$.sh << EOF
#!/bin/bash
cd '$PWD'
while true; do
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Starting server..."
    if ./blockheads_server171 -o '$world' -p $port 2>&1 | tee -a '$log_file'; then
        echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Server closed normally"
    else
        code=\$?
        echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Server failed with code: \$code"
        if [[ \$code -eq 1 ]] && tail -n 5 '$log_file' | grep -q "port.*already in use"; then
            echo "[\$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Port already in use. Will not retry."
            break
        fi
    fi
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Restarting in 5 seconds..."
    sleep 5
done
EOF

    chmod +x /tmp/start_server_$$.sh
    screen -dmS "$screen_server" /tmp/start_server_$$.sh
    (sleep 10; rm -f /tmp/start_server_$$.sh) &

    step "Waiting for server to start..."
    local wait_time=0
    while [[ ! -f "$log_file" && $wait_time -lt 15 ]]; do
        sleep 1
        ((wait_time++))
    done

    [[ ! -f "$log_file" ]] && ω "Could not create log file. Server may not have started." && return 1

    local ready=false
    for i in {1..30}; do
        if grep -q "World load complete\|Server started\|Ready for connections\|using seed:\|save delay:" "$log_file"; then
            ready=true
            break
        fi
        sleep 1
    done

    if ! $ready; then
        θ "Server did not show complete startup messages, but continuing..."
        screen_exists "$screen_server" && ο "Server screen session is active. Continuing..." ||
        ω "Server screen session not found. Server may have failed to start." && return 1
    else
        ο "Server started successfully!"
    fi

    step "Starting server bot..."
    screen -dmS "$screen_bot" bash -c "
        cd '$PWD'
        echo 'Starting server bot for port $port...'
        ./server_bot.sh '$log_file' '$port'
    "

    step "Starting anticheat security system..."
    screen -dmS "$screen_anticheat" bash -c "
        cd '$PWD'
        echo 'Starting anticheat for port $port...'
        ./anticheat_secure.sh '$log_file' '$port'
    "

    local server_started=0 bot_started=0 anticheat_started=0
    
    screen_exists "$screen_server" && server_started=1
    screen_exists "$screen_bot" && bot_started=1
    screen_exists "$screen_anticheat" && anticheat_started=1
    
    if [[ $server_started -eq 1 && $bot_started -eq 1 && $anticheat_started -eq 1 ]]; then
        υ "SERVER, BOT AND ANTICHEAT STARTED SUCCESSFULLY!"
        ο "World: $world"
        ο "Port: $port"
        echo ""
        π "To view server console: ${χ3}screen -r $screen_server${χ3}"
        π "To view bot: ${χ3}screen -r $screen_bot${χ3}"
        π "To view anticheat: ${χ3}screen -r $screen_anticheat${χ3}"
        echo ""
        θ "To exit console without stopping server: ${χ2}CTRL+A, D${χ3}"
        υ "SERVER IS NOW RUNNING"
    else
        θ "Could not verify all screen sessions"
        π "Server started: $server_started, Bot started: $bot_started, Anticheat started: $anticheat_started"
        θ "Use 'screen -list' to view active sessions"
    fi
}

stop_server() {
    local port="$1"
    
    if [[ -z "$port" ]]; then
        step "Stopping all servers, bots and anticheat..."
        
        for session in $(screen -list | grep "blockheads_server_" | awk '{print $1}'); do
            screen -S "${session}" -X quit 2>/dev/null
            ο "Stopped server: ${session}"
        done
        
        for session in $(screen -list | grep "blockheads_bot_" | awk '{print $1}'); do
            screen -S "${session}" -X quit 2>/dev/null
            ο "Stopped bot: ${session}"
        done
        
        for session in $(screen -list | grep "blockheads_anticheat_" | awk '{print $1}'); do
            screen -S "${session}" -X quit 2>/dev/null
            ο "Stopped anticheat: ${session}"
        done
        
        pkill -f "$SERVER" 2>/dev/null || true
        ο "Cleanup completed for all servers."
    else
        step "Stopping server, bot and anticheat on port $port..."
        
        local screen_server="blockheads_server_$port"
        local screen_bot="blockheads_bot_$port"
        local screen_anticheat="blockheads_anticheat_$port"
        
        screen_exists "$screen_server" && screen -S "$screen_server" -X quit 2>/dev/null && ο "Server stopped on port $port." ||
        θ "Server was not running on port $port."
        
        screen_exists "$screen_bot" && screen -S "$screen_bot" -X quit 2>/dev/null && ο "Bot stopped on port $port." ||
        θ "Bot was not running on port $port."
        
        screen_exists "$screen_anticheat" && screen -S "$screen_anticheat" -X quit 2>/dev/null && ο "Anticheat stopped on port $port." ||
        θ "Anticheat was not running on port $port."
        
        pkill -f "$SERVER.*$port" 2>/dev/null || true
        ο "Cleanup completed for port $port."
    fi
}

list_servers() {
    υ "LIST OF RUNNING SERVERS"
    
    local servers=$(screen -list | grep "blockheads_server_" | awk '{print $1}' | sed 's/\.blockheads_server_/ - Port: /')
    
    if [[ -z "$servers" ]]; then
        θ "No servers are currently running."
    else
        π "Running servers:"
        while IFS= read -r server; do
            π "  $server"
        done <<< "$servers"
    fi
    
    υ "END OF LIST"
}

show_status() {
    local port="$1"
    
    if [[ -z "$port" ]]; then
        υ "THE BLOCKHEADS SERVER STATUS - ALL SERVERS"
        
        local servers=$(screen -list | grep "blockheads_server_" | awk '{print $1}' | sed 's/\.blockheads_server_//')
        
        if [[ -z "$servers" ]]; then
            ω "No servers are currently running."
        else
            while IFS= read -r p; do
                screen_exists "blockheads_server_$p" && ο "Server on port $p: RUNNING" || ω "Server on port $p: STOPPED"
                screen_exists "blockheads_bot_$p" && ο "Bot on port $p: RUNNING" || ω "Bot on port $p: STOPPED"
                screen_exists "blockheads_anticheat_$p" && ο "Anticheat on port $p: RUNNING" || ω "Anticheat on port $p: STOPPED"
                
                [[ -f "world_id_$p.txt" ]] && local world=$(cat "world_id_$p.txt" 2>/dev/null) && π "World for port $p: ${χ3}$world${χ3}"
                echo ""
            done <<< "$servers"
        fi
    else
        υ "THE BLOCKHEADS SERVER STATUS - PORT $port"
        
        screen_exists "blockheads_server_$port" && ο "Server: RUNNING" || ω "Server: STOPPED"
        screen_exists "blockheads_bot_$port" && ο "Bot: RUNNING" || ω "Bot: STOPPED"
        screen_exists "blockheads_anticheat_$port" && ο "Anticheat: RUNNING" || ω "Anticheat: STOPPED"
        
        if [[ -f "world_id_$port.txt" ]]; then
            local world=$(cat "world_id_$port.txt" 2>/dev/null)
            π "Current world: ${χ3}$world${χ3}"
            
            screen_exists "blockheads_server_$port" && 
            π "To view console: ${χ3}screen -r blockheads_server_$port${χ3}" &&
            π "To view bot: ${χ3}screen -r blockheads_bot_$port${χ3}" &&
            π "To view anticheat: ${χ3}screen -r blockheads_anticheat_$port${χ3}"
        else
            θ "World: Not configured for port $port (run 'start' first)"
        fi
    fi
    
    υ "END OF STATUS"
}

case "$1" in
    start)
        [[ -z "$2" ]] && ω "You must specify a WORLD_NAME" && show_usage && exit 1
        start_server "$2" "$3"
        ;;
    stop)
        stop_server "$2"
        ;;
    status)
        show_status "$2"
        ;;
    list)
        list_servers
        ;;
    help|--help|-h|*)
        show_usage
        ;;
esac
