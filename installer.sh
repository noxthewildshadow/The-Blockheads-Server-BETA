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

# URLs de tus scripts en GitHub (Asegúrate que sean correctas)
SERVER_MANAGER_URL="https://raw.githubusercontent.com/noxthewildshadow/The-Blockheads-Server-BETA/main/server_manager.sh"
RANK_PATCHER_URL="https://raw.githubusercontent.com/noxthewildshadow/The-Blockheads-Server-BETA/main/rank_patcher.sh"

declare -a PACKAGES_DEBIAN=(
    'git' 'cmake' 'ninja-build' 'clang' 'patchelf' 'libgnustep-base-dev' 'libobjc4'
    'libgnutls28-dev' 'libgcrypt20-dev' 'libxml2' 'libffi-dev' 'libnsl-dev' 'zlib1g'
    'libicu-dev' 'libstdc++6' 'libgcc-s1' 'wget' 'curl' 'tar' 'grep' 'screen' 'lsof'
    'inotify-tools' 'binutils' # Añadido binutils explícitamente
)

declare -a PACKAGES_ARCH=(
    'base-devel' 'git' 'cmake' 'ninja' 'clang' 'patchelf' 'gnustep-base' 'gcc-libs'
    'gnutls' 'libgcrypt' 'libxml2' 'libffi' 'libnsl' 'zlib' 'icu' 'libdispatch'
    'wget' 'curl' 'tar' 'grep' 'screen' 'lsof' 'inotify-tools' 'binutils' # Añadido binutils explícitamente
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
        print_error "Failed to download server manager from $SERVER_MANAGER_URL"
        return 1
    fi

    print_step "Downloading rank patcher..."
    if wget --timeout=30 --tries=3 -O "rank_patcher.sh" "$RANK_PATCHER_URL" 2>/dev/null; then
        chmod +x "rank_patcher.sh"
        print_success "Rank patcher downloaded successfully"
    else
        print_error "Failed to download rank patcher from $RANK_PATCHER_URL"
        return 1
    fi

    return 0
}

# --- Inicio de la Instalación ---

print_step "[1/7] Installing required packages and dependencies..."
if ! install_packages; then
    print_warning "Falling back to basic package installation..."
    if ! apt-get update -y >/dev/null 2>&1; then
        print_error "Failed to update package list"
        exit 1
    fi
    # Instalar solo los esenciales si falla el método completo
    if ! apt-get install -y libgnustep-base-dev libobjc4 libdispatch-dev patchelf wget curl tar screen lsof inotify-tools binutils >/dev/null 2>&1; then
        print_error "Failed to install essential packages"
        exit 1
    fi
fi

print_step "[2/7] Downloading server archive from archive.org..."
print_progress "Downloading server binary (this may take a moment)..."
# Usar --show-progress para feedback, pero redirigir stderr para ocultar otros mensajes de wget
if wget --timeout=60 --tries=5 --show-progress "$SERVER_URL" -O "$TEMP_FILE" 2>&1 | grep --line-buffered "%" | sed -u -e "s,\.,,g" | awk '{printf("\b\b\b\b%4s", $2)}'; then
    echo -e "\b\b\b\b100%" # Asegura mostrar 100% al final
    print_success "Download successful from archive.org"
else
    print_error "Failed to download server file from archive.org"
    exit 1
fi


print_step "[3/7] Extracting files..."
EXTRACT_DIR="/tmp/blockheads_extract_$$"
mkdir -p "$EXTRACT_DIR"

print_progress "Extracting server files..."
if ! tar -xzf "$TEMP_FILE" -C "$EXTRACT_DIR" >/dev/null 2>&1; then
    print_error "Failed to extract server files from $TEMP_FILE"
    rm -rf "$EXTRACT_DIR" "$TEMP_FILE"
    exit 1
fi

