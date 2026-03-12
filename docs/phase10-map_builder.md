Plan: Map Builder Tool with Interactive Tiles

Context

The game board is currently a single blank flat prim with no visual distinction between cell types. We need a setup tool that rezzes a grid of individually-clickable tiles,
color-coded by cell type, with an interactive compass-rose menu for setting textures and navigating between neighbors.

---
Architecture

Three components, matching the existing rez-and-configure pattern (like GM, Handler, Spawner):

┌────────────┬─────────────────┬───────────────────────┬───────────────────────────────────────────────────────┐
│   Object   │     Script      │ Lives in inventory of │                        Purpose                        │
├────────────┼─────────────────┼───────────────────────┼───────────────────────────────────────────────────────┤
│ MapBuilder │ map_builder.lsl │ Controller prim       │ Receives map data, rezzes tiles, relays shutdown      │
├────────────┼─────────────────┼───────────────────────┼───────────────────────────────────────────────────────┤
│ MapTile    │ map_tile.lsl    │ MapBuilder prim       │ Interactive tile: click menu, texturing, neighbor nav │
└────────────┴─────────────────┴───────────────────────┴───────────────────────────────────────────────────────┘

Channel addition:

┌─────────┬──────────┬─────────────────────────────────────────┐
│ Channel │   Name   │                 Purpose                 │
├─────────┼──────────┼─────────────────────────────────────────┤
│ -2014   │ MAP_TILE │ Builder ↔ tiles, tile ↔ tile navigation │
└─────────┴──────────┴─────────────────────────────────────────┘

---
Flow

Build

1. Controller IDLE menu shows ["Start Game", "Build Map"]
2. "Build Map" → controller calls loadMap(1) (to populate gMap), rezzes MapBuilder
3. MapBuilder sends BUILDER_READY on CTRL (-2013)
4. Controller stores gBuilder_Key, sends BUILDER_CONFIG with grid geometry + cell types
5. MapBuilder rezzes 100 MapTile prims via timer (one per 0.2s tick, ~20s total)
  - Each tile at correct world position, start_param = cell_type * 10000 + gx * 100 + gy
  - Builder captures each tile's key via object_rez event (needed for linking later)
6. After last object_rez, builder broadcasts MAP_DATA on -2014 with full cell type map + cell size
7. Each tile stores the map, sets its own scale, and is ready for interaction

Tile Interaction

1. Click tile → 12-button compass-rose dialog
2. 8 neighbor buttons show type labels; clicking one opens that neighbor's menu
3. "Set Tex" → llTextBox prompts for UUID → applies texture
4. "Clear" → removes texture, reverts to type color
5. "Done" → closes dialog
6. Border tiles show --- for off-grid neighbors

Link Tiles

1. After texturing, user touches controller → "Link Tiles" option
2. Controller sends LINK_TILES to builder on CTRL
3. Builder requests PERMISSION_CHANGE_LINKS from owner (auto-granted for owned objects)
4. In run_time_permissions: iterates stored tile keys, calls llCreateLink(tile_key, TRUE) for each (~100s total due to 1.0s delay per call)
5. After all tiles linked to builder: builder calls llBreakLink(1) to unlink itself from the linkset
6. Tiles remain as a standalone 100-prim linkset; builder says "Board linked! Take it into inventory." and llDie()s
7. Controller timer detects stale builder key, auto-cleans

Key constraint: llCreateLink has a 1.0s server-side delay per call. 100 tiles = ~100 seconds. Builder reports progress every 10 tiles. This is a one-time build operation so the
 wait is acceptable.

Tile key tracking: Builder must know all tile keys. Uses timer-based rez (one tile per 0.2s tick) instead of a tight loop, so object_rez events fire between ticks and don't
overflow the 64-event LSL queue.

Cleanup

- While builder exists, controller menu shows ["Link Tiles", "Clean Up Map"]
- "Clean Up Map" → SHUTDOWN to builder → builder broadcasts SHUTDOWN on -2014 → all tiles die → builder dies
- Controller clears gBuilder_Key and frees gMap

