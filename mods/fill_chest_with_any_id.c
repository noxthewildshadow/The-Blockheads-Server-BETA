/*
 * Name: patch_chest_filler.c
 * Description: Fills chests with any ID/Data upon placement.
 * Commands: /fill <ID> [DataA] [DataB], /fill off
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

// --- Configuration ---
#define FILL_SERVER_CLASS     "BHServer"
#define FILL_CHEST_CLASS      "Chest"
#define FILL_ITEM_CLASS       "InventoryItem"
#define FILL_BASKET_ID        12

// --- Typedefs ---
typedef id   (*Fill_PlaceFunc)(id, SEL, id, id, long long, id, id, unsigned char, id, id, id);
typedef id   (*Fill_CmdFunc)(id, SEL, id, id);
typedef void (*Fill_ChatFunc)(id, SEL, id, id);
typedef const char* (*Fill_StrFunc)(id, SEL);
typedef id   (*Fill_AllocFunc)(id, SEL);
typedef void (*Fill_AddObjFunc)(id, SEL, id);
typedef id   (*Fill_InitArrFunc)(id, SEL, unsigned long);
typedef id   (*Fill_InitItemFunc)(id, SEL, int, uint16_t, uint16_t, id, id);
typedef int  (*Fill_IntFunc)(id, SEL);
typedef void (*Fill_VoidFunc)(id, SEL);

// --- Globals ---
static Fill_PlaceFunc Real_Place = NULL;
static Fill_CmdFunc   Real_Cmd   = NULL;
static Fill_ChatFunc  Real_Chat  = NULL;

static bool    g_FillActive = false;
static int     g_FillID = 0;
static int16_t g_FillDataA = 0;
static int16_t g_FillDataB = 0;

// --- Helpers ---
static id Fill_AllocStr(const char* text) {
    if(!text) return nil;
    Class cls = objc_getClass("NSString");
    SEL sel = sel_registerName("stringWithUTF8String:");
    Fill_AllocFunc f = (Fill_AllocFunc)method_getImplementation(class_getClassMethod(cls, sel));
    return f ? ((id(*)(id,SEL,const char*))f)((id)cls, sel, text) : nil;
}

static const char* Fill_GetStr(id strObj) {
    if (!strObj) return "";
    SEL sel = sel_registerName("UTF8String");
    Fill_StrFunc f = (Fill_StrFunc)class_getMethodImplementation(object_getClass(strObj), sel);
    return f ? f(strObj, sel) : "";
}

static void Fill_Chat(id server, const char* msg) {
    if (server && Real_Chat) {
        Real_Chat(server, sel_registerName("sendChatMessage:sendToClients:"), Fill_AllocStr(msg), nil);
    }
}

IMP Fill_GetMethod(id obj, const char* name) {
    if (!obj) return NULL;
    return class_getMethodImplementation(object_getClass(obj), sel_registerName(name));
}

// --- Logic ---

int Hook_MaxStack(id self, SEL _cmd) { return 99; }

id Fill_CreateItem(int itemID, int16_t dA, int16_t dB) {
    Class clsItem = objc_getClass(FILL_ITEM_CLASS);
    if (!clsItem) return nil;

    SEL sAlloc = sel_registerName("alloc");
    SEL sInit = sel_registerName("initWithType:dataA:dataB:subItems:dynamicObjectSaveDict:");
    
    Fill_AllocFunc fAlloc = (Fill_AllocFunc)method_getImplementation(class_getClassMethod(clsItem, sAlloc));
    id item = fAlloc((id)clsItem, sAlloc);
    
    Fill_InitItemFunc fInit = (Fill_InitItemFunc)method_getImplementation(class_getInstanceMethod(clsItem, sInit));
    item = fInit(item, sInit, itemID, 1, 0, nil, nil);

    // Force Data
    unsigned int outCount = 0;
    Ivar *ivars = class_copyIvarList(object_getClass(item), &outCount);
    if (ivars) {
        for (unsigned int i = 0; i < outCount; i++) {
            const char* name = ivar_getName(ivars[i]);
            if (strcasecmp(name, "dataA") == 0) {
                *(int16_t*)((char*)item + ivar_getOffset(ivars[i])) = dA;
            } else if (strcasecmp(name, "dataB") == 0) {
                *(int16_t*)((char*)item + ivar_getOffset(ivars[i])) = dB;
            }
        }
        free(ivars);
    }
    return item;
}

id Fill_CreateBasket() {
    id basket = Fill_CreateItem(FILL_BASKET_ID, 0, 0);
    
    Class clsArr = objc_getClass("NSMutableArray");
    SEL sAlloc = sel_registerName("alloc");
    SEL sInit = sel_registerName("initWithCapacity:");
    SEL sAdd = sel_registerName("addObject:");

    Fill_AllocFunc fAlloc = (Fill_AllocFunc)method_getImplementation(class_getClassMethod(clsArr, sAlloc));
    id subItems = fAlloc((id)clsArr, sAlloc);
    
    Fill_InitArrFunc fInit = (Fill_InitArrFunc)Fill_GetMethod(subItems, "initWithCapacity:");
    subItems = fInit(subItems, sInit, 4);
    
    Fill_AddObjFunc fAdd = (Fill_AddObjFunc)Fill_GetMethod(subItems, "addObject:");

    // 4 Slots
    for(int i=0; i<4; i++) {
        id content = Fill_CreateItem(g_FillID, g_FillDataA, g_FillDataB);
        if(content) {
             id slot = fAlloc((id)clsArr, sAlloc);
             fInit(slot, sInit, 99);
             for(int k=0; k<99; k++) fAdd(slot, sAdd, content);
             fAdd(subItems, sAdd, slot);
        }
    }
    
    // Inject subItems into basket
    Ivar iv = class_getInstanceVariable(object_getClass(basket), "subItems");
    if (iv) *(id*)((char*)basket + ivar_getOffset(iv)) = subItems;
    
    return basket;
}

id Hook_ChestPlace(id self, SEL _cmd, id w, id dw, long long p, id c, id i, unsigned char f, id s, id cl, id cn) {
    id obj = Real_Place(self, _cmd, w, dw, p, c, i, f, s, cl, cn);
    
    if (obj && g_FillActive && g_FillID != 0) {
         Ivar ivInv = class_getInstanceVariable(object_getClass(obj), "inventoryItems");
         if (ivInv) {
            id* ptrArray = (id*)((char*)obj + ivar_getOffset(ivInv));
            
            Class clsArr = objc_getClass("NSMutableArray");
            SEL sAlloc = sel_registerName("alloc");
            SEL sInit = sel_registerName("initWithCapacity:");
            SEL sAdd = sel_registerName("addObject:");
            
            Fill_AllocFunc fAlloc = (Fill_AllocFunc)method_getImplementation(class_getClassMethod(clsArr, sAlloc));
            id mainInv = fAlloc((id)clsArr, sAlloc);
            
            Fill_InitArrFunc fInit = (Fill_InitArrFunc)Fill_GetMethod(mainInv, "initWithCapacity:");
            mainInv = fInit(mainInv, sInit, 16);
            
            Fill_AddObjFunc fAddMain = (Fill_AddObjFunc)Fill_GetMethod(mainInv, "addObject:");

            for(int k=0; k<16; k++) {
                id basket = Fill_CreateBasket();
                id slot = fAlloc((id)clsArr, sAlloc);
                fInit(slot, sInit, 1);
                fAddMain(slot, sAdd, basket); // Add basket to slot
                fAddMain(mainInv, sAdd, slot); // Add slot to inv
            }
            
            *ptrArray = mainInv;
            
            // Visual Update
            SEL sUp = sel_registerName("contentsDidChange");
            Fill_VoidFunc fUp = (Fill_VoidFunc)Fill_GetMethod(obj, "contentsDidChange");
            if(fUp) fUp(obj, sUp);
         }
    }
    return obj;
}

id Hook_Fill_Cmd(id self, SEL _cmd, id cmdStr, id client) {
    const char* raw = Fill_GetStr(cmdStr);
    if (!raw) return Real_Cmd(self, _cmd, cmdStr, client);
    
    char text[256]; strncpy(text, raw, 255); text[255] = 0;

    if (strncmp(text, "/fill", 5) == 0) {
        char* token = strtok(text, " ");
        char* sArg1 = strtok(NULL, " ");
        char* sArg2 = strtok(NULL, " ");
        char* sArg3 = strtok(NULL, " ");

        if (!sArg1 || strcasecmp(sArg1, "off") == 0) {
            g_FillActive = false;
            g_FillID = 0;
            Fill_Chat(self, "[Fill] OFF.");
            return nil;
        }

        g_FillID = atoi(sArg1);
        if (g_FillID > 0) {
            g_FillDataA = (sArg2) ? (int16_t)atoi(sArg2) : 0;
            g_FillDataB = (sArg3) ? (int16_t)atoi(sArg3) : 0;
            g_FillActive = true;
            
            char msg[128];
            snprintf(msg, sizeof(msg), "[Fill] ON. Item ID: %d (DA:%d DB:%d)", g_FillID, g_FillDataA, g_FillDataB);
            Fill_Chat(self, msg);
        } else {
             Fill_Chat(self, "[Error] Invalid ID.");
        }
        return nil;
    }
    return Real_Cmd(self, _cmd, cmdStr, client);
}

static void* Fill_InitThread(void* arg) {
    sleep(1);
    
    Class clsChest = objc_getClass(FILL_CHEST_CLASS);
    if (clsChest) {
        Method m = class_getInstanceMethod(clsChest, sel_registerName("initWithWorld:dynamicWorld:atPosition:cache:item:flipped:saveDict:placedByClient:clientName:"));
        Real_Place = (Fill_PlaceFunc)method_getImplementation(m);
        method_setImplementation(m, (IMP)Hook_ChestPlace);
    }
    
    Class clsItem = objc_getClass(FILL_ITEM_CLASS);
    if (clsItem) {
        Method mMax = class_getInstanceMethod(clsItem, sel_registerName("maxStackSize"));
        method_setImplementation(mMax, (IMP)Hook_MaxStack);
    }

    Class clsServer = objc_getClass(FILL_SERVER_CLASS);
    if (clsServer) {
        Method mCmd = class_getInstanceMethod(clsServer, sel_registerName("handleCommand:issueClient:"));
        Real_Cmd = (Fill_CmdFunc)method_getImplementation(mCmd);
        method_setImplementation(mCmd, (IMP)Hook_Fill_Cmd);
        
        Method mChat = class_getInstanceMethod(clsServer, sel_registerName("sendChatMessage:sendToClients:"));
        Real_Chat = (Fill_ChatFunc)method_getImplementation(mChat);
    }
    return NULL;
}

__attribute__((constructor)) static void Fill_Entry() {
    pthread_t t; pthread_create(&t, NULL, Fill_InitThread, NULL);
}
