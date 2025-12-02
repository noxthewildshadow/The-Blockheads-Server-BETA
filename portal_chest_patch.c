/*
 * Portal Chest Blocker
 * Blocks ID 1074 (Portal Chest).
 * Prevents placement & nukes existing ones on load.
 * No ghost blocks.
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

// Func types
typedef id (*PlaceFunc)(id, SEL, id, id, long long, id, id, unsigned char, id, id, id);
typedef id (*LoadFunc)(id, SEL, id, id, id, id);
typedef int (*DropFunc)(id, SEL);
typedef void (*RemoveFunc)(id, SEL, unsigned char); 

static PlaceFunc original_place = NULL;
static LoadFunc original_load = NULL;

// Get item ID safely (bypassing objc_msgSend)
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

// Get block ID by checking what it drops
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

// Nuke the block cleanly (updates map + clients)
void safe_remove_block(id block) {
    if (!block) return;

    SEL sRemove = sel_registerName(SEL_REMOVE);
    Method mRemove = class_getInstanceMethod(object_getClass(block), sRemove);
    
    if (mRemove) {
        RemoveFunc f = (RemoveFunc)method_getImplementation(mRemove);
        f(block, sRemove, 1); // 1 = YES (Update clients/map)
    }
}

// HOOK: Player placing block
id hook_ChestPlace(id self, SEL _cmd, id world, id dynWorld, long long pos, id cache, id item, unsigned char flipped, id saveDict, id client, id clientName) {
    
    // Let it spawn first. Fixes ghost blocks.
    id newObj = NULL;
    if (original_place) {
        newObj = original_place(self, _cmd, world, dynWorld, pos, cache, item, flipped, saveDict, client, clientName);
    }

    // Is it the bad item?
    if (newObj && item) {
        int id = get_item_id(item);
        if (id == BLOCKED_ITEM_ID) {
            printf("[Anti-Exploit] Blocked Portal Chest placement. Nuking it.\n");
            safe_remove_block(newObj);
        }
    }

    return newObj;
}

// HOOK: Server loading map (Cleanup)
id hook_ChestLoad(id self, SEL _cmd, id world, id dynWorld, id saveDict, id cache) {
    
    // Load it up
    id loadedChest = NULL;
    if (original_load) {
        loadedChest = original_load(self, _cmd, world, dynWorld, saveDict, cache);
    }

    // Check & destroy
    if (loadedChest) {
        int dropID = get_block_drop_id(loadedChest);

        if (dropID == BLOCKED_ITEM_ID) {
            printf("[Anti-Exploit] Found existing Portal Chest. Deleting...\n");
            safe_remove_block(loadedChest);
            return loadedChest; // Return it so the engine cleans it up properly
        }
    }

    return loadedChest;
}

// Init
static void *patchThread(void *arg) {
    printf("[Anti-Exploit] Loading Portal Chest patch...\n");
    sleep(2); 

    Class targetClass = objc_getClass(TARGET_CLASS);
    if (!targetClass) {
        printf("[Anti-Exploit] ERROR: Class not found.\n");
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
