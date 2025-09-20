#!/bin/bash
set -euo pipefail

# =============================================================================
# THE BLOCKHEADS LINUX AUTO-INSTALLER (with robust FreightCar & BHServer hooks)
# =============================================================================
# Usage: sudo ./installer.sh
# This script downloads the server tar, extracts, compiles a LD_PRELOAD patch
# with retries to hook Objective-C methods, creates a launcher run_blockheads.sh,
# and updates server_manager.sh to use the launcher (backup made).
# =============================================================================

# Colors
RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' BLUE='\033[0;34m'
CYAN='\033[0;36m' PURPLE='\033[0;35m' NC='\033[0m'

info(){ echo -e "${BLUE}[INFO]${NC} $1"; }
ok(){ echo -e "${GREEN}[OK]${NC} $1"; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $1"; }
err(){ echo -e "${RED}[ERR]${NC} $1"; }

if [ "$EUID" -ne 0 ]; then
  err "Run as root: sudo $0"
  exit 1
fi

ORIGINAL_USER=${SUDO_USER:-$USER}
USER_HOME=$(getent passwd "$ORIGINAL_USER" | cut -d: -f6 || echo "/home/$ORIGINAL_USER")
WORKDIR="$(pwd)"

# Config
SERVER_URLS=(
  "https://github.com/noxthewildshadow/The-Blockheads-Server-BETA/releases/download/1.0/blockheads_server171.tar"
)
TEMP_FILE="/tmp/blockheads_server171.tar"
EXTRACT_DIR="/tmp/blockheads_extract_$$"
SERVER_BINARY="blockheads_server171"
PATCH_C="/tmp/patch_objc_hooks_fixed.c"
PATCH_SO="./libbhpatch.so"
LAUNCHER="./run_blockheads.sh"
BACKUP_SUFFIX=".installer.bak"
COMPILE_LOG="/tmp/patch_compile_fixed.log"

info "Workdir: $WORKDIR"
info "Original user: $ORIGINAL_USER, HOME: $USER_HOME"

# Try to install build deps (best effort)
info "Installing build/runtime dependencies (best-effort)..."
if [ -f /etc/os-release ]; then
  . /etc/os-release
fi

case "${ID:-}" in
  ubuntu|debian|pop)
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y build-essential gcc clang make git cmake ninja-build patchelf wget jq screen lsof tar curl gnustep-devel libgnustep-base-dev libobjc-dev 2>/dev/null || \
    apt-get install -y build-essential gcc make git patchelf wget jq screen lsof tar curl libgnustep-base-dev libobjc-*-dev || true
    ;;
  arch)
    pacman -Sy --noconfirm base-devel git cmake ninja patchelf wget jq screen lsof tar curl gnustep-base || true
    ;;
  *)
    warn "Unknown OS; skipping automated package installation. You may need build-essential, libgnustep-base-dev, libobjc-dev, patchelf, wget, screen."
    ;;
esac

# Download server archive
info "Downloading server archive..."
download_ok=0
for url in "${SERVER_URLS[@]}"; do
  info "Trying $url"
  if wget --timeout=30 --tries=2 --dns-timeout=10 --connect-timeout=10 --read-timeout=30 -q -O "$TEMP_FILE" "$url"; then
    ok "Downloaded server archive from $url"
    download_ok=1
    break
  else
    warn "Failed to download from $url"
  fi
done

if [ $download_ok -eq 0 ]; then
  err "Could not download server archive. Exiting."
  exit 1
fi

# Extract
info "Extracting archive..."
rm -rf "$EXTRACT_DIR"
mkdir -p "$EXTRACT_DIR"
if ! tar -xf "$TEMP_FILE" -C "$EXTRACT_DIR"; then
  err "Extraction failed."
  exit 1
fi

