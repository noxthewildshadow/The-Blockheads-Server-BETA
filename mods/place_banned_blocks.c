/*
 * BLOCKHEADS PLACE NATURAL FORCE
 * Usage: /place <ID> | /place off (Use stone as bait)
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

// --- CONFIG ---
#define GHOST_SERVER_CLASS "BHServer"
#define GHOST_WORLD_CLASS  "World"
#define GHOST_SOURCE_ITEM  1024 // Always use Stone/Compost to build

// Selectors
#define SEL_FILL     "fillTile:atPos:withType:dataA:dataB:placedByClient:saveDict:placedByBlockhead:placedByClientName:"
#define SEL_CMD      "handleCommand:issueClient:"
#define SEL_CHAT     "sendChatMessage:sendToClients:"
#define SEL_UTF8     "UTF8String"
#define SEL_STR      "stringWithUTF8String:"

// --- STRUCTURES ---
typedef struct { int x; int y; } IntPair;

// Func Types
typedef void (*FillTileFunc)(id, SEL, void*, IntPair, int, uint16_t, uint16_t, id, id, id, id);
typedef id   (*CmdFunc)(id, SEL, id, id);
typedef void (*ChatFunc)(id, SEL, id, id);
typedef const char* (*StrFunc)(id, SEL);
typedef id   (*StringFactoryFunc)(id, SEL, const char*);

// --- STATE ---
static FillTileFunc Ghost_Real_FillTile = NULL;
static CmdFunc      Ghost_Real_HandleCmd = NULL;
static ChatFunc     Ghost_Real_SendChat = NULL;

static bool Ghost_Active = false;
static int  Ghost_TargetID = 0;

// --- UTILS ---
static const char* Ghost_GetStr(id strObj) {
    if (!strObj) return "";
    SEL sel = sel_registerName(SEL_UTF8);
    StrFunc f = (StrFunc)class_getMethodImplementation(object_getClass(strObj), sel);
    return f ? f(strObj, sel) : "";
}

static id Ghost_AllocStr(const char* text) {
    Class cls = objc_getClass("NSString");
    SEL sel = sel_registerName(SEL_STR);
    StringFactoryFunc f = (StringFactoryFunc)method_getImplementation(class_getClassMethod(cls, sel));
    return f ? f((id)cls, sel, text) : nil;
}

static void Ghost_Chat(id server, const char* msg) {
    if (server && Ghost_Real_SendChat) {
        Ghost_Real_SendChat(server, sel_registerName(SEL_CHAT), Ghost_AllocStr(msg), nil);
    }
}

// --- HOOK: NATURAL FORCE ---
void Ghost_Hook_FillTile(id self, SEL _cmd, void* tilePtr, IntPair pos, int type, uint16_t dataA, uint16_t dataB, id client, id saveDict, id bh, id clientName) {
    
    // Logic: Only act if active AND placing the source block (Stone)
    if (Ghost_Active && type == GHOST_SOURCE_ITEM) {
        
        // 1. FORENSIC WIPE (Make it Natural)
        client = nil;
        bh = nil;
        clientName = nil;
        saveDict = nil;

        // 2. VISUAL PREP (Optional defaults for common blocks)
        if (Ghost_TargetID == 16) dataA = 3;   // Crystal Glow
        if (Ghost_TargetID == 31) dataA = 255; // Lava Full
        if (Ghost_TargetID == 3)  dataA = 255; // Water Full
    }

    // 3. EXECUTE ORIGINAL (Create the stone/source block naturally)
    if (Ghost_Real_FillTile) {
        Ghost_Real_FillTile(self, _cmd, tilePtr, pos, type, dataA, dataB, client, saveDict, bh, clientName);
    }

    // 4. MEMORY SWAP (The Ghost Build)
    // Overwrite the block ID in raw memory immediately after creation
    if (Ghost_Active && type == GHOST_SOURCE_ITEM && tilePtr) {
        uint16_t* mem = (uint16_t*)tilePtr;
        mem[0] = (uint16_t)Ghost_TargetID; 
    }
}

// --- COMMANDS ---
id Ghost_Cmd_Hook(id self, SEL _cmd, id commandStr, id client) {
    const char* raw = Ghost_GetStr(commandStr);
    if (!raw) return Ghost_Real_HandleCmd(self, _cmd, commandStr, client);
    char text[256]; strncpy(text, raw, 255); text[255] = 0;

    // /place <ID>
    if (strncmp(text, "/place", 6) == 0) {
        char* token = strtok(text, " ");
        char* sID   = strtok(NULL, " ");

        if (!sID) {
            Ghost_Chat(self, "[HELP] /place <BlockType_ID> | /place off");
            return nil;
        }

        if (strcmp(sID, "off") == 0) {
            Ghost_Active = false;
            Ghost_Chat(self, "[GHOST] Disabled. Building works normally.");
            return nil;
        }

        Ghost_TargetID = atoi(sID);
        Ghost_Active = true;
        
        char msg[128];
        snprintf(msg, 128, "[GHOST] Enabled. Placing 'Stone' will spawn Block ID: %d (Natural)", Ghost_TargetID);
        Ghost_Chat(self, msg);
        
        return nil;
    }

    return Ghost_Real_HandleCmd(self, _cmd, commandStr, client);
}

// --- INIT ---
static void* Ghost_InitThread(void* arg) {
    sleep(1);
    // No printf, silent load.

    Class clsWorld = objc_getClass(GHOST_WORLD_CLASS);
    if (clsWorld) {
        Method m = class_getInstanceMethod(clsWorld, sel_registerName(SEL_FILL));
        if (m) {
            Ghost_Real_FillTile = (FillTileFunc)method_getImplementation(m);
            method_setImplementation(m, (IMP)Ghost_Hook_FillTile);
        }
    }

    Class clsServer = objc_getClass(GHOST_SERVER_CLASS);
    if (clsServer) {
        Method mCmd = class_getInstanceMethod(clsServer, sel_registerName(SEL_CMD));
        Ghost_Real_HandleCmd = (CmdFunc)method_getImplementation(mCmd);
        method_setImplementation(mCmd, (IMP)Ghost_Cmd_Hook);
        
        Method mChat = class_getInstanceMethod(clsServer, sel_registerName(SEL_CHAT));
        Ghost_Real_SendChat = (ChatFunc)method_getImplementation(mChat);
    }
    return NULL;
}

__attribute__((constructor)) static void Ghost_Entry() {
    pthread_t t; pthread_create(&t, NULL, Ghost_InitThread, NULL);
}
