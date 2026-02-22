// =============================================================================
// tower_basic.lsl
// Tower Defense — Basic Tower, Phase 6
// =============================================================================
// PHASE 6 CHANGES:
//   - Notecard config loaded before GM discovery and registration
//   - start_param encodes tower type ID, which maps to a notecard name
//   - All tuning constants (damage, range, accuracy, etc.) are now globals
//     populated from the notecard — no recompile needed to change tower stats
//   - Added loading state: tower idles until notecard is fully parsed
//   - Notecard format: key=value per line, # for comments, blank lines ignored
//   - Supported keys: damage, range, accuracy, falloff, attack_interval,
//     targeting_strategy, tower_type_name
//
// NOTECARD SETUP:
//   Create a notecard in the tower prim's inventory named to match the entry
//   in NOTECARD_NAMES below for the tower's type ID. Example:
//
//   Notecard name: "tower_basic.cfg"
//   Contents:
//     # Basic Tower config
//     tower_type_name=Basic Tower
//     damage=25.0
//     range=10.0
//     accuracy=0.85
//     falloff=0.4
//     attack_interval=2.0
//     targeting_strategy=0
//
// STARTUP SEQUENCE:
//   1. Load notecard (type ID from start_param → notecard name)
//   2. Discover GM
//   3. Query GM for placement handler key (HANDLER_QUERY)
//   4. Request grid info from handler via GM (GRID_INFO_REQUEST)
//   5. Derive grid coords from world position
//   6. Register with GM
//   7. Begin attack cycle
// =============================================================================


// -----------------------------------------------------------------------------
// CHANNEL CONSTANTS — must match game_manager.lsl
// -----------------------------------------------------------------------------
integer GM_REGISTER_CHANNEL   = -2001;
integer GM_DEREGISTER_CHANNEL = -2002;
integer HEARTBEAT_CHANNEL     = -2003;
integer TOWER_REPORT_CHANNEL  = -2005;
integer GM_DISCOVERY_CHANNEL  = -2007;
integer SPAWNER_CHANNEL       = -2009;
integer ENEMY_CHANNEL         = -2010;
integer GRID_INFO_CHANNEL     = -2011;


// -----------------------------------------------------------------------------
// TOWER TYPE → NOTECARD NAME MAP
// Index corresponds to type_id - 1 (type_id is 1-based).
// Add an entry here whenever a new tower type is added to the GM's type registry.
// -----------------------------------------------------------------------------
list NOTECARD_NAMES = ["tower_basic.cfg", "tower_sniper.cfg"];

integer REG_TYPE_TOWER   = 1;
integer RETRY_INTERVAL   = 5;
integer LOAD_RETRY_DELAY = 2;   // seconds between notecard line requests on error


// -----------------------------------------------------------------------------
// TOWER STATS — populated from notecard, defaults used if key missing
// -----------------------------------------------------------------------------
string  gTowerTypeName      = "Tower";
float   gDamage             = 25.0;
float   gTowerRange         = 10.0;
float   gAccuracy           = 0.85;
float   gFalloff            = 0.4;
float   gAttackInterval     = 2.0;
integer gTargetingStrategy  = 0;


// -----------------------------------------------------------------------------
// GLOBAL STATE
// -----------------------------------------------------------------------------
key     gGM_KEY        = NULL_KEY;
key     gHandlerKey    = NULL_KEY;
integer gRegistered    = FALSE;
integer gDiscovering   = FALSE;
integer gGridInfoReady = FALSE;
vector  gTowerPos      = ZERO_VECTOR;

vector  gGridOrigin    = ZERO_VECTOR;
float   gGridCellSize  = 2.0;
integer gGridX         = 0;
integer gGridY         = 0;

// Notecard loading state
integer gTowerTypeId   = 1;       // set from start_param on rez
string  gNotecardName  = "";
key     gNotecardQuery = NULL_KEY;
integer gCurrentLine   = 0;
integer gConfigLoaded  = FALSE;


// =============================================================================
// NOTECARD LOADING
// =============================================================================

