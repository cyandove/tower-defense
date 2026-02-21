// =============================================================================
// spawner.lsl
// Tower Defense Enemy Spawner — Phase 4c
// Adds: automatic handler discovery via HANDLER_QUERY, no hardcoded keys
// =============================================================================
// PHASE 4c CHANGES:
//   - Removed PAIRED_HANDLER_KEY constant — handler key fetched from GM
//   - After registration, sends HANDLER_QUERY to GM on SPAWNER_CHANNEL
//   - GM responds with HANDLER_INFO|<key>; spawner retries if NULL_KEY
//   - On receiving a valid handler key, sends SPAWNER_PAIRED to GM and
//     requests grid info from the handler via the GM
//   - Spawn held until both pairing and grid info are confirmed
//   - WAVE_START queued if it arrives before setup is complete
//
// SETUP:
//   1. Place the spawner prim at the path entrance in-world
//   2. Add this script — no key configuration needed
//   3. Add the enemy prim (with enemy_base.lsl) to the spawner's inventory,
//      named to match ENEMY_OBJECT_NAME below
//   4. Confirm registration and pairing via /td dump registry and
//      /td dump pairings in the GM
//   5. Type /td wave start to trigger a test spawn
// =============================================================================


// -----------------------------------------------------------------------------
// CHANNEL CONSTANTS — must match game_manager.lsl
// -----------------------------------------------------------------------------
integer GM_REGISTER_CHANNEL   = -2001;
integer GM_DEREGISTER_CHANNEL = -2002;
integer HEARTBEAT_CHANNEL     = -2003;
integer GM_DISCOVERY_CHANNEL  = -2007;
integer SPAWNER_CHANNEL       = -2009;
integer ENEMY_CHANNEL         = -2010;
integer GRID_INFO_CHANNEL     = -2011;


// -----------------------------------------------------------------------------
// CONFIGURATION
// -----------------------------------------------------------------------------

// Name of the enemy object in this prim's inventory.
string ENEMY_OBJECT_NAME = "Enemy";

// Grid position of this spawner (path entrance cell).
integer SPAWNER_GRID_X = 2;
integer SPAWNER_GRID_Y = 0;

// Seconds between each enemy spawn during a wave.
float SPAWN_INTERVAL = 3.0;

// Enemies per wave — keep at 1 for initial testing.
integer ENEMIES_PER_WAVE = 1;

// Enemy stats sent to each enemy in its config message.
float ENEMY_SPEED  = 2.0;
float ENEMY_HEALTH = 100.0;

// Waypoint path in grid coordinates — must stay in sync with initMap() in GM.
list WAYPOINT_GRID = [
    2, 0,   2, 1,   2, 2,   2, 3,   2, 4,
    3, 4,   4, 4,   5, 4,   6, 4,   7, 4,
    7, 5,   7, 6,   7, 7,
    6, 7,   5, 7,   4, 7,   3, 7,   2, 7,
    2, 8,   2, 9
];

// How often to retry during discovery/pairing/grid-info phases, in seconds.
integer RETRY_INTERVAL = 5;

integer REG_TYPE_SPAWNER = 3;


// -----------------------------------------------------------------------------
// GLOBAL STATE
// -----------------------------------------------------------------------------
key     gGM_KEY        = NULL_KEY;
key     gHandlerKey    = NULL_KEY;   // set after HANDLER_INFO received
integer gRegistered    = FALSE;
integer gPaired        = FALSE;      // TRUE after SPAWNER_PAIRED confirmed by GM
integer gGridInfoReady = FALSE;      // TRUE after GRID_INFO received
integer gDiscovering   = FALSE;
integer gWaveQueued    = FALSE;
integer gWaveTarget    = 0;
integer gSpawnCount    = 0;

// Derived from GRID_INFO response
vector  gGridOrigin    = ZERO_VECTOR;
float   gCellSize      = 2.0;
float   gGroundZ       = 0.0;


// =============================================================================
// GRID-TO-WORLD CONVERSION
// =============================================================================

vector gridToWorld(integer gx, integer gy)
{
    return <gGridOrigin.x + (gx + 0.5) * gCellSize,
            gGridOrigin.y + (gy + 0.5) * gCellSize,
            gGroundZ>;
}

string buildWaypointString()
{
    string result = "";
    integer count = llGetListLength(WAYPOINT_GRID);
    integer i;
    for (i = 0; i < count; i += 2)
    {
        integer gx = llList2Integer(WAYPOINT_GRID, i);
        integer gy = llList2Integer(WAYPOINT_GRID, i + 1);
        vector  wp = gridToWorld(gx, gy);
        if (result != "")
            result += ";";
        result += (string)wp.x + ":" + (string)wp.y + ":" + (string)wp.z;
    }
    return result;
}


// =============================================================================
// STARTUP SEQUENCE HELPERS
// Each step is gated on the previous one completing.
// Order: discover GM -> register -> query handler -> pair -> request grid info
// =============================================================================

