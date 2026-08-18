# 04 — Electrical Grid Simulation

**Status:** Amended per `98-consistency-report.md` (binding rulings applied — round 1 §1–§13 and round 2 §14; see §10). Complies with `00-constitution.md` (LOCKED).
**Spec source:** BLACKOUT-spec §13, §26, §34, §52. **Owns:** `sim/power/`, `data/power.json`, save section `power`.
**Doc numbering:** the on-disk filenames are canonical (report 98 Ruling Zero). Every cross-reference in this doc uses them.

---

## 1. Overview & Goals

The grid is the load-bearing system of SLACUM CITY: the first thing the player builds, the first thing that overloads, and the system whose failure feeds water, traffic, lighting, crime, and fire suppression. Constitution §8 / Core Rule 10: *utilities are systems, not meters.*

1. **A real graph.** Individually placed plants, substations, feeders, transformers and tie switches, each carrying capacity, load, condition and temperature (spec §13.2).
2. **Failure is earned and legible.** Every failure traces to a number the player could have seen — a load ratio, a winding temperature, a missing tie line (Core Rule 12).
3. **Cascades emerge from data.** One trip transfers load; the transfer overloads a neighbour; the neighbour trips. No scripted chains (spec §34).
4. **4 Hz on a phone.** Four linear passes over struct-of-arrays state, ≤0.4 ms/tick at 1,500 components.
5. **Explicitly NOT electrical engineering** (spec §52). No voltage, phase, impedance, reactive power or AC solve. Capacity is a scalar kW throughput budget propagated down a tree. Stated here so nobody "improves" it into a Newton–Raphson load flow later.

**Loop position:** growth → demand → load ratio → temperature → failure hazard → incidents → crews and money → capacity or redundancy → growth.

**What this doc does *not* own, after report 98.** Money (doc 03 — every price, upkeep, fuel price and repair charge), building demand anchors (doc 02 — `base_kw` per archetype per level), building footprints (doc 02), diurnal demand shapes (doc 01 — `ctx.channels.power_demand_*`), incident *generation* from storms (doc 06), lightning strike generation and target selection (doc 07), the traffic-signal congestion penalty (doc 10). This doc owns every electrical **capacity, topology, thermal, protection, service and inventory** number, and nothing else.

---

## 2. Mechanics

### 2.1 Topology

```
            [ BULK POOL ]   all generation summed — "copper plate" simplification
             |          |
   TRANSMISSION LINK   TRANSMISSION LINK        per-link capacity, damageable
             |          |
        [SUBSTATION]  [SUBSTATION]              tree root; N feeder slots
          /   |   \
     FEEDER FEEDER FEEDER                       tile polyline; overhead or underground
        |      |
   TRANSFORMER TRANSFORMER ──(tie switch, normally open)── TRANSFORMER on another feeder
        |
   SERVICE POINTS → buildings + street-lighting + traffic signals
```

- **Bulk pool.** Generation is not routed per plant; all online output sums to one system supply figure. Only each substation's own transmission link capacity is enforced individually. Keeps the solve O(N) and honours spec §52.
- **Radial trees.** Each substation roots a tree; a feeder belongs to exactly one substation at a time. Tie switches are normally-open edges that re-parent a feeder to a different substation (§2.9).
- **Feeders and transmission links are node objects** with `route: Array[Vector2i]`, not abstract edges — they need capacity, temperature, condition and a physical location for lightning/wind/flood targeting.
- **Service attachment.** A building attaches to the nearest transformer whose `service_radius_tiles` covers its origin tile, tie-broken by lowest load ratio. None in range ⇒ `UNSERVED` (never energized; placement UI blocks it).
- **Transformers, feeders, transmission links, ties and backup generators are grid components, not buildings** (report 98 C-30). They are never placed through `place_building`, never appear in `data/buildings.json`, and carry no `footprint` — a transformer occupies exactly one tile as grid geometry. Plants and substations *are* buildings (`power_facility`, `substation` in doc 02) and take their **footprint from doc 02 §2.3**; this doc supplies only their electrical numbers.

