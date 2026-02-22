Four files. Here's the full picture of what changed and why it should finally clear the memory problem:
What moved where
The GM's gMap (300 entries, ~4.8KB heap), initMap(), all cell helpers, gReservations, gLives, gWaveActive, and startWave() are completely gone from the GM. The GM is now a pure routing and registry script. Its startup no longer does anything expensive — it just opens listeners and broadcasts GM_READY. The controller owns all of that state in a script that has nothing else to do except manage it.
Startup sequence

You place the controller prim at the grid's south-west corner and touch it
Controller calls loadMap(1) — builds gMap in its own 64KB space, derives waypoints via chain-follow
Controller rezzes GM, placement handler, and spawner at calculated world positions
GM broadcasts GM_READY on -2013; handler and spawner discover the GM and register normally
As each registers, GM sends REGISTERED to the controller; controller decrements gSetupPending
Once all three are in (gSetupPending == 0 and gGM_Key != NULL_KEY), controller sends GM_CONFIG and SPAWNER_CONFIG
Spawner receives its waypoint string pre-built — no grid-info request chain needed
Spawner sends SPAWNER_CONFIG_OK; controller enters WAITING
Touch controller again to start wave 1

Lifecycle from here
Waves escalate automatically: wave 1 = 3 enemies, wave 2 = 5, wave 3 = 7 (configurable via WAVE_BASE and WAVE_INCREMENT in the controller). Lives and score live in the controller. Game over triggers cleanupObjects() which sends SHUTDOWN to all three managed objects — they each deregister and call llDie(). Touch the controller again to run a new game.
In-world setup now
The controller prim's inventory needs: GameManager, PlacementHandler, Spawner. The GM's inventory still needs the Tower object. The spawner's inventory still needs Enemy. No manual placement of the GM, handler, or spawner — the controller handles that. Place only the controller prim, set CELL_SIZE to your in-world metre scale, touch it.
Debug commands

/td ctl status — lifecycle state, wave, lives, score, enemies out, free memory
/td ctl map — ASCII map dump (now lives in controller, not GM)
/td ctl reset — clean shutdown and reset to idle
/td ctl wave — force-start next wave for testing
