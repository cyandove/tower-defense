The GM script has no way to auto-detect dropped objects — it only registers objects that actively send a registration message themselves. So to test the registry you need a small companion script that sends that message when it rezzes.

Here's a minimal test object script you can drop into any prim:

```lsl
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
```

## Test Procedure

**Registration:**
1. Make sure the GM prim is rezzed and running
2. Create a new prim, drop `test_object.lsl` into it, and save
3. You should immediately see the GM print something like:
   `[REG] Registered: <key> type=1 grid=(0,0)`

**Heartbeat ACK:**
Wait up to 10 seconds for the next heartbeat cycle. You should see:
`[HB] Sent PING #1 to 1 object(s).`
And the timestamp for that object will update silently. You can confirm with `/td dump registry` — the `last_seen` age should be near 0 seconds.

**Stale culling:**
Delete the test prim without sending a deregister message, then wait 30 seconds (3 heartbeat cycles). You should see:
`[HB] Culling stale object: <key> (last seen 30s ago)`

**Clean deregistration:**
Add a `removed` event to the test script that fires the deregister message:

```lsl
on_rez(integer start_param)
{
    if (start_param == 0)
        llSay(GM_DEREGISTER_CHANNEL, "DEREGISTER");
    llResetScript();
}
```

Actually the better place for that is in a hypothetical `final` event, but LSL doesn't have one — deleted prims just vanish. So clean deregistration in production will come from scripts explicitly calling it before they're done (e.g. an enemy that reaches the end of the path), and the heartbeat cull handles everything else.

The test script is deliberately tiny — once the registry is verified working you can extend it to test specific object types or grid positions by changing the constants at the top.
