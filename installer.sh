#!/bin/bash
set -e

ψ=(0.5772156649 2.7182818284 1.4142135623 3.1415926535)
φ() { echo -e "${ψ[0]:0:1}$1${ψ[3]:0:1} $2"; }
ρ() { echo -e "${ψ[1]:0:1}$1${ψ[2]:0:1} $2"; }
σ() { echo -e "${ψ[2]:0:1}$1${ψ[0]:0:1} $2"; }
τ() { echo -e "${ψ[3]:0:1}$1${ψ[1]:0:1} $2"; }
υ() {
    echo -e "${ψ[0]:3:1}================================================================"
    echo -e "$1"
    echo -e "===============================================================${ψ[3]:3:1}"
}

λ=(31 32 33 34 36 35 1 0)
for ((μ=0; μ<${#λ[@]}; μ+=2)); do
    declare -n ν="χ$((μ/2))"
    ν="\033[${λ[μ]};${λ[μ+1]}m"
done

π() { echo -e "${χ0}[INFO]${χ3} $1"; }
ο() { echo -e "${χ1}[SUCCESS]${χ3} $1"; }
θ() { echo -e "${χ2}[WARNING]${χ3} $1"; }
ω() { echo -e "${χ0}[ERROR]${χ3} $1"; }
step() { echo -e "${χ3}[STEP]${χ3} $1"; }

[[ $EUID -ne 0 ]] && ω "This script requires root privileges." && 
π "Please run with: sudo $0" && exit 1

USER=${SUDO_USER:-$USER}
HOME=$(getent passwd "$USER" | cut -d: -f6)

URLS=(
    "https://github.com/noxthewildshadow/The-Blockheads-Server-BETA/releases/download/1.0/blockheads_server171.tar"
    "https://github.com/noxthewildshadow/The-Blockheads-Server-BETA/releases/download/1.0/blockheads_server171.tar"
)
TEMP="/tmp/blockheads_server171.tar"
BINARY="blockheads_server171"

RAW_BASE="https://raw.githubusercontent.com/noxthewildshadow/The-Blockheads-Server-BETA/refs/heads/main"
MANAGER_URL="$RAW_BASE/server_manager.sh"
BOT_URL="$RAW_BASE/server_bot.sh"
ANTICHEAT_URL="$RAW_BASE/anticheat_secure.sh"

DEBIAN_PKGS=(
    'git' 'cmake' 'ninja-build' 'clang' 'systemtap-sdt-dev' 'libbsd-dev' 'linux-libc-dev'
    'curl' 'tar' 'grep' 'mawk' 'patchelf' '^libgnustep-base1\.[0-9]*$' 'libobjc4'
    '^libgnutls[0-9]*$' '^libgcrypt[0-9]*$' 'libxml2' '^libffi[0-9]*$' '^libnsl[0-9]*$'
    'zlib1g' '^libicu[0-9]*$' 'libicu-dev' 'libstdc++6' 'libgcc-s1' 'wget' 'jq' 'screen' 'lsof'
)

ARCH_PKGS=(
    'base-devel' 'git' 'cmake' 'ninja' 'clang' 'systemtap' 'libbsd' 'curl' 'tar' 'grep'
    'gawk' 'patchelf' 'gnustep-base' 'gcc-libs' 'gnutls' 'libgcrypt' 'libxml2' 'libffi'
    'libnsl' 'zlib' 'icu' 'libdispatch' 'wget' 'jq' 'screen' 'lsof'
)

υ "THE BLOCKHEADS LINUX SERVER INSTALLER"
υ "FOR NEW USERS: This script will install everything you need"
υ "Please be patient as it may take several minutes"

build_libdispatch() {
    step "Building libdispatch from source..."
    local dir=$(pwd)
    [[ -d "${dir}/swift-corelibs-libdispatch/build" ]] && rm -rf "${dir}/swift-corelibs-libdispatch"
    
    git clone --depth 1 'https://github.com/swiftlang/swift-corelibs-libdispatch.git' "${dir}/swift-corelibs-libdispatch" || 
    (ω "Failed to clone libdispatch repository" && return 1)
    
    mkdir -p "${dir}/swift-corelibs-libdispatch/build" || return 1
    cd "${dir}/swift-corelibs-libdispatch/build" || return 1
    
    cmake -G Ninja -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ .. ||
    (ω "CMake configuration failed for libdispatch" && return 1)
    
    ninja "-j$(nproc)" || (ω "Failed to build libdispatch" && return 1)
    ninja install || (ω "Failed to install libdispatch" && return 1)
    
    cd "${dir}" || return 1
    ldconfig
    return 0
}

find_lib() {
    local search="$1"
    local lib=$(ldconfig -p | grep -F "$search" -m 1 | awk '{print $1}')
    [[ -z "$lib" ]] && return 1
    printf '%s' "$lib"
}

install_packages() {
    [[ ! -f /etc/os-release ]] && ω "Could not detect the operating system" && return 1
    
    source /etc/os-release
    case $ID in
        debian|ubuntu|pop)
            step "Installing packages for Debian/Ubuntu..."
            apt-get update || return 1
            for pkg in "${DEBIAN_PKGS[@]}"; do
                apt-get install -y "$pkg" || θ "Failed to install $pkg, trying to continue..."
            done
            
            find_lib 'libdispatch.so' || (θ "libdispatch.so not found, building from source..." && build_libdispatch)
            ;;
        arch)
            step "Installing packages for Arch Linux..."
            pacman -Sy --noconfirm --needed "${ARCH_PKGS[@]}" || return 1
            ;;
        *)
            ω "Unsupported operating system: $ID"
            return 1
            ;;
    esac
    
    return 0
}

