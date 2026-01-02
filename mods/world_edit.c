//Commands: /p1   /p2   /set <blocktype_id_or_name>   /del <blocktype_id_or_name_(Or leave empty for del all)>
//   /replace <old_blocktype_id_or_name> <new_blocktype_id_or_name>
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <math.h>
#include <ctype.h>
#include <stdarg.h>

// --- Native Includes ---
#include <objc/runtime.h>

#ifndef nil
#define nil (id)0
#endif

// ==========================================
// CONFIGURATION
// ==========================================

#define TARGET_SERVER_CLASS "BHServer"
#define TARGET_WORLD_CLASS  "World"
#define SYM_TILE_AT "_Z25tileAtWorldPositionLoadediiP5World"

// --- SELECTORS ---
#define SEL_DYN_WORLD   "dynamicWorld"
#define SEL_GET_PLANT   "getPlantAtPos:" 
#define SEL_REM_PLANT   "removePlantWithoutCreatingFreeblocks"

// Removers
#define SEL_REM_INT     "removeInteractionObjectAtPos:removeBlockhead:"
#define SEL_REM_BENCH   "removeWorkbenchAtPos:removeBlockhead:"
#define SEL_REM_COL     "removeColumnAtPos:"
#define SEL_REM_LAD     "removeLadderAtPos:"
#define SEL_REM_SHAFT   "removeElevatorShaftAtPos:"
#define SEL_REM_MOTOR   "removeElevatorMotorAtPos:"
#define SEL_REM_RAIL    "removeRailAtPos:"
#define SEL_REM_STAIR   "removeStairsAtPos:"
#define SEL_REM_DOOR    "removeDoorAtPos:"
#define SEL_REM_WIN     "removeWindowAtPos:"
#define SEL_REM_PAINT   "removePaintingAtPos:"
#define SEL_REM_TORCH   "removeTorchAtPos:"
#define SEL_REM_EGG     "removeEggAtPos:"
#define SEL_REM_WIRE    "removeWireAtPos:"
#define SEL_REM_WATER   "removeWaterTileAtPos:"
#define SEL_REM_BACK    "removeBackWallAtPos:removeBlockhead:"
#define SEL_REM_BG_CONT "removeAnyBackgroundContentsForTile:atPos:removeBlockhead:"
#define SEL_NUKE        "removeTileAtWorldX:worldY:createContentsFreeblockCount:createForegroundContentsFreeblockCount:removeBlockhead:onlyRemoveCOntents:onlyRemoveForegroundContents:sendWorldChangedNotifcation:dontRemoveContents:"

// Utils
#define SEL_FILL_LONG   "fillTile:atPos:withType:dataA:dataB:placedByClient:saveDict:placedByBlockhead:placedByClientName:"
#define SEL_CMD         "handleCommand:issueClient:"
#define SEL_CHAT        "sendChatMessage:sendToClients:"
#define SEL_UTF8        "UTF8String"
#define SEL_STR         "stringWithUTF8String:"

// Memory
#define SEL_ALLOC       "alloc"
#define SEL_INIT        "init"
#define SEL_DRAIN       "drain"

// --- CONSTANTS ---
#define WE_SAFE_ID  1 
#define WE_AIR_ID   2

enum WEMode { WE_OFF = 0, WE_MODE_P1, WE_MODE_P2 };

// --- STRUCTS ---
typedef struct { int x; int y; } WE_IntPair;

typedef struct {
    int fgID;      
    int contentID; 
    int dataA;     
} WE_BlockDef;

// --- IMP PROTOTYPES ---
typedef id   (*WE_GetDynWorldFunc)(id, SEL);
typedef id   (*WE_GetPlantFunc)(id, SEL, WE_IntPair); 
typedef void (*WE_RemPlantFunc)(id, SEL);   
typedef void (*WE_FillTileFunc)(id, SEL, void*, unsigned long long, int, uint16_t, uint16_t, id, id, id, id);
typedef void (*WE_RemTileFunc)(id, SEL, int, int, int, int, id, BOOL, BOOL, BOOL, BOOL);
typedef void (*WE_RemWaterFunc)(id, SEL, unsigned long long);
typedef void (*WE_RemBackFunc)(id, SEL, unsigned long long, id);
typedef void (*WE_RemBgContFunc)(id, SEL, void*, unsigned long long, id);
typedef id (*WE_DynRemFunc)(id, SEL, unsigned long long); 
typedef id (*WE_DynRemObjFunc)(id, SEL, unsigned long long, id); 
typedef id   (*WE_CmdFunc)(id, SEL, id, id);
typedef void (*WE_ChatFunc)(id, SEL, id, id);
typedef const char* (*WE_StrFunc)(id, SEL);
typedef id   (*WE_StrFactoryFunc)(id, SEL, const char*);
typedef void* (*WE_TileAtFunc)(int, int, id);

