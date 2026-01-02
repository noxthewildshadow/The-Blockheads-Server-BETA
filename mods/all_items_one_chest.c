//Command: /godchest (then place an empty wood chest)

#define _GNU_SOURCE
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <objc/runtime.h>
#include <objc/message.h>

// --- CONFIG ---
#define ZOD_SERVER_CLASS   "BHServer"
#define ZOD_CHEST_CLASS    "Chest"
#define ZOD_ITEM_CLASS     "InventoryItem"
#define ZOD_ARRAY_CLASS    "NSMutableArray"
#define ZOD_POOL_CLASS     "NSAutoreleasePool"

#define ZOD_START_ID       1
#define ZOD_ITEMS_PER_SLOT 99
#define ZOD_SLOTS_MAX      16

// --- IMPS ---
typedef id (*ZOD_Alloc)(id, SEL);
typedef id (*ZOD_Init)(id, SEL);
typedef id (*ZOD_InitCap)(id, SEL, unsigned long);
typedef id (*ZOD_InitItem)(id, SEL, int, uint16_t, uint16_t, id, id);
typedef void (*ZOD_AddObj)(id, SEL, id);
typedef void (*ZOD_Release)(id, SEL);
typedef void (*ZOD_Drain)(id, SEL);
typedef id (*ZOD_String)(id, SEL, const char*);
typedef const char* (*ZOD_Utf8)(id, SEL);
typedef void (*ZOD_Void)(id, SEL);

// Hooks
typedef id (*ZOD_Place_IMP)(id, SEL, id, id, long long, id, id, unsigned char, id, id, id);
typedef id (*ZOD_Cmd_IMP)(id, SEL, id, id);
typedef void (*ZOD_Chat_IMP)(id, SEL, id, BOOL, id);

// --- GLOBALS ---
static ZOD_Place_IMP ZOD_Real_Place = NULL;
static ZOD_Cmd_IMP   ZOD_Real_Cmd = NULL;
static ZOD_Chat_IMP  ZOD_Real_Chat = NULL;
static bool          ZOD_Active = false;

// --- MEMORY HELPERS ---
static void ZOD_ReleaseObj(id obj) {
    if (!obj) return;
    SEL s = sel_registerName("release");
    Method m = class_getInstanceMethod(object_getClass(obj), s);
    if (m) {
        ZOD_Release f = (ZOD_Release)method_getImplementation(m);
        f(obj, s);
    }
}

static id ZOD_Pool() {
    Class cls = objc_getClass(ZOD_POOL_CLASS);
    SEL sA = sel_registerName("alloc");
    SEL sI = sel_registerName("init");
    ZOD_Alloc fA = (ZOD_Alloc)method_getImplementation(class_getClassMethod(cls, sA));
    ZOD_Init fI = (ZOD_Init)method_getImplementation(class_getInstanceMethod(cls, sI));
    return fI(fA((id)cls, sA), sI);
}

static void ZOD_DrainPool(id pool) {
    if (!pool) return;
    SEL s = sel_registerName("drain");
    ZOD_Drain f = (ZOD_Drain)method_getImplementation(class_getInstanceMethod(object_getClass(pool), s));
    if (f) f(pool, s);
}

static id ZOD_Str(const char* t) {
    Class cls = objc_getClass("NSString");
    SEL s = sel_registerName("stringWithUTF8String:");
    ZOD_String f = (ZOD_String)method_getImplementation(class_getClassMethod(cls, s));
    return f((id)cls, s, t);
}

static const char* ZOD_CStr(id str) {
    if (!str) return "";
    SEL s = sel_registerName("UTF8String");
    ZOD_Utf8 f = (ZOD_Utf8)method_getImplementation(class_getInstanceMethod(object_getClass(str), s));
    return f ? f(str, s) : "";
}

static void ZOD_Msg(id srv, const char* msg) {
    if (srv && ZOD_Real_Chat) {
        ZOD_Real_Chat(srv, sel_registerName("sendChatMessage:displayNotification:sendToClients:"), ZOD_Str(msg), true, nil);
    }
}

// --- LOGIC ---
id ZOD_NewItem(int type) {
    Class cls = objc_getClass(ZOD_ITEM_CLASS);
    SEL sAlloc = sel_registerName("alloc");
    SEL sInit = sel_registerName("initWithType:dataA:dataB:subItems:dynamicObjectSaveDict:");
    ZOD_Alloc fA = (ZOD_Alloc)method_getImplementation(class_getClassMethod(cls, sAlloc));
    ZOD_InitItem fI = (ZOD_InitItem)method_getImplementation(class_getInstanceMethod(cls, sInit));
    return fI(fA((id)cls, sAlloc), sInit, type, 0, 0, nil, nil);
}

