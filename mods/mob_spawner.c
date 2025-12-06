/*
 * BLOCKHEADS ADMIN SPAWNER
 * Features:
 * - /spawn <mob> [qty] [baby]
 * - Pure Spawning Logic (Non tamed.)
 * - 100% Stable.
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
#include <strings.h> 

// --- Configuration ---
#define SERVER_CLASS_NAME "BHServer"
#define WORLD_CLASS_NAME  "DynamicWorld"

// --- NPC Types ---
enum NPCType {
    NPC_NOTHING   = 0,
    NPC_DODO      = 1,
    NPC_DROPBEAR  = 2,
    NPC_DONKEY    = 3,
    NPC_CLOWNFISH = 4,
    NPC_SHARK     = 5,
    NPC_CAVETROLL = 6,
    NPC_SCORPION  = 7,
    NPC_YAK       = 8
};

// --- Selectors ---
#define SEL_CMD        "handleCommand:issueClient:"
#define SEL_CHAT       "sendChatMessage:sendToClients:"
#define SEL_UTF8       "UTF8String"
#define SEL_STR        "stringWithUTF8String:"
#define SEL_ALL_NET    "allBlockheadsIncludingNet"
#define SEL_NET_BHEADS "netBlockheads"
#define SEL_COUNT      "count"
#define SEL_OBJ_IDX    "objectAtIndex:"
#define SEL_POS        "pos"
// Native Spawn Selector
#define SEL_SPAWN_NPC  "loadNPCAtPosition:type:saveDict:isAdult:wasPlaced:placedByClient:"

// --- Types ---
typedef id (*CmdFunc)(id, SEL, id, id);
typedef void (*ChatFunc)(id, SEL, id, id);
// SpawnNPCFunc: self, cmd, pos, type, saveDict, isAdult, wasPlaced, clientObj
typedef id (*SpawnNPCFunc)(id, SEL, long long, int, id, BOOL, BOOL, id);

typedef id (*ArrayFunc)(id, SEL);
typedef id (*ObjIdxFunc)(id, SEL, unsigned long);
typedef const char* (*StrFunc)(id, SEL);
typedef id (*StringFactoryFunc)(id, SEL, const char*);

// --- Globals ---
static CmdFunc real_Server_HandleCmd = NULL;
static ChatFunc real_Server_SendChat = NULL;

// --- MEMORY HELPERS ---

id GetObjectIvar(id obj, const char* ivarName) {
    if (!obj) return nil;
    Ivar ivar = class_getInstanceVariable(object_getClass(obj), ivarName);
    if (ivar) {
        ptrdiff_t offset = ivar_getOffset(ivar);
        return *(id*)((char*)obj + offset);
    }
    return nil;
}

int GetIntIvar(id obj, const char* ivarName) {
    if (!obj) return -1;
    Ivar ivar = class_getInstanceVariable(object_getClass(obj), ivarName);
    if (ivar) {
        ptrdiff_t offset = ivar_getOffset(ivar);
        return *(int*)((char*)obj + offset);
    }
    return -1;
}

long long GetLongIvar(id obj, const char* ivarName) {
    if (!obj) return 0;
    Ivar ivar = class_getInstanceVariable(object_getClass(obj), ivarName);
    if (ivar) {
        ptrdiff_t offset = ivar_getOffset(ivar);
        return *(long long*)((char*)obj + offset);
    }
    return 0;
}

const char* GetStringText(id strObj) {
    if (!strObj) return "";
    SEL sel = sel_registerName(SEL_UTF8);
    IMP method = class_getMethodImplementation(object_getClass(strObj), sel);
    if (method) return ((StrFunc)method)(strObj, sel);
    return "";
}

id CreateNSString(const char* text) {
    Class cls = objc_getClass("NSString");
    if (!cls) return nil;
    SEL sel = sel_registerName(SEL_STR);
    Method m = class_getClassMethod(cls, sel);
    if (m) {
        return ((StringFactoryFunc)method_getImplementation(m))((id)cls, sel, text);
    }
    return nil;
}

void SendChat(id server, const char* msg) {
    if (server && real_Server_SendChat) {
        id nsMsg = CreateNSString(msg);
        real_Server_SendChat(server, sel_registerName(SEL_CHAT), nsMsg, nil);
    }
}

int GetNPCIDFromName(const char* name) {
    if (!name) return 0;
    if (strcasecmp(name, "dodo") == 0) return NPC_DODO;
    if (strcasecmp(name, "dropbear") == 0) return NPC_DROPBEAR;
    if (strcasecmp(name, "bear") == 0) return NPC_DROPBEAR;
    if (strcasecmp(name, "donkey") == 0) return NPC_DONKEY;
    if (strcasecmp(name, "clownfish") == 0) return NPC_CLOWNFISH;
    if (strcasecmp(name, "fish") == 0) return NPC_CLOWNFISH;
    if (strcasecmp(name, "shark") == 0) return NPC_SHARK;
    if (strcasecmp(name, "troll") == 0) return NPC_CAVETROLL;
    if (strcasecmp(name, "cavetroll") == 0) return NPC_CAVETROLL;
    if (strcasecmp(name, "scorpion") == 0) return NPC_SCORPION;
    if (strcasecmp(name, "yak") == 0) return NPC_YAK;
    return atoi(name);
}

// --- CORE: GET DYNAMIC WORLD ---
id GetDynamicWorldFrom(id serverInstance) {
    if (!serverInstance) return nil;
    id worldObj = GetObjectIvar(serverInstance, "world");
    if (!worldObj) return nil;
    return GetObjectIvar(worldObj, "dynamicWorld");
}

// --- SEARCH ACTIVE PLAYER ---
id GetActiveBlockhead(id dynWorld) {
    if (!dynWorld) return nil;

    id playerList = nil;
    SEL selAllNet = sel_registerName(SEL_ALL_NET);
    if (class_getInstanceMethod(object_getClass(dynWorld), selAllNet)) {
        ArrayFunc fGetList = (ArrayFunc) class_getMethodImplementation(object_getClass(dynWorld), selAllNet);
        playerList = fGetList(dynWorld, selAllNet);
    }
    if (!playerList) playerList = GetObjectIvar(dynWorld, SEL_NET_BHEADS);
    
    if (!playerList) return nil;

    SEL selCount = sel_registerName(SEL_COUNT);
    int (*fCount)(id, SEL) = (int (*)(id, SEL)) class_getMethodImplementation(object_getClass(playerList), selCount);
    int count = fCount(playerList, selCount);
    
    SEL selIdx = sel_registerName(SEL_OBJ_IDX);
    ObjIdxFunc fIdx = (ObjIdxFunc) class_getMethodImplementation(object_getClass(playerList), selIdx);

    for (int i = 0; i < count; i++) {
        id obj = fIdx(playerList, selIdx, i);
        if (obj) {
            long long pos = GetLongIvar(obj, "pos");
            if (pos == 0) {
                 SEL selPos = sel_registerName(SEL_POS);
                 if (class_getInstanceMethod(object_getClass(obj), selPos)) {
                     long long (*fPos)(id, SEL) = (long long (*)(id, SEL)) class_getMethodImplementation(object_getClass(obj), selPos);
                     pos = fPos(obj, selPos);
                 }
            }
            if (pos != 0) return obj;
        }
    }
    return nil;
}

// --- SUMMON LOGIC (SIMPLE & STABLE) ---
void SummonNPC(id dynWorld, long long pos, int npcType, int qty, BOOL isAdult) {
    SEL selSpawn = sel_registerName(SEL_SPAWN_NPC);
    
    if (class_getInstanceMethod(object_getClass(dynWorld), selSpawn)) {
        SpawnNPCFunc fSpawn = (SpawnNPCFunc) class_getMethodImplementation(object_getClass(dynWorld), selSpawn);
        
        for (int i = 0; i < qty; i++) {
            // Args: pos, type, saveDict(nil), isAdult, wasPlaced(NO), placedByClient(nil)
            // Pure spawn, no ownership tricks.
            fSpawn(dynWorld, selSpawn, pos, npcType, nil, isAdult, 0, nil);
        }
    } else {
        printf("[Summoner] Error: Spawn selector not found on DynamicWorld.\n");
    }
}

// --- COMMAND HOOK ---
id Hook_HandleCommand(id self, SEL _cmd, id commandStr, id client) {
    const char* rawText = GetStringText(commandStr);
    
    if (!rawText || strlen(rawText) == 0) {
        if (real_Server_HandleCmd) return real_Server_HandleCmd(self, _cmd, commandStr, client);
        return nil;
    }

    char text[256];
    strncpy(text, rawText, 255);
    text[255] = '\0';

    // --- /SPAWN <TYPE> [QTY] [BABY] ---
    if (strncmp(text, "/spawn", 6) == 0) {
        id dynWorld = GetDynamicWorldFrom(self);
        
        if (!dynWorld) {
            SendChat(self, "Error: World not ready.");
            return nil;
        }

        char buffer[256];
        strncpy(buffer, text, 255);

        char* cmd = strtok(buffer, " ");
        char* strType = strtok(NULL, " ");
        char* strQty = strtok(NULL, " ");
        char* strArg3 = strtok(NULL, " "); 

        if (!strType) {
            SendChat(self, "Usage: /spawn <mob> [qty] [baby]");
            return nil;
        }

        int npcType = GetNPCIDFromName(strType);
        if (npcType == 0) {
            SendChat(self, "Error: Unknown mob type.");
            return nil;
        }

        int qty = (strQty) ? atoi(strQty) : 1;
        if (qty <= 0) qty = 1;
        if (qty > 50) qty = 50; 

        // Check for "baby"
        BOOL isAdult = 1;
        if (strArg3 && strcasecmp(strArg3, "baby") == 0) {
            isAdult = 0;
        }
        if (strncasecmp(strType, "baby_", 5) == 0) {
            isAdult = 0;
            npcType = GetNPCIDFromName(strType + 5); 
        }

        id targetBH = GetActiveBlockhead(dynWorld);
        
        if (targetBH) {
            long long pos = GetLongIvar(targetBH, "pos");
            // Pos fallback
            if (pos == 0) {
                 SEL selPos = sel_registerName(SEL_POS);
                 if (class_getInstanceMethod(object_getClass(targetBH), selPos)) {
                     long long (*fPos)(id, SEL) = (long long (*)(id, SEL)) class_getMethodImplementation(object_getClass(targetBH), selPos);
                     pos = fPos(targetBH, selPos);
                 }
            }

            if (pos != 0) {
                SummonNPC(dynWorld, pos, npcType, qty, isAdult);
                
                char msg[100];
                snprintf(msg, sizeof(msg), "Summoned %d %s%s", 
                    qty, 
                    isAdult ? "Adult " : "Baby ", 
                    strType);
                SendChat(self, msg);
            } else {
                SendChat(self, "Error: Invalid player position.");
            }
        } else {
            SendChat(self, "Player not found.");
        }
        return nil;
    }

    if (real_Server_HandleCmd) {
        return real_Server_HandleCmd(self, _cmd, commandStr, client);
    }
    return nil;
}

static void *patchThread(void *arg) {
    printf("[Summoner Lite] Module Loaded (Stable).\n");
    sleep(1);

    Class serverClass = objc_getClass(SERVER_CLASS_NAME);
    if (serverClass) {
        SEL selCmd = sel_registerName(SEL_CMD);
        if (class_getInstanceMethod(serverClass, selCmd)) {
            real_Server_HandleCmd = (CmdFunc)method_getImplementation(class_getInstanceMethod(serverClass, selCmd));
            method_setImplementation(class_getInstanceMethod(serverClass, selCmd), (IMP)Hook_HandleCommand);
        }
        SEL selChat = sel_registerName(SEL_CHAT);
        if (class_getInstanceMethod(serverClass, selChat)) {
            real_Server_SendChat = (ChatFunc)method_getImplementation(class_getInstanceMethod(serverClass, selChat));
        }
    }
    return NULL;
}

__attribute__((constructor))
static void init_hook() {
    pthread_t t;
    pthread_create(&t, NULL, patchThread, NULL);
}
