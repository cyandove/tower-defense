# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

An LSL (Linden Scripting Language) tower defense game for Second Life / OpenSimulator. LSL scripts run inside in-world prims (objects); there is no local build or test runner. Development is edit-in-editor → paste into Second Life script editor → test in-world.

There are no install, build, lint, or test commands. All validation happens in-world via `llOwnerSay` debug output and the `/td` chat commands documented below.

## Repository Layout

```
lib/           — all LSL scripts (.lsl) and config notecards (.cfg)
  config/      — notecard config files for tower/enemy types and maps (map_1.cfg, …)
docs/          — design docs and per-phase notes (plain text / markdown)
plan.md        — overall phased development plan
```

## Architecture

The game runs as a multi-script system. Each script lives in its own prim.

**Controller** (`controller.lsl`) — the only prim placed manually. Owns the map definition, cell state, grid geometry, game lifecycle (SETUP → WAITING → WAVE_ACTIVE → WAVE_CLEAR → GAME_OVER), lives, score, and wave progression. Rezzes the GM, placement handler, spawner, and MapBoard on touch. Reads the map from a `map_N.cfg` notecard asynchronously via `llGetNotecardLine`/`dataserver`; falls back to the built-in `loadMap_1()` if no notecard is found. Derives waypoints from path cells via chain-follow and sends them to the spawner in a `SPAWNER_CONFIG` message. When multiple `map_*.cfg` notecards are present, shows a map-selection dialog before setup.

**Game Manager** (`game_manager.lsl`) — pure routing and registry. Tracks all registered objects (towers, enemies, spawner, handler) via heartbeat, maintains a live enemy position table, handles targeting requests from towers, and routes placement requests. Has no map state — queries the controller asynchronously for cell data (`CELL_QUERY` / `CELL_DATA`). Only one placement query can be in-flight at a time (`gPendingQuery`).

**Spawner** (`spawner.lsl`) — sits at the path entry cell. Receives `SPAWNER_CONFIG` from the controller (waypoints as world-space vectors), then spawns enemies on `WAVE_START`. Reads enemy stats from a notecard.

**Placement Handler** (`placement_handler.lsl`) — a flat prim covering the grid. Translates player touch coordinates to grid cells, runs the `llDialog` tower selection UI, and sends `PLACEMENT_REQUEST` to the GM.

**Tower** (`tower.lsl`) — reads its config from a notecard (type determined by `start_param` at rez). Requests a target from the GM each fire tick; resolves hit/miss locally using `calcHitChance()`; sends damage directly to the enemy prim. The `start_param` encodes `type_id * 10000 + gx * 100 + gy` — limits: type_id 1–9, grid coords 0–99. Both the GM's `rezTower()` and the tower's `on_rez` must agree on this encoding.

**Enemy** (`enemy.lsl`) — moves along waypoints received at rez. Reports position to the GM every ~0.5 s. On reaching the exit sends `ENEMY_ARRIVED`; on death sends `ENEMY_KILLED`. Both events propagate to the controller via the GM.

## Channel Map

All channels are negative integers to avoid public chat collision.

| Channel | Purpose |
|---------|---------|
| -2001 | GM_REGISTER |
| -2002 | GM_DEREGISTER |
| -2003 | HEARTBEAT |
| -2004 | PLACEMENT |
| -2005 | TOWER_REPORT |
| -2006 | ENEMY_REPORT |
| -2007 | GM_DISCOVERY |
| -2008 | PLACEMENT_RESPONSE |
| -2009 | SPAWNER |
| -2010 | ENEMY |
| -2011 | GRID_INFO |
| -2012 | TOWER_PLACE |
| -2013 | CONTROLLER (map queries, lifecycle, setup config) |
| -2014 | MAP_TILE (map builder ↔ tiles; board_mover SHUTDOWN) |

## Prim Inventory Setup

Each prim needs specific scripts and notecards in its inventory:

| Prim | Scripts | Notecards |
|------|---------|-----------|
| **Controller** | `controller.lsl`, `controller-animations.lsl` (optional) | `map_1.cfg` (and any other `map_*.cfg`) |
| **GameManager** | `game_manager.lsl` | `tower_types.cfg` |
| **PlacementHandler** | `placement_handler.lsl` | — |
| **Spawner** | `spawner.lsl` | `spawner.cfg` |
| **TowerBasic** | `tower.lsl`, `tower-animations.lsl` (optional) | `tower_types.cfg`, `tower_basic.cfg` |
| **TowerSniper** | `tower.lsl`, `tower-animations.lsl` (optional) | `tower_types.cfg`, `tower_sniper.cfg` |
| **Enemy** | `enemy.lsl`, `enemy-animations.lsl` (optional) | — |
| **MapTile** | `map_tile.lsl`, `board_mover.lsl` | — |
| **MapBuilder** | `map_builder.lsl` | — |

