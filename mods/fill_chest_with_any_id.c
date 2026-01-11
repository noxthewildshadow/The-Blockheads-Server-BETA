// Commands:
//   /fill <ID> [DataA] [DataB] [force]  -> Fills chest with specific ID (dataA and dataB are optional).
//   /fill_clone [force]                 -> Copies the first item found in the chest.
//   /fill off                           -> Deactivates everything.

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

// --- CONFIGURATION ---
#define CF_SERVER_CLASS   "BHServer"
#define CF_CHEST_CLASS    "Chest"
#define CF_ITEM_CLASS     "InventoryItem"
#define CF_ARRAY_CLASS    "NSMutableArray"
#define CF_BASKET_ID      12  // Basket ID used to fill the chest slots

// --- IMP DEFINITIONS (GNUstep Compatibility) ---
// Method signatures mapped to function pointers for strict typing
typedef id (*CF_PlaceFunc)(id, SEL, id, id, long long, id, id, unsigned char, id, id, id);
typedef id (*CF_CmdFunc)(id, SEL, id, id);
typedef void (*CF_ChatFunc)(id, SEL, id, BOOL, id);

// Memory & Object Accessors
typedef id (*CF_AllocFunc)(id, SEL);
typedef id (*CF_InitArrFunc)(id, SEL, unsigned long);
typedef id (*CF_InitItemFunc)(id, SEL, int, uint16_t, uint16_t, id, id);
typedef void (*CF_AddObjFunc)(id, SEL, id);
typedef void (*CF_RelFunc)(id, SEL);
typedef void (*CF_VoidFunc)(id, SEL);
typedef id (*CF_StrFunc)(id, SEL, const char*);
typedef const char* (*CF_Utf8Func)(id, SEL);

// Getters for Item Properties
typedef int (*CF_IntFunc)(id, SEL);
typedef uint16_t (*CF_UInt16Func)(id, SEL);
typedef id (*CF_IdFunc)(id, SEL);
typedef id (*CF_IdxFunc)(id, SEL, int);

// --- GLOBAL STATE ---
static CF_PlaceFunc Real_CFill_Place = NULL;
static CF_CmdFunc   Real_CFill_Cmd = NULL;
static CF_ChatFunc  Real_CFill_Chat = NULL;

// Logic Flags
static bool g_CFill_Active = false;      // Mode: Manual ID Fill
static bool g_Clone_Active = false;      // Mode: Clone Existing Item
static bool g_Force_Mode   = false;      // Mode: Do not auto-disable

// Manual Fill Data
static int  g_CFill_TargetID = 0;
static int  g_CFill_DataA = 0;
static int  g_CFill_DataB = 0;

// Used to send disable notification from Place hook
static id g_ServerInstance = nil; 

// --- UTILITIES ---

static void CFill_Release(id obj) {
    if (!obj) return;
    SEL s = sel_registerName("release");
    CF_RelFunc f = (CF_RelFunc)method_getImplementation(class_getInstanceMethod(object_getClass(obj), s));
    f(obj, s);
}

static id CFill_Pool() {
    Class cls = objc_getClass("NSAutoreleasePool");
    SEL sA = sel_registerName("alloc");
    SEL sI = sel_registerName("init");
    CF_AllocFunc fA = (CF_AllocFunc)method_getImplementation(class_getClassMethod(cls, sA));
    CF_AllocFunc fI = (CF_AllocFunc)method_getImplementation(class_getInstanceMethod(cls, sI));
    return fI(fA((id)cls, sA), sI);
}

static void CFill_Drain(id pool) {
    if (!pool) return;
    SEL s = sel_registerName("drain");
    CF_VoidFunc f = (CF_VoidFunc)method_getImplementation(class_getInstanceMethod(object_getClass(pool), s));
    f(pool, s);
}

static id CFill_Str(const char* txt) {
    if (!txt) return nil;
    Class cls = objc_getClass("NSString");
    SEL s = sel_registerName("stringWithUTF8String:");
    CF_StrFunc f = (CF_StrFunc)method_getImplementation(class_getClassMethod(cls, s));
    return f ? f((id)cls, s, txt) : nil;
}

static const char* CFill_CStr(id str) {
    if (!str) return "";
    SEL s = sel_registerName("UTF8String");
    CF_Utf8Func f = (CF_Utf8Func)method_getImplementation(class_getInstanceMethod(object_getClass(str), s));
    return f ? f(str, s) : "";
}

static void CFill_Msg(id server, const char* msg) {
    if (server && Real_CFill_Chat) {
        Real_CFill_Chat(server, sel_registerName("sendChatMessage:displayNotification:sendToClients:"), CFill_Str(msg), true, nil);
    }
}

