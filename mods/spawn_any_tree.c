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

// --- CONFIG ---
#define TREE_SERVER_CLASS "BHServer"
#define TREE_WORLD_CLASS  "World"
#define TREE_GEM_CLASS    "GemTree"

// --- TYPES ---
// CRITICAL: Must match game structure to avoid Segfault
typedef struct { int x; int y; } IntPair;

// --- IMP SIGNATURES (Based on Reference) ---

// fillTile...
typedef void (*TREE_FillFunc)(id, SEL, void*, IntPair, int, uint16_t, uint16_t, id, id, id, id);

// handleCommand...
typedef id (*TREE_CmdFunc)(id, SEL, id, id);

// sendChatMessage...
typedef void (*TREE_ChatFunc)(id, SEL, id, BOOL, id);

// loadTreeAtPosition... (For Normal Trees)
typedef void (*TREE_LoadFunc)(id, SEL, IntPair, int, short, short, BOOL, float);

// initWithWorld... (For Gem Trees)
typedef id (*TREE_InitGemFunc)(id, SEL, id, id, IntPair, id, id, id, int);

// Alloc/Init Utils
typedef id (*TREE_AllocFunc)(id, SEL);
typedef id (*TREE_StrFunc)(id, SEL, const char*);
typedef const char* (*TREE_Utf8Func)(id, SEL);

// --- GLOBALS ---
static TREE_FillFunc Real_TREE_Fill = NULL;
static TREE_CmdFunc  Real_TREE_Cmd = NULL;
static TREE_ChatFunc Real_TREE_Chat = NULL;

static bool g_TREE_Active = false;
static int  g_TREE_Type = 0;
static bool g_TREE_IsGem = false;
static char g_TREE_Name[64] = {0};

// --- UTILS ---

// Helper to get Ivar safely (Pointer Arithmetic)
static id TREE_GetIvar(id obj, const char* name) {
    if (!obj) return nil;
    Ivar iv = class_getInstanceVariable(object_getClass(obj), name);
    if (iv) return *(id*)((char*)obj + ivar_getOffset(iv));
    return nil;
}

static id TREE_Pool() {
    Class cls = objc_getClass("NSAutoreleasePool");
    SEL sA = sel_registerName("alloc");
    SEL sI = sel_registerName("init");
    TREE_AllocFunc fA = (TREE_AllocFunc)method_getImplementation(class_getClassMethod(cls, sA));
    TREE_AllocFunc fI = (TREE_AllocFunc)method_getImplementation(class_getInstanceMethod(cls, sI));
    return fI(fA((id)cls, sA), sI);
}

static void TREE_Drain(id pool) {
    if (!pool) return;
    SEL s = sel_registerName("drain");
    void (*f)(id,SEL) = (void (*)(id,SEL))method_getImplementation(class_getInstanceMethod(object_getClass(pool), s));
    f(pool, s);
}

static id TREE_Str(const char* txt) {
    if (!txt) return nil;
    Class cls = objc_getClass("NSString");
    SEL s = sel_registerName("stringWithUTF8String:");
    TREE_StrFunc f = (TREE_StrFunc)method_getImplementation(class_getClassMethod(cls, s));
    return f((id)cls, s, txt);
}

static const char* TREE_CStr(id str) {
    if (!str) return "";
    SEL s = sel_registerName("UTF8String");
    TREE_Utf8Func f = (TREE_Utf8Func)method_getImplementation(class_getInstanceMethod(object_getClass(str), s));
    return f(str, s);
}

static void TREE_Msg(id server, const char* msg) {
    if (server && Real_TREE_Chat) {
        Real_TREE_Chat(server, sel_registerName("sendChatMessage:displayNotification:sendToClients:"), TREE_Str(msg), true, nil);
    }
}

// --- SPAWN LOGIC (FROM REFERENCE) ---

void TREE_SpawnNormal(id dynWorld, IntPair pos, int type) {
    SEL sel = sel_registerName("loadTreeAtPosition:type:maxHeight:growthRate:adultTree:adultMaxAge:");
    if (class_getInstanceMethod(object_getClass(dynWorld), sel)) {
        TREE_LoadFunc f = (TREE_LoadFunc)method_getImplementation(class_getInstanceMethod(object_getClass(dynWorld), sel));
        // Args: pos, type, height(20), rate(20), adult(1), maxAge(100.0)
        f(dynWorld, sel, pos, type, 20, 20, 1, 100.0f);
    }
}

void TREE_SpawnGem(id world, id dynWorld, IntPair pos, int gemType) {
    Class clsGem = objc_getClass(TREE_GEM_CLASS);
    if (!clsGem) return;

    // Retrieve required objects from DynamicWorld using Ivars
    id noise1 = TREE_GetIvar(dynWorld, "treeDensityNoiseFunction");
    id noise2 = TREE_GetIvar(dynWorld, "seasonOffsetNoiseFunction");
    id cache  = TREE_GetIvar(dynWorld, "cache");

    if (!noise1 || !noise2) return;

    // Alloc
    SEL sAlloc = sel_registerName("alloc");
    TREE_AllocFunc fAlloc = (TREE_AllocFunc)method_getImplementation(class_getClassMethod(clsGem, sAlloc));
    id rawTree = fAlloc((id)clsGem, sAlloc);
    if (!rawTree) return;

    // Init
    SEL sInit = sel_registerName("initWithWorld:dynamicWorld:atPosition:cache:treeDensityNoiseFunction:seasonOffsetNoiseFunction:gemTreeType:");
    if (class_getInstanceMethod(clsGem, sInit)) {
        TREE_InitGemFunc fInit = (TREE_InitGemFunc)method_getImplementation(class_getInstanceMethod(clsGem, sInit));
        fInit(rawTree, sInit, world, dynWorld, pos, cache, noise1, noise2, gemType);
    }
}

