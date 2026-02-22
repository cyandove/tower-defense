Let me think through the full design before we write anything.

**What the controller is**

A single rezzed prim at the grid origin. It's the only object you place manually — everything else gets rezzed by the controller at setup. It owns the game lifecycle, the map, and the layout. When the game ends it cleans everything up. When you want a new game you reset or touch the controller.

**Responsibilities breakdown**

*Map ownership* — `gMap`, all map helpers, `initMap()`, `gridToWorld()`, `gGridOrigin`, `gGridCellSize`. The GM loses all of this. Cell queries come in from the GM on `MAP_CHANNEL = -2013`, responses go back. Updates (set occupied, set reserved, clear) are fire-and-forget from the GM to the controller.

*Layout and rezzing* — The controller knows where everything goes. On setup it rezzes the GM at a fixed offset, the placement handler as a flat prim sized to the grid, and the spawner at the path entrance cell. It passes each one its position via `start_param` encoding or an immediate post-rez config message on a setup channel.

*Game lifecycle* — States: `SETUP → WAITING → WAVE_ACTIVE → GAME_OVER`. Touch to start. The controller tells the GM to start waves, tracks lives and score fed back from the GM, announces game over, and cleans up.

*Inventory* — The controller holds: GM object, placement handler object, spawner object, tower object, enemy object. The GM no longer needs the tower in its inventory — the controller rezzes towers directly when the GM forwards a `REZ_TOWER` request. This removes another responsibility from the GM.

Actually, pause on that — tower rezzing from the controller is cleaner but means a new message round-trip: placement handler → GM → controller → rez. The GM currently rezzes directly because it has the tower object. We could keep the tower in the GM's inventory for now and only move it to the controller in a later phase when we add multiple tower types with different objects. For phase 7 let's keep tower rezzing in the GM — it's one less message hop and one less change to get right.

*Score and lives* — `gLives` moves from the GM to the controller. The GM sends `LIFE_LOST` events; the controller decrements and checks for game over. Score (kills) similarly.

**What the GM loses**

- All map storage and helpers (`gMap`, `initMap`, `getCellType`, `getCellOccupied`, `setCell`, `setCellOccupied`, `gridToWorld`, `inBounds`)
- `gLives`, `gWaveActive`
- `startWave()` — controller sends `WAVE_START` directly to spawners

The GM becomes a pure message router and registry. It handles registration, heartbeats, enemy tracking, tower targeting, placement validation (via cell queries to the controller), and grid info forwarding. Much leaner.

**Cell query async handling in the GM**

This is the one real structural complication. Currently `handlePlacementRequest()` calls `getCellType()` and `getCellOccupied()` inline and responds synchronously. With the map in the controller, the GM has to:

1. Receive `PLACEMENT_REQUEST`
2. Send `CELL_QUERY|gx|gy` to controller
3. Store the pending request context: `[sender_key, gx, gy, avatar_key]`
4. On `CELL_DATA` response, finish validation and send `PLACEMENT_RESERVED` or `PLACEMENT_DENIED`

One pending query at a time is fine for phase 7 — placement requests are player-paced, not concurrent. A single `gPendingPlacement` strided list covering the in-flight state is enough. If two players click simultaneously the second request just waits for the first response to clear, or we drop it with a retry message.

Similarly `handleTowerPlaceRequest()` needs to query occupied state before rezzing. Same pattern.

**The setup channel**

After rezzing each object the controller needs to tell it where it is. We add `CONTROLLER_CHANNEL = -2013` for controller↔GM and controller↔spawner setup messages. Map queries also go on this channel. The controller is always the sender for setup and the listener for game events.

Actually one channel for everything between controller and GM is fine. `MAP_CHANNEL` and `CONTROLLER_CHANNEL` can be the same channel — the message prefix distinguishes them.

**Post-rez configuration**

