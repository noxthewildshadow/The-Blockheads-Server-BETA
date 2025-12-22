/*
 * Ban Drops System
 * Modifies: Removes dropped items automatically.
 * Command: /ban_drops
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
#define BAN_DYN_WORLD    "DynamicWorld"

static bool g_BanDrops_Active = false;

typedef id (*Ban_CmdFunc)(id, SEL, id, id);
typedef void (*Ban_ChatFunc)(id, SEL, id, id);
typedef id (*Ban_DropFunc)(id, SEL, id);

// Unique names to prevent conflicts
static Ban_CmdFunc  BanDrops_Real_HandleCmd = NULL;
static Ban_ChatFunc BanDrops_Real_SendChat = NULL;
static Ban_DropFunc BanDrops_Real_ClientDrop = NULL;

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
    if (server && BanDrops_Real_SendChat) {
        BanDrops_Real_SendChat(server, sel_registerName("sendChatMessage:sendToClients:"), Ban_AllocStr(msg), nil);
    }
}

id Hook_Ban_ClientDrop(id self, SEL _cmd, id data) {
    if (g_BanDrops_Active) return nil; // Block the drop
    if (BanDrops_Real_ClientDrop) return BanDrops_Real_ClientDrop(self, _cmd, data);
    return nil;
}

id Hook_Ban_Cmd(id self, SEL _cmd, id cmdStr, id client) {
    const char* raw = Ban_GetCStr(cmdStr);
    
    // Changed command to /ban_drops as requested
    if (raw && strncmp(raw, "/ban_drops", 10) == 0) {
        g_BanDrops_Active = !g_BanDrops_Active;
        char msg[128];
        if (g_BanDrops_Active) {
            snprintf(msg, 128, ">> [Server] Drop Ban System: ENABLED (Items will vanish).");
        } else {
            snprintf(msg, 128, ">> [Server] Drop Ban System: DISABLED (Drops allowed).");
        }
        Ban_SendMsg(self, msg);
        return nil;
    }

    if (BanDrops_Real_HandleCmd) return BanDrops_Real_HandleCmd(self, _cmd, cmdStr, client);
    return nil;
}

static void* BanDrops_InitThread(void* arg) {
    sleep(3);
    
    Class clsSrv = objc_getClass(BAN_SERVER_CLASS);
    Class clsDW = objc_getClass(BAN_DYN_WORLD);

    if (clsSrv) {
        Method mCmd = class_getInstanceMethod(clsSrv, sel_registerName("handleCommand:issueClient:"));
        if (mCmd) {
            BanDrops_Real_HandleCmd = (Ban_CmdFunc)method_getImplementation(mCmd);
            method_setImplementation(mCmd, (IMP)Hook_Ban_Cmd);
        }
        
        Method mChat = class_getInstanceMethod(clsSrv, sel_registerName("sendChatMessage:sendToClients:"));
        if (mChat) {
            BanDrops_Real_SendChat = (Ban_ChatFunc)method_getImplementation(mChat);
        }
    }

    if (clsDW) {
        SEL sDrop = sel_registerName("createClientFreeblocksWithData:");
        Method mDrop = class_getInstanceMethod(clsDW, sDrop);
        if (mDrop) {
            BanDrops_Real_ClientDrop = (Ban_DropFunc)method_getImplementation(mDrop);
            method_setImplementation(mDrop, (IMP)Hook_Ban_ClientDrop);
        }
    }
    return NULL;
}

__attribute__((constructor)) static void BanDrops_Entry() {
    pthread_t t; 
    pthread_create(&t, NULL, BanDrops_InitThread, NULL);
}