# Mover contenido al directorio actual
shopt -s dotglob
mv "$EXTRACT_DIR"/* ./ 2>/dev/null || print_warning "Could not move all extracted files, some might already exist."
shopt -u dotglob
rm -rf "$EXTRACT_DIR" "$TEMP_FILE" # Limpiar temp file aquí


if [ ! -f "$SERVER_BINARY" ]; then
    ALTERNATIVE_BINARY=$(find . -maxdepth 1 -iname "*blockheads*server*" -type f -executable -print -quit)
     if [ -z "$ALTERNATIVE_BINARY" ]; then
          ALTERNATIVE_BINARY=$(find . -maxdepth 1 -iname "*blockheads*" -type f -executable -print -quit)
     fi
     if [ -n "$ALTERNATIVE_BINARY" ] && [ "$ALTERNATIVE_BINARY" != "./$SERVER_BINARY" ]; then
          print_warning "Server binary named '$SERVER_BINARY' not found, renaming '$ALTERNATIVE_BINARY'"
          mv "$ALTERNATIVE_BINARY" "$SERVER_BINARY"
     elif [ ! -f "$SERVER_BINARY" ]; then
          print_error "Server binary ('$SERVER_BINARY' or similar) not found after extraction!"
          ls -lA . # Mostrar contenido del directorio
          exit 1
     fi
fi

chmod +x "$SERVER_BINARY"

print_step "[4/7] Applying comprehensive patchelf compatibility patches..."
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
PATCHED_COUNT=0

print_status "Attempting patches..."
for LIB in "${!LIBS[@]}"; do
    TARGET_LIB="${LIBS[$LIB]}"
    echo -n "  Patch $LIB -> $TARGET_LIB... "
    if [ -z "$TARGET_LIB" ]; then echo -e "${YELLOW}SKIP (Target empty)${NC}"; continue; fi
    if ! ldconfig -p | grep -q "$(basename "$TARGET_LIB")" && [ ! -f "$TARGET_LIB" ] && [ ! -L "$TARGET_LIB" ]; then echo -e "${YELLOW}SKIP (Target missing)${NC}"; continue; fi
    # Verificar si es necesario
    if ! ldd "$SERVER_BINARY" 2>/dev/null | grep -q "$LIB"; then echo -e "${BLUE}SKIP (Not needed)${NC}"; continue; fi
    ((COUNT++))
    if patchelf --replace-needed "$LIB" "$TARGET_LIB" "$SERVER_BINARY" >/dev/null 2>&1; then
        echo -e "${GREEN}OK${NC}"
        ((PATCHED_COUNT++))
    else
        patch_ec=$?
        echo -e "${RED}FAILED (Code:$patch_ec)${NC}"
        print_warning "Failed to patch $LIB."
    fi
done

print_success "Compatibility patches applied ($PATCHED_COUNT/$COUNT needed & attempted)"

print_step "[5/7] Testing server binary..."
# Ejecutar como usuario original, silenciar salida normal
if sudo -u "$ORIGINAL_USER" ./$SERVER_BINARY -h >/dev/null 2>&1; then
    print_success "Server binary test passed"
else
    print_warning "Server binary execution test failed - check dependencies manually using 'ldd ./$SERVER_BINARY'"
fi

print_step "[6/7] Downloading server manager and rank patcher..."
# Salir si falla la descarga de estos scripts cruciales
if ! download_server_files; then
    print_error "Failed to download required helper scripts. Aborting."
    exit 1
fi

print_step "[7/7] Setting ownership and permissions..."
# Cambiar propiedad de todo en el directorio actual al usuario original
chown -R "$ORIGINAL_USER:$ORIGINAL_USER" . 2>/dev/null || print_warning "Could not set ownership for current directory."
# Asegurar permisos de ejecución
chmod u+x "$SERVER_BINARY" "server_manager.sh" "rank_patcher.sh" 2>/dev/null || print_warning "Could not set execute permissions."

print_success "Ownership and permissions set."

# Limpieza final
# rm -f "$TEMP_FILE" # Comentado por si se necesita debug

print_header "INSTALLATION COMPLETE"
echo -e "${GREEN}Server installed successfully!${NC}"
echo ""

# --- INSTRUCCIONES FINALES (Restauradas de tu versión original) ---
print_header "SERVER BINARY INFORMATION"
echo ""
sudo -u "$ORIGINAL_USER" ./blockheads_server171 -h
echo ""
print_header "SERVER MANAGER INSTRUCTIONS"
echo -e "${GREEN}1. Create a world: ${CYAN}./blockheads_server171 -n${NC}"
print_warning "After creating the world, press CTRL+C to exit the creation process"
echo -e "${GREEN}2. See world list: ${CYAN}./blockheads_server171 -l${NC}"
echo -e "${GREEN}3. Start server: ${CYAN}./server_manager.sh start WORLD_ID YOUR_PORT${NC}"
echo -e "${GREEN}4. Stop server: ${CYAN}./server_manager.sh stop [PORT]${NC}"
echo -e "${GREEN}5. Check status: ${CYAN}./server_manager.sh status [PORT]${NC}"
echo -e "${GREEN}6. List running: ${CYAN}./server_manager.sh list${NC}" # Añadido 'list'
echo -e "${GREEN}7. Default port: ${YELLOW}12153${NC} (can be overridden)" # Aclarado
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

print_header "READY TO GO!" # Cambiado título final
echo -e "${GREEN}Your Blockheads server with rank management is now ready!${NC}"
print_warning "Remember to run server_manager.sh as '$ORIGINAL_USER', not root."
