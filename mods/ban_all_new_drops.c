/*
 * Name: patch_clear_drops.c
 * Description: Prevents new items from dropping/spawning in the world.
 * Commands: /ban_drops (Toggle ON/OFF)
 * Author: Fixes by Assistant
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

#define CLR_SERVER_CLASS "BHServer"
#define CLR_DYN_WORLD    "DynamicWorld"

// --- Typedefs for IMP Casting ---
typedef id (*Clr_CmdFunc)(id, SEL, id, id);
typedef void (*Clr_ChatFunc)(id, SEL, id, id);
typedef id (*Clr_DropFunc)(id, SEL, id);
typedef id (*Clr_StrFunc)(id, SEL, const char*);
typedef const char* (*Clr_Utf8Func)(id, SEL);

// --- Globals ---
static bool g_ClearDrops_Active = false;
static Clr_CmdFunc  Real_Clr_HandleCmd = NULL;
static Clr_ChatFunc Real_Clr_SendChat = NULL;
static Clr_DropFunc Real_Clr_ClientDrop = NULL;

// --- Helpers ---
static id Clr_AllocStr(const char* text) {
    if (!text) return nil;
    Class cls = objc_getClass("NSString");
    SEL sel = sel_registerName("stringWithUTF8String:");
    Method m = class_getClassMethod(cls, sel);
    if (!m) return nil;
    Clr_StrFunc f = (Clr_StrFunc)method_getImplementation(m);
    return f ? f((id)cls, sel, text) : nil;
}

static const char* Clr_GetCStr(id str) {
    if (!str) return "";
    SEL sel = sel_registerName("UTF8String");
    Method m = class_getInstanceMethod(object_getClass(str), sel);
    if (!m) return "";
    Clr_Utf8Func f = (Clr_Utf8Func)method_getImplementation(m);
    return f ? f(str, sel) : "";
}

static void Clr_SendMsg(id server, const char* msg) {
    if (server && Real_Clr_SendChat) {
        Real_Clr_SendChat(server, sel_registerName("sendChatMessage:sendToClients:"), Clr_AllocStr(msg), nil);
    }
}

// --- Hooks ---
id Hook_Clr_ClientDrop(id self, SEL _cmd, id data) {
    // If active, suppress the drop creation
    if (g_ClearDrops_Active) return nil;
    
    if (Real_Clr_ClientDrop) return Real_Clr_ClientDrop(self, _cmd, data);
    return nil;
}

id Hook_Clr_Cmd(id self, SEL _cmd, id cmdStr, id client) {
    const char* raw = Clr_GetCStr(cmdStr);
    
    if (raw && strncasecmp(raw, "/ban_drops", 12) == 0) {
        g_ClearDrops_Active = !g_ClearDrops_Active;
        char msg[128];
        snprintf(msg, sizeof(msg), "[System] Drop Ban: %s", g_ClearDrops_Active ? "ENABLED (Drops blocked)" : "DISABLED");
        Clr_SendMsg(self, msg);
        return nil;
    }

    if (Real_Clr_HandleCmd) return Real_Clr_HandleCmd(self, _cmd, cmdStr, client);
    return nil;
}

// --- Init ---
static void* ClrDrops_InitThread(void* arg) {
    sleep(3);
    
    Class clsSrv = objc_getClass(CLR_SERVER_CLASS);
    Class clsDW = objc_getClass(CLR_DYN_WORLD);

    if (clsSrv) {
        Method mCmd = class_getInstanceMethod(clsSrv, sel_registerName("handleCommand:issueClient:"));
        if (mCmd) {
            Real_Clr_HandleCmd = (Clr_CmdFunc)method_getImplementation(mCmd);
            method_setImplementation(mCmd, (IMP)Hook_Clr_Cmd);
        }
        
        Method mChat = class_getInstanceMethod(clsSrv, sel_registerName("sendChatMessage:sendToClients:"));
        if (mChat) {
            Real_Clr_SendChat = (Clr_ChatFunc)method_getImplementation(mChat);
        }
    }

    if (clsDW) {
        SEL sDrop = sel_registerName("createClientFreeblocksWithData:");
        Method mDrop = class_getInstanceMethod(clsDW, sDrop);
        if (mDrop) {
            Real_Clr_ClientDrop = (Clr_DropFunc)method_getImplementation(mDrop);
            method_setImplementation(mDrop, (IMP)Hook_Clr_ClientDrop);
        }
    }
    return NULL;
}

__attribute__((constructor)) static void ClrDrops_Entry() {
    pthread_t t; 
    pthread_create(&t, NULL, ClrDrops_InitThread, NULL);
}
