# 10 — Roads, Routing & Traffic

**Status:** AMENDED per `98-consistency-report.md` (rulings binding). Complies with `00-constitution.md` (LOCKED) and spec §8, §29.2, §46. Applied rows are listed in §10.
**Owner scope:** road tiles, road graph, A* routing, congestion scalar, closures, cosmetic civilian traffic, road classes, road build/repair **work and physics** (crew-hours, condition, decay, damage fractions), **the traffic-signal outage congestion penalty** (report 98 G-6), and **`access_quality(pos)` — the single tile-level definition of road access** (C-61).

**Not owner scope — all road *prices* are doc 03's** (report 98 RR-2, extending C-07): per-tile build and upgrade prices, repair pricing and demolish refunds live in **`data/economy.json`**, not in `data/roads.json`. **Roads carry NO standing per-tile upkeep in MVP** (mirroring C-08's no-double-billing principle): the cost of a road is *build + decay + repair*, and repair is priced by doc 03's C-16 formula `capital_value × damage_fraction × 0.85 × M_repair` against the damage fraction this doc publishes. Road **condition is on `[0,1]`** everywhere, per C-14 as extended by RR-3; UI may display it as a percentage.

**Doc numbering (report 98 Ruling Zero).** The on-disk filenames are canonical; there is no other map: 00 Constitution · 01 time model & tick scheduler (`sim/time/`) · 02 buildings, upgrades & construction projects (`sim/buildings/`, `sim/construction/`) · 03 economy, taxes, land market & difficulty (`sim/economy/`) · 04 electrical grid (`sim/power/`) · 05 water system (`sim/water/`) · 06 incidents, dispatch & emergency fleets incl. construction crews as units (`sim/incidents/`, `sim/dispatch/`, `sim/fleet/`) · 07 weather & Disaster Director (`sim/weather/`, `sim/director/`, `sim/disasters/`) · 08 persistence, offline policy & notification policy (`sim/persistence/`, `sim/offline/`, `sim/history/`, `sim/notify/`) · 09 map, land, districts, **population & stability**, starter city (`sim/world/`, `sim/population/`) · **10 roads, routing & traffic (this doc, `sim/roads/`)** · 11 rendering & performance (`game/`) · 12 UI/UX, camera input & onboarding (`ui/`) · 13 Android integration & export (`game/android/`, `android/plugins/`). This doc already used the on-disk filenames before the ruling; the former §9.2 X-3 note about sibling docs' private numbering maps is closed by Ruling Zero.

**Interfaces adopted from siblings rather than invented here** (§9.1 records what I changed to match): vehicle speed is `speed_mpgm` owned by **doc 06**, roads contributes only `road_class_mult`; `congestion_index ∈ [0,2]` with `1.0 = at capacity` per **doc 06** §2; `route_minutes(a,b,profile)` is synchronous, authoritative and mode-invariant per **doc 06** §2; roads runs at phase **P08, every step**, per **doc 01**.

---

## 1. Overview & Goals

Roads are the **latency layer** of SLACUM CITY. Every other system's response time is a road-graph query. This system exists to make three things true:

1. **Distance and layout are strategic.** Where the player puts a fire station relative to an avenue corridor decides whether a Level-5 high-rise fire is survivable.
2. **Roads are a cascade *carrier*, not a cascade *sink*.** Power outage → dark signals → +intersection delay + congestion → slower fire response → worse fire. Flood → closure → utility crew cannot reach the transformer → outage persists → more crime. These are the spec §4 Pillar-1 examples, and this doc supplies the exact numbers that make them fire.
3. **Roads are an asset that decays.** Condition falls with traffic and weather, costs money to repair, and can *collapse* into a real impassable failure. Deferring maintenance is a legitimate, punishable risk trade (spec §11.3). **Roads carry no standing upkeep** — the cost of a road is *build + decay + repair*, all priced by doc 03 (report 98 RR-2).

Non-goals (constitution §8, spec §29.2, §52): no per-vehicle civilian simulation, no pedestrians, no lane-level modelling, no transit. Civilian traffic is **density-driven cosmetics with zero simulation authority**.

**Core loop role:** *build → operate → crisis → respond → recover*. Roads are placed during **build**, priced during **operate** (repair only — no standing upkeep, RR-2), degraded during **crisis** (closures), and are the bottleneck during **respond**.

**Performance contract:** all road work — graph maintenance, congestion, and routing — must fit in **≤ 4 ms per SimTick** on the reference device (2022 Snapdragon 7-series), for a city of up to **12,000 road tiles / ~2,000 graph edges**.

---

## 2. Mechanics

### 2.1 Units, orientation, and the time-scale calibration

Per constitution §6: **1 tile = 8 m**, land block = **16×16 tiles** = 128 m.

All road times are **game-minutes (gm)**; all speeds are **metres per game-minute (m/gm)**, never km/h. Doc 06 §9 already established this abstraction (its `speed_mpgm` is a game-time constant whose literal physical reading — ~1.9 km/h for a patrol car — is nonsense and must never surface in UI or fiction). **Doc 10 adopts it unchanged.**

**Ownership split (settled with doc 06):**

| quantity | owner | symbol |
|---|---|---|
| how fast a *vehicle* is | **doc 06** | `profile.speed_mpgm` |
| how much a *road class* helps | **doc 10** | `road_class_mult` |
| how much congestion / weather / condition / closure hurt | **doc 10** | `F_cong · F_wx · F_cond · F_clos · F_ovr` |
| intersection delay | **doc 10** | `D_node` |

Doc 10 therefore publishes **no absolute vehicle speed**. Its only absolute speed is `CIVILIAN_BASE_SPEED_MPGM = 34`, used solely by the cosmetic traffic layer (§2.15), chosen to sit in doc 06's band (`patrol_car ≈ 32`, `construction_crew_vehicle = 18`).

**Calibration check** against doc 06's stated target of *4–14 gm responses across a starter city*: a starter city is 3×3 land blocks = 384 m across (constitution §6). A patrol car at `32 m/gm` on `local` roads at `congestion_index 0.5`, clear, condition 1.0, crossing 5 signalised intersections, covers 384 m in `384/32 × 1.20 × 1.0 × 1.0 = 14.4 gm` plus `5 × 0.12 × 1.5 = 0.9 gm` of signal delay ≈ **15.3 gm**. Routed along an `arterial` (`×1.25`) it drops to **12.3 gm**. Both sit at the top of doc 06's band, and the arterial saving is exactly the strategic payoff avenues are supposed to buy. **Doc 06 should confirm the band, or trim `turnout_min` / raise `speed_mpgm` — doc 10 will not move `road_class_mult` to compensate.**

### 2.2 Road tiles

A road tile is a record on the tile grid:

```
class      : 0 = NONE, 1 = STREET, 2 = AVENUE
condition  : float 0.0 .. 1.0   (saved quantised to uint8 as round(condition * 100))
flags      : bitfield
             bit0 UNDER_CONSTRUCTION
             bit1 FLOODED_SHALLOW
             bit2 FLOODED_DEEP
             bit3 COLLAPSED
             bit4 DEBRIS
             bit5 CORDON
             bit6-7 reserved
```

**Condition is on `[0,1]`, with no carve-out (report 98 C-14 as extended by RR-3).** `1.0` is a newly finished road, `0.0` is `COLLAPSED`. Every threshold, decay rate, damage delta and worked example in this doc is on that scale; the former `[0,100]` point scale is deleted, and its constants were divided by 100. **UI may display condition as a percentage** (doc 12 formats `round(condition × 100)`), but no sim value is ever authored, stored or compared in points. Doc 06's `condition_hazard_mult` citation reads `1.00 / 0.55 / 0.10`, not `100 / 55 / 10`.

**Both MVP classes occupy exactly one tile.** An avenue renders as a wider ribbon overhanging the tile bounds by ~1.5 m per side; it is not two tiles. This keeps the graph a clean 4-connected grid. Multi-tile arterials are deferred (§6).

**Connectivity is 4-neighbour (orthogonal) only.** No diagonal roads, no diagonal traversal.

### 2.3 Road classes (MVP)

| property | STREET | AVENUE |
|---|---|---|
| doc 06 `road_class_mult` name | `local` | `arterial` |
| `road_class_mult` | **1.00** | **1.25** |
| congestion base `K_base` | **1.00** | **0.64** |
| congestion sensitivity `S_cong` | **0.80** | **0.55** |
| build work | **0.50 crew-hours / tile** | **1.40 crew-hours / tile** |
| upgrade street→avenue work | — | **0.90 crew-hours / tile** |
| condition base decay | **0.0090 / game-day** | **0.0060 / game-day** |
| signalises a ≥3-way node | only if degree ≥ 4 | always |

Doc 06's third class `alley` (`×0.80`) is **not built in MVP**; the id is reserved so its table row can be added without a schema bump.

**Prices deleted — doc 03 owns them (report 98 RR-2).** The former `build cost` ($1,800 / $5,200 per tile), `upgrade street→avenue` ($4,000/tile), `upkeep` ($2.20 / $6.00 per tile per game-day) and `demolish refund` (15%) rows are **removed from this table and from `data/roads.json`**. Doc 03 is the sole currency authority (C-07), roads included: per-tile build price, street→avenue upgrade price, demolish refund fraction and repair pricing now live in **`data/economy.json` → `roads`**, authored on doc 03's ladder. **There is no `upkeep_per_game_day` anywhere** — roads carry no standing upkeep in MVP; a road's lifetime cost is *build + decay + repair*. What this doc still owns and publishes to doc 03 is the physics: the per-class **build/upgrade/repair work in crew-hours** above, the **condition decay rates** above, the **damage fractions** per closure and damage cause (§2.12), and `road_damage_fraction(tile) = 1 − condition`, which is the `damage_fraction` argument of doc 03's C-16 repair formula.

**Crew-hours are work units, and every work unit multiplies `ctx.channels.construction_rate` (report 98 C-29).** Road build, upgrade, repair and demolish jobs are never wall-clock timers. They are submitted to **doc 02's `ConstructionQueue`** (G-2, §2.13) and progress through doc 01's exact integer `WorkService` accumulator using **doc 02's convention, adopted verbatim**:

```
required_work_units = round(required_crew_hours × WORK_UNITS_PER_CREW_HOUR)    WORK_UNITS_PER_CREW_HOUR = 100
per tick: work_units += floor( crew_power × site_mult × 100 × dt_h )
site_mult = weather.get_effect("build_mult")        ← doc 07
          * road_access_mult                        ← this doc, §5.2
          * ctx.channels.construction_rate          ← doc 01, 24-hour mean 0.804, night floor 0.60   ← MANDATORY
crew_power = crew_rate of the assigned crew         ← doc 06 (generic construction crew 0.70, road crew 1.00)
```

The `construction_rate` term is **not optional and not folded into anything else**. Every crew-hour figure in this doc is *authored against the 0.804 mean*, so a road job's wall-clock time is always `crew_hours / (crew_rate × 0.804)` game-hours in clear weather, not `crew_hours / crew_rate`. *(The former `work_required_mu = crew_hours × 3600 × 1000` milli-unit conversion is deleted — doc 02 owns the accumulator and its unit under G-2.)*

**The L4/L5 avenue gate — ACCEPTED, and owned by doc 02 (report 98 C-62).** The rule this doc proposed — *a building may only reach Level 4 or 5 if an `AVENUE`-class road tile exists within 4 tiles (Chebyshev) of its access tile* — is ruled a **hard gate**, not a soft cost modifier. It now lives as **doc 02 §2.11 upgrade check #13 `E_AVENUE`**, and doc 12's `RequirementFormatter` blocker enum grows to 13 entries. Doc 10's only remaining obligation is the lookup that answers it:

```
has_class_within(tile, AVENUE, avenue_gate_radius_tiles = 4) -> bool
```

Doc 10 does **not** evaluate the gate, format its message, or store its result. Because doc 09's template stamps boundary arterials → `AVENUE` on every block (C-60, below), the gate never blocks the tutorial; it bites the first time a player develops an interior block on `STREET`s alone and then reaches for L4.

**Land-block road template — doc 09's, adopted (report 98 C-60).** Doc 09 owns the map template; doc 10 owns the class semantics. This doc's former `{0, 8}` local-line grid (60 tiles, all STREET) is **deleted** — the authoritative template is doc 09 §2.9.1, stamped by its `ROAD_INSTALL` development phase. The class mapping is:

| doc 09 template element | doc 10 class | tiles per 16×16 block |
|---|---|---|
| boundary arterial — block-local rows/cols `{0, 15}`, 1 tile contributed from each side | **AVENUE** | `2×16 + 2×16 − 4 = ` **60** |
| interior collector — block-local row and column index **7** | **STREET** | `16 + 16 − 1 − 4 shared with the boundary = ` **27** |
| any player-placed road | **STREET** (upgradeable to AVENUE per §2.13) | — |
| | **total** | **87** |

`87 × 9 blocks = 783` road tiles in doc 09's 3×3 core, `169` buildable tiles on a clean block, and the `0.34` road-area constant doc 09's price and placement math depends on — all reproduced exactly. Boundary tiles belong to the block that contributed them, so a boundary between two developed blocks is 2 tiles wide (one AVENUE tile from each side) and **is never counted twice**.

> **The stamp ships (Wave 5).** Until Wave 5 this table described something nothing executed: doc 09's `ROAD_INSTALL` phase advanced the block's `road_access` attribute and stamped no tiles, so **a developed ring block reached READY with no roads at all** — 256 placeable tiles, none of them with road access, on a map whose revenue formula multiplies by `f_road` and whose L4/L5 gate asks for an AVENUE. `RoadNetwork.stamp_block_template(block_grid)` now lays the 60 + 27 exactly as tabled, at the phase doc 09 §2.3 names, through the same incremental retrace every other edit uses; `CitySim` calls it from the `development_phase_completed` seam that already handled `UTILITY_CORRIDOR`, because doc 09's pipeline may not reach into the tile grid itself. **It books no money** — doc 03 §2.8's `road_install` phase price paid for it once, which is this section's no-double-billing rule, and `tests/test_infra_verbs.gd` asserts the whole development cost less than the $360,600 the same 87 tiles would cost at §2.13(d) piece rates. A block whose neighbour is already developed widens that boundary from one AVENUE tile to two with no special case: each block simply stamps its own local `{0, 15}`.

**Re-derived block road-install figures — work and decay only (RR-2).** The cost and upkeep rows of this table are **deleted**; `data/economy.json` prices the same 60 + 27 tile counts. Generating formulas: `work = 60 × avenue.build_crew_hours + 27 × street.build_crew_hours`; `decay = 60 × avenue.condition_base_decay + 27 × street.condition_base_decay` (per game-day, at `c_day = 0`, clear).

| quantity | avenue term (60 tiles) | street term (27 tiles) | **per block** | **doc 09 core (×9)** |
|---|---|---|---|---|
| build work | `60 × 1.40 = 84.0 ch` | `27 × 0.50 = 13.5 ch` | **97.5 crew-hours** | **877.5 crew-hours** |
| baseline condition decay | `60 × 0.0060 = 0.3600 /gd` | `27 × 0.0090 = 0.2430 /gd` | **0.6030 tile-fractions / game-day** | **5.4270 tile-fractions / game-day** |
| replacement cost | — | — | **doc 03** (`data/economy.json`) | **doc 03** |
| upkeep | — | — | **none — RR-2** | **none — RR-2** |

Wall time for one block's template at the C-29 channel mean: a `road_crew` (`crew_rate 1.00`) takes `97.5 / (1.00 × 0.804) = ` **121.3 gh**; a generic `construction_crew` (`0.70`) takes `97.5 / (0.70 × 0.804) = ` **173.2 gh**.

**Input published to doc 03 for its routine road-repair expectation line (RR-2).** Doc 03 books that line *derived, not assumed*, so this doc publishes the accrual it derives from. The 9-block core is `9 × 87 = 783` tiles = `9 × 60 = 540` AVENUE + `9 × 27 = 243` STREET. At the quiet-starter sample point (`c_day = 0.35`, clear ⇒ `wx_wear_day = 0`, so the multiplier is `1 + 0.75 × 0.35 = 1.2625`):

```
avenue : 540 × 0.0060 = 3.2400 ;  × 1.2625 = 4.09050 tile-fractions / game-day
street : 243 × 0.0090 = 2.1870 ;  × 1.2625 = 2.76109 tile-fractions / game-day
core   :                          6.85159 tile-fractions / game-day
                                = 6.85159 / 24 = 0.285483 tile-fractions / game-hour
```

That accrual — **`core_damage_fraction_accrual_per_gh = 0.28548`** — is exactly the `damage_fraction` throughput doc 03 multiplies through C-16 (`capital_value × damage_fraction × 0.85 × M_repair`) to get the starter ledger's road-repair line. Doc 10 supplies the fraction; doc 03 supplies `capital_value` and every dollar.

**Where the work is and is not charged — no double-billing.** The block template stamp is billed **once**, by doc 03's `road_install` development-phase price (§2.8, `PHASE_BASE $7,500 × terrain × distance × access`, $6,930–$21,090 in doc 03's worked example F), and its duration is doc 09's 14 crew-hour phase. Doc 03's per-tile prices are the charge for **player-placed** road tiles and the replacement value used for `COLLAPSED` rebuild pricing (§2.12) and demolish refunds (§2.13). The 97.5 crew-hour figure above is the template's **work content**, not a second invoice against the development phase — and with the price columns gone there is no longer a doc-10 dollar figure that could be mistaken for one.

> **X-9 is CLOSED by report 98 RR-2 (§9.2).** The 17–52× gap and the missing starter-ledger roads line are resolved by moving *all* road pricing to `data/economy.json` and ruling that roads carry **no standing upkeep**. The former `$157.28/gh` core upkeep figure — 42% of doc 03's restated `+$373/gh` net — **does not exist**; it is replaced by doc 03's much smaller repair-expectation line derived from the `0.28548 /gh` accrual above.

**All 81 core intersections are signalised**, which is what makes the dark-signal cascade (G-6, §2.6) reach the whole starter city: doc 09's core grid crosses 9 lines by 9 lines; every crossing either contains an AVENUE tile (avenue always signalises a ≥3-way node) or is a collector×collector crossing at degree 4 (street signalises at degree ≥ 4).

### 2.4 Graph build

Nodes and edges are derived from tiles; **the graph is never saved** (§3.2).

**Node predicate.** A road tile `T` with orthogonal road-degree `d` is a node iff:
- `d ≠ 2` (dead end `d=1`, intersection `d≥3`, isolated `d=0`), **or**
- `d = 2` and the two neighbours have different `class` from each other or from `T` (class transition point).

Corners (`d=2`, perpendicular neighbours, same class) are **not** nodes — they are interior polyline vertices. This roughly halves node count versus naive per-tile graphs.

**Degenerate case:** a connected component with zero node candidates (a pure loop) gets its lowest-`(y,x)` tile promoted to a node.

**Edge tracing.** For each node, for each of its road neighbours not yet consumed, walk forward through `d=2` non-node tiles until another node is reached. The resulting ordered tile list is the edge polyline, inclusive of both endpoint node tiles.

**Edge record:**

```
id            int          stable across rebuilds when tile list is unchanged
node_a,node_b int
tiles         PackedVector2iArray  (ordered, ≥2 entries)
length_m      float  = (tiles.size() - 1) * 8.0
road_class    int    (uniform by construction)
condition     float  = mean of tile conditions
congestion    float  0..1, smoothed
closure_id    int    (-1 = none)
blocked_mask  int    bitmask of RouteClass values that cannot traverse
district_id   int    (district of tiles[tiles.size()/2])
dens_index    float  L_dens, refreshed per game-day
```

**Node record:**

```
id, tile, edge_ids[], degree, signalised (bool), powered (bool, cached from doc 04), component_id
```

`signalised = degree ≥ 3 AND (any incident edge is AVENUE OR degree ≥ 4)`.

