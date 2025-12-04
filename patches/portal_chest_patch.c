/*
 * Portal Chest Patcher (Item Recovery)
 * Target Class: Chest
 * Target ID: 1074 (Portal Chest)
 * Detects placement or load of Portal Chests, spawns the item back, and removes the object.
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
#define TARGET_CLASS_NAME "Chest"
#define BLOCKED_ITEM_ID   1074

// --- Selectors ---
#define SEL_PLACE  "initWithWorld:dynamicWorld:atPosition:cache:item:flipped:saveDict:placedByClient:clientName:"
#define SEL_LOAD   "initWithWorld:dynamicWorld:saveDict:cache:"
#define SEL_POS    "pos"
#define SEL_TYPE   "itemType"
#define SEL_DROP   "destroyItemType"
#define SEL_SPAWN  "createFreeBlockAtPosition:ofType:dataA:dataB:subItems:dynamicObjectSaveDict:hovers:playSound:priorityBlockhead:"
#define SEL_REMOVE "remove:"
#define SEL_FLAG   "setNeedsRemoved:"

// --- Function Prototypes ---
typedef id (*PlaceFunc)(id, SEL, id, id, long long, id, id, unsigned char, id, id, id);
typedef id (*LoadFunc)(id, SEL, id, id, id, id);
typedef int (*IntReturnFunc)(id, SEL);
typedef long long (*PosReturnFunc)(id, SEL);
typedef void (*VoidFunc)(id, SEL, BOOL);
typedef id (*SpawnFunc)(id, SEL, long long, int, int, int, id, id, BOOL, BOOL, id);

// --- Global Storage for Original Methods ---
static PlaceFunc real_Chest_InitPlace = NULL;
static LoadFunc  real_Chest_InitLoad  = NULL;

// -----------------------------------------------------------------------------
// HELPER FUNCTIONS
// -----------------------------------------------------------------------------

// Retrieves itemType from an object
int GetItemID(id obj) {
    if (!obj) return 0;
    SEL sel = sel_registerName(SEL_TYPE);
    IMP method = class_getMethodImplementation(object_getClass(obj), sel);
    if (method) return ((IntReturnFunc)method)(obj, sel);
    return 0;
}

// Retrieves destroyItemType (drop ID) from a block
int GetDropID(id obj) {
    if (!obj) return 0;
    SEL sel = sel_registerName(SEL_DROP);
    IMP method = class_getMethodImplementation(object_getClass(obj), sel);
    if (method) return ((IntReturnFunc)method)(obj, sel);
    return 0;
}

// Retrieves position directly from the object
long long GetPosition(id obj) {
    if (!obj) return -1;
    SEL sel = sel_registerName(SEL_POS);
    IMP method = class_getMethodImplementation(object_getClass(obj), sel);
    if (method) return ((PosReturnFunc)method)(obj, sel);
    return -1;
}

// Spawns a FreeBlock (Item Drop) at the specified position
void SpawnDroppedItem(id dynWorld, long long pos) {
    if (!dynWorld || pos == -1) return;

    SEL sel = sel_registerName(SEL_SPAWN);
    IMP method = class_getMethodImplementation(object_getClass(dynWorld), sel);

    if (method) {
        // Args: pos, type, dataA, dataB, subItems, saveDict, hovers, playSound, priorityBlockhead
        ((SpawnFunc)method)(dynWorld, sel, pos, BLOCKED_ITEM_ID, 0, 0, nil, nil, 1, 0, nil);
        printf("[Anti-Exploit] Item recovery successful at pos %lld.\n", pos);
    } else {
        printf("[Anti-Exploit] ERROR: Failed to locate spawn method in DynamicWorld.\n");
    }
}

// Hard delete: remove:YES
void ForceRemoveObject(id obj) {
    if (!obj) return;
    SEL sel = sel_registerName(SEL_REMOVE);
    IMP method = class_getMethodImplementation(object_getClass(obj), sel);
    if (method) ((VoidFunc)method)(obj, sel, 1);
}

// Soft delete: setNeedsRemoved:YES (Safe for load time)
void SoftRemoveObject(id obj) {
    if (!obj) return;
    SEL sel = sel_registerName(SEL_FLAG);
    IMP method = class_getMethodImplementation(object_getClass(obj), sel);
    if (method) ((VoidFunc)method)(obj, sel, 1);
}

// -----------------------------------------------------------------------------
// HOOK IMPLEMENTATIONS
// -----------------------------------------------------------------------------

// Hook: Player placing a chest
id Hook_Chest_InitPlace(id self, SEL _cmd, id world, id dynWorld, long long pos, id cache, id item, unsigned char flipped, id saveDict, id client, id clientName) {
    // Call original constructor first
    id newObj = NULL;
    if (real_Chest_InitPlace) {
        newObj = real_Chest_InitPlace(self, _cmd, world, dynWorld, pos, cache, item, flipped, saveDict, client, clientName);
    }

    // Inspect creation
    if (newObj && item) {
        if (GetItemID(item) == BLOCKED_ITEM_ID) {
            printf("[Anti-Exploit] Blocked Portal Chest placement. Returning item to player.\n");
            
            // 1. Remove the illegal block immediately
            ForceRemoveObject(newObj);
            
            // 2. Spawn the item back
            SpawnDroppedItem(dynWorld, pos);
        }
    }

    return newObj;
}

// Hook: Server loading chests from save file
id Hook_Chest_InitLoad(id self, SEL _cmd, id world, id dynWorld, id saveDict, id cache) {
    // Call original constructor first
    id loadedObj = NULL;
    if (real_Chest_InitLoad) {
        loadedObj = real_Chest_InitLoad(self, _cmd, world, dynWorld, saveDict, cache);
    }

    // Inspect loaded object
    if (loadedObj) {
        if (GetDropID(loadedObj) == BLOCKED_ITEM_ID) {
            long long pos = GetPosition(loadedObj);

            if (pos != -1) {
                printf("[Anti-Exploit] Existing Portal Chest detected at %lld. Converting to drop.\n", pos);
                SpawnDroppedItem(dynWorld, pos);
            } else {
                printf("[Anti-Exploit] Existing Portal Chest detected, but position unreadable. Deleting only.\n");
            }

            // Mark for soft removal (safer during load loop)
            SoftRemoveObject(loadedObj);
            return loadedObj;
        }
    }

    return loadedObj;
}

// -----------------------------------------------------------------------------
// INITIALIZATION
// -----------------------------------------------------------------------------

static void *patchThread(void *arg) {
    printf("[Anti-Exploit] Initializing Portal Chest Patch (Recovery Mode)...\n");
    
    // Wait for runtime to settle
    sleep(2);

    Class targetClass = objc_getClass(TARGET_CLASS_NAME);
    if (!targetClass) {
        printf("[Anti-Exploit] ERROR: Class '%s' not found!\n", TARGET_CLASS_NAME);
        return NULL;
    }

    // Apply Placement Hook
    SEL selPlace = sel_registerName(SEL_PLACE);
    Method mPlace = class_getInstanceMethod(targetClass, selPlace);
    if (mPlace) {
        real_Chest_InitPlace = (PlaceFunc)method_getImplementation(mPlace);
        method_setImplementation(mPlace, (IMP)Hook_Chest_InitPlace);
        printf("[Anti-Exploit] Hooked: Placement Constructor.\n");
    }

    // Apply Load Hook
    SEL selLoad = sel_registerName(SEL_LOAD);
    Method mLoad = class_getInstanceMethod(targetClass, selLoad);
    if (mLoad) {
        real_Chest_InitLoad = (LoadFunc)method_getImplementation(mLoad);
        method_setImplementation(mLoad, (IMP)Hook_Chest_InitLoad);
        printf("[Anti-Exploit] Hooked: Load Constructor.\n");
    }

    printf("[Anti-Exploit] Portal Chest Blocker is active.\n");
    return NULL;
}

__attribute__((constructor))
static void init_hook() {
    pthread_t t;
    pthread_create(&t, NULL, patchThread, NULL);
}
