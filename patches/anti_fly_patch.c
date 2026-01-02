//Commands: /antifly status /antifly (Will turn ON or OFF automatically)

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <dlfcn.h>
#include <unistd.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <stddef.h>
#include <strings.h> 
#include <pthread.h>

// --- CONFIGURATION ---
#define ZAF_GRACE_TIME 5.0f    // 5 Seconds immunity upon entry
#define ZAF_KICK_COOLDOWN 2.0f // Log spam prevention
#define ZAF_MAX_PLAYERS 64     // Max concurrent players to track

// --- GLOBAL STATE ---
static bool ZAF_Enabled = true;

// --- TYPES ---
typedef void* id;
typedef void* SEL;
typedef void* Class;
typedef void* Method;
typedef void* Ivar;
typedef void (*ZAF_IMP)(id, SEL, ...);

// Method Signatures
typedef void (*ZAF_IMP_Boot)(id, SEL, id, bool); 
typedef id (*ZAF_IMP_Str)(id, SEL);
typedef id (*ZAF_IMP_MakeStr)(Class, SEL, const char*);
typedef bool (*ZAF_IMP_Bool)(id, SEL); 
typedef bool (*ZAF_IMP_IsAdmin)(id, SEL, id); 
typedef void (*ZAF_IMP_Chat)(id, SEL, id, bool, id);
typedef int (*ZAF_IMP_Int)(id, SEL);
typedef const char* (*ZAF_IMP_UTF8)(id, SEL);
typedef void (*ZAF_IMP_Cmd)(id, SEL, id, id);

// --- RUNTIME POINTERS ---
static Class (*ZAF_objc_getClass)(const char *name);
static SEL (*ZAF_sel_registerName)(const char *name);
static Method (*ZAF_class_getInstanceMethod)(Class cls, SEL name);
static Method (*ZAF_class_getClassMethod)(Class cls, SEL name);
static ZAF_IMP (*ZAF_method_setImplementation)(Method m, ZAF_IMP imp);
static ZAF_IMP (*ZAF_method_getImplementation)(Method m);
static Ivar (*ZAF_class_getInstanceVariable)(Class cls, const char *name);
static ptrdiff_t (*ZAF_ivar_getOffset)(Ivar v);

// --- HOOK VARIABLES ---
static ZAF_IMP ZAF_orig_GC_update = NULL;
static ZAF_IMP ZAF_orig_BH_update = NULL;
static ZAF_IMP ZAF_orig_Srv_HandleCmd = NULL;

static id ZAF_Global_BHServer = NULL;

static SEL ZAF_Sel_HasJet = NULL;
static SEL ZAF_Sel_CanFly = NULL;
static SEL ZAF_Sel_Trav = NULL;
static SEL ZAF_Sel_ClientID = NULL;
static SEL ZAF_Sel_Boot = NULL;
static SEL ZAF_Sel_UTF8 = NULL;
static SEL ZAF_Sel_IsAdmin = NULL;
static SEL ZAF_Sel_SendChat = NULL;

static ZAF_IMP_Bool    ZAF_Func_HasJet = NULL;
static ZAF_IMP_Bool    ZAF_Func_CanFly = NULL;
static ZAF_IMP_Int     ZAF_Func_Trav = NULL;
static ZAF_IMP_Str     ZAF_Func_ClientID = NULL;
static ZAF_IMP_Boot    ZAF_Func_Boot = NULL;
static ZAF_IMP_UTF8    ZAF_Func_UTF8 = NULL;
static ZAF_IMP_IsAdmin ZAF_Func_IsAdmin = NULL;
static ZAF_IMP_Chat    ZAF_Func_SendChat = NULL;
static ZAF_IMP_MakeStr ZAF_Func_MakeStr = NULL;

static ptrdiff_t ZAF_off_bhServer = 0;
static bool ZAF_ready = false;

// --- PLAYER TRACKING STRUCT ---
typedef struct {
    char idStr[64];
    float grace_timer;
    float kick_cooldown;
    float seen_timer;
    bool active;
} ZAF_PlayerInfo;

static ZAF_PlayerInfo ZAF_tracker[ZAF_MAX_PLAYERS];

