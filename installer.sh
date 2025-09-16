#!/bin/bash
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

[ "$EUID" -ne 0 ] && print_error "This script requires root privileges." && exit 1

print_status "Installing required packages..."
apt-get update >/dev/null 2>&1
apt-get install -y curl patchelf screen >/dev/null 2>&1

print_status "Downloading server binary..."
curl -sL "https://web.archive.org/web/20240309015235if_/https://majicdave.com/share/blockheads_server171.tar.gz" | tar xvz

print_status "Applying compatibility patches..."
patchelf --replace-needed libgnustep-base.so.1.24 libgnustep-base.so.1.28 blockheads_server171
patchelf --replace-needed libobjc.so.4.6 libobjc.so.4 blockheads_server171
patchelf --replace-needed libgnutls.so.26 libgnutls.so.30 blockheads_server171
patchelf --replace-needed libgcrypt.so.11 libgcrypt.so.20 blockheads_server171
patchelf --replace-needed libffi.so.6 libffi.so.8 blockheads_server171
patchelf --replace-needed libicui18n.so.48 libicui18n.so.70 blockheads_server171
patchelf --replace-needed libicuuc.so.48 libicuuc.so.70 blockheads_server171
patchelf --replace-needed libicudata.so.48 libicudata.so.70 blockheads_server171
patchelf --replace-needed libdispatch.so libdispatch.so.0 blockheads_server171

print_status "Downloading server manager and common functions..."
curl -s -O "https://raw.githubusercontent.com/noxthewildshadow/The-Blockheads-Server-BETA/main/server_manager.sh"
curl -s -O "https://raw.githubusercontent.com/noxthewildshadow/The-Blockheads-Server-BETA/main/blockheads_common.sh"

chmod +x server_manager.sh blockheads_server171

print_success "Installation completed successfully"
echo ""
print_status "To create a world: ./blockheads_server171 -n"
print_status "To start server: ./server_manager.sh start WORLD_ID PORT"