// Pool IMPs
typedef id   (*WE_AllocFunc)(id, SEL);
typedef id   (*WE_InitFunc)(id, SEL);
typedef void (*WE_DrainFunc)(id, SEL);

// --- GLOBAL STATE ---
static WE_FillTileFunc     WE_U_Real_Fill = NULL;
static WE_RemTileFunc      WE_U_Real_RemTile = NULL;
static WE_RemWaterFunc     WE_U_Real_RemWater = NULL;
static WE_RemBackFunc      WE_U_Real_RemBack = NULL;
static WE_RemBgContFunc    WE_U_Real_RemBgCont = NULL;
static WE_GetDynWorldFunc  WE_U_GetDynWorld = NULL;
static WE_CmdFunc          WE_U_Real_Cmd = NULL;
static WE_ChatFunc         WE_U_Real_Chat = NULL;
static WE_TileAtFunc       WE_U_CppTileAt = NULL;

static id WE_U_World = NULL;
static id WE_U_Server = NULL;

static int WE_U_Mode = WE_OFF;
static WE_IntPair WE_U_P1 = {0, 0};
static WE_IntPair WE_U_P2 = {0, 0};
static bool WE_U_HasP1 = false;
static bool WE_U_HasP2 = false;

// --- HELPERS ---
static const char* WE_GetStr(id strObj) {
    if (!strObj) return "";
    SEL sel = sel_registerName(SEL_UTF8);
    WE_StrFunc f = (WE_StrFunc)class_getMethodImplementation(object_getClass(strObj), sel);
    return f ? f(strObj, sel) : "";
}

static id WE_MkStr(const char* text) {
    Class cls = objc_getClass("NSString");
    SEL sel = sel_registerName(SEL_STR);
    WE_StrFactoryFunc f = (WE_StrFactoryFunc)method_getImplementation(class_getClassMethod(cls, sel));
    return f ? f((id)cls, sel, text) : NULL;
}

static void WE_Chat(const char* fmt, ...) {
    if (!WE_U_Server || !WE_U_Real_Chat) {
        printf("[WE_LOG] %s\n", fmt); return;
    }
    char buffer[256];
    va_list args;
    va_start(args, fmt);
    vsnprintf(buffer, sizeof(buffer), fmt, args);
    va_end(args);
    WE_U_Real_Chat(WE_U_Server, sel_registerName(SEL_CHAT), WE_MkStr(buffer), NULL);
}

