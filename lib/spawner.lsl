// =============================================================================
// spawner.lsl
// Tower Defense Enemy Spawner  -  Phase 7
// =============================================================================
// PHASE 7 CHANGES:
//   - Removed hardcoded SPAWNER_GRID_X/Y and WAYPOINT_GRID constants.
//     These are now received from the controller in a SPAWNER_CONFIG message
//     on CONTROLLER_CHANNEL (-2013) after the spawner registers with the GM.
//   - Removed grid-info request/response sequence (GRID_INFO_CHANNEL flow).
//     The controller sends waypoints as world-space coordinates directly,
//     so the spawner no longer needs to fetch grid geometry from the handler.
//   - Added gConfigured flag; wave execution blocked until config received.
//   - Added SPAWNER_CONFIG handler: parses entry cell coords and waypoint string.
//   - Sends SPAWNER_CONFIG_OK to controller after successful config parse.
//   - Startup sequence simplified:
//       1. Load notecard (enemy stats)
//       2. Discover GM and register
//       3. Query for handler and confirm pairing (unchanged)
//       4. Wait for SPAWNER_CONFIG from controller
//       5. On receipt: mark ready, execute any queued wave
//   - Removed gGridInfoReady (replaced by gConfigured).
//   - Removed gGridOrigin, gCellSize, gGroundZ globals (no longer needed).
//   - buildWaypointString() removed  -  waypoint string arrives pre-built.
//   - gWaypointString stores the received waypoint string verbatim.
//   - Spawn position is now llGetPos() + z offset (controller placed us correctly).
//   - CONTROLLER_CHANNEL = -2013 added to listen list.
//   - Removed GRID_INFO_CHANNEL (-2011) from listen list.
//   - Timer retry logic simplified: only retries GM discovery and handler query;
//     config wait has no retry (controller sends it once on setup).
//
// NOTECARD (spawner.cfg)  -  unchanged from Phase 6:
//   enemy_type_name=Basic Enemy
//   enemy_health=100.0
//   enemy_speed=2.0
//   enemies_per_wave=5
//   spawn_interval=3.0
// =============================================================================


// -----------------------------------------------------------------------------
// CHANNEL CONSTANTS  -  must match game_manager.lsl
// -----------------------------------------------------------------------------
integer GM_REGISTER_CHANNEL   = -2001;
integer GM_DEREGISTER_CHANNEL = -2002;
integer HEARTBEAT_CHANNEL     = -2003;
integer GM_DISCOVERY_CHANNEL  = -2007;
integer SPAWNER_CHANNEL       = -2009;
integer ENEMY_CHANNEL         = -2010;
integer CONTROLLER_CHANNEL    = -2013;


// -----------------------------------------------------------------------------
// FIXED CONFIGURATION
// -----------------------------------------------------------------------------
string  ENEMY_OBJECT_NAME = "Enemy";
string  SPAWNER_NOTECARD  = "spawner.cfg";
integer RETRY_INTERVAL    = 5;


// -----------------------------------------------------------------------------
// ENEMY STATS  -  populated from notecard, defaults used if key missing
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
key     gGM_KEY          = NULL_KEY;
key     gHandlerKey      = NULL_KEY;
integer gRegistered      = FALSE;
integer gPaired          = FALSE;
integer gConfigured      = FALSE;   // TRUE once SPAWNER_CONFIG received
integer gDiscovering     = FALSE;
integer gWaveQueued      = FALSE;
integer gWaveTarget      = 0;
integer gSpawnCount      = 0;

// Waypoint string received from controller: "x1:y1:z1;x2:y2:z2;..."
string  gWaypointString  = "";

// Entry cell grid coords  -  received from controller, used for registration
integer gGridX           = 0;
integer gGridY           = 0;


// =============================================================================
// NOTECARD LOADING
// =============================================================================

startNotecardLoad()
{
    if (llGetInventoryType(SPAWNER_NOTECARD) == INVENTORY_NONE)
    {
        llOwnerSay("[SP] No notecard '" + SPAWNER_NOTECARD + "'  -  using defaults.");
        gConfigLoaded = TRUE;
        afterConfigLoaded();
        return;
    }
    llOwnerSay("[SP] Loading '" + SPAWNER_NOTECARD + "'...");
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
    else { llOwnerSay("[SP] Unknown config key: " + k); return FALSE; }
    return TRUE;
}

