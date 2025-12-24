#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <ctype.h>
#include <objc/runtime.h>
#include <objc/message.h>

// --- CONFIG ---
#define OMNI_SERVER_CLASS "BHServer"
#define OMNI_WORLD_CLASS  "World"

// --- IMP TYPES ---
typedef void (*OMNI_FillFunc)(id, SEL, void*, long long, int, uint16_t, uint16_t, id, id, id, id);
typedef id (*OMNI_CmdFunc)(id, SEL, id, id);
typedef void (*OMNI_ChatFunc)(id, SEL, id, BOOL, id);

typedef id (*OMNI_AllocFunc)(id, SEL);
typedef id (*OMNI_InitFunc)(id, SEL);
typedef void (*OMNI_VoidFunc)(id, SEL);
typedef id (*OMNI_StrFunc)(id, SEL, const char*);
typedef const char* (*OMNI_Utf8Func)(id, SEL);

// --- GLOBALS ---
static OMNI_FillFunc Real_OMNI_Fill = NULL;
static OMNI_CmdFunc  Real_OMNI_Cmd = NULL;
static OMNI_ChatFunc Real_OMNI_Chat = NULL;

static int  g_OMNI_Mode = 0; 
static int  g_OMNI_TargetID = 0;
static bool g_OMNI_IsContent = false;

// --- UTILS ---
static id OMNI_Pool() {
    Class cls = objc_getClass("NSAutoreleasePool");
    SEL sA = sel_registerName("alloc");
    SEL sI = sel_registerName("init");
    OMNI_AllocFunc fA = (OMNI_AllocFunc)method_getImplementation(class_getClassMethod(cls, sA));
    OMNI_InitFunc fI = (OMNI_InitFunc)method_getImplementation(class_getInstanceMethod(cls, sI));
    return fI(fA((id)cls, sA), sI);
}

static void OMNI_Drain(id pool) {
    if (!pool) return;
    SEL s = sel_registerName("drain");
    OMNI_VoidFunc f = (OMNI_VoidFunc)method_getImplementation(class_getInstanceMethod(object_getClass(pool), s));
    f(pool, s);
}

static id OMNI_Str(const char* txt) {
    if (!txt) return nil;
    Class cls = objc_getClass("NSString");
    SEL s = sel_registerName("stringWithUTF8String:");
    OMNI_StrFunc f = (OMNI_StrFunc)method_getImplementation(class_getClassMethod(cls, s));
    return f ? f((id)cls, s, txt) : nil;
}

static const char* OMNI_CStr(id str) {
    if (!str) return "";
    SEL s = sel_registerName("UTF8String");
    OMNI_Utf8Func f = (OMNI_Utf8Func)method_getImplementation(class_getInstanceMethod(object_getClass(str), s));
    return f ? f(str, s) : "";
}

static void OMNI_Msg(id server, const char* msg) {
    if (server && Real_OMNI_Chat) {
        Real_OMNI_Chat(server, sel_registerName("sendChatMessage:displayNotification:sendToClients:"), OMNI_Str(msg), true, nil);
    }
}