// Get or Create Player Entry
static ZAF_PlayerInfo* ZAF_GetPlayer(const char* idStr) {
    // 1. Find existing
    for (int i = 0; i < ZAF_MAX_PLAYERS; i++) {
        if (ZAF_tracker[i].active && strcmp(ZAF_tracker[i].idStr, idStr) == 0) {
            ZAF_tracker[i].seen_timer = 0.0f;
            return &ZAF_tracker[i];
        }
    }
    // 2. Create new (New join = New Grace Period)
    for (int i = 0; i < ZAF_MAX_PLAYERS; i++) {
        if (!ZAF_tracker[i].active) {
            strncpy(ZAF_tracker[i].idStr, idStr, 63);
            ZAF_tracker[i].grace_timer = ZAF_GRACE_TIME;
            ZAF_tracker[i].kick_cooldown = 0.0f;
            ZAF_tracker[i].seen_timer = 0.0f;
            ZAF_tracker[i].active = true;
            printf("[Anti-Fly] New Player Detected: %s (Grace: %.1fs)\n", idStr, ZAF_GRACE_TIME);
            return &ZAF_tracker[i];
        }
    }
    // Fallback slot
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

static id ZAF_C_To_ObjC(const char* str) {
    if (!str) return NULL;
    Class cls = ZAF_objc_getClass("NSString");
    SEL sel = ZAF_sel_registerName("stringWithUTF8String:");
    return ZAF_Func_MakeStr(cls, sel, str);
}

static void ZAF_SendSystemMsg(const char* msg) {
    if (ZAF_Global_BHServer && ZAF_Func_SendChat) {
        id nsMsg = ZAF_C_To_ObjC(msg);
        ZAF_Func_SendChat(ZAF_Global_BHServer, ZAF_Sel_SendChat, nsMsg, true, NULL);
    }
}

// =============================================================
// HOOKS
// =============================================================

// HOOK COMMANDS: Intercepts /antifly on BHServer
static void ZAF_Hook_Srv_HandleCmd(id self, SEL _cmd, id command, id issueClient) {
    const char* cmdStr = ZAF_ObjC_To_C(command);
    
    if (cmdStr && strncasecmp(cmdStr, "/antifly", 8) == 0) {
        
        if (strncasecmp(cmdStr, "/antifly off", 12) == 0) {
            ZAF_Enabled = false;
            printf("[Anti-Fly] System disabled via command.\n");
            ZAF_SendSystemMsg("[Anti-Fly] System: DISABLED");
        } 
        else if (strncasecmp(cmdStr, "/antifly on", 11) == 0) {
            ZAF_Enabled = true;
            printf("[Anti-Fly] System enabled via command.\n");
            ZAF_SendSystemMsg("[Anti-Fly] System: ENABLED");
        }
        else {
            if (ZAF_Enabled) ZAF_SendSystemMsg("[Anti-Fly] Status: ACTIVE");
            else ZAF_SendSystemMsg("[Anti-Fly] Status: INACTIVE");
        }
        
        return; // Prevent "Unknown Command"
    }

    if (ZAF_orig_Srv_HandleCmd) ((ZAF_IMP_Cmd)ZAF_orig_Srv_HandleCmd)(self, _cmd, command, issueClient);
}

// HOOK UPDATE GLOBAL: Manages player tracking & cleanup
static void ZAF_Hook_GC_Update(id self, SEL _cmd, float dt, float accDt) {
    if (ZAF_orig_GC_update) ((void(*)(id, SEL, float, float))ZAF_orig_GC_update)(self, _cmd, dt, accDt);

    if (!ZAF_Global_BHServer && ZAF_off_bhServer != 0) {
        ZAF_Global_BHServer = *(id*)((char*)self + ZAF_off_bhServer);
        if (ZAF_Global_BHServer) printf("[Anti-Fly] Server Core Hooked.\n");
    }

    // Cleanup disconnected players
    for (int i = 0; i < ZAF_MAX_PLAYERS; i++) {
        if (ZAF_tracker[i].active) {
            ZAF_tracker[i].seen_timer += dt;
            if (ZAF_tracker[i].seen_timer > 10.0f) {
                ZAF_tracker[i].active = false; 
            }
        }
    }
}

// HOOK BLOCKHEAD: Detection Logic
static void ZAF_Hook_BH_Update(id self, SEL _cmd, float dt, float accDt, bool isSim) {
    if (ZAF_orig_BH_update) ((void(*)(id, SEL, float, float, bool))ZAF_orig_BH_update)(self, _cmd, dt, accDt, isSim);

    if (!ZAF_Enabled) return;

    if (ZAF_ready && ZAF_Global_BHServer) {
        
        id nsID = NULL;
        if (ZAF_Func_ClientID) nsID = ZAF_Func_ClientID(self, ZAF_Sel_ClientID);
        
        if (nsID) {
            const char* strID = ZAF_ObjC_To_C(nsID);
            if (strID) {
                
                // 1. ADMIN CHECK
                if (ZAF_Func_IsAdmin) {
                    bool isAdmin = ZAF_Func_IsAdmin(ZAF_Global_BHServer, ZAF_Sel_IsAdmin, nsID);
                    if (isAdmin) return; // Ignore admins
                }

                ZAF_PlayerInfo* player = ZAF_GetPlayer(strID);

                // Update Timers
                if (player->grace_timer > 0.0f) player->grace_timer -= dt;
                if (player->kick_cooldown > 0.0f) player->kick_cooldown -= dt;

                // Detection Logic
                bool detected = false;
                if (ZAF_Func_Trav) {
                    int trav = ZAF_Func_Trav(self, ZAF_Sel_Trav);
                    if (trav == 28) detected = true; // Flying Mode
                }
                if (!detected && ZAF_Func_CanFly && ZAF_Func_CanFly(self, ZAF_Sel_CanFly)) detected = true;
                if (!detected && ZAF_Func_HasJet && ZAF_Func_HasJet(self, ZAF_Sel_HasJet)) detected = true;

                // Action
                if (detected) {
                    if (player->grace_timer > 0.0f) return; // Allow grace period

                    if (player->kick_cooldown <= 0.0f) {
                        printf("[Anti-Fly] Kicking ID: %s (Illegal Flight/Item)\n", strID);
                        ZAF_Func_Boot(ZAF_Global_BHServer, ZAF_Sel_Boot, nsID, false);
                        player->kick_cooldown = 2.0f;
                    }
                }
            }
        }
    }
}

// =============================================================
// LOADER & INITIALIZATION
// =============================================================
static void* ZAF_install_thread(void* arg) {
    sleep(2);
    printf("[Anti-Fly] Loading Blockheads Anti-Fly v1.0...\n");

    ZAF_objc_getClass = dlsym(RTLD_DEFAULT, "objc_getClass");
    ZAF_sel_registerName = dlsym(RTLD_DEFAULT, "sel_registerName");
    ZAF_class_getInstanceMethod = dlsym(RTLD_DEFAULT, "class_getInstanceMethod");
    ZAF_class_getClassMethod = dlsym(RTLD_DEFAULT, "class_getClassMethod");
    ZAF_method_setImplementation = dlsym(RTLD_DEFAULT, "method_setImplementation");
    ZAF_method_getImplementation = dlsym(RTLD_DEFAULT, "method_getImplementation");
    ZAF_class_getInstanceVariable = dlsym(RTLD_DEFAULT, "class_getInstanceVariable");
    ZAF_ivar_getOffset = dlsym(RTLD_DEFAULT, "ivar_getOffset");

    Class clsGC = ZAF_objc_getClass("GameController");
    Class clsBH = ZAF_objc_getClass("Blockhead");
    Class clsSrv = ZAF_objc_getClass("BHServer");
    Class clsStr = ZAF_objc_getClass("NSString");

    if (clsStr) {
        ZAF_Sel_UTF8 = ZAF_sel_registerName("UTF8String");
        Method mUTF8 = ZAF_class_getInstanceMethod(clsStr, ZAF_Sel_UTF8);
        if (mUTF8) ZAF_Func_UTF8 = (ZAF_IMP_UTF8)ZAF_method_getImplementation(mUTF8);

        SEL selMake = ZAF_sel_registerName("stringWithUTF8String:");
        Method mMake = ZAF_class_getClassMethod(clsStr, selMake);
        if (mMake) ZAF_Func_MakeStr = (ZAF_IMP_MakeStr)ZAF_method_getImplementation(mMake);
    }

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
        // Boot Player
        ZAF_Sel_Boot = ZAF_sel_registerName("bootPlayer:wasBan:");
        Method mBoot = ZAF_class_getInstanceMethod(clsSrv, ZAF_Sel_Boot);
        if (mBoot) ZAF_Func_Boot = (ZAF_IMP_Boot)ZAF_method_getImplementation(mBoot);

        // Check Admin
        ZAF_Sel_IsAdmin = ZAF_sel_registerName("playerIsAdminWithID:");
        Method mAdm = ZAF_class_getInstanceMethod(clsSrv, ZAF_Sel_IsAdmin);
        if (mAdm) ZAF_Func_IsAdmin = (ZAF_IMP_IsAdmin)ZAF_method_getImplementation(mAdm);

        // Chat
        ZAF_Sel_SendChat = ZAF_sel_registerName("sendChatMessage:displayNotification:sendToClients:");
        Method mChat = ZAF_class_getInstanceMethod(clsSrv, ZAF_Sel_SendChat);
        if (mChat) ZAF_Func_SendChat = (ZAF_IMP_Chat)ZAF_method_getImplementation(mChat);

        // Command Hook
        Method mCmd = ZAF_class_getInstanceMethod(clsSrv, ZAF_sel_registerName("handleCommand:issueClient:"));
        if (mCmd) {
            ZAF_orig_Srv_HandleCmd = ZAF_method_getImplementation(mCmd);
            ZAF_method_setImplementation(mCmd, (ZAF_IMP)ZAF_Hook_Srv_HandleCmd);
            printf("[Anti-Fly] In-Game Command Hook Active.\n");
        }
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
            printf("[Anti-Fly] v1.0 Ready. Waiting for players.\n");
        }
    }

    return NULL;
}

__attribute__((constructor))
void ZAF_init_entry() {
    pthread_t t;
    pthread_create(&t, NULL, ZAF_install_thread, NULL);
}