afterConfigLoaded()
{
    llOwnerSay("[SP] Config: " + gEnemyTypeName
        + " hp=" + (string)gEnemyHealth
        + " spd=" + (string)gEnemySpeed
        + " count=" + (string)gEnemiesPerWave
        + " interval=" + (string)gSpawnInterval + "s");
    discoverGM();
    llSetTimerEvent(RETRY_INTERVAL);
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
    // Grid coords not yet known  -  will be sent in SPAWNER_CONFIG.
    // Register with (0,0) placeholder; controller sends real coords.
    llRegionSayTo(gGM_KEY, GM_REGISTER_CHANNEL,
        "REGISTER|3|0|0");
}

handleRegisterResponse(string msg)
{
    list parts = llParseString2List(msg, ["|"], []);
    string cmd = llList2String(parts, 0);
    if (cmd == "REGISTER_OK")
    {
        gRegistered = TRUE;
        llOwnerSay("[SP] Registered. Querying handler...");
        llRegionSayTo(gGM_KEY, SPAWNER_CHANNEL, "SPAWNER_READY");
        queryHandler();
    }
    else if (cmd == "REGISTER_REJECTED")
        llOwnerSay("[SP] Registration rejected: " + llList2String(parts, 1));
}

queryHandler()
{
    llRegionSayTo(gGM_KEY, SPAWNER_CHANNEL, "HANDLER_QUERY");
}

handleHandlerInfo(string msg)
{
    list parts      = llParseString2List(msg, ["|"], []);
    key handler_key = (key)llList2String(parts, 1);

    if (handler_key == NULL_KEY)
    { llOwnerSay("[SP] No handler yet. Will retry."); return; }

    gHandlerKey = handler_key;
    llOwnerSay("[SP] Handler: " + (string)gHandlerKey);
    llRegionSayTo(gGM_KEY, SPAWNER_CHANNEL,
        "SPAWNER_PAIRED|" + (string)gHandlerKey);
    // Don't set gPaired yet  -  wait for SPAWNER_CONFIG from controller
    llOwnerSay("[SP] Waiting for controller config...");
}


// =============================================================================
// CONTROLLER CONFIG
// SPAWNER_CONFIG|<entry_x>|<entry_y>|<wp_string>
// Sent by controller after all objects have registered.
// =============================================================================

handleSpawnerConfig(key sender, string msg)
{
    list parts = llParseString2List(msg, ["|"], []);
    if (llGetListLength(parts) < 7) return;

    gGridX          = (integer)llList2String(parts, 1);
    gGridY          = (integer)llList2String(parts, 2);
    gWaypointString = llList2String(parts, 3);

    // Move to designated position (no 10m limit with llSetRegionPos)
    vector target = <(float)llList2String(parts, 4),
                     (float)llList2String(parts, 5),
                     (float)llList2String(parts, 6)>;
    llSetRegionPos(target);

    gConfigured     = TRUE;
    gPaired         = TRUE;

    llOwnerSay("[SP] Config received. Entry=("
        + (string)gGridX + "," + (string)gGridY + ")"
        + " Waypoints=" + (string)llGetListLength(
            llParseString2List(gWaypointString, [";"], [])) + " pts");

    // Acknowledge so controller knows we're ready
    llRegionSayTo(sender, CONTROLLER_CHANNEL, "SPAWNER_CONFIG_OK");

    // Stop retry timer now that we're fully configured
    llSetTimerEvent(0);

    if (gWaveQueued)
    {
        gWaveQueued = FALSE;
        llOwnerSay("[SP] Executing queued wave.");
        beginWave(gWaveTarget);
    }
}


// =============================================================================
// WAVE AND SPAWN LOGIC
// =============================================================================

