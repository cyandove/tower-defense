// =============================================================================
// placement_handler.lsl
// Tower Defense Placement Handler — Phase 6
// =============================================================================
// PHASE 6 CHANGES:
//   - Registration message extended to include grid origin and cell size so the
//     GM can store grid geometry for tower rezzing:
//       REGISTER|4|0|0|<origin_x>|<origin_y>|<origin_z>|<cell_size>
//   - Touch flow changed from single-step to two-step:
//       Step 1: Send PLACEMENT_REQUEST to GM for cell validation
//       Step 2: On PLACEMENT_RESERVED, show llDialog tower type menu to avatar
//   - On dialog response: forward TOWER_PLACE_REQUEST to GM on TOWER_PLACE_CHANNEL
//   - Added TOWER_PLACE_CHANNEL = -2012
//   - Added gPendingDialogs list to track open dialogs: [avatar_key, gx, gy, ...]
//   - Dialog listen uses a filtered handle per avatar; handle stored alongside
//     pending entry and closed after response or timeout
//   - DIALOG_TIMEOUT = 30s matches GM reservation timeout
//
// SETUP:
//   Same as before — flat box prim sized to cover the grid, transparent,
//   phantom OFF. No additional configuration needed.
// =============================================================================


// -----------------------------------------------------------------------------
// CHANNEL CONSTANTS — must match game_manager.lsl
// -----------------------------------------------------------------------------
integer GM_REGISTER_CHANNEL        = -2001;
integer GM_DEREGISTER_CHANNEL      = -2002;
integer HEARTBEAT_CHANNEL          = -2003;
integer PLACEMENT_CHANNEL          = -2004;
integer GM_DISCOVERY_CHANNEL       = -2007;
integer PLACEMENT_RESPONSE_CHANNEL = -2008;
integer GRID_INFO_CHANNEL          = -2011;
integer TOWER_PLACE_CHANNEL        = -2012;


// -----------------------------------------------------------------------------
// GRID CONFIGURATION
// -----------------------------------------------------------------------------
integer MAP_WIDTH  = 10;
integer MAP_HEIGHT = 10;
integer TOP_FACE   = 1;

integer DISCOVERY_RETRY_INTERVAL   = 5;
integer REG_TYPE_PLACEMENT_HANDLER = 4;

// How long to wait for a dialog response before cleaning up the pending entry.
// Should match RESERVATION_TIMEOUT in game_manager.lsl.
integer DIALOG_TIMEOUT = 30;

// llDialog channel — negative, derived from prim key to avoid collisions
// between multiple placement handler instances (there should only be one,
// but this is good practice).
integer gDialogChannel;


// -----------------------------------------------------------------------------
// PENDING DIALOG TABLE
// Tracks avatars who have been shown the tower type dialog but haven't
// responded yet. Strided list: [avatar_key, gx, gy, listen_handle, timestamp]
// -----------------------------------------------------------------------------
integer DIALOG_STRIDE = 5;
list    gPendingDialogs = [];


// -----------------------------------------------------------------------------
// DERIVED GLOBALS
// -----------------------------------------------------------------------------
vector  gGridOrigin;
float   gCellSize;
key     gGM_KEY      = NULL_KEY;
integer gRegistered  = FALSE;
integer gDiscovering = FALSE;

// Tower type labels — must match gTowerTypes in game_manager.lsl.
// Used to populate the llDialog buttons and to map the response back to a type_id.
// Index in this list + 1 = type_id (1-based to match GM registry).
list TOWER_LABELS = ["Basic", "Sniper"];


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
    llOwnerSay("[PH] Broadcasting GM_DISCOVER...");
}

