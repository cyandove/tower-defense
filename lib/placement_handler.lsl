// =============================================================================
// placement_handler.lsl
// Tower Defense Placement Handler — Phase 4b
// Adds: GRID_INFO_CHANNEL listener, responds to grid info requests from GM
// =============================================================================
// PHASE 4b CHANGES:
//   - Added GRID_INFO_CHANNEL = -2011 listener
//   - Handles GRID_INFO_REQUEST forwarded by the GM from a spawner
//   - Responds directly to the requesting spawner with GRID_INFO message
//   - gGridOrigin and gCellSize already derived dynamically — no changes needed
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
// =============================================================================


// -----------------------------------------------------------------------------
// CHANNEL CONSTANTS — must match game_manager.lsl exactly.
// -----------------------------------------------------------------------------
integer GM_REGISTER_CHANNEL        = -2001;
integer GM_DEREGISTER_CHANNEL      = -2002;
integer HEARTBEAT_CHANNEL          = -2003;
integer PLACEMENT_CHANNEL          = -2004;
integer GM_DISCOVERY_CHANNEL       = -2007;
integer PLACEMENT_RESPONSE_CHANNEL = -2008;
integer GRID_INFO_CHANNEL          = -2011;


// -----------------------------------------------------------------------------
// GRID CONFIGURATION
// Only MAP_WIDTH, MAP_HEIGHT, and TOP_FACE need to be set manually.
// Cell size and grid origin are derived from the prim's scale and position.
// -----------------------------------------------------------------------------
integer MAP_WIDTH  = 10;
integer MAP_HEIGHT = 10;
integer TOP_FACE   = 1;

integer DISCOVERY_RETRY_INTERVAL   = 5;
integer REG_TYPE_PLACEMENT_HANDLER = 4;


// -----------------------------------------------------------------------------
// DERIVED GLOBALS
// -----------------------------------------------------------------------------
vector  gGridOrigin;
float   gCellSize;
key     gGM_KEY      = NULL_KEY;
integer gRegistered  = FALSE;
integer gDiscovering = FALSE;

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

discoverGM()
{
    gDiscovering = TRUE;
    llSay(GM_DISCOVERY_CHANNEL, "GM_DISCOVER");
    llOwnerSay("[PH] Broadcasting GM_DISCOVER...");
}

handleGMHere(key gm_key)
{
    gGM_KEY      = gm_key;
    gDiscovering = FALSE;
    llOwnerSay("[PH] Found GM: " + (string)gGM_KEY);
    llRegionSayTo(gGM_KEY, GM_REGISTER_CHANNEL,
        "REGISTER|" + (string)REG_TYPE_PLACEMENT_HANDLER + "|0|0");
}

handleRegisterResponse(string msg)
{
    list parts = llParseString2List(msg, ["|"], []);
    string cmd = llList2String(parts, 0);
    if (cmd == "REGISTER_OK")
    {
        gRegistered = TRUE;
        llSetTimerEvent(0);
        llOwnerSay("[PH] Registered with GM successfully.");
    }
    else if (cmd == "REGISTER_REJECTED")
    {
        gRegistered = FALSE;
        string reason = llList2String(parts, 1);
        llOwnerSay("[PH] Registration rejected: " + reason);
        llSetTimerEvent(0);
    }
}

handleHeartbeat(string msg)
{
    list parts = llParseString2List(msg, ["|"], []);
    if (llList2String(parts, 0) == "PING")
        llRegionSayTo(gGM_KEY, HEARTBEAT_CHANNEL, "ACK|" + llList2String(parts, 1));
}


// -----------------------------------------------------------------------------
// GRID INFO RESPONSE  (phase 4b)
// -----------------------------------------------------------------------------

// Handles a GRID_INFO_REQUEST forwarded by the GM on behalf of a spawner.
// The GM strips its own wrapper and sends us: GRID_INFO_REQUEST|<spawner_key>
// We respond directly to the spawner with our derived grid values.
//
// Response format: GRID_INFO|<origin_x>|<origin_y>|<origin_z>|<cell_size>
handleGridInfoRequest(key sender, string msg)
{
    // Only accept grid info requests forwarded from the GM
    if (sender != gGM_KEY)
    {
        llOwnerSay("[PH] Ignoring GRID_INFO_REQUEST from non-GM sender: "
            + (string)sender);
        return;
    }

    list parts = llParseString2List(msg, ["|"], []);
    if (llGetListLength(parts) < 2)
    {
        llOwnerSay("[PH] Malformed GRID_INFO_REQUEST: " + msg);
        return;
    }

    key spawner_key = (key)llList2String(parts, 1);

    string response = "GRID_INFO"
        + "|" + (string)gGridOrigin.x
        + "|" + (string)gGridOrigin.y
        + "|" + (string)gGridOrigin.z
        + "|" + (string)gCellSize;

    llRegionSayTo(spawner_key, GRID_INFO_CHANNEL, response);
    llOwnerSay("[PH] Sent grid info to spawner " + (string)spawner_key
        + " origin=" + (string)gGridOrigin + " cell_size=" + (string)gCellSize);
}


// -----------------------------------------------------------------------------
// GRID TRANSLATION
// -----------------------------------------------------------------------------

