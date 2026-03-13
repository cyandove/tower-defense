// =============================================================================
// map_tile.lsl
// Tower Defense Map Tile  -  Phase 8
// =============================================================================
// Rezzed by the MapBuilder, one per grid cell.
//
// start_param encoding: cell_type * 10000 + gx * 100 + gy
//   cell_type: 0=blocked, 1=buildable, 2=path
//   gx, gy: 0–99 each
//
// FLOW:
//   1. on_rez decodes start_param, stores gGridX/gGridY/gCellType.
//   2. Waits in default state for MAP_DATA broadcast on MAP_TILE channel.
//   3. On MAP_DATA: stores full map, sets scale, moves self via llSetRegionPos
//      to correct grid position (tiles rez at builder's origin to avoid the
//      llRezObject 10m limit), then colours self by cell type.
//   4. On touch: shows 12-button compass-rose dialog.
//   5. Dialog responses: neighbour buttons → OPEN_MENU broadcast; Set Tex →
//      llTextBox; Clear → revert color; Done → close; center → reopen menu.
//   6. On OPEN_MENU: if coords match self, show dialog for requested avatar.
//   7. On SHUTDOWN: llDie().
//
// CHANNELS:
//   MAP_TILE = -2014   builder <-> tiles, tile <-> tile navigation
// =============================================================================


// -----------------------------------------------------------------------------
// CHANNELS
// -----------------------------------------------------------------------------
integer MAP_TILE = -2014;


// -----------------------------------------------------------------------------
// DEBUG
// -----------------------------------------------------------------------------
integer gDebug      = FALSE;
integer DBG_CHANNEL = -2099;

dbg(string msg)
{
    if (gDebug) llOwnerSay(msg);
}


// -----------------------------------------------------------------------------
// GRID IDENTITY  (decoded from start_param on rez)
// -----------------------------------------------------------------------------
integer gGridX     = 0;
integer gGridY     = 0;
integer gCellType  = 0;   // 0=blocked, 1=buildable, 2=path


// -----------------------------------------------------------------------------
// MAP DATA  (received via MAP_DATA broadcast)
// -----------------------------------------------------------------------------
integer gMapW       = 10;
integer gMapH       = 10;
float   gCellSize   = 2.0;
vector  gGridOrigin = ZERO_VECTOR;
list    gCellTypes  = [];   // integer per cell, length = gMapW * gMapH
integer gMapReady   = FALSE;


// -----------------------------------------------------------------------------
// MENU STATE
// -----------------------------------------------------------------------------
integer gMenuHandle  = 0;
integer gTexHandle   = 0;
integer gMenuTimeout = 30;   // seconds
integer gMenuExpiry  = 0;
integer gTexExpiry   = 0;
key     gMenuAvatar  = NULL_KEY;

// Derived once in state_entry from llGetKey()
integer gMenuChannel = 0;
integer gTexChannel  = 0;


// -----------------------------------------------------------------------------
// TYPE COLORS
// -----------------------------------------------------------------------------
vector COLOR_BUILD   = <0.2, 0.7, 0.2>;   // green
vector COLOR_PATH    = <0.6, 0.4, 0.2>;   // brown
vector COLOR_BLOCKED = <0.25, 0.25, 0.25>; // dark gray


// -----------------------------------------------------------------------------
// HELPERS
// -----------------------------------------------------------------------------

integer getCellType(integer x, integer y)
{
    if (x < 0 || x >= gMapW || y < 0 || y >= gMapH) return -1;
    return llList2Integer(gCellTypes, y * gMapW + x);
}

string typeLabel(integer t)
{
    if (t == 1) return "Build";
    if (t == 2) return "Path";
    if (t == 0) return "Block";
    return "---";
}

string typeInitial(integer t)
{
    if (t == 1) return "B";
    if (t == 2) return "P";
    return "X";
}

applyColor(integer t)
{
    if      (t == 1) llSetColor(COLOR_BUILD,   ALL_SIDES);
    else if (t == 2) llSetColor(COLOR_PATH,    ALL_SIDES);
    else             llSetColor(COLOR_BLOCKED,  ALL_SIDES);
}

// Build a neighbour button label: "NW:Build", "S:---" for off-grid, etc.
string neighborBtn(string dir, integer dx, integer dy)
{
    integer nx = gGridX + dx;
    integer ny = gGridY + dy;
    integer t  = getCellType(nx, ny);
    return dir + ":" + typeLabel(t);
}

// Build the center button label: "(3,4)B"
string centerBtn()
{
    return "(" + (string)gGridX + "," + (string)gGridY + ")"
           + typeInitial(gCellType);
}

