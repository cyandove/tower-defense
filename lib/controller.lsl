// =============================================================================
// controller.lsl
// Tower Defense Controller  -  Phase 7
// =============================================================================
// The controller is the only object placed manually in-world. Everything
// else is rezzed by the controller at setup and cleaned up on game over.
//
// RESPONSIBILITIES:
//   - Map definition, storage, and cell-state authority
//   - Waypoint derivation from path cells (chain-follow algorithm)
//   - Object layout: rezzes GM, placement handler, spawner at correct positions
//   - Post-rez configuration: sends GM_CONFIG and SPAWNER_CONFIG messages
//   - Game lifecycle: SETUP -> WAITING -> WAVE_ACTIVE -> WAVE_CLEAR -> GAME_OVER
//   - Wave progression: escalating enemy counts per wave
//   - Lives and score tracking (moved from GM)
//   - Cleanup: derezzes all managed objects on game over or reset
//
// CHANNEL MAP:
//   -2001  GM_REGISTER         (listened by GM, used by all clients)
//   -2002  GM_DEREGISTER
//   -2003  HEARTBEAT
//   -2004  PLACEMENT
//   -2005  TOWER_REPORT
//   -2006  ENEMY_REPORT
//   -2007  GM_DISCOVERY
//   -2008  PLACEMENT_RESPONSE
//   -2009  SPAWNER
//   -2010  ENEMY
//   -2011  GRID_INFO
//   -2012  TOWER_PLACE
//   -2013  CONTROLLER          (controller <-> GM and controller -> spawner)
//
// SETUP:
//   1. Place this prim at the south-west corner of the intended grid area.
//      Its position becomes gGridOrigin  -  the (0,0) cell corner.
//   2. Add to this prim's inventory:
//        "GameManager"       -  the GM prim object
//        "PlacementHandler"  -  the placement handler prim object
//        "Spawner"           -  the spawner prim object
//   3. Touch to begin setup. The controller rezzes all objects, configures
//      them, and waits for registration. Touch again once WAITING to start
//      the first wave.
//
// MAP DEFINITIONS:
//   Maps are defined as functions returning pre-encoded row lists.
//   To add a map: add a new loadMap_N() function and a branch in loadMap().
//   Each row is 10 cells x stride-3 = 30 integers: [type, occupied, 0, ...]
//   Cell types: 0=blocked  1=buildable  2=path
//   Entry cell: the path cell on y=0 (top row)  -  seed for waypoint derivation.
// =============================================================================


// -----------------------------------------------------------------------------
// ANIMATION EVENT IDS — shared with controller-animations.lsl
// -----------------------------------------------------------------------------
integer ANIM_STATE = 300;


// -----------------------------------------------------------------------------
// CONTROLLER CHANNEL
// -----------------------------------------------------------------------------
integer CTRL = -2013;


// -----------------------------------------------------------------------------
// DEBUG
// -----------------------------------------------------------------------------
integer DEBUG         = FALSE;   // compile-time default — flip before pasting for verbose mode
integer gDebug        = FALSE;   // runtime toggle
integer DBG_CHANNEL = -2099;   // owner-only debug toggle broadcast


// -----------------------------------------------------------------------------
// GRID GEOMETRY
// Set CELL_SIZE to match your intended in-world scale.
// The controller prim's position is used as gGridOrigin.
// -----------------------------------------------------------------------------
float   CELL_SIZE  = 2.0;
integer MAP_W      = 10;
integer MAP_H      = 10;


// -----------------------------------------------------------------------------
// WAVE PROGRESSION
//   Wave N spawns: WAVE_BASE + (N-1) * WAVE_INCREMENT enemies
//   e.g. wave 1=3, wave 2=5, wave 3=7 ...
// -----------------------------------------------------------------------------
integer WAVE_BASE       = 3;
integer WAVE_INCREMENT  = 2;
integer WAVE_CLEAR_DELAY = 5;   // seconds between wave clear and next wave start


// -----------------------------------------------------------------------------
// GAME SETTINGS
// -----------------------------------------------------------------------------
integer STARTING_LIVES      = 20;
integer MENU_DIALOG_TIMEOUT = 30;   // seconds before an unanswered dialog is culled


// -----------------------------------------------------------------------------
// INVENTORY NAMES  -  must match prim names in this object's inventory
// -----------------------------------------------------------------------------
string INV_GM        = "GameManager";
string INV_HANDLER   = "PlacementHandler";
string INV_SPAWNER   = "Spawner";
string INV_BUILDER   = "MapBuilder";
string INV_MAP_BOARD = "MapBoard";


