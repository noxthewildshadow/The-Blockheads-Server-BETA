// WorldEdit
// Commands: /set <id>, /p1, /p2, /del <id|optional>, /replace <old> <new>

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <ctype.h>
#include <stdarg.h>
#include <objc/runtime.h>
#include <objc/message.h>

#ifndef nil
#define nil (id)0
#endif

// --- Configuration ---
#define TARGET_SERVER_CLASS "BHServer"
#define TARGET_WORLD_CLASS  "World"
#define SYM_TILE_AT         "_Z25tileAtWorldPositionLoadediiP5World"

// --- Safety Limits ---
#define MAX_BLOCK_LIMIT     10000 // Prevents server freeze/watchdog kill

// --- IDs Constants ---
#define BLOCK_STONE      1
#define BLOCK_DIRT       6
#define BLOCK_LIMESTONE  12
#define BLOCK_AIR        0

// --- Enums ---
enum WEMode { WE_OFF = 0, WE_MODE_P1, WE_MODE_P2 };

// --- Structs ---
typedef struct { int x; int y; } IntPair;

typedef struct {
    int fgID;      // The Base Block ID (Byte 0)
    int contentID; // The Content ID (Byte 3)
    int dataA;     // Extra Data (Byte 2 - e.g., water level)
} BlockDef;

// --- Function Pointers Types ---
// Explicit types ensure correct register usage on ARM64
typedef void (*FillTileFunc)(id, SEL, void*, unsigned long long, int, uint16_t, uint16_t, id, id, id, id);
typedef void (*RemoveTileFunc)(id, SEL, int, int, int, int, id, BOOL, BOOL, BOOL, BOOL);
typedef id   (*RemoveIntFunc)(id, SEL, unsigned long long, id);
typedef void (*RemoveWaterFunc)(id, SEL, unsigned long long);
typedef id   (*CmdFunc)(id, SEL, id, id);
typedef void (*ChatFunc)(id, SEL, id, id);
typedef const char* (*StrFunc)(id, SEL);
typedef id   (*StringFactoryFunc)(id, SEL, const char*);
typedef void* (*TileAtWorldPosFunc)(int, int, id);

// --- Global State ---
static FillTileFunc       Real_Fill      = NULL;
static RemoveTileFunc     Real_RemTile   = NULL;
static RemoveIntFunc      Real_RemInt    = NULL;
static RemoveWaterFunc    Real_RemWater  = NULL;
static CmdFunc            Real_Cmd       = NULL;
static ChatFunc           Real_Chat      = NULL;
static TileAtWorldPosFunc Cpp_TileAt     = NULL;

static id      G_World   = nil;
static id      G_Server  = nil;
static id      G_SafeStr = nil; // Cached "WE" string
static int     G_Mode    = WE_OFF;
static IntPair G_P1      = {0, 0};
static IntPair G_P2      = {0, 0};
static bool    G_HasP1   = false;
static bool    G_HasP2   = false;

// --- Helper Functions ---

static const char* GetStr(id strObj) {
    if (!strObj) return "";
    SEL sel = sel_registerName("UTF8String");
    StrFunc f = (StrFunc)class_getMethodImplementation(object_getClass(strObj), sel);
    return f ? f(strObj, sel) : "";
}

static id MkStr(const char* text) {
    Class cls = objc_getClass("NSString");
    SEL sel = sel_registerName("stringWithUTF8String:");
    StringFactoryFunc f = (StringFactoryFunc)method_getImplementation(class_getClassMethod(cls, sel));
    return f ? f((id)cls, sel, text) : nil;
}

static void WE_Chat(const char* fmt, ...) {
    if (!G_Server || !Real_Chat) {
        printf("[WE_LOG] %s\n", fmt); return;
    }
    char buffer[256];
    va_list args;
    va_start(args, fmt);
    vsnprintf(buffer, sizeof(buffer), fmt, args);
    va_end(args);
    
    Real_Chat(G_Server, sel_registerName("sendChatMessage:sendToClients:"), MkStr(buffer), nil);
}

