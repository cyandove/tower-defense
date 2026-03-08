// =============================================================================
// enemy.lsl
// Tower Defense Enemy — Phase 4
//
// SETUP:
//   1. Create a new prim in-world
//   2. Drop this script into it — the script will idle in dormant state
//   3. Take the prim into your inventory
//   4. Place the prim into the spawner's inventory
//   5. Name the prim to match ENEMY_OBJECT_NAME in spawner.lsl ("Enemy")
//
// LIFECYCLE:
//   Dormant  → rezzed by spawner (start_param=1) → Active
//   Active   → receives ENEMY_CONFIG from spawner → Moving
//   Moving   → reaches final waypoint → reports ENEMY_ARRIVED → deletes self
// =============================================================================


// -----------------------------------------------------------------------------
// ANIMATION EVENT IDS — shared with enemy-animations.lsl
// -----------------------------------------------------------------------------
integer ANIM_SPAWNED     = 200;
integer ANIM_TAKE_DAMAGE = 201;
integer ANIM_DEATH       = 202;


// -----------------------------------------------------------------------------
// DEBUG
// -----------------------------------------------------------------------------
integer DEBUG         = FALSE;   // compile-time default
integer gDebug        = FALSE;   // runtime toggle
integer DBG_CHANNEL = -2099;   // owner-only debug toggle broadcast


// -----------------------------------------------------------------------------
// CHANNEL CONSTANTS — must match game_manager.lsl and spawner.lsl
// -----------------------------------------------------------------------------
integer GM_REGISTER_CHANNEL   = -2001;
integer GM_DEREGISTER_CHANNEL = -2002;
integer HEARTBEAT_CHANNEL     = -2003;
integer GM_DISCOVERY_CHANNEL  = -2007;
integer ENEMY_REPORT_CHANNEL  = -2006;
integer ENEMY_CHANNEL         = -2010;


// -----------------------------------------------------------------------------
// CONFIGURATION
// -----------------------------------------------------------------------------

// How often the enemy reports its position to the GM, in seconds.
float POSITION_REPORT_INTERVAL = 1.0;

// How close the enemy needs to get to a waypoint before advancing to the next.
// Increase if enemies get stuck; decrease for more precise path following.
float WAYPOINT_THRESHOLD = 0.5;

// llMoveToTarget tau value — lower = snappier movement, higher = smoother.
// 0.5 is a good starting point for ground enemies.
float MOVE_TAU = 0.5;

// Registry type constant
integer REG_TYPE_ENEMY = 2;

// Discovery retry interval in seconds
integer DISCOVERY_RETRY_INTERVAL = 5;


// -----------------------------------------------------------------------------
// GLOBAL STATE (active state only)
// -----------------------------------------------------------------------------
key     gGM_KEY          = NULL_KEY;
integer gRegistered      = FALSE;
integer gDiscovering     = FALSE;
list    gWaypoints       = [];    // list of vectors, parsed from config
integer gCurrentWaypoint = 0;    // index into gWaypoints
float   gSpeed           = 2.0;
float   gHealth          = 100.0;
float   gMaxHealth       = 100.0; // set once from config, for health bar colour gradient
integer gConfigReceived  = FALSE;


// =============================================================================
// DEBUG HELPER
// =============================================================================

dbg(string msg)
{
    if (gDebug) llOwnerSay(msg);
}


// =============================================================================
// WAYPOINT PARSING
// =============================================================================

// Parses the semicolon-delimited, colon-encoded waypoint string from the
// spawner's config message into a list of vectors.
// Input format: "x:y:z;x:y:z;x:y:z;..."
list parseWaypoints(string waypoint_str)
{
    list result   = [];
    list segments = llParseString2List(waypoint_str, [";"], []);
    integer i;
    for (i = 0; i < llGetListLength(segments); i++)
    {
        list coords = llParseString2List(llList2String(segments, i), [":"], []);
        if (llGetListLength(coords) == 3)
        {
            vector wp = <(float)llList2String(coords, 0),
                         (float)llList2String(coords, 1),
                         (float)llList2String(coords, 2)>;
            result += [wp];
        }
    }
    return result;
}


// =============================================================================
// MOVEMENT AND ARRIVAL HELPERS
// Must be defined before the state blocks that call them.
// =============================================================================

