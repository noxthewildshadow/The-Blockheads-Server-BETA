#!/bin/bash
# =============================================================================
# THE BLOCKHEADS SERVER MANAGER (MODIFIED: backups, LD_PRELOAD patching, systemd)
# =============================================================================

# Load common functions
source blockheads_common.sh

# Determine original installer user (used for systemd User= and chown)
ORIGINAL_USER=${SUDO_USER:-$USER}
INSTALL_DIR="$(pwd)"

# Server binary and default port
SERVER_BINARY="./blockheads_server171"
DEFAULT_PORT=12153
PATCH_SO="./libfreightpatch.so"
WRAPPER="./run_server_with_patch.sh"
BACKUP_BINARY="./blockheads_server171.orig"

# Ensure wrapper exists (create a conservative wrapper if absent)
ensure_wrapper() {
    if [ -x "$WRAPPER" ]; then
        return 0
    fi

    cat > "$WRAPPER" <<'EOF'
#!/bin/bash
# wrapper to run server with LD_PRELOAD if lib is present
cd "$(pwd)"
SO_PATH="$(pwd)/libfreightpatch.so"
if [ -f "$SO_PATH" ]; then
    export LD_PRELOAD="$SO_PATH${LD_PRELOAD:+:$LD_PRELOAD}"
fi
exec ./blockheads_server171 "$@"
EOF

    chmod +x "$WRAPPER"
    print_success "Created wrapper: $WRAPPER"
}

# Function to create backup of the binary if not exists
create_backup_if_missing() {
    if [ -f "$SERVER_BINARY" ] && [ ! -f "$BACKUP_BINARY" ]; then
        cp -a "$SERVER_BINARY" "$BACKUP_BINARY" 2>/dev/null || cp "$SERVER_BINARY" "$BACKUP_BINARY"
        chmod 755 "$BACKUP_BINARY" 2>/dev/null || true
        chown "$ORIGINAL_USER:$ORIGINAL_USER" "$BACKUP_BINARY" 2>/dev/null || true
        print_success "Backup created: $BACKUP_BINARY"
    fi
}

# Function to install a systemd service for a specific world and port
install_service() {
    local world_id="$1"
    local port="${2:-$DEFAULT_PORT}"

    if [ -z "$world_id" ]; then
        print_error "You must specify a WORLD_NAME to install the service."
        return 1
    fi

    # Ensure wrapper exists
    ensure_wrapper

    local abs_dir
    abs_dir="$(pwd)"
    local unit_name="blockheads_${port}.service"
    local unit_path="/etc/systemd/system/${unit_name}"

    # Create systemd unit (requires root to write to /etc/systemd/system)
    cat > /tmp/${unit_name} <<EOF
[Unit]
Description=Blockheads server for ${world_id} on port ${port}
After=network.target

[Service]
Type=simple
WorkingDirectory=${abs_dir}
User=${ORIGINAL_USER}
Environment=LD_PRELOAD=${abs_dir}/libfreightpatch.so
ExecStart=${abs_dir}/run_server_with_patch.sh -o '${world_id}' -p ${port}
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

    # Move into place (use sudo if needed)
    if [ "$EUID" -ne 0 ]; then
        print_step "Writing systemd unit as root via sudo: ${unit_name}"
        sudo mv /tmp/${unit_name} "$unit_path" || { print_error "Failed to write $unit_path (sudo failed)"; rm -f /tmp/${unit_name}; return 1; }
        sudo systemctl daemon-reload || { print_error "systemctl daemon-reload failed"; return 1; }
        sudo systemctl enable --now "$unit_name" || { print_warning "Failed to enable/start $unit_name via sudo"; }
    else
        mv /tmp/${unit_name} "$unit_path" || { print_error "Failed to write $unit_path"; rm -f /tmp/${unit_name}; return 1; }
        systemctl daemon-reload || { print_error "systemctl daemon-reload failed"; return 1; }
        systemctl enable --now "$unit_name" || { print_warning "Failed to enable/start $unit_name"; }
    fi

    print_success "Systemd service installed and (attempted) started: $unit_name"
    print_status "To check status: sudo systemctl status $unit_name"
    return 0
}

# Function to check if world exists
check_world_exists() {
    local world_id="$1"
    local saves_dir="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves"
    [ -d "$saves_dir/$world_id" ] || {
        print_error "World '$world_id' does not exist in: $saves_dir/"
        echo ""
        print_warning "To create a world: ${GREEN}./blockheads_server171 -n${NC}"
        print_warning "After creating the world, press ${YELLOW}CTRL+C${NC} to exit"
        return 1
    }
    return 0
}

