#!/bin/bash
# --- set -e HA SIDO ELIMINADO PARA EVITAR QUE SE DETENGA POR ERRORES ---

# --- Colores ---
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

# --- Funciones de Impresión ---
print_status() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_header() {
    echo -e "${PURPLE}================================================================================${NC}"
    echo -e "${PURPLE}$1${NC}"
    echo -e "${PURPLE}================================================================================${NC}"
}
print_step() { echo -e "${CYAN}[STEP]${NC} $1"; }
print_progress() { echo -e "${MAGENTA}[PROGRESS]${NC} $1"; }

# --- Comprobación de Root ---
[ "$EUID" -ne 0 ] && print_error "This script requires root privileges. Please run with: sudo $0" && exit 1

# --- Encontrar el usuario original ---
ORIGINAL_USER=${SUDO_USER:-$USER}
USER_HOME=$(getent passwd "$ORIGINAL_USER" | cut -d: -f6)
[ -z "$USER_HOME" ] && USER_HOME="/home/$ORIGINAL_USER" # Fallback

# --- URLs y Archivos ---
SERVER_URL="https://web.archive.org/web/20240309015235if_/https://majicdave.com/share/blockheads_server171.tar.gz"
TEMP_FILE="/tmp/blockheads_server171.tar.gz"
SERVER_BINARY="blockheads_server171"

# !!! ============================================================= !!!
# !!! ASEGÚRATE DE QUE ESTAS DOS URLs SEAN CORRECTAS EN TU ARCHIVO !!!
# !!! ============================================================= !!!
SERVER_MANAGER_URL="https://raw.githubusercontent.com/noxthewildshadow/The-Blockheads-Server-BETA/main/server_manager.sh" # URL al server_manager.sh CON log de paquetes únicos
RANK_PATCHER_URL="https://raw.githubusercontent.com/noxthewildshadow/The-Blockheads-Server-BETA/main/rank_patcher.sh"

# --- Listas de Paquetes (Python3/gawk añadidos) ---
declare -a PACKAGES_DEBIAN=(
    'git' 'cmake' 'ninja-build' 'clang' 'patchelf' 'libgnustep-base-dev' 'libobjc4'
    'libgnutls28-dev' 'libgcrypt20-dev' 'libxml2' 'libffi-dev' 'libnsl-dev' 'zlib1g'
    'libicu-dev' 'libstdc++6' 'libgcc-s1' 'wget' 'curl' 'tar' 'grep' 'screen' 'lsof'
    'inotify-tools' 'ngrep' 'binutils' 'gawk' 'python3' # <-- Python3 y gawk añadidos
)
declare -a PACKAGES_ARCH=(
    'base-devel' 'git' 'cmake' 'ninja' 'clang' 'patchelf' 'gnustep-base' 'gcc-libs'
    'gnutls' 'libgcrypt' 'libxml2' 'libffi' 'libnsl' 'zlib' 'icu' 'libdispatch'
    'wget' 'curl' 'tar' 'grep' 'screen' 'lsof' 'inotify-tools' 'ngrep' 'binutils' 'gawk' 'python' # <-- Python y gawk añadidos
)
# (Añadir yum/dnf si es necesario: python3, gawk)

print_header "THE BLOCKHEADS LINUX SERVER INSTALLER (VERBOSE MODE)"
echo -e "${CYAN}Welcome to The Blockheads Server Installation!${NC}"
echo -e "${YELLOW}This script will install and configure everything you need.${NC}"
echo

# --- Funciones Auxiliares ---
find_library() {
    local SEARCH=$1
    # Usar ldconfig -p que es más fiable y rápido
    local LIBRARY=$(ldconfig -p | grep -F "$SEARCH" -m 1 | awk '{print $NF}' | head -1)
    if [ -z "$LIBRARY" ]; then
        # Fallback: buscar en directorios comunes si ldconfig falla o no encuentra
        local common_paths=(/usr/lib /usr/lib64 /lib /lib64 /usr/lib/x86_64-linux-gnu /lib/x86_64-linux-gnu)
        for path in "${common_paths[@]}"; do
            LIBRARY=$(find "$path" -maxdepth 1 -name "$SEARCH*" -print -quit)
            [ -n "$LIBRARY" ] && break
        done
    fi
    [ -z "$LIBRARY" ] && return 1
    printf '%s' "$LIBRARY"
}

