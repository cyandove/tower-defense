// =============================================================================
// game_manager.lsl
// Tower Defense Game Manager — Phase 4c
// Adds: automated spawner/handler pairing via HANDLER_QUERY flow
// =============================================================================
// PHASE 4c CHANGES:
//   - Spawner registration no longer requires a handler key in the message
//   - Added HANDLER_QUERY handling in handleSpawnerReport():
//       spawner sends HANDLER_QUERY, GM responds with HANDLER_INFO|<key>
//       (or HANDLER_INFO|NULL_KEY if no handler registered yet)
//   - Added SPAWNER_PAIRED handling: spawner confirms its paired handler key,
//       GM stores the pairing in gSpawnerPairings
//   - handleRegisterMessage() no longer parses 5th field for spawners
// =============================================================================


// -----------------------------------------------------------------------------
// CHANNEL CONSTANTS
// Copy these into every script that needs to communicate with the GM.
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
integer MAP_WIDTH  = 10;
integer MAP_HEIGHT = 10;
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
// SPAWNER PAIRING TABLE
// [spawner_key, handler_key, ...]
// One handler may appear multiple times. One spawner appears at most once.
// -----------------------------------------------------------------------------
integer PAIRING_STRIDE = 2;


// -----------------------------------------------------------------------------
// ENEMY POSITION TABLE
// [key, pos_x, pos_y, pos_z, last_update_timestamp, ...]
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
    if (!inBounds(x, y))
    {
        llOwnerSay("[MAP] setCell out of bounds: " + (string)x + "," + (string)y);
        return;
    }
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
    gMap = [];
    integer total = MAP_WIDTH * MAP_HEIGHT;
    integer i;
    for (i = 0; i < total; i++)
    {
        gMap += [CELL_BUILDABLE, CELL_EMPTY, 0];
    }

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

    setCell(0, 0, CELL_BLOCKED, CELL_EMPTY);
    setCell(1, 0, CELL_BLOCKED, CELL_EMPTY);
    setCell(9, 9, CELL_BLOCKED, CELL_EMPTY);
    setCell(8, 9, CELL_BLOCKED, CELL_EMPTY);

    llOwnerSay("[MAP] Initialized " + (string)MAP_WIDTH + "x" + (string)MAP_HEIGHT + " grid.");
}

dumpMap()
{
    llOwnerSay("[MAP] --- MAP DUMP (y=0 top, y=" + (string)(MAP_HEIGHT-1) + " bottom) ---");
    integer y;
    for (y = 0; y < MAP_HEIGHT; y++)
    {
        string row = "[MAP] y=" + (string)y + " | ";
        integer x;
        for (x = 0; x < MAP_WIDTH; x++)
        {
            integer t = getCellType(x, y);
            integer o = getCellOccupied(x, y);
            string ch;
            if      (t == CELL_PATH)      ch = "P";
            else if (t == CELL_BLOCKED)   ch = "X";
            else                          ch = "B";
            if (o == CELL_OCCUPIED)       ch = llToLower(ch);
            row += ch + " ";
        }
        llOwnerSay(row);
    }
    llOwnerSay("[MAP] --- END DUMP ---");
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
            [llGetUnixTime()],
            existing + 4, existing + 4);
        llOwnerSay("[REG] Re-registered: " + (string)id + " (type=" + (string)obj_type + ")");
        return;
    }
    gRegistry += [(string)id, obj_type, gx, gy, llGetUnixTime()];
    llOwnerSay("[REG] Registered: " + (string)id
        + " type=" + (string)obj_type
        + " grid=(" + (string)gx + "," + (string)gy + ")");
}

deregisterObject(key id)
{
    integer idx = findRegistryEntry(id);
    if (idx == -1)
    {
        llOwnerSay("[REG] Deregister: unknown key " + (string)id);
        return;
    }

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

    llOwnerSay("[REG] Deregistered: " + (string)id);
}

integer registryCount()
{
    return llGetListLength(gRegistry) / REG_STRIDE;
}