// -----------------------------------------------------------------------------
// MAP TILE CHANNEL
// -----------------------------------------------------------------------------
integer MAP_TILE = -2014;


// -----------------------------------------------------------------------------
// LIFECYCLE STATES
// -----------------------------------------------------------------------------
integer STATE_IDLE       = 0;
integer STATE_SETUP      = 1;
integer STATE_WAITING    = 2;
integer STATE_WAVE       = 3;
integer STATE_WAVE_CLEAR = 4;
integer STATE_GAME_OVER  = 5;


// -----------------------------------------------------------------------------
// GLOBAL STATE
// -----------------------------------------------------------------------------
list    gMap          = [];   // [type, occupied, 0, ...]  stride=3, 300 entries
list    gWaypoints    = [];   // world-space vectors derived from path cells
vector  gGridOrigin   = ZERO_VECTOR;
key     gGM_Key       = NULL_KEY;
key     gSpawner_Key  = NULL_KEY;
key     gHandler_Key  = NULL_KEY;
key     gBuilder_Key  = NULL_KEY;
key     gBoard_Key    = NULL_KEY;
integer gLifecycle    = 0;    // STATE_* value
integer gLives        = 0;
integer gScore        = 0;
integer gWaveNum      = 0;
integer gEnemiesOut   = 0;    // enemies currently alive this wave
integer gWaveClearTimer = 0;  // countdown ticks for WAVE_CLEAR delay
integer gSetupPending = 0;    // objects rezzed but not yet registered
integer gMenuChannel  = 0;    // derived from prim key in state_entry
list    gMenuDialogs  = [];   // [handle, avatar_key, expiry]  stride=3


// =============================================================================
// DEBUG HELPER
// =============================================================================

dbg(string msg)
{
    if (gDebug) llOwnerSay(msg);
}


// =============================================================================
// MAP DEFINITIONS
// =============================================================================
// Each loadMap_N() appends the full 300-entry map to gMap as 10 row literals.
// No setCell() calls  -  pre-encoded to avoid any llListReplaceList at init time.
// Returns the entry cell x coordinate (entry is always on y=0 for this map set).

integer loadMap_1()
{
    // Map 1  -  S-bend path
    // y0: X X P B B B B B B B
    // y1: B B P B B B B B B B
    // y2: B B P B B B B B B B
    // y3: B B P B B B B B B B
    // y4: B B P P P P P P B B
    // y5: B B B B B B B P B B
    // y6: B B B B B B B P B B
    // y7: B B P P P P P P B B
    // y8: B B P B B B B B B B
    // y9: B B P B B B B B X X
    gMap = [];
    gMap += [0,0,0, 0,0,0, 2,0,0, 1,0,0, 1,0,0, 1,0,0, 1,0,0, 1,0,0, 1,0,0, 1,0,0];
    gMap += [1,0,0, 1,0,0, 2,0,0, 1,0,0, 1,0,0, 1,0,0, 1,0,0, 1,0,0, 1,0,0, 1,0,0];
    gMap += [1,0,0, 1,0,0, 2,0,0, 1,0,0, 1,0,0, 1,0,0, 1,0,0, 1,0,0, 1,0,0, 1,0,0];
    gMap += [1,0,0, 1,0,0, 2,0,0, 1,0,0, 1,0,0, 1,0,0, 1,0,0, 1,0,0, 1,0,0, 1,0,0];
    gMap += [1,0,0, 1,0,0, 2,0,0, 2,0,0, 2,0,0, 2,0,0, 2,0,0, 2,0,0, 1,0,0, 1,0,0];
    gMap += [1,0,0, 1,0,0, 1,0,0, 1,0,0, 1,0,0, 1,0,0, 1,0,0, 2,0,0, 1,0,0, 1,0,0];
    gMap += [1,0,0, 1,0,0, 1,0,0, 1,0,0, 1,0,0, 1,0,0, 1,0,0, 2,0,0, 1,0,0, 1,0,0];
    gMap += [1,0,0, 1,0,0, 2,0,0, 2,0,0, 2,0,0, 2,0,0, 2,0,0, 2,0,0, 1,0,0, 1,0,0];
    gMap += [1,0,0, 1,0,0, 2,0,0, 1,0,0, 1,0,0, 1,0,0, 1,0,0, 1,0,0, 1,0,0, 1,0,0];
    gMap += [1,0,0, 1,0,0, 2,0,0, 1,0,0, 1,0,0, 1,0,0, 1,0,0, 1,0,0, 0,0,0, 0,0,0];
    return 2;   // entry cell x on y=0
}

// Stub for a second map  -  add row data here when ready.
// integer loadMap_2() { gMap = []; gMap += [...]; ... return entry_x; }

