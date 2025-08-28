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

print_header "THE BLOCKHEADS LINUX SERVER INSTALLER"
print_header "FOR NEW USERS: This script will install everything you need"
print_header "Please be patient as it may take several minutes"

print_step "[1/8] Installing required packages..."
{
    add-apt-repository multiverse -y || true
    apt-get update -y
    apt-get install -y libgnustep-base1.28 libdispatch-dev patchelf wget jq screen lsof software-properties-common
} > /dev/null 2>&1
if [ $? -eq 0 ]; then
    print_success "Required packages installed"
else
    print_error "Failed to install required packages"
    print_status "Trying alternative approach..."
    apt-get install -y software-properties-common
    add-apt-repository multiverse -y
    apt-get update -y
    apt-get install -y libgnustep-base1.28 libdispatch-dev patchelf wget jq screen lsof || {
        print_error "Still failed to install packages. Please check your internet connection."
        exit 1
    }
fi

print_step "[2/8] Downloading helper scripts from GitHub..."
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
print_success "Helper scripts downloaded"

chmod +x server_manager.sh server_bot.sh

print_step "[3/8] Downloading server archive..."
if ! wget -q --timeout=60 --tries=3 "$SERVER_URL" -O "$TEMP_FILE"; then
    print_error "Failed to download server file."
    print_status "This might be due to:"
    print_status "1. Internet connection issues"
    print_status "2. The server file is no longer available at the expected URL"
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

print_step "[5/8] Applying patchelf compatibility patches (best-effort)..."
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

print_step "[6/8] Set ownership and permissions for helper scripts and binary"
chown "$ORIGINAL_USER:$ORIGINAL_USER" server_manager.sh server_bot.sh "$SERVER_BINARY" ./*.json 2>/dev/null || true
chmod 755 server_manager.sh server_bot.sh "$SERVER_BINARY" ./*.json 2>/dev/null || true
print_success "Permissions set"

print_step "[7/8] Create economy data file"
sudo -u "$ORIGINAL_USER" bash -c 'echo "{\"players\": {}, \"transactions\": []}" > economy_data.json' || true
chown "$ORIGINAL_USER:$ORIGINAL_USER" economy_data.json 2>/dev/null || true
print_success "Economy data file created"

rm -f "$TEMP_FILE"

print_step "[8/8] Installation completed successfully"
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
print_status "5. For help:"
echo "   ./server_manager.sh help"
echo "   ./blockheads_server171 -h"
echo ""
print_warning "NOTE: Default port is 12153 if not specified"
print_header "NEED HELP?"
print_status "Visit the GitHub repository for more information:"
print_status "https://github.com/noxthewildshadow/The-Blockheads-Server-BETA"
print_header "INSTALLATION COMPLETE"
