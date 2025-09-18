#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# THE BLOCKHEADS LINUX SERVER INSTALLER - CORRECTED & MORE ROBUST (ENGLISH)
# =============================================================================
# Usage: sudo ./installer_fix_kitware_fixed_en.sh
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

# Check root
if [ "$EUID" -ne 0 ]; then
    print_error "This script requires root privileges. Run: sudo $0"
    exit 1
fi

ORIGINAL_USER=${SUDO_USER:-$USER}
USER_HOME=$(getent passwd "$ORIGINAL_USER" | cut -d: -f6 || echo "/home/$ORIGINAL_USER")

WGET_OPTIONS="--timeout=30 --tries=3 --dns-timeout=10 --connect-timeout=10 --read-timeout=30 -q"

SERVER_URLS=( "https://github.com/noxthewildshadow/The-Blockheads-Server-BETA/releases/download/1.0/blockheads_server171.tar" )
TEMP_FILE="/tmp/blockheads_server171.tar"
SERVER_BINARY="blockheads_server171"
SCRIPTS=( "server_manager.sh" "server_bot.sh" "anticheat_secure.sh" "blockheads_common.sh" )

# Base packages (debian/ubuntu)
PACKAGES_DEBIAN=( apt-transport-https ca-certificates curl gnupg lsb-release apt-file wget tar jq patchelf build-essential cmake ninja-build clang pkg-config libtool autoconf automake git )

# Recommended runtime packages for Objective-C / GNUstep
RUNTIME_PKGS=( libobjc4 libgnustep-base1.28 gnustep-base-runtime libdispatch-dev )

safe_sleep() { local t="$1"; for i in $(seq 1 "$t"); do sleep 1; done; }

wait_for_apt_unlock() {
    print_status "Waiting for apt/dpkg locks if present..."
    local tries=0
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/dpkg/lock >/dev/null 2>&1; do
        tries=$((tries+1))
        if [ $tries -gt 30 ]; then
            print_warning "Persistent locks detected, trying dpkg --configure -a"
            dpkg --configure -a || true
        fi
        sleep 1
    done
}

network_check() {
    print_status "Checking connectivity..."
    if ping -c1 -W1 8.8.8.8 >/dev/null 2>&1; then
        print_status "IP connectivity OK."
    else
        print_error "No IP connectivity. Check network/NAT/firewall."
        return 1
    fi
    if ping -c1 -W2 github.com >/dev/null 2>&1; then
        print_status "DNS resolving OK."
    else
        print_warning "DNS to github.com failed; trying temporary 8.8.8.8 in /etc/resolv.conf"
        if [ -w /etc/resolv.conf ] || [ ! -e /etc/resolv.conf ]; then
            cp -n /etc/resolv.conf /etc/resolv.conf.bak 2>/dev/null || true
            echo "nameserver 8.8.8.8" > /etc/resolv.conf
            if ping -c1 -W2 github.com >/dev/null 2>&1; then
                print_status "Temporary DNS OK."
            else
                print_error "DNS still failing after writing 8.8.8.8."
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
        print_status "Running apt-get update (#$try/$max_try)..."
        wait_for_apt_unlock
        if apt-get update -o Acquire::Retries=3 >/tmp/apt_update_out 2>&1; then
            print_success "apt-get update completed."
            return 0
        fi
        if grep -i "Release file" /tmp/apt_update_out >/dev/null 2>&1 || grep -i "allow-releaseinfo-change" /tmp/apt_update_out >/dev/null 2>&1; then
            print_warning "Repository release change detected. Retrying with --allow-releaseinfo-change..."
            if apt-get update --allow-releaseinfo-change >/tmp/apt_update_out 2>&1; then
                print_success "apt-get update (--allow-releaseinfo-change) completed."
                return 0
            fi
        fi
        try=$((try+1))
        sleep 2
    done
    print_error "apt-get update failed. Diagnostic output:"
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
    print_warning "Trying install with --fix-missing for $pkg..."
    if apt-get install -y --fix-missing "$pkg" >/tmp/apt_install_out 2>&1; then
        print_success "Installed (fix-missing): $pkg"
        return 0
    fi
    print_warning "Could not install $pkg. See /tmp/apt_install_out"
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
        attempts=$((attempts+1)); sleep 2
    done
    return 1
}