// --- FULL PARSER ---
static WE_BlockDef WE_Parse(const char* input) {
    WE_BlockDef def = {WE_AIR_ID, 0, 0}; 
    if (isdigit(input[0])) { def.fgID = atoi(input); return def; }

    // === TILE TYPES ===
    if (strcasecmp(input, "rock") == 0)             { def.fgID = 0x1; return def; }
    if (strcasecmp(input, "stone") == 0)            { def.fgID = 0x1; return def; }
    if (strcasecmp(input, "air") == 0)              { def.fgID = 0x2; return def; }
    if (strcasecmp(input, "water") == 0)            { def.fgID = 0x3; def.dataA = 255; return def; }
    if (strcasecmp(input, "ice") == 0)              { def.fgID = 0x4; return def; }
    if (strcasecmp(input, "snow") == 0)             { def.fgID = 0x5; return def; }
    if (strcasecmp(input, "dirt") == 0)             { def.fgID = 0x6; return def; }
    if (strcasecmp(input, "sand") == 0)             { def.fgID = 0x7; return def; }
    if (strcasecmp(input, "beach") == 0)            { def.fgID = 0x8; return def; }
    if (strcasecmp(input, "wood") == 0)             { def.fgID = 0x9; return def; }
    if (strcasecmp(input, "cobblestone") == 0)      { def.fgID = 0xA; return def; }
    if (strcasecmp(input, "red_brick") == 0)        { def.fgID = 0xB; return def; }
    if (strcasecmp(input, "limestone") == 0)        { def.fgID = 0xC; return def; }
    if (strcasecmp(input, "limestone_block") == 0)  { def.fgID = 0xD; return def; }
    if (strcasecmp(input, "marble") == 0)           { def.fgID = 0xE; return def; }
    if (strcasecmp(input, "marble_block") == 0)     { def.fgID = 0xF; return def; }
    if (strcasecmp(input, "tc") == 0)               { def.fgID = 0x10; return def; }
    if (strcasecmp(input, "sandstone") == 0)        { def.fgID = 0x11; return def; }
    if (strcasecmp(input, "sandstone_block") == 0)  { def.fgID = 0x12; return def; }
    if (strcasecmp(input, "red_marble") == 0)       { def.fgID = 0x13; return def; }
    if (strcasecmp(input, "red_marble_block") == 0) { def.fgID = 0x14; return def; }
    if (strcasecmp(input, "flax_mat") == 0)         { def.fgID = 0x15; return def; }
    if (strcasecmp(input, "flax_mat_yellow") == 0)  { def.fgID = 0x16; return def; }
    if (strcasecmp(input, "flax_mat_red") == 0)     { def.fgID = 0x17; return def; }
    if (strcasecmp(input, "glass") == 0)            { def.fgID = 0x18; return def; }
    if (strcasecmp(input, "gold_block") == 0)       { def.fgID = 0x1A; return def; }
    if (strcasecmp(input, "dirt_grass") == 0)       { def.fgID = 0x1B; return def; }
    if (strcasecmp(input, "dirt_grass_frozen") == 0){ def.fgID = 0x1C; return def; }
    if (strcasecmp(input, "lapis") == 0)            { def.fgID = 0x1D; return def; }
    if (strcasecmp(input, "lapis_block") == 0)      { def.fgID = 0x1E; return def; }
    if (strcasecmp(input, "lava") == 0)             { def.fgID = 0x1F; def.dataA = 255; return def; }
    if (strcasecmp(input, "wood_plat") == 0)        { def.fgID = 0x20; return def; }
    if (strcasecmp(input, "compost") == 0)          { def.fgID = 0x30; return def; }
    if (strcasecmp(input, "compost_grass") == 0)    { def.fgID = 0x31; return def; }
    if (strcasecmp(input, "basalt") == 0)           { def.fgID = 0x33; return def; }
    if (strcasecmp(input, "basalt_block") == 0)     { def.fgID = 0x34; return def; }
    if (strcasecmp(input, "copper_block") == 0)     { def.fgID = 0x35; return def; }
    if (strcasecmp(input, "tin_block") == 0)        { def.fgID = 0x36; return def; }
    if (strcasecmp(input, "bronze_block") == 0)     { def.fgID = 0x37; return def; }
    if (strcasecmp(input, "iron_block") == 0)       { def.fgID = 0x38; return def; }
    if (strcasecmp(input, "steel_block") == 0)      { def.fgID = 0x39; return def; }
    if (strcasecmp(input, "black_sand") == 0)       { def.fgID = 0x3A; return def; }
    if (strcasecmp(input, "black_glass") == 0)      { def.fgID = 0x3B; return def; }
    if (strcasecmp(input, "leaves") == 0)           { def.fgID = 0x42; return def; }
    if (strcasecmp(input, "platinum_block") == 0)   { def.fgID = 0x43; return def; }
    if (strcasecmp(input, "titanium_block") == 0)   { def.fgID = 0x44; return def; }
    if (strcasecmp(input, "carbon_fiber") == 0)     { def.fgID = 0x45; return def; }
    if (strcasecmp(input, "gravel") == 0)           { def.fgID = 0x46; return def; }
    if (strcasecmp(input, "amethyst_block") == 0)   { def.fgID = 0x47; return def; }
    if (strcasecmp(input, "sapphire_block") == 0)   { def.fgID = 0x48; return def; }
    if (strcasecmp(input, "emerald_block") == 0)    { def.fgID = 0x49; return def; }
    if (strcasecmp(input, "ruby_block") == 0)       { def.fgID = 0x4A; return def; }
    if (strcasecmp(input, "diamond_block") == 0)    { def.fgID = 0x4B; return def; }
    if (strcasecmp(input, "plaster") == 0)          { def.fgID = 0x4C; return def; }
    if (strcasecmp(input, "lum_plaster") == 0)      { def.fgID = 0x4D; return def; }

    // === TILE CONTENTS (ORES) ===
    if (strcasecmp(input, "flint") == 0)      { def.fgID = 6; def.contentID = 0x1; return def; } 
    if (strcasecmp(input, "clay") == 0)       { def.fgID = 6; def.contentID = 0x2; return def; } 
    
    if (strcasecmp(input, "ruby") == 0)       { def.fgID = 1; def.contentID = 0x33; return def; } 
    if (strcasecmp(input, "emerald") == 0)    { def.fgID = 1; def.contentID = 0x35; return def; } 
    if (strcasecmp(input, "sapphire") == 0)   { def.fgID = 1; def.contentID = 0x37; return def; } 
    if (strcasecmp(input, "amethyst") == 0)   { def.fgID = 1; def.contentID = 0x39; return def; } 
    if (strcasecmp(input, "diamond") == 0)    { def.fgID = 1; def.contentID = 0x3B; return def; } 
    if (strcasecmp(input, "copper") == 0)     { def.fgID = 1; def.contentID = 0x3D; return def; } 
    if (strcasecmp(input, "tin") == 0)        { def.fgID = 1; def.contentID = 0x3E; return def; } 
    if (strcasecmp(input, "iron") == 0)       { def.fgID = 1; def.contentID = 0x3F; return def; } 
    if (strcasecmp(input, "coal") == 0)       { def.fgID = 1; def.contentID = 0x41; return def; } 
    if (strcasecmp(input, "gold") == 0)       { def.fgID = 1; def.contentID = 0x4D; return def; } 
    if (strcasecmp(input, "platinum") == 0)   { def.fgID = 1; def.contentID = 0x6A; return def; } 
    if (strcasecmp(input, "titanium") == 0)   { def.fgID = 1; def.contentID = 0x6B; return def; } 

    // Special Ores
    if (strcasecmp(input, "oil") == 0)        { def.fgID = 12; def.contentID = 0x40; return def; } 
    if (strcasecmp(input, "charcoal") == 0)   { def.fgID = 0;  def.contentID = 0x2D; return def; } 

    // === TILE CONTENTS (Objects) ===
    if (strcasecmp(input, "ladder") == 0)     { def.fgID = 0; def.contentID = 0x42; return def; }
    if (strcasecmp(input, "door") == 0)       { def.fgID = 0; def.contentID = 0x46; return def; }
    if (strcasecmp(input, "trapdoor") == 0)   { def.fgID = 0; def.contentID = 0x4B; return def; }
    if (strcasecmp(input, "window") == 0)     { def.fgID = 0; def.contentID = 0x45; return def; }
    if (strcasecmp(input, "black_window") == 0){def.fgID = 0; def.contentID = 0x5F; return def; }
    if (strcasecmp(input, "rail") == 0)       { def.fgID = 0; def.contentID = 0x62; return def; }
    if (strcasecmp(input, "column") == 0)     { def.fgID = 0; def.contentID = 0x64; return def; }
    if (strcasecmp(input, "stairs") == 0)     { def.fgID = 0; def.contentID = 0x65; return def; }
    if (strcasecmp(input, "wire") == 0)       { def.fgID = 0; def.contentID = 0x60; return def; }
    if (strcasecmp(input, "chest") == 0)      { def.fgID = 0; def.contentID = 0x156; return def; }
    if (strcasecmp(input, "safe") == 0)       { def.fgID = 0; def.contentID = 0x12A; return def; }
    if (strcasecmp(input, "shelf") == 0)      { def.fgID = 0; def.contentID = 0x77; return def; }
    if (strcasecmp(input, "sign") == 0)       { def.fgID = 0; def.contentID = 0xB0; return def; }
    if (strcasecmp(input, "bed") == 0)        { def.fgID = 0; def.contentID = 0xC9; return def; }
    if (strcasecmp(input, "gold_bed") == 0)   { def.fgID = 0; def.contentID = 0x132; return def; }
    
    // Tech
    if (strcasecmp(input, "workbench") == 0)           { def.fgID = 0; def.contentID = 0x2E; return def; }
    if (strcasecmp(input, "portal") == 0)              { def.fgID = 0; def.contentID = 0x64; return def; }
    if (strcasecmp(input, "press") == 0)               { def.fgID = 0; def.contentID = 0x154; return def; }
    if (strcasecmp(input, "furnace") == 0)             { def.fgID = 0; def.contentID = 0x144; return def; }
    if (strcasecmp(input, "kiln") == 0)                { def.fgID = 0; def.contentID = 0x158; return def; }
    if (strcasecmp(input, "steam_generator") == 0)     { def.fgID = 0; def.contentID = 0x13B; return def; }
    if (strcasecmp(input, "electric_kiln") == 0)       { def.fgID = 0; def.contentID = 0x13D; return def; }
    if (strcasecmp(input, "electric_furnace") == 0)    { def.fgID = 0; def.contentID = 0x1DA; return def; }
    if (strcasecmp(input, "electric_stove") == 0)      { def.fgID = 0; def.contentID = 0x220; return def; }
    if (strcasecmp(input, "solar_panel") == 0)         { def.fgID = 0; def.contentID = 0x223; return def; }
    if (strcasecmp(input, "flywheel") == 0)            { def.fgID = 0; def.contentID = 0x225; return def; }
    if (strcasecmp(input, "electric_metal_bench") == 0){ def.fgID = 0; def.contentID = 0x1DC; return def; }
    if (strcasecmp(input, "egg_extractor") == 0)       { def.fgID = 0; def.contentID = 0x2E0; return def; }
    if (strcasecmp(input, "pizza_oven") == 0)          { def.fgID = 0; def.contentID = 0x2E3; return def; }
    if (strcasecmp(input, "refinery") == 0)            { def.fgID = 0; def.contentID = 0xBD; return def; } 
    
    // Lights
    if (strcasecmp(input, "torch") == 0)         { def.fgID = 0; def.contentID = 0x31; return def; }
    if (strcasecmp(input, "lantern") == 0)       { def.fgID = 0; def.contentID = 0x32; return def; }
    if (strcasecmp(input, "steel_lantern") == 0) { def.fgID = 0; def.contentID = 0x57; return def; }
    if (strcasecmp(input, "ice_torch") == 0)     { def.fgID = 0; def.contentID = 0x61; return def; }
    if (strcasecmp(input, "chandelier_ame") == 0){ def.fgID = 0; def.contentID = 0x52; return def; }
    if (strcasecmp(input, "chandelier_sap") == 0){ def.fgID = 0; def.contentID = 0x53; return def; }
    if (strcasecmp(input, "chandelier_eme") == 0){ def.fgID = 0; def.contentID = 0x54; return def; }
    if (strcasecmp(input, "chandelier_rub") == 0){ def.fgID = 0; def.contentID = 0x55; return def; }
    if (strcasecmp(input, "chandelier_dia") == 0){ def.fgID = 0; def.contentID = 0x56; return def; }
    if (strcasecmp(input, "steel_downlight") == 0){ def.fgID = 0; def.contentID = 0x66; return def; }
    if (strcasecmp(input, "steel_uplight") == 0)  { def.fgID = 0; def.contentID = 0x69; return def; }

    def.fgID = 1; return def;
}

