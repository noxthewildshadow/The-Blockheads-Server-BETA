/*
 * Chest Dupe + Drop Item (Reliable & Crash Fixed)
 * -----------------------------------------------------
 * Description:
 * - Spawns items as "FreeBlocks" (drops) that fly to the player.
 * - Duplicates chests upon placement.
 * - FIXED: Player detection crash when >1 player is online.
 * - FIXED: Compilation errors.
 *
 * Commands:
 * /item <ID> <QTY> <PLAYER> [force]
 * /block <ID> <QTY> <PLAYER> [force]
 * /dupe [count]
 *
 * Compile: gcc -shared -o chest_mod.so chest_dupe_plus_any_item.c -fPIC -ldl
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <objc/runtime.h>
#include <objc/message.h>

// --- STRUCTS ---
typedef struct {
    int x;
    int y;
} IntPair;

// --- CONFIG ---
#define SERVER_CLASS  "BHServer"
#define CHEST_CLASS   "Chest"
#define TARGET_ITEM   1043

#define SEL_CMD       "handleCommand:issueClient:"
#define SEL_CHAT      "sendChatMessage:sendToClients:"
#define SEL_UTF8      "UTF8String"
#define SEL_STR       "stringWithUTF8String:"
#define SEL_PLACE     "initWithWorld:dynamicWorld:atPosition:cache:item:flipped:saveDict:placedByClient:clientName:"
#define SEL_REMOVE    "remove:"
#define SEL_TYPE      "itemType"
// The original, reliable spawn method
#define SEL_SPAWN     "createFreeBlockAtPosition:ofType:dataA:dataB:subItems:dynamicObjectSaveDict:hovers:playSound:priorityBlockhead:"

// --- TYPES ---
typedef id (*CmdFunc)(id, SEL, id, id);
typedef void (*ChatFunc)(id, SEL, id, id);
typedef id (*PlaceFunc)(id, SEL, id, id, long long, id, id, unsigned char, id, id, id);
// SpawnFunc takes IntPair struct (passed in registers)
typedef id (*SpawnFunc)(id, SEL, IntPair, int, int, int, id, id, BOOL, BOOL, id);
typedef id (*StrFactoryFunc)(id, SEL, const char*);
typedef const char* (*UTF8Func)(id, SEL);
typedef int (*IntFunc)(id, SEL);
typedef void (*VoidBoolFunc)(id, SEL, BOOL);
typedef int (*CountFunc)(id, SEL);
typedef id (*ObjIdxFunc)(id, SEL, unsigned long);
typedef long (*CompareFunc)(id, SEL, id);

// --- GLOBALS ---
static CmdFunc    Real_HandleCmd = NULL;
static ChatFunc   Real_SendChat = NULL;
static PlaceFunc  Real_ChestPlace = NULL;

static bool g_DupeEnabled = false;
static int  g_DupeCount = 1;

// --- HELPERS ---
id MkStr(const char* text) {
    Class cls = objc_getClass("NSString");
    SEL sel = sel_registerName(SEL_STR);
    StrFactoryFunc f = (StrFactoryFunc)method_getImplementation(class_getClassMethod(cls, sel));
    return f ? f((id)cls, sel, text) : nil;
}

const char* GetCStr(id strObj) {
    if (!strObj) return "";
    SEL sel = sel_registerName(SEL_UTF8);
    UTF8Func f = (UTF8Func)class_getMethodImplementation(object_getClass(strObj), sel);
    return f ? f(strObj, sel) : "";
}

void SendChat(id server, const char* msg) {
    if (server && Real_SendChat) {
        Real_SendChat(server, sel_registerName(SEL_CHAT), MkStr(msg), nil);
    }
}

int GetItemID(id obj) {
    if (!obj) return 0;
    SEL sel = sel_registerName(SEL_TYPE);
    IntFunc f = (IntFunc)class_getMethodImplementation(object_getClass(obj), sel);
    return f ? f(obj, sel) : 0;
}

// --- PLAYER LOOKUP (CRASH FIX) ---
id FindPlayer(id dynWorld, const char* name) {
    if (!dynWorld || !name) return nil;
    id targetStr = MkStr(name);
    
    // 1. Safe access to netBlockheads using Ivar
    id list = nil;
    Ivar ivList = class_getInstanceVariable(object_getClass(dynWorld), "netBlockheads");
    if (ivList) {
        list = *(id*)((char*)dynWorld + ivar_getOffset(ivList));
    }
    
    if (!list) return nil;

    SEL sCount = sel_registerName("count");
    SEL sIdx = sel_registerName("objectAtIndex:");
    SEL sComp = sel_registerName("caseInsensitiveCompare:");

    CountFunc fCount = (CountFunc)class_getMethodImplementation(object_getClass(list), sCount);
    ObjIdxFunc fIdx = (ObjIdxFunc)class_getMethodImplementation(object_getClass(list), sIdx);

    if (!fCount || !fIdx) return nil;

    int count = fCount(list, sCount);
    for (int i = 0; i < count; i++) {
        id bh = fIdx(list, sIdx, i);
        if (bh) {
            id nsName = nil;
            // FIX: Check _clientName (Ivar) specifically first
            Ivar ivName = class_getInstanceVariable(object_getClass(bh), "_clientName");
            if (ivName) {
                nsName = *(id*)((char*)bh + ivar_getOffset(ivName));
            }
            
            // Fallback: Check clientName (Ivar)
            if (!nsName) {
                ivName = class_getInstanceVariable(object_getClass(bh), "clientName");
                if (ivName) nsName = *(id*)((char*)bh + ivar_getOffset(ivName));
            }

            if (nsName) {
                CompareFunc fComp = (CompareFunc)class_getMethodImplementation(object_getClass(nsName), sComp);
                if (fComp && fComp(nsName, sComp, targetStr) == 0) return bh;
            }
        }
    }
    return nil;
}

// --- SPAWN LOGIC (Original & Reliable) ---
void SpawnItemAtPlayer(id dynWorld, id player, int idVal, int qty) {
    if (!player) return;
    
    // FIX: Read _pos struct correctly
    IntPair pos = {0,0};
    void* posPtr = NULL;
    
    Ivar ivPos = class_getInstanceVariable(object_getClass(player), "_pos");
    if (!ivPos) ivPos = class_getInstanceVariable(object_getClass(player), "pos"); // Fallback
    
    if (ivPos) {
        pos = *(IntPair*)((char*)player + ivar_getOffset(ivPos));
    } else {
        return;
    }

    if (pos.x == 0 && pos.y == 0) return;

    SEL sel = sel_registerName(SEL_SPAWN);
    Method mSpawn = class_getInstanceMethod(object_getClass(dynWorld), sel);
    
    if (mSpawn) {
        SpawnFunc f = (SpawnFunc)method_getImplementation(mSpawn);
        for(int i=0; i<qty; i++) {
            // Args: pos, type, dataA, dataB, subItems, saveDict, hovers(YES), sound(NO), priority(player)
            // Setting priorityBlockhead (last arg) makes it fly to the player.
            f(dynWorld, sel, pos, idVal, 0, 0, nil, nil, 1, 0, player);
        }
    }
}

// --- HOOKS ---
id Hook_ChestPlace(id self, SEL _cmd, id w, id dw, long long pos, id cache, id item, unsigned char flip, id save, id client, id cName) {
    id ret = Real_ChestPlace(self, _cmd, w, dw, pos, cache, item, flip, save, client, cName);
    
    if (g_DupeEnabled && ret && item && GetItemID(item) == TARGET_ITEM) {
        const char* name = GetCStr(cName);
        id player = FindPlayer(dw, name);
        
        if (player) {
            SpawnItemAtPlayer(dw, player, TARGET_ITEM, 1 + g_DupeCount);
            
            SEL sRem = sel_registerName(SEL_REMOVE);
            VoidBoolFunc fRem = (VoidBoolFunc)class_getMethodImplementation(object_getClass(ret), sRem);
            if (fRem) fRem(ret, sRem, 1);
        }
    }
    return ret;
}

id Hook_HandleCmd(id self, SEL _cmd, id cmdStr, id client) {
    const char* raw = GetCStr(cmdStr);
    if (!raw) return Real_HandleCmd(self, _cmd, cmdStr, client);

    char text[256]; strncpy(text, raw, 255); text[255] = 0;
    
    bool isItem  = (strncmp(text, "/item", 5) == 0);
    bool isBlock = (strncmp(text, "/block", 6) == 0);
    bool isDupe  = (strncmp(text, "/dupe", 5) == 0);

    if (!isItem && !isBlock && !isDupe) {
        return Real_HandleCmd(self, _cmd, cmdStr, client);
    }

    id world = nil;
    Ivar ivWorld = class_getInstanceVariable(object_getClass(self), "world");
    if (ivWorld) world = *(id*)((char*)self + ivar_getOffset(ivWorld));
    
    id dynWorld = nil;
    if (world) {
        Ivar ivDyn = class_getInstanceVariable(object_getClass(world), "dynamicWorld");
        if (ivDyn) dynWorld = *(id*)((char*)world + ivar_getOffset(ivDyn));
    }

    if (!dynWorld) {
        SendChat(self, "[Mod] Error: World not ready.");
        return nil;
    }

    char *saveptr;
    char *token = strtok_r(text, " ", &saveptr);

    if (isDupe) {
        char* arg1 = strtok_r(NULL, " ", &saveptr);
        if (!arg1) {
            g_DupeEnabled = !g_DupeEnabled;
            if (g_DupeEnabled) g_DupeCount = 1;
        } else {
            g_DupeEnabled = true;
            g_DupeCount = atoi(arg1);
            if(g_DupeCount < 1) g_DupeCount = 1;
            if(g_DupeCount > 50) g_DupeCount = 50;
        }
        char msg[128];
        snprintf(msg, 128, "[Mod] Chest Dupe: %s (%d Copies)", g_DupeEnabled ? "ON" : "OFF", g_DupeCount);
        SendChat(self, msg);
        return nil;
    }

    char *sID = strtok_r(NULL, " ", &saveptr);
    char *sQty = strtok_r(NULL, " ", &saveptr);
    char *sPlayer = strtok_r(NULL, " ", &saveptr);

    if (!sID || !sPlayer) {
        SendChat(self, "Usage: /item <ID> <QTY> <PLAYER>");
        return nil;
    }

    id targetBH = FindPlayer(dynWorld, sPlayer);
    if (!targetBH) {
        char err[128];
        snprintf(err, 128, "Error: Player '%s' not found.", sPlayer);
        SendChat(self, err);
        return nil;
    }

    int qty = sQty ? atoi(sQty) : 1;
    if (qty > 99) {
        qty = 99;
        SendChat(self, "Warning: Capped at 99.");
    }

    int itemID = atoi(sID);
    // Block ID conversion logic (Basic mapping)
    if (isBlock && itemID < 256) {
        if(itemID == 1) itemID = 1024; // Stone
        else if(itemID == 2) itemID = 0; // Air
        else if(itemID == 6) itemID = 1048; // Dirt
        else if(itemID == 7) itemID = 1051; // Sand
        else if(itemID == 9) itemID = 1049; // Wood
    }

    SpawnItemAtPlayer(dynWorld, targetBH, itemID, qty);
    
    char msg[128];
    snprintf(msg, 128, "Spawned %d x ID:%d for %s.", qty, itemID, sPlayer);
    SendChat(self, msg);

    return nil;
}

static void* InitThread(void* arg) {
    sleep(1);
    Class clsServer = objc_getClass(SERVER_CLASS);
    if (clsServer) {
        SEL sC = sel_registerName(SEL_CMD);
        SEL sT = sel_registerName(SEL_CHAT);
        Real_HandleCmd = (CmdFunc)method_getImplementation(class_getInstanceMethod(clsServer, sC));
        Real_SendChat  = (ChatFunc)method_getImplementation(class_getInstanceMethod(clsServer, sT));
        method_setImplementation(class_getInstanceMethod(clsServer, sC), (IMP)Hook_HandleCmd);
    }
    Class clsChest = objc_getClass(CHEST_CLASS);
    if (clsChest) {
        SEL sP = sel_registerName(SEL_PLACE);
        Real_ChestPlace = (PlaceFunc)method_getImplementation(class_getInstanceMethod(clsChest, sP));
        method_setImplementation(class_getInstanceMethod(clsChest, sP), (IMP)Hook_ChestPlace);
    }
    return NULL;
}

__attribute__((constructor)) static void Entry() {
    pthread_t t; pthread_create(&t, NULL, InitThread, NULL);
}