id ZOD_NewArray(int cap) {
    Class cls = objc_getClass(ZOD_ARRAY_CLASS);
    SEL sAlloc = sel_registerName("alloc");
    SEL sInit = sel_registerName("initWithCapacity:");
    ZOD_Alloc fA = (ZOD_Alloc)method_getImplementation(class_getClassMethod(cls, sAlloc));
    ZOD_InitCap fI = (ZOD_InitCap)method_getImplementation(class_getInstanceMethod(cls, sInit));
    return fI(fA((id)cls, sAlloc), sInit, cap);
}

id ZOD_GenInventory() {
    id mainInv = ZOD_NewArray(ZOD_SLOTS_MAX);
    SEL sAdd = sel_registerName("addObject:");
    ZOD_AddObj fAdd = (ZOD_AddObj)method_getImplementation(class_getInstanceMethod(object_getClass(mainInv), sAdd));

    int cID = ZOD_START_ID;

    for (int i = 0; i < ZOD_SLOTS_MAX; i++) {
        id slot = ZOD_NewArray(ZOD_ITEMS_PER_SLOT);
        ZOD_AddObj fSlotAdd = (ZOD_AddObj)method_getImplementation(class_getInstanceMethod(object_getClass(slot), sAdd));

        for (int k = 0; k < ZOD_ITEMS_PER_SLOT; k++) {
            id item = ZOD_NewItem(cID++);
            if (item) {
                fSlotAdd(slot, sAdd, item);
                ZOD_ReleaseObj(item);
            }
        }
        fAdd(mainInv, sAdd, slot);
        ZOD_ReleaseObj(slot);
    }
    return mainInv;
}

// --- HOOKS ---
id ZOD_Place(id self, SEL _cmd, id w, id dw, long long pos, id cache, id item, unsigned char flip, id save, id client, id cName) {
    id chest = ZOD_Real_Place(self, _cmd, w, dw, pos, cache, item, flip, save, client, cName);
    
    if (ZOD_Active && chest) {
        id pool = ZOD_Pool();
        Ivar iv = class_getInstanceVariable(object_getClass(chest), "inventoryItems");
        if (iv) {
            id* ptr = (id*)((char*)chest + ivar_getOffset(iv));
            if (*ptr) ZOD_ReleaseObj(*ptr);
            *ptr = ZOD_GenInventory();
            
            SEL sUp = sel_registerName("contentsDidChange");
            Method mUp = class_getInstanceMethod(object_getClass(chest), sUp);
            if (mUp) {
                ZOD_Void fUp = (ZOD_Void)method_getImplementation(mUp);
                fUp(chest, sUp);
            }
        }
        ZOD_DrainPool(pool);
    }
    return chest;
}

id ZOD_Cmd(id self, SEL _cmd, id cmdStr, id client) {
    const char* t = ZOD_CStr(cmdStr);
    if (t && strcasecmp(t, "/godchest") == 0) {
        ZOD_Active = !ZOD_Active;
        ZOD_Msg(self, ZOD_Active ? "[GODCHEST] ON" : "[GODCHEST] OFF");
        return nil;
    }
    return ZOD_Real_Cmd(self, _cmd, cmdStr, client);
}

// --- INIT ---
static void* ZOD_Loader(void* arg) {
    sleep(1);
    Class srv = objc_getClass(ZOD_SERVER_CLASS);
    Class cht = objc_getClass(ZOD_CHEST_CLASS);
    if (srv && cht) {
        SEL sC = sel_registerName("handleCommand:issueClient:");
        ZOD_Real_Cmd = (ZOD_Cmd_IMP)method_getImplementation(class_getInstanceMethod(srv, sC));
        method_setImplementation(class_getInstanceMethod(srv, sC), (IMP)ZOD_Cmd);
        
        SEL sM = sel_registerName("sendChatMessage:displayNotification:sendToClients:");
        ZOD_Real_Chat = (ZOD_Chat_IMP)method_getImplementation(class_getInstanceMethod(srv, sM));
        
        SEL sP = sel_registerName("initWithWorld:dynamicWorld:atPosition:cache:item:flipped:saveDict:placedByClient:clientName:");
        ZOD_Real_Place = (ZOD_Place_IMP)method_getImplementation(class_getInstanceMethod(cht, sP));
        method_setImplementation(class_getInstanceMethod(cht, sP), (IMP)ZOD_Place);
    }
    return NULL;
}

__attribute__((constructor)) static void ZOD_Entry() {
    pthread_t t; pthread_create(&t, NULL, ZOD_Loader, NULL);
}
