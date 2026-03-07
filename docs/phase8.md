Plan: Phase 8 — Animation Layer (Separate Scripts)

Context

The game is functionally complete through Phase 7b. Phase 8 adds a visual/audio layer as
separate scripts that live in the same prim as their counterpart base script. Base scripts
broadcast events via llMessageLinked(LINK_THIS, ...) and the animation scripts react —
no game logic in the animation scripts, no visual logic in the base scripts.

Architecture

tower prim:   tower_basic.lsl          ──llMessageLinked──►  tower_basic-animations.lsl
enemy prim:   enemy_base.lsl           ──llMessageLinked──►  enemy_base-animations.lsl
controller:   controller.lsl           ──llMessageLinked──►  controller-animations.lsl

Animation scripts are entirely passive: they only handle link_message events and never
send messages back. They can be removed without affecting game logic.

Shared Event IDs

Both base and animation scripts define the same integer constants at the top:

// Animation event IDs  (num parameter of llMessageLinked)
// Tower events
integer ANIM_REGISTERED  = 100;   // tower placed and moved into position
integer ANIM_FIRE_HIT    = 101;   // str = "tx|ty|tz"  (target world pos)
integer ANIM_FIRE_MISS   = 102;   // str = "tx|ty|tz"

// Enemy events
integer ANIM_SPAWNED     = 200;   // str = max_health (float string)
integer ANIM_TAKE_DAMAGE = 201;   // str = current_health (float string)
integer ANIM_DEATH       = 202;   // no data

// Controller events
integer ANIM_STATE       = 300;   // str = "state|wave|lives|score"

---
Changes to Base Scripts

lib/tower_basic.lsl

Add the shared event ID constants at top.

Add one llMessageLinked call in each of three places:

// In handleRegisterResponse(), after llSetTimerEvent(gAttackInterval):
llMessageLinked(LINK_THIS, ANIM_REGISTERED, "", NULL_KEY);

// In resolveAttack(), on HIT (after sending TAKE_DAMAGE to enemy):
llMessageLinked(LINK_THIS, ANIM_FIRE_HIT,
    (string)target_pos.x + "|" + (string)target_pos.y + "|" + (string)target_pos.z,
    target_key);

// In resolveAttack(), on MISS:
llMessageLinked(LINK_THIS, ANIM_FIRE_MISS,
    (string)target_pos.x + "|" + (string)target_pos.y + "|" + (string)target_pos.z,
    NULL_KEY);

lib/enemy_base.lsl

Add the shared event ID constants and one new global:

float gMaxHealth = 100.0;   // set once from config, for health bar colour gradient

Add llMessageLinked calls:

// After config is parsed and gHealth is set, store max and notify animation script:
gMaxHealth = gHealth;
llMessageLinked(LINK_THIS, ANIM_SPAWNED, (string)gHealth, NULL_KEY);

// In TAKE_DAMAGE branch, after decrementing gHealth:
llMessageLinked(LINK_THIS, ANIM_TAKE_DAMAGE, (string)gHealth, NULL_KEY);

// In onDeath(), before llDie():
llMessageLinked(LINK_THIS, ANIM_DEATH, "", NULL_KEY);

lib/controller.lsl

Add the shared event ID constants. Add a helper that sends the current state snapshot:

notifyAnimations()
{
    llMessageLinked(LINK_THIS, ANIM_STATE,
        (string)gLifecycle + "|" + (string)gWaveNum
        + "|" + (string)gLives + "|" + (string)gScore,
        NULL_KEY);
}

Call notifyAnimations() at the end of: enterWaiting(), startNextWave(),
onLifeLost(), onEnemyKilled(), gameOver().

---
New Animation Scripts

lib/tower_basic-animations.lsl

Handles:
- ANIM_REGISTERED: initialize appearance (color, glow off)
- ANIM_FIRE_HIT: rotate to face target pos (yaw-only llSetRot), brief yellow glow + fire sound, schedule glow reset
- ANIM_FIRE_MISS: rotate to face target pos, miss sound (quieter), no glow

Rotation helper (horizontal yaw only, prim stays flat):
faceTarget(vector target_pos)
{
    vector self_pos = llGetPos();
    vector dir = llVecNorm(<target_pos.x - self_pos.x,
                            target_pos.y - self_pos.y, 0.0>);
    if (llVecMag(dir) > 0.01)
        llSetRot(llRotBetween(<1.0, 0.0, 0.0>, dir));
}

Glow reset: use llSetTimerEvent(0.15) to clear glow after a brief flash; timer resets itself
after one tick.

Sound constants at top (NULL_KEY placeholders):
key SOUND_FIRE = NULL_KEY;
key SOUND_MISS = NULL_KEY;

