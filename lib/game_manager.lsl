// =============================================================================
// game_manager.lsl
// Tower Defense Game Manager — Phase 2
// Adds: placement request listener and coordinate verification logging
// =============================================================================
// PHASE 2 CHANGES:
//   - Added llListen on PLACEMENT_CHANNEL
//   - Added handlePlacementRequest() for coordinate verification logging
//   - Added /td test placement debug command
// =============================================================================


// -----------------------------------------------------------------------------
// CHANNEL CONSTANTS
// Copy these into every script that needs to communicate with the GM.
// All channels are negative to avoid interference with public chat.
// -----------------------------------------------------------------------------
integer GM_REGISTER_CHANNEL   = -2001;  // objects announce themselves here
integer GM_DEREGISTER_CHANNEL = -2002;  // objects say goodbye here
integer HEARTBEAT_CHANNEL     = -2003;  // GM pings out, objects ACK back
integer PLACEMENT_CHANNEL     = -2004;  // placement handler sends grid requests
integer TOWER_REPORT_CHANNEL  = -2005;  // towers report kills, state changes
integer ENEMY_REPORT_CHANNEL  = -2006;  // enemies report position, arrival, death


// -----------------------------------------------------------------------------
// MAP CONSTANTS
// -----------------------------------------------------------------------------
integer MAP_WIDTH  = 10;
integer MAP_HEIGHT = 10;

// Each cell in gMap occupies CELL_STRIDE consecutive list entries:
//   [0] cell type   (CELL_BLOCKED | CELL_BUILDABLE | CELL_PATH)
//   [1] occupied    (CELL_EMPTY   | CELL_OCCUPIED)
//   [2] reserved    (future use, e.g. tower key or modifier flags)
integer CELL_STRIDE = 3;

// Cell type values
integer CELL_BLOCKED   = 0;
integer CELL_BUILDABLE = 1;
integer CELL_PATH      = 2;

// Occupied flag values
integer CELL_EMPTY    = 0;
integer CELL_OCCUPIED = 1;


// -----------------------------------------------------------------------------
// REGISTRY CONSTANTS
// -----------------------------------------------------------------------------
// Each entry in gRegistry occupies REG_STRIDE consecutive list entries:
//   [0] object key        (string cast of key)
//   [1] object type       (REG_TYPE_*)
//   [2] grid x            (integer, position at registration time)
//   [3] grid y            (integer, position at registration time)
//   [4] last_seen         (integer unix timestamp from llGetUnixTime)
integer REG_STRIDE = 5;

integer REG_TYPE_TOWER   = 1;
integer REG_TYPE_ENEMY   = 2;
integer REG_TYPE_SPAWNER = 3;


// -----------------------------------------------------------------------------
// HEARTBEAT CONSTANTS
// -----------------------------------------------------------------------------
integer HEARTBEAT_INTERVAL = 10;  // seconds between heartbeat cycles
integer HEARTBEAT_TIMEOUT  = 3;   // missed cycles before an object is culled


// -----------------------------------------------------------------------------
// GLOBAL STATE
// -----------------------------------------------------------------------------
list gMap      = [];  // MAP_WIDTH * MAP_HEIGHT * CELL_STRIDE entries
list gRegistry = [];  // variable length, REG_STRIDE entries per object
integer gHeartbeatSeq = 0;  // increments each heartbeat cycle


// =============================================================================
// MAP HELPERS
// =============================================================================

// Returns the flat list index for the start of a cell's data block.
integer cellIndex(integer x, integer y)
{
    return (y * MAP_WIDTH + x) * CELL_STRIDE;
}

// Returns TRUE if (x, y) is within map bounds.
integer inBounds(integer x, integer y)
{
    return (x >= 0 && x < MAP_WIDTH && y >= 0 && y < MAP_HEIGHT);
}

// Returns the cell type at (x, y), or CELL_BLOCKED if out of bounds.
integer getCellType(integer x, integer y)
{
    if (!inBounds(x, y)) return CELL_BLOCKED;
    return llList2Integer(gMap, cellIndex(x, y));
}

// Returns the occupied flag at (x, y), or CELL_OCCUPIED if out of bounds.
integer getCellOccupied(integer x, integer y)
{
    if (!inBounds(x, y)) return CELL_OCCUPIED;
    return llList2Integer(gMap, cellIndex(x, y) + 1);
}

