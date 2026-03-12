# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

An LSL (Linden Scripting Language) tower defense game for Second Life / OpenSimulator. LSL scripts run inside in-world prims (objects); there is no local build or test runner. Development is edit-in-editor → paste into Second Life script editor → test in-world.

There are no install, build, lint, or test commands. All validation happens in-world via `llOwnerSay` debug output and the `/td` chat commands documented below.

## Repository Layout

```
lib/           — all LSL scripts (.lsl) and config notecards (.cfg)
  config/      — notecard config files for tower and enemy types
docs/          — design docs and per-phase notes (plain text / markdown)
plan.md        — overall phased development plan
```

## Architecture

The game runs as a multi-script system. Each script lives in its own prim.

**Controller** (`controller.lsl`) — the only prim placed manually. Owns the map definition, cell state, grid geometry, game lifecycle (SETUP → WAITING → WAVE_ACTIVE → WAVE_CLEAR → GAME_OVER), lives, score, and wave progression. Rezzes the GM, placement handler, and spawner on touch. Derives waypoints from path cells via chain-follow and sends them to the spawner in a `SPAWNER_CONFIG` message.

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

## Prim Inventory Setup

Each prim needs specific scripts and notecards in its inventory:

| Prim | Scripts | Notecards |
|------|---------|-----------|
| **Controller** | `controller.lsl`, `controller-animations.lsl` (optional) | — |
| **GameManager** | `game_manager.lsl` | `tower_types.cfg` |
| **PlacementHandler** | `placement_handler.lsl` | — |
| **Spawner** | `spawner.lsl` | `spawner.cfg` |
| **TowerBasic** | `tower.lsl`, `tower-animations.lsl` (optional) | `tower_types.cfg`, `tower_basic.cfg` |
| **TowerSniper** | `tower.lsl`, `tower-animations.lsl` (optional) | `tower_types.cfg`, `tower_sniper.cfg` |
| **Enemy** | `enemy.lsl`, `enemy-animations.lsl` (optional) | — |

The controller prim also holds the **GameManager**, **PlacementHandler**, **Spawner**, and all tower/enemy prim objects in its inventory — it rezzes them at setup time. Each tower prim needs all tower stats notecards listed in `tower_types.cfg` (or at minimum the one for its own type), since the tower reads `tower_types.cfg` to discover which stats notecard to load.

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

Maps are defined in `controller.lsl` as `loadMap_N()` functions. Each map is a 300-entry strided list (10×10 grid, stride 3: `[type, occupied, 0]`). Cell types: `0`=blocked, `1`=buildable, `2`=path. To add a map: write a new `loadMap_N()` and add a branch in `loadMap()`.

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
