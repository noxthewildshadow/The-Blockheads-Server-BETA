/*
 * The Blockheads Server - Trade Portal Blocker (ID 210)
 * * Target: Trade Portal (Level - ANY).
 * * Logic: Hooks TradePortal class but filters strictly by ID 210.
 * * Safety: Uses surgical removal to prevent core dumps and ghost blocks.
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdbool.h>
#include <objc/runtime.h>
#include <objc/message.h>

// Config
#define TARGET_CLASS "TradePortal" // We hook this class
#define BANNED_ID    210           // Specific ID for Trade Portal

// Selectors
#define SEL_PLACE  "initWithWorld:dynamicWorld:atPosition:cache:item:flipped:saveDict:placedByClient:clientName:"
#define SEL_LOAD   "initWithWorld:dynamicWorld:saveDict:cache:"
#define SEL_UPDATE "update:accurateDT:isSimulation:" 
#define SEL_DROP   "destroyItemType"      // ID Check 1
#define SEL_OBJ    "objectType"           // ID Check 2
#define SEL_MACRO  "removeFromMacroBlock" // Map Cleanup
#define SEL_FLAG   "setNeedsRemoved:"     // Memory Cleanup

// Func types
typedef id (*PlaceFunc)(id, SEL, id, id, long long, id, id, unsigned char, id, id, id);
typedef id (*LoadFunc)(id, SEL, id, id, id, id);
typedef void (*UpdateFunc)(id, SEL, float, bool);
typedef int (*IntFunc)(id, SEL);
typedef void (*VoidFunc)(id, SEL);
typedef void (*BoolFunc)(id, SEL, unsigned char);

static PlaceFunc original_place = NULL;
static LoadFunc original_load = NULL;
static UpdateFunc original_update = NULL;

// -----------------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------------

// Get ID from item in hand
int get_item_id(id item) {
    if (!item) return 0;
    SEL s = sel_registerName("itemType");
    Method m = class_getInstanceMethod(object_getClass(item), s);
    if (m) {
        int (*f)(id, SEL) = (int (*)(id, SEL))method_getImplementation(m);
        return f(item, s);
    }
    return 0;
}

// Get Deep ID from placed block
int get_deep_id(id block) {
    if (!block) return 0;
    Class cls = object_getClass(block);
    int foundID = 0;

    // Try drop type
    SEL sDrop = sel_registerName(SEL_DROP);
    if (class_getInstanceMethod(cls, sDrop)) {
        IntFunc f = (IntFunc)method_getImplementation(class_getInstanceMethod(cls, sDrop));
        foundID = f(block, sDrop);
    }
    // Fallback to object type
    if (foundID == 0) {
        SEL sObj = sel_registerName(SEL_OBJ);
        if (class_getInstanceMethod(cls, sObj)) {
            IntFunc f = (IntFunc)method_getImplementation(class_getInstanceMethod(cls, sObj));
            foundID = f(block, sObj);
        }
    }
    return foundID;
}

// Surgical Removal (No crashes, no ghosts)
void safe_remove(id block) {
    if (!block) return;
    Class cls = object_getClass(block);

    // 1. Clear Map
    SEL sMacro = sel_registerName(SEL_MACRO);
    if (class_getInstanceMethod(cls, sMacro)) {
        VoidFunc f = (VoidFunc)method_getImplementation(class_getInstanceMethod(cls, sMacro));
        f(block, sMacro);
    }
    // 2. Flag Memory
    SEL sFlag = sel_registerName(SEL_FLAG);
    if (class_getInstanceMethod(cls, sFlag)) {
        BoolFunc f = (BoolFunc)method_getImplementation(class_getInstanceMethod(cls, sFlag));
        f(block, sFlag, 1); 
    }
}

// -----------------------------------------------------------------------------
// HOOK 1: Placement
// -----------------------------------------------------------------------------
id hook_TP_Place(id self, SEL _cmd, id world, id dynWorld, long long pos, id cache, id item, unsigned char flipped, id saveDict, id client, id clientName) {
    
    // Prevent creation if item is banned
    if (item) {
        int id = get_item_id(item);
        if (id == BANNED_ID) {
            printf("[TradeBlocker] Blocked Trade Portal placement (ID %d).\n", id);
            return NULL; 
        }
    }

    if (original_place) {
        return original_place(self, _cmd, world, dynWorld, pos, cache, item, flipped, saveDict, client, clientName);
    }
    return NULL;
}

// -----------------------------------------------------------------------------
// HOOK 2: Load (Disk)
// -----------------------------------------------------------------------------
id hook_TP_Load(id self, SEL _cmd, id world, id dynWorld, id saveDict, id cache) {
    
    id obj = NULL;
    if (original_load) {
        obj = original_load(self, _cmd, world, dynWorld, saveDict, cache);
    }

    // Clean existing map trash
    if (obj) {
        int id = get_deep_id(obj);
        if (id == BANNED_ID) {
            printf("[TradeBlocker] Found existing Trade Portal (ID %d). Deleting...\n", id);
            safe_remove(obj);
            return obj; // Return obj to avoid engine errors
        }
    }
    return obj;
}

// -----------------------------------------------------------------------------
// HOOK 3: Update (Active Scan)
// -----------------------------------------------------------------------------
void hook_TP_Update(id self, SEL _cmd, float dt, bool isSim) {
    
    int id = get_deep_id(self);
    
    if (id == BANNED_ID) {
        safe_remove(self);
        return;
    }

    if (original_update) {
        original_update(self, _cmd, dt, isSim);
    }
}

// -----------------------------------------------------------------------------
// Init
// -----------------------------------------------------------------------------
static void *patchThread(void *arg) {
    printf("[TradeBlocker] Loading ID-Filtered Patch...\n");
    sleep(2); 

    Class targetClass = objc_getClass(TARGET_CLASS);
    if (!targetClass) {
        printf("[TradeBlocker] ERROR: Class not found.\n");
        return NULL;
    }

    // Place Hook
    SEL sPlace = sel_registerName(SEL_PLACE);
    Method mPlace = class_getInstanceMethod(targetClass, sPlace);
    if (mPlace) {
        original_place = (PlaceFunc)method_getImplementation(mPlace);
        method_setImplementation(mPlace, (IMP)hook_TP_Place);
    }

    // Load Hook
    SEL sLoad = sel_registerName(SEL_LOAD);
    Method mLoad = class_getInstanceMethod(targetClass, sLoad);
    if (mLoad) {
        original_load = (LoadFunc)method_getImplementation(mLoad);
        method_setImplementation(mLoad, (IMP)hook_TP_Load);
    }

    // Update Hook
    SEL sUpdate = sel_registerName(SEL_UPDATE);
    Method mUpdate = class_getInstanceMethod(targetClass, sUpdate);
    if (mUpdate) {
        original_update = (UpdateFunc)method_getImplementation(mUpdate);
        method_setImplementation(mUpdate, (IMP)hook_TP_Update);
    }

    printf("[TradeBlocker] Active. ID %d is banned.\n", BANNED_ID);
    return NULL;
}

__attribute__((constructor))
static void init_hook() {
    pthread_t t;
    pthread_create(&t, NULL, patchThread, NULL);
}
