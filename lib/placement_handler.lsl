// =============================================================================
// placement_handler.lsl
// Tower Defense Placement Handler — Phase 2
//
// Drop this script into a flat transparent prim that covers the playfield.
// When an avatar clicks the prim, it translates the touch position into
// grid coordinates and forwards a PLACEMENT_REQUEST to the Game Manager.
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
integer PLACEMENT_CHANNEL = -2004;


// -----------------------------------------------------------------------------
// GRID CONFIGURATION
// Only MAP_WIDTH, MAP_HEIGHT, TOP_FACE, and GM_KEY need to be set manually.
// Cell size and grid origin are derived from the prim's scale and position.
// -----------------------------------------------------------------------------

// Number of grid columns and rows. Must match game_manager.lsl.
integer MAP_WIDTH  = 10;
integer MAP_HEIGHT = 10;

// The face index of the top face on the overlay prim.
// On a default unmodified cube this is face 1. Verify in-world by touching
// each face with a test script that prints llDetectedTouchFace(0).
integer TOP_FACE = 1;

// Key of the Game Manager prim. Set this after rezzing the GM.
// You can find it by touching the GM prim and printing llDetectedKey(0),
// or by reading it from the GM's llOwnerSay output at startup.
key GM_KEY = NULL_KEY;

// -----------------------------------------------------------------------------
// DERIVED GLOBALS — calculated at startup from prim scale and position.
// Do not edit these directly.
// -----------------------------------------------------------------------------
vector gGridOrigin;  // region-space XY of the grid's (0,0) corner
float  gCellSize;    // meters per cell, derived from prim scale / MAP_WIDTH

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
    string msg = "PLACEMENT_REQUEST"
        + "|" + (string)grid_x
        + "|" + (string)grid_y
        + "|" + (string)avatar;

    if (GM_KEY == NULL_KEY)
    {
        // GM key not configured — broadcast on channel as fallback.
        // This is acceptable during testing but should be replaced with
        // a direct llRegionSayTo once the GM key is known.
        llSay(PLACEMENT_CHANNEL, msg);
        llOwnerSay("[PH] Warning: GM_KEY not set, broadcasting on channel "
            + (string)PLACEMENT_CHANNEL);
    }
    else
    {
        llRegionSayTo(GM_KEY, PLACEMENT_CHANNEL, msg);
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

        llOwnerSay("[PH] Placement handler ready.");
        llOwnerSay("[PH] Prim position: " + (string)llGetPos());
        llOwnerSay("[PH] Prim scale:    " + (string)llGetScale());
        llOwnerSay("[PH] Grid origin:   " + (string)gGridOrigin);
        llOwnerSay("[PH] Cell size:     " + (string)gCellSize + "m");
        llOwnerSay("[PH] Grid:          " + (string)MAP_WIDTH + "x" + (string)MAP_HEIGHT
            + " (" + (string)((integer)(gCellSize * MAP_WIDTH)) + "x"
            + (string)((integer)(gCellSize * MAP_HEIGHT)) + "m total)");
        llOwnerSay("[PH] GM key: " + (string)GM_KEY);

        if (GM_KEY == NULL_KEY)
            llOwnerSay("[PH] Warning: GM_KEY is NULL_KEY. Set it before production use.");
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

    on_rez(integer start_param)
    {
        llResetScript();
    }
}