discoverGM()
{
    gDiscovering = TRUE;
    llSay(GM_DISCOVERY_CHANNEL, "GM_DISCOVER");
    llOwnerSay("[SP] Broadcasting GM_DISCOVER...");
}

handleGMHere(key gm_key)
{
    gGM_KEY      = gm_key;
    gDiscovering = FALSE;
    llOwnerSay("[SP] Found GM: " + (string)gGM_KEY);
    llRegionSayTo(gGM_KEY, GM_REGISTER_CHANNEL,
        "REGISTER|" + (string)REG_TYPE_SPAWNER
        + "|" + (string)SPAWNER_GRID_X
        + "|" + (string)SPAWNER_GRID_Y);
}

handleRegisterResponse(string msg)
{
    list parts = llParseString2List(msg, ["|"], []);
    string cmd = llList2String(parts, 0);
    if (cmd == "REGISTER_OK")
    {
        gRegistered = TRUE;
        llOwnerSay("[SP] Registered. Querying for placement handler...");
        llRegionSayTo(gGM_KEY, SPAWNER_CHANNEL, "SPAWNER_READY");
        queryHandler();
    }
    else if (cmd == "REGISTER_REJECTED")
    {
        llOwnerSay("[SP] Registration rejected: " + llList2String(parts, 1));
    }
}

// Asks the GM for the key of the registered placement handler.
queryHandler()
{
    llRegionSayTo(gGM_KEY, SPAWNER_CHANNEL, "HANDLER_QUERY");
    llOwnerSay("[SP] Sent HANDLER_QUERY to GM.");
}

// Called when GM responds with HANDLER_INFO|<key>.
// If key is NULL_KEY, no handler is registered yet — timer will retry.
handleHandlerInfo(string msg)
{
    list parts = llParseString2List(msg, ["|"], []);
    key handler_key = (key)llList2String(parts, 1);

    if (handler_key == NULL_KEY)
    {
        llOwnerSay("[SP] No handler registered yet. Will retry.");
        return;
    }

    gHandlerKey = handler_key;
    llOwnerSay("[SP] Handler found: " + (string)gHandlerKey + ". Confirming pairing...");

    // Notify GM of the pairing so it can store the association
    llRegionSayTo(gGM_KEY, SPAWNER_CHANNEL,
        "SPAWNER_PAIRED|" + (string)gHandlerKey);

    // Request grid info from the handler via the GM
    requestGridInfo();
}

requestGridInfo()
{
    if (gGM_KEY == NULL_KEY || gHandlerKey == NULL_KEY) return;
    llRegionSayTo(gGM_KEY, GRID_INFO_CHANNEL,
        "GRID_INFO_REQUEST|" + (string)llGetKey()
        + "|" + (string)gHandlerKey);
    llOwnerSay("[SP] Sent GRID_INFO_REQUEST for handler " + (string)gHandlerKey);
}

// Called when the placement handler sends GRID_INFO directly to this spawner.
// Format: GRID_INFO|<origin_x>|<origin_y>|<origin_z>|<cell_size>
handleGridInfo(string msg)
{
    list parts = llParseString2List(msg, ["|"], []);
    if (llGetListLength(parts) < 5)
    {
        llOwnerSay("[SP] Malformed GRID_INFO: " + msg);
        return;
    }

    gGridOrigin = <(float)llList2String(parts, 1),
                   (float)llList2String(parts, 2),
                   (float)llList2String(parts, 3)>;
    gCellSize   = (float)llList2String(parts, 4);
    gGroundZ    = gGridOrigin.z;
    gGridInfoReady = TRUE;
    gPaired        = TRUE;

    llOwnerSay("[SP] Grid info received. Origin=" + (string)gGridOrigin
        + " CellSize=" + (string)gCellSize + "m. Ready to spawn.");

    // Stop the retry timer — setup is complete
    llSetTimerEvent(0);

    if (gWaveQueued)
    {
        gWaveQueued = FALSE;
        llOwnerSay("[SP] Executing queued wave.");
        beginWave(gWaveTarget);
    }
}

handleGridInfoError(string msg)
{
    list parts = llParseString2List(msg, ["|"], []);
    llOwnerSay("[SP] Grid info error: " + llList2String(parts, 1) + ". Will retry.");
}


// =============================================================================
// WAVE AND SPAWN LOGIC
// =============================================================================

beginWave(integer enemy_count)
{
    gWaveTarget = enemy_count;
    if (gWaveTarget < 1) gWaveTarget = 1;
    gSpawnCount = 0;

    llOwnerSay("[SP] Wave started. Spawning " + (string)gWaveTarget + " enemy/enemies.");
    spawnEnemy();

    if (gWaveTarget > 1)
        llSetTimerEvent(SPAWN_INTERVAL);
}

handleWaveStart(string msg)
{
    list parts = llParseString2List(msg, ["|"], []);
    integer count = (integer)llList2String(parts, 1);

    if (!gGridInfoReady)
    {
        llOwnerSay("[SP] WAVE_START received before setup complete. Queuing.");
        gWaveQueued = TRUE;
        gWaveTarget = count;

        // Nudge the appropriate retry step
        if (!gRegistered)
            discoverGM();
        else if (gHandlerKey == NULL_KEY)
            queryHandler();
        else
            requestGridInfo();
        return;
    }

    beginWave(count);
}

