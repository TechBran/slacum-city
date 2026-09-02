# 02 — Building Archetypes, the Five-Level Upgrade System & Construction Projects

**Status:** Draft v2.2 — amended per `98-consistency-report.md` §1–§13 (wave 1), **§14 ROUND 2 rulings RR-8 / RR-9** and **§15 ROUND 3 ruling RR-19** (all BINDING). Subordinate to `00-constitution.md` (LOCKED). Parent spec: `docs/BLACKOUT-spec.md` §9, §10, §12, §43.2, §46, §55.
**Owns:** `data/buildings.json` (non-money columns), `data/building_rules.json`, `sim/buildings/*`, `sim/construction/*`, the `buildings` and `construction` save sections.
**Does not own:** any currency figure (doc 03), electrical capacity/topology (doc 04), water capacity/pressure (doc 05), fire dynamics and unit capacity (doc 06), weather effect channels (doc 07), population/occupancy/city level (doc 09), road access (doc 10).

See §10 for the full list of report-98 rulings applied (wave 1 plus the **Round 2** and **Round 3** sub-tables).

---

## 1. Overview & Goals

Buildings are the atoms of SLACUM CITY. Every number the player watches on the dashboard — population, treasury, grid load, water demand, fire risk, crime — is an aggregate of building rows. This document defines the 12 MVP archetypes (spec §43.2), their levels — five each under Core Design Rule 5, **six for §2.14's growth stock** — the exact stat curve family, the upgrade gate logic (spec §9.4), the building lifecycle state machine, and the construction project queue (spec §12).

**Goals**

1. **Every upgrade is a trade, never a free stat bump** (Pillar 5, Core Rule 3). Output rises ~1.55–2.10× per level; power and water demand rise *faster* (**2.35–2.55×**) than doc 03's `TAX_LEVEL_GROWTH = 2.15`, so every single upgrade is **8.5 % (steady) / 12.2 % (standard) / 15.7 % (vertical) less utility-efficient per tax dollar** than the level below it. Going tall buys **land efficiency and skyline**, not better ROI.
2. **Infrastructure gates verticality.** A building cannot climb past the capacity of the grid and pressure zone that serve it. "Upgrade blocked: nearby electrical capacity insufficient" (spec §9.4) is the signature moment of this system.
3. **One coherent, hand-checkable curve family.** Three growth classes, four multipliers each. An engineer or balancer can regenerate every number in this doc from the seed row and the multipliers.
4. **Buildings decay and burn.** Condition is a live, decaying number on `[0,1]`, not a cosmetic. A neglected city is a flammable city.
5. **Construction is a queue, not an instant.** Projects consume crew-hours from doc 06's crews, are throttled by doc 01's `construction_rate` channel, and can be reordered and cancelled (spec §12).
6. **No magic numbers in code.** Everything in §8 goes to `data/building_rules.json`; `sim/` reads only from there.

**Non-goals for MVP:** stadium/hospital/school/factory/warehouse (spec §9.1 archetypes 7, 8, 10, 11, 12), per-floor simulation, building rotation for non-square footprints, aesthetic/land-value modifiers.

---

## 2. Mechanics

### 2.1 Roster & taxonomy

12 archetypes, 5 levels each = 60 data rows. Categories drive UI grouping and a few shared rules.

| id | Name | Category | Growth class | Produces |
|---|---|---|---|---|
| `house` | House | residential | steady | population |
| `apartment` | Apartment Block | residential | standard | population, some jobs |
| `store` | Commercial Store | commercial | steady | jobs |
| `office` | Office Building | commercial | standard | jobs |
| `high_rise` | Mixed-Use High-Rise | residential | vertical | population + jobs |
| `data_center` | Data Center | industrial | vertical | jobs, extreme demand |
| `police_station` | Police Station | service | standard | police coverage |
| `fire_station` | Fire Station | service | standard | fire coverage |
| `power_facility` | Power Facility | utility | vertical | generation shell (capacity: doc 04) |
| `substation` | Substation | utility | standard | grid node shell (capacity: doc 04) |
| `water_facility` | Water Facility | utility | standard | water node shell, **5 variants** (capacity: doc 05) |
| `construction_yard` | Construction Yard | service | steady | crew home + reach (crew count: doc 06) |

Tax classes for the revenue archetypes (`residential | commercial | industrial | tech`) are declared in `data/buildings.json` and consumed by doc 03; this doc never assigns a dollar figure to them.

**Level acquisition rule (LOCKED for MVP):** every archetype can only be *constructed* at Level 1. Levels 2–5 are reached exclusively through the upgrade path. There is no "build a Level 4 office directly" shortcut. This keeps the upgrade loop (spec §44) mandatory and makes `min_city_level` gates meaningful.

**`water_facility` variants** *(report 98 C-35, footprints per RR-8).* One archetype id, five node kinds. The **shell and the variant list are owned here**; every per-variant number — **`footprint`**, `base_kw`, capacity, storage volume, head, `coverage_frac` — is owned by **doc 05** and read from `data/water.json`.

