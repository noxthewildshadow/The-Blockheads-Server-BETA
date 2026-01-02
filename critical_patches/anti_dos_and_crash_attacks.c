/*
 * IronDome - The Ultimate Blockheads Server Defense System
 * Prevents: Plist Bombs, Segfaults, Type Confusion, XML Injection, and Zombie DoS Attacks.
 */

#define _GNU_SOURCE
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdint.h>
#include <sys/mman.h>
#include <errno.h>
#include <time.h>
#include <objc/runtime.h>
#include <objc/message.h>

// --- CONFIGURATION ---
#define IRON_PC_PLIST_CLASS "NSPropertyListSerialization"
#define IRON_PC_DICT_CLASS  "NSMutableDictionary" 
#define IRON_WORLD_CLASS    "World"

// Security Limits
#define IRON_MAX_PLIST_SIZE 2097152 // 2MB (Anti-Bomb)
#define IRON_MAX_SAFE_COORD 60000   // Map Bounds (Anti-Segfault)
#define IRON_IP_MAX_CONNS   2       // Max connections per sec per IP (Anti-DoS)
#define IRON_LOG_COOLDOWN   30      // Seconds between DoS warnings (Anti-Spam)

// ENet Hardcoded Addresses (Internal Linking Support)
#define IRON_ADDR_ENET_SERVICE    0x4dd270
#define IRON_ADDR_ENET_DISCONNECT 0x4db810
#define IRON_PAGE_SIZE 4096

// --- STRUCTURES ---
typedef struct {
   uint32_t host;
   uint16_t port;
} IronDome_ENetAddress;

typedef struct { 
   uint8_t dispatchList[16]; 
   void * host;              
   uint16_t outgoingPeerID;
   uint16_t incomingPeerID;
   uint32_t connectID;
   uint8_t outgoingSessionID;
   uint8_t incomingSessionID;
   uint8_t pad[2]; 
   IronDome_ENetAddress address; 
} IronDome_PartialENetPeer;

typedef struct {
   int type;
   void * peer;
   uint8_t channelID;
   uint32_t data;
   void * packet;
} IronDome_ENetEvent;

// --- IMP DEFINITIONS ---
typedef int (*IronDome_ENet_Service_IMP)(void *host, IronDome_ENetEvent *event, uint32_t timeout);
typedef void (*IronDome_ENet_Disc_IMP)(void *peer, uint32_t data);

typedef id (*IronDome_PC_Plist_IMP)(id, SEL, id, unsigned long, unsigned long*, id*);
typedef id (*IronDome_PC_Dict_IMP)(id, SEL);
typedef unsigned long (*IronDome_ID_Len_IMP)(id, SEL); 
typedef void (*IronDome_ID_Req_IMP)(id, SEL, unsigned int, id);
typedef void (*IronDome_ID_Sim_IMP)(id, SEL, int, id, id);
typedef const char* (*IronDome_ID_Utf8_IMP)(id, SEL);
typedef BOOL (*IronDome_ID_Kind_IMP)(id, SEL, Class);
typedef id (*IronDome_ID_Alloc_IMP)(id, SEL);
typedef id (*IronDome_ID_Init_IMP)(id, SEL, const char*);
typedef id (*IronDome_ID_Copy_IMP)(id, SEL);
typedef id (*IronDome_ID_ObjForKey_IMP)(id, SEL, id);
typedef void (*IronDome_ID_SetObj_IMP)(id, SEL, id, id);

// --- GLOBALS ---
static IronDome_PC_Plist_IMP     IronDome_Real_PlistWithData = NULL;
static IronDome_PC_Dict_IMP      IronDome_Real_EmptyMutableDict = NULL;
static IronDome_ID_Req_IMP       IronDome_Real_RequestForBlock = NULL;
static IronDome_ID_Sim_IMP       IronDome_Real_AddSimEvent = NULL;

static void* IronDome_TargetAddr = (void*)IRON_ADDR_ENET_SERVICE;
static uint8_t IronDome_OriginalBytes[16];
static bool IronDome_HookInstalled = false;

// --- IP TRACKER ---
typedef struct {
    uint32_t ip;
    time_t last_seen;
    time_t last_log;
    int count;
} IronDome_IPTrack;

#define IRON_IP_TRACK_SIZE 64
static IronDome_IPTrack IronDome_IP_History[IRON_IP_TRACK_SIZE];
static int IronDome_IP_Head = 0;

// --- HELPERS ---

