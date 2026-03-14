// =============================================================================
// board_mover.lsl
// Tower Defense Board Auto-Positioner  -  Phase 8
// =============================================================================
// Lives in the root prim (tile 0,0) of the linked MapBoard.
// On rez: announces BOARD_READY on CTRL channel, waits for BOARD_CONFIG from
// the controller, calls llSetRegionPos to move the whole linkset to the correct
// grid position, then removes itself via llRemoveInventory.
//
// Cleanup (llDie on the whole linkset) is handled by map_tile.lsl's SHUTDOWN
// listener which is active in all tiles when start_param == 0.
//
// ACTIVATION GUARD:
//   llGetRezzingObject() == NULL_KEY means rezzed from an avatar's inventory — stays inert.
//   Only activates when rezzed by an in-world object (the controller).
//
// CHANNELS:
//   CTRL = -2013   controller <-> board_mover
// =============================================================================

integer CTRL    = -2013;
integer gHandle = 0;

default
{
    state_entry() {}   // nothing on first compile

    on_rez(integer start_param)
    {
        // Only activate when rezzed by an in-world object (the controller).
        // Rezzed from an avatar's inventory: llGetRezzingObject() == NULL_KEY — stay inert.
        if (llGetRezzingObject() == NULL_KEY) return;
        gHandle = llListen(CTRL, "", NULL_KEY, "");
        llSay(CTRL, "BOARD_READY");
    }

    listen(integer channel, string name, key id, string msg)
    {
        list   parts = llParseString2List(msg, ["|"], []);
        string cmd   = llList2String(parts, 0);

        if (cmd == "BOARD_CONFIG")
        {
            // BOARD_CONFIG|ox|oy|oz|cell_size
            if (llGetListLength(parts) < 5) return;
            float ox = (float)llList2String(parts, 1);
            float oy = (float)llList2String(parts, 2);
            float oz = (float)llList2String(parts, 3);
            float cs = (float)llList2String(parts, 4);
            // Root prim is tile (0,0) — move it to its correct grid position.
            // All other tiles follow since they maintain fixed offsets from root.
            vector target = <ox + cs * 0.5, oy + cs * 0.5, oz + 0.1>;
            llSetRegionPos(target);
            if (gHandle != 0) { llListenRemove(gHandle); gHandle = 0; }
            llSleep(0.5);   // allow position change to commit before self-destruct
            llRemoveInventory(llGetScriptName());   // board positioned — clean up self
        }
    }
}