lib/enemy_base-animations.lsl

Globals:
float gAnimMaxHealth = 100.0;   // received from ANIM_SPAWNED
integer gFlashing    = FALSE;

Handles:
- ANIM_SPAWNED: store max health, show initial health bar via llSetText
- ANIM_TAKE_DAMAGE: llSetColor(<1,0,0>, ALL_SIDES), gFlashing = TRUE,
llPlaySound(SOUND_HIT, 0.7), update llSetText health bar
- ANIM_DEATH: clear text, particle burst (llParticleSystem), death sound —
no llDie() here (base script handles deletion)

updateHealthBar(float health):
updateHealthBar(float health)
{
    float pct    = health / gAnimMaxHealth;
    vector color = <1.0 - pct, pct, 0.0>;
    llSetText((string)(integer)health + " HP", color, 1.0);
}

Flash reset: llSetTimerEvent(0.15) on damage, timer resets color and stops itself.

Death particle system (one-shot burst, PSYS_SRC_MAX_AGE = 0.1):
llParticleSystem([
    PSYS_PART_FLAGS,           PSYS_PART_EMISSIVE_MASK
                             | PSYS_PART_INTERP_COLOR_MASK
                             | PSYS_PART_INTERP_SCALE_MASK,
    PSYS_SRC_PATTERN,          PSYS_SRC_PATTERN_EXPLODE,
    PSYS_PART_START_COLOR,     <1.0, 0.5, 0.0>,
    PSYS_PART_END_COLOR,       <1.0, 0.0, 0.0>,
    PSYS_PART_START_ALPHA,     1.0,
    PSYS_PART_END_ALPHA,       0.0,
    PSYS_PART_START_SCALE,     <0.3, 0.3, 0.0>,
    PSYS_PART_END_SCALE,       <0.6, 0.6, 0.0>,
    PSYS_SRC_BURST_RATE,       0.01,
    PSYS_SRC_BURST_PART_COUNT, 20,
    PSYS_PART_MAX_AGE,         0.8,
    PSYS_SRC_MAX_AGE,          0.1
]);
llPlaySound(SOUND_DEATH, 1.0);

Sound constants:
key SOUND_HIT   = NULL_KEY;
key SOUND_DEATH = NULL_KEY;

lib/controller-animations.lsl

Handles ANIM_STATE by parsing state|wave|lives|score and calling llSetText:

// State label lookup
string stateLabel(integer s)
{
    if (s == 0) return "Idle";
    if (s == 1) return "Setting up...";
    if (s == 2) return "Touch to start wave";
    if (s == 3) return "Wave active";
    if (s == 4) return "Wave clear!";
    if (s == 5) return "GAME OVER";
    return "Unknown";
}

Display format:
Wave 3   Lives: 5   Score: 120
Wave active

---
Files Created / Modified

┌────────────────────────────────┬──────────────────────────────────────────────────────────────────────┐
│              File              │                                Action                                │
├────────────────────────────────┼──────────────────────────────────────────────────────────────────────┤
│ lib/tower_basic.lsl            │ Add event ID constants + 3 llMessageLinked calls                     │
├────────────────────────────────┼──────────────────────────────────────────────────────────────────────┤
│ lib/enemy_base.lsl             │ Add event ID constants + gMaxHealth global + 3 llMessageLinked calls │
├────────────────────────────────┼──────────────────────────────────────────────────────────────────────┤
│ lib/controller.lsl             │ Add event ID constants + notifyAnimations() + 5 call sites           │
├────────────────────────────────┼──────────────────────────────────────────────────────────────────────┤
│ lib/tower_basic-animations.lsl │ New — rotation, glow flash, fire sounds                              │
├────────────────────────────────┼──────────────────────────────────────────────────────────────────────┤
│ lib/enemy_base-animations.lsl  │ New — health bar, damage flash, death particles                      │
├────────────────────────────────┼──────────────────────────────────────────────────────────────────────┤
│ lib/controller-animations.lsl  │ New — floating text status display                                   │
└────────────────────────────────┴──────────────────────────────────────────────────────────────────────┘

---
Verification

1. Drop tower_basic-animations.lsl into a tower prim alongside tower_basic.lsl — tower
should yaw toward enemies and briefly glow yellow on each fire tick.
2. Drop enemy_base-animations.lsl into an enemy prim — health bar visible on spawn,
turns red on damage, particle burst on death.
3. Drop controller-animations.lsl into the controller prim — floating text updates on
wave start, kills, life loss, and game over.
4. Remove an animation script — base script continues working normally.
5. Run /td ctl status after a wave to confirm free memory is healthy in all modified scripts.
