// =============================================================================
// board_mover.lsl
// Tower Defense Board Auto-Positioner  -  Phase 8
// =============================================================================
// Lives in the root prim of the linked MapBoard.
// On rez: announces BOARD_READY on CTRL, waits for BOARD_CONFIG from the
// controller, calls llSetRegionPos to move the whole linkset, then swaps its
// CTRL listener for a MAP_TILE SHUTDOWN listener and stays alive.
//
// Staying alive (rather than calling llRemoveInventory) avoids the "dead script"
// problem: if llRemoveInventory fires and the board is later taken back to
// inventory, the script is gone and subsequent rezzes have no handler.
// It also means map_tile.lsl needs no active listeners in board mode — only
// this one script handles both positioning and cleanup.
//
// ACTIVATION GUARD:
//   Avatar inventory rez always passes start_param == 0 — stays inert.
//   Only activates when start_param == BOARD_PARAM (set by the controller).
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
        // Only activate when rezzed by the controller (start_param == BOARD_PARAM).
        // Avatar inventory rez always produces start_param == 0 — stay inert.
        if (start_param != BOARD_PARAM) return;
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