// --- OBJECT CREATION HELPERS ---

id CFill_CreateArray(int cap) {
    Class clsArr = objc_getClass(CF_ARRAY_CLASS);
    SEL sAlloc = sel_registerName("alloc");
    SEL sInit = sel_registerName("initWithCapacity:");
    
    CF_AllocFunc fAlloc = (CF_AllocFunc)method_getImplementation(class_getClassMethod(clsArr, sAlloc));
    CF_InitArrFunc fInit = (CF_InitArrFunc)method_getImplementation(class_getInstanceMethod(clsArr, sInit));
    
    id arr = fAlloc((id)clsArr, sAlloc);
    return fInit(arr, sInit, cap);
}

id CFill_CreateItem(int type, int dA, int dB, id subItems, id saveDict) {
    Class clsItem = objc_getClass(CF_ITEM_CLASS);
    SEL sAlloc = sel_registerName("alloc");
    SEL sInit = sel_registerName("initWithType:dataA:dataB:subItems:dynamicObjectSaveDict:");
    
    CF_AllocFunc fAlloc = (CF_AllocFunc)method_getImplementation(class_getClassMethod(clsItem, sAlloc));
    CF_InitItemFunc fInit = (CF_InitItemFunc)method_getImplementation(class_getInstanceMethod(clsItem, sInit));
    
    id item = fAlloc((id)clsItem, sAlloc);
    return fInit(item, sInit, type, (uint16_t)dA, (uint16_t)dB, subItems, saveDict);
}

// --- GENERATION LOGIC ---

// This function creates a full inventory (16 slots) filled with Baskets, which are filled with 99x of the Target Item.
id CFill_GenerateFullInventory(int itemID, int dA, int dB, id sourceSubItems, id sourceSaveDict) {
    id mainArr = CFill_CreateArray(16);
    if (!mainArr) return nil;

    SEL sAdd = sel_registerName("addObject:");
    Method mAdd = class_getInstanceMethod(object_getClass(mainArr), sAdd);
    CF_AddObjFunc fAdd = (CF_AddObjFunc)method_getImplementation(mAdd);
    
    for(int i=0; i<16; i++) {
        // 1. Create Basket SubItems container
        id basketSubItems = CFill_CreateArray(4);
        
        for(int j=0; j<4; j++) {
            // 2. Create the Slot Array (Stack of 99)
            id slotArr = CFill_CreateArray(99); 
            Method mSlotAdd = class_getInstanceMethod(object_getClass(slotArr), sAdd);
            CF_AddObjFunc fSlotAdd = (CF_AddObjFunc)method_getImplementation(mSlotAdd);
            
            // 3. Create the base item content (The item to dupe)
            // Note: We create a fresh instance for the first one to establish the base
            id content = CFill_CreateItem(itemID, dA, dB, sourceSubItems, sourceSaveDict);
            
            if (content) {
                fSlotAdd(slotArr, sAdd, content); // Add index 0
                
                // 4. Fill the rest of the stack (98 more)
                // We create new instances for each to ensure independent memory pointers for saveDicts if needed
                for(int k=0; k<98; k++) {
                     id copy = CFill_CreateItem(itemID, dA, dB, sourceSubItems, sourceSaveDict);
                     fSlotAdd(slotArr, sAdd, copy);
                     CFill_Release(copy);
                }
                CFill_Release(content); 
            }
            
            // Add slot to basket
            fAdd(basketSubItems, sAdd, slotArr);
            CFill_Release(slotArr);
        }
        
        // 5. Create the Basket Item containing the filled subitems
        id basket = CFill_CreateItem(CF_BASKET_ID, 0, 0, basketSubItems, nil);
        CFill_Release(basketSubItems);
        
        // 6. Create the Chest Slot (Stack of 1 Basket)
        id chestSlot = CFill_CreateArray(1);
        fAdd(chestSlot, sAdd, basket);
        CFill_Release(basket);
        
        // 7. Add to Chest Inventory
        fAdd(mainArr, sAdd, chestSlot);
        CFill_Release(chestSlot);
    }
    
    return mainArr;
}

// --- CLONE LOGIC ---

