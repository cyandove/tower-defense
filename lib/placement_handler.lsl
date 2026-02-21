// =============================================================================
// placement_handler.lsl
// Tower Defense Placement Handler — Phase 2b
// Adds: GM discovery flow, registration with enforcement
// =============================================================================
// PHASE 2b CHANGES:
//   - Broadcasts GM_DISCOVER on startup to find GM key automatically
//   - Retries discovery every DISCOVERY_RETRY_INTERVAL seconds until found
//   - Registers as REG_TYPE_PLACEMENT_HANDLER after GM key is confirmed
//   - Handles REGISTER_OK and REGISTER_REJECTED responses
//   - Blocks placement requests until registered successfully
//   - Responds to heartbeat PINGs from the GM
// =============================================================================
//
// SETUP INSTRUCTIONS:
//   1. Create a flat box prim sized to cover your entire grid in meters.
//      Example: if MAP_WIDTH=10 and MAP_HEIGHT=10, make the prim 20x20m for
//      2m cells, or 10x10m for 1m cells. The script derives cell size from
//      the prim's scale automatically — just keep the prim square.
//   2. Center the prim over your playfield. Grid origin and cell size are
//      calculated from the prim's position and scale at startup — no manual
//      coordinate entry needed. Move the prim and reset the script to update.
//   3. Set the prim transparent (alpha=0) but leave it phantom OFF so
//      clicks register. Alternatively set alpha to ~5% during testing.
//   4. Edit MAP_WIDTH, MAP_HEIGHT, and TOP_FACE below if needed.
//   5. The prim must be axis-aligned (no rotation) for the default math.
//      If you need rotation support, see the note in translateToGrid().
// =============================================================================


// -----------------------------------------------------------------------------
// CHANNEL CONSTANTS
// Must match game_manager.lsl exactly.
// -----------------------------------------------------------------------------
integer GM_REGISTER_CHANNEL   = -2001;
integer GM_DEREGISTER_CHANNEL = -2002;
integer HEARTBEAT_CHANNEL     = -2003;
integer PLACEMENT_CHANNEL     = -2004;
integer GM_DISCOVERY_CHANNEL  = -2007;


// -----------------------------------------------------------------------------
// GRID CONFIGURATION
// Only MAP_WIDTH, MAP_HEIGHT, and TOP_FACE need to be set manually.
// Cell size and grid origin are derived from the prim's scale and position.
// -----------------------------------------------------------------------------

// Number of grid columns and rows. Must match game_manager.lsl.
integer MAP_WIDTH  = 10;
integer MAP_HEIGHT = 10;

// The face index of the top face on the overlay prim.
// On a default unmodified cube this is face 1. Verify in-world by touching
// each face with a test script that prints llDetectedTouchFace(0).
integer TOP_FACE = 1;

// How often to retry GM discovery if no response is received, in seconds.
integer DISCOVERY_RETRY_INTERVAL = 5;

integer REG_TYPE_PLACEMENT_HANDLER = 4;


// -----------------------------------------------------------------------------
// DERIVED GLOBALS — calculated at startup from prim scale and position.
// Do not edit these directly.
// -----------------------------------------------------------------------------
vector  gGridOrigin;           // region-space XY of the grid's (0,0) corner
float   gCellSize;             // meters per cell, derived from prim scale / MAP_WIDTH
key     gGM_KEY     = NULL_KEY;  // set automatically via discovery
integer gRegistered = FALSE;   // TRUE once GM has acknowledged registration
integer gDiscovering = FALSE;  // TRUE while waiting for GM_HERE response

// Calculates gGridOrigin and gCellSize from the prim's current position and
// scale. Call this in state_entry() and whenever the prim is moved or resized.
// Assumes the prim is square — if it isn't, X and Y cell sizes will differ
// and you should store them separately.
initGridFromPrim()
{
    vector pos  = llGetPos();
    vector size = llGetScale();
    gGridOrigin = <pos.x - size.x * 0.5,
                   pos.y - size.y * 0.5,
                   pos.z>;
    gCellSize = size.x / MAP_WIDTH;
}


