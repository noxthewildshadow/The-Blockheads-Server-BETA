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

#define SERVER_CLASS  "BHServer"
#define CHEST_CLASS   "Chest"
#define TARGET_ITEM   1043

#define SEL_CMD       "handleCommand:issueClient:"
#define SEL_CHAT      "sendChatMessage:sendToClients:"
#define SEL_UTF8      "UTF8String"
#define SEL_STR       "stringWithUTF8String:"
#define SEL_NAME      "clientName"
#define SEL_ALL_NET   "allBlockheadsIncludingNet"
#define SEL_COUNT     "count"
#define SEL_OBJ_IDX   "objectAtIndex:"
#define SEL_COMPARE   "caseInsensitiveCompare:"
#define SEL_SPAWN     "createFreeBlockAtPosition:ofType:dataA:dataB:subItems:dynamicObjectSaveDict:hovers:playSound:priorityBlockhead:"
#define SEL_PLACE     "initWithWorld:dynamicWorld:atPosition:cache:item:flipped:saveDict:placedByClient:clientName:"
#define SEL_REMOVE    "remove:"
#define SEL_TYPE      "itemType"

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

static CmdFunc   Freight_Real_HandleCmd = NULL;
static ChatFunc  Freight_Real_SendChat = NULL;
static PlaceFunc Freight_Real_ChestPlace = NULL;

static bool g_FreightDupeEnabled = false;
static int  g_FreightDupeCount = 1;

// --- UTILS ---

id Freight_MakeNSString(const char* text) {
    if (!text) return nil;
    Class cls = objc_getClass("NSString");
    SEL sel = sel_registerName(SEL_STR);
    StrFactoryFunc f = (StrFactoryFunc)method_getImplementation(class_getClassMethod(cls, sel));
    return f ? f((id)cls, sel, text) : nil;
}

const char* Freight_GetCString(id strObj) {
    if (!strObj) return "";
    SEL sel = sel_registerName(SEL_UTF8);
    UTF8Func f = (UTF8Func)class_getMethodImplementation(object_getClass(strObj), sel);
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
    IntFunc f = (IntFunc)class_getMethodImplementation(object_getClass(obj), sel);
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
        case 68: return 1091; case 69: return 1090; case 71: return 1098; case 72: return 1099;
        case 73: return 1100; case 74: return 1101; case 75: return 1102;
        default: return blockID;
    }
}

// --- ROBUST FINDER (Same fix, isolated namespace) ---
id Freight_FindPlayer(id dynWorld, const char* targetName) {
    if (!dynWorld || !targetName) return nil;
    id nsTarget = Freight_MakeNSString(targetName);
    if (!nsTarget) return nil;

    id list = nil;
    SEL sAll = sel_registerName(SEL_ALL_NET);
    if (class_getInstanceMethod(object_getClass(dynWorld), sAll)) {
        ListFunc f = (ListFunc)class_getMethodImplementation(object_getClass(dynWorld), sAll);
        if (f) list = f(dynWorld, sAll);
    }
    if (!list) {
        Ivar iv = class_getInstanceVariable(object_getClass(dynWorld), "netBlockheads");
        if (iv) list = *(id*)((char*)dynWorld + ivar_getOffset(iv));
    }
    if (!list) return nil;

    SEL sCount = sel_registerName(SEL_COUNT);
    SEL sIdx = sel_registerName(SEL_OBJ_IDX);
    SEL sName = sel_registerName(SEL_NAME);
    SEL sComp = sel_registerName(SEL_COMPARE);

    CountFunc fCount = (CountFunc)class_getMethodImplementation(object_getClass(list), sCount);
    ObjIdxFunc fIdx = (ObjIdxFunc)class_getMethodImplementation(object_getClass(list), sIdx);
    
    if (!fCount || !fIdx) return nil;

    int count = fCount(list, sCount);
    for (int i = 0; i < count; i++) {
        id bh = fIdx(list, sIdx, i);
        if (bh) {
            id nsName = nil;
            if (class_getInstanceMethod(object_getClass(bh), sName)) {
                ListFunc fName = (ListFunc)class_getMethodImplementation(object_getClass(bh), sName);
                nsName = fName(bh, sName);
            }
            if (!nsName) {
                Ivar ivName = class_getInstanceVariable(object_getClass(bh), "clientName");
                if (ivName) nsName = *(id*)((char*)bh + ivar_getOffset(ivName));
            }

            if (nsName) {
                CompareFunc fComp = (CompareFunc)class_getMethodImplementation(object_getClass(nsName), sComp);
                if (fComp) {
                    long result = fComp(nsName, sComp, nsTarget);
                    if (result == 0) return bh; 
                }
            }
        }
    }
    return nil;
}

void Freight_SpawnItem(id dynWorld, id player, int idVal, int qty) {
    Ivar ivP = class_getInstanceVariable(object_getClass(player), "pos");
    long long pos = ivP ? *(long long*)((char*)player + ivar_getOffset(ivP)) : 0;
    if (pos == 0) return;

    SEL sel = sel_registerName(SEL_SPAWN);
    if (class_getInstanceMethod(object_getClass(dynWorld), sel)) {
        SpawnItemFunc f = (SpawnItemFunc)method_getImplementation(class_getInstanceMethod(object_getClass(dynWorld), sel));
        for(int i=0; i<qty; i++) f(dynWorld, sel, pos, idVal, 1, 0, nil, nil, 1, 0, player);
    }
}