handleGMHere(key gm_key)
{
    gGM_KEY      = gm_key;
    gDiscovering = FALSE;
    llOwnerSay("[PH] Found GM: " + (string)gGM_KEY);

    // Extended registration — include grid geometry so GM can rez towers
    llRegionSayTo(gGM_KEY, GM_REGISTER_CHANNEL,
        "REGISTER|" + (string)REG_TYPE_PLACEMENT_HANDLER + "|0|0"
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
        llOwnerSay("[PH] Registered with GM.");
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
        llRegionSayTo(gGM_KEY, HEARTBEAT_CHANNEL, "ACK|" + llList2String(parts, 1));
}


// =============================================================================
// GRID INFO RESPONSE
// =============================================================================

handleGridInfoRequest(key sender, string msg)
{
    if (sender != gGM_KEY) return;

    list parts = llParseString2List(msg, ["|"], []);
    if (llGetListLength(parts) < 2) return;

    key spawner_key = (key)llList2String(parts, 1);

    llRegionSayTo(spawner_key, GRID_INFO_CHANNEL,
        "GRID_INFO"
        + "|" + (string)gGridOrigin.x
        + "|" + (string)gGridOrigin.y
        + "|" + (string)gGridOrigin.z
        + "|" + (string)gCellSize);

    llOwnerSay("[PH] Sent grid info to " + (string)spawner_key);
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

string gridStr(vector g)
{
    return "(" + (string)((integer)g.x) + "," + (string)((integer)g.y) + ")";
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
    // Remove any existing pending dialog for this avatar first
    removePendingDialog(avatar);
    gPendingDialogs += [(string)avatar, gx, gy, listen_handle, llGetUnixTime()];
}

removePendingDialog(key avatar)
{
    integer idx = findPendingDialog(avatar);
    if (idx == -1) return;
    // Close the listen handle before removing
    llListenRemove(llList2Integer(gPendingDialogs, idx + 3));
    gPendingDialogs = llDeleteSubList(gPendingDialogs, idx, idx + DIALOG_STRIDE - 1);
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

// Converts a tower label (dialog button text) to the type_id the GM expects.
// type_id = index in TOWER_LABELS + 1 (1-based).
integer labelToTypeId(string label)
{
    integer idx = llListFindList(TOWER_LABELS, [label]);
    if (idx == -1) return -1;
    return idx + 1;
}

// Shows the tower selection dialog to the avatar and registers a listen handle.
showTowerDialog(key avatar, integer gx, integer gy)
{
    string prompt = "Select tower type for grid ("
        + (string)gx + "," + (string)gy + ").\n"
        + "Selection expires in " + (string)DIALOG_TIMEOUT + "s.";

    integer handle = llListen(gDialogChannel, "", avatar, "");
    llDialog(avatar, prompt, TOWER_LABELS, gDialogChannel);
    addPendingDialog(avatar, gx, gy, handle);

    llOwnerSay("[PH] Dialog sent to " + llKey2Name(avatar)
        + " for grid (" + (string)gx + "," + (string)gy + ")");
}

// Called when the avatar responds to the dialog.
handleDialogResponse(key avatar, string response)
{
    integer idx = findPendingDialog(avatar);
    if (idx == -1) return;   // not a pending dialog — ignore

    integer gx = llList2Integer(gPendingDialogs, idx + 1);
    integer gy = llList2Integer(gPendingDialogs, idx + 2);

    integer type_id = labelToTypeId(response);
    if (type_id == -1)
    {
        llOwnerSay("[PH] Unknown tower label '" + response + "' from "
            + llKey2Name(avatar) + " — ignoring.");
        removePendingDialog(avatar);
        return;
    }

    removePendingDialog(avatar);   // closes listen handle

    llOwnerSay("[PH] " + llKey2Name(avatar) + " chose type " + (string)type_id
        + " (" + response + ") for grid (" + (string)gx + "," + (string)gy + ")");

    llRegionSayTo(gGM_KEY, TOWER_PLACE_CHANNEL,
        "TOWER_PLACE_REQUEST"
        + "|" + (string)gx
        + "|" + (string)gy
        + "|" + (string)avatar
        + "|" + (string)type_id);
}


// =============================================================================
// PLACEMENT RESPONSE HANDLER
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
        // Cell is valid and reserved — show tower type dialog
        showTowerDialog(avatar, gx, gy);
    }
    else if (cmd == "PLACEMENT_DENIED")
    {
        string reason = llList2String(parts, 4);
        string human_reason;
        if      (reason == "NOT_BUILDABLE")  human_reason = "You can't build there.";
        else if (reason == "CELL_OCCUPIED")  human_reason = "That spot is already taken.";
        else if (reason == "OUT_OF_BOUNDS")  human_reason = "That's outside the play area.";
        else if (reason == "NOT_REGISTERED") human_reason = "Placement system error.";
        else                                 human_reason = "Placement denied (" + reason + ").";
        llRegionSayTo(avatar, 0, human_reason);
        llOwnerSay("[PH] Denied (" + reason + ") for "
            + llKey2Name(avatar) + " at (" + (string)gx + "," + (string)gy + ")");
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

        // Derive a stable dialog channel from this prim's key.
        // llAbs ensures it's positive; we negate it to keep it private.
        gDialogChannel = -(integer)("0x" + llGetSubString((string)llGetKey(), 0, 6));

        llListen(GM_DISCOVERY_CHANNEL,       "", NULL_KEY, "");
        llListen(GM_REGISTER_CHANNEL,        "", NULL_KEY, "");
        llListen(HEARTBEAT_CHANNEL,          "", NULL_KEY, "");
        llListen(PLACEMENT_RESPONSE_CHANNEL, "", NULL_KEY, "");
        llListen(GRID_INFO_CHANNEL,          "", NULL_KEY, "");
        // Note: per-avatar dialog listens are opened dynamically in showTowerDialog()

        llOwnerSay("[PH] Placement handler ready.");
        llOwnerSay("[PH] Grid origin: " + (string)gGridOrigin);
        llOwnerSay("[PH] Cell size:   " + (string)gCellSize + "m");
        llOwnerSay("[PH] Grid:        " + (string)MAP_WIDTH + "x" + (string)MAP_HEIGHT);

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
        else if (channel == GRID_INFO_CHANNEL && id == gGM_KEY)
        {
            list parts = llParseString2List(msg, ["|"], []);
            if (llList2String(parts, 0) == "GRID_INFO_REQUEST")
                handleGridInfoRequest(id, msg);
        }
        else if (channel == gDialogChannel)
        {
            // Dialog response from an avatar — id is the avatar's key
            handleDialogResponse(id, msg);
        }
    }

    touch_start(integer num_detected)
    {
        integer face = llDetectedTouchFace(0);
        if (face != TOP_FACE) return;

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

        if (!gRegistered)
        {
            llRegionSayTo(avatar, 0, "Tower placement is not ready yet.");
            return;
        }

        llOwnerSay("[PH] Touch by " + llKey2Name(avatar)
            + " -> grid (" + (string)grid_x + "," + (string)grid_y + ")");

        // Step 1: ask GM to validate and reserve the cell
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
            if (gDiscovering || gGM_KEY == NULL_KEY)
                discoverGM();
            else
                handleGMHere(gGM_KEY);
            return;
        }

        // Registered — periodic cleanup of stale dialog entries
        cullStaleDialogs();
    }

    on_rez(integer start_param)
    {
        llResetScript();
    }
}
