/*
 * Chest Duplicator & Item Spawner (No-Cache / Always Fresh Edition)
 * Target Class: Chest
 * Target ID: 1043
 * * FIXES:
 * 1. Solves "Stop detecting player": Fetches fresh pointers every command execution.
 * 2. Solves "Crash": Removed unsafe memory writes during spawn.
 * 3. Solves "Dependency": No chest needed to initialize.
 * 4. Solves "Conflict": Namespaced symbols.
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

// Search Selectors
#define SEL_ALL_NET    "allBlockheadsIncludingNet"
#define SEL_NET_BHEADS "netBlockheads"
#define SEL_OBJ_IDX    "objectAtIndex:"
#define SEL_COUNT      "count"
#define SEL_POS        "pos"

// Auth Selectors
#define SEL_IS_CLOUD "playerIsCloudWideAdminWithAlias:"
#define SEL_IS_INVIS "playerIsCloudWideInvisibleAdminWithAlias:"

// --- Function Prototypes ---
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

// --- Global Storage (Namespaced) ---
static PlaceFunc Dupe_Real_Chest_InitPlace = NULL;
static CmdFunc   Dupe_Real_Server_HandleCmd = NULL;
static ChatFunc  Dupe_Real_Server_SendChat = NULL;

static id Dupe_ServerInstance = nil; 

// --- STATE ---
static bool g_DupeEnabled = false; 
static int  g_ExtraCount = 1;

// --- C++ OVERRIDE (Inventory Logic) ---
// Sobreescribe la validacion interna para permitir recoger cualquier item
int _Z28itemTypeIsValidInventoryItem8ItemType(int itemType) {
    if (itemType > 0) return 1;
    return 0;
}

int _Z23itemTypeIsValidFillItem8ItemType(int itemType) {
    if (itemType > 0) return 1;
    return 0;
}

// --- BLOCK CONVERTER ---
int Dupe_BlockIDToItemID(int blockID) {
    if (blockID > 255) return blockID;
    switch (blockID) {
        case 1: return 1024;  // STONE
        case 2: return 0;     // AIR
        case 3: return 105;   // WATER -> BUCKET
        case 4: return 1060;  // ICE
        case 6: return 1048;  // DIRT
        case 7: return 1051;  // SAND
        case 8: return 1051;  // MINED_SAND
        case 9: return 1049;  // WOOD
        case 10: return 1024; // MINED_STONE
        case 11: return 1026; // RED_BRICK
        case 12: return 1027; // LIMESTONE
        case 13: return 1027; // MINED_LIMESTONE
        case 14: return 1029; // MARBLE
        case 15: return 1029; // MINED_MARBLE
        case 16: return 11;   // TIME_CRYSTAL
        case 17: return 1035; // SAND_STONE
        case 18: return 1035; // MINED_SAND_STONE
        case 19: return 1037; // RED_MARBLE
        case 20: return 1037; // MINED_RED_MARBLE
        case 24: return 1042; // GLASS
        case 25: return 134;  // PORTAL
        case 26: return 1045; // GOLD_BLOCK
        case 27: return 1048; // GRASS -> DIRT
        case 28: return 1048; // SNOW -> DIRT
        case 29: return 1053; // LAPIS
        case 30: return 1053; // MINED_LAPIS
        case 32: return 1057; // REINFORCED_PLATFORM
        case 42: return 134;  // PORTAL_BASE
        case 43: return 135;  // AMETHYST_PORTAL
        case 44: return 136;  // SAPPHIRE_PORTAL
        case 45: return 137;  // EMERALD_PORTAL
        case 46: return 138;  // RUBY_PORTAL
        case 47: return 139;  // DIAMOND_PORTAL
        case 48: return 1062; // COMPOST
        case 49: return 1062; // GRASS_COMPOST
        case 50: return 1062; // SNOW_COMPOST
        case 51: return 1063; // BASALT
        case 52: return 1063; // MINED_BASALT
        case 53: return 1066; // COPPER
        case 54: return 1067; // TIN
        case 55: return 1068; // BRONZE
        case 56: return 1069; // IRON
        case 57: return 1070; // STEEL
        case 58: return 1075; // BLACK_SAND
        case 59: return 1076; // BLACK_GLASS
        case 60: return 210;  // TRADE_PORTAL
        case 67: return 1089; // PLATINUM
        case 68: return 1091; // TITANIUM
        case 69: return 1090; // CARBON_FIBER
        case 70: return 1094; // GRAVEL
        case 71: return 1098; // AMETHYST
        case 72: return 1099; // SAPPHIRE
        case 73: return 1100; // EMERALD
        case 74: return 1101; // RUBY
        case 75: return 1102; // DIAMOND
        case 76: return 1103; // PLASTER
        case 77: return 1105; // LUMINOUS_PLASTER
        default: return 0;
    }
}

// --- Helper Functions (Namespaced) ---

int Dupe_GetItemID(id obj) {
    if (!obj) return 0;
    SEL sel = sel_registerName(SEL_TYPE);
    IMP method = class_getMethodImplementation(object_getClass(obj), sel);
    if (method) return ((IntFunc)method)(obj, sel);
    return 0;
}

const char* Dupe_GetStringText(id strObj) {
    if (!strObj) return "";
    SEL sel = sel_registerName(SEL_UTF8);
    IMP method = class_getMethodImplementation(object_getClass(strObj), sel);
    if (method) return ((StrFunc)method)(strObj, sel);
    return "";
}

id Dupe_CreateNSString(const char* text) {
    Class cls = objc_getClass("NSString");
    if (!cls) return nil;
    SEL sel = sel_registerName(SEL_STR);
    Method m = class_getClassMethod(cls, sel);
    if (m) {
        return ((StringFactoryFunc)method_getImplementation(m))((id)cls, sel, text);
    }
    return nil;
}

void Dupe_SendChat(id server, const char* msg) {
    if (server && Dupe_Real_Server_SendChat) {
        id nsMsg = Dupe_CreateNSString(msg);
        Dupe_Real_Server_SendChat(server, sel_registerName(SEL_CHAT), nsMsg, nil);
    }
}

// --- MEMORY ACCESS (Namespaced) ---

long long Dupe_GetLongIvar(id obj, const char* ivarName) {
    if (!obj) return 0;
    Ivar ivar = class_getInstanceVariable(object_getClass(obj), ivarName);
    if (ivar) {
        ptrdiff_t offset = ivar_getOffset(ivar);
        return *(long long*)((char*)obj + offset);
    }
    return 0;
}

id Dupe_GetObjectIvar(id obj, const char* ivarName) {
    if (!obj) return nil;
    Ivar ivar = class_getInstanceVariable(object_getClass(obj), ivarName);
    if (ivar) {
        ptrdiff_t offset = ivar_getOffset(ivar);
        return *(id*)((char*)obj + offset);
    }
    return nil;
}

int Dupe_GetIntIvar(id obj, const char* ivarName) {
    if (!obj) return -1;
    Ivar ivar = class_getInstanceVariable(object_getClass(obj), ivarName);
    if (ivar) {
        ptrdiff_t offset = ivar_getOffset(ivar);
        return *(int*)((char*)obj + offset);
    }
    return -1;
}

// --- AUTH CHECKER ---
bool Dupe_IsAuthorizedName(id server, id nameObj) {
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

// --- CORE: GET FRESH DYNAMIC WORLD ---
// We fetch this EVERY time to ensure we never have a stale pointer.
id Dupe_GetDynamicWorldFrom(id serverInstance) {
    if (!serverInstance) return nil;
    id worldObj = Dupe_GetObjectIvar(serverInstance, "world");
    if (!worldObj) return nil;
    return Dupe_GetObjectIvar(worldObj, "dynamicWorld");
}

// --- SEARCH ACTIVE PLAYER (Always Fresh) ---
id Dupe_GetActiveBlockhead(id dynWorld, const char* optionalTargetName) {
    if (!dynWorld) return nil;

    id playerList = nil;

    // STRATEGY 1: Official Method (Safest, ensures fresh list)
    SEL selAllNet = sel_registerName(SEL_ALL_NET);
    if (class_getInstanceMethod(object_getClass(dynWorld), selAllNet)) {
        ArrayFunc fGetList = (ArrayFunc) class_getMethodImplementation(object_getClass(dynWorld), selAllNet);
        playerList = fGetList(dynWorld, selAllNet);
    }

    // STRATEGY 2: Net Ivar (Fallback)
    if (!playerList) {
        playerList = Dupe_GetObjectIvar(dynWorld, "netBlockheads");
    }

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
            id nameObj = Dupe_GetObjectIvar(obj, "clientName");
            int clientID = Dupe_GetIntIvar(obj, "clientID");
            const char* name = Dupe_GetStringText(nameObj);
              
            bool isMatch = false;
            // Name match (if provided)
            if (optionalTargetName && strlen(optionalTargetName) > 0) {
                if (name && strcasecmp(name, optionalTargetName) == 0) isMatch = true;
            } 
            // Any active player
            else {
                if (clientID > 0 && name && strlen(name) > 0) isMatch = true;
            }

            if (isMatch) return obj;
        }
    }
    return nil;
}

// --- SPAWN LOGIC ---
void Dupe_SpawnItemInternal(id dynWorld, id targetBlockhead, int itemID, int count, id saveDict) {
    if (!dynWorld || !targetBlockhead) return;
      
    long long pos = Dupe_GetLongIvar(targetBlockhead, "pos");
    // Retry via selector if Ivar is 0 (double check)
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
            // Spawn normal, priority to player. No memory hacks here to avoid crashes.
            fSpawn(dynWorld, sel, pos, itemID, 1, 0, nil, saveDict, 1, 0, targetBlockhead);
        }
    }
}

// HOOK 2: Chest Placement
id Dupe_Hook_Chest_InitPlace(id self, SEL _cmd, id world, id dynWorld, long long pos, id cache, id item, unsigned char flipped, id saveDict, id client, id clientName) {
    // Original Logic
    id newObj = NULL;
    if (Dupe_Real_Chest_InitPlace) {
        newObj = Dupe_Real_Chest_InitPlace(self, _cmd, world, dynWorld, pos, cache, item, flipped, saveDict, client, clientName);
    }

    // Dupe Logic
    if (newObj && item && g_DupeEnabled) {
        if (Dupe_GetItemID(item) == TARGET_ITEM_ID) {
            // Check auth on server instance (captured or passed)
            if (Dupe_ServerInstance != NULL && Dupe_IsAuthorizedName(Dupe_ServerInstance, clientName)) {
                 // Get Fresh DynamicWorld from passed arg
                 id targetBH = Dupe_GetActiveBlockhead(dynWorld, NULL); 
                 if (targetBH) {
                     Dupe_SpawnItemInternal(dynWorld, targetBH, TARGET_ITEM_ID, 1 + g_ExtraCount, saveDict);
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

// HOOK 1: Handle Command (Namespaced)
id Dupe_Hook_HandleCommand(id self, SEL _cmd, id commandStr, id client) {
    const char* rawText = Dupe_GetStringText(commandStr);
    Dupe_ServerInstance = self; // Update global instance reference
      
    if (!rawText || strlen(rawText) == 0) {
        if (Dupe_Real_Server_HandleCmd) return Dupe_Real_Server_HandleCmd(self, _cmd, commandStr, client);
        return nil;
    }

    char text[256];
    strncpy(text, rawText, 255);
    text[255] = '\0';

    // /dupe
    if (strncmp(text, "/dupe", 5) == 0) {
        int newAmount = -1;
        char* token = strtok(text, " "); 
        token = strtok(NULL, " ");        
        if (token) newAmount = atoi(token);

        char msgBuffer[100];
        if (newAmount > 0) {
            g_DupeEnabled = true;
            g_ExtraCount = newAmount;
            snprintf(msgBuffer, sizeof(msgBuffer), "SYSTEM: Dupe ON (+%d Copies)", g_ExtraCount);
        } else {
            g_DupeEnabled = !g_DupeEnabled;
            g_ExtraCount = 1; 
            snprintf(msgBuffer, sizeof(msgBuffer), g_DupeEnabled ? "SYSTEM: Dupe ON" : "SYSTEM: Dupe OFF");
        }
        Dupe_SendChat(self, msgBuffer);
        return nil;
    }

    // /item OR /block
    if (strncmp(text, "/item", 5) == 0 || strncmp(text, "/block", 6) == 0) {
        
        // 1. FRESH FETCH of DynamicWorld
        id dynWorld = Dupe_GetDynamicWorldFrom(self); 
        
        if (!dynWorld) {
            Dupe_SendChat(self, "ERROR: World not ready/accessible.");
            return nil;
        }

        char buffer[256];
        strncpy(buffer, text, 255);
        
        char* cmdName = strtok(buffer, " "); 
        char* strID   = strtok(NULL, " ");    
        char* strCount= strtok(NULL, " ");    
        char* strName = strtok(NULL, " ");    

        if (!strID) {
            Dupe_SendChat(self, "Usage: /item <ID> OR /block <ID>");
            return nil;
        }

        int inputID = atoi(strID);
        int finalItemID = inputID;

        if (strncmp(cmdName, "/block", 6) == 0) {
            finalItemID = Dupe_BlockIDToItemID(inputID);
            if (finalItemID == 0) finalItemID = inputID;
        }

        int count  = (strCount) ? atoi(strCount) : 1;
        if (count > 99) count = 99;

        // 2. FRESH SEARCH for Player using the FRESH DynamicWorld
        id targetBH = Dupe_GetActiveBlockhead(dynWorld, strName);
        
        if (!targetBH) {
            Dupe_SendChat(self, "ERROR: No active player found.");
            return nil;
        }

        char msgBuffer[128];
        snprintf(msgBuffer, sizeof(msgBuffer), "Spawning Item %d (x%d)", finalItemID, count);
        Dupe_SendChat(self, msgBuffer);
        
        Dupe_SpawnItemInternal(dynWorld, targetBH, finalItemID, count, nil);
        return nil;
    }

    if (Dupe_Real_Server_HandleCmd) {
        return Dupe_Real_Server_HandleCmd(self, _cmd, commandStr, client);
    }
    return nil;
}

static void *Dupe_PatchThread(void *arg) {
    printf("[System] Loading 'Freight Car Patch v8' (Final Stable)...\n");
    sleep(1);

    Class chestClass = objc_getClass(CHEST_CLASS_NAME);
    if (chestClass) {
        SEL selPlace = sel_registerName(SEL_PLACE);
        if (class_getInstanceMethod(chestClass, selPlace)) {
            Dupe_Real_Chest_InitPlace = (PlaceFunc)method_getImplementation(class_getInstanceMethod(chestClass, selPlace));
            method_setImplementation(class_getInstanceMethod(chestClass, selPlace), (IMP)Dupe_Hook_Chest_InitPlace);
        }
    }

    Class serverClass = objc_getClass(SERVER_CLASS_NAME);
    if (serverClass) {
        SEL selCmd = sel_registerName(SEL_CMD);
        if (class_getInstanceMethod(serverClass, selCmd)) {
            Dupe_Real_Server_HandleCmd = (CmdFunc)method_getImplementation(class_getInstanceMethod(serverClass, selCmd));
            method_setImplementation(class_getInstanceMethod(serverClass, selCmd), (IMP)Dupe_Hook_HandleCommand);
        }
        SEL selChat = sel_registerName(SEL_CHAT);
        if (class_getInstanceMethod(serverClass, selChat)) {
            Dupe_Real_Server_SendChat = (ChatFunc)method_getImplementation(class_getInstanceMethod(serverClass, selChat));
        }
    }

    printf("[System] Ready.\n");
    return NULL;
}

__attribute__((constructor))
static void Dupe_Init() {
    pthread_t t;
    pthread_create(&t, NULL, Dupe_PatchThread, NULL);
}
