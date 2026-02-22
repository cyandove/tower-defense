// =============================================================================
// tower_basic.lsl
// Tower Defense — Basic Tower, Phase 5b
// Adds: automatic grid coordinate detection from placement handler
// =============================================================================
// OVERVIEW:
//   Registers with the GM, then on each attack cycle queries the GM for the
//   nearest enemy in range. On a valid target, rolls hit chance with range
//   falloff and sends TAKE_DAMAGE directly to the enemy if it hits.
//
// STARTUP SEQUENCE:
//   1. Discover GM
//   2. Query GM for placement handler key (HANDLER_QUERY)
//   3. Request grid info from handler via GM (GRID_INFO_REQUEST)
//   4. Derive grid coords from world position + grid origin + cell size
//   5. Register with GM using correct grid coords
//   6. Begin attack cycle
//
// TARGETING STRATEGY:
//   Currently "nearest". pickTarget() is isolated so switching strategies
//   (first-in-path, lowest-health, etc.) only requires changing that function.
//
// HIT PROBABILITY MODEL:
//   hit_chance = ACCURACY * (1.0 - (dist / TOWER_RANGE) * FALLOFF)
//   At point-blank: ACCURACY          (default 0.85)
//   At max range:   ACCURACY * 0.6    (default 0.51)
//   Roll: llFrand(1.0) < hit_chance
//
// SETUP:
//   1. Rez a prim on a buildable grid cell
//   2. Add this script — no configuration needed
//   3. Script discovers GM, derives its own grid position, and registers
//   4. Tower begins attacking automatically once enemies are present
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
// TOWER CONFIGURATION
// Adjust these to tune feel. Move to notecard later for per-instance config.
// -----------------------------------------------------------------------------

// How often the tower attempts to fire, in seconds.
float ATTACK_INTERVAL = 2.0;

// Maximum targeting range in metres.
float TOWER_RANGE = 10.0;

// Base hit probability at point-blank range (0.0–1.0).
float ACCURACY = 0.85;

// How much accuracy degrades across the full range.
// hit_chance = ACCURACY * (1.0 - (dist/TOWER_RANGE) * FALLOFF)
// 0.0 = no falloff, 1.0 = zero accuracy at max range.
float FALLOFF = 0.4;

// Damage dealt per successful hit.
float DAMAGE = 25.0;

// Targeting strategy identifier — passed to pickTarget() for future expansion.
// 0 = nearest (only strategy implemented in phase 5)
integer TARGETING_STRATEGY = 0;

integer RETRY_INTERVAL = 5;
integer REG_TYPE_TOWER = 1;


// -----------------------------------------------------------------------------
// GLOBAL STATE
// -----------------------------------------------------------------------------
key     gGM_KEY        = NULL_KEY;
key     gHandlerKey    = NULL_KEY;
integer gRegistered    = FALSE;
integer gDiscovering   = FALSE;
integer gGridInfoReady = FALSE;
vector  gTowerPos      = ZERO_VECTOR;

// Derived from GRID_INFO
vector  gGridOrigin    = ZERO_VECTOR;
float   gCellSize      = 2.0;

// Derived grid position — computed once grid info arrives
integer gGridX         = 0;
integer gGridY         = 0;


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

// Step 2: ask GM for the placement handler key
queryHandler()
{
    llRegionSayTo(gGM_KEY, SPAWNER_CHANNEL, "HANDLER_QUERY");
    llOwnerSay("[TW] Sent HANDLER_QUERY.");
}

// Step 3: GM replied with the handler key — request grid info
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

    llRegionSayTo(gGM_KEY, GRID_INFO_CHANNEL,
        "GRID_INFO_REQUEST|" + (string)llGetKey()
        + "|" + (string)gHandlerKey);
}

// Step 4: handler replied with grid info — derive grid coords and register
handleGridInfo(string msg)
{
    list parts = llParseString2List(msg, ["|"], []);
    if (llGetListLength(parts) < 5)
    {
        llOwnerSay("[TW] Malformed GRID_INFO: " + msg);
        return;
    }

    gGridOrigin = <(float)llList2String(parts, 1),
                   (float)llList2String(parts, 2),
                   (float)llList2String(parts, 3)>;
    gCellSize   = (float)llList2String(parts, 4);
    gGridInfoReady = TRUE;

    // Derive grid coords from world position
    gTowerPos = llGetPos();
    gGridX = (integer)((gTowerPos.x - gGridOrigin.x) / gCellSize);
    gGridY = (integer)((gTowerPos.y - gGridOrigin.y) / gCellSize);

    llOwnerSay("[TW] Grid info received. Position derives to grid ("
        + (string)gGridX + "," + (string)gGridY + ").");

    // Step 5: now register with correct grid coords
    llRegionSayTo(gGM_KEY, GM_REGISTER_CHANNEL,
        "REGISTER|" + (string)REG_TYPE_TOWER
        + "|" + (string)gGridX
        + "|" + (string)gGridY);
}

