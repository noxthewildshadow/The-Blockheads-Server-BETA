/*
 * MOB Spawner
 * Commands: /spawn <mob> <qty> <PLAYER> [baby] [force]
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

#define SERVER_CLASS "BHServer"
#define SEL_CMD      "handleCommand:issueClient:"
#define SEL_CHAT     "sendChatMessage:sendToClients:"
#define SEL_UTF8     "UTF8String"
#define SEL_STR      "stringWithUTF8String:"
#define SEL_NAME     "clientName"
#define SEL_ALL_NET  "allBlockheadsIncludingNet"
#define SEL_COUNT    "count"
#define SEL_OBJ_IDX  "objectAtIndex:"
#define SEL_COMPARE  "caseInsensitiveCompare:"
#define SEL_LOAD_NPC "loadNPCAtPosition:type:saveDict:isAdult:wasPlaced:placedByClient:"

// --- TYPES ---
typedef id (*CmdFunc)(id, SEL, id, id);
typedef void (*ChatFunc)(id, SEL, id, id);
typedef id (*SpawnNPCFunc)(id, SEL, long long, int, id, BOOL, BOOL, id);
typedef long (*CompareFunc)(id, SEL, id);
typedef id (*StrFactoryFunc)(id, SEL, const char*);
typedef id (*ListFunc)(id, SEL);
typedef int (*CountFunc)(id, SEL);
typedef id (*ObjIdxFunc)(id, SEL, unsigned long);
typedef const char* (*UTF8Func)(id, SEL);

// --- GLOBALS (Prefixed) ---
static CmdFunc  Summon_Real_HandleCmd = NULL;
static ChatFunc Summon_Real_SendChat = NULL;

// --- UTILS ---

id Summon_MakeNSString(const char* text) {
    if (!text) return nil;
    Class cls = objc_getClass("NSString");
    SEL sel = sel_registerName(SEL_STR);
    StrFactoryFunc f = (StrFactoryFunc)method_getImplementation(class_getClassMethod(cls, sel));
    return f ? f((id)cls, sel, text) : nil;
}

const char* Summon_GetCString(id strObj) {
    if (!strObj) return "";
    SEL sel = sel_registerName(SEL_UTF8);
    UTF8Func f = (UTF8Func)class_getMethodImplementation(object_getClass(strObj), sel);
    return f ? f(strObj, sel) : "";
}

void Summon_SendChat(id server, const char* msg) {
    if (server && Summon_Real_SendChat) {
        Summon_Real_SendChat(server, sel_registerName(SEL_CHAT), Summon_MakeNSString(msg), nil);
    }
}

int Summon_ParseMobType(const char* name) {
    if (!name) return 0;
    if (strcasecmp(name, "dodo")==0) return 1;
    if (strcasecmp(name, "bear")==0 || strcasecmp(name, "dropbear")==0) return 2;
    if (strcasecmp(name, "donkey")==0) return 3;
    if (strcasecmp(name, "fish")==0 || strcasecmp(name, "clownfish")==0) return 4;
    if (strcasecmp(name, "shark")==0) return 5;
    if (strcasecmp(name, "troll")==0 || strcasecmp(name, "cavetroll")==0) return 6;
    if (strcasecmp(name, "scorpion")==0) return 7;
    if (strcasecmp(name, "yak")==0) return 8;
    return atoi(name);
}

// --- ROBUST FINDER (The Fix) ---
id Summon_FindPlayer(id dynWorld, const char* targetName) {
    if (!dynWorld || !targetName) return nil;

    id nsTarget = Summon_MakeNSString(targetName);
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

// --- LOGIC ---

void Summon_SpawnAction(id dynWorld, id player, int mobID, int qty, bool isBaby) {
    Ivar ivP = class_getInstanceVariable(object_getClass(player), "pos");
    long long pos = ivP ? *(long long*)((char*)player + ivar_getOffset(ivP)) : 0;
    if (pos == 0) return;

    SEL sel = sel_registerName(SEL_LOAD_NPC);
    if (class_getInstanceMethod(object_getClass(dynWorld), sel)) {
        SpawnNPCFunc f = (SpawnNPCFunc)method_getImplementation(class_getInstanceMethod(object_getClass(dynWorld), sel));
        for(int i=0; i<qty; i++) f(dynWorld, sel, pos, mobID, nil, !isBaby, 0, nil);
    }
}

id Summon_Hook_HandleCmd(id self, SEL _cmd, id cmdStr, id client) {
    const char* raw = Summon_GetCString(cmdStr);
    if (!raw || strlen(raw) == 0) return Summon_Real_HandleCmd(self, _cmd, cmdStr, client);

    char buffer[256]; strncpy(buffer, raw, 255); buffer[255] = 0;

    if (strncmp(buffer, "/spawn", 6) == 0) {
        id world = nil;
        Ivar ivW = class_getInstanceVariable(object_getClass(self), "world");
        if (ivW) world = *(id*)((char*)self + ivar_getOffset(ivW));
        
        id dynWorld = nil;
        if (world) {
            Ivar ivD = class_getInstanceVariable(object_getClass(world), "dynamicWorld");
            if (ivD) dynWorld = *(id*)((char*)world + ivar_getOffset(ivD));
        }

        if (!dynWorld) {
            Summon_SendChat(self, "Error: World not ready.");
            return nil;
        }

        char *tCmd = strtok(buffer, " ");
        char *sID = strtok(NULL, " ");
        char *sQty = strtok(NULL, " ");
        char *sPlayer = strtok(NULL, " ");
        char *sArg4 = strtok(NULL, " ");
        char *sArg5 = strtok(NULL, " ");

        if (!sID || !sPlayer) {
            Summon_SendChat(self, "Usage: /spawn <mob> <qty> <PLAYER> [baby] [force]");
            return nil;
        }

        id targetBH = Summon_FindPlayer(dynWorld, sPlayer);
        if (!targetBH) {
            Summon_SendChat(self, "Error: Player not found (Check Name/Spaces).");
            return nil;
        }

        int qty = sQty ? atoi(sQty) : 1;
        if (qty < 1) qty = 1;
        
        bool force = false;
        if (sArg4 && strcasecmp(sArg4, "force")==0) force = true;
        if (sArg5 && strcasecmp(sArg5, "force")==0) force = true;
        
        if (!force && qty > 50) {
            qty = 50;
            Summon_SendChat(self, "Qty capped at 50. Use 'force'.");
        }

        int mobID = Summon_ParseMobType(sID);
        bool baby = false;
        if (sArg4 && strcasecmp(sArg4, "baby")==0) baby = true;
        if (sArg5 && strcasecmp(sArg5, "baby")==0) baby = true;
        
        if (mobID > 0) {
            Summon_SpawnAction(dynWorld, targetBH, mobID, qty, baby);
            char msg[64]; snprintf(msg, 64, "Summoned %d %s for %s", qty, sID, sPlayer);
            Summon_SendChat(self, msg);
        } else {
            Summon_SendChat(self, "Unknown Mob.");
        }
        return nil;
    }

    return Summon_Real_HandleCmd(self, _cmd, cmdStr, client);
}

static void* Summon_InitThread(void* arg) {
    sleep(1);
    Class clsServer = objc_getClass(SERVER_CLASS);
    if (clsServer) {
        SEL sC = sel_registerName(SEL_CMD);
        SEL sT = sel_registerName(SEL_CHAT);
        Summon_Real_HandleCmd = (CmdFunc)method_getImplementation(class_getInstanceMethod(clsServer, sC));
        Summon_Real_SendChat  = (ChatFunc)method_getImplementation(class_getInstanceMethod(clsServer, sT));
        method_setImplementation(class_getInstanceMethod(clsServer, sC), (IMP)Summon_Hook_HandleCmd);
    }
    printf("[System] The Summoner (Robust) Loaded.\n");
    return NULL;
}

__attribute__((constructor)) static void Summon_Entry() {
    pthread_t t; pthread_create(&t, NULL, Summon_InitThread, NULL);
}
