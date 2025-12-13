/*
 * UNIFIED COMMAND & UTILITY LAYER
 * Ensures 100% compatibility for all command-based patches.
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

#define UNIFIED_SERVER_CLASS "BHServer"

// --- Types ---
typedef id (*Unified_CmdFunc)(id, SEL, id, id);
typedef void (*Unified_ChatFunc)(id, SEL, id, id);
typedef const char* (*Unified_StrFunc)(id, SEL);
typedef id (*Unified_StringFactoryFunc)(id, SEL, const char*);

// --- Globals ---
Unified_CmdFunc Real_Unified_HandleCmd = NULL;
Unified_ChatFunc Real_Unified_SendChat = NULL;

// --- External Handlers ---
extern id BanDrops_Hook_Cmd_Handler(id self, SEL _cmd, const char* raw);
extern id Dupe_Hook_Cmd_Handler(id self, SEL _cmd, const char* raw, id client);
extern id Summon_Hook_Cmd_Handler(id self, SEL _cmd, const char* raw, id client);
extern id Pause_Hook_Cmd_Handler(id self, SEL _cmd, const char* raw, id cmdStr, id client);

// -------------------------------------------------------------------------
// --- UNIFIED UTILITIES ---
// -------------------------------------------------------------------------

const char* Unified_GetCStr(id str) {
    if (!str) return "";
    SEL sel = sel_registerName("UTF8String");
    Method m = class_getInstanceMethod(object_getClass(str), sel);
    if (!m) return "";
    Unified_StrFunc f = (Unified_StrFunc)method_getImplementation(m);
    return f ? f(str, sel) : "";
}

id Unified_AllocStr(const char* text) {
    if (!text) return nil;
    Class cls = objc_getClass("NSString");
    SEL sel = sel_registerName("stringWithUTF8String:");
    Method m = class_getClassMethod(cls, sel);
    if (!m) return nil;
    Unified_StringFactoryFunc f = (Unified_StringFactoryFunc)method_getImplementation(m);
    return f ? f((id)cls, sel, text) : nil;
}

// Global safe chat function for all scripts
void Unified_SendMsg(id server, const char* msg) {
    if (server && Real_Unified_SendChat) {
        Real_Unified_SendChat(server, sel_registerName("sendChatMessage:sendToClients:"), Unified_AllocStr(msg), nil);
    }
}

// -------------------------------------------------------------------------
// --- UNIFIED COMMAND HOOK ---
// -------------------------------------------------------------------------

id Unified_Hook_Cmd(id self, SEL _cmd, id cmdStr, id client) {
    const char* raw = Unified_GetCStr(cmdStr);
    id result = nil;

    // Chain execution
    result = Pause_Hook_Cmd_Handler(self, _cmd, raw, cmdStr, client);
    if (result == nil) return nil; 

    result = BanDrops_Hook_Cmd_Handler(self, _cmd, raw);
    if (result == nil) return nil; 

    result = Dupe_Hook_Cmd_Handler(self, _cmd, raw, client);
    if (result == nil) return nil; 
    
    result = Summon_Hook_Cmd_Handler(self, _cmd, raw, client);
    if (result == nil) return nil; 

    if (Real_Unified_HandleCmd) return Real_Unified_HandleCmd(self, _cmd, cmdStr, client);
    return nil;
}

static void* Unified_InitThread(void* arg) {
    int checks = 0;
    while (!objc_getClass(UNIFIED_SERVER_CLASS)) {
        usleep(1000); 
        checks++;
        if (checks > 15000) return NULL; 
    }

    Class clsSrv = objc_getClass(UNIFIED_SERVER_CLASS);

    Method mCmd = class_getInstanceMethod(clsSrv, sel_registerName("handleCommand:issueClient:"));
    if (mCmd) {
        Real_Unified_HandleCmd = (Unified_CmdFunc)method_getImplementation(mCmd);
        method_setImplementation(mCmd, (IMP)Unified_Hook_Cmd);
    }

    Method mChat = class_getInstanceMethod(clsSrv, sel_registerName("sendChatMessage:sendToClients:"));
    if (mChat) {
        Real_Unified_SendChat = (Unified_ChatFunc)method_getImplementation(mChat);
    }
    
    return NULL;
}

__attribute__((constructor)) static void Unified_Entry() {
    pthread_t t; pthread_create(&t, NULL, Unified_InitThread, NULL);
}
