#!/bin/bash
# --- set -e HA SIDO ELIMINADO PARA EVITAR QUE SE DETENGA POR ERRORES ---

# --- Colores ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; PURPLE='\033[0;35m'; NC='\033[0m'

# --- Funciones de Impresión ---
print_status() { echo -e "${BLUE}[INFO]${NC} $1"; }; print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }; print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }; print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_header() { echo -e "${PURPLE}================================================================================${NC}"; echo -e "${PURPLE}$1${NC}"; echo -e "${PURPLE}================================================================================${NC}"; }
print_step() { echo -e "${CYAN}[STEP]${NC} $1"; }; print_progress() { echo -e "${MAGENTA}[PROGRESS]${NC} $1"; }

# --- Comprobación de Root ---
# Necesario porque 'curl | sudo bash' ejecuta todo como root
if [ "$EUID" -ne 0 ]; then
    print_error "This script must be run as root. Use: curl ... | sudo bash"
    exit 1
fi

# --- Encontrar el usuario original ---
# Usar SUDO_USER es más fiable cuando se usa 'curl | sudo bash'
ORIGINAL_USER=${SUDO_USER:-$(logname 2>/dev/null || whoami)} # whoami como último recurso
if [ "$ORIGINAL_USER" == "root" ] && [ -n "$SUDO_USER" ]; then
    ORIGINAL_USER="$SUDO_USER" # Asegurar que no sea root si SUDO_USER existe
fi
USER_HOME=$(getent passwd "$ORIGINAL_USER" | cut -d: -f6)
# Fallback si getent falla (ej. en contenedores mínimos)
[ -z "$USER_HOME" ] && USER_HOME="/home/$ORIGINAL_USER"
# Crear HOME si no existe (puede pasar en algunos entornos)
mkdir -p "$USER_HOME" && chown "$ORIGINAL_USER:$ORIGINAL_USER" "$USER_HOME"

print_status "Detected original user as: ${YELLOW}$ORIGINAL_USER${NC}"
print_status "User home directory set to: ${CYAN}$USER_HOME${NC}"


# --- URLs y Archivos ---
SERVER_URL="https://web.archive.org/web/20240309015235if_/https://majicdave.com/share/blockheads_server171.tar.gz"
TEMP_FILE="/tmp/blockheads_server171.tar.gz.$$" # Añadir PID para evitar colisiones
SERVER_BINARY="blockheads_server171"

# !!! ============================================================= !!!
# !!! ASEGÚRATE DE QUE ESTAS DOS URLs SEAN CORRECTAS EN TU ARCHIVO !!!
# !!! ============================================================= !!!
SERVER_MANAGER_URL="https://raw.githubusercontent.com/noxthewildshadow/The-Blockheads-Server-BETA/main/server_manager.sh"
RANK_PATCHER_URL="https://raw.githubusercontent.com/noxthewildshadow/The-Blockheads-Server-BETA/main/rank_patcher.sh"

# --- Listas de Paquetes ---
declare -a PACKAGES_DEBIAN=('git' 'cmake' 'ninja-build' 'clang' 'patchelf' 'libgnustep-base-dev' 'libobjc4' 'libgnutls28-dev' 'libgcrypt20-dev' 'libxml2' 'libffi-dev' 'libnsl-dev' 'zlib1g' 'libicu-dev' 'libstdc++6' 'libgcc-s1' 'wget' 'curl' 'tar' 'grep' 'screen' 'lsof' 'inotify-tools' 'ngrep' 'binutils' 'gawk' 'python3')
declare -a PACKAGES_ARCH=('base-devel' 'git' 'cmake' 'ninja' 'clang' 'patchelf' 'gnustep-base' 'gcc-libs' 'gnutls' 'libgcrypt' 'libxml2' 'libffi' 'libnsl' 'zlib' 'icu' 'libdispatch' 'wget' 'curl' 'tar' 'grep' 'screen' 'lsof' 'inotify-tools' 'ngrep' 'binutils' 'gawk' 'python')

