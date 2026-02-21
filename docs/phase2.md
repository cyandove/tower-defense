## Phase 2 Plan: Placement Handler Prim

The goal for this phase is purely coordinate translation and communication — no map validation yet, that's phase 3. By the end of phase 2 you want to be able to click anywhere on the playfield overlay prim and see the correct grid coordinates reported back, with the message arriving at the GM.

---

## What We Need to Figure Out First

Before writing any code you need three real-world measurements from your Second Life build:

**Playfield origin** — the region XY position of the corner of your grid that corresponds to cell (0,0). This will be the bottom-left or top-left corner depending on how you orient the map.

**Cell size** — how many meters wide and deep each grid cell is. A common choice is 2m per cell, giving a 10x10 grid a 20x20m footprint.

**Overlay prim size and position** — the placement handler prim needs to exactly cover the buildable area. Its center position and X/Y dimensions need to be known so the touch offset math works correctly.

These three values become constants at the top of the placement handler script. Getting them right is the whole job — the math itself is simple once the inputs are correct.

---

## The Coordinate Translation

When the overlay prim is touched, `llDetectedTouchPos` returns a region-space XYZ. To convert that to grid coordinates:

```
local_pos = touch_pos - prim_center_pos
grid_x = floor((local_pos.x + half_prim_width) / cell_size)
grid_y = floor((local_pos.y + half_prim_height) / cell_size)
```

The addition of `half_prim_width` and `half_prim_height` shifts the origin from the prim's center to its corner, so grid (0,0) starts at the corner rather than wrapping around the center.

If your prim is rotated relative to the region axes you'll also need to counter-rotate `local_pos` using the prim's inverse rotation before doing the grid math. Worth checking whether your build is axis-aligned to avoid that complexity for now.

---

## Edge Cases to Handle

**Clicks outside the grid** — touch pos math could theoretically return negative coordinates or values >= MAP_WIDTH/HEIGHT if the prim is slightly larger than the grid, or if llDetectedTouchPos returns a position at the very edge. The script should clamp and validate before sending.

**Top face only** — the overlay prim has six faces. You only want to process touches on the top face, otherwise clicking the side of the prim sends a spurious message. `llDetectedTouchFace` returns the face index — you'd check that it matches the top face (usually face 1 on a default cube, but worth verifying in-world).

**Multiple simultaneous touches** — `touch_start` receives an integer count of how many avatars touched simultaneously. For now a single-touch assumption is fine, but worth noting for later when multiple players might be placing towers.

---

## Communication to the GM

The placement handler sends a single message to the GM on `PLACEMENT_CHANNEL`:

```
PLACEMENT_REQUEST|<grid_x>|<grid_y>|<avatar_key>
```

The GM in phase 2 just needs to acknowledge it and log what it received — no validation yet. That keeps phase 2 focused on getting the coordinates right before adding logic on top.

---

## Test Procedure

You'll want a companion debug listener on the GM side — a simple addition to the existing `listen` handler that catches `PLACEMENT_CHANNEL` messages and prints the grid coordinates to owner chat. Then:

1. Click the corner of the overlay prim closest to (0,0) and confirm you get `(0,0)` or `(0,1)` back
2. Click the opposite corner and confirm you get `(9,9)` or close to it
3. Click a spot you can visually identify — center of the grid should give roughly `(5,5)`
4. Click an edge and confirm it doesn't produce out-of-bounds coordinates
5. If you have the map dump available, click a cell you know is PATH and confirm the coordinates match what you see in the dump

The coordinate verification is the entire deliverable for phase 2. Phase 3 then takes those verified coordinates and runs them through the map validation logic with confidence that the inputs are correct.

---

## What We're Not Doing Yet

- No map validation (phase 3)
- No tower spawning or placement confirmation
- No UI feedback to the clicking avatar
- No occupancy changes to the map

Should I go ahead and implement the placement handler script and the GM listener addition for phase 2?