// Writes type and occupied flag to a cell. Reserved field is set to 0.
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

// Marks a cell as occupied (e.g. after a tower is placed).
setCellOccupied(integer x, integer y, integer flag)
{
    if (!inBounds(x, y)) return;
    integer idx = cellIndex(x, y) + 1;
    gMap = llListReplaceList(gMap, [flag], idx, idx);
}

// Returns TRUE if a tower can be placed at (x, y).
integer isPlaceable(integer x, integer y)
{
    return (getCellType(x, y) == CELL_BUILDABLE && getCellOccupied(x, y) == CELL_EMPTY);
}

// Initializes gMap to all BUILDABLE/EMPTY, then stamps path and blocked cells.
// Edit the path and blocked sections below to match your actual map layout.
initMap()
{
    gMap = [];
    integer total = MAP_WIDTH * MAP_HEIGHT;
    integer i;
    for (i = 0; i < total; i++)
    {
        gMap += [CELL_BUILDABLE, CELL_EMPTY, 0];
    }

    // ------------------------------------------------------------------
    // PATH DEFINITION
    // Define the enemy path as a sequence of cells. Edit this to match
    // your map. The path below traces a simple S-curve across a 10x10 grid:
    //   Enter from top of column 2, snake across, exit at bottom of column 7.
    // ------------------------------------------------------------------

    // Column 2, top to row 4 (entry corridor)
    setCell(2, 0, CELL_PATH, CELL_EMPTY);
    setCell(2, 1, CELL_PATH, CELL_EMPTY);
    setCell(2, 2, CELL_PATH, CELL_EMPTY);
    setCell(2, 3, CELL_PATH, CELL_EMPTY);
    setCell(2, 4, CELL_PATH, CELL_EMPTY);

    // Row 4, columns 2 to 7 (first horizontal)
    setCell(3, 4, CELL_PATH, CELL_EMPTY);
    setCell(4, 4, CELL_PATH, CELL_EMPTY);
    setCell(5, 4, CELL_PATH, CELL_EMPTY);
    setCell(6, 4, CELL_PATH, CELL_EMPTY);
    setCell(7, 4, CELL_PATH, CELL_EMPTY);

    // Column 7, rows 4 to 7 (right corridor)
    setCell(7, 5, CELL_PATH, CELL_EMPTY);
    setCell(7, 6, CELL_PATH, CELL_EMPTY);
    setCell(7, 7, CELL_PATH, CELL_EMPTY);

    // Row 7, columns 7 to 2 (second horizontal, reversed)
    setCell(6, 7, CELL_PATH, CELL_EMPTY);
    setCell(5, 7, CELL_PATH, CELL_EMPTY);
    setCell(4, 7, CELL_PATH, CELL_EMPTY);
    setCell(3, 7, CELL_PATH, CELL_EMPTY);
    setCell(2, 7, CELL_PATH, CELL_EMPTY);

    // Column 2, rows 7 to 9 (exit corridor)
    setCell(2, 8, CELL_PATH, CELL_EMPTY);
    setCell(2, 9, CELL_PATH, CELL_EMPTY);

    // ------------------------------------------------------------------
    // BLOCKED CELLS (obstacles, decorative elements, out-of-bounds areas)
    // ------------------------------------------------------------------
    setCell(0, 0, CELL_BLOCKED, CELL_EMPTY);
    setCell(1, 0, CELL_BLOCKED, CELL_EMPTY);
    setCell(9, 9, CELL_BLOCKED, CELL_EMPTY);
    setCell(8, 9, CELL_BLOCKED, CELL_EMPTY);

    llOwnerSay("[MAP] Initialized " + (string)MAP_WIDTH + "x" + (string)MAP_HEIGHT + " grid.");
}

// Debug utility: dumps the entire map to owner chat as a visual grid.
// B = buildable, P = path, X = blocked. Lowercase = occupied.
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

// Returns the flat list index for the start of an object's registry entry,
// or -1 if the key is not found.
integer findRegistryEntry(key id)
{
    return llListFindList(gRegistry, [(string)id]);
}

