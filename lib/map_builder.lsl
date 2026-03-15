// =============================================================================
// map_builder.lsl
// Tower Defense Map Builder  -  Phase 8
// =============================================================================
// Lives in the controller prim's inventory as "MapBuilder" object, itself
// containing the "MapTile" object + map_tile.lsl.
//
// FLOW:
//   1. Rezzed by controller on "Build Map". Sends BUILDER_READY on CTRL.
//   2. Receives BUILDER_CONFIG from controller: grid origin, cell_size, map W/H,
//      and CSV string of 100 cell types.
//   3. Rezzes 100 MapTile prims via timer (one per 0.2s tick) to avoid
//      overflowing the 64-event LSL queue with object_rez events. All tiles
//      are rezzed at the builder's own position (llRezObject 10m limit workaround).
//   4. Tracks each tile's key via object_rez. When all tiles are rezzed,
//      broadcasts MAP_DATA (including grid origin) on MAP_TILE. Each tile
//      calls llSetRegionPos to move itself to its correct grid position.
//
// NOTE: on_rez resets globals manually instead of calling llResetScript().
// After llResetScript(), on_rez does not re-fire, so start_param is lost.
//   5. On LINK_TILES: requests PERMISSION_CHANGE_LINKS, then iterates
//      gTileKeys calling llCreateLink (1.0s server delay per call = ~100s).
//      Reports progress every 10 tiles. After all linked, breaks self from
//      linkset and dies. board_mover.lsl is already in every MapTile prim
//      and needs no delivery step.
//   6. On SHUTDOWN: broadcasts SHUTDOWN on MAP_TILE, then dies.
//
// CHANNELS:
//   CTRL     = -2013   controller <-> builder
//   MAP_TILE = -2014   builder <-> tiles
// =============================================================================


// -----------------------------------------------------------------------------
// CHANNELS
// -----------------------------------------------------------------------------
integer CTRL     = -2013;
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
// GRID CONFIG  (received from controller)
// -----------------------------------------------------------------------------
vector  gGridOrigin = ZERO_VECTOR;
float   gCellSize   = 2.0;
integer gMapW       = 10;
integer gMapH       = 10;
list    gCellTypes  = [];   // integers, length = gMapW * gMapH


// -----------------------------------------------------------------------------
// REZ STATE
// -----------------------------------------------------------------------------
string  INV_TILE    = "MapTile";
integer gRezX       = 0;
integer gRezY       = 0;
integer gRezzing    = FALSE;
float   REZ_INTERVAL = 0.2;   // seconds between tile rezzes

list    gTileKeys   = [];   // keys of all rezzed tiles, in rez order
integer gRezTotal   = 0;    // = gMapW * gMapH


// -----------------------------------------------------------------------------
// LINK STATE
// -----------------------------------------------------------------------------
integer gLinking    = FALSE;
integer gLinkIdx    = 0;


// -----------------------------------------------------------------------------
// HELPERS
// -----------------------------------------------------------------------------

// All tiles rez at the builder's own position to stay within llRezObject's 10m limit.
// Each tile calls llSetRegionPos on itself after receiving MAP_DATA (which includes
// the grid origin) to move to its correct world position.
vector tileRezPos()
{
    return llGetPos() + <0.0, 0.0, 0.5>;
}

startRezzing()
{
    gRezX    = 0;
    gRezY    = 0;
    gTileKeys = [];
    gRezzing = TRUE;
    llSetTimerEvent(REZ_INTERVAL);
    llOwnerSay("[BLD] Rezzing " + (string)gRezTotal + " tiles...");
}

// Broadcast MAP_DATA to all tiles so they can initialise and position themselves.
// Format: MAP_DATA|map_w|map_h|cell_size|ox|oy|oz|t0,t1,...
broadcastMapData()
{
    string types_csv = llDumpList2String(gCellTypes, ",");
    llSay(MAP_TILE,
        "MAP_DATA"
        + "|" + (string)gMapW
        + "|" + (string)gMapH
        + "|" + (string)gCellSize
        + "|" + (string)gGridOrigin.x
        + "|" + (string)gGridOrigin.y
        + "|" + (string)gGridOrigin.z
        + "|" + types_csv);
    llOwnerSay("[BLD] Map data broadcast. All tiles initialised.");
}


