# LSL Tower Defense

A multi-script tower defense game for Second Life / OpenSimulator, written in LSL (Linden Scripting Language).

---

## How it works

The game runs as a set of cooperating scripts, each living in its own prim. Only the **controller** is placed manually — it rezzes everything else at setup time and tears it down on game over or reset.

| Script | Prim | Role |
|---|---|---|
| `controller.lsl` | Controller | Map, waypoints, lifecycle, lives, score, wave escalation |
| `game_manager.lsl` | GameManager | Registry, routing, targeting, placement validation |
| `spawner.lsl` | Spawner | Enemy spawning, wave execution |
| `placement_handler.lsl` | PlacementHandler | Touch-to-grid translation, tower selection dialog |
| `tower.lsl` | Tower | Attack cycle, hit resolution |
| `enemy.lsl` | Enemy | Waypoint movement, damage handling |

---

## Repository layout

```
lib/           — LSL scripts (.lsl) and config notecards (.cfg)
  config/      — tower and enemy stat notecards
  animations/  — optional animation layer scripts
docs/          — design notes per phase
plan.md        — phased development log
```

---

## In-world setup

### Step 1 — Prepare the controller prim

The controller prim's inventory must contain these objects (names must match exactly):

| Inventory item | Scripts / objects inside |
|---|---|
| `GameManager` | `game_manager.lsl` |
| `PlacementHandler` | `placement_handler.lsl` |
| `Spawner` | `spawner.lsl` |
| `MapBuilder` _(optional)_ | `map_builder.lsl`, `MapTile` object |

