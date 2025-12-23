/*
 * Trade Portal Blocker (FIXED)
 * Target: Trade Portal (ID 210)
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
#define TARGET_CLASS "TradePortal" 
#define BANNED_ID    210            

// Selectors
#define SEL_PLACE  "initWithWorld:dynamicWorld:atPosition:cache:item:flipped:saveDict:placedByClient:clientName:"
#define SEL_LOAD   "initWithWorld:dynamicWorld:saveDict:cache:"
#define SEL_UPDATE "update:accurateDT:isSimulation:" 
#define SEL_DROP   "destroyItemType"       
#define SEL_OBJ    "objectType"            
#define SEL_MACRO  "removeFromMacroBlock"  
#define SEL_FLAG   "setNeedsRemoved:"      

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

// -----------------------------------------------------------------------------
// CLEANUP LOGIC

void safe_remove_fully(id block) {
    if (!block) return;
    Class cls = object_getClass(block);

    SEL sMacro = sel_registerName(SEL_MACRO);
    if (class_getInstanceMethod(cls, sMacro)) {
        VoidFunc f = (VoidFunc)method_getImplementation(class_getInstanceMethod(cls, sMacro));
        f(block, sMacro);
    }
    SEL sFlag = sel_registerName(SEL_FLAG);
    if (class_getInstanceMethod(cls, sFlag)) {
        BoolFunc f = (BoolFunc)method_getImplementation(class_getInstanceMethod(cls, sFlag));
        f(block, sFlag, 1); 
    }
}

void mark_for_removal_only(id block) {
    if (!block) return;
    Class cls = object_getClass(block);

    SEL sFlag = sel_registerName(SEL_FLAG);
    if (class_getInstanceMethod(cls, sFlag)) {
        BoolFunc f = (BoolFunc)method_getImplementation(class_getInstanceMethod(cls, sFlag));
        f(block, sFlag, 1); 
    }
}

// -----------------------------------------------------------------------------
// HOOKS

id hook_TP_Place(id self, SEL _cmd, id world, id dynWorld, long long pos, id cache, id item, unsigned char flipped, id saveDict, id client, id clientName) {
    
    if (item) {
        int id = get_item_id(item);
        if (id == BANNED_ID) {
            return NULL;
        }
    }

    if (original_place) {
        return original_place(self, _cmd, world, dynWorld, pos, cache, item, flipped, saveDict, client, clientName);
    }
    return NULL;
}

id hook_TP_Load(id self, SEL _cmd, id world, id dynWorld, id saveDict, id cache) {
    
    id obj = NULL;
    if (original_load) {
        obj = original_load(self, _cmd, world, dynWorld, saveDict, cache);
    }

    if (obj) {
        int id = get_deep_id(obj);
        if (id == BANNED_ID) {
            mark_for_removal_only(obj);
            return obj; 
        }
    }
    return obj;
}

void hook_TP_Update(id self, SEL _cmd, float dt, bool isSim) {
    
    int id = get_deep_id(self);
    
    if (id == BANNED_ID) {
        safe_remove_fully(self);
        return;
    }

    if (original_update) {
        original_update(self, _cmd, dt, isSim);
    }
}

// -----------------------------------------------------------------------------
static void *TBlocker_InitThread(void *arg) {
    sleep(2); 

    Class targetClass = objc_getClass(TARGET_CLASS);
    if (!targetClass) return NULL;

    SEL sPlace = sel_registerName(SEL_PLACE);
    Method mPlace = class_getInstanceMethod(targetClass, sPlace);
    if (mPlace) {
        original_place = (PlaceFunc)method_getImplementation(mPlace);
        method_setImplementation(mPlace, (IMP)hook_TP_Place);
    }

    SEL sLoad = sel_registerName(SEL_LOAD);
    Method mLoad = class_getInstanceMethod(targetClass, sLoad);
    if (mLoad) {
        original_load = (LoadFunc)method_getImplementation(mLoad);
        method_setImplementation(mLoad, (IMP)hook_TP_Load);
    }

    SEL sUpdate = sel_registerName(SEL_UPDATE);
    Method mUpdate = class_getInstanceMethod(targetClass, sUpdate);
    if (mUpdate) {
        original_update = (UpdateFunc)method_getImplementation(mUpdate);
        method_setImplementation(mUpdate, (IMP)hook_TP_Update);
    }

    return NULL;
}

__attribute__((constructor))
static void TBlocker_Entry() {
    pthread_t t;
    pthread_create(&t, NULL, TBlocker_InitThread, NULL);
}
