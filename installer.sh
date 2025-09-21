#!/bin/bash
set -e

# =============================================================================
# THE BLOCKHEADS LINUX SERVER INSTALLER - ENHANCED UI VERSION
# =============================================================================

# Color codes for output with more vibrant colors
RED='\033[1;91m'
GREEN='\033[1;92m'
YELLOW='\033[1;93m'
BLUE='\033[1;94m'
CYAN='\033[1;96m'
MAGENTA='\033[1;95m'
ORANGE='\033[1;33m'
PURPLE='\033[1;35m'
BOLD='\033[1m'
UNDERLINE='\033[4m'
NC='\033[0m'

# Function definitions with better formatting
print_status() {
    echo -e "${BLUE}ℹ ${NC}${BOLD}$1${NC}";
}

print_success() {
    echo -e "${GREEN}✓ ${NC}${BOLD}$1${NC}";
}

print_warning() {
    echo -e "${YELLOW}⚠ ${NC}${BOLD}$1${NC}";
}

print_error() {
    echo -e "${RED}✗ ${NC}${BOLD}$1${NC}";
}

print_header() {
    echo -e "${PURPLE}╔══════════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${PURPLE}║${NC}${BOLD} $1${NC}"
    echo -e "${PURPLE}╚══════════════════════════════════════════════════════════════════════════════════╝${NC}"
}

print_step() {
    echo -e "${CYAN}→${NC} ${BOLD}$1${NC}";
}

print_progress() {
    echo -e "${MAGENTA}⌛${NC} ${BOLD}$1${NC}";
}

print_divider() {
    echo -e "${BLUE}──────────────────────────────────────────────────────────────────────────────────────${NC}"
}

# Función para mostrar una barra de progreso animada
progress_bar() {
    local duration=${1:-5}
    local steps=30
    local step_delay=$(echo "scale=3; $duration/$steps" | bc)
    local colors=("${BLUE}" "${CYAN}" "${GREEN}" "${YELLOW}")
    
    echo -ne "["
    for ((i=0; i<steps; i++)); do
        color_idx=$((i % 4))
        echo -ne "${colors[color_idx]}"
        echo -ne "█"
        sleep $step_delay
    done
    echo -e "${NC}]"
}

# Función para mostrar un spinner
spinner() {
    local pid=$1
    local message=$2
    local delay=0.1
    local spinstr='|/-\'
    
    echo -ne " ${message} "
    while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
}

# Función para limpiar carpetas problemáticas
clean_problematic_dirs() {
    local problematic_dirs=(
        "swift-corelibs-libdispatch"
        "swift-corelibs-libdispatch.build"
        "libdispatch-build"
    )
    
    for dir in "${problematic_dirs[@]}"; do
        if [ -d "$dir" ]; then
            print_step "Eliminando carpeta problemática: $dir"
            rm -rf "$dir" 2>/dev/null || (
                print_warning "No se pudo eliminar $dir, intentando con sudo..."
                sudo rm -rf "$dir"
            )
        fi
    done
}

# Limpiar carpetas problemáticas al inicio
clean_problematic_dirs

# Wget options for downloads with progress
WGET_OPTIONS="--timeout=30 --tries=2 --dns-timeout=10 --connect-timeout=10 --read-timeout=30 --show-progress"

# Check if running as root
[ "$EUID" -ne 0 ] && print_error "This script requires root privileges." && exit 1

ORIGINAL_USER=${SUDO_USER:-$USER}
USER_HOME=$(getent passwd "$ORIGINAL_USER" | cut -d: -f6)

# URL for server download (updated to archive.org)
SERVER_URL="https://web.archive.org/web/20240309015235if_/https://majicdave.com/share/blockheads_server171.tar.gz"
TEMP_FILE="/tmp/blockheads_server171.tar.gz"
SERVER_BINARY="blockheads_server171"

# GitHub raw content URLs
SCRIPTS=(
    "server_manager.sh"
    "server_bot.sh"
    "anticheat_secure.sh"
    "blockheads_common.sh"
)

