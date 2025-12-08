/*
 * Portal Chest Ban
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
#define SEL_ALL_NET "allBlockheadsIncludingNet"
#define SEL_COUNT   "count"
#define SEL_OBJ_IDX "objectAtIndex:"
#define SEL_NAME    "clientName"

typedef id (*PlaceFunc)(id, SEL, id, id, long long, id, id, unsigned char, id, id, id);
typedef id (*LoadFunc)(id, SEL, id, id, id, id);
typedef id (*SpawnFunc)(id, SEL, long long, int, int, int, id, id, BOOL, BOOL, id);
typedef const char* (*StrFunc)(id, SEL);
typedef id (*ObjIdxFunc)(id, SEL, unsigned long);

static PlaceFunc Portal_Real_Place = NULL;
static LoadFunc  Portal_Real_Load  = NULL;

// --- Helpers ---
static const char* Portal_GetStr(id str) {
    if (!str) return "";
    SEL s = sel_registerName(SEL_UTF8);
    if (class_getInstanceMethod(object_getClass(str), s)) {
        IMP m = class_getMethodImplementation(object_getClass(str), s);
        return m ? ((StrFunc)m)(str, s) : "";
    }
    return "";
}

static const char* Portal_GetBlockheadName(id bh) {
    if (!bh) return NULL;
    SEL sName = sel_registerName(SEL_NAME);
    if (class_getInstanceMethod(object_getClass(bh), sName)) {
        IMP m = class_getMethodImplementation(object_getClass(bh), sName);
        if (m) {
            id s = ((id (*)(id, SEL))m)(bh, sName);
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
    IMP m = class_getMethodImplementation(object_getClass(obj), s);
    return m ? ((int (*)(id, SEL))m)(obj, s) : 0;
}

static int Portal_GetDropID(id obj) {
    if (!obj) return 0;
    SEL s = sel_registerName(SEL_DROP);
    IMP m = class_getMethodImplementation(object_getClass(obj), s);
    return m ? ((int (*)(id, SEL))m)(obj, s) : 0;
}

static long long Portal_GetPos(id obj) {
    if (!obj) return -1;
    SEL s = sel_registerName(SEL_POS);
    IMP m = class_getMethodImplementation(object_getClass(obj), s);
    return m ? ((long long (*)(id, SEL))m)(obj, s) : -1;
}

// --- Strict Finder (Name Only) ---
static id Portal_FindBlockhead(id dynWorld, const char* name) {
    if (!dynWorld || !name) return nil;
    
    id list = nil;
    SEL sAll = sel_registerName(SEL_ALL_NET);
    IMP mAll = class_getMethodImplementation(object_getClass(dynWorld), sAll);
    if (mAll) list = ((id (*)(id, SEL))mAll)(dynWorld, sAll);
    
    if (!list) {
        Ivar iv = class_getInstanceVariable(object_getClass(dynWorld), "netBlockheads");
        if (iv) list = *(id*)((char*)dynWorld + ivar_getOffset(iv));
    }
    if (!list) return nil;

    SEL sCount = sel_registerName(SEL_COUNT);
    IMP mCount = class_getMethodImplementation(object_getClass(list), sCount);
    int c = mCount ? ((int (*)(id, SEL))mCount)(list, sCount) : 0;

    SEL sIdx = sel_registerName(SEL_OBJ_IDX);
    IMP mIdx = class_getMethodImplementation(object_getClass(list), sIdx);

    for (int i=0; i<c; i++) {
        id bh = mIdx ? ((ObjIdxFunc)mIdx)(list, sIdx, i) : nil;
        if (bh) {
            const char* o = Portal_GetBlockheadName(bh);
            if (o && strcasecmp(o, name)==0) {
                return bh;
            }
        }
    }
    return nil;
}

// --- Action ---
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
    IMP m = class_getMethodImplementation(object_getClass(obj), s);
    if (m) ((void (*)(id, SEL, BOOL))m)(obj, s, 1);
}

static void Portal_SoftRemove(id obj) {
    if (!obj) return;
    SEL s = sel_registerName(SEL_FLAG);
    IMP m = class_getMethodImplementation(object_getClass(obj), s);
    if (m) ((void (*)(id, SEL, BOOL))m)(obj, s, 1);
}

// --- Hooks ---
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
