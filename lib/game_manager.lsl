// =============================================================================
// game_manager.lsl
// Tower Defense Game Manager — Phase 6 (memory optimised)
// =============================================================================
// MEMORY OPTIMISATIONS vs Phase 6:
//   - All named integer constants removed; literals inlined at call sites.
//     Each named global costs data-segment space permanently. 30+ eliminated.
//   - gTowerTypes list, TOWER_TYPE_STRIDE, findTowerType(), getTowerTypeLabels(),
//     towerTypeFromLabel() all replaced with two lightweight switch functions:
//     towerObjName(type_id) and towerLabel(type_id). No heap list at load time.
//   - dumpMap(), dumpRegistry(), dumpPairings(), handleSetCommand(),
//     handleDebugCommand() moved to game_manager_debug.lsl (separate prim script).
//     GM exposes them via link_message handler instead. Saves ~5KB of code space.
//   - isPlaceable() inlined at its single call site — one less function frame.
//   - getPairedHandler() removed — defined but never called anywhere.
//   - findNearestEnemy() unused target_pos_out parameter removed.
//   - Comments trimmed throughout; section headers kept for orientation.
//
// CHANNEL MAP (inlined — listed here for reference only):
//   GM_REGISTER_CHANNEL        = -2001
//   GM_DEREGISTER_CHANNEL      = -2002
//   HEARTBEAT_CHANNEL          = -2003
//   PLACEMENT_CHANNEL          = -2004
//   TOWER_REPORT_CHANNEL       = -2005
//   ENEMY_REPORT_CHANNEL       = -2006
//   GM_DISCOVERY_CHANNEL       = -2007
//   PLACEMENT_RESPONSE_CHANNEL = -2008
//   SPAWNER_CHANNEL            = -2009
//   ENEMY_CHANNEL              = -2010  (not listened by GM)
//   GRID_INFO_CHANNEL          = -2011
//   TOWER_PLACE_CHANNEL        = -2012
//   LINK_DEBUG_CHANNEL         = 42     (link_message from debug script)
// =============================================================================


// -----------------------------------------------------------------------------
// GLOBAL STATE
// Only true runtime state lives here — no constants.
// -----------------------------------------------------------------------------
list    gMap             = [];   // 300 entries: [type, occupied, 0] x 100 cells
list    gRegistry        = [];   // [key, type, gx, gy, timestamp, ...]  stride=5
list    gEnemyPositions  = [];   // [key, x, y, z, timestamp, ...]  stride=5
list    gSpawnerPairings = [];   // [spawner_key, handler_key, ...]  stride=2
list    gReservations    = [];   // [gx, gy, avatar_key, timestamp, ...]  stride=4
integer gHeartbeatSeq    = 0;
integer gLives           = 20;
integer gWaveActive      = FALSE;
vector  gTargetPosOut    = ZERO_VECTOR;
vector  gGridOrigin      = ZERO_VECTOR;
float   gGridCellSize    = 0.0;


// =============================================================================
// TOWER TYPE REGISTRY
// Two functions replace the gTowerTypes list + three helper functions.
// To add a tower type: add an else-if branch in each function.
// type_id matches start_param passed to llRezObject and the GM's tower type list.
// All tower types currently share the same "Tower" inventory object name.
// =============================================================================

string towerObjName(integer type_id)
{
    if (type_id == 1) return "Tower";
    if (type_id == 2) return "Tower";
    return "";
}

// Returns the display label shown in the placement handler's llDialog.
// Must stay in sync with TOWER_LABELS in placement_handler.lsl.
string towerLabel(integer type_id)
{
    if (type_id == 1) return "Basic";
    if (type_id == 2) return "Sniper";
    return "";
}


// =============================================================================
// MAP HELPERS
// MAP_WIDTH=10  MAP_HEIGHT=10  CELL_STRIDE=3
// Cell types:  0=blocked  1=buildable  2=path
// Occupied:    0=empty    1=occupied   2=reserved
// =============================================================================

integer cellIndex(integer x, integer y)
{
    return (y * 10 + x) * 3;
}

integer inBounds(integer x, integer y)
{
    return (x >= 0 && x < 10 && y >= 0 && y < 10);
}

