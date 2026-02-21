// test_object.lsl
// Drop this into any prim to test GM registration and heartbeat.

integer GM_REGISTER_CHANNEL   = -2001;
integer GM_DEREGISTER_CHANNEL = -2002;
integer HEARTBEAT_CHANNEL     = -2003;

integer REG_TYPE_TOWER = 1;

default
{
    state_entry()
    {
        // Listen for heartbeat pings
        llListen(HEARTBEAT_CHANNEL, "", NULL_KEY, "");

        // Send registration message to GM
        // Format: REGISTER|<type>|<grid_x>|<grid_y>
        // Use 0,0 as placeholder grid position for testing
        llSay(GM_REGISTER_CHANNEL, "REGISTER|" + (string)REG_TYPE_TOWER + "|0|0");
    }

    listen(integer channel, string name, key id, string msg)
    {
        if (channel == HEARTBEAT_CHANNEL)
        {
            list parts = llParseString2List(msg, ["|"], []);
            if (llList2String(parts, 0) == "PING")
            {
                string seq = llList2String(parts, 1);
                llSay(HEARTBEAT_CHANNEL, "ACK|" + seq);
            }
        }
    }

    on_rez(integer start_param)
    {
        llResetScript();
    }
}
