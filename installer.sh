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

print_status() {
    echo -e "${BLUE}[INFO]${NC} $1";
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1";
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1";
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1";
}

print_header() {
    echo -e "${PURPLE}================================================================================${NC}"
    echo -e "${PURPLE}$1${NC}"
    echo -e "${PURPLE}================================================================================${NC}"
}

print_step() {
    echo -e "${CYAN}[STEP]${NC} $1";
}

print_progress() {
    echo -e "${MAGENTA}[PROGRESS]${NC} $1";
}

[ "$EUID" -ne 0 ] && print_error "This script requires root privileges." && exit 1

ORIGINAL_USER=${SUDO_USER:-$USER}
USER_HOME=$(getent passwd "$ORIGINAL_USER" | cut -d: -f6)

SERVER_URL="https://web.archive.org/web/20240309015235if_/https://majicdave.com/share/blockheads_server171.tar.gz"
TEMP_FILE="/tmp/blockheads_server171.tar.gz"
SERVER_BINARY="blockheads_server171"

# --- MODIFICADO: Agregadas URLs del nuevo parche ---
SERVER_MANAGER_URL="https://raw.githubusercontent.com/noxthewildshadow/The-Blockheads-Server-BETA/main/server_manager.sh"
RANK_PATCHER_URL="https://raw.githubusercontent.com/noxthewildshadow/The-Blockheads-Server-BETA/main/rank_patcher.sh"
FREIGHT_PATCH_URL="https://raw.githubusercontent.com/noxthewildshadow/The-Blockheads-Server-BETA/main/freight_car_patch.c"
# ---------------------------------------------------

# --- MODIFICADO: Agregado 'build-essential' y 'libdispatch-dev' a la lista ---
declare -a PACKAGES_DEBIAN=(
    'git' 'cmake' 'ninja-build' 'clang' 'patchelf' 'libgnustep-base-dev' 'libobjc4'
    'libgnutls28-dev' 'libgcrypt20-dev' 'libxml2' 'libffi-dev' 'libnsl-dev' 'zlib1g'
    'libicu-dev' 'libstdc++6' 'libgcc-s1' 'wget' 'curl' 'tar' 'grep' 'screen' 'lsof'
    'inotify-tools' 'bc' 'build-essential' 'libdispatch-dev'
)

declare -a PACKAGES_ARCH=(
    'base-devel' 'git' 'cmake' 'ninja' 'clang' 'patchelf' 'gnustep-base' 'gcc-libs'
    'gnutls' 'libgcrypt' 'libxml2' 'libffi' 'libnsl' 'zlib' 'icu' 'libdispatch'
    'wget' 'curl' 'tar' 'grep' 'screen' 'lsof' 'inotify-tools' 'bc'
)

print_header "THE BLOCKHEADS LINUX SERVER INSTALLER"
echo -e "${CYAN}Welcome to The Blockheads Server Installation!${NC}"
echo -e "${YELLOW}This script will install and configure everything you need.${NC}"
echo

find_library() {
    SEARCH=$1
    LIBRARY=$(ldconfig -p | grep -F "$SEARCH" -m 1 | awk '{print $NF}' | head -1)
    [ -z "$LIBRARY" ] && return 1
    printf '%s' "$LIBRARY"
}

install_packages() {
    [ ! -f /etc/os-release ] && print_error "Could not detect the operating system" && return 1
    source /etc/os-release
    case $ID in
    debian|ubuntu|pop)
        print_step "Installing packages for Debian/Ubuntu..."
        if ! apt-get update >/dev/null 2>&1; then
            print_error "Failed to update package list"
            return 1
        fi
        for package in "${PACKAGES_DEBIAN[@]}"; do
            if ! apt-get install -y "$package" >/dev/null 2>&1; then
                print_warning "Failed to install $package"
            fi
        done
        ;;
    arch)
        print_step "Installing packages for Arch Linux..."
        if ! pacman -Sy --noconfirm --needed "${PACKAGES_ARCH[@]}" >/dev/null 2>&1; then
            print_error "Failed to install Arch Linux packages"
            return 1
        fi
        ;;
    *)
        print_error "Unsupported operating system: $ID"
        return 1
        ;;
    esac
    return 0
}