static void* WE_GetPtr(WE_IntPair pos) {
    if (!WE_U_CppTileAt || !WE_U_World) return NULL;
    if (pos.y < 0 || pos.y > 1024) return NULL;
    return WE_U_CppTileAt(pos.x, pos.y, WE_U_World);
}

// --- CORE LOGIC: NUKE ---

static void WE_RunDynRemover(id dynWorld, const char* selName, unsigned long long packedPos) {
    SEL sel = sel_registerName(selName);
    if (!class_getInstanceMethod(object_getClass(dynWorld), sel)) return;
    WE_DynRemFunc f = (WE_DynRemFunc)method_getImplementation(class_getInstanceMethod(object_getClass(dynWorld), sel));
    if (f) f(dynWorld, sel, packedPos);
}

static void WE_RunDynRemoverObj(id dynWorld, const char* selName, unsigned long long packedPos) {
    SEL sel = sel_registerName(selName);
    if (!class_getInstanceMethod(object_getClass(dynWorld), sel)) return;
    WE_DynRemObjFunc f = (WE_DynRemObjFunc)method_getImplementation(class_getInstanceMethod(object_getClass(dynWorld), sel));
    if (f) f(dynWorld, sel, packedPos, nil);
}

static void WE_KillPlant(id dynWorld, WE_IntPair pos) {
    SEL selGet = sel_registerName(SEL_GET_PLANT);
    SEL selRem = sel_registerName(SEL_REM_PLANT);
    
    if (!class_getInstanceMethod(object_getClass(dynWorld), selGet)) return;

    WE_GetPlantFunc getFunc = (WE_GetPlantFunc)method_getImplementation(class_getInstanceMethod(object_getClass(dynWorld), selGet));
    id plantObj = getFunc(dynWorld, selGet, pos);

    if (plantObj) {
        WE_RemPlantFunc remFunc = (WE_RemPlantFunc)method_getImplementation(class_getInstanceMethod(object_getClass(plantObj), selRem));
        if (remFunc) remFunc(plantObj, selRem);
    }
}

