In Second Life, when an avatar touches a prim, the touch event provides the exact position on the surface that was clicked via `llDetectedTouchPos`. If you place a single large flat transparent prim over the entire buildable area of your map, every click on the playfield will hit that one prim, and you can do the math to figure out which grid cell was intended.

## The Core Idea

```lsl
touch_start(integer num) {
    vector touch_pos = llDetectedTouchPos(0);
    vector prim_pos = llGetPos();
    
    // get click position relative to prim center
    vector local_pos = touch_pos - prim_pos;
    
    // snap to grid
    integer grid_x = (integer)((local_pos.x + half_width) / cell_size);
    integer grid_y = (integer)((local_pos.y + half_height) / cell_size);
    
    // send to GM
    string payload = llList2Json(JSON_OBJECT, [
        "grid_x", grid_x,
        "grid_y", grid_y,
        "avatar", llDetectedKey(0)
    ]);
    llRegionSayTo(gm_key, GM_CHANNEL, "PLACEMENT_REQUEST|" + payload);
}
```

The GM receives the grid coordinates, checks its map data to confirm the cell is buildable and unoccupied, then responds with approval or rejection. The placement handler doesn't need to know anything about map state — it's just a coordinate translator.

## A Few Practical Considerations

**Z-fighting and click interference** — the transparent prim needs to sit just slightly above the tile visuals so clicks register on it rather than the decorative prims underneath. A small Z offset handles this, and setting the prim to fully transparent but keeping it visible to touch events works fine in LSL.

**Path tiles** — you might not want the overlay prim to cover path tiles at all, just the buildable area. Or you cover everything and let the GM reject placement requests on path or blocked cells, which is simpler to set up and gives you a natural place to send the player feedback about why placement failed.

**Multiple buildable regions** — if your map has disconnected buildable areas separated by the path, you could either use one large prim that covers everything (and let the GM sort out validity), or use a small number of placement handler prims each covering a contiguous buildable zone. Either works; the single-prim approach is simpler.

**Rotation** — if your map is rotated relative to the region axes, you'd need to account for the prim's rotation when converting touch position to grid coordinates. `llDetectedTouchPos` returns a region-space position, so you'd transform it into the prim's local space using the prim's rotation before doing the grid math.

The elegance here is that this prim has no state and no dependencies on game progress — it just translates spatial input into grid coordinates and passes them up. You could reset or replace it without affecting game state at all.