# Function to free port
free_port() {
    local port="$1"
    print_warning "Freeing port $port..."
    local pids
    pids=$(lsof -ti ":$port" 2>/dev/null || true)
    [ -n "$pids" ] && kill -9 $pids 2>/dev/null

    local screen_server="blockheads_server_$port"
    local screen_bot="blockheads_bot_$port"
    local screen_anticheat="blockheads_anticheat_$port"

    screen_session_exists "$screen_server" && screen -S "$screen_server" -X quit 2>/dev/null
    screen_session_exists "$screen_bot" && screen -S "$screen_bot" -X quit 2>/dev/null
    screen_session_exists "$screen_anticheat" && screen -S "$screen_anticheat" -X quit 2>/dev/null

    sleep 2
    ! is_port_in_use "$port"
}

# Function to start server
start_server() {
    local world_id="$1"
    local port="${2:-$DEFAULT_PORT}"

    local SCREEN_SERVER="blockheads_server_$port"
    local SCREEN_BOT="blockheads_bot_$port"
    local SCREEN_ANTICHEAT="blockheads_anticheat_$port"

    [ ! -f "$SERVER_BINARY" ] && {
        print_error "Server binary not found: $SERVER_BINARY"
        print_warning "Run the installer first: ${GREEN}./installer.sh${NC}"
        return 1
    }

    # Ensure backup exists before any run
    create_backup_if_missing

    check_world_exists "$world_id" || return 1

    is_port_in_use "$port" && {
        print_warning "Port $port is in use."
        if ! free_port "$port"; then
            print_error "Could not free port $port"
            return 1
        fi
    }

    screen_session_exists "$SCREEN_SERVER" && screen -S "$SCREEN_SERVER" -X quit 2>/dev/null
    screen_session_exists "$SCREEN_BOT" && screen -S "$SCREEN_BOT" -X quit 2>/dev/null
    screen_session_exists "$SCREEN_ANTICHEAT" && screen -S "$SCREEN_ANTICHEAT" -X quit 2>/dev/null

    sleep 1

    local log_dir="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves/$world_id"
    local log_file="$log_dir/console.log"
    mkdir -p "$log_dir"

    print_step "Starting server - World: $world_id, Port: $port"
    echo "$world_id" > "world_id_$port.txt"

    # Ensure wrapper exists so systemd and start use the same launcher
    ensure_wrapper

    cat > /tmp/start_server_$$.sh <<EOF
#!/bin/bash
cd '$PWD'

# If a libfreightpatch.so exists in this directory, preload it so the runtime patch is active.
SO_PATH="\$PWD/libfreightpatch.so"
if [ -f "\$SO_PATH" ]; then
    echo "[freight_patch] Found patch: \$SO_PATH" >&2
    export LD_PRELOAD="\$SO_PATH\${LD_PRELOAD:+:\$LD_PRELOAD}"
    echo "[freight_patch] LD_PRELOAD set to: \$LD_PRELOAD" >&2
fi

while true; do
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Starting server..."
    # Use the wrapper to ensure consistent LD_PRELOAD behaviour
    if $WRAPPER -o '$world_id' -p $port 2>&1 | tee -a '$log_file'; then
        echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Server closed normally"
    else
        exit_code=\$?
        echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Server failed with code: \$exit_code"
        if [ \$exit_code -eq 1 ] && tail -n 5 '$log_file' | grep -q "port.*already in use"; then
            echo "[\$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Port already in use. Will not retry."
            break
        fi
    fi
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Restarting in 5 seconds..."
    sleep 5
done
EOF

    chmod +x /tmp/start_server_$$.sh
    screen -dmS "$SCREEN_SERVER" /tmp/start_server_$$.sh
    (sleep 10; rm -f /tmp/start_server_$$.sh) &

    print_step "Waiting for server to start..."
    local wait_time=0
    while [ ! -f "$log_file" ] && [ $wait_time -lt 15 ]; do
        sleep 1
        ((wait_time++))
    done

    [ ! -f "$log_file" ] && {
        print_error "Could not create log file. Server may not have started."
        return 1
    }

    local server_ready=false
    for i in {1..30}; do
        if grep -q "World load complete\|Server started\|Ready for connections\|using seed:\|save delay:" "$log_file"; then
            server_ready=true
            break
        fi
        sleep 1
    done

    [ "$server_ready" = false ] && {
        print_warning "Server did not show complete startup messages"
        if ! screen_session_exists "$SCREEN_SERVER"; then
            print_error "Server screen session not found"
            return 1
        fi
    } || print_success "Server started successfully!"

    print_step "Starting server bot..."
    screen -dmS "$SCREEN_BOT" bash -c "
        cd '$PWD'
        echo 'Starting server bot for port $port...'
        ./server_bot.sh '$log_file' '$port'
    "

    print_step "Starting anticheat security system..."
    screen -dmS "$SCREEN_ANTICHEAT" bash -c "
        cd '$PWD'
        echo 'Starting anticheat for port $port...'
        ./anticheat_secure.sh '$log_file' '$port'
    "

    local server_started=0 bot_started=0 anticheat_started=0

    screen_session_exists "$SCREEN_SERVER" && server_started=1
    screen_session_exists "$SCREEN_BOT" && bot_started=1
    screen_session_exists "$SCREEN_ANTICHEAT" && anticheat_started=1

    if [ "$server_started" -eq 1 ] && [ "$bot_started" -eq 1 ] && [ "$anticheat_started" -eq 1 ]; then
        print_header "SERVER, BOT AND ANTICHEAT STARTED SUCCESSFULLY!"
        print_success "World: $world_id"
        print_success "Port: $port"
        echo ""
        print_status "To view server console: ${CYAN}screen -r $SCREEN_SERVER${NC}"
        print_status "To view bot: ${CYAN}screen -r $SCREEN_BOT${NC}"
        print_status "To view anticheat: ${CYAN}screen -r $SCREEN_ANTICHEAT${NC}"
        echo ""
        print_warning "To exit console without stopping server: ${YELLOW}CTRL+A, D${NC}"
    else
        print_warning "Could not verify all screen sessions"
    fi
}

