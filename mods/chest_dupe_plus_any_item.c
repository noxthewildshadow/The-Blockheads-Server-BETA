//Commands: /item <any_item_id_here>   /dupe <quantity> (Then place the chest with all content inside)

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

// --- CONFIG ---
#define ISP_SERVER_CLASS  "BHServer"
#define ISP_CHEST_CLASS   "Chest"
#define ISP_TARGET_ITEM   1043

// --- IMP TYPES ---
typedef id (*ISP_CmdFunc)(id, SEL, id, id);
typedef void (*ISP_ChatFunc)(id, SEL, id, BOOL, id);
typedef id (*ISP_PlaceFunc)(id, SEL, id, id, long long, id, id, unsigned char, id, id, id);
typedef id (*ISP_SpawnFunc)(id, SEL, long long, int, int, int, id, id, BOOL, BOOL, id);

// Memory & Utils
typedef id (*ISP_AllocFunc)(id, SEL);
typedef id (*ISP_InitFunc)(id, SEL);
typedef void (*ISP_VoidFunc)(id, SEL);
typedef void (*ISP_VoidBoolFunc)(id, SEL, BOOL);
typedef id (*ISP_StrFunc)(id, SEL, const char*);
typedef const char* (*ISP_Utf8Func)(id, SEL);
typedef int (*ISP_IntFunc)(id, SEL);
typedef id (*ISP_IdxFunc)(id, SEL, int);
typedef id (*ISP_GetterFunc)(id, SEL);
typedef long (*ISP_CompFunc)(id, SEL, id);

// --- GLOBALS ---
static ISP_CmdFunc   Real_ISP_HandleCmd = NULL;
static ISP_ChatFunc  Real_ISP_SendChat = NULL;
static ISP_PlaceFunc Real_ISP_ChestPlace = NULL;

static bool g_ISP_DupeEnabled = false;
static int  g_ISP_DupeCount = 1;

// --- UTILS ---
static id ISP_Pool() {
    Class cls = objc_getClass("NSAutoreleasePool");
    SEL sA = sel_registerName("alloc");
    SEL sI = sel_registerName("init");
    ISP_AllocFunc fA = (ISP_AllocFunc)method_getImplementation(class_getClassMethod(cls, sA));
    ISP_InitFunc fI = (ISP_InitFunc)method_getImplementation(class_getInstanceMethod(cls, sI));
    return fI(fA((id)cls, sA), sI);
}

static void ISP_Drain(id pool) {
    if (!pool) return;
    SEL s = sel_registerName("drain");
    ISP_VoidFunc f = (ISP_VoidFunc)method_getImplementation(class_getInstanceMethod(object_getClass(pool), s));
    f(pool, s);
}

static id ISP_Str(const char* txt) {
    if (!txt) return nil;
    Class cls = objc_getClass("NSString");
    SEL s = sel_registerName("stringWithUTF8String:");
    ISP_StrFunc f = (ISP_StrFunc)method_getImplementation(class_getClassMethod(cls, s));
    return f ? f((id)cls, s, txt) : nil;
}

static const char* ISP_CStr(id str) {
    if (!str) return "";
    SEL s = sel_registerName("UTF8String");
    ISP_Utf8Func f = (ISP_Utf8Func)method_getImplementation(class_getInstanceMethod(object_getClass(str), s));
    return f ? f(str, s) : "";
}

static void ISP_Chat(id server, const char* msg) {
    if (server && Real_ISP_SendChat) {
        Real_ISP_SendChat(server, sel_registerName("sendChatMessage:displayNotification:sendToClients:"), ISP_Str(msg), true, nil);
    }
}

// --- LOGIC: FIND PLAYER (ClientName) ---
id ISP_FindBlockhead(id dynWorld, const char* name) {
    if (!dynWorld || !name) return nil;
    Ivar iv = class_getInstanceVariable(object_getClass(dynWorld), "netBlockheads");
    if (!iv) return nil;
    id list = *(id*)((char*)dynWorld + ivar_getOffset(iv));
    
    SEL sCnt = sel_registerName("count");
    SEL sIdx = sel_registerName("objectAtIndex:");
    SEL sClientName = sel_registerName("clientName");
    SEL sComp = sel_registerName("caseInsensitiveCompare:");
    
    ISP_IntFunc fCnt = (ISP_IntFunc)method_getImplementation(class_getInstanceMethod(object_getClass(list), sCnt));
    ISP_IdxFunc fIdx = (ISP_IdxFunc)method_getImplementation(class_getInstanceMethod(object_getClass(list), sIdx));
    
    int count = fCnt(list, sCnt);
    id target = ISP_Str(name);
    
    for (int i=0; i<count; i++) {
        id pool = ISP_Pool();
        id bh = fIdx(list, sIdx, i);
        id cName = nil;
        
        Method mName = class_getInstanceMethod(object_getClass(bh), sClientName);
        if (mName) {
            ISP_GetterFunc fName = (ISP_GetterFunc)method_getImplementation(mName);
            cName = fName(bh, sClientName);
        } else {
            Ivar ivN = class_getInstanceVariable(object_getClass(bh), "clientName");
            if (ivN) cName = *(id*)((char*)bh + ivar_getOffset(ivN));
        }
        
        if (cName) {
            ISP_CompFunc fComp = (ISP_CompFunc)method_getImplementation(class_getInstanceMethod(object_getClass(cName), sComp));
            if (fComp(cName, sComp, target) == 0) {
                ISP_Drain(pool);
                return bh;
            }
        }
        ISP_Drain(pool);
    }
    return nil;
}

