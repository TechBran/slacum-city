# 98 — Cross-Doc Consistency Report & Rulings

**Status:** RULINGS — binding on docs 01–13 until the overseer overrides a specific line.
**Authority order used for every resolution:** `00-constitution.md` → the more concretely-reasoned doc (worked examples, calibrated tables, downstream dependents) → the doc that owns the subject matter by assignment.
**Scope:** every contradiction found by reading `docs/BLACKOUT-spec.md`, `00-constitution.md` and design docs 01–13 in full.
**This document does not amend the docs.** §12 is the per-doc amendment worklist; each owning doc applies its own rows.

Counts: **72 contradictions**, **9 ownership gaps**, **17 numeric recomputations forced by the rulings**, **4 constitution amendments requested**.

---

## 0. RULING ZERO — canonical doc numbering

Six docs cross-reference each other using three mutually incompatible numbering maps (01 thinks 06=roads / 07=dispatch / 10=incidents / 11=weather / 13=persistence; 03 thinks 07=incidents / 08=weather / 10=construction / 11=population / 13=persistence; 04 thinks 02=world / 03=buildings+economy / 10=UI / 11=persistence / 12=stability; 06 thinks 02=economy / 03=buildings / 08=director / 11=persistence / 12=UI; 08 and 13 each use a fourth and fifth variant). Docs 09, 10, 11 and 12 already use the on-disk filenames.

**RULING: the on-disk filenames are canonical. There is no other map.**

| # | System | Owns (code root) |
|---|---|---|
| 00 | Constitution | — |
| 01 | Time model & tick scheduler | `sim/time/` |
| 02 | Buildings, upgrades & construction projects | `sim/buildings/`, `sim/construction/` |
| 03 | Economy, taxes, land market & difficulty | `sim/economy/` |
| 04 | Electrical grid | `sim/power/` |
| 05 | Water system | `sim/water/` |
| 06 | Incidents, dispatch & emergency fleets (incl. construction crews as units) | `sim/incidents/`, `sim/dispatch/`, `sim/fleet/` |
| 07 | Weather & Disaster Director | `sim/weather/`, `sim/director/`, `sim/disasters/` |
| 08 | Persistence, offline policy & notification policy | `sim/persistence/`, `sim/offline/`, `sim/history/`, `sim/notify/` |
| 09 | Map, land, districts, **population & stability**, starter city | `sim/world/`, `sim/population/` |
| 10 | Roads, routing & traffic | `sim/roads/` |
| 11 | Rendering & performance | `game/` |
| 12 | UI/UX, camera input & onboarding | `ui/` |
| 13 | Android integration & export | `game/android/`, `android/plugins/` |
| 98 | This report | — |
| 99 | Master plan | — |

Every §5 cross-reference table in docs 01, 03, 04, 06, 08 and 13 is wrong today and must be renumbered. **No code may reference a doc number until this ruling is applied** (docs are permitted to name systems in words in the interim).

---

## 1. Constitution conflicts

### C-01 — Canonical clock storage (constitution §4 vs doc 01)
**Contradiction.** §4: "Canonical clock: game-minutes since city founding, int64." Doc 01: `tick_index` (15-game-second resolution) is authoritative, `sim_time_minutes = tick_index / 4` is derived. A minute counter cannot round-trip a quarter-minute tick.
**Resolution.** Doc 01 wins on substance; the constitution's wording is amended. `tick_index : int64` is the persisted canonical counter; `sim_time_minutes` is written at save top level per §9 and asserted equal to `tick_index / 4` on load. No numeric value changes. The existing `sim/core/game_clock.gd` already implements this.
**Amend:** 00 §4 (one sentence). **Constitution amendment #1.**

### C-02 — "4 Hz utilities / 1 Hz incidents" (constitution §4)
**Contradiction.** Real-world Hz doubles at 2× speed, which would make speed a balance lever.
**Resolution.** Read as *game-time* cadences: `EVERY_TICK` (15 game-seconds) and `EVERY_MINUTE` (1 game-minute), which equal 4 Hz and 1 Hz at 1×. Doc 01's reading is the only one under which speed controls do not alter balance. Test T-06 enforces it.
**Amend:** 00 §4 (clarifying clause). **Constitution amendment #2.**

### C-03 — Device-scoped settings live outside the save slot
**Contradiction.** Constitution §2 describes only `user://saves/slot0/`. Docs 08, 11, 12 and 13 all need graphics preset, notification prefs and accessibility settings to survive city deletion and checkpoint rollback.
**Resolution.** Add `user://settings.cfg` (device-scoped, never inside a save, never migrated by the save ladder) to constitution §2. Doc 11's `user://settings.cfg` naming wins over doc 08's `settings.json`.
**Amend:** 00 §2, 08 §2.5. **Constitution amendment #3.**

### C-04 — A fifth source layer (`platform/`)
**Contradiction.** Doc 08 §9 C-5 proposes a fifth top-level `platform/` directory for Kotlin/JNI/AlarmManager. Doc 13 puts the identical responsibilities in `game/android/` plus `android/plugins/slacum_native/`.
**Resolution.** **Doc 13 wins — no new source layer.** The Android shell is `game/android/*` (GDScript) plus a Kotlin AAR under `android/plugins/`, which is build-system territory, not a source layer. `sim/` reaches the platform only through injected `IClockSource` / `IFileSink` / `INotificationSink` interfaces implemented in `game/`. Constitution §3's four layers stand unchanged. Doc 08's C-5 is withdrawn.
**Amend:** 08 §4, §9.

### C-05 — Compression on top of JSON
**Contradiction.** Constitution §2 says "versioned JSON per save slot"; doc 08 writes zstd-compressed JSON.
**Resolution.** Compliant — the *format* is JSON, compression is transport, debug builds write a plain mirror. Recorded, no amendment. Add a one-line note to constitution §2 for the record. **Constitution amendment #4 (cosmetic).**

### C-06 — Utilities as coverage radii (constitution §8)
**Contradiction.** Doc 02 §2.4 ships `pressure_radius_tiles` (26–63) and `feeder_radius_tiles` (24–59) — coverage-percentage models that constitution §8 explicitly forbids for utilities.
**Resolution.** **Constitution wins.** Both columns are deleted from `data/buildings.json`. Doc 04's transformer `service_radius_tiles` (a physical attachment radius for a real graph node, not a coverage percentage) is legal and stays. Doc 05's pressure zones replace `pressure_radius_tiles` entirely.
**Amend:** 02 §2.4, §3.1, §8.

---

## 2. Currency, cost and revenue — the largest cluster

### C-07 — Three incompatible currency scales
**Contradiction.**

| item | doc 02 | doc 03 | doc 04 | doc 06 |
|---|---|---|---|---|
| house L1 build | $800 | $1,200 | — | — |
| store L1 build | $1,600 | $2,600 | — | — |
| apartment L1 | $6,000 | $7,000 | — | — |
| office L1 | $9,000 | $13,000 | — | — |
| data center L1 | $45,000 | $180,000 | — | — |
| substation L1 | $9,000 | $15,000 | **$120,000** | — |
| power plant L1 | $40,000 | $60,000 | **$180,000** | — |
| fire engine | — | $14,000 | — | **$190,000** |
| patrol car | — | $9,000 | — | **$45,000** |

Doc 04's grid ladder is 8–13× doc 03's; doc 06's fleet is 5–14× doc 03's; doc 02 is uniformly ~35% below doc 03.

**Resolution.** **Doc 03 is the sole currency authority.** It owns treasury magnitude, starting funds, and the only calibrated 12-session pacing model in the fleet; every other table is an uncalibrated guess (both docs 04 and 06 say so in their own §9). Therefore:
- `build_cost_l1` for all 12 archetypes = doc 03's column. Doc 02's cost column is deleted.
- All vehicle purchase/upkeep/dispatch costs = doc 03's `expenses.vehicles` block. Doc 06's cost columns are deleted; doc 06's *ratios* (engine ≈ 1.6× patrol after rescale) are preserved by doc 03 adjusting its own roster if it disagrees, not by doc 06 reintroducing numbers.
- Doc 04's `build_cost` per component is rescaled onto doc 03's ladder (substation L1 → $15,000, plant_gas L1 → $60,000, transformer/feeder/transmission scaled by the same factor and re-rounded).
**Amend:** 02 §2.3/§8, 04 §2.2/§8, 06 §2.11/§8. **Nothing costed may be implemented before this rescale lands.**

### C-08 — Two building upkeep models, double-billing risk
**Contradiction.** Doc 02 charges `upkeep_cents_per_hour = 0.05% of build cost/gh` on *every* building including civic and utility. Doc 03 charges `BUILDING_MAINT_RATE 0.00040 × capital_value` on **revenue buildings only**, plus separate `station_upkeep` per civic station and `E_grid`/`E_water` formulas for utilities — and explicitly states that billing civic buildings twice was "the original balance error".
**Resolution.** **Doc 03 owns all recurring expense.** Doc 02's `upkeep_cents_per_hour` column is deleted from `data/buildings.json`.
**Amend:** 02 §2.3, §3.1, §8.

### C-09 — Two tax formulas
**Contradiction.** Doc 02 §2.5: `tax = base × utilization × service_factor × condition_factor × state_factor × policy`, with `service_factor = (0.15+0.85P)(0.55+0.45W)(0.80+0.20S)`. Doc 03 §2.2: `R_b = base_tax × occ × f_power × f_water × f_road × f_stability × f_happiness × f_condition × policy × M_rev`, with class-specific floors. These produce different revenue for identical inputs and use different condition curves (`0.50+0.50·clamp((c−20)/80)` vs `0.55+0.45·C`).
**Resolution.** **Doc 03 owns revenue end to end.** Doc 02 §2.5's tax computation is deleted; doc 02 publishes only `population`, `jobs`, `condition`, `state`, and per-tick `power_demand_kw` / `water_demand`. Doc 02's `service_factor` survives *only* as the doc-06/doc-09 safety-coverage input `S` feeding doc 03's `f_stability` chain, renamed to avoid confusion.
**Amend:** 02 §2.5, §7 (tests 4–6), §8.

### C-10 — Two per-building tax tables
**Contradiction.** Doc 02: house L1 $9.00/gh, apartment L1 $42.00, store L1 $16.00, office L1 $60.00, growing on its own class curve to house L5 $52.00. Doc 03: house L1 $12, apartment $70, store $26, office $130, growing at `TAX_LEVEL_GROWTH = 2.15` to house L5 $256.
**Resolution.** Doc 03's `base_tax_by_level` is authoritative (generated from `build_cost_l1 × TAX_YIELD[class] × 2.15^(L−1)`). Doc 02's `Tax $/gh` column is deleted.
**Consequence (see C-11):** doc 09's starter-city anchor changes.
**Amend:** 02 §2.3, 03 §3.2.

### C-11 — The $686 starter anchor: root cause identified
**Contradiction.** Doc 03 requires the starter city to yield **$686/gh gross base tax ±5%** with a stated mix of 18 house / 5 store / 3 apartment / 1 office. Doc 09 computed that mix as **$428/gh** and therefore rebuilt the starter city as 28/8/6/1 to reach $692/gh.
**Root cause.** Doc 09 evaluated the mix against **doc 02's** tax rows. Against **doc 03's** rows the original mix is exact: `18×12 + 5×26 + 3×70 + 1×130 = 216 + 130 + 210 + 130 = $686/gh`. Doc 09's 28/8/6/1 mix against doc 03's rows is **$1,094/gh — 59% over target.**
**Resolution.** With C-10 ruled, doc 03's mix is correct and doc 09's rebuild is unnecessary. **Doc 09 reverts the starter manifest to 18 house / 5 store / 3 apartment / 1 office (L1) plus the six civic/utility buildings**, keeping its road template, block geometry, utility topology and tags. Starter population falls from 256 to 144 (18×4 + 3×24); jobs, power (508 kW building load) and water totals all re-derive.
**Amend:** 09 §2.9.3, §2.9.4, §8 `starter` block, tests 10/11/21/22; 03 §2.12 (no change to $686).

### C-12 — Starter city is insolvent as costed (~25× utility upkeep gap)
**Contradiction.** Doc 03 §2.12 budgets `plant O&M 10 + grid 16 + lines 6 = $32/gh` for the whole electrical plant, against total starter revenue $720/gh and net +$414/gh. Doc 04's per-component `upkeep_per_gh` prices the same starter set at plant $420 + substation $90 + 23 transformers $204 + ~110 line tiles ≈$120 = **~$834/gh**, which alone exceeds revenue.
**Resolution.** **Doc 03's expense *formula* is authoritative and doc 04's flat `upkeep_per_gh` column is deleted.** Doc 04 supplies the inventory (`rated_mva`, `line_km`, `plant_capacity_mw`, `condition`) and doc 03 computes `E_grid`. Sanity check on the starter set: `8 MW × $5.0 = $40` (plant O&M) + `~6 MVA × $4.0 = $24` (substation) + `~2.1 MVA × $4.0 = $8` (transformers) + `0.88 km × $0.9 = $1` (lines) ≈ **$73/gh** — 2.3× doc 03's assumed $32, not 25×.
**Forced recomputation:** doc 03 restates the starter expense line (306 → ~347 $/gh) and net (+414 → ~+373 $/gh), and re-runs the S1–S12 pacing table. Doc 04 does the same for `E_water` inputs.
**Amend:** 03 §2.12 (whole table), 04 §2.2/§8.

### C-13 — Doc 02's demand growth violates doc 03's hard requirement (Core Rule 3 collapse)
**Contradiction.** Doc 03 requires `DEMAND_LEVEL_GROWTH = 2.35 > TAX_LEVEL_GROWTH = 2.15` so every upgrade is ~9% less utility-efficient (spec §55 rule 3 / Pillar 5). Doc 02's actual `k_dem` is **1.70 (steady: house, store, construction_yard)**, **2.00 (standard: apartment, office, stations, substation, water_facility)**, **2.25 (vertical: high_rise, data_center, power_facility)**.
**Consequence as written:** for house, store, apartment and office — the four archetypes the player upgrades most — tax grows *faster* than demand (2.15 vs 1.70/2.00), so upgrading makes the city **more** utility-efficient per dollar of tax. The game's central "growth creates risk" rule is inverted for the majority of the roster. Even `vertical` at 2.25 gives only 4.7% per level, not 9%.
**Resolution.** **Doc 03 wins (it derives from a Core Rule).** Doc 02 sets `k_dem = 2.35` for `steady`, `2.45` for `standard`, `2.55` for `vertical` — every class strictly above 2.15, preserving the intended ordering that taller buildings degrade efficiency fastest. All 60 rows of `power_demand_kw` and `water_demand` regenerate. Doc 04's capacity ladders, doc 05's supply ladders and doc 09's starter night-peak all re-derive.
**Amend:** 02 §2.2/§2.3/§8; recompute 04 §2.13 worked examples, 05 §2.14, 09 §2.9.4/§2.9.5.
**This is the single most load-bearing balance correction in the report.**

### C-14 — `condition` is [0,100] in one doc and [0,1] in five
**Contradiction.** Doc 02 uses `condition ∈ [0,100]` with thresholds 85/60/35 and `decay_per_hour` in points. Docs 03 (`f_condition = 0.55+0.45·C`), 04 (`cond_mult = 1+3(1−condition)²`), 05, 06 (`fire_risk × (2 − condition)`) and 07 (`condition_factor = 1+1.5(1−condition)`) all use `[0,1]`. Doc 06 states the assumption explicitly in its §9.
**Resolution.** **`condition ∈ [0,1]` everywhere.** Doc 02 rescales: bands 0.85 / 0.60 / 0.35, `auto_damage_threshold 0.35`, `structural_failure_threshold 0.10`, `decay_per_hour` divided by 100, `min_condition_to_upgrade 0.55`, `condition_factor` reformulated on [0,1]. UI may display a percentage.
**Amend:** 02 §2.6/§2.11/§3.2/§8.

### C-15 — Two sub-dollar precision schemes
**Contradiction.** Doc 02 keeps a per-building `tax_accum_cents : int64`; doc 03 computes per-building revenue in float, sums city-wide, rounds once, and carries `revenue_carry_millidollars : int64`.
**Resolution.** Doc 03's scheme (single city-wide rounding per settlement) is the only one, following C-09. Doc 02's `tax_accum_cents` field is deleted from the save section.
**Amend:** 02 §2.5/§3.2/§7 (test 5).

### C-16 — Three repair-pricing models
**Contradiction.** Doc 03: `repair_cost = capital_value × damage_fraction × 0.85 × M_repair`. Doc 02: `repair_cost = build_cost(L) × 0.55 × (100−condition)/100`. Doc 04: `cost_frac_of_build` per failure type (burnout 0.35, rebuild 0.20, trip 0.005…). Doc 05: `base_cost[type] × (0.5 + severity)`. Doc 07 quotes repair totals ($42K / $310K) it does not own.
**Resolution.** **Doc 03 owns repair pricing.** Docs 02/04/05 supply a `damage_fraction ∈ [0,1]` per failure type (their existing `cost_frac_of_build` tables convert directly into damage fractions) and doc 03 multiplies by `capital_value`. Doc 07 consumes `economy.repair_cost(asset, damage_fraction)` and deletes its quoted totals pending recomputation.
**Amend:** 02 §2.6, 04 §8 `repair`, 05 §8 `repair`, 07 §2.7.8.

