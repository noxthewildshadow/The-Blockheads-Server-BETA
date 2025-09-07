#!/bin/bash
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
ORANGE='\033[0;33m'
PURPLE='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

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

progress_bar() {
    local PROG_BAR='####################'
    local BLANK_BAR='                    '
    local PROGRESS=$1
    printf "\r[%.*s%.*s] %d%%" $PROGRESS "$PROG_BAR" $((20-PROGRESS)) "$BLANK_BAR" $((PROGRESS*5))
}

find_library() {
    SEARCH=$1
    LIBRARY=$(ldconfig -p | grep -F "$SEARCH" -m 1 | awk '{print $1}')
    [ -z "$LIBRARY" ] && return 1
    printf '%s' "$LIBRARY"
}

[ "$EUID" -ne 0 ] && print_error "This script requires root privileges." && exit 1

ORIGINAL_USER=${SUDO_USER:-$USER}
USER_HOME=$(getent passwd "$ORIGINAL_USER" | cut -d: -f6)

SERVER_URLS=(
    "https://github.com/noxthewildshadow/The-Blockheads-Server-BETA/releases/download/1.0/blockheads_server171.tar"
    "https://github.com/noxthewildshadow/The-Blockheads-Server-BETA/releases/download/1.0/blockheads_server171.tar"
)
TEMP_FILE="/tmp/blockheads_server171.tar"
SERVER_BINARY="blockheads_server171"

RAW_BASE="https://raw.githubusercontent.com/noxthewildshadow/The-Blockheads-Server-BETA/refs/heads/main"
SERVER_MANAGER_URL="$RAW_BASE/server_manager.sh"
BOT_SCRIPT_URL="$RAW_BASE/server_bot.sh"
ANTICHEAT_SCRIPT_URL="$RAW_BASE/anticheat_secure.sh"

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

build_libdispatch() {
    print_step "Building libdispatch from source..."
    local DIR=$(pwd)
    [ -d "${DIR}/swift-corelibs-libdispatch/build" ] && rm -rf "${DIR}/swift-corelibs-libdispatch"
    
    git clone --depth 1 'https://github.com/swiftlang/swift-corelibs-libdispatch.git' "${DIR}/swift-corelibs-libdispatch" || return 1
    
    mkdir -p "${DIR}/swift-corelibs-libdispatch/build" || return 1
    cd "${DIR}/swift-corelibs-libdispatch/build" || return 1
    
    cmake -G Ninja -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ .. || return 1
    ninja "-j$(nproc)" || return 1
    ninja install || return 1
    
    cd "${DIR}" || return 1
    ldconfig
    return 0
}

install_packages() {
    [ ! -f /etc/os-release ] && print_error "Could not detect the operating system" && return 1
    
    source /etc/os-release
    case $ID in
        debian|ubuntu|pop)
            print_step "Installing packages for Debian/Ubuntu..."
            apt-get update || return 1
            for package in "${PACKAGES_DEBIAN[@]}"; do
                apt-get install -y "$package" || print_warning "Failed to install $package"
            done
            
            find_library 'libdispatch.so' || build_libdispatch
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
install_packages || {
    apt-get update -y
    apt-get install -y libgnustep-base1.28 libdispatch-dev patchelf wget jq screen lsof software-properties-common || {
        print_error "Failed to install packages"
        exit 1
    }
}

print_step "[2/8] Downloading helper scripts from GitHub..."
wget -q -O server_manager.sh "$SERVER_MANAGER_URL" || {
    SERVER_MANAGER_URL="https://raw.githubusercontent.com/noxthewildshadow/The-Blockheads-Server-BETA/main/server_manager.sh"
    wget -q -O server_manager.sh "$SERVER_MANAGER_URL" || {
        print_error "Failed to download server_manager.sh"
        exit 1
    }
}

wget -q -O server_bot.sh "$BOT_SCRIPT_URL" || {
    BOT_SCRIPT_URL="https://raw.githubusercontent.com/noxthewildshadow/The-Blockheads-Server-BETA/main/server_bot.sh"
    wget -q -O server_bot.sh "$BOT_SCRIPT_URL" || {
        print_error "Failed to download server_bot.sh"
        exit 1
    }
}