// Reads the contents of a chest and generates a full inventory based on the first item found.
id CFill_CloneFromChest(id chestObj) {
    if (!chestObj) return nil;
    
    // Access 'inventoryItems' ivar directly
    Ivar ivInv = class_getInstanceVariable(object_getClass(chestObj), "inventoryItems");
    if (!ivInv) return nil;
    
    id invArray = *(id*)((char*)chestObj + ivar_getOffset(ivInv));
    if (!invArray) return nil;

    // IMPs for NSArray
    SEL sCount = sel_registerName("count");
    SEL sObjAt = sel_registerName("objectAtIndex:");
    CF_IntFunc fCount = (CF_IntFunc)method_getImplementation(class_getInstanceMethod(object_getClass(invArray), sCount));
    CF_IdxFunc fObjAt = (CF_IdxFunc)method_getImplementation(class_getInstanceMethod(object_getClass(invArray), sObjAt));
    
    int count = fCount(invArray, sCount);
    if (count == 0) return nil;

    // Find first valid item
    id foundItem = nil;
    for (int i = 0; i < count; i++) {
        id slotStack = fObjAt(invArray, sObjAt, i); // NSMutableArray (Stack)
        if (slotStack) {
            int stackCount = fCount(slotStack, sCount);
            if (stackCount > 0) {
                foundItem = fObjAt(slotStack, sObjAt, 0); // Get item at index 0
                if (foundItem) break;
            }
        }
    }
    
    if (!foundItem) return nil;
    
    // Extract Exact Data
    SEL sType = sel_registerName("itemType");
    SEL sDA   = sel_registerName("dataA");
    SEL sDB   = sel_registerName("dataB");
    SEL sSub  = sel_registerName("subItems");
    SEL sSave = sel_registerName("dynamicObjectSaveDict");
    
    Class clsItem = object_getClass(foundItem);
    
    // Use Getters via IMPs
    int itemID = ((CF_IntFunc)method_getImplementation(class_getInstanceMethod(clsItem, sType)))(foundItem, sType);
    uint16_t dA = ((CF_UInt16Func)method_getImplementation(class_getInstanceMethod(clsItem, sDA)))(foundItem, sDA);
    uint16_t dB = ((CF_UInt16Func)method_getImplementation(class_getInstanceMethod(clsItem, sDB)))(foundItem, sDB);
    id subItems = ((CF_IdFunc)method_getImplementation(class_getInstanceMethod(clsItem, sSub)))(foundItem, sSub);
    id saveDict = ((CF_IdFunc)method_getImplementation(class_getInstanceMethod(clsItem, sSave)))(foundItem, sSave);
    
    // Generate the massive filled inventory
    return CFill_GenerateFullInventory(itemID, (int)dA, (int)dB, subItems, saveDict);
}

// --- HOOKS ---

id Hook_CFill_Place(id self, SEL _cmd, id w, id dw, long long pos, id cache, id item, unsigned char flip, id save, id client, id cName) {
    // 1. Let the server create the chest normally
    id chestObj = Real_CFill_Place(self, _cmd, w, dw, pos, cache, item, flip, save, client, cName);
    
    // 2. Check if we need to intervene
    if ((g_CFill_Active || g_Clone_Active) && chestObj) {
        id pool = CFill_Pool();
        bool success = false;
        
        Ivar ivInv = class_getInstanceVariable(object_getClass(chestObj), "inventoryItems");
        if (ivInv) {
            id newInv = nil;
            
            if (g_Clone_Active) {
                // Read from the chest itself (which contains the item placed by user)
                newInv = CFill_CloneFromChest(chestObj);
            } else if (g_CFill_Active && g_CFill_TargetID > 0) {
                // Use manual ID settings
                newInv = CFill_GenerateFullInventory(g_CFill_TargetID, g_CFill_DataA, g_CFill_DataB, nil, nil);
            }
            
            if (newInv) {
                // Swap pointer
                id* ptrToInv = (id*)((char*)chestObj + ivar_getOffset(ivInv));
                if (*ptrToInv) CFill_Release(*ptrToInv);
                *ptrToInv = newInv; // Retained by creation
                
                // Notify server of content change
                SEL sUp = sel_registerName("contentsDidChange");
                if (class_getInstanceMethod(object_getClass(chestObj), sUp)) {
                    CF_VoidFunc fUp = (CF_VoidFunc)method_getImplementation(class_getInstanceMethod(object_getClass(chestObj), sUp));
                    fUp(chestObj, sUp);
                }
                success = true;
            }
        }
        
        // 3. Auto-Disable Logic (Safety)
        if (success && !g_Force_Mode) {
            g_CFill_Active = false;
            g_Clone_Active = false;
            // Optionally notify via global server instance if available
            if (g_ServerInstance) {
                CFill_Msg(g_ServerInstance, "[System] Auto-disabled for safety. Type command again to reuse.");
            }
        }
        
        CFill_Drain(pool);
    }
    return chestObj;
}

