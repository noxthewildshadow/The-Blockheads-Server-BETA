#!/bin/bash
set -euo pipefail

# =============================================================================
# INSTALLER COMPLETO: Blockheads server + parche runtime (FreightCar + BHServer)
# - Descarga y extrae el servidor
# - Aplica patchelf de compatibilidad (intento)
# - Crea freight_patch.m (combinado), compila libfreightpatch.so
# - Crea wrapper run_server_with_patch.sh
# - Crea/instala server_manager.sh modificado (backup)
# - Crea backup del binario original (blockheads_server171.orig)
# =============================================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info(){ echo -e "${BLUE}[INFO]${NC} $*"; }
ok(){ echo -e "${GREEN}[OK]${NC} $*"; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $*"; }
err(){ echo -e "${RED}[ERR]${NC} $*"; }

if [ "$EUID" -ne 0 ]; then
  err "Este script debe ejecutarse como root. Usa: sudo ./install_blockheads_full.sh"
  exit 1
fi

ORIGINAL_USER=${SUDO_USER:-$USER}
WORKDIR="/opt/blockheads_server"
LOG="$WORKDIR/install_full_patch.log"

mkdir -p "$WORKDIR"
cd "$WORKDIR"
: > "$LOG"

# Config
SERVER_URLS=(
 "https://github.com/noxthewildshadow/The-Blockheads-Server-BETA/releases/download/1.0/blockheads_server171.tar"
)
TEMP_TAR="/tmp/blockheads_server171.tar"
SERVER_BINARY="blockheads_server171"
BACKUP_BINARY="${SERVER_BINARY}.orig"
PATCH_SO="libfreightpatch.so"
SOURCE_FILE="freight_patch.m"
WRAPPER="run_server_with_patch.sh"
MANAGER_FILE="server_manager.sh"

info "Directorio de instalación: $WORKDIR"
info "Log: $LOG"

# --------------------------
# Instalar dependencias (intentar)
# --------------------------
info "Instalando dependencias (apt-get). Esto puede tardar..."
apt-get update -y >>"$LOG" 2>&1 || true

PKGS=(clang build-essential patchelf wget jq screen lsof libgnustep-base-dev libobjc-8-dev libobjc-dev)
for p in "${PKGS[@]}"; do
  info "Instalando paquete: $p"
  apt-get install -y "$p" >>"$LOG" 2>&1 || warn "No se pudo instalar $p (continuando)"
done
ok "Intento de instalación de dependencias completado (ver $LOG)."

# --------------------------
# Descargar servidor
# --------------------------
info "Descargando paquete del servidor..."
DL_OK=0
for url in "${SERVER_URLS[@]}"; do
  if wget -q --timeout=30 --tries=3 -O "$TEMP_TAR" "$url"; then
    DL_OK=1
    info "Descargado desde: $url"
    break
  else
    warn "Fallo descarga desde: $url"
  fi
done
if [ $DL_OK -eq 0 ]; then
  err "No se pudo descargar el servidor. Revisa las URLs."
  exit 1
fi

# --------------------------
# Extraer
# --------------------------
info "Extrayendo paquete..."
EXDIR=$(mktemp -d -t bh_extract_XXXX)
tar -xf "$TEMP_TAR" -C "$EXDIR" >>"$LOG" 2>&1 || ( err "Fallo al extraer" && exit 1 )
cp -r "$EXDIR"/* ./
rm -rf "$EXDIR" "$TEMP_TAR"
ok "Extracción completada."

# --------------------------
# Detectar/renombrar binario si hace falta
# --------------------------
if [ ! -f "$SERVER_BINARY" ]; then
  ALT=$(find . -maxdepth 2 -type f -executable -name "*blockheads*" | head -n1 || true)
  if [ -n "$ALT" ]; then
    mv "$ALT" "$SERVER_BINARY" || cp "$ALT" "$SERVER_BINARY"
    ok "Renombrado $ALT -> $SERVER_BINARY"
  fi
fi

if [ ! -f "$SERVER_BINARY" ]; then
  err "No se encontró el binario $SERVER_BINARY después de la extracción."
  ls -lah
  exit 1
fi

chmod +x "$SERVER_BINARY"
ok "Binario listo: $SERVER_BINARY"

# --------------------------
# patchelf: intentos de compatibilidad
# --------------------------
info "Aplicando parche de compatibilidad con patchelf (si aplica)..."
find_library() {
  ldconfig -p 2>/dev/null | grep -F "$1" | awk '{print $NF}' | head -n1 || true
}
declare -A LIBS_MAP=(
  ["libgnustep-base.so.1.24"]="$(find_library libgnustep-base.so || echo libgnustep-base.so)"
  ["libobjc.so.4.6"]="$(find_library libobjc.so || echo libobjc.so)"
  ["libdispatch.so"]="$(find_library libdispatch.so || echo libdispatch.so)"
)
for lib in "${!LIBS_MAP[@]}"; do
  target="${LIBS_MAP[$lib]}"
  if [ -n "$target" ]; then
    patchelf --replace-needed "$lib" "$target" "$SERVER_BINARY" >>"$LOG" 2>&1 || warn "patchelf no pudo reemplazar $lib -> $target"
  fi
done
ok "Intento de patchelf completado."

# --------------------------
# Crear backup del binario original si no existe
# --------------------------
if [ -f "$SERVER_BINARY" ] && [ ! -f "$BACKUP_BINARY" ]; then
  cp -a "$SERVER_BINARY" "$BACKUP_BINARY" 2>>"$LOG" || cp "$SERVER_BINARY" "$BACKUP_BINARY"
  chmod 755 "$BACKUP_BINARY" 2>/dev/null || true
  chown "$ORIGINAL_USER:$ORIGINAL_USER" "$BACKUP_BINARY" 2>/dev/null || true
  ok "Backup del binario creado: $BACKUP_BINARY"
else
  info "Backup del binario ya existe o binario no encontrado (skip)."
fi

# --------------------------
# Escribir fuente del parche combinado (FreightCar + BHServer)
# --------------------------
info "Escribiendo fuente del parche combinado: $SOURCE_FILE"
cat > "$SOURCE_FILE" <<'EOF'
// freight_patch.m
// Parche combinado: FreightCar (init replacements) + BHServer (protect bad packets)
// Compilar: clang -shared -fPIC -o libfreightpatch.so freight_patch.m -lobjc

#import <stdio.h>
#import <stdlib.h>
#import <objc/objc.h>
#import <objc/runtime.h>
#import <objc/message.h>

// --------------------------- FreightCar replacements ---------------------------

static id my_initWithWorld_dynamicWorld_atPosition_cache_saveDict_placedByClient(
    id self, SEL _cmd,
    int arg1, int arg2, int arg3, int arg4, int arg5, int arg6)
{
    SEL selSetNeeds = sel_getUid("setNeedsRemoved:");
    if (selSetNeeds) {
        void (*msg_setNeedsRemoved)(id, SEL, BOOL) = (void(*)(id, SEL, BOOL))objc_msgSend;
        msg_setNeedsRemoved(self, selSetNeeds, (BOOL)1);
    }
    SEL selDealloc = sel_getUid("dealloc");
    if (selDealloc) {
        void (*msg_dealloc)(id, SEL) = (void(*)(id, SEL))objc_msgSend;
        msg_dealloc(self, selDealloc);
    }
    return (id)NULL;
}

static id my_initWithWorld_dynamicWorld_cache_netData(
    id self, SEL _cmd,
    int arg1, int arg2, int arg3, int arg4)
{
    SEL selSetNeeds = sel_getUid("setNeedsRemoved:");
    if (selSetNeeds) {
        void (*msg_setNeedsRemoved)(id, SEL, BOOL) = (void(*)(id, SEL, BOOL))objc_msgSend;
        msg_setNeedsRemoved(self, selSetNeeds, (BOOL)1);
    }
    SEL selDealloc = sel_getUid("dealloc");
    if (selDealloc) {
        void (*msg_dealloc)(id, SEL) = (void(*)(id, SEL))objc_msgSend;
        msg_dealloc(self, selDealloc);
    }
    return (id)NULL;
}

static id my_initWithWorld_dynamicWorld_saveDict_chestSaveDict_cache(
    id self, SEL _cmd,
    int arg1, int arg2, int arg3, int arg4, int arg5)
{
    SEL selSetNeeds = sel_getUid("setNeedsRemoved:");
    if (selSetNeeds) {
        void (*msg_setNeedsRemoved)(id, SEL, BOOL) = (void(*)(id, SEL, BOOL))objc_msgSend;
        msg_setNeedsRemoved(self, selSetNeeds, (BOOL)1);
    }
    SEL selDealloc = sel_getUid("dealloc");
    if (selDealloc) {
        void (*msg_dealloc)(id, SEL) = (void(*)(id, SEL))objc_msgSend;
        msg_dealloc(self, selDealloc);
    }
    return (id)NULL;
}

// --------------------------- BHServer replacement (preserve original) ---------------------------

static void (*orig_BHServer_match_didReceiveData_fromPlayer)(id, SEL, id, id, id) = NULL;

static void my_BHServer_match_didReceiveData_fromPlayer(id self, SEL _cmd, id match, id data, id player) {
    if (!data) {
        fprintf(stderr, "[BadPacketCrashPatch] Detected nil data, preventing crash. Player: %p\n", player);
        return;
    }

    SEL selLength = sel_getUid("length");
    if (!selLength) {
        if (orig_BHServer_match_didReceiveData_fromPlayer) {
            orig_BHServer_match_didReceiveData_fromPlayer(self, _cmd, match, data, player);
        }
        return;
    }

    unsigned long data_len = ((unsigned long (*)(id, SEL))objc_msgSend)(data, selLength);
    if (data_len == 0) {
        fprintf(stderr, "[BadPacketCrashPatch] Detected empty packet (length 0), preventing crash. Player: %p\n", player);
        return;
    }

    if (orig_BHServer_match_didReceiveData_fromPlayer) {
        orig_BHServer_match_didReceiveData_fromPlayer(self, _cmd, match, data, player);
    }
}

// --------------------------- Constructor: instala los method swaps ---------------------------

__attribute__((constructor))
static void freight_and_bh_patch_init(void)
{
    // FreightCar
    Class freightClass = objc_getClass("FreightCar");
    if (!freightClass) {
        fprintf(stderr, "[freight_patch] Clase FreightCar no encontrada.\n");
    } else {
        SEL sel1 = sel_getUid("initWithWorld:dynamicWorld:atPosition:cache:saveDict:placedByClient:");
        Method m1 = sel1 ? class_getInstanceMethod(freightClass, sel1) : NULL;
        if (m1) {
            const char *typeEnc = method_getTypeEncoding(m1);
            class_replaceMethod(freightClass, sel1, (IMP)my_initWithWorld_dynamicWorld_atPosition_cache_saveDict_placedByClient, typeEnc);
            fprintf(stderr, "[freight_patch] Reemplazado FreightCar selector 1 OK\n");
        } else {
            fprintf(stderr, "[freight_patch] FreightCar selector 1 no encontrado.\n");
        }

        SEL sel2 = sel_getUid("initWithWorld:dynamicWorld:cache:netData:");
        Method m2 = sel2 ? class_getInstanceMethod(freightClass, sel2) : NULL;
        if (m2) {
            const char *typeEnc = method_getTypeEncoding(m2);
            class_replaceMethod(freightClass, sel2, (IMP)my_initWithWorld_dynamicWorld_cache_netData, typeEnc);
            fprintf(stderr, "[freight_patch] Reemplazado FreightCar selector 2 OK\n");
        } else {
            fprintf(stderr, "[freight_patch] FreightCar selector 2 no encontrado.\n");
        }

        SEL sel3 = sel_getUid("initWithWorld:dynamicWorld:saveDict:chestSaveDict:cache:");
        Method m3 = sel3 ? class_getInstanceMethod(freightClass, sel3) : NULL;
        if (m3) {
            const char *typeEnc = method_getTypeEncoding(m3);
            class_replaceMethod(freightClass, sel3, (IMP)my_initWithWorld_dynamicWorld_saveDict_chestSaveDict_cache, typeEnc);
            fprintf(stderr, "[freight_patch] Reemplazado FreightCar selector 3 OK\n");
        } else {
            fprintf(stderr, "[freight_patch] FreightCar selector 3 no encontrado.\n");
        }
    }

    // BHServer
    Class bhClass = objc_getClass("BHServer");
    if (!bhClass) {
        fprintf(stderr, "[BadPacketCrashPatch] Clase BHServer no encontrada.\n");
    } else {
        SEL selBH = sel_getUid("match:didReceiveData:fromPlayer:");
        Method mbh = selBH ? class_getInstanceMethod(bhClass, selBH) : NULL;
        if (mbh) {
            IMP originalIMP = method_getImplementation(mbh);
            orig_BHServer_match_didReceiveData_fromPlayer = (void (*)(id, SEL, id, id, id))originalIMP;
            method_setImplementation(mbh, (IMP)my_BHServer_match_didReceiveData_fromPlayer);
            fprintf(stderr, "[BadPacketCrashPatch] Reemplazado BHServer match:didReceiveData:fromPlayer: OK\n");
        } else {
            fprintf(stderr, "[BadPacketCrashPatch] Selector BHServer match:didReceiveData:fromPlayer: no encontrado.\n");
        }
    }

    fprintf(stderr, "[freight_patch] Init complete\n");
}
EOF

ok "Fuente del parche escrita: $SOURCE_FILE"

# --------------------------
# Compilar la .so
# --------------------------
info "Compilando $SOURCE_FILE -> $PATCH_SO..."
COMPILE_OK=0
if command -v clang >/dev/null 2>&1; then
  if clang -shared -fPIC -o "$PATCH_SO" "$SOURCE_FILE" -lobjc >>"$LOG" 2>&1; then
    COMPILE_OK=1
  fi
fi
if [ $COMPILE_OK -eq 0 ] && command -v gcc >/dev/null 2>&1; then
  warn "clang no disponible o falló; intentando gcc..."
  if gcc -shared -fPIC -o "$PATCH_SO" "$SOURCE_FILE" -lobjc >>"$LOG" 2>&1; then
    COMPILE_OK=1
  fi
fi

if [ $COMPILE_OK -eq 1 ]; then
  chmod 755 "$PATCH_SO"
  chown "$ORIGINAL_USER:$ORIGINAL_USER" "$PATCH_SO" 2>/dev/null || true
  ok "Compilación OK: $PATCH_SO creado."
else
  warn "Fallo la compilación de $PATCH_SO. Revisa $LOG para errores."
fi

# --------------------------
# Crear wrapper run_server_with_patch.sh
# --------------------------
info "Creando wrapper: $WRAPPER"
cat > "$WRAPPER" <<'EOF'
#!/bin/bash
cd "$(pwd)"
SO_PATH="$(pwd)/libfreightpatch.so"
if [ -f "$SO_PATH" ]; then
    export LD_PRELOAD="$SO_PATH${LD_PRELOAD:+:$LD_PRELOAD}"
fi
exec ./blockheads_server171 "$@"
EOF
chmod +x "$WRAPPER"
chown "$ORIGINAL_USER:$ORIGINAL_USER" "$WRAPPER" 2>/dev/null || true
ok "Wrapper creado: $WRAPPER"

# --------------------------
# Instalar server_manager.sh modificado (respaldo si existe)
# --------------------------
info "Instalando server_manager.sh modificado (respaldando el existente si aplica)..."
if [ -f "$MANAGER_FILE" ]; then
  cp "$MANAGER_FILE" "${MANAGER_FILE}.bak" 2>>"$LOG" || warn "No se pudo crear backup de $MANAGER_FILE"
  ok "Backup de $MANAGER_FILE creado: ${MANAGER_FILE}.bak"
fi

cat > "$MANAGER_FILE" <<'EOF'
#!/bin/bash
# =============================================================================
# THE BLOCKHEADS SERVER MANAGER (MODIFIED: backups, LD_PRELOAD patching, systemd)
# =============================================================================

# Load common functions
source blockheads_common.sh

# Determine original installer user (used for systemd User= and chown)
ORIGINAL_USER=${SUDO_USER:-$USER}
INSTALL_DIR="$(pwd)"

# Server binary and default port
SERVER_BINARY="./blockheads_server171"
DEFAULT_PORT=12153
PATCH_SO="./libfreightpatch.so"
WRAPPER="./run_server_with_patch.sh"
BACKUP_BINARY="./blockheads_server171.orig"

# Ensure wrapper exists (create a conservative wrapper if absent)
ensure_wrapper() {
    if [ -x "$WRAPPER" ]; then
        return 0
    fi

    cat > "$WRAPPER" <<'WRAP_EOF'
#!/bin/bash
# wrapper to run server with LD_PRELOAD if lib is present
cd "$(pwd)"
SO_PATH="$(pwd)/libfreightpatch.so"
if [ -f "$SO_PATH" ]; then
    export LD_PRELOAD="$SO_PATH${LD_PRELOAD:+:$LD_PRELOAD}"
fi
exec ./blockheads_server171 "$@"
WRAP_EOF

    chmod +x "$WRAPPER"
    print_success "Created wrapper: $WRAPPER"
}

# Function to create backup of the binary if not exists
create_backup_if_missing() {
    if [ -f "$SERVER_BINARY" ] && [ ! -f "$BACKUP_BINARY" ]; then
        cp -a "$SERVER_BINARY" "$BACKUP_BINARY" 2>/dev/null || cp "$SERVER_BINARY" "$BACKUP_BINARY"
        chmod 755 "$BACKUP_BINARY" 2>/dev/null || true
        chown "$ORIGINAL_USER:$ORIGINAL_USER" "$BACKUP_BINARY" 2>/dev/null || true
        print_success "Backup created: $BACKUP_BINARY"
    fi
}

# Function to install a systemd service for a specific world and port
install_service() {
    local world_id="$1"
    local port="${2:-$DEFAULT_PORT}"

    if [ -z "$world_id" ]; then
        print_error "You must specify a WORLD_NAME to install the service."
        return 1
    fi

    # Ensure wrapper exists
    ensure_wrapper

    local abs_dir
    abs_dir="$(pwd)"
    local unit_name="blockheads_${port}.service"
    local unit_path="/etc/systemd/system/${unit_name}"

    # Create systemd unit (requires root to write to /etc/systemd/system)
    cat > /tmp/${unit_name} <<UNIT_EOF
[Unit]
Description=Blockheads server for ${world_id} on port ${port}
After=network.target

[Service]
Type=simple
WorkingDirectory=${abs_dir}
User=${ORIGINAL_USER}
Environment=LD_PRELOAD=${abs_dir}/libfreightpatch.so
ExecStart=${abs_dir}/run_server_with_patch.sh -o '${world_id}' -p ${port}
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
UNIT_EOF

    # Move into place (use sudo if needed)
    if [ "$EUID" -ne 0 ]; then
        print_step "Writing systemd unit as root via sudo: ${unit_name}"
        sudo mv /tmp/${unit_name} "$unit_path" || { print_error "Failed to write $unit_path (sudo failed)"; rm -f /tmp/${unit_name}; return 1; }
        sudo systemctl daemon-reload || { print_error "systemctl daemon-reload failed"; return 1; }
        sudo systemctl enable --now "$unit_name" || { print_warning "Failed to enable/start $unit_name via sudo"; }
    else
        mv /tmp/${unit_name} "$unit_path" || { print_error "Failed to write $unit_path"; rm -f /tmp/${unit_name}; return 1; }
        systemctl daemon-reload || { print_error "systemctl daemon-reload failed"; return 1; }
        systemctl enable --now "$unit_name" || { print_warning "Failed to enable/start $unit_name"; }
    fi

    print_success "Systemd service installed and (attempted) started: $unit_name"
    print_status "To check status: sudo systemctl status $unit_name"
    return 0
}

# Function to check if world exists
check_world_exists() {
    local world_id="$1"
    local saves_dir="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves"
    [ -d "$saves_dir/$world_id" ] || {
        print_error "World '$world_id' does not exist in: $saves_dir/"
        echo ""
        print_warning "To create a world: ${GREEN}./blockheads_server171 -n${NC}"
        print_warning "After creating the world, press ${YELLOW}CTRL+C${NC} to exit"
        return 1
    }
    return 0
}

# Function to free port
free_port() {
    local port="$1"
    print_warning "Freeing port $port..."
    local pids
    pids=$(lsof -ti ":$port" 2>/dev/null || true)
    [ -n "$pids" ] && kill -9 $pids 2>/dev/null

    local screen_server="blockheads_server_$port"
    local screen_bot="blockheads_bot_$port"
    local screen_anticheat="blockheads_anticheat_$port"

    screen_session_exists "$screen_server" && screen -S "$screen_server" -X quit 2>/dev/null
    screen_session_exists "$screen_bot" && screen -S "$screen_bot" -X quit 2>/dev/null
    screen_session_exists "$screen_anticheat" && screen -S "$screen_anticheat" -X quit 2>/dev/null

    sleep 2
    ! is_port_in_use "$port"
}

# Function to start server
start_server() {
    local world_id="$1"
    local port="${2:-$DEFAULT_PORT}"

    local SCREEN_SERVER="blockheads_server_$port"
    local SCREEN_BOT="blockheads_bot_$port"
    local SCREEN_ANTICHEAT="blockheads_anticheat_$port"

    [ ! -f "$SERVER_BINARY" ] && {
        print_error "Server binary not found: $SERVER_BINARY"
        print_warning "Run the installer first: ${GREEN}./installer.sh${NC}"
        return 1
    }

    # Ensure backup exists before any run
    create_backup_if_missing

    check_world_exists "$world_id" || return 1

    is_port_in_use "$port" && {
        print_warning "Port $port is in use."
        if ! free_port "$port"; then
            print_error "Could not free port $port"
            return 1
        fi
    }

    screen_session_exists "$SCREEN_SERVER" && screen -S "$SCREEN_SERVER" -X quit 2>/dev/null
    screen_session_exists "$SCREEN_BOT" && screen -S "$SCREEN_BOT" -X quit 2>/dev/null
    screen_session_exists "$SCREEN_ANTICHEAT" && screen -S "$SCREEN_ANTICHEAT" -X quit 2>/dev/null

    sleep 1

    local log_dir="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves/$world_id"
    local log_file="$log_dir/console.log"
    mkdir -p "$log_dir"

    print_step "Starting server - World: $world_id, Port: $port"
    echo "$world_id" > "world_id_$port.txt"

    # Ensure wrapper exists so systemd and start use the same launcher
    ensure_wrapper

    cat > /tmp/start_server_$$.sh <<EOF_SCRIPT
#!/bin/bash
cd '$PWD'

# If a libfreightpatch.so exists in this directory, preload it so the runtime patch is active.
SO_PATH="\$PWD/libfreightpatch.so"
if [ -f "\$SO_PATH" ]; then
    echo "[freight_patch] Found patch: \$SO_PATH" >&2
    export LD_PRELOAD="\$SO_PATH\${LD_PRELOAD:+:\$LD_PRELOAD}"
    echo "[freight_patch] LD_PRELOAD set to: \$LD_PRELOAD" >&2
fi

while true; do
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Starting server..."
    # Use the wrapper to ensure consistent LD_PRELOAD behaviour
    if $WRAPPER -o '$world_id' -p $port 2>&1 | tee -a '$log_file'; then
        echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Server closed normally"
    else
        exit_code=\$?
        echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Server failed with code: \$exit_code"
        if [ \$exit_code -eq 1 ] && tail -n 5 '$log_file' | grep -q "port.*already in use"; then
            echo "[\$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Port already in use. Will not retry."
            break
        fi
    fi
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Restarting in 5 seconds..."
    sleep 5
done
EOF_SCRIPT

    chmod +x /tmp/start_server_$$.sh
    screen -dmS "$SCREEN_SERVER" /tmp/start_server_$$.sh
    (sleep 10; rm -f /tmp/start_server_$$.sh) &

    print_step "Waiting for server to start..."
    local wait_time=0
    while [ ! -f "$log_file" ] && [ $wait_time -lt 15 ]; do
        sleep 1
        ((wait_time++))
    done

    [ ! -f "$log_file" ] && {
        print_error "Could not create log file. Server may not have started."
        return 1
    }

    local server_ready=false
    for i in {1..30}; do
        if grep -q "World load complete\|Server started\|Ready for connections\|using seed:\|save delay:" "$log_file"; then
            server_ready=true
            break
        fi
        sleep 1
    done

    [ "$server_ready" = false ] && {
        print_warning "Server did not show complete startup messages"
        if ! screen_session_exists "$SCREEN_SERVER"; then
            print_error "Server screen session not found"
            return 1
        fi
    } || print_success "Server started successfully!"

    print_step "Starting server bot..."
    screen -dmS "$SCREEN_BOT" bash -c "
        cd '$PWD'
        echo 'Starting server bot for port $port...'
        ./server_bot.sh '$log_file' '$port'
    "

    print_step "Starting anticheat security system..."
    screen -dmS "$SCREEN_ANTICHEAT" bash -c "
        cd '$PWD'
        echo 'Starting anticheat for port $port...'
        ./anticheat_secure.sh '$log_file' '$port'
    "

    local server_started=0 bot_started=0 anticheat_started=0

    screen_session_exists "$SCREEN_SERVER" && server_started=1
    screen_session_exists "$SCREEN_BOT" && bot_started=1
    screen_session_exists "$SCREEN_ANTICHEAT" && anticheat_started=1

    if [ "$server_started" -eq 1 ] && [ "$bot_started" -eq 1 ] && [ "$anticheat_started" -eq 1 ]; then
        print_header "SERVER, BOT AND ANTICHEAT STARTED SUCCESSFULLY!"
        print_success "World: $world_id"
        print_success "Port: $port"
        echo ""
        print_status "To view server console: ${CYAN}screen -r $SCREEN_SERVER${NC}"
        print_status "To view bot: ${CYAN}screen -r $SCREEN_BOT${NC}"
        print_status "To view anticheat: ${CYAN}screen -r $SCREEN_ANTICHEAT${NC}"
        echo ""
        print_warning "To exit console without stopping server: ${YELLOW}CTRL+A, D${NC}"
    else
        print_warning "Could not verify all screen sessions"
    fi
}

# Function to stop server
stop_server() {
    local port="$1"

    if [ -z "$port" ]; then
        print_step "Stopping all servers, bots and anticheat..."

        for server_session in $(screen -list | grep "blockheads_server_" | awk -F. '{print $1}'); do
            screen -S "$server_session" -X quit 2>/dev/null
            print_success "Stopped server: $server_session"
        done

        for bot_session in $(screen -list | grep "blockheads_bot_" | awk -F. '{print $1}'); do
            screen -S "$bot_session" -X quit 2>/dev/null
            print_success "Stopped bot: $bot_session"
        done

        for anticheat_session in $(screen -list | grep "blockheads_anticheat_" | awk -F. '{print $1}'); do
            screen -S "$anticheat_session" -X quit 2>/dev/null
            print_success "Stopped anticheat: $anticheat_session"
        done

        pkill -f "$SERVER_BINARY" 2>/dev/null || true
        print_success "Cleanup completed for all servers."
    else
        print_step "Stopping server, bot and anticheat on port $port..."

        local screen_server="blockheads_server_$port"
        local screen_bot="blockheads_bot_$port"
        local screen_anticheat="blockheads_anticheat_$port"

        if screen_session_exists "$screen_server"; then
            screen -S "$screen_server" -X quit 2>/dev/null
            print_success "Server stopped on port $port."
        else
            print_warning "Server was not running on port $port."
        fi

        if screen_session_exists "$screen_bot"; then
            screen -S "$screen_bot" -X quit 2>/dev/null
            print_success "Bot stopped on port $port."
        else
            print_warning "Bot was not running on port $port."
        fi

        if screen_session_exists "$screen_anticheat"; then
            screen -S "$screen_anticheat" -X quit 2>/dev/null
            print_success "Anticheat stopped on port $port."
        else
            print_warning "Anticheat was not running on port $port."
        fi

        pkill -f "$SERVER_BINARY.*$port" 2>/dev/null || true
        print_success "Cleanup completed for port $port."
    fi
}

# Function to list servers
list_servers() {
    print_header "LIST OF RUNNING SERVERS"

    local servers
    servers=$(screen -list | grep "blockheads_server_" | awk -F. '{print $1}' | sed 's/blockheads_server_/ - Port: /' || true)

    if [ -z "$servers" ]; then
        print_warning "No servers are currently running."
    else
        print_status "Running servers:"
        while IFS= read -r server; do
            print_status "  $server"
        done <<< "$servers"
    fi

    print_header "END OF LIST"
}

# Function to show status
show_status() {
    local port="$1"

    if [ -z "$port" ]; then
        print_header "THE BLOCKHEADS SERVER STATUS - ALL SERVERS"

        local servers
        servers=$(screen -list | grep "blockheads_server_" | awk -F. '{print $1}' | sed 's/blockheads_server_//' || true)

        if [ -z "$servers" ]; then
            print_error "No servers are currently running."
        else
            while IFS= read -r server_port; do
                if screen_session_exists "blockheads_server_$server_port"; then
                    print_success "Server on port $server_port: RUNNING"
                else
                    print_error "Server on port $server_port: STOPPED"
                fi

                if screen_session_exists "blockheads_bot_$server_port"; then
                    print_success "Bot on port $server_port: RUNNING"
                else
                    print_error "Bot on port $server_port: STOPPED"
                fi

                if screen_session_exists "blockheads_anticheat_$server_port"; then
                    print_success "Anticheat on port $server_port: RUNNING"
                else
                    print_error "Anticheat on port $server_port: STOPPED"
                fi

                if [ -f "world_id_$server_port.txt" ]; then
                    local WORLD_ID
                    WORLD_ID=$(cat "world_id_$server_port.txt" 2>/dev/null)
                    print_status "World for port $server_port: ${CYAN}$WORLD_ID${NC}"
                fi

                echo ""
            done <<< "$servers"
        fi
    else
        print_header "THE BLOCKHEADS SERVER STATUS - PORT $port"

        if screen_session_exists "blockheads_server_$port"; then
            print_success "Server: RUNNING"
        else
            print_error "Server: STOPPED"
        fi

        if screen_session_exists "blockheads_bot_$port"; then
            print_success "Bot: RUNNING"
        else
            print_error "Bot: STOPPED"
        fi

        if screen_session_exists "blockheads_anticheat_$port"; then
            print_success "Anticheat: RUNNING"
        else
            print_error "Anticheat: STOPPED"
        fi

        if [ -f "world_id_$port.txt" ]; then
            local WORLD_ID
            WORLD_ID=$(cat "world_id_$port.txt" 2>/dev/null)
            print_status "Current world: ${CYAN}$WORLD_ID${NC}"

            if screen_session_exists "blockheads_server_$port"; then
                print_status "To view console: ${CYAN}screen -r blockheads_server_$port${NC}"
                print_status "To view bot: ${CYAN}screen -r blockheads_bot_$port${NC}"
                print_status "To view anticheat: ${CYAN}screen -r blockheads_anticheat_$port${NC}"
            fi
        else
            print_warning "World: Not configured for port $port"
        fi
    fi

    print_header "END OF STATUS"
}

# Function to show usage
show_usage() {
    print_header "THE BLOCKHEADS SERVER MANAGER"
    print_status "Usage: $0 [command]"
    echo ""
    print_status "Available commands:"
    echo -e "  ${GREEN}start${NC} [WORLD_NAME] [PORT]      - Start server, bot and anticheat"
    echo -e "  ${GREEN}install-service${NC} [WORLD_NAME] [PORT] - Install systemd service for this world (requires sudo)"
    echo -e "  ${RED}stop${NC} [PORT]                    - Stop server, bot and anticheat"
    echo -e "  ${CYAN}status${NC} [PORT]                  - Show server status"
    echo -e "  ${YELLOW}list${NC}                         - List all running servers"
    echo -e "  ${YELLOW}help${NC}                         - Show this help"
    echo ""
    print_status "Examples:"
    echo -e "  ${GREEN}$0 start MyWorld 12153${NC}"
    echo -e "  ${GREEN}$0 install-service MyWorld 12153${NC} (creates systemd unit blockheads_12153.service)"
    echo -e "  ${RED}$0 stop 12153${NC}"
    echo -e "  ${CYAN}$0 status 12153${NC}"
    echo -e "  ${YELLOW}$0 list${NC}"
    echo ""
    print_warning "First create a world: ./blockheads_server171 -n"
    print_warning "After creating the world, press CTRL+C to exit"
}

# Main execution
case "$1" in
    start)
        [ -z "$2" ] && print_error "You must specify a WORLD_NAME" && show_usage && exit 1
        start_server "$2" "$3"
        ;;
    install-service)
        [ -z "$2" ] && print_error "You must specify a WORLD_NAME" && show_usage && exit 1
        install_service "$2" "$3"
        ;;
    stop)
        stop_server "$2"
        ;;
    status)
        show_status "$2"
        ;;
    list)
        list_servers
        ;;
    help|--help|-h|*)
        show_usage
        ;;
esac
EOF

chmod +x "$MANAGER_FILE"
chown "$ORIGINAL_USER:$ORIGINAL_USER" "$MANAGER_FILE" 2>/dev/null || true
ok "server_manager.sh modificado/instalado (backup si existía)."

# --------------------------
# Final: permisos, mensajes
# --------------------------
chown -R "$ORIGINAL_USER:$ORIGINAL_USER" "$WORKDIR" 2>/dev/null || true
chmod +x "$SERVER_BINARY" "$WRAPPER" "$MANAGER_FILE" 2>/dev/null || true

echo ""
ok "Instalación finalizada."
echo "Resumen de archivos en: $WORKDIR"
ls -lah "$WORKDIR" | sed -n '1,200p'
echo ""
echo "¿Qué sigue?  (comandos exactos):"
echo "  cd $WORKDIR"
echo "  # (opcional) revisar log de instalación:"
echo "  sudo less $LOG"
echo ""
echo "  # Crear un mundo (si no existe):"
echo "  sudo -u $ORIGINAL_USER ./blockheads_server171 -n"
echo ""
echo "  # Arrancar servidor con manager (usa el wrapper y la .so si existe):"
echo "  sudo -u $ORIGINAL_USER ./server_manager.sh start MyWorld 12153"
echo ""
echo "  # Alternativa: arrancar manual con wrapper (útil para debug):"
echo "  sudo -u $ORIGINAL_USER ./run_server_with_patch.sh -o MyWorld -p 12153 2> freight_patch_runtime.log &"
echo "  tail -f freight_patch_runtime.log"
echo ""
echo "  # Para crear servicio systemd (requiere sudo):"
echo "  ./server_manager.sh install-service MyWorld 12153"
echo ""
echo "Logs útiles:"
echo "  - Instalador: $LOG"
echo "  - Runtime (si usas wrapper y rediriges): freight_patch_runtime.log"
echo "  - Server console: \$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves/<World>/console.log"
echo ""
echo "IMPORTANTE: Haz backup de tus mundos antes de pruebas en producción."
echo ""

exit 0