The controller prim also holds the **GameManager**, **PlacementHandler**, **Spawner**, **MapBuilder**, **MapBoard**, and all tower/enemy prim objects in its inventory — it rezzes them at setup time. Each tower prim needs all tower stats notecards listed in `tower_types.cfg` (or at minimum the one for its own type), since the tower reads `tower_types.cfg` to discover which stats notecard to load.

`board_mover.lsl` lives in every **MapTile** prim (not delivered at link time). When the MapBoard linkset is rezzed by the controller, `board_mover` in the root prim (link 1) handles positioning and SHUTDOWN; all other instances see `llGetLinkNumber() != 1` and stay inert. Do not use `llGiveInventory` to deliver `board_mover` — scripts delivered this way do not reliably start running.

## Config Notecards

Tower and enemy parameters live in `lib/config/*.cfg` — key=value format, `#` for comments.

**`tower_types.cfg`** is the central tower type registry, shared across the GM, tower, and placement handler. Format is pipe-delimited: `type_id|object_name|label|notecard`. Adding a new tower type requires only: a new stats `.cfg` file and a new line in `tower_types.cfg`. The GM reads it to look up object names and labels; the tower reads it to find its stats notecard; the GM sends labels to the placement handler at runtime.

## Combat Model

Hit resolution is purely mathematical — no physical projectiles. When a tower fires:
1. Requests target from GM (position + distance)
2. Calls `calcHitChance(distance, range, accuracy, enemy_speed, enemy_evasion)`
3. Rolls `llFrand(1.0)` and sends HIT or MISS directly to the enemy key via `llRegionSayTo`

Enemy parameters: `health`, `speed`, `evasion`, `armor`, `shield`. Tower parameters: `damage`, `range`, `accuracy`, `falloff`, `attack_interval`, `targeting_strategy`, `armor_penetration`, `splash_radius`.

## Map Format

Maps live in `lib/config/map_N.cfg` notecards dropped into the controller prim's inventory. The controller reads the active map asynchronously at startup via `llGetNotecardLine`/`dataserver`. Fields: `map_w`, `map_h`, `cell_size`, `entry_x`, `board_name`, and `row_0`…`row_N` (compact strings of `X`/`B`/`P` characters). `map_w`/`map_h`/`cell_size` must appear before any `row_N` line. If no notecard is found the controller falls back to the built-in `loadMap_1()` (same S-bend layout as `map_1.cfg`).

When multiple `map_*.cfg` notecards are present, the startup menu shows a map-selection dialog. The naming convention `map_*.cfg` is significant — `findMapNotecards()` scans for that pattern.

The internal representation is a 300-entry strided list (`gMap`, stride 3: `[type, occupied, 0]`). Cell types: `0`=blocked, `1`=buildable, `2`=path.

## In-World Debug Commands (owner chat)

```
/td ctl status   — lifecycle state, wave, lives, score, free memory
/td ctl map      — ASCII map dump (B=buildable, P=path, X=blocked, lowercase=occupied)
/td ctl reset    — clean shutdown and reset to idle
/td ctl wave     — force-start next wave (testing)
```

## Key LSL Constraints to Keep in Mind

- Each script has a **64 KB heap**. The GM and controller are the most memory-pressured scripts. Check `llGetFreeMemory()` after changes.
- `llListReplaceList` on large lists allocates a new list — minimize calls during wave-active state.
- `llRegionSayTo` (targeted) is strongly preferred over `llSay`/`llRegionSay` (broadcast) to avoid waking unintended listeners.
- Enemy position reports (~0.5 s interval per enemy) are the dominant message volume source; this scales with wave count.
- **`llRezObject` has a 10-metre limit** — objects cannot be rezzed more than 10m from the rezzer's position. Workaround: rez at the rezzer's own position, then have the rezzed object call `llSetRegionPos` (no distance limit) to move itself to the target location. Map tiles use this pattern: the builder rezzes all tiles at its own position, and each tile moves itself when it receives `MAP_DATA`.
- **Never call `llResetScript()` in `on_rez`** — after the reset, `on_rez` does not re-fire, so `start_param` is permanently lost. Instead, decode `start_param` directly in `on_rez` and manually reset all relevant globals there. This is the pattern used by `tower.lsl`, `map_builder.lsl`, and `map_tile.lsl`.
