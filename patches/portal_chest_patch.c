/*
 * Portal Chest Blocker (FIXED)
 * Blocks ID 1074 (Portal Chest).
 * Fix: Uses "Soft Delete" during load to prevent crashes.
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

// Config
#define TARGET_CLASS "Chest"
#define BLOCKED_ITEM_ID 1074

// Selectors
#define SEL_PLACE  "initWithWorld:dynamicWorld:atPosition:cache:item:flipped:saveDict:placedByClient:clientName:"
#define SEL_LOAD   "initWithWorld:dynamicWorld:saveDict:cache:"
#define SEL_DROP   "destroyItemType"
#define SEL_REMOVE "remove:" 
#define SEL_FLAG   "setNeedsRemoved:"

// Func types
typedef id (*PlaceFunc)(id, SEL, id, id, long long, id, id, unsigned char, id, id, id);
typedef id (*LoadFunc)(id, SEL, id, id, id, id);
typedef int (*DropFunc)(id, SEL);
typedef void (*RemoveFunc)(id, SEL, unsigned char);
typedef void (*FlagFunc)(id, SEL, unsigned char);

static PlaceFunc original_place = NULL;
static LoadFunc original_load = NULL;

// Helper: Get item ID from item object
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

// Helper: Get block ID from block object
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
// CLEANUP LOGIC
// -----------------------------------------------------------------------------

// METHOD A: Full Nuke (Map + Memory)
// Use this ONLY when placing items or updating live items.
void safe_remove_fully(id block) {
    if (!block) return;
    SEL sRemove = sel_registerName(SEL_REMOVE);
    Method mRemove = class_getInstanceMethod(object_getClass(block), sRemove);
    if (mRemove) {
        RemoveFunc f = (RemoveFunc)method_getImplementation(mRemove);
        f(block, sRemove, 1); // 1 = YES
    }
}

// METHOD B: Soft Delete (Memory Only)
// Use this ONLY during "initWithWorld" (Loading) to avoid crash.
void mark_for_removal_only(id block) {
    if (!block) return;
    SEL sFlag = sel_registerName(SEL_FLAG);
    Method mFlag = class_getInstanceMethod(object_getClass(block), sFlag);
    if (mFlag) {
        FlagFunc f = (FlagFunc)method_getImplementation(mFlag);
        f(block, sFlag, 1); // setNeedsRemoved:YES
    }
}

// -----------------------------------------------------------------------------
// HOOKS
// -----------------------------------------------------------------------------

// HOOK: Player placing block
id hook_ChestPlace(id self, SEL _cmd, id world, id dynWorld, long long pos, id cache, id item, unsigned char flipped, id saveDict, id client, id clientName) {
    
    // Let it spawn first
    id newObj = NULL;
    if (original_place) {
        newObj = original_place(self, _cmd, world, dynWorld, pos, cache, item, flipped, saveDict, client, clientName);
    }

    // Check immediately after spawn
    if (newObj && item) {
        int id = get_item_id(item);
        if (id == BLOCKED_ITEM_ID) {
            printf("[Anti-Exploit] Blocked Portal Chest placement. Nuking it.\n");
            // Safe to use Full Nuke here because the engine just finished placing it
            safe_remove_fully(newObj);
        }
    }

    return newObj;
}

// HOOK: Server loading map (THE CRASH FIX)
id hook_ChestLoad(id self, SEL _cmd, id world, id dynWorld, id saveDict, id cache) {
    
    // Load normally
    id loadedChest = NULL;
    if (original_load) {
        loadedChest = original_load(self, _cmd, world, dynWorld, saveDict, cache);
    }

    // Check & Soft Delete
    if (loadedChest) {
        int dropID = get_block_drop_id(loadedChest);

        if (dropID == BLOCKED_ITEM_ID) {
            printf("[Anti-Exploit] Found existing Portal Chest during load. Scheduling removal.\n");
            // CRITICAL: Only mark memory, do not touch map yet
            mark_for_removal_only(loadedChest); 
            return loadedChest; 
        }
    }

    return loadedChest;
}

// -----------------------------------------------------------------------------
// Init
// -----------------------------------------------------------------------------
static void *patchThread(void *arg) {
    printf("[Anti-Exploit] Loading Portal Chest patch v2 (Anti-Crash)...\n");
    sleep(2); 

    Class targetClass = objc_getClass(TARGET_CLASS);
    if (!targetClass) {
        printf("[Anti-Exploit] ERROR: Chest Class not found.\n");
        return NULL;
    }

    // Install Placement Hook
    SEL sPlace = sel_registerName(SEL_PLACE);
    Method mPlace = class_getInstanceMethod(targetClass, sPlace);
    if (mPlace) {
        original_place = (PlaceFunc)method_getImplementation(mPlace);
        method_setImplementation(mPlace, (IMP)hook_ChestPlace);
    }

    // Install Load Hook
    SEL sLoad = sel_registerName(SEL_LOAD);
    Method mLoad = class_getInstanceMethod(targetClass, sLoad);
    if (mLoad) {
        original_load = (LoadFunc)method_getImplementation(mLoad);
        method_setImplementation(mLoad, (IMP)hook_ChestLoad);
    }

    printf("[Anti-Exploit] Portal Chests (ID %d) are blocked.\n", BLOCKED_ITEM_ID);
    return NULL;
}

__attribute__((constructor))
static void init_hook() {
    pthread_t t;
    pthread_create(&t, NULL, patchThread, NULL);
}
