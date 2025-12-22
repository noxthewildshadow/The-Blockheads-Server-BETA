/*
 * WorldEdit (FIXED & FULL)
 * Commands: /we, /p1, /p2, /set <block>, /replace <old> <new>, /del <block>
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
#include <ctype.h>
#include <stdarg.h>
#include <objc/runtime.h>
#include <objc/message.h>

#ifndef nil
#define nil (id)0
#endif

#define TARGET_SERVER_CLASS "BHServer"
#define TARGET_WORLD_CLASS  "World"
#define SYM_TILE_AT         "_Z25tileAtWorldPositionLoadediiP5World"
#define MAX_BLOCK_LIMIT     10000 
#define BLOCK_STONE       1
#define BLOCK_DIRT        6
#define BLOCK_LIMESTONE   12
#define BLOCK_AIR         0

enum WEMode { WE_OFF = 0, WE_MODE_P1, WE_MODE_P2 };
typedef struct { int x; int y; } IntPair;
typedef struct { int fgID; int contentID; int dataA; } BlockDef;

typedef void (*FillTileFunc)(id, SEL, void*, unsigned long long, int, uint16_t, uint16_t, id, id, id, id);
typedef void (*RemoveTileFunc)(id, SEL, int, int, int, int, id, BOOL, BOOL, BOOL, BOOL);
typedef id   (*RemoveIntFunc)(id, SEL, unsigned long long, id);
typedef void (*RemoveWaterFunc)(id, SEL, unsigned long long);
typedef id   (*CmdFunc)(id, SEL, id, id);
typedef void (*ChatFunc)(id, SEL, id, id);
typedef const char* (*StrFunc)(id, SEL);
typedef id   (*StringFactoryFunc)(id, SEL, const char*);
typedef void* (*TileAtWorldPosFunc)(int, int, id);

static FillTileFunc       WE_Real_Fill     = NULL;
static RemoveTileFunc     WE_Real_RemTile  = NULL;
static RemoveIntFunc      WE_Real_RemInt   = NULL;
static RemoveWaterFunc    WE_Real_RemWater = NULL;
static CmdFunc            WE_Real_Cmd      = NULL;
static ChatFunc           WE_Real_Chat     = NULL;
static TileAtWorldPosFunc WE_Cpp_TileAt    = NULL;

static id      G_World   = nil;
static id      G_Server  = nil;
static int     G_Mode    = WE_OFF;
static IntPair G_P1      = {0, 0};
static IntPair G_P2      = {0, 0};
static bool    G_HasP1   = false;
static bool    G_HasP2   = false;

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
    if (!G_Server || !WE_Real_Chat) return;
    char buffer[256];
    va_list args;
    va_start(args, fmt);
    vsnprintf(buffer, sizeof(buffer), fmt, args);
    va_end(args);
    WE_Real_Chat(G_Server, sel_registerName("sendChatMessage:sendToClients:"), MkStr(buffer), nil);
}

// Helper faltante agregado
bool IsCmd(const char* text, const char* cmd) {
    size_t len = strlen(cmd);
    if (strncasecmp(text, cmd, len) != 0) return false;
    return (text[len] == ' ' || text[len] == '\0');
}

// FULL PARSER (Igual que Omni Tool para máxima compatibilidad)
static BlockDef WE_Parse(const char* input) {
    BlockDef def = {BLOCK_AIR, 0, 0};
    if (!input) return def;

    // Numeric ID direct support
    if (isdigit(input[0])) { def.fgID = atoi(input); return def; }

    // Liquids & Basics
    if (strcasecmp(input, "air") == 0)   { def.fgID = 0; return def; }
    if (strcasecmp(input, "water") == 0) { def.fgID = 3; def.dataA = 255; return def; }
    if (strcasecmp(input, "lava") == 0)  { def.fgID = 31; def.dataA = 255; return def; }
    
    // Solids
    if (strcasecmp(input, "stone") == 0)     { def.fgID = 1; return def; }
    if (strcasecmp(input, "dirt") == 0)      { def.fgID = 6; return def; }
    if (strcasecmp(input, "wood") == 0)      { def.fgID = 9; return def; }
    if (strcasecmp(input, "glass") == 0)     { def.fgID = 24; return def; }
    if (strcasecmp(input, "brick") == 0)     { def.fgID = 11; return def; }
    if (strcasecmp(input, "marble") == 0)    { def.fgID = 14; return def; }
    if (strcasecmp(input, "redmarble") == 0) { def.fgID = 19; return def; }
    if (strcasecmp(input, "sandstone") == 0) { def.fgID = 17; return def; }
    if (strcasecmp(input, "steel") == 0)     { def.fgID = 57; return def; }
    if (strcasecmp(input, "carbon") == 0)    { def.fgID = 69; return def; }
    if (strcasecmp(input, "ice") == 0)       { def.fgID = 4; return def; }
    if (strcasecmp(input, "tc") == 0)        { def.fgID = 16; def.dataA = 3; return def; }
    if (strcasecmp(input, "lapis") == 0)     { def.fgID = 29; return def; }
    if (strcasecmp(input, "basalt") == 0)    { def.fgID = 51; return def; }

    // Ores & Contents (Requiring specific base blocks)
    if (strcasecmp(input, "flint") == 0)    { def.fgID = BLOCK_DIRT; def.contentID = 1; return def; }
    if (strcasecmp(input, "clay") == 0)     { def.fgID = BLOCK_DIRT; def.contentID = 2; return def; }
    if (strcasecmp(input, "oil") == 0)      { def.fgID = BLOCK_LIMESTONE; def.contentID = 64; return def; }
    
    if (strcasecmp(input, "copper") == 0)   { def.fgID = BLOCK_STONE; def.contentID = 61; return def; }
    if (strcasecmp(input, "tin") == 0)      { def.fgID = BLOCK_STONE; def.contentID = 62; return def; }
    if (strcasecmp(input, "iron") == 0)     { def.fgID = BLOCK_STONE; def.contentID = 63; return def; }
    if (strcasecmp(input, "coal") == 0)     { def.fgID = BLOCK_STONE; def.contentID = 65; return def; }
    if (strcasecmp(input, "gold") == 0)     { def.fgID = BLOCK_STONE; def.contentID = 77; return def; }
    if (strcasecmp(input, "titanium") == 0) { def.fgID = BLOCK_STONE; def.contentID = 107; return def; }
    if (strcasecmp(input, "platinum") == 0) { def.fgID = BLOCK_STONE; def.contentID = 106; return def; }

    // Gems (COMPLETE)
    if (strcasecmp(input, "diamond") == 0)  { def.fgID = BLOCK_STONE; def.contentID = 75; return def; }
    if (strcasecmp(input, "ruby") == 0)     { def.fgID = BLOCK_STONE; def.contentID = 74; return def; }
    if (strcasecmp(input, "emerald") == 0)  { def.fgID = BLOCK_STONE; def.contentID = 73; return def; }
    if (strcasecmp(input, "sapphire") == 0) { def.fgID = BLOCK_STONE; def.contentID = 72; return def; }
    if (strcasecmp(input, "amethyst") == 0) { def.fgID = BLOCK_STONE; def.contentID = 71; return def; }

    // Fallback: Stone
    def.fgID = 1; 
    return def;
}

static void* WE_GetPtr(IntPair pos) {
    if (!WE_Cpp_TileAt || !G_World) return NULL;
    if (pos.y < 0 || pos.y > 1024) return NULL; 
    return WE_Cpp_TileAt(pos.x, pos.y, G_World);
}

static void WE_Nuke(IntPair pos) {
    if (!G_World) return;
    unsigned long long packedPos = ((unsigned long long)pos.y << 32) | (unsigned int)pos.x;
    if (WE_Real_RemInt) WE_Real_RemInt(G_World, sel_registerName("removeInteractionObjectAtPos:removeBlockhead:"), packedPos, nil);
    if (WE_Real_RemWater) WE_Real_RemWater(G_World, sel_registerName("removeWaterTileAtPos:"), packedPos);
    if (WE_Real_RemTile) {
        WE_Real_RemTile(G_World, sel_registerName("removeTileAtWorldX:worldY:createContentsFreeblockCount:createForegroundContentsFreeblockCount:removeBlockhead:onlyRemoveCOntents:onlyRemoveForegroundContents:sendWorldChangedNotifcation:dontRemoveContents:"), 
                       pos.x, pos.y, 0, 0, nil, false, false, true, false);
    }
}

static void WE_Place(IntPair pos, BlockDef def) {
    if (!WE_Real_Fill || !G_World) return;
    unsigned long long packedPos = ((unsigned long long)pos.y << 32) | (unsigned int)pos.x;
    WE_Real_Fill(G_World, sel_registerName("fillTile:atPos:withType:dataA:dataB:placedByClient:saveDict:placedByBlockhead:placedByClientName:"), 
               nil, packedPos, def.fgID, def.dataA, 0, nil, nil, nil, MkStr("WE_Bot"));
    if (def.contentID > 0) {
        void* tilePtr = WE_GetPtr(pos);
        if (tilePtr) {
            uint8_t* raw = (uint8_t*)tilePtr;
            raw[0] = (uint8_t)def.fgID; 
            raw[3] = (uint8_t)def.contentID;
        }
    }
}

static void WE_RunOp(int opCode, BlockDef target, BlockDef replacement) {
    if (!G_HasP1 || !G_HasP2) { WE_Chat(">> [WE] Error: Set P1 and P2."); return; }
    int x1 = (G_P1.x < G_P2.x) ? G_P1.x : G_P2.x;
    int x2 = (G_P1.x > G_P2.x) ? G_P1.x : G_P2.x;
    int y1 = (G_P1.y < G_P2.y) ? G_P1.y : G_P2.y;
    int y2 = (G_P1.y > G_P2.y) ? G_P1.y : G_P2.y;
    long long totalBlocks = (long long)(x2 - x1 + 1) * (long long)(y2 - y1 + 1);
    
    if (totalBlocks > MAX_BLOCK_LIMIT) {
        WE_Chat(">> [WE] Error: Limit %d blocks.", MAX_BLOCK_LIMIT);
        return;
    }
    int count = 0;
    for (int x = x1; x <= x2; x++) {
        for (int y = y1; y <= y2; y++) {
            IntPair curPos = {x, y};
            void* tilePtr = WE_GetPtr(curPos);
            int curID = BLOCK_AIR;
            int curCont = 0;
            if (tilePtr) {
                uint8_t* raw = (uint8_t*)tilePtr;
                curID = raw[0];
                curCont = raw[3];
            } else continue; 

            if (opCode == 1) { // Del
                bool hit = false;
                if (target.fgID == -1) { if (curID != BLOCK_AIR || curCont != 0) hit = true; } 
                else { 
                    if (target.contentID > 0) {
                        if (curID == target.fgID && curCont == target.contentID) hit = true;
                    } else {
                        if (curID == target.fgID) hit = true;
                    }
                }
                if (hit) { WE_Nuke(curPos); count++; }
            }
            else if (opCode == 2) { // Set
                if (curID != target.fgID || (target.contentID > 0 && curCont != target.contentID)) {
                    WE_Nuke(curPos); WE_Place(curPos, target); count++;
                }
            }
            else if (opCode == 3) { // Replace
                bool match = false;
                if (target.contentID > 0) {
                    if (curID == target.fgID && curCont == target.contentID) match = true;
                } else {
                    if (curID == target.fgID) match = true;
                }
                if (match) {
                    WE_Nuke(curPos); WE_Place(curPos, replacement); count++;
                }
            }
        }
    }
    WE_Chat(">> [WE] Success. %d blocks.", count);
}

void Hook_WE_FillTile(id self, SEL _cmd, void* tilePtr, unsigned long long packedPos, int type, uint16_t dA, uint16_t dB, id client, id saveDict, id bh, id clientName) {
    if (!G_World) G_World = self; 
    int x = (int)(packedPos & 0xFFFFFFFF);
    int y = (int)(packedPos >> 32);
    
    if ((type == 1 || type == 1024)) {
        if (G_Mode == WE_MODE_P1) {
            G_P1.x = x; G_P1.y = y; G_HasP1 = true; G_Mode = WE_OFF;
            WE_Chat(">> [WE] Point 1: (%d, %d)", x, y);
            return; 
        } 
        else if (G_Mode == WE_MODE_P2) {
            G_P2.x = x; G_P2.y = y; G_HasP2 = true; G_Mode = WE_OFF;
            WE_Chat(">> [WE] Point 2: (%d, %d)", x, y);
            return;
        }
    }
    if (WE_Real_Fill) WE_Real_Fill(self, _cmd, tilePtr, packedPos, type, dA, dB, client, saveDict, bh, clientName);
}

id Hook_WE_HandleCmd(id self, SEL _cmd, id commandStr, id client) {
    G_Server = self; 
    const char* raw = GetStr(commandStr);
    if (!raw) return WE_Real_Cmd(self, _cmd, commandStr, client);
    char text[256]; strncpy(text, raw, 255); text[255] = 0;

    if (IsCmd(text, "/we")) {
        G_Mode = WE_OFF; G_HasP1 = false; G_HasP2 = false;
        WE_Chat(">> [WE] Reset."); return nil;
    }
    if (IsCmd(text, "/p1")) { G_Mode = WE_MODE_P1; WE_Chat(">> [WE] Place Point 1."); return nil; }
    if (IsCmd(text, "/p2")) { G_Mode = WE_MODE_P2; WE_Chat(">> [WE] Place Point 2."); return nil; }

    if (IsCmd(text, "/set")) {
        char* t = strtok(text, " "); char* arg = strtok(NULL, " ");
        if (arg) {
            WE_Chat(">> [WE] Setting %s...", arg);
            WE_RunOp(2, WE_Parse(arg), (BlockDef){0});
        } else WE_Chat("Usage: /set <block>");
        return nil;
    }
    if (IsCmd(text, "/del")) {
        char* t = strtok(text, " "); char* arg = strtok(NULL, " ");
        BlockDef def = {-1,0,0}; 
        if (arg) def = WE_Parse(arg);
        WE_Chat(">> [WE] Deleting %s...", arg ? arg : "all");
        WE_RunOp(1, def, (BlockDef){0});
        return nil;
    }
    if (IsCmd(text, "/replace")) {
        char* t = strtok(text, " "); char* a1 = strtok(NULL, " "); char* a2 = strtok(NULL, " ");
        if (a1 && a2) {
            WE_Chat(">> [WE] Replacing %s -> %s...", a1, a2);
            WE_RunOp(3, WE_Parse(a1), WE_Parse(a2));
        } else WE_Chat("Usage: /replace <old> <new>");
        return nil;
    }
    return WE_Real_Cmd(self, _cmd, commandStr, client);
}

static void* WE_InitThread(void* arg) {
    sleep(1);
    void* handle = dlopen(NULL, RTLD_LAZY);
    if (handle) {
        WE_Cpp_TileAt = (TileAtWorldPosFunc)dlsym(handle, SYM_TILE_AT);
        dlclose(handle);
    } 

    Class clsWorld = objc_getClass(TARGET_WORLD_CLASS);
    if (clsWorld) {
        Method mFill = class_getInstanceMethod(clsWorld, sel_registerName("fillTile:atPos:withType:dataA:dataB:placedByClient:saveDict:placedByBlockhead:placedByClientName:"));
        WE_Real_Fill = (FillTileFunc)method_getImplementation(mFill);
        method_setImplementation(mFill, (IMP)Hook_WE_FillTile);
        
        Method mNuke = class_getInstanceMethod(clsWorld, sel_registerName("removeTileAtWorldX:worldY:createContentsFreeblockCount:createForegroundContentsFreeblockCount:removeBlockhead:onlyRemoveCOntents:onlyRemoveForegroundContents:sendWorldChangedNotifcation:dontRemoveContents:"));
        if (mNuke) WE_Real_RemTile = (RemoveTileFunc)method_getImplementation(mNuke);
        
        Method mInt = class_getInstanceMethod(clsWorld, sel_registerName("removeInteractionObjectAtPos:removeBlockhead:"));
        if (mInt) WE_Real_RemInt = (RemoveIntFunc)method_getImplementation(mInt);
        
        Method mWater = class_getInstanceMethod(clsWorld, sel_registerName("removeWaterTileAtPos:"));
        if (mWater) WE_Real_RemWater = (RemoveWaterFunc)method_getImplementation(mWater);
    }

    Class clsServer = objc_getClass(TARGET_SERVER_CLASS);
    if (clsServer) {
        Method mCmd = class_getInstanceMethod(clsServer, sel_registerName("handleCommand:issueClient:"));
        WE_Real_Cmd = (CmdFunc)method_getImplementation(mCmd);
        method_setImplementation(mCmd, (IMP)Hook_WE_HandleCmd);
        Method mChat = class_getInstanceMethod(clsServer, sel_registerName("sendChatMessage:sendToClients:"));
        if (mChat) WE_Real_Chat = (ChatFunc)method_getImplementation(mChat);
    }
    return NULL;
}

__attribute__((constructor)) static void WE_Entry() {
    pthread_t t; pthread_create(&t, NULL, WE_InitThread, NULL);
}
