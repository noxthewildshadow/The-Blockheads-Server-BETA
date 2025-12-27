#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <dlfcn.h>
#include <unistd.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <stddef.h>
#include <pthread.h>

// --- CONFIGURACIÓN ---
#define ZAF_GRACE_TIME 3.0f
#define ZAF_KICK_COOLDOWN 2.0f
#define ZAF_MAX_PLAYERS 64

// --- TIPOS ---
typedef void* id;
typedef void* SEL;
typedef void* Class;
typedef void* Method;
typedef void* Ivar;
typedef void (*ZAF_IMP)(id, SEL, ...);

// Firmas
typedef void (*ZAF_IMP_Boot)(id, SEL, id, bool); 
typedef id (*ZAF_IMP_Str)(id, SEL);
typedef bool (*ZAF_IMP_Bool)(id, SEL); 
typedef int (*ZAF_IMP_Int)(id, SEL);
typedef const char* (*ZAF_IMP_UTF8)(id, SEL);

// --- RUNTIME ---
static Class (*ZAF_objc_getClass)(const char *name);
static SEL (*ZAF_sel_registerName)(const char *name);
static Method (*ZAF_class_getInstanceMethod)(Class cls, SEL name);
static ZAF_IMP (*ZAF_method_setImplementation)(Method m, ZAF_IMP imp);
static ZAF_IMP (*ZAF_method_getImplementation)(Method m);
static Ivar (*ZAF_class_getInstanceVariable)(Class cls, const char *name);
static ptrdiff_t (*ZAF_ivar_getOffset)(Ivar v);

// --- GLOBALES ---
static ZAF_IMP ZAF_orig_GC_update = NULL;
static ZAF_IMP ZAF_orig_BH_update = NULL;

static id ZAF_Global_BHServer = NULL;

static SEL ZAF_Sel_HasJet = NULL;
static SEL ZAF_Sel_CanFly = NULL;
static SEL ZAF_Sel_Trav = NULL;
static SEL ZAF_Sel_ClientID = NULL;
static SEL ZAF_Sel_Boot = NULL;
static SEL ZAF_Sel_UTF8 = NULL;

static ZAF_IMP_Bool ZAF_Func_HasJet = NULL;
static ZAF_IMP_Bool ZAF_Func_CanFly = NULL;
static ZAF_IMP_Int  ZAF_Func_Trav = NULL;
static ZAF_IMP_Str  ZAF_Func_ClientID = NULL;
static ZAF_IMP_Boot ZAF_Func_Boot = NULL;
static ZAF_IMP_UTF8 ZAF_Func_UTF8 = NULL;

static ptrdiff_t ZAF_off_bhServer = 0;
static bool ZAF_ready = false;

// --- GESTIÓN DE JUGADORES ---
typedef struct {
    char idStr[64];
    float grace_timer;
    float kick_cooldown;
    float seen_timer;
    bool active;
} ZAF_PlayerInfo;

static ZAF_PlayerInfo ZAF_tracker[ZAF_MAX_PLAYERS];

static ZAF_PlayerInfo* ZAF_GetPlayer(const char* idStr) {
    for (int i = 0; i < ZAF_MAX_PLAYERS; i++) {
        if (ZAF_tracker[i].active && strcmp(ZAF_tracker[i].idStr, idStr) == 0) {
            ZAF_tracker[i].seen_timer = 0.0f;
            return &ZAF_tracker[i];
        }
    }
    for (int i = 0; i < ZAF_MAX_PLAYERS; i++) {
        if (!ZAF_tracker[i].active) {
            strncpy(ZAF_tracker[i].idStr, idStr, 63);
            ZAF_tracker[i].grace_timer = ZAF_GRACE_TIME;
            ZAF_tracker[i].kick_cooldown = 0.0f;
            ZAF_tracker[i].seen_timer = 0.0f;
            ZAF_tracker[i].active = true;
            return &ZAF_tracker[i];
        }
    }
    return &ZAF_tracker[0];
}

// --- HELPERS ---
static const char* ZAF_ObjC_To_C(id nsStr) {
    if (!nsStr) return NULL;
    Class cls = ZAF_objc_getClass("NSString");
    SEL sel = ZAF_sel_registerName("UTF8String");
    ZAF_IMP_UTF8 func = (ZAF_IMP_UTF8)ZAF_method_getImplementation(ZAF_class_getInstanceMethod(cls, sel));
    return func(nsStr, sel);
}

// =============================================================
// HOOKS
// =============================================================

static void ZAF_Hook_GC_Update(id self, SEL _cmd, float dt, float accDt) {
    if (ZAF_orig_GC_update) ((void(*)(id, SEL, float, float))ZAF_orig_GC_update)(self, _cmd, dt, accDt);

    if (!ZAF_Global_BHServer && ZAF_off_bhServer != 0) {
        ZAF_Global_BHServer = *(id*)((char*)self + ZAF_off_bhServer);
        if (ZAF_Global_BHServer) printf("[ZAF] Core System Active.\n");
    }

    for (int i = 0; i < ZAF_MAX_PLAYERS; i++) {
        if (ZAF_tracker[i].active) {
            ZAF_tracker[i].seen_timer += dt;
            if (ZAF_tracker[i].seen_timer > 10.0f) {
                ZAF_tracker[i].active = false; 
            }
        }
    }
}

