#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <dlfcn.h>
#include <pthread.h>
#include <unistd.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>

// --- CONSTANTES ---
#define AF_MAX_QUEUE 50
#define AF_TRAVERSE_FLY 28
#define AF_KICK_DELAY 3.0f
#define AF_COOLDOWN_TIME 5.0f

// --- TIPOS (Locales) ---
typedef void* id;
typedef void* SEL;
typedef void* Class;
typedef void* Method;
typedef void* Ivar;
typedef void (*AF_IMP)(id, SEL, ...);

typedef id (*AF_IMP_Str)(Class, SEL, const char*);
typedef void (*AF_IMP_Chat)(id, SEL, id, char, id);
typedef void (*AF_IMP_Cmd)(id, SEL, id, id);
typedef const char* (*AF_IMP_UTF8)(id, SEL);

// --- PUNTEROS RUNTIME (Static para no chocar) ---
static Class (*AF_objc_getClass)(const char *name);
static SEL (*AF_sel_registerName)(const char *name);
static Method (*AF_class_getInstanceMethod)(Class cls, SEL name);
static Method (*AF_class_getClassMethod)(Class cls, SEL name);
static AF_IMP (*AF_method_setImplementation)(Method m, AF_IMP imp);
static AF_IMP (*AF_method_getImplementation)(Method m);
static Ivar (*AF_class_getInstanceVariable)(Class cls, const char *name);
static ptrdiff_t (*AF_ivar_getOffset)(Ivar v);

// --- GLOBALES DEL PARCHE (Con Prefijo AF_) ---
AF_IMP AF_orig_GC_update = NULL;
AF_IMP AF_orig_BH_update = NULL;

// Offsets
static ptrdiff_t AF_off_traverse = 0;
static ptrdiff_t AF_off_isFlying = 0;
static ptrdiff_t AF_off_bhServer = 0;
static ptrdiff_t AF_off_clientName = 0;
static bool AF_offsets_ready = false;

// =============================================================
// GESTIÓN DE COOLDOWN (Anti-Rebote)
// =============================================================
typedef struct {
    char name[128];
    float timer;
    bool active;
} AF_CooldownEntry;

static AF_CooldownEntry AF_cooldown_list[AF_MAX_QUEUE];

bool AF_IsOnCooldown(const char* name) {
    for (int i = 0; i < AF_MAX_QUEUE; i++) {
        if (AF_cooldown_list[i].active && strcmp(AF_cooldown_list[i].name, name) == 0) {
            return true;
        }
    }
    return false;
}

void AF_AddToCooldown(const char* name) {
    for (int i = 0; i < AF_MAX_QUEUE; i++) {
        if (!AF_cooldown_list[i].active) {
            strncpy(AF_cooldown_list[i].name, name, 127);
            AF_cooldown_list[i].timer = AF_COOLDOWN_TIME;
            AF_cooldown_list[i].active = true;
            return;
        }
    }
}

// =============================================================
// GESTIÓN DE COLA (QUEUE)
// =============================================================
static char AF_kick_queue[AF_MAX_QUEUE][128];
static int AF_queue_read = 0;
static int AF_queue_write = 0;
static int AF_queue_count = 0;

const char* AF_PeekQueue() {
    if (AF_queue_count == 0) return NULL;
    return AF_kick_queue[AF_queue_read];
}

void AF_PopQueue() {
    if (AF_queue_count > 0) {
        AF_queue_read = (AF_queue_read + 1) % AF_MAX_QUEUE;
        AF_queue_count--;
    }
}

void AF_AddToQueue(const char* name) {
    if (AF_queue_count >= AF_MAX_QUEUE) return;
    if (!name || strlen(name) < 1 || strcmp(name, "Unknown") == 0) return;

    // Verificar duplicados
    for (int i = 0; i < AF_queue_count; i++) {
        int idx = (AF_queue_read + i) % AF_MAX_QUEUE;
        if (strcmp(AF_kick_queue[idx], name) == 0) return;
    }

    // Verificar Cooldown
    if (AF_IsOnCooldown(name)) return;

    // Agregar
    strncpy(AF_kick_queue[AF_queue_write], name, 127);
    AF_queue_write = (AF_queue_write + 1) % AF_MAX_QUEUE;
    AF_queue_count++;
    
    // Log mínimo
    printf("[Anti-Fly] Detectado: %s\n", name);
}