id Hook_CFill_Cmd(id self, SEL _cmd, id cmdStr, id client) {
    const char* raw = CFill_CStr(cmdStr);
    if (!raw) return Real_CFill_Cmd(self, _cmd, cmdStr, client);
    
    // Capture Server Instance for later use in notifications
    g_ServerInstance = self;
    
    // --- COMMAND: /fill_clone ---
    if (strncmp(raw, "/fill_clone", 11) == 0) {
        id pool = CFill_Pool();
        
        // Check for 'force' argument
        g_Force_Mode = (strcasestr(raw, "force") != NULL);
        
        g_Clone_Active = !g_Clone_Active;
        g_CFill_Active = false; // Disable conflicting mode
        
        if (g_Clone_Active) {
            char msg[256];
            if (g_Force_Mode) {
                snprintf(msg, 256, "[Clone] ON (PERSISTENT). Use 'force' to keep active. Place a chest with 1 item to copy.");
            } else {
                snprintf(msg, 256, "[Clone] ON (SINGLE USE). Will auto-disable after 1 chest. Add 'force' to override.");
            }
            CFill_Msg(self, msg);
        } else {
            CFill_Msg(self, "[Clone] OFF.");
        }
        
        CFill_Drain(pool);
        return nil;
    }
    
    // --- COMMAND: /fill ---
    if (strncmp(raw, "/fill", 5) == 0) {
        id pool = CFill_Pool();
        
        char buffer[256]; strncpy(buffer, raw, 255);
        
        // Manual Tokenizer to handle optional args
        char* token = strtok(buffer, " "); // skip cmd
        char* sID = strtok(NULL, " ");
        
        // Handle "/fill off" or empty
        if (!sID || strcasecmp(sID, "off") == 0) {
            g_CFill_Active = false;
            g_Clone_Active = false;
            CFill_Msg(self, "[Fill] OFF.");
            CFill_Drain(pool);
            return nil;
        }
        
        // Parse args
        int pID = atoi(sID);
        int pDA = 0;
        int pDB = 0;
        bool pForce = false;
        
        char* nextArg = strtok(NULL, " ");
        while (nextArg) {
            if (strcasecmp(nextArg, "force") == 0) {
                pForce = true;
            } else {
                if (pDA == 0 && nextArg[0] != 'f') pDA = atoi(nextArg); // Simple heuristic
                else if (pDB == 0 && nextArg[0] != 'f') pDB = atoi(nextArg);
            }
            nextArg = strtok(NULL, " ");
        }
        
        g_CFill_TargetID = pID;
        g_CFill_DataA = pDA;
        g_CFill_DataB = pDB;
        g_Force_Mode = pForce;
        
        g_CFill_Active = true;
        g_Clone_Active = false;
        
        char msg[256];
        if (g_Force_Mode) {
            snprintf(msg, 256, "[Fill] ON (PERSISTENT). ID: %d (%d, %d).", g_CFill_TargetID, g_CFill_DataA, g_CFill_DataB);
        } else {
            snprintf(msg, 256, "[Fill] ON (SINGLE USE). ID: %d (%d, %d). Will auto-disable.", g_CFill_TargetID, g_CFill_DataA, g_CFill_DataB);
        }
        CFill_Msg(self, msg);
        
        CFill_Drain(pool);
        return nil;
    }
    
    return Real_CFill_Cmd(self, _cmd, cmdStr, client);
}

// --- INITIALIZATION ---
static void* CFill_Init(void* arg) {
    sleep(1);
    
    // Hook Server (Commands/Chat)
    Class clsServer = objc_getClass(CF_SERVER_CLASS);
    if (clsServer) {
        Method mC = class_getInstanceMethod(clsServer, sel_registerName("handleCommand:issueClient:"));
        Real_CFill_Cmd = (CF_CmdFunc)method_getImplementation(mC);
        method_setImplementation(mC, (IMP)Hook_CFill_Cmd);
        
        Method mT = class_getInstanceMethod(clsServer, sel_registerName("sendChatMessage:displayNotification:sendToClients:"));
        Real_CFill_Chat = (CF_ChatFunc)method_getImplementation(mT);
    } else {
        printf("[Error] BHServer class not found.\n");
    }
    
    // Hook Chest (Place)
    Class clsChest = objc_getClass(CF_CHEST_CLASS);
    if (clsChest) {
        Method mP = class_getInstanceMethod(clsChest, sel_registerName("initWithWorld:dynamicWorld:atPosition:cache:item:flipped:saveDict:placedByClient:clientName:"));
        Real_CFill_Place = (CF_PlaceFunc)method_getImplementation(mP);
        method_setImplementation(mP, (IMP)Hook_CFill_Place);
    } else {
        printf("[Error] Chest class not found.\n");
    }
    
    return NULL;
}

__attribute__((constructor)) static void CFill_Entry() {
    pthread_t t; 
    pthread_create(&t, NULL, CFill_Init, NULL);
}
