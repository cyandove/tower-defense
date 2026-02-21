// =============================================================================
// game_manager.lsl
// Tower Defense Game Manager — Phase 4c (memory optimised)
// =============================================================================
// MEMORY FIXES:
//   - initMap(): replaced 100-iteration += loop with 10-chunk append
//   - dumpMap(): replaced per-character string += with list + llDumpList2String
//   - receiveHeartbeatAck(): removed stale-ACK llOwnerSay (hot path)
//   - registerObject() / deregisterObject(): trimmed log strings
//   - cullStaleObjects(): removed per-cull llOwnerSay, kept summary only
//   - handleSpawnerReport() HANDLER_QUERY: single log line
//   - handleEnemyReport() ENEMY_POSITION: no log (fires every second per enemy)
// =============================================================================


// -----------------------------------------------------------------------------
// CHANNEL CONSTANTS
// -----------------------------------------------------------------------------
integer GM_REGISTER_CHANNEL        = -2001;
integer GM_DEREGISTER_CHANNEL      = -2002;
integer HEARTBEAT_CHANNEL          = -2003;
integer PLACEMENT_CHANNEL          = -2004;
integer TOWER_REPORT_CHANNEL       = -2005;
integer ENEMY_REPORT_CHANNEL       = -2006;
integer GM_DISCOVERY_CHANNEL       = -2007;
integer PLACEMENT_RESPONSE_CHANNEL = -2008;
integer SPAWNER_CHANNEL            = -2009;
integer ENEMY_CHANNEL              = -2010;
integer GRID_INFO_CHANNEL          = -2011;


// -----------------------------------------------------------------------------
// MAP CONSTANTS
// -----------------------------------------------------------------------------
integer MAP_WIDTH   = 10;
integer MAP_HEIGHT  = 10;
integer CELL_STRIDE = 3;

integer CELL_BLOCKED   = 0;
integer CELL_BUILDABLE = 1;
integer CELL_PATH      = 2;

integer CELL_EMPTY    = 0;
integer CELL_OCCUPIED = 1;


// -----------------------------------------------------------------------------
// REGISTRY CONSTANTS
// -----------------------------------------------------------------------------
integer REG_STRIDE = 5;

integer REG_TYPE_TOWER             = 1;
integer REG_TYPE_ENEMY             = 2;
integer REG_TYPE_SPAWNER           = 3;
integer REG_TYPE_PLACEMENT_HANDLER = 4;


// -----------------------------------------------------------------------------
// SPAWNER PAIRING TABLE  [spawner_key, handler_key, ...]
// -----------------------------------------------------------------------------
integer PAIRING_STRIDE = 2;


// -----------------------------------------------------------------------------
// ENEMY POSITION TABLE  [key, pos_x, pos_y, pos_z, timestamp, ...]
// -----------------------------------------------------------------------------
integer EP_STRIDE = 5;


// -----------------------------------------------------------------------------
// HEARTBEAT CONSTANTS
// -----------------------------------------------------------------------------
integer HEARTBEAT_INTERVAL = 10;
integer HEARTBEAT_TIMEOUT  = 3;


// -----------------------------------------------------------------------------
// GLOBAL STATE
// -----------------------------------------------------------------------------
list    gMap             = [];
list    gRegistry        = [];
list    gEnemyPositions  = [];
list    gSpawnerPairings = [];
integer gHeartbeatSeq    = 0;
integer gLives           = 20;
integer gWaveActive      = FALSE;


// =============================================================================
// MAP HELPERS
// =============================================================================

integer cellIndex(integer x, integer y)
{
    return (y * MAP_WIDTH + x) * CELL_STRIDE;
}

integer inBounds(integer x, integer y)
{
    return (x >= 0 && x < MAP_WIDTH && y >= 0 && y < MAP_HEIGHT);
}

integer getCellType(integer x, integer y)
{
    if (!inBounds(x, y)) return CELL_BLOCKED;
    return llList2Integer(gMap, cellIndex(x, y));
}

integer getCellOccupied(integer x, integer y)
{
    if (!inBounds(x, y)) return CELL_OCCUPIED;
    return llList2Integer(gMap, cellIndex(x, y) + 1);
}

