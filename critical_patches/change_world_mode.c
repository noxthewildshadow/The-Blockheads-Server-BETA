#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdbool.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <dlfcn.h>
#include <objc/runtime.h>

static bool hook_installed = false;

// --- IMP Typedefs to avoid objc_msgSend linking errors ---
typedef id (*IMP_MutableCopy)(id, SEL);
typedef id (*IMP_StringWithUTF8)(id, SEL, const char*);
typedef id (*IMP_NumberWithBool)(id, SEL, BOOL);
typedef void (*IMP_SetObject)(id, SEL, id, id);
typedef void (*IMP_RemoveObject)(id, SEL, id);
typedef void (*IMP_Release)(id, SEL);

// Pointer to the original method
typedef void (*LoadWorld_ptr)(id, SEL, id, id, id, int, int, int, int, id, id, id, BOOL, BOOL);
static LoadWorld_ptr original_LoadWorld;

void hooked_LoadWorld(id self, SEL _cmd, id saveDict, id saveID, id port, int maxP, int delay, int width, int credit, id salt, id owner, id privacy, BOOL convert, BOOL noExit) {
    
    // 1. Check environment variable
    char* mode_env = getenv("BH_MODE");
    if (!mode_env || strlen(mode_env) == 0) {
        original_LoadWorld(self, _cmd, saveDict, saveID, port, maxP, delay, width, credit, salt, owner, privacy, convert, noExit);
        return;
    }

    // 2. Clone dictionary (mutableCopy)
    SEL mutableCopySel = sel_registerName("mutableCopy");
    Class dictClass = object_getClass(saveDict); 
    Method mCopyMethod = class_getInstanceMethod(dictClass, mutableCopySel);
    
    id mutableDict = nil;
    if (mCopyMethod) {
        IMP_MutableCopy copyFunc = (IMP_MutableCopy)method_getImplementation(mCopyMethod);
        mutableDict = copyFunc(saveDict, mutableCopySel);
    }

    if (mutableDict) {
        // --- Prepare Classes and Selectors ---
        Class strClass = objc_getClass("NSString");
        Class numClass = objc_getClass("NSNumber");
        Class mutableDictClass = object_getClass(mutableDict);

        SEL stringSel = sel_registerName("stringWithUTF8String:");
        SEL boolNumberSel = sel_registerName("numberWithBool:");
        SEL setObjSel = sel_registerName("setObject:forKey:");
        SEL removeSel = sel_registerName("removeObjectForKey:");

        // --- Get Implementations (IMPs) ---
        Method stringMethod = class_getClassMethod(strClass, stringSel);
        Method boolMethod = class_getClassMethod(numClass, boolNumberSel);
        Method setMethod = class_getInstanceMethod(mutableDictClass, setObjSel);
        Method removeMethod = class_getInstanceMethod(mutableDictClass, removeSel);

        IMP_StringWithUTF8 stringFunc = (IMP_StringWithUTF8)method_getImplementation(stringMethod);
        IMP_NumberWithBool numFunc = (IMP_NumberWithBool)method_getImplementation(boolMethod);
        IMP_SetObject setFunc = (IMP_SetObject)method_getImplementation(setMethod);
        IMP_RemoveObject removeFunc = (IMP_RemoveObject)method_getImplementation(removeMethod);

        // --- Create Keys ---
        id strExpertKey = stringFunc((id)strClass, stringSel, "expertMode");
        id strRulesKey = stringFunc((id)strClass, stringSel, "customRules");

        // --- Logic by Mode ---
        BOOL targetExpert = NO;
        BOOL targetConvert = NO; 
        BOOL shouldInjectExpert = NO; 
        BOOL shouldRemoveRules = NO;

        if (strcmp(mode_env, "EXPERT") == 0) {
            targetExpert = YES;
            shouldInjectExpert = YES;
        } 
        else if (strcmp(mode_env, "VANILLA") == 0) {
            targetExpert = NO;
            shouldInjectExpert = YES;
            shouldRemoveRules = YES;
        }
        else if (strcmp(mode_env, "CUSTOM") == 0) {
            targetExpert = NO;
            shouldInjectExpert = YES;
            targetConvert = YES; // Triggers internal game conversion
        }

        // 3. Apply Changes
        if (shouldInjectExpert && setFunc) {
            id valExpert = numFunc((id)numClass, boolNumberSel, targetExpert);
            setFunc(mutableDict, setObjSel, valExpert, strExpertKey);
        }

        if (shouldRemoveRules && removeFunc) {
            removeFunc(mutableDict, removeSel, strRulesKey);
        }

        // 4. Call Original with modified data
        // Force 'convert' argument if targetConvert is set
        BOOL finalConvert = targetConvert ? YES : convert;
        
        original_LoadWorld(self, _cmd, mutableDict, saveID, port, maxP, delay, width, credit, salt, owner, privacy, finalConvert, noExit);
        
        // 5. Cleanup
        SEL releaseSel = sel_registerName("release");
        Method releaseMethod = class_getInstanceMethod(mutableDictClass, releaseSel);
        if (releaseMethod) {
            IMP_Release releaseFunc = (IMP_Release)method_getImplementation(releaseMethod);
            releaseFunc(mutableDict, releaseSel);
        }

    } else {
        // Fallback if copy fails
        original_LoadWorld(self, _cmd, saveDict, saveID, port, maxP, delay, width, credit, salt, owner, privacy, convert, noExit);
    }
}

void* install_thread(void* arg) {
    int attempts = 0;
    while (!hook_installed && attempts < 1000) {
        Class targetClass = objc_getClass("CommandLineDelegate");
        if (targetClass) {
            SEL targetSel = sel_registerName("loadWorldWithSaveDict:saveID:port:maxPlayers:saveDelay:worldWidthMacro:credit:cloudSalt:ownerName:privacy:convertToCustomRules:noExit:");
            Method targetMethod = class_getInstanceMethod(targetClass, targetSel);
            
            if (targetMethod) {
                original_LoadWorld = (LoadWorld_ptr)method_getImplementation(targetMethod);
                method_setImplementation(targetMethod, (IMP)hooked_LoadWorld);
                hook_installed = true;
                return NULL;
            }
        }
        usleep(10000); // 10ms
        attempts++;
    }
    return NULL;
}

__attribute__((constructor))
void init_patch() {
    pthread_t thread_id;
    pthread_create(&thread_id, NULL, install_thread, NULL);
    pthread_detach(thread_id);
}
