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

# Function to display a progress bar
progress_bar() {
    local PROG_BAR='####################'
    local BLANK_BAR='                    '
    local PROGRESS=$1
    printf "\r[%.*s%.*s] %d%%" $PROGRESS "$PROG_BAR" $((20-PROGRESS)) "$BLANK_BAR" $((PROGRESS*5))
}

# Function to find a library
find_library() {
    SEARCH=$1
    LIBRARY=$(ldconfig -p | grep -F "$SEARCH" -m 1 | awk '{print $1}')
    if [ -z "$LIBRARY" ]; then
        return 1
    fi
    printf '%s' "$LIBRARY"
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
SERVER_URLS=(
    "https://drive.usercontent.google.com/u/0/uc?id=1x6q7OyDr3NWG5pCnm9Zxxfet0GzUkYLb&export=download"
    "https://drive.usercontent.google.com/u/0/uc?id=1x6q7OyDr3NWG5pCnm9Zxxfet0GzUkYLb&export=download"
)
TEMP_FILE="/tmp/blockheads_server171.tar.gz"
SERVER_BINARY="blockheads_server171"

# Raw URLs for helper scripts
RAW_BASE="https://raw.githubusercontent.com/noxthewildshadow/The-Blockheads-Server-BETA/refs/heads/main"
SERVER_MANAGER_URL="$RAW_BASE/server_manager.sh"
BOT_SCRIPT_URL="$RAW_BASE/server_bot.sh"
ANTICHEAT_SCRIPT_URL="$RAW_BASE/anticheat_secure.sh"

# Package lists for different distributions
declare -a PACKAGES_DEBIAN=(
    'git' 'cmake' 'ninja-build' 'clang' 'systemtap-sdt-dev' 'libbsd-dev' 'linux-libc-dev'
    'curl' 'tar' 'grep' 'mawk' 'patchelf' '^libgnustep-base1\.[0-9]*$' 'libobjc4'
    '^libgnutls[0-9]*$' '^libgcrypt[0-9]*$' 'libxml2' '^libffi[0-9]*$' '^libnsl[0-9]*$'
    'zlib1g' '^libicu[0-9]*$' 'libicu-dev' 'libstdc++6' 'libgcc-s1' 'wget' 'jq' 'screen' 'lsof'
)

declare -a PACKAGES_ARCH=(
    'base-devel' 'git' 'cmake' 'ninja' 'clang' 'systemtap' 'libbsd' 'curl' 'tar' 'grep'
    'gawk' 'patchelf' 'gnustep-base' 'gcc-libs' 'gnutls' 'libgcrypt' 'libxml2' 'libffi'
    'libnsl' 'zlib' 'icu' 'libdispatch' 'wget' 'jq' 'screen' 'lsof'
)

print_header "THE BLOCKHEADS LINUX SERVER INSTALLER"
print_header "FOR NEW USERS: This script will install everything you need"
print_header "Please be patient as it may take several minutes"

# Function to build libdispatch from source
build_libdispatch() {
    print_step "Building libdispatch from source..."
    local DIR=$(pwd)
    if [ -d "${DIR}/swift-corelibs-libdispatch/build" ]; then
        rm -rf "${DIR}/swift-corelibs-libdispatch"
    fi
    
    if ! git clone --depth 1 'https://github.com/swiftlang/swift-corelibs-libdispatch.git' "${DIR}/swift-corelibs-libdispatch"; then
        print_error "Failed to clone libdispatch repository"
        return 1
    fi
    
    mkdir -p "${DIR}/swift-corelibs-libdispatch/build" || return 1
    cd "${DIR}/swift-corelibs-libdispatch/build" || return 1
    
    if ! cmake -G Ninja -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ ..; then
        print_error "CMake configuration failed for libdispatch"
        return 1
    fi
    
    if ! ninja "-j$(nproc)"; then
        print_error "Failed to build libdispatch"
        return 1
    fi
    
    if ! ninja install; then
        print_error "Failed to install libdispatch"
        return 1
    fi
    
    cd "${DIR}" || return 1
    ldconfig
    return 0
}

# Function to install packages based on distribution
install_packages() {
    if [ ! -f /etc/os-release ]; then
        print_error "Could not detect the operating system because /etc/os-release does not exist."
        return 1
    fi
    
    source /etc/os-release
    case $ID in
        debian|ubuntu|pop)
            print_step "Installing packages for Debian/Ubuntu..."
            apt-get update || return 1
            for package in "${PACKAGES_DEBIAN[@]}"; do
                if ! apt-get install -y "$package"; then
                    print_warning "Failed to install $package, trying to continue..."
                fi
            done
            
            # Check if libdispatch is available
            if ! find_library 'libdispatch.so'; then
                print_warning "libdispatch.so not found, building from source..."
                build_libdispatch
            fi
            ;;
        arch)
            print_step "Installing packages for Arch Linux..."
            pacman -Sy --noconfirm --needed "${PACKAGES_ARCH[@]}" || return 1
            ;;
        *)
            print_error "Unsupported operating system: $ID"
            return 1
            ;;
    esac
    
    return 0
}

