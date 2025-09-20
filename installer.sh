#!/bin/bash
set -euo pipefail

# =============================================================================
# THE BLOCKHEADS LINUX SERVER INSTALLER - AUTOMATIC PATCH + LD_PRELOAD HOOKS
# =============================================================================

# Colors
RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' BLUE='\033[0;34m'
CYAN='\033[0;36m' MAGENTA='\033[0;35m' PURPLE='\033[0;35m' BOLD='\033[1m' NC='\033[0m'

print_status(){ echo -e "${BLUE}[INFO]${NC} $1"; }
print_success(){ echo -e "${GREEN}[OK]${NC} $1"; }
print_warning(){ echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error(){ echo -e "${RED}[ERR]${NC} $1"; }
print_header(){ echo -e "${PURPLE}========================================${NC}\n$1\n${PURPLE}========================================${NC}"; }
print_step(){ echo -e "${CYAN}[STEP]${NC} $1"; }

# --- Basic checks
[ "$EUID" -ne 0 ] && print_error "Run as root: sudo ./installer.sh" && exit 1
ORIGINAL_USER=${SUDO_USER:-$USER}
USER_HOME=$(getent passwd "$ORIGINAL_USER" | cut -d: -f6 || echo "/home/$ORIGINAL_USER")

# --- Config (edit if needed)
SERVER_URLS=(
  "https://github.com/noxthewildshadow/The-Blockheads-Server-BETA/releases/download/1.0/blockheads_server171.tar"
  # add mirrors if you have
)
TEMP_FILE="/tmp/blockheads_server171.tar"
EXTRACT_DIR="/tmp/blockheads_extract_$$"
SERVER_BINARY="blockheads_server171"
SCRIPTS=( "server_manager.sh" "server_bot.sh" "anticheat_secure.sh" "blockheads_common.sh" )
PATCH_C="/tmp/patch_objc_hooks.c"
PATCH_SO="./libbhpatch.so"
LAUNCHER="./run_blockheads.sh"
BACKUP_SUFFIX=".installer.bak"

print_header "THE BLOCKHEADS LINUX SERVER INSTALLER (AUTO PATCH)"

# --- Helper: detect OS
if [ -f /etc/os-release ]; then
  . /etc/os-release
  OS_ID="$ID"
else
  OS_ID="unknown"
fi

# --- Install packages (best effort)
print_step "Installing build/runtime dependencies..."
case "$OS_ID" in
  debian|ubuntu|pop)
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y build-essential gcc clang make git cmake ninja-build patchelf wget jq screen lsof tar curl libgnustep-base-dev libobjc-*-dev libobjc4 2>/dev/null || \
    apt-get install -y build-essential gcc clang make git cmake ninja-build patchelf wget jq screen lsof tar curl libgnustep-base-dev libobjc4 2>/dev/null || true
    ;;
  arch)
    pacman -Sy --noconfirm base-devel git cmake ninja patchelf wget jq screen lsof tar curl gnustep-base 2>/dev/null || true
    ;;
  *)
    print_warning "Unsupported or unknown OS ($OS_ID). Attempting best-effort installs (may fail)."
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y build-essential gcc make patchelf wget jq screen lsof tar curl 2>/dev/null || true
    ;;
esac

# --- Download server archive
print_step "Downloading server archive..."
DOWNLOAD_OK=0
for url in "${SERVER_URLS[@]}"; do
  if wget --timeout=30 --tries=2 --dns-timeout=10 --connect-timeout=10 --read-timeout=30 -q -O "$TEMP_FILE" "$url"; then
    print_success "Downloaded server archive from $url"
    DOWNLOAD_OK=1
    break
  else
    print_warning "Failed to download from $url"
  fi
done
[ $DOWNLOAD_OK -eq 0 ] && print_error "Could not download server archive" && exit 1

# --- Extract
print_step "Extracting archive..."
rm -rf "$EXTRACT_DIR"
mkdir -p "$EXTRACT_DIR"
tar -xf "$TEMP_FILE" -C "$EXTRACT_DIR" || { print_error "Extraction failed"; exit 1; }
# Copy contents to current directory
print_step "Copying files into $(pwd)..."
cp -r "$EXTRACT_DIR"/* ./ 2>/dev/null || true
rm -rf "$EXTRACT_DIR"
rm -f "$TEMP_FILE"

# --- Ensure server binary exists (fallback find)
if [ ! -f "$SERVER_BINARY" ]; then
  ALT=$(find . -type f -executable -name "*blockheads*" | head -n1 || true)
  if [ -n "$ALT" ]; then
    mv "$ALT" "$SERVER_BINARY"
    print_success "Found and renamed $ALT -> $SERVER_BINARY"
  else
    print_error "Server binary ($SERVER_BINARY) not found after extraction"
    exit 1
  fi
fi
chmod +x "$SERVER_BINARY" || true

# --- Create runtime patch C (LD_PRELOAD hooks)
print_step "Generating Objective-C runtime hook source ($PATCH_C)..."

cat > "$PATCH_C" <<'EOF'
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <dlfcn.h>
#include <objc/objc.h>
#include <objc/message.h>
#include <objc/runtime.h>

// Original IMP holders
static IMP orig_bh_match_imp = NULL;
static IMP orig_fc_init1_imp = NULL;
static IMP orig_fc_init2_imp = NULL;
static IMP orig_fc_init3_imp = NULL;

static unsigned long data_length_or_zero(id data) {
    if (!data) return 0;
    SEL sel_len = sel_registerName("length");
    unsigned long len = (unsigned long) ((unsigned long (*)(id, SEL))objc_msgSend)(data, sel_len);
    return len;
}

/* Safe BHServer - (void)match:didReceiveData:fromPlayer: */
static void safe_BHServer_match_didReceiveData_fromPlayer(id self, SEL _cmd, id match, id data, id player) {
    unsigned long len = data_length_or_zero(data);
    if (!data || len == 0) {
        fprintf(stderr, "[BadPacketCrashPatch] blocked empty/bad packet (player=%p)\n", (void*)player);
        return;
    }
    if (orig_bh_match_imp) {
        ((void (*)(id, SEL, id, id, id))orig_bh_match_imp)(self, _cmd, match, data, player);
    }
}

