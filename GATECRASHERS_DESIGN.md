# GATECRASHERS (working title)
**Jam Design Doc — v1**

Top-down 3D melee action roguelite. Gungeon energy, Hades camera, swords the size of refrigerators, and an oxygen gauge that doesn't care about your feelings.

---

## 1. Vision Statement

You are part of an exploration program that travels to alien worlds through a gate. The gate destroys all electronics in transit — so expeditions go through in analog pressure suits, carrying comically oversized melee weapons, with a finite supply of oxygen. Fight out, find the evidence, kill the thing if you can, and run home before your air runs out.

**The one-sentence pitch:** Stargate SG-1 meets Hades, but your gun doesn't work and your watch is wind-up.

**Pillars (in priority order):**
1. **Feel first.** Hitstop, knockback, camera kick, particles. If swinging the greatsword at a dummy isn't fun, nothing else matters.
2. **Readable danger.** Flat colors, strong silhouettes, telegraphed attacks. Players die because they ignored a signal, never because they couldn't see one.
3. **Push your luck.** Oxygen is the run. Every decision is "deeper or home?"
4. **Campy surface, eldritch basement.** Mission logs start chipper. They do not stay chipper.

---

## 2. Theme & Lore

- **The Gate:** Only way to and from alien worlds. Transit destroys electronics and complex machinery — only inert/mechanical matter survives. This is why everything is analog and everyone carries swords.
- **The Suit:** Apollo-era pressure suit aesthetic. Analog gauges, wound springs, glass dome. The HUD is **diegetic where possible** — oxygen is a physical gauge on the suit, not a UI bar.
- **Addresses:** Gate destinations are glyph sequences ("telephone numbers"). New addresses are *learned*, not unlocked — found as evidence in the field. Same world can be re-dialed at higher difficulty tiers with remixed encounters and world modifiers.
- **World modifiers (post-jam):** thick atmosphere (slow movement), low gravity (double knockback), predator grassland (fast + fragile enemies), etc. Variety at config-file cost.
- **Narrative delivery:** No cutscenes, ever. Evidence pickups (logs, glyph fragments, personal effects of previous expeditions) readable later in the hub journal. Evidence is also *progression* — glyph fragments assemble into new addresses.
- **The arc:** Why did the previous expeditions stop reporting in? Early logs are mundane. Later logs get wrong. The boss is the answer.

---

## 3. Core Loop

```
HUB (gate room) → dial address → OUTBOUND (gated arenas, clear to proceed)
→ BOSS (open arena, O2 cache as prize) → RETURN (chase, pursuit spawns)
→ gate home → read journal, spend/upgrade → dial again
```

