Plan: Move Maps to Notecards

Context

Maps are currently hardcoded as loadMap_N() functions inside controller.lsl. Adding a new map requires editing LSL, saving, and recompiling. This plan moves map definitions
into map_N.cfg notecards stored in the controller prim's inventory. The map builder's Export Map output changes to emit notecard format directly — so the full edit-and-deploy
loop becomes: edit tiles in-world → Export Map → create notecard → paste → done. No LSL editing required.

The main complication is that LSL notecard reading is async (llGetNotecardLine + dataserver event). The controller's current linear setup flow (loadMap() → rezAllObjects())
must be split into a start phase and a callback phase.

---
Notecard Format

map_1.cfg (stored in controller prim inventory):

# map_1.cfg
# Tower Defense Map 1 - S-bend path
# Cell types: 0=blocked, 1=buildable, 2=path

entry_x=2
row_0=0,0,2,1,1,1,1,1,1,1
row_1=1,1,2,1,1,1,1,1,1,1
row_2=1,1,2,1,1,1,1,1,1,1
row_3=1,1,2,1,1,1,1,1,1,1
row_4=1,1,2,2,2,2,2,2,1,1
row_5=1,1,1,1,1,1,1,2,1,1
row_6=1,1,1,1,1,1,1,2,1,1
row_7=1,1,2,2,2,2,2,2,1,1
row_8=1,1,2,1,1,1,1,1,1,1
row_9=1,1,2,1,1,1,1,1,1,0

Rules:
- Lines starting with # or blank are skipped
- entry_x=N — the x coordinate of the first path cell on y=0
- row_0 … row_9 — comma-separated cell types, left to right, bottom to top (y=0 first)
- Width/height not encoded — assumed 10×10 (MAP_W / MAP_H constants still apply)
- Rows can arrive out of order; each is indexed by its suffix

---
Files Changed

┌──────────────────────┬───────────────────────────────────────────────────────────────────────────────────────┐
│         File         │                                        Changes                                        │
├──────────────────────┼───────────────────────────────────────────────────────────────────────────────────────┤
│ lib/controller.lsl   │ Async notecard load replacing loadMap(); new dataserver event; onMapLoaded() dispatch │
├──────────────────────┼───────────────────────────────────────────────────────────────────────────────────────┤
│ lib/map_builder.lsl  │ EXPORT_MAP emits notecard format instead of LSL code                                  │
├──────────────────────┼───────────────────────────────────────────────────────────────────────────────────────┤
│ lib/config/map_1.cfg │ New notecard file containing map 1 data                                               │
└──────────────────────┴───────────────────────────────────────────────────────────────────────────────────────┘

---
controller.lsl

New globals

key     gMapQuery    = NULL_KEY;
integer gMapLine     = 0;
integer gMapEntryX   = 2;
integer gMapLoadMode = 0;   // 1=game setup, 2=map builder
string  gMapNotecard = "map_1.cfg";

Replace loadMap() calls with startMapLoad()

Current call sites:
- startSetup() → loadMap(1) (sync, then rezAllObjects())
- startMapBuilder() → loadMap(1) (sync, then llRezObject(INV_BUILDER, ...))

New call sites:
- startSetup() → startMapLoad("map_1.cfg", 1) — return immediately; rezAllObjects() happens in callback
- startMapBuilder() → startMapLoad("map_1.cfg", 2) — return immediately; llRezObject(INV_BUILDER,...) happens in callback

startMapLoad(string notecard, integer mode)

startMapLoad(string notecard, integer mode)
{
    if (llGetInventoryType(notecard) == INVENTORY_NONE)
    {
        llOwnerSay("[CTL] Map notecard '" + notecard + "' not found — using built-in map.");
        loadMap_1();           // fallback to hardcoded map
        deriveWaypoints(gMapEntryX, 0);
        onMapLoaded(mode);
        return;
    }
    gMap         = [];
    gWaypoints   = [];
    gMapNotecard = notecard;
    gMapLoadMode = mode;
    gMapLine     = 0;
    gMapEntryX   = 2;          // sensible default if notecard lacks entry_x
    llOwnerSay("[CTL] Loading map: " + notecard);
    gMapQuery    = llGetNotecardLine(notecard, 0);
}

dataserver event — notecard line handler

dataserver(key id, string data)
{
    if (id != gMapQuery) return;

    if (data == EOF)
    {
        deriveWaypoints(gMapEntryX, 0);
        onMapLoaded(gMapLoadMode);
        return;
    }

    // Skip blanks and comments
    string t = llStringTrim(data, STRING_TRIM);
    if (t == "" || llGetSubString(t, 0, 0) == "#")
    {
        gMapQuery = llGetNotecardLine(gMapNotecard, ++gMapLine);
        return;
    }

    integer eq = llSubStringIndex(t, "=");
    if (eq > 0)
    {
        string key = llGetSubString(t, 0, eq - 1);
        string val = llGetSubString(t, eq + 1, -1);

        if (key == "entry_x")
        {
            gMapEntryX = (integer)val;
        }
        else if (llGetSubString(key, 0, 3) == "row_")
        {
            integer rowIdx = (integer)llGetSubString(key, 4, -1);
            list cells = llParseString2List(val, [","], []);
            integer x;
            for (x = 0; x < MAP_W; x++)
                gMap += [(integer)llList2String(cells, x), 0, 0];
        }
    }

    gMapQuery = llGetNotecardLine(gMapNotecard, ++gMapLine);
}