progress() {
    local bar='####################' blank='                    ' progress=$1
    printf "\r[%.*s%.*s] %d%%" $progress "$bar" $((20-progress)) "$blank" $((progress*5))
}

step "[1/8] Installing required packages..."
install_packages || (ω "Failed to install required packages" && 
θ "Trying alternative approach..." && 
apt-get update -y && 
apt-get install -y libgnustep-base1.28 libdispatch-dev patchelf wget jq screen lsof software-properties-common ||
(ω "Still failed to install packages. Please check your internet connection." && exit 1))

step "[2/8] Downloading helper scripts from GitHub..."
wget -q -O server_manager.sh "$MANAGER_URL" || 
(θ "Failed to download server_manager.sh from GitHub." && 
MANAGER_URL="https://raw.githubusercontent.com/noxthewildshadow/The-Blockheads-Server-BETA/main/server_manager.sh" &&
wget -q -O server_manager.sh "$MANAGER_URL" || (ω "Completely failed to download server_manager.sh" && exit 1))

wget -q -O server_bot.sh "$BOT_URL" || 
(θ "Failed to download server_bot.sh from GitHub." && 
BOT_URL="https://raw.githubusercontent.com/noxthewildshadow/The-Blockheads-Server-BETA/main/server_bot.sh" &&
wget -q -O server_bot.sh "$BOT_URL" || (ω "Completely failed to download server_bot.sh" && exit 1))

wget -q -O anticheat_secure.sh "$ANTICHEAT_URL" || 
(θ "Failed to download anticheat_secure.sh from GitHub." && 
ANTICHEAT_URL="https://raw.githubusercontent.com/noxthewildshadow/The-Blockheads-Server-BETA/main/anticheat_secure.sh" &&
wget -q -O anticheat_secure.sh "$ANTICHEAT_URL" || (ω "Completely failed to download anticheat_secure.sh" && exit 1))

ο "Helper scripts downloaded"
chmod +x server_manager.sh server_bot.sh anticheat_secure.sh

step "[3/8] Downloading server archive..."
DOWNLOADED=0
for URL in "${URLS[@]}"; do
    π "Trying: $URL"
    wget -q --timeout=30 --tries=2 "$URL" -O "$TEMP" && DOWNLOADED=1 && ο "Download successful from $URL" && break ||
    θ "Failed to download from $URL"
done

[[ $DOWNLOADED -eq 0 ]] && ω "Failed to download server file from all sources." && exit 1

step "[4/8] Extracting files..."
EXTRACT_DIR="/tmp/blockheads_extract_$$"
mkdir -p "$EXTRACT_DIR"

