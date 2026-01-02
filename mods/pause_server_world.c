//Command: /pause (The command works for ON and OFF)

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdbool.h>
#include <objc/runtime.h>
#include <objc/message.h>

// --- CONFIG ---
#define PAUSE_SERVER_CLASS "BHServer"
#define PAUSE_DYN_WORLD    "DynamicWorld"

// --- IMP TYPES ---
typedef id (*PAUSE_CmdFunc)(id, SEL, id, id);
typedef void (*PAUSE_ChatFunc)(id, SEL, id, BOOL, id);
typedef void (*PAUSE_UpdateFunc)(id, SEL, float, bool);

// Memory & Utils
typedef id (*PAUSE_AllocFunc)(id, SEL);
typedef id (*PAUSE_InitFunc)(id, SEL);
typedef void (*PAUSE_VoidFunc)(id, SEL);
typedef id (*PAUSE_StrFunc)(id, SEL, const char*);
typedef const char* (*PAUSE_Utf8Func)(id, SEL);

// --- GLOBALS ---
static PAUSE_CmdFunc    Real_PAUSE_HandleCmd = NULL;
static PAUSE_ChatFunc   Real_PAUSE_SendChat = NULL;
static PAUSE_UpdateFunc Real_PAUSE_Update = NULL;

static bool g_PAUSE_Active = false;

// --- UTILS ---
static id PAUSE_Pool() {
    Class cls = objc_getClass("NSAutoreleasePool");
    SEL sA = sel_registerName("alloc");
    SEL sI = sel_registerName("init");
    PAUSE_AllocFunc fA = (PAUSE_AllocFunc)method_getImplementation(class_getClassMethod(cls, sA));
    PAUSE_InitFunc fI = (PAUSE_InitFunc)method_getImplementation(class_getInstanceMethod(cls, sI));
    return fI(fA((id)cls, sA), sI);
}

static void PAUSE_Drain(id pool) {
    if (!pool) return;
    SEL s = sel_registerName("drain");
    PAUSE_VoidFunc f = (PAUSE_VoidFunc)method_getImplementation(class_getInstanceMethod(object_getClass(pool), s));
    f(pool, s);
}

static id PAUSE_Str(const char* txt) {
    if (!txt) return nil;
    Class cls = objc_getClass("NSString");
    SEL s = sel_registerName("stringWithUTF8String:");
    PAUSE_StrFunc f = (PAUSE_StrFunc)method_getImplementation(class_getClassMethod(cls, s));
    return f ? f((id)cls, s, txt) : nil;
}

static const char* PAUSE_CStr(id str) {
    if (!str) return "";
    SEL s = sel_registerName("UTF8String");
    PAUSE_Utf8Func f = (PAUSE_Utf8Func)method_getImplementation(class_getInstanceMethod(object_getClass(str), s));
    return f ? f(str, s) : "";
}

static void PAUSE_Msg(id server, const char* msg) {
    if (server && Real_PAUSE_SendChat) {
        Real_PAUSE_SendChat(server, sel_registerName("sendChatMessage:displayNotification:sendToClients:"), PAUSE_Str(msg), true, nil);
    }
}

// --- HOOKS ---

// Hook DynamicWorld update loop
void Hook_PAUSE_Update(id self, SEL _cmd, float dt, bool isSim) {
    if (g_PAUSE_Active) {
        return; // Skip update (Freeze)
    }
    if (Real_PAUSE_Update) {
        Real_PAUSE_Update(self, _cmd, dt, isSim);
    }
}

id Hook_PAUSE_Cmd(id self, SEL _cmd, id cmdStr, id client) {
    const char* raw = PAUSE_CStr(cmdStr);
    if (!raw) return Real_PAUSE_HandleCmd(self, _cmd, cmdStr, client);
    
    if (strncmp(raw, "/pause", 6) == 0) {
        id pool = PAUSE_Pool();
        g_PAUSE_Active = !g_PAUSE_Active;
        
        char msg[128];
        snprintf(msg, 128, "[System] Server Freeze: %s", g_PAUSE_Active ? "ENABLED" : "DISABLED");
        PAUSE_Msg(self, msg);
        
        PAUSE_Drain(pool);
        return nil;
    }
    
    return Real_PAUSE_HandleCmd(self, _cmd, cmdStr, client);
}

// --- INIT ---
static void* PAUSE_Init(void* arg) {
    sleep(1);
    
    Class clsSrv = objc_getClass(PAUSE_SERVER_CLASS);
    if (clsSrv) {
        Method mC = class_getInstanceMethod(clsSrv, sel_registerName("handleCommand:issueClient:"));
        Real_PAUSE_HandleCmd = (PAUSE_CmdFunc)method_getImplementation(mC);
        method_setImplementation(mC, (IMP)Hook_PAUSE_Cmd);
        
        Method mT = class_getInstanceMethod(clsSrv, sel_registerName("sendChatMessage:displayNotification:sendToClients:"));
        Real_PAUSE_SendChat = (PAUSE_ChatFunc)method_getImplementation(mT);
    }
    
    Class clsDW = objc_getClass(PAUSE_DYN_WORLD);
    if (clsDW) {
        Method mUp = class_getInstanceMethod(clsDW, sel_registerName("update:accurateDT:isSimulation:"));
        Real_PAUSE_Update = (PAUSE_UpdateFunc)method_getImplementation(mUp);
        method_setImplementation(mUp, (IMP)Hook_PAUSE_Update);
    }
    
    return NULL;
}

__attribute__((constructor)) static void PAUSE_Entry() {
    pthread_t t; pthread_create(&t, NULL, PAUSE_Init, NULL);
}