static void WE_U_Nuke(WE_IntPair pos) {
    if (!WE_U_World) return;
    unsigned long long packedPos = ((unsigned long long)pos.y << 32) | (unsigned int)pos.x;
    
    id dynWorld = nil;
    if (WE_U_GetDynWorld) {
        dynWorld = WE_U_GetDynWorld(WE_U_World, sel_registerName(SEL_DYN_WORLD));
    }

    if (dynWorld) WE_KillPlant(dynWorld, pos);

    if (dynWorld) {
        WE_RunDynRemover(dynWorld, SEL_REM_COL, packedPos);
        WE_RunDynRemover(dynWorld, SEL_REM_LAD, packedPos);
        WE_RunDynRemover(dynWorld, SEL_REM_RAIL, packedPos);
        WE_RunDynRemover(dynWorld, SEL_REM_STAIR, packedPos);
        WE_RunDynRemover(dynWorld, SEL_REM_SHAFT, packedPos);
        WE_RunDynRemover(dynWorld, SEL_REM_MOTOR, packedPos);
        WE_RunDynRemover(dynWorld, SEL_REM_WIRE, packedPos);
        WE_RunDynRemover(dynWorld, SEL_REM_DOOR, packedPos);
        WE_RunDynRemover(dynWorld, SEL_REM_WIN, packedPos);
        WE_RunDynRemover(dynWorld, SEL_REM_PAINT, packedPos);
        WE_RunDynRemover(dynWorld, SEL_REM_TORCH, packedPos);
        WE_RunDynRemover(dynWorld, SEL_REM_EGG, packedPos);
        WE_RunDynRemoverObj(dynWorld, SEL_REM_BENCH, packedPos);
        WE_RunDynRemoverObj(dynWorld, SEL_REM_INT, packedPos);
    }

    void* tilePtr = WE_GetPtr(pos);
    if (WE_U_Real_RemBgCont && tilePtr) {
        WE_U_Real_RemBgCont(WE_U_World, sel_registerName(SEL_REM_BG_CONT), tilePtr, packedPos, nil);
    }
    if (WE_U_Real_RemWater) {
        WE_U_Real_RemWater(WE_U_World, sel_registerName(SEL_REM_WATER), packedPos);
    }

    if (WE_U_Real_RemBack) {
        WE_U_Real_RemBack(WE_U_World, sel_registerName(SEL_REM_BACK), packedPos, nil);
    }

    if (WE_U_Real_RemTile) {
        WE_U_Real_RemTile(WE_U_World, sel_registerName(SEL_NUKE), 
                          pos.x, pos.y, 
                          0, 0, NULL, 
                          false, false, true, false);
    }
}