static id IronDome_ID_Str(const char* str) {
    Class cls = objc_getClass("NSString");
    SEL sAlloc = sel_registerName("alloc");
    SEL sInit = sel_registerName("initWithUTF8String:");
    if (!cls) return nil;
    Method mAlloc = class_getClassMethod(cls, sAlloc);
    Method mInit = class_getInstanceMethod(cls, sInit);
    if (mAlloc && mInit) {
        IronDome_ID_Alloc_IMP fAlloc = (IronDome_ID_Alloc_IMP)method_getImplementation(mAlloc);
        IronDome_ID_Init_IMP fInit = (IronDome_ID_Init_IMP)method_getImplementation(mInit);
        return fInit(fAlloc((id)cls, sAlloc), sInit, str);
    }
    return nil;
}

static id IronDome_GetSafeEmptyMutableDict() {
    Class cls = objc_getClass(IRON_PC_DICT_CLASS);
    SEL s = sel_registerName("dictionary");
    if (!IronDome_Real_EmptyMutableDict) {
        Method m = class_getClassMethod(cls, s);
        IronDome_Real_EmptyMutableDict = (IronDome_PC_Dict_IMP)method_getImplementation(m);
    }
    return IronDome_Real_EmptyMutableDict((id)cls, s);
}

// --- IP FILTER LOGIC ---
static int IronDome_CheckIPStatus(uint32_t ip) {
    time_t now = time(NULL);
    
    for (int i=0; i<IRON_IP_TRACK_SIZE; i++) {
        if (IronDome_IP_History[i].ip == ip) {
            if (IronDome_IP_History[i].last_seen == now) {
                IronDome_IP_History[i].count++;
                if (IronDome_IP_History[i].count > IRON_IP_MAX_CONNS) {
                    if (now - IronDome_IP_History[i].last_log >= IRON_LOG_COOLDOWN) {
                        IronDome_IP_History[i].last_log = now;
                        return 2; // LOG (Alert)
                    }
                    return 1; // SILENT (Block)
                }
                return 0; // ALLOW
            } else {
                IronDome_IP_History[i].last_seen = now;
                IronDome_IP_History[i].count = 1;
                return 0;
            }
        }
    }
    
    // New IP entry
    IronDome_IP_History[IronDome_IP_Head].ip = ip;
    IronDome_IP_History[IronDome_IP_Head].last_seen = now;
    IronDome_IP_History[IronDome_IP_Head].last_log = 0;
    IronDome_IP_History[IronDome_IP_Head].count = 1;
    IronDome_IP_Head = (IronDome_IP_Head + 1) % IRON_IP_TRACK_SIZE;
    return 0;
}

// --- HOTPATCH LOGIC (Anti-Zombie) ---

int IronDome_My_Enet_Service(void *host, IronDome_ENetEvent *event, uint32_t timeout);

int IronDome_My_Enet_Service(void *host, IronDome_ENetEvent *event, uint32_t timeout) {
    // 1. Restore & Call Original
    memcpy(IronDome_TargetAddr, IronDome_OriginalBytes, 13);
    int result = ((IronDome_ENet_Service_IMP)IronDome_TargetAddr)(host, event, timeout);
    
    // 2. Re-Install Hook (JMP)
    uint8_t jump_code[13];
    jump_code[0] = 0x49; jump_code[1] = 0xBB;
    *(uintptr_t*)(&jump_code[2]) = (uintptr_t)IronDome_My_Enet_Service;
    jump_code[10] = 0x41; jump_code[11] = 0xFF; jump_code[12] = 0xE3;
    memcpy(IronDome_TargetAddr, jump_code, 13);

    // 3. Filter Connections
    if (result > 0 && event != NULL) {
        if (event->type == 1 && event->peer) { // CONNECT EVENT
            IronDome_PartialENetPeer *p = (IronDome_PartialENetPeer*)event->peer;
            uint32_t ip = p->address.host;
            
            int status = IronDome_CheckIPStatus(ip);
            
            if (status > 0) { // BLOCKED
                if (status == 2) {
                    unsigned char b[4];
                    b[0] = ip & 0xFF; b[1] = (ip >> 8) & 0xFF; b[2] = (ip >> 16) & 0xFF; b[3] = (ip >> 24) & 0xFF;
                    printf("[IronDome] DoS Attack: High volume from %d.%d.%d.%d. Blocking.\n", b[0], b[1], b[2], b[3]);
                }
                
                // Disconnect Peer Immediately
                IronDome_ENet_Disc_IMP disc = (IronDome_ENet_Disc_IMP)(uintptr_t)IRON_ADDR_ENET_DISCONNECT;
                if (disc) disc(event->peer, 0);
                
                // Drop Event (Hide from Game Logic)
                event->type = 0;
                event->peer = NULL;
                return 0;
            }
        }
    }
    return result;
}

