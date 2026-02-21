Good. Now I'll write all three files — the updated GM, the spawner, and the enemy.Three files. A few things to know before testing:

**Setup order matters.** Get the GM running first, then rez the spawner — it will auto-discover and register. Only then put the enemy prim in the spawner's inventory.

**The enemy prim must be named `Enemy`** (exactly, capital E) to match `ENEMY_OBJECT_NAME` in the spawner. If the name doesn't match the spawner will tell you in owner chat.

**Set `GRID_ORIGIN` and `CELL_SIZE` in `spawner.lsl`** to match your actual build, the same values you determined for the placement handler. The spawner uses these to convert the waypoint grid coordinates into world positions that it sends to each enemy.

**`ENEMIES_PER_WAVE = 1`** is set deliberately low for first testing. Once a single enemy walks the full path and you see `ENEMY_ARRIVED` in the GM's chat, bump it up.

**The enemy uses `llMoveToTarget`** which requires the prim to be physical. The script enables physics on wakeup and locks X/Y rotation to keep it upright. If enemies are tumbling, you may need to adjust the prim's shape or increase its mass via object properties.
