Let me think through what phase 1 actually needs to deliver before writing any code.

The Game Manager in phase 1 needs to do three things: define and store the map, accept registration messages from other objects, and run a heartbeat to confirm registered objects are still alive. Everything else — wave management, combat, scoring — comes later.

---

## Data Structures

The map is a flat list in LSL, used as a pseudo-2D grid. Since LSL doesn't have arrays of arrays, you encode the grid as a strided list where each cell occupies a fixed number of entries:

```lsl
// map constants
integer MAP_WIDTH = 10;
integer MAP_HEIGHT = 10;
integer CELL_STRIDE = 3;  // type, occupied, reserved

// cell types
integer CELL_BLOCKED   = 0;
integer CELL_BUILDABLE = 1;
integer CELL_PATH      = 2;

// occupied flags
integer CELL_EMPTY    = 0;
integer CELL_OCCUPIED = 1;
```

The map list is initialized at startup and looks like:

```lsl
list gMap = [];  // MAP_WIDTH * MAP_HEIGHT * CELL_STRIDE entries

initMap() {
    integer i;
    integer total = MAP_WIDTH * MAP_HEIGHT;
    for (i = 0; i < total; i++) {
        gMap += [CELL_BUILDABLE, CELL_EMPTY, 0];
    }
    // then stamp path cells and blocked cells over the defaults
    setCell(2, 0, CELL_PATH, CELL_EMPTY);
    setCell(2, 1, CELL_PATH, CELL_EMPTY);
    // ... etc
}
```

Helper functions for reading and writing cells:

```lsl
integer cellIndex(integer x, integer y) {
    return (y * MAP_WIDTH + x) * CELL_STRIDE;
}

integer getCellType(integer x, integer y) {
    return llList2Integer(gMap, cellIndex(x, y));
}

integer getCellOccupied(integer x, integer y) {
    return llList2Integer(gMap, cellIndex(x, y) + 1);
}

setCell(integer x, integer y, integer type, integer occupied) {
    integer idx = cellIndex(x, y);
    gMap = llListReplaceList(gMap, [type, occupied, 0], idx, idx + 2);
}
```

---

## Registration

Objects register themselves when they rez by sending a message on a known channel. The GM maintains a registry as a strided list:

```lsl
// registry entry layout
// key, type, pos_x, pos_y, last_seen_timestamp
integer REG_STRIDE = 5;

integer REG_TYPE_TOWER   = 1;
integer REG_TYPE_ENEMY   = 2;
integer REG_TYPE_SPAWNER = 3;

list gRegistry = [];
```

The registration handler parses an incoming message and appends a new entry:

```lsl
registerObject(key id, integer obj_type, vector pos) {
    // check for duplicate registration first
    integer existing = findRegistryEntry(id);
    if (existing != -1) {
        // update timestamp only
        gRegistry = llListReplaceList(gRegistry, 
            [(integer)llGetTime()], 
            existing + 4, existing + 4);
        return;
    }
    gRegistry += [(string)id, obj_type, (integer)pos.x, (integer)pos.y, (integer)llGetTime()];
    llOwnerSay("Registered: " + (string)id + " type=" + (string)obj_type);
}

integer findRegistryEntry(key id) {
    return llListFindList(gRegistry, [(string)id]);
}

deregisterObject(key id) {
    integer idx = findRegistryEntry(id);
    if (idx != -1) {
        gRegistry = llDeleteSubList(gRegistry, idx, idx + REG_STRIDE - 1);
    }
}
```

---

## Heartbeat

The GM runs a periodic timer that pings all registered objects and tracks which ones respond. Objects that miss too many pings get culled from the registry automatically — this handles cases where prims are deleted without sending a clean deregistration message.