// Returns the key of the first registered placement handler, or NULL_KEY.
key findRegisteredHandler()
{
    integer count = registryCount();
    integer i;
    for (i = 0; i < count; i++)
    {
        integer idx      = i * REG_STRIDE;
        integer obj_type = llList2Integer(gRegistry, idx + 1);
        if (obj_type == REG_TYPE_PLACEMENT_HANDLER)
            return (key)llList2String(gRegistry, idx);
    }
    return NULL_KEY;
}

dumpRegistry()
{
    integer count = registryCount();
    llOwnerSay("[REG] --- REGISTRY DUMP (" + (string)count + " objects) ---");
    integer i;
    for (i = 0; i < count; i++)
    {
        integer idx       = i * REG_STRIDE;
        string  id        = llList2String (gRegistry, idx);
        integer obj_type  = llList2Integer(gRegistry, idx + 1);
        integer gx        = llList2Integer(gRegistry, idx + 2);
        integer gy        = llList2Integer(gRegistry, idx + 3);
        integer last_seen = llList2Integer(gRegistry, idx + 4);
        integer age       = llGetUnixTime() - last_seen;

        string type_label;
        if      (obj_type == REG_TYPE_TOWER)             type_label = "TOWER";
        else if (obj_type == REG_TYPE_ENEMY)             type_label = "ENEMY";
        else if (obj_type == REG_TYPE_SPAWNER)           type_label = "SPAWNER";
        else if (obj_type == REG_TYPE_PLACEMENT_HANDLER) type_label = "PLACEMENT_HANDLER";
        else                                             type_label = "UNKNOWN";

        llOwnerSay("[REG] [" + (string)i + "] " + type_label
            + " grid=(" + (string)gx + "," + (string)gy + ")"
            + " last_seen=" + (string)age + "s ago"
            + " key=" + id);
    }
    llOwnerSay("[REG] --- END DUMP ---");
}


// =============================================================================
// HEARTBEAT HELPERS
// =============================================================================

sendHeartbeat()
{
    gHeartbeatSeq++;
    integer count = registryCount();
    if (count == 0) return;

    string ping_msg = "PING|" + (string)gHeartbeatSeq;
    integer i;
    for (i = 0; i < count; i++)
    {
        key target = (key)llList2String(gRegistry, i * REG_STRIDE);
        llRegionSayTo(target, HEARTBEAT_CHANNEL, ping_msg);
    }
    llOwnerSay("[HB] Sent PING #" + (string)gHeartbeatSeq
        + " to " + (string)count + " object(s).");
}

receiveHeartbeatAck(key id, integer seq)
{
    if (seq != gHeartbeatSeq)
    {
        llOwnerSay("[HB] Stale ACK from " + (string)id
            + " (seq=" + (string)seq + " expected=" + (string)gHeartbeatSeq + ")");
        return;
    }
    integer idx = findRegistryEntry(id);
    if (idx == -1) return;
    gRegistry = llListReplaceList(gRegistry,
        [llGetUnixTime()],
        idx + 4, idx + 4);
}

cullStaleObjects()
{
    integer threshold = llGetUnixTime() - (HEARTBEAT_INTERVAL * HEARTBEAT_TIMEOUT);
    integer i = registryCount() - 1;
    integer culled_count = 0;

    for (; i >= 0; i--)
    {
        integer idx       = i * REG_STRIDE;
        integer last_seen = llList2Integer(gRegistry, idx + 4);

        if (last_seen < threshold)
        {
            integer obj_type  = llList2Integer(gRegistry, idx + 1);
            integer gx        = llList2Integer(gRegistry, idx + 2);
            integer gy        = llList2Integer(gRegistry, idx + 3);
            string culled_key = llList2String(gRegistry, idx);

            llOwnerSay("[HB] Culling stale object: " + culled_key
                + " (last seen " + (string)(llGetUnixTime() - last_seen) + "s ago)");

            gRegistry = llDeleteSubList(gRegistry, idx, idx + REG_STRIDE - 1);

            if (obj_type == REG_TYPE_TOWER)
                setCellOccupied(gx, gy, CELL_EMPTY);
            if (obj_type == REG_TYPE_ENEMY)
                removeEnemyPosition((key)culled_key);
            if (obj_type == REG_TYPE_SPAWNER)
                removeSpawnerPairing((key)culled_key);
            if (obj_type == REG_TYPE_PLACEMENT_HANDLER)
                removePairingsForHandler((key)culled_key);

            culled_count++;
        }
    }

    if (culled_count > 0)
    {
        llOwnerSay("[HB] Culled " + (string)culled_count + " stale object(s). "
            + "Registry size: " + (string)registryCount());
    }
}


