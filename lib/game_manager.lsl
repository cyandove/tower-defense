// =============================================================================
// game_manager.lsl
// Tower Defense Game Manager  -  Phase 7
// =============================================================================
// PHASE 7 CHANGES (vs Phase 6 optimised):
//   - Map entirely removed: gMap, all map helpers, initMap(), gridToWorld(),
//     inBounds(), getCellType(), getCellOccupied(), setCell(), setCellOccupied(),
//     gGridOrigin, gGridCellSize, gReservations, cullStaleReservations()  - 
//     all gone. Map authority now lives in controller.lsl.
//   - gLives, gWaveActive, startWave() removed  -  lifecycle owned by controller.
//   - Added CONTROLLER_CHANNEL = -2013; GM listens and sends on it.
//   - Added gCtrl_Key: set when controller sends GM_CONFIG after rezzing.
//   - Startup sequence: GM now idles in "waiting for config" mode until it
//     receives GM_CONFIG from the controller. Registers with its own key once
//     configured, then notifies controller GM_CONFIG_OK.
//   - Cell validation is now async: handlePlacementRequest() sends CELL_QUERY
//     to controller, stores request in gPendingQuery, resumes in
//     handleCellData() when CELL_DATA response arrives.
//   - gPendingQuery: single in-flight placement query
//     [handler_key, gx, gy, avatar_key]   -  stride 4.
//     Second request while one is in flight is dropped with a retry message.
//   - Reservation management delegated to controller via CELL_SET messages.
//   - deregisterObject() sends CELL_SET to controller instead of calling
//     setCellOccupied() locally.
//   - handleEnemyReport() forwards LIFE_LOST and ENEMY_KILLED to controller
//     on CTRL channel instead of decrementing gLives locally.
//   - GM announces itself to controller on CTRL channel with GM_READY on rez.
//   - GM notifies controller of handler/spawner registrations via REGISTERED.
//   - Grid info (origin, cell size) for tower rezzing now comes from GM_CONFIG.
//   - handleSpawnerReport() SPAWNER_PAIRED and HANDLER_QUERY retained unchanged.
//   - debug dump functions updated: map dump removed, stats updated.
//
// CHANNEL MAP (all inlined as literals):
//   -2001  GM_REGISTER
//   -2002  GM_DEREGISTER
//   -2003  HEARTBEAT
//   -2004  PLACEMENT
//   -2005  TOWER_REPORT
//   -2006  ENEMY_REPORT
//   -2007  GM_DISCOVERY
//   -2008  PLACEMENT_RESPONSE
//   -2009  SPAWNER
//   -2010  ENEMY  (not listened here)
//   -2011  GRID_INFO
//   -2012  TOWER_PLACE
//   -2013  CONTROLLER
// =============================================================================


// -----------------------------------------------------------------------------
// GLOBAL STATE
// -----------------------------------------------------------------------------
list    gRegistry        = [];   // [key, type, gx, gy, timestamp]  stride=5
list    gEnemyPositions  = [];   // [key, x, y, z, timestamp]  stride=5
list    gSpawnerPairings = [];   // [spawner_key, handler_key]  stride=2
list    gPendingQuery    = [];   // [handler_key, gx, gy, avatar_key]  max 1 entry
integer gHeartbeatSeq    = 0;
vector  gTargetPosOut    = ZERO_VECTOR;

// Set from GM_CONFIG sent by controller after rezzing
key     gCtrl_Key        = NULL_KEY;
vector  gGridOrigin      = ZERO_VECTOR;
float   gGridCellSize    = 0.0;
integer gConfigured      = FALSE;


// =============================================================================
// TOWER TYPE REGISTRY
// Add a branch in each function for each new tower type.
// type_id matches start_param passed to llRezObject.
// =============================================================================

string towerObjName(integer type_id)
{
    if (type_id == 1) return "Tower";
    if (type_id == 2) return "Tower";
    return "";
}

string towerLabel(integer type_id)
{
    if (type_id == 1) return "Basic";
    if (type_id == 2) return "Sniper";
    return "";
}


// =============================================================================
// GRID HELPERS
// Only geometry needed for tower rezzing  -  no cell state stored here.
// =============================================================================

vector gridToWorld(integer gx, integer gy)
{
    return <gGridOrigin.x + (gx + 0.5) * gGridCellSize,
            gGridOrigin.y + (gy + 0.5) * gGridCellSize,
            gGridOrigin.z + 0.5>;
}

