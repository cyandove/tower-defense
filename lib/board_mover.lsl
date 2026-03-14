// =============================================================================
// board_mover.lsl
// Tower Defense Board Auto-Positioner  -  Phase 8
// =============================================================================
// Lives in the root prim (tile 0,0) of the linked MapBoard.
// On rez: announces BOARD_READY on CTRL channel, waits for BOARD_CONFIG from
// the controller containing the pre-computed target position (x|y|z), calls
// llSetRegionPos to move the whole linkset, then removes itself via llRemoveInventory.
// Mirrors how PlacementHandler receives and applies HANDLER_CONFIG.
//
// Cleanup (llDie on the whole linkset) is handled by map_tile.lsl's SHUTDOWN
// listener which is active in all tiles when start_param == BOARD_PARAM.
//
// ACTIVATION GUARD:
//   Avatar inventory rez always passes start_param == 0 — stays inert.
//   Only activates when start_param == BOARD_PARAM (set by the controller's llRezObject call).
//
// CHANNELS:
//   CTRL = -2013   controller <-> board_mover
// =============================================================================

integer CTRL        = -2013;
integer BOARD_PARAM = 99999;   // sentinel passed by controller; never sent by avatar inventory rez
integer gHandle     = 0;

default
{
    state_entry() {}   // nothing on first compile

    on_rez(integer start_param)
    {
        // Only activate when rezzed by the controller (start_param == BOARD_PARAM).
        // Avatar inventory rez always produces start_param == 0 — stay inert.
        if (start_param != BOARD_PARAM) return;
        gHandle = llListen(CTRL, "", NULL_KEY, "");
        llSay(CTRL, "BOARD_READY");
    }

    listen(integer channel, string name, key id, string msg)
    {
        list   parts = llParseString2List(msg, ["|"], []);
        string cmd   = llList2String(parts, 0);

        if (cmd == "BOARD_CONFIG")
        {
            // BOARD_CONFIG|x|y|z  — pre-computed by controller (mirrors HANDLER_CONFIG)
            if (llGetListLength(parts) < 4) return;
            vector target = <(float)llList2String(parts, 1),
                             (float)llList2String(parts, 2),
                             (float)llList2String(parts, 3)>;
            llSetRegionPos(target);
            if (gHandle != 0) { llListenRemove(gHandle); gHandle = 0; }
            llSleep(0.5);   // allow position change to commit before self-destruct
            llRemoveInventory(llGetScriptName());   // board positioned — clean up self
        }
    }
}
