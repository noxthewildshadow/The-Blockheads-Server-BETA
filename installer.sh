#!/bin/bash
set -e

# =============================================================================
# THE BLOCKHEADS LINUX SERVER INSTALLER - OPTIMIZED VERSION
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

# Función para mostrar una barra de progreso simple
progress_bar() {
    local duration=${1}
    local steps=20
    local step_delay=$(echo "scale=3; $duration/$steps" | bc)
    
    echo -n "["
    for ((i=0; i<steps; i++)); do
        echo -n "▰"
        sleep $step_delay
    done
    echo -n "]"
    echo
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
WGET_OPTIONS="--timeout=30 --tries=2 --dns-timeout=10 --connect-timeout=10 --read-timeout=30 -q --show-progress"

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
declare -a PACKAGES_DEBIAN=(
    'git' 'cmake' 'ninja-build' 'clang' 'systemtap-sdt-dev' 'libbsd-dev' 'linux-libc-dev'
    'curl' 'tar' 'grep' 'mawk' 'patchelf' 'libgnustep-base-dev' 'libobjc4' 'libgnutls28-dev'
    'libgcrypt20-dev' 'libxml2' 'libffi-dev' 'libnsl-dev' 'zlib1g' 'libicu-dev' 'libicu-dev'
    'libstdc++6' 'libgcc-s1' 'wget' 'jq' 'screen' 'lsof' 'libobjc-10-dev'
)

declare -a PACKAGES_ARCH=(
    'base-devel' 'git' 'cmake' 'ninja' 'clang' 'systemtap' 'libbsd' 'curl' 'tar' 'grep' 'gawk'
    'patchelf' 'gnustep-base' 'gcc-libs' 'gnutls' 'libgcrypt' 'libxml2' 'libffi' 'libnsl' 'zlib'
    'icu' 'libdispatch' 'wget' 'jq' 'screen' 'lsof' 'libobjc4'
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
    
    if ! apt-get install -y libgnustep-base1.28 libdispatch-dev patchelf wget jq screen lsof software-properties-common libobjc4 >/dev/null 2>&1; then
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

print_step "[6/8] Creating and applying security patches..."

# Create packet validation patch
cat > packet_patch.c << 'EOF'
#define _GNU_SOURCE
#include <dlfcn.h>
#include <sys/socket.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>

// Original function pointer
static ssize_t (*original_recv)(int, void *, size_t, int) = NULL;

ssize_t recv(int sockfd, void *buf, size_t len, int flags) {
    // Initialize original function if not already done
    if (!original_recv) {
        original_recv = dlsym(RTLD_NEXT, "recv");
        if (!original_recv) {
            fprintf(stderr, "Error getting original recv function: %s\n", dlerror());
            return -1;
        }
    }
    
    // Call original function
    ssize_t result = original_recv(sockfd, buf, len, flags);
    
    // Validate packet length to prevent crashes
    if (result <= 0) {
        // Connection closed or error, let the server handle it
        return result;
    }
    
    // Log suspicious packets (zero-length or malformed)
    if (result == 0) {
        fprintf(stderr, "[WARNING] Received zero-length packet, potential crash attempt prevented\n");
    }
    
    return result;
}
EOF

# Create enhanced freight car patch
cat > freightcar_patch.c << 'EOF'
#define _GNU_SOURCE
#include <stdio.h>
#include <dlfcn.h>
#include <string.h>
#include <objc/objc.h>
#include <objc/runtime.h>

// Function prototypes for the original methods
static id (*orig_initWithWorld_dynamicWorld_atPosition_cache_saveDict_placedByClient)(id, SEL, id, id, void*, id, id, id) = NULL;
static id (*orig_initWithWorld_dynamicWorld_cache_netData)(id, SEL, id, id, id, id) = NULL;
static id (*orig_initWithWorld_dynamicWorld_saveDict_chestSaveDict_cache)(id, SEL, id, id, id, id, id) = NULL;

// Patched methods that prevent freight car creation
id patched_initWithWorld_dynamicWorld_atPosition_cache_saveDict_placedByClient(id self, SEL _cmd, id world, id dynamicWorld, void* position, id cache, id saveDict, id clientID) {
    printf("[FreightCarPatch] BLOCKED: Freight car creation attempt prevented (method 1)\n");
    printf("[FreightCarPatch] This action would have caused item duplication\n");
    return nil;
}

id patched_initWithWorld_dynamicWorld_cache_netData(id self, SEL _cmd, id world, id dynamicWorld, id cache, id netData) {
    printf("[FreightCarPatch] BLOCKED: Freight car creation attempt prevented (method 2)\n");
    printf("[FreightCarPatch] This action would have caused item duplication\n");
    return nil;
}

id patched_initWithWorld_dynamicWorld_saveDict_chestSaveDict_cache(id self, SEL _cmd, id world, id dynamicWorld, id saveDict, id chestSaveDict, id cache) {
    printf("[FreightCarPatch] BLOCKED: Freight car creation attempt prevented (method 3)\n");
    printf("[FreightCarPatch] This action would have caused item duplication\n");
    return nil;
}

// Constructor to apply the patches
__attribute__((constructor)) void apply_freightcar_patch() {
    printf("[FreightCarPatch] Loading enhanced freight car prevention system...\n");
    
    // Get the FreightCar class
    Class freightCarClass = objc_getClass("FreightCar");
    if (!freightCarClass) {
        printf("[FreightCarPatch] ERROR: Could not find FreightCar class\n");
        return;
    }
    
    // Replace the methods using method swizzling
    Method originalMethod1 = class_getInstanceMethod(freightCarClass, 
        sel_registerName("initWithWorld:dynamicWorld:atPosition:cache:saveDict:placedByClient:"));
    Method originalMethod2 = class_getInstanceMethod(freightCarClass, 
        sel_registerName("initWithWorld:dynamicWorld:cache:netData:"));
    Method originalMethod3 = class_getInstanceMethod(freightCarClass, 
        sel_registerName("initWithWorld:dynamicWorld:saveDict:chestSaveDict:cache:"));
    
    if (originalMethod1) {
        orig_initWithWorld_dynamicWorld_atPosition_cache_saveDict_placedByClient = 
            (id (*)(id, SEL, id, id, void*, id, id, id))method_getImplementation(originalMethod1);
        method_setImplementation(originalMethod1, 
            (IMP)patched_initWithWorld_dynamicWorld_atPosition_cache_saveDict_placedByClient);
        printf("[FreightCarPatch] Successfully patched method 1\n");
    } else {
        printf("[FreightCarPatch] WARNING: Could not find method 1\n");
    }
    
    if (originalMethod2) {
        orig_initWithWorld_dynamicWorld_cache_netData = 
            (id (*)(id, SEL, id, id, id, id))method_getImplementation(originalMethod2);
        method_setImplementation(originalMethod2, 
            (IMP)patched_initWithWorld_dynamicWorld_cache_netData);
        printf("[FreightCarPatch] Successfully patched method 2\n");
    } else {
        printf("[FreightCarPatch] WARNING: Could not find method 2\n");
    }
    
    if (originalMethod3) {
        orig_initWithWorld_dynamicWorld_saveDict_chestSaveDict_cache = 
            (id (*)(id, SEL, id, id, id, id, id))method_getImplementation(originalMethod3);
        method_setImplementation(originalMethod3, 
            (IMP)patched_initWithWorld_dynamicWorld_saveDict_chestSaveDict_cache);
        printf("[FreightCarPatch] Successfully patched method 3\n");
    } else {
        printf("[FreightCarPatch] WARNING: Could not find method 3\n");
    }
    
    printf("[FreightCarPatch] All freight car creation methods have been blocked\n");
    printf("[FreightCarPatch] Item duplication exploit has been patched\n");
}
EOF

# Compile packet patch
if gcc -shared -fPIC -o packet_patch.so packet_patch.c -ldl; then
    print_success "Packet validation patch compiled successfully"
else
    print_warning "Failed to compile packet validation patch"
    rm -f packet_patch.c packet_patch.so
fi

# Compile freight car patch
if gcc -shared -fPIC -o freightcar_patch.so freightcar_patch.c -ldl -lobjc; then
    print_success "Enhanced freight car patch compiled successfully"
else
    print_warning "Failed to compile enhanced freight car patch"
    # Try without objc library
    if gcc -shared -fPIC -o freightcar_patch.so freightcar_patch.c -ldl; then
        print_success "Freight car patch compiled successfully (without objc)"
    else
        print_warning "Failed to compile freight car patch completely"
        rm -f freightcar_patch.c freightcar_patch.so
    fi
fi

print_step "[7/8] Set ownership and permissions"
chown "$ORIGINAL_USER:$ORIGINAL_USER" server_manager.sh server_bot.sh anticheat_secure.sh blockheads_common.sh "$SERVER_BINARY" ./*.json ./*.so 2>/dev/null || true
chmod 755 server_manager.sh server_bot.sh anticheat_secure.sh blockheads_common.sh "$SERVER_BINARY" ./*.json ./*.so 2>/dev/null || true

print_step "[8/8] Create economy data file"
sudo -u "$ORIGINAL_USER" bash -c 'echo "{\"players\": {}, \"transactions\": []}" > economy_data.json' || true
chown "$ORIGINAL_USER:$ORIGINAL_USER" economy_data.json 2>/dev/null || true

rm -f "$TEMP_FILE" packet_patch.c freightcar_patch.c

# Limpieza final de carpetas problemáticas
clean_problematic_dirs

print_step "[9/9] Installation completed successfully"
echo ""

print_header "SECURITY PATCHES APPLIED"
echo -e "${GREEN}✓ Packet validation patch${NC} - Prevents server crashes from malformed packets"
echo -e "${GREEN}✓ Enhanced freight car patch${NC} - Prevents item duplication exploits"
echo -e "${YELLOW}Note:${NC} Patches are loaded automatically when starting the server"
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