setCell(integer x, integer y, integer type, integer occupied)
{
    if (!inBounds(x, y)) return;
    integer idx = cellIndex(x, y);
    gMap = llListReplaceList(gMap, [type, occupied, 0], idx, idx + CELL_STRIDE - 1);
}

setCellOccupied(integer x, integer y, integer flag)
{
    if (!inBounds(x, y)) return;
    integer idx = cellIndex(x, y) + 1;
    gMap = llListReplaceList(gMap, [flag], idx, idx);
}

integer isPlaceable(integer x, integer y)
{
    return (getCellType(x, y) == CELL_BUILDABLE && getCellOccupied(x, y) == CELL_EMPTY);
}

initMap()
{
    // Build one row of 10 cells (30 entries) then append it 10 times.
    // Avoids 100 individual list copies from a single-entry += loop.
    list row = [ 1,0,0, 1,0,0, 1,0,0, 1,0,0, 1,0,0,
                 1,0,0, 1,0,0, 1,0,0, 1,0,0, 1,0,0 ];
    gMap = [];
    integer i;
    for (i = 0; i < MAP_HEIGHT; i++)
        gMap += row;

    // Path cells
    setCell(2, 0, CELL_PATH, CELL_EMPTY);
    setCell(2, 1, CELL_PATH, CELL_EMPTY);
    setCell(2, 2, CELL_PATH, CELL_EMPTY);
    setCell(2, 3, CELL_PATH, CELL_EMPTY);
    setCell(2, 4, CELL_PATH, CELL_EMPTY);
    setCell(3, 4, CELL_PATH, CELL_EMPTY);
    setCell(4, 4, CELL_PATH, CELL_EMPTY);
    setCell(5, 4, CELL_PATH, CELL_EMPTY);
    setCell(6, 4, CELL_PATH, CELL_EMPTY);
    setCell(7, 4, CELL_PATH, CELL_EMPTY);
    setCell(7, 5, CELL_PATH, CELL_EMPTY);
    setCell(7, 6, CELL_PATH, CELL_EMPTY);
    setCell(7, 7, CELL_PATH, CELL_EMPTY);
    setCell(6, 7, CELL_PATH, CELL_EMPTY);
    setCell(5, 7, CELL_PATH, CELL_EMPTY);
    setCell(4, 7, CELL_PATH, CELL_EMPTY);
    setCell(3, 7, CELL_PATH, CELL_EMPTY);
    setCell(2, 7, CELL_PATH, CELL_EMPTY);
    setCell(2, 8, CELL_PATH, CELL_EMPTY);
    setCell(2, 9, CELL_PATH, CELL_EMPTY);

    // Blocked cells
    setCell(0, 0, CELL_BLOCKED, CELL_EMPTY);
    setCell(1, 0, CELL_BLOCKED, CELL_EMPTY);
    setCell(9, 9, CELL_BLOCKED, CELL_EMPTY);
    setCell(8, 9, CELL_BLOCKED, CELL_EMPTY);

    llOwnerSay("[GM] Map ready. Mem: " + (string)llGetFreeMemory() + "b");
}

dumpMap()
{
    // Build each row as a list then join once with llDumpList2String.
    // Avoids repeated string copies from row += ch in a loop.
    llOwnerSay("[MAP] y=0 is top");
    integer y;
    for (y = 0; y < MAP_HEIGHT; y++)
    {
        list cells = [];
        integer x;
        for (x = 0; x < MAP_WIDTH; x++)
        {
            integer t = getCellType(x, y);
            integer o = getCellOccupied(x, y);
            string ch;
            if      (t == CELL_PATH)    ch = "P";
            else if (t == CELL_BLOCKED) ch = "X";
            else                        ch = "B";
            if (o == CELL_OCCUPIED)     ch = llToLower(ch);
            cells += [ch];
        }
        llOwnerSay("y" + (string)y + " " + llDumpList2String(cells, " "));
    }
}