integer getCellType(integer x, integer y)
{
    if (!inBounds(x, y)) return 0;
    return llList2Integer(gMap, cellIndex(x, y));
}

integer getCellOccupied(integer x, integer y)
{
    if (!inBounds(x, y)) return 1;
    return llList2Integer(gMap, cellIndex(x, y) + 1);
}

setCell(integer x, integer y, integer type, integer occupied)
{
    if (!inBounds(x, y)) return;
    integer idx = cellIndex(x, y);
    gMap = llListReplaceList(gMap, [type, occupied, 0], idx, idx + 2);
}

setCellOccupied(integer x, integer y, integer flag)
{
    if (!inBounds(x, y)) return;
    integer idx = cellIndex(x, y) + 1;
    gMap = llListReplaceList(gMap, [flag], idx, idx);
}

vector gridToWorld(integer gx, integer gy)
{
    return <gGridOrigin.x + (gx + 0.5) * gGridCellSize,
            gGridOrigin.y + (gy + 0.5) * gGridCellSize,
            gGridOrigin.z + 0.5>;
}

initMap()
{
    list row = [ 1,0,0, 1,0,0, 1,0,0, 1,0,0, 1,0,0,
                 1,0,0, 1,0,0, 1,0,0, 1,0,0, 1,0,0 ];
    gMap = [];
    integer i;
    for (i = 0; i < 10; i++)
        gMap += row;

    // Path
    setCell(2,0,2,0); setCell(2,1,2,0); setCell(2,2,2,0); setCell(2,3,2,0);
    setCell(2,4,2,0); setCell(3,4,2,0); setCell(4,4,2,0); setCell(5,4,2,0);
    setCell(6,4,2,0); setCell(7,4,2,0); setCell(7,5,2,0); setCell(7,6,2,0);
    setCell(7,7,2,0); setCell(6,7,2,0); setCell(5,7,2,0); setCell(4,7,2,0);
    setCell(3,7,2,0); setCell(2,7,2,0); setCell(2,8,2,0); setCell(2,9,2,0);

    // Blocked
    setCell(0,0,0,0); setCell(1,0,0,0);
    setCell(9,9,0,0); setCell(8,9,0,0);

    llOwnerSay("[GM] Map ready. Mem: " + (string)llGetFreeMemory() + "b");
}


// =============================================================================
// RESERVATION TABLE  stride=4: [gx, gy, avatar_key, timestamp]
// =============================================================================

integer findReservation(integer gx, integer gy)
{
    integer count = llGetListLength(gReservations) / 4;
    integer i;
    for (i = 0; i < count; i++)
    {
        integer idx = i * 4;
        if (llList2Integer(gReservations, idx)     == gx &&
            llList2Integer(gReservations, idx + 1) == gy)
            return idx;
    }
    return -1;
}

addReservation(integer gx, integer gy, key avatar)
{
    gReservations += [gx, gy, (string)avatar, llGetUnixTime()];
    setCellOccupied(gx, gy, 2);
}

clearReservation(integer gx, integer gy)
{
    integer idx = findReservation(gx, gy);
    if (idx == -1) return;
    gReservations = llDeleteSubList(gReservations, idx, idx + 3);
    if (getCellOccupied(gx, gy) == 2)
        setCellOccupied(gx, gy, 0);
}

cullStaleReservations()
{
    integer threshold = llGetUnixTime() - 30;
    integer count = llGetListLength(gReservations) / 4;
    integer i = count - 1;
    integer culled = 0;
    for (; i >= 0; i--)
    {
        integer idx = i * 4;
        if (llList2Integer(gReservations, idx + 3) < threshold)
        {
            integer gx = llList2Integer(gReservations, idx);
            integer gy = llList2Integer(gReservations, idx + 1);
            gReservations = llDeleteSubList(gReservations, idx, idx + 3);
            if (getCellOccupied(gx, gy) == 2)
                setCellOccupied(gx, gy, 0);
            culled++;
        }
    }
    if (culled > 0)
        llOwnerSay("[RES] Cleared " + (string)culled + " stale reservation(s).");
}


// =============================================================================
// TOWER REZZING
// =============================================================================

