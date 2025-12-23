/*
 * Chest Dupe + Any Item
 * -----------------------------------------------------
 * Commands:
 * /item <ID> <QTY> <PLAYER> [force]
 * /block <ID> <QTY> <PLAYER> [force]
 * /dupe [count]
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

// --- STRUCTS (Based on Headers) ---
// intpair is implicitly two ints. On 64-bit systems, this aligns with long long.
typedef struct {
    int x;
    int y;
} IntPair;

// --- CONSTANTS & SELECTORS ---
#define SERVER_CLASS  "BHServer"
#define CHEST_CLASS   "Chest"
#define TARGET_ITEM   1043

#define SEL_CMD       "handleCommand:issueClient:"
#define SEL_CHAT      "sendChatMessage:sendToClients:"
#define SEL_UTF8      "UTF8String"
#define SEL_STR       "stringWithUTF8String:"
#define SEL_COUNT     "count"
#define SEL_OBJ_IDX   "objectAtIndex:"
#define SEL_COMPARE   "caseInsensitiveCompare:"
// createFreeBlockAtPosition expects intpair (struct), usually passed as registers in ARM64 matching long long signature
#define SEL_SPAWN     "createFreeBlockAtPosition:ofType:dataA:dataB:subItems:dynamicObjectSaveDict:hovers:playSound:priorityBlockhead:"
#define SEL_PLACE     "initWithWorld:dynamicWorld:atPosition:cache:item:flipped:saveDict:placedByClient:clientName:"
#define SEL_REMOVE    "remove:"
#define SEL_TYPE      "itemType"
#define SEL_ALLOC     "alloc"
#define SEL_INIT      "init"
#define SEL_RELEASE   "release"

// --- TYPES ---
typedef id (*CmdFunc)(id, SEL, id, id);
typedef void (*ChatFunc)(id, SEL, id, id);
typedef id (*PlaceFunc)(id, SEL, id, id, long long, id, id, unsigned char, id, id, id);
typedef id (*SpawnItemFunc)(id, SEL, IntPair, int, int, int, id, id, BOOL, BOOL, id); // Updated to IntPair
typedef long (*CompareFunc)(id, SEL, id);
typedef id (*StrFactoryFunc)(id, SEL, const char*);
typedef id (*ListFunc)(id, SEL);
typedef int (*CountFunc)(id, SEL);
typedef id (*ObjIdxFunc)(id, SEL, unsigned long);
typedef const char* (*UTF8Func)(id, SEL);
typedef int (*IntFunc)(id, SEL);
typedef void (*VoidBoolFunc)(id, SEL, BOOL);
typedef id (*AllocFunc)(id, SEL);
typedef id (*InitFunc)(id, SEL);
typedef void (*ReleaseFunc)(id, SEL);

// --- GLOBALS ---
static CmdFunc    Freight_Real_HandleCmd = NULL;
static ChatFunc   Freight_Real_SendChat = NULL;
static PlaceFunc  Freight_Real_ChestPlace = NULL;

static bool g_FreightDupeEnabled = false;
static int  g_FreightDupeCount = 1;

// --- HELPERS ---
id Freight_CreatePool() {
    Class cls = objc_getClass("NSAutoreleasePool");
    if (!cls) return nil;
    SEL sAlloc = sel_registerName(SEL_ALLOC);
    SEL sInit = sel_registerName(SEL_INIT);
    Method mAlloc = class_getClassMethod(cls, sAlloc);
    AllocFunc fAlloc = (AllocFunc)method_getImplementation(mAlloc);
    Method mInit = class_getInstanceMethod(cls, sInit);
    InitFunc fInit = (InitFunc)method_getImplementation(mInit);
    if (fAlloc && fInit) {
        id obj = fAlloc((id)cls, sAlloc);
        return fInit(obj, sInit);
    }
    return nil;
}

void Freight_Release(id obj) {
    if (!obj) return;
    SEL sRel = sel_registerName(SEL_RELEASE);
    Method mRel = class_getInstanceMethod(object_getClass(obj), sRel);
    ReleaseFunc fRel = (ReleaseFunc)method_getImplementation(mRel);
    if (fRel) fRel(obj, sRel);
}

id Freight_MakeNSString(const char* text) {
    if (!text) return nil;
    Class cls = objc_getClass("NSString");
    SEL sel = sel_registerName(SEL_STR);
    Method m = class_getClassMethod(cls, sel);
    StrFactoryFunc f = (StrFactoryFunc)method_getImplementation(m);
    return f ? f((id)cls, sel, text) : nil;
}

const char* Freight_GetCString(id strObj) {
    if (!strObj) return "";
    SEL sel = sel_registerName(SEL_UTF8);
    Method m = class_getInstanceMethod(object_getClass(strObj), sel);
    UTF8Func f = (UTF8Func)method_getImplementation(m);
    return f ? f(strObj, sel) : "";
}

void Freight_SendChat(id server, const char* msg) {
    if (server && Freight_Real_SendChat) {
        Freight_Real_SendChat(server, sel_registerName(SEL_CHAT), Freight_MakeNSString(msg), nil);
    }
}

int Freight_GetItemID(id obj) {
    if (!obj) return 0;
    SEL sel = sel_registerName(SEL_TYPE);
    Method m = class_getInstanceMethod(object_getClass(obj), sel);
    IntFunc f = (IntFunc)method_getImplementation(m);
    return f ? f(obj, sel) : 0;
}

int Freight_ParseBlockID(int blockID) {
    if (blockID > 255) return blockID;
    switch (blockID) {
        case 1: return 1024; case 2: return 0; case 3: return 105; case 4: return 1060;
        case 6: return 1048; case 7: return 1051; case 9: return 1049; case 11: return 1026;
        case 12: return 1027; case 14: return 1029; case 16: return 11; case 17: return 1035;
        case 19: return 1037; case 24: return 1042; case 25: return 134; case 26: return 1045;
        case 29: return 1053; case 32: return 1057; case 48: return 1062; case 51: return 1063;
        case 53: return 1066; case 54: return 1067; case 55: return 1068; case 56: return 1069;
        case 57: return 1070; case 59: return 1076; case 60: return 210; case 67: return 1089;
        default: return blockID;
    }
}

// --- PLAYER LOOKUP (OPTIMIZED) ---
id Freight_FindPlayer(id dynWorld, const char* targetName) {
    if (!dynWorld || !targetName) return nil;
    id nsTarget = Freight_MakeNSString(targetName);
    if (!nsTarget) return nil;

    // Based on DynamicWorld.h: NSMutableArray* netBlockheads;
    id list = nil;
    Ivar ivList = class_getInstanceVariable(object_getClass(dynWorld), "netBlockheads");
    if (ivList) list = *(id*)((char*)dynWorld + ivar_getOffset(ivList));
    
    if (!list) return nil;

    SEL sCount = sel_registerName(SEL_COUNT);
    SEL sIdx = sel_registerName(SEL_OBJ_IDX);
    SEL sComp = sel_registerName(SEL_COMPARE);

    Method mCount = class_getInstanceMethod(object_getClass(list), sCount);
    Method mIdx = class_getInstanceMethod(object_getClass(list), sIdx);
    
    if (!mCount || !mIdx) return nil;

    CountFunc fCount = (CountFunc)method_getImplementation(mCount);
    ObjIdxFunc fIdx = (ObjIdxFunc)method_getImplementation(mIdx);

    int count = fCount(list, sCount);
    
    for (int i = 0; i < count; i++) {
        id bh = fIdx(list, sIdx, i);
        if (bh) {
            id nsName = nil;
            // Based on Blockhead.h: NSString* _clientName;
            Ivar ivCName = class_getInstanceVariable(object_getClass(bh), "_clientName");
            if (ivCName) {
                nsName = *(id*)((char*)bh + ivar_getOffset(ivCName));
            }

            if (nsName) {
                Method mComp = class_getInstanceMethod(object_getClass(nsName), sComp);
                if (mComp) {
                    CompareFunc fComp = (CompareFunc)method_getImplementation(mComp);
                    long result = fComp(nsName, sComp, nsTarget);
                    if (result == 0) return bh;
                }
            }
        }
    }
    return nil;
}

// --- CORE LOGIC (OPTIMIZED) ---
void Freight_SpawnItem(id dynWorld, id player, int idVal, int qty, id saveDict) {
    if (!player) return;
    
    // Based on DynamicObject.h: intpair _pos;
    IntPair posStruct = {0, 0};
    
    Ivar ivPos = class_getInstanceVariable(object_getClass(player), "_pos");
    if (ivPos) {
        posStruct = *(IntPair*)((char*)player + ivar_getOffset(ivPos));
    } else {
        return; // Failed to find pos, safe exit
    }
    
    if (posStruct.x == 0 && posStruct.y == 0) return;

    SEL sel = sel_registerName(SEL_SPAWN);
    Method mSpawn = class_getInstanceMethod(object_getClass(dynWorld), sel);
    if (mSpawn) {
        SpawnItemFunc f = (SpawnItemFunc)method_getImplementation(mSpawn);
        for(int i=0; i<qty; i++) {
            f(dynWorld, sel, posStruct, idVal, 1, 0, nil, saveDict, 1, 0, player);
        }
    }
}

// --- HOOKS ---
id Freight_Hook_ChestPlace(id self, SEL _cmd, id w, id dw, long long pos, id cache, id item, unsigned char flip, id save, id client, id cName) {
    id ret = Freight_Real_ChestPlace(self, _cmd, w, dw, pos, cache, item, flip, save, client, cName);
    
    if (g_FreightDupeEnabled && ret && item && Freight_GetItemID(item) == TARGET_ITEM) {
        const char* name = Freight_GetCString(cName);
        id pool = Freight_CreatePool();

        id player = Freight_FindPlayer(dw, name);
        if (player) {
            Freight_SpawnItem(dw, player, TARGET_ITEM, 1 + g_FreightDupeCount, save);
            
            SEL sRem = sel_registerName(SEL_REMOVE);
            Method mRem = class_getInstanceMethod(object_getClass(ret), sRem);
            if (mRem) {
                VoidBoolFunc fRem = (VoidBoolFunc)method_getImplementation(mRem);
                fRem(ret, sRem, 1);
            }
        }
        Freight_Release(pool);
    }
    return ret;
}

id Freight_Hook_HandleCmd(id self, SEL _cmd, id cmdStr, id client) {
    const char* raw = Freight_GetCString(cmdStr);
    if (!raw || strlen(raw) == 0) return Freight_Real_HandleCmd(self, _cmd, cmdStr, client);

    id pool = Freight_CreatePool();
    char buffer[256]; 
    strncpy(buffer, raw, 255); 
    buffer[255] = 0;
    
    bool isItem  = (strncmp(buffer, "/item", 5) == 0);
    bool isBlock = (strncmp(buffer, "/block", 6) == 0);
    bool isDupe  = (strncmp(buffer, "/dupe", 5) == 0);

    if (!isItem && !isBlock && !isDupe) {
        Freight_Release(pool);
        return Freight_Real_HandleCmd(self, _cmd, cmdStr, client);
    }

    // Based on BHServer.h: World* world;
    id world = nil;
    Ivar ivWorld = class_getInstanceVariable(object_getClass(self), "world");
    if (ivWorld) world = *(id*)((char*)self + ivar_getOffset(ivWorld));
    
    // Based on World.h: DynamicWorld* dynamicWorld;
    id dynWorld = nil;
    if (world) {
        Ivar ivDyn = class_getInstanceVariable(object_getClass(world), "dynamicWorld");
        if (ivDyn) dynWorld = *(id*)((char*)world + ivar_getOffset(ivDyn));
    }

    if (!dynWorld) {
        Freight_SendChat(self, "[CD+] Error: Server world not initialized.");
        Freight_Release(pool);
        return nil;
    }

    char *saveptr;
    char *token = strtok_r(buffer, " ", &saveptr);

    if (isDupe) {
        char* arg1 = strtok_r(NULL, " ", &saveptr);
        char* arg2 = strtok_r(NULL, " ", &saveptr); 
        char msg[128];

        if (!arg1) {
            g_FreightDupeEnabled = !g_FreightDupeEnabled;
            if (g_FreightDupeEnabled) g_FreightDupeCount = 1;
        } else {
            g_FreightDupeEnabled = true;
            g_FreightDupeCount = atoi(arg1);
            if (g_FreightDupeCount > 5 && (!arg2 || strcasecmp(arg2, "force") != 0)) {
                g_FreightDupeCount = 5;
            }
        }

        if (g_FreightDupeEnabled) {
            snprintf(msg, 128, "[CD+] Duplicator: ACTIVE (Mode: 1 Original + %d Copies)", g_FreightDupeCount);
        } else {
            snprintf(msg, 128, "[CD+] Duplicator: DISABLED");
        }
        Freight_SendChat(self, msg);
        Freight_Release(pool);
        return nil;
    }

    char *sID = strtok_r(NULL, " ", &saveptr);
    char *sQty = strtok_r(NULL, " ", &saveptr);
    char *sPlayer = strtok_r(NULL, " ", &saveptr);
    char *sArg4 = strtok_r(NULL, " ", &saveptr);

    if (!sID || !sPlayer) {
        Freight_SendChat(self, "[CD+] Usage: /item <ID> <Qty> <Player> [force]");
        Freight_Release(pool);
        return nil;
    }

    id targetBH = Freight_FindPlayer(dynWorld, sPlayer);
    if (!targetBH) {
        char err[128];
        snprintf(err, 128, "[CD+] Error: Player '%s' not found.", sPlayer);
        Freight_SendChat(self, err);
        Freight_Release(pool);
        return nil;
    }

    int qty = sQty ? atoi(sQty) : 1;
    if (qty < 1) qty = 1;
    bool force = false;
    if (sArg4 && strcasecmp(sArg4, "force")==0) force = true;
    
    if (!force && qty > 99) {
        qty = 99;
        Freight_SendChat(self, "[CD+] Warning: Quantity capped at 99.");
    }

    int itemID = atoi(sID);
    if (isBlock) itemID = Freight_ParseBlockID(itemID);
    
    Freight_SpawnItem(dynWorld, targetBH, itemID, qty, nil);
    
    char successMsg[128];
    snprintf(successMsg, 128, "[CD+] Spawned %d x (ID: %d) for %s.", qty, itemID, sPlayer);
    Freight_SendChat(self, successMsg);

    Freight_Release(pool);
    return nil;
}

// --- INITIALIZATION ---
static void* Freight_InitThread(void* arg) {
    sleep(1);
    Class clsServer = objc_getClass(SERVER_CLASS);
    if (clsServer) {
        SEL sC = sel_registerName(SEL_CMD);
        SEL sT = sel_registerName(SEL_CHAT);
        Method mC = class_getInstanceMethod(clsServer, sC);
        Method mT = class_getInstanceMethod(clsServer, sT);
        Freight_Real_HandleCmd = (CmdFunc)method_getImplementation(mC);
        Freight_Real_SendChat  = (ChatFunc)method_getImplementation(mT);
        method_setImplementation(mC, (IMP)Freight_Hook_HandleCmd);
    } 

    Class clsChest = objc_getClass(CHEST_CLASS);
    if (clsChest) {
        SEL sP = sel_registerName(SEL_PLACE);
        Method mP = class_getInstanceMethod(clsChest, sP);
        Freight_Real_ChestPlace = (PlaceFunc)method_getImplementation(mP);
        method_setImplementation(mP, (IMP)Freight_Hook_ChestPlace);
    } 
    return NULL;
}

__attribute__((constructor)) static void Freight_Entry() {
    pthread_t t; 
    pthread_create(&t, NULL, Freight_InitThread, NULL);
}