// =============================================================================
// DISCOVERY
// =============================================================================

handleDiscoveryMessage(key sender, string msg)
{
    if (msg != "GM_DISCOVER") return;
    llRegionSayTo(sender, GM_DISCOVERY_CHANNEL, "GM_HERE|" + (string)llGetKey());
    llOwnerSay("[GM] Discovery response sent to " + (string)sender);
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
    {
        gSpawnerPairings = llDeleteSubList(gSpawnerPairings,
            idx, idx + PAIRING_STRIDE - 1);
        llOwnerSay("[PAIR] Removed pairing for spawner: " + (string)spawner_key);
    }
}

removePairingsForHandler(key handler_key)
{
    integer count = llGetListLength(gSpawnerPairings) / PAIRING_STRIDE;
    integer i = count - 1;
    for (; i >= 0; i--)
    {
        integer idx = i * PAIRING_STRIDE;
        if ((key)llList2String(gSpawnerPairings, idx + 1) == handler_key)
        {
            key spawner = (key)llList2String(gSpawnerPairings, idx);
            gSpawnerPairings = llDeleteSubList(gSpawnerPairings,
                idx, idx + PAIRING_STRIDE - 1);
            llOwnerSay("[PAIR] Removed pairing for spawner " + (string)spawner
                + " (handler removed)");
        }
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
    llOwnerSay("[PAIR] --- PAIRING DUMP (" + (string)count + " pairs) ---");
    integer i;
    for (i = 0; i < count; i++)
    {
        integer idx = i * PAIRING_STRIDE;
        llOwnerSay("[PAIR] [" + (string)i + "] spawner="
            + llList2String(gSpawnerPairings, idx)
            + " -> handler="
            + llList2String(gSpawnerPairings, idx + 1));
    }
    llOwnerSay("[PAIR] --- END DUMP ---");
}


// =============================================================================
// GRID INFO FORWARDING
// =============================================================================

// Handles GRID_INFO_REQUEST from a spawner.
// The spawner sends its own key and the handler key it was given.
// The GM validates the handler is registered and forwards the request.
// Format: GRID_INFO_REQUEST|<spawner_key>|<handler_key>
handleGridInfoRequest(key sender, string msg)
{
    list parts = llParseString2List(msg, ["|"], []);
    if (llGetListLength(parts) < 3)
    {
        llOwnerSay("[GRID] Malformed GRID_INFO_REQUEST from " + (string)sender);
        return;
    }

    key spawner_key = (key)llList2String(parts, 1);
    key handler_key = (key)llList2String(parts, 2);

    if (sender != spawner_key)
    {
        llOwnerSay("[GRID] Sender mismatch in GRID_INFO_REQUEST: " + (string)sender);
        return;
    }

    integer handler_idx = findRegistryEntry(handler_key);
    if (handler_idx == -1 ||
        llList2Integer(gRegistry, handler_idx + 1) != REG_TYPE_PLACEMENT_HANDLER)
    {
        llOwnerSay("[GRID] Handler not registered: " + (string)handler_key);
        llRegionSayTo(sender, GRID_INFO_CHANNEL, "GRID_INFO_ERROR|HANDLER_NOT_REGISTERED");
        return;
    }

    llRegionSayTo(handler_key, GRID_INFO_CHANNEL,
        "GRID_INFO_REQUEST|" + (string)spawner_key);
    llOwnerSay("[GRID] Forwarded grid info request: spawner=" + (string)spawner_key
        + " handler=" + (string)handler_key);
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
            [pos.x, pos.y, pos.z, llGetUnixTime()],
            idx + 1, idx + 4);
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
        vector pos = <(float)llList2String(parts, 1),
                      (float)llList2String(parts, 2),
                      (float)llList2String(parts, 3)>;
        upsertEnemyPosition(sender, pos);
    }
    else if (cmd == "ENEMY_ARRIVED")
    {
        gLives--;
        llOwnerSay("[EN] Enemy reached end. Lives: " + (string)gLives);
        removeEnemyPosition(sender);
        deregisterObject(sender);
    }
    else
    {
        llOwnerSay("[EN] Unknown enemy report: " + cmd);
    }
}


