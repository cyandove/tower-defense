// =============================================================================
// spawner.lsl
// Tower Defense Enemy Spawner — Phase 6
// =============================================================================
// PHASE 6 CHANGES:
//   - Enemy stats (health, speed, enemies_per_wave, spawn_interval) now loaded
//     from a notecard instead of hardcoded constants
//   - Notecard name: SPAWNER_NOTECARD (default "spawner.cfg")
//   - Notecard format: key=value per line, # for comments, blank lines ignored
//   - Supported keys: enemy_health, enemy_speed, enemies_per_wave,
//     spawn_interval, enemy_type_name
//   - Notecard loaded first; GM discovery begins after load completes
//   - If notecard missing or unreadable, hardcoded defaults are used
//
// NOTECARD SETUP (spawner.cfg):
//   # Basic enemy config
//   enemy_type_name=Basic Enemy
//   enemy_health=100.0
//   enemy_speed=2.0
//   enemies_per_wave=5
//   spawn_interval=3.0
//
// SETUP:
//   1. Place the spawner prim at the path entrance in-world
//   2. Add this script and a "spawner.cfg" notecard to the prim
//   3. Add the enemy prim to the spawner's inventory, named "Enemy"
//   4. Confirm registration via /td dump registry
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
// FIXED CONFIGURATION (not notecard-driven)
// -----------------------------------------------------------------------------
string  ENEMY_OBJECT_NAME = "Enemy";
string  SPAWNER_NOTECARD  = "spawner.cfg";
integer SPAWNER_GRID_X    = 2;
integer SPAWNER_GRID_Y    = 0;
integer RETRY_INTERVAL    = 5;
integer REG_TYPE_SPAWNER  = 3;

// Waypoint path — must stay in sync with initMap() in game_manager.lsl
list WAYPOINT_GRID = [
    2, 0,   2, 1,   2, 2,   2, 3,   2, 4,
    3, 4,   4, 4,   5, 4,   6, 4,   7, 4,
    7, 5,   7, 6,   7, 7,
    6, 7,   5, 7,   4, 7,   3, 7,   2, 7,
    2, 8,   2, 9
];


// -----------------------------------------------------------------------------
// ENEMY STATS — populated from notecard, defaults used if key missing
// -----------------------------------------------------------------------------
string  gEnemyTypeName   = "Basic Enemy";
float   gEnemyHealth     = 100.0;
float   gEnemySpeed      = 2.0;
integer gEnemiesPerWave  = 1;
float   gSpawnInterval   = 3.0;


// -----------------------------------------------------------------------------
// NOTECARD LOADING STATE
// -----------------------------------------------------------------------------
key     gNotecardQuery = NULL_KEY;
integer gCurrentLine   = 0;
integer gConfigLoaded  = FALSE;


// -----------------------------------------------------------------------------
// RUNTIME STATE
// -----------------------------------------------------------------------------
key     gGM_KEY        = NULL_KEY;
key     gHandlerKey    = NULL_KEY;
integer gRegistered    = FALSE;
integer gPaired        = FALSE;
integer gGridInfoReady = FALSE;
integer gDiscovering   = FALSE;
integer gWaveQueued    = FALSE;
integer gWaveTarget    = 0;
integer gSpawnCount    = 0;

vector  gGridOrigin    = ZERO_VECTOR;
float   gCellSize      = 2.0;
float   gGroundZ       = 0.0;


// =============================================================================
// NOTECARD LOADING
// =============================================================================

startNotecardLoad()
{
    if (llGetInventoryType(SPAWNER_NOTECARD) == INVENTORY_NONE)
    {
        llOwnerSay("[SP] No notecard '" + SPAWNER_NOTECARD + "' — using defaults.");
        gConfigLoaded = TRUE;
        afterConfigLoaded();
        return;
    }

    llOwnerSay("[SP] Loading config from '" + SPAWNER_NOTECARD + "'...");
    gCurrentLine   = 0;
    gNotecardQuery = llGetNotecardLine(SPAWNER_NOTECARD, gCurrentLine);
}

