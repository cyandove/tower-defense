1. Build the Game Manager with map data structure and registration/heartbeat
2. Build the placement handler prim and verify grid coordinate translation is working correctly — this is foundational since tower placement touches almost everything else
3. Implement the GM's map validation logic (buildable vs path vs occupied) and confirm placement requests are being accepted and rejected correctly
4. Add enemy spawning and waypoint movement with no combat — just confirm enemies walk the path and report to the GM on arrival
5. Add a single tower with the hit resolution math and direct GM-to-enemy damage messages — verify the probabilistic model feels right before building more tower types
6. Expand to multiple tower and enemy parameter variants using the notecard config system
7. Controller implementation
7a. Fix llRezObject 10m limit — rez all managed objects (GM, handler, spawner) adjacent
    to the controller, then send each one a target position in its config message so it
    can relocate itself with llSetRegionPos (no distance cap). The placement handler
    re-derives grid geometry and re-registers with the GM after moving.
    Commit: cb47578
7b. Fix tower rezzing 10m limit — encode gx/gy into start_param (type_id*10000 + gx*100 + gy)
    so the GM rezzes towers at its own position and the tower moves to the correct grid cell
    after receiving target world pos in REGISTER_OK. Eliminates handler query and grid info
    request steps from tower startup. Also fixes TOP_FACE = 0 on placement handler.
    Commits: 7067d2a, c06a666
8. Add the animation layer last, once all functional behavior is stable and tested

The main change is pulling placement handler work earlier, since getting the grid coordinate system right underpins tower placement, and you want to catch any issues with your map layout and coordinate math before you've built a lot of other systems on top of assumptions about it.
