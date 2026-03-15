// =============================================================================
// board_mover.lsl
// Tower Defense Board Auto-Positioner  -  Phase 8
// =============================================================================
// Lives in every MapTile prim (alongside map_tile.lsl), but only activates
// in the root prim (link 1) when rezzed by the controller.
//
// Including this script in MapTile from the start avoids the llGiveInventory
// delivery problem: scripts delivered at link-time via llGiveInventory do not
// reliably start running. By shipping board_mover in the tile prim itself,
// it is always present and already running when the board is rezzed.
//
// On rez (start_param == BOARD_PARAM, link 1 only): announces BOARD_READY on
// CTRL, waits for BOARD_CONFIG, calls llSetRegionPos to move the whole
// linkset, then swaps its CTRL listener for a MAP_TILE SHUTDOWN listener.
// All 99 non-root tile instances return immediately in on_rez.
//
// ACTIVATION GUARD:
//   Avatar inventory rez passes start_param == 0 — all instances stay inert.
//   Controller rez passes start_param == BOARD_PARAM — only link 1 activates.
//
// CHANNELS:
//   CTRL     = -2013   controller <-> board_mover (positioning handshake)
//   MAP_TILE = -2014   controller -> board_mover (SHUTDOWN)
// =============================================================================

integer CTRL        = -2013;
integer MAP_TILE    = -2014;
integer BOARD_PARAM = 99999;   // sentinel passed by controller; never sent by avatar inventory rez
integer gHandle     = 0;

default
{
    state_entry() {}

    on_rez(integer start_param)
    {
        // Only the root prim (link 1) handles positioning and shutdown.
        // Non-root instances of this script stay completely inert.
        if (start_param != BOARD_PARAM) return;
        if (llGetLinkNumber() != 1) return;
        if (gHandle != 0) { llListenRemove(gHandle); gHandle = 0; }
        gHandle = llListen(CTRL, "", NULL_KEY, "");
        llSay(CTRL, "BOARD_READY");
    }

    listen(integer channel, string name, key id, string msg)
    {
        if (channel == CTRL)
        {
            list   parts = llParseString2List(msg, ["|"], []);
            string cmd   = llList2String(parts, 0);

            if (cmd == "BOARD_CONFIG")
            {
                // BOARD_CONFIG|x|y|z  — pre-computed by controller
                if (llGetListLength(parts) < 4) return;
                vector target = <(float)llList2String(parts, 1),
                                 (float)llList2String(parts, 2),
                                 (float)llList2String(parts, 3)>;
                llSetRegionPos(target);
                // Swap CTRL listener for SHUTDOWN listener.
                // Staying alive avoids the llRemoveInventory dead-script problem.
                if (gHandle != 0) { llListenRemove(gHandle); gHandle = 0; }
                gHandle = llListen(MAP_TILE, "", NULL_KEY, "SHUTDOWN");
            }
        }
        else if (channel == MAP_TILE)
        {
            llDie();   // kills the entire linkset
        }
    }
}