// -----------------------------------------------------------------------------
// GM DISCOVERY AND REGISTRATION
// -----------------------------------------------------------------------------

// Broadcasts a discovery request. The GM will respond with GM_HERE|<key>.
discoverGM()
{
    gDiscovering = TRUE;
    llSay(GM_DISCOVERY_CHANNEL, "GM_DISCOVER");
    llOwnerSay("[PH] Broadcasting GM_DISCOVER...");
}

// Called when GM_HERE is received. Stores the GM key and sends registration.
handleGMHere(key gm_key)
{
    gGM_KEY      = gm_key;
    gDiscovering = FALSE;
    llOwnerSay("[PH] Found GM: " + (string)gGM_KEY);

    // Register as a placement handler. Grid position 0,0 is a placeholder
    // since placement handlers aren't tied to a specific cell.
    llRegionSayTo(gGM_KEY, GM_REGISTER_CHANNEL,
        "REGISTER|" + (string)REG_TYPE_PLACEMENT_HANDLER + "|0|0");
}

// Called when the GM responds to our registration attempt.
handleRegisterResponse(string msg)
{
    list parts = llParseString2List(msg, ["|"], []);
    string cmd = llList2String(parts, 0);
    if (cmd == "REGISTER_OK")
    {
        gRegistered = TRUE;
        llSetTimerEvent(0);  // stop retry timer
        llOwnerSay("[PH] Registered with GM successfully.");
    }
    else if (cmd == "REGISTER_REJECTED")
    {
        gRegistered = FALSE;
        string reason = llList2String(parts, 1);
        llOwnerSay("[PH] Registration rejected by GM: " + reason);
        // Don't retry — a duplicate handler is a configuration error,
        // not a timing issue. Operator intervention required.
        llSetTimerEvent(0);
    }
}

// Responds to heartbeat PINGs from the GM.
handleHeartbeat(string msg)
{
    list parts = llParseString2List(msg, ["|"], []);
    if (llList2String(parts, 0) == "PING")
    {
        string seq = llList2String(parts, 1);
        llRegionSayTo(gGM_KEY, HEARTBEAT_CHANNEL, "ACK|" + seq);
    }
}


// -----------------------------------------------------------------------------
// GRID TRANSLATION
// -----------------------------------------------------------------------------

// Translates a region-space touch position into integer grid coordinates.
// Returns a vector where .x = grid_x, .y = grid_y, .z = 0.
// Returns <-1, -1, 0> if the touch is outside the valid grid area.
//
// NOTE ON ROTATION: This function assumes the prim (and therefore the grid)
// is axis-aligned with the region. If your playfield is rotated, you need to
// counter-rotate local_pos by the prim's inverse rotation before the floor()
// math. That would look like:
//   vector local_pos = (touch_pos - gGridOrigin) / llGetRot();
// For now, keep your build axis-aligned to avoid this complexity.
vector translateToGrid(vector touch_pos)
{
    // Get position relative to grid origin
    float local_x = touch_pos.x - gGridOrigin.x;
    float local_y = touch_pos.y - gGridOrigin.y;

    // Convert to grid coordinates by dividing by cell size and flooring
    integer grid_x = (integer)(local_x / gCellSize);
    integer grid_y = (integer)(local_y / gCellSize);

    // Validate bounds
    if (grid_x < 0 || grid_x >= MAP_WIDTH ||
        grid_y < 0 || grid_y >= MAP_HEIGHT)
    {
        return <-1.0, -1.0, 0.0>;  // out of bounds sentinel
    }

    return <(float)grid_x, (float)grid_y, 0.0>;
}

// Returns a human-readable string for a grid coordinate vector.
string gridStr(vector g)
{
    return "(" + (string)((integer)g.x) + "," + (string)((integer)g.y) + ")";
}


