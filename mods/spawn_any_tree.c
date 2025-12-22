/*
 * Tree Generator (FULL - NO OMISSIONS)
 * /tree <type>
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <objc/runtime.h>
#include <objc/message.h>

#define TG_SERVER_CLASS "BHServer"
#define TG_WORLD_CLASS  "World"
#define TG_GEM_CLASS    "GemTree"
#define TG_BAIT_ITEM    1024 

#define SEL_FILL      "fillTile:atPos:withType:dataA:dataB:placedByClient:saveDict:placedByBlockhead:placedByClientName:"
#define SEL_CMD       "handleCommand:issueClient:"
#define SEL_CHAT      "sendChatMessage:sendToClients:"
#define SEL_UTF8      "UTF8String"
#define SEL_STR       "stringWithUTF8String:"
#define SEL_ALLOC     "alloc"
#define SEL_LOAD_TREE "loadTreeAtPosition:type:maxHeight:growthRate:adultTree:adultMaxAge:"
#define SEL_INIT_GEM  "initWithWorld:dynamicWorld:atPosition:cache:treeDensityNoiseFunction:seasonOffsetNoiseFunction:gemTreeType:"

enum TreeType {
    TREE_APPLE = 1, TREE_MANGO = 2, TREE_MAPLE = 3, TREE_PINE = 4,
    TREE_CACTUS = 5, TREE_COCONUT = 6, TREE_ORANGE = 7, TREE_CHERRY = 8,
    TREE_COFFEE = 9, TREE_LIME = 10,
    TREE_GEM_AMETHYST = 11, TREE_GEM_SAPPHIRE = 12, TREE_GEM_EMERALD = 13,
    TREE_GEM_RUBY = 14, TREE_GEM_DIAMOND = 15
};

typedef struct { int x; int y; } IntPair;
typedef void (*FillTileFunc)(id, SEL, void*, IntPair, int, uint16_t, uint16_t, id, id, id, id);
typedef id   (*CmdFunc)(id, SEL, id, id);
typedef void (*ChatFunc)(id, SEL, id, id);
typedef const char* (*StrFunc)(id, SEL);
typedef id   (*StringFactoryFunc)(id, SEL, const char*);
typedef id   (*AllocFunc)(id, SEL);
typedef void (*LoadTreeFunc)(id, SEL, IntPair, int, short, short, BOOL, float);
typedef id   (*InitGemFunc)(id, SEL, id, id, IntPair, id, id, id, int);

static FillTileFunc TreeGen_Real_FillTile = NULL;
static CmdFunc      TreeGen_Real_HandleCmd = NULL;
static ChatFunc     TreeGen_Real_SendChat = NULL;
static bool TreeGen_Active = false;
static int  TreeGen_Type = 0;   
static bool TreeGen_IsGem = false;

static const char* TG_GetStr(id strObj) {
    if (!strObj) return "";
    SEL sel = sel_registerName(SEL_UTF8);
    StrFunc f = (StrFunc)class_getMethodImplementation(object_getClass(strObj), sel);
    return f ? f(strObj, sel) : "";
}

static id TG_AllocStr(const char* text) {
    Class cls = objc_getClass("NSString");
    SEL sel = sel_registerName(SEL_STR);
    StringFactoryFunc f = (StringFactoryFunc)method_getImplementation(class_getClassMethod(cls, sel));
    return f ? f((id)cls, sel, text) : nil;
}

static void TG_Chat(id server, const char* msg) {
    if (server && TreeGen_Real_SendChat) {
        TreeGen_Real_SendChat(server, sel_registerName(SEL_CHAT), TG_AllocStr(msg), nil);
    }
}

static id TG_GetIvar(id obj, const char* name) {
    if (!obj) return nil;
    Ivar iv = class_getInstanceVariable(object_getClass(obj), name);
    if (iv) return *(id*)((char*)obj + ivar_getOffset(iv));
    return nil;
}

void TG_SpawnNormalTree(id dynWorld, IntPair pos, int type) {
    SEL sel = sel_registerName(SEL_LOAD_TREE);
    if (class_getInstanceMethod(object_getClass(dynWorld), sel)) {
        LoadTreeFunc f = (LoadTreeFunc)method_getImplementation(class_getInstanceMethod(object_getClass(dynWorld), sel));
        f(dynWorld, sel, pos, type, 20, 20, 1, 100.0f);
    }
}

void TG_SpawnGemTree(id world, id dynWorld, IntPair pos, int gemType) {
    Class clsGem = objc_getClass(TG_GEM_CLASS);
    if (!clsGem) return;
    id noise1 = TG_GetIvar(dynWorld, "treeDensityNoiseFunction");
    id noise2 = TG_GetIvar(dynWorld, "seasonOffsetNoiseFunction");
    id cache  = TG_GetIvar(dynWorld, "cache");
    if (!noise1 || !noise2) return; 

    SEL sAlloc = sel_registerName(SEL_ALLOC);
    AllocFunc fAlloc = (AllocFunc)method_getImplementation(class_getClassMethod(clsGem, sAlloc));
    id rawTree = fAlloc((id)clsGem, sAlloc);
    if (!rawTree) return;

    SEL sInit = sel_registerName(SEL_INIT_GEM);
    InitGemFunc fInit = (InitGemFunc)method_getImplementation(class_getInstanceMethod(clsGem, sInit));
    fInit(rawTree, sInit, world, dynWorld, pos, cache, noise1, noise2, gemType);
}

void TreeGen_Hook_FillTile(id self, SEL _cmd, void* tilePtr, IntPair pos, int type, uint16_t dataA, uint16_t dataB, id client, id saveDict, id bh, id clientName) {
    if (TreeGen_Active && type == TG_BAIT_ITEM) {
        id dynWorld = TG_GetIvar(self, "dynamicWorld");
        if (dynWorld) {
            if (TreeGen_IsGem) TG_SpawnGemTree(self, dynWorld, pos, TreeGen_Type);
            else TG_SpawnNormalTree(dynWorld, pos, TreeGen_Type);
        }
        return; 
    }
    if (TreeGen_Real_FillTile) {
        TreeGen_Real_FillTile(self, _cmd, tilePtr, pos, type, dataA, dataB, client, saveDict, bh, clientName);
    }
}

id TreeGen_Cmd_Hook(id self, SEL _cmd, id commandStr, id client) {
    const char* raw = TG_GetStr(commandStr);
    if (!raw) return TreeGen_Real_HandleCmd(self, _cmd, commandStr, client);
    char text[256]; strncpy(text, raw, 255); text[255] = 0;

    if (strncmp(text, "/tree", 5) == 0) {
        char* token = strtok(text, " ");
        char* sType = strtok(NULL, " ");

        if (!sType || strcasecmp(sType, "off") == 0) {
            TreeGen_Active = false;
            TG_Chat(self, ">> [Tree] Disabled.");
            return nil;
        }

        TreeGen_Active = true;
        TreeGen_IsGem = false;

        // PARSER COMPLETO
        if (strcasecmp(sType, "apple") == 0)       TreeGen_Type = TREE_APPLE;
        else if (strcasecmp(sType, "mango") == 0)  TreeGen_Type = TREE_MANGO;
        else if (strcasecmp(sType, "maple") == 0)  TreeGen_Type = TREE_MAPLE;
        else if (strcasecmp(sType, "pine") == 0)   TreeGen_Type = TREE_PINE;
        else if (strcasecmp(sType, "cactus") == 0) TreeGen_Type = TREE_CACTUS;
        else if (strcasecmp(sType, "coco") == 0)   TreeGen_Type = TREE_COCONUT;
        else if (strcasecmp(sType, "coconut") == 0)TreeGen_Type = TREE_COCONUT;
        else if (strcasecmp(sType, "orange") == 0) TreeGen_Type = TREE_ORANGE;
        else if (strcasecmp(sType, "cherry") == 0) TreeGen_Type = TREE_CHERRY;
        else if (strcasecmp(sType, "coffee") == 0) TreeGen_Type = TREE_COFFEE;
        else if (strcasecmp(sType, "lime") == 0)   TreeGen_Type = TREE_LIME;
        else {
            TreeGen_IsGem = true;
            if (strcasecmp(sType, "amethyst") == 0)      TreeGen_Type = TREE_GEM_AMETHYST;
            else if (strcasecmp(sType, "sapphire") == 0) TreeGen_Type = TREE_GEM_SAPPHIRE;
            else if (strcasecmp(sType, "emerald") == 0)  TreeGen_Type = TREE_GEM_EMERALD;
            else if (strcasecmp(sType, "ruby") == 0)     TreeGen_Type = TREE_GEM_RUBY;
            else if (strcasecmp(sType, "diamond") == 0)  TreeGen_Type = TREE_GEM_DIAMOND;
            else {
                TreeGen_Active = false;
                TG_Chat(self, ">> [Error] Unknown Tree Type.");
                return nil;
            }
        }

        char msg[128];
        snprintf(msg, 128, ">> [Tree] Selected: %s. Place Stone to plant.", sType);
        TG_Chat(self, msg);
        return nil;
    }
    return TreeGen_Real_HandleCmd(self, _cmd, commandStr, client);
}

static void* TreeGen_InitThread(void* arg) {
    sleep(1);
    Class clsWorld = objc_getClass(TG_WORLD_CLASS);
    if (clsWorld) {
        Method m = class_getInstanceMethod(clsWorld, sel_registerName(SEL_FILL));
        if (m) {
            TreeGen_Real_FillTile = (FillTileFunc)method_getImplementation(m);
            method_setImplementation(m, (IMP)TreeGen_Hook_FillTile);
        }
    }
    Class clsServer = objc_getClass(TG_SERVER_CLASS);
    if (clsServer) {
        Method mCmd = class_getInstanceMethod(clsServer, sel_registerName(SEL_CMD));
        TreeGen_Real_HandleCmd = (CmdFunc)method_getImplementation(mCmd);
        method_setImplementation(mCmd, (IMP)TreeGen_Cmd_Hook);
        Method mChat = class_getInstanceMethod(clsServer, sel_registerName(SEL_CHAT));
        TreeGen_Real_SendChat = (ChatFunc)method_getImplementation(mChat);
    }
    return NULL;
}

__attribute__((constructor)) static void TreeGen_Entry() {
    pthread_t t; pthread_create(&t, NULL, TreeGen_InitThread, NULL);
}