When the controller rezzes the GM via `llRezObject`, the GM gets `on_rez(start_param)` — but start_param is only an integer, so it can only carry one value. Instead, immediately after rezzing, the controller sends a `GM_CONFIG` message on the controller channel carrying grid origin, cell size, and anything else the GM needs. The GM idles in a config-waiting state until it receives this.

Same pattern for the spawner — controller rezzes it, immediately sends `SPAWNER_CONFIG|<grid_x>|<grid_y>|<waypoints...>`. The spawner no longer has hardcoded `SPAWNER_GRID_X/Y` or `WAYPOINT_GRID`.

The placement handler is simpler — it derives its own grid geometry from its prim scale as it does now, but the controller sets its scale and position before rezzing so the geometry is already correct.

**Lifecycle state machine**

```
SETUP     — controller rezzing objects, waiting for all to register
WAITING   — all objects registered, awaiting touch to start wave
WAVE_ACTIVE — wave running, enemies spawning
WAVE_CLEAR  — all enemies dead or arrived, brief pause, next wave or game over
GAME_OVER   — lives hit zero, cleanup, display score
```

The controller drives transitions. The GM reports `ENEMY_ARRIVED` (life lost) and `ENEMY_KILLED` (score). The controller tracks both. When enemies_remaining hits zero the controller moves to `WAVE_CLEAR`. It sends the next `WAVE_START` after a delay, with escalating enemy counts.

**Wave progression**

Simple for phase 7: `enemies_per_wave = base_count + (wave_number - 1) * increment`. Say base=3, increment=2: wave 1=3 enemies, wave 2=5, wave 3=7. The controller sends `WAVE_START|<count>` to each registered spawner. The spawner already handles this.

**New files**

- `controller.lsl` — new, ~400 lines
- `game_manager.lsl` — loses map, gLives, gWaveActive, startWave; gains MAP_CHANNEL listener, pending placement query, LIFE_LOST/ENEMY_KILLED forwarding to controller
- `spawner.lsl` — loses hardcoded SPAWNER_GRID_X/Y and WAYPOINT_GRID; gains CONTROLLER_CHANNEL config receive
- `placement_handler.lsl` — minimal changes; controller sets its position/scale on rez
- `enemy_base.lsl` — no changes
- `tower_basic.lsl` — no changes

**Channels summary**

```
-2001  GM_REGISTER
-2002  GM_DEREGISTER  
-2003  HEARTBEAT
-2004  PLACEMENT
-2005  TOWER_REPORT
-2006  ENEMY_REPORT
-2007  GM_DISCOVERY
-2008  PLACEMENT_RESPONSE
-2009  SPAWNER
-2010  ENEMY
-2011  GRID_INFO
-2012  TOWER_PLACE
-2013  CONTROLLER  (map queries, lifecycle events, setup config)
```

**Open questions before writing**

Two things worth confirming:

1. **Waypoint definition** — currently hardcoded in the spawner as grid coordinates. For phase 7 should waypoints stay hardcoded in the controller (which passes them to the spawner on config), or do you want the controller to derive them from the map (follow path cells in order)? Deriving from the map is more elegant and means you only define the path once, but it requires a path-finding traversal at setup. Hardcoding in the controller is simpler and matches what we have now.

2. **Multiple maps** — you mentioned the controller could handle multiple maps. For phase 7 should we build in a map selection mechanism (controller picks from a list of map definitions) or keep it single-map and leave that for later?

Waypoint definition — Derive it. Multiple maps — We'll just have one map for now but build it so multiple can exist. Should the Placement Handler manage any of the cell state stuff? Would that simplify the architecture at all?

Good questions. Let me think through the placement handler one carefully before answering.

**On the placement handler managing cell state**

The tempting version is: placement handler owns the map, answers cell queries, handles reservation state. It's already the thing players interact with for placement, it already knows the grid geometry, and it's already a flat prim sitting on top of the grid. Giving it the map feels natural.

But there's a problem with authority. The GM is the thing that knows when a tower deregisters (dies, gets culled by heartbeat timeout), and it needs to clear that cell back to empty when that happens. If the map lives in the placement handler, the GM has to send a cell update to the placement handler every time a tower goes away — which means the GM needs to know the placement handler's key reliably, and the placement handler becomes a dependency for correct registry cleanup. That's a tighter coupling than you want between those two systems.