**Edge-id stability:** after a rebuild, each new edge is hashed over `(node_a_tile, node_b_tile, tiles)`. If a just-deleted edge had an identical hash, its id is reused. This prevents spurious `route_invalidated` storms when an unrelated road is edited nearby.

**Worked example B-1 — plus-shape build.** Tiles: `(2,0) (2,1) (0,2) (1,2) (2,2) (3,2) (4,2) (2,3) (2,4)`.
Degrees: `(2,2)=4` → node N1. `(2,0),(0,2),(4,2),(2,4)` each `d=1` → nodes N0,N2,N3,N4. `(2,1),(1,2),(3,2),(2,3)` are `d=2` collinear → interior.
Result: **5 nodes, 4 edges**, each edge 3 tiles, `length_m = (3−1)×8 = 16 m`. Node/edge count for 9 road tiles = 5/4.

### 2.5 Incremental rebuild

Edits are **batched per SimTick**. A tick's edit set `E` (tiles added, removed, or class-changed) is processed once:

1. `dirty_tiles = E ∪ (orthogonal neighbours of E)`.
2. `dirty_edges = { edges whose tile list intersects dirty_tiles }`; `dirty_nodes = { nodes at dirty_tiles }`.
3. Delete `dirty_edges`. Delete nodes in `dirty_nodes` that no longer satisfy the node predicate (return id to the free list); keep ids of nodes that still qualify.
4. Re-evaluate the node predicate for every tile in `dirty_tiles` that is a road tile; promote/demote.
5. Re-trace edges outward from every affected node, stopping at the first *surviving* node in each direction. Retracing never walks past a stable node, so cost is `O(length of affected chains)`.
6. Update `tile_to_edge` and `tile_to_node` maps for retraced tiles only.
7. Update components (§2.9). Increment `graph_version`. Emit `road_graph_changed { added_edges, removed_edges }`.

**Budget:** `REBUILD_TILE_BUDGET = 2048` retraced tiles per tick. If exceeded, the remainder of the dirty set carries to the next tick; the graph stays *valid* throughout (only the not-yet-retraced region keeps its previous, still-consistent edges), and `graph_dirty = true` suppresses route-cache reuse for edges in the pending set.

**Worked example B-2 — remove the hub.** Delete `(2,2)` from B-1. `dirty_tiles = {(2,2),(2,1),(1,2),(3,2),(2,3)}`; all 4 edges are dirty and deleted; N1 is deleted. `(2,1),(1,2),(3,2),(2,3)` all become `d=1` → new nodes. Retrace produces 4 edges of 2 tiles each (`length_m = 8`). Tiles retraced: **8**. Components go from 1 → 4. Any vehicle holding one of the 4 old edge ids receives `route_invalidated`.

### 2.6 Cost function

All costs are in **game-minutes**. Cost is symmetric (MVP has no one-ways).

```
cost(e, prof) = (L_e / (prof.speed_mpgm * road_class_mult(class_e)))
              * F_cong(e, prof) * F_weather(prof) * F_cond(e)
              * F_closure(e, prof) * F_override(e)
              + D_node(n_entry, e, prof)
```

`n_entry` is the node the vehicle passes *through* to reach `e`; the origin and destination nodes contribute no delay.

**Routing profile.** Doc 06 passes a `RouteProfile`, not a bare enum. It carries the vehicle's own `speed_mpgm` plus the privilege set implied by its routing class:

| routing class | `cong_relief` | `node_relief` | `wx_resist` | doc 06 vehicle types |
|---|---|---|---|---|
| `EMERGENCY` | **0.65** | **0.60** | **0.25** | patrol car, supervisor, engine, ladder, rescue, ambulance |
| `UTILITY` | **0.30** | **0.20** | **0.10** | service/bucket/heavy truck, mobile transformer, water repair/pump |
| `CONSTRUCTION` | **0.10** | **0.00** | **0.00** | construction crew vehicle, heavy equipment, crane, road crew |
| `CIVILIAN` | **0.00** | **0.00** | **0.00** | cosmetic traffic; the ETA shown in the traffic overlay |