wget -q -O anticheat_secure.sh "$ANTICHEAT_SCRIPT_URL" || {
    ANTICHEAT_SCRIPT_URL="https://raw.githubusercontent.com/noxthewildshadow/The-Blockheads-Server-BETA/main/anticheat_secure.sh"
    wget -q -O anticheat_secure.sh "$ANTICHEAT_SCRIPT_URL" || {
        print_error "Failed to download anticheat_secure.sh"
        exit 1
    }
}

chmod +x server_manager.sh server_bot.sh anticheat_secure.sh

print_step "[3/8] Downloading server archive..."
DOWNLOAD_SUCCESS=0
for URL in "${SERVER_URLS[@]}"; do
    print_status "Trying: $URL"
    wget -q --timeout=30 --tries=2 "$URL" -O "$TEMP_FILE" && {
        DOWNLOAD_SUCCESS=1
        print_success "Download successful from $URL"
        break
    } || print_warning "Failed to download from $URL"
done

[ $DOWNLOAD_SUCCESS -eq 0 ] && print_error "Failed to download server file" && exit 1

print_step "[4/8] Extracting files..."
EXTRACT_DIR="/tmp/blockheads_extract_$$"
mkdir -p "$EXTRACT_DIR"

tar -xf "$TEMP_FILE" -C "$EXTRACT_DIR" || {
    print_error "Failed to extract server files"
    rm -rf "$EXTRACT_DIR"
    exit 1
}

cp -r "$EXTRACT_DIR"/* ./
rm -rf "$EXTRACT_DIR"

[ ! -f "$SERVER_BINARY" ] && {
    ALTERNATIVE_BINARY=$(find . -name "*blockheads*" -type f -executable | head -n 1)
    [ -n "$ALTERNATIVE_BINARY" ] && mv "$ALTERNATIVE_BINARY" "blockheads_server171" && SERVER_BINARY="blockheads_server171"
}

chmod +x "$SERVER_BINARY"

print_step "[5/8] Applying comprehensive patchelf compatibility patches..."
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
    [ -z "${LIBS[$LIB]}" ] && continue
    COUNT=$((COUNT+1))
    PERCENTAGE=$((COUNT * 100 / TOTAL_LIBS / 5))
    echo -n "Patching $LIB -> ${LIBS[$LIB]} "
    progress_bar $PERCENTAGE
    patchelf --replace-needed "$LIB" "${LIBS[$LIB]}" "$SERVER_BINARY" || print_warning "Failed to patch $LIB"
done

echo -e "\n"
print_success "Compatibility patches applied"

print_step "[6/8] Set ownership and permissions"
chown "$ORIGINAL_USER:$ORIGINAL_USER" server_manager.sh server_bot.sh anticheat_secure.sh "$SERVER_BINARY" ./*.json 2>/dev/null || true
chmod 755 server_manager.sh server_bot.sh anticheat_secure.sh "$SERVER_BINARY" ./*.json 2>/dev/null || true

print_step "[7/8] Create economy data file"
sudo -u "$ORIGINAL_USER" bash -c 'echo "{\"players\": {}, \"transactions\": []}" > economy_data.json' || true
chown "$ORIGINAL_USER:$ORIGINAL_USER" economy_data.json 2>/dev/null || true

rm -f "$TEMP_FILE"

print_step "[8/8] Installation completed successfully"
echo ""
print_header "BINARY INSTRUCTIONS"

./blockheads_server171 -h

print_header "SERVER MANAGER INSTRUCTIONS"
print_status "1. Create a world: ./blockheads_server171 -n"
print_status "2. Start server: ./server_manager.sh start WORLD_ID PORT"
print_status "3. Stop server: ./server_manager.sh stop"
print_status "4. Check status: ./server_manager.sh status"
print_status "5. Default port: 12153"
print_status "6. HELP: ./server_manager.sh help"
print_warning "After creating the world, press CTRL+C to exit"
print_header "INSTALLATION COMPLETE"