// --- LOGIC: FULL BLOCK ID LIST ---
int ISP_ParseID(int blockID) {
    if (blockID > 255) return blockID; 
    switch (blockID) {
        case 1: return 1024; // Stone
        case 2: return 0;    // Dirt
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
    long long pos = *(long long*)((char*)player + ivar_getOffset(ivP));
    
    SEL sSpawn = sel_registerName("createFreeBlockAtPosition:ofType:dataA:dataB:subItems:dynamicObjectSaveDict:hovers:playSound:priorityBlockhead:");
    ISP_SpawnFunc fSpawn = (ISP_SpawnFunc)method_getImplementation(class_getInstanceMethod(object_getClass(dynWorld), sSpawn));
    
    for(int i=0; i<qty; i++) {
        fSpawn(dynWorld, sSpawn, pos, idVal, 1, 0, nil, saveDict, 1, 0, player);
    }
}

// --- HOOKS ---

id Hook_ISP_ChestPlace(id self, SEL _cmd, id w, id dw, long long pos, id cache, id item, unsigned char flip, id save, id client, id cName) {
    id ret = Real_ISP_ChestPlace(self, _cmd, w, dw, pos, cache, item, flip, save, client, cName);
    
    if (g_ISP_DupeEnabled && ret && item) {
        SEL sType = sel_registerName("itemType");
        ISP_IntFunc fType = (ISP_IntFunc)method_getImplementation(class_getInstanceMethod(object_getClass(item), sType));
        int type = fType(item, sType);

        if (type == ISP_TARGET_ITEM) {
            const char* name = ISP_CStr(cName);
            id pool = ISP_Pool();
            id player = ISP_FindBlockhead(dw, name);
            
            if (player) {
                // Spawn Original (1) + Copies (Count)
                ISP_Spawn(dw, player, ISP_TARGET_ITEM, 1 + g_ISP_DupeCount, save);
                
                SEL sRem = sel_registerName("remove:");
                ISP_VoidBoolFunc fRem = (ISP_VoidBoolFunc)method_getImplementation(class_getInstanceMethod(object_getClass(ret), sRem));
                fRem(ret, sRem, 1);
            }
            ISP_Drain(pool);
        }
    }
    return ret;
}

id Hook_ISP_Cmd(id self, SEL _cmd, id cmdStr, id client) {
    const char* raw = ISP_CStr(cmdStr);
    if (!raw) return Real_ISP_HandleCmd(self, _cmd, cmdStr, client);
    
    id pool = ISP_Pool();
    char buffer[256]; strncpy(buffer, raw, 255);
    
    bool isItem  = (strncmp(buffer, "/item", 5) == 0);
    bool isBlock = (strncmp(buffer, "/block", 6) == 0);
    bool isDupe  = (strncmp(buffer, "/dupe", 5) == 0);

    if (!isItem && !isBlock && !isDupe) {
        ISP_Drain(pool);
        return Real_ISP_HandleCmd(self, _cmd, cmdStr, client);
    }

    id world = nil;
    object_getInstanceVariable(self, "world", (void**)&world);
    id dynWorld = nil;
    if (world) object_getInstanceVariable(world, "dynamicWorld", (void**)&dynWorld);

    if (!dynWorld) {
        ISP_Chat(self, "[Error] World not initialized.");
        ISP_Drain(pool);
        return nil;
    }

    char *saveptr;
    strtok_r(buffer, " ", &saveptr);
    
    // --- DUPE ---
    if (isDupe) {
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
        snprintf(msg, 128, "[Dupe] %s. (Get 1 Original + %d Copies)", g_ISP_DupeEnabled ? "ON" : "OFF", g_ISP_DupeCount);
        ISP_Chat(self, msg);
        ISP_Drain(pool);
        return nil;
    }

    // --- ITEM/BLOCK ---
    char *sID = strtok_r(NULL, " ", &saveptr);
    char *sQty = strtok_r(NULL, " ", &saveptr);
    char *sPlayer = strtok_r(NULL, " ", &saveptr);
    char *sForce = strtok_r(NULL, " ", &saveptr);

    if (!sID || !sPlayer) {
        ISP_Chat(self, "[Usage] /item <ID> <QTY> <CLIENT_NAME> [force]");
        ISP_Drain(pool);
        return nil;
    }

    id targetBH = ISP_FindBlockhead(dynWorld, sPlayer);
    if (!targetBH) {
        char err[128];
        snprintf(err, 128, "[Error] Client '%s' not found.", sPlayer);
        ISP_Chat(self, err);
        ISP_Drain(pool);
        return nil;
    }

    int qty = sQty ? atoi(sQty) : 1;
    if (qty < 1) qty = 1;
    
    bool force = (sForce && strcasecmp(sForce, "force") == 0);
    if (!force && qty > 99) {
        qty = 99;
        ISP_Chat(self, "[Warn] Capped at 99. Use 'force' to override.");
    }

    int itemID = atoi(sID);
    if (isBlock) itemID = ISP_ParseID(itemID); // Convert Block->Item ID
    
    ISP_Spawn(dynWorld, targetBH, itemID, qty, nil);
    
    char successMsg[128];
    snprintf(successMsg, 128, "[System] Gave %d x (ID: %d) to %s.", qty, itemID, sPlayer);
    ISP_Chat(self, successMsg);

    ISP_Drain(pool);
    return nil;
}

// --- INIT ---
static void* ISP_Init(void* arg) {
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
    pthread_t t; pthread_create(&t, NULL, ISP_Init, NULL);
}
