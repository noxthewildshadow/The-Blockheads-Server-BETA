
// /set /p1 /p2 /del /replace

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <math.h>
#include <ctype.h>
#include <stdarg.h>

// --- Includes Nativos ---
#include <objc/runtime.h>
#include <objc/message.h>

#ifndef nil
#define nil (id)0
#endif

// --- Configuration ---
#define TARGET_SERVER_CLASS "BHServer"
#define TARGET_WORLD_CLASS  "World"

// --- IDs ---
#define WE_SAFE_ID  1 
#define WE_AIR_ID   2

enum WEMode { WE_OFF = 0, WE_MODE_P1, WE_MODE_P2 };

// --- Selectors ---
#define SEL_FILL_LONG  "fillTile:atPos:withType:dataA:dataB:placedByClient:saveDict:placedByBlockhead:placedByClientName:"
#define SEL_REM_INT    "removeInteractionObjectAtPos:removeBlockhead:"
#define SEL_REM_WATER  "removeWaterTileAtPos:"
#define SEL_NUKE       "removeTileAtWorldX:worldY:createContentsFreeblockCount:createForegroundContentsFreeblockCount:removeBlockhead:onlyRemoveCOntents:onlyRemoveForegroundContents:sendWorldChangedNotifcation:dontRemoveContents:"
#define SEL_CMD        "handleCommand:issueClient:"
#define SEL_CHAT       "sendChatMessage:sendToClients:"
#define SEL_UTF8       "UTF8String"
#define SEL_STR        "stringWithUTF8String:"

// --- C++ Symbols ---
#define SYM_TILE_AT "_Z25tileAtWorldPositionLoadediiP5World"

typedef struct { int x; int y; } IntPair;

typedef struct {
    int fgID;      
    int contentID; 
    int dataA;     
} BlockDef;

// --- Function Prototypes ---
typedef void (*FillTileLongFunc)(id, SEL, void*, unsigned long long, int, uint16_t, uint16_t, id, id, id, id);
typedef void (*RemoveTileFunc)(id, SEL, int, int, int, int, id, BOOL, BOOL, BOOL, BOOL);
typedef id   (*RemoveIntFunc)(id, SEL, unsigned long long, id);
typedef void (*RemoveWaterFunc)(id, SEL, unsigned long long);
typedef id   (*CmdFunc)(id, SEL, id, id);
typedef void (*ChatFunc)(id, SEL, id, id);
typedef const char* (*StrFunc)(id, SEL);
typedef id   (*StringFactoryFunc)(id, SEL, const char*);
typedef void* (*TileAtWorldPosFunc)(int, int, id);

// --- GLOBAL STATE ---
static FillTileLongFunc   WE47_Real_Fill = NULL;
static RemoveTileFunc     WE47_Real_RemTile = NULL;
static RemoveIntFunc      WE47_Real_RemInt = NULL;
static RemoveWaterFunc    WE47_Real_RemWater = NULL;
static CmdFunc            WE47_Real_Cmd = NULL;
static ChatFunc           WE47_Real_Chat = NULL;
static TileAtWorldPosFunc WE47_CppTileAt = NULL;

static id WE47_World = NULL;
static id WE47_Server = NULL;
static id WE47_SafeStr = NULL;
static int WE47_Mode = WE_OFF;
static IntPair WE47_P1 = {0, 0};
static IntPair WE47_P2 = {0, 0};
static bool WE47_HasP1 = false;
static bool WE47_HasP2 = false;

// --- Helpers ---
static const char* GetStr(id strObj) {
    if (!strObj) return "";
    SEL sel = sel_registerName(SEL_UTF8);
    StrFunc f = (StrFunc)class_getMethodImplementation(object_getClass(strObj), sel);
    return f ? f(strObj, sel) : "";
}

static id MkStr(const char* text) {
    Class cls = objc_getClass("NSString");
    SEL sel = sel_registerName(SEL_STR);
    StringFactoryFunc f = (StringFactoryFunc)method_getImplementation(class_getClassMethod(cls, sel));
    return f ? f((id)cls, sel, text) : NULL;
}

static void WE_Chat(const char* fmt, ...) {
    if (!WE47_Server || !WE47_Real_Chat) {
        printf("[WE47_LOG] %s\n", fmt); return;
    }
    char buffer[256];
    va_list args;
    va_start(args, fmt);
    vsnprintf(buffer, sizeof(buffer), fmt, args);
    va_end(args);
    
    WE47_Real_Chat(WE47_Server, sel_registerName(SEL_CHAT), MkStr(buffer), NULL);
}

