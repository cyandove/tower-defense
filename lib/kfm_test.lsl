// kfm_test.lsl
// Touch the prim to move it 5m forward, then 5m back.
// Verifies that llSetKeyframedMotion works on this object.

default
{
    state_entry()
    {
        llSetStatus(STATUS_PHYSICS, FALSE);
        llOwnerSay("KFM test ready. Touch to run.");
    }

    touch_start(integer n)
    {
        llOwnerSay("Starting KFM sequence...");
        list frames = [
            <5.0, 0.0, 0.0>, 5.0,   // move 5m on X over 5 seconds
            <-5.0, 0.0, 0.0>, 5.0   // move back over 5 seconds
        ];
        llSetKeyframedMotion(frames, [KFM_DATA, KFM_TRANSLATION]);
    }

    moving_end()
    {
        llOwnerSay("moving_end fired — KFM complete.");
    }
}
