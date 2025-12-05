/*
 * Chest Duplicator With Content
 * Target Class: Chest
 * Target ID: 1043
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
#include <pthread.h>   // <-- Necesario para pthread_create
#include <stdbool.h>   // <-- Necesario para bool, true, false
#include <objc/runtime.h>
#include <objc/message.h>

// --- Configuration ---
#define CHEST_CLASS_NAME  "Chest"
#define SERVER_CLASS_NAME "BHServer"
#define TARGET_ITEM_ID    1043

// --- Selectors ---
#define SEL_PLACE    "initWithWorld:dynamicWorld:atPosition:cache:item:flipped:saveDict:placedByClient:clientName:"
#define SEL_SPAWN    "createFreeBlockAtPosition:ofType:dataA:dataB:subItems:dynamicObjectSaveDict:hovers:playSound:priorityBlockhead:"
#define SEL_REMOVE   "remove:"  // Selector para evitar ghost blocks
#define SEL_TYPE     "itemType"
#define SEL_CMD      "handleCommand:issueClient:"
#define SEL_CHAT     "sendChatMessage:sendToClients:"
#define SEL_UTF8     "UTF8String"
#define SEL_STR      "stringWithUTF8String:"

// Auth Selectors
#define SEL_IS_CLOUD "playerIsCloudWideAdminWithAlias:"
#define SEL_IS_INVIS "playerIsCloudWideInvisibleAdminWithAlias:"

// --- Function Prototypes ---
typedef id (*PlaceFunc)(id, SEL, id, id, long long, id, id, unsigned char, id, id, id);
typedef id (*CmdFunc)(id, SEL, id, id);
typedef void (*ChatFunc)(id, SEL, id, id);
typedef id (*SpawnFunc)(id, SEL, long long, int, int, int, id, id, BOOL, BOOL, id);
typedef int (*IntFunc)(id, SEL);
typedef void (*VoidFunc)(id, SEL);
typedef void (*VoidBoolFunc)(id, SEL, BOOL); // Para remove:YES
typedef const char* (*StrFunc)(id, SEL);
typedef id (*StringFactoryFunc)(id, SEL, const char*);
typedef BOOL (*BoolObjArg)(id, SEL, id);

// --- Global Storage ---
static PlaceFunc real_Chest_InitPlace = NULL;
static CmdFunc   real_Server_HandleCmd = NULL;
static ChatFunc  real_Server_SendChat = NULL;
static id        g_ServerInstance = nil; 

// --- STATE ---
static bool g_DupeEnabled = false; 
static int  g_ExtraCount = 1;

int GetItemID(id obj) {
    if (!obj) return 0;
    SEL sel = sel_registerName(SEL_TYPE);
    IMP method = class_getMethodImplementation(object_getClass(obj), sel);
    if (method) return ((IntFunc)method)(obj, sel);
    return 0;
}

const char* GetStringText(id strObj) {
    if (!strObj) return "";
    SEL sel = sel_registerName(SEL_UTF8);
    IMP method = class_getMethodImplementation(object_getClass(strObj), sel);
    if (method) return ((StrFunc)method)(strObj, sel);
    return "";
}

id CreateNSString(const char* text) {
    Class cls = objc_getClass("NSString");
    if (!cls) return nil;
    SEL sel = sel_registerName(SEL_STR);
    Method m = class_getClassMethod(cls, sel);
    if (m) {
        return ((StringFactoryFunc)method_getImplementation(m))((id)cls, sel, text);
    }
    return nil;
}

// Spawns items (Original + Copies)
void SpawnClonedItems(id dynWorld, long long pos, id originalSaveDict) {
    if (!dynWorld || pos == -1) return;
    SEL sel = sel_registerName(SEL_SPAWN);
    IMP method = class_getMethodImplementation(object_getClass(dynWorld), sel);
    if (method) {
        SpawnFunc fSpawn = (SpawnFunc)method;
        // Spawn original item + extra copies
        int totalToSpawn = 1 + g_ExtraCount; 
        for (int i = 0; i < totalToSpawn; i++) {
            // Args: pos, type, dataA, dataB, subItems, saveDict, hovers, playSound, priorityBlockhead
            fSpawn(dynWorld, sel, pos, TARGET_ITEM_ID, 1, 0, nil, originalSaveDict, 1, 0, nil);
        }
    }
}

// FIX: Usamos remove:YES para limpiar el tile correctamente
void SafeRemoveObject(id obj) {
    if (!obj) return;
    SEL sel = sel_registerName(SEL_REMOVE);
    IMP method = class_getMethodImplementation(object_getClass(obj), sel);
    if (method) {
        // remove:YES (YES = 1)
        ((VoidBoolFunc)method)(obj, sel, 1);
        printf("[Duplicator] Object removed cleanly via remove:YES\n");
    } else {
        printf("[Duplicator] ERROR: Failed to find remove: selector!\n");
    }
}

bool IsAuthorizedName(id server, id nameObj) {
    if (!server || !nameObj) return false;

    const char* cName = GetStringText(nameObj);
    printf("[Duplicator] Checking permissions for: %s\n", cName);

    // Check Cloud Wide
    SEL selCloud = sel_registerName(SEL_IS_CLOUD);
    if (class_getInstanceMethod(object_getClass(server), selCloud)) {
        IMP method = class_getMethodImplementation(object_getClass(server), selCloud);
        if (((BoolObjArg)method)(server, selCloud, nameObj)) {
            return true;
        }
    }

    // Check Invisible
    SEL selInvis = sel_registerName(SEL_IS_INVIS);
    if (class_getInstanceMethod(object_getClass(server), selInvis)) {
        IMP method = class_getMethodImplementation(object_getClass(server), selInvis);
        if (((BoolObjArg)method)(server, selInvis, nameObj)) {
            return true;
        }
    }

    return false;
}

// HOOK 1: Handle Command (/dupe)
id Hook_HandleCommand(id self, SEL _cmd, id commandStr, id client) {
    const char* text = GetStringText(commandStr);
    
    // Capture server instance for auth checks later
    g_ServerInstance = self;
    
    if (text && strncmp(text, "/dupe", 5) == 0) {
        int newAmount = -1;
        if (strlen(text) > 6) newAmount = atoi(text + 6);

        char msgBuffer[100];
        if (newAmount > 0) {
            g_DupeEnabled = true;
            g_ExtraCount = newAmount;
            snprintf(msgBuffer, sizeof(msgBuffer), "SYSTEM: Dupe ON (1 Drop + %d Copies)", g_ExtraCount);
        } else {
            g_DupeEnabled = !g_DupeEnabled;
            g_ExtraCount = 1; 
            snprintf(msgBuffer, sizeof(msgBuffer), g_DupeEnabled ? "SYSTEM: Dupe ON (1 Drop + 1 Copy)" : "SYSTEM: Dupe OFF");
        }

        if (real_Server_SendChat) {
            id nsMsg = CreateNSString(msgBuffer);
            real_Server_SendChat(self, sel_registerName(SEL_CHAT), nsMsg, nil);
        }
        printf("[Duplicator] %s\n", msgBuffer);
        return nil; // Consume command
    }

    if (real_Server_HandleCmd) {
        return real_Server_HandleCmd(self, _cmd, commandStr, client);
    }
    return nil;
}

// HOOK 2: Chest Placement (Logic principal)
id Hook_Chest_InitPlace(id self, SEL _cmd, id world, id dynWorld, long long pos, id cache, id item, unsigned char flipped, id saveDict, id client, id clientName) {
    
    // 1. Crear el objeto normalmente
    id newObj = NULL;
    if (real_Chest_InitPlace) {
        newObj = real_Chest_InitPlace(self, _cmd, world, dynWorld, pos, cache, item, flipped, saveDict, client, clientName);
    }

    // 2. Lógica de duplicación
    if (newObj && item) {
        if (GetItemID(item) == TARGET_ITEM_ID) {
            
            if (g_DupeEnabled && client != NULL) {
                
                // Verificar permisos usando el nombre del cliente
                if (IsAuthorizedName(g_ServerInstance, clientName)) {
                     printf("[Duplicator] AUTHORIZED Dupe at %lld.\n", pos);
                     
                     // A. Spawneamos los items (Original + Copias)
                     SpawnClonedItems(dynWorld, pos, saveDict);
                     
                     // B. Eliminamos el cofre INMEDIATAMENTE
                     SafeRemoveObject(newObj);
                     
                } else {
                     printf("[Duplicator] DENIED Dupe for %s (Not Admin).\n", GetStringText(clientName));
                }
            }
        }
    }

    return newObj;
}

static void *patchThread(void *arg) {
    printf("[Duplicator] Initializing Chest Cloner...\n");
    sleep(2);

    Class chestClass = objc_getClass(CHEST_CLASS_NAME);
    if (chestClass) {
        SEL selPlace = sel_registerName(SEL_PLACE);
        if (class_getInstanceMethod(chestClass, selPlace)) {
            real_Chest_InitPlace = (PlaceFunc)method_getImplementation(class_getInstanceMethod(chestClass, selPlace));
            method_setImplementation(class_getInstanceMethod(chestClass, selPlace), (IMP)Hook_Chest_InitPlace);
            printf("[Duplicator] Hooked Chest Placement.\n");
        }
    }

    Class serverClass = objc_getClass(SERVER_CLASS_NAME);
    if (serverClass) {
        SEL selCmd = sel_registerName(SEL_CMD);
        if (class_getInstanceMethod(serverClass, selCmd)) {
            real_Server_HandleCmd = (CmdFunc)method_getImplementation(class_getInstanceMethod(serverClass, selCmd));
            method_setImplementation(class_getInstanceMethod(serverClass, selCmd), (IMP)Hook_HandleCommand);
        }
        
        SEL selChat = sel_registerName(SEL_CHAT);
        if (class_getInstanceMethod(serverClass, selChat)) {
            real_Server_SendChat = (ChatFunc)method_getImplementation(class_getInstanceMethod(serverClass, selChat));
        }
    }

    printf("[Duplicator] Ready.\n");
    return NULL;
}

__attribute__((constructor))
static void init_hook() {
    pthread_t t;
    pthread_create(&t, NULL, patchThread, NULL);
}
