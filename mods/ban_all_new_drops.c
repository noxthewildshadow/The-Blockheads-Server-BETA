//Commands: /ban_drops (This will ban newer drops)   /del_drops 

#define _GNU_SOURCE
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <objc/runtime.h>
#include <objc/message.h>

// --- CONFIGURATION ---
#define CLASS_SERVER        "BHServer"
#define CLASS_DYNWORLD      "DynamicWorld"
#define CLASS_FREEBLOCK     "FreeBlock"
#define IVAR_DYNAMIC_OBJS   "dynamicObjects"
#define IVAR_WORLD          "world"
#define IVAR_DYN_WORLD      "dynamicWorld"

// --- MEMORY LAYOUTS (GCC x64) ---
struct RbNode_Base {
    unsigned long _color;
    struct RbNode_Base* _parent;
    struct RbNode_Base* _left;
    struct RbNode_Base* _right;
};

struct RbNode {
    struct RbNode_Base base;
    uint64_t key;
    id value; 
};

struct RbTree_Impl {
    unsigned long _pad; 
    struct RbNode_Base _header;
    size_t _node_count;
};

// --- TYPE DEFINITIONS ---
typedef id (*IMP_Str)(id, SEL, const char*);
typedef const char* (*IMP_Utf8)(id, SEL);
typedef void (*IMP_SetBool)(id, SEL, BOOL);
typedef id (*IMP_Cmd)(id, SEL, id, id);
typedef void (*IMP_Msg)(id, SEL, id, BOOL, id);
typedef void (*IMP_Drop)(id, SEL, id);

// --- GLOBAL STATE ---
static IMP_Cmd  Real_HandleCommand = NULL;
static IMP_Msg  Real_SendChat = NULL;
static IMP_Drop Real_ClientDrop = NULL;
static bool     g_DropBanEnabled = false;

// --- UTILITIES ---

static bool BH_IsValidPtr(void* ptr) {
    uintptr_t addr = (uintptr_t)ptr;
    // Check for valid user-space alignment and range
    return (addr > 0x400000 && addr < 0x7fffffffffff && (addr % 8 == 0));
}

static id BH_CreateNSString(const char* cStr) {
    if (!cStr) return nil;
    Class cls = objc_getClass("NSString");
    SEL s = sel_registerName("stringWithUTF8String:");
    IMP_Str f = (IMP_Str)method_getImplementation(class_getClassMethod(cls, s));
    return f ? f((id)cls, s, cStr) : nil;
}

static const char* BH_GetCString(id nsStr) {
    if (!nsStr) return "";
    SEL s = sel_registerName("UTF8String");
    IMP_Utf8 f = (IMP_Utf8)method_getImplementation(class_getInstanceMethod(object_getClass(nsStr), s));
    return f ? f(nsStr, s) : "";
}

static void BH_Reply(id server, const char* msg) {
    if (server && Real_SendChat) {
        Real_SendChat(server, 
                      sel_registerName("sendChatMessage:displayNotification:sendToClients:"), 
                      BH_CreateNSString(msg), 
                      true, 
                      nil);
    }
}

// Retrieves IVAR value directly by offset, bypassing missing property getters
static id BH_GetIvarValue(id obj, const char* name) {
    if (!obj) return nil;
    Class cls = object_getClass(obj);
    Ivar iv = class_getInstanceVariable(cls, name);
    
    // Check for underscore convention
    if (!iv) {
        char buff[128];
        snprintf(buff, sizeof(buff), "_%s", name);
        iv = class_getInstanceVariable(cls, buff);
    }

    if (!iv) return nil;
    ptrdiff_t offset = ivar_getOffset(iv);
    return *(id*)((char*)obj + offset);
}

// --- MEMORY SCANNING LOGIC ---

static int BH_RecursiveWalk(struct RbNode_Base* node, Class targetCls, SEL selRem, IMP_SetBool impRem, int depth) {
    if (!node || depth > 500 || !BH_IsValidPtr(node)) return 0;

    int count = 0;
    
    // Access node value (Offset 40: 32 header + 8 key)
    struct RbNode* realNode = (struct RbNode*)node;
    id obj = realNode->value;

    if (obj && BH_IsValidPtr(obj)) {
        if (object_getClass(obj) == targetCls) {
            impRem(obj, selRem, true); // Mark for removal
            count++;
        }
    }

    if (node->_left)  count += BH_RecursiveWalk(node->_left, targetCls, selRem, impRem, depth + 1);
    if (node->_right) count += BH_RecursiveWalk(node->_right, targetCls, selRem, impRem, depth + 1);
    
    return count;
}