// Maps a type_id to a notecard name. Returns "" if type_id is out of range.
string notecardForType(integer type_id)
{
    integer idx = type_id - 1;   // convert to 0-based
    if (idx < 0 || idx >= llGetListLength(NOTECARD_NAMES))
        return "";
    return llList2String(NOTECARD_NAMES, idx);
}

startNotecardLoad()
{
    gNotecardName = notecardForType(gTowerTypeId);

    if (gNotecardName == "")
    {
        llOwnerSay("[TW] No notecard defined for type " + (string)gTowerTypeId
            + ". Using defaults.");
        gConfigLoaded = TRUE;
        afterConfigLoaded();
        return;
    }

    if (llGetInventoryType(gNotecardName) == INVENTORY_NONE)
    {
        llOwnerSay("[TW] Notecard '" + gNotecardName + "' not found. Using defaults.");
        gConfigLoaded = TRUE;
        afterConfigLoaded();
        return;
    }

    llOwnerSay("[TW] Loading config from '" + gNotecardName + "'...");
    gCurrentLine   = 0;
    gNotecardQuery = llGetNotecardLine(gNotecardName, gCurrentLine);
}

// Parses a single notecard line and updates the appropriate global.
// Returns TRUE if the line contained a recognised key.
integer parseConfigLine(string line)
{
    // Strip leading/trailing whitespace (LSL has no trim — approximate with split)
    if (line == "" || llGetSubString(line, 0, 0) == "#")
        return FALSE;

    integer eq = llSubStringIndex(line, "=");
    if (eq == -1) return FALSE;

    string k = llToLower(llGetSubString(line, 0, eq - 1));
    string v = llGetSubString(line, eq + 1, -1);

    if      (k == "tower_type_name")    gTowerTypeName     = v;
    else if (k == "damage")             gDamage            = (float)v;
    else if (k == "range")              gTowerRange        = (float)v;
    else if (k == "accuracy")           gAccuracy          = (float)v;
    else if (k == "falloff")            gFalloff           = (float)v;
    else if (k == "attack_interval")    gAttackInterval    = (float)v;
    else if (k == "targeting_strategy") gTargetingStrategy = (integer)v;
    else
    {
        llOwnerSay("[TW] Unknown config key: " + k);
        return FALSE;
    }
    return TRUE;
}

afterConfigLoaded()
{
    llOwnerSay("[TW] Config loaded: " + gTowerTypeName
        + " dmg=" + (string)gDamage
        + " range=" + (string)gTowerRange
        + " acc=" + (string)gAccuracy
        + " interval=" + (string)gAttackInterval);

    // Proceed with startup sequence
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
    llOwnerSay("[TW] Broadcasting GM_DISCOVER...");
}

handleGMHere(key gm_key)
{
    gGM_KEY      = gm_key;
    gDiscovering = FALSE;
    gTowerPos    = llGetPos();
    llOwnerSay("[TW] Found GM: " + (string)gGM_KEY);
    queryHandler();
}

queryHandler()
{
    llRegionSayTo(gGM_KEY, SPAWNER_CHANNEL, "HANDLER_QUERY");
    llOwnerSay("[TW] Sent HANDLER_QUERY.");
}

handleHandlerInfo(string msg)
{
    list parts = llParseString2List(msg, ["|"], []);
    key handler_key = (key)llList2String(parts, 1);

    if (handler_key == NULL_KEY)
    {
        llOwnerSay("[TW] No handler registered yet. Will retry.");
        return;
    }

    gHandlerKey = handler_key;
    llOwnerSay("[TW] Handler: " + (string)gHandlerKey + ". Requesting grid info...");
    requestGridInfo();
}

requestGridInfo()
{
    llRegionSayTo(gGM_KEY, GRID_INFO_CHANNEL,
        "GRID_INFO_REQUEST|" + (string)llGetKey()
        + "|" + (string)gHandlerKey);
}

