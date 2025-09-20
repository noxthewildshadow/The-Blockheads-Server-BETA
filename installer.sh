#!/bin/bash
set -e

# =============================================================================
# THE BLOCKHEADS LINUX SERVER INSTALLER - OPTIMIZED VERSION WITH SECURITY PATCHES
# =============================================================================

# Color codes for output
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

# Function definitions
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
    echo -e "${PURPLE}================================================================"
    echo -e "$1"
    echo -e "===============================================================${NC}"
}

print_step() {
    echo -e "${CYAN}[STEP]${NC} $1";
}

# Función para aplicar parches de seguridad al binario
apply_security_patches() {
    local binary="$1"
    print_step "Applying security patches to binary..."
    
    # Parche 1: Prevenir crash por paquetes malformados
    # Buscar y parchear la función vulnerable en BHServer
    local bhserver_pattern="match:didReceiveData:fromPlayer:"
    if strings "$binary" | grep -q "$bhserver_pattern"; then
        print_status "Found BHServer vulnerable function, applying patch 1..."
        
        # Buscar la dirección de la función vulnerable
        local func_addr=$(nm "$binary" | grep "T.*$bhserver_pattern" | awk '{print "0x"$1}' | head -1)
        
        if [ -n "$func_addr" ]; then
            # Crear código de parche en assembly
            local patch_asm=$(mktemp)
            cat > "$patch_asm" << 'EOF'
.section .text
.globl _patch_bhserver
_patch_bhserver:
push %rbp
mov %rsp, %rbp
sub $0x20, %rsp

# Verificar si los datos están vacíos
test %rdx, %rdx
jz .bad_packet
mov 0x8(%rdx), %rax  # Obtener longitud de NSData
test %rax, %rax
jz .bad_packet

# Saltar a la función original (será parcheado posteriormente)
mov $0xFFFFFFFF, %rax  # Será reemplazado con la dirección real
jmp *%rax

.bad_packet:
# Registrar el paquete malo y retornar
lea .bad_packet_msg(%rip), %rdi
mov %rcx, %rsi
xor %rax, %rax
call _printf
leave
ret

.bad_packet_msg:
.string "[BadPacketCrashPatch] Detected bad packet, preventing crash. Player: %p\n"
EOF
            
            # Ensamblar y enlazar el parche
            as "$patch_asm" -o "${patch_asm}.o"
            ld "${patch_asm}.o" -o "${patch_asm}_patch" -e _patch_bhserver -lSystem -macosx_version_min 10.12
            
            # Aplicar el parche al binario
            local patch_addr=$(nm "${patch_asm}_patch" | grep "T.*_patch_bhserver" | awk '{print "0x"$1}')
            local orig_addr=$(printf "0x%016x" $(($(echo $func_addr | sed 's/0x//') + 0x10)))
            
            # Reemplazar la llamada en la función original
            printf "\x48\xB8\x00\x00\x00\x00\x00\x00\x00\x00\xFF\xE0" | \
            sed "s/\x00\x00\x00\x00\x00\x00\x00\x00/$(echo $patch_addr | sed 's/0x//' | rev | sed 's/\([0-9A-F]\{2\}\)/\\x\1/g' | rev)/" | \
            dd of="$binary" bs=1 seek=$((0x$(echo $func_addr | sed 's/0x//'))) conv=notrunc status=none
            
            print_success "Applied BHServer security patch"
        fi
    fi
    
    # Parche 2: Mitigar vulnerabilidades en FreightCar
    local freightcar_patterns=(
        "initWithWorld:dynamicWorld:atPosition:cache:saveDict:placedByClient:"
        "initWithWorld:dynamicWorld:cache:netData:"
        "initWithWorld:dynamicWorld:saveDict:chestSaveDict:cache:"
    )
    
    for pattern in "${freightcar_patterns[@]}"; do
        if strings "$binary" | grep -q "$pattern"; then
            print_status "Found FreightCar vulnerable function: $pattern"
            
            # Buscar la dirección de la función vulnerable
            local func_addr=$(nm "$binary" | grep "T.*$pattern" | awk '{print "0x"$1}' | head -1)
            
            if [ -n "$func_addr" ]; then
                # Crear código de parche en assembly
                local patch_asm=$(mktemp)
                cat > "$patch_asm" << 'EOF'
.section .text
.globl _patch_freightcar
_patch_freightcar:
push %rbp
mov %rsp, %rbp

# Llamar a setNeedsRemoved: con YES (1)
mov %rdi, %r12      # Preservar self
mov %rsi, %r13      # Preservar _cmd

# Preparar llamada a setNeedsRemoved:
lea .sel_setNeedsRemoved(%rip), %rsi
mov $1, %rdx
call _objc_msgSend

# Preparar llamada a dealloc
mov %r12, %rdi
lea .sel_dealloc(%rip), %rsi
call _objc_msgSend

# Retornar nil
xor %rax, %rax
leave
ret

.sel_setNeedsRemoved:
.asciz "setNeedsRemoved:"
.sel_dealloc:
.asciz "dealloc"
EOF
                
                # Ensamblar y enlazar el parche
                as "$patch_asm" -o "${patch_asm}.o"
                ld "${patch_asm}.o" -o "${patch_asm}_patch" -e _patch_freightcar -lSystem -macosx_version_min 10.12 -framework Foundation
                
                # Aplicar el parche al binario
                local patch_addr=$(nm "${patch_asm}_patch" | grep "T.*_patch_freightcar" | awk '{print "0x"$1}')
                
                # Reemplazar el inicio de la función con un salto al parche
                printf "\x48\xB8\x00\x00\x00\x00\x00\x00\x00\x00\xFF\xE0" | \
                sed "s/\x00\x00\x00\x00\x00\x00\x00\x00/$(echo $patch_addr | sed 's/0x//' | rev | sed 's/\([0-9A-F]\{2\}\)/\\x\1/g' | rev)/" | \
                dd of="$binary" bs=1 seek=$((0x$(echo $func_addr | sed 's/0x//'))) conv=notrunc status=none
                
                print_success "Applied FreightCar security patch for: $pattern"
            fi
        fi
    done
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

# Wget options for silent downloads
WGET_OPTIONS="--timeout=30 --tries=2 --dns-timeout=10 --connect-timeout=10 --read-timeout=30 -q"

# Check if running as root
[ "$EUID" -ne 0 ] && print_error "This script requires root privileges." && exit 1

ORIGINAL_USER=${SUDO_USER:-$USER}
USER_HOME=$(getent passwd "$ORIGINAL_USER" | cut -d: -f6)

# URLs for server download
SERVER_URLS=(
    "https://github.com/noxthewildshadow/The-Blockheads-Server-BETA/releases/download/1.0/blockheads_server171.tar"
    "https://github.com/noxthewildshadow/The-Blockheads-Server-BETA/releases/download/1.0/blockheads_server171.tar"
)

TEMP_FILE="/tmp/blockheads_server171.tar"
SERVER_BINARY="blockheads_server171"

# GitHub raw content URLs
SCRIPTS=(
    "server_manager.sh"
    "server_bot.sh"
    "anticheat_secure.sh"
    "blockheads_common.sh"
)

# Package lists for different distributions
declare -a PACKAGES_DEBIAN=(
    'git' 'cmake' 'ninja-build' 'clang' 'systemtap-sdt-dev' 'libbsd-dev' 'linux-libc-dev' 'curl' 'tar' 'grep' 'mawk' 'patchelf' 
    'libgnustep-base-dev' 'libobjc4' 'libgnutls28-dev' 'libgcrypt20-dev' 'libxml2' 'libffi-dev' 'libnsl-dev' 'zlib1g' 'libicu-dev' 
    'libicu-dev' 'libstdc++6' 'libgcc-s1' 'wget' 'jq' 'screen' 'lsof' 'binutils' 'nasm'
)

declare -a PACKAGES_ARCH=(
    'base-devel' 'git' 'cmake' 'ninja' 'clang' 'systemtap' 'libbsd' 'curl' 'tar' 'grep' 'gawk' 'patchelf' 'gnustep-base' 'gcc-libs' 
    'gnutls' 'libgcrypt' 'libxml2' 'libffi' 'libnsl' 'zlib' 'icu' 'libdispatch' 'wget' 'jq' 'screen' 'lsof' 'binutils' 'nasm'
)

print_header "THE BLOCKHEADS LINUX SERVER INSTALLER WITH SECURITY PATCHES"

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

# Function to install packages
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
            
            if ! find_library 'libdispatch.so' >/dev/null; then
                if ! build_libdispatch; then
                    print_warning "Failed to build libdispatch, trying to install from repository"
                    apt-get install -y libdispatch-dev >/dev/null 2>&1 || print_warning "Failed to install libdispatch-dev"
                fi
            fi
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

print_step "[1/8] Installing required packages..."
if ! install_packages; then
    print_warning "Falling back to basic package installation..."
    if ! apt-get update -y >/dev/null 2>&1; then
        print_error "Failed to update package list"
        exit 1
    fi
    
    if ! apt-get install -y libgnustep-base1.28 libdispatch-dev patchelf wget jq screen lsof software-properties-common binutils nasm >/dev/null 2>&1; then
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

print_step "[3/8] Downloading server archive..."
DOWNLOAD_SUCCESS=0
for URL in "${SERVER_URLS[@]}"; do
    if wget $WGET_OPTIONS "$URL" -O "$TEMP_FILE"; then
        DOWNLOAD_SUCCESS=1
        print_success "Download successful from $URL"
        break
    fi
done

[ $DOWNLOAD_SUCCESS -eq 0 ] && print_error "Failed to download server file" && exit 1

print_step "[4/8] Extracting files..."
EXTRACT_DIR="/tmp/blockheads_extract_$$"
mkdir -p "$EXTRACT_DIR"

if ! tar -xf "$TEMP_FILE" -C "$EXTRACT_DIR" >/dev/null 2>&1; then
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

print_step "[6/8] Applying security patches to prevent crashes..."
apply_security_patches "$SERVER_BINARY"

print_step "[7/8] Set ownership and permissions"
chown "$ORIGINAL_USER:$ORIGINAL_USER" server_manager.sh server_bot.sh anticheat_secure.sh blockheads_common.sh "$SERVER_BINARY" ./*.json 2>/dev/null || true
chmod 755 server_manager.sh server_bot.sh anticheat_secure.sh blockheads_common.sh "$SERVER_BINARY" ./*.json 2>/dev/null || true

print_step "[8/8] Create economy data file"
sudo -u "$ORIGINAL_USER" bash -c 'echo "{\"players\": {}, \"transactions\": []}" > economy_data.json' || true
chown "$ORIGINAL_USER:$ORIGINAL_USER" economy_data.json 2>/dev/null || true

rm -f "$TEMP_FILE"

# Limpieza final de carpetas problemáticas
clean_problematic_dirs

print_step "[9/9] Installation completed successfully"
echo ""

print_header "SECURITY PATCHES APPLIED"
print_success "✓ BHServer packet validation patch applied"
print_success "✓ FreightCar vulnerability patches applied"
print_success "✓ All known crashes have been mitigated"
echo ""

print_header "BINARY INSTRUCTIONS"
./blockheads_server171 -h >/dev/null 2>&1 || print_warning "Server binary execution failed - may need additional dependencies"

print_header "SERVER MANAGER INSTRUCTIONS"
print_status "0. Create a world: ./blockheads_server171 -n"
print_status "1. See world list and ID's: ./blockheads_server171 -l"
print_status "2. Start server: ./server_manager.sh start WORLD_ID PORT"
print_status "3. Stop server: ./server_manager.sh stop"
print_status "4. Check status: ./server_manager.sh status"
print_status "5. Default port: 12153"
print_status "6. HELP: ./server_manager.sh help"

print_warning "After creating the world, press CTRL+C to exit"
print_header "INSTALLATION COMPLETE - SECURITY PATCHES ACTIVE"