// Variables de Estado
static float AF_kick_timer = 0.0f;
static bool AF_warning_sent = false;

// =============================================================
// HELPERS (Con Prefijo AF_)
// =============================================================
id AF_MakeString(const char* text) {
    if (!text) return NULL;
    Class cls = AF_objc_getClass("NSString");
    SEL sel = AF_sel_registerName("stringWithUTF8String:");
    Method m = AF_class_getClassMethod(cls, sel);
    if (!m) return NULL;
    AF_IMP_Str func = (AF_IMP_Str)AF_method_getImplementation(m);
    return func(cls, sel, text);
}

const char* AF_ObjC_To_C(id nsStr) {
    if (!nsStr) return NULL;
    Class cls = AF_objc_getClass("NSString");
    SEL sel = AF_sel_registerName("UTF8String");
    Method m = AF_class_getInstanceMethod(cls, sel);
    if (!m) return NULL;
    AF_IMP_UTF8 func = (AF_IMP_UTF8)AF_method_getImplementation(m);
    return func(nsStr, sel);
}

void AF_SendChat(id server, const char* msgC) {
    if (!server || !msgC) return;
    id nsMsg = AF_MakeString(msgC);
    Class cls = AF_objc_getClass("BHServer");
    SEL sel = AF_sel_registerName("sendChatMessage:displayNotification:sendToClients:");
    Method m = AF_class_getInstanceMethod(cls, sel);
    if (m) {
        AF_IMP_Chat f = (AF_IMP_Chat)AF_method_getImplementation(m);
        f(server, sel, nsMsg, 1, NULL);
    }
}

void AF_ExecuteCommand(id gc, const char* cmdC) {
    if (!gc || !cmdC) return;
    id nsCmd = AF_MakeString(cmdC);
    Class cls = AF_objc_getClass("GameController");
    SEL sel = AF_sel_registerName("handleCommand:issueClient:");
    Method m = AF_class_getInstanceMethod(cls, sel);
    if (m) {
        AF_IMP_Cmd f = (AF_IMP_Cmd)AF_method_getImplementation(m);
        f(gc, sel, nsCmd, NULL);
    }
}

// =============================================================
// HOOKS (Con Prefijo AF_)
// =============================================================

// Hook 1: GameController (Main Loop)
void AF_Hook_GC_Update(id self, SEL _cmd, float dt, float accDt) {
    if (AF_orig_GC_update) ((void(*)(id, SEL, float, float))AF_orig_GC_update)(self, _cmd, dt, accDt);

    static id myServer = NULL;
    if (!myServer && AF_off_bhServer) {
        myServer = *(id*)((char*)self + AF_off_bhServer);
        if (myServer) printf("[Anti-Fly] Servidor listo.\n");
    }

    if (myServer) {
        // Actualizar Cooldowns
        for(int i=0; i<AF_MAX_QUEUE; i++) {
            if(AF_cooldown_list[i].active) {
                AF_cooldown_list[i].timer -= dt;
                if(AF_cooldown_list[i].timer <= 0) AF_cooldown_list[i].active = false;
            }
        }

        // Procesar Queue
        const char* target = AF_PeekQueue();
        if (target) {
            if (!AF_warning_sent) {
                char buf[512];
                snprintf(buf, sizeof(buf), "⚠️ %s FLY is not allowed in this server. You will be kicked in 3 seconds.", target);
                AF_SendChat(myServer, buf);
                AF_kick_timer = AF_KICK_DELAY;
                AF_warning_sent = true;
            }
            else if (AF_kick_timer > 0.0f) {
                AF_kick_timer -= dt;
            }
            else {
                char cmd[512];
                snprintf(cmd, sizeof(cmd), "/kick %s", target);
                printf("[Anti-Fly] Kicking: %s\n", target);
                
                AF_ExecuteCommand(self, cmd);
                AF_AddToCooldown(target);
                AF_PopQueue();
                AF_warning_sent = false;
            }
        }
    }
}

