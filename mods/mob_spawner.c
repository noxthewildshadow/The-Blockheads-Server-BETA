/*
 * ======================================================================================
 * * FEATURES:
 * - Spawn specific Dodo breeds (Gems, Ores, Blocks).
 * - Spawn specific Donkey/Unicorn breeds (Rainbow, Flying, Colors).
 * - Support for hostile mobs (Sharks, Scorpions, Cave Trolls).
 * - Force 'Baby' state for any mob.
 * - In-game Help menus.
 * * COMMANDS:
 * /spawn <mob> <qty> <player> [variant] [baby]
 * /help_dodo
 * /help_donkey
 * ======================================================================================
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
#include <objc/runtime.h>
#include <objc/message.h>

#ifndef nil
#define nil (id)0
#endif

// --- Configuration ---
#define SERVER_CLASS "BHServer"

// --- Selectors ---
#define SEL_CMD      "handleCommand:issueClient:"
#define SEL_CHAT     "sendChatMessage:sendToClients:"
#define SEL_LOAD_NPC "loadNPCAtPosition:type:saveDict:isAdult:wasPlaced:placedByClient:"
#define SEL_NUM_INT  "numberWithInt:"
#define SEL_DICT     "dictionaryWithObject:forKey:"
#define SEL_STR      "stringWithUTF8String:"
#define SEL_UTF8     "UTF8String"
#define SEL_ALLOC    "alloc"
#define SEL_INIT     "init"
#define SEL_RELEASE  "release"

// --- Mob IDs ---
enum MobType {
    MOB_DODO      = 1,
    MOB_DONKEY    = 3,
    MOB_FISH      = 4,
    MOB_SHARK     = 5,
    MOB_TROLL     = 6,
    MOB_SCORPION  = 7,
    MOB_YAK       = 8
};

// --- Dodo Breed Constants ---
#define DODO_STD        0
#define DODO_STONE      1
#define DODO_LIMESTONE  2
#define DODO_SANDSTONE  3
#define DODO_MARBLE     4
#define DODO_RED_MARBLE 5
#define DODO_LAPIS      6
#define DODO_DIRT       7
#define DODO_COMPOST    8
#define DODO_WOOD       9
#define DODO_GRAVEL     10
#define DODO_SAND       11
#define DODO_BLACK_SAND 12
#define DODO_GLASS      13
#define DODO_BLACK_GLASS 14
#define DODO_CLAY       15
#define DODO_BRICK      16
#define DODO_FLINT      17
#define DODO_COAL       18
#define DODO_OIL        19
#define DODO_FUEL       20
#define DODO_COPPER     21
#define DODO_TIN        22
#define DODO_IRON       23
#define DODO_GOLD       24
#define DODO_TITANIUM   25
#define DODO_PLATINUM   26
#define DODO_AMETHYST   27
#define DODO_SAPPHIRE   28
#define DODO_EMERALD    29
#define DODO_RUBY       30
#define DODO_DIAMOND    31
#define DODO_RAINBOW    32

// --- Donkey/Unicorn Breed Constants ---
#define DONK_STD            0
#define DONK_RAINBOW        11
#define DONK_UNI_GREY       12
#define DONK_UNI_BROWN      13
#define DONK_UNI_BLACK      14
#define DONK_UNI_BLUE       15
#define DONK_UNI_GREEN      16
#define DONK_UNI_YELLOW     17
#define DONK_UNI_ORANGE     18
#define DONK_UNI_RED        19
#define DONK_UNI_PURPLE     20
#define DONK_UNI_PINK       21
#define DONK_UNI_WHITE      22
#define DONK_UNI_RAINBOW    23

// --- Function Types ---
typedef id   (*CmdFunc)(id, SEL, id, id);
typedef void (*ChatFunc)(id, SEL, id, id);
typedef id   (*SpawnNPCFunc)(id, SEL, long long, int, id, BOOL, BOOL, id);
typedef id   (*StrFactoryFunc)(id, SEL, const char*);
typedef id   (*NumFactoryFunc)(id, SEL, int);
typedef id   (*DictFactoryFunc)(id, SEL, id, id);
typedef int  (*CountFunc)(id, SEL);
typedef id   (*ObjIdxFunc)(id, SEL, unsigned long);
typedef const char* (*UTF8Func)(id, SEL);
// Memory Types
typedef id (*AllocFunc)(id, SEL);
typedef id (*InitFunc)(id, SEL);
typedef void (*ReleaseFunc)(id, SEL);

// --- Globals ---
static CmdFunc  Real_HandleCmd = NULL;
static ChatFunc Real_SendChat = NULL;

// --- Memory Helpers ---
static id CreatePool() {
    Class cls = objc_getClass("NSAutoreleasePool");
    SEL sAlloc = sel_registerName(SEL_ALLOC);
    SEL sInit = sel_registerName(SEL_INIT);
    AllocFunc fAlloc = (AllocFunc)method_getImplementation(class_getClassMethod(cls, sAlloc));
    InitFunc fInit = (InitFunc)method_getImplementation(class_getInstanceMethod(cls, sInit));
    return fInit(fAlloc((id)cls, sAlloc), sInit);
}

static void ReleasePool(id pool) {
    if(!pool) return;
    SEL sRel = sel_registerName(SEL_RELEASE);
    ReleaseFunc fRel = (ReleaseFunc)method_getImplementation(class_getInstanceMethod(object_getClass(pool), sRel));
    fRel(pool, sRel);
}

// --- Helpers ---

static id MkStr(const char* text) {
    if (!text) return nil;
    Class cls = objc_getClass("NSString");
    SEL sel = sel_registerName(SEL_STR);
    StrFactoryFunc f = (StrFactoryFunc)method_getImplementation(class_getClassMethod(cls, sel));
    return f ? f((id)cls, sel, text) : nil;
}

static const char* GetCStr(id strObj) {
    if (!strObj) return "";
    SEL sel = sel_registerName(SEL_UTF8);
    UTF8Func f = (UTF8Func)class_getMethodImplementation(object_getClass(strObj), sel);
    return f ? f(strObj, sel) : "";
}

static void SendChat(id server, const char* msg) {
    if (server && Real_SendChat) {
        Real_SendChat(server, sel_registerName(SEL_CHAT), MkStr(msg), nil);
    }
}

static id MkGeneDict(int breedID) {
    if (breedID < 0) return nil;
    
    Class clsNum = objc_getClass("NSNumber");
    SEL selNum = sel_registerName(SEL_NUM_INT);
    NumFactoryFunc fNum = (NumFactoryFunc)method_getImplementation(class_getClassMethod(clsNum, selNum));
    id val = fNum((id)clsNum, selNum, breedID);

    id key = MkStr("breed");

    Class clsDict = objc_getClass("NSDictionary");
    SEL selDict = sel_registerName(SEL_DICT);
    DictFactoryFunc fDict = (DictFactoryFunc)method_getImplementation(class_getClassMethod(clsDict, selDict));
    
    return fDict((id)clsDict, selDict, val, key);
}

// --- Parsers ---

static int ParseDodoBreed(const char* name) {
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

static int ParseDonkeyBreed(const char* name) {
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

// --- Core Logic ---

static id FindPlayer(id dynWorld, const char* name) {
    if (!dynWorld) return nil;
    id targetStr = MkStr(name);
    
    id list = nil;
    Ivar iv = class_getInstanceVariable(object_getClass(dynWorld), "netBlockheads");
    if (iv) list = *(id*)((char*)dynWorld + ivar_getOffset(iv));
    
    if (!list) return nil;
    
    SEL sCount = sel_registerName("count");
    SEL sIdx = sel_registerName("objectAtIndex:");
    SEL sComp = sel_registerName("caseInsensitiveCompare:");
    
    CountFunc fCount = (CountFunc)class_getMethodImplementation(object_getClass(list), sCount);
    ObjIdxFunc fIdx = (ObjIdxFunc)class_getMethodImplementation(object_getClass(list), sIdx);
    
    int count = fCount(list, sCount);
    for(int i=0; i<count; i++) {
        id bh = fIdx(list, sIdx, i);
        if(bh) {
            id bName = nil;
            Ivar ivN = class_getInstanceVariable(object_getClass(bh), "clientName");
            if(ivN) bName = *(id*)((char*)bh + ivar_getOffset(ivN));
            
            if(bName) {
                long (*fC)(id, SEL, id) = (long (*)(id, SEL, id))class_getMethodImplementation(object_getClass(bName), sComp);
                if(fC(bName, sComp, targetStr) == 0) return bh;
            }
        }
    }
    return nil;
}

static void SpawnAction(id dynWorld, id player, int mobID, int qty, int breedID, bool isBaby) {
    Ivar ivP = class_getInstanceVariable(object_getClass(player), "pos");
    long long pos = ivP ? *(long long*)((char*)player + ivar_getOffset(ivP)) : 0;
    if (pos == 0) return;

    SEL sel = sel_registerName(SEL_LOAD_NPC);
    Method m = class_getInstanceMethod(object_getClass(dynWorld), sel);
    
    if (m) {
        SpawnNPCFunc f = (SpawnNPCFunc)method_getImplementation(m);
        id saveDict = MkGeneDict(breedID);
        for(int i=0; i<qty; i++) {
            f(dynWorld, sel, pos, mobID, saveDict, !isBaby, 0, nil);
        }
    }
}

// --- Help Printers ---

static void PrintDodoHelp(id self) {
    SendChat(self, ">> DODO BREEDS LIST:");
    SendChat(self, "- Resources: titanium, platinum, gold, iron, copper, tin, oil, coal, fuel.");
    SendChat(self, "- Gems: diamond, ruby, emerald, sapphire, amethyst.");
    SendChat(self, "- Blocks: rainbow, glass, stone, dirt, wood, marble, lapis, flint, clay.");
    SendChat(self, "Usage: /spawn dodo 1 PLAYER_NAME <breed>");
}

static void PrintDonkeyHelp(id self) {
    SendChat(self, ">> DONKEY / UNICORN BREEDS LIST:");
    SendChat(self, "- Unicorns: unicorn, unicorn_white, unicorn_black, unicorn_pink, unicorn_blue.");
    SendChat(self, "- Special: rainbow (Standard donkey, rainbow colors).");
    SendChat(self, "Usage: /spawn donkey 1 PLAYER_NAME <breed>");
}

// --- Command Hook ---

id Hook_HandleCmd(id self, SEL _cmd, id cmdStr, id client) {
    const char* raw = GetCStr(cmdStr);
    if (!raw) return Real_HandleCmd(self, _cmd, cmdStr, client);
    
    id pool = CreatePool(); // Inicio gestión de memoria

    char text[256]; strncpy(text, raw, 255); text[255] = 0;

    // Help
    if (strcasecmp(text, "/help_dodo") == 0) {
        PrintDodoHelp(self); 
        ReleasePool(pool);
        return nil;
    }
    if (strcasecmp(text, "/help_donkey") == 0) {
        PrintDonkeyHelp(self); 
        ReleasePool(pool);
        return nil;
    }

    // Spawn
    if (strncmp(text, "/spawn", 6) == 0) {
        id world = nil;
        object_getInstanceVariable(self, "world", (void**)&world);
        id dynWorld = nil;
        if (world) object_getInstanceVariable(world, "dynamicWorld", (void**)&dynWorld);
        
        if (!dynWorld) { 
            SendChat(self, "Error: World system not ready."); 
            ReleasePool(pool);
            return nil; 
        }

        char *saveptr; // Puntero para strtok_r
        char *t = strtok_r(text, " ", &saveptr);
        char *sID = strtok_r(NULL, " ", &saveptr);
        char *sQty = strtok_r(NULL, " ", &saveptr);
        char *sPl = strtok_r(NULL, " ", &saveptr);
        char *sVar = strtok_r(NULL, " ", &saveptr); 
        char *sBaby = strtok_r(NULL, " ", &saveptr);

        if (!sID || !sPl) {
            SendChat(self, "Usage: /spawn <mob> <qty> <player> [variant] [baby]");
            SendChat(self, "Type /help_dodo or /help_donkey for variants.");
            ReleasePool(pool);
            return nil;
        }

        id target = FindPlayer(dynWorld, sPl);
        if (!target) { 
            SendChat(self, "Player not found."); 
            ReleasePool(pool);
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
            if (sVar) breedID = ParseDodoBreed(sVar);
        }
        else if (strcasecmp(sID, "donkey") == 0 || strcasecmp(sID, "unicorn") == 0) {
            mobID = MOB_DONKEY;
            if (strcasecmp(sID, "unicorn") == 0 && !sVar) breedID = DONK_UNI_RAINBOW;
            else if (sVar) breedID = ParseDonkeyBreed(sVar);
        }
        else if (strcasecmp(sID, "shark") == 0) mobID = MOB_SHARK;
        else if (strcasecmp(sID, "fish") == 0) mobID = MOB_FISH;
        else if (strcasecmp(sID, "yak") == 0) mobID = MOB_YAK;
        else if (strcasecmp(sID, "scorpion") == 0) mobID = MOB_SCORPION;
        else if (strcasecmp(sID, "troll") == 0) mobID = MOB_TROLL;
        else if (strcasecmp(sID, "dropbear") == 0) mobID = 2;

        if (mobID > 0) {
            SpawnAction(dynWorld, target, mobID, qty, breedID, isBaby);
            char msg[128];
            snprintf(msg, 128, ">> Summoned %d %s [%s] for %s.", qty, sID, sVar ? sVar : "Standard", sPl);
            SendChat(self, msg);
        } else {
            SendChat(self, "Unknown Mob.");
        }
        
        ReleasePool(pool); // Limpieza final
        return nil;
    }

    ReleasePool(pool); // Limpieza si no fue comando nuestro
    return Real_HandleCmd(self, _cmd, cmdStr, client);
}

// --- Initialization ---

static void* InitThread(void* arg) {
    sleep(1);
    Class cls = objc_getClass(SERVER_CLASS);
    if (cls) {
        Real_HandleCmd = (CmdFunc)method_getImplementation(class_getInstanceMethod(cls, sel_registerName(SEL_CMD)));
        Real_SendChat = (ChatFunc)method_getImplementation(class_getInstanceMethod(cls, sel_registerName(SEL_CHAT)));
        method_setImplementation(class_getInstanceMethod(cls, sel_registerName(SEL_CMD)), (IMP)Hook_HandleCmd);
    }
    return NULL;
}

__attribute__((constructor)) static void Entry() {
    pthread_t t; pthread_create(&t, NULL, InitThread, NULL);
}