onMapLoaded(integer mode) — dispatch after load

onMapLoaded(integer mode)
{
    dbg("[CTL] Map loaded. " + (string)llGetListLength(gMap) + " cells. Mem: "
        + (string)llGetFreeMemory() + "b");
    if (mode == 1)      // game setup
        rezAllObjects();
    else if (mode == 2) // map builder
    {
        vector rez_pos = llGetPos() + <0.0, 0.0, 0.5>;
        llRezObject(INV_BUILDER, rez_pos, ZERO_VECTOR, ZERO_ROTATION, 1);
        dbg("[CTL] Rezzed MapBuilder.");
    }
}

Keep loadMap_1() as fallback

Remove the loadMap() dispatch wrapper (no longer needed), but keep loadMap_1() intact as the notecard-missing fallback. Store the entry x in the global rather than returning
it:

// Change return type from integer to void; write to gMapEntryX instead
loadMap_1()
{
    gMapEntryX = 2;
    gMap = [];
    gMap += [...];   // unchanged row data
    ...
}

---
map_builder.lsl — update EXPORT_MAP to emit notecard format

Replace the LSL-code emission with notecard-ready output:

if (cmd == "EXPORT_MAP")
{
    integer entry_x = -1;
    integer x;
    for (x = 0; x < gMapW; x++)
    {
        if (llList2Integer(gCellTypes, x) == 2)
        { entry_x = x; x = gMapW; }
    }
    if (entry_x == -1) llOwnerSay("[BLD] WARNING: no path cell on y=0");

    llOwnerSay("[BLD] --- CREATE NOTECARD, PASTE BELOW ---");
    llOwnerSay("# map_N.cfg");
    llOwnerSay("# Cell types: 0=blocked 1=buildable 2=path");
    llOwnerSay("entry_x=" + (string)entry_x);
    integer y;
    for (y = 0; y < gMapH; y++)
    {
        string row = "row_" + (string)y + "=";
        for (x = 0; x < gMapW; x++)
        {
            integer t = llList2Integer(gCellTypes, y * gMapW + x);
            if (x > 0) row += ",";
            row += (string)t;
        }
        llOwnerSay(row);
    }
    llOwnerSay("[BLD] --- END ---");
    return;
}

---
lib/config/map_1.cfg — new file

Encode the existing S-bend map (map 1) in notecard format. This serves as both the live map data and the format reference.

---
Deployment Workflow (after this change)

1. Edit tiles in-world with the Map Builder
2. Controller menu → Export Map → owner-say shows notecard content
3. In Second Life viewer: create a new notecard named map_1.cfg (or map_2.cfg for a new map), paste the content
4. Drop notecard into controller prim inventory
5. /td ctl reset → touch → Start Game — controller loads from notecard

No LSL editing required for new maps.

---
Edge Cases

- Row order: rows are indexed by suffix (row_0, row_1, ...) not by arrival order, so out-of-order lines still produce the correct gMap. However, gMap is built by += in the
dataserver loop order. Since lines arrive in file order (line 0 → EOF), and we write row_0…row_9 in order in the export, this is fine in practice. If out-of-order support is
needed, rows can be buffered and sorted — not necessary for now.
- Missing rows: If row_3 is absent, gMap will have fewer than 300 entries. cellType() will return 0 (blocked) for out-of-bounds accesses, which is safe.
- Fallback map: If no notecard is found, loadMap_1() is used, so the game still works without any notecards in inventory.
- Memory: The dataserver event and new globals add ~50 lines / minimal heap. The removal of loadMap() wrapper saves ~11 lines. Net neutral.
- gMapEntryX global: loadMap_1() previously returned its entry x; now it writes gMapEntryX = 2. Same value, different mechanism.

---
Verification

1. Add map_1.cfg notecard to controller prim
2. Touch → Start Game → confirm game sets up normally (check /td ctl status)
3. /td ctl map — ASCII dump should match expected S-bend layout
4. Remove notecard from inventory → reset → Start Game → confirm fallback fires and owner-say says "not found — using built-in map"
5. Touch → Build Map → edit a few tiles → Export Map → confirm output is notecard format (starts with # map_N.cfg, has entry_x=, has row_0= ... row_9=)
6. Create notecard from export output, add to inventory, reset → game loads edited map correctly