# Package lists for different distributions
declare -A PACKAGES_DEBIAN=(
    ['git']='Git version control system'
    ['cmake']='CMake build system'
    ['ninja-build']='Ninja build system'
    ['clang']='Clang compiler'
    ['systemtap-sdt-dev']='SystemTap development files'
    ['libbsd-dev']='BSD library development files'
    ['linux-libc-dev']='Linux kernel headers'
    ['curl']='cURL command line tool'
    ['tar']='Tar archiving utility'
    ['grep']='Grep pattern matching utility'
    ['mawk']='AWK implementation'
    ['patchelf']='ELF binary patcher'
    ['libgnustep-base-dev']='GNUstep Base library development files'
    ['libobjc4']='Objective-C runtime library'
    ['libgnutls28-dev']='GnuTLS development files'
    ['libgcrypt20-dev']='Libgcrypt development files'
    ['libxml2']='LibXML2 library'
    ['libffi-dev']='LibFFI development files'
    ['libnsl-dev']='Network Services Library development files'
    ['zlib1g']='Zlib compression library'
    ['libicu-dev']='ICU development files'
    ['libstdc++6']='GNU Standard C++ Library'
    ['libgcc-s1']='GCC support library'
    ['wget']='Wget download utility'
    ['jq']='jq JSON processor'
    ['screen']='Screen terminal multiplexer'
    ['lsof']='LiSt Open Files utility'
)

declare -A PACKAGES_ARCH=(
    ['base-devel']='Basic development tools'
    ['git']='Git version control system'
    ['cmake']='CMake build system'
    ['ninja']='Ninja build system'
    ['clang']='Clang compiler'
    ['systemtap']='SystemTap'
    ['libbsd']='BSD library'
    ['curl']='cURL command line tool'
    ['tar']='Tar archiving utility'
    ['grep']='Grep pattern matching utility'
    ['gawk']='GNU AWK implementation'
    ['patchelf']='ELF binary patcher'
    ['gnustep-base']='GNUstep Base library'
    ['gcc-libs']='GCC runtime libraries'
    ['gnutls']='GnuTLS library'
    ['libgcrypt']='Libgcrypt library'
    ['libxml2']='LibXML2 library'
    ['libffi']='LibFFI library'
    ['libnsl']='Network Services Library'
    ['zlib']='Zlib compression library'
    ['icu']='ICU library'
    ['libdispatch']='Libdispatch library'
    ['wget']='Wget download utility'
    ['jq']='jq JSON processor'
    ['screen']='Screen terminal multiplexer'
    ['lsof']='LiSt Open Files utility'
)

print_header "THE BLOCKHEADS LINUX SERVER INSTALLER"
echo -e "${CYAN}Welcome to The Blockheads Server Installation!${NC}"
echo -e "${YELLOW}This script will install and configure everything you need.${NC}"
echo

# Function to find library
find_library() {
    SEARCH=$1
    LIBRARY=$(ldconfig -p | grep -F "$SEARCH" -m 1 | awk '{print $NF}' | head -1)
    [ -z "$LIBRARY" ] && return 1
    printf '%s' "$LIBRARY"
}

# Function to check if flock is available
check_flock() {
    if command -v flock >/dev/null 2>&1; then
        return 0
    else
        print_warning "flock not found. Locking mechanisms will be disabled."
        print_warning "Some security features may not work properly."
        return 1
    fi
}

# Function to build libdispatch from source
build_libdispatch() {
    print_step "Building libdispatch from source..."
    local DIR=$(pwd)
    
    # Limpiar cualquier carpeta existente antes de construir
    clean_problematic_dirs
    
    if ! git clone --depth 1 'https://github.com/swiftlang/swift-corelibs-libdispatch.git' "${DIR}/swift-corelibs-libdispatch" >/dev/null 2>&1; then
        print_error "Failed to clone libdispatch repository"
        return 1
    fi
    
    mkdir -p "${DIR}/swift-corelibs-libdispatch/build" || return 1
    cd "${DIR}/swift-corelibs-libdispatch/build" || return 1
    
    if ! cmake -G Ninja -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ .. >/dev/null 2>&1; then
        print_error "CMake configuration failed"
        cd "${DIR}"
        clean_problematic_dirs
        return 1
    fi
    
    if ! ninja "-j$(nproc)" >/dev/null 2>&1; then
        print_error "Build failed"
        cd "${DIR}"
        clean_problematic_dirs
        return 1
    fi
    
    if ! ninja install >/dev/null 2>&1; then
        print_error "Installation failed"
        cd "${DIR}"
        clean_problematic_dirs
        return 1
    fi
    
    cd "${DIR}" || return 1
    # Limpiar después de la instalación exitosa
    clean_problematic_dirs
    ldconfig
    return 0
}

