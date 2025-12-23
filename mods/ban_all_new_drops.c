/*
 * Clear All New Drops
 * Commands: /clear_drops
 */

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

#define BAN_SERVER_CLASS "BHServer"
#define BAN_DYN_WORLD    "DynamicWorld"

static bool g_ClearDrops_Active = false;

typedef id (*Ban_CmdFunc)(id, SEL, id, id);
typedef void (*Ban_ChatFunc)(id, SEL, id, id);
typedef id (*Ban_DropFunc)(id, SEL, id);

static Ban_CmdFunc  Real_Ban_HandleCmd = NULL;
static Ban_ChatFunc Real_Ban_SendChat = NULL;
static Ban_DropFunc Real_Ban_ClientDrop = NULL;

static id Ban_AllocStr(const char* text) {
    if (!text) return nil;
    Class cls = objc_getClass("NSString");
    SEL sel = sel_registerName("stringWithUTF8String:");
    Method m = class_getClassMethod(cls, sel);
    if (!m) return nil;
    id (*f)(id,SEL,const char*) = (void*)method_getImplementation(m);
    return f ? f((id)cls, sel, text) : nil;
}

static const char* Ban_GetCStr(id str) {
    if (!str) return "";
    SEL sel = sel_registerName("UTF8String");
    Method m = class_getInstanceMethod(object_getClass(str), sel);
    if (!m) return "";
    const char* (*f)(id, SEL) = (void*)method_getImplementation(m);
    return f ? f(str, sel) : "";
}

static void Ban_SendMsg(id server, const char* msg) {
    if (server && Real_Ban_SendChat) {
        Real_Ban_SendChat(server, sel_registerName("sendChatMessage:sendToClients:"), Ban_AllocStr(msg), nil);
    }
}

id Hook_Ban_ClientDrop(id self, SEL _cmd, id data) {
    if (g_ClearDrops_Active) return nil;
    if (Real_Ban_ClientDrop) return Real_Ban_ClientDrop(self, _cmd, data);
    return nil;
}

id Hook_Ban_Cmd(id self, SEL _cmd, id cmdStr, id client) {
    const char* raw = Ban_GetCStr(cmdStr);
    
    if (raw && strncmp(raw, "/clear_drops", 12) == 0) {
        g_ClearDrops_Active = !g_ClearDrops_Active;
        char msg[128];
        snprintf(msg, 128, "[System] Clear Drops: %s", g_ClearDrops_Active ? "ON" : "OFF");
        Ban_SendMsg(self, msg);
        return nil;
    }

    if (Real_Ban_HandleCmd) return Real_Ban_HandleCmd(self, _cmd, cmdStr, client);
    return nil;
}

static void* BanDrops_InitThread(void* arg) {
    sleep(3);
    
    Class clsSrv = objc_getClass(BAN_SERVER_CLASS);
    Class clsDW = objc_getClass(BAN_DYN_WORLD);

    if (clsSrv) {
        Method mCmd = class_getInstanceMethod(clsSrv, sel_registerName("handleCommand:issueClient:"));
        if (mCmd) {
            Real_Ban_HandleCmd = (Ban_CmdFunc)method_getImplementation(mCmd);
            method_setImplementation(mCmd, (IMP)Hook_Ban_Cmd);
        }
        
        Method mChat = class_getInstanceMethod(clsSrv, sel_registerName("sendChatMessage:sendToClients:"));
        if (mChat) {
            Real_Ban_SendChat = (Ban_ChatFunc)method_getImplementation(mChat);
        }
    }

    if (clsDW) {
        SEL sDrop = sel_registerName("createClientFreeblocksWithData:");
        Method mDrop = class_getInstanceMethod(clsDW, sDrop);
        if (mDrop) {
            Real_Ban_ClientDrop = (Ban_DropFunc)method_getImplementation(mDrop);
            method_setImplementation(mDrop, (IMP)Hook_Ban_ClientDrop);
        }
    }
    return NULL;
}

__attribute__((constructor)) static void BanDrops_Entry() {
    pthread_t t; 
    pthread_create(&t, NULL, BanDrops_InitThread, NULL);
}
