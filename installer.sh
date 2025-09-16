#!/bin/bash
set -e

# Silent minimal installer for The Blockheads server
# Output will only show STEP and DONE messages (and ERROR if something fails)

SERVER_URL="https://web.archive.org/web/20240309015235if_/https://majicdave.com/share/blockheads_server171.tar.gz"
BINARY_NAME="blockheads_server171"

step() { echo "[STEP] $1"; }
done_step() { echo "[DONE] $1"; }
err() { echo "[ERROR] $1" >&2; exit 1; }

# must be root for package install
if [ "$EUID" -ne 0 ]; then
  err "This script must be run as root."
fi

step "Update package lists and install required packages (silent)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null 2>&1 || err "apt-get update failed"
apt-get install -y curl tar patchelf screen lsof >/dev/null 2>&1 || err "Package installation failed"
done_step "Packages installed"

step "Download and extract server binary (silent)"
curl -sL "$SERVER_URL" | tar -xzf - >/dev/null 2>&1 || err "Download or extraction failed"
done_step "Server binary downloaded and extracted"

step "Make binary executable"
if [ -f "$BINARY_NAME" ]; then
  chmod +x "$BINARY_NAME" >/dev/null 2>&1 || err "chmod failed"
  done_step "Binary is executable"
else
  err "Binary '$BINARY_NAME' not found after extraction"
fi

step "Apply compatibility patches with patchelf (best-effort, silent)"
# best-effort replacements; failures are ignored for each replace
patches=(
  "libgnustep-base.so.1.24 libgnustep-base.so.1.28"
  "libobjc.so.4.6 libobjc.so.4"
  "libgnutls.so.26 libgnutls.so.30"
  "libgcrypt.so.11 libgcrypt.so.20"
  "libffi.so.6 libffi.so.8"
  "libicui18n.so.48 libicui18n.so.70"
  "libicuuc.so.48 libicuuc.so.70"
  "libicudata.so.48 libicudata.so.70"
  "libdispatch.so libdispatch.so.0"
)
for p in "${patches[@]}"; do
  old=$(echo "$p" | awk '{print $1}')
  new=$(echo "$p" | awk '{print $2}')
  patchelf --replace-needed "$old" "$new" "$BINARY_NAME" >/dev/null 2>&1 || true
done
done_step "Compatibility patches applied (best-effort)"

step "Finalizing installation"

./blockheads_server171 -h
# make manager hint quiet (no real action, informational)
done_step "Installation completed"

# usage hint (silent script prints final actions)
echo ""
echo "[STEP] Next actions you can run (manual):"
echo "  chmod +x server_manager.sh"
echo "  ./server_manager.sh start myWorld 12153"
echo "[DONE] Installer finished"