// --- PARSER ---
static BlockDef WE_Parse(const char* input) {
    BlockDef def = {WE_AIR_ID, 0, 0}; 
    if (isdigit(input[0])) { def.fgID = atoi(input); return def; }

    if (strcasecmp(input, "air") == 0)   { def.fgID = 2; return def; }
    if (strcasecmp(input, "stone") == 0) { def.fgID = 1; return def; }
    if (strcasecmp(input, "dirt") == 0)  { def.fgID = 6; return def; }
    if (strcasecmp(input, "wood") == 0)  { def.fgID = 9; return def; }
    if (strcasecmp(input, "glass") == 0) { def.fgID = 24; return def; }
    if (strcasecmp(input, "water") == 0) { def.fgID = 3; def.dataA = 255; return def; }
    if (strcasecmp(input, "lava") == 0)  { def.fgID = 31; def.dataA = 255; return def; }
    if (strcasecmp(input, "tc") == 0)    { def.fgID = 16; return def; }
    if (strcasecmp(input, "gold_block") == 0) { def.fgID = 26; return def; }

    // Ores
    if (strcasecmp(input, "copper") == 0)   { def.fgID = 1; def.contentID = 61; return def; }
    if (strcasecmp(input, "tin") == 0)      { def.fgID = 1; def.contentID = 62; return def; }
    if (strcasecmp(input, "iron") == 0)     { def.fgID = 1; def.contentID = 63; return def; }
    if (strcasecmp(input, "coal") == 0)     { def.fgID = 1; def.contentID = 65; return def; }
    if (strcasecmp(input, "gold") == 0)     { def.fgID = 1; def.contentID = 77; return def; }
    if (strcasecmp(input, "titanium") == 0) { def.fgID = 1; def.contentID = 107; return def; }
    if (strcasecmp(input, "platinum") == 0) { def.fgID = 1; def.contentID = 106; return def; }
    if (strcasecmp(input, "oil") == 0)      { def.fgID = 12; def.contentID = 64; return def; }

    def.fgID = 1; return def;
}

// --- Logic ---

static void* WE_GetPtr(IntPair pos) {
    if (!WE47_CppTileAt || !WE47_World) return NULL;
    if (pos.y < 0 || pos.y > 1024) return NULL;
    return WE47_CppTileAt(pos.x, pos.y, WE47_World);
}

// SUPER DELETE
static void WE_Nuke(IntPair pos) {
    if (!WE47_World) return;
    unsigned long long packedPos = ((unsigned long long)pos.y << 32) | (unsigned int)pos.x;
    if (WE47_Real_RemInt) WE47_Real_RemInt(WE47_World, sel_registerName(SEL_REM_INT), packedPos, nil);
    if (WE47_Real_RemWater) WE47_Real_RemWater(WE47_World, sel_registerName(SEL_REM_WATER), packedPos);
    if (WE47_Real_RemTile) WE47_Real_RemTile(WE47_World, sel_registerName(SEL_NUKE), pos.x, pos.y, 0, 0, NULL, false, false, true, false);
}

// SMART PLACE
static void WE_Place(IntPair pos, BlockDef def) {
    if (!WE47_Real_Fill || !WE47_World) return;
    if (!WE47_SafeStr) WE47_SafeStr = MkStr("WE");
    unsigned long long packedPos = ((unsigned long long)pos.y << 32) | (unsigned int)pos.x;

    WE47_Real_Fill(WE47_World, sel_registerName(SEL_FILL_LONG), 
                   NULL, packedPos, WE_SAFE_ID, def.dataA, 0, NULL, NULL, NULL, WE47_SafeStr);

    void* tilePtr = WE_GetPtr(pos);
    if (tilePtr) {
        uint8_t* raw = (uint8_t*)tilePtr;
        raw[0] = (uint8_t)def.fgID; 
        raw[3] = (uint8_t)def.contentID;
    }
}

