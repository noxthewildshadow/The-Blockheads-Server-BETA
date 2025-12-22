/*
 * OMNI TOOL
 * /place, /wall, /build
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

#define TARGET_SERVER_CLASS "BHServer"
#define TARGET_WORLD_CLASS  "World"
#define BLOCK_STONE      1
#define BLOCK_DIRT       6
#define BLOCK_LIMESTONE  12
#define ITEM_STONE       1024

enum BuildMode { MODE_OFF = 0, MODE_PLACE, MODE_WALL, MODE_BUILD };

#define SEL_FILL      "fillTile:atPos:withType:dataA:dataB:placedByClient:saveDict:placedByBlockhead:placedByClientName:"
#define SEL_CMD       "handleCommand:issueClient:"
#define SEL_CHAT      "sendChatMessage:sendToClients:"
#define SEL_UTF8      "UTF8String"
#define SEL_STR       "stringWithUTF8String:"

typedef struct { int x; int y; } IntPair;
typedef void (*FillTileFunc)(id, SEL, void*, IntPair, int, uint16_t, uint16_t, id, id, id, id);
typedef id   (*CmdFunc)(id, SEL, id, id);
typedef void (*ChatFunc)(id, SEL, id, id);
typedef const char* (*StrFunc)(id, SEL);
typedef id   (*StringFactoryFunc)(id, SEL, const char*);

static FillTileFunc Real_FillTile = NULL;
static CmdFunc      Omni_Real_HandleCmd = NULL;
static ChatFunc     Omni_Real_SendChat = NULL;

static int     G_Mode = MODE_OFF;
static int     G_TargetID = 0;       
static bool    G_IsContent = false; 
static uint8_t G_BuildBytes[12];
static int     G_BuildCount = 0;

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
    if (server && Omni_Real_SendChat) {
        Omni_Real_SendChat(server, sel_registerName(SEL_CHAT), CreateNSString(msg), nil);
    }
}

static int ParseID(const char* input, bool* isContent) {
    if (isContent) *isContent = true; 
    if (strcasecmp(input, "north") == 0) return 38;
    if (strcasecmp(input, "south") == 0) return 39;
    if (strcasecmp(input, "west") == 0)  return 40;
    if (strcasecmp(input, "east") == 0)  return 41;
    
    bool foundSolid = false;
    int solidID = 0;
    if (strcasecmp(input, "carbon") == 0)    { solidID = 69; foundSolid = true; }
    if (strcasecmp(input, "steel") == 0)     { solidID = 57; foundSolid = true; }
    if (strcasecmp(input, "glass") == 0)     { solidID = 24; foundSolid = true; }
    if (strcasecmp(input, "marble") == 0)    { solidID = 14; foundSolid = true; }
    if (strcasecmp(input, "ice") == 0)       { solidID = 4;  foundSolid = true; }

    if (foundSolid) {
        if (isContent) *isContent = false;
        return solidID;
    }
    if (strcasecmp(input, "flint") == 0) return 1;
    if (strcasecmp(input, "clay") == 0)  return 2;
    if (strcasecmp(input, "copper") == 0)   return 61;
    if (strcasecmp(input, "tin") == 0)      return 62;
    if (strcasecmp(input, "iron") == 0)     return 63;
    if (strcasecmp(input, "oil") == 0)      return 64;
    if (strcasecmp(input, "coal") == 0)     return 65;
    if (strcasecmp(input, "gold") == 0)     return 77;
    if (strcasecmp(input, "diamond") == 0)  return 75;
    if (strcasecmp(input, "ruby") == 0)     return 74;
    
    if (isContent) *isContent = false;
    return atoi(input);
}

void Hook_FillTile(id self, SEL _cmd, void* tilePtr, IntPair pos, int type, uint16_t dataA, uint16_t dataB, id client, id saveDict, id bh, id clientName) {
    bool isTrigger = (G_Mode != MODE_OFF && (type == BLOCK_STONE || type == ITEM_STONE));
    if (isTrigger) {
        client = nil; bh = nil; clientName = nil; saveDict = nil;
        if (G_Mode == MODE_PLACE && !G_IsContent) {
            if (G_TargetID == 16) dataA = 3;  
            if (G_TargetID == 31) dataA = 255; 
            if (G_TargetID == 3)  dataA = 255;
        }
    }

    if (Real_FillTile) {
        Real_FillTile(self, _cmd, tilePtr, pos, type, dataA, dataB, client, saveDict, bh, clientName);
    }

    if (isTrigger && tilePtr) {
        uint8_t* rawMem = (uint8_t*)tilePtr;
        switch (G_Mode) {
            case MODE_PLACE: 
                if (G_IsContent) {
                    uint8_t baseBlock = BLOCK_STONE;
                    if (G_TargetID == 64) baseBlock = BLOCK_LIMESTONE;
                    else if (G_TargetID == 1 || G_TargetID == 2) baseBlock = BLOCK_DIRT; 
                    rawMem[0] = baseBlock;
                    rawMem[3] = (uint8_t)G_TargetID; 
                } else {
                    rawMem[0] = (uint8_t)G_TargetID;
                    rawMem[3] = 0; 
                }
                rawMem[4] = 0; 
                break;
            case MODE_WALL: 
                rawMem[0] = BLOCK_STONE;    
                rawMem[1] = (uint8_t)G_TargetID; 
                rawMem[3] = 0;
                rawMem[4] = 0;
                break;
            case MODE_BUILD: 
                for (int i = 0; i < G_BuildCount; i++) rawMem[i] = G_BuildBytes[i];
                break;
        }
    }
}

id Omni_Hook_HandleCmd(id self, SEL _cmd, id commandStr, id client) {
    const char* raw = GetString(commandStr);
    if (!raw) return Omni_Real_HandleCmd(self, _cmd, commandStr, client);
    char text[256]; strncpy(text, raw, 255); text[255] = 0;

    if (strncmp(text, "/place", 6) == 0) {
        char* token = strtok(text, " ");
        char* arg = strtok(NULL, " ");
        if (!arg || strcasecmp(arg, "off") == 0) {
            G_Mode = MODE_OFF;
            SendChat(self, ">> [Omni] Deactivated.");
            return nil;
        }
        int target = ParseID(arg, &G_IsContent);
        if (target > 0) {
            G_TargetID = target;
            G_Mode = MODE_PLACE;
            char msg[128];
            snprintf(msg, 128, ">> [Omni] Place Mode: %s (ID %d).", arg, target);
            SendChat(self, msg);
        } else {
            SendChat(self, ">> [Omni] Error: Unknown ID.");
        }
        return nil;
    }
    if (strncmp(text, "/wall", 5) == 0) {
        char* token = strtok(text, " ");
        char* arg = strtok(NULL, " ");
        if (!arg || strcasecmp(arg, "off") == 0) {
            G_Mode = MODE_OFF;
            SendChat(self, ">> [Omni] Deactivated.");
            return nil;
        }
        int target = ParseID(arg, NULL);
        if (target > 0) {
            G_TargetID = target;
            G_Mode = MODE_WALL;
            char msg[128]; 
            snprintf(msg, 128, ">> [Omni] Wall Mode: ID %d.", target);
            SendChat(self, msg);
        }
        return nil;
    }
    return Omni_Real_HandleCmd(self, _cmd, commandStr, client);
}

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
        if (mCmd) {
            Omni_Real_HandleCmd = (CmdFunc)method_getImplementation(mCmd);
            method_setImplementation(mCmd, (IMP)Omni_Hook_HandleCmd);
        }
        Method mChat = class_getInstanceMethod(clsServer, sel_registerName(SEL_CHAT));
        if (mChat) Omni_Real_SendChat = (ChatFunc)method_getImplementation(mChat);
    }
    return NULL;
}

__attribute__((constructor)) static void Entry() {
    pthread_t t; pthread_create(&t, NULL, InitThread, NULL);
}