rezTower(integer gx, integer gy, integer type_id)
{
    if (gGridCellSize == 0.0)
    {
        llOwnerSay("[GM] Cannot rez — no grid info.");
        return;
    }

    string obj_name = towerObjName(type_id);
    if (obj_name == "")
    {
        llOwnerSay("[GM] Unknown tower type: " + (string)type_id);
        return;
    }

    if (llGetInventoryType(obj_name) == INVENTORY_NONE)
    {
        llOwnerSay("[GM] '" + obj_name + "' not in inventory.");
        return;
    }

    vector rez_pos = gridToWorld(gx, gy);
    llRezObject(obj_name, rez_pos, ZERO_VECTOR, ZERO_ROTATION, type_id);
    llOwnerSay("[GM] Rezzed type=" + (string)type_id
        + " (" + (string)gx + "," + (string)gy + ")");
}


// =============================================================================
// REGISTRY  stride=5: [key, type, gx, gy, timestamp]
// Types: 1=tower  2=enemy  3=spawner  4=placement_handler
// =============================================================================

integer findRegistryEntry(key id)
{
    return llListFindList(gRegistry, [(string)id]);
}

registerObject(key id, integer obj_type, integer gx, integer gy)
{
    integer existing = findRegistryEntry(id);
    if (existing != -1)
    {
        gRegistry = llListReplaceList(gRegistry,
            [llGetUnixTime()], existing + 4, existing + 4);
        return;
    }
    gRegistry += [(string)id, obj_type, gx, gy, llGetUnixTime()];
    llOwnerSay("[REG] +" + (string)obj_type + " " + (string)id);
}

deregisterObject(key id)
{
    integer idx = findRegistryEntry(id);
    if (idx == -1) return;

    integer obj_type = llList2Integer(gRegistry, idx + 1);
    integer gx       = llList2Integer(gRegistry, idx + 2);
    integer gy       = llList2Integer(gRegistry, idx + 3);

    gRegistry = llDeleteSubList(gRegistry, idx, idx + 4);

    if (obj_type == 1) setCellOccupied(gx, gy, 0);
    if (obj_type == 2) removeEnemyPosition(id);
    if (obj_type == 3) removeSpawnerPairing(id);
    if (obj_type == 4) { removePairingsForHandler(id); cullStaleReservations(); }

    llOwnerSay("[REG] -" + (string)obj_type + " " + (string)id);
}

integer registryCount()
{
    return llGetListLength(gRegistry) / 5;
}

key findRegisteredHandler()
{
    integer count = registryCount();
    integer i;
    for (i = 0; i < count; i++)
    {
        integer idx = i * 5;
        if (llList2Integer(gRegistry, idx + 1) == 4)
            return (key)llList2String(gRegistry, idx);
    }
    return NULL_KEY;
}


// =============================================================================
// HEARTBEAT
// =============================================================================

sendHeartbeat()
{
    gHeartbeatSeq++;
    integer count = registryCount();
    if (count == 0) return;
    string ping = "PING|" + (string)gHeartbeatSeq;
    integer i;
    for (i = 0; i < count; i++)
        llRegionSayTo((key)llList2String(gRegistry, i * 5), -2003, ping);
}

receiveHeartbeatAck(key id, integer seq)
{
    if (seq != gHeartbeatSeq) return;
    integer idx = findRegistryEntry(id);
    if (idx == -1) return;
    gRegistry = llListReplaceList(gRegistry, [llGetUnixTime()], idx + 4, idx + 4);
}

cullStaleObjects()
{
    integer threshold = llGetUnixTime() - 30;   // HEARTBEAT_INTERVAL * HEARTBEAT_TIMEOUT
    integer i = registryCount() - 1;
    integer culled = 0;

    for (; i >= 0; i--)
    {
        integer idx = i * 5;
        if (llList2Integer(gRegistry, idx + 4) < threshold)
        {
            integer obj_type = llList2Integer(gRegistry, idx + 1);
            integer gx       = llList2Integer(gRegistry, idx + 2);
            integer gy       = llList2Integer(gRegistry, idx + 3);
            key     cid      = (key)llList2String(gRegistry, idx);

            gRegistry = llDeleteSubList(gRegistry, idx, idx + 4);

            if (obj_type == 1) setCellOccupied(gx, gy, 0);
            if (obj_type == 2) removeEnemyPosition(cid);
            if (obj_type == 3) removeSpawnerPairing(cid);
            if (obj_type == 4) removePairingsForHandler(cid);

            culled++;
        }
    }

    if (culled > 0)
        llOwnerSay("[HB] Culled " + (string)culled
            + ". Registry: " + (string)registryCount());
}