moveToCurrentWaypoint()
{
    if (gCurrentWaypoint >= llGetListLength(gWaypoints)) return;
    vector target = llList2Vector(gWaypoints, gCurrentWaypoint);
    llMoveToTarget(target, MOVE_TAU);
    dbg("[EN] Moving to waypoint " + (string)gCurrentWaypoint
        + " at " + (string)target);
}

onArrival()
{
    dbg("[EN] Reached end of path. Reporting arrival.");
    llSetTimerEvent(0);
    llMoveToTarget(ZERO_VECTOR, 0.0);  // stop movement

    if (gGM_KEY != NULL_KEY)
    {
        llRegionSayTo(gGM_KEY, ENEMY_REPORT_CHANNEL, "ENEMY_ARRIVED");
        llRegionSayTo(gGM_KEY, GM_DEREGISTER_CHANNEL, "DEREGISTER");
    }

    // Brief pause so messages can be sent before deletion
    llSleep(0.5);
    llDie();
}

onDeath()
{
    dbg("[EN] Killed! Reporting to GM.");
    llSetTimerEvent(0);
    llMoveToTarget(ZERO_VECTOR, 0.0);  // stop movement

    if (gGM_KEY != NULL_KEY)
    {
        llRegionSayTo(gGM_KEY, ENEMY_REPORT_CHANNEL, "ENEMY_KILLED");
        llRegionSayTo(gGM_KEY, GM_DEREGISTER_CHANNEL, "DEREGISTER");
    }

    llMessageLinked(LINK_THIS, ANIM_DEATH, "", NULL_KEY);
    llSleep(0.5);
    llDie();
}


// =============================================================================
// DORMANT STATE
// Enemy sits here after script load until rezzed by the spawner.
// =============================================================================

default
{
    state_entry()
    {
        // Intentionally empty — enemy is dormant until rezzed with start_param=1
    }

    on_rez(integer start_param)
    {
        if (start_param != 0)
            state active;
        // If start_param is 0 (hand-rezzed or rezzed from inventory directly),
        // stay dormant. This allows safe setup without triggering game logic.
    }
}


// =============================================================================
// ACTIVE STATE
// Enemy wakes here, discovers the GM, registers, waits for config, then moves.
// =============================================================================

