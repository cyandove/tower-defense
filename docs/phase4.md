## Phase 4 Plan: Enemy Spawning and Waypoint Movement

Two new scripts this phase — a spawner and an enemy — plus additions to the GM to support both.

---

## New Scripts

### `spawner.lsl`

The spawner is a single prim that sits at the entrance of the path. Its only jobs are to register with the GM, listen for wave start signals, and rez enemies from its inventory at a configured interval. It doesn't do any movement or combat logic itself.

It registers as `REG_TYPE_SPAWNER` and participates in the heartbeat like any other object. The GM tells it when to start and stop spawning via a new `SPAWNER_CHANNEL`.

At rez time, each enemy receives its waypoint list and other config via `start_param` or a notecard. Since `start_param` is a single integer, passing a full waypoint list that way isn't viable — the cleaner approach is for the spawner to send the enemy a configuration message immediately after rezzing it, before the enemy starts moving. The enemy holds still until it receives that message.

### `enemy_base.lsl`

Handles the full lifecycle of a single enemy:

- On rez, registers with the GM and waits for a config message from the spawner
- On receiving config, begins stepping through the waypoint list using `llMoveToTarget`
- Reports position to the GM periodically so the GM's position table stays current
- On reaching the final waypoint, reports arrival to the GM and deletes itself
- Responds to heartbeat PINGs like any registered object

---

## Waypoint System

Waypoints are a list of region-space XYZ vectors stored in the spawner, passed to each enemy at spawn time. They correspond directly to the path cells defined in the GM's map, translated from grid coordinates to world positions.

The translation uses the same origin and cell size logic as the placement handler — center of a grid cell at `(x, y)` is:

```
world_pos = grid_origin + <(x + 0.5) * cell_size, (y + 0.5) * cell_size, ground_z>
```

Rather than hardcoding world positions in the spawner, you configure `GRID_ORIGIN`, `CELL_SIZE`, and `GROUND_Z` and define the path as a list of grid coordinate pairs. The spawner converts them to world positions at startup, making it easy to adjust the map layout without hunting through vector literals.

The path definition in the spawner should match the path cells in `initMap()` in the GM — they need to stay in sync. A later phase could have the GM distribute the waypoint list to the spawner at registration time, but for now keeping it as a duplicate constant is fine and simpler.

---

## New Channels

```lsl
integer SPAWNER_CHANNEL = -2009;  // GM → spawner commands
integer ENEMY_CHANNEL   = -2010;  // spawner → enemy config, GM → enemy commands
```

---

## GM Additions

**Position table** — a separate strided list `gEnemyPositions` tracking `[key, x, y, z, timestamp]` for each active enemy. Updated when enemies report in, used in phase 5 for tower targeting.

**Enemy arrival handler** — when an enemy reports `ENEMY_ARRIVED`, the GM decrements a lives counter (stubbed for now, just logged), removes the enemy from the position table, and logs the event.

**Wave control stubs** — `WAVE_START` and `WAVE_END` commands on `SPAWNER_CHANNEL`. Phase 4 just needs `WAVE_START` to trigger spawning. You can trigger it manually via a new debug command `/td wave start` rather than building full wave logic yet.

**Enemy registration** — enemies register as `REG_TYPE_ENEMY` with their starting grid position. The GM should not enforce a limit on enemy count the way it does for placement handlers.

---

## Movement Approach

`llMoveToTarget` works well for this. Each enemy calls it with the next waypoint position and a tau (damping) value. When the enemy is within a threshold distance of the current waypoint, it advances to the next one via a timer or `at_target` event.

`at_target` is cleaner than polling distance in a timer since it fires exactly when the target is reached, but it requires the object to be physical. A timer polling `llVecDist(llGetPos(), current_waypoint)` every 0.2–0.5 seconds works on non-physical objects and is more predictable in a scripted context. Either approach works — worth deciding before implementing.

Speed, health, and other per-enemy parameters come from the config message sent by the spawner. Different enemy types are just different parameter sets, no new scripts needed.

---

## Test Procedure

1. Place the spawner prim at the grid entrance, drop `spawner.lsl` into it, confirm it registers with the GM via `/td dump registry`
2. Type `/td wave start` in chat — spawner should rez one enemy
3. Confirm enemy registers with the GM
4. Watch the enemy walk the waypoints — each step should produce a position report visible in owner chat
5. Confirm the enemy reports `ENEMY_ARRIVED` when it reaches the final waypoint and then deletes itself
6. Spawn multiple enemies in sequence and confirm they all walk the path independently without interfering with each other
7. Check `/td dump registry` mid-wave to confirm enemies are registered while alive and deregistered on arrival

---

## What We're Still Not Doing

- No combat or damage
- No wave sequencing or enemy counts (just manual trigger for now)
- No lives counter decrement (logged only)
- No enemy types beyond a single default configuration

Ready to implement?

Let's make sure the enemies don't start up until their spawned by the spawner. I'll need to rez the prim, load the script, take it back to my inventory, then place the prim+script combo into the spawner's inventory

Good thinking. The issue is that when you save a script into a prim in Second Life, the script runs immediately — so by the time you take the prim into inventory and put it in the spawner, the script has already fired `state_entry` once and potentially tried to register or move.

The standard LSL pattern for this is to use `on_rez` with `start_param` as a signal. When a prim sits in inventory or is rezzed by hand, `start_param` is 0. When the spawner rezzes it via `llRezObject`, it can pass a non-zero value. So the enemy script just idles in a dormant state until it sees a non-zero `start_param`:

```lsl
default
{
    state_entry()
    {
        // do nothing — wait to be rezzed by the spawner
    }

    on_rez(integer start_param)
    {
        if (start_param != 0)
            state active;
    }
}

state active
{
    state_entry()
    {
        // register with GM, wait for config, begin movement
    }
}
```

When you're setting up the prim and script in-world, it fires `state_entry` in the dormant default state which does nothing. When you take it into inventory and put it in the spawner, it's inert. When the spawner calls `llRezObject("enemy", pos, vel, rot, wave_number)`, the enemy wakes into `state active` and begins its lifecycle.

The `start_param` value the spawner passes can also carry useful information — the wave number, an enemy type index, or a spawn sequence number — as a simple integer. Anything more complex gets passed via the follow-up config message from the spawner, which the design already accounts for.

The one thing to verify during setup is that the script compiles without errors when you save it into the prim, even though it doesn't do anything yet. LSL will still flag syntax errors at save time regardless of which state is active. Ready to implement?
