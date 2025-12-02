/*
 * Portal Blocker (IDs 134-139)
 * Blocks: Portal, Amethyst, Sapphire, Emerald, Ruby, Diamond.
 * IGNORES Trade Portals.
 * Fixes: Infinite Spawn Portal regeneration.
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
#define TARGET_CLASS "Workbench" 

// Selectors
#define SEL_PLACE  "initWithWorld:dynamicWorld:atPosition:cache:item:flipped:saveDict:placedByClient:clientName:"
#define SEL_LOAD   "initWithWorld:dynamicWorld:saveDict:cache:"
#define SEL_UPDATE "update:accurateDT:isSimulation:" // Heartbeat (Fixes spawn regen)
#define SEL_DROP   "destroyItemType"      // ID check
#define SEL_MACRO  "removeFromMacroBlock" // Map cleanup
#define SEL_FLAG   "setNeedsRemoved:"     // Memory cleanup

// Func types
typedef id (*PlaceFunc)(id, SEL, id, id, long long, id, id, unsigned char, id, id, id);
typedef id (*LoadFunc)(id, SEL, id, id, id, id);
typedef void (*UpdateFunc)(id, SEL, float, bool);
typedef int (*DropFunc)(id, SEL);
typedef void (*VoidFunc)(id, SEL);
typedef void (*BoolFunc)(id, SEL, unsigned char);

static PlaceFunc original_place = NULL;
static LoadFunc original_load = NULL;
static UpdateFunc original_update = NULL;

// -----------------------------------------------------------------------------
// Logic: Banned IDs
// -----------------------------------------------------------------------------
bool is_banned_portal(int id) {
    return (id >= 134 && id <= 139);
}

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

// Get ID from placed block
int get_block_drop_id(id block) {
    if (!block) return 0;
    SEL s = sel_registerName(SEL_DROP);
    Method m = class_getInstanceMethod(object_getClass(block), s);
    if (m) {
        DropFunc f = (DropFunc)method_getImplementation(m);
        return f(block, s);
    }
    return 0;
}

// Nuke block cleanly (Map + Memory)
void safe_remove_block(id block) {
    if (!block) return;
    Class cls = object_getClass(block);

    // 1. Clear Map (Fixes ghosts)
    SEL sMacro = sel_registerName(SEL_MACRO);
    if (class_getInstanceMethod(cls, sMacro)) {
        VoidFunc f = (VoidFunc)method_getImplementation(class_getInstanceMethod(cls, sMacro));
        f(block, sMacro);
    }
    // 2. Flag for deletion
    SEL sFlag = sel_registerName(SEL_FLAG);
    if (class_getInstanceMethod(cls, sFlag)) {
        BoolFunc f = (BoolFunc)method_getImplementation(class_getInstanceMethod(cls, sFlag));
        f(block, sFlag, 1); 
    }
}

// -----------------------------------------------------------------------------
// HOOK 1: Placement (Preventive)
// -----------------------------------------------------------------------------
id hook_PortalPlace(id self, SEL _cmd, id world, id dynWorld, long long pos, id cache, id item, unsigned char flipped, id saveDict, id client, id clientName) {
    
    // If player has banned item, block immediately.
    if (item) {
        int id = get_item_id(item);
        if (is_banned_portal(id)) {
            printf("[PortalBlocker] Player tried to place Portal (ID %d). Denied.\n", id);
            return NULL; 
        }
    }

    if (original_place) {
        return original_place(self, _cmd, world, dynWorld, pos, cache, item, flipped, saveDict, client, clientName);
    }
    return NULL;
}

// -----------------------------------------------------------------------------
// HOOK 2: Loading (Cleanup)
// -----------------------------------------------------------------------------
id hook_PortalLoad(id self, SEL _cmd, id world, id dynWorld, id saveDict, id cache) {
    
    id loadedObj = NULL;
    if (original_load) {
        loadedObj = original_load(self, _cmd, world, dynWorld, saveDict, cache);
    }

    // Check if we loaded trash
    if (loadedObj) {
        int dropID = get_block_drop_id(loadedObj);
        if (is_banned_portal(dropID)) {
            printf("[PortalBlocker] Removing existing Portal (ID %d).\n", dropID);
            safe_remove_block(loadedObj);
            return loadedObj; 
        }
    }
    return loadedObj;
}

// -----------------------------------------------------------------------------
// HOOK 3: Update (Spawn Killer)
// -----------------------------------------------------------------------------
void hook_PortalUpdate(id self, SEL _cmd, float dt, bool isSim) {
    
    // Check active object ID
    int myID = get_block_drop_id(self);

    // If illegal (e.g. System regen), kill it.
    if (is_banned_portal(myID)) {
        safe_remove_block(self);
        return; // Stop execution
    }

    if (original_update) {
        original_update(self, _cmd, dt, isSim);
    }
}

// -----------------------------------------------------------------------------
// Init
// -----------------------------------------------------------------------------
static void *patchThread(void *arg) {
    printf("[PortalBlocker] Loading...\n");
    sleep(2); 

    Class targetClass = objc_getClass(TARGET_CLASS);
    if (!targetClass) {
        printf("[PortalBlocker] ERROR: Class not found.\n");
        return NULL;
    }

    // Install Hooks
    SEL sPlace = sel_registerName(SEL_PLACE);
    Method mPlace = class_getInstanceMethod(targetClass, sPlace);
    if (mPlace) {
        original_place = (PlaceFunc)method_getImplementation(mPlace);
        method_setImplementation(mPlace, (IMP)hook_PortalPlace);
    } 

    SEL sLoad = sel_registerName(SEL_LOAD);
    Method mLoad = class_getInstanceMethod(targetClass, sLoad);
    if (mLoad) {
        original_load = (LoadFunc)method_getImplementation(mLoad);
        method_setImplementation(mLoad, (IMP)hook_PortalLoad);
    }

    SEL sUpdate = sel_registerName(SEL_UPDATE);
    Method mUpdate = class_getInstanceMethod(targetClass, sUpdate);
    if (mUpdate) {
        original_update = (UpdateFunc)method_getImplementation(mUpdate);
        method_setImplementation(mUpdate, (IMP)hook_PortalUpdate);
    }

    printf("[PortalBlocker] Active. IDs 134-139 banned.\n");
    return NULL;
}

__attribute__((constructor))
static void init_hook() {
    pthread_t t;
    pthread_create(&t, NULL, patchThread, NULL);
}