loadMap(integer map_id)
{
    integer entry_x;
    if (map_id == 1) entry_x = loadMap_1();
    else             entry_x = loadMap_1();   // fallback to map 1

    dbg("[CTL] Map " + (string)map_id + " loaded. Mem: "
        + (string)llGetFreeMemory() + "b");

    deriveWaypoints(entry_x, 0);
}


// =============================================================================
// MAP HELPERS
// =============================================================================

integer cellIdx(integer x, integer y) { return (y * MAP_W + x) * 3; }

integer inBounds(integer x, integer y)
{
    return (x >= 0 && x < MAP_W && y >= 0 && y < MAP_H);
}

integer cellType(integer x, integer y)
{
    if (!inBounds(x, y)) return 0;
    return llList2Integer(gMap, cellIdx(x, y));
}

integer cellOccupied(integer x, integer y)
{
    if (!inBounds(x, y)) return 1;
    return llList2Integer(gMap, cellIdx(x, y) + 1);
}

setCellOccupied(integer x, integer y, integer flag)
{
    if (!inBounds(x, y)) return;
    integer i = cellIdx(x, y) + 1;
    gMap = llListReplaceList(gMap, [flag], i, i);
}

// Cell types used as string tokens in CELL_DATA responses
string cellTypeStr(integer t)
{
    if (t == 2) return "path";
    if (t == 1) return "build";
    return "blocked";
}

vector cellToWorld(integer gx, integer gy)
{
    return <gGridOrigin.x + (gx + 0.5) * CELL_SIZE,
            gGridOrigin.y + (gy + 0.5) * CELL_SIZE,
            gGridOrigin.z + 0.5>;
}


// =============================================================================
// WAYPOINT DERIVATION
// Chain-follow from the entry cell. At each step find the one unvisited
// adjacent path cell and move to it. Stop when we reach the map boundary
// (the exit cell). Diagonal movement is not used  -  path is 4-connected.
// =============================================================================

// Returns TRUE if (nx,ny) is a valid unvisited path neighbour.
integer isValidStep(integer nx, integer ny, integer px, integer py)
{
    if (nx == px && ny == py)  return FALSE;
    if (!inBounds(nx, ny))     return FALSE;
    if (cellType(nx, ny) != 2) return FALSE;
    return TRUE;
}

deriveWaypoints(integer entry_x, integer entry_y)
{
    gWaypoints = [];
    integer cx = entry_x;
    integer cy = entry_y;
    integer px = -1;   // previous cell - prevents backtracking
    integer py = -1;

    integer safety = MAP_W * MAP_H;
    integer steps;
    for (steps = 0; steps < safety; steps++)
    {
        gWaypoints += [cellToWorld(cx, cy)];

        // Try each cardinal neighbour: N E S W
        // All four checks use the same px/py before committing the move.
        integer found = FALSE;
        integer ncx = cx;
        integer ncy = cy;

        if (!found && isValidStep(cx, cy-1, px, py))
            { ncx = cx;   ncy = cy-1; found = TRUE; }
        if (!found && isValidStep(cx+1, cy, px, py))
            { ncx = cx+1; ncy = cy;   found = TRUE; }
        if (!found && isValidStep(cx, cy+1, px, py))
            { ncx = cx;   ncy = cy+1; found = TRUE; }
        if (!found && isValidStep(cx-1, cy, px, py))
            { ncx = cx-1; ncy = cy;   found = TRUE; }

        if (!found)
        {
            steps = safety;   // dead end - exit loop
        }
        else
        {
            px = cx; py = cy;
            cx = ncx; cy = ncy;
        }
    }

    dbg("[CTL] Derived " + (string)llGetListLength(gWaypoints)
        + " waypoints.");
}

// Serialise gWaypoints to the semicolon:colon format the spawner expects:
// "x1:y1:z1;x2:y2:z2;..."
string buildWaypointString()
{
    string result = "";
    integer count = llGetListLength(gWaypoints);
    integer i;
    for (i = 0; i < count; i++)
    {
        vector wp = llList2Vector(gWaypoints, i);
        if (result != "") result += ";";
        result += (string)wp.x + ":" + (string)wp.y + ":" + (string)wp.z;
    }
    return result;
}


// =============================================================================
// OBJECT LAYOUT AND REZZING
// =============================================================================

// Returns the world position for a grid cell, used when rezzing objects.
// The spawner sits at the entry cell; the handler covers the full grid.
vector entryWorldPos()
{
    // First path cell on y=0  -  scan left to right
    integer x;
    for (x = 0; x < MAP_W; x++)
        if (cellType(x, 0) == 2) return cellToWorld(x, 0);
    return gGridOrigin;   // fallback
}