# --- Funciones Principales ---
install_packages() {
    [ ! -f /etc/os-release ] && print_error "Could not detect the operating system" && return 1
    source /etc/os-release

    print_step "[1/8] Installing system packages..."
    case $ID in
        debian|ubuntu|pop)
            print_status "Updating package lists (Debian/Ubuntu)..."
            apt-get update || print_warning "apt-get update failed"
            print_status "Installing ${#PACKAGES_DEBIAN[@]} packages..."
            for package in "${PACKAGES_DEBIAN[@]}"; do
                echo -n "  Installing $package... "
                if apt-get install -y "$package"; then echo -e "${GREEN}OK${NC}"; else echo -e "${RED}FAILED${NC}"; print_warning "Could not install $package"; fi
            done
            ;;
        arch)
             print_status "Installing ${#PACKAGES_ARCH[@]} packages (Arch)..."
             pacman -Sy || print_warning "pacman -Sy failed"
             if ! pacman -S --noconfirm --needed "${PACKAGES_ARCH[@]}"; then print_error "Failed to install some Arch Linux packages"; fi
             ;;
        *)
            print_error "Unsupported operating system: $ID"; return 1 ;;
    esac
    print_success "Package installation attempt complete."
    return 0
}

configure_sudoers() {
    print_step "[2/8] Configuring passwordless sudo for sniffer..."
    NGREP_PATH=$(which ngrep)
    if [ -z "$NGREP_PATH" ]; then print_warning "ngrep not found. Skipping sudo config."; return; fi
    SUDOERS_FILE="/etc/sudoers.d/blockheads_sniffer"
    print_status "Creating sudoers rule for user '$ORIGINAL_USER' for '$NGREP_PATH'"
    echo "$ORIGINAL_USER ALL=(ALL) NOPASSWD: $NGREP_PATH" | tee "$SUDOERS_FILE" > /dev/null
    chmod 440 "$SUDOERS_FILE"
    if visudo -c -f "$SUDOERS_FILE"; then print_success "Passwordless sudo configured."; else print_error "Failed to validate sudoers file. Removing."; rm -f "$SUDOERS_FILE"; print_warning "Manual 'sudo visudo' needed."; fi
}

download_files() {
    print_step "[3/8] Downloading Server Binary..."
    print_progress "Downloading from $SERVER_URL ..."
    if ! wget --timeout=60 --tries=5 --progress=bar:force -O "$TEMP_FILE" "$SERVER_URL" 2>&1; then print_error "Download failed: $SERVER_URL"; exit 1; fi
    print_success "Server binary downloaded."

    print_step "[4/8] Downloading Manager and Patcher scripts..."
    print_progress "Downloading server_manager.sh from $SERVER_MANAGER_URL ..."
    dl_manager_failed=0
    if [ -z "$SERVER_MANAGER_URL" ]; then print_error "SERVER_MANAGER_URL is empty!"; dl_manager_failed=1;
    elif ! wget --spider --timeout=10 "$SERVER_MANAGER_URL" 2>/dev/null; then print_error "Cannot reach URL: $SERVER_MANAGER_URL"; dl_manager_failed=1;
    elif ! wget --timeout=30 --tries=3 -O "server_manager.sh" "$SERVER_MANAGER_URL"; then print_error "Download failed: $SERVER_MANAGER_URL"; dl_manager_failed=1;
    else print_success "Server manager downloaded."; fi

    if [ "$dl_manager_failed" -eq 1 ]; then print_warning "Creating placeholder server_manager.sh"; cat > server_manager.sh << 'EOF_P1'; echo "ERROR: Download failed."; EOF_P1; chmod +x server_manager.sh; fi

    print_progress "Downloading rank_patcher.sh from $PATCHER_URL ..."
    dl_patcher_failed=0
     if [ -z "$RANK_PATCHER_URL" ]; then print_error "RANK_PATCHER_URL is empty!"; dl_patcher_failed=1;
    elif ! wget --spider --timeout=10 "$RANK_PATCHER_URL" 2>/dev/null; then print_error "Cannot reach URL: $RANK_PATCHER_URL"; dl_patcher_failed=1;
    elif ! wget --timeout=30 --tries=3 -O "rank_patcher.sh" "$RANK_PATCHER_URL"; then print_error "Download failed: $RANK_PATCHER_URL"; dl_patcher_failed=1;
    else print_success "Rank patcher downloaded."; fi

    if [ "$dl_patcher_failed" -eq 1 ]; then print_warning "Creating placeholder rank_patcher.sh"; cat > rank_patcher.sh << 'EOF_P2'; echo "ERROR: Download failed."; EOF_P2; chmod +x rank_patcher.sh; fi

    chmod +x "server_manager.sh" "rank_patcher.sh" 2>/dev/null || true
}