handleGridInfoError(string msg)
{
    list parts = llParseString2List(msg, ["|"], []);
    llOwnerSay("[TW] Grid info error: " + llList2String(parts, 1) + ". Will retry.");
}

// Step 6: GM confirmed registration — start attacking
handleRegisterResponse(string msg)
{
    list parts = llParseString2List(msg, ["|"], []);
    string cmd = llList2String(parts, 0);
    if (cmd == "REGISTER_OK")
    {
        gRegistered = TRUE;
        llSetTimerEvent(0);
        llOwnerSay("[TW] Registered at grid (" + (string)gGridX + ","
            + (string)gGridY + ")."
            + " Range=" + (string)TOWER_RANGE + "m"
            + " Interval=" + (string)ATTACK_INTERVAL + "s");
        llSetTimerEvent(ATTACK_INTERVAL);
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

// Returns the key of the best target from a flat enemy position list, or
// NULL_KEY if no enemy is within range.
//
// TARGETING_STRATEGY values:
//   0 = nearest (current)
//
// To add a new strategy, add an else-if branch here. The attack cycle
// calls pickTarget() and never needs to change.
key pickTarget(list enemy_positions, integer strategy)
{
    integer count = llGetListLength(enemy_positions) / 5;
    if (count == 0) return NULL_KEY;

    key   best_key  = NULL_KEY;
    float best_dist = TOWER_RANGE + 1.0;

    gTowerPos = llGetPos();

    integer i;
    for (i = 0; i < count; i++)
    {
        integer idx = i * 5;
        vector enemy_pos = <(float)llList2String(enemy_positions, idx + 1),
                            (float)llList2String(enemy_positions, idx + 2),
                            (float)llList2String(enemy_positions, idx + 3)>;

        float dist = llVecDist(gTowerPos, enemy_pos);

        if (dist <= TOWER_RANGE && dist < best_dist)
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
    float chance = ACCURACY * (1.0 - (dist / TOWER_RANGE * FALLOFF));
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
            "TAKE_DAMAGE|" + (string)DAMAGE);
        llOwnerSay("[TW] HIT  dist=" + (string)((integer)dist)
            + "m chance=" + (string)((integer)(hit_chance * 100)) + "%"
            + " dmg=" + (string)((integer)DAMAGE));
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
        + "|" + (string)TOWER_RANGE);
}

handleTargetResponse(string msg)
{
    list parts = llParseString2List(msg, ["|"], []);
    if (llGetListLength(parts) < 2) return;

    key target_key = (key)llList2String(parts, 1);
    if (target_key == NULL_KEY) return;

    if (llGetListLength(parts) < 5)
    {
        llOwnerSay("[TW] Malformed TARGET_RESPONSE: " + msg);
        return;
    }

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
        llOwnerSay("[TW] Tower starting up...");
        gTowerPos = llGetPos();

        llListen(GM_DISCOVERY_CHANNEL, "", NULL_KEY, "");
        llListen(GM_REGISTER_CHANNEL,  "", NULL_KEY, "");
        llListen(HEARTBEAT_CHANNEL,    "", NULL_KEY, "");
        llListen(TOWER_REPORT_CHANNEL, "", NULL_KEY, "");
        llListen(SPAWNER_CHANNEL,      "", NULL_KEY, "");
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
        else if (channel == SPAWNER_CHANNEL && id == gGM_KEY)
        {
            list parts = llParseString2List(msg, ["|"], []);
            if (llList2String(parts, 0) == "HANDLER_INFO")
                handleHandlerInfo(msg);
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
        if (!gRegistered)
        {
            // Retry whichever setup step is incomplete
            if (gDiscovering || gGM_KEY == NULL_KEY)
                discoverGM();
            else if (gHandlerKey == NULL_KEY)
                queryHandler();
            else if (!gGridInfoReady)
                llRegionSayTo(gGM_KEY, GRID_INFO_CHANNEL,
                    "GRID_INFO_REQUEST|" + (string)llGetKey()
                    + "|" + (string)gHandlerKey);
            return;
        }

        // Registered — attack cycle tick
        requestTarget();
    }

    on_rez(integer start_param)
    {
        llResetScript();
    }
}
