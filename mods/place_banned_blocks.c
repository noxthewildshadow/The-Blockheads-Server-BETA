/*
 * BLOCKHEADS SERVER PATCH - OMNI TOOL
 * -----------------------------------
 * COMMANDS:
 * /place <name|id>
 * - Supports Ores (Copper, Gold, Flint, Clay, Oil...)
 * - Supports Solids (Glass, Carbon, Steel, Marble...)
 * - Auto-fixes base block (Dirt for Flint, Limestone for Oil).
 *
 * /wall <name|id>
 * - Places Backwalls. Mine the foreground stone to reveal.
 *
 * /build <b0> <b1> ...
 * - Raw byte injection.
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
#include <strings.h> 

// --- Configuration ---
#define TARGET_SERVER_CLASS "BHServer"
#define TARGET_WORLD_CLASS  "World"

// --- IDs & Constants ---
#define BLOCK_STONE      1
#define BLOCK_DIRT       6
#define BLOCK_LIMESTONE  12
#define ITEM_STONE       1024

// --- Operation Modes ---
enum BuildMode { 
    MODE_OFF = 0, 
    MODE_PLACE, 
    MODE_WALL, 
    MODE_BUILD 
};

// --- Selectors ---
#define SEL_FILL      "fillTile:atPos:withType:dataA:dataB:placedByClient:saveDict:placedByBlockhead:placedByClientName:"
#define SEL_CMD       "handleCommand:issueClient:"
#define SEL_CHAT      "sendChatMessage:sendToClients:"
#define SEL_UTF8      "UTF8String"
#define SEL_STR       "stringWithUTF8String:"

// --- Structures ---
typedef struct { int x; int y; } IntPair;

// --- Function Prototypes ---
typedef void (*FillTileFunc)(id, SEL, void*, IntPair, int, uint16_t, uint16_t, id, id, id, id);
typedef id   (*CmdFunc)(id, SEL, id, id);
typedef void (*ChatFunc)(id, SEL, id, id);
typedef const char* (*StrFunc)(id, SEL);
typedef id   (*StringFactoryFunc)(id, SEL, const char*);

// --- Global State ---
static FillTileFunc Real_FillTile = NULL;
static CmdFunc      Real_HandleCmd = NULL;
static ChatFunc     Real_SendChat = NULL;

static int     G_Mode = MODE_OFF;
static int     G_TargetID = 0;       
static bool    G_IsContent = false; 

// Raw Build Buffer (Up to 12 bytes for Tile Struct)
static uint8_t G_BuildBytes[12];
static int     G_BuildCount = 0;

// --- Helper Functions ---

static const char* GetString(id strObj) {
    if (!strObj) return "";
    SEL sel = sel_registerName(SEL_UTF8);
    StrFunc f = (StrFunc)class_getMethodImplementation(object_getClass(strObj), sel);
    return f ? f(strObj, sel) : "";
}

static id CreateNSString(const char* text) {
    Class cls = objc_getClass("NSString");
    SEL sel = sel_registerName(SEL_STR);
    StringFactoryFunc f = (StringFactoryFunc)method_getImplementation(class_getClassMethod(cls, sel));
    return f ? f((id)cls, sel, text) : nil;
}

static void SendChat(id server, const char* msg) {
    if (server && Real_SendChat) {
        Real_SendChat(server, sel_registerName(SEL_CHAT), CreateNSString(msg), nil);
    }
}

// --- ID Parser ---
static int ParseID(const char* input, bool* isContent) {
    if (isContent) *isContent = true; // Default assumption, fixed below if solid
    
    // --- Walls / Poles ---
    if (strcasecmp(input, "north") == 0) return 38;
    if (strcasecmp(input, "south") == 0) return 39;
    if (strcasecmp(input, "west") == 0)  return 40;
    if (strcasecmp(input, "east") == 0)  return 41;
    
    // --- Solid Blocks (TileTypes) ---
    // These are NOT contents. They replace the block itself.
    bool foundSolid = false;
    int solidID = 0;

    if (strcasecmp(input, "carbon") == 0)    { solidID = 69; foundSolid = true; }
    if (strcasecmp(input, "steel") == 0)     { solidID = 57; foundSolid = true; }
    if (strcasecmp(input, "bronze") == 0)    { solidID = 55; foundSolid = true; }
    if (strcasecmp(input, "glass") == 0)     { solidID = 24; foundSolid = true; }
    if (strcasecmp(input, "marble") == 0)    { solidID = 14; foundSolid = true; }
    if (strcasecmp(input, "redmarble") == 0) { solidID = 19; foundSolid = true; }
    if (strcasecmp(input, "sandstone") == 0) { solidID = 17; foundSolid = true; }
    if (strcasecmp(input, "basalt") == 0)    { solidID = 51; foundSolid = true; }
    if (strcasecmp(input, "gravel") == 0)    { solidID = 70; foundSolid = true; }
    if (strcasecmp(input, "brick") == 0)     { solidID = 11; foundSolid = true; }
    if (strcasecmp(input, "ice") == 0)       { solidID = 4;  foundSolid = true; }
    if (strcasecmp(input, "lapis") == 0)     { solidID = 29; foundSolid = true; }

    if (foundSolid) {
        if (isContent) *isContent = false;
        return solidID;
    }

    // --- Contents (Ores, Gems, Dirt items) ---
    if (strcasecmp(input, "flint") == 0) return 1;
    if (strcasecmp(input, "clay") == 0)  return 2;
    if (strcasecmp(input, "copper") == 0)   return 61;
    if (strcasecmp(input, "tin") == 0)      return 62;
    if (strcasecmp(input, "iron") == 0)     return 63;
    if (strcasecmp(input, "oil") == 0)      return 64;
    if (strcasecmp(input, "coal") == 0)     return 65;
    if (strcasecmp(input, "gold") == 0)     return 77;
    if (strcasecmp(input, "platinum") == 0) return 106;
    if (strcasecmp(input, "titanium") == 0) return 107;
    
    // Gems
    if (strcasecmp(input, "diamond") == 0)  return 75;
    if (strcasecmp(input, "ruby") == 0)     return 74;
    if (strcasecmp(input, "emerald") == 0)  return 73;
    if (strcasecmp(input, "sapphire") == 0) return 72;
    if (strcasecmp(input, "amethyst") == 0) return 71;
    
    // Structures
    if (strcasecmp(input, "gate") == 0)      return 47;
    if (strcasecmp(input, "portal") == 0)    return 47;
    if (strcasecmp(input, "workbench") == 0) return 46;
    if (strcasecmp(input, "tc") == 0)        return 16;

    // Numeric Fallback (Direct ID input)
    // We assume numeric input is a Block ID (not content) unless told otherwise,
    // but for safety in this script, we default to block mode for numbers.
    if (isContent) *isContent = false;
    return atoi(input);
}

// --- Core Logic: Tile Hook ---

void Hook_FillTile(id self, SEL _cmd, void* tilePtr, IntPair pos, int type, uint16_t dataA, uint16_t dataB, id client, id saveDict, id bh, id clientName) {
    
    // Intercept only when Active AND placing Stone
    bool isTrigger = (G_Mode != MODE_OFF && (type == BLOCK_STONE || type == ITEM_STONE));

    if (isTrigger) {
        // Remove ownership/save data for cleaner placement
        client = nil;
        bh = nil;
        clientName = nil;
        saveDict = nil;
        
        // Visual defaults for liquid/glow blocks
        if (G_Mode == MODE_PLACE && !G_IsContent) {
            if (G_TargetID == 16) dataA = 3;   // TC Glow
            if (G_TargetID == 31) dataA = 255; // Lava
            if (G_TargetID == 3)  dataA = 255; // Water
        }
    }

    // Call Original Implementation
    if (Real_FillTile) {
        Real_FillTile(self, _cmd, tilePtr, pos, type, dataA, dataB, client, saveDict, bh, clientName);
    }

    // Apply Memory Injection
    if (isTrigger && tilePtr) {
        uint8_t* rawMem = (uint8_t*)tilePtr;
        
        switch (G_Mode) {
            case MODE_PLACE: 
                if (G_IsContent) {
                    // --- Content Mode (Ores/Flint/Oil) ---
                    // Determine correct base block to avoid glitches
                    uint8_t baseBlock = BLOCK_STONE;
                    
                    if (G_TargetID == 64) {
                        baseBlock = BLOCK_LIMESTONE; // Oil -> Limestone
                    } else if (G_TargetID == 1 || G_TargetID == 2) {
                        baseBlock = BLOCK_DIRT;      // Flint/Clay -> Dirt
                    }
                    
                    rawMem[0] = baseBlock;
                    rawMem[3] = (uint8_t)G_TargetID; // Set Content ID
                } else {
                    // --- Solid Block Mode (Carbon/Steel/Glass) ---
                    // Directly replace the TileType (Byte 0)
                    rawMem[0] = (uint8_t)G_TargetID;
                    rawMem[3] = 0; // Ensure no content inside
                }
                rawMem[4] = 0; // Reset damage
                break;

            case MODE_WALL: 
                rawMem[0] = BLOCK_STONE;         // Foreground
                rawMem[1] = (uint8_t)G_TargetID; // Backwall (Layer 1)
                rawMem[3] = 0;
                rawMem[4] = 0;
                break;

            case MODE_BUILD: 
                for (int i = 0; i < G_BuildCount; i++) {
                    rawMem[i] = G_BuildBytes[i];
                }
                break;
        }
    }
}

// --- Command Handler ---

id Hook_HandleCmd(id self, SEL _cmd, id commandStr, id client) {
    const char* raw = GetString(commandStr);
    if (!raw) return Real_HandleCmd(self, _cmd, commandStr, client);
    char text[256]; strncpy(text, raw, 255); text[255] = 0;

    // Command: /place
    if (strncmp(text, "/place", 6) == 0) {
        char* token = strtok(text, " ");
        char* arg = strtok(NULL, " ");
        
        if (!arg || strcasecmp(arg, "off") == 0) {
            G_Mode = MODE_OFF;
            SendChat(self, ">> OMNI-TOOL: Deactivated.");
            if (!arg) SendChat(self, "Usage: /place <gold|flint|carbon|glass|oil>");
            return nil;
        }

        int target = ParseID(arg, &G_IsContent);
        if (target > 0) {
            G_TargetID = target;
            G_Mode = MODE_PLACE;
            
            char msg[128];
            if (G_IsContent) {
                // Determine base block name for the user message
                const char* baseName = "Stone";
                if (target == 1 || target == 2) baseName = "Dirt";
                if (target == 64) baseName = "Limestone";
                
                snprintf(msg, 128, ">> ORE MODE: Spawning %s (ID %d). Base: %s. Place Stone blocks.", arg, target, baseName);
            } else {
                snprintf(msg, 128, ">> SOLID MODE: Spawning %s (ID %d). Place Stone blocks.", arg, target);
            }
            SendChat(self, msg);
        } else {
            SendChat(self, ">> ERROR: Unknown Block/Ore ID.");
        }
        return nil;
    }

    // Command: /wall
    if (strncmp(text, "/wall", 5) == 0) {
        char* token = strtok(text, " ");
        char* arg = strtok(NULL, " ");

        if (!arg || strcasecmp(arg, "off") == 0) {
            G_Mode = MODE_OFF;
            SendChat(self, ">> OMNI-TOOL: Deactivated.");
            return nil;
        }

        int target = ParseID(arg, NULL);
        if (target > 0) {
            G_TargetID = target;
            G_Mode = MODE_WALL;
            char msg[128]; 
            snprintf(msg, 128, ">> WALL MODE: ID %d. Place Stone, then mine it to reveal.", target);
            SendChat(self, msg);
        } else {
            SendChat(self, ">> ERROR: Invalid Wall ID.");
        }
        return nil;
    }

    // Command: /build
    if (strncmp(text, "/build", 6) == 0) {
        char bufferCopy[256]; strcpy(bufferCopy, text);
        char* token = strtok(bufferCopy, " "); 
        char* arg = strtok(NULL, " ");
        
        if (!arg || strcasecmp(arg, "off") == 0) {
            G_Mode = MODE_OFF;
            SendChat(self, ">> OMNI-TOOL: Deactivated.");
            return nil;
        }

        G_BuildCount = 0;
        while (arg != NULL && G_BuildCount < 12) {
            G_BuildBytes[G_BuildCount] = (uint8_t)atoi(arg);
            G_BuildCount++;
            arg = strtok(NULL, " ");
        }

        if (G_BuildCount > 0) {
            G_Mode = MODE_BUILD;
            char msg[128];
            snprintf(msg, 128, ">> RAW BUILD: Injecting %d bytes. Place Stone.", G_BuildCount);
            SendChat(self, msg);
        }
        return nil;
    }

    return Real_HandleCmd(self, _cmd, commandStr, client);
}

// --- Initialization ---

static void* InitThread(void* arg) {
    sleep(1);

    // Hook FillTile (World)
    Class clsWorld = objc_getClass(TARGET_WORLD_CLASS);
    if (clsWorld) {
        Method m = class_getInstanceMethod(clsWorld, sel_registerName(SEL_FILL));
        if (m) {
            Real_FillTile = (FillTileFunc)method_getImplementation(m);
            method_setImplementation(m, (IMP)Hook_FillTile);
        } else {
            printf("Error: Could not find fillTile method!\n");
        }
    }

    // Hook Commands & Chat (BHServer)
    Class clsServer = objc_getClass(TARGET_SERVER_CLASS);
    if (clsServer) {
        Method mCmd = class_getInstanceMethod(clsServer, sel_registerName(SEL_CMD));
        if (mCmd) {
            Real_HandleCmd = (CmdFunc)method_getImplementation(mCmd);
            method_setImplementation(mCmd, (IMP)Hook_HandleCmd);
        }

        Method mChat = class_getInstanceMethod(clsServer, sel_registerName(SEL_CHAT));
        if (mChat) {
            Real_SendChat = (ChatFunc)method_getImplementation(mChat);
        }
    }
    return NULL;
}

__attribute__((constructor)) static void Entry() {
    pthread_t t; pthread_create(&t, NULL, InitThread, NULL);
}
