// =============================================================================
// game_manager_debug.lsl
// Tower Defense — GM Debug Shell
// =============================================================================
// Drop this script into the same prim as game_manager.lsl.
// It listens for /td chat commands from the owner and forwards them to
// game_manager.lsl via link_message(num=42). The GM sends results back
// on link_message(num=43) and this script prints them to local chat.
//
// Remove this script from the prim for production to free code space in the GM.
//
// COMMANDS:
//   /td dump map
//   /td dump registry
//   /td dump pairings
//   /td dump all
//   /td stats
//   /td set <x> <y> <build|path|blocked>
//   /td wave start
// =============================================================================

default
{
    state_entry()
    {
        llListen(0, "", llGetOwner(), "");
        llOwnerSay("[DBG] Debug shell active. /td commands enabled.");
    }

    listen(integer channel, string name, key id, string msg)
    {
        if (llGetSubString(msg, 0, 3) != "/td ") return;
        string cmd = llGetSubString(msg, 4, -1);
        llMessageLinked(LINK_THIS, 42, cmd, "");
    }

    link_message(integer sender_num, integer num, string str, key id)
    {
        if (num != 43) return;
        // GM returns multi-line strings — print each line separately
        list lines = llParseString2List(str, ["\n"], []);
        integer i;
        for (i = 0; i < llGetListLength(lines); i++)
        {
            string line = llList2String(lines, i);
            if (line != "") llOwnerSay(line);
        }
    }
}