// --- ID PARSER (CORRECTED PRIORITY) ---
int OMNI_ParseID(const char* v, bool* isContent) {
    if (!v) return 0;
    *isContent = false;
    
    // Numeric direct override
    if (isdigit(v[0])) return atoi(v);
    
    // --- ORES / CONTENTS (Priority for common names) ---
    // User wants "iron" to be ore, not block.
    
    if (strcasecmp(v, "flint")==0) { *isContent=true; return 1; }
    if (strcasecmp(v, "clay")==0) { *isContent=true; return 2; }
    if (strcasecmp(v, "oil")==0) { *isContent=true; return 64; }
    if (strcasecmp(v, "coal")==0) { *isContent=true; return 65; }
    
    if (strcasecmp(v, "gold")==0 || strcasecmp(v, "gold_ore")==0) { *isContent=true; return 77; }
    if (strcasecmp(v, "copper")==0 || strcasecmp(v, "copper_ore")==0) { *isContent=true; return 61; }
    if (strcasecmp(v, "tin")==0 || strcasecmp(v, "tin_ore")==0) { *isContent=true; return 62; }
    if (strcasecmp(v, "iron")==0 || strcasecmp(v, "iron_ore")==0) { *isContent=true; return 63; }
    if (strcasecmp(v, "titanium")==0 || strcasecmp(v, "titanium_ore")==0) { *isContent=true; return 107; }
    if (strcasecmp(v, "platinum")==0 || strcasecmp(v, "platinum_ore")==0) { *isContent=true; return 106; }
    
    if (strcasecmp(v, "emerald")==0) { *isContent=true; return 73; }
    if (strcasecmp(v, "ruby")==0) { *isContent=true; return 74; }
    if (strcasecmp(v, "diamond")==0) { *isContent=true; return 75; }
    if (strcasecmp(v, "sapphire")==0) { *isContent=true; return 72; }
    if (strcasecmp(v, "amethyst")==0) { *isContent=true; return 71; }

    // --- BLOCKS (Explicit names for solids) ---
    if (strcasecmp(v, "stone")==0) return 1;
    if (strcasecmp(v, "dirt")==0) return 6;
    if (strcasecmp(v, "sand")==0) return 7;
    if (strcasecmp(v, "wood")==0) return 9;
    if (strcasecmp(v, "brick")==0) return 11;
    if (strcasecmp(v, "limestone")==0) return 12;
    if (strcasecmp(v, "marble")==0) return 14;
    if (strcasecmp(v, "tc")==0) return 16;
    if (strcasecmp(v, "sandstone")==0) return 17;
    if (strcasecmp(v, "red_marble")==0) return 19;
    if (strcasecmp(v, "glass")==0) return 24;
    if (strcasecmp(v, "portal")==0) return 25; 
    
    if (strcasecmp(v, "gold_block")==0) return 26; 
    if (strcasecmp(v, "lapis")==0) return 29;
    if (strcasecmp(v, "lava")==0) return 31;
    if (strcasecmp(v, "platform")==0) return 32;
    if (strcasecmp(v, "compost")==0) return 48;
    if (strcasecmp(v, "basalt")==0) return 51;
    
    if (strcasecmp(v, "copper_block")==0) return 53;
    if (strcasecmp(v, "tin_block")==0) return 54;
    if (strcasecmp(v, "bronze_block")==0) return 55;
    if (strcasecmp(v, "iron_block")==0) return 56;
    if (strcasecmp(v, "steel_block")==0) return 57; // or "steel"
    if (strcasecmp(v, "steel")==0) return 57;
    
    if (strcasecmp(v, "black_glass")==0) return 59;
    if (strcasecmp(v, "trade_portal")==0) return 60;
    if (strcasecmp(v, "leaves")==0) return 66;
    
    if (strcasecmp(v, "platinum_block")==0) return 67;
    if (strcasecmp(v, "titanium_block")==0) return 68;
    
    if (strcasecmp(v, "carbon")==0) return 69;
    if (strcasecmp(v, "gravel")==0) return 70;
    if (strcasecmp(v, "plaster")==0) return 76;
    if (strcasecmp(v, "luminous")==0) return 77;
    if (strcasecmp(v, "ice")==0) return 4;
    if (strcasecmp(v, "snow")==0) return 5;
    
    return 0;
}

// --- HOOKS ---

void Hook_OMNI_Fill(id self, SEL _cmd, void* tile, long long pos, int type, uint16_t dA, uint16_t dB, id client, id saveDict, id bh, id name) {
    
    // Call Original
    if (Real_OMNI_Fill) {
        Real_OMNI_Fill(self, _cmd, tile, pos, type, dA, dB, client, saveDict, bh, name);
    }
    
    // Check Trigger (Stone ID 1 or 1024)
    if (tile && g_OMNI_Mode > 0 && (type == 1 || type == 1024)) {
        
        uint8_t* bytes = (uint8_t*)tile;
        
        // Mode 1: PLACE
        if (g_OMNI_Mode == 1) {
            if (g_OMNI_IsContent) {
                // --- ORE/CONTENT LOGIC ---
                // We MUST set the correct base block for the content to exist validly.
                
                // Flint (1) or Clay (2) -> Requires DIRT (6)
                if (g_OMNI_TargetID == 1 || g_OMNI_TargetID == 2) {
                    bytes[0] = 6; // Set Foreground to Dirt
                }
                // Oil (64) -> Requires LIMESTONE (12)
                else if (g_OMNI_TargetID == 64) {
                    bytes[0] = 12; // Set Foreground to Limestone
                }
                // Standard Ores/Gems -> Remain STONE (1)
                else {
                    bytes[0] = 1; // Default Stone
                }
                
                // Set the Content (Offset 3)
                bytes[3] = (uint8_t)g_OMNI_TargetID; 
                
            } else {
                // --- SOLID BLOCK LOGIC ---
                bytes[0] = (uint8_t)g_OMNI_TargetID; // Set FG
                bytes[3] = 0; // Remove existing content (e.g. if we replace a block that had something)
            }
        }
        
        // Mode 2: WALL
        if (g_OMNI_Mode == 2) {
            bytes[1] = (uint8_t)g_OMNI_TargetID; // Set BG
        }
    }
}

