// =============================================================================
// placement_handler.lsl
// Tower Defense Placement Handler  -  Phase 7
// =============================================================================
// PHASE 7 CHANGES:
//   - Controller rezzes this prim at the correct world position and scale,
//     so initGridFromPrim() derives correct geometry without any manual setup.
//   - Added CONTROLLER_CHANNEL (-2013) to listen list.
//   - Added SHUTDOWN handler: deregisters from GM and calls llDie().
//   - GM_DISCOVERY broadcast still used for finding GM key after rez.
//   - Registration message format unchanged: REGISTER|4|0|0|ox|oy|oz|cellsize
//     (GM still uses the grid geometry for tower rezzing).
//   - Everything else unchanged from Phase 6.
//
// The placement handler does NOT interact with the controller during normal
// operation  -  it is a pure UI layer. The controller only sends SHUTDOWN to it.
// =============================================================================


// -----------------------------------------------------------------------------
// DEBUG
// -----------------------------------------------------------------------------
integer DEBUG         = FALSE;   // compile-time default
integer gDebug        = FALSE;   // runtime toggle
integer DBG_CHANNEL = -2099;   // owner-only debug toggle broadcast


// -----------------------------------------------------------------------------
// CHANNEL CONSTANTS
// -----------------------------------------------------------------------------
integer GM_REGISTER_CHANNEL        = -2001;
integer GM_DEREGISTER_CHANNEL      = -2002;
integer HEARTBEAT_CHANNEL          = -2003;
integer PLACEMENT_CHANNEL          = -2004;
integer GM_DISCOVERY_CHANNEL       = -2007;
integer PLACEMENT_RESPONSE_CHANNEL = -2008;
integer TOWER_PLACE_CHANNEL        = -2012;
integer CONTROLLER_CHANNEL         = -2013;


// -----------------------------------------------------------------------------
// GRID CONFIGURATION
// -----------------------------------------------------------------------------
integer MAP_WIDTH  = 10;
integer MAP_HEIGHT = 10;
integer TOP_FACE   = 0;
integer DISCOVERY_RETRY_INTERVAL = 5;
integer DIALOG_TIMEOUT = 30;

integer gDialogChannel;


// -----------------------------------------------------------------------------
// PENDING DIALOG TABLE  stride=5: [avatar_key, gx, gy, listen_handle, timestamp]
// -----------------------------------------------------------------------------
integer DIALOG_STRIDE = 5;
list    gPendingDialogs = [];


// -----------------------------------------------------------------------------
// STATE
// -----------------------------------------------------------------------------
vector  gGridOrigin;
float   gCellSize;
key     gGM_KEY      = NULL_KEY;
integer gRegistered  = FALSE;
integer gDiscovering = FALSE;

// Tower labels — received from GM via TOWER_LABELS message. Index+1 = type_id.
list gTowerLabels = [];


// =============================================================================
// DEBUG HELPER
// =============================================================================

dbg(string msg)
{
    if (gDebug) llOwnerSay(msg);
}


// =============================================================================
// GRID INITIALISATION
// =============================================================================

initGridFromPrim()
{
    vector pos  = llGetPos();
    vector size = llGetScale();
    gGridOrigin = <pos.x - size.x * 0.5,
                   pos.y - size.y * 0.5,
                   pos.z>;
    gCellSize = size.x / MAP_WIDTH;
}


// =============================================================================
// GM DISCOVERY AND REGISTRATION
// =============================================================================

discoverGM()
{
    gDiscovering = TRUE;
    llSay(GM_DISCOVERY_CHANNEL, "GM_DISCOVER");
    dbg("[PH] Broadcasting GM_DISCOVER...");
}

handleGMHere(key gm_key)
{
    gGM_KEY      = gm_key;
    gDiscovering = FALSE;
    dbg("[PH] Found GM: " + (string)gGM_KEY);
    llRegionSayTo(gGM_KEY, GM_REGISTER_CHANNEL,
        "REGISTER|4|0|0"
        + "|" + (string)gGridOrigin.x
        + "|" + (string)gGridOrigin.y
        + "|" + (string)gGridOrigin.z
        + "|" + (string)gCellSize);
}

handleRegisterResponse(string msg)
{
    list parts = llParseString2List(msg, ["|"], []);
    string cmd = llList2String(parts, 0);
    if (cmd == "REGISTER_OK")
    {
        gRegistered = TRUE;
        llSetTimerEvent(0);
        dbg("[PH] Registered with GM.");
    }
    else if (cmd == "REGISTER_REJECTED")
    {
        gRegistered = FALSE;
        llOwnerSay("[PH] Registration rejected: " + llList2String(parts, 1));
        llSetTimerEvent(0);
    }
}