# Function to stop server
stop_server() {
    local port="$1"

    if [ -z "$port" ]; then
        print_step "Stopping all servers, bots and anticheat..."

        for server_session in $(screen -list | grep "blockheads_server_" | awk -F. '{print $1}'); do
            screen -S "$server_session" -X quit 2>/dev/null
            print_success "Stopped server: $server_session"
        done

        for bot_session in $(screen -list | grep "blockheads_bot_" | awk -F. '{print $1}'); do
            screen -S "$bot_session" -X quit 2>/dev/null
            print_success "Stopped bot: $bot_session"
        done

        for anticheat_session in $(screen -list | grep "blockheads_anticheat_" | awk -F. '{print $1}'); do
            screen -S "$anticheat_session" -X quit 2>/dev/null
            print_success "Stopped anticheat: $anticheat_session"
        done

        pkill -f "$SERVER_BINARY" 2>/dev/null || true
        print_success "Cleanup completed for all servers."
    else
        print_step "Stopping server, bot and anticheat on port $port..."

        local screen_server="blockheads_server_$port"
        local screen_bot="blockheads_bot_$port"
        local screen_anticheat="blockheads_anticheat_$port"

        if screen_session_exists "$screen_server"; then
            screen -S "$screen_server" -X quit 2>/dev/null
            print_success "Server stopped on port $port."
        else
            print_warning "Server was not running on port $port."
        fi

        if screen_session_exists "$screen_bot"; then
            screen -S "$screen_bot" -X quit 2>/dev/null
            print_success "Bot stopped on port $port."
        else
            print_warning "Bot was not running on port $port."
        fi

        if screen_session_exists "$screen_anticheat"; then
            screen -S "$screen_anticheat" -X quit 2>/dev/null
            print_success "Anticheat stopped on port $port."
        else
            print_warning "Anticheat was not running on port $port."
        fi

        pkill -f "$SERVER_BINARY.*$port" 2>/dev/null || true
        print_success "Cleanup completed for port $port."
    fi
}

# Function to list servers
list_servers() {
    print_header "LIST OF RUNNING SERVERS"

    local servers
    servers=$(screen -list | grep "blockheads_server_" | awk -F. '{print $1}' | sed 's/blockheads_server_/ - Port: /' || true)

    if [ -z "$servers" ]; then
        print_warning "No servers are currently running."
    else
        print_status "Running servers:"
        while IFS= read -r server; do
            print_status "  $server"
        done <<< "$servers"
    fi

    print_header "END OF LIST"
}