The `MapBuilder` object is only required if you intend to use the [Map Builder](#map-builder) tool. See that section for how to prepare the `MapBuilder` and `MapTile` objects.

### Step 2 — Prepare the GameManager prim

The GameManager prim's inventory must contain one object for each tower type. By default all types share a single object:

| Inventory item | Script inside |
|---|---|
| `Tower` | `tower.lsl` |

If you add tower types with distinct object names (see [Adding a custom tower type](#adding-a-custom-tower-type)), add a corresponding object for each name.

### Step 3 — Prepare the Spawner prim

The Spawner prim's inventory must contain:

| Inventory item | Script inside |
|---|---|
| `Enemy` | `enemy.lsl` |
| `spawner.cfg` | Enemy stats notecard |

### Step 4 — Prepare the Tower prim

The Tower prim's inventory must contain the appropriate config notecard for each tower type:

| Notecard | Tower type |
|---|---|
| `tower_basic.cfg` | Basic Tower (type ID 1) |
| `tower_sniper.cfg` | Sniper Tower (type ID 2) |

### Step 5 — Place and start

1. Place **only the controller prim** at the **south-west corner** of your intended grid area. Its position becomes the `(0,0)` grid origin.
2. Set `CELL_SIZE` in `controller.lsl` to match your in-world metre scale (default `2.0`).
3. **Touch the controller** to begin setup. It rezzes the GM, placement handler, and spawner, sends each its config, and waits for all three to report ready.
4. Once chat shows `[CTL] Ready. Touch to start wave 1.`, **touch the controller again** to start wave 1.

The placement handler (a flat prim covering the grid) can be touched by any player to open the tower selection dialog.

---

## Config notecards

Tower and enemy parameters are `key=value` text files. `#` begins a comment; blank lines are ignored.

**Tower notecard keys** (`tower_basic.cfg`, `tower_sniper.cfg`):

| Key | Type | Description |
|---|---|---|
| `tower_type_name` | string | Display name |
| `damage` | float | Damage per hit |
| `range` | float | Attack range in metres |
| `accuracy` | float | Base hit chance (0.0–1.0) |
| `falloff` | float | Accuracy reduction at max range (0.0–1.0) |
| `attack_interval` | float | Seconds between attack attempts |
| `targeting_strategy` | integer | `0` = nearest enemy |

**Spawner notecard keys** (`spawner.cfg`):

| Key | Type | Description |
|---|---|---|
| `enemy_type_name` | string | Display name |
| `enemy_health` | float | Starting health |
| `enemy_speed` | float | Movement speed (metres/sec) |
| `enemies_per_wave` | integer | Default enemies per wave (overridden by wave escalation) |
| `spawn_interval` | float | Seconds between spawns within a wave |

---

## Adding a custom tower type

Tower types are identified by an integer **type ID** (1-based). Adding a new type requires changes in four places — no other files need touching.

### 1. Create the config notecard

Create a new file in `lib/config/` following the notecard format described above. Example for a cannon tower:

```
# Cannon Tower config
tower_type_name=Cannon Tower
damage=60.0
range=8.0
accuracy=0.70
falloff=0.5
attack_interval=3.5
targeting_strategy=0
```

### 2. Register the notecard in `tower.lsl`

Add the notecard filename to the `NOTECARD_NAMES` list. The list index is `type_id - 1`, so append to give the next available ID:

```lsl
list NOTECARD_NAMES = ["tower_basic.cfg", "tower_sniper.cfg", "tower_cannon.cfg"];
//                     type 1              type 2               type 3 (new)
```

### 3. Register the type in `game_manager.lsl`

Add a branch to both `towerObjName()` and `towerLabel()`:

```lsl
string towerObjName(integer type_id)
{
    if (type_id == 1) return "Tower";
    if (type_id == 2) return "Tower";
    if (type_id == 3) return "Tower";   // new — shares the same object
    return "";
}

string towerLabel(integer type_id)
{
    if (type_id == 1) return "Basic";
    if (type_id == 2) return "Sniper";
    if (type_id == 3) return "Cannon";  // new
    return "";
}
```

`towerObjName()` is the name passed to `llRezObject`, so it must exactly match an object in the **GameManager prim's inventory**. All types can share one object (as above), or each type can use a distinct prim with its own shape, size, or animation scripts:

```lsl
string towerObjName(integer type_id)
{
    if (type_id == 1) return "Tower";         // short stubby prim
    if (type_id == 2) return "Tower Sniper";  // tall thin prim
    if (type_id == 3) return "Tower Cannon";  // wide barrel prim
    return "";
}
```

When using distinct object names, add each named object to the GameManager prim's inventory. All objects must still contain `tower.lsl` — the type ID encoded in `start_param` at rez time determines which notecard is loaded, regardless of which object was rezzed.

### 4. Add the label to `placement_handler.lsl`

Append the label string to `TOWER_LABELS`. The list index must match: `index + 1 == type_id`.

```lsl
list TOWER_LABELS = ["Basic", "Sniper", "Cannon"];
//                   type 1   type 2    type 3 (new)
```

This label appears as a button in the `llDialog` tower selection popup. Note that `llDialog` supports a maximum of **12 buttons**, so the game supports at most 12 tower types.

### Summary checklist

| File | Change |
|---|---|
| `lib/config/tower_<name>.cfg` | Create notecard with stat keys |
| `tower.lsl` — `NOTECARD_NAMES` | Append `"tower_<name>.cfg"` |
| `game_manager.lsl` — `towerObjName()` | Add `if (type_id == N) return "<ObjName>";` |
| `game_manager.lsl` — `towerLabel()` | Add `if (type_id == N) return "<Label>";` |
| `placement_handler.lsl` — `TOWER_LABELS` | Append `"<Label>"` |
| GameManager inventory | Add object named `<ObjName>` containing `tower.lsl` |

---

## Map definitions

Maps are defined as `loadMap_N()` functions in `controller.lsl`. Each map is a 300-entry list (10×10 grid, stride 3: `[type, occupied, 0]`).

Cell types:
- `0` — blocked (impassable, unbuildable)
- `1` — buildable (tower can be placed here)
- `2` — path (enemy route)

The entry cell is the path cell on `y=0` (the first row). `loadMap()` calls `deriveWaypoints()` automatically — no manual waypoint authoring needed.

To add a new map: write a `loadMap_2()` function and add a branch in `loadMap()`. To design a map interactively in-world, use the [Map Builder](#map-builder).

---

## Map Builder

The Map Builder is an interactive in-world tool for designing and texturing game board maps. It rezzes a grid of 100 clickable tiles color-coded by cell type, and can produce a finished 100-prim linkset ready for use as a game board.

### Usage

1. Touch the controller in IDLE state — the menu shows **Start Game** and **Build Map**.
2. Select **Build Map** — the controller rezzes the `MapBuilder`, which rezzes 100 `MapTile` prims over ~20 seconds (one per 0.2s tick).
3. Tiles appear color-coded by cell type:

| Color | Cell type |
|---|---|
| Green `<0.2, 0.7, 0.2>` | Buildable |
| Brown `<0.6, 0.4, 0.2>` | Path |
| Dark gray `<0.25, 0.25, 0.25>` | Blocked |

### Tile interaction

Click any tile to open a 12-button compass-rose dialog:

- The **center button** shows the tile's coordinates and type initial (e.g. `(3,4)B`)
- The **8 directional buttons** show each neighbor's type label — clicking one opens that neighbor's dialog
- **Set Tex** — prompts for a texture UUID; the texture is applied to that tile
- **Clear** — removes the applied texture and restores the type color
- **Done** — closes the dialog

Off-grid neighbor buttons show `---`.

### Finishing the board

After texturing, touch the controller and select **Link Tiles**. The builder links all 100 tiles into a single linkset — this takes ~100 seconds (one `llCreateLink` call per tile with a mandatory 1s delay each). Progress is reported every 10 tiles. When complete the builder announces `Board linked!` and removes itself. Take the 100-prim linkset into inventory.

To discard without linking, select **Clean Up Map** — all tiles and the builder are removed immediately.

### In-world setup (one-time)

The `MapBuilder` and `MapTile` objects must be created once and stored in the appropriate inventories:

1. Create a flat box prim (z-scale `0.05`), name it **`MapTile`**, add `map_tile.lsl` inside, then take it into inventory.
2. Create a prim, name it **`MapBuilder`**, add `map_builder.lsl` and the `MapTile` object inside, then take it into inventory.
3. Place the `MapBuilder` object in the **controller prim's inventory** alongside `GameManager`, `PlacementHandler`, and `Spawner`.

---

## Wave progression

Wave N spawns `WAVE_BASE + (N-1) × WAVE_INCREMENT` enemies.

With the defaults (`WAVE_BASE=3`, `WAVE_INCREMENT=2`): wave 1 = 3, wave 2 = 5, wave 3 = 7, …

Adjust these constants at the top of `controller.lsl`.

---

## Debug commands

All commands are typed in local chat (channel 0) by the **object owner** only.

### Lifecycle commands

| Command | Description |
|---|---|
| `/td ctl status` | Print lifecycle state, wave number, lives, score, enemies out, and free memory |
| `/td ctl map` | Print an ASCII map dump (`B`=buildable, `P`=path, `X`=blocked, lowercase=occupied, `r`=reserved) |
| `/td ctl wave` | Force-start the next wave (useful for testing without waiting) |
| `/td ctl reset` | Send `SHUTDOWN` to all managed objects, clean up, and return to idle |

### Debug output commands

| Command | Description |
|---|---|
| `/td ctl debug on` | Enable verbose debug output on **all scripts simultaneously** |
| `/td ctl debug off` | Disable verbose debug output on all scripts |

Debug output is **off by default**. When enabled, all six scripts print routine chatter: registration events, wave starts, hit/miss results, waypoint movement, heartbeat culls, and config confirmations.

To enable debug output at compile time (before any commands are available), set `DEBUG = TRUE` at the top of the relevant script before pasting it into the Second Life editor.

**What always prints** (regardless of debug state): error conditions such as missing inventory items, malformed notecards, unknown config keys, and rejected registrations.

---

## Channel map

All inter-script communication uses negative channels to avoid public chat.

| Channel | Purpose |
|---|---|
| `-2001` | `GM_REGISTER` |
| `-2002` | `GM_DEREGISTER` |
| `-2003` | `HEARTBEAT` |
| `-2004` | `PLACEMENT` |
| `-2005` | `TOWER_REPORT` |
| `-2006` | `ENEMY_REPORT` |
| `-2007` | `GM_DISCOVERY` |
| `-2008` | `PLACEMENT_RESPONSE` |
| `-2009` | `SPAWNER` |
| `-2010` | `ENEMY` |
| `-2011` | `GRID_INFO` |
| `-2012` | `TOWER_PLACE` |
| `-2013` | `CONTROLLER` (map queries, lifecycle, setup config) |
| `-2014` | `MAP_TILE` (map builder ↔ tiles, tile ↔ tile navigation) |
| `-2099` | `DEBUG` (owner-only broadcast toggle) |

---

## Memory notes

Each LSL script has a **64 KB heap**. The GM and controller are the most memory-pressured. Check `llGetFreeMemory()` via `/td ctl status` (controller) or the GM's link-message debug interface after making changes.

Enemy position reports fire every ~1 second per live enemy — this is the dominant message volume source and scales with wave size.