// --- Enhanced Parser ---
static BlockDef WE_Parse(const char* input) {
    BlockDef def = {BLOCK_AIR, 0, 0};
    if (!input) return def;

    // Numeric ID direct support
    if (isdigit(input[0])) { def.fgID = atoi(input); return def; }

    // Liquids & Basics
    if (strcasecmp(input, "air") == 0)   { def.fgID = 0; return def; } // Air usually 0
    if (strcasecmp(input, "water") == 0) { def.fgID = 3; def.dataA = 255; return def; }
    if (strcasecmp(input, "lava") == 0)  { def.fgID = 31; def.dataA = 255; return def; }
    
    // Solids (Construction)
    if (strcasecmp(input, "stone") == 0)     { def.fgID = 1; return def; }
    if (strcasecmp(input, "dirt") == 0)      { def.fgID = 6; return def; }
    if (strcasecmp(input, "wood") == 0)      { def.fgID = 9; return def; }
    if (strcasecmp(input, "glass") == 0)     { def.fgID = 24; return def; }
    if (strcasecmp(input, "brick") == 0)     { def.fgID = 11; return def; }
    if (strcasecmp(input, "marble") == 0)    { def.fgID = 14; return def; }
    if (strcasecmp(input, "redmarble") == 0) { def.fgID = 19; return def; }
    if (strcasecmp(input, "sandstone") == 0) { def.fgID = 17; return def; }
    if (strcasecmp(input, "steel") == 0)     { def.fgID = 57; return def; }
    if (strcasecmp(input, "carbon") == 0)    { def.fgID = 69; return def; }
    if (strcasecmp(input, "ice") == 0)       { def.fgID = 4; return def; }
    if (strcasecmp(input, "tc") == 0)        { def.fgID = 16; def.dataA = 3; return def; }

    // Ores & Contents (Requiring specific base blocks)
    // NOTE: Base block setting happens in WE_Place logic
    if (strcasecmp(input, "flint") == 0)    { def.fgID = BLOCK_DIRT; def.contentID = 1; return def; }
    if (strcasecmp(input, "clay") == 0)     { def.fgID = BLOCK_DIRT; def.contentID = 2; return def; }
    if (strcasecmp(input, "oil") == 0)      { def.fgID = BLOCK_LIMESTONE; def.contentID = 64; return def; }
    
    if (strcasecmp(input, "copper") == 0)   { def.fgID = BLOCK_STONE; def.contentID = 61; return def; }
    if (strcasecmp(input, "tin") == 0)      { def.fgID = BLOCK_STONE; def.contentID = 62; return def; }
    if (strcasecmp(input, "iron") == 0)     { def.fgID = BLOCK_STONE; def.contentID = 63; return def; }
    if (strcasecmp(input, "coal") == 0)     { def.fgID = BLOCK_STONE; def.contentID = 65; return def; }
    if (strcasecmp(input, "gold") == 0)     { def.fgID = BLOCK_STONE; def.contentID = 77; return def; }
    if (strcasecmp(input, "titanium") == 0) { def.fgID = BLOCK_STONE; def.contentID = 107; return def; }
    if (strcasecmp(input, "platinum") == 0) { def.fgID = BLOCK_STONE; def.contentID = 106; return def; }

    // Gems
    if (strcasecmp(input, "diamond") == 0)  { def.fgID = BLOCK_STONE; def.contentID = 75; return def; }
    if (strcasecmp(input, "ruby") == 0)     { def.fgID = BLOCK_STONE; def.contentID = 74; return def; }
    if (strcasecmp(input, "emerald") == 0)  { def.fgID = BLOCK_STONE; def.contentID = 73; return def; }

    // Fallback: Stone
    def.fgID = 1; 
    return def;
}

// --- Core Manipulation ---

static void* WE_GetPtr(IntPair pos) {
    if (!Cpp_TileAt || !G_World) return NULL;
    // Bounds Check (Standard BH World Height)
    if (pos.y < 0 || pos.y > 1024) return NULL; 
    return Cpp_TileAt(pos.x, pos.y, G_World);
}

