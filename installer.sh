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
            # Usar -print -quit para eficiencia
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
            apt-get update || print_warning "apt-get update failed" # Continuar aunque falle
            print_status "Installing ${#PACKAGES_DEBIAN[@]} packages..."
            # Instalar paquetes individualmente para mejor feedback
            for package in "${PACKAGES_DEBIAN[@]}"; do
                echo -n "  Installing $package... "
                if apt-get install -y "$package"; then # Sin silenciar
                   echo -e "${GREEN}OK${NC}"
                else
                   echo -e "${RED}FAILED${NC}"
                   print_warning "Could not install $package" # Advertir pero continuar
                fi
            done
            ;;
        arch)
             print_status "Installing ${#PACKAGES_ARCH[@]} packages (Arch)..."
             pacman -Sy || print_warning "pacman -Sy failed" # Continuar aunque falle
             # Instalar individualmente
             for package in "${PACKAGES_ARCH[@]}"; do
                  echo -n "  Installing $package... "
                  if pacman -S --noconfirm --needed "$package"; then # Sin silenciar
                       echo -e "${GREEN}OK${NC}"
                  else
                       echo -e "${RED}FAILED${NC}"
                       print_warning "Could not install $package" # Advertir pero continuar
                  fi
             done
             ;;
        *)
            print_error "Unsupported operating system: $ID"; return 1 ;;
    esac
    # Verificar paquetes esenciales al final
    local essential_pkgs=('wget' 'curl' 'tar' 'screen' 'lsof' 'ngrep' 'python3' 'python' 'gawk' 'binutils' 'patchelf')
    local missing_essential=0
    for pkg_cmd in "${essential_pkgs[@]}"; do
        if ! command -v "$pkg_cmd" &> /dev/null; then
             # Intentar detectar el paquete faltante basado en el comando
             case "$pkg_cmd" in
                  python3|python) pkg_name="python3 or python";;
                  gawk) pkg_name="gawk or awk";;
                  *) pkg_name="$pkg_cmd";;
             esac
             print_error "Essential command '$pkg_cmd' (package: $pkg_name) not found after installation attempt!"
             missing_essential=1
        fi
    done
    if [ "$missing_essential" -eq 1 ]; then
         print_error "Essential packages missing. Cannot continue reliably."
         # return 1 # Decidir si abortar o solo advertir
         print_warning "Attempting to continue, but script may fail later."
    else
         print_success "Essential packages verified."
    fi
    return 0 # Siempre retorna éxito para continuar si no se abortó antes
}

configure_sudoers() {
    print_step "[2/8] Configuring passwordless sudo for sniffer..."
    # Verificar ngrep primero
    if ! command -v ngrep &> /dev/null; then
        print_warning "ngrep command not found. Skipping sudo configuration."
        return
    fi

    NGREP_PATH=$(which ngrep)
    if [ -z "$NGREP_PATH" ]; then
        print_error "Could not find ngrep path using 'which'. Skipping sudo configuration."
        return
    fi
    SUDOERS_FILE="/etc/sudoers.d/blockheads_sniffer"

    print_status "Creating sudoers rule for user '$ORIGINAL_USER' to run '$NGREP_PATH' without password."

    # Usar tee para escribir como root de forma segura
    # Asegurarse de que el directorio /etc/sudoers.d exista
    mkdir -p /etc/sudoers.d
    echo "$ORIGINAL_USER ALL=(ALL) NOPASSWD: $NGREP_PATH" | tee "$SUDOERS_FILE" > /dev/null
    chmod 440 "$SUDOERS_FILE"

    # Validar con visudo
    print_status "Validating sudoers rule..."
    if visudo -c -f "$SUDOERS_FILE"; then
        print_success "Passwordless sudo for ngrep configured successfully."
    else
        print_error "Failed to validate sudoers file. Removing rule."
        rm -f "$SUDOERS_FILE"
        print_warning "Sudoers configuration FAILED. You will need to run 'sudo visudo' manually and add:"
        print_warning "$ORIGINAL_USER ALL=(ALL) NOPASSWD: $NGREP_PATH"
    fi
}