vector translateToGrid(vector touch_pos)
{
    float local_x = touch_pos.x - gGridOrigin.x;
    float local_y = touch_pos.y - gGridOrigin.y;

    integer grid_x = (integer)(local_x / gCellSize);
    integer grid_y = (integer)(local_y / gCellSize);

    if (grid_x < 0 || grid_x >= MAP_WIDTH ||
        grid_y < 0 || grid_y >= MAP_HEIGHT)
    {
        return <-1.0, -1.0, 0.0>;
    }

    return <(float)grid_x, (float)grid_y, 0.0>;
}

string gridStr(vector g)
{
    return "(" + (string)((integer)g.x) + "," + (string)((integer)g.y) + ")";
}


// -----------------------------------------------------------------------------
// GM COMMUNICATION
// -----------------------------------------------------------------------------

sendPlacementRequest(integer grid_x, integer grid_y, key avatar)
{
    if (!gRegistered)
    {
        llOwnerSay("[PH] Not yet registered — placement request dropped.");
        return;
    }

    string msg = "PLACEMENT_REQUEST"
        + "|" + (string)grid_x
        + "|" + (string)grid_y
        + "|" + (string)avatar;

    llRegionSayTo(gGM_KEY, PLACEMENT_CHANNEL, msg);
}


// -----------------------------------------------------------------------------
// PLACEMENT RESPONSE HANDLER
// -----------------------------------------------------------------------------

string reasonToMessage(string reason)
{
    if (reason == "NOT_BUILDABLE") return "You can't build there.";
    if (reason == "CELL_OCCUPIED") return "That spot is already occupied.";
    if (reason == "OUT_OF_BOUNDS") return "That location is outside the play area.";
    if (reason == "NOT_REGISTERED") return "Placement system error — handler not registered.";
    return "Placement denied (" + reason + ").";
}

handlePlacementResponse(string msg)
{
    list parts = llParseString2List(msg, ["|"], []);
    string cmd = llList2String(parts, 0);

    if (llGetListLength(parts) < 4)
    {
        llOwnerSay("[PH] Malformed placement response: " + msg);
        return;
    }

    integer gx = (integer)llList2String(parts, 1);
    integer gy = (integer)llList2String(parts, 2);
    key avatar = (key)llList2String(parts, 3);

    if (cmd == "PLACEMENT_OK")
    {
        llRegionSayTo(avatar, 0,
            "Tower placed at grid (" + (string)gx + "," + (string)gy + ").");
        llOwnerSay("[PH] PLACEMENT_OK -> " + llKey2Name(avatar)
            + " at (" + (string)gx + "," + (string)gy + ")");
    }
    else if (cmd == "PLACEMENT_DENIED")
    {
        string reason = llList2String(parts, 4);
        llRegionSayTo(avatar, 0, reasonToMessage(reason));
        llOwnerSay("[PH] PLACEMENT_DENIED (" + reason + ") -> "
            + llKey2Name(avatar)
            + " at (" + (string)gx + "," + (string)gy + ")");
    }
    else
    {
        llOwnerSay("[PH] Unknown placement response: " + cmd);
    }
}


// =============================================================================
// MAIN STATE
// =============================================================================

default
{
    state_entry()
    {
        initGridFromPrim();

        llListen(GM_DISCOVERY_CHANNEL,       "", NULL_KEY, "");
        llListen(GM_REGISTER_CHANNEL,        "", NULL_KEY, "");
        llListen(HEARTBEAT_CHANNEL,          "", NULL_KEY, "");
        llListen(PLACEMENT_RESPONSE_CHANNEL, "", NULL_KEY, "");
        llListen(GRID_INFO_CHANNEL,          "", NULL_KEY, "");

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
        else if (channel == PLACEMENT_RESPONSE_CHANNEL && id == gGM_KEY)
        {
            handlePlacementResponse(msg);
        }
        else if (channel == GRID_INFO_CHANNEL)
        {
            list parts = llParseString2List(msg, ["|"], []);
            if (llList2String(parts, 0) == "GRID_INFO_REQUEST")
                handleGridInfoRequest(id, msg);
        }
    }

    touch_start(integer num_detected)
    {
        integer face = llDetectedTouchFace(0);
        if (face != TOP_FACE)
        {
            llOwnerSay("[PH] Touch on face " + (string)face + " ignored (expected "
                + (string)TOP_FACE + ")");
            return;
        }

        key avatar       = llDetectedKey(0);
        vector touch_pos = llDetectedTouchPos(0);
        vector grid      = translateToGrid(touch_pos);

        if ((integer)grid.x == -1)
        {
            llOwnerSay("[PH] Touch out of bounds at " + (string)touch_pos);
            return;
        }

        integer grid_x = (integer)grid.x;
        integer grid_y = (integer)grid.y;

        llOwnerSay("[PH] Touch by " + llKey2Name(avatar)
            + " at " + (string)touch_pos
            + " -> grid " + gridStr(grid));

        sendPlacementRequest(grid_x, grid_y, avatar);
    }

    timer()
    {
        if (!gRegistered && gDiscovering)
            discoverGM();
        else if (gGM_KEY != NULL_KEY && !gRegistered)
            handleGMHere(gGM_KEY);
    }

    on_rez(integer start_param)
    {
        llResetScript();
    }
}