rezAllObjects()
{
    if (llGetInventoryType(INV_GM) == INVENTORY_NONE)
    { llOwnerSay("[CTL] Missing inventory: " + INV_GM); return; }
    if (llGetInventoryType(INV_HANDLER) == INVENTORY_NONE)
    { llOwnerSay("[CTL] Missing inventory: " + INV_HANDLER); return; }
    if (llGetInventoryType(INV_SPAWNER) == INVENTORY_NONE)
    { llOwnerSay("[CTL] Missing inventory: " + INV_SPAWNER); return; }

    // Rez all objects near the controller (within 10m limit).
    // Each object will move itself to its correct position after receiving
    // its config message containing the target position.
    vector rez_pos = llGetPos() + <0.0, 0.0, 0.5>;

    llRezObject(INV_GM, rez_pos, ZERO_VECTOR, ZERO_ROTATION, 0);
    dbg("[CTL] Rezzed GM near controller.");

    llRezObject(INV_HANDLER, rez_pos, ZERO_VECTOR, ZERO_ROTATION, 0);
    dbg("[CTL] Rezzed handler near controller.");

    llRezObject(INV_SPAWNER, rez_pos, ZERO_VECTOR, ZERO_ROTATION, 0);
    dbg("[CTL] Rezzed spawner near controller.");

    if (llGetInventoryType(INV_MAP_BOARD) != INVENTORY_NONE)
    {
        llRezObject(INV_MAP_BOARD, rez_pos, ZERO_VECTOR, ZERO_ROTATION, 99999);
        dbg("[CTL] Rezzed MapBoard.");
    }

    gSetupPending = 3;   // waiting for GM + handler + spawner to register
    gLifecycle    = STATE_SETUP;
}

// Called when a new object registers with the GM and the GM notifies us.
// Once all three core objects are registered we send their configs.
onObjectRegistered(key obj_key, integer obj_type)
{
    if      (obj_type == 1) return;   // tower  -  not part of setup
    else if (obj_type == 3) { gSpawner_Key = obj_key; gSetupPending--; }
    else if (obj_type == 4) { gHandler_Key = obj_key; gSetupPending--; }
    // GM registers itself with us directly on CTRL channel, not via GM_REGISTER
    // so obj_type==GM is handled in handleControllerMessage

    if (gSetupPending <= 0 && gGM_Key != NULL_KEY)
        sendConfigs();
}

sendConfigs()
{
    // Send GM its config: grid origin, cell size, and target position.
    // GM will move itself to target_gm using llSetRegionPos.
    vector target_gm = gGridOrigin + <0.5, -2.0, 1.0>;
    llRegionSayTo(gGM_Key, CTRL,
        "GM_CONFIG"
        + "|" + (string)gGridOrigin.x
        + "|" + (string)gGridOrigin.y
        + "|" + (string)gGridOrigin.z
        + "|" + (string)CELL_SIZE
        + "|" + (string)target_gm.x
        + "|" + (string)target_gm.y
        + "|" + (string)target_gm.z);

    // Send spawner its config: entry cell coords, waypoint string, and target position.
    // Spawner will move itself to target_spawner using llSetRegionPos.
    string wps = buildWaypointString();
    // Entry cell coords  -  first path cell on y=0
    integer ex = 0;
    integer x;
    for (x = 0; x < MAP_W; x++)
        if (cellType(x, 0) == 2) { ex = x; x = MAP_W; }   // break

    vector target_spawner = entryWorldPos();
    llRegionSayTo(gSpawner_Key, CTRL,
        "SPAWNER_CONFIG"
        + "|" + (string)ex
        + "|0"
        + "|" + wps
        + "|" + (string)target_spawner.x
        + "|" + (string)target_spawner.y
        + "|" + (string)target_spawner.z);

    // Send handler its config: target position (grid centre).
    // Handler will move itself there and re-derive grid geometry.
    vector target_handler = <gGridOrigin.x + MAP_W * CELL_SIZE * 0.5,
                              gGridOrigin.y + MAP_H * CELL_SIZE * 0.5,
                              gGridOrigin.z + 0.05>;
    llRegionSayTo(gHandler_Key, CTRL,
        "HANDLER_CONFIG"
        + "|" + (string)target_handler.x
        + "|" + (string)target_handler.y
        + "|" + (string)target_handler.z);

    dbg("[CTL] Configs sent. Waiting for ready confirmations...");
}


// =============================================================================
// ANIMATION NOTIFICATION
// =============================================================================

notifyAnimations()
{
    llMessageLinked(LINK_THIS, ANIM_STATE,
        (string)gLifecycle + "|" + (string)gWaveNum
        + "|" + (string)gLives + "|" + (string)gScore,
        NULL_KEY);
}


