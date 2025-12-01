#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
#include <pthread.h>
#include <objc/runtime.h>
#include <objc/message.h>

/* FREIGHT CAR EXPLOIT FIX
   This patch intercepts the creation of FreightCar objects to prevent server crashes.
*/

// Fake constructor to replace the real FreightCar init methods
id fakeCtor(id self, SEL _cmd, ...) {
    printf("[Anti-Exploit] Blocked malicious FreightCar creation.\n");

    // 1. Force the game engine to mark the object for removal
    SEL selSetNeedsRemoved = sel_registerName("setNeedsRemoved:");
    IMP fnSetNeedsRemoved = class_getMethodImplementation(object_getClass(self), selSetNeedsRemoved);
    if (fnSetNeedsRemoved) {
        ((void (*)(id, SEL, BOOL))fnSetNeedsRemoved)(self, selSetNeedsRemoved, 1);
    }

    // 2. Free memory immediately
    SEL selDealloc = sel_registerName("dealloc");
    IMP fnDealloc = class_getMethodImplementation(object_getClass(self), selDealloc);
    if (fnDealloc) {
        ((void (*)(id, SEL))fnDealloc)(self, selDealloc);
    }

    return NULL;
}

// Thread that waits for the server to load classes, then applies the patch
static void *patchThread(void *arg) {
    // Wait 2 seconds for the server to initialize the ObjC runtime
    sleep(2); 

    printf("[Anti-Exploit] Searching for FreightCar class...\n");

    unsigned int classCount = 0;
    Class *classes = objc_copyClassList(&classCount);

    if (classes) {
        for (unsigned int i = 0; i < classCount; i++) {
            const char *name = class_getName(classes[i]);
            
            // Look for the target class
            if (name && strstr(name, "FreightCar")) {
                printf("[Anti-Exploit] Patching class: %s\n", name);

                // Known selectors used by the exploit
                SEL sel1 = sel_registerName("initWithWorld:dynamicWorld:atPosition:cache:saveDict:placedByClient:");
                SEL sel2 = sel_registerName("initWithWorld:dynamicWorld:cache:netData:");
                SEL sel3 = sel_registerName("initWithWorld:dynamicWorld:saveDict:chestSaveDict:cache:");

                // Replace methods with our fake constructor
                if(sel1) class_replaceMethod(classes[i], sel1, (IMP)fakeCtor, "v@:*");
                if(sel2) class_replaceMethod(classes[i], sel2, (IMP)fakeCtor, "v@:*");
                if(sel3) class_replaceMethod(classes[i], sel3, (IMP)fakeCtor, "v@:*");
            }
        }
        free(classes);
    } else {
        printf("[Anti-Exploit] Error: Could not retrieve class list.\n");
    }

    return NULL;
}

// Library constructor - runs automatically when loaded via LD_PRELOAD
__attribute__((constructor))
static void init_hook() {
    printf("[Anti-Exploit] Initializing FreightCar protection...\n");
    pthread_t t;
    pthread_create(&t, NULL, patchThread, NULL);
}