// "Nuke" - Completely removes tile, liquids, and interactive objects
static void WE_Nuke(IntPair pos) {
    if (!G_World) return;
    unsigned long long packedPos = ((unsigned long long)pos.y << 32) | (unsigned int)pos.x;
    
    // 1. Remove Interaction Objects (Chests, Benches)
    if (Real_RemInt) Real_RemInt(G_World, sel_registerName("removeInteractionObjectAtPos:removeBlockhead:"), packedPos, nil);
    
    // 2. Remove Water/Liquid
    if (Real_RemWater) Real_RemWater(G_World, sel_registerName("removeWaterTileAtPos:"), packedPos);
    
    // 3. Remove Tile Physics & Data
    if (Real_RemTile) {
        Real_RemTile(G_World, sel_registerName("removeTileAtWorldX:worldY:createContentsFreeblockCount:createForegroundContentsFreeblockCount:removeBlockhead:onlyRemoveCOntents:onlyRemoveForegroundContents:sendWorldChangedNotifcation:dontRemoveContents:"), 
                     pos.x, pos.y, 0, 0, nil, false, false, true, false);
    }
}

// "Set" - Smart placement
static void WE_Place(IntPair pos, BlockDef def) {
    if (!Real_Fill || !G_World) return;
    if (!G_SafeStr) G_SafeStr = MkStr("WE_Bot");

    unsigned long long packedPos = ((unsigned long long)pos.y << 32) | (unsigned int)pos.x;

    // 1. Set the Base Block (Physics update)
    // We pass 0 as dataB/saveDict etc to keep it clean
    Real_Fill(G_World, sel_registerName("fillTile:atPos:withType:dataA:dataB:placedByClient:saveDict:placedByBlockhead:placedByClientName:"), 
              nil, packedPos, def.fgID, def.dataA, 0, nil, nil, nil, G_SafeStr);

    // 2. Inject Content (if any)
    // fillTile generally handles the foreground block. Ores are "contents" inside the tile struct.
    if (def.contentID > 0) {
        void* tilePtr = WE_GetPtr(pos);
        if (tilePtr) {
            uint8_t* raw = (uint8_t*)tilePtr;
            // Ensure base block matches parser logic
            raw[0] = (uint8_t)def.fgID; 
            // Set content byte (Byte 3 is standard for contents)
            raw[3] = (uint8_t)def.contentID;
        }
    }
}

// --- Operation Runner ---

