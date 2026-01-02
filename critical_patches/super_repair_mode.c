/*
 * Blockheads Super Repair Mode
 * * Description: 
 * Overrides the native /repair command logic to forcefully remove 
 * ANY block type at the tapped position (But main spawn portal). This includes protected 
 * blocks like Spawn Portals (Not main), Trade Portals, Natural blocks, and Fluids (Lava/Water).
 * * Logic:
 * Executes a "Trinity Strike" sequence on the target coordinate:
 * 1. Remove Interaction Object (Clears logic/protection/menus).
 * 2. Remove Water/Fluid (Clears Lava and Water layers).
 * 3. Remove Physical Tile (Clears the block and backwall).
 */

// MADE: BY FER THE WILD SHADOW (NO ONE MADE THIS POSSIBLE EARLIER)

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

// --- Configuration ---
#define DYN_WORLD_CLASS "DynamicWorld"
#define WORLD_CLASS     "World"

// --- Method Selectors ---
#define SEL_REPAIR      "doRepairForTileAtPos:"
#define SEL_REM_INT     "removeInteractionObjectAtPos:removeBlockhead:"
#define SEL_REM_WATER   "removeWaterTileAtPos:"
// The master removal selector
#define SEL_REM_TILE    "removeTileAtWorldX:worldY:createContentsFreeblockCount:createForegroundContentsFreeblockCount:removeBlockhead:onlyRemoveCOntents:onlyRemoveForegroundContents:sendWorldChangedNotifcation:dontRemoveContents:"

// --- Function Prototypes ---
typedef void (*RepairFunc)(id, SEL, long long);
typedef void (*RemoveTileFunc)(id, SEL, int, int, int, int, id, BOOL, BOOL, BOOL, BOOL);
typedef id   (*RemoveIntFunc)(id, SEL, long long, id);
typedef void (*RemoveWaterFunc)(id, SEL, long long);

// --- Global State ---
static RepairFunc Real_DoRepair = NULL;

// --- Helper Functions ---

id GetWorldInstance(id dynObj) {
    if (!dynObj) return nil;
    Ivar iv = class_getInstanceVariable(object_getClass(dynObj), "world");
    if (iv) return *(id*)((char*)dynObj + ivar_getOffset(iv));
    return nil;
}

// --- Hook Implementation ---

void Hook_DoRepair(id self, SEL _cmd, long long pos) {
    // 1. Decode Position (Packed 64-bit integer: X low, Y high)
    int x = (int)(pos & 0xFFFFFFFF);
    int y = (int)(pos >> 32);

    id world = GetWorldInstance(self);
    
    if (world) {
        // STEP 1: Remove Interaction Objects
        // Strips protections from Portals, Chests, Benches, Signs, etc.
        SEL sRemInt = sel_registerName(SEL_REM_INT);
        if (class_getInstanceMethod(object_getClass(self), sRemInt)) {
            RemoveIntFunc fRemInt = (RemoveIntFunc)method_getImplementation(class_getInstanceMethod(object_getClass(self), sRemInt));
            fRemInt(self, sRemInt, pos, nil);
        }

        // STEP 2: Remove Fluids
        // Essential for removing Lava (ID 31) and Water.
        SEL sRemWater = sel_registerName(SEL_REM_WATER);
        if (class_getInstanceMethod(object_getClass(world), sRemWater)) {
            RemoveWaterFunc fRemWater = (RemoveWaterFunc)method_getImplementation(class_getInstanceMethod(object_getClass(world), sRemWater));
            fRemWater(world, sRemWater, pos);
        }

        // STEP 3: Remove Physical Block
        // Removes the solid block, backwall, and updates the client.
        SEL sRemove = sel_registerName(SEL_REM_TILE);
        if (class_getInstanceMethod(object_getClass(world), sRemove)) {
            RemoveTileFunc fRemove = (RemoveTileFunc)method_getImplementation(class_getInstanceMethod(object_getClass(world), sRemove));
            
            // Arguments:
            // x, y, 
            // drops (0), drops (0), 
            // blockhead (nil/server), 
            // onlyContent (NO), onlyForeground (NO), 
            // notify (YES), dontRemoveContent (NO)
            fRemove(world, sRemove, x, y, 0, 0, nil, NO, NO, YES, NO);
        }
    } else {
        // Fallback: Use original logic if world instance is missing
        if (Real_DoRepair) Real_DoRepair(self, _cmd, pos);
    }
}

// --- Initialization ---

static void* PatchThread(void* arg) {
    // Wait for server initialization
    sleep(1);
    
    Class clsDyn = objc_getClass(DYN_WORLD_CLASS);
    if (clsDyn) {
        SEL sRepair = sel_registerName(SEL_REPAIR);
        Method mRepair = class_getInstanceMethod(clsDyn, sRepair);
        
        if (mRepair) {
            Real_DoRepair = (RepairFunc)method_getImplementation(mRepair);
            method_setImplementation(mRepair, (IMP)Hook_DoRepair);
        }
    }
    return NULL;
}

__attribute__((constructor)) static void Entry() {
    pthread_t t;
    pthread_create(&t, NULL, PatchThread, NULL);
}
