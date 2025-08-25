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
RAW_BASE="https://raw.githubusercontent.com/noxthewildshadow/TheBlockHeads-Server-CLONE/refs/heads/main"
SERVER_MANAGER_URL="$RAW_BASE/server_manager.sh"
BOT_SCRIPT_URL="$RAW_BASE/bot_server.sh"

print_header "THE BLOCKHEADS LINUX SERVER INSTALLER"
print_status "This script will install The Blockheads server on your Linux system."
print_status "Make sure you have a stable internet connection before proceeding."
echo ""

# Check if we're in a suitable directory
if [ "$(basename "$PWD")" = "blockheads_server" ]; then
    print_status "Installing in dedicated blockheads_server directory."
else
    print_warning "It's recommended to create a dedicated directory for the server."
    read -p "Do you want to create a 'blockheads_server' directory now? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        mkdir -p blockheads_server
        cd blockheads_server
        print_success "Created and moved to blockheads_server directory."
    fi
fi

print_step "[1/8] Installing required packages..."
{
    # Add multiverse repository for Ubuntu/Debian
    if [ -f /etc/debian_version ]; then
        add-apt-repository multiverse -y > /dev/null 2>&1 || true
    fi
    
    # Update package lists
    apt-get update -y > /dev/null 2>&1
    
    # Install required packages
    apt-get install -y libgnustep-base1.28 libdispatch0 patchelf wget jq screen lsof > /dev/null 2>&1
} 
if [ $? -eq 0 ]; then
    print_success "Required packages installed"
else
    print_error "Failed to install required packages"
    print_status "Trying alternative approach..."
    
    # Try alternative package names for different distributions
    {
        apt-get install -y libgnustep-base-dev libdispatch-dev patchelf wget jq screen lsof > /dev/null 2>&1
    } || {
        print_error "Could not install required packages. Please install manually:"
        print_status "libgnustep-base1.28, libdispatch0, patchelf, wget, jq, screen, lsof"
        exit 1
    }
fi

print_step "[2/8] Downloading helper scripts from GitHub..."
if ! wget -q --timeout=30 -O server_manager.sh "$SERVER_MANAGER_URL"; then
    print_error "Failed to download server_manager.sh from GitHub."
    print_status "Creating a basic server_manager.sh instead..."
    
    # Create a basic server manager script as fallback
    cat > server_manager.sh << 'EOF'
#!/bin/bash
# Basic server manager script as fallback
echo "Basic server manager - please download the full version from GitHub"
exit 1
EOF
    chmod +x server_manager.sh
fi

if ! wget -q --timeout=30 -O bot_server.sh "$BOT_SCRIPT_URL"; then
    print_error "Failed to download bot_server.sh from GitHub."
    print_status "Creating a basic bot_server.sh instead..."
    
    # Create a basic bot script as fallback
    cat > bot_server.sh << 'EOF'
#!/bin/bash
# Basic bot script as fallback
echo "Basic bot server - please download the full version from GitHub"
exit 1
EOF
    chmod +x bot_server.sh
fi

print_success "Helper scripts downloaded or created"

print_step "[3/8] Downloading server archive..."
if ! wget -q --timeout=60 --tries=3 "$SERVER_URL" -O "$TEMP_FILE"; then
    print_error "Failed to download server file."
    print_status "Please check your internet connection and try again."
    exit 1
fi
print_success "Server archive downloaded"

print_step "[4/8] Extracting files..."
EXTRACT_DIR="/tmp/blockheads_extract_$$"
mkdir -p "$EXTRACT_DIR"

if ! tar xzf "$TEMP_FILE" -C "$EXTRACT_DIR"; then
    print_error "Failed to extract server files."
    rm -rf "$EXTRACT_DIR"
    exit 1
fi