// =============================================================================
// GAME LIFECYCLE
// =============================================================================

// =============================================================================
// MAP BUILDER SUPPORT
// =============================================================================

// Extract cell types (stride-3 index 0) from gMap into a CSV string.
// Result: "0,1,2,1,1,..." (100 values for a 10x10 grid)
string buildCellTypeString()
{
    string result = "";
    integer total = MAP_W * MAP_H;
    integer i;
    for (i = 0; i < total; i++)
    {
        if (result != "") result += ",";
        result += (string)llList2Integer(gMap, i * 3);
    }
    return result;
}

startMapBuilder()
{
    if (llGetInventoryType(INV_BUILDER) == INVENTORY_NONE)
    {
        llOwnerSay("[CTL] Missing inventory: " + INV_BUILDER);
        return;
    }
    loadMap(1);
    vector rez_pos = llGetPos() + <0.0, 0.0, 0.5>;
    llRezObject(INV_BUILDER, rez_pos, ZERO_VECTOR, ZERO_ROTATION, 1);
    dbg("[CTL] Rezzed MapBuilder.");
}

cleanupBuilder()
{
    if (gBuilder_Key != NULL_KEY)
    {
        llRegionSayTo(gBuilder_Key, CTRL, "SHUTDOWN");
        gBuilder_Key = NULL_KEY;
    }
    gMap       = [];
    gWaypoints = [];
}


startSetup()
{
    if (gBuilder_Key != NULL_KEY) cleanupBuilder();
    gGridOrigin = llGetPos();
    gLives      = STARTING_LIVES;
    gScore      = 0;
    gWaveNum    = 0;
    gEnemiesOut = 0;

    dbg("[CTL] Setup started. Grid origin: " + (string)gGridOrigin);
    loadMap(1);
    rezAllObjects();
}

enterWaiting()
{
    gLifecycle = STATE_WAITING;
    dbg("[CTL] Ready. Touch to start wave 1.");
    notifyAnimations();
}

startNextWave()
{
    gWaveNum++;
    integer count = WAVE_BASE + (gWaveNum - 1) * WAVE_INCREMENT;
    gEnemiesOut = count;
    gLifecycle  = STATE_WAVE;

    dbg("[CTL] Wave " + (string)gWaveNum + "  -  " + (string)count + " enemies.");
    notifyAnimations();

    // Tell all registered spawners to start
    llRegionSayTo(gSpawner_Key, CTRL, "WAVE_START|" + (string)count);
}

onLifeLost()
{
    gLives--;
    gEnemiesOut--;
    dbg("[CTL] Life lost. Lives: " + (string)gLives
        + "  Enemies remaining: " + (string)gEnemiesOut);

    if (gLives <= 0)
    {
        gameOver();
        return;
    }
    notifyAnimations();
    checkWaveClear();
}

onEnemyKilled()
{
    gScore++;
    gEnemiesOut--;
    dbg("[CTL] Enemy killed. Score: " + (string)gScore
        + "  Enemies remaining: " + (string)gEnemiesOut);
    notifyAnimations();
    checkWaveClear();
}

checkWaveClear()
{
    if (gLifecycle != STATE_WAVE) return;
    if (gEnemiesOut > 0) return;

    gLifecycle    = STATE_WAVE_CLEAR;
    gWaveClearTimer = WAVE_CLEAR_DELAY;
    dbg("[CTL] Wave " + (string)gWaveNum + " cleared!"
        + "  Score: " + (string)gScore
        + "  Lives: " + (string)gLives
        + "  Next wave in " + (string)WAVE_CLEAR_DELAY + "s...");
}

gameOver()
{
    gLifecycle = STATE_GAME_OVER;
    dbg("[CTL] GAME OVER. Final score: " + (string)gScore
        + "  Survived " + (string)(gWaveNum - 1) + " wave(s).");
    llSay(0, "Game over! Final score: " + (string)gScore);
    notifyAnimations();
    cleanupObjects();
}

cleanupObjects()
{
    // Ask all managed objects to deregister and die.
    // We broadcast on GM_DEREGISTER so each script hears it.
    // Objects with on_rez/llDie handle their own cleanup.
    if (gGM_Key      != NULL_KEY) llRegionSayTo(gGM_Key,      CTRL,     "SHUTDOWN");
    if (gHandler_Key != NULL_KEY) llRegionSayTo(gHandler_Key, CTRL,     "SHUTDOWN");
    if (gSpawner_Key != NULL_KEY) llRegionSayTo(gSpawner_Key, CTRL,     "SHUTDOWN");
    if (gBoard_Key   != NULL_KEY) llRegionSayTo(gBoard_Key,   MAP_TILE, "SHUTDOWN");
    gGM_Key      = NULL_KEY;
    gHandler_Key = NULL_KEY;
    gSpawner_Key = NULL_KEY;
    gBoard_Key   = NULL_KEY;
    gLifecycle   = STATE_IDLE;
}