// =============================================================================
// REGISTRY HELPERS
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

    gRegistry = llDeleteSubList(gRegistry, idx, idx + REG_STRIDE - 1);

    if (obj_type == REG_TYPE_TOWER)
        setCellOccupied(gx, gy, CELL_EMPTY);
    if (obj_type == REG_TYPE_ENEMY)
        removeEnemyPosition(id);
    if (obj_type == REG_TYPE_SPAWNER)
        removeSpawnerPairing(id);
    if (obj_type == REG_TYPE_PLACEMENT_HANDLER)
        removePairingsForHandler(id);

    llOwnerSay("[REG] -" + (string)obj_type + " " + (string)id);
}

integer registryCount()
{
    return llGetListLength(gRegistry) / REG_STRIDE;
}

key findRegisteredHandler()
{
    integer count = registryCount();
    integer i;
    for (i = 0; i < count; i++)
    {
        integer idx = i * REG_STRIDE;
        if (llList2Integer(gRegistry, idx + 1) == REG_TYPE_PLACEMENT_HANDLER)
            return (key)llList2String(gRegistry, idx);
    }
    return NULL_KEY;
}

dumpRegistry()
{
    integer count = registryCount();
    llOwnerSay("[REG] --- " + (string)count + " objects ---");
    integer i;
    for (i = 0; i < count; i++)
    {
        integer idx      = i * REG_STRIDE;
        integer obj_type = llList2Integer(gRegistry, idx + 1);
        integer age      = llGetUnixTime() - llList2Integer(gRegistry, idx + 4);

        string type_label;
        if      (obj_type == REG_TYPE_TOWER)             type_label = "TWR";
        else if (obj_type == REG_TYPE_ENEMY)             type_label = "ENM";
        else if (obj_type == REG_TYPE_SPAWNER)           type_label = "SPN";
        else if (obj_type == REG_TYPE_PLACEMENT_HANDLER) type_label = "PLH";
        else                                             type_label = "UNK";

        llOwnerSay("[REG] " + type_label
            + " (" + (string)llList2Integer(gRegistry, idx + 2)
            + "," + (string)llList2Integer(gRegistry, idx + 3) + ")"
            + " " + (string)age + "s"
            + " " + llList2String(gRegistry, idx));
    }
}


// =============================================================================
// HEARTBEAT HELPERS
// =============================================================================

sendHeartbeat()
{
    gHeartbeatSeq++;
    integer count = registryCount();
    if (count == 0) return;

    string ping = "PING|" + (string)gHeartbeatSeq;
    integer i;
    for (i = 0; i < count; i++)
        llRegionSayTo((key)llList2String(gRegistry, i * REG_STRIDE),
            HEARTBEAT_CHANNEL, ping);
}

receiveHeartbeatAck(key id, integer seq)
{
    // Silently drop stale ACKs — logging here fires on every enemy every cycle
    if (seq != gHeartbeatSeq) return;
    integer idx = findRegistryEntry(id);
    if (idx == -1) return;
    gRegistry = llListReplaceList(gRegistry,
        [llGetUnixTime()], idx + 4, idx + 4);
}

