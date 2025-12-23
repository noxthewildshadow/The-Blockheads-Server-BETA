/*
 * Name: patch_item_dupe.c
 * Description: Commands to spawn items, blocks, and duplicate chests.
 * Commands: 
 * /item <ID> <QTY> <PLAYER> [force]
 * /block <ID> <QTY> <PLAYER> [force]
 * /dupe [count]
 * Author: Fixes by Assistant
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdbool.h>
#include <ctype.h>
#include <objc/runtime.h>
#include <objc/message.h>

// --- Constants ---
#define SERVER_CLASS  "BHServer"
#define CHEST_CLASS   "Chest"
#define TARGET_CHEST  1043

// --- Typedefs (Strict IMP Casting) ---
typedef id (*CmdFunc)(id, SEL, id, id);
typedef void (*ChatFunc)(id, SEL, id, id);
typedef id (*PlaceFunc)(id, SEL, id, id, long long, id, id, unsigned char, id, id, id);
typedef id (*SpawnItemFunc)(id, SEL, long long, int, int, int, id, id, BOOL, BOOL, id);
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

// --- Globals ---
static CmdFunc   Real_HandleCmd = NULL;
static ChatFunc  Real_SendChat = NULL;
static PlaceFunc Real_ChestPlace = NULL;
static bool g_DupeEnabled = false;
static int  g_DupeCount = 1;

// --- Helpers ---

// Safe ObjC Call Wrappers
id F_AllocStr(const char* text) {
    if (!text) return nil;
    Class cls = objc_getClass("NSString");
    SEL sel = sel_registerName("stringWithUTF8String:");
    StrFactoryFunc f = (StrFactoryFunc)method_getImplementation(class_getClassMethod(cls, sel));
    return f ? f((id)cls, sel, text) : nil;
}

const char* F_GetCStr(id strObj) {
    if (!strObj) return "";
    SEL sel = sel_registerName("UTF8String");
    UTF8Func f = (UTF8Func)class_getMethodImplementation(object_getClass(strObj), sel);
    return f ? f(strObj, sel) : "";
}

void F_SendChat(id server, const char* msg) {
    if (server && Real_SendChat) {
        Real_SendChat(server, sel_registerName("sendChatMessage:sendToClients:"), F_AllocStr(msg), nil);
    }
}

int F_GetItemID(id obj) {
    if (!obj) return 0;
    SEL sel = sel_registerName("itemType");
    IntFunc f = (IntFunc)class_getMethodImplementation(object_getClass(obj), sel);
    return f ? f(obj, sel) : 0;
}

// Convert Block ID to Item ID (Safety wrapper)
int F_ParseBlockID(int blockID) {
    if (blockID > 255) return blockID;
    // Common mappings to prevent user frustration
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

// --- Robust Player Lookup (Fixes Crash) ---
id F_FindPlayer(id dynWorld, const char* targetName) {
    if (!dynWorld || !targetName) return nil;
    
    // Safety check: Ensure targetName is not empty
    if (strlen(targetName) < 1) return nil;

    id nsTarget = F_AllocStr(targetName);
    if (!nsTarget) return nil;

    // Get List
    id list = nil;
    Ivar iv = class_getInstanceVariable(object_getClass(dynWorld), "netBlockheads");
    if (iv) list = *(id*)((char*)dynWorld + ivar_getOffset(iv));
    
    // Fallback getter if ivar fails
    if (!list) {
        SEL sAll = sel_registerName("allBlockheadsIncludingNet");
        if (class_getInstanceMethod(object_getClass(dynWorld), sAll)) {
            ListFunc f = (ListFunc)class_getMethodImplementation(object_getClass(dynWorld), sAll);
            list = f(dynWorld, sAll);
        }
    }
    
    if (!list) return nil;

    // Safe Iteration
    SEL sCount = sel_registerName("count");
    SEL sIdx = sel_registerName("objectAtIndex:");
    SEL sComp = sel_registerName("caseInsensitiveCompare:");
    SEL sName = sel_registerName("clientName");

    CountFunc fCount = (CountFunc)class_getMethodImplementation(object_getClass(list), sCount);
    ObjIdxFunc fIdx = (ObjIdxFunc)class_getMethodImplementation(object_getClass(list), sIdx);

    if (!fCount || !fIdx) return nil;

    int count = fCount(list, sCount);
    for (int i = 0; i < count; i++) {
        id bh = fIdx(list, sIdx, i);
        if (bh) {
            // Get Name Safely
            id nsName = nil;
            if (class_getInstanceMethod(object_getClass(bh), sName)) {
                ListFunc fName = (ListFunc)class_getMethodImplementation(object_getClass(bh), sName);
                nsName = fName(bh, sName);
            } else {
                 Ivar ivName = class_getInstanceVariable(object_getClass(bh), "clientName");
                 if (ivName) nsName = *(id*)((char*)bh + ivar_getOffset(ivName));
            }

            // Compare only if valid string
            if (nsName) {
                // Verify it's actually an NSString
                const char* clsName = object_getClassName(nsName);
                if (strstr(clsName, "String")) {
                     CompareFunc fComp = (CompareFunc)class_getMethodImplementation(object_getClass(nsName), sComp);
                     if (fComp && fComp(nsName, sComp, nsTarget) == 0) {
                         return bh;
                     }
                }
            }
        }
    }
    return nil;
}

// --- Spawner Logic ---
void F_SpawnItem(id dynWorld, id player, int idVal, int qty, id saveDict) {
    if (!player || !dynWorld) return;

    Ivar ivP = class_getInstanceVariable(object_getClass(player), "pos");
    long long pos = ivP ? *(long long*)((char*)player + ivar_getOffset(ivP)) : 0;
    
    // CRASH FIX: Ensure player position is valid
    if (pos == 0) return;

    SEL sel = sel_registerName("createFreeBlockAtPosition:ofType:dataA:dataB:subItems:dynamicObjectSaveDict:hovers:playSound:priorityBlockhead:");
    Method mSpawn = class_getInstanceMethod(object_getClass(dynWorld), sel);
    
    if (mSpawn) {
        SpawnItemFunc f = (SpawnItemFunc)method_getImplementation(mSpawn);
        for(int i=0; i<qty; i++) {
            f(dynWorld, sel, pos, idVal, 1, 0, nil, saveDict, 1, 0, player);
        }
    }
}

// --- Hooks ---

id Hook_ChestPlace(id self, SEL _cmd, id w, id dw, long long pos, id cache, id item, unsigned char flip, id save, id client, id cName) {
    id ret = Real_ChestPlace(self, _cmd, w, dw, pos, cache, item, flip, save, client, cName);
    
    // Duplication Logic
    if (g_DupeEnabled && ret && item && F_GetItemID(item) == TARGET_CHEST) {
        const char* name = F_GetCStr(cName);
        id player = F_FindPlayer(dw, name);
        
        if (player) {
            // Spawn copies
            F_SpawnItem(dw, player, TARGET_CHEST, g_DupeCount, save);
            
            // Remove the one just placed (optional, keeps inventory clean)
            SEL sRem = sel_registerName("remove:");
            VoidBoolFunc fRem = (VoidBoolFunc)class_getMethodImplementation(object_getClass(ret), sRem);
            if (fRem) fRem(ret, sRem, 1);
        }
    }
    return ret;
}

id Hook_HandleCmd(id self, SEL _cmd, id cmdStr, id client) {
    const char* raw = F_GetCStr(cmdStr);
    if (!raw || strlen(raw) == 0) return Real_HandleCmd(self, _cmd, cmdStr, client);

    // Local buffer copy for safety
    char buffer[256]; 
    strncpy(buffer, raw, 255); 
    buffer[255] = 0;
    
    bool isItem  = (strncasecmp(buffer, "/item", 5) == 0);
    bool isBlock = (strncasecmp(buffer, "/block", 6) == 0);
    bool isDupe  = (strncasecmp(buffer, "/dupe", 5) == 0);

    if (!isItem && !isBlock && !isDupe) {
        return Real_HandleCmd(self, _cmd, cmdStr, client);
    }

    // Get World/DynWorld safely
    id world = nil;
    Ivar ivW = class_getInstanceVariable(object_getClass(self), "world");
    if (ivW) world = *(id*)((char*)self + ivar_getOffset(ivW));
    
    id dynWorld = nil;
    if (world) {
        Ivar ivD = class_getInstanceVariable(object_getClass(world), "dynamicWorld");
        if (ivD) dynWorld = *(id*)((char*)world + ivar_getOffset(ivD));
    }

    if (!dynWorld) {
        F_SendChat(self, "[Error] World not initialized.");
        return nil;
    }

    char *saveptr;
    char *token = strtok_r(buffer, " ", &saveptr); 

    // --- DUPE COMMAND ---
    if (isDupe) {
        char* arg1 = strtok_r(NULL, " ", &saveptr);
        
        if (!arg1) {
            g_DupeEnabled = !g_DupeEnabled;
            if (g_DupeEnabled) g_DupeCount = 1; // Default
        } else {
            g_DupeEnabled = true;
            g_DupeCount = atoi(arg1);
            if (g_DupeCount < 1) g_DupeCount = 1;
            if (g_DupeCount > 10) g_DupeCount = 10; // Safety cap
        }

        char msg[128];
        if (g_DupeEnabled) {
            snprintf(msg, sizeof(msg), "[Dupe] ON. Mode: 1 Original + %d Copie%s", g_DupeCount, g_DupeCount > 1 ? "s" : "");
        } else {
            snprintf(msg, sizeof(msg), "[Dupe] OFF.");
        }
        F_SendChat(self, msg);
        return nil;
    }

    // --- ITEM/BLOCK COMMAND ---
    char *sID = strtok_r(NULL, " ", &saveptr);
    char *sQty = strtok_r(NULL, " ", &saveptr);
    char *sPlayer = strtok_r(NULL, " ", &saveptr);
    char *sArg4 = strtok_r(NULL, " ", &saveptr);

    if (!sID || !sPlayer) {
        F_SendChat(self, "Usage: /item <ID> <QTY> <PLAYER> [force]");
        return nil;
    }

    id targetBH = F_FindPlayer(dynWorld, sPlayer);
    if (!targetBH) {
        char err[128];
        snprintf(err, sizeof(err), "[Error] Player '%s' not found.", sPlayer);
        F_SendChat(self, err);
        return nil;
    }

    int qty = sQty ? atoi(sQty) : 1;
    if (qty < 1) qty = 1;
    
    bool force = (sArg4 && strcasecmp(sArg4, "force")==0);
    if (!force && qty > 99) {
        qty = 99;
        F_SendChat(self, "[Warn] Capped at 99. Use 'force' to override.");
    }

    int itemID = atoi(sID);
    if (isBlock) itemID = F_ParseBlockID(itemID);
    
    F_SpawnItem(dynWorld, targetBH, itemID, qty, nil);
    
    char successMsg[128];
    snprintf(successMsg, sizeof(successMsg), "[God] Gave %d x (ID:%d) to %s.", qty, itemID, sPlayer);
    F_SendChat(self, successMsg);

    return nil;
}

// --- Init ---
static void* F_InitThread(void* arg) {
    sleep(1);
    
    Class clsServer = objc_getClass(SERVER_CLASS);
    if (clsServer) {
        Method mC = class_getInstanceMethod(clsServer, sel_registerName("handleCommand:issueClient:"));
        Method mT = class_getInstanceMethod(clsServer, sel_registerName("sendChatMessage:sendToClients:"));
        
        Real_HandleCmd = (CmdFunc)method_getImplementation(mC);
        Real_SendChat  = (ChatFunc)method_getImplementation(mT);
        
        method_setImplementation(mC, (IMP)Hook_HandleCmd);
    }

    Class clsChest = objc_getClass(CHEST_CLASS);
    if (clsChest) {
        Method mP = class_getInstanceMethod(clsChest, sel_registerName("initWithWorld:dynamicWorld:atPosition:cache:item:flipped:saveDict:placedByClient:clientName:"));
        Real_ChestPlace = (PlaceFunc)method_getImplementation(mP);
        method_setImplementation(mP, (IMP)Hook_ChestPlace);
    }

    return NULL;
}

__attribute__((constructor)) static void F_Entry() {
    pthread_t t; 
    pthread_create(&t, NULL, F_InitThread, NULL);
}
