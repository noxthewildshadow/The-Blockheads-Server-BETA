/*
 * Chest Filler (Glitch Items)
 * Commands:
 * /fill <ID> <DataA> <DataB>
 * /fill off
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

// --- ISOLATION CONFIGURATION ---
#define CFILL_SERVER_CLASS    "BHServer"
#define CFILL_CHEST_CLASS     "Chest"
#define CFILL_ITEM_CLASS      "InventoryItem"
#define CFILL_BASKET_ID       12

// --- SELECTORS ---
#define CFILL_SEL_PLACE     "initWithWorld:dynamicWorld:atPosition:cache:item:flipped:saveDict:placedByClient:clientName:"
#define CFILL_SEL_CMD       "handleCommand:issueClient:"
#define CFILL_SEL_CHAT      "sendChatMessage:sendToClients:"
#define CFILL_SEL_UTF8      "UTF8String"
#define CFILL_SEL_STR       "stringWithUTF8String:"
#define CFILL_SEL_ALLOC     "alloc"
#define CFILL_SEL_INIT_CAP  "initWithCapacity:"
#define CFILL_SEL_ADD_OBJ   "addObject:"
#define CFILL_SEL_UPDATE    "contentsDidChange"
#define CFILL_SEL_INIT_ITEM "initWithType:dataA:dataB:subItems:dynamicObjectSaveDict:"
#define CFILL_SEL_MAX_STACK "maxStackSize"

// --- TYPES ---
typedef id   (*CFill_PlaceFunc)(id, SEL, id, id, long long, id, id, unsigned char, id, id, id);
typedef id   (*CFill_CmdFunc)(id, SEL, id, id);
typedef void (*CFill_ChatFunc)(id, SEL, id, id);
typedef const char* (*CFill_StrFunc)(id, SEL);
typedef id   (*CFill_StringFactoryFunc)(id, SEL, const char*);
typedef void (*CFill_VoidFunc)(id, SEL);
typedef id   (*CFill_AllocFunc)(id, SEL);
typedef void (*CFill_AddObjFunc)(id, SEL, id);
typedef id   (*CFill_InitArrFunc)(id, SEL, unsigned long);
typedef id   (*CFill_InitItemFunc)(id, SEL, int, uint16_t, uint16_t, id, id);
typedef int  (*CFill_IntFunc)(id, SEL);

// --- STATE ---
static CFill_PlaceFunc CFILL_Real_Place = NULL;
static CFill_CmdFunc   CFILL_Real_Cmd   = NULL;
static CFill_ChatFunc  CFILL_Real_Chat  = NULL;
static CFill_IntFunc   CFILL_Real_Max   = NULL;

static bool    CFILL_Active = false;
static int     CFILL_TargetID = 0;
static int16_t CFILL_DataA = 0;
static int16_t CFILL_DataB = 0;

// --- UTILS ---
static const char* CFILL_GetStr(id strObj) {
    if (!strObj) return "";
    SEL sel = sel_registerName(CFILL_SEL_UTF8);
    CFill_StrFunc f = (CFill_StrFunc)class_getMethodImplementation(object_getClass(strObj), sel);
    return f ? f(strObj, sel) : "";
}

static id CFILL_AllocStr(const char* text) {
    Class cls = objc_getClass("NSString");
    SEL sel = sel_registerName(CFILL_SEL_STR);
    CFill_StringFactoryFunc f = (CFill_StringFactoryFunc)method_getImplementation(class_getClassMethod(cls, sel));
    return f ? f((id)cls, sel, text) : nil;
}

static void CFILL_SendChat(id server, const char* msg) {
    if (server && CFILL_Real_Chat) {
        CFILL_Real_Chat(server, sel_registerName(CFILL_SEL_CHAT), CFILL_AllocStr(msg), nil);
    }
}

IMP CFILL_GetInstMethod(id instance, SEL sel) {
    if (!instance) return NULL;
    return method_getImplementation(class_getInstanceMethod(object_getClass(instance), sel));
}

// --- LOGIC: FORCE MAX STACK ---
int CFILL_Hook_MaxStack(id self, SEL _cmd) { return 99; }

// --- LOGIC: CREATE ITEM WITH DATA ---
id CFILL_CreateItem(int itemID, int16_t dA, int16_t dB) {
    Class clsItem = objc_getClass(CFILL_ITEM_CLASS);
    if (!clsItem) return nil;

    SEL sAlloc = sel_registerName(CFILL_SEL_ALLOC);
    CFill_AllocFunc fAlloc = (CFill_AllocFunc)method_getImplementation(class_getClassMethod(clsItem, sAlloc));
    id rawItem = fAlloc((id)clsItem, sAlloc);

    SEL sInit = sel_registerName(CFILL_SEL_INIT_ITEM);
    CFill_InitItemFunc fInit = (CFill_InitItemFunc)method_getImplementation(class_getInstanceMethod(clsItem, sInit));
    rawItem = fInit(rawItem, sInit, itemID, 1, 0, nil, nil);

    unsigned int outCount = 0;
    Ivar *ivars = class_copyIvarList(object_getClass(rawItem), &outCount);
    if (ivars) {
        for (unsigned int i = 0; i < outCount; i++) {
            const char* name = ivar_getName(ivars[i]);
            if (strstr(name, "dataA") || strstr(name, "DataA")) {
                int16_t* ptr = (int16_t*)((char*)rawItem + ivar_getOffset(ivars[i]));
                *ptr = dA;
            } 
            else if (strstr(name, "dataB") || strstr(name, "DataB")) {
                int16_t* ptr = (int16_t*)((char*)rawItem + ivar_getOffset(ivars[i]));
                *ptr = dB;
            }
        }
        free(ivars);
    }
    return rawItem;
}

// --- LOGIC: BASKET FILLER ---
void CFILL_InjectSubItems(id basket, id array) {
    unsigned int outCount = 0;
    Ivar *ivars = class_copyIvarList(object_getClass(basket), &outCount);
    if (ivars) {
        for (unsigned int i = 0; i < outCount; i++) {
            if (strcmp(ivar_getName(ivars[i]), "subItems") == 0) {
                id* ptr = (id*)((char*)basket + ivar_getOffset(ivars[i]));
                *ptr = array;
                break;
            }
        }
        free(ivars);
    }
}

id CFILL_CreateBasket() {
    id basket = CFILL_CreateItem(CFILL_BASKET_ID, 0, 0);
    
    Class clsArray = objc_getClass("NSMutableArray");
    SEL sAlloc = sel_registerName(CFILL_SEL_ALLOC);
    SEL sInitCap = sel_registerName(CFILL_SEL_INIT_CAP);
    SEL sAdd = sel_registerName(CFILL_SEL_ADD_OBJ);
    
    CFill_AllocFunc fAllocArr = (CFill_AllocFunc)method_getImplementation(class_getClassMethod(clsArray, sAlloc));
    id subItems = fAllocArr((id)clsArray, sAlloc);
    CFill_InitArrFunc fInitArr = (CFill_InitArrFunc)CFILL_GetInstMethod(subItems, sInitCap);
    if(fInitArr) subItems = fInitArr(subItems, sInitCap, 4);
    CFill_AddObjFunc fAdd = (CFill_AddObjFunc)CFILL_GetInstMethod(subItems, sAdd);

    for(int i=0; i<4; i++) {
        id content = CFILL_CreateItem(CFILL_TargetID, CFILL_DataA, CFILL_DataB);
        if(content) {
            id slot = fAllocArr((id)clsArray, sAlloc);
            CFill_InitArrFunc fInitSlot = (CFill_InitArrFunc)CFILL_GetInstMethod(slot, sInitCap);
            if(fInitSlot) slot = fInitSlot(slot, sInitCap, 99);
            CFill_AddObjFunc fAddSlot = (CFill_AddObjFunc)CFILL_GetInstMethod(slot, sAdd);
            
            for(int k=0; k<99; k++) fAddSlot(slot, sAdd, content);
            fAdd(subItems, sAdd, slot);
        }
    }
    CFILL_InjectSubItems(basket, subItems);
    return basket;
}

// --- HOOK: PLACE CHEST ---
id CFILL_Hook_Place(id self, SEL _cmd, id w, id dw, long long p, id c, id i, unsigned char f, id s, id cl, id cn) {
    id obj = CFILL_Real_Place(self, _cmd, w, dw, p, c, i, f, s, cl, cn);
    
    if (obj && CFILL_Active && CFILL_TargetID != 0) {
         Ivar ivInv = class_getInstanceVariable(object_getClass(obj), "inventoryItems");
         if (ivInv) {
            id* ptrArray = (id*)((char*)obj + ivar_getOffset(ivInv));
            
            Class clsArray = objc_getClass("NSMutableArray");
            SEL sAlloc = sel_registerName(CFILL_SEL_ALLOC); 
            SEL sInitCap = sel_registerName(CFILL_SEL_INIT_CAP);
            SEL sAdd = sel_registerName(CFILL_SEL_ADD_OBJ);
            CFill_AllocFunc fAllocArr = (CFill_AllocFunc)method_getImplementation(class_getClassMethod(clsArray, sAlloc));
            
            id mainInv = fAllocArr((id)clsArray, sAlloc);
            CFill_InitArrFunc fInitArr = (CFill_InitArrFunc)CFILL_GetInstMethod(mainInv, sInitCap);
            if(fInitArr) mainInv = fInitArr(mainInv, sInitCap, 16);
            *ptrArray = mainInv;
            
            CFill_AddObjFunc fAddMain = (CFill_AddObjFunc)CFILL_GetInstMethod(mainInv, sAdd);

            if(fAddMain) {
                for(int k=0; k<16; k++) {
                    id basket = CFILL_CreateBasket();
                    
                    id slot = fAllocArr((id)clsArray, sAlloc);
                    CFill_InitArrFunc fInitSlot = (CFill_InitArrFunc)CFILL_GetInstMethod(slot, sInitCap);
                    if(fInitSlot) slot = fInitSlot(slot, sInitCap, 1);
                    CFill_AddObjFunc fAddSlot = (CFill_AddObjFunc)CFILL_GetInstMethod(slot, sAdd);
                    
                    fAddSlot(slot, sAdd, basket);
                    fAddMain(mainInv, sAdd, slot);
                }
            }
            SEL sUpdate = sel_registerName(CFILL_SEL_UPDATE);
            CFill_VoidFunc fUp = (CFill_VoidFunc)CFILL_GetInstMethod(obj, sUpdate);
            if(fUp) fUp(obj, sUpdate);
         }
    }
    return obj;
}

// --- HOOK: COMMANDS ---
id CFILL_Hook_Cmd(id self, SEL _cmd, id commandStr, id client) {
    const char* raw = CFILL_GetStr(commandStr);
    if (!raw) return CFILL_Real_Cmd(self, _cmd, commandStr, client);
    char text[256]; strncpy(text, raw, 255); text[255] = 0;

    if (strncmp(text, "/fill", 5) == 0) {
        char* token = strtok(text, " ");
        char* sArg1 = strtok(NULL, " "); 
        char* sArg2 = strtok(NULL, " "); 
        char* sArg3 = strtok(NULL, " "); 

        if (!sArg1 || strcasecmp(sArg1, "off") == 0) {
            CFILL_Active = false;
            CFILL_TargetID = 0;
            CFILL_SendChat(self, ">> [Fill] Mode: OFF.");
            return nil;
        }

        int parsedID = atoi(sArg1);
        if (parsedID > 0) {
            CFILL_TargetID = parsedID;
            
            CFILL_DataA = (sArg2) ? (int16_t)atoi(sArg2) : 0;
            CFILL_DataB = (sArg3) ? (int16_t)atoi(sArg3) : 0;

            CFILL_Active = true;
            
            char msg[128];
            if (sArg2 || sArg3) {
                snprintf(msg, 128, ">> [Fill] Glitch Mode: ID %d (DataA:%d DataB:%d)", CFILL_TargetID, CFILL_DataA, CFILL_DataB);
            } else {
                snprintf(msg, 128, ">> [Fill] Clean Mode: ID %d", CFILL_TargetID);
            }
            CFILL_SendChat(self, msg);
        } else {
            CFILL_SendChat(self, ">> [Error] Invalid Item ID.");
        }
        return nil;
    }

    return CFILL_Real_Cmd(self, _cmd, commandStr, client);
}

// --- INIT ---
static void* CFILL_InitThread(void* arg) {
    sleep(1);
    
    Class clsChest = objc_getClass(CFILL_CHEST_CLASS);
    if (clsChest) {
        Method m = class_getInstanceMethod(clsChest, sel_registerName(CFILL_SEL_PLACE));
        CFILL_Real_Place = (CFill_PlaceFunc)method_getImplementation(m);
        method_setImplementation(m, (IMP)CFILL_Hook_Place);
    }

    Class clsItem = objc_getClass(CFILL_ITEM_CLASS);
    if (clsItem) {
        SEL sMax = sel_registerName(CFILL_SEL_MAX_STACK);
        Method mMax = class_getInstanceMethod(clsItem, sMax);
        CFILL_Real_Max = (CFill_IntFunc)method_getImplementation(mMax);
        method_setImplementation(mMax, (IMP)CFILL_Hook_MaxStack);
    }

    Class clsServer = objc_getClass(CFILL_SERVER_CLASS);
    if (clsServer) {
        Method mCmd = class_getInstanceMethod(clsServer, sel_registerName(CFILL_SEL_CMD));
        CFILL_Real_Cmd = (CFill_CmdFunc)method_getImplementation(mCmd);
        method_setImplementation(mCmd, (IMP)CFILL_Hook_Cmd);
        
        Method mChat = class_getInstanceMethod(clsServer, sel_registerName(CFILL_SEL_CHAT));
        CFILL_Real_Chat = (CFill_ChatFunc)method_getImplementation(mChat);
    }
    return NULL;
}

__attribute__((constructor)) static void CFILL_Entry() {
    pthread_t t; pthread_create(&t, NULL, CFILL_InitThread, NULL);
}