resetGame()
{
    if (gBuilder_Key != NULL_KEY) cleanupBuilder();
    cleanupObjects();
    gMap       = [];
    gWaypoints = [];
    gLives     = 0;
    gScore     = 0;
    gWaveNum   = 0;
    gEnemiesOut = 0;
    dbg("[CTL] Reset. Touch to set up a new game.");
}


// =============================================================================
// CONTROLLER CHANNEL MESSAGE HANDLER
// Receives from GM (game events) and from rezzed objects (registration notify)
// =============================================================================

handleControllerMessage(key sender, string msg)
{
    list parts  = llParseString2List(msg, ["|"], []);
    string cmd  = llList2String(parts, 0);

    // Board announces itself after rezzing (from board_mover.lsl)
    if (cmd == "BOARD_READY")
    {
        gBoard_Key = sender;
        dbg("[CTL] Board online: " + (string)gBoard_Key);
        // Root tile target position — the last tile linked (tile MAP_W-1, MAP_H-1)
        // becomes link 1 (root) after the builder detaches. Mirrors HANDLER_CONFIG pattern.
        vector target_board = <gGridOrigin.x + (MAP_W - 0.5) * CELL_SIZE,
                               gGridOrigin.y + (MAP_H - 0.5) * CELL_SIZE,
                               gGridOrigin.z + 0.1>;
        llRegionSayTo(gBoard_Key, CTRL,
            "BOARD_CONFIG"
            + "|" + (string)target_board.x
            + "|" + (string)target_board.y
            + "|" + (string)target_board.z);
        return;
    }

    // MapBuilder announces itself after rezzing
    if (cmd == "BUILDER_READY")
    {
        gBuilder_Key = sender;
        dbg("[CTL] Builder online: " + (string)gBuilder_Key);
        string types = buildCellTypeString();
        llRegionSayTo(gBuilder_Key, CTRL,
            "BUILDER_CONFIG"
            + "|" + (string)gGridOrigin.x
            + "|" + (string)gGridOrigin.y
            + "|" + (string)gGridOrigin.z
            + "|" + (string)CELL_SIZE
            + "|" + (string)MAP_W
            + "|" + (string)MAP_H
            + "|" + types);
        return;
    }

    // GM announces itself immediately after rezzing
    if (cmd == "GM_READY")
    {
        gGM_Key = sender;
        gSetupPending--;
        dbg("[CTL] GM online: " + (string)gGM_Key);
        // Tell GM who we are so it can forward registrations to us
        llRegionSayTo(gGM_Key, CTRL, "CTRL_HELLO");
        if (gSetupPending <= 0 && gHandler_Key != NULL_KEY && gSpawner_Key != NULL_KEY)
            sendConfigs();
        return;
    }

    // GM confirms it received and applied its config
    if (cmd == "GM_CONFIG_OK")
    {
        dbg("[CTL] GM config acknowledged.");
        return;
    }

    // Spawner confirms it received and applied its config  -  game is ready
    if (cmd == "SPAWNER_CONFIG_OK")
    {
        dbg("[CTL] Spawner config acknowledged.");
        enterWaiting();
        return;
    }

    // GM forwards registration events for non-tower objects so we can track keys
    if (cmd == "REGISTERED")
    {
        if (llGetListLength(parts) < 3) return;
        key  obj_key  = (key)llList2String(parts, 1);
        integer obj_type = (integer)llList2String(parts, 2);
        onObjectRegistered(obj_key, obj_type);
        return;
    }

    // Life lost  -  enemy reached the exit
    if (cmd == "LIFE_LOST")
    {
        onLifeLost();
        return;
    }

    // Enemy killed by a tower
    if (cmd == "ENEMY_KILLED")
    {
        onEnemyKilled();
        return;
    }

    // Cell state query from GM: CELL_QUERY|gx|gy
    if (cmd == "CELL_QUERY")
    {
        if (llGetListLength(parts) < 3) return;
        integer gx = (integer)llList2String(parts, 1);
        integer gy = (integer)llList2String(parts, 2);
        llRegionSayTo(sender, CTRL,
            "CELL_DATA"
            + "|" + (string)gx
            + "|" + (string)gy
            + "|" + (string)cellType(gx, gy)
            + "|" + (string)cellOccupied(gx, gy));
        return;
    }

    // Cell occupied update from GM: CELL_SET|gx|gy|flag
    if (cmd == "CELL_SET")
    {
        if (llGetListLength(parts) < 4) return;
        setCellOccupied((integer)llList2String(parts, 1),
                        (integer)llList2String(parts, 2),
                        (integer)llList2String(parts, 3));
        return;
    }

    llOwnerSay("[CTL] Unknown message: " + cmd);
}