// Assemble the full 12-button list.
// LSL displays buttons bottom-to-top, 3 per row.
// Desired layout (top→bottom visual):
//   top row:   NW  N   NE
//   row 3:     W  (ctr) E
//   row 2:     SW  S   SE
//   bottom:    SetTex Clear Done
// Button list order (index 0=bottom-left):
//   [0..2]  = bottom row
//   [3..5]  = row 2
//   [6..8]  = row 3
//   [9..11] = top row
list buildMenuButtons()
{
    return [
        "Set Tex", "Clear", "Done",
        neighborBtn("SW", -1, -1), neighborBtn("S", 0, -1), neighborBtn("SE", 1, -1),
        neighborBtn("W", -1,  0),  centerBtn(),              neighborBtn("E", 1, 0),
        neighborBtn("NW",-1,  1),  neighborBtn("N", 0, 1),  neighborBtn("NE",1, 1)
    ];
}

showTileMenu(key avatar)
{
    // Clean up any stale menu listener
    if (gMenuHandle != 0) { llListenRemove(gMenuHandle); gMenuHandle = 0; }

    gMenuAvatar  = avatar;
    gMenuHandle  = llListen(gMenuChannel, "", avatar, "");
    gMenuExpiry  = llGetUnixTime() + gMenuTimeout;
    string prompt = "Tile (" + (string)gGridX + "," + (string)gGridY + ")  "
                  + typeLabel(gCellType);
    llDialog(avatar, prompt, buildMenuButtons(), gMenuChannel);
}

closeMenu()
{
    if (gMenuHandle != 0) { llListenRemove(gMenuHandle); gMenuHandle = 0; }
    if (gTexHandle  != 0) { llListenRemove(gTexHandle);  gTexHandle  = 0; }
    gMenuAvatar = NULL_KEY;
}

// Parse a direction prefix from a dialog button label (e.g. "NW:Build" → "NW")
string btnDir(string label)
{
    integer colon = llSubStringIndex(label, ":");
    if (colon < 0) return "";
    return llGetSubString(label, 0, colon - 1);
}

// Map a direction string to (dx, dy)
list dirOffset(string dir)
{
    if (dir == "N")  return [ 0,  1];
    if (dir == "NE") return [ 1,  1];
    if (dir == "E")  return [ 1,  0];
    if (dir == "SE") return [ 1, -1];
    if (dir == "S")  return [ 0, -1];
    if (dir == "SW") return [-1, -1];
    if (dir == "W")  return [-1,  0];
    if (dir == "NW") return [-1,  1];
    return [0, 0];
}


// =============================================================================
// STATES
// =============================================================================

// default: dormant — just waiting for on_rez to decode start_param
default
{
    on_rez(integer start_param)
    {
        // Decode: cell_type * 10000 + gx * 100 + gy
        gCellType = start_param / 10000;
        integer rem = start_param % 10000;
        gGridX    = rem / 100;
        gGridY    = rem % 100;
        state active;
    }
}