find_library() {
    local SEARCH="$1"
    ldconfig -p 2>/dev/null | grep -F "$SEARCH" -m 1 | awk '{print $NF}' | head -1 || return 1
}

install_kitware_key_and_source() {
    print_step "Ensuring Kitware APT key and source..."
    local keyring_dir="/usr/share/keyrings"
    local keyring_file="${keyring_dir}/kitware-archive-keyring.gpg"
    local distro_codename
    distro_codename=$(lsb_release -cs 2>/dev/null || echo "jammy")
    mkdir -p "$keyring_dir"

    if command -v gpg >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
        if curl -fsSL https://apt.kitware.com/keys/kitware-archive-latest.asc | gpg --dearmor > "${keyring_file}" 2>/tmp/kitware_key_err 2>&1; then
            chmod 644 "$keyring_file" || true
            print_status "Kitware key installed to $keyring_file"
        else
            print_warning "Failed fetching/dearmoring Kitware key. See /tmp/kitware_key_err"
        fi
    else
        print_warning "gpg or curl not available; skipping Kitware key download for now."
    fi

    if [ -f "$keyring_file" ]; then
        echo "deb [signed-by=${keyring_file}] https://apt.kitware.com/ubuntu/ ${distro_codename} main" > /etc/apt/sources.list.d/kitware.list
        print_status "Kitware source written with signed-by."
    else
        if ! grep -q "apt.kitware.com" /etc/apt/sources.list.d/* 2>/dev/null && ! grep -q "apt.kitware.com" /etc/apt/sources.list 2>/dev/null; then
            echo "deb https://apt.kitware.com/ubuntu/ ${distro_codename} main" > /etc/apt/sources.list.d/kitware.list
            print_warning "Kitware source written WITHOUT signed-by (key missing). apt may warn."
        else
            print_status "Kitware source already present."
        fi
    fi
    print_status "Kitware step complete."
}

ensure_universe() {
    if command -v add-apt-repository >/dev/null 2>&1; then
        if grep -Ei "ubuntu" /etc/os-release >/dev/null 2>&1; then
            print_status "Enabling 'universe' repository (if applicable)..."
            add-apt-repository -y universe || true
        fi
    fi
}

prepare_basic_packages() {
    print_step "Installing base packages..."
    ensure_universe
    apt_update_retry
    for p in "${PACKAGES_DEBIAN[@]}"; do
        apt_install_with_retry "$p" || print_warning "Continuing even if $p failed"
    done

    if ! command -v apt-file >/dev/null 2>&1; then
        apt_install_with_retry apt-file || true
    fi
    if command -v apt-file >/dev/null 2>&1; then
        apt-file update || true
    fi
}

install_runtime_pkgs() {
    print_step "Attempting to install Objective-C / GNUstep runtime packages..."
    local ok=0
    for pkg in "${RUNTIME_PKGS[@]}"; do
        if apt_install_with_retry "$pkg"; then
            ok=1
        fi
    done

    if [ $ok -eq 1 ]; then
        print_success "At least one runtime package installed."
        return 0
    fi

    print_warning "Could not install runtime packages directly. Trying to locate package that provides libobjc.so.4..."
    if command -v apt-file >/dev/null 2>&1; then
        apt-file search libobjc.so.4 | head -n 20 || true
    fi

    print_status "Attempting 'apt-get download libobjc4' as fallback..."
    if apt-get download libobjc4 >/tmp/apt_download_libobjc.log 2>&1; then
        dpkg -i ./*.deb || apt-get install -f -y
        print_success "libobjc4 downloaded and installed (download)."
        return 0
    else
        print_warning "apt-get download did not find libobjc4 or failed. Showing apt-cache policy libobjc4..."
        apt-cache policy libobjc4 || true
    fi

    print_warning "No prebuilt libobjc package found for this system. Attempting to build libobjc2 from source (heavy)."
    if ! command -v git >/dev/null 2>&1; then
        apt_install_with_retry git || print_warning "git not available; build will fail"
    fi
    set +e
    TMPBUILD="/tmp/libobjc_build_$$"
    rm -rf "$TMPBUILD"
    mkdir -p "$TMPBUILD"
    print_status "Cloning libobjc2 (gnustep/libobjc2)..."
    git clone --depth 1 https://github.com/gnustep/libobjc2.git "$TMPBUILD" >/tmp/libobjc_clone.log 2>&1 || true
    if [ -d "$TMPBUILD" ]; then
        pushd "$TMPBUILD" >/dev/null || true
        mkdir -p build && cd build
        cmake .. -DCMAKE_BUILD_TYPE=Release >/tmp/libobjc_cmake.log 2>&1 || true
        make -j"$(nproc)" >/tmp/libobjc_make.log 2>&1 || true
        make install >/tmp/libobjc_install.log 2>&1 || true
        popd >/dev/null || true
        ldconfig || true
        if find_library "libobjc.so" >/dev/null 2>&1; then
            print_success "libobjc2 build/install completed."
            set -e
            return 0
        else
            print_warning "Build did not produce a usable libobjc. Check /tmp/libobjc_* logs."
        fi
    else
        print_warning "Could not clone libobjc2; skipping build."
    fi
    set -e

    print_error "Could not install libobjc automatically on this system."
    return 1
}

apply_patchelf_adjustments() {
    print_step "Applying patchelf adjustments..."
    declare -A LIBS=(
        ["libgnustep-base.so.1.24"]="$(find_library 'libgnustep-base.so' || echo '')"
        ["libobjc.so.4.6"]="$(find_library 'libobjc.so' || echo '')"
        ["libgnutls.so.26"]="$(find_library 'libgnutls.so' || echo '')"
        ["libgcrypt.so.11"]="$(find_library 'libgcrypt.so' || echo '')"
        ["libffi.so.6"]="$(find_library 'libffi.so' || echo '')"
        ["libicui18n.so.48"]="$(find_library 'libicui18n.so' || echo '')"
        ["libicuuc.so.48"]="$(find_library 'libicuuc.so' || echo '')"
        ["libicudata.so.48"]="$(find_library 'libicudata.so' || echo '')"
        ["libdispatch.so"]="$(find_library 'libdispatch.so' || echo '')"
    )

    for LIB in "${!LIBS[@]}"; do
        local TARGET="${LIBS[$LIB]}"
        if [ -z "$TARGET" ]; then
            print_warning "No replacement found for $LIB; skipping."
            continue
        fi
        if command -v patchelf >/dev/null 2>&1; then
            if ! patchelf --replace-needed "$LIB" "$TARGET" "$SERVER_BINARY" >/tmp/patchelf_out 2>&1; then
                print_warning "patchelf could not replace $LIB => $TARGET (see /tmp/patchelf_out)"
            else
                print_status "Patchelf: $LIB -> $TARGET"
            fi
        else
            print_warning "patchelf not installed; binary patches will be skipped."
            break
        fi
    done
}

# ------------------ MAIN ------------------
print_header "THE BLOCKHEADS INSTALLER - CORRECTED (ENGLISH)"

print_step "[0] Checking network..."
if ! network_check; then
    print_error "Network failure. Abort."
    exit 1
fi

print_step "[1] Preparing base packages..."
prepare_basic_packages

print_step "[2] Attempting to install Objective-C/GNUstep runtimes..."
if ! install_runtime_pkgs; then
    print_warning "Runtime packages could not be installed automatically. You may try: sudo apt install libobjc4 libgnustep-base1.28 gnustep-base-runtime"
fi

print_step "[3] Downloading helper scripts from GitHub..."
for script in "${SCRIPTS[@]}"; do
    if download_script "$script"; then
        print_success "Downloaded: $script"
    else
        print_warning "Failed to download $script from GitHub. Continuing (you can download manually)."
    fi
done

print_step "[4] Downloading server archive..."
DOWNLOAD_SUCCESS=0
for URL in "${SERVER_URLS[@]}"; do
    if wget $WGET_OPTIONS "$URL" -O "$TEMP_FILE"; then
        DOWNLOAD_SUCCESS=1
        print_success "Downloaded successfully from $URL"
        break
    fi
done
if [ $DOWNLOAD_SUCCESS -eq 0 ]; then
    print_error "Could not download server archive. Aborting."
    exit 1
fi

print_step "[5] Extracting files..."
EXTRACT_DIR="/tmp/blockheads_extract_$$"
rm -rf "$EXTRACT_DIR"
mkdir -p "$EXTRACT_DIR"
if ! tar -xf "$TEMP_FILE" -C "$EXTRACT_DIR"; then
    print_error "Error extracting $TEMP_FILE"
    rm -rf "$EXTRACT_DIR"
    exit 1
fi
cp -r "$EXTRACT_DIR"/* ./
rm -rf "$EXTRACT_DIR"
rm -f "$TEMP_FILE"

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

print_step "[6] Applying patchelf where possible..."
apply_patchelf_adjustments

print_step "[7] Checking for missing dependencies (ldd)..."
MISSING=$(ldd "$SERVER_BINARY" 2>/dev/null | grep "not found" || true)
if [ -n "$MISSING" ]; then
    print_warning "Missing dependencies detected:"
    echo "$MISSING"
    print_status "Attempting to install missing dependencies automatically..."
    for so in $(echo "$MISSING" | awk '{print $1}'); do
        print_status "Searching for package providing $so..."
        if command -v apt-file >/dev/null 2>&1; then
            apt-file search "$so" | head -n 10 || true
        fi
    done
    print_status "Retrying runtime installation (if not present)..."
    install_runtime_pkgs || print_warning "Runtime re-install attempt failed."
else
    print_success "No missing libs reported by ldd."
fi

print_step "[8] Adjusting ownership/permissions"
chown "$ORIGINAL_USER:$ORIGINAL_USER" server_manager.sh server_bot.sh anticheat_secure.sh blockheads_common.sh "$SERVER_BINARY" ./*.json 2>/dev/null || true
chmod 755 server_manager.sh server_bot.sh anticheat_secure.sh blockheads_common.sh "$SERVER_BINARY" ./*.json 2>/dev/null || true

print_step "[9] Creating economy_data.json"
sudo -u "$ORIGINAL_USER" bash -c 'echo "{\"players\": {}, \"transactions\": []}" > economy_data.json' || true
chown "$ORIGINAL_USER:$ORIGINAL_USER" economy_data.json 2>/dev/null || true

print_success "Installation finished (partially automated)."

print_header "BASIC INSTRUCTIONS"
./$SERVER_BINARY -h >/dev/null 2>&1 || print_warning "The binary may require additional runtime dependencies to run (see above)."

print_status "1. Create a world: ./$SERVER_BINARY -n"
print_status "2. Start server: ./server_manager.sh start WORLD_ID PORT"
print_status "3. Stop server: ./server_manager.sh stop"
print_status "4. Check status: ./server_manager.sh status"
print_status "5. Default port: 12153"
print_status "6. HELP: ./server_manager.sh help"
print_warning "After creating the world, press CTRL+C to exit (as the binary advises)."
print_header "END"

if ldconfig -p | grep libobjc >/dev/null 2>&1 || find_library libobjc >/dev/null 2>&1; then
    print_success "libobjc detected on the system."
else
    print_warning "libobjc not detected. If the server fails with 'libobjc.so.4: cannot open shared object file', try manually:"
    echo "  sudo apt update && sudo apt install -y libobjc4 libgnustep-base1.28 gnustep-base-runtime libdispatch-dev"
    echo "If those packages don't exist on your distro, paste the output of: lsb_release -a && uname -m && ldd ./$SERVER_BINARY"
fi

exit 0
