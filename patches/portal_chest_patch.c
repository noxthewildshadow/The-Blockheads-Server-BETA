/*
 * Portal Chest Ban & Refund
 * Blocks ID 1074
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
#include <pthread.h>
#include <objc/runtime.h>
#include <objc/message.h>

#define TARGET_CLASS "Chest"
#define BLOCKED_ID   1074

#define SEL_PLACE  "initWithWorld:dynamicWorld:atPosition:cache:item:flipped:saveDict:placedByClient:clientName:"
#define SEL_LOAD   "initWithWorld:dynamicWorld:saveDict:cache:"
#define SEL_POS    "pos"
#define SEL_TYPE   "itemType"
#define SEL_DROP   "destroyItemType"
#define SEL_SPAWN  "createFreeBlockAtPosition:ofType:dataA:dataB:subItems:dynamicObjectSaveDict:hovers:playSound:priorityBlockhead:"
#define SEL_REMOVE "remove:"
#define SEL_FLAG   "setNeedsRemoved:"
#define SEL_UTF8   "UTF8String"
#define SEL_COUNT  "count"
#define SEL_OBJ_IDX "objectAtIndex:"
#define SEL_NAME    "clientName"
#define SEL_ALL_NET "allBlockheadsIncludingNet"

// --- TYPEDEFS ---
typedef id (*PlaceFunc)(id, SEL, id, id, long long, id, id, unsigned char, id, id, id);
typedef id (*LoadFunc)(id, SEL, id, id, id, id);
typedef id (*SpawnFunc)(id, SEL, long long, int, int, int, id, id, BOOL, BOOL, id);
typedef const char* (*StrFunc)(id, SEL);
typedef int (*IntFunc)(id, SEL);
typedef void (*VoidBoolFunc)(id, SEL, BOOL);
typedef id (*ListFunc)(id, SEL);
typedef int (*CountFunc)(id, SEL);
typedef id (*ObjIdxFunc)(id, SEL, unsigned long);

static PlaceFunc Portal_Real_Place = NULL;
static LoadFunc  Portal_Real_Load  = NULL;

static const char* Portal_GetStr(id str) {
    if (!str) return "";
    SEL s = sel_registerName(SEL_UTF8);
    StrFunc f = (StrFunc)class_getMethodImplementation(object_getClass(str), s);
    return f ? f(str, s) : "";
}

static const char* Portal_GetBlockheadName(id bh) {
    if (!bh) return NULL;
    SEL sName = sel_registerName(SEL_NAME);
    if (class_getInstanceMethod(object_getClass(bh), sName)) {
        StrFunc f = (StrFunc)class_getMethodImplementation(object_getClass(bh), sName);
        if (f) {
            id s = ((id (*)(id, SEL))f)(bh, sName);
            return Portal_GetStr(s);
        }
    }
    Ivar iv = class_getInstanceVariable(object_getClass(bh), "clientName");
    if (iv) {
        id str = *(id*)((char*)bh + ivar_getOffset(iv));
        return Portal_GetStr(str);
    }
    return NULL;
}

static int Portal_GetID(id obj) {
    if (!obj) return 0;
    SEL s = sel_registerName(SEL_TYPE);
    IntFunc f = (IntFunc)class_getMethodImplementation(object_getClass(obj), s);
    return f ? f(obj, s) : 0;
}

static int Portal_GetDropID(id obj) {
    if (!obj) return 0;
    SEL s = sel_registerName(SEL_DROP);
    IntFunc f = (IntFunc)class_getMethodImplementation(object_getClass(obj), s);
    return f ? f(obj, s) : 0;
}

static long long Portal_GetPos(id obj) {
    if (!obj) return -1;
    SEL s = sel_registerName(SEL_POS);
    long long (*f)(id, SEL) = (void*)class_getMethodImplementation(object_getClass(obj), s);
    return f ? f(obj, s) : -1;
}

static id Portal_ScanList(id list, const char* targetName) {
    if (!list) return nil;
    SEL sCount = sel_registerName(SEL_COUNT);
    SEL sIdx = sel_registerName(SEL_OBJ_IDX);
    
    CountFunc fCnt = (CountFunc)class_getMethodImplementation(object_getClass(list), sCount);
    ObjIdxFunc fIdx = (ObjIdxFunc)class_getMethodImplementation(object_getClass(list), sIdx);
    
    if (!fCnt || !fIdx) return nil;

    int count = fCnt(list, sCount);
    for (int i = 0; i < count; i++) {
        id bh = fIdx(list, sIdx, i);
        if (bh) {
            const char* o = Portal_GetBlockheadName(bh);
            if (o && targetName && strcasecmp(o, targetName)==0) return bh;
        }
    }
    return nil;
}

// --- CORE FIX: FIND PLAYER ---
static id Portal_FindBlockhead(id dynWorld, const char* name) {
    if (!dynWorld || !name) return nil;
    
    // Method 1
    SEL sAll = sel_registerName(SEL_ALL_NET);
    if (class_getInstanceMethod(object_getClass(dynWorld), sAll)) {
        ListFunc f = (ListFunc)class_getMethodImplementation(object_getClass(dynWorld), sAll);
        if (f) {
            id list = f(dynWorld, sAll);
            if (list) return Portal_ScanList(list, name);
        }
    }

    // Method 2 (Fallback)
    Ivar iv = class_getInstanceVariable(object_getClass(dynWorld), "netBlockheads");
    if (iv) {
        id res = Portal_ScanList(*(id*)((char*)dynWorld + ivar_getOffset(iv)), name);
        if (res) return res;
    }
    return nil;
}

static void Portal_Recover(id dynWorld, long long pos, id targetBH) {
    if (!dynWorld || pos == -1) return;
    SEL s = sel_registerName(SEL_SPAWN);
    SpawnFunc f = (SpawnFunc)class_getMethodImplementation(object_getClass(dynWorld), s);
    if (f) {
        f(dynWorld, s, pos, BLOCKED_ID, 0, 0, nil, nil, 1, 0, targetBH);
    }
}

static void Portal_Remove(id obj) {
    if (!obj) return;
    SEL s = sel_registerName(SEL_REMOVE);
    VoidBoolFunc f = (VoidBoolFunc)class_getMethodImplementation(object_getClass(obj), s);
    if (f) f(obj, s, 1);
}

static void Portal_SoftRemove(id obj) {
    if (!obj) return;
    SEL s = sel_registerName(SEL_FLAG);
    VoidBoolFunc f = (VoidBoolFunc)class_getMethodImplementation(object_getClass(obj), s);
    if (f) f(obj, s, 1);
}

id Portal_Place_Hook(id self, SEL _cmd, id world, id dynWorld, long long pos, id cache, id item, unsigned char flipped, id saveDict, id client, id clientName) {
    id obj = NULL;
    if (Portal_Real_Place) 
        obj = Portal_Real_Place(self, _cmd, world, dynWorld, pos, cache, item, flipped, saveDict, client, clientName);

    if (obj && item && Portal_GetID(item) == BLOCKED_ID) {
        Portal_Remove(obj); 
        const char* name = Portal_GetStr(clientName);
        id bh = Portal_FindBlockhead(dynWorld, name);
        Portal_Recover(dynWorld, pos, bh);
    }
    return obj;
}

id Portal_Load_Hook(id self, SEL _cmd, id world, id dynWorld, id saveDict, id cache) {
    id obj = NULL;
    if (Portal_Real_Load) 
        obj = Portal_Real_Load(self, _cmd, world, dynWorld, saveDict, cache);

    if (obj && Portal_GetDropID(obj) == BLOCKED_ID) {
        Portal_Recover(dynWorld, Portal_GetPos(obj), nil);
        Portal_SoftRemove(obj);
    }
    return obj;
}

static void* Portal_InitThread(void* arg) {
    sleep(2);
    Class cls = objc_getClass(TARGET_CLASS);
    if (cls) {
        Method m1 = class_getInstanceMethod(cls, sel_registerName(SEL_PLACE));
        Portal_Real_Place = (PlaceFunc)method_getImplementation(m1);
        method_setImplementation(m1, (IMP)Portal_Place_Hook);

        Method m2 = class_getInstanceMethod(cls, sel_registerName(SEL_LOAD));
        Portal_Real_Load = (LoadFunc)method_getImplementation(m2);
        method_setImplementation(m2, (IMP)Portal_Load_Hook);
    }
    return NULL;
}

__attribute__((constructor)) static void Portal_Entry() {
    pthread_t t; pthread_create(&t, NULL, Portal_InitThread, NULL);
}
