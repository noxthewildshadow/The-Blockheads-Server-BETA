#!/bin/bash

# =============================================================================
# THE BLOCKHEADS ANTICHEAT SECURITY SYSTEM WITH PLAYERS.LOG AS SINGLE SOURCE OF TRUTH
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

# Validate required tools
if ! command -v inotifywait &> /dev/null; then
    echo -e "${RED}ERROR: inotifywait is required but not installed. Please install inotify-tools first.${NC}"
    exit 1
fi

if ! command -v flock &> /dev/null; then
    echo -e "${RED}ERROR: flock is required but not installed. Please install util-linux first.${NC}"
    exit 1
fi

# Initialize variables
LOG_FILE="$1"
PORT="$2"
LOG_DIR=$(dirname "$LOG_FILE")
PLAYERS_LOG="$LOG_DIR/players.log"
ADMINLIST_FILE="$LOG_DIR/adminlist.txt"
MODLIST_FILE="$LOG_DIR/modlist.txt"
BLACKLIST_FILE="$LOG_DIR/blacklist.txt"
SCREEN_SERVER="blockheads_server_$PORT"
SYNC_LOCK_FILE="/tmp/players_sync.lock"

# Ensure players.log exists
initialize_players_log() {
    if [ ! -f "$PLAYERS_LOG" ]; then
        touch "$PLAYERS_LOG"
        print_success "Created players.log: $PLAYERS_LOG"
    fi
    
    # Create default list files if they don't exist
    [ ! -f "$ADMINLIST_FILE" ] && echo "# Admin list (auto-generated from players.log)" > "$ADMINLIST_FILE"
    [ ! -f "$MODLIST_FILE" ] && echo "# Mod list (auto-generated from players.log)" > "$MODLIST_FILE"
    [ ! -f "$BLACKLIST_FILE" ] && echo "# Blacklist (auto-generated from players.log)" > "$BLACKLIST_FILE"
}

# Function to sync list files from players.log
sync_list_files() {
    # Acquire lock to prevent concurrent access
    (
        flock -x 200
        
        print_status "Starting sync of list files from players.log..."
        
        # Clear existing list files (keep headers)
        sed -i '/^[^#]/d' "$ADMINLIST_FILE"
        sed -i '/^[^#]/d' "$MODLIST_FILE"
        sed -i '/^[^#]/d' "$BLACKLIST_FILE"
        
        local added_admins=0
        local added_mods=0
        local added_bans=0
        
        # Read players.log and update list files
        while IFS='|' read -r name ip rank password ban_status; do
            if [ "$ban_status" = "BANNED" ] || [ "$ban_status" = "Blacklisted" ]; then
                if ! grep -q "^$name$" "$BLACKLIST_FILE"; then
                    echo "$name" >> "$BLACKLIST_FILE"
                    ((added_bans++))
                fi
                # Remove from admin and mod lists if banned
                sed -i "/^$name$/d" "$ADMINLIST_FILE"
                sed -i "/^$name$/d" "$MODLIST_FILE"
            elif [ "$rank" = "ADMIN" ]; then
                if ! grep -q "^$name$" "$ADMINLIST_FILE"; then
                    echo "$name" >> "$ADMINLIST_FILE"
                    ((added_admins++))
                fi
                # Remove from mod list if admin
                sed -i "/^$name$/d" "$MODLIST_FILE"
            elif [ "$rank" = "MOD" ]; then
                if ! grep -q "^$name$" "$MODLIST_FILE"; then
                    echo "$name" >> "$MODLIST_FILE"
                    ((added_mods++))
                fi
            else
                # Remove from all lists if no rank
                sed -i "/^$name$/d" "$ADMINLIST_FILE"
                sed -i "/^$name$/d" "$MODLIST_FILE"
            fi
        done < <(grep -v "^#" "$PLAYERS_LOG" | grep -v "^$")
        
        print_success "Sync completed - $added_admins admins, $added_mods mods, $added_bans bans"
        
    ) 200>"$SYNC_LOCK_FILE"
}

