Good place to pause and design carefully — the targeting and damage math will set the feel for everything else.

**What phase 5 needs to do:**

A tower script that registers with the GM, then on a timer scans the enemy position table for targets in range, picks one, rolls the hit chance, and if it hits sends a damage message directly to the enemy. The enemy takes the hit, checks its health, and dies or continues. The GM doesn't need to be in the damage resolution path at all — tower talks directly to enemy.

**Targeting**

The tower needs to know where enemies are. Two options: the tower queries the GM on each attack cycle, or the GM pushes updates to towers. Querying is simpler for a single tower — the tower sends `TARGET_REQUEST` to the GM, the GM responds with the nearest enemy key and position. For phase 5 that's fine. Later when you have many towers firing simultaneously you'd want the GM to broadcast position snapshots instead.

Range check is straightforward — `llVecDist(tower_pos, enemy_pos)` against a configurable `TOWER_RANGE`. Tower stores its own world position at registration time.

**Hit probability model**

The simplest model that still feels interesting has two factors:

- **Base accuracy** — a flat per-tower stat, say 0.85 for a basic tower
- **Range falloff** — accuracy scales down as distance increases, flooring at some minimum. Something like `hit_chance = BASE_ACCURACY * (1.0 - (dist / TOWER_RANGE) * FALLOFF_FACTOR)` where `FALLOFF_FACTOR` around 0.4 means you're at 85% at point-blank and around 51% at max range

The roll itself is just `llFrand(1.0) < hit_chance`. Miss is silent on the enemy side — the tower can play a miss particle or sound later.

**Damage message**

On a hit, the tower sends directly to the enemy on `ENEMY_CHANNEL`:

```
TAKE_DAMAGE|<amount>
```

The enemy subtracts from `gHealth`, and if health hits zero it runs the same arrival cleanup sequence — report to GM, deregister, `llDie()`. The GM just sees a deregister and an enemy disappearing from the position table, same as a natural arrival. You may want a separate `ENEMY_KILLED` report so the GM can distinguish kills from arrivals for scoring later, but that's optional for phase 5.

**Attack cycle**

Tower fires on a timer at `ATTACK_INTERVAL` (say 2.0 seconds). Each tick: query GM for nearest target in range, if one exists roll hit chance, if hit send damage. No queuing, no burst fire — keeps it simple and verifiable.

**What to verify before building more tower types**

- Does the hit rate feel right at various distances? Watch a few enemies walk the path and count hits vs misses
- Does the damage amount kill enemies in a satisfying number of hits? A basic enemy at 100hp taking 25 damage dies in 4 hits — adjust `ATTACK_INTERVAL` and damage together to tune DPS
- Does the tower correctly stop targeting when no enemies are in range?
- Does the GM's enemy position table stay consistent when enemies die to tower fire vs reaching the end?

**New channel needed**

`TOWER_REPORT_CHANNEL = -2005` already exists for tower-to-GM communication. `ENEMY_CHANNEL = -2010` already exists for tower-to-enemy damage messages. No new channels required.

**New GM additions**

A `TARGET_REQUEST` / `TARGET_RESPONSE` handler in `handleTowerReport()`. The GM receives `TARGET_REQUEST|<tower_pos_x>|<tower_pos_y>|<tower_pos_z>|<range>`, walks `gEnemyPositions`, finds the closest enemy within range, and responds with `TARGET_RESPONSE|<enemy_key>` or `TARGET_RESPONSE|NULL_KEY` if none in range.

---

Does this model sound right to you, or do you want to adjust anything before I start writing — targeting strategy (nearest vs first-in-path vs lowest-health), the falloff curve, damage numbers, attack rate?