static void WE_RunOp(int opCode, BlockDef target, BlockDef replacement) {
    if (!G_HasP1 || !G_HasP2) { WE_Chat("[WE] Error: Set P1 and P2 first."); return; }
    
    int x1 = (G_P1.x < G_P2.x) ? G_P1.x : G_P2.x;
    int x2 = (G_P1.x > G_P2.x) ? G_P1.x : G_P2.x;
    int y1 = (G_P1.y < G_P2.y) ? G_P1.y : G_P2.y;
    int y2 = (G_P1.y > G_P2.y) ? G_P1.y : G_P2.y;

    long long totalBlocks = (long long)(x2 - x1 + 1) * (long long)(y2 - y1 + 1);
    
    // Safety Brake
    if (totalBlocks > MAX_BLOCK_LIMIT) {
        WE_Chat("[WE] Error: Selection too large (%lld blocks). Limit is %d.", totalBlocks, MAX_BLOCK_LIMIT);
        return;
    }

    if (!Cpp_TileAt) { WE_Chat("[WE] Error: Missing C++ Symbol."); return; }

    int count = 0;
    
    for (int x = x1; x <= x2; x++) {
        for (int y = y1; y <= y2; y++) {
            IntPair curPos = {x, y};
            
            // Get current state for checks
            void* tilePtr = WE_GetPtr(curPos);
            int curID = BLOCK_AIR;
            int curCont = 0;

            if (tilePtr) {
                uint8_t* raw = (uint8_t*)tilePtr;
                curID = raw[0];
                curCont = raw[3];
            } else {
                continue; // Skip unloaded chunks
            }

            // --- OP 1: DELETE ---
            if (opCode == 1) { 
                bool hit = false;
                if (target.fgID == -1) { // Delete All
                    if (curID != BLOCK_AIR || curCont != 0) hit = true;
                } else { // Delete Specific
                    if (target.contentID > 0) {
                        if (curID == target.fgID && curCont == target.contentID) hit = true;
                    } else {
                        if (curID == target.fgID) hit = true;
                    }
                }
                if (hit) { WE_Nuke(curPos); count++; }
            }
            
            // --- OP 2: SET ---
            else if (opCode == 2) {
                // Only place if different
                if (curID != target.fgID || (target.contentID > 0 && curCont != target.contentID)) {
                    WE_Nuke(curPos); // Clean spot first prevents ghost blocks
                    WE_Place(curPos, target);
                    count++;
                }
            }
            
            // --- OP 3: REPLACE ---
            else if (opCode == 3) {
                bool match = false;
                // Match Logic
                if (target.contentID > 0) {
                    // Match Block+Content (e.g. replace only Coal)
                    if (curID == target.fgID && curCont == target.contentID) match = true;
                } else {
                    // Match Block Type (e.g. replace all Stone)
                    if (curID == target.fgID) match = true;
                }
                
                if (match) {
                    WE_Nuke(curPos);
                    WE_Place(curPos, replacement);
                    count++;
                }
            }
        }
    }
    
    WE_Chat("[WE] Done. Affected %d blocks.", count);
}

// --- Hooks ---

void Hook_FillTile(id self, SEL _cmd, void* tilePtr, unsigned long long packedPos, int type, uint16_t dA, uint16_t dB, id client, id saveDict, id bh, id clientName) {
    if (!G_World) G_World = self; // Capture World Instance

    int x = (int)(packedPos & 0xFFFFFFFF);
    int y = (int)(packedPos >> 32);
    
    // P1/P2 Selection Logic
    // Detects placing Stone (1) or Item Stone (1024)
    if ((type == 1 || type == 1024)) {
        if (G_Mode == WE_MODE_P1) {
            G_P1.x = x; G_P1.y = y; G_HasP1 = true; G_Mode = WE_OFF;
            WE_Chat("[WE] Point 1 >> (%d, %d)", x, y);
            // Don't place the block used for selection
            return; 
        } 
        else if (G_Mode == WE_MODE_P2) {
            G_P2.x = x; G_P2.y = y; G_HasP2 = true; G_Mode = WE_OFF;
            WE_Chat("[WE] Point 2 >> (%d, %d)", x, y);
            return;
        }
    }

    if (Real_Fill) {
        Real_Fill(self, _cmd, tilePtr, packedPos, type, dA, dB, client, saveDict, bh, clientName);
    }
}

bool IsCmd(const char* text, const char* cmd) {
    size_t len = strlen(cmd);
    if (strncasecmp(text, cmd, len) != 0) return false;
    return (text[len] == ' ' || text[len] == '\0');
}