| `variant` | Role | Doc 05's L1 footprint | Per-variant numbers owned by |
|---|---|---|---|
| `source` | Raw intake (river / well field) | 2×2 river · 1×1 well | doc 05 |
| `treatment` | Treatment plant | 2×2 | doc 05 |
| `pump` | Pump station — **the reference variant** the §2.3 shell table is generated for | 3×3 | doc 05 (= doc 02's shell) |
| `tank` | Elevated / ground storage (gravity-fed, near-zero draw) | **2×2** | doc 05 |
| `booster` | In-zone booster pump | 1×1 | doc 05 |

Placement command is `place_building{type: "water_facility", variant: "tank"}`. Core Rule 5 (five levels per archetype) is satisfied **per variant**. The variant is immutable after placement; changing kinds means demolish and rebuild.

### 2.2 The curve family

Everything scales geometrically off the Level-1 seed row: `value(L) = round_rule( seed × k^(L-1) )`.

| Growth class | k_out (pop, jobs, coverage radii) | **k_dem (power, water)** | k_time (crew-hours) | Members |
|---|---|---|---|---|
| **steady** | 1.55 | **2.35** | 1.40 | house, store, construction_yard |
| **standard** | 1.85 | **2.45** | 1.55 | apartment, office, police_station, fire_station, substation, water_facility |
| **vertical** | 2.10 | **2.55** | 1.70 | high_rise, data_center, power_facility |

> **`k_dem` is the single most load-bearing balance constant in the game** (report 98 C-13). Doc 03 requires `DEMAND_LEVEL_GROWTH > TAX_LEVEL_GROWTH = 2.15` so that every upgrade is strictly less utility-efficient (spec §55 rule 3 / Pillar 5). All three classes are now strictly above 2.15, ordered so that taller buildings degrade efficiency fastest. **Do not lower these without re-ruling C-13.**
>
> Efficiency loss per level = `1 − 2.15 / k_dem`: steady `1 − 2.15/2.35 = 8.5 %`, standard `1 − 2.15/2.45 = 12.2 %`, vertical `1 − 2.15/2.55 = 15.7 %`.
> Compounded L1 → L5: steady `2.35⁴/2.15⁴ = 30.50/21.37 = 1.427` (an L5 draws 42.7 % more utility per tax dollar than an L1), standard `36.03/21.37 = 1.686` (+68.6 %), vertical `42.28/21.37 = 1.978` (+97.8 %).

**Costs are not in this table.** `build_cost_l1`, `upgrade_cost`, `capital_value`, `base_tax` and all recurring upkeep are owned by **doc 03 §2.2–2.4** (`CostCurves.upgrade_cost() / capital_value() / base_tax()`, `UPG_COEFF 1.45`, `UPG_GROWTH 2.55`, `TAX_LEVEL_GROWTH 2.15`, `BUILDING_MAINT_RATE 0.00040`). This doc supplies only `class` and consumes the curves. *(Report 98 C-07, C-08, C-10.)*

Cross-class constants (identical for all 12 archetypes):

| Constant | Value | Applies to |
|---|---|---|
| `k_decay` | **1.20** | `decay_per_hour` (a fraction of condition, `[0,1]`) |
| `k_fire_rate` | **1.28** | `fire_ignition_per_hour` |
| `k_fire_load` | **2.00** | `fire_load` (consequence index) |
| `k_crime` | **1.60** | `crime_weight` (selection weight) |
| `k_radius` | **1.25** | coverage radii (police, fire, construction yard) |
| `upgrade_time_factor` | **0.65** | `upgrade_time(L→L+1) = build_time(L+1) × 0.65` |

**Rounding rules** (deterministic; **half-up at every tie**; applied once at table-generation time to the raw product `seed × k^(L−1)`, never at runtime, and never to an already-rounded cell — see §2.3's seed table, report 98 RR-8):

- time (crew-hours): `<20` → nearest 0.5; else nearest 1.
- kW: `<10` → 0.5; `<100` → 1; `<1 000` → 5; `<10 000` → 10; else 50.
- WU/gh (= m³/h): `<1` → **nearest 0.01**; `<10` → 0.1; `<100` → 0.5; else 1.
  *The sub-unit step is new: after the C-34 rescale by 1/6.25, an L1 house is 0.08 m³/h and the old 0.1 step would destroy the anchor.*
- population/jobs/radii: nearest integer.
- decay: 6 decimal places.

There is no money or cents rounding rule here any more — doc 03 owns every rounded currency figure.

**Consequence of the family (stated deliberately, not accidentally):** because doc 03's `UPG_GROWTH 2.55 > TAX_LEVEL_GROWTH 2.15`, payback time lengthens with level. **Regenerated against doc 03's `build_cost_l1`, `base_tax_by_level`, `upgrade_cost_by_step` and `capital_value_by_level`** *(report 98 R-03)*:

```
net_income(L)   = base_tax(L) − capital_value(L) × BUILDING_MAINT_RATE      (full occupancy,
                                                                             full service, C = 1.0)
payback(L1)     = build_cost_l1 / net_income(1)
payback(L≥2)    = upgrade_cost(L−1 → L) / net_income(L)
total_spend     = build_cost_l1 + Σ upgrade_cost = capital_value(5)
payback(L1→L5)  = total_spend / net_income(5)
```

`BUILDING_MAINT_RATE = 0.00040 /gh` (doc 03 §2.4), levied on revenue buildings only — the six civic/utility archetypes are covered by doc 03's `station_upkeep` / `E_grid` / `E_water` lines instead, and appear in no payback row.

| archetype (doc 03 class) | L1 | L2 | L3 | L4 | L5 | L1→L5 total spend / L5 payback |
|---|---|---|---|---|---|---|
| house (residential, $1,200) | 104.2 gh | 70.1 | 85.2 | 101.4 | 121.7 | $47,544 / 200.6 gh |
| store (commercial, $2,600) | 104.2 | 70.5 | 84.6 | 101.4 | 121.4 | $103,012 / 200.1 gh |
| apartment (residential, $7,000) | 104.2 | 70.4 | 84.4 | 101.2 | 121.5 | $277,340 / 200.2 gh |
| office (commercial, $13,000) | 104.2 | 70.5 | 84.5 | 101.2 | 121.5 | $515,060 / 200.3 gh |
| high_rise (residential, $26,000) | 104.2 | 70.7 | 84.5 | 101.2 | 121.5 | $1,030,120 / 200.3 gh |
| data_center (tech, $180,000) | 88.8 | 60.2 | 71.8 | 85.9 | 103.0 | $7,131,600 / 169.7 gh |

Worked check, house L3: `capital_value(3) = 1,200 × 6.147 = $7,376`; maintenance `7,376 × 0.00040 = $2.95/gh`; `net = 55 − 2.95 = $52.05/gh`; `upgrade_cost(2→3) = 1,200 × 3.6975 = $4,437`; `4,437 / 52.05 = 85.2 gh`. ✔

(1 game-hour = 60 real seconds while the app is open, per constitution §4.) Three readings fall out and all three are intended:

- **The L2 dip is intentional** — the cheapest upgrade in the game is the first one, which teaches the mechanic.
- **Payback is now almost class-invariant** (~104 / 70 / 85 / 101 / 122 gh) because doc 03 generates tax from cost through one yield anchor. The only outlier is `data_center` (tech yield 0.0117 vs residential 0.0100), which pays back ~15 % faster in dollars — and buys that with 42× the L1 power draw. **The trade against going tall is now carried entirely by utility demand and risk, not by dollar payback.** That is exactly what C-13 makes true.
- Doc 03 §2.3 quotes a *marginal* payback of ~126 / 150 / 177 / 210 gh (`upgrade_cost ÷ Δtax`). That is a different quantity from this table (`upgrade_cost ÷ total net income at the new level`) and the two must not be compared row-to-row.

After that, **the reason to go tall is that you have run out of land, coverage budget, or road frontage — not that towers print money faster.**

### 2.3 Full stat tables

Columns: `Foot` = footprint w×h in tiles (1 tile = 8 m, constitution §6) — **authoritative for all 12 archetypes, including the three utility shells** (report 98 C-30), with one carve-out: for `water_facility` the column is the **`pump` reference variant only**; the other four variants' footprints are **doc 05's** per-variant property *(report 98 RR-8 — see §2.3's `water_facility` note)*. `Pwr` = `power_demand_kw`. `Water` = `water_demand`, in WU/gh where **1 WU ≡ 1 m³/h** (report 98 C-34). `Build/Upg gh` = **crew-hours** at crew rate 1.0, not wall time (see §2.10). `Decay` = fraction of condition lost per game-hour on the `[0,1]` scale. `Fire p/gh` = base ignition probability per game-hour — **normative, doc 06 must not re-weight it** (report 98 C-42). `FireLoad` = fire consequence index; doc 06 derives `S_req_base` from it (§2.7). `Crime` = `crime_weight` selection weight. `ReqFire`/`ReqPol` = coverage required to reach and hold that level. `CityLv` = minimum city level (doc 09 owns `city_level`).

**Build cost, upgrade cost, upkeep and tax columns are absent by ruling — see doc 03 §2.2–2.4 and `data/economy.json`.**

**These tables are the first FIVE rungs.** Six of the twelve archetypes carry a sixth, generated by the same formulas at `e = 5`; **§2.14 publishes those six rows**, and it is the same table continued rather than a separate one. A reader reconstructing the whole ladder needs both sections. *(Wave 10.)*

Generating formulas for the two regenerated columns *(report 98 R-01)*:

```
power_demand_kw(L) = round_kw( power_kw_seed × k_dem^(L−1) )
water_demand(L)    = round_wu( water_wu_seed  × k_dem^(L−1) )    water_wu_seed = old_water_wu_L1 / 6.25
k_dem = 2.35 steady | 2.45 standard | 2.55 vertical
rounding: §2.2 ladders, half-up at every tie, applied ONCE per cell to the raw product
```

**Generation runs from the unrounded seeds, never from a printed table cell** *(report 98 RR-8, verifier finding F-07)*. The C-34 rescale divided the old water column by 6.25, which produced three seeds that are not representable in the display ladder of §2.2 (`<1` → 0.01, `<10` → 0.1). Re-growing a level from the **rounded** L1 cell instead of the seed breaks 8 of the 60 water cells (`store` L2/L3/L5, `high_rise` L3/L4/L5, `police_station` L3/L5). Both numbers are therefore published: the seed is normative, the table cell is display.

**Unrounded L1 water seeds — normative** (the same values ship in §8 `seed_rows[*].water`; `data/buildings.json` is generated from these, and `§7 test 2` regenerates from these):

| archetype | old WU/gh (pre-C-34) | ÷ 6.25 = **seed (normative)** | L1 cell as displayed in §2.3 | differ? |
|---|---|---|---|---|
| `house` | 0.5 | **0.08** | 0.08 | — |
| `apartment` | 3.0 | **0.48** | 0.48 | — |
| `store` | 0.8 | **0.128** | 0.13 | **yes** |
| `office` | 2.0 | **0.32** | 0.32 | — |
| `high_rise` | 8.0 | **1.28** | 1.3 | **yes** |
| `data_center` | 20.0 | **3.2** | 3.2 | — |
| `police_station` | 1.2 | **0.192** | 0.19 | **yes** |
| `fire_station` | 2.5 | **0.40** | 0.40 | — |
| `power_facility` | 6.0 | **0.96** | 0.96 | — |
| `substation` | 0 | **0** | 0 | — |
| `water_facility` (`pump`) | 0 | **0** | 0 | — |
| `construction_yard` | 1.0 | **0.16** | 0.16 | — |

Worked check on the worst offender, `store` (steady, `k_dem 2.35`): from the seed `0.128 × 2.35 = 0.3008 → 0.30` ✔ (published 0.30), `0.128 × 2.35² = 0.70688 → 0.71` ✔, `0.128 × 2.35⁴ = 3.903745 → 3.9` ✔. From the printed cell 0.13 the same three come out `0.30550 → 0.31`, `0.717925 → 0.72`, `3.964741 → 4.0` — three wrong cells out of four. `high_rise` L5: `1.28 × 2.55⁴ = 54.121608 → 54.0` ✔ against `1.3 × 2.55⁴ = 54.967258 → 55.0` ✗. `police_station` L5: `0.192 × 2.45⁴ = 6.917761 → 6.9` ✔ against `0.19 × 2.45⁴ = 6.845701 → 6.8` ✗.

The **`Pwr kW` column needs no seed table**: every L1 power figure is already exact on its own rounding ladder, so seed and printed cell coincide for all 12 archetypes and all 60 power cells regenerate from the table itself.

#### `house` — steady (k_dem 2.35)
| L | Foot | Pop | Jobs | Pwr kW | Water WU/gh | Build gh | Upg gh | Decay | Fire p/gh | FireLoad | Crime | ReqFire | ReqPol | CityLv |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 1x1 | 4 | 0 | 3.0 | 0.08 | 2 | 2 | 0.000450 | 0.00015 | 20 | 1.00 | 0.00 | 0.00 | 0 |
| 2 | 1x1 | 6 | 0 | 7.0 | 0.19 | 3 | 2.5 | 0.000540 | 0.00019 | 40 | 1.60 | 0.20 | 0.15 | 1 |
| 3 | 1x1 | 10 | 0 | 17 | 0.44 | 4 | 3.5 | 0.000648 | 0.00025 | 80 | 2.56 | 0.40 | 0.35 | 2 |
| 4 | 1x1 | 15 | 0 | 39 | 1.0 | 5.5 | 5 | 0.000778 | 0.00031 | 160 | 4.10 | 0.60 | 0.55 | 3 |
| 5 | 1x1 | 23 | 0 | 91 | 2.4 | 7.5 | — | 0.000933 | 0.00040 | 320 | 6.55 | 0.80 | 0.75 | 4 |

`house` L1 water is exactly `4 residents × 0.020 m³/h = 0.08` — the anchor doc 05 §2.13 arbitrates against.

#### `apartment` — standard (k_dem 2.45)
| L | Foot | Pop | Jobs | Pwr kW | Water WU/gh | Build gh | Upg gh | Decay | Fire p/gh | FireLoad | Crime | ReqFire | ReqPol | CityLv |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 2x2 | 24 | 2 | 22 | 0.48 | 6 | 6 | 0.000500 | 0.00022 | 45 | 2.00 | 0.00 | 0.00 | 1 |
| 2 | 2x2 | 44 | 4 | 54 | 1.2 | 9.5 | 9.5 | 0.000600 | 0.00028 | 90 | 3.20 | 0.20 | 0.15 | 1 |
| 3 | 2x2 | 82 | 7 | 130 | 2.9 | 14.5 | 14.5 | 0.000720 | 0.00036 | 180 | 5.12 | 0.40 | 0.35 | 2 |
| 4 | 2x2 | 152 | 13 | 325 | 7.1 | 22 | 23 | 0.000864 | 0.00046 | 360 | 8.19 | 0.60 | 0.55 | 3 |
| 5 | 2x2 | 281 | 23 | 795 | 17.5 | 35 | — | 0.001037 | 0.00059 | 720 | 13.11 | 0.80 | 0.75 | 4 |

`apartment` L1 water is likewise exact: `24 residents × 0.020 = 0.48`.

#### `store` — steady (k_dem 2.35; footprint grows at L3)
| L | Foot | Pop | Jobs | Pwr kW | Water WU/gh | Build gh | Upg gh | Decay | Fire p/gh | FireLoad | Crime | ReqFire | ReqPol | CityLv |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 1x1 | 0 | 6 | 9.0 | 0.13 | 3 | 2.5 | 0.000550 | 0.00030 | 25 | 3.00 | 0.00 | 0.00 | 0 |
| 2 | 1x1 | 0 | 9 | 21 | 0.30 | 4 | 4 | 0.000660 | 0.00038 | 50 | 4.80 | 0.20 | 0.15 | 1 |
| 3 | 2x2 | 0 | 14 | 50 | 0.71 | 6 | 5 | 0.000792 | 0.00049 | 100 | 7.68 | 0.40 | 0.35 | 2 |
| 4 | 2x2 | 0 | 22 | 115 | 1.7 | 8 | 7.5 | 0.000950 | 0.00063 | 200 | 12.29 | 0.60 | 0.55 | 3 |
| 5 | 2x2 | 0 | 35 | 275 | 3.9 | 11.5 | — | 0.001140 | 0.00081 | 400 | 19.66 | 0.80 | 0.75 | 4 |

*Water seed = **0.128** (displayed 0.13). Generate L2–L5 from 0.128, not from the cell — RR-8.*

#### `office` — standard (k_dem 2.45)
| L | Foot | Pop | Jobs | Pwr kW | Water WU/gh | Build gh | Upg gh | Decay | Fire p/gh | FireLoad | Crime | ReqFire | ReqPol | CityLv |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 2x2 | 0 | 30 | 35 | 0.32 | 8 | 8 | 0.000450 | 0.00020 | 40 | 1.50 | 0.00 | 0.00 | 1 |
| 2 | 2x2 | 0 | 56 | 86 | 0.78 | 12.5 | 12.5 | 0.000540 | 0.00026 | 80 | 2.40 | 0.20 | 0.15 | 1 |
| 3 | 2x2 | 0 | 103 | 210 | 1.9 | 19 | 19.5 | 0.000648 | 0.00033 | 160 | 3.84 | 0.40 | 0.35 | 2 |
| 4 | 2x2 | 0 | 190 | 515 | 4.7 | 30 | 30 | 0.000778 | 0.00042 | 320 | 6.14 | 0.60 | 0.55 | 3 |
| 5 | 2x2 | 0 | 351 | 1260 | 11.5 | 46 | — | 0.000933 | 0.00054 | 640 | 9.83 | 0.80 | 0.75 | 4 |

#### `high_rise` — vertical (k_dem 2.55; spec §9.3: ~12 / 24 / 36 / 48 / 60+ floors)
| L | Foot | Pop | Jobs | Pwr kW | Water WU/gh | Build gh | Upg gh | Decay | Fire p/gh | FireLoad | Crime | ReqFire | ReqPol | CityLv |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 2x2 | 60 | 15 | 90 | 1.3 | 16 | 17.5 | 0.000600 | 0.00026 | 70 | 2.50 | 0.00 | 0.00 | 3 |
| 2 | 2x2 | 126 | 32 | 230 | 3.3 | 27 | 30 | 0.000720 | 0.00033 | 140 | 4.00 | 0.25 | 0.19 | 3 |
| 3 | 2x2 | 265 | 66 | 585 | 8.3 | 46 | 51 | 0.000864 | 0.00043 | 280 | 6.40 | 0.50 | 0.44 | 3 |
| 4 | 2x2 | 556 | 139 | 1490 | 21.0 | 79 | 87 | 0.001037 | 0.00055 | 560 | 10.24 | 0.75 | 0.69 | 3 |
| 5 | 2x2 | 1167 | 292 | 3810 | 54.0 | 134 | — | 0.001244 | 0.00070 | 1120 | 16.38 | 0.95 | 0.94 | 4 |

*Water seed = **1.28** (displayed 1.3). Generate L2–L5 from 1.28, not from the cell — RR-8.*

#### `data_center` — vertical (k_dem 2.55; spec §10: huge electrical + cooling demand)
| L | Foot | Pop | Jobs | Pwr kW | Water WU/gh | Build gh | Upg gh | Decay | Fire p/gh | FireLoad | Crime | ReqFire | ReqPol | CityLv |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 2x2 | 0 | 12 | 400 | 3.2 | 20 | 22 | 0.000750 | 0.00060 | 80 | 2.00 | 0.00 | 0.00 | 4 |
| 2 | 2x2 | 0 | 25 | 1020 | 8.2 | 34 | 38 | 0.000900 | 0.00077 | 160 | 3.20 | 0.25 | 0.19 | 4 |
| 3 | 2x2 | 0 | 53 | 2600 | 21.0 | 58 | 64 | 0.001080 | 0.00098 | 320 | 5.12 | 0.50 | 0.44 | 4 |
| 4 | 2x2 | 0 | 111 | 6630 | 53.0 | 98 | 109 | 0.001296 | 0.00126 | 640 | 8.19 | 0.75 | 0.69 | 4 |
| 5 | 2x2 | 0 | 233 | 16900 | 135 | 167 | — | 0.001555 | 0.00161 | 1280 | 13.11 | 0.95 | 0.94 | 4 |

#### `police_station` — standard (k_dem 2.45)
| L | Foot | Pop | Jobs | Pwr kW | Water WU/gh | Build gh | Upg gh | Decay | Fire p/gh | FireLoad | Crime | ReqFire | ReqPol | CityLv |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 2x2 | 0 | 12 | 25 | 0.19 | 10 | 10 | 0.000400 | 0.00010 | 30 | 0.20 | 0.00 | 0.00 | 0 |
| 2 | 2x2 | 0 | 22 | 61 | 0.47 | 15.5 | 15.5 | 0.000480 | 0.00013 | 60 | 0.32 | 0.15 | 0.11 | 1 |
| 3 | 2x2 | 0 | 41 | 150 | 1.2 | 24 | 24 | 0.000576 | 0.00016 | 120 | 0.51 | 0.30 | 0.26 | 2 |
| 4 | 2x2 | 0 | 76 | 370 | 2.8 | 37 | 38 | 0.000691 | 0.00021 | 240 | 0.82 | 0.45 | 0.41 | 3 |
| 5 | 2x2 | 0 | 141 | 900 | 6.9 | 58 | — | 0.000829 | 0.00027 | 480 | 1.31 | 0.60 | 0.56 | 4 |

*Water seed = **0.192** (displayed 0.19). Generate L2–L5 from 0.192, not from the cell — RR-8.*

#### `fire_station` — standard (k_dem 2.45)
| L | Foot | Pop | Jobs | Pwr kW | Water WU/gh | Build gh | Upg gh | Decay | Fire p/gh | FireLoad | Crime | ReqFire | ReqPol | CityLv |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 2x2 | 0 | 14 | 28 | 0.40 | 10 | 10 | 0.000400 | 0.00006 | 25 | 0.30 | 0.00 | 0.00 | 0 |
| 2 | 2x2 | 0 | 26 | 69 | 0.98 | 15.5 | 15.5 | 0.000480 | 0.00008 | 50 | 0.48 | 0.15 | 0.11 | 1 |
| 3 | 2x2 | 0 | 48 | 170 | 2.4 | 24 | 24 | 0.000576 | 0.00010 | 100 | 0.77 | 0.30 | 0.26 | 2 |
| 4 | 2x2 | 0 | 89 | 410 | 5.9 | 37 | 38 | 0.000691 | 0.00013 | 200 | 1.23 | 0.45 | 0.41 | 3 |
| 5 | 2x2 | 0 | 164 | 1010 | 14.5 | 58 | — | 0.000829 | 0.00016 | 400 | 1.97 | 0.60 | 0.56 | 4 |

**Domestic water only.** These are the station buildings' own consumption. Fire-suppression flow (`fire_flow_per_engine`) is doc 05/doc 06 territory and is never billed to this column.

#### `power_facility` — vertical (k_dem 2.55; footprint grows at L4)
| L | Foot | Pop | Jobs | Pwr kW (own use) | Water WU/gh | Build gh | Upg gh | Decay | Fire p/gh | FireLoad | Crime | ReqFire | ReqPol | CityLv |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 3x3 | 0 | 20 | 0 | 0.96 | 18 | 20 | 0.000900 | 0.00090 | 90 | 1.20 | 0.00 | 0.00 | 0 |
| 2 | 3x3 | 0 | 42 | 0 | 2.4 | 31 | 34 | 0.001080 | 0.00115 | 180 | 1.92 | 0.15 | 0.11 | 1 |
| 3 | 3x3 | 0 | 88 | 0 | 6.2 | 52 | 57 | 0.001296 | 0.00147 | 360 | 3.07 | 0.30 | 0.26 | 2 |
| 4 | 4x4 | 0 | 185 | 0 | 16.0 | 88 | 98 | 0.001555 | 0.00189 | 720 | 4.92 | 0.45 | 0.41 | 3 |
| 5 | 4x4 | 0 | 389 | 0 | 40.5 | 150 | — | 0.001866 | 0.00242 | 1440 | 7.86 | 0.60 | 0.56 | 4 |

*(The L5 row is the largest single movement in the C-34 rescale: 154.0 old WU/gh → 40.5 m³/h of cooling and process water.)* Generation capacity in MW is **doc 04's**, not a column here.

#### `substation` — standard (k_dem 2.45)
| L | Foot | Pop | Jobs | Pwr kW | Water WU/gh | Build gh | Upg gh | Decay | Fire p/gh | FireLoad | Crime | ReqFire | ReqPol | CityLv |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 2x2 | 0 | 4 | 0 | 0 | 8 | 8 | 0.000800 | 0.00070 | 55 | 1.50 | 0.00 | 0.00 | 0 |
| 2 | 2x2 | 0 | 7 | 0 | 0 | 12.5 | 12.5 | 0.000960 | 0.00090 | 110 | 2.40 | 0.15 | 0.11 | 1 |
| 3 | 2x2 | 0 | 14 | 0 | 0 | 19 | 19.5 | 0.001152 | 0.00115 | 220 | 3.84 | 0.30 | 0.26 | 2 |
| 4 | 2x2 | 0 | 25 | 0 | 0 | 30 | 30 | 0.001382 | 0.00147 | 440 | 6.14 | 0.45 | 0.41 | 3 |
| 5 | 2x2 | 0 | 47 | 0 | 0 | 46 | — | 0.001659 | 0.00188 | 880 | 9.83 | 0.60 | 0.56 | 4 |

`substation` keeps a deliberately high `crime_weight` for its class (copper theft), so an unguarded remote substation is a real cascade seed. Throughput, `service_radius_tiles` and every other electrical number are **doc 04's**.

#### `water_facility` — standard (k_dem 2.45; footprint grows at L5) — **`pump` reference variant**
| L | Foot | Pop | Jobs | Pwr kW | Water WU/gh | Build gh | Upg gh | Decay | Fire p/gh | FireLoad | Crime | ReqFire | ReqPol | CityLv |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 3x3 | 0 | 10 | 60 | 0 | 12 | 12 | 0.000700 | 0.00012 | 25 | 0.80 | 0.00 | 0.00 | 0 |
| 2 | 3x3 | 0 | 19 | 145 | 0 | 18.5 | 19 | 0.000840 | 0.00015 | 50 | 1.28 | 0.15 | 0.11 | 1 |
| 3 | 3x3 | 0 | 34 | 360 | 0 | 29 | 29 | 0.001008 | 0.00020 | 100 | 2.05 | 0.30 | 0.26 | 2 |
| 4 | 3x3 | 0 | 63 | 880 | 0 | 45 | 45 | 0.001210 | 0.00025 | 200 | 3.28 | 0.45 | 0.41 | 3 |
| 5 | 4x4 | 0 | 117 | 2160 | 0 | 69 | — | 0.001452 | 0.00032 | 400 | 5.24 | 0.60 | 0.56 | 4 |

The shell table above is generated for the **`pump`** variant **and its `Foot` column is the `pump` footprint only** *(report 98 RR-8, verifier finding F-08)*. The earlier claim that the four non-reference variants "reuse the same footprint" is **deleted** — it contradicted C-35, which gave doc 05 every per-variant number, and it contradicted doc 09's starter-city footprint total, which counts `WTR-2` as a **2×2 tank**. What survives here is a **restatement, not an ownership claim**: the `Foot` column above must equal doc 05's `components.pump` footprint columns, and the loader asserts that equality at boot (§3.1). C-30's "doc 02's footprint is authoritative" remains true against **doc 04**; it was never a claim against doc 05.

| Field, per variant | Owner |
|---|---|
| `footprint` (all five levels, all five variants) | **doc 05** — `data/water.json` `components[variant][L].footprint_w/h`. Doc 02 restates only the `pump` row and asserts it equal at load. |
| `base_kw`, capacity / throughput / volume / head, `coverage_frac`, `backup_kw` | **doc 05** — `data/water.json` |
| build/upgrade crew-hours, `decay_per_hour`, `fire_ignition_per_hour`, `fire_load`, `crime_weight`, jobs, coverage requirements, `min_city_level`, the §2.12 state machine, the variant list itself | **doc 02** — the shell above |
| the `k_dem = 2.45` standard-class shape every per-variant ladder is generated on | **doc 02** (§2.2) |

Doc 05's published footprints for reference (**doc 05 §8 is the source of truth — do not copy these into `data/buildings.json`**): `source_river` 2×2/2×2/3×3/3×3/4×4 · `source_well` 1×1/1×1/2×2/2×2/3×3 · `treatment` 2×2/3×3/3×3/4×4/4×4 · **`pump` 3×3/3×3/3×3/3×3/4×4 (= the shell table above)** · `tank` 2×2/2×2/3×3/3×3/4×4 · `booster` 1×1/1×1/1×1/2×2/2×2. A gravity `tank` L1 is 2×2 and draws **5.0 kW**, not the 3×3 / 60 kW of an L1 `pump` — which is exactly the flat-shell error C-35 was raised to kill.

#### `construction_yard` — steady (k_dem 2.35; footprint grows at L4)
| L | Foot | Pop | Jobs | Pwr kW | Water WU/gh | Build gh | Upg gh | Decay | Fire p/gh | FireLoad | Crime | ReqFire | ReqPol | CityLv |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 2x2 | 0 | 16 | 12 | 0.16 | 10 | 9 | 0.000650 | 0.00040 | 50 | 2.20 | 0.00 | 0.00 | 0 |
| 2 | 2x2 | 0 | 25 | 28 | 0.38 | 14 | 12.5 | 0.000780 | 0.00051 | 100 | 3.52 | 0.15 | 0.11 | 1 |
| 3 | 2x2 | 0 | 38 | 66 | 0.88 | 19.5 | 17.5 | 0.000936 | 0.00066 | 200 | 5.63 | 0.30 | 0.26 | 2 |
| 4 | 3x3 | 0 | 60 | 155 | 2.1 | 27 | 25 | 0.001123 | 0.00084 | 400 | 9.01 | 0.45 | 0.41 | 3 |
| 5 | 3x3 | 0 | 92 | 365 | 4.9 | 38 | — | 0.001348 | 0.00107 | 800 | 14.42 | 0.60 | 0.56 | 4 |

### 2.4 Coverage reach table (the only "special output" this doc still owns)

| Archetype | Field | L1 | L2 | L3 | L4 | L5 |
|---|---|---|---|---|---|---|
| police_station | `coverage_radius_tiles` | 20 | 25 | 31 | 39 | 49 |
| fire_station | `coverage_radius_tiles` | 18 | 23 | 28 | 35 | 44 |
| construction_yard | `coverage_radius_tiles` | 30 | 38 | 47 | 59 | 73 |

Radii grow on `k_radius = 1.25` (§2.2) and round to the nearest integer, half-up. *`fire_station` L2 is **23**, corrected from 22 by report 98 **RR-19**: `18 × 1.25 = 22.5` is an exact tie and the tie rule is half-up, exactly as `construction_yard` L2 already rounded `37.5 → 38`. Worked example E6 (§2.9) is re-derived at 23.*

Everything else that used to live in this table has an owner elsewhere and is **deleted from `data/buildings.json`**:

| Deleted field | Now read from |
|---|---|
| `power_supply_kw`, `power_throughput_kw` | doc 04 `data/power.json` (`plant_capacity_mw`, `capacity_kw`, `rated_mva`) |
| `feeder_radius_tiles` | doc 04's transformer `service_radius_tiles` (a physical attachment radius, not a coverage percentage) |
| `water_supply_wu_per_hour`, `pressure_radius_tiles` | doc 05 `data/water.json` per-variant capacity + pressure zones |
| `unit_slots`, `crew_slots` | doc 06 `capacity_per_station_level` — `[2,3,4,5,6]` patrol, `[1,2,3,4,5]` engine / water truck / utility truck / construction crew |

*(Report 98 C-06 forbids radius-based utility coverage outright — constitution §8: utilities are graphs with capacity and load, not coverage percentages.)*

**Signature balance fact, restated after C-13.** An L5 data center draws **16,900 kW and 135 m³/h**. That is `2.55⁴ = 42.3×` its own L1 draw against `2.15⁴ = 21.4×` its L1 tax — the tower is **97.8 % less utility-efficient per tax dollar** than the L1 it grew from, and it is 5,633× an L1 house's draw. Spec §10's "data center upgrade → taxes increase → electric and water demand increase sharply" is literal here, and Core Rule 3 now holds for **every** archetype in the roster rather than for three of twelve.

### 2.5 Runtime outputs published by this system

**This doc computes no revenue.** *(Report 98 C-09: doc 03 owns revenue end to end — `R_b`, `f_power`, `f_water`, `f_road`, `f_stability`, `f_happiness`, `f_condition`, `tax_policy_factor`, `M_rev` and the city revenue floor are all doc 03 §2.2.)* Every game-hour, `BuildingSystem` publishes exactly five things per building and nothing else:

```
population        = level_stats.population                       (capacity; doc 09 owns fill)
jobs              = level_stats.jobs                             (capacity; doc 09 owns fill)
condition         ∈ [0,1]                                        (§2.6)
state             ∈ the 8 states of §2.12
power_demand_kw   = power_demand_kw(L)  × STATE_DEMAND[state]  × weather.get_effect("load_mult")
water_demand      = water_demand(L)     × STATE_DEMAND[state]  × weather.get_effect("water_mult")
```

Weather multipliers come from **doc 07's `get_effect()`** — this doc authors none of them *(report 98 C-57)*.

**Safety coverage factor** — the one surviving piece of the old `service_factor`, renamed so it can never be mistaken for doc 03's revenue chain *(report 98 C-09)*:

```
safety_coverage_factor(b) = SAFETY_FLOOR + SAFETY_SPAN × S(b)     SAFETY_FLOOR = 0.80, SAFETY_SPAN = 0.20
```

`S(b) ∈ [0,1]` is the safety satisfaction of §2.9. `safety_coverage_factor` is published to **doc 06** (incident exposure) and **doc 09** (district stability components), and reaches revenue only through doc 03's `f_stability` chain. It never multiplies tax directly.

**Worked example E1 (recomputed) — apartment L3 during a heat wave with a half-dark feeder.**
Published row: `population = 82`, `jobs = 7`, `condition = 0.72`, `state = active`.
Power: `130 kW × 1.00 (active) × weather.get_effect("load_mult")`. Water: `2.9 m³/h × 1.00 × weather.get_effect("water_mult")`.
Coverage: `cov_fire = 0.62`, `cov_pol = 0.55` against L3 requirements `0.40 / 0.35` → both satisfied → `S = 1.0` → `safety_coverage_factor = 0.80 + 0.20 × 1.0 = 1.00`.
Doc 04 reports `power_availability_hour = 0.55` for the settled hour; doc 03 turns that, the condition 0.72, the occupancy and the district stability into `R_b`. **This doc reports 130 kW requested and 71.5 kWh served; it does not report a dollar.** Under the old table the same building drew 88 kW — the C-13 correction raises an L3 apartment's draw by 47.7 % while its tax is unchanged, which is precisely the intended pressure.

### 2.6 Condition & decay

`condition ∈ [0, 1]` float, starts at **1.00** on completion *(report 98 C-14: one scale across docs 02–07; the UI may render it as a percentage)*.

```
decay_rate = decay_per_hour                          (fraction of condition per gh, §2.3)
           * (1 + 0.80 * overload_excess)            overload_excess = max(0, load/capacity − 1) reported
                                                     by doc 04 for the serving grid node
           * (1 + 0.50 * (1 − P))                    unpowered buildings deteriorate; P from doc 04
           * weather.get_effect("decay_mult")        doc 07 — no constant is authored here
condition = clamp(condition − decay_rate * hours_elapsed, 0.0, 1.0)
```

Thresholds and effects (all rescaled by ÷100):

| condition | Label (UI) | Effects |
|---|---|---|
| 0.85–1.00 | Good | nominal; `fire_condition_mult` 1.00–1.09; doc 03's `f_condition` 0.93–1.00 |
| 0.60–0.85 | Worn | `fire_condition_mult` 1.09–1.38; doc 03's `f_condition` 0.82–0.93 |
| 0.35–0.60 | Poor | `fire_condition_mult` 1.38–1.79; doc 03's `f_condition` 0.71–0.82; UI warning badge |
| 0.00–0.35 | Failing | auto-transition `active → damaged` at **0.35**; below **0.10**, `p_structural_failure = 0.02/gh` → `destroyed` |

`fire_condition_mult = 1 + 1.5 × (1 − condition)^1.5` — now natively on `[0,1]`: `C=1.00 → 1.00`, `C=0.50 → 1.53`, `C=0.00 → 2.50`.

**Structural failure, as shipped (Wave 4).** `Building.roll_structural_failure` is called once per settled game-hour from `CitySim.apply_hourly_decay`, immediately after `apply_decay` and in the same sorted-id loop, on the **`failures`** RNG stream (constitution §5 — no new stream was minted for it; `failures` is the one doc 02's damage already owns). It rolls only for buildings that are `damaged` **and** below `structural_failure_threshold 0.10`, so a healthy city draws nothing and the stream advances only where the city is already rotting. It emits doc 02's own `building_destroyed` with `cause = structural_failure`; the destroyed building stays in the registry at `STATE_OCCUPANCY 0.00` exactly as a burned-down one does, so population, revenue and the rebuild grace window all follow the existing path. **Offline:** during a catch-up the roll is not *taken* rather than taken and refused (doc 08 C-47 / report 98 — an absence may not silently consume the stream, and the rot must still be standing where the returning player can see it).

**Repair / maintenance.** This doc supplies a **`damage_fraction ∈ [0,1]` and crew-hours only**; doc 03 prices it *(report 98 C-16)*.

```
damage_fraction = clamp(1.0 − condition, 0.0, 1.0)
repair_hours    = build_time_hours(L) * REPAIR_TIME_FACTOR (0.50) * damage_fraction     (crew-hours)
repair_target   = 1.00 if state == active else 0.85     (post-damage repairs never restore to new)
repair_cost     = economy.repair_cost(building_ref, damage_fraction)      ← doc 03 §2.5
                = round( capital_value(L) × damage_fraction × 0.85 × M_repair[difficulty] )
```

Incident-inflicted damage (doc 06 fire, doc 07 disasters) arrives as a `damage_fraction` too, so there is exactly one repair-pricing path in the game.

**Worked example E4 (recomputed on `[0,1]`).** An L3 apartment (`decay_per_hour 0.000720`) left alone for one game-week (168 gh) on a healthy grid: `1.000 − 0.000720 × 168 = 1.000 − 0.12096 = **0.879**`.
Same apartment on a grid node at 130 % load with `P = 0.7` for that week:
`0.000720 × (1 + 0.8×0.30) × (1 + 0.5×0.30) = 0.000720 × 1.24 × 1.15 = 0.00102672/gh` → `1.000 − 0.17249 = **0.828**`.
Repairing it back to 1.00: `damage_fraction = 0.172`, `repair_hours = 14.5 × 0.50 × 0.172 = **1.25 crew-hours**`, and doc 03 charges `capital_value(apartment L3) 43,029 × 0.172 × 0.85 × 1.00 = **$6,291**` at standard difficulty. *(The old figures — condition 87.9 / 82.1 and $2,855 — used the deleted `[0,100]` scale and doc 02's deleted `build_cost` column. The old 82.1 also contained an arithmetic slip: `0.0720 × 1.24 × 1.15 = 0.10267`, not `0.1067`, giving 82.75 on the old scale.)*

### 2.7 Fire — ignition here, dynamics in doc 06

**Ignition is owned by this doc and is normative** *(report 98 C-42)*. `fire_ignition_per_hour` is per archetype **per level**, rolled once per game-hour per building on the `failures` RNG stream. Doc 06 has deleted `base_fire_risk_by_archetype` and `level_risk_slope`; it must not re-weight this rate by archetype or level, only by situation.

```
p_ignite = fire_ignition_per_hour(type, L)          ← §2.3, this doc, normative
         * fire_condition_mult                      ← §2.6, this doc
         * state_fire_mult                          ← §2.12, this doc
         * f_power * f_weather * f_arson            ← doc 06's situational multipliers only
```

**Consequence is `fire_load`, and nothing else here.** *(Report 98 C-43: doc 06 owns fire dynamics — severity, tier, `required_rate`, spread, burn-down and residual damage — because its model is integrated with dispatch, water pressure and the sub-step integrator.)* Deleted from this doc and from `data/buildings.json`: `burn_hours`, `condition_loss_per_hour`, `required_fire_units`, `spread_radius_tiles`, and the `fire.base_burn_hours / k_burn_hours / units_per_fire_load / max_required_units / tiles_per_spread_step / max_spread_radius_tiles` tunables. Look for them in doc 06 §2.8.

**Doc 06 must derive its suppression requirement from `fire_load`**, not from hand-authored per-archetype constants, or this doc's deliberate 56× spread does not reach the dispatch math:

```
S_req_base = 0.50 × (fire_load / 20)^0.45              ← doc 06 implements; doc 02 owns fire_load
```

**Worked example E5 (recomputed as the `fire_load` → `S_req_base` handoff).**
`house` L1, `fire_load = 20` → `0.50 × (20/20)^0.45 = **0.50**` — the calibration anchor.
`high_rise` L5, `fire_load = 1120` → `0.50 × 56^0.45 = 0.50 × 6.119 = **3.06**`.
`data_center` L5, `fire_load = 1280` → `0.50 × 64^0.45 = 0.50 × 6.497 = **3.25**`.
`power_facility` L5, `fire_load = 1440` → `0.50 × 72^0.45 = 0.50 × 6.852 = **3.43**`.
That is spec §17's requirement made numeric — **an L5 high-rise carries 56× the fire load of an L1 house and needs 6.1× the suppression rate** — and it now enters doc 06's model through one number instead of two competing simulations.

**Calibration is closed** *(report 98 RR-9, verifier finding F-09)*. C-43's original gloss "high_rise L5 ≈ 3.6" was arithmetically wrong — `0.50 × 56^0.45 = 3.05948`, and reaching 3.60 would need the exponent `ln(7.2)/ln(56) = 0.490424`, not 0.45. The **formula is canonical and `S_req_base(high_rise L5) = 3.06` is the shipped value**; C-43 has been corrected in place in report 98 §5. Doc 06 needs no change (its published 3.060 was right all along), this doc's earlier suggestion of raising the exponent to ≈0.474 is **withdrawn**, and `s_req_base_exponent` stays at **0.45** in §8. This doc still owns only `fire_load`; the constants live in `data/building_rules.json` and doc 06 implements the formula.

`on_fire` is entered and left **only** on doc 06's events (`FireStarted` / `FireSuppressed` / `BurnDown`); this doc never advances a fire itself.

### 2.8 Crime attractiveness

`crime_weight` is a *selection weight*, not a probability, and it is all this doc publishes *(report 98 C-44)*. **Doc 06 owns crime generation** (district λ on the **`crime`** RNG stream, per constitution §5) and uses `crime_weight` as the within-district weighted pick that places the incident on a specific building.

```
target_weight(b) = crime_weight(type, L) × STATE_ELIGIBLE[state]
```

The three situational coefficients this doc used to author — `no_police 1.2`, `night 0.8`, `outage 1.5` — are **deleted**; they duplicated doc 06's `f_police`, `f_dark` and `f_stab` and were double-counting the same signal. See doc 06 §2.6(a).

Ordering is preserved and still meaningful: an L5 store carries weight 19.66 against an L1 house's 1.00, and a substation carries 1.50 at L1 rising to 9.83 at L5 for its class (copper theft).

### 2.9 Service coverage — owned and implemented here

*(Report 98 C-51: this doc owns the radii, the staffing term and the requirement ladder, so it implements the formula. It publishes `coverage_police(pos: Vector2i) -> float` and `coverage_fire(pos: Vector2i) -> float`, both `∈ [0,1]`. Doc 06 reads the scalars and implements nothing.)*

**Where it lives, Wave 5.** The formula shipped as **`sim/incidents/coverage_index.gd`** (`CoverageIndex`) rather than at C-51's named `sim/buildings/coverage.gd`, and the two `coverage_*` queries are published from `CityIncidentWorld`. The reason is that the formula needs three things at once — this doc's radii and per-state condition, doc 06's `capacity_per_station_level` and its live roster — and `CityIncidentWorld` is the only adapter that already holds all three. `CoverageIndex` itself is **pure**: station rows in, scalars out, every constant read from `data/building_rules.json.coverage_ladder`, and it knows nothing about `Building`, `CitySim` or the fleet — so moving it to `sim/buildings/` when a `BuildingSystem`-side assembler exists is a file move and nothing else. Two Wave-5 readings the code fixes in place:

- **`units_housed(s)` is the roster, not the bay.** Units whose `home_station_id` is the station and whose status is not `OFFLINE` (doc 03's austerity parking). A station whose only engine is out on a call still covers its district; the other reading makes coverage oscillate with every dispatch and feeds doc 06's crime generator a signal that *rises* the moment police answer a crime. E6's "one engine dispatched away" still collapses `c` to 0.314 — as a decommissioning or an unpayable roster, not as a call.
- **The state term is §2.12's table, not `active ? 1 : 0`.** `data/building_rules.json.state_modifiers.*.coverage` already publishes 1.00 / 0.50 (upgrading) / 0.25 (damaged or repairing) / 0, and `Building.coverage_mult()` is that column. The table is the narrower, later statement of the same rule.

```
c_station(pos, s) = clamp(1 − (dist_tiles(pos, s) / coverage_radius_tiles(s))^FALLOFF (1.5), 0, 1)
                  * staffing(s)                  = min(1, units_housed(s) / capacity(s))   ← doc 06
                  * station_condition_factor(s)  = 0.50 + 0.50 * clamp((cond_s − 0.20)/0.80, 0, 1)
                  * (s.state == active ? 1 : 0)

coverage(pos) = min(1, max_s c_station(pos,s)
                     + REDUNDANCY_BONUS (0.15) * count{ s : c_station(pos,s) >= REDUNDANCY_MIN (0.30) }
                     − REDUNDANCY_BONUS)
```

`dist_tiles` is Euclidean between footprint centroids, in tiles. `capacity(s)` is **doc 06's** `capacity_per_station_level` — `[1,2,3,4,5]` engines per fire station, `[2,3,4,5,6]` patrols per police station — *not* a `unit_slots` column here *(report 98 C-50)*. The `+0.15 per extra overlapping station` term rewards redundancy (Pillar 2) and is capped at 1.0.

**Requirement.** A building at level L must satisfy `coverage_fire(b) >= req_fire_coverage(L)` and `coverage_police(b) >= req_police_coverage(L)` to (a) start an upgrade to that level and (b) avoid the safety penalty. Requirement ladder (before archetype multiplier): fire `0.00 / 0.20 / 0.40 / 0.60 / 0.80`, police `0.00 / 0.15 / 0.35 / 0.55 / 0.75`. Archetype multiplier: **1.00** for house/apartment/store/office, **1.25** for high_rise/data_center, **0.75** for the six service/utility archetypes. Result is clamped to 0.95 (never require perfection).

```
S (safety satisfaction) = 1.0 if both requirements are 0, else
                          clamp( 0.5*min(1, cov_fire/req_fire) + 0.5*min(1, cov_pol/req_pol), 0, 1 )
```

Falling below a requirement **does not downgrade the building** — it lowers `safety_coverage_factor` (§2.5) and blocks further upgrades. Deliberate: silent auto-downgrades would violate spec §20.2 "readable cause-and-effect."

**Worked example E6 (re-derived at radius 23 per report 98 RR-19; on the `[0,1]` condition scale and doc 06's capacity).** L2 fire station (radius **23**, doc 06 capacity 2 engines, 2 engines housed, condition **0.90**) and a candidate L4 office 11 tiles away, no other station in range.

```
distance falloff        (11/23)^1.5 = 0.478261^1.5 = 0.330748
                        1 − 0.330748                        = 0.669252
staffing                min(1, 2/2)                         = 1.0
station condition       0.50 + 0.50 × ((0.90 − 0.20)/0.80)  = 0.9375
c = 0.669252 × 1.0 × 0.9375                                 = 0.627424 → 0.627
required for office L4  = 0.60 × 1.00                       = 0.60
margin                  = 0.627424 − 0.60                   = 0.027
```

**Passes by 0.027** — and the moment that station's condition drops below **0.834** or an engine is dispatched away permanently, the upgrade gate closes. The condition threshold inverts the same chain: `station_condition_factor` must reach `0.60 / 0.669252 = 0.896523`, so `cond = 0.20 + 0.80 × 2 × (0.896523 − 0.50) = 0.834437`. The UI must show the margin, not just pass/fail.

*(Before RR-19 this example ran at radius 22 and read `1 − (11/22)^1.5 = 0.646447`, `c = 0.606`, margin **0.006**, gate closing below condition **0.885** — quoted in the doc as 0.89. The corrected radius widens the margin but does not change the lesson: one engine dispatched away still drops staffing to `1/2` and collapses `c` to 0.314, far below the 0.60 requirement.)*

### 2.10 Construction & upgrade timing

`build_time_hours` and `upgrade_time_hours` are **crew-hours**, not wall-clock. Progress runs through doc 01's exact integer `WorkService` accumulator (§2.13).

> **`upgrade_time_hours` is read off the row the step starts FROM.** §2.2 makes
> the cell on row `L` the price of `L → L+1` (`0.65 × build_time(L + 1)`), which
> is why `BuildingCatalog` requires it on every row below the top and forbids it
> on the top row. `CitySim.cmd_upgrade_building` read the row upgraded *to* until
> 2026-08-20 and billed every step in the game one rung too slow — worked example
> **E3 below is the tell**: it prices an office L4→L5 at **30** crew-hours, the L4
> cell, and the shipped binary charged the L5 cell's **47**. Report 98 RR-38 is
> the fix and the ruling; doc 92 §27.2 is the full ladder-by-ladder delta. E3's
> arithmetic below is unchanged and now describes what the game does.

```
crew_power   = Σ over assigned crews of crew_rate           (base 1.0; doc 06 defines specialist rates)
site_mult    = weather.get_effect("build_mult")             ← doc 07, no constant authored here
             * road_access_mult                             ← from doc 10's access_quality(pos), §2.11
             * ctx.channels.construction_rate               ← doc 01 (24-hour mean 0.804, night floor 0.60)
progress += (crew_power * site_mult / required_hours) * hours_elapsed        clamped to [0,1]
```

The `construction_rate` channel is **mandatory** — doc 01 §2.7 requires every work unit to multiply it, and authored durations are calibrated against its 0.804 mean *(report 98 C-29)*.

A project may hold `1..max_crews_per_project` crews; `max_crews_per_project = clamp(1 + floor(required_hours / 20), 1, 4)`.

**Worked example E3 (recomputed with the `construction_rate` channel).** Office **L4→L5** upgrade: `upgrade_time = 30 crew-hours`, `max_crews = 1 + floor(30/20) = 2`.
Two base crews, clear weather (`build_mult = 1.0`), road within 1 tile (`road_access_mult = 1.00`), averaged over a full day/night cycle:
`effective = 2.0 × 1.0 × 1.00 × 0.804 = 1.608 crew-hours per game-hour` → `30 / 1.608 = **18.7 game-hours**` of wall time (18.7 real minutes with the app open). One crew: `30 / 0.804 = **37.3 gh**`. At the 0.60 night floor a single crew makes only 0.60 crew-hours per game-hour, so an overnight-only build takes `30 / 0.60 = 50 gh`. *(The old figures — 17.6 gh and 54.5 gh — omitted the channel entirely and quoted doc 07's rain and thunderstorm constants, which this doc no longer authors.)*

Cost is charged **in full at project start** by doc 03. Cancelling refunds a **fraction of the job cost**, which this doc publishes and doc 03 converts to dollars:

| Cancelled from | `refund_fraction` |
|---|---|
| `planned` (never started) | 1.00 |
| `under_construction`, new build | `0.60 × (1 − progress)` — tile freed, no rubble |
| `under_construction`, upgrade | `0.50` — building returns to level L, `active`, condition unchanged |

### 2.11 Upgrade preconditions (spec §9.4)

`can_upgrade(b) -> {ok: bool, blockers: [code]}`. **All** must pass. Codes are stable strings; the UI (doc 12) maps them to copy. The enum now has **13** entries.

| # | Code | Rule |
|---|---|---|
| 1 | `E_STATE` | `b.state == active` (not building, damaged, burning, or destroyed) |
| 2 | `E_MAX_LEVEL` | `b.level < 5` |
| 3 | `E_CONDITION` | `b.condition >= 0.55` — you may not stack a tower on a rotten base *(C-14 rescale)* |
| 4 | `E_CITY_LEVEL` | `city_level >= min_city_level(L+1)` — `city_level` from doc 09 |
| 5 | `E_FUNDS` | `treasury >= economy.upgrade_cost(type, L→L+1)` — doc 03 answers, this doc only asks |
| 6 | `E_NO_CREW` | at least 1 idle crew within a construction yard's `coverage_radius_tiles` (doc 06 roster) |
| 7 | `E_ROAD` | a footprint tile is within `max_road_distance = 2` tiles (Chebyshev) of a road tile whose road-graph component contains ≥ 1 active construction yard (doc 10) |
| 8 | `E_POWER_HEADROOM` | see below — doc 04 answers |
| 9 | `E_WATER_HEADROOM` | see below — doc 05 answers |
| 10 | `E_FIRE_COVERAGE` | `coverage_fire(b) >= req_fire_coverage(L+1)` (§2.9) |
| 11 | `E_POLICE_COVERAGE` | `coverage_police(b) >= req_police_coverage(L+1)` (§2.9) |
| 12 | `E_FOOTPRINT` | if `footprint(L+1) > footprint(L)`, the added tiles (extending +X/+Z from origin) are owned, developed, empty, and not road |
| **13** | **`E_AVENUE`** | **`L+1 >= 4` requires an `AVENUE`-class road tile within 4 tiles (Chebyshev) of the building's access tile** *(report 98 C-62 — accepted as a hard gate)* |

```
delta_power = power_demand_kw(L+1) − power_demand_kw(L)
E_POWER_HEADROOM passes iff  power.upgrade_headroom_kw(building_id) >= delta_power * 1.15   ← doc 04

delta_water = water_demand(L+1) − water_demand(L)
E_WATER_HEADROOM passes iff  water.zone_headroom_m3h(building_id) >= delta_water * 1.10     ← doc 05
```

Doc 04 computes `upgrade_headroom_kw` across the whole serving path (transformer → feeder → substation → generation) and returns the binding minimum; this doc no longer models a single substation's throughput because it no longer owns one *(report 98 C-30)*. The 1.15 / 1.10 safety margins exist so a legal upgrade does not immediately push the serving asset into the overload-decay regime of §2.6.

**`E_AVENUE` rationale and reach.** It gives avenues a strategic purpose beyond travel time and is the cleanest reading of spec §9.4's "road access" precondition. Doc 09's starter city stamps boundary arterials → `AVENUE` on every block (report 98 C-60), so the gate never blocks the tutorial; it bites the first time a player develops an interior block on `STREET`s alone and then reaches for L4.

**Worked example E2 (recomputed at the new `k_dem`) — the signature block.** Apartment at L2 wants L3.
`delta_power = 130 − 54 = **76 kW**`; required headroom `76 × 1.15 = **87.4 kW**`. Under the old table this delta was 44 kW needing 50.6 kW — **the C-13 correction makes the signature upgrade gate 73 % harder to clear**, which is the point: the grid, not the wallet, is what stops the skyline.
`delta_water = 2.9 − 1.2 = **1.7 m³/h**`; required zone headroom `1.7 × 1.10 = **1.87 m³/h**` — that one passes comfortably, because after the C-34 rescale a single L1 pump serves roughly 2,000 residents.
Player options when doc 04 reports only 37 kW of headroom, all legitimate: upgrade the serving substation, add a transformer, build a second feed to the block, or repair the derated asset. This is spec §9.4's "This forces the player to upgrade infrastructure before vertically expanding the city," implemented.

**City level thresholds** are **doc 09's** (report 98 G-1); this doc's proposed ladder was adopted there and **retuned against measurement by doc 92 §19** (audit 91 D-7 — four of the six proposed rungs were unreachable by anything the game can do). It lives in `data/progression.json`; doc 09 §2.11 is the statement of record and the row below is a read-only copy:

| city_level | 0 | 1 | 2 | 3 | 4 | 5 |
|---|---|---|---|---|---|---|
| min city population | 0 | **200** | **700** | **1,600** | **3,600** | **8,000** |
| *this doc's original proposal* | 0 | 250 | 1,000 | 4,000 | 12,000 | 30,000 |

### 2.12 Building state machine

Eight states (spec §46 `construction_state`). An in-progress upgrade is **not** a separate state: it is `under_construction` with `pending_level = level + 1`, keeping the state set exactly as specified.

```
                    cancel/refund
        ┌──────────────────────────────┐
        v                              │
   [planned] ──crew assigned──> [under_construction] ──progress>=1.0──> [active]
                                        │                                 │  ^
                                        │ doc 06 FireStarted              │  │ repair done
                                        v                                 │  │
                                    [on_fire] <───doc 06 ignition/spread──┘  │
                                     │     │                                │
                        suppressed   │     │ burn-down (doc 06)              │
                                     v     v                                │
                                 [damaged] ─────> [destroyed]               │
                                   │  ^                │                    │
                       repair order│  │ new damage     │ rebuild ordered    │
                                   v  │                v                    │
                              [repairing] ────────> [planned]  ─────────────┘
```

Full transition table:

| From | To | Trigger | Side effects |
|---|---|---|---|
| — | `planned` | `cmd_place_building` validated | doc 03 charges cost; tiles reserved; job submitted to `ConstructionQueue` |
| `planned` | `under_construction` | crew assigned by doc 06 | `work_units = 0`, emits `job_started` |
| `planned` | (removed) | `cmd_cancel` | `refund_fraction = 1.00` reported to doc 03 |
| `active` | `under_construction` | `cmd_upgrade` passes §2.11 | `pending_level = L+1`, cost charged, `work_units = 0` |
| `under_construction` | `active` | `progress >= 1.0` | `level = pending_level or 1`; `condition = 1.00`; emits `BuildingCompleted` + `job_completed` |
| `under_construction` | `on_fire` | doc 06 ignition (state mult 1.4) | progress frozen |
| `active` | `damaged` | incident/disaster `damage_fraction`, or `condition < 0.35` | occupancy →0.40, emits `BuildingDamaged` |
| `active` / `damaged` / `under_construction` | `on_fire` | doc 06 `FireStarted` (ignition roll or spread) | occupancy →0, emits `BuildingIgnited`, doc 06 opens the incident |
| `on_fire` | `damaged` | doc 06 `FireSuppressed` | doc 06 supplies the residual `damage_fraction`; condition set from it |
| `on_fire` | `destroyed` | doc 06 `BurnDown` **and** `world.destroy_allowed()` | pop/jobs →0, rubble placed, emits `BuildingDestroyed` |
| `damaged` | `destroyed` | `condition <= 0` or structural-failure roll (`0.02/gh` below condition 0.10) | as above |
| `damaged` | `repairing` | `cmd_repair` + crew assigned | doc 03 charges `repair_cost(damage_fraction)` |
| `repairing` | `active` | repair progress ≥ 1.0 | `condition = 0.85` |
| `repairing` | `damaged` | crew withdrawn or new damage | partial progress kept |
| `destroyed` | `planned` | `cmd_rebuild`; doc 03 charges `0.60 × build cost(level_at_destruction)` if within `rebuild_grace_hours = 72`, else L1 price and level resets to 1 | rubble cleared as part of the project |
| `destroyed` | (removed) | `cmd_clear_rubble`; `0.10` cost fraction, `0.25 × build_time` crew-hours | tiles freed |

**Offline note.** `destroy_building` is guarded by `world.destroy_allowed()` (report 98 C-47): while catching up, doc 08's fairness rule clamps the outcome to condition **0.15** with the incident left open, and the verb is refused **visibly** rather than swallowed. The player arrives to a building still burning.

**Per-state behaviour modifiers** (the `STATE_*` tables referenced in §2.5):

| state | output × | power/water demand × | occupancy × | provides coverage × | decays? | can ignite? |
|---|---|---|---|---|---|---|
| `planned` | 0 | 0 | 0 | 0 | no | no |
| `under_construction` (new) | 0 | 0.15 site power, 0.10 site water | 0 | 0 | no | yes (×1.4) |
| `under_construction` (upgrade) | 0.35 of level L | 1.00 of level L | 0.50 | 0.50 | yes | yes (×1.4) |
| `active` | 1.00 | 1.00 | 1.00 | 1.00 | yes | yes |
| `damaged` | 0.40 | 0.50 | 0.40 | 0.25 | yes (×1.5) | yes (×1.8) |
| `repairing` | 0.40 | 0.50 | 0.40 | 0.25 | no | yes (×1.8) |
| `on_fire` | 0 | 0 | 0 | 0 | n/a | n/a |
| `destroyed` | 0 | 0 | 0 | 0 | no | no |

The `under_construction` (upgrade) row is the interesting one: **an upgrading tower keeps drawing its old load while producing a third of its old revenue.** A city that queues five upgrades at once starves itself. That is intended pressure, not an oversight.

### 2.13 Construction projects & the queue (`sim/construction/`)

*(Report 98 G-2: three-way split, one published API. **Doc 06 owns crews as dispatchable units** — roster, station capacity, preemption at priority 400, `auto_dispatch_construction: false`. **This doc owns the project record and its progress.** Doc 09 keeps the land-development phase → crew-type mapping. Doc 10 submits road jobs to this queue.)*

**Project record.** One row per job, in the `construction` save section (§3.3):

```
{ job_id, kind: build|upgrade|repair|rebuild|clear_rubble|road|development,
  target_ref,                 // building id, or a road/development ref for docs 09/10
  required_work_units : int,  // = round(required_crew_hours × WORK_UNITS_PER_CREW_HOUR)
  work_units : int,           // exact integer accumulator, never a float
  crew_type,                  // doc 06 crew specialisation requested
  assigned_crews : [unit_id], // doc 06 owns the units; this is a binding, not ownership
  priority : int,             // queue order; player-reorderable
  submitted_hour, started_hour, blocked_reason }
```

**Progress is integer work units, not a float.** `WORK_UNITS_PER_CREW_HOUR = 100`, so one crew-hour is 100 units and the accumulator round-trips a save exactly (constitution §4's determinism requirement, doc 01's `WorkService`):

```
required_work_units = round(required_crew_hours × 100)
per tick:  work_units += floor( crew_power × site_mult × ctx.channels.construction_rate
                                × 100 × dt_h )      ← site_mult per §2.10; residual carried in WorkService
progress = work_units / required_work_units          (derived, never stored)
```

**Published API** (`sim/construction/construction_queue.gd`):

| Call | Contract |
|---|---|
| `ConstructionQueue.submit(job) -> job_id` | Validates, charges through doc 03, enqueues at the tail. Rejects with the §2.11 blocker codes for upgrades. |
| `ConstructionQueue.reorder(job_id, new_index) -> bool` | Player-facing queue reordering (doc 12). Running jobs keep their crews; only the *pending* order changes. |
| `ConstructionQueue.cancel(job_id) -> refund_fraction` | Applies the §2.10 refund table and returns the fraction; doc 03 converts it to dollars. Releases crews back to doc 06. |
| `ConstructionQueue.list(filter) -> [project]` | Read-only snapshot for `ui/`. |
| `ConstructionQueue.remaining_work_units(job_id) -> int` | Work still owed, in the accumulator's own integer units. **Read off the accumulator, never recomputed from `progress()`** — a float round-trip through a fraction is the second accumulator this section forbids. |
| `ConstructionQueue.remaining_crew_hours(job_id) -> float` | The same quantity in crew-hours, which is the unit doc 03 §2.13(f) quotes a rush in. Presentation, like `progress()`; nothing in the tick path calls it. |
| `ConstructionQueue.force_complete(job_id) -> project` | Fills the accumulator to its required total and takes the job off the queue, returning the **same record `advance()` would have returned**. `{}` for an unknown or already-finished job. Requires no crew — doc 03 §2.5's contractor exists precisely for a job the city's own crews are not on. |

**`force_complete` does not route the completion, and that is the whole point.** It hands the record back and the coordinator (`CitySim._route_completed_jobs`) passes it to the *identical* dispatch the tick uses, so a rushed build fires the same `building_completed` a natural one does, in the same order, and the translator, the notification bindings and doc 09's goals cannot tell the two apart. There is deliberately no second completion path to keep in step (report 98 RR-108).

**Every project the player would call "being built or upgraded" is on this one queue.** `cmd_upgrade_building` has **no clock of its own** — the §2.11 gate submits an `upgrade` job and *this* accumulator is the timer — and the same is true of repairs, doc 09's six development phases and doc 10's three road jobs. `CitySim.construction_overview()` is therefore a read of `active_jobs()` and nothing else: no adapter, no second source, no merge (report 98 RR-109).

**Events emitted:** `job_started{job_id, target_ref, crew_ids}`, `job_completed{job_id, target_ref}`, `job_cancelled{job_id, refund_fraction}`, `job_blocked{job_id, reason}`.

**Crew binding.** This doc *requests* crew-hours; doc 06 *assigns* units and may **preempt** them for an incident at priority 400. A preempted job keeps its `work_units` and re-enters the queue as `blocked_reason = "crew_preempted"` — progress is never lost, only paused. `auto_dispatch_construction` is `false`, so crews never leave a job for a routine call.

---

### 2.14 The sixth rung — the tower tier

> **Added Wave 10** (doc 92 §24, ruling 93 §G6). Core Design Rule 5 said *five
> levels for every archetype*. It now says **five for every archetype, six for
> the growth stock**, and the rule change is content rather than tuning: the
> goals wave shipped a five-rung curriculum and found the top of the ladder
> hollow — every `min_city_level` in this doc topped out at 4, doc 09's block
> gates at 2, so **city level 5 unlocked nothing at all** and a sixth city level
> would have unlocked less.

**Who has six.** The six revenue-producing archetypes, named in
`building_rules.json.sixth_level_archetypes`:

| | archetype | growth class | L6 opens at city level |
|---|---|---|---|
| the street tier | `house`, `store` | `steady` | **4** |
| the tower tier | `apartment`, `office`, `high_rise`, `data_center` | `standard` / `vertical` | **5** |

The other six — `police_station`, `fire_station`, `power_facility`,
`substation`, `water_facility`, `construction_yard` — stop at five, and that is a
**boundary and not an omission**: their level ladders are not this doc's alone.
`water_facility`'s per-variant tables are doc 05's `data/water.json` (five rows ×
five variants, behind that doc's own `levels_4_5_enabled` flag), and station
fleet capacity is doc 06's `capacity_per_station_level` (five rows, locked by
C-50). A sixth rung for either is those docs' to author, not this one's.

**How the numbers were made.** By the §2.2 curve family at `e = 5`, and by
nothing else. There is no new fit, no hand-placed cell and no whitelist:
`value(6) = round_rule(seed × k^5)` with the §8 ladders applied once, half-up at
every tie, exactly as the first five rows are made. `tools/gen_buildings.py`
regenerates all **66** rows and diffs every one against the tables below.

Two consequences of the extension are worth naming out loud:

1. **The L5 rows of those six now carry `upgrade_time_hours`.** They had none
   before because they had no next level to price. The column is
   `0.65 × build_time(6)` — the same rule §2.2 has always used.
2. **The coverage ladder's sixth rung REPEATS its fifth** (0.80 fire / 0.75
   police, before the archetype multiplier). §2.9's requirements are a demand on
   the service stock, and the service stock did not gain a rung; a sixth-rung
   requirement above 0.80 would price the tower tier against coverage the player
   has no verb to buy. The two ×1.25 archetypes were already saturated at
   `max_requirement` 0.95 at L5, so their cells are identical either way.

**The sixth stat row** (columns as §2.3; `upgrade_time` is `--` at the top):

| archetype | pop | jobs | kW | WU/gh | build h | upg h | decay/h | fire p/gh | fire load | crime | req F | req P | minLvl |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `house` L6 | 36 | 0 | 215 | 5.7 | 11.0 | — | 0.001120 | 0.00052 | 640 | 10.49 | 0.80 | 0.75 | **4** |
| `store` L6 | 0 | 54 | 645 | 9.2 | 16.0 | — | 0.001369 | 0.00103 | 800 | 31.46 | 0.80 | 0.75 | **4** |
| `apartment` L6 | 520 | 43 | 1,940 | 42.5 | 54 | — | 0.001244 | 0.00076 | 1,440 | 20.97 | 0.80 | 0.75 | **5** |
| `office` L6 | 0 | 650 | 3,090 | 28.0 | 72 | — | 0.001120 | 0.00069 | 1,280 | 15.73 | 0.80 | 0.75 | **5** |
| `high_rise` L6 | 2,450 | 613 | 9,700 | 138 | 227 | — | 0.001493 | 0.00089 | 2,240 | 26.21 | 0.95 | 0.94 | **5** |
| `data_center` L6 | 0 | 490 | 43,150 | 345 | 284 | — | 0.001866 | 0.00206 | 2,560 | 20.97 | 0.95 | 0.94 | **5** |

**The `upgrade_time_hours` the L5 rows gained:** house 7.0, store 10.5,
apartment 35, office 47, high_rise 148, data_center 185.

**Footprints do not grow at L6.** All six keep their L5 footprint (1×1 for
`house`, 2×2 for the other five), which keeps §6's "exactly four footprint growth
steps" intact and is the design point of the rung: *the sixth rung goes up, not
out.* A 36-resident `house` on a 1×1 lot is a walk-up; a 2,450-resident
`high_rise` on a 2×2 is 273 m of tower.

**The money columns** live in doc 03 and are generated the same way — see doc 92
§24.4 for the derivation of `CAPITAL_VALUE_V`'s sixth cell (100.929).

**Which `min_city_level` a sixth rung gets** is authored in
`building_rules.json.min_city_level_by_growth_class`, an ADDITIVE override that
may touch the sixth rung and no other: the `steady` class opens its L6 at city
level 4, everything else at 5, so both of doc 09 §2.11's top two rungs pay out.
The reward-pacing derivation is doc 92 §24.3.

**What the loader now enforces** (`BuildingCatalog`, §3.1): a ladder is 5 or 6
rows; it is 6 **iff** `sixth_level_archetypes` names the archetype;
`upgrade_time_hours` is present on every rung but the archetype's own last; and
`max_level_of(archetype)` — not a literal 5, and not the roster maximum — is what
`cmd_upgrade_building`, the build sheet's level strip and the goals sheet's
reward card all ask.

---

## 3. Data Schema

### 3.1 `data/buildings.json`

```jsonc
{
  "schema_version": 1,                   // data-file version; save sections use section_version
  "archetypes": {
    "<archetype_id>": {
      "name": "string",                    // display name
      "category": "residential|commercial|industrial|service|utility",
      "tax_class": "residential|commercial|industrial|tech|civic|utility",  // consumed by doc 03
      "growth_class": "steady|standard|vertical",
      "variants": ["source","treatment","pump","tank","booster"],  // water_facility only (C-35)
      "levels": [                          // 5 rows, or 6 for §2.14's growth stock;
                                           // index 0 == level 1
        {
          "level": 1,                      // int 1..5, or 1..6 (§2.14)
          "footprint": [w, h],             // whole tiles, +X/+Z from origin — authoritative (C-30).
                                           // water_facility: this is the `pump` REFERENCE variant only;
                                           // the other four variants' footprints live in data/water.json
                                           // components[variant][L].footprint_w/h (doc 05, RR-8).
          "population": 0,                 // int, capacity
          "jobs": 0,                       // int, capacity
          "power_demand_kw": 0.0,          // k_dem curve, §2.3
          "water_demand": 0.0,             // WU/gh ≡ m³/h, k_dem curve, §2.3
          "coverage_radius_tiles": 0,      // optional: police, fire, construction_yard
          "build_time_hours": 0.0,         // crew-hours
          "upgrade_time_hours": 0.0,       // absent at the archetype's TOP level only (§2.14)
          "decay_per_hour": 0.0,           // FRACTION of condition per game-hour, [0,1] scale
          "fire_ignition_per_hour": 0.0,   // base probability / game-hour — NORMATIVE (C-42)
          "fire_load": 0,                  // consequence index; doc 06 derives S_req_base from it
          "crime_weight": 0.0,             // within-district target selection weight (doc 06)
          "req_fire_coverage": 0.0,        // 0..0.95
          "req_police_coverage": 0.0,      // 0..0.95
          "min_city_level": 0              // int; doc 09 owns city_level itself
        }
      ]
    }
  }
}
```

**Fields deleted from this file by report 98** — do not reintroduce them, and look here for the owner:

| Deleted | Ruling | Owner |
|---|---|---|
| `build_cost`, `upgrade_cost` | C-07 | doc 03 `build_cost_l1` + `CostCurves` |
| `tax_cents_per_hour` | C-10 | doc 03 `base_tax_by_level` |
| `upkeep_cents_per_hour` | C-08 | doc 03 `BUILDING_MAINT_RATE` / `station_upkeep` / `E_grid` / `E_water` |
| `power_supply_kw`, `power_throughput_kw`, `feeder_radius_tiles` | C-30, C-06 | doc 04 `data/power.json` |
| `water_supply_wu_per_hour`, `pressure_radius_tiles` | C-35, C-06 | doc 05 `data/water.json` |
| `unit_slots`, `crew_slots` | C-50 | doc 06 `capacity_per_station_level` |

**Economy columns written into this file by doc 03** (doc 02 owns the file, doc 03 owns these keys — doc 03 §3.2): `class`, `build_cost_l1`, `base_tax_l1`, `base_tax_by_level`, `upgrade_cost_by_step`, `capital_value_by_level`. They are generated by `tools/gen_building_economy.gd`; hand-editing them is a schema violation.

Loader invariants (asserted at boot, tested in §7): 12 archetypes; **5 levels each in ascending order, or 6 iff `building_rules.sixth_level_archetypes` names the archetype (§2.14)**; `upgrade_time_hours` present on every rung but the archetype's own last one; footprint non-decreasing across levels; `min_city_level` non-decreasing; `decay_per_hour < 0.01` (a `[0,1]`-scale guard that fails loudly if anyone re-imports the old `[0,100]` numbers); every numeric field ≥ 0; `variants` present iff `id == "water_facility"`; **no per-variant footprint table exists in this file** — `water_facility.levels[*].footprint` is the `pump` reference row and the loader cross-checks it against `data/water.json` `components.pump` *(RR-8)*.

Global constants live in the sibling file `data/building_rules.json` (full contents in §8).

### 3.2 Save section — `buildings`

```jsonc
"buildings": {
  "section_version": 1,             // renamed from schema_version per report 98 C-25
  "next_id": 1041,
  "items": [
    {
      "id": 1040,                     // int64, stable for the city's life
      "type": "apartment",
      "variant": null,                // water_facility only: source|treatment|pump|tank|booster
      "level": 2,
      "origin": [x, z],               // min-X/min-Z tile of the footprint
      "state": "under_construction",
      "pending_level": 3,             // null unless upgrading
      "condition": 0.745,             // float [0,1]  (C-14)
      "district_id": 7,
      "grid_node_id": "t_0412",       // serving transformer/feeder component id (doc 04), or null
      "pressure_zone_id": 5,          // serving pressure zone id (doc 05), or null
      "fire": null,                   // or {"ignited_at": 91240, "incident_id": 552} — doc 06 owns the incident
      "built_at": 88104,              // game-minutes
      "destroyed_at": null,
      "last_level_at_destruction": null
    }
  ]
}
```

Deleted from this section: **`tax_accum_cents`** *(report 98 C-15 — doc 03 computes per-building revenue in float, sums city-wide, rounds once per settlement and carries `revenue_carry_millidollars`; two sub-dollar schemes cannot coexist)*; **`occupancy` / `job_fill`** *(report 98 G-1 — doc 09 owns them in the `population` section; caching them here would create a second truth)*; **`progress` / `assigned_crews`** (moved to the `construction` section below, where the exact integer accumulator lives).

Rubble is stored as a `destroyed` building row, not a separate entity — it keeps the tile reservation and the rebuild-grace bookkeeping in one place.

### 3.3 Save section — `construction` (new, report 98 C-26 / G-2)

```jsonc
"construction": {
  "section_version": 1,
  "next_job_id": 3312,
  "jobs": [
    {
      "job_id": 3310,
      "kind": "upgrade",
      "target_ref": { "kind": "building", "id": 1040 },
      "required_work_units": 1450,     // 14.5 crew-hours × 100
      "work_units": 609,               // exact int64 accumulator
      "crew_type": "general",
      "assigned_crews": [3],           // doc 06 unit ids; binding only
      "priority": 2,
      "submitted_hour": 51190,
      "started_hour": 51193,
      "blocked_reason": null
    }
  ]
}
```

---

## 4. Sim API Sketch

All classes are `RefCounted`, in `sim/buildings/` and `sim/construction/`, with no engine imports (constitution §3).

| Class | Responsibility |
|---|---|
| `BuildingCatalog` | Loads/validates `buildings.json` + `building_rules.json`; `level_stats(type, level, variant) -> Dictionary`; pure lookup, no state |
| `Building` | One instance: id, type, variant, level, origin, state, condition |
| `BuildingSystem` | Owns the array of `Building`; all tick entry points; the only writer of building state |
| `Coverage` (`sim/buildings/coverage.gd`) | **Owns and implements** `coverage_police(pos)` / `coverage_fire(pos)` (§2.9) — the single implementation in the game *(C-51)* |
| `UpgradeGate` | Stateless evaluator: `check(building, world_view) -> {ok, blockers}` — the 13-row §2.11 table |
| `ConstructionQueue` (`sim/construction/`) | `submit` / `reorder` / `cancel` / `list`; owns project records and the integer work-unit accumulator *(G-2)* |
| `BuildingStateMachine` | Legal-transition table + side effects; every state change funnels through `transition(b, to, cause)` |

**Tick entry points** (cadences per constitution §4 — all game-time):

- `tick_utilities(dt)` — `EVERY_TICK`: recompute `power_demand_kw`, `water_demand` per building, publish to docs 04/05.
- `tick_projects(dt)` — `EVERY_TICK`: advance work units through `WorkService` (doc 01).
- `tick_hour(game_hour)` — `EVERY_HOUR`: decay, ignition rolls (`failures` stream), condition-threshold transitions.
- `tick_day(game_day)` — `EVERY_DAY`: recompute cached coverage per building, refresh `min_city_level` availability.
- `advance_coarse_hour()` — the offline path (constitution §4), same code, no separate rules.

**Commands handled:** `place_building{type, variant?, origin}`, `cancel_project{job_id}`, `upgrade_building{id}`, `repair_building{id}`, `rebuild_building{id}`, `clear_rubble{id}`, `demolish_building{id}`, `reorder_project{job_id, index}`, `set_building_priority{id, tier}`.

**As shipped (Wave 1.5, audit doc 93 §B).** The command layer lives on `CitySim` and prefixes every verb `cmd_`, so the four of the above that exist today are `cmd_place_building(archetype, origin, variant)`, `cmd_upgrade_building(sim_id, preview)`, **`cmd_repair_building(sim_id, preview)`** and **`cmd_demolish_building(sim_id, preview)`**; `set_building_priority` shipped as **`cmd_set_priority(sim_id, priority_class)`** and writes doc 04 §2.4's class onto the grid service record. Each takes an optional `preview` that returns the full blocker list and the quote without charging. Reason codes are `E_*` StringNames on `CommandQueue.fail()`, not the prose labels above: demolition refuses with `E_UNKNOWN_BUILDING` / `E_STATE`, repair with `E_UNKNOWN_BUILDING` / `E_STATE` / `E_NOT_DAMAGED` / `E_JOB_IN_FLIGHT` / `E_FUNDS`. Demolition emits **`building_removed`** (the renderer's event) rather than `BuildingDemolished`; `cancel_project`, `rebuild_building` and `clear_rubble` are still unimplemented.

**Events emitted:** `BuildingPlaced`, `BuildingCompleted`, `BuildingUpgraded`, `BuildingUpgradeBlocked{codes}`, `BuildingConditionThreshold{band}`, `BuildingDamaged`, `BuildingIgnited`, `BuildingDestroyed`, `BuildingRepaired`, `BuildingDemolished`, `CityLevelUnlockedArchetype{type}`, `job_started`, `job_completed`, `job_cancelled`, `job_blocked`.

**Queries exposed** (read-only snapshot for `game/` and `ui/`): `snapshot_building(id)`, `buildings_in_chunk(block_id)`, `city_totals() -> {population_capacity, jobs_capacity, power_kw, water_m3h}`, `upgrade_preview(id) -> {deltas, blockers}`, `coverage_police(pos)`, `coverage_fire(pos)`. **`city_totals()` returns no currency field.**

---

## 5. Cross-System Interfaces

Doc numbers below are the **canonical on-disk numbering of report 98 §0**. There is no other map.

| Doc | This system READS | This system PROVIDES |
|---|---|---|
| **01 — Time model & tick scheduler** (`sim/time/`) | `dt_h` per cadence; `EVERY_TICK`/`EVERY_HOUR`/`EVERY_DAY` callbacks; the coarse 1-game-hour offline path; `ctx.channels.construction_rate`; `WorkService` integer accumulator | work-unit demands per active project |
| **03 — Economy, taxes, land market & difficulty** (`sim/economy/`) | `CostCurves.build_cost() / upgrade_cost() / capital_value() / base_tax()`; `repair_cost(ref, damage_fraction)`; `Treasury.charge()`; `M_repair`, `M_build` | `class`/`tax_class`, `level`, `condition ∈ [0,1]`, `state`; per-job `refund_fraction`; `damage_fraction` per repair |
| **04 — Electrical grid** (`sim/power/`) | `P[building_id]` = `power_availability_hour()` ∈ [0,1]; serving `grid_node_id`; `upgrade_headroom_kw(building_id)`; `overload_excess`; outage flag | `power_demand_kw` per building per tick (doc 04's own `base_kw` table is deleted — **this doc is the source**, report 98 C-31); **`footprint` for the three utility shells** (C-30 — `water_facility`'s is the `pump` reference row only, RR-8); critical-facility priority tier |
| **05 — Water system** (`sim/water/`) | `W[building_id]` = `water_service_factor_hour()`; `pressure_zone_id`; `zone_headroom_m3h(building_id)`; **every per-variant `water_facility` number — `footprint`, `base_kw`, capacity/volume/head, `coverage_frac`** (C-35, RR-8) | `water_demand` in m³/h per building per tick; `population`/`jobs` capacity for per-capita derivation; the `water_facility` **shell + variant list** and the `k_dem = 2.45` shape the per-variant ladders are generated on (C-35) |
| **06 — Incidents, dispatch & emergency fleets** (`sim/incidents/`, `sim/dispatch/`, `sim/fleet/`) | `capacity_per_station_level` and `units_housed(s)` (C-50); `crew_rate` and crew assignment/preemption; `FireStarted`/`FireSuppressed`/`BurnDown`; residual `damage_fraction`; situational fire multipliers | `coverage_police(pos)` / `coverage_fire(pos)` **implemented here** (C-51); station `coverage_radius_tiles`, condition and state; `fire_ignition_per_hour` (normative, C-42); `fire_load` → `S_req_base` (C-43); `crime_weight` (C-44); `safety_coverage_factor`; per-building state for target eligibility; crew-hour requests |
| **07 — Weather & Disaster Director** (`sim/weather/`, `sim/director/`) | `weather.get_effect("load_mult" \| "water_mult" \| "decay_mult" \| "fire_mult" \| "build_mult")` — **authoritative, no constant authored here** (C-57) | `fire_load` and `condition` as damage targets; `damage_fraction` acceptance |
| **08 — Persistence, offline & notifications** (`sim/persistence/`, `sim/offline/`) | migration hooks; the coarse-advance contract; `world.destroy_allowed()` (C-47); `OfflinePolicy.band_for()` via `TimeContext` | the `buildings` (§3.2) and `construction` (§3.3) save sections, both keyed `section_version`; `BuildingCompleted` / `BuildingDestroyed` events for the WHILE YOU WERE AWAY report |
| **09 — Map, land, districts, population & stability** (`sim/world/`, `sim/population/`) | tile ownership + development state; `district_id`; `city_level` and its population thresholds; `occupancy[id]` / `job_fill[id]` (G-1) | tile occupancy claims (footprint + rubble); `population`/`jobs` capacity per building; `safety_coverage_factor` as a district stability component; land-development jobs accepted into `ConstructionQueue` (G-2) |
| **10 — Roads, routing & traffic** (`sim/roads/`) | `access_quality(pos) ∈ [0,1]` — **the single definition of road access** (C-61); road-graph component id; `AVENUE`-class tile lookup for `E_AVENUE` (C-62) | road construction jobs accepted into `ConstructionQueue` (G-2) |
| **11 — Rendering & performance** (`game/`) | nothing | per-building snapshot: type, level, state, condition, `overlay_state`; structural `occ_b` that doc 11 multiplies by its own art-owned `occupancy_hour_curve` (C-66) |
| **12 — UI/UX, camera input & onboarding** (`ui/`) | nothing | the 13 blocker codes for `RequirementFormatter` (C-62); `upgrade_preview()`; per-variant build cards for `water_facility` (C-35); queue reorder handles |

**Contract note for doc 04.** Power demand is published **per building per tick as a request**; satisfaction returns as a time-weighted `power_availability_hour()` scalar over the settled hour, not a boolean (report 98 C-37). This system never reads grid topology beyond its serving `grid_node_id`.

**Ownership split on the three infrastructure archetypes.** For `power_facility`, `substation` and `water_facility`, this doc owns the **building shell only**: build/upgrade crew-hours, jobs, condition/decay, fire and crime stats, coverage requirements, the state machine and the variant list. Footprint is authoritative here for `power_facility`, `substation` and the `water_facility` **`pump` reference variant**; the other four `water_facility` variants' footprints are **doc 05's** *(RR-8)*. Electrical capacity and topology are **doc 04's**; hydraulic capacity, pressure and every per-variant number are **doc 05's**. There is no fallback table here any more — `sim/buildings/` is testable standalone because those fields are simply absent from its schema.

---

## 6. MVP Cut

**Ships in the vertical slice (spec §43):**

- All 12 archetypes, all 5 levels, exactly the tables in §2.3–2.4, plus the five `water_facility` variants.
- Full state machine, all 8 states and every transition in §2.12.
- All **13** upgrade precondition checks with per-code UI messaging.
- Condition decay on `[0,1]`, repair via `damage_fraction`, rebuild, rubble clearing.
- Fire ignition rolls + `fire_load` publication (dynamics in doc 06).
- `crime_weight` publication for doc 06.
- Coverage provision (`sim/buildings/coverage.gd`) + requirement checking.
- `sim/construction/`: project records, integer work units, `submit` / `reorder` / `cancel`, the four job events.
- Footprint growth at the four defined levels (store L3, power L4, yard L4, water L5 — the last one on the `pump` reference variant; the other four variants grow on **doc 05's** per-variant schedule, e.g. `tank` 2×2 → 3×3 at L3, RR-8).

**Deferred past the slice:**

- Archetypes 7/8/10/11/12 from spec §9.1 (factory, warehouse, hospital, school, stadium).
- Building-specific incident types beyond fire/crime (data-center cooling failure, backup-generator dependence — spec §10); `data_center` ships with generic fire, its cooling-failure event is a doc 06 Phase 3 item.
- Non-square footprints and building rotation.
- Land-value / desirability modifiers on tax (doc 03's territory in any case).
- Research/technology unlock preconditions (spec §9.4 lists them; MVP uses `min_city_level` only).
- Historic/landmark cosmetic variants and premium architecture packs (spec §37.3).
- Per-level distinct 3D models — placeholder gray-box with per-level height and emissive window density (constitution §11).

---

## 7. Test Plan

Headless tests in `tests/sim/buildings/` and `tests/sim/construction/`, run by `godot --headless --path . -s res://tests/run_tests.gd`.

**Data integrity**
1. `test_catalog_loads` — 12 archetypes; **5 ordered levels each, or 6 exactly where `sixth_level_archetypes` says (§2.14)**; `max_level_of(archetype)` and `is_top_level` agree with the row count; all loader invariants from §3.1 hold; `variants` present only on `water_facility`. The malformed-fixture sweep now includes a sixth rung smuggled onto an archetype the rules do not name — a mesh set and a money row would not know about it.
2. `test_curve_consistency` — regenerating every level from **`building_rules.json`'s `seed_rows` block** (the unrounded seeds, *not* the printed/stored L1 cell) and the class multipliers, with the §2.2 rounding ladders applied half-up once per cell, reproduces `buildings.json` byte-for-byte. Catches hand-edits that break the family. **The seed-vs-cell distinction is load-bearing** *(RR-8)*: reading L1 from the table instead of the seed fails 8 of the 60 water cells (`store` L2/L3/L5, `high_rise` L3/L4/L5, `police_station` L3/L5).
2b. `test_water_seeds_published` — `seed_rows.store.water == 0.128`, `seed_rows.high_rise.water == 1.28`, `seed_rows.police_station.water == 0.192`, and for all 12 archetypes `round_wu(seed) == levels[0].water_demand`. Guards the audit trail RR-8 restored.
3. `test_no_deleted_columns` — `buildings.json` contains **none** of `build_cost`, `upgrade_cost`, `tax_cents_per_hour`, `upkeep_cents_per_hour`, `power_supply_kw`, `power_throughput_kw`, `feeder_radius_tiles`, `water_supply_wu_per_hour`, `pressure_radius_tiles`, `unit_slots`, `crew_slots`, `burn_hours`, `required_fire_units`, `spread_radius_tiles`. Fails loudly if a ruling is silently reverted.
4. `test_demand_growth_invariant` — **for all three growth classes `k_dem > 2.15`** (doc 03's `TAX_LEVEL_GROWTH`, read from `data/economy.json` at test time, not hard-coded). This is the C-13 guard and the most important assertion in the file.
5. `test_condition_scale` — every `decay_per_hour < 0.01`, every condition constant in `building_rules.json` ∈ [0,1]; a fixture at condition 0.35 auto-damages, one at 0.36 does not.
6. `test_water_anchor` — `house` L1 `water_demand == 0.08` exactly (`4 × 0.020`), `apartment` L1 `== 0.48` (`24 × 0.020`), matching doc 05 §2.13's per-capita rate.
6b. `test_variant_footprints_not_here` — `buildings.json` carries **exactly one** footprint ladder for `water_facility` (the `pump` reference row `3x3/3x3/3x3/3x3/4x4`) and **no** per-variant footprint table; `BuildingCatalog.level_stats("water_facility", L, variant)` returns doc 05's footprint for `source`/`treatment`/`tank`/`booster` (`tank` L1 == `[2,2]`, **not** `[3,3]`) and doc 02's own row only for `pump`. Guards RR-8 / F-08 and doc 09's 77-tile starter footprint total.
7. `test_no_magic_numbers` — grep `sim/buildings/` and `sim/construction/` for numeric literals outside `0, 1, -1, 2` and fail on hits (constitution §3).

**Published outputs**
8. `test_publishes_no_currency` — `city_totals()` and `snapshot_building()` expose no dollar, cent or tax field; `sim/buildings/` contains no reference to `Treasury` except through `economy.repair_cost` / `CostCurves`.
9. `test_safety_coverage_factor_bounds` — `S = 0 → 0.80`, `S = 1 → 1.00`, and the value is published to doc 06/doc 09 but never multiplied into any revenue path.
10. `test_state_modifier_table` — for each of the 8 states, output/demand/occupancy/coverage multipliers match §2.12.
11. `test_demand_worked_example_E1` — apartment L3 publishes exactly `130 kW` and `2.9 m³/h` at `state = active` with weather mults 1.0.

**Upgrade gate**
12. `test_upgrade_blocked_power_headroom` — the §2.11 E2 fixture (37 kW reported headroom, `delta_power = 76 kW`, requirement `87.4 kW`) returns exactly `[E_POWER_HEADROOM]`; raising doc 04's reported headroom to 90 kW clears it.
13. `test_upgrade_blocked_each_code` — **13** fixtures, one per blocker code, each returning exactly that one code.
14. `test_e_avenue_gate` — an L3 building with only `STREET` tiles within 4 tiles is blocked with `[E_AVENUE]` on the L3→L4 step and **not** on L2→L3; stamping an `AVENUE` 4 tiles away clears it; at 5 tiles it does not.
15. `test_upgrade_multiple_blockers` — a fixture failing funds + coverage + city level returns all three, sorted stably.
16. `test_footprint_growth_gate` — store L2→L3 blocked with `E_FOOTPRINT` when a +X tile holds a road; passes after the road moves; the 3 new tiles are claimed on completion.
17. `test_level_only_via_upgrade` — `place_building` with any level ≠ 1 is rejected.
18. `test_condition_gate` — an upgrade at condition 0.54 is blocked with `E_CONDITION`; at 0.55 it passes.

**Lifecycle**
19. `test_state_machine_legal_transitions` — every legal transition in §2.12 succeeds; a random sample of 40 illegal pairs all raise and leave state unchanged.
20. `test_upgrade_in_progress_economics` — an upgrading L3 office draws full L3 power (210 kW) and reports `output × 0.35` for the whole build.
21. `test_cancel_refunds` — the three `refund_fraction` rows of §2.10, exact fractions (no dollar assertions — doc 03 owns the conversion).
22. `test_decay_and_repair_E4` — 168 gh healthy → condition **0.879 ±0.0005**; overloaded variant → **0.828 ±0.0005**; `damage_fraction = 0.172`, `repair_hours = 1.25 ±0.01`; the doc-03 price stub returns **$6,291 ±1** at standard difficulty.
23. `test_condition_auto_damage` — condition crossing **0.35** transitions `active → damaged` on the same hour tick and emits one event.
24. `test_fire_load_ladder` — `fire_load` doubles per level for all 66 rows (§2.14); `house` L1 = 20 and `high_rise` L5 = 1120 (56×); doc 06's `S_req_base(20) == 0.50` and `S_req_base(1120) == **3.06** ±0.01` by the §2.7 formula — **3.06 is canonical, the report's old "≈3.6" gloss is void** *(RR-9)*; `s_req_base_exponent == 0.45`.
25. `test_destroy_guard_offline` — with `world.destroy_allowed() == false`, a burn-down clamps condition to 0.15, leaves the incident open, and emits **no** `BuildingDestroyed`.
26. `test_rebuild_grace` — rebuild at 71 gh preserves level; at 73 gh level resets to 1 (cost assertions live in doc 03's suite).

**Construction queue**
27. `test_construction_time_E3` — office L4→L5, 2 crews, clear weather, `construction_rate` at its 0.804 mean → **18.7 gh ±0.1**; 1 crew → **37.3 gh ±0.1**; 1 crew held at the 0.60 night floor → **50.0 gh ±0.1**.
28. `test_construction_rate_channel_applied` — a project run with `construction_rate` forced to 1.0 finishes in exactly `0.804×` the wall time of the same project at the channel's mean. Guards C-29.
29. `test_work_units_are_integers` — after 10,000 ticks at fractional crew power, `work_units` is an exact int64 and a save round-trip reproduces the identical completion tick.
30. `test_queue_reorder_and_cancel` — `reorder` moves a pending job without disturbing running crews; `cancel` returns the §2.10 fraction and releases crews to doc 06.
31. `test_crew_preemption` — a crew preempted at priority 400 leaves `work_units` untouched and sets `blocked_reason = "crew_preempted"`.

**Determinism & persistence**
32. `test_ignition_determinism` — 200 buildings, 2,000 game-hours, `failures` stream seeded: two runs produce identical ignition sequences; the coarse 1-game-hour offline path produces the same result as the online path (constitution §4).
33. `test_save_roundtrip` — 500 buildings in mixed states plus 40 queued jobs serialize/deserialize identically, including `variant`, `pending_level` and `work_units`; both sections carry `section_version`, neither carries `schema_version` or `tax_accum_cents`.

---

## 8. Tunables

Two files. `data/buildings.json` is generated from the seed rows by the rules in §2.2 and fully listed in §2.3–2.4 (60 rows) and §2.14 (the 6 sixth rows, 66 in total); its loader-facing schema is §3.1. Below is `data/building_rules.json` — every global constant this system introduces — plus the seed block that regenerates the table.

```json
{
  "schema_version": 2,
  "growth_classes": {
    "steady":   { "k_out": 1.55, "k_dem": 2.35, "k_time": 1.40 },
    "standard": { "k_out": 1.85, "k_dem": 2.45, "k_time": 1.55 },
    "vertical": { "k_out": 2.10, "k_dem": 2.55, "k_time": 1.70 }
  },
  "demand_growth_invariant": {
    "must_exceed": "economy.TAX_LEVEL_GROWTH",
    "reason": "report 98 C-13 / spec §55 rule 3 — every upgrade must be less utility-efficient"
  },
  "shared_curves": {
    "k_decay": 1.20,
    "k_fire_rate": 1.28,
    "k_fire_load": 2.00,
    "k_crime": 1.60,
    "k_radius": 1.25,
    "upgrade_time_factor": 0.65
  },
  "water_facility_variants": ["source", "treatment", "pump", "tank", "booster"],
  "water_facility_reference_variant": "pump",
  "water_facility_per_variant_numbers": {
    "_owner": "doc 05 — data/water.json components[variant]",
    "_fields": ["footprint_w", "footprint_h", "base_kw", "capacity", "volume", "head_m", "coverage_frac", "backup_kw"],
    "_note": "report 98 C-35 + RR-8. This file's water_facility seed row is the `pump` REFERENCE variant only. Doc 02 authors NO per-variant footprint; the earlier 'all variants reuse the 3x3 shell' claim is deleted (a tank L1 is 2x2 / 5.0 kW). Doc 02 owns only the k_dem = 2.45 shape doc 05 generates those ladders on."
  },
  "coverage_ladder": {
    "fire":   [0.00, 0.20, 0.40, 0.60, 0.80],
    "police": [0.00, 0.15, 0.35, 0.55, 0.75],
    "archetype_multiplier": { "default": 1.00, "high_rise": 1.25, "data_center": 1.25,
                              "police_station": 0.75, "fire_station": 0.75, "power_facility": 0.75,
                              "substation": 0.75, "water_facility": 0.75, "construction_yard": 0.75 },
    "max_requirement": 0.95,
    "falloff_exponent": 1.5,
    "redundancy_bonus_per_extra_station": 0.15,
    "redundancy_min_contribution": 0.30,
    "station_condition_floor": 0.50,
    "station_condition_span": 0.50,
    "station_condition_low_anchor": 0.20,
    "station_condition_range": 0.80
  },
  "min_city_level_by_level": [0, 1, 2, 3, 4],
  "safety_coverage_factor": { "floor": 0.80, "span": 0.20 },
  "condition": {
    "start": 1.00,
    "band_good": 0.85, "band_worn": 0.60, "band_poor": 0.35,
    "auto_damage_threshold": 0.35,
    "structural_failure_threshold": 0.10,
    "structural_failure_p_per_hour": 0.02,
    "offline_burn_down_clamp": 0.15,
    "overload_decay_coefficient": 0.80,
    "unpowered_decay_coefficient": 0.50,
    "damaged_decay_multiplier": 1.50,
    "repair_time_factor": 0.50,
    "repair_target_active": 1.00,
    "repair_target_damaged": 0.85,
    "min_condition_to_upgrade": 0.55
  },
  "fire": {
    "condition_mult_coefficient": 1.5,
    "condition_mult_exponent": 1.5,
    "state_ignition_multiplier": { "under_construction": 1.4, "active": 1.0, "damaged": 1.8, "repairing": 1.8 },
    "s_req_base_coefficient": 0.50,
    "s_req_base_anchor_fire_load": 20,
    "s_req_base_exponent": 0.45,
    "_s_req_base_note": "LOCKED by report 98 RR-9. 0.50 x (fire_load/20)^0.45 is canonical: house L1 = 0.500, high_rise L5 = 3.06 (0.50 x 56^0.45 = 3.05948). C-43's old '~3.6' gloss was arithmetically wrong and is corrected in place; reaching 3.60 would need exponent 0.490424. Doc 02's earlier 0.474 proposal is withdrawn. Doc 06 implements; doc 02 owns only fire_load."
  },
  "construction": {
    "work_units_per_crew_hour": 100,
    "base_crew_rate": 1.0,
    "max_crews_per_project_base": 1,
    "hours_per_extra_crew_slot": 20,
    "max_crews_per_project_cap": 4,
    "max_road_distance_tiles": 2,
    "road_access_mult_1_tile": 1.00,
    "road_access_mult_2_tiles": 0.85,
    "crew_preempt_priority": 400,
    "auto_dispatch_construction": false,
    "refund_fraction_planned": 1.00,
    "refund_fraction_under_construction_new": 0.60,
    "refund_fraction_under_construction_upgrade": 0.50,
    "rubble_clear_time_factor": 0.25,
    "rebuild_grace_hours": 72
  },
  "headroom_safety": { "power": 1.15, "water": 1.10 },
  "avenue_gate": { "min_level": 4, "max_distance_tiles": 4, "road_class": "AVENUE" },
  "state_modifiers": {
    "planned":                    { "output": 0.00, "demand": 0.00, "occupancy": 0.00, "coverage": 0.00 },
    "under_construction_new":     { "output": 0.00, "demand": 0.15, "water_demand": 0.10, "occupancy": 0.00, "coverage": 0.00 },
    "under_construction_upgrade": { "output": 0.35, "demand": 1.00, "occupancy": 0.50, "coverage": 0.50 },
    "active":                     { "output": 1.00, "demand": 1.00, "occupancy": 1.00, "coverage": 1.00 },
    "damaged":                    { "output": 0.40, "demand": 0.50, "occupancy": 0.40, "coverage": 0.25 },
    "repairing":                  { "output": 0.40, "demand": 0.50, "occupancy": 0.40, "coverage": 0.25 },
    "on_fire":                    { "output": 0.00, "demand": 0.00, "occupancy": 0.00, "coverage": 0.00 },
    "destroyed":                  { "output": 0.00, "demand": 0.00, "occupancy": 0.00, "coverage": 0.00 }
  },
  "seed_rows": {
    "_note": "NORMATIVE GENERATION INPUT (report 98 RR-8). data/buildings.json is generated from these rows; nothing regenerates from a printed or stored L1 cell. `water` is the UNROUNDED C-34 quotient (old WU/gh / 6.25) and for store / high_rise / police_station it differs from the displayed L1 cell (0.128 vs 0.13, 1.28 vs 1.3, 0.192 vs 0.19). Regenerating from the rounded cell breaks 8 of the 60 water cells. `power_kw` seeds coincide with their displayed cells for all 12 archetypes. Footprints for the four non-reference water_facility variants are NOT here — see water_facility_per_variant_numbers.",
    "house":             { "class": "steady",   "tax_class": "residential", "footprints": ["1x1","1x1","1x1","1x1","1x1"], "pop": 4,  "jobs": 0,  "power_kw": 3,   "water": 0.08, "time_h": 2,  "decay": 0.00045, "fire_p": 0.00015, "fire_load": 20, "crime": 1.0, "min_city": 0 },
    "apartment":         { "class": "standard", "tax_class": "residential", "footprints": ["2x2","2x2","2x2","2x2","2x2"], "pop": 24, "jobs": 2,  "power_kw": 22,  "water": 0.48, "time_h": 6,  "decay": 0.00050, "fire_p": 0.00022, "fire_load": 45, "crime": 2.0, "min_city": 1 },
    "store":             { "class": "steady",   "tax_class": "commercial",  "footprints": ["1x1","1x1","2x2","2x2","2x2"], "pop": 0,  "jobs": 6,  "power_kw": 9,   "water": 0.128,"time_h": 3,  "decay": 0.00055, "fire_p": 0.00030, "fire_load": 25, "crime": 3.0, "min_city": 0 },
    "office":            { "class": "standard", "tax_class": "commercial",  "footprints": ["2x2","2x2","2x2","2x2","2x2"], "pop": 0,  "jobs": 30, "power_kw": 35,  "water": 0.32, "time_h": 8,  "decay": 0.00045, "fire_p": 0.00020, "fire_load": 40, "crime": 1.5, "min_city": 1 },
    "high_rise":         { "class": "vertical", "tax_class": "residential", "footprints": ["2x2","2x2","2x2","2x2","2x2"], "pop": 60, "jobs": 15, "power_kw": 90,  "water": 1.28, "time_h": 16, "decay": 0.00060, "fire_p": 0.00026, "fire_load": 70, "crime": 2.5, "min_city": 3 },
    "data_center":       { "class": "vertical", "tax_class": "tech",        "footprints": ["2x2","2x2","2x2","2x2","2x2"], "pop": 0,  "jobs": 12, "power_kw": 400, "water": 3.2,  "time_h": 20, "decay": 0.00075, "fire_p": 0.00060, "fire_load": 80, "crime": 2.0, "min_city": 4 },
    "police_station":    { "class": "standard", "tax_class": "civic",       "footprints": ["2x2","2x2","2x2","2x2","2x2"], "pop": 0,  "jobs": 12, "power_kw": 25,  "water": 0.192,"time_h": 10, "decay": 0.00040, "fire_p": 0.00010, "fire_load": 30, "crime": 0.2, "min_city": 0, "coverage_radius": 20 },
    "fire_station":      { "class": "standard", "tax_class": "civic",       "footprints": ["2x2","2x2","2x2","2x2","2x2"], "pop": 0,  "jobs": 14, "power_kw": 28,  "water": 0.40, "time_h": 10, "decay": 0.00040, "fire_p": 0.00006, "fire_load": 25, "crime": 0.3, "min_city": 0, "coverage_radius": 18 },
    "power_facility":    { "class": "vertical", "tax_class": "utility",     "footprints": ["3x3","3x3","3x3","4x4","4x4"], "pop": 0,  "jobs": 20, "power_kw": 0,   "water": 0.96, "time_h": 18, "decay": 0.00090, "fire_p": 0.00090, "fire_load": 90, "crime": 1.2, "min_city": 0 },
    "substation":        { "class": "standard", "tax_class": "utility",     "footprints": ["2x2","2x2","2x2","2x2","2x2"], "pop": 0,  "jobs": 4,  "power_kw": 0,   "water": 0.0,  "time_h": 8,  "decay": 0.00080, "fire_p": 0.00070, "fire_load": 55, "crime": 1.5, "min_city": 0 },
    "water_facility":    { "class": "standard", "tax_class": "utility",     "footprints": ["3x3","3x3","3x3","3x3","4x4"], "pop": 0,  "jobs": 10, "power_kw": 60,  "water": 0.0,  "time_h": 12, "decay": 0.00070, "fire_p": 0.00012, "fire_load": 25, "crime": 0.8, "min_city": 0, "variants": ["source","treatment","pump","tank","booster"], "reference_variant": "pump", "footprints_are_reference_variant_only": true, "per_variant_footprint_source": "data/water.json components[variant][L].footprint_w/h" },
    "construction_yard": { "class": "steady",   "tax_class": "civic",       "footprints": ["2x2","2x2","2x2","3x3","3x3"], "pop": 0,  "jobs": 16, "power_kw": 12,  "water": 0.16, "time_h": 10, "decay": 0.00065, "fire_p": 0.00040, "fire_load": 50, "crime": 2.2, "min_city": 0, "coverage_radius": 30 }
  },
  "rounding": {
    "_applies_to": "the raw product seed x k^(L-1), once per cell, at table-generation time only — never at runtime",
    "_tie_break": "half_up",
    "time_h": [[20, 0.5], [null, 1]],
    "kw":     [[10, 0.5], [100, 1], [1000, 5], [10000, 10], [null, 50]],
    "wu":     [[1, 0.01], [10, 0.1], [100, 0.5], [null, 1]],
    "decay":  [[null, 0.000001]]
  }
}
```

**Constants that used to live here and no longer do** (report 98): `upkeep_fraction_of_build_cost_per_hour` (C-08 → doc 03), `upgrade_cost_factor` and `k_cost` (C-07 → doc 03 `UPG_COEFF`/`UPG_GROWTH`), `repair_cost_factor` (C-16 → doc 03 `REPAIR_COST_PER_CAPITAL`), `service_factor.power_*`/`water_*` (C-09 → doc 03 `f_power`/`f_water`), `condition.factor_*` (C-09 → doc 03 `f_condition`), the whole `crime` coefficient block (C-44 → doc 06), `fire.base_burn_hours` / `k_burn_hours` / `units_per_fire_load` / `max_required_units` / `tiles_per_spread_step` / `max_spread_radius_tiles` (C-43 → doc 06), the five `weather_*_mult` values (C-57 → doc 07 `get_effect()`), `feeder_condition_derate` (C-30 → doc 04), `city_level_population_thresholds` (G-1 → doc 09 `data/progression.json`), `rebuild_cost_factor` and `rubble_clear_cost_factor` (C-07 → doc 03).

---

## 9. Conflicts & Open Questions

Every conflict raised by v1 of this doc has been ruled on by report 98 and applied in §10. The list below records the outcome and keeps only what is genuinely still open.

**Resolved by report 98 (recorded, not re-litigated):**

1. **Doc numbering** — resolved by Ruling Zero. The on-disk filenames are canonical; §5 is rewritten against them. No code may reference a doc number until the whole fleet has applied this.
2. **Doc 04 vs this doc on electrical tables** — C-30: doc 04 owns every capacity and topology number; this doc keeps the shell and its `footprint` column is authoritative over doc 04's. *(RR-8 narrows this for `water_facility` only: doc 02's footprint row is the `pump` reference variant; the other four variants' footprints are doc 05's.)*
3. **Currency scale** — C-07: doc 03 is the sole currency authority. Every cost, tax and upkeep column is gone from here. My v1 open question "starting treasury and the currency scale" is answered: $25,000 at standard, house L1 $1,200.
4. **Doc 05 vs this doc on water** — C-34: `1 WU ≡ 1 m³/h`, this column divided by 6.25, doc 05 rescaled by `WU_SCALE 0.1333`. The two independently authored tables now agree within 20 %. C-35 adds the `variant` field.
5. **Crew capacity** — C-50: doc 06 owns unit capacity; `unit_slots` and `crew_slots` deleted. G-2 then splits construction three ways and gives this doc the project record and the queue API.
6. **Fire risk double-weighting** — C-42: this doc's per-archetype-per-level `fire_ignition_per_hour` is normative and doc 06's `base_fire_risk_by_archetype` is deleted. C-43 gives doc 06 the dynamics and requires it to derive `S_req_base` from this doc's `fire_load`.
7. **Coverage formula ownership** — C-51: **this doc implements it**, in `sim/buildings/coverage.gd`. My v1 proposal to hand it to doc 06 is overruled, correctly — I own the radii, the staffing term and the requirement ladder.
8. **Is increasing payback-per-level the right lesson?** — answered sideways and better. After C-07/C-10 the dollar payback is nearly flat across levels (~104 / 70 / 85 / 101 / 122 gh) because doc 03 generates tax from cost. The "going tall costs you" lesson is now carried by `k_dem` (C-13) instead: **an L5 vertical building is 97.8 % less utility-efficient per tax dollar than its L1.** That is a better place for the lesson — it lands as grid stress and blackout risk, which the player can see, rather than as a spreadsheet ratio.

9. **`S_req_base` calibration constant** *(was open question 1)* — **closed by RR-9.** The formula `0.50 × (fire_load/20)^0.45` is canonical and `high_rise` L5 = **3.06**; C-43's "≈3.6" gloss was arithmetically wrong and has been corrected in report 98 §5 in place. Doc 06's shipped 3.060 was correct; doc 06 needs no change; this doc's proposed 0.474 exponent is withdrawn and `s_req_base_exponent` stays at 0.45 (§8). Nothing in the `fire_load` ladder moves.
10. **Water-table reproducibility and per-variant footprints** — **closed by RR-8.** §2.3 now publishes the unrounded L1 water seeds beside the display-rounded cells and states that generation runs from the seeds; §8's `seed_rows` was already carrying them, so no published value changed. The claim that the four non-reference `water_facility` variants reuse the `pump` 3×3 shell is deleted — per-variant footprints are doc 05's property (`tank` 2×2 at L1–L2), which is what doc 09's 77-tile starter footprint total already assumed.

11. **Cells that fail `test_curve_consistency`** *(was open question 4 — "three cells still fail")* — **closed by RR-19.** There were **four**, not three. The P0-15 generator swept all 60 rows × every column with `Decimal`/half-up and found one cell nobody had audited: **`water_facility` L2 `jobs` = 18** where `10 × 1.85 = 18.5` is an exact tie and the rule gives **19**. Doc 97 §1 checked `k_dem` (60 power + 60 water cells) and the 240 `k_decay`/`k_fire_rate`/`k_fire_load`/`k_crime` cells, but **never swept the `k_out` column**, so pop/jobs went unverified end to end. RR-19 rules the §2.2 rounding rules and §8 seeds the single source of truth (master-plan working rule 6: generated data is generated, never hand-edited) and **corrects all four published cells to the rule-generated values**: `house` L4 fire `0.00032 → 0.00031`, `construction_yard` L3 fire `0.00065 → 0.00066`, `fire_station` L2 radius `22 → 23`, `water_facility` L2 jobs `18 → 19`. The generator ships **no whitelist**; the tables in §2.3/§2.4 above already carry the corrected values, and worked example E6 is re-derived at radius 23 (§2.9: margin 0.027, gate closes below condition 0.834). The table now contains five exact `.5` ties and all five round half-up: `office` L2 jobs 55.5 → 56, `high_rise` L2 jobs 31.5 → 32, `construction_yard` L2 radius 37.5 → 38, and the two RR-19 corrected.

**Still open — for the overseer:**

1. **Should losing coverage or headroom ever *downgrade* a building?** I still say no (§2.9) — output penalty and upgrade block only. A "brownout downgrade" would be more dramatic but risks spec §20.2 readability and irreversible offline losses.
2. **Data-center gating at city level 4 (12,000 pop) may be too late for the vertical slice**, which is supposed to demonstrate "one building eats the whole grid." After C-13 an L1 data center draws 400 kW and an L2 draws 1,020 kW, so the demonstration is now sharper and later. Consider a slice-only override to city level 2, or a scripted starter data center.
3. **Fire station L1 houses 1 engine** (doc 06's `[1,2,3,4,5]`), while an L5 high-rise needs `S_req_base` **3.06** of suppression rate (now a settled figure, RR-9). That is intentional early pressure, but a one-station city can be genuinely overwhelmed. Doc 06 should confirm it as the Standard-difficulty floor.
4. **`store` at L4–L5 is functionally a strip mall.** Kept as one archetype id to hold MVP at 12; the art doc needs to know the silhouette changes character at L3 when the footprint goes 2×2.

**Conflicts with the constitution:** none. Footprints stay within the 1×1…4×4 range of §6; all rates are per game-hour per §7; **no currency is defined here at all**, so §7's int64 whole-dollar rule is doc 03's to keep; utilities are graphs with capacity and load, not coverage percentages, per §8 — the two radius columns that violated it are deleted (C-06); every constant is in `data/`; no `sim/` class here touches Node, wall time, or a global RNG.

---

## 10. Amendments applied (report 98)

| Ruling | Change |
|---|---|
| **Ruling Zero** | §5 cross-reference table rewritten against the canonical on-disk numbering; every doc reference in the file (02–13) renumbered and each system also named in words. |
| **C-06** | `pressure_radius_tiles` and `feeder_radius_tiles` deleted from §2.4, §3.1 and §8 — constitution §8 forbids coverage-percentage models for utilities; doc 05's pressure zones and doc 04's transformer `service_radius_tiles` replace them. |
| **C-07** | All build/upgrade cost columns deleted from §2.3, §3.1, §8 and §2.10's refund table (now fractions); doc 03 is the sole currency authority and supplies `build_cost_l1` + `CostCurves`. |
| **C-08** | `upkeep_cents_per_hour` and `upkeep_factor` deleted; recurring expense is doc 03's `BUILDING_MAINT_RATE` / `station_upkeep` / `E_grid` / `E_water`. |
| **C-09** | §2.5's tax formula deleted; this doc now publishes only population, jobs, condition, state and per-tick power/water demand. The surviving safety term is renamed **`safety_coverage_factor` = 0.80 + 0.20·S** and feeds doc 03 only through `f_stability`. |
| **C-10** | `Tax $/gh` column deleted from all 12 stat tables; doc 03's `base_tax_by_level` is authoritative. |
| **C-13 / R-01** | `k_dem` raised to **2.35 steady / 2.45 standard / 2.55 vertical**; **all 60 rows of `power_demand_kw` and `water_demand` regenerated** with L1 anchors held fixed. Every class is now strictly above doc 03's `TAX_LEVEL_GROWTH 2.15`. |
| **C-14 / R-02** | `condition` rescaled to **[0,1]** everywhere: bands 0.85/0.60/0.35, `auto_damage_threshold` 0.35, `structural_failure_threshold` 0.10, all 60 `decay_per_hour` values ÷100, `min_condition_to_upgrade` 0.55, station condition factor reformulated on 0.20/0.80. |
| **C-15** | `tax_accum_cents` deleted from the `buildings` save section; doc 03's single city-wide rounding with `revenue_carry_millidollars` is the only sub-dollar scheme. |
| **C-16** | Repair expressed as `damage_fraction = 1 − condition` plus crew-hours; pricing calls `economy.repair_cost(ref, damage_fraction)`. `repair_cost_factor` deleted. |
| **C-25** | Save sections keyed `section_version` (both `buildings` and the new `construction`); `schema_version` survives only on the `data/` files. |
| **C-30** | `power_supply_kw` and `power_throughput_kw` deleted; **`footprint` retained here as the authoritative column** for the three utility shells; `E_POWER_HEADROOM` now calls doc 04's `upgrade_headroom_kw()`. *(Narrowed by RR-8 below: for `water_facility` the column is the `pump` reference variant only.)* |
| **C-34** | Water column divided by 6.25 before regrowth; `1 WU ≡ 1 m³/h`; `house` L1 = **0.08** exactly (4 × 0.020) and `apartment` L1 = 0.48; WU rounding ladder given a new 0.01 step below 1.0 so the anchor survives. |
| **C-35** | `water_facility.variant = source \| treatment \| pump \| tank \| booster` added to §2.1, §3.1, §3.2 and §8; shell + variant list owned here, per-variant numbers owned by doc 05; `pump` named as the reference variant the shell table is generated for. *(RR-8 below makes explicit that "per-variant numbers" includes `footprint`.)* |
| **C-42** | `fire_ignition_per_hour` restated as **normative** — doc 06 may apply situational multipliers only and has deleted `base_fire_risk_by_archetype`. |
| **C-43 / R-12** | `burn_hours`, `condition_loss_per_hour`, `required_fire_units` and `spread_radius_tiles` deleted with their tunables; `fire_load` kept as the consequence index; §2.7 states doc 06's derivation `S_req_base = 0.50 × (fire_load/20)^0.45` and E5 recomputed as that handoff. |
| **C-44** | The `no_police` / `night` / `outage` multiplier stack deleted; only `crime_weight` is published, as doc 06's within-district weighted pick on the `crime` RNG stream. |
| **C-50** | `unit_slots` and `crew_slots` deleted; §2.9's staffing term reads doc 06's `capacity_per_station_level`. |
| **C-51** | `coverage_police(pos)` / `coverage_fire(pos)` owned, specified and implemented here in **`sim/buildings/coverage.gd`**; doc 06 consumes the scalars. |
| **C-57** | All five inline `weather_*_mult` constants deleted; every call site reads doc 07's `weather.get_effect()`. |
| **C-62** | Precondition **#13 `E_AVENUE`** added: L4/L5 requires an `AVENUE` within 4 tiles of the access tile. Enum is now 13 codes; test 14 added. |
| **G-2** | New §2.13 and `sim/construction/`: project record, integer work units (`WORK_UNITS_PER_CREW_HOUR = 100`), `ConstructionQueue.submit / reorder / cancel / list`, `job_started/completed/cancelled/blocked` events, crew preemption at priority 400, new `construction` save section (§3.3). |
| **C-47** | `destroy_building` guarded by `world.destroy_allowed()`; offline burn-down clamps condition to 0.15 and refuses the verb visibly. |
| **C-29** | §2.10 and §2.13 multiply `ctx.channels.construction_rate` into every work unit; E3 recomputed against its 0.804 mean. *(Applied from C-29's own Amend line, which names 02 §2.10.)* |
| **C-61** | Road access reads doc 10's single `access_quality(pos)` definition. |
| **C-26 / G-1 / C-66 / C-37** | `construction` save section assigned here; `occupancy`/`job_fill`/`city_level` handed to doc 09 and removed from the save row; doc 11 owns the diurnal `occupancy_hour_curve`; doc 04 returns time-weighted `power_availability_hour()`. |
| **R-03** | Payback table §2.2 fully regenerated against doc 03's `build_cost_l1`, `base_tax_by_level`, `upgrade_cost_by_step`, `capital_value_by_level` and `BUILDING_MAINT_RATE`, with the generating formula stated above the table. |

### Round 2 (report 98 §14 — post-verification rulings)

Applied from the adversarial verification pass (docs 96 structural / 97 numeric). **No published stat-table value changed in this wave** — Round 2 fixes the audit trail and one ownership contradiction.

| Ruling | Change |
|---|---|
| **RR-8** *(verif F-07)* | §2.3 now publishes the **unrounded L1 water seeds** as a normative table beside the display-rounded cells, and states that generation runs from the seeds and never from a printed cell. Three seeds differ from their displayed L1 cell: `store` **0.128** (shown 0.13), `high_rise` **1.28** (shown 1.3), `police_station` **0.192** (shown 0.19); the other nine coincide. Re-derived: from the seeds all 60 water cells reproduce exactly (`0.128 × 2.35 = 0.3008 → 0.30`, `0.128 × 2.35² = 0.70688 → 0.71`, `0.128 × 2.35⁴ = 3.903745 → 3.9`; `1.28 × 2.55² = 8.3232 → 8.3`, `× 2.55³ = 21.22416 → 21.0`, `× 2.55⁴ = 54.121608 → 54.0`; `0.192 × 2.45² = 1.15248 → 1.2`, `× 2.45⁴ = 6.917761 → 6.9`) — from the rounded cells 8 of 60 break. Per-table seed footnotes added under `store`, `high_rise` and `police_station`; §8's `rounding` block gains `_tie_break: half_up` and a generation note; §7 test 2 restated to regenerate from `seed_rows` and new test **2b** `test_water_seeds_published` added. The `Pwr kW` column needed no seed table (all 12 L1 power figures are exact on their ladder). |
| **RR-8** *(verif F-08)* | The claim that `source` / `treatment` / `tank` / `booster` "reuse the same footprint … shell" as `pump` is **deleted**. Per-variant `water_facility` footprints are **doc 05's** property under C-35 (`data/water.json` `components[variant][L].footprint_w/h`); doc 02's §2.3 `Foot` column is the **`pump` reference variant only**. Doc 09's 77-tile starter footprint total — which counts `WTR-2` as a **2×2 tank**, not 3×3 — is correct. Ownership table added to §2.3, per-variant L1 footprints listed in §2.1 for reference only, §2.4/§3.1/§5/§6 carve-outs added, §8 gains `water_facility_per_variant_numbers` and flags the seed row's footprints as reference-variant-only, new test **6b** `test_variant_footprints_not_here` added. |
| **RR-9** *(verif F-09)* | §9 open question 1 is **closed**. `S_req_base = 0.50 × (fire_load/20)^0.45` is canonical and `high_rise` L5 = **3.06** (`0.50 × 56^0.45 = 3.05948`); C-43's "≈3.6" gloss was arithmetically wrong (it would need exponent `ln(7.2)/ln(56) = 0.490424`) and is corrected in place in report 98 §5. Doc 06's shipped 3.060 was right; **this doc's proposed 0.474 exponent is withdrawn** and `s_req_base_exponent` stays **0.45** with a LOCKED note in §8. §2.7's E5 closing paragraph rewritten, §7 test 24 annotated, §9 items renumbered. |

### Round 3 (report 98 §15 — closing-audit rulings)

| Ruling | Change |
|---|---|
| **RR-19** *(P0-15 implementation finding)* | **The §2.2 rounding rules and §8 `seed_rows` are the single source of truth; four published cells that violated them are corrected to the rule-generated values, and the generator ships no whitelist.** The P0-15 generator (`tools/gen_buildings.py`, `Decimal` + `ROUND_HALF_UP`) regenerated all 60 rows × every column and found four cells the tables could not reproduce — two arithmetic slips already recorded in doc 97 §1.4 and two exact `.5` ties published half-**down** under a half-up rule, one of which **no earlier sweep had seen**: doc 97 §1 audited `k_dem` (120 cells) and the 240 `k_decay`/`k_fire_rate`/`k_fire_load`/`k_crime` cells but never the `k_out` column, so `water_facility` L2 `jobs` went unverified. Corrections applied in §2.3/§2.4: `house` L4 `fire_ignition_per_hour` **0.00032 → 0.00031** (`0.00015 × 1.28³ = 0.000314573`); `construction_yard` L3 **0.00065 → 0.00066** (`0.00040 × 1.28² = 0.00065536`); `fire_station` L2 `coverage_radius_tiles` **22 → 23** (`18 × 1.25 = 22.5`, an exact tie); `water_facility` L2 `jobs` **18 → 19** (`10 × 1.85 = 18.5`, an exact tie). All five exact ties in the table now round half-up consistently (the other three — `office` L2 jobs 55.5, `high_rise` L2 jobs 31.5, `construction_yard` L2 radius 37.5 — were already correct). Worked example **E6** (§2.9) re-derived at radius 23: `(11/23)^1.5 = 0.330748` → `c = 0.669252 × 1.0 × 0.9375 = 0.627`, **margin 0.027** (was 0.006), and the upgrade gate now closes below station condition **0.834** (was 0.885, quoted as 0.89). §2.4 gains a tie-rule footnote; §9 open item 4 is **closed** and moves to the resolved list as item 11, renumbering the remaining open item. Deciding principle: master-plan working rule 6 — generated data is generated, never hand-edited. |