# Function to install packages with better output
install_packages() {
    [ ! -f /etc/os-release ] && print_error "Could not detect the operating system" && return 1
    
    source /etc/os-release
    
    case $ID in
        debian|ubuntu|pop|linuxmint|zorin|elementary|kali|parrot)
            print_step "Installing packages for Debian/Ubuntu based systems..."
            if ! apt-get update >/dev/null 2>&1; then
                print_error "Failed to update package list"
                return 1
            fi
            
            for package in "${!PACKAGES_DEBIAN[@]}"; do
                print_progress "Installing ${PACKAGES_DEBIAN[$package]} ($package)"
                if ! apt-get install -y "$package" >/dev/null 2>&1; then
                    print_warning "Failed to install $package"
                else
                    echo -e "${GREEN}  ✓ ${package} installed${NC}"
                fi
            done
            
            if ! find_library 'libdispatch.so' >/dev/null; then
                if ! build_libdispatch; then
                    print_warning "Failed to build libdispatch, trying to install from repository"
                    apt-get install -y libdispatch-dev >/dev/null 2>&1 || print_warning "Failed to install libdispatch-dev"
                fi
            fi
            ;;
        arch|manjaro|endeavouros)
            print_step "Installing packages for Arch Linux based systems..."
            if ! pacman -Sy --noconfirm --needed >/dev/null 2>&1; then
                print_error "Failed to sync package databases"
                return 1
            fi
            
            for package in "${!PACKAGES_ARCH[@]}"; do
                print_progress "Installing ${PACKAGES_ARCH[$package]} ($package)"
                if ! pacman -S --noconfirm --needed "$package" >/dev/null 2>&1; then
                    print_warning "Failed to install $package"
                else
                    echo -e "${GREEN}  ✓ ${package} installed${NC}"
                fi
            done
            ;;
        fedora|rhel|centos|almalinux|rocky)
            print_step "Installing packages for Fedora/RHEL based systems..."
            if ! dnf check-update -y >/dev/null 2>&1; then
                print_error "Failed to update package list"
                return 1
            fi
            
            # Convert Arch packages to Fedora equivalents
            declare -A PACKAGES_FEDORA=(
                ['git']='git'
                ['cmake']='cmake'
                ['ninja-build']='ninja-build'
                ['clang']='clang'
                ['systemtap-sdt-dev']='systemtap-sdt-devel'
                ['libbsd-dev']='libbsd-devel'
                ['linux-libc-dev']='kernel-headers'
                ['curl']='curl'
                ['tar']='tar'
                ['grep']='grep'
                ['mawk']='gawk'
                ['patchelf']='patchelf'
                ['libgnustep-base-dev']='gnustep-base-devel'
                ['libobjc4']='libobjc'
                ['libgnutls28-dev']='gnutls-devel'
                ['libgcrypt20-dev']='libgcrypt-devel'
                ['libxml2']='libxml2'
                ['libffi-dev']='libffi-devel'
                ['libnsl-dev']='libnsl'
                ['zlib1g']='zlib'
                ['libicu-dev']='libicu-devel'
                ['libstdc++6']='libstdc++'
                ['libgcc-s1']='libgcc'
                ['wget']='wget'
                ['jq']='jq'
                ['screen']='screen'
                ['lsof']='lsof'
            )
            
            for package in "${!PACKAGES_FEDORA[@]}"; do
                print_progress "Installing ${PACKAGES_FEDORA[$package]}"
                if ! dnf install -y "${PACKAGES_FEDORA[$package]}" >/dev/null 2>&1; then
                    print_warning "Failed to install ${PACKAGES_FEDORA[$package]}"
                else
                    echo -e "${GREEN}  ✓ ${PACKAGES_FEDORA[$package]} installed${NC}"
                fi
            done
            ;;
        *)
            print_error "Unsupported operating system: $ID"
            return 1
            ;;
    esac
    
    # Check if flock was installed
    check_flock
    return 0
}

# Optimized function to download scripts
download_script() {
    local script_name=$1
    local attempts=0
    local max_attempts=3
    
    while [ $attempts -lt $max_attempts ]; do
        if wget $WGET_OPTIONS -O "$script_name" \
            "https://raw.githubusercontent.com/noxthewildshadow/The-Blockheads-Server-BETA/main/$script_name"; then
            return 0
        fi
        
        attempts=$((attempts + 1))
        if [ $attempts -lt $max_attempts ]; then
            sleep 2
        fi
    done
    
    return 1
}

