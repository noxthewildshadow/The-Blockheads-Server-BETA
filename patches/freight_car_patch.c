/*
 * Freight Car Ban
 * Target Class: FreightCar
 * Target ID: 206 (Freight Handcar)
 * Logic: (Allow Load -> Get Pos -> Drop -> Delete)
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

// --- Configuration ---
#define TARGET_CLASS_NAME "FreightCar"
#define DROPPED_ITEM_ID   206  // Correct ID: Freight Handcar

// --- Selectors ---
#define SEL_PLACE  "initWithWorld:dynamicWorld:atPosition:cache:saveDict:placedByClient:"
#define SEL_LOAD   "initWithWorld:dynamicWorld:saveDict:chestSaveDict:cache:"
#define SEL_NET    "initWithWorld:dynamicWorld:cache:netData:"
#define SEL_SPAWN  "createFreeBlockAtPosition:ofType:dataA:dataB:subItems:dynamicObjectSaveDict:hovers:playSound:priorityBlockhead:"
#define SEL_POS    "pos"
#define SEL_FLAG   "setNeedsRemoved:"

// --- Function Prototypes ---
typedef id (*PlaceFunc)(id, SEL, id, id, long long, id, id, id);
typedef id (*LoadFunc)(id, SEL, id, id, id, id, id); 
typedef id (*NetFunc)(id, SEL, id, id, id, id);
typedef long long (*PosReturnFunc)(id, SEL);
typedef void (*VoidFunc)(id, SEL, BOOL);
typedef id (*SpawnFunc)(id, SEL, long long, int, int, int, id, id, BOOL, BOOL, id);

// --- Global Storage ---
static LoadFunc real_Freight_InitLoad = NULL;

// -----------------------------------------------------------------------------
// HELPER FUNCTIONS
// -----------------------------------------------------------------------------

// Retrieves position directly from an instantiated object
long long GetPosition(id obj) {
    if (!obj) return -1;
    SEL sel = sel_registerName(SEL_POS);
    IMP method = class_getMethodImplementation(object_getClass(obj), sel);
    if (method) return ((PosReturnFunc)method)(obj, sel);
    return -1;
}

// Spawns a FreeBlock (Item Drop)
void SpawnDroppedItem(id dynWorld, long long pos) {
    if (!dynWorld || pos == -1) return;

    SEL sel = sel_registerName(SEL_SPAWN);
    IMP method = class_getMethodImplementation(object_getClass(dynWorld), sel);

    if (method) {
        // Args: pos, type, dataA, dataB, subItems, saveDict, hovers, playSound, priorityBlockhead
        ((SpawnFunc)method)(dynWorld, sel, pos, DROPPED_ITEM_ID, 0, 0, nil, nil, 1, 0, nil);
        printf("[Anti-Exploit] Item (ID %d) returned at pos %lld.\n", DROPPED_ITEM_ID, pos);
    } else {
        printf("[Anti-Exploit] ERROR: Failed to locate spawn method in DynamicWorld.\n");
    }
}

// Soft delete: setNeedsRemoved:YES
void SoftRemoveObject(id obj) {
    if (!obj) return;
    SEL sel = sel_registerName(SEL_FLAG);
    IMP method = class_getMethodImplementation(object_getClass(obj), sel);
    if (method) ((VoidFunc)method)(obj, sel, 1);
}

// -----------------------------------------------------------------------------
// HOOK IMPLEMENTATIONS
// -----------------------------------------------------------------------------

/*
 * Hook: Player Placement
 * Block immediately. We have the pos in args.
 */
id Hook_Freight_InitPlace(id self, SEL _cmd, id world, id dynWorld, long long pos, id cache, id saveDict, id client) {
    printf("[Anti-Exploit] Blocked Freight Car placement at %lld. Returning item.\n", pos);
    SpawnDroppedItem(dynWorld, pos);
    return NULL; 
}

/*
 * Hook: Server Load
 * Allow creation -> Get Pos -> Drop -> Delete.
 */
id Hook_Freight_InitLoad(id self, SEL _cmd, id world, id dynWorld, id saveDict, id chestDict, id cache) {
    // 1. Run original constructor
    id loadedObj = NULL;
    if (real_Freight_InitLoad) {
        loadedObj = real_Freight_InitLoad(self, _cmd, world, dynWorld, saveDict, chestDict, cache);
    }

    // 2. Process valid object
    if (loadedObj) {
        long long pos = GetPosition(loadedObj);

        if (pos != -1) {
            printf("[Anti-Exploit] Existing Freight Car loaded at %lld. Converting to drop.\n", pos);
            SpawnDroppedItem(dynWorld, pos);
        } else {
            printf("[Anti-Exploit] Existing Freight Car loaded, but 'pos' unknown. Deleting only.\n");
        }

        // 3. Mark for deletion
        SoftRemoveObject(loadedObj);
    }

    return loadedObj;
}

/*
 * Hook: Network Packet Spawn
 * Block immediately.
 */
id Hook_Freight_InitNet(id self, SEL _cmd, id world, id dynWorld, id cache, id netData) {
    printf("[Anti-Exploit] Blocked Freight Car network spawn packet.\n");
    return NULL; 
}

// -----------------------------------------------------------------------------
// INITIALIZATION
// -----------------------------------------------------------------------------

static void *patchThread(void *arg) {
    printf("[Anti-Exploit] Initializing Freight Car Patch v5 (ID: %d)...\n", DROPPED_ITEM_ID);
    sleep(1); 

    Class targetClass = objc_getClass(TARGET_CLASS_NAME);
    if (!targetClass) {
        printf("[Anti-Exploit] ERROR: Class '%s' not found!\n", TARGET_CLASS_NAME);
        return NULL;
    }

    // 1. Hook Placement (Replace)
    SEL selPlace = sel_registerName(SEL_PLACE);
    if (class_getInstanceMethod(targetClass, selPlace)) {
        method_setImplementation(class_getInstanceMethod(targetClass, selPlace), (IMP)Hook_Freight_InitPlace);
        printf("[Anti-Exploit] Hooked: Placement.\n");
    }

    // 2. Hook Load (Swizzle to allow object creation)
    SEL selLoad = sel_registerName(SEL_LOAD);
    Method mLoad = class_getInstanceMethod(targetClass, selLoad);
    if (mLoad) {
        real_Freight_InitLoad = (LoadFunc)method_getImplementation(mLoad);
        method_setImplementation(mLoad, (IMP)Hook_Freight_InitLoad);
        printf("[Anti-Exploit] Hooked: Load.\n");
    }

    // 3. Hook Net (Replace)
    SEL selNet = sel_registerName(SEL_NET);
    if (class_getInstanceMethod(targetClass, selNet)) {
        method_setImplementation(class_getInstanceMethod(targetClass, selNet), (IMP)Hook_Freight_InitNet);
        printf("[Anti-Exploit] Hooked: Network.\n");
    }

    printf("[Anti-Exploit] Freight Car Patch Active.\n");
    return NULL;
}

__attribute__((constructor))
static void init_hook() {
    pthread_t t;
    pthread_create(&t, NULL, patchThread, NULL);
}