// =============================================================================
// DISCOVERY
// =============================================================================

handleDiscoveryMessage(key sender, string msg)
{
    if (msg != "GM_DISCOVER") return;
    llRegionSayTo(sender, -2007, "GM_HERE|" + (string)llGetKey());
}


// =============================================================================
// SPAWNER PAIRING  stride=2: [spawner_key, handler_key]
// =============================================================================

integer findSpawnerPairing(key spawner_key)
{
    return llListFindList(gSpawnerPairings, [(string)spawner_key]);
}

setSpawnerPairing(key spawner_key, key handler_key)
{
    integer idx = findSpawnerPairing(spawner_key);
    if (idx == -1)
        gSpawnerPairings += [(string)spawner_key, (string)handler_key];
    else
        gSpawnerPairings = llListReplaceList(gSpawnerPairings,
            [(string)handler_key], idx + 1, idx + 1);
}

removeSpawnerPairing(key spawner_key)
{
    integer idx = findSpawnerPairing(spawner_key);
    if (idx != -1)
        gSpawnerPairings = llDeleteSubList(gSpawnerPairings, idx, idx + 1);
}

removePairingsForHandler(key handler_key)
{
    integer count = llGetListLength(gSpawnerPairings) / 2;
    integer i = count - 1;
    for (; i >= 0; i--)
    {
        integer idx = i * 2;
        if ((key)llList2String(gSpawnerPairings, idx + 1) == handler_key)
            gSpawnerPairings = llDeleteSubList(gSpawnerPairings, idx, idx + 1);
    }
}


// =============================================================================
// GRID INFO FORWARDING
// =============================================================================

handleGridInfoRequest(key sender, string msg)
{
    list parts = llParseString2List(msg, ["|"], []);
    if (llGetListLength(parts) < 3) return;

    key spawner_key = (key)llList2String(parts, 1);
    key handler_key = (key)llList2String(parts, 2);

    if (sender != spawner_key) return;

    integer handler_idx = findRegistryEntry(handler_key);
    if (handler_idx == -1 || llList2Integer(gRegistry, handler_idx + 1) != 4)
    {
        llRegionSayTo(sender, -2011, "GRID_INFO_ERROR|HANDLER_NOT_REGISTERED");
        return;
    }

    llRegionSayTo(handler_key, -2011, "GRID_INFO_REQUEST|" + (string)spawner_key);
}


// =============================================================================
// ENEMY POSITION TABLE  stride=5: [key, x, y, z, timestamp]
// =============================================================================

integer findEnemyPosition(key id)
{
    return llListFindList(gEnemyPositions, [(string)id]);
}

upsertEnemyPosition(key id, vector pos)
{
    integer idx = findEnemyPosition(id);
    if (idx == -1)
        gEnemyPositions += [(string)id, pos.x, pos.y, pos.z, llGetUnixTime()];
    else
        gEnemyPositions = llListReplaceList(gEnemyPositions,
            [pos.x, pos.y, pos.z, llGetUnixTime()], idx + 1, idx + 4);
}

removeEnemyPosition(key id)
{
    integer idx = findEnemyPosition(id);
    if (idx != -1)
        gEnemyPositions = llDeleteSubList(gEnemyPositions, idx, idx + 4);
}

integer enemyCount()
{
    return llGetListLength(gEnemyPositions) / 5;
}


// =============================================================================
// ENEMY REPORT
// =============================================================================

handleEnemyReport(key sender, string msg)
{
    list parts = llParseString2List(msg, ["|"], []);
    string cmd = llList2String(parts, 0);

    if (cmd == "ENEMY_POSITION")
    {
        if (llGetListLength(parts) < 4) return;
        upsertEnemyPosition(sender,
            <(float)llList2String(parts, 1),
             (float)llList2String(parts, 2),
             (float)llList2String(parts, 3)>);
    }
    else if (cmd == "ENEMY_ARRIVED")
    {
        gLives--;
        llOwnerSay("[GM] Enemy arrived. Lives: " + (string)gLives);
        removeEnemyPosition(sender);
        deregisterObject(sender);
    }
    else if (cmd == "ENEMY_KILLED")
    {
        llOwnerSay("[GM] Enemy killed.");
        removeEnemyPosition(sender);
        deregisterObject(sender);
    }
}


