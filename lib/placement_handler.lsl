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
//      Example: if cell_size=2.0 and grid is 10x10, prim should be 20x20m.
//   2. Position the prim so its corner aligns with your grid's (0,0) origin.
//   3. Set the prim transparent (alpha=0) but leave it phantom OFF so
//      clicks register. Alternatively, set alpha to ~5% so you can see it
//      during testing and turn it fully transparent later.
//   4. Edit CELL_SIZE, GRID_ORIGIN, and TOP_FACE below to match your build.
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
// Edit these values to match your in-world build.
// -----------------------------------------------------------------------------

// Size of each grid cell in meters.
float CELL_SIZE = 2.0;

// Number of grid columns and rows. Must match game_manager.lsl.
integer MAP_WIDTH  = 10;
integer MAP_HEIGHT = 10;

// The region-space XY position of the grid's (0,0) corner — the corner that
// corresponds to the minimum X and minimum Y of your playfield.
// Measure this in-world with a prim or the coordinates display.
// Z is ignored for grid translation but set it to your ground level.
vector GRID_ORIGIN = <128.0, 128.0, 22.0>;

// The face index of the top face on the overlay prim.
// On a default unmodified cube this is face 1. Verify in-world by touching
// each face with a test script that prints llDetectedTouchFace(0).
integer TOP_FACE = 1;

// Key of the Game Manager prim. Set this after rezzing the GM.
// You can find it by touching the GM prim and printing llDetectedKey(0),
// or by reading it from the GM's llOwnerSay output at startup.
key GM_KEY = NULL_KEY;


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
//   vector local_pos = (touch_pos - GRID_ORIGIN) / llGetRot();
// For now, keep your build axis-aligned to avoid this complexity.
vector translateToGrid(vector touch_pos)
{
    // Get position relative to grid origin
    float local_x = touch_pos.x - GRID_ORIGIN.x;
    float local_y = touch_pos.y - GRID_ORIGIN.y;

    // Convert to grid coordinates by dividing by cell size and flooring
    integer grid_x = (integer)(local_x / CELL_SIZE);
    integer grid_y = (integer)(local_y / CELL_SIZE);

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
        llOwnerSay("[PH] Placement handler ready.");
        llOwnerSay("[PH] Grid: " + (string)MAP_WIDTH + "x" + (string)MAP_HEIGHT
            + " cells at " + (string)CELL_SIZE + "m each.");
        llOwnerSay("[PH] Grid origin: " + (string)GRID_ORIGIN);
        llOwnerSay("[PH] Prim position: " + (string)llGetPos());
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