print_step "[1/8] Installing required packages..."
if ! install_packages; then
    print_error "Failed to install required packages"
    print_status "Trying alternative approach..."
    
    # Fallback to basic package installation
    apt-get update -y
    apt-get install -y libgnustep-base1.28 libdispatch-dev patchelf wget jq screen lsof software-properties-common || {
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

print_step "[3/8] Downloading server archive..."
DOWNLOAD_SUCCESS=0
for URL in "${SERVER_URLS[@]}"; do
    print_status "Trying: $URL"
    if wget -q --timeout=30 --tries=2 "$URL" -O "$TEMP_FILE"; then
        DOWNLOAD_SUCCESS=1
        print_success "Download successful from $URL"
        break
    else
        print_warning "Failed to download from $URL"
    fi
done

if [ $DOWNLOAD_SUCCESS -eq 0 ]; then
    print_error "Failed to download server file from all sources."
    exit 1
fi

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

print_step "[5/8] Applying comprehensive patchelf compatibility patches..."
# Define libraries to patch
declare -A LIBS=(
    ["libgnustep-base.so.1.24"]="$(find_library 'libgnustep-base.so' || echo 'libgnustep-base.so.1.28')"
    ["libobjc.so.4.6"]="$(find_library 'libobjc.so' || echo 'libobjc.so.4')"
    ["libgnutls.so.26"]="$(find_library 'libgnutls.so' || echo 'libgnutls.so.30')"
    ["libgcrypt.so.11"]="$(find_library 'libgcrypt.so' || echo 'libgcrypt.so.20')"
    ["libffi.so.6"]="$(find_library 'libffi.so' || echo 'libffi.so.8')"
    ["libicui18n.so.48"]="$(find_library 'libicui18n.so' || echo 'libicui18n.so.70')"
    ["libicuuc.so.48"]="$(find_library 'libicuuc.so' || echo 'libicuuc.so.70')"
    ["libicudata.so.48"]="$(find_library 'libicudata.so' || echo 'libicudata.so.70')"
    ["libdispatch.so"]="$(find_library 'libdispatch.so' || echo 'libdispatch.so.0')"
)

TOTAL_LIBS=${#LIBS[@]}
COUNT=0

for LIB in "${!LIBS[@]}"; do
    if [ -z "${LIBS[$LIB]}" ]; then
        print_warning "Failed to locate up-to-date matching library for $LIB, skipping..."
        continue
    fi
    COUNT=$((COUNT+1))
    PERCENTAGE=$((COUNT * 100 / TOTAL_LIBS / 5))
    echo -n "Patching $LIB -> ${LIBS[$LIB]} "
    progress_bar $PERCENTAGE
    if ! patchelf --replace-needed "$LIB" "${LIBS[$LIB]}" "$SERVER_BINARY"; then
        print_warning "Failed to patch $LIB, trying to continue..."
    fi
done

echo -e "\n"
print_success "Compatibility patches applied"

print_step "[6/8] Set ownership and permissions for helper scripts and binary"
chown "$ORIGINAL_USER:$ORIGINAL_USER" server_manager.sh server_bot.sh anticheat_secure.sh "$SERVER_BINARY" ./*.json 2>/dev/null || true
chmod 755 server_manager.sh server_bot.sh anticheat_secure.sh "$SERVER_BINARY" ./*.json 2>/dev/null || true
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
print_header "NEW FEATURES"
print_status "Added anticheat system: anticheat_secure.sh"
print_status "New player commands: !give_rank_mod and !give_rank_admin"
print_status "All data files are now stored with the server world data"
print_header "NEED HELP?"
print_status "Visit the GitHub repository for more information:"
print_status "https://github.com/noxthewildshadow/The-Blockheads-Server-BETA"
print_header "INSTALLATION COMPLETE"