download_files() {
    print_step "[3/8] Downloading Server Binary..."
    print_progress "Downloading from $SERVER_URL ..."
    # Mostrar progreso de wget
    if ! wget --timeout=60 --tries=5 --progress=bar:force -O "$TEMP_FILE" "$SERVER_URL" 2>&1; then
        print_error "Failed to download server file from $SERVER_URL"
        exit 1
    fi
    print_success "Server binary downloaded."

    print_step "[4/8] Downloading Manager and Patcher scripts..."
    print_progress "Downloading server_manager.sh from $SERVER_MANAGER_URL ..."
    dl_manager_failed=0
    # Verificar variable
    if [ -z "$SERVER_MANAGER_URL" ]; then
        print_error "SERVER_MANAGER_URL variable is empty in the script!"
        dl_manager_failed=1
    # Verificar si la URL es alcanzable (más robusto que solo descargar)
    elif ! curl --output /dev/null --silent --head --fail --connect-timeout 10 "$SERVER_MANAGER_URL"; then
        print_error "Cannot reach SERVER_MANAGER_URL (or it's not a valid file): $SERVER_MANAGER_URL"
        print_warning "Please double-check the URL in the installer script."
        dl_manager_failed=1
    # Intentar descargar
    elif ! wget --timeout=30 --tries=3 -O "server_manager.sh" "$SERVER_MANAGER_URL"; then # Mostrar errores
        print_error "Failed to download server_manager.sh from your repo!"
        print_warning "URL was reachable but download failed. Check permissions or network."
        dl_manager_failed=1
    else
        print_success "Server manager downloaded."
    fi

    # Crear placeholder si la descarga falló
    if [ "$dl_manager_failed" -eq 1 ]; then
        print_warning "Creating a basic placeholder script for server_manager.sh instead."
        cat > server_manager.sh << 'EOF_PLACEHOLDER'
#!/bin/bash
echo "[ERROR] server_manager.sh failed to download during installation."
echo "Please fix the URL in installer.sh and re-run, or download manually."
echo "Basic commands:"
echo "Create world: ./blockheads_server171 -n"
echo "Start world: ./blockheads_server171 -o WORLD_ID -p PORT"
EOF_PLACEHOLDER
        chmod +x server_manager.sh
    fi

    print_progress "Downloading rank_patcher.sh from $RANK_PATCHER_URL ..."
    dl_patcher_failed=0
     # Verificar variable
    if [ -z "$RANK_PATCHER_URL" ]; then
        print_error "RANK_PATCHER_URL variable is empty in the script!"
        dl_patcher_failed=1
    # Verificar si la URL es alcanzable
    elif ! curl --output /dev/null --silent --head --fail --connect-timeout 10 "$RANK_PATCHER_URL"; then
        print_error "Cannot reach RANK_PATCHER_URL (or it's not a valid file): $RANK_PATCHER_URL"
        print_warning "Please double-check the URL in the installer script."
        dl_patcher_failed=1
    # Intentar descargar
    elif ! wget --timeout=30 --tries=3 -O "rank_patcher.sh" "$RANK_PATCHER_URL"; then # Mostrar errores
        print_error "Failed to download rank_patcher.sh from your repo!"
        print_warning "URL was reachable but download failed. Check permissions or network."
        dl_patcher_failed=1
    else
        print_success "Rank patcher downloaded."
    fi

    # Crear placeholder si la descarga falló
    if [ "$dl_patcher_failed" -eq 1 ]; then
        print_warning "Creating a basic placeholder script for rank_patcher.sh instead."
        cat > rank_patcher.sh << 'EOF_PLACEHOLDER2'
#!/bin/bash
echo "[ERROR] rank_patcher.sh failed to download during installation."
echo "Functionality will be limited."
EOF_PLACEHOLDER2
        chmod +x rank_patcher.sh
    fi

    # Hacer ejecutables los scripts descargados (o placeholders)
    chmod +x "server_manager.sh" "rank_patcher.sh" 2>/dev/null || true
}


