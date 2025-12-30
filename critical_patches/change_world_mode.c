#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdbool.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <dlfcn.h>
#include <objc/runtime.h>
#include <stddef.h>

// --- TYPEDEFS ---
typedef void (*LoadWorld_PTR)(id, SEL, id, id, id, int, int, int, int, id, id, id, BOOL, BOOL);
typedef BOOL (*LoadGame_PTR)(id, SEL);
typedef void (*RulesChanged_PTR)(id, SEL);

// --- VARIABLES GLOBALES ---
static LoadWorld_PTR original_LoadWorld = NULL;
static LoadGame_PTR original_LoadGame = NULL;
static RulesChanged_PTR original_RulesChanged = NULL;

static bool hook_cmd_installed = false;
static bool hook_world_installed = false;

// --- HERRAMIENTAS DE MEMORIA (LOBOTOMÍA) ---

// Pone una variable de objeto en nil (Borrar reglas)
void nuke_ivar(id object, const char* ivarName) {
    if (!object) return;
    Ivar ivar = class_getInstanceVariable(object_getClass(object), ivarName);
    if (ivar) {
        object_setIvar(object, ivar, nil);
        printf("[MODE-MGR] Variable '%s' eliminada de RAM (nil).\n", ivarName);
    }
}

// Fuerza un valor booleano en memoria (YES/NO)
void set_bool_ivar(id object, const char* ivarName, BOOL value) {
    if (!object) return;
    Ivar ivar = class_getInstanceVariable(object_getClass(object), ivarName);
    if (ivar) {
        ptrdiff_t offset = ivar_getOffset(ivar);
        unsigned char* ptr = (unsigned char*)((char*)object + offset);
        *ptr = value ? 1 : 0;
        printf("[MODE-MGR] Variable '%s' forzada a %s en RAM.\n", ivarName, value ? "YES" : "NO");
    }
}

// --- HOOK 1: COMMAND LINE DELEGATE (Argumentos de Entrada) ---
// Este hook intercepta la orden de cargar y manipula los argumentos iniciales
void hooked_LoadWorld(id self, SEL _cmd, id saveDict, id saveID, id port, int maxP, int delay, int width, int credit, id salt, id owner, id privacy, BOOL convert, BOOL noExit) {
    
    char* mode_env = getenv("BH_MODE");
    printf("\n[MODE-MGR] LoadWorld interceptado. Modo solicitado: %s\n", mode_env ? mode_env : "NORMAL");

    BOOL finalConvert = convert;
    BOOL isVanillaTarget = false;

    // Lógica de Manipulación de Argumentos
    if (mode_env) {
        if (strcmp(mode_env, "CUSTOM") == 0) {
            printf("[MODE-MGR] Forzando conversión a Custom Rules...\n");
            finalConvert = YES; // Esto le dice al juego que genere reglas nuevas
        }
        else if (strcmp(mode_env, "VANILLA") == 0) {
            printf("[MODE-MGR] Preparando carga Vanilla...\n");
            finalConvert = NO; 
            isVanillaTarget = true;
        }
    }

    // Llamamos al original. 
    // Nota: No manipulamos saveDict aquí porque aprendimos que la DB lo sobreescribe.
    // Dejamos que eso lo maneje el Hook 2 (Lobotomía).
    original_LoadWorld(self, _cmd, saveDict, saveID, port, maxP, delay, width, credit, salt, owner, privacy, finalConvert, noExit);
}

// --- HOOK 2: WORLD LOAD GAME (Lobotomía Post-Carga) ---
// Se ejecuta DESPUÉS de que el juego lee la base de datos. Aquí es donde reescribimos la realidad.
BOOL hooked_LoadGame(id self, SEL _cmd) {
    char* mode_env = getenv("BH_MODE");
    
    // 1. Dejar que cargue normalmente (leyendo la DB sucia)
    BOOL result = NO;
    if (original_LoadGame) {
        result = original_LoadGame(self, _cmd);
    }

    if (result && mode_env) {
        printf("[MODE-MGR] Carga de DB terminada. Aplicando parches de memoria para modo: %s\n", mode_env);

        if (strcmp(mode_env, "VANILLA") == 0) {
            // === LA LOBOTOMÍA ===
            // Borramos cualquier regla que se haya cargado de la DB
            nuke_ivar(self, "customRulesDict");
            nuke_ivar(self, "customRules"); 
            set_bool_ivar(self, "expertMode", NO);
            
            // Forzamos al motor a actualizarse
            if (original_RulesChanged) {
                printf("[MODE-MGR] Ejecutando customRulesChanged para purificar físicas...\n");
                original_RulesChanged(self, sel_registerName("customRulesChanged"));
            }
            printf("[MODE-MGR] >>> MUNDO FORZADO A VANILLA (RAM LIMPIA) <<<\n");
        }
        else if (strcmp(mode_env, "EXPERT") == 0) {
            // Forzamos modo experto en memoria (por si la DB decía que no)
            set_bool_ivar(self, "expertMode", YES);
            printf("[MODE-MGR] >>> MUNDO FORZADO A EXPERT MODE <<<\n");
        }
        // Para CUSTOM no hacemos nada aquí, ya que el Hook 1 forzó la conversión.
    }

    return result;
}

// --- INSTALADOR ---
void* install_thread(void* arg) {
    int attempts = 0;
    while ((!hook_cmd_installed || !hook_world_installed) && attempts < 2000) {
        
        // 1. Hookear CommandLineDelegate (Para CUSTOM/Init)
        if (!hook_cmd_installed) {
            Class cmdClass = objc_getClass("CommandLineDelegate");
            if (cmdClass) {
                SEL selLoad = sel_registerName("loadWorldWithSaveDict:saveID:port:maxPlayers:saveDelay:worldWidthMacro:credit:cloudSalt:ownerName:privacy:convertToCustomRules:noExit:");
                Method mLoad = class_getInstanceMethod(cmdClass, selLoad);
                if (mLoad) {
                    original_LoadWorld = (LoadWorld_PTR)method_getImplementation(mLoad);
                    method_setImplementation(mLoad, (IMP)hooked_LoadWorld);
                    hook_cmd_installed = true;
                    printf("[MODE-MGR] Hook instalado en CommandLineDelegate.\n");
                }
            }
        }

        // 2. Hookear World (Para VANILLA/EXPERT Post-Carga)
        if (!hook_world_installed) {
            Class worldClass = objc_getClass("World");
            if (worldClass) {
                SEL loadSel = sel_registerName("loadGame");
                Method loadMethod = class_getInstanceMethod(worldClass, loadSel);
                
                SEL rulesSel = sel_registerName("customRulesChanged");
                Method rulesMethod = class_getInstanceMethod(worldClass, rulesSel);

                if (loadMethod && rulesMethod) {
                    original_LoadGame = (LoadGame_PTR)method_getImplementation(loadMethod);
                    original_RulesChanged = (RulesChanged_PTR)method_getImplementation(rulesMethod);
                    
                    method_setImplementation(loadMethod, (IMP)hooked_LoadGame);
                    hook_world_installed = true;
                    printf("[MODE-MGR] Hook instalado en World (LoadGame).\n");
                }
            }
        }

        usleep(10000); // 10ms
        attempts++;
    }
    
    if (!hook_cmd_installed || !hook_world_installed) {
        printf("[MODE-MGR] ADVERTENCIA: No se pudieron instalar todos los hooks.\n");
    }
    return NULL;
}

__attribute__((constructor))
void init_patch() {
    pthread_t thread_id;
    pthread_create(&thread_id, NULL, install_thread, NULL);
    pthread_detach(thread_id);
}
