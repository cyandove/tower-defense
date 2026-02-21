1. Build the Game Manager with map data structure and registration/heartbeat
2. Build the placement handler prim and verify grid coordinate translation is working correctly — this is foundational since tower placement touches almost everything else
3. Implement the GM's map validation logic (buildable vs path vs occupied) and confirm placement requests are being accepted and rejected correctly
4. Add enemy spawning and waypoint movement with no combat — just confirm enemies walk the path and report to the GM on arrival
5. Add a single tower with the hit resolution math and direct GM-to-enemy damage messages — verify the probabilistic model feels right before building more tower types
6. Expand to multiple tower and enemy parameter variants using the notecard config system
7. Add the animation layer last, once all functional behavior is stable and tested

The main change is pulling placement handler work earlier, since getting the grid coordinate system right underpins tower placement, and you want to catch any issues with your map layout and coordinate math before you've built a lot of other systems on top of assumptions about it.
