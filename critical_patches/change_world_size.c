#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <dlfcn.h>
#include <objc/runtime.h>
#include <objc/message.h>
#include <getopt.h>

// --- TYPEDEFS ---
// IMPORTANTE: 'credit' es float para evitar corrupción de memoria (ABI mismatch)
typedef void (*CWS_LoadWorld_PTR)(id, SEL, id, id, id, int, int, int, float, id, id, id, BOOL, BOOL);
typedef id (*CWS_InitWorld_PTR)(id, SEL, id, id, id, id, id, id, id, id, id, int, int, id, BOOL);
typedef int (*CWS_GetOpt_PTR)(int argc, char * const argv[], const char *optstring, const struct option *longopts, int *longindex);

// --- VARIABLES GLOBALES ESTATICAS CON PREFIJO CWS ---
// El prefijo evita conflictos con otros parches como change_world_mode.so
static CWS_LoadWorld_PTR CWS_original_LoadWorld = NULL;
static CWS_InitWorld_PTR CWS_original_InitWorld = NULL;
static CWS_GetOpt_PTR CWS_original_getopt_long_only = NULL;

static int CWS_hooks_installed = 0;
static int CWS_TARGET_WIDTH = 0; // 0 = Modo Pasivo (No tocar nada)

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

static void CWS_set_int_ivar(id object, const char* ivarName, int value) {
    if (!object) return;
    Ivar ivar = class_getInstanceVariable(object_getClass(object), ivarName);
    if (ivar) {
        ptrdiff_t offset = ivar_getOffset(ivar);
        int* ptr = (int*)((char*)object + offset);
        *ptr = value; 
    }
}

// --- PAYLOAD: LoadWorld ---
// Intercepta la carga para leer variables de entorno y pasar el tamaño inicial
static void CWS_hooked_LoadWorld(id self, SEL _cmd, id saveDict, id saveID, id port, int maxP, int delay, int widthMacro, float credit, id salt, id owner, id privacy, BOOL convert, BOOL noExit) {
    
    char* env_raw = getenv("BH_RAW");
    char* env_mul = getenv("BH_MUL");
    
    int final_size = 0; // Default 0: Usar el del juego

    if (env_raw) {
        final_size = atoi(env_raw);
    } 
    else if (env_mul) {
        int mul = atoi(env_mul);
        final_size = 512 * mul;
    }

    // Seguridad mínima
    if (final_size > 0 && final_size < 16) final_size = 16;

    // Guardar objetivo globalmente
    CWS_TARGET_WIDTH = final_size;

    // Decidir qué pasar al siguiente eslabón de la cadena:
    // Si target > 0, pasamos el nuestro. Si es 0, pasamos el original (widthMacro).
    int size_to_pass = (CWS_TARGET_WIDTH > 0) ? CWS_TARGET_WIDTH : widthMacro;

    if (CWS_original_LoadWorld)
        CWS_original_LoadWorld(self, _cmd, saveDict, saveID, port, maxP, delay, size_to_pass, credit, salt, owner, privacy, convert, noExit);
}

// --- PAYLOAD: InitWorld ---
// Intercepta la inicialización para SOBRESCRIBIR la memoria si el savefile restauró el tamaño original
static id CWS_hooked_InitWorld(id self, SEL _cmd, id winInfo, id cache, id delegate, id saveID, id name, id client, id server, id mpData, id hostData, int saveDelay, int widthMacro, id rules, BOOL expert) {
    
    // 1. Llamar al original (Esto lee el savefile y resetea widthMacro al valor guardado)
    id result = CWS_original_InitWorld(self, _cmd, winInfo, cache, delegate, saveID, name, client, server, mpData, hostData, saveDelay, widthMacro, rules, expert);
    
    // 2. FORZADO DE MEMORIA
    // Solo actuamos si CWS_TARGET_WIDTH > 0 (O sea, si hay variables de entorno activas)
    if (result && CWS_TARGET_WIDTH > 0) {
        int current = CWS_get_int_ivar(result, "worldWidthMacro");
        
        // Si el tamaño en memoria no coincide con lo que queremos, lo aplastamos.
        if (current != CWS_TARGET_WIDTH) {
            CWS_set_int_ivar(result, "worldWidthMacro", CWS_TARGET_WIDTH);
        }
    }
    return result;
}

// --- BOOTSTRAP ---
static void CWS_install_hooks() {
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

// --- ENTRY POINT ---
// Usamos getopt como punto de entrada seguro al inicio del proceso
int getopt_long_only(int argc, char * const argv[], const char *optstring, const struct option *longopts, int *longindex) {
    if (!CWS_hooks_installed) CWS_install_hooks();
    
    if (!CWS_original_getopt_long_only) {
        CWS_original_getopt_long_only = dlsym(RTLD_NEXT, "getopt_long_only");
    }
    return CWS_original_getopt_long_only(argc, argv, optstring, longopts, longindex);
}