### C-17 — Difficulty knobs scattered across four docs
**Contradiction.** Doc 03 defines the economic multipliers and claims "no other doc defines its own economic difficulty scalar", yet doc 07 defines `repair_cost_mult` (economic, duplicating `M_repair`) alongside its pressure knobs; doc 06 defines `difficulty.escalation_mult`; doc 08 defines `difficulty_offline_mult`.
**Resolution.** One file, **`data/difficulty.json`, owned by doc 03**, containing every difficulty knob — economic (doc 03), pressure (doc 07: tp_rate, cooldown, severity, warning), escalation (doc 06), offline (doc 08). Owners still author their own rows; the file has one schema and one loader. Doc 07's `repair_cost_mult` is deleted (use `M_repair`).
**Amend:** 03 §8, 06 §8, 07 §8, 08 §8.

### C-18 — Doc 03's cheap-marsh-block beat is geometrically impossible
**Contradiction.** Doc 03 §2.12 session S5 scripts "buy cheap marsh block ($3,900)" from worked example E, which uses Chebyshev block distance `d = 5`. Doc 09's 7×7 world with a 3×3 core has `max d = 3`; the cheapest block on the board is **$6,700**.
**Resolution.** **Keep the 7×7 world** (it is sized for the vertical slice and for doc 11's chunk budgets). Doc 03 rewrites worked example E against a real block — `B_0_6` (A7), marsh, d=3, ERI 0.443 → $6,700 — and updates the S5 pacing row and the `test_land_price_example_e` expectation. Growing to 9×9 is a Phase 2 option, not an MVP change.
**Amend:** 03 §2.7 example E, §2.8 example F, §2.12 row S5, §7 test 10/11.

---

## 3. Time, cadence and offline

### C-19 — Offline cap: 8 h vs 12 h vs 72 h
**Contradiction.** Doc 01: `OFFLINE_CAP_REAL_MS = 8 real hours` (480 game-hours, 20 game-days). Doc 08: adopts 8 h "for consistency" but recommends 12 h. Doc 13: `offline_max_hours = 72` real hours (4,320 game-hours = **180 game-days**) and builds its whole slicing/ANR design around 4,320 coarse steps.
**Resolution.** **12 real hours (720 game-hours = 30 game-days).** Rationale: 8 h does not cover a full night plus a commute (the stated failure mode of a check-in game); 72 h hands back six months of city per absence, which breaks doc 03's offline/online income guardrail G4, doc 07's fairness budget, and doc 08's damage-cap arithmetic simultaneously. 12 h is doc 08's own recommendation and costs nothing under either performance model. Doc 01 owns the constant in `data/time.json`; docs 08 and 13 read it and define none of their own.
**Forced recomputation:** doc 08's `M(H) = 1.00·min(H,72) + 0.60·clamp(H−72, 0, **648**)`; at the cap `M(720) = 460.8 / 720 = ×0.64`. Doc 13's `offline_max_hours` deleted; its A-05 test expectation changes.
**Amend:** 01 §2.10/§8, 08 §2.2/§8/§7 test 17, 13 §2.3/§8/§7 A-05.

### C-20 — Two offline yield curves applied to the same revenue
**Contradiction.** Doc 03 tapers offline income with `yield_mult(h) = exp(−(h−4)/90)`, capping any absence at ~94 game-hours of income. Doc 08 tapers it with a two-band step (`1.00` for hours 0–71, `0.60` for 72+). Both are described as multiplying revenue. Implemented together they double-taper; implemented separately they disagree by ~4× at long absences.
**Resolution.** **One channel, one curve, split by concern.** Doc 08 owns the *mechanism* — `OfflinePolicy.band_for(hour_index)` on `TimeContext`, the only path by which any system learns it is offline. Doc 03 owns the *economic curve* — `band.yield_mult` is populated from doc 03's exponential taper, because doc 03 alone pacing-tested it (guardrail G4). Doc 08's flat 1.00/0.60 yield rows are deleted; its `incident_mult`, `damage_mult` and `director_allowed` rows stay. Doc 03 stops keeping its own `absence_hours_elapsed` counter and reads `ctx.catchup_index`.
**Amend:** 03 §2.11/§3.3, 08 §2.2/§8.

### C-21 — 45× disagreement on coarse-step cost
**Contradiction.** Doc 01 budgets **0.6 ms** per coarse step (480 hours ≈ 290 ms). Doc 08's per-entity accounting gives **~27 ms** on an 800-building reference city (480 hours ≈ 13.4 s). Both satisfy the 24-hour target; only the cap is at risk.
**Resolution.** **Settle by measurement, not argument.** Doc 08's decision rule is adopted verbatim and doc 01's 0.6 ms line is retired: build `tests/perf/test_coarse_step_cost.gd` in Phase 0 (task P0-27), measure one FULL-band coarse hour on the reference city, and set `max_coarse_hours = ceil(2000 / measured_ms)` rounded down to a multiple of 24 with a floor of 72, capped at the C-19 value of 720. Doc 08 owns the tunable.
**Amend:** 01 §2.12/§8, 08 §2.12 (make it normative rather than conditional).

### C-22 — Threaded vs sliced catch-up
**Contradiction.** Doc 08: catch-up above 24 hours runs on a `WorkerThreadPool` task. Doc 13: catch-up is sliced on the main thread at a 12 ms budget behind an animated veil.
**Resolution.** **Doc 13 wins — main-thread slicing only.** Sim state is single-owner `RefCounted` (constitution §3); threading it to save a load screen is an unforced determinism and lifecycle risk on a platform that can kill the process mid-task. Doc 08 deletes the threading branch and keeps `catchup_progress` events. Doc 01 exposes the sliced entry point `advance_coarse_sliced(max_ms) -> bool` plus `steps_done()` / `steps_total()`.
**Amend:** 01 §4, 08 §2.12/§8.

### C-23 — Notification look-ahead horizon is off by 60×
**Contradiction.** Doc 13 §2.4 projects notifications by running `plan_sim.advance_coarse_hours(1)` × `plan_horizon_hours = 24` and calls the result "24 real hours of look-ahead". At the locked 60× scale, 24 coarse **game**-hours = **24 real minutes**. Reaching a true 24 real-hour horizon needs 1,440 coarse steps — 39 s of work at doc 08's cost model, against an 80 ms pause budget. Separately, doc 08 §2.13 states the horizon as "48 game-hours", i.e. 48 real minutes.
**Resolution.** Split by predictability class:
- **(a) deterministic timers** (construction, upgrade, land development) and **(b) pre-rolled Director forecast events** need **no projection at all** — their fire times are already in the save — and are scheduled out to the full offline cap (12 real hours).
- **(c) emergent-event projection** is bounded by budget, not by wishful hours: `projection_steps = clamp(floor(projection_budget_ms / measured_coarse_ms), 12, 60)` — i.e. 12–60 game-minutes of real-world look-ahead. In MVP this class ships **disabled**; classes (a) and (b) carry every notification the slice needs.
**Amend:** 13 §2.4/§8/§7 A-16..A-19, 08 §2.13.

### C-24 — Doc 13 reimplements persistence
**Contradiction.** Doc 13 §2.2 writes `slot0/city.tmp → city.json` with a 3-deep `city.bak.N` rotation. Doc 08 owns immutable generation files, a `manifest.json` commit point, SHA-256 envelopes, zstd, a 6+2 retention ladder and a 7-check recovery gate.
**Resolution.** **Doc 08 owns persistence.** Doc 13's pause sequence step 3 becomes `SaveManager.request_save("pause")`; its `.bak` rotation, fallback logic and `saves_recovered_from_backup` counter are deleted (doc 08's quarantine + repair notes replace them). Doc 13 keeps the *budget* (≤250 ms pause) and the lifecycle ordering.
**Amend:** 13 §2.2/§2.11/§3.2/§7 A-23.

### C-25 — Inner section version key name
**Contradiction.** Docs 01, 02, 04, 09, 10 and 12 name the per-section version key `schema_version`, colliding with the envelope's. Doc 05 and doc 13 use `section_version`. Doc 08 mandates `section_version`.
**Resolution.** **`section_version`** inside every section; `schema_version` only on the envelope. One-word edit in six docs.
**Amend:** 01 §3.2, 02 §3.2, 04 §3.2, 09 §3.2, 10 §3.2, 12 §3.2.

### C-26 — Save section registry is incomplete
**Contradiction.** Doc 08's registry omits `roads` (doc 10), `render_prefs` (doc 11), `ui` (doc 12) and `android` (doc 13), and assigns `construction` to "Economy & Construction" and `districts` to a "Districts, Population & Stability" doc that does not exist.
**Resolution.** Registry per §11 of this report. `construction` → doc 02. `districts` + `population` + `progression` + `stats` → doc 09.
**Amend:** 08 §3.1.

### C-27 — Scheduled-event modifiers double-count weather
**Contradiction.** Doc 01's shipped `thunderstorm_hazard` event template pushes `traffic_density ×1.35`, `response_speed ×0.70`, `construction_rate ×0.35`, `incident_rate ×1.80` while the `impact` phase is open. Doc 07's `THUNDERSTORM` state simultaneously supplies `road_speed_mult 0.72→0.55`, `construction_speed_mult 0.45→0.25` and `incident_*_mult` for the same storm.
**Resolution.** **Doc 07 owns every storm effect multiplier.** Doc 01's template retains only the phase structure, timing and notification classes; its `modifiers` blocks become empty. The ScheduledEvent framework remains the carrier for the warning timeline.
**Amend:** 01 §2.8/§8.

### C-28 — Calendar: 21-day vs 30-day seasons
**Contradiction.** Doc 01 §2.2: `days_per_season = 30`, `seasons_per_year = 4` → 120-game-day year. Doc 07 §2.1: `season_length_days = 21` → 84-game-day year, and derives `season = floor((sim_day % 84)/21)` itself.
**Resolution.** **Doc 01 owns the calendar.** 30-day seasons, 120-day year. Doc 07 consumes `ctx.season_index` and `ctx.season_progress` and deletes its own derivation; its four-row season table re-indexes unchanged (the table is per-season, not per-day, so only the boundaries move). Seasons themselves are approved as a concept (doc 07 §9.1).
**Amend:** 07 §2.1/§8 `seasons`.

