// =============================================================================
// enemy_base-animations.lsl
// Tower Defense — Enemy Animation Layer, Phase 8
//
// Drop this script into an enemy prim alongside enemy_base.lsl.
// Reacts to llMessageLinked events from enemy_base.lsl — no game logic here.
// Can be removed without affecting game behaviour.
//
// Events handled:
//   ANIM_SPAWNED     (200) — store max health, show initial health bar
//   ANIM_TAKE_DAMAGE (201) — flash red, play hit sound, update health bar
//   ANIM_DEATH       (202) — clear text, particle burst, play death sound
// =============================================================================


// -----------------------------------------------------------------------------
// ANIMATION EVENT IDS — must match enemy_base.lsl
// -----------------------------------------------------------------------------
integer ANIM_SPAWNED     = 200;
integer ANIM_TAKE_DAMAGE = 201;
integer ANIM_DEATH       = 202;


// -----------------------------------------------------------------------------
// SOUND PLACEHOLDERS — replace NULL_KEY with actual sound asset UUIDs in-world
// -----------------------------------------------------------------------------
key SOUND_HIT   = NULL_KEY;
key SOUND_DEATH = NULL_KEY;


// -----------------------------------------------------------------------------
// STATE
// -----------------------------------------------------------------------------
float   gAnimMaxHealth = 100.0;
integer gFlashing      = FALSE;


// =============================================================================
// HELPERS
// =============================================================================

updateHealthBar(float health)
{
    float pct    = health / gAnimMaxHealth;
    if (pct < 0.0) pct = 0.0;
    if (pct > 1.0) pct = 1.0;
    vector color = <1.0 - pct, pct, 0.0>;
    llSetText((string)((integer)health) + " HP", color, 1.0);
}


// =============================================================================
// MAIN STATE
// =============================================================================

default
{
    link_message(integer sender_num, integer num, string str, key id)
    {
        if (num == ANIM_SPAWNED)
        {
            gAnimMaxHealth = (float)str;
            updateHealthBar(gAnimMaxHealth);
        }
        else if (num == ANIM_TAKE_DAMAGE)
        {
            float current = (float)str;
            llSetColor(<1.0, 0.0, 0.0>, ALL_SIDES);
            gFlashing = TRUE;
            if (SOUND_HIT != NULL_KEY)
                llPlaySound(SOUND_HIT, 0.7);
            updateHealthBar(current);
            llSetTimerEvent(0.15);
        }
        else if (num == ANIM_DEATH)
        {
            llSetText("", ZERO_VECTOR, 0.0);
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
            if (SOUND_DEATH != NULL_KEY)
                llPlaySound(SOUND_DEATH, 1.0);
        }
    }

    timer()
    {
        // One-shot damage flash reset
        if (gFlashing)
        {
            llSetColor(<1.0, 1.0, 1.0>, ALL_SIDES);
            gFlashing = FALSE;
        }
        llSetTimerEvent(0);
    }
}