```lsl
integer HEARTBEAT_INTERVAL = 10;  // seconds
integer HEARTBEAT_TIMEOUT  = 3;   // missed beats before culling

integer gHeartbeatSeq = 0;  // incrementing sequence number

sendHeartbeat() {
    gHeartbeatSeq++;
    integer i;
    integer count = llGetListLength(gRegistry) / REG_STRIDE;
    for (i = 0; i < count; i++) {
        integer idx = i * REG_STRIDE;
        key target = (key)llList2String(gRegistry, idx);
        llRegionSayTo(target, HEARTBEAT_CHANNEL, 
            "PING|" + (string)gHeartbeatSeq);
    }
}

receiveHeartbeatAck(key id, integer seq) {
    if (seq != gHeartbeatSeq) return;  // stale response, ignore
    integer idx = findRegistryEntry(id);
    if (idx != -1) {
        gRegistry = llListReplaceList(gRegistry,
            [(integer)llGetTime()],
            idx + 4, idx + 4);
    }
}

cullStaleObjects() {
    float now = llGetTime();
    float timeout_threshold = now - (HEARTBEAT_INTERVAL * HEARTBEAT_TIMEOUT);
    integer i = llGetListLength(gRegistry) / REG_STRIDE - 1;
    // iterate backwards so deletions don't shift indices we haven't visited
    for (; i >= 0; i--) {
        integer idx = i * REG_STRIDE;
        float last_seen = (float)llList2Integer(gRegistry, idx + 4);
        if (last_seen < timeout_threshold) {
            key culled = (key)llList2String(gRegistry, idx);
            llOwnerSay("Culling stale object: " + (string)culled);
            gRegistry = llDeleteSubList(gRegistry, idx, idx + REG_STRIDE - 1);
        }
    }
}
```

The timer fires `sendHeartbeat` and `cullStaleObjects` on each tick.

---

## Channel Layout

Define all channels at the top of the GM script as constants so they're easy to change and reference from other scripts:

```lsl
integer GM_REGISTER_CHANNEL   = -2001;  // objects announce themselves here
integer GM_DEREGISTER_CHANNEL = -2002;  // objects say goodbye here
integer HEARTBEAT_CHANNEL     = -2003;  // GM pings, objects ack
integer PLACEMENT_CHANNEL     = -2004;  // placement handler sends requests here
integer TOWER_REPORT_CHANNEL  = -2005;  // towers report kills, etc
integer ENEMY_REPORT_CHANNEL  = -2006;  // enemies report position, arrival, death
```

Each llListen call in the GM corresponds to one of these. You'll want a shared constants notecard or a shared header pattern so other scripts use the same values without you having to keep them in sync manually.

---

## Phase 1 GM Script Skeleton

Putting it all together, the GM script structure in phase 1 looks like this:

```lsl
// === constants ===
// channels, cell types, reg types, strides (as above)

// === state ===
list gMap = [];
list gRegistry = [];
integer gHeartbeatSeq = 0;

// === map helpers ===
// cellIndex, getCellType, getCellOccupied, setCell, initMap

// === registry helpers ===
// registerObject, findRegistryEntry, deregisterObject

// === heartbeat helpers ===
// sendHeartbeat, receiveHeartbeatAck, cullStaleObjects

default {
    state_entry() {
        initMap();
        llListen(GM_REGISTER_CHANNEL,   "", NULL_KEY, "");
        llListen(GM_DEREGISTER_CHANNEL, "", NULL_KEY, "");
        llListen(HEARTBEAT_CHANNEL,     "", NULL_KEY, "");
        llSetTimerEvent(HEARTBEAT_INTERVAL);
        llOwnerSay("Game Manager ready.");
    }

    listen(integer channel, string name, key id, string msg) {
        list parts = llParseString2List(msg, ["|"], []);
        string cmd = llList2String(parts, 0);

        if (channel == GM_REGISTER_CHANNEL) {
            integer obj_type = (integer)llList2String(parts, 1);
            vector pos = (vector)llList2String(parts, 2);
            registerObject(id, obj_type, pos);
        }
        else if (channel == GM_DEREGISTER_CHANNEL) {
            deregisterObject(id);
        }
        else if (channel == HEARTBEAT_CHANNEL) {
            if (cmd == "ACK") {
                integer seq = (integer)llList2String(parts, 1);
                receiveHeartbeatAck(id, seq);
            }
        }
    }

    timer() {
        sendHeartbeat();
        cullStaleObjects();
    }
}
```

---

## What to Verify at the End of Phase 1

Before moving on you want to be able to confirm:

- Dropping any object into the region and having it register correctly, with llOwnerSay confirming receipt
- The heartbeat cycling and timestamps updating for live objects
- Deleting a registered object and watching the GM cull it after the timeout window
- Map helper functions returning correct cell types for known coordinates — worth writing a small debug command that dumps the map state to chat so you can visually inspect it

That last point is worth investing a little time in now. A map dump utility will save you significant debugging time in phase 2 when placement validation logic depends on the map being correct.
