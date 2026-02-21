// =============================================================================
// spawner.lsl
// Tower Defense Enemy Spawner — Phase 4
//
// Place this prim at the entrance of the enemy path (grid cell 2,0 in the
// default map). It registers with the GM, waits for WAVE_START, then rezzes
// enemies from its inventory at a configurable interval.
//
// SETUP:
//   1. Place the spawner prim at the path entrance in-world
//   2. Add this script
//   3. Add the enemy prim (with enemy_base.lsl inside) to the spawner's inventory
//   4. The enemy prim in inventory must be named exactly ENEMY_OBJECT_NAME below
//   5. Confirm the spawner registers with the GM via /td dump registry
//   6. Type /td wave start to trigger a test spawn
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


// -----------------------------------------------------------------------------
// CONFIGURATION
// -----------------------------------------------------------------------------

// Name of the enemy object in this prim's inventory.
// Must match exactly, including capitalisation.
string ENEMY_OBJECT_NAME = "Enemy";

// Grid position of this spawner (path entrance cell).
// Used for registration with the GM only — not for movement.
integer SPAWNER_GRID_X = 2;
integer SPAWNER_GRID_Y = 0;

// How many seconds between each enemy spawn during a wave.
float SPAWN_INTERVAL = 3.0;

// How many enemies to spawn per wave.
// Phase 4: keep this at 1 for initial testing, increase once movement works.
integer ENEMIES_PER_WAVE = 1;

// Enemy config sent to each enemy after it rezzes.
// Format matches what enemy_base.lsl expects in its ENEMY_CONFIG message.
// Speed is in meters per second. Health is stubbed for phase 4.
float ENEMY_SPEED  = 2.0;
float ENEMY_HEALTH = 100.0;

// Waypoint list in grid coordinates, matching the path defined in initMap().
// Each pair is <grid_x, grid_y>. The enemy converts these to world positions
// using GRID_ORIGIN and CELL_SIZE below.
// This must stay in sync with the path cells in game_manager.lsl initMap().
list WAYPOINT_GRID = [
    2, 0,
    2, 1,
    2, 2,
    2, 3,
    2, 4,
    3, 4,
    4, 4,
    5, 4,
    6, 4,
    7, 4,
    7, 5,
    7, 6,
    7, 7,
    6, 7,
    5, 7,
    4, 7,
    3, 7,
    2, 7,
    2, 8,
    2, 9
];

// Grid-to-world conversion constants.
// Set GRID_ORIGIN to the region XY of your grid's (0,0) corner.
// CELL_SIZE must match the placement handler prim's derived cell size.
// GROUND_Z is the Z position enemies walk at.
vector GRID_ORIGIN = <128.0, 128.0, 22.0>;
float  CELL_SIZE   = 2.0;
float  GROUND_Z    = 22.0;


// -----------------------------------------------------------------------------
// DISCOVERY AND REGISTRATION CONSTANTS
// -----------------------------------------------------------------------------
integer DISCOVERY_RETRY_INTERVAL = 5;
integer REG_TYPE_SPAWNER = 3;


// -----------------------------------------------------------------------------
// GLOBAL STATE
// -----------------------------------------------------------------------------
key     gGM_KEY       = NULL_KEY;
integer gRegistered   = FALSE;
integer gDiscovering  = FALSE;
integer gSpawnCount   = 0;    // enemies spawned in current wave
integer gWaveTarget   = 0;    // total enemies to spawn this wave


// =============================================================================
// GRID-TO-WORLD CONVERSION
// =============================================================================

// Converts a grid coordinate pair to the center of that cell in world space.
vector gridToWorld(integer gx, integer gy)
{
    return <GRID_ORIGIN.x + (gx + 0.5) * CELL_SIZE,
            GRID_ORIGIN.y + (gy + 0.5) * CELL_SIZE,
            GROUND_Z>;
}

// Builds a pipe-delimited string of world-space waypoint vectors from
// WAYPOINT_GRID. Sent to each enemy as part of its config message.
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
        // Encode vector as x:y:z to avoid pipe/comma conflicts
        result += (string)wp.x + ":" + (string)wp.y + ":" + (string)wp.z;
    }
    return result;
}