(Doc 06 already carries a per-type `siren_mult`; that is a *speed* modifier and multiplies `speed_mpgm` on doc 06's side. It must **not** be double-counted as `cong_relief`.)

**Congestion factor**

```
F_cong(e, prof) = 1 + S_cong(class_e) * c_e * (1 - cong_relief(prof))
```
`c_e` is `congestion_index ∈ [0, 2]`, **1.0 = at capacity** (doc 06's scale, adopted here). Bounds: a civilian on a gridlocked street (`c = 2`) pays `1 + 0.80·2 = 2.60×`; an emergency vehicle pays `1 + 0.80·2·0.35 = 1.56×`. At capacity (`c = 1`) they pay `1.80×` and `1.28×`.

**Weather factor**

```
F_weather(vc) = 1 + wx_slowdown(state) * (1 - wx_resist(vc))
```
`wx_slowdown`, plus the congestion term `wx_cong_add` (§2.10) and the wear term `wx_wear` (§2.12), are tabulated per weather state in `tunables.weather` (§8). Range: `clear 0.00` → `heavy_rain 0.18` → `snow 0.30` → `blizzard 0.55`.

**Condition factor**

```
F_cond(e) = 1 + COND_PENALTY_MAX * (1 - condition_e)^2           COND_PENALTY_MAX = 0.60
```
Condition **1.00** → 1.000 · **0.75** → 1.038 · **0.50** → 1.150 · **0.25** → 1.338 · **0.01** → 1.588 · **0** → COLLAPSED (impassable, not a multiplier). *(RR-3 rescale: the `/100` divisor is deleted because `condition` is already on `[0,1]`; the multiplier values are unchanged — `1 + 0.60 × 0.25² = 1.0375` at 0.75, `1 + 0.60 × 0.75² = 1.3375` at 0.25.)*

**Closure factor.** From the closure cause table (§2.8). `BLOCK` means the edge is excluded from that class's search entirely (`blocked_mask` bit set), not given a large finite cost.

**Override factor.** Doc 06 escalation tiers set a direct speed multiplier on a segment (`set_edge_speed_mult(edge, m, until_min)` — e.g. `traffic_accident` T1 → `0.6`, T2 → `0.3`; `water_main_break` T3 → `0.5`).
```
F_override(e) = 1 / clamp(edge.speed_override, 0.10, 1.00)      default override = 1.0 → F = 1.0
```
This is a **separate, multiplicative** channel from `F_closure`, so doc 06 can degrade a segment without inventing a closure cause, and the two compose predictably. Overrides expire at `until_min` and are saved.

**Node delay**

```
base = if !signalised and degree < 3 : 0
       elif !signalised              : STOP_DELAY   * (1 + c_e)
       elif powered                  : SIGNAL_DELAY * (1 + c_e)
       else                          : DARK_SIGNAL_DELAY * (1 + 2 * c_e)

D_node = base * (1 - node_relief(prof))
```
`STOP_DELAY = 0.04 gm`, `SIGNAL_DELAY = 0.12 gm`, **`DARK_SIGNAL_DELAY = 0.45 gm`**.

**Ownership (report 98 G-6 — closed, this doc owns it).** The traffic-signal outage congestion penalty was flagged unowned by doc 04. It is **doc 10's**, and it is exactly two constants:

| constant | value | where it acts | §|
|---|---|---|---|
| **`DARK_SIGNAL_DELAY`** | **0.45 gm** | per-node travel-time term in `D_node`, scaled by `(1 + 2·c_e)` | §2.6 |
| **`DARK_SIGNAL_ADD`** | **0.19** | additive congestion per dark signalised endpoint node in `I_inc(e)` | §2.10 |

Both live in `data/roads.json` (§8: `node_delay.dark_signal_delay_gm`, `congestion.dark_signal_add`). **Doc 04 consumes neither and defines neither** — it only publishes the power state (`power.is_tile_powered(tile)`), and doc 10 turns that into delay and congestion. No other doc may author a signal-outage penalty.

The `powered` flag comes from doc 04 (`power.is_tile_powered(node.tile)`), cached on the node and refreshed at phase P08 from **this step's** power state (doc 01 orders P06 POWER before P08 ROADS precisely so this has zero lag). **This is the spec §4 "traffic lights fail" cascade.** A 10-signal route through a blacked-out district at `c = 1.0` costs a civilian `10 × 0.45 × 3.0 = 13.5 gm` versus `10 × 0.12 × 2.0 = 2.4 gm` powered — **+11.1 gm**, which on a typical cross-district run is a ~30% increase from the signals alone, before the congestion the dark signals also add (§2.10).

**Worked example C — fire engine, three edges, storm + blackout.**

Vehicle: doc 06 `fire_engine`, `speed_mpgm = 26.0 × siren_mult 1.25 = 32.5`.
Route: `E_a` avenue 480 m cond **0.92** `c=0.72` · node N1 (signalised, powered) · `E_b` street 240 m cond **0.61** `c=1.15` (over capacity) with `accident_minor` · node N2 (signalised, **unpowered**) · `E_c` street 160 m cond **0.88** `c=0.48`. Weather `heavy_rain` (`slowdown 0.18`, EMERGENCY `wx_resist 0.25` → `F_wx = 1.1350`).

| term | `t0 = L / (32.5 · class_mult)` | `F_cong` | `F_cond` | `F_clos` | result (gm) |
|---|---|---|---|---|---|
| `E_a` | 480 / 40.625 = 11.8154 | 1+0.55·0.72·0.35 = 1.1386 | 1+0.60·0.08² = 1.0038 | 1.00 | **15.3276** |
| `N1` | `0.12 · (1+1.15) · (1−0.60)` | | | | **0.1032** |
| `E_b` | 240 / 32.5 = 7.3846 | 1+0.80·1.15·0.35 = 1.3220 | 1+0.60·0.39² = 1.0913 | 1.40 | **16.9284** |
| `N2` | `0.45 · (1+2·0.48) · (1−0.60)` | | | | **0.3528** |
| `E_c` | 160 / 32.5 = 4.9231 | 1+0.80·0.48·0.35 = 1.1344 | 1+0.60·0.12² = 1.0086 | 1.00 | **6.3934** |
| | | | | **TOTAL** | **39.105 gm / 880 m** |

*(The `F_cond` column is unchanged by RR-3: `1 − 0.92 = 0.08`, `1 − 0.61 = 0.39`, `1 − 0.88 = 0.12` are exactly the residuals the old `1 − cond/100` produced.)*

Same route clear, `c = 0`, condition **1.0**, both signals powered: `11.8154 + 0.048 + 7.3846 + 0.048 + 4.9231 = ` **24.219 gm**. Degradation factor **1.615×** — the storm-plus-blackout tax on this response is **+14.9 game-minutes**, and the player can read every term of it in the traffic overlay.

Same route as a `CIVILIAN` (`speed_mpgm = 34`, no siren, no relief, `F_wx = 1.18`): `18.676 + 0.258 + 52.356 + 0.882 + 7.752 = ` **79.92 gm** — **2.04×** the fire engine. The accident that costs the engine 4.8 gm costs civilians 35 gm. The privilege system is legible in the numbers, and it is why the traffic overlay's civilian ETA is *not* the dispatch ETA.

### 2.7 A* routing

**Search space:** the *contracted* graph (nodes = intersections/endpoints only). For a mature 320×320-tile city (~12,000 road tiles) this is ≈ 1,800–2,200 nodes, so worst-case exhaustive search is bounded and small.

**Heuristic:**
```
h(n) = manhattan_m(n.tile, goal.tile) / (prof.speed_mpgm * ROAD_CLASS_MULT_MAX)
ROAD_CLASS_MULT_MAX = 1.25   (the fastest class present in the graph)
```
Admissible and consistent: every cost factor is ≥ 1, node delays ≥ 0, and Manhattan distance never exceeds true 4-connected path length. The heuristic depends on `prof.speed_mpgm`, which is constant for a given query, so consistency is preserved.

**Weighting:** `f = g + ε·h`. `ε = 1.00` for `priority ≤ 1` (critical/urgent — optimal paths guaranteed). `ε = 1.25` for `priority ≥ 2` (routine service, construction, ETA queries) — bounded 25% suboptimality in exchange for typically 40–60% fewer expansions.

**Determinism (constitution §5).** The open set is a binary heap ordered by `(f, h, node_id)` — all ties broken by ascending `node_id`. Neighbour iteration is by ascending `edge_id`. Routing consumes **no RNG**. Same graph + same congestion snapshot ⇒ byte-identical path.

**Endpoint snapping.** Start/goal are arbitrary tiles (a station door, an incident anchor):
1. `nearest_road_tile(tile)` searches an expanding ring up to `SNAP_RADIUS_TILES = 6` using a per-land-block bucket index of road tiles. Ties break by `(dist, y, x)`.
2. The snapped tile is looked up in `tile_to_edge` → `(edge_id, index_in_polyline)`.
3. The search is **seeded** with both endpoint nodes of the start edge, each with `g` = the partial cost from the snap index to that node. Goal termination checks both endpoint nodes of the goal edge and adds the goal-side partial cost; the search terminates when the *cheaper* completed goal endpoint's `f` is ≤ the open set's minimum.
4. Same-edge special case: if start and goal snap to the same edge, the answer is `min(direct along-edge cost, around-the-block cost)` — the direct segment is returned immediately without search.

No permanent nodes are created for snapping.

**Failure modes** (`fail_reason`): `NO_ROAD_NEAR_ORIGIN`, `NO_ROAD_NEAR_DEST`, `UNREACHABLE` (component mismatch or class-blocked), `BUDGET_EXCEEDED`.

**Second-chance pass.** If a request has `allow_restricted = true` and the first pass returns `UNREACHABLE`, the planner re-runs with **soft-blocked** edges admitted at `DESPERATE_BLOCK_MULT = 12.0`. Soft blocks: `accident_major`, `debris`, `police_cordon`, `construction_new` (for `CIVILIAN`/`UTILITY`). **Hard blocks are never admitted:** `flood_deep`, `COLLAPSED`. Doc 06 uses this for its last-resort dispatch attempt before reporting "no unit can reach".

### 2.8 Closures

A closure is a first-class record attached to an **edge**. A closure raised on a *node* tile applies to all incident edges.

```
Closure {
  id, edge_ids[], cause, severity 0..1,
  start_minute, expected_end_minute (-1 = until cleared),
  source_incident_id (-1 = none), clearing_unit_id (-1 = none)
}
```

**Cause table.** `BLOCK` = excluded from search for that class.

| cause | CIVILIAN | UTILITY | CONSTRUCTION | EMERGENCY | `cong_add` | hard? | cleared by |
|---|---|---|---|---|---|---|---|
| `accident_minor` | ×3.0 | ×2.2 | ×2.2 | ×1.4 | 0.35 | no | incident resolve (cap 90 gm) |
| `accident_major` | BLOCK | ×4.0 | ×3.5 | ×1.8 | 0.55 | no | incident resolve (cap 240 gm) |
| `flood_shallow` | ×3.5 | ×2.5 | ×2.2 | ×2.0 | 0.40 | no | tile depth < 0.10 m |
| `flood_deep` | BLOCK | BLOCK | BLOCK | BLOCK | 0.50 | **yes** | depth < 0.35 m → becomes shallow |
| `construction_new` | BLOCK | ×2.5 | ×1.0 | ×2.2 | 0.20 | no | job complete |
| `construction_work` | ×2.0 | ×1.6 | ×1.2 | ×1.5 | 0.25 | no | job complete |
| `debris` | BLOCK | ×3.0 | ×1.5 | ×2.5 | 0.45 | no | public-works clear job |
| `police_cordon` | BLOCK | ×1.2 | ×1.2 | ×1.0 | 0.30 | no | incident resolve |

Only **one** closure may be active per edge; a higher-severity cause replaces a lower one (ordering: `flood_deep > accident_major > debris > flood_shallow > police_cordon > construction_new > accident_minor > construction_work`). The replaced closure is retained in a shadow list and reinstated if the dominant one clears first.

**Entering the graph.**
```
roads.add_closure(tile_or_edge, cause, severity, expected_duration_gm, source_incident_id) -> closure_id
```
Effects, applied immediately (not deferred to the next tick):
1. Resolve tile → `edge_ids`.
2. Set `edge.closure_id`, recompute `edge.blocked_mask` from the cause table.
3. `closure_epoch += 1`.
4. Mark the closed edges and all edges within **2 graph hops** dirty for congestion (spillback, §2.10) and force an immediate congestion recompute of that set.
5. Emit `road_closure_opened { closure_id, edge_ids, cause }`.
6. Invalidate cached routes: the planner keeps `edge_id → cached_route_ids` reverse index; every cached route touching a changed edge is dropped, and every **live** route (held by a vehicle) touching it produces `route_invalidated { requester_ids[], reason: CLOSURE }`.

**Leaving the graph.** `remove_closure(id)` — called explicitly by the owning system on resolve, or automatically when `sim_minute ≥ expected_end_minute`. Same steps in reverse; emits `road_closure_cleared`. Auto-expiry caps exist so a lost `incident_resolved` event can never permanently strand a district.

**Vehicles caught by a new closure.**
- **Soft block:** the vehicle finishes its current edge, then reroutes from the node it reaches.
- **Hard block** (`flood_deep`, `COLLAPSED`): the vehicle reverses to the node it last passed, paying `REVERSE_PENALTY = 0.50 gm`, then reroutes. If no route exists, doc 06 returns it to station or holds it in place with status `STRANDED`.

### 2.9 Reachability & components

Every node carries `component_id` from a union-find structure.
- **Road added:** union the touched components — O(α).
- **Road removed / hard-blocked:** may split. The removal marks the affected component `dirty`; a BFS re-labels it, budgeted at `COMPONENT_BFS_BUDGET = 4000` tiles per tick, resumable. While any component is dirty, `is_reachable()` returns `true` conservatively and the fast reject is skipped (full A* decides).

`is_reachable(a, b, vc)` is O(1) in the common case and is the cheapest thing doc 06 can call. Note it is *class-aware only for hard blocks* — soft-blocked edges are still "reachable" but expensive.

### 2.10 Congestion model

One scalar per edge: **`congestion_index c_e ∈ [0, 2]`, where `1.0 = at capacity`** — doc 06's scale, adopted verbatim so `f_flow`, `traffic_accident` generation and `congestion_ref = 1.5` in doc 06 §2 need no conversion. **No civilian vehicles are simulated.**

```
c_raw(e) = clamp( K_base(class_e) * D_tod(e,t) * L_dens(e) * E_evt(e,t)
                  + I_inc(e)
                  + wx_cong_add(weather),
                  0.0, 2.0 )

c_e  ←  c_e + (c_raw(e) - c_e) * smooth(dt)
smooth(dt) = 1 - (1 - CONG_SMOOTH) ^ (dt_game_minutes)      CONG_SMOOTH = 0.35 per game-minute
```

**Cadence and phase (doc 01).** Roads occupies **phase P08, every step**, after `WEATHER` (P04), `POWER` (P06) and `WATER` (P07), before `VEHICLES` (P09) — so a signal that goes dark at P06 slows the ambulance dispatched at P09 in the *same* step, with zero lag. Within P08:
- **Every step:** re-read power state for signalised nodes; expire closures and speed overrides; apply batched road edits; recompute `c_e` for the **dirty set only** (edges whose closure, override, or signal power changed since last step) — typically 0–40 edges.
- **`EVERY_MINUTE`:** full recompute across all edges (~2,000 edges ≈ 0.15 ms).
- **`EVERY_DAY`:** `L_dens` refresh, condition decay, auto-repair queueing. *(No upkeep pass — roads have no standing upkeep, RR-2.)*

The dt-aware `smooth()` exponent is what makes coarse offline steps agree with fine online steps: one 1-game-hour coarse step applies `1 − 0.65^60 ≈ 1.0`, i.e. it lands exactly on `c_raw`, which is also where 60 fine steps converge. **This is required for doc 06's mode-invariance guarantee** and is asserted by test 40.

**Time sampling.** `D_tod` reads the hour-of-day from doc 01's frozen `TimeContext` (fine step: `hour + (minute + 0.125)/60`; coarse step: `h + 0.5`). Roads never samples the clock itself.

**`D_tod(e,t)` — time-of-day demand.** Four land-use profile curves, 24 hourly samples, linearly interpolated. Each district (doc 09) carries normalised `profile_weights = {res, com, ind, civ}` recomputed once per game-day from its building mix (doc 02).

```
D_tod(e,t) = Σ_p  profile_weights[district_of(e)][p] * lerp(curve[p][h], curve[p][h+1], frac)
```

The four 24-entry curves are in `tunables.tod_curves` (§8). Shape: `res` twin-peaks at 07:00 (0.85) and 18:00 (0.95); `com` plateaus 09:00–17:00 (0.85–0.95); `ind` is flat-shifted, peaking 16:00 (0.75) and never below 0.18 overnight; `civ` peaks 07:00 (0.75) and 15:00 (0.75) for school and shift changes.

**`L_dens(e)` — local development density.**
```
L_dens(e) = clamp(0.20 + DENS_K * pj(e), 0.20, 1.60)     DENS_K = 0.0022
pj(e) = Σ (population + jobs) of buildings whose access tile is within 6 tiles of any tile of e
```
Recomputed per edge on `building_changed` and once per game-day for all edges (~2,000 spatial queries/day = negligible).

**`E_evt(e,t)` — event spike.** Default `1.0`. Driven by doc 01's `ScheduledEventService` (phase P03, which opens event windows *before* P08 in the same step). For a venue event at tile `V`:
```
E_evt = 1 + EVENT_PEAK * ramp(t) * max(0, 1 - graph_dist_tiles(e,V) / EVENT_RADIUS_TILES)
EVENT_PEAK = 1.40   EVENT_RADIUS_TILES = 40
ramp(t) = 1.00 in [start-45gm, start]        (inbound)
          0.25 in (start, end)               (during)
          1.00 in [end, end+45gm]            (outbound)
          0.00 otherwise
```
Evacuation order (doc 07, post-MVP): `E_evt = 1 + 2.50` on all edges of evacuating districts, linearly decaying to 1.0 over `EVAC_DECAY = 180 gm`.

**`I_inc(e)` — incident/closure additive.**
```
I_inc(e) = cong_add(own closure)
         + 0.50 * Σ cong_add(closures 1 graph hop away)
         + 0.25 * Σ cong_add(closures 2 graph hops away)
         + DARK_SIGNAL_ADD * (# endpoint nodes that are signalised and unpowered)
DARK_SIGNAL_ADD = 0.19
```
`DARK_SIGNAL_ADD` is the second half of the doc-10-owned signal-outage penalty (report 98 G-6; the first half is `DARK_SIGNAL_DELAY 0.45 gm` in §2.6). It is the *congestion* consequence of a dark intersection, distinct from and additive to the *delay* consequence, and it is why a blackout makes a district slow even for a vehicle that never stops at a light.
Spillback is computed by BFS depth 2 outward from each closure (closures are few — capped at `MAX_ACTIVE_CLOSURES = 128`), not by scanning every edge.

**No feedback loop.** Congestion feeds routing cost, cosmetic spawn density, the traffic overlay, accident hazard, and condition decay. It does **not** feed back into `D_tod` or `L_dens`. This is a deliberate anti-oscillation decision: the model is a forward function of city state and time, so it is stable, cheap, and reproducible offline.

**Worked example D — one street edge across a day.**
Mixed district, `profile_weights = {res .55, com .30, ind .05, civ .10}`, `pj = 410` → `L_dens = 0.20 + 0.0022×410 = 1.102`. STREET → `K_base = 1.00`.

| time | `D_tod` | base product | weather | additive | `c_raw` | reading |
|---|---|---|---|---|---|---|
| 02:00 | .0565 | 0.0623 | clear 0 | — | **0.062** | empty |
| 13:00 | .5725 | 0.6309 | clear 0 | — | **0.631** | free-flowing |
| 17:40 | .8542 | 0.9414 | clear 0 | — | **0.941** | at capacity |
| 17:40 | .8542 | 0.9414 | heavy_rain +.19 | 1 dark signal +.19 | **1.321** | over capacity |
| 17:40 | .8542 | 0.9414 | heavy_rain +.19 | + `accident_minor` +.56 | **1.881** | near gridlock |

(`D_tod` at 17:40 = `.55×lerp(.90,.95,.667) + .30×lerp(.95,.85,.667) + .05×lerp(.65,.45,.667) + .10×lerp(.60,.45,.667)` = `.55×.9333 + .30×.8833 + .05×.5167 + .10×.50` = `.8542`.)

Note that the worst case reaches **1.881**, not the clamp — the `[0,2]` headroom is real, and only a disaster-scale combination (blizzard + major accident + district blackout) saturates it. That is deliberate: doc 06's `f_flow = clamp(c, 0.05, 2.0)^1.5` must keep discriminating at the top end.

Contrast, same hour, same district, on an **AVENUE** with `pj = 900` (→ `L_dens` clamped 1.60), commercial weights `{res .20, com .70, ind 0, civ .10}` → `D_tod = .855`, `c_raw = 0.64 × .855 × 1.60 = **0.876**` (at capacity). Same corridor built as street: `1.00 × .855 × 1.60 = **1.368**` (over capacity). Combined with `S_cong` (0.55 vs 0.80), the avenue is **1.9× cheaper in travel-cost terms at rush hour** — that is what its price premium and its 2.8× build work (`1.40` vs `0.50` crew-hours/tile) buy. *(The former "2.9× build cost" gloss is deleted with the price table under RR-2; doc 03's `data/economy.json` sets the actual ratio.)*

**Smoothing ramp.** From `c = 0.90` toward `1.881` at 1 game-minute per step: `1.244 / 1.467 / 1.612 / 1.807` after 1/2/3/6 minutes. A jam is visible on the overlay in ~2 game-minutes and settles in ~6 — fast enough to read as a consequence of the accident, slow enough not to flicker.

### 2.11 Traffic-accident generation is **doc 06's**, not this doc's

Doc 06 §2 already owns the `traffic_accident` hazard model (`f_flow`, `dark_frac`, per-intersection base rate, the `incidents` RNG stream, the 0.69/game-day worked example). **Doc 10 defines no competing accident formula.** It supplies the three inputs doc 06 names and nothing more:

```
congestion_index(edge_id) -> float          # 0..2, this step's value
signalised_intersections(district_id) -> [ { node_id, tile, powered: bool } ]
access_quality(pos) -> float                # 0..1, see §5.2
```
`dark_frac` for a district = `count(signalised ∧ ¬powered) / count(signalised)`, computed by doc 06 from that list. Roads guarantees the list is stable within a step and refreshed at P08 before doc 06's P11 incident phase.

Roads *does* own the **road-condition contribution**, which doc 06 has no visibility into. It is exposed as a multiplier for doc 06 to fold into its own rate:
```
condition_hazard_mult(e) = 1 + COND_ACC_K * max(0, COND_ACC_THRESHOLD - condition_e)
COND_ACC_K = 0.40      COND_ACC_THRESHOLD = 0.75
```
**Rescaled to `[0,1]` per RR-3**, with the coefficient multiplied by 100 so every output is byte-identical to the old `[0,100]` form: a failing road at condition **0.10** returns `1 + 0.40 × 0.65 = ` **1.26**; a worn road at **0.55** returns `1 + 0.40 × 0.20 = ` **1.08**; anything at or above **0.75** returns **1.00**. Doc 06's test 30 consumes `1.00 / 0.55 / 0.10`, not `100 / 55 / 10`. **Doc 06 multiplies this into its `traffic_accident` rate** — ruled in this doc's favour by report 98 C-48, because without it road condition has no safety consequence at all and maintenance degrades to a pure travel-time tax. No change is owed by doc 10; §9.2 X-5 records the closure.

### 2.12 Road condition & damage

Condition is stored **per tile** on `[0,1]` (RR-3); edge condition is the tile mean.

**Decay, applied once per game-day** (constitution §4 population/growth cadence):
```
decay(tile) = base_decay(class) * (1 + 0.75 * c_day(e)) * (1 + wx_wear_day)
base_decay   = 0.0090 / game-day (STREET), 0.0060 / game-day (AVENUE)   ← RR-3: former 0.90 / 0.60 pts, /100
c_day(e)     = mean of c_e over the 24 hourly congestion samples of that game-day
wx_wear_day  = max wx_wear observed that game-day (tunables.weather, §8)
```
Examples (all rescaled by RR-3; the *durations* are unchanged because both the rate and the range divided by 100):
- street, `c_day = 0.35` (quiet), clear → `0.0090 × 1.2625 = ` **0.011363 / day** → `1.0 → 0` in `1 / 0.011363 = ` **~88 game-days**;
- street, `c_day = 0.80` (busy), one snow day → `0.0090 × 1.60 × 1.80 = ` **0.02592 / day**;
- avenue, `c_day = 0.88`, clear → `0.0060 × 1.66 = ` **0.00996 / day**.

At 1 game-day = 24 real minutes, a neglected busy street needs attention roughly every 10–15 real hours of play. Maintenance is a recurring but not nagging decision.

**Instant damage.** These deltas are also the **damage fractions** this doc publishes per cause under C-16 — doc 03 multiplies them by `capital_value` to price the resulting repair. They are physical constants and are **kept** by RR-2.

| source | condition delta (= damage fraction) | applies to |
|---|---|---|
| `accident_major` resolve | **−0.08** | 3 tiles nearest the incident |
| `flood_deep` receding | **−0.15** | every tile that was deep-flooded |
| `flood_shallow` receding | **−0.04** | every tile that was shallow-flooded |
| structure fire adjacent (doc 06) | **−0.06** | tiles orthogonally adjacent to the burning footprint |
| earthquake (post-MVP) | **−0.40**, 12% chance `COLLAPSED` | all tiles in radius |

**Condition tiers.**

| tier | range | `F_cond` | extra effects |
|---|---|---|---|
| Good | 0.75–1.00 | 1.000–1.038 | — |
| Worn | 0.50–0.75 | 1.038–1.150 | hazard term engages below 0.75 |
| Poor | 0.25–0.50 | 1.150–1.338 | cosmetic patches; civilian visual speed −10% |
| Failing | 0.01–0.25 | 1.338–1.588 | pothole VFX; `road_condition_critical` event at **0.20** |
| Collapsed | 0 | — | **IMPASSABLE for all classes**, `road_collapsed` event, P2 notification |

Collapse is a genuine failure state: a collapsed tile can sever a district from its fire station. It is repaired only by a full rebuild.

**Repair (a doc 02 `ConstructionQueue` job running on doc 01's `WorkService` accumulator).**
```
damage_fraction = 1 - condition                                   ← RR-3 scale; this is the C-16 argument
crew_hours      = ROAD_REPAIR_HOURS_BASE * damage_fraction        ROAD_REPAIR_HOURS_BASE = 0.35 ch / tile
work_units      = round(crew_hours * 100)                         ← doc 02's WORK_UNITS_PER_CREW_HOUR (G-2)
cost            = economy.repair_cost(road_tile_asset, damage_fraction)   ← doc 03, C-16 / RR-2
minimum job     = 4 contiguous tiles
result          = condition set to 1.0
during the job  = `construction_work` closure on the tiles
```
**Repair pricing is doc 03's (RR-2).** The former `cost_per_tile = ROAD_REPAIR_COST_BASE × (1 − condition/100)` with `ROAD_REPAIR_COST_BASE = $600` is **deleted from this doc and from `data/roads.json`**; the price now comes from doc 03's single C-16 formula `capital_value × damage_fraction × 0.85 × M_repair`, with `capital_value` taken from the per-tile build price in `data/economy.json`. Doc 10 supplies `damage_fraction` and the crew-hours; it quotes no dollars.

**Worked example F — a 12-tile street repair at condition 0.40** (recomputed for C-29, G-2 and now RR-2/RR-3):
`damage_fraction = 1 − 0.40 = ` **0.60** · `crew_hours = 12 × 0.35 × 0.60 = ` **2.52 ch** · `work_units = round(2.52 × 100) = ` **252** · `cost = economy.repair_cost(street_tile ×12, 0.60)` — **doc 03 quotes it; this doc does not.**
Wall time is *not* 2.52 gh, because the `construction_rate` channel is mandatory (C-29): a `road_crew` (`crew_rate 1.00`) at the channel's 0.804 mean takes `2.52 / (1.00 × 0.804) = ` **3.13 gh**; a generic `construction_crew` (`0.70`) takes `2.52 / (0.70 × 0.804) = ` **4.48 gh**; the same job worked only across the 0.60 night floor by one road crew takes `2.52 / 0.60 = ` **4.20 gh**. *(The former figures quoted 2.52 gh of wall time, 9,072,000 milli-units and a `$4,320` doc-10 price; the first two omitted the channel and used a unit doc 02 does not use, and the third is now doc 03's to quote.)*

Rebuilding a COLLAPSED tile (`condition = 0`, so `damage_fraction = 1.0`) costs the full build price of its class from `data/economy.json` and the full build work of its class from §2.3 — **50 work units** for a STREET tile, **140 work units** for an AVENUE tile.

**Auto-maintenance policy** (spec §21.3, keeps the offline city viable):
```
auto_repair_threshold : 0 (off) | 0.25 | 0.40 | 0.55          ← RR-3 scale
auto_repair_daily_cap : dollars per game-day (default $25,000)
```
Once per game-day, roads groups every tile below the threshold into contiguous runs, sorts by `(mean congestion desc, condition asc)`, and submits repair jobs until the cap or the crew queue limit (`AUTO_REPAIR_MAX_JOBS_PER_DAY = 3`) is hit. The cap is a **player budget setting**, not a price: roads evaluates each candidate run against the quote doc 03 returns from `economy.repair_cost(...)` (RR-2) and stops when the running total would exceed it. Doc 10 authors no dollar figure here except the default cap itself, which is a UI default and moves to `data/economy.json` if doc 03 wants it.

### 2.13 Build, upgrade, demolish

**Validation** (all must pass, else the command is rejected with a reason code):
1. Every tile is on **owned and developed** land (doc 09).
2. Tile is not inside a building footprint (doc 02) and is not water (bridges deferred).
3. The new tile set contains at least one tile orthogonally adjacent to an existing road tile, **or** the whole set lies inside a land block being developed.
4. Treasury ≥ total cost, **quoted by doc 03 from `data/economy.json`** (RR-2 — this doc holds no per-tile price to quote from); `ConstructionQueue.submit` charges through doc 03 at submission.
5. The job is accepted by **doc 02's `ConstructionQueue`**; if no crew is free it enqueues rather than failing.

**Job submission — doc 02's `ConstructionQueue` (report 98 G-2, API named as doc 02 publishes it).** Construction crews and the project queue are a three-way split: doc 06 owns crews as dispatchable units, doc 02 owns the project record and progress in `sim/construction/`, doc 09 owns the land-development phase→crew-type mapping, and **doc 10 submits road jobs to doc 02's queue**. This doc runs no queue of its own.

| call | roads' use |
|---|---|
| `ConstructionQueue.submit(job) -> job_id` | every `road_build` / `road_upgrade` / `road_repair` / `road_demolish` command, and each auto-repair run (§2.12). `job = {kind, tiles, class, required_crew_hours, cost, preferred_crew: "road_crew", fallback_crew: "construction_crew"}`. Validates, charges doc 03, enqueues at the tail. |
| `ConstructionQueue.reorder(job_id, new_index) -> bool` | doc 12's player-facing queue reordering; roads holds no opinion. |
| `ConstructionQueue.cancel(job_id) -> refund_fraction` | `road_job_rejected` / player cancel; doc 03 converts the fraction to dollars. |
| `ConstructionQueue.list(filter) -> [project]` | the road-jobs panel in doc 12. |

Roads consumes doc 02's events `job_started{job_id, target_ref, crew_ids}` (→ open the `construction_new` / `construction_work` closure), `job_completed{job_id, target_ref}` (→ condition **1.0**, clear flag, remove closure, emit `road_built`), `job_cancelled{job_id, refund_fraction}` and `job_blocked{job_id, reason}` (→ emit `road_job_rejected`). Crew preemption at doc 06's priority 400 pauses a road job without losing `work_units`; `auto_dispatch_construction = false`, so a road crew is never pulled off a job for a routine call.

**Under-construction lifecycle.** New tiles enter the tile grid *immediately* with `class` set, `condition = 0.10` (RR-3), `UNDER_CONSTRUCTION` flag, and a `construction_new` closure (CIVILIAN **BLOCK**, EMERGENCY ×2.2, CONSTRUCTION ×1.0). They therefore participate in the graph — the crew can reach the far end of its own job, and the player can see the corridor forming — but they carry no civilian traffic and are a poor emergency route until finished. On `job_completed`: condition → **1.0** (RR-3), flag cleared, closure removed, `road_built` emitted.

**Upgrade street → avenue:** `0.9 crew-hours/tile` (`90 work units/tile`), priced by doc 03 (`data/economy.json → roads.upgrade_street_to_avenue`; the former `$4,000/tile` is deleted from this doc per RR-2), requires the tile to have no active closure other than `construction_work`; applies `construction_work` during the job; condition is preserved (not reset).

**Demolish:** refunded at doc 03's road demolish-refund fraction (formerly 15% here; the fraction moves to `data/economy.json` with the price it multiplies, RR-2). **Rejected** if, after removal, any building's access tile would have no adjacent road tile, or would land in a graph component that contains no station of any department. (Cheap check: simulate the removal against the union-find, evaluate only buildings whose access tile is within 2 tiles of the removed set.)

**As shipped (Wave 5).** The three verbs live in `sim/city_sim.gd` as `cmd_place_road(tiles, road_class, preview)`, `cmd_upgrade_road(tiles, preview)` and `cmd_demolish_road(tiles, preview)`. This doc keeps the geometry, the lifecycle and the reason codes; `CitySim` joins them to doc 03's money and doc 02's queue, and is the only place a road command can move a dollar. Notes on what the integration pinned down:

| point | as shipped |
|---|---|
| check order | `E_UNKNOWN_ROAD_CLASS` → `E_NO_TILES` → this section's own set (`E_OUT_OF_BOUNDS` · `E_WATER` · `E_FOOTPRINT` · `E_NOT_DEVELOPED` · `E_NOT_CONNECTED`) → `E_ALREADY_ROAD` → `E_FUNDS` / `E_AUSTERITY`. Money is always last, so a refusal names the real problem. |
| what is billed | the **fresh** tiles only. A drag that crosses existing pavement pays for what it lays. |
| build over an existing road | **skipped, not re-laid.** Build, upgrade and demolish stay three verbs: re-laying STREET over AVENUE would be a silent downgrade, and re-laying AVENUE over STREET would buy the §2.13 upgrade at the build price *and* reset the tile to `under_construction_seed`. |
| the orphan test | doc 02 owns the access list, so `CitySim` supplies one representative tile per building near the removed set — chosen so this doc's per-tile rule reproduces doc 09 §2.9.1's per-BUILDING one (a building survives if ANY footprint tile keeps a neighbouring road). The code and the event stay here. |
| freeing the ground | `TileGrid.set_road` clears `BUILDABLE` when a tile is paved and does not restore it when the pavement goes, so the coordinator re-opens a demolished tile. Without that, ripping up a road sterilised the tile for the life of the city. |
| `E_NO_QUEUE` | unreachable in the integrated build — `submit_job` is always injected — and kept for the fixtures that construct a bare `RoadNetwork`. |

### 2.14 Routing performance budget

| constant | value | meaning |
|---|---|---|
| `MAX_ROUTES_PER_TICK` | 6 | full A* runs started or resumed per SimTick |
| `EMERGENCY_OVERFLOW` | 3 | extra P0/P1 routes allowed above the cap |
| `MAX_EXPANSIONS_PER_TICK` | 1500 | total node pops across all jobs this tick |
| `MAX_EXPANSIONS_PER_ROUTE` | 600 | before a job is suspended and resumed next tick |
| `MAX_ROUTE_TICKS` | 6 | ⇒ 3600 expansions ⇒ ≥ full-graph coverage; then fail |
| `ROUTE_CACHE_SIZE` | 256 | LRU entries |
| `DISPATCH_CANDIDATES` | 3 | how many units doc 06 should full-route after ranking |
| `PRIORITY_AGE_TICKS` | 8 | a queued request gains one priority level per 8 ticks (starvation guard) |

**Request queue.** A min-heap ordered by `(effective_priority, submit_tick, ticket_id)`. `effective_priority = max(0, priority - floor(wait_ticks / PRIORITY_AGE_TICKS))`.

**Resumable jobs.** An A* job is a plain object holding `open_heap, g[], came_from[], parent_edge[], visited_stamp, expansions`. Suspension is free (nothing is torn down). This makes the worst case a *latency* cost (≤ 1.5 game-minutes), never a frame hitch.

**Route cache.** Key `(start_snap_key, goal_snap_key, route_class, speed_mpgm, graph_version, closure_epoch, quantised_congestion_epoch)`. Value stores `edge_ids`, `tiles`, `length_m`, and the `congestion_epoch` at compute time.
- **Congestion changes do NOT invalidate cached paths** — only their prices. On a hit with a stale `congestion_epoch`, the ETA is re-summed over the cached edge list (≤ ~60 edges → ~5 µs) and returned. This is the single most important optimisation: paths are far more stable than prices.
- Structural changes (`graph_version`) and closures (`closure_epoch`) *do* invalidate, via the `edge_id → route_ids` reverse index.

**O(1) estimates** — doc 06 and doc 12 must use these before asking for real quotes:
```
estimate_eta(a, b, prof)           = manhattan_m(a,b) / (prof.speed_mpgm * 1.25)   # optimistic, admissible
estimate_eta_practical(a, b, prof) = estimate_eta(a,b,prof) * DETOUR_FACTOR
                                     * (1 + 0.45 * district_mean_congestion(a,b))
DETOUR_FACTOR = 1.25
```
(The `0.45` coefficient is `0.90` halved for the `[0,2]` congestion scale, so a district at capacity still adds ~45%.)

`estimate_eta` never over-estimates, so doc 06 may prune with it safely. `estimate_eta_practical` is the **ranking** function. **The intended pattern: rank every candidate unit with `estimate_eta_practical` (O(1), so ~40 units per frame is free — this is what doc 12's unit picker needs), then call `route_minutes` for only the top `DISPATCH_CANDIDATES = 3`.** With ~40 units and ~6 concurrent incidents that is ≤ 18 real quotes, most of them cache hits, comfortably inside the budget.

**Worked example E — dispatch of one structure fire.** 5 engines available. Doc 12's picker calls `estimate_eta_practical` 5× (≈ 2 µs total) and shows the list instantly. Doc 06 ranks them: `8.1 / 9.4 / 11.0 / 19.2 / 26.5 gm`. It then calls `route_minutes` for the top 3 only. Engine 2's optimistic 9.4 becomes a real **9.9 gm**; Engine 1's optimistic 8.1 becomes **14.6 gm** because its only corridor has an `accident_minor` closure; Engine 3's 11.0 becomes **11.4 gm**. Dispatch picks **Engine 3**, and the reason — a closure the player can see on the traffic overlay — is fully legible. Cost: 3 A* runs, ~1,200 expansions total, one tick.

**Hierarchical routing — deferred, with a trigger.** Post-MVP design: an abstract graph whose nodes are the road tiles crossing land-block boundaries, with intra-block all-pairs distances precomputed per block and invalidated per block on edit; A* runs on the abstract graph and refines only the first and last blocks. **Enable when**: median expansions per emergency route > 800 **or** road tiles > 8,000 **or** measured routing cost > 4 ms/tick on the reference device. Until then the contracted-graph A* is measured, not assumed, by the perf test in §7.

> #### Measured 2026-08-20 — the trigger fires on a workload dispatch never pays, and hierarchical routing is NOT required (Wave 9, report 98 RR-27)
>
> `tests/test_roads_integration.gd` has printed *"median P0 expansions 1154 vs trigger 800 → hierarchical routing REQUIRED"* since the reference map existed, and doc 06 §2.10's wiring was held for two waves partly on the strength of it. **The trigger is measuring six deliberately corner-to-corner routes, and §2.14's own rank-then-quote contract means no dispatch quote is ever one of those.** `tools/profile_routing.gd` is the instrument that measures the shape doc 06 really produces: boot a city, age it, rank every station on `estimate_eta_practical`, and time `travel_gs_for` — the seam call, cache and re-price and rounding included — for the nearest `DISPATCH_CANDIDATES = 3`.
>
> Benchmark city (3,132 road tiles, 2,024 nodes, 3,092 edges), aged 120 game-hours so condition, congestion and closures are live, cold cache, `epsilon_critical = 1.0`, 60 incidents:
>
> | per quote | rank-then-quote (nearest 3) | quote every station (16) |
> |---|---|---|
> | mean | **0.709 ms** | 2.862 ms |
> | median | 0.556 ms | 2.179 ms |
> | p90 | **1.360 ms** | 6.365 ms |
> | max | 4.254 ms | 13.033 ms |
> | expansions | **46.6** | 206.2 |
> | **per incident** | **2.13 ms** | 45.8 ms |
>
> Ranking does not merely buy fewer quotes, it buys **cheaper** ones: it picks the near stations, and a near route is a small search. Twenty-one times less work per incident, and the mean quote is **seven times** cheaper than the ≈ 5 ms the Wave-8 note recorded — because that 5 ms was a cross-city miss.
>
> **The landmark (ALT) overlay was built, measured and not shipped.** A speed-independent lower-bound metric (`length_m / road_class_mult`, which every doc §2.6 multiplier can only raise), four farthest-point landmarks, one Dijkstra each, rebuilt only when the graph's shape grows — provably admissible, so the search returns the identical optimum. It does, and the measurement says it is not worth its own arithmetic:
>
> | arm (bench city, ranked quotes) | expansions | quote mean | mean route |
> |---|---|---|---|
> | no overlay | 46.6 | **0.696 ms** | 5.008170 gm |
> | ALT overlay | 45.8 (−1.7 %) | 0.758 ms (**+9 %**) | 5.008170 gm |
>
> and on the reference map the same overlay cut expansions 6,921 → 5,534 (−20 %) while taking 110.8 → 141.6 ms (+28 %). **The reason is structural, and it is why the block abstraction sketched above would not have helped either.** Slacum City's road network is a block grid, so `manhattan_m / (speed · class_mult_max)` is already within a few per cent of the true cost; the expansions are not heuristic slack, they are a **plateau** of nodes that all share the optimal `f`, and no sharper *admissible* heuristic can remove a plateau. Only a weighting can.
>
> **The epsilon policy, stated.** `epsilon_critical` **stays 1.0**. It is right for a fire engine's own route — an admissible, unweighted A\* whose answer is the arrival time §4 guarantee 1 promises — and the reason it is now also *affordable* inside §2.10's per-sub-step loop is that rank-then-quote bounds both the count (≤ `MAX_ASSIGNMENTS_PER_TICK × DISPATCH_CANDIDATES` per pass) and the length of what is quoted. For the record, weighting is the lever that would work if it were ever needed: the same 180 ranked quotes at `epsilon_routine = 1.25` cost **0.476 ms** (−32 %) at 29.2 expansions (−37 %) and lengthen the mean quoted route by **0.025 %** — 1.2 game-seconds on a 5 gm trip.
>
> **What remains.** (a) The **tail**, not the mean: p90 1.36 ms and max 4.25 ms are cold-cache misses to an incident with no station near it, and the honest mitigation for those is a station, not a router. (b) The trigger in §8 still reads `hierarchical_trigger_median_expansions: 800` against the six-corner-route metric; the tunable is **unchanged** so the historical series stays comparable, but the reading below is the one that decides anything. (c) None of this is measured on device — every number here is a debug headless workstation number (§9.3 C-3's ladder ends at GDExtension for exactly that reason).
>
> **The re-stated trigger.** Build hierarchical routing when **the mean rank-then-quote seam call on the benchmark city exceeds 1.5 ms**, or when `road_tiles > 8,000`, or when measured routing cost exceeds 4 ms/tick on the reference device. The first clause is the one this wave supplies a number for: **0.709 ms, 47 % of budget**.

### 2.15 Cosmetic civilian traffic

**Zero simulation authority.** Civilian cars exist only in `game/`, are never saved, never affect congestion, never collide, and never appear in any sim query. Turning them off changes nothing except the picture. They use a renderer-local RNG, **not** a sim RNG stream, so they cannot perturb determinism.

**Spawn eligibility.** An edge spawns cars only if: in the camera frustum expanded by one land block; within `CIVILIAN_MAX_DIST = 320 m` of the camera focus point; not hard-blocked; not `construction_new`; condition > 0.

**Target population per edge:**
```
n_e = round(CIV_DENSITY_K * c_e * length_m(e) / 100)     CIV_DENSITY_K = 0.9
n_e = clamp(n_e, 0, MAX_CARS_PER_EDGE = 6)
```
A 200 m edge at `c = 1.0` (at capacity) → `0.9 × 1.0 × 2 = 1.8` → **2 cars**. At `c = 1.8` → **3 cars**. At `c = 0.3` (early morning) → **1 car**.

**Global caps by graphics preset:** Performance **40**, Balanced **90**, High **160** simultaneous cars. When at cap, edges are served in descending `c_e × visibility` order.

**Spawn/despawn rules:**
- Spawn preferentially at an endpoint node that is off-screen. If both endpoints are on-screen, spawn at a random point ≥ 15 m from any existing car with a **0.40 s fade-in**.
- Despawn when off-screen for > 1.5 s, when `n_e` drops (oldest first, 0.40 s fade-out), when the edge becomes hard-blocked, or when the global cap is exceeded.
- At a node, a car picks a uniformly random outgoing edge excluding the one it arrived on; reversal is allowed only at dead ends.

**Motion:** `v = CIVILIAN_BASE_SPEED_MPGM × road_class_mult(class) × (1 − 0.325 × c_e) × jitter`, with `CIVILIAN_BASE_SPEED_MPGM = 34`, `jitter ∈ [0.85, 1.15]`, plus a `0.90×` factor on Poor/Failing condition tiers. At gridlock (`c = 2`) cars crawl at `0.35×`. Cars stop for `SIGNAL_DELAY × (1 + c_e)` at powered signalised nodes and `DARK_SIGNAL_DELAY × (1 + 2c_e)` at dark ones — the visible manifestation of the blackout cascade, and the reason a dark intersection *looks* wrong before the player opens the overlay.

**Night:** headlights between 19:00 and 06:00 game time. In a blacked-out district, headlights and emergency beacons are the only moving light sources — the signature visual (constitution §11). Doc 11 owns the light budget; roads only supplies positions and the `dark` flag.

**Rendering hooks the sim provides** (`TrafficSnapshot`, rebuilt every game-minute):
```
visible_edges[]  : { edge_id, tiles, congestion, closure_cause, condition_tier, blocked_mask, node_a_dark, node_b_dark }
active_closures[]: { edge_ids, cause, severity }
overlay_bands    : c < .25 clear · < .50 light · < .75 heavy · < .90 severe · ≥ .90 gridlock
```
Overlay encodes state as **colour + pattern** (dashed = closure, hatched = flooded, dotted = under construction) per spec §49.

---

## 3. Data Schema

### 3.1 `data/roads.json`

The complete tunables block is in §8. Its top-level keys are:
`version`, `classes`, `route_classes`, `cost`, `node_delay`, `congestion`, `tod_curves`, `weather`, `closures`, `condition`, `build`, `routing`, `civilian_traffic`, `hazard`, `access_quality`.

### 3.2 Save section — `save.roads`

**Section key naming (report 98 C-25).** The per-section version key is **`section_version`**, never `schema_version`. `schema_version` exists **only** on the save envelope's top level (constitution §9, doc 08). This doc's former inner `schema_version` key is renamed. The `roads` section is registered to doc 10 in report 98 §11's canonical registry (it was missing from doc 08's original registry — G-9, now corrected).

The **graph is derived and is never serialised**. On load it is rebuilt in full from the tile grid (measured target: < 30 ms for 12,000 road tiles) and closures are re-applied. Congestion is **not** saved — it is a pure function of time-of-day, density, weather, and closures, so it is recomputed cold at load with smoothing bypassed (`c = c_raw` on the first tick). The route cache is not saved.

```json
{
  "section_version": 1,
  "blocks": {
    "3,4": {
      "class":     [[0, 34], [1, 16], [0, 96], [2, 16], [0, 94]],
      "condition": [[0, 34], [88, 16], [0, 96], [93, 16], [0, 94]],
      "flags":     [[0, 256]]
    }
  },
  "closures": [
    {
      "id": 37, "edge_tiles": [[27,44],[28,44],[29,44]],
      "cause": "accident_major", "severity": 0.8,
      "start_minute": 184402, "expected_end_minute": 184530,
      "source_incident_id": 913, "clearing_unit_id": -1
    }
  ],
  "next_closure_id": 38,
  "speed_overrides": [
    { "edge_tiles": [[31,44],[32,44]], "mult": 0.60, "until_minute": 184460 }
  ],
  "auto_repair": { "threshold": 0.40, "daily_cap": 25000 },
  "condition_accum": { "3,4": 0.0042 },
  "event_spikes": [
    { "venue_tile": [64,88], "start_minute": 187200, "end_minute": 187380 }
  ]
}
```

Notes:
- `blocks` is keyed by land-block coordinate; only blocks containing ≥ 1 road tile are present. Each of the three arrays is a **run-length encoding** `[value, run]` over the block's 256 tiles in row-major local order. **Recomputed for doc 09's 87-tile template (C-60):** a block carrying the stamped template alone (rows/cols `{0,15}` AVENUE, row/col `7` STREET) encodes to exactly **55 runs** per array, not the ~40 the deleted `{0,8}` 60-tile grid produced. Estimated cost for a mature 200-block city: `200 blocks × 3 arrays × 55 runs × ~7.5 B ≈ ` **~250 KB** of JSON (was ~180 KB) — still acceptable per constitution §2 (JSON saves, binary is a post-alpha optimisation). The §7 test-25 reference map of 12,000 road tiles is `12,000 / 87 ≈ 138` blocks ⇒ `138 × 3 × 55 × 7.5 ≈ ` **~171 KB**, comfortably inside test 39's 400 KB assertion.
- `closures` and `speed_overrides` store **tile lists**, not edge ids, because edge ids are derived and unstable across a load. On load each tile list is resolved back to edge ids.
- The `condition` RLE stores the **uint8 quantisation** `round(condition × 100)`, not the float — so `88` and `93` above are conditions **0.88** and **0.93** on the RR-3 `[0,1]` scale. The wire format and save size are unchanged by the rescale; only the in-memory and in-doc scale moved.
- `condition_accum` carries the **sub-quantum (< 0.01)** fractional decay remainder per block so daily decay is lossless across saves. *(RR-3: formerly "sub-1.0", when a quantum was one condition point.)*
- Migration: `migrate_roads_v1_to_v2` will be added when the schema changes; the loader tolerates unknown keys and missing optional keys (`auto_repair`, `event_spikes`) by falling back to defaults.

### 3.3 Runtime (non-serialised) structures

`RoadGraph`: `nodes: Array[Node]`, `edges: Array[Edge]`, `tile_to_edge: Dictionary[Vector2i → int]`, `tile_to_node: Dictionary[Vector2i → int]`, `components: UnionFind`, `road_tile_buckets: Dictionary[block_coord → PackedVector2iArray]`, `graph_version: int`, `closure_epoch: int`, `congestion_epoch: int`, free-lists for node and edge ids.

---

## 4. Sim API Sketch

```
sim/roads/road_network.gd      RoadNetwork      tiles, edits, condition, closures, save/load
sim/roads/road_graph.gd        RoadGraph        nodes, edges, components, incremental rebuild
sim/roads/route_planner.gd     RoutePlanner     A*, request queue, budgets, LRU cache
sim/roads/congestion_model.gd  CongestionModel  per-edge scalar, ToD curves, spillback
sim/roads/road_costs.gd        RoadCosts        pure static cost functions (fully unit-testable)
sim/roads/route_player.gd      RoutePlayer      advances a vehicle along a route per tick
sim/roads/traffic_snapshot.gd  TrafficSnapshot  read-only view for game/ and ui/
```
All are `RefCounted`. No `Node`, no engine singletons, clock and (unused) RNG injected — constitution §3.

**Tick entry points**

All entry points sit in **phase P08 `ROADS`** (doc 01 §2.4), `system_id = "roads"`. There is one `step(ctx)` entry; cadence is declared as data, per doc 01, not as internal timers.

| method | doc 01 cadence | work |
|---|---|---|
| `RoadNetwork.step(ctx)` | `EVERY_TICK` (fine **and** coarse) | apply batched edits → `rebuild_dirty` → refresh signal power → expire closures & speed overrides → congestion dirty-set recompute |
| `CongestionModel.full_pass(ctx)` | `EVERY_MINUTE` | recompute `c_e` for all edges |
| `RoadNetwork.on_day(ctx)` | `EVERY_DAY` | condition decay, `L_dens` refresh, auto-repair jobs to `ConstructionQueue.submit` (doc 02, G-2). **No upkeep call** — roads have no standing upkeep (RR-2), so `RoadNetwork` makes no billing call of any kind on the daily cadence |
| `RoutePlanner.step(ctx)` | `EVERY_TICK` (fine only) | drain the async path-request queue within budget |

**Coarse (offline) steps run the identical code** with `ctx.dt_minutes = 60`. Only `RoutePlanner.step` is skipped — no vehicle needs a *polyline* offline; doc 06's offline dispatch uses `route_minutes()`, which is available in both modes and is required to return the identical value (§4 guarantee 2). This satisfies constitution §4 ("offline catch-up uses the SAME system code") without a parallel implementation.

**Commands handled** (from `ui/` via the sim command API):
`road_build{tiles, class}` · `road_upgrade{tiles}` · `road_repair{tiles}` · `road_demolish{tiles}` · `set_auto_repair_policy{threshold, daily_cap}` · `query_road_preview{tiles, class}` (cost/validity preview, no state change).

**Events emitted:**
`road_built` · `road_removed` · `road_upgraded` · `road_graph_changed` · `road_closure_opened` · `road_closure_cleared` · `road_condition_critical` · `road_collapsed` · `route_ready` · `route_invalidated` · `building_access_lost` · `building_access_restored` · `congestion_updated` · `road_job_rejected`.

**The routing interface (doc 06's contract, adopted as doc 06 specified it).**

Doc 06 §2.11 requires `route_minutes(a, b, profile) -> float` to be **synchronous, authoritative for actual arrival, and mode-invariant**. Doc 10 provides exactly that. The async path API exists only to hand the *renderer* a polyline; it never determines arrival time.

```gdscript
enum RouteClass { EMERGENCY = 0, UTILITY = 1, CONSTRUCTION = 2, CIVILIAN = 3 }
enum RouteFail  { NONE, NO_ROAD_NEAR_ORIGIN, NO_ROAD_NEAR_DEST, UNREACHABLE, BUDGET_EXCEEDED }

class RouteProfile:                 # built by doc 06 from its vehicle table
    var speed_mpgm: float           # doc 06 owns this (incl. siren_mult already applied)
    var route_class: int            # RouteClass → cong_relief / node_relief / wx_resist
    var ignores_closures: bool      # true ⇒ soft blocks admitted at DESPERATE_BLOCK_MULT

# ---------- AUTHORITATIVE, SYNCHRONOUS, MODE-INVARIANT ----------
func route_minutes(a: Vector2i, b: Vector2i, prof: RouteProfile) -> float
    # Returns INF if unreachable. THIS number is the arrival time, online and offline.
    # Congestion is quantised to CONG_QUANT = 0.05 before costing, so the value is a
    # pure function of (graph_version, quantised congestion snapshot, closure_epoch, profile).

func is_reachable(a, b, prof) -> bool          # O(1) union-find pre-check
func nearest_node(pos: Vector2i) -> int        # -1 if no road within SNAP_RADIUS_TILES
func congestion_index(edge_id: int) -> float   # 0..2
func access_quality(pos: Vector2i) -> float    # 0..1, see §5.2
func signalised_intersections(district_id: int) -> Array   # [{node_id, tile, powered}]
func condition_hazard_mult(edge_id: int) -> float
func road_damage_fraction(tile: Vector2i) -> float   # 1.0 - condition; doc 03's C-16 argument (RR-2)
func road_tile_counts() -> Dictionary                # {street: int, avenue: int}; doc 03's pricing inventory

# ---------- MUTATORS other systems call ----------
func set_edge_speed_mult(edge_id: int, m: float, until_min: int) -> void
func close_edge(edge_id: int, cause: String, until_min: int) -> int   # -> closure_id
func remove_closure(closure_id: int) -> void

# ---------- ASYNC, RENDER-ONLY: the polyline ----------
class PathRequest:  var from_tile; var to_tile; var prof; var priority; var requester_id
class PathResult:   var ok; var fail_reason; var requester_id
                    var tiles: PackedVector2iArray; var edge_ids: PackedInt32Array
                    var length_m: float; var minutes: float      # == route_minutes()
                    var graph_version: int; var closure_epoch: int
func request_path(req: PathRequest) -> int     # ticket_id, resolves ≤ MAX_ROUTE_TICKS
func cancel(ticket_id: int) -> void

# events
path_ready(ticket_id: int, result: PathResult)
route_invalidated(ticket_ids: PackedInt32Array, reason: int)   # CLOSURE | GRAPH | COLLAPSE
```

**Contract guarantees to doc 06:**
1. **`route_minutes` is the arrival time.** Doc 06 sets `arrive_minute = now + turnout_min + route_minutes(...)`. The renderer stretches the real polyline to hit that minute (doc 11), never the reverse — constitution §3.
2. **Mode invariance.** Identical `(graph_version, quantised congestion, closure_epoch, profile)` ⇒ bit-identical `route_minutes` in fine and coarse steps. Quantising congestion to `0.05` (doc 06's own suggestion) is what makes the cache safe *and* removes float-drift between modes. Asserted by test 40.
3. **`INF` on unreachable** — doc 06 skips the unit and flags the incident `unreachable`. Never a large finite number, so doc 06's `min()` cannot silently pick an impossible unit.
4. **Re-quoting is explicit.** `route_minutes` is *not* re-integrated per tick behind doc 06's back. When a closure or graph change invalidates a live route, roads emits `route_invalidated`; doc 06 re-quotes and adjusts `arrive_minute` at a single, deterministic, auditable point. This is the concession that makes doc 06's offline/online equivalence guarantee hold — **it replaces the per-tick-integration model I originally drafted** (§9.1).
5. **Cost.** A cached `route_minutes` is ~5 µs (re-price the stored edge list). A cache miss is a full A* and is subject to the budget in §2.14; if the budget is exhausted, `route_minutes` still returns synchronously using the **admissible estimate × `DETOUR_FACTOR`**, marked by setting `last_call_was_estimated = true` so doc 06 can prefer a real quote next tick. It never blocks and never returns garbage.
6. **`estimate_eta_practical(a, b, prof)`** (O(1), no search) is provided for doc 12's unit picker, which needs ETAs for ~40 units inside one frame (doc 12 §9.2 asks for exactly this). Ranking with it and quoting only the top `DISPATCH_CANDIDATES = 3` is the intended dispatch pattern.

---

## 5. Cross-System Interfaces

*Doc numbers below are the canonical on-disk numbering of report 98 Ruling Zero (see the header). Nothing in this table is a legacy alias.*

### 5.1 Roads reads from

| doc | what roads needs | expected call / event |
|---|---|---|
| **01 — Time model & tick scheduler** (`sim/time/`) | the frozen `TimeContext`, cadence registration, the `WorkService` integer accumulator, and **`ctx.channels.construction_rate`** | phase `P08`, `system_id "roads"`, cadences `EVERY_TICK / EVERY_MINUTE / EVERY_DAY`; every road work unit multiplies `construction_rate` (C-29, §2.3) |
| **02 — Buildings, upgrades & construction projects** (`sim/buildings/`, `sim/construction/`) | footprints, access tiles, `population + jobs` per building; **and the project queue every road job runs through** | `buildings.footprint_tiles(id)`, `buildings.access_tile(id)`, `buildings.pop_plus_jobs(id)`; event `building_changed`; **`ConstructionQueue.submit / reorder / cancel / list` and `job_started / job_completed / job_cancelled / job_blocked`** (G-2, §2.13) |
| **03 — Economy, taxes, land market & difficulty** (`sim/economy/`) | **every road price** — build, upgrade, repair, demolish refund — from `data/economy.json → roads`; doc 03 is the sole currency authority (C-07, extended to roads by RR-2) | `ConstructionQueue.submit` charges through `Treasury.spend()`; `economy.road_build_cost(class, n_tiles)`; **`economy.repair_cost(asset, damage_fraction)`** (C-16). **No `bill_upkeep` call** — the former `economy.bill_upkeep("roads", per_game_hour)` is deleted with the upkeep model (RR-2) |
| **04 — Electrical grid** (`sim/power/`) | is an intersection's tile energised | `power.is_tile_powered(tile) -> bool`; read at P08 from **this step's** P06 output (doc 01 ordering makes an event unnecessary; the event is a fallback). Doc 04 supplies the power state and **nothing else** — the outage penalty itself is doc 10's (G-6) |
| **05 — Water system** (`sim/water/`) | main break flooding a tile | event `water_main_flood{tiles, depth_m}` → `flood_shallow` / `flood_deep` closure |
| **06 — Incidents, dispatch & emergency fleets** (`sim/incidents/`, `sim/dispatch/`, `sim/fleet/`) | closures and speed overrides raised by incident tiers; crew units and `crew_rate` | doc 06 calls `close_edge`, `set_edge_speed_mult`; `incident_resolved` → `remove_closure(linked)`; crews are doc 06 entities assigned to doc 02's queue (G-2) |
| **07 — Weather & Disaster Director** (`sim/weather/`, `sim/director/`) | the **global** weather state, per-tile flood depth, debris placement | `weather.current_state() -> String` (city-wide global per C-59 — see §9.2 X-4, closed), `weather.flood_depth(tile) -> float`; events `weather_changed`, `flood_depth_changed`, `debris_placed{tiles}` |
| **08 — Persistence, offline policy & notifications** (`sim/persistence/`, `sim/offline/`) | save/load, coarse step driving | `save_section()` / `load_section(dict)` for the `roads` section (report 98 §11 registry), coarse `step(ctx)` with `dt = 60 gm` |
| **09 — Map, land, districts, population & stability** (`sim/world/`, `sim/population/`) | ownership + development state, buildability, district id, `profile_weights`, **and the road template** | `land.is_developed(tile)`, `land.is_buildable(tile)`, `land.district_of(tile)`, `land.district_profile_weights(id) -> {res,com,ind,civ}`; the 87-tile block template of doc 09 §2.9.1, stamped at its `ROAD_INSTALL` phase (C-60, §2.3) |

### 5.2 Roads provides to

| doc | what roads gives | call |
|---|---|---|
| **02 — Buildings, upgrades & construction projects** | access validity, the `E_AVENUE` lookup, and the placement multiplier doc 02 §2.10 uses | `has_road_access(building_id) -> bool`; `road_access_mult(tile) -> float` (**1.00** if a road tile is within 1 tile, **0.85** within 2, **0.00** beyond — doc 02's constants, sourced from here via `access_quality`'s `w_dist` bands, C-61); **`has_class_within(tile, AVENUE, 4) -> bool`** answering doc 02's upgrade check **#13 `E_AVENUE`** (C-62); `access_quality(pos)`; road-graph `component_id`; events `building_access_lost/restored` |
| **03 — Economy, taxes, land market & difficulty** | the tile-level road-access term doc 03 §2.2 uses as `a_b` in `f_road`, plus the **physical inputs doc 03 needs to price roads** (RR-2) | **`access_quality(pos) -> float`** (see below); **`road_damage_fraction(tile) -> float` = `1 − condition`** (the C-16 argument); `road_tile_counts() -> {street, avenue}` and the published decay rates, from which doc 03 derives its routine road-repair expectation line (`0.28548` tile-fractions/gh on the 783-tile core, §2.3). The former `upkeep_per_game_day() -> int` is **deleted** — there is no standing road upkeep (RR-2). Doc 03's own `road_access_factor` is deleted (C-61); doc 09's block-level `block_road_access_score` is a *different* quantity feeding land price and must not be confused with this one |
| **06 — Incidents, dispatch & emergency fleets** | the routing API of §4, exactly as doc 06 §5 requested | `route_minutes`, `congestion_index`, **`access_quality`** (doc 06's `< 0.6` degraded-response penalty), `set_edge_speed_mult`, `close_edge`, `nearest_node`, `signalised_intersections` (for `dark_frac`), plus **`condition_hazard_mult`** (which doc 06 now multiplies into `traffic_accident` per C-48), `estimate_eta_practical`, `is_reachable`, `dispatch_candidates`, `request_path` |

> #### Measured 2026-08-20 — the seam is complete; doc 06 is not yet a live consumer (Wave 8)
>
> This row described an interface, not a wiring. `sim/roads/road_travel_time_provider.gd` — the object doc 06 holds so it never has to know `RoadNetwork` exists — shipped in Wave 7 with **only `travel_gs` and `route_tiles` overridden**, and `CitySim` never constructed it at all: the incident system was built with doc 06's own Chebyshev stand-in. **Wave 8 completed the object and held the construction**: every row below is implemented and tested, and doc 06 §2.10's Wave-8 note carries the measurement that keeps `CitySim` on the stand-in for now (a rotting city's incidents stop clearing `MAX_ACCEPTABLE_COST`, doc 06 has no terminal rule for one nobody can answer, and the backlog is unbounded). What is genuinely implemented across the seam:
>
> | doc 10 publishes | how doc 06 reads it | notes |
> |---|---|---|
> | `route_minutes(a, b, prof)` | `travel_gs = route_minutes × 60`, whole game-seconds; `−1` becomes doc 06's `UNREACHABLE_GS` sentinel at the seam | authoritative for arrival, mode-invariant, one planner cache entry shared with the polyline |
> | `route_tiles(a, b, prof)` | the vehicle's street polyline (doc 06 §2.11) | same cache entry as the price, so shape and duration can never describe two different trips |
> | `access_quality(pos)` | §2.4's `access_factor` knee at 0.60 | tile-level, **unrescaled** (C-61) |
> | `congestion_index(edge)` | doc 06's `traffic_accident` `esc_env` and `exposure` fallback | asked about a TILE; `RoadNetwork.congestion_index_at(pos)` makes the tile→edge join (snap, then `edge_at`), so all three per-position answers describe the same piece of street |
> | `condition_hazard_mult(edge)` | folded into `traffic_accident` weighting (C-48) | likewise via `condition_hazard_mult_at(pos)` |
> | `estimate_eta_practical(a, b, prof)` | the O(1) **ranking** cost in §2.10's assignment loop | never an arrival time |
> | `is_reachable(a, b, prof)` | the O(1) screen that drops candidates in another component before a search is paid for | conservative — it can admit a route the quote then refuses, never hide one |
> | `routing.dispatch_candidates` (= 3) | how many candidates doc 06 may full-route after ranking | published through the seam as `dispatch_candidates()`; **0** from doc 06's stand-in, meaning "quote everyone", so a provider with no street network ranks exactly as it always did |
>
> **§2.14's budget was not decorative and this is the measurement that proves it.** On doc 09 §2.13's benchmark city — 3,132 road tiles, a 70-unit fleet — a cache miss is **≈ 5 ms**, and the route cache cannot absorb dispatch traffic because half the key is a responding unit's tile, which changes every tile it drives. **Raising `route_cache_size` 256 → 4096 changed the hit and miss counts by nothing at all** (measured, same run, same seed): the misses are new pairs, not evictions, and no cache can help. Quoting every capable unit cost doc 06's incident phase **211 ms per coarse game-hour** against doc 01's 166 ms whole-step budget; rank-then-quote takes it to **55 ms** at **197 planner misses per 24 coarse hours instead of 589**. The number `DISPATCH_CANDIDATES = 3` has been in §2.14's tunable table since this document was written; Wave 8 is the first wave anything spent it.
>
> **And §2.14's other warning is now a blocker, not a note.** `tests/test_roads_routing.gd` reports *"median P0 expansions 1154 vs trigger 800 → hierarchical routing REQUIRED"* on a 2,134-edge graph, and the same six cross-city routes cost **110.02 ms at `epsilon_critical = 1.0`** against **16.88 ms at `epsilon_routine = 1.25`**. Emergency profiles route at `epsilon = 1.0` by design — an admissible, unweighted A\*, which is the right answer for a fire engine and the wrong cost for a loop that runs on every integrator sub-step. **Hierarchical routing is the thing that unblocks doc 06 §2.10's wiring**, and it is doc 10's to build.
>
> #### DOC 06 IS NOW A LIVE CONSUMER (Wave 9, 2026-08-20 — report 98 RR-26/RR-27)
>
> `CitySim._boot_incidents` constructs `RoadTravelTimeProvider`; `tests/test_incidents_routes.gd::test_the_router_is_what_the_shipped_sim_holds` pins it, so a regression to the Chebyshev stand-in fails loudly. Two corrections ride with the wiring:
>
> * **The paragraph above was right about the seam and wrong about the fix.** Hierarchical routing was built, measured and not shipped: with rank-then-quote the shipped seam call measures **0.709 ms mean / 1.360 ms p90** on the benchmark city at `epsilon_critical = 1.0`, and a landmark overlay made it 9 % *slower*. §2.14's Wave-9 note carries the arms. What actually unblocked doc 06 was **the second bullet below** — a defect at this seam, not the router's price and not the missing terminal rule (doc 92 §23.3's four-arm ablation).
> * **The profile crosses the seam now, and this is what closed RR-22's cliff.** `RoadTravelTimeProvider` used to ignore the `RouteProfile` dictionary doc 06 hands it and price every trip on one fixed `emergency(32.0)` object — no per-type speed and **no siren multiplier**, so a *responding* patrol car was quoted at 32 m/gm where doc 06 §2.11 says `32 × 1.25 = 40`, 20 % slow, on the department that answers most of doc 06's ambient load. `greedy_growth` seed 4242 goes from **> 600 s to 11.2 s** on that change alone. It now builds one `RouteProfile` per distinct speed — siren multiplier folded in by doc 06, as §2.11 there specifies — and caches them, because `RoutePlanner._prep` keys its per-query constant cache on profile identity and a fresh object per call would invalidate it on every quote. The route CLASS stays doc 10's.


| **07 — Weather & Disaster Director** | which districts are cut off, for evacuation and Director scoring | `components_summary() -> [{component_id, tile_count, has_station: bool}]` |
| **11 — Rendering & performance** | polylines and per-edge visual state; civilian traffic density | `TrafficSnapshot.visible_edges`, `path_ready` polylines, `overlay_mode` colour bands (4 states, matching doc 11's 2-bit packing) |
| **12 — UI/UX, camera input & onboarding** | traffic overlay, build preview, closure list, cheap unit-picker ETAs | `TrafficSnapshot`, `query_road_preview`, `estimate_eta_practical` |

**`access_quality(pos) -> float ∈ [0,1]` — CONFIRMED as the single tile-level definition (report 98 C-61).** Road access was defined four times across the project: doc 02's `road_access_mult`/`E_ROAD`, doc 03's `road_access_factor` (`a_b`), doc 06's `access_quality < 0.6` penalty, and doc 09's per-block `road_access_score`. The ruling: **this function is the one tile-level definition**, and docs 02, 03 and 06 all consume it rather than defining their own. Doc 02's 1.00/0.85 constants are *sourced from* the `w_dist` bands below. Doc 09's per-block score is a different quantity — a block-level development attribute feeding land price — and is renamed `block_road_access_score` so the two can never be conflated. One definition, three consumers:
```
access_quality(pos) = w_dist * w_class * w_state
  w_dist  = 1.00 (road within 1 tile) | 0.85 (2 tiles) | 0.60 (3–6 tiles) | 0.00 (none within 6)
  w_class = 1.00 if an AVENUE is within 4 tiles, else 0.90
  w_state = 1.00 normal | 0.55 if the nearest road tile is soft-closed
          | 0.20 if hard-blocked or COLLAPSED
          | 0.00 if the tile's component contains no station of any department
```
So an ordinary house on a street reads `0.90`; the same house when its street floods reads `0.495` — below doc 06's `0.6` threshold, which is exactly when "utility crews cannot reach the damaged equipment" (spec §4) should bite.

**Crew specialisation — ownership settled (report 98 G-2).** Generic construction crews execute road jobs at **`crew_rate 0.70`**; a dedicated **`road_crew`**, unlocked at city level 3 (doc 09 owns `city_level` per G-1), runs at **1.00**. The former "no numbered doc owns construction crews" gap is closed by the three-way split: **doc 06** owns crews as dispatchable units (roster, station capacity, preemption at priority 400, `auto_dispatch_construction = false`), **doc 02** owns the project record, the integer work-unit accumulator and the published `ConstructionQueue` API, and **doc 09** owns the land-development phase→crew-type mapping. Doc 10 authors neither the roster nor the queue: it submits jobs (§2.13) and reads `crew_rate`.

---

## 6. MVP Cut

**In the vertical slice**

- STREET and AVENUE, one tile wide, 4-connected.
- Full graph build + incremental rebuild + edge-id stability + union-find components.
- A* with all six cost factors (`cong`, `weather`, `condition`, `closure`, `override`, node delay) and all four route classes.
- **Powered vs dark signalised intersections.** This is the signature cascade and is non-negotiable for MVP — without it the thunderstorm disaster does not connect power to response time.
- Congestion scalar: time-of-day curves + density + closures + spillback + weather. Event spikes present in code but only wired to the stadium hook, off by default.
- Closure causes: `accident_minor`, `accident_major`, `flood_shallow`, `flood_deep`, `construction_new`, `construction_work`.
- Condition on **`[0,1]`** (RR-3), daily decay, damage events (which double as C-16 damage fractions), tiers, collapse, repair jobs, auto-repair policy — with **every price supplied by doc 03** from `data/economy.json` and **no standing road upkeep** (RR-2).
- Build / upgrade / repair / demolish submitted to **doc 02's `ConstructionQueue`** (G-2) as `WORK_UNITS_PER_CREW_HOUR = 100` work units that multiply `ctx.channels.construction_rate` (C-29), with validation and preview.
- `access_quality()` — the single tile-level definition consumed by docs 02, 03 and 06 (C-61).
- `has_class_within(tile, AVENUE, 4)` — the lookup behind doc 02's `E_AVENUE` upgrade check #13 (C-62).
- The doc-10-owned dark-signal penalty: `DARK_SIGNAL_DELAY 0.45 gm` and `DARK_SIGNAL_ADD 0.19` (G-6).
- `route_minutes` (synchronous, authoritative, mode-invariant, congestion quantised to 0.05), the O(1) estimators, the async `request_path` polyline API, route cache, budgets, resumable A*.
- Cosmetic civilian traffic with global caps and night headlights.
- Traffic overlay data, and doc 09's 87-tile block road template classed AVENUE (boundary arterials) / STREET (interior collector) per C-60.
- Save section (`section_version`, C-25) with RLE tile blocks + closures; cold congestion recompute on load.

**Deferred**

| deferred | earliest phase | note |
|---|---|---|
| Hierarchical routing | Phase 3 | trigger conditions specified in §2.14 |
| One-ways, turn restrictions, lane counts | post-launch | would require a directed graph |
| Multi-tile arterials / highways | Phase 3 | needs a wider-footprint editor |
| Bridges, tunnels, overpasses | Phase 3 | needs terrain + elevation from doc 09 |
| `debris` and `police_cordon` closures | Phase 2 | arrive with the disaster and riot systems |
| Evacuation flow (`E_evt` = 3.5 mode) | Phase 3 | needs doc 07 evacuation orders |
| Per-district signal timing policy | post-launch | a mayor-policy feature, not core |
| Pedestrians, transit, parking | out of scope | spec §52 non-goals |
| Congestion pricing / tolls | post-launch | |

---

## 7. Test Plan

Headless, `tests/sim/roads/`, run by `godot --headless --path . -s res://tests/run_tests.gd`. Every case constructs a `RoadNetwork` with an injected fake clock and stub providers for land/power/weather.

**Graph construction**
1. `test_plus_shape_topology` — the §2.4 worked example yields exactly 5 nodes, 4 edges, each `length_m == 16.0`, and `tile_to_edge` covers all 9 tiles.
2. `test_corner_is_not_a_node` — an L-shaped 5-tile road yields 2 nodes and 1 edge with 5 polyline tiles.
3. `test_class_transition_creates_node` — a straight 6-tile run, 3 street then 3 avenue, yields 3 nodes and 2 edges.
4. `test_pure_loop_gets_promoted_node` — an 8-tile ring yields exactly 1 node and 1 self-edge.
5. `test_isolated_tile` — a single road tile yields 1 node, 0 edges, its own component.

**Incremental rebuild**
6. `test_remove_hub_splits_components` — §2.5 example B-2: 4 edges, 8 nodes, 4 components, exactly 8 tiles retraced (assert the instrumented counter).
7. `test_edge_id_stable_on_unrelated_edit` — edit a road 30 tiles away; assert the edge ids on the original corridor are unchanged and no `route_invalidated` is emitted.
8. `test_incremental_matches_full_rebuild` — property test: apply 200 seeded random edits to a 48×48 map, comparing the incremental graph against a from-scratch rebuild after every edit (node set, edge tile-sets, component partition must match exactly).
9. `test_rebuild_budget_respected` — one edit dirtying 5,000 tiles retraces ≤ 2048 tiles in tick N and completes by tick N+3, with the graph queryable and consistent every tick in between.

**Costs**
10. `test_worked_example_C` — reproduce the §2.6 numbers to 1e-4: fire engine 39.105 gm, clear baseline 24.219 gm, civilian 79.92 gm. Edge conditions are supplied on the RR-3 scale (`0.92 / 0.61 / 0.88`) and the clear baseline uses `condition = 1.0`; the totals are unchanged by the rescale.
11. `test_emergency_privileges_monotone` — at equal `speed_mpgm`, for every closure cause and every `c ∈ {0, 0.5, 1.0, 1.5, 2.0}`, `cost(EMERGENCY) < cost(UTILITY) ≤ cost(CIVILIAN)`.
12. `test_dark_signal_penalty` — a 10-signal route costs `+11.1 gm` for a civilian at `c = 1.0` when power is cut, and reverts exactly on restore. Power is read from the **same step's** P06 output (assert no one-step lag).
13. `test_heuristic_admissible` — over 500 seeded random node pairs on a 64×64 map with random congestion/weather/condition, assert `h(n) ≤ true_cost(n, goal)` for every node on every optimal path.

**Routing**
14. `test_astar_optimal_vs_dijkstra` — for 100 seeded pairs with `ε = 1.0`, A* cost equals a reference Dijkstra cost to 1e-6.
15. `test_epsilon_bounded_suboptimality` — with `ε = 1.25`, `cost_astar ≤ 1.25 × cost_optimal` for all 100 pairs.
16. `test_deterministic_paths` — the same request run 50 times returns byte-identical `edge_ids`; and after save→load→rebuild, still identical.
17. `test_snapping_same_edge` — start and goal on the same edge returns the direct sub-segment without any node expansion (assert expansion counter == 0).
18. `test_unreachable_fast_reject` — two disconnected components reject in O(1) with `UNREACHABLE` and zero expansions.
19. `test_hard_block_never_traversed` — `flood_deep` on the only path yields `INF` from `route_minutes` even with `ignores_closures = true` (never a large finite number, so doc 06's `min()` cannot pick it).
20. `test_soft_block_second_chance` — `accident_major` on the only path yields `INF` for CIVILIAN, and a finite ×12-priced quote with `ignores_closures = true`.

**Budget & cache**
21. `test_route_budget_caps` — 40 simultaneous requests start at most `6 + 3` per tick, total expansions ≤ 1500/tick, and all resolve or fail within 6 ticks each.
22. `test_priority_aging` — a P3 request submitted behind a continuous P0 stream still resolves within 40 ticks.
23. `test_cache_hit_reprices_on_congestion` — after a congestion change of ≥ one `CONG_QUANT` step, a second identical query returns the *same* `edge_ids` with a *different* `route_minutes` and zero expansions; a change smaller than one quant step returns an identical value (proves the quantisation contract).
24. `test_cache_invalidated_by_closure` — adding a closure on a cached route's edge drops the entry and emits `route_invalidated` for live holders.
25. `test_perf_budget_reference_map` — on a generated 320×320 map with 12,000 road tiles: full graph build < 30 ms; 6 cross-city emergency routes complete within one tick's 1500-expansion budget; total routing work per tick < 4 ms. **Fails the build if exceeded** (this is the trigger for the hierarchical-routing work).

**Congestion**
26. `test_tod_curve_interpolation` — the §2.10 example D table reproduces to 1e-3 at 02:00 (0.062), 13:00 (0.631), 17:40 (0.941 / 1.321 / 1.881). Hour-of-day comes from an injected `TimeContext`, never from a clock read.
27. `test_smoothing_ramp` — from `c = 0.90` toward 1.881, values match `1.244 / 1.467 / 1.612 / 1.807` at 1/2/3/6 game-minutes.
28. `test_spillback_depth` — a closure raises `I_inc` on its own edge, `0.5×` at 1 hop, `0.25×` at 2 hops, `0` at 3 hops.
29. `test_congestion_no_feedback` — running 500 congestion ticks with a frozen clock converges and never oscillates (`|Δc| < 1e-4` after 30 ticks).
30. `test_avenue_beats_street` — same corridor, density and hour: avenue `c = 0.876` vs street `c = 1.368`, and the resulting emergency `cost` ratio is ≥ 1.85× (§2.10).

**Closures, condition, jobs**
31. `test_closure_auto_expiry_cap` — a closure whose `incident_resolved` never arrives clears at its hard cap.
32. `test_closure_dominance_and_restore` — a `flood_deep` over an `accident_minor` replaces it; clearing the flood reinstates the accident.
33. `test_condition_decay_math` — street at `c_day = 0.80` on a snow day loses exactly **0.02592** (RR-3; was 2.59 points); every condition read back is in `[0,1]`; the sub-quantum (< 0.01) fractional remainder survives a save/load round trip.
34. `test_collapse_blocks_all_classes` — condition hits **0.0** → `road_collapsed` emitted, all four classes report `UNREACHABLE` across it.
35. `test_repair_job_work_and_result` — 12 tiles at condition **0.40** → `damage_fraction 0.60`, `2.52` crew-hours = **`252` work units** (`round(2.52 × WORK_UNITS_PER_CREW_HOUR 100)`, doc 02's unit per G-2); on completion condition == **1.0** and the `construction_work` closure is gone. **Asserts `sim/roads/` produces no dollar figure**: the job's cost comes from exactly one `economy.repair_cost(asset, 0.60)` call (RR-2). *(Renamed from `test_repair_job_cost_and_result`; recomputed from the deleted `9,072,000` milli-unit and `$4,320` expectations.)*
36. `test_under_construction_blocks_civilians` — a `construction_new` tile is CIVILIAN-blocked but CONSTRUCTION-traversable at ×1.0.
37. `test_demolish_rejected_when_orphaning` — removing a building's only access road is rejected with a reason code and mutates nothing.
38. `test_auto_repair_respects_cap` — with `threshold = 0.40` (RR-3) and `daily_cap = $25,000`, at most 3 jobs are queued and the total of doc 03's returned quotes ≤ cap (RR-2: roads reads the quotes, it does not compute them).

**Save / offline**
39. `test_save_load_roundtrip` — a 12,000-tile map round-trips: identical tile grid, identical rebuilt graph (node/edge tile-sets), identical closure set; save size asserted < 400 KB.
40. `test_offline_advance_matches_online` — **the doc 06 mode-invariance gate.** Advance 7 game-days in coarse 1-hour steps and, separately, in fine ticks, with the same weather and closure script. Assert (a) condition values agree to 1e-6, (b) `route_minutes(a,b,prof)` sampled hourly for 20 fixed pairs is **bit-identical** between modes, (c) `c_e` after any coarse step equals `c_raw` for that step. If (b) fails, doc 06's offline dispatch is unsound and must be told before it ships.

**Report 98 conformance (new cases 41–46)**

41. `test_block_template_matches_doc09` (C-60) — stamping the block template yields exactly **87** road tiles: **60** `AVENUE` on local rows/cols `{0,15}` and **27** `STREET` on local row/col `7`, with the 4 shared cells classed `AVENUE`; nine blocks stamped adjacently yield **783** tiles and **169** buildable tiles on a clean block. Asserts no `{0,8}` line index appears anywhere in `data/roads.json`.
42. `test_block_template_work_and_decay` (C-60, amended by RR-2) — the stamped template costs **97.5 crew-hours** (`60×1.40 + 27×0.50` = `9,750` work units) and accrues **0.6030** tile-fractions of condition per game-day at `c_day = 0` clear (`60×0.0060 + 27×0.0090`); the 9-block core accrues **0.28548** tile-fractions per game-hour at `c_day = 0.35` (`(540×0.0060 + 243×0.0090) × 1.2625 / 24`). Also asserts the template stamp is billed **once**, by doc 03's `road_install` phase — a stamped block must produce **zero** `Treasury.spend()` calls from `sim/roads/` (no double-billing). *(Renamed from `test_block_template_cost_and_work`; the `$360,600` and `$419.40/gd` expectations are deleted with the price table under RR-2.)*
43. `test_construction_rate_channel_applied` (C-29) — a 97.5 crew-hour road job run with `construction_rate` pinned to 1.0 completes in exactly `0.804×` the wall time of the same job at the channel's 0.804 mean; a `road_crew` at the mean takes **121.3 gh ±0.1**, a generic crew (`crew_rate 0.70`) **173.2 gh ±0.1**. A road job that does *not* read the channel fails the test.
44. `test_road_jobs_go_through_construction_queue` (G-2) — `road_build`, `road_upgrade`, `road_repair`, `road_demolish` and an auto-repair run each produce exactly one `ConstructionQueue.submit`; `sim/roads/` owns no queue, no crew roster and no work accumulator of its own. A `job_blocked` reply surfaces as `road_job_rejected`.
45. `test_e_avenue_lookup` (C-62) — `has_class_within(tile, AVENUE, 4)` is true at Chebyshev 4 and false at 5, and `sim/roads/` never evaluates the L4/L5 gate itself (doc 02 check #13 owns it).
46. `test_section_version_key` (C-25) — `save_section()` emits `section_version` and **no** `schema_version`; a legacy save carrying `schema_version` loads through the migration shim.

**Report 98 Round 2 conformance (new cases 47–48)**

47. `test_roads_json_holds_no_prices` (RR-2) — parse `data/roads.json` and assert the keys `build_cost`, `upgrade_from_street_cost`, `upkeep_per_game_day`, `repair_cost_base`, `demolish_refund_pct`, `block_template_replacement_cost` and `block_template_upkeep_per_game_day` are **absent at every depth**, and that `sim/roads/` contains no currency literal. This is the doc-10 half of doc 03's test 33 (`build_cost` in no file but `data/economy.json`), which now passes as written. Also asserts `RoadNetwork.on_day()` makes **zero** upkeep/billing calls over a 30-game-day run — roads have no standing upkeep.
48. `test_road_condition_is_unit_interval` (RR-3) — over a 30-game-day randomised run (decay, damage events, repairs, collapses, save/load), every tile `condition`, every edge mean and every threshold read is within `[0.0, 1.0]`; `F_cond(0.75) == 1.0375`, `F_cond(0.25) == 1.3375`, `condition_hazard_mult` at `0.10 / 0.55 / ≥0.75` is `1.26 / 1.08 / 1.00`; `job_completed` sets exactly `1.0`; and `data/roads.json` contains no condition constant `> 1.0` in the `condition`, `classes.*.condition_base_decay` or `hazard` blocks.

---

## 8. Tunables — `data/roads.json`

```json
{
  "version": 1,

  "_pricing_owner_note": "report 98 RR-2 (extending C-07): ALL road prices live in data/economy.json -> roads, owned by doc 03. Deleted from this file: classes.*.build_cost, classes.*.upkeep_per_game_day, classes.*.demolish_refund_pct, avenue.upgrade_from_street_cost, condition.repair_cost_base, build.block_template_replacement_cost, build.block_template_upkeep_per_game_day. Roads carry NO standing upkeep in MVP: road cost = build + decay + repair, and repair is priced by doc 03's C-16 formula capital_value x damage_fraction x 0.85 x M_repair. This file keeps only physical constants: crew-hours, condition, decay, damage fractions.",
  "_condition_scale_note": "report 98 RR-3 (extending C-14): condition is on [0,1] everywhere in this file. The former [0,100] point scale is deleted; decay rates and the hazard threshold were divided by 100 and the hazard coefficient multiplied by 100 so every output value is unchanged. UI may display round(condition * 100) as a percentage.",

  "classes": {
    "street": {
      "id": 1, "doc06_name": "local", "road_class_mult": 1.00,
      "k_base": 1.00, "s_cong": 0.80,
      "build_crew_hours": 0.50,
      "condition_base_decay": 0.0090,
      "signal_min_degree": 4
    },
    "avenue": {
      "id": 2, "doc06_name": "arterial", "road_class_mult": 1.25,
      "k_base": 0.64, "s_cong": 0.55,
      "build_crew_hours": 1.40,
      "condition_base_decay": 0.0060,
      "signal_min_degree": 3,
      "upgrade_from_street_crew_hours": 0.90
    }
  },
  "_classes_note": "alley (id 3, doc06_name 'alley', road_class_mult 0.80) is reserved, not built in MVP",
  "_classes_price_note": "per-tile build price, street->avenue upgrade price and the demolish refund fraction are doc 03's: data/economy.json -> roads.{street,avenue}.build_cost / roads.upgrade_street_to_avenue / roads.demolish_refund_pct (RR-2)",

  "route_classes": {
    "emergency":    { "id": 0, "cong_relief": 0.65, "node_relief": 0.60, "wx_resist": 0.25 },
    "utility":      { "id": 1, "cong_relief": 0.30, "node_relief": 0.20, "wx_resist": 0.10 },
    "construction": { "id": 2, "cong_relief": 0.10, "node_relief": 0.00, "wx_resist": 0.00 },
    "civilian":     { "id": 3, "cong_relief": 0.00, "node_relief": 0.00, "wx_resist": 0.00 }
  },
  "_route_classes_note": "absolute speed (speed_mpgm) is owned by doc 06, never by this file",

  "cost": {
    "tile_m": 8.0,
    "cond_penalty_max": 0.60,
    "desperate_block_mult": 12.0,
    "reverse_penalty_gm": 0.50,
    "speed_override_min": 0.10,
    "congestion_index_max": 2.0
  },

  "node_delay": {
    "_owner_note": "report 98 G-6: the traffic-signal outage penalty is OWNED by doc 10. dark_signal_delay_gm here and congestion.dark_signal_add below are the whole of it. Doc 04 publishes power state only and defines neither.",
    "stop_delay_gm": 0.04,
    "signal_delay_gm": 0.12,
    "dark_signal_delay_gm": 0.45,
    "dark_congestion_coeff": 2.0,
    "powered_congestion_coeff": 1.0
  },

  "congestion": {
    "full_pass_cadence": "EVERY_MINUTE",
    "smooth_per_game_minute": 0.35,
    "quantise_step": 0.05,
    "dens_k": 0.0022,
    "dens_min": 0.20,
    "dens_max": 1.60,
    "dens_radius_tiles": 6,
    "spillback_hop1": 0.50,
    "spillback_hop2": 0.25,
    "dark_signal_add": 0.19,
    "_dark_signal_add_note": "report 98 G-6, doc 10 owns it; pairs with node_delay.dark_signal_delay_gm",
    "max_active_closures": 128,
    "event_peak": 1.40,
    "event_radius_tiles": 40,
    "event_inbound_lead_gm": 45,
    "event_outbound_tail_gm": 45,
    "event_during_factor": 0.25,
    "evac_peak": 2.50,
    "evac_decay_gm": 180
  },

  "tod_curves": {
    "res": [0.10,0.06,0.05,0.05,0.07,0.15,0.40,0.85,0.70,0.45,0.35,0.35,0.45,0.40,0.38,0.45,0.65,0.90,0.95,0.70,0.50,0.40,0.28,0.18],
    "com": [0.08,0.05,0.04,0.04,0.05,0.10,0.25,0.55,0.80,0.85,0.85,0.90,0.95,0.90,0.85,0.85,0.90,0.95,0.85,0.65,0.50,0.40,0.28,0.15],
    "ind": [0.20,0.18,0.18,0.18,0.22,0.35,0.60,0.75,0.70,0.68,0.68,0.65,0.60,0.65,0.68,0.70,0.75,0.65,0.45,0.35,0.30,0.28,0.25,0.22],
    "civ": [0.10,0.08,0.08,0.08,0.10,0.15,0.35,0.75,0.65,0.50,0.45,0.45,0.50,0.50,0.55,0.75,0.70,0.60,0.45,0.35,0.30,0.25,0.20,0.14]
  },

  "weather": {
    "clear":        { "slowdown": 0.00, "cong_add": 0.00, "wear": 0.00 },
    "cloudy":       { "slowdown": 0.00, "cong_add": 0.00, "wear": 0.00 },
    "fog":          { "slowdown": 0.10, "cong_add": 0.16, "wear": 0.00 },
    "rain":         { "slowdown": 0.08, "cong_add": 0.08, "wear": 0.30 },
    "heavy_rain":   { "slowdown": 0.18, "cong_add": 0.19, "wear": 0.30 },
    "thunderstorm": { "slowdown": 0.22, "cong_add": 0.24, "wear": 0.30 },
    "high_wind":    { "slowdown": 0.05, "cong_add": 0.03, "wear": 0.00 },
    "snow":         { "slowdown": 0.30, "cong_add": 0.32, "wear": 0.80 },
    "blizzard":     { "slowdown": 0.55, "cong_add": 0.48, "wear": 0.80 },
    "extreme_cold": { "slowdown": 0.12, "cong_add": 0.06, "wear": 0.80 },
    "heat_wave":    { "slowdown": 0.00, "cong_add": 0.00, "wear": 0.25 }
  },

  "closures": {
    "dominance_order": ["flood_deep","accident_major","debris","flood_shallow","police_cordon","construction_new","accident_minor","construction_work"],
    "causes": {
      "accident_minor":    { "mult": [1.4, 2.2, 2.2, 3.0], "cong_add": 0.56, "hard": false, "auto_expire_gm": 90 },
      "accident_major":    { "mult": [1.8, 4.0, 3.5, -1 ], "cong_add": 0.88, "hard": false, "auto_expire_gm": 240 },
      "flood_shallow":     { "mult": [2.0, 2.5, 2.2, 3.5], "cong_add": 0.64, "hard": false, "auto_expire_gm": -1 },
      "flood_deep":        { "mult": [-1,  -1,  -1,  -1 ], "cong_add": 0.80, "hard": true,  "auto_expire_gm": -1 },
      "construction_new":  { "mult": [2.2, 2.5, 1.0, -1 ], "cong_add": 0.32, "hard": false, "auto_expire_gm": -1 },
      "construction_work": { "mult": [1.5, 1.6, 1.2, 2.0], "cong_add": 0.40, "hard": false, "auto_expire_gm": -1 },
      "debris":            { "mult": [2.5, 3.0, 1.5, -1 ], "cong_add": 0.72, "hard": false, "auto_expire_gm": -1 },
      "police_cordon":     { "mult": [1.0, 1.2, 1.2, -1 ], "cong_add": 0.48, "hard": false, "auto_expire_gm": -1 }
    },
    "_mult_index": "[emergency, utility, construction, civilian]; -1 = BLOCK",
    "flood_deep_to_shallow_depth_m": 0.35,
    "flood_shallow_clear_depth_m": 0.10
  },

  "condition": {
    "_scale": "[0,1]; 1.0 = newly finished, 0.0 = COLLAPSED (report 98 RR-3)",
    "congestion_wear_coeff": 0.75,
    "tiers": { "good": 0.75, "poor": 0.50, "failing": 0.25, "critical_event": 0.20 },
    "poor_civilian_speed_mult": 0.90,
    "damage": {
      "_note": "these deltas are also the C-16 damage_fraction per cause; doc 03 multiplies them by capital_value to price the repair (RR-2)",
      "accident_major_resolve": -0.08,  "accident_major_tiles": 3,
      "flood_deep_recede": -0.15,
      "flood_shallow_recede": -0.04,
      "adjacent_structure_fire": -0.06,
      "earthquake": -0.40, "earthquake_collapse_chance": 0.12
    },
    "_repair_price_note": "report 98 RR-2: the former repair_cost_base 600 is DELETED. Repair price = economy.repair_cost(asset, damage_fraction) where damage_fraction = 1 - condition; the formula and every dollar are doc 03's (C-16), in data/economy.json.",
    "repair_crew_hours_base": 0.35,
    "repair_min_tiles": 4,
    "auto_repair_thresholds": [0, 0.25, 0.40, 0.55],
    "auto_repair_default_threshold": 0.40,
    "auto_repair_default_daily_cap": 25000,
    "_auto_repair_cap_note": "a player budget setting evaluated against doc 03's quotes, not a price authored here",
    "auto_repair_max_jobs_per_day": 3
  },

  "build": {
    "_template_note": "report 98 C-60: the block road template is doc 09's (data/starter_city.json / doc 09 §2.9.1), NOT this file's. The deleted {0,8} 60-tile grid lived here; this file now carries only the class MAPPING and the derived totals.",
    "block_template_owner_doc": "09",
    "block_template_class_map": { "boundary_arterial": "avenue", "interior_collector": "street", "player_placed": "street" },
    "block_template_tiles_per_block": 87,
    "block_template_avenue_tiles": 60,
    "block_template_street_tiles": 27,
    "block_template_crew_hours": 97.5,
    "block_template_baseline_decay_per_game_day": 0.6030,
    "core_tiles_783": { "avenue": 540, "street": 243 },
    "core_damage_fraction_accrual_per_gh": 0.28548,
    "_core_accrual_note": "report 98 RR-2: ((540 x 0.0060) + (243 x 0.0090)) x 1.2625 / 24 at c_day 0.35 clear. Published so doc 03 can DERIVE its routine road-repair expectation line rather than assume it. Doc 10 supplies the damage-fraction throughput; doc 03 supplies capital_value and every dollar.",
    "_block_template_billing_note": "report 98 RR-2: the former block_template_replacement_cost 360600 and block_template_upkeep_per_game_day 419.40 are DELETED. The stamp is charged once by doc 03's road_install development phase; per-tile replacement value for COLLAPSED rebuild and demolish refund is priced from data/economy.json.",

    "work_units_per_crew_hour": 100,
    "_work_units_note": "report 98 G-2: unit and accumulator owned by doc 02's ConstructionQueue; the former work_required_mu = crew_hours x 3600 x 1000 milli-unit conversion is deleted",
    "construction_rate_channel": "ctx.channels.construction_rate",
    "_construction_rate_note": "report 98 C-29: MANDATORY multiplier on every road work unit; all crew-hour figures in doc 10 are authored against its 0.804 24-hour mean (0.60 night floor). Channel values are doc 01's, never authored here.",

    "snap_radius_tiles": 6,
    "access_radius_tiles": 1,
    "avenue_gate_level": 4,
    "avenue_gate_radius_tiles": 4,
    "_avenue_gate_note": "report 98 C-62: ACCEPTED as a hard gate and OWNED by doc 02 as upgrade check #13 E_AVENUE. This file holds only the radius the has_class_within() lookup uses; doc 10 does not evaluate, format or store the gate.",
    "generic_crew_speed_mult": 0.70,
    "road_crew_speed_mult": 1.00,
    "road_crew_unlock_city_level": 3
  },

  "routing": {
    "max_routes_per_tick": 6,
    "emergency_overflow": 3,
    "max_expansions_per_tick": 1500,
    "max_expansions_per_route": 600,
    "max_route_ticks": 6,
    "route_cache_size": 256,
    "dispatch_candidates": 3,
    "priority_age_ticks": 8,
    "epsilon_critical": 1.00,
    "epsilon_routine": 1.25,
    "critical_priority_max": 1,
    "detour_factor": 1.25,
    "practical_congestion_coeff": 0.45,
    "estimate_class_mult_max": 1.25,
    "cong_quant": 0.05,
    "rebuild_tile_budget": 2048,
    "component_bfs_budget": 4000,
    "perf_budget_ms_per_tick": 4.0,
    "hierarchical_trigger_road_tiles": 8000,
    "hierarchical_trigger_median_expansions": 800
  },

  "civilian_traffic": {
    "density_k": 0.9,
    "base_speed_mpgm": 34.0,
    "max_cars_per_edge": 6,
    "global_cap_performance": 40,
    "global_cap_balanced": 90,
    "global_cap_high": 160,
    "max_dist_m": 320,
    "fade_seconds": 0.40,
    "offscreen_despawn_seconds": 1.5,
    "min_spawn_separation_m": 15,
    "speed_congestion_coeff": 0.325,
    "speed_jitter_min": 0.85,
    "speed_jitter_max": 1.15,
    "headlights_on_hour": 19,
    "headlights_off_hour": 6
  },

  "hazard": {
    "_note": "doc 06 owns traffic_accident generation; roads supplies only this multiplier",
    "_scale_note": "report 98 RR-3: rescaled from (coeff 0.004, threshold 75) on [0,100] to (0.40, 0.75) on [0,1]; outputs are identical (condition 0.10 -> 1.26, 0.55 -> 1.08, >=0.75 -> 1.00)",
    "condition_coeff": 0.40,
    "condition_threshold": 0.75
  },

  "access_quality": {
    "_owner_note": "report 98 C-61: the SINGLE tile-level road-access definition. Docs 02 (road_access_mult / E_ROAD), 03 (a_b in f_road) and 06 (< 0.6 degraded response) all consume it and define none of their own. Doc 09's block_road_access_score is a different, block-level quantity.",
    "w_dist_1_tile": 1.00, "w_dist_2_tiles": 0.85, "w_dist_3_to_6_tiles": 0.60, "w_dist_none": 0.00,
    "w_class_avenue_within_4": 1.00, "w_class_street_only": 0.90,
    "w_state_normal": 1.00, "w_state_soft_closed": 0.55, "w_state_hard_blocked": 0.20,
    "w_state_no_station_in_component": 0.00
  }
}
```

---

## 9. Conflicts & Open Questions

### 9.1 Where I changed my design to match a sibling doc

These were real conflicts found by reading docs 01, 02, 03, 06 and 12 after drafting. In every case I moved, because the sibling had already calibrated other numbers against its version.

**R-1 — Vehicle speed ownership → doc 06 wins.** I originally gave each road class an absolute `v_free` (street 110, avenue 165 m/gm) and each vehicle class a `speed_mult`. Doc 06 §2.11 already owns `speed_mpgm` per vehicle type (patrol 32, engine 26, utility 24, crew 18) with `siren_mult`, and had calibrated turnout and escalation timings against it. **Doc 10 now publishes no absolute vehicle speed** — only `road_class_mult` (`local 1.00 / arterial 1.25`, matching doc 06's own table). All §2 numbers and worked examples were recomputed. Consequence to note: at doc 06's speeds an 880 m response takes ~24 gm clear and ~39 gm in a storm-plus-blackout, which is longer than the 4–14 gm band doc 06 quotes for a *starter city* — the band and the mature-city case need a joint sanity pass (open question 1).

**R-2 — Congestion scale → doc 06 wins.** I had `c ∈ [0,1]`. Doc 06 uses `congestion_index ∈ [0,2]` with `1.0 = at capacity` in `f_flow = clamp(c,0.05,2)^1.5`, `traffic_accident: c/1.5`, and `congestion_ref = 1.5`. **Adopted verbatim.** `K_base` rescaled (street 0.62→1.00, avenue 0.40→0.64), `S_cong` halved (1.60→0.80, 1.10→0.55) so the endpoint penalties are unchanged, and every additive term (`wx_cong_add`, `cong_add`, `DARK_SIGNAL_ADD`) scaled by 1.6. Also rescaled: `congestion_wear_coeff` 1.20→0.75, `CIV_DENSITY_K` 1.8→0.9, `speed_congestion_coeff` 0.65→0.325, `practical_congestion_coeff` 0.90→0.45.

**R-3 — ETA authority → doc 06 wins, and this is the biggest change.** I drafted `eta_minutes` as *advisory*, with true arrival emerging from per-tick integration against live congestion (so a vehicle really slows when a jam forms mid-trip). Doc 06 §2.11/§9 requires `route_minutes(a,b,profile)` to be **synchronous, authoritative and mode-invariant**, and states plainly that per-tick integration would break its offline/online equivalence guarantee. **I dropped the integration model.** `route_minutes` is now authoritative; congestion is quantised to `0.05` before costing (doc 06's own suggestion) so the value is a pure function of a quantised snapshot; re-quoting happens only on the discrete, auditable `route_invalidated` event. Test 40 is the gate. *Cost of this concession:* a vehicle already en route does not gradually slow as a jam builds — it re-quotes in one step when a closure lands. That is less physically satisfying and I would revisit it only if doc 06 relaxes its guarantee.

**R-4 — Traffic-accident generation → doc 06 wins.** I had written a competing `accident_hazard(e)` with its own base rate and worked example. Doc 06 §2 already owns `traffic_accident` generation end to end, including the outage cascade worked example. **I deleted my formula.** Roads now supplies only `congestion_index`, `signalised_intersections` (for doc 06's `dark_frac`) and `condition_hazard_mult` — the last being the one input doc 06 has no visibility into.

**R-5 — Tick model → doc 01 wins.** I had roads owning internal timers ("every 4 SimTicks"). Doc 01 §2.4 assigns roads **phase P08, every step**, between `WATER` (P07) and `VEHICLES` (P09), with cadence declared as data. Adopted, and it is strictly better: reading power at P08 in the same step is what removes the lag from the signature blackout→response cascade. Congestion smoothing became dt-aware (`1-(1-0.35)^dt`) so coarse offline steps land exactly where fine steps converge — required by R-3.

**R-6 — Build/repair timing → doc 01 wins; the queue → doc 02 wins.** Crew-hours are converted to **work units**, not wall-clock timers, per doc 01's rule that anything whose speed can change with weather, night or road access must be a work unit. Report 98 then settled the unit and the owner: the accumulator is doc 02's (`WORK_UNITS_PER_CREW_HOUR = 100`, G-2) and every unit multiplies `ctx.channels.construction_rate` (C-29), so my `crew_hours × 3600 × 1000` milli-unit conversion is deleted and every wall-time figure in this doc is now `crew_hours / (crew_rate × 0.804)` in clear weather.

**R-8 — Block road template → doc 09 wins (report 98 C-60).** I specified a default `{0, 8}` local-line street grid: 60 tiles, all STREET, $108,000 per block. Doc 09 had already authored a boundary-arterial + index-7-collector template giving **87 tiles per block, 783 in the core, 169 buildable tiles** and the `0.34` road-area constant that all of its price and placement math depends on. **Doc 09 owns the template; doc 10 owns the class semantics.** My template is deleted; the mapping is boundary arterials → `AVENUE`, interior collectors and player-placed roads → `STREET`, and every derived figure is re-generated against 87 tiles in §2.3.

**R-7 — `access_quality` / `road_access_mult` unified.** Doc 02 already uses `road_access_mult` (1.00 within 1 tile, 0.85 within 2) and doc 03 uses `road_access_factor` as `a_b` in land value; doc 06 uses `access_quality < 0.6` as a degraded-access penalty. §5.2 now gives **one** definition serving all three rather than three drifting ones.

### 9.2 Cross-doc conflicts — status after report 98

**X-1 — Nobody owns construction crews. → CLOSED by G-2.** Ownership is a three-way split published as one API: **doc 06** owns crews as dispatchable units (roster, station capacity, preemption at priority 400, `auto_dispatch_construction: false`); **doc 02** owns the project record and progress in `sim/construction/`, with work units on doc 01's `WorkService` and the published `ConstructionQueue.submit / reorder / cancel / list` plus `job_started / job_completed / job_cancelled / job_blocked`; **doc 09** owns the land-development phase→crew-type mapping. **Doc 10 submits road jobs to doc 02's queue** (§2.13) and runs no queue, roster or accumulator of its own. Crew rates (`construction_crew 0.70`, `road_crew 1.00`) are read from doc 06.

**X-2 — Doc 09 does not exist yet. → CLOSED.** Doc 09 exists on disk as *Map, Land, Districts, Population & Stability, Starter City* and has absorbed population, stability, progression and lifetime stats (G-1, G-4, G-5). It supplies land ownership/development state, buildability, `district_of`, `district_profile_weights{res,com,ind,civ}`, `city_level` (which gates the `road_crew` unlock) and — decisively for this doc — **the block road template**. My proposed "automatic 60-tile street grid at $108,000" is **deleted**: C-60 gives the template to doc 09 (87 tiles, boundary arterial + index-7 collector) and leaves doc 10 only the class mapping and the derived costs (§2.3).

**X-3 — Every sibling doc used a different assumed numbering. → CLOSED by Ruling Zero.** The on-disk filenames are canonical and there is no other map; every doc's §5 renumbers to it. This doc already used the on-disk filenames, so nothing in §5 moved except to state the ruling explicitly. No code or comment may reference a doc number until each doc has applied the ruling.

**X-4 — Weather: global state or per-tile? → CLOSED by C-59.** **Weather state is city-wide global.** Only the `THUNDERSTORM` storm cell is spatial, and it affects lightning targeting and flood accumulation — *not* the global effect channels. Roads therefore samples `weather.current_state()` once per step and never `state_at(tile)`; the §8 `weather` table is indexed by the global state id and is unchanged. Doc 07 additionally publishes a continuous `precip01 = clamp(precip_mm_h / 35, 0, 1)` for doc 11's renderer (C-58); **roads does not consume it** — `slowdown`, `cong_add` and `wear` stay snapped to the state row, because interpolating them would break the quantised-snapshot purity that `route_minutes`' mode-invariance guarantee depends on (§4 guarantee 2). Doc 11 §9.12 is closed by the same ruling.

**X-5 — Doc 06 must multiply in `condition_hazard_mult`. → CLOSED by C-48.** Ruled in this doc's favour: doc 06 multiplies `condition_hazard_mult(e)` into its `traffic_accident` rate. Without it road maintenance would be a pure travel-time tax and the maintenance decision would lose half its weight. **Restated on the RR-3 `[0,1]` scale: `1 + 0.40 × max(0, 0.75 − condition_e)`** (was `1 + 0.004 × max(0, 75 − condition_e)`); every output is unchanged, and doc 06's test 30 now feeds it `1.00 / 0.55 / 0.10` rather than `100 / 55 / 10`. That is the only change doc 06 owes on this row; the ruling itself is unaltered.

**X-6 — Doc 06's `RouteProfile` carries `weather_mult` and `flood_mult`. → CLOSED by C-49.** Ruled in this doc's favour: **doc 06 drops both fields**, since roads already applies weather via `wx_resist` per route class and flood via the closure table, and carrying them in the profile would double-count. A genuine per-vehicle exception (a future high-clearance flood truck) becomes a named capability, not a raw multiplier. §4's `RouteProfile` is unchanged.

**X-7 — L4/L5 avenue gate is mine to propose, doc 02's to accept. → CLOSED by C-62: ACCEPTED as a hard gate.** It is now doc 02 §2.11 upgrade check **#13 `E_AVENUE`**, with a `RequirementFormatter` string in doc 12 (whose blocker enum grows to 13). Doc 10 keeps only the `has_class_within(tile, AVENUE, 4)` lookup and the `avenue_gate_radius_tiles` constant (§2.3, §8). Because doc 09's template stamps boundary arterials → AVENUE on every block, the gate never blocks the tutorial.

**X-8 — Doc 12 asked, and this is the answer.** Doc 12 §9.2 asks whether a cheap ETA exists for ~40 units in one frame. **Yes:** `estimate_eta_practical` is O(1) with no search. Doc 12 does not need a "refining…" state for the picker, only for the three real quotes doc 06 then makes. *(Unchanged by report 98.)*

**X-9 — road pricing is off doc 03's ladder, and the starter ledger has no roads line. → CLOSED by report 98 RR-2.** The ruling went further than this doc's own recommendation: rather than rescaling doc 10's prices, **doc 03 takes the prices outright.** The three facts are resolved as follows.

1. *A street tile cost more than a house.* Both per-tile prices (`street $1,800`, `avenue $5,200`) are **deleted from this doc and from `data/roads.json`**. Doc 03 adds a `roads` block to `data/economy.json` carrying street/avenue per-tile build and upgrade prices, adopting doc 10's *magnitudes* onto its own ladder. Doc 10 no longer quotes a road price anywhere.
2. *The 17–52× template gap.* With `block_template_replacement_cost` deleted there is no competing doc-10 figure. The stamp is billed once by doc 03's `road_install` phase; per-tile replacement value for a `COLLAPSED` rebuild is priced from `data/economy.json`. What this doc still publishes for the template is its **work content (97.5 crew-hours)** and its **baseline decay (0.6030 tile-fractions/game-day)**.
3. *The missing starter-ledger roads line.* **Roads carry NO standing per-tile upkeep in MVP** — the whole `upkeep_per_game_day` model is deleted, mirroring C-08's no-double-billing principle. A road's lifetime cost is *build + decay + repair*. The `$157.28/gh` figure that would have eaten 42% of doc 03's restated `+$373/gh` net **does not exist**. In its place doc 03 books a **routine road-repair expectation line, derived** from this doc's decay rates and the C-16 repair formula over the 783 core tiles; §2.3 publishes the derivation input, `0.28548` tile-fractions per game-hour.

Consequently doc 03's test 33 (`build_cost` appears in no file but `data/economy.json`) now passes as written, and this doc adds test 47 as its mirror. Nothing in this doc is under report 98 §13 item 1 any more — see the §10 Round 2 rows.

### 9.3 Tension with the constitution

**C-1 — Apparent vehicle speed under the locked 60× clock (constitution §4). → APPROVED (report 98 C-70).** `speed_mpgm` as a game-time constant is approved; the constitution imposes no physical-speed requirement. The report also confirmed that doc 06's 4–14 gm starter-city band and this doc's 24.2 gm clear / 39.1 gm storm-plus-blackout figures for an 880 m mature-city run are **both true at different city sizes** (the starter city is 384 m across), and checked the consequence: an unattended house fire reaches tier 2 at 21.8 gm and tier 3 at 39.3 gm, so a 24 gm mature-city response arrives at tier 2 — playable. Doc 06 adds the mature-city case to its §1.1 pacing table. Worked example C's numbers stand unchanged.

**C-2 — The `traffic` RNG stream (constitution §5) is unused by roads. → ACCEPTED (report 98 C-45).** The stream is **reserved, not deleted**. Routing, congestion, decay and closures are all closed-form and stochastic-free. Cosmetic civilian traffic uses a **renderer-local** RNG in `game/`, which is legal because constitution §5 governs `sim/` only. (The same ruling moves doc 06's crime generation onto the `crime` stream, which had also been unconsumed.)

**C-3 — GDScript performance (constitution §2, "hot paths move to GDExtension ONLY after profiling").** A* on a ~2,000-node contracted graph is the likeliest first breach of a per-tick budget. Test 25 is written as a **build-failing gate at 4 ms/tick** so this is settled by profiling, not opinion. Ordered remedies if it fails: (1) lower `max_expansions_per_tick`, (2) build hierarchical routing (trigger conditions already specified), (3) move `find_path` to GDExtension.

### 9.4 Open questions for the overseer

1. ~~**Response-time band.**~~ **CLOSED by report 98 C-70.** Both bands are true at different city sizes; `speed_mpgm` as a game-time constant is approved; the 24 gm mature-city response lands at fire tier 2, which is playable. Doc 06 records the mature-city case in its §1.1 pacing table. See §9.3 C-1.
2. **Should a vehicle already en route slow as a jam builds?** R-3 traded that away for doc 06's mode-invariance. If the overseer wants live degradation, doc 06's offline/online equivalence guarantee must be relaxed first.
3. **Should avenues be two tiles wide?** One tile keeps the graph a clean 4-connected grid and the editor simple, but a one-tile "avenue" that merely renders wider may read as a cheat.
4. **Should congestion have an economic effect?** Currently it costs only time. A commercial-output penalty in gridlocked districts would tie roads to doc 03 but risks double-punishing, since traffic already slows every service. Left out deliberately.
5. **Auto-repair default: on or off?** Default is `threshold 0.40` (RR-3 scale), `cap $25,000/day`. On by default keeps the offline city healthy (spec §21.3, Risk 5) but hides road decay from new players. **Recommendation: off during onboarding, offered as a prompt after the first `road_condition_critical` event.**
6. **Should collapsed roads exist in MVP?** It is the most punishing road failure and can sever a station from a district. Kept because it makes maintenance matter, but it may need a grace mechanic (a free "temporary surface" at 30% speed) to avoid an unrecoverable single-corridor map.
7. **Confirm the 4 ms/tick routing budget and the reference device** (assumed: 2022 Snapdragon 7-series, matching minSdk 29 / Vulkan baseline) as the values test 25 gates on.
8. ~~**Who owns construction crews (X-1) and when does doc 09 land (X-2)?**~~ **CLOSED.** G-2 splits crews three ways and names doc 02's `ConstructionQueue` as the one API; doc 09 exists and owns the road template, land state, districts and `city_level`. Neither is a blocker any more.
9. ~~**Road pricing against doc 03's ladder (X-9).**~~ **CLOSED by report 98 RR-2.** All road pricing moves to `data/economy.json` (doc 03), and **roads carry no standing upkeep** — road cost is build + decay + repair, with repair priced by C-16. The `$157.28/gh` core-upkeep line is deleted rather than booked; doc 03 books a derived routine-repair line instead, from the `0.28548` tile-fractions/gh accrual this doc publishes (§2.3). See §9.2 X-9.
10. **NEW — does doc 03 want the auto-repair daily cap?** `auto_repair_default_daily_cap = $25,000` is the one dollar figure left in `data/roads.json`. It is a *player budget setting* evaluated against doc 03's quotes, not a price, so RR-2 does not name it — but it is denominated in currency and will need re-tuning whenever doc 03 re-tunes the road ladder. **Recommendation: doc 03 adopts it into `data/economy.json → roads.auto_repair_default_daily_cap` and doc 10 reads it.** Doc 10 has kept it pending that call.
11. **NEW — the road demolish-refund fraction.** RR-2 names four fields to delete and `demolish_refund_pct` (0.15) is not among them, but it is a pure multiplier on a build price this doc no longer holds. Doc 10 has moved it to doc 03 with the price it multiplies, on the reading that a refund *is* pricing. **If doc 03 would rather own only the price and let doc 10 keep the fraction, say so and it comes back** — nothing else depends on where it lives.

---

## 10. Amendments applied (report 98)

Every row of report 98 §12's worklist for doc 10, plus the Ruling Zero and §13 obligations that bind every doc. Ruling ids are the report's.

| ruling | change made in this doc |
|---|---|
| **Ruling Zero** | Header roster replaced with the canonical on-disk numbering (00–13 with code roots); §5.1 and §5.2 tables relabelled with full canonical doc titles; the former §9.2 X-3 note about five incompatible private numbering maps closed. No doc-number reference in this doc points anywhere but the on-disk filenames. |
| **C-25** | §3.2 save section: the inner key `schema_version` renamed **`section_version`** (`schema_version` now exists only on doc 08's envelope). §3.2 states the rule; new test 46 guards it; report 98 §11 registers the `roads` section to doc 10 (closing G-9). |
| **C-29** | §2.3 states the mandatory rule: every road work unit multiplies **`ctx.channels.construction_rate`** (24-hour mean **0.804**, night floor 0.60), with the full `site_mult` chain written out. §2.12's repair example and §2.3's block-template example are recomputed as wall time = `crew_hours / (crew_rate × 0.804)`. New test 43 fails any road job that does not read the channel. |
| **C-60** | This doc's `{0, 8}` / 60-tile / $108,000 block template is **deleted** (doc 09 §2.9.1 owns the template; look there). Class mapping adopted: boundary arterials → **AVENUE**, interior collectors and player-placed roads → **STREET**, **87 tiles per block**. Block figures re-derived against 60 AVENUE + 27 STREET: **97.5 crew-hours** (core 783 tiles / 877.5 ch). *(The Round-1 cost figures in this row — $360,600 replacement, $419.40/game-day upkeep, $3,245,400 and $157.28/gh for the core — are **superseded and deleted by RR-2**; only the tile counts and the work survive.)* §3.2's RLE estimate re-derived (40 → **55 runs** per array, ~180 KB → **~250 KB** for 200 blocks). §8's `build` block replaced. New tests 41–42. |
| **C-62** | The L4/L5 avenue gate is recorded as **ACCEPTED as a hard gate, owned by doc 02 as §2.11 upgrade check #13 `E_AVENUE`** (doc 12's blocker enum → 13). Doc 10 retains only `has_class_within(tile, AVENUE, 4)` and `avenue_gate_radius_tiles`; it does not evaluate, format or store the gate. §2.3, §5.2, §6, §8, new test 45. |
| **C-61** | §5.2 confirms **`access_quality(pos) ∈ [0,1]` is the single tile-level definition of road access**, consumed by docs 02, 03 and 06, which define none of their own; doc 09's block-level score is renamed `block_road_access_score` to prevent conflation. Recorded in the §8 `access_quality` block and in the owner-scope line of the header. |
| **G-2** | §2.13 names the API: road jobs are submitted to **doc 02's `ConstructionQueue.submit / reorder / cancel / list`** with `job_started / job_completed / job_cancelled / job_blocked`, at doc 02's `WORK_UNITS_PER_CREW_HOUR = 100`. §2.13 validation rule 5 corrected (it wrongly named "doc 11's queue"). The `crew_hours × 3600 × 1000` milli-unit conversion is deleted (doc 02 owns the unit). §5.1/§5.2 and §9.2 X-1 record the three-way crew split (06 units / 02 projects / 09 development mapping). New test 44. |
| **G-6** | §2.6 records that the **traffic-signal outage congestion penalty is doc 10's**, and is exactly two constants: **`DARK_SIGNAL_DELAY = 0.45 gm`** (travel-time term in `D_node`) and **`DARK_SIGNAL_ADD = 0.19`** (congestion term in `I_inc`). Doc 04 publishes power state only and defines neither. Owner notes added to both §8 blocks. |
| **C-48** | No change owed by this doc — recorded in §9.2 X-5 as ruled in doc 10's favour: doc 06 multiplies `condition_hazard_mult(e)` into its `traffic_accident` rate. |
| **C-49** | No change owed — §9.2 X-6 recorded as ruled in doc 10's favour: doc 06 drops `weather_mult` and `flood_mult` from `RouteProfile`. §4's profile is unchanged. |
| **C-59** | §9.2 **X-4 closed**: weather state is city-wide **global**; only the `THUNDERSTORM` storm cell is spatial and it does not touch the global effect channels. Roads samples `weather.current_state()` and never `state_at(tile)`; the §8 `weather` table stays indexed by global state. Roads deliberately does **not** consume doc 07's continuous `precip01`, because interpolating `slowdown` would break `route_minutes`' quantised-snapshot mode-invariance. §5.1 updated. |
| **C-63** | No change owed — camera/projection constants live in `data/render.json` (doc 11) and `data/ui.json` (doc 12); this doc authors none. |
| **C-45** | §9.3 C-2 restated as ruled: the `traffic` RNG stream is **reserved, not deleted**; cosmetic traffic's renderer-local RNG in `game/` is legal because constitution §5 governs `sim/` only. |
| **C-70** | §9.3 C-1 and §9.4 question 1 closed: `speed_mpgm` as a game-time constant is **approved**; the 4–14 gm starter band and this doc's 24.2 / 39.1 gm mature-city figures are both true at different city sizes, and a 24 gm response lands at fire tier 2. Worked example C unchanged. |
| **X-1 / X-2** | Both closed (by G-2 and by doc 09's existence, respectively) in §9.2. |
| **new — X-9** | Opened, not resolved in Round 1: doc 10's per-tile prices sat above doc 03's ladder, the C-60 template re-derivation was 17–52× doc 03's `road_install` phase price, and doc 03 §2.12's starter ledger carried no roads upkeep line against **$157.28/gh** for the 9-block core. Doc 10 did not move its prices unilaterally; doc 03 is the sole currency authority. **→ Superseded and closed by Round 2 RR-2 below.** |
| **§13 blocked list** | Recorded in Round 1: everything priced in this doc was under report 98 §13 item 1 pending X-9. **→ Superseded by RR-2: nothing in this doc is priced any more, so nothing here is blocked.** Graph, routing, congestion, closures, condition mechanics and the save section were never disputed. |

**Numbers that moved (Round 1).** `block tiles 60 → 87` · `block road cost $108,000 → $360,600` · `block road work — → 97.5 crew-hours` · `block road upkeep — → $419.40/game-day` · `core road upkeep $49.50/gh → $157.28/gh` · `repair job unit 9,072,000 milli-units → 252 work units` · `12-tile repair wall time 2.52 gh → 3.13 gh (road crew) / 4.48 gh (generic crew)` · `RLE runs per block array ~40 → 55` · `200-block save ~180 KB → ~250 KB`.

**Numbers that did not move, and why.** Worked example C (39.105 / 24.219 / 79.92 gm) and worked example D (0.062 / 0.631 / 0.941 / 1.321 / 1.881) are untouched: C-70 approved the speed abstraction, C-59 confirmed the global weather sampling those examples assume, and no cost-function constant changed. `road_class_mult`, `K_base`, `S_cong`, all four route-class relief triples, the closure cause table, the ToD curves and every routing budget are unchanged. **Round 2 did not disturb any of them either** — RR-2 removed prices and RR-3 changed a scale, and neither touches the cost function's output.

### Round 2 (report 98 §14 — post-verification rulings)

Rulings addressed to doc 10 by the adversarial verification pass (docs 96/97). Ruling ids are the report's.

| ruling | change made in this doc |
|---|---|
| **RR-2** — road pricing ownership + no standing road upkeep (verif F-4 / F-06 / S-6) | **Every price is deleted from this doc and from `data/roads.json`**, with a one-line ownership pointer at each site: `classes.street.build_cost 1800`, `classes.avenue.build_cost 5200`, `avenue.upgrade_from_street_cost 4000`, `classes.*.upkeep_per_game_day 2.20 / 6.00`, `classes.*.demolish_refund_pct 0.15`, `condition.repair_cost_base 600`, `build.block_template_replacement_cost 360600`, `build.block_template_upkeep_per_game_day 419.40`. All of it now lives in **`data/economy.json → roads`** (doc 03, sole currency authority per C-07). **Roads carry NO standing per-tile upkeep in MVP**: `RoadNetwork.on_day()` makes no billing call, the §5.1 `economy.bill_upkeep("roads", …)` call and the §5.2 `upkeep_per_game_day()` provider are deleted, and road cost is *build + decay + repair*. Repair is priced by doc 03's C-16 formula against `road_damage_fraction(tile) = 1 − condition`, which this doc publishes (§4, §5.2). **Every physical constant is kept**: crew-hours (build 0.50 / 1.40, upgrade 0.90, repair base 0.35 per tile at full damage), condition, decay rates, and the per-cause damage fractions — which are re-labelled as exactly the C-16 `damage_fraction` inputs. Header owner-scope line, §1, §2.3, §2.10, §2.12, §2.13, §4, §5.1, §5.2, §6, §8 and tests 35/42 all updated; new test 47 mirrors doc 03's test 33. **§9.2 X-9 and §9.4 question 9 are closed as ruled.** |
| **RR-2 (derived input)** | So doc 03 can book its routine road-repair line *derived, not assumed*, §2.3 publishes the accrual it derives from: the 783-tile core is `9 × 60 = 540` AVENUE + `9 × 27 = 243` STREET, and at the quiet-starter sample point (`c_day = 0.35`, clear ⇒ `× 1.2625`) it sheds `540 × 0.0060 × 1.2625 = 4.09050` + `243 × 0.0090 × 1.2625 = 2.76109` = **6.85159 tile-fractions / game-day = 0.28548 / game-hour**. Shipped as `build.core_damage_fraction_accrual_per_gh`. |
| **RR-3** — road condition joins `[0,1]` (verif R-2) | **`condition` is rescaled to `[0,1]` with no carve-out**, stated explicitly in §2.2 so the next reader of C-14 does not have to rediscover it. Field type `float 0..100 → float 0.0..1.0`; `F_cond` drops its `/100` divisor; `condition_hazard_mult` becomes `1 + 0.40 · max(0, 0.75 − condition)`; decay constants divided by 100; every damage delta divided by 100; tier boundaries, the `road_condition_critical` trigger, the auto-repair thresholds, the under-construction seed and the `job_completed` result all rescaled; worked examples C and F restated on the new scale. **Output values are unchanged everywhere** — the rescale is exact, because each constant's divisor matches its operand's. UI may display `round(condition × 100)` as a percentage; the save wire format keeps the same uint8 quantisation, now defined as `round(condition × 100)`. §2.2, §2.6, §2.11, §2.12, §2.13, §3.2, §8 and tests 10/33/34/35 updated; new test 48 guards the interval. Doc 06's test 30 consumes `1.00 / 0.55 / 0.10`. |

**Numbers that moved (Round 2).** `condition field 0..100 → 0.0..1.0` · `street base decay 0.90 pts/gd → 0.0090 /gd` · `avenue base decay 0.60 pts/gd → 0.0060 /gd` · `street quiet decay 1.14 pts/day → 0.011363 /day` · `street busy+snow decay 2.59 pts/day → 0.02592 /day` · `avenue busy decay 1.00 pts/day → 0.00996 /day` · `COND_ACC_K 0.004 → 0.40` · `COND_ACC threshold 75 → 0.75` · `damage deltas −8 / −15 / −4 / −6 / −40 → −0.08 / −0.15 / −0.04 / −0.06 / −0.40` · `tier bounds 75 / 50 / 25 / 20 → 0.75 / 0.50 / 0.25 / 0.20` · `auto-repair thresholds [0,25,40,55] → [0, 0.25, 0.40, 0.55]` · `under-construction seed 10 → 0.10` · `job_completed result 100 → 1.0` · `condition_accum example 0.42 → 0.0042` · `street build cost $1,800 → doc 03` · `avenue build cost $5,200 → doc 03` · `street→avenue upgrade $4,000/tile → doc 03` · `street upkeep $2.20/tile/gd → deleted (none)` · `avenue upkeep $6.00/tile/gd → deleted (none)` · `demolish refund 15% → doc 03` · `ROAD_REPAIR_COST_BASE $600 → doc 03 (C-16)` · `block replacement cost $360,600 → doc 03` · `block upkeep $419.40/gd → deleted (none)` · `core upkeep $157.28/gh → deleted (none)` · `12-tile repair price $4,320 → doc 03 quotes it` · `— → block baseline decay 0.6030 tile-fractions/gd` · `— → core repair accrual 0.28548 tile-fractions/gh`.

**Numbers that did not move under Round 2, and why.** `F_cond` at every tier (1.000 / 1.038 / 1.150 / 1.338 / 1.588), `condition_hazard_mult` at every sample (1.26 / 1.08 / 1.00), the ~88-game-day street decay life, worked example C's totals (39.105 / 24.219 / 79.92 gm), worked example F's work (2.52 ch = 252 work units) and its three wall times (3.13 / 4.48 / 4.20 gh), the block template's 97.5 crew-hours and 9,750 work units, and the COLLAPSED rebuild work (50 / 140 work units) are all unchanged: RR-3's rescale is exact by construction, and RR-2 removed prices without touching a single work or physics constant.

---

## 11. The player's road tools (Wave 10, 2026-08-20)

§2.13's three verbs shipped in Wave 5 and **no UI could reach one** (doc 92
§17.6). They are now the build sheet's `Roads` tab, and this section records the
UI contract they are driven under so a retune of the physics above can be
checked against the surface below.

| Card | Verb | What the bar quotes |
|---|---|---|
| `Street` | `cmd_place_road(tiles, CLASS_STREET)` | doc 03 §2.13(d)'s per-tile build price on the card face; the **fresh**-tile total once a run is drawn. |
| `Avenue` | `cmd_place_road(tiles, CLASS_AVENUE)` | same, at the avenue price. |
| `Widen` | `cmd_upgrade_road(tiles)` | `STREET_TO_AVENUE` per eligible tile. |
| `Remove` | `cmd_demolish_road(tiles)` | the **refund**, at the class each tile actually carries. |

**The run is an L, Manhattan, longest leg first** (doc 12 §2.7), ordered from the
anchor, capped at `data/ui.json.placement.max_run_tiles` = 48 by truncating the
far end so the preview is always exactly the run the commit lays. Every verdict
is the command's own `preview = true` answer, run at the ghost's revalidation
rate — the UI re-implements none of §2.13's checks and cannot disagree with them.

**The ghost dims what it is not being billed for.** §2.13 keeps build, upgrade
and demolish as three verbs and each passes silently over the tiles the other two
own; the run ghost reads `road_class_at` per tile (O(1)) and draws an untouched
tile at a third of the alpha, so a sweep across three tiles of existing street
reads as *five billed of eight crossed* before the player commits.

**What still has no door.** `RoadNetwork.cmd_road_repair(tiles)` exists on this
system and has no `CitySim.cmd_*` wrapper, so there is no player verb to surface
and none was invented; road condition is bought back by §2.12's automatic repair
policy alone. Recorded as an open question rather than a gap in the tab.