handleHeartbeat(string msg)
{
    list parts = llParseString2List(msg, ["|"], []);
    if (llList2String(parts, 0) == "PING")
        llRegionSayTo(gGM_KEY, HEARTBEAT_CHANNEL,
            "ACK|" + llList2String(parts, 1));
}


// =============================================================================
// GRID TRANSLATION
// =============================================================================

vector translateToGrid(vector touch_pos)
{
    float local_x = touch_pos.x - gGridOrigin.x;
    float local_y = touch_pos.y - gGridOrigin.y;
    integer grid_x = (integer)(local_x / gCellSize);
    integer grid_y = (integer)(local_y / gCellSize);
    if (grid_x < 0 || grid_x >= MAP_WIDTH ||
        grid_y < 0 || grid_y >= MAP_HEIGHT)
        return <-1.0, -1.0, 0.0>;
    return <(float)grid_x, (float)grid_y, 0.0>;
}


// =============================================================================
// PENDING DIALOG TABLE
// =============================================================================

integer findPendingDialog(key avatar)
{
    return llListFindList(gPendingDialogs, [(string)avatar]);
}

addPendingDialog(key avatar, integer gx, integer gy, integer listen_handle)
{
    removePendingDialog(avatar);
    gPendingDialogs += [(string)avatar, gx, gy, listen_handle, llGetUnixTime()];
}

removePendingDialog(key avatar)
{
    integer idx = findPendingDialog(avatar);
    if (idx == -1) return;
    llListenRemove(llList2Integer(gPendingDialogs, idx + 3));
    gPendingDialogs = llDeleteSubList(gPendingDialogs,
        idx, idx + DIALOG_STRIDE - 1);
}

cullStaleDialogs()
{
    integer threshold = llGetUnixTime() - DIALOG_TIMEOUT;
    integer count = llGetListLength(gPendingDialogs) / DIALOG_STRIDE;
    integer i = count - 1;
    for (; i >= 0; i--)
    {
        integer idx = i * DIALOG_STRIDE;
        if (llList2Integer(gPendingDialogs, idx + 4) < threshold)
        {
            llListenRemove(llList2Integer(gPendingDialogs, idx + 3));
            gPendingDialogs = llDeleteSubList(gPendingDialogs,
                idx, idx + DIALOG_STRIDE - 1);
        }
    }
}


// =============================================================================
// TOWER TYPE DIALOG
// =============================================================================

integer labelToTypeId(string label)
{
    integer idx = llListFindList(gTowerLabels, [label]);
    if (idx == -1) return -1;
    return idx + 1;
}

showTowerDialog(key avatar, integer gx, integer gy)
{
    if (gTowerLabels == [])
    {
        llRegionSayTo(avatar, 0, "Tower types not loaded yet.");
        return;
    }
    string prompt = "Select tower for grid ("
        + (string)gx + "," + (string)gy + ").\n"
        + "Expires in " + (string)DIALOG_TIMEOUT + "s.";
    integer handle = llListen(gDialogChannel, "", avatar, "");
    llDialog(avatar, prompt, gTowerLabels, gDialogChannel);
    addPendingDialog(avatar, gx, gy, handle);
    dbg("[PH] Dialog -> " + llKey2Name(avatar)
        + " (" + (string)gx + "," + (string)gy + ")");
}

handleDialogResponse(key avatar, string response)
{
    integer idx = findPendingDialog(avatar);
    if (idx == -1) return;

    integer gx      = llList2Integer(gPendingDialogs, idx + 1);
    integer gy      = llList2Integer(gPendingDialogs, idx + 2);
    integer type_id = labelToTypeId(response);

    if (type_id == -1)
    {
        llOwnerSay("[PH] Unknown label '" + response + "'  -  ignoring.");
        removePendingDialog(avatar);
        return;
    }

    removePendingDialog(avatar);
    dbg("[PH] " + llKey2Name(avatar) + " chose type " + (string)type_id
        + " (" + response + ") for (" + (string)gx + "," + (string)gy + ")");

    llRegionSayTo(gGM_KEY, TOWER_PLACE_CHANNEL,
        "TOWER_PLACE_REQUEST"
        + "|" + (string)gx
        + "|" + (string)gy
        + "|" + (string)avatar
        + "|" + (string)type_id);
}


// =============================================================================
// PLACEMENT RESPONSE
// =============================================================================

handlePlacementResponse(string msg)
{
    list parts = llParseString2List(msg, ["|"], []);
    string cmd = llList2String(parts, 0);
    if (llGetListLength(parts) < 4) return;

    integer gx = (integer)llList2String(parts, 1);
    integer gy = (integer)llList2String(parts, 2);
    key avatar = (key)llList2String(parts, 3);

    if (cmd == "PLACEMENT_RESERVED")
    {
        showTowerDialog(avatar, gx, gy);
    }
    else if (cmd == "PLACEMENT_DENIED")
    {
        string reason = llList2String(parts, 4);
        string human;
        if      (reason == "NOT_BUILDABLE")  human = "You can't build there.";
        else if (reason == "CELL_OCCUPIED")  human = "That spot is already taken.";
        else if (reason == "OUT_OF_BOUNDS")  human = "That's outside the play area.";
        else if (reason == "NOT_REGISTERED") human = "Placement system error.";
        else                                 human = "Placement denied (" + reason + ").";
        llRegionSayTo(avatar, 0, human);
    }
}