// =============================================================================
// GM DISCOVERY AND REGISTRATION
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
        llSetTimerEvent(0);
        llOwnerSay("[SP] Registered with GM.");
        // Notify GM the spawner is ready to receive wave commands
        llRegionSayTo(gGM_KEY, SPAWNER_CHANNEL, "SPAWNER_READY");
    }
    else if (cmd == "REGISTER_REJECTED")
    {
        gRegistered = FALSE;
        llOwnerSay("[SP] Registration rejected: " + llList2String(parts, 1));
        llSetTimerEvent(0);
    }
}

handleHeartbeat(string msg)
{
    list parts = llParseString2List(msg, ["|"], []);
    if (llList2String(parts, 0) == "PING")
        llRegionSayTo(gGM_KEY, HEARTBEAT_CHANNEL, "ACK|" + llList2String(parts, 1));
}


// =============================================================================
// WAVE AND SPAWN LOGIC
// =============================================================================

// Rezzes one enemy at the spawn position and sends it a config message.
// The enemy is rezzed with start_param = 1 to wake it from its dormant state.
spawnEnemy()
{
    if (llGetInventoryNumber(INVENTORY_OBJECT) == 0)
    {
        llOwnerSay("[SP] Error: no objects in inventory to spawn.");
        return;
    }
    if (llGetInventoryName(INVENTORY_OBJECT, 0) != ENEMY_OBJECT_NAME)
    {
        llOwnerSay("[SP] Error: inventory object name mismatch. Expected '"
            + ENEMY_OBJECT_NAME + "', found '"
            + llGetInventoryName(INVENTORY_OBJECT, 0) + "'");
        return;
    }

    // Rez at the spawner's position with a small upward offset to avoid
    // intersecting the ground plane
    vector spawn_pos = llGetPos() + <0.0, 0.0, 0.5>;

    // start_param = 1 wakes the enemy from its dormant default state
    llRezObject(ENEMY_OBJECT_NAME, spawn_pos, ZERO_VECTOR, ZERO_ROTATION, 1);

    gSpawnCount++;
    llOwnerSay("[SP] Spawned enemy " + (string)gSpawnCount
        + " of " + (string)gWaveTarget);
}

// Handles WAVE_START from the GM.
// Message format: WAVE_START|<enemy_count>
handleWaveStart(string msg)
{
    list parts = llParseString2List(msg, ["|"], []);
    gWaveTarget = (integer)llList2String(parts, 1);
    if (gWaveTarget < 1) gWaveTarget = 1;
    gSpawnCount = 0;

    llOwnerSay("[SP] Wave started. Spawning " + (string)gWaveTarget + " enemy/enemies.");
    spawnEnemy();

    // If more than one enemy, set a timer to spawn the rest at intervals
    if (gWaveTarget > 1)
        llSetTimerEvent(SPAWN_INTERVAL);
}

// Called when a rezzed enemy sends back its key on ENEMY_CHANNEL.
// The spawner sends the enemy its full config including waypoints.
// Message format: ENEMY_READY|<enemy_key>
handleEnemyReady(key sender, string msg)
{
    list parts = llParseString2List(msg, ["|"], []);
    if (llList2String(parts, 0) != "ENEMY_READY") return;

    string waypoints = buildWaypointString();
    string config = "ENEMY_CONFIG"
        + "|" + (string)ENEMY_SPEED
        + "|" + (string)ENEMY_HEALTH
        + "|" + waypoints;

    llRegionSayTo(sender, ENEMY_CHANNEL, config);
    llOwnerSay("[SP] Sent config to enemy " + (string)sender);
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

        discoverGM();
        llSetTimerEvent(DISCOVERY_RETRY_INTERVAL);
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
            if (llList2String(parts, 0) == "WAVE_START")
                handleWaveStart(msg);
        }
        else if (channel == ENEMY_CHANNEL)
        {
            handleEnemyReady(id, msg);
        }
    }

    timer()
    {
        if (!gRegistered)
        {
            // Still in discovery/registration phase
            if (gDiscovering)
                discoverGM();
            else if (gGM_KEY != NULL_KEY)
                handleGMHere(gGM_KEY);
            return;
        }

        // Wave spawn timer — rez next enemy at interval
        if (gSpawnCount < gWaveTarget)
        {
            spawnEnemy();
            if (gSpawnCount >= gWaveTarget)
                llSetTimerEvent(0);  // all enemies spawned, stop timer
        }
    }

    on_rez(integer start_param)
    {
        llResetScript();
    }
}