- **The gate is the only way home.** Every run is out-and-back.
- **Outbound** = roguelite. Arenas gate shut during combat (diegetic barrier — rockslide / shimmer / TBD). Clear to proceed.
- **Return** = chase, NOT a re-clear. Pursuit spawns behind and beside the player: faster, flimsier, they chase rather than block. The player's job flips from "kill everything" to "don't stop moving." Knockback becomes a snowplow.
- **Bando rule:** Boss arenas NEVER lock. Abandoning the fight must always be possible. An abandoned boss pursues to its territory edge (rare cruelty option post-jam: sometimes it doesn't stop).
- **Boss prize:** A fat oxygen cache in the boss arena. The fight itself is the wager — win and you're refueled to loot at leisure; struggle and every extra second burns your escape margin.

---

## 4. Combat

### 4.1 Plane Rule
3D presentation, **2D gameplay**. All combat resolves on the XZ plane. Playable surfaces are *genuinely flat* — no gameplay slopes, ever. Terrain height is visual only.

### 4.2 Hit Detection
Math, not physics: an attack hits enemies within radius **R** and arc **θ** of facing, on XZ. Distance check + dot product per target. Tunable per weapon with two numbers.

### 4.3 The Feel Stack (tune in this order)
1. **Hitstop** — a few frames of freeze on connect. Cheapest, highest-impact feel tool. Scale with weapon weight.
2. **Knockback** — Vector2 on the plane. Systemic, not cosmetic: wall slams (bonus damage/stun), enemy-into-enemy collisions, hazard launches. Positioning is the damage multiplier.
3. **Camera kick** — directional punch on hit, shake on slams.
4. **VFX** — flashes, smoke, particles. Last, because they hide weak fundamentals if added first.

### 4.4 Weapons (4 total, jam ships with 1)
Each weapon is a *position on the battlefield*, not a stat line:

| Weapon | Reach | Arc | Commitment | Role |
|---|---|---|---|---|
| **Greatsword** | mid | wide | huge | Anchor. Knockback showcase. **BUILD FIRST.** |
| Short sword | short-mid | medium | medium | Vanilla baseline / tuning reference |
| Pike/halberd | long | narrow | med-high | Pokes down a line; attacks through the scrum |
| Daggers | tiny | circle | low | Glass cannon, mobility-tied, flanker |

**Greatsword first** because it stress-tests the entire feel stack at max amplitude. If the slowest weapon is fun, the fast ones will be. The reverse is not true.

### 4.5 Build Variety (post-jam, cheap)
Runes/modifiers, not items: fire trails on swings, knockback shockwaves, combo-ender lunge. 6 modifiers × 4 weapons reads as 24 builds.

---

## 5. Oxygen

- Continuous drain. Diegetic gauge on the suit. **The run timer and the extraction system are the same dial.**
- Tune **generously** — the tension is greed, not panic. O2 tank pickups in the world act as pressure-release valves and exploration rewards.
- The player must be able to **do the math**: readable gauge mid-sprint, sense of distance back to the gate. A bando should feel like "my greed," never "the game's opacity."
- **Jam: oxygen is a timer ONLY.** Do not couple to damage. (Suit punctures that leak air = stars column.)

---

## 6. The Boss

A bruiser. Big health, slow, high damage, brutally readable.

- **It's a person in a suit.** Player capsule rig scaled ~2.5x, dragging an enormous version of the player's own greatsword. Suit wrong: cracked dome, purple seep, gauges spinning backwards. This *is* the narrative — Expedition Five, found.
- **Three attacks, three answers:**
  1. **Overhead slam** — punishes standing still. Slow, huge telegraph, leaves it vulnerable. The dodge test.
  2. **Wide sweep** — punishes hugging it. Forces disengage/re-enter rhythm.
  3. **Lunge/stomp** — punishes edge-camping. Closes distance.
- **AI:** random pick weighted by player distance. That's it.
- **Telegraph language over brains:** distinct windup silhouettes, color flash / ground decal one beat before commitment, unique audio cue per attack. **Punch-Out test:** fightable on silhouette alone; dangerous only if you stop reading.
- It uses the same hitstop/knockback systems as the player — getting slammed into canyon walls teaches the player their own mechanics.

---

## 7. Level Design (Terrain3D)

- **Terrain is paint and scatter. Colliders are the level.** Sculpted cliffs are visual; invisible flat box colliders hugging the cliff lines are the mechanical walls (and they're what wall-slam detection tags).
- **Theater staging rule (hard rule, never break):** Camera is Hades-tilted (~50–60°), looking north-ish. Every arena is high-walled on north and sides, **low or open toward the camera (south)**. Canyon corridors run north-south or diagonal. This eliminates camera occlusion forever — no transparency shaders, no camera collision.
- **Paint = readability:** One distinct ground color/texture for playable space. Scatter stays off the play floor (or non-colliding). A worn-path color leads to the next arena.
- **Jam map:** ONE continuous sculpted map. Gate landing site → ~3 gated arenas via canyon chokepoints → boss arena. Spoke/loop layout so the return leg reuses geography under chase pressure.
- **Replayability cheat:** fixed geography, shuffled *content* — encounter mixes, evidence locations, O2 tank spots.

---

## 8. Architecture Rules (multiplayer door stays open, zero netcode now)

Single-player from day 1. No networking code, no MultiplayerSynchronizer, no authority logic. But these three habits cost nothing and keep co-op possible later:

1. **Input → Intent → Action.** Gameplay scripts never read `Input` directly. An input component produces intents (move vector, attack, dash); the character consumes intents. A future net peer or AI companion is just another intent producer.
2. **No "the player" singleton.** Everything written as if `players` is an array that happens to have length 1. Camera follows a target. Enemies query nearest player. Never `Global.player.position`.
3. **State changes through chokepoints.** `take_hit(damage, knockback, source)` — never scattered `hp -= x`. One chokepoint is where RPCs slot in later, and it's where hitstop/particles/camera-kick fire consistently from a single place *now*.

---

## 9. Godot Conventions (project law)

1. **Nodes first, scenes always.** Do NOT generate node trees from scripts. Build everything as reusable `.tscn` scenes composed in the editor. Scripts add behavior to scenes; they don't construct them.
2. **Short, single-purpose scripts.** One script = one job (e.g., `HitstopController`, `OxygenTank`, `KnockbackReceiver`). If a script does two things, it's two scripts. Compose behavior from small scene/script pairs.
3. **`class_name` with vigor + strong typing everywhere.** Every reusable script gets a `class_name`. All variables, parameters, and return values explicitly typed. **No `:=` inference** — write `var speed: float = 6.0`, not `var speed := 6.0`. Human-readable types over terseness.
4. **No hand-authored UIDs/GUIDs.** Let Godot generate and manage all UIDs and resource IDs. Never write or edit them manually.

---

## 10. Build Order (jam sequencing — do not skip ahead)

Each phase has a gate. Don't start the next until the current one passes.

- **Phase 1 — The Swing.** Flat graybox plane. Capsule + oversized greatsword + training dummy. Tune hitstop, knockback curve, camera kick, smoke/flash.
  *Gate: swinging at the dummy is fun with no game around it.*
- **Phase 2 — The Fodder.** One enemy: pure knockback fodder. Wall slams, enemy-into-enemy hits work.
  *Gate: bowling through a pack feels great.*
- **Phase 3 — The Threat.** Second enemy that punishes greed and forces the dodge. Add the dodge/dash if not already in.
  *Gate: a mixed pack creates real decisions.*
- **Phase 4 — The Ground.** Terrain3D map: gate site, 3 arenas, chokepoints, boss arena. Invisible colliders, theater staging, paint pass.
  *Gate: a full outbound clear flows.*
- **Phase 5 — The Air.** Oxygen drain, diegetic gauge, O2 pickups, return-leg pursuit spawns, gate-out ends the run.
  *Gate: the run home is scary and fair.*
- **Phase 6 — The Fallen.** Boss: scaled suit-figure, three attacks, telegraph language, open arena, O2 cache prize.
  *Gate: Punch-Out test passes.*
- **Phase 7 — The Story.** Hub gate room, journal UI, 5–8 evidence pickups placed on the map, one partial address tease.
  *Gate: someone reads the journal voluntarily.*
- **Phase 8 — Polish.** Audio pass, screen flash pass, menu, balance.

**If time runs out:** ship at the end of any completed phase. Phase 5 is a shippable game.

---

## 11. Stars Column (post-jam, explicitly NOT jam scope)

- Weapons 2–4 (short sword → pike → daggers, in that order)
- Rune/modifier system
- 4-player co-op (architecture is ready; netcode + melee hit sync is the tax)
- Multiple addresses, difficulty tiers, world modifiers
- Suit punctures (damage ↔ oxygen coupling)
- Persistent half-killed bosses / boss pursuit beyond territory
- Upgrade track: range-based progression (tank capacity, rebreather efficiency, suit weight, dialing speed) — power = how deep you can go, not damage inflation
- More biomes: grassland murder-bunnies, acid swamp, thick purple "underwater" atmosphere

---

*Vision: aim for the stars. Scope: ship Phase 5.*