// --- OPERATIONS ---

static void WE_U_Place(WE_IntPair pos, WE_BlockDef def, id client, id safeStr) {
    if (!WE_U_Real_Fill || !WE_U_World) return;
    
    unsigned long long packedPos = ((unsigned long long)pos.y << 32) | (unsigned int)pos.x;

    // 1. SAFE INIT (Use Stone/ID 1)
    // IMPORTANT: Pass 'client' and 'safeStr' (from Outer Pool)
    WE_U_Real_Fill(WE_U_World, sel_registerName(SEL_FILL_LONG), 
                   NULL, packedPos, WE_SAFE_ID, def.dataA, 0, 
                   client, NULL, NULL, safeStr);

    // 2. DIRTY WRITE (Universal Overwrite)
    void* tilePtr = WE_GetPtr(pos);
    if (tilePtr) {
        uint8_t* raw = (uint8_t*)tilePtr;
        raw[0] = (uint8_t)def.fgID; 
        raw[3] = (uint8_t)def.contentID;
    }
}

static void WE_U_RunOp(int operation, WE_BlockDef def1, WE_BlockDef def2, id client) {
    if (!WE_U_HasP1 || !WE_U_HasP2) { WE_Chat("[WE] Error: Set P1 & P2 first."); return; }
    
    int x1 = (WE_U_P1.x < WE_U_P2.x) ? WE_U_P1.x : WE_U_P2.x;
    int x2 = (WE_U_P1.x > WE_U_P2.x) ? WE_U_P1.x : WE_U_P2.x;
    int y1 = (WE_U_P1.y < WE_U_P2.y) ? WE_U_P1.y : WE_U_P2.y;
    int y2 = (WE_U_P1.y > WE_U_P2.y) ? WE_U_P1.y : WE_U_P2.y;
    
    int totalBlocks = (abs(x2 - x1) + 1) * (abs(y2 - y1) + 1);
    
    // === LIMITS CAP ===
    int limit = 2000000;
    if (operation == 1) limit = 25000; // DEL limit
    if (operation == 2) limit = 5000;  // SET limit

    if (totalBlocks > limit) {
        WE_Chat("[WE] Error: Selection too large (%d blocks). Max for this command is %d.", totalBlocks, limit);
        return;
    }

    int count = 0;
    if (!WE_U_CppTileAt) { WE_Chat("[WE] Critical: Reader Error."); return; }

    WE_Chat("[WE] Processing area...");

    // === MEMORY MANAGEMENT (CRASH FIX - Outer Pool) ===
    Class PoolClass = objc_getClass("NSAutoreleasePool");
    if (!PoolClass) { printf("[WE] Fatal: NSAutoreleasePool not found.\n"); return; }

    SEL selAlloc = sel_registerName(SEL_ALLOC);
    SEL selInit = sel_registerName(SEL_INIT);
    SEL selDrain = sel_registerName(SEL_DRAIN);

    WE_AllocFunc impAlloc = (WE_AllocFunc)method_getImplementation(class_getClassMethod(PoolClass, selAlloc));
    WE_InitFunc impInit = (WE_InitFunc)method_getImplementation(class_getInstanceMethod(PoolClass, selInit));
    WE_DrainFunc impDrain = (WE_DrainFunc)method_getImplementation(class_getInstanceMethod(PoolClass, selDrain));

    // 1. OUTER POOL: Holds long-living objects like 'safeStr'
    id outerPool = impInit(impAlloc((id)PoolClass, selAlloc), selInit);

    // 2. SAFE STRING: Created in Outer Pool scope
    id safeStr = WE_MkStr("WE");

    // 3. INNER POOL: For garbage collection inside the loop
    id innerPool = impInit(impAlloc((id)PoolClass, selAlloc), selInit);

    for (int x = x1; x <= x2; x++) {
        for (int y = y1; y <= y2; y++) {
            
            // Garbage Collection every 100 blocks
            if (count % 100 == 0 && count > 0) {
                impDrain(innerPool, selDrain); 
                innerPool = impInit(impAlloc((id)PoolClass, selAlloc), selInit);
            }

            WE_IntPair currentPos = {x, y};
            void* tilePtr = WE_GetPtr(currentPos);
            
            int currentID = WE_AIR_ID;
            int currentContent = 0;

            if (tilePtr) {
                uint8_t* raw = (uint8_t*)tilePtr;
                currentID = raw[0];
                currentContent = raw[3];
            }

            // DEL
            if (operation == 1) { 
                bool shouldDelete = false;
                if (def1.fgID == -1) shouldDelete = true; 
                else {
                    if (def1.contentID > 0) {
                        if (currentID == def1.fgID && currentContent == def1.contentID) shouldDelete = true;
                    } else {
                        if (currentID == def1.fgID) shouldDelete = true;
                    }
                }
                if (shouldDelete) { WE_U_Nuke(currentPos); count++; }
            }
            // SET (LAG FIX: Force Nuke + Place)
            else if (operation == 2) { 
                // NO Smart Fill. Force replace everything.
                WE_U_Nuke(currentPos);
                WE_U_Place(currentPos, def1, client, safeStr);
                count++;
            }
            // REPLACE (Crash Fix logic)
            else if (operation == 3) { 
                bool match = false;
                if (def1.fgID == WE_AIR_ID && currentID == 2) match = true;
                else if (def1.contentID > 0) {
                    if (currentID == def1.fgID && currentContent == def1.contentID) match = true;
                } else {
                    if (currentID == def1.fgID) match = true;
                }
                
                if (match) {
                    if (currentID != WE_AIR_ID) {
                        WE_U_Nuke(currentPos);
                    }
                    WE_U_Place(currentPos, def2, client, safeStr);
                    count++;
                }
            }
        }
    }
    
    // Cleanup Pools
    impDrain(innerPool, selDrain); 
    impDrain(outerPool, selDrain); // Safe string dies here, safely

    WE_Chat("[WE] Done. Modified %d blocks.", count);
}

