#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
#include <pthread.h>
#include <objc/runtime.h>
#include <objc/message.h>

// --- Configuration ---
#define TARGET_CLASS_NAME "FreightCar"
#define DROPPED_ITEM_ID 206

// --- Selectors ---
#define SEL_PLACE "initWithWorld:dynamicWorld:atPosition:cache:saveDict:placedByClient:"
#define SEL_LOAD "initWithWorld:dynamicWorld:saveDict:chestSaveDict:cache:"
#define SEL_NET "initWithWorld:dynamicWorld:cache:netData:"
#define SEL_SPAWN "createFreeBlockAtPosition:ofType:dataA:dataB:subItems:dynamicObjectSaveDict:hovers:playSound:priorityBlockhead:"
#define SEL_POS "pos"
#define SEL_FLAG "setNeedsRemoved:"

// --- Function Prototypes ---
typedef id (*PlaceFunc)(id, SEL, id, id, long long, id, id, id);
typedef id (*LoadFunc)(id, SEL, id, id, id, id, id);
typedef id (*NetFunc)(id, SEL, id, id, id, id);
typedef long long (*PosReturnFunc)(id, SEL);
typedef void (*VoidFunc)(id, SEL, BOOL);
typedef id (*SpawnFunc)(id, SEL, long long, int, int, int, id, id, BOOL, BOOL, id);

// --- Global Storage ---
static LoadFunc real_Freight_InitLoad = NULL;

long long GetPosition(id obj) {
    if (!obj) return -1;
    SEL sel = sel_registerName(SEL_POS);
    IMP method = class_getMethodImplementation(object_getClass(obj), sel);
    if (method) return ((PosReturnFunc)method)(obj, sel);
    return -1;
}

void SpawnDroppedItem(id dynWorld, long long pos) {
    if (!dynWorld || pos == -1) return;

    SEL sel = sel_registerName(SEL_SPAWN);
    IMP method = class_getMethodImplementation(object_getClass(dynWorld), sel);

    if (method) {
        ((SpawnFunc)method)(dynWorld, sel, pos, DROPPED_ITEM_ID, 0, 0, nil, nil, 1, 0, nil);
    }
}

void SoftRemoveObject(id obj) {
    if (!obj) return;
    SEL sel = sel_registerName(SEL_FLAG);
    IMP method = class_getMethodImplementation(object_getClass(obj), sel);
    if (method) ((VoidFunc)method)(obj, sel, 1);
}

// --- HOOKS ---

id Hook_Freight_InitPlace(id self, SEL _cmd, id world, id dynWorld, long long pos, id cache, id saveDict, id client) {
    // Silent block
    SpawnDroppedItem(dynWorld, pos);
    return NULL;
}

id Hook_Freight_InitLoad(id self, SEL _cmd, id world, id dynWorld, id saveDict, id chestDict, id cache) {
    id loadedObj = NULL;
    if (real_Freight_InitLoad) {
        loadedObj = real_Freight_InitLoad(self, _cmd, world, dynWorld, saveDict, chestDict, cache);
    }

    if (loadedObj) {
        long long pos = GetPosition(loadedObj);
        if (pos != -1) {
            SpawnDroppedItem(dynWorld, pos);
        }
        SoftRemoveObject(loadedObj);
    }
    return loadedObj;
}

id Hook_Freight_InitNet(id self, SEL _cmd, id world, id dynWorld, id cache, id netData) {
    return NULL;
}

// --- INIT ---

static void *Freight_InitThread(void *arg) {
    sleep(1);
    Class targetClass = objc_getClass(TARGET_CLASS_NAME);
    if (!targetClass) return NULL;

    SEL selPlace = sel_registerName(SEL_PLACE);
    if (class_getInstanceMethod(targetClass, selPlace)) {
        method_setImplementation(class_getInstanceMethod(targetClass, selPlace), (IMP)Hook_Freight_InitPlace);
    }

    SEL selLoad = sel_registerName(SEL_LOAD);
    Method mLoad = class_getInstanceMethod(targetClass, selLoad);
    if (mLoad) {
        real_Freight_InitLoad = (LoadFunc)method_getImplementation(mLoad);
        method_setImplementation(mLoad, (IMP)Hook_Freight_InitLoad);
    }

    SEL selNet = sel_registerName(SEL_NET);
    if (class_getInstanceMethod(targetClass, selNet)) {
        method_setImplementation(class_getInstanceMethod(targetClass, selNet), (IMP)Hook_Freight_InitNet);
    }

    return NULL;
}

__attribute__((constructor))
static void Freight_Entry() {
    pthread_t t;
    pthread_create(&t, NULL, Freight_InitThread, NULL);
}
