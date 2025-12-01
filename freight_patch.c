#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>     // strstr
#include <unistd.h>     // sleep
#include <dlfcn.h>
#include <pthread.h>
#include <objc/runtime.h>
#include <objc/message.h> // objc_msgSend

// Función fake para reemplazar constructores de FreightCar
id fakeCtor(id self, SEL _cmd, ...) {
    printf("[freightkill] FreightCar creation blocked: %s\n", sel_getName(_cmd));

    // setNeedsRemoved:YES
    SEL selSetNeedsRemoved = sel_registerName("setNeedsRemoved:");
    IMP fnSetNeedsRemoved = class_getMethodImplementation(object_getClass(self), selSetNeedsRemoved);
    ((void (*)(id, SEL, BOOL))fnSetNeedsRemoved)(self, selSetNeedsRemoved, 1);

    // dealloc
    SEL selDealloc = sel_registerName("dealloc");
    IMP fnDealloc = class_getMethodImplementation(object_getClass(self), selDealloc);
    ((void (*)(id, SEL))fnDealloc)(self, selDealloc);

    return NULL;
}

// Thread para parchear después de que el binario cargue todas las clases
static void *patchThread(void *arg) {
    sleep(1); // espera a que el runtime registre las clases

    printf("[freightkill] Searching for FreightCar class...\n");

    int patched = 0;
    unsigned int classCount = objc_getClassList(NULL, 0);
    Class *classes = malloc(sizeof(Class) * classCount);
    classCount = objc_getClassList(classes, classCount);

    for (unsigned int i = 0; i < classCount; i++) {
        const char *name = class_getName(classes[i]);
        if (strstr(name, "FreightCar")) {
            printf("[freightkill] Found class: %s\n", name);

            SEL sel1 = sel_registerName("initWithWorld:dynamicWorld:atPosition:cache:saveDict:placedByClient:");
            SEL sel2 = sel_registerName("initWithWorld:dynamicWorld:cache:netData:");
            SEL sel3 = sel_registerName("initWithWorld:dynamicWorld:saveDict:chestSaveDict:cache:");

            class_replaceMethod(classes[i], sel1, (IMP)fakeCtor, "v@:*");
            class_replaceMethod(classes[i], sel2, (IMP)fakeCtor, "v@:*");
            class_replaceMethod(classes[i], sel3, (IMP)fakeCtor, "v@:*");

            patched = 1;
            break;
        }
    }

    free(classes);

    if (patched)
        printf("[freightkill] FreightCar constructors patched successfully.\n");
    else
        printf("[freightkill] ERROR: Could not find FreightCar class!\n");

    return NULL;
}

__attribute__((constructor))
static void init_hook() {
    printf("[freightkill] Initializing patch thread...\n");
    pthread_t t;
    pthread_create(&t, NULL, patchThread, NULL);
}
