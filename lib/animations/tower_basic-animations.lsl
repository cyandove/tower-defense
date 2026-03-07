// =============================================================================
// tower_basic-animations.lsl
// Tower Defense — Tower Animation Layer, Phase 8
//
// Drop this script into a tower prim alongside tower_basic.lsl.
// Reacts to llMessageLinked events from tower_basic.lsl — no game logic here.
// Can be removed without affecting game behaviour.
//
// Events handled:
//   ANIM_REGISTERED (100) — initialise appearance (colour, glow off)
//   ANIM_FIRE_HIT   (101) — yaw toward target, brief yellow glow, fire sound
//   ANIM_FIRE_MISS  (102) — yaw toward target, quiet miss sound, no glow
// =============================================================================


// -----------------------------------------------------------------------------
// ANIMATION EVENT IDS — must match tower_basic.lsl
// -----------------------------------------------------------------------------
integer ANIM_REGISTERED = 100;
integer ANIM_FIRE_HIT   = 101;
integer ANIM_FIRE_MISS  = 102;


// -----------------------------------------------------------------------------
// SOUND PLACEHOLDERS — replace NULL_KEY with actual sound asset UUIDs in-world
// -----------------------------------------------------------------------------
key SOUND_FIRE = NULL_KEY;
key SOUND_MISS = NULL_KEY;


// -----------------------------------------------------------------------------
// STATE
// -----------------------------------------------------------------------------
integer gGlowing = FALSE;


// =============================================================================
// HELPERS
// =============================================================================

// Rotate the prim (yaw only) to face a world-space target position.
faceTarget(vector target_pos)
{
    vector self_pos = llGetPos();
    vector dir = llVecNorm(<target_pos.x - self_pos.x,
                            target_pos.y - self_pos.y, 0.0>);
    if (llVecMag(dir) > 0.01)
        llSetRot(llRotBetween(<1.0, 0.0, 0.0>, dir));
}

// Parse a "|"-delimited position string produced by tower_basic.lsl.
vector parsePos(string s)
{
    list parts = llParseString2List(s, ["|"], []);
    return <(float)llList2String(parts, 0),
            (float)llList2String(parts, 1),
            (float)llList2String(parts, 2)>;
}


// =============================================================================
// MAIN STATE
// =============================================================================

default
{
    link_message(integer sender_num, integer num, string str, key id)
    {
        if (num == ANIM_REGISTERED)
        {
            // Initialise appearance: neutral colour, no glow
            llSetColor(<0.8, 0.8, 0.8>, ALL_SIDES);
            llSetPrimitiveParams([PRIM_GLOW, ALL_SIDES, 0.0]);
        }
        else if (num == ANIM_FIRE_HIT)
        {
            faceTarget(parsePos(str));
            llSetPrimitiveParams([PRIM_GLOW, ALL_SIDES, 0.4]);
            llSetColor(<1.0, 1.0, 0.0>, ALL_SIDES);
            gGlowing = TRUE;
            if (SOUND_FIRE != NULL_KEY)
                llPlaySound(SOUND_FIRE, 1.0);
            llSetTimerEvent(0.15);
        }
        else if (num == ANIM_FIRE_MISS)
        {
            faceTarget(parsePos(str));
            if (SOUND_MISS != NULL_KEY)
                llPlaySound(SOUND_MISS, 0.4);
        }
    }

    timer()
    {
        // One-shot glow reset after ANIM_FIRE_HIT flash
        if (gGlowing)
        {
            llSetPrimitiveParams([PRIM_GLOW, ALL_SIDES, 0.0]);
            llSetColor(<0.8, 0.8, 0.8>, ALL_SIDES);
            gGlowing = FALSE;
        }
        llSetTimerEvent(0);
    }
}