integer inBounds(integer x, integer y)
{
    // Grid is always 10x10; expand if needed.
    return (x >= 0 && x < 10 && y >= 0 && y < 10);
}


// =============================================================================
// TOWER REZZING
// =============================================================================

rezTower(integer gx, integer gy, integer type_id)
{
    if (gGridCellSize == 0.0)
    { llOwnerSay("[GM] Cannot rez  -  no grid config yet."); return; }

    string obj_name = towerObjName(type_id);
    if (obj_name == "")
    { llOwnerSay("[GM] Unknown tower type: " + (string)type_id); return; }

    if (llGetInventoryType(obj_name) == INVENTORY_NONE)
    { llOwnerSay("[GM] '" + obj_name + "' not in inventory."); return; }

    vector rez_pos = gridToWorld(gx, gy);
    llRezObject(obj_name, rez_pos, ZERO_VECTOR, ZERO_ROTATION, type_id);
    llOwnerSay("[GM] Rezzed type=" + (string)type_id
        + " (" + (string)gx + "," + (string)gy + ")");
}


// =============================================================================
// REGISTRY  stride=5: [key, type, gx, gy, timestamp]
// Types: 1=tower  2=enemy  3=spawner  4=handler
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

    // Notify controller of handler and spawner registrations
    // so it can track their keys for config delivery
    if (gCtrl_Key != NULL_KEY && (obj_type == 3 || obj_type == 4))
        llRegionSayTo(gCtrl_Key, -2013,
            "REGISTERED|" + (string)id + "|" + (string)obj_type);
}