---
Message Formats

On CTRL (-2013):
- BUILDER_READY — builder → controller
- BUILDER_CONFIG|ox|oy|oz|cell_size|map_w|map_h|t0,t1,t2,...,t99 — controller → builder
- LINK_TILES — controller → builder (triggers the link sequence)
- SHUTDOWN — controller → builder

On MAP_TILE (-2014):
- MAP_DATA|map_w|map_h|cell_size|t0,t1,t2,...,t99 — builder → all tiles (broadcast)
- OPEN_MENU|gx|gy|avatar_key — tile → all tiles (broadcast); target tile opens dialog
- SHUTDOWN — builder → all tiles (broadcast)

Cell types string is comma-separated: "0,0,2,1,1,1,1,1,1,1,1,1,2,..." (~200 chars, well under 1024 byte limit).

---
Dialog Layout

LSL displays buttons bottom-to-top, 3 per row. Button list order:

List index → Display position:
[1,2,3]     → bottom row
[4,5,6]     → row 2
[7,8,9]     → row 3
[10,11,12]  → top row

Compass rose target:
Top:     NW:type   N:type    NE:type
Row 3:   W:type    (3,4)B    E:type
Row 2:   SW:type   S:type    SE:type
Bottom:  Set Tex   Clear     Done

So the button list passed to llDialog:
["Set Tex", "Clear", "Done",
 neighborBtn("SW",-1,-1), neighborBtn("S",0,-1), neighborBtn("SE",1,-1),
 neighborBtn("W",-1,0),   centerBtn(),            neighborBtn("E",1,0),
 neighborBtn("NW",-1,1),  neighborBtn("N",0,1),   neighborBtn("NE",1,1)]

Direction offsets (grid Y increases northward, matching cellToWorld):
- N=(0,+1), S=(0,-1), E=(+1,0), W=(-1,0)
- NE=(+1,+1), NW=(-1,+1), SE=(+1,-1), SW=(-1,-1)

Button labels (max 24 bytes, all ≤10 chars):
- Neighbor: "NW:Build", "S:Path", "SE:---" (off-grid)
- Center: "(3,4)B" / "(3,4)P" / "(3,4)X" (coords + type initial)
- Actions: "Set Tex", "Clear", "Done"

---
File Changes

lib/controller.lsl — modify

New globals:
- gBuilder_Key = NULL_KEY
- INV_BUILDER = "MapBuilder"

New functions:
- buildCellTypeString() — extracts cell types from gMap stride-3 into CSV string
- startMapBuilder() — calls loadMap(1), rezzes MapBuilder
- cleanupBuilder() — sends SHUTDOWN to builder, nulls key, frees gMap/gWaypoints

Modified functions:
- showMenu() — IDLE/GAME_OVER branch: if builder exists show ["Link Tiles", "Clean Up Map"], else ["Start Game", "Build Map"]
- handleMenuResponse() — add "Build Map", "Link Tiles", and "Clean Up Map" branches
- handleControllerMessage() — add BUILDER_READY handler: store key, send BUILDER_CONFIG
- resetGame() — call cleanupBuilder() at top if builder exists
- timer() — add stale builder check: if (gBuilder_Key != NULL_KEY && llKey2Name(gBuilder_Key) == "") cleanupBuilder()

lib/map_builder.lsl — new

~120 lines. Timer-based rez with tile key tracking and linking support:
- Globals: gTileKeys list (populated via object_rez), gRezX/gRezY counters, gRezzing/gLinking flags
- state_entry: listen on CTRL + MAP_TILE + DBG_CHANNEL, send BUILDER_READY
- listen: handle BUILDER_CONFIG → parse config → start timer-based rez; handle LINK_TILES → llRequestPermissions(llGetOwner(), PERMISSION_CHANGE_LINKS); handle SHUTDOWN →
broadcast SHUTDOWN on -2014 → llDie()
- timer(): if gRezzing — rez one tile per tick (0.2s interval), advance gRezX/gRezY; when all rezzed, stop timer
- object_rez(key id): append id to gTileKeys; when length == gRezTotal, broadcast MAP_DATA on -2014
- run_time_permissions: if granted PERMISSION_CHANGE_LINKS, iterate gTileKeys calling llCreateLink(key, TRUE) for each (reports progress every 10); after all linked,
llBreakLink(1) to detach self, announce "Board linked!", llDie()
- on_rez: llResetScript()

