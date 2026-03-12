// =============================================================================
// tower-animations.lsl
// Tower Defense — Tower Animation Layer, Phase 8
//
// Drop this script into a tower prim alongside tower.lsl.
// Reacts to llMessageLinked events from tower.lsl — no game logic here.
// Can be removed without affecting game behaviour.
//
// Events handled:
//   ANIM_REGISTERED (100) — initialise appearance (colour, glow off)
//   ANIM_FIRE_HIT   (101) — yaw toward target, brief yellow glow, fire sound
//   ANIM_FIRE_MISS  (102) — yaw toward target, quiet miss sound, no glow
// =============================================================================


// -----------------------------------------------------------------------------
// ANIMATION EVENT IDS — must match tower.lsl
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
integer gGlowing  = FALSE;

// llScaleByFactor operates on the whole linkset uniformly.
// INITIAL_FACTOR must keep all prims above SL's 0.01 m minimum.
float   INITIAL_FACTOR = 0.1;  // start at 10% of normal size
float   gCurrentFactor;        // tracks current scale relative to original

integer gRising   = FALSE;    // TRUE while spawn-rise animation is playing
integer gRiseStep = 0;

integer RISE_STEPS    = 10;
float   RISE_INTERVAL = 0.05;  // 10 steps × 0.05 s = 0.5 s total


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

// Parse a "|"-delimited position string produced by tower.lsl.
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
    state_entry()
    {
        // No visual changes here — prim appears normally when built or edited.
        // Shrink/hide only happens in on_rez when rezzed by the GM (start_param != 0).
        gCurrentFactor = 1.0;
    }

    on_rez(integer start_param)
    {
        if (start_param == 0)
        {
            // Rezzed from inventory manually — restore scale to 1.0x in case a
            // previous animation session left the object at a wrong scale.
            if (gCurrentFactor > 0.0 && gCurrentFactor != 1.0)
                llScaleByFactor(1.0 / gCurrentFactor);
            gCurrentFactor = 1.0;
            llSetLinkAlpha(LINK_SET, 1.0, ALL_SIDES);
            return;
        }
        // Rezzed by GM — hide and shrink until registered and in position
        gCurrentFactor = INITIAL_FACTOR;
        llSetLinkAlpha(LINK_SET, 0.0, ALL_SIDES);
        llScaleByFactor(INITIAL_FACTOR);
    }

    link_message(integer sender_num, integer num, string str, key id)
    {
        if (num == ANIM_REGISTERED)
        {
            // Tower has teleported to its grid cell — reveal entire linkset and rise
            llSetLinkAlpha(LINK_SET, 1.0, ALL_SIDES);
            llSetColor(<0.8, 0.8, 0.8>, ALL_SIDES);
            llSetPrimitiveParams([PRIM_GLOW, ALL_SIDES, 0.0]);
            gRising   = TRUE;
            gRiseStep = 0;
            llSetTimerEvent(RISE_INTERVAL);
        }
        else if (num == ANIM_FIRE_HIT)
        {
            faceTarget(parsePos(str));
            llSetPrimitiveParams([PRIM_GLOW, ALL_SIDES, 0.4]);
            llSetColor(<1.0, 1.0, 0.0>, ALL_SIDES);
            gGlowing = TRUE;
            if (SOUND_FIRE != NULL_KEY)
                llPlaySound(SOUND_FIRE, 1.0);
            if (!gRising)
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
        if (gRising)
        {
            gRiseStep++;
            float targetFactor;
            if (gRiseStep >= RISE_STEPS)
            {
                targetFactor = 1.0;
                gRising = FALSE;
            }
            else
            {
                targetFactor = INITIAL_FACTOR
                    + (1.0 - INITIAL_FACTOR) * ((float)gRiseStep / (float)RISE_STEPS);
            }
            llScaleByFactor(targetFactor / gCurrentFactor);
            gCurrentFactor = targetFactor;

            if (!gRising)
            {
                if (gGlowing)
                    llSetTimerEvent(0.15);
                else
                    llSetTimerEvent(0);
            }
            return;
        }

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