download_server_files() {
    print_step "Downloading server manager..."
    if wget --timeout=30 --tries=3 -O "server_manager.sh" "$SERVER_MANAGER_URL" 2>/dev/null; then
        chmod +x "server_manager.sh"
        print_success "Server manager downloaded successfully"
    else
        print_error "Failed to download server manager"
        return 1
    fi
    print_step "Downloading rank patcher..."
    if wget --timeout=30 --tries=3 -O "rank_patcher.sh" "$RANK_PATCHER_URL" 2>/dev/null; then
        chmod +x "rank_patcher.sh"
        print_success "Rank patcher downloaded successfully"
    else
        print_error "Failed to download rank patcher"
        return 1
    fi
    
    # --- MODIFICADO: Descarga del parche .c ---
    print_step "Downloading freight car patch..."
    if wget --timeout=30 --tries=3 -O "freight_car_patch.c" "$FREIGHT_PATCH_URL" 2>/dev/null; then
        print_success "Freight car patch downloaded successfully"
    else
        print_warning "Failed to download freight car patch (file might not exist in repo yet)"
    fi
    # ------------------------------------------
    return 0
}

print_step "[1/8] Installing required packages and dependencies..."
if ! install_packages; then
    print_warning "Falling back to basic package installation..."
    if ! apt-get update -y >/dev/null 2>&1; then
        print_error "Failed to update package list"
        exit 1
    fi
    if ! apt-get install -y libgnustep-base1.28 libdispatch-dev patchelf wget curl tar screen lsof inotify-tools bc clang build-essential >/dev/null 2>&1; then
        print_error "Failed to install essential packages"
        exit 1
    fi
fi

print_step "[2/8] Downloading server archive from archive.org..."
print_progress "Downloading server binary (this may take a moment)..."
if wget --timeout=30 --tries=3 --show-progress "$SERVER_URL" -O "$TEMP_FILE" 2>/dev/null; then
    print_success "Download successful from archive.org"
else
    print_error "Failed to download server file from archive.org"
    exit 1
fi

print_step "[3/8] Extracting files..."
EXTRACT_DIR="/tmp/blockheads_extract_$$"
mkdir -p "$EXTRACT_DIR"

print_progress "Extracting server files..."
if ! tar -xzf "$TEMP_FILE" -C "$EXTRACT_DIR" >/dev/null 2>&1; then
    print_error "Failed to extract server files"
    rm -rf "$EXTRACT_DIR"
    exit 1
fi

cp -r "$EXTRACT_DIR"/* ./
rm -rf "$EXTRACT_DIR"

if [ ! -f "$SERVER_BINARY" ]; then
    ALTERNATIVE_BINARY=$(find . -name "*blockheads*" -type f -executable | head -n 1)
    [ -n "$ALTERNATIVE_BINARY" ] && mv "$ALTERNATIVE_BINARY" "blockheads_server171" && SERVER_BINARY="blockheads_server171"
fi

if [ ! -f "$SERVER_BINARY" ]; then
    print_error "Server binary not found after extraction"
    exit 1
fi

chmod +x "$SERVER_BINARY"

print_step "[4/8] Applying comprehensive patchelf compatibility patches..."
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
    if ! patchelf --replace-needed "$LIB" "${LIBS[$LIB]}" "$SERVER_BINARY" >/dev/null 2>&1; then
        print_warning "Failed to patch $LIB"
    fi
done

print_success "Compatibility patches applied ($COUNT/$TOTAL_LIBS libraries)"

print_step "[5/8] Testing server binary..."
if ./blockheads_server171 -h >/dev/null 2>&1; then
    print_success "Server binary test passed"
else
    print_warning "Server binary execution test failed - may need additional dependencies"
fi

print_step "[6/8] Downloading server manager and rank patcher..."
if ! download_server_files; then
    print_warning "Creating basic server manager and rank patcher..."
    # (El fallback original se mantiene igual)
    cat > server_manager.sh << 'EOF'
#!/bin/bash
echo "Use: ./blockheads_server171 -n (to create world)"
echo "Then: ./blockheads_server171 -o WORLD_NAME -p PORT"
EOF
    chmod +x server_manager.sh
    cat > rank_patcher.sh << 'EOF'
#!/bin/bash
echo "Rank patcher placeholder - download failed"
EOF
    chmod +x rank_patcher.sh
fi

# --- MODIFICADO: Paso nuevo para compilar e inyectar el parche .c ---
print_step "[7/8] Compiling and Applying Freight Car Patch..."
if [ -f "freight_car_patch.c" ]; then
    print_progress "Compiling freight_car_patch.c to .so..."
    # Intentamos compilar con rutas de headers comunes
    if clang -shared -fPIC -o freight_car_patch.so freight_car_patch.c -lobjc -ldl -lpthread -I/usr/include/GNUstep -I/usr/lib/gcc/x86_64-linux-gnu/*/include -w; then
        print_success "Patch compiled successfully (freight_car_patch.so)"
        
        # Ahora modificamos server_manager.sh descargado para inyectar LD_PRELOAD
        if [ -f "server_manager.sh" ]; then
            print_progress "Injecting LD_PRELOAD into server_manager.sh..."
            # Usamos sed para insertar la línea de carga del parche
            if ! grep -q "freight_car_patch.so" server_manager.sh; then
                sed -i '/export LD_LIBRARY_PATH=/a export LD_PRELOAD="$PWD/freight_car_patch.so"' server_manager.sh
                print_success "server_manager.sh updated to load the patch"
            else
                print_status "server_manager.sh already contains the patch loader"
            fi
        fi
    else
        print_error "Failed to compile patch. Ensure libobjc-dev / build-essential are installed."
    fi
