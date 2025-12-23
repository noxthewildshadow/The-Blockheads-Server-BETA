/*
 * Script: Clear Drops
 * Command: /ban_drops
 * Description: Prevents items from dropping on the ground to reduce lag.
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <objc/runtime.h>
#include <objc/message.h>

#define BAN_SERVER_CLASS "BHServer"
#define BAN_DYN_WORLD    "DynamicWorld"

// --- GLOBALS (Static for isolation) ---
static bool g_ClearDrops_Active = false;
static id (*Ban_Real_HandleCmd)(id, SEL, id, id) = NULL;
static void (*Ban_Real_SendChat)(id, SEL, id, id) = NULL;
static id (*Ban_Real_ClientDrop)(id, SEL, id) = NULL;

// --- HELPERS ---
static id Ban_AllocStr(const char* text) {
    if (!text) return nil;
    Class cls = objc_getClass("NSString");
    SEL sel = sel_registerName("stringWithUTF8String:");
    id (*f)(id, SEL, const char*) = (void*)method_getImplementation(class_getClassMethod(cls, sel));
    return f ? f((id)cls, sel, text) : nil;
}

static const char* Ban_GetCStr(id str) {
    if (!str) return "";
    SEL sel = sel_registerName("UTF8String");
    const char* (*f)(id, SEL) = (void*)class_getMethodImplementation(object_getClass(str), sel);
    return f ? f(str, sel) : "";
}

static void Ban_SendMsg(id server, const char* msg) {
    if (server && Ban_Real_SendChat) {
        Ban_Real_SendChat(server, sel_registerName("sendChatMessage:sendToClients:"), Ban_AllocStr(msg), nil);
    }
}

// --- HOOKS ---
static id Hook_Ban_ClientDrop(id self, SEL _cmd, id data) {
    if (g_ClearDrops_Active) return nil; // Block the drop
    if (Ban_Real_ClientDrop) return Ban_Real_ClientDrop(self, _cmd, data);
    return nil;
}

static id Hook_Ban_Cmd(id self, SEL _cmd, id cmdStr, id client) {
    const char* raw = Ban_GetCStr(cmdStr);
    
    if (raw && strncmp(raw, "/ban_drops", 12) == 0) {
        g_ClearDrops_Active = !g_ClearDrops_Active;
        char msg[128];
        snprintf(msg, 128, "[System] Clear Drops: %s", g_ClearDrops_Active ? "ON" : "OFF");
        Ban_SendMsg(self, msg);
        return nil;
    }

    if (Ban_Real_HandleCmd) return Ban_Real_HandleCmd(self, _cmd, cmdStr, client);
    return nil;
}

// --- INIT ---
static void* BanDrops_InitThread(void* arg) {
    sleep(1);
    Class clsSrv = objc_getClass(BAN_SERVER_CLASS);
    Class clsDW = objc_getClass(BAN_DYN_WORLD);

    if (clsSrv) {
        Method mCmd = class_getInstanceMethod(clsSrv, sel_registerName("handleCommand:issueClient:"));
        if (mCmd) {
            Ban_Real_HandleCmd = (void*)method_getImplementation(mCmd);
            method_setImplementation(mCmd, (IMP)Hook_Ban_Cmd);
        }
        Method mChat = class_getInstanceMethod(clsSrv, sel_registerName("sendChatMessage:sendToClients:"));
        if (mChat) Ban_Real_SendChat = (void*)method_getImplementation(mChat);
    }

    if (clsDW) {
        SEL sDrop = sel_registerName("createClientFreeblocksWithData:");
        Method mDrop = class_getInstanceMethod(clsDW, sDrop);
        if (mDrop) {
            Ban_Real_ClientDrop = (void*)method_getImplementation(mDrop);
            method_setImplementation(mDrop, (IMP)Hook_Ban_ClientDrop);
        }
    }
    return NULL;
}

__attribute__((constructor)) static void BanDrops_Entry() {
    pthread_t t; pthread_create(&t, NULL, BanDrops_InitThread, NULL);
}