print_header "THE BLOCKHEADS LINUX SERVER INSTALLER (curl | bash compatible)"
echo -e "${CYAN}Welcome! This script will install and configure everything.${NC}"
echo

# --- Funciones Auxiliares ---
find_library() {
    local SEARCH=$1; local LIBRARY=$(ldconfig -p | grep -F "$SEARCH" -m 1 | awk '{print $NF}' | head -1)
    if [ -z "$LIBRARY" ]; then
        local common_paths=(/usr/lib /usr/lib64 /lib /lib64 /usr/lib/x86_64-linux-gnu /lib/x86_64-linux-gnu); for path in "${common_paths[@]}"; do LIBRARY=$(find "$path" -maxdepth 1 -name "$SEARCH*" -print -quit); [ -n "$LIBRARY" ] && break; done
    fi; [ -z "$LIBRARY" ] && return 1; printf '%s' "$LIBRARY"
}

# --- Funciones Principales ---
install_packages() {
    [ ! -f /etc/os-release ] && print_error "Could not detect OS" && return 1; source /etc/os-release
    print_step "[1/8] Installing system packages..."; local packages_to_install=()
    case $ID in
        debian|ubuntu|pop) print_status "Updating package lists (Debian/Ubuntu)..."; apt-get update || print_warning "apt-get update failed"; packages_to_install=("${PACKAGES_DEBIAN[@]}"); ;;
        arch) print_status "Syncing package database (Arch)..."; pacman -Sy || print_warning "pacman -Sy failed"; packages_to_install=("${PACKAGES_ARCH[@]}"); ;;
        *) print_error "Unsupported OS: $ID"; return 1 ;;
    esac
    print_status "Installing ${#packages_to_install[@]} packages..."
    local all_ok=1
    for package in "${packages_to_install[@]}"; do echo -n "  Installing $package... ";
        case $ID in
            debian|ubuntu|pop) if apt-get install -y "$package"; then echo -e "${GREEN}OK${NC}"; else echo -e "${RED}FAILED${NC}"; print_warning "Failed: $package"; all_ok=0; fi ;;
            arch) if pacman -S --noconfirm --needed "$package"; then echo -e "${GREEN}OK${NC}"; else echo -e "${RED}FAILED${NC}"; print_warning "Failed: $package"; all_ok=0; fi ;;
        esac
    done
    if [ "$all_ok" -eq 0 ]; then print_warning "Some packages failed to install."; else print_success "Package installation complete."; fi
    # Verificar esenciales
    local essential_pkgs=('wget' 'curl' 'tar' 'screen' 'lsof' 'ngrep' 'python3' 'python' 'gawk' 'binutils' 'patchelf'); local missing_essential=0
    for pkg_cmd in "${essential_pkgs[@]}"; do if ! command -v "$pkg_cmd" &> /dev/null; then case "$pkg_cmd" in python3|python) pkg_name="python3/python";; gawk) pkg_name="gawk/awk";; *) pkg_name="$pkg_cmd";; esac; print_error "Essential '$pkg_cmd' (package: $pkg_name) missing!"; missing_essential=1; fi; done
    [ "$missing_essential" -eq 1 ] && print_error "Essential packages missing. Aborting." && return 1
    return 0
}

configure_sudoers() {
    print_step "[2/8] Configuring passwordless sudo for sniffer..."; NGREP_PATH=$(which ngrep); if [ -z "$NGREP_PATH" ]; then print_warning "ngrep not found. Skipping."; return; fi
    SUDOERS_FILE="/etc/sudoers.d/blockheads_sniffer"; print_status "Creating rule for '$ORIGINAL_USER' for '$NGREP_PATH'"
    mkdir -p /etc/sudoers.d; echo "$ORIGINAL_USER ALL=(ALL) NOPASSWD: $NGREP_PATH" | tee "$SUDOERS_FILE" > /dev/null; chmod 440 "$SUDOERS_FILE"
    print_status "Validating rule..."; if visudo -c -f "$SUDOERS_FILE"; then print_success "Sudo configured."; else print_error "Validation FAILED."; rm -f "$SUDOERS_FILE"; print_warning "Manual 'sudo visudo' needed."; fi
}