static void IronDome_SetupHotpatch() {
    void *page_start = (void *)((uintptr_t)IronDome_TargetAddr & ~(IRON_PAGE_SIZE - 1));
    if (mprotect(page_start, IRON_PAGE_SIZE * 2, PROT_READ | PROT_WRITE | PROT_EXEC) != 0) {
        perror("[IronDome] Critical: mprotect failed");
        return;
    }
    
    memcpy(IronDome_OriginalBytes, IronDome_TargetAddr, 13);
    
    uint8_t jump_code[13];
    jump_code[0] = 0x49; jump_code[1] = 0xBB;
    *(uintptr_t*)(&jump_code[2]) = (uintptr_t)IronDome_My_Enet_Service;
    jump_code[10] = 0x41; jump_code[11] = 0xFF; jump_code[12] = 0xE3;
    
    memcpy(IronDome_TargetAddr, jump_code, 13);
    IronDome_HookInstalled = true;
}

// --- STANDARD HOOKS ---

static void IronDome_SanitizePacket(id dict) {
    if (!dict) return;
    SEL sObj = sel_registerName("objectForKey:");
    SEL sSet = sel_registerName("setObject:forKey:");
    SEL sKind = sel_registerName("isKindOfClass:");
    
    Method mObj = class_getInstanceMethod(object_getClass(dict), sObj);
    Method mSet = class_getInstanceMethod(object_getClass(dict), sSet);
    if (!mObj || !mSet) return;

    IronDome_ID_ObjForKey_IMP fGet = (IronDome_ID_ObjForKey_IMP)method_getImplementation(mObj);
    IronDome_ID_SetObj_IMP fSet = (IronDome_ID_SetObj_IMP)method_getImplementation(mSet);

    id kMsg = IronDome_ID_Str("message");
    id kAlias = IronDome_ID_Str("alias");
    Class strClass = objc_getClass("NSString");

    // Fix Type Confusion (Test 8)
    id msgVal = fGet(dict, sObj, kMsg);
    if (msgVal) {
        Method mKind = class_getInstanceMethod(object_getClass(msgVal), sKind);
        if (mKind) {
            IronDome_ID_Kind_IMP fKind = (IronDome_ID_Kind_IMP)method_getImplementation(mKind);
            if (!fKind(msgVal, sKind, strClass)) {
                printf("[IronDome] Security: Malformed 'message' sanitized.\n");
                fSet(dict, sSet, IronDome_ID_Str(""), kMsg);
            }
        }
    }
    
    // Fix XSS/Type (Test 11)
    id aliasVal = fGet(dict, sObj, kAlias);
    if (aliasVal) {
        Method mKind = class_getInstanceMethod(object_getClass(aliasVal), sKind);
        if (mKind) {
            IronDome_ID_Kind_IMP fKind = (IronDome_ID_Kind_IMP)method_getImplementation(mKind);
            if (!fKind(aliasVal, sKind, strClass)) {
                printf("[IronDome] Security: Malformed 'alias' sanitized.\n");
                fSet(dict, sSet, IronDome_ID_Str("Unknown"), kAlias);
            }
        }
    }
}

// Fix Runtime Crash (Test 9)
static void IronDome_Patch_GetBytesLength(id self, SEL _cmd, void *buffer, unsigned long length) {
    SEL sUtf8 = sel_registerName("UTF8String");
    Method mUtf8 = class_getInstanceMethod(object_getClass(self), sUtf8);
    if (mUtf8) {
        IronDome_ID_Utf8_IMP fUtf8 = (IronDome_ID_Utf8_IMP)method_getImplementation(mUtf8);
        const char *strData = fUtf8(self, sUtf8);
        if (strData && buffer) {
            size_t strLen = strlen(strData);
            size_t copyLen = (strLen < length) ? strLen : length;
            memcpy(buffer, strData, copyLen);
            if (copyLen < length) memset((char*)buffer + copyLen, 0, length - copyLen);
        }
    }
}