/* Safe FreightCar inits: setNeedsRemoved:YES; dealloc; return NULL */
static id safe_FreightCar_init1(id self, SEL _cmd, id a1, id a2, id a3, id a4, id a5, id a6) {
    SEL sel_setNeedsRemoved = sel_registerName("setNeedsRemoved:");
    SEL sel_dealloc = sel_registerName("dealloc");
    ((void (*)(id, SEL, BOOL))objc_msgSend)(self, sel_setNeedsRemoved, (BOOL)1);
    ((void (*)(id, SEL))objc_msgSend)(self, sel_dealloc);
    return NULL;
}
static id safe_FreightCar_init2(id self, SEL _cmd, id a1, id a2, id a3, id a4) {
    SEL sel_setNeedsRemoved = sel_registerName("setNeedsRemoved:");
    SEL sel_dealloc = sel_registerName("dealloc");
    ((void (*)(id, SEL, BOOL))objc_msgSend)(self, sel_setNeedsRemoved, (BOOL)1);
    ((void (*)(id, SEL))objc_msgSend)(self, sel_dealloc);
    return NULL;
}
static id safe_FreightCar_init3(id self, SEL _cmd, id a1, id a2, id a3, id a4, id a5) {
    SEL sel_setNeedsRemoved = sel_registerName("setNeedsRemoved:");
    SEL sel_dealloc = sel_registerName("dealloc");
    ((void (*)(id, SEL, BOOL))objc_msgSend)(self, sel_setNeedsRemoved, (BOOL)1);
    ((void (*)(id, SEL))objc_msgSend)(self, sel_dealloc);
    return NULL;
}

__attribute__((constructor))
static void install_objc_patches(void) {
    Class bhClass = objc_getClass("BHServer");
    Class fcClass = objc_getClass("FreightCar");

    if (bhClass) {
        SEL sel_bh = sel_registerName("match:didReceiveData:fromPlayer:");
        Method m = class_getInstanceMethod(bhClass, sel_bh);
        if (m) {
            orig_bh_match_imp = method_getImplementation(m);
            method_setImplementation(m, (IMP)safe_BHServer_match_didReceiveData_fromPlayer);
            fprintf(stderr, "[patch] BHServer match:didReceiveData:fromPlayer: hooked\n");
        } else {
            fprintf(stderr, "[patch] BHServer selector not found: match:didReceiveData:fromPlayer:\n");
        }
    } else {
        fprintf(stderr, "[patch] BHServer class not found\n");
    }

    if (fcClass) {
        SEL sel_init1 = sel_registerName("initWithWorld:dynamicWorld:atPosition:cache:saveDict:placedByClient:");
        SEL sel_init2 = sel_registerName("initWithWorld:dynamicWorld:cache:netData:");
        SEL sel_init3 = sel_registerName("initWithWorld:dynamicWorld:saveDict:chestSaveDict:cache:");

        Method m1 = class_getInstanceMethod(fcClass, sel_init1);
        Method m2 = class_getInstanceMethod(fcClass, sel_init2);
        Method m3 = class_getInstanceMethod(fcClass, sel_init3);

        if (m1) {
            orig_fc_init1_imp = method_getImplementation(m1);
            method_setImplementation(m1, (IMP)safe_FreightCar_init1);
            fprintf(stderr, "[patch] FreightCar initWithWorld:dynamicWorld:atPosition:... hooked\n");
        } else {
            fprintf(stderr, "[patch] FreightCar selector not found: init1\n");
        }
        if (m2) {
            orig_fc_init2_imp = method_getImplementation(m2);
            method_setImplementation(m2, (IMP)safe_FreightCar_init2);
            fprintf(stderr, "[patch] FreightCar initWithWorld:dynamicWorld:cache:netData: hooked\n");
        } else {
            fprintf(stderr, "[patch] FreightCar selector not found: init2\n");
        }
        if (m3) {
            orig_fc_init3_imp = method_getImplementation(m3);
            method_setImplementation(m3, (IMP)safe_FreightCar_init3);
            fprintf(stderr, "[patch] FreightCar initWithWorld:dynamicWorld:saveDict:chestSaveDict:cache: hooked\n");
        } else {
            fprintf(stderr, "[patch] FreightCar selector not found: init3\n");
        }
    } else {
        fprintf(stderr, "[patch] FreightCar class not found\n");
    }
}
EOF