# Copy files, preserving directory structure
cp -r "$EXTRACT_DIR"/* ./
rm -rf "$EXTRACT_DIR"
print_success "Files extracted successfully"

# Find server binary if it wasn't named correctly
if [ ! -f "$SERVER_BINARY" ]; then
    print_warning "$SERVER_BINARY not found. Searching for alternative binary names..."
    ALTERNATIVE_BINARY=$(find . -name "*blockheads*" -type f -executable | head -n 1)
    if [ -n "$ALTERNATIVE_BINARY" ]; then
        print_status "Found alternative binary: $ALTERNATIVE_BINARY"
        SERVER_BINARY=$(basename "$ALTERNATIVE_BINARY")
        print_success "Using binary: $SERVER_BINARY"
    else
        print_error "Could not find the server binary."
        print_status "Contents of the archive:"
        tar -tzf "$TEMP_FILE" | head -20
        exit 1
    fi
fi

chmod +x "$SERVER_BINARY"

print_step "[5/8] Applying patchelf compatibility patches (best-effort)..."
# Check if patchelf is available
if command -v patchelf >/dev/null 2>&1; then
    patchelf --replace-needed libgnustep-base.so.1.24 libgnustep-base.so.1.28 "$SERVER_BINARY" 2>/dev/null || print_warning "libgnustep-base patch may have failed"
    patchelf --replace-needed libobjc.so.4.6 libobjc.so.4 "$SERVER_BINARY" 2>/dev/null || true
    patchelf --replace-needed libgnutls.so.26 libgnutls.so.30 "$SERVER_BINARY" 2>/dev/null || true
    patchelf --replace-needed libgcrypt.so.11 libgcrypt.so.20 "$SERVER_BINARY" 2>/dev/null || true
    patchelf --replace-needed libffi.so.6 libffi.so.8 "$SERVER_BINARY" 2>/dev/null || true
    patchelf --replace-needed libicui18n.so.48 libicui18n.so.70 "$SERVER_BINARY" 2>/dev/null || true
    patchelf --replace-needed libicuuc.so.48 libicuuc.so.70 "$SERVER_BINARY" 2>/dev/null || true
    patchelf --replace-needed libicudata.so.48 libicudata.so.70 "$SERVER_BINARY" 2>/dev/null || true
    patchelf --replace-needed libdispatch.so libdispatch.so.0 "$SERVER_BINARY" 2>/dev/null || true
    print_success "Compatibility patches applied"
else
    print_warning "patchelf not found, skipping compatibility patches"
fi

print_step "[6/8] Set ownership and permissions for helper scripts and binary"
chown "$ORIGINAL_USER:$ORIGINAL_USER" server_manager.sh bot_server.sh "$SERVER_BINARY" 2>/dev/null || true
chmod 755 server_manager.sh bot_server.sh "$SERVER_BINARY" 2>/dev/null || true
print_success "Permissions set"

print_step "[7/8] Create economy data file"
sudo -u "$ORIGINAL_USER" bash -c 'echo "{\"players\": {}, \"transactions\": []}" > economy_data.json' 2>/dev/null || true
chown "$ORIGINAL_USER:$ORIGINAL_USER" economy_data.json 2>/dev/null || true
print_success "Economy data file created"

rm -f "$TEMP_FILE"

print_step "[8/8] Installation completed successfully"
echo ""
print_header "USAGE INSTRUCTIONS"
print_status "1. FIRST create a world manually with:"
echo "   ./$SERVER_BINARY -n"
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
print_status "5. For help:"
echo "   ./server_manager.sh help"
echo "   ./$SERVER_BINARY -h"
echo ""
print_warning "NOTE: Default port is 12153 if not specified"
print_header "NEXT STEPS"
print_status "1. Create your world: ./$SERVER_BINARY -n"
print_status "2. Start your server: ./server_manager.sh start MyWorld 12153"
print_status "3. Connect using The Blockheads app on your device"
print_status "4. Find your server in the 'Custom Servers' section"
print_header "INSTALLATION COMPLETE"