integer parseConfigLine(string line)
{
    if (line == "" || llGetSubString(line, 0, 0) == "#") return FALSE;

    integer eq = llSubStringIndex(line, "=");
    if (eq == -1) return FALSE;

    string k = llToLower(llGetSubString(line, 0, eq - 1));
    string v = llGetSubString(line, eq + 1, -1);

    if      (k == "enemy_type_name")  gEnemyTypeName  = v;
    else if (k == "enemy_health")     gEnemyHealth     = (float)v;
    else if (k == "enemy_speed")      gEnemySpeed      = (float)v;
    else if (k == "enemies_per_wave") gEnemiesPerWave  = (integer)v;
    else if (k == "spawn_interval")   gSpawnInterval   = (float)v;
    else
    {
        llOwnerSay("[SP] Unknown config key: " + k);
        return FALSE;
    }
    return TRUE;
}

afterConfigLoaded()
{
    llOwnerSay("[SP] Config loaded: " + gEnemyTypeName
        + " hp=" + (string)gEnemyHealth
        + " spd=" + (string)gEnemySpeed
        + " count=" + (string)gEnemiesPerWave
        + " interval=" + (string)gSpawnInterval + "s");

    discoverGM();
    llSetTimerEvent(RETRY_INTERVAL);
}


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
        if (result != "") result += ";";
        result += (string)wp.x + ":" + (string)wp.y + ":" + (string)wp.z;
    }
    return result;
}


// =============================================================================
// STARTUP SEQUENCE
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

queryHandler()
{
    llRegionSayTo(gGM_KEY, SPAWNER_CHANNEL, "HANDLER_QUERY");
    llOwnerSay("[SP] Sent HANDLER_QUERY to GM.");
}

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

    llRegionSayTo(gGM_KEY, SPAWNER_CHANNEL,
        "SPAWNER_PAIRED|" + (string)gHandlerKey);

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
    gCellSize      = (float)llList2String(parts, 4);
    gGroundZ       = gGridOrigin.z;
    gGridInfoReady = TRUE;
    gPaired        = TRUE;

    llOwnerSay("[SP] Grid info received. Origin=" + (string)gGridOrigin
        + " CellSize=" + (string)gCellSize + "m. Ready to spawn.");

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

    llOwnerSay("[SP] Wave started. Spawning "
        + (string)gWaveTarget + " " + gEnemyTypeName + "(s).");
    spawnEnemy();

    if (gWaveTarget > 1)
        llSetTimerEvent(gSpawnInterval);
}

handleWaveStart(string msg)
{
    list parts = llParseString2List(msg, ["|"], []);

    // WAVE_START can carry a count override; if not, use notecard value
    integer count = (integer)llList2String(parts, 1);
    if (count < 1) count = gEnemiesPerWave;

    if (!gGridInfoReady)
    {
        llOwnerSay("[SP] WAVE_START received before setup complete. Queuing.");
        gWaveQueued = TRUE;
        gWaveTarget = count;

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
        + "|" + (string)gEnemySpeed
        + "|" + (string)gEnemyHealth
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

        // Notecard loads first — afterConfigLoaded() triggers GM discovery
        startNotecardLoad();
    }

    dataserver(key query_id, string data)
    {
        if (query_id != gNotecardQuery) return;

        if (data == EOF)
        {
            gConfigLoaded = TRUE;
            afterConfigLoaded();
            return;
        }

        parseConfigLine(data);
        gCurrentLine++;
        gNotecardQuery = llGetNotecardLine(SPAWNER_NOTECARD, gCurrentLine);
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
            if      (cmd == "WAVE_START")    handleWaveStart(msg);
            else if (cmd == "HANDLER_INFO")  handleHandlerInfo(msg);
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
            if      (cmd == "GRID_INFO")       handleGridInfo(msg);
            else if (cmd == "GRID_INFO_ERROR") handleGridInfoError(msg);
        }
    }

    timer()
    {
        if (!gConfigLoaded) return;

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

        // Wave spawn interval tick
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
