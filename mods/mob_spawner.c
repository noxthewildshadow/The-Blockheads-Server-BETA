//Command: /spawn <mob_name> <quantity> <player_name> <variation_(optional)> <adult_or_baby_(optional)>

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdbool.h>
#include <ctype.h>
#include <objc/runtime.h>
#include <objc/message.h>

#define MS_SERVER_CLASS "BHServer"

// --- IMP TYPES ---
typedef id (*MS_CmdFunc)(id, SEL, id, id);
typedef void (*MS_ChatFunc)(id, SEL, id, BOOL, id);
typedef id (*MS_SpawnFunc)(id, SEL, long long, int, id, BOOL, BOOL, id);
typedef id (*MS_AllocFunc)(id, SEL);
typedef id (*MS_InitFunc)(id, SEL);
typedef id (*MS_DictFunc)(id, SEL, id, id);
typedef id (*MS_NumFunc)(id, SEL, int);
typedef id (*MS_StrFunc)(id, SEL, const char*);
typedef const char* (*MS_Utf8Func)(id, SEL);
typedef int (*MS_IntFunc)(id, SEL);
typedef id (*MS_IdxFunc)(id, SEL, int);
typedef id (*MS_GetterFunc)(id, SEL);
typedef long (*MS_CompFunc)(id, SEL, id);
typedef void (*MS_VoidFunc)(id, SEL);

static MS_CmdFunc  Real_MSpawn_Cmd = NULL;
static MS_ChatFunc Real_MSpawn_Chat = NULL;

// --- UTILS ---
static id MSpawn_Pool() {
    Class cls = objc_getClass("NSAutoreleasePool");
    SEL sA = sel_registerName("alloc");
    SEL sI = sel_registerName("init");
    MS_AllocFunc fA = (MS_AllocFunc)method_getImplementation(class_getClassMethod(cls, sA));
    MS_AllocFunc fI = (MS_AllocFunc)method_getImplementation(class_getInstanceMethod(cls, sI));
    return fI(fA((id)cls, sA), sI);
}

static void MSpawn_Drain(id pool) {
    if (!pool) return;
    SEL s = sel_registerName("drain");
    MS_VoidFunc f = (MS_VoidFunc)method_getImplementation(class_getInstanceMethod(object_getClass(pool), s));
    f(pool, s);
}

static id MSpawn_Str(const char* txt) {
    if (!txt) return nil;
    Class cls = objc_getClass("NSString");
    SEL s = sel_registerName("stringWithUTF8String:");
    MS_StrFunc f = (MS_StrFunc)method_getImplementation(class_getClassMethod(cls, s));
    return f ? f((id)cls, s, txt) : nil;
}

static const char* MSpawn_CStr(id str) {
    if (!str) return "";
    SEL s = sel_registerName("UTF8String");
    MS_Utf8Func f = (MS_Utf8Func)method_getImplementation(class_getInstanceMethod(object_getClass(str), s));
    return f ? f(str, s) : "";
}

static void MSpawn_Chat(id server, const char* msg) {
    if (server && Real_MSpawn_Chat) {
        Real_MSpawn_Chat(server, sel_registerName("sendChatMessage:displayNotification:sendToClients:"), MSpawn_Str(msg), true, nil);
    }
}

static id MSpawn_MakeBreedDict(int breedVal) {
    if (breedVal < 0) return nil;
    Class clsNum = objc_getClass("NSNumber");
    SEL sNum = sel_registerName("numberWithInt:");
    MS_NumFunc fNum = (MS_NumFunc)method_getImplementation(class_getClassMethod(clsNum, sNum));
    id numObj = fNum((id)clsNum, sNum, breedVal);
    
    id key = MSpawn_Str("breed");
    Class clsDict = objc_getClass("NSDictionary");
    SEL sDict = sel_registerName("dictionaryWithObject:forKey:");
    MS_DictFunc fDict = (MS_DictFunc)method_getImplementation(class_getClassMethod(clsDict, sDict));
    return fDict((id)clsDict, sDict, numObj, key);
}

id MSpawn_FindPlayer(id dynWorld, const char* name) {
    if (!dynWorld) return nil;
    Ivar iv = class_getInstanceVariable(object_getClass(dynWorld), "netBlockheads");
    if (!iv) return nil;
    id list = *(id*)((char*)dynWorld + ivar_getOffset(iv));
    
    SEL sCnt = sel_registerName("count");
    SEL sIdx = sel_registerName("objectAtIndex:");
    SEL sClientName = sel_registerName("clientName");
    SEL sComp = sel_registerName("caseInsensitiveCompare:");
    
    MS_IntFunc fCnt = (MS_IntFunc)method_getImplementation(class_getInstanceMethod(object_getClass(list), sCnt));
    MS_IdxFunc fIdx = (MS_IdxFunc)method_getImplementation(class_getInstanceMethod(object_getClass(list), sIdx));
    
    int count = fCnt(list, sCnt);
    id target = MSpawn_Str(name);
    
    for (int i=0; i<count; i++) {
        id pool = MSpawn_Pool();
        id bh = fIdx(list, sIdx, i);
        id cName = nil;
        Method mName = class_getInstanceMethod(object_getClass(bh), sClientName);
        if (mName) {
            MS_GetterFunc fName = (MS_GetterFunc)method_getImplementation(mName);
            cName = fName(bh, sClientName);
        }
        
        if (cName) {
            MS_CompFunc fComp = (MS_CompFunc)method_getImplementation(class_getInstanceMethod(object_getClass(cName), sComp));
            if (fComp(cName, sComp, target) == 0) return bh;
        }
        MSpawn_Drain(pool);
    }
    return nil;
}

