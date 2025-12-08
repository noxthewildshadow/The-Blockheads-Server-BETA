/*
 * Item Spawner & Duplicator
 * Help: /item <ID> <AMOUNT> <PLAYER_NAME>
 * Help: /block <ID> <AMOUNT> <PLAYER_NAME>
 * Help: /dupe
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

// --- Config ---
#define TARGET_ITEM_ID    1043 
#define SERVER_CLASS      "BHServer"
#define CHEST_CLASS       "Chest"

// --- Selectors ---
#define SEL_PLACE    "initWithWorld:dynamicWorld:atPosition:cache:item:flipped:saveDict:placedByClient:clientName:"
#define SEL_SPAWN    "createFreeBlockAtPosition:ofType:dataA:dataB:subItems:dynamicObjectSaveDict:hovers:playSound:priorityBlockhead:"
#define SEL_REMOVE   "remove:"
#define SEL_TYPE     "itemType"
#define SEL_CMD      "handleCommand:issueClient:"
#define SEL_CHAT     "sendChatMessage:sendToClients:"
#define SEL_UTF8     "UTF8String"
#define SEL_STR      "stringWithUTF8String:"
#define SEL_ALL_NET  "allBlockheadsIncludingNet"
#define SEL_COUNT    "count"
#define SEL_OBJ_IDX  "objectAtIndex:"
#define SEL_NAME     "clientName"

// --- Typedefs ---
typedef id (*PlaceFunc)(id, SEL, id, id, long long, id, id, unsigned char, id, id, id);
typedef id (*CmdFunc)(id, SEL, id, id);
typedef void (*ChatFunc)(id, SEL, id, id);
typedef id (*SpawnFunc)(id, SEL, long long, int, int, int, id, id, BOOL, BOOL, id);
typedef void (*VoidBoolFunc)(id, SEL, BOOL);
typedef const char* (*StrFunc)(id, SEL);
typedef id (*StringFactoryFunc)(id, SEL, const char*);
typedef id (*ObjIdxFunc)(id, SEL, unsigned long);

// --- Global Storage ---
static PlaceFunc Real_Chest_InitPlace = NULL;
static CmdFunc   Real_Server_HandleCmd = NULL;
static ChatFunc  Real_Server_SendChat = NULL;
static bool g_DupeEnabled = false; 
static int  g_ExtraCount = 1;

// --- C++ Overrides ---
int _Z28itemTypeIsValidInventoryItem8ItemType(int itemType) { return 1; }
int _Z23itemTypeIsValidFillItem8ItemType(int itemType) { return 1; }

int Dupe_BlockIDToItemID(int blockID) {
    if (blockID > 255) return blockID;
    switch (blockID) {
        case 1: return 1024; case 3: return 105; case 4: return 1060;
        case 6: return 1048; case 25: return 134; case 59: return 1076;
        default: return blockID;
    }
}

// --- Helpers ---
static const char* Dupe_GetStr(id strObj) {
    if (!strObj) return "";
    SEL sel = sel_registerName(SEL_UTF8);
    if (class_getInstanceMethod(object_getClass(strObj), sel)) {
        IMP method = class_getMethodImplementation(object_getClass(strObj), sel);
        return method ? ((StrFunc)method)(strObj, sel) : "";
    }
    return "";
}

static id Dupe_AllocStr(const char* text) {
    Class cls = objc_getClass("NSString");
    SEL sel = sel_registerName(SEL_STR);
    Method m = class_getClassMethod(cls, sel);
    return m ? ((StringFactoryFunc)method_getImplementation(m))((id)cls, sel, text) : nil;
}

static void Dupe_Chat(id server, const char* msg) {
    if (server && Real_Server_SendChat) {
        Real_Server_SendChat(server, sel_registerName(SEL_CHAT), Dupe_AllocStr(msg), nil);
    }
}

static int Dupe_GetID(id obj) {
    if (!obj) return 0;
    SEL sel = sel_registerName(SEL_TYPE);
    IMP m = class_getMethodImplementation(object_getClass(obj), sel);
    return m ? ((int (*)(id, SEL))m)(obj, sel) : 0;
}

static const char* Dupe_GetBlockheadName(id bh) {
    if (!bh) return NULL;
    SEL sName = sel_registerName(SEL_NAME);
    if (class_getInstanceMethod(object_getClass(bh), sName)) {
        IMP m = class_getMethodImplementation(object_getClass(bh), sName);
        if (m) {
            id s = ((id (*)(id, SEL))m)(bh, sName);
            return Dupe_GetStr(s);
        }
    }
    Ivar iv = class_getInstanceVariable(object_getClass(bh), "clientName");
    if (iv) {
        id str = *(id*)((char*)bh + ivar_getOffset(iv));
        return Dupe_GetStr(str);
    }
    return NULL;
}

// --- Finder Logic ---
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

static id Dupe_FindBlockhead(id dynWorld, const char* targetName) {
    if (!dynWorld || !targetName) return nil;
    id list = nil;
    SEL selAll = sel_registerName(SEL_ALL_NET);
    IMP mAll = class_getMethodImplementation(object_getClass(dynWorld), selAll);
    if (mAll) list = ((id (*)(id, SEL))mAll)(dynWorld, selAll);
    
    if (!list) {
        Ivar ivar = class_getInstanceVariable(object_getClass(dynWorld), "netBlockheads");
        if (ivar) list = *(id*)((char*)dynWorld + ivar_getOffset(ivar));
    }
    if (!list) return nil;

    SEL selCount = sel_registerName(SEL_COUNT);
    IMP mCount = class_getMethodImplementation(object_getClass(list), selCount);
    int count = mCount ? ((int (*)(id, SEL))mCount)(list, selCount) : 0;

    SEL selIdx = sel_registerName(SEL_OBJ_IDX);
    IMP mIdx = class_getMethodImplementation(object_getClass(list), selIdx);

    for (int i = 0; i < count; i++) {
        id bh = mIdx ? ((ObjIdxFunc)mIdx)(list, selIdx, i) : nil;
        if (bh) {
            const char* bhName = Dupe_GetBlockheadName(bh);
            if (bhName && targetName && strcasecmp(bhName, targetName) == 0) {
                return bh;
            }
        }
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

// --- Hooks ---
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
            IMP mRem = class_getMethodImplementation(object_getClass(newObj), selRem);
            if (mRem) ((VoidBoolFunc)mRem)(newObj, selRem, 1);
        }
    }
    return newObj;
}

id Dupe_Cmd_Hook(id self, SEL _cmd, id commandStr, id client) {
    const char* raw = Dupe_GetStr(commandStr);
    if (!raw || strlen(raw) == 0) 
        return Real_Server_HandleCmd ? Real_Server_HandleCmd(self, _cmd, commandStr, client) : nil;

    char text[256]; strncpy(text, raw, 255); text[255] = 0;

    // /dupe
    if (strncmp(text, "/dupe", 5) == 0) {
        char* token = strtok(text, " "); token = strtok(NULL, " ");
        int amount = (token) ? atoi(token) : -1;
        char msg[100];
        if (amount > 0) {
            g_DupeEnabled = true; g_ExtraCount = amount;
            snprintf(msg, 100, "SYSTEM: Dupe Active (+%d copies)", g_ExtraCount);
        } else {
            g_DupeEnabled = !g_DupeEnabled; g_ExtraCount = 1;
            snprintf(msg, 100, g_DupeEnabled ? "SYSTEM: Dupe ON" : "SYSTEM: Dupe OFF");
        }
        Dupe_Chat(self, msg);
        return nil;
    }

    // /item or /block
    if (strncmp(text, "/item", 5) == 0 || strncmp(text, "/block", 6) == 0) {
        id dynWorld = Dupe_GetDynamicWorld(self);
        char buf[256]; strncpy(buf, text, 255);
        char *cmd = strtok(buf, " "), *sID = strtok(NULL, " "), *sCnt = strtok(NULL, " "), *sUsr = strtok(NULL, " ");

        if (!sID || !sUsr) { 
            Dupe_Chat(self, "Help: /item <ID> <AMOUNT> <PLAYER_NAME>"); 
            return nil; 
        }
        
        int idVal = atoi(sID);
        if (strncmp(cmd, "/block", 6) == 0) idVal = Dupe_BlockIDToItemID(idVal);
        int count = sCnt ? atoi(sCnt) : 1;
        if (count > 99) count = 99;

        id bh = Dupe_FindBlockhead(dynWorld, sUsr);

        if (bh) {
            Dupe_Spawn(dynWorld, bh, idVal, count, nil);
            char msg[128]; snprintf(msg, 128, "Spawned %d (x%d) for %s", idVal, count, sUsr);
            Dupe_Chat(self, msg);
        } else {
            Dupe_Chat(self, "Error: Player name not found. Check spelling.");
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
