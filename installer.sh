#!/bin/bash
set -euo pipefail

# =============================================================================
# THE BLOCKHEADS LINUX SERVER INSTALLER - ROBUST + KITWARE KEY AUTO-FIX
# =============================================================================
# This installer includes robust network/apt handling and will automatically
# install the Kitware GPG key & source entry to avoid NO_PUBKEY errors.
# Run as root: sudo ./installer_fix_kitware.sh
# =============================================================================

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
CYAN='\033[0;36m'; PURPLE='\033[0;35m'; NC='\033[0m'

print_header() { echo -e "${PURPLE}================================================================${NC}"; echo -e "${PURPLE}$1${NC}"; echo -e "${PURPLE}================================================================${NC}"; }
print_step()    { echo -e "${CYAN}[STEP]${NC} $1"; }
print_status()  { echo -e "${BLUE}[INFO]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

# Must be run as root
if [ "$EUID" -ne 0 ]; then
    print_error "This script requires root privileges. Run: sudo $0"
    exit 1
fi

ORIGINAL_USER=${SUDO_USER:-$USER}
USER_HOME=$(getent passwd "$ORIGINAL_USER" | cut -d: -f6 || echo "/home/$ORIGINAL_USER")

WGET_OPTIONS="--timeout=30 --tries=2 --dns-timeout=10 --connect-timeout=10 --read-timeout=30 -q"

SERVER_URLS=(
    "https://github.com/noxthewildshadow/The-Blockheads-Server-BETA/releases/download/1.0/blockheads_server171.tar"
)

TEMP_FILE="/tmp/blockheads_server171.tar"
SERVER_BINARY="blockheads_server171"

SCRIPTS=( "server_manager.sh" "server_bot.sh" "anticheat_secure.sh" "blockheads_common.sh" )

PACKAGES_DEBIAN=( git cmake ninja-build clang systemtap-sdt-dev libbsd-dev linux-libc-dev curl tar grep mawk patchelf libgnustep-base-dev libobjc4 libgnutls28-dev libgcrypt20-dev libxml2 libffi-dev libnsl-dev zlib1g libicu-dev libstdc++6 libgcc-s1 wget jq screen lsof )
PACKAGES_ARCH=( base-devel git cmake ninja clang systemtap libbsd curl tar grep gawk patchelf gnustep-base gcc-libs gnutls libgcrypt libxml2 libffi libnsl zlib icu libdispatch wget jq screen lsof )

# ---------- Utilities ----------
safe_sleep() { local t="$1"; for i in $(seq 1 "$t"); do sleep 1; done; }

wait_for_apt_unlock() {
    print_status "Waiting for apt/dpkg locks to be released if present..."
    local tries=0
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/dpkg/lock >/dev/null 2>&1; do
        tries=$((tries+1))
        if [ $tries -gt 30 ]; then
            print_warning "Persistent apt locks detected, trying dpkg --configure -a"
            dpkg --configure -a || true
        fi
        sleep 1
    done
}

network_check() {
    print_status "Checking network connectivity..."
    if ping -c1 -W1 8.8.8.8 >/dev/null 2>&1; then
        print_status "IP connectivity to the Internet detected (8.8.8.8 responded)."
    else
        print_error "Cannot reach 8.8.8.8. Check your network connection / NAT / firewall."
        return 1
    fi

    if ping -c1 -W2 github.com >/dev/null 2>&1; then
        print_status "DNS resolution works (github.com resolves)."
    else
        print_warning "Failed to resolve github.com: possible DNS issue. Trying to use 8.8.8.8 temporarily."
        if [ -w /etc/resolv.conf ] || [ ! -e /etc/resolv.conf ]; then
            cp -n /etc/resolv.conf /etc/resolv.conf.bak 2>/dev/null || true
            echo "nameserver 8.8.8.8" > /etc/resolv.conf
            print_status "Temporarily wrote 'nameserver 8.8.8.8' to /etc/resolv.conf for diagnosis."
            if ping -c1 -W2 github.com >/dev/null 2>&1; then
                print_status "DNS temporarily fixed."
            else
                print_error "DNS still failing even with 8.8.8.8. Check your network/proxy configuration."
                return 1
            fi
        else
            print_warning "/etc/resolv.conf is not writable. Skipping DNS fix."
            return 1
        fi
    fi
    return 0
}

apt_update_retry() {
    local max_try=5
    local try=1
    while [ $try -le $max_try ]; do
        print_status "Attempting apt-get update (#$try/$max_try)..."
        wait_for_apt_unlock
        if apt-get update -o Acquire::Retries=3 >/tmp/apt_update_out 2>&1; then
            print_success "apt-get update completed."
            return 0
        fi
        # Inspect output for release-change message
        if grep -i "Release file" /tmp/apt_update_out >/dev/null 2>&1 || grep -i "allow-releaseinfo-change" /tmp/apt_update_out >/dev/null 2>&1; then
            print_warning "Detected repository Release change. Retrying with --allow-releaseinfo-change..."
            if apt-get update --allow-releaseinfo-change >/tmp/apt_update_out 2>&1; then
                print_success "apt-get update (--allow-releaseinfo-change) completed."
                return 0
            fi
        fi
        try=$((try+1))
        sleep 2
    done

    print_error "apt-get update failed after multiple attempts. Diagnostic output:"
    sed -n '1,200p' /tmp/apt_update_out || true
    return 1
}

apt_install_with_retry() {
    local pkg="$1"
    local tries=0
    local max=3
    while [ $tries -lt $max ]; do
        if apt-get install -y "$pkg" >/tmp/apt_install_out 2>&1; then
            print_success "Installed: $pkg"
            return 0
        fi
        tries=$((tries+1))
        print_warning "Failed installing $pkg (attempt $tries/$max). Retrying..."
        sleep 2
    done
    print_warning "Trying installation with --fix-missing for $pkg ..."
    if apt-get install -y --fix-missing "$pkg" >/tmp/apt_install_out 2>&1; then
        print_success "Installed (fix-missing): $pkg"
        return 0
    fi
    print_warning "Could not install $pkg. See /tmp/apt_install_out for details"
    sed -n '1,200p' /tmp/apt_install_out || true
    return 1
}

download_script() {
    local script_name="$1"
    local attempts=0
    local max_attempts=3
    while [ $attempts -lt $max_attempts ]; do
        if wget $WGET_OPTIONS -O "$script_name" "https://raw.githubusercontent.com/noxthewildshadow/The-Blockheads-Server-BETA/main/$script_name"; then
            chmod +x "$script_name"
            return 0
        fi
        attempts=$((attempts+1))
        sleep 2
    done
    return 1
}

find_library() {
    local SEARCH="$1"
    ldconfig -p 2>/dev/null | grep -F "$SEARCH" -m 1 | awk '{print $NF}' | head -1 || return 1
}

build_libdispatch() {
    print_step "Building libdispatch from source (optional, heavy operation)..."
    local DIR="/tmp/swift-corelibs-libdispatch-$$"
    rm -rf "$DIR"
    if ! git clone --depth 1 'https://github.com/swiftlang/swift-corelibs-libdispatch.git' "$DIR" >/dev/null 2>&1; then
        print_error "Failed to clone libdispatch"
        return 1
    fi
    mkdir -p "$DIR/build"
    pushd "$DIR/build" >/dev/null
    if ! cmake -G Ninja -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ .. >/dev/null 2>&1; then
        print_error "CMake failed for libdispatch"
        popd >/dev/null
        return 1
    fi
    if ! ninja "-j$(nproc)" >/dev/null 2>&1 || ! ninja install >/dev/null 2>&1; then
        print_error "Build/install of libdispatch failed"
        popd >/dev/null
        return 1
    fi
    popd >/dev/null
    ldconfig || true
    return 0
}

# ------------------ NEW: Kitware key & source fix ------------------
install_kitware_key_and_source() {
    print_step "Ensuring Kitware APT key and source are present (auto-fix)..."
    local keyring_dir="/usr/share/keyrings"
    local keyring_file="${keyring_dir}/kitware-archive-keyring.gpg"
    local distro_codename
    distro_codename=$(lsb_release -cs 2>/dev/null || echo "jammy")

    mkdir -p "$keyring_dir"

    # Try to fetch and dearmor the key
    if curl -fsSL https://apt.kitware.com/keys/kitware-archive-latest.asc | gpg --dearmor >"$keyring_file" 2>/tmp/kitware_key_err 2>&1; then
        chmod 644 "$keyring_file" || true
        print_status "Kitware key fetched and installed to $keyring_file"
    else
        print_warning "Failed to fetch/dearmor Kitware key with curl/gpg. See /tmp/kitware_key_err"
        # Fallback: try apt-key (deprecated) to import by ID (id from error)
        local keyid="16FAAD7AF99A65E2"
        if command -v apt-key >/dev/null 2>&1; then
            print_warning "Attempting fallback import with apt-key..."
            apt-key adv --keyserver keyserver.ubuntu.com --recv-keys "$keyid" >/tmp/aptkey_out 2>&1 || true
            print_status "apt-key fallback attempted (check /tmp/aptkey_out)."
        else
            print_warning "apt-key not available; cannot fallback. You may need to install gnupg and curl."
        fi
    fi

    # Write/replace the kitware sources list with signed-by if keyring present
    if [ -f "$keyring_file" ]; then
        echo "deb [signed-by=${keyring_file}] https://apt.kitware.com/ubuntu/ ${distro_codename} main" > /etc/apt/sources.list.d/kitware.list
        print_status "Kitware source written to /etc/apt/sources.list.d/kitware.list with signed-by."
    else
        # If keyring not available but apt-key added key, keep existing or write a plain entry
        if grep -q "apt.kitware.com" /etc/apt/sources.list.d/* 2>/dev/null || grep -q "apt.kitware.com" /etc/apt/sources.list 2>/dev/null; then
            print_status "Kitware source already present somewhere. Skipping third-party source write."
        else
            echo "deb https://apt.kitware.com/ubuntu/ ${distro_codename} main" > /etc/apt/sources.list.d/kitware.list
            print_warning "Kitware source written without signed-by (keyring missing). apt may still warn if key is missing."
        fi
    fi
    print_status "Kitware key/source ensure step complete."
}
# --------------------------------------------------------------------

install_packages() {
    if [ ! -f /etc/os-release ]; then
        print_error "Cannot detect OS (/etc/os-release missing)."
        return 1
    fi
    source /etc/os-release

    case "$ID" in
        debian|ubuntu|pop)
            print_step "Installing packages for Debian/Ubuntu..."
            if ! network_check; then
                print_error "Network or DNS issue detected. Aborting package installation."
                return 1
            fi

            # --- Ensure Kitware key/source BEFORE updating apt ---
            install_kitware_key_and_source

            if ! apt_update_retry; then
                print_error "Could not update package list (apt-get update)."
                return 1
            fi

            for pkg in "${PACKAGES_DEBIAN[@]}"; do
                apt_install_with_retry "$pkg" || print_warning "Continuing even though $pkg failed"
            done

            # Check libdispatch
            if ! find_library 'libdispatch.so' >/dev/null 2>&1; then
                print_warning "libdispatch not found; trying build or repository package"
                if ! build_libdispatch; then
                    apt_install_with_retry libdispatch-dev || print_warning "Could not obtain libdispatch-dev"
                fi
            fi
            ;;
        arch)
            print_step "Installing packages for Arch Linux..."
            if ! pacman -Sy --noconfirm --needed "${PACKAGES_ARCH[@]}" >/tmp/pacman_out 2>&1; then
                print_error "pacman failed. See /tmp/pacman_out"
                sed -n '1,200p' /tmp/pacman_out || true
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

# ------------------ Main script ------------------
print_header "THE BLOCKHEADS LINUX SERVER INSTALLER - ROBUST + KITWARE AUTO-FIX"

print_step "[1/8] Installing required packages..."
if ! install_packages; then
    print_warning "Attempting minimal fallback package installation..."
    wait_for_apt_unlock
    if ! apt_update_retry; then
        print_error "Cannot update package list in fallback. Aborting."
        exit 1
    fi
    for p in libgnustep-base1.28 libdispatch-dev patchelf wget jq screen lsof; do
        apt_install_with_retry "$p" || print_warning "Failed to install $p in fallback"
    done
fi

print_step "[2/8] Downloading helper scripts from GitHub..."
for script in "${SCRIPTS[@]}"; do
    if download_script "$script"; then
        print_success "Downloaded: $script"
    else
        print_error "Failed to download $script after several attempts"
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
if [ $DOWNLOAD_SUCCESS -eq 0 ]; then
    print_error "Failed to download server archive from all URLs."
    exit 1
fi

print_step "[4/8] Extracting files..."
EXTRACT_DIR="/tmp/blockheads_extract_$$"
mkdir -p "$EXTRACT_DIR"
if ! tar -xf "$TEMP_FILE" -C "$EXTRACT_DIR"; then
    print_error "Failed to extract $TEMP_FILE"
    rm -rf "$EXTRACT_DIR"
    exit 1
fi
cp -r "$EXTRACT_DIR"/* ./
rm -rf "$EXTRACT_DIR"

if [ ! -f "$SERVER_BINARY" ]; then
    ALTERNATIVE_BINARY=$(find . -name "*blockheads*" -type f -executable | head -n 1 || true)
    if [ -n "$ALTERNATIVE_BINARY" ]; then
        mv "$ALTERNATIVE_BINARY" "blockheads_server171" || true
        SERVER_BINARY="blockheads_server171"
    fi
fi

if [ ! -f "$SERVER_BINARY" ]; then
    print_error "Server binary not found after extraction."
    exit 1
fi
chmod +x "$SERVER_BINARY"

print_step "[5/8] Applying patchelf compatibility adjustments..."
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

for LIB in "${!LIBS[@]}"; do
    [ -z "${LIBS[$LIB]}" ] && continue
    if ! patchelf --replace-needed "$LIB" "${LIBS[$LIB]}" "$SERVER_BINARY" >/tmp/patchelf_out 2>&1; then
        print_warning "Could not patchelf $LIB (see /tmp/patchelf_out)"
    fi
done

print_success "Compatibility patches applied where possible."

print_step "[6/8] Setting ownership and permissions"
chown "$ORIGINAL_USER:$ORIGINAL_USER" server_manager.sh server_bot.sh anticheat_secure.sh blockheads_common.sh "$SERVER_BINARY" ./*.json 2>/dev/null || true
chmod 755 server_manager.sh server_bot.sh anticheat_secure.sh blockheads_common.sh "$SERVER_BINARY" ./*.json 2>/dev/null || true

print_step "[7/8] Creating economy data file"
sudo -u "$ORIGINAL_USER" bash -c 'echo "{\"players\": {}, \"transactions\": []}" > economy_data.json' || true
chown "$ORIGINAL_USER:$ORIGINAL_USER" economy_data.json 2>/dev/null || true

rm -f "$TEMP_FILE"

print_step "[8/8] Installation completed"
print_header "BINARY INSTRUCTIONS"
./blockheads_server171 -h >/dev/null 2>&1 || print_warning "Server binary may require additional dependencies to run."

print_header "SERVER MANAGER INSTRUCTIONS"
print_status "1. Create a world: ./blockheads_server171 -n"
print_status "2. Start server: ./server_manager.sh start WORLD_ID PORT"
print_status "3. Stop server: ./server_manager.sh stop"
print_status "4. Check status: ./server_manager.sh status"
print_status "5. Default port: 12153"
print_status "6. HELP: ./server_manager.sh help"
print_warning "After creating the world, press CTRL+C to exit"
print_header "INSTALLATION COMPLETE"