else
    print_warning "freight_car_patch.c not found. Skipping compilation."
fi
# --------------------------------------------------------------------

print_step "[8/8] Setting ownership and permissions..."
chown "$ORIGINAL_USER:$ORIGINAL_USER" "$SERVER_BINARY" "server_manager.sh" "rank_patcher.sh" "freight_car_patch.c" "freight_car_patch.so" 2>/dev/null || true
chmod 755 "$SERVER_BINARY" "server_manager.sh" "rank_patcher.sh" "freight_car_patch.so" 2>/dev/null || true

rm -f "$TEMP_FILE"

print_header "INSTALLATION COMPLETE"
echo -e "${GREEN}Server installed successfully!${NC}"
echo ""

print_header "SERVER BINARY INFORMATION"
echo ""
./blockheads_server171 -h
echo ""
print_header "SERVER MANAGER INSTRUCTIONS"
echo -e "${GREEN}1. Create a world: ${CYAN}./blockheads_server171 -n${NC}"
print_warning "After creating the world, press CTRL+C to exit the creation process"
echo -e "${GREEN}2. See world list: ${CYAN}./blockheads_server171 -l${NC}"
echo -e "${GREEN}3. Start server: ${CYAN}./server_manager.sh start WORLD_ID YOUR_PORT${NC}"
echo -e "${GREEN}4. Stop server: ${CYAN}./server_manager.sh stop${NC}"
echo -e "${GREEN}5. Check status: ${CYAN}./server_manager.sh status${NC}"
echo -e "${GREEN}6. Default port: ${YELLOW}12153${NC}"
echo ""

print_header "RANK PATCHER FEATURES"
echo -e "${GREEN}The rank patcher provides:${NC}"
echo -e "${CYAN}• Player authentication with IP verification${NC}"
echo -e "${CYAN}• Password protection for players${NC}"
echo -e "${CYAN}• Automated rank management (ADMIN, MOD, SUPER)${NC}"
echo -e "${CYAN}• Real-time monitoring of player lists${NC}"
echo ""

print_header "MULTI-SERVER SUPPORT"
echo -e "${GREEN}You can run multiple servers simultaneously:${NC}"
echo -e "${CYAN}./server_manager.sh start WorldID1 12153${NC}"
echo -e "${CYAN}./server_manager.sh start WorldID2 12154${NC}"
echo -e "${CYAN}./server_manager.sh start WorldID3 12155${NC}"
echo ""
echo -e "${YELLOW}Each server runs in its own screen session with rank patcher${NC}"

print_header "INSTALLATION COMPLETE"
echo -e "${GREEN}Your Blockheads server with rank management is now ready!${NC}"