id Freight_Hook_ChestPlace(id self, SEL _cmd, id w, id dw, long long pos, id cache, id item, unsigned char flip, id save, id client, id cName) {
    id ret = Freight_Real_ChestPlace(self, _cmd, w, dw, pos, cache, item, flip, save, client, cName);
    
    if (g_FreightDupeEnabled && ret && item && Freight_GetItemID(item) == TARGET_ITEM) {
        const char* name = Freight_GetCString(cName);
        id player = Freight_FindPlayer(dw, name);
        if (player) {
            Freight_SpawnItem(dw, player, TARGET_ITEM, 1 + g_FreightDupeCount);
            SEL sRem = sel_registerName(SEL_REMOVE);
            VoidBoolFunc fRem = (VoidBoolFunc)class_getMethodImplementation(object_getClass(ret), sRem);
            if (fRem) fRem(ret, sRem, 1);
        }
    }
    return ret;
}

id Freight_Hook_HandleCmd(id self, SEL _cmd, id cmdStr, id client) {
    const char* raw = Freight_GetCString(cmdStr);
    if (!raw || strlen(raw) == 0) return Freight_Real_HandleCmd(self, _cmd, cmdStr, client);

    char buffer[256]; strncpy(buffer, raw, 255); buffer[255] = 0;
    
    bool isItem  = (strncmp(buffer, "/item", 5) == 0);
    bool isBlock = (strncmp(buffer, "/block", 6) == 0);
    bool isDupe  = (strncmp(buffer, "/dupe", 5) == 0);

    if (!isItem && !isBlock && !isDupe) {
        return Freight_Real_HandleCmd(self, _cmd, cmdStr, client);
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
        Freight_SendChat(self, "Error: World not ready.");
        return nil;
    }

    if (isDupe) {
        char* token = strtok(buffer, " ");
        char* arg1 = strtok(NULL, " ");
        char* arg2 = strtok(NULL, " "); 
        
        if (!arg1) {
            g_FreightDupeEnabled = !g_FreightDupeEnabled;
            g_FreightDupeCount = 1;
            char msg[64]; snprintf(msg, 64, "Dupe: %s", g_FreightDupeEnabled?"ON":"OFF");
            Freight_SendChat(self, msg);
        } else {
            g_FreightDupeEnabled = true;
            g_FreightDupeCount = atoi(arg1);
            if (g_FreightDupeCount > 5 && (!arg2 || strcasecmp(arg2, "force") != 0)) g_FreightDupeCount = 5;
            char msg[64]; snprintf(msg, 64, "Dupe ON (+%d copies)", g_FreightDupeCount);
            Freight_SendChat(self, msg);
        }
        return nil;
    }

    char *tCmd = strtok(buffer, " ");
    char *sID = strtok(NULL, " ");
    char *sQty = strtok(NULL, " ");
    char *sPlayer = strtok(NULL, " ");
    char *sArg4 = strtok(NULL, " ");

    if (!sID || !sPlayer) {
        Freight_SendChat(self, "Usage: /item <ID> <Qty> <Player> [force]");
        return nil;
    }

    id targetBH = Freight_FindPlayer(dynWorld, sPlayer);
    if (!targetBH) {
        Freight_SendChat(self, "Error: Player not found.");
        return nil;
    }

    int qty = sQty ? atoi(sQty) : 1;
    if (qty < 1) qty = 1;
    
    bool force = false;
    if (sArg4 && strcasecmp(sArg4, "force")==0) force = true;
    
    if (!force && qty > 99) {
        qty = 99;
        Freight_SendChat(self, "Qty capped at 99.");
    }

    int itemID = atoi(sID);
    if (isBlock) itemID = Freight_ParseBlockID(itemID);
    
    Freight_SpawnItem(dynWorld, targetBH, itemID, qty);
    Freight_SendChat(self, "Items Spawned.");

    return nil;
}

static void* Freight_InitThread(void* arg) {
    sleep(1);
    Class clsServer = objc_getClass(SERVER_CLASS);
    if (clsServer) {
        SEL sC = sel_registerName(SEL_CMD);
        SEL sT = sel_registerName(SEL_CHAT);
        Freight_Real_HandleCmd = (CmdFunc)method_getImplementation(class_getInstanceMethod(clsServer, sC));
        Freight_Real_SendChat  = (ChatFunc)method_getImplementation(class_getInstanceMethod(clsServer, sT));
        method_setImplementation(class_getInstanceMethod(clsServer, sC), (IMP)Freight_Hook_HandleCmd);
    }
    Class clsChest = objc_getClass(CHEST_CLASS);
    if (clsChest) {
        SEL sP = sel_registerName(SEL_PLACE);
        Freight_Real_ChestPlace = (PlaceFunc)method_getImplementation(class_getInstanceMethod(clsChest, sP));
        method_setImplementation(class_getInstanceMethod(clsChest, sP), (IMP)Freight_Hook_ChestPlace);
    }
    printf("[System] Freight (Items/Dupe) Loaded.\n");
    return NULL;
}

__attribute__((constructor)) static void Freight_Entry() {
    pthread_t t; pthread_create(&t, NULL, Freight_InitThread, NULL);
}
