// =============================================================================
// tower.lsl
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
// INVENTORY SETUP:
//   Each tower prim needs:
//     - tower.lsl (this script)
//     - tower-animations.lsl (optional)
//     - tower_types.cfg (shared type registry)
//     - tower_basic.cfg, tower_sniper.cfg, etc. (stats notecards)
//
//   tower_types.cfg maps type_id → stats notecard name.
//   The tower reads tower_types.cfg first, finds the line matching its
//   type_id (from start_param), then loads that stats notecard.
//
//   Stats notecard example (tower_basic.cfg):
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
//   1. Read tower_types.cfg to find stats notecard for our type_id
//   2. Load stats notecard (damage, range, accuracy, etc.)
//   3. Discover GM
//   4. Register with GM (grid coords decoded from start_param)
//   5. Begin attack cycle
// =============================================================================


// -----------------------------------------------------------------------------
// ANIMATION EVENT IDS — shared with tower-animations.lsl
// -----------------------------------------------------------------------------
integer ANIM_REGISTERED = 100;
integer ANIM_FIRE_HIT   = 101;
integer ANIM_FIRE_MISS  = 102;


// -----------------------------------------------------------------------------
// DEBUG
// -----------------------------------------------------------------------------
integer DEBUG         = FALSE;   // compile-time default
integer gDebug        = FALSE;   // runtime toggle
integer DBG_CHANNEL = -2099;   // owner-only debug toggle broadcast


// -----------------------------------------------------------------------------
// CHANNEL CONSTANTS — must match game_manager.lsl
// -----------------------------------------------------------------------------
integer GM_REGISTER_CHANNEL   = -2001;
integer GM_DEREGISTER_CHANNEL = -2002;
integer HEARTBEAT_CHANNEL     = -2003;
integer TOWER_REPORT_CHANNEL  = -2005;
integer GM_DISCOVERY_CHANNEL  = -2007;
integer ENEMY_CHANNEL         = -2010;


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
integer gRegistered    = FALSE;
integer gDiscovering   = FALSE;
vector  gTowerPos      = ZERO_VECTOR;

integer gGridX         = 0;
integer gGridY         = 0;

// Notecard loading state
integer gTowerTypeId   = 1;       // set from start_param on rez
string  gNotecardName  = "";
key     gNotecardQuery = NULL_KEY;
integer gCurrentLine   = 0;
integer gConfigLoaded  = FALSE;
integer gLoadPhase     = 0;       // 0=tower_types.cfg, 1=stats notecard


// =============================================================================
// DEBUG HELPER
// =============================================================================

dbg(string msg)
{
    if (gDebug) llOwnerSay(msg);
}


// =============================================================================
// NOTECARD LOADING
// =============================================================================

