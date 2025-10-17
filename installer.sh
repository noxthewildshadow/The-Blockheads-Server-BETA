#!/bin/bash
# Este script DEBE ejecutarse como root (con sudo)
set -e

# --- Colores ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
PURPLE='\033[0;35m'
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

# --- Comprobación de Root ---
if [ "$EUID" -ne 0 ]; then
    print_error "This script requires root privileges. Please run with: sudo $0"
    exit 1
fi

# --- Encontrar el usuario original que ejecutó sudo ---
ORIGINAL_USER=${SUDO_USER:-$USER}
USER_HOME=$(getent passwd "$ORIGINAL_USER" | cut -d: -f6)
[ -z "$USER_HOME" ] && USER_HOME="/home/$ORIGINAL_USER" # Fallback

# --- URLs y Archivos ---
SERVER_URL="https://web.archive.org/web/20240309015235if_/https://majicdave.com/share/blockheads_server171.tar.gz"
TEMP_FILE="/tmp/blockheads_server171.tar.gz"
SERVER_BINARY="blockheads_server171"

# !!! CAMBIA ESTAS URLs POR LAS DE TU REPOSITORIO DE GITHUB !!!
MANAGER_URL="https://raw.githubusercontent.com/noxthewildshadow/The-Blockheads-Server-BETA/main/server_manager.sh"
PATCHER_URL="https://raw.githubusercontent.com/noxthewildshadow/The-Blockheads-Server-BETA/main/rank_patcher.sh"

# --- Listas de Paquetes ---
declare -a PACKAGES_DEBIAN=(
    'binutils' 'libgnustep-base-dev' 'libobjc4' 'libdispatch-dev' 'libgnutls28-dev' 
    'libgcrypt20-dev' 'libffi-dev' 'libnsl-dev' 'libicu-dev' 'wget' 'curl' 
    'tar' 'grep' 'screen' 'lsof' 'ngrep' 'patchelf' 'inotify-tools' 'libc6'
)
declare -a PACKAGES_ARCH=(
    'base-devel' 'binutils' 'gnustep-base' 'gcc-libs' 'libdispatch' 'gnutls' 
    'libgcrypt' 'libffi' 'libnsl' 'icu' 'wget' 'curl' 'tar' 'grep' 'screen' 
    'lsof' 'ngrep' 'patchelf' 'inotify-tools'
)
# (Añade yum/dnf si es necesario)

print_header "THE BLOCKHEADS LINUX SERVER INSTALLER"
print_status "Installing for user: $ORIGINAL_USER"
echo

# --- Funciones de Instalación ---

find_library() {
    local SEARCH=$1
    local LIBRARY=$(ldconfig -p | grep -F "$SEARCH" -m 1 | awk '{print $NF}' | head -1)
    [ -z "$LIBRARY" ] && return 1
    printf '%s' "$LIBRARY"
}

install_packages() {
    [ ! -f /etc/os-release ] && print_error "Could not detect the operating system" && return 1
    source /etc/os-release
    
    print_step "[1/7] Installing system packages..."
    case $ID in
        debian|ubuntu|pop)
            print_status "Updating package lists (Debian/Ubuntu)..."
            if ! apt-get update >/dev/null 2>&1; then
                print_error "Failed to update package list"
                return 1
            fi
            
            print_status "Installing ${#PACKAGES_DEBIAN[@]} packages..."
            if ! apt-get install -y "${PACKAGES_DEBIAN[@]}" >/dev/null 2>&1; then
                print_warning "Failed to install all packages, retrying one by one..."
                for pkg in "${PACKAGES_DEBIAN[@]}"; do
                    apt-get install -y "$pkg" >/dev/null 2>&1 || print_warning "Could not install $pkg"
                done
            fi
            ;;
        arch)
            print_status "Installing ${#PACKAGES_ARCH[@]} packages (Arch)..."
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
    print_success "Package installation complete."
    return 0
}

