/*
 * Ban Drops / Clear Drops v2
 * Descripción: Evita que se generen items tirados en el suelo (anti-lag).
 * Comandos: /ban_drops
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

// --- Configuration ---
#define BD_SERVER_CLASS "BHServer"
#define BD_DYN_WORLD    "DynamicWorld"

static bool g_BanDrops_Active = false;

// --- Typedefs (IMPs) ---
typedef id   (*BD_CmdFunc)(id, SEL, id, id);
typedef void (*BD_ChatFunc)(id, SEL, id, id);
typedef id   (*BD_DropFunc)(id, SEL, id);
typedef id   (*BD_StrFunc)(id, SEL, const char*);
typedef const char* (*BD_Utf8Func)(id, SEL);

// --- Globals ---
static BD_CmdFunc  BD_Real_HandleCmd = NULL;
static BD_ChatFunc BD_Real_SendChat = NULL;
static BD_DropFunc BD_Real_ClientDrop = NULL;

// --- Helpers ---
static id BD_AllocStr(const char* text) {
    if (!text) return nil;
    Class cls = objc_getClass("NSString");
    SEL sel = sel_registerName("stringWithUTF8String:");
    Method m = class_getClassMethod(cls, sel);
    if (!m) return nil;
    BD_StrFunc f = (BD_StrFunc)method_getImplementation(m);
    return f ? f((id)cls, sel, text) : nil;
}

static const char* BD_GetCStr(id str) {
    if (!str) return "";
    SEL sel = sel_registerName("UTF8String");
    Method m = class_getInstanceMethod(object_getClass(str), sel);
    if (!m) return "";
    BD_Utf8Func f = (BD_Utf8Func)method_getImplementation(m);
    return f ? f(str, sel) : "";
}

static void BD_SendMsg(id server, const char* msg) {
    if (server && BD_Real_SendChat) {
        BD_Real_SendChat(server, sel_registerName("sendChatMessage:sendToClients:"), BD_AllocStr(msg), nil);
    }
}

// --- Hooks ---
id Hook_BD_ClientDrop(id self, SEL _cmd, id data) {
    if (g_BanDrops_Active) return nil; // Bloquea la creación del drop
    if (BD_Real_ClientDrop) return BD_Real_ClientDrop(self, _cmd, data);
    return nil;
}

id Hook_BD_Cmd(id self, SEL _cmd, id cmdStr, id client) {
    const char* raw = BD_GetCStr(cmdStr);
    
    // Copia segura para evitar crashes
    char buffer[256];
    if (raw) {
        strncpy(buffer, raw, 255);
        buffer[255] = 0;
        
        if (strncmp(buffer, "/ban_drops", 10) == 0) {
            g_BanDrops_Active = !g_BanDrops_Active;
            char msg[128];
            snprintf(msg, 128, "[System] Drop Ban: %s", g_BanDrops_Active ? "ENABLED (Items will vanish)" : "DISABLED");
            BD_SendMsg(self, msg);
            return nil; // Consume el comando
        }
    }

    if (BD_Real_HandleCmd) return BD_Real_HandleCmd(self, _cmd, cmdStr, client);
    return nil;
}

// --- Init ---
static void* BD_InitThread(void* arg) {
    sleep(1);
    
    Class clsSrv = objc_getClass(BD_SERVER_CLASS);
    Class clsDW = objc_getClass(BD_DYN_WORLD);

    if (clsSrv) {
        Method mCmd = class_getInstanceMethod(clsSrv, sel_registerName("handleCommand:issueClient:"));
        if (mCmd) {
            BD_Real_HandleCmd = (BD_CmdFunc)method_getImplementation(mCmd);
            method_setImplementation(mCmd, (IMP)Hook_BD_Cmd);
        }
        
        Method mChat = class_getInstanceMethod(clsSrv, sel_registerName("sendChatMessage:sendToClients:"));
        if (mChat) BD_Real_SendChat = (BD_ChatFunc)method_getImplementation(mChat);
    }

    if (clsDW) {
        SEL sDrop = sel_registerName("createClientFreeblocksWithData:");
        Method mDrop = class_getInstanceMethod(clsDW, sDrop);
        if (mDrop) {
            BD_Real_ClientDrop = (BD_DropFunc)method_getImplementation(mDrop);
            method_setImplementation(mDrop, (IMP)Hook_BD_ClientDrop);
        }
    }
    return NULL;
}

__attribute__((constructor)) static void BD_Entry() {
    pthread_t t; 
    pthread_create(&t, NULL, BD_InitThread, NULL);
}