cullStaleObjects()
{
    integer threshold = llGetUnixTime() - (HEARTBEAT_INTERVAL * HEARTBEAT_TIMEOUT);
    integer i = registryCount() - 1;
    integer culled = 0;

    for (; i >= 0; i--)
    {
        integer idx = i * REG_STRIDE;
        if (llList2Integer(gRegistry, idx + 4) < threshold)
        {
            integer obj_type = llList2Integer(gRegistry, idx + 1);
            integer gx       = llList2Integer(gRegistry, idx + 2);
            integer gy       = llList2Integer(gRegistry, idx + 3);
            key     cid      = (key)llList2String(gRegistry, idx);

            gRegistry = llDeleteSubList(gRegistry, idx, idx + REG_STRIDE - 1);

            if (obj_type == REG_TYPE_TOWER)
                setCellOccupied(gx, gy, CELL_EMPTY);
            if (obj_type == REG_TYPE_ENEMY)
                removeEnemyPosition(cid);
            if (obj_type == REG_TYPE_SPAWNER)
                removeSpawnerPairing(cid);
            if (obj_type == REG_TYPE_PLACEMENT_HANDLER)
                removePairingsForHandler(cid);

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
    llRegionSayTo(sender, GM_DISCOVERY_CHANNEL, "GM_HERE|" + (string)llGetKey());
}


// =============================================================================
// SPAWNER PAIRING TABLE
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
        gSpawnerPairings = llDeleteSubList(gSpawnerPairings,
            idx, idx + PAIRING_STRIDE - 1);
}

removePairingsForHandler(key handler_key)
{
    integer count = llGetListLength(gSpawnerPairings) / PAIRING_STRIDE;
    integer i = count - 1;
    for (; i >= 0; i--)
    {
        integer idx = i * PAIRING_STRIDE;
        if ((key)llList2String(gSpawnerPairings, idx + 1) == handler_key)
            gSpawnerPairings = llDeleteSubList(gSpawnerPairings,
                idx, idx + PAIRING_STRIDE - 1);
    }
}

key getPairedHandler(key spawner_key)
{
    integer idx = findSpawnerPairing(spawner_key);
    if (idx == -1) return NULL_KEY;
    return (key)llList2String(gSpawnerPairings, idx + 1);
}

dumpPairings()
{
    integer count = llGetListLength(gSpawnerPairings) / PAIRING_STRIDE;
    llOwnerSay("[PAIR] --- " + (string)count + " pairs ---");
    integer i;
    for (i = 0; i < count; i++)
    {
        integer idx = i * PAIRING_STRIDE;
        llOwnerSay("[PAIR] " + llList2String(gSpawnerPairings, idx)
            + " -> " + llList2String(gSpawnerPairings, idx + 1));
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
    if (handler_idx == -1 ||
        llList2Integer(gRegistry, handler_idx + 1) != REG_TYPE_PLACEMENT_HANDLER)
    {
        llRegionSayTo(sender, GRID_INFO_CHANNEL, "GRID_INFO_ERROR|HANDLER_NOT_REGISTERED");
        return;
    }

    llRegionSayTo(handler_key, GRID_INFO_CHANNEL,
        "GRID_INFO_REQUEST|" + (string)spawner_key);
}


// =============================================================================
// ENEMY POSITION TABLE
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
        gEnemyPositions = llDeleteSubList(gEnemyPositions, idx, idx + EP_STRIDE - 1);
}

integer enemyCount()
{
    return llGetListLength(gEnemyPositions) / EP_STRIDE;
}


// =============================================================================
// ENEMY REPORT HANDLER
// =============================================================================

handleEnemyReport(key sender, string msg)
{
    list parts = llParseString2List(msg, ["|"], []);
    string cmd = llList2String(parts, 0);

    if (cmd == "ENEMY_POSITION")
    {
        if (llGetListLength(parts) < 4) return;
        // No llOwnerSay here — this fires every second per enemy
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
    else
    {
        llOwnerSay("[EN] Unknown: " + cmd);
    }
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
        llRegionSayTo(sender, SPAWNER_CHANNEL, "HANDLER_INFO|" + (string)handler_key);
        llOwnerSay("[SP] HANDLER_QUERY -> " + (string)handler_key);
    }
    else if (cmd == "SPAWNER_PAIRED")
    {
        if (llGetListLength(parts) < 2) return;
        key handler_key = (key)llList2String(parts, 1);

        integer handler_idx = findRegistryEntry(handler_key);
        if (handler_idx == -1 ||
            llList2Integer(gRegistry, handler_idx + 1) != REG_TYPE_PLACEMENT_HANDLER)
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
        integer idx = i * REG_STRIDE;
        if (llList2Integer(gRegistry, idx + 1) == REG_TYPE_SPAWNER)
        {
            llRegionSayTo((key)llList2String(gRegistry, idx),
                SPAWNER_CHANNEL, "WAVE_START|1");
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

approvePlacement(key handler, integer gx, integer gy, key avatar)
{
    setCellOccupied(gx, gy, CELL_OCCUPIED);
    llRegionSayTo(handler, PLACEMENT_RESPONSE_CHANNEL,
        "PLACEMENT_OK|" + (string)gx + "|" + (string)gy + "|" + (string)avatar);
    llOwnerSay("[PL] OK (" + (string)gx + "," + (string)gy + ")");
}

denyPlacement(key handler, integer gx, integer gy, key avatar, string reason)
{
    llRegionSayTo(handler, PLACEMENT_RESPONSE_CHANNEL,
        "PLACEMENT_DENIED|" + (string)gx + "|" + (string)gy
        + "|" + (string)avatar + "|" + reason);
    llOwnerSay("[PL] Denied " + reason + " (" + (string)gx + "," + (string)gy + ")");
}

handlePlacementRequest(key sender, string msg)
{
    if (sender != llGetKey())
    {
        integer sender_idx = findRegistryEntry(sender);
        if (sender_idx == -1 ||
            llList2Integer(gRegistry, sender_idx + 1) != REG_TYPE_PLACEMENT_HANDLER)
        {
            llRegionSayTo(sender, PLACEMENT_RESPONSE_CHANNEL,
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
    {
        denyPlacement(sender, gx, gy, avatar, "OUT_OF_BOUNDS");
        return;
    }
    if (getCellType(gx, gy) != CELL_BUILDABLE)
    {
        denyPlacement(sender, gx, gy, avatar, "NOT_BUILDABLE");
        return;
    }
    if (getCellOccupied(gx, gy) == CELL_OCCUPIED)
    {
        denyPlacement(sender, gx, gy, avatar, "CELL_OCCUPIED");
        return;
    }

    approvePlacement(sender, gx, gy, avatar);
}


// =============================================================================
// REGISTRATION HELPERS
// =============================================================================

integer checkPlacementHandlerSlot(key sender)
{
    integer count = registryCount();
    integer i;
    for (i = 0; i < count; i++)
    {
        integer idx      = i * REG_STRIDE;
        key existing_key = (key)llList2String(gRegistry, idx);
        if (llList2Integer(gRegistry, idx + 1) == REG_TYPE_PLACEMENT_HANDLER
            && existing_key != sender)
        {
            llRegionSayTo(sender, GM_REGISTER_CHANNEL,
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

    if (obj_type < REG_TYPE_TOWER || obj_type > REG_TYPE_PLACEMENT_HANDLER)
    {
        llOwnerSay("[REG] Unknown type " + (string)obj_type);
        return;
    }

    if (obj_type == REG_TYPE_PLACEMENT_HANDLER)
    {
        if (!checkPlacementHandlerSlot(sender))
            return;
    }

    registerObject(sender, obj_type, gx, gy);
    llRegionSayTo(sender, GM_REGISTER_CHANNEL, "REGISTER_OK|" + (string)obj_type);
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
// DEBUG COMMANDS
// =============================================================================

handleSetCommand(string msg)
{
    list parts = llParseString2List(msg, [" "], []);
    if (llGetListLength(parts) < 5)
    {
        llOwnerSay("[GM] Usage: /td set <x> <y> <build|path|blocked>");
        return;
    }
    integer x       = (integer)llList2String(parts, 2);
    integer y       = (integer)llList2String(parts, 3);
    string type_str = llToLower(llList2String(parts, 4));

    if (!inBounds(x, y))
    {
        llOwnerSay("[GM] Out of bounds");
        return;
    }

    integer new_type;
    integer new_occupied;
    if (type_str == "build")
    {
        new_type     = CELL_BUILDABLE;
        new_occupied = getCellOccupied(x, y);
    }
    else if (type_str == "path")
    {
        new_type     = CELL_PATH;
        new_occupied = CELL_EMPTY;
    }
    else if (type_str == "blocked")
    {
        new_type     = CELL_BLOCKED;
        new_occupied = CELL_EMPTY;
    }
    else
    {
        llOwnerSay("[GM] Unknown type: " + type_str);
        return;
    }

    setCell(x, y, new_type, new_occupied);
    llOwnerSay("[MAP] (" + (string)x + "," + (string)y + ") = " + type_str);
}

handleDebugCommand(string msg)
{
    if (msg == "/td dump map")
        dumpMap();
    else if (msg == "/td dump registry")
        dumpRegistry();
    else if (msg == "/td dump pairings")
        dumpPairings();
    else if (msg == "/td dump all")
    {
        dumpMap();
        dumpRegistry();
        dumpPairings();
    }
    else if (msg == "/td stats")
    {
        llOwnerSay("[GM] Objs:" + (string)registryCount()
            + " Enemies:" + (string)enemyCount()
            + " Pairs:" + (string)(llGetListLength(gSpawnerPairings) / PAIRING_STRIDE)
            + " Lives:" + (string)gLives
            + " Wave:" + (string)gWaveActive
            + " HB:" + (string)gHeartbeatSeq
            + " Mem:" + (string)llGetFreeMemory() + "b");
    }
    else if (llGetSubString(msg, 0, 7) == "/td set ")
        handleSetCommand(msg);
    else if (msg == "/td wave start")
        startWave();
    else if (msg == "/td test placement")
    {
        integer cx = MAP_WIDTH  / 2;
        integer cy = MAP_HEIGHT / 2;
        key fake_avatar = llGetOwner();

        llOwnerSay("[PL] --- TEST ---");
        handlePlacementRequest(llGetKey(),
            "PLACEMENT_REQUEST|" + (string)cx + "|" + (string)cy
            + "|" + (string)fake_avatar);
        handlePlacementRequest(llGetKey(),
            "PLACEMENT_REQUEST|" + (string)cx + "|" + (string)cy
            + "|" + (string)fake_avatar);
        handlePlacementRequest(llGetKey(),
            "PLACEMENT_REQUEST|2|0|" + (string)fake_avatar);
        handlePlacementRequest(llGetKey(),
            "PLACEMENT_REQUEST|0|0|" + (string)fake_avatar);
        setCellOccupied(cx, cy, CELL_EMPTY);
        llOwnerSay("[PL] --- DONE ---");
    }
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

        llListen(GM_REGISTER_CHANNEL,        "", NULL_KEY, "");
        llListen(GM_DEREGISTER_CHANNEL,      "", NULL_KEY, "");
        llListen(HEARTBEAT_CHANNEL,          "", NULL_KEY, "");
        llListen(PLACEMENT_CHANNEL,          "", NULL_KEY, "");
        llListen(GM_DISCOVERY_CHANNEL,       "", NULL_KEY, "");
        llListen(ENEMY_REPORT_CHANNEL,       "", NULL_KEY, "");
        llListen(SPAWNER_CHANNEL,            "", NULL_KEY, "");
        llListen(GRID_INFO_CHANNEL,          "", NULL_KEY, "");
        llListen(0, "", llGetOwner(), "");

        llSetTimerEvent(HEARTBEAT_INTERVAL);

        llOwnerSay("[GM] Key: " + (string)llGetKey());
        llOwnerSay("[GM] Mem: " + (string)llGetFreeMemory() + "b");
        llOwnerSay("[GM] /td: dump map|registry|pairings|all|stats|wave start|test placement|set <x> <y> <type>");
    }

    listen(integer channel, string name, key id, string msg)
    {
        if      (channel == GM_REGISTER_CHANNEL)   handleRegisterMessage(id, msg);
        else if (channel == GM_DEREGISTER_CHANNEL) handleDeregisterMessage(id, msg);
        else if (channel == HEARTBEAT_CHANNEL)     handleHeartbeatMessage(id, msg);
        else if (channel == PLACEMENT_CHANNEL)     handlePlacementRequest(id, msg);
        else if (channel == GM_DISCOVERY_CHANNEL)  handleDiscoveryMessage(id, msg);
        else if (channel == ENEMY_REPORT_CHANNEL)  handleEnemyReport(id, msg);
        else if (channel == SPAWNER_CHANNEL)       handleSpawnerReport(id, msg);
        else if (channel == GRID_INFO_CHANNEL)     handleGridInfoRequest(id, msg);
        else if (channel == 0 && id == llGetOwner())
        {
            if (llGetSubString(msg, 0, 2) == "/td")
                handleDebugCommand(msg);
        }
    }

    timer()
    {
        sendHeartbeat();
        cullStaleObjects();
    }
}
