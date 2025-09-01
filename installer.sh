#!/bin/bash
set -e

# Enhanced Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
ORANGE='\033[0;33m'
PURPLE='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Function to print status messages
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_header() {
    echo -e "${PURPLE}================================================================"
    echo -e "$1"
    echo -e "===============================================================${NC}"
}

print_step() {
    echo -e "${CYAN}[STEP]${NC} $1"
}

# Check for root privileges
if [ "$EUID" -ne 0 ]; then
    print_error "This script requires root privileges."
    print_status "Please run with: sudo $0"
    exit 1
fi

ORIGINAL_USER=${SUDO_USER:-$USER}
USER_HOME=$(getent passwd "$ORIGINAL_USER" | cut -d: -f6)

# Configuration
SERVER_URL="https://web.archive.org/web/20240309015235if_/https://majicdave.com/share/blockheads_server171.tar.gz"
TEMP_FILE="/tmp/blockheads_server171.tar.gz"
SERVER_BINARY="blockheads_server171"

# Raw URLs for helper scripts
RAW_BASE="https://raw.githubusercontent.com/noxthewildshadow/The-Blockheads-Server-BETA/refs/heads/main"
SERVER_MANAGER_URL="$RAW_BASE/server_manager.sh"
BOT_SCRIPT_URL="$RAW_BASE/server_bot.sh"
ANTICHEAT_SCRIPT_URL="$RAW_BASE/anticheat_secure.sh"

print_header "THE BLOCKHEADS LINUX SERVER INSTALLER"
print_header "FOR NEW USERS: This script will install everything you need"
print_header "Please be patient as it may take several minutes"

print_step "[1/9] Installing required packages..."
print_status "This may take a while depending on your internet connection..."
{
    # Add multiverse repository if not already added
    if ! grep -q "^deb.*multiverse" /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null; then
        add-apt-repository multiverse -y
    fi
    
    # Update package lists
    apt-get update -y
    
    # Install essential packages
    apt-get install -y libgnustep-base1.28 libdispatch-dev patchelf wget jq screen lsof software-properties-common
    
    # Install security packages
    apt-get install -y iptables-persistent bc
    
} > /dev/null 2>&1

if [ $? -eq 0 ]; then
    print_success "Required packages installed"
else
    print_error "Failed to install required packages"
    print_status "Trying alternative approach..."
    
    # Fallback installation method
    apt-get install -y software-properties-common
    add-apt-repository multiverse -y
    apt-get update -y
    apt-get install -y libgnustep-base1.28 libdispatch-dev patchelf wget jq screen lsof iptables-persistent bc || {
        print_error "Still failed to install packages. Please check your internet connection."
        exit 1
    }
fi

print_step "[2/9] Downloading helper scripts from GitHub..."
if ! wget -q -O server_manager.sh "$SERVER_MANAGER_URL"; then
    print_error "Failed to download server_manager.sh from GitHub."
    print_status "Trying alternative URL..."
    SERVER_MANAGER_URL="https://raw.githubusercontent.com/noxthewildshadow/The-Blockheads-Server-BETA/main/server_manager.sh"
    if ! wget -q -O server_manager.sh "$SERVER_MANAGER_URL"; then
        print_error "Completely failed to download server_manager.sh"
        exit 1
    fi
fi

if ! wget -q -O server_bot.sh "$BOT_SCRIPT_URL"; then
    print_error "Failed to download server_bot.sh from GitHub."
    print_status "Trying alternative URL..."
    BOT_SCRIPT_URL="https://raw.githubusercontent.com/noxthewildshadow/The-Blockheads-Server-BETA/main/server_bot.sh"
    if ! wget -q -O server_bot.sh "$BOT_SCRIPT_URL"; then
        print_error "Completely failed to download server_bot.sh"
        exit 1
    fi
fi

if ! wget -q -O anticheat_secure.sh "$ANTICHEAT_SCRIPT_URL"; then
    print_error "Failed to download anticheat_secure.sh from GitHub."
    print_status "Trying alternative URL..."
    ANTICHEAT_SCRIPT_URL="https://raw.githubusercontent.com/noxthewildshadow/The-Blockheads-Server-BETA/main/anticheat_secure.sh"
    if ! wget -q -O anticheat_secure.sh "$ANTICHEAT_SCRIPT_URL"; then
        print_error "Completely failed to download anticheat_secure.sh"
        exit 1
    fi