info "Copying extracted files to current directory..."
cp -r "$EXTRACT_DIR"/* ./ 2>/dev/null || true
rm -rf "$EXTRACT_DIR"
rm -f "$TEMP_FILE"

# Find server binary if not present
if [ ! -f "$SERVER_BINARY" ]; then
  ALT=$(find . -type f -executable -name "*blockheads*" | head -n 1 || true)
  if [ -n "$ALT" ]; then
    mv "$ALT" "$SERVER_BINARY" || true
    ok "Found server binary $ALT -> renamed to $SERVER_BINARY"
  else
    err "Server binary ($SERVER_BINARY) not found after extraction."
    exit 1
  fi
fi
chmod +x "$SERVER_BINARY" || true

# Write the robust patch C (retries +alloc + init hooks)
info "Writing Objective-C hook source to $PATCH_C..."
cat > "$PATCH_C" <<'EOF'
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <dlfcn.h>
#include <unistd.h>
#include <pthread.h>
#include <objc/objc.h>
#include <objc/message.h>
#include <objc/runtime.h>

static IMP orig_bh_match_imp = NULL;
static IMP orig_fc_init1_imp = NULL;
static IMP orig_fc_init2_imp = NULL;
static IMP orig_fc_init3_imp = NULL;
static IMP orig_alloc_imp = NULL;

static void safe_BHServer_match_didReceiveData_fromPlayer(id self, SEL _cmd, id match, id data, id player) {
    unsigned long len = 0;
    if (data) {
        SEL sel_len = sel_registerName("length");
        len = (unsigned long)((unsigned long (*)(id, SEL))objc_msgSend)(data, sel_len);
    }
    if (!data || len == 0) {
        fprintf(stderr, "[patch][BadPacketCrashPatch] blocked empty/bad packet (player=%p)\n", (void*)player);
        return;
    }
    if (orig_bh_match_imp) {
        ((void (*)(id, SEL, id, id, id))orig_bh_match_imp)(self, _cmd, match, data, player);
    }
}

static id safe_FreightCar_init1(id self, SEL _cmd, long a1, long a2, long a3, long a4, long a5, long a6) {
    SEL sel_setNeedsRemoved = sel_registerName("setNeedsRemoved:");
    SEL sel_dealloc = sel_registerName("dealloc");
    ((void (*)(id, SEL, BOOL))objc_msgSend)(self, sel_setNeedsRemoved, (BOOL)1);
    ((void (*)(id, SEL))objc_msgSend)(self, sel_dealloc);
    return NULL;
}
static id safe_FreightCar_init2(id self, SEL _cmd, long a1, long a2, long a3, long a4) {
    SEL sel_setNeedsRemoved = sel_registerName("setNeedsRemoved:");
    SEL sel_dealloc = sel_registerName("dealloc");
    ((void (*)(id, SEL, BOOL))objc_msgSend)(self, sel_setNeedsRemoved, (BOOL)1);
    ((void (*)(id, SEL))objc_msgSend)(self, sel_dealloc);
    return NULL;
}
static id safe_FreightCar_init3(id self, SEL _cmd, long a1, long a2, long a3, long a4, long a5) {
    SEL sel_setNeedsRemoved = sel_registerName("setNeedsRemoved:");
    SEL sel_dealloc = sel_registerName("dealloc");
    ((void (*)(id, SEL, BOOL))objc_msgSend)(self, sel_setNeedsRemoved, (BOOL)1);
    ((void (*)(id, SEL))objc_msgSend)(self, sel_dealloc);
    return NULL;
}

static id safe_class_alloc(id cls_self, SEL _cmd) {
    Class freight = objc_getClass("FreightCar");
    if (cls_self == (id)freight) {
        fprintf(stderr, "[patch][alloc] Blocking +[FreightCar alloc] -> returning NULL\n");
        return NULL;
    }
    if (orig_alloc_imp) {
        return ((id (*)(id, SEL))orig_alloc_imp)(cls_self, _cmd);
    }
    return NULL;
}

static void try_install_hooks_once(void) {
    Class bhClass = objc_getClass("BHServer");
    Class fcClass = objc_getClass("FreightCar");
    if (bhClass) {
        SEL sel_bh = sel_registerName("match:didReceiveData:fromPlayer:");
        Method m = class_getInstanceMethod(bhClass, sel_bh);
        if (m && !orig_bh_match_imp) {
            orig_bh_match_imp = method_getImplementation(m);
            method_setImplementation(m, (IMP)safe_BHServer_match_didReceiveData_fromPlayer);
            fprintf(stderr, "[patch] Hooked BHServer -match:didReceiveData:fromPlayer:\n");
        }
    }
    if (fcClass) {
        SEL sel_init1 = sel_registerName("initWithWorld:dynamicWorld:atPosition:cache:saveDict:placedByClient:");
        SEL sel_init2 = sel_registerName("initWithWorld:dynamicWorld:cache:netData:");
        SEL sel_init3 = sel_registerName("initWithWorld:dynamicWorld:saveDict:chestSaveDict:cache:");

        Method m1 = class_getInstanceMethod(fcClass, sel_init1);
        Method m2 = class_getInstanceMethod(fcClass, sel_init2);
        Method m3 = class_getInstanceMethod(fcClass, sel_init3);

        if (m1 && !orig_fc_init1_imp) {
            orig_fc_init1_imp = method_getImplementation(m1);
            method_setImplementation(m1, (IMP)safe_FreightCar_init1);
            fprintf(stderr, "[patch] Hooked FreightCar initWithWorld:dynamicWorld:atPosition:...\n");
        }
        if (m2 && !orig_fc_init2_imp) {
            orig_fc_init2_imp = method_getImplementation(m2);
            method_setImplementation(m2, (IMP)safe_FreightCar_init2);
            fprintf(stderr, "[patch] Hooked FreightCar initWithWorld:dynamicWorld:cache:netData:\n");
        }
        if (m3 && !orig_fc_init3_imp) {
            orig_fc_init3_imp = method_getImplementation(m3);
            method_setImplementation(m3, (IMP)safe_FreightCar_init3);
            fprintf(stderr, "[patch] Hooked FreightCar initWithWorld:dynamicWorld:saveDict:chestSaveDict:cache:\n");
        }

        Class meta = object_getClass((id)fcClass);
        if (meta) {
            SEL sel_alloc = sel_registerName("alloc");
            Method alloc_m = class_getClassMethod(fcClass, sel_alloc);
            if (alloc_m && !orig_alloc_imp) {
                orig_alloc_imp = method_getImplementation(alloc_m);
                method_setImplementation(alloc_m, (IMP)safe_class_alloc);
                fprintf(stderr, "[patch] Hooked +[FreightCar alloc]\n");
            }
        }
    }
}

static void *hook_thread_fn(void *arg) {
    int tries = 0;
    const int max_tries = 120;
    while (tries < max_tries) {
        try_install_hooks_once();
        if (orig_fc_init1_imp || orig_fc_init2_imp || orig_fc_init3_imp || orig_alloc_imp) {
            fprintf(stderr, "[patch] FreightCar hooks installed (or partial). Stopping retry loop.\n");
            break;
        }
        usleep(500000);
        tries++;
    }
    if (tries >= max_tries) {
        fprintf(stderr, "[patch] Hook retry timed out after %d attempts\n", max_tries);
    }
    return NULL;
}

__attribute__((constructor))
static void install_objc_patches(void) {
    pthread_t tid;
    if (pthread_create(&tid, NULL, hook_thread_fn, NULL) == 0) {
        pthread_detach(tid);
        fprintf(stderr, "[patch] Hook thread started\n");
    } else {
        fprintf(stderr, "[patch] Failed to start hook thread\n");
    }
}
EOF

ok "Wrote patch source."

# Compile the patch
info "Compiling the LD_PRELOAD patch (this may print errors to $COMPILE_LOG)..."
rm -f "$PATCH_SO" "$COMPILE_LOG"
if command -v gcc >/dev/null 2>&1; then
  if gcc -shared -fPIC -o "$PATCH_SO" "$PATCH_C" -ldl -lobjc -pthread -O2 2> "$COMPILE_LOG"; then
    ok "Compiled $PATCH_SO successfully."
  else
    warn "Compilation failed. See $COMPILE_LOG for details. Continuing installation (server still usable without patch)."
    tail -n 120 "$COMPILE_LOG" || true
    rm -f "$PATCH_SO" 2>/dev/null || true
  fi
else
  warn "gcc not found. Install build-essential/gcc and re-run installer if you want the runtime patch."
fi

# Create launcher wrapper
info "Creating launcher wrapper $LAUNCHER ..."
cat > "$LAUNCHER" <<'SH_EOF'
#!/bin/bash
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH="$HERE/libbhpatch.so"
EXEC="$HERE/blockheads_server171"
# If compiled patch exists, preload it
if [ -f "$PATCH" ]; then
  export LD_PRELOAD="$PATCH${LD_PRELOAD:+:$LD_PRELOAD}"
fi
exec "$EXEC" "$@"
SH_EOF
chmod +x "$LAUNCHER" || true
ok "Launcher created: $LAUNCHER"

# Update server_manager.sh to use wrapper
if [ -f "server_manager.sh" ]; then
  info "Backing up server_manager.sh -> server_manager.sh$BACKUP_SUFFIX"
  cp -a server_manager.sh "server_manager.sh$BACKUP_SUFFIX" || true

  info "Updating server_manager.sh to use $LAUNCHER ..."
  # Replace SERVER_BINARY assignment or add it; also replace occurrences of ./blockheads_server171 with ./run_blockheads.sh
  if grep -q "^SERVER_BINARY=" server_manager.sh; then
    sed -i "s|^SERVER_BINARY=.*|SERVER_BINARY=\"./run_blockheads.sh\"|g" server_manager.sh
  else
    sed -i "1i SERVER_BINARY=\"./run_blockheads.sh\"" server_manager.sh
  fi
  # Replace direct references just in case
  sed -i "s|./blockheads_server171|./run_blockheads.sh|g" server_manager.sh || true
  ok "server_manager.sh updated (backup saved)."
else
  warn "server_manager.sh not found in current directory — skipping manager update."
fi

# Attempt patchelf compatibility tweaks (best-effort)
if command -v patchelf >/dev/null 2>&1; then
  info "Attempting patchelf compatibility adjustments (best-effort)."
  # common replacements (only if binary requires the original)
  declare -A LIBS_TO_TRY=(
    ["libgnustep-base.so.1.24"]="libgnustep-base.so.1.28"
    ["libobjc.so.4.6"]="libobjc.so.4"
    ["libgnutls.so.26"]="libgnutls.so.30"
    ["libgcrypt.so.11"]="libgcrypt.so.20"
    ["libffi.so.6"]="libffi.so.8"
  )
  for k in "${!LIBS_TO_TRY[@]}"; do
    if ldd "./$SERVER_BINARY" 2>/dev/null | grep -q "$k"; then
      patchelf --replace-needed "$k" "${LIBS_TO_TRY[$k]}" "./$SERVER_BINARY" 2>/dev/null || warn "patchelf replace $k failed"
    fi
  done
  ok "patchelf attempts done."
else
  warn "patchelf not installed; skipping compatibility replacements."
fi

# Set ownership & permissions
chown -R "$ORIGINAL_USER:$ORIGINAL_USER" . 2>/dev/null || true
chmod +x "$SERVER_BINARY" "$LAUNCHER" 2>/dev/null || true

info "Installation finished."

echo
echo -e "${PURPLE}--- USAGE NOTES ---${NC}"
echo "- Create a world:     ./run_blockheads.sh -n"
echo "- List worlds:        ./run_blockheads.sh -l"
echo "- Start server (manual): ./run_blockheads.sh -o <WORLD_ID> -p <PORT>"
echo "- Start with manager: ./server_manager.sh start <WORLD_ID> <PORT>"
echo "- Logs: $USER_HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves/<WORLD_ID>/console.log"
echo "- If patch compiled, it will be preloaded by ./run_blockheads.sh (libbhpatch.so)."
echo
if [ -f "$PATCH_SO" ]; then
  ok "Runtime patch present: $PATCH_SO (check $COMPILE_LOG for compile output)."
else
  warn "Runtime patch not present (compilation failed or gcc missing). Check $COMPILE_LOG."
fi

ok "Installer completed. Run ./run_blockheads.sh -n to create a world (press CTRL+C when done)."