// --- PARSERS ---

// Mapeado exacto del enum DodoBreed
int MSpawn_ParseDodo(const char* v) {
    if (!v) return 0; // Default Standard
    if (isdigit(v[0])) return atoi(v);
    
    if (strcasecmp(v, "standard")==0) return 0;
    if (strcasecmp(v, "stone")==0) return 1;
    if (strcasecmp(v, "limestone")==0) return 2;
    if (strcasecmp(v, "sandstone")==0) return 3;
    if (strcasecmp(v, "marble")==0) return 4;
    if (strcasecmp(v, "red_marble")==0) return 5;
    if (strcasecmp(v, "lapis")==0) return 6;
    if (strcasecmp(v, "dirt")==0) return 7;
    if (strcasecmp(v, "compost")==0) return 8;
    if (strcasecmp(v, "wood")==0) return 9;
    if (strcasecmp(v, "gravel")==0) return 10;
    if (strcasecmp(v, "sand")==0) return 11;
    if (strcasecmp(v, "black_sand")==0) return 12;
    if (strcasecmp(v, "glass")==0) return 13;
    if (strcasecmp(v, "black_glass")==0) return 14;
    if (strcasecmp(v, "clay")==0) return 15;
    if (strcasecmp(v, "red_brick")==0) return 16;
    if (strcasecmp(v, "brick")==0) return 16; // Alias
    if (strcasecmp(v, "flint")==0) return 17;
    if (strcasecmp(v, "coal")==0) return 18;
    if (strcasecmp(v, "oil")==0) return 19;
    if (strcasecmp(v, "fuel")==0) return 20;
    if (strcasecmp(v, "copper")==0) return 21;
    if (strcasecmp(v, "tin")==0) return 22;
    if (strcasecmp(v, "iron")==0) return 23;
    if (strcasecmp(v, "gold")==0) return 24;
    if (strcasecmp(v, "titanium")==0) return 25;
    if (strcasecmp(v, "platinum")==0) return 26;
    if (strcasecmp(v, "amethyst")==0) return 27;
    if (strcasecmp(v, "sapphire")==0) return 28;
    if (strcasecmp(v, "emerald")==0) return 29;
    if (strcasecmp(v, "ruby")==0) return 30;
    if (strcasecmp(v, "diamond")==0) return 31;
    if (strcasecmp(v, "rainbow")==0) return 32;
    
    return 0; 
}

// Mapeado exacto del enum DonkeyBreeds y Unicorn Logic
int MSpawn_ParseDonkey(const char* v, bool isUnicorn) {
    if (!v) return isUnicorn ? 23 : 0; // Default Unicorn=Rainbow(23), Donkey=Standard(0)
    if (isdigit(v[0])) return atoi(v);

    // Colores base comunes
    if (strcasecmp(v, "standard")==0) return isUnicorn ? 12 : 0; // Unicorn standard is Grey(12)
    if (strcasecmp(v, "brown")==0) return isUnicorn ? 13 : 1;
    if (strcasecmp(v, "black")==0) return isUnicorn ? 14 : 2;
    if (strcasecmp(v, "blue")==0) return isUnicorn ? 15 : 3;
    if (strcasecmp(v, "green")==0) return isUnicorn ? 16 : 4;
    if (strcasecmp(v, "yellow")==0) return isUnicorn ? 17 : 5;
    if (strcasecmp(v, "orange")==0) return isUnicorn ? 18 : 6;
    if (strcasecmp(v, "red")==0) return isUnicorn ? 19 : 7;
    if (strcasecmp(v, "purple")==0) return isUnicorn ? 20 : 8;
    if (strcasecmp(v, "pink")==0) return isUnicorn ? 21 : 9;
    if (strcasecmp(v, "white")==0) return isUnicorn ? 22 : 10;
    if (strcasecmp(v, "rainbow")==0) return isUnicorn ? 23 : 11;
    
    // Alias especificos de donkey
    if (strcasecmp(v, "grey")==0) return isUnicorn ? 12 : 0; // Donkey normal no tiene grey explicito en enum, usa standard? Asumimos 0 o grey unicorn 12.

    return isUnicorn ? 23 : 0;
}

void MSpawn_Execute(id dynWorld, id player, int mobID, int qty, int breed, bool baby) {
    Ivar ivP = class_getInstanceVariable(object_getClass(player), "pos");
    long long pos = *(long long*)((char*)player + ivar_getOffset(ivP));
    SEL sLoad = sel_registerName("loadNPCAtPosition:type:saveDict:isAdult:wasPlaced:placedByClient:");
    MS_SpawnFunc fLoad = (MS_SpawnFunc)method_getImplementation(class_getInstanceMethod(object_getClass(dynWorld), sLoad));
    id dict = MSpawn_MakeBreedDict(breed);
    for(int i=0; i<qty; i++) {
        fLoad(dynWorld, sLoad, pos, mobID, dict, !baby, 0, nil);
    }
}