configure_sudoers() {
    print_step "[2/7] Configuring passwordless sudo for sniffer..."
    if ! command -v ngrep &> /dev/null; then
        print_warning "ngrep command not found. Skipping sudo configuration."
        return
    fi
    
    NGREP_PATH=$(which ngrep)
    SUDOERS_FILE="/etc/sudoers.d/blockheads_sniffer"
    
    print_status "Creating sudoers rule for $ORIGINAL_USER at $NGREP_PATH"
    
    # Crear el archivo de regla de sudo
    echo "$ORIGINAL_USER ALL=(ALL) NOPASSWD: $NGREP_PATH" > "$SUDOERS_FILE"
    chmod 440 "$SUDOERS_FILE"
    
    # Validar con visudo
    if visudo -c -f "$SUDOERS_FILE" >/dev/null 2>&1; then
        print_success "Passwordless sudo for ngrep configured."
    else
        print_error "Failed to validate sudoers file. Removing."
        rm -f "$SUDOERS_FILE"
        print_warning "You will need to run 'sudo visudo' manually."
    fi
}

download_files() {
    print_step "[3/7] Downloading Server Binary..."
    if ! wget --timeout=30 --tries=3 -O "$TEMP_FILE" "$SERVER_URL" 2>/dev/null; then
        print_error "Failed to download server file from $SERVER_URL"
        exit 1
    fi
    print_success "Server binary downloaded."

    print_step "[4/7] Downloading Manager and Patcher scripts..."
    if ! wget --timeout=30 --tries=3 -O "server_manager.sh" "$MANAGER_URL" 2>/dev/null; then
        print_error "Failed to download server_manager.sh from your repo!"
        print_warning "Please check the MANAGER_URL variable in this script."
        exit 1
    fi
    
    if ! wget --timeout=30 --tries=3 -O "rank_patcher.sh" "$PATCHER_URL" 2>/dev/null; then
        print_error "Failed to download rank_patcher.sh from your repo!"
        print_warning "Please check the PATCHER_URL variable in this script."
        exit 1
    fi
    print_success "Helper scripts downloaded."
}

extract_and_patch() {
    print_step "[5/7] Extracting files..."
    EXTRACT_DIR="/tmp/blockheads_extract_$$"
    mkdir -p "$EXTRACT_DIR"

    if ! tar -xzf "$TEMP_FILE" -C "$EXTRACT_DIR" >/dev/null 2>&1; then
        print_error "Failed to extract server files"
        rm -rf "$EXTRACT_DIR" "$TEMP_FILE"
        exit 1
    fi
    
    cp -r "$EXTRACT_DIR"/* ./
    rm -rf "$EXTRACT_DIR" "$TEMP_FILE"
    
    if [ ! -f "$SERVER_BINARY" ]; then
        print_error "Server binary not found after extraction"
        exit 1
    fi
    print_success "Server binary extracted."

    print_step "[6/7] Applying compatibility patches..."
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
    for LIB in "${!LIBS[@]}"; do
        [ -z "${LIBS[$LIB]}" ] && continue
        if patchelf --replace-needed "$LIB" "${LIBS[$LIB]}" "$SERVER_BINARY" >/dev/null 2>&1; then
            ((COUNT++))
        fi
    done
    print_success "Compatibility patches applied ($COUNT libraries)."
}

set_permissions() {
    print_step "[7/7] Setting final permissions..."
    chown -R "$ORIGINAL_USER:$ORIGINAL_USER" . 2>/dev/null || true
    chmod 755 "$SERVER_BINARY" "server_manager.sh" "rank_patcher.sh" 2>/dev/null || true
    print_success "Permissions set."
}

# --- Ejecución del Instalador ---
install_packages
configure_sudoers
download_files
extract_and_patch
set_permissions

print_header "INSTALLATION COMPLETE"
print_success "Your Blockheads server is ready!"
echo ""
print_warning "¡IMPORTANTE! Sal de root (escribe 'exit') y ejecuta los siguientes comandos como '$ORIGINAL_USER'."
echo ""
print_status "1. Crea un mundo:  ${CYAN}./blockheads_server171 -n${NC}"
print_status "2. Inicia el server: ${CYAN}./server_manager.sh start TuMundo 11111${NC}"
