#!/bin/bash
set -e

# =============================================================================
# THE BLOCKHEADS LINUX SERVER INSTALLER - ENHANCED SECURITY VERSION
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

# Function to clean problematic directories
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
    'git' 'cmake' 'ninja-build' 'clang' 'systemtap-sdt-dev' 'libbsd-dev' 'linux-libc-dev'
    'curl' 'tar' 'grep' 'mawk' 'patchelf' 'libgnustep-base-dev' 'libobjc4' 'libgnutls28-dev'
    'libgcrypt20-dev' 'libxml2' 'libffi-dev' 'libnsl-dev' 'zlib1g' 'libicu-dev' 'libicu-dev'
    'libstdc++6' 'libgcc-s1' 'wget' 'jq' 'screen' 'lsof' 'binutils' 'objdump'
)

declare -a PACKAGES_ARCH=(
    'base-devel' 'git' 'cmake' 'ninja' 'clang' 'systemtap' 'libbsd' 'curl' 'tar' 'grep' 'gawk'
    'patchelf' 'gnustep-base' 'gcc-libs' 'gnutls' 'libgcrypt' 'libxml2' 'libffi' 'libnsl' 'zlib'
    'icu' 'libdispatch' 'wget' 'jq' 'screen' 'lsof' 'binutils'
)

# Clean problematic directories at start
clean_problematic_dirs

print_header "THE BLOCKHEADS LINUX SERVER INSTALLER"

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
    
    # Clean any existing folders before building
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
    
    cd "${DIR" || return 1
    # Clean after successful installation
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

# =============================================================================
# ENHANCED SECURITY PATCHING FUNCTIONS
# =============================================================================