static void WE_RunOp(int operation, BlockDef def1, BlockDef def2) {
    if (!WE47_HasP1 || !WE47_HasP2) { WE_Chat("[WE] Error: Points not set. Use /p1 and /p2"); return; }
    
    int x1 = (WE47_P1.x < WE47_P2.x) ? WE47_P1.x : WE47_P2.x;
    int x2 = (WE47_P1.x > WE47_P2.x) ? WE47_P1.x : WE47_P2.x;
    int y1 = (WE47_P1.y < WE47_P2.y) ? WE47_P1.y : WE47_P2.y;
    int y2 = (WE47_P1.y > WE47_P2.y) ? WE47_P1.y : WE47_P2.y;
    
    int count = 0;
    if (!WE47_CppTileAt) { WE_Chat("[WE] Critical: Reader Error."); return; }

    for (int x = x1; x <= x2; x++) {
        for (int y = y1; y <= y2; y++) {
            IntPair currentPos = {x, y};
            void* tilePtr = WE_GetPtr(currentPos);
            
            int currentID = WE_AIR_ID;
            int currentContent = 0;

            if (tilePtr) {
                uint8_t* raw = (uint8_t*)tilePtr;
                currentID = raw[0];
                currentContent = raw[3];
            }

            // DEL
            if (operation == 1) { 
                bool shouldDelete = false;
                if (def1.fgID == -1) {
                    if (currentID != WE_AIR_ID) shouldDelete = true;
                } else {
                    if (def1.contentID > 0) {
                        if (currentID == def1.fgID && currentContent == def1.contentID) shouldDelete = true;
                    } else {
                        if (currentID == def1.fgID) shouldDelete = true;
                    }
                }
                if (shouldDelete) { WE_Nuke(currentPos); count++; }
            }
            // SET (Antes FILL)
            else if (operation == 2) {
                if (currentID == WE_AIR_ID) { WE_Place(currentPos, def1); count++; }
            }
            // REPLACE
            else if (operation == 3) {
                bool match = false;
                if (def1.fgID == WE_AIR_ID && currentID == 2) match = true;
                else if (def1.contentID > 0) {
                    if (currentID == def1.fgID && currentContent == def1.contentID) match = true;
                } else {
                    if (currentID == def1.fgID) match = true;
                }

                if (match) {
                    if (def2.fgID != WE_AIR_ID) WE_Nuke(currentPos);
                    WE_Place(currentPos, def2);
                    count++;
                }
            }
        }
    }
    
    WE_Chat("[WE] Operation Complete. Modified %d blocks.", count);
}

// --- Hooks ---

void WE47_Hook_Fill(id self, SEL _cmd, void* tilePtr, unsigned long long packedPos, int type, uint16_t dA, uint16_t dB, id client, id saveDict, id bh, id clientName) {
    if (WE47_World == NULL) { WE47_World = self; }

    int x = (int)(packedPos & 0xFFFFFFFF);
    int y = (int)(packedPos >> 32);
    IntPair pos = {x, y};

    if (WE47_Mode == WE_MODE_P1 && (type == 1 || type == 1024)) {
        WE47_P1 = pos; WE47_HasP1 = true; WE47_Mode = WE_OFF;
        WE_Chat("[WE] Point 1 set at (X: %d, Y: %d)", x, y);
    }
    else if (WE47_Mode == WE_MODE_P2 && (type == 1 || type == 1024)) {
        WE47_P2 = pos; WE47_HasP2 = true; WE47_Mode = WE_OFF;
        WE_Chat("[WE] Point 2 set at (X: %d, Y: %d)", x, y);
    }

    if (WE47_Real_Fill) {
        WE47_Real_Fill(self, _cmd, tilePtr, packedPos, type, dA, dB, client, saveDict, bh, clientName);
    }
}

// Helper para chequear comando exacto
bool WE_IsCommand(const char* text, const char* cmd) {
    size_t cmdLen = strlen(cmd);
    if (strncmp(text, cmd, cmdLen) != 0) return false;
    return (text[cmdLen] == ' ' || text[cmdLen] == '\0');
}

