/*
 * Ban All New Drops
 * ------------------------
 * Description: Prevents new FreeBlocks from dropping into the world.
 * Commands: /ban_drops
 * Note: Uses BHServer chat signature.
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

// --- CONFIG ---
#define CD_SERVER_CLASS "BHServer"
#define CD_DYN_WORLD    "DynamicWorld"

// --- GLOBALS ---
static bool g_CD_Active = false;

// --- TYPES ---
typedef id (*CD_CmdFunc)(id, SEL, id, id);
// Signature validated against BHServer.h
typedef void (*CD_ChatFunc)(id, SEL, id, BOOL, id); 
typedef id (*CD_DropFunc)(id, SEL, id);

static CD_CmdFunc  Real_CD_HandleCmd = NULL;
static CD_ChatFunc Real_CD_SendChat = NULL;
static CD_DropFunc Real_CD_ClientDrop = NULL;

// --- HELPERS ---
static id CD_AllocStr(const char* text) {
    if (!text) return nil;
    Class cls = objc_getClass("NSString");
    SEL sel = sel_registerName("stringWithUTF8String:");
    id (*f)(id,SEL,const char*) = (void*)method_getImplementation(class_getClassMethod(cls, sel));
    return f ? f((id)cls, sel, text) : nil;
}

static const char* CD_GetCStr(id str) {
    if (!str) return "";
    SEL sel = sel_registerName("UTF8String");
    const char* (*f)(id, SEL) = (void*)method_getImplementation(class_getInstanceMethod(object_getClass(str), sel));
    return f ? f(str, sel) : "";
}

static void CD_SendMsg(id server, const char* msg) {
    if (server && Real_CD_SendChat) {
        // Correct signature: Msg(id), DisplayNotification(BOOL), SendToClients(NSArray*)
        Real_CD_SendChat(server, 
                         sel_registerName("sendChatMessage:displayNotification:sendToClients:"), 
                         CD_AllocStr(msg), 
                         true, 
                         nil);
    }
}

// --- HOOKS ---

id Hook_CD_ClientDrop(id self, SEL _cmd, id data) {
    if (g_CD_Active) return nil; // Return nil to prevent drop creation
    if (Real_CD_ClientDrop) return Real_CD_ClientDrop(self, _cmd, data);
    return nil;
}

id Hook_CD_Cmd(id self, SEL _cmd, id cmdStr, id client) {
    const char* raw = CD_GetCStr(cmdStr);
    
    if (raw && strncmp(raw, "/ban_drops", 12) == 0) {
        g_CD_Active = !g_CD_Active;
        char msg[128];
        snprintf(msg, 128, "[System] Drop Cleaner: %s", g_CD_Active ? "ON (Drops Disabled)" : "OFF (Drops Enabled)");
        CD_SendMsg(self, msg);
        return nil;
    }

    if (Real_CD_HandleCmd) return Real_CD_HandleCmd(self, _cmd, cmdStr, client);
    return nil;
}

// --- INIT ---
static void* CD_InitThread(void* arg) {
    sleep(1);
    
    Class clsSrv = objc_getClass(CD_SERVER_CLASS);
    Class clsDW = objc_getClass(CD_DYN_WORLD);

    if (clsSrv) {
        Method mCmd = class_getInstanceMethod(clsSrv, sel_registerName("handleCommand:issueClient:"));
        if (mCmd) {
            Real_CD_HandleCmd = (CD_CmdFunc)method_getImplementation(mCmd);
            method_setImplementation(mCmd, (IMP)Hook_CD_Cmd);
        }
        
        Method mChat = class_getInstanceMethod(clsSrv, sel_registerName("sendChatMessage:displayNotification:sendToClients:"));
        if (mChat) {
            Real_CD_SendChat = (CD_ChatFunc)method_getImplementation(mChat);
        }
    }

    if (clsDW) {
        SEL sDrop = sel_registerName("createClientFreeblocksWithData:");
        Method mDrop = class_getInstanceMethod(clsDW, sDrop);
        if (mDrop) {
            Real_CD_ClientDrop = (CD_DropFunc)method_getImplementation(mDrop);
            method_setImplementation(mDrop, (IMP)Hook_CD_ClientDrop);
        }
    }
    return NULL;
}

__attribute__((constructor)) static void CD_Entry() {
    pthread_t t; 
    pthread_create(&t, NULL, CD_InitThread, NULL);
}
