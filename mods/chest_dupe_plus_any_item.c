/*
 * Chest Dupe + Item/Block Spawner
 * -----------------------------------------------------
 * Commands:
 * /item <ID> <QTY> <PLAYER_NAME> [force]
 * /block <ID> <QTY> <PLAYER_NAME> [force]
 * /dupe <amount>
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdbool.h>
#include <objc/runtime.h>
#include <objc/message.h>

// --- CONFIG ---
#define ISP_SERVER_CLASS  "BHServer"
#define ISP_CHEST_CLASS   "Chest"
#define ISP_TARGET_ITEM   1043

// --- TYPES (IMPs) ---
typedef id (*ISP_CmdFunc)(id, SEL, id, id);
typedef void (*ISP_ChatFunc)(id, SEL, id, BOOL, id);
typedef id (*ISP_PlaceFunc)(id, SEL, id, id, long long, id, id, unsigned char, id, id, id);
typedef id (*ISP_SpawnFunc)(id, SEL, long long, int, int, int, id, id, BOOL, BOOL, id);

// Memory & Strings
typedef id (*ISP_AllocFunc)(id, SEL);
typedef id (*ISP_InitFunc)(id, SEL);
typedef void (*ISP_ReleaseFunc)(id, SEL);
typedef id (*ISP_StrFacFunc)(id, SEL, const char*);
typedef const char* (*ISP_Utf8Func)(id, SEL);
typedef id (*ISP_GetterFunc)(id, SEL);
typedef long (*ISP_CompFunc)(id, SEL, id);
typedef int (*ISP_IntFunc)(id, SEL);
typedef void (*ISP_VoidBoolFunc)(id, SEL, BOOL);
typedef id (*ISP_IdxFunc)(id, SEL, int);

// --- GLOBALS ---
static ISP_CmdFunc   Real_ISP_HandleCmd = NULL;
static ISP_ChatFunc  Real_ISP_SendChat = NULL;
static ISP_PlaceFunc Real_ISP_ChestPlace = NULL;

static bool g_ISP_DupeEnabled = false;
static int  g_ISP_DupeCount = 1;

// --- MEMORY HELPERS (PURE IMP) ---

static id ISP_CreatePool() {
    Class cls = objc_getClass("NSAutoreleasePool");
    if (!cls) return nil;
    
    SEL sAlloc = sel_registerName("alloc");
    SEL sInit = sel_registerName("init");
    
    Method mAlloc = class_getClassMethod(cls, sAlloc);
    Method mInit = class_getInstanceMethod(cls, sInit);
    
    if (mAlloc && mInit) {
        ISP_AllocFunc fAlloc = (ISP_AllocFunc)method_getImplementation(mAlloc);
        ISP_InitFunc fInit = (ISP_InitFunc)method_getImplementation(mInit);
        if (fAlloc && fInit) {
            return fInit(fAlloc((id)cls, sAlloc), sInit);
        }
    }
    return nil;
}

static void ISP_ReleasePool(id pool) {
    if (!pool) return;
    SEL sRel = sel_registerName("release");
    Method mRel = class_getInstanceMethod(object_getClass(pool), sRel);
    if (mRel) {
        ISP_ReleaseFunc fRel = (ISP_ReleaseFunc)method_getImplementation(mRel);
        if (fRel) fRel(pool, sRel);
    }
}

static id ISP_AllocStr(const char* text) {
    if (!text) return nil;
    Class cls = objc_getClass("NSString");
    SEL sel = sel_registerName("stringWithUTF8String:");
    Method m = class_getClassMethod(cls, sel);
    if (!m) return nil;
    ISP_StrFacFunc f = (ISP_StrFacFunc)method_getImplementation(m);
    return f ? f((id)cls, sel, text) : nil;
}

static const char* ISP_GetCStr(id str) {
    if (!str) return "";
    SEL sel = sel_registerName("UTF8String");
    Method m = class_getInstanceMethod(object_getClass(str), sel);
    if (!m) return "";
    ISP_Utf8Func f = (ISP_Utf8Func)method_getImplementation(m);
    return f ? f(str, sel) : "";
}

static void ISP_SendChat(id server, const char* msg) {
    if (server && Real_ISP_SendChat) {
        Real_ISP_SendChat(server, 
                          sel_registerName("sendChatMessage:displayNotification:sendToClients:"), 
                          ISP_AllocStr(msg), 
                          true, 
                          nil);
    }
}

// --- LOGIC: FIND PLAYER (PURE IMP) ---
id ISP_FindBlockheadForPlayer(id dynWorld, const char* targetName) {
    if (!dynWorld || !targetName) return nil;
    
    Ivar iv = class_getInstanceVariable(object_getClass(dynWorld), "netBlockheads");
    if (!iv) return nil;
    
    id list = *(id*)((char*)dynWorld + ivar_getOffset(iv));
    if (!list) return nil;

    SEL sCount = sel_registerName("count");
    SEL sIdx = sel_registerName("objectAtIndex:");
    SEL sClientName = sel_registerName("clientName"); 
    SEL sComp = sel_registerName("caseInsensitiveCompare:");

    Method mCount = class_getInstanceMethod(object_getClass(list), sCount);
    Method mIdx = class_getInstanceMethod(object_getClass(list), sIdx);

    if (!mCount || !mIdx) return nil;

    ISP_IntFunc fCount = (ISP_IntFunc)method_getImplementation(mCount);
    ISP_IdxFunc fIdx = (ISP_IdxFunc)method_getImplementation(mIdx);

    int count = fCount(list, sCount);
    id targetStr = ISP_AllocStr(targetName);
    id foundBH = nil;

    for (int i = 0; i < count; i++) {
        id pool = ISP_CreatePool();
        id bh = fIdx(list, sIdx, i);
        if (bh) {
            id nsName = nil;
            // Use property getter for clientName (safer than ivar)
            Method mName = class_getInstanceMethod(object_getClass(bh), sClientName);
            if (mName) {
                ISP_GetterFunc fName = (ISP_GetterFunc)method_getImplementation(mName);
                nsName = fName(bh, sClientName);
            } else {
                Ivar ivN = class_getInstanceVariable(object_getClass(bh), "clientName");
                if (ivN) nsName = *(id*)((char*)bh + ivar_getOffset(ivN));
            }

            if (nsName) {
                Method mComp = class_getInstanceMethod(object_getClass(nsName), sComp);
                if (mComp) {
                    ISP_CompFunc fComp = (ISP_CompFunc)method_getImplementation(mComp);
                    if (fComp(nsName, sComp, targetStr) == 0) {
                        foundBH = bh; 
                    }
                }
            }
        }
        ISP_ReleasePool(pool);
        if (foundBH) break; 
    }
    return foundBH;
}

// --- LOGIC: FULL BLOCK-TO-ITEM MAP ---
int ISP_ParseBlockID(int blockID) {
    if (blockID > 255) return blockID; 
    
    // FULL List restored
    switch (blockID) {
        case 1: return 1024; // Stone
        case 2: return 0;    // Dirt (Block vs Item diff)
        case 3: return 105;  // Water
        case 4: return 1060; // Ice
        case 6: return 1048; // Dirt item
        case 7: return 1051; // Sand
        case 9: return 1049; // Wood
        case 11: return 1026; // Red Brick
        case 12: return 1027; // Limestone
        case 14: return 1029; // Marble
        case 16: return 11;   // Time Crystal
        case 17: return 1035; // Sandstone
        case 19: return 1037; // Red Marble
        case 24: return 1042; // Glass
        case 25: return 134;  // Portal Base
        case 26: return 1045; // North Pole
        case 29: return 1053; // Lapis
        case 32: return 1057; // Wooden Platform
        case 48: return 1062; // Compost
        case 51: return 1063; // Basalt
        case 53: return 1066; // Copper Block
        case 54: return 1067; // Tin Block
        case 55: return 1068; // Bronze Block
        case 56: return 1069; // Iron Block
        case 57: return 1070; // Steel Block
        case 59: return 1076; // Black Glass
        case 60: return 210;  // Trade Portal
        case 67: return 1089; // Platinum Block
        case 68: return 1090; // Titanium Block
        case 69: return 1091; // Carbon Fiber Block
        case 70: return 1092; // Gravel
        default: return blockID;
    }
}

void ISP_Spawn(id dynWorld, id player, int idVal, int qty, id saveDict) {
    if (!player) return;
    
    Ivar ivP = class_getInstanceVariable(object_getClass(player), "pos");
    if (!ivP) return;
    
    long long pos = *(long long*)((char*)player + ivar_getOffset(ivP));
    if (pos == 0) return;

    SEL sel = sel_registerName("createFreeBlockAtPosition:ofType:dataA:dataB:subItems:dynamicObjectSaveDict:hovers:playSound:priorityBlockhead:");
    Method mSpawn = class_getInstanceMethod(object_getClass(dynWorld), sel);
    if (mSpawn) {
        ISP_SpawnFunc f = (ISP_SpawnFunc)method_getImplementation(mSpawn);
        for(int i=0; i<qty; i++) {
            f(dynWorld, sel, pos, idVal, 1, 0, nil, saveDict, 1, 0, player);
        }
    }
}

// --- HOOKS ---

id Hook_ISP_ChestPlace(id self, SEL _cmd, id w, id dw, long long pos, id cache, id item, unsigned char flip, id save, id client, id cName) {
    id ret = Real_ISP_ChestPlace(self, _cmd, w, dw, pos, cache, item, flip, save, client, cName);
    
    if (g_ISP_DupeEnabled && ret && item) {
        SEL sType = sel_registerName("itemType");
        Method mType = class_getInstanceMethod(object_getClass(item), sType);
        ISP_IntFunc fType = mType ? (ISP_IntFunc)method_getImplementation(mType) : NULL;
        int type = fType ? fType(item, sType) : 0;

        if (type == ISP_TARGET_ITEM) {
            const char* name = ISP_GetCStr(cName);
            id pool = ISP_CreatePool();
            
            // Search by Client Name
            id player = ISP_FindBlockheadForPlayer(dw, name);
            
            if (player) {
                // Refund Original (1) + Add Copies (g_ISP_DupeCount)
                ISP_Spawn(dw, player, ISP_TARGET_ITEM, 1 + g_ISP_DupeCount, save);
                
                // Remove placed item immediately
                SEL sRem = sel_registerName("remove:");
                Method mRem = class_getInstanceMethod(object_getClass(ret), sRem);
                if (mRem) {
                    ISP_VoidBoolFunc fRem = (ISP_VoidBoolFunc)method_getImplementation(mRem);
                    fRem(ret, sRem, 1);
                }
            }
            ISP_ReleasePool(pool);
        }
    }
    return ret;
}

id Hook_ISP_Cmd(id self, SEL _cmd, id cmdStr, id client) {
    const char* raw = ISP_GetCStr(cmdStr);
    if (!raw || strlen(raw) == 0) return Real_ISP_HandleCmd(self, _cmd, cmdStr, client);

    id pool = ISP_CreatePool();
    char buffer[256]; 
    strncpy(buffer, raw, 255); 
    buffer[255] = 0;
    
    bool isItem  = (strncmp(buffer, "/item", 5) == 0);
    bool isBlock = (strncmp(buffer, "/block", 6) == 0);
    bool isDupe  = (strncmp(buffer, "/dupe", 5) == 0);

    if (!isItem && !isBlock && !isDupe) {
        ISP_ReleasePool(pool);
        return Real_ISP_HandleCmd(self, _cmd, cmdStr, client);
    }

    id world = nil;
    Ivar ivW = class_getInstanceVariable(object_getClass(self), "world");
    if (ivW) world = *(id*)((char*)self + ivar_getOffset(ivW));

    id dynWorld = nil;
    if (world) {
        Ivar ivD = class_getInstanceVariable(object_getClass(world), "dynamicWorld");
        if (ivD) dynWorld = *(id*)((char*)world + ivar_getOffset(ivD));
    }

    if (!dynWorld) {
        ISP_SendChat(self, "[Error] World not initialized.");
        ISP_ReleasePool(pool);
        return nil;
    }

    // --- DUPE ---
    if (isDupe) {
        char *saveptr;
        strtok_r(buffer, " ", &saveptr);
        char* arg1 = strtok_r(NULL, " ", &saveptr);
        
        if (!arg1) {
            g_ISP_DupeEnabled = !g_ISP_DupeEnabled;
            if (g_ISP_DupeEnabled) g_ISP_DupeCount = 1;
        } else {
            g_ISP_DupeEnabled = true;
            g_ISP_DupeCount = atoi(arg1);
            if (g_ISP_DupeCount < 1) g_ISP_DupeCount = 1;
            if (g_ISP_DupeCount > 5) g_ISP_DupeCount = 5;
        }

        char msg[128];
        snprintf(msg, 128, "[Dupe] %s. (Original + %d copies)", g_ISP_DupeEnabled ? "ON" : "OFF", g_ISP_DupeCount);
        ISP_SendChat(self, msg);
        ISP_ReleasePool(pool);
        return nil;
    }

    // --- ITEM/BLOCK ---
    char *saveptr;
    strtok_r(buffer, " ", &saveptr);
    char *sID = strtok_r(NULL, " ", &saveptr);
    char *sQty = strtok_r(NULL, " ", &saveptr);
    char *sPlayer = strtok_r(NULL, " ", &saveptr); 
    char *sForce = strtok_r(NULL, " ", &saveptr);

    if (!sID || !sPlayer) {
        ISP_SendChat(self, "[Usage] /item <ID> <QTY> <CLIENT_NAME> [force]");
        ISP_ReleasePool(pool);
        return nil;
    }

    // Find Player
    id targetBH = ISP_FindBlockheadForPlayer(dynWorld, sPlayer);
    
    if (!targetBH) {
        char err[128];
        snprintf(err, 128, "[Error] Client '%s' not found.", sPlayer);
        ISP_SendChat(self, err);
        ISP_ReleasePool(pool);
        return nil;
    }

    int qty = sQty ? atoi(sQty) : 1;
    if (qty < 1) qty = 1;
    bool force = (sForce && strcasecmp(sForce, "force") == 0);
    
    if (!force && qty > 99) {
        qty = 99;
        ISP_SendChat(self, "[Warn] Capped at 99. Use 'force' to override.");
    }

    int itemID = atoi(sID);
    if (isBlock) itemID = ISP_ParseBlockID(itemID);
    
    ISP_Spawn(dynWorld, targetBH, itemID, qty, nil);
    
    char successMsg[128];
    snprintf(successMsg, 128, "[System] Gave %d x (ID: %d) to %s.", qty, itemID, sPlayer);
    ISP_SendChat(self, successMsg);

    ISP_ReleasePool(pool);
    return nil;
}

static void* ISP_InitThread(void* arg) {
    sleep(1);
    Class clsServer = objc_getClass(ISP_SERVER_CLASS);
    if (clsServer) {
        Method mC = class_getInstanceMethod(clsServer, sel_registerName("handleCommand:issueClient:"));
        Real_ISP_HandleCmd = (ISP_CmdFunc)method_getImplementation(mC);
        method_setImplementation(mC, (IMP)Hook_ISP_Cmd);
        
        Method mT = class_getInstanceMethod(clsServer, sel_registerName("sendChatMessage:displayNotification:sendToClients:"));
        Real_ISP_SendChat = (ISP_ChatFunc)method_getImplementation(mT);
    }

    Class clsChest = objc_getClass(ISP_CHEST_CLASS);
    if (clsChest) {
        Method mP = class_getInstanceMethod(clsChest, sel_registerName("initWithWorld:dynamicWorld:atPosition:cache:item:flipped:saveDict:placedByClient:clientName:"));
        Real_ISP_ChestPlace = (ISP_PlaceFunc)method_getImplementation(mP);
        method_setImplementation(mP, (IMP)Hook_ISP_ChestPlace);
    }
    return NULL;
}

__attribute__((constructor)) static void ISP_Entry() {
    pthread_t t; 
    pthread_create(&t, NULL, ISP_InitThread, NULL);
}