// =============================================================================
// DEBUG DUMP (owner-only chat commands)
// /td ctl status   -  lifecycle, lives, score, wave
// /td ctl map      -  ASCII map dump
// /td ctl reset    -  clean up and reset
// /td ctl wave     -  force-start next wave (testing)
// =============================================================================

handleDebug(string msg)
{
    if (msg == "/td ctl status")
    {
        string state_name;
        if      (gLifecycle == STATE_IDLE)       state_name = "IDLE";
        else if (gLifecycle == STATE_SETUP)      state_name = "SETUP";
        else if (gLifecycle == STATE_WAITING)    state_name = "WAITING";
        else if (gLifecycle == STATE_WAVE)       state_name = "WAVE";
        else if (gLifecycle == STATE_WAVE_CLEAR) state_name = "WAVE_CLEAR";
        else if (gLifecycle == STATE_GAME_OVER)  state_name = "GAME_OVER";
        else                                     state_name = "?";

        llOwnerSay("[CTL] State=" + state_name
            + " Wave=" + (string)gWaveNum
            + " Lives=" + (string)gLives
            + " Score=" + (string)gScore
            + " EnemiesOut=" + (string)gEnemiesOut
            + " Mem=" + (string)llGetFreeMemory() + "b");
    }
    else if (msg == "/td ctl map")
    {
        llOwnerSay("[MAP] B=buildable P=path X=blocked r=reserved o=occupied");
        integer y;
        for (y = 0; y < MAP_H; y++)
        {
            list cells = [];
            integer x;
            for (x = 0; x < MAP_W; x++)
            {
                integer t = cellType(x, y);
                integer o = cellOccupied(x, y);
                string ch;
                if      (t == 2) ch = "P";
                else if (t == 0) ch = "X";
                else             ch = "B";
                if      (o == 1) ch = llToLower(ch);
                else if (o == 2) ch = "r";
                cells += [ch];
            }
            llOwnerSay("y" + (string)y + " " + llDumpList2String(cells, " "));
        }
    }
    else if (msg == "/td ctl reset")
        resetGame();
    else if (msg == "/td ctl wave")
    {
        if (gLifecycle == STATE_WAITING || gLifecycle == STATE_WAVE_CLEAR)
            startNextWave();
        else
            llOwnerSay("[CTL] Not in a waitable state.");
    }
    else if (msg == "/td ctl debug on")
    {
        gDebug = TRUE;
        llSay(DBG_CHANNEL, "DEBUG_ON");
        llOwnerSay("[CTL] Debug ON (all scripts).");
    }
    else if (msg == "/td ctl debug off")
    {
        gDebug = FALSE;
        llSay(DBG_CHANNEL, "DEBUG_OFF");
        llOwnerSay("[CTL] Debug OFF (all scripts).");
    }
}


// =============================================================================
// TOUCH MENU
// Open an llDialog for any avatar who touches the controller.
// Each touch gets its own per-avatar listener to avoid cross-talk.
// Stale listeners are culled by the 1-second timer.
// =============================================================================

showMenu(key avatar)
{
    string prompt;
    list   buttons;

    if (gLifecycle == STATE_IDLE || gLifecycle == STATE_GAME_OVER)
    {
        if (gBuilder_Key != NULL_KEY)
        {
            prompt  = "Tower Defense\nMap builder active.";
            buttons = ["Link Tiles", "Export Map", "Clean Up Map"];
        }
        else
        {
            prompt  = "Tower Defense\nPress 'Start Game' to begin.";
            buttons = ["Start Game", "Build Map"];
        }
    }
    else if (gLifecycle == STATE_WAITING)
    {
        prompt  = "Wave " + (string)(gWaveNum + 1) + " ready"
            + "\nLives: " + (string)gLives
            + "   Score: " + (string)gScore;
        buttons = ["Start Wave", "End Game"];
    }
    else if (gLifecycle == STATE_WAVE || gLifecycle == STATE_WAVE_CLEAR)
    {
        prompt  = "Wave " + (string)gWaveNum + " in progress"
            + "\nLives: " + (string)gLives
            + "   Score: " + (string)gScore;
        buttons = ["End Game"];
    }
    else
    {
        // STATE_SETUP — busy
        llRegionSayTo(avatar, 0, "Game is setting up, please wait...");
        return;
    }

    integer handle = llListen(gMenuChannel, "", avatar, "");
    gMenuDialogs += [handle, (string)avatar, llGetUnixTime() + MENU_DIALOG_TIMEOUT];
    llDialog(avatar, prompt, buttons, gMenuChannel);
}