// --- HOOKS ---

// Hook fillTile with IntPair structure
void Hook_TREE_Fill(id self, SEL _cmd, void* tilePtr, IntPair pos, int type, uint16_t dA, uint16_t dB, id client, id saveDict, id bh, id cName) {
    
    // Check ID 1 (Block) or 1024 (Item)
    if (g_TREE_Active && (type == 1 || type == 1024)) {
        
        id dynWorld = TREE_GetIvar(self, "dynamicWorld");
        
        if (dynWorld) {
            if (g_TREE_IsGem) {
                TREE_SpawnGem(self, dynWorld, pos, g_TREE_Type);
            } else {
                TREE_SpawnNormal(dynWorld, pos, g_TREE_Type);
            }
        }
        
        // Cancel Stone Placement (Return without calling original)
        return; 
    }
    
    if (Real_TREE_Fill) {
        Real_TREE_Fill(self, _cmd, tilePtr, pos, type, dA, dB, client, saveDict, bh, cName);
    }
}

id Hook_TREE_Cmd(id self, SEL _cmd, id cmdStr, id client) {
    const char* raw = TREE_CStr(cmdStr);
    if (!raw) return Real_TREE_Cmd(self, _cmd, cmdStr, client);
    
    if (strncmp(raw, "/tree", 5) == 0) {
        id pool = TREE_Pool();
        
        char buffer[256]; strncpy(buffer, raw, 255);
        char* token = strtok(buffer, " ");
        char* arg = strtok(NULL, " ");
        
        if (!arg) {
            if (g_TREE_Active) {
                g_TREE_Active = false;
                TREE_Msg(self, "[Tree] OFF.");
            } else {
                TREE_Msg(self, "[Usage] /tree <type> (e.g. apple, diamond)");
            }
            TREE_Drain(pool);
            return nil;
        }
        
        if (strcasecmp(arg, "off") == 0) {
            g_TREE_Active = false;
            TREE_Msg(self, "[Tree] OFF.");
            TREE_Drain(pool);
            return nil;
        }
        
        g_TREE_Active = true;
        g_TREE_IsGem = false;
        strncpy(g_TREE_Name, arg, 63);
        
        // --- PARSER (Reference Based) ---
        if (strcasecmp(arg, "apple")==0) g_TREE_Type=1;
        else if (strcasecmp(arg, "mango")==0) g_TREE_Type=2;
        else if (strcasecmp(arg, "maple")==0) g_TREE_Type=3;
        else if (strcasecmp(arg, "pine")==0) g_TREE_Type=4;
        else if (strcasecmp(arg, "cactus")==0) g_TREE_Type=5;
        else if (strcasecmp(arg, "coconut")==0) g_TREE_Type=6;
        else if (strcasecmp(arg, "orange")==0) g_TREE_Type=7;
        else if (strcasecmp(arg, "cherry")==0) g_TREE_Type=8;
        else if (strcasecmp(arg, "coffee")==0) g_TREE_Type=9;
        else if (strcasecmp(arg, "lime")==0) g_TREE_Type=10;
        else {
            // Gem Trees
            g_TREE_IsGem = true;
            if (strcasecmp(arg, "amethyst")==0) g_TREE_Type=11;
            else if (strcasecmp(arg, "sapphire")==0) g_TREE_Type=12;
            else if (strcasecmp(arg, "emerald")==0) g_TREE_Type=13;
            else if (strcasecmp(arg, "ruby")==0) g_TREE_Type=14;
            else if (strcasecmp(arg, "diamond")==0) g_TREE_Type=15;
            else {
                g_TREE_Active = false;
                TREE_Msg(self, "[Tree] Unknown Type.");
                TREE_Drain(pool);
                return nil;
            }
        }
        
        char msg[128];
        snprintf(msg, 128, "[Tree] %s selected. Place STONE to plant.", g_TREE_Name);
        TREE_Msg(self, msg);
        
        TREE_Drain(pool);
        return nil;
    }
    
    return Real_TREE_Cmd(self, _cmd, cmdStr, client);
}

// --- INIT ---
static void* TREE_Init(void* arg) {
    sleep(1);
    
    Class clsWorld = objc_getClass(TREE_WORLD_CLASS);
    if (clsWorld) {
        SEL sFill = sel_registerName("fillTile:atPos:withType:dataA:dataB:placedByClient:saveDict:placedByBlockhead:placedByClientName:");
        if (class_getInstanceMethod(clsWorld, sFill)) {
            Real_TREE_Fill = (TREE_FillFunc)method_getImplementation(class_getInstanceMethod(clsWorld, sFill));
            method_setImplementation(class_getInstanceMethod(clsWorld, sFill), (IMP)Hook_TREE_Fill);
        }
    }
    
    Class clsSrv = objc_getClass(TREE_SERVER_CLASS);
    if (clsSrv) {
        Method mC = class_getInstanceMethod(clsSrv, sel_registerName("handleCommand:issueClient:"));
        Real_TREE_Cmd = (TREE_CmdFunc)method_getImplementation(mC);
        method_setImplementation(mC, (IMP)Hook_TREE_Cmd);
        
        Method mT = class_getInstanceMethod(clsSrv, sel_registerName("sendChatMessage:displayNotification:sendToClients:"));
        Real_TREE_Chat = (TREE_ChatFunc)method_getImplementation(mT);
    }
    return NULL;
}

__attribute__((constructor)) static void TREE_Entry() {
    pthread_t t; pthread_create(&t, NULL, TREE_Init, NULL);
}
