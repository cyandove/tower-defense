// =============================================================================
// game_manager.lsl
// Tower Defense Game Manager — Phase 3
// Adds: map validation, placement approval/denial, /td set debug command
// =============================================================================
// PHASE 3 CHANGES:
//   - Added PLACEMENT_RESPONSE_CHANNEL = -2008
//   - handlePlacementRequest now fully validates bounds, cell type, occupancy
//   - Approved placements mark cell occupied and send PLACEMENT_OK
//   - Denied placements send PLACEMENT_DENIED with a reason string
//   - Added /td set <x> <y> <type> debug command for live map editing
//   - Updated /td test placement to exercise all validation paths
// =============================================================================


// -----------------------------------------------------------------------------
// CHANNEL CONSTANTS
// Copy these into every script that needs to communicate with the GM.
// -----------------------------------------------------------------------------
integer GM_REGISTER_CHANNEL      = -2001;
integer GM_DEREGISTER_CHANNEL    = -2002;
integer HEARTBEAT_CHANNEL        = -2003;
integer PLACEMENT_CHANNEL        = -2004;
integer TOWER_REPORT_CHANNEL     = -2005;
integer ENEMY_REPORT_CHANNEL     = -2006;
integer GM_DISCOVERY_CHANNEL     = -2007;
integer PLACEMENT_RESPONSE_CHANNEL = -2008;


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

integer REG_TYPE_TOWER             = 1;
integer REG_TYPE_ENEMY             = 2;
integer REG_TYPE_SPAWNER           = 3;
integer REG_TYPE_PLACEMENT_HANDLER = 4;


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
            integer obj_type  = llList2Integer(gRegistry, idx + 1);
            integer gx        = llList2Integer(gRegistry, idx + 2);
            integer gy        = llList2Integer(gRegistry, idx + 3);
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
// DISCOVERY
// =============================================================================

// Responds to GM_DISCOVER broadcasts so objects can find the GM's key
// without it being hardcoded.
handleDiscoveryMessage(key sender, string msg)
{
    if (msg != "GM_DISCOVER") return;
    llRegionSayTo(sender, GM_DISCOVERY_CHANNEL, "GM_HERE|" + (string)llGetKey());
    llOwnerSay("[GM] Discovery response sent to " + (string)sender);
}


// =============================================================================
// PLACEMENT VALIDATION  (phase 3)
// =============================================================================

// Sends a placement approval to the placement handler and marks the cell
// occupied. The avatar key is passed through so the placement handler can
// relay the result directly to the player.
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

// Sends a placement denial to the placement handler with a reason string.
// Reason values: OUT_OF_BOUNDS | NOT_BUILDABLE | CELL_OCCUPIED
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

// Full validation pipeline for a placement request.
// 1. Verify sender is a registered placement handler.
// 2. Parse and validate message format.
// 3. Check bounds.
// 4. Check cell type.
// 5. Check occupancy.
// 6. Approve or deny with appropriate reason.
handlePlacementRequest(key sender, string msg)
{
    // Step 1: verify sender is a registered placement handler
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

    // Step 2: parse message
    list parts = llParseString2List(msg, ["|"], []);
    if (llGetListLength(parts) < 4)
    {
        llOwnerSay("[PL] Malformed placement request: " + msg);
        return;
    }
    string cmd = llList2String(parts, 0);
    integer gx = (integer)llList2String(parts, 1);
    integer gy = (integer)llList2String(parts, 2);
    key avatar = (key)llList2String(parts, 3);

    if (cmd != "PLACEMENT_REQUEST")
    {
        llOwnerSay("[PL] Unexpected command on placement channel: " + cmd);
        return;
    }

    // Step 3: bounds check (defensive — placement handler checks this too)
    if (!inBounds(gx, gy))
    {
        denyPlacement(sender, gx, gy, avatar, "OUT_OF_BOUNDS");
        return;
    }

    // Step 4: cell type check
    integer cell_type = getCellType(gx, gy);
    if (cell_type != CELL_BUILDABLE)
    {
        denyPlacement(sender, gx, gy, avatar, "NOT_BUILDABLE");
        return;
    }

    // Step 5: occupancy check
    if (getCellOccupied(gx, gy) == CELL_OCCUPIED)
    {
        denyPlacement(sender, gx, gy, avatar, "CELL_OCCUPIED");
        return;
    }

    // All checks passed
    approvePlacement(sender, gx, gy, avatar);
}


// =============================================================================
// REGISTRATION HELPERS
// =============================================================================

// Parses a registration message of the form:
//   "REGISTER|<type>|<grid_x>|<grid_y>"
// Calls registerObject if the message is well-formed.
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

    registerObject(sender, obj_type, gx, gy);
    llRegionSayTo(sender, GM_REGISTER_CHANNEL, "REGISTER_OK|" + (string)obj_type);
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