// --- HOOKS ---

void WE_U_Hook_Fill(id self, SEL _cmd, void* tilePtr, unsigned long long packedPos, int type, uint16_t dA, uint16_t dB, id client, id saveDict, id bh, id clientName) {
    if (WE_U_World == NULL) { WE_U_World = self; }
    int x = (int)(packedPos & 0xFFFFFFFF);
    int y = (int)(packedPos >> 32);
    WE_IntPair pos = {x, y};

    if (WE_U_Mode == WE_MODE_P1 && (type == 1 || type == 1024)) {
        WE_U_P1 = pos; WE_U_HasP1 = true; WE_U_Mode = WE_OFF;
        
        if (WE_U_HasP2) {
            int area = (abs(WE_U_P1.x - WE_U_P2.x) + 1) * (abs(WE_U_P1.y - WE_U_P2.y) + 1);
            WE_Chat("[WE] Point 1 set. Selection area: %d blocks.", area);
        } else {
            WE_Chat("[WE] Point 1 set at (%d, %d).", x, y);
        }
    }
    else if (WE_U_Mode == WE_MODE_P2 && (type == 1 || type == 1024)) {
        WE_U_P2 = pos; WE_U_HasP2 = true; WE_U_Mode = WE_OFF;
        
        if (WE_U_HasP1) {
            int area = (abs(WE_U_P1.x - WE_U_P2.x) + 1) * (abs(WE_U_P1.y - WE_U_P2.y) + 1);
            WE_Chat("[WE] Point 2 set. Selection area: %d blocks.", area);
        } else {
            WE_Chat("[WE] Point 2 set at (%d, %d).", x, y);
        }
    }
    if (WE_U_Real_Fill) WE_U_Real_Fill(self, _cmd, tilePtr, packedPos, type, dA, dB, client, saveDict, bh, clientName);
}

bool WE_IsCommand(const char* text, const char* cmd) {
    size_t cmdLen = strlen(cmd);
    if (strncmp(text, cmd, cmdLen) != 0) return false;
    return (text[cmdLen] == ' ' || text[cmdLen] == '\0');
}