static int BH_PerformCleanup(id srv) {
    id world = BH_GetIvarValue(srv, IVAR_WORLD);
    if (!world) return -1;

    id dynWorld = BH_GetIvarValue(world, IVAR_DYN_WORLD);
    if (!dynWorld) return -1;

    // Locate the dynamicObjects map array
    Class dwClass = object_getClass(dynWorld);
    Ivar mapIvar = class_getInstanceVariable(dwClass, IVAR_DYNAMIC_OBJS);
    if (!mapIvar) return -1;

    ptrdiff_t mapOffset = ivar_getOffset(mapIvar);
    char* baseMaps = (char*)dynWorld + mapOffset;
    struct RbTree_Impl* mapsArray = (struct RbTree_Impl*)baseMaps;

    // Resolve removal method
    Class fbClass = objc_getClass(CLASS_FREEBLOCK);
    if (!fbClass) return -1;
    
    SEL sRem = sel_registerName("setNeedsRemoved:");
    Method mRem = class_getInstanceMethod(fbClass, sRem);
    IMP_SetBool fRem = (IMP_SetBool)method_getImplementation(mRem);

    int total = 0;

    // Iterate map array (Indices 0-64)
    for (int i = 0; i < 65; i++) {
        size_t count = mapsArray[i]._node_count;
        
        // Skip empty or corrupt maps
        if (count == 0 || count > 1000000) continue;

        struct RbNode_Base* root = mapsArray[i]._header._parent;
        if (root && BH_IsValidPtr(root)) {
            total += BH_RecursiveWalk(root, fbClass, sRem, fRem, 0);
        }
    }
    return total;
}

// --- HOOK IMPLEMENTATIONS ---

void Hook_CreateFreeblocks(id self, SEL _cmd, id data) {
    if (g_DropBanEnabled) {
        return; // Silently reject drop creation
    }
    if (Real_ClientDrop) {
        Real_ClientDrop(self, _cmd, data);
    }
}

id Hook_HandleCommand(id self, SEL _cmd, id cmdStr, id client) {
    const char* txt = BH_GetCString(cmdStr);
    
    if (txt) {
        if (strcasecmp(txt, "/del_drops") == 0) {
            int count = BH_PerformCleanup(self);
            char msg[64];
            if (count >= 0) {
                snprintf(msg, sizeof(msg), "[Admin] Cleaned %d items.", count);
            } else {
                snprintf(msg, sizeof(msg), "[Admin] Error: Failed to access world data.");
            }
            BH_Reply(self, msg);
            return nil; // Consume command
        }
        
        if (strcasecmp(txt, "/ban_drops") == 0) {
            g_DropBanEnabled = !g_DropBanEnabled;
            char msg[64];
            snprintf(msg, sizeof(msg), "[Admin] Drop Ban: %s", g_DropBanEnabled ? "ENABLED" : "DISABLED");
            BH_Reply(self, msg);
            return nil; // Consume command
        }
    }
    
    return Real_HandleCommand(self, _cmd, cmdStr, client);
}

// --- INITIALIZATION ---

static void* BH_LoaderThread(void* arg) {
    // Wait for Objective-C Runtime to be fully initialized
    sleep(3);
    
    Class clsServer = objc_getClass(CLASS_SERVER);
    Class clsDynWorld = objc_getClass(CLASS_DYNWORLD);

    if (clsServer) {
        // Hook Command Handler
        SEL sCmd = sel_registerName("handleCommand:issueClient:");
        Method mCmd = class_getInstanceMethod(clsServer, sCmd);
        if (mCmd) {
            Real_HandleCommand = (IMP_Cmd)method_getImplementation(mCmd);
            method_setImplementation(mCmd, (IMP)Hook_HandleCommand);
        }

        // Cache Send Message IMP
        SEL sMsg = sel_registerName("sendChatMessage:displayNotification:sendToClients:");
        Method mMsg = class_getInstanceMethod(clsServer, sMsg);
        if (mMsg) {
            Real_SendChat = (IMP_Msg)method_getImplementation(mMsg);
        }
    }

    if (clsDynWorld) {
        // Hook Drop Creation
        SEL sDrop = sel_registerName("createClientFreeblocksWithData:");
        Method mDrop = class_getInstanceMethod(clsDynWorld, sDrop);
        if (mDrop) {
            Real_ClientDrop = (IMP_Drop)method_getImplementation(mDrop);
            method_setImplementation(mDrop, (IMP)Hook_CreateFreeblocks);
        }
    }

    return NULL;
}

__attribute__((constructor)) static void BH_Entry() {
    pthread_t t; 
    pthread_create(&t, NULL, BH_LoaderThread, NULL);
}
