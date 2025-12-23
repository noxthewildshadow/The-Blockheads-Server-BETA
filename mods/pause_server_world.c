/*
 * Server Pause World
 * Commands: /pause [mode 1|2]
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
#include <time.h>

#define PAUSE_SERVER_CLASS "BHServer"
#define PAUSE_DYN_WORLD    "DynamicWorld"

static bool g_IsPaused = false;
static int  g_PauseMode = 1;
static time_t g_DramaEndTime = 0;

typedef id (*Pause_CmdFunc)(id, SEL, id, id);
typedef void (*Pause_ChatFunc)(id, SEL, id, id);
typedef void (*Pause_UpdateFunc)(id, SEL, double, bool);

static Pause_CmdFunc    Real_Pause_Cmd = NULL;
static Pause_ChatFunc   Real_Pause_Chat = NULL;
static Pause_UpdateFunc Real_Pause_Update = NULL;

static id Pause_AllocStr(const char* text) {
    if (!text) return nil;
    Class cls = objc_getClass("NSString");
    SEL sel = sel_registerName("stringWithUTF8String:");
    Method m = class_getClassMethod(cls, sel);
    if (!m) return nil;
    id (*f)(id,SEL,const char*) = (void*)method_getImplementation(m);
    return f ? f((id)cls, sel, text) : nil;
}

static const char* Pause_GetCStr(id str) {
    if (!str) return "";
    SEL sel = sel_registerName("UTF8String");
    Method m = class_getInstanceMethod(object_getClass(str), sel);
    if (!m) return "";
    const char* (*f)(id, SEL) = (void*)method_getImplementation(m);
    return f ? f(str, sel) : "";
}

static void Pause_SendMsg(id server, const char* msg) {
    if (server && Real_Pause_Chat) {
        Real_Pause_Chat(server, sel_registerName("sendChatMessage:sendToClients:"), Pause_AllocStr(msg), nil);
    }
}

void Hook_Pause_Update(id self, SEL _cmd, double dt, bool isSim) {
    if (g_IsPaused) return;

    if (g_PauseMode == 2 && time(NULL) < g_DramaEndTime) {
        dt = 0.0;
    }

    if (Real_Pause_Update) Real_Pause_Update(self, _cmd, dt, isSim);
}

id Hook_Pause_Cmd(id self, SEL _cmd, id cmdStr, id client) {
    const char* raw = Pause_GetCStr(cmdStr);
    
    if (raw) {
        bool toggle = false;
        
        if (strcmp(raw, "/pause") == 0 || strcmp(raw, "/pause ") == 0) {
            toggle = true;
        }
        else if (strncmp(raw, "/pause mode 1", 13) == 0) {
            g_PauseMode = 1;
            toggle = true;
        }
        else if (strncmp(raw, "/pause mode 2", 13) == 0) {
            g_PauseMode = 2;
            toggle = true;
        }

        if (toggle) {
            g_IsPaused = !g_IsPaused;
            
            if (!g_IsPaused && g_PauseMode == 2) {
                g_DramaEndTime = time(NULL) + 60;
            }

            char msg[128];
            char *desc = (g_PauseMode == 1) ? "BURST" : "DRAMA";
            snprintf(msg, 128, "[System] Pause: %s [%s]", g_IsPaused ? "ON" : "OFF", desc);
            Pause_SendMsg(self, msg);
            
            return nil;
        }
    }
    
    if (Real_Pause_Cmd) return Real_Pause_Cmd(self, _cmd, cmdStr, client);
    return nil;
}

static void* Pause_InitThread(void* arg) {
    sleep(3);
    Class clsSrv = objc_getClass(PAUSE_SERVER_CLASS);
    Class clsDyn = objc_getClass(PAUSE_DYN_WORLD);

    if (clsSrv) {
        Method mCmd = class_getInstanceMethod(clsSrv, sel_registerName("handleCommand:issueClient:"));
        if (mCmd) {
            Real_Pause_Cmd = (Pause_CmdFunc)method_getImplementation(mCmd);
            method_setImplementation(mCmd, (IMP)Hook_Pause_Cmd);
        }
        Method mChat = class_getInstanceMethod(clsSrv, sel_registerName("sendChatMessage:sendToClients:"));
        if (mChat) Real_Pause_Chat = (Pause_ChatFunc)method_getImplementation(mChat);
    }

    if (clsDyn) {
        Method mUp = class_getInstanceMethod(clsDyn, sel_registerName("update:accurateDT:isSimulation:"));
        if (mUp) {
            Real_Pause_Update = (Pause_UpdateFunc)method_getImplementation(mUp);
            method_setImplementation(mUp, (IMP)Hook_Pause_Update);
        }
    }
    
    return NULL;
}

__attribute__((constructor)) static void Pause_Entry() {
    pthread_t t; 
    pthread_create(&t, NULL, Pause_InitThread, NULL);
}