// =============================================================================
// MAIN STATE
// =============================================================================

default
{
    state_entry()
    {
        gDebug = DEBUG;
        initGridFromPrim();
        gDialogChannel = -(integer)("0x"
            + llGetSubString((string)llGetKey(), 0, 6));

        llListen(GM_DISCOVERY_CHANNEL,       "", NULL_KEY,     "");
        llListen(GM_REGISTER_CHANNEL,        "", NULL_KEY,     "");
        llListen(HEARTBEAT_CHANNEL,          "", NULL_KEY,     "");
        llListen(PLACEMENT_RESPONSE_CHANNEL, "", NULL_KEY,     "");
        llListen(CONTROLLER_CHANNEL,         "", NULL_KEY,     "");
        llListen(DBG_CHANNEL,              "", llGetOwner(), "");

        dbg("[PH] Ready. Origin=" + (string)gGridOrigin
            + " Cell=" + (string)gCellSize + "m");

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
            list parts = llParseString2List(msg, ["|"], []);
            if (llList2String(parts, 0) == "TOWER_LABELS")
            {
                gTowerLabels = llDeleteSubList(parts, 0, 0);
                dbg("[PH] Received tower labels: " + llList2CSV(gTowerLabels));
            }
            else handlePlacementResponse(msg);
        }
        else if (channel == gDialogChannel)
        {
            handleDialogResponse(id, msg);
        }
        else if (channel == CONTROLLER_CHANNEL)
        {
            list parts = llParseString2List(msg, ["|"], []);
            string cmd = llList2String(parts, 0);
            if (cmd == "HANDLER_CONFIG")
            {
                // Move to grid centre, then re-derive geometry from new position
                vector target = <(float)llList2String(parts, 1),
                                 (float)llList2String(parts, 2),
                                 (float)llList2String(parts, 3)>;
                llSetRegionPos(target);
                initGridFromPrim();
                dbg("[PH] Moved to grid centre. Origin=" + (string)gGridOrigin
                    + " Cell=" + (string)gCellSize + "m");
                // Re-register to push corrected grid origin to GM
                if (gGM_KEY != NULL_KEY)
                    llRegionSayTo(gGM_KEY, GM_REGISTER_CHANNEL,
                        "REGISTER|4|0|0"
                        + "|" + (string)gGridOrigin.x
                        + "|" + (string)gGridOrigin.y
                        + "|" + (string)gGridOrigin.z
                        + "|" + (string)gCellSize);
            }
            else if (cmd == "SHUTDOWN")
            {
                dbg("[PH] Shutdown.");
                if (gGM_KEY != NULL_KEY)
                    llRegionSayTo(gGM_KEY, GM_DEREGISTER_CHANNEL, "DEREGISTER");
                llDie();
            }
        }
        else if (channel == DBG_CHANNEL)
        {
            if      (msg == "DEBUG_ON")  gDebug = TRUE;
            else if (msg == "DEBUG_OFF") gDebug = FALSE;
        }
    }

    touch_start(integer num_detected)
    {
        integer face = llDetectedTouchFace(0);
        if (face != TOP_FACE) return;

        key    avatar    = llDetectedKey(0);
        vector touch_pos = llDetectedTouchPos(0);
        vector grid      = translateToGrid(touch_pos);

        if ((integer)grid.x == -1)
        { dbg("[PH] Touch OOB at " + (string)touch_pos); return; }

        if (!gRegistered)
        { llRegionSayTo(avatar, 0, "Tower placement not ready yet."); return; }

        integer grid_x = (integer)grid.x;
        integer grid_y = (integer)grid.y;

        dbg("[PH] " + llKey2Name(avatar)
            + " -> (" + (string)grid_x + "," + (string)grid_y + ")");

        llRegionSayTo(gGM_KEY, PLACEMENT_CHANNEL,
            "PLACEMENT_REQUEST"
            + "|" + (string)grid_x
            + "|" + (string)grid_y
            + "|" + (string)avatar);
    }

    timer()
    {
        if (!gRegistered)
        {
            if (gDiscovering || gGM_KEY == NULL_KEY) discoverGM();
            else handleGMHere(gGM_KEY);
            return;
        }
        cullStaleDialogs();
    }

    on_rez(integer start_param)
    {
        llResetScript();
    }
}