id WE47_Hook_Cmd(id self, SEL _cmd, id commandStr, id client) {
    WE47_Server = self; 
    const char* raw = GetStr(commandStr);
    if (!raw) return WE47_Real_Cmd(self, _cmd, commandStr, client);
    char text[256]; strncpy(text, raw, 255); text[255] = 0;

    if (strcasecmp(text, "/we") == 0) {
        WE47_Mode = WE_OFF; WE47_HasP1 = false; WE47_HasP2 = false;
        WE_Chat("[WE] Tools Reset. Selection Cleared."); return NULL;
    }
    if (strcasecmp(text, "/p1") == 0 || strcasecmp(text, "/we p1") == 0) { 
        WE47_Mode = WE_MODE_P1; WE_Chat("[WE] Place a block to set Point 1."); return NULL; 
    }
    if (strcasecmp(text, "/p2") == 0 || strcasecmp(text, "/we p2") == 0) { 
        WE47_Mode = WE_MODE_P2; WE_Chat("[WE] Place a block to set Point 2."); return NULL; 
    }

    if (WE_IsCommand(text, "/del")) {
        char* token = strtok(text, " "); char* arg = strtok(NULL, " "); 
        BlockDef target = arg ? WE_Parse(arg) : (BlockDef){-1,0,0};
        WE_Chat("[WE] Deleting %s...", arg ? arg : "everything");
        BlockDef dummy = {0}; WE_RunOp(1, target, dummy); return NULL;
    }
    
    // CAMBIO CRITICO: /fill AHORA ES /set
    if (WE_IsCommand(text, "/set")) {
        char* token = strtok(text, " "); char* arg = strtok(NULL, " ");
        if (arg) { 
            WE_Chat("[WE] Setting %s...", arg);
            BlockDef def = WE_Parse(arg); BlockDef dummy = {0}; 
            WE_RunOp(2, def, dummy); 
        } else WE_Chat("[WE] Usage: /set <block/ore>");
        return NULL;
    }

    if (WE_IsCommand(text, "/replace")) {
        char* token = strtok(text, " "); char* arg1 = strtok(NULL, " "); char* arg2 = strtok(NULL, " ");
        if (arg1 && arg2) { 
            WE_Chat("[WE] Replacing %s with %s...", arg1, arg2);
            BlockDef d1 = WE_Parse(arg1); BlockDef d2 = WE_Parse(arg2); 
            WE_RunOp(3, d1, d2); 
        } else WE_Chat("[WE] Usage: /replace <old> <new>");
        return NULL;
    }

    return WE47_Real_Cmd(self, _cmd, commandStr, client);
}

static void* WE47_Init(void* arg) {
    sleep(1);
    void* handle = dlopen(NULL, RTLD_LAZY);
    if (handle) {
        WE47_CppTileAt = (TileAtWorldPosFunc)dlsym(handle, SYM_TILE_AT);
        dlclose(handle);
    }
    
    Class clsWorld = objc_getClass(TARGET_WORLD_CLASS);
    if (clsWorld) {
        Method mFill = class_getInstanceMethod(clsWorld, sel_registerName(SEL_FILL_LONG));
        if (mFill) {
            WE47_Real_Fill = (FillTileLongFunc)method_getImplementation(mFill);
            method_setImplementation(mFill, (IMP)WE47_Hook_Fill);
        }
        Method mNuke = class_getInstanceMethod(clsWorld, sel_registerName(SEL_NUKE));
        if (mNuke) WE47_Real_RemTile = (RemoveTileFunc)method_getImplementation(mNuke);
        Method mInt = class_getInstanceMethod(clsWorld, sel_registerName(SEL_REM_INT));
        if (mInt) WE47_Real_RemInt = (RemoveIntFunc)method_getImplementation(mInt);
        Method mWater = class_getInstanceMethod(clsWorld, sel_registerName(SEL_REM_WATER));
        if (mWater) WE47_Real_RemWater = (RemoveWaterFunc)method_getImplementation(mWater);
        
        printf("[WE47] World Hooks Loaded.\n");
    }
    
    Class clsServer = objc_getClass(TARGET_SERVER_CLASS);
    if (clsServer) {
        Method mCmd = class_getInstanceMethod(clsServer, sel_registerName(SEL_CMD));
        WE47_Real_Cmd = (CmdFunc)method_getImplementation(mCmd);
        method_setImplementation(mCmd, (IMP)WE47_Hook_Cmd);
        Method mChat = class_getInstanceMethod(clsServer, sel_registerName(SEL_CHAT));
        WE47_Real_Chat = (ChatFunc)method_getImplementation(mChat);
    }
    return NULL;
}

__attribute__((constructor)) static void WE47_Entry() {
    pthread_t t; pthread_create(&t, NULL, WE47_Init, NULL);
}
