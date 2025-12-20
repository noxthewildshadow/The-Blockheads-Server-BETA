/*
 * ======================================================================================
 *
 * 1. /chaos
 * - Activates RANDOM Mode.
 * - Action: Place Stone (Block ID 1) or Stone Item (ID 1024).
 * - Result: Generates a random seed/type for every block placed.
 * - Logs: Checks the SERVER CONSOLE for the "Seed" and "Type" generated.
 *
 * 2. /glitch <TYPE> <SEED>
 * - Activates REPLICATOR (Fixed) Mode.
 * - Usage: /glitch 4 1928374
 * - Action: Forces the specified Type and Seed on every Stone placed.
 * - Use this to replicate a specific glitch found using /chaos.
 *
 * 3. /glitch off
 * - Disables the mod immediately.
 *
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
#include <stdint.h>
#include <time.h>
#include <objc/runtime.h>

// --- Configuration ---
#define TARGET_SERVER "BHServer"
#define TARGET_WORLD  "World"

// --- IDs ---
#define ID_STONE_BLOCK   1
#define ID_STONE_ITEM    1024

// --- Selectors ---
#define SEL_PLACE_WB "placeWorkbenchOfType:atPos:saveDict:placedByClient:placedByBlockhead:placedByClientName:"
#define SEL_CMD      "handleCommand:issueClient:"
#define SEL_CHAT     "sendChatMessage:sendToClients:"
#define SEL_FILL     "fillTile:atPos:withType:dataA:dataB:placedByClient:saveDict:placedByBlockhead:placedByClientName:"

// --- Typedefs (Function Pointers) ---
typedef struct { int x; int y; } IntPair;

typedef void (*Imp_Fill)(id, SEL, void*, IntPair, int, uint16_t, uint16_t, id, id, id, id);
typedef void (*Imp_PlaceWB)(id, SEL, int, IntPair, id, id, id, id);
typedef id   (*Imp_Cmd)(id, SEL, id, id);
typedef void (*Imp_Chat)(id, SEL, id, id);
typedef id   (*Imp_NbInt)(id, SEL, int);
typedef id   (*Imp_NbFloat)(id, SEL, float);
typedef id   (*Imp_Str)(id, SEL, const char*);
typedef id   (*Imp_Dict)(id, SEL);
typedef void (*Imp_Set)(id, SEL, id, id);
typedef const char* (*Imp_Utf8)(id, SEL);

// --- Global State ---
static Imp_Fill    Real_Fill    = NULL;
static Imp_Cmd     Real_Cmd     = NULL;
static Imp_Chat    Real_Chat    = NULL;
static Imp_PlaceWB Real_PlaceWB = NULL;

static int G_Mode      = 0; // 0=OFF, 1=RANDOM, 2=FIXED
static int G_FixedType = 3;
static int G_FixedSeed = 0;

// --- Runtime Helpers (No objc_msgSend) ---

static IMP GetClassIMP(const char* className, const char* selName) {
    Class cls = objc_getClass(className);
    if (!cls) return NULL;
    SEL sel = sel_registerName(selName);
    Method m = class_getClassMethod(cls, sel); 
    return m ? method_getImplementation(m) : NULL;
}

static IMP GetInstIMP(id obj, const char* selName) {
    if (!obj) return NULL;
    SEL sel = sel_registerName(selName);
    Class cls = object_getClass(obj);
    Method m = class_getInstanceMethod(cls, sel);
    return m ? method_getImplementation(m) : NULL;
}

// Cached Wrappers for common objects
id NbInt(int val) {
    static Imp_NbInt imp = NULL;
    static Class cls = NULL;
    if (!imp) { 
        cls = objc_getClass("NSNumber"); 
        imp = (Imp_NbInt)GetClassIMP("NSNumber", "numberWithInt:"); 
    }
    return imp ? imp((id)cls, sel_registerName("numberWithInt:"), val) : nil;
}

id NbFloat(float val) {
    static Imp_NbFloat imp = NULL;
    static Class cls = NULL;
    if (!imp) { 
        cls = objc_getClass("NSNumber"); 
        imp = (Imp_NbFloat)GetClassIMP("NSNumber", "numberWithFloat:"); 
    }
    return imp ? imp((id)cls, sel_registerName("numberWithFloat:"), val) : nil;
}

id MkStr(const char* txt) {
    static Imp_Str imp = NULL;
    static Class cls = NULL;
    if (!imp) { 
        cls = objc_getClass("NSString"); 
        imp = (Imp_Str)GetClassIMP("NSString", "stringWithUTF8String:"); 
    }
    return imp ? imp((id)cls, sel_registerName("stringWithUTF8String:"), txt) : nil;
}

const char* GetDesc(id obj) {
    if (!obj) return "(null)";
    typedef id (*Imp_Desc)(id, SEL);
    Imp_Desc impDesc = (Imp_Desc)GetInstIMP(obj, "description");
    id strObj = impDesc ? impDesc(obj, sel_registerName("description")) : nil;
    
    if (strObj) {
        Imp_Utf8 impU = (Imp_Utf8)GetInstIMP(strObj, "UTF8String");
        return impU ? impU(strObj, sel_registerName("UTF8String")) : "err";
    }
    return "err";
}

void SendMsg(id self, const char* msg) {
    if (Real_Chat) {
        Real_Chat(self, sel_registerName(SEL_CHAT), MkStr(msg), nil);
    }
}

// --- Chaos Logic ---

id CreateSeededDict(int seed, int* outType) {
    srand(seed);
    static Class clsDict = NULL;
    static Imp_Dict impDictInfo = NULL;
    
    if (!clsDict) {
        clsDict = objc_getClass("NSMutableDictionary");
        impDictInfo = (Imp_Dict)GetClassIMP("NSMutableDictionary", "dictionary");
    }

    id dict = impDictInfo((id)clsDict, sel_registerName("dictionary"));
    if (!dict) return nil;

    Imp_Set impSet = (Imp_Set)GetInstIMP(dict, "setObject:forKey:");
    SEL selSet = sel_registerName("setObject:forKey:");

    if (impSet) {
        // ID Generation: Random 1-20
        int t = (rand() % 20) + 1;
        if (outType) *outType = t;

        impSet(dict, selSet, NbInt(t), MkStr("id"));
        
        // High level to break textures/logic
        impSet(dict, selSet, NbInt((rand() % 15) + 1), MkStr("level"));

        // Random Garbage Data
        char keyBuf[16];
        for (char c = 'C'; c <= 'F'; c++) {
            sprintf(keyBuf, "data%c", c);
            impSet(dict, selSet, NbInt(rand()), MkStr(keyBuf));
        }

        // Hybrid Properties
        if (rand() % 2) impSet(dict, selSet, NbInt((rand() % 5)), MkStr("chestType"));
        
        impSet(dict, selSet, NbInt(1), MkStr("hasFuel"));
        impSet(dict, selSet, NbFloat(99999.0f), MkStr("fuelFraction"));
        impSet(dict, selSet, MkStr("GLITCH"), MkStr("ownerName"));
    }
    return dict;
}

// --- Hooks ---

id Hook_Cmd(id self, SEL _cmd, id cmdStr, id client) {
    const char* txt = GetDesc(cmdStr); 
    char buffer[256];
    
    // /chaos -> Modo Random
    if (txt && strcasecmp(txt, "/chaos") == 0) {
        G_Mode = 1; 
        SendMsg(self, "[CHAOS] ON. Place STONE. Check CONSOLE for Seeds.");
        return nil;
    }

    // /glitch TYPE SEED -> Modo Replicar
    if (txt && strncmp(txt, "/glitch", 7) == 0) {
        int typeArg = 0;
        int seedArg = 0;
        
        if (strcasecmp(txt, "/glitch off") == 0) {
            G_Mode = 0;
            SendMsg(self, "[GLITCH] OFF.");
        } 
        else if (sscanf(txt, "/glitch %d %d", &typeArg, &seedArg) == 2) {
            G_Mode = 2;
            G_FixedType = typeArg;
            G_FixedSeed = seedArg;
            sprintf(buffer, "[REPLICATOR] Locked: Type %d | Seed %d", G_FixedType, G_FixedSeed);
            SendMsg(self, buffer);
        } else {
            SendMsg(self, "Usage: /glitch <TYPE> <SEED> (Get data from console)");
        }
        return nil;
    }
    
    if (Real_Cmd) return Real_Cmd(self, _cmd, cmdStr, client);
    return nil;
}

void Hook_FillTile(id self, SEL _cmd, void* tile, IntPair pos, int type, uint16_t dA, uint16_t dB, id client, id dict, id bh, id name) {
    
    // DETECTOR DE STONE (P1/P2 logic compatible)
    if (G_Mode > 0 && (type == ID_STONE_BLOCK || type == ID_STONE_ITEM)) {
        
        int typeToUse = 0;
        int seedToUse = 0;

        if (G_Mode == 1) { // RANDOM MODE
            seedToUse = (int)time(NULL) + pos.x + pos.y + rand();
        } else { // FIXED MODE
            typeToUse = G_FixedType;
            seedToUse = G_FixedSeed;
        }

        // Create corrupt dictionary
        id junkDict = CreateSeededDict(seedToUse, &typeToUse);
        
        // Ensure Fixed Type consistency
        if (G_Mode == 2) typeToUse = G_FixedType;

        // SAFE LOGGING (Console Only - No Chat calls here)
        if (G_Mode == 1) {
            printf("[CHAOS] Type: %d | Seed: %d | Replicate: /glitch %d %d\n", typeToUse, seedToUse, typeToUse, seedToUse);
        } else {
            printf("[REPLICATOR] Injecting Type %d Seed %d\n", typeToUse, seedToUse);
        }

        // Injection: Call PlaceWorkbench instead of FillTile
        if (Real_PlaceWB) {
            Real_PlaceWB(self, sel_registerName(SEL_PLACE_WB), 
                         typeToUse, pos, junkDict, client, bh, name);
            return; 
        }
    }

    if (Real_Fill) {
        Real_Fill(self, _cmd, tile, pos, type, dA, dB, client, dict, bh, name);
    }
}

// --- Initialization ---

void* InitThread(void* arg) {
    sleep(1);
    srand(time(NULL));

    // Hook World
    Class world = objc_getClass(TARGET_WORLD); 
    if (world) {
        Method mFill = class_getInstanceMethod(world, sel_registerName(SEL_FILL));
        if(mFill) {
            Real_Fill = (Imp_Fill)method_getImplementation(mFill);
            method_setImplementation(mFill, (IMP)Hook_FillTile);
        }
        
        Method mWB = class_getInstanceMethod(world, sel_registerName(SEL_PLACE_WB));
        if (mWB) Real_PlaceWB = (Imp_PlaceWB)method_getImplementation(mWB);
    }

    // Hook Server
    Class server = objc_getClass(TARGET_SERVER);
    if (server) {
        Method mCmd = class_getInstanceMethod(server, sel_registerName(SEL_CMD));
        Real_Cmd = (Imp_Cmd)method_getImplementation(mCmd);
        method_setImplementation(mCmd, (IMP)Hook_Cmd);

        Method mChat = class_getInstanceMethod(server, sel_registerName(SEL_CHAT));
        Real_Chat = (Imp_Chat)method_getImplementation(mChat);
    }

    printf("[WE47] Replicator V40 (Clean & Stable) Loaded.\n");
    return NULL;
}

__attribute__((constructor)) void Entry() {
    pthread_t t; 
    pthread_create(&t, NULL, InitThread, NULL);
}