fi
print_success "Helper scripts downloaded"

chmod +x server_manager.sh server_bot.sh anticheat_secure.sh

print_step "[3/9] Downloading server archive..."
if ! wget -q --timeout=60 --tries=3 "$SERVER_URL" -O "$TEMP_FILE"; then
    print_error "Failed to download server file."
    print_status "This might be due to:"
    print_status "1. Internet connection issues"
    print_status "2. The server file is no longer available at the expected URL"
    exit 1
fi
print_success "Server archive downloaded"

print_step "[4/9] Extracting files..."
EXTRACT_DIR="/tmp/blockheads_extract_$$"
mkdir -p "$EXTRACT_DIR"

if ! tar xzf "$TEMP_FILE" -C "$EXTRACT_DIR"; then
    print_error "Failed to extract server files."
    rm -rf "$EXTRACT_DIR"
    exit 1
fi

cp -r "$EXTRACT_DIR"/* ./
rm -rf "$EXTRACT_DIR"
print_success "Files extracted successfully"

# Find server binary if it wasn't named correctly
if [ ! -f "$SERVER_BINARY" ]; then
    print_warning "$SERVER_BINARY not found. Searching for alternative binary names..."
    ALTERNATIVE_BINARY=$(find . -name "*blockheads*" -type f -executable | head -n 1)
    if [ -n "$ALTERNATIVE_BINARY" ]; then
        print_status "Found alternative binary: $ALTERNATIVE_BINARY"
        mv "$ALTERNATIVE_BINARY" "blockheads_server171"
        SERVER_BINARY="blockheads_server171"
        print_success "Renamed to: blockheads_server171"
    else
        print_error "Could not find the server binary."
        print_status "Contents of the downloaded archive:"
        tar -tzf "$TEMP_FILE" || true
        exit 1
    fi
fi

chmod +x "$SERVER_BINARY"

print_step "[5/9] Applying patchelf compatibility patches (best-effort)..."
patchelf --replace-needed libgnustep-base.so.1.24 libgnustep-base.so.1.28 "$SERVER_BINARY" || print_warning "libgnustep-base patch may have failed"
patchelf --replace-needed libobjc.so.4.6 libobjc.so.4 "$SERVER_BINARY" || true
patchelf --replace-needed libgnutls.so.26 libgnutls.so.30 "$SERVER_BINARY" || true
patchelf --replace-needed libgcrypt.so.11 libgcrypt.so.20 "$SERVER_BINARY" || true
patchelf --replace-needed libffi.so.6 libffi.so.8 "$SERVER_BINARY" || true
patchelf --replace-needed libicui18n.so.48 libicui18n.so.70 "$SERVER_BINARY" || true
patchelf --replace-needed libicuuc.so.48 libicuuc.so.70 "$SERVER_BINARY" || true
patchelf --replace-needed libicudata.so.48 libicudata.so.70 "$SERVER_BINARY" || true
patchelf --replace-needed libdispatch.so libdispatch.so.0 "$SERVER_BINARY" || true
print_success "Compatibility patches applied"

print_step "[6/9] Set ownership and permissions for helper scripts and binary"
chown "$ORIGINAL_USER:$ORIGINAL_USER" server_manager.sh server_bot.sh anticheat_secure.sh "$SERVER_BINARY" ./*.json 2>/dev/null || true
chmod 755 server_manager.sh server_bot.sh anticheat_secure.sh "$SERVER_BINARY" ./*.json 2>/dev/null || true
print_success "Permissions set"

print_step "[7/9] Create economy data file"
sudo -u "$ORIGINAL_USER" bash -c 'echo "{\"players\": {}, \"transactions\": []}" > economy_data.json' || true
chown "$ORIGINAL_USER:$ORIGINAL_USER" economy_data.json 2>/dev/null || true
print_success "Economy data file created"

print_step "[8/9] Installing security enhancements..."
# Create security directory
SECURITY_DIR="$USER_HOME/blockheads_security"
sudo -u "$ORIGINAL_USER" mkdir -p "$SECURITY_DIR"

# Create firewall script
sudo -u "$ORIGINAL_USER" cat > "$SECURITY_DIR/setup_firewall.sh" << 'EOF'
#!/bin/bash
# Blockheads Server Firewall Configuration
PORT=${1:-12153}

echo "Setting up firewall rules for Blockheads server..."

# Check if we have root privileges
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Firewall setup requires root privileges."
    echo "Please run this script with: sudo $0 [PORT]"
    exit 1
fi

# Flush existing rules
iptables -F
iptables -X

# Default policies
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

# Allow loopback
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Allow established connections
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Protection against scans and brute force
iptables -A INPUT -p tcp --tcp-flags ALL NONE -j DROP
iptables -A INPUT -p tcp ! --syn -m state --state NEW -j DROP
iptables -A INPUT -p tcp --tcp-flags ALL ALL -j DROP

# Limit new connections (DDoS protection)
iptables -A INPUT -p tcp --dport $PORT -m connlimit --connlimit-above 20 -j DROP
iptables -A INPUT -p tcp --dport $PORT -m limit --limit 10/min --limit-burst 20 -j ACCEPT

# Allow server traffic
iptables -A INPUT -p tcp --dport $PORT -j ACCEPT

echo "Firewall rules configured successfully for port $PORT."
echo "Port $PORT is now protected against DDoS attacks."

# Save rules for persistence
if command -v iptables-save > /dev/null && command -v netfilter-persistent > /dev/null; then
    iptables-save > /etc/iptables/rules.v4
    netfilter-persistent save
    echo "Firewall rules saved persistently."
else
    echo "Warning: iptables-persistent not installed. Rules will not persist after reboot."
    echo "Install with: sudo apt-get install iptables-persistent"
fi
EOF

# Create monitoring script
sudo -u "$ORIGINAL_USER" cat > "$SECURITY_DIR/monitor_resources.sh" << 'EOF'
#!/bin/bash
# Resource monitoring for Blockheads server
PORT=${1:-12153}

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Thresholds
THRESHOLD_CPU=80
THRESHOLD_MEMORY=85
THRESHOLD_CONNECTIONS=50

log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$HOME/blockheads_security/monitor.log"
}

check_resources() {
    # Monitor CPU usage
    CPU_USAGE=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1)
    
    # Monitor memory usage
    MEM_USAGE=$(free | grep Mem | awk '{printf "%.0f", $3/$2 * 100.0}')
    
    # Monitor connections
    CONNECTION_COUNT=$(netstat -an | grep ":$PORT" | grep ESTABLISHED | wc -l)
    
    # Check thresholds
    if (( $(echo "$CPU_USAGE > $THRESHOLD_CPU" | bc -l) )); then
        log_message "HIGH CPU USAGE: $CPU_USAGE% - Possible DDoS attack"
        echo -e "${YELLOW}WARNING: High CPU usage detected ($CPU_USAGE%)${NC}"
    fi
    
    if [ "$MEM_USAGE" -gt "$THRESHOLD_MEMORY" ]; then
        log_message "HIGH MEMORY USAGE: $MEM_USAGE% - Possible DDoS attack"
        echo -e "${YELLOW}WARNING: High memory usage detected ($MEM_USAGE%)${NC}"
    fi
    
    if [ "$CONNECTION_COUNT" -gt "$THRESHOLD_CONNECTIONS" ]; then
        log_message "HIGH CONNECTION COUNT: $CONNECTION_COUNT - Possible DDoS attack"
        echo -e "${YELLOW}WARNING: High connection count detected ($CONNECTION_COUNT)${NC}"
    fi
}

# Main monitoring loop
echo "Starting resource monitoring for Blockheads server on port $PORT..."
log_message "Monitoring started for port $PORT"

while true; do
    check_resources
    sleep 30
done
EOF

# Create security helper script
sudo -u "$ORIGINAL_USER" cat > "$SECURITY_DIR/security_helper.sh" << 'EOF'
#!/bin/bash
# Security helper script for Blockheads server

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SECURITY_DIR="$HOME/blockheads_security"

show_help() {
    echo -e "${BLUE}Blockheads Server Security Helper${NC}"
    echo "Usage: $0 [command] [port]"
    echo ""
    echo "Commands:"
    echo "  setup-firewall    - Configure firewall rules (requires sudo)"
    echo "  start-monitoring  - Start resource monitoring"
    echo "  check-security    - Perform security check"
    echo "  view-logs         - View security logs"
    echo "  help              - Show this help"
    echo ""
    echo "Default port: 12153"
}

setup_firewall() {
    local PORT=${1:-12153}
    
    if [ ! -f "$SECURITY_DIR/setup_firewall.sh" ]; then
        echo -e "${RED}ERROR: Firewall script not found.${NC}"
        echo -e "${YELLOW}Please run the installer first.${NC}"
        return 1
    fi
    
    echo -e "${BLUE}Setting up firewall rules for port $PORT...${NC}"
    sudo "$SECURITY_DIR/setup_firewall.sh" "$PORT"
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Firewall configured successfully for port $PORT.${NC}"
    else
        echo -e "${RED}Firewall configuration failed.${NC}"
    fi
}

start_monitoring() {
    local PORT=${1:-12153}
    
    if [ ! -f "$SECURITY_DIR/monitor_resources.sh" ]; then
        echo -e "${RED}ERROR: Monitoring script not found.${NC}"
        echo -e "${YELLOW}Please run the installer first.${NC}"
        return 1
    fi
    
    echo -e "${BLUE}Starting resource monitoring for port $PORT...${NC}"
    nohup "$SECURITY_DIR/monitor_resources.sh" "$PORT" > /dev/null 2>&1 &
    echo -e "${GREEN}Monitoring started. Check $SECURITY_DIR/monitor.log for details.${NC}"
}

check_security() {
    echo -e "${BLUE}Performing security check...${NC}"
    
    # Check if firewall rules are active
    echo -e "${YELLOW}Checking firewall rules...${NC}"
    sudo iptables -L -n | head -20
    
    # Check running processes
    echo -e "${YELLOW}Checking running processes...${NC}"
    ps aux | grep -E "(blockheads|monitor)" | grep -v grep || echo -e "${RED}No security processes found.${NC}"
    
    # Check open ports
    echo -e "${YELLOW}Checking open ports...${NC}"
    netstat -tuln | grep -E "(:12153|:80|:443)" || echo -e "${RED}No relevant ports open.${NC}"
    
    echo -e "${GREEN}Security check completed.${NC}"
}

view_logs() {
    if [ -f "$SECURITY_DIR/monitor.log" ]; then
        echo -e "${BLUE}Showing security logs:${NC}"
        tail -20 "$SECURITY_DIR/monitor.log"
    else
        echo -e "${YELLOW}No security logs found.${NC}"
    fi
}

# Main command handling
case "$1" in
    setup-firewall)
        setup_firewall "$2"
        ;;
    start-monitoring)
        start_monitoring "$2"
        ;;
    check-security)
        check_security
        ;;
    view-logs)
        view_logs
        ;;
    help|*)
        show_help
        ;;
esac
EOF

# Give execute permissions
sudo -u "$ORIGINAL_USER" chmod +x "$SECURITY_DIR/setup_firewall.sh"
sudo -u "$ORIGINAL_USER" chmod +x "$SECURITY_DIR/monitor_resources.sh"
sudo -u "$ORIGINAL_USER" chmod +x "$SECURITY_DIR/security_helper.sh"

print_success "Security enhancements installed"

print_step "[9/9] Finalizing installation..."
rm -f "$TEMP_FILE"

print_success "Installation completed successfully"
echo ""
print_header "USAGE INSTRUCTIONS FOR NEW USERS"
print_status "1. FIRST create a world manually with:"
echo "   ./blockheads_server171 -n"
echo ""
print_warning "IMPORTANT: After creating the world, press CTRL+C to exit"
echo ""
print_status "2. Then start the server and bot with:"
echo "   ./server_manager.sh start WORLD_NAME PORT"
echo ""
print_status "3. To stop the server:"
echo "   ./server_manager.sh stop"
echo ""
print_status "4. To check status:"
echo "   ./server_manager.sh status"
echo ""
print_status "5. For security setup:"
echo "   sudo ~/blockheads_security/setup_firewall.sh [PORT]"
echo "   ~/blockheads_security/security_helper.sh start-monitoring [PORT]"
echo "   ~/blockheads_security/security_helper.sh check-security"
echo ""
print_status "6. For help:"
echo "   ./server_manager.sh help"
echo "   ./blockheads_server171 -h"
echo ""
print_warning "NOTE: Default port is 12153 if not specified"
print_header "NEW SECURITY FEATURES"
print_status "Added firewall protection against DDoS attacks"
print_status "Added resource monitoring system"
print_status "Enhanced security helper script"
print_status "All security files are stored in: $SECURITY_DIR"
print_header "NEED HELP?"
print_status "Visit the GitHub repository for more information:"
print_status "https://github.com/noxthewildshadow/The-Blockheads-Server-BETA"
print_header "INSTALLATION COMPLETE"
