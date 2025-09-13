#!/bin/bash
set -e

# =============================================================================
# THE BLOCKHEADS LINUX SERVER INSTALLER - OPTIMIZED VERSION
# =============================================================================

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Function definitions
print_status() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

# Check if running as root
[ "$EUID" -ne 0 ] && print_error "This script requires root privileges." && exit 1

ORIGINAL_USER=${SUDO_USER:-$USER}
USER_HOME=$(getent passwd "$ORIGINAL_USER" | cut -d: -f6)

# URLs for server download
SERVER_URL="https://github.com/noxthewildshadow/The-Blockheads-Server-BETA/releases/download/1.0/blockheads_server171.tar"
TEMP_FILE="/tmp/blockheads_server171.tar"
SERVER_BINARY="blockheads_server171"

# GitHub raw content URLs
SCRIPTS=(
    "server_manager.sh"
    "server_bot.sh"
    "anticheat_secure.sh"
    "blockheads_common.sh"
)

# Package lists for different distributions
declare -a PACKAGES_DEBIAN=(
    'curl' 'tar' 'grep' 'patchelf' 'libgnustep-base-dev' 'libobjc4'
    'libgnutls28-dev' 'libgcrypt20-dev' 'libxml2' 'libffi-dev' 'libnsl-dev'
    'zlib1g' 'libicu-dev' 'libstdc++6' 'libgcc-s1' 'wget' 'jq' 'screen' 'lsof'
)

print_step "THE BLOCKHEADS LINUX SERVER INSTALLER"

# Function to install packages
install_packages() {
    [ ! -f /etc/os-release ] && print_error "Could not detect the operating system" && return 1
    
    source /etc/os-release
    case $ID in
        debian|ubuntu|pop)
            print_status "Installing packages for Debian/Ubuntu..."
            apt-get update > /dev/null 2>&1
            for package in "${PACKAGES_DEBIAN[@]}"; do
                apt-get install -y "$package" > /dev/null 2>&1
            done
            ;;
        arch)
            print_status "Installing packages for Arch Linux..."
            pacman -Sy --noconfirm --needed "${PACKAGES_ARCH[@]}" > /dev/null 2>&1
            ;;
        *)
            print_error "Unsupported operating system: $ID"
            return 1
            ;;
    esac
    
    return 0
}

# Function to download scripts
download_script() {
    local script_name=$1
    wget --timeout=30 --tries=2 -q -O "$script_name" \
        "https://raw.githubusercontent.com/noxthewildshadow/The-Blockheads-Server-BETA/main/$script_name"
    return $?
}

print_step "1/6 Installing required packages..."
if ! install_packages; then
    print_warning "Falling back to basic package installation..."
    apt-get update -y > /dev/null 2>&1
    apt-get install -y libgnustep-base1.28 libdispatch-dev patchelf wget jq screen lsof > /dev/null 2>&1
fi

print_step "2/6 Downloading helper scripts from GitHub..."
for script in "${SCRIPTS[@]}"; do
    if download_script "$script"; then
        chmod +x "$script"
    else
        print_error "Failed to download $script"
        exit 1
    fi
done

print_step "3/6 Downloading server archive..."
if wget --progress=bar:force "$SERVER_URL" -O "$TEMP_FILE" 2>/dev/null; then
    print_status "Download successful"
else
    print_error "Failed to download server file"
    exit 1
fi

print_step "4/6 Extracting files..."
EXTRACT_DIR="/tmp/blockheads_extract_$$"
mkdir -p "$EXTRACT_DIR"

if tar -xf "$TEMP_FILE" -C "$EXTRACT_DIR" 2>/dev/null; then
    cp -r "$EXTRACT_DIR"/* ./
    rm -rf "$EXTRACT_DIR"
else
    print_error "Failed to extract server files"
    exit 1
fi

if [ ! -f "$SERVER_BINARY" ]; then
    ALTERNATIVE_BINARY=$(find . -name "*blockheads*" -type f -executable | head -n 1)
    [ -n "$ALTERNATIVE_BINARY" ] && mv "$ALTERNATIVE_BINARY" "blockheads_server171"
fi

[ ! -f "$SERVER_BINARY" ] && print_error "Server binary not found after extraction" && exit 1

chmod +x "$SERVER_BINARY"

print_step "5/6 Applying compatibility patches..."
declare -A LIBS=(
    ["libgnustep-base.so.1.24"]="libgnustep-base.so.1.28"
    ["libobjc.so.4.6"]="libobjc.so.4"
    ["libgnutls.so.26"]="libgnutls.so.30"
    ["libgcrypt.so.11"]="libgcrypt.so.20"
    ["libffi.so.6"]="libffi.so.8"
)

for LIB in "${!LIBS[@]}"; do
    patchelf --replace-needed "$LIB" "${LIBS[$LIB]}" "$SERVER_BINARY" 2>/dev/null || true
done

print_step "6/6 Setting up final configuration..."
chown "$ORIGINAL_USER:$ORIGINAL_USER" server_manager.sh server_bot.sh anticheat_secure.sh blockheads_common.sh "$SERVER_BINARY" 2>/dev/null || true
chmod 755 server_manager.sh server_bot.sh anticheat_secure.sh blockheads_common.sh "$SERVER_BINARY" 2>/dev/null || true

sudo -u "$ORIGINAL_USER" bash -c 'echo "{\"players\": {}, \"transactions\": []}" > economy_data.json' 2>/dev/null || true
chown "$ORIGINAL_USER:$ORIGINAL_USER" economy_data.json 2>/dev/null || true

rm -f "$TEMP_FILE"

print_success "Installation completed successfully"
print_status "1. Create a world: ./blockheads_server171 -n"
print_status "2. Start server: ./server_manager.sh start WORLD_ID PORT"
print_status "3. Default port: 12153"
print_warning "After creating the world, press CTRL+C to exit"