print_success "Source created: $PATCH_C"

# --- Compile libbhpatch.so
print_step "Compiling $PATCH_SO..."
COMPILE_LOG="/tmp/patch_compile_$$.log"
if command -v gcc >/dev/null 2>&1; then
  if gcc -shared -fPIC -o "$PATCH_SO" "$PATCH_C" -ldl -lobjc -O2 2>"$COMPILE_LOG"; then
    print_success "Compiled $PATCH_SO successfully"
  else
    print_warning "Compilation failed. See $COMPILE_LOG for details"
    tail -n 80 "$COMPILE_LOG" || true
    print_warning "Continuing without runtime patch (server will still be installed)."
    rm -f "$PATCH_SO" 2>/dev/null || true
  fi
else
  print_warning "gcc not installed. Skipping compilation of runtime patch."
fi

# --- Create launcher wrapper (run_blockheads.sh)
print_step "Creating launcher wrapper: $LAUNCHER"
cat > "$LAUNCHER" <<'SH_EOF'
#!/bin/bash
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH="$HERE/libbhpatch.so"
EXEC="$HERE/blockheads_server171"
if [ -f "$PATCH" ]; then
  export LD_PRELOAD="$PATCH${LD_PRELOAD:+:$LD_PRELOAD}"
fi
# Execute the original with any args
exec "$EXEC" "$@"
SH_EOF
chmod +x "$LAUNCHER"

# --- Modify server_manager.sh to use launcher (backup first)
if [ -f "server_manager.sh" ]; then
  print_step "Backing up server_manager.sh -> server_manager.sh$BACKUP_SUFFIX"
  cp -a server_manager.sh "server_manager.sh$BACKUP_SUFFIX" || true

  # Replace the SERVER_BINARY assignment if present
  if grep -q "^SERVER_BINARY=" server_manager.sh; then
    sed -i "s|^SERVER_BINARY=.*|SERVER_BINARY=\"./run_blockheads.sh\"|g" server_manager.sh && print_success "server_manager.sh updated to use ./run_blockheads.sh"
  else
    # Fallback: append at top
    sed -i "1i SERVER_BINARY=\"./run_blockheads.sh\"" server_manager.sh && print_success "Inserted SERVER_BINARY assignment into server_manager.sh"
  fi
else
  print_warning "server_manager.sh not found in current directory; skipping modification."
fi

# --- Patchelf compatibility adjustments (best-effort)
print_step "Applying patchelf compatibility adjustments (best-effort)..."
if command -v patchelf >/dev/null 2>&1; then
  # Try to detect common libs and replace needed if present
  declare -A LIBS_TO_TRY=(
    ["libgnustep-base.so.1.24"]="libgnustep-base.so.1.28"
    ["libobjc.so.4.6"]="libobjc.so.4"
    ["libgnutls.so.26"]="libgnutls.so.30"
    ["libgcrypt.so.11"]="libgcrypt.so.20"
    ["libffi.so.6"]="libffi.so.8"
    ["libicui18n.so.48"]="libicui18n.so.70"
    ["libicuuc.so.48"]="libicuuc.so.70"
    ["libicudata.so.48"]="libicudata.so.70"
  )
  for L in "${!LIBS_TO_TRY[@]}"; do
    TARGET=${LIBS_TO_TRY[$L]}
    if ldd "./$SERVER_BINARY" 2>/dev/null | grep -q "$L"; then
      patchelf --replace-needed "$L" "$TARGET" "./$SERVER_BINARY" 2>/dev/null || print_warning "patchelf replace $L -> $TARGET failed"
    fi
  done
  print_success "patchelf adjustments attempted"
else
  print_warning "patchelf not found; skipping binary compatibility adjustments"
fi

# --- Set ownership/permissions
print_step "Setting permissions and ownerships..."
chown "$ORIGINAL_USER:$ORIGINAL_USER" ./* 2>/dev/null || true
chmod +x "$SERVER_BINARY" "$LAUNCHER" 2>/dev/null || true

# --- Final notes and output
print_header "INSTALLATION COMPLETE"
print_status "To run the server with runtime patches (if compiled): ./run_blockheads.sh -h"
print_status "Server manager uses: ./run_blockheads.sh (server_manager.sh was updated if present)."
print_status "If the runtime patch failed to compile, you can still run the server directly: ./blockheads_server171"
print_warning "If you prefer NOT to preload patches, run ./blockheads_server171 directly."
print_success "Installer finished. Check compile logs: /tmp/patch_compile_$$.log (if present)."

# --- End
