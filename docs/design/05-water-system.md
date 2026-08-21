# 05 — Water System Simulation

**Status:** AMENDED per `98-consistency-report.md` (rulings C-06, C-16, C-33, C-34, C-35, C-36, C-37, C-46; recomputations R-09, R-10; **Round 2: RR-11**, with RR-6 consumed). Complies with `docs/design/00-constitution.md` (LOCKED). Implements spec §14, §26 (Water Overlay), §34 (cascades), §43 (MVP).
**Owner scope:** water source → treatment → pumping → storage → mains → pressure zones → per-tile hydrant pressure, water demand *decomposition and routing* (magnitude is doc 02's), water failures, water crews/repair, water overlay data, the per-variant `water_facility` numbers, `data/water.json`, save section `"water"`.
**Does not own:** any currency figure (doc 03 — sole currency authority, report 98 C-07), per-building water demand *magnitude* (doc 02), the diurnal demand curves (doc 01, C-33), backup-generator fuel and refuelling (doc 04, C-36), the `water_main_break` roll and its pressure escalation (doc 06, C-46), weather effect channels (doc 07, C-57), building footprint of the shell (doc 02, C-30).
**Doc numbering:** the on-disk filenames are canonical (report 98 **Ruling Zero**). 01 time & tick scheduler · 02 buildings, upgrades & construction · 03 economy, taxes, land & difficulty · 04 electrical grid · **05 this doc — water** · 06 incidents, dispatch & emergency fleets · 07 weather & Disaster Director · 08 persistence, offline & notification policy · 09 map, land, districts, population & stability, starter city · 10 roads, routing & traffic · 11 rendering & performance · 12 UI/UX · 13 Android integration.
**Units:** volume `m³`, flow `m³/h` (game-hour, per constitution §7), head/elevation `m`, power `kW`, time game-minutes (int64) / game-hours (float `dt_h`). **`1 WU ≡ 1 m³/h`** (C-34) — the two names are interchangeable and doc 02's `Water WU/gh` column is read directly as m³/h. **No dollar figure is authored in this document.**

---

## 1. Overview & Goals

Water is the second physical utility graph (constitution §8: *"Utilities are graphs with capacity/load/condition, not coverage percentages"*). It exists to do four jobs in the core loop:

1. **Be a consumer of the grid.** Pumps and treatment draw kW from doc 04. Losing power loses water *after a delay* — the tank buffer. This is the single most legible cascade in the game (spec §4 Pillar 1, §14.4: *"Water depends on electricity unless backup systems are present"*).
2. **Be a supplier to fire.** Every tile exposes a `hydrant_pressure_ratio` ∈ [0,1.2] that doc 06 turns into its suppression multiplier. Fire also *consumes* water, so a big fire in a weak zone drains the tank that was keeping the zone alive — the cascade closes a loop.
3. **Be a growth gate.** Buildings can't upgrade without headroom (spec §9.4). Water demand rises with population, jobs and process load, and after the C-13 correction it rises **2.45× per level** for the `standard` class — faster than tax — so growth forces infrastructure investment (Pillar 5).
4. **Be repairable under pressure.** Main breaks, pump failures, freeze damage and contamination generate incidents that compete with fire/police for finite crews (spec §15).

**Non-goals.** No fluid dynamics, no Hardy-Cross / head-loss network solve, no sewage (spec §52), no per-pipe friction. The model is a **per-zone mass balance plus a scalar pressure factor**, evaluated at the utilities cadence **`EVERY_TICK` = 15 game-seconds = 1/240 game-hour** (a *game-time* cadence, equal to 4 Hz only at 1× speed — constitution §4 as amended by report 98 C-02), and identically at **dt = 1.0 game-hour** during offline catch-up. Everything expensive (zone partitioning, per-tile factors) is recomputed only on **topology change**, never per tick.

**Success test for this doc:** a player who loses a substation should be able to say, before it happens, "that will drop pump 2, my tank there holds about four hours, and my hydrants in the north zone will be at 60% if a fire starts."

---

## 2. Mechanics

### 2.1 The graph

Nodes (`WaterNode`) and edges (`WaterEdge`, called *mains*).

Every powered node kind is a **`water_facility` variant** (report 98 C-35). Doc 02 owns the archetype shell — footprint of the reference variant, build/upgrade crew-hours, jobs, condition/decay, fire, crime, the state machine and the variant list — and **this doc owns every per-variant number: `base_kw`, capacity, storage volume, `coverage_frac`, head, and the per-variant footprint of the four non-reference variants** (§8). Placement is `place_building{type: "water_facility", variant: "tank"}`.

| `variant` | Role | Needs power? | Key stats (this doc, §8) |
|---|---|---|---|
| `source` | Raw intake — `subtype: river` (MVP) or `well` (post-MVP) | Yes (small) | `yield_m3h`, `base_kw`, `raw_quality` |
| `treatment` | Makes raw water potable; gate for contamination | Yes | `throughput_m3h`, `base_kw`, |
| `pump` | Pushes water into zones; the grid-dependent heart. **Reference variant** — doc 02's shell table is generated for it | **Yes** (or backup) | `rated_flow_m3h`, `base_kw`, `head_m` |
| `tank` | Buffer + gravity head | Trivially (telemetry, mixers) | `capacity_m3`, `volume_m3`, `max_inflow_m3h`, `max_outflow_m3h`, `head_m`, `base_kw` |
| `booster` | Adds head for high-elevation zones (post-MVP) | Yes (small) | `head_bonus_m`, `boost_flow_m3h`, `base_kw` |

`junction` (tee/valve vault) is **not** a `water_facility` variant — it is a topology-only node created implicitly by `place_main`, carries no level, no power and no cost.

Every node carries: `id`, `variant`, `tile` (Vector2i), `level` (1–5), `condition` ∈ [0,1], `state` ∈ {`ok`,`degraded`,`failed`,`offline_manual`}, `built_at_minutes`.

Edges (mains) carry: `id`, `a`, `b` (node ids), `path` (PackedVector2Array of tiles — mains occupy tiles, constitution §6), `tier` ∈ {`service`,`trunk`,`arterial`}, `capacity_m3h`, `condition`, `state` ∈ {`ok`,`broken`,`isolated`}, `insulation` (0–2, freeze protection), `flow_m3h` (last tick, for overlay).

Hydrants are **implicit**: any tile within `hydrant_reach_tiles` of a live main has a hydrant. Explicit hydrant placement is deferred (§6).

### 2.2 Pressure zones (derived, never authored) — the C-06 model

*(Report 98 **C-06**: constitution §8 forbids coverage-percentage models for utilities. Doc 02's `pressure_radius_tiles` column is **deleted** from `data/buildings.json`; a reader looking for water coverage looks here, at the zone graph. Nothing in this document assigns a service percentage to a radius.)*

A **pressure zone** is a connected component of the *live* main graph (edges not `broken`/`isolated`) that contains ≥1 supply node (`pump` or `tank`). Components with no supply node become zones too, flagged `dead: true` (P = 0).

Tile→zone assignment: multi-source BFS over the tile grid seeded from every live main tile, cost = Chebyshev tile steps, cutoff `max_service_distance_tiles = 12`. A tile keeps the zone of the cheapest seed; tiles beyond the cutoff are **unserved** (`zone_id = -1`, P = 0).

> **Why the two tile distances are legal under C-06.** `hydrant_reach_tiles` and `max_service_distance_tiles` are *physical attachment distances to a real graph edge* — the same category the ruling explicitly permits for doc 04's transformer `service_radius_tiles` — not a coverage percentage. A tile 5 tiles from a main is not "70% covered"; it is connected to a specific zone whose pressure is computed by mass balance, and it goes to zero the instant that zone's supply does. Remove every main and every tile in the city is unserved, which a radius model can never express.

`rebuild_zones()` runs only when: a main/node is built, removed, breaks, is isolated, repaired, or terrain changes. Cost is one BFS over the developed tile set (≈25k tiles at 100 land blocks) — target < 8 ms, run once, never per tick. Results cached per land block as `PackedInt32Array zone_of_tile[256]` and `PackedByteArray tile_factor_q[256]` (quantized ×255).

### 2.3 Per-tile static factor

```
prox(tile)  = 1.0                                   if d <= hydrant_reach_tiles (2)
            = clamp(1.0 - 0.10 * (d - 2), 0.0, 1.0) if d <= 12
            = 0.0                                   otherwise
              where d = tile distance to nearest live main tile

head_z      = max(head_m of live supply nodes in z) + Σ booster.head_bonus_m in z
elev(tile)  = clamp(1.0 - 0.015 * max(0.0, elev_m(tile) - head_z), 0.30, 1.0)

tile_factor(tile) = prox(tile) * elev(tile)          # cached, recomputed on topology/head change
```

`elev_m(tile)` comes from doc 09. A tank at 30 m head serving tiles at 60 m gives `1 - 0.015*30 = 0.55` — a visible reason to buy a booster (+25 m → 0.925) or build the tank on high ground.

### 2.4 Demand aggregation — doc 02 owns the magnitude, doc 01 owns the curves (C-33, C-34)

**Deleted from this doc and from `data/water.json`** *(report 98 C-33)*: the `residential_hourly` and `commercial_hourly` 24-entry arrays. The diurnal store is `data/time.json` and nothing else. A reader looking for the curves looks at **doc 01 §2.6**, channels `water_demand_residential` (24-h mean 0.997, the renamed `water_demand`) and `water_demand_commercial` (24-h mean 0.999, populated from this doc's deleted commercial array).

**Also deleted** *(C-34 hygiene — these were double-counting doc 02 and doc 07)*: `idle_demand_frac` (doc 02's `STATE_DEMAND[state]` already derates unpowered / abandoned / under-construction buildings) and the whole `weather_demand_mult` table (doc 07's `weather.get_effect("water_mult")` is authoritative for all five weather multipliers per C-57, and doc 02 has already applied it to the number it publishes).

**What doc 02 publishes, once per tick, per building** (doc 02 §2.5):

```
W_b = water_demand(archetype, level) × STATE_DEMAND[state] × weather.get_effect("water_mult")     [m³/h]
```

**What this doc does with it.** `W_b` is a single scalar, but the three parts of a building's water use follow different clocks: showers follow the residential curve, tills and taps follow the commercial curve, and process load (cooling, boilers, racks) is flat. This doc therefore owns only the **split**, never the magnitude — a per-archetype triple of shares that sums to exactly 1.0 (§8 `demand_split`, the surviving form of the per-archetype `process_demand` the ruling told this doc to keep):

```
res_b  = W_b * demand_split[archetype].res
com_b  = W_b * demand_split[archetype].com
proc_b = W_b * demand_split[archetype].proc          res + com + proc == 1.000 by loader assertion
```

The aggregator keeps three cached sums per zone — `res_base`, `com_base`, `proc_base` — recomputed **event-driven** (on build / upgrade / state change / destruction), never per tick.

Per tick, per zone (cheap — O(zones)):

```
D_build = ( res_base  * ctx.channels.water_demand_residential
          + com_base  * ctx.channels.water_demand_commercial
          + proc_base )                                     * restriction_mult
D       = D_build + fire_draw_z + leak_z
```

- `restriction_mult` = 0.75 while the player policy `water_restrictions` is active (§2.11); 1.00 otherwise.
- `fire_draw_z` = `fire_flow_per_engine_m3h (8.0)` × engines currently flowing in the zone, registered by doc 06. *(60 → 8.0 is the C-34 rescale: `60 × 0.1333 = 7.998`.)*
- `leak_z` = Σ over broken mains in zone of `capacity_m3h * leak_frac_of_capacity (0.25) * severity`.

**Derivation of `demand_split` (audit trail).** Each row is `(pop × 0.020, jobs × 0.012, process_native × WU_SCALE 0.1333)` at L1, normalized to 1.000 — i.e. the same three quantities the old §2.4 summed, expressed as shares so that doc 02's column is the only magnitude in the project. The two per-capita anchors survive as documentation constants only: `RES_PER_CAPITA_M3H = 0.020`, `JOB_PER_CAPITA_M3H = 0.012`.

| archetype | pop×0.020 | jobs×0.012 | proc×0.1333 | total | **res / com / proc shares** |
|---|---|---|---|---|---|
| house | 4×0.020 = 0.080 | 0 | 0 | 0.080 | **1.00 / 0.00 / 0.00** |
| apartment | 24×0.020 = 0.480 | 2×0.012 = 0.024 | 0.30×0.1333 = 0.040 | 0.544 | **0.88 / 0.05 / 0.07** |
| store | 0 | 6×0.012 = 0.072 | 0.50×0.1333 = 0.067 | 0.139 | **0.00 / 0.55 / 0.45** |
| office | 0 | 30×0.012 = 0.360 | 1.00×0.1333 = 0.133 | 0.493 | **0.00 / 0.73 / 0.27** |
| high_rise | 60×0.020 = 1.200 | 15×0.012 = 0.180 | 2.00×0.1333 = 0.267 | 1.647 | **0.73 / 0.11 / 0.16** |
| data_center | 0 | 12×0.012 = 0.144 | 40.0×0.1333 = 5.332 | 5.476 | **0.00 / 0.03 / 0.97** |
| police_station | 0 | 12×0.012 = 0.144 | 1.00×0.1333 = 0.133 | 0.277 | **0.00 / 0.52 / 0.48** |
| fire_station | 0 | 14×0.012 = 0.168 | 2.50×0.1333 = 0.333 | 0.501 | **0.00 / 0.34 / 0.66** |
| power_facility | 0 | 20×0.012 = 0.240 | 25.0×0.1333 = 3.333 | 3.573 | **0.00 / 0.07 / 0.93** |
| substation | 0 | 0 | — | 0 | **0.00 / 0.00 / 1.00** *(doc 02 magnitude is 0)* |
| water_facility | 0 | 0 | — | 0 | **0.00 / 0.00 / 1.00** *(doc 02 magnitude is 0)* |
| construction_yard | 0 | 16×0.012 = 0.192 | 2.00×0.1333 = 0.267 | 0.459 | **0.00 / 0.42 / 0.58** |

Five post-MVP archetypes keep authored shares against the day doc 02 adds them: `factory` 0.00/0.10/0.90, `warehouse` 0.00/0.55/0.45, `hospital` 0.35/0.25/0.40, `school` 0.00/0.45/0.55, `stadium` 0.20/0.30/0.50 (with `stadium_event_process_mult 4.0` applied to the proc share during an event).

**Sanity anchor (post-rescale).** 184,291 citizens (spec §40.3 dashboard) → `184,291 × 0.020 ≈ 3,686 m³/h` residential ≈ 88,000 m³/day, i.e. ~480 L/person/day including commercial. Real-world plausible. Against the rescaled ladder that metropolis needs `3,686 / 1,441 ≈ 2.6` L5 pumps plus commercial and process load — roughly four to five L5 stations, which is the right number of visible strategic objects for a city that size.

**The C-34 anchor, verified:** one L1 `pump` at **40.0 m³/h** ÷ **0.020 m³/h per resident** = **2,000 residents**, and against doc 02's column `40.0 / 0.08 = 500` L1 houses = `500 × 4` = **2,000 residents**. Both readings agree exactly, which is the ruling's stated target.

**Starter-city anchor** *(report 98 **RR-11**; the totals are doc 09's — ⟨owner: doc 09 §2.9.4⟩, quoted here, never authored here)*. The starter manifest is C-11's reverted mix — 18 house / 5 store / 3 apartment / 1 office (all L1) plus the six civic/utility buildings — and against doc 02's post-C-34 water column it draws:

```
18 × 0.08  house              = 1.44
 3 × 0.48  apartment          = 1.44
 5 × 0.13  store              = 0.65
 1 × 0.32  office             = 0.32
 1 × 0.19  police_station     = 0.19
 1 × 0.40  fire_station       = 0.40
 1 × 0.96  power_facility     = 0.96
 1 × 0.16  construction_yard  = 0.16
 1 × substation + 2 × water_facility (doc 02 magnitude 0)  = 0.00
                                        TOTAL              = 5.56 m³/h
```

Against the starter city's single L1 duty `pump` at **40.0 m³/h**: `40.0 / 5.56 = 7.194` → **7.2× headroom** on the 24-hour mean, and `40.0 / 7.10 = 5.63 →` **5.6×** at doc 09's 07:00 morning peak of 7.10 m³/h (upstream is looser still: source `107 / 7.10 = 15.1×`, treatment `80.0 / 7.10 = 11.3×`).

Two independent cross-checks that the number is right: the per-capita anchor gives `144 residents × 0.020 = 2.88 m³/h` residential, which is exactly the house + apartment rows above (`1.44 + 1.44`); and `144 / 2,000 = 7.2 %` of one L1 facility's residential capacity.

*(The **8.2 m³/h / 4.9×** figure this doc used to carry is withdrawn — see §2.13.)*

### 2.5 Supply chain availability

Upstream capacity is resolved on topology change, not per tick:

```
for each pump p:
    upstream_cap(p) = min( Σ live source.yield_m3h reachable upstream,
                           Σ live treatment.throughput_m3h reachable upstream )
    # shared upstream is split among pumps in proportion to rated_flow_m3h
    share(p) = upstream_cap_group * rated_flow(p) / Σ rated_flow(group)
```

Per tick, each supply node's flow:

```
cond_factor(n)  = 0.5 + 0.5 * condition(n)                       # failed node: 0
power_frac(n)   = effective_power_fraction(n)                    # §2.6
running(n)      = power_frac >= pump_trip_fraction (0.35) and state != failed and restart_timer == 0
node_flow(p)    = running ? min(rated_flow * power_frac * cond_factor, share(p)) : 0.0

S_raw(z) = Σ node_flow(p) for pumps in z
S(z)     = min(S_raw(z), feed_capacity(z))
feed_capacity(z) = Σ capacity_m3h of live mains directly incident to supply nodes of z
```

`feed_capacity` is the **simplified min-cut**: an over-large pump behind a thin main is throttled, which is the whole reason to buy trunk mains — without any flow solver. After the rescale the bite is sharp and legible: an L3 pump (240 m³/h) behind a single `service` main (53.5) delivers 53.5. See worked example F.

### 2.6 Power dependency (doc 04 interface) and backup coverage (C-36)

Doc 04 models every powered water node as a building sink with `priority_class = CRITICAL`, `backup_capable = true`, and `base_kw` from §8's per-variant tables. Water reads power **only** through doc 04's two published functions (it never touches feeders or transformers):

```
power.is_powered(node_id) -> bool
power.power_output_multiplier(node_id) -> float   # 1.0 lit | coverage_frac on backup | 0.0 dark

effective_power_fraction(n) = power.power_output_multiplier(n)
```

**`base_kw` is a table, not a formula** (§8). The generating rule is recorded so the tables can be regenerated: `base_kw(variant, L) = kw_per_m3h[variant] × capacity(variant, L)`, with `kw_per_m3h` = **1.50** pump · **0.50** treatment · **0.30** river intake · **0.75** well · **1.50** booster (against `boost_flow_m3h`), and the `tank` anchored directly at **5.0 kW** (gravity storage draws telemetry, mixing and cathodic-protection load only — roughly a twelfth of a pump, which is the number C-35 called for when it rejected doc 02's flat 60 kW for every node kind).

**This reproduces doc 02's amended kW column exactly**, which is the arithmetic proof that the two tables are now one table: `1.50 × 40 = 60`, `1.50 × 98 = 147 → 145`, `1.50 × 240 = 360`, `1.50 × 588 = 882 → 880`, `1.50 × 1441 = 2161.5 → 2160` — doc 02's `water_facility` row is `60 / 145 / 360 / 880 / 2160` (C-34: "adopts doc 02's kW column"). ✔

**Backup coverage — this doc owns `coverage_frac`, doc 04 owns the fuel** *(report 98 C-36)*:

```
coverage_frac[level] = [ —, 0.60, 0.70, 0.85, 1.00 ]                       # published to doc 04
backup_kw(variant, L) = round_kw( coverage_frac[L] × base_kw(variant, L) ) # §8, published to doc 04
kw_required(node)     = base_kw(variant, level)                            # published to doc 04
```

Doc 04's previously hard-coded `coverage_frac["water_pump_station"] = 1.00` is replaced by this table. A module exists only at facility level ≥ 2; at L5 a node is fully backed.

**Deleted from this doc and from `data/water.json`** *(C-36 — one fuel model, one owner)*: `fuel_l_per_kwh`, `fuel_price_per_l`, `fuel_capacity_l`, `backup_start_minutes`, the `fuel burn` and `start delay` formulas, the `refuel_backup` command, the `auto_refuel_backup` policy flag, the `backup.fuel_l` / `backup.start_timer_min` save fields and the `water_backup_started` / `water_backup_fuel_out` events. A reader looking for generator fuel, runtime, start delay or refuelling looks at **doc 04 §2.10 `backup`**; the price of the diesel is doc 03's `$95/MWh`. This doc's input to that model is exactly three numbers per node: `kw_required`, `backup_kw`, `coverage_frac`.

```
effective_power_fraction = doc 04's power_output_multiplier(node)     # 1.0 | coverage_frac | 0.0
```

If `effective_power_fraction < pump_trip_fraction (0.35)` the pump trips: flow 0 and a `pump_restart_minutes = 5` lockout after power returns (prevents flicker-driven oscillation and reads as real equipment). The trip threshold and the restart lockout are water equipment behaviour and stay here.

Doc 04 sheds whole feeders, so intermediate values of `power_output_multiplier` come from **backup coverage**, not partial grid supply. Water still treats it as a fraction: a pump on a 60 %-coverage generator moves 60 % of rated flow.

### 2.7 Tank drain / refill — exact math

Per tick, per zone, after `D` and `S` are known:

```
if S >= D:
    delivered = D
    surplus   = S - D
    for each tank t in z (proportional to free space):
        inflow_t = min( surplus * freespace_t / Σ freespace,
                        t.max_inflow_m3h,
                        (t.capacity_m3 - t.volume_m3) / dt_h )
        t.volume_m3 += inflow_t * dt_h
else:
    need = D - S
    for each tank t in z (proportional to available volume):
        out_t = min( need * t.volume_m3 / Σ volume,
                     t.max_outflow_m3h,
                     t.volume_m3 / dt_h )
    draw      = Σ out_t
    delivered = S + draw
    t.volume_m3 -= out_t * dt_h        (clamped >= 0)
```

`t.volume_m3 / dt_h` and the free-space clamp make the integration exact at **both** dt = 1/240 h and dt = 1.0 h (offline), with no overshoot. Volumes are stored as `float`, clamped to `[0, capacity]` every tick.

**Buffer readout for UI/overlay:**

```
buffer_hours(z) = Σ volume_m3 / max(D - S, 0.001)     # ∞ (shown as "—") when S >= D
```

### 2.8 Pressure factor — doc 06's tiered delta wins (C-46)

```
ratio(z)      = delivered / max(D, 0.001)                          # 0..1
head_factor(z)= 1.0                                    if no tanks in z, or level_frac >= tank_low_frac (0.15)
              = 0.40 + 0.60 * (level_frac / 0.15)      if level_frac < 0.15
                where level_frac = Σvolume / Σcapacity
contam_pen    = 0.0    # contamination never reduces pressure — it is a quality event (§2.10)

break_pen(z)  = min( Σ over active breaks in z of break_penalty(break), 0.50 )

break_penalty(break) = |zone_pressure_delta(tier)|        if doc 06 owns the break   ← ALWAYS in MVP
                     = break_pressure_penalty_fallback (0.12) * severity   otherwise ← fallback only

P_target(z)   = clamp( pow(clamp(ratio,0,1), pressure_curve_exponent (1.3)) * head_factor - break_pen, 0.0, 1.0 )
P(z)          += (P_target - P(z)) * min(1.0, dt_h / pressure_tau_h (0.05))
```

*(Report 98 **C-46**: doc 06 owns the `water_main_break` incident and its tiered `zone_pressure_delta` = **−0.15 / −0.35 / −0.60 / −0.80** at tiers 1–4. That table **wins**. This doc's flat `0.12 × severity` is retained under the explicit name `break_pressure_penalty_fallback` and fires **only** for a broken segment with no owning doc-06 incident — which in MVP is the empty set, and in practice only a debug/standalone harness. It is not deleted because `WaterSystem` must remain runnable and testable without an incident system attached.)*

The 3-game-minute smoothing time constant models pipe storage and, critically, prevents the fire↔pressure feedback loop from oscillating at the tick cadence. At dt = 1.0 h (offline) the factor saturates to 1.0 and `P = P_target` immediately — correct for coarse steps.

**Per-tile output (the thing everyone else consumes):**

```
P_tile(tile) = P(zone_of_tile[tile]) * tile_factor(tile)      # 0 for unserved tiles

# Doc 06 consumes a ratio that may exceed 1.0 (a strong system suppresses faster):
overpressure(z)  = 1.0 + overpressure_bonus_max (0.20)
                       * clamp((S(z)/max(D(z),ε) - 1.0) / 0.5, 0, 1)
                       * (tanks_in_z ? clamp((level_frac - 0.80)/0.20, 0, 1) : 0.0)
hydrant_pressure_ratio(pos) = clamp(P_tile(tile_of(pos)) * overpressure(z), 0.0, 1.2)
```

Doc 06 then applies its own `hydrant_factor = clamp(0.25 + 0.75 · ratio, 0.25, 1.15)` — the 0.25 floor is the engine's onboard tank, so a dead water system slows fire response instead of stopping it.

### 2.9 Failure model — doc 06 rolls, this doc supplies the multipliers (C-46)

**Ownership split with doc 06.** Doc 06 owns the `water_main_break` spawn roll and the whole incident lifecycle. Per **C-46** doc 06 **multiplies** this doc's condition, load and freeze terms into its own rate rather than replacing them — over-pressure alone cannot break a well-run system, and condition/utilization/freeze are exactly the levers the player controls. This doc therefore publishes, per candidate segment, three dimensionless multipliers and the raw inputs behind them:

```
water.mains() -> [ { segment_id, length_km, condition, utilization, pressure_ratio,
                     freeze_stress, ground_saturation,
                     cond_mult, load_mult, freeze_mult } ]

cond_mult   = 1.0 + 6.0 * pow(1.0 - condition, 2)
load_mult   = 1.0 + 1.5 * max(0, utilization - 0.85) / 0.15          # utilization = flow / capacity
freeze_mult = clamp( 1.0 + FREEZE_HAZARD_GAIN (2.5) * freeze_stress, 1.0, 6.0 )

doc 06's rate becomes  λ = R_wm_base (0.0022) · length_km · dt_h · f_press · cond_mult · load_mult · freeze_mult · f_ground
```

**Calibration of `FREEZE_HAZARD_GAIN` (shown, because it is a new constant).** Target: a deep freeze must reproduce this doc's standalone freeze hazard. Reference segment 0.10 km, condition 0.70, nominal load, `stress = 1.8` (example E). Doc 06's base for that segment is `0.0022 × 0.10 = 0.000220/h`; `cond_mult = 1 + 6×0.30² = 1.54` → `0.000339/h`. This doc's standalone total at the same point is `mechanical 0.000040 × 1.54 = 0.0000616` + `freeze 0.0020 × 1.8 × (1.2 − 0.70) = 0.0018` = **0.00186/h**. Required freeze factor `0.00186 / 0.000339 = 5.49`, so `gain = (5.49 − 1) / 1.8 = 2.49 → **2.5**`, and `freeze_mult(1.8) = 1 + 2.5×1.8 = 5.50`. ✔

This doc keeps the rolls doc 06 does not model — **pump, treatment and source failures** — and hands them to doc 06's queue as incidents. They roll **once per game-hour** of sim time (both live and offline — identical code path, identical results), using the shared `failures` RNG stream (constitution §5).

```
p_hour(component) = base_rate * cond_mult * load_mult * weather_mult * age_mult
load_mult   (pumps) = 1.0 + 1.5 * max(0, output_frac - 0.95) / 0.05
age_mult    = 1.0 + 0.15 * floor(age_game_days / 60)                     # capped at 2.0
weather_mult: thunderstorm 1.2 (mains, wash-out), flood 1.8, heat_wave 1.15 (pumps), else 1.0
```

Base rates (per component per game-hour, `data/water.json`) — **rates are dimensionless per-hour probabilities and are unaffected by the C-34 rescale**:

| Failure | Component | `base_rate` | Role after C-46 |
|---|---|---|---|
| `main_break` | main segment (per edge) | 0.000040 | **fallback / calibration reference only** — doc 06 rolls it |
| `freeze_break` | main segment | 0.0020 × stress × (1.2 − condition) | **fallback only** — folded into doc 06 as `freeze_mult` |
| `pump_failure` | `pump` | 0.001500 | owned here — MTBF ≈ 667 game-h ≈ 28 game-days at condition 1.0 |
| `treatment_failure` | `treatment` | 0.000900 | owned here — takes throughput to 0; contamination risk |
| `source_failure` | `source` | 0.000300 | owned here — intake screen clog / well fouling |

**Severity** on creation: `severity = clamp(0.25 + rng.randf() * 0.6 + 0.2 * (1 - condition), 0.1, 1.0)`.

**Freeze (doc 07 supplies `temp_c`):**

```
if air_temp_c < freeze_threshold_c (-6.0):
    stress += ((freeze_threshold_c - air_temp_c) / 10.0) * dt_h * (1.0 - 0.45 * insulation)
else:
    stress = max(0, stress - freeze_thaw_rate (0.5) * dt_h)
```

A freeze break carries `frozen: true` → repair time ×1.6, `post_repair_condition` 0.80 instead of 0.85, and `damage_fraction × 1.15` before the clamp (§2.12). Pumps and boosters with `insulation == 0` can also suffer `pump_failure` at ×2.0 base rate below −12 °C (exposed housing).

**Capacity shortage** is a *state*, not a component failure: when `ratio(z) < 0.98` continuously for `shortage_warn_minutes (20)`, emit `water_capacity_shortage` (Priority 2 notification). It has no repair job — the player must build.

### 2.10 Contamination (stub)

Zone-level flag, no chemistry model.

Triggers: `treatment_failure` while the plant is still passing water (probability `contam_on_treatment_fail = 0.35`), or a flood event from doc 07 overlapping a `source` tile (probability 0.50).

```
zone.contaminated = true
zone.contaminated_until_minutes = now + contamination_base_minutes (720)   # 12 game-hours
```

Effects while contaminated (boil-water advisory):
- happiness −`contamination_happiness_penalty (12)` on every building in the zone,
- commercial output ×0.90, hospital service ×0.85 (doc 02 / doc 09),
- **no pressure effect and no hydrant effect** — fire suppression is unaffected,
- clearing requires the treatment plant repaired **and** a `flush_minutes (360)` flush countdown; the player may pay to halve it — priced by doc 03 from this doc's dimensionless `flush_cost_frac_of_capital = 0.125` (§8), never as a dollar figure here.

Deferred (§6): contaminant types, illness model, disease incidents.

### 2.11 Effects on buildings, happiness and population

Every building samples `P_tile` at its access tile once per game-minute (not per tick). All of this is scale-invariant and unchanged by C-34.

```
water_happiness_penalty(b) = 40.0 * pow(clamp((0.60 - P) / 0.60, 0, 1), 1.2)
water_output_mult(b)       = 0.15 + 0.85 * clamp(P / 0.60, 0, 1)
```

| P | penalty | output mult | UI label |
|---|---|---|---|
| ≥0.60 | 0 | 1.00 | Normal |
| 0.45 | −7.6 | 0.79 | Low pressure |
| 0.35 | −14.0 | 0.65 | Low pressure |
| 0.20 | −24.6 | 0.43 | Critical |
| 0.10 | −32.1 | 0.29 | Critical |
| 0.00 | −40.0 | 0.15 | No water |

Additional rules:
- **Upgrade gate (spec §9.4):** doc 02 refuses an upgrade if the building's 30-game-day average `P < upgrade_min_pressure (0.55)` or if `water.zone_headroom_m3h(building_id) < delta_water × 1.10` (doc 02's check **E_WATER_HEADROOM**, §2.11 there). `zone_headroom_m3h(z) = max(0, S(z) − D(z))`. Refusal string: *"Upgrade blocked: water pressure/capacity insufficient in this zone."*
- **Health:** `P < 0.10` accumulates `no_water_hours`. Above `health_decay_start_hours (12)`, health −`2.0` pts/game-hour (doc 09 population & health).
- **Abandonment:** at `no_water_hours >= abandon_hours (36)`, residents leave at `0.5 %/game-hour`. No deaths from water outage alone (spec §31).
- Counters reset (`no_water_hours -= 4/h`) once `P ≥ 0.35`.
- **District reliability:** water contributes `water_reliability = mean over game-day of clamp(P/0.6,0,1)` to district stability (spec §32, doc 09).

### 2.12 Repair mechanics — work content here, price in doc 03 (C-16)

Water depots (doc 02's `water_facility`) house water vehicles. Vehicle routing, travel, job execution, roster and **every vehicle price** are doc 06/doc 03's; this doc owns capability and work content.

| Vehicle | Capabilities | `crew_mult` | Notes |
|---|---|---|---|
| `water_repair_truck` | main_break, valve, isolate | 1.00 | Depot L1 has 1 |
| `water_pump_truck` | pump_failure, temp_supply | 0.80 repair | Provides `temp_supply_m3h = 16.0` to a zone, diesel, no grid need |
| `water_heavy_truck` | main_break, treatment, source | 1.50 | Unlocked at depot L3 |
| `water_flood_response` | flood pump-out, contamination flush | 1.00 | Post-MVP |

```
work_minutes = base_minutes[type] * (0.6 + 0.8 * severity) * type_mods / crew_mult
type_mods    = freeze ? 1.6 : 1.0   ×   flooded_tile ? 1.4 : 1.0   ×   night ? 1.1 : 1.0
```

**Repair pricing is deleted from this doc** *(report 98 **C-16**)*. The `repair.base_cost` table (`main_break $4,000 · freeze_break $4,600 · pump_failure $9,000 · treatment_failure $22,000 · source_failure $7,500`) and the formula `base_cost[type] × (0.5 + severity)` are **removed** from §8 and from `data/water.json`. A reader looking for what a repair costs looks at **doc 03 §2.5**:

```
repair_cost = round( capital_value(asset) × damage_fraction × REPAIR_COST_PER_CAPITAL (0.85) × M_repair )
```

This doc supplies **only** `damage_fraction ∈ [0,1]`, in the exact conversion doc 03 published for it:

```
damage_fraction(type, severity) = clamp( 0.5 + severity, 0, 1 ) × frozen_dmg_mult (1.15 if frozen else 1.0), clamped to [0,1]
```

| break type | `damage_fraction` at severity 0.4 | at 0.7 | at 1.0 | note |
|---|---|---|---|---|
| `main_break` | 0.90 | 1.00 | 1.00 | per-type cost separation now comes from `capital_value`, not a price row |
| `freeze_break` | 1.00 (0.90×1.15 = 1.035 → 1.00) | 1.00 | 1.00 | the ×1.15 only bites below severity 0.37 |
| `pump_failure` | 0.90 | 1.00 | 1.00 | a pump's capital is ~11× a service main segment's, so the old ordering survives |
| `treatment_failure` | 0.90 | 1.00 | 1.00 | |
| `source_failure` | 0.90 | 1.00 | 1.00 | |

`base_minutes` / `post_repair_condition` (full table in §8): main_break 50 / 0.85 · freeze_break 50×1.6 / 0.80 · pump_failure 90 / 0.90 · treatment_failure 180 / 0.90 · source_failure 120 / 0.90 · isolate_main 8 / — · overhaul 240 / 1.00.

**Isolation** (`cmd_isolate_main`) is the key tactical verb: a crew arrives, spends 8 game-minutes, and the broken main goes `isolated` — leak → 0, but everything downstream drops out of the live graph, which triggers `rebuild_zones()` and can strand tiles. Isolation is auto-released when the repair completes.

**Maintenance & condition decay** (funded from doc 03's maintenance budget, `maintenance_level` ∈ [0,1]):

```
condition -= condition_decay_per_hour * (2.5 - 1.5 * maintenance_level) * dt_h
condition_decay_per_hour: mains 0.000060, pumps 0.000100, treatment 0.000080, tanks 0.000030
```
At full funding a pump ages 1.0 → 0.0 in ≈10,000 game-hours (≈417 game-days); at zero funding ≈167 game-days. `cmd_overhaul_node(id)` restores condition to 1.0, takes 240 crew-minutes, and is priced by doc 03 as `repair_cost(node, damage_fraction = 1 − condition)` — the `overhaul_cost_frac 0.35` constant is **deleted**.

### 2.13 The C-34 rescale — APPLIED (recomputation R-09)

This section previously *proposed* an arbitration. Report 98 C-34 **ruled it**, and the rescale is now applied throughout this document. What follows is the audit trail, not a proposal.

**The ruling.** `1 WU ≡ 1 m³/h`. Doc 02 divides its water column by **6.25** (house L1 `0.5 → 0.08 = 4 × 0.020` exactly). Doc 05 multiplies **every flow, capacity and volume constant** by **`WU_SCALE = 0.1333`** and adopts doc 02's kW column. Target: **~2,000 residents per L1 facility**, verified exactly in §2.4.

**How the L2–L5 rows are generated.** The rescale fixes the **L1 anchors**; the *shape* is doc 02's, because `water_facility` is a `standard`-class archetype and doc 02 §2.2/§2.3 owns the curve family: *"Doc 02 owns the `k_dem = 2.45` shape those rows must be generated on; doc 05 owns their L1 anchors."* Therefore:

```
capacity(variant, L) = round_wu( capacity_native_L1 × WU_SCALE (0.1333) × k_dem^(L−1) ),  k_dem = 2.45
base_kw(variant, L)  = round_kw( kw_per_m3h[variant] × capacity(variant, L) )
round_wu / round_kw  = doc 02 §2.2's rounding rules (WU: <1 → 0.01, <10 → 0.1, <100 → 0.5, else 1;
                       kW: <10 → 0.5, <100 → 1, <1,000 → 5, <10,000 → 10, else 50)
```

**The proof that this is the intended reading:** `1.50 kW per m³/h × (40 × 2.45^(L−1))` reproduces doc 02's amended `water_facility` kW column `60 / 145 / 360 / 880 / 2160` **digit for digit at all five levels**. No other pairing of anchor and shape does. Level ratios (treatment : pump = 2 : 1, source : treatment = 1.33 : 1, tank hours of storage = 3.0 h of the same-level pump) are preserved at every level because every variant uses the same exponent.

| after the rescale | L1 | L2 | L3 | L4 | L5 |
|---|---|---|---|---|---|
| `pump` `rated_flow_m3h` | **40.0** | 98.0 | 240 | 588 | 1441 |
| `pump` `base_kw` (= doc 02) | **60** | 145 | 360 | 880 | 2160 |
| `treatment` `throughput_m3h` | 80.0 | 196.0 | 480 | 1176 | 2882 |
| `tank` `capacity_m3` / `max_out` / `max_in` | 120 / 66.5 / 26.5 | 294 / 163 / 65.0 | 720 / 399 / 159 | 1765 / 978 / 390 | 4324 / 2396 / 955 |
| `source` (river) `yield_m3h` | 107 | 262 | 642 | 1574 | 3855 |
| mains `service` / `trunk` / `arterial` `capacity_m3h` | 53.5 | 213 | 640 | — | — |
| `fire_flow_per_engine_m3h` | **8.0** | | | | |

**Every formula, ratio, threshold, failure rate, repair time and effect in this doc is scale-invariant** (they all consume `S/D`, `volume/deficit`, or `flow/capacity`), which is why only the constants moved. Test 25 (`test_scale_invariance`) proves it by re-running example A with every flow and volume divided back by `WU_SCALE`.

**Downstream consequences of the applied rescale** (flagged, not amended here — they belong to the owning docs): doc 03's `E_water` now reads `pump_capacity_m3h × PUMP_OM_PER_M3H_HOUR (0.35)` against a **40 m³/h** starter pump = **$14/gh**, not the `$5/gh` assumed in doc 03 §2.12's starter table (report 98 **RR-6** adopts the $14/gh line in doc 03's re-run ledger); doc 09's starter water demand is **5.56 m³/h against 40 m³/h of L1 supply — 7.2× headroom** ⟨owner: doc 09 §2.9.4⟩, derived cell by cell in §2.4.

**Correction — the withdrawn 8.2 m³/h / 4.9× figure** *(report 98 **RR-11**, verifier findings 96 F-5 / 97 F-05)*. This section previously stated *"8.2 m³/h … 4.9× headroom"*. That number is `51.1 / 6.25 = 8.176`: it applies the C-34 WU rescale to the **pre-C-11 28 / 8 / 6 / 1 manifest** and never applies C-11's revert to 18 / 5 / 3 / 1 — it double-counts the mix in words but not in arithmetic. Report 98 §11/C-34 seeded the same stale figure, and doc 09 §2.9.4 (the owner) recomputed it correctly on the reverted manifest. Applying **both** rulings gives **5.56 m³/h**, and `40.0 / 5.56 = 7.194` → **7.2×**, not 4.9× — the old figure overstated starter demand by 47 %. Doc 09's values are the authoritative ones and this doc now states them in §2.4, here, and in §2.14.

### 2.14 Worked examples (recomputation R-10 — all in rescaled units)

*Channel values are doc 01's (C-33) and are stated as inputs so every example is reproducible in a test: `water_demand_residential` interpolates its keyframes to **1.075 at h13, 1.333 at h19, 1.025 at h22**; `water_demand_commercial` keeps this doc's old commercial shape, **1.65 at h13, 1.00 at h19, 0.45 at h22**.*

> **One of those six stated inputs is not what the store holds (verified 2026-08-20, doc 91 A91-D-25).** Five reproduce exactly. The sixth, `water_demand_commercial = 0.45 at h22`, does not: `data/time.json`'s authored keyframes are `[21, 0.65]` and `[23, 0.35]`, which interpolate to **0.50** at h22, and C-33 makes `data/time.json` the store. `tests/test_water_data.gd:51-55` records the disagreement and asserts the store's 0.50; the examples below still pass because they are driven from injected channels rather than from the store, which is exactly why nobody noticed. **A worked example whose stated input is not the shipped input cannot be used to debug the shipped system**, so this wants resolving in one direction or the other: either the number here becomes 0.50, or `data/time.json` gains the keyframe that would make 0.45 true — and the second is a balance change and wants doc 92.

*Scale note (report 98 **RR-11**): zones `R1` and `D2` below are illustrative mid-game zones, each several times larger than the whole starter city. The starter city's own figure is **5.56 m³/h of demand against 40 m³/h of L1 supply = 7.2× headroom** (§2.4, ⟨owner: doc 09 §2.9.4⟩ — mean 5.56, morning peak 7.10, 20:00 6.24). No example here is the starter manifest and no starter figure is derived from one; in particular example A's 26.93 m³/h zone is ~4.8× the entire starter city's mean draw, which is why an L1 tank buffers it for only 4 h there while `WTR-2` buffers the starter city for 21.6 h (doc 09 §2.9.6).*

**A — Grid loss, tank buffer (the signature moment).**
Zone `R1` at 19:00. Cached sums `res_base 16.0`, `com_base 4.0`, `proc_base 1.6` (the old 120 / 30 / 12 × 0.1333). Clear weather, no restrictions.
`D = 16.0×1.333 + 4.0×1.00 + 1.6 = 21.33 + 4.00 + 1.60 = **26.93 m³/h**`.
Pump P1 (`pump` L1, rated 40.0, condition 0.95): `cond_factor = 0.5+0.5×0.95 = 0.975`, power 1.0 → `flow = 40.0 × 1.0 × 0.975 = 39.0`. Trunk main 213 not binding. `S = 39.0 ≥ D` → delivered 26.93, surplus 12.07 → tank T1 (`tank` L1: cap 120, vol 108 = 90 %, `max_inflow 26.5`) fills at 12.07 m³/h.
Substation trips. `grid_fraction = 0`, no backup → `0 < 0.35` → pump trips, `S = 0`.
`need = 26.93`; `out = min(26.93, max_outflow 66.5, 108/dt)` = 26.93 → `delivered = 26.93`, `ratio = 1.0`, `level_frac = 0.90 ≥ 0.15` → `head_factor = 1.0` → **P stays 1.0**. Hydrants full. Nothing visibly wrong yet — the overlay shows `buffer 4.01 h` and the tank gauge draining.
- Time to `level_frac 0.15` (18.0 m³): `(108 − 18) / 26.93 = 90 / 26.93 = **3.34 game-hours**` (≈3.3 real minutes at 60×).
- Then head_factor falls linearly: at 7.5 % full (9.0 m³) → `0.40 + 0.60×0.5 = 0.70` → **P = 0.70**, buildings "Low pressure", hydrants at 70 %.
- Empty at `108 / 26.93 = **4.01 game-hours**` → ratio 0 → **P = 0**.
`water_tank_low` (P2) fires at `level_frac ≤ 0.25`; `water_tank_empty` (P1) at 0.

**B — Refill is slower than drain.**
Power restored at t = 3.0 h: `vol = 108 − 26.93×3 = **27.21 m³** (22.7 %)`. It is now 22:00.
`D = 16.0×1.025 + 4.0×0.45 + 1.6 = 16.40 + 1.80 + 1.60 = **19.80 m³/h**`.
`S = 39.0`; surplus `19.20` → `inflow = min(19.20, max_inflow 26.5, (120−27.21)/dt) = 19.20`.
Refill 27.21 → 120 = `92.79 / 19.20 = **4.83 game-hours**`, against 4.01 h to drain. Recovery costs more than the failure — the lesson is "buy headroom", not "buy a bigger tank".

**C — Main break during a fire (the full cascade, with doc 06 owning the break).**
Zone `D2` at 13:00: `res_base 30.0`, `com_base 10.0`, `proc_base 5.0`.
`D = 30.0×1.075 + 10.0×1.65 + 5.0 = 32.25 + 16.50 + 5.00 = **53.75 m³/h**`.
Pump L2 (rated 98.0, cond 0.90 → cond_factor 0.95) → `S = 98.0 × 0.95 = **93.10**`. Tank T2 (`tank` L2: cap 294, vol 205.8 = 70 %, `max_out 163`).
Trunk main (capacity 213) breaks, severity 0.7 → `leak = 213 × 0.25 × 0.7 = **37.28 m³/h**` → `D_eff = 91.03`, still under S → ratio 1.0, tank still trickling up at 2.07 m³/h.
Doc 06 raises the incident at **tier 1** → `zone_pressure_delta = −0.15` (C-46, doc 06's table wins) → **P = 1.00 − 0.15 = 0.85**.
Doc 06 puts 2 engines on a fire in the zone → `fire_draw = 2 × 8.0 = 16.0` → `D_eff = 107.03 > S` → `need = 13.93` from the tank → delivered 107.03 → ratio still 1.0 → **P still 0.85**; the tank is paying for the pressure.
Fire tile is 3 tiles from the nearest main: `prox = 1 − 0.10×(3−2) = 0.90`, flat ground → `tile_factor = 0.90` → **`hydrant_pressure_ratio = 0.85 × 0.90 = 0.765`**, and doc 06's own `hydrant_factor = clamp(0.25 + 0.75×0.765, …) = **0.824**` — it suppresses at 82 % of nominal flow.
Tank drains at 13.93 m³/h: 205.8 → 44.1 (15 %) in `161.7 / 13.93 = **11.61 h**`, empty in `205.8 / 13.93 = **14.77 h**`.
Player isolates the break (8 min) → leak 0, but the isolated branch carrying 12.0 m³/h of demand leaves the live graph; its tiles are now >12 tiles from a live main → `P_tile = 0`, "No water" for those buildings, and any hydrant there is dead. Remaining zone: `D_eff = 53.75 − 12.00 + 16.00 = 57.75 < 93.10` → tank refills at `min(35.35, max_inflow 65.0) = 35.35 m³/h` while the crew works. **Trading a neighbourhood's taps for the fire's hydrants is exactly the intended decision.**
*(Fallback path, for a break with no owning incident: `break_pen = 0.12 × 0.7 = 0.084` → `P = 0.916`. MVP never takes it.)*

**D — Power math and the backup module.**
Pump L2: `base_kw = **145 kW**` — doc 02's column, and `1.50 × 98.0 = 147 → 145` reproduces it.
Brownout, `grid_fraction = 0.60` → `flow = 98.0 × 0.60 × 0.95 = **55.86 m³/h**` (above the 0.35 trip threshold, so the pump runs derated and the zone quietly slides into deficit).
With the L2 backup module: this doc publishes `coverage_frac = 0.60` and `backup_kw = round_kw(0.60 × 145) = **87 kW**`. On full grid loss, doc 04 starts the generator, returns `power_output_multiplier = 0.60`, and the pump runs at `98.0 × 0.60 × 0.95 = 55.86 m³/h`.
**Fuel, runtime and refuelling are doc 04's** (C-36). For reference only, against doc 04's model constants: `0.28 L/kWh × 87 kW = 24.4 L/h`, so doc 04's 400 L L2 tank gives ≈**16.4 game-hours**, billed by doc 03 at $95/MWh (`87 kW × 16.4 h = 1.43 MWh ≈ $136` per full burn). This doc asserts none of those three numbers.

**E — Freeze (unchanged by the rescale; re-expressed as a doc-06 input per C-46).**
−12 °C for 3 h, uninsulated segment (`insulation = 0`), condition 0.70.
`stress = ((−6) − (−12))/10 × 3 = **1.8**` → published `freeze_mult = 1 + 2.5×1.8 = **5.50**`, with `cond_mult = 1 + 6×0.30² = **1.54**`.
Doc 06's roll for a 0.10 km segment: `0.0022 × 0.10 × 1.54 × 1.00 × 5.50 = **0.001863/h**` — which is the standalone hazard this doc used to roll itself (`0.000040×1.54 + 0.0020×1.8×0.5 = 0.00186`), to three significant figures. Over 60 exposed segments: `1 − (1 − 0.001863)^60 = **0.1058**` → ≈1 break per 9.5 hours of deep freeze; insulation level 2 cuts stress by 90 % (`stress 0.18 → freeze_mult 1.45`, rate `0.000491/h`) → ≈1 per 34 h.

**F — Demand from growth: the upgrade gate and the min-cut (the Pillar-5 beat).**
Zone `D2` from example C: `D = 53.75`, `S = 93.10` (pump L2, trunk main 213) → `zone_headroom = 39.35 m³/h`.
A `data_center` **L3** lands: doc 02 publishes `water_demand = 21.0 m³/h`; shares 0.00/0.03/0.97 → `com_base += 0.63`, `proc_base += 20.37`.
`D = 30.0×1.075 + 10.63×1.65 + 25.37 = 32.25 + 17.54 + 25.37 = **75.16**` — still under `S = 93.10`, headroom now **17.94**.
The player then tries to upgrade it **L3 → L4**. Doc 02's `delta_water = 53.0 − 21.0 = **32.0 m³/h**`, and its check **E_WATER_HEADROOM** needs `32.0 × 1.10 = **35.2**` against a headroom of 17.94 → **BLOCKED**: *"Upgrade blocked: water pressure/capacity insufficient in this zone."*
The player upgrades the pump L2 → L3: rated flow 98.0 → 240, `S_raw = 240 × 0.95 = 228`. But `feed_capacity` is the single trunk main at **213** → `S = 213`, not 228 — the min-cut bites, exactly as §2.5 promises, and the overlay shows the main at 100 % utilization. Headroom `213 − 75.16 = **137.8 ≥ 35.2`** → the upgrade is now allowed; after it, `D = 32.25 + 19.12 + 56.41 = **107.78**`, `ratio = 1.0`, `P = 1.0`.
Had the player *not* upgraded the pump and forced the data center up anyway (a debug path, not a legal one), `ratio = 93.10 / 107.78 = 0.8638` → `water_capacity_shortage` after 20 minutes and, once the tank empties, `P = 0.8638^1.3 = **0.827**`. **Growth bought demand at 2.55× per level against tax at 2.15× — the pump, the main and the tank all have to move before the tower can.**

---

## 3. Data Schema

### 3.1 `data/water.json`

Full contents in §8. Top-level keys: `schema_version`, `units`, `_provenance`, `global` (coefficients/thresholds), `demand_split` (per-archetype res/com/proc shares — **no curves**), `_component_columns` + `components` (six variant rows × **5 levels each**, stored as column-ordered rows — the loader zips columns to field names), `mains` (3 tiers), `backup` (`coverage_frac` + per-variant `backup_kw`), `price_inputs` (dimensionless ratios published to doc 03), `failures`, `repair`, `effects`, `contamination`, `overlay`, `feature_flags`.

The loader validates: every `components[variant][i]` row length equals `_component_columns[variant]` length; **no hourly array exists anywhere in the file** (C-33 guard); every `demand_split` row sums to `1.000 ± 0.001`; every referenced archetype exists in **doc 02's** building table; **no key whose name contains `cost`, `price`, `upkeep` or `maintenance` carries a dollar magnitude** (C-07/C-16 guard — only dimensionless ratios are permitted); `components.pump.base_kw` equals doc 02's `water_facility` kW column exactly (C-34 guard); and **every key under `_provenance` — including `_starter_reference`, which quotes doc 09 §2.9.4's starter totals — is documentation, never a sim input** (RR-11 guard: the loader rejects any attempt to bind them to a runtime field, and test 30 checks the quoted values against doc 09's manifest instead).

### 3.2 Save section `"water"` (inside the slot save, constitution §9)

*(Key name is already `section_version` — this doc is not in report 98 C-25's rename list.)*

```json
{
  "water": {
    "section_version": 2,
    "nodes": [
      { "id": 41, "variant": "pump", "subtype": null, "level": 2, "tile": [96, 48],
        "condition": 0.93, "state": "ok", "built_at_minutes": 128340,
        "grid_load_id": "water_pump_41", "restart_timer_min": 0.0,
        "backup_installed": true }
    ],
    "tanks_volume": { "57": 205.80 },
    "edges": [
      { "id": 210, "a": 41, "b": 58, "tier": "trunk", "level": 1,
        "path": [[96,48],[97,48],[98,48]], "condition": 0.88,
        "state": "broken", "severity": 0.7, "frozen": false, "freeze_stress": 0.0,
        "insulation": 0, "broken_at_minutes": 131020, "owning_incident": 4412 }
    ],
    "zones": [
      { "zone_key": 41, "pressure": 0.85, "contaminated": false, "contaminated_until_minutes": 0,
        "no_supply_hours": 0.0, "shortage_timer_min": 0.0 }
    ],
    "jobs": [
      { "job_id": 88, "kind": "main_break", "target_kind": "edge", "target_id": 210,
        "tile": [97,48], "severity": 0.7, "damage_fraction": 1.0, "work_remaining_min": 34.5,
        "assigned_vehicle": 12, "isolated": true, "created_at_minutes": 131020 }
    ],
    "service_accum": { "1042": { "w_accum_h": 0.4125, "elapsed_h": 0.5000 } },
    "policy": { "water_restrictions": false, "auto_dispatch_water": true },
    "stats": { "delivered_m3_total": 122400.7, "m3_treated_total": 122400.7, "breaks_total": 17,
               "last_rebuild_minutes": 131030 }
  }
}
```

**Changes from `section_version` 1** (migration `migrate_water_v1_to_v2`): `kind` → `variant` (+ `subtype` for `source`); the `backup` object collapses to the single boolean `backup_installed` — **`kw`, `fuel_l` and `start_timer_min` move to doc 04's `power` section** (C-36); `owning_incident` added to edges (C-46); `damage_fraction` added to jobs (C-16); `service_accum` added (C-37); `auto_refuel_backup` removed from `policy`. Volumes in the example are rescaled per C-34.

**`section_version` 2 → 3 (Wave 13, report 98 §26 RR-60, defect A91-D-30).** Two
additive keys, and both of them are **history rather than state**:

```json
"demand": {
  "buildings": [ { "id": "APT-001", "archetype": "apartment", "tile": [40,32], "w_b": 1.62 } ],
  "zone_sums": {
    "res":   { "0": 4.8125 }, "com":   { "0": 0.9987 },
    "proc":  { "0": 1.3741 }, "count": { "0": 37 }
  }
},
"pending": { "topology": false, "demand": false }
```

The rung is **additive** — a v2 body has neither key, `adopt_zone_sums` declines
and `pending` defaults to `false`, so the section restores exactly as it always
has (doc 08 §2.8's additive-first rule) and there is no `migrate_water_v2_to_v3`
to write.

**`pending` is the rebuilds this city OWES.** A city that broke a main a tick
before the save carries `topology_dirty` into its next `advance()` and rebuilds
its zones there; a restored city has already spent that rebuild inside
`deserialize()`, so without the flag it does not owe it, does not do it, and
`stats.last_rebuild_minutes` — which IS in the save body — stops agreeing within
one game-hour. Measured on the benchmark city seven game-days in: **10080.0 live
against 9960.0 restored**. Same family as `service_pending_h` (C-37 / D-15
proposal 3), and named the same way for that reason.

**Why `zone_sums` exists, because the paragraph below used to say the opposite.** The
three per-zone demand sums were listed as *"not saved (rebuilt on load)"*, and
rebuilding them is what broke constitution §5. They are maintained
**incrementally** while the city runs — `set_demand` backs a building's old
contribution out of the sum and adds its new one, once per changed building per
utilities tick — and `reassign()` rebuilds them with a single forward pass in
sorted building order. Both are correct and the two float histories are **not
the same float**: after 24 game-hours of the founding city `com_base` differs in
its last bit, and one further game-hour is enough for the live city and its
restored twin to disagree about how much water was delivered. A quantity that is
a function of the city's HISTORY has to travel with the save; doc 10 §3.2 reached
the same conclusion about smoothed congestion two waves earlier, for the same
reason and in the same words.

**Not saved (rebuilt on load):** zone→tile maps, `tile_factor` caches, `feed_capacity`, `upstream_cap`, `fire_draw`. `load()` ends with `rebuild_zones()` + `rebuild_demand_cache()`, **and then takes the saved `zone_sums` back** — the rebuild is what re-derives each building's zone, and the sums are what the live run held. Zone **ids** are unstable across rebuilds; the persisted `zones` array is keyed by a stable `zone_key` = smallest node id in the component, and re-mapped on load (pressure defaults to 1.0 if a zone key is unknown).

---

## 4. Sim API Sketch

`sim/water/` — all `RefCounted`, no Node, no engine singletons (constitution §3).

| Class | Responsibility |
|---|---|
| `WaterSystem` | Owner. `advance(dt_h)`, `hourly_step()`, `rebuild_zones()`, save/load, command handling. |
| `WaterNode`, `WaterEdge` | Component state (§2.1). |
| `PressureZone` | Derived aggregate: demand sums, supply, pressure, tanks, buffer hours. |
| `WaterDemandCache` | Event-driven per-zone `res/com/proc` sums from doc 02's `W_b` × `demand_split`; `on_building_changed(b)`. |
| `WaterTopology` | Connected components, tile BFS, `tile_factor` caches, `feed_capacity`, `upstream_cap`. |
| `WaterFailureModel` | Hourly pump/treatment/source rolls, freeze stress, condition decay, the multipliers published to doc 06. Uses `failures` RNG stream. |
| `WaterServiceLedger` | Per-building hourly service accumulation → `water_service_factor_hour()` (§5.4). |
| `WaterRepairJobs` | Job lifecycle, work-time math, `damage_fraction`, isolation. |
| `WaterSnapshot` | Read-only overlay/HUD payload (§5.8). |

**Tick entry points**
- `advance(dt_h)` — utilities cadence (`EVERY_TICK`, dt_h = 1/240; offline dt_h = 1.0). Demand → supply → tank → pressure → job progress → per-building service accumulation.
- `hourly_step()` — called once per crossed game-hour by the scheduler, both live and offline: failure rolls, condition decay, freeze stress, contamination timers, **service-factor settlement** (§5.4), statistics.

**Commands handled** (from `ui/` via the command API): `place_water_node` (= `place_building{type:"water_facility", variant:…}` validated here), `place_main`, `remove_main`, `upgrade_water_node`, `install_backup_generator` (validates the node, then delegates sizing, fuel and refuelling to doc 04), `isolate_main`, `restore_main`, `overhaul_node`, `set_water_restrictions`, `deploy_pump_truck`, `set_water_policy`.
*Deleted: `refuel_backup` — doc 04 owns refuelling (C-36).*

**`install_backup_generator` is an INTERFACE CALL, not a player verb, and that is now a ruling** *(Wave 12, doc 93 §N3)*. It has no `CitySim` wrapper, no card and no matrix row, and it keeps none until **doc 04 ships the generator it delegates to** — doc 04 §12's deferred list names "backup generators", its §6 unshipped list names `place_backup_gen`, and `grep -rn fuel sim/power/` returns nothing. As shipped the command sets `backup_installed = true` and debits no dollar, so `power_fraction_of` answers `coverage_frac` instead of 0.0 whenever the node goes dark, permanently and for free: a card on it would sell the half of the feature that grants the benefit with none of the half that prices it. The re-open condition is doc 04 §2.10's capital price, tank, burn rate and refuelling; the verb that gets the door then is `place_backup_gen`, and this call stays what it is — three numbers handed across a seam.

**Events emitted** (event bus, per tick): `water_main_break` *(fallback path only — doc 06 owns the incident)*, `water_main_isolated`, `water_pump_failed`, `water_pump_tripped`, `water_treatment_failed`, `water_source_failed`, `water_freeze_break` *(fallback path only)*, `water_tank_low`, `water_tank_empty`, `water_capacity_shortage`, `water_zone_offline`, `water_pressure_low`, `water_pressure_restored`, `water_contamination_started`, `water_contamination_cleared`, `water_incident_raised` (handed to doc 06's queue), `water_repair_completed`.
*Deleted: `water_backup_started`, `water_backup_fuel_out` — doc 04 emits the generator lifecycle (C-36).*

---

## 5. Cross-System Interfaces

*(Doc numbers below are the canonical on-disk filenames — report 98 **Ruling Zero**. The old note in this section claiming doc 06 numbered buildings "03" and economy "02" is deleted; that map no longer exists anywhere in the project.)*

### 5.1 Doc 01 — Time & tick scheduler
Water is phase **P07 `WATER`**, every step, guaranteed **after P06 `POWER` in the same step** (a pump that loses its feeder loses pressure with zero lag) and **before P08 `ROADS`**. Water subscribes to `EVERY_TICK` plus the per-game-hour hook for §2.9 and §5.4.
Water reads **two** diurnal channels and stores none of its own (C-33): `ctx.channels.water_demand_residential` (24-h mean 0.997) and `ctx.channels.water_demand_commercial` (24-h mean 0.999). Doc 01 populated the commercial channel from this doc's deleted `commercial_hourly` array, so the shape is unchanged; the store is not.

### 5.2 Doc 02 — Buildings
Water **reads**: `water_demand` per building per tick (**the magnitude — doc 02 owns it**, already multiplied by `STATE_DEMAND` and doc 07's `water_mult`), `archetype`, `level`, `state`, `origin_tile`/`access_tile`, and the `water_facility` **shell + variant list** (C-35).
Water **provides**: every per-variant number for `water_facility` — `base_kw`, `kw_required`, capacity/volume/head, `coverage_frac`, and the per-variant footprint of the four non-reference variants (§8); `get_water_service(building) -> {pressure, output_mult, happiness_penalty, contaminated}`; `zone_headroom_m3h(building_id)`; `can_upgrade_water(building, target_level) -> {ok, reason, deficit_m3h}` with `reason = "BLOCKED_WATER_CAPACITY"` (doc 02's check **E_WATER_HEADROOM**).
Doc 02's `water_supply_wu_per_hour` and `pressure_radius_tiles` columns are **deleted** (C-06, C-35); this doc's per-variant capacity and the zone graph replace them.

### 5.3 Doc 03 — Economy (sole currency authority)
Water **provides**, and never a dollar: `delivered_m3_hour`, `m3_treated_hour`, `main_km`, `pump_capacity_m3h` (the `E_water` inputs), `water_margin_score` (for the resilience index), `water_service_factor_hour(building_id)` (§5.4, doc 03's `w_b`), and **`damage_fraction ∈ [0,1]` per break type** (C-16).
Water **consumes**: `economy.repair_cost(asset, damage_fraction)`, `economy.debit(amount, reason)`, `CostCurves.build_cost/upgrade_cost/capital_value` for every water asset, and `Difficulty.get("economic", …)`. Doc 03's `E_water = m3_treated × 0.06 + main_km × 0.7 × (1 + 2.0×(1−condition)) + pump_capacity_m3h × 0.35` is the **only** water expense formula; this doc's old `chem_cost_per_m3`, per-component `maintenance_per_hour` and per-tile main maintenance rows are deleted as duplicates.

### 5.4 Per-building hourly service — `water_service_factor_hour()` (report 98 C-37)

Doc 03's `f_water` needs the **fraction of the settled hour** a building actually had usable water; a boolean or an instantaneous pressure erases most of the cascade signal, exactly as C-37 says of doc 04's `is_powered()`. This doc therefore accumulates, per building, every tick:

```
w_accum_h  += clamp( P_tile(access_tile(b)) / NOMINAL_PRESSURE (0.60), 0.0, 1.0 ) * dt_h
elapsed_h  += dt_h

water_service_factor_hour(building_id) = w_accum_h / max(elapsed_h, 1e-6)      # ∈ [0,1]
```

Settled and reset in `hourly_step()`, before doc 03's `tick_hour()` runs in the same game-hour (doc 01 phase order P07 → economy). Persisted mid-hour in `service_accum` so a save/load inside an hour cannot inflate or erase a building's revenue. The accumulator uses the same `dt_h` at 1/240 and at 1.0, so offline catch-up produces the identical figure a live hour would.

**Worked example (the twin of doc 03's example B).** A house sits in zone `R1` through example A's outage: `P = 1.00` for the first 3.34 h of the outage, then falls linearly through the head-factor ramp to 0 at 4.01 h. For the settled hour that begins 3.00 h into the outage: minutes 0–20.4 at `P = 1.00` (→ ratio 1.0), then `P` ramps 1.00 → 0.40 over the next 21.0 minutes (mean ratio ≈ 0.70 → clamped contribution 0.70), then `P` sits at 0 for the last 18.6 minutes.
`w_accum = (20.4/60)×1.000 + (21.0/60)×0.700 + (18.6/60)×0.000 = 0.340 + 0.245 + 0.000 = **0.585**` → `water_service_factor_hour = **0.585**`.
Doc 03 then computes `f_water(residential) = 0.45 + 0.55 × 0.585 = **0.772**` — the house earns 77 % of its water term for the hour it half-lost water. A boolean would have said "1.0, it had water for 41 of 60 minutes" or "0.0, it ended dark"; neither is true.

A volumetric sibling, `water_delivered_fraction_hour(building_id) = served_m3 / demanded_m3`, is accumulated on the same clock and used for doc 03's water tariff and for the WHILE YOU WERE AWAY report. Only the pressure-based figure feeds `f_water`.

### 5.5 Doc 04 — Electrical grid (water is a consumer)
Water reads `power.is_powered(node_id)` and `power.power_output_multiplier(node_id)` only (§2.6). Water supplies doc 04: `priority_class = CRITICAL`, `backup_capable = true`, `base_kw`/`kw_required` per node (§8, identical to doc 02's kW column for the `pump` variant), **`coverage_frac` per node (this doc owns it — C-36)** and `backup_kw` as the generator sizing input. Doc 04 owns the generator itself: fuel, burn rate, tank size, start delay, refuelling, its save state and its events.

### 5.6 Doc 06 — Incidents, dispatch & fire (water supplies *and* consumes)
Water **provides**:
- `water.hydrant_pressure_ratio(pos) -> float ∈ [0, 1.2]` (§2.8) — the fire cascade.
- `water.mains() -> [{segment_id, length_km, condition, utilization, pressure_ratio, freeze_stress, ground_saturation, cond_mult, load_mult, freeze_mult}]` — the candidate set **and the three hazard multipliers doc 06 multiplies into its roll** (C-46).
- `water.set_segment_broken(id, severity, incident_id)` / `water.set_segment_repaired(id)` — state transitions doc 06 drives.
- `damage_fraction` per break type, for doc 06's repair job to price through doc 03.
Water **consumes**: `water.zone_pressure_delta(zone, d)` — **doc 06's tiered −0.15 / −0.35 / −0.60 / −0.80 is authoritative** and is held until the incident resolves (C-46); `register_fire_draw(draw_id, pos, flow)` / `clear_fire_draw(draw_id)` at `fire_flow_per_engine_m3h = 8.0` per engine; doc 06's `water_repair` and `hydrant_service` capabilities and its vehicle roster (this doc authors capability and `crew_mult` only, never a vehicle price); and doc 06's incident queue for pump/treatment/source failures, to which water supplies `base_work_gm` and §2.12's modifier formula while doc 06 owns travel, skill, weather and night modifiers.

### 5.7 Docs 07 / 08 / 09 / 10
- **Doc 07 (weather & director):** water reads `weather.current()` → `kind`, `temp_c`, `flood_saturation`, and the `TileFlooded(tile, depth_m)` event stream. Water authors **no** weather multiplier of its own (C-57) — the demand-side effect arrives pre-applied inside doc 02's `water_demand`, and the failure-side `weather_failure_mult` rows in §8 are hazard modifiers, not effect channels.
- **Doc 08 (persistence/offline):** save section §3.2; offline uses `advance(dt_h = 1.0)` + `hourly_step()`, same code path; `ctx.catchup_index` and the offline band are read, never derived.
- **Doc 09 (map, land, districts, population & stability):** water reads `elev_m(tile)`, `is_developed(tile)`, `block_of(tile)`; water supplies `water_reliability` per district for the stability aggregate (§2.11) and per-building `water_service_factor_hour` for population/happiness.
- **Doc 10 (roads):** a break emits its tile; doc 06's escalation table sets `roads.set_edge_speed_mult(edge, 0.5)` at T3 and closes the segment on failure. Water asserts nothing about roads itself.

### 5.8 Doc 12 — UI / Water overlay (spec §26)
`WaterSystem.get_overlay_snapshot() -> WaterOverlaySnapshot`, rebuilt at the tick cadence, allocation-free (reused buffers):

```
zones[]:  { zone_key, pressure, demand_m3h, supply_m3h, delivered_m3h,
            tank_volume_m3, tank_capacity_m3, buffer_hours, contaminated, dead,
            color_band }                      # band: normal>=0.60, warn>=0.35, critical>=0.10, none<0.10
nodes[]:  { id, variant, level, tile, state, condition, load_kw, power_fraction,
            on_backup, coverage_frac, flow_m3h, rated_m3h, level_frac }
edges[]:  { id, path, tier, state, condition, flow_m3h, utilization, severity }
tiles:    per land block PackedByteArray of quantized P_tile (0-255) for the pressure heat-tint
jobs[]:   { job_id, kind, tile, severity, work_remaining_min, assigned_vehicle }
city:     { total_demand_m3h, total_supply_m3h, total_storage_m3, storage_frac,
            water_health_pct, zones_in_deficit, active_breaks }
water_health_pct = round(100 * Σ(building_count_z * clamp(P_z/0.6,0,1)) / total_buildings)
```

Doc 12 ships **five build cards** for `water_facility`, one per variant (C-35), each showing this doc's capacity and `base_kw` and doc 03's price. Overlay must use **colour + icon**, never colour alone (constitution §11 / spec §49). `fuel_hours_left` is gone from the node payload — doc 04's generator panel owns it.

---

## 6. MVP Cut (spec §43, vertical slice)

**In the vertical slice:** variants `source` (subtype `river`, L1–2), `treatment` (L1–2), `pump` (L1–3), `tank` (L1–3) plus implicit `junction`s; mains `service` + `trunk`; derived pressure zones with tile BFS, per-tile factor and `hydrant_pressure_ratio` for doc 06; demand decomposition against doc 02's magnitudes and doc 01's two channels; grid dependency with pump trip/restart **and the backup module** (the headline cascade — do not cut it), with `coverage_frac` published to doc 04; tank drain/refill with buffer-hours UI; failures `pump_failure` + doc 06's `main_break` (fed by this doc's multipliers), power loss, capacity shortage; repair via `water_repair_truck` (depot L1–2) plus `isolate_main`; `water_service_factor_hour()` for doc 03; effects on happiness, output multiplier and the upgrade gate; water overlay + HUD `Water: NN%` + P1/P2 notifications; save section and offline catch-up at dt = 1 h.

**Deferred (Phase 2+), data present but gated by `feature_flags`:** freeze damage & insulation (ship the math, gate on winter weather); contamination beyond the flag + happiness penalty; `booster` variant, `source` subtype `well`, `arterial` mains, facility levels 4–5; `water_pump_truck` temporary supply, `water_heavy_truck`, `water_flood_response`; `water_restrictions` policy and `overhaul_node`; explicit hydrant placement, per-hydrant flow ratings, player-drawn pressure districts, drought/source depletion; sewage (never — spec §52).

### 6.1 The player verbs, as shipped (Wave 5)

This doc's `cmd_*` methods existed on `WaterSystem` from Wave 1 and nothing above them could reach one — the water system was a thing that happened *to* the player. It is now a thing they build. `sim/city_sim.gd` exposes four:

| verb | what it does |
|---|---|
| `cmd_place_water_component(kind, tile, level, preview)` | `source` (river) · `treatment` · `pump` · `tank`, at the levels §6's roster offers. **One command builds three things**, because they have never been separable: doc 02's `water_facility` SHELL (the building that decays, is maintained, is billed and is what doc 04 energises), this doc's NODE hosted on that shell's `power_ref` — exactly as `WTR-1` hosts three — and a `service` LATERAL from the nearest live main, because §2.2's connectivity is physical and a component sharing no tile with the network is its own dead zone. |
| `cmd_place_water_main(tiles, tier, preview)` | `service` and `trunk`. Reach, so the network can grow toward new ground ahead of the components that will sit on it. |
| `cmd_upgrade_water_component(node, preview)` | one level, gated on doc 04's power headroom (×1.15, the same margin doc 02 §2.11's upgrade check uses) — which is where the player meets the cascade from the supply side rather than the failure side. |
| `cmd_isolate_water_main` / `cmd_restore_water_main` | §2.12's tactical pair, surfaced verbatim. Neither is priced: the crew time is this doc's work content and no capital changes hands. |

**Check order** (first blocker is the reason code, the full list rides in `payload.blockers`, and `preview = true` quotes without charging): `E_UNKNOWN_COMPONENT` → `E_VARIANT_LOCKED` → `E_LEVEL_UNAVAILABLE` → `E_OUT_OF_BOUNDS` → `E_NOT_OWNED` → `E_NOT_DEVELOPED` → `E_CITY_LEVEL` → `E_FOOTPRINT` → `E_NO_WATER` → `E_NO_MAIN` → `E_UNSERVED` → `E_FUNDS` / `E_AUSTERITY`.

**The roster is data, not code.** `data/water.json` gains a `placeable` block (which variants, at which levels, sited how) and a `placement` block (`main_tap_radius_tiles` 8, mirroring doc 04's feeder tap radius at the same value and for the same reason — half a 16×16 land block). Neither carries a dollar or a capacity: footprints are the `components[variant][L]` columns already here, and **every price is doc 03's**, read at runtime from `data/economy.json`'s new `water` block. That block adds no new ladder either — a component is §2.13(a)'s `water_plant` anchor ($45,000, which IS this doc's L1 pump reference variant) walked up §2.3's own `capital_value()` / `upgrade_cost()` curves and scaled by this doc's dimensionless `variant_cost_ratio_l1`, exactly as C-16 has this doc contributing only `damage_fraction` to a repair. L1: source_river $37,800 · treatment $120,150 · pump $45,000 · tank $59,850.

**The surfaces, as shipped (Wave 10).** `cmd_place_water_component` reached the build sheet's `infrastructure` tab in Wave 5. `cmd_place_water_main` had no door at all until Wave 10 (doc 92 §17.6) and is now two cards on that same tab — `Water Main` (`service`) and `Trunk Main` — driven by doc 12 §2.7's **drag-path** tool: the player pins a start tile ON the existing network (§2.2's connectivity is physical, so `path[0]` is the tap), sweeps an L to the far end, and one `cmd_place_water_main` lays the whole run at `main_build_cost_per_tile[tier] x tiles`. The `arterial` tier is **not** offered while `levels_4_5_enabled` is off: a card that can never be placed is noise, not progression.

**The last three, Wave 11 (doc 93 §J1, doc 92 §28) — and there is no water-node panel.** The open question the paragraph above used to end on is answered by ruling that the screen it asked for should not exist: the three verbs are two verbs at two moments, and the moments decide the surface.

* **`cmd_upgrade_water_component` is on S5, the building panel of the SHELL that hosts the node.** §6.1's own first row is the reason: one command builds a doc-02 `water_facility` shell and the doc-05 node hosted on that shell's `power_ref`, so the site the player taps already has a panel and this is another purchase against the same asset. The block is a **list**, not a row — `WTR-1` hosts a source, a treatment train and a pump — with one row per node carrying §2.9's own `L1 L2 ▮L3▮` strip, the node's `kw_required` and `state`, and one button that quotes `cmd_upgrade_water_component(preview = true)`'s price with the whole gate (`E_MAX_LEVEL` → `E_LEVEL_UNAVAILABLE` → `E_POWER_HEADROOM` → `E_FUNDS`) under it. The ladder height a row draws is **this doc's `placeable_levels` clamped by `levels_4_5_enabled`** — `source` and `treatment` stop at 2, `pump` and `tank` at 3 — read at runtime, never authored in `ui/`. A `junction` draws a row that says it has no levels rather than a button that can only refuse (§2.1: a junction is where mains meet, not a component).
* **`cmd_isolate_water_main` / `cmd_restore_water_main` are on S6, the incident drawer's expanded row.** §2.12 describes the pair as trading a neighbourhood's taps for the fire's hydrants — a decision taken under time pressure, about a MAIN, and a main has no footprint and no panel. The only place a main is ever named to the player is doc 06's `water_main_break`, whose `target_ref` is `{kind: "water_segment", id}`. So the drawer row that is already telling them the main is open carries the valve, beside `ASSIGN`: **one control in two moods** (`ISOLATE` while the main is live, `RESTORE` once it is valved out), because the two are never both available.

**A player cannot strand a main.** §2.12's isolation is cleared by this doc's own repair path — `set_segment_repaired` sets `state` back to `ok`, and doc 06 calls it when the break resolves — so every main the drawer lets a player valve out un-valves itself when the crew finishes. **And isolation already persists**: `WaterEdge.serialize()` has carried `state` since Wave 1, so the surface needs no save-section bump. `tests/test_water_actions.gd` pins both.

**A node is born `offline_manual` and commissioned when its shell finishes.** §2.5's `is_live()` already refuses to count it, so a pump cannot pump while its building is a hole in the ground — and demolishing the shell retires the node and its own lateral, for the same reason doc 06's stations take their units with them.

---

## 7. Test Plan (headless, `tests/sim/water/`)

Every test constructs a `WaterSystem` with an injected clock, injected doc-01 channel values, injected doc-02 building rows and a seeded `failures` RNG, no scene tree. **All expectations below are recomputed in rescaled units (R-09/R-10).**

| # | Test | Assertion |
|---|---|---|
| 1 | `test_no_local_curves` | `data/water.json` contains **no** 24-entry array and no key matching `*_hourly` (C-33); the system reads `ctx.channels.water_demand_residential/commercial`; every `demand_split` row sums to 1.000 ± 0.001. |
| 2 | `test_demand_aggregation` | 10 × house L1 (doc 02 `W_b` 0.08, share res 1.00) + 2 × store L2 (`W_b` 0.30, shares 0.55/0.45) at h13 (res 1.075, com 1.65) → `res_base 0.80`, `com_base 0.33`, `proc_base 0.27` → `D == 0.80×1.075 + 0.33×1.65 + 0.27 == **1.6745** ± 0.0005 m³/h`. |
| 3 | `test_zone_partition` | Two pump/main clusters with no connecting main → exactly 2 zones; joining them with one main → 1 zone after `rebuild_zones()`. |
| 4 | `test_tile_factor` | Tile 0/2/5/12/13 tiles from a main → 1.0 / 1.0 / 0.70 / 0.0 / unserved(−1). |
| 5 | `test_pressure_full_supply` | `S > D`, tank 50 % → `P` converges to 1.0 within 20 ticks. |
| 6 | `test_tank_drain_exact` | Example A: from vol 108.0 at `D = 26.93`, after 3.00 game-hours at dt=1/240 → `volume == 27.21 ± 0.10`, `P == 1.0`; `level_frac` crosses 0.15 at `t == 3.34 h ± 0.02`; empty at `4.01 h ± 0.02`. |
| 7 | `test_tank_drain_offline_equivalence` | Same scenario at dt=1.0 h vs dt=1/240 h → tank volume agrees within 1.0 %, no negative volume, no overshoot above capacity. |
| 8 | `test_tank_low_head_factor` | `level_frac = 0.075` → `head_factor == 0.70`, `P == 0.70 ± 0.005`. |
| 9 | `test_refill_caps` | Refill never exceeds `max_inflow (26.5)` nor `capacity (120)`; Example B completes in **4.83 h ± 0.05**. |
| 10 | `test_power_dependency` | Pump L2 at `supply_fraction 0.6` → flow **55.86 ± 0.05**; at `0.30` → pump trips, flow 0; restoring power → flow still 0 for 5 game-minutes, then resumes. |
| 11 | `test_backup_coverage_published` | L2 node publishes `kw_required == 145`, `coverage_frac == 0.60`, `backup_kw == 87`; with doc 04 returning `power_output_multiplier == 0.60` the pump flows **55.86**. **No fuel assertion lives here** — runtime, burn and refuel are doc 04's tests (C-36). |
| 12 | `test_feed_capacity_bottleneck` | Pump L5 (1441) behind one `service` main (53.5) → `S == 53.5`; example F's L3 pump (228 after condition) behind a `trunk` (213) → `S == 213`. |
| 13 | `test_main_break_pressure` | Example C: `leak == 37.28 ± 0.02`; with doc 06 owning the break at tier 1 → `P == 0.85 ± 0.002`; with **no** owning incident the fallback gives `P == 0.916 ± 0.002` (C-46 both paths). |
| 14 | `test_isolation` | After `isolate_main`, leak 0, zone count increases, stranded tiles report `P_tile == 0`. |
| 15 | `test_fire_draw_cascade` | Registering 2 fire draws raises `D` by **16.0** and gives `hydrant_pressure_ratio == 0.765 ± 0.005` at the fire tile, from which doc 06's `hydrant_factor == 0.824 ± 0.005` (Example C). |
| 16 | `test_hydrant_ratio_contract` | Returns 0.0 for unserved tiles, never NaN, stays in [0, 1.2] over 10,000 random tiles; over-pressure only exceeds 1.0 when `S/D ≥ 1.5` and tanks ≥ 90 %. |
| 17 | `test_failure_determinism` | Same seed + same 500 game-hours → identical failure sequence (ids, tiles, severities) across two runs and across live-vs-offline stepping. |
| 18 | `test_freeze_multiplier` | −12 °C for 3 h → `freeze_stress == 1.8 ± 0.01`; published `freeze_mult == 5.50 ± 0.01`, `cond_mult == 1.54 ± 0.01` at condition 0.70; insulation 2 → stress ×0.10 → `freeze_mult == 1.45 ± 0.01`. |
| 19 | `test_repair_work_and_damage_fraction` | main_break severity 0.7 with `water_heavy_truck` → `work_minutes == 50×(0.6+0.56)/1.5 == 38.67 ± 0.01`; `damage_fraction == clamp(0.5+0.7) == 1.00`; frozen variant at severity 0.30 → `0.80 × 1.15 == 0.92`. **The system exposes no cost method** (C-16). |
| 20 | `test_effects_table` | `P` of 0.60/0.35/0.10/0.00 → penalties 0/−14.0/−32.1/−40.0 and output mults 1.00/0.65/0.29/0.15 (±0.05). |
| 21 | `test_abandonment_threshold` | `P = 0` for 35 h → no population loss; at 36 h → 0.5 %/h loss begins; restoring to 0.4 → counter decays. |
| 22 | `test_contamination_stub` | Treatment failure with forced roll → zone contaminated 720 min, happiness −12, `hydrant_pressure_ratio` unchanged. |
| 23 | `test_service_factor_hour` | §5.4's worked hour (20.4 min at P 1.00, 21.0 min ramping to 0.40, 18.6 min at 0) → `water_service_factor_hour == 0.585 ± 0.005`; identical at dt=1/240 and dt=1.0 h; a save/load mid-hour reproduces it exactly. |
| 24 | `test_variant_tables` | All six variant rows have exactly 5 levels; `components.pump.base_kw == [60,145,360,880,2160]` (doc 02's column, C-34/C-35); `rated_flow[L] == round_wu(40.0 × 2.45^(L−1))` for all L; `40.0 / 0.020 == 2000` residents per L1 facility. |
| 25 | `test_scale_invariance` | Re-running Example A with every flow/volume constant divided by `WU_SCALE 0.1333` yields identical pressures, ratios and buffer hours (±1e-4) — proves the applied rescale changed no behaviour. |
| 26 | `test_no_currency_and_no_curves` | Static scan of `data/water.json` + `sim/water/`: no key or literal carrying a dollar magnitude (C-07/C-16), no hourly curve (C-33), no `pressure_radius` / coverage-percentage term (C-06), no fuel constant (C-36). Fails loudly if a ruling is silently reverted. |
| 27 | `test_save_roundtrip` | Save → load → `rebuild_zones()` → all zone pressures, tank volumes, jobs and service accumulators identical (±1e-4); `migrate_water_v1_to_v2` maps `kind`→`variant` and drops the fuel fields. |
| 31 | `test_the_water_zone_sums_survive_the_round_trip_bit_for_bit` | **RR-60 / A91-D-30.** A founding city advanced 26 game-hours, saved and restored: every zone's `res_base`, `com_base` and `proc_base` compares equal under `is_same` — **bit-for-bit, not within a tolerance**, because the defect this guards was one ULP and every tolerance in the table above would have passed it. `building_count` too. |
| 32 | `test_a_water_section_without_zone_sums_still_loads` | Doc 08 §2.8 additive-first: a v3 section stamps `section_version: 3` and carries `demand.zone_sums`; erase the key, stamp the version back to 2, and the body still restores to a city with non-zero zone demand — the rebuild answers, exactly as it did before the rung existed. |
| 33 | `test_a_week_old_city_replays_from_its_save` | The whole property, and it lives in `tests/test_save_determinism_days.gd` rather than here because it is not a water test — it is the constitution's. Saves at 2 h, 26 h, 50 h (fine) and seven game-days (aged on the coarse path, the way a player ages a city), restores, advances two further game-hours and asserts an identical `state_hash()`, on the founding city and the benchmark city. |
| 28 | `test_no_engine_deps` | Static scan: no `Node`, `Engine`, `OS`, `Input`, `Time` references under `sim/water/`. |
| 29 | `test_perf_tick` | 120 zones / 600 mains / 20k developed tiles: `advance()` < 0.8 ms mean over 2,000 ticks; `rebuild_zones()` < 8 ms. |
| 30 | `test_starter_headroom_reference` | **RR-11 guard.** Load doc 09's starter manifest and doc 02's water column: Σ `water_demand` over the 18/5/3/1 + 6 civic buildings == **5.56 ± 0.01 m³/h**; against `components.pump[L1].rated_flow_m3h == 40.0` → headroom `40.0 / 5.56 == 7.19 ± 0.02`, and the quoted `_provenance._starter_reference` block matches doc 09 §2.9.4 to the digit. Fails loudly if either doc's manifest moves without the other's quoted figure moving — the stale-quote failure mode that produced the withdrawn 8.2 / 4.9×. |

---

## 8. Tunables — `data/water.json`

```json
{
  "schema_version": 2,
  "units": { "volume": "m3", "flow": "m3_per_game_hour", "head": "m", "power": "kW",
             "_note": "1 WU == 1 m3/h (report 98 C-34). No currency appears in this file." },

  "_provenance": {
    "applied_wu_scale": 0.1333,
    "_note": "Every flow/capacity/volume L1 anchor below = the pre-C-34 native value x 0.1333 (R-09). Levels 2-5 are generated on doc 02's k_dem = 2.45 standard-class curve with doc 02's rounding rules. base_kw = kw_per_m3h[variant] x capacity, which reproduces doc 02's water_facility kW column 60/145/360/880/2160 exactly.",
    "k_dem": 2.45,
    "_starter_reference": {
      "_owner": "doc 09 section 2.9.4 - quoted for cross-checking only, NOT owned or authored here (report 98 RR-11). The loader must not read these keys as sim inputs.",
      "starter_demand_m3h_mean": 5.56,
      "starter_demand_m3h_morning_peak": 7.10,
      "starter_supply_m3h": 40.0,
      "starter_headroom_x": 7.2,
      "_derivation": "18x0.08 + 3x0.48 + 5x0.13 + 1x0.32 + 0.19 + 0.40 + 0.96 + 0.16 = 5.56 against doc 02's post-C-34 water column on C-11's reverted 18/5/3/1 + 6 civic manifest; 40.0/5.56 = 7.194.",
      "_superseded": "8.2 m3/h / 4.9x - that was 51.1/6.25, the WU rescale of the pre-C-11 28/8/6/1 manifest with the mix revert never applied (verifier 96 F-5 / 97 F-05)."
    }
  },

  "global": {
    "res_per_capita_m3h_reference": 0.020, "job_per_capita_m3h_reference": 0.012,
    "hydrant_reach_tiles": 2, "max_service_distance_tiles": 12, "prox_falloff_per_tile": 0.10,
    "elev_penalty_per_m": 0.015, "elev_factor_floor": 0.30,
    "pressure_curve_exponent": 1.3, "pressure_tau_h": 0.05,
    "tank_low_frac": 0.15, "tank_low_head_floor": 0.40,
    "break_pressure_penalty_fallback": 0.12, "break_penalty_cap": 0.50, "leak_frac_of_capacity": 0.25,
    "fire_flow_per_engine_m3h": 8.0, "overpressure_bonus_max": 0.20,
    "pump_trip_fraction": 0.35, "pump_restart_minutes": 5.0,
    "shortage_warn_minutes": 20.0, "restriction_demand_mult": 0.75,
    "nominal_pressure": 0.60, "building_sample_interval_minutes": 1.0,
    "kw_per_m3h": { "pump": 1.50, "treatment": 0.50, "source_river": 0.30, "source_well": 0.75,
                    "booster": 1.50, "tank_anchor_kw": 5.0 }
  },

  "demand_split": {
    "_note": "Shares of doc 02's published water_demand, routed to doc 01's residential / commercial channels and to flat process load. Rows sum to 1.000. This is the surviving form of the per-archetype process split (C-33); the magnitude is doc 02's and appears nowhere here.",
    "house":             { "res": 1.00, "com": 0.00, "proc": 0.00 },
    "apartment":         { "res": 0.88, "com": 0.05, "proc": 0.07 },
    "store":             { "res": 0.00, "com": 0.55, "proc": 0.45 },
    "office":            { "res": 0.00, "com": 0.73, "proc": 0.27 },
    "high_rise":         { "res": 0.73, "com": 0.11, "proc": 0.16 },
    "data_center":       { "res": 0.00, "com": 0.03, "proc": 0.97 },
    "police_station":    { "res": 0.00, "com": 0.52, "proc": 0.48 },
    "fire_station":      { "res": 0.00, "com": 0.34, "proc": 0.66 },
    "power_facility":    { "res": 0.00, "com": 0.07, "proc": 0.93 },
    "substation":        { "res": 0.00, "com": 0.00, "proc": 1.00 },
    "water_facility":    { "res": 0.00, "com": 0.00, "proc": 1.00 },
    "construction_yard": { "res": 0.00, "com": 0.42, "proc": 0.58 },
    "_post_mvp": {
      "factory":   { "res": 0.00, "com": 0.10, "proc": 0.90 },
      "warehouse": { "res": 0.00, "com": 0.55, "proc": 0.45 },
      "hospital":  { "res": 0.35, "com": 0.25, "proc": 0.40 },
      "school":    { "res": 0.00, "com": 0.45, "proc": 0.55 },
      "stadium":   { "res": 0.20, "com": 0.30, "proc": 0.50 }
    },
    "stadium_event_process_mult": 4.0
  },

  "_component_columns": {
    "source_river": ["level","yield_m3h","base_kw","footprint_w","footprint_h"],
    "source_well":  ["level","yield_m3h","base_kw","footprint_w","footprint_h"],
    "treatment":    ["level","throughput_m3h","base_kw","footprint_w","footprint_h"],
    "pump":         ["level","rated_flow_m3h","base_kw","head_m","footprint_w","footprint_h"],
    "tank":         ["level","capacity_m3","max_inflow_m3h","max_outflow_m3h","head_m","base_kw","footprint_w","footprint_h"],
    "booster":      ["level","boost_flow_m3h","head_bonus_m","base_kw","footprint_w","footprint_h"]
  },
  "components": {
    "source_river": [[1,107,32,2,2],[2,262,79,2,2],[3,642,195,3,3],
                     [4,1574,470,3,3],[5,3855,1160,4,4]],
    "source_well":  [[1,66.5,50,1,1],[2,163,120,1,1],[3,399,300,2,2],
                     [4,978,735,2,2],[5,2396,1800,3,3]],
    "treatment":    [[1,80.0,40,2,2],[2,196,98,3,3],[3,480,240,3,3],
                     [4,1176,590,4,4],[5,2882,1440,4,4]],
    "pump":         [[1,40.0,60,34,3,3],[2,98.0,145,38,3,3],[3,240,360,42,3,3],
                     [4,588,880,46,3,3],[5,1441,2160,52,4,4]],
    "tank":         [[1,120,26.5,66.5,30,5.0,2,2],[2,294,65.0,163,32,12,2,2],
                     [3,720,159,399,35,30,3,3],[4,1765,390,978,38,74,3,3],
                     [5,4324,955,2396,42,180,4,4]],
    "booster":      [[1,8.0,25,12,1,1],[2,19.5,34,29,1,1],[3,48.0,44,72,1,1],
                     [4,118,56,175,2,2],[5,288,70,430,2,2]]
  },

  "mains": {
    "service":  {"capacity_m3h":53.5, "break_rate_mult":1.0},
    "trunk":    {"capacity_m3h":213,  "break_rate_mult":0.6},
    "arterial": {"capacity_m3h":640,  "break_rate_mult":0.5},
    "insulation_levels": [1, 2]
  },

  "backup": {
    "_note": "This doc owns coverage_frac and the backup_kw sizing input (C-36). Doc 04 owns the generator: fuel, burn rate, tank size, start delay, refuelling, state and events. Doc 03 owns the price.",
    "coverage_frac": { "1": 0.00, "2": 0.60, "3": 0.70, "4": 0.85, "5": 1.00 },
    "backup_kw": {
      "source_river": { "2": 47,  "3": 135, "4": 400, "5": 1160 },
      "source_well":  { "2": 72,  "3": 210, "4": 625, "5": 1800 },
      "treatment":    { "2": 59,  "3": 170, "4": 500, "5": 1440 },
      "pump":         { "2": 87,  "3": 250, "4": 750, "5": 2160 },
      "tank":         { "2": 7.0, "3": 21,  "4": 63,  "5": 180 },
      "booster":      { "2": 17,  "3": 50,  "4": 150, "5": 430 }
    }
  },

  "price_inputs": {
    "_note": "Dimensionless ratios ONLY. Doc 03 is the sole currency authority (C-07) and prices every water asset from its build_cost_l1.water_plant = 45,000 anchor, which is the L1 pump reference variant. This doc authors no dollar figure; the deleted build_cost / maintenance_per_hour / cost_per_tile / base_cost / flush_cost / overhaul_cost_frac columns lived here and now live in doc 03 sections 2.3 / 2.5 / 2.13.",
    "variant_cost_ratio_l1": { "source_river": 0.84, "source_well": 1.16, "treatment": 2.67,
                               "pump": 1.00, "tank": 1.33, "booster": 0.78 },
    "main_cost_ratio_per_tile": { "service": 1.00, "trunk": 2.81, "arterial": 7.50 },
    "insulation_cost_ratio_per_tile": { "1": 0.34, "2": 0.81 },
    "flush_cost_frac_of_capital": 0.125
  },

  "failures": {
    "base_rate_per_hour": { "main_break": 0.000040, "pump_failure": 0.001500,
                            "treatment_failure": 0.000900, "source_failure": 0.000300,
                            "_main_break_note": "fallback / calibration reference only - doc 06 owns the roll (C-46)" },
    "cond_mult_k": 6.0, "main_load_mult_knee": 0.85, "pump_load_mult_knee": 0.95,
    "load_mult_gain": 1.5, "age_mult_per_60_days": 0.15, "age_mult_cap": 2.0,
    "freeze_hazard_gain": 2.5, "freeze_mult_cap": 6.0,
    "weather_failure_mult": { "thunderstorm": 1.20, "flood": 1.80, "heat_wave": 1.15, "blizzard": 1.10 },
    "severity_base": 0.25, "severity_random": 0.60, "severity_condition_gain": 0.20,
    "freeze": { "threshold_c": -6.0, "stress_gain_div": 10.0, "thaw_rate_per_hour": 0.5,
                "insulation_reduction_per_level": 0.45, "break_base": 0.0020,
                "exposed_pump_temp_c": -12.0, "exposed_pump_mult": 2.0 },
    "condition_decay_per_hour": { "main": 0.000060, "pump": 0.000100, "treatment": 0.000080,
                                  "tank": 0.000030, "source": 0.000060, "booster": 0.000090 },
    "maintenance_decay_curve": { "at_zero_funding": 2.5, "gain": 1.5 }
  },

  "repair": {
    "base_minutes": { "main_break": 50, "freeze_break": 50, "pump_failure": 90,
                      "treatment_failure": 180, "source_failure": 120, "isolate_main": 8, "overhaul": 240 },
    "damage_fraction": { "_formula": "clamp(0.5 + severity, 0, 1) * frozen_mult, clamped to [0,1] - the conversion doc 03 published for this doc (C-16)",
                         "severity_base": 0.5, "severity_gain": 1.0, "frozen_mult": 1.15 },
    "severity_floor": 0.6, "severity_gain": 0.8,
    "mods": { "frozen": 1.6, "flooded": 1.4, "night": 1.1 },
    "crew_mult": { "water_repair_truck": 1.0, "water_pump_truck": 0.8,
                   "water_heavy_truck": 1.5, "water_flood_response": 1.0 },
    "post_repair_condition": { "main_break": 0.85, "freeze_break": 0.80, "pump_failure": 0.90,
                               "treatment_failure": 0.90, "source_failure": 0.90, "overhaul": 1.00 },
    "temp_supply_m3h": 16.0, "temp_supply_hours": 10
  },

  "effects": {
    "happiness_penalty_max": 40.0, "happiness_pressure_ref": 0.60, "happiness_exponent": 1.2,
    "output_mult_floor": 0.15, "output_pressure_ref": 0.60, "upgrade_min_pressure": 0.55,
    "upgrade_headroom_safety": 1.10,
    "health_decay_start_hours": 12.0, "health_decay_per_hour": 2.0,
    "abandon_hours": 36.0, "abandon_rate_per_hour": 0.005,
    "no_water_pressure_threshold": 0.10, "recovery_pressure_threshold": 0.35,
    "no_water_counter_decay_per_hour": 4.0,
    "bands": { "normal": 0.60, "warn": 0.35, "critical": 0.10 }
  },

  "contamination": {
    "on_treatment_fail_chance": 0.35, "on_flood_source_chance": 0.50, "base_minutes": 720,
    "flush_minutes": 360, "happiness_penalty": 12.0,
    "commercial_output_mult": 0.90, "hospital_service_mult": 0.85
  },

  "overlay": {
    "quantize_steps": 255, "refresh_cadence": "EVERY_TICK",
    "notification_priority": { "water_tank_empty": 1, "water_zone_offline": 1,
                              "water_main_break": 2, "water_pump_failed": 2,
                              "water_tank_low": 2, "water_capacity_shortage": 2,
                              "water_contamination_started": 2, "water_repair_completed": 3 }
  },

  "feature_flags": { "freeze_enabled": false, "contamination_enabled": true,
                     "boosters_enabled": false, "restrictions_enabled": false,
                     "levels_4_5_enabled": false, "source_well_enabled": false }
}
```

**Constants that used to live here and no longer do** (report 98) — a reader looking for them should look in the doc named:

| Deleted | Ruling | Now read from |
|---|---|---|
| `residential_hourly`, `commercial_hourly`, `industrial_flat` | C-33 | doc 01 `data/time.json` channels `water_demand_residential` / `water_demand_commercial` |
| `weather_demand_mult` (12 rows) | C-57 / C-34 | doc 07 `weather.get_effect("water_mult")`, pre-applied inside doc 02's `water_demand` |
| `idle_demand_frac` | C-34 | doc 02 `STATE_DEMAND[state]` |
| `process_demand_m3h` (absolute m³/h per archetype × level) | C-33 / C-34 | magnitude is doc 02's `water_demand` column; only the `demand_split` shares remain here |
| `build_cost`, `maintenance_per_hour`, `cost_per_tile`, `maintenance_per_tile_hour`, `insulation_upgrade` costs | C-07 | doc 03 §2.13 `build_cost_l1.water_plant = 45,000` + `CostCurves`; upkeep is doc 03's `E_water` |
| `repair.base_cost` (5 rows), `overhaul_cost_frac`, `flush_cost` | C-16 | doc 03 §2.5 `repair_cost = capital_value × damage_fraction × 0.85 × M_repair` |
| `chem_cost_per_m3` | C-07 | doc 03 `WATER_TREAT_COST_PER_M3 = 0.06` (same value, single owner) |
| `fuel_l_per_kwh`, `fuel_price_per_l`, `fuel_capacity_l`, `backup_start_minutes` | C-36 | doc 04 §2.10 `backup` (fuel model) + doc 03 (diesel at $95/MWh) |
| `booster_kw` (flat 40), `kw_per_m3h_*` native coefficients | C-34 / C-35 | per-variant `base_kw` tables above; `global.kw_per_m3h` is the generating rule |
| `wu_scale_if_doc02_adopted` | C-34 | applied, not conditional — recorded in `_provenance.applied_wu_scale` |
| doc 02's `pressure_radius_tiles`, `water_supply_wu_per_hour` | C-06 / C-35 | the pressure-zone graph (§2.2) and the per-variant capacity tables above |

---

## 9. Conflicts & Open Questions

### Conflicts with the constitution
1. **None material.** Water uses the shared `failures` RNG stream (§5), reads no wall clock (§4), keeps every number in `data/water.json` (§3), runs as pure `RefCounted` sim code (§3), and models coverage as a graph rather than a radius (§8, and see the C-06 note in §2.2). Two scheduler requirements, not deviations: (a) a *per-game-hour* hook so live and offline stepping are identical; (b) intra-step ordering P06 POWER → **P07 WATER** → P08 ROADS, both of which doc 01 provides.

### Conflicts resolved by report 98 (recorded, not open)
2. **Scale vs doc 02** — **RULED (C-34), APPLIED.** `1 WU ≡ 1 m³/h`; doc 02 ÷ 6.25, doc 05 × 0.1333 on every flow/capacity/volume anchor, L2–L5 regenerated on doc 02's `k_dem 2.45`, doc 02's kW column adopted (and reproduced exactly by `1.50 kW per m³/h`). 2,000 residents per L1 facility, verified two ways in §2.4.
3. **`pressure_radius_tiles`** — **RULED (C-06).** Deleted from doc 02; pressure zones replace it. §2.2 states why the two tile distances that remain are attachment distances and not coverage percentages.
4. **Main breaks** — **RULED (C-46).** Doc 06 owns the roll and multiplies this doc's `cond_mult` / `load_mult` / `freeze_mult` into its rate; doc 06's tiered `zone_pressure_delta` wins; the flat `0.12 × severity` survives as `break_pressure_penalty_fallback` for breaks with no owning incident (empty set in MVP, non-empty in the standalone test harness).
5. **`coverage_frac` and generator fuel** — **RULED (C-35, C-36).** Doc 02 owns the shell and variant list, this doc owns every per-variant number including `coverage_frac`, doc 04 owns generator fuel and refuelling for all backup-capable sinks, doc 03 owns every price.
6. **Doc 04 is feeder-shed, not fractional-supply.** `power_output_multiplier` returns 1.0 / `coverage_frac` / 0.0, so §2.6's derating only fires via backup coverage. Recorded so nobody implements a fractional grid read doc 04 will not provide.
7. **Doc numbering** — **RULED (Ruling Zero).** On-disk filenames are canonical; §5 is renumbered accordingly and this doc references no other map.
8. **Two curve stores** — **RULED (C-33).** Doc 01 owns both channels; this doc keeps only the split.
9. **Doc 09 must provide `elev_m(tile)` in metres.** If terrain ends up categorical, replace §2.3's elevation term with low 1.0 / mid 0.85 / high 0.65. Still open on doc 09's side; harmless either way.

### Open questions for the overseer
10. **Is a ~4 real-minute tank buffer the right live-play window?** After the rescale an L1 tank holds 120 m³ against a 26.9 m³/h zone — 4.0 game-hours ≈ 4 real minutes at 60×, up slightly from the pre-rescale 3.4 h because doc 01's residential channel peaks at 1.333 rather than this doc's old 1.65. I recommend keeping it and letting player-built redundancy extend it, but it is the single knob that decides whether water failures feel tense or unfair.
11. **`damage_fraction` saturates at severity ≥ 0.5.** Doc 03 published the conversion `clamp(0.5 + severity, 0, 1)` and this doc adopted it verbatim (C-16), but the severity roll has a mean near 0.6, so most repairs are billed at full capital × 0.85. If playtest says repairs sting, doc 03 should re-read the conversion as `clamp(0.35 + 0.65 × severity, 0, 1)` — a doc 03 decision, not a doc 05 one, and no number here changes.
12. **Doc 03 §2.12's starter `pump O&M $5/gh`** — **RULED and closed (RR-6).** `E_water`'s `pump_capacity_m3h × 0.35` against one L1 pump (40 m³/h) is **$14/gh**, and report 98 RR-6 puts that line into doc 03's re-run starter ledger. This doc supplies the inventory (one L1 duty pump, 40 m³/h) and asserts no dollar. Recorded, not open.
13. **Water bills as revenue (spec §11.1)?** The model tracks delivered volume and doc 03 already prices it at `WATER_TARIFF_PER_M3 0.55`. Confirming the loop is closed rather than proposing anything.
14. **Freeze in MVP?** The math is cheap and the winter cascade (blizzard → lines down → pump off → mains freeze → breaks the crews cannot reach) is one of the best stories the systems can generate. Gated off because the MVP disaster is a thunderstorm; worth reconsidering for early Phase 2 now that the hazard is a single multiplier doc 06 consumes.
15. **This doc's starter water figure was stale until RR-11 — recorded, not open, so the failure mode is not repeated.** §2.13 carried report 98's own **8.2 m³/h / 4.9×**, which rescaled the pre-C-11 28/8/6/1 manifest without also applying C-11's revert to 18/5/3/1. Corrected to doc 09 §2.9.4's **5.56 m³/h / 7.2×** in §2.4, §2.13 and §2.14, and guarded by test 30. The verifiers' general remedy (96 §3) is adopted here: every figure this doc quotes but does not own now carries a `⟨owner: doc NN §X⟩` tag.
16. **Should `treatment` and `source` be separate placeables in MVP,** or should the MVP `water_facility` be a combined source+treatment+pump+tank that splits into variants at city level 3? The latter is gentler onboarding (spec §41 wants water connected in tutorial step 4) and is my recommendation if the vertical slice feels cluttered. C-35 makes either possible without a schema change.

---

## 10. Amendments applied (report 98)

| Ruling | Change |
|---|---|
| **Ruling Zero** | Every cross-doc reference renumbered to the canonical on-disk filenames; §5 restructured in canonical order (01, 02, 03, service contract, 04, 06, 07/08/09/10, 12) and the old "doc 06 numbers buildings as 03" note deleted. |
| **C-06** | Pressure zones stated as the sole water coverage model; doc 02's `pressure_radius_tiles` recorded as deleted; §2.2 adds an explicit note on why `hydrant_reach_tiles` / `max_service_distance_tiles` are physical attachment distances to a live main and not coverage percentages. |
| **C-16** | The `repair.base_cost` table and `base_cost[type] × (0.5 + severity)` **removed**; this doc now publishes `damage_fraction = clamp(0.5 + severity, 0, 1) × 1.15 if frozen` and calls `economy.repair_cost()`. `overhaul_cost_frac` and `flush_cost` removed the same way (overhaul → `damage_fraction = 1 − condition`; flush → dimensionless `flush_cost_frac_of_capital 0.125`). |
| **C-33** | `residential_hourly` and `commercial_hourly` **deleted**; the system reads doc 01's `water_demand_residential` / `water_demand_commercial`. The per-archetype process split survives as `demand_split` shares (res/com/proc, summing to 1.000) against doc 02's magnitude. `weather_demand_mult` and `idle_demand_frac` deleted as double-counts of doc 07 and doc 02. |
| **C-34 / R-09** | The rescale is **applied**, not described: every flow/capacity/volume L1 anchor × `WU_SCALE 0.1333`, L2–L5 regenerated on doc 02's `k_dem 2.45`, doc 02's kW column adopted (and reproduced exactly by `1.50 kW per m³/h`), `1 WU ≡ 1 m³/h` throughout, `fire_flow_per_engine` 60 → **8.0**, mains 400/1600/4800 → **53.5/213/640**, L1 pump **40.0 m³/h = 2,000 residents** verified two ways. |
| **C-34 / R-10** | Worked examples **A–F all recomputed** in rescaled units against doc 01's channel values: A buffer 4.01 gh, B refill 4.83 gh, C leak 37.28 with doc 06's tier-1 delta (P 0.85, hydrant ratio 0.765), D 145 kW / 87 kW backup / flow 55.86, E `freeze_mult` 5.50 reproducing the old standalone hazard, F rebuilt as the E_WATER_HEADROOM block + trunk-main min-cut. Every test expectation that used an old number is recomputed, not deleted. |
| **C-35** | This doc now owns the five `water_facility` variants' numbers: per-variant `base_kw`, capacity/volume/head, footprint and `coverage_frac`, five levels each, with `pump` as the reference variant matching doc 02's shell; node kinds renamed to doc 02's variant ids (`source`/`treatment`/`pump`/`tank`/`booster`, `junction` declared non-building). |
| **C-36** | `coverage_frac = [—, 0.60, 0.70, 0.85, 1.00]` and per-variant `backup_kw` published to doc 04; **all** generator fuel fields, the start delay, the `refuel_backup` command, the `auto_refuel_backup` policy, the save-state fuel fields and the two backup events removed to doc 04. |
| **C-37** | §5.4 added: `water_service_factor_hour(building_id)`, a time-weighted `clamp(P/0.60)` accumulator settled each game-hour, persisted mid-hour in `service_accum`, with a worked hour (0.585 → doc 03's `f_water` 0.772) and test 23. |
| **C-46** | Doc 06 owns the break roll; this doc publishes `cond_mult`, `load_mult` and the new `freeze_mult` (calibrated `FREEZE_HAZARD_GAIN = 2.5`, arithmetic shown) through `water.mains()`; doc 06's tiered `zone_pressure_delta` wins and the flat penalty is renamed `break_pressure_penalty_fallback`. |
| **C-07 (by extension)** | Not listed for this doc in report §12, but C-07 makes doc 03 the sole currency authority and report §13 blocks "anything with a price on it": every dollar figure in §8 (component `build_cost`, `maintenance_per_hour`, main `cost_per_tile`, insulation costs, `chem_cost_per_m3`) is **removed** and replaced by the dimensionless `price_inputs` ratios doc 03 needs. `build_cost_l1.water_plant = $45,000` already equals this doc's deleted L1 pump figure, so no magnitude moved. |
| **C-25** | No action — this doc already used `section_version`; it is not in the rename list. The key is bumped 1 → 2 for the schema changes above, with `migrate_water_v1_to_v2` specified. |
| **C-02 (constitution)** | Cadence language changed from "4 Hz" to the game-time cadence `EVERY_TICK` (15 game-seconds), equal to 4 Hz only at 1× speed. |

### Round 2 (report 98 §14 — post-verification rulings)

| Ruling | Change |
|---|---|
| **RR-11** | **Starter water demand restated as doc 09 §2.9.4's `5.56 m³/h` against `40 m³/h` of L1 supply = `7.2×` headroom**, replacing the withdrawn `8.2 m³/h / 4.9×` (which was `51.1 / 6.25` — the C-34 rescale of the *pre*-C-11 28/8/6/1 manifest, with C-11's revert to 18/5/3/1 never applied; verifier 96 F-5 / 97 F-05). Applied in **§2.4** (new starter anchor, cell-by-cell derivation `18×0.08 + 3×0.48 + 5×0.13 + 1×0.32 + 0.19 + 0.40 + 0.96 + 0.16 = 5.56`, `40.0/5.56 = 7.194 → 7.2×`, plus the morning-peak reading `40.0/7.10 = 5.6×` and two independent cross-checks), **§2.13** (the stale line replaced and an explicit withdrawal note added), **§2.14** (scale note relating the illustrative zones to the real starter city), **§8** (`_provenance._starter_reference`, tagged as doc 09's number and not a sim input), **§7 test 30** (`test_starter_headroom_reference`, a mechanical guard against the quote drifting again) and **§9 item 15** (the failure mode recorded). No formula, constant, ladder, curve or example in this doc changes — the corrected figure is a *quotation*, and every water number this doc owns was already scale-correct. |
| **RR-6 (consumed, not amended here)** | Doc 03's starter ledger adopts the `E_water` pump O&M line this doc derived (`40 m³/h × 0.35 = $14/gh`, not `$5/gh`). §2.13's downstream note and §9 item 12 now record it as ruled and closed rather than "flagged for the R-16 pass". This doc still asserts no dollar figure. |
