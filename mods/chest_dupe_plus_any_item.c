/*
 * Target: Chest Duplication & Item Spawning
 * Status: ISOLATED & STABLE
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

// --- Configuration ---
#define CHEST_CLASS_NAME  "Chest"
#define SERVER_CLASS_NAME "BHServer"
#define TARGET_ITEM_ID    1043

// --- Selectors ---
#define SEL_PLACE    "initWithWorld:dynamicWorld:atPosition:cache:item:flipped:saveDict:placedByClient:clientName:"
#define SEL_SPAWN    "createFreeBlockAtPosition:ofType:dataA:dataB:subItems:dynamicObjectSaveDict:hovers:playSound:priorityBlockhead:"
#define SEL_REMOVE   "remove:"
#define SEL_TYPE     "itemType"
#define SEL_CMD      "handleCommand:issueClient:"
#define SEL_CHAT     "sendChatMessage:sendToClients:"
#define SEL_UTF8     "UTF8String"
#define SEL_STR      "stringWithUTF8String:"

#define SEL_ALL_NET    "allBlockheadsIncludingNet"
#define SEL_NET_BHEADS "netBlockheads"
#define SEL_OBJ_IDX    "objectAtIndex:"
#define SEL_COUNT      "count"
#define SEL_POS        "pos"

// Auth
#define SEL_IS_CLOUD "playerIsCloudWideAdminWithAlias:"
#define SEL_IS_INVIS "playerIsCloudWideInvisibleAdminWithAlias:"

// --- Typedefs ---
typedef id (*PlaceFunc)(id, SEL, id, id, long long, id, id, unsigned char, id, id, id);
typedef id (*CmdFunc)(id, SEL, id, id);
typedef void (*ChatFunc)(id, SEL, id, id);
typedef id (*SpawnFunc)(id, SEL, long long, int, int, int, id, id, BOOL, BOOL, id);
typedef id (*ArrayFunc)(id, SEL);
typedef int (*IntFunc)(id, SEL);
typedef void (*VoidBoolFunc)(id, SEL, BOOL);
typedef const char* (*StrFunc)(id, SEL);
typedef id (*StringFactoryFunc)(id, SEL, const char*);
typedef BOOL (*BoolObjArg)(id, SEL, id);
typedef id (*ObjIdxFunc)(id, SEL, unsigned long);

// --- Global Storage (Static to avoid collision) ---
static PlaceFunc real_Chest_InitPlace = NULL;
static CmdFunc   real_Server_HandleCmd = NULL;
static ChatFunc  real_Server_SendChat = NULL;
static id g_ServerInstance = nil; 
static bool g_DupeEnabled = false; 
static int  g_ExtraCount = 1;

// --- C++ Override (Only needed in Spawner) ---
int _Z28itemTypeIsValidInventoryItem8ItemType(int itemType) {
    if (itemType > 0) return 1;
    return 0;
}

int _Z23itemTypeIsValidFillItem8ItemType(int itemType) {
    if (itemType > 0) return 1;
    return 0;
}

// --- STATIC HELPERS (Isolated) ---

static int SP_BlockIDToItemID(int blockID) {
    if (blockID > 255) return blockID;
    switch (blockID) {
        case 1: return 1024; case 2: return 0; case 3: return 105; case 4: return 1060;
        case 6: return 1048; case 7: return 1051; case 8: return 1051; case 9: return 1049;
        case 10: return 1024; case 11: return 1026; case 12: return 1027; case 13: return 1027;
        case 14: return 1029; case 15: return 1029; case 16: return 11; case 17: return 1035;
        case 18: return 1035; case 19: return 1037; case 20: return 1037; case 24: return 1042;
        case 25: return 134; case 26: return 1045; case 27: return 1048; case 28: return 1048;
        case 29: return 1053; case 30: return 1053; case 32: return 1057; case 42: return 134;
        case 43: return 135; case 44: return 136; case 45: return 137; case 46: return 138;
        case 47: return 139; case 48: return 1062; case 49: return 1062; case 50: return 1062;
        case 51: return 1063; case 52: return 1063; case 53: return 1066; case 54: return 1067;
        case 55: return 1068; case 56: return 1069; case 57: return 1070; case 58: return 1075;
        case 59: return 1076; case 60: return 210; case 67: return 1089; case 68: return 1091;
        case 69: return 1090; case 70: return 1094; case 71: return 1098; case 72: return 1099;
        case 73: return 1100; case 74: return 1101; case 75: return 1102; case 76: return 1103;
        case 77: return 1105;
        default: return 0;
    }
}

static int SP_GetItemID(id obj) {
    if (!obj) return 0;
    SEL sel = sel_registerName(SEL_TYPE);
    IMP method = class_getMethodImplementation(object_getClass(obj), sel);
    if (method) return ((IntFunc)method)(obj, sel);
    return 0;
}

static const char* SP_GetStringText(id strObj) {
    if (!strObj) return "";
    SEL sel = sel_registerName(SEL_UTF8);
    IMP method = class_getMethodImplementation(object_getClass(strObj), sel);
    if (method) return ((StrFunc)method)(strObj, sel);
    return "";
}

static id SP_CreateNSString(const char* text) {
    Class cls = objc_getClass("NSString");
    if (!cls) return nil;
    SEL sel = sel_registerName(SEL_STR);
    Method m = class_getClassMethod(cls, sel);
    if (m) {
        return ((StringFactoryFunc)method_getImplementation(m))((id)cls, sel, text);
    }
    return nil;
}

static void SP_SendChat(id server, const char* msg) {
    if (server && real_Server_SendChat) {
        id nsMsg = SP_CreateNSString(msg);
        real_Server_SendChat(server, sel_registerName(SEL_CHAT), nsMsg, nil);
    }
}

static long long SP_GetLongIvar(id obj, const char* ivarName) {
    if (!obj) return 0;
    Ivar ivar = class_getInstanceVariable(object_getClass(obj), ivarName);
    if (ivar) {
        ptrdiff_t offset = ivar_getOffset(ivar);
        return *(long long*)((char*)obj + offset);
    }
    return 0;
}

static id SP_GetObjectIvar(id obj, const char* ivarName) {
    if (!obj) return nil;
    Ivar ivar = class_getInstanceVariable(object_getClass(obj), ivarName);
    if (ivar) {
        ptrdiff_t offset = ivar_getOffset(ivar);
        return *(id*)((char*)obj + offset);
    }
    return nil;
}

static int SP_GetIntIvar(id obj, const char* ivarName) {
    if (!obj) return -1;
    Ivar ivar = class_getInstanceVariable(object_getClass(obj), ivarName);
    if (ivar) {
        ptrdiff_t offset = ivar_getOffset(ivar);
        return *(int*)((char*)obj + offset);
    }
    return -1;
}

static bool SP_IsAuthorizedName(id server, id nameObj) {
    if (!server || !nameObj) return false;
    SEL selCloud = sel_registerName(SEL_IS_CLOUD);
    SEL selInvis = sel_registerName(SEL_IS_INVIS);
    
    Class cls = object_getClass(server);
    if (class_getInstanceMethod(cls, selCloud)) {
        IMP method = class_getMethodImplementation(cls, selCloud);
        if (((BoolObjArg)method)(server, selCloud, nameObj)) return true;
    }
    if (class_getInstanceMethod(cls, selInvis)) {
        IMP method = class_getMethodImplementation(cls, selInvis);
        if (((BoolObjArg)method)(server, selInvis, nameObj)) return true;
    }
    return false;
}

static id SP_GetDynamicWorldFrom(id serverInstance) {
    if (!serverInstance) return nil;
    id worldObj = SP_GetObjectIvar(serverInstance, "world");
    if (!worldObj) return nil;
    return SP_GetObjectIvar(worldObj, "dynamicWorld");
}

static id SP_GetActiveBlockhead(id dynWorld, const char* optionalTargetName) {
    if (!dynWorld) return nil;

    id playerList = nil;
    SEL selAllNet = sel_registerName(SEL_ALL_NET);
    if (class_getInstanceMethod(object_getClass(dynWorld), selAllNet)) {
        ArrayFunc fGetList = (ArrayFunc) class_getMethodImplementation(object_getClass(dynWorld), selAllNet);
        playerList = fGetList(dynWorld, selAllNet);
    }
    if (!playerList) playerList = SP_GetObjectIvar(dynWorld, "netBlockheads");
    if (!playerList) return nil;

    SEL selCount = sel_registerName(SEL_COUNT);
    int (*fCount)(id, SEL) = (int (*)(id, SEL)) class_getMethodImplementation(object_getClass(playerList), selCount);
    int count = fCount(playerList, selCount);
    
    if (count == 0) return nil;

    SEL selIdx = sel_registerName(SEL_OBJ_IDX);
    ObjIdxFunc fIdx = (ObjIdxFunc) class_getMethodImplementation(object_getClass(playerList), selIdx);

    for (int i = 0; i < count; i++) {
        id obj = fIdx(playerList, selIdx, i);
        if (obj) {
            id nameObj = SP_GetObjectIvar(obj, "clientName");
            int clientID = SP_GetIntIvar(obj, "clientID");
            const char* name = SP_GetStringText(nameObj);
            
            bool isMatch = false;
            if (optionalTargetName && strlen(optionalTargetName) > 0) {
                if (name && strcasecmp(name, optionalTargetName) == 0) isMatch = true;
            } else {
                if (clientID > 0 && name && strlen(name) > 0) isMatch = true;
            }

            if (isMatch) return obj;
        }
    }
    return nil;
}

static void SP_SpawnItemInternal(id dynWorld, id targetBlockhead, int itemID, int count, id saveDict) {
    if (!dynWorld || !targetBlockhead) return;
    long long pos = SP_GetLongIvar(targetBlockhead, "pos");
    
    if (pos == 0) {
         SEL selPos = sel_registerName(SEL_POS);
         if (class_getInstanceMethod(object_getClass(targetBlockhead), selPos)) {
             long long (*fPos)(id, SEL) = (long long (*)(id, SEL)) class_getMethodImplementation(object_getClass(targetBlockhead), selPos);
             pos = fPos(targetBlockhead, selPos);
         }
    }
    if (pos == 0) return;

    SEL sel = sel_registerName(SEL_SPAWN);
    IMP method = class_getMethodImplementation(object_getClass(dynWorld), sel);
    
    if (method) {
        SpawnFunc fSpawn = (SpawnFunc)method;
        for (int i = 0; i < count; i++) {
            fSpawn(dynWorld, sel, pos, itemID, 1, 0, nil, saveDict, 1, 0, targetBlockhead);
        }
    }
}

// --- Hooks ---

id Spawner_Hook_Chest_InitPlace(id self, SEL _cmd, id world, id dynWorld, long long pos, id cache, id item, unsigned char flipped, id saveDict, id client, id clientName) {
    id newObj = NULL;
    if (real_Chest_InitPlace) {
        newObj = real_Chest_InitPlace(self, _cmd, world, dynWorld, pos, cache, item, flipped, saveDict, client, clientName);
    }
    if (newObj && item && g_DupeEnabled) {
        if (SP_GetItemID(item) == TARGET_ITEM_ID) {
            if (g_ServerInstance != NULL && SP_IsAuthorizedName(g_ServerInstance, clientName)) {
                 id targetBH = SP_GetActiveBlockhead(dynWorld, NULL); 
                 if (targetBH) {
                     SP_SpawnItemInternal(dynWorld, targetBH, TARGET_ITEM_ID, 1 + g_ExtraCount, saveDict);
                     SEL selRem = sel_registerName(SEL_REMOVE);
                     if (class_getInstanceMethod(object_getClass(newObj), selRem)) {
                         ((VoidBoolFunc)class_getMethodImplementation(object_getClass(newObj), selRem))(newObj, selRem, 1);
                     }
                 }
            }
        }
    }
    return newObj;
}

id Spawner_Hook_HandleCommand(id self, SEL _cmd, id commandStr, id client) {
    const char* rawText = SP_GetStringText(commandStr);
    g_ServerInstance = self; 
    
    if (!rawText || strlen(rawText) == 0) {
        if (real_Server_HandleCmd) return real_Server_HandleCmd(self, _cmd, commandStr, client);
        return nil;
    }

    char text[256];
    strncpy(text, rawText, 255);
    text[255] = '\0';

    if (strncmp(text, "/dupe", 5) == 0) {
        int newAmount = -1;
        char* token = strtok(text, " "); 
        token = strtok(NULL, " ");       
        if (token) newAmount = atoi(token);
        if (newAmount > 0) {
            g_DupeEnabled = true; g_ExtraCount = newAmount;
            SP_SendChat(self, "Dupe ON");
        } else {
            g_DupeEnabled = !g_DupeEnabled; g_ExtraCount = 1; 
            SP_SendChat(self, g_DupeEnabled ? "Dupe ON" : "Dupe OFF");
        }
        return nil;
    }

    if (strncmp(text, "/item", 5) == 0 || strncmp(text, "/block", 6) == 0) {
        id dynWorld = SP_GetDynamicWorldFrom(self); 
        if (!dynWorld) return nil;

        char buffer[256]; strncpy(buffer, text, 255);
        char* cmdName = strtok(buffer, " "); 
        char* strID   = strtok(NULL, " ");   
        char* strCount= strtok(NULL, " ");   
        char* strName = strtok(NULL, " ");   

        if (!strID) { SP_SendChat(self, "Usage: /item <ID>"); return nil; }

        int inputID = atoi(strID);
        int finalItemID = inputID;
        if (strncmp(cmdName, "/block", 6) == 0) {
            finalItemID = SP_BlockIDToItemID(inputID);
            if (finalItemID == 0) finalItemID = inputID;
        }

        int count  = (strCount) ? atoi(strCount) : 1;
        if (count > 99) count = 99;

        id targetBH = SP_GetActiveBlockhead(dynWorld, strName);
        if (!targetBH) { SP_SendChat(self, "Player not found."); return nil; }

        SP_SpawnItemInternal(dynWorld, targetBH, finalItemID, count, nil);
        SP_SendChat(self, "Spawned.");
        return nil;
    }

    if (real_Server_HandleCmd) {
        return real_Server_HandleCmd(self, _cmd, commandStr, client);
    }
    return nil;
}

static void *SpawnerPatchThread(void *arg) {
    printf("[Spawner] Loaded.\n");
    sleep(1);
    Class chestClass = objc_getClass(CHEST_CLASS_NAME);
    if (chestClass) {
        SEL selPlace = sel_registerName(SEL_PLACE);
        if (class_getInstanceMethod(chestClass, selPlace)) {
            real_Chest_InitPlace = (PlaceFunc)method_getImplementation(class_getInstanceMethod(chestClass, selPlace));
            method_setImplementation(class_getInstanceMethod(chestClass, selPlace), (IMP)Spawner_Hook_Chest_InitPlace);
        }
    }
    Class serverClass = objc_getClass(SERVER_CLASS_NAME);
    if (serverClass) {
        SEL selCmd = sel_registerName(SEL_CMD);
        if (class_getInstanceMethod(serverClass, selCmd)) {
            real_Server_HandleCmd = (CmdFunc)method_getImplementation(class_getInstanceMethod(serverClass, selCmd));
            method_setImplementation(class_getInstanceMethod(serverClass, selCmd), (IMP)Spawner_Hook_HandleCommand);
        }
        SEL selChat = sel_registerName(SEL_CHAT);
        if (class_getInstanceMethod(serverClass, selChat)) {
            real_Server_SendChat = (ChatFunc)method_getImplementation(class_getInstanceMethod(serverClass, selChat));
        }
    }
    return NULL;
}

__attribute__((constructor))
static void spawner_init() {
    pthread_t t;
    pthread_create(&t, NULL, SpawnerPatchThread, NULL);
}
