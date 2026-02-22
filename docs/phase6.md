Here's the full phase 6 plan before we start writing.

**What changes and what's new**

`placement_handler.lsl` needs to present a tower type selection UI when a player clicks a valid cell. LSL's built-in option is `llDialog` — it sends a floating dialog with up to 12 buttons to a specific avatar. The handler sends a dialog listing available tower types, waits for the response on a listen handle, then forwards the selection plus grid coords to the GM as a new `TOWER_PLACE_REQUEST|<gx>|<gy>|<avatar>|<tower_type>` message. The existing `PLACEMENT_REQUEST` flow stays intact for the validation side.

`game_manager.lsl` gains a tower rezzing function. On receiving a valid `TOWER_PLACE_REQUEST` it validates the cell (same checks as before), then calls `llRezObject` with the tower object name and encodes the type ID in `start_param`. It needs to know the world position of the cell to rez at — that's `gridToWorld(gx, gy)` using the grid origin and cell size it already has from the pairing system. Wait — the GM doesn't actually store grid origin and cell size anywhere currently, that lives only in the placement handler. The GM will need to cache it. The cleanest approach: when the spawner receives `GRID_INFO` and confirms pairing, the GM also stores the grid info at that point. We add `gGridOrigin` and `gCellSize` globals to the GM and populate them when it processes `SPAWNER_PAIRED` — since the handler responds to the spawner directly, the GM can request it separately on startup, or we can have the handler proactively send it to the GM during registration. The latter is simpler.

`tower_basic.lsl` gains notecard loading as the first step before GM discovery. `start_param` encodes the tower type ID (1=basic, 2=sniper, etc.), which maps to a notecard name. Stats become globals populated from the notecard. A `dataserver` event handles line-by-line loading.

`spawner.lsl` similarly gains notecard loading for enemy stats before it registers.

New notecard format — `key=value`, `#` comments, blank lines ignored:

```
# tower_basic.cfg
tower_type_name=Basic Tower
damage=25.0
range=10.0
accuracy=0.85
falloff=0.4
attack_interval=2.0
targeting_strategy=0
```

```
# tower_sniper.cfg  
tower_type_name=Sniper Tower
damage=60.0
range=18.0
accuracy=0.95
falloff=0.15
attack_interval=5.0
targeting_strategy=0
```

```
# enemy_basic.cfg
enemy_type_name=Basic Enemy
health=100.0
speed=2.0
enemies_per_wave=5
spawn_interval=3.0
```

**Tower type registry**

The GM needs a mapping from type ID to object name and display name. A simple strided list works:

```lsl
// [type_id, object_name, display_name, ...]
list gTowerTypes = [
    1, "Tower", "Basic Tower",
    2, "Tower", "Sniper Tower"
];
integer TOWER_TYPE_STRIDE = 3;
```

Both types point to the same object name `"Tower"` since it's one object. `start_param` carries the type ID so the tower knows which notecard to load.

**`llDialog` flow in placement handler**

```
player clicks grid cell
  → handler validates cell is buildable (ask GM)
  → on PLACEMENT_OK: send llDialog to avatar with tower type buttons
  → player selects type
  → handler sends TOWER_PLACE_REQUEST to GM
  → GM rezzes tower with type-encoded start_param
```

This means placement approval now happens in two stages — the cell check happens first (so the player gets immediate feedback on invalid clicks), then the type selection, then the actual rezzing and cell occupation. The cell should be reserved between approval and type selection so two players can't race to place on the same cell. We add a `CELL_RESERVED` state alongside `CELL_EMPTY` and `CELL_OCCUPIED`, with a timeout (say 30 seconds) that clears the reservation if the player doesn't complete their selection.

**New channel**

`TOWER_PLACE_CHANNEL = -2012` for the placement handler → GM tower rez request, separate from `PLACEMENT_CHANNEL` which handles the cell validation query.

**GM grid info storage**

Add `gGridOrigin` and `gGridCellSize` globals. Populate them by having the placement handler include its grid info in its registration message — extend the registration to `REGISTER|4|0|0|<origin_x>|<origin_y>|<origin_z>|<cell_size>`. The GM stores it when it processes placement handler registration. Clean, no extra round-trip.

---

**Files touched:**
- `game_manager.lsl` — grid info storage, tower type registry, `CELL_RESERVED` state, tower rezzing, `TOWER_PLACE_CHANNEL` listener, `handleTowerPlaceRequest()`
- `placement_handler.lsl` — `llDialog` flow, `TOWER_PLACE_CHANNEL` message, grid info in registration
- `tower_basic.lsl` — notecard loading phase, `start_param` → notecard name mapping, stats as globals
- `spawner.lsl` — notecard loading phase for enemy stats

**Files unchanged:**
- `enemy_base.lsl` — enemy stats still come from spawner config message, no change needed
- `placement_handler.lsl` grid math — already correct

---

Any adjustments before we start? Specifically worth confirming: the `CELL_RESERVED` timeout duration, whether `llDialog` is the right UI (it's functional but not pretty — the alternative is a HUD object but that's a much bigger lift), and whether the tower type list should be hardcoded in the GM or also driven by a notecard.