deregisterObject(key id)
{
    integer idx = findRegistryEntry(id);
    if (idx == -1) return;

    integer obj_type = llList2Integer(gRegistry, idx + 1);
    integer gx       = llList2Integer(gRegistry, idx + 2);
    integer gy       = llList2Integer(gRegistry, idx + 3);

    gRegistry = llDeleteSubList(gRegistry, idx, idx + 4);

    if (obj_type == 1)
    {
        // Tower gone  -  tell controller to clear the cell
        if (gCtrl_Key != NULL_KEY)
            llRegionSayTo(gCtrl_Key, -2013,
                "CELL_SET|" + (string)gx + "|" + (string)gy + "|0");
    }
    if (obj_type == 2) removeEnemyPosition(id);
    if (obj_type == 3) removeSpawnerPairing(id);
    if (obj_type == 4) removePairingsForHandler(id);

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
    integer threshold = llGetUnixTime() - 30;
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

            if (obj_type == 1 && gCtrl_Key != NULL_KEY)
                llRegionSayTo(gCtrl_Key, -2013,
                    "CELL_SET|" + (string)gx + "|" + (string)gy + "|0");
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
// Unchanged from Phase 6  -  handler still answers directly to spawner.
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
        removeEnemyPosition(sender);
        deregisterObject(sender);
        if (gCtrl_Key != NULL_KEY)
            llRegionSayTo(gCtrl_Key, -2013, "LIFE_LOST");
    }
    else if (cmd == "ENEMY_KILLED")
    {
        removeEnemyPosition(sender);
        deregisterObject(sender);
        if (gCtrl_Key != NULL_KEY)
            llRegionSayTo(gCtrl_Key, -2013, "ENEMY_KILLED");
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


// =============================================================================
// PLACEMENT VALIDATION  -  ASYNC
//
// Flow:
//   1. handlePlacementRequest() validates sender, parses coords, checks bounds.
//   2. Sends CELL_QUERY to controller; stores request in gPendingQuery.
//   3. handleCellData() receives CELL_DATA from controller.
//   4. Validates cell type and occupied state, then reserves or denies.
//   5. Reservation = tell controller CELL_SET|gx|gy|2, send PLACEMENT_RESERVED.
//
// Only one in-flight query at a time. If a second request arrives while one
// is pending, the second player gets a "try again" message.
// =============================================================================

pendingQuerySet(key handler, integer gx, integer gy, key avatar)
{
    gPendingQuery = [(string)handler, gx, gy, (string)avatar, llGetUnixTime()];
}

integer pendingQueryActive()
{
    return llGetListLength(gPendingQuery) > 0;
}

clearPendingQuery()
{
    gPendingQuery = [];
}

denyPlacement(key handler, integer gx, integer gy, key avatar, string reason)
{
    llRegionSayTo(handler, -2008,
        "PLACEMENT_DENIED|" + (string)gx + "|" + (string)gy
        + "|" + (string)avatar + "|" + reason);
    llOwnerSay("[PL] Denied " + reason
        + " (" + (string)gx + "," + (string)gy + ")");
}

handlePlacementRequest(key sender, string msg)
{
    integer sender_idx = findRegistryEntry(sender);
    if (sender_idx == -1 || llList2Integer(gRegistry, sender_idx + 1) != 4)
    {
        llRegionSayTo(sender, -2008,
            "PLACEMENT_DENIED|0|0|" + (string)sender + "|NOT_REGISTERED");
        return;
    }

    list parts = llParseString2List(msg, ["|"], []);
    if (llGetListLength(parts) < 4) return;
    if (llList2String(parts, 0) != "PLACEMENT_REQUEST") return;

    integer gx = (integer)llList2String(parts, 1);
    integer gy = (integer)llList2String(parts, 2);
    key avatar = (key)llList2String(parts, 3);

    if (!inBounds(gx, gy))
    { denyPlacement(sender, gx, gy, avatar, "OUT_OF_BOUNDS"); return; }

    // Drop if another query is in flight
    if (pendingQueryActive())
    {
        llRegionSayTo(avatar, 0, "Grid is busy  -  please try again in a moment.");
        return;
    }

    pendingQuerySet(sender, gx, gy, avatar);
    llRegionSayTo(gCtrl_Key, -2013,
        "CELL_QUERY|" + (string)gx + "|" + (string)gy);
}

// Called when controller responds with CELL_DATA.
handleCellData(string msg)
{
    if (!pendingQueryActive()) return;

    list parts = llParseString2List(msg, ["|"], []);
    if (llGetListLength(parts) < 5) return;

    integer gx       = (integer)llList2String(parts, 1);
    integer gy       = (integer)llList2String(parts, 2);
    integer ctype    = (integer)llList2String(parts, 3);
    integer occupied = (integer)llList2String(parts, 4);

    key handler = (key)llList2String(gPendingQuery, 0);
    key avatar  = (key)llList2String(gPendingQuery, 3);

    // Verify this response matches our pending query
    if (gx != llList2Integer(gPendingQuery, 1) ||
        gy != llList2Integer(gPendingQuery, 2))
    {
        llOwnerSay("[PL] Stale CELL_DATA  -  ignoring.");
        clearPendingQuery();
        return;
    }

    clearPendingQuery();

    if (ctype != 1)
    { denyPlacement(handler, gx, gy, avatar, "NOT_BUILDABLE"); return; }

    if (occupied != 0)
    { denyPlacement(handler, gx, gy, avatar, "CELL_OCCUPIED"); return; }

    // Reserve: tell controller to mark the cell reserved
    llRegionSayTo(gCtrl_Key, -2013,
        "CELL_SET|" + (string)gx + "|" + (string)gy + "|2");

    // Tell handler to show the tower dialog
    llRegionSayTo(handler, -2008,
        "PLACEMENT_RESERVED|" + (string)gx + "|" + (string)gy
        + "|" + (string)avatar);
    llOwnerSay("[PL] Reserved (" + (string)gx + "," + (string)gy
        + ") for " + llKey2Name(avatar));
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

    if (towerObjName(type_id) == "")
    { llOwnerSay("[PL] Unknown tower type: " + (string)type_id); return; }

    // Mark occupied in controller and rez
    llRegionSayTo(gCtrl_Key, -2013,
        "CELL_SET|" + (string)gx + "|" + (string)gy + "|1");
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
    { llOwnerSay("[REG] Unknown type " + (string)obj_type); return; }

    if (obj_type == 4)
    {
        if (!checkPlacementHandlerSlot(sender)) return;
        // Grid geometry still arrives via handler registration for tower rezzing
        if (llGetListLength(parts) >= 8)
        {
            gGridOrigin   = <(float)llList2String(parts, 4),
                             (float)llList2String(parts, 5),
                             (float)llList2String(parts, 6)>;
            gGridCellSize = (float)llList2String(parts, 7);
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
// CONTROLLER CHANNEL
// Handles GM_CONFIG from controller and CELL_DATA responses.
// =============================================================================

handleControllerMessage(key sender, string msg)
{
    if (sender != gCtrl_Key && gCtrl_Key != NULL_KEY) return;

    list parts = llParseString2List(msg, ["|"], []);
    string cmd = llList2String(parts, 0);

    if (cmd == "CTRL_HELLO")
    {
        gCtrl_Key = sender;
        llOwnerSay("[GM] Controller registered: " + (string)gCtrl_Key);
        // Replay any handler/spawner registrations that arrived before us
        integer i;
        integer n = llGetListLength(gRegistry) / 5;
        for (i = 0; i < n; i++)
        {
            integer idx = i * 5;
            integer ot  = llList2Integer(gRegistry, idx + 1);
            if (ot == 3 || ot == 4)
                llRegionSayTo(gCtrl_Key, -2013,
                    "REGISTERED|" + llList2String(gRegistry, idx)
                    + "|" + (string)ot);
        }
        return;
    }

    if (cmd == "GM_CONFIG")
    {
        if (llGetListLength(parts) < 5) return;
        gCtrl_Key     = sender;
        gGridOrigin   = <(float)llList2String(parts, 1),
                         (float)llList2String(parts, 2),
                         (float)llList2String(parts, 3)>;
        gGridCellSize = (float)llList2String(parts, 4);
        gConfigured   = TRUE;

        llOwnerSay("[GM] Config received from controller. Grid origin="
            + (string)gGridOrigin + " cell=" + (string)gGridCellSize + "m");
        llRegionSayTo(gCtrl_Key, -2013, "GM_CONFIG_OK");
    }
    else if (cmd == "CELL_DATA")
    {
        handleCellData(msg);
    }
    else if (cmd == "SHUTDOWN")
    {
        llOwnerSay("[GM] Shutdown received. Deregistering and dying.");
        llRegionSay(-2002, "DEREGISTER");
        llDie();
    }
}


// =============================================================================
// LINK MESSAGE  -  debug script on num=42, responds on num=43
// =============================================================================

handleLinkDebug(string cmd)
{
    if (cmd == "dump registry")
        llMessageLinked(LINK_THIS, 43, dumpRegistryStr(), "");
    else if (cmd == "dump pairings")
        llMessageLinked(LINK_THIS, 43, dumpPairingsStr(), "");
    else if (cmd == "stats")
        llMessageLinked(LINK_THIS, 43,
            "Objs:" + (string)registryCount()
            + " Enemies:" + (string)enemyCount()
            + " Pairs:" + (string)(llGetListLength(gSpawnerPairings) / 2)
            + " HB:" + (string)gHeartbeatSeq
            + " Configured:" + (string)gConfigured
            + " Mem:" + (string)llGetFreeMemory() + "b", "");
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
        string lbl;
        if      (obj_type == 1) lbl = "TWR";
        else if (obj_type == 2) lbl = "ENM";
        else if (obj_type == 3) lbl = "SPN";
        else if (obj_type == 4) lbl = "PLH";
        else                    lbl = "UNK";
        out += lbl
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
        llOwnerSay("[GM] Starting. Waiting for controller config...");

        llListen(-2001, "", NULL_KEY, "");   // GM_REGISTER
        llListen(-2002, "", NULL_KEY, "");   // GM_DEREGISTER
        llListen(-2003, "", NULL_KEY, "");   // HEARTBEAT
        llListen(-2004, "", NULL_KEY, "");   // PLACEMENT
        llListen(-2005, "", NULL_KEY, "");   // TOWER_REPORT
        llListen(-2006, "", NULL_KEY, "");   // ENEMY_REPORT
        llListen(-2007, "", NULL_KEY, "");   // GM_DISCOVERY
        llListen(-2009, "", NULL_KEY, "");   // SPAWNER
        llListen(-2011, "", NULL_KEY, "");   // GRID_INFO
        llListen(-2012, "", NULL_KEY, "");   // TOWER_PLACE
        llListen(-2013, "", NULL_KEY, "");   // CONTROLLER

        llSetTimerEvent(10);

        // Announce to controller  -  it may have rezzed us just now
        llSay(-2013, "GM_READY");

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
        else if (channel == -2013) handleControllerMessage(id, msg);
    }

    link_message(integer sender_num, integer num, string str, key id)
    {
        if (num == 42) handleLinkDebug(str);
    }

    timer()
    {
        if (!gConfigured) return;
        sendHeartbeat();
        cullStaleObjects();
    }

    on_rez(integer start_param)
    {
        llResetScript();
    }
}