id Hook_HandleCmd(id self, SEL _cmd, id commandStr, id client) {
    G_Server = self; 
    const char* raw = GetStr(commandStr);
    if (!raw) return Real_Cmd(self, _cmd, commandStr, client);
    
    char text[256]; strncpy(text, raw, 255); text[255] = 0;

    // --- Commands ---
    
    if (IsCmd(text, "/we")) {
        G_Mode = WE_OFF; G_HasP1 = false; G_HasP2 = false;
        WE_Chat("[WE] >> Tools Reset."); return nil;
    }
    
    if (IsCmd(text, "/p1")) { G_Mode = WE_MODE_P1; WE_Chat("[WE] >> Place a block for Point 1."); return nil; }
    if (IsCmd(text, "/p2")) { G_Mode = WE_MODE_P2; WE_Chat("[WE] >> Place a block for Point 2."); return nil; }

    if (IsCmd(text, "/set")) {
        char* t = strtok(text, " "); char* arg = strtok(NULL, " ");
        if (arg) {
            WE_Chat("[WE] Setting area to %s...", arg);
            BlockDef def = WE_Parse(arg);
            WE_RunOp(2, def, (BlockDef){0});
        } else WE_Chat("Usage: /set <block/ore>");
        return nil;
    }

    if (IsCmd(text, "/del")) {
        char* t = strtok(text, " "); char* arg = strtok(NULL, " ");
        BlockDef def = {-1,0,0}; // Default: Delete All
        if (arg) def = WE_Parse(arg);
        WE_Chat("[WE] Deleting %s...", arg ? arg : "all");
        WE_RunOp(1, def, (BlockDef){0});
        return nil;
    }

    if (IsCmd(text, "/replace")) {
        char* t = strtok(text, " "); char* a1 = strtok(NULL, " "); char* a2 = strtok(NULL, " ");
        if (a1 && a2) {
            WE_Chat("[WE] Replacing %s -> %s...", a1, a2);
            BlockDef old = WE_Parse(a1);
            BlockDef new = WE_Parse(a2);
            WE_RunOp(3, old, new);
        } else WE_Chat("Usage: /replace <old> <new>");
        return nil;
    }

    return Real_Cmd(self, _cmd, commandStr, client);
}

// --- Initialization ---

static void* WE_InitThread(void* arg) {
    sleep(1);
    
    // Link C++ Symbol
    void* handle = dlopen(NULL, RTLD_LAZY);
    if (handle) {
        Cpp_TileAt = (TileAtWorldPosFunc)dlsym(handle, SYM_TILE_AT);
        dlclose(handle);
    } else {
        printf("[WE] Error: dlopen failed.\n");
    }

    // Hook World Methods
    Class clsWorld = objc_getClass(TARGET_WORLD_CLASS);
    if (clsWorld) {
        Method mFill = class_getInstanceMethod(clsWorld, sel_registerName("fillTile:atPos:withType:dataA:dataB:placedByClient:saveDict:placedByBlockhead:placedByClientName:"));
        if (mFill) {
            Real_Fill = (FillTileFunc)method_getImplementation(mFill);
            method_setImplementation(mFill, (IMP)Hook_FillTile);
        }
        
        Method mNuke = class_getInstanceMethod(clsWorld, sel_registerName("removeTileAtWorldX:worldY:createContentsFreeblockCount:createForegroundContentsFreeblockCount:removeBlockhead:onlyRemoveCOntents:onlyRemoveForegroundContents:sendWorldChangedNotifcation:dontRemoveContents:"));
        if (mNuke) Real_RemTile = (RemoveTileFunc)method_getImplementation(mNuke);
        
        Method mInt = class_getInstanceMethod(clsWorld, sel_registerName("removeInteractionObjectAtPos:removeBlockhead:"));
        if (mInt) Real_RemInt = (RemoveIntFunc)method_getImplementation(mInt);
        
        Method mWater = class_getInstanceMethod(clsWorld, sel_registerName("removeWaterTileAtPos:"));
        if (mWater) Real_RemWater = (RemoveWaterFunc)method_getImplementation(mWater);
    }

    // Hook Server Methods
    Class clsServer = objc_getClass(TARGET_SERVER_CLASS);
    if (clsServer) {
        Method mCmd = class_getInstanceMethod(clsServer, sel_registerName("handleCommand:issueClient:"));
        if (mCmd) {
            Real_Cmd = (CmdFunc)method_getImplementation(mCmd);
            method_setImplementation(mCmd, (IMP)Hook_HandleCmd);
        }
        Method mChat = class_getInstanceMethod(clsServer, sel_registerName("sendChatMessage:sendToClients:"));
        if (mChat) Real_Chat = (ChatFunc)method_getImplementation(mChat);
    }

    printf("[WE] WorldEdit v2 Loaded.\n");
    return NULL;
}

__attribute__((constructor)) static void WE_Entry() {
    pthread_t t; pthread_create(&t, NULL, WE_InitThread, NULL);
}