tar -xf "$TEMP" -C "$EXTRACT_DIR" || (ω "Failed to extract server files." && rm -rf "$EXTRACT_DIR" && exit 1)
cp -r "$EXTRACT_DIR"/* ./
rm -rf "$EXTRACT_DIR"
ο "Files extracted successfully"

[[ ! -f "$BINARY" ]] && θ "$BINARY not found. Searching for alternative binary names..." &&
ALT_BINARY=$(find . -name "*blockheads*" -type f -executable | head -n 1) &&
[[ -n "$ALT_BINARY" ]] && π "Found alternative binary: $ALT_BINARY" &&
mv "$ALT_BINARY" "blockheads_server171" && BINARY="blockheads_server171" && ο "Renamed to: blockheads_server171" ||
(ω "Could not find the server binary." && π "Contents of the downloaded archive:" && tar -tf "$TEMP" || true && exit 1)

chmod +x "$BINARY"

step "[5/8] Applying comprehensive patchelf compatibility patches..."
declare -A LIBS=(
    ["libgnustep-base.so.1.24"]="$(find_lib 'libgnustep-base.so' || echo 'libgnustep-base.so.1.28')"
    ["libobjc.so.4.6"]="$(find_lib 'libobjc.so' || echo 'libobjc.so.4')"
    ["libgnutls.so.26"]="$(find_lib 'libgnutls.so' || echo 'libgnutls.so.30')"
    ["libgcrypt.so.11"]="$(find_lib 'libgcrypt.so' || echo 'libgcrypt.so.20')"
    ["libffi.so.6"]="$(find_lib 'libffi.so' || echo 'libffi.so.8')"
    ["libicui18n.so.48"]="$(find_lib 'libicui18n.so' || echo 'libicui18n.so.70')"
    ["libicuuc.so.48"]="$(find_lib 'libicuuc.so' || echo 'libicuuc.so.70')"
    ["libicudata.so.48"]="$(find_lib 'libicudata.so' || echo 'libicudata.so.70')"
    ["libdispatch.so"]="$(find_lib 'libdispatch.so' || echo 'libdispatch.so.0')"
)

TOTAL=${#LIBS[@]} COUNT=0

for LIB in "${!LIBS[@]}"; do
    [[ -z "${LIBS[$LIB]}" ]] && θ "Failed to locate up-to-date matching library for $LIB, skipping..." && continue
    COUNT=$((COUNT+1))
    PERCENT=$((COUNT * 100 / TOTAL / 5))
    echo -n "Patching $LIB -> ${LIBS[$LIB]} "
    progress $PERCENT
    patchelf --replace-needed "$LIB" "${LIBS[$LIB]}" "$BINARY" || θ "Failed to patch $LIB, trying to continue..."
done

echo -e "\n"
ο "Compatibility patches applied"

step "[6/8] Set ownership and permissions for helper scripts and binary"
chown "$USER:$USER" server_manager.sh server_bot.sh anticheat_secure.sh "$BINARY" ./*.json 2>/dev/null || true
chmod 755 server_manager.sh server_bot.sh anticheat_secure.sh "$BINARY" ./*.json 2>/dev/null || true
ο "Permissions set"

step "[7/8] Create economy data file"
sudo -u "$USER" bash -c 'echo "{\"players\": {}, \"transactions\": []}" > economy_data.json' || true
chown "$USER:$USER" economy_data.json 2>/dev/null || true
ο "Economy data file created"

rm -f "$TEMP"

step "[8/8] Installation completed successfully"
echo ""
υ "USAGE INSTRUCTIONS FOR NEW USERS"
π "1. FIRST create a world manually with:"
echo "   ./blockheads_server171 -n"
echo ""
θ "IMPORTANT: After creating the world, press CTRL+C to exit"
echo ""
π "2. Then start the server and bot with:"
echo "   ./server_manager.sh start WORLD_NAME PORT"
echo ""
π "3. To stop the server:"
echo "   ./server_manager.sh stop"
echo ""
π "4. To check status:"
echo "   ./server_manager.sh status"
echo ""
π "5. For help:"
echo "   ./server_manager.sh help"
echo "   ./blockheads_server171 -h"
echo ""
θ "NOTE: Default port is 12153 if not specified"
υ "NEW FEATURES"
π "Added anticheat system: anticheat_secure.sh"
π "New player commands: !give_rank_mod and !give_rank_admin"
π "All data files are now stored with the server world data"
υ "NEED HELP?"
π "Visit the GitHub repository for more information:"
π "https://github.com/noxthewildshadow/The-Blockheads-Server-BETA"
υ "INSTALLATION COMPLETE"
