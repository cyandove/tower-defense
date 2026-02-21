## Phase 3 Plan: Map Validation and Placement Response

The goal is to close the loop on placement requests — the GM receives a request, validates it against the map, and sends a response back to the placement handler, which then relays the outcome to the clicking avatar.

---

## What the GM Needs to Validate

When a placement request arrives the GM checks three things in order:

**1. Bounds** — already handled by the placement handler before the message is sent, but the GM should defensively re-check since in future any script could send a placement request directly.

**2. Cell type** — `getCellType()` already exists. The cell must be `CELL_BUILDABLE` or the request is rejected with a reason.

**3. Occupancy** — `getCellOccupied()` already exists. The cell must be `CELL_EMPTY` or the request is rejected with a reason.

If all three pass, the GM marks the cell occupied, sends an approval response, and logs the change. At this phase there's no actual tower being spawned yet — that comes in phase 5. The approval just reserves the cell so subsequent clicks on the same cell are correctly rejected.

---

## Response Messages

The GM sends responses back to the placement handler on a new `PLACEMENT_RESPONSE_CHANNEL`. The placement handler relays the outcome to the avatar via `llRegionSayTo` on a dialog or via `llInstantMessage`. For now a simple `llSay` to the avatar is fine for testing.

Response format:

```
PLACEMENT_OK|<grid_x>|<grid_y>
PLACEMENT_DENIED|<grid_x>|<grid_y>|<reason>
```

Reasons cover the rejection cases cleanly:
- `OUT_OF_BOUNDS`
- `NOT_BUILDABLE`
- `CELL_OCCUPIED`

---

## Changes Needed

**In the GM:**
- Replace the phase 2 stub body of `handlePlacementRequest` with real validation logic
- Call `setCellOccupied` on approval
- Send `PLACEMENT_OK` or `PLACEMENT_DENIED` back to the placement handler on `PLACEMENT_RESPONSE_CHANNEL`
- Add `PLACEMENT_RESPONSE_CHANNEL = -2008` to channel constants
- Add a new debug command `/td set <x> <y> <type>` so you can manually flip cells during testing without restarting the GM

**In the placement handler:**
- Add a listener on `PLACEMENT_RESPONSE_CHANNEL`
- Handle `PLACEMENT_OK` and `PLACEMENT_DENIED` responses
- Relay the outcome to the avatar with `llRegionSayTo`

---

## The Debug Set Command

This is worth adding now because without it, verifying rejection cases requires editing `initMap()` and restarting the GM every time. With `/td set x y type` you can flip any cell to PATH, BLOCKED, or BUILDABLE from chat and immediately test all three rejection reasons. Something like:

```
/td set 3 3 path     → makes (3,3) a path cell
/td set 3 3 blocked  → makes (3,3) blocked
/td set 3 3 build    → restores (3,3) to buildable
```

---

## Test Procedure

With map dump available you can script a complete verification:

1. Click a known `BUILDABLE` cell — should get `PLACEMENT_OK`, cell shows lowercase `b` in map dump
2. Click the same cell again — should get `PLACEMENT_DENIED|CELL_OCCUPIED`
3. Use `/td set` to make a cell `PATH`, click it — should get `PLACEMENT_DENIED|NOT_BUILDABLE`
4. Use `/td set` to make a cell `BLOCKED`, click it — should get `PLACEMENT_DENIED|NOT_BUILDABLE`
5. Use `/td set` to restore it to `BUILDABLE`, click it — should get `PLACEMENT_OK` again
6. Restart the GM and confirm the map resets cleanly with no stale occupancy

---

## What We're Still Not Doing

- No tower spawning (phase 5)
- No UI beyond chat messages to the avatar
- No currency check (that's game logic for later)
- No undo or sell-back mechanic

Ready to implement?
