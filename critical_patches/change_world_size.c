#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <dlfcn.h>
#include <objc/runtime.h>
#include <objc/message.h>
#include <getopt.h>

// --- TYPEDEFS ---
// CORRECCIÓN CRÍTICA: 'credit' cambiado a float. 
// Si se deja en int, los registros de CPU se desalinean y el server se congela al cargar mundos x16.
typedef void (*CWS_LoadWorld_PTR)(id, SEL, id, id, id, int, int, int, float, id, id, id, BOOL, BOOL);
typedef id (*CWS_InitWorld_PTR)(id, SEL, id, id, id, id, id, id, id, id, id, int, int, id, BOOL);
typedef int (*CWS_GetOpt_PTR)(int argc, char * const argv[], const char *optstring, const struct option *longopts, int *longindex);

// --- VARIABLES GLOBALES (Con prefijo CWS_ para evitar choques con change_world_mode) ---
static CWS_LoadWorld_PTR CWS_original_LoadWorld = NULL;
static CWS_InitWorld_PTR CWS_original_InitWorld = NULL;
static CWS_GetOpt_PTR CWS_original_getopt_long_only = NULL;

static int CWS_hooks_installed = 0;
static int CWS_TARGET_MACRO_WIDTH = 0;

// --- HELPERS ---
static int CWS_get_int_ivar(id object, const char* ivarName) {
    if (!object) return -1;
    Ivar ivar = class_getInstanceVariable(object_getClass(object), ivarName);
    if (ivar) {
        ptrdiff_t offset = ivar_getOffset(ivar);
        int* ptr = (int*)((char*)object + offset);
        return *ptr;
    }
    return -2;
}

// --- PAYLOAD ---
// Hook para loadWorldWithSaveDict...
static void CWS_hooked_LoadWorld(id self, SEL _cmd, id saveDict, id saveID, id port, int maxP, int delay, int widthMacro, float credit, id salt, id owner, id privacy, BOOL convert, BOOL noExit) {
    printf("\n[GOD-MODE] >>> LoadWorld Interceptado (Size Patcher) <<<\n");
    
    // 1. BUSCAR VARIABLE DE TAMAÑO
    char* env_raw = getenv("BH_RAW");
    char* env_mul = getenv("BH_MUL");
    
    // Si no hay variables, usamos el widthMacro que viene del juego (que lee del savefile)
    int final_size = widthMacro; 

    if (env_raw) {
        final_size = atoi(env_raw);
        printf("[GOD-MODE] 🔬 MODO MICRO/RAW DETECTADO. Forzando valor exacto: %d\n", final_size);
    } 
    else if (env_mul) {
        int mul = atoi(env_mul);
        final_size = 512 * mul;
        printf("[GOD-MODE] 🚀 MODO MULTIPLICADOR. 512 x %d = %d\n", mul, final_size);
    }
    else {
        printf("[GOD-MODE] ⚠️ Ninguna variable detectada. Usando valor del juego/save: %d\n", widthMacro);
    }

    CWS_TARGET_MACRO_WIDTH = final_size;

    // Llamamos al original con el tamaño (modificado o original)
    if (CWS_original_LoadWorld)
        CWS_original_LoadWorld(self, _cmd, saveDict, saveID, port, maxP, delay, final_size, credit, salt, owner, privacy, convert, noExit);
}

// --- VERIFICACION ---
// Hook para initWithWindowInfo...
static id CWS_hooked_InitWorld(id self, SEL _cmd, id winInfo, id cache, id delegate, id saveID, id name, id client, id server, id mpData, id hostData, int saveDelay, int widthMacro, id rules, BOOL expert) {
    
    id result = CWS_original_InitWorld(self, _cmd, winInfo, cache, delegate, saveID, name, client, server, mpData, hostData, saveDelay, widthMacro, rules, expert);
    
    if (result) {
        int val = CWS_get_int_ivar(result, "worldWidthMacro");
        
        // Solo verificamos si teníamos un objetivo específico
        if (CWS_TARGET_MACRO_WIDTH > 0) {
            if (val == CWS_TARGET_MACRO_WIDTH) {
                printf("[GOD-MODE] ✅ ÉXITO: Mundo cargado/generado con tamaño %d.\n", val);
            } else {
                printf("[GOD-MODE] ❌ AVISO: El tamaño en memoria es %d (Esperábamos %d). Si cargaste un save existente, el juego puede haber forzado su tamaño real.\n", val, CWS_TARGET_MACRO_WIDTH);
            }
        }
    }
    return result;
}

// --- BOOTSTRAP ---
static void CWS_install_objc_hooks() {
    if (CWS_hooks_installed) return;
    
    Class cmdClass = objc_getClass("CommandLineDelegate");
    Class worldClass = objc_getClass("World");
    
    if (!cmdClass || !worldClass) return;

    // Hook LoadWorld
    SEL selLoad = sel_registerName("loadWorldWithSaveDict:saveID:port:maxPlayers:saveDelay:worldWidthMacro:credit:cloudSalt:ownerName:privacy:convertToCustomRules:noExit:");
    Method mLoad = class_getInstanceMethod(cmdClass, selLoad);
    if (mLoad) {
        CWS_original_LoadWorld = (CWS_LoadWorld_PTR)method_getImplementation(mLoad);
        method_setImplementation(mLoad, (IMP)CWS_hooked_LoadWorld);
    }

    // Hook InitWorld
    SEL selInit = sel_registerName("initWithWindowInfo:cache:delegate:saveID:name:client:server:multiplayerWorldData:serverHostData:saveDelay:worldWidthMacro:customRules:expertMode:");
    Method mInit = class_getInstanceMethod(worldClass, selInit);
    if (mInit) {
        CWS_original_InitWorld = (CWS_InitWorld_PTR)method_getImplementation(mInit);
        method_setImplementation(mInit, (IMP)CWS_hooked_InitWorld);
    }
    CWS_hooks_installed = 1;
}

// Interceptamos getopt para iniciar todo
int getopt_long_only(int argc, char * const argv[], const char *optstring, const struct option *longopts, int *longindex) {
    if (!CWS_hooks_installed) CWS_install_objc_hooks();
    
    if (!CWS_original_getopt_long_only) {
        CWS_original_getopt_long_only = dlsym(RTLD_NEXT, "getopt_long_only");
    }
    return CWS_original_getopt_long_only(argc, argv, optstring, longopts, longindex);
}
