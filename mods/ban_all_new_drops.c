//Command: /ban_drops (This will ban newer drops)

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

#define CD_SERVER_CLASS "BHServer"
#define CD_DYN_WORLD    "DynamicWorld"

// --- GLOBALS ---
static bool g_CD_Active = false;

// --- IMP TYPES ---
typedef id (*CD_CmdFunc)(id, SEL, id, id);
typedef void (*CD_ChatFunc)(id, SEL, id, BOOL, id);
typedef id (*CD_DropFunc)(id, SEL, id);
typedef id (*CD_StrFunc)(id, SEL, const char*);
typedef const char* (*CD_Utf8Func)(id, SEL);

static CD_CmdFunc  Real_CD_HandleCmd = NULL;
static CD_ChatFunc Real_CD_SendChat = NULL;
static CD_DropFunc Real_CD_ClientDrop = NULL;

// --- UTILS ---
static id CD_Str(const char* txt) {
    if (!txt) return nil;
    Class cls = objc_getClass("NSString");
    SEL s = sel_registerName("stringWithUTF8String:");
    CD_StrFunc f = (CD_StrFunc)method_getImplementation(class_getClassMethod(cls, s));
    return f ? f((id)cls, s, txt) : nil;
}

static const char* CD_CStr(id str) {
    if (!str) return "";
    SEL s = sel_registerName("UTF8String");
    CD_Utf8Func f = (CD_Utf8Func)method_getImplementation(class_getInstanceMethod(object_getClass(str), s));
    return f ? f(str, s) : "";
}

static void CD_Msg(id server, const char* msg) {
    if (server && Real_CD_SendChat) {
        Real_CD_SendChat(server, sel_registerName("sendChatMessage:displayNotification:sendToClients:"), CD_Str(msg), true, nil);
    }
}

// --- HOOKS ---
id Hook_CD_ClientDrop(id self, SEL _cmd, id data) {
    if (g_CD_Active) return nil;
    if (Real_CD_ClientDrop) return Real_CD_ClientDrop(self, _cmd, data);
    return nil;
}

id Hook_CD_Cmd(id self, SEL _cmd, id cmdStr, id client) {
    const char* raw = CD_CStr(cmdStr);
    if (!raw) return Real_CD_HandleCmd(self, _cmd, cmdStr, client);
    
    if (strncmp(raw, "/ban_drops", 12) == 0) {
        g_CD_Active = !g_CD_Active;
        char msg[128];
        snprintf(msg, 128, "[System] Drop Cleaner: %s", g_CD_Active ? "ON" : "OFF");
        CD_Msg(self, msg);
        return nil;
    }
    return Real_CD_HandleCmd(self, _cmd, cmdStr, client);
}

// --- INIT ---
static void* CD_Init(void* arg) {
    sleep(1);
    Class clsSrv = objc_getClass(CD_SERVER_CLASS);
    Class clsDW = objc_getClass(CD_DYN_WORLD);

    if (clsSrv) {
        Method mC = class_getInstanceMethod(clsSrv, sel_registerName("handleCommand:issueClient:"));
        Real_CD_HandleCmd = (CD_CmdFunc)method_getImplementation(mC);
        method_setImplementation(mC, (IMP)Hook_CD_Cmd);
        
        Method mT = class_getInstanceMethod(clsSrv, sel_registerName("sendChatMessage:displayNotification:sendToClients:"));
        Real_CD_SendChat = (CD_ChatFunc)method_getImplementation(mT);
    }

    if (clsDW) {
        Method mD = class_getInstanceMethod(clsDW, sel_registerName("createClientFreeblocksWithData:"));
        Real_CD_ClientDrop = (CD_DropFunc)method_getImplementation(mD);
        method_setImplementation(mD, (IMP)Hook_CD_ClientDrop);
    }
    return NULL;
}

__attribute__((constructor)) static void CD_Entry() {
    pthread_t t; pthread_create(&t, NULL, CD_Init, NULL);
}
