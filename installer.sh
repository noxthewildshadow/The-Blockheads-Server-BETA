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

# !!! CAMBIA ESTAS URLs POR LAS DE TU REPOSITORIO DE GITHUB !!!
SERVER_MANAGER_URL="https://raw.githubusercontent.com/noxthewildshadow/The-Blockheads-Server-BETA/main/server_manager.sh" # URL al server_manager.sh CON log de paquetes únicos
RANK_PATCHER_URL="https://raw.githubusercontent.com/noxthewildshadow/The-Blockheads-Server-BETA/main/rank_patcher.sh"

# --- Listas de Paquetes (Restauradas y con adiciones) ---
declare -a PACKAGES_DEBIAN=(
    'git' 'cmake' 'ninja-build' 'clang' 'patchelf' 'libgnustep-base-dev' 'libobjc4'
    'libgnutls28-dev' 'libgcrypt20-dev' 'libxml2' 'libffi-dev' 'libnsl-dev' 'zlib1g'
    'libicu-dev' 'libstdc++6' 'libgcc-s1' 'wget' 'curl' 'tar' 'grep' 'screen' 'lsof'
    'inotify-tools' 'ngrep' 'binutils' 'gawk' # <-- ngrep, binutils, gawk añadidos
)

declare -a PACKAGES_ARCH=(
    'base-devel' 'git' 'cmake' 'ninja' 'clang' 'patchelf' 'gnustep-base' 'gcc-libs'
    'gnutls' 'libgcrypt' 'libxml2' 'libffi' 'libnsl' 'zlib' 'icu' 'libdispatch'
    'wget' 'curl' 'tar' 'grep' 'screen' 'lsof' 'inotify-tools' 'ngrep' 'binutils' 'gawk' # <-- ngrep, binutils, gawk añadidos
)
# (Añadir yum/dnf si es necesario)


print_header "THE BLOCKHEADS LINUX SERVER INSTALLER (VERBOSE MODE)"
echo -e "${CYAN}Welcome to The Blockheads Server Installation!${NC}"
echo -e "${YELLOW}This script will install and configure everything you need.${NC}"
echo

# --- Funciones Auxiliares (Restauradas) ---
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
            if ! apt-get update; then # Sin silenciar
                print_error "Failed to update package list"
                # Continuar de todas formas
            fi
            print_status "Installing ${#PACKAGES_DEBIAN[@]} packages..."
            for package in "${PACKAGES_DEBIAN[@]}"; do
                echo -n "  Installing $package... "
                if apt-get install -y "$package"; then # Sin silenciar
                   echo -e "${GREEN}OK${NC}"
                else
                   echo -e "${RED}FAILED${NC}"
                   print_warning "Could not install $package"
                fi
            done
            ;;
        arch)
            print_status "Installing ${#PACKAGES_ARCH[@]} packages (Arch)..."
            # Asegurarse de actualizar la base de datos primero
            if ! pacman -Sy; then # Sin silenciar
                 print_warning "Failed to sync package database"
            fi
            # Instalar paquetes necesarios
            if ! pacman -S --noconfirm --needed "${PACKAGES_ARCH[@]}"; then # Sin silenciar
                print_error "Failed to install some Arch Linux packages"
                # Continuar de todas formas
            fi
            ;;
        *)
            print_error "Unsupported operating system: $ID"
            return 1
            ;;
    esac
    print_success "Package installation attempt complete."
    return 0 # Siempre retorna éxito para continuar
}

configure_sudoers() {
    print_step "[2/8] Configuring passwordless sudo for sniffer..."
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
    if ! wget --timeout=30 --tries=3 --progress=bar:force -O "$TEMP_FILE" "$SERVER_URL" 2>&1; then
        print_error "Failed to download server file from $SERVER_URL"
        exit 1
    fi
    print_success "Server binary downloaded."

    print_step "[4/8] Downloading Manager and Patcher scripts..."
    print_progress "Downloading server_manager.sh from $MANAGER_URL ..."
    if ! wget --timeout=30 --tries=3 -O "server_manager.sh" "$MANAGER_URL"; then # Mostrar errores
        print_error "Failed to download server_manager.sh from your repo!"
        print_warning "Please check the MANAGER_URL variable in this script: $MANAGER_URL"
        exit 1
    fi

    print_progress "Downloading rank_patcher.sh from $PATCHER_URL ..."
    if ! wget --timeout=30 --tries=3 -O "rank_patcher.sh" "$PATCHER_URL"; then # Mostrar errores
        print_error "Failed to download rank_patcher.sh from your repo!"
        print_warning "Please check the PATCHER_URL variable in this script: $PATCHER_URL"
        exit 1
    fi
    print_success "Helper scripts downloaded."
}