**Line routing is player-drawn** (report 98 C-41, closing this doc's former open question 9). Drag-path placement is the primary interaction — it is what makes undergrounding and storm exposure real decisions — with a **"route along roads" assist button** that fills the polyline automatically from the player's two endpoints. The player still confirms the filled path before it is committed, and may edit it tile by tile afterwards. `suggest_route_along_roads(from, to)` is a pure query (§4); it is never applied without a confirming command.

### 2.2 Component stat ladders

kW throughput and the **inventory quantities doc 03 bills against** (report 98 C-12). **§8 is authoritative**; this is the readable summary, L1→L5 left to right.

**Prices, upkeep and fuel cost are not in this doc.** Build cost, the recurring `E_grid` charge and generation fuel price all live in **doc 03 §2.4 / §2.13(b)** and `data/economy.json`; a reader looking for a dollar figure looks there.

| kind | capacity kW | inventory published to doc 03 | notes |
|---|---|---|---|
| `plant_gas` | 8k / 18k / 36k / 70k / 120k | `plant_capacity_mw` 8 / 18 / 36 / 70 / 120 | `plant_efficiency_mult` 1.000 / 0.935 / 0.871 / 0.806 / 0.758; overhaul 240→480 gm; footprint per doc 02 `power_facility` |
| `plant_solar` | 2k / 5k / 10k / 20k / 36k nameplate | `plant_capacity_mw` 2 / 5 / 10 / 20 / 36 | output = nameplate × sun × cloud (§2.7.6) |
| `plant_wind` | 3k / 7k / 14k / 26k / 45k nameplate | `plant_capacity_mw` 3 / 7 / 14 / 26 / 45 | wind curve; **cutout >24 m/s** |
| `substation` | 6k / 14k / 30k / 60k / 110k | `rated_mva` 6 / 14 / 30 / 60 / 110 | feeder slots 2/3/4/6/8; fault repair 115→215 gm; footprint 2×2 at every level per doc 02 |
| `transformer` | 50 / 150 / 400 / 1,000 / 2,500 | `rated_mva` 0.05 / 0.15 / 0.40 / 1.00 / 2.50 | service radius 3/4/5/6/8 tiles; swap 18/18/26/38/55 gm; occupies 1 tile as grid geometry |
| `feeder` cls 1–3 | 1,200 / 3,000 / 7,500 | `line_km` = route tiles × 0.008 | underground ×2.6 cost (doc 03 applies it), ×2.2 repair time, immune to wind + lightning, flood-vulnerable |
| `transmission` cls 1–3 | 40k / 90k / 180k | `line_km` = route tiles × 0.008 | repair 60 gm + 2 gm/tile |
| `backup_gen` S/M/L | 150 / 600 / 2,500 | *not* in the `plants` inventory — building equipment, billed by doc 03 as capital + diesel | tank 8/16/48 gh; `fuel_efficiency_mult` 1.000 / 0.905 / 0.810 |
| `battery` (post-MVP) | 1k / 2.5k / 6k / 14k / 30k | `rated_mva` 1 / 2.5 / 6 / 14 / 30 | 4k→120k kWh, 0.88 round-trip |

**Inventory definitions** (the contract doc 03's `E_grid` reads, report 98 C-12):
```
rated_mva(node)        = capacity_kw / 1000          # unity power factor by the §1.5 simplification
plant_capacity_mw(gen) = capacity_kw / 1000          # nameplate for renewables, not instantaneous output
line_km(line)          = route_tiles × 8 m / 1000 = route_tiles × 0.008     # constitution §6
condition(component)   ∈ [0,1]                       # §2.6
```
`node` = substations **and** transformers. Nothing in this doc bills a flat per-component rate in parallel; that double-billing is exactly what C-12 removed.

**Worked inventory — the starter city** (report 98 RR-6; the manifest is doc 09 §2.9.5's, the rates are doc 03 §2.4's, this doc supplies only the middle column):

```
plant_capacity_mw   1 × plant_gas L1                          =  8.00 MW
rated_mva (sub)     1 × substation L1                         =  6.00 MVA
rated_mva (xfmr)    13×0.05 + 9×0.15 + 1×0.40                 =  2.40 MVA
line_km             (147 feeder + 30 transmission) × 0.008    =  1.416 km
condition           every component at t0                     =  1.0

E_grid  = 8.00 × 5.0  +  6.00 × 4.0  +  2.40 × 4.0  +  1.416 × 0.9
        = 40.000      +  24.000      +  9.600       +  1.274
        = $74.874/gh  →  ≈ $74.9/gh          (doc 03 computes this; the figure is quoted, not owned)
```
The superseded 14 × L1 + 9 × L2 / 110-tile set (`rated_mva 2.05`, `line_km 0.88`, `E_grid $73`) is **deleted** — it predates doc 09's R-16 topology. Owner of the counts: **doc 09 §2.9.5**; owner of the rates and the sum: **doc 03 §2.4**.

Component upgrades (not level ladders): **surge arrester** on substation/transformer/feeder, levels 0–3, −22% lightning damage probability per level. **Flood wall** on substations, levels 0–2, +0.6 m immunity depth per level. Both are priced by doc 03 §2.13(b).

### 2.3 Demand model

```
demand_kw = base_kw[type][level]                      # doc 02 §2.3 `Pwr kW` column — the only source
          × occupancy_factor                          # 0..1, doc 09 (population / jobs filled)
          × ctx.channels.power_demand_<class>         # doc 01 §2.6, normalized, 24-h mean 1.000
          × weather_mult(class)                       # §2.7.1
          × event_mult                                # stadium event day 3.2, else 1.0
          × (1 - efficiency_bonus)                    # research/policy, 0 in MVP
demand_kw = min(demand_kw, base_kw × 2.2)             # demand_mult_cap
```

**`base_kw` is owned by doc 02** (report 98 C-31). This doc's former reference table is **deleted** — a reader wanting a kW anchor reads doc 02 §2.3's `Pwr kW` column, which is generated on doc 02's `k_dem` curve family (2.35 steady / 2.45 standard / 2.55 vertical, report 98 C-13). Every worked example and test below is computed against that column.

**Diurnal shape is owned by doc 01** (report 98 C-32). This doc's former `demand.tod_curves` block is **deleted**; `data/time.json` is the only diurnal curve store in the project. The grid's job is the class → channel map:

| doc 02 archetype | demand class | channel read from `ctx.channels` |
|---|---|---|
| `house`, `apartment`, `high_rise` | RES | `power_demand_residential` |
| `store`, `office` | COM | `power_demand_commercial` |
| `construction_yard` | IND | `power_demand_industrial` |
| `police_station`, `fire_station`, `water_facility` (all variants), `power_facility` | CIV | `power_demand_civic` |
| `data_center` | DC | `power_demand_datacenter` (flat 1.0) |
| `substation` | — | no service draw (station service is inside `capacity_kw`) |

Doc 01 populated `power_demand_civic` by normalizing this doc's retired CIV shape (24-hour mean 0.959 → factor **1.0426**) and `power_demand_datacenter` as flat 1.0. Those two channels now live in `data/time.json` and this doc stores no copy.

**Distributed sinks.** Each **road tile** draws `0.35 kW × ctx.channels.streetlight_load` (doc 01's absolute 0–1 lighting channel, 1.00 from 19:00 to 07:00); each **road-graph intersection** draws `0.6 kW` continuously. Both attach to their nearest transformer. This is what makes a blackout visible (spec §24.2) and is real, payable load; de-energized intersections emit `TrafficSignalPowerChanged`, which **doc 10** turns into a congestion penalty (report 98 G-6 — this doc owns none of that math).

### 2.4 The load-flow solve — four passes at 4 Hz

`dt = 15 game-seconds` (constitution §4). State is SoA `PackedFloat32Array` / `PackedInt32Array` indexed by component slot.

**Pass A — bottom-up demand aggregation** (topological order, leaves → roots):
```
transformer.load_kw = Σ attached building demand + streetlights + signals
feeder.load_kw      = Σ child transformer.load_kw
substation.load_kw  = Σ child feeder.load_kw ;  link.load_kw = its substation's load
system.demand_kw    = Σ substation.load_kw
```
Components carry **full downstream demand**, not a curtailed value. Overload is real; nothing self-limits. Curtailment happens only via protection trips (§2.5), thermal failure (§2.6) or system shedding (below).

**Pass B — supply and shedding** (the only top-down capacity step):
```
system.supply_kw = Σ online generation output (plants §2.7.6 + batteries + imports)
deficit_kw       = max(0, system.demand_kw - system.supply_kw)
```
If `deficit_kw > 0`, shed **whole feeders** — the feeder is the smallest switchable unit — cheapest-pain first:
```
shed_score = Σ_sinks(demand_kw × priority_weight[class]) / feeder.load_kw
priority_weight = { CRITICAL 1000, ESSENTIAL 40, STANDARD 8, DISCRETIONARY 1 }
```
Sort ascending by `shed_score`; **ties break by descending `load_kw`, then by component id** (determinism, and it closes the deficit with the fewest feeders). Open feeders until `Σ shed ≥ deficit_kw`. A feeder containing any CRITICAL sink is shed only if no other feeder can close the deficit. Shed feeders rotate every **30 game-minutes** (`rolling_shed_period_gm`) so the pain moves — emit `RollingBlackoutRotated`. `priority_class` comes from doc 02 (its critical-facility priority tier); a player override via `set_feeder_priority` adds `+500` to that feeder's score.

**Pass C — thermal, protection, hazard** (§2.5–§2.6) for every energized component. De-energized components decay `theta` toward 0 with the same time constant.

**Pass D — energization** (DFS from substation roots; runs only when `topology_dirty`). A component is energized iff it has an unbroken path to the bulk pool through components that are neither `FAILED` nor `OPEN`, and `system.supply_kw > 0`. **The DFS visit order is the restoration order** and is published verbatim as `restore_order` on restoration events (§4, report 98 C-39).

**Building service state**, with hysteresis so nothing flickers:
```
served_kw = demand_kw          if its transformer is energized
          = backup_output_kw   if a backup generator is running (§2.10)
          = 0                  otherwise
DARK when served_kw < 0.35 × demand_kw sustained ≥ 20 game-seconds
LIT  when served_kw ≥ 0.55 × demand_kw sustained ≥ 10 game-seconds
```

**Time-weighted availability** (report 98 C-37 — doc 03's `f_power` needs a fraction, not a boolean). Every tick, for every served building, the grid accumulates:
```
served_kwh[b]   += served_kw[b] × dt_gh          dt_gh = 15/3600 = 0.00416667
demanded_kwh[b] += demand_kw[b] × dt_gh
```
At each game-hour boundary, **before** doc 03 settles:
```
power_availability_hour(b) = clamp(served_kwh[b] / demanded_kwh[b], 0, 1)   if demanded_kwh[b] > 0
                           = 1.0                                            otherwise
```
then both accumulators reset. A building on backup accumulates `served_kw = demand_kw × coverage_frac`, so a hospital riding an outage on its generator reports `0.70` rather than `1.0` or `0.0` — the two-thirds of the cascade signal a boolean was erasing. `is_powered()` and `power_output_multiplier()` remain for consumers that genuinely want the instantaneous state (doc 05, doc 11).

**Tiles that go dark:** every tile of a DARK building's footprint; every road tile and intersection whose nearest transformer is de-energized. A land block flags **`block_dark`** when ≥60% of its buildings (weighted by population + jobs) are DARK (report 98 C-38 — block granularity is correct, it is the render chunk). Doc 09 aggregates member blocks into its district-level `district_dark`; doc 11 renders the block-level event unchanged.

**Cost.** A/C/D are O(N) over ≤1,500 components: under 6,000 float ops per tick, ~24k/s. B runs only in deficit; D only on topology change. The availability accumulation is two multiply-adds per served building. Budget **≤0.4 ms/tick** on a 2020 mid-tier device. If profiling misses it, shard Pass C across 4 ticks by index (thermal `dt` becomes 60 game-seconds for that shard) — a pure perf knob, `perf.thermal_shard_count`, no change to the maths.

### 2.5 Overload → protection trips (feeder, substation, transmission)

Inverse-time overcurrent relay, one accumulator per component:
```
cap_eff    = cap_base × (0.55 + 0.45 × condition) × amb_derate
amb_derate = clamp(1 - 0.008 × max(0, T_ambient - 30), 0.80, 1.0)
r          = load_kw / cap_eff

if r > r_pickup (1.05):  t_trip_gs   = clamp(k_trip / (r² - 1), 2.0, 900.0)
                         trip_accum += dt / t_trip_gs
else:                    trip_accum  = max(0, trip_accum - dt / 120)
trip_accum ≥ 1.0 ⇒ OPEN, incident FEEDER_TRIP / SUB_TRIP, trip_accum = 0
```
`k_trip`: feeder 120, substation 90, transmission 100. Resulting feeder trip times: r=1.10 → 571 gs; r=1.30 → 174 gs; r=1.80 → 54 gs; r=2.50 → 23 gs. Substation times are 0.75× those.

**Auto-reclose.** 90 game-seconds after a trip, retry. If post-reclose `r ≤ 0.98`, service restores free (`AutoReclosedOK`). Otherwise re-trip, and after 2 failed attempts → **lockout**, requiring a crew `reclose` job (4 gm). Momentary outages are therefore common and cheap; genuine over-capacity demands a real fix. **`auto_reclose_delay_gs` and `auto_reclose_max_attempts` are coupled to doc 11's `momentary_outage_s`** — see the comment in §8 `protection` and report 98 C-40.

**Transformers have no protection.** That is the design point: an overloaded transformer does not trip, it cooks (§2.6). Only a hard ceiling exists — `r ≥ 3.0` ⇒ immediate `XFMR_BURNOUT`.

### 2.6 Heat accumulation → failure probability (exact math)

Every component carries `theta`, its temperature **rise above ambient** in °C.
```
theta_ss = theta_rated × r² × heat_wave_still_air_mult   # 1.10 during HEAT_WAVE, else 1.0
alpha    = dt / (tau + dt)                               # dt = 15 game-seconds
theta   += (theta_ss - theta) × alpha
T        = T_ambient + theta                             # T_ambient from doc 07
```
`thermal` constants: transformer `theta_rated 55 °C, tau 900 gs` (alpha 0.01639); feeder `40 / 300` (0.04762); substation `45 / 1200` (0.01235); transmission `35 / 240` (0.05882).

**Hazard curve** — cubic above a knee, so `r ≤ 1.0` is genuinely safe and `r ≥ 1.5` genuinely lethal, without the runaway of a pure exponential:
```
stress    = max(0, (T - T_knee) / T_span)
cond_mult = 1 + 3 × (1 - condition)²
h         = (h_cold + h_hot × stress³) × cond_mult        # hazard per game-hour
p_tick    = 1 - exp(-h × dt_gh)      dt_gh = 15/3600 = 0.00416667
```
(`p_tick ≈ h × dt_gh` is permitted when `h × dt_gh < 0.05`; the exp form is required on the offline coarse path where `dt_gh = 1.0`.) `hazard` constants as `(T_knee, T_span, h_hot, h_cold)`: transformer `(85, 60, 2.00, 0.00012)`; feeder `(75, 55, 1.20, 0.00008)`; substation `(80, 60, 0.90, 0.00010)`; transmission `(70, 55, 0.70, 0.00006)`. Plants skip the thermal model: `h = 0.00030 × (1 + 2·max(0, r − 0.9)) × cond_mult`.

**Transformer steady state at `T_ambient = 25 °C`, `condition = 1.0`:**

| r | theta_ss | T | stress | h /gh | MTTF |
|---|---|---|---|---|---|
| 0.80 | 35.2 | 60.2 | 0 | 0.00012 | ~8,300 gh — safe |
| 1.00 | 55.0 | 80.0 | 0 | 0.00012 | safe |
| 1.15 | 72.7 | 97.7 | 0.212 | 0.0191 | 52 gh (≈52 real min) |
| 1.30 | 93.0 | 118.0 | 0.550 | 0.333 | 3.0 gh (≈3 real min) |
| 1.60 | 140.8 | 165.8 | 1.347 | 4.89 | 12 game-min |
| 2.00 | 220.0 | 245.0 | 2.667 | 37.9 | 1.6 game-min |

(This table is parameterized by `r`, not by kW, so C-31 and C-32 do not move it.)

With ~150 transformers, `h_cold` alone yields one random burnout roughly every **55 game-hours (~2.3 game-days)** citywide at perfect condition — a steady low-noise incident drip that justifies keeping a utility crew on staff.

**Condition wear:** `condition -= 0.00035 × dt_gh × (1 + 6 × stress²) × kind_wear_mult`, clamped to [0,1]. At zero stress that is 119 game-days from 1.0 to 0.0. A `preventive_maintenance` job restores `+0.35` over 22 gm (doc 03 prices it as `PM_COST_FRACTION × capital_value`); any repair restores condition to `0.85`.

### 2.7 Weather couplings (interface: doc 07)

Read each tick from doc 07: `T_ambient_c`, `wind_mps`, `cloud_factor`, `sun_elevation_rad`, `weather_state`, `storm_intensity` (0–1), `precip01`; plus event streams `LightningStrike(target_ref, energy)` and `TileFlooded(tile, depth_m)`. **The grid simulates no weather of its own and rolls no weather-driven failures** (report 98 C-53/C-54): doc 07 generates strikes and selects targets, doc 06 generates storm damage incidents, and this doc resolves what happens to a grid component once it is hit.

**2.7.1 Temperature → demand.**
```
weather_mult = 1 + k_cool[class] × max(0, T_ambient - 24) + k_heat[class] × max(0, 12 - T_ambient)
k_cool = { RES 0.030, COM 0.035, IND 0.012, CIV 0.030, DC 0.055 }
k_heat = { RES 0.028, COM 0.022, IND 0.010, CIV 0.026, DC 0.000 }
```
Heat wave at 40 °C ⇒ RES ×1.48, DC ×1.88. Blizzard at −10 °C ⇒ RES ×1.62.

**2.7.2 Temperature → capacity and heat.** `amb_derate` (§2.5) plus `T = T_ambient + theta` (§2.6). A 40 °C heat wave simultaneously raises load ~48%, cuts transformer capacity to 0.92, and adds 15 °C to every winding. Those three multiply — the signature heat-wave death spiral, and it is intended.

**2.7.3 Lightning — damage resolution for grid components.** Doc 07 owns strike generation **and target selection** (only it can see buildings, the storm cell and F4 target immunity) and emits `LightningStrike{target_ref, energy}`. This doc's former target-weight table and `strike_radius_tiles` selection are **deleted** (report 98 C-54). When `target_ref` names a grid component, the grid resolves it and nothing else does:

```
underground component            ⇒ ds0 immediately (earthed; no damage path)
p_damage = 0.55 × (1 - 0.22 × arrester_level) × clamp(energy, 0.6, 1.6)
u = rng(failures).randf()
```

**Damage-state bands** — the resolution table doc 07 references rather than restates:

| band | condition on `u` | outcome | `damage_fraction` |
|---|---|---|---|
| `ds0` SURGE_ABSORBED | `u ≥ p_damage` | `SurgeAbsorbed`, `condition -= 0.05`, stays in service | 0.00 |
| `ds1` TRIP | `u < 0.45 × p_damage` | protection operates: `OPEN`, auto-reclose eligible (§2.5) | 0.005 |
| `ds2` FAULT | `0.45 × p_damage ≤ u < 0.90 × p_damage` | `FAILED`, cause `LIGHTNING`, repair job per §2.8 | per §2.8 (0.05 / 0.30 / 0.35) |
| `ds3` DESTROYED | `0.90 × p_damage ≤ u < p_damage` | `FAILED`, component must be replaced, secondary-fire roll 0.25 handed to **doc 06** | 1.00 |

Band shares are `{ds1 0.45, ds2 0.45, ds3 0.10}` of `p_damage`. At `arrester_level 3` the whole damage probability falls by 66% (`1 − 0.22×3 = 0.34`), which is what the arrester is sold on.

**2.7.4 Wind and storm exposure — attributes, not rolls.** This doc's former `h_wind` line-damage roll is **deleted** (report 98 C-53): **doc 06 owns all incident generation, including storm damage.** Doc 07 supplies `wind_kph` and the storm-cell mask; this doc supplies, per component, the attributes doc 06's `storm_damage` generator consumes:

| attribute | type | value |
|---|---|---|
| `weather_exposure` | float 0–1 | overhead feeder / transmission tile **1.00**; pole-mounted transformer **0.80**; substation yard **0.35**; pad-mounted transformer **0.30**; plant **0.20**; anything `underground` **0.00** |
| `tree_adjacent` | bool | true when the route crosses ≥3 undeveloped/park tiles (doc 09 supplies the tile classes) |
| `condition` | float 0–1 | §2.6 |
| `underground` | bool | feeders only in MVP |
| `span_count` | int | `ceil(route_tiles / span_tiles)`, `span_tiles = 4` (32 m spans) — the unit doc 06 calibrates `R_storm_base` against (its targets: ≈2.5 failures for a maintained 60-span grid, ≈12 for a neglected one) |

When doc 06 raises a storm failure on a line, the grid applies it as `FEEDER_DOWN` (§2.8) and owns the consequence, the repair job and the `damage_fraction` — the same split as lightning.

**2.7.5 Wind → generation cutout.** Wind farms produce nothing above 24 m/s: a wind-heavy city loses generation exactly when the storm is knocking down its feeders. Intended, and unaffected by C-53 — this is a generation curve, not a failure roll.

**2.7.6 Renewable output.**
```
solar_out = nameplate × max(0, sin(sun_elevation_rad)) × cloud_factor
cloud_factor: CLEAR 1.00, CLOUDY 0.55, RAIN 0.35, THUNDERSTORM 0.20, SNOW 0.30, FOG 0.45
wind_out  = nameplate × f(w),  f(w) = 0 (w<3.5) | ((w-3.5)/8.5)³ (3.5≤w<12) | 1 (12≤w≤24) | 0 (w>24)
```

**2.7.7 Flooding.** With `effective_depth = flood_depth_m - 0.6 × flood_wall_level`: substation forced OPEN above 0.40 m (`SUB_FLOOD_TRIP`), `FAILED` above 0.90 m (`SUB_FLOOD`, repair **time** ×3.0, cannot start until depth < 0.20). Submerged underground feeder tile: `h_flood = 0.05/gh`. Transformer under >0.5 m: `h_flood = 0.35/gh`. (Flood hazard stays here because it is a per-component thermal/immersion state, not an incident generator; doc 07 supplies only `TileFlooded`.)

### 2.8 Failure types, damage fractions and incident objects

Repair **pricing** is doc 03's (report 98 C-16). This doc supplies a `damage_fraction ∈ [0,1]` per failure type — the same table that used to be `cost_frac_of_build`, re-read — and doc 03 computes `repair_cost = capital_value(asset) × damage_fraction × 0.85 × M_repair`.

| id | cause | protection | repair job | crew capability | `damage_fraction` |
|---|---|---|---|---|---|
| `XFMR_BURNOUT` | thermal hazard, or r ≥ 3.0 | none | swap | `xfmr_swap_l2/_l4/_l5` | 0.35 |
| `XFMR_LIGHTNING` | strike (ds2) | arrester | swap | as above | 0.35 |
| `FEEDER_TRIP` | inverse-time relay | yes | reclose | `reclose` | 0.005 |
| `FEEDER_FAULT` | thermal hazard, strike (ds2) | — | splice | `splice` | 0.05 |
| `FEEDER_DOWN` | doc 06 storm damage / crash | — | rebuild | `rebuild_overhead` | 0.20 |
| `SUB_TRIP` | inverse-time relay | yes | reclose | `reclose` | 0.005 |
| `SUB_FAULT` | thermal / strike (ds2) | — | repair | `substation_repair` | 0.30 |
| `SUB_FLOOD` | flood depth | flood wall | repair (time ×3) | `substation_repair` | 0.30 |
| `PLANT_TRIP` | random / disturbance | yes | restart | `plant_restart` | 0.02 |
| `PLANT_FAULT` | mechanical hazard | — | overhaul | `plant_overhaul` | 0.25 |
| *any* `ds3` DESTROYED | strike (§2.7.3) | arrester | replace | as per kind | 1.00 |
| `FUEL_SHORTAGE` | treasury < fuel bill | — | pay bill | none | 0.00 |
| `BACKUP_GEN_FAIL` | start failure / fuel out | — | refuel/repair | `refuel_gen` | 0.00 (fuel is billed as fuel) |
| `CASCADE_OVERLOAD` | tag applied to any trip within 60 gs of another | — | — | — | — |

Incident object per spec §33 / constitution §8. Concrete instance emitted by the grid:
```json
{ "id": 40217, "type": "XFMR_BURNOUT", "position": [148, 96], "severity": 3,
  "start_time": 918442, "escalation_time": 918622,
  "required_units": [{"dept": "utility", "capability": "xfmr_swap_l4", "count": 1}],
  "optional_units": [{"dept": "utility", "capability": "mobile_transformer", "count": 1}],
  "assigned_units": [], "dependencies": ["power:transformer:t_0412"],
  "status": "QUEUED", "notification_priority": 2,
  "payload": { "component_id": "t_0412", "component_kind": "transformer", "level": 4,
    "peak_temp_c": 171.4, "peak_load_ratio": 1.62, "buildings_dark": 14,
    "population_affected": 812, "damage_fraction": 0.35,
    "cause_chain": ["HEAT_WAVE", "OVERLOAD", "THERMAL"] } }
```
**No `repair_cost` field.** Doc 03 turns `damage_fraction 0.35` on a transformer L4 (`capital_value` $6,900 per its §2.13(b)) into `0.35 × 6,900 × 0.85 × 1.00 = $2,052.75 → $2,053` at `M_repair = 1.0`. Under this doc's deleted currency scale the same event quoted $19,250 — a 9.4× overcharge against the only calibrated pacing model in the project.

`severity = clamp(1 + floor(population_affected / 400) + (2 if any CRITICAL sink dark else 0), 1, 5)`. `cause_chain` exists purely to satisfy Core Rule 12 — the post-mortem UI reads it verbatim.

### 2.9 Cascades, tie lines, and N-1

1. Component X trips or fails → its subtree de-energizes → `PowerOutage`.
2. For each closed-capable tie touching the orphaned segment with `auto_transfer` on, wait `transfer_delay_gs = 20`, then evaluate `r_after = (partner.load + orphan.load) / partner.cap_eff`:
   - `r_after ≤ 0.95` → close, restore, `TieTransferSuccess`.
   - `0.95 < r_after ≤ 1.35` → close only in `AGGRESSIVE` mode; the partner now accumulates trip time (§2.5) and may cascade.
   - `r_after > 1.35` → refuse, `TieTransferBlocked` — the message that teaches the player to build headroom rather than more ties.
3. Any component tripping within `cascade_window_gs = 60` of another trip is tagged `CASCADE_OVERLOAD`, and its `cause_chain` prepends the upstream component id.
4. De-energized load ≥ 40% of `system.demand_kw` ⇒ `MajorOutage` (notification priority 1, spec §22).

**N-1 headroom** — the metric the player builds against:
```
n1_headroom_kw(F) = max over tie-partners P of (P.cap_eff - P.load_kw - F.load_kw)
n1_ok_fraction(S) = (# child feeders of S with n1_headroom_kw ≥ 0) / (# child feeders)
```
The load-weighted city-wide mean of `n1_ok_fraction` is published as `power_resilience` (0–1) to **doc 09**, feeding district stability and the "Resilient Grid" milestone.

**Redundancy the player can buy** (prices: doc 03 §2.13(b)): *tie switch* plus its connecting segment, modes MANUAL / AUTO / AGGRESSIVE; *parallel transformer* on one service group, each taking `load × own_cap / Σ cap` (two L4s carry 1,600 kW at r = 0.80 each); *dual-fed substation*, where losing one link caps intake at the survivor rather than zeroing it; *battery* (post-MVP) discharging into the pool during deficit and charging when `supply > demand × 1.15`.

### 2.10 Backup generators — the one fuel model

**This doc owns generator fuel and refuelling for every backup-capable sink in the project** (report 98 C-36), including doc 05's water nodes: doc 05's `backup_generator` fuel fields are deleted there and its generators are registered as `backup_gens` entries in this doc's save section. Buildings flagged `backup_capable` by doc 02 (hospital, data_center, water_facility, police_station, fire_station) may host one.

```
on service loss: wait start_delay_gs = 12
                 success = rng(failures) < 0.94 × condition   # else BACKUP_GEN_FAIL, stays DARK
                 output_kw = min(demand_kw × coverage_frac[sink], gen_capacity_kw)
fuel_remaining_gh -= dt_gh × (output_kw / gen_capacity_kw)   # exhaustion ⇒ BACKUP_GEN_FAIL(FUEL)
fuel_kwh_burned    = output_kw × dt_gh × fuel_efficiency_mult[tier]
```

`coverage_frac` **for water nodes is doc 05's input** (report 98 C-36: 0.60 at L2 rising to 1.00 at L5, per node) and is read, never authored, here. For non-water sinks this doc keeps the defaults `{hospital 0.70, data_center 0.55, police_station 0.85, fire_station 0.85, default 0.60}`.

Refuelling is a `refuel_gen` job of 14 gm restoring the tank; the **fuel volume** it consumes is `capacity_kw × fuel_gh × fuel_efficiency_mult` kWh and **doc 03 prices it** at the diesel rate (`$95/MWh`). A tier-M tank is `600 kW × 16 gh × 0.905 = 8,688 kWh = 8.69 MWh ⇒ $825`. This doc quotes no dollar.

A building on backup is **LIT but degraded**: doc 03 applies `output_multiplier = coverage_frac`, its `power_availability_hour` reports `coverage_frac` for the hours it ran (§2.4), and the renderer dims it.

### 2.11 Black start — deferred (spec §13.4)

`TotalBlackout` is raised when `system.supply_kw == 0` and every substation is de-energized. **MVP behaviour:** every non-failed plant auto-restarts after `blackstart_auto_restart_gm = 12` (assumed station-service backup), then substations reclose in descending `critical_load_kw` order at one per 30 game-seconds to avoid a cold-load-pickup re-trip. That reclose order is the `restore_order` payload (§4). Because the staged reclose already exists, the post-MVP black start (manual ordering, cranking path from a `blackstart_capable` plant, `cold_load_pickup_mult = 1.70` for the first 10 game-minutes) is a UI + rule layer on top, not a rewrite. Those fields ship now, unused.

### 2.12 Offline catch-up (constitution §4)

Same code, coarse path. Per 1 game-hour step: `dt_gh = 1.0`, `alpha = 3600/(900+3600) = 0.8`. **Fidelity rule:** if any component ended the previous step with `r > 1.0`, or a storm is active, the hour is sub-stepped at `dt = 300 game-seconds` (12 sub-steps) so cascades and inverse-time trips resolve correctly; otherwise the hour runs in one step. Worst case is bounded at 12 × O(N). `power_availability_hour` accumulates identically on this path (one coarse step = one settled hour, so a fully dark hour reports 0.0 and a backed-up hour reports `coverage_frac`). Auto-repair policies (spec §21.3) are applied by doc 06.

### 2.13 Worked examples

**R-07 — what normalizing the curves did.** This doc's retired `tod_curves` were never normalized; doc 01's are, to a 24-hour mean of 1.000. The uplift is `1 / old_mean` per class:

| class | old `tod_curves` 24-h mean | doc 01 channel mean | uplift |
|---|---|---|---|
| RES | 19.06 / 24 = 0.7942 | 1.000 | **×1.2592 (+25.9%)** |
| COM | 18.52 / 24 = 0.7717 | 1.000 | **×1.2959 (+29.6%)** |
| IND | 19.87 / 24 = 0.8279 | 1.000 | **×1.2079 (+20.8%)** |
| CIV | 23.02 / 24 = 0.9592 | 1.000 | **×1.0426 (+4.3%)** |
| DC | 1.0000 | 1.000 | ×1.0000 (0%) |

Weighted by WE-4's class base mix (RES 33,000 / COM 24,000 / IND 21,000 / CIV 11,000 / DC 13,000 kW = 102,000 kW), citywide 24-hour mean demand rises `122,488 / 102,000 = ` **×1.201, i.e. +20.1%** — the "~+20%" the ruling predicted. Generation ladders are unchanged, but every capacity example, upgrade gate and shed margin below is computed at the higher figure.

**Starter-city headroom check, restated from doc 09's R-16 results** (report 98 RR-10). The starter load is **doc 09's number, not this doc's** — doc 09 §2.9.4 owns the manifest, the per-class arithmetic and the distributed-sink counts; this table quotes it and derives only the headroom ratio, `headroom = plant_capacity_kw / load_kw`:

| starter-city figure | value (doc 09 §2.9.4) | vs one `plant_gas` L1 = 8,000 kW |
|---|---|---|
| building **nameplate** load | **402.0 kW** | `8,000 / 402.0` = **×19.90** |
| building load at the 20:00 night peak | 460.7 kW | `8,000 / 460.7` = ×17.36 |
| streetlights `783 road tiles × 0.35 kW × 1.00` | 274.05 kW | — |
| traffic signals `81 intersections × 0.6 kW` | 48.60 kW | — |
| **published night peak** `460.69 + 274.05 + 48.60` | **783.3 kW** | `8,000 / 783.3` = **×10.21** |

So an L1 gas plant covers the reverted C-11 starter city **≈20× on nameplate and ≈10× on the real 20:00 peak**, and `SUB-A` (L1, 6,000 kW) runs at `783.3 / 6,000 = 13.1%` of rating. **The former quote of "508 kW building load with 15× headroom" is deleted** — 508 kW was the pre-C-11 28/8/6/1 manifest carrying doc 02's since-deleted flat 60 kW `water_facility` shell, and it was never this doc's figure to publish. Owner: **doc 09 §2.9.4** (`starter.building_nameplate_kw 402.0`, `starter.night_peak_kw 783.3`).

All demand figures below are generated by §2.3 against **doc 02's `Pwr kW` column** (report 98 C-31 / recomputation R-06) and **doc 01's normalized channels** (C-32 / R-07). Channel values are read from `data/time.json`'s piecewise-linear keys: `power_demand_residential` 19:00 = **1.37**, 20:00 = **1.46**, 04:00 = **0.688**; `power_demand_commercial` 19:00 = **1.325**, 20:00 = **1.14**; `power_demand_industrial` 20:00 = **1.0033**; `power_demand_civic` 20:00 = **0.9592**; `power_demand_datacenter` flat **1.000**; `streetlight_load` 19:00 = **1.00**.

**WE-1 — Aggregation.** Feeder F3 (class 2, 3,000 kW) at 19:00, clear, 22 °C, carrying T7 (L3, 400 kW) and T8 (L4, 1,000 kW).

T7 serves 4× apartment L3 (doc 02 `base_kw` **130**, occupancy 0.95, RES channel 1.37) plus 26 streetlit road tiles:
```
4 × 130 × 0.95 × 1.37 = 676.78 kW
26 × 0.35 × 1.00      =   9.10 kW
T7.load               = 685.88 → 685.9 kW      r = 685.9 / 400 = 1.715
```
T8 serves office L4 (`base_kw` 515 × 0.40 occ × 1.325 COM = **272.95**) + store L3 (`base_kw` 50 × 0.90 × 1.325 = **59.63**) + 18 streetlights (**6.30**):
```
T8.load = 338.88 → 338.9 kW                    r = 338.9 / 1000 = 0.339
F3.load = 685.9 + 338.9 = 1,024.8 kW           r = 1,024.8 / 3,000 = 0.342
```
The problem is entirely T7 — the local hotspot the overlay must surface, and post-C-13/C-31 it is a **CRITICAL** hotspot rather than the merely worrying `r = 1.33` the old table produced (T7 was 533.5 kW; the corrected `base_kw` and normalized curve add **+28.6%**). Fixes: upgrade T7 to L4 (doc 03 price $6,900) ⇒ `685.9 / 1,000 = r 0.686`; or add a second L3 and split the group ($2,800) ⇒ `342.9 / 400 = r 0.857` each — still amber, which is the honest reading: at these loads the split is a stopgap and the L4 is the fix.

**WE-2 — Heat-wave burnout.** T7 again at `T_ambient = 39 °C`:
```
RES weather_mult = 1 + 0.030 × (39 − 24) = 1.45
per building     = 130 × 0.95 × 1.37 × 1.45 = 245.3 kW   (cap 130 × 2.2 = 286 — not binding)
demand           = 4 × 245.3 + 9.1 = 990.4 kW
amb_derate       = 1 − 0.008 × 9 = 0.928
cap_eff (cond 0.9) = 400 × (0.55 + 0.45×0.9) × 0.928 = 400 × 0.955 × 0.928 = 354.5
r                = 990.4 / 354.5 = 2.794          (below the 3.0 hard ceiling — it cooks, it does not snap)
theta_ss         = 55 × 2.794² × 1.10 = 55 × 7.806 × 1.10 = 472.3 °C
```
From `theta = 40`, integrating at `alpha = 15/915 = 0.016393`:

| elapsed | theta | T | stress | h /gh | p_tick | survival |
|---|---|---|---|---|---|---|
| 5.0 gm (20 ticks) | 161.7 | 200.7 | 1.928 | 14.76 | 0.0597 | 0.701 |
| 6.25 gm (25 ticks) | 186.3 | 225.3 | 2.339 | 26.35 | 0.1040 | **0.449 — median** |
| 10.0 gm (40 ticks) | 249.1 | 288.1 | 3.385 | 79.91 | 0.2832 | 0.017 |
| 15.0 gm (60 ticks) | 311.9 | 350.9 | 4.432 | 179.3 | 0.5263 | <0.001 |

**Median time to burnout ≈ 6.25 game-minutes**; the 5th–95th percentile band is **3.25 → 9.25 gm**. The old table gave 8–12 gm; the C-13/C-31/C-32 corrections make the heat-wave death spiral roughly **35% faster**, which is the intended consequence of an apartment L3 drawing 130 kW instead of 120 and of the RES curve no longer being quietly de-rated by a factor of 0.79. Still long enough for the warning icon to matter, short enough that ignoring it costs money.

**WE-3 — Cascade.** Substation S2 (L3, 30,000 kW) trips on a lightning `ds2` fault at t = 0; its three feeders (6,100 / 5,400 / 4,800 kW) orphan. *(Inputs here are stated feeder loads, so C-31/C-32 move nothing; the arithmetic is re-verified against the current constants.)*
- Feeder A (6,100) ties AUTO to D on S1 (cap_eff 7,120, load 3,900): `r_after = 10,000 / 7,120 = 1.404 > 1.35` ⇒ **TieTransferBlocked**, A stays dark.
- Feeder B (5,400) ties to E (cap_eff 7,120, load 1,200): `r_after = 6,600 / 7,120 = 0.927 ≤ 0.95` ⇒ clean transfer.
- Feeder C (4,800) ties AGGRESSIVE to F (class 2, cap_eff 3,000, load 1,000): `r_after = 5,800 / 3,000 = 1.933`, closed anyway, `t_trip = 120 / (1.933² − 1) = 120 / 2.738 = 43.8 gs`, so F trips at `20 + 43.8 = 63.8 gs` tagged `CASCADE_OVERLOAD`, dragging its own healthy 1,000 kW into the outage.

The post-mortem line writes itself: *"Tie D→F closed at 1.93× capacity and tripped 44s later, adding 1,000 kW to the outage."*

**WE-4 — Shedding, at the 20:00 system peak** (recomputed against normalized channels, R-07). Class base load (`Σ base_kw × occupancy`) and the channel at hour 20:
```
RES 33,000 × 1.4600 = 48,180
COM 24,000 × 1.1400 = 27,360
IND 21,000 × 1.0033 = 21,070
CIV 11,000 × 0.9592 = 10,551
DC  13,000 × 1.0000 = 13,000
system.demand_kw    = 120,161 kW
```
Supply 92,000 kW (an L5 plant is out for repair) ⇒ **deficit 28,161 kW** (it was 26,400 under the un-normalized curves). Shed scores: F11 industrial 9,800 kW (1.0), F14 data centre 13,200 kW (1.0), F7 mixed commercial 7,100 kW (8.0), F3 residential 5,900 kW (40.0). Equal scores break by descending load, so F14 sheds first: `13,200 + 9,800 = 23,000`, still 5,161 short ⇒ add F7. **Total shed 30,100 kW; shed set {F14, F11, F7}** — the same set as before the recomputation, which is the point: the policy is robust to the demand correction, only the margin moved. Thirty game-minutes later the rotation restores F7 and drops F9 instead.

**WE-5 — Repair timing.** `XFMR_BURNOUT` on an L4 during a thunderstorm at night, crew skill 2:
```
38 gm × (1 + 0.5 × 0.8) × 1.15 × (1 − 0.08 × 1) = 38 × 1.4 × 1.15 × 0.92 = 56.3 game-minutes
```
on site (travel is doc 06's). The grid reports `damage_fraction = 0.35`; doc 03 charges `0.35 × 6,900 × 0.85 = $2,053`. A `mobile_transformer` dispatched in parallel restores 60% of the group in 6 game-minutes.

**WE-6 — Time-weighted availability** (report 98 C-37). Apartment L3, `base_kw` 130, settled hour 19:00→20:00, occupancy and channel folded to a flat 130 kW request for clarity. Its feeder trips at :00 and the crew recloses at :27.
```
demanded_kwh = 130 × 1.00           = 130.0 kWh
served_kwh   = 130 × (33/60)        =  71.5 kWh
power_availability_hour = 71.5 / 130 = 0.55
```
0.55 is exactly the figure doc 02 §2.5 and doc 03's cascade example assume — the same hour under the old boolean API reported `is_powered = true` (the building was lit when the hour ended) and doc 03's `f_power` would have seen no outage at all. Had the building been a hospital riding the outage on a generator instead, it would have accumulated `130 × 0.70` for 27 minutes and reported `0.865`.

---

## 3. Data Schema

### 3.1 `data/power.json`
Keys: `version`, `components`, `upgrades`, `demand` (class map and weather coefficients only — `base_kw` lives in `data/buildings.json`, diurnal curves in `data/time.json`), `thermal`, `hazard`, `protection`, `weather`, `shedding`, `redundancy`, `service`, `repair`, `backup`, `blackstart`, `overlay`, `offline`, `perf`. Full values in §8. **This file contains no prices** (report 98 C-07/C-08/C-12): no `build_cost`, no `upkeep_per_gh`, no `fuel_cost_per_kwh`, no `cost_frac_of_build`, no `tie_switch_cost`. A loader that finds one must fail the schema test (§7 test 25).

### 3.2 Save section `power` (constitution §9)

```json
{ "section_version": 1, "next_component_id": 1043,
  "components": [
    { "id": "t_0412", "kind": "transformer", "level": 4, "tile": [148, 96], "parent": "f_0031",
      "state": "OK", "condition": 0.912, "theta_c": 41.8, "trip_accum": 0.0,
      "arrester_level": 1, "flood_wall_level": 0, "cum_energy_kwh": 41822.5,
      "weather_exposure": 0.80, "tree_adjacent": false,
      "failed_cause": null, "incident_id": null },
    { "id": "f_0031", "kind": "feeder", "conductor_class": 2, "underground": false,
      "route": [[140,90],[141,90],[142,90]], "parent": "s_0003", "state": "OK",
      "condition": 0.98, "theta_c": 12.2, "trip_accum": 0.14, "reclose_attempts": 0,
      "priority_override": false, "weather_exposure": 1.00, "tree_adjacent": true }
  ],
  "ties": [ {"id": "tie_007", "a": "f_0031", "b": "f_0044", "mode": "AUTO",
             "closed": false, "route_cost_tiles": 6} ],
  "backup_gens": [ {"building_id": "b_2201", "tier": "M", "condition": 0.95,
                    "fuel_remaining_gh": 12.4, "running": false} ],
  "system": { "shed_feeders": ["f_0011"], "shed_rotation_next_gm": 918720,
              "total_blackout_since": null, "hour_start_gm": 918420,
              "cum_outage_customer_minutes": 184220.0 },
  "building_service": { "b_2201": {"state": "LIT", "since_gm": 918440, "on_backup": false,
                                   "served_kwh": 41.2, "demanded_kwh": 74.9,
                                   "availability_prev_hour": 0.55} } }
```
`state` ∈ `OK | OPEN | FAILED | SHED | UNSERVED`. `building_service` is stored sparsely — only buildings not in the default LIT state, plus hysteresis timestamps and any non-zero availability accumulators (a full-service building's accumulators are reconstructible and are omitted). `section_version` is the per-section key mandated by report 98 C-25; `schema_version` exists only on the save envelope, which doc 08 owns. `fuel_debt` is gone: fuel insolvency is doc 03's ledger, and `FUEL_SHORTAGE` is raised from doc 03's signal. RNG state for the `failures` stream lives in the top-level `rng_streams` block, not here. **Migration:** new component kinds append with defaults; unknown `kind` values are dropped with a logged warning rather than failing the load.

---

## 4. Sim API Sketch

`sim/power/` — all `RefCounted`, no Node imports.

| class | role |
|---|---|
| `PowerGrid` | owns SoA component arrays and topology; tick entry; save/load |
| `PowerComponent` | id, kind, level, tile/route, parent, state, condition, theta, trip_accum, exposure attributes |
| `PowerTopology` | parent/child index, tie registry, `topology_dirty`, energization DFS, restore ordering |
| `LoadFlowSolver` | Passes A / B / D; `solve(dt_gs)` |
| `ThermalModel` | Pass C temperature integration and capacity derate |
| `FailureModel` | hazard rolls, inverse-time relay, lightning **damage resolution**, flood hazard |
| `SheddingPolicy` | shed scores, rolling rotation, priority overrides |
| `TieManager` | auto-transfer evaluation, cascade tagging |
| `ServiceLedger` | per-building LIT/DARK hysteresis and `served_kwh` / `demanded_kwh` accumulation |
| `GridInventory` | publishes `rated_mva` / `line_km` / `plant_capacity_mw` / `condition` to doc 03 |
| `PowerOverlayBuilder` | 1 Hz snapshot (§5.7) |
| `PowerSaveIO` | section serialize/deserialize plus migration ladder |

**Tick entry:** `PowerGrid.tick(dt_game_seconds: int, ctx: SimContext) -> void`, registered on the 4 Hz utilities cadence; `ctx` supplies `clock`, `channels`, `rng.failures`, `weather`, `buildings`, `event_bus`. **Hour entry:** `PowerGrid.settle_hour() -> void`, registered `EVERY_HOUR` ahead of doc 03, which finalizes availability and resets the accumulators.

**Queries:** `is_powered(building_id)`, `power_output_multiplier(building_id)`, **`power_availability_hour(building_id) -> float`** (report 98 C-37), `can_upgrade_power(building_id, target_level)`, `n1_headroom_kw(feeder_id)`, `grid_inventory() -> {nodes, lines, plants}`, `storm_exposure(component_id)`, **`suggest_route_along_roads(from, to) -> PackedVector2Array`** (the C-41 assist — a query, never an action).

**Commands:** `place_power_component`, `upgrade_power_component`, `demolish_power_component`, `route_feeder`, `set_feeder_underground`, `place_tie`, `set_tie_mode`, `set_feeder_priority`, `manual_switch`, `request_reclose`, `buy_arrester`, `buy_flood_wall`, `place_backup_gen`, `request_preventive_maintenance`, `set_shed_policy`.

**Events:** `PowerComponentFailed`, `PowerComponentTripped`, `AutoReclosedOK`, `AutoRecloseLockout`, `PowerOutage`, `PowerRestored`, `MajorOutage`, `TotalBlackout`, `CascadeStep`, `TieTransferSuccess`, `TieTransferBlocked`, `LoadShedStarted`, `LoadShedEnded`, `RollingBlackoutRotated`, `BuildingPowerChanged`, `TrafficSignalPowerChanged`, `StreetlightsChanged`, **`BlockDarkChanged`** (renamed from `DistrictDarkChanged`, report 98 C-38), `BackupGenStarted`, `BackupGenFailed`, `SurgeAbsorbed`, `CapacityWarning`, `GenerationDeficit`, `FuelShortage`.

**Restoration payload** (report 98 C-39) — carried by `PowerRestored` and by `BlockDarkChanged` when the transition is dark→lit:
```
restore_order    : PackedInt32Array   # component slot ids in energization-DFS visit order,
                                      # i.e. real restoration priority — doc 11 sweeps along it
powered_fraction : float              # served_kw / demand_kw over the affected set;
                                      # 0.0 or 1.0 while the model is binary, but shipped from
                                      # day one so load-shed tiers need no schema change later
```

---

## 5. Cross-System Interfaces

*(Renumbered to the canonical on-disk map, report 98 Ruling Zero.)*

**5.1 doc 09 — Map, land, districts & population.** *Reads:* tile grid, land-block membership, terrain elevation, undeveloped/park tile classes (for `tree_adjacent`), per-building `occupancy_factor` and `job_fill`. *Expects:* `block_of(tile) -> block_id`. *Provides:* per land block `block_dark`, `outage_duration_gm`, `power_reliability` (rolling 24-game-hour served fraction); city-wide `power_resilience`. Doc 09 aggregates `block_dark` into its district-level `district_dark` and owns every stability consequence.

**5.2 doc 10 — Roads, routing & traffic.** *Reads:* `road_tiles: PackedVector2Array`, `intersections: Array[{id, tile}]`, and `access_quality(pos)` for crew reachability. *Provides:* `TrafficSignalPowerChanged(intersection_id, powered)` and `StreetlightsChanged(block_id, lit)`. Doc 10 owns the congestion penalty for a dark signal (`DARK_SIGNAL_DELAY`, `DARK_SIGNAL_ADD`); this doc owns none of it (report 98 G-6).

**5.3 doc 02 — Buildings, upgrades & construction.** *Reads per building:* `type`, `level`, `origin_tile`, `footprint`, `power_demand_kw` (already `base_kw × state × weather` per doc 02 §2.5), `demand_class`, `priority_class` (its critical-facility tier), `backup_capable`. **Doc 02 owns `base_kw` and every footprint, including the `power_facility` and `substation` shells** (report 98 C-30/C-31). *Provides:* `is_powered()`, `power_output_multiplier()`, `power_availability_hour()`, `upgrade_headroom_kw()`, and the upgrade gate:
```
can_upgrade_power(building_id, target_level) -> {ok, reason, deficit_kw}
ok iff (xfmr.load - cur_demand + new_demand)   / xfmr.cap_eff   ≤ 0.90
   and (feeder.load - cur_demand + new_demand) / feeder.cap_eff ≤ 0.90
else reason = "BLOCKED_POWER_CAPACITY", deficit_kw = the shortfall
```
This is spec §9.4's *"Upgrade blocked: nearby electrical capacity insufficient"*, made exact, and it is what doc 02's worked example E2 (`delta_power = 76 kW`, requirement `87.4 kW`) queries.

**5.4 doc 03 — Economy.** **Doc 03 owns every dollar** (report 98 C-07/C-08/C-12/C-16). *Provides to doc 03, per game-hour:* the inventory `{nodes:[{rated_mva, condition}], lines:[{line_km, condition}], plants:[{plant_capacity_mw, generation_mwh_this_hour, plant_efficiency_mult}]}` for `E_grid` and `E_fuel_generation`; `damage_fraction ∈ [0,1]` per failure event (§2.8); backup-generator `fuel_kwh_burned`. *Reads from doc 03:* `CostCurves.capital_value()` and `repair_cost(asset, damage_fraction)` when quoting a job to the player, the grid price ladder (§2.13(b)) for placement affordability checks, and the `FUEL_SHORTAGE` signal when the treasury cannot pay the fuel bill. This doc publishes no `upkeep_total_per_gh`, no `fuel_cost_per_gh` and no `repair_cost`.

**5.5 doc 05 — Water.** Pumps are `priority_class = CRITICAL` and `backup_capable`; doc 05 reads power only via `is_powered`, `power_output_multiplier` and `power_availability_hour` and never touches grid internals. **Doc 05 owns `coverage_frac` per water node** and publishes it here (report 98 C-36); **this doc owns the generator fuel model and refuelling** for those nodes as for every other backup-capable sink. Per-variant `base_kw` for `water_facility` is doc 02's shell on doc 05's anchors, not this doc's.

**5.6 doc 06 — Incidents, dispatch & crews.** The grid **constructs its own component incidents** (§2.8) and executes the repair effect on completion; doc 06 owns the queue, crews, routing, travel time and job scheduling — and, since report 98 C-53, **all storm-damage generation**. This doc supplies the exposure attributes of §2.7.4 and receives `FEEDER_DOWN` (and any other storm failure) as an input to apply. Secondary fires from a `ds3` strike are handed to doc 06. Capabilities required: `reclose`, `splice`, `rebuild_overhead`, `xfmr_swap_l2/_l4/_l5`, `substation_repair`, `plant_restart`, `plant_overhaul`, `mobile_transformer`, `refuel_gen`, `preventive_maintenance`. Vehicle mapping: service truck → reclose / splice / xfmr_swap_l2 / plant_restart / refuel_gen; bucket truck → + rebuild_overhead / xfmr_swap_l4; heavy repair truck → + substation_repair / plant_overhaul / xfmr_swap_l5; mobile transformer → temporary restore (60% of group capacity, 6 gm setup, expires on permanent repair). The grid supplies `base_repair_gm` and the modifier formula `× (1 + 0.5 × storm_intensity) × 1.15 if night × (1 - 0.08 × (skill - 1))`; doc 06 supplies travel time and blocked-road logic. Vehicle prices are doc 03's.

**5.7 doc 07 — Weather & Disaster Director.** As §2.7. *Reads:* `T_ambient_c`, `wind_mps`, `wind_kph`, `cloud_factor`, `sun_elevation_rad`, `weather_state`, `storm_intensity`, `precip01`, plus `LightningStrike{target_ref, energy}` and `TileFlooded{tile, depth_m}`. *Provides:* the §2.7.3 `ds0..ds3` damage-state bands, which doc 07 **references rather than restates** (report 98 C-54), and the §2.7.4 exposure attributes. This doc generates no weather, selects no strike target and rolls no wind failure.

**5.8 doc 08 — Persistence & offline.** Doc 08 owns the save envelope, the offline band policy and `ctx.catchup_index`; this doc owns its `power` section and the coarse-step contract in §2.12.

**5.9 doc 11 — Rendering.** Consumes `BlockDarkChanged`, `PowerRestored` (with `restore_order` and `powered_fraction`), `StreetlightsChanged` and the dark-tile mask for the blackout/relight signature. Doc 11 owns `momentary_outage_s`; see the coupling comment in §8 `protection`.

**5.10 doc 12 — UI & overlays.** Snapshot built at **1 Hz** (the overlay does not need tick fidelity), double-buffered so the renderer never reads a mutating array:
```json
{ "t_gm": 918442,
  "components": [ {"id":"t_0412","kind":"transformer","tile":[148,96],"level":4,"state":"OK",
                   "color":"CRITICAL","r":1.62,"temp_c":171.4,"condition":0.91,"energized":true} ],
  "edges": [ {"from":"s_0003","to":"f_0031","flow_kw":6100,"r":0.86,"anim_speed":0.86} ],
  "dark_tiles": { "block_31": "<256-bit packed byte array>" },
  "aggregates": { "gen_online_kw":92000, "gen_capacity_kw":128000, "demand_kw":120161,
                  "served_kw":90061, "reserve_margin":-0.234, "shedding":true, "outages":3,
                  "buildings_dark":214, "population_affected":9840,
                  "grid_health":63.4, "power_resilience":0.71 } }
```
Color state: `NORMAL` r < 0.75; `WARNING` 0.75 ≤ r < 0.95; `CRITICAL` r ≥ 0.95 **or** `T ≥ T_knee`; `FAILED`; `OFFLINE`. Per spec §49 each color pairs with a distinct glyph (dot / triangle / double-triangle / cross / hollow) — never color alone. `grid_health = 100 × (0.5 × served/demand + 0.3 × (1 - overloaded_frac) + 0.2 × mean_condition)`. The **N-1 planner mode** re-runs Pass D with one component forced FAILED and returns the resulting `dark_tiles` mask: an on-demand query, not a per-tick cost. Doc 12 owns the drag-path line-drawing UX and the "route along roads" button that calls `suggest_route_along_roads` (report 98 C-41).

---

## 6. MVP Cut (spec §43)

**Ships:** `plant_gas` L1–3, `substation` L1–3, `feeder` class 1–2 overhead, `transformer` L1–4, `transmission` class 1; the full demand model reading doc 02's `base_kw` and doc 01's channels, including streetlights and signals; the full four-pass solve, thermal model, hazard curve, inverse-time relays and auto-reclose; per-building `power_availability_hour`; failure types `XFMR_BURNOUT`, `FEEDER_TRIP`, `FEEDER_DOWN`, `SUB_TRIP`, `PLANT_TRIP`, `CASCADE_OVERLOAD`; weather couplings for temperature and for lightning **damage resolution**, plus publication of the storm-exposure attributes doc 06's storm generator needs (all exercised by the MVP thunderstorm, spec §43.4); tie switches MANUAL + AUTO with the N-1 headroom readout; load shedding with rolling rotation; repair via service and bucket trucks; the power overlay, dark-tile mask, `block_dark` and the block blackout/relight with `restore_order`; player-drawn routing with the route-along-roads assist; the save section and offline coarse path.

**Deferred:** black start as a player action (§2.11 auto-restart ships instead); batteries; solar and wind generation (tables ship, buildable later); underground feeders, flood walls and surge arresters (fields exist, defaulted); nuclear, plant L4–5, substation L4–5, transformer L5, feeder class 3; `FUEL_SHORTAGE`, `PLANT_FAULT`, `SUB_FLOOD`, backup generators; preventive maintenance jobs (condition still decays, repair still restores it); regional imports/exports; tiered `powered_fraction` (the field ships, the value stays binary).

---

## 7. Test Plan (headless, `tests/sim/power/`)

1. `test_demand_aggregation` — WE-1 exactly, against doc 02's `base_kw` fixture: T7 = **685.9 ± 0.1 kW**, T8 = **338.9 ± 0.1**, feeder = **1,024.8 ± 0.2**. *(Was 533.5 / 188.3 / 721.8 — recomputation R-06/R-07.)*
2. `test_demand_channels` — the same apartment L3 at hour 4 vs hour 20 yields `1.46 / 0.688 = **2.122 ± 0.005**`, read from `data/time.json` at test time and **not** hard-coded; asserts `data/power.json` contains no `tod_curves` key (C-32).
3. `test_capacity_derate` — at 45 °C `cap_eff` = base × 0.88 × condition term; the 0.80 floor holds at 60 °C.
4. `test_thermal_convergence` / `test_thermal_cooldown` — hold r = 1.0 for 2,000 ticks ⇒ `theta → 55 ± 0.5`; de-energize ⇒ `theta → 0` on the same tau.
5. `test_hazard_table` — `h` at r ∈ {0.8, 1.15, 1.3, 1.6, 2.0} matches §2.6 to three significant figures.
6. `test_burnout_timing_distribution` — 1,000 seeded runs at r = 1.3, 25 °C; median time-to-failure within ±20% of 3.0 game-hours.
7. `test_inverse_time_trip` — feeder at r = 1.30 trips at 174 ± 15 gs; at r = 1.04 never trips over 10 game-hours.
8. `test_auto_reclose_and_lockout` — transient fault recloses OK; persistent overload locks out after exactly 2 attempts.
9. `test_energization_dfs` — trip a substation; exactly its subtree goes DARK and nothing else; a 15-gs interruption causes no flicker.
10. `test_cascade_we3` — WE-3 replayed: D blocked at `r_after 1.404`, E succeeds at `0.927`, F trips at 63.8 ± 2 gs with `CASCADE_OVERLOAD` and the correct `cause_chain`.
11. `test_load_shedding_priority` — WE-4 replayed at 20:00: `system.demand_kw = 120,161 ± 50`, `deficit = 28,161 ± 50`, shed set = **{F14, F11, F7}** totalling 30,100 kW; no CRITICAL-bearing feeder shed while a discretionary one remains; equal scores break by descending load.
12. `test_rolling_shed_rotation` — after 30 game-minutes the shed set changes and total shed kW still covers the deficit.
13. `test_lightning_damage_resolution` — 10,000 injected `LightningStrike{target_ref, energy=1.0}` on one transformer: the `ds0/ds1/ds2/ds3` split matches `{1−p, 0.45p, 0.45p, 0.10p}` within ±2%; arrester L3 cuts the damage rate by 66% ± 3%; an underground feeder target always returns `ds0`. *(Replaces `test_lightning_targeting` — target selection is doc 07's, C-54.)*
14. `test_storm_exposure_publication` — a 20-tile overhead feeder crossing 4 park tiles publishes `weather_exposure 1.00`, `tree_adjacent true`, `span_count 5`; the underground twin publishes `0.00 / false / 5`; and a doc-06-injected `FEEDER_DOWN` resolves to `damage_fraction 0.20` with a `rebuild_overhead` job of `35 + 1.5 × 20 = 65 gm`. *(Replaces `test_wind_line_damage_rate`; the 30-feeder / 9.3-failure rate expectation moved to doc 06 with `R_storm_base`, C-53.)*
15. `test_heat_wave_death_spiral` — WE-2 end to end: `r = 2.794 ± 0.005`, `theta_ss = 472.3 ± 0.5`, and the transformer fails between **game-minute 3 and 11** across 200 seeds with a median of **6.25 ± 1.5 gm**. *(Was 6–16 gm; R-06/R-07.)*
16. `test_n1_headroom` — a known tie pair matches hand-computed `n1_headroom_kw` and `n1_ok_fraction`.
17. `test_upgrade_gate` — blocks at r_after = 0.91, allows at 0.89, reports `deficit_kw` exactly; cross-checked against doc 02's E2 fixture (`delta_power 76 kW`, requirement 87.4 kW).
18. `test_backup_generator` — hospital loses power, generator starts after 12 gs at 0.70 coverage, burns `output_kw × dt_gh` against a tier-M 16-gh tank, exhausts at the computed hour, then goes DARK; `fuel_kwh_burned` is published to doc 03 and no dollar figure is produced here.
19. `test_save_roundtrip` — 500 ticks with failures, save, load, 500 more; state and event stream identical to an uninterrupted run; the section writes `section_version`, never `schema_version` (C-25).
20. `test_offline_equivalence` — 6 game-hours live at 4 Hz vs the coarse path on the same seed: served energy within 3%, failure count within ±1, `power_availability_hour` within 0.02 per building, and the sub-step counter proves sub-stepping fired whenever r > 1.0.
21. `test_perf_budget` — 1,500 components, 4,000 ticks; wall time implies < 0.4 ms/tick on the CI reference machine.
22. `test_power_availability_hour` — WE-6: 27 dark minutes of a 130 kW hour returns **0.55 ± 0.005**; a fully served hour returns 1.0; a fully dark hour returns 0.0; a hospital on 0.70 backup for the same 27 minutes returns **0.865 ± 0.005**; accumulators reset at the hour boundary and survive a save in mid-hour (C-37).
23. `test_block_dark_and_restore_order` — a block crossing the 60% population+jobs threshold emits `BlockDarkChanged` (never `DistrictDarkChanged`); the restoration event carries `restore_order` equal to the energization DFS visit order and `powered_fraction ∈ {0.0, 1.0}` (C-38/C-39).
24. `test_grid_inventory_publication` — the C-11 starter set **as doc 09 §2.9.5 actually authors it** (1 × `plant_gas` L1, 1 × `substation` L1, **13 × transformer L1 + 9 × transformer L2 + 1 × transformer L3**, **147 feeder + 30 transmission = 177 line tiles**, all condition 1.0) publishes `plant_capacity_mw 8.0`, `rated_mva 6.0` + **`2.40`** (`13×0.05 + 9×0.15 + 1×0.40 = 0.65 + 1.35 + 0.40`), **`line_km 1.416`** (`177 × 0.008`; doc 09 displays it rounded as 1.42); feeding it to doc 03's `ExpenseLedger` yields **`E_grid = $74.9 ± 0.5/gh`** (C-12, report 98 RR-6). Inventory counts are read from `data/starter_city.json` at test time, not hard-coded here. *(Was 14 × L1 + 9 × L2, `rated_mva 2.05`, `line_km 0.88`, `E_grid $73 ± 1` — a manifest that no doc ships; the L3 exists because `WTR-1`'s 132 kW site load needs it.)*
25. `test_power_json_has_no_prices` — `data/power.json` contains none of `build_cost`, `upkeep_per_gh`, `fuel_cost_per_kwh`, `cost_frac_of_build`, `cost_per_tile`, `cost_per_level`, `tie_switch_cost`, `refuel_cost_per_gh_restored`; and every failure type in §2.8 exposes a `damage_fraction ∈ [0,1]` (C-07/C-08/C-12/C-16).

---

## 8. Tunables — `data/power.json`

```json
{
  "version": 2,
  "_price_note": "This file contains NO prices (report 98 C-07/C-08/C-12). Build cost and the grid price ladder: doc 03 §2.13(b). Recurring cost: doc 03 §2.4 E_grid, billed against the inventory fields below. Generation and diesel fuel price: doc 03 FUEL_PRICE_PER_MWH. Repair charge: doc 03 repair_cost(asset, damage_fraction) (C-16).",
  "_footprint_note": "Footprints are doc 02's for power_facility and substation (C-30). Transformers, feeders, transmission links, ties and backup generators are grid components, never placed via place_building, and carry grid geometry only.",
  "components": {
    "plant_gas": {"capacity_kw": [8000,18000,36000,70000,120000], "plant_capacity_mw": [8,18,36,70,120], "plant_efficiency_mult": [1.000,0.935,0.871,0.806,0.758], "blackstart_capable": [false,false,true,true,true], "wear_mult": [1.00,1.00,1.05,1.10,1.15]},
    "plant_solar": {"nameplate_kw": [2000,5000,10000,20000,36000], "plant_capacity_mw": [2,5,10,20,36]},
    "plant_wind": {"nameplate_kw": [3000,7000,14000,26000,45000], "plant_capacity_mw": [3,7,14,26,45]},
    "substation": {"capacity_kw": [6000,14000,30000,60000,110000], "rated_mva": [6.0,14.0,30.0,60.0,110.0], "feeder_slots": [2,3,4,6,8], "fault_repair_gm": [115,140,165,190,215]},
    "transformer": {"capacity_kw": [50,150,400,1000,2500], "rated_mva": [0.05,0.15,0.40,1.00,2.50], "service_radius_tiles": [3,4,5,6,8], "swap_repair_gm": [18,18,26,38,55], "grid_tiles": 1, "pole_mounted_max_level": 2},
    "feeder": {"capacity_kw": [1200,3000,7500], "km_per_tile": 0.008, "underground_cost_mult": 2.6, "span_tiles": 4, "splice_repair_gm_base": 20, "splice_repair_gm_per_tile": 0.8, "rebuild_repair_gm_base": 35, "rebuild_repair_gm_per_tile": 1.5, "underground_repair_mult": 2.2},
    "transmission": {"capacity_kw": [40000,90000,180000], "km_per_tile": 0.008, "span_tiles": 4, "repair_gm_base": 60, "repair_gm_per_tile": 2.0},
    "battery": {"energy_kwh": [4000,10000,24000,55000,120000], "power_kw": [1000,2500,6000,14000,30000], "rated_mva": [1.0,2.5,6.0,14.0,30.0], "round_trip_efficiency": 0.88, "charge_trigger_ratio": 1.15, "_status": "post_mvp"}
  },
  "upgrades": {
    "arrester": {"max_level": 3, "damage_reduction_per_level": 0.22},
    "flood_wall": {"max_level": 2, "depth_per_level_m": 0.6}
  },
  "demand": {
    "_curve_note": "Diurnal curves live ONLY in data/time.json (report 98 C-32). This doc's tod_curves block is deleted. doc 01's power_demand_civic was normalized from the retired CIV shape (24-h mean 0.959, factor 1.0426); power_demand_datacenter is flat 1.0.",
    "class_channel": {"RES": "power_demand_residential", "COM": "power_demand_commercial", "IND": "power_demand_industrial", "CIV": "power_demand_civic", "DC": "power_demand_datacenter"},
    "class_map": {"house": "RES", "apartment": "RES", "high_rise": "RES", "store": "COM", "office": "COM", "construction_yard": "IND", "police_station": "CIV", "fire_station": "CIV", "water_facility": "CIV", "power_facility": "CIV", "data_center": "DC", "substation": null},
    "k_cool": {"RES": 0.030, "COM": 0.035, "IND": 0.012, "CIV": 0.030, "DC": 0.055},
    "k_heat": {"RES": 0.028, "COM": 0.022, "IND": 0.010, "CIV": 0.026, "DC": 0.000},
    "cool_ref_c": 24, "heat_ref_c": 12, "demand_mult_cap": 2.2,
    "streetlight_kw_per_road_tile": 0.35, "streetlight_channel": "streetlight_load",
    "signal_kw_per_intersection": 0.6, "stadium_event_mult": 3.2
  },
  "thermal": {
    "transformer": {"theta_rated_c": 55, "tau_gs": 900}, "feeder": {"theta_rated_c": 40, "tau_gs": 300},
    "substation": {"theta_rated_c": 45, "tau_gs": 1200}, "transmission": {"theta_rated_c": 35, "tau_gs": 240},
    "heat_wave_still_air_mult": 1.10, "amb_derate_k_per_c": 0.008, "amb_derate_ref_c": 30,
    "amb_derate_floor": 0.80, "condition_capacity_floor": 0.55
  },
  "hazard": {
    "transformer": {"t_knee_c": 85, "t_span_c": 60, "h_hot_per_gh": 2.00, "h_cold_per_gh": 0.00012},
    "feeder": {"t_knee_c": 75, "t_span_c": 55, "h_hot_per_gh": 1.20, "h_cold_per_gh": 0.00008},
    "substation": {"t_knee_c": 80, "t_span_c": 60, "h_hot_per_gh": 0.90, "h_cold_per_gh": 0.00010},
    "transmission": {"t_knee_c": 70, "t_span_c": 55, "h_hot_per_gh": 0.70, "h_cold_per_gh": 0.00006},
    "plant": {"h_cold_per_gh": 0.00030, "overload_k": 2.0, "overload_ref_r": 0.9},
    "stress_exponent": 3.0, "cond_mult_k": 3.0, "wear_rate_per_gh": 0.00035, "wear_stress_k": 6.0,
    "repair_restores_condition_to": 0.85,
    "preventive_maintenance": {"condition_gain": 0.35, "duration_gm": 22, "_price": "doc 03 PM_COST_FRACTION x capital_value"}
  },
  "protection": {
    "r_pickup": 1.05, "reset_time_gs": 120, "k_trip": {"feeder": 120, "substation": 90, "transmission": 100},
    "t_trip_min_gs": 2.0, "t_trip_max_gs": 900.0, "transformer_hard_burnout_r": 3.0,
    "auto_reclose_delay_gs": 90, "auto_reclose_max_r": 0.98, "auto_reclose_max_attempts": 2, "manual_reclose_gm": 4,
    "_reclose_render_coupling": "doc 11's momentary_outage_s is DERIVED from these two keys, not chosen (report 98 C-40): momentary_outage_s >= 1.5 x (auto_reclose_delay_gs / 60) x auto_reclose_max_attempts. At 90 gs and 2 attempts that bound is 1.5 x 1.5 x 2 = 4.5 real seconds. SATISFIED: doc 11 ships momentary_outage_s = 4.50 in data/render.json, so the assertion holds at equality (report 98 RR-10 - no change is owed by either doc). Doc 11 owns the constant and the headless assertion that reads both files; retuning either key here changes what doc 11 must render, so retune them together."
  },
  "weather": {
    "_generation_note": "This doc generates no weather failures. Doc 07 owns lightning generation AND target selection (C-54); doc 06 owns storm damage generation (C-53). The former lightning target_weights / strike_radius_tiles and the h_wind roll are deleted.",
    "lightning": {"base_damage_prob": 0.55, "energy_scale_min": 0.6, "energy_scale_max": 1.6, "secondary_fire_prob": 0.25, "surge_absorbed_condition_loss": 0.05, "underground_immune": true,
      "damage_state_bands": {"ds1_trip": 0.45, "ds2_fault": 0.45, "ds3_destroyed": 0.10}},
    "storm_exposure": {"overhead_line_tile": 1.00, "transformer_pole": 0.80, "substation_yard": 0.35, "transformer_pad": 0.30, "plant": 0.20, "underground": 0.00, "tree_adjacent_min_tiles": 3, "reference_span_count": 60},
    "flood": {"sub_trip_depth_m": 0.40, "sub_fail_depth_m": 0.90, "sub_repair_time_mult": 3.0, "sub_repair_start_depth_m": 0.20, "underground_feeder_h_per_gh": 0.05, "transformer_depth_m": 0.5, "transformer_h_per_gh": 0.35},
    "solar_cloud_factor": {"CLEAR": 1.00, "CLOUDY": 0.55, "RAIN": 0.35, "THUNDERSTORM": 0.20, "SNOW": 0.30, "FOG": 0.45},
    "wind_curve": {"cut_in_mps": 3.5, "rated_mps": 12.0, "cut_out_mps": 24.0, "exponent": 3.0}
  },
  "shedding": {
    "priority_weight": {"CRITICAL": 1000, "ESSENTIAL": 40, "STANDARD": 8, "DISCRETIONARY": 1},
    "priority_override_bonus": 500, "rolling_shed_period_gm": 30, "major_outage_demand_frac": 0.40,
    "tie_break": ["shed_score_asc", "load_kw_desc", "component_id_asc"]
  },
  "redundancy": {"transfer_delay_gs": 20, "auto_transfer_max_r": 0.95, "aggressive_transfer_max_r": 1.35, "cascade_window_gs": 60},
  "service": {
    "dark_threshold_frac": 0.35, "dark_hold_gs": 20, "lit_threshold_frac": 0.55, "lit_hold_gs": 10,
    "block_dark_frac": 0.60, "upgrade_gate_max_r": 0.90,
    "availability_settle_cadence": "EVERY_HOUR", "availability_default_unmetered": 1.0
  },
  "repair": {
    "_pricing_note": "damage_fraction only (report 98 C-16). doc 03 computes capital_value x damage_fraction x 0.85 x M_repair.",
    "damage_fraction_by_failure": {"FEEDER_TRIP": 0.005, "SUB_TRIP": 0.005, "PLANT_TRIP": 0.02, "FEEDER_FAULT": 0.05, "FEEDER_DOWN": 0.20, "PLANT_FAULT": 0.25, "SUB_FAULT": 0.30, "SUB_FLOOD": 0.30, "XFMR_BURNOUT": 0.35, "XFMR_LIGHTNING": 0.35, "DS3_DESTROYED": 1.00, "BACKUP_GEN_FAIL": 0.00, "FUEL_SHORTAGE": 0.00},
    "plant_restart_gm_base": 25, "plant_restart_gm_per_level": 10, "plant_fault_gm_base": 240, "plant_fault_gm_per_level": 60,
    "storm_mult_k": 0.5, "night_mult": 1.15, "skill_reduction_per_level": 0.08,
    "mobile_transformer": {"setup_gm": 6, "capacity_frac": 0.60}
  },
  "backup": {
    "_owner_note": "This doc owns the generator fuel model and refuelling for EVERY backup-capable sink, including doc 05's water nodes (report 98 C-36). doc 05 owns coverage_frac for those nodes and publishes it here. Diesel is priced by doc 03 at FUEL_PRICE_PER_MWH.diesel.",
    "tiers": {"S": {"capacity_kw": 150, "fuel_gh": 8, "fuel_efficiency_mult": 1.000},
              "M": {"capacity_kw": 600, "fuel_gh": 16, "fuel_efficiency_mult": 0.905},
              "L": {"capacity_kw": 2500, "fuel_gh": 48, "fuel_efficiency_mult": 0.810}},
    "start_delay_gs": 12, "start_success_base": 0.94,
    "coverage_frac": {"hospital": 0.70, "data_center": 0.55, "police_station": 0.85, "fire_station": 0.85, "default": 0.60,
                      "_water": "read from doc 05 per node (0.60 at L2 rising to 1.00 at L5); never authored here"},
    "refuel_gm": 14
  },
  "blackstart": {"auto_restart_gm": 12, "substation_reclose_interval_gs": 30, "cold_load_pickup_mult": 1.70, "cold_load_duration_gm": 10, "_status": "post_mvp_ui"},
  "overlay": {"snapshot_hz": 1, "color_thresholds": {"warning_r": 0.75, "critical_r": 0.95}, "grid_health_weights": {"served": 0.5, "not_overloaded": 0.3, "condition": 0.2}},
  "offline": {"coarse_step_gh": 1.0, "substep_gs": 300, "substep_trigger_r": 1.0, "substep_on_storm": true},
  "perf": {"max_components_soft": 1500, "tick_budget_ms": 0.4, "thermal_shard_count": 1}
}
```

---

## 9. Conflicts & Open Questions

**Conflicts with the constitution**

1. **None blocking.** One tension to record: §4 locks utilities at 4 Hz. Thermal integration genuinely does not need 4 Hz (tau ≥ 240 gs), and §2.4 reserves the right to shard Pass C across 4 ticks under profiling pressure. That is an implementation detail *inside* the locked cadence, not a deviation from it — flagged so `perf.thermal_shard_count` surprises nobody.
2. **Doc numbering — RESOLVED.** Report 98 Ruling Zero makes the on-disk filenames canonical. §5 has been renumbered in full: world/land/population is **09**, roads is **10**, buildings is **02**, economy is **03**, water is **05**, incidents/dispatch is **06**, weather + Director is **07**, persistence/offline is **08**, rendering is **11**, UI/overlays is **12**. No doc-number reference elsewhere in this file uses the old map.

**Resolved by report 98 (recorded, not open)**

3. **`base_kw` ownership — RESOLVED (C-31).** Doc 02 owns it. This doc's reference table is deleted; WE-1, WE-2, WE-4 and tests 1/2/15 are recomputed against doc 02's post-C-13 `Pwr kW` column. The formulas were unchanged; only numbers moved, and they moved *up* — an apartment L3 is 130 kW, not 120, and the RES diurnal curve is no longer silently de-rated by 0.79.
4. **`priority_class` and `backup_capable` — RESOLVED.** Doc 02 publishes both as building properties (its critical-facility priority tier). Pass B shedding has its input.
5. **Incident ownership boundary — RESOLVED (C-53, and doc 06 §5 concurs).** Doc 06 owns the queue, dispatch, travel, crew scheduling and **all incident generation**; this doc constructs its own component-failure incidents from *its own* physics (thermal, protection, flood) and applies repair effects. Storm and lightning generation are not its physics and are not its incidents.
6. **Water pump `base_kw` — RESOLVED (C-35/C-36).** Doc 02 owns the `water_facility` shell and `base_kw`, doc 05 owns the per-variant anchors and `coverage_frac`, this doc owns the generator fuel model. Generation sizing here still assumes pumps are ~4% of citywide demand; doc 05's rescaled ladder (C-34) is consistent with that.
7. **Traffic-signal outage effect — RESOLVED (G-6).** Doc 10 owns it (`DARK_SIGNAL_DELAY 0.45 gm`, `DARK_SIGNAL_ADD 0.19`). This doc emits `TrafficSignalPowerChanged` and consumes nothing.
9. **Manual feeder routing vs auto-route — RESOLVED (C-41).** Player-drawn is primary, with a "route along roads" assist that fills the polyline and still requires confirmation. Recorded in §2.1 and §4; doc 12 owns the drag UX. This question is **closed**.

13. **Reclose ↔ `momentary_outage_s` coupling — RESOLVED, SATISFIED (C-40, report 98 RR-10).** With `auto_reclose_delay_gs = 90` and `auto_reclose_max_attempts = 2`, the ruled bound is `momentary_outage_s ≥ 1.5 × (90/60) × 2 = 4.5` real seconds. **Doc 11 ships `momentary_outage_s = 4.50` in `data/render.json`, so the bound holds at equality and the headless assertion passes.** This doc's former request that doc 11 raise the constant is **deleted** — it described a pre-amendment world. Nothing is outstanding: doc 11 owns the constant and the assertion, this doc owns the two `protection` keys, and the only live obligation is that they are retuned together (§8 `_reclose_render_coupling`).

**Open questions for the overseer**

8. **Is the burnout tempo right for mobile?** At r = 1.3 a transformer dies in ~3 real minutes; at r = 1.6, ~12 real seconds; and WE-2's heat-wave case is now a **6.25 game-minute** median rather than 8–12, because C-13 and C-32 both push demand up. Deliberately sharp so overload feels dangerous, but it may punish a player who puts the phone down mid-session. Options: (a) keep as is; (b) scale `h_hot` by difficulty (Casual ×0.5, Hard ×1.6) — the knob would live in doc 03's `data/difficulty.json` per C-17, not here; (c) a one-time grace that freezes hazard for 60 game-seconds on first entry into CRITICAL. **Recommend (b).**
10. **Is `plant_gas` the only MVP generation?** Wind creates the best weather coupling — a storm kills wind output *while* doc 06 knocks down lines — at the cost of one more build menu in onboarding. Currently deferred; happy to promote wind into MVP if the thunderstorm slice wants more teeth.
11. **Fuel as a resource or a cost line?** Currently pure money via doc 03's `FUEL_PRICE_PER_MWH`, with `FUEL_SHORTAGE` on treasury insolvency. Delivered-fuel stock (tanks, resupply convoys, blizzard delivery failure) is a richer crisis vector but a whole logistics subsystem. Deferred by default — confirm.
12. **Should street lighting be separately switchable?** Today streetlights die with their transformer. A separate lighting circuit would let the player shed lighting to save residential load, paying a crime penalty to docs 06/09 — a genuinely interesting tradeoff, but one more concept in the overlay.

---

## 10. Amendments applied (report 98)

| Ruling | Change made in this doc |
|---|---|
| **Ruling Zero** | §5 renumbered to the canonical on-disk map (09 world/population, 10 roads, 02 buildings, 03 economy, 05 water, 06 incidents, 07 weather+Director, 08 persistence, 11 rendering, 12 UI); every in-line doc reference in §§1–9 corrected; §9 item 2 closed. |
| **C-07** | All `build_cost` / `cost_per_tile` / `cost_per_level` / `tie_switch_cost` rows deleted from §2.2 and §8; prices now read from doc 03 §2.13(b). Worked examples requote at doc 03's ladder (transformer L4 $6,900, L3 $2,800). |
| **C-08** | `upkeep_per_gh` deleted from every component in §2.2 and §8; recurring cost is doc 03's `E_grid`. |
| **C-12** | §2.2 now publishes the **inventory** doc 03 bills — `rated_mva`, `line_km` (= tiles × 0.008), `plant_capacity_mw`, `condition` — with exact definitions; new test 24 asserts the starter set yields `E_grid = $73/gh`. *(Superseded in Round 2 — **RR-6** re-based test 24 on doc 09 §2.9.5's real starter inventory: the assertion is now `E_grid = $74.9 ± 0.5/gh`. Class of fix: stale-figure correction, not a change of contract — §2.2 still publishes the same four inventory fields C-12 established.)* `fuel_cost_per_kwh` deleted, replaced by the dimensionless `plant_efficiency_mult` doc 03 asked for. |
| **C-16** | §2.8's `cost_frac_of_build` table re-expressed as **`damage_fraction` per failure type**; incident payload carries `damage_fraction`, not `repair_cost`; WE-5 recomputed ($19,250 → $2,053 via doc 03). |
| **C-25** | Save section key renamed `schema_version` → **`section_version`**; test 19 asserts it. |
| **C-30** | This doc keeps every electrical capacity and topology number and **deletes its `footprint` column**; footprints are doc 02's (substation is now 2×2 at all levels). Transformers/feeders/transmission/ties/backup gens restated as grid components never placed via `place_building`. |
| **C-31** | The `base_kw` reference table is **deleted**; §2.3 reads doc 02's `Pwr kW`. WE-1 (T7 533.5 → **685.9 kW**), WE-2 (r 2.171 → **2.794**) and tests 1/2/15 recomputed. |
| **C-32** | `demand.tod_curves` **deleted**; §2.3 consumes `ctx.channels.power_demand_*` with an explicit class→channel and archetype→class map; streetlights read `streetlight_load`. WE-4 recomputed on normalized channels. |
| **C-36** | §2.10 restated: this doc owns generator fuel and refuelling for **all** backup-capable sinks; doc 05's `coverage_frac` is an input and its `water_pump_station` row is removed from the authored table; `fuel_cost_per_kwh` replaced by `fuel_efficiency_mult`. |
| **C-37** | Per-building `served_kwh` / `demanded_kwh` accumulation added to §2.4, the save section, the API (`settle_hour`, `power_availability_hour()`), WE-6 and test 22. |
| **C-38** | `district_dark` → **`block_dark`** in §2.4, §4 (`BlockDarkChanged`), §5.1 and §8 (`service.block_dark_frac`); doc 09 derives the district aggregate. |
| **C-39** | `restore_order: PackedInt32Array` (energization-DFS visit order) and `powered_fraction: float` added to the restoration payload in §4, sourced in §2.4/§2.11, tested in test 23. |
| **C-40** | §8 `protection` carries an explicit `_reclose_render_coupling` comment with the bound `momentary_outage_s ≥ 1.5 × (delay_gs/60) × attempts = 4.5 s`. *(The follow-on claim that doc 11's 2.50 fails the bound was removed in Round 2 — see RR-10 below.)* |
| **C-41** | Player-drawn routing with a route-along-roads assist recorded in §2.1, §4 (`suggest_route_along_roads`) and §5.10; open question 9 **closed**. |
| **C-53** | The `h_wind` wind-damage roll and its `veg_mult` / `ice_mult` constants are **deleted**; §2.7.4 now publishes `weather_exposure` / `tree_adjacent` / `condition` / `underground` / `span_count` for doc 06's storm generator; test 14 replaced. |
| **C-54** | The lightning target-weight table and `strike_radius_tiles` selection are **deleted**; §2.7.3 keeps damage resolution as explicit `ds0..ds3` bands for doc 07 to reference; test 13 replaced. |
| **R-06** | WE-1/WE-2/WE-3/WE-4 and tests 1/2/15 recomputed against doc 02's `base_kw`. |
| **R-07** | Demand aggregation recomputed against doc 01's normalized channels: per-class 24-hour uplift **RES +25.9%, COM +29.6%, IND +20.8%, CIV +4.3%, DC 0%**, a **+20.1%** citywide mean on the WE-4 mix. |
| **R-08** | Cost rows removed rather than rescaled (doc 03 published the rescaled ladder); every price quoted in this doc's examples now cites doc 03's figures. |

### Round 2 (report 98 §14 — post-verification rulings)

| Ruling | Change made in this doc |
|---|---|
| **RR-6** | Test 24's inventory and `E_grid` expectation re-based on doc 09 §2.9.5's **real** starter topology: transformers `14×L1 + 9×L2` → **`13×L1 + 9×L2 + 1×L3`**, `rated_mva 2.05` → **2.40**, lines `110 feeder tiles = 0.88 km` → **`147 feeder + 30 transmission = 177 tiles = 1.416 km`**, `E_grid $73 ± 1/gh` → **`$74.9 ± 0.5/gh`**. The full derivation (`8.00×5.0 + 6.00×4.0 + 2.40×4.0 + 1.416×0.9 = 74.874`) is shown in §2.2; the counts are read from `data/starter_city.json` at test time rather than hard-coded. |
| **RR-10** | (a) The §9 claim that doc 11's `momentary_outage_s = 2.50` fails the C-40 bound is **deleted** — doc 11 shipped **4.50 s**, which satisfies `≥ 4.5 s` at equality; §9 item 13 and the §8 `_reclose_render_coupling` comment now record C-40 as **satisfied**, and the C-40 changelog row above is corrected. (b) §2.13's pre-C-11 starter quote ("**508 kW** building load, **15×** headroom") is **deleted** and restated from doc 09's R-16 results: **402.0 kW nameplate** and the published **783.3 kW** 20:00 night peak (460.69 building + 274.05 streetlight + 48.60 signal), giving recomputed headroom of **×19.90 on nameplate** and **×10.21 on the night peak** against one `plant_gas` L1. Owner pointer: doc 09 §2.9.4. |
| **RR-1** | Confirmed, no change needed: this doc emits **`BlockDarkChanged`** and nothing else — §4 (event list and restoration payload), §5.9 and test 23 all use it, and the only occurrences of `DistrictDarkChanged` are the explicit "renamed from" annotations in §4, test 23's negative assertion and the C-38 changelog row. The rename obligation is doc 11's consumption sites. |

### Round 3 (report 98 §15 — closing-audit rulings)

| Ruling | Change made in this doc |
|---|---|
| **RR-18** | The **C-12 changelog row** above still described test 24 as asserting `E_grid = $73/gh` — the pre-RR-6 figure — making it the last surviving statement of the stale number in this doc. It is now annotated in place with the RR-6 correction: test 24 asserts **`E_grid = $74.9 ± 0.5/gh`** on doc 09 §2.9.5's real inventory. **Class of fix: stale-figure correction in a historical changelog row — no contract, tunable, formula or live test expectation changes.** Arithmetic restated for the record: `8.00 MW × $5.0 + 6.00 MVA × $4.0 + 2.40 MVA × $4.0 + 1.416 km × $0.9 = 40.000 + 24.000 + 9.600 + 1.2744 = $74.8744/gh → $74.9/gh`; the old $73 sits **1.874** below that, well outside the **±0.5** band (`[74.4, 75.4]`), so the row was wrong rather than merely rounded. Audit of the other three `$73` occurrences (§2.2 "superseded set is deleted", test 24's "*Was …*" parenthetical, the RR-6 row) confirms each already reads as explicitly superseded and is left untouched. §8 tunables carry no dollar figures (C-07/C-08/C-12) and are unaffected. |