// =============================================================================
// TOWER HANDLER
// =============================================================================

key findNearestEnemy(vector tower_pos, float range)
{
    integer count = llGetListLength(gEnemyPositions) / 5;
    key   best_key  = NULL_KEY;
    float best_dist = range + 1.0;
    vector best_pos = ZERO_VECTOR;

    integer i;
    for (i = 0; i < count; i++)
    {
        integer idx = i * 5;
        vector epos = <(float)llList2String(gEnemyPositions, idx + 1),
                       (float)llList2String(gEnemyPositions, idx + 2),
                       (float)llList2String(gEnemyPositions, idx + 3)>;
        float dist = llVecDist(tower_pos, epos);
        if (dist <= range && dist < best_dist)
        {
            best_dist = dist;
            best_key  = (key)llList2String(gEnemyPositions, idx);
            best_pos  = epos;
        }
    }

    gTargetPosOut = best_pos;
    return best_key;
}

handleTowerReport(key sender, string msg)
{
    list parts = llParseString2List(msg, ["|"], []);
    if (llList2String(parts, 0) != "TARGET_REQUEST") return;
    if (llGetListLength(parts) < 5) return;

    vector tower_pos = <(float)llList2String(parts, 1),
                        (float)llList2String(parts, 2),
                        (float)llList2String(parts, 3)>;
    float range = (float)llList2String(parts, 4);

    key target_key = findNearestEnemy(tower_pos, range);

    if (target_key == NULL_KEY)
        llRegionSayTo(sender, -2005, "TARGET_RESPONSE|" + (string)NULL_KEY);
    else
        llRegionSayTo(sender, -2005, "TARGET_RESPONSE"
            + "|" + (string)target_key
            + "|" + (string)gTargetPosOut.x
            + "|" + (string)gTargetPosOut.y
            + "|" + (string)gTargetPosOut.z);
}


// =============================================================================
// SPAWNER HANDLER
// =============================================================================

handleSpawnerReport(key sender, string msg)
{
    list parts = llParseString2List(msg, ["|"], []);
    string cmd = llList2String(parts, 0);

    if (cmd == "SPAWNER_READY")
    {
        llOwnerSay("[SP] Ready: " + (string)sender);
    }
    else if (cmd == "HANDLER_QUERY")
    {
        key handler_key = findRegisteredHandler();
        llRegionSayTo(sender, -2009, "HANDLER_INFO|" + (string)handler_key);
        llOwnerSay("[SP] HANDLER_QUERY -> " + (string)handler_key);
    }
    else if (cmd == "SPAWNER_PAIRED")
    {
        if (llGetListLength(parts) < 2) return;
        key handler_key = (key)llList2String(parts, 1);
        integer handler_idx = findRegistryEntry(handler_key);
        if (handler_idx == -1 || llList2Integer(gRegistry, handler_idx + 1) != 4)
        {
            llOwnerSay("[PAIR] Rejected: " + (string)handler_key);
            return;
        }
        setSpawnerPairing(sender, handler_key);
        llOwnerSay("[PAIR] " + (string)sender + " -> " + (string)handler_key);
    }
}

startWave()
{
    integer count = registryCount();
    integer sent  = 0;
    integer i;
    for (i = 0; i < count; i++)
    {
        integer idx = i * 5;
        if (llList2Integer(gRegistry, idx + 1) == 3)
        {
            llRegionSayTo((key)llList2String(gRegistry, idx), -2009, "WAVE_START|1");
            sent++;
        }
    }
    if (sent == 0)
        llOwnerSay("[GM] No spawners registered.");
    else
    {
        gWaveActive = TRUE;
        llOwnerSay("[GM] Wave -> " + (string)sent + " spawner(s).");
    }
}


// =============================================================================
// PLACEMENT VALIDATION
// =============================================================================

