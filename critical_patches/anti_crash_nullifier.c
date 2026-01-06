#define _GNU_SOURCE
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
#include <stdint.h>
#include <pthread.h>
#include <objc/runtime.h>
#include <objc/message.h>

#define ADC_MAX_PLIST_SIZE 3221225472UL

typedef struct {
    uint32_t macroIndex;
    uint8_t createIfNotCreated;
    uint8_t padding[3];
} ADC_ClientMacroBlockRequest;

typedef id (*ADC_PC_Plist_IMP)(id, SEL, id, unsigned long, unsigned long*, id*);
typedef unsigned long (*ADC_ID_Len_IMP)(id, SEL); 
typedef void (*ADC_ID_Req_IMP)(id, SEL, ADC_ClientMacroBlockRequest, id); 
typedef void (*ADC_ID_Sim_IMP)(id, SEL, int, id, id);
typedef id (*ADC_ID_Copy_IMP)(id, SEL);
typedef id (*ADC_ID_ObjForKey_IMP)(id, SEL, id);
typedef void (*ADC_ID_SetObj_IMP)(id, SEL, id, id);
typedef BOOL (*ADC_ID_Kind_IMP)(id, SEL, Class);
typedef id (*ADC_ID_Alloc_IMP)(id, SEL);
typedef id (*ADC_ID_Init_IMP)(id, SEL, const char*);

static ADC_PC_Plist_IMP ADC_Real_PlistWithData = NULL;
static ADC_ID_Req_IMP   ADC_Real_RequestForBlock = NULL;
static ADC_ID_Sim_IMP   ADC_Real_AddSimEvent = NULL;

static id ADC_ID_Str(const char* str) {
    Class cls = objc_getClass("NSString");
    SEL sAlloc = sel_registerName("alloc");
    SEL sInit = sel_registerName("initWithUTF8String:");
    if (!cls) return nil;
    
    id (*fAlloc)(id, SEL) = (id (*)(id, SEL))class_getMethodImplementation(object_getClass((id)cls), sAlloc);
    id (*fInit)(id, SEL, const char*) = (id (*)(id, SEL, const char*))class_getMethodImplementation(cls, sInit);
    
    return fInit(fAlloc((id)cls, sAlloc), sInit, str);
}

static id ADC_GetSafeEmptyMutableDict() {
    Class cls = objc_getClass("NSMutableDictionary");
    SEL s = sel_registerName("dictionary");
    id (*f)(id, SEL) = (id (*)(id, SEL))class_getMethodImplementation(object_getClass((id)cls), s);
    return f((id)cls, s);
}

static int ADC_GetWorldWidth(id worldObject) {
    if (!worldObject) return 0;
    Ivar ivar = class_getInstanceVariable(object_getClass(worldObject), "worldWidthMacro");
    if (ivar) {
        ptrdiff_t offset = ivar_getOffset(ivar);
        int* ptr = (int*)((char*)worldObject + offset);
        return *ptr;
    }
    return 0; 
}

static void ADC_SanitizePacket(id dict) {
    if (!dict) return;
    Class dictClass = object_getClass(dict);
    
    SEL sObj = sel_registerName("objectForKey:");
    SEL sSet = sel_registerName("setObject:forKey:");
    SEL sKind = sel_registerName("isKindOfClass:");
    
    if (!class_respondsToSelector(dictClass, sObj) || !class_respondsToSelector(dictClass, sSet)) return;

    ADC_ID_ObjForKey_IMP fGet = (ADC_ID_ObjForKey_IMP)class_getMethodImplementation(dictClass, sObj);
    ADC_ID_SetObj_IMP fSet = (ADC_ID_SetObj_IMP)class_getMethodImplementation(dictClass, sSet);
    
    Class strClass = objc_getClass("NSString");
    id kMsg = ADC_ID_Str("message");
    id kAlias = ADC_ID_Str("alias");

    id msgVal = fGet(dict, sObj, kMsg);
    if (msgVal) {
        BOOL (*fKind)(id, SEL, Class) = (BOOL (*)(id, SEL, Class))class_getMethodImplementation(object_getClass(msgVal), sKind);
        if (!fKind(msgVal, sKind, strClass)) {
            fSet(dict, sSet, ADC_ID_Str(""), kMsg);
        }
    }

    id aliasVal = fGet(dict, sObj, kAlias);
    if (aliasVal) {
        BOOL (*fKind)(id, SEL, Class) = (BOOL (*)(id, SEL, Class))class_getMethodImplementation(object_getClass(aliasVal), sKind);
        if (!fKind(aliasVal, sKind, strClass)) {
            fSet(dict, sSet, ADC_ID_Str("Unknown"), kAlias);
        }
    }
}