id Hook_OMNI_Cmd(id self, SEL _cmd, id cmdStr, id client) {
    const char* raw = OMNI_CStr(cmdStr);
    if (!raw) return Real_OMNI_Cmd(self, _cmd, cmdStr, client);
    
    id pool = OMNI_Pool();
    char buf[256]; strncpy(buf, raw, 255);
    char* cmd = strtok(buf, " ");
    char* arg = strtok(NULL, " ");
    
    // --- /PLACE ---
    if (strcasecmp(cmd, "/place") == 0) {
        if (!arg) {
            if (g_OMNI_Mode == 1) {
                g_OMNI_Mode = 0;
                OMNI_Msg(self, "[Omni] Place Mode OFF.");
            } else {
                OMNI_Msg(self, "[Usage] /place <ID/Name>");
            }
            OMNI_Drain(pool);
            return nil;
        }
        
        if (strcasecmp(arg, "off") == 0) {
            g_OMNI_Mode = 0;
            OMNI_Msg(self, "[Omni] Place Mode OFF.");
            OMNI_Drain(pool);
            return nil;
        }
        
        g_OMNI_TargetID = OMNI_ParseID(arg, &g_OMNI_IsContent);
        if (g_OMNI_TargetID > 0) {
            g_OMNI_Mode = 1; // Place Mode
            char msg[128];
            const char* typeStr = g_OMNI_IsContent ? "Content (Auto-Base)" : "Block";
            snprintf(msg, 128, "[Omni] Place: %s (ID %d) [%s].", arg, g_OMNI_TargetID, typeStr);
            OMNI_Msg(self, msg);
        } else {
            OMNI_Msg(self, "[Omni] Invalid Block Name/ID.");
        }
        
        OMNI_Drain(pool);
        return nil;
    }
    
    // --- /WALL ---
    if (strcasecmp(cmd, "/wall") == 0) {
        if (!arg) {
            if (g_OMNI_Mode == 2) {
                g_OMNI_Mode = 0;
                OMNI_Msg(self, "[Omni] Wall Mode OFF.");
            } else {
                OMNI_Msg(self, "[Usage] /wall <ID/Name>");
            }
            OMNI_Drain(pool);
            return nil;
        }
        
        if (strcasecmp(arg, "off") == 0) {
            g_OMNI_Mode = 0;
            OMNI_Msg(self, "[Omni] Wall Mode OFF.");
            OMNI_Drain(pool);
            return nil;
        }
        
        bool dummy;
        g_OMNI_TargetID = OMNI_ParseID(arg, &dummy);
        if (g_OMNI_TargetID > 0) {
            g_OMNI_Mode = 2; // Wall Mode
            char msg[128];
            snprintf(msg, 128, "[Omni] Wall: %s (ID %d).", arg, g_OMNI_TargetID);
            OMNI_Msg(self, msg);
        } else {
            OMNI_Msg(self, "[Omni] Invalid Block.");
        }
        OMNI_Drain(pool);
        return nil;
    }
    
    OMNI_Drain(pool);
    return Real_OMNI_Cmd(self, _cmd, cmdStr, client);
}

// --- INIT ---
static void* OMNI_Init(void* arg) {
    sleep(1);
    Class clsSrv = objc_getClass(OMNI_SERVER_CLASS);
    if (clsSrv) {
        Method mC = class_getInstanceMethod(clsSrv, sel_registerName("handleCommand:issueClient:"));
        Real_OMNI_Cmd = (OMNI_CmdFunc)method_getImplementation(mC);
        method_setImplementation(mC, (IMP)Hook_OMNI_Cmd);
        
        Method mT = class_getInstanceMethod(clsSrv, sel_registerName("sendChatMessage:displayNotification:sendToClients:"));
        Real_OMNI_Chat = (OMNI_ChatFunc)method_getImplementation(mT);
    }
    
    Class clsWorld = objc_getClass(OMNI_WORLD_CLASS);
    if (clsWorld) {
        SEL sFill = sel_registerName("fillTile:atPos:withType:dataA:dataB:placedByClient:saveDict:placedByBlockhead:placedByClientName:");
        Method mFill = class_getInstanceMethod(clsWorld, sFill);
        Real_OMNI_Fill = (OMNI_FillFunc)method_getImplementation(mFill);
        method_setImplementation(mFill, (IMP)Hook_OMNI_Fill);
    }
    return NULL;
}

__attribute__((constructor)) static void OMNI_Entry() {
    pthread_t t; pthread_create(&t, NULL, OMNI_Init, NULL);
}
