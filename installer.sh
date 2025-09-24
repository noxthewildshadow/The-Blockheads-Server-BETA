#!/bin/bash
set -e

# =============================================================================
# THE BLOCKHEADS LINUX SERVER INSTALLER
# =============================================================================

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

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
    echo -e "${MAGENTA}================================================================================${NC}"
    echo -e "${MAGENTA}$1${NC}"
    echo -e "${MAGENTA}================================================================================${NC}"
}

print_step() {
    echo -e "${CYAN}[STEP]${NC} $1";
}

# Check if running as root
[ "$EUID" -ne 0 ] && print_error "This script requires root privileges." && exit 1

ORIGINAL_USER=${SUDO_USER:-$USER}

# URL for server download
SERVER_URL="https://web.archive.org/web/20240309015235if_/https://majicdave.com/share/blockheads_server171.tar.gz"
TEMP_FILE="/tmp/blockheads_server171.tar.gz"
SERVER_BINARY="blockheads_server171"

# URL for server manager
SERVER_MANAGER_URL="https://raw.githubusercontent.com/noxthewildshadow/The-Blockheads-Server-BETA/main/server_manager.sh"

# Basic packages
PACKAGES=('wget' 'tar' 'screen' 'lsof')

print_header "THE BLOCKHEADS LINUX SERVER INSTALLER"
echo -e "${CYAN}Welcome to The Blockheads Server Installation!${NC}"
echo

# Function to install packages
install_packages() {
    print_step "Installing required packages..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update >/dev/null 2>&1 || print_warning "Failed to update package list"
        for package in "${PACKAGES[@]}"; do
            apt-get install -y "$package" >/dev/null 2>&1 || print_warning "Failed to install $package"
        done
    elif command -v yum >/dev/null 2>&1; then
        yum update -y >/dev/null 2>&1 || print_warning "Failed to update package list"
        for package in "${PACKAGES[@]}"; do
            yum install -y "$package" >/dev/null 2>&1 || print_warning "Failed to install $package"
        done
    else
        print_warning "Could not detect package manager, trying to continue anyway"
    fi
}

# Function to download server manager
download_server_manager() {
    print_step "Downloading server manager..."
    if wget --timeout=30 --tries=3 -O "server_manager.sh" "$SERVER_MANAGER_URL" 2>/dev/null; then
        chmod +x "server_manager.sh"
        print_success "Server manager downloaded successfully"
        return 0
    else
        print_error "Failed to download server manager"
        return 1
    fi
}

# Function to find library
find_library() {
    SEARCH=$1
    LIBRARY=$(ldconfig -p | grep -F "$SEARCH" -m 1 | awk '{print $NF}' | head -1)
    [ -z "$LIBRARY" ] && return 1
    printf '%s' "$LIBRARY"
}

print_step "[1/5] Installing basic packages..."
install_packages

print_step "[2/5] Downloading server archive..."
if wget --timeout=30 --tries=3 --show-progress "$SERVER_URL" -O "$TEMP_FILE" 2>/dev/null; then
    print_success "Server downloaded successfully"
else
    print_error "Failed to download server file"
    exit 1
fi

print_step "[3/5] Extracting server files..."
if tar -xzf "$TEMP_FILE" -C . >/dev/null 2>&1; then
    print_success "Files extracted successfully"
else
    print_error "Failed to extract server files"
    exit 1
fi

# Find and rename the server binary
if [ ! -f "$SERVER_BINARY" ]; then
    SERVER_BINARY=$(find . -name "*blockheads*" -type f -executable | head -n 1)
    if [ -n "$SERVER_BINARY" ]; then
        mv "$SERVER_BINARY" "blockheads_server171"
        SERVER_BINARY="blockheads_server171"
        chmod +x "$SERVER_BINARY"
    else
        print_error "Server binary not found after extraction"
        exit 1
    fi
fi

print_step "[4/5] Downloading server manager..."
if ! download_server_manager; then
    # Create a basic server manager if download fails
    print_warning "Creating basic server manager..."
    cat > server_manager.sh << 'EOF'
#!/bin/bash
# Basic Server Manager for Blockheads
echo "Use: ./blockheads_server171 -n (to create world)"
echo "Then: ./blockheads_server171 -o WORLD_NAME -p PORT"
EOF
    chmod +x server_manager.sh
fi

print_step "[5/5] Setting permissions..."
chown "$ORIGINAL_USER:$ORIGINAL_USER" "$SERVER_BINARY" "server_manager.sh" 2>/dev/null || true
chmod 755 "$SERVER_BINARY" "server_manager.sh" 2>/dev/null || true

rm -f "$TEMP_FILE"

print_header "INSTALLATION COMPLETE"
echo -e "${GREEN}Server installed successfully!${NC}"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo -e "1. ${CYAN}./blockheads_server171 -n${NC} (create a world)"
echo -e "2. ${CYAN}./server_manager.sh start WORLD_NAME${NC} (start server)"
echo -e "3. ${CYAN}./server_manager.sh stop${NC} (stop server)"
echo ""
echo -e "${GREEN}Your Blockheads server is ready!${NC}"