# Function to apply rank changes to server
apply_rank_changes() {
    local name="$1"
    local rank="$2"
    local ban_status="$3"
    local ip="$4"
    
    # Priority: BANNED > ADMIN > MOD > NONE
    if [ "$ban_status" = "BANNED" ] || [ "$ban_status" = "Blacklisted" ]; then
        # Remove ranks and ban player
        screen -S "$SCREEN_SERVER" -p 0 -X stuff "/unmod $name$(printf \\r)"
        screen -S "$SCREEN_SERVER" -p 0 -X stuff "/unadmin $name$(printf \\r)"
        screen -S "$SCREEN_SERVER" -p 0 -X stuff "/ban ip $ip$(printf \\r)"
        print_success "Banned $name (IP: $ip) and removed all ranks"
    elif [ "$rank" = "ADMIN" ]; then
        # Ensure admin rank
        screen -S "$SCREEN_SERVER" -p 0 -X stuff "/admin $name$(printf \\r)"
        screen -S "$SCREEN_SERVER" -p 0 -X stuff "/unmod $name$(printf \\r)"
        print_success "Applied ADMIN rank to $name"
    elif [ "$rank" = "MOD" ]; then
        # Ensure mod rank (and not admin)
        screen -S "$SCREEN_SERVER" -p 0 -X stuff "/mod $name$(printf \\r)"
        screen -S "$SCREEN_SERVER" -p 0 -X stuff "/unadmin $name$(printf \\r)"
        print_success "Applied MOD rank to $name"
    else
        # Remove all ranks
        screen -S "$SCREEN_SERVER" -p 0 -X stuff "/unmod $name$(printf \\r)"
        screen -S "$SCREEN_SERVER" -p 0 -X stuff "/unadmin $name$(printf \\r)"
        print_success "Removed all ranks from $name"
    fi
}

# Function to monitor players.log for changes
monitor_players_log() {
    print_header "STARTING PLAYERS.LOG MONITOR"
    print_status "Monitoring: $PLAYERS_LOG"
    print_status "Server screen: $SCREEN_SERVER"
    
    # Initial sync
    sync_list_files
    
    # Monitor for changes with debounce
    local last_change=0
    local debounce_delay=2
    
    inotifywait -m -e modify "$PLAYERS_LOG" | while read -r path action file; do
        local current_time=$(date +%s)
        
        # Debounce logic - group rapid changes
        if [ $((current_time - last_change)) -ge $debounce_delay ]; then
            print_status "Change detected in players.log - syncing..."
            
            # Sync list files
            sync_list_files
            
            # Apply rank changes to server
            while IFS='|' read -r name ip rank password ban_status; do
                apply_rank_changes "$name" "$rank" "$ban_status" "$ip"
            done < <(grep -v "^#" "$PLAYERS_LOG" | grep -v "^$")
            
            last_change=$current_time
        fi
    done
}

# Function to handle manual edits to list files
monitor_list_files() {
    print_status "Monitoring list files for manual changes..."
    
    # Monitor all three list files
    inotifywait -m -e modify "$ADMINLIST_FILE" "$MODLIST_FILE" "$BLACKLIST_FILE" | while read -r path action file; do
        print_warning "Manual change detected in $file - overriding with players.log data"
        sync_list_files
    done
}

# Function to cleanup
cleanup() {
    print_status "Cleaning up anticheat..."
    kill $(jobs -p) 2>/dev/null
    rm -f "$SYNC_LOCK_FILE" 2>/dev/null
    exit 0
}

# Main execution
if [ $# -lt 1 ]; then
    echo -e "${RED}Usage: $0 <server_log_directory> [port]${NC}"
    exit 1
fi

# Initialize
initialize_players_log

# Set trap for cleanup
trap cleanup EXIT INT TERM

# Start monitoring in background
monitor_list_files &
monitor_players_log