handleGridInfo(string msg)
{
    list parts = llParseString2List(msg, ["|"], []);
    if (llGetListLength(parts) < 5) return;

    gGridOrigin = <(float)llList2String(parts, 1),
                   (float)llList2String(parts, 2),
                   (float)llList2String(parts, 3)>;
    gGridCellSize  = (float)llList2String(parts, 4);
    gGridInfoReady = TRUE;

    gTowerPos = llGetPos();
    gGridX    = (integer)((gTowerPos.x - gGridOrigin.x) / gGridCellSize);
    gGridY    = (integer)((gTowerPos.y - gGridOrigin.y) / gGridCellSize);

    llOwnerSay("[TW] Grid position: (" + (string)gGridX + "," + (string)gGridY + ").");

    llRegionSayTo(gGM_KEY, GM_REGISTER_CHANNEL,
        "REGISTER|" + (string)REG_TYPE_TOWER
        + "|" + (string)gGridX
        + "|" + (string)gGridY);
}

handleRegisterResponse(string msg)
{
    list parts = llParseString2List(msg, ["|"], []);
    string cmd = llList2String(parts, 0);
    if (cmd == "REGISTER_OK")
    {
        gRegistered = TRUE;
        llSetTimerEvent(0);
        llOwnerSay("[TW] Registered: " + gTowerTypeName
            + " at (" + (string)gGridX + "," + (string)gGridY + ")"
            + " range=" + (string)gTowerRange + "m"
            + " interval=" + (string)gAttackInterval + "s");
        llSetTimerEvent(gAttackInterval);
    }
    else if (cmd == "REGISTER_REJECTED")
    {
        llOwnerSay("[TW] Registration rejected: " + llList2String(parts, 1));
    }
}

handleHeartbeat(string msg)
{
    list parts = llParseString2List(msg, ["|"], []);
    if (llList2String(parts, 0) == "PING")
        llRegionSayTo(gGM_KEY, HEARTBEAT_CHANNEL, "ACK|" + llList2String(parts, 1));
}


// =============================================================================
// TARGETING
// =============================================================================

key pickTarget(list enemy_positions, integer strategy)
{
    integer count = llGetListLength(enemy_positions) / 5;
    if (count == 0) return NULL_KEY;

    key   best_key  = NULL_KEY;
    float best_dist = gTowerRange + 1.0;

    gTowerPos = llGetPos();

    integer i;
    for (i = 0; i < count; i++)
    {
        integer idx = i * 5;
        vector enemy_pos = <(float)llList2String(enemy_positions, idx + 1),
                            (float)llList2String(enemy_positions, idx + 2),
                            (float)llList2String(enemy_positions, idx + 3)>;

        float dist = llVecDist(gTowerPos, enemy_pos);
        if (dist <= gTowerRange && dist < best_dist)
        {
            best_dist = dist;
            best_key  = (key)llList2String(enemy_positions, idx);
        }
        // future strategies: else if (strategy == 1) { ... }
    }

    return best_key;
}


// =============================================================================
// HIT RESOLUTION
// =============================================================================

float calcHitChance(float dist)
{
    float chance = gAccuracy * (1.0 - (dist / gTowerRange * gFalloff));
    if (chance < 0.05) chance = 0.05;
    if (chance > 1.0)  chance = 1.0;
    return chance;
}

integer resolveAttack(key target_key, vector target_pos)
{
    float dist       = llVecDist(llGetPos(), target_pos);
    float hit_chance = calcHitChance(dist);
    integer hit      = (llFrand(1.0) < hit_chance);

    if (hit)
    {
        llRegionSayTo(target_key, ENEMY_CHANNEL,
            "TAKE_DAMAGE|" + (string)gDamage);
        llOwnerSay("[TW] HIT  dist=" + (string)((integer)dist)
            + "m chance=" + (string)((integer)(hit_chance * 100)) + "%"
            + " dmg=" + (string)((integer)gDamage));
    }
    else
    {
        llOwnerSay("[TW] MISS dist=" + (string)((integer)dist)
            + "m chance=" + (string)((integer)(hit_chance * 100)) + "%");
    }

    return hit;
}


// =============================================================================
// ATTACK CYCLE
// =============================================================================

