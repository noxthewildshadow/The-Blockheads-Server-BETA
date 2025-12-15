/*
 * COMMANDS:
 * -----------------------------------
 * 1. NATURAL SPAWNER:
 * /place <name|id>
 * - Places blocks with their natural properties (Ores, Crystals, etc).
 * - Automatically handles "Oil" requiring Limestone base.
 * - Example: /place iron, /place oil, /place 16
 *
 * 2. WALL BUILDER:
 * /wall <name|id>
 * - Places specific Backwalls (Layer 1) while keeping a Stone foreground.
 * - User must mine the Stone manually to reveal the wall (prevents ghost blocks).
 * - Example: /wall north, /wall 26
 *
 * 3. RAW MEMORY BUILDER:
 * /build <b0> <b1> <b2> ... <b11>
 * - Manually writes up to 12 bytes of raw data to the Tile structure.
 * - Byte 0: BlockID, Byte 1: WallID, Byte 3: ContentID, Byte 6: Light, etc.
 * - Example: /build 1 26 107 (Stone + GoldWall + Titanium)
 *
 * 4. DISABLE:
 * Type any command without arguments (e.g., /place) or add "off".
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
#define TARGET_WORLD_CLASS  "World"

// --- IDs & Constants ---
#define BLOCK_STONE      1
#define BLOCK_LIMESTONE  12
#define ITEM_STONE       1024

// --- Operation Modes ---
enum BuildMode { 
    MODE_OFF = 0, 
    MODE_PLACE, 
    MODE_WALL, 
    MODE_BUILD 
};

// --- Selectors ---
#define SEL_FILL      "fillTile:atPos:withType:dataA:dataB:placedByClient:saveDict:placedByBlockhead:placedByClientName:"
#define SEL_CMD       "handleCommand:issueClient:"
#define SEL_CHAT      "sendChatMessage:sendToClients:"
#define SEL_UTF8      "UTF8String"
#define SEL_STR       "stringWithUTF8String:"

// --- Structures ---
typedef struct { int x; int y; } IntPair;

// --- Function Prototypes ---
typedef void (*FillTileFunc)(id, SEL, void*, IntPair, int, uint16_t, uint16_t, id, id, id, id);
typedef id   (*CmdFunc)(id, SEL, id, id);
typedef void (*ChatFunc)(id, SEL, id, id);
typedef const char* (*StrFunc)(id, SEL);
typedef id   (*StringFactoryFunc)(id, SEL, const char*);

// --- Global State ---
static FillTileFunc Real_FillTile = NULL;
static CmdFunc      Real_HandleCmd = NULL;
static ChatFunc     Real_SendChat = NULL;

static int     G_Mode = MODE_OFF;
static int     G_TargetID = 0;      
static bool    G_IsContent = false; 

// Raw Build Buffer (Up to 12 bytes for Tile Struct)
static uint8_t G_BuildBytes[12];
static int     G_BuildCount = 0;

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

static int ParseID(const char* input, bool* isContent) {
    if (isContent) *isContent = true;
    
    // Walls / Poles
    if (strcasecmp(input, "north") == 0) return 38;
    if (strcasecmp(input, "south") == 0) return 39;
    if (strcasecmp(input, "west") == 0)  return 40;
    if (strcasecmp(input, "east") == 0)  return 41;
    
    // Ores & Contents
    if (strcasecmp(input, "copper") == 0)   return 61;
    if (strcasecmp(input, "tin") == 0)      return 62;
    if (strcasecmp(input, "iron") == 0)     return 63;
    if (strcasecmp(input, "oil") == 0)      return 64;
    if (strcasecmp(input, "coal") == 0)     return 65;
    if (strcasecmp(input, "gold") == 0)     return 77;
    if (strcasecmp(input, "platinum") == 0) return 106;
    if (strcasecmp(input, "titanium") == 0) return 107;
    
    // Gems
    if (strcasecmp(input, "diamond") == 0)  return 75;
    if (strcasecmp(input, "ruby") == 0)     return 74;
    if (strcasecmp(input, "emerald") == 0)  return 73;
    if (strcasecmp(input, "sapphire") == 0) return 72;
    if (strcasecmp(input, "amethyst") == 0) return 71;
    
    // Structures
    if (strcasecmp(input, "gate") == 0)      return 47;
    if (strcasecmp(input, "portal") == 0)    return 47;
    if (strcasecmp(input, "workbench") == 0) return 46;
    if (strcasecmp(input, "tc") == 0)        return 16;

    // Numeric Fallback (Block Mode)
    if (isContent) *isContent = false;
    return atoi(input);
}

// --- Core Logic: Tile Hook ---

void Hook_FillTile(id self, SEL _cmd, void* tilePtr, IntPair pos, int type, uint16_t dataA, uint16_t dataB, id client, id saveDict, id bh, id clientName) {
    
    // Intercept only when Active AND placing Stone
    bool isTrigger = (G_Mode != MODE_OFF && (type == BLOCK_STONE || type == ITEM_STONE));

    if (isTrigger) {
        // Remove ownership for natural placement
        client = nil;
        bh = nil;
        clientName = nil;
        saveDict = nil;
        
        // Apply visual defaults for specific blocks in Place Mode
        if (G_Mode == MODE_PLACE && !G_IsContent) {
            if (G_TargetID == 16) dataA = 3;   // Time Crystal Glow
            if (G_TargetID == 31) dataA = 255; // Full Lava
            if (G_TargetID == 3)  dataA = 255; // Full Water
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
                // Natural Spawner Logic
                if (G_IsContent) {
                    // Fix: Oil (64) requires Limestone (12) base to persist
                    rawMem[0] = (G_TargetID == 64) ? BLOCK_LIMESTONE : BLOCK_STONE;
                    rawMem[3] = (uint8_t)G_TargetID;
                } else {
                    rawMem[0] = (uint8_t)G_TargetID;
                }
                rawMem[4] = 0; // Reset damage/partial data
                break;

            case MODE_WALL: 
                // Wall Builder Logic
                rawMem[0] = BLOCK_STONE;         // Keep foreground block for physics
                rawMem[1] = (uint8_t)G_TargetID; // Set Backwall (Layer 1)
                rawMem[3] = 0;                   // Clear contents
                rawMem[4] = 0;
                break;

            case MODE_BUILD: 
                // Raw Memory Dump (Up to 12 bytes)
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
            SendChat(self, "[OMNI] Modes Disabled.");
            if (!arg) SendChat(self, "Help: /place <iron|oil|16>");
            return nil;
        }

        int target = ParseID(arg, &G_IsContent);
        if (target > 0) {
            G_TargetID = target;
            G_Mode = MODE_PLACE;
            char msg[128]; 
            if (G_IsContent) snprintf(msg, 128, "[PLACE] Ore Mode: %s. Place Stone.", arg);
            else snprintf(msg, 128, "[PLACE] Block Mode: ID %d. Place Stone.", G_TargetID);
            SendChat(self, msg);
        } else {
            SendChat(self, "Error: Invalid Name/ID.");
        }
        return nil;
    }

    // Command: /wall
    if (strncmp(text, "/wall", 5) == 0) {
        char* token = strtok(text, " ");
        char* arg = strtok(NULL, " ");

        if (!arg || strcasecmp(arg, "off") == 0) {
            G_Mode = MODE_OFF;
            SendChat(self, "[OMNI] Modes Disabled.");
            if (!arg) SendChat(self, "Help: /wall <north|26>");
            return nil;
        }

        int target = ParseID(arg, NULL);
        if (target > 0) {
            G_TargetID = target;
            G_Mode = MODE_WALL;
            char msg[128]; 
            snprintf(msg, 128, "[WALL] ID %d. Place Stone, then mine it.", target);
            SendChat(self, msg);
        } else {
            SendChat(self, "Error: Invalid Wall Name/ID.");
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
            SendChat(self, "[OMNI] Modes Disabled.");
            if (!arg) SendChat(self, "Help: /build <b0> <b1> <b3> ... <b11>");
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
            snprintf(msg, 128, "[BUILD] Writing %d bytes. Place Stone.", G_BuildCount);
            SendChat(self, msg);
        }
        return nil;
    }

    return Real_HandleCmd(self, _cmd, commandStr, client);
}

// --- Initialization ---

static void* InitThread(void* arg) {
    sleep(1);

    Class clsWorld = objc_getClass(TARGET_WORLD_CLASS);
    if (clsWorld) {
        Method m = class_getInstanceMethod(clsWorld, sel_registerName(SEL_FILL));
        if (m) {
            Real_FillTile = (FillTileFunc)method_getImplementation(m);
            method_setImplementation(m, (IMP)Hook_FillTile);
        }
    }

    Class clsServer = objc_getClass(TARGET_SERVER_CLASS);
    if (clsServer) {
        Method mCmd = class_getInstanceMethod(clsServer, sel_registerName(SEL_CMD));
        Real_HandleCmd = (CmdFunc)method_getImplementation(mCmd);
        method_setImplementation(mCmd, (IMP)Hook_HandleCmd);
        
        Method mChat = class_getInstanceMethod(clsServer, sel_registerName(SEL_CHAT));
        Real_SendChat = (ChatFunc)method_getImplementation(mChat);
    }
    return NULL;
}

__attribute__((constructor)) static void Entry() {
    pthread_t t; pthread_create(&t, NULL, InitThread, NULL);
}