// =============================================================================
// DEBUG COMMANDS
// =============================================================================

// Parses and executes /td set <x> <y> <type> commands.
// Type tokens: build | path | blocked
// Preserves existing occupancy when changing cell type, except when changing
// to PATH or BLOCKED which always clears occupancy since towers can't
// exist on those cell types.
handleSetCommand(string msg)
{
    list parts = llParseString2List(msg, [" "], []);
    if (llGetListLength(parts) < 5)
    {
        llOwnerSay("[GM] Usage: /td set <x> <y> <build|path|blocked>");
        return;
    }
    integer x         = (integer)llList2String(parts, 2);
    integer y         = (integer)llList2String(parts, 3);
    string  type_str  = llToLower(llList2String(parts, 4));

    if (!inBounds(x, y))
    {
        llOwnerSay("[GM] /td set: coordinates out of bounds (" + (string)x + "," + (string)y + ")");
        return;
    }

    integer new_type;
    integer new_occupied;
    if (type_str == "build")
    {
        new_type     = CELL_BUILDABLE;
        new_occupied = getCellOccupied(x, y);  // preserve existing occupancy
    }
    else if (type_str == "path")
    {
        new_type     = CELL_PATH;
        new_occupied = CELL_EMPTY;  // towers can't exist on path cells
    }
    else if (type_str == "blocked")
    {
        new_type     = CELL_BLOCKED;
        new_occupied = CELL_EMPTY;  // towers can't exist on blocked cells
    }
    else
    {
        llOwnerSay("[GM] /td set: unknown type '" + type_str + "' (use: build | path | blocked)");
        return;
    }

    setCell(x, y, new_type, new_occupied);
    string occupied_label;
    if (new_occupied == CELL_OCCUPIED)
        occupied_label = " [occupied]";
    else
        occupied_label = " [empty]";
    llOwnerSay("[MAP] Set (" + (string)x + "," + (string)y + ") to " + type_str + occupied_label);
}

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
    else if (llGetSubString(msg, 0, 7) == "/td set ")
    {
        handleSetCommand(msg);
    }
    else if (msg == "/td test placement")
    {
        // Test all three rejection paths plus one approval in sequence.
        // Uses the owner key as a fake avatar and the GM's own key as a
        // fake placement handler — the sender check is bypassed in this path.
        integer cx = MAP_WIDTH  / 2;
        integer cy = MAP_HEIGHT / 2;
        key fake_avatar = llGetOwner();

        llOwnerSay("[PL] --- PLACEMENT TEST SEQUENCE ---");

        // Should approve (buildable, empty)
        llOwnerSay("[PL] Test 1: valid cell (" + (string)cx + "," + (string)cy + ")");
        handlePlacementRequest(llGetKey(),
            "PLACEMENT_REQUEST|" + (string)cx + "|" + (string)cy
            + "|" + (string)fake_avatar);

        // Should deny CELL_OCCUPIED (same cell, now occupied from test 1)
        llOwnerSay("[PL] Test 2: same cell again (expect CELL_OCCUPIED)");
        handlePlacementRequest(llGetKey(),
            "PLACEMENT_REQUEST|" + (string)cx + "|" + (string)cy
            + "|" + (string)fake_avatar);

        // Should deny NOT_BUILDABLE (path cell)
        llOwnerSay("[PL] Test 3: path cell (2,0) (expect NOT_BUILDABLE)");
        handlePlacementRequest(llGetKey(),
            "PLACEMENT_REQUEST|2|0|" + (string)fake_avatar);

        // Should deny NOT_BUILDABLE (blocked cell)
        llOwnerSay("[PL] Test 4: blocked cell (0,0) (expect NOT_BUILDABLE)");
        handlePlacementRequest(llGetKey(),
            "PLACEMENT_REQUEST|0|0|" + (string)fake_avatar);

        // Clean up test occupation so map isn't left dirty
        setCellOccupied(cx, cy, CELL_EMPTY);
        llOwnerSay("[PL] Test cell (" + (string)cx + "," + (string)cy
            + ") restored to empty.");
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
        llListen(0, "", llGetOwner(), "");

        llSetTimerEvent(HEARTBEAT_INTERVAL);

        llOwnerSay("[GM] Key: " + (string)llGetKey());
        llOwnerSay("[GM] Ready. Free memory: " + (string)llGetFreeMemory() + " bytes");
        llOwnerSay("[GM] Debug: /td dump map | /td dump registry | /td dump all | /td stats | /td test placement | /td set <x> <y> <build|path|blocked>");
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
        else if (channel == GM_DISCOVERY_CHANNEL)
        {
            handleDiscoveryMessage(id, msg);
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