### C-29 — Construction rate channel omitted from authored durations
**Contradiction.** Doc 01's `construction_rate` channel has a 24-hour mean of **0.804** (night floor 0.60) and doc 01 §5 requires durations to be authored against it. Doc 02 §2.10's `progress` formula multiplies only `crew_power × weather_build_mult × road_access_mult`, and doc 09's tutorial-block worked example (97.6 gh for 60 crew-hours) omits the channel entirely.
**Resolution.** Every work unit multiplies `ctx.channels.construction_rate` (doc 01 §2.7's exact integer accumulator already does this; docs 02/09/10 must call it). Doc 09's tutorial block becomes `97.6 / 0.804 ≈ 121 gh` of wall time; `first_block_time_mult` is retuned from 0.60 to **0.48** to preserve the intended "one session plus one offline gap" completion (58.6 gh).
**Amend:** 02 §2.10, 09 §2.3/§8/§7 test 16, 10 §2.3.

---

## 4. Power, water and their consumers

### C-30 — Electrical capacity ladders 20× apart
**Contradiction.** Doc 02 `substation.power_throughput_kw = [300, 600, 1200, 2400, 4800]`, `power_facility.power_supply_kw = [400, 900, 2020, 4560, 10250]`, footprint 2×2/3×3. Doc 04 `substation.capacity_kw = [6000, 14000, 30000, 60000, 110000]`, `plant_gas = [8000, 18000, 36000, 70000, 120000]`, footprint `[2,2,3,3,3]` / `[3,3,3,4,4]`, plus a `transformer` tier doc 02 does not model at all.
**Resolution.** **Doc 04 owns every electrical capacity and topology number** (it is the only doc with a load-flow, thermal and protection model calibrated against them, and doc 02 concedes the point in its own §9). Doc 02 deletes `power_supply_kw`, `power_throughput_kw` and `feeder_radius_tiles`. Doc 02 retains the **building shell** — footprint, build time, jobs, condition/decay, fire, crime, coverage requirements, state machine — and doc 04's `footprint` column is deleted in favour of doc 02's. Doc 04's `transformer` is a grid component, not a building, and is never placed through `place_building`.
**Amend:** 02 §2.4/§3.1/§8, 04 §2.2/§8.

### C-31 — Two `base_kw` tables
**Contradiction.** Doc 04 §2.3 publishes a reference `base_kw` table "owned by doc 03" that disagrees with doc 02's `Pwr kW` column at every row: house L1 5 vs 3, apartment L1 45 vs 22, office L1 90 vs 35, data_center L1 900 vs 400.
**Resolution.** **Doc 02 owns `base_kw`** (it is a building property that must scale with level on doc 02's curve family — see C-13). Doc 04's reference table is deleted; its worked examples WE-1/WE-2 and tests 1, 2 and 15 are recomputed against doc 02's post-C-13 column. Formulas hold, numbers move.
**Amend:** 04 §2.3/§2.13/§7.

### C-32 — Two time-of-day demand curve stores
**Contradiction.** Doc 01 publishes normalized `power_demand_residential/commercial/industrial` channels (24-hour mean 1.000) in `data/time.json`. Doc 04 publishes `demand.tod_curves` for five classes (RES/COM/IND/CIV/DC) in `data/power.json`, **not** normalized — its RES curve has a 24-hour mean of ≈0.83.
**Resolution.** **`data/time.json` is the only diurnal curve store.** Doc 04 consumes `ctx.channels.power_demand_*`; doc 01 adds two channels to close the gap: `power_demand_civic` (mapped from doc 04's CIV shape, normalized) and `power_demand_datacenter` (flat 1.0). Doc 04's `tod_curves` block is deleted.
**Numeric consequence:** normalizing raises mean RES demand by ~20%, so doc 04's capacity examples, doc 09's night-peak (831 kW pre-C-11) and the generation ladder all re-derive.
**Amend:** 01 §2.6/§8, 04 §2.3/§8.

### C-33 — Two water diurnal curve stores
**Contradiction.** Doc 01 publishes a `water_demand` channel (mean 0.997). Doc 05 §8 ships `residential_hourly` and `commercial_hourly` (each summing to 24.0).
**Resolution.** Same rule as C-32. Doc 01 renames its channel `water_demand_residential` and adds `water_demand_commercial` populated from doc 05's curve; doc 05 deletes both arrays and keeps only the per-archetype `process_demand` split (which is not a curve).
**Amend:** 01 §2.6/§8, 05 §2.4/§8.

### C-34 — Water scale: 47× disagreement on residents per facility
**Contradiction.** Doc 02's `Water WU/gh` column implies **0.125 units per resident per hour** (house L1: pop 4, 0.5 WU) → one L1 water facility (40 WU/gh) serves **320 people**. Doc 05 uses **0.020 m³/h per resident** → its L1 pump (300 m³/h) serves **15,000 people**.
**Resolution.** **Adopt doc 05 §2.13's arbitration verbatim.** `1 WU ≡ 1 m³/h`. Doc 02 divides its water column by **6.25** (house L1 0.5 → 0.08 = exactly 4 × 0.020). Doc 05 multiplies every flow/capacity/volume constant by **`WU_SCALE = 0.1333`** and adopts doc 02's kW column. Result: ~2,000 residents per L1 facility, and the two independently authored component tables agree within 20%. Doc 05's own `test_scale_invariance` proves the rescale is safe.
**Forced recomputation:** doc 09's starter water demand (51.1 WU/gh → 8.2 after C-11's smaller mix and this rescale), `WTR-2` tank autonomy, hydrant flows, `fire_flow_per_engine` (60 → 8.0).
**Amend:** 02 §2.3/§8, 05 §2.13/§8 (apply the rescale rather than describing it), 09 §2.9.4/§2.9.6.

### C-35 — One `water_facility` archetype must cover five node kinds
**Contradiction.** Doc 02 ships a single `water_facility` with a flat 60 kW draw at L1. Doc 05 needs `source`, `treatment`, `pump_station`, `tank` and `booster` as distinct nodes with different power (a gravity tank draws ~5 kW, not 60) and different capacity semantics. Doc 09's starter city already models `WTR-1` and `WTR-2` as two `water_facility` buildings carrying different doc-05 `kinds`.
**Resolution.** Add a **`variant`** field to `water_facility` (`source | treatment | pump | tank | booster`) with per-variant `base_kw`, footprint and capacity. Doc 02 owns the shell and the variant list; **doc 05 owns the per-variant numbers**. `place_building{type:"water_facility", variant:"tank"}` is the placement command. Core Rule 5 (five levels per archetype) is satisfied per variant.
**Amend:** 02 §2.1/§2.4/§3.1, 05 §2.1/§8, 12 §2.7 (build card list).

### C-36 — Pump backup coverage: three docs, one number
**Contradiction.** Doc 04 hard-codes `coverage_frac["water_pump_station"] = 1.00` and says doc 05 owns `base_kw`; doc 02 already publishes a kW column for `water_facility`; doc 05 wants `coverage_frac = backup_kw / kw_required` (0.60 at L2 rising to 1.00 at L5) and asks who owns generator fuel.
**Resolution.** Doc 02 owns `base_kw` per variant (C-35). **Doc 05 owns `coverage_frac`** per node and publishes it to doc 04. **Doc 04 owns generator fuel and refuelling for all backup-capable sinks** (one fuel model, one owner); doc 05's `backup_generator` fuel fields become doc 04's input table.
**Amend:** 04 §2.10/§8 `backup`, 05 §2.6/§8.

### C-37 — Doc 03 needs a time-weighted power fraction doc 04 does not produce
**Contradiction.** Doc 03's `f_power` requires `power_availability_hour(building_id) ∈ [0,1]` — the fraction of the settled hour the building had power. Doc 04 produces `is_powered()` (boolean, with LIT/DARK hysteresis) and `power_output_multiplier()` (1.0 / coverage_frac / 0.0), neither of which integrates over an hour. A boolean erases roughly two-thirds of the cascade signal in doc 03's worked example B.
**Resolution.** Doc 04 accumulates `served_kwh / demanded_kwh` per building per settled hour and exposes `power_availability_hour()`. Doc 05 adds the equivalent `water_service_factor_hour()`.
**Amend:** 04 §5.2, 05 §5.4.

### C-38 — `district_dark` is per land block, but "district" means 1–4 blocks
**Contradiction.** Doc 04 flags `district_dark` on a **land block** (≥60% of buildings dark, pop+jobs weighted). Doc 09 defines a district as **1–4 orthogonally contiguous blocks**. Doc 11 renders per chunk (= per block) and doc 07 reads `customers_out_pct` city-wide.
**Resolution.** Rename doc 04's flag **`block_dark`** (block granularity is correct — it is the render chunk). Doc 09 derives `district_dark` as the population-weighted aggregate over member blocks. Doc 11 keeps consuming the block-level event unchanged.
**Amend:** 04 §2.4/§4/§5.8, 09 §2.6, 11 §5 (name only).

### C-39 — Renderer cannot sweep the relight
**Contradiction.** Doc 11 §2.7.3's signature relight sweep needs the position or ordering of restoration; doc 04's `DistrictDarkChanged` carries no positional payload. Doc 11 calls this its highest-risk unresolved dependency.
**Resolution.** Doc 04 adds **`restore_order: PackedInt32Array`** to the restoration event — it falls out of doc 04's existing energization DFS for free and is strictly better than a `source_pos` because it follows real restoration priority. Doc 04 additionally carries `powered_fraction: float` from day one even while the model is binary (doc 11 §9.13), so load-shed tiers do not force a later schema change.
**Amend:** 04 §4 events, 11 §2.7.3 (consume ordering rather than distance where available).

### C-40 — Momentary-outage constant is derived, not chosen
**Contradiction.** Doc 11's `momentary_outage_s = 2.50` is derived from doc 04's 90-game-second auto-reclose (1.5 real seconds) and would become wrong if doc 04 retunes the reclose interval.
**Resolution.** Not a conflict — a dependency. Record it: `momentary_outage_s ≥ 1.5 × (auto_reclose_delay_gs / 60) × auto_reclose_max_attempts`, asserted by a headless test that reads both files.
**Amend:** 11 §7 (add the assertion), 04 §8 (comment the coupling).

### C-41 — Player-drawn vs auto-routed utility lines
**Contradiction.** Doc 12's onboarding steps 3–4 ("connect/confirm power", "connect/confirm water") and its drag-path placement UX require the player to draw feeders and mains tile by tile. Doc 04's open question 9 recommends auto-routing along roads. Doc 05 exposes `place_main` (player-drawn).
**Resolution.** **Player-drawn, with an auto-route assist.** Drag-path placement is the primary interaction (it is what makes spec §41 steps 3–4 meaningful and what makes undergrounding and wind exposure real decisions); a "route along roads" button fills the path automatically and the player still confirms. Doc 04's open question 9 is closed.
**Amend:** 04 §9 (record the ruling), 12 §2.7 (no change needed).

---

## 5. Incidents, fire, crime and crews

### C-42 — Fire ignition probability is doubly weighted
**Contradiction.** Doc 02 owns `fire_ignition_per_hour` per archetype **per level** (house L1 0.00015 → L5 0.00040; high_rise 1.7× house). Doc 06 owns `base_fire_risk_by_archetype × (1 + 0.15(level−1)) × (2 − condition)` — and its per-archetype ordering **inverts** doc 02's (doc 06 rates `high_rise` 0.80, *below* `house` at 1.00). Multiplied together, ignition is weighted twice with contradictory shapes.
**Resolution.** **Doc 02 owns the per-archetype-per-level base rate** (it must scale with level and is a building property). Doc 06 deletes `base_fire_risk_by_archetype` and `level_risk_slope`, keeping only situational multipliers (`f_power`, `f_weather`, `f_arson`) and re-calibrating its global `R_fire_base` so the citywide rate lands on its stated target (≈0.76 fires/game-day at 300 buildings).
**Amend:** 06 §2.6(b)/§8, 02 §2.7 (unchanged, but now normative).

### C-43 — Two fire consequence models
**Contradiction.** Doc 02: `burn_hours(L) = 3.0 × 1.15^(L−1)`, `condition_loss_per_hour = (100/burn_hours)(1 − suppression/fire_load)`, `required_fire_units = clamp(1+floor(fire_load/120),1,6)`, `spread_radius_tiles`. Doc 06: continuous severity, `required_rate = S_req_base[archetype](1+0.35(L−1))·stage_mult[tier]`, hazard-rate spread over a 40 m radius, `FIRE_BURN_DOWN_H = 0.50 gh` at tier 5, `damage_fraction = 0.10(tier_peak−1) + 0.30·burn_timer`. These are two complete, incompatible fire simulations.
**Resolution.** **Doc 06 owns fire dynamics** (severity, tier, required_rate, spread, burn-down, residual damage) — it is the incident system and its model is integrated with dispatch, water pressure and the sub-step integrator. Doc 02 deletes `burn_hours`, `condition_loss_per_hour`, `required_fire_units` and `spread_radius_tiles`. Doc 02's **`fire_load`** survives as the consequence index, and doc 06 **must derive `S_req_base` from it** (`S_req_base = 0.50 × (fire_load / 20)^0.45`, calibrated so house L1 = 0.50 and high_rise L5 = 3.06 — *the original "≈ 3.6" gloss here was arithmetically wrong; the formula is canonical and doc 06's 3.060 is correct — Round 2 ruling RR-9*) rather than hand-authoring per-archetype constants — otherwise doc 02's deliberate "L5 high-rise carries 56× the fire load of an L1 house" (spec §17) does not reach the dispatch math. Doc 02's `on_fire` state is entered and left only on doc 06's events.
**Amend:** 02 §2.7/§2.12/§8/§7 test 18, 06 §2.8/§8.

### C-44 — Crime target selection is unowned at building granularity
**Contradiction.** Doc 02 publishes `crime_weight` per archetype/level plus its own multiplier stack (`no_police 1.2`, `night 0.8`, `outage 1.5`) — which duplicates doc 06's `f_police`, `f_dark` and `f_stab`. Doc 06's crime generator has district granularity only and no way to place the incident.
**Resolution.** Doc 06 owns generation (district λ) **and** adopts doc 02's `crime_weight` as the within-district weighted pick for the incident's position. Doc 02 deletes its multiplier stack (§2.8's three coefficients); the weight column stays.
**Amend:** 02 §2.8/§8 `crime`, 06 §2.6(a).

### C-45 — Crime does not use the `crime` RNG stream
**Contradiction.** Constitution §5 names seven streams including `crime`. Doc 06 draws crime generation from `rng_incidents`; nothing uses `crime`. Doc 10 uses nothing and notes `traffic` is unconsumed.
**Resolution.** Doc 06 draws crime generation and crime target selection from the **`crime`** stream. `traffic` is **reserved, not deleted** (doc 10 §9.3 C-2 accepted) — cosmetic traffic uses a render-local RNG in `game/`, which is legal since constitution §5 governs `sim/` only.
**Amend:** 06 §2.6(a)/§4.

### C-46 — Water main breaks: two hazard drivers, two pressure penalties
**Contradiction.** Doc 06 owns the `water_main_break` roll driven by **over-pressure** (`f_press = 1 + 1.5·max(0, pressure_ratio − 1.05)`). Doc 05's model is driven by **condition, utilization and freeze stress**. Doc 06's tiered `zone_pressure_delta` (−0.15/−0.35/−0.60/−0.80) conflicts with doc 05's `break_pressure_penalty = 0.12 × severity`.
**Resolution.** Doc 06 owns the roll and **multiplies** doc 05's `cond_mult`, `load_mult` and freeze terms into its rate rather than replacing them (over-pressure alone cannot produce breaks in a well-run system, which is wrong). Doc 06's tiered `zone_pressure_delta` wins; doc 05's flat constant becomes the fallback only for breaks doc 06 does not own (none in MVP).
**Amend:** 06 §2.6(d), 05 §2.8/§2.9.

### C-47 — Offline burn-down destroys what offline may not destroy
**Contradiction.** Doc 06's `on_fail` action list calls `destroy_building`. Doc 08 fairness rule 4 forbids any destruction offline and clamps the outcome to condition 0.15 with the incident left open.
**Resolution.** Doc 08's clamp stands (it is the better drama — the player arrives to a building still burning) **and** doc 06 adds an explicit `world.destroy_allowed()` guard in the `destroy_building` cascade op, so the verb is refused visibly rather than silently swallowed by `OfflineGuard`.
**Amend:** 06 §3.1 (op vocabulary), 08 §5.

### C-48 — Road condition has no safety consequence
**Contradiction.** Doc 10 owns `condition_hazard_mult(e) = 1 + 0.004·max(0, 75 − condition)` and states doc 06 must fold it into `traffic_accident` generation. Doc 06's formula does not include it.
**Resolution.** Doc 06 multiplies `condition_hazard_mult` into its `traffic_accident` rate. Without it, road maintenance is a pure travel-time tax and the maintenance decision loses half its weight.
**Amend:** 06 §2.6(e)/§8.

### C-49 — `RouteProfile` double-counts weather and flood
**Contradiction.** Doc 06's `RouteProfile` carries `weather_mult` and `flood_mult`; doc 10 already applies both via `wx_resist` per route class and the flood closure table.
**Resolution.** Doc 06 drops both fields. Genuine per-vehicle exceptions (a future high-clearance flood truck) become a named capability, not a raw multiplier.
**Amend:** 06 §2.10, 10 §4 (no change).

### C-50 — Station capacity ladders disagree
**Contradiction.** Doc 02 `police_station.unit_slots = [2,3,5,7,10]`, `fire_station.unit_slots = [1,2,3,4,6]`, `construction_yard.crew_slots = [1,2,3,4,6]`. Doc 06 `capacity_per_station_level = [2,3,4,5,6]` for patrol and `[1,2,3,4,5]` for engine, water truck, utility truck and construction crew.
**Resolution.** **Doc 06 owns unit capacity** (units are its entities, and its fleet sizing calibrates the incident load damper and the Director's fleet-strength score). Doc 02 deletes `unit_slots` and `crew_slots`. Doc 06's `[1,2,3,4,5]` / `[2,3,4,5,6]` stand.
**Amend:** 02 §2.4/§8, 06 (no change).

### C-51 — Coverage falloff formula ownership
**Contradiction.** Doc 02 defines `c_station` radial falloff, station radii and the requirement ladder; doc 06 consumes `police_coverage` / `coverage_fire` as 0–1 scalars; doc 02 proposes doc 06 implement the formula.
**Resolution.** **Doc 02 implements it** — it owns the radii, the staffing term and the requirement ladder, and doc 06 only needs the scalar. `sim/buildings/coverage.gd` publishes `coverage_police(pos)` / `coverage_fire(pos)`; doc 06 reads them. One implementation, in the doc that owns the inputs.
**Amend:** 02 §9 (item 8 resolved), 06 §5.

### C-52 — Unpowered stations have no effect (spec Pillar 1 tension)
**Contradiction.** Spec §4 Pillar 1 implies a blacked-out fire station should be degraded; doc 06 explicitly ships no effect in MVP to avoid a death spiral during the storm that caused the outage.
**Resolution.** **Doc 06's MVP call is upheld** — accepted, deliberate, recorded. Post-MVP: `turnout_min ×2` while the station is dark, never a hard stop. Flagged in doc 99's risk register rather than fixed.
**Amend:** 06 §6 (state it as a ruled decision, not an open question).

---

## 6. Weather, Director and disaster ownership

### C-53 — Three systems roll line failures
**Contradiction.** Doc 04 rolls wind damage per overhead line per game-hour (`h_wind = 4.0e-6 · len · (w_mps − 18)^2.4 · veg · ice`). Doc 07 rolls wind damage per exposed span every 5 game-minutes (`p = 0.020 · ((wind_kph − 45)/100)² · (2 − condition) · span_factor`) and proposes a `storm_owns_line_failures` flag to suppress doc 04's. Doc 06 has a third: the `storm_damage` generator (`R_storm_base 0.020 · wind_factor · exposure_class · (2 − condition)`).
**Resolution.** **Doc 06 owns all incident generation, including storm damage.** Doc 04's `h_wind` and doc 07's §2.7.4 wind rolls are both deleted as generators; doc 07 supplies `wind_kph` and the storm cell mask, doc 04 supplies per-component `weather_exposure` / `tree_adjacent` / `condition` / `underground`, and doc 06's `storm_damage` generator consumes both. The `storm_owns_line_failures` flag becomes unnecessary and is deleted. Doc 06 re-calibrates `R_storm_base` against doc 07's stated outcome targets (≈2.5 failures for a maintained 60-span grid, ≈12 for a neglected one).
**Amend:** 04 §2.7.4/§8, 07 §2.2/§2.7.4/§8, 06 §2.6(f)/§8.

### C-54 — Two lightning targeting models
**Contradiction.** Doc 04 §2.7.3: collect components within 7.5 tiles, weights substation 8.0 / plant 6.0 / transmission 5.0 / overhead feeder 3.0 / transformer 2.0 / underground 0.0, `p_damage = 0.55 × (1 − 0.22·arrester)`. Doc 07 §2.7.3: storm-cell-scoped weighted pick across a superset including buildings, weights transmission 3.0 / substation 2.5 / transformer 1.8 / high-rise 2.2 / data center 1.4, with height, condition, exposure, protection and immunity factors, then its own damage bands.
**Resolution.** **Split by concern.** Doc 07 owns **strike generation and target selection** — only it can see buildings, the storm cell, and F4 target immunity — and emits `LightningStrike{target_ref, energy}`. Doc 04 owns **damage resolution for grid components** (its failure-type table and repair jobs); doc 02/06 own damage resolution for buildings. Doc 04's target-weight table and radius selection are deleted; doc 07's per-target damage bands are deleted in favour of doc 04's `ds` bands, which doc 07 references rather than restates.
**Amend:** 04 §2.7.3/§8 `weather.lightning`, 07 §2.7.3.

### C-55 — Offline Director allowance: three different caps
**Contradiction.** Doc 01 recommends ≤1 Director-scheduled major hazard per catch-up session. Doc 07 F8 allows 1 major per 12 real hours of absence with `severity_mult ×0.75`. Doc 08 rule 1 allows at most 1 hazard, which must be **Tier 1**, must be **pre-warned before backgrounding**, must be in the FULL band, and is **zero on casual**.
**Resolution.** **Doc 08's invariants are the outer clamp** — they are normative anti-frustration rules and they are strictly the tightest. Doc 07's F8 is tightened to match verbatim; doc 01's recommendation becomes a reference to doc 08.
**Amend:** 07 §2.6.4 F8/§8 `fairness.offline`, 01 §2.10.

### C-56 — City stability: range and owner
**Contradiction.** Doc 09 owns `stability ∈ [0,1]` per district. Doc 06 assumes `[0,1]`. Doc 03 uses `S ∈ [0,100]` in `f_stability = 0.25 + 0.75(S/100)^0.70`. Doc 07 reads and *writes* a city-level `city_stability ∈ [0,1]` that nobody defines.
**Resolution.** **`stability ∈ [0,1]`, owned by doc 09.** Doc 03 converts (`f_stability = 0.25 + 0.75·S^0.70` with S already in [0,1]). `city_stability` = population-weighted mean of district stability, computed and published by doc 09. Doc 07 writes stability deltas through `districts.apply_stability(id, d)`, never to a city scalar directly.
**Amend:** 03 §2.2/§8, 07 §2.6.1/§5, 09 §2.6 (add the city aggregate).

### C-57 — Doc 02's weather constants supersede nothing
**Contradiction.** Doc 02 authors inline `weather_load_mult`, `weather_water_mult`, `weather_decay_mult`, `weather_fire_mult`, `weather_build_mult` with its own values (storm decay 1.6, thunderstorm fire 2.5, thunderstorm build 0.55) and flags them as doc 07's. Doc 07 adopts the names and maps them onto intensity-lerped channels, disagreeing on one: thunderstorm construction speed 0.55 (doc 02) vs 0.45→0.25 (doc 07).
**Resolution.** **Doc 07's `get_effect()` is authoritative for all five.** Doc 02's inline constants are deleted (not merely overridden), so nobody implements the placeholder. Doc 07's harsher construction figure stands — a thunderstorm should stop a crane.
**Amend:** 02 §2.6/§2.7/§2.10/§8, 07 §9.12 (resolved).

### C-58 — Continuous `precip` for the renderer
**Contradiction.** Doc 11 requires `precip ∈ [0,1]` as a continuous ramp for `amount_ratio` and the wetness integrator; doc 07 publishes `precip_mm_h ∈ [0,35]` per state.
**Resolution.** Doc 07 additionally publishes `precip01 = clamp(precip_mm_h / 35.0, 0, 1)`, continuous across segment boundaries by lerping the last 60 game-seconds of a segment into the next.
**Amend:** 07 §2.2/§4, 11 §5 (consume `precip01`).

### C-59 — Weather is global, rendered globally, but modelled with a moving cell
**Contradiction.** Doc 10 asks whether weather is global or per-tile; doc 11 renders one global state from the camera-focus region and notes two visible regions would pop.
**Resolution.** **Weather state is city-wide global; only the `THUNDERSTORM` storm cell is spatial**, and it affects lightning targeting and flood accumulation, not the global effect channels. Roads samples the global state; the renderer renders the global state. No boundary popping exists in MVP because there is no second region. Doc 10's X-4 and doc 11's §9.12 are closed.
**Amend:** 07 §2.3 (state it explicitly), 10 §9.2 X-4 (closed), 11 §9.12 (closed).

---

## 7. Roads, camera and rendering

### C-60 — Two road-class taxonomies and two block road templates
**Contradiction.** Doc 09 stamps `arterial` (block boundary, 1 tile per side) + `collector` (block-local index 7) + `local`, giving **87 road tiles per block / 783 in the core / 169 buildable tiles**, and the 0.34 road-area constant that all its price and placement math depends on. Doc 10 defines `STREET` / `AVENUE` (`alley` reserved) and specifies a default block grid on local lines `{0, 8}` = **60 tiles per block at $108,000**.
**Resolution.** **Doc 09 owns the map template; doc 10 owns the class semantics.** The template is doc 09's (boundary + index-7 collector, 87 tiles/block). The mapping is: boundary arterials → `AVENUE`, interior collectors and player-placed roads → `STREET`. Doc 10 deletes its `{0,8}` template and re-derives the block road-install cost from its own per-tile prices against 87 tiles.
**Amend:** 10 §2.3/§8 `build`, 09 §2.9.1 (name the classes).

### C-61 — `road_access` is defined three times
**Contradiction.** Doc 02 uses `road_access_mult` (1.00 within 1 tile, 0.85 within 2) and `E_ROAD` at max 2 tiles; doc 03 uses `road_access_factor` as `a_b` in land value; doc 06 uses `access_quality < 0.6` as a degraded-response penalty; doc 09 uses a per-block `road_access_score {NONE 0, STUB 0.35, EDGE 0.70, ARTERIAL 1.00}`.
**Resolution.** **Doc 10's `access_quality(pos) ∈ [0,1]` is the single definition** for tile-level access (docs 02, 03, 06 all consume it; doc 02's constants are sourced from doc 10's `w_dist` bands). Doc 09's per-block `road_access_score` is a *different quantity* — a block-level development attribute feeding land price — and is renamed `block_road_access_score` to prevent conflation.
**Amend:** 02 §2.11, 03 §2.2, 09 §2.6/§8.

### C-62 — The L4/L5 avenue gate is proposed but unowned
**Contradiction.** Doc 10 introduces "a building may only reach Level 4–5 with an AVENUE within 4 tiles of its access tile" and notes doc 02 owns upgrade preconditions and may prefer a soft modifier.
**Resolution.** **Accepted as a hard gate.** It gives avenues a strategic purpose beyond travel time and is the cleanest reading of spec §9.4's "road access" precondition. Doc 02 adds check **#13 `E_AVENUE`** to §2.11 and a `RequirementFormatter` string in doc 12. Note the starter city has boundary arterials on every block (C-60), so the gate never blocks the tutorial.
**Amend:** 02 §2.11/§8, 12 §2.7 (failure-code enum grows to 13).

### C-63 — Two camera specifications
**Contradiction.** Doc 12 §2.16: `FOV 45°`, `dist 18–420 m`, `pitch 34°→62°`, near 1 / far 2000. Doc 11 §2.5: `FOV 40°`, `dist 60–560 m`, `pitch 40°→62°`, near 1 / far 1600. The two docs already agreed the *ownership* split (12 owns state and input, 11 owns node, projection, culling and LOD) but not the numbers.
**Resolution.** **The interaction ranges are doc 12's** (`D_MIN 18`, `D_MAX 420`, `pitch 34→62`) — they were derived against thumb reach, city diagonal and the "one intersection fills the screen" read. **The projection constants are doc 11's** (`FOV 40°`, near 1, far 1600) — the draw-call budget is computed against them. Both live in **one place: `data/render.json`**, and `data/ui.json` references them rather than restating them.
**Forced recomputation (real):** at `D = 420, pitch 62°` the camera is 371 m up and the nearest visible ground is ~200–300 m from the camera — i.e. **MEDIUM tier, not FAR**. Doc 11's headline claim that "the entire city is FAR at max zoom" and its Z2 draw-call figure of 143 are wrong at a 420 m ceiling. Doc 11 must re-derive §2.13's frustum worked example and Z2 budget, and either raise `medium_max_m` or accept ~10 draw calls per chunk at max zoom.
**Amend:** 11 §2.5/§2.13/§8, 12 §2.16/§8 (reference, do not restate).

### C-64 — Overlay state count: 4 or 5?
**Contradiction.** Doc 11 packs `overlay_state` into 2 bits (4 states) of the per-instance custom data with the packing constant 112. Doc 12 §2.5 lists five states: NORMAL, WARNING, CRITICAL, OFFLINE **and SELECTED**.
**Resolution.** **Four building overlay states.** `SELECTED` is a UI-layer outline/ring drawn by `MarkerLayer`, never a per-instance building state — a selection is transient and single-valued, so it belongs to the UI, not the instance buffer. The 2-bit packing and constant 112 stand.
**Amend:** 12 §2.5 (state that SELECTED is not an `overlay_state`).

### C-65 — Speed options: {1,2,3} or {1,2,4}?
**Contradiction.** Doc 12 §2.11 and its tunables correctly use `{1,2,3}` per doc 01, but accessibility gate **A10** says "pause + 1×/2×/4× always reachable in ≤2 taps".
**Resolution.** `{1, 2, 3}`. Internal inconsistency in doc 12; A10 is corrected. Spec §49's "pause/slow-speed controls" is satisfied by explicit pause with 1× as the floor — recorded as a deliberate reading, with no sub-1× slow motion in MVP.
**Amend:** 12 §2.18 A10.

### C-66 — Renderer needs a diurnal occupancy curve the sim does not have
**Contradiction.** Doc 11's emissive target uses `occ = occupancy(archetype, hour)`; doc 02 defines only a slow structural `occ_b` with a 36-game-hour ramp. Without a diurnal shape, every powered building sits at a flat 0.775 emissive and "the city breathes" dies.
**Resolution.** **The curve is art, not simulation** — it must not become a sim input. Doc 11 owns `occupancy_hour_curve` per building *family* in `data/render.json` and multiplies it by doc 02's structural `occ_b`. No new sim data, no new save state.
**Amend:** 11 §2.7.1/§8, 02 (no change).

### C-67 — Vehicle interpolation needs velocity
**Contradiction.** Doc 11's Hermite interpolation needs `speed` and `heading` as explicit fields; doc 06's `vehicle_state` does not list them.
**Resolution.** Doc 06 adds `speed: float` and `heading: float` to `vehicle_state`. Deriving them from consecutive 4 Hz positions doubles visible latency.
**Amend:** 06 §4, 11 §5.

### C-68 — Renderer must not replay 30 days of relights
**Contradiction.** After offline catch-up, doc 11 would receive the accumulated event stream and play a 3.15 s relight sweep for every district that changed while the app was closed.
**Resolution.** Doc 08 flags the first post-catch-up snapshot `is_resync: true`; doc 11 snaps emissive state instead of animating. Already agreed by both docs — recorded as binding.
**Amend:** 08 §4 (add the flag to the contract), 11 §5 (no change).

### C-69 — `content_scale_mode = disabled`
**Contradiction.** Doc 12 needs dp-exact UI (`content_scale_mode = disabled` + dpi-derived `content_scale_factor`) for the 48 dp accessibility gate; doc 11's `render_scale` assumes it controls the 3D viewport.
**Resolution.** **Agreed as doc 11 already proposed:** 3D renders into a `SubViewport` sized `viewport_px × render_scale`, composited under the UI `CanvasLayer`. This is how `render_scale` must be implemented regardless. No conflict remains; recorded.
**Amend:** none (both docs already state the agreement).

### C-70 — Mature-city response times vs starter-city band
**Contradiction.** Doc 06 quotes 4–14 game-minute responses; doc 10 computes 24.2 gm clear / 39.1 gm in a storm-plus-blackout for an 880 m mature-city run.
**Resolution.** **Not a contradiction — both are true at different city sizes** (the starter city is 384 m across). But it must be *confirmed*, because doc 06's escalation timers are calibrated against the short band. Check: an unattended house fire reaches tier 2 at 21.8 gm and tier 3 at 39.3 gm, so a 24 gm mature-city response arrives at tier 2 — playable. **Ruling: `speed_mpgm` as a game-time constant is approved** (constitution imposes no physical-speed requirement); doc 06 adds the mature-city case to its §1.1 pacing table so the numbers are not rediscovered later.
**Amend:** 06 §1.1/§9(1) (approved), 10 §9.4 Q1 (closed).

---

## 8. Notifications — three docs, one file

### C-71 — `data/notifications.json` is claimed by docs 08, 12 and 13 with three schemas
**Contradiction.** Doc 08 owns it with four classes (P1–P4), token buckets (global 8/day), quiet hours and an 18-event table. Doc 12 lists it under "data files owned by this doc" with three classes (p1–p3) and different capacities. Doc 13 owns three Android channels with its own rate limiter (`max_per_wake 3`, `min_gap_s 1800`, `max_per_day 6`) and proposes `data/notifications_text.json`.
**Resolution.** **Split by layer, one owner each:**
- **Doc 08 owns policy** — classes, priorities, event→class mapping, budgets, quiet hours, coalescing — in `data/notifications.json`. Doc 08's four-class model is canonical; P4 ships disabled.
- **Doc 13 owns the platform** — Android channels, `AlarmManager`, permission flow, scheduling mechanics — in `data/android.json`, and *consumes* doc 08's plan. Doc 13's parallel rate limiter is deleted; its three channels map to P1/P2/P3.
- **Doc 12 owns only the in-app banner/toast gate**, whose constants move into `data/ui.json` under `in_app_alerts`. Its `data/notifications.json` block is deleted.
- Copy lives in `data/notifications_text.json`, owned by doc 13, reviewed by whoever owns tone.
**Amend:** 08 §3.3 (unchanged, now sole), 12 §3.1/§8, 13 §2.5/§8.

### C-72 — Notification budgets differ 3×
**Contradiction.** Doc 08: P2 = 3 per 6 hours, min gap 20 min, global 8/day. Doc 12: p2 = 3 per hour, global 3/hour. Doc 13: max 3 per wake, min gap 30 min, 6/day.
**Resolution.** Doc 08's numbers are the push budget (they are the most conservative and the most reasoned about attention cost). Doc 12's numbers apply only to *in-app banners*, where a higher rate is correct because they cost no attention outside the app — retained under a different key name (`in_app_alerts`) so they can never be confused with push budgets.
**Amend:** 12 §2.13/§8, 13 §2.5.

---

## 9. Ownership gaps — things the spec requires that no doc owns

| # | Gap | Spec ref | RULING |
|---|---|---|---|
| **G-1** | **Population, occupancy, job fill, happiness, city level.** Doc 02 reads `occupancy`/`job_fill` "from doc 03"; doc 03 reads them "from doc 11 population"; doc 08's registry names a "Districts, Population & Stability" doc. None exists. `city_level` thresholds are proposed by doc 02 with no owner, and gate doc 02's upgrades, doc 09's land purchase, doc 06's vehicle unlocks and doc 10's road crew. | §31, §32, §36 | **Doc 09 absorbs it** (retitled *Map, Land, Districts, Population & Stability*). It already owns districts, the stability formula and the aggregates. New code root `sim/population/`; new save sections `population`, `progression`. Doc 02's `city_level_population_thresholds [0, 250, 1000, 4000, 12000, 30000]` are adopted. |
| **G-2** | **Construction crews and the project queue.** Docs 02, 03, 06, 07, 09, 10 and 12 all reference crews, a queue, specialisations and reordering; doc 01 names a `WorkService` at P10; no doc owns the queue. Doc 02 and doc 06 publish contradictory crew capacities (C-50). | §12 | **Three-way split, published as one API.** Doc 06 owns crews as **dispatchable units** (roster, station capacity, preemption at priority 400, `auto_dispatch_construction: false`). Doc 02 owns the **project record and progress** (`sim/construction/`, work units via doc 01's `WorkService`) and publishes `ConstructionQueue.submit(job) / reorder / cancel` + `job_started/completed/cancelled`. Doc 09 keeps the land-development phase→crew-type mapping. Doc 10 submits road jobs to doc 02's queue. |
| **G-3** | **Audio.** Spec §39 lists 16 required sounds and calls power restoration's audiovisual signature out explicitly; doc 11 emits `render_relight_started/peak` "for doc 13"; doc 13 does not own audio. | §39 | **Deferred to Phase 2 with a named owner: doc 11** (it already owns the event hooks and the timing beats). Add `game/audio/` and a §2.16 to doc 11 in Phase 2. MVP ships silent; this is recorded, not hidden. |
| **G-4** | **Progression, unlocks, eras, milestones.** Doc 08's registry lists a `progression` section owned by "Progression"; nothing owns it. | §36 | **Doc 09** (with G-1 — progression is population-driven in MVP). |
| **G-5** | **Analytics / lifetime stats.** `stats` save section unowned. | §48 | **Doc 09** owns the `stats` section as local counters. Network analytics deferred past MVP (no `INTERNET` permission — doc 13 §2.7). |
| **G-6** | **Traffic-signal outage congestion penalty.** Doc 04 flagged it unowned. | §4 Pillar 1 | **Closed — doc 10 owns it** (`DARK_SIGNAL_DELAY 0.45 gm`, `DARK_SIGNAL_ADD 0.19`). Doc 04 consumes nothing; it only emits the power state. |
| **G-7** | **`tests/fixtures/bench_city.json`** — doc 11's on-device gates silently stop running if it goes stale. | §50 | **Doc 09 generates it** (`tools/gen_bench_city.py`, same generator family as the starter city); **doc 08 validates it** against the current save schema in CI; **doc 11 consumes it**. |
| **G-8** | **String table / localization.** Doc 12 mentions an externalized string table; no file, no owner. | §49 | **Doc 12 owns `data/strings.en.json`**, keyed as `n_<event>_title` / `n_<event>_body` (doc 08's convention) and `ui_<screen>_<element>`. English only in MVP. |
| **G-9** | **`roads` save section.** Doc 10 defines one; doc 08's registry omits it. | §47 | Registry corrected (C-26). |

---

## 10. Forced numeric recomputations

These are not open questions — they are arithmetic that must be redone once the rulings above land. Each belongs to exactly one doc.

| # | Doc | What must be recomputed | Because of |
|---|---|---|---|
| R-01 | 02 | All 60 rows of `power_demand_kw` and `water_demand` at the new `k_dem` | C-13 |
| R-02 | 02 | All condition thresholds, decay rates and factors on the [0,1] scale | C-14 |
| R-03 | 02 | Payback table §2.2 (it used doc 02's deleted tax and upkeep columns) | C-08, C-09, C-10 |
| R-04 | 03 | Starter expense line and net (306 → ~347 $/gh; +414 → ~+373 $/gh) and the whole S1–S12 pacing table | C-12 |
| R-05 | 03 | Worked example E and the S5 land beat ($3,900 → $6,700) | C-18 |
| R-06 | 04 | WE-1, WE-2, WE-3, WE-4 and tests 1/2/15 against doc 02's `base_kw` | C-31 |
| R-07 | 04 | Demand aggregation against normalized doc-01 curves (+~20% mean RES) | C-32 |
| R-08 | 04 | All `build_cost` rows onto doc 03's currency ladder | C-07 |
| R-09 | 05 | Every flow, volume and capacity constant × `WU_SCALE 0.1333` | C-34 |
| R-10 | 05 | Worked examples A–F in rescaled units | C-34 |
| R-11 | 06 | `R_fire_base` recalibration after deleting `base_fire_risk_by_archetype` | C-42 |
| R-12 | 06 | `S_req_base` derived from doc 02's `fire_load` | C-43 |
| R-13 | 06 | `R_storm_base` against doc 07's stated storm outcome targets | C-53 |
| R-14 | 06 | Vehicle costs onto doc 03's ladder | C-07 |
| R-15 | 08 | `M(H)` at the 720-hour cap: `M(720) = 460.8`, ×0.64 | C-19, C-20 |
| R-16 | 09 | Starter manifest, population 256→144, night peak, water demand, tank autonomy, district stability worked values | C-11, C-13, C-32, C-34 |
| R-17 | 11 | Frustum footprint, chunk counts and draw-call budget at `D_MAX = 420 m` | C-63 |

---

## 11. Canonical save-section registry (supersedes doc 08 §3.1)

Top level: `schema_version`, `sim_time_minutes`, `rng_streams`, then:

| Section | Owner | Notes |
|---|---|---|
| `meta` | 08 | save identity, difficulty, catch-up bookkeeping, `reserve_treasury` |
| `rng_streams` | 08 (custody) | seven streams per constitution §5 |
| `time` | 01 | `tick_index`, residual, timers, work units, scheduled events |
| `world` | 09 | blocks, ownership, development, tile overrides |
| `districts` | 09 | membership, reliability EMAs, stability components |
| `population` | 09 | per-building occupancy/job fill, happiness, city level |
| `progression` | 09 | unlocks, milestones |
| `stats` | 09 | lifetime counters |
| `buildings` | 02 | per-building records |
| `construction` | 02 | project queue, progress, crew bindings |
| `economy` | 03 | treasury, carry, tax rate, land owned, ledger, hourly ring |
| `power` | 04 | components (SoA), ties, backup gens, system, building service |
| `water` | 05 | nodes, tanks, edges, zones, jobs, policy |
| `roads` | 10 | RLE tile blocks, closures, speed overrides, auto-repair |
| `incidents` / `fleet` / `dispatch` | 06 | active incidents, units, policy + stats |
| `weather` / `director` | 07 | timeline, storm cell, flood; TP, cooldowns, scheduled |
| `notifications` / `event_log` / `pending_report` | 08 | buckets, rings, unacknowledged report |
| `ui` | 12 | camera, overlay, settings, onboarding |
| `render_prefs` | 11 | camera continuity only |
| `android` | 13 | last pause stamp, permission state, device profile |

---

## 12. Amendment worklist by doc

**00 Constitution** — C-01 (§4 clock wording), C-02 (§4 cadence clarification), C-03 (§2 `user://settings.cfg`), C-05 (§2 compression note). Four amendments, all one-liners.

**01 Time** — Ruling Zero (renumber §5); C-19 (cap → 12 h); C-21 (retire 0.6 ms budget); C-22 (add `advance_coarse_sliced`); C-25 (`section_version`); C-27 (empty template modifiers); C-32/C-33 (add `power_demand_civic`, `power_demand_datacenter`, rename `water_demand_residential`, add `water_demand_commercial`); C-55 (defer offline Director cap to doc 08).

**02 Buildings** — C-06 (delete radii); C-07 (delete costs); C-08 (delete upkeep); C-09 (delete tax formula); C-10 (delete tax column); C-13 (raise `k_dem`, regenerate); C-14 (rescale condition); C-15 (delete cents accumulator); C-16 (damage fractions); C-25; C-30 (delete electrical columns, keep footprint); C-35 (add `water_facility.variant`); C-42 (unchanged, now normative); C-43 (delete fire dynamics, keep `fire_load`); C-44 (delete crime multipliers); C-50 (delete `unit_slots`/`crew_slots`); C-51 (implement coverage); C-57 (delete weather constants); C-62 (add `E_AVENUE`); G-2 (own `sim/construction/`).

**03 Economy** — Ruling Zero; C-07 (sole currency authority — publish the full ladder); C-12 (restate starter expenses, re-run pacing); C-16 (repair pricing); C-17 (own `data/difficulty.json`); C-18 (rewrite example E and S5); C-20 (own the offline curve, read `ctx.catchup_index`); C-56 (stability on [0,1]); C-59 (auto-accrual confirmed — the spec §41.5 deviation is **approved**, `economy.manual_collection` is deleted); C-61.

**04 Power** — Ruling Zero; C-07/C-08/C-12 (costs and upkeep); C-16; C-25; C-30 (own capacities, drop footprint); C-31 (delete `base_kw`, recompute WEs); C-32 (delete `tod_curves`); C-36 (fuel owner); C-37 (`power_availability_hour`); C-38 (rename `block_dark`); C-39 (`restore_order`, `powered_fraction`); C-40; C-41 (manual routing ruled); C-53 (delete `h_wind`); C-54 (delete lightning targeting, keep damage bands).

**05 Water** — C-06; C-16; C-33 (delete hourly curves); C-34 (apply the rescale); C-35 (own variant numbers); C-36 (own `coverage_frac`); C-37 (`water_service_factor_hour`); C-46.

**06 Incidents/Dispatch** — Ruling Zero; C-07 (fleet costs); C-42 (delete `base_fire_risk_by_archetype`); C-43 (derive `S_req_base` from `fire_load`); C-44 (adopt `crime_weight`); C-45 (use the `crime` stream); C-46; C-47 (`destroy_allowed()`); C-48 (`condition_hazard_mult`); C-49 (drop profile fields); C-50 (own capacities); C-52 (state as ruled); C-53 (own storm damage); C-67 (`speed`/`heading`); C-70 (pacing table); G-2 (own crews as units).

**07 Weather/Director** — Ruling Zero; C-16; C-17 (delete `repair_cost_mult`); C-28 (adopt doc 01's calendar); C-53 (delete wind rolls); C-54 (own targeting, drop damage bands); C-55 (tighten F8 to doc 08's rule); C-56 (write via districts); C-57 (authoritative); C-58 (`precip01`); C-59 (state global-with-cell).

**08 Persistence/Offline** — Ruling Zero; C-03; C-04 (withdraw `platform/`); C-19 (12 h); C-20 (delete yield rows); C-21 (make the decision rule normative); C-22 (delete threading); C-23 (horizon); C-24 (assert ownership over doc 13); C-26 (registry per §11); C-47; C-68 (`is_resync`); C-71 (sole owner of notification policy).

**09 Map/Land/Districts** — C-11 (revert starter mix); C-25; C-29 (retune development timing); C-34 (rescale water); C-38 (derive district dark); C-56 (city stability aggregate); C-60 (name road classes); C-61 (rename block score); G-1 (absorb population/stability/progression/stats); G-7 (generate `bench_city.json`); R-16.

**10 Roads** — C-25; C-29 (work units use the channel); C-48 (no change — doc 06 acts); C-60 (adopt doc 09's template); C-62 (gate accepted); C-63 (no change); X-1/X-2 in doc 10 §9.2 are closed by G-2 and doc 09's existence.

**11 Rendering** — C-38 (name); C-39/C-40; C-58; C-63 (own projection constants, **re-derive the draw-call budget**); C-64 (4 states confirmed); C-66 (own `occupancy_hour_curve`); C-68; G-3 (own audio in Phase 2); G-7 (consume the fixture).

**12 UI/UX** — C-25; C-35 (build cards per variant); C-59 (delete `manual_collection`, step 5 = review the ledger); C-62 (13th failure code); C-63 (reference doc 11's projection constants); C-64 (SELECTED is UI-only); C-65 (A10 → 1×/2×/3×); C-71/C-72 (delete `data/notifications.json`, move in-app constants to `data/ui.json`); G-8 (own `data/strings.en.json`).

**13 Android** — Ruling Zero; C-04 (no `platform/`); C-19 (delete `offline_max_hours`); C-23 (fix the horizon); C-24 (delegate persistence); C-71 (consume doc 08's policy, delete the parallel limiter). Spec §21.1 amendment request (background execution clause struck) is **approved** — record it in doc 13 §9 as ruled.

---

## 13. Blocked until ruled — do not implement

1. **Anything with a price on it** until C-07 lands (docs 02, 03, 04, 06 tables).
2. **`data/buildings.json`** until C-13 (`k_dem`) and C-14 (condition scale) land — every row changes.
3. **`data/water.json`** until C-34's rescale is applied.
4. **`data/starter_city.json`** until C-11, C-13, C-32 and C-34 land — it is downstream of all four.
5. **Any doc-number reference in code or comments** until Ruling Zero is applied.

Everything else in Phase 0 of doc 99 is unblocked: the clock, scheduler, RNG, event bus, command API, tile grid, save envelope and test harness carry no disputed numbers.

---

## 14. ROUND 2 — post-amendment verification rulings (binding)

The adversarial verification pass (docs 96/97) found 22 residual defects after the amendment wave. Rulings:

### RR-1 — Blackout event name (verif F-1, HIGH)
The carrying event is **`BlockDarkChanged`** everywhere, matching the C-38 flag rename. Doc 04 already emits it; **doc 11 amends every consumption site** (§2.7.2/.3/.5, §4, §5) from `DistrictDarkChanged` to `BlockDarkChanged`. Block granularity is the render chunk; the event was never district-scoped.

### RR-2 — Road pricing ownership + no standing road upkeep (verif F-4/S-6, HIGH)
Doc 03 is the sole currency authority (C-07) — **roads included**. `data/roads.json` loses `build_cost`, `upgrade_cost`, `upkeep_per_game_day` and `repair_cost_base`; doc 03 adds a `roads` block to `data/economy.json` (street/avenue per-tile build and upgrade prices, adopting doc 10's magnitudes onto its ladder). **Roads carry NO standing per-tile upkeep in MVP** — mirroring C-08's no-double-billing principle, road cost is build + condition decay + repair (repair priced via C-16 `capital_value × damage_fraction × 0.85 × M_repair`). Doc 03 books an honest **routine road-repair expectation line** in the starter ledger, derived from doc 10's decay rate and the repair pricing over the 783 core road tiles — derived, not assumed. Doc 03's test 33 (`build_cost` in no file but `data/economy.json`) then passes as written.

### RR-3 — Road condition joins [0,1] (verif R-2)
C-14's "condition ∈ [0,1] everywhere" applies to roads too. Doc 10 rescales (`condition : float 0..1`, `cost_per_tile = base × (1 − condition)`, `job_completed → 1.0`, decay /100); doc 06 test 30's consumed values become 1.00/0.55/0.10. No undocumented carve-outs.

### RR-4 — Weather multipliers: doc 07 sole owner, incident rates included (verif R-1)
Extending C-57's principle: doc 06 deletes its `weather_mults` table (crime/fire/transformer/traffic, including the dead snow/blizzard/fog columns) and consumes doc 07 `get_effect()` channels (`incident_crime_mult`, `incident_traffic_mult`, `incident_utility_mult`, `fire_ignition_mult`). One statement of weather, one owner.

### RR-5 — Yield anchors are descriptive; published tax rows are normative (verif S-1)
The published `base_tax_by_level` rows (house 12 / store 26 / apartment 70 / office 130 …) and the **$686/gh starter anchor are LOCKED** — they are woven through C-11, doc 09 and Milestone 1 acceptance. `TAX_YIELD[class]` becomes a documented derivation aid; doc 03 test 7 changes from equality to a ±6% drift guard against the published rows.

### RR-6 — Doc 03 starter ledger re-run, round 2 (verif F-6/F-7/S-2/S-3/S-4)
Doc 03 restates the starter ledger with every post-amendment input at once: `E_grid` on doc 09's real inventory (13×L1 + 9×L2 + 1×L3 transformers = 2.40 MVA, 1.416 km of line → ≈ $74.9/gh), pump O&M from the rescaled `E_water` formula (40 m³/h × 0.35 = $14/gh), the RR-2 road-repair line, and gross revenue using doc 09's owned t0 factors (`f_stability 0.972 × f_happiness 1.110 = 1.079`) instead of the assumed 0.90 aggregate. Then re-runs S1–S12 and the guardrails. Doc 04 test 24's E_grid expectation updates to match.

### RR-7 — `DEMAND_LEVEL_GROWTH` is a floor, not an equality (verif F-8/S-11)
Doc 03 §5/§8: the requirement is **`k_dem > TAX_LEVEL_GROWTH (2.15)` for every growth class**; the shipped constant becomes `"REQUIRED_MIN_DEMAND_LEVEL_GROWTH": 2.15` (exclusive). Doc 02's three class values (2.35/2.45/2.55) are the authority.

### RR-8 — Doc 02 table reproducibility + variant footprints (verif S-7/S-8)
Doc 02 publishes the **unrounded L1 water seeds** (e.g. 0.128, 1.28, 0.192) alongside the display-rounded cells and states generation runs from the seeds. Per-variant `water_facility` **footprints belong to doc 05** (C-35: per-variant numbers), doc 02 references them; doc 09's 77-tile total (tank 2×2) is correct.

### RR-9 — C-43 gloss corrected (verif S-9)
The formula `0.50 × (fire_load/20)^0.45` is canonical; high_rise L5 = **3.06**, not 3.6. §5 C-43 above is corrected in place; doc 06 needs no change; doc 02 closes its §9 open question 1.

### RR-10 — Doc 04 stale figures (verif F-2/F-3/S-10)
Doc 04 drops the already-satisfied C-40 request to doc 11 (4.50 s shipped), and restates §2.13's starter figures from doc 09's R-16 results (402.0 kW nameplate; doc 09's published night-peak) instead of the pre-C-11 508 kW.

### RR-11 — Doc 05 stale starter water demand (verif F-5/S-5)
Doc 05 restates starter demand as **5.56 m³/h against 40 m³/h supply (7.2× headroom)** per doc 09 §2.9.4.

### RR-12 — Doc 11 Z2 frustum table (verif S-12)
The phantom fourth chunk row at r = 412 m is removed (rows at 52/180/308 m only inside `r_far = 411.8 m`); chunk count and draw-call figures re-derived (~15–17 chunks), test 19 expectation updated.

## 15. ROUND 3 — closing-audit rulings (binding)

### RR-13 — Road-repair ledger priced at doc 10's operating point (audit N-1)
Doc 10 owns congestion physics; the starter city's derived operating point is **c_day = 0.35** (decay multiplier 1.2625). Doc 03 re-derives its road-repair ledger line at that point (≈ $185.9/gh, not the $147.22 floor), restates net and `PACING_ROAD_PER_DEVELOPED_BLOCK`, re-runs the pacing rows and guardrails (retuning expense constants only if a guardrail breaks, stating what changed), and aligns its test 43 to c_day = 0.35 so it asserts the same starter city as doc 10 test 42.

### RR-14 — Z2 chunk rows use the pure ceiling rule (audit N-2)
Doc 11's Z2 rows are ⌈W/128⌉ with no discretionary rounding: 5 / 5 / 6 → **16 chunks, 10 MEDIUM + 6 FAR, 159 draw calls (165 with overlays)**; the 20:9 aspect delta is +5 chunks. `data/render.json`'s `_z2_derivation` and test 19 match.

### RR-15 — Weather-keyed escalation/spread constants move behind doc 07 channels (audit N-7)
Extending RR-4: doc 07 publishes a **`fire_escalation_mult`** channel whose per-state values are **adopted from doc 06's current `esc_env` table** (ownership moves; calibration is preserved, so doc 06's §1.1 band and test 23 invariants stand). Doc 06 deletes its weather-keyed `esc_env` entries and consumes the channel. Doc 06 §2.8 additionally multiplies doc 07's existing **`fire_spread_mult`** into spread growth (it is currently published and unread) and re-derives the affected spread worked values/tests.

### RR-16 — Department lines are staffing-only where a utility formula bills O&M (audit N-9)
Wherever `E_grid`/`E_water` bills a facility's O&M, the department expense line for that service is **staffing-only** and must say so. Doc 03 labels `water_works 20` staffing-only (mirroring the PLANT-1/SUB-A exclusion). No number changes.

### RR-17 — Test 33 is key-based (audit N-5)
Doc 03 test 33 asserts price **JSON keys** appear only in `data/economy.json`; explanatory `_note` strings may name tokens freely. Respecify the test; no data changes.

### RR-18 — Housekeeping (audit N-3/N-4/N-6/N-8)
Doc 03: test 7 negative-case figure is 16.7 %; net-line arithmetic shown from unrounded lines; the per-district K constant re-derived (1.36378); E_grid tolerance harmonized to ±0.5 on both sides. Doc 04: annotate the C-12 changelog row with the RR-6 correction ($74.9). Doc 09: §9 cross-doc notes about docs 04/05/03 are marked resolved (they were fixed in Round 2).

### RR-19 — Rounding rules are canonical; the four non-reproducible cells are corrected (P0-15 implementation finding)
The generator found doc 02's published tables contain four cells that violate the doc's own generation rules — two arithmetic slips (`house` L4 fire 0.00032 → rule gives **0.00031**; `construction_yard` L3 fire 0.00065 → **0.00066**) and two half-**down** roundings of exact `.5` ties whose rule is half-up (`fire_station` L2 radius 22 → **23**; `water_facility` L2 jobs 18 → **19** — the fourth cell, missed by every earlier sweep because the k_out column was never audited). **Ruling: the §2.2 rules + §8 seeds are the single source of truth; all four published cells are corrected to the rule-generated values, and the generator's whitelist is deleted.** Doc 02 amends the four cells, closes its §9 open item 4, and re-derives worked example E6 at radius 23 (margin 0.027 instead of 0.006; the "UI must show the margin" lesson stands, and the condition-gate threshold restates from 0.89 to its re-derived value). Master-plan working rule 6 ("generated data is generated, never hand-edited") is the deciding principle.

### RR-20 — Economy implementation acceptance notes (P0-19..22 findings, recorded)
The economy implementation shipped with these overseer-accepted resolutions: (a) the **published `CAPITAL_VALUE_V` vector wins** over §2.3's closed form (RR-5's principle; max divergence $159 at data_center L5, basis recorded in the generated file); (b) doc 03's 14-archetype cost roster vs doc 02's 12-archetype MVP catalog is bridged by a **`doc02_archetype_alias` map** (`high_rise`↔`highrise_res`, `power_facility`↔`power_plant_gas`, `water_facility`↔`water_plant`); `factory` and `highrise_com` rows ship as currency-authority orphans pending their archetypes (post-MVP); (c) the cost columns live in **`data/building_economy.json`** (own generator), not `data/buildings.json`, whose generator bans cost keys per C-07 — doc 03 §3.2's placement was unbuildable as written; (d) minor doc arithmetic nits (example D's printed 12,389; the 5e-5 road-line rounding; §9 item 12's stale $625K) are recorded in the implementation summary and do not move any shipped value.

## 16. WAVE 8 — routing, sub-steps and the ambient band (binding)

### RR-21 — The ambient-incident band is re-ruled at the measured rate, **5–8 per game-week** (doc 92 §18.7)
Doc 92 §18's 2–4/game-week band is **retired**. It was fitted in Wave 6 while `IncidentWorld.water_mains()` and `road_intersections()` were base-class stubs returning `[]`, i.e. with **two of doc 06 §2.6's six generators producing exactly zero at every city size**; both landed in Wave 7. Measured on doc 92 §18.6's own methodology — 12 seeds × 28 game-days of `do_nothing` per arm, 336 game-days each — the control city runs at **6.62/game-week before Wave 8 and 6.54 after**, and at **6.06 with the ambient floor switched entirely off**, so no floor edit can reach 2–4 and a `max()` cannot subtract. Reaching it would require cutting `traffic_per_intersection` ≈ 6.5×, and the starter city already measures **0.515 accidents/game-day against doc 06 §2.6(e)'s own worked intent of 0.687** — i.e. *below* the specification. **Ruling: the band is the measurement, not the other way round.** Every testable clause of doc 92 §18's original ruling holds at the new rate (0 failed, 0 abandoned, 0 destroyed over 336 game-days, treasury up on 12 of 12 seeds); the word that changes is "weekly", because the dispatch loop is a daily beat with a weekly floor under it. **No data moves**: `data/incidents.json` `ambient_floor` keeps `enabled true`, `per_day` summing to 0.40 across the same five channels, and `grace_days 2.0`. `tests/test_balance_gates.gd` gate 19 already asserted the measurement; it now agrees with the ruling as well.

### RR-22 — Doc 10's router is doc 06's ETA authority, and the wiring waits on two rulings doc 06 and doc 10 owe (doc 06 §2.10, doc 10 §5.2)
`sim/roads/road_travel_time_provider.gd` shipped in Wave 7 overriding only `travel_gs` and `route_tiles`, and **nothing constructed it** — doc 06 priced every dispatch on its own Chebyshev stand-in while doc 10's router sat beside it, tested and unused. Wave 8 completed the seam (all four of doc 10 §7's published inputs, unrescaled per C-48/C-61; the tile→edge join; doc 10 §2.14's rank-then-quote contract with the quote budget published *through* the seam; `_boot_roads` ahead of `_boot_incidents`) and then **held the one-argument wiring**, with the measurement in doc 06 §2.10's Wave-8 note: on doc 92's `greedy_growth` agent the 21-game-day run goes from **12.6 s with 0–4 open incidents to over twenty minutes with the open roster still climbing on game-day 18**. Five mitigations were implemented and measured and none moved it, because the cost is not the router: real ETAs across a collapsed, flood-closed network push `eta + penalties` past `MAX_ACCEPTABLE_COST = 90`, and **doc 06 §2.10 has no terminal rule for an incident no unit can answer**. **Two rulings are required before the argument goes in, and neither belongs to an implementation branch:** (a) **doc 06** must say what becomes of an unanswerable incident — it already has `STATUS_ABANDONED` and an `incident_abandoned` event that gate 9 measures, and it lacks only the condition — or re-fit `MAX_ACCEPTABLE_COST` to the street-true ETA distribution doc 06 §1.1's Wave-8 measurement now publishes; (b) **doc 10** owes hierarchical routing, which its own test already reports as REQUIRED (*"median P0 expansions 1154 vs trigger 800"*) and which is what makes a ~5 ms quote affordable inside a per-sub-step loop. Until both land, `CitySim` constructs the stand-in and `tests/test_incidents_routes.gd` pins that it does, so the day the ruling arrives the pin fails and somebody reads this entry.

### RR-23 — A power component's `tile` is its LOCATION and doc 06 dispatches to it (doc 04 §2.1, doc 08 §2.8)
`PowerGrid.add_component` defaulted `tile` to `Vector2i.ZERO`, and `CitySim._boot_power` supplied no tile for plants, substations, feeders or transmission links — `data/starter_city.json` spells a terminal component's position `terminal`, not `tile`. Every substation and plant failure in the shipped game therefore raised its incident at **(0, 0)**, and the value went into every save ever written. **Ruling: the field is normative and the boot path must fill it.** The boot reads both spellings; `PowerGrid._initial_tile` falls back to the head of a line component's own route; `PowerGrid.deserialize` applies the same rule to a legacy body; and **`CitySim.restore_state` re-stamps authored power tiles from the boot file on every load**, because a boot-authored terminal is boot data and not player state — the same rule `_transformer_cover` already follows. The repair deliberately does **not** live on doc 08 §2.8's ladder: a migrator may not read `data/`, and the authored terminal is in `data/`. Measured consequence on the doc 92 rig (`balanced`, seed 1337, 50 game-days, with the router wired so the defect is visible): dark share **61.8 % → 6.25 %**, and balance gates 4, 12c, 18, 18b and 19 go from failing to passing.

### RR-25 — The city level is `max(population rung, completed objectives)`, and `data/goals.json` is doc 09's (Wave 9, 2026-08-20)
Doc 09 §2.11's ladder had **one** consumer-facing surface — a toast on the way past — so the progression the whole build-card, land and upgrade economy hangs off was invisible to the player it was for. Doc 09 gains **§2.14 (the goal curriculum)** and **§8.3 (`data/goals.json`)**; doc 12 gains **§2.19 (S14, the goals sheet)** and a §2.4 amendment for the eighth chip; doc 92 gains **§22** (the measurement); doc 93 §G carries the three rulings. **Ruling: objectives ADVANCE the level, they do not gate it** — `city_level = max(level_reached(population), goals.earned_level)`, both through the one monotone writer `ProgressionSystem.grant_level`. The rejected alternative (objectives REPLACE thresholds for levels 1–5) is refused with a measurement, not an opinion: three of the five curriculum levels ask for verbs no scripted agent drives, so pure replacement would strand `balanced` at level 2 for ever and stop doc 92's matrix measuring the ladder it was fitted on (doc 93 §G1). **`data/progression.json` is byte-identical**; the only threshold that moved in 27 balance gates is gate 20's level-1 window, from `[2, 4]` to `[0, 2]`, re-derived in doc 92 §22.4, with the new gate 21 asserting that the objective list is what earned it. Ownership is doc 09's for the same reason §2.11 is: the curriculum is per-city-level and the level is doc 09's scalar. Two subsidiary rulings ride with it — **a curriculum row may never name a verb with no UI surface** (doc 93 §G2; `stamp_road_tiles`, `place_water_main` and `repair_buildings` therefore exist as evaluators and are used by no level, per doc 92 §17.6), and **the curriculum is five levels because the ladder has five rungs above the founding level and a sixth would unlock nothing** (doc 93 §G3). `CitySim.SAVE_SECTION_VERSION` moves **2 → 3**: the body gains one additive `goals` key, and because doc 08 §2.8 forbids a migrator from reading `data/`, `_v2_to_v3` **marks** the body and `CitySim.restore_state` bootstraps the answer from the standing city — every level at or below the city's own level complete, the active one seeded from what the city already has, and the event queue emptied so a returning player is not shown four level-ups for last week's work.

### RR-24 — STREET-1: the streetlight ground pool was uploaded under the road it lights (render finding, 2026-08-20)
`data/render.json.streetlights.pool_y_m` was **0.06** and the road slab's driving surface is **0.10**. Every `MM_pool` disc in the game therefore failed the depth test against the carriageway it was lighting; what a player saw was the ring of it that spilled onto the block either side — a doughnut of light around a dark road. This was not a tuning miss, it was a geometry miss, and it is a large part of the playtest verdict that streetlights "look like sticks popping out of the ground". **Ruling: the pool's height is derived, not authored** — `road_surface.asphalt_top_m + kerb_height_m + lamp.pool_lift_m`, i.e. just over the FOOTWAY, the highest surface a lamp ever stands on. `pool_y_m` stays in the file, annotated, for a clone with no `road_surface` block. Doc 11 §2.10.1 carries the derivation and the parallax arithmetic that says the 0.155 m float is invisible at Z0. **No sim value moves; state hashes are unchanged on both cities and both paths.**

## 17. WAVE 9 — the router goes live, and the fine tick gets its cadence pass (binding)

### RR-26 — Doc 06 §2.10 gets its terminal rule, `MAX_ACCEPTABLE_COST` is re-fitted to street-true ETAs, and the router is WIRED (doc 06 §2.10.1/§2.10.2, 2026-08-20)
RR-22 held doc 10's router out of `CitySim` on one measurement: with it wired, `greedy_growth` at seed 4242 went from a 21-game-day run in ~10 s with 0–4 open incidents to over twenty minutes with the roster still climbing on game-day 18. **RR-22 attributed that to the missing terminal rule. A four-arm ablation says otherwise, and the real cause is a defect at the seam.**

| `greedy_growth`, seed 4242, 21 game-days, one session | wall clock |
|---|---|
| stand-in (pre-wiring HEAD) | **9.4 s** |
| **RR-22's exact configuration** — router wired, seam pricing every vehicle on one fixed `emergency(32.0)`, `max_acceptable_cost_min` 90, no terminal rule | **> 600 s, killed** (RR-22 reported > 20 min) |
| the same, with **only** the per-vehicle profile honoured at the seam | **11.2 s** |
| + the terminal rule at 24 gh | **11.6 s** |
| **shipped** (+ `max_acceptable_cost_min` 115) | **11.6 – 12.1 s** |

**The seam ignored the `RouteProfile` doc 06 hands it** and priced every trip on one fixed `emergency(32.0)` — no per-type speed and, decisively, **no siren multiplier**. Doc 06 §2.11 gives a responding patrol car `32 × 1.25 = 40 m/gm`; RR-22 measured it at 32, i.e. **20 % slow**, and police answer `crime` and `traffic_accident`, which are the bulk of the ambient load (RR-21). That was enough to push `eta + penalties` past `MAX_ACCEPTABLE_COST` for a whole channel on a degrading network, and the backlog followed. Honouring the profile — one cached `RouteProfile` per distinct speed, so `RoutePlanner._prep`'s constant cache is not invalidated per quote — closes the cliff on its own.

**The two rulings RR-22 asked for are still right, still shipped, and are safety nets rather than the fix.** They close a real gap: **three ROWS of `data/incidents.json` author no ending at all** — `traffic_accident` and `storm_damage/blocked_road` above tier 2 (their `self_resolve_max_tier` is 2 and they carry no other condition), and bare `storm_damage`, which has no `on_fail` block whatsoever. Under Chebyshev ETAs those were always answered and the gap was unreachable; under street-true ETAs across a collapsed network they escalate to tier 5 and stand there for the rest of the city's life. **In the shipped configuration the terminal rule fires zero times across the whole 18-run matrix** — verified by an on/off A/B that reproduces every column byte-for-byte, including `greedy_growth` seed 9001's seven abandonments, which come from the pre-existing `self_resolve` path that street-true waits made reachable. A rule a played city never reaches is exactly what a terminal rule should be.

**Ruling, in two parts.** (a) **An incident with NOTHING committed to it for `unanswered_abandon_h = 24.0` game-hours — one game-day — becomes `STATUS_ABANDONED`** and emits `incident_abandoned{reason: "unanswered"}`, after running whatever `on_fail` actions its type authors. The clock runs only while the `assigned` set is empty and is zeroed by the first commitment, so it measures *nobody is coming*, not *this is slow*; it is **paused** (not reset) while an incident carries `fail_refused`, because C-47's refusal exists so a returning player finds the building still burning. **T = 24 is derived, not chosen**: the longest terminal path any ROW in `data/incidents.json` authors is the SUBTYPE `storm_damage/roof_damage` at **13.574 game-hours** (tier 5 at casual difficulty, 11.574 gh, plus its 2.0 gh hold — reading only the type rows makes this easy to get wrong, because `storm_damage`'s base row authors no ending at all), and 24 is 1.77× that, so every authored `on_fail` still fires first at every difficulty and every weather state and **the neglect-fatal identity is untouched** — an unanswered house fire still destroys its building at 2.80 gh in the kindest case and `do_nothing` still dies in about five weeks. The backlog is now bounded by `arrival_rate × T`, which at the matrix's worst measured rate (~26 incidents/game-day) is ~26 open incidents — inside §2.13's own worst-case accounting of ≤ 40 active, against the 42-and-climbing that held the wiring. (b) **`max_acceptable_cost_min` moves 90 → 115**, derived as `90 × 1.27` where +27 % is the midpoint of doc 06 §1.1's published street-true ETA shift (+22–32 %) — the same decision boundary re-expressed in the metric that now measures it. The full desperation stack (reassign 12 + reserve 45 + a 0.25-fit crew 22.5 = 79.5) leaves 35.5 gm of admissible ETA, which sits just under §2.4's 39.3 gm tier-3 boundary: the cap now says *send it if it can arrive before the tier the send was meant to prevent*.

**A second defect the wave found, and this one was invisible until the cadence moved.** `WaterServiceLedger.settle_hour` settled the founding hour — which the EVERY_HOUR cadence fires before a single game-second has been integrated — as a pressure factor of **0.0**, billing the starter city's first hour as if it had no water; invisible while the ledger accumulated every SimTick, and worth **$436** of the founding hour the moment it did not. An hour with no elapsed time now settles nothing and the documented 1.0 default stands.

### RR-27 — Hierarchical routing is NOT required, and doc 10 §2.14's trigger was measuring a workload dispatch never pays (doc 10 §2.14, 2026-08-20)
RR-22's second blocker was doc 10's own test printing *"median P0 expansions 1154 vs trigger 800 → hierarchical routing REQUIRED"*, with a full quote at ≈ 5 ms. **Both numbers are real and neither describes a dispatch quote.** The trigger times six deliberately corner-to-corner routes; §2.14's own rank-then-quote contract means doc 06 quotes the *nearest three* stations, and a near route is a small search. `tools/profile_routing.gd` — new, and the first instrument to measure the shape §2.10 produces — puts the shipped seam call on the benchmark city (3,132 road tiles, aged 120 game-hours, cold cache, `epsilon_critical = 1.0`) at **0.709 ms mean / 0.556 median / 1.360 p90 / 46.6 expansions**, against **2.862 / 2.179 / 6.365 / 206.2** for the same incidents with every station quoted — **21× less work per incident**, and seven times cheaper than the 5 ms that held the wiring.

**Ruling: the structure is not built, and the reason is measured rather than asserted.** A landmark (ALT) overlay was implemented — a speed-independent lower-bound metric (`length_m / road_class_mult`, which every §2.6 multiplier can only raise), four farthest-point landmarks, one Dijkstra each, rebuilt only when the graph grows, provably admissible so the optimum is unchanged — and it **cost more than it saved on both cities, fresh and degraded**: bench city ranked quotes 46.6 → 45.8 expansions (−1.7 %) for 0.696 → 0.758 ms (+9 %); reference map 6,921 → 5,534 expansions (−20 %) for 110.8 → 141.6 ms (+28 %). The cause is structural: Slacum City's network is a block grid, `manhattan_m / (speed · class_mult_max)` is already within a few per cent of the truth, and what remains is a **plateau** of equal-`f` nodes that no sharper admissible heuristic can remove. §2.14's tunables do not move (the historical series stays comparable) and the trigger is **re-stated** in terms of the workload that matters: build it when the mean rank-then-quote seam call on the benchmark city exceeds **1.5 ms**. It is at 0.709 ms, 47 % of budget.

**Epsilon policy, on the record.** `epsilon_critical` stays **1.0** — admissible and unweighted is right for a fire engine's own route, and rank-then-quote is what makes it affordable inside a per-sub-step loop by bounding both the count of quotes and the length of what is quoted. Weighting remains the lever if the tail ever moves: the same 180 ranked quotes at `epsilon_routine = 1.25` cost 0.476 ms (−32 %) and lengthen the mean quoted route by 0.025 %.

### RR-28 — The fine tick's cadence pass: the minute's roads work is spread, and the service ledgers bank per game-minute (audit 91 D-15 proposals 2 and 3, 2026-08-20)
Wave 7 costed three cadence proposals and took none; Wave 8 took proposal 1. **Proposals 2 and 3 are taken here**, in the same branch as the router because all three move state hashes and doc 08 §2.8's rung has to move once. (2) `roads_congestion` declares `EVERY_TICK` and selects its pass from `tick_index % 4` — congestion + the `c_day` sample on tick 0 of the minute, `TrafficSnapshot.rebuild` on tick 1, `TrafficFeed.rebalance` on tick 2 — so the minute's three passes stop landing on one frame. It is **not** three `EVERY_MINUTE` systems at offsets 0/1/2, because a COARSE step's `tick_index` is hour-aligned and an offset system would never fire offline; the coarse path takes the whole minute in one call exactly as it did. (3) The per-building power and water service ledgers accumulate once per game-minute at `dt = 1 min` instead of once per SimTick at `dt = 15 s`; both accumulators are dt-exact, so the settled hour is unchanged in VALUE but not in float association, and `PowerGrid`'s LIT/DARK hysteresis now samples on a game-minute grid rather than a 15-game-second one. **`CitySim.SAVE_SECTION_VERSION` moves 3 → 4** — the routing/cadence epoch — with an identity migrator: a v3 save opens with every building, dollar and RNG stream where it was left, and every restored incident starts its `unanswered_h` clock at zero, because a v3 body records no such thing and a migrator that guessed would abandon a returning player's incidents on the strength of a guess.

## 18. WAVE 9 — the top of the ladder (binding)

### RR-29 — Core Design Rule 5 is amended to *five levels for every archetype, six for the growth stock*, and the sixth city level is granted because the sixth building rung pays for it (Wave 10, 2026-08-20)

Doc 93 §G3 refused a sixth curriculum level in Wave 9 with a test rather than a preference — *"a level whose reward card is empty is a number, not a goal"* — and doc 92 §22.7 logged the consequence: city level 5 unlocked **nothing whatsoever** (`GoalsModel.reward(5)` returned `{empty: true}`, and the goals sheet showed "Nothing new to build" as a *reward*), so a sixth rung would have unlocked less. This ruling supplies the payout and then grants the rung.

**(a) Six archetypes gain a sixth level; six do not, and the line is jurisdiction rather than taste.** `house`, `store`, `apartment`, `office`, `high_rise` and `data_center` — the revenue-producing stock whose level ladder doc 02 owns end to end — gain an L6 row generated by doc 02 §2.2's own curve family at `e = 5`. The other six stop at five because their ladders are **not doc 02's alone**: `water_facility` is doc 05's per-variant `data/water.json` (five rows × five variants, behind that doc's `levels_4_5_enabled` flag), the two stations are doc 06's `capacity_per_station_level` (five rows, locked by C-50), and the two grid shells are priced off doc 04's `expenses.grid_components`. A content wave may not edit three other systems' balance tables from behind. The roster is **data** (`building_rules.sixth_level_archetypes`), asserted at load, and cross-checked by `tools/gen_building_shapes.py` against the stat table so a mesh set and a stat row can never disagree about how tall a ladder is.

**(b) Every new cell is generated, none is placed.** `value(6) = round_rule(seed × k^5)`, the §8 ladders applied once, half-up at every tie — RR-19's principle applied forward instead of backward. Doc 03's three money columns extend the same way, and `upgrades.CAPITAL_VALUE_V` gains its sixth cell **100.929** (the closed form `1 + (1.45/1.55)(2.55^5 − 1) = 100.9287528125`, half-up at 3 dp) — the only cell of that vector this project has ever placed itself, and it is placed by the rule the other five claim. Two riders are derivations, not exceptions: the **coverage ladder's sixth rung repeats its fifth** (those columns are a demand ON a service stock that did not gain a rung, and demanding coverage the player cannot buy is a wall with no door), and the **L5 rows gain the `upgrade_time_hours` they never had** because they never had a next level to price.

**(c) `max_level` is per-archetype, and a literal `5` is now a bug.** `BuildingCatalog.max_level()` is the roster's tallest ladder and answers no useful question about a particular building; `max_level_of(archetype)` and `Building.max_level` (stamped by the coordinator beside `stats`, derived at load, **never serialized**) are what `cmd_upgrade_building`, the build sheet's level strip, the goals sheet's reward read and the playtest harness must ask. Six literals were replaced.

**(d) The seventh city-level rung is 18,000, and it is an append.** `[0, 200, 700, 1600, 3600, 8000]` → `[…, 18000]`, placed by doc 92 §19.2's own recipe one step further (rungs 2–5 settle at a flat 2.25×; 8,000 × 2.25 = 18,000 exactly) and labelled honest extrapolation exactly as rungs 4 and 5 are. **Reward pacing is split by growth class** so both top rungs pay: the `steady` class opens its sixth rung at **city level 4**, `standard` and `vertical` at **city level 5**. The override (`min_city_level_by_growth_class`) may move the sixth rung and no other, and the generator fails the build if it does — rungs 1–5 shipped, and a city that has earned them may never be told it has not.

**(e) There is no ring-3 land tier, and there cannot be one on this board.** The 7 × 7 world is 9 core + 16 ring-1 + 24 ring-2 = **49 blocks, exactly**; ring 3 is the 9 × 9 shell, and buying it means `world.size_blocks` 7 → 9, a 144 × 144 tile grid, every block id re-based, the committed `bench_city.json` regenerated and doc 03 §2.7's `blocks_owned` escalation re-anchored — a *world* change, not a land tier. Re-gating existing ring-2 land upward is refused for the stronger reason: it would take purchasability away from a city that already has it. Doc 09 §2.8.3 carries the arithmetic; the two top rungs pay out in buildings only.

**(f) Gates 20 and 21 are re-fitted; the other 26 are untouched.** Gate 20: `ladder.size()` 6 → 7, every other claim in it unchanged. Gate 21: the horizon moves 21 → **45 game-days** with a ruled bound of **40** on the top level, against a measurement of 31.1 / 33.5 / 34.3, and **level 5 is now asserted separately against the old 21-day horizon** so "the arc got longer at the top and not underneath" stays provable. Doc 92 §23.9 is the fit.

**(g) Hashes: the starter city does not move; the bench city moves through exactly one key, and the A/B proves it.** Starter coarse/fine are byte-identical. The bench fixture settles at **35,411 residents**, which a seven-rung ladder reads as city level **6** where a six-rung one read 5, so its `progression` section carries a different level and one more milestone. Removing the L6 curriculum row changes nothing; putting the ladder back to six rungs reproduces the Wave-9 baseline byte for byte. The sixth building rung, the L6 meshes, the new `upgrade_time_hours` column and `Building.max_level` are all hash-neutral. **`tools/profile_sim.gd` needs exactly one baseline refresh — the bench city's two digests — and it is published in doc 92 §23.12 rather than made from this branch.**

**(h) One defect is REPORTED, NOT FIXED.** `CitySim.cmd_upgrade_building` reads `upgrade_time_hours` from the row of the level being upgraded TO, where doc 02 §2.2 stores the price of the step `L → L+1` on the row being upgraded FROM — so every upgrade in the game runs one rung's duration too slow, and the last step of every ladder (which has no such row) ran on a bare `4.0`-hour literal. This wave changes only the **fallback**, from that literal to the row below, so the final step reads doc 02's own number instead of a placeholder and every step that already had a figure is untouched. Fixing the off-by-one itself moves every upgrade duration in the game and is a balance pass, not a content one.

**(i) The measured surprise, recorded for doc 04.** The first three-seed run of the new curriculum level failed on two of three seeds at 45 game-days, and the gate said `E_POWER_HEADROOM` on **every single** level-5 house in both cities (25 of 25, 32 of 32). That is doc 02 §8's `k_dem > TAX_LEVEL_GROWTH` working exactly as ruled — a `house` goes 91 kW → 215 kW across the sixth step, more than a whole level-2 transformer — and the fix is copper at the building that was refused, which a level-3 transformer supplies for $2,800 against a $73,572 upgrade. The `curriculum` agent now does it and all three seeds complete. **The tower tier is therefore affordable but fiddly while doc 04's feeder verb is unlanded** (doc 92 F-11): it is the first content in the game that requires the player to read a power refusal and act on it. Doc 92 §23.8 is the measurement.

### RR-30 — Every shipped player verb gets a surface, and the drag-path tool is how the run verbs get theirs (Wave 10, 2026-08-20)

`cmd_place_road`, `cmd_upgrade_road`, `cmd_demolish_road`, `cmd_place_water_main`, `cmd_repair_building`, `cmd_set_priority` and `cmd_demolish_building` were shipped, tested `CitySim` verbs that **no UI could reach** (doc 92 §17.6, doc 93 §G2). Seven verbs is not an oversight, it is a category: two of them are *runs* (a tile list, billed per tile) and doc 12 §2.7's placement machinery only knew *footprints*, and the other four wanted §2.9 item 6's actions row, which was specified and never built. **Ruling: doc 12 §2.7's drag-path placement is the mechanism for every run verb, and §2.9 item 6 is the mechanism for every per-building verb; both ship in full rather than one card at a time.** The run tool is a second headless state machine (`ui/path_tool.gd`) beside `BuildController`'s, sharing the sheet, the bar, the verdict ladder and the back stack; the run geometry is the doc's own L (Manhattan, longest leg first, ties to X); every verdict is the owning command's own `preview = true` answer, so the UI re-implements no rule from doc 10 §2.13 or doc 05 §6. **No sim changed.** Three subsidiary rulings ride with it: (a) **the bar does not grow a fourth control** — at 130 % text with larger targets on a 360 dp display four controls measure 404 dp against a 360 dp box, so the LEFT button carries two verbs (`↺` unpins the anchor while drawing, `CANCEL` leaves otherwise) while hardware BACK keeps its single meaning; (b) **`E_CONDITION`'s `Fix this →` is a purchase, not a place** — `RequirementFormatter.FIX_REPAIR`, performed by the panel, because focusing the camera on the building the player already has open moves nothing; (c) **the repair affordance appears at any damage, not below 90 %**, because doc 02's own upgrade gate is `MIN_CONDITION_TO_UPGRADE` and the checklist starts asking for a repair above the doc-12 threshold that would have hidden it. Doc 93 §G2 is amended to record that the doors exist and §G4 rules on the one evaluator kind that stays unused; `data/goals.json` gains `l3_streets` and `l4_repairs`, re-measured in doc 92 §23. **`tools/profile_sim.gd` hashes are unchanged on both cities and both paths, and `balanced` is bit-identical on all three doc 92 seeds across the curriculum re-arc.**


## 19. WAVE 8 FOLLOW-UPS — the four render debts (binding)

### RR-31 — `rebuild()` may be a stateful diff, and the sort under it was `sort_custom` (render follow-ups, 2026-08-20)
`RoadSurfaceView.rebuild()` shipped as a pure function of (grid, graph) — **18.3 ms** on the benchmark city, fired on every road the player lays, and a wave that ships a road-drawing tool turns that into a per-tile drag. **Ruling: it becomes a stateful dirty-tile diff, and the price of that is one exact contract, property-tested: after ANY sequence of edits both uploaded buffers are byte-identical to a from-scratch rebuild of the same city.** `force` restores the pure-function behaviour and is what a sim swap takes. Doc 11 §2.1.2a carries the dependency radii the dirty set is derived from (Manhattan r = 3) and §7.2c the seven tests, five of them property tests over random edit sequences. Measured **19.7 → 4.87 ms** on the benchmark city and **4.76 → 1.18 ms** on the founding one, picture identical to the instance (3,132 asphalt tiles, 576 footway runs, 469 lamps).

**The seeds are read off the graph, not off `road_graph_changed`'s edge delta, and that is the general lesson:** `RoadGraph.apply_edits` excludes from `added_edges` any edge it deleted and recreated with the same id and tile list — doc 10 §2.5's own id-stability rule — and a tile belonging to more than one edge takes its class from the GRID, which no edge delta reports on at all. **An event that reports a change of IDENTITY is not a report of a change of VALUE**, and a consumer that treats it as one is silently wrong on exactly the cases the identity rule exists to protect.

Two sim-side consequences ride with it, both pure optimisations in `sim/roads/road_graph.gd`, both proved hash-neutral on the starter city and on `tests/fixtures/bench_city.json`, coarse and fine: **`_sorted_tiles` sorts a packed integer key instead of calling a GDScript lambda per comparison** (3.44 ms → 0.29 ms on 3,132 tiles; out-of-bounds input falls back to the comparator, because `apply_edits` sorts a caller-supplied list), and **`road_tiles_sorted()` is memoised on `graph_version`**, which is an exact key because `_road_tiles` is written in exactly two places and both bump the version before returning. Callers still get a copy. Both are called four times a tick inside `sim/roads/` as well as once per road edit by the renderer.

### RR-32 — One-buffer MultiMesh uploads are a 2× REGRESSION in GDScript, and the layer's frame was never in the uploads (render follow-ups, 2026-08-20)
The construction branch filed "replace the ~200 `set_instance_*` triples per frame with one `multimesh_set_buffer` per layer" as **the named lever for Fold headroom**. It was measured on the real renderer before it was implemented (`tools/profile_mm_upload.gd`, 600 measured frames a side): per 200 instances a frame the three per-instance setters cost **0.031 ms** and packing the same rows into a `PackedFloat32Array` costs **0.061 ms**, with the `mm.buffer =` write itself **0.003 ms**; at 2,000 instances it is **0.307 ms against 0.662**, and whole-frame wall time agrees (0.518 vs 0.863 ms). **Ruling: the premise is refuted and the setters stay.** `set_instance_transform` is one binding call around a C++ memcpy of twelve floats; packing the same row is twelve scripted array writes plus the basis reads to feed them, and the server-side write is nearly free either way — the cost was never the RenderingServer, it was GDScript.

The instrumented split says the same thing louder: of `ConstructionVehicleView`'s 0.53 ms layer CPU at `--sites=20`, **0.32 ms is pose computation and 0.09 ms is the upload**. The pass therefore took the reductions that were actually there — per-instance work repeated for values that cannot change — and measured them: `_upload` **0.088 → 0.049 ms** on the construction layer, `VehicleView._upload` **0.194 → 0.158 ms** at the Balanced cap, layer CPU **0.506 / 0.512 / 0.484 → 0.453 / 0.447 / 0.456 ms** at Z0 / Z1 / Z2, draw calls unmoved. **The one place the packed buffer IS right is `RoadSurfaceView`** — a per-EDIT path, where the array kept between passes is what makes RR-31's byte-identity contract checkable on a `--headless` run at all (the DUMMY driver stores no instance data). The general lesson for this codebase: **a per-frame path in GDScript should prefer the engine's own per-element setters; reach for a packed buffer when the BYTES are the deliverable, not when the frame is.** *(The 0.32 ms pose half named as the next lever here was taken in Wave 10 — see RR-38(c): 0.354 → 0.213 ms for the whole layer at 20 sites.)*

---

## 20. WAVE 9 — the Fold 6 measurement pass (binding)

*The device never appeared: 45 minutes of `adb` polled every 20 s, 135 attempts, `adb mdns services` re-run on each, zero endpoints advertised, zero devices authorised. Every ruling below is therefore taken on WORKSTATION evidence and says so; each names what a device number would have to show to overturn it, and `tools/device_runbook.md` is the session that would take those numbers.*

### RR-33 — The asphalt fragment ladder is a PRESET CEILING and an escape hatch, never a governor rung (doc 11 §2.1.2, §2.13)
`road_surface.gdshader` gains `uniform int detail` — **2** everything, **1** drops the wear terms (11 m hash mottle, pour joint, wheel-path polish, kerb grime) and keeps every line of paint including the crossings, **0** also drops the four-leg zebra loop. Every branch on it is on a uniform, so it is one scalar decision per draw and the `fwidth()` calls inside are taken in uniform control flow. Measured on the founding city with the camera on the Grand/Slacum junction, three interleaved rounds per arm, `RenderingServer`'s own GPU time at 1920×1080 Balanced: at Z0 **1.5176 / 1.4730 / 1.3637 ms** for rungs 2 / 1 / 0 at hour 21 and **1.8584 / 1.8030 / 1.6956** at hour 13 — arms that do not overlap. **The finding is the split: the zebra loop costs 0.109 ms against 0.045 for every wear term put together — 2.4× — and it paints only on junction tiles.** **Ruling: `road_surface.detail` is the project ceiling (2), `presets.*.road_detail` the per-tier one (Balanced 2, High 2, Performance 1 — provisional, and marked so in `data/render.json`), `RoadSurfaceView.set_detail()` may only ever LOWER the live rung, and the ladder is NOT on `governor.knobs`.** 0.15 ms does not pay for a street that changes appearance mid-pan: every existing rung degrades *fidelity*, and this one would degrade the *drawing*. Rung 0 is shipped by no preset, because losing the crossings changes what a street means. **Rung 2 is proved identical to the pre-ladder shader, not asserted:** 1920×1080 captures one file apart differ on **0 of 2,073,600 pixels at Z0** (Z1 15, Z2 30, against a same-build control of 0 / 4 / 29 — §2.6's `near_flicker` and nothing of the road). The first attempt failed that check: hoisting the per-tile wear trim out of the branch turned `1 + patch + seed` into `(1 + seed)(1 + patch)` and moved 1,756 Z0 pixels by up to 4/255; the cross term is folded back into one multiply and the shader says why. Overturned by a tier-C measurement putting the wear terms below 1 % of its GPU pass (then Performance goes to 2), or by a device that cannot hold 30 fps at rung 1 (then the governor ruling re-opens).

### RR-34 — Pad shadows ship ON, and a shadow question asked at night is not a measurement (doc 11 §2.10b, §2.13)
`PowerInfraView.set_pad_shadows()` had existed since the power-viz branch and had never been priced. The first attempt to price it was run at hour 21 and measured nothing at all, because **the sun is below the horizon at 21:00 and there is no shadow pass for the pads to be in** — a result that reads as "free" and means "not asked". Re-run at hour 13, four interleaved rounds per arm: **+1 draw call at Z0 and Z1, +0 at Z2** on both cities (the pad buffer is one city-wide MultiMesh under one custom AABB, submitted whole and once, so the count does not grow with the roster), and a GPU delta of **−0.0039 / −0.0054 / +0.0170 ms on the founding city against an instrument spread of ±0.011** — negative in two of three poses, i.e. nothing to find. On the benchmark city (144 cabinets) the spread is 40× worse and the largest arm difference, +0.226 ms at Z1, is an **upper bound** and not a measurement. **Ruling: `power_infra.pad_shadows: true`, authored in `data/render.json` and read by `PowerInfraView.setup()` instead of hard-coded in `_build_pads()`.** One draw call of 320 is 0.3 %; the alternative costs the read the layer exists for — a 1.5 m cabinet with no contact shadow at Z0 is a decal printed on the pavement. **Consequential and general: every shadow-cost question in this repo must be asked at hour 13.** Overturned by a Fold daylight Z0/Z1 pose landing within 5 % of the draw-call budget.

### RR-35 — Every published frame number was taken at night, and at 1280×720; both are corrected (doc 11 §2.13)
Two instrument faults, found before any Wave-8 question could be asked. **(a) The harness was rendering at 1280×720 while every table said 1920×1080.** `tools/profile_frame.gd` set `root.size` in `_initialize`, which the window created from `[display] window/size/viewport_*` silently overrides; caught by dumping `--shots` and reading the PNG header, which came back 1280×720 whatever `--resolution` asked for. **Every millisecond column published in doc 11 §2.13 before 2026-08-20 was measured at 0.44× the pixels it claims** (`1280·720 / 1920·1080 = 0.444`). **The record corroborates itself:** the bucket-merge subsection reports *"Z0 and Z1 are BIT-IDENTICAL, 0 of **921,600** pixels differing"* — and 921,600 is 1280 × 720. The true pixel count sat beside the wrong resolution label for a year and nobody read the two together, which is the argument for `_verify_resolution()` refusing to print rather than for reading more carefully. The draw-call, chunk and primitive columns are resolution-independent and are unaffected — and they are the ones the budget is written against. Fixed through `DisplayServer.window_set_size`, with `_verify_resolution()` reading the live viewport back and refusing to print a number under a resolution it did not get. **(b) Every measured frame in §2.13 was taken at hour 21, with the shadow pass empty.** Measured at hour 13 on the same build and poses, the benchmark city costs **+142 draw calls at Z0 (95 → 237) and +120 at Z1 (113 → 233)**, taking the with-UI figures to 262 and 258 of 320. **The 31.6 % headroom §2.13 advertises is a night figure; the tightest daylight pose has 18.1 %.** Nothing is over budget and no §2.13 conclusion is overturned — the error was again conservative — but the margin the doc quotes is roughly twice the margin the game has at noon, **and the tightest pose changes hands**: every table in §2.13 makes Z2 the expensive one, and in daylight it is **Z0**, because Z2 has no shadow pass to fill and Z0 has twelve NEAR chunks' worth. **Ruling: a frame table in this repo states its HOUR or it is not a result**, and the daylight rows are the ones an acceptance gate is read against. **One consequence lands on an open defect:** the chunk census is identical at both hours (bench Z0 12 NEAR / 24 MEDIUM / 0 FAR, Z1 8 / 28 / 0, Z2 0 / 16 / 20), so the whole delta divides cleanly into the shadow pass — **5.92 extra calls per NEAR chunk per split at Z0, 7.50 at Z1** — against doc 91 **D-16**'s worst case of `16.4 buckets × 2 splits` per NEAR chunk. D-16's arithmetic is **2.2× pessimistic against a measured sunlit frame**, because the split frustum culls most of a chunk's buckets before they are drawn. Its own trigger — *"take it the first time a device measurement puts a close-zoom pose near 320"* — is not met: the closest any pose has come is daylight Z0 at 262. The same table confirms two standing claims by measurement for the first time: **Z2 is genuinely the shadow-free pose** — its draw-call count is identical at hour 13 and at hour 21, to the digit, on both cities (196 on the bench, 80 on the founding) — and the founding city tracks the benchmark city's shape at a tenth of the scale.

### RR-36 — The `PERF` line doc 11 §7.4 is built on was never emitted, and `bench_device.sh` cannot launch a scenario (doc 11 §7.4, doc 13 §7)
`PerfGovernor.perf_line()` shipped in Wave 6 with `tests/test_perf_governor.gd` covering its shape, and **nothing ever called it** — so §7.4's documented instrument (`adb logcat -s godot:V | grep '^PERF'`) returns an empty CSV on the shipped build and `tools/bench_device.sh`'s own summariser prints "NO PERF LINES". Two further faults in that script, both readable in `game/main.gd` rather than discoverable only with a phone on the cable: it launches with `--es cmdline` when Godot's Android launcher reads a string **ARRAY** extra and `OS.get_cmdline_user_args()` returns only what follows a literal `--` (so the form is `--esa command_line_params "--,…"`), and **`--bench=S1|S2|S3`, `--preset=` and `--city=` are parsed by nothing.** The shell's whole scenario vocabulary is `--resume`, `--title`, `--zoom=`, `--focus=`, `--advance-hours=`, `--overlay=`, `--rain=`, `--storm=`, `--wet=`, `--blackout`, `--cut-feeder=`, `--place=`, `--save-now`, `--screenshot=`, `--shot-at=` — enough for all six Wave-8 questions. **Ruling: the instrument is wired and the session is rewritten against the vocabulary that exists.** `game/render/perf_telemetry.gd` is the wiring — `RefCounted`, clock-injected, engine-facing, deliberately a separate file so `PerfGovernor` stays the Node-free model its microsecond tests need — and it takes three lines in `game/main.gd`, which belongs to the lead and is not touched here. `SaveService` gains `last_save_ms` / `last_load_ms` and a `^PERF`-anchored `PERFIO` line so one logcat grep collects both halves. **`tools/device_runbook.md`** is the session: the retry loop, a pre-flight whose probe is a *visible* signal rather than a log line, the six questions as commands against the **installed** build, and a workstation provisional in every cell so a device number that disagrees is a finding. It installs, reinstalls and uninstalls nothing — the user's saves are in that app's private storage and there is no export path.

### RR-37 — Save and load are synchronous, and nobody had measured them (doc 08 §2.7, doc 11 §2.13, doc 13 §2.9)
`tools/profile_save.gd` is new and drives the **shipped** path — `SaveService.save_slot` / `load_slot`, the calls the lifecycle makes — rather than a harness path. Headless workstation, best of 7 / best of 5: the founding city (34 buildings) saves in **13.9–14.8 ms** and loads in **48.5–50.0 ms**; the 1,500-building benchmark saves in **120–154 ms** and loads in **429–483 ms**. **A load of the founding city is three frames at 60 Hz on a workstation and a save is most of one; on the benchmark city a load is half a second, synchronously, on the main thread.** Two consequences are published rather than fixed, because neither belongs to a render branch: doc 08's autosave lands a **visible hitch** as soon as a city is a few hundred buildings — the cadence is not the problem, the synchronous write is — and **doc 13 §2.9's ANR arithmetic budgets the catch-up without budgeting the LOAD in front of it**, which on the benchmark city is 0.46 s before a single coarse step runs. Doc 13 §7 gains **D-17**, which gets the same two numbers off an uninstrumented device as a difference of `am start -W` cold starts (`--title` / `--resume` / `--resume --save-now`), so the measurement does not wait on a new build. Expect the Fold at 2–3× the workstation on both columns; that factor is the multiplier every other provisional in the runbook leans on, and confirming it is the first thing the next session should do.

---

## 21. WAVE 10 — the performance ladder (binding)

*Four levers, each already named and priced by an earlier session, taken and
re-measured. Every arm is interleaved WITHIN its round on one machine, because a
shared workstation's absolute millisecond is not a result. Two of the four
returned a finding that contradicts the brief that asked for them, and both are
recorded as the ruling rather than buried in the win.*

### RR-38 — The zebra loop gets a junction early-out, the pose layer gets an exact cache, and BOTH proved that an algebraic identity is not a codegen identity (doc 11 §2.1.2, §2.16, §2.13)

**(a) The street.** RR-33 priced `road_surface.gdshader`'s four-leg crossing loop
at **0.107–0.109 ms at Z0, 2.4× every wear term put together**, painting only on
junction tiles, and named the fix: hoist the eight `fwidth()` calls, early-out on
the crosswalk mask. **Ruling: taken. `detail >= 1 && cw_mask > 0.5`.** `cw_mask`
decodes out of `v_pack`, which is `flat` — constant across a primitive, and a
derivative quad never spans two primitives — so the branch is **quad-uniform**,
which is the scope the derivative rules are written at, and `fwidth()` inside it
is legal for the same reason it is legal inside a `detail` branch. The eight
calls are four distinct values: legs 0/2 and 1/3 differ only in the sign of their
perpendicular coordinate and `fwidth(-x) == fwidth(x)` bit-for-bit. Measured,
founding city, Grand/Slacum junction, 1920×1080 Balanced, 90 + 300 frames, three
interleaved rounds: **the zebra term (`rung 1 − rung 0`) falls 0.1156 → 0.0355 ms
at Z0/21 (−69 %) and 0.1096 → 0.0427 at Z0/13 (−61 %)**, against a rung-0
control — the same program in both arms — that agrees to +0.0008 and +0.0076.
The brief asked for a halving.

**(b) The scar, in a second place.** RR-33's first attempt failed pixel identity
by regrouping `1 + patch + seed` into `(1 + seed)(1 + patch)`. This one failed
the same way. Legs 0 and 2 provably share their `dashes()` call and their
carriageway clip, and `max(a,b)·k ≡ max(a·k, b·k)` for `k ≥ 0` because
correctly-rounded multiplication is monotone — algebraically exact, and it moved
**1 pixel of 2,073,600 at hour 21 and 4 at hour 13, at rungs 1 and 2 and never at
rung 0**, which places the difference inside the zebra block beyond argument.
**Ruling: the fold is rejected and the shader records why.** The shipped form
hoists the derivatives and adds the branch and changes no expression, and is
**byte-identical at Z0 at every rung and both hours** — Z0 being the only pose
where a same-build control run is itself byte-identical, so the only pose with no
noise floor. **General: in this file the contract is the PICTURE, not the
algebra, and the only safe transformation is one that leaves every surviving
expression as the same operations on the same floats in the same order.**

**(c) The site poses.** RR-32 split the construction layer's 0.53 ms at 20 sites
into 0.32 ms of pose computation and 0.09 of upload. **Ruling requested and
GRANTED: `ConstructionActivity` may cache poses, keyed off discrete facts,
provided the cached stream is BIT-IDENTICAL to the uncached one.** It is exact by
construction rather than by tolerance: the `Pose` objects are pooled and never
reallocated, so a site whose slice of a pool has not moved and none of whose
facts have changed is already carrying the floats this frame would write, and
skipping is declining to write the same bits twice. Three keys, each with exactly
one writer — `layout_serial` (bumped by `_lay_out_fittings` and
`_lay_out_barriers`, which every re-route and every stage change passes through),
`stage`, `delivered` — plus one rule that is easy to miss and is the only way a
slice-index cache can be wrong: **a site that did not emit on the immediately
preceding pass re-emits unconditionally**, because `radius` or `limit` may have
handed its slots to somebody else while it sat out. Measured with
`tools/profile_construction.gd` (headless, real network, both arms in ONE process
alternating inside each round): **0.2179 → 0.0964 ms at 20 sites (−55.7 %) and
0.3046 → 0.1357 at `max_sites` 28 (−55.4 %)**, against a 0.10 ms target, with
HEAD's own two columns agreeing to −0.0 %/−0.7 % as the noise floor. Confirmed
end to end in the shipped harness, where the figure also carries `_service_routes`
and the upload: `tools/profile_frame.gd --sites=20` reports **0.354 → 0.213 ms
(−40 %)** at Z1/hour 13 over three interleaved rounds, arms nowhere near
overlapping. The contract
is a property test over a scripted 700-frame timeline with irregular steps, stage
changes and a walking focus gate, comparing every field of every pose.

### RR-39 — A dirty-set congestion pass CANNOT skip an edge, and the census is the proof (doc 10 §2.10, §9.3 C-3, doc 91 D-15, doc 11 §2.13)

Doc 11 §2.13 named "a dirty-set congestion pass" as one of two honest next steps
for the fine tick. **Ruling: the skip-edges form is REFUSED, and the reason is a
measurement rather than an argument — `3,092 of 3,092` edges move on an ordinary
pass on the benchmark city.** `hour` reaches every edge through `D_tod(district,
hour)` and the smoother `c ← c + (c_raw − c)·α` never lands on its target, so the
skippable set is empty and always will be. An implementation that skipped an edge
whose closures and condition had not changed would not be an optimisation; it
would be a different simulation, and the state hash would say so. The census is
`CongestionModel.last_moved` and `tools/profile_congestion.gd` prints it, so the
refusal stays checkable rather than becoming folklore.

**What IS a dirty set here, and it is taken.** Each edge's road CLASS and
DISTRICT hold still between passes, and those two are the whole of `c_raw`'s
shared factor `K_base(class) · D_tod(district, hour)`. The (class, district)
pairs are resolved once per graph and priced once per pass; the per-edge loop
reads an index. The key is exact: `district_id` is written only by
`RoadNetwork._assign_districts` and `road_class` only where an edge record is
built, and both are followed by `_refresh_all_edge_state`, which invalidates the
table; `graph_version` is carried as well. Association is preserved to the term —
`K · demand · dens · evt` binds left to right, so `kd = K · demand` then
`kd · dens · evt` is the same float, which is RR-38(b) applied to arithmetic
instead of to a shader. Three whole-graph sweeps go with it, all exact:
`mean_congestion()` folded into the pass that has just written every value it
would sum (same ids, same ascending order, same additions — and the DIRTY-set
callers still take the second sweep, because their id list is not the graph); the
district roster memoised on `graph_version` (the WEIGHTS are still fetched fresh
every pass, because doc 09's land use moves under the roster without moving it);
and `dark_signal_counts_by_edge()` early-outing on a count `refresh_signal_power`
maintains for nothing — **its own doc comment claimed O(dark nodes) and it was
O(all nodes)**, 0.28 ms a game-minute for an answer that is `{}` whenever every
signal is lit.

Measured: **`RoadNetwork.full_pass` 7.7568 → 3.5902 ms per game-minute (−53.7 %)**
on the benchmark city; `roads_congestion` **5.205 → 4.127 ms/tick (−20.7 %)** and
the fine tick **17.20 → 16.06 (−6.7 %)**; on the starter city `roads_congestion`
**0.873 → 0.668 (−23.5 %)**, fine tick **1.801 → 1.592 (−11.6 %)** and the coarse
step **9.39 → 8.18 (−12.9 %)**. Three interleaved rounds against HEAD, no arm
overlapping. **Hash-neutral on both cities, coarse and fine.** D-15 narrows
again: `roads_congestion` is no longer the largest term on the bench city's fine
tick.

### RR-40 — The write half leaves the main thread; the LOAD cannot, and the save's expensive half was never the write (doc 08 §2.7, §2.14, doc 13 §2.2)

RR-37 measured save and load as synchronous and named the synchronous write as
the fault. **Ruling: `SaveManager` splits into `capture_save` (main thread — it
reads LIVE sim state and is the whole reason a save is deterministic) and
`commit_save` (bytes only), and `SaveService.async_writes` hands the second to
`WorkerThreadPool`.** The API keeps its shape: `save_slot` still returns the meta
dictionary at once, because the header is built from the capture and not from the
file, and `saved` still fires exactly once per successful write — later, and on
the main thread. Every reader of a slot flushes the queue on the way in, so
nothing in the codebase can observe a half-written ladder;
`NOTIFICATION_PREDELETE` / `EXIT_TREE` flush too, so a process that ends with a
write queued still lands it. **One write in flight per service**, because
`commit_save` reads the generation number out of the manifest and two commits
would race for it; a second request settles the first.

**`SYNC_REASONS` is normative: `pause`, `quit`, `pre_migration`, `pre_catchup`
commit before the call returns.** Doc 13 §2.2 gives the process no promise that
it survives the pause callback, and a dispatched write is not a committed one.
`AndroidLifecycle` already tags its lifecycle save `pause`, so that path is
synchronous whether or not the shell ever sets `async_writes`; `game/main.gd`'s
two quit paths need the reason `"quit"` and that is an integration snippet, not a
change made here.

**Two findings that contradict the brief.** `tools/profile_save.gd` now reports
both halves of both operations, and:

1. **The save's expensive half was never the write.** Of the benchmark city's
   148.7 ms save, the write is **52.4 ms** and the capture is **96.3** —
   `canonical_capture()` walking the roster and floating every number into
   `"~f~%08x%08x"` costs nearly twice what stringifying, digesting, compressing
   and writing the result does. Threading the write takes the caller's cost
   **148.72 → 97.54 ms** on the benchmark city and **16.54 → 11.99** on the
   founding one: a third off, not the seven-eighths the framing implied. Worth
   taking; the next lever on this path is the capture.
2. **Streaming the load is costed and REFUSED.** Its split is **35.2 ms of
   reading** (decompress, parse, SHA-256, the seven-check gate, section
   deserialize) against **442.6 ms of `restore_state`**, which rebuilds the live
   city and can no more leave the main thread than the capture can. A threaded
   reader would move **7 % of a 484 ms load** in exchange for a background
   thread, a progress model and a re-entrancy contract on the load gate. Doc 08
   §2.14 carries the design and the arithmetic so the next person to want it can
   see it was priced. **Re-open only if `restore_state` itself is chunked** —
   that is the load's real lever, and it is doc 08's call, not a render branch's.

The recovery contract holds through all of it, and it is tested rather than
asserted: a kill BEFORE the generation rename leaves an orphan `.tmp` and the
previous city still active and still loading; a torn ACTIVE generation is refused
by the digest gate, MOVED to quarantine so the next boot does not pay for it
again, and the generation behind it comes back with `last_load_lost_minutes` set
to the difference between the two captures.