download_files() {
    print_step "[3/8] Downloading Server Binary..."; print_progress "From $SERVER_URL ..."; if ! wget --timeout=60 --tries=5 --progress=bar:force -O "$TEMP_FILE" "$SERVER_URL" 2>&1; then print_error "Download failed: $SERVER_URL"; exit 1; fi; print_success "Server binary downloaded."
    print_step "[4/8] Downloading Manager and Patcher scripts..."

    print_progress "Downloading server_manager.sh from $SERVER_MANAGER_URL ...";
    # --- MODIFICADO: Salir si la descarga falla (sin placeholder) ---
    if [ -z "$SERVER_MANAGER_URL" ]; then print_error "SERVER_MANAGER_URL empty!"; exit 1;
    elif ! curl --output /dev/null --silent --head --fail --connect-timeout 10 "$SERVER_MANAGER_URL"; then print_error "Cannot reach URL: $SERVER_MANAGER_URL"; exit 1;
    elif ! wget --timeout=30 --tries=3 -O "server_manager.sh" "$SERVER_MANAGER_URL"; then print_error "Download failed: $SERVER_MANAGER_URL"; exit 1;
    else print_success "Manager downloaded."; fi

    print_progress "Downloading rank_patcher.sh from $PATCHER_URL ...";
     # --- MODIFICADO: Salir si la descarga falla (sin placeholder) ---
    if [ -z "$RANK_PATCHER_URL" ]; then print_error "RANK_PATCHER_URL empty!"; exit 1;
    elif ! curl --output /dev/null --silent --head --fail --connect-timeout 10 "$RANK_PATCHER_URL"; then print_error "Cannot reach URL: $RANK_PATCHER_URL"; exit 1;
    elif ! wget --timeout=30 --tries=3 -O "rank_patcher.sh" "$RANK_PATCHER_URL"; then print_error "Download failed: $RANK_PATCHER_URL"; exit 1;
    else print_success "Patcher downloaded."; fi

    chmod +x "server_manager.sh" "rank_patcher.sh" 2>/dev/null || true
}