handleMenuResponse(key avatar, string choice)
{
    // Find and remove the listener for this avatar
    integer idx = llListFindList(gMenuDialogs, [(string)avatar]);
    if (idx != -1)
    {
        llListenRemove(llList2Integer(gMenuDialogs, idx - 1));
        gMenuDialogs = llDeleteSubList(gMenuDialogs, idx - 1, idx + 1);
    }

    if (choice == "Start Game")
    {
        if (gLifecycle == STATE_IDLE || gLifecycle == STATE_GAME_OVER)
            startSetup();
    }
    else if (choice == "Build Map")
    {
        if ((gLifecycle == STATE_IDLE || gLifecycle == STATE_GAME_OVER)
            && gBuilder_Key == NULL_KEY)
        {
            gGridOrigin = llGetPos();
            startMapBuilder();
        }
    }
    else if (choice == "Link Tiles")
    {
        if (gBuilder_Key != NULL_KEY)
            llRegionSayTo(gBuilder_Key, CTRL, "LINK_TILES");
    }
    else if (choice == "Export Map")
    {
        if (gBuilder_Key != NULL_KEY)
            llRegionSayTo(gBuilder_Key, CTRL, "EXPORT_MAP");
    }
    else if (choice == "Clean Up Map")
    {
        if (gBuilder_Key != NULL_KEY)
            cleanupBuilder();
    }
    else if (choice == "Start Wave")
    {
        if (gLifecycle == STATE_WAITING)
            startNextWave();
    }
    else if (choice == "End Game")
    {
        resetGame();
    }
}

cullStaleMenuDialogs()
{
    integer now   = llGetUnixTime();
    integer count = llGetListLength(gMenuDialogs) / 3;
    integer i     = count - 1;
    for (; i >= 0; i--)
    {
        integer idx = i * 3;
        if (llList2Integer(gMenuDialogs, idx + 2) < now)
        {
            llListenRemove(llList2Integer(gMenuDialogs, idx));
            gMenuDialogs = llDeleteSubList(gMenuDialogs, idx, idx + 2);
        }
    }
}


// =============================================================================
// MAIN STATE
// =============================================================================

default
{
    state_entry()
    {
        gLifecycle   = STATE_IDLE;
        gDebug       = DEBUG;
        gMenuChannel = -(integer)("0x" + llGetSubString((string)llGetKey(), 0, 6));
        llListen(CTRL,          "", NULL_KEY,     "");
        llListen(0,             "", llGetOwner(), "");
        llListen(DBG_CHANNEL, "", llGetOwner(), "");
        llSetTimerEvent(1.0);
        llOwnerSay("[CTL] Controller ready. Touch to set up game.");
        llOwnerSay("[CTL] Mem: " + (string)llGetFreeMemory() + "b");
    }

    touch_start(integer num)
    {
        showMenu(llDetectedKey(0));
    }

    listen(integer channel, string name, key id, string msg)
    {
        if (channel == CTRL)
            handleControllerMessage(id, msg);
        else if (channel == 0 && id == llGetOwner()
                 && llGetSubString(msg, 0, 6) == "/td ctl")
            handleDebug(msg);
        else if (channel == DBG_CHANNEL)
        {
            if      (msg == "DEBUG_ON")  gDebug = TRUE;
            else if (msg == "DEBUG_OFF") gDebug = FALSE;
        }
        else if (channel == gMenuChannel)
            handleMenuResponse(id, msg);
    }

    timer()
    {
        if (gLifecycle == STATE_WAVE_CLEAR)
        {
            gWaveClearTimer--;
            if (gWaveClearTimer <= 0)
                startNextWave();
        }
        // Auto-clean stale builder (manually deleted or region restart)
        if (gBuilder_Key != NULL_KEY && llKey2Name(gBuilder_Key) == "")
        {
            dbg("[CTL] Builder gone, auto-cleaning.");
            gBuilder_Key = NULL_KEY;
            gMap       = [];
            gWaypoints = [];
        }
        // Auto-clean stale board
        if (gBoard_Key != NULL_KEY && llKey2Name(gBoard_Key) == "")
        {
            dbg("[CTL] Board gone, auto-cleaning.");
            gBoard_Key = NULL_KEY;
        }
        cullStaleMenuDialogs();
    }

    on_rez(integer start_param)
    {
        llResetScript();
    }
}