// =============================================================================
// SPAWNER HANDLER
// =============================================================================

// Handles messages from spawners on SPAWNER_CHANNEL.
//
// SPAWNER_READY
//   Spawner has registered and is announcing readiness.
//
// HANDLER_QUERY
//   Spawner is asking the GM for the key of the registered placement handler.
//   GM responds with HANDLER_INFO|<key> — NULL_KEY if none registered yet.
//
// SPAWNER_PAIRED|<handler_key>
//   Spawner confirms which handler it paired with. GM stores the association.
handleSpawnerReport(key sender, string msg)
{
    list parts = llParseString2List(msg, ["|"], []);
    string cmd = llList2String(parts, 0);

    if (cmd == "SPAWNER_READY")
    {
        llOwnerSay("[SP] Spawner ready: " + (string)sender);
    }
    else if (cmd == "HANDLER_QUERY")
    {
        key handler_key = findRegisteredHandler();
        llRegionSayTo(sender, SPAWNER_CHANNEL,
            "HANDLER_INFO|" + (string)handler_key);
        if (handler_key == NULL_KEY)
            llOwnerSay("[SP] HANDLER_QUERY from " + (string)sender
                + " — no handler registered yet.");
        else
            llOwnerSay("[SP] HANDLER_QUERY from " + (string)sender
                + " — replied with " + (string)handler_key);
    }
    else if (cmd == "SPAWNER_PAIRED")
    {
        if (llGetListLength(parts) < 2)
        {
            llOwnerSay("[SP] Malformed SPAWNER_PAIRED from " + (string)sender);
            return;
        }
        key handler_key = (key)llList2String(parts, 1);

        // Validate handler is still registered before storing pairing
        integer handler_idx = findRegistryEntry(handler_key);
        if (handler_idx == -1 ||
            llList2Integer(gRegistry, handler_idx + 1) != REG_TYPE_PLACEMENT_HANDLER)
        {
            llOwnerSay("[PAIR] Rejected SPAWNER_PAIRED — handler not registered: "
                + (string)handler_key);
            return;
        }

        setSpawnerPairing(sender, handler_key);
        llOwnerSay("[PAIR] Spawner " + (string)sender
            + " paired with handler " + (string)handler_key);
    }
    else
    {
        llOwnerSay("[SP] Unknown spawner message: " + cmd);
    }
}

startWave()
{
    integer count = registryCount();
    integer sent  = 0;
    integer i;
    for (i = 0; i < count; i++)
    {
        integer idx      = i * REG_STRIDE;
        integer obj_type = llList2Integer(gRegistry, idx + 1);
        if (obj_type == REG_TYPE_SPAWNER)
        {
            key target = (key)llList2String(gRegistry, idx);
            llRegionSayTo(target, SPAWNER_CHANNEL, "WAVE_START|1");
            sent++;
        }
    }
    if (sent == 0)
        llOwnerSay("[GM] /td wave start: no spawners registered.");
    else
    {
        gWaveActive = TRUE;
        llOwnerSay("[GM] Wave started. Sent WAVE_START to " + (string)sent + " spawner(s).");
    }
}


