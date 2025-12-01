#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
#include <pthread.h>
#include <objc/runtime.h>
#include <objc/message.h>

// Fake constructor to replace FreightCar init methods
id fakeCtor(id self, SEL _cmd, ...) {
    printf("[Anti-Exploit] FreightCar creation blocked: %s\n", sel_getName(_cmd));

    // setNeedsRemoved:YES
    SEL selSetNeedsRemoved = sel_registerName("setNeedsRemoved:");
    IMP fnSetNeedsRemoved = class_getMethodImplementation(object_getClass(self), selSetNeedsRemoved);
    if (fnSetNeedsRemoved) {
        ((void (*)(id, SEL, BOOL))fnSetNeedsRemoved)(self, selSetNeedsRemoved, 1);
    }

    // dealloc
    SEL selDealloc = sel_registerName("dealloc");
    IMP fnDealloc = class_getMethodImplementation(object_getClass(self), selDealloc);
    if (fnDealloc) {
        ((void (*)(id, SEL))fnDealloc)(self, selDealloc);
    }

    return NULL;
}

// Thread to apply patch after server loads classes
static void *patchThread(void *arg) {
    sleep(2); // wait for runtime

    printf("[Anti-Exploit] Searching for FreightCar class...\n");

    int patched = 0;
    unsigned int classCount = objc_getClassList(NULL, 0);
    Class *classes = malloc(sizeof(Class) * classCount);
    if (!classes) return NULL;
    
    classCount = objc_getClassList(classes, classCount);

    for (unsigned int i = 0; i < classCount; i++) {
        const char *name = class_getName(classes[i]);
        if (name && strstr(name, "FreightCar")) {
            printf("[Anti-Exploit] Found class: %s\n", name);

            SEL sel1 = sel_registerName("initWithWorld:dynamicWorld:atPosition:cache:saveDict:placedByClient:");
            SEL sel2 = sel_registerName("initWithWorld:dynamicWorld:cache:netData:");
            SEL sel3 = sel_registerName("initWithWorld:dynamicWorld:saveDict:chestSaveDict:cache:");

            if (sel1) class_replaceMethod(classes[i], sel1, (IMP)fakeCtor, "v@:*");
            if (sel2) class_replaceMethod(classes[i], sel2, (IMP)fakeCtor, "v@:*");
            if (sel3) class_replaceMethod(classes[i], sel3, (IMP)fakeCtor, "v@:*");

            patched = 1;
            break;
        }
    }

    free(classes);

    if (patched)
        printf("[Anti-Exploit] FreightCar constructors patched successfully.\n");
    else
        printf("[Anti-Exploit] ERROR: Could not find FreightCar class!\n");

    return NULL;
}

__attribute__((constructor))
static void init_hook() {
    printf("[Anti-Exploit] Initializing patch thread...\n");
    pthread_t t;
    pthread_create(&t, NULL, patchThread, NULL);
}