id Hook_MSpawn_Cmd(id self, SEL _cmd, id cmdStr, id client) {
    const char* raw = MSpawn_CStr(cmdStr);
    if (!raw || strncmp(raw, "/spawn", 6) != 0) return Real_MSpawn_Cmd(self, _cmd, cmdStr, client);
    
    id pool = MSpawn_Pool();
    char buf[256]; strncpy(buf, raw, 255);
    
    // Tokenization manual para evitar saltos raros
    char* args[10] = {0};
    int argCount = 0;
    char* token = strtok(buf, " "); // /spawn
    
    while(token && argCount < 10) {
        token = strtok(NULL, " ");
        if (token) args[argCount++] = token;
    }
    
    // args[0]=mob, args[1]=qty, args[2]=player, args[3+]=options
    
    if (argCount < 3) {
        MSpawn_Chat(self, "[Usage] /spawn <mob> <qty> <player> [variant/baby/force...]");
        MSpawn_Drain(pool);
        return nil;
    }
    
    char* sMob = args[0];
    char* sQty = args[1];
    char* sPl = args[2];
    
    id world = nil;
    object_getInstanceVariable(self, "world", (void**)&world);
    id dynWorld = nil;
    object_getInstanceVariable(world, "dynamicWorld", (void**)&dynWorld);
    
    id target = MSpawn_FindPlayer(dynWorld, sPl);
    if (!target) {
        MSpawn_Chat(self, "[Error] Player not found.");
        MSpawn_Drain(pool);
        return nil;
    }
    
    int qty = atoi(sQty);
    if (qty < 1) qty = 1;
    
    bool isBaby = false;
    bool force = false;
    const char* variant = NULL;
    
    // Procesar argumentos extra en cualquier orden (index 3 en adelante)
    for(int i=3; i<argCount; i++) {
        if (!args[i]) continue;
        if (strcasecmp(args[i], "baby") == 0) isBaby = true;
        else if (strcasecmp(args[i], "force") == 0) force = true;
        else {
            // Si no es flag, asumimos que es la variante
            variant = args[i]; 
        }
    }
    
    if (!force && qty > 10) {
        qty = 10;
        MSpawn_Chat(self, "[Warn] Qty capped at 10. Use 'force' to override.");
    }
    
    int mobID = 0;
    int breed = -1;
    
    if (strcasecmp(sMob, "dodo")==0) {
        mobID = 1; 
        breed = MSpawn_ParseDodo(variant);
    }
    else if (strcasecmp(sMob, "donkey")==0) {
        mobID = 3; 
        breed = MSpawn_ParseDonkey(variant, false);
    }
    else if (strcasecmp(sMob, "unicorn")==0) {
        mobID = 3; 
        // Si no puso variante, default a rainbow(23), si puso "red", sera unicorn red(19)
        breed = MSpawn_ParseDonkey(variant, true); 
    }
    else if (strcasecmp(sMob, "shark")==0) mobID = 5;
    else if (strcasecmp(sMob, "troll")==0) mobID = 6;
    else if (strcasecmp(sMob, "scorpion")==0) mobID = 7;
    else if (strcasecmp(sMob, "yak")==0) mobID = 8;
    else if (strcasecmp(sMob, "dropbear")==0) mobID = 2;
    else if (strcasecmp(sMob, "fish")==0) mobID = 4;
    else if (strcasecmp(sMob, "cave_troll")==0) mobID = 6; // Alias
    
    if (mobID > 0) {
        MSpawn_Execute(dynWorld, target, mobID, qty, breed, isBaby);
        char msg[128];
        snprintf(msg, 128, "[Spawn] Summoned %d %s (%d) near %s.", qty, sMob, breed, sPl);
        MSpawn_Chat(self, msg);
    } else {
        MSpawn_Chat(self, "[Error] Unknown Mob.");
    }
    
    MSpawn_Drain(pool);
    return nil;
}

static void* MSpawn_Init(void* arg) {
    sleep(1);
    Class cls = objc_getClass(MS_SERVER_CLASS);
    if (cls) {
        Method mC = class_getInstanceMethod(cls, sel_registerName("handleCommand:issueClient:"));
        Real_MSpawn_Cmd = (MS_CmdFunc)method_getImplementation(mC);
        method_setImplementation(mC, (IMP)Hook_MSpawn_Cmd);
        
        Method mT = class_getInstanceMethod(cls, sel_registerName("sendChatMessage:displayNotification:sendToClients:"));
        Real_MSpawn_Chat = (MS_ChatFunc)method_getImplementation(mT);
        printf("[MSpawn] Hooked!\n");
    }
    return NULL;
}

__attribute__((constructor)) static void MSpawn_Entry() {
    pthread_t t; pthread_create(&t, NULL, MSpawn_Init, NULL);
}