static id ADC_Hook_PlistWithData(id self, SEL _cmd, id data, unsigned long opt, unsigned long* fmt, id* err) {
    if (!data) return nil;
    
    SEL sLen = sel_registerName("length");
    unsigned long (*fLen)(id, SEL) = (unsigned long (*)(id, SEL))class_getMethodImplementation(object_getClass(data), sLen);
    if (fLen) {
        unsigned long len = fLen(data, sLen);
        if (len > ADC_MAX_PLIST_SIZE) return ADC_GetSafeEmptyMutableDict();
    }

    id result = ADC_Real_PlistWithData(self, _cmd, data, opt, fmt, err);
    if (result == nil) return ADC_GetSafeEmptyMutableDict();
    
    SEL sMut = sel_registerName("mutableCopy");
    id (*fMut)(id, SEL) = (id (*)(id, SEL))class_getMethodImplementation(object_getClass(result), sMut);
    
    if (fMut) {
        id mutableResult = fMut(result, sMut);
        ADC_SanitizePacket(mutableResult);
        return mutableResult;
    }
    
    return result;
}

static void ADC_Hook_RequestForBlock(id self, SEL _cmd, ADC_ClientMacroBlockRequest req, id clientID) {
    int width = ADC_GetWorldWidth(self);
    if (width <= 0) width = 512; 
    unsigned int safeLimit = (unsigned int)(width * 32) + 1000;

    if (req.macroIndex > safeLimit) {
        return; 
    }
    
    ADC_Real_RequestForBlock(self, _cmd, req, clientID);
}

static void ADC_Patch_GetBytesLength(id self, SEL _cmd, void *buffer, unsigned long length) {
    SEL sUtf8 = sel_registerName("UTF8String");
    id (*fUtf8)(id, SEL) = (id (*)(id, SEL))class_getMethodImplementation(object_getClass(self), sUtf8);
    
    if (fUtf8) {
        const char *strData = (const char*)fUtf8(self, sUtf8);
        if (strData && buffer) {
            size_t strLen = strlen(strData);
            size_t copyLen = (strLen < length) ? strLen : length;
            memcpy(buffer, strData, copyLen);
            if (copyLen < length) memset((char*)buffer + copyLen, 0, length - copyLen);
        }
    }
}

static void ADC_Hook_AddSimEvent(id self, SEL _cmd, int type, id bh, id extraData) {
    ADC_Real_AddSimEvent(self, _cmd, type, bh, extraData);
}

static void* ADC_Loader(void* arg) {
    sleep(1);
    
    Class strCls = objc_getClass("NSString");
    if (strCls) {
        SEL sGb = sel_registerName("getBytes:length:");
        if (!class_getInstanceMethod(strCls, sGb)) {
             class_addMethod(strCls, sGb, (IMP)ADC_Patch_GetBytesLength, "v@:^vL");
        }
    }

    Class plistCls = objc_getClass("NSPropertyListSerialization");
    if (plistCls) {
        SEL sPlist = sel_registerName("propertyListWithData:options:format:error:");
        Method mPlist = class_getClassMethod(plistCls, sPlist);
        if (mPlist) {
            ADC_Real_PlistWithData = (ADC_PC_Plist_IMP)method_getImplementation(mPlist);
            method_setImplementation(mPlist, (IMP)ADC_Hook_PlistWithData);
        }
    }

    Class worldCls = objc_getClass("World");
    if (worldCls) {
        SEL sReq = sel_registerName("requestForBlock:fromClient:");
        Method mReq = class_getInstanceMethod(worldCls, sReq);
        if (mReq) {
            ADC_Real_RequestForBlock = (ADC_ID_Req_IMP)method_getImplementation(mReq);
            method_setImplementation(mReq, (IMP)ADC_Hook_RequestForBlock);
        }
        
        SEL sSim = sel_registerName("addSimulationEventOfType:forBlockhead:extraData:");
        Method mSim = class_getInstanceMethod(worldCls, sSim);
        if (mSim) {
            ADC_Real_AddSimEvent = (ADC_ID_Sim_IMP)method_getImplementation(mSim);
            method_setImplementation(mSim, (IMP)ADC_Hook_AddSimEvent);
        }
    }
    return NULL;
}

__attribute__((constructor)) static void ADC_Entry() {
    pthread_t t; 
    pthread_create(&t, NULL, ADC_Loader, NULL);
    pthread_detach(t);
}