reservePlacement(key handler, integer gx, integer gy, key avatar)
{
    addReservation(gx, gy, avatar);
    llRegionSayTo(handler, -2008,
        "PLACEMENT_RESERVED|" + (string)gx + "|" + (string)gy + "|" + (string)avatar);
    llOwnerSay("[PL] Reserved (" + (string)gx + "," + (string)gy
        + ") for " + llKey2Name(avatar));
}

denyPlacement(key handler, integer gx, integer gy, key avatar, string reason)
{
    llRegionSayTo(handler, -2008,
        "PLACEMENT_DENIED|" + (string)gx + "|" + (string)gy
        + "|" + (string)avatar + "|" + reason);
    llOwnerSay("[PL] Denied " + reason + " (" + (string)gx + "," + (string)gy + ")");
}

handlePlacementRequest(key sender, string msg)
{
    if (sender != llGetKey())
    {
        integer sender_idx = findRegistryEntry(sender);
        if (sender_idx == -1 || llList2Integer(gRegistry, sender_idx + 1) != 4)
        {
            llRegionSayTo(sender, -2008,
                "PLACEMENT_DENIED|0|0|" + (string)sender + "|NOT_REGISTERED");
            return;
        }
    }

    list parts = llParseString2List(msg, ["|"], []);
    if (llGetListLength(parts) < 4) return;
    if (llList2String(parts, 0) != "PLACEMENT_REQUEST") return;

    integer gx = (integer)llList2String(parts, 1);
    integer gy = (integer)llList2String(parts, 2);
    key avatar = (key)llList2String(parts, 3);

    if (!inBounds(gx, gy))
    { denyPlacement(sender, gx, gy, avatar, "OUT_OF_BOUNDS"); return; }

    if (getCellType(gx, gy) != 1)
    { denyPlacement(sender, gx, gy, avatar, "NOT_BUILDABLE"); return; }

    if (getCellOccupied(gx, gy) != 0)
    { denyPlacement(sender, gx, gy, avatar, "CELL_OCCUPIED"); return; }

    reservePlacement(sender, gx, gy, avatar);
}

handleTowerPlaceRequest(key sender, string msg)
{
    integer sender_idx = findRegistryEntry(sender);
    if (sender_idx == -1 || llList2Integer(gRegistry, sender_idx + 1) != 4)
    {
        llOwnerSay("[PL] TOWER_PLACE_REQUEST from unregistered sender.");
        return;
    }

    list parts = llParseString2List(msg, ["|"], []);
    if (llGetListLength(parts) < 5) return;
    if (llList2String(parts, 0) != "TOWER_PLACE_REQUEST") return;

    integer gx      = (integer)llList2String(parts, 1);
    integer gy      = (integer)llList2String(parts, 2);
    key avatar      = (key)llList2String(parts, 3);
    integer type_id = (integer)llList2String(parts, 4);

    integer res_idx = findReservation(gx, gy);
    if (res_idx == -1)
    {
        llRegionSayTo(avatar, 0,
            "Your tower selection timed out. Please click the grid again.");
        return;
    }

    if ((key)llList2String(gReservations, res_idx + 2) != avatar)
    {
        llOwnerSay("[PL] Avatar mismatch on placement.");
        return;
    }

    if (towerObjName(type_id) == "")
    {
        llOwnerSay("[PL] Unknown tower type: " + (string)type_id);
        return;
    }

    clearReservation(gx, gy);
    setCellOccupied(gx, gy, 1);
    rezTower(gx, gy, type_id);
    llRegionSayTo(avatar, 0,
        "Tower placed at (" + (string)gx + "," + (string)gy + ").");
}


// =============================================================================
// REGISTRATION
// =============================================================================

integer checkPlacementHandlerSlot(key sender)
{
    integer count = registryCount();
    integer i;
    for (i = 0; i < count; i++)
    {
        integer idx      = i * 5;
        key existing_key = (key)llList2String(gRegistry, idx);
        if (llList2Integer(gRegistry, idx + 1) == 4 && existing_key != sender)
        {
            llRegionSayTo(sender, -2001,
                "REGISTER_REJECTED|PLACEMENT_HANDLER_ALREADY_REGISTERED|"
                + (string)existing_key);
            return FALSE;
        }
    }
    return TRUE;
}