More importantly, the controller is already going to own map definition and layout. Having it also own runtime cell state is coherent — the controller defines the map, the controller tracks what's on it. The placement handler becomes a pure UI layer: it translates player touch input into placement requests and shows dialogs. It doesn't need to know what's on the grid, only where the player clicked.

So the cleaner split is:

- **Controller** — map definition, cell state, grid geometry, lifecycle
- **GM** — registry, routing, targeting, heartbeat, event forwarding
- **Placement handler** — player input, dialog UI, grid hit detection

The placement handler does keep its `translateToGrid()` logic because it needs to convert a touch position to grid coordinates before it can ask anything. But that's geometry, not state.

**On waypoint derivation**

Deriving waypoints from path cells is the right call and works cleanly with a single-map setup. The algorithm is a simple chain-follow: find the entry cell (path cell on the top edge), then repeatedly find the next unvisited adjacent path cell. No backtracking needed because the path is guaranteed to be a single non-branching corridor. The controller runs this once at setup and sends the result to the spawner as the existing waypoint string format.

The entry cell detection — finding which edge cell is the path entrance — can be done by scanning the top row (y=0) for a path cell, which is unambiguous for the current map. For multiple maps you'd encode the entry point as part of the map definition rather than inferring it, since a map could theoretically have its entrance on any edge.

**Revised responsibility table**

```
controller.lsl
  owns: map definitions, gMap, cell state, grid geometry
  owns: game lifecycle (states, waves, lives, score)
  owns: waypoint derivation, spawner config
  owns: object rezzing and cleanup
  listens on: -2013 (CONTROLLER_CHANNEL)
  receives: LIFE_LOST, ENEMY_KILLED, REGISTER_NOTIFY from GM

game_manager.lsl  
  owns: object registry, heartbeat, enemy positions, targeting
  owns: placement validation (queries controller for cell state)
  owns: tower rezzing (still holds tower object)
  owns: grid info forwarding (proxies controller's geometry)
  receives: all existing channels minus map stuff
  pending placement: one in-flight async cell query at a time

placement_handler.lsl
  owns: touch→grid translation, llDialog flow
  no map state, no cell knowledge
  sends PLACEMENT_REQUEST to GM as before
  receives PLACEMENT_RESERVED or PLACEMENT_DENIED from GM as before

spawner.lsl
  loses: hardcoded grid position, waypoint list
  gains: SPAWNER_CONFIG message from controller at startup
  everything else unchanged

tower_basic.lsl — no changes
enemy_base.lsl — no changes
```

**Map definition format**

Each map is a strided structure the controller holds. For phase 7 with one map, it's just constants in the controller, but structured so adding a second map means adding another block in the same format. The map definition contains:

- The 10 row literals (same as current `initMap()` encoding)
- Entry cell (gx, gy) — where the path starts, used to seed waypoint derivation
- Exit cell (gx, gy) — where enemies disappear, for validation
- Grid dimensions (width, height) — allows non-10x10 maps later
- Cell size in metres — drives geometry

The controller builds `gMap` from the selected definition and derives waypoints from it before rezzing anything else. By the time the spawner is rezzed, waypoints are already computed and ready to send.

**One subtle issue to flag**

The GM's async cell query pattern for placement validation introduces a state where the GM is waiting for a `CELL_DATA` response from the controller before it can finish handling a `PLACEMENT_REQUEST`. During that window, if the same cell gets a second request from another player, the GM needs to either queue it or drop it. For phase 7 a single pending query slot with a drop-and-retry-message is fine. Worth keeping in mind for the implementation.

---

Ready to write. The order will be: controller first (it defines everything else's interfaces), then GM (loses the most, gains the async query), then spawner (simple config change), then placement handler (minimal). Tower and enemy untouched.

Shall I go ahead?