# Function to show status
show_status() {
    local port="$1"

    if [ -z "$port" ]; then
        print_header "THE BLOCKHEADS SERVER STATUS - ALL SERVERS"

        local servers
        servers=$(screen -list | grep "blockheads_server_" | awk -F. '{print $1}' | sed 's/blockheads_server_//' || true)

        if [ -z "$servers" ]; then
            print_error "No servers are currently running."
        else
            while IFS= read -r server_port; do
                if screen_session_exists "blockheads_server_$server_port"; then
                    print_success "Server on port $server_port: RUNNING"
                else
                    print_error "Server on port $server_port: STOPPED"
                fi

                if screen_session_exists "blockheads_bot_$server_port"; then
                    print_success "Bot on port $server_port: RUNNING"
                else
                    print_error "Bot on port $server_port: STOPPED"
                fi

                if screen_session_exists "blockheads_anticheat_$server_port"; then
                    print_success "Anticheat on port $server_port: RUNNING"
                else
                    print_error "Anticheat on port $server_port: STOPPED"
                fi

                if [ -f "world_id_$server_port.txt" ]; then
                    local WORLD_ID
                    WORLD_ID=$(cat "world_id_$server_port.txt" 2>/dev/null)
                    print_status "World for port $server_port: ${CYAN}$WORLD_ID${NC}"
                fi

                echo ""
            done <<< "$servers"
        fi
    else
        print_header "THE BLOCKHEADS SERVER STATUS - PORT $port"

        if screen_session_exists "blockheads_server_$port"; then
            print_success "Server: RUNNING"
        else
            print_error "Server: STOPPED"
        fi

        if screen_session_exists "blockheads_bot_$port"; then
            print_success "Bot: RUNNING"
        else
            print_error "Bot: STOPPED"
        fi

        if screen_session_exists "blockheads_anticheat_$port"; then
            print_success "Anticheat: RUNNING"
        else
            print_error "Anticheat: STOPPED"
        fi

        if [ -f "world_id_$port.txt" ]; then
            local WORLD_ID
            WORLD_ID=$(cat "world_id_$port.txt" 2>/dev/null)
            print_status "Current world: ${CYAN}$WORLD_ID${NC}"

            if screen_session_exists "blockheads_server_$port"; then
                print_status "To view console: ${CYAN}screen -r blockheads_server_$port${NC}"
                print_status "To view bot: ${CYAN}screen -r blockheads_bot_$port${NC}"
                print_status "To view anticheat: ${CYAN}screen -r blockheads_anticheat_$port${NC}"
            fi
        else
            print_warning "World: Not configured for port $port"
        fi
    fi

    print_header "END OF STATUS"
}

# Function to show usage
show_usage() {
    print_header "THE BLOCKHEADS SERVER MANAGER"
    print_status "Usage: $0 [command]"
    echo ""
    print_status "Available commands:"
    echo -e "  ${GREEN}start${NC} [WORLD_NAME] [PORT]      - Start server, bot and anticheat"
    echo -e "  ${GREEN}install-service${NC} [WORLD_NAME] [PORT] - Install systemd service for this world (requires sudo)"
    echo -e "  ${RED}stop${NC} [PORT]                    - Stop server, bot and anticheat"
    echo -e "  ${CYAN}status${NC} [PORT]                  - Show server status"
    echo -e "  ${YELLOW}list${NC}                         - List all running servers"
    echo -e "  ${YELLOW}help${NC}                         - Show this help"
    echo ""
    print_status "Examples:"
    echo -e "  ${GREEN}$0 start MyWorld 12153${NC}"
    echo -e "  ${GREEN}$0 install-service MyWorld 12153${NC} (creates systemd unit blockheads_12153.service)"
    echo -e "  ${RED}$0 stop 12153${NC}"
    echo -e "  ${CYAN}$0 status 12153${NC}"
    echo -e "  ${YELLOW}$0 list${NC}"
    echo ""
    print_warning "First create a world: ./blockheads_server171 -n"
    print_warning "After creating the world, press CTRL+C to exit"
}

# Main execution
case "$1" in
    start)
        [ -z "$2" ] && print_error "You must specify a WORLD_NAME" && show_usage && exit 1
        start_server "$2" "$3"
        ;;
    install-service)
        [ -z "$2" ] && print_error "You must specify a WORLD_NAME" && show_usage && exit 1
        install_service "$2" "$3"
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