extract_and_patch() {
    print_step "[5/8] Extracting server files..."; EXTRACT_DIR="/tmp/blockheads_extract_$$"; mkdir -p "$EXTRACT_DIR"
    if ! tar -xzf "$TEMP_FILE" -C "$EXTRACT_DIR"; then print_error "Extraction failed: $TEMP_FILE"; ls -l "$TEMP_FILE"; rm -rf "$EXTRACT_DIR" "$TEMP_FILE"; exit 1; fi; print_progress "Extracted."
    shopt -s dotglob; cp -r "$EXTRACT_DIR"/* ./ 2>/dev/null || print_warning "Copy failed."; shopt -u dotglob; rm -rf "$EXTRACT_DIR" "$TEMP_FILE"; print_progress "Moved."
    if [ ! -f "$SERVER_BINARY" ]; then ALT_BINARY=$(find . -maxdepth 1 -iname "*blockheads*server*" -type f -executable -print -quit); if [ -z "$ALT_BINARY" ]; then ALT_BINARY=$(find . -maxdepth 1 -iname "*blockheads*" -type f -executable -print -quit); fi; if [ -n "$ALT_BINARY" ] && [ "$ALT_BINARY" != "./$SERVER_BINARY" ]; then print_warning "Renaming '$ALT_BINARY' to '$SERVER_BINARY'"; mv "$ALT_BINARY" "$SERVER_BINARY"; elif [ ! -f "$SERVER_BINARY" ]; then print_error "Server binary not found!"; ls -lA .; exit 1; fi; fi
    chmod +x "$SERVER_BINARY"; print_success "Binary ready."
    print_step "[6/8] Applying compatibility patches..."; declare -A LIBS=( ["libgnustep-base.so.1.24"]="$(find_library 'libgnustep-base.so' || echo 'libgnustep-base.so.1.28')" ["libobjc.so.4.6"]="$(find_library 'libobjc.so' || echo 'libobjc.so.4')" ["libgnutls.so.26"]="$(find_library 'libgnutls.so' || echo 'libgnutls.so.30')" ["libgcrypt.so.11"]="$(find_library 'libgcrypt.so' || echo 'libgcrypt.so.20')" ["libffi.so.6"]="$(find_library 'libffi.so' || echo 'libffi.so.8')" ["libicui18n.so.48"]="$(find_library 'libicui18n.so' || echo 'libicui18n.so.70')" ["libicuuc.so.48"]="$(find_library 'libicuuc.so' || echo 'libicuuc.so.70')" ["libicudata.so.48"]="$(find_library 'libicudata.so' || echo 'libicudata.so.70')" ["libdispatch.so"]="$(find_library 'libdispatch.so' || echo 'libdispatch.so.0')" ); local COUNT=0; local PATCHED_COUNT=0
    print_status "Attempting patches..."; for LIB in "${!LIBS[@]}"; do TARGET_LIB="${LIBS[$LIB]}"; echo -n "  Patch $LIB -> $TARGET_LIB... "; if [ -z "$TARGET_LIB" ]; then echo -e "${YELLOW}SKIP (Target empty)${NC}"; continue; fi; if ! ldconfig -p | grep -q "$(basename "$TARGET_LIB")" && [ ! -f "$TARGET_LIB" ] && [ ! -L "$TARGET_LIB" ]; then echo -e "${YELLOW}SKIP (Target '$TARGET_LIB' missing)${NC}"; continue; fi; if ! ldd "$SERVER_BINARY" 2>/dev/null | grep -q "$LIB"; then echo -e "${BLUE}SKIP (Not needed)${NC}"; continue; fi; ((COUNT++)); if patchelf --replace-needed "$LIB" "$TARGET_LIB" "$SERVER_BINARY"; then echo -e "${GREEN}OK${NC}"; ((PATCHED_COUNT++)); else patch_ec=$?; echo -e "${RED}FAILED (Code:$patch_ec)${NC}"; patchelf --replace-needed "$LIB" "$TARGET_LIB" "$SERVER_BINARY" || true; print_warning "Patch failed: $LIB"; fi; done; print_success "Patches applied ($PATCHED_COUNT/$COUNT needed & attempted)."
}

test_binary() {
    print_step "[7/8] Testing server binary execution..."; print_progress "Running '$SERVER_BINARY -h' as user '$ORIGINAL_USER'..."
    local test_output; test_output=$(sudo -u "$ORIGINAL_USER" ./$SERVER_BINARY -h 2>&1); local test_ec=$?
    if [ $test_ec -eq 0 ]; then print_success "Server binary test passed."; else print_warning "Server binary test FAILED (Code: $test_ec)."; print_warning "Output:\n$test_output"; print_warning "Checking dependencies with ldd:"; ldd ./$SERVER_BINARY || print_error "ldd failed."; print_warning "Manual library installation might be needed."; fi
}

set_permissions() {
    print_step "[8/8] Setting final ownership and permissions..."; print_progress "Changing ownership to '$ORIGINAL_USER'..."
    find . -mindepth 1 -exec chown "$ORIGINAL_USER:$ORIGINAL_USER" {} \; || print_warning "Chown failed for some files."
    print_progress "Setting execute permissions..."; chmod u+x "$SERVER_BINARY" "server_manager.sh" "rank_patcher.sh" || print_warning "Chmod failed for scripts/binary."
    print_success "Permissions set."
}

# --- Ejecución ---
install_packages
# Salir si fallaron paquetes esenciales
if [ $? -ne 0 ]; then exit 1; fi

configure_sudoers
download_files # Ahora saldrá si falla la descarga de manager o patcher
extract_and_patch
test_binary
set_permissions

# --- Instrucciones Finales ---
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
echo -e "${GREEN}7. Default port: ${YELLOW}12153${NC} (specified in server_manager.sh)"
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