static void ZAF_Hook_BH_Update(id self, SEL _cmd, float dt, float accDt, bool isSim) {
    if (ZAF_orig_BH_update) ((void(*)(id, SEL, float, float, bool))ZAF_orig_BH_update)(self, _cmd, dt, accDt, isSim);

    if (ZAF_ready && ZAF_Global_BHServer) {
        
        id nsID = NULL;
        if (ZAF_Func_ClientID) nsID = ZAF_Func_ClientID(self, ZAF_Sel_ClientID);
        
        if (nsID) {
            const char* strID = ZAF_ObjC_To_C(nsID);
            if (strID) {
                ZAF_PlayerInfo* player = ZAF_GetPlayer(strID);

                if (player->grace_timer > 0.0f) player->grace_timer -= dt;
                if (player->kick_cooldown > 0.0f) player->kick_cooldown -= dt;

                bool detected = false;
                
                if (ZAF_Func_Trav) {
                    int trav = ZAF_Func_Trav(self, ZAF_Sel_Trav);
                    if (trav == 28) detected = true; 
                }
                if (!detected && ZAF_Func_CanFly && ZAF_Func_CanFly(self, ZAF_Sel_CanFly)) detected = true;
                if (!detected && ZAF_Func_HasJet && ZAF_Func_HasJet(self, ZAF_Sel_HasJet)) detected = true;

                if (detected) {
                    if (player->grace_timer > 0.0f) return; 

                    if (player->kick_cooldown <= 0.0f) {
                        printf("[ZAF] Kicking ID: %s (Illegal Flight/Item)\n", strID);
                        ZAF_Func_Boot(ZAF_Global_BHServer, ZAF_Sel_Boot, nsID, false);
                        player->kick_cooldown = 2.0f;
                    }
                }
            }
        }
    }
}

// =============================================================
// LOADER
// =============================================================
static void* ZAF_install_thread(void* arg) {
    sleep(2);
    printf("[ZAF] Loading Anti-Fly Module...\n");

    ZAF_objc_getClass = dlsym(RTLD_DEFAULT, "objc_getClass");
    ZAF_sel_registerName = dlsym(RTLD_DEFAULT, "sel_registerName");
    ZAF_class_getInstanceMethod = dlsym(RTLD_DEFAULT, "class_getInstanceMethod");
    ZAF_method_setImplementation = dlsym(RTLD_DEFAULT, "method_setImplementation");
    ZAF_method_getImplementation = dlsym(RTLD_DEFAULT, "method_getImplementation");
    ZAF_class_getInstanceVariable = dlsym(RTLD_DEFAULT, "class_getInstanceVariable");
    ZAF_ivar_getOffset = dlsym(RTLD_DEFAULT, "ivar_getOffset");

    Class clsGC = ZAF_objc_getClass("GameController");
    Class clsBH = ZAF_objc_getClass("Blockhead");
    Class clsSrv = ZAF_objc_getClass("BHServer");
    Class clsStr = ZAF_objc_getClass("NSString");

    if (clsGC) {
        Ivar iv = ZAF_class_getInstanceVariable(clsGC, "bhServer");
        if (iv) ZAF_off_bhServer = ZAF_ivar_getOffset(iv);
        
        Method m = ZAF_class_getInstanceMethod(clsGC, ZAF_sel_registerName("update:accurateDT:"));
        if (m) {
            ZAF_orig_GC_update = ZAF_method_getImplementation(m);
            ZAF_method_setImplementation(m, (ZAF_IMP)ZAF_Hook_GC_Update);
        }
    }

    if (clsSrv) {
        ZAF_Sel_Boot = ZAF_sel_registerName("bootPlayer:wasBan:");
        Method mBoot = ZAF_class_getInstanceMethod(clsSrv, ZAF_Sel_Boot);
        if (mBoot) ZAF_Func_Boot = (ZAF_IMP_Boot)ZAF_method_getImplementation(mBoot);
    }

    if (clsStr) {
        ZAF_Sel_UTF8 = ZAF_sel_registerName("UTF8String");
        Method mUTF8 = ZAF_class_getInstanceMethod(clsStr, ZAF_Sel_UTF8);
        if (mUTF8) ZAF_Func_UTF8 = (ZAF_IMP_UTF8)ZAF_method_getImplementation(mUTF8);
    }

    if (clsBH) {
        ZAF_Sel_ClientID = ZAF_sel_registerName("clientID");
        Method mID = ZAF_class_getInstanceMethod(clsBH, ZAF_Sel_ClientID);
        if (mID) ZAF_Func_ClientID = (ZAF_IMP_Str)ZAF_method_getImplementation(mID);

        ZAF_Sel_HasJet = ZAF_sel_registerName("hasJetPackEquipped");
        Method mHas = ZAF_class_getInstanceMethod(clsBH, ZAF_Sel_HasJet);
        if (mHas) ZAF_Func_HasJet = (ZAF_IMP_Bool)ZAF_method_getImplementation(mHas);

        ZAF_Sel_CanFly = ZAF_sel_registerName("canFly");
        Method mFly = ZAF_class_getInstanceMethod(clsBH, ZAF_Sel_CanFly);
        if (mFly) ZAF_Func_CanFly = (ZAF_IMP_Bool)ZAF_method_getImplementation(mFly);

        ZAF_Sel_Trav = ZAF_sel_registerName("traverseType");
        Method mTrav = ZAF_class_getInstanceMethod(clsBH, ZAF_Sel_Trav);
        if (mTrav) ZAF_Func_Trav = (ZAF_IMP_Int)ZAF_method_getImplementation(mTrav);

        Method mUpd = ZAF_class_getInstanceMethod(clsBH, ZAF_sel_registerName("update:accurateDT:isSimulation:"));
        if (mUpd) {
            ZAF_orig_BH_update = ZAF_method_getImplementation(mUpd);
            ZAF_method_setImplementation(mUpd, (ZAF_IMP)ZAF_Hook_BH_Update);
            ZAF_ready = true;
        }
    }

    return NULL;
}

__attribute__((constructor))
void ZAF_init_entry() {
    pthread_t t;
    pthread_create(&t, NULL, ZAF_install_thread, NULL);
}
