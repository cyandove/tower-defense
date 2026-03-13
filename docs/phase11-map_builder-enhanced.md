Plan: Map Builder → Game Integration

Context

The Map Builder creates a visual board from the map defined in controller.lsl. After linking, the board is a 100-prim linkset — but it is purely decorative. There is no path
back: you can't change tile types interactively, and you can't export the edited map data into the game. This plan adds:

1. Cell type editing in the tile dialog — change a tile to Build / Path / Blocked in-world
2. Export Map — output a complete loadMap_N() function body via owner-say, ready to paste into controller.lsl

After exporting, the deployment workflow is:
- Paste the exported function into controller.lsl as loadMap_N()
- Rez the linked MapTile board at the controller prim's SW corner (grid origin) as the visual floor
- Start the game — the PlacementHandler flat prim covers the board and handles touch events

---
Files Changed

┌─────────────────────┬─────────────────────────────────────────────────────────────────────────────────────────────┐
│        File         │                                           Changes                                           │
├─────────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────┤
│ lib/map_tile.lsl    │ Replace "Clear" with "Type" button; add secondary type-change dialog; broadcast TYPE_CHANGE │
├─────────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────┤
│ lib/map_builder.lsl │ Listen for TYPE_CHANGE; update gCellTypes; add EXPORT_MAP handler                           │
├─────────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────┤
│ lib/controller.lsl  │ Add "Export Map" button in builder-active menu; handle choice                               │
└─────────────────────┴─────────────────────────────────────────────────────────────────────────────────────────────┘

---
map_tile.lsl

buildMenuButtons() — swap "Clear" → "Type"

The 12-button limit is already saturated. Replace "Clear" with "Type" (texture clear is a less important operation; can be done by not applying a texture).

// Bottom row was: "Set Tex", "Clear", "Done"
// New bottom row:
return [
    "Set Tex", "Type", "Done",
    ...  // rows 2–4 unchanged
];

New branch in menu listen handler — handle "Type" and type names

if (msg == "Type")
{
    // Secondary dialog — same channel, re-register one-shot listener
    gMenuHandle = llListen(gMenuChannel, "", gMenuAvatar, "");
    llDialog(gMenuAvatar,
        "Set type for (" + (string)gGridX + "," + (string)gGridY + "):",
        ["Blocked", "Path", "Build"], gMenuChannel);
    return;
}

if (msg == "Build" || msg == "Path" || msg == "Blocked")
{
    integer newType;
    if      (msg == "Build")   newType = 1;
    else if (msg == "Path")    newType = 2;
    else                       newType = 0;
    gCellType = newType;
    applyColor(gCellType);
    llSay(MAP_TILE, "TYPE_CHANGE"
        + "|" + (string)gGridX
        + "|" + (string)gGridY
        + "|" + (string)newType);
    showTileMenu(gMenuAvatar);
    return;
}

Note: gCellTypes in the tile script stores the full map. After changing type, also update the local copy so neighbour-button labels reflect the change:
integer selfIdx = gGridY * gMapW + gGridX;
gCellTypes = llListReplaceList(gCellTypes, [newType], selfIdx, selfIdx);

---
map_builder.lsl

Listen for TYPE_CHANGE — update gCellTypes

In the listen handler, MAP_TILE channel, add before the SHUTDOWN check:

if (cmd == "TYPE_CHANGE")
{
    // TYPE_CHANGE|gx|gy|new_type
    if (llGetListLength(parts) < 4) return;
    integer tx  = (integer)llList2String(parts, 1);
    integer ty  = (integer)llList2String(parts, 2);
    integer nt  = (integer)llList2String(parts, 3);
    integer idx = ty * gMapW + tx;
    gCellTypes  = llListReplaceList(gCellTypes, [nt], idx, idx);
    dbg("[BLD] TYPE_CHANGE (" + (string)tx + "," + (string)ty
        + ")=" + (string)nt);
    return;
}

Add EXPORT_MAP handler — in CTRL channel listen block

if (cmd == "EXPORT_MAP")
{
    // Find entry_x: first path (type 2) cell on y=0
    integer entry_x = -1;
    integer x;
    for (x = 0; x < gMapW; x++)
    {
        if (llList2Integer(gCellTypes, x) == 2)
        { entry_x = x; x = gMapW; }
    }
    llOwnerSay("[BLD] --- COPY FROM NEXT LINE ---");
    llOwnerSay("integer loadMap_N()");
    llOwnerSay("{");
    llOwnerSay("    gMap = [];");
    integer y;
    for (y = 0; y < gMapH; y++)
    {
        string row = "    gMap += [";
        for (x = 0; x < gMapW; x++)
        {
            integer t = llList2Integer(gCellTypes, y * gMapW + x);
            row += (string)t + ",0,0";
            if (x < gMapW - 1) row += ", ";
        }
        row += "]; // y" + (string)y;
        llOwnerSay(row);
    }
    llOwnerSay("    return " + (string)entry_x
        + ";   // entry cell x on y=0");
    llOwnerSay("}");
    llOwnerSay("[BLD] --- END ---");
    return;
}

---
controller.lsl

Builder-active menu: add "Export Map"

Current buttons list when builder is active (line ~808):
buttons = ["Link Tiles", "Clean Up Map"];
Change to:
buttons = ["Link Tiles", "Export Map", "Clean Up Map"];

Handle "Export Map" choice (near line ~867)

else if (choice == "Export Map")
{
    if (gBuilder_Key != NULL_KEY)
        llRegionSayTo(gBuilder_Key, CTRL, "EXPORT_MAP");
}

---
Edge Cases

- TYPE_CHANGE before MAP_DATA: A tile could theoretically change type before broadcastMapData(). gCellTypes in the builder is fully populated before tiles are even rezzed (set
during BUILDER_CONFIG parsing), so any TYPE_CHANGE arriving after that is a valid update. Safe.
- Export with no path on y=0: entry_x would be -1. The output would still be valid LSL code; deriveWaypoints(-1, 0) would fail to find a start cell and output no waypoints — a
separate validation issue. Add a guard: if (entry_x == -1) llOwnerSay("[BLD] WARNING: no path cell on y=0");
- llOwnerSay truncation: LSL truncates llOwnerSay messages at 1024 chars. Each row line is     gMap += [t,0,0, t,0,0, ...]; ≈ 10 × 5 chars + overhead ≈ 80 chars. Well within
limit.
- 12-button dialog limit: Removing "Clear" frees one slot for "Type" without exceeding 12.

---
Verification

1. Start Map Builder (Build Map from controller menu)
2. Touch a tile → compass dialog; click Type → secondary dialog shows Build/Path/Blocked
3. Click "Path" → tile turns brown; builder's gCellTypes updated (confirm via Debug On + touch again)
4. Continue editing a few tiles (ensure entry path is connected on y=0)
5. Controller menu → Export Map → owner-say shows complete function
6. Paste as loadMap_2() in controller.lsl; add branch in loadMap()
7. Reset + start game with new map → verify waypoints derived correctly
8. Rez linked board in-world at controller SW corner → tiles align with game grid
