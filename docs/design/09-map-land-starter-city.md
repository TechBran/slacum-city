# 09 — Map, Land, Districts, Population & Stability

**Owner scope:** the tile grid and world extents · the land block record · terrain / elevation / flood / environmental-risk attributes · the ownership + 6-phase development state machine · the adjacency purchase rule · districts, their aggregates, `stability` and `city_stability` · **population, occupancy, job fill, happiness, `city_level` and progression** *(report 98 G-1 / G-4)* · **lifetime stats counters** *(G-5)* · the hand-authored starter city · **the benchmark-city fixture generator** *(G-7)* · `data/world.json`, `data/progression.json`, `data/starter_city.json`, save sections `"world"`, `"districts"`, `"population"`, `"progression"`, `"stats"`.
**Code roots:** `sim/world/`, `sim/population/`. **Tools:** `tools/gen_starter_city.py`, `tools/gen_bench_city.py`.
**Not owned here:** the land price *formula* and development phase *costs* (doc 03), building stats (doc 02), utility component ratings (docs 04/05), road graph and routing (doc 10), weather/flood events (doc 07), crime (doc 06).
**Complies with:** `00-constitution.md` §6 (World Units), §4 (Time), §8 (Sim State Truths), §10 (Doc Contract), and every ruling in `98-consistency-report.md` (§10 amendments applied).

**Doc numbering — Ruling Zero.** The on-disk filenames are canonical and there is no other map: 01 time & ticks · 02 buildings, upgrades & construction · 03 economy, taxes & land market · 04 electrical grid · 05 water system · 06 incidents, dispatch & fleets · 07 weather & Disaster Director · 08 persistence, offline & notifications · **09 this doc — map, land, districts, population & stability** · 10 roads, routing & traffic · 11 rendering & performance · 12 UI/UX, camera & onboarding · 13 Android integration & export.

---

## 1. Overview & Goals

This document defines the physical world SLACUM CITY is played on, the people who live in it, and the exact hand-authored starter city that ships in `data/starter_city.json`.

Role in the core loop (constitution §12): it owns the first two verbs of *buy land → develop → build → tax → upgrade → overload → improve → survive → repair → grow*, it owns the **last** verb (*grow* — population, occupancy and city level), and it supplies the **geography that makes disasters legible** — flood risk, elevation, wind exposure, contamination — so that "cheap land carries hidden risk" (spec Pillar 2) is a number, not a mood.

Goals:

1. **Legible geography** — after 30 seconds a player can say "west is cheap and floods, east is expensive high ground, south is dirty industrial land, north is easy flat farmland."
2. **Expansion is a real project** — buying is a down payment; the block is worthless until six phases finish, each occupying a finite crew (spec §7.3, §12.1).
3. **One block = one chunk = one render/sim unit** (constitution §6). No second spatial concept.
4. **People are the scoreboard.** Population is not a decoration: it fills buildings (`occ_b`, doc 03's revenue multiplier), it staffs jobs, it sets `city_level`, and it leaves when the lights stay off. One number, owned in one place *(report 98 G-1)*.
5. **The starter city is pre-wired to teach one cascade** — the grid is radial with a single substation and no tie switch, and one of its two feeders carries the water works, the police station, downtown and the plant's own site service. The first storm teaches the whole game.
6. **All world data is authored JSON**, emitted and validated by a generator script. No procedural generation in MVP; the schema is generation-ready for post-MVP rings, and the same generator family emits the performance fixture doc 11 benchmarks against.

---

## 2. Mechanics

### 2.1 Coordinates and world extents

| Concept | Value |
|---|---|
| Tile | 8 m × 8 m (constitution §6) |
| Land block | 16 × 16 tiles = 128 m square = 256 tiles |
| World (MVP) | 7 × 7 blocks = 49 blocks = 112 × 112 tiles = 896 m across |
| Developed core | 3 × 3 blocks, block coords (2,2)…(4,4) = global tiles x,z ∈ [32,79] |
| Purchasable | 40 blocks: ring 1 = 16, ring 2 = 24 |
| City centre | global tile (56,56) = core-local (24,24), inside block `B_3_3` |

`block = (tx div 16, tz div 16)` · `core_local = global − 32` · block id `B_<bx>_<bz>`.
**Player-facing grid label:** columns `A`–`G` for `bx` 0–6, rows `1`–`7` for `bz` 0–6. `B_4_3` = **E4**. Both forms are stable ids; UI (doc 12) uses the label.

`ring(b)` = Chebyshev block distance to the nearest **owned** block, recomputed on every purchase. At t0 ring 1 = the 16 blocks touching the core, ring 2 = the 24 outer blocks.
`d(b)` = Chebyshev block distance from the **centre block** (3,3) — this is doc 03's `d`. Ring 1 ⇒ d = 2, ring 2 ⇒ d = 3.

Axes: +x east, +z south, +y up.

### 2.2 Land block schema

Authored attributes:

| Field | Type | Notes |
|---|---|---|
| `id`, `grid`, `label` | string, [int,int], string | `B_3_1`, `[3,1]`, `D2` |
| `terrain_class` | enum | **game** taxonomy: `flat` \| `hills` \| `waterfront` \| `industrial_edge` |
| `dev_terrain` | enum | **doc 03** taxonomy: `flat` `gentle` `hilly` `steep` `rocky` `forest` `marsh` `island` — the key doc 03's `T_factor` and `terrain_phase_mult` index on (§2.4) |
| `elevation_class` | int 0–4 | `elevation_m = [0, 5, 12, 22, 34][class]` |
| `flood_risk` | float 0–1 | authored base hazard |
| `env_risk` | object | `{flood, wildfire, subsidence, pollution, wind, hazmat}` each 0–1 |
| `road_access` | enum | `NONE` \| `STUB` \| `EDGE` \| `ARTERIAL` (display), plus derived `arterial_connections` 0–4 = doc 03's `n` |
| `water_tiles`, `blocked_tiles` | int | permanent water / un-buildable |
| `waterfront_edges` | int 0–4 | doc 03's `W_factor` input |
| `amenity_score` | float 0–1 | view/prestige character |
| `vegetation_density`, `slope_index` | float 0–1 | development drivers |
| `min_city_level` | int | gate for `PURCHASABLE`, on the §2.11 city-level ladder |
| `ownership_state` | enum | `LOCKED` \| `PURCHASABLE` \| `OWNED` |
| `development_state` | enum | §2.3 |
| `district_id` | string \| null | assigned on `READY` |
| `tags` | string[] | stable hooks for the tutorial and scenarios (§2.9.7) |
| `bridge_required`, `satellite`, `special_zone_id` | null in MVP | future exceptions (§2.5) |

**Derived, never stored:**

```
usable_tiles      = 256 - water_tiles - blocked_tiles
road_tiles_est    = round(0.34 * usable_tiles)          # matches the authored core grid exactly
buildable_tiles   = usable_tiles - road_tiles_est       # clean block = 169
env_risk_index    = 0.35*flood + 0.15*wildfire + 0.15*subsidence
                  + 0.20*pollution + 0.10*wind + 0.05*hazmat        # = doc 03's risk_index
block_road_access_score = {NONE 0.00, STUB 0.35, EDGE 0.70, ARTERIAL 1.00}[road_access]
land_value_index  = clamp01(0.25 + 0.30*amenity_score
                          + 0.25*(1 - env_risk_index) + 0.20*district_stability)   # 0 if undeveloped
prestige(b)       = mean land_value_index over OWNED 4-neighbours of b, 0 if none  # = doc 03's prestige
elev_m(tile)      = elevation_m of the tile's block          # blocks are flat; doc 05 §2.3 consumes this
elevation_band    = LOW (class 0-1) | MID (class 2) | HIGH (class 3-4)   # answers doc 07 open Q8
drain_rate_mm_h   = 25.0 * (1 - 0.80*flood_risk) * (1 + 0.50*elevation_class/4)
```

> **`block_road_access_score` is a block-level development attribute, not tile-level road access** *(report 98 C-61)*. It was called `road_access_score`; the name now carries the `block_` prefix so it can never be confused with **doc 10's `access_quality(pos) ∈ [0,1]`, which is the single definition of tile-level road access** for docs 02, 03 and 06. This doc consumes `access_quality` for the development site multiplier (§2.3) and publishes `block_road_access_score` for land price (§2.4) and district stability (§2.6). They are different quantities with different consumers.

`buildable_tiles` is an **estimate** below `READY` (the road template is not stamped yet, so the 0.34 constant stands in) and a **direct count from the tile grid** afterwards. The estimate feeds the price; the count gates placement. They agree exactly (169) on a clean block; `B_2_3` estimates 159 and counts 154 because Mill Pond distorts the template.

**Terrain classes** (the game-facing taxonomy; spec §7.2 made numeric):

| class | signature risks | typical `dev_terrain` |
|---|---|---|
| `flat` | wildfire 0.20 (dry grass); nothing else notable | `flat`, or `gentle` on the soft floodplain |
| `waterfront` | flood 0.72–0.90, subsidence 0.35 — plus a waterfront price premium | `gentle` (river bank) / `marsh` (tidal) |
| `hills` | wind 0.45, wildfire 0.45 (overhead line damage), landslide 0.20; flood-immune | `hilly` (bx 5) / `steep` (bx 6) |
| `industrial_edge` | pollution 0.70, hazmat 0.60; cheapest land on the board | `forest` — **proxy**, see §9 |

**Flood interface to doc 07.** Doc 07 accumulates `depth_mm` on road tiles whose block reports `elevation_band == LOW`, drained at `drain_rate_mm_h`. This doc supplies both. Worked values:

| block | flood_risk | elev class | band | drain_rate_mm_h |
|---|---|---|---|---|
| `B_0_4` A5 river bank | 0.80 | 0 | LOW | 25 × 0.36 × 1.00 = **9.0** |
| `B_1_3` B4 the Flats | 0.51 | 1 | LOW | 25 × 0.592 × 1.125 = **16.7** |
| `B_3_1` D2 farmland | 0.18 | 2 | MID | 25 × 0.856 × 1.25 = **26.8** |
| `B_6_2` G3 ridge | 0.04 | 4 | HIGH | 25 × 0.968 × 1.50 = **36.3** |

A LOW block with a 9 mm/h drain under doc 07's storm rainfall ponds within minutes; a HIGH block effectively never floods. That is the whole west-vs-east tradeoff in one number.

### 2.3 Ownership & development state machine

```
LOCKED ──(city_level ≥ min_city_level AND shares a full edge with an OWNED block)──▶ PURCHASABLE
PURCHASABLE ──buy_land, treasury ≥ price──▶ OWNED, development_state = UNDEVELOPED
UNDEVELOPED ─▶ SURVEY ─▶ CLEARING ─▶ GRADING ─▶ ROAD_INSTALL ─▶ UTILITY_CORRIDOR ─▶ FINAL_DEVELOPMENT ─▶ READY
```

- Phases run **strictly in order**, one at a time per block; any number of blocks may develop in parallel if crews exist.
- Each phase is a construction project in doc 02's §2.10 model: its duration is in **crew-hours**, and `max_crews_per_project = clamp(1 + floor(h/20), 1, 4)` — which is **1** for every phase here, so *a phase holds exactly one crew for its whole run*.
- The player may `pause_development` **between** phases (crew released, progress kept). Mid-phase pausing is rejected; mid-phase cancel forfeits the phase and refunds per doc 03.
- **Building placement requires `development_state == READY`.** No exceptions in MVP.
- Progress is stored as `phase_crew_minutes_remaining : int` (integer game-minutes of crew work) so the 1 Hz online path and the 1-game-hour offline path agree exactly.

**Phase table.** Durations and `PHASE_BASE` costs are **doc 03 §2.8's**, reproduced here for readability; the crew-type column is this doc's contribution (nothing else owns it).

| # | Phase | crew-hours | `PHASE_BASE` $ | Primary crew | Fallback (× time) | World effect on completion |
|---|---|---|---|---|---|---|
| 1 | `SURVEY` | 4 | 1,200 | `construction_crew` | any ×1.0 | true `env_risk` revealed (before this the UI shows a ±0.20 risk band, doc 03 §2.7) |
| 2 | `CLEARING` | 8 | 3,000 | `heavy_equipment_crew` | `construction_crew` ×1.4 | vegetation props removed, `vegetation_density → 0` |
| 3 | `GRADING` | 12 | 4,500 | `heavy_equipment_crew` | `construction_crew` ×1.6 | terrain flattens to `elevation_m`, `slope_index → 0` |
| 4 | `ROAD_INSTALL` | 14 | 7,500 | `road_crew` | `construction_crew` ×1.8 | road template stamped (§2.9.1); boundary AVENUEs widen 1→2 tiles where the neighbour is developed; all 4 neighbours' `road_access` rises to ≥ `STUB`; doc 10 rebuilds the road graph |
| 5 | `UTILITY_CORRIDOR` | 16 | 9,000 | `heavy_equipment_crew` | `road_crew` ×1.3, `construction_crew` ×2.0 | power feeder stub + water main stub placed at the block's interior STREET crossing; block appears in the overlays as *available, unconnected* |
| 6 | `FINAL_DEVELOPMENT` | 6 | 5,000 | `construction_crew` | any ×1.0 | `READY`; district auto-assignment runs (§2.6); buildable tiles unlocked |
| | **Total** | **60 crew-hours** | | | | |

**Wall-clock time — every work unit multiplies `ctx.channels.construction_rate`** *(report 98 C-29)*. Doc 01 §2.7's exact integer work accumulator already does this; this doc, doc 02 and doc 10 must all call it. The channel is **absolute**, not normalized: its 24-hour mean is **0.804** with a 0.60 night floor, so authored crew-hours are always *less* than wall-clock game-hours.

```
work_units_per_hour = crew_power * site_mult * ctx.channels.construction_rate
progress           += work_units_per_hour / phase_crew_hours * hours_elapsed
crew_power = crew_rate of the assigned crew  (base 1.0; fallback multiplies phase_crew_hours, not crew_rate)
site_mult  = weather_build_mult                     (doc 07 get_effect(): clear 1.0, rain 0.85,
                                                     thunderstorm 0.45→0.25, blizzard 0.40)
           * road_access_mult                       (doc 10's access_quality(pos) at the block's access tile)
```

**Worked example — `B_3_1` (D2), the tutorial block** *(recomputation R-16)*. One `construction_crew` only (Construction Yard L1), clear weather, AVENUE frontage so `road_access_mult = 1.0`. Wall time = effective crew-hours ÷ 0.804.

| Phase | crew-hours | fallback × | effective crew-hours | wall time @ crew_power 1.0 |
|---|---|---|---|---|
| SURVEY | 4 | 1.0 | 4.0 | 4.0 / 0.804 = **4.98 gh** |
| CLEARING | 8 | 1.4 | 11.2 | 11.2 / 0.804 = **13.93 gh** |
| GRADING | 12 | 1.6 | 19.2 | 19.2 / 0.804 = **23.88 gh** |
| ROAD_INSTALL | 14 | 1.8 | 25.2 | 25.2 / 0.804 = **31.34 gh** |
| UTILITY_CORRIDOR | 16 | 2.0 | 32.0 | 32.0 / 0.804 = **39.80 gh** |
| FINAL | 6 | 1.0 | 6.0 | 6.0 / 0.804 = **7.46 gh** |
| **Total** | **60** | | **97.6 crew-hours** | **121.39 game-hours** |

The old figure of 97.6 gh silently assumed the crew worked at full rate through the night. It does not: `construction_rate` floors at 0.60 between 22:00 and 05:00, and **97.6 / 0.804 = 121.39 gh** is the honest wall time.

With the specialist crews unlocked (`heavy_equipment_crew` + `road_crew`, doc 03's roster at $30,000 and $20,000) the same block is 60 crew-hours ⇒ **60 / 0.804 = 74.63 gh** — the same 39 % saving, now stated in wall time. In steady rain the one-crew case stretches to `121.39 / 0.85 = ` **142.82 gh**.

`first_block_time_mult` is **retuned 0.60 → 0.48** *(C-29)* so the tutorial block still completes across one play session plus one offline gap:

```
first-block crew-hours = 97.6 × 0.48 = 46.85
first-block wall time  = 46.85 / 0.804 = 58.27 game-hours ≈ 58.3 gh  (2,811 crew-minutes, 3,496 wall game-minutes)
```

That is the same beat the pre-amendment doc delivered at `0.60` against an un-channelled 97.6 gh, and it lands within 0.6 % of the 58.6 gh the report quotes as the target. **The constant is 0.48; the derived beat is 58.3 gh.**

### 2.4 Purchase pricing — the inputs this doc supplies

> **Doc 03 §2.7 owns the formula.** This section defines only the block attributes that feed it. Values below are computed with doc 03's formula verbatim.

| doc 03 term | supplied by this doc as |
|---|---|
| `d` | Chebyshev block distance from centre block (3,3); ring 1 ⇒ 2, ring 2 ⇒ 3 |
| `terrain` (`T_factor`) | `dev_terrain` (8-way key, §2.2) |
| `risk_index` (`R_factor`) | `env_risk_index` — **hidden until SURVEY completes**, shown as a band before that |
| `waterfront_edges` (`W_factor`) | `waterfront_edges` 0–4 |
| `n` (`A_factor`) | `arterial_connections` — count of the block's 4 edges that lie on an existing AVENUE |
| `prestige` (`P_factor`) | mean `land_value_index` of OWNED 4-neighbours (§2.2) |
| `elevation_norm` (`E_factor`) | `elevation_class / 4` |
| `blocks_owned` (`escalation`) | count of `OWNED` blocks; `STARTER_BLOCKS_FREE = 9` matches the 9-block core exactly, so escalation is 1.00 at t0 and rises 6 % per block after |

**Worked example — `B_3_1` (D2):** d = 2, `dev_terrain = flat`, risk 0.143, waterfront_edges 0, n = 2 (core boundary AVENUE west + SR-9 east), prestige 0.797 (its only owned neighbour is `B_3_2`, land-value index 0.797), elevation_class 2, blocks_owned 9, standard difficulty.

```
D = 0.55 + 0.45·e^(−0.25)     = 0.9005      W = 1 + 0.55·(0/4)      = 1.0000
T = 1.00 (flat)               = 1.0000      A = 1 + 0.09·2          = 1.1800
R = 1 − 0.45·0.143            = 0.9357      P = 1 + 0.35·0.797      = 1.2790
                                            E = 1 + 0.20·(2/4)      = 1.1000
escalation = 1.00 · M_land 1.00
price = 9,000 × 0.9005 × 1.00 × 0.9357 × 1.0000 × 1.18 × 1.2790 × 1.10  =  12,596  →  $12,600
```

This lands within 2 % of doc 03's own worked example D ($12,400) and of its pacing table's "buy block 2 ($12,400)" beat, so the two docs are consistent without patching. **No land price changed under report 98** — the price inputs are untouched; only the `min_city_level` column moved, onto the adopted city-level ladder (§2.11).

Full sheet: §2.8.2.

### 2.5 Adjacency purchase rule and future exceptions

A block is `PURCHASABLE` iff **all** hold:

1. `purchasable == true` in world data (not world-edge void).
2. `city_level >= min_city_level` (§2.11).
3. It shares a **full edge** (4-neighbour) with at least one `OWNED` block. **Diagonal contact does not qualify.**
4. No unresolved exception flag (below).

Rule 3 is checked against *ownership*, not development, so land-banking is legal but starves your crews.

At t0 the 12 orthogonal ring-1 blocks are purchasable; the 4 ring-1 diagonals (`B_1_1` B2, `B_5_1` F2, `B_1_5` B6, `B_5_5` F6) are `LOCKED` until one of their edge-neighbours is bought. The very first purchase therefore already decides which corner of the map opens next.

**Future exceptions** (schema present, all `null` in MVP):

| Flag | Effect |
|---|---|
| `bridge_required: {from_block, cost, crew, crew_hours}` | Ignores rule 3 once a bridge project from `from_block` completes. Shore blocks carry `bridge_anchor: true`. Islands. |
| `satellite: {unlock_city_level}` | Purchasable with no adjacency at doc 03's `NONADJACENT_PREMIUM = 1.6×`. `UTILITY_CORRIDOR` uses true distance, so remote land is cheap to buy and brutal to connect. |
| `special_zone_id` | Unlocked by a scenario/expansion event rather than adjacency (spec §7.1). |

### 2.6 Districts, stability and `city_stability`

A **district** is an aggregation region of **1 to 4 orthogonally contiguous land blocks** (constitution §8). It owns no tiles, no buildings and no simulation of its own.

- Every block at `READY` or beyond belongs to exactly one district; membership is 4-connected; max 4 blocks.
- **Auto-assignment on `READY`:** join the adjacent district with the fewest blocks that has `< 4` and the same `terrain_class`; else the adjacent district with the fewest blocks; else create a new district, named from `data/district_names.json` using the `misc` RNG stream.
- `rename_district` is free. `assign_block_to_district` is subject to contiguity + size cap and a **24 game-hour per-block cooldown**, so a player cannot shuffle blocks to game the stability aggregate before an inspection.

**Fields (spec §46) and who writes them:**

| Field | Written by | Cadence |
|---|---|---|
| `id`, `name`, `label`, `block_ids[]`, `color_index` | this doc | on change |
| `population`, `jobs` | this doc (§2.10 rollup over doc 02 capacities) | per game-hour |
| `tax_output` ($/gh) | doc 03 | per game-hour |
| `power_reliability` | doc 04 | 1 Hz |
| `block_dark` **per member block** | doc 04 (§2.4: a block flags `block_dark` at ≥60 % of buildings DARK, weighted by pop+jobs) | on change |
| **`district_dark`** | **this doc** — derived from doc 04's `block_dark`, below | on change |
| `water_reliability` | doc 05 §2.11 | 1 Hz |
| `fire_risk` | doc 06 | 1 Hz |
| `crime_index` | doc 06 | 1 Hz |
| `traffic_state` | doc 10 | 1 Hz |
| **`stability`** | **this doc** — docs 05 §2.11 and 06 §2.3 both name doc 09 as its owner | 1 Hz |

Entry points owned here: `District.recompute_fast()` (1 Hz, with incident evaluation) and `District.recompute_slow()` (per game-hour, with economy). Both are pure functions of member-block state except the two reliability EMAs.

```
population = Σ building.population × occ_b ;  jobs = Σ building.jobs      # capacity for jobs, filled for pop (§2.10)
tax_output = Σ building.tax_output                                        # doc 03 writes it
power_reliability = EMA(served_kw / demanded_kw,  halflife 6 game-hours)
water_reliability = EMA over game-day of clamp(P_zone / 0.6, 0, 1)          # doc 05 §2.11's definition
road_access_quality = mean over member blocks of block_road_access_score
                      {NONE 0.00, STUB 0.35, EDGE 0.70, ARTERIAL 1.00}
employment_ratio    = clamp01( jobs / max(1, population * 0.55) )

stability = clamp01( 0.30*power_reliability
                   + 0.20*water_reliability
                   + 0.20*(1 - crime_index)
                   + 0.15*road_access_quality
                   + 0.10*employment_ratio
                   + 0.05*(1 - fire_risk) )
```

`stability ∈ [0,1]` — confirming doc 06's §9 assumption and satisfying report 98 C-56. Doc 06 consumes it as `f_stab = 1 + 3.0·(1 − stability)²`; **doc 03 consumes it as `f_stability = 0.25 + 0.75·S^0.70` with `S` already on [0,1]** — there is no [0,100] stability anywhere in the project. Doc 07 writes stability deltas through `districts.apply_stability(id, d)` and never to a city scalar.

**`district_dark` — the population-weighted aggregate** *(report 98 C-38)*. Doc 04 flags `block_dark` at block granularity, which is correct because a block is the render chunk (doc 11 consumes the block-level event unchanged). A district is 1–4 blocks, so the district flag is an aggregate this doc derives:

```
district_dark_fraction = Σ_b population_b · block_dark_b  /  Σ_b population_b     over member blocks
                       = mean over member blocks of block_dark_b                  if Σ population_b == 0
district_dark          = district_dark_fraction >= DISTRICT_DARK_THRESHOLD (0.60)
```

`block_dark_b ∈ {0,1}`. The continuous `district_dark_fraction` is published alongside the boolean so doc 12 can render a partial-blackout badge and doc 11 can tint at district scale without a second event. The zero-population fallback matters at t0: `B_4_3` (E4) and `B_4_4` (E5) are pure utility blocks with no residents, so a district containing only those blocks would otherwise divide by zero.

**Worked at t0 for `D_DOWNTOWN`** (`B_3_3`+`B_4_3`; pop 24, jobs 60; utilities nominal ⇒ reliabilities 1.00; placeholder `crime_index` 0.10 and `fire_risk` 0.12 pending doc 06's real t0 values; `road_access_quality` 1.00 — every core block is AVENUE-fronted):

```
employment_ratio = clamp01(60 / (24 × 0.55 = 13.2)) = clamp01(4.545) = 1.00
stability = 0.30×1.00 + 0.20×1.00 + 0.20×0.90 + 0.15×1.00 + 0.10×1.00 + 0.05×0.88
          = 0.300 + 0.200 + 0.180 + 0.150 + 0.100 + 0.044 = **0.974**
```

Same district 3 game-hours into the designed `F_SOUTH` fault (power_reliability 0.55, water_reliability 0.70, crime 0.28, fire_risk 0.31):

```
0.30×0.55 + 0.20×0.70 + 0.20×0.72 + 0.15×1.00 + 0.10×1.00 + 0.05×0.69
= 0.165 + 0.140 + 0.144 + 0.150 + 0.100 + 0.0345 = **0.7335**
```

— a 0.2405 drop that doc 06 turns into `f_stab = 1 + 3·(1 − 0.7335)² = **1.213**`, a 21 % lift in incident rate on top of the outage itself, and that doc 03 turns into `f_stability = 0.25 + 0.75·0.7335^0.70 = 0.25 + 0.75×0.8083 = **0.856**` against 0.972 nominal — a 12 % revenue cut. That is the cascade arriving as a number, in two currencies.

Contrast `D_NORTHGATE` at t0: 100 residents but only 34 jobs ⇒ `employment_ratio = 34/55 = 0.6182` ⇒ `stability = 0.874 + 0.10×0.6182 = **0.9358**`. The starter city's north side is still the weakest district after the C-11 revert, and still for the same reason — housing without commerce. A legible first lesson that costs nothing to author.

**`city_stability` — published by this doc** *(report 98 C-56)*. Doc 07 reads and writes a city-level stability scalar that previously had no owner and no definition. It is the **population-weighted mean of district stability**, on [0,1], recomputed with `recompute_slow()`:

```
city_stability = Σ_d population_d · stability_d  /  Σ_d population_d
               = mean over districts of stability_d          if Σ population_d == 0
```

At t0: `(100×0.9358 + 24×0.9740 + 16×0.9740 + 4×0.9740) / 144 = (93.580 + 23.376 + 15.584 + 3.896) / 144 = 136.436 / 144 = **0.9475**`.

Under the `F_SOUTH` fault, with only `D_DOWNTOWN` degraded to 0.7335: `(93.580 + 17.604 + 15.584 + 3.896) / 144 = 130.664 / 144 = **0.9074**`. The city scalar moves only 0.040 for a 0.241 district collapse **because Downtown holds 17 % of the population** — which is exactly the point of weighting by people rather than by district count, and is why a blackout in Northgate would hurt the city number four times as hard.

`city_stability` is a **read-only publication**: nothing outside this doc writes it, and it feeds doc 03's happiness chain (§2.10), doc 07's Director pressure and doc 12's dashboard.

#### 2.6.1 `profile_weights` — the district's land-use mix, and doc 10's consumer (Wave 14)

Doc 10 §5.1 has always named `land.district_profile_weights(id) -> {res, com, ind, civ}` as this doc's to publish. Until Wave 14 nothing did, and doc 10's four authored time-of-day curves were four copies of one curve on every district of every city (report 98 RR-69, doc 91 A91-D-32). `DistrictRegistry.profile_weights(id)` is that publication.

**What it is.** A district's normalised share of *trip generation*, per doc 10 profile:

```
raw_p     = Σ over buildings in the district with profile p of (population + jobs)     ← doc 02 CAPACITY
weight_p  = raw_p / Σ_q raw_q                                     (the row sums to 1)
```

The weight is `population + jobs` and **not a building count**: it is the same `pj` doc 10 §2.10's `L_dens` counts, because both are trip generation, and one 60-resident high-rise is not one house. It is authored **capacity**, not this hour's `occ_b`: occupancy already swings with the hour of day, and a weight that swung with it would put doc 10's time-of-day curve inside its own weights.

**The fold from doc 02's five categories to doc 10's four curves** lives in `DistrictRegistry.CATEGORY_PROFILE` and is read off what doc 10 says each curve *means*, not off the category's name:

| doc 02 category | archetypes | doc 10 profile | why |
|---|---|---|---|
| `residential` | house, apartment, high_rise | `res` | — |
| `commercial` | store, office | `com` | — |
| `industrial` | data_center | `ind` | (its doc 03 **tax** class is `tech`; that is a different axis) |
| `utility` | power_facility, substation, water_facility | **`ind`** | utilities are industrial land use in any zoning taxonomy, and `ind` is *"flat-shifted, peaking 16:00 and never below 0.18 overnight"* — a continuously-staffed plant. Folding them into `civ` would empty a 24/7 works at 03:00 |
| `service` | police_station, fire_station, construction_yard | `civ` | doc 10: `civ` *"peaks 07:00 and 15:00 for school and shift changes"* — the emergency-service watch change |

**Cadence: a revision memo, not a day timer (doc 93 §O1).** Doc 10 §2.10 used to say "recomputed once per game-day". The mix is a pure function of the building roster and of district membership, and both carry a revision counter, so `CitySim` keys the rebuild on that pair — the same shape `district_of_building()` already had. **A block that develops mid-game therefore shifts its district's rush hour on the pass after the building lands**, not at the next midnight; that is this doc's grain (a district *aggregates*, and its aggregates are refreshed when their inputs move) and it removes a second cadence that would have had to be kept bit-identical between the fine and coarse paths for no gain.

**Derived, never persisted.** §3.2's district section does not carry it and the state hash never sees it. A restored city re-derives the identical row from the roster the save *does* carry, before its first tick — which is what keeps a loaded city on the live city's congestion. `deserialize` drops the live row rather than keeping a stale one alive.

**A district with no trips at all publishes `{}`**, and doc 10 falls back to `data/roads.json`'s authored `default_profile_weights`. That is deliberate: an empty district has no land use, and a fabricated uniform row would be a number nobody authored.

Measured on the founding city at t0:

| district | mix (`Σ pop+jobs`) | `res` | `com` | `ind` | `civ` |
|---|---|---|---|---|---|
| `D_DOWNTOWN` | 1 apartment · 1 office · 4 stores · 1 substation | 0.3095 | **0.6429** | 0.0476 | 0.0000 |
| `D_FOUNDRY` | 1 house · 1 power facility · 1 store | 0.1333 | 0.2000 | **0.6667** | 0.0000 |
| `D_MILLPOND` | 4 houses · 1 police station · 2 water facilities | 0.3333 | 0.0000 | 0.4167 | 0.2500 |
| `D_NORTHGATE` | 13 houses · 2 apartments · 1 fire station · 1 yard | **0.7761** | 0.0000 | 0.0000 | 0.2239 |

The starter city's authored character survives the arithmetic without anyone hand-tuning a weight: Downtown is commercial, the Foundry is industrial, Northgate is a dormitory. Doc 10 §2.10 carries what that does to `D_tod`.

### 2.7 Elevation, and what other docs get from it

Blocks are **flat at their `elevation_m`**; there is no intra-block terrain variation in MVP. `elev_m(tile)` therefore reduces to a block lookup — this is the answer to doc 07's open question 8 (flooding is block-granular, 128 m at a time) and to doc 05's `elev_m(tile)` requirement.

Consequence worth naming: doc 05's pressure model is `1 − 0.015·(elev_m − tank_head_m)` above the tank head. `WTR-2` sits at `elevation_m = 5` with 30 m of head ⇒ effective head 35 m, so the whole core (5–12 m) is at full pressure. **Copper Ridge at 34 m is at `1 − 0.015×(34 − 35) → 1.0` marginally, and any ridge building above the tank line will need a `booster` variant** (doc 05 §8: `booster` L1 adds 25 m of head for 8.0 m³/h at 12 kW). Expanding east is a water-engineering problem before it is a money problem, which is exactly the intent.

### 2.8 The world — 7 × 7 geography

#### 2.8.1 Regions

```
 bz\bx   0(A)    1(B)    2(C)    3(D)    4(E)    5(F)    6(G)
   0     river   flats   farm    farm*   farm*   farm    RIDGE
   1     river   flats   farm    farm*   farm*   hills   RIDGE
   2     river   flats   [ ===  C O R E  === ]   hills   RIDGE
   3     river   flats   [ ===  C O R E  === ]   hills*  RIDGE*   ← SR-14 enters east
   4     river   flats   [ ===  C O R E  === ]   hills*  RIDGE*
   5     marsh   flats   flat    IND     IND     IND     RIDGE
   6     marsh   flats   IND     IND     IND     IND     ridge
                                 ↑ SR-9 enters north      (* = AVENUE access at t0)
```

- **Slacum River** occupies the eastern 5 tile-columns of block column A. Column A is `waterfront`; `B_0_5`/`B_0_6` (A6/A7) are tidal marsh — 96 water tiles, the worst flood risk in the game, and the cheapest land on the board.
- **The Flats** (column B) sit behind a levee: `flat` terrain, elevation class 1, flood risk 0.42 → 0.60 rising southward, soft ground (`dev_terrain = gentle`, subsidence 0.30). Easy to build on, first to drown.
- **Northfield** (rows 1–2, columns C–F): flat farmland, elevation class 2, the safest and best-value expansion.
- **Copper Ridge** (columns F–G in the north and middle): `hills`, elevation 3–4. Flood-immune and prestigious (`amenity_score` 0.65–0.80) but 16–40 blocked tiles per block, `steep` grading costs, and wind 0.45 / wildfire 0.45 make overhead distribution a liability up there.
- **Foundry / Slag End** (rows 6–7, columns C–F): `industrial_edge`. Pollution 0.70, hazmat 0.60, brownfield clearing. Cheap.
- **Highways:** `SR-9` enters from the north on the block-column D|E boundary; `SR-14` enters from the east on the block-row 4|5 boundary. Both terminate at the core's AVENUE ring, giving the blocks they touch `arterial_connections ≥ 1` and a reduced `min_city_level`.

#### 2.8.2 Attribute + price sheet — all 40 purchasable blocks

Prices computed with **doc 03 §2.7's formula**, standard difficulty, `blocks_owned = 9` (escalation 1.00). `ERI` = `env_risk_index` = doc 03's `risk_index`. Every price rises 6 % per block owned beyond 9 (doc 03's `LAND_ESCALATION`, capped 4×). **`minLvl` is re-based onto the §2.11 city-level ladder** *(report 98 G-1)*: the previous column was authored against an unowned, undefined ladder that started at 1, and every value is now one lower so that ring 1 opens at `city_level 0` — which is what the starter city's 144 residents give you, and what test 13 and the tutorial's first land purchase both require. No price changed.

| Block | Grid | ring | terrain (game) | dev_terrain (doc 03) | elev | flood | ERI | wf edges | arterials n | prestige | buildable | **price @t0** | minLvl |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `B_1_1` | B2 | 1 | flat | `gentle` | 1 | 0.45 | 0.264 | 1 | 0 | 0.00 | 169 | **$9,200** | 0 |
| `B_2_1` | C2 | 1 | flat | `flat` | 2 | 0.18 | 0.143 | 0 | 1 | 0.80 | 169 | **$11,600** | 0 |
| `B_3_1` | D2 | 1 | flat | `flat` | 2 | 0.18 | 0.143 | 0 | 2 | 0.80 | 169 | **$12,600** | 0 |
| `B_4_1` | E2 | 1 | flat | `flat` | 2 | 0.18 | 0.143 | 0 | 2 | 0.80 | 169 | **$12,600** | 0 |
| `B_5_1` | F2 | 1 | hills | `hilly` | 3 | 0.08 | 0.180 | 0 | 0 | 0.00 | 158 | **$11,100** | 0 |
| `B_1_2` | B3 | 1 | flat | `gentle` | 1 | 0.48 | 0.275 | 1 | 1 | 0.80 | 169 | **$12,800** | 0 |
| `B_5_2` | F3 | 1 | hills | `hilly` | 3 | 0.08 | 0.180 | 0 | 1 | 0.80 | 158 | **$15,500** | 0 |
| `B_1_3` | B4 | 1 | flat | `gentle` | 1 | 0.51 | 0.285 | 1 | 1 | 0.80 | 169 | **$12,700** | 0 |
| `B_5_3` | F4 | 1 | hills | `hilly` | 3 | 0.08 | 0.180 | 0 | 2 | 0.77 | 158 | **$16,700** | 0 |
| `B_1_4` | B5 | 1 | flat | `gentle` | 1 | 0.54 | 0.296 | 1 | 1 | 0.77 | 169 | **$12,500** | 0 |
| `B_5_4` | F5 | 1 | hills | `hilly` | 3 | 0.08 | 0.180 | 0 | 2 | 0.69 | 158 | **$16,300** | 0 |
| `B_1_5` | B6 | 1 | flat | `gentle` | 1 | 0.57 | 0.306 | 1 | 0 | 0.00 | 169 | **$9,000** | 0 |
| `B_2_5` | C6 | 1 | flat | `flat` | 1 | 0.30 | 0.186 | 0 | 1 | 0.77 | 169 | **$10,800** | 0 |
| `B_3_5` | D6 | 1 | industrial_edge | `forest` | 1 | 0.30 | 0.363 | 0 | 1 | 0.76 | 169 | **$10,300** | 0 |
| `B_4_5` | E6 | 1 | industrial_edge | `forest` | 1 | 0.30 | 0.363 | 0 | 1 | 0.69 | 169 | **$10,100** | 0 |
| `B_5_5` | F6 | 1 | industrial_edge | `forest` | 2 | 0.22 | 0.335 | 0 | 0 | 0.00 | 169 | **$7,900** | 0 |
| `B_0_0` | A1 | 2 | waterfront | `gentle` | 0 | 0.72 | 0.380 | 2 | 0 | 0.00 | 116 | **$8,500** | 2 |
| `B_1_0` | B1 | 2 | flat | `gentle` | 1 | 0.42 | 0.253 | 1 | 0 | 0.00 | 169 | **$8,500** | 2 |
| `B_2_0` | C1 | 2 | flat | `flat` | 2 | 0.18 | 0.143 | 0 | 0 | 0.00 | 169 | **$7,600** | 2 |
| `B_3_0` | D1 | 2 | flat | `flat` | 2 | 0.18 | 0.143 | 0 | 1 | 0.00 | 169 | **$8,300** | 1 |
| `B_4_0` | E1 | 2 | flat | `flat` | 2 | 0.18 | 0.143 | 0 | 1 | 0.00 | 169 | **$8,300** | 1 |
| `B_5_0` | F1 | 2 | flat | `flat` | 2 | 0.12 | 0.122 | 0 | 0 | 0.00 | 169 | **$7,700** | 2 |
| `B_6_0` | G1 | 2 | hills | `steep` | 3 | 0.06 | 0.173 | 0 | 0 | 0.00 | 143 | **$13,000** | 2 |
| `B_0_1` | A2 | 2 | waterfront | `gentle` | 0 | 0.74 | 0.387 | 2 | 0 | 0.00 | 116 | **$8,400** | 2 |
| `B_6_1` | G2 | 2 | hills | `steep` | 4 | 0.04 | 0.166 | 0 | 0 | 0.00 | 143 | **$13,600** | 2 |
| `B_0_2` | A3 | 2 | waterfront | `gentle` | 0 | 0.76 | 0.394 | 2 | 0 | 0.00 | 116 | **$8,400** | 2 |
| `B_6_2` | G3 | 2 | hills | `steep` | 4 | 0.04 | 0.166 | 0 | 0 | 0.00 | 143 | **$13,600** | 2 |
| `B_0_3` | A4 | 2 | waterfront | `gentle` | 0 | 0.78 | 0.401 | 2 | 0 | 0.00 | 116 | **$8,400** | 2 |
| `B_6_3` | G4 | 2 | hills | `steep` | 4 | 0.04 | 0.166 | 0 | 1 | 0.00 | 143 | **$14,800** | 1 |
| `B_0_4` | A5 | 2 | waterfront | `gentle` | 0 | 0.80 | 0.408 | 2 | 0 | 0.00 | 116 | **$8,300** | 2 |
| `B_6_4` | G5 | 2 | hills | `steep` | 4 | 0.04 | 0.166 | 0 | 1 | 0.00 | 143 | **$14,800** | 1 |
| `B_0_5` | A6 | 2 | waterfront | `marsh` | 0 | 0.88 | 0.436 | 3 | 0 | 0.00 | 106 | **$6,700** | 2 |
| `B_6_5` | G6 | 2 | hills | `steep` | 4 | 0.04 | 0.166 | 0 | 0 | 0.00 | 143 | **$13,600** | 2 |
| `B_0_6` | A7 | 2 | waterfront | `marsh` | 0 | 0.90 | 0.443 | 3 | 0 | 0.00 | 106 | **$6,700** | 2 |
| `B_1_6` | B7 | 2 | flat | `gentle` | 1 | 0.60 | 0.317 | 1 | 0 | 0.00 | 169 | **$8,200** | 2 |
| `B_2_6` | C7 | 2 | industrial_edge | `forest` | 1 | 0.42 | 0.404 | 0 | 0 | 0.00 | 169 | **$6,700** | 2 |
| `B_3_6` | D7 | 2 | industrial_edge | `forest` | 1 | 0.42 | 0.404 | 0 | 0 | 0.00 | 169 | **$6,700** | 2 |
| `B_4_6` | E7 | 2 | industrial_edge | `forest` | 1 | 0.42 | 0.404 | 0 | 0 | 0.00 | 169 | **$6,700** | 2 |
| `B_5_6` | F7 | 2 | industrial_edge | `forest` | 2 | 0.28 | 0.356 | 0 | 0 | 0.00 | 169 | **$7,200** | 2 |
| `B_6_6` | G7 | 2 | hills | `steep` | 3 | 0.10 | 0.187 | 0 | 0 | 0.00 | 143 | **$12,900** | 2 |

Env-risk profiles are keyed by terrain, with `flood` authored per block:

| terrain | wildfire | subsidence | pollution | wind | hazmat |
|---|---|---|---|---|---|
| `waterfront` | 0.05 | 0.35 | 0.20 | 0.25 | 0.05 |
| `flat` — Northfield / south flats (bx ≥ 2) | 0.20 | 0.10 | 0.06 | 0.22 | 0.03 |
| `flat` — The Flats (bx = 1) | 0.10 | 0.30 | 0.12 | 0.20 | 0.05 |
| `hills` | 0.45 | 0.20 | 0.04 | 0.45 | 0.02 |
| `industrial_edge` | 0.30 | 0.15 | 0.70 | 0.20 | 0.60 |

Also authored per terrain: `vegetation_density` flat 0.35 / waterfront 0.45 / hills 0.70 / industrial 0.20 · `slope_index` flat 0.05 / waterfront 0.10 / industrial 0.10 / hills bx5 0.45 / hills bx6 0.70 · `blocked_tiles` 0 except hills bx5 = 16, bx6 = 40 · `water_tiles` 0 except column A = 80 (marsh rows 6–7 = 96).

**Price spread check.** Ring 1 spans **$7,600** (`B_5_5` F6, industrial edge, no AVENUE) to **$16,700** (`B_5_3` F4, ridge-adjacent hills on SR-14) — a 2.2× range. Ring 2 spans **$6,700** (marsh and Foundry) to **$14,800** (`steep` ridge on SR-14). Cheap always means dirty, wet, or off the road network; expensive always means safe, high, or connected. The single dearest thing you can buy at t0 is high ground with a highway on it, and it is also the most expensive to grade — spec §7.2's "High Ground" tradeoff, intact.

#### 2.8.3 Ring 3 — DECLINED, with the arithmetic

> **Wave 10 asked for a ring-3 land tier gated at `city_level` 4+, so the two
> top rungs of §2.11's ladder would pay out in land as well as in buildings.
> It cannot be built on this board, and the reason is geometry rather than
> pricing.**

The world is **7 × 7 blocks** with a **3 × 3** core (§2.8.1). The rings around
that core are exhaustive and there are exactly two of them:

| ring | the shell it is | blocks | check |
|---|---|---|---|
| core | 3 × 3 | 9 | — |
| **1** | 5 × 5 − 3 × 3 | **16** | opens at `city_level` 0 |
| **2** | 7 × 7 − 5 × 5 | **24** | opens at `city_level` 1–2 |
| | | **49** | = 7 × 7, the whole board |

9 + 16 + 24 = 49. **There is no land left.** A ring 3 is the 9 × 9 shell —
another 32 blocks — and buying it means `world.size_blocks` 7 → 9, a 112 × 112
tile grid becoming 144 × 144, every block id in `data/starter_city.json`
re-based, the committed `bench_city.json` fixture regenerated, doc 03 §2.7's
`blocks_owned` escalation re-anchored off a 9-block core into a 40-block one, and
every `world_map` / `tile_grid` / starter-city test re-fitted. That is a *world*
change, not a land tier, and it is nobody's to make inside a content wave.

**Nor is re-gating existing land an option.** Ring 2 currently opens at
`city_level` 1–2. Raising any of those to 4 would take purchasability away from a
city that already has it, which is precisely what §2.11's monotonicity promise
forbids — *"a level, once earned, survives any disaster"* is worth nothing if the
thing the level unlocked can be moved out of reach afterwards.

**So the two top rungs pay out in buildings only**, and doc 02 §2.14's split
carries the whole load: city level 4 opens the `steady` class's sixth rung
(`house`, `store` — the stock a city has dozens of) and city level 5 opens the
tower tier (`apartment`, `office`, `high_rise`, `data_center`). Recorded here so
that the day the board grows, ring 3 has a price sheet waiting for it: §2.8.2's
formula is unchanged and would apply to the 9 × 9 shell unmodified.

### 2.9 The Starter City

> **Rebuilt to report 98 C-11.** The pre-amendment manifest was 28 house / 8 store / 6 apartment / 1 office, chosen to hit doc 03's $686/gh anchor **against doc 02's tax rows — which C-10 deleted.** Against doc 03's rows (the only surviving tax table) that mix yields $1,094/gh, 59 % over target, while the mix doc 03 always named yields the anchor exactly. **The manifest reverts to 18 house / 5 store / 3 apartment / 1 office (all L1) plus the six civic/utility sites.** The road template, block geometry, utility topology and tag registry are unchanged; population, jobs, power and water all re-derive below (recomputation R-16).

#### 2.9.1 Road grid rule and road classes

Roads are stamped from a template so purchased blocks connect automatically. **This doc owns the template; doc 10 owns the class semantics** *(report 98 C-60)*, and the mapping is fixed here:

| Template line | Doc 10 class | Width | Where |
|---|---|---|---|
| block boundary | **`AVENUE`** | 1 tile contributed per side (2 tiles between two developed blocks) | every land-block edge; carries the utility trunks |
| interior collector | **`STREET`** | 1 tile | block-local index 7 on both axes, quartering the block |
| player-placed local road | **`STREET`** | 1 tile | none at t0 |

`alley` stays reserved in doc 10 and is unused in MVP. A boundary against an undeveloped neighbour stays a 1-tile "half AVENUE" and widens when that neighbour reaches `ROAD_INSTALL`.

For the 48 × 48 core this gives road columns/rows at core-local **{0, 7, 15, 16, 23, 31, 32, 39, 47}** — AVENUE at {0, 15, 16, 31, 32, 47}, STREET at {7, 23, 39}.
Result: **783 road tiles of 2,304 (34.0 %)**, **87 per block**, **169 buildable tiles on a clean block** — which is exactly the 0.34 constant used in §2.2. 81 road-grid intersections.

By class: `48×6 + 48×6 − 6×6 = 288 + 288 − 36 = ` **540 AVENUE tiles** and **783 − 540 = 243 STREET tiles**. Doc 10 re-derives its block road-install cost from its own per-tile prices against these counts (its `{0,8}` template is deleted).

**Consequence for doc 02's `E_AVENUE` gate** *(C-62)*: every core block is AVENUE-fronted on all four edges, so the L4/L5 avenue gate never blocks the tutorial. It bites the first time a player develops an interior block and reaches for L4 on STREETs alone.

Between roads sit **36 parcels** (4 per block) of 6×6, 6×7, 7×6 or 7×7 tiles. **Placement rule: every building footprint must be orthogonally adjacent to at least one road tile.** Parcel interiors stay as courtyards.

Named AVENUEs: `x=0` Levee Rd · `x=15/16` Slacum Ave · `x=31/32` Foundry Ave · `x=47` Ridge Rd · `z=0` North Loop · `z=15/16` Grand Ave · `z=31/32` Canal St · `z=47` South Loop.

#### 2.9.2 The 48 × 48 core map

Core-local coordinates; **global tile = core-local + 32**. Column header = ones digit of x.

Legend: `A` AVENUE · `c` STREET (collector) · `.` vacant buildable lot · `~` water ·
`h` house · `H` apartment · `s` store · `O` office ·
`P` power_facility (`plant_gas`) · `S` substation · `W` water_facility (`WTR-1`, 3×3) · `T` water_facility (`WTR-2`, tank, 2×2) ·
`L` police_station · `F` fire_station · `Y` construction_yard.

**Every starter building is Level 1** (doc 02 §2.2: archetypes can only be *constructed* at L1, so a starter city that begins above L1 would be unreachable by the player's own rules). No two same-type buildings are orthogonally adjacent anywhere on the map, so footprints read unambiguously from the glyphs.

```
    0         1         2         3         4       
    012345678901234567890123456789012345678901234567
  0 AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA 0
  1 AYY.h.hcHH....hAAHH....ch.h.h..AAFF.h.hc.......A 1
  2 AYY....cHH.....AAHH....c.......AAFF....c.......A 2
  3 A.....hc.......AA......c.......AA.....hc.......A 3
  4 A......c.......AAh.....c.......AA......c.......A 4
  5 A......c.......AA......c.......AA......c.......A 5
  6 A......c.......AA..h...c.......AA......c.......A 6
  7 AccccccccccccccAAccccccccccccccAAccccccccccccccA 7
  8 Ah.....c.......AA......c.......AA......c.......A 8
  9 A......c.......AA......c.......AA......c.......A 9
 10 A......c.......AA......c.......AA......c.......A 10
 11 A......c.......AA......c.......AA......c.......A 11
 12 A......c.......AA......c.......AA......c.......A 12
 13 A......c.......AA......c.......AA......c.......A 13
 14 A......c.......AA......c.......AA......c.......A 14
 15 AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA 15
 16 AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA 16
 17 A....h.ch......AAs.s.s.cOO.s...AASS....c.......A 17
 18 A......c.......AA......cOO.....AASS....c.......A 18
 19 A~~~~~~c.......AA......c.......AA......c.......A 19
 20 AWWW~~~c.......AA......c.......AA......c.......A 20
 21 AWWW~~~c.......AA......c.......AA......c.......A 21
 22 AWWW~~~c.......AA......c.......AA......c.......A 22
 23 AccccccccccccccAAccccccccccccccAAccccccccccccccA 23
 24 ATT....c.......AA......cHH.....AA......c.......A 24
 25 ATT....c.......AA......cHH.....AA......c.......A 25
 26 A......c.......AA......c.......AA......c.......A 26
 27 A......c.......AA......c.......AA......c.......A 27
 28 A......c.......AA......c.......AA......c.......A 28
 29 A......c.......AA......c.......AA......c.......A 29
 30 A......c.......AA......c.......AA......c.......A 30
 31 AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA 31
 32 AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA 32
 33 ALL.h.hc.......AAs....hc.......AA......c.......A 33
 34 ALL....c.......AA......c.......AA......c.......A 34
 35 A......c.......AA......c.......AA......c.......A 35
 36 A......c.......AA......c.......AA......c.......A 36
 37 A......c.......AA......c.......AA......c.......A 37
 38 A......c.......AA......c.......AA......c.......A 38
 39 AccccccccccccccAAccccccccccccccAAccccccccccccccA 39
 40 A......c.......AA......c.......AA......cPPP....A 40
 41 A......c.......AA......c.......AA......cPPP....A 41
 42 A......c.......AA......c.......AA......cPPP....A 42
 43 A......c.......AA......c.......AA......c.......A 43
 44 A......c.......AA......c.......AA......c.......A 44
 45 A......c.......AA......c.......AA......c.......A 45
 46 A......c.......AA......c.......AA......c.......A 46
 47 AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA 47
    0         1         2         3         4       
    012345678901234567890123456789012345678901234567
```

**Mill Creek & Mill Pond** (`~`, 15 tiles, block `B_2_3` C4): creek at (1–3, 19), pond at (4–6, 19–22). Levee Rd tile (0,19) is a **culvert** — road, not water. This is the water system's raw source and the only surface water inside the core.

#### 2.9.3 Building manifest

**34 buildings, all Level 1.** Footprints are doc 02's L1 values, except the `tank` variant, whose 2×2 footprint is doc 05's *(report 98 C-35 — doc 02 owns the `water_facility` shell and variant list, doc 05 owns the per-variant numbers)*.

| id | type (doc 02) | variant (doc 05) | foot | origin (core-local) | origin (global) | block | notes |
|---|---|---|---|---|---|---|---|
| `YARD-1` | `construction_yard` | — | 2×2 | (1,1) | (33,33) | `B_2_2` C3 | 1 `construction_crew` + 1 `road_crew` at L1 (doc 06 roster) |
| `FIRE-1` | `fire_station` | — | 2×2 | (33,1) | (65,33) | `B_4_2` E3 | NE quadrant |
| `WTR-1` | `water_facility` | `pump` (reference) | 3×3 | (1,20) | (33,52) | `B_2_3` C4 | the water works; hosts three co-located doc-05 nodes — see §2.9.6 |
| `WTR-2` | `water_facility` | `tank` | 2×2 | (1,24) | (33,56) | `B_2_3` C4 | elevated tank, 120 m³, 30 m head, 5.0 kW |
| `OFF-1` | `office` | — | 2×2 | (24,17) | (56,49) | `B_3_3` D4 | the only office; downtown anchor |
| `SUB-A` | `substation` | — | 2×2 | (33,17) | (65,49) | `B_4_3` E4 | the city's only substation; 2 feeder slots at L1 |
| `POL-1` | `police_station` | — | 2×2 | (1,33) | (33,65) | `B_2_4` C5 | SW quadrant |
| `PLANT-1` | `power_facility` (`plant_gas`) | — | 3×3 | (40,40) | (72,72) | `B_4_4` E5 | 8 MW at L1 (doc 04) |
| 18 × `house` | `house` | — | 1×1 | see below | | | |
| 3 × `apartment` | `apartment` | — | 2×2 | see below | | | |
| 5 × `store` | `store` | — | 1×1 | see below | | | |

Revenue-building origins (core-local), authored so the removal from the old 28/8/6/1 layout is pure subtraction — every surviving building keeps its exact tile:

| class | origins | block |
|---|---|---|
| `house` ×5 | (4,1) (6,1) (14,1) (6,3) (1,8) | `B_2_2` C3 |
| `house` ×5 | (24,1) (26,1) (28,1) (17,4) (19,6) | `B_3_2` D3 |
| `house` ×3 | (36,1) (38,1) (38,3) | `B_4_2` E3 |
| `house` ×2 | (5,17) (8,17) | `B_2_3` C4 |
| `house` ×2 | (4,33) (6,33) | `B_2_4` C5 |
| `house` ×1 | (22,33) | `B_3_4` D5 |
| `apartment` ×3 | (8,1) · (17,1) · (24,24) | `B_2_2` · `B_3_2` · `B_3_3` |
| `store` ×4 | (17,17) (19,17) (21,17) (27,17) | `B_3_3` D4 |
| `store` ×1 | (17,33) | `B_3_4` D5 |
| `office` ×1 | (24,17) | `B_3_3` D4 |

**"Six civic/utility sites."** Doc 03 §2.12 names them as *police, fire, gas plant, substation, water plant, construction yard*. The water plant is **one site, two building records** here (`WTR-1` pumping/treatment/intake + `WTR-2` gravity tank), because doc 05 needs the tank as a distinct node with its own head, capacity and 5 kW draw. Six sites, seven non-revenue building records, one anchor — the counts reconcile.

`POL-1` and `FIRE-1` sit on opposite diagonal corners of a 384 m core; every tile is within 34 tiles of each, so at doc 06's response speeds no part of the starter city is unreachable — coverage only becomes a real constraint once the player expands.

#### 2.9.4 Starter totals and the doc 03 anchor — recomputation R-16

Every figure below is generated from the **amended** sibling tables: doc 03's `base_tax_by_level` (C-10), doc 02's post-C-13 `Pwr kW` and post-C-34 `Water WU/gh` columns, doc 05's per-variant `base_kw` (C-35), doc 01's normalized diurnal channels (C-32/C-33) and doc 04's distributed-sink rates.

**Gross base tax — the anchor, exactly.**

```
18 × $12  +  5 × $26  +  3 × $70  +  1 × $130
=   216   +    130    +    210    +    130     =  $686/gh          (doc 03 §3.2 L1 rows)
```

`STARTER_GROSS_TAX_PER_HOUR = 686 ± 5 %` is hit **on the nose, with zero tolerance consumed** — because this is the mix doc 03 always assumed. The pre-amendment 28/8/6/1 rebuild evaluates to `28×12 + 8×26 + 6×70 + 1×130 = 336 + 208 + 420 + 130 = $1,094/gh`, **59 % over target**, and is withdrawn.

**Population and jobs.**

```
population = 18 houses × 4  +  3 apartments × 24  =  72 + 72  =  144       (256 → 144)
jobs       = 5 store×6  + 3 apt×2  + 1 office×30                = 30 + 6 + 30 = 66   (market)
           + police 12 + fire 14 + plant 20 + substation 4
           + 2 water_facility ×10 + yard 16                     = 86              (civic/utility)
           = 152 total
```

At t0 every authored building ships at `occ_b = 1.00` (§2.10: they are pre-existing, `building_age_hours ≥ 36`, and `city_stability 0.9475` puts city attractiveness at its 1.00 ceiling), so occupied population **is** capacity: **144**, and occupancy-weighted base tax is also exactly **$686/gh**. Market job fill is `clamp01(workforce 79.2 / market jobs 66) = 1.00` — the starter city is still job-rich, and the pressure is still housing.

**Electrical load at the 20:00 night peak** *(recomputation R-16, forced by C-13, C-32 and C-34)*. Building demand is `Σ base_kw × ctx.channels.power_demand_<class>`, with doc 04's archetype→class map and doc 01's normalized channel values at 20:00 — `RES 1.46`, `COM 1.14`, `IND 1.0033`, `CIV 0.9592`, `streetlight_load 1.00` (doc 04 §2.13 publishes these exact reads). `substation` has no demand class and draws 0 kW; `power_facility` own-use is 0 kW at every level in doc 02's amended table.

| class | buildings | nameplate kW | channel @20:00 | night kW |
|---|---|---|---|---|
| RES | 18 house × 3.0 + 3 apartment × 22 | 54.0 + 66.0 = 120.0 | 1.4600 | **175.20** |
| COM | 5 store × 9.0 + 1 office × 35 | 45.0 + 35.0 = 80.0 | 1.1400 | **91.20** |
| IND | 1 construction_yard × 12 | 12.0 | 1.0033 | **12.04** |
| CIV | police 25 + fire 28 + `PLANT-1` 0 + `WTR-1` 132 + `WTR-2` 5 | 190.0 | 0.9592 | **182.25** |
| — | `SUB-A` | 0 | — | **0.00** |
| | **building total** | **402.0 nameplate** | | **460.69** |

```
streetlights  = 783 road tiles × 0.35 kW × 1.00      = 274.05 kW
traffic signals = 81 intersections × 0.6 kW          =  48.60 kW
NIGHT PEAK      = 460.69 + 274.05 + 48.60            = 783.34 kW  →  783.3 kW
                = 9.8 % of PLANT-1's 8,000 kW,  13.1 % of SUB-A's 6,000 kW
```

**831 kW → 783.3 kW.** Three amendments push in different directions and very nearly cancel: the smaller manifest removes 106 kW of nameplate residential/commercial load, C-35 replaces two flat 60 kW `water_facility` shells with a 132 kW water works and a 5 kW tank (+17 kW), and C-32's normalization lifts the residential channel ~26 % and the commercial channel ~30 % above the un-normalized curves doc 04 used to carry. **Distributed sinks now carry 41 % of the night peak** (322.65 kW of 783.34) — the streetlights and signals are no longer a rounding error against the buildings, which is exactly why a blackout reads on screen.

**Water demand** *(C-34 applied — `1 WU ≡ 1 m³/h`, doc 02's column already divided by 6.25)*:

| archetype | n | m³/h each | subtotal |
|---|---|---|---|
| `house` | 18 | 0.08 | 1.44 |
| `apartment` | 3 | 0.48 | 1.44 |
| `store` | 5 | 0.13 | 0.65 |
| `office` | 1 | 0.32 | 0.32 |
| `police_station` | 1 | 0.19 | 0.19 |
| `fire_station` | 1 | 0.40 | 0.40 |
| `power_facility` | 1 | 0.96 | 0.96 |
| `construction_yard` | 1 | 0.16 | 0.16 |
| `substation`, `water_facility` ×2 | 3 | 0.00 | 0.00 |
| | | **total** | **5.56 m³/h** |

Routed through doc 05's `demand_split` shares and doc 01's `water_demand_residential` / `water_demand_commercial` channels, the day shapes to **7.10 m³/h at the 07:00 morning peak** and **6.24 m³/h at 20:00**; the 24-hour mean is the nameplate 5.56 m³/h (both channels are normalized to 1.000).

**51.1 WU/gh → 5.56 m³/h.** `51.1 / 6.25 = 8.18` is the rescale of the *old* 28/8/6/1 manifest — the figure report 98 C-34 and doc 05 §2.13 both quote as "8.2". Applying C-11's smaller mix as well lands at **5.56**; the report's headline double-counts the mix in words but not in arithmetic. Against **40.0 m³/h** of L1 pump capacity that is **7.2× headroom** on the daily mean and **5.6× at the morning peak** — comfortable, and comfortable is correct for a tutorial city whose water crisis is supposed to arrive through the *power* system.

Per block:

| block | grid | district | contents | tax $/gh | pop | jobs |
|---|---|---|---|---|---|---|
| `B_2_2` | C3 | `D_NORTHGATE` | `YARD-1`, 5 house, 1 apartment | 130 | 44 | 18 |
| `B_3_2` | D3 | `D_NORTHGATE` | 5 house, 1 apartment | 130 | 44 | 2 |
| `B_4_2` | E3 | `D_NORTHGATE` | `FIRE-1`, 3 house | 36 | 12 | 14 |
| `B_2_3` | C4 | `D_MILLPOND` | `WTR-1`, `WTR-2`, 2 house | 24 | 8 | 20 |
| `B_3_3` | D4 | `D_DOWNTOWN` | `OFF-1`, 4 store, 1 apartment | 304 | 24 | 56 |
| `B_4_3` | E4 | `D_DOWNTOWN` | `SUB-A` | 0 | 0 | 4 |
| `B_2_4` | C5 | `D_MILLPOND` | `POL-1`, 2 house | 24 | 8 | 12 |
| `B_3_4` | D5 | `D_FOUNDRY` | 1 store, 1 house | 38 | 4 | 6 |
| `B_4_4` | E5 | `D_FOUNDRY` | `PLANT-1` | 0 | 0 | 20 |
| | | | **TOTAL** | **686** | **144** | **152** |

Starter districts (all 4-connected, all ≤ 4 blocks), with `stability` worked from §2.6 at nominal utilities (`power_reliability` 1.00, `water_reliability` 1.00, `crime_index` 0.10, `fire_risk` 0.12, `road_access_quality` 1.00 ⇒ a fixed base of `0.300 + 0.200 + 0.180 + 0.150 + 0.044 = 0.874`, plus `0.10 × employment_ratio`):

| district | label | blocks | pop | jobs | employment_ratio | **t0 stability** |
|---|---|---|---|---|---|---|
| `D_NORTHGATE` | Northgate | `B_2_2`, `B_3_2`, `B_4_2` | 100 | 34 | 34 / 55 = 0.6182 | 0.874 + 0.0618 = **0.9358** |
| `D_DOWNTOWN` | Downtown | `B_3_3`, `B_4_3` | 24 | 60 | 60 / 13.2 → 1.00 | 0.874 + 0.1000 = **0.9740** |
| `D_MILLPOND` | Millpond | `B_2_3`, `B_2_4` | 16 | 32 | 32 / 8.8 → 1.00 | **0.9740** |
| `D_FOUNDRY` | Foundry Flats | `B_3_4`, `B_4_4` | 4 | 26 | 26 / 2.2 → 1.00 | **0.9740** |

`city_stability = (100×0.9358 + 24×0.9740 + 16×0.9740 + 4×0.9740) / 144 = 136.436 / 144 = ` **0.9475**.

**1,429 of 2,304 core tiles are vacant buildable lots (62.0 %)** — `2,304 − 783 road − 15 water − 77 footprint`, where the footprint total is `18×1 + 3×4 + 5×1 + 1×4 + 4×(2×2 civic) + 9 (plant) + 9 (WTR-1) + 4 (WTR-2) = 77`. The C-11 revert hands the player 30 more empty lots than the old manifest (1,399 → 1,429), so onboarding step 2 ("build one house", spec §41) always has a legal site and blocks `B_4_3`/`B_4_4` remain deliberately near-empty utility blocks with room to grow.

#### 2.9.5 Power — one plant, one substation, two feeders, no tie

Doc 04's component ratings drive this: `plant_gas` L1 = 8,000 kW / 3×3 · `substation` L1 = 6,000 kW, **2 feeder slots**, 2×2 · `transformer` L1 = 50 kW / radius 3, L2 = 150 kW / radius 4, L3 = 400 kW / radius 5 · `feeder` class 1 = 1,200 kW.

```
PLANT-1  gas, 8 MW, terminal (39,41)
   └─ TL-1  transmission cls 1, 30 tiles: (39,41)→(39,32)→(32,32)→(32,18)
SUB-A    6 MW, 2 feeder slots, HV terminal (32,18)
   ├─ F_NORTH  feeder cls 1, overhead. 34 tiles: (32,18)→(32,16)→(0,16)
   │            laterals (27 t): (39,16)→(39,7) · (23,16)→(23,7) · (7,16)→(7,7)
   │            serves T-01…T-13.  Night load 361.8 kW / 1,200 kW = 30.1 %
   └─ F_SOUTH  feeder cls 1, overhead. 46 tiles: (32,18)→(32,32)→(0,32)
                laterals (28 t): (7,32)→(7,39) · (23,32)→(23,39) · (32,32)→(39,32)→(39,39)
                riser   (12 t): (0,32)→(0,20)  → service drops to WTR-1 (0,20) and WTR-2 (0,24)
                serves T-14…T-23.  Night load 421.6 kW / 1,200 kW = 35.1 %
```

All polylines run in road right-of-way and are axis-aligned segment by segment.

**Line inventory published to docs 03 and 04** (doc 03 computes `E_grid` from it; doc 04 stores it): feeders `34 + 27 + 46 + 28 + 12 = 147 tiles = 1.18 km`; transmission `30 tiles = 0.24 km`; **total 177 line tiles = 1.42 km**. Every line is overhead and `condition 1.0` at t0.

**Transformer sizing rule** *(generalized from the old flat "> 35 kW ⇒ L2")*: a transformer is authored at **the smallest level whose capacity leaves ≥ 30 % headroom over its t0 night load** — `night_load ≤ TRANSFORMER_HEADROOM_FRAC (0.70) × capacity_kw`. The old rule was the same rule stated only for L1 (`0.70 × 50 = 35 kW`); writing it as a fraction makes it hold at every level, and it is the reason the water works now needs an L3. The 30 % margin is sized against doc 04's heat-wave stack: at 40 °C the CIV/RES load multiplier reaches ~1.48 while transformer capacity derates to 0.92, so a transformer at 70 % nominal is the largest that survives a heat wave without the player touching it.

**Eighteen transformers** *(doc 92 §14.1 F-4, ruled Wave 4; the doc edit doc 92 §16 held is applied here)*, sited on road tiles so that **every building origin is within 3 tiles of one** (doc 04's L1 service radius). Streetlights and signals attach to their nearest transformer with no radius limit (doc 04 §2.3), which is why transformers with no building customers still carry real load.

> **23 → 18: what F-4 changed and what it did not.** Doc 92 measured the founding roster against the placement pacing it is supposed to create and found five nodes the map does not need: **`T-05`, `T-08`, `T-16`, `T-21` and `T-22` are deleted.** Their streetlights, signals and building customers re-home onto the nearest surviving transformer — doc 04 §2.3 attaches distributed sinks with **no radius limit** — so **the LOAD is conserved and only its distribution moves**. `T-03`, `T-04`, `T-07`, `T-12`, `T-13`, `T-14`, `T-15`, `T-17`, `T-19`, `T-20` and `T-23` re-load accordingly, and four of them (`T-19`, `T-20` among them) step up a level under the sizing rule above rather than run past 70 %. What DOES fall is the rated PLATE — `2.40 → 2.25 MVA` — which is $0.60/gh off doc 03 §2.4's `E_grid` and nothing else. The set-cover argument behind the floor is in `tests/test_balance_gates.gd` gate 10: those 34 authored building origins are spread across all nine core blocks, a cover of them needs 16–17 nodes, and 18 is the roster that also keeps `tutorial_lot_b` served and `tutorial_lot_a` exactly one tap away.

Loads below are **metered off the running sim at 20:00**, not hand-derived, so they include doc 05's live node roster (see the basis note under the table).

| id | tile | feeder | level | cap kW | night load kW | %cap | streetlights | signals | building customers |
|---|---|---|---|---|---|---|---|---|---|
| T-01 | (0,0) | F_NORTH | L1 | 50 | 15.6 | 31 % | 7 | 1 | `YARD-1` |
| T-02 | (8,0) | F_NORTH | L2 | 150 | 36.8 | 25 % | 8 | 1 | 1 apartment |
| T-03 | (27,0) | F_NORTH | L1 | 50 | 29.3 | 59 % | 36 | 5 | 3 houses |
| T-04 | (35,0) | F_NORTH | L2 | 150 | 65.4 | 44 % | 56 | 7 | `FIRE-1`, 3 houses |
| T-06 | (7,2) | F_NORTH | L1 | 50 | 19.2 | 38 % | 14 | 1 | 3 houses |
| T-07 | (16,3) | F_NORTH | L2 | 150 | 56.0 | 37 % | 22 | 2 | 1 apartment, 3 houses |
| T-09 | (15,5) | F_NORTH | L1 | 50 | 7.5 | 15 % | 18 | 2 | — |
| T-10 | (0,7) | F_NORTH | L1 | 50 | 10.1 | 20 % | 14 | 1 | 1 house |
| T-11 | (7,14) | F_NORTH | L1 | 50 | 21.5 | 43 % | 32 | 2 | 2 houses |
| T-12 | (18,15) | F_NORTH | L2 | 150 | 51.8 | 35 % | 48 | 5 | 3 stores |
| T-13 | (26,15) | F_NORTH | L2 | 150 | 62.9 | 42 % | 27 | 2 | `OFF-1`, 1 store |
| T-14 | (31,17) | F_SOUTH | L2 | 150 | 38.6 | 26 % | 95 | 9 | `SUB-A` (0 kW) |
| T-15 | (0,20) | F_SOUTH | **L3** | 400 | 140.3 | 35 % | 20 | 3 | **`WTR-1` — the water works** |
| T-17 | (23,21) | F_SOUTH | L2 | 150 | 44.4 | 30 % | 28 | 2 | 1 apartment |
| T-18 | (0,24) | F_SOUTH | L1 | 50 | 8.0 | 16 % | 7 | 1 | `WTR-2` (tank, 5 kW) |
| T-19 | (3,31) | F_SOUTH | L2 | 150 | 74.7 | 50 % | 99 | 10 | `POL-1`, 2 houses |
| T-20 | (19,31) | F_SOUTH | L2 | 150 | 58.3 | 39 % | 106 | 10 | 1 store, 1 house |
| T-23 | (39,37) | F_SOUTH | L2 | 150 | 61.3 | 41 % | 146 | 17 | `PLANT-1` (0 kW site service) |

**Fleet: 7 × L1 + 10 × L2 + 1 × L3**, `rated_mva = 7×0.05 + 10×0.15 + 1×0.40 = 0.35 + 1.50 + 0.40 = **2.25**` published to doc 04 and thence to doc 03's `E_grid`. Every surviving node still sits inside the sizing rule's 70 % headroom, worst case `T-03` at 59 %.

**Basis note — 783.4 kW published, 801.7 kW metered.** This doc's own arithmetic gives a 20:00 system peak of **783.4 kW**, split `F_NORTH 365.8 / F_SOUTH 417.6` — that is the figure `data/world.json`'s `starter` block carries and `tests/test_starter_city.gd` asserts, and it is computed against the per-variant L1 constants doc 05 published for the water works. The **running sim meters 801.7 kW** (`F_NORTH 376.0 / F_SOUTH 425.7`) because doc 05's LIVE node roster is ~+18.4 kW over those constants. Both numbers are correct at their own layer, the gap is a doc-05 inventory difference rather than a disagreement about this city, and **doc 93 §E2 owns the shift table** — this doc publishes the first and the sim meters the second.

Two C-35 consequences are visible in that table and both are the ruling working as intended. **`WTR-2` drops from an L2 to the smallest transformer in the city**, because a gravity tank draws 5 kW of telemetry and cathodic protection, not the flat 60 kW doc 02 used to assign every `water_facility`. **`WTR-1` climbs to the only L3**, because the intake, the package treatment plant and the duty pump together draw 132 kW — and that is the correct shape: the water works is the single largest, most critical load in the starter city and it should look like it on the overlay.

**The designed lesson, restated on the new numbers.** There is **no tie switch** at t0 and only one substation, so `F_SOUTH` is a radial overhead feeder with no alternate supply carrying *the water works, the police station, all of downtown, and `PLANT-1`'s own site service*. It carries **421.6 kW of the city's 783.3 kW — 53.8 %** (the old manifest's figure was 54 %; the lesson survives the revert intact) while housing only 44 of 144 residents, so **the south feeder is 31 % of the people and 54 % of the load**. One wind or lightning fault on it (doc 07 → doc 06's `storm_damage` generator → doc 04's damage resolution) darkens over half the city's load, stops the pumps, and starts the tank draining. Two fixes exist and both are real purchases: a **normally-open tie switch** plus its 16-tile connecting segment along the STREET at core-local x = 23 between `F_NORTH`'s (23,16) lateral and `F_SOUTH`'s (23,32) lateral, switch at (23,23) — the designed first resilience buy; or a **second substation** on the reserved parcel at (40–46, 24–30) in `B_4_3` (E4), which is why that parcel is empty.

#### 2.9.6 Water — looped mains, one pressure zone

**Node kinds are now `water_facility` variants** *(C-35)*. `WTR-1` is one building hosting three co-located doc-05 nodes at the same terminal (0,20) — the intake structure, the package treatment skid and the pump house are one facility on the ground and three nodes in the graph, exactly as doc 05's `junction` is topology without a building:

| node | variant | doc 05 L1 rating | `base_kw` | state at t0 |
|---|---|---|---|---|
| `WTR-1-SRC` | `source` (river/pond intake) | `yield_m3h` 107 | 32 | ok |
| `WTR-1-TRT` | `treatment` | `throughput_m3h` 80.0 | 40 | ok |
| `WTR-1-PMP` | `pump` (duty pump `P-1`) | `rated_flow_m3h` 40.0, head 34 m | 60 | ok |
| — `P-2` | second pump in the same house | — | 0 | `offline_manual` — standby |
| `WTR-2` | `tank` | `capacity_m3` 120, `max_out` 66.5, `max_in` 26.5, head 30 m | 5.0 | ok |

`WTR-1` site load = `32 + 40 + 60 = ` **132 kW** (the standby pump draws nothing until the player or an auto-changeover starts it — that is what the `tutorial_pump` tag is for). Backup coverage is `coverage_frac = 0.00` at L1 across the board (doc 05 §2.6), so **the starter water works has no generator**: losing `F_SOUTH` stops it dead. That is the cascade.

```
WTR-1 terminal (0,20)   WTR-2 terminal (0,24)
   M_RISER   4 t: (0,20)→(0,24)            source ↔ tank
   M_NORTH  51 t: (0,20)→(0,16)→(47,16)    north trunk along Grand Ave
   M_SOUTH  55 t: (0,24)→(0,32)→(47,32)    south trunk along Canal St
   M_TIE    16 t: (23,16)→(23,32)          cross-tie — closes the loop
   laterals: 7 tiles each along every block's interior STREET to the block centre
```

Nine hydrants at (8,7) (24,7) (40,7) (8,23) (24,23) (40,23) (8,39) (24,39) (40,39). Doc 05's `max_service_distance_tiles = 12` from a live main tile covers all 2,304 core tiles from the mains above, so the whole core is inside one pressure zone `Z1`.

**Supply headroom at t0** (against §2.9.4's demand): source `107 / 7.10 = 15.1×` · treatment `80.0 / 7.10 = 11.3×` · duty pump `40.0 / 7.10 = 5.6×` at the morning peak, `7.2×` on the daily mean. Doc 05's own anchor — one L1 pump serves ~2,000 residents — says the same thing from the other end: 144 residents is 7 % of one pump.

**Tank autonomy — recomputed** *(C-34, R-16)*. `WTR-2` holds 120 m³ with a 66.5 m³/h maximum outflow, which is never the binding constraint here:

| scenario | draw | autonomy = 120 ÷ draw |
|---|---|---|
| 24-hour mean | 5.56 m³/h | **21.6 game-hours** |
| 20:00 night | 6.24 m³/h | **19.2 game-hours** |
| 07:00 morning peak | 7.10 m³/h | **16.9 game-hours** |
| night + 2 engines flowing on a fire (`2 × fire_flow_per_engine_m3h 8.0`) | 22.24 m³/h | **5.4 game-hours** |

**The old "2.3 game-hours" was a unit error, not a design decision.** It divided a *post*-rescale tank (120 m³) by a *pre*-rescale demand (51.1 WU/gh) — the exact 6.25× mismatch C-34 exists to kill. Computed consistently in either scale, the pre-amendment starter city's buffer was already ~17.6 gh. So the honest post-C-34 answer is that **the tank is not the drama; the pumps are.** A night-time `F_SOUTH` fault does not empty the tank before morning — it stops 40 m³/h of production while 120 m³ of storage drains slowly, and the emergency arrives the moment a fire starts and two engines pull 16 m³/h out of the same tank, which cuts the buffer to 5.4 hours and drops `hydrant_pressure_ratio` for every subsequent engine. That is a *better* lesson than a dry tank at 3 a.m., because it teaches the coupling (power → pumps → hydrants → fire response) rather than a timer, and it is doc 05's `fire_draw_z` term doing the work.

**Water is looped where power is radial.** That asymmetry is deliberate and is the doc's clearest teaching device: a single main break isolates a segment and the loop keeps the city wet, while a single feeder fault takes half the city's load dark. If playtesting wants a tighter buffer, the lever is doc 05's `tank` L1 anchor, not this doc's topology — the starter city ships one tank at L1 by design.

#### 2.9.7 Named entities for the tutorial (answers doc 12 open question 7)

`starter_city.json` carries a `tags: []` array on blocks, buildings and tiles. Doc 12 must reference **tags**, never raw ids, so the layout can move without breaking the tutorial. The tags doc 12 asked for are guaranteed, and all of them survived the C-11 revert:

| doc 12 name | tag | resolves to at t0 |
|---|---|---|
| `tutorial_lot_A` | `tutorial_lot_a` | vacant tile (11,8) core-local, block `B_2_2` C3 — visible from the opening camera |
| `tutorial_lot_B` | `tutorial_lot_b` | vacant tile (13,8) core-local, block `B_2_2` C3 |
| transformer `T-04` | `tutorial_transformer` | `T-04` at (35,0), the fire station's L2 transformer on `F_NORTH` — scripted failure target, session 1 |
| pump `P-2` | `tutorial_pump` | the standby pump inside `WTR-1`, `offline_manual` at t0 |
| `Utility 1` | `tutorial_utility_vehicle` | doc 06's first `utility_service_truck`; homed at `YARD-1` |
| block `E4` | `tutorial_expansion_block` | `B_4_3` E4 — the empty utility block with the reserved second-substation parcel |
| `Substation A` | `tutorial_substation` | `SUB-A` |
| first land purchase | `tutorial_land_block` | `B_3_1` D2 — flat, 2 AVENUE connections, lowest risk on the board, **$12,600**, `min_city_level 0` |

### 2.10 Population, occupancy, job fill and happiness — absorbed per report 98 G-1

> **Ownership gap G-1, closed here.** Doc 02 read `occupancy`/`job_fill` "from doc 03"; doc 03 read them "from doc 11 population"; doc 08's registry named a "Districts, Population & Stability" doc that did not exist. It does now: **this one.** New code root `sim/population/`, new save sections `population` and `progression`. Doc 02's `occupancy`/`job_fill` save fields are deleted on its side; nothing caches these but `sim/population/`.

Constitution §8 stands: population is **aggregate per building**, never individual citizens.

#### 2.10.1 The three population numbers

```
population_capacity      = Σ_b building.population                       # doc 02 level_stats, all buildings
population_capacity_res  = Σ_b building.population  over residential archetypes
occupied_population      = Σ_b building.population × occ_b               # the number the HUD shows
city_population          = round(occupied_population)                    # what city_level reads (§2.11)
workforce                = occupied_population × WORKFORCE_FRACTION (0.55)
jobs_capacity            = Σ_b building.jobs                             # every archetype; feeds district stability
jobs_market              = Σ_b building.jobs  over revenue archetypes    # store, office, apartment, high_rise, data_center
jobs_civic               = jobs_capacity − jobs_market                   # police, fire, plant, substation, water, yard
```

**Civic and utility jobs are city-staffed, not market-filled.** Their headcount is paid for through doc 03's `station_upkeep` and `E_grid`/`E_water`, so they are always `job_fill = 1.00` and they are **excluded from the market denominator**. If they were not, a starter city with 86 civic jobs against 79 workers would report every store half-empty on day one, which is both wrong and unteachable.

#### 2.10.2 Occupancy and job fill

Doc 03 §2.2 consumes one scalar per building, `occ_b ∈ [0,1]`, defined as *occupied population / capacity* for residential and *jobs filled / jobs* for everything else. Both come out of three factors:

```
occ_b (residential)      = STATE_OCCUPANCY[state] × ramp(age_b) × A_city
occ_b (revenue, jobs)    = STATE_OCCUPANCY[state] × ramp(age_b) × A_city × job_fill_city
occ_b (civic / utility)  = STATE_OCCUPANCY[state]                        # always fully staffed

ramp(age_h)     = clamp(0.35 + 0.65 × age_h / OCCUPANCY_RAMP_HOURS (36), 0.35, 1.00)
job_fill_city   = clamp01( workforce / max(1, jobs_market) )
A_city(t+dt)    = A_city + (A_target − A_city) × (1 − exp(−dt_h × growth_rate_multiplier / ATTRACT_TAU_H (12)))
A_target        = min( A_stab(city_stability), A_happy(H), A_tax(Δ_tax) )        # §2.10.2a
A_stab(S)       = clamp( (S − 0.35) / 0.50, 0.25, 1.00 )
```

- `STATE_OCCUPANCY` is **doc 02's** eight-row state table (`active` 1.00, `damaged`/`repairing` 0.40, `under_construction_upgrade` 0.50, `on_fire`/`destroyed`/`planned`/`under_construction_new` 0.00). This doc multiplies it; it does not redefine it.
- `ramp` is exactly doc 03's stated behaviour — a fresh building fills from 0.35 to 1.00 over **36 game-hours**, linearly. `age_b` is `(sim_time_minutes − built_at_minutes) / 60`.
- `A_city` is **city attractiveness**: the fraction of a building's nominal tenants who are willing to live in this city right now. It relaxes toward `A_target` with a 12 game-hour time constant, so a blackout empties buildings gradually and refilling them takes just as long. `growth_rate_multiplier = 1 − (tax_rate − 0.09) × TAX_RATE_GROWTH_COEFF (8.0)` comes from **doc 03** and scales the relaxation RATE, in both directions: a 16 % rate empties *and* refills the city 56 % slower.
- `A_stab` is deliberately saturated: at `city_stability ≥ 0.85` it clamps to 1.00, so a well-run city loses nobody to instability, and it falls linearly to a 0.25 floor as stability collapses. The floor exists because a city never empties completely.
- `A_happy` and `A_tax` are **§2.10.2a**, below. Both are 1.00 for the founding city, so every worked value in this section is unchanged by their arrival.
- `job_fill_city` is a single city-wide ratio, applied uniformly. There is **no per-building job allocation loop** — a loop would be order-dependent and would break the offline coarse path's exactness for no gameplay gain.

##### 2.10.2a The tax–growth coupling — amendment T-1

> **Why this exists.** Doc 03 §2.2 publishes `growth_rate_multiplier` into this doc's relaxation, and doc 92 pass-2 F-5 ruled `TAX_RATE_GROWTH_COEFF` 3.5 → 8.0 so that the top tax detent would cost "a city later" instead of a decimal of happiness. It cost nothing. The multiplier scales `(A_target − A_city)`, and for **any** city with `city_stability ≥ 0.85` that difference is exactly zero: `A_target` was saturated at 1.00 and a founding city starts at 1.00. A controlled pair at detent 5 and detent 12 ended 2, 3, 5, 7, 10 and 14 game-days with **the same 224 people**. The rate lever cannot move a city that is already where it is going, and no value of the coefficient could have fixed that. T-1 adds the half that was missing: the tax slider moves the **target**.

`A_target` is the **most binding of three ceilings**, not their product:

```
A_target  = min( A_stab(S), A_happy(H), A_tax(Δ_tax) )                    ∈ [0.25, 1.00]

A_happy(H)     = clamp( 1 + ATTRACT_HAPPINESS_PULL × min(0, H − ATTRACT_HAPPINESS_REF) / 100,  0.25, 1.00 )
A_tax(Δ_tax)   = clamp( 1 + TAX_RATE_ATTRACT_PULL  × min(0, Δ_tax)                      / 100,  0.25, 1.00 )

ATTRACT_HAPPINESS_REF  = 60      # this doc, sim/population/population_system.gd
ATTRACT_HAPPINESS_PULL = 1.30    # this doc
TAX_RATE_ATTRACT_PULL  = 1.30    # DOC 03, data/economy.json → tax
Δ_tax = happiness_tax_delta = −(r − 0.09) × 360                          # doc 03 §2.2, coeff owned there
```

**`min`, and not a product — this is the whole no-double-count rule.** The tax bill is *already* inside `H`: `happiness_tax_delta` is a term of `H_target` (§2.10.3), so twelve game-hours after a hike the happiness channel has absorbed it too. Multiplying `A_happy × A_tax` would bill the same discontent twice, and it compounds exactly where it should not: the shipped detent-12 city settles at `H = 53.9` *because of the tax*, so the product would deepen the ceiling from 0.6724 to 0.619 for the same 25.2 points, and the deeper it went the further `H` would fall. Taking the **minimum** bills it once, through whichever channel is currently harsher: the tax term is *immediate* (policy is instant), the happiness term is *lagged* (mood is not). Because both terms carry the same pull, the crossover has a one-line reading: **the happiness ceiling takes over exactly when `H` has fallen further below 60 than the tax bill itself** — at the top detent, below `60 − 25.2 = 34.8` (the Wave-7 coefficient; the crossover moves with `TAX_RATE_HAPPINESS_COEFF` and with nothing else). That is genuine misery, not the tax bill charged again. The rate is read exactly once in the entire coupling, by `happiness_tax_delta`; §2.10 never sees `tax_rate`.

**Why the reference is 60.** It is this doc's own `H` baseline (§2.10.3) and the pivot of doc 03's `f_happiness`, so *a perfectly average city is attractiveness-neutral exactly as it is revenue-neutral*. Above 60 the happiness ceiling is 1.00 — happiness can never lift `A_target` **above** the stability ceiling, only fail to drag it below. The same one-sided rule governs `A_tax` (`min(0, Δ_tax)`): cutting tax buys a 1.40× faster refill through `growth_rate_multiplier`, never a higher ceiling. Rate and target are different levers on purpose.

**Worked at the three detents**, founding city (`S = 0.9475`, so `A_stab = 1.00`):

| detent | `r` | `Δ_tax` | `A_tax` | equilibrium `H` | `A_happy` | **`A_target`** | equilibrium `occupied_population` |
|---|---|---|---|---|---|---|---|
| 0 | 0.04 | **+18.0** | 1.00 (`min(0, +18) = 0`) | 100.0 (clamped) | 1.00 | **1.00** | 144 |
| 5 (base) | 0.09 | **0.0** | 1.00 | 82.2 | 1.00 | **1.00** | **144** |
| 12 | 0.16 | **−25.2** | `1 + 1.30 × (−25.2)/100` = **0.6724** | 57.0 | 0.961 (57.0 < 60) | **0.6724** | 97 |

Detent 12 in full: `A_tax = 0.6724`; `A_happy(57.0) = 0.961`, which is *not* binding because the happiness channel has only been charged for the 3.0 points `H` sits below the reference and not for the 25.2 the tax cost; `A_stab = 1.00`; so `A_target = 0.6724`. `A_city` walks down to it with the rate multiplier `0.44`, i.e. an effective time constant of `12 / 0.44 = 27.3` game-hours — half the loss is gone by hour 19, and `occupied_population = 144 × 0.6724 = 96.8 → 97`. **Forty-seven residents, more than the `F_SOUTH` multi-district blackout above costs**, for a revenue factor of ×1.778. That is the trade doc 92 F-5 costed the ruling against: money now, a smaller city later, and the two are legible against each other on the same screen.

**`TAX_RATE_HAPPINESS_COEFF` is 360 from Wave 7** (doc 92 §20, doc 93 §E2; it was 220 when this table was first written, giving −15.4 / 0.7998 / 115). Doc 03 owns the number and the reason; what matters here is that this doc's mapping is unchanged — the coefficient produces the points, §2.10.2a spends them once, and every value at and below `TAX_RATE_BASE` is identical to what it was.

**Measured as integrated** (`tests/test_balance_gates.gd` gates 12 / 12b, seed 1337, a controlled pair — identical build plan, identical tiles, identical seed, one field different):

| game-day | detent 5 population | detent 12 population |
|---|---|---|
| 1 | 224 | 181 |
| 3 | 224 | 156 |
| 7 | 224 | **151** |
| 21 | 219 | **151** |

**−31.1 % population for +25.8 % cash** at three game-weeks ($255,276 against $202,996), diverging inside the **first** game-day. The detent-12 city settles at `H = 53.9`, which is *below* the 60 reference — `A_happy = 0.921` — and still does not bind, because `A_tax = 0.6724` is harsher. That is the `min` doing its job in the shipped sim, not just on paper.

*(At the pre-Wave-7 coefficient the same pair read 179 people and +71 % cash — −18.3 % population. The cash multiple fell because the residents the squeezed city no longer has were the ones paying the ×1.778 rate; the direction of the trade is unchanged and the size of it is now legible.)*

And on the shared strategy matrix, where doc 92 F-5 originally measured "+46 % value created for a happiness number that changed nothing else" (`tools/playtest.gd`, 21 game-days, seed 1337, coarse):

| strategy | treasury | value created | **population** | happiness |
|---|---|---|---|---|
| `balanced` | $78,704 | $878,217 | **1,342** | 74.6 |
| `tax_squeezer`, coeff 220 | $133,122 | $1,787,852 | **1,918** | 73.0 |
| `tax_squeezer`, coeff 360 | $96,249 | $1,182,823 | **1,145** | 51.6 |

*(Re-measured Wave 7 on `tests/balance_matrix.gd` — the same strategies run ONLINE on the coarse step, which is what `BalanceGateRig` fixed and what the older offline figures in this row could not see. Three seeds, 21 game-days.)*

The middle row is why Wave 7 happened: with the grid buyable, the squeezed agent converted its ×1.778 revenue into **more city**, so it led on population as well as on money and the happiness deficit was 1.6 points. At the ruled coefficient it **trails on population by 14.7 %** while still creating 35 % more value — money now, a smaller city later, on the agent a player actually resembles. `tests/test_balance_gates.gd` gate 12c holds exactly this comparison; gates 12 and 12b hold the controlled pair above, because two scripted agents earn different money and therefore build different cities, and the population column of a strategy comparison confounds the detent with the build plan. Both readings are needed, which is why there are now three gates and not two.

**Ordering.** `PopulationSystem.advance` reads the `H` of the game-hour just lived and `HappinessModel.advance` then relaxes on the aggregates population just produced (`employment_balance` is a §2.10.1 output and an §2.10.3 input). One game-hour of lag, deliberately: it cuts the cycle, it is the same on the fine and coarse paths, and every term is still a closed-form exponential in `dt_h`, so §5's "the 1 Hz and 1-game-hour paths agree exactly" survives T-1 intact.

**Worked at t0.** Every authored building has `age ≥ 36 gh` ⇒ `ramp = 1.00`; all are `active` ⇒ `STATE_OCCUPANCY = 1.00`; `city_stability = 0.9475` ⇒ `A_target = (0.9475 − 0.35)/0.50 = 1.195 → clamp 1.00`, and `A_city` is authored at 1.00.

```
occ_b (18 houses, 3 apartments) = 1.00        ⇒ occupied_population = 144  = capacity
workforce      = 144 × 0.55 = 79.2
jobs_market    = 5×6 + 1×30 + 3×2 = 66
job_fill_city  = clamp01(79.2 / 66) = clamp01(1.200) = 1.00
occ_b (5 stores, 1 office)      = 1.00        ⇒ occupancy-weighted base tax = $686/gh, unreduced
```

**Worked under the `F_SOUTH` fault.** Three game-hours in, `city_stability` has fallen to 0.9074 (§2.6) — still above the 0.85 saturation point, so `A_target` is still 1.00 and nobody leaves. Push it further, to a citywide `city_stability = 0.60` (a multi-district outage), and `A_target = (0.60 − 0.35)/0.50 = 0.50`. Six game-hours at that stability, at the default 9 % tax rate:

```
A_city = 1.00 + (0.50 − 1.00) × (1 − e^(−6/12)) = 1.00 − 0.50 × 0.3935 = 0.8033
occupied_population = 144 × 0.8033 = 115.7 → 116        (28 residents gone in six hours)
```

and doc 03 loses 20 % of residential revenue on top of every other multiplier, because `occ_b` is a factor in `R_b`. Neglect is expensive twice over, and the recovery is symmetric and slow — which is the whole point of a time constant rather than an instant recompute.

#### 2.10.3 Happiness

City happiness `H ∈ [0,100]` is a **single city-wide scalar** owned here and consumed by doc 03 as `f_happiness = clamp(1.0 + 0.50 × (H − 60)/100, 0.75, 1.25)`. It is deliberately *slow* and *aggregate*, where `stability` is fast and per-district — two signals, two timescales, no overlap in who writes them.

```
u(x) = clamp(x, −1, +1)

H_target = 60
         + 14 × u( (city_stability      − 0.85) / 0.15 )
         +  8 × u( (service_uptime_day  − 0.97) / 0.03 )
         +  8 × u( (employment_balance  − 0.85) / 0.15 )
         +  6 × u( (condition_mean      − 0.85) / 0.15 )
         + happiness_tax_delta                                  # doc 03: −(tax_rate − 0.09) × 360
H(t+dt)  = H + (clamp(H_target, 0, 100) − H) × (1 − exp(−dt_h / HAPPINESS_TAU_H (12)))
```

| input | source | definition |
|---|---|---|
| `city_stability` | this doc §2.6 | population-weighted mean of district stability |
| `service_uptime_day` | docs 04 + 05 | population-weighted mean over the trailing game-day of `0.6 × power_availability_hour(b) + 0.4 × water_service_factor_hour(b)` — the two time-weighted fractions report 98 C-37 required both docs to publish |
| `employment_balance` | this doc §2.10.1 | `1 − |workforce − jobs_market| / max(workforce, jobs_market, 1)` — punishes both unemployment and unstaffed shops |
| `condition_mean` | doc 02 | `population + jobs`-weighted mean building `condition ∈ [0,1]` (C-14 scale) |
| `happiness_tax_delta` | doc 03 §2.4 | `−(tax_rate − 0.09) × 360`; 0 at the default rate, −25.2 at 16 % |

The 60 baseline is the pivot of doc 03's `f_happiness`, so a perfectly average city is revenue-neutral. The band is `[24, 96]` before the tax term, which leaves the 0.75/1.25 clamp reachable only through the tax slider — deliberate: happiness is a *slow* lever, not a second economy.

**Worked at t0:** `city_stability 0.9475`, `service_uptime_day 1.000`, `employment_balance = 1 − |79.2 − 66| / 79.2 = 1 − 0.1667 = 0.8333`, `condition_mean 1.000`, `tax_rate 0.09`.

```
H_target = 60 + 14×u(0.647=+0.647) + 8×u(1.00→+1) + 8×u(−0.113) + 6×u(1.00→+1) + 0
         = 60 + 9.06 + 8.00 − 0.91 + 6.00 = 82.15  →  H0 authored at 82
f_happiness = 1.0 + 0.50 × (82 − 60)/100 = 1.110
```

**Worked 3 gh into the `F_SOUTH` fault:** `city_stability 0.9074`; `service_uptime_day = (21×1.000 + 3×(0.6×0.694 + 0.4×1.000)) / 24 = 0.9771` (44 of 144 residents dark for 3 hours; the tank holds water pressure up); other inputs unchanged.

```
H_target = 60 + 14×u(0.380) + 8×u(0.237) + 8×u(−0.113) + 6×u(+1) = 60 + 5.32 + 1.90 − 0.91 + 6.00 = 72.31
H(3 gh)  = 82 + (72.31 − 82) × (1 − e^(−3/12)) = 82 − 9.69 × 0.2212 = 79.86  →  79.9
f_happiness = 1.099
```

A one-feeder fault costs 2.1 happiness points and 1 % of revenue in three hours — small, cumulative, and it keeps falling for as long as the fault is open. That is the intended shape: happiness never spikes, it erodes.

### 2.11 City level and progression — absorbed per report 98 G-1 / G-4

Doc 02 proposed the population ladder and nothing owned it. Adopted here, and **RETUNED against measurement by doc 92 §19** (audit 91 D-7). `data/progression.json` — the file this section has always named, and which doc 92 §19 is the pass that finally wrote it:

| `city_level` | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
|---|---|---|---|---|---|---|---|---|
| min city population | **0** | **200** | **700** | **1,600** | **3,600** | **8,000** | **18,000** | **40,500** |
| *doc 02's original proposal* | 0 | 250 | 1,000 | 4,000 | 12,000 | 30,000 | — | — |
| `balanced` reaches it on game-day | t0 | **2** | **11** | **23** | *unfitted* | *unfitted* | *unfitted* | *unfitted* |

**Rung 7 was added Wave 22** (doc 92 §61), on §19.2's same recipe one rung
further: `18,000 × 2.25 = 40,500`. It is an APPEND and it is honest
extrapolation, labelled as such — nothing in this study reaches it by population
and nothing is meant to, because §2.14.2's level 7 is a capital exercise and the
curriculum is its route.

**The rung had to exist before the level could**, and this is the sentence to
remember: `ProgressionSystem.grant_level` clamps its argument to
`city_level_pop().size() - 1`. A curriculum with a seventh row and a ladder with
six rungs earns level 7 inside `GoalSystem`, shows the sheet complete, and
**never fires `city_level_changed` for rung 7 — so doc 03 §2.5a's $5,000,000 is
never paid.** That is this project's signature defect (a level the ladder can
reach that no data row describes) and it is closed by the row above rather than
by a special case in the clamp. Every other `city_level` consumer was walked in
report 98 §64 RR-189.

**Rung 6 was added Wave 10** (doc 92 §24.6). It is an APPEND — no rung below it
moved by a single resident, and appending above the top rung cannot un-earn a
level in any existing save. Its placement is §19.2's own recipe applied one rung
further rather than a new fit: rungs 2–5 settle at a flat 2.25× (1,600 → 3,600 is
exactly that, 3,600 → 8,000 is 2.22 after rounding to two significant figures),
so **8,000 × 2.25 = 18,000**. Like rungs 4 and 5 it is honest extrapolation and
labelled as such — the highest population this study has ever measured is 7,923
(doc 92 §22.3.1, seed 1337 at game-day 70), which clears rung 5 and not rung 6.
**Why a sixth rung exists at all is content, not curve.** Before Wave 10 city
level 5 unlocked *nothing whatsoever* and a sixth would have unlocked less; it
now unlocks doc 02 §2.14's tower tier, and §2.14.2's curriculum has a sixth row
that teaches it.

That 18,000 is **inside what this engine can represent** is measured, even though
no PLAYED city has reached it: §2.13's benchmark fixture — 1,500 buildings — settles
at **35,411 residents**, which is rung 6 with room to spare, and it is the reason
that fixture's two identity hashes move under this rung (doc 92 §24.12's A/B). What
stops a played city from getting there is doc 92 pass-3 F-11's power ceiling, not
the rung, which is the same thing that stops it reaching rungs 4 and 5.

The proposal predated every measurement in doc 92 and four of its six rungs were unreachable by anything the game can do: the fastest builder in the study peaks at 1,872 residents over 90 game-days and the competent player ends fifty game-days at 2,710, so a 12-game-day city sat at level 0 and refused 376 upgrades with `E_CITY_LEVEL`. The rungs above are placed on doc 92 §19.1's measured `balanced` population curve at game-days that roughly double; levels 4 and 5 are placed by the ~2.25× ratio the fitted rungs settle into rather than by fit, because nothing has yet produced 3,600 residents — that is doc 92 pass-3 F-11's power ceiling, and they get a real fit when the feeder verb lands.

```
city_level_reached = max{ i : city_population >= CITY_LEVEL_POP[i] }
city_level         = max(city_level, city_level_reached)      # monotone — a level is never lost
```

**Progression is monotone by design.** A disaster that halves your population must not re-lock the buildings you already own, re-lock land you have already bought, or repossess a fire engine. `city_level_max` is stored in the `progression` save section; the *displayed* level is the max, and doc 12 may show "population 610 / 700 to level 2" as a separate readout — `ProgressionSystem.next_level_threshold()` is the reader, so a retuned ladder moves the readout with it.

At t0 `city_population = 144 ⇒ city_level = 0`. Level 1 arrives at 200 residents — **56 more people: fourteen more houses, or three more apartments**, or the mix in between; against a 62 %-vacant core that is a *first-session* goal, and doc 92 §19.3 measures the competent player reaching it on game-day 2 on all three seeds. The old 250 put it on game-day 4, at the far edge of playable, and put every rung above it out of reach.

**What `city_level` gates** (this doc publishes the scalar and the event; each consumer owns its own thresholds):

| Consumer | Gate |
|---|---|
| **02 Buildings** | `E_CITY_LEVEL` — `city_level >= min_city_level(L+1)` for every upgrade; and `min_city` per archetype for placement. **Since Wave 10 that tops out at 5, not 4**: doc 02 §2.14's sixth rung opens at city level 4 for the `steady` class and 5 for the towers |
| **09 this doc** | block `min_city_level` for `PURCHASABLE` (§2.5, §2.8.2) — ring 1 at 0, SR-served ring 2 at 1, the rest of ring 2 at 2. **There is no ring 3 to gate at 4+, and there cannot be one on this board — see §2.8.3** |
| **06 Incidents & fleets** | vehicle and station-tier unlocks |
| **10 Roads** | the `road_crew` unlock |
| **12 UI** | build-card availability and the progression panel |

Events emitted: `city_level_changed{from, to}` (once, on the monotone increase) and `progression_milestone{id}`.

**Milestones** (the `progression` save section's other half; MVP set, all one-shot, all cosmetic-plus-notification):

| id | condition |
|---|---|
| `first_land_purchase` | first `land_purchased` |
| `first_block_ready` | first block reaches `READY` |
| `first_blackout_survived` | a `district_dark` district returns to `district_dark_fraction == 0` |
| `city_level_1` … `city_level_5` | `city_level_changed` to that level |
| `population_1k` / `population_10k` | `city_population` crosses the threshold |
| `first_tie_switch` | a tie switch is placed (doc 04) |

### 2.12 Lifetime stats — absorbed per report 98 G-5

The `stats` save section is **local counters only**. Network analytics are deferred past MVP and there is no `INTERNET` permission to send them with (doc 13 §2.7). Every counter is a monotone `int64` written by this doc from events other systems emit, so no system needs its own tally:

```
game_minutes_played · game_days_elapsed · offline_sessions · offline_minutes_credited
blocks_purchased · blocks_developed · dollars_spent_on_land
buildings_built · buildings_upgraded · buildings_lost
peak_population · peak_city_level · peak_treasury
incidents_opened · incidents_resolved · fires_extinguished · buildings_saved_from_fire
outage_minutes_total · outage_events · worst_outage_customers
water_shortage_minutes · tank_empty_events
storms_survived · disasters_survived
```

`peak_*` counters are maxima rather than sums, and they are the only ones that read state rather than events. The section carries `section_version` and migrates by appending new counters at 0 — never by renaming an existing one, because a lifetime counter that resets is worse than no counter.

### 2.13 The benchmark-city fixture — `tools/gen_bench_city.py` (report 98 G-7)

`tests/fixtures/bench_city.json` is doc 11's on-device performance fixture, and its failure mode is silence: if it goes stale, the render gates stop meaning anything without failing. **This doc generates it, doc 08 validates it as a BOOT file and round-trips the city it produces through the save path, doc 11 consumes it.**

> **Wording correction, 2026-08-19.** This section called the fixture a *save file* so that doc 08's migration ladder would apply to it. **Doc 08 §7 test 37's ruling settles it the other way: it is a BOOT file, not a save body**, and this section now says so throughout. The two schemas have two owners and two version counters — a boot file is `world` / `blocks` / `buildings` / roads read by `StarterCityLoader`, a save body is doc 08 §3.1's section registry with `rng_streams` and per-section versions — so feeding one to the other's loader would assert only that they disagree. The fixture's whole job is to be *booted*.

`tools/gen_bench_city.py` is the **same generator family** as `tools/gen_starter_city.py` — same road-template stamper, same parcel packer, same transformer cover solver, same invariant assertions (§7 tests 2–8 run against the fixture too) — parameterized rather than forked, so a change to the road template or the block schema cannot leave the fixture behind.

| profile | world | developed core | buildings | districts | consumer |
|---|---|---|---|---|---|
| `starter` | 7×7 | 3×3 (9 blocks) | 34 | 4 | `data/starter_city.json` (shipped) |
| `bench` *(default)* | **7×7** *(as shipped)* | **6×6 (36 blocks)** | **1,500** across L1–L5 | 12 (36 blocks ÷ 3) | doc 11 §7.4's 90 s camera path |
| `reference` | 8×8 | 6×6 | 800 | 24 | doc 08 §2.12's coarse-step cost measurement |

The `bench` profile matches doc 11's stated contents exactly: 36 developed blocks × 87 road tiles = **3,132 road tiles**, 1,500 buildings, and the ~780 streetlight *props* doc 11 places at its own art-owned density (the electrical sink is one per road tile — doc 04 — and the two counts are deliberately different and must not be conflated). 20 emergency vehicles and a level mix weighted toward L2–L3 so LOD tiers are all exercised.

**As shipped, two rows of this section moved and both are flagged.** (1) The world is **7×7**, not 8×8: `TileGrid.BLOCKS` is 7 and `StarterCityLoader` refuses anything but 49 block rows, so an 8×8 world is not reachable without a sim change nobody asked for. The 6×6 *developed core* — which is what every content figure here is sized against — is unchanged. (2) The building count is **1,500**, not ~1,100, because that is the size doc 11 §2.13's device matrix is written against (doc 91 D-8) and therefore the size the fixture has to be for the matrix to mean anything.

The generator writes the fixture in the **`data/starter_city.json` boot shape**, not as a save body, so `CitySim.boot()` and the render harnesses can load it directly (`tools/profile_sim.gd --city=…`, `tools/profile_frame.gd --city=…`). Its `schema_version` is therefore the *data-file* version this doc's §3.1 defines, and it tracks `data/starter_city.json` rather than the save ladder. **Settled 2026-08-19:** the Wave-6 flag above is resolved in doc 08's favour and against this section's original wording — `tests/test_save_migration.gd::test_37_bench_city_is_a_boot_file_that_round_trips_the_save_path` asserts the fixture's `schema_version` equals `data/starter_city.json`'s, boots it clean at 1,500 buildings, and *then* puts the booted city through `save_slot` → `load_slot` with an identical `state_hash` and zero repair notes. That second leg is the one that catches a save-schema drift, and it catches it on 1,500 buildings rather than the starter city's 35 — a stronger reading of report G-7 than "validate the file against the save registry" ever was. Regeneration is a committed step: `python3 tools/gen_bench_city.py --profile bench`, run whenever the block schema or the road template changes.

### 2.14 The goal curriculum — the ladder made visible (Wave 9)

§2.11 gives the city a level and an event. It does not give the player a
**goal**, and until Wave 9 nothing else did either: the ladder was a population
threshold nobody could see, announced by one toast on the way past. The player's
words after a Fold playtest are the finding —

> *"players know exactly what they need to accomplish to get to the next level,
> like build a certain building or do a certain task. The first five or six
> levels should be all about teaching the users exactly how to play the game."*

So each rung of §2.11's ladder now carries an **objective list**, authored in
`data/goals.json` (§8.3) and evaluated by `sim/progression/goal_system.gd`.

#### 2.14.1 The ruling — objectives ADVANCE the level, they do not gate it

```
city_level = max( level_reached(city_population),  goals.earned_level )
```

Both routes go through the one monotone writer, `ProgressionSystem.grant_level`.
The consequences are the point:

* a player who follows the sheet reaches level 1 in **18 game-hours** instead of
  two game-days, because the objective list is a checklist and the threshold is
  a wait;
* a player who never opens the sheet still climbs doc 92 §19's fitted curve, and
  so does every scripted agent in `tools/playtest.gd` — which is why the balance
  matrix still measures the ladder it was fitted on (doc 92 §22.3);
* **monotonicity is untouched.** Neither route can take a level back, and the
  MAX of two monotone functions is monotone.

The full ruling, with the alternative that was rejected, is doc 93 §G1.

#### 2.14.2 The curriculum — seven levels, one system each

> **Six since Wave 10.** It was five, and the reason was arithmetic: §2.11's
> ladder had five rungs above the founding level and a sixth would have unlocked
> nothing — every `min_city_level` in `data/buildings.json` topped out at 4 and
> every block's at 2, so a level-6 reward card would have been empty, and *a
> level whose reward card is empty is a number, not a goal* (ruling 93 §G3).
> **That test is unchanged; what changed is that the card is no longer empty.**
> Doc 02 §2.14's tower tier gates the sixth rung of `apartment`, `office`,
> `high_rise` and `data_center` at city level 5, so rung 5 pays out for the first
> time and rung 6 has somewhere to go (ruling 93 §G6). Level **0** is still doc
> 12 §2.17's tutorial, which the sheet shows as complete and which hands the
> player here on its way out.

| level | name | objectives | teaches | reward (READ, not authored) |
|---|---|---|---|---|
| **0** | Getting started | doc 12 §2.17's eleven steps | taps, a house, one emergency | — |
| **1** | Homes and power | 4 houses · 1 transformer · 170 residents | the build sheet, and the `E_UNSERVED` wall a new lot hits without copper | Apartments, Offices, L2 upgrades |
| **2** | Shops and upkeep | 2 shops · 1 upgrade · 210 residents | the commercial cards, and upgrading instead of sprawling | ring-2 land, L3 upgrades |
| **3** | The budget | 1 apartment · set the tax rate · happiness 70 · 280 residents | doc 03's slider and what it costs in people | High-rise, `road_crew`, L4 upgrades |
| **4** | When it goes wrong | 1 police station · 2 incidents resolved · 24 clean game-hours · 340 residents | coverage, the drawer, dispatch | Data centre, L5 upgrades |
| **5** | Room to grow | buy a block · develop it · 1 water pump · 400 residents | doc 09's land pipeline and doc 05's first player-built works | the growth ladder itself |
| **6** | Up, not out | 1 high-rise · take one building to level 6 · 900 residents | doc 02 §2.14's tower tier, and the power a tall building drinks | $325,000, and the last build cards |
| **7** | The whole city | **one upgrade of each of the twelve archetypes** | the city as one asset — the stations and the works you have been paying for since day one | **$5,000,000** |

> **Seven since Wave 22, and the seventh is the player's own** (doc 92 §61,
> ruling 93 §AU). *"We can even make a SEVENTH level where it's pretty much get a
> lot of buildings upgraded — get one of each type of building upgraded — and you
> get the big money when you go through the last level. That'll be five
> million."* Ruling 93 §G3 — *a level whose reward card is empty is a number, not
> a goal* — is the test this rung had to pass, and it passes on a reading the
> §G3 wave could not have made: **nothing in `data/buildings.json` unlocks at city
> level 7, and the card is not empty, because doc 12 §2.19's reward card now
> READS doc 03 §2.5a's grant.** The money is the unlock.

**Level 7's three design decisions, and where each one is written down.**

1. **All twelve archetypes count, civic and utility included.** The roster is the
   build sheet's own: `BuildController.cards()` walks `sim.catalog.archetypes()`
   with no filter, every one of the twelve has a priced upgrade ladder in
   `data/building_economy.json`, and `cmd_upgrade_building` accepts every one.
   Excluding the stations and the works would make the graduation a
   residential-and-commercial exercise, and doc 03 §2.12 has billed the player for
   `departments` and `fleet` since game-hour 1 — upgrading the station you have
   been paying for since founding is the curriculum closing its own loop.
   `data/starter_city.json` stands **ten of the twelve** up on the founding day,
   so ten rows are *upgrade what you were given*; only `high_rise` (level 6
   teaches it) and `data_center` (nothing in the curriculum has ever mentioned it)
   have to be built first. That is what makes the rung an ask rather than a wall.
2. **Twelve rows, not one clever row.** A `count the DISTINCT archetypes` kind
   would have to persist a SET per objective and §2.14.4's body writes `progress`
   as `id → int`. Twelve integer counters cost one save key each — and they read
   on the sheet as twelve ticks, which is what a checklist level wants.
3. **No `reach_population` row — the only level without one.** Level 7 is a
   CAPITAL level; the twelve rows state the ask completely and a population row
   would be a wait bolted onto a checklist. §2.11's rung 7 (40,500) is still
   underneath as the backstop and the sheet still greys it in.

**The ask, priced:** $644,370 — a data centre ($180,000) plus one L1→L2 step of
each of the twelve ($464,370, itemised in doc 92 §61.5). Doc 03 §2.5a's rung-6
grant is derived as **half** of exactly that number, which is what stops the
capstone from being prepaid.

**Every objective is a verb the player can actually perform.** That is a hard
rule, not a preference: `cmd_place_road`, `cmd_place_water_main` and
`cmd_repair_building` are shipped sim verbs with **no UI surface** (doc 92
§17.6), so their evaluator kinds exist and **no level uses them**. A curriculum
row that asks for something the UI cannot do is a wall with no door, and the
tutorial walks the player straight into it.

#### 2.14.3 Objective kinds

Each kind is a small pure evaluator in `GoalSystem`, and they come in three
shapes:

| shape | kinds | how it is measured |
|---|---|---|
| **event** | `build_archetype` · `place_grid_component` · `place_water_component` · `place_water_main` · `stamp_road_tiles` · `upgrade_building` · **`upgrade_to_level`** · **`upgrade_archetype`** · `repair_buildings` · `resolve_incidents` · `buy_block` · `develop_block` · `set_tax_rate` · **`collect_opportunities`** | counted off `SimEventBus`, from LEVEL ENTRY, on the command rather than on the thing finishing |
| **state** | `reach_population` · `reach_happiness` · `reach_stability` · `reach_treasury` | one O(1) reading per game-hour |
| **endurance** | `survive_no_abandonment` | game-hours in a row without `incident_abandoned` / `incident_failed` / `building_destroyed` |

**Cost.** Evaluation is O(events), never O(buildings): the event kinds subscribe
through `SimEventBus.observer` and consult only the ACTIVE level's handful of
rows. The state kinds are read once a game-hour off four scalars the sim already
keeps — which is the boundary of that table, and why a "power coverage ≥ 95 %"
objective is not in it until doc 04 publishes a city-wide scalar.

A counter ticks on the **command**, not on the completion: "Build 4 houses"
lands when the fourth house is committed, not two game-hours later when its
scaffolding comes down. A teaching counter that lags the tap teaches nothing.

**`collect_opportunities` is authorable and deliberately UNUSED** (Wave 15, doc
06 §2.16). It counts `opportunity_collected` — a street bounty taken — with an
empty `match_field`, so an unqualified row counts a collection of any kind
("collect 3 street opportunities", not "collect 3 crooks"); the kind-specific
reading is one authored key away (`match_field: "kind"` plus an
`opportunity_kind` on the row) and is deliberately not taken, because a row that
asks for a crook asks the player to wait for a crime the police did not answer.

**No row in `data/goals.json` uses it**, and that is a decision rather than an
omission: §2.14.2's targets are FITTED against the `curriculum` agent and held by
balance gate 21, so adding a rung is a re-measure of that arrival table and not a
data edit. Where one would fit when it is taken: **level 4**, which already
teaches the police station — *"there are still crimes it misses, and here is what
you do about them"* is the sentence the objective would be finishing. Doc 92
§35.4 item 2 ranks it, and `tests/test_street_opportunities.gd` asserts the file
stays clean of it until then, so the kind cannot drift into the curriculum
without the measurement.

**`upgrade_archetype` is the third reading of one button** (Wave 22). It counts
the same `upgrade_started_sim` event that `upgrade_building` and
`upgrade_to_level` count, filtered by the `archetype` field that
`CitySim.cmd_upgrade_building` now stamps onto it. The field is **additive** —
every existing reader asks for `sim_id`, `to_level` or `cost` — and it is stamped
at the emit site rather than looked up by the goal system, because handing
`GoalSystem` the roster so it could resolve a `sim_id` would make a per-event
evaluator O(buildings) and break this section's own cost rule. Doc 12 §2.19's
sheet renders the twelve rows it produces; `tools/ui_preview.gd`'s
`goals_capstone` state is what they were photographed in.

**`upgrade_to_level` is the one kind that filters NUMERICALLY** (Wave 10). It reads the same `upgrade_started_sim` event `upgrade_building` reads and additionally requires `to_level >= ` the row's own `to_level`. The comparison is `>=` and not `==` because doc 02 §2.14's ladder is archetype-shaped — six archetypes have a level 6 and six do not — so an equality row would refuse a player who went further and a per-archetype row would be unanswerable by a police station. It costs one extra dictionary lookup and one comparison per event, so the cost rule above still holds.

#### 2.14.4 Persistence and retroactive safety

The curriculum is a block of the `city` save section (doc 08 §2.8), and
`CitySim.SAVE_SECTION_VERSION` moves **2 → 3** for it. The body gains one key;
every other key is byte-for-byte what v2 wrote.

What a v2 save cannot carry is the ANSWER — a city played for thirty game-days
has no record of which objectives it met, because nothing was counting. Doc 08
§2.8 forbids a migrator from reading `data/`, and the answer depends on the whole
restored city as well as on `data/goals.json`, so:

1. `_v2_to_v3` **marks** the body (`goals.bootstrap = true`) and answers nothing;
2. `CitySim.restore_state` runs `GoalSystem.bootstrap` **last**, once the city is
   standing, under two rules:
   * **every level at or below the city's own level is complete** — a player at
     level 4 is never asked to build their first house;
   * **the active level starts from what the city already HAS** — the observable
     residue of the event kinds (houses standing, transformers placed, blocks
     owned). A kind with no residue starts at zero, because a city cannot be
     asked what it once did.
3. the event queue is then **emptied**. A restore is not an achievement:
   bootstrapping a level-4 city completes four levels' worth of objectives, and
   publishing those would greet a returning player with four level-up toasts for
   work they did last week.

Save → load → advance stays bit-identical with a curriculum in flight
(`tests/test_goals_system.gd`).

**Wave 22's seventh level moves NO save rung, and this is why.** The body's shape
is `{version, earned_level, done: [ids], progress: {id → int}}` — two open
collections keyed by objective id — so twelve new rows add twelve possible keys
and change no schema. `CitySim.SAVE_SECTION_VERSION` (9 as this wave forks) does not
move and doc 08's ladder is untouched. **The bootstrap's third rule turned out to be load bearing
for a second reason**: it empties the event queue, and since doc 03 §2.5a's grant
is now paid off `city_level_objectives_met` (ruling 93 §AU6), a restore that
published those events would hand a migrated level-6 city **$1,605,000** for work
it did last week. The rule was written to stop four level-up toasts; it stops
that too.

#### 2.14.5 Events

| event | payload | consumer |
|---|---|---|
| `goal_progress` | `{goal_id, level, current, target}` | doc 12 §2.19's chip pulse |
| `goal_completed` | `{goal_id, level}` | the row that just landed, pulsed once |
| `city_level_objectives_met` | `{level}` | the celebration toast |

`city_level_changed` is unchanged and still fires from `grant_level`, whichever
route earned it.

---

## 3. Data Schema

### 3.1 `data/starter_city.json`

Hand-authored content, but **emitted and validated by `tools/gen_starter_city.py`** — the script stamps the road template, places the buildings, solves the transformer cover, and asserts every invariant in §7 before writing. The script is the source of truth for the layout; the JSON is its committed output; the headless test re-runs the same assertions against the shipped file.

All tile coordinates in this file are **core-local** (add 32 for global); `blocks[].grid` is in block coords. `schema_version` here is the **data-file** version — save sections use `section_version` (§3.2, report 98 C-25); the two never share a key.

```jsonc
{
  "schema_version": 2,
  "world": { "size_blocks": [7,7], "tile_meters": 8, "block_tiles": 16,
             "city_center_tile": [56,56], "core_origin_block": [2,2], "core_size_blocks": [3,3] },

  "blocks": [                                       // × 49; the 9 core blocks are OWNED / READY
    { "id": "B_3_1", "grid": [3,1], "label": "D2",
      "terrain_class": "flat", "dev_terrain": "flat",
      "elevation_class": 2, "flood_risk": 0.18,
      "env_risk": { "flood":0.18,"wildfire":0.20,"subsidence":0.10,"pollution":0.06,"wind":0.22,"hazmat":0.03 },
      "road_access": "ARTERIAL", "arterial_connections": 2,
      "water_tiles": 0, "blocked_tiles": 0, "waterfront_edges": 0,
      "amenity_score": 0.45, "vegetation_density": 0.35, "slope_index": 0.05,
      "min_city_level": 0,                          // re-based onto the §2.11 ladder (G-1)
      "ownership_state": "PURCHASABLE", "development_state": "UNDEVELOPED",
      "district_id": null, "tags": ["tutorial_land_block"],
      "bridge_required": null, "satellite": null, "special_zone_id": null }
  ],

  "roads": [                                        // 18 entries = the whole core template
    { "axis":"x", "index":0,  "class":"AVENUE", "name":"Levee Rd", "from":0, "to":47, "half":true },
    { "axis":"z", "index":23, "class":"STREET", "from":0, "to":47 }
  ],
  "water_tiles": [[1,19],[2,19],[3,19],[4,19]],     // 15 entries

  "buildings": [                                    // × 34, all level 1
    { "id":"PLANT-1", "type":"power_facility", "level":1, "origin":[40,40], "size":[3,3],
      "block":"B_4_4", "rotation":0, "tags":[] },
    { "id":"WTR-2", "type":"water_facility", "variant":"tank", "level":1, "origin":[1,24],
      "size":[2,2], "block":"B_2_3", "rotation":0, "tags":[] }     // variant per report 98 C-35
  ],

  "power": {
    "nodes": [
      { "id":"PLANT-1","kind":"plant_gas","level":1,"terminal":[39,41] },
      { "id":"SUB-A","kind":"substation","level":1,"terminal":[32,18],"tags":["tutorial_substation"] },
      { "id":"T-04","kind":"transformer","level":2,"tile":[35,0],"feeder":"F_NORTH",
        "tags":["tutorial_transformer"] },                          // × 23: 13 L1, 9 L2, 1 L3
      { "id":"T-15","kind":"transformer","level":3,"tile":[0,20],"feeder":"F_SOUTH" }
    ],
    "lines": [
      { "id":"TL-1","kind":"transmission","class":1,"from":"PLANT-1","to":"SUB-A",
        "path":[[39,41],[39,32],[32,32],[32,18]] },
      { "id":"F_SOUTH","kind":"feeder","class":1,"overhead":true,"from":"SUB-A",
        "path":[[32,18],[32,32],[0,32]],
        "laterals":[[[7,32],[7,39]],[[23,32],[23,39]],[[32,32],[39,32],[39,39]],[[0,32],[0,20]]] }
    ],
    "tie_switches": []                              // empty at t0 — see §2.9.5
  },
  "water": {
    "nodes": [                                      // doc-05 variant nodes, co-located per building
      { "id":"WTR-1-SRC","building":"WTR-1","variant":"source","subtype":"river","level":1,"terminal":[0,20] },
      { "id":"WTR-1-TRT","building":"WTR-1","variant":"treatment","level":1,"terminal":[0,20] },
      { "id":"WTR-1-PMP","building":"WTR-1","variant":"pump","level":1,"terminal":[0,20],
        "pumps":[{"id":"P-1","state":"ok"},{"id":"P-2","state":"offline_manual","tags":["tutorial_pump"]}] },
      { "id":"WTR-2","building":"WTR-2","variant":"tank","level":1,"terminal":[0,24],
        "head_m":30, "volume_m3":108 } ],
    "mains": [ { "id":"M_TIE","path":[[23,16],[23,32]] } ],
    "hydrants": [[8,7],[24,7],[40,7],[8,23],[24,23],[40,23],[8,39],[24,39],[40,39]],
    "pressure_zones": [ { "id":"Z1" } ]
  },
  "districts": [ { "id":"D_NORTHGATE","name":"Northgate","label":"N",
                   "blocks":["B_2_2","B_3_2","B_4_2"],"color_index":0 } ],
  "population": { "attractiveness": 1.00, "happiness": 82.0,
                  "building_age_hours_default": 36 },              // §2.10 seed state
  "tags": { "tutorial_lot_a": {"kind":"tile","tile":[11,8]},
            "tutorial_lot_b": {"kind":"tile","tile":[13,8]} }
}
```

### 3.2 Save-file sections

This doc owns **six** sections of the canonical registry (report 98 §11): `world`, `districts`, `population`, `progression`, `goals`, `stats`. (`goals` is §2.14's, added in Wave 9; like the other five it rides Milestone 1's single `city` body until doc 08 §3.1's per-system split lands, and `CitySim.SAVE_SECTION_VERSION` 2 → 3 is the bump that carries it.) **Every one carries `section_version`, never `schema_version`** *(report 98 C-25 — `schema_version` exists only on doc 08's envelope)*.

```jsonc
"world": {
  "section_version": 1,
  "blocks": [                                   // only blocks differing from starter defaults
    { "id":"B_3_1", "ownership_state":"OWNED", "development_state":"GRADING",
      "phase_crew_minutes_remaining": 743, "assigned_crew_id":"CREW-02", "paused": false,
      "purchase_price": 12600, "purchased_minute": 1980,
      "road_access":"ARTERIAL", "arterial_connections": 2,
      "survey_revealed": true, "flood_depth_class": 0,
      "district_id": null, "reassign_cooldown_until_minute": 0 } ],
  "tile_overrides_rle": "…"                     // PackedByteArray, RLE, delta from the authored map
},

"districts": {
  "section_version": 1,
  "districts": [
    { "id":"D_NORTHGATE","name":"Northgate","blocks":["B_2_2","B_3_2","B_4_2"],
      "color_index":0, "power_rel_ema":0.98, "water_rel_ema":1.00,
      "stability":0.9358, "district_dark_fraction":0.00 } ],
  "city_stability": 0.9475
},

"population": {
  "section_version": 1,
  "attractiveness": 1.00,                       // A_city, §2.10.2
  "happiness": 82.0,                            // H, §2.10.3
  "occupancy": { "H-001": 1.00 },               // sparse: only buildings whose occ_b != 1.00
  "building_age_minutes": { "H-042": 120 },     // sparse: only buildings younger than 36 gh
  "service_uptime_ring": [ 1.00, 1.00 ]         // 24 hourly samples, trailing game-day
},

"progression": {
  "section_version": 1,
  "city_level": 0, "city_level_max": 0,
  "milestones": [ "first_land_purchase" ]
},

"goals": {                                      // §2.14, Wave 9
  "version": 1,
  "earned_level": 2,                            // highest level the OBJECTIVES earned
  "done": [ "l1_houses", "l1_population", "l1_transformer" ],   // sorted; a set that hashes the same twice
  "progress": { "l3_apartment": 0 }             // counted kinds only; state kinds are re-read
},

"stats": {
  "section_version": 1,
  "counters": { "game_minutes_played": 0, "blocks_purchased": 0, "outage_minutes_total": 0 }
}
```

Tile flags (uint8 bitfield): `1 BUILDABLE · 2 ROAD · 4 WATER · 8 BLOCKED · 16 OCCUPIED · 32 FLOODED · 64 UTILITY_ROW`. Only the delta from the authored map persists; the 112 × 112 grid is rebuilt at load. Districts persist their two reliability EMAs and the current `stability` because those are history, not derivable state. `population` persists sparsely — the common case is "everything at 1.00", which serializes to almost nothing.

**Migration policy.** Sections append fields with defaults; `stats.counters` appends new keys at 0 and never renames. The `districts` section split out of `world` at `section_version 1` (they were one section pre-amendment); the v0→v1 migration lifts `world.districts[]` into `districts.districts[]` and computes `city_stability` from the loaded values, so no long-running city loses a district.

---

## 4. Sim API Sketch

`sim/world/` and `sim/population/`, `RefCounted` only (constitution §3).

| Class | Root | Responsibility |
|---|---|---|
| `WorldMap` | `sim/world/` | owns blocks + `TileGrid`; adjacency, purchasability, ring/`d` computation; `tick_second()`, `tick_hour()` |
| `LandBlock` | `sim/world/` | attribute record, derived getters, development state |
| `TileGrid` | `sim/world/` | 112×112 `PackedByteArray` flags + `PackedInt32Array` building ids; stamp/query; `elev_m(tile)`, `block_of(tile)`, `road_class(tile)` |
| `DevelopmentController` | `sim/world/` | phase queue, crew requests, integer game-minute countdowns, `ctx.channels.construction_rate` accumulation |
| `DistrictRegistry` | `sim/world/` | district CRUD, auto-assignment, `recompute_fast()` / `recompute_slow()`, `apply_stability(id, d)`, `city_stability`, `district_dark` |
| `LandPriceInputs` | `sim/world/` | assembles the doc 03 input bundle for a block |
| `StarterCityLoader` | `sim/world/` | parses `data/starter_city.json` → `WorldMap`, emits building/utility spawn requests, resolves `tags` |
| **`PopulationSystem`** | `sim/population/` | `occ_b`, `job_fill_city`, `A_city`, `occupied_population`, per-district rollup |
| **`HappinessModel`** | `sim/population/` | `H`, its four inputs, the 12 gh relaxation, doc 03's tax delta |
| **`ProgressionSystem`** | `sim/population/` | `city_level` (monotone), milestones, unlock queries |
| **`StatsRecorder`** | `sim/population/` | lifetime counters, event-driven, no state reads except `peak_*` |

**Tick entry points.** `WorldMap.tick_second()` (1 Hz — development countdowns, district fast aggregates). `WorldMap.tick_hour()` (per game-hour — district slow aggregates, occupancy/job-fill/attractiveness/happiness relaxation, `city_level` check; applies 60 minutes of development countdown in one step). Development, occupancy and happiness are fully deterministic and non-stochastic, and every relaxation is a closed-form exponential in `dt_h`, so the 1 Hz and 1-game-hour paths agree exactly — which is what makes the offline coarse path free.

**Commands handled:** `preview_land_price(block_id)`, `buy_land(block_id)`, `start_development(block_id)`, `pause_development(block_id)`, `resume_development(block_id)`, `create_district(block_ids, name)`, `assign_block_to_district(block_id, district_id)`, `rename_district(district_id, name)`, `resolve_tag(tag)`.

**As shipped (Wave 1.5, audit doc 93 §B).** `buy_land` shipped on `CitySim` as **`cmd_buy_block(block_id, preview, auto_develop)`** and `start_development` as **`cmd_start_development(block_id, preview)`**; `preview_land_price` is the `preview = true` form of the first, which also quotes doc 03 §2.8's six-phase total so the purchase dialog can show the TCO. The §2.5 gate is unchanged and returns `E_UNKNOWN_BLOCK` / `E_ALREADY_OWNED` / `E_CITY_LEVEL` / `E_NOT_ADJACENT`, then `E_FUNDS`. `auto_develop` defaults **true** so one verb grows the city, but the two stay separable exactly as the §2.3 state machine says: a purchase that cannot also afford the SURVEY phase still completes, and reports `development_started: false`. **`prestige` is computed live** from the mean `land_value_index` of owned 4-neighbours at the current district stability, so shipped prices track §2.8.2's t0 sheet to within about 1 %; the prestige-free blocks (`B_0_6` among them) match it exactly.

Two phase effects reach outside the land block and therefore live in the coordinator, not in `DevelopmentController`: **`utility_corridor`** extends the nearest feeder's route to the block **centre** (no extra charge — the $9,000 phase price already bought it, and doc 03 §2.13(b)'s no-double-billing rule forbids charging twice), which is what makes the block tappable by doc 04's `cmd_place_grid_component`; and **`final_development`** sets `FLAG_BUILDABLE` on the block's non-water, non-blocked tiles, which is what §2.2's `count_buildable` gate needs to open. Road-template stamping remains doc 10's and has not shipped.

**Events emitted:** `world_loaded`, `land_price_previewed`, `land_purchased`, `land_purchase_rejected{reason}`, `development_phase_started{block, phase, crew, crew_hours}`, `development_phase_completed`, `development_paused`, `block_surveyed{risk_revealed}`, `block_ready`, `block_road_access_changed`, `block_flooded{depth_class}`, `district_created`, `district_membership_changed`, `district_aggregates_updated`, **`district_dark_changed{district_id, dark, fraction}`**, **`city_stability_changed`**, **`population_changed{occupied, capacity}`**, **`happiness_changed`**, **`city_level_changed{from, to}`**, **`progression_milestone{id}`**.

---

## 5. Cross-System Interfaces

Doc numbers below are the **canonical on-disk numbering** (report 98 Ruling Zero). This table is normative for what this doc reads and provides; where a sibling doc's §5 disagrees, that doc is stale.

| Doc | We read | We provide |
|---|---|---|
| **01 Time & ticks** | `ctx.channels.construction_rate` (**every development work unit multiplies it** — C-29), `EVERY_SECOND` / `EVERY_HOUR` / `EVERY_DAY` cadences, `ctx.catchup_index` and `OfflinePolicy.band_for()` for the coarse path, `sim_time_minutes` for building age | nothing (this doc authors no curve and no timer template) |
| **02 Buildings & construction** | footprints, `population` / `jobs` **capacity**, `condition ∈ [0,1]`, `state` + `STATE_OCCUPANCY`, `fire_load`, `power_demand_kw`, `water_demand`, `coverage_police/fire`; the §2.10 crew-hour timing model; the `water_facility` variant list | `block_of(tile)`, `district_id` of a tile, buildable/vacant tile set, parcel geometry, road-adjacency legality, tile-occupancy arbitration; **`city_level` for `E_CITY_LEVEL` and `min_city_level`**; **`occupancy[id]` / `job_fill[id]`** (G-1); land-development jobs submitted into `ConstructionQueue` (G-2) |
| **03 Economy, taxes & land** | the canonical `land_price()` (§2.7), the six `PHASE_BASE` costs + `terrain_phase_mult` (§2.8), treasury debits, `tax_rate`, `happiness_tax_delta = −(r − 0.09) × 360`, `growth_rate_multiplier = 1 − (r − 0.09) × 8.0`, **`attractiveness_tax_factor(r)` (§2.10.2a, amendment T-1)** | the full input bundle of §2.4; `dev_terrain`, `d`, `n`, `risk_index`, `prestige`, `blocks_owned`; **`occ_b` per building**, **district `stability ∈ [0,1]`**, **`city_stability`**, **city `happiness ∈ [0,100]`**, **`city_level`**. **The starter city delivers exactly $686/gh gross base tax against `STARTER_GROSS_TAX_PER_HOUR 686 ± 5 %`** |
| **04 Electrical grid** | component capacities/levels/radii, outage state, **`block_dark` per block**, `power_availability_hour(b)` | starter topology (§2.9.5) with exact tile polylines, **18 transformer sites (7 L1 / 10 L2 / 1 L3, `rated_mva` 2.25)**, **177 line tiles = 1.42 km**, 783 road tiles and 81 intersections as distributed-sink counts, `wind`/`wildfire` per block for doc 06's storm rolls, `block_of(tile)` for crew routing; **`district_dark` derived from their `block_dark`** (C-38) |
| **05 Water system** | pressure, zone state, tank level, per-variant `base_kw` / capacity / `coverage_frac`, `water_service_factor_hour(b)` | starter topology (§2.9.6) with the `source`/`treatment`/`pump`/`tank` variant split, 9 hydrant tiles, Mill Pond as the `source`, **`elev_m(tile)`** (block-flat), `is_developed(tile)`, `block_of(tile)`; `WTR-1`'s power dependency on `F_SOUTH` |
| **06 Incidents, dispatch & fleets** | `crime_index`, `fire_risk` per district, station/vehicle definitions, crew roster and rates, `destroy_allowed()` participation | **`stability ∈ [0,1]` per district** (§2.6) for `f_stab`, `city_level` for vehicle unlocks, station sites, hydrant sites, `block_of(tile)`, the land-development phase→crew-type mapping (G-2) |
| **07 Weather & Disaster Director** | storm intensity, `wind_kph`, `precip01`, `weather_build_mult` via `get_effect()` | `elevation_band ∈ {LOW,MID,HIGH}` per block (**answers their open question 8: block-granular, 128 m**), `drain_rate_mm_h` per block, `flood_risk` and the full `env_risk` profile; **`city_stability`** and `districts.apply_stability(id, d)` — they never write a city scalar directly (C-56) |
| **08 Persistence & offline** | save/load orchestration, the offline coarse-advance driver, `OfflineGuard`, `is_resync` | the five sections of §3.2, integer-minute development state and closed-form relaxations that make the coarse path exact; **`tests/fixtures/bench_city.json`, which they validate in CI** (G-7) |
| **10 Roads, routing & traffic** | road-graph construction, congestion, closure state, **`access_quality(pos) ∈ [0,1]`** — the single definition of tile-level road access (C-61) | the road tile template and **the class mapping: boundary → `AVENUE`, interior collector and player-placed → `STREET`** (C-60); 87 tiles/block, 540 AVENUE + 243 STREET tiles in the core; the widening-on-development rule; flooded-tile impassability; the intersection list; `city_level` for the road-crew unlock; **`district_profile_weights(id) -> {res,com,ind,civ}` (§2.6.1) — SHIPPED Wave 14, and until then the one row of this table that was an interface rather than a wiring (report 98 RR-69)** |
| **11 Rendering & performance** | — | block bounds as chunk bounds (chunk == land block, constitution §6), `get_block_terrain()`, terrain class + elevation for the ground mesh, `development_state` for construction-site VFX, **`block_road_access_score`** (C-61), `district_dark_fraction` for district-scale tinting; **`tests/fixtures/bench_city.json`** via `tools/gen_bench_city.py` (G-7) |
| **12 UI/UX & onboarding** | — | grid labels `A1`–`G7`, block purchase preview data, development progress, district colours/aggregates/`stability`, **population, happiness, `city_level` and progress to the next level**, milestone notifications, and the **tag registry of §2.9.7 (answers their open question 7)** |
| **13 Android integration** | — | nothing directly; all state reaches the shell through doc 08's save and doc 12's UI |

---

## 6. MVP Cut

**In the vertical slice:** the 7×7 world, 9-block core, 40 purchasable blocks · the full block attribute set including `dev_terrain` and the doc 03 input bundle · the 6-phase development state machine with crew types, fallbacks and the `construction_rate` channel · the orthogonal adjacency rule and `min_city_level` gating on the §2.11 ladder · risk hidden until SURVEY · districts with auto-assignment, rename, the spec §46 field set, the `stability` aggregate, the derived `district_dark` and the published `city_stability` · **population, occupancy, job fill, city attractiveness, happiness, `city_level` and milestones (G-1/G-4)** · **the `stats` counters (G-5)** · `data/starter_city.json` exactly as authored (18/5/3/1 + six civic/utility sites) · `elevation_band` + `drain_rate_mm_h` feeding the thunderstorm · the AVENUE/STREET road template and its widening-on-development behaviour · the tag registry · **`tools/gen_bench_city.py` and the committed `bench_city.json` fixture (G-7)**.

**Deferred:** bridges, islands, satellite and special-zone blocks · rings 3+ and world growth · player terraforming, land reclamation, block resale · manual district split/merge UI (auto-assign + rename only) · district specialisations and zoning bonuses · intra-block elevation variation · road classes beyond AVENUE/STREET (`alley` stays reserved in doc 10) · demolition of authored starter buildings · a `brownfield` `dev_terrain` key (using `forest` as the proxy, §9) · per-district happiness (one city scalar in MVP) · migration/immigration as an explicit population flow (attractiveness stands in) · network analytics on top of `stats`.

---

## 7. Test Plan

Headless: `tests/sim/world/test_world_map.gd`, `test_development.gd`, `test_districts.gd`, `test_starter_city.gd`, `tests/sim/population/test_population.gd`, `test_progression.gd`.

**Data integrity**
1. `starter_city.json` parses; exactly 49 blocks — 9 `OWNED`/`READY`, 12 `PURCHASABLE`, 28 `LOCKED`.
2. **All 34 building footprints** are in-bounds, non-overlapping, off-road, off-water, and orthogonally road-adjacent; all are `level == 1`; every footprint matches doc 02's L1 size for its archetype, **except `WTR-2`, whose 2×2 matches doc 05's `tank` variant footprint** (C-35). The manifest is exactly 18 `house` / 5 `store` / 3 `apartment` / 1 `office` plus `YARD-1`, `FIRE-1`, `POL-1`, `SUB-A`, `PLANT-1`, `WTR-1`, `WTR-2`.
3. No two same-archetype buildings are orthogonally adjacent (keeps the authored ASCII map unambiguous).
4. Road stamp yields exactly **783 road tiles, 540 `AVENUE` and 243 `STREET`**, 81 intersections in the core, 87 road tiles per block; a clean block counts `buildable_tiles == 169`, `B_2_3` counts 154; the pre-development *estimate* gives 169 and 159. **Vacant buildable lots == 1,429.**
5. Every power line and water main polyline is axis-aligned segment-by-segment and lies entirely on road tiles. Feeder tiles == 147, transmission tiles == 30, `line_km == 1.42 ± 0.01`.
6. Every building origin is within 3 tiles (Chebyshev) of a transformer; **every transformer's t0 night load is ≤ `TRANSFORMER_HEADROOM_FRAC (0.70) × capacity_kw` at its authored level, and no transformer is authored above the smallest level that satisfies it**. The fleet is exactly **13 L1 + 9 L2 + 1 L3**, `rated_mva == 2.40`.
7. Every core tile is within 12 tiles of a live water main (doc 05's `max_service_distance_tiles`) and within 12 tiles of a hydrant.
8. All 9 core blocks are 4-connected; all 4 starter districts are 4-connected and ≤ 4 blocks; every core block has exactly one district.
9. Every tag in §2.9.7 resolves to a live entity, including `tutorial_pump` → `P-2` in `state == offline_manual`.

**Economy and utility anchors** *(recomputation R-16)*
10. Starter gross base tax == **$686/gh exactly**, computed as `18×12 + 5×26 + 3×70 + 1×130`, read from `data/economy.json` at test time rather than hard-coded, and within doc 03's `STARTER_GROSS_TAX_PER_HOUR 686 ± 5 %` with **zero tolerance consumed**. Population **144**, jobs **152** (`jobs_market` 66, `jobs_civic` 86).
11. Night peak electrical load at 20:00 == **783.3 kW ± 0.5** = 460.7 building + 274.05 streetlight + 48.6 signal; per class RES 175.20 / COM 91.20 / IND 12.04 / CIV 182.25; `F_NORTH` **361.8 kW (30.1 % of feeder class 1)**, `F_SOUTH` **421.6 kW (35.1 %)**, `F_SOUTH` share of city load **53.8 %**. Channel values are read from `data/time.json`, not hard-coded, so a curve edit fails this test loudly.
12. Starter water demand == **5.56 m³/h** nameplate, **7.10 at the 07:00 peak**, **6.24 at 20:00**; supply headroom against one L1 pump ≥ 5.5× at peak. `WTR-1` site load == **132 kW** (32 + 40 + 60), `WTR-2` == **5.0 kW**.
13. `WTR-2` tank autonomy == **21.6 gh** on the daily mean, **16.9 gh** at the morning peak, and **5.4 gh** with two engines flowing — all computed as `120 m³ ÷ draw`, with `fire_flow_per_engine_m3h` read from `data/water.json`.
14. `preview_land_price("B_3_1")` at `city_level 0`, `blocks_owned 9`, standard difficulty ⇒ **12,600**. `B_5_5` ⇒ 7,600. `B_0_6` ⇒ 6,700. After buying 5 more blocks (`blocks_owned 14`, escalation 1.30) `B_2_1` ⇒ 15,100.

**Purchase rules**
15. At t0 exactly 12 blocks are `PURCHASABLE` **at `city_level 0`**; the 4 ring-1 diagonals are `LOCKED` on adjacency. Buying `B_2_1` makes `B_1_1` purchasable and `B_2_0` still `LOCKED` on `min_city_level 2`.
16. `buy_land` rejects with `"not_adjacent"` on a diagonal-only neighbour, `"insufficient_funds"` when broke, `"city_level"` when under-levelled.
17. `env_risk_index` reads as a ±0.20 band before SURVEY and exactly afterwards; `block_surveyed` fires once.

**Development** *(C-29)*
18. `B_3_1` with one `construction_crew` in clear weather totals **5,856 crew-minutes (97.6 crew-hours)** of work and **7,284 wall game-minutes (121.39 gh)** against `construction_rate` mean 0.804; with `heavy_equipment_crew` + `road_crew` available, **3,600 crew-minutes / 4,478 wall gm (74.63 gh)**; with `first_block_time_mult 0.48`, **2,811 crew-minutes / 3,496 wall gm (58.27 gh)**. In steady rain the one-crew case is **142.82 gh**. The channel mean is read from `data/time.json`; hard-coding 0.804 fails the test.
19. **Channel coupling guard:** running the same block with `construction_rate` pinned to 1.0 yields exactly 97.6 gh, and pinned to 0.60 (the night floor) yields 162.67 gh — proving the channel is multiplied and not ignored, which is the whole content of C-29.
20. Phases run strictly in order; each holds exactly one crew (`max_crews_per_project == 1` for all six); `pause_development` mid-phase is rejected, between phases succeeds and frees the crew.
21. **Determinism:** advancing a mid-development block 6 game-hours via 21,600 `tick_second()` calls and via 6 `tick_hour()` calls yields identical `phase_crew_minutes_remaining` and identical event sequences.
22. On `ROAD_INSTALL` completion the shared boundary `AVENUE` with a developed neighbour widens 1→2 tiles, both neighbours' `road_access` rises to ≥ `STUB`, and doc 10 receives one road-graph rebuild request.
23. On `FINAL_DEVELOPMENT` the block auto-joins the adjacent district with fewest blocks and matching terrain; creates a new district when every adjacent district already holds 4 blocks.

**Districts and stability**
24. `recompute_slow()` on the starter city gives city totals pop **144** / jobs **152**, and `D_DOWNTOWN` **24 / 60**.
25. t0 stability: `D_DOWNTOWN` == `D_MILLPOND` == `D_FOUNDRY` == **0.9740 ± 0.0005**; `D_NORTHGATE` == **0.9358 ± 0.0005**; `D_DOWNTOWN` under the §2.6 fault inputs == **0.7335 ± 0.0005**.
26. **`city_stability` == 0.9475 ± 0.0005** at t0 and **0.9074 ± 0.0005** with `D_DOWNTOWN` alone at 0.7335 — proving the aggregate is **population**-weighted (an unweighted mean would give 0.9645 and 0.9043 respectively, and the test asserts it does *not*).
27. **`district_dark` (C-38):** with doc 04 flagging `block_dark` on `B_3_3` and `B_4_3`, `D_DOWNTOWN.district_dark_fraction == 1.00` and `district_dark == true`; with only `B_2_4` dark, `D_MILLPOND.district_dark_fraction == 0.50` and `district_dark == false` (below the 0.60 threshold); a district whose member blocks all have zero population falls back to the unweighted mean rather than dividing by zero.
28. `assign_block_to_district` rejects non-contiguous targets, 4-block targets, and calls inside `reassign_cooldown_until_minute`.

**Population, happiness and progression** *(G-1 / G-4)*
29. At t0 `occ_b == 1.00` for every authored building; `occupied_population == 144`; `job_fill_city == 1.00` because `workforce 79.2 > jobs_market 66`; occupancy-weighted base tax == **$686/gh**.
30. Adding one `office` L1 (30 market jobs) drops `job_fill_city` to `clamp01(79.2 / 96) == 0.825`, and every commercial `occ_b` with it — the "build housing" pressure is a number.
31. A fresh building's `occ_b` follows `0.35 + 0.65·age/36`, reaching exactly 1.00 at 36 gh and never exceeding it.
32. With `city_stability` pinned to 0.60, `A_city` after 6 gh == **0.8033 ± 0.0005** and `occupied_population` == **116**; restoring stability to 0.95 returns `A_city` to ≥ 0.99 within 36 gh. Civic/utility buildings stay at `occ_b == STATE_OCCUPANCY[state]` throughout.
33. `H` at t0 == **82.15 ± 0.05**; 3 gh into the §2.10.3 fault case == **79.86 ± 0.05**; at `tax_rate 0.16` the steady-state target drops by exactly **25.2** points via doc 03's `happiness_tax_delta`. `f_happiness` handed to doc 03 == `1.0 + 0.50 × (H − 60)/100`, clamped [0.75, 1.25].
34. `city_level` at t0 == **0**; crossing 250 population raises it to 1 and emits `city_level_changed{0,1}` exactly once; **dropping back to 200 population leaves `city_level == 1`** (monotone), and `city_level_max` round-trips through a save.
35. Every `min_city_level` in `starter_city.json` is on the §2.11 ladder (0–6 since Wave 10; the authored rows still use 0–2 and §2.8.3 says why there is no ring 3 to gate higher) and the 12 t0-purchasable blocks are all reachable at `city_level 0`.
36. `stats.counters` are monotone: a 24-game-hour run with two blackouts and one land purchase increments `outage_events` by 2, `blocks_purchased` by 1, and never decrements anything; `peak_population` tracks the maximum, not the current.

**Save and fixtures**
37. Save → load → save round-trips all five sections (`world`, `districts`, `population`, `progression`, `stats`) byte-identically after developing two blocks, re-assigning one district and crossing a city level.
38. **Every section carries `section_version` and none carries `schema_version`** *(C-25)* — asserted by key inspection, not by parsing, so a copy-paste regression fails.
39. A v0 save (single combined `world` section) loads through the migration ladder into split `world` + `districts` with no block or district loss and a recomputed `city_stability`.
40. **`tools/gen_bench_city.py --profile bench` regenerates `tests/fixtures/bench_city.json` deterministically** (byte-identical on a re-run with the same seed), the fixture passes tests 2–8 with the `bench` profile's counts, and it carries the **boot-file** `schema_version` — `data/starter_city.json`'s, asserted equal by `tests/test_bench_city.gd`, not the save envelope's *(§2.13's 2026-08-19 wording correction; G-7; doc 08 test 37 and doc 11 test 26 are the other two legs of this tripwire)*.

---

## 8. Tunables

Only constants **owned by this doc**. Land price constants live in `data/economy.json` (doc 03); component ratings in `data/power.json` / `data/water.json`; building stats in `data/buildings.json`; diurnal curves in `data/time.json` (doc 01 is the only curve store, C-32/C-33).

### 8.1 `data/world.json`

```json
{
  "schema_version": 2,
  "world": {
    "tile_meters": 8, "block_tiles": 16, "size_blocks": [7, 7],
    "core_origin_block": [2, 2], "core_size_blocks": [3, 3],
    "city_center_tile": [56, 56],
    "road_area_fraction": 0.34, "reference_buildable_tiles": 169,
    "grid_label_columns": "ABCDEFG", "grid_label_row_offset": 1
  },
  "elevation_meters_by_class": [0, 5, 12, 22, 34],
  "elevation_band_by_class": ["LOW", "LOW", "MID", "HIGH", "HIGH"],
  "env_risk_weights": {
    "flood": 0.35, "wildfire": 0.15, "subsidence": 0.15,
    "pollution": 0.20, "wind": 0.10, "hazmat": 0.05
  },
  "land_value_index": { "base": 0.25, "amenity_weight": 0.30,
                        "safety_weight": 0.25, "stability_weight": 0.20 },
  "block_road_access_score": { "NONE": 0.00, "STUB": 0.35, "EDGE": 0.70, "ARTERIAL": 1.00 },
  "_renamed": "road_access_score -> block_road_access_score (report 98 C-61). Tile-level road access is doc 10's access_quality(pos); this key is a block development attribute and the two must never be conflated.",
  "flood": {
    "drain_base_mm_h": 25.0, "drain_flood_coeff": 0.80, "drain_elevation_coeff": 0.50,
    "impassable_at_depth_class": 2, "depth_classes": 3
  },
  "development": {
    "phase_order": ["SURVEY","CLEARING","GRADING","ROAD_INSTALL","UTILITY_CORRIDOR","FINAL_DEVELOPMENT"],
    "crew_hours":  { "SURVEY": 4, "CLEARING": 8, "GRADING": 12,
                     "ROAD_INSTALL": 14, "UTILITY_CORRIDOR": 16, "FINAL_DEVELOPMENT": 6 },
    "primary_crew": { "SURVEY": "construction_crew", "CLEARING": "heavy_equipment_crew",
                      "GRADING": "heavy_equipment_crew", "ROAD_INSTALL": "road_crew",
                      "UTILITY_CORRIDOR": "heavy_equipment_crew", "FINAL_DEVELOPMENT": "construction_crew" },
    "fallback_time_mult": {
      "SURVEY":            { "road_crew": 1.0, "heavy_equipment_crew": 1.0, "crane_crew": 1.0 },
      "CLEARING":          { "construction_crew": 1.4 },
      "GRADING":           { "construction_crew": 1.6 },
      "ROAD_INSTALL":      { "construction_crew": 1.8 },
      "UTILITY_CORRIDOR":  { "road_crew": 1.3, "construction_crew": 2.0 },
      "FINAL_DEVELOPMENT": { "road_crew": 1.0, "heavy_equipment_crew": 1.0, "crane_crew": 1.0 }
    },
    "work_units_multiply_construction_rate": true,
    "_c29": "Every work unit multiplies ctx.channels.construction_rate (24-h mean 0.804, night floor 0.60) per report 98 C-29. Authored crew-hours are WORK, not wall time.",
    "first_block_time_mult": 0.48,
    "_first_block_retune": "0.60 -> 0.48 (C-29): 97.6 crew-h x 0.48 = 46.85 crew-h / 0.804 = 58.27 gh wall time, preserving the one-session-plus-one-offline-gap beat that 0.60 delivered against the un-channelled figure.",
    "pause_allowed_mid_phase": false,
    "risk_hidden_until_survey": true, "pre_survey_risk_band": 0.20,
    "placement_requires_ready": true
  },
  "terrain_defaults": {
    "vegetation_density": { "flat": 0.35, "waterfront": 0.45, "hills": 0.70, "industrial_edge": 0.20 },
    "slope_index":        { "flat": 0.05, "waterfront": 0.10, "hills_low": 0.45,
                            "hills_high": 0.70, "industrial_edge": 0.10 },
    "amenity_score":      { "river": 0.75, "marsh": 0.35, "ridge": 0.80, "hills_low": 0.65,
                            "farmland": 0.45, "flats": 0.35, "flat_other": 0.40, "industrial_edge": 0.10 },
    "dev_terrain_map":    { "flat": "flat", "flats_floodplain": "gentle", "river": "gentle",
                            "marsh": "marsh", "hills_low": "hilly", "hills_high": "steep",
                            "industrial_edge": "forest" }
  },
  "env_profiles": {
    "waterfront":      { "wildfire": 0.05, "subsidence": 0.35, "pollution": 0.20, "wind": 0.25, "hazmat": 0.05 },
    "flat_upland":     { "wildfire": 0.20, "subsidence": 0.10, "pollution": 0.06, "wind": 0.22, "hazmat": 0.03 },
    "flat_floodplain": { "wildfire": 0.10, "subsidence": 0.30, "pollution": 0.12, "wind": 0.20, "hazmat": 0.05 },
    "hills":           { "wildfire": 0.45, "subsidence": 0.20, "pollution": 0.04, "wind": 0.45, "hazmat": 0.02 },
    "industrial_edge": { "wildfire": 0.30, "subsidence": 0.15, "pollution": 0.70, "wind": 0.20, "hazmat": 0.60 }
  },
  "districts": {
    "min_blocks": 1, "max_blocks": 4,
    "reassign_cooldown_game_hours": 24,
    "reliability_ema_halflife_game_hours": 6,
    "auto_assign_prefers_same_terrain": true,
    "workforce_fraction_of_population": 0.55,
    "stability_weights": { "power": 0.30, "water": 0.20, "crime": 0.20,
                           "road": 0.15, "employment": 0.10, "fire": 0.05 },
    "district_dark_threshold": 0.60,
    "district_dark_weight": "population",
    "_c38": "district_dark is the population-weighted aggregate of doc 04's per-block block_dark; unweighted mean is the zero-population fallback.",
    "city_stability_weight": "population",
    "_c56": "city_stability = population-weighted mean of district stability, on [0,1], published by this doc. Doc 03 reads it as f_stability = 0.25 + 0.75*S^0.70 with S already in [0,1]."
  },
  "roads": {
    "boundary_arterial_tiles_per_side": 1,
    "interior_collector_block_local_index": 7,
    "widen_boundary_on_neighbour_development": true,
    "boundary_class": "AVENUE",
    "interior_class": "STREET",
    "player_placed_default_class": "STREET",
    "_c60": "This doc owns the template; doc 10 owns the class semantics. 87 road tiles per block; 540 AVENUE + 243 STREET in the 48x48 core."
  },
  "starter": {
    "manifest": { "house": 18, "store": 5, "apartment": 3, "office": 1,
                  "construction_yard": 1, "fire_station": 1, "police_station": 1,
                  "substation": 1, "power_facility": 1, "water_facility": 2 },
    "target_gross_tax_per_hour": 686,
    "target_population": 144, "target_jobs": 152,
    "target_jobs_market": 66, "target_jobs_civic": 86,
    "building_nameplate_kw": 402.0,
    "night_peak_kw": 783.3,
    "night_peak_hour": 20,
    "feeder_night_kw": { "F_NORTH": 361.8, "F_SOUTH": 421.6 },
    "water_demand_m3h": 5.56,
    "water_peak_m3h": 7.10, "water_peak_hour": 7,
    "tank_autonomy_gh_mean": 21.6, "tank_autonomy_gh_peak": 16.9, "tank_autonomy_gh_two_engines": 5.4,
    "vacant_buildable_tiles": 1429,
    "transformer_headroom_frac": 0.70,
    "transformer_levels": { "L1": 13, "L2": 9, "L3": 1 },
    "transformer_rated_mva_total": 2.40,
    "line_tiles": { "feeder": 147, "transmission": 30 }, "line_km": 1.42,
    "hydrant_effective_radius_tiles": 12,
    "t0_city_stability": 0.9475, "t0_happiness": 82.0, "t0_city_level": 0
  }
}
```

**Deleted from `data/world.json`:** `road_access_score` (renamed `block_road_access_score`, C-61) · `transformer_overload_threshold_kw: 35` (superseded by `transformer_headroom_frac 0.70`, which is the same rule expressed so it holds at every transformer level). A reader looking for tile-level road access looks at **doc 10's `access_quality(pos)`**; for transformer capacities, **doc 04's `transformer.capacity_kw`**.

### 8.2 `data/progression.json` — new, owned here (report 98 G-1 / G-4 / G-5)

> **Shipped state (doc 92 §19, Wave 6).** The file now exists, and it carries the
> `city_level_population_thresholds` block and nothing else. Report 98 named this
> file and no pass ever wrote it, so the ladder lived as a `const` in
> `sim/population/progression_system.gd` and was the one balance number in the
> game that could not be retuned without a code edit — which is audit 91 D-7.
> The `population`, `happiness`, `milestones`, `stats_counters` and `bench_city`
> blocks below are still authored-but-unshipped: their consumers hold their own
> constants, and moving them is the job of whoever next touches those systems.
> **Do not add a second copy of the ladder anywhere** —
> `ProgressionSystem.CITY_LEVEL_POP_FALLBACK` is a missing-file degrade, gated
> equal by `tests/test_balance_gates.gd::test_gate_20_*`, not a mirror.

```json
{
  "schema_version": 1,
  "city_level_population_thresholds": [0, 200, 700, 1600, 3600, 8000, 18000, 40500],
  "_source": "Adopted from doc 02's proposal (report 98 G-1), RETUNED against doc 92 §19's measured curves; doc 02's copy is read-only.",
  "city_level_monotone": true,
  "population": {
    "workforce_fraction": 0.55,
    "occupancy_ramp_hours": 36,
    "occupancy_ramp_floor": 0.35,
    "_ramp": "occ = clamp(0.35 + 0.65*age_h/36, 0.35, 1.00) — doc 03 §2.2's stated behaviour, implemented here.",
    "attract_tau_game_hours": 12,
    "attract_stability_floor": 0.35,
    "attract_stability_span": 0.50,
    "attract_min": 0.25, "attract_max": 1.00,
    "civic_archetypes_always_staffed": ["police_station","fire_station","power_facility",
                                        "substation","water_facility","construction_yard"],
    "market_archetypes": ["store","office","apartment","high_rise","data_center"]
  },
  "happiness": {
    "baseline": 60.0,
    "tau_game_hours": 12,
    "weights": { "city_stability": 14.0, "service_uptime_day": 8.0,
                 "employment_balance": 8.0, "condition_mean": 6.0 },
    "norms":   { "city_stability": [0.85, 0.15], "service_uptime_day": [0.97, 0.03],
                 "employment_balance": [0.85, 0.15], "condition_mean": [0.85, 0.15] },
    "_norms_note": "[centre, span]; each term contributes weight * clamp((x - centre)/span, -1, +1).",
    "service_uptime_power_weight": 0.60, "service_uptime_water_weight": 0.40,
    "service_uptime_window_hours": 24,
    "min": 0.0, "max": 100.0
  },
  "milestones": ["first_land_purchase","first_block_ready","first_blackout_survived",
                 "city_level_1","city_level_2","city_level_3","city_level_4","city_level_5",
                 "population_1k","population_10k","first_tie_switch"],
  "stats_counters": [
    "game_minutes_played","game_days_elapsed","offline_sessions","offline_minutes_credited",
    "blocks_purchased","blocks_developed","dollars_spent_on_land",
    "buildings_built","buildings_upgraded","buildings_lost",
    "peak_population","peak_city_level","peak_treasury",
    "incidents_opened","incidents_resolved","fires_extinguished","buildings_saved_from_fire",
    "outage_minutes_total","outage_events","worst_outage_customers",
    "water_shortage_minutes","tank_empty_events","storms_survived","disasters_survived"
  ],
  "bench_city": {
    "profiles": {
      "starter":   { "size_blocks": [7,7], "core_blocks": [3,3], "buildings": 34,   "districts": 4 },
      "bench":     { "size_blocks": [7,7], "core_blocks": [6,6], "buildings": 1500, "districts": 12 },
      "reference": { "size_blocks": [8,8], "core_blocks": [6,6], "buildings": 800,  "districts": 24 }
    },
    "default_profile": "bench",
    "output": "tests/fixtures/bench_city.json"
  }
}
```

**§2.10 population constants live in code**, beside the relaxation they belong to, not in `data/world.json`: `WORKFORCE_FRACTION 0.55`, `OCCUPANCY_RAMP_HOURS 36`, `ATTRACT_TAU_H 12`, `HAPPINESS_TAU_H 12`, and T-1's `ATTRACT_FLOOR 0.25` / `ATTRACT_HAPPINESS_REF 60` / `ATTRACT_HAPPINESS_PULL 1.30` (`sim/population/`). T-1's **tax-side** coefficient is doc 03's, in `data/economy.json → tax.TAX_RATE_ATTRACT_PULL`, because it is a price on the tax slider and doc 03 is the tax authority; it is authored to the same 1.30 as the happiness-side pull because both act on happiness points, and neither reads the other — a retune of one is a retune of one.

Constants read from elsewhere and **never restated here**: `happiness_tax_delta`, `growth_rate_multiplier` and `attractiveness_tax_factor` coefficients (doc 03 §2.2 / §2.4), `HAPPY_SLOPE` / `f_happiness` clamps (doc 03), `STATE_OCCUPANCY` (doc 02 §2.12), `construction_rate` (doc 01 `data/time.json`), transformer capacities and streetlight/signal kW (doc 04 `data/power.json`), `fire_flow_per_engine_m3h` and every tank/pump rating (doc 05 `data/water.json`).

### 8.3 `data/goals.json` — new, owned here (§2.14, Wave 9)

The curriculum, and nothing else. One row per rung of §2.11's ladder above the
founding level, in play order; every objective is a `{kind, target}` pair plus
whatever that kind needs to identify itself.

```json
{
  "schema_version": 1,
  "levels": [
    {
      "level": 1,
      "title_key": "ui_level_1_title",
      "intent_key": "ui_level_1_intent",
      "teaches_key": "ui_level_1_teaches",
      "objectives": [
        {"id": "l1_houses", "kind": "build_archetype", "archetype": "house",
         "target": 4, "text_key": "ui_goal_l1_houses"},
        {"id": "l1_transformer", "kind": "place_grid_component",
         "kind_id": "transformer", "target": 1, "text_key": "ui_goal_l1_transformer"},
        {"id": "l1_population", "kind": "reach_population",
         "target": 170, "text_key": "ui_goal_l1_population"}
      ]
    },
    {
      "level": 7,
      "title_key": "ui_level_7_title",
      "intent_key": "ui_level_7_intent",
      "teaches_key": "ui_level_7_teaches",
      "objectives": [
        {"id": "l7_house", "kind": "upgrade_archetype", "archetype": "house",
         "target": 1, "text_key": "ui_goal_l7_house"}
        // … eleven more, one per archetype in data/buildings.json
      ]
    }
  ]
}
```

**A row carries its own prose** — `_added`, `_archetype_scope`, `_the_ask` on
level 7 — for the same reason every other data file in this project does: the
number is checkable from the file that holds it, and a reader who finds the row
before they find §2.14.2 still learns why it says what it says.

| field | meaning |
|---|---|
| `level` | the §2.11 rung this list earns. Rows are sorted ascending at parse. |
| `id` | unique across the whole file — it is the save key and the event payload |
| `kind` | one of §2.14.3's evaluator kinds. **An unknown kind is DROPPED at parse**, not fatal: a curriculum that will not load must never cost a city. `tests/test_goals_system.gd` asserts authored count == parsed count, so a typo is loud in the suite rather than silent in the game. |
| `archetype` / `kind_id` | what a `build_archetype` / component kind matches against. `kind_id` and not `kind`, because a row's `kind` is already its objective kind. |
| `target` | the number the counter has to reach. Inclusive. |
| `*_key` | `data/strings.en.json` keys (G-8). The objective text takes `{target}`, so a retune of the number retunes the sentence. |

**Rules for editing it.**

* **Only verbs the player can perform** (§2.14.2). Adding a `stamp_road_tiles`
  row before doc 12 ships a road surface is a level nobody can finish.
* **A retune of a target is a balance change** and belongs with a measurement:
  doc 92 §22's `curriculum` agent is the instrument, and
  `tests/test_balance_gates.gd::test_gate_21_*` is the gate.
* **Objective ids are permanent.** They are save keys; renaming one silently
  resets that objective for every city that had completed it.
* **The file may be empty.** No rows means no curriculum, which is exactly the
  game that shipped before Wave 9 — the population ladder alone.

---

## 9. Conflicts & Open Questions

### Conflicts with the constitution

**None.** 16×16 blocks, chunk == block, 8 m tiles, integer game-minute timers, injected clock, all tunables in `data/`, `RefCounted`-only sim classes, population aggregate-per-building (§8) — all as locked. Two clarifications, not deviations:

1. Constitution §6 says "3×3 developed + surrounding purchasable ring (exact layout in doc 09)". This doc fixes it at **two** rings (40 blocks, 7×7 world). Dropping to one ring means deleting ring 2 from the data; nothing else changes.
2. Constitution §4 lists no cadence for construction/development or for population. This doc runs development on the **1 Hz** cadence with integer game-minute state, and population/happiness/progression on the **per-game-hour** cadence with closed-form exponential relaxations, so the 1-game-hour offline path is exact in both.

### Conflicts with sibling docs — resolved by report 98

Six of the seven conflicts this section used to raise are **closed by rulings and applied above**. They are listed here with their disposition rather than deleted, so the audit trail survives:

1. **~~Utility upkeep ~25× apart; the starter city is insolvent~~** — **CLOSED by C-12.** Doc 03's expense *formula* is authoritative and doc 04's flat `upkeep_per_gh` column is deleted. This doc's job is to supply the inventory, which it now does exactly: `plant_capacity_mw 8.0`, `rated_mva 6.0` (substation) + **2.25** (18 transformers, doc 92 F-4), **`line_km 1.42`**, all at `condition 1.0`. The ruling's sanity check landed at ≈$73/gh against $32 assumed — 2.3×, not 25×.
2. **~~$686 is unreachable with doc 03's own mix~~** — **CLOSED by C-10 + C-11**, and the root cause was mine: I evaluated the mix against doc 02's tax rows, which C-10 deleted. Against doc 03's rows, `18×12 + 5×26 + 3×70 + 1×130 = 686` exactly. The 28/8/6/1 rebuild is withdrawn (§2.9).
3. **~~Doc 03's pacing table assumes blocks this world cannot contain~~** — **CLOSED by C-18.** The 7×7 world stands (it is sized for the vertical slice and for doc 11's chunk budgets); doc 03 rewrites its worked example E and S5 beat against `B_0_6` (A7), marsh, d = 3, ERI 0.443 ⇒ **$6,700**, which is this doc's actual cheapest block. 9×9 is a Phase 2 option.
4. **~~Archetype naming and the flat 60 kW `water_facility`~~** — **CLOSED by C-30 + C-35.** `power_facility` is doc 02's building shell and `plant_gas` is doc 04's component kind; both names are correct at their own layer. `water_facility` now carries a `variant` field, and the gravity tank draws **5.0 kW**, not 60 — applied throughout §2.9.6.
5. **~~Doc 03 assigns phase durations to a construction doc that does not exist~~** — **CLOSED by G-2's three-way split.** Doc 06 owns crews as dispatchable units, doc 02 owns the project record and progress, and **this doc keeps the land-development phase→crew-type mapping** (§2.3) by explicit ruling rather than by default.
6. **~~Doc 04's stale numbering~~** — **CLOSED by Ruling Zero.** The on-disk filenames are canonical; doc 04's §5.1/§5.8 references to "doc 02" and "doc 12" both mean this doc, and every interface they name is provided in §5.
7. **`dev_terrain = forest` for industrial edge is still a proxy.** Doc 03's 8-way terrain table has no brownfield key, and `forest` is the only one whose shape (cheap land, clearing-dominant cost) matches contaminated industrial land. **Still open as a request to doc 03:** add `brownfield` to `development.terrain_phase_mult` with clearing ≈ 2.2, grading ≈ 1.3, `T_factor` ≈ 0.85. Nothing in this doc breaks without it; six blocks are simply priced as forest.

### New cross-doc notes raised by this amendment — ALL RESOLVED IN ROUND 2

These were *findings*, not disagreements — each was a number a sibling doc projected before this doc recomputed it. **All three were corrected in the Round 2 amendment wave (report 98 §14); they are retained here with their disposition, not as live requests.** RR-18 marks them closed.

- ~~**Doc 04 §7 test 24** expects "14 × transformer L1 + 9 × transformer L2, 110 feeder tiles, `rated_mva 6.0 + 2.05`, `line_km 0.88`"~~ — **RESOLVED (RR-6).** Doc 04 test 24's `E_grid` expectation was restated onto this doc's real inventory: **13 L1 + 9 L2 + 1 L3 = `rated_mva 6.0 + 2.40`, 147 feeder + 30 transmission tiles = `line_km` 1.42**, and doc 03 re-ran `E_grid` on 1.42 km (≈ $74.9/gh). The L3 rationale (`WTR-1`'s three co-located variant nodes at 132 kW, §2.9.5) stands unchanged.
- ~~**Doc 04 §2.13** cites "the C-11 starter city's 508 kW building load"~~ — **RESOLVED (RR-10).** Doc 04 §2.13 now cites this doc's R-16 results: nameplate **402.0 kW** and this doc's published night peak **783.3 kW**; the stale pre-C-11 28/8/6/1 figure of 508 kW is gone. RR-18 additionally annotates doc 04's C-12 changelog row with the $74.9 correction.
- ~~**Doc 05 §2.13 and report 98 C-34** quote this doc's post-rescale water demand as **8.2 m³/h**~~ — **RESOLVED (RR-11).** Doc 05 now states starter demand as **5.56 m³/h against 40 m³/h of L1 supply, 7.2× headroom**, matching §2.9.4; the 8.2 figure (`51.1 / 6.25 = 8.176`, the old manifest rescaled without C-11's smaller mix) is retired.

### Open questions for the overseer

1. **World size.** 7×7 (896 m across) is sized for the vertical slice. C-18 kept it and moved doc 03's cheap-block beat to the real $6,700 floor, so nothing is broken — but 9×9 remains the Phase 2 option if land pricing wants more spread. Confirm 7×7 for MVP.
2. **Development time.** The tutorial block is now **58.3 gh** with `first_block_time_mult 0.48`, and later blocks are **74.6–142.8 gh** of wall time at 1 real minute per game-hour. C-29 fixed the arithmetic; it did not rule on whether that cadence is *right*. Is land development a within-session activity (as tuned) or should it be a multi-game-day, offline-progress item (×3–5)?
3. **Placement before `READY`.** I still forbid building until all six phases finish. The alternative — allow placement after `ROAD_INSTALL`, with buildings sitting unpowered and unwatered until `UTILITY_CORRIDOR` completes — is more interesting and creates more UI edge cases. Which?
4. **District player agency.** MVP gives auto-assignment plus rename only. Manual merge/split is a genuinely interesting lever now that `city_stability` is population-weighted — a player could redraw districts to move the aggregate. The 24 gh cooldown exists precisely to blunt that. Pull manual redraw into MVP, or leave it deferred?
5. **Half-AVENUE widening.** A boundary road growing from 1 to 2 tiles when a neighbour develops is a good visual beat but mutates the tile grid under doc 10's live road graph and doc 11's chunk meshes. Confirm both can absorb a mid-game edit, or I will author boundary AVENUEs at 2 tiles from the start and leave the outer tile unpaved.
6. **Tank autonomy is now 16.9–21.6 game-hours, not 2.3** *(§2.9.6)*. The old figure was a unit error, and correcting it removes the "night-time feeder fault becomes a water emergency before morning" beat as a *timer*. The coupling survives — two engines on a fire cut the buffer to **5.4 gh** and pull hydrant pressure down for every subsequent engine — but the drama now lives in the fire, not the clock. **Confirm that is the intended reading**, or ask doc 05 to lower the `tank` L1 capacity anchor (this doc will not change the topology to force it).
7. **Happiness at t0 is 82, giving doc 03 `f_happiness = 1.110`** *(§2.10.3)*. Doc 03 §2.12's pre-amendment starter table assumed an aggregate multiplier of 0.90 on $686 base ⇒ $617; with `f_stability 0.972 × f_happiness 1.110 = 1.079` the same base yields **$740/gh** before tariffs. **The cross-doc half of this is RESOLVED (RR-6):** doc 03's starter ledger was re-run in Round 2 with this doc's owned t0 factors (`0.972 × 1.110 = 1.079`) in place of the assumed 0.90 aggregate, so the number has been fed in and nothing is outstanding against doc 03. What remains open for the overseer is only the *taste* call — if a lower starting multiplier is wanted, the honest lever is the `happiness.norms` centres in `data/progression.json` (raise `city_stability` centre 0.85 → 0.95 and t0 lands at 76), not a fudge in the revenue chain.
8. **Civic jobs excluded from the job market** *(§2.10.1)*. Police, fire, plant, substation, water works and yard headcount are city-staffed and always filled, so `jobs_market` at t0 is 66 rather than 152. Without that split the starter city reports every shop half-staffed on turn one. Confirm the split, or accept a job-fill haircut on doc 03's anchor.

---

## 10. Amendments applied (report 98)

| Ruling | What changed in this doc |
|---|---|
| **Ruling Zero** | Doc numbering restated in the header against the on-disk filenames; §5's cross-reference table rebuilt and extended with doc 01 (the `construction_rate` channel) and doc 13; §9 conflict 6 (doc 04's stale numbering) closed. |
| **C-11** | Starter manifest **reverted to 18 house / 5 store / 3 apartment / 1 office L1 + the six civic/utility sites** (34 buildings, was 50). Road template, block geometry, utility topology and tags unchanged. Gross base tax **$692 → $686/gh exactly**; population **256 → 144**; jobs **176 → 152**; ASCII map, per-block table, district table and vacant-lot count (1,399 → **1,429**) all regenerated. |
| **C-13** | Building power and water totals re-derived from doc 02's regenerated `k_dem` columns: nameplate **402.0 kW** and **5.56 m³/h**. |
| **C-25** | Save sections renamed `schema_version` → **`section_version`**, on all five sections this doc now owns; data files keep `schema_version`. New test 38 asserts it by key inspection. |
| **C-29** | Every development work unit now multiplies `ctx.channels.construction_rate`; §2.3's timing model, phase table and worked example restated in wall time (**97.6 crew-hours → 121.39 gh**); `first_block_time_mult` **0.60 → 0.48** ⇒ **58.27 gh**; test 18 recomputed and new test 19 added as the channel-coupling guard. |
| **C-32** | Night peak recomputed against doc 01's **normalized** channels at 20:00 (RES 1.46 / COM 1.14 / IND 1.0033 / CIV 0.9592 / streetlight 1.00), per demand class, with doc 04's archetype→class map. **831 → 783.3 kW.** |
| **C-34** | Water rescaled to `1 WU ≡ 1 m³/h`: starter demand **51.1 WU/gh → 5.56 m³/h**, tank autonomy **2.3 gh → 21.6 / 16.9 / 5.4 gh** (mean / peak / two engines), and the old figure identified as a mixed-scale unit error rather than a design choice. |
| **C-35** | `WTR-1` modelled as three co-located doc-05 variant nodes (`source` 32 kW + `treatment` 40 kW + `pump` 60 kW = **132 kW**) with `P-2` as a standby pump; `WTR-2` becomes a `tank` at **5.0 kW** and doc 05's 2×2 footprint. `T-15` rises to **L3**, `T-18` falls to **L1**. |
| **C-38** | **`district_dark` derived here** as the population-weighted aggregate of doc 04's per-block `block_dark`, with a 0.60 threshold, a continuous `district_dark_fraction` published alongside, and an unweighted-mean fallback for zero-population districts. New test 27. |
| **C-56** | **`city_stability` published** as the population-weighted mean of district stability on [0,1] (**0.9475** at t0, **0.9074** under the `F_SOUTH` fault); doc 03's consumption restated as `f_stability = 0.25 + 0.75·S^0.70`; doc 07 writes only through `districts.apply_stability()`. New test 26 proves the weighting. |
| **C-60** | Road classes named: **boundary AVENUE, interior collector and player-placed STREET**; 540 AVENUE + 243 STREET tiles counted in the core; `data/starter_city.json` road entries and `data/world.json` `roads` block updated; doc 02's `E_AVENUE` gate confirmed never to block the tutorial. |
| **C-61** | `road_access_score` renamed **`block_road_access_score`** in §2.2, §2.6, §8 and the doc-11 interface, with an explicit note that tile-level access is doc 10's `access_quality(pos)`. |
| **G-1** | Doc **retitled *Map, Land, Districts, Population & Stability***; absorbed population, occupancy, job fill, city attractiveness, happiness and `city_level` as new §2.10–§2.11; new code root `sim/population/` with four classes; new save sections `population` and `progression`; `city_level_population_thresholds [0, 250, 1000, 4000, 12000, 30000]` adopted verbatim into new `data/progression.json`; block `min_city_level` re-based onto that ladder (all 40 rows). |
| **G-4** | Progression owned here: monotone `city_level`, `city_level_max`, an 11-entry milestone set, `city_level_changed` / `progression_milestone` events. |
| **G-5** | `stats` section owned as **local counters only** (§2.12), 23 monotone counters, append-only migration, no network analytics. |
| **G-7** | **`tools/gen_bench_city.py`** specified as the same generator family as `tools/gen_starter_city.py`, with three profiles (`starter` / `bench` / `reference`); emits `tests/fixtures/bench_city.json` ~~as a save file so doc 08's ladder applies~~ **as a BOOT file** *(corrected 2026-08-19 by doc 08 §7 test 37's ruling; see §2.13)*; new test 40 as this doc's leg of the three-way tripwire. |
| **R-16** | Full recomputation shown with arithmetic in §2.9.4–§2.9.6: manifest, tax anchor, population, jobs, per-class night peak, feeder split, water demand at three hours of the day, tank autonomy in four scenarios, transformer fleet and line inventory, four district stability values and `city_stability`. Tests 10–14 and 24–26 carry the new expectations. |

### Wave 4 (overseer ruling — the tax–growth coupling)

| Ruling | What changed in this doc |
|---|---|
| **T-1** | **New §2.10.2a: `A_target` becomes a function of stability AND happiness AND tax burden.** `A_target = min(A_stab(S), A_happy(H), A_tax(Δ_tax))`, with `A_happy(H) = clamp(1 + 1.30 × min(0, H − 60)/100, 0.25, 1.00)` and `A_tax(Δ) = clamp(1 + TAX_RATE_ATTRACT_PULL (1.30, doc 03) × min(0, Δ)/100, 0.25, 1.00)`. **`A_stab` is this doc's published formula verbatim**, so §2.10.2's t0 (`A_target = 1.00`, 144 people) and `F_SOUTH` (`S = 0.60 → 0.50`, 144 → 116 in six hours) worked values are unchanged, and so is the founding ledger (`+$336.50/gh`, gate 1). The composition is `min` and not a product: `Δ_tax` is already a term of `H_target` (§2.10.3), so a product would bill the same discontent twice; `min` bills it once through whichever channel is harsher, and the tax rate is read exactly once in the whole coupling (by `happiness_tax_delta`, doc 03). §8 gains a "these constants live in code" paragraph naming the three new ones and pointing at doc 03 for the tax-side pull; §5's doc 03 row gains `attractiveness_tax_factor(r)` and its `growth_rate_multiplier` coefficient is corrected 3.5 → 8.0 (doc 92 pass-2 F-5 moved it and this doc still quoted the old value). **What it fixes:** doc 92 F-5's ruling had no bite — `growth_rate_multiplier` scales `(A_target − A_city)`, which is zero for any city sitting at the saturated ceiling, so the top detent cost a healthy city literally zero people. Measured after T-1, controlled pair, seed 1337: **−20.3 % population for +69.6 % cash at 21 game-days, diverging inside the first game-day.** New gate `test_gate_12b_tax_squeezing_trails_on_population`; gate 12's `assert_eq(healthy_max, healthy_base)` — written to fail loudly on this day — becomes the divergence assertion it was waiting for. |

### Round 3 (report 98 §15)

| Ruling | What changed in this doc |
|---|---|
| **RR-18** | **Housekeeping only — no numeric, tunable or test change.** §9's three "new cross-doc notes" were still written in the present tense as live requests against sibling docs; all three had already been fixed in the Round 2 wave, so each is now struck through and marked resolved with a one-line pointer: doc 04 test 24's transformer/line expectation → **RR-6** (13 L1 + 9 L2 + 1 L3, `rated_mva 6.0 + 2.40`, `line_km 1.42`, `E_grid` ≈ $74.9/gh); doc 04 §2.13's 508 kW → **RR-10** (restated to this doc's 402.0 kW nameplate and 783.3 kW night peak); doc 05's 8.2 m³/h → **RR-11** (restated to 5.56 m³/h against 40 m³/h, 7.2× headroom). §9 open question 7's claim that "doc 03 is re-running that whole table under R-04 anyway" is likewise marked resolved by **RR-6** (the ledger was re-run with `f_stability 0.972 × f_happiness 1.110 = 1.079`); only the overseer's taste call on the starting multiplier stays open. §7 tests and §8 tunables are unaffected — the notes were prose about *other* docs' numbers, and every figure they cite is already this doc's own published R-16 value. |