// =============================================================================
// STATES
// =============================================================================

// default: dormant gate — only activates when rezzed by the controller (start_param=1).
// Rezzed from inventory (start_param=0) stays inert.
default
{
    on_rez(integer start_param)
    {
        if (start_param == 1) state active;
    }
}


state active
{
    state_entry()
    {
        llListen(CTRL,        "", NULL_KEY,     "");
        llListen(MAP_TILE,    "", NULL_KEY,     "");
        llListen(DBG_CHANNEL, "", llGetOwner(), "");
        // Announce to controller
        llSay(CTRL, "BUILDER_READY");
        dbg("[BLD] Builder ready.");
    }

    listen(integer channel, string name, key id, string msg)
    {
        if (channel == DBG_CHANNEL)
        {
            if      (msg == "DEBUG_ON")  gDebug = TRUE;
            else if (msg == "DEBUG_OFF") gDebug = FALSE;
            return;
        }

        if (channel == CTRL)
        {
            list   parts = llParseString2List(msg, ["|"], []);
            string cmd   = llList2String(parts, 0);

            if (cmd == "BUILDER_CONFIG")
            {
                // BUILDER_CONFIG|ox|oy|oz|cell_size|map_w|map_h|t0,t1,...,t99
                if (llGetListLength(parts) < 8) return;
                gGridOrigin = <(float)llList2String(parts, 1),
                               (float)llList2String(parts, 2),
                               (float)llList2String(parts, 3)>;
                gCellSize   = (float)llList2String(parts, 4);
                gMapW       = (integer)llList2String(parts, 5);
                gMapH       = (integer)llList2String(parts, 6);
                string csv  = llList2String(parts, 7);
                gCellTypes  = llParseString2List(csv, [","], []);
                gRezTotal   = gMapW * gMapH;
                dbg("[BLD] Config received. Grid: " + (string)gMapW
                    + "x" + (string)gMapH
                    + " cells. Cell size: " + (string)gCellSize);
                startRezzing();
                return;
            }

            if (cmd == "LINK_TILES")
            {
                if (llGetListLength(gTileKeys) == 0)
                {
                    llOwnerSay("[BLD] No tiles to link.");
                    return;
                }
                gLinking = TRUE;
                gLinkIdx = 0;
                llOwnerSay("[BLD] Requesting link permissions...");
                llRequestPermissions(llGetOwner(), PERMISSION_CHANGE_LINKS);
                return;
            }

            if (cmd == "EXPORT_MAP")
            {
                // Find entry_x: first path (type 2) cell on y=0
                integer entry_x = -1;
                integer x;
                for (x = 0; x < gMapW; x++)
                {
                    if (llList2Integer(gCellTypes, x) == 2)
                    { entry_x = x; x = gMapW; }
                }
                if (entry_x == -1)
                    llOwnerSay("[BLD] WARNING: no path cell on y=0");
                llOwnerSay("[BLD] --- CREATE NOTECARD, PASTE BELOW ---");
                llOwnerSay("# map_N.cfg");
                llOwnerSay("# Cell types: X=blocked  B=buildable  P=path");
                llOwnerSay("map_w="     + (string)gMapW);
                llOwnerSay("map_h="     + (string)gMapH);
                llOwnerSay("cell_size=" + (string)gCellSize);
                llOwnerSay("entry_x="   + (string)entry_x);
                llOwnerSay("board_name=MapBoard");
                integer y;
                for (y = 0; y < gMapH; y++)
                {
                    string row = "row_" + (string)y + "=";
                    for (x = 0; x < gMapW; x++)
                    {
                        integer tp = llList2Integer(gCellTypes, y * gMapW + x);
                        if      (tp == 2) row += "P";
                        else if (tp == 1) row += "B";
                        else              row += "X";
                    }
                    llOwnerSay(row);
                }
                llOwnerSay("[BLD] --- END ---");
                return;
            }

            if (cmd == "SHUTDOWN")
            {
                llSay(MAP_TILE, "SHUTDOWN");
                llSleep(0.5);
                llDie();
                return;
            }
        }

        if (channel == MAP_TILE)
        {
            list   parts = llParseString2List(msg, ["|"], []);
            string cmd   = llList2String(parts, 0);

            if (cmd == "TYPE_CHANGE")
            {
                // TYPE_CHANGE|gx|gy|new_type
                if (llGetListLength(parts) < 4) return;
                integer tx  = (integer)llList2String(parts, 1);
                integer ty  = (integer)llList2String(parts, 2);
                integer nt  = (integer)llList2String(parts, 3);
                integer idx = ty * gMapW + tx;
                gCellTypes  = llListReplaceList(gCellTypes, [nt], idx, idx);
                dbg("[BLD] TYPE_CHANGE (" + (string)tx + "," + (string)ty
                    + ")=" + (string)nt);
                return;
            }
        }
    }

    timer()
    {
        if (gRezzing)
        {
            if (gRezX >= gMapW)
            {
                gRezX = 0;
                gRezY++;
            }
            if (gRezY >= gMapH)
            {
                // All tiles queued — wait for object_rez events to complete
                gRezzing = FALSE;
                llSetTimerEvent(0.0);
                dbg("[BLD] All " + (string)gRezTotal + " tiles queued.");
                return;
            }

            integer cell_type = llList2Integer(gCellTypes, gRezY * gMapW + gRezX);
            // Encoding: cell_type * 10000 + gx * 100 + gy + 1
            // +1 ensures start_param is never 0, reserving 0 for inventory-rez detection.
            integer param = cell_type * 10000 + gRezX * 100 + gRezY + 1;
            llRezObject(INV_TILE, tileRezPos(), ZERO_VECTOR, ZERO_ROTATION, param);
            gRezX++;
        }
    }

    object_rez(key id)
    {
        gTileKeys += [id];
        integer count = llGetListLength(gTileKeys);
        if (count == gRezTotal)
        {
            llOwnerSay("[BLD] All " + (string)gRezTotal
                + " tiles rezzed. Broadcasting map data...");
            broadcastMapData();
        }
    }

    run_time_permissions(integer perm)
    {
        if (!(perm & PERMISSION_CHANGE_LINKS)) return;

        integer total = llGetListLength(gTileKeys);
        llOwnerSay("[BLD] Linking " + (string)total
            + " tiles (~" + (string)total + "s)...");

        integer i;
        for (i = 0; i < total; i++)
        {
            key tile = llList2Key(gTileKeys, i);
            llCreateLink(tile, TRUE);
            if ((i + 1) % 10 == 0)
                llOwnerSay("[BLD] Linked " + (string)(i + 1)
                    + "/" + (string)total + " tiles.");
        }

        // Detach the builder itself from the linkset (link 1 = root = self after linking)
        llBreakLink(1);
        llOwnerSay("[BLD] Board linked! Take it into controller inventory.");
        llDie();
    }

    on_rez(integer start_param)
    {
        // Reset all state manually instead of llResetScript() — on_rez does
        // not re-fire after a reset, so start_param would be lost.
        gGridOrigin = ZERO_VECTOR;
        gCellSize   = 2.0;
        gMapW       = 10;
        gMapH       = 10;
        gCellTypes  = [];
        gRezX       = 0;
        gRezY       = 0;
        gRezzing    = FALSE;
        gTileKeys   = [];
        gRezTotal   = 0;
        gLinking    = FALSE;
        gLinkIdx    = 0;
        if (start_param == 1) state active;
        else state default;
    }
}