// =============================================================================
// PLACEMENT VALIDATION
// =============================================================================

approvePlacement(key handler, integer gx, integer gy, key avatar)
{
    setCellOccupied(gx, gy, CELL_OCCUPIED);
    string response = "PLACEMENT_OK"
        + "|" + (string)gx
        + "|" + (string)gy
        + "|" + (string)avatar;
    llRegionSayTo(handler, PLACEMENT_RESPONSE_CHANNEL, response);
    llOwnerSay("[PL] Approved: grid (" + (string)gx + "," + (string)gy
        + ") for " + llKey2Name(avatar));
}

denyPlacement(key handler, integer gx, integer gy, key avatar, string reason)
{
    string response = "PLACEMENT_DENIED"
        + "|" + (string)gx
        + "|" + (string)gy
        + "|" + (string)avatar
        + "|" + reason;
    llRegionSayTo(handler, PLACEMENT_RESPONSE_CHANNEL, response);
    llOwnerSay("[PL] Denied (" + reason + "): grid ("
        + (string)gx + "," + (string)gy + ") for " + llKey2Name(avatar));
}

handlePlacementRequest(key sender, string msg)
{
    if (sender != llGetKey())
    {
        integer sender_idx = findRegistryEntry(sender);
        if (sender_idx == -1 ||
            llList2Integer(gRegistry, sender_idx + 1) != REG_TYPE_PLACEMENT_HANDLER)
        {
            llOwnerSay("[PL] Rejected request from unregistered sender: " + (string)sender);
            llRegionSayTo(sender, PLACEMENT_RESPONSE_CHANNEL,
                "PLACEMENT_DENIED|0|0|" + (string)sender + "|NOT_REGISTERED");
            return;
        }
    }

    list parts = llParseString2List(msg, ["|"], []);
    if (llGetListLength(parts) < 4) return;
    string cmd = llList2String(parts, 0);
    integer gx = (integer)llList2String(parts, 1);
    integer gy = (integer)llList2String(parts, 2);
    key avatar = (key)llList2String(parts, 3);

    if (cmd != "PLACEMENT_REQUEST") return;

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
    integer i;
    integer count = registryCount();
    for (i = 0; i < count; i++)
    {
        integer idx      = i * REG_STRIDE;
        integer obj_type = llList2Integer(gRegistry, idx + 1);
        key existing_key = (key)llList2String(gRegistry, idx);
        if (obj_type == REG_TYPE_PLACEMENT_HANDLER && existing_key != sender)
        {
            llRegionSayTo(sender, GM_REGISTER_CHANNEL,
                "REGISTER_REJECTED|PLACEMENT_HANDLER_ALREADY_REGISTERED|"
                + (string)existing_key);
            llOwnerSay("[REG] Rejected duplicate placement handler: " + (string)sender);
            return FALSE;
        }
    }
    return TRUE;
}