Why timer-based rez: LSL's event queue holds ~64 events. A tight loop of 100 llRezObject calls would queue 100 object_rez events, overflowing the queue and losing tile keys.
Timer-based rez (one per tick) lets object_rez fire between ticks.

lib/map_tile.lsl — new

~200 lines. Two states:
- default (dormant): on_rez decodes start_param → cell_type * 10000 + gx * 100 + gy, stores gGridX/gGridY/cell_type, enters state active
- state active:
  - state_entry: listen on MAP_TILE + DBG_CHANNEL, color self by cell type, generate menu channel from key
  - listen on MAP_TILE: handle MAP_DATA (store map, set scale from cell_size), OPEN_MENU (show dialog if coords match), SHUTDOWN (die)
  - listen on menu channel: parse dialog response — direction buttons → broadcast OPEN_MENU, "Set Tex" → llTextBox, "Clear" → revert color, "Done" → close, center → reopen own
menu
  - listen on tex channel: validate UUID format (36 chars), apply llSetTexture
  - touch_start: call showTileMenu(avatar)
  - timer: 30s cleanup of stale menu/texture listeners

Default tile colors:
- Buildable (1): green <0.2, 0.7, 0.2>
- Path (2): brown <0.6, 0.4, 0.2>
- Blocked (0): dark gray <0.25, 0.25, 0.25>

Key helpers:
- getCellType(x, y) — bounds-checked lookup into stored map list; returns -1 for off-grid
- typeLabel(t) — "Build", "Path", "Block", or "---"
- neighborBtn(dir, dx, dy) — returns "DIR:Label" string
- centerBtn() — returns "(gx,gy)T" string
- buildMenuButtons() — assembles the 12-button list
- applyColor(cell_type) — sets prim color by type

---
Edge Cases

- Builder already exists: Menu shows "Clean Up Map" instead of "Build Map"; can't double-rez
- Builder disappears (manual delete/region restart): Controller timer detects stale key via llKey2Name, auto-cleans
- Partial rez failure (prim limit): Tiles that rezzed work normally; missing tiles just don't exist
- Texture validation: Check UUID string length == 36; invalid UUIDs show SL's missing-texture placeholder
- Multiple avatars: Single menu listener per tile; second touch replaces first avatar's menu (acceptable for build tool)
- Game start while building: startSetup() calls cleanupBuilder() first if builder is active

---
In-World Setup (manual, one-time)

1. Create a flat box prim (z-scale 0.05), name it "MapTile", put map_tile.lsl inside, take to inventory
2. Create a prim, name it "MapBuilder", put map_builder.lsl + the MapTile object inside, take to inventory
3. Put the MapBuilder object into the controller prim's inventory

---
Verification

1. Touch controller in IDLE → menu shows "Start Game" and "Build Map"
2. Click "Build Map" → ~20s later, 100 colored tiles appear in grid layout
3. Click any tile → compass-rose dialog with correct neighbor types
4. Click a neighbor button → that neighbor's dialog opens
5. Click "Set Tex" → text box appears → paste UUID → texture applies
6. Click "Clear" → texture removed, color restored
7. Border tile → off-grid neighbors show "---"
8. Touch controller → menu shows "Link Tiles" and "Clean Up Map"
9. Click "Link Tiles" → progress reports every 10 tiles → ~100s later, "Board linked!" message
10. Builder disappears; 100-tile linkset remains in-world ready to take into inventory
11. Alternatively: "Clean Up Map" → all tiles and builder disappear
12. Touch controller → back to "Start Game" / "Build Map"
