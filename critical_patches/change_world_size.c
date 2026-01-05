#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <dlfcn.h>
#include <objc/runtime.h>
#include <objc/message.h>
#include <getopt.h>

// --- TYPEDEFS ---
// Mantenemos float en credit para evitar el crash de registros XMM/General
typedef void (*LoadWorld_PTR)(id, SEL, id, id, id, int, int, int, float, id, id, id, BOOL, BOOL);
typedef id (*InitWorld_PTR)(id, SEL, id, id, id, id, id, id, id, id, id, int, int, id, BOOL);
typedef int (*GetOpt_PTR)(int argc, char * const argv[], const char *optstring, const struct option *longopts, int *longindex);

// --- VARIABLES GLOBALES ESTATICAS (PRIVADAS) ---
// El uso de 'static' es VITAL para que no choque con change_world_mode.so
static LoadWorld_PTR size_original_LoadWorld = NULL;
static InitWorld_PTR size_original_InitWorld = NULL;
static GetOpt_PTR size_original_getopt_long_only = NULL;

static int size_hooks_installed = 0;
static int TARGET_MACRO_WIDTH = 0;

// --- HELPERS ---
static int get_int_ivar_safe(id object, const char* ivarName) {
    if (!object) return -1;
    Ivar ivar = class_getInstanceVariable(object_getClass(object), ivarName);
    if (ivar) {
        ptrdiff_t offset = ivar_getOffset(ivar);
        int* ptr = (int*)((char*)object + offset);
        return *ptr;
    }
    return -2;
}

static void set_int_ivar_safe(id object, const char* ivarName, int value) {
    if (!object) return;
    Ivar ivar = class_getInstanceVariable(object_getClass(object), ivarName);
    if (ivar) {
        ptrdiff_t offset = ivar_getOffset(ivar);
        int* ptr = (int*)((char*)object + offset);
        *ptr = value; 
    }
}

// --- PAYLOAD (SIZE) ---
// Nombre único para evitar conflictos de símbolos en el linker dinámico
static void size_hooked_LoadWorld(id self, SEL _cmd, id saveDict, id saveID, id port, int maxP, int delay, int widthMacro, float credit, id salt, id owner, id privacy, BOOL convert, BOOL noExit) {
    
    // 1. Obtener configuración
    char* env_raw = getenv("BH_RAW");
    char* env_mul = getenv("BH_MUL");
    
    int final_size = widthMacro;

    if (env_raw) {
        final_size = atoi(env_raw);
    } 
    else if (env_mul) {
        int mul = atoi(env_mul);
        final_size = 512 * mul;
    }

    if (final_size < 1) final_size = 16;

    TARGET_MACRO_WIDTH = final_size;

    // 2. Llamar al siguiente en la cadena (podría ser el original o el hook de change_world_mode)
    if (size_original_LoadWorld)
        size_original_LoadWorld(self, _cmd, saveDict, saveID, port, maxP, delay, final_size, credit, salt, owner, privacy, convert, noExit);
}

// --- FORCE MEMORY OVERWRITE (SIZE) ---
static id size_hooked_InitWorld(id self, SEL _cmd, id winInfo, id cache, id delegate, id saveID, id name, id client, id server, id mpData, id hostData, int saveDelay, int widthMacro, id rules, BOOL expert) {
    // 1. Dejar que el juego (y la DB) carguen primero
    id result = size_original_InitWorld(self, _cmd, winInfo, cache, delegate, saveID, name, client, server, mpData, hostData, saveDelay, widthMacro, rules, expert);
    
    // 2. AGRESIVO: Si el usuario pidió un tamaño específico, lo forzamos en RAM
    // Esto anula lo que el juego haya leído del archivo world.bin
    if (result && TARGET_MACRO_WIDTH > 0) {
        int current = get_int_ivar_safe(result, "worldWidthMacro");
        if (current != TARGET_MACRO_WIDTH) {
            set_int_ivar_safe(result, "worldWidthMacro", TARGET_MACRO_WIDTH);
        }
    }
    return result;
}

// --- BOOTSTRAP ---
static void install_size_hooks() {
    if (size_hooks_installed) return;
    
    Class cmdClass = objc_getClass("CommandLineDelegate");
    Class worldClass = objc_getClass("World");
    
    if (!cmdClass || !worldClass) return;

    // Hook LoadWorld (Chainable)
    SEL selLoad = sel_registerName("loadWorldWithSaveDict:saveID:port:maxPlayers:saveDelay:worldWidthMacro:credit:cloudSalt:ownerName:privacy:convertToCustomRules:noExit:");
    Method mLoad = class_getInstanceMethod(cmdClass, selLoad);
    if (mLoad) {
        // Guardamos la implementación actual (que podría ser el hook de Mode Manager o el original)
        size_original_LoadWorld = (LoadWorld_PTR)method_getImplementation(mLoad);
        // Ponemos nuestro hook encima
        method_setImplementation(mLoad, (IMP)size_hooked_LoadWorld);
    }

    // Hook InitWorld
    SEL selInit = sel_registerName("initWithWindowInfo:cache:delegate:saveID:name:client:server:multiplayerWorldData:serverHostData:saveDelay:worldWidthMacro:customRules:expertMode:");
    Method mInit = class_getInstanceMethod(worldClass, selInit);
    if (mInit) {
        size_original_InitWorld = (InitWorld_PTR)method_getImplementation(mInit);
        method_setImplementation(mInit, (IMP)size_hooked_InitWorld);
    }

    size_hooks_installed = 1;
}

// Usamos getopt como punto de entrada seguro
int getopt_long_only(int argc, char * const argv[], const char *optstring, const struct option *longopts, int *longindex) {
    if (!size_hooks_installed) install_size_hooks();
    
    if (!size_original_getopt_long_only) {
        size_original_getopt_long_only = dlsym(RTLD_NEXT, "getopt_long_only");
    }
    return size_original_getopt_long_only(argc, argv, optstring, longopts, longindex);
}