extract_and_patch() {
    print_step "[5/8] Extracting server files..."
    EXTRACT_DIR="/tmp/blockheads_extract_$$"; mkdir -p "$EXTRACT_DIR"

    # Mostrar salida de tar en caso de error
    if ! tar -xzf "$TEMP_FILE" -C "$EXTRACT_DIR"; then
        print_error "Failed to extract server files from $TEMP_FILE"
        ls -l "$TEMP_FILE" # Mostrar tamaño por si la descarga falló
        rm -rf "$EXTRACT_DIR" "$TEMP_FILE"
        exit 1
    fi
    print_progress "Files extracted to temporary directory."

    # Mover archivos extraídos al directorio actual
    # Usar 'shopt -s dotglob' para incluir archivos ocultos si los hubiera
    shopt -s dotglob
    # Usar 'cp' y luego 'rm' es a veces más seguro que 'mv' si hay conflictos
    cp -r "$EXTRACT_DIR"/* ./ 2>/dev/null || print_warning "Could not copy all extracted files."
    shopt -u dotglob
    rm -rf "$EXTRACT_DIR" "$TEMP_FILE"
    print_progress "Files moved to current directory."

    # Verificar existencia del binario
    if [ ! -f "$SERVER_BINARY" ]; then
        # Buscar de forma más flexible, ignorando mayúsculas/minúsculas
        ALTERNATIVE_BINARY=$(find . -maxdepth 1 -iname "*blockheads*server*" -type f -executable -print -quit)
        if [ -z "$ALTERNATIVE_BINARY" ]; then
             # Buscar cualquier ejecutable que contenga 'blockheads'
             ALTERNATIVE_BINARY=$(find . -maxdepth 1 -iname "*blockheads*" -type f -executable -print -quit)
        fi

        if [ -n "$ALTERNATIVE_BINARY" ] && [ "$ALTERNATIVE_BINARY" != "./$SERVER_BINARY" ]; then
             print_warning "Server binary named '$SERVER_BINARY' not found, renaming '$ALTERNATIVE_BINARY'"
             mv "$ALTERNATIVE_BINARY" "$SERVER_BINARY"
        elif [ ! -f "$SERVER_BINARY" ]; then
             print_error "Server binary ('$SERVER_BINARY' or similar) not found after extraction!"
             ls -lA . # Mostrar contenido del directorio, incluyendo ocultos
             exit 1
        fi
    fi
    chmod +x "$SERVER_BINARY"
    print_success "Server binary located and made executable."

    print_step "[6/8] Applying comprehensive compatibility patches..."
    # Mapa de librerías a parchear (Restaurado de tu original)
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

    local COUNT=0
    local PATCHED_COUNT=0
    print_status "Attempting to patch needed libraries..."
    for LIB in "${!LIBS[@]}"; do
        TARGET_LIB="${LIBS[$LIB]}"
        # Mostrar qué se intenta parchear
        echo -n "  Checking patch for $LIB -> $TARGET_LIB... "
        # Validar que TARGET_LIB no esté vacío
        if [ -z "$TARGET_LIB" ]; then
             echo -e "${YELLOW}SKIP (Target library name is empty)${NC}"
            continue
        fi
         # Validar que TARGET_LIB exista en el sistema
        if ! ldconfig -p | grep -q "$(basename "$TARGET_LIB")" && [ ! -f "$TARGET_LIB" ] && [ ! -L "$TARGET_LIB" ]; then
             echo -e "${YELLOW}SKIP (Target '$TARGET_LIB' not found on system)${NC}"
             continue
        fi
        # Validar que LIB sea realmente una dependencia del binario
        if ! ldd "$SERVER_BINARY" | grep -q "$LIB"; then
             echo -e "${BLUE}SKIP (Not needed by binary)${NC}"
             continue
        fi


        ((COUNT++))
        # Ejecutar patchelf y mostrar su salida en caso de error
        if patchelf --replace-needed "$LIB" "$TARGET_LIB" "$SERVER_BINARY"; then
             echo -e "${GREEN}OK${NC}"
            ((PATCHED_COUNT++))
        else
             local patch_error_code=$?
             echo -e "${RED}FAILED (Code: $patch_error_code)${NC}"
             # Mostrar el error específico de patchelf
             patchelf --replace-needed "$LIB" "$TARGET_LIB" "$SERVER_BINARY" || true
             print_warning "Failed to apply patch for $LIB. Check patchelf output above."
        fi
    done
    print_success "Compatibility patches applied ($PATCHED_COUNT/$COUNT libraries needed and attempted)."
}

test_binary() {
    print_step "[7/8] Testing server binary execution..."
    print_progress "Running '$SERVER_BINARY -h' as user '$ORIGINAL_USER'..."
    # Ejecutar la prueba como el usuario original y mostrar salida completa
    if sudo -u "$ORIGINAL_USER" ./$SERVER_BINARY -h; then
        print_success "Server binary help screen test passed."
    else
        local test_error_code=$?
        print_warning "Server binary execution test FAILED (Code: $test_error_code)."
        print_warning "This likely indicates missing libraries or incorrect patches."
        print_warning "Check the output above for specific errors (e.g., 'cannot open shared object file')."
        print_warning "Running ldd to check dependencies:"
        ldd ./$SERVER_BINARY || print_error "ldd command failed."
        print_warning "You might need to install additional libraries manually or fix patches."
    fi
}


set_permissions() {
    print_step "[8/8] Setting final ownership and permissions..."
    # Asegurarse de que el usuario original sea dueño de todo en el directorio actual
    print_progress "Changing ownership of current directory contents to '$ORIGINAL_USER'..."
    # Usar find para asegurar que se aplique a todo, incluyendo archivos ocultos
    find . -mindepth 1 -exec chown "$ORIGINAL_USER:$ORIGINAL_USER" {} \; || print_warning "Could not set ownership for some files."

    # Asegurarse de que los scripts y el binario sean ejecutables por el dueño
    print_progress "Setting execute permissions..."
    chmod u+x "$SERVER_BINARY" "server_manager.sh" "rank_patcher.sh" || print_warning "Could not set execute permissions on scripts/binary."
    print_success "Permissions set."
}

# --- Ejecución del Instalador ---
install_packages
configure_sudoers
download_files
extract_and_patch
test_binary
set_permissions

# --- Limpieza (Opcional) ---
# rm -f "$TEMP_FILE" 2>/dev/null

# --- INSTRUCCIONES FINALES (RESTAURADAS COMPLETAMENTE) ---
print_header "INSTALLATION COMPLETE"
echo -e "${GREEN}Server installed successfully!${NC}"
echo ""

print_header "SERVER BINARY INFORMATION"
echo ""
# Ejecutar como usuario original para mostrar ayuda
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

print_header "FINAL CHECK"
echo -e "${GREEN}Installation attempt finished.${NC}"
print_warning "Review the output above for any ${RED}FAILED${NC} steps or ${YELLOW}WARNINGS${NC}."
print_warning "If essential packages failed or the binary test failed, the server might not run correctly."
echo ""
print_success "If everything looks OK, proceed to create a world and start the server as user '$ORIGINAL_USER'."
