/*
 * MOB Spawner
 * Help: /spawn <mob> <qty> <PLAYER_NAME> [baby]
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
#define SEL_ALL_NET  "allBlockheadsIncludingNet"
#define SEL_COUNT    "count"
#define SEL_OBJ_IDX  "objectAtIndex:"
#define SEL_SPAWN_NPC "loadNPCAtPosition:type:saveDict:isAdult:wasPlaced:placedByClient:"
#define SEL_NAME      "clientName"

enum NPCType { NPC_DODO=1, NPC_DROPBEAR=2, NPC_DONKEY=3, NPC_CLOWNFISH=4, NPC_SHARK=5, NPC_CAVETROLL=6, NPC_SCORPION=7, NPC_YAK=8 };

typedef id (*CmdFunc)(id, SEL, id, id);
typedef void (*ChatFunc)(id, SEL, id, id);
typedef id (*SpawnNPCFunc)(id, SEL, long long, int, id, BOOL, BOOL, id);
typedef const char* (*StrFunc)(id, SEL);
typedef id (*StringFactoryFunc)(id, SEL, const char*);
typedef id (*ObjIdxFunc)(id, SEL, unsigned long);

static CmdFunc  Summon_Real_HandleCmd = NULL;
static ChatFunc Summon_Real_SendChat = NULL;

static const char* Summon_GetStr(id str) {
    if (!str) return "";
    SEL sel = sel_registerName(SEL_UTF8);
    if (class_getInstanceMethod(object_getClass(str), sel)) {
        IMP m = class_getMethodImplementation(object_getClass(str), sel);
        return m ? ((StrFunc)m)(str, sel) : "";
    }
    return "";
}

static id Summon_AllocStr(const char* txt) {
    Class cls = objc_getClass("NSString");
    SEL sel = sel_registerName(SEL_STR);
    Method m = class_getClassMethod(cls, sel);
    return m ? ((StringFactoryFunc)method_getImplementation(m))((id)cls, sel, txt) : nil;
}

static void Summon_Chat(id server, const char* msg) {
    if (server && Summon_Real_SendChat) 
        Summon_Real_SendChat(server, sel_registerName(SEL_CHAT), Summon_AllocStr(msg), nil);
}

static const char* Summon_GetBlockheadName(id bh) {
    if (!bh) return NULL;
    SEL sName = sel_registerName(SEL_NAME);
    if (class_getInstanceMethod(object_getClass(bh), sName)) {
        IMP m = class_getMethodImplementation(object_getClass(bh), sName);
        if (m) {
            id s = ((id (*)(id, SEL))m)(bh, sName);
            return Summon_GetStr(s);
        }
    }
    Ivar iv = class_getInstanceVariable(object_getClass(bh), "clientName");
    if (iv) {
        id str = *(id*)((char*)bh + ivar_getOffset(iv));
        return Summon_GetStr(str);
    }
    return NULL;
}

static int Summon_ParseType(const char* name) {
    if (!name) return 0;
    if (strcasecmp(name, "dodo")==0) return NPC_DODO;
    if (strcasecmp(name, "bear")==0 || strcasecmp(name, "dropbear")==0) return NPC_DROPBEAR;
    if (strcasecmp(name, "donkey")==0) return NPC_DONKEY;
    if (strcasecmp(name, "fish")==0) return NPC_CLOWNFISH;
    if (strcasecmp(name, "shark")==0) return NPC_SHARK;
    if (strcasecmp(name, "troll")==0) return NPC_CAVETROLL;
    if (strcasecmp(name, "scorpion")==0) return NPC_SCORPION;
    if (strcasecmp(name, "yak")==0) return NPC_YAK;
    return 0; // Unknown
}

static id Summon_GetDynamicWorld(id server) {
    if (!server) return nil;
    Ivar ivar = class_getInstanceVariable(object_getClass(server), "world");
    if (ivar) {
        id w = *(id*)((char*)server + ivar_getOffset(ivar));
        if (w) {
            Ivar ivar2 = class_getInstanceVariable(object_getClass(w), "dynamicWorld");
            if (ivar2) return *(id*)((char*)w + ivar_getOffset(ivar2));
        }
    }
    return nil;
}

static id Summon_FindBlockhead(id dynWorld, const char* targetName) {
    if (!dynWorld || !targetName) return nil;
    id list = nil;
    SEL selAll = sel_registerName(SEL_ALL_NET);
    IMP mAll = class_getMethodImplementation(object_getClass(dynWorld), selAll);
    if (mAll) list = ((id (*)(id, SEL))mAll)(dynWorld, selAll);
    
    if (!list) {
        Ivar iv = class_getInstanceVariable(object_getClass(dynWorld), "netBlockheads");
        if (iv) list = *(id*)((char*)dynWorld + ivar_getOffset(iv));
    }
    if (!list) return nil;

    SEL selCount = sel_registerName(SEL_COUNT);
    IMP mCount = class_getMethodImplementation(object_getClass(list), selCount);
    int count = mCount ? ((int (*)(id, SEL))mCount)(list, selCount) : 0;

    SEL selIdx = sel_registerName(SEL_OBJ_IDX);
    IMP mIdx = class_getMethodImplementation(object_getClass(list), selIdx);
    
    for (int i=0; i<count; i++) {
        id bh = mIdx ? ((ObjIdxFunc)mIdx)(list, selIdx, i) : nil;
        if (bh) {
            const char* bhName = Summon_GetBlockheadName(bh);
            if (bhName && strcasecmp(bhName, targetName)==0) {
                return bh;
            }
        }
    }
    return nil;
}

id Summon_Cmd_Hook(id self, SEL _cmd, id commandStr, id client) {
    const char* raw = Summon_GetStr(commandStr);
    if (!raw || strlen(raw) == 0) return Summon_Real_HandleCmd(self, _cmd, commandStr, client);

    char text[256]; strncpy(text, raw, 255); text[255] = 0;

    if (strncmp(text, "/spawn", 6) == 0) {
        id dynWorld = Summon_GetDynamicWorld(self);
        
        char buf[256]; strncpy(buf, text, 255);
        char *cmd = strtok(buf, " "), *sType = strtok(NULL, " "), *sQty = strtok(NULL, " "), *sPlayer = strtok(NULL, " "), *sBaby = strtok(NULL, " ");

        // FORCE NAME REQUIREMENT
        if (!sType || !sPlayer) { 
            Summon_Chat(self, "Help: /spawn <mob> <qty> <PLAYER_NAME> [baby]"); 
            return nil; 
        }
        
        // CHECK MOB TYPE
        int type = Summon_ParseType(sType);
        if (type == 0) {
            Summon_Chat(self, "Unknown Mob! List: dodo, dropbear, donkey, fish, shark, troll, scorpion, yak");
            return nil;
        }

        int qty = sQty ? atoi(sQty) : 1;
        if (qty > 50) qty = 50;
        
        // CHECK BABY (Arg 4)
        BOOL isAdult = 1;
        if (sBaby && strcasecmp(sBaby, "baby") == 0) {
            isAdult = 0;
        }

        // FIND PLAYER
        id bh = Summon_FindBlockhead(dynWorld, sPlayer);
        
        if (bh) {
            Ivar ivP = class_getInstanceVariable(object_getClass(bh), "pos");
            long long pos = *(long long*)((char*)bh + ivar_getOffset(ivP));
            SEL selS = sel_registerName(SEL_SPAWN_NPC);
            SpawnNPCFunc f = (SpawnNPCFunc)class_getMethodImplementation(object_getClass(dynWorld), selS);
            
            if (f && pos != 0) {
                for(int i=0; i<qty; i++) f(dynWorld, selS, pos, type, nil, isAdult, 0, nil);
                
                char msg[128]; 
                snprintf(msg, 128, "Spawned %d %s %s for %s", qty, (isAdult ? "Adult" : "Baby"), sType, sPlayer);
                Summon_Chat(self, msg);
            }
        } else {
            Summon_Chat(self, "Error: Player not found by that name.");
        }
        return nil;
    }
    return Summon_Real_HandleCmd(self, _cmd, commandStr, client);
}

static void* Summon_InitThread(void* arg) {
    sleep(1);
    Class cls = objc_getClass(SERVER_CLASS);
    if (cls) {
        Method m1 = class_getInstanceMethod(cls, sel_registerName(SEL_CMD));
        Summon_Real_HandleCmd = (CmdFunc)method_getImplementation(m1);
        method_setImplementation(m1, (IMP)Summon_Cmd_Hook);
        Method m2 = class_getInstanceMethod(cls, sel_registerName(SEL_CHAT));
        Summon_Real_SendChat = (ChatFunc)method_getImplementation(m2);
    }
    return NULL;
}

__attribute__((constructor)) static void Summon_Entry() {
    pthread_t t; pthread_create(&t, NULL, Summon_InitThread, NULL);
}