beginWave(integer enemy_count)
{
    gWaveTarget = enemy_count;
    if (gWaveTarget < 1) gWaveTarget = 1;
    gSpawnCount = 0;
    llOwnerSay("[SP] Wave: spawning "
        + (string)gWaveTarget + " " + gEnemyTypeName + "(s).");
    spawnEnemy();
    if (gWaveTarget > 1)
        llSetTimerEvent(gSpawnInterval);
}

handleWaveStart(string msg)
{
    list    parts = llParseString2List(msg, ["|"], []);
    integer count = (integer)llList2String(parts, 1);
    if (count < 1) count = gEnemiesPerWave;

    if (!gConfigured)
    {
        llOwnerSay("[SP] WAVE_START before config  -  queuing.");
        gWaveQueued = TRUE;
        gWaveTarget = count;
        return;
    }
    beginWave(count);
}

spawnEnemy()
{
    if (llGetInventoryType(ENEMY_OBJECT_NAME) == INVENTORY_NONE)
    {
        llOwnerSay("[SP] '" + ENEMY_OBJECT_NAME + "' not in inventory.");
        return;
    }
    vector spawn_pos = llGetPos() + <0.0, 0.0, 0.5>;
    llRezObject(ENEMY_OBJECT_NAME, spawn_pos, ZERO_VECTOR, ZERO_ROTATION, 1);
    gSpawnCount++;
    llOwnerSay("[SP] Spawned " + (string)gSpawnCount
        + "/" + (string)gWaveTarget);
}

handleEnemyReady(key sender)
{
    string config = "ENEMY_CONFIG"
        + "|" + (string)gEnemySpeed
        + "|" + (string)gEnemyHealth
        + "|" + gWaypointString;
    llRegionSayTo(sender, ENEMY_CHANNEL, config);
}

handleHeartbeat(string msg)
{
    list parts = llParseString2List(msg, ["|"], []);
    if (llList2String(parts, 0) == "PING")
        llRegionSayTo(gGM_KEY, HEARTBEAT_CHANNEL,
            "ACK|" + llList2String(parts, 1));
}


// =============================================================================
// MAIN STATE
// =============================================================================

default
{
    state_entry()
    {
        llOwnerSay("[SP] Spawner starting...");

        llListen(GM_DISCOVERY_CHANNEL, "", NULL_KEY, "");
        llListen(GM_REGISTER_CHANNEL,  "", NULL_KEY, "");
        llListen(HEARTBEAT_CHANNEL,    "", NULL_KEY, "");
        llListen(SPAWNER_CHANNEL,      "", NULL_KEY, "");
        llListen(ENEMY_CHANNEL,        "", NULL_KEY, "");
        llListen(CONTROLLER_CHANNEL,   "", NULL_KEY, "");

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
            if      (cmd == "WAVE_START")   handleWaveStart(msg);
            else if (cmd == "HANDLER_INFO") handleHandlerInfo(msg);
        }
        else if (channel == ENEMY_CHANNEL)
        {
            list parts = llParseString2List(msg, ["|"], []);
            if (llList2String(parts, 0) == "ENEMY_READY")
                handleEnemyReady(id);
        }
        else if (channel == CONTROLLER_CHANNEL)
        {
            list parts = llParseString2List(msg, ["|"], []);
            string cmd = llList2String(parts, 0);
            if      (cmd == "SPAWNER_CONFIG") handleSpawnerConfig(id, msg);
            else if (cmd == "WAVE_START")    handleWaveStart(msg);
            else if (cmd == "SHUTDOWN")
            {
                llOwnerSay("[SP] Shutdown.");
                llRegionSayTo(gGM_KEY, GM_DEREGISTER_CHANNEL, "DEREGISTER");
                llDie();
            }
        }
    }

    timer()
    {
        if (!gConfigLoaded) return;

        // Retry GM discovery / handler query until configured
        if (!gConfigured)
        {
            if (!gRegistered)
            {
                if (gDiscovering || gGM_KEY == NULL_KEY) discoverGM();
                else handleGMHere(gGM_KEY);
                return;
            }
            if (gHandlerKey == NULL_KEY)
            {
                queryHandler();
                return;
            }
            // Registered and paired but no config yet  -  just wait
            return;
        }

        // Configured  -  timer used only for wave spawn interval
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