spawnEnemy()
{
    if (llGetInventoryNumber(INVENTORY_OBJECT) == 0)
    {
        llOwnerSay("[SP] Error: no objects in inventory.");
        return;
    }
    if (llGetInventoryName(INVENTORY_OBJECT, 0) != ENEMY_OBJECT_NAME)
    {
        llOwnerSay("[SP] Error: expected '" + ENEMY_OBJECT_NAME + "', found '"
            + llGetInventoryName(INVENTORY_OBJECT, 0) + "'");
        return;
    }

    vector spawn_pos = llGetPos() + <0.0, 0.0, 0.5>;
    llRezObject(ENEMY_OBJECT_NAME, spawn_pos, ZERO_VECTOR, ZERO_ROTATION, 1);
    gSpawnCount++;
    llOwnerSay("[SP] Spawned enemy " + (string)gSpawnCount
        + " of " + (string)gWaveTarget);
}

handleEnemyReady(key sender)
{
    string waypoints = buildWaypointString();
    string config = "ENEMY_CONFIG"
        + "|" + (string)ENEMY_SPEED
        + "|" + (string)ENEMY_HEALTH
        + "|" + waypoints;
    llRegionSayTo(sender, ENEMY_CHANNEL, config);
    llOwnerSay("[SP] Sent config to enemy " + (string)sender);
}

handleHeartbeat(string msg)
{
    list parts = llParseString2List(msg, ["|"], []);
    if (llList2String(parts, 0) == "PING")
        llRegionSayTo(gGM_KEY, HEARTBEAT_CHANNEL, "ACK|" + llList2String(parts, 1));
}


// =============================================================================
// MAIN STATE
// =============================================================================

default
{
    state_entry()
    {
        llOwnerSay("[SP] Spawner starting up...");

        llListen(GM_DISCOVERY_CHANNEL, "", NULL_KEY, "");
        llListen(GM_REGISTER_CHANNEL,  "", NULL_KEY, "");
        llListen(HEARTBEAT_CHANNEL,    "", NULL_KEY, "");
        llListen(SPAWNER_CHANNEL,      "", NULL_KEY, "");
        llListen(ENEMY_CHANNEL,        "", NULL_KEY, "");
        llListen(GRID_INFO_CHANNEL,    "", NULL_KEY, "");

        discoverGM();
        llSetTimerEvent(RETRY_INTERVAL);
    }

    listen(integer channel, string name, key id, string msg)
    {
        if (channel == GM_DISCOVERY_CHANNEL)
        {
            list parts = llParseString2List(msg, ["|"], []);
            if (llList2String(parts, 0) == "GM_HERE" && gGM_KEY == NULL_KEY)
                handleGMHere((key)llList2String(parts, 1));
        }
        else if (channel == GM_REGISTER_CHANNEL && id == gGM_KEY)
        {
            handleRegisterResponse(msg);
        }
        else if (channel == HEARTBEAT_CHANNEL && id == gGM_KEY)
        {
            handleHeartbeat(msg);
        }
        else if (channel == SPAWNER_CHANNEL && id == gGM_KEY)
        {
            list parts = llParseString2List(msg, ["|"], []);
            string cmd = llList2String(parts, 0);
            if (cmd == "WAVE_START")
                handleWaveStart(msg);
            else if (cmd == "HANDLER_INFO")
                handleHandlerInfo(msg);
        }
        else if (channel == ENEMY_CHANNEL)
        {
            list parts = llParseString2List(msg, ["|"], []);
            if (llList2String(parts, 0) == "ENEMY_READY")
                handleEnemyReady(id);
        }
        else if (channel == GRID_INFO_CHANNEL)
        {
            list parts = llParseString2List(msg, ["|"], []);
            string cmd = llList2String(parts, 0);
            if (cmd == "GRID_INFO")
                handleGridInfo(msg);
            else if (cmd == "GRID_INFO_ERROR")
                handleGridInfoError(msg);
        }
    }

    timer()
    {
        // This timer only runs during the setup sequence.
        // Once grid info is confirmed it is stopped.
        // During wave spawning it is restarted with SPAWN_INTERVAL.

        if (!gRegistered)
        {
            if (gDiscovering || gGM_KEY == NULL_KEY)
                discoverGM();
            else
                handleGMHere(gGM_KEY);
            return;
        }

        if (gHandlerKey == NULL_KEY)
        {
            queryHandler();
            return;
        }

        if (!gGridInfoReady)
        {
            requestGridInfo();
            return;
        }

        // Grid info is ready — this is the wave spawn interval tick
        if (gSpawnCount < gWaveTarget)
        {
            spawnEnemy();
            if (gSpawnCount >= gWaveTarget)
                llSetTimerEvent(0);
        }
    }

    on_rez(integer start_param)
    {
        llResetScript();
    }
}