handleRegisterMessage(key sender, string msg)
{
    list parts = llParseString2List(msg, ["|"], []);
    if (llGetListLength(parts) < 4) return;
    if (llList2String(parts, 0) != "REGISTER") return;

    integer obj_type = (integer)llList2String(parts, 1);
    integer gx       = (integer)llList2String(parts, 2);
    integer gy       = (integer)llList2String(parts, 3);

    if (obj_type < 1 || obj_type > 4)
    {
        llOwnerSay("[REG] Unknown type " + (string)obj_type);
        return;
    }

    if (obj_type == 4)
    {
        if (!checkPlacementHandlerSlot(sender)) return;

        if (llGetListLength(parts) >= 8)
        {
            gGridOrigin   = <(float)llList2String(parts, 4),
                             (float)llList2String(parts, 5),
                             (float)llList2String(parts, 6)>;
            gGridCellSize = (float)llList2String(parts, 7);
            llOwnerSay("[GM] Grid: origin=" + (string)gGridOrigin
                + " cell=" + (string)gGridCellSize + "m");
        }
    }

    registerObject(sender, obj_type, gx, gy);
    llRegionSayTo(sender, -2001, "REGISTER_OK|" + (string)obj_type);
}

handleDeregisterMessage(key sender, string msg)
{
    list parts = llParseString2List(msg, ["|"], []);
    if (llList2String(parts, 0) != "DEREGISTER") return;
    deregisterObject(sender);
}

handleHeartbeatMessage(key sender, string msg)
{
    list parts = llParseString2List(msg, ["|"], []);
    if (llList2String(parts, 0) == "ACK" && llGetListLength(parts) >= 2)
        receiveHeartbeatAck(sender, (integer)llList2String(parts, 1));
}


// =============================================================================
// LINK MESSAGE — debug commands forwarded from game_manager_debug.lsl
// Num=42 is the agreed debug channel. str carries the /td command text.
// =============================================================================

handleLinkDebug(string cmd)
{
    if (cmd == "dump map")
        llMessageLinked(LINK_THIS, 43, dumpMapStr(), "");
    else if (cmd == "dump registry")
        llMessageLinked(LINK_THIS, 43, dumpRegistryStr(), "");
    else if (cmd == "dump pairings")
        llMessageLinked(LINK_THIS, 43, dumpPairingsStr(), "");
    else if (cmd == "dump all")
    {
        llMessageLinked(LINK_THIS, 43, dumpMapStr(), "");
        llMessageLinked(LINK_THIS, 43, dumpRegistryStr(), "");
        llMessageLinked(LINK_THIS, 43, dumpPairingsStr(), "");
    }
    else if (cmd == "stats")
    {
        llMessageLinked(LINK_THIS, 43,
            "Objs:" + (string)registryCount()
            + " Enemies:" + (string)enemyCount()
            + " Pairs:" + (string)(llGetListLength(gSpawnerPairings) / 2)
            + " Res:" + (string)(llGetListLength(gReservations) / 4)
            + " Lives:" + (string)gLives
            + " Wave:" + (string)gWaveActive
            + " HB:" + (string)gHeartbeatSeq
            + " Mem:" + (string)llGetFreeMemory() + "b", "");
    }
    else if (llGetSubString(cmd, 0, 3) == "set ")
    {
        list parts = llParseString2List(cmd, [" "], []);
        if (llGetListLength(parts) < 4)
        {
            llOwnerSay("[GM] Usage: set <x> <y> <build|path|blocked>");
            return;
        }
        integer x        = (integer)llList2String(parts, 1);
        integer y        = (integer)llList2String(parts, 2);
        string  type_str = llToLower(llList2String(parts, 3));

        if (!inBounds(x, y)) { llOwnerSay("[GM] Out of bounds"); return; }

        if      (type_str == "build")
            setCell(x, y, 1, getCellOccupied(x, y));
        else if (type_str == "path")
            setCell(x, y, 2, 0);
        else if (type_str == "blocked")
            setCell(x, y, 0, 0);
        else
            llOwnerSay("[GM] Unknown type: " + type_str);
    }
    else if (cmd == "wave start")
        startWave();
}