extract_and_patch() {
    print_step "[5/8] Extracting server files..."
    EXTRACT_DIR="/tmp/blockheads_extract_$$"
    mkdir -p "$EXTRACT_DIR"

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
    mv "$EXTRACT_DIR"/* ./
    shopt -u dotglob
    rm -rf "$EXTRACT_DIR" "$TEMP_FILE"
    print_progress "Files moved to current directory."

    # Verificar existencia del binario
    if [ ! -f "$SERVER_BINARY" ]; then
        ALTERNATIVE_BINARY=$(find . -maxdepth 1 -name "*blockheads*" -type f -executable -print -quit)
        if [ -n "$ALTERNATIVE_BINARY" ]; then
             print_warning "Server binary named '$SERVER_BINARY' not found, renaming '$ALTERNATIVE_BINARY'"
             mv "$ALTERNATIVE_BINARY" "$SERVER_BINARY"
        else
             print_error "Server binary ('$SERVER_BINARY' or similar) not found after extraction!"
             ls -l . # Mostrar contenido del directorio
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
        if [ -z "$TARGET_LIB" ]; then
             echo -e "${YELLOW}SKIP (Target library not found using find_library)${NC}"
            continue
        fi
        # Verificar si la librería objetivo realmente existe antes de intentar parchear
        if ! ldconfig -p | grep -q "$(basename "$TARGET_LIB")"; then
             # A veces find_library puede devolver un nombre aunque no esté en ldconfig
             if [ ! -f "$TARGET_LIB" ] && [ ! -L "$TARGET_LIB" ]; then
                 echo -e "${YELLOW}SKIP (Target '$TARGET_LIB' does not exist on system)${NC}"
                 continue
             fi
        fi

        ((COUNT++))
        # Ejecutar patchelf y mostrar su salida en caso de error
        if patchelf --replace-needed "$LIB" "$TARGET_LIB" "$SERVER_BINARY"; then
             echo -e "${GREEN}OK${NC}"
            ((PATCHED_COUNT++))
        else
             echo -e "${RED}FAILED${NC}"
             # Mostrar el error específico de patchelf
             patchelf --replace-needed "$LIB" "$TARGET_LIB" "$SERVER_BINARY" || true
             print_warning "Failed to apply patch for $LIB. Check patchelf output above."
        fi
    done
    print_success "Compatibility patches applied ($PATCHED_COUNT/$COUNT libraries attempted)."
}

test_binary() {
    print_step "[7/8] Testing server binary execution..."
    print_progress "Running '$SERVER_BINARY -h' as user '$ORIGINAL_USER'..."
    # Ejecutar la prueba como el usuario original y mostrar salida
    if sudo -u "$ORIGINAL_USER" ./$SERVER_BINARY -h; then
        print_success "Server binary help screen test passed."
    else
        print_warning "Server binary execution test FAILED."
        print_warning "This likely indicates missing libraries or incorrect patches."
        print_warning "Check the output above for specific errors (e.g., 'cannot open shared object file')."
        print_warning "You might need to install additional libraries manually."
    fi
}


set_permissions() {
    print_step "[8/8] Setting final ownership and permissions..."
    # Asegurarse de que el usuario original sea dueño de todo en el directorio actual
    print_progress "Changing ownership of current directory to '$ORIGINAL_USER'..."
    chown -R "$ORIGINAL_USER:$ORIGINAL_USER" . || print_warning "Could not set ownership for current directory."

    # Asegurarse de que los scripts y el binario sean ejecutables por el dueño
    print_progress "Setting execute permissions..."
    chmod u+x "$SERVER_BINARY" "server_manager.sh" "rank_patcher.sh" || print_warning "Could not set execute permissions."
    print_success "Permissions set."
}

# --- Ejecución del Instalador ---
install_packages
configure_sudoers
download_files
extract_and_patch
test_binary
set_permissions

# --- Limpieza (opcional) ---
# rm -f "$TEMP_FILE" 2>/dev/null

print_header "INSTALLATION COMPLETE"
print_success "Your Blockheads server setup is complete!"
echo ""
print_warning "¡IMPORTANTE! Exit root now (type 'exit') and run the following commands as '$ORIGINAL_USER'."
echo ""
print_status "1. Create a world (if you haven't): ${CYAN}./$SERVER_BINARY -n${NC}"
print_warning "   (Press CTRL+C after world creation finishes)"
print_status "2. Start the server & services:   ${CYAN}./server_manager.sh start YourWorldName 11111${NC}"
print_status "   (Replace YourWorldName and 11111 if needed)"
echo ""
print_status "Check server status with: ${CYAN}./server_manager.sh status YourPort${NC}"
print_status "Stop server with:       ${CYAN}./server_manager.sh stop YourPort${NC}"
echo ""
print_success "Enjoy your server!"