// Adds a new registry entry, or refreshes the timestamp if already registered.
registerObject(key id, integer obj_type, integer gx, integer gy)
{
    integer existing = findRegistryEntry(id);
    if (existing != -1)
    {
        // Already registered — update timestamp only.
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

// Removes an object from the registry by key.
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

    // Free map cell if this was a tower (phase 3 will own this fully,
    // but we keep it here so deregistration stays consistent)
    if (obj_type == REG_TYPE_TOWER)
        setCellOccupied(gx, gy, CELL_EMPTY);

    llOwnerSay("[REG] Deregistered: " + (string)id);
}

// Returns the number of currently registered objects.
integer registryCount()
{
    return llGetListLength(gRegistry) / REG_STRIDE;
}

// Debug utility: dumps the full registry to owner chat.
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
        if      (obj_type == REG_TYPE_TOWER)   type_label = "TOWER";
        else if (obj_type == REG_TYPE_ENEMY)   type_label = "ENEMY";
        else if (obj_type == REG_TYPE_SPAWNER) type_label = "SPAWNER";
        else                                   type_label = "UNKNOWN";

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

// Sends a PING to every registered object on HEARTBEAT_CHANNEL.
// Each object is expected to reply with "ACK|<seq>" on the same channel.
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

// Updates the last_seen timestamp for an object that has ACKed a heartbeat.
// Ignores ACKs with a sequence number that doesn't match the current cycle,
// since stale ACKs from a lagged object shouldn't reset its timeout clock.
receiveHeartbeatAck(key id, integer seq)
{
    if (seq != gHeartbeatSeq)
    {
        llOwnerSay("[HB] Stale ACK from " + (string)id
            + " (seq=" + (string)seq + " expected=" + (string)gHeartbeatSeq + ")");
        return;
    }
    integer idx = findRegistryEntry(id);
    if (idx == -1) return;  // ACK from an unregistered object, ignore
    gRegistry = llListReplaceList(gRegistry,
        [llGetUnixTime()],
        idx + 4, idx + 4);
}

// Walks the registry in reverse and removes objects whose last_seen timestamp
// is older than HEARTBEAT_INTERVAL * HEARTBEAT_TIMEOUT seconds.
// Reverse iteration ensures deletions don't shift indices of unvisited entries.
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
            integer obj_type = llList2Integer(gRegistry, idx + 1);
            integer gx       = llList2Integer(gRegistry, idx + 2);
            integer gy       = llList2Integer(gRegistry, idx + 3);
            string culled_key = llList2String(gRegistry, idx);

            llOwnerSay("[HB] Culling stale object: " + culled_key
                + " (last seen " + (string)(llGetUnixTime() - last_seen) + "s ago)");

            gRegistry = llDeleteSubList(gRegistry, idx, idx + REG_STRIDE - 1);

            if (obj_type == REG_TYPE_TOWER)
                setCellOccupied(gx, gy, CELL_EMPTY);

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
// PLACEMENT HANDLER  (new in phase 2)
// =============================================================================

// Handles PLACEMENT_REQUEST messages from the placement handler prim.
// Phase 2 scope: log coordinates and cross-reference against map data.
// Phase 3 will replace the body with full validation and response logic.
handlePlacementRequest(key sender, string msg)
{
    list parts = llParseString2List(msg, ["|"], []);
    if (llGetListLength(parts) < 4)
    {
        llOwnerSay("[PL] Malformed placement request: " + msg);
        return;
    }

    string cmd  = llList2String(parts, 0);
    integer gx  = (integer)llList2String(parts, 1);
    integer gy  = (integer)llList2String(parts, 2);
    key avatar  = (key)llList2String(parts, 3);

    if (cmd != "PLACEMENT_REQUEST")
    {
        llOwnerSay("[PL] Unexpected command on placement channel: " + cmd);
        return;
    }

    // Cross-reference grid coordinates against map data for verification
    integer cell_type = getCellType(gx, gy);
    string type_label;
    if      (cell_type == CELL_PATH)      type_label = "PATH";
    else if (cell_type == CELL_BLOCKED)   type_label = "BLOCKED";
    else if (cell_type == CELL_BUILDABLE) type_label = "BUILDABLE";
    else                                  type_label = "UNKNOWN";

    llOwnerSay("[PL] Request from " + llKey2Name(avatar)
        + " -> grid (" + (string)gx + "," + (string)gy + ")"
        + " cell=" + type_label);
}


// =============================================================================
// MESSAGE PARSING HELPERS
// =============================================================================

// Parses a registration message of the form:
//   "REGISTER|<type>|<grid_x>|<grid_y>"
// Calls registerObject if the message is well-formed.
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
    if (obj_type < REG_TYPE_TOWER || obj_type > REG_TYPE_SPAWNER)
    {
        llOwnerSay("[REG] Unknown object type " + (string)obj_type + " from " + (string)sender);
        return;
    }
    registerObject(sender, obj_type, gx, gy);
}