# Function to find method address with better precision
find_method_address() {
    local binary="$1"
    local method_name="$2"
    
    # Use multiple approaches to find the method
    local address=""
    
    # Approach 1: Search for method name string
    address=$(strings -t x "$binary" | grep "$method_name" | head -1 | awk '{print $1}')
    if [ -n "$address" ]; then
        echo $((16#$address))
        return 0
    fi
    
    # Approach 2: Use objdump for more precise search
    address=$(objdump -t "$binary" | grep "$method_name" | awk '{print $1}' | head -1)
    if [ -n "$address" ]; then
        echo $((16#$address))
        return 0
    fi
    
    return 1
}

# Function to apply enhanced FreightCar patches
apply_enhanced_freightcar_patches() {
    local binary="$1"
    print_step "Applying enhanced FreightCar security patches..."
    
    # Create a backup
    cp "$binary" "${binary}.backup"
    
    # Methods to patch - based on the freightcar.txt content
    local methods=(
        "initWithWorld:dynamicWorld:atPosition:cache:saveDict:placedByClient:"
        "initWithWorld:dynamicWorld:cache:netData:"
        "initWithWorld:dynamicWorld:saveDict:chestSaveDict:cache:"
    )
    
    local success_count=0
    
    for method in "${methods[@]}"; do
        print_status "Patching method: $method"
        
        # Find method address
        local method_addr=$(find_method_address "$binary" "$method")
        if [ -z "$method_addr" ]; then
            print_warning "Method not found: $method"
            continue
        fi
        
        # Find the actual implementation (look for function prologue)
        local impl_offset=0
        local max_search=500
        
        for ((i=0; i<max_search; i++)); do
            local current_addr=$((method_addr + i))
            local bytes=$(dd if="$binary" bs=1 skip=$current_addr count=3 2>/dev/null | od -t x1 -An | tr -d ' \n')
            
            # Look for function prologue (55 48 89 e5) or similar
            if [[ "$bytes" == "554889e5"* ]] || [[ "$bytes" == "55488bec"* ]]; then
                impl_offset=$i
                break
            fi
        done
        
        if [ $impl_offset -eq 0 ]; then
            print_warning "Could not find implementation for: $method"
            continue
        fi
        
        local func_addr=$((method_addr + impl_offset))
        
        # Apply the patch - replace with immediate return nil
        # For x86-64: xor %eax, %eax; retq
        patch_bytes="\x31\xc0\xc3"
        
        # Write the patch
        printf "$patch_bytes" | dd of="$binary" bs=1 seek=$func_addr conv=notrunc 2>/dev/null
        
        if [ $? -eq 0 ]; then
            print_success "Patched method: $method"
            success_count=$((success_count + 1))
            
            # Additional protection: Also patch related methods
            case "$method" in
                *initWithWorld*)
                    # Patch the actionTitle method to return empty string
                    local title_method_addr=$(find_method_address "$binary" "actionTitle")
                    if [ -n "$title_method_addr" ]; then
                        printf "\x48\xc7\xc0\x00\x00\x00\x00\xc3" | dd of="$binary" bs=1 seek=$title_method_addr conv=notrunc 2>/dev/null
                        print_success "Also patched actionTitle method"
                    fi
                    ;;
            esac
        else
            print_warning "Failed to patch method: $method"
        fi
    done
    
    # Additional protection: Patch the itemType method to return invalid type
    local itemtype_addr=$(find_method_address "$binary" "itemType")
    if [ -n "$itemtype_addr" ]; then
        # Return an invalid item type (0)
        printf "\x31\xc0\xc3" | dd of="$binary" bs=1 seek=$itemtype_addr conv=notrunc 2>/dev/null
        print_success "Patched itemType method"
        success_count=$((success_count + 1))
    fi
    
    if [ $success_count -gt 0 ]; then
        print_success "Applied $success_count FreightCar security patches"
        return 0
    else
        print_warning "Failed to apply any FreightCar patches - restoring backup"
        mv "${binary}.backup" "$binary"
        return 1
    fi
}

# Function to apply BHServer patch
apply_bhserver_patch() {
    local binary="$1"
    print_step "Applying BHServer security patch..."
    
    # Create a backup
    cp "$binary" "${binary}.backup"
    
    # Find the method
    local method_addr=$(find_method_address "$binary" "match:didReceiveData:fromPlayer:")
    if [ -z "$method_addr" ]; then
        print_warning "BHServer method not found"
        return 1
    fi
    
    # Find implementation
    local impl_offset=0
    local max_search=500
    
    for ((i=0; i<max_search; i++)); do
        local current_addr=$((method_addr + i))
        local bytes=$(dd if="$binary" bs=1 skip=$current_addr count=3 2>/dev/null | od -t x1 -An | tr -d ' \n')
        
        if [[ "$bytes" == "554889e5"* ]] || [[ "$bytes" == "55488bec"* ]]; then
            impl_offset=$i
            break
        fi
    done
    
    if [ $impl_offset -eq 0 ]; then
        print_warning "Could not find BHServer method implementation"
        return 1
    fi
    
    local func_addr=$((method_addr + impl_offset))
    
    # Apply patch: Add length check at the beginning
    # if (data.length == 0) { return; }
    patch_bytes="\x48\x85\xd2\x0f\x84\x00\x00\x00\x00"  # test rdx, rdx; jz <offset>
    
    printf "$patch_bytes" | dd of="$binary" bs=1 seek=$func_addr conv=notrunc 2>/dev/null
    
    if [ $? -eq 0 ]; then
        print_success "BHServer security patch applied"
        return 0
    else
        print_warning "Failed to apply BHServer patch - restoring backup"
        mv "${binary}.backup" "$binary"
        return 1
    fi
}

# =============================================================================
# MAIN INSTALLATION PROCESS
# =============================================================================

print_step "[1/8] Installing required packages..."
if ! install_packages; then
    print_warning "Falling back to basic package installation..."
    if ! apt-get update -y >/dev/null 2>&1; then
        print_error "Failed to update package list"
        exit 1
    fi
    
    if ! apt-get install -y libgnustep-base1.28 libdispatch-dev patchelf wget jq screen lsof software-properties-common binutils >/dev/null 2>&1; then
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

# =============================================================================
# APPLY ENHANCED SECURITY PATCHES
# =============================================================================
print_step "[5.5/8] Applying enhanced security patches..."

# Apply BHServer patch
apply_bhserver_patch "$SERVER_BINARY"

# Apply enhanced FreightCar patches
apply_enhanced_freightcar_patches "$SERVER_BINARY"

print_success "Security patches applied successfully"

print_step "[6/8] Set ownership and permissions"
chown "$ORIGINAL_USER:$ORIGINAL_USER" server_manager.sh server_bot.sh anticheat_secure.sh blockheads_common.sh "$SERVER_BINARY" ./*.json 2>/dev/null || true
chmod 755 server_manager.sh server_bot.sh anticheat_secure.sh blockheads_common.sh "$SERVER_BINARY" ./*.json 2>/dev/null || true

print_step "[7/8] Create economy data file"
sudo -u "$ORIGINAL_USER" bash -c 'echo "{\"players\": {}, \"transactions\": []}" > economy_data.json' || true
chown "$ORIGINAL_USER:$ORIGINAL_USER" economy_data.json 2>/dev/null || true

rm -f "$TEMP_FILE"

# Final cleanup of problematic directories
clean_problematic_dirs

print_step "[8/8] Installation completed successfully"
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

print_header "ENHANCED SECURITY PATCHES APPLIED"
print_status "✓ BHServer patch: Prevents crash from malformed packets"
print_status "✓ FreightCar patches: Prevents creation of Freight Cars"
print_status "✓ Additional method patches: actionTitle, itemType"

print_header "INSTALLATION COMPLETE"