// Fix Plist Bombs / Corruption (Test 1, 3, 7)
static id IronDome_Hook_PlistWithData(id self, SEL _cmd, id data, unsigned long opt, unsigned long* fmt, id* err) {
    if (!data) return nil;
    SEL sLen = sel_registerName("length");
    Method mLen = class_getInstanceMethod(object_getClass(data), sLen);
    unsigned long len = 0;
    if (mLen) {
        IronDome_ID_Len_IMP fLen = (IronDome_ID_Len_IMP)method_getImplementation(mLen);
        len = fLen(data, sLen);
    }

    if (len > IRON_MAX_PLIST_SIZE) {
        printf("[IronDome] Security: Oversized packet dropped (%lu bytes).\n", len);
        return IronDome_GetSafeEmptyMutableDict();
    }

    id result = IronDome_Real_PlistWithData(self, _cmd, data, opt, fmt, err);

    if (result == nil) {
        printf("[IronDome] Security: Corrupt XML/Plist dropped.\n");
        return IronDome_GetSafeEmptyMutableDict();
    }
    
    SEL sMut = sel_registerName("mutableCopy");
    Method mMut = class_getInstanceMethod(object_getClass(result), sMut);
    if (mMut) {
        IronDome_ID_Copy_IMP fCopy = (IronDome_ID_Copy_IMP)method_getImplementation(mMut);
        id mutableResult = fCopy(result, sMut);
        IronDome_SanitizePacket(mutableResult);
        return mutableResult;
    }
    return result;
}

// Fix Map Segfaults (Test 2, 6, 14)
static void IronDome_Hook_RequestForBlock(id self, SEL _cmd, unsigned int macroIndex, id clientID) {
    if (macroIndex > IRON_MAX_SAFE_COORD) {
        // Silent drop to avoid log spam on massive fuzzing
        return; 
    }
    IronDome_Real_RequestForBlock(self, _cmd, macroIndex, clientID);
}

// Extra Event Safety (Layer for Test 9)
static void IronDome_Hook_AddSimEvent(id self, SEL _cmd, int type, id bh, id extraData) {
    if (extraData) {
        Class strClass = objc_getClass("NSString");
        SEL sKind = sel_registerName("isKindOfClass:");
        Method mKind = class_getInstanceMethod(object_getClass(extraData), sKind);
        if (mKind) {
            IronDome_ID_Kind_IMP fKind = (IronDome_ID_Kind_IMP)method_getImplementation(mKind);
            if (fKind(extraData, sKind, strClass)) return; // Drop
        }
    }
    IronDome_Real_AddSimEvent(self, _cmd, type, bh, extraData);
}

// --- LOADER ---
static void* IronDome_Loader(void* arg) {
    sleep(1);
    
    // 1. Activate Anti-DoS (Hotpatch)
    IronDome_SetupHotpatch(); 

    // 2. Activate Runtime Safety (NSString Patch)
    Class strCls = objc_getClass("NSString");
    if (strCls) {
        SEL sGb = sel_registerName("getBytes:length:");
        if (!class_getInstanceMethod(strCls, sGb)) {
            class_addMethod(strCls, sGb, (IMP)IronDome_Patch_GetBytesLength, "v@:^vL");
        }
    }

    // 3. Activate Plist Security
    Class plistCls = objc_getClass(IRON_PC_PLIST_CLASS);
    if (plistCls) {
        SEL sPlist = sel_registerName("propertyListWithData:options:format:error:");
        Method mPlist = class_getClassMethod(plistCls, sPlist);
        if (mPlist) {
            IronDome_Real_PlistWithData = (IronDome_PC_Plist_IMP)method_getImplementation(mPlist);
            method_setImplementation(mPlist, (IMP)IronDome_Hook_PlistWithData);
        }
    }

    // 4. Activate Logic Security (World)
    Class worldCls = objc_getClass(IRON_WORLD_CLASS);
    if (worldCls) {
        SEL sReq = sel_registerName("requestForBlock:fromClient:");
        Method mReq = class_getInstanceMethod(worldCls, sReq);
        if (mReq) {
            IronDome_Real_RequestForBlock = (IronDome_ID_Req_IMP)method_getImplementation(mReq);
            method_setImplementation(mReq, (IMP)IronDome_Hook_RequestForBlock);
        }
        
        SEL sSim = sel_registerName("addSimulationEventOfType:forBlockhead:extraData:");
        Method mSim = class_getInstanceMethod(worldCls, sSim);
        if (mSim) {
            IronDome_Real_AddSimEvent = (IronDome_ID_Sim_IMP)method_getImplementation(mSim);
            method_setImplementation(mSim, (IMP)IronDome_Hook_AddSimEvent);
        }
    }
    
    printf("[IronDome] Protected Mode Active.\n");
    return NULL;
}

__attribute__((constructor)) static void IronDome_Entry() {
    pthread_t t; pthread_create(&t, NULL, IronDome_Loader, NULL);
}