// -----------------------------------------------------------------------------
// GM COMMUNICATION
// -----------------------------------------------------------------------------

// Sends a placement request to the Game Manager.
// Format: PLACEMENT_REQUEST|<grid_x>|<grid_y>|<avatar_key>
sendPlacementRequest(integer grid_x, integer grid_y, key avatar)
{
    if (!gRegistered)
    {
        llOwnerSay("[PH] Not yet registered with GM — placement request dropped.");
        return;
    }

    string msg = "PLACEMENT_REQUEST"
        + "|" + (string)grid_x
        + "|" + (string)grid_y
        + "|" + (string)avatar;

    llRegionSayTo(gGM_KEY, PLACEMENT_CHANNEL, msg);
}


// =============================================================================
// MAIN STATE
// =============================================================================

default
{
    state_entry()
    {
        initGridFromPrim();

        llListen(GM_DISCOVERY_CHANNEL, "", NULL_KEY, "");
        llListen(GM_REGISTER_CHANNEL,  "", NULL_KEY, "");
        llListen(HEARTBEAT_CHANNEL,    "", NULL_KEY, "");

        llOwnerSay("[PH] Placement handler ready.");
        llOwnerSay("[PH] Prim position: " + (string)llGetPos());
        llOwnerSay("[PH] Prim scale:    " + (string)llGetScale());
        llOwnerSay("[PH] Grid origin:   " + (string)gGridOrigin);
        llOwnerSay("[PH] Cell size:     " + (string)gCellSize + "m");
        llOwnerSay("[PH] Grid:          " + (string)MAP_WIDTH + "x" + (string)MAP_HEIGHT
            + " (" + (string)((integer)(gCellSize * MAP_WIDTH)) + "x"
            + (string)((integer)(gCellSize * MAP_HEIGHT)) + "m total)");

        discoverGM();
        llSetTimerEvent(DISCOVERY_RETRY_INTERVAL);
    }

    listen(integer channel, string name, key id, string msg)
    {
        if (channel == GM_DISCOVERY_CHANNEL)
        {
            list parts = llParseString2List(msg, ["|"], []);
            if (llList2String(parts, 0) == "GM_HERE" && gGM_KEY == NULL_KEY)
                handleGMHere((key)llList2String(parts, 1));
        }
        else if (channel == GM_REGISTER_CHANNEL && id == gGM_KEY)
        {
            handleRegisterResponse(msg);
        }
        else if (channel == HEARTBEAT_CHANNEL && id == gGM_KEY)
        {
            handleHeartbeat(msg);
        }
    }

    touch_start(integer num_detected)
    {
        // Only process touches on the top face
        integer face = llDetectedTouchFace(0);
        if (face != TOP_FACE)
        {
            llOwnerSay("[PH] Touch on face " + (string)face + " ignored (expected face "
                + (string)TOP_FACE + ")");
            return;
        }

        key avatar       = llDetectedKey(0);
        vector touch_pos = llDetectedTouchPos(0);
        vector grid      = translateToGrid(touch_pos);

        // Out of bounds check
        if ((integer)grid.x == -1)
        {
            llOwnerSay("[PH] Touch out of grid bounds at region pos "
                + (string)touch_pos);
            return;
        }

        integer grid_x = (integer)grid.x;
        integer grid_y = (integer)grid.y;

        llOwnerSay("[PH] Touch by " + llKey2Name(avatar)
            + " at region " + (string)touch_pos
            + " -> grid " + gridStr(grid));

        sendPlacementRequest(grid_x, grid_y, avatar);
    }

    timer()
    {
        // Still discovering — retry broadcast
        if (!gRegistered && gDiscovering)
            discoverGM();
        // GM found but registration not yet acknowledged — resend
        else if (gGM_KEY != NULL_KEY && !gRegistered)
            handleGMHere(gGM_KEY);
    }

    on_rez(integer start_param)
    {
        llResetScript();
    }
}