id WE_U_Hook_Cmd(id self, SEL _cmd, id commandStr, id client) {
    WE_U_Server = self; 
    const char* raw = WE_GetStr(commandStr);
    if (!raw) return WE_U_Real_Cmd(self, _cmd, commandStr, client);
    char text[256]; strncpy(text, raw, 255); text[255] = 0;

    if (strcasecmp(text, "/we") == 0) {
        WE_U_Mode = WE_OFF; WE_U_HasP1 = false; WE_U_HasP2 = false;
        WE_Chat("[WE] Selection cleared."); return NULL;
    }
    if (strcasecmp(text, "/p1") == 0) { WE_U_Mode = WE_MODE_P1; WE_Chat("[WE] Place a block to set Point 1."); return NULL; }
    if (strcasecmp(text, "/p2") == 0) { WE_U_Mode = WE_MODE_P2; WE_Chat("[WE] Place a block to set Point 2."); return NULL; }

    if (WE_IsCommand(text, "/del")) {
        char* token = strtok(text, " "); char* arg = strtok(NULL, " "); 
        WE_BlockDef target = arg ? WE_Parse(arg) : (WE_BlockDef){-1,0,0};
        WE_Chat("[WE] Deleting %s...", arg ? arg : "selection");
        WE_BlockDef dummy = {0}; WE_U_RunOp(1, target, dummy, client); return NULL;
    }
    
    if (WE_IsCommand(text, "/set")) {
        char* token = strtok(text, " "); char* arg = strtok(NULL, " ");
        if (arg) { 
            WE_Chat("[WE] Setting %s...", arg);
            WE_BlockDef def = WE_Parse(arg); WE_BlockDef dummy = {0}; 
            WE_U_RunOp(2, def, dummy, client); 
        } else WE_Chat("[WE] Usage: /set <block>");
        return NULL;
    }

    if (WE_IsCommand(text, "/replace")) {
        char* token = strtok(text, " "); char* arg1 = strtok(NULL, " "); char* arg2 = strtok(NULL, " ");
        if (arg1 && arg2) {
             WE_BlockDef d1 = WE_Parse(arg1); WE_BlockDef d2 = WE_Parse(arg2);
             WE_U_RunOp(3, d1, d2, client);
        } else WE_Chat("[WE] Usage: /replace <old> <new>");
        return NULL;
    }

    return WE_U_Real_Cmd(self, _cmd, commandStr, client);
}

static void* WE_U_Init(void* arg) {
    sleep(1);
    void* handle = dlopen(NULL, RTLD_LAZY);
    if (handle) {
        WE_U_CppTileAt = (WE_TileAtFunc)dlsym(handle, SYM_TILE_AT);
        dlclose(handle);
    }
    
    Class clsWorld = objc_getClass(TARGET_WORLD_CLASS);
    if (clsWorld) {
        Method mFill = class_getInstanceMethod(clsWorld, sel_registerName(SEL_FILL_LONG));
        if (mFill) {
            WE_U_Real_Fill = (WE_FillTileFunc)method_getImplementation(mFill);
            method_setImplementation(mFill, (IMP)WE_U_Hook_Fill);
        }
        
        Method mNuke = class_getInstanceMethod(clsWorld, sel_registerName(SEL_NUKE));
        if (mNuke) WE_U_Real_RemTile = (WE_RemTileFunc)method_getImplementation(mNuke);
        
        Method mWater = class_getInstanceMethod(clsWorld, sel_registerName(SEL_REM_WATER));
        if (mWater) WE_U_Real_RemWater = (WE_RemWaterFunc)method_getImplementation(mWater);

        Method mBack = class_getInstanceMethod(clsWorld, sel_registerName(SEL_REM_BACK));
        if (mBack) WE_U_Real_RemBack = (WE_RemBackFunc)method_getImplementation(mBack);

        Method mBgCont = class_getInstanceMethod(clsWorld, sel_registerName(SEL_REM_BG_CONT));
        if (mBgCont) WE_U_Real_RemBgCont = (WE_RemBgContFunc)method_getImplementation(mBgCont);

        Method mDyn = class_getInstanceMethod(clsWorld, sel_registerName(SEL_DYN_WORLD));
        if (mDyn) WE_U_GetDynWorld = (WE_GetDynWorldFunc)method_getImplementation(mDyn);

        printf("[WE] Hooks Loaded.\n");
    }
    
    Class clsServer = objc_getClass(TARGET_SERVER_CLASS);
    if (clsServer) {
        Method mCmd = class_getInstanceMethod(clsServer, sel_registerName(SEL_CMD));
        WE_U_Real_Cmd = (WE_CmdFunc)method_getImplementation(mCmd);
        method_setImplementation(mCmd, (IMP)WE_U_Hook_Cmd);
        Method mChat = class_getInstanceMethod(clsServer, sel_registerName(SEL_CHAT));
        WE_U_Real_Chat = (WE_ChatFunc)method_getImplementation(mChat);
    }
    return NULL;
}

__attribute__((constructor)) static void WE_U_Entry() {
    pthread_t t; pthread_create(&t, NULL, WE_U_Init, NULL);
}