state active
{
    state_entry()
    {
        // Derive per-tile unique channels from prim key
        // Use different substrings so menu and tex channels differ
        gMenuChannel = -(integer)("0x" + llGetSubString((string)llGetKey(), 0, 6));
        gTexChannel  = -(integer)("0x" + llGetSubString((string)llGetKey(), 2, 8));

        llListen(MAP_TILE,    "", NULL_KEY,     "");
        llListen(DBG_CHANNEL, "", llGetOwner(), "");

        applyColor(gCellType);

        // Scale to cell size (set z thin, x and y to cell size)
        // We'll update once MAP_DATA arrives with confirmed cell_size
        llSetScale(<gCellSize, gCellSize, 0.05>);

        // Start cleanup timer
        llSetTimerEvent(10.0);

        dbg("[TILE] Active: (" + (string)gGridX + "," + (string)gGridY
            + ") type=" + (string)gCellType);
    }

    touch_start(integer num)
    {
        showTileMenu(llDetectedKey(0));
    }

    listen(integer channel, string name, key id, string msg)
    {
        // --- DBG toggle ---
        if (channel == DBG_CHANNEL)
        {
            if      (msg == "DEBUG_ON")  gDebug = TRUE;
            else if (msg == "DEBUG_OFF") gDebug = FALSE;
            return;
        }

        // --- MAP_TILE channel ---
        if (channel == MAP_TILE)
        {
            list   parts = llParseString2List(msg, ["|"], []);
            string cmd   = llList2String(parts, 0);

            if (cmd == "MAP_DATA" && !gMapReady)
            {
                // MAP_DATA|map_w|map_h|cell_size|ox|oy|oz|t0,t1,...
                if (llGetListLength(parts) < 8) return;
                gMapW       = (integer)llList2String(parts, 1);
                gMapH       = (integer)llList2String(parts, 2);
                gCellSize   = (float)  llList2String(parts, 3);
                gGridOrigin = <(float)llList2String(parts, 4),
                               (float)llList2String(parts, 5),
                               (float)llList2String(parts, 6)>;
                string csv  = llList2String(parts, 7);
                gCellTypes  = llParseString2List(csv, [","], []);
                gMapReady   = TRUE;
                llSetScale(<gCellSize, gCellSize, 0.05>);
                // Move to correct grid position (no distance limit via llSetRegionPos)
                vector worldPos = <gGridOrigin.x + (gGridX + 0.5) * gCellSize,
                                   gGridOrigin.y + (gGridY + 0.5) * gCellSize,
                                   gGridOrigin.z + 0.1>;
                llSetRegionPos(worldPos);
                dbg("[TILE] Map data received. Moving to ("
                    + (string)gGridX + "," + (string)gGridY + ").");
                return;
            }

            if (cmd == "OPEN_MENU")
            {
                // OPEN_MENU|gx|gy|avatar_key
                if (llGetListLength(parts) < 4) return;
                integer tx = (integer)llList2String(parts, 1);
                integer ty = (integer)llList2String(parts, 2);
                if (tx != gGridX || ty != gGridY) return;
                key avatar = (key)llList2String(parts, 3);
                showTileMenu(avatar);
                return;
            }

            if (cmd == "SHUTDOWN")
            {
                llDie();
                return;
            }
            return;
        }

        // --- Menu channel ---
        if (channel == gMenuChannel)
        {
            // Remove listener — each response is one-shot
            if (gMenuHandle != 0) { llListenRemove(gMenuHandle); gMenuHandle = 0; }

            if (msg == "Done")
            {
                closeMenu();
                return;
            }

            if (msg == "Clear")
            {
                llSetTexture(TEXTURE_BLANK, ALL_SIDES);
                applyColor(gCellType);
                showTileMenu(gMenuAvatar);
                return;
            }

            if (msg == "Set Tex")
            {
                if (gTexHandle != 0) { llListenRemove(gTexHandle); gTexHandle = 0; }
                gTexHandle = llListen(gTexChannel, "", gMenuAvatar, "");
                gTexExpiry = llGetUnixTime() + gMenuTimeout;
                llTextBox(gMenuAvatar,
                    "Paste texture UUID for tile ("
                    + (string)gGridX + "," + (string)gGridY + "):",
                    gTexChannel);
                return;
            }

            // Check if it's the center button (own tile) — reopen menu
            string center = centerBtn();
            if (msg == center)
            {
                showTileMenu(gMenuAvatar);
                return;
            }

            // Check if it's a direction neighbour button
            string dir = btnDir(msg);
            if (dir != "")
            {
                list   off  = dirOffset(dir);
                integer dx  = llList2Integer(off, 0);
                integer dy  = llList2Integer(off, 1);
                integer nx  = gGridX + dx;
                integer ny  = gGridY + dy;
                // Bounds-check — off-grid buttons show "---" but are still clickable
                if (nx >= 0 && nx < gMapW && ny >= 0 && ny < gMapH)
                {
                    llSay(MAP_TILE,
                        "OPEN_MENU"
                        + "|" + (string)nx
                        + "|" + (string)ny
                        + "|" + (string)gMenuAvatar);
                }
                // If off-grid: do nothing (button was decorative)
                return;
            }
            return;
        }

        // --- Texture input channel ---
        if (channel == gTexChannel)
        {
            if (gTexHandle != 0) { llListenRemove(gTexHandle); gTexHandle = 0; }
            // Basic UUID validation: must be 36 chars
            if (llStringLength(msg) == 36)
            {
                llSetTexture((key)msg, ALL_SIDES);
                dbg("[TILE] Texture applied: " + msg);
            }
            else
            {
                llRegionSayTo(gMenuAvatar, 0,
                    "[Tile] Invalid UUID length. Use 'Set Tex' again.");
            }
            // Reopen the menu after texture input
            showTileMenu(gMenuAvatar);
            return;
        }
    }

    timer()
    {
        integer now = llGetUnixTime();
        // Cull stale menu listener
        if (gMenuHandle != 0 && gMenuExpiry > 0 && now > gMenuExpiry)
        {
            llListenRemove(gMenuHandle);
            gMenuHandle = 0;
            gMenuAvatar = NULL_KEY;
        }
        // Cull stale texture listener
        if (gTexHandle != 0 && gTexExpiry > 0 && now > gTexExpiry)
        {
            llListenRemove(gTexHandle);
            gTexHandle = 0;
        }
    }

    on_rez(integer start_param)
    {
        llResetScript();
    }
}