// Build map dump as a single string for link_message.
// Called only when debug script requests it — not in hot path.
string dumpMapStr()
{
    string out = "[MAP] B=buildable P=path X=blocked r=reserved o=occupied\n";
    integer y;
    for (y = 0; y < 10; y++)
    {
        list cells = [];
        integer x;
        for (x = 0; x < 10; x++)
        {
            integer t = getCellType(x, y);
            integer o = getCellOccupied(x, y);
            string ch;
            if      (t == 2) ch = "P";
            else if (t == 0) ch = "X";
            else             ch = "B";
            if      (o == 1) ch = llToLower(ch);
            else if (o == 2) ch = "r";
            cells += [ch];
        }
        out += "y" + (string)y + " " + llDumpList2String(cells, " ") + "\n";
    }
    return out;
}

string dumpRegistryStr()
{
    integer count = registryCount();
    string out = "[REG] --- " + (string)count + " objects ---\n";
    integer i;
    for (i = 0; i < count; i++)
    {
        integer idx      = i * 5;
        integer obj_type = llList2Integer(gRegistry, idx + 1);
        integer age      = llGetUnixTime() - llList2Integer(gRegistry, idx + 4);
        string type_label;
        if      (obj_type == 1) type_label = "TWR";
        else if (obj_type == 2) type_label = "ENM";
        else if (obj_type == 3) type_label = "SPN";
        else if (obj_type == 4) type_label = "PLH";
        else                    type_label = "UNK";
        out += type_label
            + " (" + (string)llList2Integer(gRegistry, idx + 2)
            + "," + (string)llList2Integer(gRegistry, idx + 3) + ")"
            + " " + (string)age + "s "
            + llList2String(gRegistry, idx) + "\n";
    }
    return out;
}

string dumpPairingsStr()
{
    integer count = llGetListLength(gSpawnerPairings) / 2;
    string out = "[PAIR] --- " + (string)count + " pairs ---\n";
    integer i;
    for (i = 0; i < count; i++)
    {
        integer idx = i * 2;
        out += llList2String(gSpawnerPairings, idx)
            + " -> " + llList2String(gSpawnerPairings, idx + 1) + "\n";
    }
    return out;
}


// =============================================================================
// MAIN STATE
// =============================================================================

default
{
    state_entry()
    {
        llOwnerSay("[GM] Starting up...");
        initMap();

        llListen(-2001, "", NULL_KEY, "");   // GM_REGISTER
        llListen(-2002, "", NULL_KEY, "");   // GM_DEREGISTER
        llListen(-2003, "", NULL_KEY, "");   // HEARTBEAT
        llListen(-2004, "", NULL_KEY, "");   // PLACEMENT
        llListen(-2006, "", NULL_KEY, "");   // ENEMY_REPORT
        llListen(-2005, "", NULL_KEY, "");   // TOWER_REPORT
        llListen(-2007, "", NULL_KEY, "");   // GM_DISCOVERY
        llListen(-2009, "", NULL_KEY, "");   // SPAWNER
        llListen(-2011, "", NULL_KEY, "");   // GRID_INFO
        llListen(-2012, "", NULL_KEY, "");   // TOWER_PLACE

        llSetTimerEvent(10);

        llOwnerSay("[GM] Key: " + (string)llGetKey());
        llOwnerSay("[GM] Mem: " + (string)llGetFreeMemory() + "b");
    }

    listen(integer channel, string name, key id, string msg)
    {
        if      (channel == -2001) handleRegisterMessage(id, msg);
        else if (channel == -2002) handleDeregisterMessage(id, msg);
        else if (channel == -2003) handleHeartbeatMessage(id, msg);
        else if (channel == -2004) handlePlacementRequest(id, msg);
        else if (channel == -2007) handleDiscoveryMessage(id, msg);
        else if (channel == -2006) handleEnemyReport(id, msg);
        else if (channel == -2005) handleTowerReport(id, msg);
        else if (channel == -2009) handleSpawnerReport(id, msg);
        else if (channel == -2011) handleGridInfoRequest(id, msg);
        else if (channel == -2012) handleTowerPlaceRequest(id, msg);
    }

    link_message(integer sender_num, integer num, string str, key id)
    {
        if (num == 42) handleLinkDebug(str);
    }

    timer()
    {
        sendHeartbeat();
        cullStaleObjects();
        cullStaleReservations();
    }
}
