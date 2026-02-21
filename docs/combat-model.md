That's a much cleaner approach for LSL — collision detection on projectiles is notoriously laggy and unreliable, and pooling physical prims adds complexity. Keeping damage purely in the message/math layer means the game runs the same whether the animation layer is present or not.

## Revised Combat Model

### Hit Resolution Function

Each tower script calculates a hit chance when it fires, based on a few factors:

```lsl
float calcHitChance(float distance, float range, float accuracy, float enemy_speed, float enemy_evasion) {
    float range_factor = 1.0 - (distance / range);         // falls off toward max range
    float speed_penalty = enemy_speed * 0.05;              // faster enemies are harder to hit
    float raw_chance = (accuracy * range_factor) - speed_penalty - enemy_evasion;
    return llClamp(raw_chance, 0.05, 0.95);                // always a floor and ceiling
}
```

Then the shot resolves instantly:

```lsl
float roll = llFrand(1.0);
if (roll < hit_chance) {
    // send DAMAGE message to enemy
} else {
    // send MISS message (animation layer can still play a near-miss effect)
}
```

No prim ever needs to travel anywhere. The animation layer receives the same fire event and independently plays whatever projectile or effect it wants, but the outcome is already decided the moment the tower fires.

---

## Message Flow for a Single Shot

```
Tower fires (timer tick)
  │
  ├─► llMessageLinked(ANIM_FIRE, target_pos, target_key)   ← animation layer does its thing
  │
  └─► hit resolution happens locally in tower script
        │
        ├─► HIT  → llRegionSayTo(enemy_key, DMG_CHANNEL, damage_payload)
        │
        └─► MISS → llRegionSayTo(enemy_key, DMG_CHANNEL, miss_payload)
                    ← enemy script can play a dodge/near-miss anim if it wants
```

The Game Manager doesn't need to be involved in individual shot resolution at all — towers and enemies communicate directly for combat, and only report meaningful events (kills, damage totals, enemy reaching the end) up to the GM.

---

## Enemy Parameters That Affect Combat

Rather than a flat HP value, giving enemies a small parameter set makes the probabilistic model more interesting:

- `speed` — affects hit chance penalty as shown above
- `evasion` — a flat dodge modifier (flying units, phased enemies, etc.)
- `armor` — damage reduction applied after a hit lands, before HP is decremented
- `shield` — an HP buffer that absorbs damage first and might have different resistance properties than raw HP

These values get passed into the enemy script at rez time from the spawner, so you can define enemy types in a notecard without needing separate scripts for each.

---

## Tower Parameters That Feed the Formula

Similarly, each tower's combat personality lives in its config values rather than its script:

- `accuracy` — base hit chance at ideal range
- `range` — maximum sensor distance, also the denominator in range_factor
- `damage` — base damage on a successful hit
- `fire_rate` — timer interval in seconds
- `armor_penetration` — reduces effective armor on the target
- `splash_radius` — if nonzero, tower queries the GM for enemies within that radius of the target and rolls reduced-damage hits against each of them

Splash works cleanly in this model because it's just iterating a list of nearby enemy UUIDs and sending each one a damage message with a falloff multiplier — no physics involved.

---

## Range Checking Without Sensors

Since you're not using collision, you can also reconsider whether llSensorRepeat is even the best targeting tool. An alternative is to have the **Game Manager maintain a live position table** of all active enemies, and towers request a target from the GM rather than sensing independently:

- Enemies report their position to the GM every 0.5s or so as they move
- When a tower's fire timer ticks, it sends a TARGET_REQUEST to the GM with its position and range
- The GM returns the best target UUID and distance from its table
- The tower resolves the shot locally using that distance

This centralizes position tracking, reduces the number of active sensors in the region, and lets the GM apply global logic like "this enemy has taunt and must be targeted first" without every tower needing to know about that mechanic.

---

## What the Animation Layer Receives

The functional scripts fire linked messages that give the animation layer everything it needs to do something interesting, without the animation layer needing to understand game state:

- `FIRE` + target position + hit/miss result — so it can show a clean hit effect vs a glancing miss
- `ENEMY_DAMAGED` + remaining HP fraction — so health bars or hurt animations can scale
- `ENEMY_DIED` + position — for death effects
- `TOWER_UPGRADED` — to swap mesh or particle style
- `WAVE_START` / `WAVE_END` — for ambient atmosphere effects

Because hit/miss is already resolved before the animation message goes out, the animation layer can even show a slightly different effect for a hit versus a miss — adding visual feedback that matches reality — without ever being part of the logic.
