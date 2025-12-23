/*
 * Script: Mob Spawner
 * Command: /spawn <mob> <qty> <player> [variant] [baby]
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
#include <stdint.h>
#include <objc/runtime.h>
#include <objc/message.h>

typedef struct { int x; int y; } MS_IntPair;

// --- STATIC GLOBALS (Isolation) ---
static id (*MS_Real_HandleCmd)(id, SEL, id, id) = NULL;
static void (*MS_Real_SendChat)(id, SEL, id, id) = NULL;

// --- MOBS ---
enum MobType {
    MOB_DODO = 1, MOB_DONKEY = 3, MOB_FISH = 4, MOB_SHARK = 5,
    MOB_TROLL = 6, MOB_SCORPION = 7, MOB_YAK = 8
};

// Dodo Variants
#define DODO_STD 0
#define DODO_STONE 1
#define DODO_LIMESTONE 2
#define DODO_SANDSTONE 3
#define DODO_MARBLE 4
#define DODO_RED_MARBLE 5
#define DODO_LAPIS 6
#define DODO_DIRT 7
#define DODO_COMPOST 8
#define DODO_WOOD 9
#define DODO_GRAVEL 10
#define DODO_SAND 11
#define DODO_BLACK_SAND 12
#define DODO_GLASS 13
#define DODO_BLACK_GLASS 14
#define DODO_CLAY 15
#define DODO_BRICK 16
#define DODO_FLINT 17
#define DODO_COAL 18
#define DODO_OIL 19
#define DODO_FUEL 20
#define DODO_COPPER 21
#define DODO_TIN 22
#define DODO_IRON 23
#define DODO_GOLD 24
#define DODO_TITANIUM 25
#define DODO_PLATINUM 26
#define DODO_AMETHYST 27
#define DODO_SAPPHIRE 28
#define DODO_EMERALD 29
#define DODO_RUBY 30
#define DODO_DIAMOND 31
#define DODO_RAINBOW 32

// Donkey Variants
#define DONK_STD 0
#define DONK_RAINBOW 11
#define DONK_UNI_GREY 12
#define DONK_UNI_BROWN 13
#define DONK_UNI_BLACK 14
#define DONK_UNI_BLUE 15
#define DONK_UNI_GREEN 16
#define DONK_UNI_YELLOW 17
#define DONK_UNI_ORANGE 18
#define DONK_UNI_RED 19
#define DONK_UNI_PURPLE 20
#define DONK_UNI_PINK 21
#define DONK_UNI_WHITE 22
#define DONK_UNI_RAINBOW 23

// --- HELPERS ---
static id MS_AllocStr(const char* text) {
    if (!text) return nil;
    Class cls = objc_getClass("NSString");
    SEL sel = sel_registerName("stringWithUTF8String:");
    id (*f)(id, SEL, const char*) = (void*)method_getImplementation(class_getClassMethod(cls, sel));
    return f ? f((id)cls, sel, text) : nil;
}

static const char* MS_GetCStr(id strObj) {
    if (!strObj) return "";
    SEL sel = sel_registerName("UTF8String");
    const char* (*f)(id, SEL) = (void*)class_getMethodImplementation(object_getClass(strObj), sel);
    return f ? f(strObj, sel) : "";
}

static void MS_SendChat(id server, const char* msg) {
    if (server && MS_Real_SendChat) {
        MS_Real_SendChat(server, sel_registerName("sendChatMessage:sendToClients:"), MS_AllocStr(msg), nil);
    }
}

static id MS_MkGeneDict(int breedID) {
    if (breedID < 0) return nil;
    Class clsNum = objc_getClass("NSNumber");
    id (*fNum)(id, SEL, int) = (void*)method_getImplementation(class_getClassMethod(clsNum, sel_registerName("numberWithInt:")));
    id val = fNum((id)clsNum, sel_registerName("numberWithInt:"), breedID);
    
    id key = MS_AllocStr("breed");
    Class clsDict = objc_getClass("NSDictionary");
    id (*fDict)(id, SEL, id, id) = (void*)method_getImplementation(class_getClassMethod(clsDict, sel_registerName("dictionaryWithObject:forKey:")));
    return fDict((id)clsDict, sel_registerName("dictionaryWithObject:forKey:"), val, key);
}

// --- PARSERS ---
static int ParseDodo(const char* name) {
    if (!name) return -1;
    if (strcasecmp(name, "titanium") == 0) return DODO_TITANIUM;
    if (strcasecmp(name, "platinum") == 0) return DODO_PLATINUM;
    if (strcasecmp(name, "gold") == 0)      return DODO_GOLD;
    if (strcasecmp(name, "iron") == 0)      return DODO_IRON;
    if (strcasecmp(name, "copper") == 0)    return DODO_COPPER;
    if (strcasecmp(name, "tin") == 0)       return DODO_TIN;
    if (strcasecmp(name, "coal") == 0)      return DODO_COAL;
    if (strcasecmp(name, "oil") == 0)       return DODO_OIL;
    if (strcasecmp(name, "fuel") == 0)      return DODO_FUEL;
    if (strcasecmp(name, "diamond") == 0)   return DODO_DIAMOND;
    if (strcasecmp(name, "ruby") == 0)      return DODO_RUBY;
    if (strcasecmp(name, "emerald") == 0)   return DODO_EMERALD;
    if (strcasecmp(name, "sapphire") == 0)  return DODO_SAPPHIRE;
    if (strcasecmp(name, "amethyst") == 0)  return DODO_AMETHYST;
    if (strcasecmp(name, "rainbow") == 0)   return DODO_RAINBOW;
    if (strcasecmp(name, "glass") == 0)     return DODO_GLASS;
    if (strcasecmp(name, "stone") == 0)     return DODO_STONE;
    if (strcasecmp(name, "dirt") == 0)      return DODO_DIRT;
    if (strcasecmp(name, "wood") == 0)      return DODO_WOOD;
    if (strcasecmp(name, "ice") == 0)       return DODO_GLASS;
    if (strcasecmp(name, "lapis") == 0)     return DODO_LAPIS;
    if (strcasecmp(name, "red_marble") == 0) return DODO_RED_MARBLE;
    if (strcasecmp(name, "marble") == 0)    return DODO_MARBLE;
    if (strcasecmp(name, "sand") == 0)      return DODO_SAND;
    if (strcasecmp(name, "flint") == 0)     return DODO_FLINT;
    if (strcasecmp(name, "clay") == 0)      return DODO_CLAY;
    return -1;
}

static int ParseDonkey(const char* name) {
    if (!name) return -1;
    if (strcasecmp(name, "rainbow") == 0) return DONK_RAINBOW;
    if (strcasecmp(name, "unicorn") == 0)         return DONK_UNI_RAINBOW;
    if (strcasecmp(name, "unicorn_rainbow") == 0) return DONK_UNI_RAINBOW;
    if (strcasecmp(name, "unicorn_white") == 0)   return DONK_UNI_WHITE;
    if (strcasecmp(name, "unicorn_black") == 0)   return DONK_UNI_BLACK;
    if (strcasecmp(name, "unicorn_pink") == 0)    return DONK_UNI_PINK;
    if (strcasecmp(name, "unicorn_red") == 0)     return DONK_UNI_RED;
    if (strcasecmp(name, "unicorn_blue") == 0)    return DONK_UNI_BLUE;
    if (strcasecmp(name, "unicorn_green") == 0)   return DONK_UNI_GREEN;
    if (strcasecmp(name, "unicorn_yellow") == 0)  return DONK_UNI_YELLOW;
    if (strcasecmp(name, "unicorn_purple") == 0)  return DONK_UNI_PURPLE;
    return -1;
}

// --- LOGIC ---
static id MS_FindPlayer(id dynWorld, const char* name) {
    if (!dynWorld || !name) return nil;
    id targetStr = MS_AllocStr(name);
    
    id list = nil;
    Ivar iv = class_getInstanceVariable(object_getClass(dynWorld), "netBlockheads");
    if (iv) list = *(id*)((char*)dynWorld + ivar_getOffset(iv));
    if (!list) return nil;
    
    SEL sCount = sel_registerName("count");
    SEL sIdx = sel_registerName("objectAtIndex:");
    SEL sComp = sel_registerName("caseInsensitiveCompare:");
    
    int (*fCount)(id, SEL) = (void*)class_getMethodImplementation(object_getClass(list), sCount);
    id (*fIdx)(id, SEL, unsigned long) = (void*)class_getMethodImplementation(object_getClass(list), sIdx);
    
    if (!fCount || !fIdx) return nil;

    int count = fCount(list, sCount);
    for(int i=0; i<count; i++) {
        id bh = fIdx(list, sIdx, i);
        if(bh) {
            id bName = nil;
            Ivar ivName = class_getInstanceVariable(object_getClass(bh), "_clientName");
            if (ivName) bName = *(id*)((char*)bh + ivar_getOffset(ivName));
            
            if (!bName) {
                ivName = class_getInstanceVariable(object_getClass(bh), "clientName");
                if (ivName) bName = *(id*)((char*)bh + ivar_getOffset(ivName));
            }
            
            if(bName) {
                long (*fC)(id, SEL, id) = (void*)class_getMethodImplementation(object_getClass(bName), sComp);
                if(fC && fC(bName, sComp, targetStr) == 0) return bh;
            }
        }
    }
    return nil;
}

static void MS_SpawnAction(id dynWorld, id player, int mobID, int qty, int breedID, bool isBaby) {
    MS_IntPair pos = {0,0};
    void* posPtr = NULL;
    object_getInstanceVariable(player, "_pos", &posPtr);
    if (!posPtr) object_getInstanceVariable(player, "pos", &posPtr);
    if (posPtr) pos = *(MS_IntPair*)posPtr;
    else return;

    SEL sel = sel_registerName("loadNPCAtPosition:type:saveDict:isAdult:wasPlaced:placedByClient:");
    Method m = class_getInstanceMethod(object_getClass(dynWorld), sel);
    
    if (m) {
        id (*f)(id, SEL, MS_IntPair, int, id, BOOL, BOOL, id) = (void*)method_getImplementation(m);
        id saveDict = MS_MkGeneDict(breedID);
        for(int i=0; i<qty; i++) {
            f(dynWorld, sel, pos, mobID, saveDict, !isBaby, 0, nil);
        }
    }
}

// --- HOOK ---
static id Hook_MobCmd(id self, SEL _cmd, id cmdStr, id client) {
    const char* raw = MS_GetCStr(cmdStr);
    if (!raw) return MS_Real_HandleCmd(self, _cmd, cmdStr, client);
    
    char text[256]; strncpy(text, raw, 255); text[255] = 0;

    if (strcasecmp(text, "/help_dodo") == 0) {
        PrintDodoHelp(self); return nil;
    }
    if (strcasecmp(text, "/help_donkey") == 0) {
        PrintDonkeyHelp(self); return nil;
    }

    if (strncmp(text, "/spawn", 6) == 0) {
        id world = nil;
        object_getInstanceVariable(self, "world", (void**)&world);
        id dynWorld = nil;
        if (world) object_getInstanceVariable(world, "dynamicWorld", (void**)&dynWorld);
        
        if (!dynWorld) { 
            MS_SendChat(self, "[Mob] Error: World not ready."); 
            return nil; 
        }

        char *saveptr; 
        char *t = strtok_r(text, " ", &saveptr);
        char *sID = strtok_r(NULL, " ", &saveptr);
        char *sQty = strtok_r(NULL, " ", &saveptr);
        char *sPl = strtok_r(NULL, " ", &saveptr);
        char *sVar = strtok_r(NULL, " ", &saveptr); 
        char *sBaby = strtok_r(NULL, " ", &saveptr);

        if (!sID || !sPl) {
            MS_SendChat(self, "Usage: /spawn <mob> <qty> <player> [variant] [baby]");
            return nil;
        }

        id target = MS_FindPlayer(dynWorld, sPl);
        if (!target) { 
            MS_SendChat(self, "Player not found."); 
            return nil; 
        }

        int qty = sQty ? atoi(sQty) : 1;
        if (qty > 20) qty = 20;

        int mobID = 0;
        int breedID = -1;
        bool isBaby = false;

        if (sBaby && strcasecmp(sBaby, "baby") == 0) isBaby = true;
        if (sVar && strcasecmp(sVar, "baby") == 0) { isBaby = true; sVar = NULL; }

        if (strcasecmp(sID, "dodo") == 0) {
            mobID = MOB_DODO;
            if (sVar) breedID = ParseDodo(sVar);
        }
        else if (strcasecmp(sID, "donkey") == 0 || strcasecmp(sID, "unicorn") == 0) {
            mobID = MOB_DONKEY;
            if (strcasecmp(sID, "unicorn") == 0 && !sVar) breedID = DONK_UNI_RAINBOW;
            else if (sVar) breedID = ParseDonkey(sVar);
        }
        else if (strcasecmp(sID, "shark") == 0) mobID = MOB_SHARK;
        else if (strcasecmp(sID, "fish") == 0) mobID = MOB_FISH;
        else if (strcasecmp(sID, "yak") == 0) mobID = MOB_YAK;
        else if (strcasecmp(sID, "scorpion") == 0) mobID = MOB_SCORPION;
        else if (strcasecmp(sID, "troll") == 0) mobID = MOB_TROLL;
        else if (strcasecmp(sID, "dropbear") == 0) mobID = 2; // Fixed ID from context

        if (mobID > 0) {
            MS_SpawnAction(dynWorld, target, mobID, qty, breedID, isBaby);
            char msg[128];
            snprintf(msg, 128, ">> Summoned %d %s for %s.", qty, sID, sPl);
            MS_SendChat(self, msg);
        } else {
            MS_SendChat(self, "Unknown Mob.");
        }
        
        return nil;
    }

    return MS_Real_HandleCmd(self, _cmd, cmdStr, client);
}

// --- INIT ---
static void* Mob_Init(void* arg) {
    sleep(1);
    Class clsSrv = objc_getClass("BHServer");
    if (clsSrv) {
        Method mC = class_getInstanceMethod(clsSrv, sel_registerName("handleCommand:issueClient:"));
        Method mT = class_getInstanceMethod(clsSrv, sel_registerName("sendChatMessage:sendToClients:"));
        MS_Real_HandleCmd = (void*)method_getImplementation(mC);
        MS_Real_SendChat  = (void*)method_getImplementation(mT);
        method_setImplementation(mC, (IMP)Hook_MobCmd);
    }
    return NULL;
}

__attribute__((constructor)) static void Mob_Entry() {
    pthread_t t; pthread_create(&t, NULL, Mob_Init, NULL);
}
