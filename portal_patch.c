/*
 * The Blockheads Server - Portal Blocker (IDs 134-139)
 * Blocks: Portal, Amethyst, Sapphire, Emerald, Ruby, Diamond.
 * IGNORES Trade Portals.
 * Features: Safe removal logic to prevent Ghost Blocks & Core Dumps.
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
#define SEL_DROP   "destroyItemType"
// We need granular removal to avoid segfaults on load
#define SEL_MACRO  "removeFromMacroBlock" // Step 1: Clear Map
#define SEL_FLAG   "setNeedsRemoved:"     // Step 2: Clear Memory

// Func types
typedef id (*PlaceFunc)(id, SEL, id, id, long long, id, id, unsigned char, id, id, id);
typedef id (*LoadFunc)(id, SEL, id, id, id, id);
typedef int (*DropFunc)(id, SEL);
typedef void (*VoidFunc)(id, SEL);
typedef void (*BoolFunc)(id, SEL, unsigned char);

static PlaceFunc original_place = NULL;
static LoadFunc original_load = NULL;

// -----------------------------------------------------------------------------
// Logic: Check banned IDs (Portals only, no Trade Portals)
// -----------------------------------------------------------------------------
bool is_banned_portal(int id) {
    // 134: Portal, 135-139: Gem Portals
    return (id >= 134 && id <= 139);
}

// -----------------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------------
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

// -----------------------------------------------------------------------------
// Surgical Removal: Prevents crashes during world load
// -----------------------------------------------------------------------------
void surgical_remove_block(id block) {
    if (!block) return;
    Class cls = object_getClass(block);

    // 1. Remove from Map (Fixes Ghost Blocks)
    SEL sMacro = sel_registerName(SEL_MACRO);
    if (class_getInstanceMethod(cls, sMacro)) {
        VoidFunc fMacro = (VoidFunc)method_getImplementation(class_getInstanceMethod(cls, sMacro));
        fMacro(block, sMacro);
    }

    // 2. Mark for Deletion (Prevents Segfault)
    // Using 'remove:' during init causes crashes. This flags it for safe deletion later.
    SEL sFlag = sel_registerName(SEL_FLAG);
    if (class_getInstanceMethod(cls, sFlag)) {
        BoolFunc fFlag = (BoolFunc)method_getImplementation(class_getInstanceMethod(cls, sFlag));
        fFlag(block, sFlag, 1); // 1 = YES
    }
}

// -----------------------------------------------------------------------------
// HOOK 1: Player Placement
// -----------------------------------------------------------------------------
id hook_PortalPlace(id self, SEL _cmd, id world, id dynWorld, long long pos, id cache, id item, unsigned char flipped, id saveDict, id client, id clientName) {
    
    // Let it spawn first to register the tile
    id newObj = NULL;
    if (original_place) {
        newObj = original_place(self, _cmd, world, dynWorld, pos, cache, item, flipped, saveDict, client, clientName);
    }

    // Check ID
    if (newObj && item) {
        int id = get_item_id(item);
        if (is_banned_portal(id)) {
            printf("[PortalBlocker] Blocked Portal placement (ID %d). Nuking safely.\n", id);
            surgical_remove_block(newObj);
        }
    }

    return newObj;
}

// -----------------------------------------------------------------------------
// HOOK 2: World Load
// -----------------------------------------------------------------------------
id hook_PortalLoad(id self, SEL _cmd, id world, id dynWorld, id saveDict, id cache) {
    
    // Load normal
    id loadedObj = NULL;
    if (original_load) {
        loadedObj = original_load(self, _cmd, world, dynWorld, saveDict, cache);
    }

    // Check existing
    if (loadedObj) {
        int dropID = get_block_drop_id(loadedObj);
        if (is_banned_portal(dropID)) {
            printf("[PortalBlocker] Found existing Portal (ID %d). Deleting safely...\n", dropID);
            surgical_remove_block(loadedObj);
            return loadedObj; // Return obj to avoid engine errors
        }
    }

    return loadedObj;
}

// -----------------------------------------------------------------------------
// Init
// -----------------------------------------------------------------------------
static void *patchThread(void *arg) {
    printf("[PortalBlocker] Loading...\n");
    sleep(2); 

    // Portals are Workbenches in code
    Class targetClass = objc_getClass(TARGET_CLASS);
    if (!targetClass) {
        printf("[PortalBlocker] ERROR: Workbench class not found.\n");
        return NULL;
    }

    // Install Placement Hook
    SEL sPlace = sel_registerName(SEL_PLACE);
    Method mPlace = class_getInstanceMethod(targetClass, sPlace);
    if (mPlace) {
        original_place = (PlaceFunc)method_getImplementation(mPlace);
        method_setImplementation(mPlace, (IMP)hook_PortalPlace);
    } 

    // Install Load Hook
    SEL sLoad = sel_registerName(SEL_LOAD);
    Method mLoad = class_getInstanceMethod(targetClass, sLoad);
    if (mLoad) {
        original_load = (LoadFunc)method_getImplementation(mLoad);
        method_setImplementation(mLoad, (IMP)hook_PortalLoad);
    } 

    printf("[PortalBlocker] Portals (134-139) blocked. Safe removal active.\n");
    return NULL;
}

__attribute__((constructor))
static void init_hook() {
    pthread_t t;
    pthread_create(&t, NULL, patchThread, NULL);
}
