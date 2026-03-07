// =============================================================================
// controller-animations.lsl
// Tower Defense — Controller Animation Layer, Phase 8
//
// Drop this script into the controller prim alongside controller.lsl.
// Reacts to llMessageLinked events from controller.lsl — no game logic here.
// Can be removed without affecting game behaviour.
//
// Events handled:
//   ANIM_STATE (300) — parse state|wave|lives|score and update floating text
// =============================================================================


// -----------------------------------------------------------------------------
// ANIMATION EVENT IDS — must match controller.lsl
// -----------------------------------------------------------------------------
integer ANIM_STATE = 300;


// =============================================================================
// HELPERS
// =============================================================================

string stateLabel(integer s)
{
    if (s == 0) return "Idle";
    if (s == 1) return "Setting up...";
    if (s == 2) return "Touch to start wave";
    if (s == 3) return "Wave active";
    if (s == 4) return "Wave clear!";
    if (s == 5) return "GAME OVER";
    return "Unknown";
}


// =============================================================================
// MAIN STATE
// =============================================================================

default
{
    state_entry()
    {
        // Show idle state on script start / reset
        llSetText("Idle", <0.6, 0.6, 0.6>, 1.0);
    }

    link_message(integer sender_num, integer num, string str, key id)
    {
        if (num != ANIM_STATE) return;

        // str format: "lifecycle|wave|lives|score"
        list parts   = llParseString2List(str, ["|"], []);
        integer state = (integer)llList2String(parts, 0);
        integer wave  = (integer)llList2String(parts, 1);
        integer lives = (integer)llList2String(parts, 2);
        integer score = (integer)llList2String(parts, 3);

        string line1 = "Wave " + (string)wave
            + "   Lives: " + (string)lives
            + "   Score: " + (string)score;
        string line2 = stateLabel(state);

        vector color;
        if      (state == 5) color = <1.0, 0.0, 0.0>;   // game over — red
        else if (state == 4) color = <0.0, 1.0, 0.0>;   // wave clear — green
        else if (state == 3) color = <1.0, 0.8, 0.0>;   // wave active — amber
        else                 color = <1.0, 1.0, 1.0>;   // other — white

        llSetText(line1 + "\n" + line2, color, 1.0);
    }
}