requestTarget()
{
    if (!gRegistered || gGM_KEY == NULL_KEY) return;
    gTowerPos = llGetPos();
    llRegionSayTo(gGM_KEY, TOWER_REPORT_CHANNEL,
        "TARGET_REQUEST"
        + "|" + (string)gTowerPos.x
        + "|" + (string)gTowerPos.y
        + "|" + (string)gTowerPos.z
        + "|" + (string)gTowerRange);
}

handleTargetResponse(string msg)
{
    list parts = llParseString2List(msg, ["|"], []);
    if (llGetListLength(parts) < 2) return;

    key target_key = (key)llList2String(parts, 1);
    if (target_key == NULL_KEY) return;

    if (llGetListLength(parts) < 5) return;

    vector target_pos = <(float)llList2String(parts, 2),
                         (float)llList2String(parts, 3),
                         (float)llList2String(parts, 4)>;

    resolveAttack(target_key, target_pos);
}


// =============================================================================
// MAIN STATE
// =============================================================================

default
{
    state_entry()
    {
        // type ID comes from start_param set by GM's llRezObject call.
        // On manual rez (start_param=0), default to type 1 (basic tower).
        gTowerTypeId = llGetStartParameter();
        if (gTowerTypeId < 1) gTowerTypeId = 1;

        llOwnerSay("[TW] Tower type " + (string)gTowerTypeId + " starting up...");
        gTowerPos = llGetPos();

        llListen(GM_DISCOVERY_CHANNEL, "", NULL_KEY, "");
        llListen(GM_REGISTER_CHANNEL,  "", NULL_KEY, "");
        llListen(HEARTBEAT_CHANNEL,    "", NULL_KEY, "");
        llListen(TOWER_REPORT_CHANNEL, "", NULL_KEY, "");
        llListen(SPAWNER_CHANNEL,      "", NULL_KEY, "");
        llListen(GRID_INFO_CHANNEL,    "", NULL_KEY, "");

        // Notecard loading happens first — afterConfigLoaded() triggers discovery
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
        gNotecardQuery = llGetNotecardLine(gNotecardName, gCurrentLine);
    }

    listen(integer channel, string name, key id, string msg)
    {
        if (channel == GM_DISCOVERY_CHANNEL)
        {
            list parts = llParseString2List(msg, ["|"], []);
            if (llList2String(parts, 0) == "GM_HERE" && gGM_KEY == NULL_KEY)
                handleGMHere((key)llList2String(parts, 1));
        }
        else if (channel == SPAWNER_CHANNEL && id == gGM_KEY)
        {
            list parts = llParseString2List(msg, ["|"], []);
            if (llList2String(parts, 0) == "HANDLER_INFO")
                handleHandlerInfo(msg);
        }
        else if (channel == GRID_INFO_CHANNEL)
        {
            list parts = llParseString2List(msg, ["|"], []);
            if (llList2String(parts, 0) == "GRID_INFO")
                handleGridInfo(msg);
        }
        else if (channel == GM_REGISTER_CHANNEL && id == gGM_KEY)
        {
            handleRegisterResponse(msg);
        }
        else if (channel == HEARTBEAT_CHANNEL && id == gGM_KEY)
        {
            handleHeartbeat(msg);
        }
        else if (channel == TOWER_REPORT_CHANNEL && id == gGM_KEY)
        {
            list parts = llParseString2List(msg, ["|"], []);
            if (llList2String(parts, 0) == "TARGET_RESPONSE")
                handleTargetResponse(msg);
        }
    }

    timer()
    {
        if (!gConfigLoaded) return;   // waiting for notecard — shouldn't happen

        if (!gRegistered)
        {
            if (gDiscovering || gGM_KEY == NULL_KEY)
                discoverGM();
            else if (gHandlerKey == NULL_KEY)
                queryHandler();
            else if (!gGridInfoReady)
                requestGridInfo();
            return;
        }

        requestTarget();
    }

    on_rez(integer start_param)
    {
        llResetScript();
    }
}