extract_and_patch() {
    print_step "[5/8] Extracting server files..."
    EXTRACT_DIR="/tmp/blockheads_extract_$$"; mkdir -p "$EXTRACT_DIR"
    if ! tar -xzf "$TEMP_FILE" -C "$EXTRACT_DIR"; then print_error "Failed to extract $TEMP_FILE"; ls -l "$TEMP_FILE"; rm -rf "$EXTRACT_DIR" "$TEMP_FILE"; exit 1; fi
    print_progress "Files extracted."
    shopt -s dotglob; mv "$EXTRACT_DIR"/* ./ 2>/dev/null || print_warning "Could not move all extracted files."; shopt -u dotglob
    rm -rf "$EXTRACT_DIR" "$TEMP_FILE"
    print_progress "Files moved."

    if [ ! -f "$SERVER_BINARY" ]; then
        ALTERNATIVE_BINARY=$(find . -maxdepth 1 -name "*blockheads*" -type f -executable -print -quit)
        if [ -n "$ALTERNATIVE_BINARY" ]; then print_warning "Renaming '$ALTERNATIVE_BINARY' to '$SERVER_BINARY'"; mv "$ALTERNATIVE_BINARY" "$SERVER_BINARY"; else print_error "Server binary not found!"; ls -l .; exit 1; fi
    fi
    chmod +x "$SERVER_BINARY"; print_success "Server binary ready."

    print_step "[6/8] Applying compatibility patches..."
    declare -A LIBS=( ["libgnustep-base.so.1.24"]="$(find_library 'libgnustep-base.so' || echo 'libgnustep-base.so.1.28')" ["libobjc.so.4.6"]="$(find_library 'libobjc.so' || echo 'libobjc.so.4')" ["libgnutls.so.26"]="$(find_library 'libgnutls.so' || echo 'libgnutls.so.30')" ["libgcrypt.so.11"]="$(find_library 'libgcrypt.so' || echo 'libgcrypt.so.20')" ["libffi.so.6"]="$(find_library 'libffi.so' || echo 'libffi.so.8')" ["libicui18n.so.48"]="$(find_library 'libicui18n.so' || echo 'libicui18n.so.70')" ["libicuuc.so.48"]="$(find_library 'libicuuc.so' || echo 'libicuuc.so.70')" ["libicudata.so.48"]="$(find_library 'libicudata.so' || echo 'libicudata.so.70')" ["libdispatch.so"]="$(find_library 'libdispatch.so' || echo 'libdispatch.so.0')" )
    local COUNT=0; local PATCHED_COUNT=0
    print_status "Attempting patches..."
    for LIB in "${!LIBS[@]}"; do
        TARGET_LIB="${LIBS[$LIB]}"; echo -n "  Patch $LIB -> $TARGET_LIB... "; if [ -z "$TARGET_LIB" ]; then echo -e "${YELLOW}SKIP (Target not found)${NC}"; continue; fi
        if ! ldconfig -p | grep -q "$(basename "$TARGET_LIB")" && [ ! -f "$TARGET_LIB" ] && [ ! -L "$TARGET_LIB" ]; then echo -e "${YELLOW}SKIP (Target '$TARGET_LIB' not on system)${NC}"; continue; fi
        ((COUNT++))
        if patchelf --replace-needed "$LIB" "$TARGET_LIB" "$SERVER_BINARY"; then echo -e "${GREEN}OK${NC}"; ((PATCHED_COUNT++)); else echo -e "${RED}FAILED${NC}"; patchelf --replace-needed "$LIB" "$TARGET_LIB" "$SERVER_BINARY" || true; print_warning "Patch failed for $LIB"; fi
    done
    print_success "Patches applied ($PATCHED_COUNT/$COUNT attempted)."
}

test_binary() {
    print_step "[7/8] Testing server binary execution..."; print_progress "Running '$SERVER_BINARY -h' as user '$ORIGINAL_USER'..."
    if sudo -u "$ORIGINAL_USER" ./$SERVER_BINARY -h; then print_success "Server binary test passed."; else print_warning "Server binary test FAILED. Check output."; fi
}

set_permissions() {
    print_step "[8/8] Setting final ownership and permissions..."; print_progress "Changing ownership to '$ORIGINAL_USER'..."
    chown -R "$ORIGINAL_USER:$ORIGINAL_USER" . || print_warning "Could not set ownership."
    print_progress "Setting execute permissions..."; chmod u+x "$SERVER_BINARY" "server_manager.sh" "rank_patcher.sh" 2>/dev/null || true # Ignorar error si placeholders no existen
    print_success "Permissions set."
}

# --- Ejecución ---
install_packages
configure_sudoers
download_files
extract_and_patch
test_binary
set_permissions

# --- Instrucciones Finales (Restauradas) ---
print_header "INSTALLATION COMPLETE"
echo -e "${GREEN}Server installed successfully!${NC}"
echo ""

print_header "SERVER BINARY INFORMATION"
echo ""
sudo -u "$ORIGINAL_USER" ./blockheads_server171 -h
echo ""
print_header "SERVER MANAGER INSTRUCTIONS"
echo -e "${YELLOW}¡IMPORTANTE! Ejecuta los siguientes comandos como tu usuario normal ('$ORIGINAL_USER'), NO como root.${NC}"
echo -e "${YELLOW}Puedes salir de root ahora escribiendo: exit${NC}"
echo ""
echo -e "${GREEN}1. Create a world: ${CYAN}./blockheads_server171 -n${NC}"
print_warning "   After creating the world, press CTRL+C to exit the creation process"
echo -e "${GREEN}2. See world list: ${CYAN}./blockheads_server171 -l${NC}"
echo -e "${GREEN}3. Start server: ${CYAN}./server_manager.sh start WORLD_ID YOUR_PORT${NC}"
echo -e "${GREEN}4. Stop server: ${CYAN}./server_manager.sh stop [PORT]${NC} (stops all if no port specified)"
echo -e "${GREEN}5. Check status: ${CYAN}./server_manager.sh status [PORT]${NC} (shows all if no port specified)"
echo -e "${GREEN}6. List running: ${CYAN}./server_manager.sh list${NC}"
echo -e "${GREEN}7. Default port: ${YELLOW}12153${NC}"
echo ""

print_header "RANK PATCHER FEATURES"
echo -e "${GREEN}The rank patcher (rank_patcher.sh, started by server_manager.sh) provides:${NC}"
echo -e "${CYAN}• Player authentication with IP verification${NC}"
echo -e "${CYAN}• Password protection for players (!psw, !change_psw, !ip_change)${NC}"
echo -e "${CYAN}• Automated rank management based on players.log (ADMIN, MOD, SUPER)${NC}"
echo -e "${CYAN}• Real-time monitoring of player lists and console log${NC}"
echo ""

print_header "PACKET SNIFFER (UNIQUE LOG)"
echo -e "${GREEN}The server manager also starts a packet sniffer automatically:${NC}"
echo -e "${CYAN}• It logs only UNIQUE packets sent/received on the server port.${NC}"
echo -e "${CYAN}• Log file: ${YELLOW}\$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves/WORLD_ID/packet_dump.log${NC}"
echo -e "${CYAN}• View live unique packets: ${YELLOW}tail -f <path_to_packet_dump.log>${NC}"
echo -e "${CYAN}• The screen session 'blockheads_sniffer_PORT' exists but will be BLANK (output is redirected).${NC}"
echo ""


print_header "MULTI-SERVER SUPPORT"
echo -e "${GREEN}You can run multiple servers simultaneously using different ports:${NC}"
echo -e "${CYAN}./server_manager.sh start WorldID1 12153${NC}"
echo -e "${CYAN}./server_manager.sh start WorldID2 12154${NC}"
echo -e "${CYAN}./server_manager.sh start WorldID3 12155${NC}"
echo ""
echo -e "${YELLOW}Each server runs in its own screen session with its own patcher and sniffer.${NC}"

print_header "INSTALLATION COMPLETE"
echo -e "${GREEN}Your Blockheads server with rank management and packet logger is now ready!${NC}"
