/*
 * Item Spawner & Chest Duplicator
 * Commands:
 * /item <ID> <QTY> <PLAYER> [force]
 * /block <ID> <QTY> <PLAYER> [force]
 * /dupe [count] [force]
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
#define TARGET_ITEM_ID    1043 
#define SERVER_CLASS      "BHServer"
#define CHEST_CLASS       "Chest"

// --- SELECTORS ---
#define SEL_PLACE    "initWithWorld:dynamicWorld:atPosition:cache:item:flipped:saveDict:placedByClient:clientName:"
#define SEL_SPAWN    "createFreeBlockAtPosition:ofType:dataA:dataB:subItems:dynamicObjectSaveDict:hovers:playSound:priorityBlockhead:"
#define SEL_REMOVE   "remove:"
#define SEL_TYPE     "itemType"
#define SEL_CMD      "handleCommand:issueClient:"
#define SEL_CHAT     "sendChatMessage:sendToClients:"
#define SEL_UTF8     "UTF8String"
#define SEL_STR      "stringWithUTF8String:"
#define SEL_COUNT    "count"
#define SEL_OBJ_IDX  "objectAtIndex:"
#define SEL_NAME     "clientName"
#define SEL_ALL_NET  "allBlockheadsIncludingNet"

// --- TYPEDEFS ---
typedef id (*PlaceFunc)(id, SEL, id, id, long long, id, id, unsigned char, id, id, id);
typedef id (*CmdFunc)(id, SEL, id, id);
typedef void (*ChatFunc)(id, SEL, id, id);
typedef id (*SpawnFunc)(id, SEL, long long, int, int, int, id, id, BOOL, BOOL, id);
typedef void (*VoidBoolFunc)(id, SEL, BOOL);
typedef const char* (*StrFunc)(id, SEL);
typedef id (*StringFactoryFunc)(id, SEL, const char*);
typedef id (*ObjIdxFunc)(id, SEL, unsigned long);
typedef id (*ListFunc)(id, SEL);
typedef int (*CountFunc)(id, SEL);
typedef int (*IntFunc)(id, SEL);

// --- GLOBALS ---
static PlaceFunc Real_Chest_InitPlace = NULL;
static CmdFunc   Real_Server_HandleCmd = NULL;
static ChatFunc  Real_Server_SendChat = NULL;
static bool g_DupeEnabled = false; 
static int  g_ExtraCount = 1;

// --- UTILS ---

int Dupe_BlockIDToItemID(int blockID) {
    if (blockID > 255) return blockID; 
    switch (blockID) {
        case 1: return 1024; case 2: return 0; case 3: return 105; case 4: return 1060;
        case 6: return 1048; case 7: return 1051; case 9: return 1049; case 11: return 1026;
        case 12: return 1027; case 14: return 1029; case 16: return 11; case 17: return 1035;
        case 19: return 1037; case 24: return 1042; case 25: return 134; case 26: return 1045;
        case 29: return 1053; case 32: return 1057; case 48: return 1062; case 51: return 1063;
        case 53: return 1066; case 54: return 1067; case 55: return 1068; case 56: return 1069;
        case 57: return 1070; case 59: return 1076; case 60: return 210; case 67: return 1089;
        case 68: return 1091; case 69: return 1090; case 71: return 1098; case 72: return 1099;
        case 73: return 1100; case 74: return 1101; case 75: return 1102;
        default: return blockID;
    }
}

static const char* Dupe_GetStr(id strObj) {
    if (!strObj) return "";
    SEL sel = sel_registerName(SEL_UTF8);
    StrFunc f = (StrFunc)class_getMethodImplementation(object_getClass(strObj), sel);
    return f ? f(strObj, sel) : "";
}

static id Dupe_AllocStr(const char* text) {
    Class cls = objc_getClass("NSString");
    SEL sel = sel_registerName(SEL_STR);
    StringFactoryFunc f = (StringFactoryFunc)method_getImplementation(class_getClassMethod(cls, sel));
    return f ? f((id)cls, sel, text) : nil;
}

static void Dupe_Chat(id server, const char* msg) {
    if (server && Real_Server_SendChat) {
        Real_Server_SendChat(server, sel_registerName(SEL_CHAT), Dupe_AllocStr(msg), nil);
    }
}

static int Dupe_GetID(id obj) {
    if (!obj) return 0;
    SEL sel = sel_registerName(SEL_TYPE);
    IntFunc f = (IntFunc)class_getMethodImplementation(object_getClass(obj), sel);
    return f ? f(obj, sel) : 0;
}

static const char* Dupe_GetBlockheadName(id bh) {
    if (!bh) return NULL;
    SEL sName = sel_registerName(SEL_NAME);
    
    // 1. Try Method
    if (class_getInstanceMethod(object_getClass(bh), sName)) {
        StrFunc f = (StrFunc)class_getMethodImplementation(object_getClass(bh), sName);
        if (f) {
            id s = ((id (*)(id, SEL))f)(bh, sName); 
            return Dupe_GetStr(s);
        }
    }
    // 2. Try Ivar
    Ivar iv = class_getInstanceVariable(object_getClass(bh), "clientName");
    if (iv) {
        id str = *(id*)((char*)bh + ivar_getOffset(iv));
        return Dupe_GetStr(str);
    }
    return NULL;
}

static id Dupe_ScanList(id list, const char* targetName) {
    if (!list) return nil;
    SEL sCount = sel_registerName(SEL_COUNT);
    SEL sIdx = sel_registerName(SEL_OBJ_IDX);
    
    CountFunc fCount = (CountFunc)class_getMethodImplementation(object_getClass(list), sCount);
    ObjIdxFunc fIdx = (ObjIdxFunc)class_getMethodImplementation(object_getClass(list), sIdx);

    if (!fCount || !fIdx) return nil;

    int count = fCount(list, sCount);
    for (int i = 0; i < count; i++) {
        id bh = fIdx(list, sIdx, i);
        if (bh) {
            const char* name = Dupe_GetBlockheadName(bh);
            if (name && targetName && strcasecmp(name, targetName) == 0) return bh;
        }
    }
    return nil;
}

static id Dupe_GetDynamicWorld(id server) {
    if (!server) return nil;
    Ivar ivar = class_getInstanceVariable(object_getClass(server), "world");
    if (ivar) {
        id world = *(id*)((char*)server + ivar_getOffset(ivar));
        if (world) {
            Ivar ivar2 = class_getInstanceVariable(object_getClass(world), "dynamicWorld");
            if (ivar2) return *(id*)((char*)world + ivar_getOffset(ivar2));
        }
    }
    return nil;
}

// --- CORE FIX: FIND PLAYER ---
static id Dupe_FindBlockhead(id dynWorld, const char* targetName) {
    if (!dynWorld || !targetName) return nil;

    // Method 1: allBlockheadsIncludingNet
    SEL sAll = sel_registerName(SEL_ALL_NET);
    if (class_getInstanceMethod(object_getClass(dynWorld), sAll)) {
        ListFunc f = (ListFunc)class_getMethodImplementation(object_getClass(dynWorld), sAll);
        if (f) {
            id fullList = f(dynWorld, sAll);
            id res = Dupe_ScanList(fullList, targetName);
            if (res) return res;
        }
    }

    // Method 2: Manual Fallback
    Ivar ivNet = class_getInstanceVariable(object_getClass(dynWorld), "netBlockheads");
    if (ivNet) {
        id res = Dupe_ScanList(*(id*)((char*)dynWorld + ivar_getOffset(ivNet)), targetName);
        if (res) return res;
    }
    return nil;
}

static void Dupe_Spawn(id dynWorld, id targetBH, int itemID, int count, id saveDict) {
    if (!dynWorld || !targetBH) return;
    long long pos = 0;
    Ivar ivar = class_getInstanceVariable(object_getClass(targetBH), "pos");
    if (ivar) pos = *(long long*)((char*)targetBH + ivar_getOffset(ivar));
    if (pos == 0) return;

    SEL sel = sel_registerName(SEL_SPAWN);
    SpawnFunc f = (SpawnFunc)class_getMethodImplementation(object_getClass(dynWorld), sel);
    if (f) {
        for(int i=0; i<count; i++) f(dynWorld, sel, pos, itemID, 1, 0, nil, saveDict, 1, 0, targetBH);
    }
}

// --- HOOKS ---

id Dupe_Chest_Hook(id self, SEL _cmd, id world, id dynWorld, long long pos, id cache, id item, unsigned char flipped, id saveDict, id client, id clientName) {
    id newObj = NULL;
    if (Real_Chest_InitPlace) 
        newObj = Real_Chest_InitPlace(self, _cmd, world, dynWorld, pos, cache, item, flipped, saveDict, client, clientName);

    if (newObj && item && g_DupeEnabled && Dupe_GetID(item) == TARGET_ITEM_ID) {
        const char* name = Dupe_GetStr(clientName);
        id targetBH = Dupe_FindBlockhead(dynWorld, name);
        if (targetBH) {
            Dupe_Spawn(dynWorld, targetBH, TARGET_ITEM_ID, 1 + g_ExtraCount, saveDict);
            SEL selRem = sel_registerName(SEL_REMOVE);
            VoidBoolFunc mRem = (VoidBoolFunc)class_getMethodImplementation(object_getClass(newObj), selRem);
            if (mRem) mRem(newObj, selRem, 1);
        }
    }
    return newObj;
}

id Dupe_Cmd_Hook(id self, SEL _cmd, id commandStr, id client) {
    const char* raw = Dupe_GetStr(commandStr);
    if (!raw || strlen(raw) == 0) 
        return Real_Server_HandleCmd ? Real_Server_HandleCmd(self, _cmd, commandStr, client) : nil;

    char text[256]; strncpy(text, raw, 255); text[255] = 0;

    // --- /DUPE ---
    if (strncmp(text, "/dupe", 5) == 0) {
        char* token = strtok(text, " "); 
        char* sAmount = strtok(NULL, " ");
        char* sForce = strtok(NULL, " ");

        if (!sAmount) {
            g_DupeEnabled = !g_DupeEnabled;
            g_ExtraCount = 1;
            char msg[128]; snprintf(msg, 128, "[SYSTEM] Duplicator: %s (Default +1)", g_DupeEnabled ? "ENABLED" : "DISABLED");
            Dupe_Chat(self, msg);
            return nil;
        }

        int amount = atoi(sAmount);
        bool isForce = (sForce && strcasecmp(sForce, "force") == 0);
        int max = isForce ? 99 : 3;

        if (amount > max) {
            amount = max;
            char warn[100]; snprintf(warn, 100, "[WARN] Cap reached. Use 'force' for max %d.", max);
            Dupe_Chat(self, warn);
        }

        if (amount > 0) {
            g_DupeEnabled = true;
            g_ExtraCount = amount;
            char msg[100]; snprintf(msg, 100, "[SYSTEM] Duplicator Active (+%d copies)", g_ExtraCount);
            Dupe_Chat(self, msg);
        }
        return nil;
    }

    // --- /ITEM or /BLOCK ---
    if (strncmp(text, "/item", 5) == 0 || strncmp(text, "/block", 6) == 0) {
        id dynWorld = Dupe_GetDynamicWorld(self);
        char buf[256]; strncpy(buf, text, 255);
        char *cmd = strtok(buf, " "), *sID = strtok(NULL, " "), *sCnt = strtok(NULL, " "), *sUsr = strtok(NULL, " "), *sForce = strtok(NULL, " ");

        if (!sID || !sUsr) { 
            Dupe_Chat(self, "[HELP] Usage: /item <ID> <QTY> <NAME> [force]"); 
            return nil; 
        }
        
        int idVal = atoi(sID);
        if (strncmp(cmd, "/block", 6) == 0) idVal = Dupe_BlockIDToItemID(idVal);
        
        int count = sCnt ? atoi(sCnt) : 1;
        bool isForce = (sForce && strcasecmp(sForce, "force") == 0);
        int max = isForce ? 999 : 99;

        if (count > max) {
            count = max;
            char warn[100]; snprintf(warn, 100, "[WARN] Quantity capped at %d. Use 'force' to override.", max);
            Dupe_Chat(self, warn);
        }

        id bh = Dupe_FindBlockhead(dynWorld, sUsr);

        if (bh) {
            Dupe_Spawn(dynWorld, bh, idVal, count, nil);
            char msg[128]; snprintf(msg, 128, "[SUCCESS] Gave %d x Item#%d to '%s'", count, idVal, sUsr);
            Dupe_Chat(self, msg);
        } else {
            char err[128]; snprintf(err, 128, "[ERROR] Player '%s' not found. (Check case sensitivity)", sUsr);
            Dupe_Chat(self, err);
        }
        return nil;
    }

    return Real_Server_HandleCmd ? Real_Server_HandleCmd(self, _cmd, commandStr, client) : nil;
}

static void* Dupe_InitThread(void* arg) {
    sleep(1);
    Class clsChest = objc_getClass(CHEST_CLASS);
    if (clsChest) {
        Method m = class_getInstanceMethod(clsChest, sel_registerName(SEL_PLACE));
        Real_Chest_InitPlace = (PlaceFunc)method_getImplementation(m);
        method_setImplementation(m, (IMP)Dupe_Chest_Hook);
    }
    Class clsServer = objc_getClass(SERVER_CLASS);
    if (clsServer) {
        Method m1 = class_getInstanceMethod(clsServer, sel_registerName(SEL_CMD));
        Real_Server_HandleCmd = (CmdFunc)method_getImplementation(m1);
        method_setImplementation(m1, (IMP)Dupe_Cmd_Hook);
        Method m2 = class_getInstanceMethod(clsServer, sel_registerName(SEL_CHAT));
        Real_Server_SendChat = (ChatFunc)method_getImplementation(m2);
    }
    return NULL;
}

__attribute__((constructor)) static void Dupe_Entry() {
    pthread_t t; pthread_create(&t, NULL, Dupe_InitThread, NULL);
}