# Function to check internet connection
check_internet() {
    print_step "Checking internet connection..."
    if ! ping -c 1 -W 3 google.com >/dev/null 2>&1 && ! ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
        print_error "No internet connection detected"
        return 1
    fi
    return 0
}

# Check internet connection
check_internet || exit 1

print_step "[1/8] Installing required packages..."
if ! install_packages; then
    print_warning "Falling back to basic package installation..."
    if ! apt-get update -y >/dev/null 2>&1; then
        print_error "Failed to update package list"
        exit 1
    fi
    
    if ! apt-get install -y libgnustep-base1.28 libdispatch-dev patchelf wget jq screen lsof software-properties-common >/dev/null 2>&1; then
        print_error "Failed to install essential packages"
        exit 1
    fi
    
    # Check if flock was installed in fallback mode
    check_flock
fi

print_step "[2/8] Downloading helper scripts from GitHub..."
for script in "${SCRIPTS[@]}"; do
    if download_script "$script"; then
        print_success "Downloaded: $script"
        chmod +x "$script"
    else
        print_error "Failed to download $script after multiple attempts"
        exit 1
    fi
done

print_step "[3/8] Downloading server archive from archive.org..."
print_progress "Downloading server binary (this may take a moment)..."
if wget $WGET_OPTIONS "$SERVER_URL" -O "$TEMP_FILE"; then
    print_success "Download successful from archive.org"
else
    print_error "Failed to download server file from archive.org"
    exit 1
fi

print_step "[4/8] Extracting files..."
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
    
    if ! patchelf --replace-needed "$LIB" "${LIBS[$LIB]}" "$SERVER_BINARY" >/dev/null 2>&1; then
        print_warning "Failed to patch $LIB"
    fi
done

print_success "Compatibility patches applied"

print_step "[6/8] Set ownership and permissions"
chown "$ORIGINAL_USER:$ORIGINAL_USER" server_manager.sh server_bot.sh anticheat_secure.sh blockheads_common.sh "$SERVER_BINARY" ./*.json 2>/dev/null || true
chmod 755 server_manager.sh server_bot.sh anticheat_secure.sh blockheads_common.sh "$SERVER_BINARY" ./*.json 2>/dev/null || true

print_step "[7/8] Create economy data file"
sudo -u "$ORIGINAL_USER" bash -c 'echo "{\"players\": {}, \"transactions\": []}" > economy_data.json' || true
chown "$ORIGINAL_USER:$ORIGINAL_USER" economy_data.json 2>/dev/null || true

rm -f "$TEMP_FILE"

# Limpieza final de carpetas problemáticas
clean_problematic_dirs

print_step "[8/8] Installation completed successfully"
echo ""

print_header "BINARY INSTRUCTIONS"
./blockheads_server171 -h >/dev/null 2>&1 || print_warning "Server binary execution failed - may need additional dependencies"

print_header "SERVER MANAGER INSTRUCTIONS"
echo -e "${GREEN}0. Create a world: ${CYAN}./blockheads_server171 -n${NC}"
echo -e "${GREEN}1. See world list and ID's: ${CYAN}./blockheads_server171 -l${NC}"
echo -e "${GREEN}2. Start server: ${CYAN}./server_manager.sh start WORLD_ID PORT${NC}"
echo -e "${GREEN}3. Stop server: ${CYAN}./server_manager.sh stop${NC}"
echo -e "${GREEN}4. Check status: ${CYAN}./server_manager.sh status${NC}"
echo -e "${GREEN}5. Default port: ${YELLOW}12153${NC}"
echo -e "${GREEN}6. HELP: ${CYAN}./server_manager.sh help${NC}"
echo ""
print_warning "After creating the world, press CTRL+C to exit"

print_header "INSTALLATION COMPLETE"
echo -e "${GREEN}Your Blockheads server is now ready to use!${NC}"
echo -e "${YELLOW}Don't forget to check the server manager for more options.${NC}"
echo ""
echo -e "${BOLD}Next steps:${NC}"
echo -e " 1. ${CYAN}./blockheads_server171 -n${NC}   (Create a new world)"
echo -e " 2. ${CYAN}./blockheads_server171 -l${NC}   (List your worlds)"
echo -e " 3. ${CYAN}./server_manager.sh start WORLD_ID${NC}   (Start your server)"
echo ""