state active
{
    state_entry()
    {
        gDebug = DEBUG;
        dbg("[EN] Awake. Discovering GM...");

        // Make the prim physical so llMoveToTarget works
        llSetStatus(STATUS_PHYSICS, TRUE);

        // Prevent the enemy from rotating or tipping due to physics
        llSetStatus(STATUS_ROTATE_X, FALSE);
        llSetStatus(STATUS_ROTATE_Y, FALSE);

        llListen(GM_DISCOVERY_CHANNEL, "", NULL_KEY,     "");
        llListen(GM_REGISTER_CHANNEL,  "", NULL_KEY,     "");
        llListen(HEARTBEAT_CHANNEL,    "", NULL_KEY,     "");
        llListen(ENEMY_CHANNEL,        "", NULL_KEY,     "");
        llListen(DBG_CHANNEL,        "", llGetOwner(), "");

        // Announce to the spawner that we're alive and ready for config.
        // The spawner listens on ENEMY_CHANNEL for ENEMY_READY.
        // We broadcast since we don't have the spawner's key yet.
        llSay(ENEMY_CHANNEL, "ENEMY_READY|" + (string)llGetKey());

        // Begin GM discovery in parallel
        gDiscovering = TRUE;
        llSay(GM_DISCOVERY_CHANNEL, "GM_DISCOVER");

        llSetTimerEvent(DISCOVERY_RETRY_INTERVAL);
    }

    listen(integer channel, string name, key id, string msg)
    {
        if (channel == GM_DISCOVERY_CHANNEL)
        {
            list parts = llParseString2List(msg, ["|"], []);
            if (llList2String(parts, 0) == "GM_HERE" && gGM_KEY == NULL_KEY)
            {
                gGM_KEY      = (key)llList2String(parts, 1);
                gDiscovering = FALSE;
                dbg("[EN] Found GM: " + (string)gGM_KEY);
                llRegionSayTo(gGM_KEY, GM_REGISTER_CHANNEL,
                    "REGISTER|" + (string)REG_TYPE_ENEMY + "|0|0");
            }
        }
        else if (channel == GM_REGISTER_CHANNEL && id == gGM_KEY)
        {
            list parts = llParseString2List(msg, ["|"], []);
            if (llList2String(parts, 0) == "REGISTER_OK")
            {
                gRegistered = TRUE;
                dbg("[EN] Registered with GM.");
                // Don't stop timer yet — still waiting for config if not received
                if (gConfigReceived)
                    llSetTimerEvent(POSITION_REPORT_INTERVAL);
            }
        }
        else if (channel == HEARTBEAT_CHANNEL && id == gGM_KEY)
        {
            list parts = llParseString2List(msg, ["|"], []);
            if (llList2String(parts, 0) == "PING")
                llRegionSayTo(gGM_KEY, HEARTBEAT_CHANNEL,
                    "ACK|" + llList2String(parts, 1));
        }
        else if (channel == DBG_CHANNEL)
        {
            if      (msg == "DEBUG_ON")  gDebug = TRUE;
            else if (msg == "DEBUG_OFF") gDebug = FALSE;
        }
        else if (channel == ENEMY_CHANNEL)
        {
            list parts = llParseString2List(msg, ["|"], []);
            string cmd = llList2String(parts, 0);

            if (cmd == "ENEMY_CONFIG")
            {
                // Format: ENEMY_CONFIG|<speed>|<health>|<waypoint_string>
                if (llGetListLength(parts) < 4)
                {
                    llOwnerSay("[EN] Malformed ENEMY_CONFIG: " + msg);
                    return;
                }
                gSpeed           = (float)llList2String(parts, 1);
                gHealth          = (float)llList2String(parts, 2);
                gMaxHealth       = gHealth;
                gWaypoints       = parseWaypoints(llList2String(parts, 3));
                gCurrentWaypoint = 0;
                gConfigReceived  = TRUE;
                llMessageLinked(LINK_THIS, ANIM_SPAWNED, (string)gHealth, NULL_KEY);

                dbg("[EN] Config received. Speed=" + (string)gSpeed
                    + " Health=" + (string)gHealth
                    + " Waypoints=" + (string)llGetListLength(gWaypoints));

                if (llGetListLength(gWaypoints) == 0)
                {
                    llOwnerSay("[EN] Error: no waypoints in config. Cannot move.");
                    return;
                }

                moveToCurrentWaypoint();

                if (gRegistered)
                    llSetTimerEvent(POSITION_REPORT_INTERVAL);
            }
            else if (cmd == "TAKE_DAMAGE")
            {
                // Format: TAKE_DAMAGE|<amount>
                // Sent directly from a tower on a successful hit.
                if (llGetListLength(parts) < 2) return;
                float amount = (float)llList2String(parts, 1);
                gHealth -= amount;

                dbg("[EN] Hit! -" + (string)((integer)amount)
                    + " hp, remaining: " + (string)((integer)gHealth));

                llMessageLinked(LINK_THIS, ANIM_TAKE_DAMAGE, (string)gHealth, NULL_KEY);

                if (gHealth <= 0.0)
                    onDeath();
            }
        }
    }

    timer()
    {
        // Discovery/registration retry phase
        if (!gConfigReceived)
        {
            if (!gRegistered)
            {
                if (gDiscovering || gGM_KEY == NULL_KEY)
                    llSay(GM_DISCOVERY_CHANNEL, "GM_DISCOVER");
                else
                    llRegionSayTo(gGM_KEY, GM_REGISTER_CHANNEL,
                        "REGISTER|" + (string)REG_TYPE_ENEMY + "|0|0");
            }
            return;
        }

        // Position reporting phase — check waypoint progress and report position
        vector pos = llGetPos();

        // Report position to GM
        if (gRegistered && gGM_KEY != NULL_KEY)
        {
            llRegionSayTo(gGM_KEY, ENEMY_REPORT_CHANNEL,
                "ENEMY_POSITION|" + (string)pos.x
                + "|" + (string)pos.y
                + "|" + (string)pos.z);
        }

        // Check if we've reached the current waypoint
        if (gCurrentWaypoint < llGetListLength(gWaypoints))
        {
            vector target = llList2Vector(gWaypoints, gCurrentWaypoint);
            float dist    = llVecDist(<pos.x, pos.y, 0.0>, <target.x, target.y, 0.0>);

            if (dist < WAYPOINT_THRESHOLD)
            {
                gCurrentWaypoint++;

                if (gCurrentWaypoint >= llGetListLength(gWaypoints))
                {
                    // Reached the final waypoint
                    onArrival();
                }
                else
                {
                    moveToCurrentWaypoint();
                }
            }
        }
    }

    on_rez(integer start_param)
    {
        // Already active — ignore
    }
}



