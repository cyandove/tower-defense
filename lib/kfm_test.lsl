// kfm_test.lsl
// Touch the prim to move it 0.5m up, then 0.5m back down.

default
{
    state_entry()
    {
        llSetStatus(STATUS_PHYSICS, FALSE);
        // Set physics shape to convex hull to reduce KFM complexity cost
        llSetPrimitiveParams([PRIM_PHYSICS_SHAPE_TYPE, PRIM_PHYSICS_SHAPE_CONVEX]);
        llOwnerSay("KFM test ready. Touch to run.");
    }

    touch_start(integer n)
    {
        llOwnerSay("Calling llSetKeyframedMotion...");
        list frames = [
            <0.0, 0.0, 0.5>, 2.0,
            <0.0, 0.0, -0.5>, 2.0
        ];
        llSetKeyframedMotion(frames, [KFM_DATA, KFM_TRANSLATION]);
        llOwnerSay("Call returned.");
    }

    moving_end()
    {
        llOwnerSay("moving_end fired — KFM complete.");
    }
}