// Hook 2: Blockhead (Detector)
void AF_Hook_BH_Update(id self, SEL _cmd, float dt, float accDt, bool isSim) {
    if (AF_orig_BH_update) ((void(*)(id, SEL, float, float, bool))AF_orig_BH_update)(self, _cmd, dt, accDt, isSim);

    if (AF_offsets_ready) {
        int trav = *(int*)((char*)self + AF_off_traverse);
        char fly = *(char*)((char*)self + AF_off_isFlying);

        if (trav == AF_TRAVERSE_FLY || fly != 0) {
            id nsName = NULL;
            if (AF_off_clientName != 0) nsName = *(id*)((char*)self + AF_off_clientName);
            const char* nameC = AF_ObjC_To_C(nsName);

            if (nameC) {
                AF_AddToQueue(nameC);
            }
        }
    }
}

// =============================================================
// LOADER
// =============================================================
void* AF_install_thread(void* arg) {
    printf("[Patch] Cargando Anti-Fly (Clean & Prefixed)...\n");
    sleep(3); // Pequeña espera para que carguen otros libs

    // Cargar Símbolos del Runtime
    AF_objc_getClass = dlsym(RTLD_DEFAULT, "objc_getClass");
    AF_sel_registerName = dlsym(RTLD_DEFAULT, "sel_registerName");
    AF_class_getInstanceMethod = dlsym(RTLD_DEFAULT, "class_getInstanceMethod");
    AF_class_getClassMethod = dlsym(RTLD_DEFAULT, "class_getClassMethod");
    AF_method_setImplementation = dlsym(RTLD_DEFAULT, "method_setImplementation");
    AF_method_getImplementation = dlsym(RTLD_DEFAULT, "method_getImplementation");
    AF_class_getInstanceVariable = dlsym(RTLD_DEFAULT, "class_getInstanceVariable");
    AF_ivar_getOffset = dlsym(RTLD_DEFAULT, "ivar_getOffset");

    // Fallback libobjc
    if (!AF_class_getClassMethod) {
        void* lib = dlopen("libobjc.so", RTLD_LAZY);
        if (lib) AF_class_getClassMethod = dlsym(lib, "class_getClassMethod");
    }

    Class clsGC = AF_objc_getClass("GameController");
    Class clsBH = AF_objc_getClass("Blockhead");

    // Hook GC
    if (clsGC) {
        Ivar iv = AF_class_getInstanceVariable(clsGC, "bhServer");
        if (iv) AF_off_bhServer = AF_ivar_getOffset(iv);
        
        Method m = AF_class_getInstanceMethod(clsGC, AF_sel_registerName("update:accurateDT:"));
        if (m) {
            AF_orig_GC_update = AF_method_getImplementation(m);
            AF_method_setImplementation(m, (AF_IMP)AF_Hook_GC_Update);
        }
    }

    // Hook BH
    if (clsBH) {
        Ivar iv1 = AF_class_getInstanceVariable(clsBH, "traverseType");
        Ivar iv2 = AF_class_getInstanceVariable(clsBH, "isInJetPackFreeFlightMode");
        Ivar ivName = AF_class_getInstanceVariable(clsBH, "_clientName");
        if (!ivName) ivName = AF_class_getInstanceVariable(clsBH, "clientName");
        
        if (iv1 && iv2 && ivName) {
            AF_off_traverse = AF_ivar_getOffset(iv1);
            AF_off_isFlying = AF_ivar_getOffset(iv2);
            AF_off_clientName = AF_ivar_getOffset(ivName);
            AF_offsets_ready = true;
            
            Method m = AF_class_getInstanceMethod(clsBH, AF_sel_registerName("update:accurateDT:isSimulation:"));
            if (m) {
                AF_orig_BH_update = AF_method_getImplementation(m);
                AF_method_setImplementation(m, (AF_IMP)AF_Hook_BH_Update);
                printf("[Anti-Fly] Sistema Activado.\n");
            }
        }
    }
    return NULL;
}

__attribute__((constructor))
void AF_init_entry() {
    pthread_t t;
    pthread_create(&t, NULL, AF_install_thread, NULL);
}