handleRegisterMessage(key sender, string msg)
{
    list parts = llParseString2List(msg, ["|"], []);
    if (llGetListLength(parts) < 4)
    {
        llOwnerSay("[REG] Malformed register message from " + (string)sender + ": " + msg);
        return;
    }
    string cmd       = llList2String(parts, 0);
    integer obj_type = (integer)llList2String(parts, 1);
    integer gx       = (integer)llList2String(parts, 2);
    integer gy       = (integer)llList2String(parts, 3);

    if (cmd != "REGISTER")
    {
        llOwnerSay("[REG] Unexpected command on register channel: " + cmd);
        return;
    }
    if (obj_type < REG_TYPE_TOWER || obj_type > REG_TYPE_PLACEMENT_HANDLER)
    {
        llOwnerSay("[REG] Unknown object type " + (string)obj_type + " from " + (string)sender);
        return;
    }

    if (obj_type == REG_TYPE_PLACEMENT_HANDLER)
    {
        if (!checkPlacementHandlerSlot(sender))
            return;
    }

    // Spawners no longer need a handler key at registration time —
    // pairing is negotiated separately via HANDLER_QUERY / SPAWNER_PAIRED

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
    string cmd = llList2String(parts, 0);
    if (cmd == "ACK" && llGetListLength(parts) >= 2)
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
        llOwnerSay("[GM] /td set: out of bounds (" + (string)x + "," + (string)y + ")");
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
        llOwnerSay("[GM] /td set: unknown type '" + type_str + "'");
        return;
    }

    setCell(x, y, new_type, new_occupied);
    string occ;
    if (new_occupied == CELL_OCCUPIED) occ = " [occupied]";
    else                               occ = " [empty]";
    llOwnerSay("[MAP] Set (" + (string)x + "," + (string)y + ") to " + type_str + occ);
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
        llOwnerSay("[GM] Objects: " + (string)registryCount()
            + " | Enemies: " + (string)enemyCount()
            + " | Pairings: " + (string)(llGetListLength(gSpawnerPairings) / PAIRING_STRIDE)
            + " | Lives: " + (string)gLives
            + " | Wave: " + (string)gWaveActive
            + " | HB seq: " + (string)gHeartbeatSeq
            + " | Mem: " + (string)llGetFreeMemory() + " bytes");
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

        llOwnerSay("[PL] --- PLACEMENT TEST SEQUENCE ---");

        llOwnerSay("[PL] Test 1: valid cell (" + (string)cx + "," + (string)cy + ")");
        handlePlacementRequest(llGetKey(),
            "PLACEMENT_REQUEST|" + (string)cx + "|" + (string)cy
            + "|" + (string)fake_avatar);

        llOwnerSay("[PL] Test 2: same cell (expect CELL_OCCUPIED)");
        handlePlacementRequest(llGetKey(),
            "PLACEMENT_REQUEST|" + (string)cx + "|" + (string)cy
            + "|" + (string)fake_avatar);

        llOwnerSay("[PL] Test 3: path cell 2,0 (expect NOT_BUILDABLE)");
        handlePlacementRequest(llGetKey(),
            "PLACEMENT_REQUEST|2|0|" + (string)fake_avatar);

        llOwnerSay("[PL] Test 4: blocked cell 0,0 (expect NOT_BUILDABLE)");
        handlePlacementRequest(llGetKey(),
            "PLACEMENT_REQUEST|0|0|" + (string)fake_avatar);

        setCellOccupied(cx, cy, CELL_EMPTY);
        llOwnerSay("[PL] Restored (" + (string)cx + "," + (string)cy + ") to empty.");
        llOwnerSay("[PL] --- END TEST SEQUENCE ---");
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
        llOwnerSay("[GM] Ready. Free memory: " + (string)llGetFreeMemory() + " bytes");
        llOwnerSay("[GM] Debug: /td dump map | /td dump registry | /td dump pairings | /td dump all | /td stats | /td wave start | /td test placement | /td set <x> <y> <build|path|blocked>");
    }

    listen(integer channel, string name, key id, string msg)
    {
        if (channel == GM_REGISTER_CHANNEL)
            handleRegisterMessage(id, msg);
        else if (channel == GM_DEREGISTER_CHANNEL)
            handleDeregisterMessage(id, msg);
        else if (channel == HEARTBEAT_CHANNEL)
            handleHeartbeatMessage(id, msg);
        else if (channel == PLACEMENT_CHANNEL)
            handlePlacementRequest(id, msg);
        else if (channel == GM_DISCOVERY_CHANNEL)
            handleDiscoveryMessage(id, msg);
        else if (channel == ENEMY_REPORT_CHANNEL)
            handleEnemyReport(id, msg);
        else if (channel == SPAWNER_CHANNEL)
            handleSpawnerReport(id, msg);
        else if (channel == GRID_INFO_CHANNEL)
            handleGridInfoRequest(id, msg);
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
