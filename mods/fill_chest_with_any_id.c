/*
 * Chest Filler
 * ----------------------------------------------------
 * Prefix: CFill_
 * Commands: /fill <ID> [DataA] [DataB]
 * /fill (Toggle OFF)
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

#define CF_SERVER_CLASS   "BHServer"
#define CF_CHEST_CLASS    "Chest"
#define CF_ITEM_CLASS     "InventoryItem"
#define CF_ARRAY_CLASS    "NSMutableArray"
#define CF_BASKET_ID      12

// --- IMP TYPES ---
typedef id (*CF_PlaceFunc)(id, SEL, id, id, long long, id, id, unsigned char, id, id, id);
typedef id (*CF_CmdFunc)(id, SEL, id, id);
typedef void (*CF_ChatFunc)(id, SEL, id, BOOL, id);

// Memory
typedef id (*CF_AllocFunc)(id, SEL);
typedef id (*CF_InitArrFunc)(id, SEL, unsigned long);
typedef id (*CF_InitItemFunc)(id, SEL, int, uint16_t, uint16_t, id, id);
typedef void (*CF_AddObjFunc)(id, SEL, id);
typedef void (*CF_RelFunc)(id, SEL);
typedef void (*CF_VoidFunc)(id, SEL);
typedef id (*CF_StrFunc)(id, SEL, const char*);
typedef const char* (*CF_Utf8Func)(id, SEL);

// --- GLOBALS ---
static CF_PlaceFunc Real_CFill_Place = NULL;
static CF_CmdFunc   Real_CFill_Cmd = NULL;
static CF_ChatFunc  Real_CFill_Chat = NULL;

static bool g_CFill_Active = false;
static int  g_CFill_TargetID = 0;
static int  g_CFill_DataA = 0;
static int  g_CFill_DataB = 0;

// --- UTILS ---
static void CFill_Release(id obj) {
    if (!obj) return;
    SEL s = sel_registerName("release");
    CF_RelFunc f = (CF_RelFunc)method_getImplementation(class_getInstanceMethod(object_getClass(obj), s));
    f(obj, s);
}

static id CFill_Pool() {
    Class cls = objc_getClass("NSAutoreleasePool");
    SEL sA = sel_registerName("alloc");
    SEL sI = sel_registerName("init");
    CF_AllocFunc fA = (CF_AllocFunc)method_getImplementation(class_getClassMethod(cls, sA));
    CF_AllocFunc fI = (CF_AllocFunc)method_getImplementation(class_getInstanceMethod(cls, sI));
    return fI(fA((id)cls, sA), sI);
}

static void CFill_Drain(id pool) {
    if (!pool) return;
    SEL s = sel_registerName("drain");
    CF_VoidFunc f = (CF_VoidFunc)method_getImplementation(class_getInstanceMethod(object_getClass(pool), s));
    f(pool, s);
}

static id CFill_Str(const char* txt) {
    if (!txt) return nil;
    Class cls = objc_getClass("NSString");
    SEL s = sel_registerName("stringWithUTF8String:");
    CF_StrFunc f = (CF_StrFunc)method_getImplementation(class_getClassMethod(cls, s));
    return f ? f((id)cls, s, txt) : nil;
}

static const char* CFill_CStr(id str) {
    if (!str) return "";
    SEL s = sel_registerName("UTF8String");
    CF_Utf8Func f = (CF_Utf8Func)method_getImplementation(class_getInstanceMethod(object_getClass(str), s));
    return f ? f(str, s) : "";
}

static void CFill_Msg(id server, const char* msg) {
    if (server && Real_CFill_Chat) {
        Real_CFill_Chat(server, sel_registerName("sendChatMessage:displayNotification:sendToClients:"), CFill_Str(msg), true, nil);
    }
}

// --- LOGIC ---

id CFill_CreateArray(int cap) {
    Class clsArr = objc_getClass(CF_ARRAY_CLASS);
    SEL sAlloc = sel_registerName("alloc");
    SEL sInit = sel_registerName("initWithCapacity:");
    
    CF_AllocFunc fAlloc = (CF_AllocFunc)method_getImplementation(class_getClassMethod(clsArr, sAlloc));
    CF_InitArrFunc fInit = (CF_InitArrFunc)method_getImplementation(class_getInstanceMethod(clsArr, sInit));
    
    id arr = fAlloc((id)clsArr, sAlloc);
    return fInit(arr, sInit, cap);
}

id CFill_CreateItem(int type, int dA, int dB, id subItems) {
    Class clsItem = objc_getClass(CF_ITEM_CLASS);
    SEL sAlloc = sel_registerName("alloc");
    SEL sInit = sel_registerName("initWithType:dataA:dataB:subItems:dynamicObjectSaveDict:");
    
    CF_AllocFunc fAlloc = (CF_AllocFunc)method_getImplementation(class_getClassMethod(clsItem, sAlloc));
    CF_InitItemFunc fInit = (CF_InitItemFunc)method_getImplementation(class_getInstanceMethod(clsItem, sInit));
    
    id item = fAlloc((id)clsItem, sAlloc);
    return fInit(item, sInit, type, (uint16_t)dA, (uint16_t)dB, subItems, nil);
}

id CFill_CreateMainInventory() {
    id mainArr = CFill_CreateArray(16);
    if (!mainArr) return nil;

    SEL sAdd = sel_registerName("addObject:");
    Method mAdd = class_getInstanceMethod(object_getClass(mainArr), sAdd);
    CF_AddObjFunc fAdd = (CF_AddObjFunc)method_getImplementation(mAdd);
    
    for(int i=0; i<16; i++) {
        // --- CANASTA ---
        id basketSubItems = CFill_CreateArray(4); // Array interno de la canasta
        
        for(int j=0; j<4; j++) {
            // --- SLOT DEL ITEM (Stack de 99) ---
            id slotArr = CFill_CreateArray(99); 
            Method mSlotAdd = class_getInstanceMethod(object_getClass(slotArr), sAdd);
            CF_AddObjFunc fSlotAdd = (CF_AddObjFunc)method_getImplementation(mSlotAdd);
            
            // Creamos 1 objeto item
            id content = CFill_CreateItem(g_CFill_TargetID, g_CFill_DataA, g_CFill_DataB, nil);
            
            // Agregamos el MISMO item 99 veces al array del slot
            if (content) {
                for(int k=0; k<99; k++) {
                    fSlotAdd(slotArr, sAdd, content);
                }
                CFill_Release(content); // El array ya lo retuvo 99 veces
            }
            
            // Agregamos el slot a la canasta
            fAdd(basketSubItems, sAdd, slotArr);
            CFill_Release(slotArr);
        }
        
        // --- OBJETO CANASTA ---
        id basket = CFill_CreateItem(CF_BASKET_ID, 0, 0, basketSubItems);
        CFill_Release(basketSubItems);
        
        // --- SLOT DE LA CANASTA (Para el cofre) ---
        id basketSlot = CFill_CreateArray(1);
        fAdd(basketSlot, sAdd, basket);
        CFill_Release(basket);
        
        // Agregar al cofre
        fAdd(mainArr, sAdd, basketSlot);
        CFill_Release(basketSlot);
    }
    
    return mainArr;
}

// --- HOOKS ---

id Hook_CFill_Place(id self, SEL _cmd, id w, id dw, long long pos, id cache, id item, unsigned char flip, id save, id client, id cName) {
    id chestObj = Real_CFill_Place(self, _cmd, w, dw, pos, cache, item, flip, save, client, cName);
    
    if (g_CFill_Active && chestObj && g_CFill_TargetID > 0) {
        id pool = CFill_Pool();
        
        Ivar ivInv = class_getInstanceVariable(object_getClass(chestObj), "inventoryItems");
        if (ivInv) {
            id newInv = CFill_CreateMainInventory();
            id* ptrToInv = (id*)((char*)chestObj + ivar_getOffset(ivInv));
            
            if (*ptrToInv) CFill_Release(*ptrToInv); // Liberar viejo
            *ptrToInv = newInv; // Asignar nuevo (Retained por alloc)
            
            SEL sUp = sel_registerName("contentsDidChange");
            if (class_getInstanceMethod(object_getClass(chestObj), sUp)) {
                CF_VoidFunc fUp = (CF_VoidFunc)method_getImplementation(class_getInstanceMethod(object_getClass(chestObj), sUp));
                fUp(chestObj, sUp);
            }
        }
        
        CFill_Drain(pool);
    }
    return chestObj;
}

id Hook_CFill_Cmd(id self, SEL _cmd, id cmdStr, id client) {
    const char* raw = CFill_CStr(cmdStr);
    if (!raw) return Real_CFill_Cmd(self, _cmd, cmdStr, client);
    
    if (strncmp(raw, "/fill", 5) == 0) {
        id pool = CFill_Pool();
        
        char buffer[256]; strncpy(buffer, raw, 255);
        char* token = strtok(buffer, " ");
        char* sID = strtok(NULL, " ");
        char* sDA = strtok(NULL, " ");
        char* sDB = strtok(NULL, " ");
        
        // Toggle inteligente: Si no hay args y está activo, apagar
        if (!sID) {
            if (g_CFill_Active) {
                g_CFill_Active = false;
                CFill_Msg(self, "[Fill] OFF.");
            } else {
                CFill_Msg(self, "[Usage] /fill <ID> [DataA] [DataB]");
            }
            CFill_Drain(pool);
            return nil;
        }
        
        if (strcasecmp(sID, "off") == 0) {
            g_CFill_Active = false;
            CFill_Msg(self, "[Fill] OFF.");
            CFill_Drain(pool);
            return nil;
        }
        
        g_CFill_TargetID = atoi(sID);
        g_CFill_DataA = sDA ? atoi(sDA) : 0;
        g_CFill_DataB = sDB ? atoi(sDB) : 0;
        g_CFill_Active = true;
        
        char msg[128];
        snprintf(msg, 128, "[Fill] ON. ID: %d (Data: %d, %d). 99x Stacks.", g_CFill_TargetID, g_CFill_DataA, g_CFill_DataB);
        CFill_Msg(self, msg);
        
        CFill_Drain(pool);
        return nil;
    }
    
    return Real_CFill_Cmd(self, _cmd, cmdStr, client);
}

// --- INIT ---
static void* CFill_Init(void* arg) {
    sleep(1);
    Class clsServer = objc_getClass(CF_SERVER_CLASS);
    if (clsServer) {
        Method mC = class_getInstanceMethod(clsServer, sel_registerName("handleCommand:issueClient:"));
        Real_CFill_Cmd = (CF_CmdFunc)method_getImplementation(mC);
        method_setImplementation(mC, (IMP)Hook_CFill_Cmd);
        Method mT = class_getInstanceMethod(clsServer, sel_registerName("sendChatMessage:displayNotification:sendToClients:"));
        Real_CFill_Chat = (CF_ChatFunc)method_getImplementation(mT);
    }
    Class clsChest = objc_getClass(CF_CHEST_CLASS);
    if (clsChest) {
        Method mP = class_getInstanceMethod(clsChest, sel_registerName("initWithWorld:dynamicWorld:atPosition:cache:item:flipped:saveDict:placedByClient:clientName:"));
        Real_CFill_Place = (CF_PlaceFunc)method_getImplementation(mP);
        method_setImplementation(mP, (IMP)Hook_CFill_Place);
    }
    return NULL;
}

__attribute__((constructor)) static void CFill_Entry() {
    pthread_t t; pthread_create(&t, NULL, CFill_Init, NULL);
}