// Parses a deregistration message of the form:
//   "DEREGISTER"
handleDeregisterMessage(key sender, string msg)
{
    list parts = llParseString2List(msg, ["|"], []);
    string cmd = llList2String(parts, 0);
    if (cmd != "DEREGISTER")
    {
        llOwnerSay("[DEREG] Unexpected command on deregister channel: " + cmd);
        return;
    }
    deregisterObject(sender);
}

// Parses a heartbeat ACK message of the form:
//   "ACK|<seq>"
handleHeartbeatMessage(key sender, string msg)
{
    list parts = llParseString2List(msg, ["|"], []);
    string cmd = llList2String(parts, 0);
    if (cmd == "ACK" && llGetListLength(parts) >= 2)
    {
        integer seq = (integer)llList2String(parts, 1);
        receiveHeartbeatAck(sender, seq);
    }
}

// Handles debug commands sent by the owner via local chat on channel 0.
// Supported commands:
//   /td dump map      — print the map grid to owner chat
//   /td dump registry — print all registered objects
//   /td dump all      — print both
//   /td stats         — print summary counts
handleDebugCommand(string msg)
{
    if (msg == "/td dump map")
    {
        dumpMap();
    }
    else if (msg == "/td dump registry")
    {
        dumpRegistry();
    }
    else if (msg == "/td dump all")
    {
        dumpMap();
        dumpRegistry();
    }
    else if (msg == "/td stats")
    {
        llOwnerSay("[GM] Registered objects: " + (string)registryCount()
            + " | Heartbeat seq: " + (string)gHeartbeatSeq
            + " | Map: " + (string)MAP_WIDTH + "x" + (string)MAP_HEIGHT
            + " | Free memory: " + (string)llGetFreeMemory() + " bytes");
    }
    else if (msg == "/td test placement")
    {
        // Simulate a placement click at grid center for sanity checking
        // without needing to touch the overlay prim
        integer cx = MAP_WIDTH  / 2;
        integer cy = MAP_HEIGHT / 2;
        llOwnerSay("[PL] Simulating placement at grid center ("
            + (string)cx + "," + (string)cy + ")");
        handlePlacementRequest(llGetOwner(),
            "PLACEMENT_REQUEST|" + (string)cx + "|" + (string)cy
            + "|" + (string)llGetOwner());
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

        // Initialize the map grid
        initMap();

        // Open listeners
        llListen(GM_REGISTER_CHANNEL,   "", NULL_KEY, "");
        llListen(GM_DEREGISTER_CHANNEL, "", NULL_KEY, "");
        llListen(HEARTBEAT_CHANNEL,     "", NULL_KEY, "");

        // Listen on channel 0 for debug commands from owner only
        // (filtered by avatar check inside handleDebugCommand)
        llListen(PLACEMENT_CHANNEL,     "", NULL_KEY, "");  // new in phase 2
        llListen(0, "", llGetOwner(), "");

        // Start heartbeat timer
        llSetTimerEvent(HEARTBEAT_INTERVAL);

        llOwnerSay("[GM] Ready. Free memory: " + (string)llGetFreeMemory() + " bytes");
        llOwnerSay("[GM] Key: " + (string)llGetKey());
        llOwnerSay("[GM] Debug: /td dump map | /td dump registry | /td dump all | /td stats | /td test placement");
    }

    listen(integer channel, string name, key id, string msg)
    {
        if (channel == GM_REGISTER_CHANNEL)
        {
            handleRegisterMessage(id, msg);
        }
        else if (channel == GM_DEREGISTER_CHANNEL)
        {
            handleDeregisterMessage(id, msg);
        }
        else if (channel == HEARTBEAT_CHANNEL)
        {
            handleHeartbeatMessage(id, msg);
        }
        else if (channel == PLACEMENT_CHANNEL)
        {
            handlePlacementRequest(id, msg);
        }
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

    on_rez(integer start_param)
    {
        // Re-initialize cleanly if the GM prim is re-rezzed
        llResetScript();
    }
}