startNotecardLoad()
{
    if (llGetInventoryType("tower_types.cfg") == INVENTORY_NONE)
    {
        llOwnerSay("[TW] tower_types.cfg not found. Using defaults.");
        gConfigLoaded = TRUE;
        afterConfigLoaded();
        return;
    }
    gLoadPhase     = 0;
    gNotecardName  = "";
    gCurrentLine   = 0;
    gNotecardQuery = llGetNotecardLine("tower_types.cfg", gCurrentLine);
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
    dbg("[TW] Config loaded: " + gTowerTypeName
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
    dbg("[TW] Broadcasting GM_DISCOVER...");
}

handleGMHere(key gm_key)
{
    gGM_KEY      = gm_key;
    gDiscovering = FALSE;
    dbg("[TW] Found GM: " + (string)gGM_KEY);
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
        if (llGetListLength(parts) >= 5)
        {
            vector target = <(float)llList2String(parts, 2),
                             (float)llList2String(parts, 3),
                             (float)llList2String(parts, 4)>;
            llSetRegionPos(target);
            gTowerPos = llGetPos();
        }
        llSetTimerEvent(0);
        dbg("[TW] Registered: " + gTowerTypeName
            + " at (" + (string)gGridX + "," + (string)gGridY + ")"
            + " range=" + (string)gTowerRange + "m");
        llSetTimerEvent(gAttackInterval);
        llMessageLinked(LINK_THIS, ANIM_REGISTERED, "", NULL_KEY);
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
        dbg("[TW] HIT  dist=" + (string)((integer)dist)
            + "m chance=" + (string)((integer)(hit_chance * 100)) + "%"
            + " dmg=" + (string)((integer)gDamage));
        llMessageLinked(LINK_THIS, ANIM_FIRE_HIT,
            (string)target_pos.x + "|" + (string)target_pos.y + "|" + (string)target_pos.z,
            target_key);
    }
    else
    {
        dbg("[TW] MISS dist=" + (string)((integer)dist)
            + "m chance=" + (string)((integer)(hit_chance * 100)) + "%");
        llMessageLinked(LINK_THIS, ANIM_FIRE_MISS,
            (string)target_pos.x + "|" + (string)target_pos.y + "|" + (string)target_pos.z,
            NULL_KEY);
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
        gDebug = DEBUG;
        llListen(GM_DISCOVERY_CHANNEL, "", NULL_KEY,     "");
        llListen(GM_REGISTER_CHANNEL,  "", NULL_KEY,     "");
        llListen(HEARTBEAT_CHANNEL,    "", NULL_KEY,     "");
        llListen(TOWER_REPORT_CHANNEL, "", NULL_KEY,     "");
        llListen(DBG_CHANNEL,        "", llGetOwner(), "");
        // on_rez fires after state_entry and kicks off the startup sequence.
        // A manual script reset (no on_rez) starts as type 1 at (0,0).
    }

    dataserver(key query_id, string data)
    {
        if (query_id != gNotecardQuery) return;

        if (gLoadPhase == 0)
        {
            // Phase 0: reading tower_types.cfg to find our notecard name
            if (data == EOF)
            {
                if (gNotecardName == "")
                {
                    llOwnerSay("[TW] Type " + (string)gTowerTypeId
                        + " not found in tower_types.cfg. Using defaults.");
                    gConfigLoaded = TRUE;
                    afterConfigLoaded();
                    return;
                }
                if (llGetInventoryType(gNotecardName) == INVENTORY_NONE)
                {
                    llOwnerSay("[TW] '" + gNotecardName
                        + "' not found. Using defaults.");
                    gConfigLoaded = TRUE;
                    afterConfigLoaded();
                    return;
                }
                dbg("[TW] Loading config from '" + gNotecardName + "'...");
                gLoadPhase   = 1;
                gCurrentLine = 0;
                gNotecardQuery = llGetNotecardLine(gNotecardName, gCurrentLine);
                return;
            }
            // Parse tower_types.cfg line: type_id|obj_name|label|notecard
            if (data != "" && llGetSubString(data, 0, 0) != "#")
            {
                list fields = llParseString2List(data, ["|"], []);
                if (llGetListLength(fields) >= 4
                    && (integer)llList2String(fields, 0) == gTowerTypeId)
                {
                    gNotecardName = llList2String(fields, 3);
                    dbg("[TW] Found notecard: " + gNotecardName);
                }
            }
            gCurrentLine++;
            gNotecardQuery = llGetNotecardLine("tower_types.cfg", gCurrentLine);
        }
        else
        {
            // Phase 1: reading stats notecard
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
            if (msg == "SHUTDOWN") llDie();
            else handleRegisterResponse(msg);
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
        else if (channel == DBG_CHANNEL)
        {
            if      (msg == "DEBUG_ON")  gDebug = TRUE;
            else if (msg == "DEBUG_OFF") gDebug = FALSE;
        }
    }

    timer()
    {
        if (!gConfigLoaded) return;   // waiting for notecard — shouldn't happen

        if (!gRegistered)
        {
            if (gDiscovering || gGM_KEY == NULL_KEY)
                discoverGM();
            return;
        }

        requestTarget();
    }

    on_rez(integer start_param)
    {
        // Decode start_param here — reliable, no reset needed.
        // Encoding: type_id * 10000 + gx * 100 + gy
        integer sp = start_param;
        gTowerTypeId = sp / 10000;
        gGridX       = (sp % 10000) / 100;
        gGridY       = sp % 100;
        if (gTowerTypeId < 1) gTowerTypeId = 1;

        // Reset runtime state for clean re-rez without llResetScript().
        gGM_KEY        = NULL_KEY;
        gRegistered    = FALSE;
        gDiscovering   = FALSE;
        gConfigLoaded  = FALSE;
        gNotecardQuery = NULL_KEY;
        gCurrentLine   = 0;
        gLoadPhase     = 0;
        gNotecardName  = "";
        gTowerPos      = llGetPos();

        dbg("[TW] Tower type=" + (string)gTowerTypeId
            + " gx=" + (string)gGridX + " gy=" + (string)gGridY + " starting...");

        startNotecardLoad();
        llSetTimerEvent(RETRY_INTERVAL);
    }
}
