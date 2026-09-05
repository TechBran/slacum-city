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

**(f) Gates 20 and 21 are re-fitted; the other 26 are untouched.** Gate 20: `ladder.size()` 6 → 7, every other claim in it unchanged. Gate 21: the horizon moves 21 → **45 game-days** with a ruled bound of **40** on the top level, against a measurement of 31.1 / 33.5 / 34.3, and **level 5 is now asserted separately against the old 21-day horizon** so "the arc got longer at the top and not underneath" stays provable. Doc 92 §24.9 is the fit.

**(g) Hashes: the starter city does not move; the bench city moves through exactly one key, and the A/B proves it.** Starter coarse/fine are byte-identical. The bench fixture settles at **35,411 residents**, which a seven-rung ladder reads as city level **6** where a six-rung one read 5, so its `progression` section carries a different level and one more milestone. Removing the L6 curriculum row changes nothing; putting the ladder back to six rungs reproduces the Wave-9 baseline byte for byte. The sixth building rung, the L6 meshes, the new `upgrade_time_hours` column and `Building.max_level` are all hash-neutral. **`tools/profile_sim.gd` needs exactly one baseline refresh — the bench city's two digests — and it is published in doc 92 §24.12 rather than made from this branch.**

**(h) One defect is REPORTED, NOT FIXED.** `CitySim.cmd_upgrade_building` reads `upgrade_time_hours` from the row of the level being upgraded TO, where doc 02 §2.2 stores the price of the step `L → L+1` on the row being upgraded FROM — so every upgrade in the game runs one rung's duration too slow, and the last step of every ladder (which has no such row) ran on a bare `4.0`-hour literal. This wave changes only the **fallback**, from that literal to the row below, so the final step reads doc 02's own number instead of a placeholder and every step that already had a figure is untouched. Fixing the off-by-one itself moves every upgrade duration in the game and is a balance pass, not a content one.

**(i) The measured surprise, recorded for doc 04.** The first three-seed run of the new curriculum level failed on two of three seeds at 45 game-days, and the gate said `E_POWER_HEADROOM` on **every single** level-5 house in both cities (25 of 25, 32 of 32). That is doc 02 §8's `k_dem > TAX_LEVEL_GROWTH` working exactly as ruled — a `house` goes 91 kW → 215 kW across the sixth step, more than a whole level-2 transformer — and the fix is copper at the building that was refused, which a level-3 transformer supplies for $2,800 against a $73,572 upgrade. The `curriculum` agent now does it and all three seeds complete. **The tower tier is therefore affordable but fiddly while doc 04's feeder verb is unlanded** (doc 92 F-11): it is the first content in the game that requires the player to read a power refusal and act on it. Doc 92 §24.8 is the measurement.

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

## 21. WAVE 10 FOLLOW-UPS — the reported defect gets fixed (binding)

### RR-38 — The price of an upgrade step lives on the row it starts FROM, and every step in the game was billed the next rung's duration (RR-29(h) closed, 2026-08-20)

RR-29(h) reported the defect and deliberately did not fix it: *"fixing the off-by-one itself moves every upgrade duration in the game and is a balance pass, not a content one."* This is that balance pass.

**The defect.** `CitySim.cmd_upgrade_building` read `upgrade_time_hours` from `next_stats` — the row of the level being upgraded **to**. Doc 02 §2.2 stores the price of the step `L → L+1` on the row upgraded **from** (`upgrade_time_hours(L) = 0.65 × build_time(L + 1)`), which is exactly the shape `BuildingCatalog` validates at load: every row below the top carries the column, the top row must not. So the command was billing each step the rung above's duration, and had been since the verb shipped. **One rung too slow, all the way up every one of the twelve ladders.** The single step that was already correct is the LAST one of each ladder: its `next_stats` is the top row, which carries no column, so the old read missed and fell through to the same cell the new read takes first (that fallback is RR-29(h)'s own Wave-10 change).

**The fix is the two halves of one `get()` swapped**, and nothing in `data/` moved. Every figure it changes is a cell doc 02 already authored, now read by the step it was authored for: a `house` L4→L5 goes 7.0 crew-hours → **5.0**, a `high_rise` L4→L5 goes 148 → **87**, and a full climb from L1 to the top of a ladder is **20–28 % faster** across the roster (doc 92 §27.2 is the full table). The fallbacks stay, reversed, so the read is still TOTAL against a hand-edited table.

**`CitySim.SAVE_SECTION_VERSION` moves 4 → 5** — the upgrade-timing epoch — with an identity migrator. It is the smallest rung this ladder has and the clearest illustration of what the ladder is for: no key on either side of the migration means anything different, and a v4 body advanced under v5 rules still produces a city v4 never would have, because every upgrade the player starts after the update completes sooner and everything downstream of a completion minute moves with it. **`_v4_to_v5` deliberately does not re-price the jobs already in the body**: `ConstructionQueue` serialises `required_crew_hours` per job, so an upgrade in flight across the update finishes on the bill it was quoted. Re-pricing a paid-for job downward mid-flight is a gift and upward is a theft; leaving it is the only one of the three that is a record.

**Hashes, and the one that says the fix has exactly one door.** `tools/profile_sim.gd` is **byte-identical on both cities and both paths** — its identity pass never issues a player command, so a digest taken with nobody in the loop cannot see a change to what a command costs, and **no baseline refresh is needed**. The `curriculum` agent's 45-game-day end-state hash moves on all three doc 92 seeds. In the 21-strategy-run matrix, **`do_nothing` and `infrastructure_first` reproduce every column to the printed digit** — both report `upg` 0 — while the five agents that do upgrade all move. That pair is the control: it proves the change reaches the sim through `cmd_upgrade_building` and nowhere else, and it is what licenses doc 92 §27.7's claim that this pass cannot have moved the ambient-incident arm.

**A standing debt found while taking those digests, which this branch did not create and does not pay.** None of the four `profile_sim` digests published in doc 92 §24.12 / §25.2 reproduce at HEAD *before* this branch touches anything: those sections quote starter `2231df75…` / `bffdf583…` and bench `8b4e0079…` / `aea5370b…`, and the tree returns starter `18e70625…` / `4c3c52cd…` and bench `d6b2509c…` / `bf8dc728…`. The Wave-9 integration merge and the two commits after it moved them and nothing re-published. **The absolute digests in those two sections are stale and belong to whoever owns the next integration**; doc 92 §27.3's table is a valid *identity* result either way, because both of its columns were measured at the same fork.

**What it does NOT buy, recorded because the brief predicted otherwise.** Faster upgrades were expected to shorten the curriculum. They do not: the arc finishes on game-day 34.5–36.1 against 34.5–36.5 before, levels 1–3 do not move by a single game-hour, and levels 4–6 move a few hours in *both* directions across the three seeds. A re-timed completion re-seeds the draws after it; it does not systematically hurry a level that is gated on saving or on incident arrival. The fix is worth making because it makes the binary do what doc 02 says, not because it buys pacing.

### RR-39 — Doc 92 §22's 10–40 game-hour curriculum band is retired for a three-tier beat, because deleting the objective under test does not reach it (2026-08-20)

Wave-9's road-UI open question 4: curriculum level 3 measures **59–64 game-hours** against §22.3's ruled 10–40 band, and was outside it (44–48) before the street row existed. Fix the band or shed the objective?

**Measured, three arms, one instrument** (`tools/measure_curriculum.gd`, seeds 1337/4242/9001, the only difference between arms being `l3_streets`): 4 tiles (shipped) → **59–64**; 2 tiles → **51–52**; the row deleted entirely → **44–48**. **Deleting the whole objective does not reach the band.** The row is the smaller half of the overrun, and the deleted arm reproduces doc 92 §25.3's pre-row column (`97 / 98 / 103`) to the digit on a different tree — the control the ablation needed.

**The band also contradicted its own table on the day it was written.** §22.3 claims "levels 1–3 land inside the 10–40 game-hour band" one line under a row printing level 2 at **39 – 41**. Level 2 has measured 39–41 on every tree since, including this one.

**Ruling: one band becomes three tiers** — **opening** (levels 1–2) ≤ **45** game-hours, **middle** (levels 3–4) ≤ **90**, **finale** (levels 5–6) bounded in game-**days** by gate 21's existing `LONG_DAYS` / `CURRICULUM_TOP_LEVEL_DAYS` and given no hour band at all. Three reasons, in order of weight: **(a)** a game-hour is a minute of *attention* only while the app is open, and doc 08's offline catch-up is the other half of the product — the band was serving a session length the design does not ask anyone to sit through; **(b)** a doubling cadence cannot fit three levels inside a fixed window, and §22.3 named the cadence itself two paragraphs above the band, so the ruling was self-contradictory from the start and every pass that added anything to the arc was going to break it; **(c)** the alternative was measured and cannot deliver.

**It is a test, not a sentence.** Gate 21 gains `CURRICULUM_OPENING_BEAT_H` (45) and `CURRICULUM_MIDDLE_BEAT_H` (90) as executable ceilings on the first four levels' durations — the lesson §18.6 had to be taught twice, applied on the first pass this time. **Level 4's ceiling is the same number and claims less**, and the gate's docstring says so: its duration is an incident wait against gate 19's own ambient rate, §25.3 has measured it as wide as 89 game-hours, and 90 is one hour above that historical worst case — a runaway detector, not a fit. No FLOOR is asserted at either tier, because a level that got faster is not something this gate can tell apart from an improvement. **No ruled bound moved and no other gate threshold moved. `data/goals.json` is untouched**: `l3_streets` stays at 4 tiles, because four tiles is an L with a corner in it and 2 is a straight line — buying 8–12 game-hours by deleting the only corner in the curriculum is not a trade worth making.

### RR-40 — A doc-05 placement is a purchase and must sound like one; an event table keyed on `building_placed_sim` opts water out silently (2026-08-20)

`cmd_place_water_component` builds a real doc-02 building (its own step 1) but announces it on doc 05's `water_component_placed` rather than on `building_placed_sim`. That is the same shape as the pump-station render bug fixed on 2026-08-20 — the shell was invisible until relaunch because `game/main.gd`'s translator only knew the doc-02 event — and it had a second instance nobody had looked for: `data/audio.json`'s cue table maps `building_placed_sim` to `purchase` and had **no row for water at all**. `water_component_placed` was in `AudioEvents.OBSERVED_TYPES`, so the construction-site bed followed the pump and the crane could be heard working on it, and the confirmation blip at the moment of purchase never played. **The most expensive single purchase in the game — doc 05's $45,000 pump, the whole of curriculum level 5 — was the one purchase that made no sound.**

**Ruling: every event that creates a Building must be checked against BOTH tables — the renderer's translator and the audio cue map — and doc 11 §2.15's wired set gets a row per EVENT, not per concept.** The fix is one rule in `data/audio.json` carrying the same cue, key, dedup and cooldown as the building row (`attenuation: none`, because a purchase confirmation is the player's own action and is always crisp), one row in doc 11 §2.15's table, and one entry in `tests/test_audio_model.gd`'s event→cue map so the next silent verb fails a test instead of shipping. **Unverified on device:** this is a workstation reading of the cue path, not the lead's ears on a Fold 6 — the cue resolves, the rule matches and the test asserts the mapping, but nobody has heard it.


### RR-41 — The verb table is empty of doorless rows, and the panel the last three asked for was not built (docs 04 §4, 05 §6.1, 10 §2.13, 12 §2.7/§2.9, 91 §14.5 D-4, 92 §27, 93 §J1–§J3)

Three surfaces were outstanding after Wave 10 and every one of them had been
deferred for a reason rather than missed. **All three are closed, and two of the
three closures are rulings against building the screen that was asked for.**

**(a) `cmd_route_feeder` is two cards on doc 12 §2.7's drag-path tool.** Doc 92
§25.7 deferred it as a *balance* change — §17.3 names the 2 × 1,200 kW feeder
ceiling as the late game's binding constraint — so it got the pass and the matrix
it asked for (doc 92 §27), and the full **7 strategies × 3 seeds × 21 game-days**
matrix is **byte-identical**, all 30 rows, diffed field by field. The reason is
worth recording because it is not the obvious one: the verb has been *in* the
matrix since Wave 6, driven by `Balanced` through the one-tap door the build
sheet would use, so a UI pass cannot move a harness that never had a UI. Three
sub-rulings sit under the card. The tab is **`infrastructure`, not `roads`** —
§2.7 files a run card by what it is made of, and a feeder belongs beside the
transformer it roots exactly as a main belongs beside the pump it feeds. The
class choice is **two cards, not a picker**, read from
`routable.feeder.conductor_classes` so a class this build does not ship never
gets one. And it is the **only run card whose geometry is not §2.7's L**:
`cmd_route_feeder` requires every tile owned and READY, a straight Chebyshev line
between two owned blocks routinely crosses one the city does not own (doc 04 §4
records that as the whole of seed 4242's late-game routing failure), so the run
is filled by `suggest_feeder_route` — the C-41 assist — which returns the
shortest LEGAL run and, on a per-tile price, therefore the cheapest. The ghost
still draws exactly the tiles the commit will lay.

**(b) There is no water-node panel, and there should not be one.** Doc 05 §6.1,
doc 93 §B2 and doc 91 §14.5 **D-4** had all carried the same sentence since Wave
5: `cmd_upgrade_water_component`, `cmd_isolate_water_main` and
`cmd_restore_water_main` "want a water-NODE panel doc 12's screen map does not
have". They do not. They are **two verbs at two moments**, and the moments decide
the surface (doc 93 §J1): *upgrade* is a purchase against a standing asset, and
the asset already has a panel — the doc-02 `water_facility` SHELL the node is
hosted on — so it is a block there, as a **list**, because `WTR-1` hosts three
nodes and a panel showing one would be lying about the other two. *Isolate and
restore* is a trade taken under time pressure about a MAIN, and a main has no
footprint, no panel and no way to be selected; the only place one is ever named
to the player is doc 06's `water_main_break`, whose `target_ref` is
`{kind: "water_segment", id}`, so the valve goes on the drawer row that is
already telling them the main is open. **One control in two moods**, never two
buttons, because the two are never both available. The trap — a main isolated and
then orphaned — cannot happen: doc 05's own `set_segment_repaired` clears the
flag and doc 06 calls it on resolve, so every main the drawer can valve out
un-valves itself when the crew finishes. **And isolation already persisted**:
`WaterEdge.serialize()` has carried `state` since Wave 1, so the surface needed
**no save-section bump** — asserted by a test rather than assumed, because the
ruling turns on it. D-4 is closed.

**(c) `RoadNetwork.cmd_road_repair` is not a player verb, and the row is closed
rather than carried.** Doc 10 §2.13 had recorded it as an open question since
Wave 5. Doc 93 §J3 and doc 10 now rule it out, on four grounds that bind in
order: §2.12 **already names the player's surface** and it is the *policy*
(`auto_repair_threshold`, `auto_repair_daily_cap` — this doc's own words: "a
player budget setting, not a price"); the policy picks better runs than a thumb
can, sorting contiguous runs by `(mean congestion desc, condition asc)` against
information doc 12 gives the player no overlay for; a manual verb would spend the
same C-16 dollars **outside `auto_repair_daily_cap`**, which is the only thing
holding road repair inside doc 03's derived routine-repair line; and doc 02's
per-building `REPAIR` is not a precedent, because a building is a discrete asset
the player taps and a road tile is not. What remains open is strictly smaller and
is doc 10 §9.4 question 5 restated: **the policy's two dials have no door
either**, and they want a settings row on the `policy:` mechanism doc 12 §2.13
already ships for doc 06's dispatch policy.

**The `sim/` cost of all three: eight lines.** `IncidentSystem.snapshot()` now
publishes `target_ref` — a field `incident_created` has always carried — so a UI
that comes up on a loaded save, which replays no lifecycle event, knows which
main a break is about. The save is `canonical_capture()` and the snapshot is not
hashed; `profile_sim --hash-only` is **bit-identical on both cities and both
paths**, with the change reverted and re-applied.

---

## 22. WAVE 10 — the performance ladder (binding)

*Four levers, each already named and priced by an earlier session, taken and
re-measured. Every arm is interleaved WITHIN its round on one machine, because a
shared workstation's absolute millisecond is not a result. Two of the four
returned a finding that contradicts the brief that asked for them, and both are
recorded as the ruling rather than buried in the win.*

### RR-42 — The zebra loop gets a junction early-out, the pose layer gets an exact cache, and BOTH proved that an algebraic identity is not a codegen identity (doc 11 §2.1.2, §2.16, §2.13)

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

### RR-43 — A dirty-set congestion pass CANNOT skip an edge, and the census is the proof (doc 10 §2.10, §9.3 C-3, doc 91 D-15, doc 11 §2.13)

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
`kd · dens · evt` is the same float, which is RR-42(b) applied to arithmetic
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

### RR-44 — The write half leaves the main thread; the LOAD cannot, and the save's expensive half was never the write (doc 08 §2.7, §2.14, doc 13 §2.2)

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

### RR-45 — Three affordances shared one corner and nobody solved it; and a modal that outgrows the phone GROWS, it does not clip (doc 12 §2.3, §2.6, §2.13, D-16)
Two pre-existing sweep failures, both invisible at 100 % text and together worth more findings than everything else in the deck. **(a) The bottom-right corner.** `PanelLayer/IncidentDrawer/Handle`, `AlertsCenter/Chip` and `EventLog/Chip` are three edge affordances in three files, each carrying a hard-coded offset pair authored for a 48 dp target. At 130 % text with larger touch targets the chips measure **100 dp** tall against a 56 dp pitch and the handle **94 dp** wide against a 56 dp reserve, so they collided: **73 `overlapping_targets` findings on every supported box — 360, 412, 794, 880 and 1280 alike — across 36 of the 50 preview screens.** D-16 had already ruled the *pattern* for the other corner ("edge affordances yield their edge") and `AlertsCenter` had already grown a per-frame patch for one of the three pairs, polled in `_process` and therefore a frame stale — which is why the first screen of every sweep measured a *worse* overlap (3 872 px²) than the rest (1 848 px²). **Ruling: a corner with more than one affordance in it is a RAIL, and a rail is solved in one place from the same tunables, exactly as D-13's left-hand `rail_slot()` is.** `UIWidgets.solve_corner_rail()` is that place; membership is duck-typed like `close_siblings()` (`corner_rail_entry() -> {control, index}`), the tab keeps the edge, the chips stack in the column beside it, and a hidden affordance is skipped so the ones above it close the gap. The property that made it safe to land: **at 100 % text with 48 dp targets the solver reproduces the scene's authored offsets exactly**, so no screenshot in the repo moves. **(b) The two sheets.** `SettingsSheet` and `SaveLoadSheet` are full-screen modals anchored to the display with `grow_horizontal = BOTH`, which means a minimum size larger than the display does not clip — it **centres the overflow**, exactly as D-12 found for the top bar. `Emergency contractors` (201 dp) beside its value chip (183 dp) is a **392 dp** `HBox` row; `SAVE · LOAD · DELETE` are 110 + 120 + 134 = **380 dp** of another. Both made a **420 dp** sheet on a 360 dp phone, sitting at x = −20, with the sheet's own ✕ ending at 380 of 360 and `MANAGE SAVES` laid out 400 dp wide off the left edge — i.e. **the only way out of the settings sheet was itself off the screen.** Note what the header did NOT do wrong: it measures 242 dp and fits, and eliding the title further would have changed nothing. **Ruling: a row inside a sheet wraps rather than widening the sheet** — `HFlowContainer` asks for its widest child where an `HBox` asks for the sum, it costs nothing at the reference box (both rows still lay out on one line at 880 dp with the label expanding and the value flush right), and it is the only fix that keeps working as the player's text-size setting grows. Whole-deck after: **0 findings of any kind at 360×800, 412×915, 794×924 and 1280×720, at 100 % and at 130 % with larger targets.** The 880 × 400 landscape box still carries 153, none of them from either fix — 147 top-bar chips overlapping between wrapped rows on a bar only 392 dp tall, and 6 title/pause/banner controls off the bottom — recorded in doc 12's Wave-11 note as the next wave's work.

### RR-46 — No dev argument had ever reached the game on device, and the fix belongs in the plugin (doc 13 D-20, §2.6)
`OS.get_cmdline_user_args()` answers `[]` on the shipped Android export template no matter what the launch carried, which the 2026-08-20 device session proved twice over: `--zoom=0.0` and `--zoom=0.5` produced byte-identical `dc`/`prim` sequences, and `--rain=1.0,--overlay=2` came up in clear weather with no overlay. The city loaded on every launch anyway — through `CrashSentinel`'s recovery branch, because `am force-stop` registers as an unclean exit — which is precisely what disguised the fault for as long as it lasted. **Everything downstream was blocked:** doc 13's D-17 save/load timing (its three arms are *selected by arguments*), D-18's six-pose day/night matrix, `--save-now`, `--advance-hours` and the whole §2 scenario vocabulary. The extra is on the Intent and `GodotAppLauncher` is an `activity-alias`, across which Android forwards extras, so the loss is inside the template's own command-line plumbing. **Ruling: we do not patch `android/build/` — doc 13 §10.5 keeps that patch set empty on purpose — so the plugin reads the Intent itself.** `SlacumNative.launch_args()` returns `command_line_params` (string array) plus `args` (string, whitespace-split) verbatim; `game/dev_args.gd` applies Godot's own "everything after `--`" convention to that half and merges it with the engine's list. **The de-duplication in that merge is load-bearing rather than tidy:** the day an engine build starts forwarding the extra, both halves carry the same strings, and `--advance-hours=4` counted twice would silently run the city eight hours forward before the first frame. Two argument forms are accepted because forgetting the `--` separator inside a comma-joined array is the single most common way a device window loses its scenario — `--es args "--resume --zoom=1.0"` has no syntax to get wrong. Verified off device: 10 cases in `tests/test_dev_args.gd`, `launch_args()` present in the exported APK's `classes.dex`, and an 89.2 MB debug APK that `aapt2` and `apksigner` both read clean. **The device half is unverified and is the next session's first act:** §1.2's probe, `--zoom=1.0`, judged by where the camera actually is.

---

## 23. WAVE 10 — the completeness re-audit (binding)

### RR-47 — A coverage claim is a JOIN, and every join in this project gets a test or an id (doc 91 Part II, doc 92 §17.6.1)

> *The count in this ruling is the Wave-10 one, at `a892315`, and it must not be quoted after 2026-08-21: **RR-71 measures 169 of 187 (90 %)**, on a basis two rows wider. Doc 91's re-derived table is the authority. The ruling itself — a coverage claim is a join — is unaffected and is the reason the number can be re-derived at all.*

Doc 91 was written post-Wave-4 against a 1,249-test tree and patched piecemeal for six waves while HEAD grew to 1,890. Re-derived against `a892315` it moved **thirteen rows up, three rows down, and found ten sections of docs 01–13 that had never been counted at all** — 183 rows against the 173 it claimed, 161 SHIPPED (88 %). The three downward moves are the finding, because each is the same failure and none of them is a bug in any subsystem:

* **doc 03 §2.9 SHIPPED → PARTIAL.** The row's own pointer, `data/difficulty.json`, **is not in the tree**, and neither is `sim/economy/difficulty.gd`, the loader §2.9 names. `Treasury.DIFFICULTY_STANDARD` is compiled in and `CitySim` never passes a difficulty, so three of four authored presets are unreachable and `data/economy.json` announces a move to a file nobody wrote. A scan of every backticked path in doc 91 found this one and only this one.
* **doc 07 §2.4 SHIPPED → PARTIAL.** `FloodField` fires `flood_level_changed` 460 times in a two-hour soak and **nothing consumes it** — `WeatherFX` matches three types and that is not one of them. The simulation is right and the player never sees water.
* **doc 12 §2.18 SHIPPED → PARTIAL.** The 100 % sweep is clean at all five boxes (D-12 and D-13 both closed and re-verified), and the **130 % + `larger_touch_targets`** sweep fails at all five — including a settings sheet whose ✕ is off-screen at 360×800 and a title screen whose START NEW is off-screen at 880×400. §2.18 calls those two settings release gates, and the suite *does* have an a11y assertion — `get_combined_minimum_size().x <= 360.0` at `(1.3, true)`, one axis, one box, full-width panels only. **Every failure found is an overlap or a Y-axis overflow**, so the gate passes and the requirement does not hold: the check is the wrong shape, not absent. **And the box A2 names — 640 × 340 dp, which is `data/ui.json.layout.min_safe_box_dp`, the project's own declared floor — is in no `BOXES` list at all**: measured for the first time here it fails at 150 % on all 49 states, and at **100 %** it puts the title screen's CANCEL 26 dp off the bottom (A91-D-29). A requirement whose own geometry nothing runs is not a gate.

**Ruling, in one sentence: a per-section grade cannot see a join, so every join this project depends on gets either a test or a defect id, and never a prose assurance.** Four joins were swept and each got one of the two:

| Join | Instrument | Result |
|---|---|---|
| roster row → textured asset | **`tests/test_asset_completeness.gd`** (new; 19 tests, 3,167 asserts) | **green at HEAD**, nothing xfail'd |
| `cmd_*` → player door | doc 91 §17, doc 92 §17.6.1 | 18 of 23; A91-D-24 |
| event name → consumer | doc 91 §18 | 58 of 121 wired; A91-D-26 — **closed in RR-48**, and the instrument is now `tests/test_event_matrix.gd` |
| screen × box × a11y setting | `tools/ui_preview.gd --audit --strict`, 12 sweeps | 5 of 12; A91-D-21/22/23, and A91-D-29 at 640 × 340 — the box A2 names and no `BOXES` list contains. The harness also covers only 14 of 15 screens, A91-D-28 |

The asset test is the shape the other three should take, and its own first run is the argument: it failed twice before it passed, and **both failures were in the sweep rather than in the tree** — an equality rule where the invariant is monotonicity (twenty LOD1 meshes are legitimately shorter than their LOD0, because `lod1_volume_keep_frac` drops the non-signature roof props, and it is safe only because `CityView` builds `_far_scale` inside a `lod == 0` arm), and a page-group reader attributed to the wrong class. A join test that never disagrees with the author is a join test that was written from the same assumption as the code.

**Consequential and general: the three `D-nn` id spaces are ended.** Doc 91, doc 12's delta table and doc 13 §7's device matrix all number defects `D-nn` in unrelated sequences, which has already forced one renumbering (2026-08-19, the second `D-14`/`D-15` collision in two waves). From this date **doc 91 files `A91-D-nn`**, and the number CONTINUES doc 91's own sequence rather than restarting — the Wave-10 rows are `A91-D-19` … `A91-D-28`, because `A91-D-01` sitting beside `D-1` would be the same ambiguity in a new coat. Existing rows keep their ids, because renaming them would break every cross-reference in `docs/` and in code comments a third time. Doc 12 and doc 13 should take `A12-D-nn` and `A13-D-nn` when they next file. **Reading rule: an unprefixed `D-nn` belongs to whichever document you found it in.**

**And one thing this ruling explicitly does not do.** It does not re-open any balance number. The re-audit changed no `sim/`, no `data/`, no `game/`: `tools/profile_sim.gd --hash-only` reports `18e70625e633c254…` / `4c3c52cdb4c5a3cc…` on the founding city and `d6b2509c179987d3…` / `bf8dc7282758843b…` on the benchmark city at `a892315`, before and after, and the 28 gates are untouched. **A91-D-19 is the one finding with a balance consequence and it is a statement about coverage, not about tuning**: every figure doc 92 has ever published was measured on `standard`, because `standard` is the only preset the code can reach.

### RR-48 — A difficulty preset is a property of a CITY, and the file the docs have pointed at for six waves now exists (doc 03 §2.9/§3.4, doc 06 §8, doc 07 §8.3, doc 08 §2.3/§2.8, doc 91 A91-D-19, doc 92 §29, doc 93 §K1/§K2)

RR-47 closed by naming **A91-D-19 as the one Wave-10 finding with a balance
consequence**, and by saying the consequence was coverage rather than tuning.
This entry is the fix, and the interesting part is that measuring the other three
presets for the first time found something neither document predicted.

**(a) What was actually broken, restated once.** C-17 ruled in Wave 3 that every
difficulty scalar lives in `data/difficulty.json` behind one loader. Three
documents then wrote "MOVED" notes into their own data files pointing at that
path, and **nobody wrote the file**. What shipped instead was
`Treasury.DIFFICULTY_STANDARD` compiled into a class, a read-only mirror of doc
07's pressure rows in `data/director.json`, doc 06's escalation rows parked in
`data/incidents.json` and read by nothing, and doc 08's `difficulty_offline_mult`
authored in a doc and filed nowhere. Three files, three readers, one of them
unreachable — against a ruling whose whole content is "one file, one loader".

**(b) Ruled and shipped: the whole section, not the cheap half.** A91-D-19's own
filing recommended writing the file and leaving the selection UI for a later
wave. The lead ruled otherwise and the ruling was right: a preset that no player
can choose is the same defect one level up — a table the code can reach and the
player cannot. So `data/difficulty.json` ships with all four sections × four
presets, `sim/economy/difficulty.gd` is the one loader, `CitySim.boot()` resolves
it before the treasury (the founding balance is one of its knobs),
`CitySim.found_with_difficulty()` is the founding seam, the front door carries a
cycling chip, S9 reports it read-only, and doc 08's city section moved to **v6**.
The three stranded copies are **deleted**, and `DirectorTables` and
`IncidentCatalog` now REFUSE a file that grows one back — a ruling that only
holds while somebody remembers it is not a ruling.

**(c) Two things §2.9 asked for that were ruled OUT rather than shipped**, and
both are in doc 93 §K1. `save.assisted` is a leaderboard flag for a leaderboard
this game does not have and has no plan to have, and mid-city difficulty changes
re-price a city the player has already paid for — twelve of the sixteen knobs are
not treasury, so §2.9's own "already-accrued treasury is untouched" escape clause
protects almost nothing. **A city is founded on a preset and keeps it for life.**
The cost is real (a player who finds crisis too hard starts a city) and it is
stated on the door in words rather than buried in a tooltip.

**(d) The preset rides the section it was already in, and that is a determinism
ruling as much as a schema one** (doc 93 §K2). `DisasterDirector.serialize()` has
written `"difficulty"` since doc 07 shipped. `state_hash()` is SHA-256 over
`canonical_capture()`, so a new city-level key would move the hash on the DEFAULT
preset — and "the default preset reproduces the pre-difficulty binary bit-for-bit"
is the claim the whole change stands on. The two requirements are compatible in
exactly one way and this is it: `_v5_to_v6` adds **no top-level key**, and
`CitySim._restore_difficulty` reads the preset back out of the `director` section
and re-pins the treasury's economic row, the pressure knobs and doc 06's
escalation pair.

**Proof, not assertion:** `tools/profile_sim.gd --hash-only` reports
`18e70625e633c254…` / `4c3c52cdb4c5a3cc…` on the founding city and
`d6b2509c179987d3…` / `bf8dc7282758843b…` on `bench_city`, before and after, both
paths; and doc 92 §29.1's seven-strategy × three-seed × 21-game-day matrix is
byte-identical to §27.6's post-fix column in **all 63 cells**.

**(e) What the measurement found, which is why this entry is not just plumbing.**
Doc 92 §29 is the first look at the other three presets. The neglect-fatal
identity holds on all four and is cleanly ordered — `do_nothing` goes insolvent on
game-day **109/76/52/35** (casual/standard/hard/crisis), strictly ordered on every
seed, each rung about 1.5× the next one's rope, all four ending with the whole
authored roster destroyed. Gate 29 pins that. But:

> **`E_roads_repair` takes the difficulty TWICE.** `EconomySystem.settle_hour()`
> computes it as `e_roads_repair(roads, m_repair)` and then sweeps it into
> `recurring *= m_exp` with the other seven lines, so it scales by
> `M_repair × M_exp` — **2.0000× on crisis** — while every other expense line
> scales by `M_exp` exactly. At $157.90/gh it is 31.3 % of the standard founding
> expense, so this one line contributes **48 % of the entire difficulty delta on
> the expense side**, and it is why the crisis founding city settles its first
> hour at **−$18.70/gh**: negative before the player has done anything. Remove the
> compounding and it is +$99.73/gh.

**It is left alone, deliberately.** The compounding is *arguable* — `E_roads_repair`
is genuinely both a recurring line (doc 03 §2.4) and a repair price (§2.5) — and
this pass was tasked to make the presets reachable and gate their sanity, not to
tune them. What it does not have is a decision, and doc 92 §29.5(a) carries the
derivation and the counterfactual. Two facts make the ruling cheap when the lead
takes it: the fix is one line, and **it is hash-neutral on the default preset by
construction**, because `M_repair` and `M_exp` are both 1.00 there.

**(f) And one finding that is not about difficulty at all, found because a
preset made it reachable in 104 game-days instead of never.** Gate 29 was first
written with a flat 120-game-day horizon; it did not fail, it **did not finish**.
From game-day 104 of a `do_nothing` `crisis` city the open incident count
multiplies by **~2.5–2.9 per game-hour** — 103 → 357 → 832 → 2,424 → 6,389 →
14,671 → 37,631 → 89,055 — with the per-game-hour wall cost following it from
0.22 s to 269 s, and no ceiling in sight. Doc 06 §2.13's own worst-case
accounting is ≤ 40 active. The Director is idle throughout (TP pinned, nothing
scheduled, zero lightning, zero flood), so this is doc 06's own generation and
spread on a city where every building is at condition 0.000 and nothing is ever
dispatched.

**It is a state, not a preset**: `standard` and `casual` were both run to 200
game-days without it. `crisis` only gets there sooner. But a game-hour that costs
269 s and doubles is an ANR on device, and the state it needs is *a city left
alone for three and a half months* — which doc 03 §2.10's recovery ladder exists
to make survivable rather than terminal. **Filed as doc 92 §29.5(b), ranked above
everything else that section names, and owned by doc 06 rather than doc 03.**
Gate 29 is written AROUND it — per-preset horizons, each its own insolvency day
plus ten days — and asserts the peak open-incident count stays ≤ 40 inside them
(measured 0–1), so that if the cascade ever moves earlier the gate says so in
words instead of hanging.

**(g) A stale table in doc 92, found by running it.** §28.2 republished §27.6's
**pre**-fix matrix column as if it were the current tree (`greedy_growth` 69,006
against a real 65,962, and four more). `do_nothing` and `infrastructure_first` are
identical in both columns, which is how it survived a read. §28.2's conclusion is
unaffected — the Wave-11 UI pass genuinely moved nothing — but the table is
superseded by §29.1 and is now marked as such. Filed here because it is the second
time in this document that *a number nobody re-ran* has been the defect, and the
lesson is the same one RR-47 drew about coverage claims: **a table that is quoted
rather than produced is a claim, not a measurement.**

**(h) One naming deviation, recorded rather than hidden.** §3.4 rule 5 names the
read path `Difficulty.get(section, key)`. It cannot ship under that name — `get`
is `Object.get(StringName) -> Variant` and GDScript refuses a method that
redeclares a native one with a different signature — so it is
`Difficulty.value(section, key)`, with `number()` and `flag()` as typed wrappers.
The rule was about there being exactly ONE read path; there is. Doc 03 §2.9 rule 3
and §3.4 rule 5 both now say so.

---

## 24. WAVE 12 — the deep save/load levers (binding)

*Wave 10 measured the two numbers and named them the next levers: `canonical_capture()` was 96.3 ms of a 148.7 ms save, and `restore_state()` was 442.6 of a 483.9 ms load. Both are taken here. Both turned out to be a different shape than the brief that asked for them, and one of the three levers the brief proposed is refused on measurement.*

### RR-49 — The float codec's bill was the WALK, not the hex — and the half that walks does not belong on the sim's thread (doc 08 §2.6, doc 13 §2.9)

**The suspects the brief named were both measured and both are wrong.** Pooling the encoder's `PackedByteArray` and replacing `"~f~%08x%08x"` with a nibble-table formatter are the two obvious optimizations of a function that produces hex strings, and the benchmark city's body contains **21,923 floats of which only 6,229 are fractional** — the other 15,694 canonicalize to ints and never touch the formatter at all. Measured on the same body, five runs, best-of: pooling the buffer is **50.60 ms against 50.34** (inside the noise), and the nibble table is **57.58 ms — 14 % SLOWER** than `%08x`. Inlining the leaf dispatch so scalars cost no function call is **50.54 against 51.44**, also inside the noise. The hex is not the bill.

**What the bill is.** The body is **112,000 Variant nodes**, and a GDScript walk that does nothing at all but visit them — no allocation, no encoding, an integer counter — costs **30.06 ms** if it recurses once per node and **14.03 ms** if it pops an explicit stack and pushes `values()` through one native `append_array`. `Dictionary.duplicate(true)`, which visits the same 112,000 nodes in C++, costs **8.77 ms**. The recursive rebuild was paying GDScript interpreter overhead 112,000 times to produce a tree the engine can copy natively in a twelfth of the time.

**Ruling: deep-copy natively, then patch the float leaves with a stack walk.** `_encode_floats` is `duplicate(true)` + `_encode_in_place`, and the decoder is its mirror. **62.4 → 36.3 ms encode and 58.4 → 34.5 ms decode on the benchmark city, with byte-identical output** (`tests/test_save_chunked_restore.gd` diffs the JSON text against a reference implementation of the old recursive walk, kept in the test file so it cannot be "optimized" alongside the thing it certifies).

**One correctness trap the rebuild was hiding, and it would have been a silent format change.** The old walk built `[]` and `{}` from scratch, so every array in the output was untyped. An in-place patch inherits the input's typing, and **three arrays in the benchmark city's capture arrive typed** — writing a `~f~` string into an `Array[float]` is a runtime error, and writing an int into one *silently converts it back to a float*, which prints `1.0` instead of `1` and changes the bytes on disk without changing anything a reader would notice. The walk therefore re-seats a typed array untyped at the moment it discovers it. `tests/test_save_chunked_restore.gd::test_a_typed_float_array_is_re_seated_untyped` is that trap, pinned.

**And the half that walks does not need the sim's thread.** RR-44 split the save into `capture_save` (main thread, reads live state) and `commit_save` (bytes, any thread), and put the whole capture — the read AND the canonicalisation — on the main side. The canonicalisation is a pure function of a snapshot. `SaveSection` therefore grows a second half, **`finalize()`**, which `commit_save` runs on the write thread; `DictSection` carries it as a Callable and `SaveService` installs `CitySim.encode_captured` there. What stays on the sim's thread is `capture_detached()` — `capture_state()` plus a native `duplicate(true)`, which is **8.1 ms and makes `capture_save`'s "nothing aliases the sim" a guarantee instead of an accident it inherited from the old codec's rebuild**. (`RoadNetwork.save_section()` alone puts three live containers into its body by reference; the recursive encode had been quietly deep-copying them for free.)

Measured, benchmark city, `tools/profile_save.gd --repeats=7`, best ms:

| | before | after |
|---|---|---|
| save, caller thread, `--async` | 85.4 | **39.2** |
| save, caller thread, synchronous (the pause path) | 125.3 | **106.4** |
| write half (now carries `finalize`) | 38.3 | 61.5 |
| save, founding city, `--async` | 10.0 | **5.2** |
| save, founding city, synchronous | 13.9 | **11.2** |

The brief's target was "capture under 40 ms bench". It is 39.2.

### RR-50 — The restore's 443 ms was one quadratic loop and one indivisible call, and only the second one needed a design (doc 08 §2.14, doc 13 §2.9)

**Half the load was a linear scan inside a linear loop.** `restore_state()` rebuilt the building roster by asking, for each of the 1,500 buildings in the body, which `_building_records` entry has a matching `grid_id` — with a scan of all 1,500 records. **1.1 million dictionary reads, 216 ms of a 426 ms restore.** Replaced with a `grid_id -> sim_id` index built once, `has()`-guarded so a body with duplicate grid ids still binds to the first record exactly as the scan did: **216 → 7.9 ms.** Nothing else changed and no hash moved.

**The rest is a design.** A restore writes the live sim, so C-22's refusal to thread the catch-up applies to it verbatim, and what is left after the quadratic loop is real work: `roads.load_section` 118 ms, `decode` 31, `world` 22, `water` 19. **Ruling: `CitySim.begin_restore()` returns a `RestoreCursor` — eleven labelled, resumable steps the shell spends one per frame behind a veil**, and `restore_state()` is that cursor drained on the spot, so there is one implementation and not two. `tests/test_save_chunked_restore.gd` proves stepped and monolithic land on the same `state_hash()` on the founding city, the benchmark city and a body captured mid-storm mid-incident, and that save → load → **advance** stays bit-identical through the cursor.

**The veil's budget is the LONGEST STEP, not the total, which is why `roads` is three steps and not one.** At eight steps the cut left `roads.load_section` as a single 118 ms block — 58 % of the restore in one frame. `RoadNetwork.load_section_steps()` names its own three seams (`tiles` = the RLE block decode, `graph` = `rebuild_all()` plus §2.4's id adoption, `state` = everything restored against an edge id) and `CitySim` splices them in rather than cutting them from outside, because a restore that pretended to know a road loader's seams would go stale the first time that loader grew a phase. **Longest step 118 → 76.5 ms.**

| | before | after |
|---|---|---|
| load, benchmark city | 432.8 | **236.4** |
| restore half, benchmark city | 396.8 | **202.1** |
| longest single step | (not sliceable) | **76.5** |
| load, founding city | 48.4 | **45.3** |
| restore half, founding city | 45.4 | **42.2** |

The founding city barely moves, and that is the honest reading of it: it has no roster to scan quadratically, and what its restore costs is `roads.load_section` on a small graph. The lever was never about small cities.

### RR-51 — The per-section skip is REFUSED, and the measurement that refuses it refuses it on both sides (doc 08 §3.1)

The brief named a section cache as "the honest big lever" on both paths: capture would reuse the last serialized form of any section that had not moved, and restore would skip any section already identical to the live state. Doc 08 §3.1's registry was always the plan and `SaveManager` already speaks sections, so the plumbing is nearly free. **The premise is not.**

Measured directly — capture the benchmark city, advance, capture again, compare each of the 28 sections with a native deep `==` (4.16 ms for the whole body, so the *test* would have been affordable):

| Advance between the two captures | Sections unchanged | Sections changed |
|---|---|---|
| 15 game-minutes | 14 of 28 | 14 of 28 |
| 1 game-hour | 14 of 28 | 14 of 28 |

Fourteen unchanged sections sounds like a win until they are named. The unchanged set is `construction`, `development`, `director_links`, `events`, `goals`, `placed_records`, `policy`, `population`, `progression`, `removed_records`, `stats`, `timers`, `work`, `world_blocks` — **whose combined encode cost is 0.25 ms of a 36 ms encode.** The changed set is `buildings`, `grid`, `roads`, `water`, `clock`, `rng`, `districts`, `dispatch`, `director`, `fleet`, `happiness`, `incidents`, `treasury`, `weather` — and the first four of those are **91 % of the body**. Every one of the four changes within fifteen game-minutes, because condition decays, congestion smooths, flows settle and the load ledger accrues, every tick, on every one of them.

**Ruling: a section cache would ship a comparison that always says "changed" on the sections that cost anything, and would ship it on the save path AND the restore path, where the same table applies to a mid-session reload.** It is refused, and it is refused with the table rather than with an opinion, so the next session that reads doc 08 §3.1 and has the same idea can see what it costs before building it. **What would change the answer**: splitting `roads`, `water` and `grid` into a static half (topology, which changes when the player builds) and a dynamic half (condition, congestion, flow, which changes every tick) — a real format change, correctly out of scope for a hash-neutral wave, and the shape doc 08 §3.1's twenty-owner registry should take when it is actually built.

**A format change was costed and is also refused, for the record.** The body is 1.28 MB of JSON text and `JSON.stringify` is 24.8 ms of it. A binary body (`var_to_bytes`) would remove the stringify, the parse (20.3 ms) and the whole float-canonicalisation problem — doubles would be doubles — for something like 60 ms of the round trip. It would also invalidate every save on every phone, retire the digest-over-text rule doc 08 §2.6 step 3 depends on, and make a corrupt save unreadable by eye at exactly the moment somebody needs to read one. Not worth it at this size; revisit if a body ever passes 10 MB.

### RR-52 — A save taken after the first game-day does not replay bit-identically, and it is a ROADS defect, not a serialization one (A91-D-30)

Found while writing the mid-incident round-trip test for RR-50, on the FOUNDING city, at `28b9550` — i.e. **before** anything in this wave, and reproduced against the stashed tree to be certain. Seed 8191, `CitySim.boot_from_files`:

| Save taken at | at rest | after 2 further game-hours |
|---|---|---|
| 1, 2, 4, 6, 8, 10, 12, 16, 20 h | identical | identical |
| **24 h, 30 h** | identical | **DIFFERENT** |

The body is byte-identical and the restored city matches the live one exactly at the moment of restore — `state_hash()` agrees — and then the two runs diverge within one game-hour of advancing. The first fields to move are `roads.traffic_feed.vehicles[*].s_m` and `.speed_mpgm` at a relative 2 × 10⁻⁶, followed immediately by `roads.edge_dynamics[*][1]` (smoothed congestion). Both restore paths — one call and eleven steps — land on the *same* wrong city, which is what places the fault upstream of the cursor and upstream of the codec: **something derived inside `RoadNetwork` is rebuilt differently by `load_section()` than the live run had it, and it only starts to matter once a day boundary has been crossed.** `_last_hour_sampled` is the obvious candidate — it is the one day-scoped member of `RoadNetwork` that `save_section()` does not persist, and `load_section()` hard-codes the `12.0` that its `-1` default produces — but poking it (and `_mean_congestion`) across the restore does **not** close the gap, so the real cause is something else and is not yet named.

Filed as **A91-D-30 (High)**. It is not fixed here: this wave is hash-neutral by contract, and the fix is a change to what `roads` persists, which is a `SECTION_VERSION` bump and a ladder rung. `tests/test_save_chunked_restore.gd` asserts the three properties that DO hold (the body round-trips, the two restore paths agree with each other, and both agree at rest) and documents the fourth in prose rather than smuggling a weakened assertion past a reader.

**Why the suite never caught it.** Every existing save → load → advance proof saves inside the first game-day: `tests/test_milestone1.gd` at 2 h, `test_save_service.gd` shorter still. The determinism gate is real and the window it covers is smaller than a day.

**Hash-neutrality of this wave, stated for the record.** `tools/profile_sim.gd --hash-only` before and after, both cities: founding `18e70625e633c254…` / `4c3c52cdb4c5a3cc…`, benchmark `d6b2509c179987d3…` / `bf8dc7282758843b…`. Unchanged.

## 24b. WAVE 11 — the flood gets drawn, and the event matrix gets a rule (binding)

### RR-53 — Standing water is GEOMETRY, not a global; and an event that describes a player-visible state change needs a consumer or a written exemption (docs 07 §2.4, 11 §2.9b/§7.3e/§7.3f, 91 §18 + A91-D-26, 93 §L1)

Two findings, one branch, because the second is the general form of the first.

**The flood.** `sim/weather/flood_field.gd` has been integrating `depth_mm` on the utilities cadence since the weather system shipped — **460 `flood_level_changed` in a two-real-hour soak**, doc 10 closing edges off it correctly — and **nothing in the tree matched that event type.** Not `game/render/weather_fx.gd` (three types, and that is not one of them), not `main.gd`'s translator, not `data/ui.json.event_log.events`, not `data/notifications.json.bindings`. The only evidence a player ever had was `road_closed_flood`, which fires at the 350 mm band; the three bands below it were invisible. Doc 04's *"a subsystem can be fully shipped and wholly invisible"* gap, in doc 07.

**The cheap fix doc 07 §2.4 proposed is the wrong fix, and this is the ruling.** The note said: raise `sc_wetness` on the affected tiles. It cannot be done and would be wrong if it could. **`sc_wetness` is a project shader global — one float for the entire world — and `WeatherFX` owns it as doc 11 §2.9's city-wide rain integrator.** A flood is the opposite shape of data: per land block, outliving the rain that caused it by hours (drainage is 40 mm/h against an inflow that stops when the segment does), and routinely at different bands on blocks a hundred metres apart. Folding it into the global floods the whole city or none of it.

> **RULING: standing water is GEOMETRY.** One MultiMesh of 8 m quads over the flooded cell's ROAD tiles — doc 07 §2.4's own rule, *only road tiles accumulate*, which also means a 128 m sheet over the land block would put water through every building on it. `game/render/flood_view.gd` + `game/shaders/flood.gdshader`. **+1 draw call while water stands anywhere and +0 when the city is dry.**

Three sub-rulings fell out of building it, and all three were found by looking at a screenshot rather than by reasoning:

* **(a) Nothing in this surface may be a function of the INSTANCE.** Two drafts had a per-tile term — a UV-space gutter bias, then a per-tile hash seed phasing the puddle noise so "which corner holds the last puddle" would be a fact about the city. Both are reasonable and both drew the same thing: **a wet 8 m LATTICE over the whole city — the tile grid, in water.** Coverage has to be a function of WORLD position for two adjacent quads to read as one puddle, which is the rule `water.gdshader` already follows for the canal. `INSTANCE_CUSTOM` therefore carries two channels and two zeroes, and the picture is a pure function of the sim with no seed to persist.
* **(b) Coverage, not height, is where depth reads — and it is not linear in depth.** 350 mm on an 8 m tile is a few pixels of geometric lift at the camera's pitch band. Depth drives how much of the tile is wet. And doc 07's bands are 0–39 / 40–99 / 100–199 / 200–349 / 350+, so `standing water` — where vehicles start stalling — is only **0.29** of the way to the divisor: a linear ramp put a third of a tile under water at the depth the sim was already stalling traffic on. `pow(water01, 0.45)` puts the four bands at roughly 20 / 50 / 90 / 100 % of the tile, which is what the bands MEAN.
* **(c) A wet road at night is LIGHTER than a dry one, and the first cut had it backwards.** Measured at 22:00: a 490 mm flood over unlit asphalt was **invisible**, because a `night_mult` borrowed from the canal put the water below the road it was standing on. Water at night has stopped diffusing and started mirroring. Report NIGHT-1's three terms, aimed the other way: `night_mult 0.80`, a `night_lift` off the sampled `sc_fog_tint`, and a `night_glow` skyglow floor. This is the shot the feature exists for and it was one constant away from shipping black.

**The load path is doc 07's own persisted field, and the renderer persists nothing.** `WeatherSystem.serialize()` already writes `"flood": flood.serialize()` → `{"tiles": {cell: depth_mm}}`. The view takes that dictionary through `prime()` and `snap()`. Waiting for the next band crossing would be wrong twice: on a draining field the next crossing can be a game-hour away, and a render-side copy of a sim fact can only ever disagree with it. `tools/flood_preview.gd --reload` round-trips the weather section through JSON, throws the live view away, builds a new one and primes it — a city that has consumed **zero** flood events, with the flood on screen.

**Measured** (`tools/profile_frame.gd --flood=350` vs `--flood=0`, bench city, balanced, 1920×1080, three runs × 400 frames). 350 mm on every LOW block is the worst case the layer can be asked for — **21 cells, 1,827 tiles, +3,654 primitives**:

| pose | Δ draw calls | Δ rs gpu | Δ rs cpu |
|---|---|---|---|
| Z0 | **+1** | +0.151 ms | 0.000 |
| Z1 | **+1** | +0.115 ms | 0.000 |
| Z2 | **+1** | +0.127 ms | 0.000 |

Against the branch's +6 draw-call budget at Z2: **+1**. And the fragment ladder (`--flood-detail=0/1/2`) reads 2.077 / 2.130 / 2.071 ms at Z0 against 1.920 dry — the three rungs are inside each other's ±0.05 ms run-to-run spread, so **on a desktop GPU the layer's cost is the transparent blend and the overdraw, not the arithmetic.** The rung stays because the Fold frame is fragment-bound and its ALU is a different machine, but it is a governor lever that desktop numbers do not justify. On the device list.

**The general form: doc 93 §L1's event ruling.** Doc 91 §18's *43 consumed by nothing* is unusable as a rule — most of the 43 are a cascade trace, a treasury credit, a scheduler phase boundary. The narrowing, adopted:

> **Every event whose payload describes a PLAYER-VISIBLE state change must have a consumer or a written exemption. Everything else carries a one-line classification and no consumer is expected. And a RENDERER is a consumer.**

Which yields the design line: **narrate the bands that change what the player can DO, draw the ones that only change how the city looks.** Doc 07's 40 mm nuisance band has `flood_view.gd` and nothing else, for ever.

**Re-walking the matrix under the rule found that the count was already stale, and that the real remainder was in doc 05.** The scan is now `tests/test_event_matrix.gd` (doc 11 §7.3f) and prints **138 types emitted, 78 consumed, 60 classified, 0 unexplained**. 138 against 121 is mostly one line of scanner — `_emit(&"water_freeze_break" if main.frozen else &"water_main_break", …)` puts a real type in an `else` branch, and a scan taking the first literal calls `water_main_break` un-emitted while two routers are wired to it. Three of the 43 (`grid_feeder_routed`, `grid_node_commissioned`, `grid_node_retired`) had acquired a `main.gd` arm in Wave 10, **the day after the defect was filed**. That is the argument for the test and not for the numbers.

Eleven types were wired in this pass and every one of them is an ASYMMETRY — a state whose onset was announced and whose end was not, or a warning that only existed after the thing it warned about had happened:

| wired | the asymmetry |
|---|---|
| `flood_level_changed` | A91-D-26's headline |
| `road_reopened` | the closure was announced; the reopen was not |
| `storm_phase_changed` (lead-in / ended) | `weather_changed` says the sky turned; this says the cell carrying the strikes arrived |
| `water_capacity_shortage` | doc 05 §2.9: **no repair job exists** — the only water alert whose answer is BUILD, and the quietest thing in the game |
| `water_tank_low` / `water_tank_empty` | a zone drawing on reserve, then living on what it makes |
| `water_pump_failed` / `water_treatment_failed` / `water_source_failed` | `water_pump_tripped`, a recoverable lockout, was wired; a FAILURE was not. One notify_id for the three: a failed pump, plant and source are the same sentence and the same job |
| `water_contamination_cleared` | `water_contamination_started` was wired; the boil notice lifting was not |
| `austerity_exited` | the belt tightening was announced; the loosening was not |
| `relief_grant_awarded` | money arriving in the treasury that nothing mentioned |
| `road_condition_critical` | the only warning that a road was about to fail was the road failing |

**Hash-neutral, and here are the numbers.** No `sim/`, no `data/weather.json`, no balance table was touched. `tools/profile_sim.gd --hash-only` at this branch: founding city `18e70625e633c254…` / `4c3c52cdb4c5a3cc…`, benchmark city `d6b2509c179987d3…` / `bf8dc7282758843b…` — identical to RR-47's recorded values. The 28 gates are untouched.

---

## 24c. WAVE 12 — the last doors, and the last accessibility corner (binding)

### RR-54 — A door that cannot be reached is a missing feature; a door whose command says `ok` for doing nothing is a worse one (docs 06 §2.11, 10 §2.13, 12 §2.4/§2.6/§2.13/§2.18, 91 A91-D-21/22/23/24, 92 §30, 93 §J3)

Four findings closed together because they are the same shape twice over: a
**verb with no surface**, and a **surface that does not survive the two
accessibility settings §2.18 calls release gates.**

**(a) The last two doorless verbs.** `cmd_recall_unit` had *zero callers anywhere
in the repository* (A91-D-24) — not a shell, not a harness, not even a test,
because the one test that exercises recall reached past the `CitySim` wrapper and
called `DispatchSystem` directly. `cmd_set_auto_repair_policy` had no wrapper at
all (doc 91 §17.2). Both now have the door their own doc had already specified:
doc 12 §2.6's assigned-unit chips for the first, doc 12 §2.13's `policy:` row
family for the second. **Ruling: a verb doc 06 or doc 10 calls a *player* verb
gets a door in the wave that notices it has none, and the door is the one the UI
doc already drew** — §2.6 has described those chips since the first draft, and
building something else instead would have been a second design where a first one
already existed. Two deviations from §2.6's words are recorded rather than
silently taken: the chips are 48 dp not 24 (A3 outranks a dimension) and they sit
beside ASSIGN rather than replacing it (a `Button` inside a `Button` cannot be
hit, and sending a second unit is a verb doc 06 supports).

**(b) And wiring the verb exposed that the command was lying.**
`FleetSystem.recall()` has always no-opped on `IDLE` and `OFFLINE`, so
`cmd_recall_unit` answered `ok` for doing nothing. Harmless while nobody called
it; a door that reports success and moves no truck the moment somebody did.
**Ruling: a command reachable from a surface must refuse what it cannot do, by
code, with the state it refused for in the payload** — `E_UNIT_NOT_DEPLOYED`
carrying `status`, so §2.7's formatter can put doc 06's own vocabulary in front
of the player. This is the general form of the D-35 lesson: the affordance is not
finished when it issues the command, it is finished when the refusal is a
sentence.

**(c) A control that MOVES SPEND needs a control run, and a control run needs a
horizon.** The auto-repair dial is the first door whose purpose is to spend money
without asking. The 7 × 3 × 21 matrix is **byte-identical** with the dial in
place at its defaults — and byte-identical at `auto_repair=0` and at
`0.55 / $200,000` as well, which on its own proves nothing at all. Doc 92 §29.2
therefore measures *why*: the founding city's worst road tile is **0.7947** at
game-day 21 and **0.5484** at day 45, so no arm of the dial has anything to queue
inside the horizon the matrix uses. The lever is then measured where it can act —
24 tiles worn to 0.30, four game-days — and both dials are shown to gate the
spend independently (threshold 0.25: nothing; 0.40: 24 tiles, $181; cap $0:
nothing). **Ruling: "the matrix did not move" is only a finding when the same
pass also shows what would have moved it.** An unmoved table with no such
measurement beside it is indistinguishable from a wire that was never connected.

**(d) A layout solver that has only one axis will eventually be asked about the
other.** §2.4's collapse solver has budgeted chip WIDTH since the first draft and
D-1 taught it to wrap. Nothing taught it how tall the answer was, so at 880 × 400
— doc 12 §2.3's own reference box — with 130 % text and larger targets the bar ran
two 100 dp rows to y 212 of a 392 dp safe area, straight through the left rail:
**156 `overlapping_targets` findings, every state, one box** (A91-D-23). The
budget alone could not close it, because one row is already 100 dp against a rail
top at 89 and the column wants 407 dp of 392. **Ruling: when two solved stacks
cannot share a column, the one §2.3 classes *rare* yields to the ones it classes
*frequent*** — the bar steps right of the rail column and §2.4's existing
demote-then-hide ladder absorbs the width. The property that made it safe to
land is D-46's property: at 100 % text with 48 dp targets the inset is **0 at
every supported box**, so no screenshot in the repo moves.

**(e) And the centred cards got the pattern the full-screen sheets already had.**
RR-45(b) fixed sheets that grew WIDER than the phone. S0 and the pause menu fail
the same way on the other axis and for a different reason: they are cards in a
`CenterContainer`, which lays a child out at exactly its minimum, so a 449 dp
card on a 400 dp box hangs off both ends and `SAVE & QUIT`, `SETTINGS` and the
new-city confirmation's `CANCEL` were all below the fold. **Ruling: a card is
capped at what the display can show and its body scrolls** — `UIWidgets.card_height()`
+ `wrap_in_scroller()`, the goals-sheet pattern applied to a card that is not
full-screen.

**Measured, whole deck, after:** `tools/ui_preview.gd --screen=all --audit` over
**52 states × 5 boxes × 2 accessibility settings = 520 state-sweeps, 0 findings
of any kind.** A2 at 130 % and A3 are green at every box the project tests for
the first time. A2's own box — 150 % at 640 × 340 — remains A91-D-29 and remains
unmeasured; this wave did not touch it and does not claim it.

**One process note, and it cost an hour.** `git stash` is **shared across
worktrees** — `refs/stash` lives in the common git directory, not the per-worktree
one — so a stash pushed in one agent's worktree can be popped in another's. It
happened here: a sibling's stash was popped into this worktree between a push and
a pop. It was recovered byte-identically (re-pushed, contents diffed against the
working tree before and after) and the stack order restored, but **a
worktree-isolated agent must not use `git stash` at all**: save a patch with
`git diff > file`, `git checkout --` the paths, and `git apply` to restore.

---

## 25. WAVE 12 — the ledger closes (binding)

*Five debts that every wave filed and no branch owned. Docs, tools and tests
only: `sim/`, `data/` and `game/` are untouched, and `tools/profile_sim.gd
--hash-only` reports `18e70625e633c254…` / `4c3c52cdb4c5a3cc…` on the founding
city and `d6b2509c179987d3…` / `bf8dc7282758843b…` on the benchmark city, before
and after.*

### RR-55 — A digest published from a branch is a statement about that branch; quote the fork or quote the merge (doc 92 §24.12, §25.2, §27.3)

Doc 92 §24.12 and §25.2 published four `profile_sim` digests each and **none of
them reproduces on the integrated tree**. §27.3 caught that, could not pay it,
and filed it. Paid here at `28b9550`, and the diagnosis is not "somebody
mistyped": both sections forked from `85e25aa`, both measured correctly *there*,
and `85e25aa` returns exactly the digests they publish — starter
`2231df75…` / `bffdf583…`, bench `a06e7d43…` / `224a900d…`. The identity
ARGUMENTS in both sections are unaffected; only the absolute values are a
branch's.

The mover is one commit, found by `--hash-only` along the first-parent chain:
**all four move at `1b2852b`**, the Wave-9 routing-enablement merge (branch
`d66a0e5`, which self-declares `CitySim.SAVE_SECTION_VERSION` 4). The starter
pair has not moved through the six integrations since — including the
upgrade-timing fix, which is §27.3's own point measured over a longer arc: the
identity pass issues no player command, so a change to what a command costs
cannot reach it. The bench pair moves once more, at `675226e`, whose own branch
report published its digests as unmoved against ITS base — **two branches each
hash-neutral against `85e25aa` composed into a move on the merged tree.**

**Ruling: a digest is only a baseline if the commit it was taken at is named
beside it, and a hash-neutrality claim made on a branch does not survive the
merge unless it is re-taken there.** Any section quoting a `state_hash` names its
fork. Any wave that publishes "unchanged" from a branch owes the integrator a
re-take, and the integrator is entitled to treat an unnamed digest as unverified.
`tools/profile_sim.gd --hash-only` is seconds of wall clock; there is no excuse
proportional to the cost.

### RR-56 — A per-channel row in the 336-game-day ambient arm is a SAMPLE, not a rate (doc 92 §18.6, §18.7, §18.8, §27.7)

§27.7 filed `water_main_break`'s 0.60 → 0.75 → 0.90/game-week as *"2.6 σ across
two waves"* and asked for a dedicated arm. It got one (doc 92 §18.8), and both
halves of the filing were answered:

* **The move is one commit.** Seven full arms — `8b36323`, `64390c5`, `85e25aa`,
  `d66a0e5`, `1b2852b`, `a892315`, `28b9550`, 12 seeds × 28 game-days each —
  put 36 counts on every tree up to `85e25aa` and 43 on every tree from
  `d66a0e5`. `d66a0e5` has a single parent, so the A/B either side of it is one
  commit, and it moves **every** channel (total 308 → 321), not just water.
  A negative control settles which half of it: `d66a0e5` with
  `data/dispatch.json` rolled back to `85e25aa`'s — reverting
  `max_acceptable_cost_min` 90 → 115 and the new `unanswered_abandon_h: 24.0` —
  returns 43 / 321 / $191,595, **byte-identical to the shipped commit.** The
  dispatch retune is not the cause; the code epoch is.
* **It is not a rate change.** The same arm at HEAD on two more 12-seed blocks
  disjoint from the canonical one returns `water_main_break` **29 and 27** —
  0.60 and 0.56/game-week, one of them §18.6's own number, on the tree that
  "drifted" to 0.90. The whole reported drift sits inside the arm's sampling
  spread.

**And the statistic was wrong.** §27.7 divided the difference by the Poisson σ of
one of the two counts. For two independent counts over equal exposure the
denominator is `√(n₁+n₂)`: the "2.6 σ" is **1.65 σ**, `36 → 43` is **0.79 σ**, and
the total's `308 → 321` is **0.52 σ**.

**Ruling, and it is about the instrument rather than the channel: 12 seeds × 28
game-days is correctly sized for the TOTAL and under-powered for any single
channel.** ~33 `water_main_break` arrivals put 1 σ at ±0.15/game-week, a sixth of
its own mean. A pass that wants to rule on one channel quadruples the exposure
first (48 seeds, or 112 game-days); until then a per-channel row in §18.6,
§18.7 or §27.7 is read as a sample and never quoted as a rate.
`data/incidents.json` is untouched and §18.7's 5–8 band stands on all three
blocks (6.17 / 6.50 / 6.69).

### RR-57 — A test method that never asserts is a FAILURE, and a test runner owns its own `user://` (doc 00, `tests/run_tests.gd`)

Two agents in two waves filed the same pair of faults and neither is a bug in any
subsystem. `user://` is keyed on `application/config/name`, which every worktree
shares, so two suites running side by side write the same
`~/.local/share/godot/app_userdata/Slacum City/saves` — and on 2026-08-20 an
agent watched a **green** run in which
`test_save_service.gd::test_a_pinned_checkpoint_is_never_swept` was killed
mid-method by a manifest key a sibling had swept. A GDScript runtime error does
not throw: it prints, unwinds the one function it happened in, and returns to the
caller. So the aborted method contributed **no assert and no failure**, and from
the runner's seat looked exactly like a pass.

Both halves are closed **inside the runner**, because "remember the environment
variable" is not a fix:

* **`user://` is moved to a per-process directory in `_initialize()`** by
  `tests/user_dir_isolation.gd`, which **all three runners** use — the gate
  (`tests/run_tests.gd`) and both inner-loop runners (`tools/run_one_test.gd`,
  `tools/run_one.gd`), because the inner loop is exactly where a sibling run
  collides with you. Two mechanisms, both re-read by `OS.get_user_data_dir()` on
  every call — measured on 4.7.2, which is what makes them usable after boot:
  `application/config/use_custom_user_dir` + `custom_user_dir_name` (every
  platform, supplies the per-process NAME) and `XDG_DATA_HOME` (Linux/BSD, moves
  the ROOT into the temp dir). Godot creates the user directory exactly once, at
  boot, so the new one is `make_dir_recursive_absolute`d — without that every
  `FileAccess.open("user://…", WRITE)` returns `ERR_FILE_CANT_OPEN`, which is a
  worse failure than the collision it replaces. An inherited `XDG_DATA_HOME` is
  honoured as the root and still gets a private child underneath, so the old
  hand-isolated invocation keeps working and becomes safe against itself.
  `tools/run_suite.sh` is a convenience, not a requirement.
* **`SimTest.begin_test` / `end_test` read the assert counter on both sides of
  every method**, and one that did not move it is named in `silent()`. The runner
  refuses to print ALL TESTS PASSED while that list is non-empty.

**It found two on its first run, which is the argument for it.**
`test_power_grid.gd::test_relay_trip_timing` was a comment and a bare `pass`
deferring to a test that **does not exist and never has**; deleted, with its §2.5
arithmetic moved into `test_relay_on_feeder`, which does check it.
`test_ui_strings.gd::test_every_notification_placeholder_has_a_supplier` read
`data/ui.json.alerts.events`, which has never existed — the rows are under
`event_log` — so `supplied` stayed empty, every key hit a `continue` and the
method made **zero assertions** while counting as a passing test. One word fixed
it and the file now runs 201 asserts.

**Ruling: a test that makes no assertion is a failing test.** The guard is
covered by `tests/test_runner_guard.gd`, which drives
`tests/fixtures/aborting_suite.gd` — a fixture that aborts on a missing key on
purpose — with the same three calls the runner makes, and asserts that the abort,
the early return and the honest control are told apart.

**Both halves were proved in ONE experiment, and it is the experiment the fault
deserves: two full suites, same worktree, at the same time.**

| | suite A (clean tree) | suite B (one aborting `test_*.gd` added) |
|---|---|---|
| files / tests | 112 / 1,965 | 113 / 1,967 |
| asserts | 508,216 | 508,215 |
| failed | 0 | 0 |
| **silent** | **0** | **1** — `test_aborts_on_a_missing_key`, named |
| verdict | `ALL TESTS PASSED` | `NOT PASSED: 1 test method(s) never asserted` |
| exit | 0 | 1 |
| `grep -c "ALL TESTS PASSED"` | 1 | **0** |
| `user://` | `/tmp/slacum-suite/slacum-suite-209697` | `/tmp/slacum-suite/slacum-suite-210402` |

Different directories, neither touching `~/.local/share`, both correct — which
is what the pre-Wave-12 pair of runs could not have produced. **`failed: 0` is
no longer sufficient for green; `failed: 0` AND `silent: 0` is.**

*(One consequence of adding a `class_name` script: it is only global after the
project has been imported, so `tools/run_suite.sh` imports when the class cache
is missing or older than any `.gd` under `sim/ game/ ui/ tests/ tools/` — warm,
that is one `find`; the CI workflow already had the same step.)*

### RR-58 — A setup script that unzips over the tree must reapply the tree's patches, and the patch set was never empty (doc 13 §2.10, §9 item 4, §10.1)

Doc 13 §2.10 says every template edit lives in `tools/android_patches/*.patch`
and is reapplied after the unzip, and doc 13 §10.1 recorded the reapply step as
unnecessary because "the patch set is empty (as designed)". **It was not empty.**
`tools/setup_android.sh` runs `unzip -o`, which overwrites every committed file
the template carries, and a file-by-file comparison against 4.7.2 gives the exact
size of the problem: **34 tracked files under `android/build/` are also in the
zip, 33 are byte-identical, and one is ours** —
`android/build/res/values/themes.xml`, holding §2's dark
`android:windowBackground` and the removal of a dangling
`@drawable/splash_branding_image` reference. Running the setup script on a
working clone reverted both and the next debug build flashed white.

Written, and verified in a worktree in three steps: a bare `unzip -o` leaves
`git status` reporting the file modified with exactly those two hunks; the patch
restores it byte for byte; a full `setup_android.sh` run — 215 MB unzip plus a
`BUILD SUCCESSFUL` Kotlin plugin build — leaves `git status --porcelain android/`
**empty**, with no `.rej` and no `.orig`. And the exporter does not undo it:
`--export-debug "Android"` completes and the file is unchanged afterwards,
despite its own header claiming to be "auto-generated during export".

**Ruling: `--forward` alone is not idempotence, and a patch that will not apply
is a STOP.** The reapply loop checks `patch --reverse --dry-run` first and skips
an already-applied patch rather than leaving a `.rej`; a patch that applies
neither way aborts the script with the file named, because that is a Godot
upgrade having moved the lines and a build whose theme is nobody's intent is
worse than no build. **The general rule: a script that overwrites source from an
external archive owns the diff between the archive and the tree, and "the design
goal is to keep it empty" is a goal, not a measurement** — measure it, in the
script or in the doc, or it drifts silently.

### RR-59 — A device harness whose vocabulary the shell does not parse is not a harness (doc 11 §7.4, §2.13, `tools/device_runbook.md` §1.1–§1.3, §3)

`tools/bench_device.sh` shipped in Wave 6 and was never run. The Fold session
found three reasons it could not be: it hard-coded `com.godot.game.GodotApp`
(the launcher is `GodotAppLauncher`), it launched with `--es cmdline` (Godot's
launcher reads a string ARRAY extra, and the engine's own list is only what
follows a literal `--`), and its whole scenario vocabulary —
`--bench=S1|S2|S3`, `--preset=`, `--city=` — **is parsed by nothing in
`game/main.gd`.** The runbook recorded all three and the script kept them for two
waves, because a document that describes a broken tool is not a fixed tool.

Rewritten against the runbook. The activity is resolved live; every launch
carries **both** correct extra forms, since `game/dev_args.gd` merges and
de-duplicates them and a duplicated `--advance-hours=4` would otherwise advance
the city eight hours; `--bench=` is gone and doc 11 §7.4's S1/S2/S3 survive as
`--scenario=`, re-expressed in flags the shell parses. `--hour=H` is the script's
own shorthand and is resolved to `--advance-hours=DELTA` against a `--now=H` read
off the HUD, re-based after every pose — because `--advance-hours` is a delta and
the runbook names getting that wrong as the easiest way to measure dusk twice.

**Ruling: a harness that cannot reach its device ships a self-test that proves
everything else.** `--self-test` runs 20 checks with no device: the flag
vocabulary against `game/main.gd`'s own parse table, the hour arithmetic
including the day wrap and the re-base, the pose and scenario tables, both launch
forms, and both summarisers against known answers. It earned its place while
being written by catching three real bugs, one of which would have silently
ruined every capture — a comma-separated pose list set `IFS` globally,
`resolve_hours` splits on whitespace, and every pose therefore launched with the
unresolved `--hour=` and was captured at whatever hour the save held. **The
device half remains unverified and the script says so in its own summary rather
than in a document nobody opens.**

---

## 26. WAVE 13 — the determinism defect, found where nobody was looking (binding)

### RR-60 — A91-D-30 is a WATER defect, and the field that MOVES first is not the field that is wrong (docs 05 §3.2, 08 §2.8, 10 §3.2, 91 A91-D-30 + §20.2 item 18, 00 §5)

**The root cause, in one paragraph.** `WaterDemandCache` keeps three per-zone
demand sums — `zone_res`, `zone_com`, `zone_proc` — and maintains them
**incrementally**: `set_demand` subtracts a building's old contribution from the
running sum and adds its new one, once per changed building per utilities tick,
which after a game-day of a founding city is tens of thousands of additions and
subtractions in the order the city happened to change. A restore does not have
that history. `WaterSystem.deserialize()` ends in `rebuild_zones()`, which calls
`demand.reassign()`, which clears the three sums and rebuilds them with **one
clean forward pass in sorted building order** — the same number, arrived at by a
different route, and therefore **not the same float**. Measured on the founding
city at seed 8191 after 24 game-hours: `zone_com[0]` is
`0.99869999999999992` live and `0.99870000000000014` restored, a difference of
one ULP, present **at the moment of the load and before anything advances**.
`com_base` is a term of every zone's hourly demand, demand drives the pressure
solve, the solve drives delivery, and within one further game-hour the two cities
disagree about `water.hour_accum.delivered_m3` in a way `state_hash()` can see.
**The fix is that the sums travel with the save** (`water.section_version` 2 → 3,
additive), taken back immediately after the rebuild that re-derives each
building's zone — which is the same shape, and the same argument, as doc 10
§3.2's `edge_dynamics` two waves earlier: *a quantity that is a function of the
city's HISTORY cannot be re-derived from its state.*

**Roads was the wrong suspect, and the reason is worth more than the fix.**
RR-52 named `roads.traffic_feed.vehicles[*].s_m` and `roads.edge_dynamics[*][1]`
as "the first fields to move", filed the defect against `RoadNetwork`, and
eliminated the only candidate it could name (`_last_hour_sampled`). Every one of
those observations was correct and the conclusion drawn from them was not. The
diff was taken **after** advancing, and after advancing, a chaotic system's
loudest coordinate is whichever one amplifies fastest — here the cosmetic traffic
feed, whose `speed_mpgm` is a multiplicative function of a smoothed congestion
value, three systems downstream of the seed. The instrument that separates the
two is a **reflection walk over every member of every live object, run before
either city advances a tick**: `tools/diff_restore.gd` walks `RoadNetwork`,
`RoadGraph`, `CongestionModel`, `RoutePlanner`, `TrafficFeed` and
`TrafficSnapshot` — or any other `CitySim` member — comparing dictionaries by
key ORDER as well as by value, floats with `is_same` rather than a tolerance, and
collapsing the result into a per-field census. It found the answer in one run,
and the answer was in the section nobody had a hypothesis about.

> **RULING: a determinism divergence is diagnosed AT REST, never after
> advancing.** The first field to move is evidence of amplification, not of
> cause. A save→load bug report that names a field must say whether the field
> differed *before* the two cities were stepped; if it did not, the field is a
> symptom and the report has not found the defect yet.

**And "at rest" has to mean every LIVE member, not the body.** The body was
byte-identical in all three defects this section closes; every one of them lived
in state the body does not carry. `state_hash()` is a gate, not an instrument.

**The A/B, because a root-cause claim needs one.** Restoring at 24 h and then
overwriting the restored city's four zone dictionaries with the live city's —
changing nothing else, touching no other system — makes the founding city
bit-identical after two further game-hours, at every save point tried. Without
the patch the same runs diverge. Before the fix, on
`CitySim.boot_from_files(8191)`, saving and then advancing two game-hours:

| save taken at | at rest | after +2 game-hours | first field to differ |
|---|---|---|---|
| 2 h | identical | identical | — |
| 26 h | identical | **DIFFERENT** | `water.hour_accum.delivered_m3`, 1 ULP |
| 50 h | identical | **DIFFERENT** | `water.hour_accum.delivered_m3`, 1 ULP |
| 74 h | identical | **DIFFERENT** | `water.hour_accum.delivered_m3`, 1 ULP |
| 120 h | identical | **DIFFERENT** | — |

and with the fix, every row reads *identical / identical*. **The 24-hour
threshold is not a day boundary and never was**: the ULP is present from the
first minutes of the city's life, and 24 game-hours is simply how long it takes
to grow into a digit the hash can see. RR-52's *"it only starts to matter once a
day boundary has been crossed"* was pattern-matching on the two save points that
had been tried.

**Why the suite could not see it, and what replaces the gate.** Every
save → load → advance proof in the tree saved inside the first game-day:
`tests/test_milestone1.gd` at 2 h, `test_save_service.gd` shorter,
`test_save_chunked_restore.gd` at 9 h and 7 h. The gate was real and its window
was smaller than a day. `tests/test_save_determinism_days.gd` is the widened one
— saves at 2 h, 26 h, 50 h and seven game-days, restores, advances two further
game-hours and asserts bit-identity, on the founding city **and** the benchmark
city, walking one reference timeline so each milestone is checked against a city
with real history rather than a fresh one. It is the most expensive file in the
suite and that is the correct trade for the one property the constitution does
not let this project trade.

**And the widened gate immediately earned itself, which is the other half of the
argument for writing it.** With `zone_sums` carried, three of the four save
points were clean on both cities and the fourth was not: the **benchmark city,
seven game-days in, aged on the coarse path**, diverged on
`water.stats.last_rebuild_minutes` — **10080.0 live against 9960.0 restored**.
The cause is the same shape as the first one and is not a float at all. That city
had broken a main, so it was carrying `topology_dirty = true` into its next
`advance()`, where it would rebuild its zones; the restored city has already
spent that rebuild inside `deserialize()`, so it did not owe one, did not do one,
and never re-stamped the timestamp. **A pending rebuild is work the city OWES,
and work a city owes is history**: `pending: {topology, demand}` joins
`zone_sums` on the same rung, and is the same argument `service_pending_h` (C-37)
made for the un-banked remainder of a game-minute. It is worth noticing that
neither of the two defects this section closes would have been found by looking
harder at the roads section, and that the second was found by a test rather than
by a person.

### RR-60b — …and there WAS a roads defect with RR-52's exact fingerprint. It needs a dark signal, not a day boundary (doc 10 §2.6, §3.2)

Two defects, one symptom, which is why one report could not separate them.

`RoadGraph.rebuild_all()` builds every node with `powered = true` — the
`_create_node` default — and **nothing between the rebuild and the end of
`load_section()` ever wrote it**. So a city loaded with a substation down comes
back with every signal lit. That is not a cosmetic difference for one tick.
`RoadNetwork.step()`'s very first act is `graph.refresh_signal_power(…)`, and its
return value is *how many nodes CHANGED*; a non-zero answer dirties **every edge
in the city** and takes a full smoothed congestion pass. The live run's signals
went dark hours ago and are not changing, so it takes no such pass. The restored
city therefore applies **one extra smoothing step to all 644 edges on its first
tick**, and from there `edge_dynamics` and the cosmetic feed's `speed_mpgm` walk
away from the live run — which is, precisely, the ordering RR-52 described:
`traffic_feed.vehicles[*].s_m` and `.speed_mpgm` first, `edge_dynamics[*][1]`
immediately after.

Reproduced with `tests/test_save_chunked_restore.gd`'s own mid-incident,
mid-flood fixture — seed 8191, a storm injected across the save point and doc
04's tutorial transformer failed under it — where the restored graph held
**eleven** signalised nodes lit that the live one held dark. The fix is to derive
rather than to persist: doc 04's grid is restored by `begin_restore`'s `core`
step, three steps before roads, so `power_is_tile_powered` already answers
correctly and `_load_edge_state` simply asks it. §3.2's own rule — *the graph is
derived* — with the emphasis where it belongs: derived state has to actually be
DERIVED, at the seam, and not left at a constructor default for the next tick to
discover.

**Why the caveat in `test_a_mid_incident_mid_flood_body_round_trips` never caught
it.** That test asserted the restored city and the stepped-restore city agree
with *each other*. They did — they were both wrong in the same way. The
assertion it was missing is the one that was added with this fix: **and both must
keep burning the way the city that was never saved does.**

**And the fix moved 107 ms off the first live frame, which was the surprise.**
Sampling signal power at the load seam is the single most expensive thing a
restore does on a cold sim — `power_is_tile_powered` fills doc 04's per-tile
transformer memo, and 2,024 nodes of that is **106 ms** on the benchmark city.
That is not new work. It is work the FIRST TICK after a load was already paying,
in one hitch, on a live frame, after the veil had come down. Measured three ways
on the benchmark city, first `advance_fine_n(1)` after a restore against the
steady-state tick beside it:

| | tick 1 | tick 2 |
|---|---|---|
| no sample at the load seam (before) | **186 ms** | 13.4 ms |
| sampled at the load seam (after) | **79 ms** | 13.3 ms |

So the restore's total goes 202 → 298 ms and the first frame goes 186 → 79, and
the 40 ms per-step ceiling still holds because the sample is emitted as
`SIGNAL_REFRESH_NODE_BUDGET`-sized steps (five of ~21 ms on that city) rather
than swallowed by `roads_state` — which is what it did in the first cut of this
change, taking that step from 28 ms to **135 ms** and failing the target on the
spot. A restore total is a number under a veil; a first frame is a number the
player feels.

**Two more genuine roads restore defects were found on the way, and neither is
the one above.** They are fixed in the same branch because they are real:

* **Every edge of a live founding city carries `district_id == ""` for its whole
  life, while its restored twin carries the real district on every one.**
  `CitySim._boot_roads` calls `roads.bootstrap()` and assigns
  `roads.district_of_tile` on the *next line*, so `_assign_districts()` inside
  that bootstrap sees an invalid `Callable` and returns having written nothing;
  and on a city where no road tile is ever edited, `_refresh_all_edge_state()` is
  never reached again. A restore refreshes edge state after rebuilding the graph,
  by which time the callable is valid — so the live city and the loaded city
  genuinely disagree about which district every road is in. It is numerically
  inert **today** only because `profile_weights_of` is injected by nothing, so
  `_profile_weights` answers with the same default row for every district; the
  day doc 10 §2.10's per-district land-use weights are wired in it becomes an
  immediate divergence on the first congestion pass. `district_of_tile` is now a
  property with a setter that re-stamps the edges, because a setter cannot be
  forgotten the way a call after an assignment can.
* **`RoadNetwork._mean_congestion` was left describing a city that no longer
  existed.** `_load_edge_state` recomputes congestion cold at hour 12, caches the
  mean of *that*, and then overwrites every edge's value with the saved one — and
  never re-takes the mean. It is what `estimate_eta_practical` reads, doc 12 §9.2
  asks ~40 of those inside one frame and doc 06 ranks dispatch candidates on
  them, so the first frame after a load ranked units against a stale scalar until
  the next game-minute's `full_pass` replaced it.

And one that is a rung: **`roads.section_version` 2 → 3 persists
`last_hour_sampled`.** Its `-1` default makes `_last_sample_hour()` answer a
hard-coded **12.0**, which is the hour `_after_closure_change()` prices its
immediate two-hop spillback recompute at — with smoothing BYPASSED, so it does
not nudge those edges toward noon, it *sets* them to noon's `c_raw`. A closure
opening in the first game-minute after a load therefore landed on a different
congestion than the live run's, at every hour of the day except midday. RR-52
tested this one by hand and correctly reported that it does not close the gap; it
is still wrong, and it is now written down.

**The founding-path hashes MOVED, and here is the proof that the trajectory did
not.** Three keys were added to the save body, so `tools/profile_sim.gd
--hash-only` prints different digests and any recorded baseline has to be
re-taken. That is exactly the failure mode a baseline invites — *"the hash moved,
re-record it"* — so it is answered with a measurement rather than an assurance.
The A/B is the constitution's own protocol (`git diff > patch` / `git checkout
--` / `git apply`; never `git stash`, whose ref is shared across worktrees), and
what it compares is not the digest but **the canonical body itself**, pretty
-printed and diffed line by line:

| | founding (`data/starter_city.json`) | benchmark |
|---|---|---|
| lines differing, HEAD vs this wave | **25** | **25** |
| …that are not a new key or a `section_version` stamp | **0** | **0** |

The 25 are `roads.last_hour_sampled`, `roads.section_version` 2 → 3,
`water.demand.zone_sums` (four sub-objects), `water.pending` (two booleans) and
`water.section_version` 2 → 3. **Every number that existed at HEAD is the same
number.** The identity pass is 24 coarse game-hours plus 2 fine ones on both
cities, which is what `--hash-only` runs.

For the record, the digests either side:

| | HEAD | this wave |
|---|---|---|
| founding, coarse 24 h | `18e70625e633c254…` | `e8bffba1853f248e…` |
| founding, fine 2 h | `4c3c52cdb4c5a3cc…` | `08bfdfaa3dd65281…` |
| bench, coarse 24 h | `d6b2509c179987d3…` | `e760f9305d21d331…` |
| bench, fine 2 h | `bf8dc7282758843b…` | `bd2d8f30d25827f4…` |

### RR-61 — The largest indivisible step of a restore is a graph rebuild, and a graph rebuild has seams (docs 08 §2.14, 10 §3.2, 13 §2.9)

`RoadGraph.rebuild_all()` was **73.7 ms of a 202 ms restore** on the
1,500-building benchmark city — the longest single thing the game does on the
main thread, and therefore the entire per-frame budget of doc 13 §2.9's loading
veil, since a veil that spends one cursor step per frame is bounded by the
longest step and not by the total. It is now four phases cut where the function
already had them: `graph_scan` (clear + the 512 × 512 tile sweep, bounded by map
AREA and so identical on every city), `graph_nodes` (§2.4's node predicate),
`graph_trace` (the polyline walk, one step per 700 nodes) and `graph_finish`
(orphan loops, node meta, the version bump).

**Slicing the trace is exact, not approximate.** `_trace_from_nodes` is a loop
over node ids in ascending order with `seen` and `_edge_key` carried across, so a
batch boundary cannot change which edge is created, in what order, or with what
id. `tests/test_roads_graph.gd::test_a_stepped_rebuild_lands_where_the_one_call_lands`
asserts the strong form — same ids, same node pairs, same tiles in the same
ORDER, at batch sizes down to **one node**, which puts a seam between every pair
of nodes in the graph. And `rebuild_all()` itself is now `rebuild_all_steps()`
drained on the spot, so there is one implementation and not two to drift.

`RoadNetwork.load_section_steps()` returns `[[label, Callable], …]` and
`CitySim.begin_restore()` splices the whole list rather than naming three indices
of it — the seams inside a road load are the road network's, there are now eight
of them, and a cursor that hard-coded three would have quietly dropped five.
`RestoreCursor` gained one method for it, `splice_next`, and the reason it is an
INSERT rather than an append is a bug this branch wrote and then caught:
`SaveService.begin_load_slot()` adds a `settle` step of its own *after*
`begin_restore()` hands the cursor back — the step that publishes the loaded UI
state and fires the `loaded` signal — so an append put ten road-graph steps
*behind* it and the city was announced as loaded with no road graph in it.
`tests/test_save_chunked_restore.gd` now asserts the ORDER (`finish` last of the
restore's own, `settle` last of all) and not only the membership, because
membership is what a set of labels proves and order is what the bug was. The
cursor is captured WEAKLY: a lambda stored in a cursor that also holds the cursor
is a `RefCounted` cycle with no collector to break it.

**Measured, `tools/profile_save.gd --city=res://tests/fixtures/bench_city.json
--repeats=5 --steps`, workstation:**

| | before | after |
|---|---|---|
| restore total | 202.4 ms | 297.6 ms |
| longest step | **73.7 ms** (`roads_graph`) | **29.2 ms** (`decode`) |
| longest ROADS step | 73.7 ms | **27.7 ms** (`roads_state`) |
| first LIVE frame after the load | 186 ms | **79 ms** |
| steps | 11 | 27 (9 announced + 18 spliced) |

**The total went UP and that is the right trade, stated plainly.** 96 ms of it is
RR-60b's signal-power sample, which the first live frame was paying before and
the veil pays now (see the table there); the rest is noise. The target this cut
was written against — *no single restore step over 40 ms on the bench city* — is
met, with the longest step no longer belonging to roads at all, and the number
the player actually feels more than halved. `tools/profile_graph_rebuild.gd`
prints the rebuild's four phases on their own: **15.1 / 4.9 / 10.0 + 9.8 + 8.4 /
7.0 ms** on 3,132 road tiles, 2,024 nodes and 3,092 edges.

**One honest cost.** The trace slot count is derived from an exact ceiling — every
road tile can be a node, which is the worst case §2.4 admits — so a city whose
nodes are fewer than its tiles spends one or two no-op steps at the end of the
trace. On the bench city that is two frames of nothing out of nineteen. The
alternative is a ceiling that can be too small, and a rebuild that silently
leaves half a graph untraced is not a failure mode worth being elegant about;
`graph_finish` drains the remainder for exactly that reason, and
`rebuild_all()`'s own one-slot path exercises that drain on every call, so it is
never untested code.

## 26b. WAVE 13 — the incident cascade gets its ceiling (binding)

### RR-62 — RR-26 bounded how long an incident LIVES; nothing bounded how many it MAKES (docs 06 §2.10.1/§2.13(b)/§3.1/§8, 92 §31, 93 §M1, 91 A91-D-35)

**The defect.** `BalanceGateRig.run("do_nothing", 1337, 120, "crisis")` does not
finish. From game-day **104** the open-incident roster multiplies by ~2.5–2.9
**per game-hour** — 103 → 357 → 832 → 2,424 → 6,389 → 14,671 → 37,631 →
**89,055** — and the wall clock for one simulated game-hour goes 0.22 s → 269 s
with it. Doc 06 §2.13's own worst-case accounting is **≤ 40 active**. On device
this is an ANR on any long-abandoned save, and gate 29 was already routing around
it with a per-preset horizon and a written warning.

**The mechanism, and the two candidates that were NOT it.** Doc 02 §2.12's
`state_fire_mult` is already `0` for `destroyed`, so a ruin is neither an
ignition candidate nor a spread target; and a `structure_fire` that burns its
building down already goes `FAILED` and leaves the roster in the same sub-step.
Both of the obvious suspects were already correct. What runs away is `crime`:

```
on_tier_enter[4] → spawn_incident{type: crime, count: 1, scope: "district"}
on_tier_enter[5] → spawn_incident{type: crime, count: 2, scope: "district"}
```

Mean offspring **three**, and `scope: "district"` needs no entity at all, so the
process consumes nothing and cannot exhaust itself. Five of the catalog's eight
`spawn_incident` actions resolve to a building and are self-limiting because
buildings run out; these two and `traffic_accident`'s are the three that are not. Its own tier entries drive
the district's stability to zero inside four game-hours, which pins §2.4's
`esc_env` at its 3.0 clamp and collapses the generation time to
`t(1→5) = 3.038095 / (0.80 × 3.0 × 1.6) = 0.79` gh at `crisis`. **RR-26 fired on
every single one of them, on schedule** — `crime`'s own
`on_fail{hold_tier 5, hold_h 1.0}` terminates each incident at ≈ 2.0 gh, which is
exactly the `unanswered_h` maximum the runaway roster measures. Every incident
died on time. There were simply three more of it.

**Ruling: an action that creates an incident from an incident is a RATE, and
every automatic birth in the system answers to one published roster ceiling.**
Doc 06 §2.13(b) adds three numbers and one seam:

```
CEIL    = 40   §2.13's own accounting — the ROSTER bound
RESERVE =  4   slots inside CEIL that doc 06 may not spend
A_CEIL  = 36   where ambient generation, fire spread and cascades stop
KNEE    = 26   §2.10.1's measured worst LEGITIMATE backlog
sat(N)  = clamp((A_CEIL − N) / (A_CEIL − KNEE), 0, 1)   × ambient generation
```

`IncidentSystem.spawn_automatic()` is the single seam every automatic birth
passes through, and the refusal is **deterministic and RNG-free** — it draws
nothing, so a city below `A_CEIL` is bit-identical to one running without the
rule. `spawn()` itself stays open.

**The reserve is not a fudge factor, it is doc 04's one-shot contract.**
`PowerComponentFailed` is emitted once per component and never re-offered;
refusing that incident does not defer it, it strands the component, because
`power_restore_component` has no other caller. So the doc 04 path is admitted
unconditionally and the roster can stand above `A_CEIL`. A first cut without the
reserve measured **42** open on a 200-game-day `crisis` run against a ceiling of
40, and both extras were `PowerComponentFailed`. Four is that measurement
doubled, and a doc 04 admission cannot branch — the only endogenous child a
`transformer_failure` authors is itself an automatic birth — so the reserve is a
bound rather than a leak.

**Second half of the ruling: a cascade may not invent a subject the GENERATOR
would not have found.** Doc 92 §18 states this for the ambient floor; the
building-scoped cascades already obeyed it by returning `""`. `scope: "district"`
now applies the type's own generator eligibility — §2.6(a)'s `population > 0` for
`crime`, nothing for the per-asset types. This alone ends the measured cascade in
its first game-hour; the ceiling is what makes the class of defect impossible.

**What it costs a played city: nothing, and that is measured, not asserted.**
The whole doc 92 matrix — 7 strategies × 3 seeds × 21 game-days — peaks at **13**
open incidents; `sat(N)` is exactly 1.0 at and below 26. Both determinism
baselines (`tools/profile_sim.gd --hash-only` on the starter city and on
`tests/fixtures/bench_city.json`) are byte-identical, all 30 balance gates hold
with no threshold re-fit — gate 29's pinned `standard` insolvency day and its
strict four-preset ordering included. **The
save section is unchanged**: the rule's only piece of state is a rising/falling
edge latch for the two `incident_roster_saturated` / `incident_roster_relieved`
events, and it is DERIVED from the roster on load rather than persisted, so doc
06 §3.3's `incidents` section keeps `section_version: 1` and no save rung is
taken.

**What it buys.** `crisis` `do_nothing`, seed 1337, 200 game-days: peak **37**
open (36 automatic + 1 doc 04), worst single game-hour **0.47 s**, whole run
**89 s** — against a run that could not finish (reproducer:
`tools/profile_decay.gd --days=200 --preset=crisis`). Gate 30 asserts the bound on that
exact run and gate 29's horizons no longer have to dodge the cascade.

**Recorded limit.** `traffic_accident`'s tier-5 cascade has expected offspring
exactly **1** and also invents its subject (`scope: "adjacent_edge"`, the parent's
own tile). It is the critical case: it does not diverge and it does not die, and
from game-day 160 it is what holds the roster at the ceiling on a dead `crisis`
city, at 66–73 ms per game-hour against 5.8 ms quiet. Bounded, correct, and doc
06's ranked open question.

## 26c. WAVE 12 — the difficulty follow-through (binding)

### RR-63 — One difficulty knob per ledger line, never two; and a summary-table row label does not outrank the two formulas that define the knob (docs 03 §2.4/§2.2/§2.9, 05 §9, 91 §17.2, 92 §29.2/§29.3/§29.5/§31, 93 §N1–§N4)

Doc 92 §29 shipped the four difficulty presets as *measurements* and closed with
four ranked questions it deliberately did not answer. Three of the four are the
same defect wearing three hats: **a scalar's SCOPE was never written down, so it
drifted.**

**(a) `E_roads_repair` took two knobs.** `EconomySystem.settle_hour()` computed
the line as `e_roads_repair(roads, M_repair)` and then swept it into
`recurring *= M_exp` with the other seven, so it carried `M_repair × M_exp` —
**2.0000 on `crisis` against 1.2500 everywhere else**, 48 % of the whole
difficulty delta on the expense side, and the entire sign of crisis's founding
net (−$18.70/gh). The decisive argument is not that two knobs are too many; it is
that **the accrual and the payment disagreed**. Doc 03 §2.4 defines this line as
the *accrual* the auto-repair policy realises as `E_oneoff` jobs, and what the
policy pays is `repair_cost_road(class, damage_fraction, M_repair)` — no `M_exp`
anywhere in it. An accrual that does not converge on its own payment is C-07 /
C-08 / C-12 / RR-2's double count one knob down.

**Ruled (doc 93 §N1): `E_roads_repair` takes `M_repair` and is excluded from the
`M_exp` sweep, exactly the way `E_debt` already is.** Doc 03 §2.4's "All ×
`M_exp` except `E_debt` and `E_oneoff`" gains a third exception and states the
rule once: **one difficulty knob per ledger line, never two.**

**(b) `M_rev` says "revenue" and means "tax".** §2.9's table row is labelled
*revenue*; the code applies it inside `revenue_for_building()` only, so crisis's
advertised −15 % measures **−13.2 %**. **Ruled the other way (doc 93 §N2): the
code is right and the label is wrong.** Doc 03 defines the knob twice — §2.2's
per-building formula and §2.2's revenue-floor formula — and both say tax; §2.5,
which authors every non-tax line, never mentions it. One row label does not
outrank two formulas. The decider is a measurement rather than a preference:
**two of the three non-tax lines are held constants** (`HELD_DELIVERED_MWH = 1.5`,
`HELD_FINE_RATE = 3/350`, doc 03 §9 item 6b), measured flat at $93.00/gh and
$3.00/gh on **all four presets** at the founding hour, at 21 game-days and at 48
game-days of total neglect. Difficulty-scaling a seam makes a preset's advertised
strength a property of a placeholder. §2.9 now prints the measured effective
column (+13.23 % / −7.05 % / −13.23 %) beside the advertised one.

**(c) The verb list counted itself wrong twice.** Doc 91 §17.2 and doc 92 §17.6.2
both published an open count without showing the arithmetic, and both were wrong
— first by omitting `cmd_install_backup_generator` entirely, then by not
subtracting `cmd_set_auto_repair_policy` after it got a door. **Ruled (doc 93
§N3): `cmd_install_backup_generator` is doc 05's interface call, not a player
verb** — doc 05 §2.6 gives the generator to doc 04, doc 04 §12 defers it,
`grep -rn fuel sim/power/` returns nothing, and the command as shipped grants a
permanent `coverage_frac` on a dark node for no dollar. It keeps a **written
re-open condition** rather than a permanent closure, which is the difference from
§J3's `cmd_road_repair`. Both tables now show the subtraction: 8 − 1 ruled − 1
doored − 1 ruled = **five** open.

**What it cost the default preset: nothing, and that is proved three ways** (doc
92 §32.1) — the four state hashes on both cities and both paths, all 63 cells of
the seven-strategy matrix, and `standard`'s `do_nothing` insolvency day, which is
**76 / 75 / 74 on the same three seeds after 76 game-days of decay**. The last one
is the proof that matters: a 24-hour hash and a 21-day matrix both measure a city
that is still nearly the city it was handed.

**What it cost the other three, said plainly:** `casual` lost 5 game-days of rope
(104–110 against 109–116), `hard` gained 4 and `crisis` gained 6 (57/56/56 and
41/42/40), the strict ordering held on every seed, and crisis's founding net moved
**−$18.70 → +$44.47/gh**. Gate 29's horizons re-base to `{120, 90, 70, 55}`; every
threshold it asserts is unchanged in kind and three are unchanged in number,
including `standard`'s 76 ± 6 pin.

**Two corrections to §29.5's own arithmetic, found by implementing it.** Step 2
of §29.5(a) predicted crisis would found at +$99.73/gh; it computed the
un-compounded road bill as `157.90 × 1.25`, which is `M_exp`, where the ruling
applies `M_repair`, `157.90 × 1.60`. The measured answer is **+$44.47**. Step 3
blamed `Balanced`'s flat `RESERVE_FLOOR` for the frozen crisis agent, but the
agent holds `max(floor, one game-day of expense)` and step 3's own numbers show
the payroll term winning ($17,968 > $12,000). The floor becomes a fraction of the
founding purse anyway — `0.48`, which reproduces `standard` to the dollar — because
the principle is right; what actually unfroze the agent was (a).

**Ruling, in one line: a difficulty scalar declares its SCOPE in the document that
authors it, and a test asserts the scope against the live data file.**
`tests/test_economy.gd::test_one_difficulty_knob_per_ledger_line` settles the
founding ledger on all four live `data/difficulty.json` rows and asserts, per
preset, that the seven swept lines are exactly `M_exp`, `roads_repair` is exactly
`M_repair` and explicitly not `M_repair × M_exp`, `debt` is neither, `tax` is
exactly `M_rev`, and the three non-tax lines are exactly 1.000. A retune moves the
expectation with the file; only a change of scope fails.

## 27. WAVE 13 — the accessibility root fix, and the veil (binding)

*One line of `ui/theme_builder.gd` took the whole-deck a11y sweep from 408
findings to 8; four small layout fixes took it to 0; `640 × 340` became a gate
box; §2.3's left rail became one solved stack; and doc 13's veil got a surface.
`ui/`, `tests/`, `tools/`, `data/ui.json`, `data/strings.en.json` and
`game/ui/ui_root.tscn` only — `sim/`, `game/` scripts and every balance table
are untouched, and `tools/profile_sim.gd --hash-only` is unchanged on both
cities before and after.*

### RR-64 — A number that is already scaled must not be handed to the scaler

`ThemeBuilder.build()` computed a button's vertical content margin from
`touch_min_dp(cfg, text_scale, larger)` — a figure that has **already** been
multiplied by the text scale — and then, seventeen lines later, handed the
finished `Theme` to `scale_theme(theme, text_scale)`, which multiplies every
`content_margin_*` again. The arithmetic, at 130 % with larger touch targets:

```
touch_min       = ceil(56 × 1.3)                     = 73
pad_v           = max(4, ceil((73 − 14×1.4) × 0.5))  = 27      ← already scaled
scale_theme     = round(27 × 1.3)                    = 35      ← scaled again
StatChip height = 35 + 35 + round(16×1.3)×1.4        ≈ 100 dp
A3 floor                                             = 73 dp
```

**Every themed button in the deck was 37 % taller and wider than the gate it was
sized for**, and at 150 % the surplus is 32 dp per control. That is the 89 × 100
chip of A91-D-21, the 94 dp drawer handle of doc 12 D-46, the
`407-against-392` top-bar arithmetic of D-51 and the 126 dp `SpeedButton`
clipped to a 56 dp sliver in A91-D-29. Four separate S-sized fixes were priced,
argued and shipped against symptoms of one line.

**Ruling: a derived value crosses a scaling boundary once, and the boundary is
named.** The fix is `touch_min_dp(cfg, 1.0, larger)` — build the base theme in
base units and let the scaler own the scaling. It is a **no-op at
`text_scale == 1.0`** (the two figures are equal there), which is what keeps
every screenshot in the repository valid, and
`tests/test_ui_scaffold.gd::test_a_button_stylebox_is_scaled_exactly_once` fails
on the old theme with `a StatChip's own box is 95 dp against an A3 floor of 73`.

Measured, `--screen=all --audit --strict`, six boxes × three text scales:
**408 findings → 8** on the one line, **→ 0** with the four layout defects it
exposed. The 100 % row does not move by a single finding at any box.

### RR-65 — Three placers, three measurements, one column

Doc 12 §2.3's left rail — the BUILD FAB, the overlay button, the speed rail —
lives in three files on **two layers**, so no `solve_corner_rail()`-style sibling
walk can find it, and each file called `UIWidgets.place_in_rail()` with its own
control's measurement. Two of those measurements are taken at different moments
in the frame:

| placer | when | measured pitch at 880 × 400 / 130 % / larger |
|---|---|---|
| `OverlayRail._build_button()` | inside `setup()`, before the theme has propagated and before any layout | **73** (its own `custom_minimum_size`) |
| `CityHUD.refresh()` | every frame, after layout | **93** (the laid-out size) |

Result: the overlay button at y 210 … 303 and the speed rail at y 89 … 182 —
**28 dp of gap where `data/ui.json.layout.rail_gap_dp` says 8** — and
`HudModel.top_bar_left_inset()` solving the top bar against a rail top that no
button actually had. It produced no *finding*, which is why three waves of green
sweeps did not see it: a stack with the wrong pitch is still a stack of
non-overlapping rects.

**Ruling: a shared pitch has one owner, and it is not any of the things being
pitched.** `UIWidgets.solve_rail_stack()` takes every member, computes one pitch
from the tallest, and places all of them; `UIRoot` collects the members (they
answer `rail_entry()`, duck-typed like `corner_rail_entry()`) and calls it from
`_process`, from `_recompute_layout` and at the end of `force_layout` — the last
because a headless mount never gets a frame. Indices are fixed and gaps are
deliberately *not* closed, unlike the corner rail: the FAB hides during
placement, and a rail button that slid down into its slot would move under the
player's thumb mid-gesture.

`place_in_rail()` survives as each file's **first** placement, so a rail button
does not spend a frame at the wrong offset; the solver overwrites it as soon as
there are real metrics to solve against.

### RR-66 — A slicer with no surface is not a feature

`RestoreCursor` (eleven resumable restore steps, Wave 12) and
`CatchUpPlanner.plan()` (boundary-aligned offline segments, Wave 7) were both
built, both tested, and **neither had anything to draw**. Doc 13 §2.9 has
written `veil.show()` in its pseudocode since it was drafted and doc 13 §2.9.1
added a second one in front of it; what shipped instead was a comment in
`game/main.gd` saying the title door *is* the veil — which covers CONTINUE and
covers nothing else. Not a resume, not a slot load from S8, not the catch-up
that follows any of them.

**Ruling: the mechanism and its surface land in the same wave, or the mechanism
is unverifiable.** Doc 12 §2.20 / D-60 builds S15 on the deck's own pattern
(headless model + code-built view, its own layer, two preview states, a
`SURFACES` row, thirteen model tests). It is the cheapest screen in the project —
a scrim, two labels and a `MeterBar`, with **no tap targets at all**, which is
itself a requirement rather than an economy: doc 08 §2.15.2 forbids anything
querying the sim between restore steps, and a pressable control during a
half-restored city is exactly what would.

**One deviation from doc 13 §2.9.1, recorded in both documents.** That section
asks for a spinner over the restore because `completed() / step_count()` is
"honest about how many steps have run and dishonest about how much time is
left". S15 ships a stepped **bar with its unit named under it** — `Step 7 of 11`
— because (a) naming the unit answers the objection rather than hiding from it,
and (b) a spinner is the one animation in the deck that A8's `reduce_motion`
would have to suppress, and *a loading animation that has been suppressed is
indistinguishable from a hung app*, which is the failure §2.9.1 spends a
paragraph avoiding. The catch-up phase takes doc 13's own bar unchanged, where
the fraction *is* proportional to time.

**What it left behind, filed as A91-D-31**: `game/main.gd::_on_app_resumed`
walks the planner's segments in a synchronous `for` loop, so a 12-hour absence
runs 720 coarse steps inside one frame and the catch-up veil is a message rather
than an animation. Doc 13 §2.9's `advance_coarse_sliced(12)` +
`await get_tree().process_frame` has never been wired; the veil is now the half
that was missing on the other side of it.

### RR-67 — The box a data file calls the floor

`data/ui.json.layout.min_safe_box_dp` is `[640, 340]`. Doc 12 §2.18's A2 names it
as the size the layout must survive 150 % at. It appeared in **no `BOXES` list,
no sweep and no test** until this wave — the one box the project's own data calls
the minimum was the one box nothing ran, which is how a 26 dp overflow on the
title screen's CANCEL survived three waves of green sweeps (A91-D-29).

**Ruling: a geometry a data file declares is a geometry the suite runs.** It is a
row of `tests/test_ui_audit.gd::BOXES` and of `tools/ui_preview.gd`'s sweep list,
added in the same commit as the layout fixes — which is exactly what A91-D-29's
filing demanded and what it is closed against.

### RR-68 — A wrapping container measures its height from its width

Three of this wave's four layout fixes are doc 12 D-47's rule applied one screen
over — *an `HBox` asks for the SUM of its children; a flow container asks for its
widest child* — and the third of them surfaced the rule's companion, which was
written down nowhere:

**a flow container's minimum HEIGHT is a function of the width it has been
given.** `CoachMark._layout_bubble()` derives the bubble's width from the
bubble's own minimum and then takes its height from the same minimum — so once
the button row became an `HFlowContainer`, the two-line row was *measured* as a
one-line row and `GOT IT` landed 64 dp below a 360 dp display. The fix is to
measure twice with a `UIRoot.sort_tree()` between. The same trap is why S15's
card is capped by `UIWidgets.card_height()` even though its content is three
short lines: an autowrapped `Label` reports **771 dp** of minimum height on the
frame before it has been given a width, and Godot invalidates that cache through
the message queue rather than synchronously, so the cap — not the measurement —
is what keeps the card on screen for that one frame.

**Ruling: after choosing a width for a wrapping container, re-read its height.**
Recorded here because it will be met again — every `HBox` → `HFlowContainer`
conversion this project makes from now on carries it.

## 28. WAVE 14 — the last two dead inputs (binding)

### RR-69 — A seam with a plausible DEFAULT on the far side is the hardest kind to notice, and there were two of them in one file (docs 07 §5, 09 §2.6.1/§5, 10 §2.10/§2.12/§5.1, 91 A91-D-32, 92 §33, 93 §O)

`RoadNetwork` declares two injectable siblings at the top of the file:

```gdscript
var profile_weights_of: Callable = Callable()  # doc 09
var weather_state_of: Callable = Callable()    # doc 07
```

**`CitySim` assigned neither. Not at boot, not after a restore, not anywhere.**
Wave 12's determinism agent found them and filed them as its open q1/q2; this
wave closes them. What was actually shipping, on every city anyone has ever
played:

* `_profile_weights(district)` fell through to `data/roads.json`'s
  `default_profile_weights` **for every district**, so doc 10 §2.10's four
  authored land-use curves were four copies of one curve and doc 09's
  `district_profile_weights` interface had no implementation on either side.
* `_weather_state()` fell through to the field's initialiser, the literal string
  `"clear"`, **for the life of the process**. `wx_cong_add` was 0.00,
  `wx_slowdown` was 0.00 and `wx_wear_day` was 0.00 — so **rain had never slowed
  traffic in a shipped build and no road had ever worn faster for being wet**,
  and eleven authored rows of `data/roads.json`'s `weather` table were
  unreachable by any code path.

**The lesson is the shape, not the two fields.** A stub crashes, a TODO greps,
and an unimplemented method fails a test. A `Callable()` with a *well-defined
degraded default behind it* does none of those things: every consumer gets a
plausible number, every test passes, and the profiler shows the code running.
The same shape produced A91-D-19 (four authored difficulty presets behind a
compiled-in `standard` row) and doc 06's Chebyshev stand-in. **The tell is a
fallback whose own comment explains what will replace it** —
`data/roads.json`'s `_default_profile_weights_note` said *"Delete the fallback
once doc 09 ships the real per-district building mix"*, and had said it since it
was written.

> **Ruling.** An injected sibling that has a default must have a test that asserts
> the sibling is INJECTED, not merely that the default is sane —
> and it must assert a CONSEQUENCE, because a `Callable` that returns the default
> is perfectly valid. `tests/test_city_sim.gd::test_the_roads_land_use_and_weather_seams_are_injected`
> is that test for these two: every edge carries a district id, and the four
> founding districts disagree about `D_tod` by more than 0.05.

**What shipped.** Doc 09's `DistrictRegistry` gains `profile_weights(id)` and
`set_building_mix(mix)` — the publication doc 10 §5.1 has always named — holding
the normalised `Σ(population + jobs)` share per profile, computed from doc 02's
roster. `CitySim._district_profile_weights` is the wire, memoised on
`(roster_revision, membership_revision)` rather than given a cadence (doc 93
§O1), and `CitySim._road_weather_state` is the other,
`weather.get_state().to_lower()` onto doc 10 §8's table — the same fold doc 05's
water system has always used for `weather_kind`.

**Both are injected BEFORE `bootstrap()` now, and the ordering closes a second
defect.** RR-61 recorded that `_assign_districts()` inside `bootstrap()` saw an
invalid `Callable` and wrote no `district_id` on a live founding city while the
restored twin carried the real district on every edge — and correctly called it
*inert, only because `profile_weights_of` is injected by nothing*. It is not
inert any more, so the assignments moved above the `bootstrap()` call.
`district_of_tile` keeps its re-stamping setter as the belt to these braces.

**The hashes moved, and this time that IS the deliverable.** Doc 92 §33 carries
the balance derivation and the gate re-fit. For the record, the digests either
side (`tools/profile_sim.gd --hash-only`, 24 coarse game-hours + 2 fine, seed
1337, on the founding city and on `tests/fixtures/bench_city.json`):

| | HEAD (Wave 13) | this wave |
|---|---|---|
| founding, coarse 24 h | `e8bffba1853f248e…` | `0b67cd2273a5115a…` |
| founding, fine 2 h | `08bfdfaa3dd65281…` | `4f9f383038fbe383…` |
| bench, coarse 24 h | `e760f9305d21d331…` | `bbe658aeeaa9f855…` |
| bench, fine 2 h | `bd2d8f30d25827f4…` | `158501b8845b056f…` |

**One row of the ledger moved, and only one** — which is the evidence that the
wiring did what it says and nothing else. Founding `do_nothing`, `standard`, mean
over the first 24 game-hours, measured with `tools/measure_founding_ledger.gd`
either side of the same patch (`git diff` → `git checkout --` → `git apply`;
never `git stash`, whose ref is shared across worktrees):

| line | before | after |
|---|---|---|
| gross revenue | 839.81 | 839.81 |
| `building_maint` · `departments` · `fleet` · `grid` · `generation_fuel` · `water` | — | unchanged to the cent |
| **`roads_repair`** | **158.42** | **183.92** |
| net $/gh | +333.01 | **+307.51** |

**Four of the thirty gates are re-fitted, each with its derivation in the test
file itself, and twenty-six are not touched.** The 30-gate contract is a contract
about *what is asserted*, not about the numbers a measurement produces, and the
rule this wave applied is the one doc 92 has applied since §13: **re-fit a gate
only where its derivation legitimately moved, and record the old number beside
the new one.**

| gate | what moved | before → after |
|---|---|---|
| **2** founding first game-day net | `wx_wear_day` stopped being 0.00 | `STARTER_FIRST_GAME_DAY_NET_EXACT` 8,004.047 → **7,380.321** |
| **19** the ambient dispatch beat | doc 06's `f_flow` finally sees a congestion index that moves | band `[62, 132]` → **`[100, 200]`** around a measured 92 → 146 |
| **21** the curriculum is paced | the agent's purse fills more slowly | `CURRICULUM_OPENING_BEAT_H` 45 → **58** |
| **29** neglect is fatal and ordered | every preset dies sooner; the ORDERING is preserved | `PRESET_LIFETIME_FLOOR` 25 → **18**, `STANDARD_LIFETIME_DAYS` 76 → **69** |

**Gates 1 and 2b were NOT re-fitted and that is the more interesting half.** The
founding *hour* is clear weather, so it moved only by the land-use half —
`roads_repair` 157.90 → 158.46, net +337.05 → +336.49, i.e. **0.17 %** against a
±1 % band. `data/economy.json`'s two `_EXACT` hour anchors keep their values and
gain a note saying why: absorbing a drift that small into an anchor is the
mistake the file's own `_k_rounding_note` declines to make. **Recorded, not
absorbed.**

Two more that did not move, and are worth naming because they could have:
`tests/test_save_determinism_days.gd` takes its saves at 2 h, **26 h**, **50 h**
and seven game-days — every one of the last three lands inside rain on the
founding city now — and it is green, so **a city saved mid-downpour restores with
the same wet roads and advances bit-identically**. And gate 30's 200-game-day
`crisis` run is green with the roster still bounded, so §33.5's doubled accident
channel does not reach doc 06 §2.13(b)'s ceiling.

**And it is free, which RR-43 makes it easy to check.** The congestion pass
already resolved the per-district weights once per district per pass and handed
`_d_tod_memo` a key it was already keyed on; all this wave adds is a `Vector2i`
compare and one dictionary lookup per district per pass. Measured back to back on
a quiet box, `tools/profile_congestion.gd --city=res://tests/fixtures/bench_city.json`:

| | before | after |
|---|---|---|
| `RoadNetwork.full_pass` | 2.9372 ms/game-minute | **2.9486** (+0.4 %) |
| `roads_congestion` SimTick mean | 3.8416 ms | **3.7267** |
| `CongestionModel.last_moved` census | 3,092 of 3,092 | 3,092 of 3,092 |

RR-43's refusal is untouched: `hour` still reaches every edge through `D_tod`,
so the skippable set is still empty — and it is now empty for a second reason,
because `D_tod` differs per district as well as per hour.

## 29. WAVE 14 — the four platform items with known fixes (binding)

Four rows the previous waves had already diagnosed and left standing: the
exporter's permission list, the synchronous resume, doc 04's cold transformer
memo, and `TrafficFeed._by_edge`'s insertion order. **Three of the four were
diagnosed correctly. The first was not** — RR-70 measures it and reverses the
finding, which is why that entry is the longest one here and why the change it
ships is redundancy rather than a repair.

**Every one of them is hash-neutral, and the proof is the same instrument in
every case** —
`tools/profile_sim.gd --hash-only` on `data/starter_city.json` and
`res://tests/fixtures/bench_city.json`, coarse 24 h and fine 2 h, unmoved:

| | before | after |
|---|---|---|
| founding, coarse 24 h | `e8bffba1853f248e…` | `e8bffba1853f248e…` |
| founding, fine 2 h | `08bfdfaa3dd65281…` | `08bfdfaa3dd65281…` |
| bench, coarse 24 h | `e760f9305d21d331…` | `e760f9305d21d331…` |
| bench, fine 2 h | `bd2d8f30d25827f4…` | `bd2d8f30d25827f4…` |

### RR-70 — The permission list had TWO possible sources and the failing build had NEITHER. Measure the artifact, and make sure the artifact is the one you built (docs 13 §2.6/§2.7/§3.4/§10.8/§11.2, 91 §13)

**The finding this wave was sent to fix, and it does not survive measurement.**
The third Fold session recorded that the plugin's four `<uses-permission>`
elements never reach the APK, that manifest merging carries `<application>`
children and not permissions, that Godot's exporter builds the list from
`export_presets.cfg` alone, and therefore that doc 13 §2.6's self-containment
rationale was false. That reading was written into
`android/plugins/slacum_native/src/main/AndroidManifest.xml` in capitals, into
doc 13 §2.6, into §3.4's preset block and into doc 91 §13. **It is wrong.**

**The 2×2, `aapt2 dump permissions` on four locally built debug APKs** (Gradle
path, `godot --headless --export-debug "Android"`, build-tools 36.1.0). Each arm
is a full export from a cleared `build/`, and the AAR arms are real rebuilds
through `tools/build_native_plugin.sh`:

| plugin AAR declares the four | `export_presets.cfg` declares the four | APK requests |
|---|---|---|
| yes | yes | **4** ← shipped state |
| yes | no | **4** |
| no | yes | **4** |
| no | no | **0**, and the plugin meta-data plus both receivers still merge |

**Either source suffices, and the bottom row reproduces the phone reading
exactly** — zero requested permissions against a package whose plugin loads and
whose `componentsDeclared` is 6. So the APK on the Fold was built against an AAR
that predated the plugin manifest's permission block, and **the root cause is the
STALE AAR the session immediately before it had just diagnosed and fixed by
tracking the binary.** The same defect, one symptom later, attributed to the
wrong file. Doc 13 §2.6 was right all along; §11.2's `aapt2` block was right; and
§10.8's "superseded by §11.2" was right. Every one of those was corrected in the
wrong direction and is corrected back here.

**The ruling is what to do about a fact with two sources.** `export_presets.cfg`
**keeps** the four flags this wave added:

```ini
permissions/post_notifications=true
permissions/receive_boot_completed=true
permissions/vibrate=true
permissions/wake_lock=true
```

on all three presets, not because the plugin manifest is insufficient — arm 2
proves it is sufficient — but because **arm 3 is the one that matters to a
project a stale AAR has now cost two sessions.** With the preset flags in
place the APK's permission set no longer depends on a 36 KB binary being current;
it depends on a committed, diffable text file the exporter reads directly, and a
stale AAR degrades from "silently drops a runtime permission" to "nothing".
`custom_permissions` stays `PackedStringArray()`: all four are in 4.7.2's own
permission table (`"permissions/" + PERMISSION.to_lower()` is the option key), so
the boolean flags are the idiomatic spelling and
`test_the_forbidden_permissions_are_absent`'s "presets add no permissions of
their own" assertion keeps its meaning.

Shipped state, read back off the binary:

```
$ aapt2 dump permissions build/slacum-debug.apk
package: com.slacumcity.game
uses-permission: name='android.permission.POST_NOTIFICATIONS'
uses-permission: name='android.permission.RECEIVE_BOOT_COMPLETED'
uses-permission: name='android.permission.VIBRATE'
uses-permission: name='android.permission.WAKE_LOCK'
```

Four, exactly; no `INTERNET`, so the Data Safety story is intact; `minSdk 29`,
`targetSdk 36`, `arm64-v8a`; and `aapt2 dump xmltree` confirms the plugin
meta-data and both receivers.

**The gate that would have caught the stale AAR without a phone now exists.**
`tests/test_release_plumbing.gd` asserted what the plugin manifest AUTHORS and
asserted that `custom_permissions` was empty; it had no assertion at all about
what the presets REQUEST, so the second source could be missing silently.
`test_every_preset_requests_exactly_the_four_permissions` closes that: the four
flags are `true` on all three presets and a scan of every `permissions/*=true`
line finds those four and nothing else. It does not catch a stale AAR — nothing
headless can — but it means a stale AAR can no longer take a permission with it.

**The lesson, stated where the next session will read it, because it has now cost
two:** *a measurement of a binary is a measurement of THAT binary.* `dumpsys
package` on the phone was correct about the APK it was given and wrong about
every APK the repository can build, and the difference is one build input that
was not committed at the time. The 2×2 above costs four exports and twelve
minutes, and it is what turns "the manifest does not work" into "this artifact
was stale" — which is a different fix in a different file.


### RR-71 — A memo whose whole input is boot data should be filled at boot (docs 04 §2.2, 10 §2.6/§9 q13, 13 §2.9.1)

`CitySim._transformer_cover` answers doc 10's G-6 question — *is this tile
powered?* — for every signalised intersection on every tick. It depends only on
`loader.power`, which is written once at boot and never again, and it was filled
**lazily, one tile at a time**, by a scan that re-derived every transformer's
global tile, radius and id string *inside* the per-tile loop. RR-60b already
measured the total and moved it under the veil: **96 ms on the benchmark city**,
emitted as five ~21 ms `roads_signals` restore steps.

**Ruling: derived state whose whole input is boot data is filled once, at boot,
in whichever loop order is cheapest — not on demand in the order a consumer
happens to ask.** `_boot_power()` now resolves the transformers into packed
columns and stamps every covered tile from the transformer side. The winner per
tile is the same `argmin (chebyshev distance, id)` restricted to
`distance <= radius` that the per-tile scan computed; that is order-independent,
so tile-major and transformer-major land on the same id for every tile, and the
covered SET is identical because it is the union of the same square service
areas. A memo MISS is therefore a complete answer — *uncovered, and lit* — rather
than a cache fault, which is what keeps the query O(1) for the tiles no
transformer reaches.

Interleaved A/B, three rounds, no arm overlapping, `tools/profile_save.gd`
(`--steps` and the new `--boot-only`), workstation carrying two sibling suites:

| | before | after |
|---|---|---|
| `roads_signals` steps, bench | 109.5 / 108.9 / 107.6 ms | **1.54 / 1.62 / 1.51 ms** |
| restore total, bench | 316.0 / 315.0 / 313.7 ms | **207.2 / 207.8 / 204.6 ms** |
| cold `CitySim.boot()`, bench | 211.3 / 215.9 / 219.9 ms | **222.4 / 225.5 / 228.7 ms** |
| cold `CitySim.boot()`, founding | 38.7 / 38.5 / 38.7 ms | **39.2 / 38.7 / 38.8 ms** |
| memo entries after boot | **0** — it fills in play, to one per signalised node (2,024 on the bench city, RR-60b) | **11,236** bench / **1,072** founding |

**The trade, stated plainly: +9.4 ms once per process launch buys −108 ms off
every load.** A boot happens behind the splash before any city is on screen; a
restore happens behind the veil the player is watching. The memo grows to one
entry per covered tile — **2,024 → 11,236** on the benchmark city, the *union* of
144 level-5 squares rather than the 41,616 stamps that fill it. At Godot's
Variant sizes that is on the order of a megabyte; the entry count is the measured
number and the megabyte is arithmetic on it.

**Hash-neutrality is proved on the ANSWER, not on the digest.**
`tests/test_city_sim.gd::test_the_warm_transformer_memo_answers_what_the_authored_scan_answers`
re-implements the pre-Wave-14 tile-major scan verbatim as an oracle that shares
no code with the thing under test, and walks every tile in the transformer
envelope plus a 10-tile margin — both sides of every service boundary and the
uncovered ground beyond. Zero mismatches, and `--hash-only` is unmoved.

`tools/profile_save.gd` gained a `boot (cold sim)` row and a `--boot-only` mode
for this A/B, because a table that could see the restore end of the move and not
the boot end would have made the move look free.

### RR-72 — Order-canonical containers, not order-tolerant consumers (doc 10 §2.15/§9 q14)

`TrafficFeed._by_edge` (`edge_id → [vehicle ids]`) was insertion-ordered, and a
shipped city produces two insertion histories for the same feed: **live**, a car
is appended to the edge it spawns on and again to every edge it hops onto, so a
list is in visit order and the key order is first-touch; **restored**,
`deserialize` walks the saved roster in ascending vehicle id. The two disagree on
every city with a hop in it. It was inert because the one consumer — `rebalance`
— copied each list, sorted it, and iterated `_sorted_keys()`.

**Ruling: when a container's order is load-bearing, the container owns it.** An
order-tolerant consumer is a defence that has to be remembered, and the first
reader to forget it breaks save→load→advance identity in a way that only
reproduces after a hop — the same class of defect as RR-60's ULP and RR-60b's
lit signals, each of which cost a wave to find. `_attach` / `_detach` now place
by binary search, so every per-edge list is ascending; a maintained `_edge_keys`
`PackedInt32Array` carries the keys ascending; `edges_with_vehicles()` and
`vehicles_on_edge()` are the seam and `rebalance()` sorts nothing.

`tests/test_roads_traffic_order.gd` asserts over the **raw** containers with no
sorting on the way in — which is exactly the assertion an unsorted future
consumer would need — plus the parallel-index invariant (`_edge_keys` equals
`sorted(_by_edge.keys())`, and no emptied edge is ever left behind as an empty
list) across spawn, hop, despawn, drain, refill and reset. **Against the
pre-Wave-14 append behaviour the file produces 356 failures**; against the
shipped one, none. Hash-neutral on both cities, coarse and fine.

### RR-73 — The budget belongs to the shell, the unit belongs to the sim (docs 13 §2.9, 01 §2.10, 91 A91-D-31)

`game/main.gd::_on_app_resumed` ran `CatchUpPlanner`'s segments in a synchronous
`for` loop, so S15's catch-up veil drew for one frame and then froze until the
whole absence had been simulated — 720 coarse steps in the worst case, at 6.3 ms
(founding) to 190 ms (bench) each. Doc 13 §2.9 has specified the other shape
since it was drafted.

**Ruling: `CitySim.begin_catchup(plan) -> CatchUpCursor`, and the shell spends
units against its own wall clock.** Two parts of §2.9's pseudocode did not
survive contact with the shipped planner, and are recorded rather than quietly
dropped:

* **`advance_coarse_sliced(hours_per_slice)` returning "done yet?" cannot advance
  a real resume.** A returning player's plan is not coarse hours alone: it
  carries a fine head-align segment and a 40-tick fine tail (doc 91 D-1), and a
  coarse-only entry point has nothing to do with either. The cursor takes the
  whole plan.
* **The budget cannot live in `sim/` at all** — constitution §5 forbids reading a
  clock there, which is the same argument `RestoreCursor` already makes and which
  §2.9's own text makes too ("the shell decides the budget"). So the unit is one
  coarse hour or one fine tick and the shell loops on `Time.get_ticks_usec()`.
  `hours_per_slice = 12` came from the retired 0.60 ms estimate; at the measured
  step costs a 12 ms budget spends **one** step per frame on every city in this
  project, which is §2.9's own worst-case row.

**Slicing may not change the simulation, and the seam that guarantees it is
`TickScheduler.advance_coarse_n`'s `catchup_index_base`.** A coarse step reads
`ctx.catchup_index` / `ctx.catchup_total`; doc 03's `offline_yield_mult` and doc
07's 72-hour offline event gate both consume them, and they index the SEGMENT,
not the slice. The cursor issues
`advance_coarse_n(1, true, hours_done_in_segment, segment_hours)` where the loop
issued `advance_coarse_n(n, true, 0, n)` once, and `catchup_begin()` fires once
per coarse segment (doc 07 C-55) rather than once per frame.

`tests/test_catchup_cursor.gd` proves bit-identity against a verbatim copy of the
old shell loop, on **both cities**, at **1, 3, 12 and unbounded** units per frame,
on `state_hash()` **and** on the drained event stream — an away report is built
from `sim.bus.drain()`, so two resumes that agree on the hash and disagree on the
stream are still two different resumes. A second test pins the index mechanism
directly through a probe `SimSystem`, so a regression names its cause and not
only its symptom.

ANR safety is unchanged and still structural: a step longer than the budget runs
to completion, so the worst blocked frame is one coarse step against the 5 s line.

**Two shell-side consequences of the catch-up no longer being one frame, and both
are integration decisions rather than UI ones — which is what A91-D-31 reserved
for the lead when it declined to fix this itself.** First, **`SimHost` must be
paused for the duration**: it is a separate node with its own `_process`, and
unpaused it adds `delta × 60` to `clock.residual_game_ms` and spends LIVE fine
ticks *between* the plan's slices, so the sliced resume would land on a different
city from the synchronous one. That pause is a determinism requirement, not
tidiness, and it is the one line of the integration that is not optional. Second,
a player can now background the app **while the veil is up**, which was
unreachable when the catch-up was atomic; a second `_on_app_resumed` therefore
drains the unfinished cursor on the spot and then plans the new absence, rather
than dropping it. Draining synchronously is exactly what this path did with the
whole plan at HEAD, so the worst case is no worse than the frame it replaces.

The shell integration is an exact snippet — `game/main.gd` is the lead's.

---

## 30. WAVE 13 — the final ledger: the last two rulings, and the count (binding)

*Two questions that had each outlived a wave by being ranked instead of answered,
and one number the project needs to be able to quote from one place. This section
changes no `sim/`, no `data/`, no `game/` and no `ui/`; it is rulings and
arithmetic. **RR-76 is the count**, and it supersedes RR-47's.*

### RR-74 — A starting purse is a RESERVE, and a difficulty is defined by the cushions it removes (docs 03 §2.9, 92 §32.7/§33, 93 §O1, 91 §20)

**The question.** Doc 92 §32.7's ranked item 1: the founding purse buys
**3.60 / 2.07 / 1.25 / 0.729** game-days of the founding city's own expense
across `casual` / `standard` / `hard` / `crisis`, so `crisis` is the only preset
whose purse does not cover one game-day of bills. Raise it, or rule the
knife-edge?

**Ruled: the knife-edge. `economic.crisis.starting_treasury` stays $12,000**, and
`data/difficulty.json` is not touched — so the ruling is hash-neutral on all four
presets by construction, not by measurement.

**The reasoning that generalises, which is why this is an RR and not just a doc
92 section.** Four arguments — the first two about *reading a ratio correctly*,
the last two about what a tuning table is for. Each names a mistake this project
could make again against any other knob:

1. **A ratio needs its denominator checked before it is believed.** "Purse ÷ one
   game-day of expense" sounds like solvency and is not: the founding city on
   `crisis` nets **+$44.47/gh** (doc 92 §33.1), so expense is paid out of revenue
   and the purse is a *reserve*. Left completely alone a `crisis` city takes its
   $12,000 to **$20,657 by game-day 10** and does not close negative until
   game-day **41** (doc 92 §33.2, re-measured). The figure that reads like "one
   day from ruin" describes a city that grows its purse by 72 % before it spends
   a dollar of it.
2. **Before treating a value as an outlier, check whether it is on the curve.**
   The coverage rungs are 1.7434 / 1.6556 / 1.7109 — mean 1.703, span ±2.6 %,
   the most regular ladder in the file. Extend the mean of the two rungs `crisis`
   is not in one rung past `hard` and it predicts **$12,080**; the authored value
   is 12,000, **0.66 % low**. The "outlier" is the ladder's own extrapolation of
   itself, and the proposed fix — $16,452 for exactly 1.000 game-days — would put
   the last rung 27 % off the ladder, ten times its spread.
3. **Never tune shipped data to satisfy a harness threshold.** `grep -rn
   RESERVE_DAYS_OF_EXPENSE sim/ game/ ui/ data/` returns **nothing**. The only
   two hits in the repository are `tools/playtest.gd:1606` and `:1885`. The
   1.0-game-day line exists solely inside the scripted agent's
   `operating_reserve()`, already ruled a harness artifact in doc 93 §N4. A
   preset retuned to make an agent's private prudence rule work is a game tuned
   to its test.
4. **A difficulty preset is a set of REMOVED CUSHIONS, not a set of scaled
   numbers, and the two read differently.** `crisis`'s column carries four knobs
   that take a safety net away rather than scale one: `starting_treasury` 0.48×
   standard (the largest single departure in a row whose every multiplier is
   0.85–1.60), `REV_FLOOR_FRACTION` 0.10 against 0.18, `relief_grants_per_era`
   **0**, and `soft_suppression` **false**. Three of the four are absolutes. A
   knob that looks extreme against the multipliers beside it should be read
   against the *absolutes* beside it first.

**The re-open condition, recorded so the question is not re-asked without new
evidence:** a measurement showing a *player* — not `tools/playtest.gd`'s agent —
cannot take the first meaningful action on `crisis` inside the founding session.
The arm that would show it is `curriculum` on `crisis` failing doc 09 §2.14's
level-1 objectives inside gate 21's horizon. If it is ever moved, the number is
$16,452 and gate 29's four assertions are what the change re-proves.

**Applied:** doc 93 §O1 (the ruling), doc 92 §33.1–§33.2 (the tables and the
derivation), doc 92 §33.4 (the ranked list, re-headed).

### RR-75 — A SECTION rung is sufficient when the body's shape holds; a rung is never a date stamp (docs 08 §2.8, 05 §3.2, 10 §3.2, 93 §O2)

**The question, asked three times now.** Wave 13's determinism fix took
`water.section_version` 2 → 3 and `roads.section_version` 2 → 3 (RR-60 /
RR-60b) and left `city.section_version` at 6. Did the city body owe a rung beside
them as an epoch marker?

**Ruled: no.** Doc 08 §2.8's second bullet already answers it — *"`section_version`
inside every section — owned by that section's system, with its own independent
ladder. Adding a field to `power` bumps `power.section_version`, not the
envelope."* A ladder a sibling section can force is not independent, and
independence is the entire reason §2.8 gave every section one. The ruling is now
in doc 08 §2.8's own body as a rule with a table, rather than in a note under one
shipment where the next wave does not find it.

**Three counters, three triggers, and no counter may be forced by a change it
does not own:**

| counter | MOVES when | does NOT move when |
|---|---|---|
| envelope `schema_version` | the section **registry** changes — a section appears, disappears, splits, is renamed, or a top-level key moves *between* sections | any section changes its own contents |
| `<section>.section_version` | that section's own **shape** changes, or the **rules under which that section's state is advanced** change | a sibling section takes a rung |
| `city.section_version` | the same two triggers for the `city` section — **plus** a rules change no single section owns (scheduler, phase order, cross-section association) | `water`, `roads` or any other section takes a rung of its own |

**The v1 → v2 argument is the reason for the ruling, not against it.** That note
is this project's strongest statement that a version records *rules* and not only
*shape*: "a save is a promise about what the binary that wrote it would do next",
and "`section_version` is the only field a future migrator can key on to know
which set of rules a body was last advanced under". The field it names is **the
changed section's**. When water's rules moved, `water.section_version` became
that key. A `city` rung beside it would be a second record of one fact — the
scattering C-17 exists to stop, and the same objection §K2 raised against a
second copy of the difficulty preset.

**The test that makes it checkable rather than a preference:** *does an old body
still mean what it meant?* A v6 city body written by the pre-RR-60 binary
restores under the post-RR-60 binary to **exactly** the city it restored to
before — the two new keys are absent and both loaders fall back to what they
always did. Where that holds and the only thing that moved is inside a section
that took its own rung, the city rung stays. `tests/test_save_migration.gd` and
`tests/test_save_determinism_days.gd` are the gates.

**What the ruling forbids: the pure epoch marker.** A `_v6_to_v7` identity
migrator with nothing in the body it is about describes rules the *city section*
did not have. §2.8's own Wave-9 correction already names that fault — "a ladder
that describes rules the binary did not have is worse than no ladder" — and the
price is that every future migrator walks a rung that answers nothing. **A rung
is taken because a body needs it, never to date-stamp a wave.** The date stamp
belongs in §2.8's dated shipment notes, which is exactly where the RR-60 rungs
already have one.

**Applied:** doc 08 §2.8 (the ruled block, and a pointer from the RR-60 shipment
note), doc 93 §O2.

### RR-76 — The count is 169 of 187, and a count table that drifts from its own rows has now done so three times (doc 91)

**The binding number, so it can be quoted from one place.** At the Wave-13 fork,
2026-08-21: **169 of 187 `### 2.N` rows of docs 01–13 are SHIPPED — 90 %, or
91 % of the 185 rows that are not deferred by their own docs.** 15 PARTIAL, 1
ABSENT, 2 DEFERRED. Six of thirteen design documents are complete. Suite
118 files / 2,083 tests / 522,300 asserts / 0 failed / 0 silent, 30 balance
gates, both determinism baselines unmoved. Doc 91's re-derived table is the
authority and this line is its pointer; **RR-47's 161 of 183 is the Wave-10
number and is superseded.**

**And the process finding, which is the part that generalises.** The published
Wave-12 headline (`185 / 163 / 19 / 1 / 2`) was **two rows behind the table
printed directly above it**: doc 03 §2.9 and doc 07 §2.4 were both struck in
their own rows and folded into neither total. That is the **third** time a hand-
maintained count in this project has drifted from the rows beneath it, and it is
the same class as §28.2 in doc 92 (RR-55) one document over.

**Ruling: a derived total is not a source. Either it is computed, or it carries
the fork it was computed at.** Doc 91 already names the durable fix and it is
half done — three of its four matrices are tests now (§16 asset, §18 event, §19's
width half), and the fourth (§17's verb doors) is the last hand census in the
project. **When the fourth becomes a test, "done" is a number the suite prints
and this failure mode ends.** Until then, every count table in doc 91 carries the
fork and the date in its heading, and the top-of-file provenance box names which
one is current.

**Applied:** doc 91 (the re-derived count table before §0.5; the provenance box
at the head of the file; §20.1a's eight clauses; §20.4's completion statement;
§20.5's marker sweep), and the pointer above RR-47.

---

## 31. WAVE 15 — the layer that pays for LOOKING (binding)

### RR-77 — A system that pays for ATTENTION belongs to the fine path; and a hash delta is a claim you can enumerate (docs 00 §5, 03 §2.5/§3.3, 06 §2.16, 08 §2.3/§2.8/§2.9/§3.1, 09 §2.14, 91 A91-D-33, 92 §35, 93 §Q)

**What the player said, because it is the whole requirement.** *"We need to have
ways where we can make money quickly… on the street, we should have an animation
of humans that are committing crimes that aren't being picked up by the police
station, and animals that maybe have gotten on the loose — need to collect them.
And these should definitely pay you money. So there's not a lot of downtime of
absolutely nothing to do."*

Read that against what the project had: eleven systems the player SETS UP and
then watches settle. A fire answers itself. A tax rate pays on the hour. A block
develops over game-days. **Nothing rewarded looking at the city**, so a session
had a busy first minute and then a wait. Doc 06 §2.16 is the answer — three kinds
of tappable street offer, spawned on a new named stream, expiring in two to four
real minutes, paying a bounty — and it ships behind three rulings.

**(a) The offline rule is STRUCTURAL, not clamped** *(doc 93 §Q1, doc 08 §2.3
rule 9).* Every other rule in §2.3 is a clamp: the system runs offline and
`OfflineGuard` bounds its output. This one is not — the spawner's
`advance_coarse` expires and returns, drawing nothing, so there is no output to
bound. Same visible result as the clamp version ("they expire before you get
back"); different guarantees. Zero draws is checkable, cannot drift, satisfies
doc 01 §2.5's coarse contract without an argument, and leaves the coarse-step
balance matrix bit-identical. **Verified: 21 game-days of catch-up move the
`street` stream's state by zero** (`tests/test_street_opportunities.gd`), and
`tests/balance_matrix.gd -- days=21 strategies=do_nothing seeds=1337,4242,9001`
reproduces doc 92 §33.4's published row **cell for cell** — treasury 145,417,
value 145,417, pop 141, minC 0.501, peak open 2.

**(b) Attention money is its own ledger line** *(doc 93 §Q2, doc 03 §2.5).*
`Treasury.credit(reward, &"street", …)`, with `ledger_totals.lifetime_street`.
Never `tax` (a rate on the city's value is not a bounty on the player's
attention, and mixing them makes the tax slider appear to move when the player
merely tapped more), never `tariff` (nothing was delivered or metered), never in
`settle()`'s `revenue` (which would let tapping raise the credit limit).

**(c) A split delivery gets a named, self-clearing exemption** *(doc 93 §Q3).*
RR-53 requires a consumer or a written exemption for every player-visible event.
`tests/test_event_matrix.gd` gains one classification word, `awaiting_consumer`,
usable only by a row that names the wave that owes the consumer and the file that
will be it — and it expires mechanically, because the register's own
stale-exemption test fails the suite the moment the consumer lands. The same
shape lands one gate over: doc 09 §2.14's `collect_opportunities` evaluator kind
sits in a `SURFACE_DEFERRED_KINDS` list in `tests/test_goals_system.gd` under
§G2, with a **stronger** expiry — the test scans `game/` and `ui/` for the verb
the row names and fails the moment anything there calls it.

**(d) And a defect this change FOUND rather than caused** *(doc 93 §Q4).* Doc 01
§2.3 has always said the scheduler "sorts by `(phase, system_id)` … so ties are
broken deterministically". `sort_custom` is an introsort and is **not stable**, so
two systems sharing a phase *and* an id had no defined order at all. Nothing
shipped registers a duplicate; `tests/test_weather_integration.gd` deliberately
does — a second `&"weather"` driving a wired `WeatherSystem` alongside the sim's,
both writing the shared `ModifierStack`, so the last to run decides what the grid
draws. Registering one unrelated system elsewhere flipped that sort, the rig lost,
and the failure read as *"a heat wave stopped moving power demand"* three
directories from the change. **Ruled: the sort key gains registration order as its
final term** — an override registered later wins, which is what a caller
registering a duplicate already means. It can move no correct behaviour, because
the order it defines was previously undefined, and it changes nothing for a
unique-id registry: all four determinism baselines are byte-identical across it.
The general form is worth more than the fix: **a sort key that is not unique is
not a key**, and this project sorts for determinism everywhere.

**The methodological half of this ruling, and the part that generalises.**

> **A hash delta is not "the baselines moved". It is a claim about which keys
> moved and which values did not, and that claim can be ENUMERATED.**

This change moves all four published determinism baselines, which under the
existing practice would be recorded as four new digests and a sentence of
reassurance. That is exactly the shape RR-55 and RR-76 keep catching in other
documents: a derived number republished without the argument that produced it.
So the delta was enumerated instead. The layer adds **exactly three keys** to the
city body — `street` (the roster), `rng.street` (the eighth named stream) and
`treasury.ledger_totals.lifetime_street` — and **changes no existing value
anywhere**. Strip those three from the captured body and re-digest:

| city / path | shipped digest | with the three keys stripped | Wave-13 baseline |
|---|---|---|---|
| founding, coarse 24 h | `32a3e968…` | `0b67cd2273a5115a…` | `0b67cd22…` ✅ |
| founding, fine 2 h | `90a41a97…` | `4f9f383038fbe383…` | `4f9f3830…` ✅ |
| bench, coarse 24 h | `385dacb2…` | `bbe658aeeaa9f855…` | `bbe658ae…` ✅ |
| bench, fine 2 h | `e4204947…` | `158501b8845b056f…` | `158501b8…` ✅ |

Four for four, on two cities and both paths, **to the byte** — including the fine
runs, which have two live opportunities standing on the street when the digest is
taken. That is the difference between "we believe this was additive" and "this
was additive, here is the arithmetic". The property is kept alive after the
baselines move on by
`test_the_layer_moves_nothing_outside_its_own_three_keys`, which runs the same
comparison between a live spawner and one pinned at `max_live = 0` and needs no
published digest at all.

**Constitution §5's stream roster is a ROSTER, not a cap.** `street` is added to
doc 00 §5's list. The rule above the list — *every stochastic system gets its own
named RNG stream* — **requires** the addition; a new stochastic system that
reused `misc` would be the violation. It costs the existing streams nothing,
because each stream's seed is `hash(master_seed + ":" + name)` and a name that
did not exist perturbs no sequence that did. The whole cost lands in one place,
the body's `rng` block, which is why it takes a section rung.

**And the rung is a SHAPE rung, which doc 93 §P2 requires it to be.** §P2 forbids
"a rung taken as a pure epoch marker — a `_v6_to_v7` identity migrator with
nothing in the body it is about". This one has something in the body it is about:
a new top-level `street` key. `_v6_to_v7` is still the identity function, and
here that is the complete answer rather than a formality — an absent `street`
block deserialises to an empty roster (which is what a v6 city genuinely had) and
`RngStreams.deserialize` leaves an unknown stream on its boot seed (which is
where a fresh city of that seed starts). A migrator that materialised those
defaults would have to be re-read every time a default changed.

**Applied:** doc 00 §5 (the roster + the ruling pointer); doc 01 §2.3 (the sort
key's third term); doc 03 §2.5 (the
`street` revenue line, the measured ceiling table) and §3.3 (`lifetime_street`);
doc 06 §2.16 (the mechanic, whole); doc 08 §2.3 rule 9, §2.8's v7 shipped note,
§2.9 (eight streams) and §3.1's registry row; doc 09 §2.14 gains the
`collect_opportunities` evaluator kind with **no curriculum row** (gate 21's
fitted targets are untouched — see doc 92 §35 for where a row would fit); doc 91
A91-D-33 and §17's verb matrix; doc 92 §35; doc 93 §Q.

## 32. WAVE 15 — the money pass (binding)

*Three rulings. The first is the oldest open question in the project: doc 06 filed it as its own §9 question 6 in Wave 1, doc 93 §N1 point 4 wrote its re-open condition in Wave 11, and this pass discharges it. The other two are what discharging it turned up — an opening whose bill nobody had read out loud, and a gate measuring a stock where the knob moves a flow.*

### RR-78 — Two names for one dollar, and the live half had no ledger line (docs 03 §2.5/§2.6/§2.12, 06 §2.7/§9 q6, 93 §N1/§R1, 92 §36.1)

**The contradiction, as filed.** Doc 06 §9 question 6: *"`reward_base[crime] = 350` is numerically identical to doc 03's `POLICE_FINE_PER_RESOLVED_INCIDENT = 350`, which suggests doc 03 already books that revenue… if it is the same dollar it must move. Requesting a ruling."* C-07 had already given doc 03 the currency monopoly and R-14 had already deleted doc 06's vehicle prices; `reward_base` was simply missed, and it stayed missed for four waves because **neither half looked wrong from its own side.**

**It is the same dollar.** And the state of the two halves is the finding:

* **Doc 06's half was live and invisible.** `IncidentSystem._pay_reward` credited the payout on every resolve through `world.credit(reward, "incident_resolved")` → `Treasury.credit(…, &"incident")`, which is a terminal call. `EconomySystem.settle_hour` never saw it, so there was no ledger line, no budget-panel row and no notification. Measured on `do_nothing`, seed 1337, `tools/measure_founding_ledger.gd --hours=24`: **$38.38/gh — $921 over the founding game-day, 12.5 % of that day's whole reported net income** — paid to a city that builds nothing and dispatches nothing.
* **Doc 03's half was dead and visible.** `CitySim.HELD_FINE_RATE = 3/350` fed `police_incidents_resolved`, which multiplied back into the 350 for a permanent **$3.00/gh**. Doc 93 §N1 point 3 measured it flat on all four presets at the founding hour, at 21 game-days and at 48.

**RULED.**

1. **`reward_base` is deleted from `data/incidents.json` and lands in `data/economy.json` as `city_services.dispatch_payout_base`**, at the same six values (350 / 900 / 600 / 500 / 300 / 400). Doc 06 keeps the SHAPE of a payout — `tier_k` and the speed-bonus band, its own §2.7 questions — and doc 03 owns every dollar, the same split C-16 already uses for repairs. `IncidentCatalog.FORBIDDEN_KEYS` gains `reward_base` so a data file that carries it back fails the boot, not just CI, and doc 03 §7 test 33's key list gains it too.
2. **`POLICE_FINE_PER_RESOLVED_INCIDENT`, `CitySim.HELD_FINE_RATE`, `police_incidents_resolved` and the `fines` ledger line are all retired.** Doc 93 §N1 point 4's re-open condition — *"when doc 06 publishes real resolutions, the line becomes a measurement"* — is met on the doc-06 half. The doc-04 half (`delivered_mwh`) is untouched and stays ranked.
3. **ONE new revenue line, `city_services`, for dispatch and street both**, with `city_services_by_source: {dispatch, street}` inside the snapshot exactly as `tax_by_class` sits beside `tax`. Two half-sized rows on a phone budget panel cost a row and buy nothing; the sub-grain is not lost, it is nested.
4. **The money is credited immediately and reported afterwards**, and the accounting is explicit rather than implied: `Treasury.credit_city_service()` moves the cash now and tallies it by source in `hour_city_services`; `CitySim` drains that tally once per settled game-hour in the ECONOMY phase (after INCIDENTS has finished writing to it); `EconomySystem` books it on the line, includes it in `gross` and `net`, and hands `Treasury.settle` **`revenue − city_services`** because that cash already moved. One dollar, one line, two moments. The tally is serialised — defaulting to 0 on any pre-RR-78 save — because a save between a resolve and a settlement would otherwise drop a line the statement is about to print.
5. **Who answered changes the price.** `MANUAL_DISPATCH_MULT = 1.50` — doc 06's own `speed_bonus_max`, adopted rather than a new magnitude invented — applies only when `Incident.manual_requested` is true, i.e. only through `cmd_dispatch_unit`. Auto-dispatch pays 1.00×, **exactly the dollars it has quietly earned since Wave 1**, which is what keeps the balance matrix's control strategies attributable to RR-79 alone.
6. **The moral-hazard ceiling is doc 03's and it BINDS on shipped numbers.** `payout ≤ MORAL_HAZARD_CAP_FRACTION (0.75) × (capital_value(target) − repair_cost(target, residual))`. Doc 06 grows the payout at `tier_k = 0.35`/tier while doc 02 grows residual damage at `0.10`/tier, so on a house L1 a tier-5 fire paid **2.73×** the loss it prevented (4.09× at the best speed): *letting a fire grow before answering it has been the profitable play since doc 06 shipped.* 0.75 sits above doc 06's own ruled worked example (0.679 of prevented loss — a cap under a ruled payout at its reference point is a retune wearing a guard's clothes) and strictly under 1.00 (indifference between a fire and no fire, which plus variance is a strategy). Where doc 03 prices no capital — road edges, water segments — `prevented_loss_value` returns **−1, not 0**, the clamp is skipped rather than silently zeroing a payout, and `MORAL_HAZARD_UNPRICED_CEILING = 3900` holds those three types instead. New balance **gate 31** holds all three surfaces. **The clamp costs the control strategies real money and the report says so rather than folding it into the retune**: `do_nothing`'s 21-game-day treasury moves +$14,465 / +$14,772 / +$14,731 against a two-constant prediction of +$15,000, and the seed-dependent residual — **−$535 / −$228 / −$269**, 2–4 % of the movement — is the ceiling binding on high-tier fires in cheap houses (doc 92 §36.5). A guard that changed no behaviour would not be one.
7. **Doc 12's street opportunities are priced here too**, for the same C-07 reason: `petty_crime 180 < dispatch_payout_base.crime 350` **by ruling** — a tapped crook is petty, a dispatched crime is the real one — with `STREET_MAX_RATE_PER_GAME_HOUR 0.45` as an income-share contract a test can hold (`0.45 × 180 = $81.00/gh` = 16.0 % of the opening's $506.05/gh net, inside the ruled 10–20 %) and `STREET_IDLE_SHARE 0.0` as a written-down zero. The sibling system owns when an opportunity appears and where it stands; it owns no dollar. New balance **gate 32**.

**What moves:** `data/incidents.json` loses six `reward_base` keys; `data/economy.json` gains `city_services` and loses `POLICE_FINE_PER_RESOLVED_INCIDENT`; `data/ui.json.budget.revenue_keys` swaps `fines` for `city_services` + `assistance`; `data/strings.en.json` swaps `ui_budget_revenue_fines` for two new keys; four determinism baselines (doc 92 §36.6); doc 03 §2.12's founding ledger; doc 06 §2.7's table and worked example.

### RR-79 — A founded city is billed for three stations and eight vehicles it never chose (docs 03 §2.5a/§2.12, 09 §2.14, 92 §36.2, 93 §R2)

**The complaint.** The player, twice: *"we need ways to make money quickly"* and *"money production is pretty slow for these first three levels."*

**The measurement that redirected the fix.** `tools/measure_money_pass.gd` counts **BROKE game-minutes** — game-hours in which the treasury cannot buy the cheapest row on the build sheet ($1,200, a level-1 house). Curriculum agent, 21 game-days, three seeds, before AND after: **zero**. So is `E_FUNDS` in the agent's own action log. *The opening is not poor; it is slow.* Nothing is unaffordable — the milestones are two real hours apart (`data/time.json` sets one game-hour = one real minute at 1×, so doc 03's $/gh column IS $/real-minute, and curriculum level 3 arrived at game-hour 122–128).

That killed the obvious candidate before it was implemented: `building_maint` is **$27.46 of a $504.73/gh** founding bill, 5.4 %, so "ease maintenance at low levels" is a dead lever. What the bill actually says is that **`departments` $96.00 + `fleet` $76.00 = $172.00/gh, 34.1 % of everything a founding city spends, is three stations and eight vehicles `data/starter_city.json` hands the player and bills at full price from game-hour 1.**

**RULED — two grants, both published constants, neither farmable.**

1. **`FOUNDING_ASSISTANCE_PER_HOUR = 172`**, tapering on `share(day) = clamp(1 − day / FOUNDING_ASSISTANCE_DAYS (7), 0, 1)`, evaluated on the settled game-day so the line steps once a day rather than drifting inside one. It is a **constant and not a fraction of the live bill**: a subsidy that grew with the fleet would pay a player to buy vehicles (the C-08 / RR-2 mistake one knob down), and a revenue line carrying an `M_exp` would break doc 93 §N1's one-knob-per-line contract from the other side. Total $16,512 against a $25,000 purse — the discrete daily step (seven shares averaging `4/7`), not the continuous integral, which is $2,064 light. Seven game-days is the curriculum's own opening, so it covers levels 1–3 and is retired before level 4's incident wait.
2. **`LEVEL_UP_GRANT_BY_CITY_LEVEL = [0, 2500, 7000, 9000, 22500, 37000, 83000]`** — *the city pays half of what the next chapter asks you to buy*, derived row by row against doc 09 §2.14's taught purchase (stores → apartment + street → police station → water works → tower upgrade), with rung 6 as the same 2.25× extrapolation the population ladder itself uses above rung 3 and labelled as such. Paid on the composed city level (doc 93 §G1's `max()`), so neither route to a rung is worth more than the other, and once only — `data/progression.json`'s `city_level_monotone` is what makes that structural rather than a guard. A **one-off receipt is not an hourly ledger line**, for the same reason doc 03 §2.4 keeps one-off capital spends out of the recurring rate.

**Not one price moved.** No `build_cost_l1`, no `base_tax_by_level`, no expense constant. The founding ledger's entire movement is `+172.00 − 3.00 = +169.00/gh` on the revenue side; `STARTER_EXPENSE_PER_HOUR_EXACT` is deliberately not re-stamped, and gate 2b is the check that this was a revenue-side change.

**Measured** (doc 92 §36.4): curriculum level 3 arrives at game-hour **79–83 instead of 122–128**, every rung from 2 to 6 lands 25–37 % sooner, and the arc finishes on game-day **29.5–31.4** against a ruled bound of 40 that doc 92 §33.7 had ranked as the tightest number in the gate file at 38.2–38.8. Gate 21 asserts ceilings only, so faster is inside every one of them.

### RR-80 — A stock measures how much an agent chose not to spend (docs 92 §36.5, 93 §R3, `tests/test_balance_gates.gd` gate 4)

**The failure.** After RR-79, gate 4's cash assertion inverted: `balanced` $58,612 against `disaster_neglect`'s $80,532 (before: $81,950 against $55,624). Gate 4 is the maintenance A/B — the same agent class with one field changed — and the gate whose header already carries one re-fit of exactly this kind, when pass 3 dropped `value created` because the harness's action budget contaminated it.

**The diagnosis: both money columns are artefacts, and this pass swapped which one is showing it.** `value created` *un*-inverted in the same run (balanced $965,739 against neglect's $925,644, where it used to read $834,156 against $952,519). Neither flip is the maintenance knob. Cash-in-bank is a **stock** — it records how much of its income an agent declined to convert into city — so giving both agents more money moves the stock toward whichever one converts less, and the agent that also buys repairs converts more. **An agent that skips maintenance holding more cash is correct**; that is what "maintenance costs money" means. The design claim was never that neglect ends poorer.

**RULED: gate 4's money column is `net_mean_per_hour`.** It is the **flow**; it is what condition drives through doc 03's `f_condition`; it separates the pair by **12–20 % on all three seeds in both arms**; and gate 5 already uses it for the same claim one comparison up. `value created` is refused as the replacement on the evidence — seed 9001 separates the pair by **0.29 %** on it, and doc 92 already ruled once (gate 12c, Wave 8) that a threshold fitted on the matrix must be measured on the matrix rather than on one seed's noise. **No constant moved**; the column moved to the thing the knob acts on. The health columns were never in doubt: min condition 0.798 vs 0.391, dark share 0.19 % vs 30.66 %.

## 33. WAVE 14 — the street gets something to do, and three render rules come out of it (binding)

*The STREET LIFE layer (doc 11 §2.17). Three of its findings generalise past the
layer that found them, and two of the three are defects a headless suite is
structurally incapable of catching — they were found by looking at a screenshot,
which is why the rulings below each name the assertion that now stands in for the
eye. This section changes no `sim/`; the layer is a pure event consumer and its
hash neutrality is proved by an interleaved full-frame test, not asserted.*

### RR-81 — A distance field is DATA, and `source_color` is a lie about it (docs 11 §2.17, 91 §11, 93 §S1)

**The symptom.** Every attention marker in the city drew as a **perfect, empty
pin** — the chip, the tail, the rim and the pulse all correct, and no mark inside
any of them. The `+$N` labels drew, which is what made it look like a marker bug
rather than a page bug.

**The cause, and it is one word.** `StreetGlyphAtlas` builds a signed distance
field: the stored value is `0.5 − d / 2·SPREAD`, so the contour a shader tests
against is `field > 0.5`. The uniform was declared

```glsl
uniform sampler2D glyph_page : source_color, filter_linear, repeat_disable;
```

and `source_color` tells Godot the texture is **sRGB-encoded colour**, so the
sampler decodes it. **0.561 — the field one texel inside a stroke — comes back as
0.275.** Every `field > 0.5` test in the file fails, every mark vanishes, and
nothing errors, because a decode of a valid texture is a valid texture.

**Why the labels survived and hid it.** A label draws `max(ink, outline)`, and
the outline contour sits at `0.5 − label_outline_w` = **0.16** — below the
decoded 0.275. So the labels kept drawing their outline shape at full alpha and
looked *nearly* right, while the markers, which only ever test the 0.5 contour,
went silently blank. A partial survivor is worse than none: it argues the page is
fine.

**Ruled, and it generalises past this file.** **A sampler is hinted
`source_color` if and only if the texture is a COLOUR a human picked.** A
distance field, a mask, a lookup table, a packed set of channels — none of them
are. The rule has a companion this pass also paid for and that points the other
way:

**A MultiMesh INSTANCE COLOUR is LINEAR and Godot converts nothing on that
path.** A `source_color` uniform is converted for free; so is
`StandardMaterial3D.albedo_color`; `MultiMesh.set_instance_color` is neither. An
authored `#F25242` therefore renders as if it were linear `(0.95, 0.32, 0.26)`,
which displays at roughly sRGB `(250, 165, 150)` — the marker came out the colour
of a plaster. `StreetLifeModel` now converts its whole authored palette once, at
`configure()`, and says why in the file.

**Filed as `A91-D-36` (Low), not fixed from this branch:** `VehicleView` and
`ConstructionVehicleView` pass their authored liveries into `set_instance_color`
raw and have the same latent lift. On a SHADED surface it is much less visible
than on an unshaded billboard and reads as a deliberately chalky palette rather
than as a bug — which is exactly why a branch that only *found* it should not be
the branch that re-saturates a fleet and a plant hire. It is an art call on two
shipped layers: the lead's, not a street-life branch's.

**The assertion that stands in for the eye.** `tests/test_street_life.gd`
`test_every_glyph_has_ink_at_the_contour` asserts every glyph has texels on BOTH
sides of 0.5 inside its own cell, and `test_the_shaders_keep_this_renderers_rules`
reads the shader source. Neither can see an sRGB decode — that happens in the
driver — so the durable guard is the RULE, written here and in the shader's own
header, plus the screenshot repro in doc 11 §2.17.

### RR-82 — A screen-space affordance is laid out in SCREEN space (docs 11 §2.17, 93 §S2)

**The symptom.** `+$120` read as `+ 20` for the first third of a second, and the
number skewed and foreshortened as the camera turned.

**The cause, two of them, both the same mistake.** The label's glyph run was
placed in WORLD space — `origin + (i·pitch − span/2, 0, 0)` — so it lay along
world **+X**, not along the screen. At any camera yaw but one it therefore
foreshortened; and because it was centred on the marker's own world position, its
middle glyphs sat **behind the marker chip**, which is where the `$` and the `1`
went.

**Ruled.** **A billboard's siblings are laid out in the billboard's own frame.**
Every glyph of a label now shares ONE world origin and carries its SLOT
(`i − (n−1)/2`) in `INSTANCE_CUSTOM.a`; the shader steps them apart along the
quad's local **+X**, which is screen right by the time the billboard transform is
done. One float per instance, no camera basis on the CPU, and the run is exactly
horizontal at every yaw and every zoom. The label also starts clear of the
marker's own top before it begins to rise.

**And the same rule has a size half.** The rise was authored in METRES
(`label_rise_m` 1.55) against a marker that holds an ANGULAR size — so at Z0 it
was a hand's width and at Z1 a twitch. It is now `label_rise_frac` × the marker's
own size, and the label travels the same number of screen pixels at every pose.
The general form: **a quantity that decorates a screen-sized thing is measured in
that thing, not in metres.**

### RR-83 — An empty MultiMesh still costs a draw call (docs 11 §2.13/§2.17, 93 §S3)

**The measurement.** `profile_frame --street-life=5` against `--street-life=0`,
bench city, balanced, everything else identical:

| pose | before | after | delta |
|---|---|---|---|
| Z0 | 237 dc | 241 dc | +4 |
| Z1 | 233 dc | 237 dc | +4 |
| Z2 | 196 dc | **200** dc | **+4** |

Z2 is the wrong number and the harness said so out loud: its own census line read
`4 MultiMeshes declared, 1 submitting`, because at 420 m every body is past
`body_radius_m` and only the marker buffer has anything in it. **Three buffers
holding `visible_instance_count == 0` were each costing a call.**

**Why the culler cannot save you.** Every MultiMesh in this renderer carries an
explicit world-sized `custom_aabb` — it has to, because instances are written
straight into the buffer and never update the auto AABB (the note is on every
`_add_layer` in `game/render/`). So the frustum test passes for every one of
them, every frame, whether they hold anything or not.

**Ruled.** **Emptying a buffer is not the same as switching it off. A layer that
gates its instances by distance must gate its NODES by count**:
`node.visible = n > 0`, on the same line that writes `visible_instance_count`.
Z2 then reads **197** — the one live marker buffer, and nothing else. The layer's
`active_buffers()` is now exactly its draw-call cost and `profile_frame` prints
it beside the timing, so the claim is checkable rather than asserted.

**Where else this applies.** Any layer whose instance count legitimately reaches
zero: this one, `ConstructionVehicleView`'s five buffers on a city with no sites,
`PowerInfraView`'s smoke and spark buffer on a healthy grid. `PowerInfraView`
already gates its wire buckets by DISTANCE for the same reason and by the same
mechanism (`wire_gate_m`), which is the precedent — this ruling only says that
*count* is a gate too. Not re-audited from this branch; filed for the lead.

## 34. WAVE 14 — the payday reaches a surface (binding)

*Shell/UI fork off the Wave-13 integration. Hash-neutral by construction:
nothing under `sim/` was touched, both determinism baselines are unmoved, and
the balance gates are unread by anything in this pass.*

### RR-84 — Two documents describe the same dollar and only one of them is the ledger (docs 03, 06, 12)

**The inconsistency.** Doc 03 §2.4 specifies the hourly settlement and names its
revenue terms: tax, power tariff, water tariff, fines. Doc 06 §2.9 specifies an
incident reward and `IncidentSystem._pay_reward` pays it — through
`CityIncidentWorld.credit` → `Treasury.credit(amount, &"incident", reason)`, a
**direct credit that never enters `EconomySystem.settle_hour`**. Doc 12 §2.10
then draws "the ledger" from the settle snapshot, in good faith, and the
resulting screen is missing a revenue stream large enough that **one resolved
fire outweighs every non-tax line on it combined** (doc 92 §38.1: a tier-3 fire
pays $1,530 against `power_tariff + water_tariff + fines = $1,470` per settled
hour on the tab's own fixture). **The NET line was wrong by exactly the bounty
income, every hour a crew answered a call.** Filed as A91-D-37.

Neither document is *wrong* in isolation, which is why this is a consistency
finding rather than a defect in one of them: doc 03 never claimed to enumerate
every path into the treasury, doc 06 never claimed its reward was a settled
line, and doc 12 read the only structured source there was.

**Ruling, in two parts.**

1. **A ledger's rows and its total are one object.** A surface that renders a
   revenue column and a NET beneath it is asserting that the column explains the
   total. Where it cannot, it must say so by carrying the line, not by omitting
   it — an omitted line reads as "there was none", which is a stronger and
   falser claim than a line whose provenance is imperfect. `BudgetModel`
   therefore adds side revenue to `gross` and to `net` as well as to the rows;
   a row the column shows but the total does not contain would be a second,
   worse defect.
2. **Every path into the treasury is doc 03's to enumerate, and a direct credit
   is a path.** `revenue.bounties` and `revenue.street` should be settle-snapshot
   keys, accumulated where the credit is made. Doc 92 §35's ranked list carries
   it at position 0. Until then doc 12 tallies them off the bus, and the tally is
   built to stand down: **a key the settle snapshot carries is taken from the
   snapshot, always**, so the day doc 03 publishes one, the sim's number wins
   with no edit under `ui/` and no possibility of counting a dollar twice.

**The generalising half.** This is the third instance in three waves of the same
shape — a correct system with no observable (RR-69's `profile_weights_of`,
RR-62's cascade, this) — and it is the first one a **player** found rather than
an audit. That is worth recording precisely because the audit had every chance:
`reward` is a field on a bus event that four classes already read, and no test
anywhere asks *"is this number ever shown to anybody?"*. Doc 93 §T1 is the
ruling that generalises it — a value transfer the player did not personally
authorise must have a sensory surface at the moment it lands.

**Applied:** doc 12 §2.21 and D-61 … D-64; doc 91 A91-D-37; doc 92 §38; doc 93
**§T** *(this line read "§P" until 2026-08-21: the payday rulings are `T1`–`T3`
and their section header carried a stale letter — see §35 / RR-85)*;
`data/ui.json.budget` (two keys plus the `_comment_side_revenue` note that
states the retirement rule at the point of use).

---

## 35. WAVE 15 — the reward ledger settles (binding)

*Balance fork. Five rulings, and the first four of them are the same shape: a
number that was published, quoted in three documents, held by a test, and **not
the number the game was using.** The fifth is a fix for a counter that answered
zero for its whole life. Every determinism baseline below is bit-identical
across the whole pass on the `standard` preset — see doc 92 §39.9 for the
enumeration, and RR-87 for why the non-default presets deliberately move.*

### RR-85 — One feature, two price tables, and the live one was not the one the gates read (docs 03 §2.5, 06 §2.16/§8, 92 §35/§39, `data/street.json`, `data/economy.json`)

**The inconsistency.** RR-78 moved doc 06's `reward_base` into
`data/economy.json` and wrote, in the same breath, that
`data/street.json` *"still carries the LIVE reward columns this table is due to
absorb"*. It did. So for one wave the project shipped **two price tables for one
feature**:

| | `data/street.json` (LIVE — what the game paid) | `data/economy.json` `street_payout` (what everything READ) |
|---|---|---|
| crook | `{base: 260, spread: 90}` → mean **$305** | `petty_crime: 180` |
| animal | `{base: 150, spread: 60}` → mean **$180** | `stray_animal: 120` |
| valuables | `{base: 420, spread: 180}` → mean **$510** | `abandoned_haul: 150` |

Two of the three keys in doc 03's table **were not even live kind ids** —
`stray_animal` and `abandoned_haul` name nothing in `data/street.json`, which
authors `loose_animal` and `lost_valuables`. The table could not have been read
by the spawner even if the spawner had tried.

**What that cost, precisely.** Balance gate 32 read doc 03's table and asserted
two things off it, and both assertions were true of the dead column and false of
the live one:

* *"a tapped crook is petty"* — `180 / 350 = 0.514`, comfortably under the ruled
  0.60. The live mean is `305 / 350 = 0.871`, which is not "about half" by any
  reading.
* *"the income-share bound"* — `0.45 × 180 = $81.00/gh`, 16.0 % of the opening's
  net. The live worst case is `0.45 × 600 = $270/gh`, 53 %.

Neither number was ever a lie anybody told; both were the arithmetic of a
placeholder that the wave which wrote it said out loud was a placeholder. The
defect is structural and it is the one C-07 exists to prevent: **a price that
lives in two files is a price nobody owns.**

**Ruling.** *Doc 03 owns every dollar, and "owns" means the game reads it from
there.* The bands move to `city_services.street_payout` **at the same values, to
the dollar and to the spread**, `reward_city_level_k` moves with them as
`STREET_REWARD_CITY_LEVEL_K` (it is a term in a dollar formula), and
`OpportunitySystem.FORBIDDEN_KEYS` refuses `reward` and `reward_city_level_k`
back at any depth — a boot error, not a fallback, exactly as
`IncidentCatalog.FORBIDDEN_KEYS` refuses `reward_base`. A kind `data/street.json`
names and `street_payout` does not price is a boot error too: a crook worth $0 is
a bug that looks exactly like a balance decision.

**The migration MOVED NO NUMBER, and the check that says so is the hash.** All
four `profile_sim` baselines are bit-identical across it (doc 92 §39.9), and
`tools/measure_street_yield.gd` reproduces its published table offer for offer —
1,225 offers, mean bounty $320.29, ceiling $181.65/gh — off the new file pair.

**The generalising half, because this is the fourth instance in four waves.**
RR-69 (a correct system with no observable), RR-78 (two names for one dollar),
RR-84 (a ledger whose rows did not explain its total), and now a gate holding a
column the game does not read. The common failure is not duplication; it is that
**every one of them passed its tests.** A test that asserts a published number is
*present and well-shaped* cannot tell a live column from a dead one. The test
that can is the one that asserts the other file is **empty** —
`tests/test_city_services.gd::test_no_street_price_survives_in_doc_06s_data`
checks absence, which is the half that discriminates, and it is written beside
the RR-78 test that already did the same job for `reward_base`.

**FOR SIBLINGS AND FOR THE MERGE — one key changes SHAPE, and it is the only
thing in this pass that can break a branch that has not seen it.**
`city_services.street_payout[kind]` was an `int` and is now
`{base: int, spread: int}`, and its keys changed with it (`stray_animal` →
`loose_animal`, `abandoned_haul` → `lost_valuables`, because the old two named
nothing). Nothing under `ui/` or `game/` reads it at this fork — grepped — and
the only consumers in the tree are `CostCurves.street_payout*` and balance gate
32, both of which move with it. **A branch that reads it as a number gets a
`Dictionary` and a silent 0**, so if a sibling has added a budget row, a build
sheet hint or a tooltip against that key between this fork and the merge, it
needs `street_payout_mean(kind)` (or `_base`/`_spread`) rather than a cast.
`has_street_payout(kind)` exists so a caller can tell "priced at nothing" from
"not priced" without guessing.

**Applied:** `data/street.json` (three `reward` blocks and `spawn.reward_city_level_k`
deleted; `_no_dollars` states the rule at the point of use); `data/economy.json`
§2.5 (`street_payout` as bands, `STREET_REWARD_CITY_LEVEL_K`, and the three
re-derived bounds of RR-86); `sim/street/opportunity_system.gd`
(`FORBIDDEN_KEYS`, `errors`, `bind_payouts`, `_reward_for` reads `CostCurves`);
`sim/economy/cost_curves.gd` (`street_payout_base` / `_spread` / `_mean`,
`has_street_payout`, `street_reward_city_level_k`); `sim/city_sim.gd`
(`_boot_street` binds the price table and drains its errors); doc 03 §2.5 and
§2.13(e); doc 06 §2.16 and §8; doc 92 §39.1/§39.3; balance gate 32(b);
`tests/test_city_services.gd`.

### RR-86 — A bound nobody could measure is not a bound (docs 03 §2.5, 92 §35.3/§39, `tools/playtest.gd`, `tests/balance_gate_rig.gd`)

**The inconsistency.** Three published numbers claimed to bound doc 06 §2.16's
opportunity layer, and none of the three was ever compared against the layer:

1. `STREET_MAX_RATE_PER_GAME_HOUR = 0.45` — "a contract the spawn table must
   satisfy". The spawn table has run at `1 / 1.5 = 0.667` offers/gh since the day
   the layer landed, i.e. **the contract was violated by 48 % from the moment it
   was written**, and no test could see it because the two files lived in
   different branches.
2. *"the ruled band is 10–20 % of early-game income WHEN PLAYED"* — never
   measured, because no agent in `tools/playtest.gd` could collect an
   opportunity and every agent in the matrix runs the coarse path, where the
   spawner deliberately draws nothing (RR-77(a)).
3. Doc 92 §35.2's **57 % ceiling** — measured, but from spawn telemetry on a
   founding city that never changes, against a founding net that the money pass
   moved out from under it two sections later in the same document.

**Ruling, in three parts.**

1. **A contract is checked against the thing it constrains, or it is a
   comment.** Both files are in one tree since RR-85, so gate 32(c) now reads
   `data/street.json`'s `target_interval_h`, inverts it, and holds it against
   doc 03's ceiling. The ceiling is re-derived to **0.70** — above the shipped
   table's own 0.667, refusing any `target_interval_h` under 1.43, and stated as
   a tripwire rather than a fit.
2. **A ceiling is measured on the spawner; a share is measured on a played
   city.** They are different claims and they get different numbers:
   `STREET_CEILING_SHARE_MAX = 0.40` (every offer taken, against the opening's
   own net) and `STREET_PLAYED_SHARE_BAND` (street income against the same run's
   settled net, on an arc). The old single band conflated them, which is how a
   "worst case" derivation ended up standing in for both.
3. **THE INSTRUMENT IS PART OF THE RULING.** `tools/playtest.gd` gains
   `collector` — `curriculum` plus one tap per game-minute and nothing else
   changed, so the pair is controlled by construction — plus `Api.collect_nearby`
   and an opt-in game-minute hook on `Strategy`. It is the project's first
   FINE-path agent, because the layer only exists there. `BalanceGateRig.run_fine`
   is the same loop for gates, sharing `Runner.advance_hour_by_minutes` rather
   than copying it, so a gate and a report row stay the same measurement.

**The slice is bit-identical to the hour it replaces**, and that is asserted on
`state_hash()` rather than argued: `advance_hours(1.0)` is `advance_fine_n(240)`,
`1.0/60.0` rounds to exactly 4 ticks, and `TickScheduler` carries no per-call
state (`tests/test_playtest_harness.gd::test_slicing_an_hour_into_minutes_lands_on_the_same_city`).
Without that property every collector measurement would be a measurement of a
different city and the controlled pair would not be controlled.

**What the ruling does NOT claim.** `collector` is a **ceiling agent**: no
camera, no travel time, unbounded sweep radius, so every offer it is awake for is
an offer it takes. Its share is the most the layer can pay somebody playing the
curriculum, not a forecast of a session. Doc 92 §39.5 states that at the head of
the table rather than in a footnote, because a ceiling quoted as an expectation
is exactly the error §35.2 made.

**Applied:** `tools/playtest.gd` (`NAMED_ONLY_STRATEGY_IDS`, `Collector`,
`Api.collect_nearby` / `live_opportunities` / the five street summary columns,
`Strategy.wants_game_minutes` / `tick_minute`, `Runner.advance_hour_by_minutes`);
`tests/balance_gate_rig.gd` (`run_fine`); `tools/measure_street_arc.gd` (new);
`data/economy.json` (`STREET_MAX_RATE_PER_GAME_HOUR` 0.45 → 0.70,
`STREET_CEILING_SHARE_MAX`, `STREET_PLAYED_SHARE_BAND`); doc 03 §2.5; doc 92
§39.2/§39.4/§39.5/§39.6; balance gate 32(c)–(f);
`tests/test_playtest_harness.gd`.

### RR-87 — A budget is a budget only if it is compared against the price (docs 03 §2.4, 10 §2.12/§9.4 q12, 92 §31/§34/§39.8, 93 §M1)

**The inconsistency.** `CitySim` wired `RoadNetwork.repair_quote` as
`econ_curves.repair_cost_road(road_class, damage_fraction)`, leaving C-16's
`M_repair` at its 1.00 default. The quote's only consumer is the decision "how
many contiguous runs fit inside `auto_repair_daily_cap`", and doc 10 §2.12 calls
that cap *"a **player budget setting**, not a price"* — which was read for three
waves as a reason quoting at nominal was fine. Doc 92 §31 measured what it
actually meant: a `crisis` city's $25,000/game-day admitted **1.60×** more
tile-fractions than repairing them costs, a `casual` city's **0.70×** fewer.
Doc 92 §34 ranked it the document's top open number; doc 10 §9.4 item 12 held it
open for doc 10's call.

**Ruling.** *"A player budget setting, not a price" is the reason the multiplier
must be there, not a reason it may be absent.* The cap is denominated in the
player's dollars, so the settings row that reads **$25,000/day** has to buy
$25,000/day of repairs on every preset. Quoting at nominal made one dial mean
four different things and said so on none of them. `M_repair` now comes from the
live preset, exactly as `cmd_repair_building` has always passed it, closing the
other side of the seam doc 93 §M1 closed on the accrual line.

**Hash-neutral on `standard`** — `M_repair` is exactly 1.00 there, the
multiplication is the identity, and all four `profile_sim` baselines are
bit-identical across the change. The preset arms move **by construction**: the
cap admits `1 / M_repair` of the tile-fractions it used to.

**Applied:** `sim/city_sim.gd` (`_boot_roads`'s `repair_quote` lambda); doc 10
§9.4 item 12 (struck, with the ruling); doc 92 §39.8.

### RR-88 — A counter that is always zero is worse than a counter that is missing (docs 03 §2.5, 08 §2.8, `sim/economy/treasury.gd`)

**The defect.** `Treasury.credit_city_service(amount, source)` credits through
`credit(amount, &"city_services", …)`, and `_note_lifetime` keys on the
**category**. It has a `&"street"` arm. Nothing ever reached it. So
`ledger_totals.lifetime_street` — doc 03 §2.5's own named row, the one
`Treasury`'s docstring calls *"its OWN row on purpose"*, the one doc 08 §2.8's
section rung 7 was cut for, the one
`tests/test_street_opportunities.gd` asserts is **present in the save** — has
read **zero on every city since the layer shipped.**

The cash was never wrong: `credit()` moved the balance correctly, the hourly
receipt book tallied correctly, and doc 03's `city_services` revenue line printed
correctly. Only the lifetime row was dead.

**Ruling.** A named counter answers questions. A missing one answers *"I don't
know"*, which is honest; a permanently-zero one answers *"none"*, which is a
false claim in a data structure the save carries forward forever. The tally is
noted by SOURCE alongside the category credit. `dispatch` deliberately gets
nothing here — `_note_lifetime` has no `&"incident"` arm, doc 91 A91-D-37 is the
row that would build one, and inventing a key in `Treasury` would publish a
counter doc 03 has not.

**And the test that would have caught it is the one that checks the VALUE.** The
existing tests asserted the key was in the serialised body and that the byte-
identity property held with the key *erased*; both pass whether the counter
counts or not. The new assertion is one line and compares it to the bounty.

**Applied:** `sim/economy/treasury.gd` (`credit_city_service`); doc 03 §2.5;
`tests/test_street_opportunities.gd`; `tests/test_playtest_harness.gd` (the
harness's own tally and doc 03's row are asserted equal, which is what says the
harness measures the game and not itself).

### RR-89 — The same number is a rhythm or an attrition depending on whether it pays (docs 06 §2.6, 92 §18/§33.5/§33.7/§39.7, `tests/test_balance_gates.gd` gate 19)

**The inconsistency.** Balance gate 19 is titled *"the dispatch loop is a
**weekly** beat"* and has been since doc 92 §18 measured **3.04 ambient
incidents per game-week**. It measures **9.73** at this fork — 146 over five
seeds × 21 game-days — of which `traffic_accident` alone is 101, about **0.96 a
game-day**. Doc 92 §33.5 refused to hide the doubling inside the band and §33.7
ranked the ruling; it has been open since Wave 13.

**Ruling: the rate is correct and the TITLE is what moves.** Three reasons, in
the order they bind.

1. **Nothing safety-critical is near its bound.** Zero failed, zero abandoned,
   zero destroyed, treasury climbing on every seed, peak open roster **2**
   against doc 06 §2.13(b)'s **36**.
2. **Cutting it would invalidate doc 06's own worked examples.** §2.6(e) intends
   0.687 accidents/game-day for a 20-intersection city; doc 09 stamps 389
   junctions before the player builds anything, and the starter city measures
   0.515/game-day in permanent sunshine — *below* doc 06's per-intersection
   intent. The Wave-13 doubling is doc 07's weather reaching doc 10's congestion
   index for the first time, i.e. two authored formulas meeting. The base rate is
   not what is wrong, so the base rate is not what moves.
3. **THE FUN CALCULUS CHANGED UNDERNEATH THE QUESTION, and this is the half
   Wave 13 could not have ruled on.** When §33.7 filed it, a traffic accident was
   a pure cost: fuel, vehicle wear, and a resolution that paid into a ledger line
   which did not exist. Since RR-78 it is **income** — $300 × tier × speed,
   credited through `city_services` and named in the budget panel. At 0.96/day
   and a tier-1 answer at target ($450) that is **~$430/game-day, ~$18/gh**
   against a founding net of $506.05/gh.

**A once-a-day event that pays is a rhythm; a once-a-day event that only costs
is attrition.** Same number, opposite reading. The honest form of this ruling is
that it would have been *cut it* in Wave 13 and is *keep it* in Wave 15, and the
thing that changed is not the generator — which is exactly why a pacing question
should not be answered in the wave that discovers it.

**What is NOT ruled:** the *mix* is lopsided (one channel of five carries 69 % of
the count). That is doc 06 §2.6's rate surface to balance across channels if it
ever wants to, and it is a different question from whether the loop beats and the
city survives it. Both: yes.

**Applied:** `tests/test_balance_gates.gd` gate 19 (re-titled, with the ruling
and the superseded clause marked in the historical block); doc 92 §39.7.


## 36. WAVE 15 — street polish: the five art items, and the one sim ruling (binding)

*Render/art fork off the Wave-14 street-life integration. Hash-neutral except
for RR-93, whose delta is published below; the balance gates are unread by
anything in this pass and both determinism COARSE baselines are unmoved.*

### RR-90 — A shadow you cannot see is not a shadow (docs 11 §2.11/§2.17, 93 §V3)

**The defect (render q4).** `data/render.json` has carried a `blob_shadow` block
since the preset table was written — `enabled_presets`, `y_m`,
`footprint_scale`, `alpha`, `night_fade` — and **nothing in the renderer read
it**. Meanwhile `vehicle_shadows` is `false` on Performance and on Balanced,
which is every phone, so doc 11 §2.17's bodies had no contact shadow of any
kind: a crook at Z0 read as a decal printed on the pavement rather than as a
person standing on it.

**Ruled.** *One knob decides both shadows.* `StreetLifeView.set_preset` pushes
the preset's `vehicle_shadows` into `StreetLifeModel.set_blob_shadows`
**inverted** — blob when real is off — so no body can have two shadows and no
body can have none. The `blob_shadow` block's own `enabled_presets` row is NOT
read by this layer and the reason is stated at the point of use: that row
belongs to §2.11's per-BUILDING decal, which is a different object with a
different gate, and reading both is what would let a preset arrive at "no real
shadow and no blob either".

**Zero draw calls, measured.** The blob is a sixth MODE on the existing street
fx buffer (`INSTANCE_CUSTOM.r == 5`), not a fifth buffer. It is the one quad on
that buffer that must NOT face the camera, so the vertex stage `mix`es the
billboard's three basis columns against the instance's own on a mode test —
three vec4 mixes, no branch.

| bench city, balanced, hour 21, `--street-life=6 --focus=48,48` | Z0 | Z1 |
|---|---|---|
| blobs off (preset `high`) | 91 dc, 7 fx rows, layer CPU 0.089 ms | 109 dc, layer CPU 0.088 ms |
| blobs on (preset `balanced`) | **91 dc**, 11 fx rows, layer CPU 0.099 ms | **109 dc**, layer CPU 0.096 ms |

**+0 draw calls, +4 instances, +8 primitives, +0.010 ms of layer CPU** for four
bodies. `profile_frame` now prints the blob count beside the buffer count, so
the claim is checkable rather than asserted.

**Two things a census could not have told us, and a screenshot did.**

1. **A `blend_mix` pass mixes TOWARDS a colour; it does not multiply by one.**
   The first cut authored the ambient's own blue-grey (0.055, 0.062, 0.080) on
   the reasoning that a real contact shadow is sky-coloured. The shaded
   carriageway at Z0 sits near **0.02 linear** — the shadow was *lighter than
   the road it was cast on*, and the layer was invisible while the census said
   one blob was in the frame. Black makes the same blend a multiply: the ground
   keeps (1 − a) of whatever it was, so one disc darkens dark asphalt and pale
   pavement by the same FRACTION, which is what a shadow does.
2. **A body has an AREA of contact.** The first cut reused the poof's
   `pow(1 − r, softness)`, which peaks at one pixel and is half gone a third of
   the way out: measured at the shipping size it put **244 pixels** of real
   shadow into a 1920 × 1080 frame. A core-and-rim falloff
   (`1 − smoothstep(blob_core, 1.0, r)`) at the same instruction count reads as
   a contact shadow. With `body_alpha` 0.50 the shipping disc moves **2,637
   pixels** at Z0, mean |Δ| 11.9 per channel, peak 129 — an A/B taken with the
   wander clock PINNED (`profile_frame --street-gm=`), because a free-running
   layer puts the bodies in different parts of their beat between two runs and
   the pixel diff then measures the frame rate.

**And a latent defect it exposed.** A body deep inside a junction has four road
neighbours, therefore no footway anywhere on its tile, therefore
`StreetLifeModel._anchor` left it at **y = 0 — ten centimetres inside the
carriageway it was walking on**. Invisible on the body (its feet are a dark box
against a dark road; its boots were simply gone) and fatal to a flat decal,
which was being depth-buried under the road it belonged to. It is the same
defect report NIGHT-1 found under the lamp pools, in the same 0.10 m. An
unsnapped body on a road tile now stands on `asphalt_top_m`.

**Applied:** `game/shaders/street_fx.gdshader` (mode 5, the basis mix, the
core-and-rim disc), `game/render/street_life_model.gd`
(`_emit_blob`, `set_blob_shadows`, `road_top_m`, the pool grows to
`max_live * 3`), `game/render/street_life_view.gd`,
`data/render.json.blob_shadow` (`body_alpha`, `body_m`, `body_lift_m` and the
`_blob_shadow` note that states which consumer takes which gate),
`tools/profile_frame.gd` (`--street-gm`, the blob column),
`tests/test_street_life.gd` (four tests).

### RR-91 — An instance colour is LINEAR, and a palette fitted against a lift is unfitted (A91-D-36; docs 11 §2.12/§2.16, 91, 93 §V4)

**The defect, as filed by the street-life branch and left for the lead.** A
shader uniform hinted `source_color` is converted from sRGB for free, and so is
`StandardMaterial3D.albedo_color` — but a **MultiMesh INSTANCE COLOUR is
neither**. It arrives in the shader exactly as written and is used as a linear
value. `VehicleView._paint_for` and `ConstructionActivity._plant_paint` were
both passing authored hexes straight in, so an authored `#9E3B34` (a deep oxide
red) rendered as if it were linear (0.62, 0.23, 0.20) — roughly sRGB
(208, 133, 122), a pale salmon. **Every fleet and every machine in the city was
about two stops light**, and it read as a deliberately chalky palette rather
than as a bug, which is exactly why it survived four waves and shipped.
`StreetLifeModel._bake_colours` had already made the same fix on its own layer
one wave earlier and filed this one.

**Fixed at the seam and not per frame.** `srgb_to_linear` allocates a `Color`,
and both call sites write a colour per instance per frame; the conversion is
therefore done once per vehicle and once per site, where the hex is chosen.
The three stock tints (`SAND`, `GRAVEL`, `REBAR`) reaching
`ConstructionVehicleView`'s heap and stack buffers take the same conversion,
baked once in `ConstructionActivity._init`.

**And then the palettes were re-judged, which is the half that is easy to skip.**
Screenshots: `profile_frame --traffic=14 --units=4 --sites=2` at Z1, hour 13 and
hour 21, bench city, no UI layer in the frame. The fix darkens everything, and
four hexes had been fitted BY EYE against the lift:

| hex | was | now | why |
|---|---|---|---|
| `CIV_PAINT[2]` | `#4A5157` | `#5B646C` | linear 0.068 against a carriageway near 0.02 — a car the same value as the road is not traffic, it is a hole |
| `CIV_PAINT[3]` | `#2C3237` | `#3B434B` | linear 0.024, i.e. the road exactly; still the darkest of the ten |
| `LIVERY[2]` | `#2F6E52` | `#3E8C69` | a plant livery is high-visibility by its own doc comment; corrected, it was near-black at hour 21 |
| `LIVERY[3]` | `#3D6B92` | `#4C82AE` | ditto — a silhouette rather than a machine |

The amber `#E3A423`, the orange `#D2601F`, all six department colours and the
other eight civilian paints survive the correction unchanged: they were bright
enough that two stops down still reads as paint. **`StreetLifeView` did not have
this defect** — its model bakes every coat and marker tint to linear at
`configure` — which is the audit answer the task asked for.

**DEFERRED, with a named owner.** The same latent lift is on every **vertex**
colour in every procedural mesh in this renderer — `ConstructionRigMesh.STEEL`,
`DARK`, `TYRE`, `GLASS`, `GRAVEL`, `VehicleMesh`'s part tints,
`StreetLifeMesh.CLOTH_DARK` and the rest — because a vertex colour takes no
decode either. It is not fixed here for one reason: several of those constants
are used BOTH as vertex colours and as instance tints (`GRAVEL` is the dump
truck's load and the yard's gravel heap), so converting the constant would move
both at once and the mesh half has never been judged against a picture.
~~**awaiting_consumer:** the next render pass, over
`game/render/construction_rig_mesh.gd`, `game/render/vehicle_mesh.gd` and
`game/render/street_life_mesh.gd`, with a screenshot per mesh family.~~
**CONSUMED 2026-09-01 by RR-95** (§38), which is the named pass over the three
named files with the screenshot pass the filing asked for. One correction to
this deferral's own text is recorded there: `GRAVEL` as "the dump truck's load"
is a DEAD vertex colour — the load carries `SURF_STOCK` and the fragment stage
replaces it with the `stock_color` uniform, which is `source_color` and
therefore already decoded. The heap half of that dual use is real and is exactly
why the conversion went at the WRITE and not at the constant.

**Applied:** `game/render/vehicle_view.gd` (`_paint_for` + the `CIV_PAINT`
re-judgement), `game/render/construction_activity.gd` (`_plant_paint`,
`_stock_linear`, the `LIVERY` re-judgement),
`tests/test_vehicle_view.gd` and `tests/test_construction_living.gd`
(three tests), doc 91 A91-D-36, doc 93 §V4.

### RR-92 — RR-83's corollary, audited and closed (docs 11 §2.13/§2.16, 93 §S3)

RR-83 ruled that `node.visible = n > 0` belongs on the same line as
`visible_instance_count`, applied it to `StreetLifeView`, and **filed the rest
for the lead**: `ConstructionVehicleView`'s five buffers on a city with no
sites, `PowerInfraView`'s smoke buffer on a healthy grid. The audit is done.

**The instrument first.** The harness could price a BUSY layer and an ABSENT one
and never the third thing a real city spends most of its life in — the layer
present, every buffer empty, every node still submitting — because `--sites=0`
did not build the layer at all. `profile_frame --quiet-layers` builds both
optional layers and stands nothing in them, which is the quiet city.

| bench city, balanced, hour 21 | Z0 | Z1 | Z2 |
|---|---|---|---|
| baseline, before | 95 | 113 | 196 |
| `--quiet-layers`, before | 100 | 118 | 201 |
| baseline, **after** | **87** | **105** | **188** |
| `--quiet-layers`, **after** | **87** | **105** | **188** |

**−13 draw calls at every pose on a quiet city**, and the optional layers now
cost exactly zero when they have nothing to draw. The 5 is
`ConstructionVehicleView`; the other 8 is `VehicleView`, which nobody had
counted because the harness feeds it no traffic — seven body buffers and a
headlight cone, all eight submitting, all eight empty. In the real game the
emergency four are empty in any city with nothing on fire and **the headlight
cone is empty for the whole of every daylight hour**, so the saving is real
there too, just smaller.

**The audit, layer by layer, so the next person does not redo it.**

| layer | verdict |
|---|---|
| `StreetLifeView` | already gated (RR-83) |
| `ConstructionVehicleView` | **gated now** — 5 buffers, world AABB, born hidden |
| `VehicleView` | **gated now** — 7 bodies + cone, world AABB, born hidden |
| `CityView` bucket nodes | **gated now** — a bucket is allocated on the first building of its (archetype, level) and is not freed when the last is demolished, so a redeveloped chunk carries empty buckets that still submit |
| `CityView` far nodes | **gated now** — `_upload_far` returns its instance count and the caller gates on it |
| `PowerInfraView` | already gated — `_pad_node.visible = count > 0`, `_smoke_node.visible = count > 0`. No change needed; the filing was cautious rather than wrong |
| `FloodView` | already gated |
| `StreetlightView` | not applicable — a chunk with no lamps is FREED, not emptied |
| `RoadOverlayView`, `PathGhostView`, `ConstructionSiteView` | already gated, or per-object nodes that are freed |

`VehicleView` and `ConstructionVehicleView` both publish `active_buffers()` now,
for the reason RR-83 gave: a budget claim that cannot be printed is a budget
claim nobody re-checks.

### RR-93 — A field the renderer needs is a field the save owes it (docs 06 §2.16, 08 §2.8, 11 §2.17, 93 §V2)

**The gap (render q2), and it is bigger than the field.** Doc 11 §2.17's wander
is a closed form in `(id, elapsed)`, which makes it exact under pause, catch-up
and frame-rate change — and undefined after a COLD LOAD, because the layer had
no way to learn when a restored opportunity had appeared. Worse: **it had no way
to learn that it existed at all.** `CitySim.restore_state` refills the roster in
silence — there is no `opportunity_spawned` for a row that was already on the
books — and `game/main.gd`'s load path resyncs the road surface, the vehicles,
the power layer, the lamps and the flood field, and not this one. A crook the
player was walking toward was live, tappable and paying, and **invisible until
it expired**.

**Both halves, in one field and one call.** `born_gm` (the spawn game-minute) is
written at spawn, republished on all three payloads and persisted with the row;
`StreetLifeView.seed_roster(sim.street.live())` replays the restored roster as
spawns carrying it, so every body comes back MID-WANDER rather than restarting
on its first waypoint. A row written before this field derives it from
`spawned_h × 60`, which is exactly what the spawner would have written, so an
old save is a body with a beat rather than a crash.

**The hash delta, predicted before the run and published.** A payload field is
not hashed (`state_hash` is `capture_state`; the bus is not in it); a persisted
row is. And the COARSE path never spawns — doc 06 §2.16's offline fairness rule
— so the roster it hashes is empty whatever the row's shape.

| `profile_sim --hash-only` | before | after |
|---|---|---|
| starter, coarse 24 h | `a27da24a…` | **`a27da24a…` (unmoved)** |
| starter, fine 2.0 h | `d2dec672…` | `7745cb25…` |
| bench, coarse 24 h | `7c99720f…` | **`7c99720f…` (unmoved)** |
| bench, fine 2.0 h | `8f60accb…` | `d8e88896…` |

`tests/test_save_determinism_days.gd` — the multi-day
save → load → advance identity gate — is green, which is the property that
matters: the baseline moved because the row got wider, not because the sequence
moved.

**Applied:** `sim/street/opportunity_system.gd` (the field on spawn, on
`event_payload`, in `deserialize`), `game/render/street_life_model.gd`
(`spawn`'s fifth argument, `seed_roster`), `game/render/street_life_view.gd`
(`seed_roster`), `tests/test_street_opportunities.gd` and
`tests/test_street_life.gd` (five tests), doc 93 §V2. **`game/main.gd` is the
lead's** — the one-line call is in the branch report's integration snippets.

## 37. WAVE 14 MERGE — the ledger is re-derived, and the ids are made unique (binding)

### RR-94 — A derived total is re-derived at the MERGE; a colliding id moves by a stated rule; and a sentence that names a command is re-RUN, never re-read (docs 91 §0/§17/§20.1b/§20.4/§20.6, 92, 93, 98 §24/§26)

**RR-55 said a digest published from a branch is a statement about that branch.
RR-76 said a derived total is not a source. Both were obeyed by all four Wave-14
branches, and the tree still ended the wave with **three double-assigned ids**,
**six doc-93 section headers carrying a letter none of their own rulings used**,
**two doc-98 section numbers each assigned three times**, **nine bad
cross-reference targets across sixteen references**, two count tables counting
rows they had never printed, and a completion statement telling its reader to do
work a sibling had already done.** None of that is a failure of the two rulings; it is the half of the
problem they do not reach. RR-55 and RR-76 govern what a *branch* may publish.
This ruling governs what a *merge* must do about it.

**(a) The count is re-derived at the merge, from the documents, with the
arithmetic printed.** Doc 91's basis is
`grep -c "^### 2\.[0-9]"` per document (**184** across docs 01–13 at this fork),
plus an **enumerated and now CLOSED** promotion list of four `####` rows (all
doc 11's: §2.1.1, §2.1.2, §2.1.2a, §2.10.1), plus **two** enumerated
cross-cutting `—` rows (both doc 05's, each printed twice in §5 and counted
once). `184 + 4 + 2 = 190`. Graded: **172 SHIPPED / 15 PARTIAL / 1 ABSENT /
2 DEFERRED**, and `172 + 15 + 1 + 2 = 190` is printed as a check rather than
trusted. **172 of 190 — 90 %, or 91 % of the 188 non-deferred rows — is the
project's single quotable figure and it supersedes the 170/188 RR-76 named.**

**The promotion list is closed, and doc 03 §2.5a is why.** §2.5a (state grants,
RR-79) is a genuinely shipped deliverable with its own constants, its own
`assistance` revenue line and its own tests — and so are doc 11 §2.15.1 and
§2.16b, doc 06 §2.6(z)/§2.10.1/§2.10.2/§2.13(b), and sixty more:
`grep -c "^#### 2\."` over docs 01–13 returns **63**, of which four are already
promoted, leaving fifty-nine with an equal claim. **No criterion admits
§2.5a and excludes doc 07 §2.6.3 or doc 09 §2.9.4**, and a basis that grows by
whichever sub-heading a wave felt proudest of is not a basis. Sub-headings are
graded inside their parent row, whose pointer must name them. The four
grandfathered rows stay because four waves of printed grades hang off them; they
are a historical accident the table declines to repeat, and when §17 becomes a
test the list should be deleted and the basis should be the bare `grep`.

**(b) A colliding id stays with the row that CODE already points at; the row
whose references are docs-only takes the next free number.** Three collisions
existed at this merge and the rule resolves all three without a judgement call:

| collision | keeps the id | why | moves to |
|---|---|---|---|
| `A91-D-31` ×2 (two Wave-13 siblings) | the sliced offline catch-up | named from `sim/time/catchup_cursor.gd`, `sim/city_sim.gd`, `tests/test_catchup_cursor.gd` | the incident-roster cascade → **`A91-D-35`**, the sequence's one unissued number |
| `A91-D-33` ×2 (two Wave-15 siblings) | the opportunity layer | named from `tests/test_save_migration.gd:345` | the dispatch-ledger row → **`A91-D-38`** |
| doc 93 `G4` ×2 | the `place_water_main` ruling | five doc references, and the Wave-10 block's own header claims the contiguous range `G4–G6` | the interloper → **`G9`** |

A code comment is the reference hardest to keep true and the one a grep-driven
reader trusts most, which is the whole of the reason. Where neither side has a
code reference, the id stays with the block whose **header** claims a contiguous
range. Both halves are mechanical, so the next collision costs a lookup rather
than a debate.

**(c) A section header is part of the id space, and a per-line merge `sed` does
not know that.** The lead's Wave-13/14 merges renumbered rulings correctly and
left their **section headers** behind, in six places in doc 93 — `## K.` heading
`L1`, `## M.` heading `N1`–`N4`, `## O.` heading `P1`–`P2`, and three separate
`## P.` headers over `R`, `S` and `T`. Doc 98 carried the same fault in its own
numbering: **`## 24.` three times and `## 26.` three times.** Every live
reference resolved to the first of each (checked one by one), so the first keeps
its number and the later two take a `b`/`c` suffix — this document's own house
style, established by RR-60b. **Fixed at this merge; the rule from here is that a
renumbering `sed` must be run against `^#{2,4} ` as well as against the body.**

**(d) Nine cross-reference targets were wrong across sixteen references — five
dangling and four resolving to the WRONG section, which is worse.**
**Dangling (9 references, 5 ids):** doc 92 `§23.8` / `§23.9` / `§23.12` — cited
from §18 of this report, and the content is doc 92 **§24**'s Wave-10 pass; doc 92
`§35.5` — from `tests/test_balance_gates.gd`, and §35 has no `.5` at all; and doc
93 `§M3` — five references, and the ruling is **§N3**.
**Resolving to the wrong section (7 references, 4 ids):** doc 92 `§35.2`,
`§35.3`, `§35.4` and `§35.6` — every one a money-pass pointer that lands on the
*opportunity layer's* section, because the money pass was drafted as §35 on its
branch and merged as **§36**. **A dangling reference is a broken link; a reference that resolves to
the wrong section is a lie with a footnote, and only a validator finds the
second kind.** All are corrected — **and the validator that found them SHIPS, as
`tools/check_doc_refs.py`**, rather than being described. It walks
`docs/ sim/ ui/ game/ tests/ tools/ data/ .github/` and checks two things: that
every `RR-nn`, `A91-D-nn`, `92 §<n>.<m>`, `93 §<letter>` and `98 §<n>` resolves
to a header that defines it, **and that no header id is assigned twice** — which
is the half that would have caught `A91-D-31`, `A91-D-33` and `G4` at the moment
each was filed. At this merge: **2,517 references, all resolving, no id assigned
twice, exit 0.** No dependencies, reads only, 163 lines. **It belongs in CI
beside the suite**, and it fails closed: injecting four ids that do not
exist — one per space — is reported as four `DANGLING` lines and exits 1.

**(e) A sentence that names a command or a field must be RE-RUN, not re-read, at
every merge.** Doc 91 §20.4's one-paragraph answer told its reader that doc 13
*"needs one `export_presets.cfg` field"*. True at the fork it was written on;
**false one commit later**, because a sibling branch of the same wave filled the
field and RR-70 proved the field was never the root cause. For one wave the
project's most-quotable sentence directed whoever read it to redo finished work.
Two more of doc 91's PARTIAL evidence commands had gone stale the same way —
`grep -rln _on_app_resumed tests/` now returns a file (a comment, not coverage)
and the doc-13 permission grep now returns four flags. **A PARTIAL row is only as
good as the command underneath it. Re-run the command; do not re-read the
sentence.**

**What this costs and what it buys.** Nothing in `sim/`, `game/` or `ui/` moved
and no behaviour changed: the whole ruling is documents, four test/data comment
pointers, and the ids. The four determinism baselines at this merge — founding
`a27da24aaf6e9663…` / `d2dec6727c64001d…`, bench `7c99720f5ff14553…` /
`8f60accb6d91ad1e…` — are re-measured rather than quoted, and they differ from
**all four** sets the Wave-14 branches published, because two of those branches
wrote `sim/` and `data/`. That is not drift; that is a merge, and it is exactly
why the merge is where a count gets re-derived.

**Applied:** doc 91 §0 (the re-derived count table and the basis rule), §6, §12,
§14.5 (the two renumberings), §17.1/§17.2 (the 25-of-25 census), §20.1b, §20.4
(the completion statement, re-taken) and **§20.6** (the Wave-14 marker sweep);
doc 92 §41; doc 93 §U and six section headers; doc 98 §24b/§24c/§26b/§26c and
this section; doc 06 §9 item 9 (closed); doc 11 §6 (the deferred-pedestrians
annotation); **new: `tools/check_doc_refs.py`**; and four stale pointers in
files that are not documents — `tests/test_city_sim.gd:146` and
`tests/test_balance_gates.gd:412` (comments), `tests/test_balance_gates.gd:2277`
(an assertion's failure-message string, which a passing run never builds) and
`data/economy.json`'s `_wave15_money_pass_note` (a `_`-prefixed comment key).
None can change behaviour, and that is proved rather than asserted:
`profile_sim --hash-only` was run on both cities **before and after** these
edits and all four digests are byte-identical.


## 39. WAVE 17 — the economy dial-in: who pays, how fast, how much (binding)

*Filed 2026-09-02 against the user's three playtest notes of 2026-09-01. Five
rulings — one of which was reversed by its own measurement, and that reversal is
the most useful thing in this section. Every number was measured on this branch
and the command is quoted beside it. The rulings themselves are doc 93 §Y and the
measurements doc 92 §43.*

**Baselines.** The fork's four `tools/profile_sim.gd --hash-only` hashes were
`a27da24aaf6e9663…` / `7745cb25e55ff65c…` (starter) and `7c99720f5ff14553…` /
`d8e8889681b23297…` (bench), verified unmoved before a line was edited. After
this pass: **`05614522975fad52…` / `d1aaee0dca92f2fd…`** and
**`275aad9d4aeea809…` / `d40126e371371d59…`**. `data/buildings.json` carries no numeric change at all — every
`decay_per_hour` cell is byte-identical to the fork (RR-101); its one diff is a
stale `s2.12 -> s2.14` cross-reference inside a `_note` string that
`tools/gen_buildings.py` had already corrected and the shipped file had not.

**The shape of it.** Three notes came back from days of play on the Fold — repair
is too aggressive and bills the wrong party, income is too slow, upgrades cost
too much — and each of them turned out to be a *contract* defect wearing a
tuning defect's clothes. The repair note is an ownership error the code states
plainly and nobody had read; the income note is a charge that should never have
been on the city's ledger; the upgrade note is a coefficient whose correct value
is an identity between two constants that were already published.

### RR-99 — the repair moves to the owner; the SERVICE cost does not

**Ruling: `cmd_repair_building` refuses private stock; `E_building_maint` stays;
`ASSET_CONDITION_PENALTY_COEFF` reaches the two city assets still billed flat.**

`EconomySystem.settle_hour`'s maintenance loop skips every row for which
`CostCurves.is_revenue_producing(type)` is false — C-08, so a civic or utility
shell is not billed twice beside its own department or O&M line. That predicate
is `REVENUE_CLASSES.has(class_of(type))` and `REVENUE_CLASSES` is
`["residential", "commercial", "industrial", "tech"]`, so the set the line bills
is exactly the set the city does not own. **The first draft of this ruling
retired it on that reading and the retirement was withdrawn on the measurement**
(doc 92 §43.8): with the line gone and private stock keeping itself up,
`tools/measure_insolvency.gd` put `do_nothing` on `standard` at game-day **176**
against gate 29's ruled 69, and `casual` never went insolvent inside 200
game-days at all.

What the line prices is the city's cost of **serving** a building — the reading
C-08's own exclusion implies, since civic shells are excluded because *their own
O&M lines bill them* — and it rises as a building wears because a worn building
costs more to serve. What the 2026-09-01 playtest asked to move to the owner is
the **repair**: a lumpy purchase, at a price, behind a tap, on a building the
player does not own. That is what moves.

* `cmd_repair_building` refuses private stock with `E_OWNER_MAINTAINED` at any
  condition, and `repair_view` folds the code into "nothing to buy" so no row is
  drawn (doc 93 §Y3a). Measured: the REPAIR affordance falls from **260 private /
  21 civic** to **0 / 24** in a 21-game-day `balanced` city, and private repair
  trips from 14 to 0.
* A private building's owner holds it at `condition.band_worn` **while the city
  serves it**, so it is never `damaged` by wear, never destroyed by wear, and
  always still upgradable (0.60 > `min_condition_to_upgrade` 0.55). After a
  720-game-hour absence a `balanced` city's private stock goes from
  **2/16/236/8** across the bands to **4/233/0/0**, with **0** damaged.
* The city sees the drag as `f_condition` — `0.40 + 0.60 × 0.60 = 0.76`, a
  permanent **24 %** cut in what a neglected building pays — and the recovery is
  an **upgrade**, which sets condition back to 1.00 and which RR-103 made 20.7 %
  cheaper in the same wave.

**Founding ledger, both sides** (`tools/measure_founding_ledger.gd --hours=24`,
`standard`, seed 1337): gross **1047.184374 → 1047.184374, bit-identical**;
expense `532.296003 → 533.212457`; net `514.888371 → 513.971917`. The **only**
line that moves is `departments`, by +$0.92/gh, because doc 93 §Y5 finally
applies `ASSET_CONDITION_PENALTY_COEFF` to a worn station — the coefficient a
worn transformer and a worn water main have always paid. That is **0.18 %**,
inside every anchor's own ±1 % tolerance, so **gates 1, 2 and 2b hold unchanged
and not one pacing guardrail is re-fitted.** The same reading closes the one flat
row left in `e_grid`: a plant carries the condition penalty its own nodes and
lines carry.

### RR-100 — `building_rules.json.condition` was a mirror; `Building` now reads it

**Ruling: the condition block is stamped on every `Building` and read from
there.** PA-13 found that all fifteen keys were validated for presence, asserted
by `tests/test_building_catalog.gd`, and **read by nothing** — `building.gd`
hardcoded every one of them — so this wave's decay retune would have edited a
file that moves nothing. The block is stamped beside `stats` and `max_level` at
the four sites that make a `Building` live (boot, restore, placement, and doc
05's water shell), never as
a static: `sim/` is RefCounted-only and the rigs boot several `CitySim`s per
process, so a process-global would let one city's fixture move another city's
physics. The consts remain as the fallback, so a `Building` nobody stamped is
bit-identical to the day before.

The gate is PA-13's own and is the reason this row exists: `tests/test_building.gd`
perturbs an authored key and asserts the **behaviour** moves, not that the loader
accepted it. Five tests, one per key family. **Scope: the `condition` block only.**
`construction.*` and `headroom_safety` are the same defect in the same file and
belong to the construction-queue and power lanes; PA-13 stays open until they land.

### RR-101 — PA-82's decay cap is DECLINED, and the neglect clock is re-fitted

**Ruling: no city decay rate moves.** PA-82 asks that `power_facility` 0.00090,
`substation` 0.00080, `water_facility` 0.00070 and `construction_yard` 0.00065 be
capped at the house's 0.00045. The cap was implemented, measured and withdrawn:

```
tools/measure_insolvency.gd --max-days=200 · do_nothing · seed 1337
                            casual   standard   hard   crisis
  gate 29's ruled figures      105         69     51       26
  with the cap               NEVER        168    128       71
  without the cap            NEVER        175    131       38
```

After RR-99 the city's own decay rates are the only neglect clock left, and the
cap doubles it on its own. Doc 02 §2.3's Decay columns are restored cell for
cell; **no private seed was ever touched**, because after RR-99 a private seed
sets only how fast a building reaches its owner's floor.

*PA-82 is not thereby dismissed.* Its real complaint is that the plant's and the
water works' first quotes land before the sheet has taught repair — a curriculum
and surface problem, and its own proposed fix (the Grid-health chip warning from
plant condition) is the power lane's. Declined on the rate; open on the surface.

**Gate 29 is re-fitted, and it is the only gate this pass moves.**
`tools/measure_insolvency.gd --max-days=220`, three seeds:

| preset | 1337 / 4242 / 9001 | mean | Wave-14 mean |
|---|---|---|---|
| `casual` | 193 / 190 / 189 | **190.7** | 105.0 |
| `standard` | 137 / 139 / 129 | **135.0** | 69.0 |
| `hard` | 58 / 97 / 64 | **73.0** | 51.0 |
| `crisis` | 31 / 18 / 43 | **30.7** | 26.0 |

Horizons `120/90/70/55 → 210/160/120/70`, ceiling `118 → 200`, floor unmoved at
18, `standard` pinned `69 ± 6 → 137 ± 12`. **Every preset still dies and doc 03
§2.9's ordering holds on every seed individually**, which is the assertion the
gate is for. The derivation is doc 92 §43.8: the ownership floor removes private
structural failure, which was the dominant term — half the engine, twice the
clock.

**And the autopsy that made this necessary is a finding in its own right.** A
probe of an untouched `standard` city shows `PLANT-1` **destroyed on game-day 40**
and `SUB-A` **on 45**, with the tax line moving from 569.7 to 580.1 across the
two failures — *nothing goes dark*. So the service clause that was to keep
neglect fatal after private stock stopped rotting to death is built on a signal
this fork does not emit, and what actually killed a neglected city was private
structural failure. It is the third instance of the audit's own "a computed value
with no consequence" (PA-02, PA-08, PA-09), it is the most expensive because a
whole difficulty table was fitted on it, and it belongs to the power lane. Filed
as doc 93 §Y8.

### RR-102 — the founding taper is correct and was invisible

**Ruling: publish the window; move no dollar.** Doc 03 §2.5a's assistance retires
`FOUNDING_ASSISTANCE_PER_HOUR / FOUNDING_ASSISTANCE_DAYS = 172/7 = $24.571/gh =
$589.71 a game-day`, which PA-32 measured as the largest single mover of the net
chip in the opening fortnight, with no toast, no log row and no end date
anywhere. Flattening it would pay the player for the seven days they are least
short of money — a `do_nothing` starter city banks **$89,798 by game-day 7**
without being touched. `CostCurves.founding_assistance_days_left()` reads the
same two constants the other way round, the settle snapshot carries
`assistance_days_left` at its top (a **count**, so it is not inside `revenue`,
where every key is a dollar a sheet sums), and doc 12's budget row spends it on
its own label.

### RR-103 — an upgrade costs what the revenue it adds is worth

**Ruling: `UPG_COEFF = TAX_LEVEL_GROWTH − 1 = 1.15`, an identity and not a fit.**
Doc 03 §2.3's ladders reduce every payback to a ratio of published constants:

```
payback(upgrade L->L+1) = (build_cost_l1 / base_tax_l1)
                        x [UPG_COEFF / (TAX_LEVEL_GROWTH - 1)]
                        x (UPG_GROWTH / TAX_LEVEL_GROWTH)^(L-1)
```

and `build_cost_l1 / base_tax_l1` is **exactly 100 gh for every revenue
archetype**, so the bracket is the whole of it. Measured on the shipped, rounded
tables (house, `upgrade_cost / Δbase_tax`): `124.3 / 153.0 / 176.8 / 210.6 /
249.4` → **`98.6 / 121.3 / 140.2 / 167.0 / 197.8`** game-hours. The ruled window
is `[100, 200]` — one new-build payback to two — and 1.15 is the largest
coefficient whose whole six-rung ladder fits inside it.

**PA-46's own constant is superseded**: it proposes `UPG_COEFF ≤ 1.15 ×
(TAX_LEVEL_GROWTH − 1) = 1.3225` "so L1→L2 payback ≤ new-build", and substituting
gives a ratio of `1.3225/1.15 = 1.15`, i.e. a first rung 15 % **worse** than a
new build — the opposite of its stated target. The exclusive condition is
`UPG_COEFF ≤ TAX_LEVEL_GROWTH − 1` and this ruling takes the equality.

`CAPITAL_VALUE_V` is re-derived to `[1.000, 2.150, 5.083, 12.560, 31.629,
80.254]` and every cell is now its own closed form at 3 dp; the L3/L5
disagreements the 1.45 vector carried were artefacts of that coefficient. Two
derived consequences are published rather than left stale:

* **the water and power component ladders FOLLOW, and pinning is forbidden**
  (doc 93 §Y7a). `water_component_upgrade_cost` is defined as a *ratio of doc
  03's anchor step*, not as a price — doc 05 owns the ratio, doc 03 owns the
  dollar — so pinning would author a second upgrade curve, which is a second
  currency authority in the one place C-07 names by hand.
* **`LEVEL_UP_GRANT_BY_CITY_LEVEL` rungs 5 and 6 follow doc 03 §2.5a's own rule**
  — "the city pays half of what the next chapter asks you to buy". Rung 5's basis
  is an *upgrade* (the level-6 tower step, `73,572 → 58,350`), so `37,000 →
  29,000`, and rung 6's own 2.25× extrapolation with it, `83,000 → 65,000`.
  Rungs 1–4 are built on build costs, which did not move.

**The construction-rush verb is not in this lane's fork** (`grep -rn "cmd_rush"
sim/` is empty here) and this lane changes no line of it. It prices a rush off
`CostCurves`, so RR-103 carries into it automatically: a rush of an upgrade gets
**20.69 % cheaper** in step with the upgrade, and its derived per-crew-hour rate
is unchanged because that rate is a fraction of a price and both halves move
together. Recorded so the merge checks it rather than discovers it.

## 45. WAVE 17 FORK — the production audit's three rulings (binding)

*Filed 2026-09-01 from `main` `fd4d8a0` by the synthesis agent of the production
audit (`99-production-audit.md`). Sections §38–§44 and rulings 95–122 of the `RR` space are
reserved for the Wave-17 lanes that forked from the same commit; this section's
number and its three ids were pre-assigned by the lead so that no two branches
of the wave could claim the same one (RR-94(b)). The gap is deliberate and
`tools/check_doc_refs.py` tolerates a gap — it refuses only a collision.*

### RR-123 — Severity in a production audit is measured on the device path, not in the tree, and the ladder maps onto doc 91's grades (docs 91 §14.5, 99-PA §1.2)

**Seven lenses filed 112 findings with seven private notions of P0.** The
shape hunter called a dead data table P0; the sim lens called a stalled
scheduler P0; the breakage lens called an uncalled function P0. Each was right
by its own light and the ledger could not be ranked until one rule held for all
of them. The rule:

- **P0 (doc 91 Critical):** on the path a player actually plays, the shipped
  build *lies* (a false sentence, a dead affordance, a green gate that punishes
  later), *discards* their progress or a valid decision, or a
  constitution-level loop is unreachable in every save.
- **P1 (High):** an authored mechanic doc 91 grades SHIPPED cannot fire or be
  reached, or a control lies about part of what it claims.
- **P2 (Medium):** a drift or a missing surface the player can route around,
  or a test gap with a named on-device consequence.
- **P3 (Low):** doc-only, cosmetic or forward-looking.

**Applied at the fork.** Two lens P0s moved: the auto-reclose that never
resolves (`99-PA PA-08`, A91-D-63) is P1 — it never lies and it never
finishes, which is quieter than a false push; the goals-sheet standing line
laid out one character per line was **dropped**, because `main` had closed it
at `f9ccfd7`/`fd4d8a0` before the lens's tree caught up. The Director stall
(`PA-04`, A91-D-59) stays P0 under the third clause: the weather loop is one of
the constitution's four and it is unreachable in every save after the second
minor event. Five P0s survive; every one of them is A91-D-19's shape — a
computed value with no consumer — and every one of them was found by a census
or a probe, not by a test.

**Why the device path and not the tree.** A count of dead keys is a fact about
the repository; a player cannot see it. A flood push that says traffic is being
turned back while every engine drives through at full speed is a fact about the
phone, and it is the one the user reported as "alerts for nothing". The audit
ranks the second kind above the first even when the first is larger, and it
says so in the row so that the next audit can disagree with the ranking without
disagreeing with the evidence.

### RR-124 — A row a concurrent lane owns is recorded, not re-proposed; a hub file is partitioned by function; a pre-assigned id block leaves a gap and the gap is not a defect (docs 91 §14.5, 98 §37, 99-PA §3)

**Six Wave-17 lanes were building while the seven lenses read.** Four of the
audit's rows, and halves of five more, fall inside those lanes' remits
(`99-PA §3.1`). The audit does not propose them again — a second agent on the
same seam is a merge conflict with a plan — but it does **record their evidence
here**, because the merge check needs something to check against: the decay
retune lands nothing unless `Building` reads `building_rules.json` (A91-D-68);
the fix-button rework lands nothing on the transformer case unless a `T-nn` id
resolves (A91-D-60). A row marked *in flight* therefore carries the sentence
the merge must find true.

**Two hub files cannot be avoided.** `sim/city_sim.gd` (4,700 lines) and
`game/main.gd` (2,034 lines) are named by more than half the Wave-18 lanes.
Rather than serialise the wave behind them, each lane owns **named functions**
in those two files and nothing else there; a lane that needs a function outside
its partition files a one-line note for the lead instead of editing it.
`data/*.json` binding tables, `data/strings.en.json` and `KNOWN_VERBS` are
**append-only** across lanes. The lead resolves order at merge. This is the
merge discipline of RR-94 applied one level earlier, at the fork.

**On the ids.** The lead pre-assigned this audit `A91-D-56 … 80`, `RR-123 …
125` and doc 98 §45, leaving `41 … 55`, `95 … 122` and §38–§44 to the lanes.
The sequences will show gaps until the wave merges, and may keep some. A gap is
not a double assignment and the checker treats it so; a reader who finds number 47 missing from the `A91-D` sequence should look for a Wave-17 branch, not a lost row.

### RR-125 — Which rows get an `A91-D` id: a defect in a thing that exists, never a feature the doc authors; the audit's own ledger keeps every row (docs 91 §14.5, 99-PA §2)

**Doc 91 §14.5 is a register of defects, and this audit found more rows than it
has ids for.** 100 survived merging; 25 ids were assigned. The rule for the 25:
a row is promoted when it is **P0 or P1** *and* names **something that exists
in the tree and does not do what it claims** — a gate that reads the wrong
hour, an event that is authored and never emitted, a file that is validated and
never read, a button that returns before it acts. A row that asks for something
that does not exist yet — the storm prep panel (`PA-26`, master plan P1-19),
the land tab (`PA-28`), the missing tutorial rows (`PA-29`), the jump-to-worst
button (`PA-30`), the auto-repair policy for buildings (`PA-33`), the ground
textures (`PA-36`) — is a *plan item*, and plan items go to the master plan's
backlog and this document's §3, not to the defect register. The `max_coarse_hours`
clamp (`PA-27`) sits on the line — a NORMATIVE rule unimplemented — and is not
promoted because its on-device consequence is already carried by A91-D-74.

**The audit's `PA-nn` ids are permanent handles.** Every one of the 100 rows is
cited as `99-production-audit.md PA-nn` (short form `99-PA PA-nn`) and the
promoted 25 carry that pointer in their doc 91 row. A fix that closes a promoted
row closes it in doc 91 the way every other `A91-D` row is closed — struck
severity, date, wave, the discriminating test — and the `PA` row in this
document is **not** edited: the audit is a record of a fork, not a living
register, which is the same status doc 92's measurements have (RR-55).

**What this costs and what it buys.** Nothing in `sim/`, `game/` or `ui/` moved
on the branch that filed this: the whole audit is one new document, 25 register
rows and this section. The four determinism baselines are untouched by
construction. What it buys is a ranked, verified, lane-partitioned roster for
Wave 18 that the lead can assign without re-reading 112 findings — and a
severity rule that the next audit can apply before it starts filing.

**Applied:** doc 91 §14.5 (rows A91-D-56 … A91-D-80 and the block note beneath
them); this section; `docs/design/99-production-audit.md` (new). Re-grades of
doc 91's SHIPPED rows that this audit contradicts (doc 07 §2.6, doc 05 §2.11,
doc 09 §2.6/§2.10, doc 04 §2.5, doc 02 §2.9, doc 10 §2.10, doc 12 §2.17) are
**deferred to Wave 18 lane T** so that the branch that filed the evidence is not
also the branch that rewrites the grades (RR-94(e): re-run, then re-grade).

---

## 48. WAVE 17 — the catch-up owed on a cold launch (binding)

*Filed 2026-09-01 from the production audit's robustness lens. Three findings,
three rulings; every number below was measured on this branch and the command is
quoted beside it.*

**The shape of it.** Doc 08's Core Design Rule 2 — *"the city continues while the
player is away"* — had exactly one implementation, and it was reachable from
exactly one place: `game/main.gd::_on_app_resumed`, connected to
`AndroidLifecycle.resumed`, which fires only for
`NOTIFICATION_APPLICATION_RESUMED`. That is a notification a **dead process never
receives**. Android kills backgrounded games routinely — a swipe-away, the task
switcher's X, a low-memory kill, an OEM battery manager — and the title door
(doc 12 §2.19) makes the *default* player launch a fresh process too. So on the
commonest way back into this game, the city resumed **frozen at the pause**, with
no veil, no catch-up and no away report. Core Rule 2 was true only for the case
where nothing had gone wrong.

Everything needed to fix it was already on disk and read by nobody:
`manifest.active.real_unix` and `manifest.max_seen_unix` were written by
`sim/persistence/save_manager.gd` and by `game/save_service.gd`, and
`grep -rn "last_loaded_real_unix\|max_seen_unix" game/` at the fork returned the
writer and no reader.

### RR-132 — Core Rule 2 owes the absence on ANY successful restore, not on a notification

**Ruled.** The absence is a property of **the generation that was loaded**, not
of the process that loads it. Every successful restore — the title door's
CONTINUE, `--resume`'s `load_latest`, crash recovery — now asks
`AndroidLifecycle.arm_cold_resume(save_service)` what the city is owed, and the
answer goes to the shell through **the same `resumed` signal an in-process resume
uses**. There is one catch-up path in the game and the cold launch is not a
second one; it is a different way of *measuring elapsed time* and nothing else.

**The stamp.** Doc 13 §3.2's `save.android.last_pause` is built as specified —
`{unix_s, elapsed_realtime_ms, boot_id, clock_ticks, app_version, clean}` — by
`game/android/lifecycle_stamp.gd`, and rides **every** save rather than only the
pause one: a periodic autosave the process was killed two seconds later is just
as much a "last time this city was awake", and `clean` is what tells the two
apart. The section is registered on the WRITE side and read straight out of the
loaded body on the read side, because `SaveManager._validate_structural` files a
`repair_notes` entry for every registered section a body is missing and **every
generation ever written predates this one** — registering it on the read side
would put "(1 repairs)" in front of a player whose save is perfectly healthy.
That is a deviation from doc 08 §3.1's registry shape and it is recorded here
rather than left in a comment; it costs nothing at `section_version = 1` and
reverses the day a v2 needs a migrator.

**Fallback.** A generation with no `android` section falls back to
`manifest.active.real_unix` — a wall reading with no monotonic bracket, which is
exactly the information desktop has always had, so it is credited on those terms.

**The three clamps, in the order they may overrule each other**
(`LifecycleStamp.elapsed_since`, doc 08 §2.9 + doc 13 §3.2):

1. **`max_seen_unix` is absolute.** `now_unix + 120 s < max(max_seen_unix,
   stamp.unix_s)` ⇒ the clock moved backwards ⇒ **credit zero**, log it, play
   continues. We clamp; we never punish. The 120 s is doc 13 §2.3's existing
   tolerance, not a new number — a 60-second NTP correction is not a tamper.
2. **`elapsedRealtime` within one boot is a CEILING.** Same `boot_id`, both
   known ⇒ a wall delta above `(now_realtime − stamp_realtime) + 120 s` is a
   forward clock jump and is clamped to it.
3. **`elapsedRealtime` across a reboot is a FLOOR.** Different `boot_id` ⇒ the
   device restarted *during* the absence, so the absence is at least as long as
   the device has been up. A wall clock claiming less has lost time and the
   floor wins. `""` is never "same boot" — `AndroidNative.boot_id`'s own rule.

**Timing.** The absence is queued and spent by `AndroidLifecycle.pump_resume()`,
called from `Main._process` **after** the `_restore_cursor` and `_catchup_cursor`
early-returns and never while the title door is up. `Main` is `SimHost`'s parent,
so a parent-first `_process` order guarantees the pump runs before any live tick
of that frame; the door's CONTINUE fires it on the restore's own last frame,
which is the same guarantee by a shorter route.

**Pinned:** `tests/test_cold_launch_catchup.gd` — the load-bearing one is
`test_the_cold_path_and_the_warm_path_land_on_the_SAME_city`: two cities from one
seed over one four-hour absence, one through `NOTIFICATION_APPLICATION_RESUMED`
and one off the disk, compared on `state_hash()`.

### RR-133 — `max_coarse_hours` is implemented, and the reference city is the STARTER city

Doc 08 §2.12's decision rule has been NORMATIVE since report C-21 and was
implemented **nowhere**: `grep -rn max_coarse_hours sim/ game/ data/` at the fork
returned zero hits, and `CatchUpPlanner` clamped at `OFFLINE_CAP_REAL_MS` alone.

**Measured 2026-09-01** (`godot --headless -s res://tools/profile_sim.gd --
--coarse-hours=48 --fine-hours=1 --repeats=3 --no-profile --quiet`, this
workstation, debug headless):

| City | coarse step | `ceil(2000/m)` | ↓ ×24 | `max_coarse_hours` |
|---|---|---|---|---|
| `data/starter_city.json` (34 buildings) | **5.488 ms/hour** | 365 | 360 | **360** |
| `tests/fixtures/bench_city.json` (1,500 buildings) | **165.493 ms/hour** | 13 | 0 | **72** (floor) |

The Fold multiplier is doc 13 §2.13's 3–5×, on top of both.

**Ruled: the rule reads the STARTER city, and 360 ships.** Three reasons, and the
third is the one that decides it:

1. `tests/test_milestone1.gd::test_coarse_step_cost_budget` — P0-30, the task
   that OWNS this measurement — has always measured the starter city, and doc 01
   §2.10's shipped note records the starter figure as the value the rule reports.
2. The bench fixture is doc 09 §2.13's **1,500-building stress fixture**, sized
   to break the renderer. It is not a city a player reaches, and a clamp derived
   from it would be a clamp derived from a city nobody has.
3. **Doc 08 §2.12 states which way to err, in its own words:** *"at the 72-hour
   floor the floor wins over the budget — we would rather spend 4 s once than
   hand back less than three game-days."* The clamp only ever *discards player
   time*; under-clamping costs veil seconds, over-clamping costs game-days. 360
   is the larger of the two candidates and it is what the rule's own stated
   preference points at.

**And the disagreement is recorded rather than resolved.** `bench_coarse_ms` sits
in `data/persistence.json` beside the shipped number, and
`tests/test_catchup_clamp.gd` re-derives the shipped value from the measurement
beside it, so the two can never drift apart silently. **The honest statement is
that the rule's premise — one measured number characterises the device — is false
across cities by a factor of 30, and that this ruling picks a side rather than
fixing it.** Fixing it would mean a clamp derived from the LIVE city, which
constitution §5 forbids: a catch-up that credited two different amounts on two
phones for the same absence is not deterministic. Filed as an open question, not
as a defect.

**What a player notices, stated plainly.** An absence longer than **6 real
hours** now credits 360 game-hours (15 game-days) rather than 720 (30 game-days),
and the veil and the away report both say so. `tests/test_catchup_planner.gd` is
re-pinned with both forms — doc 01's C-19 ladder arithmetic with the cap passed
explicitly, and the shipped default beside it — so the two facts stay separable.

**The copy was dead, and that is the other half of this ruling.**
`ui/away_model.gd` has carried `capped_text` since S12 and `game/main.gd`'s
report dictionary **had no `capped` key at all**, so the line could never fire;
and `ui_veil_catchup_capped` said "12 hours" as a literal. Both now take the cap
that was actually applied — `{hours}` in the veil string, `cap_game_hours` in the
report dict.

### RR-134 — a second absence is QUEUED; an interrupted plan is CARRIED, never re-derived

**The defect.** `_on_app_resumed` answered a second absence arriving on top of an
unfinished one with `_catchup_cursor.run()` — drain the whole remaining plan on
this frame. Up to 720 coarse steps at 165 ms on the benchmark city is **119
seconds of blocked main thread**, an ANR twenty-four times over, on the one path
Wave 14 had just made reachable. And `_on_paused` in between committed a
mid-absence city and overwrote `_before_snapshot` with it, so the away report
diffed the city against a version of itself that was already half way through the
absence it was reporting.

**Ruled — SEQUENTIAL, and the remainder is carried as SEGMENTS.** The full
argument is doc 93 §AG; the conclusion is that "merge the remaining ticks with
the new elapsed into one plan" is **not expressible**. A plan's shape is a
function of the tick index it was planned at — the fine head-align, the 40-tick
fine tail, the residual — and a partially-spent coarse segment additionally
carries `ctx.catchup_index` / `ctx.catchup_total`, which doc 03's offline yield
decay and doc 07's 72-hour offline event gate both read. None of that survives
being turned back into a duration. So `CatchUpCursor.remaining_plan()` hands back
the unspent segments *with their original `index_base` and `total`*, and
`CatchUpPlanner.plan_after(unfinished, …)` puts them in front of the next
absence's plan as one schedule. `catchup_begin()` still fires once per coarse
segment (doc 07 C-55) and not again for a carried tail.

**Three consequences, all built:**

* A resume with a cursor in flight calls `AndroidLifecycle.defer_absence()` and
  returns. The old plan keeps stepping under the veil at 12 ms a frame; the
  queued absence is pumped when the frame is free.
* `_on_paused` mid-catch-up tags its save **`pause_mid_catchup`** (a new
  `SYNC_REASONS` entry — sync for the same reason `pause` is), skips
  `plan_for_background` entirely (the alarms would be predictions from a city
  that is still being simulated), and `Main._on_app_paused` leaves
  `_before_snapshot` alone.
* The unspent tail rides `last_pause.unfinished`, so a **process death mid-veil
  is finished by the next cold launch** rather than lost. The pre-absence
  snapshot rides with it, so the away report's 'before' survives the death too.

**Pinned:** `tests/test_catchup_resume.gd`.
`test_a_plan_carried_across_a_process_death_is_BIT_IDENTICAL` interrupts a plan
130 units in, finishes it from the carried remainder alone, and compares
`state_hash()` against the same plan run straight through; the two orderings —
death then relaunch, and death then a further two-hour absence — are pinned
separately.

### The three findings, and where each is closed

| Finding (2026-09-01 audit) | Severity | Closed by | Evidence |
|---|---|---|---|
| Cold launch never runs the offline catch-up | **P0** | RR-132 | `tests/test_cold_launch_catchup.gd` (10 tests) |
| Backgrounding mid-catch-up drains synchronously; the pause overwrites the report's 'before' | P1 | RR-134 | `tests/test_catchup_resume.gd` (13 tests) |
| Doc 08 §2.12's `max_coarse_hours` not implemented | P1 | RR-133 | `tests/test_catchup_clamp.gd` (15 tests) |

## 41. WAVE 17 — the rush verb and the overview roster: the sim half (binding)

*The player's ask, verbatim: "if we have buildings that are being upgraded or
built on, those should have a queue that tells us what's actually being built and
the progress tracker of that. And we also should have the ability to speed it up
with cash." This is the `sim/` half — the roster read and the money verb, against
a seam contract the UI branch builds to independently. Doc 03 §2.13(f) prices it,
doc 92 §45 derives the rate, doc 93 §AA argues the shape. **All four determinism
baselines are bit-identical**: a rush is a player verb and no agent taps it.*

### RR-107 — The price of time was already published; it was just not written as a rate (docs 03 §2.5/§2.13(f), 92 §45, `data/economy.json`, `sim/economy/cost_curves.gd`)

**The question.** A rush needs a price, and the brief was explicit: derive it
against doc 03's own build/upgrade tables, say what fraction was chosen and why,
**do not guess**. The trap is that "a meaningful premium" is exactly the kind of
number a branch invents, defends with a paragraph, and hands the balance report
as a new claim to re-litigate every wave.

**The finding.** Doc 03 §2.5 has carried the answer since the founding ledger.
The *emergency contractor* row — `CONTRACTOR_SURCHARGE 1.80 ×` the job cost for
`CONTRACTOR_TIME_FRACTION 0.35` of the duration — is not a package price, it is a
**point on a curve**: it buys `1 − 0.35 = 0.65` of a project's duration for
`1.80 − 1 = 0.80` of its cash price. The quotient is the rate:

```
RUSH_SURCHARGE_PER_DURATION = 0.80 / 0.65 = 1.230769…  → published as 1.23077
rush_cost = ceil( remaining_crew_hours × cash_price × 1.23077 / required_crew_hours )
          = ceil( 1.23077 × (1 − progress) × cash_price )
```

**The ruling.** The cell is **published in `data/economy.json` behind a
`CostCurves` accessor** (C-07: a price lives in that file, not in a runtime
expression) and **re-checked against the two cells it came from at load** —
`RUSH_DERIVATION_TOLERANCE 1e-5`, residual `7.7e-7`, and a drifted cell is a boot
error, asserted by
`tests/test_construction_rush.gd::test_the_rush_rate_is_the_contractor_row_carried_to_its_limit`.
A published derivation that nothing re-derives is a comment.

Three consequences are binding. **(a) The fraction is 1.23 of the project's cash
price for a full-length rush**, so an instantly-finished anything costs 2.23× its
sticker — chosen because it is the only rate that leaves the contractor and the
rush at *identical value per hour saved*, so neither dominates and §2.5's
"deliberately bad value" verdict is inherited rather than re-argued. **(b) The
rate is PER-PROJECT, not a flat $/crew-hour.** The roster's dollars-per-crew-hour
spans **15×** (`house` $600/ch → `data_center` $9,000/ch); a flat rate at the
median would price a `house` rush 2.71× too dear and a `data_center` rush at
**0.18×** — $180,000 of tower finished instantly for $40,000, which is not a
bad-value valve but the dominant strategy in the game. Doc 92 §45.2 has the
sweep. **(c) Rounding is a CEILING, and §2.13(f) names it as the ladder's one
exception to §2.1's half-up.** This is the only price computed against a live,
continuously-moving quantity; half-up would let a project at 99.9 % quote **$0**
and hand over the last of the time for none of the money.

**No difficulty multiplier is applied on top**, and that is not an omission:
`M_build` / `M_dev` are already inside the job's cash price, so a `crisis` city
pays a `crisis` rush through the number the rush is a fraction of. Applying it
again would charge `M²`.

### RR-108 — A rushed completion is not a second completion path; it is the SAME one, called from a command (docs 02 §2.13, 93 §AA2, `sim/construction/construction_queue.gd`, `sim/city_sim.gd`)

**The rule this obeys.** *Every event that completes or creates a Building must
reach `main.gd`'s `_on_sim_batch` translator, and a rushed completion fires the
SAME events as a natural one — never a new bespoke path.* The Wave-13 pump lesson
is the reason it is written down, and a money verb that finishes buildings is
exactly the shape that re-breaks it: the tempting implementation calls
`Building.complete_construction()` directly, gets a working building, and quietly
skips `_sync_station_fleet`, `_commission_water_nodes`, `_commission_grid_node`,
doc 09's phase auto-submit and doc 03 §2.8's invoice for it.

**The mechanism, ruled.** `ConstructionQueue.force_complete(job_id)` fills the
accumulator to its required total, takes the job off the queue and returns **the
identical record `advance()` would have returned** — and deliberately routes
nothing. The dispatch loop that used to live inside `WorkPhaseSystem.advance_fine`
is lifted verbatim into **`CitySim._route_completed_jobs(completed)`**, and both
callers use it. The rush path then runs the tick's own order for that one job:
`_emit_construction_stages()` (so the finished site's stage residue clears
exactly as it would have), `_route_completed_jobs([finished])`, and
`_charge_development_phases()` (so a rushed phase's successor is billed in the
same breath, which is §2.8's *"never a phase behind the site"* rule).

`force_complete` requires **no crew**, and that is doc 03 §2.5's fiction, not an
oversight: the whole point of *"paying to bypass the construction/crew queue"* is
that it works when the city's own crews are somewhere else. A job parked at
`blocked_reason = "no_crew"` is precisely the one a player pays to be rid of.

The one **new** event is `construction_rushed{job, cost, source}` — additive, and
emitted *in front* of the completion (the money left, then the thing finished).
It carries an `awaiting_consumer` row in `tests/test_event_matrix.gd` naming Wave
16's `ui/construction_queue_model.gd` and `game/notifications/`; the row deletes
itself the day the model lands, by the register's own expiry test.

**The shell-side tail of this rule, found on review and NOT fixed here.** The
sim half is whole — the events are emitted, in the right order, onto the bus. But
there is exactly **one** live drain in the shell, `SimHost._process`'s
(`game/sim_host.gd:35`, `grep -c "bus.drain()" game/main.gd game/sim_host.gd` →
one apiece, and `main.gd`'s is the offline-report path at 1675), and it is gated
on `if paused or sim == null: return` at `sim_host.gd:27`. **A player verb that
completes a building therefore leaves its completion on the bus for as long as
the game is paused.** For `cmd_place_building` this has always been invisible —
the site appears with its scaffolding either way. For a rush it is the whole
verb: the player pays to make a crane go away, and the crane stays up until they
un-pause. `main.gd` is the lead's file, so this is a snippet and a ruling, not a
patch. The fix is the two lines `main.gd` *already runs* on the offline path,
given a name — insert immediately **after** `_on_sim_batch`'s body, at the line
`func _render_id(sim_id: String) -> int:`:

```gdscript
## A player verb that COMPLETES work (doc 03 §2.13(f)'s rush) emits its events
## from inside the command, and the only live drain is `SimHost._process`'s,
## which does not run while the game is paused (`sim_host.gd:27`). So a rush
## bought from a paused panel finishes in the sim and leaves its crane standing
## until the player un-pauses. This is the door that lets a command's own batch
## through immediately. It is NOT a second translator — it is `_on_sim_batch`,
## called once, with the events already on the bus — and it is idempotent: a
## second call drains an empty array and does nothing. Same two lines the
## offline-report path already runs at `_apply_offline_progress`.
func flush_sim_events() -> void:
	if sim_host == null or sim_host.sim == null:
		return
	var batch: Array = sim_host.sim.bus.drain()
	if not batch.is_empty():
		_on_sim_batch(batch)
```

`awaiting_consumer` — Wave 17's UI branch calls it on the tap that returns
`{"ok": true}` from `cmd_rush_construction`, and nothing else in the game needs
it today. Filed against RR-108 rather than taking a new id, because it is this
rule (*the completion must reach the translator*) at the one seam the sim half
cannot reach from inside `sim/`.

### RR-109 — There was nothing to unify: `cmd_upgrade_building` has no clock of its own (docs 02 §2.13, 09 §2.3, 10 §2.13, `sim/city_sim.gd`)

**The mapping this branch was told to make first**, and the answer, recorded
because the next reader will ask it too. Every project the player would call
*"being built or upgraded"* runs through doc 02 §2.13's **one** queue:

| submitter | kind | roster `source` |
|---|---|---|
| `cmd_place_building` (and `cmd_place_water_component`'s shell) | `build` | `build` |
| `cmd_upgrade_building` — **the §2.11 gate submits a job; the accumulator IS the timer** | `upgrade` | `upgrade` |
| `cmd_repair_building` | `repair` | `repair` |
| `DevelopmentController._submit_phase` (doc 09's six phases) | `development` | `block` |
| `RoadNetwork` build / upgrade / repair, via the injected `submit_job` | `road` | `road` |

So `construction_overview()` is a read of `active_jobs()` and **nothing else** —
no adapter, no second source, no merge — and the "if upgrades run a separate
clock, adapt them" branch of the brief is dead code. The `city_sim.gd` ladder
note that prompted the question is about **which row the DURATION is read from**
(RR-38: the row upgraded *from*, not *to*), not about where the clock lives.

Two things are ruled here so the roster cannot drift. **(a) The kind → source map
is TOTAL over `ConstructionQueue.KINDS`**, including the two nothing submits
(`rebuild`, `clear_rubble`), so a new kind can never reach `ui/` as a word the UI
branch was never told about; the gate is
`test_every_job_kind_has_a_published_source`. **(b) Only `development` is
renamed** — the player bought a *block* and is watching a block — and every other
kind keeps the queue's own noun, because a second vocabulary for the same thing
is how two halves of a seam drift apart.

The roster's `title_key` is the **noun** (`ui_build_card_<archetype>`,
`ui_land_phase_<phase>`, and five new namespaced `ui_queue_title_road_*` /
`ui_queue_title_project` keys); the **verb** is `ui/`'s to compose from `source`
and the `level_from`/`level_to` pair. Shipping the noun once is what stops the
two branches authoring two rosters. Every key the roster can answer is asserted
to resolve in `data/strings.en.json`.

### RR-110 — Hash-neutrality is not evidence for a player verb; the quote-versus-charge is (docs 92 §45.4, `tests/test_construction_rush.gd`)

**The trap.** A player verb no agent calls **cannot** move a determinism
baseline, so "all four baselines are bit-identical" is a statement about the
harness, not about the feature. Publishing it as the branch's proof would be
A91-D-40's mistake in a new costume: a check that passes identically whether the
thing works or not.

**The ruling.** The neutrality claim still ships — all four digests reproduce the
post-Wave-15 values byte for byte, and a moved one would mean the verb had leaked
into the tick path — but it is stated as a **falsifier, not evidence**. The
discriminating assertions are the verb's own, and there are four claims worth
making:

1. **the quote is the charge** — the dollars the roster drew are the dollars the
   treasury lost, exactly, with no rounding drift and no partial deferral, and
   **nothing is charged on any refusal**;
2. **a rushed building equals a naturally-finished one** — two cities, same seed,
   same house; one finishes on the clock, one buys the rest of the hours;
   compared field-for-field *and* event-stream-for-event-stream from
   `building_completed` onward;
3. **the price lives in exactly one file** — asserted by **absence**, scanning
   every `data/*.json` but `economy.json` for the key, because a test that only
   proves doc 03's cell is present passes identically beside a live duplicate;
4. **the refusals refuse** — and the money-shaped one is checked from both sides
   of the credit floor, one dollar apart.

Two further properties are asserted because instant completion's *claim* is that
it adds no state: a city that has rushed **restores from its save at rest and
replays bit-identically two game-hours on**, and the same seed plus the same taps
produces the same city (the verb draws no RNG and reads no clock).

## 42. WAVE 17 — the queue surface: a rail that wraps, a clock that may not read zero, and a beat felt once (binding)

*The UI half of the construction queue (doc 12 §2.22, doc 93 §AB), built
against the seam CONTRACT through a provider `Callable` and swept before the
sim half existed. Three rulings. All three are hash-neutral by construction —
nothing under `sim/` moved and the four `profile_sim` baselines at this fork
are byte-identical to 9e3f5d3's — which is exactly why they are about pixels,
words and frames rather than about numbers.*

### RR-111 — A corner rail WRAPS before it overflows, and never hides a door to make room (docs 12 §2.3/§2.22, 93 §AB2, `ui/ui_widgets.gd`)

**The bottom-right rail was two chips and a tab, solved by D-46 against no
height at all.** It did not need one: two rungs fit every box at every scale.
The queue chip is the third rung, and at the project's own minimum box — 640 ×
340, `data/ui.json.layout.min_safe_box_dp` — at the 150 % A2 names for it, a
chip measures **92 dp**, so rung 3's bottom edge sits at `92 + 2 × (92 + 8) =
292` above the safe area's bottom edge and its top at **384**, which is window
`y −48` on a 340 dp display. The door to the queue would have been 48 dp above
the top of it, on precisely the box and scale the deck promises to survive, and
`UIAudit` would have said `offscreen` on every screen behind it.

**The ruling.** `UIWidgets.solve_corner_rail()` takes the safe area's height
and `corner_rail_capacity()` — a pure static function — fits
`floor((H − margin + gap) / (pitch + gap))` chips per column, never fewer than
one, and starts a second column one chip-width plus a gap further in for the
rest. Measured: **2** per column at 640 × 340 / 150 %, **5** at the 880 × 400
reference box; `host_h = 0`, which is every caller before this wave, is the
old unbounded column byte for byte, so the reference screenshots do not move.
The column ends at the safe area's edge and not at the top bar's underside on
purpose: the bar is a different layer, the two chips that were already there
have passed under it at 150 % since D-46 shipped, and moving them to tidy a
cosmetic overlap would break D-46's own promise. **This is D-1's rule for the
top bar — wrap before you overflow — applied to the other corner; a rail that
runs out of room drops nothing, shrinks nothing and stacks nothing under
anything.** `tests/test_ui_audit.gd::test_the_corner_rail_wraps_before_it_overflows`
pins the arithmetic; the 18-cell sweep (doc 92 §46) pins the pixels.

**Re-open condition.** A fourth chip. Two columns of two is the most the
minimum box holds at 150 %, and the third column would reach the overlay
legend's side of the display; at that point the corner needs a *priority* —
§2.4's chip-collapse solver, which chip yields first — not a third column.

### RR-112 — An unworked project says so in WORDS: `-1` is a state, and a clock that reads `0:00` is a lie the player acts on (docs 02 §2, 12 §2.22, `ui/construction_queue_model.gd`)

**The seam carries two facts that mean the same thing** — `eta_gm = -1.0`
("nothing is working it") and `crews = 0` — and a row that formats `eta_gm`
as a span prints `0m` for the first and *some number* for the second. Both
are wrong in the worst direction: `0:00` on a bar frozen at 12 % reads as
*finishing now*, which is the opposite of what is true, and a countdown on a
job nobody is on is a promise the queue cannot keep. A player who reads either
one will wait for a completion that is not coming rather than buy a crew or
rush the job — the two things the screen exists to offer.

**The ruling.** `working := eta_gm >= 0 and crews > 0`, decided **before** a
sentence is written, and an unworked project renders as the sentence
`ui_queue_eta_none` — *Nothing is working on this yet.* — with the bar hatched
as well as amber (A5) and the crew line reading *No crew*. The span formatter
is never handed a negative: `UIWidgets.duration_text()` floors at `0m` for a
caller that has no reading, and the caller owns the words for *why*. The rush
price stays on the face of an unworked row, because a project nobody is
working is exactly the one a player would pay to unstick. The two contract
fields are treated as one fact that has to agree, so a fixture — or a future
sim — that sends `crews = 2, eta = -1` or `crews = 0, eta = 40` produces the
sentence and not a clock; `tests/test_ui_construction_queue.gd::
test_an_unworked_project_says_so_in_words_and_never_as_a_clock` holds it.

**Why it is a ruling and not a formatting note.** Doc 12 §2.8's land panel
wrote the same rule for a development phase and it was obeyed by one caller.
The queue is the first screen where the `-1` arrives across a seam from a
system that does not know what the screen will print, and a seam is where a
convention has to become a rule.

### RR-113 — A spend is felt from the BUS, once; a refusal from the DOOR; and two things a frame will not forgive (docs 12 §2.21/§2.22, 91 A91-D-50, `ui/ui_root.gd`, `ui/ui_widgets.gd`, `tools/ui_preview.gd`)

**(a) One beat, one source.** The salvage this wave began from buzzed the
player's hand twice for one rush: once when the door answered `ok` and once
when `construction_rushed` came back off the bus a tick later. D-62's rule —
one cue, one chip, one sentence — was obeyed by each half and broken by the
pair. The ruling: **an accepted rush does nothing at the door.** The toast,
the chip pulse, the haptic and (through `data/audio.json`) the `purchase` cue
are all spent by `UIRoot._check_construction()` off the bus, so a rush from
the queue, from S5's inline verb, from a later automation or a replayed batch
is felt exactly once and identically; the door's answer is read only for a
**refusal**, which is §2.7's formatter over `err` as a toast — and
`E_NO_COMMAND` is silence, because there is no story to tell about a feature
that is not there. `UIRoot.report_rush()` is public for the same reason:
S5's `rushed` signal reaches it through the shell and a refusal reads the same
on both doors.

**(b) A control that removes its own row may not free itself mid-signal.** The
RUSH press rebuilds the list it was pressed from, and `UIWidgets.clear_children()`
frees immediately — correctly, everywhere a rebuild is driven by a refresh, so
a new row never collides with the old one for a frame. Here the button being
freed is the one whose `pressed` is still being emitted, and Godot names that
an error and a potential crash. It is caught by the tap-then-rush case as
ENGINE OUTPUT rather than as a failed assertion — with `clear_children()` put
back the file still passes 22/22 and the run prints `Object … was freed or
unreferenced while a signal is being emitted from it`; with
`release_children()` that line is not there — caught before any device ran it.
**The ruling: a list rebuilt from inside one of its own
children's signals uses `UIWidgets.release_children()` — detach now, free at
frame end — and nothing else in the deck changes.** The alerts feed sidesteps
the case by repainting rather than rebuilding on a tap; this is the first
screen where the tap genuinely takes the row away.

**(c) A single-state audit that measures on its first frame measures a deck no
child has processed.** `tools/ui_preview.gd --screen=<one>` is the instrument
a developer reaches for first. A parent's `_process` runs before its
children's, and the first frame's `delta` carries the boot — so the 0.12 s
settle window was satisfied on the very first frame, before any sibling chip
had run the `_process` that yields the edge to an open panel. Measured on a
tree the whole-deck sweep called clean in all eighteen of its cells: three
states across the six gate boxes reported **46** findings, every one of them an
`overlapping_targets` between an open panel's rows and a corner affordance that
had not yet stood down — `--screen=alerts` worst at **7** (360 × 800, 880 × 400
and 1280 × 720 alike), `--screen=queue` at **4** on 640 × 340, and
`--screen=building_upgrading` at **3** on the same box. The guard is two whole
frames after `_apply()` (`MIN_FRAMES_BEFORE_MEASURE`), and all eighteen read
**0** afterwards, exit 0. Doc 92 §46.3 has the table. **A single-state run has to answer the
same as the sweep, or the first thing a developer measures is the one thing
they cannot trust.** A91-D-50 is the row.

**What this wave costs, for the record.** No file under `sim/` changed. The
four determinism baselines were re-measured at the fork before any edit and
again on the finished tree, and all four are byte-identical to 9e3f5d3's —
starter `a27da24aaf6e9663…` / `7745cb25e55ff65c…`, bench `7c99720f5ff14553…` /
`d8e8889681b23297…`. Doc 92 §46 has the geometry and the sweep table; doc 91
§14.5 the two rows; doc 12 §2.22 the screen and its deferral rows.

---

## 43. WAVE 17 — the camera learns to look up: a sky nobody had judged, a band the budget bought, and a ray that is allowed to miss (binding)

**The user's directive (2026-08-21), verbatim:** *"we need to be able to look up
at the buildings — the high rise is really tall; if you zoom in you're pretty
much just looking at the ground… on the right side of the screen a tilt slider,
vertically: all the way down, all the way up, the slider sits in the middle, up
and down motion."* The 2026-09-01 visual audit added the warning that goes with
it: *"what the horizon will expose once the camera tilts: an 896 m floating slab
with a hard cliff."*

**What shipped:** a manual pitch axis on `ui/camera_state.gd` composing with the
zoom curve (never replacing it); a two-finger tilt arm in
`ui/gesture_recognizer.gd` + `game/touch_input.gd`; the right-edge column
`ui/tilt_slider.gd` (doc 12 §2.23) with two preview states; a procedural gradient
sky (`game/shaders/sky_gradient.gdshader`, installed by
`game/environment_controller.gd`) whose horizon haze is the day/night FOG tint;
`--tilt=`, `--yaw=`, `--sky=` and `t<zoom_t>` poses in `tools/profile_frame.gd`;
and the `camera` block of the `ui` save section (doc 12 D-68). **Nothing in
`sim/` moved and no baseline moved** — `profile_sim --hash-only` on both cities,
before and after, all four digests byte-identical (§43.5).

### RR-114 — A sky nobody could see had never been judged (docs 11 §2.8, 12 §2.23, 93 §AC1)

Before this wave **no reachable camera pose could see the sky at all**: the pitch
curve's shallowest angle is 34°, the vertical FOV is 40°, so the top of the frame
sat 14° *below* the horizon at every zoom. The `ProceduralSkyMaterial` the scene
built was therefore an AMBIENT SOURCE wearing a sky's name — its colours reached
the frame only through `ambient_light_source = SKY`, and nobody had ever looked
at it, because looking at it was not possible.

The manual floor makes the top of the frame 8° *above* the horizon (12° of pitch
minus 20° of half-FOV) and the sky becomes the backdrop the skyline is read
against. What ships is a gradient and nothing else — zenith → horizon in one
`pow`, a haze band at the horizon, a ground hemisphere below it; no sun disc, no
scattering, no clouds, no half-res pass (the Fold is fragment-bound, doc 11
§2.13). **The one non-obvious decision is that the haze band is the FOG tint, not
the sky's own horizon colour** (`DayNightController.sky_colors`): the far city
fogs toward `fog_tint` and the sky draws toward the same colour, so the two meet
on one value and the world's edge is seated rather than cut.

**Measured, and this is the audit's P1 answered with a number.** Worst case as
specified — pitch floor, far zoom, camera at the city's own corner looking out
over the edge (`--tilt=12 --hour=13 --yaw=225 --focus=60,60 --poses=z2`) — the
sky→ground seam at the world edge is a **single-pixel step of at most 17/255 in
any channel**, sampled at three columns: sky `(118,131,145)` → ground
`(111,123,128)`, max step 15 / 16 / 17 at x = 120 / 300 / 1700. There is no
cliff, and there is no black band: what a grazing camera sees past the last block
is haze in the same colour the far roofs are already wearing. **Re-open:** a
capture on the Fold's OLED where the same step may band; and the `ground_darken`
sliver, which is authored (0.45) rather than measured.

The sky's own cost is **not resolvable on the dev GPU** and is published that way
rather than claimed: `--sky=gradient` against `--sky=procedural`, same city, same
hour, same poses, gives **identical draw calls in all six cells** and `rs gpu`
differences of −0.13 … +0.87 ms, inside a run-to-run spread of ±0.9 ms measured
by repeating one cell (Z1 day floor: 3.955 then 2.187 ms with nothing changed).
Per preset, which is what doc 11 §2.8 asks for: the sky is drawn on the pixels
the city does not cover and the presets do not change that — the floor pose measures
the **same** 363 / 333 / 258 dc+ui at performance, balanced and high (doc 92 §47.5),
so the sky's per-preset cost is the same unresolvable GPU term three times.
The term that should matter on a tile GPU is `sky.radiance_size` **64** against
the engine's default 256 — the ambient cubemap is re-convolved whenever a colour
moves, which is every frame, because the hour is. That one is **unmeasured here
and owed on the device**.

### RR-115 — The band composes; the far end of it was bought with a measurement (docs 11 §2.5/§2.13, 12 §2.23, 92 §47, 93 §AC2)

`pitch = lerp(curve(t), target, |bias| · reach(t))`, `target` = 12° up / 78° down.
Three properties fall out and all three are tested: bias 0 is **exactly**
`pitch_deg_at(t)` at every zoom (so a city that never touches the slider is the
camera it was before Wave 17, to the bit); the middle detent is honest, because
the value it holds is the curve's own answer rather than a number that resembles
it; and the ZOOM still owns the default, which is what keeps AUTO meaningful
after a pinch.

`reach_up_far = 0.76` is the wave's one bought number. At `reach 1.0` the Z2 floor
is 12°, the camera sits `420·sin 12° = 87 m` up — **under doc 11 §2.5's 150 m NEAR
boundary** — and four chunks re-tier into the near/shadow pass: **330 dc (355 with
the UI's 25) against a 320 budget**, day, bench city. At 0.76 the floor is 24°,
the camera is `420·sin 24° = 171 m` up, past the boundary, NEAR back to zero:
**233 dc (258)**. The slider's track visibly compresses to match — the *angle* the
ends buy shrinks, never the travel, so the thumb keeps its whole column.

**What the same measurement refuses to hide:** the near and mid floors bust the
budget by day — Z0 **338 dc (363)**, Z1 **308 (333)** — and no band that shows the
horizon can avoid it, because the cliff is not at the floor: it is at
**pitch = half the FOV = 20°**, the angle at which the horizon enters the top of
the frame and the whole city enters the frustum behind it. Measured either side of
it at Z0, day: 26° → 235 dc, 20° → 332 dc. Narrowing the near reach far enough to
stay under 320 would put the floor at ~26°, which is a camera that cannot see the
sky — i.e. it would retract the feature to protect a proxy for it. The excess is
published (doc 92 §47), the mechanism is named, and the runtime guard is doc 11
§2.13's governor. **Re-open:** a Fold capture at a Z0/Z1 floor pose whose p95
passes 16.7 ms at balanced lowers `pitch_reach_up_near`, or grows the row a mid
knot; the fix with the best prize, if one is wanted, is a pitch-coupled
`far_cull_m` — at the floor the far city is already fogged to within 7 % of the
sky, so the geometry paying for those draw calls is geometry nobody can see.

### RR-116 — A ground ray that misses is an ANSWER, not a zero (docs 12 §2.16/§2.23, 93 §AC3, 91 A91-D-51)

`CameraState.screen_to_ground()` has always answered a `Vector3` for every screen
point, because until this wave every screen point *had* a ground point: the guard
that clamps a near-parallel ray to `dist · 4` was a numerical safety net, not a
semantic one. **At the manual floor the top of the frame is sky**, and the old
signature can only answer that tap with a point 1,680 m away that the player did
not touch — which would place a building, draw a road, or deselect, on a tap
aimed at a cloud.

`ground_hit()` is therefore the honest read: `{hit, position, reason, distance}`
with `reason` ∈ `ground` / `above_horizon` / `grazing`. `screen_to_ground()`
survives verbatim on top of it, because **pan, pinch and the anchor lock want *a*
point and the old behaviour is exactly right for them** — a pan that stopped
tracking because the anchor left the ground would be a worse bug than the one
being fixed. The callers that must not act on a guess are all in `game/main.gd`
and are handed over as snippets (§43.4): the tap path, the world-drag router and
the mouse-hover ghost. `m_per_dp()` is **pitch-invariant by construction** (screen
right is parallel to the ground at every pitch), so §2.21's 48 dp tap radius keeps
its metres through a tilt; the anisotropy is entirely in the other axis and is
published as `m_per_dp_depth()` = `m_per_dp / sin(pitch)` (×1.79 at the 34° curve
floor, ×4.81 at 12°), which means a tilt can only make a radius pick MORE
conservative on screen, never less.

### RR-117 — A headless mount has no layout, so a test that asserts a laid-out rect is asserting the harness (docs 12 §2.18, 91 A91-D-52, 93 §AC4)

Two families of test arrived with this wave's salvaged work and **both were
green-looking and wrong**; they are recorded because the shapes recur.

**(a) A `force_layout()` box is not a laid-out deck.** `SafeArea` is a
`MarginContainer`, and a container only fits children that are
`is_visible_in_tree()`; a `CanvasLayer` mounted into a headless `SceneTree` root
is not, so **every rect in the deck is 0×0** and every right-anchored control sits
at `x = −width`. This is why `tests/test_ui_audit.gd` walks `walk_frame_free()`
and why every other `force_layout()` caller in the repository asserts *minimum
sizes* and never positions. The tilt slider's geometry tests now assert what the
control itself sets — anchors, offsets, the band solve, the stand-down — and the
laid-out rect is checked where a real viewport exists: `tools/ui_preview.gd
--screen=all --audit --strict`, which is clean at 412×915, 640×340 and
360×800 @130 % with large targets, exit 0 in all three.

**(b) A synthetic two-finger stroke fed as one jump is not a gesture.** Godot
delivers each finger's drag as its own event, so the recogniser always sees an
intermediate sample with one finger moved and the other not. Fed as a single
40 dp jump per finger, that intermediate is an **11.3° bearing change across a
200 dp span** and engages the (pre-Wave-17) TWIST arm before the tilt table is
ever consulted — a fact about the feed, not about a device, where 60 fps at
600 dp/s is a 10 dp step and 2.9°. Every discrimination test now walks in
device-sized steps (`_walk_pair`). The residual finding, filed and not fixed
because the twist arm is not this lane's: **at ≥ 28 dp of inter-event finger lag
(≈ 1,700 dp/s at 60 fps, or 850 dp/s at 30) a two-finger vertical stroke can trip
the 8° twist deadzone before the tilt engages**, and the city yaws where the
player meant to tilt. The tilt's own thresholds are already half the twist's
precisely so it cannot steal a rotation; the reverse direction wants a per-finger
travel test rather than a centroid one.

### 43.4 The `game/main.gd` snippets (the lead's file — not edited on this branch)

Four hand-overs, each anchored on a line quoted from `game/main.gd` at this fork.
Numbers 1–3 are the RR-116 callers; number 4 is what binds the slider and the
save block. Without number 4 the column never appears and `capture_ui_state()`
writes no `camera` key — the deck degrades to exactly its pre-Wave-17 behaviour,
which is the intended failure mode.

1. **The tap** — anchor `var ground := camera_state.screen_to_ground(screen_pos, viewport_size)`
   in `_handle_tap()`; replace with the typed read and bail on a miss.
2. **The world-drag router** — anchor `var ground := camera_state.screen_to_ground(position,`
   in `_route_world_drag()`; a `PHASE_BEGIN` above the horizon declines the
   stroke, which hands it back to the camera as a pan.
3. **The hover ghost** — anchor `build_sheet.move_ghost(camera_state.screen_to_ground(`
   in `_unhandled_input()`; a hover above the horizon leaves the ghost where it
   was rather than teleporting it to the far clamp.
4. **The camera binding** — anchor `save_service.ui_provider = root.capture_ui_state`
   in the UI wiring; `root.bind_camera(camera_state)` goes immediately before it,
   so the block exists before the first save and before the resume restore two
   lines below.

The four, in full. Applied to `game/main.gd` on this branch for a parse check
(`godot --headless --check-only --script game/main.gd`, exit 0) and then reverted
with `git checkout -- game/main.gd`, so the file this branch ships is the lead's,
byte for byte.

**1 — `_handle_tap()`.** Replaces the `screen_to_ground` line and the two
branches under it:

```gdscript
	# Wave 17 (doc 12 §2.23 / report 98 RR-116): at the manual pitch floor the top
	# of the frame is sky, and `screen_to_ground` would answer a tap up there with
	# the far clamp — a point the player never touched.
	var answer := camera_state.ground_hit(screen_pos, viewport_size)
	var ground: Vector3 = answer["position"]
	var on_ground := bool(answer["hit"])
	if build_sheet != null and build_sheet.is_placing():
		if on_ground:
			build_sheet.move_ghost(ground)
		return
	if build_sheet != null and build_sheet.is_open():
		# A tap that reached the world missed every sheet control: dismiss.
		build_sheet.close()
		return
	if not on_ground:
		# Not a pick, and not a deselect either: the selection survives a tap on
		# the sky, because the player did not touch anything to change it.
		return
```

**2 — `_route_world_drag()`.** Replaces the `screen_to_ground` line and the two
`match` arms that use it:

```gdscript
	var answer := camera_state.ground_hit(position,
			Vector2(get_viewport().get_visible_rect().size))
	var ground: Vector3 = answer["position"]
	var on_ground := bool(answer["hit"])
	match phase:
		TouchInput.PHASE_BEGIN:
			# Wave 17 (RR-116): a run that begins above the horizon has no first
			# tile. Declining hands the stroke back to the camera as a pan.
			return on_ground and build_sheet.begin_world_drag(ground)
		TouchInput.PHASE_UPDATE:
			# Mid-run the stroke stays the tool's: a finger that crosses the
			# horizon holds the last valid tile rather than dropping the run.
			return build_sheet.update_world_drag(ground) if on_ground \
					else build_sheet.is_drag_drawing()
```

**3 — `_unhandled_input()`, the mouse path drag and the hover ghost.** Two
replacements in the `InputEventMouseMotion` branch:

```gdscript
			if build_sheet != null and build_sheet.is_placing_path():
				# Wave 17 (RR-116): both ends of this stroke have to be ON the
				# ground — the anchor (the press point) and this sample.
				var from_hit := camera_state.ground_hit(_tap_origin, viewport_size)
				var at_hit := camera_state.ground_hit(motion.position, viewport_size)
				if bool(from_hit["hit"]) and bool(at_hit["hit"]):
					if not build_sheet.is_drag_drawing():
						build_sheet.begin_world_drag(from_hit["position"])
					build_sheet.update_world_drag(at_hit["position"])
```

```gdscript
		elif build_sheet != null and build_sheet.is_placing():
			# Hover keeps the ghost under the pointer; the verdict is recomputed
			# on every move (§2.7) and only PLACE ever commits it. Wave 17
			# (RR-116): a hover above the horizon leaves the ghost where it is.
			var hover := camera_state.ground_hit(motion.position, viewport_size)
			if bool(hover["hit"]):
				build_sheet.move_ghost(hover["position"])
```

**4 — the camera binding.** One insertion, immediately above
`save_service.ui_provider = root.capture_ui_state`:

```gdscript
	# Wave 17 (doc 12 §2.23 / D-68): the deck's one handle on the camera — the
	# tilt slider's axis, and the `camera` block of the `ui` save section. Bound
	# BEFORE the provider below, so the first save and the resume restore two
	# lines down both see it.
	root.bind_camera(camera_state)
```

**What needs no snippet, and why.** The gradient sky ships with no `main.gd`
change at all: `_build_environment()` already hands its `Environment` to
`EnvironmentController.setup()`, which is where the swap happens — so the sky is
live the moment this branch merges, while the slider and the save block wait for
number 4. The two-finger tilt likewise needs nothing: `TouchInput` already holds
the `CameraState` and reads the recogniser's new kinds. `set_tap_radius_from(
camera_state.m_per_dp(viewport_size))` is **deliberately untouched** — that
figure is pitch-invariant (§2.23 item 4), so §2.21's 48 dp radius keeps its
metres through a tilt with no change here. The coach-mark projector
(`_coach_world_rect` / `_coach_world_point`) is also correct as written: it
already returns `null` on `behind`, and a GROUND point never projects above the
horizon at any pitch, so the tilt cannot invent a mark that is not there.

### 43.5 What this cost, and the four digests

`profile_sim --hash-only`, both cities, at this branch's tip: starter coarse
`a27da24aaf6e9663…` / fine `7745cb25e55ff65c…`, bench coarse `7c99720f5ff14553…`
/ fine `d8e8889681b23297…` — **byte-identical to the fork**, which is what
separates "the shell learned to look up" from "the game changed".

### 43.6 Re-running every number in this section

A fresh worktree has no `.godot`, and **every** command below fails with a parse
error until the project has been imported once — the class-name cache is what
`class_name CameraState` resolves through:

```
~/.local/bin/godot --headless --import
```

Then, in order of what they prove:

```
~/.local/bin/godot --headless --script tools/profile_sim.gd -- --hash-only
~/.local/bin/godot --headless --script tools/profile_sim.gd -- --hash-only \
    --city=res://tests/fixtures/bench_city.json
~/.local/bin/godot --headless --script tests/run_tests.gd > suite.log 2>&1; echo $?
python3 tools/check_doc_refs.py
~/.local/bin/godot --path . tools/ui_preview.tscn -- --screen=all \
    --size=412x915 --audit --strict            # and 640x340, 794x924, 880x400, 1280x720
~/.local/bin/godot --path . tools/ui_preview.tscn -- --screen=all --size=360x800 \
    --text-scale=1.3 --large-targets --audit --strict
~/.local/bin/godot --path . -s res://tools/profile_frame.gd -- --tilt=12 --hour=13
~/.local/bin/godot --path . -s res://tools/profile_frame.gd -- --tilt=12 --hour=13 \
    --yaw=225 --focus=60,60 --poses=z2 --warmup=30 --frames=30 --shots=/tmp/edge
```

The last one is the world-edge picture RR-114 measures; the 17/255 figure is a
per-channel `max` over the seam rows of three columns of `/tmp/edge/z2.png`.
`--tilt=` accepts `auto` and any angle: the band clamps it per zoom and the table
row prints the angle that was actually rendered, which is why doc 92 §47's Z1 and
Z2 floor rows read 16.3° and 24.0° rather than 12°.

**Deviation, stated:** every code comment, data row and test in this lane names
**doc 12 §2.23**, not §2.22. §2.22 is claimed 47 times by the in-flight
construction-queue branch of the same wave (S16, the construction queue), and doc
91 §14.5's fifth collision is exactly this: two lanes, one free number. The tilt
slider took the next one.

---

## 44. WAVE 17 — POWER THAT WORKS AND POWER YOU CAN OPERATE (binding)

Five rulings from the doc 04 model audit (doc 93 §AD) and the player surface it
produced (doc 12 §2.9 D-70 / §2.7 D-71 / §2.10 D-72). Defects are doc 91 §14.5
`A91-D-53` … `A91-D-55`; the measurements are doc 92 §48.

### RR-118 — An event that has to survive a save is not a reason to grow state (docs 04 §4, 08 §2.8, 93 §AD5)

**Finding.** Doc 04 §4 authors `CapacityWarning` and `sim/power/power_grid.gd`
never emitted it, so a transformer's only pre-failure cue was the failure.

**The trap.** The obvious implementation is a per-component `already_warned`
latch. `PowerGrid.serialize` writes each component dictionary whole
(`duplicate(true)`), so a latch on the component rides the save automatically —
and **moves every `state_hash` in the project**, because the component
dictionary is what the hash is taken over. An authored event would have cost
four baselines and every downstream lane's re-measurement.

**Ruling.** *Derive the transition from state the save already carries.* The
previous tick's `load_kw` is in the section; sampling the band **before** pass A
overwrites it and comparing **after** gives exactly "did this component cross a
band during this tick", with no new field, no migration and no hash movement. A
restore compares against the same number the live sim compares against.
Hysteresis is a constant (`BAND_REARM_MARGIN = 0.03`), not a memory.

**Generalisation, binding on every doc.** Before adding a field to a serialized
structure for the sake of an edge-triggered event, check whether the level the
edge is taken on is already persisted. It usually is — this project stores
*state*, and an event is a *difference of state*.

**Re-open condition.** A band that must fire once per **game-day** rather than
once per crossing genuinely needs a timestamp, and that is a real field with a
real migration. Nothing asks for one today.

### RR-119 — A default that means "not modelled" must not be reachable by a modelled object (docs 04 §2.4, 93 §AD6)

**Finding.** `PowerGrid.is_powered` answers `true` for a building with no
service record — correct, and deliberate: the roster asks before boot has
attached anything, and doc 09's authored buildings must not read dark for the
half-tick between `add_component` and `attach_building`. But
`attach_building` opened **no record at all** when it found no transformer, so a
building that fell out of every service radius landed on that default and stayed
there: permanently lit, invisible to `unserved_building_ids`, uncounted by
`block_dark_fractions`, and — the reason it was found — un-adoptable by the very
transformer upgrade whose wider radius now reached it
(`CitySim._reattach_unserved` iterates service records).

**Ruling.** The record is opened either way. A building the grid has been ASKED
about is on the books; the `true` default now covers only ids the grid has never
been told about, which is what it was written for. The record opens `LIT` and
goes `DARK` through §2.4's ordinary hysteresis, exactly as a burnout's customers
do — no second outage path.

**Hash-neutral, and here is why:** on both authored cities every building is in
range at boot (`boot_errors` is empty) and `cmd_place_building` refuses
`E_UNSERVED` outside coverage, so no live path reached the defaulted state. All
four baselines are bit-identical.

**Generalisation.** A "we have not been told about this" default is fine. A
"we were told and had nothing to say" default is a silent branch. If a function
can distinguish the two, it must.

### RR-120 — A gate written against an instantaneous reading must name the hour (docs 01 §2.6, 02 §2.11, 04 §5.3, 93 §AD3/§AD4)

**Finding.** Every headroom gate — `cmd_upgrade_building`,
`cmd_upgrade_water_component`, and placement's coverage check — read
`load_kw`, the load at this instant. Doc 01's channels move that load by
**2.18× (residential) and 4.19× (commercial)** across a day. An upgrade approved
at 05:00 browns out at 20:00, and the player was told nothing about which hour
they had asked in.

**Ruling.** Doc 04 §5.3's ceiling is judged at the **peak**, per channel.
`CitySim.peak_component_loads()` scales each building's present demand by its own
channel's daily maximum over that channel's value now, walks the scaled demand
up the service path as `_pass_a` walks the live one, and hands the result to
`can_upgrade_power` as a `load_override`. Three properties make it safe:

1. **Clamped at 1.0 from below** — the gate can never be *more* permissive than
   the live reading, so no previously-refused upgrade becomes possible.
2. **Per channel, not per system** — a transformer serving houses peaks at
   20:00 and one serving shops at 10:00; one city-wide multiplier would
   understate the first and overstate the second.
3. **Read-only and memoised on `(game-minute, grid.mutation_epoch)`** — it is
   derived, saved nowhere, and cannot outlive the topology it was measured on.
   The placement ghost asks for it once a frame; the game-minute is the period
   doc 04 already banks service on.

`delta_kw` itself stays doc 02 §2.11's nameplate × 1.15. The margin is that
doc's own allowance for exactly this and re-scaling it too would double-count.

**Consequence, published:** blockers rise (starter 1 → 2, benchmark 140 → 400,
of which 86 now bind at a feeder where the live reading saw none). Those
refusals were always true; the game was reading them at the wrong hour. No
baseline moves, because no player command runs inside `profile_sim`'s identity
pass. Doc 92 §48.5 carries the `awaiting_consumer` note for the economy lane.

### RR-121 — A loop that samples one row of a set must not be described as summarising it (docs 04 §2.4, 93 §AD6)

**Finding.** `PowerGrid._shed_score` walked every attached building, and
`break`'d on the first one whose transformer hung off the feeder in question.
Its own comment said "one class sample per transformer GROUP is the MVP
granularity"; the code took one sample per **feeder**. A trunk carrying one
discretionary shop and two hundred houses was ranked by the shop, because `a_`
sorts before `z_`.

**Why it was survivable and still wrong.** `_feeder_has_critical` protects
critical feeders as a hard rule ABOVE this score, so nothing catastrophic came of
it — but the shed ORDER among ordinary feeders was reproducible and arbitrary,
which is the worst kind of deterministic: it looks like a decision.

**Ruling.** Sum the whole feeder, weighting each building by its transformer's
load divided among that transformer's customers. That is the "per-building
demand folded through the service record" the comment promised. **Hash-neutral
on both baselines** — neither city sheds in the identity pass.

**It moved one live expectation, and it moved it onto that test's own
sentence.** `tests/test_player_verbs.gd::test_priority_loads_survive_shedding`
asserted `["F_NORTH"]` under the caption *"with every load STANDARD the bigger
feeder sheds"*. Measured at 13:00 on the starter city under the test's own 40 kW
deficit: **F_SOUTH carries 430.0 kW and F_NORTH 382.6 kW**, so the bigger feeder
is F_SOUTH — and the old rank shed F_NORTH. The expectation was pinned to the
defect while the caption described the rule. The test now asserts `["F_SOUTH"]`
and promotes its CRITICAL load onto F_SOUTH, so the discriminating half — one
priority change moves the blackout to the other feeder — is preserved mirrored.
This is the third time this project has found a test whose PROSE was right and
whose NUMBER was the bug (A91-D-19, A91-D-33, A91-D-40); it is worth saying out
loud that the caption is the specification and the literal is the measurement.

**Generalisation.** A comment that describes a granularity is a claim, and a
claim in this project is testable. `tests/test_power_operations.gd::
test_f_the_shed_score_reads_the_whole_feeder_not_its_first_building` builds the
discriminating case: one DISCRETIONARY that sorts first, four CRITICALs behind
it, and an assertion that the mean has moved off the first row.

### RR-122 — Derived state rebuilt from BOOT data must be reconciled with the LIVE graph on restore (docs 04 §2.1, 08 §2.8, 10 §5.4, 93 §AD)

**Finding, and it broke determinism.** `CitySim._transformer_cover` is doc 10's
tile → transformer memo for signalled intersections. It is derived, not saved,
and refilled after a load from `_index_transformers()`, which reads
`loader.power` — **boot data, which lists every authored transformer whether or
not the city still has it**. Wave 17's `cmd_demolish_grid_component` makes the
two disagree: the live sim forgets the node, the restored one does not.
`is_energized` answers `false` for a missing id, so every intersection that
transformer covered read DARK in the restored city and LIT in the live one; doc
10 turns that into signal delay and congestion, and `save → load → advance`
stopped being bit-identical.

**Measured before the fix**, starter city, T-04 demolished, 0.5 h advance, then
6 h on both sides: live `state_hash` `54c9a6d2709bce2f…`, restored
`b6ca57575cc45b4b…`.

**Ruling.** `_sync_transformer_cover()` runs in `_restore_core` immediately
after `grid.deserialize` and drops every packed column whose id the GRID no
longer carries, then re-warms. The rule is the one the live sim already follows:
*a transformer the graph does not have is not in the memo.* A player-placed
transformer was never in it either, live or restored, which keeps the two halves
symmetric.

**Second ruling, recorded so it is not re-litigated.** A demolished
transformer's tiles go back to **uncovered**, and `_is_tile_powered` answers
`true` for an uncovered tile — most of the 112×112 map has no transformer over
it and doc 10 must not read every rural intersection as a dead signal. So the
intersection reads LIT after the demolition, exactly as it would have if no
transformer had ever stood there, and what the player sees is the BUILDINGS
going dark through the service ledger. **Re-open condition:** if doc 10 ever
wants "was covered and now is not" to mean dark, it needs a second set —
authored coverage versus live coverage — and that is a doc 10 change, not a
doc 04 one.

**Generalisation, binding.** Any memo refilled from `loader.*` after a restore
is refilled from a snapshot of the world at FOUNDING. The moment a verb can
delete one of the things that snapshot lists, the refill needs a reconciliation
pass. Grep for `loader.` inside restore paths before shipping a delete verb.

## 46. WAVE 17 — the refresh pin (binding)

The screen-tearing investigation (doc 11 §2.13's open band, doc 13 §2.8) got a
verdict from the player on 2026-09-01, after days of play on the Aug-21 build:
**"tearing only happens in the sub menus."** World play is clean.

That is a much narrower claim than the one the band has carried for three waves,
and it fits one thing in this tree better than anything else in it. Doc 93 §AE
has the analysis; this section has the rulings, what shipped, and the protocol
that decides whether the rulings were right.

### RR-126 — Declare the rate you cap at, in the same statement that caps it

**The finding.** `PerfGovernor.target_fps()` answers 60, 45 or 30, `game/main.gd`
writes it into `Engine.max_fps`, and **nothing has ever told the display**. Three
searches, each one line:

* `grep -rn "max_fps" game/ ui/` → `game/main.gd:1935` and `game/showcase.gd:138`
  (`= 0`, the screenshot harness). Two writes in the tree, one of them a tool.
* `grep -n "max_fps" project.godot` → nothing. There is no `run/max_fps`, so a
  fresh launch runs uncapped until the governor first steps — and the 2026-08-21
  Fold capture held `knob = 0` for its whole settled window at **99.5–112.4 fps**.
  The reference device has never once run this game at a declared rate.
* `git show HEAD:…/SlacumNative.kt | grep -c 'setFrameRate\|preferredRefreshRate\|preferredDisplayModeId'`
  → **0**.

`vsync_mode=1` is a property of the *swapchain*; Swappy (`swappy_mode=2`,
auto-fps) is a *consumer* of the refresh rate, not a declarer of it. So on the
reference device's **1856 × 2160 LTPO, 1–120 Hz adaptive** inner panel, the sole
input to the platform's mode policy was the app's observed present cadence.

**The ruling.** **A frame cap that is not declared is not a frame policy — it is a
side effect the platform reverse-engineers, and it re-derives that inference every
time the cadence changes.** Wherever the shell writes `Engine.max_fps` it also
declares the same number, through one idempotent object
(`game/render/refresh_pin.gd`) and one plugin method
(`SlacumNative.set_frame_rate`).

**The mode rule**, written once in `RefreshPin.choose_refresh_hz()`, table-tested
in `tests/test_refresh_pin.gd`, mirrored in Kotlin because it has to run against a
`Display.Mode` that only exists on a device:

| cap | panel | mode | clause |
|---|---|---|---|
| 60 | {60, 120} | **60** | smallest integer multiple |
| 30 | {60, 120} | **60** | smallest integer multiple |
| 120 | {60, 120} | **120** | smallest integer multiple |
| 45 | {60, 90, 120} | **90** | smallest integer multiple |
| 45 | {60, 120} | **120** | no multiple → fastest at or above |
| 90 | {60, 120} | **120** | no multiple → fastest at or above |
| 60 | {24, 30, 48} | **48** | nothing reaches it → the fastest there is |

**Smallest** multiple, not fastest: an integer multiple is what makes the cadence
exact — every app frame held for the same whole number of scanouts — and every
*extra* scanout beyond that is battery spent on a picture that did not change.
Doc 13 §2.8 calls capping at 60 on a 120 Hz panel "the single biggest battery
lever available"; pinning the panel to 120 for a 60 fps game hands it straight
back. Where no multiple exists the error is one scanout whatever is chosen, so the
faster mode halves it (±4.2 ms at 120 Hz against ±8.3 ms at 60) and wins.

**The cap and the declaration are ONE statement, and the order matters.**
Declaring a rate the app does not then present at would be worse than declaring
nothing — it asks the panel for a mode and then misses it. On this build the two
are self-consistent by construction: `vsync_mode=1` is FIFO, so a panel held at
60 Hz throttles the swapchain to 60 whether or not `Engine.max_fps` says so. But
that is a property of the *current* vsync setting and not of the design, so the
shell hook writes both numbers in one helper (`_apply_frame_cap(fps)` in the
branch report's snippet) and there is no path that writes one without the other.
The boot half of that helper is also the first time this project has ever applied
its own frame cap at launch — see A91-D-81's third search.

**And the declaration is conservative by construction.** The two-argument
`Surface.setFrameRate(fps, FRAME_RATE_COMPATIBILITY_FIXED_SOURCE)` means
`CHANGE_FRAME_RATE_ONLY_IF_SEAMLESS` on API 31+, so a mode switch the panel could
not make invisibly is **refused rather than made**; `preferredDisplayModeId` is
set only for a mode at the *current resolution*, because a mode that also changes
resolution is a reconfiguration and is the one kind that cannot be seamless. A
remedy for banding may not be a new source of banding.

### RR-127 — A frame-rate vote is cast on change, and re-cast on a new surface, and on nothing else

Two halves, and both are failure modes rather than tidiness.

**A vote is a request, so it is not per-frame.** `RefreshPin.pin(cap_fps)` is
idempotent: the same number twice reaches the platform once
(`test_the_same_rate_twice_casts_one_vote`). Re-declaring every frame would put a
request into the compositor's mode policy at 60–120 Hz, which is a fix for mode
hunting that hunts.

**A vote lives on the Surface and dies with it.** `Surface.setFrameRate` is a
property of the surface, not of the process: a surface that has been recreated has
no vote at all until one is cast again. On the reference device the surface is
recreated by **the Fold folding and unfolding**, and on every device by rotation
and by some resume paths — precisely the moments a player's session changes shape.
So `SlacumNative` caches the last rate GDScript asked for and re-casts it from
`onVkSurfaceCreated` / `onVkSurfaceChanged`, which is the only hook a
`GodotPlugin` is given that is handed the actual surface. **The shell must not do
this**: GDScript cannot see a surface recreation, and a shell that re-pinned "just
in case" would be back to per-frame.

The generalisation, which is what makes this binding: **when the platform owns an
object's lifetime and the app owns a property of it, the app re-applies the
property from the platform's own lifecycle callback — never from its own loop, and
never once at boot.** Doc 12 D-65 is the same rule for a solved layout, one layer
up: nothing owned re-running it.

### RR-128 — A device A/B's control arm is the shipped behaviour, in the same binary, or it is not a control

The pin is a **hypothesis with a test**, not a fix, and RR-126 is only worth what
§46's protocol below can say about it. That puts three requirements on the arms,
all of which are design decisions and none of which is obvious:

1. **`off` declares nothing at all rather than declaring zero.** Clearing a vote is
   itself a request to the compositor, and an arm that makes a request is not the
   behaviour that shipped. `RefreshPin.pin()` returns early on `off` before it
   computes anything (`test_off_casts_no_vote_at_all_rather_than_a_vote_of_zero`).
2. **Both arms come out of ONE install.** `--refresh=auto|60|90|120|off` rides doc
   13 D-20's argument path, so the two arms differ in an Intent extra and in
   nothing else — no rebuild, no reinstall, no second APK to confuse with the
   first. A control arm that is a *different binary* is a control for the change
   plus everything else that binary carries.
3. **The lever outranks the settings row.** A saved preference that could silently
   overturn an arm is not an arm (`test_the_lever_outranks_the_settings_row`), and
   this is the same precedence `main.gd`'s `_apply_render_ab_args()` already
   applies to the render levers.

**And the arm has to be provable from outside the app.** This project has already
lost one session to a **stale AAR**: an export packaged a plugin two days old,
`has_method("launch_args")` answered false, and every dev argument was dropped in
silence while the game looked perfect (RR-70, `.gitignore`'s own note). The
refresh pin has exactly that failure mode — a stale AAR makes `auto` and `off`
**the same arm** — so it is gated twice: `tools/run_matrix.sh step_build_check`
greps the installed dex for `set_frame_rate` beside `launch_args`, and
`tests/test_release_plumbing.gd` opens the tracked
`android/plugins/slacum_native.aar`, reads `SlacumNative.class` out of the
`classes.jar` inside it, and asserts **every `@UsedByGodot` method the Kotlin
declares** is in its constant pool. The pinned list is *derived from the source's
own annotations*, not hand-maintained, so the next plugin method is pinned by
being written; a second test asserts every `has_method("…")` probe in
`game/android_native.gd` names one of them, which is how a misspelt probe — false
on every device, indistinguishable from an old build — stops being invisible.

*(Proof that the gate has teeth: with the pre-Wave-17 AAR restored in place, the
suite reports `set_frame_rate`, `get_supported_refresh_rates` and
`current_frame_rate_pin` missing — three failures, then green again on the
rebuilt one.)*

### §46's shell hook — five anchors in `game/main.gd`, which this branch did not edit

`game/main.gd` is the lead's file, so the hook is delivered as anchored snippets
rather than applied. There are five, and the third is the one that matters: it is
the single door every `Engine.max_fps` write goes through, so the cap and the
declaration cannot come apart.

**1 — the field**, beside `var perf_governor: PerfGovernor` (`main.gd:57`):

```gdscript
var perf_governor: PerfGovernor
## doc 13 §2.8 / RR-126 — the rate is DECLARED, not merely capped.
var refresh_pin: RefreshPin
```

**2 — construction and the boot cap**, immediately after
`perf_governor = PerfGovernor.new(render_data, render_model.preset)`
(`main.gd:390`; `android_lifecycle` exists from `:127` and `main.gd:144` already
reads `.native`):

```gdscript
	perf_governor = PerfGovernor.new(render_data, render_model.preset)
	# RR-126. The lever is applied HERE because it outranks the settings row the
	# UI restores later (RR-128), and the cap is applied here because until this
	# line the game had never capped itself at boot at all (A91-D-81).
	refresh_pin = RefreshPin.new(render_data, android_lifecycle.native)
	refresh_pin.apply_lever(DevArgs.user_args())
	_apply_frame_cap(perf_governor.target_fps())
```

**3 — the one door**, a new function beside `_apply_render_ab_args()`
(`main.gd:487`):

```gdscript
## The frame cap and the frame-rate DECLARATION, which are one statement
## (report 98 RR-126). Every write of `Engine.max_fps` goes through here, so no
## path can cap without telling the panel: declaring a rate the app does not then
## present at asks the display for a mode and then misses it. `RefreshPin.pin()`
## is idempotent (RR-127), so calling this on every governor step costs one vote
## per CHANGE and none per frame.
func _apply_frame_cap(fps: int) -> void:
	Engine.max_fps = fps
	if refresh_pin != null:
		refresh_pin.pin(fps)
```

**4 — the governor step**, replacing `main.gd:1935`:

```gdscript
			Engine.max_fps = perf_governor.target_fps()          # doc 13 §2.8
```
becomes
```gdscript
			_apply_frame_cap(perf_governor.target_fps())         # doc 13 §2.8, RR-126
```

**5 — the two settings paths.** In `_wire_ui`, where the restored sheet is read
(`main.gd:954`, beside `_autosave_interval_s = …`):

```gdscript
		# D-75: the restored row, unless a --refresh= lever is holding the arm.
		if refresh_pin != null and perf_governor != null:
			refresh_pin.set_mode(
					str(root.settings_sheet.model.value("refresh_rate")), true)
			_apply_frame_cap(perf_governor.target_fps())
```

…and in `_on_ui_setting_changed` (`main.gd:1268`), one new arm beside `&"auto_quality"` (`:1297`), plus one line inside the existing `&"graphics"` arm:

```gdscript
		&"refresh_rate":
			if refresh_pin != null and perf_governor != null:
				refresh_pin.set_mode(str(model.value("refresh_rate")), true)
				_apply_frame_cap(perf_governor.target_fps())
```
```gdscript
			if perf_governor != null:
				# A player's preset choice clears the ladder and any latched drop.
				perf_governor.reset(str(model.value("graphics")))
				_apply_frame_cap(perf_governor.target_fps())   # NEW: the preset
				                                               # owns target_fps
```

**That last line is a defect fix in its own right.** `presets.performance.target_fps`
is **30** and `balanced`/`high` are **60**, and `PerfGovernor.reset()` re-reads
`target_fps` — so a player switching to Performance today does not get a 30 fps
cap until the governor next happens to step a knob, which on a device with
headroom is never. The preset row has been a quality control with no frame-rate
consequence since it shipped.

### §46's A/B — the protocol the lead runs on the phone

**One binary, one install, two Intent extras.** The perf-capture flag is disarmed
in BOTH arms, so the per-frame `viewport_set_measure_render_time` GPU timestamp
query — doc 91 §19's row-5 suspect — is absent from both and cannot explain a
difference between them.

**0. Build the thing that is being tested.** The AAR is a tracked binary and it is
not rebuilt by exporting:

```bash
tools/build_native_plugin.sh --debug
~/.local/bin/godot --headless --path "/home/bbx/Slacum City game" \
  --export-debug "Android" build/slacum-debug.apk
adb install -r build/slacum-debug.apk        # -r keeps the player's saves
adb shell run-as com.slacumcity.game rm -f files/perf_capture.flag
bash tools/run_matrix.sh build_check         # must print set_frame_rate in dex: 1
```

**1. Arm A — the control, and it is the shipped behaviour.**

```bash
adb logcat -c
adb shell "am start -n com.slacumcity.game/com.godot.game.GodotAppLauncher \
  --es args '--resume --refresh=off'"
```

**2. Arm B — the pin.** Same install, same save, one extra changed.

```bash
adb logcat -c
adb shell "am start -n com.slacumcity.game/com.godot.game.GodotAppLauncher \
  --es args '--resume --refresh=auto'"
```

**3. The content, identical in both arms — 30 s each, in this order.** These are
the four sheets the player names, and each is a full-screen UI layer over a world
that is not moving. **Do not touch the camera while a sheet is open**: camera
motion is the thing that hides the artifact, and it is the whole reason world play
reads clean.

| # | screen | how to get there |
|---|---|---|
| 1 | **Settings** (S9) | pause → SETTINGS |
| 2 | **Build sheet** (S3) | the FAB, bottom right |
| 3 | **Goals** (S8) | the goals chip, top bar |
| 4 | **Budget / Economy** (S6) | the treasury chip, top bar |

Open each, hold it for 30 s with the world still behind it, close it, and move on.
**The reading is the player's**: *did bands appear on this screen, yes or no, and
roughly how often.* Nothing on the workstation can see this artifact — it is a
scanout event and a screenshot is a framebuffer read.

**4. What to record, per arm.** Three machine readings and one human one.

```bash
# what the app ASKED the window manager for (0 / 0.0 in arm A, non-zero in arm B)
adb shell dumpsys window | grep -iE 'preferredDisplayModeId|preferredRefreshRate' | head

# what the PLUGIN says it declared, and which mode it picked
adb logcat -d -s SlacumNative | grep -i 'refresh pin'

# what the PANEL is actually doing, taken while a sheet is open
adb shell dumpsys display | grep -iE 'DesiredDisplayModeSpecs|mActiveModeId|fps ' | head

# and the frame record for the same window
adb shell dumpsys gfxinfo com.slacumcity.game framestats | head -40
```

**5. How to read the result, decided in advance.**

* **Bands in arm A, none in arm B** → RR-126 is confirmed on the reference device.
  Doc 11 §2.13's open band closes, `off` stays as a settings row and a lever, and
  doc 91's row-5 A/B is retired as superseded.
* **Bands in both, at the same rate** → **RR-126 is refuted as a remedy** and doc
  93 §AE says so first. The declaration keeps its battery and pacing arguments and
  loses its tearing argument; the band stays open and the next suspect is the
  compositor's handling of a full-screen layer over the `SurfaceView`, which needs
  a different instrument. Write that down rather than leaving the pin to imply a
  fix it did not make.
* **Bands in both but rarer in arm B** → partial. Re-run arm B as
  `--refresh=120` (declare the panel's top mode outright) before concluding
  anything: that separates *"the mode is being held"* from *"the mode being held
  is the right one"*.
* **`preferredDisplayModeId` reads 0 in arm B** → the arm did not run. Check
  `set_frame_rate in dex` from step 0 and the `SlacumNative` log line, in that
  order; a stale AAR makes both arms `off` and the session measures nothing. If
  the dex has the symbol and the log line is still absent, the third possibility
  is that Godot refused to REGISTER the method — `set_frame_rate(double, boolean)`
  is the first `double` parameter this plugin has ever exposed — and
  `current_frame_rate_pin()` is the readback that separates the two, because its
  own signature carries no `double`.

**Applied at this branch:** new `game/render/refresh_pin.gd`,
`tests/test_refresh_pin.gd`; `SlacumNative.kt` (`set_frame_rate`,
`get_supported_refresh_rates`, `current_frame_rate_pin`, the two Vulkan surface
callbacks) and the rebuilt, committed `android/plugins/slacum_native.aar`;
`game/android_native.gd`; `data/render.json.refresh`; `data/ui.json`'s
`refresh_rate` row + `defaults` + `device_scoped_keys`, `ui/settings_model.gd`'s
`refresh_modes` source, four `data/strings.en.json` values and two labels;
`tests/test_release_plumbing.gd` (the AAR gate), `tests/test_ui_settings.gd`,
`tests/test_android_native.gd`; `tools/run_matrix.sh step_build_check`;
`tools/check_doc_refs.py` (A91-D-82); docs 11 §2.13, 12 D-75, 13 §2.8, 91 §14.5
(A91-D-81, A91-D-82), 93 §AE and this section. **`game/main.gd` is untouched** —
the shell hook is delivered as an anchored snippet in the branch report, because
that file is the lead's.

## 47. WAVE 17 — the first complete device matrix (binding)

*`tools/run_matrix.sh` ran end to end for the first time on 2026-09-01: an
unlocked, connected Galaxy Z Fold 6 (SM-F956U, Android 16, inner panel), the
Wave-15 build (`versionName` 0.4.0, installed 2026-08-21), the player's live
city, `--preset=balanced` pinned in sections 2-4, `MATRIX EXIT: 0`. Fourteen
captures, 25 `PERF` samples each, fifteen `PERFIO kind=load` rows and one
`kind=save`, one screenshot, one `meminfo`, one thermal dump — all committed under `tools/device_results/`, with
`run_matrix_2026-09-01.log` as the session log. The full write-up and the
re-taken Fold table are **doc 11 §2.13, "The 2026-09-01 session"**; the three
rulings the deltas support are here, and so are the two defects the matrix found
by accident, which are the more expensive half of the day.*

**Three A/Bs were asked and three rulings come out, but not the three that were
expected.** The zebra A/B rules cleanly. The flood A/B rules cleanly. The pad
A/B does not rule at all, and the reason it does not is a *third* measurement
nobody went looking for: **a ~2.5 ms two-state in `gpu_est` that the hour does
not fully control**, sitting underneath every arm in the session. It is named in
each ruling below rather than averaged into any of them.

### RR-129 — The asphalt fragment ladder is FREE on Adreno 750, at BOTH hours; the `rd0_h21` capture that looks like a result is a pose change

**Ruling.** `road_detail` 2 versus 0 is **below the noise floor on device at
both hours**, and it is below it in the direction that makes the ladder
pointless: the *cheaper* arm is the *slower* one in both matched pairs, by the
same 0.3–0.4 ms, which is the run-order drift between two captures a minute
apart and not a shader. `presets.balanced.road_detail = 2` and
`presets.high.road_detail = 2` stand. **RR-42's note — "if rung 2 and rung 0 are
within each other's spread on device, the ladder is pointless" — is answered
YES for this part**, and the ladder survives only as `presets.performance`'s
tier-C ceiling, which is a different part and is still unmeasured (doc 91 §20.4
device item 4).

| pair | arm | fps | p95 ms | cpu ms | gpu ms | dc | Δ gpu (rd0 − rd2) |
|---|---|---|---|---|---|---|---|
| day, whole hold | `rd2_h13` | 69.7 | 18.0 | 0.50 | **8.5** | 100 | — |
| day, whole hold | `rd0_h13` | 69.4 | 18.3 | 0.50 | **8.9** | 100 | **+0.4** |
| night, `t = 4–12 s` (matched) | `rd2_h21` | 70.9 | 16.7 | — | **8.5** | 93 | — |
| night, `t = 4–12 s` (matched) | `rd0_h21` | 71.1 | 16.7 | — | **8.9** | 93 | **+0.4** |

*(The day rows are `tools/perf_rows.py`'s own medians over `t ≥ 12 s`, `n = 20`.
The night rows are medians over the five samples `t = 4, 6, 8, 10, 12 s`, which
is the window in which the two night arms are at the same pose — see below. The
arms' own spreads over those windows are `gpu_est` 8.4–9.6 and 8.4–10.1, so a
0.4 ms delta is inside both.)*

**The arms rendered the same geometry, and that is checked rather than
assumed.** The ladder is a fragment branch (§2.1.2), so identical `dc`/`prim`
between the arms is the expected result and confirms both arms drew the same
city:

    cd tools/device_results
    md5sum <(grep -ao 'dc=.* lights=[0-9]*' log_rd0_h13.txt) \
           <(grep -ao 'dc=.* lights=[0-9]*' log_rd2_h13.txt)
    # cc761e3e782311b8db9b578f109b2417  — both

**And the rung-2 arm was really rung 2.** `set_detail` clamps to the preset's
ceiling, so a phone that auto-detected `performance` would have measured rung 1
against rung 1 and reported "free" for the wrong reason —
`tools/run_matrix.sh:186` pins `--preset=balanced` for exactly that reason, and
every `PERF` line in all four captures reads `preset=balanced`.

#### The `rd0_h21` headline row is NOT a `road_detail` result, and here is what it is

`tools/perf_rows.py` prints `rd0_h21` as **58.0 fps / p95 21.3 / gpu 11.1 /
dc 130/130 / prim 54,551 / near 0 / knob [0, 1, 2]**, which reads like the one
place in the session where the ladder mattered. It is not. Read the capture:

    grep -a 'PERF t=' tools/device_results/log_rd0_h21.txt

* **The step is a single sample wide and it is a POSE change.** At `t = 12.0 s`
  the capture is `dc=90 prim=45,820 near=6`. At `t = 14.0 s` it is
  `dc=122 prim=53,666 **near=0**`, and at `t = 16.1 s` `dc=130 prim=53,954
  near=0`, where it stays for the remaining eighteen samples. `near` is the
  chunk-tier census (`RenderStateModel.tier_census()`, chunks within
  `near_max_m = 150 m` of `camera_rig.camera.global_position`), so `near: 6 → 0`
  with `chunks` constant at 9 is the camera moving, and nothing else in the file
  moves at that sample. **What raised `dc` from ~100 to 130 is +8,000 primitives
  arriving in the frustum, not a detail level.**
* **It is not the detail level, and the control that proves it is in the same
  session.** `rd0_h13` carries the *identical* `--road-detail=0` and holds
  `near=4 / dc≈100 / prim≈47.8k` for all 25 samples; `rd2_h21` holds the same at
  the same hour. **`rd0_h21` is the only capture of the fourteen whose census
  moves mid-hold.**
* **It is not the junction pose either — there is no junction pose.** Section 3
  of the harness is *named* "road_detail A/B at a junction pose" and launches
  `--zoom=0.0` and nothing else; no argument in the session selects a junction,
  and `--zoom` did not move the camera in any capture (A91-D-84). Whatever moved
  it at `t = 14 s` was not the harness.
* **The knobs, and heat had nothing to do with them.** `knob = 0` through
  `t = 36.1 s`, `1` at `t = 38.2–40.2 s`, `2` from `t = 42.2 s` to the last
  sample — **two down-steps, 24 s after the `dc` rise, at `thermal = 0` for the
  entire capture.** The trigger is §2.13's own rule (`p95 > budget × 1.25`
  sustained 5 s): balanced's 60 fps target is a 16.67 ms budget, ×1.25 = 20.83 ms,
  and `p95` ran 18.1–26.9 ms from `t = 22 s` onward, **above that line in 11
  of those 15 samples**. Rungs 1 and 2 are
  `render_scale −0.05` and particle `amount_ratio ×0.60`; **rung 3 (`far_cull
  −128 m`) was never reached, which is why `dc` stayed at 130 rather than
  falling.**
* **They did not recover, and could not have.** The up-step needs
  `p95 < budget × 0.80 = 13.3 ms` sustained **30 s**; `p95` never went below
  18.1 ms after `t = 14 s`, and the capture ends 8 s after the second step. A
  50 s hold cannot observe a recovery even if one were due.
* **And the two steps bought nothing measurable.** Median fps at `knob = 0`
  after the pose change (`t = 16–36 s`) is **58.8**; at `knob = 2`
  (`t = 42–50 s`) it is **53.3**. The governor stepped twice and the frame rate
  went *down* 5.5 fps. Four samples is a short window and this is reported as an
  observation rather than a ruling — but it is the first time the ladder has
  been watched running on hardware, and what it shows is two rungs spent on a
  frame whose cost is submission-side (`dc` 130) against two knobs that are
  pixel-side. **Filed as the first device evidence that the ladder's ORDER may
  be wrong for this frame**; the workstation ladder table (§2.13, "The
  performance ladder — four named levers, measured") ranked the rungs on a frame
  that was fragment-bound, and this one is not.

### RR-130 — `flood_detail` rung 2 is FREE on device; it stays 2, and standing water has finally been photographed

**Ruling.** `presets.balanced.flood_detail = 2` and
`presets.high.flood_detail = 2` stand. Rung 2 versus rung 0 is **identical to
0.0 ms of median GPU** on the Fold at a night flood pose, and the two arms
disagree about `fps` and `p95` in *opposite* directions, which is the signature
of noise rather than of a cost:

| arm | fps | p95 ms | cpu ms | gpu ms | dc | prim | near |
|---|---|---|---|---|---|---|---|
| `flood2` (`--flood=350 --flood-detail=2`) | 67.5 | **17.2** | 0.40 | **8.8** | 101 | 45,889 | **7** |
| `flood0` (`--flood=350 --flood-detail=0`) | 69.1 | **17.6** | 0.55 | **8.8** | 100 | 47,783 | **4** |

**Stated rather than buried: these two arms are not census-matched.** `flood2`
runs at `near = 7 / prim = 45,889` from its very first sample and `flood0` at
`near = 4 / prim = 47,783` from its first — a difference present at `t = 2.0 s`,
so it is a starting-camera difference and not something the flood did. This is
therefore *two nearby poses that cost the same* rather than *one pose measured
twice*, and it is weaker evidence than the zebra pair. It is still enough to
rule, because the rung's entire claim is a per-pixel one and the arm carrying
the rung is not more expensive at either pose. **`near = 7` also exceeds
`presets.balanced.near_chunk_max = 6`**, which is a separate thread and is filed
in doc 11 §2.13 rather than ruled here.

**The screenshot exists.** `tools/device_results/flood_night.png`, 2,618,648
bytes, taken through `cap_pose.sh --snap` (which resolves the display — a bare
`screencap` on this two-display phone writes a warning ahead of the PNG bytes
and produces a file that is not an image; the 2026-08-21 session found that and
doc 11 §2.13 carries it). It is the first device look at doc 07 §2.4's standing
water and the
first artefact of any kind from the flood layer on hardware.

### RR-131 — The pad-shadow A/B produced NO usable pair; RR-33 stands unrevisited, and the re-run is a command rather than a wish

**Ruling.** **RR-33 is unchanged and `power_infra.pad_shadows = true` stays
shipped.** The 2026-09-01 pads pair is *not* evidence for it and *not* evidence
against it, and is recorded as an unusable pair rather than as a number. Three
independent reasons, in ascending order of how badly each one hurts:

1. **The harness stamped one arm.** `cap_pose.sh` asserts foreground before and
   after each hold and wrote `CONTAMINATED fg_before=0 fg_after=1` into
   `log_pads0.txt` (`tools/cap_pose.sh:153`). Unlike the 2026-08-21 case, the
   ordering argument does **not** rescue it: that capture's `PERF` lines stop
   when the surface is lost, and `log_pads0.txt` emits all 25 samples across the
   full 50 s, so the loss is not cleanly outside the sampled window.
2. **The pair straddles a thermal boundary.** `thermal` rises `0 → 1` *inside*
   `log_pads1.txt` at `t = 14.1 s` and is `1` for the whole of `log_pads0.txt`.
   The pair is the only one in the session that is not taken at one thermal
   status.
3. **And the reason that actually disqualifies it: the "no-op" arm cost
   2.5 ms.** `--pad-shadows=1` sets the value the build already boots with —
   `data/render.json:184` is `"pad_shadows": true`, `power_infra_view.gd:279`
   builds `_pad_node` with `SHADOW_CASTING_SETTING_ON`, and `:131` re-applies
   the authored value at setup — yet `pads1` reads **`gpu_est` 8.6 ms** against
   the three no-lever daylight captures' **6.1 ms**, and `pads0` (the arm that
   *changes* something) reads **6.5 ms**. An arm that sets a flag to the value it
   already has cannot cost 2.5 ms, so **something other than pad shadows is
   moving `gpu_est` by 2.5 ms in this session** and it is inside the pads pair.
   Until that is explained neither arm is a pad-shadow measurement. It is the
   same two-state named in the section preamble and written up in doc 11 §2.13.

**RR-33's own re-open gate is unmet for the second session running, and by a
wider margin than the first.** RR-33 made itself revisitable only by *"a daylight
Z0/Z1 Fold pose within 5 % of the draw-call budget"*. The 2026-09-01 session
measured **`dc` 100 against balanced's `draw_call_budget` 320 — 69 % headroom**,
against 41–56 % on 2026-08-20. The frame is nowhere near submission-bound at any
pose the harness can reach, so the condition RR-33 wrote for its own revision has
now failed twice and by a growing margin. **RR-33 is confirmed on its own terms
and untouched by this session's numbers.**

**The re-run, exact, so the next window starts at the measurement.** The fault in
the 2026-09-01 attempt is that the two arms ran once each, in sequence, across a
thermal step; the fix is interleaving, which is the convention every workstation
A/B in doc 11 already uses:

    adb shell run-as com.slacumcity.game rm -f files/perf_capture.flag
    bash tools/run_matrix.sh build_check
    for r in 1 2 3 4; do
      bash tools/cap_pose.sh "pads1_r$r" \
        "--resume --zoom=0.0 --preset=balanced --pad-shadows=1 --perf" 40 13
      bash tools/cap_pose.sh "pads0_r$r" \
        "--resume --zoom=0.0 --preset=balanced --pad-shadows=0 --perf" 40 13
    done
    python3 tools/perf_rows.py tools/device_results/log_pads[01]_r*.txt

Three things this adds to what ran on 2026-09-01, each of which one of the three
reasons above demands: `--preset=balanced` is **pinned** (the 2026-09-01 pads
captures did not pin it — they read `preset=balanced` by auto-detection, which is
luck, not control); the arms are **round-paired** so a thermal step lands on both
arms rather than between them; and **four rounds** give each arm a spread to be
compared against instead of one number. Take it as the FIRST section of a window,
not the last — `pads1`/`pads0` were captures 13 and 14 of 14 on 2026-09-01, at
`AP 47.4 °C`.

### The two defects the matrix found by accident, and why they cost more than the three A/Bs

Both are filed in doc 91 §14.5; both are `game/`'s and neither is fixed here.

* **`A91-D-83` — doc 13 §2.8's frame cap is only applied when the governor
  changes something.** `game/main.gd:1935` writes `Engine.max_fps =
  perf_governor.target_fps()` **inside** `if perf_governor.update(delta):`, so a
  device that never trips a rung never gets a cap and runs at whatever the panel
  offers. Measured: **106.5–109.2 fps at the three daylight poses**, on a phone
  whose active preset asks for 60. Doc 13 §2.8 calls capping at 60 on a 120 Hz
  panel *"the single biggest battery lever available (roughly halves GPU work)"*,
  and it has never been pulled on this device. **It also distorts this session's
  own headline**: the day→night `gpu_est` delta of +2.60 ms costs **38.5 fps**
  only because the frame is free-running against a 8.33 ms vsync interval that
  6.03 ms clears and 8.63 ms misses. Capped at 60 the same 2.60 ms would have
  been invisible in `fps` and visible only in `gpu_est`, which is the number that
  matters for heat and battery.
* **`A91-D-84` — `--zoom` is delivered, parsed, and does not move the camera.**
  The plugin logs the argument (`SlacumNative: launch args: [--resume,
  --zoom=1.0, --perf]`) and `game/main.gd:218` parses it, and the three zoom
  values produce **byte-identical** `dc`/`prim`/`vram`/`chunks`/`near`/`inst`
  columns across 25 samples — **one `md5`
  (`cc761e3e782311b8db9b578f109b2417`) shared by eleven of the fourteen
  captures**, day rows and night rows and both zebra day arms and both pads arms
  alike. `near` is `tools/run_matrix.sh:152`'s own stated discriminator
  for whether the poses separated (*"2026-08-20 got `near=4` at every 'zoom'
  because no argument landed"*), and it reads **4 in every capture again**. The
  2026-08-20 conclusion — *the pose matrix is still open* — therefore survives the
  session that was meant to close it, for a **different** reason: the argument
  now arrives and the camera still does not move.

**What this means for doc 91 §20.4 device item 2, stated plainly and against the
instruction this lane was given.** The day/night half of the pose matrix
**closes** — six captures, two hours, one pinned preset, an unambiguous +2.60 ms
and a re-taken table. The three-**pose** half does **not**: the session produced
one pose three times, and A91-D-84 is why. The row is split rather than ticked.

**Applied:** doc 11 §2.13 (the re-taken Fold table, "The 2026-09-01 session");
doc 13 §2.9.1 (the ANR budget lines, re-derived against the measured load and
save); doc 91 §14.5 (`A91-D-83`, `A91-D-84`) and §20.4 (device items 2, 3 and 5,
and the completion statement); doc 93 §AF; and
`tools/device_results/README.md`.

---

## 38. WAVE 17 — the preset that did nothing, the linear meshes, the building shadow and the far line (binding)

*Render/art lane, forked off the Wave-17 integration (`a5d9021`), 2026-09-02.
**Hash-neutral throughout**, proved on both cities at the fork and again at the
end: nothing in this lane touches `sim/`, and its only `data/` edit is
`data/render.json`, which no file under `sim/` opens.*

*Two earlier attempts at this task died mid-build on the weekly usage limit,
each leaving an unverified diff and neither having run the suite. **This
section is the third, and its first commit was the second attempt's diff
re-based onto the fork — after which every number in it was re-taken.** Six of
the inherited claims turned out to be wrong; each is corrected in place, with
what it said, what it is, and how the error was found. Those six are the most
useful paragraphs here, because five of them are the SAME MISTAKE — a claim
about a consumer made from reading rather than from grepping — which is
`A91-D-19`'s shape for the fourth wave running.*

| `profile_sim --hash-only` | at the fork | after this pass |
|---|---|---|
| starter, coarse 24 h | `a27da24aaf6e9663…` | **`a27da24aaf6e9663…`** |
| starter, fine 2.0 h | `7745cb25e55ff65c…` | **`7745cb25e55ff65c…`** |
| bench, coarse 24 h | `7c99720f5ff14553…` | **`7c99720f5ff14553…`** |
| bench, fine 2.0 h | `d8e8889681b23297…` | **`d8e8889681b23297…`** |

### RR-95 — a vertex colour takes no decode either, and the file that gets missed is the one nobody greps for (closes `A91-D-36`; docs 11 §2.12/§2.16/§2.17, 91, 93 §X1)

**RR-91 closed the INSTANCE half of `A91-D-36`** — a `MultiMesh` instance
colour is handed to the shader as LINEAR and nothing on that path decoded it,
so every authored livery rendered about two stops light — and left the VERTEX
half open with an `awaiting_consumer` naming three files. A vertex `COLOR` is
the same: no decode, no `source_color` hint, no engine help.

**The seam is at the WRITE, never at the constant**, and the reason is
`ConstructionRigMesh`'s dual-use trio. `SAND`, `GRAVEL` and `REBAR` are read
both as vertex colours here and as MultiMesh instance TINTS by
`ConstructionActivity._stock_linear`, which already applies `srgb_to_linear()`
once at `_init`. Decoding the constant would decode them **twice** on that path
— gravel at linear 0.049 instead of 0.223, i.e. black — while fixing nothing
the mesh half needed. One authored source of truth, one decode per consumer.

**Two hexes of twenty moved, and both had to.** `DARK` `#1D2022` → `#424548`
and `TYRE` `#161618` → `#333336`, in both mesh files. Decoded from their
authored values they land at linear **0.0125** and **0.0069** against a shaded
carriageway near **0.02**: an excavator's track band stopped being an object
standing on the road and became a hole cut in it, and a tyre went blacker than
fresh asphalt, taking its tread ribs with it. The other eighteen survive — the
fix is a darkening, and a darkening is what it is for.

**THE FIFTH BUILDER, and the correction that matters most in this entry.** The
inherited note recorded `CobraHeadMesh` as *"checked and deliberately left,
whose vertex colour is a grime ramp and whose colour is `albedo_color`"*.
**Both halves of that are wrong.** The ramp MULTIPLIES two authored tints
(`COWL_TINT`, `LENS_TINT`), and those tints reach the shader through
`ARRAY_COLOR` and not through `albedo_color`. It is fixed, and the ruling is a
SPLIT worth stating on its own:

> **The authored TINT is decoded; the GRIME RAMP is not.** A ramp is a
> reflectance multiplier — soot on a mast — and belongs in linear, where
> halving it means half the light. Decoding the product instead would put the
> ramp through a 2.4 power and take the foot of the mast from linear 0.41 to
> 0.18, which is not grime, it is night.

Neither cobra constant moved: both are near-white, `0.90` decodes to `0.787`,
and white is a fixed point of the decode. That is exactly the difference
between this file and `DARK`/`TYRE`, and it is why "convert everything and
re-judge everything" would have been the wrong instruction.

**AND THE GUARD IS NOW A CENSUS RATHER THAN A LIST.**
`test_every_procedural_mesh_decodes_its_authored_vertex_colour` walks
`game/render/`, takes every file containing `Mesh.ARRAY_COLOR`, and requires
`srgb_to_linear` in each — five files found, five checked. **A hand-kept list
of builders is what missed the fifth one twice.** `grep -rln "ARRAY_COLOR"
game/render/` was always the audit answer this row was owed; it is a test now.

**The re-judge, measured rather than described** (`profile_frame --preset=high
--hour=13 --focus=52,44 --poses=z0 --sites=3 --street-life=8 --traffic=14
--units=2 --shots`, bench city, 1920 × 1080, before/after with nothing else
changed):

| | |
|---|---|
| frame moved > 2/255 | 28,282 px, **1.36 %** |
| frame moved > 32/255 | 12,514 px, 0.60 %; peak **87/255** |
| mean luma over the moved pixels | **151.1 → 99.3** |
| whole-frame mean luma | 94.59 → 94.15 — *targeted, not a global dimming* |
| **pixels below 20/255 luma** | **1,956 before, 1,956 after** |
| pixels below 12/255 luma | **0 before, 0 after** |

**The near-black count is the number that matters**: the re-judged `DARK` and
`TYRE` are what bought it, and an unchanged near-black population is what "no
part became a hole in the road" means as evidence rather than as an opinion.
The picture that carries the art call is the construction site's cabin — a
washed-out mint before, a saturated sage after, with the white barricade tops
unmoved.

### RR-96 — the layer §2.11 has been owed since the preset table was written, and the price of a per-chunk cost multiplied by a modelled chunk count (docs 11 §2.11/§2.13, 91, 93 §X2)

`presets.performance.shadows` is `false` and `blob_shadow.enabled_presets` has
named `["performance"]` since the preset table existed, and nothing drew it —
so the cheapest preset shipped with **every block in the city floating**.
`MM_blob` is that layer.

**ONE draw call city-wide, not one per NEAR/MEDIUM chunk.** §2.11 priced the
per-chunk shape; built and measured, Performance's census on the bench city at
`--focus=52,44` is **10 NEAR + 26 MEDIUM at Z0**, not the worked example's
3 + 3, so per-chunk cost **36 calls at Z0** against a budget the city was
already over. **A per-chunk cost multiplied by a chunk count taken from the
model rather than from the census is the failure mode; the census is the
number.**

**Measured** (bench city, performance, hour 13, `--focus=52,44`, `--blob=0`
vs `--blob=1`, nothing else different):

| pose | dc, off → on | prims, off → on | `rs gpu`, off → on |
|---|---|---|---|
| Z0 | **89 → 90** | 89,822 → 92,822 | 0.585 → 0.586 ms |
| Z1 | **123 → 124** | 95,494 → 98,494 | 0.741 → 0.742 ms |
| Z2 | **196 → 197** | 261,464 → 264,464 | 0.837 → 0.843 ms |

**+1 draw call and +3,000 primitives at every pose** = 1,500 buildings × 2
triangles: a function of the ROSTER, not of the camera, which is what makes
scrubbing across a tier boundary free. Balanced and High are unchanged —
`blob_draw_calls()` is 0 at every pose on both.

*Corrected from the inherited draft: its table read `229 → 230 / 225 → 226 /
188 → 189`. Those were measured before RR-98 wired `shadows: false`, so
Performance was still paying a shadow pass it had authored itself out of. The
`0 → 1` delta is the same either way; the base is not.*

*Also corrected: `rs gpu` is REPORTED, not claimed. The same configuration
measured 0.837 and 1.228 ms at Z2 in two runs an hour apart on a workstation
carrying sibling suites, so a ±0.4 ms run-to-run band swamps a 0.006 ms effect.
That number belongs to a Fold session.*

**Alpha 0.35 verified twice, and screen deltas alone could not have done it**,
because AgX sits between the blend and the pixel. Linearising both frames and
taking the ratio over the decal gives **p5 = 0.630 / 0.574 / 0.653** at
Z0 / Z1 / Z2 against the **0.650** that `blend_mix` toward black at α = 0.35
predicts. The deeper p1 tail (0.457 / 0.423 / 0.521) is where two neighbouring
decals OVERLAP — and **0.65² = 0.42** is exactly where that tail sits, which is
a second, independent check on the same number.

**Path decided, and it is a dedicated MultiMesh under RR-83 rather than a mode
on the street FX buffer.** Three reasons, in the order that decides them: the
fx buffer is rewritten every frame for objects that WALK while a building decal
moves only when a building does; the fx shader's one unconditional
`texture(glyph_page, …)` fetch is right for five of its six modes and would be
paid by every fragment of every building decal on the lowest tier for nothing;
and the two layers have two different gates (`enabled_presets` against
`vehicle_shadows` INVERTED) that a shared shader would hide rather than merge.

**The live preset swap and the governor's latched drop both need no shell
call**: `_sync_blob_preset()` runs inside `_upload_all` and re-derives the gate
from `RenderStateModel.preset`, which is the one object both paths write.

### RR-97 — the lever with authority is not always the lever with the ruling, and an arm has to be checked at a pose that contains the thing (docs 11 §2.1.2/§2.17b, 93 §X3/§X4)

§2.17b's street-body blob is near-invisible on the carriageway and `body_alpha`
is not the cause: a `blend_mix` decal darkens what is behind it by a FRACTION,
so the same disc is a 15/255 mark on the carriageway and a 40/255 mark on the
footway. The lever with authority is the road — and the road is every street in
the city on a phone screen. So this lane ships `RoadSurfaceView.set_tint_gain(k)`
(live, one uniform, byte-identical at `k = 1.0`), both commands, and **moves
nothing**.

**THE ARM HAD TO BE CHECKED, AND IT FAILED ITS FIRST CHECK.** The
re-measurement began at Z0, `--focus=52,44`, and moved **zero pixels at
`k = 4.0`** — three shots at `k` = 1.0, 1.5 and 4.0 byte-identical by `md5sum`.
The arm was not broken: **that pose has no carriageway in it.** A null result
from a frame containing none of the thing under test is indistinguishable from
a null result from a lever with no authority, and this section's own binding is
that an arm must be checked for authority before its result is believed. What
caught it was making the harness print the uniform **read back off the live
`ShaderMaterial`** (`RoadSurfaceView.live_tint_color()`) beside the value the
arithmetic wanted — the same "read back off the live object" rule RR-98's
`QUALITY` line follows.

**Re-measured on a road-bearing pose** (bench city, High, `--focus=52,44`,
`k = 1.0` vs `1.5`, i.e. `(0.3412, 0.3412, 0.3725)` → `(0.4141, 0.4141,
0.4512)`, a +21.4 % lift of the authored triple):

| pose / hour | carriageway in frame | rendered luma | peak |
|---|---|---|---|
| Z1, 13 | 19.2 % | 72.84 → 75.07, **+3.1 %** | 8/255 |
| Z2, 13 | 7.7 % | 107.78 → 109.04, **+1.2 %** | 5/255 |
| Z1, 21 | 1.8 % | 38.83 → 40.22, **+3.6 %** | 5/255 |
| Z2, 21 | 1.2 % | 36.46 → 37.37, **+2.5 %** | 6/255 |

**Two inherited claims corrected.** (1) **There is no day/night asymmetry.**
The draft said the tint moves the road 17 % by day and "buys nothing at all" at
night, on the theory that after dark the road's value belongs to
`road_night_albedo_lift` and `road_night_glow` in a different block. At Z1 the
night arm moves it **more** than the day arm. The theory was reasonable and it
is not what the frames do. (2) **The lever has far less authority than "the
lever with authority" implies.** The response is near-linear and was measured,
not extrapolated (`k` 1.0 → 3.0 gives 73.55 → 81.96 luma at Z1 by day,
**+4.21 luma per unit of `k`**, against +4.46 from the 1.0 → 1.5 arm), so
moving the road the ~15/255 the blob needs takes **`k ≈ 4.6`** — an authored
tint near `(0.68, 0.68, 0.73)`. **That is not a tint adjustment, it is a
different, pale-grey road**, which makes the case for leaving the ruling to a
device session stronger than the draft made it.

**§V1's re-open condition is restated and the restatement was re-checked**
(doc 93 §X4): the trigger was *"telemetry showing players farm-ignoring crooks
at scale"* and **this project has no analytics path at all** — the crash
sentinel writes a local file and sends nothing, and no `INTERNET` permission is
requested. It now names two instruments that exist on the day it is written: a
play session in which a tester says the offers became **wallpaper**, and a
`tools/run_matrix.sh` row in which the tapping agent's `street_share_of_net`
collapses. The second is **a column that already prints** —
`tools/playtest.gd:3000-3007` computes `opportunities_collected`,
`street_income`, `street_missed` and `street_share_of_net` per run — verified
by reading those lines, not by trusting the citation.

### RR-98 — an authored number nothing reads is not a setting, it is a comment; and the FAR tier was grey because a colour space was applied twice (docs 11 §2.5b/§2.6b/§2.13b, 12 D-74/D-74b, 91, 93 §X5)

**Twenty-two keys** in every preset row of `data/render.json` reached no engine
call. The count is `grep -rn '"<key>"' --include=*.gd game/ ui/` against the
fork tree, and it **corrects the "thirteen" the inherited draft published**:
that list omitted `shadows`, `glow_blend`, `civ_headlights` and the six deleted
rows. Twenty-one of the twenty-two appear nowhere in `game/` or `ui/` in any
form — unreachable, not merely unread. The twenty-second, `render_scale`,
appears exactly twice, both in `ui/settings_model.gd:172-173`'s comparator:
**it sorted the graphics menu cheapest-first**, so the number that decided the
ORDER of the options was the number that did nothing when you picked one.

**The audit's sentence, as three numbers.** With the engine-side keys inert
(`--no-quality`, which reproduces the pre-Wave-17 frame exactly), bench city,
hour 13, `--focus=52,44`, Z0:

| pre-Wave-17 | dc | prims | `rs gpu` |
|---|---|---|---|
| performance | 224 | 276,530 | 1.271 ms |
| balanced | 223 | **273,710** | 1.290 ms |
| high | 223 | **273,710** | 1.286 ms |

**Balanced and High rendered the same frame to the primitive**, GPU times 0.3 %
apart. Performance's one extra call and 2,820 extra primitives are RR-96's
decal — the only thing on the whole engine side separating the rows. As
shipped: **90 / 223 / 223 dc** and **92,822 / 273,710 / 455,852 prims**, with
VRAM spreading **74 / 123 / 191 MB** from a flat 125 MB. **`shadows: false`
alone is 134 draw calls and 183,708 primitives at Z0**, and High costs **67 %
more primitives than Balanced** at the same draw-call count, because Godot
batches the PSSM passes — **`dc` is the wrong column to look for a shadow
setting in.**

**`civ_headlights` was DELETED by the draft on a false claim and is WIRED.**
The claim was that it "duplicates a cap `vehicles.headlight_*` already owns".
Those four rows are a night threshold, a cone length, an energy and a colour —
none of them a count — and `MM_headlights` was in fact **the one buffer in
`VehicleView` with no ceiling at all**: `_ensure_capacity` clamps every body
layer against `caps`, and `_ensure_cone_capacity` grew the cone buffer to the
next multiple of 32 above the roster and clamped against nothing. It is the
only additive, transparent layer the vehicle system draws, on a device §2.13
measures as fragment-bound. **Deleting a key needs the same evidence as wiring
one: the grep, not the recollection.**

**The three `reflection_probe` rows stay deleted, but the justification was
also wrong and is replaced.** The draft cited
`test_water_has_two_octaves_and_no_reflection_probe` as *"the standing ruling
that the probe is not coming"*. That test forbids the WATER SHADER from faking
a reflection, and its own failure message says §2.11 *"gates the ONE probe the
game may own to High"* — **it assumes the probe, it does not refuse it.** The
rows go because nothing constructs a `ReflectionProbe`, and §2.13b now records
the node, the owner and the three numbers so the wave that builds it re-authors
them in the same commit. Six keys are deleted, not seven.

**§2.5b — the pitch-coupled cull is BUILT, and it does not fix what it was
ranked to fix.** `pitch_cull_reach_m` computes where the frustum's TOP CORNERS
meet the ground and clamps the cull ring to it; `CityView` supplies pitch and
aspect off the live `Camera3D` and viewport, so it is live with no shell edit.
Three things the obvious implementation gets wrong and this one does not: the
CENTRE of the top edge reaches 411.9 m at Z2 (exactly `_z2_derivation`'s
hand-computed `r_far`) but **the CORNERS reach 532 m, 29 % further**; `slack`
must multiply the computed REACH and not `far_cull_m`, because the reach scales
with camera height as much as pitch (48 m from Z0 at the floor, 1,111 m from
Z2); and the reach is a GROUND range while `chunk_ground_distance` is 3-D, so
the ring is `hypot(reach, camera_y)` or it comes in by the whole camera height.

**And it removes zero draw calls**, at every pose and every pitch, armed or
disarmed. At 62° the ring resolves to 675 m against the preset's 1,200; the
bench and starter cities are ~896 m across and the presets cull at
900/1200/1500. **A cull ring larger than the city is not a cull.** The
mechanism works — `--far-cull=M` at Z2 gives 19 FAR chunks at 1,200 m, 19 at
675 m and **8 at 500 m** — it simply has nothing to remove until the ring is
inside the city.

**The bust the handoff pointed at is the shadow pass.** Z1 busts the 320 budget
at **335 dc+ui as shipped**, before any manual tilt, and at **353** at the
pitch floor. `far_cull_m` cannot reach it in principle: the Z1 census is
10 NEAR + 26 MEDIUM + **0 FAR**. Measured alternatives: `medium_max_m`
420 → 250 is worth **6 dc at Z1 and 65 at Z2**; the shadow pass is worth
**187 at Z1** (Performance draws Z1 at 124 dc, the same run with the pass
restored at 311) — **60 % of that pose is the sun's cascades**. Filed as an
OPEN with its re-open trigger rather than closed by moving a budget.

**§2.6b — the FAR tier, and it was a colour space applied twice wearing an art
bug's clothes.** `base_albedo`/`roof_albedo` are `source_color` uniforms, which
the engine decodes, so the authored 0.340/0.260 painted linear 0.0946/0.0550
against a tier in front of it painting the MEAN OF ITS FAÇADE PAGE. `CityView`
now measures each page the near tier wears (an 8×8 Lanczos reduction — what
that page looks like once it is a few pixels wide) and hands the five wall/roof
pairs over in sRGB, so the engine performs the one and only decode.

**Where the boundary sits and how big the step was.** `medium_max_m` 420 m is a
3-D distance, so at Z2 the boundary is a ground ring at **197.3 m** and the FAR
tier covers **20.87 % of the frame**. The A/B is `--medium-max=1500`, which
draws the same buildings with the textured shader:

| arm | mean luma over the FAR footprint | vs textured | sd |
|---|---|---|---|
| reference (all textured) | 142.63 | — | 23.10 |
| FAR flat grey (pre-Wave-17) | 120.62 | **−15.4 %** | 12.63 |
| FAR per-family palette | 141.70 | **−0.7 %** | 23.70 |

The far city was **15.4 % too dark and carrying 55 % of the variance**, at zero
draw-call cost either way (182 dc / 302,878 prims in both arms).

**§2.6b (2) — the day façade, which is the other half of the audit's row and is
new in this lane.** With the level matched, `ALBEDO` was still one flat value
per family per face by day. The night path already computes a storey band and a
bay mullion for `EMISSION`; this reuses them on `ALBEDO` for **three ALU, no
texture fetch and no draw call**. **It is ZERO-MEAN by construction** —
`1 + depth · (cover − mean_cover)` with `mean_cover = (band_hi − band_lo) ·
far_mullion_duty`, exactly what the sharp pattern integrates to — because any
pattern whose average is not 1 would throw away the −0.7 % level match above;
measured, the far walls move 145.53 → 144.58 luma, **−0.65 %**. It also
self-extinguishes at range with no second boundary, because both factors are
`fwidth`-crossfaded to their own means. **The depth is a measured art call**:
high-pass detail RMS over the far-tier walls runs **4.46 / 6.07 / 7.66** at
depth 0 / 0.55 / **0.90 (shipped)** against the textured reference's 13.30.

**A textured FAR atlas is FILED WITH ITS PRICE rather than taken**: promoting
the whole Z2 frame to the textured shader costs **+80 dc and +158,322 prims**
on High (182 → 262; inside High's 520 and inside Balanced's 320 at 287 with
UI), but the level error is already −0.7 % and the walls carry structure, so
the residual is texture DETAIL, which reads as softness and not as a line. **A
distance fade is rejected outright**: `fog_aerial_perspective` already greys
the far city with range, and a second fade in the albedo greys the skyline
twice — which is the shot §1's "show the tall skyline" is about.

### The six inherited claims that were wrong, in one place

| the draft said | it is | how it was found |
|---|---|---|
| `civ_headlights` duplicates a cap `vehicles.headlight_*` owns | those are a threshold, a length, an energy and a colour; `MM_headlights` had **no** cap | read `_ensure_cone_capacity` beside `_ensure_capacity` |
| the water test is a standing ruling that no probe is coming | it forbids the water SHADER faking one and assumes the probe | read the test's own failure message |
| `CobraHeadMesh` is exempt: a grime ramp, and `albedo_color` | the ramp multiplies two authored tints, through `ARRAY_COLOR` | `grep -rln "ARRAY_COLOR" game/render/` |
| thirteen preset keys were inert | **twenty-two** | the grep, against the fork tree |
| the road tint moves the road 17 % by day, 1.6 % at night | +3.1 % / +1.2 % by day, +3.6 % / +2.5 % at night — no asymmetry | re-measured at a pose that has a road in it |
| only Performance misses `chunk_budget`, at Z2 | all three presets miss `near_chunk_max` at Z0/Z1; Performance misses `chunk_budget` at all three poses | read the harness's own `OVER` line |

**Five of the six are the same mistake**: a claim about a consumer, made from
reading the code once rather than from grepping for it. `A91-D-19` was closed
by a census and not by a fix, and every one of these would have been caught by
the census the fix eventually shipped —
`test_no_inert_preset_key`, `test_the_deleted_keys_stay_deleted` and
`test_every_procedural_mesh_decodes_its_authored_vertex_colour` are those
censuses, and they are the part of this section worth keeping.

---

## 55. WAVE 18 — the band the governor drew (binding)

### RR-154 — A frame drawn under a full-screen sheet is not a measurement of the world

**The report.** On the Fold, 2026-09-02, on the Wave-17 build: *"the banding does
happen, right in the middle of the screen, only in menus... it's instant, it
doesn't go away or move... every 30 seconds... in any menu or submenu that opens
up. Not the gameplay itself."*

**Three things the evidence settled before any code was read.** (a) A device-side
`adb shell screencap` — a SurfaceFlinger re-composite that never touches a video
encoder — **contains the band**, so it is not scan-out tearing and not the
remote-control capture path; both were the standing suspects since 2026-08-21 and
both are now excluded. (b) Three consecutive captures a second apart are
**identical across the band's rows** (device y ≈ 912-920): it does not crawl, so
it is not a tear. (c) The player's own cadence — *every 30 seconds* — is
`PerfGovernor.DEF_STEP_UP_HOLD_S = 30.0`, to the second.

**The mechanism.** A full-screen sheet covers the city with an opaque panel. The
GPU load collapses, `p95_ms` falls far under budget, and after the 30 s hold the
ladder **takes a rung back**. Rung 1 is `render_scale`, which
`QualityApplier.apply_viewport` writes as `scaling_3d_scale` — so the step
**resizes the 3D render target while a modal is composited over it**, and the
frame that lands mid-resize carries a static horizontal band for as long as the
menu is up. Doc 13 §2.8 authored a *modal row* for exactly this; it had never
been implemented, and the Wave-17 refresh-pin lane said so in its open questions
before anyone knew it was load-bearing.

**The ruling.** The ladder measures the WORLD. While a full-screen surface owns
the display, `PerfGovernor` is **suspended**: `submit_frame` refuses the sample,
`update` makes no move, and the hold timers reset so no step rides out of a menu
on the menu's own headroom. Suspended is not disabled — every rung already
applied is kept, because the world behind the panel has not got any cheaper.
`UIRoot.modal_open()` is the one query (every `ModalLayer` child is full-screen
by §2.2's construction, plus the title door and the loading veil), and
`game/main.gd` asks it once a frame **before** `submit_frame`.

**THE RULING STANDS; THE DIAGNOSIS DID NOT. Corrected 2026-09-02, same day,
before the fix shipped.** The A/B this section proposed was run immediately —
**Settings → Auto quality OFF, app restarted** — and **the bands were still
there**. `auto_quality` false sets `PerfGovernor.enabled = false`, `update()`
returns on its first line, no rung moves and `scaling_3d_scale` is never
written; the band survived all of it. **The governor is not the cause.** The
cadence match was a coincidence of the most seductive kind — the player said
*"every 30 seconds"* and the constant that governs step-up is 30.0 — and it is
recorded here as one, because a number that fits is not a mechanism that fires.

**What the suspension is still for.** Everything in the ruling above is true on
its own terms and is why the code stays: a frame drawn under an opaque sheet
measures the sheet, the ladder acting on it resizes the world's render target
for a reason that has nothing to do with the world, and doc 13 §2.8 asked for
this row before any of this happened. It is a correctness fix that was mis-sold
as a bug fix for one afternoon.

**What is actually known about the band**, evidence only: it is present in a
device-side `screencap` (so it is in the composited frame — not scan-out
tearing, not the remote-control encoder); it is byte-identical across
consecutive captures (so it does not crawl); it is **two strips of about eight
device rows each, at y ≈ 904-911 and y ≈ 920-927** on the 2160×1856 inner panel,
which replace whatever is under them, cutting through text and leaving fragments
aligned at the panel's right edge; and the player sees it only while a
full-screen surface is up.

**The next discriminator, and it is one command.** `game/main.gd`'s
`--screenshot=<path>` saves `get_viewport().get_texture().get_image()` — the
app's OWN framebuffer, read back before the compositor ever sees it. Run it with
a modal on screen: a band in that image is OURS (a render-target or swapchain
defect); a clean image with a banded `screencap` of the same moment puts it
downstream, and the standing candidates there are the Samsung front-buffer /
low-latency stroke path that attaches to this window at launch (`SPen::FbrDrawPad`,
`LowLatencyStrokeView`, both in logcat on every boot) and any system-alert
overlay composited above the game. Until that image exists, this section names
no cause.

### §55.1 PARKED by the owner, 2026-09-02, and how to pick it up

*"We should focus more on this banding issue later... we should get the game more
built out so it works the way we expect. The banding is not a big deal, it
doesn't hinder the gameplay at all."* — the player, after three suspects were
eliminated and the fourth needed a build.

**Parked, not abandoned, and the next step is one command.** The dev screenshot
that would settle it is fixed as of the same day (`game/main.gd`'s `--shot-at`
clock now runs above the two cursor returns; it had never once fired on a device
launch). On the next build:

```bash
adb shell am force-stop com.slacumcity.game
adb shell "am start -n com.slacumcity.game/com.godot.game.GodotAppLauncher \
  --es args '--resume --screenshot=user://band.png --shot-at=30'"
# open a full-screen sheet and leave it up; the app saves and quits itself
adb shell "run-as com.slacumcity.game cat files/band.png" > band.png
```

A band in `band.png` is OURS — a render-target or swapchain defect, and the hunt
moves into the renderer. A clean `band.png` beside a banded `adb shell screencap`
of the same moment puts it downstream of us, and the standing candidate is the
Samsung front-buffer / low-latency stroke path that attaches to this window on
every boot (`SPen::FbrDrawPad`, `LowLatencyStrokeView`, in logcat at every
launch). **Do not re-run the three tests that are already done:** it is not
scan-out tearing, not the remote-control encoder, and not the quality governor.

## 54. WAVE 18 — the tilt looks up: an axis that could not reach its own pose, a scale that was invariant by accident, and a far zoom that got cheaper (binding)

**The user's directive (2026-09-02), verbatim:** *"The screen tilt does work, but
we need more vertical. We need to be able to look UP towards the sky, towards the
top of the buildings as well."*

**What shipped:** the AIM-HEIGHT RAMP on `ui/camera_state.gd` — `aim_height_m()`,
`view_pitch_deg()`, `aim_point()`, `orbit_basis()`, `focus_axis_distance()`,
authored by `data/ui.json.camera.aim_up_ground_frac` / `aim_up_anchor_ndc`; the
`m_per_dp()` correction that follows from it; `--aim=0|1` and a view-angle column
in `tools/profile_frame.gd`; `tests/test_camera_aim.gd` (14 tests, 1,776
asserts). **No screen, no string, no layout, no preview state and no save key
moved**, and **nothing in `sim/` moved** — `profile_sim --hash-only` on both
cities, at the fork and at the end, all four digests byte-identical (§54.4).

### RR-151 — A camera axis built to look UP could not, at any angle it had (docs 12 §2.23.7, 93 §AM1/§AM2/§AM3, A91-D-97)

Wave 17 answered *"we need to be able to look up at the buildings"* with a manual
pitch band floored at 12° and **thirty tests** across
`test_camera_state.gd`, `test_ui_tilt.gd` and `test_gestures.gd` — every one of
which asserts the ANGLE, the bias, the reach or the gesture. **Not one of them
asserted the FRAME**, and the frame is what the directive was about. In doc 12
§2.16's rig the camera looks AT THE FOCUS and the focus is on `y = 0`, so the
horizon is always `pitch` above the view axis and is drawn at
`(1 − tan p / tan(fov/2))/2` down the frame — **20.8 % down at the 12° floor,
leaving the ground the other 79 %**, at *every* angle the band can reach. The
picture at the floor is the complaint verbatim: two thirds pavement, the mid-rise
facades cut off at mid-height, the tower tops off the TOP edge, sky only in the
gaps between roofs. And there was nowhere left to go — `18·sin 12° = 3.74 m` is
the last angle that clears doc 11 §2.6's 3.5 m ground floor.

So the LOOK-AT point rises with the lean instead:

    v_target = −atan((1 − 2·aim_up_ground_frac)·tan(fov/2))     = −6.92°
    view     = lerp(pitch, v_target, |bias| · reach(t)) , ≥ pitch − atan(ndc·tan(fov/2))
    aim      = D·(sin pitch − cos pitch·tan view)
    look_at  = focus + (0, aim, 0)

Four properties, all tested:

* **`bias = 0` lifts exactly nothing.** AUTO and the whole top-down half of the
  axis are the camera Wave 17 shipped, to the bit — `view_pitch_rad()` *returns*
  `pitch_rad()` there rather than reconstructing it through an `atan2`, so
  `camera_basis()` is `orbit_basis()` byte-for-byte and every existing pose,
  test, hash and screenshot is untouched.
* **The composition is authored, and the scale is derived rather than chosen.**
  `aim_up_ground_frac = 1/3` is "pavement in the bottom third". At the far pose it
  solves to `420·(sin 24° + cos 24°·tan 20°/3) = 217.4 m` — and doc 02 §2.3's
  five-rung roster maximum is `high_rise` L5 at `62 × 3.5 = 217.0 m`, the same
  217 m tower doc 11 §2.5 works its LOD example against. **At full zoom-out the
  ramp aims at the roofline of the tallest tower the roster can build, to within
  0.4 m.** Both numbers are read out of `data/building_shapes.json` by the test
  rather than restated, so a roster change fails loudly.
* **It is a PURE AIM LIFT, and that is the ruling** (doc 93 §AM1). A
  camera-height lift changes what is occluded and cannot move the horizon at all,
  because the horizon's screen position is a function of the view axis ANGLE
  alone. Leaving `camera_position()` untouched is what keeps Wave 17's
  ground-floor clearance (swept: 41 zooms × 21 biases, lowest camera in the whole
  product still 3.742 m), doc 11 §2.5's LOD tiering and doc 92 §47.2's bought
  150 m NEAR boundary all statements about the *same* rig.
* **The lean interpolates the ANGLE, not the height.** The first cut scaled the
  full-lean height by the lean and was **not monotone** — the orbit pitch falls
  under the lean and takes `R` with it, so the Z0 aim peaked at 5.896 m around
  bias 0.95 and came back to 5.879 m at bias 1, which the slider would have shown
  as the horizon nodding at the end of its travel.

| pose | orbit pitch | view pitch | look-at height | ground's share of the frame |
|---|---|---|---|---|
| Z0 (t 0) | 12.00° | **−6.92°** | 5.88 m | **33.3 %** (was 79.2 %) |
| default (t 0.42) | 14.99° | −4.92° | 23.09 m | 38.2 % (was 86.8 %) |
| Z1 (t 0.5) | 16.32° | −3.68° | 29.80 m | 41.2 % (was 90.2 %) |
| Z2 (t 1) | 24.00° | +4.00° | 144.0 m | 59.6 % (was 100 %, the horizon off the top edge) |

The near end lands on the authored third exactly; the far end does not, because
two guards bite there first — `reach_up_far = 0.76`, and `aim_up_anchor_ndc`.
That second one is the ramp's only guard and it is geometric rather than a taste
number: **the focus may not leave the frame**, because it is the pan anchor, the
pinch anchor, the twist pivot and `focus_on()`'s landing spot. At the authored
1.0 it may ride the bottom edge and no further; it does not bind at the near zoom
(Z0's full lean needs 18.92° of drop against the frame's 20°) and binds by 0.45°
at Z1 and 3.5° at Z2. That the near end clears it by 1.08° is a coincidence of
three authored numbers and is therefore TESTED, by projecting the horizon and
asserting where it lands.

### RR-152 — A scale that was invariant by accident, and a pick that had to be proved (docs 12 §2.21/§2.23.4 (D-85), 93 §AM4, A91-D-98)

The ramp changes where the frustum POINTS, and every ray in this project reads
`camera_position()` and `camera_basis()` — the same basis the `Camera3D` wears —
so `screen_ray`, `ground_hit`, `screen_to_ground` and `project_to_screen` follow
the aim for free and cannot disagree with what is drawn. **Proved, not argued:**
`test_a_tap_resolves_to_the_tile_it_visually_covers` projects a tile centre to the
screen and casts that pixel back at three zooms × {AUTO, floor} and asserts the
same 8 m tile to within 0.01 m; the inverse round trip is
`test_a_screen_point_round_trips_through_the_ground_and_back`.

**One number did have to move, and it is the defect this wave found.**
`m_per_dp()` is documented — in its own comment and in doc 12 §2.23.4 — as
pitch-invariant "because screen-right is parallel to the ground at every pitch".
Half true. Screen-right is parallel to the ground, but the figure also carries a
DEPTH: `2·D·tan(h½)/w` is the frame's width in metres *at the focus*, and that is
only `D` deep while the camera is aimed at the focus. It always was, for four
waves, which is why the claim read as arithmetic rather than as a property of the
rig. The ramp tips the focus `Δ = pitch − view` below the axis and its depth to
`D·cos Δ`, and leaving the figure at `D` would have over-stated §2.21's 48 dp tap
radius, §2.7's drag ghost and the drawer offset by **5.4 % at the Z0 floor and
6.0 % at Z2** — small, silent, and in the un-conservative direction. It now
measures at `focus_axis_distance()`, and
`test_m_per_dp_is_the_scale_the_projection_actually_draws` proves it against
`project_to_screen` itself, at 27 poses, rather than against its own formula. The
correction moves it DOWN, so a lifted aim can only make a radius pick tighter —
which is the direction §2.23.4 already promised.

**The typed miss is now most of the frame rather than a corner of it.** At the
floor the horizon is drawn two thirds of the way down, so every screen point
above it answers `MISS_ABOVE_HORIZON`. No caller changed — RR-116's split already
routes every caller that ACTS on the world through `hit` — and *which* ground is
pickable did not move either: the `ray_parallel_eps` and `dist·4` limits are
properties of the camera POSITION, not of the aim. Only where that ground is
DRAWN moved, from "below 32 % of the frame" to "below 78 %". **The consequence
that is real and is filed rather than hidden:** the screen AREA a placement tap
can land on at a full lean shrinks from the bottom 68 % of the frame to the
bottom 22 %. The same world ground is reachable and the remedy is the control the
player already has — let the slider go and the frame comes back — but a build
flow driven at the floor has a smaller target than it had, and no measurement in
this wave says whether that reads as tight on a phone. Owed on the device.

### RR-153 — What the recomposition costs: the near zoom pays, the far zoom is REFUNDED, and the cull cannot arbitrate either (docs 11 §2.5b/§2.13, 92 §53, 93 §AM5)

Full table in doc 92 §53, measured as a true A/B on one binary through
`--aim=0|1`. The headline, bench city, balanced, 1920 × 1080, day, at the pitch
floor:

| pose | before (`--aim=0`) | after (`--aim=1`) | Δ |
|---|---|---|---|
| Z0 | 361 dc / **386** | 409 dc / **434** | **+48** |
| Z1 | 321 dc / **346** | 332 dc / **357** | **+11** |
| Z2 | 240 dc / **265** | 201 dc / **226** | **−39** |

**The far pose gets CHEAPER**, and that is the geometry rather than luck: aiming
up rotates the frustum off the ground immediately in front of the camera, and at
Z2 the camera is 171 m up, so what leaves the frame is a large apron of near
ground and what enters is sky. At Z0 the camera is 3.74 m up, the apron is 10 m
wide, and what enters is the airspace 1,500 buildings stand in — which is the
picture the wave exists to produce, and the calls that draw it.

**Fifteen of the table's twenty-four cells are byte-identical** — every cell whose
bias is `≤ 0`, i.e. AUTO and the whole top-down half of the axis. That is the
"AUTO lifts nothing" claim tested through a rendered frame rather than through a
unit test. And **the worst cell is not the floor**: 34° asked at Z1 is a 0.39
lean off a 48° curve and goes 285 → 350 dc+ui, taking a cell that was inside the
budget outside it, where the Z1 *floor* moves only +11 because `reach_up` and the
anchor cap have already shortened the lean there.

**Where the +48 went, attributed.** The visible NEAR building buckets are
identical in both arms (197 + 149 = 346), so none of it is building geometry
re-tiering. Two independent ways of disarming the sun's shadow pass — hour 21,
and the `performance` preset's `shadow_max 0 m` — both give **+33**, so the split
is **+33 main pass** (the road and ground surfaces, the street furniture and the
merged tier an aimed-up frustum newly contains; `--no-power-infra` is 3 of it)
and **+15 sun-shadow pass**, day only.

**The pitch-coupled `far_cull_m` cannot pay for the Z0 bill, and the brief's
hypothesis about it is backwards** (doc 93 §AM5). Aiming up moves the frame's
NEAR edge out — the bottom ray at the Z0 floor is 13.08° below horizontal, so the
nearest visible ground is `3.742/tan 13.08° = 16.1 m` where it was 6.0 m — and
leaves the FAR edge exactly where it was, at infinity, because the top ray still
clears the horizon. §2.5b's `pitch_cull_reach_m` returns INF for every angle at or
below the half-FOV and is honest to do so; a cull tightened past it would delete
the skyline. **The `lod.pitch_cull.slack` curve is therefore NOT re-fitted, and
the excess is published under §AC2's standing ruling** — Z0 day floor **+114 dc
over the 320 budget (434 of 320, +35.6 %)**, Z1 floor +37, Z1 at 34° +30, with
Z2 **under** by 94 and every night cell in the table inside the budget. One thing
was checked rather than assumed: a NEGATIVE view pitch now collides with
`set_camera_pose`'s `pitch_deg < 0` "no pitch supplied" sentinel, and both
branches produce the identical answer (`far_cull_m` untouched) precisely because
the reach is INF there — asserted at five angles from −6.92° to 19.9°.
**Re-open** if a `slack` curve is ever authored that makes the reach finite below
the half-FOV.

**Where these numbers sit against doc 92 §47's.** The NIGHT column reproduces §47
cell for cell (Z0 floor 221, Z1 216, Z2 251, AUTO Z0 112). The DAY column is
+23 / +13 / +7 dc above §47's at the floor, and that gap is not this wave: §47 was
measured before the render fork merged (RR-95…98, the building shadow and the
linear meshes), and the sun's shadow pass is the only renderer difference between
hour 13 and hour 21 at a fixed pose. The A/B above is taken on ONE binary for
exactly this reason. **One §47 claim is now stale and is recorded rather than
left standing:** §47.5's "the draw calls do not move with the preset" — after
RR-98 wired doc 11 §2.13b's engine-side keys, `performance` draws no sun shadow
and the Z0 day floor measures **222 dc+ui at performance against 386 at
balanced**, before the aim ramp is involved at all (doc 92 §53.4).

### 54.4 The world edge, re-checked — and it is better seated than before

The 2026-09-01 audit's P1 (*"an 896 m floating slab with a hard cliff"*) was
answered at Wave 17's composition by RR-114 with a ≤ 17/255 seam step. Re-run at
the new one, same worst case — pitch floor, far zoom, camera at the city's corner
looking out over the edge (`--poses=z2 --hour=13 --tilt=12 --yaw=225 --focus=60,60`)
— the sky-to-world seam measures **7 … 11 / 255** at the three sample columns that
sample the edge rather than a tower silhouette (doc 92 §53.5 has the table). The
edge is **better** seated after the ramp, and the mechanism is the composition:
the aim lift puts more SKY above the fogged skyline rather than more slab below
it. That pose is also one of the refunded cells — 213 → 168 dc.

### 54.5 The pictures, and the baselines

Every screenshot is `tools/profile_frame.gd --shots=DIR` on the bench city at
1920 × 1080, preset balanced.

| what | command | reads as |
|---|---|---|
| the complaint, measured | `--poses=z0 --hour=13 --tilt=12 --aim=0` | horizon a fifth down, two thirds pavement, mid-rise facades cut at mid-height, tower tops off the top edge |
| the same pose, after | `--poses=z0 --hour=13 --tilt=12` | street-level camera, pavement in the bottom third, facades filling the middle, towers into the top third, sky above them |
| a 168 m tower bottom to top | `--poses=t0.88 --hour=13 --tilt=12 --focus=69,67 --yaw=45` | `R-0046`, one of the bench city's tallest (`high_rise` L4, 48 × 3.5 m), standing at the focus: base on the bottom edge, roof at 13.5 % down by projection with its mast above that, sky over it, and a skyline behind |
| the same floor at night | `--poses=z0 --hour=21 --tilt=12` | lit facades and towers against a night sky, road in the bottom third |
| the world edge, worst case | `--poses=z2 --hour=13 --tilt=12 --yaw=225 --focus=60,60` | the far city fogs into the haze band; no cliff, no black band, 7…11/255 at the seam |

**A 168 m tower cannot be framed bottom-to-top at Z0 and no camera change can do
it:** 40° of vertical FOV needs `168/(2·tan 20°) = 230.8 m` of view distance and
Z0 is 18 m. The pose above is `zoom_t 0.88` (`D = 288 m`), and at the floor with
the ramp the anchor cap puts the tower's base corner exactly on the bottom edge
while its roof projects to 145.9 px of 1080 — **13.5 % down** — which is as close
to "bottom to top" as the projection allows. At `t0.85` the same tower clips the
top edge (roof at 4.8 %), which is how the zoom was chosen.

**One harness trap, recorded because it cost a screenshot.** `--focus=TX,TZ` is a
**GLOBAL** tile; a city fixture's building `origin` is **core-local**, and
`StarterCityLoader.core_to_global` adds `CORE_TILE_OFFSET = 32` to each axis. The
first take of this shot aimed 30 tiles away from the tower it named. The flag's
doc comment in `tools/profile_frame.gd` now says so.

**Baselines — all four bit-identical, at the fork and at the end.** `sim/` was
not touched; this wave is shell and `ui/` only.

    ~/.local/bin/godot --headless --script tools/profile_sim.gd -- --hash-only
    ~/.local/bin/godot --headless --script tools/profile_sim.gd -- --hash-only         --city=res://tests/fixtures/bench_city.json

| city | coarse 24 h | fine 2 h |
|---|---|---|
| starter | `05614522975fad52…` | `d1aaee0dca92f2fd…` |
| bench | `275aad9d4aeea809…` | `d40126e371371d59…` |

**Gates.** `~/.local/bin/godot --headless --script tests/run_tests.gd` — **134
files, 2,490 tests, 551,462 asserts, failed 0, silent 0**, exit 0.
`xvfb-run -a ~/.local/bin/godot --path . res://tools/ui_preview.tscn --
--screen=all --audit --strict` — **exit 0**, and the two tilt preview states
(`tilt_rest`, `tilt_drag`) are clean at every box: the ramp adds no control and
changes no layout, so the deck stays at 59 states.

## 49. WAVE 18 — the Director wakes up, and the storm the game never ran (binding)

*Filed 2026-09-02 from `99-production-audit.md` lane B — rows **PA-04** (P0),
**PA-25**, **PA-26** and **PA-89**. Every number below was measured on this
branch and the command that produced it is quoted beside it. This lane holds the
balance matrix for the wave; §49.5 carries the re-fits and their derivations.*

**The shape of it.** Doc 07's Disaster Director is the system that decides what
tests the city. At the Wave-17 fork it decided twice, and then it stopped — for
the rest of every city's life, in every save on every phone.

Three independent defects stacked, and each one alone would have been enough to
make doc 07 §2.6's SHIPPED grade false:

1. **Nothing resolved an event.** `on_event_resolved` is the only eraser of
   `active_events` and `grep -rn on_event_resolved sim/ game/` at the fork
   returned **the definition and the tests**. `_try_schedule`'s pacing gate —
   `if has_pending_major() or scheduled.size() + active_events.size() >= 2:
   return` — therefore refused every schedule after the second event, forever.
2. **Five of the eight catalog events could not become anything.**
   `target_provider` was declared, read twice and never assigned; four of the
   eight ids are not doc 06 catalog types at all; and the sink resolved a
   reference against buildings and grid components only, so a water segment or a
   road intersection could never resolve. Each dead pick still spent its TP.
3. **The player's half of the storm had no door.** Six authored prep actions, a
   Storm Report, a Storm Ready payout — `grep -c storm_prep sim/city_sim.gd` →
   **0**.

Measured at the fork, `tools/probe_director.gd`, balanced / seed 4242 / 60
game-days on the coarse online path:

| | fork (`d0d114f`) | this branch |
|---|---|---|
| `director_event_started` | **2** | **23** |
| `director_event_ended` | **0** | **23** |
| `active_events` at the wall | **2** | **0** |
| last event started on game-day | **7.5** | **47.3** |
| longest hold (game-minutes) | — (nothing ever ended) | **226** |
| kinds that resolved | *none* | `traffic_pileup` ×8, `water_main_break` ×6, `storm_minor` ×5, `transformer_explosion` ×4 |

### RR-135 — every committed event is STAMPED at commit with the two minutes that end it

**Ruled.** An event that cannot end is a scheduling gate that cannot open, so the
end is written at the beginning. `DisasterDirector._stamp_resolution` puts two
fields on every committed row:

* **`resolve_after_min`** — the earliest minute it may resolve. A weather event
  is not over while its segment runs, so `impact + duration`; a
  `severe_thunderstorm` also owes §2.7.6's STORM REPORT, so
  `impact + max(duration, storm.recovery.report_at_min)`, which for the beat
  sheet's own 120-minute storm is **exactly T+180**. An event that only requests
  incidents may end the moment they close, so `impact`.
* **`expire_at_min`** — the hold cap, `impact + fairness.max_active_min`
  (**2880** game-minutes = 48 game-hours, past doc 06 §2.10's one-game-day
  ABANDONED terminal rule). Nothing waits forever, however the link book was
  lost.

**The two halves of the test live in the two places that can answer them.**
`DisasterDirector.events_due_for_resolution(now_min, busy_uids)` owns the clock;
`CitySim._sweep_director_events` owns `_director_links`, the incident-to-event
book, and joins them on every REPORT tick immediately after the drain that erases
links — so an event whose last incident closes on a tick resolves on that tick. A
request the sink REFUSED never enters the busy set and therefore resolves at
once, which is the honest answer: it produced nothing, so there is nothing to
wait for. Resolutions are handed back in ascending uid so two events closing on
one tick close in a canonical order.

**Rejected: resolving in `on_incident_resolved`.** That hook already exists and
already fires; making it the resolver would have closed an event on its FIRST
incident rather than its last, which is not what F2 measures its cooldowns from.

**Rejected: an hourly sweep in the DIRECTOR phase.** Cheaper, and it would have
quantised every resolution to the hour boundary — F2's from-resolution cooldowns
would then read up to 59 minutes early. `active_events` holds at most two rows;
the per-tick sweep is a two-row loop behind an `is_empty()` guard.

`on_event_resolved` gained a third argument, `now_min`, for the same reason: the
Director's `_now_min` only advances on its hourly tick, and resolution happens at
REPORT. It only ever moves the clock forward.

### RR-136 — the save ladder's rung 8 REPAIRS rather than records, and it is the first one that does

**Ruled.** `CitySim.SAVE_SECTION_VERSION` moves **7 → 8**. Every rung before this
one recorded a rules change with an identity migrator; this one writes into the
body, because the state it is fixing is one no binary should have been able to
write — a `director.active_events` list that can never empty. Every save the
game has ever produced can carry one, and a city with two ghost rows has a
Director that will never schedule again.

`_v7_to_v8` stamps `resolve_after_min` and `expire_at_min` onto every
`director.scheduled` and `director.active_events` row, computed from what the row
already carries (`impact_min`, and `duration_min` if it is a weather row) plus
`DisasterDirector.MAX_ACTIVE_MIN_DEFAULT` and `STORM_REPORT_AT_MIN_DEFAULT`. The
two constants exist **because** doc 08 §2.8 forbids a migrator from opening
`data/`; `tests/test_director_resolution.gd` pins each equal to the
`data/director.json` value it mirrors, so they cannot drift.

**Rejected: dropping the ghost rows.** It is the obvious move and it is wrong
twice: a row that is genuinely in flight has incidents on the map linked to it,
and a dropped major would leave `last_major_end_min` never set and
`has_pending_major()` lying in the other direction. A stamp is total; a deletion
is a guess.

`DisasterDirector.deserialize` writes the same stamp when a row arrives without
one, so a fragment restored by a tool or a fixture — anything that never walked
the ladder — still gets an event that can end.

This rung is **hash-moving on every played city**: an event that could not end
can now end, so a v7 city advanced under v8 sees storms a v7 binary would never
have scheduled. §49.5 carries the re-taken baselines.

### RR-137 — the Director's catalog names the drama; doc 06's catalog names the type, and one column joins them

**Ruled.** `data/director.json`'s eight event rows gain an **`incident_kind`**
column, `{type, subtype, source}`: doc 06's own type id, its subtype (only
`storm_damage` has any) and the §2.6.5 candidate source its target roster is
drawn from. Five rows carry one; the three weather rows do not, because their
whole effect is the segment they inject, and an EMPTY column is the statement
"this event has no incident half" rather than an omission.

| director event | doc 06 type | §2.6.5 source |
|---|---|---|
| `traffic_pileup` | `traffic_accident` | `intersection` |
| `water_main_break` | `water_main_break` | `water_segment` |
| `transformer_explosion` | `transformer_failure` | `transformer` |
| `crime_surge` | `crime` | `district_building` |
| `major_structure_fire` | `structure_fire` | `building` |
| `storm_minor` · `heat_wave` · `severe_thunderstorm` | — | — |

**`CitySim.director_targets` is bound to `target_provider` at boot** and supplies
§2.6.5's descriptor — `ref`, `condition`, `district_id`, `domain`,
`base_type_weight`, `exposure_factor`, plus `pos` and `f10_protected` — drawn
from **doc 06's own candidate source** through `CityIncidentWorld`, so a Director
target and an ambient one come from the same population. The Director is not a
second, parallel spawner. F10's "last of its kind" test is evaluated there,
because the live roster is the only place it is answerable, and it ships to the
resolver as `condition_floor`.

**The trap this fix walks past, recorded because it cost a measurement.** §2.6.3
step 8 says *"if no legal target, drop the pick"*. A weather event has no target
roster — its target is the whole city — so reading step 8 the other way deleted
`storm_minor`, `heat_wave` and the authored thunderstorm from the schedule the
moment a provider was bound: the 60-day probe went from 23 events with 5 warnings
to 20 events with **zero** `weather_warning` emissions. `_choose_target` now
returns "no target, proceed" for a row with no `incident_kind`, and drops the
pick only for a row that needs something to hit and cannot find it.

**The sink picks for itself when the request carries no reference** (the debug
force verb; a row restored from a save written before the provider existed). The
pick is the heaviest §2.6.5 weight with ties broken by `ref` — deterministic and
RNG-free, because this is a fallback and not a second scheduler, and a `randf()`
here would be a `director` stream position the fine and coarse paths would have
to agree on.

### RR-138 — "no other candidate is affordable" is `pool.size() == 1`, and the looser reading was measured and rejected

**Ruled.** §2.6.2's *buy severity* ships: the Director may spend up to
`1.60 × tp_cost` to add up to `+0.30` to `severity_mult`, linearly, and only when
`tp_pool > 1.6 × tp_cost` **and no other candidate is affordable**. Since
`candidates()` has already filtered the pool to what the budget can buy and what
the fairness gates allow, the second clause is exactly `pool.size() == 1`: there
is money, there is one thing to spend it on, and the surplus would otherwise sit
against F6's cap doing nothing.

**The looser reading — "nothing DEARER is affordable" — was implemented first,
measured, and rejected.** Over doc 07 §7 test 26's own rig (100 game-days × 12
seeds × 4 presets, `tools/probe_test26.gd`):

| | majors, Standard | game-days per major, Standard | mean `severity_mult`, Standard | crisis/casual major ratio |
|---|---|---|---|---|
| fork (no buy) | 454 | 2.643 | 1.2080 | 2.644 |
| "nothing dearer" | 372 | **3.226** | 1.2377 | **2.506** |
| **shipped** (`pool.size() == 1`) | 420 | **2.857** | **1.2825** | **2.622** |

The looser reading fires on any hour whose pool tops out on a cheap minor. It
took the Standard cadence outside §2.6.3's own claim (*"one major crisis every
~2–2.5 game-days"*), and outside the two bounds `test_26_difficulty_scaling`
already held, while buying only **+2.5 %** mean severity for an **18 %** cut in
majors. The literal reading buys **+6.2 %** mean severity for **7.5 %**, keeps
both existing bounds green with no re-fit, and is what the sentence says.

**One doc-internal inconsistency is recorded, not silently resolved.** Doc 07
§2.6.2's parenthetical *"(+0.50×tp_cost buys +0.125)"* cannot be reconciled with
its own *"spend up to 1.60 × tp_cost to add up to +0.30"*: the second sentence
fixes the rate at `+0.50` of severity per unit of `tp_cost` overspent, which puts
`+0.50×tp_cost` at `+0.25`. The rate implied by the two endpoints is the one
implemented (`(spend/cost − 1) × buy_max_severity / (buy_max_cost_mult − 1)`,
exactly `+0.30` at the cap); the parenthetical is an arithmetic slip in the
authored text and is flagged as an open question rather than patched by this
lane, which does not own doc 07's prose.

The buy is **all-or-nothing** rather than a slider: a partial buy would need a
draw, and a draw here is a stream position the coarse and fine paths would have
to agree on for no design gain. `tp_spent` rides on the committed row so the
report and the save both carry what it actually cost.

### 49.x — awaiting_consumer: disaster income

**Filed by lane B, addressed to the money lane (99-PA §3.2 lane S), not ruled
here.** With the Director running for the first time, `city_services` revenue on
the `do_nothing` control agent rises **36–49 % on every difficulty preset**
(doc 92 §49.5's table) — because doc 06 pays the city for an incident it
auto-resolves and a city that never repairs anything pays none of the damage it
takes. On `hard` that is $26k over 120 game-days, enough to keep a neglected
city's treasury closing above zero for 72 consecutive game-days after it first
runs out of money.

Doc 03 and doc 06 own both halves of that (`dispatch_payout_base`, RR-78's
ruling that the payout is the survivor of the double-booked fine); lane B owns
neither file and rules nothing about it. The row is filed because **it could not
be seen before**: with the Director stalled at two events there was no disaster
income to notice, and the first thing that measures it is this wave's gate 29
re-read. Gate 29's own bands are untouched (§49.5) — the question is whether a
disaster should be net revenue for a player who ignores it, which is a design
ruling and not a gate.

**The matrix holder this wave is lane B**; any lane whose merge moves a hash
should publish its delta against §49.4's four baselines.

### 49.z — what the lane leaves green, and the two things the suite caught last

`~/.local/bin/godot --headless --script tests/run_tests.gd` → **137 files,
2,516 tests, 563,090 asserts, 0 failed**, exit 0, on a branch merged up to
`4503d35` (all of Wave 17). `tools/check_doc_refs.py` → 3,830 references, all
resolving. `tools/ui_preview.gd --screen=all --audit --strict` → exit 0 at
412×915, at 360×800 with 130 % text and larger touch targets, and at the Fold's
673×841 with the same two settings.

Two failures survived to the first full run, and both are worth the record
because neither was reachable by any smaller instrument:

1. **`test_weather_director.gd::test_29` went red**, and that is A91-D-87
   confirming itself. The test called `SevereThunderstorm.begin()` — a call the
   Director itself only makes at IMPACT — and then asked for a window measured
   against `storm.t0_min`. RR-135's re-pointing of the window at the SCHEDULED
   row is exactly what broke it: a test standing on an unreachable branch stays
   green until the branch becomes reachable. It is re-pointed at a real
   `director.scheduled` row at T−50 and keeps every assertion it had.
2. **S17 did not fit a 360 dp phone at 130 % text.** The action row's one-line
   form needs 395 dp of a 300 dp body, a `ScrollContainer` with horizontal
   scrolling off hands that straight up its parents, and the sheet became 423 dp
   wide inside a 320 dp box — pushing ✕, the only way out of a modal, off the
   screen. The button moves to the row's second line (307 dp). Doc 12 §2.24 and
   D-78 carry the derivation. `tests/test_ui_audit.gd` could not have caught it:
   its `SURFACES` sweep reads a CLOSED modal, and a hidden subtree reports a
   minimum width of 0 — `ModalLayer/PauseMenu/Panel` 260 against
   `ModalLayer/GoalsSheet/Panel` 0 in one mount. This lane binds S17 to a
   six-row fixture there and measures its own row directly; **the sweep itself
   is left open for the lane that owns that file**, because every modal in that
   list is currently unmeasured.

## 50. WAVE 18 — the fix router, the locator, and the one shell file the suite could not see (binding)

*Filed 2026-09-02 from the production audit's `§3.2 Lane D` brief — PA-05 (router
half), PA-38, PA-20, PA-76, PA-72, PA-100. Three rulings; every number below is
quoted with the command that produced it.*

**The shape of it.** `game/main.gd` was 2,257 lines with **zero test
references** (`grep -rn "main\.gd\|main\.tscn\|MainShell" tests/` → six prose
comments and no load). Three separate defects lived in it and none of them could
fail a gate: `Fix this →` looked a **transformer** id up in `sim.buildings` and
returned; `E_AVENUE` handed the same router an **empty** id, which the router
discards on its first line; and every camera answer in the file anchored on a
building's **NW corner tile** rather than on its footprint centre, so a jump to a
4×4 civic building landed sixteen metres off it. All three are the same missing
thing — *the shell was doing sim reasoning in a file nothing can boot* — and the
fix is not to test `main.gd`. It is to move the reasoning out.

### RR-139 — one geometry authority, and a gate that fails on drift rather than an audit that finds it

**Ruled.** `TileGrid.METRES_PER_TILE` (and `METRES_PER_BLOCK`, `corner_of`,
`centre_of`, `centre_of_footprint`, `centre_of_block`, `tile_at`) is the single
authority for tile→world conversion. The **store** stays `data/world.json`
`world.tile_meters`; the constant mirrors it and `tests/test_tile_geometry.gd`
asserts the two agree.

**Why a gate before a migration.** PA-76 counted the number written **eight
times under six names** (`METRES_PER_TILE`, `TILE_METERS`, `TILE_M`,
`DEF_TILE_M`, `TILE_M_DEFAULT`, bare `8.0`) and the footprint→centre formula four
times, and its evidence line is the damning one: *"No test asserts agreement."*
The eleven live declarations sit in files owned by six different Wave-18 lanes,
so a lane that migrated them all would be editing five other lanes' files on a
rule (99 §3.0.1) that forbids exactly that. The gate is therefore landed **first
and alone**: `test_tile_geometry.gd::test_every_mirrored_spelling_agrees` names
all eleven by class constant and fails on the first one that drifts. Every
consumer migration afterwards becomes a one-line change that cannot go wrong
quietly, and the migrations themselves are filed per owner (`awaiting_consumer`,
below) instead of merged by force.

**Hash-neutral, and provable.** No helper here is new arithmetic:
`test_the_footprint_centre_reproduces_the_hand_written_formula` asserts
`centre_of_footprint(origin, size)` equals the `origin * 8.0 + size * 4.0` the
shell and the renderer already wrote, and
`test_the_block_centre_reproduces_the_hand_written_formula` does the same for the
`(grid * 16 + 8) * tile_m` the alert locator wrote three times. Adoption moves no
building and no hash.

**Two things the helpers do that the hand-written code did not.** `tile_at`
**floors** rather than truncating — truncation folds every point in `(-8, 0)`
onto tile `0`, which reads as "the tap landed on the map" for a tap that landed
west of it — and `centre_of_footprint` clamps a zero size to one tile, so a
malformed record focuses on a tile rather than on its corner.

**And the hand-written census was wrong before the wave ended, which is the
best argument in this section.** The gate was first written naming **eleven**
mirrors by class constant — PA-76's own tally, transcribed. Merging the lane onto
`4503d35` turned up **seventeen**: two shipped (`ConstructionSiteView.DEF_TILE_M`,
`VehicleView.DEF_TILE_M`, both added by the Wave-17 render lane *while this lane
was in flight*) and four in `tools/`, which PA-76's evidence line never scanned
(`onboarding_preview`, `overlay_preview`, `construction_preview`, `flow_test`).
A gate against drift that is itself a hand-maintained list is `A91-D-19`'s shape
for the fifth wave running, and it would have shipped as one.

So `test_the_mirror_census_finds_no_declaration_the_named_list_missed` **scans**:
every `const <TILE-and-metre-shaped> := <number>` under `sim/`, `game/`, `ui/`
and `tools/` is found by regex on the NAME — not on the value, because a
value-matched scan skips precisely the declaration that has already drifted — and
checked against `TileGrid.METRES_PER_TILE`. The count is asserted from below
(`>= 17`) so a broken scan cannot pass by finding nothing, and the name pattern
names its spellings rather than matching "anything with TILE in it", so
`TILES_PER_BLOCK` (a tile COUNT) is not swept in. The named list stays beside it,
now thirteen, because it checks the LOADED constant rather than the source text.

Verified by negative control: setting `tools/flow_test.gd:43 TILE_M := 8.5`
fails the file with `res://tools/flow_test.gd:43 TILE_M = 8.5 drifted from
TileGrid.METRES_PER_TILE`, and reverting restores `10 tests, 66 asserts, 0
failed`.

**Applied:** `sim/world/tile_grid.gd`, `tests/test_tile_geometry.gd`.

### RR-140 — a fix target resolves to an ACTION, and a router that cannot answer says which of five ways it failed

**Ruled.** `Fix this →` is a two-part contract and the parts belong to different
files. The **params half** (which id a checklist row carries) belongs to the
surface that built the row; the **router half** (what that id means and what to
do about it) belongs to `ui/fix_router.gd`, is headless, and is total over
`RequirementFormatter`'s `FIX_*` kinds. `game/main.gd::_on_fix_requested` is now
three lines and does the one thing a shell may do with the answer: move the
camera.

**The sweep caught this lane's own bug, and that is the row's best evidence.**
`test_no_real_checklist_row_falls_through_silently` runs the REAL
`BuildController.upgrade_view` checklist for every building in the starter city
and routes every row. A first cut of the router treated `FIX_POWER`'s id as a
building sim id — the natural reading, since `FIX_REPAIR`'s is one — and the
sweep failed **33 rows in one method**, every `POWER_CAPACITY` row in the city,
each naming the transformer it had been handed (`APT-001 … id T-02 named nothing
on the map`). `FIX_POWER`'s id is the component the headroom **binds at**, not
the subject: it is filled from `sim.grid.attachment_of(sim_id)`, which is
precisely the mismatch PA-05 is about, and a router that "fixed" it by looking
the component up among buildings would have reproduced the original defect in a
new file. It is carried as `binds_at` with the wall's position; the BUILDING is
taken only from an explicit `sim_id` a caller adds, never by reinterpreting the
component id. The gate is the reason that is a paragraph here instead of a
regression on the phone.

**Why "an ACTION" and not "a world position".** Two of the seven kinds have no
place to go — `FIX_REPAIR` and `FIX_POWER` target the building the player is
already looking at, so a camera move is a no-op, which is precisely how
A91-D-54 was found. A router that returns only positions has to lie about those
two. Three shapes cover the whole table and each is what a real surface already
does: **focus a world point**, **open a sheet pre-armed** (`FIX_POWER` arms the
panel's power strip — `building_panel.gd` sets `_power_fix_armed` and the strip
spends), and **run a verb with a quote** (`FIX_REPAIR` → `cmd_repair_building`).
The quotes are the sim's own `preview: true` returns, which stop before the
first mutation in both commands, so **routing a fix target is a read** —
asserted by `test_fix_router.gd::test_routing_never_moves_the_sim`, not argued.

**The refusal is the load-bearing half.** The two dead branches were dead in the
same way: a bare `return`. `ACTION_NONE` now carries one of five reasons, and
the distinction between two of them is the whole point — `no_fix` means the row
has no remedy and is not a bug; `empty_id` means the row has a remedy and the
CALLER did not supply a target, which is a bug, and names whose. `E_AVENUE`
answers `empty_id` today and will answer `focus` the moment
`ui/build_controller.gd`'s `E_AVENUE` params carry `"fix_target_id": sim_id` —
one line, filed below, and the router side is already tested against it
(`test_E_AVENUE_routes_once_its_params_carry_the_building`, which additionally
asserts the tile it lands on IS an avenue).

**The namespace ruling.** `POWER_CAPACITY` fills `fix_target_id` from
`sim.grid.attachment_of()`, which is a **transformer** id, and the code table
maps it to a **building** kind. The mismatch is three waves old and was
"resolved" twice by re-pointing the kind. The durable answer is that **an id the
sim published always resolves**: `WorldLocator.locate_any` tries buildings, then
grid components, then blocks, then districts, in a fixed order over namespaces
that are disjoint in practice, and `KIND_BUILDING` falls through to it on a miss.
A future kind/id mismatch is then a wrong camera destination — visible — rather
than silence.

**And the lane committed RR-139's defect inside RR-140's file, which is the
second-best evidence in this section.** `WorldLocator.ROAD_SEARCH_TILES` shipped
as a hand-written `:= 12` under a docstring reading *"Mirrors
`BuildController.AVENUE_SEARCH_TILES`"* — which is **16**. One number, written
twice, under a promise that they agree, in the same wave that ruled a promise is
not a gate. The tile-metre census in RR-139 could not see it: it is a tile
**count**, not a metre.

The consequence is `Fix this →` refusing a fix that exists.
`BuildController.nearest_avenue_tiles` searches to 16 before reporting "none in
range", so `E_AVENUE` is raised for a building whose nearest avenue is up to 16
tiles off; once lane L's params half lands (§50.2 item 1), a building at 13–16
hands this locator a row the checklist has just measured and gets `unresolved`.
That is PA-05's shape one namespace over — and it would have been introduced by
the lane that closed PA-05.

`ROAD_SEARCH_TILES` is now `BuildController.AVENUE_SEARCH_TILES` **by
reference**; a reference cannot drift. Two gates stand behind it:
`test_the_search_reaches_as_far_as_the_check_that_raises_the_row` (the constants
are the same object) and
`test_every_building_the_controller_can_measure_the_locator_can_find`, which
sweeps the real roster and asserts the two hand-written ring walks agree on the
DISTANCE as well as on the reach — so any other divergence between them fails
too. `--file=test_world_locator` goes 16 tests / 51 asserts → **18 / 121**.

**Latent, not live, and worth stating as such**: the farthest starter building
from an avenue is **7 tiles** (`APT-003`; `in_13_to_16 = 0` over all 34), so no
fixture in the tree could have caught this and none of the numbers above moved
because of it. `E_AVENUE` is a level-4 check on a building the *player* chose to
place far from an avenue — exactly the case the starter city does not contain,
which is why it was found by reading the constant against its own docstring
rather than by a failing test.

**Applied:** `ui/fix_router.gd`, `ui/world_locator.gd`, `game/main.gd`
(`_on_fix_requested`, `_alert_world_pos`), `tests/test_fix_router.gd`,
`tests/test_world_locator.gd`.

### RR-141 — a memory warning spends its step on MEMORY, and a cache shed may not free what a hot path rebuilds

**Ruled.** `AndroidLifecycle.memory_warning` has a listener. The response is two
independent halves plus an ordering: `PerfGovernor.on_memory_warning()` takes
the `far_cull_m` rung, `CityView.shed_caches()` returns what nothing is drawing,
and `game/main.gd::_on_memory_warning` sheds **first** so the chunks the tighter
cull drops are already gone when `apply_governor` re-uploads.

**Not `_step_down`, and this is the ruling.** The governor's ladder is ordered by
**cost per millisecond** — `render_scale` first, because dropping resolution buys
the most frame time for the least visible loss. Android's memory warning is not
about milliseconds. Handing it to `_step_down` would have spent the one step on
resolution and returned **no memory at all**, which would have looked like a
response and been none. The response therefore names its knob (`MEMORY_KNOB =
"far_cull_m"`, doc 11's own prescription) and takes that rung out of ladder
order; it still enters `_applied`, so `_step_up` unwinds it LIFO like any other
and a device that recovers gets its draw distance back.

**What a shed may free.** Only things whose rebuild is *lazy*. `CityView` frees
the FAR node of a chunk that is no longer FAR and the MEDIUM nodes of a chunk
that is no longer MEDIUM, because `_upload_all` creates both inside a tier test
and will not rebuild them until the camera returns; and it evicts merged LOD1
atlas meshes no live node still points at, because `_atlas_for` caches on
`archetype:mask:lod` and **never evicted** — a long session accumulates one
ArrayMesh per mask it has ever shown, and an unreferenced one is pure garbage.

**What it may NOT free, stated because the tempting thing here is wrong.** The
per-(archetype, level) LOD0 bucket nodes are the largest allocation in the view
and freeing them reclaims *nothing*: `refresh()` calls `_upload_all()` every
frame, and that loop calls `_ensure_bucket_node` for every bucket of every chunk
**before** it decides visibility. A bucket freed this frame is rebuilt next
frame, at the cost of a mesh load — so the "shed" would be a per-frame thrash
that reports a big number. Making that creation lazy is a real fix and a change
to a hot path; it is **filed** (below), not smuggled into a memory handler.
Materials and textures are not freed either: live nodes hold them, and rebuilding
an atlas material would drop the overlay paint `set_overlay_palette` wrote into
it.

**The honest floor.** `on_memory_warning()` returns `false` when `far_cull_m` is
already at its 600 m floor, and the shell logs that rather than claiming a step.
A device under sustained pressure gets a truthful `adb logcat` line — which is
the only instrument doc 13 D-12 has, since none of this can be observed from
inside the process that is about to be killed.

**Applied:** `game/render/perf_governor.gd` (`on_memory_warning`, `_apply_rung`),
`game/render/city_view.gd` (`shed_caches`), `game/main.gd` (the connect and
`_on_memory_warning`), `tests/test_memory_warning.gd`.

### 50.1 Measurements

| Command | Number |
|---|---|
| `wc -l game/main.gd` (fork → now) | 2,257 → 2,264 — **the file got 7 lines LONGER**, and §50.3 is why that is the honest result rather than an embarrassing one |
| `git diff 4503d35 --numstat -- game/main.gd` | `67 60` |
| of those 67 added lines, `grep -c '^+[[:space:]]*#'` | **46 are `##` rulings**; 21 are code. Deleted: 60, of which 8 are comment → **52 lines of executable shell removed, 21 added, net −31** |
| `grep -c "sim_host\.sim\." game/main.gd` (fork → now) | 72 → 67 — the metric doc 93 §AI1 argues for |
| `grep -rn "res://game/main" tests/` | 0 — `main.gd` is still not loaded, and the point is that it no longer has to be |
| `grep -rn "sim\._[a-z]" --include=*.gd game ui tools` (fork → now) | 8 → 0 (two comments naming the row) |
| `--file=test_fix_router` | 19 tests, 347 asserts, 0 failed |
| `--file=test_world_locator` | 18 tests, 121 asserts, 0 failed |
| `--file=test_tile_geometry` | 10 tests, 66 asserts, 0 failed |
| mirrors the scan finds (was a hand-list of 11) | **17** — `sim` 5, `game` 7, `ui` 1, `tools` 4 |
| negative control: `flow_test.gd:43 := 8.5` | `failed: 1`, naming `res://tools/flow_test.gd:43` |
| `--file=test_power_infra_feed` | 14 tests, 68 asserts, 0 failed |
| `--file=test_memory_warning` | 12 tests, 41 asserts, 0 failed |
| full suite (`run_tests.gd`, exit code from the redirect) | **138 files, 2,550 tests, 550,725 asserts, 0 failed, 0 silent, exit 0** — the fork's 2,476 plus this lane's 74 |
| `profile_sim --hash-only` starter, coarse 24 h | `05614522975fad52…` = the `4503d35` baseline |
| `profile_sim --hash-only` starter, fine 2.0 h | `d1aaee0dca92f2fd…` = the `4503d35` baseline |
| `--hash-only --city=res://tests/fixtures/bench_city.json`, coarse 24 h | `275aad9d4aeea809…` = the `4503d35` baseline |
| same, fine 2.0 h | `d40126e371371d59…` = the `4503d35` baseline |

All four are the lane brief's `4503d35` baselines, unchanged. Nothing this lane
ships is under `sim/` except `sim/world/tile_grid.gd`, which declares constants
and pure functions and is called by no sim system — `grep -rn "TileGrid\." sim/`
names only its own test.

### 50.2 `awaiting_consumer` — filed, with the owner named

Every row below is a one-line-to-one-function change in a file **this lane does
not own**. None is a blocker for anything shipped above; each closes a hole this
lane's gate can already see.

1. **`ui/build_controller.gd` — `E_AVENUE`'s params half** (lane L, PA-05's other
   half). Add `"fix_target_id": sim_id` to the `E_AVENUE` row of
   `_check_params`. `test_fix_router.gd::test_E_AVENUE_routes_once_its_params_
   carry_the_building` already asserts the router side, and
   `test_the_checklist_sweep_still_finds_the_E_AVENUE_hole` will start failing
   the moment it lands — deliberately, so the two halves cannot drift apart
   silently.
2. **`ui/building_panel.gd:414-416` — the button gate** (lane L). It draws
   `Fix this →` on `kind != FIX_NONE` alone, which is why a row with an empty id
   rendered a live button; the land panel already requires an id, which is why it
   was safe. `FixRouter.can_route(sim, fix_target)` is the gate both should use.
3. **The seventeen mirrored tile constants** (one row per owning lane; PA-76 —
   which counted eight, and the scan in RR-139 is why the number is now exact).
   Each is `const X := 8.0` → `const X := TileGrid.METRES_PER_TILE`, and
   `tests/test_tile_geometry.gd` already fails on drift with the file and line,
   so there is no hurry and no risk in doing them one at a time:
   `IncidentWorld`, `Vehicle`, `WaterEdge`, `TravelTimeProvider` (sim),
   `WeatherSystem` (lane B's neighbourhood), `RoadSurfaceView`,
   `StreetlightPlacer`, `StreetLifeView`, `ConstructionVehicleView`,
   **`ConstructionSiteView`**, **`VehicleView`** (render — the last two arrived
   in `4503d35` after PA-76 was written),
   `BuildController.TILE_M_DEFAULT` (lane L), `AudioEvents._DEFAULT_TILE_M`, and
   four in `tools/` that no lens scanned: **`onboarding_preview.gd:19`,
   `overlay_preview.gd:29`, `construction_preview.gd:41`, `flow_test.gd:43`**.
   Two remaining hand-written footprint→centre formulas live in
   `game/showcase.gd` and `tools/profile_frame.gd`.
4. **`CityView._upload_all`'s eager bucket creation** (lane P or lane O — both
   own parts of `city_view.gd` next wave; RR-141). Move
   `_ensure_bucket_node` **below** the visibility decision so a CULLED or FAR
   chunk's LOD0 buckets are not built at all. That is what would make
   `shed_caches()` able to free them, and it is a per-frame saving on its own.
5. **`main.gd::_on_sim_batch` → `RenderEventRouter`** (lane K, doc 93 §AI3). The
   single highest-consequence extraction left in the shell and the one the
   constitution's "every `Building` event reaches the translator" rule depends
   on. Filed with its gate: every `Building`-lifecycle event named in `data/` has
   an arm in the table.

**Applied:** doc 93 §AI; doc 91 §14.5 (`A91-D-89`, `A91-D-90`); doc 12 §2.7
(D-79).


### 50.3 The file got longer, and the metric that says so is the wrong metric

`main.gd` is **2,264 lines against the fork's 2,257**. Stated without the split
above that reads as a failed extraction, so state it with the split: the lane
**removed 52 lines of executable shell and added 21**, and 46 of its 67 added
lines are the `##` paragraphs that make RR-139/140/141 auditable in the file
they constrain. The net movement of *code* is **−31 lines**, and it happened
while the lane also **added a handler the file never had** — `_on_memory_warning`
plus its wiring is new behaviour (PA-20), not moved behaviour, so it can only
push the count up.

This is exactly the failure mode doc 93 §AI1 was written to head off, and it is
worth being blunt about: **PA-38's "under 1,200 lines" target is not met, is not
close, and is not reachable by extraction.** What moved is the thing that was
actually broken — `grep -c "sim_host\.sim\." game/main.gd` fell **72 → 67**, and
the five reads that left were the three defects PA-05 and PA-76 found plus the
two `_building_records` reach-throughs PA-100 named. A lane that chased the line
count instead would have extracted `_ready` and `_wire_*`, bought a shorter file,
and moved no defect at all.

The follow-on is filed rather than claimed: doc 93 §AI2 ranks the eight
remaining extractions by what a player sees when one is wrong, and item 3
(`_on_sim_batch` → `RenderEventRouter`) is the one that carries the
constitution's own event rule.

## 51. WAVE 18 — the building panel and the requirement contract (binding)

Doc 12 §2.7 calls `Fix this →` *"the single most important teaching device in the
game"*. This wave measured what it actually does, and the answer, on the two
surfaces a new player meets first, was **nothing at all**. The production audit
found the mechanism (99-PA PA-05, PA-23, PA-24); this section rules on the shape
that stops it recurring, because in all three cases the failure was not a wrong
branch — it was a contract with a hole in it that no test could see.

### RR-142 — A `Fix this →` target is `{kind, id, params}`; an id the router cannot resolve is not a target, it is a button that does nothing (docs 12 §2.7a, 99-PA PA-05)

**The finding.** `RequirementFormatter.format()` emitted `fix_target = {kind,
id}`, and the shell resolved `id` per kind. Two of the building panel's seven
checklist rows resolved to nothing:

* `POWER_CAPACITY` set `fix_target_id = grid.attachment_of(sim_id)`, which is a
  **transformer** (`T-06` on the founding city), and routed `FIX_BUILDING`, whose
  branch reads `sim.buildings.get(id)` → `null` → `return`.
* `E_AVENUE` carried no `fix_target_id` at all, so the formatter emitted `id ==
  ""` and the router discarded it on its first line.

*(The audit's third candidate, `E_NO_SLOT`, is **not** one of them and the ruling
below says why: `buildings.has("SUB-A")` is `true`.)* Neither of the two produced
an error, a log line or a haptic. The land panel escaped only
because `land_panel.gd:392` happens to gate its button on a non-empty id as well
as a kind — a second, accidental check that the building panel does not have.

**The ruling.** Every formatted row carries a third field, `params`, and it is
**what the router needs in order to ACT** — a `Vector2i` tile for `FIX_TILE`, a
district key for `FIX_DISTRICT`, a component id for `FIX_COMPONENT`, the
`CitySim` verb for the two purchase kinds. The per-kind table lives in
`ui/requirement_formatter.gd`'s class doc and in doc 12 §2.7a, and it is
**normative in both directions**: a producer that cannot fill a row's `params`
routes `FIX_NONE` and draws no button, rather than shipping one the router will
drop on the floor. `FIX_COMPONENT` is new and exists for exactly this reason, and **which rows
belong in it was measured rather than assumed**: on the founding city
`attachment_of("H-001")` = `T-06`, `buildings.has("T-06")` = `false`,
`component_tile("T-06")` = `(39, 34)`. `E_TRANSFORMER_FULL` and
`E_NEEDS_TRANSFORMER` move there. `E_NO_SLOT` does **not** — its substation is
also a doc 02 shell (`buildings.has("SUB-A")` = `true`), so `FIX_BUILDING`
resolves and doc 12 D-71 already ruled that one deliberate. A contract this lane
first got wrong in the other direction, and the suite caught it: the correction
is recorded here rather than quietly fixed, because "the id looks like a
component" is not evidence and `has()` is.

**Why `params` and not a better id.** Because the two halves are written by two
different lanes and the id alone cannot say which namespace it is in. A tile is
unambiguous, and the row that computed it — `_check_params`, which already walked
the map to write the sentence — is the row that has it. `E_AVENUE` searched
outward to the nearest avenue to print *"no avenue within 4 tiles"* and then
threw the tile away.

**The test**, in three parts, because "normative in both directions" is three
claims. `tests/test_requirement_formatter.gd::
test_every_fix_target_carries_the_params_its_kind_needs` walks every code in
`CODE_TABLE`, asserts the kind is one of `FIX_KINDS`, and asserts the params its
kind's row of the table requires — with `FIX_TILE` strict, because for that kind
the tile **is** the target. `tests/test_build_controller.gd::
test_every_real_fix_target_resolves_or_is_none` is the half PA-05 asked for by
name: the same walk over rows the REAL producers build against a BOOTED sim —
the upgrade checklist on a building broken every way it can be, placement refused
on each wall a player hits, the water block's own ladder — every one of which
resolves to something `ui/fix_router.gd` can act on, or is `FIX_NONE`, never a
silent null.

And `test_the_two_copies_of_the_params_contract_agree` diffs the class doc's
table against doc 12 §2.7a's, kind by kind and key by key. **That test exists
because this lane drifted them inside one wave**: `FIX_BLOCK` gained `block_id`
in `_fix_params_for` and in doc 12 and not in the class doc, which is the copy
Lane D's router is written against. A contract written twice is a contract that
drifts — PA-75's whole finding, one file over — and the only cure that survives
the wave is a test that reads both copies.

### RR-143 — A refusal reaches a touch screen as visible copy with a door, or it does not reach the player at all (docs 12 §2.7, 99-PA PA-23)

**The finding.** `ui/build_sheet.gd:870-879` put the requirement's TITLE on the
placement bar and its BODY — the sentence carrying the remedy — in
`tooltip_text`. Godot shows no tooltip for a touch event, and
`grep -rn -i tooltip game/touch_input.gd game/main.gd ui/ui_root.gd` returns
nothing: there is no long-press-to-tooltip path in this build. So on the device,
`ui_requirement_occupied_remedy` and every other remedy string was **unreachable
from placement**, which is the first thing a new player does. The bar also had no
`Fix this →` at all, and the commit-refusal fallback wrote into
`Sheet/Body/Notice`, a child of the sheet that `_on_card_pressed` had already
closed.

**The ruling.** A tooltip is an accelerator for a pointer, never the carrier of a
reason. Any surface that refuses an action states the reason **in visible copy**,
and if the reason has a `fix_target` whose kind is not `FIX_NONE`, it offers a
48 dp door to it. The tooltip may keep the same text; it may not be the only
place the text appears. This is doc 12 A14 (*"every blocked action states its
reason in words"*) restated as a mechanical rule, because A14 was satisfied on
paper by a string that existed and could not be read.

**The general form.** A string that only a mouse can reveal is a string this game
does not have. Any lane adding copy to `tooltip_text` writes it to a visible
control in the same commit.

### RR-144 — A gate the command raises and the checklist does not list is a silent gate, and the list is checked against the command's own source (docs 02 §2.11, 12 §2.9, 99-PA PA-24)

**The finding.** `CitySim.cmd_upgrade_building` appends seven blocker codes.
`BuildController.UPGRADE_CHECKS` listed six. The seventh, `E_WATER_HEADROOM`, is
a real gate (`water_system.gd:824-837`) and had **no row, no `CODE_TABLE` entry
and no string** — so a building blocked on water alone drew six green ticks,
printed *"Every requirement met."*, and left `UPGRADE` disabled with nothing on
screen to act on. Had the code ever reached the formatter it would have folded to
`UNKNOWN` and printed the identifier `E_WATER_HEADROOM` at the player.

**The ruling.** Two hand-maintained lists that must agree, and no test between
them, is a defect waiting for a wave. The checklist is now verified against the
**command's own source**: `tests/test_build_controller.gd::
test_every_upgrade_blocker_the_command_raises_has_a_row_and_copy` extracts every
`blockers.append(&"…")` from `cmd_upgrade_building`'s body and requires each code
to be (a) in `UPGRADE_CHECKS`, (b) `RequirementFormatter.is_known()`, and (c)
carrying both a body and a title string. A doc-02 gate added without its surface
now fails the suite in the commit that adds it.

**Scope.** The rule is written for the upgrade gate because that is where the
hole was found; the same shape applies to any command whose preview returns a
`blockers` array that a checklist mirrors.

### What the shell must connect (two lines in `game/main.gd`, the lead's file)

The lane is inert in the shipped shell without them, and both are one line:

1. **`ui_root.build_fix_requested.connect(_on_fix_requested)`**, beside
   `ui_root.land_fix_requested.connect(_on_fix_requested)`. `BuildSheet` emits
   `fix_requested` and `UIRoot` re-emits it the way it re-emits the land panel's;
   nothing in the tree connected the sheet's, which would have made PA-23's door
   a button with nothing behind it — PA-05's own defect one layer up, on the
   surface this wave had just given a button to. `tests/test_build_controller.gd::
   test_the_placement_bar_offers_fix_this_with_a_routable_target` asserts the
   re-emission; only the shell's own `connect` is outside the suite.
2. **`ui_root.report_dispatch_result(unit_id, bool(r["ok"]), r)`** — the third
   argument is the whole `CommandQueue` answer, and without it the picker still
   has only `ok` and still answers doc 06's three refusals with one sentence
   (PA-52). The parameter is optional, so the two-argument call compiles and
   keeps today's behaviour; that is the point of the default and the reason this
   is a snippet rather than a break.

### The finding that was not this lane's, and was closed anyway

**`hud_banners` at 412 × 915, 130 % text + larger targets.** `HUDLayer/
AlertStack/Alert1/Row/View` P(296, 296) S(94, 76) covered **1,155 px²** of
`HUDLayer/TiltSlider/Thumb` at P(335, 351) — the *only* finding standing between
this deck and `--screen=all --audit --strict` exit 0 across **all six `BOXES` ×
both accessibility settings**, the other eleven cells clean. It is **pre-existing
at the fork**: Wave 17 added the tilt column (doc 12 §2.23) and solved its band
against the top bar and the drawer handle, and §2.4's banner stack — the third
thing on that edge — was never a measurement point. Nothing in Lane L's diff
touches either surface (`git diff 4503d35 -- ui/ui_root.gd` is PA-52's
`report_dispatch_result` signature and nothing else).

**It was closed here regardless, and the ruling is why.** A lane that owns "the
refusal is reachable" and hands back a deck where a 48 dp target sits on another
48 dp target at the accessibility setting has not finished; and the fix is
three lines in the function whose whole job is already this — `solve_tilt_slider`
starts the band under the top bar's first row and above the drawer handle's
reservation, so the banner stack joins them as a third measurement point. The
band starts under the **lowest banner actually on screen**, and only when that
banner's right edge is inside the column: at 794 dp the stack is `alert_dp`'s 400
wide and centred, never reaches the edge, and the band does not move. Measured,
same cell, after: the column P(335, 267.5) → P(335, **416.5**), the thumb 351 →
**500**, twelve sweeps exit 0. Headless the guard is inert — a mount with no
frames lays nothing out, which is why `tests/test_ui_tilt.gd`'s authored-band
assertions are untouched and still pass.

**One finding this lane surfaced and did not own.**

1. **The side panel could grow wider than the screen and nothing could see it.**
   Fixed here because PA-47 could not land without it (`SCROLL_MODE_SHOW_NEVER`
   plus the shed row's `HFlowContainer`), but the *class* of defect is wider than
   this panel: `UIAudit` exempts everything inside a `ScrollContainer`, which is
   correct for content and wrong for the container's own outer geometry. Every
   deck surface whose only child is a scroller with `SCROLL_MODE_DISABLED` has
   the same blind spot. A check that measures a scroller's own laid-out rect
   against the viewport would find the rest of them; this lane did not write it.

### Measured at the branch tip

| claim | command | number |
|---|---|---|
| the suite | `tools/run_suite.sh` | 133 files, **2,492 tests**, 550,118 asserts, failed **0**, silent **0**, exit **0** |
| the deck | `--screen=all --audit --strict`, six `BOXES` × {100 %, 130 % + larger targets} | **12 sweeps, 68 states each, exit 0 in every one** |
| the sim | `profile_sim --hash-only`, starter and `bench_city.json` | all four digests **byte-identical to `4503d35`** |

The third row is the one that says what kind of wave this was: every finding in
this section was a **surface** that disagreed with a sim that was already right.
Nothing here needed a number to move, and none moved.

**Applied:** doc 12 §2.7a (the params table), §2.9 (the seventh row, the four
live coverage tiles, the pinned actions footer), §2.7 (the placement bar's second
line and its door) and §2.23 (the band's third measurement point); doc 91 §14.5
(`A91-D-91`, `A91-D-92`); doc 92 §51 (the founding city's first coverage
readings); doc 93 §AJ; doc 12 deltas `D-80`, `D-81`.


---

## 52. WAVE 18 — the settings screen tells the truth: a file that is written, an ask that is earned, and a word that finally means something (binding)

*Lane G, production audit PA-14 / PA-15 / PA-58 / PA-59 / PA-84, at fork
`4503d35`. Five rows, and four of the five are the same defect wearing different
clothes: **a control, a default or a clause that the code declares and nothing
consumes**. `user://settings.cfg` was a path with no caller; `PermissionFlow`
was a complete state machine with no caller; `follow_dispatched_unit` and
`set_follow_target` were a default and a method with no caller;
`auto_spend_contractor` wrote a key with no reader; `auto_speed_reset` was a
function with no caller. Doc 93 §AK carries the mechanics argument; doc 12's
D-82/D-83 carry the surface changes.*

### RR-145 — The device file's ordering rule belongs to the MODEL, not to the shell

**Ruling.** *"On load `settings.cfg` wins for those keys"* (doc 12 §3.2) is
enforced at the **end of `SettingsModel.restore_state()`**, which re-applies the
device copy after the incoming block, rather than at each call site that
restores one.

**Why it is a ruling and not a detail.** The shell restores the `ui` section
from at least four places — the resumed save at boot, a mid-session load
(`_on_ui_save_loaded`), the title door's CONTINUE, and New City's empty block —
and every one of them is a place the rule could be forgotten. A rule that has to
be remembered four times is a rule that will be right three times: the shipped
build restored settings only when `_resumed_slot >= 0`, which is precisely one
of the four. Putting the re-apply inside the one function all four already call
makes the ordering a property of the model instead of a property of the caller's
memory. **The generalisable shape: when a precedence rule has N enforcement
sites, move it under the one thing all N already go through, or it is not a rule
— it is a convention.**

**Consequences.** `_on_title_new_game` restores `{}` rather than restoring
nothing, which is now a *statement*: the city-scoped rows go back to data
defaults because they belonged to the city that just left, and the device-scoped
ones do not move. `game/device_settings.gd` is a section registry with
merge-read-write and tmp+rename, so doc 12's rows and doc 13's permission
counters share one file without either write losing the other. PA-15's own fix
column also asks for the notification budget's last-sent stamps in this file;
**that half is declined** — doc 08 §2.5 rules those roll-back-able runtime state
and keeps them in the save's `notifications` section, and the audit's fix column
does not outrank the owning document.

### RR-146 — BACK is not an answer, and the ask is worth more than the permission

**Ruling.** The `POST_NOTIFICATIONS` rationale modal has **three exits and they
are not the same exit**: TURN ON opens the system dialog, NOT NOW calls
`decline()` and spends one of Android's two lifetime chances, and **BACK closes
the sheet and spends nothing**.

**Why.** Android 13 makes the *ask* the scarce resource, not the permission: two
dismissals and the system dialog never appears again for the life of the
install, with no route back except the app's own page in system settings. Doc 12
§2.2 makes BACK the universal "close the thing in front of me" — it is pressed
reflexively, out of habit, by a player who has not read anything. Counting that
as a refusal would burn an irreplaceable chance on a gesture that carried no
opinion. So `PermissionSheet.answered` is emitted by the two buttons and never
by `close()`, and the asymmetry is pinned by
`test_back_costs_nothing_and_the_two_buttons_each_cost_a_chance`.

**The trigger is the other half of the same ruling.** Doc 13 §2.7 step 1 names
"the first construction timer"; the shipped trigger is `upgrade_started_sim` or
`incident_resolved`, and **`building_placed_sim` is deliberately excluded** even
though it creates a construction timer too — the tutorial has the player place a
house inside its first minute, and asking there is the cold prompt §2.7 forbids
with extra steps. The counters are device-scoped for a correctness reason rather
than a tidiness one: two dismissals are spent per INSTALL, so a counter in the
city's save would let a deleted city hand the app a third prompt that Android
will not honour — a modal that opens a dialog which never appears.

**Not verified on hardware.** Every claim here is code, data and headless
suite. `dumpsys notification` after a pause is what this ruling is owed, and doc
99 §4.1 already lists it.

### RR-147 — A clause that says "critical" without saying which is not implementable, and the measurement is what closes it

**Ruling.** Doc 01 §2.9 / doc 12 §2.11's `auto_speed_reset_on_critical` resets
speed on **exactly three authored events** — `incident_failed`,
`credit_limit_reached`, and `flood_level_changed` at band `flooded` — with a
**thirty-real-minute re-arm**, both in `data/ui.json.speed`.

**Why the docs' own wording could not ship.** They said "a P1 notification".
Taken literally that is the whole P1 class, and the P1 class is not rare: on the
curriculum path, 21 game-days, seeds 1337/4242/9001, the P1 stream that matches
those three types alone is **0 / 138 / 161** events — and 504 game-hours is 8.4
real hours at 1× (constitution §4), so the literal reading forces **19.2 speed
resets per real hour** on the worst seed. A game that takes the speed control
away every three minutes has not implemented a safety feature; it has
implemented a fault. That is the reason the function sat uncalled for seventeen
waves, and *"nobody got round to it"* was the wrong diagnosis.

**What the re-arm buys, and why it is not the ten minutes PA-84 asked for.** The
audit's fix column prescribes "a 10-real-minute re-arm" and its target in the
same sentence: ≤ 1 forced reset per real hour. **Those two are inconsistent, and
only a measurement could have said so.** Eleven curriculum seeds, 21 game-days:

| re-arm | worst seed | forced per real hour |
|---|---|---:|
| 600 s — the audit's suggestion | 8888 | **1.071, over its own bar** |
| 1200 s | 3141 | 0.952 |
| **1800 s — shipped** | 3141 / 1234 | **0.714** |

**The seed that breaks ten minutes is the one that explains the whole shape.**
8888 has the FEWEST raw triggers of the eleven (41) and, at 600 s, the MOST
forced resets (9): its crises are *spread out*, which is exactly the case a short
re-arm cannot coalesce. A burst is what a short re-arm is good at; a drizzle is
what it is useless against, and a drizzle is what annoys. So the lever that
closes the bar is silence, not selectivity — and this is the second time in this
section that the naive reading of a doc sentence produces the failure the feature
was written to prevent.

`tools/measure_speed_resets.gd` prints both columns, takes `--rearm=N` so the
lever can be swept without editing the data file, and exits non-zero above the
bar — so the bar is a runnable claim rather than a sentence.

**Where the margin should be spent if a future seed crosses it.** On
`auto_speed_reset_rearm_real_s`, never on the trigger list. Dropping a trigger
leaves a crisis the player cannot fix at 3× unannounced, which is the failure the
feature exists to prevent; lengthening the re-arm only repeats something already
true — that the wheel was handed over once for this crisis.

**The generalisable shape.** A spec clause whose subject is an undefined
adjective — *critical*, *significant*, *nearby* — is not a feature that has not
been built yet. It is a decision that has not been made, and the honest close is
to make it **in data, with the measurement that justifies the number beside it**
— never to implement the literal reading and let the playtest find out.

## 53. WAVE 18 — money has surfaces: the taper says when it ends, the wear says what it costs, and the city repairs what it owns (binding)

*Filed 2026-09-02 against 99-PA §3.2 Lane S (rows PA-31 surface half, PA-32,
**PA-33 REPAIR HALF**, PA-83). **PA-33 is half, and the filing line said
whole until a verifier read the row against the tree.** The row names two
targets — at most 20 manual REPAIR taps and at most 30 manual UPGRADE taps per
45-day arc — and two fixes; this lane shipped the repair policy and no batch
upgrade exists anywhere in the tree (`grep -rn "upgrade_all\|Upgrade all"
--include=*.gd --include=*.json .` → nothing). The upgrade half lives on
`ui/build_sheet.gd` / `ui/build_controller.gd`, which Lane S does not own, and
is handed to **Lane L** with this note. Corrected at merge rather than merged
as written, because closing an audit row that is still half open is how a
ledger stops meaning anything. Baselines re-recorded at the lane fork `d0d114f` and unmoved at
delivery — see §53.5. Every number below is a command in this section.*

**The shape of all four rows is one shape.** The Wave-17 economy dial-in made the
money HONEST: the repair fell on the owner (doc 93 §Y1), the founding grant's
window was published into the settle snapshot (RR-102), the upgrade ladder became
an identity (§Y7). None of that put a number on a screen. The audit's Lane S is
therefore not a tuning lane at all — every row is a computed value with no
consumer, and the fix is a consumer:

| row | the value the sim already had | where it now lands |
|---|---|---|
| PA-32 | `founding_assistance_days_left` (RR-102) | `assistance_stepped` ×8 per city; the Economy tab's assistance note |
| PA-31 | `Building.condition` crossing doc 02 §2.6's bands | `building_condition_band`; the Economy tab's **Upkeep** band |
| PA-33 | `cmd_repair_building`, one building at a time | `cmd_set_building_repair_policy` + `cmd_repair_all_worn` |
| PA-83 | `development_phase_charged` | a doc 12 economy log row |

### RR-148 — A scheduled taper announces its OWN schedule, once per step, and only the last step is a notification

**The finding (99-PA PA-32).** Doc 03 §2.5a's founding assistance retires
`FOUNDING_ASSISTANCE_PER_HOUR / FOUNDING_ASSISTANCE_DAYS` = **$589.71 a game-day**
for seven game-days. Measured on the coarse curriculum arc, `do_nothing` net falls
517 → 266 $/gh across the same window and the taper is the largest single mover in
it. At the Wave-17 fork the whole surface was `ui/budget_model.gd`'s
`"ends in {days} days"` on a row inside a sheet — a count, on a screen the player
has to open, with no rate and no end date.

**Ruled.** A change the game has *already scheduled* is owed a statement at each
step, and the statement must carry **the rate, the end day and the days left** —
the three numbers the sentence needs — because a count alone does not tell a
player what the next step is going to cost them.

**And the corollary that keeps it cheap: only the LAST step is a notification.**
Seven pushes about a number going down on a published schedule is the doc 08
budget spent on a thing the player cannot act on. So `assistance_stepped` fires
eight times per city and exactly one of them (`final: true`, the game-day the
grant is gone) carries a `data/notifications.json` binding; the other seven are
`data/ui.json.event_log` rows and nothing else. That is the audit's own target —
*1 toast + 7 log rows per city* — reached by construction rather than by a budget
rule.

**Hash-neutral by construction.** The step is detected by asking `CostCurves` what
YESTERDAY's published share was, so `EconomySystem` remembers nothing between
hours, serializes nothing new, and `state_hash()` cannot move for it.

*Verification:* `tests/test_money_surfaces.gd`
`test_pa32_the_taper_steps_once_a_game_day_and_says_when_it_ends`,
`test_pa32_each_step_is_the_published_daily_retirement`,
`test_pa32_the_economy_row_carries_the_rate_and_the_end_day`,
`test_pa32_both_steps_reach_a_surface`.

**Applied:** `sim/economy/economy_system.gd` (`_publish_assistance_step`),
`ui/budget_model.gd`, `ui/city_dashboard.gd` (ledger notes),
`data/ui.json.event_log`, `data/notifications.json`, `data/strings.en.json`;
doc 03 §2.5a, doc 12 §2.10 (D-84), doc 93 §AL.

### RR-149 — Wear that costs money is reported as MONEY, in one band, and the band names the repair that ends it

**The finding (99-PA PA-31, surface half).** An untouched city loses 53 % of its
non-subsidy income in 20 game-days from decay alone; at the Wave-17 fork nothing
said so until a building reached `damaged` at 0.35 — and after doc 93 §Y1's
ownership floor **a private building the city keeps SERVED never gets there**
(§Y1a lifts the floor only for an owner left in the dark), so on the path a
player actually plays the only cue that ever existed is unreachable by
construction. Two instruments size the silence:

* `tools/measure_repair_burden.gd --days=45 --seeds=1337 --strategies=curriculum`
  counts **321 downward crossings of 0.85, 0 of 0.60, 0 of 0.35**, ends with
  **185 private buildings sitting worn**, and reports **118 repair-family events
  reaching no surface at all**.
* A 60-game-day `do_nothing` starter run emits **37 Worn and 11 Poor** crossings
  and **zero** `building_damaged` — forty-eight moments at which the city got
  poorer and nothing on any screen moved.

**Ruled, in two halves.**

*(a) The crossing is an event.* `building_condition_band` is emitted on a
**downward** crossing of doc 02 §2.6's `band_good` (0.85) and `band_worn` (0.60) —
the two lines the band table already draws, read out of `building_rules.json`, not
restated. Downward only: a building climbing back through a band is the player's
own repair or upgrade finishing, and the screen that issued it already knows
(doc 93's event rule, `player_initiated`). Worn is a doc 12 log row, aggregated;
Poor is a P3.

*(b) The consequence is a BAND on the Economy tab, denominated in dollars.* A
count of worn buildings is not a reason to act. `(1 − f_condition) × tax` is: it
is the money the city is not collecting this hour because its stock is worn,
computed off doc 03's own per-building settle rows and off nothing this lane
authors, printed beside **the repair quote that would end it**. That pairing is
the whole ruling — *the loss and the price of stopping it, on one screen*, which
is the audit's stated target for this row.

**Hash-neutral by construction.** The band is derived from `condition` before and
after the hour's own decay call. No band is stored, so nothing new is serialized,
and the Upkeep band is a read of `last_settlement` plus `preview` quotes — no
dollar moves to draw it.

*Verification:* `tests/test_money_surfaces.gd` `test_pa31_*`.

**Applied:** `sim/city_sim.gd` (`apply_hourly_decay`), `ui/dashboard_model.gd`,
`ui/city_dashboard.gd`, `data/ui.json.event_log`, `data/notifications.json`,
`data/strings.en.json`; doc 02 §2.6, doc 12 §2.10 (D-84), doc 93 §AL.

### RR-150 — The city repairs what it OWNS under a policy, the way roads already do; the default is manual, and that is what keeps the matrix still

**The finding (99-PA PA-33).** Roads have `cmd_set_auto_repair_policy` and a
settings row (doc 10 §2.13, doc 93 §J3); buildings had `cmd_repair_building(sim_id)`,
one call per building, and nothing ruled them manual. The audit measured 211–245
repair taps per 45-game-day arc. **That number has already fallen**, and this
ruling records the new one rather than the one that motivated it: after doc 93
§Y1 moved private stock to its owners, `tools/measure_repair_burden.gd --days=45
--seeds=1337 --strategies=curriculum` counts **51 civic repair trips and $226,852
of civic repair** on the same arc — 0 private, because there is no private repair
left to buy. So the row is smaller than filed and it is the same row: 51 taps is
still one every ~21 game-hours, on buildings the city unambiguously owns, for a
decision that has exactly one sensible answer.

**Ruled.** `cmd_set_building_repair_policy(threshold, daily_cap)` and
`cmd_repair_all_worn(preview)`, mirroring roads:

1. **The threshold ladder is doc 02's own band table**, resolved through
   `BuildingCatalog` — `0.0` (off), `band_worn`, `band_good`. A policy dial that
   authored its own condition constants would be the second copy doc 02 §2.6
   exists to prevent, and `E_BAD_THRESHOLD` is answered for anything else exactly
   as `RoadNetwork` answers it.
2. **The daily cap is doc 03's**, because it is dollars (C-07). It is a player
   *budget*, not a price: the pass never invents a number, it asks
   `cmd_repair_building(sim_id, true)` for each quote and stops at the cap.
3. **Only what the city owns.** `owner_maintained` buildings are skipped, and not
   as an optimisation — `cmd_repair_building` refuses them with
   `E_OWNER_MAINTAINED`, so a policy that tried would be a policy that spends its
   whole pass being refused.
4. **The default is `off` / manual.** A city that never opens the control behaves
   exactly as it did at the fork: no candidate is selected, no quote is taken, no
   dollar moves, and the policy is omitted from the city section entirely, so
   `capture_state()` is byte-identical and **the four `profile_sim` baselines do
   not move** (§53.5). A default of *auto* would have been a balance change, would
   have moved every gate, and is not what a surfacing lane is for.

**And the batch verb is the same pass, run once, by hand.** `cmd_repair_all_worn`
is what the Upkeep band's *"Repair all worn (N) — $X"* button presses; it shares
one implementation with the daily policy pass, so the button and the policy can
never disagree about which buildings are candidates or what they cost.

*Verification:* `tests/test_money_surfaces.gd` `test_pa33_*`.

**Applied:** `sim/city_sim.gd` (`cmd_set_building_repair_policy`,
`cmd_repair_all_worn`, `building_repair_policy`, `run_building_repair_policy`),
`data/economy.json` (`building_repair`), `ui/dashboard_model.gd`,
`ui/city_dashboard.gd`; doc 02 §2.6, doc 03 §2.5, doc 12 §2.10 (D-84), doc 93 §AL.

### RR-150a — The verb gets a DOOR, and it is on the band that reports the loss

**The finding, against this section's own first draft.** RR-150 shipped
`cmd_set_building_repair_policy`, its ladders, its refusal code, its save rung and
its daily pass — and no way for a player to call it. The Upkeep band *reported*
the standing policy in a sentence; a command with no control is 99-PA's own
PA-55 shape ("verbs get doors") filed against the lane that had just written the
verb. Doc 99 §3.2 assigns Lane S `data/ui.json settings.rows` for it, and the
first draft of D-84 declined the row for a sound reason — §2.13's plumbing
(`SettingsModel.POLICY_*`, `UIRoot._write_*_policy`) belongs to Lane G this wave,
and a row appended without the arm would be **stored, written to the device
settings file and never reach the sim**, which is RR-1's control-that-lies. That
reasoning is kept; the conclusion "therefore no door" is not.

**Ruled (doc 93 §AL3a).** The door is **two cycling faces on the Upkeep band**,
under the sentence that reports them:

1. **Both ladders are the sim's.** `building_repair_policy()` publishes
   `thresholds` (doc 02 §2.6's band table, resolved off a real building's stamped
   rules) and `daily_caps` (doc 03's `AUTO_REPAIR_DAILY_CAPS`), and
   `DashboardModel` forwards both **verbatim** — it picks no rung and authors no
   dollar. Feed it a ladder doc 02 never wrote and it offers that one, which is
   the test that proves the model has no opinion of its own
   (`test_door_the_control_never_authors_a_band_or_a_dollar`). So no sequence of
   presses can produce a pair the command answers `E_BAD_THRESHOLD` for
   (`test_door_every_face_it_can_show_is_a_rung_the_command_accepts`: 6 + 10
   presses, 0 refusals).
2. **A press writes the PAIR**, because `cmd_set_building_repair_policy` takes
   the pair, exactly as `UIRoot._write_road_policy` does for doc 10's control.
3. **Switching on supplies a budget** — doc 03's own `AUTO_REPAIR_DEFAULT_DAILY_CAP`,
   newly published on `building_repair_policy()` so `ui/` reads it rather than
   restating it (C-07). Switching off keeps it. §AL3a is the argument.
4. **A shell that binds three wires and not the fourth draws the sentence and no
   dials** — `bind_upkeep`'s fourth parameter is optional and the read-only band
   is a shipped state, asserted rather than promised
   (`test_door_a_shell_that_binds_no_verb_draws_no_control`).

**And the row's own first press found a live use-after-free in the button RR-150
had already shipped.** Every control on the Upkeep band lives *inside* the
subtree a refresh rebuilds, so `refresh()` called from a `pressed` handler frees
the button while its own signal is still on the stack — Godot's *"Object was
freed or unreferenced while a signal is being emitted from it"*, which the tab
buttons never hit because they sit outside `_content`. `Repair all worn` had this
from the moment it was written and no test had ever pressed it, because until
this row nothing mounted the dashboard. The fix splits the two halves: the
**reading** refreshes synchronously (the next press must see it) and the
**nodes** rebuild once the emission has unwound (`_reread_upkeep_after_press`).

**And the row's target is now measurable, because a policy no player can stand
cannot be measured.** `tools/measure_repair_burden.gd --auto-repair=` stands the
pair the way the dial does; on the 45-game-day curriculum arc, seed 1337, the
manual tap count falls **51 → 3** at `band_good` for **+0.11 %** of repair
spend ($226,852 → $227,109). The audit asked for ≤ 20. Doc 92 §52.4a carries the
table, including the finding that rung 1 (`band_worn`, 0.60) buys nothing on a
played arc because doc 93 §Y1's ownership floor IS 0.60.

*Verification:* `tests/test_money_surfaces.gd` `test_door_*` — six tests that
mount the real `ui_root.tscn`, bind a real `CitySim` and press the real buttons.
`tools/ui_preview.gd` gains `economy_upkeep_auto`, the policy-ON state a
screenshot of the shipped default can never show, and it is the state that caught
the control's first layout: `Automatic repair  below 85%  $10,000/day` is 300 dp
on a 360 dp screen at `--text-scale=1.3`, and the audit reported the whole panel
pushed off the viewport. The row label is dropped (the sentence above is the
label, the faces name themselves to a screen reader) and both faces clip. Both
audits exit 0 at 412×915 and at 360×800 `--text-scale=1.3 --large-targets`.

**Hash-neutral.** The only `sim/` change is one derived key on a dictionary
nothing serializes; the default pair is still `off / no budget`, so §53.5's four
baselines are unmoved.

**Applied:** `ui/city_dashboard.gd`, `ui/dashboard_model.gd`, `sim/city_sim.gd`
(`building_repair_policy`'s `default_daily_cap`), `data/strings.en.json`,
`tools/ui_preview.gd`, `tests/test_money_surfaces.gd`; doc 12 §2.10 (D-84),
doc 93 §AL3a.

### 53.4 PA-83 — the six silent debits, and the two defects the wiring found

Land development charges the treasury **six times per block**, $1.2K to $21K a
phase, 14–15 times per 21 game-days on a curriculum run, and
`development_phase_charged` had **zero shell consumers**. It has a doc 12 log row
now — *"Grading started on Block E4 — $4,770"* with a camera jump — and nothing
louder, because the player pressed DEVELOP and doc 03 §2.8 published the
schedule: this is a receipt, not news. The phase resolves through the same
`ui_land_phase_*` copy the land panel's progress line uses, so no surface prints
`road_install` at a player.

The one sim-side change it needed is a name, not a number: the alerts centre's
locator contract is `(&"block_id", id)` and the event carried the id as `block`,
so the payload now names it **both ways** rather than the router guessing. That
is not gold-plating — writing this row is what turned up **`A91-D-95`**: the
`block_ready` row already in the same table makes exactly that mistake and has
been rendering a **blank title with a dead jump** on the log's most celebratory
line. `data/notifications.json` has the same binding written correctly, with a
`_comment` recording the fix, so the log half was simply missed. Neither that row
nor **`A91-D-96`** — the gate that cannot see this class, because it proves a
placeholder has a *declaration* and never a *value* — is fixed here: both live in
Lane K's table and Lane K's gate (99-PA §3.0 rule 1).

**And the full suite made the lane delete its own excuse.**
`tests/test_event_matrix.gd`'s register carried an exemption for this event —
*"bookkeeping: money moving. Spend belongs in the budget sheet's ledger, not in
the alerts feed"* — and `test_the_register_names_a_consumer_that_is_no_longer_needed`
failed the moment the log row landed. The exemption was not merely stale: **the
budget sheet's ledger does not itemise these debits either**, so the sentence was
covering a dollar that reached no surface at all, which is precisely what PA-83
measured. The entry is gone and the reasoning that replaces it is a comment
naming the row. That half of the gate — the one that fails when an exemption
becomes unnecessary — is the reason a `_comment` in a register is not a place a
wrong answer can hide.

### 53.5 Baselines

Re-recorded at the lane fork `d0d114f` (`~/.local/bin/godot --headless --script
tools/profile_sim.gd -- --hash-only`, and again with
`--city=res://tests/fixtures/bench_city.json`) and re-taken at delivery:

| city | pass | fork `d0d114f` | after Lane S |
|---|---|---|---|
| starter | coarse 24 h | `05614522975fad52…` | unchanged |
| starter | fine 2.0 h | `d1aaee0dca92f2fd…` | unchanged |
| bench | coarse 24 h | `275aad9d4aeea809…` | unchanged |
| bench | fine 2.0 h | `d40126e371371d59…` | unchanged |

**No hash delta, so no `awaiting_consumer` row and nothing for the matrix holder
(Lane B) to re-fit.** That is a deliberate constraint on the lane and not a happy
accident: RR-148's step detection is stateless, RR-149's band is derived, and
RR-150's policy is omitted from the save at its default.

### 53.6 Delivered, and what the lane hands on

| gate | command | result |
|---|---|---|
| the lane's own tests | `run_tests.gd -- --file=test_money_surfaces.gd` | 36 tests, 218 asserts, **0 failed** |
| the full suite | `run_tests.gd` | 134 files, 2,512 tests, 551,886 asserts, **0 failed**, exit 0 |
| the deck, portrait | `ui_preview --screen=all --size=412x915 --audit --strict` | **exit 0**, 69 states clean |
| the deck, small + A2/A3 | `… --size=360x800 --text-scale=1.3 --large-targets --audit --strict` | **exit 0**, 69 states clean |
| determinism | `profile_sim --hash-only` ×2 cities | all four §53.5 baselines **unmoved** |
| doc integrity | `python3 tools/check_doc_refs.py` | 3,874 references, all resolving, no id twice |

**Three things the lane found rather than shipped**, each recorded above with the
gate that caught it: `A91-D-95` (a blank log title and a dead jump on
`block_ready`, for Lane K), the Upkeep band's use-after-free (RR-150a, fixed
here because the button was this lane's), and `test_event_matrix.gd`'s stale
`development_phase_charged` exemption (§53.4, deleted here).

**Two things it hands on.**

1. **The shell binding — LANDED at merge, and written down here because a
   snippet that lives only in a delivery note is a snippet that is lost.**
   RR-116's precedent put its `main.gd` wires into doc 98 §43.4; this one was
   in a chat message and nowhere else, which a verifier held the merge on.
   Inserted immediately after `root.bind_recall(sim_host.sim.cmd_recall_unit)`:

   ```gdscript
   	if root.city_dashboard != null:
   		root.city_dashboard.bind_upkeep(
   				func(preview: bool = false) -> Dictionary:
   					var quoted: Dictionary = sim_host.sim.cmd_repair_all_worn(preview)
   					if not preview and bool(quoted.get("ok", false)):
   						flush_sim_events()
   					return quoted,
   				sim_host.sim.building_repair_policy,
   				func() -> float: return float(sim_host.sim.treasury.balance),
   				sim_host.sim.cmd_set_building_repair_policy)
   ```

   Four wires: the batch verb (preview and commit are one Callable with a
   different first argument), the standing policy, a treasury reading so an
   unaffordable batch shows its price on a disabled face instead of vanishing,
   and the policy verb the band's dials write through. The batch is WRAPPED in
   `flush_sim_events()` for RR-108's reason — the command emits from inside
   itself and the only live drain does not run while the game is paused, so
   repairs a paused player just bought would not reach the renderer until they
   un-paused.
2. **The §2.13 settings row** (doc 12 D-84's note), which lands the moment Lane
   G's `POLICY_BUILDINGS` arm exists. Not a blocker: D-84 (d) is the door.

---

## 57. WAVE 18 MERGE — the seam two lanes could not see (binding)

**Lane D's completeness gate earned its keep on the day it landed.** Merging
Lane D (the fix router) and Lane L (the requirement contract) each passed its own
suite; the merged tree failed 35 assertions in `tests/test_fix_router.gd`, in two
shapes, on every building in the starter city.

### RR-158 — A declared fix kind that no router maps is a button that answers `unknown_kind`

`RequirementFormatter.FIX_COMPONENT` was declared by the power wave and used by
Lane L's `E_TRANSFORMER_FULL` / `E_NEEDS_TRANSFORMER` rows. `FixRouter._locator_kind`
— written by Lane D, from a tree where those rows did not exist — had no arm for
it, so it returned `&""` and the route answered `unknown_kind`. Neither lane was
wrong on its own; the mapping was the piece no lane owned. Fixed by mapping it to
`WorldLocator.KIND_COMPONENT` and adding it to the focus arm's match list.
`test_every_declared_fix_kind_is_routed` is exactly the gate that says so, and it
is worth keeping BECAUSE it fails at a merge rather than in a player's hands.

### RR-159 — "Component" is two namespaces, and "district" is sometimes a third

`WorldLocator.locate_component` asked doc 04's `PowerGrid` only. Doc 05's water
nodes (`WTR-1-PMP`, tanks, treatment, sources) are addressed the same way by the
checklist, so every water component resolved to nothing. Water is now asked
first, then the grid; the ids are disjoint and the order is stated.

The second half is subtler and is the reason all 35 rows failed rather than a
few. `E_WATER_HEADROOM`'s `fix_target_id` is the **pressure-zone key**, and doc 05
keys a zone by its SOURCE NODE — so the row honestly declares `FIX_DISTRICT` (the
remedy is "add a pump or a tank in this area") while carrying an id doc 09's
district table has never heard of. The district arm now falls through to
`locate_any()` when the district table does not know the id, which is the same
fallthrough the building arm already took, for the same reason, written down in
the same words: **the id came from the sim, and the sim knows what it is.**

**The rule this leaves.** A fix row's `kind` says what the remedy IS; it does not
promise which table the `id` lives in. A locator arm that cannot find its id in
its own table asks the others rather than returning null, and a `FIX_*` with no
locator mapping fails loudly at a gate. Both halves are pinned by Lane D's two
tests, which is why this cost one merge and not one playtest.

## 56. WAVE 18 — the restore: a door that was never cut (binding)

*The restore lane, forked off the Wave-17 integration, 2026-09-02.
**Hash-neutral throughout**, proved on both cities at the fork and again at the
end: everything this lane adds to `sim/` is reachable only through a PLAYER
VERB, and a player verb moves no baseline.*

*This section closes the sixth instance of `A91-D-19`'s shape — authored,
documented behaviour with no caller — and the sixth is the one a player found
from the outside, in their own words, on their own city: "I have many buildings
that are destroyed that I can't actually fix even if I upgrade power."*

| `profile_sim --hash-only` | at the fork | after this pass |
|---|---|---|
| starter, coarse 24 h | `05614522975fad52…` | **`05614522975fad52…`** |
| starter, fine 2.0 h | `d1aaee0dca92f2fd…` | **`d1aaee0dca92f2fd…`** |
| bench, coarse 24 h | `275aad9d4aeea809…` | **`275aad9d4aeea809…`** |
| bench, fine 2.0 h | `d40126e371371d59…` | **`d40126e371371d59…`** |

### RR-155 — `cmd_restore_building`: the transition that had a model, a doc and no caller (closes `A91-D-99`; docs 02 §2.12, 03 §2.5, 91 §14.5, 92 §54, 93 §AN)

`Building.order_rebuild(now_minutes)` has been in the tree since doc 02 shipped.
It is typed, documented against §2.12's transition table, and it returned a
priced quote — `pending_level = level_at_destruction` inside a 72-game-hour
window at `cost_fraction` 0.60, and `1` at 1.00 after it.

**The grep is the whole finding:**

```
$ grep -rn "cmd_rebuild\|\.rebuild(" sim/ ui/ game/
sim/buildings/building.gd:463:func order_rebuild(now_minutes: int) -> Dictionary:
game/showcase.gd:314: road_surface.rebuild(...)          ← a different rebuild
sim/roads/road_network.gd:269: snapshot.rebuild(...)     ← a different rebuild
...
```

Every hit is `RoadSurfaceView.rebuild` or `WaterTopology.rebuild`. **There is no
`cmd_rebuild`, there is no CitySim verb, and there is no UI door.** The only
caller of `order_rebuild` in the entire project was `tests/test_building.gd`,
asserting the price of a transition nothing could reach.

And the door the player DOES reach for is closed against exactly this state:
`cmd_repair_building` (`sim/city_sim.gd`) refuses anything that is not `active`
or `damaged` with `E_STATE`, and on private stock the `E_OWNER_MAINTAINED`
blocker fires first and the panel draws no affordance at all. So a destroyed
building was permanently dead, in a game whose promise is *"You built it. Now
keep it alive."*

**Shipped.** `CitySim.cmd_restore_building(sim_id: Variant, preview := false)`:
`String()` coercion at the door (doc 12 §4.4's one-funnel rule), a
quote-then-commit shape identical to `cmd_repair_building`'s, refusals in the
documented order `E_UNKNOWN_BUILDING → E_STATE → E_JOB_IN_FLIGHT → E_FUNDS`
**with the quote on `E_FUNDS`** so the button can show the price it could not
pay, and the charge through `Treasury.spend(cost, &"restore", …)`. The building
comes back through the ordinary construction path — `planned` → the one queue →
`active` — on the authored `rebuild` job kind, so the queue panel lists it,
`cmd_rush_construction` rushes it and `building_completed` fires exactly as it
does for a new build. `cmd_restore_all_destroyed(preview)` is the many-at-once
half and is not a second verb: every row goes through the same command,
**cheapest first**, so a batch and N taps are the same N charges in the same
order.

`E_JOB_IN_FLIGHT` is not defensive. A shell can burn down WHILE it is being
built (§2.12: `under_construction → on_fire → destroyed`), and that job's
completion would call `complete_construction` on the restore the player just
bought and finish it for free.

**One thing the verb had to fix on the way past.** `CitySim._emit_construction_stages`
filtered its scan to `build`/`upgrade`, so a `rebuild` job would have drawn no
crane and no six-stage walk — the renderer telling the player nothing is
happening on a lot they just paid for. `rebuild` joins the walk.

### RR-156 — the price is ruled, not inherited: 0.20 of capital, the level survives, and the window is retired (docs 02 §2.12, 03 §2.5, 92 §54, 93 §AN)

A price nothing has ever charged is a proposal, not a measurement. Doc 02's
authored pair met its first measurement on 2026-09-02 and failed it.

`data/economy.json.expenses.RESTORE_COST_FRACTION = 0.20`, behind
`CostCurves.restore_cost_building()` (C-07: no dollar in `data/buildings.json`
or `sim/buildings/building.gd` — `order_rebuild` returns no `cost_fraction`
now, only `hours_destroyed`, which is a fact rather than a price).

The fraction is pinned between two prices the game already publishes: the repair
a maintaining player buys (`0.20 damage × 0.85 = 0.17 × capital`, doc 92 §43.1's
`balanced` agent threshold) and the repair at doc 02 §2.6's auto-damage line
(`0.65 × 0.85 = 0.5525 × capital`). **The floor is enforced twice** — `CostCurves`
refuses a table below it at boot, beside the rush-rate derivation check, and
`tests/test_economy.gd` asserts the inequality for every archetype at every rung
rather than asserting a constant. Below it the game would pay for neglect.

Measured (doc 92 §54, `tools/measure_restore_burden.gd`, new this wave): the
three ruins a `disaster_neglect` arc actually leaves standing — the starter
city's power plant, substation and water plant — restore for **$24,000 against a
$17,058 day's net = 1.41×**, where the authored 0.60 charged **$72,000 = 4.22×**.

**The grace window and the L1 demotion are both retired** (doc 93 §AN3). The
demotion deleted the player's own capital — a `house` at L5 carries $37,955 paid
rung by rung and came back holding $1,200 of it — and the window was **72
game-hours against doc 08's 720-hour offline cap**, so it punished exactly the
overnight absence the product is designed around. `REBUILD_GRACE_HOURS` is
deleted rather than deprecated.

**`owner_maintained` does not block a restore**, and that is a ruling read
narrowly on purpose (doc 93 §AN4). §Y1 puts ROUTINE WEAR on the owner; a
building destroyed by fire is a capital event, the owner is gone with the
building, and the rebuild is the city's call. The natural reading would have
closed this door on every house, store and office in the city —
`tests/test_restore_building.gd::test_a_destroyed_private_building_can_still_be_restored`
pins it, because it would have looked like a correct application of a Wave-17
ruling while doing it.

**No lifetime counter, deliberately.** `Treasury.lifetime` is captured into
`canonical_capture().ledger_totals` and thus into `state_hash()`; a new key would
move every baseline in the project on a player verb, which must move none.
`A91-D-100` is the row that publishes one.

### RR-157 — the ONE TAP, and the ruin the renderer has to stop drawing (docs 12 §2.9 D-86, 93 §AN6/§AN7)

**A ruin was already selectable and this was checked rather than assumed.**
`CitySim` does not un-stamp a destroyed building's tiles, so
`BuildController.sim_id_at_tile` → `TileGrid.building_at` resolves and
`pick_at_ground` answers `PICK_BUILDING`; `building_view()` carries no state
guard. What the PANEL drew was the defect: on city-maintained stock a disabled
`REPAIR` with an `E_STATE` sentence, and on private stock `E_OWNER_MAINTAINED`
folded into "nothing to buy" so the ruin's panel offered **no action at all**.

Shipped as doc 12 §2.9's destroyed block: what happened, how long ago, and one
primary 48 dp `RESTORE · $X` with the price on its face —
disabled-with-the-price-still-showing when unaffordable (the build-card
pattern), namespaced strings, tooltip, **no confirm dialog** (§AB's precedent:
the price is on the button). The repair affordance is suppressed on a ruin,
because the restore is the verb that answers it. Every value comes from
`BuildController.restore_view()`, which asks `cmd_restore_building(…, true)` —
the panel decides only what is on screen, so a button is never enabled on a rule
`ui/` believes and the sim does not.

**And the renderer must not lie in either direction.** The pump lesson (RR-108)
says a thing the player just bought appears the same frame, not on the next
relaunch; a ruin is the same statement inverted — the rubble must GO the same
frame. `restore_started_sim` carries the render id as well as the sim id
(`repair_started_sim`'s shape), `game/render/render_state_model.gd` gains one arm
that clears the soot the `building_destroyed` arm wrote and puts the site at
stage 1, and `game/main.gd`'s translator adds the site props. Without the arm the
lot would have kept its ruin overlay and its full damage channel **through the
whole rebuild and past its completion**, because the `building_completed` arm
carries damage forward when the event does not name it.

### 56.4 What this lane verified before it closed

| check | command | result |
|---|---|---|
| zero callers at the fork | `git grep -n "cmd_rebuild\|\.rebuild(\|order_rebuild" <fork> -- sim ui game` | one hit, and it is the **definition**: `sim/buildings/building.gd:463`. Every other hit in the tree is `RoadSurfaceView.rebuild` or `WaterTopology.rebuild` — two unrelated methods that happen to share a name, which is most of why this survived five waves of audit. |
| the suite | `godot --headless --script tests/run_tests.gd > suite.log 2>&1; echo $?` | **exit 0** — 135 files, **2,495 tests, 551,375 asserts, failed 0, silent 0** |
| determinism, founding city | `tools/profile_sim.gd --hash-only` | `05614522975fad52…` / `d1aaee0dca92f2fd…` — **byte-identical to the fork** |
| determinism, benchmark city | `… --hash-only --city=res://tests/fixtures/bench_city.json` | `275aad9d4aeea809…` / `d40126e371371d59…` — **byte-identical to the fork** |
| the preview deck | `xvfb-run -a godot --path . res://tools/ui_preview.tscn -- --screen=all --audit --strict` | **exit 0**, **69 of 69** states clean, the two new ones included |
| the doc ledger | `python3 tools/check_doc_refs.py` | `all resolving; no id assigned twice` |

**The one test that failed on the way, and why it is the best thing in this
section.** `tests/test_event_matrix.gd::test_every_emitted_event_is_consumed_or_classified`
failed on `restore_batch_completed` — a new event with no consumer — which is
precisely the guard `A91-D-19`'s shape exists to trip, tripping on the wave whose
whole subject is that shape. It is classified `awaiting_consumer` naming
`ui/city_dashboard.gd`'s Upkeep band and the lane that owns it, **not deleted**:
every building in a sweep already emits its own `restore_started_sim` and the
renderer consumes it, so the city visibly comes back; what is missing is the
one-line summary a twelve-ruin sweep deserves instead of twelve notices. The
classification carries a mechanical expiry, so the row deletes itself the moment
that lane lands.

**And one hazard the lane found in its own code before the suite did.**
`CostCurves` resolves doc 03's archetype aliases (`power_facility` →
`power_plant_gas`) and `BuildingCatalog` does not. The restore quote reads a
PRICE from the first and a DURATION from the second, and both were being read
off one variable — equal on every city today only because `_boot_buildings`
builds the archetype FROM `record["type"]` and `cmd_place_building` writes it
INTO it. A catalog read made in the economy's spelling answers `{}` and silently
gives every ruin a four-hour rebuild. Each side is now asked in its own
vocabulary, and `tests/test_restore_building.gd::test_the_catalog_and_the_economy_are_each_asked_in_their_own_spelling`
walks `PLANT-1` — the one founding archetype whose two names differ — and
asserts the quoted crew-hours are the authored figure rather than the fallback.

### 56.5 What is left to `game/main.gd` — two snippets, both the lead's

Neither is guessed and neither is written here: `game/main.gd` is the lead's
file, and both arms are anchored in the branch report.

1. **`_on_sim_batch`**, immediately after the `&"upgrade_started_sim":` arm.
   `restore_started_sim` already carries the int render id (the
   `repair_started_sim` shape), so it is appended as-is — exactly as
   `building_construction_stage` is — and `RenderStateModel`'s new arm does the
   rest. `_add_construction_site()` is the same call every other new project
   makes.
2. **The panel wiring**, immediately after
   `building_panel.demolished.connect(_on_building_demolished)`. Two args, so
   not `_on_building_action`. It is **wrapped in `flush_sim_events()`** for the
   same reason `bind_construction`'s rush door is: a verb that emits from inside
   the command meets a live drain (`SimHost._process`) that does not run while
   the game is paused, so the rubble a paused player just paid to clear would sit
   there until they un-paused. RR-108's lesson, applied in the other direction.

Until they land, `sim/` and `ui/` are complete and covered — the verb, the price,
the panel and the render arm all ship with tests — and the only thing a player
would notice missing is that the ruin's mesh survives its own restore until the
next relaunch. That is the pump lesson exactly, which is why the arms are named
rather than assumed.

---

## 58. WAVE 19 — the money stopped at six hours, and it was our clamp (binding)

**The player's report, 2026-09-03, on their own Fold 6 city:** *"I went to bed
hoping I'd wake up to a bunch of money. The money stops after a certain amount of
hours of the game being closed — we should boost those numbers."*

They are describing a wall, and there was one, and it was ours. `RR-133` (§48,
2026-09-01) implemented doc 08 §2.12's performance budget as `max_coarse_hours`
and fed it into `CatchUpPlanner.plan` as a second clamp — on the **credited
absence**. Derived from the founding city's measured 5.488 ms coarse hour it
shipped at 360 game-hours, and 360 game-hours is **six real hours**. Every hour
of sleep past the sixth paid nothing.

Doc 92 §55 measures the bill on a settled L3 city, seed 1337: an **eight-hour
night was worth $281,319 and is worth $354,830** — the wall cost the player
**$73,511, 26.1% of a night** — and a twelve-hour absence was paid 57.5% of what
those hours were worth.

This section rules the axis, not the number.

### RR-160 — the credited absence is doc 01's cap and NOTHING may tighten it (docs 01 §2.10, 08 §2.12, 92 §55)

**Binding.** `CatchUpPlanner.plan(elapsed_real_ms, residual_game_ms, tick_index)`
credits `mini(elapsed, OFFLINE_CAP_REAL_MS)` and there is **no fourth argument**.
`max_coarse_hours` is deleted from the planner, from `SavePolicy` and from
`data/persistence.json`, and `tests/test_catchup_veil_budget.gd` scans the
planner's source to prove the name is gone rather than merely unused — the
inverse of the grep that opened RR-133.

**The reasoning, stated once.** A performance budget and a fairness rule answer
different questions:

| | question | may bound | measured in |
|---|---|---|---|
| **Fairness rule** (doc 01 C-19) | *what is the player paid for being away?* | the credited absence | real hours of the player's life |
| **Performance budget** (doc 08 §2.12) | *how long does the catch-up veil run?* | wall clock behind the veil | milliseconds |

Wave 17 made one number do both, and when the two disagreed the *player* paid.
That is the defect. It is also why the fix is structural and not a retune: the
planner now reads **no data file at all** (`grep -n SavePolicy
sim/time/catchup_planner.gd` → nothing), so no workstation measurement has a path
to a player's wallet, and constitution §5 gets a stronger guarantee for free —
two phones cannot credit the same absence differently because there is nothing
device-shaped left in the credit.

**A second, quieter correction rides along.** `plan()` publishes `cap_real_hours`
beside `cap_game_hours`. The cap has always been quotable in two units and the
surfaces were picking one each; RR-162 makes them pick the same one.

### RR-161 — the performance budget moves to the axis it is a budget for (doc 08 §2.12, doc 92 §55.6)

**Binding.** Doc 08 §2.12's decision rule — `max_coarse_hours = clamp(floor(
ceil(2000 / measured_coarse_ms) / 24) × 24, 72, 720)` — is **retired**. In its
place, `data/persistence.json.catchup` carries two wall-clock numbers with no
arithmetic between them:

```
veil_ms_at_cap : 6432   # MEASURED: a whole 12-real-hour plan on the settled
                        # reference city (doc 92 §55.6)
veil_budget_ms : 9000   # what that is allowed to be
```

and the gate is `veil_ms_at_cap ≤ veil_budget_ms`. `tests/test_catchup_veil_budget.gd`
asserts it, asserts that **nothing in `sim/`, `ui/` or `game/` reads either
field**, and prints a live founding-city measurement rather than asserting one (a
wall-clock assert beside a fleet of sibling suites is a flake, not a gate).

**Three things the old rule got wrong, for the record.**

1. **The numerator was the wrong budget.** `2000` is doc 08 G4's *"24 game-hours
   of absence caught up well under 2 s"*. G4 bounds a **24-hour** catch-up; the
   rule applied it to the **720-hour** one and then took the difference out of
   the credit.
2. **It bounded neither veil.** At the shipped 360 the founding city spent ~3 s
   and the benchmark city spent **64,552 ms** on the same absence (doc 92 §55.6),
   because the clamp was derived from one city and applied to all of them. A
   number that produces 3 s here and 65 s there is not a bound.
3. **It erred the wrong way against its own stated preference.** §2.12 says *"we
   would rather spend 4 s once than hand back less than three game-days"*. The
   full cap on the settled reference city costs **5,504 ms** — 4 s once, almost
   exactly — and hands back 30 game-days.

**What is NOT fixed:** the benchmark city needs 116,882 ms for a full-cap
catch-up and is over budget by 13×. Filed as doc 92 §55.7 **AC-19-1** against the
coarse step (57% `incidents` + `roads_congestion` at `profile_sim
--coarse-hours=240`). **The fix is a cheaper coarse hour, never a smaller
credit** — that is the whole content of RR-160 and it does not get suspended
because the number is inconvenient.

### RR-162 — the away report tells the truth about the cap, in the unit the player slept in (doc 12 §2.12 D-87, doc 08 §2.12)

**Binding.** Three defects in one header, and two of them were invisible because
the third hid them.

1. **`elapsed_game_minutes` was the WALL CLOCK, not the credited time.**
   `game/main.gd` passed `elapsed_wall_s` straight through, so a 26-hour absence
   rendered *"Away 26h · 65 days of city time"* over a city that had lived 30.
   The shell now passes `plan.credited_real_ms / 1000`, and
   `tests/test_catchup_veil_budget.gd::test_the_header_counts_the_city_time_that_actually_ran`
   pins 720 game-hours / 30 game-days against a 26-hour absence.
2. **The capped line quoted city time at a sleeping player.**
   `ui_away_capped` filled `{hours}` from `cap_game_hours` and rendered *"Your
   city ran for 720h — the maximum."* `AwayModel._cap_real_hours` reads the
   plan's new `cap_real_hours`, falls back to `cap_game_hours ÷ 60` so an
   un-updated caller says something true rather than something absurd, and the
   copy is now **"Your city ran for 12 hours while you were away — the
   maximum."** — the player's own unit and very nearly their own words.
3. **Nothing tested the other direction.** D-77 pinned the line firing when the
   cap bit; nothing pinned it staying quiet when it did not, which is the case
   that matters now that an eight-hour night is uncapped.
   `test_an_uncapped_away_report_does_not_imply_a_cap` builds the report from a
   real eight-hour plan and asserts `capped_text == ""`.

### RR-163 — the window is ruled against what a player earns, not against a step cost (doc 92 §55.5)

**Binding: 12 real hours, credited in full.** Doc 01 C-19 stands and doc 08
§2.12 no longer tightens it. The ruling is made in the unit a player experiences,
which RR-133's was not, and doc 92 §55.2/§55.4 carry the arithmetic:

* A settled city earns **$40,374 (L2) / $50,262 (L3) / $58,632 (L4) per REAL
  HOUR** of play. One game-hour is one real minute at 1x, so the ledger's `$/gh`
  column *is* the per-real-minute rate; nothing is converted.
* An absence pays **97.4–101.1% of the same hours online-and-idle** at every
  length from one hour to twelve — measured against a control arm that runs the
  same settled city the same number of real hours with `is_catchup = false`.
* Therefore the cap is not where the money is decided; it is only where it is
  **stopped**. At 12 real hours it stops on an absence that is no longer a night.

**Doc 03 §2.11's taper is NOT WIRED — corrected at merge, 2026-09-03.** The
measurement that produced this ruling (offline earns 97-101 % of idle-online)
reproduces exactly; the mechanism the ruling gave for it does not. The taper is
not cancelled by `TAPER_EXEMPT` growth: `CitySim.build_settlement_inputs` never
sets `yield_mult`, `EconomySystem.settle_hour` therefore reads `1.0` every
catch-up hour, and `TAPER_EXEMPT` is data with no reader. Offline income is
untapered because nothing tapers it. Filed A91-D-109. The original sentence,
kept so the correction is legible: this is the finding that kept the wave
honest.** The obvious suspect for "the money stops" is the exponential taper,
whose effective-hours ceiling is `OFF_FULL + OFF_TAU = 94` game-hours. It was
measured (doc 92 §55.4) and it is very nearly cancelled at a growing city,
because the work the player already paid for — construction, upgrades, population
arrival — is `TAPER_EXEMPT`: the untapered base grows while the multiplier
shrinks. **No taper change is shipped, no difficulty scalar moves, and
`data/difficulty.json` is untouched.** Doc 08 §2.3's eight fairness rules are
likewise unchanged: offline still draws no street opportunities, catch-up is
still a session kind rather than a step size, and the Director is still held to
one pre-warned Tier-1 event per absence. Under those rules the city measures at
97.9% of online, so they are not what made an overnight feel empty.

### 58.1 Hash deltas, and why there are none

All four `profile_sim --hash-only` baselines are **unchanged** at the end of this
wave — recorded at the fork and re-run at the tip:

| pass | city | hash |
|---|---|---|
| coarse 24 h | `data/starter_city.json` | `64c4d7e9d8f8fb74…` |
| fine 2.0 h | `data/starter_city.json` | `9f19dcc5212f834d…` |
| coarse 24 h | `tests/fixtures/bench_city.json` | `6f383de1ed6940a2…` |
| fine 2.0 h | `tests/fixtures/bench_city.json` | `311e29d10b1cb43d…` |

**Structurally, not luckily.** Nothing this wave touches what a coarse hour or a
fine tick *does*: `CatchUpPlanner` decides how many of them run, and
`tools/profile_sim.gd` calls `CitySim.advance_coarse_hours` directly rather than
through a plan. For the same reason **no balance gate cell moves** —
`BalanceGateRig` runs `advance_coarse_hours(1, false)`, online, never through the
planner. Doc 92 §55.7 AC-19-2 files that for the survivable-city lane rather than
assuming it.

### 58.1b Verified at the tip — the commands, and what they printed

Every claim in this section is re-runnable. Recorded 2026-09-03 on the branch's
final commit, in this order:

```
~/.local/bin/godot --headless --script tests/run_tests.gd > suite.log 2>&1; echo $?
  -> 0 · files 146 · tests 2,705 · asserts 570,321 · failed 0 · silent 0

~/.local/bin/godot --headless -s res://tools/profile_sim.gd -- --hash-only
  coarse 24h  64c4d7e9d8f8fb74e5dd1502ad06c0bce46dd8940cdd777098c80b7aae9e8787
  fine  2.0h  9f19dcc5212f834dacbbe61ccaf3c42674a793c564b23f8c645e33c76cb69ba4
… same, --city=res://tests/fixtures/bench_city.json
  coarse 24h  6f383de1ed6940a28b4f27c9ddfa8593ef9edeb0a71efaf20814feae4012c496
  fine  2.0h  311e29d10b1cb43d2b52b94f02e4b346943ebb1ac7bc42a5445b0d5473ed2127
  -> all four IDENTICAL to the same four recorded at the fork, before any edit

python3 tools/check_doc_refs.py
  -> 4,399 references, all resolving; no id assigned twice

grep -n SavePolicy sim/time/catchup_planner.gd
  -> nothing: the planner reads no data file

grep -rn "max_coarse_hours" sim/ game/ ui/ --include=*.gd | grep -v ":[0-9]*:##\?"
  -> nothing: the three surviving mentions are `##` prose explaining the deletion
```

The headline, re-measured after the change with the same instrument that
measured before it (doc 92 §55.3, settled L3 city, seed 1337):

```
tools/measure_offline_night.gd --absences=8,12 --settle-hours=110 --seeds=1337
  8 real h -> $354,830   12 real h -> $478,377      # ships
… --cap-hours=360                                   # the Wave-18 clamp, as a what-if
  8 real h -> $281,319   12 real h -> $281,319
```

**The suite cost of the fix, stated because it is real.**
`tests/test_catchup_cursor.gd` plans a 7 h 41 m absence and proves slice
bit-identity at four slice sizes on two cities; that absence used to be clamped
to 6 h, so the file now runs 461 coarse hours per arm instead of 360 and takes
**6 m 57 s** instead of ~5 m 20 s. The test was silently proving a smaller
property than it claimed. Nothing was weakened to buy the minute back.

### 58.2 What is left to `game/main.gd` — one snippet, the lead's

`game/main.gd` is the lead's file. The arm is named and anchored rather than
written here; until it lands, the shell still passes the wall clock as
`elapsed_game_minutes` and the away header over-reports city time on a **capped**
absence only (an uncapped one is already correct, because credited *is* elapsed).
Every other half of RR-160/161/163 is live without it: the credit itself comes
out of `CatchUpPlanner.plan`, which the shell already calls.

**It is not a guess.** `tests/shell_resume_rig.gd` mirrors these same two
functions and has the change already, so the snippet below is a copy of code with
a green test behind it —
`tests/test_catchup_resume.gd::test_a_nine_hour_night_is_credited_whole_and_reported_honestly`
drives a real nine-hour absence through `AndroidLifecycle` and asserts 129,600
ticks (the Wave-18 clamp credited 86,400), an uncapped veil, 22.5 game-days in
the header and an empty capped line.

**(a) `_on_app_resumed`** — the `_catchup_after` literal, two keys appended:

```gdscript
	_catchup_after = {
		"elapsed_wall_s": elapsed_wall_s + float(unfinished.get("elapsed_wall_s", 0.0)),
		"residual_game_ms": int(plan.get("new_residual_game_ms", 0)),
		"capped": bool(plan.get("capped", false)),
		"cap_game_hours": float(cap_game_hours),
		# RR-162 / doc 12 D-87. The away report counts the city time that
		# ACTUALLY RAN and quotes the cap in the hours the player was away;
		# `elapsed_wall_s` is neither of those on a capped absence.
		"credited_real_ms": int(plan.get("credited_real_ms", 0)),
		"cap_real_hours": float(plan.get("cap_real_hours",
				CatchUpPlanner.OFFLINE_CAP_REAL_HOURS)),
	}
```

**(b) `_finish_catchup`** — beside the three existing reads, immediately after
`var cap_game_hours := float(_catchup_after.get("cap_game_hours", 720.0))`:

```gdscript
	var credited_real_ms := int(_catchup_after.get("credited_real_ms",
			int(elapsed_wall_s * 1000.0)))
	var cap_real_hours := float(_catchup_after.get("cap_real_hours",
			float(CatchUpPlanner.OFFLINE_CAP_REAL_HOURS)))
```

…and in the same function's `ui_root.present_away_report({…})` literal, the
`elapsed_game_minutes` line is replaced and one key is appended:

```gdscript
		# 1 real s = 1 game min at 1x — on the CREDITED absence, not on the wall
		# clock. A capped resume claimed city time the city never lived (RR-162).
		"elapsed_game_minutes": float(credited_real_ms) / 1000.0,
		…
		"capped": capped,
		"cap_game_hours": cap_game_hours,
		"cap_real_hours": cap_real_hours,
```

`AwayModel` accepts `cap_game_hours` alone and divides it by 60, so the file is
correct before the snippet lands and more correct after — there is no window in
which the two disagree.


## 59. WAVE 19 — a city that cannot be wiped out while you sleep (binding)

*(Lane 2. Measured in doc 92 §56, ruled in doc 93 §AP, defect rows doc 91
A91-D-103/104/105, UI delta doc 12 D-88. This lane held the balance matrix.)*

The player, on their own Galaxy Z Fold 6 city, 2026-09-03:

> *"The buildings are still being destroyed super fast. There was a natural
> disaster, a water flooding, I woke up to — and there's negative money … ALL of
> my buildings are destroyed right now."*

**The first result of the wave is that the disaster did not do it.** Doc 92
§56.1's instrument ran 45 game-days × 4 presets × 2 session kinds and every
destruction in all eight arms came through `Building.roll_structural_failure` —
0 through `apply_damage`, 0 through `burn_down` — and the flood has no path to a
building's condition at all. What took the city was doc 02 §2.6 wear, on stock
the city had left dark, through a door that only opens one way.

---

### RR-164 — wear may CONDEMN a private building, it may not demolish one

`data/building_rules.json owner_maintenance.wear_may_demolish = false`;
`Building.wear_may_demolish` stamped by `BuildingCatalog.wear_may_demolish()` at
doc 93 §Y2's four sites; `roll_structural_failure` returns empty for
owner-maintained stock. Ruling: doc 93 §AP1.

The chain it cuts, measured (doc 92 §56.2): a city outgrows its generation →
**74–107 of 251 buildings permanently dark with zero failed components** → doc 02
§2.6a's ownership floor lifts under its own service clause (§Y1a) → the private
stock falls to 0.10 → the 0.02/gh roll deletes it, **nine buildings on a bad
game-day, one every 2.7 real minutes.**

Measured effect, same seed and instrument, before → after: standard **42 → 6**
ruins over 45 game-days, casual **21 → 10**; hard and crisis unchanged at 6 and
7 because every ruin there was already civic or utility stock the city owns.
`damaged` rises by what `ruins` falls (standard +34 against −36) — the same
buildings, condemned instead of demolished, still paying `output_mult` 0.40.

**Not a shield.** `burn_down`, doc 06's explicit `destroy_building`, an event
landing on an already-condemned building, and this same roll on the city's own
civic and utility stock all still demolish.

### RR-165 — one event may not demolish a standing building

`Building.apply_damage` floors at `structural_failure_threshold` for any building
above it; a building already at or below it is finished off as before. The floor
is doc 02 §2.6's own 0.10 and not a new constant. Ruling: doc 93 §AP2.

**One line had to split.** `CityIncidentWorld.destroy_building` spelled its
non-fire branch `apply_damage(1.0)`, so a floor on damage would have silently
disarmed doc 06's terminal outcomes. `Building.demolish()` now says what it
means — **and carries doc 08 C-47's guard, which that branch never had.** Before
this wave an explicit destroy was the one door through which an ABSENCE could
still take a building, inside a rule whose entire purpose is that absences may
not.

### RR-166 — three lifetime ledger rows, and the wave that was allowed to pay for them

`Treasury.lifetime` gains `lifetime_dispatch`, `lifetime_restores` and
`lifetime_relief`, with the matching `_note_lifetime` arms.

This closes **doc 91 A91-D-37** (`&"incident"`, open since Wave 15) and
**A91-D-100** (`&"restore"`, opened by Wave 18), and it closes them *here* for the
reason A91-D-100's own row gives: `lifetime` is captured into
`canonical_capture().ledger_totals` and therefore into `state_hash()`, so adding
a key moves **all four `profile_sim` baselines on both cities**. The row rules
that they close "in a lane that holds the balance matrix … as one `ledger_totals`
edit and one re-record". Wave 19 holds the matrix, and this is that one
re-record. `lifetime_relief` joins them because RR-167 creates a grant that
would otherwise be un-auditable.

### RR-167 — the recovery ladder gets a bottom that cannot run out

Doc 03 §2.10 layer 5, two defects, one ruling (doc 93 §AP4):

* **A91-D-103 — the allowance had no era.** `relief_grants_per_era` has carried
  that word since doc 03 §2.9 and `relief_grants_used` was reset by nothing
  anywhere in the project, so it was a LIFETIME allowance of three on standard.
  `Treasury.note_era(city_level)`, called from `_pay_level_up_grant`, makes an
  era a city level: already tracked, already persisted, monotone, unfarmable.
* **A91-D-104 — the grant shrank with the disaster.** It was
  `1.5 × daily_gross_revenue`, measured on the city *after* the loss. Measured at
  the limit (doc 92 §56.5): a city of 251 ruins with a **$238 280** restore bill
  was offered **$8 000**, `RELIEF_MIN`, on every preset. Relief is now
  `max(revenue term, RELIEF_DAMAGE_FRACTION × outstanding restore bill)` inside
  the same clamp: **$83 398** on standard, 10.4×, and still $155 000 short of the
  bill.

`RELIEF_DAMAGE_FRACTION = 0.35` is `DEFERRED_REPAY_FRACTION` adopted, not
invented — doc 03's existing answer to *how much of a hole does the city close
per step*. **The anti-farm is an inequality**: 0.35 < 1, so the grant never
covers the bill and wrecking your own city always loses money.
`Treasury.relief_gates_pass()` splits the four price-free gates out so the
`O(roster)` bill is priced only when a grant is already possible — the ladder runs
every settled game-hour and the bench city has 1 500 buildings.

**One migration, and it is the half that rescues the reported save.** A
pre-Wave-19 save carries a spent `relief_grants_used` and no `relief_era_level`,
so it would load at era 0 — and a city whose stock is all ruins cannot reach a
new city level, which means the ruling would refill an allowance for every city
**except the one that needs it**. `Treasury.relief_needs_era_migration` is set by
`deserialize` only when the key is absent, and `CitySim._restore_systems` opens
the era at the level the city has already reached. **Conditional on the save's
shape, and that is what makes it safe**: a save written by this build migrates
nothing, so save→load→advance stays bit-identical (constitution §5,
`tests/test_save_determinism_days.gd`, 6 tests green). It cannot be farmed by
reloading — `note_era` is idempotent per level.

### The four baselines, re-recorded, with the cause measured rather than assumed

| city / path | at the fork | after Wave 19 |
| --- | --- | --- |
| starter, coarse 24 h | `64c4d7e9…8787` | `50d22101…d620` |
| starter, fine 2.0 h | `9f19dcc5…9ba4` | `140ded24…34f7` |
| bench, coarse 24 h | `6f383de1…c496` | `0fd19f68…6c46` |
| bench, fine 2.0 h | `311e29d1…2127` | `d1a58e7c…30f6` |

**All four moved. §AP1 contributes nothing — that half IS measured; the claim
that RR-166's three `ledger_totals` keys are "the whole of it" is NOT, and is
withdrawn here (verify pass, 2026-09-03).** The flip-the-switch experiment below
exonerates §AP1 and only §AP1: flipping `owner_maintenance.wear_may_demolish`
back to `true` and re-hashing both cities on both paths returns all four shipped
hashes unchanged. It says nothing about §AP4's new save key or RR-167's
`relief_era_level`, both of which are also inside `canonical_capture()`, so the
attribution to three keys is an inference wearing a measurement's clothes. What
is established: §AP1 is not a cause — neither profiling
city has a building near `structural_failure_threshold` inside 24 coarse hours or
2 fine hours, and neither is insolvent, so §AP2 and §AP4 cannot fire. Doc 92
§56.6 carries the commands.

**Gates: 33 of 33, no re-fit.** This lane held the matrix and was entitled to
re-fit any gate whose derivation had moved; none had. Gate 29's insolvency
ordering is unchanged **to the game-day on all four presets** (`probe_neglect`,
seed 1337: 193/193, 135/135, never/48, 35/19 — eight numbers, eight matches
against §49.5's published table), because a `do_nothing` founding city loses one
to five buildings across its whole horizon, so the stock §AP1 saves was never
what decided the insolvency day. Neglect is still fatal; it is no longer fatal by
demolition. The curriculum arc still earns all six levels on all three seeds
(`measure_curriculum --days=45`).

### RR-168 — the instrument, and five knobs that were re-derived and not moved

`tools/measure_catastrophe.gd`: per-game-day ruins, damaged, destructions by
cause, dark buildings, failed components, mean condition, treasury and
population, across two session kinds that are not interchangeable
(`--mode=online` is gate 29's arm; `--mode=absence` is a real closed app under
C-47), with `--warm`, `--real-hours`, `--then-online`, `--treasury` and
`--relief`.

The lane brief named five Director knobs to re-derive against a Director that no
longer stalls. **All five are HELD, each with its number** (doc 93 §AP3), and the
before/after Director event count is **bit-identical on all eight arms** —
15/13/41/44 online, 0/0/1/0 offline — so nothing this wave shipped made a storm
rarer, weaker or later. Two of the verdicts are worth repeating because reading
the code disproved the premise:

* `floor.tp_per_day` **already passes through** `pressure = 0.55 + 0.90·P`
  (`tp_base_per_day` returns `max(ladder, floor)`, and `tp_rate_per_day`
  multiplies that base by `age_ramp × pressure × tp_rate_mult`). The apparent
  inversion — crisis 44 events against casual 15 — is the difficulty ladder plus
  F5 holding the large city down on its own ambient load;
* **the flood has no damage fraction to tune.** `FloodField` emits
  `flood_level_changed` and `road_closed_flood` and nothing else.

**What the measurement found instead is filed, not fixed** (doc 91 A91-D-105):
the `building_damaged` cause column reads `decay=61 incident=0 fire=0` on every
arm — the whole incident and disaster layer does **zero** damage to buildings over
45 game-days, because `building_condition` ops sit on tier-2/tier-4 escalations
auto-dispatch resolves first. A storm is currently spectacle. The honest sequence
is this wave's door first, then a measured damage pass in the lane that owns doc
06's escalation ladder — not both in one measurement, where neither could be
attributed.

## 60. WAVE 19 — money you actually collect (binding)

*Lane 3 of Wave 19, forked off the Wave-18 merge (`d4f62e1`), 2026-09-03. The
lane exists for one overnight report, and the sentence it is built against is the
player's own:*

> *"The crimes we stop are only a few hundred dollars — add a zero to that.
> 15,000 for one. And any other fun ideas to collect money in the game, something
> to actually DO to collect, other than tax revenue."*

*Two of the three asks are answered by re-pricing what already exists; the third
needed verbs that were not there. **The lane does NOT touch the balance matrix**
— every dollar it adds is reachable only through a player verb or a level curve
that is exactly 1.00 at the founding city, so `do_nothing`, `balanced`,
`tax_squeezer` and `infrastructure_first` earn what they earned before it, and
gate 29's insolvency day does not move.*

| `profile_sim --hash-only` | at the fork (`d4f62e1`) | after this pass |
|---|---|---|
| starter, coarse 24 h | `64c4d7e9d8f8fb74…` | `e05f57a6caa87297…` |
| starter, fine 2.0 h | `9f19dcc5212f834d…` | `35826d0d9c7510c3…` |
| bench, coarse 24 h | `6f383de1ed6940a2…` | `7c849bb295dc8653…` |
| bench, fine 2.0 h | `311e29d10b1cb43d…` | `5b2a3bfb5c13afd2…` |

**All four move, and there are exactly TWO causes. Neither is a balance change.**

1. **`RngStreams.STREAM_NAMES` gains `"contracts"`** (RR-170). `rng.serialize()`
   is inside `canonical_capture()` and therefore inside `state_hash()`, so a
   named stream is a hash change on **every** city — including one that never
   opens the board, and including the coarse path, where the board takes no draws
   at all. `Treasury.hour_city_services` gains a `contracts` key for the same
   reason it had to: the settlement's `services_total` is the SUM of that
   dictionary, so a source with no key there would move the balance and not the
   line. This is the same shape RR-85's `street` stream had at rung 7.
2. **`data/street.json spawn.target_interval_h` 1.50 → 2.85** (RR-169), which
   changes the Bernoulli threshold `_try_spawn` compares its first draw against.
   This one moves the FINE hashes only — the opportunity layer's coarse contract
   is zero draws and zero spawns.

**What did NOT move is the half that matters for the matrix.** Nothing in this
lane changes what a `do_nothing`, `balanced`, `tax_squeezer` or
`infrastructure_first` agent EARNS: the street layer is fine-path only, the
commissions board is fine-path only, the dispatcher's premium scales on the
manual half that no scripted agent ever uses, and the salvage verb is a player
tap. Gates 1, 2, 21, 29, 31 and 33 all pass unmoved. The re-record is a schema
cost, not a behaviour cost, and the way to check that claim is the one this
project always uses: the four gates that hold the founding ledger and the
insolvency day are green in the same suite run this table was taken in.

### RR-169 — the street layer and the dispatcher's premium: what "add a zero" can honestly mean (docs 03 §2.5, 06 §2.16, 92 §57.1/§57.2, 93 §AQ1)

**The finding is not that the numbers were low. It is that two of them were
FLAT.**

`dispatch_payout_base` has no city-level term at all. A resolved crime pays
`350 × (1 + 0.35·(tier−1)) × speed`, and every factor in that product is a
property of the *incident*; none is a property of the *city*. So the reference
crime — tier 3, answered on target — paid **$595 on game-day one and $595 on game
day three hundred**, while the city's own net per real-minute went
**537.7 → 2,755.4** (`tools/measure_curriculum.gd --days=45 --seeds=1337,4242,9001`).
The reward for answering an incident therefore lost about four fifths of its real
value as the player got better at the game. That is a decay, not a level, and it
is exactly what the player reported.

The street layer's `STREET_REWARD_CITY_LEVEL_K` was not flat but was fitted
against a run AVERAGE, and it decayed for the same reason at a slower rate: 1.8×
by level 5 against a city that got 3.3× richer.

**What "$15,000 for one" costs, stated before anything is changed.** The street
layer delivers 0.339 offers per game-hour (measured). A $15,000 collection at
that rate is **$5,090/gh**, which is **1.85× the entire net income of a level-6
city**. A street table that paid the player's number would not be a strong second
income; it would be the economy, and every other system in the game would become
scenery. So the number is answered by a verb that fires about once a game-day (RR-170's
contract board), and the street layer is re-priced against what it can actually
carry.

**(a) The street trade — 1.70× per collection, 1.00× per game-hour.**

The ceiling on this layer is a SHARE of the city's income
(`STREET_CEILING_SHARE_MAX`), and the shipped layer was already at 35.9 % of a
40 % bound. There was therefore **no room to make one pickup bigger by making the
layer richer — only by making pickups rarer.** Both sides move in the same
commit:

| | before | after | ratio |
|---|---|---|---|
| `petty_crime` band | 260 + 90 | **430 + 155** | mean ×1.664 |
| `loose_animal` band | 150 + 60 | **250 + 100** | mean ×1.667 |
| `lost_valuables` band | 420 + 180 | **700 + 300** | mean ×1.667 |
| `spawn.target_interval_h` | 1.50 | **2.85** | ×1.90 |
| measured mean bounty | $320.29 | **$543.11** | ×1.696 |
| measured mean interval | 1.763 gh | **2.947 gh** | ×1.671 |
| measured ceiling | $181.65/gh | **$184.30/gh** | ×1.015 |
| ceiling ÷ founding net | 35.90 % | **36.42 %** | bound 40 % |

*(Instrument: `tools/measure_street_yield.gd --hours=720 --seeds=1337,4242,9001
--net=506.04786`.)*

**`target_interval_h` is 2.85 and not 2.50, and the difference is a finding.**
Delivery is not the table rate: `max_live`, `min_separation_tiles` and an empty
kerb pool reject a fraction of the draws, and **that fraction falls as the table
slows**. A table divided by exactly 5/3 delivered only 1.50× fewer offers and the
ceiling went UP 12 % — measured $204.23/gh, 40.4 % of founding net, *over* the
bound. The trade is only neutral at the interval where the measured delivered
interval matches the measured bounty ratio, and that is 2.85.

The beat moves 1.76 → 2.95 real minutes between offers. Doc 06 §2.16's own
authored band is 1–3 real minutes, so the layer is still inside it and now sits
at its **slow** edge — which is where a $500 pickup belongs and where a $305 one
did not.

**(b) `STREET_REWARD_CITY_LEVEL_K` 0.20 → 0.25, and the rung that binds it is
FIVE.**

The old value's note closes *"that is why 0.20 is HELD rather than raised"*, and
what held it was a denominator taken from a 21-game-day run average. The
per-LEVEL series is now measured and published as
`pacing_guardrails.MODEL_NET_PER_HOUR_BY_CITY_LEVEL`:

| city level | 1 | 2 | 3 | 4 | 5 | 6 |
|---|---|---|---|---|---|---|
| mean net $/real-min | 537.7 | 658.8 | 851.0 | 956.4 | 1017.2 | **2755.4** |

**That series is not a ramp.** It is roughly flat from level 2 to level 5 and
then triples. So a curve fitted against the run average is fitted against a
number the player is never at, and the binding rung for a share ceiling is level
**5**, not 1 and not 6. Holding `184.30 × (1 + k·(L−1)) ≤ 0.40 × net(L)` at every
rung gives `k ≤ 0.302`; 0.25 is that bound with a seed's worth of margin, and the
per-level ceiling shares become **34.3 / 35.0 / 32.5 / 33.7 / 36.2 / 15.0 %**.

Gate 32 gains arm **(d2)**, which checks exactly this at every rung. Before this
wave (d) measured the founding city only, which is how a level curve could be
moved with nothing asking what the share became at level 5.

**(c) `MANUAL_DISPATCH_LEVEL_K` 0.90 — new, and it is the only thing in this lane
that touches doc 06's payout.**

`manual_dispatch_mult(level) = 1.50 + 0.90 × (level − 1)`, so the dispatcher's
premium is **1.50× at the founding city and 6.00× at level 6**. Fitted under the
series above and deliberately not to it: 6.00/1.50 = **4.00×** against a city that
got **5.12×** richer, so the premium closes most of the decay and never outruns
the city that pays it.

Two bounds keep it out of the matrix and out of gate 31, and **both were already
in the file**:

1. **Only the MANUAL half scales.** `Incident.manual_requested` is set by
   `cmd_dispatch_unit` and by nothing else, so auto-dispatch keeps exactly the
   dollars it has and every control agent in the balance matrix earns what it
   earned before this wave. This is RR-78's own argument used a second time —
   *"the new money this wave pays out is the dispatcher's premium, and a control
   agent never earns one."*
2. **Only where doc 03 can PRICE the target.** `CityIncidentWorld.dispatch_payout`
   asks for the level curve only when `prevented_loss_value(...) ≥ 0`. There the
   runtime clamp is `MORAL_HAZARD_CAP_FRACTION × prevented_loss`, which already
   grows with the asset, so the raise is bounded by the value of the thing the
   player saved and can never become a moral hazard. Where the target is unpriced
   (road edges, water segments) the premium stays flat at 1.50, because
   `MORAL_HAZARD_UNPRICED_CEILING` is derived from an avenue rebuild and an avenue
   does not get dearer because the city levelled up. **Gate 31(c)'s published
   table is therefore unmoved and untouched.**

**(d) The ratio ruling, re-derived for the second time — and for the second time
the derivation moved while the ruling did not.**

The ruling is still *"a tapped crook is petty, a dispatched crime is the real
one."* The 2026-08-21 derivation stated it against ONE denominator, the
auto-dispatched reference of $595, and a crook re-priced to a mean of $507.50 is
0.853 of that — which would fail the old 0.60 bound.

**That denominator was the loose half, and RR-78 said so in its own words when it
invented the premium: *"the drawer is where the raise is."*** A *dispatched* crime
is one a human dispatched, and doc 06's reference case dispatched by hand pays
`350 × 1.70 × 1.50 = $892.50`. Gate 32(b) now holds two assertions that say
different things, which is cheaper than re-litigating one:

* **(b1) the ORDERING** — the street mean is under the AUTO reference. 507.50 <
  595, 15 % of margin. This is the assertion that catches a street table priced
  past the incident it is a lesser version of.
* **(b2) the READS-AS-ABOUT-HALF claim** — street mean ≤ 0.60 × the MANUAL
  reference, **at every city level**. Both sides now carry a level curve and the
  dispatch side is the steeper by construction, so the ratio FALLS across the
  ladder: **0.569 at level 1 → 0.320 at level 6.** The dispatched crime becomes
  more the real one as the city grows, not less. The old form read the base
  tables and stopped, so a future wave that raised the street curve past the
  dispatch curve would have passed it and shipped an inversion.

**What the player gets.** A level-6 crook's mean bounty goes $610 → **$1,142**; a
level-6 `lost_valuables` tops out at $1,200 → **$2,250**; the reference crime the
player dispatches by hand goes $892.50 → **$3,570** (clamped at 0.75 × the loss
it prevented, which on upgraded stock is far above it). That is between 1.9× and
4.0× on the mature city, and it is what this layer can carry. The zero the player
asked for is RR-170's.

### RR-171 — `cmd_salvage_building`: a ruin is worth something, and the verb that runs the other way (closes the other half of `A91-D-99`; docs 02 §2.12, 03 §2.5, 12 §2.9 D-89, 92 §57.2, 93 §AQ2)

**The state the player woke to, in their words:** *"There was a natural disaster,
a water flooding, I woke up to — and there's negative money … ALL of my buildings
are destroyed right now."*

Every priced verb the game offers a player in that state asks them for money they
do not have. `cmd_restore_building` (Wave 18) is a *purchase*; the panel draws it
disabled with its price on its face, which is correct and is also the whole
screen. There was nothing on any surface a broke player could press.

**And doc 02 §2.12's own table has always had the missing row.** Under the
`destroyed → planned` line Wave 18 finally gave a caller sits
`destroyed → (removed)`, `cmd_clear_rubble`, `0.10` cost fraction,
`0.25 × build_time` crew-hours. `ConstructionQueue.KINDS` carries `clear_rubble`;
`ConstructionQueueModel` renders it; `NotificationScheduler` exempts it by name.
**Everything existed except a verb** — which is `A91-D-19`'s shape for the seventh
time, and doc 12 §2.9 D-86 named it as `A91-D-99`'s remaining half when it closed
the other one.

```
grep -rn "cmd_clear_rubble" sim/ ui/ game/     # before: 3 hits, all comments
                                               #         saying it does not exist
```

**The price is a closed form, not a fit.** `SALVAGE_FRACTION = 0.15 =
DEMOLITION_REFUND_FRACTION 0.25 − doc 02 §2.12's own authored rubble-clearance
fraction 0.10`: a ruin is worth what an intact building is worth knocked down,
less the cost of clearing a mess the demolition contractor never had to make.
Three bounds, and it sits inside all of them — `tests/test_salvage_building.gd`
holds each as an inequality against the other published fractions rather than
against a literal:

1. **strictly below 0.25**, or a building is worth more dead than demolished and
   letting stock fall is a strategy — the exact failure the moral-hazard cap
   exists to refuse one system over;
2. **strictly below `RESTORE_COST_FRACTION` 0.20**, so salvaging a ruin never pays
   for restoring the same ruin and the two verbs are a decision rather than a
   loop;
3. **strictly above 0.05**, which is the net of an arbitrage that already existed
   and that nobody had noticed — see `A91-D-107`.

Worth, on shipped stock: a house L1 **$180**, L3 **$915**, L5 **$5,693**; the
starter city's power plant (capital $60,000 at L1) **$9,000**.

**Two deliberate deviations, both recorded rather than smuggled.**

* **It is instant and files no job**, so doc 02 §2.12's `0.25 × build_time` is not
  spent and `clear_rubble` remains an unused queue kind. It follows the shipped
  precedent of its nearest sibling: `cmd_demolish_building` is instant today for
  a whole intact building, and a verb that made a WRECK take longer to clear than
  an office block would be explaining the queue rather than the city.
* **There is no `cmd_salvage_all_destroyed`**, and the asymmetry with
  `cmd_restore_all_destroyed` is the ruling: a batch is safe when the worst case
  is spending money and unsafe when the worst case is a city that cannot be
  brought back. Restore-all can be undone by earning; salvage-all cannot be
  undone at all.

**The money is credited to `&"construction"`, not to a new `city_services`
source**, and the reason is a hash (`A91-D-108`): `Treasury.lifetime` is captured
into `canonical_capture().ledger_totals` and therefore into `state_hash()`, so a
`salvage` key would move all four baselines on every city for a schema change
that belongs in one edit with `A91-D-37`'s `&"incident"` arm and `A91-D-100`'s
`&"restore"` arm. The category is also the honest one on its own terms: a
demolition refund goes there already, and this is a demolition refund at a
different fraction.

**The refactor that came with it.** `cmd_demolish_building`'s teardown is now
`_take_building_off_the_map()` — twelve steps (tiles, both utility attachments,
the doc-05 nodes and the doc-04 node the shell hosted, the station's fleet, five
per-building caches, the road-density index, the grid-id high-water mark, the
replay row an authored building owes a save, and the district rollup). Two verbs
that each did eleven of the twelve would be a bug that only shows up on whichever
was written second, which is the shape doc 91 keeps filing. The credit and the
event stay with the callers, because they are the half that differs.

**One blocker was written and then removed as unreachable.** The first draft
carried an `E_JOB_IN_FLIGHT` arm mirroring `cmd_restore_building`'s. It can never
fire: the only job that can exist on a ruin's lot is the rebuild that verb files,
and `Building.order_rebuild` moves the state out of `destroyed` in the same call,
so `E_STATE` always wins. A blocker that cannot fire is a blocker nobody can
test; the state check is the whole gate and
`test_a_rebuild_in_flight_takes_the_lot_out_of_this_verbs_reach` says so.

### RR-172 — the salvage row: a second button on the one panel that had a decision missing (docs 12 §2.9 D-89, 93 §AQ2)

A verb with no door is this project's signature defect, so the row ships in the
same commit as the verb, with its preview state, exactly as D-86 did.

```
Destroyed 2h 30m ago. Rebuilds at level 3, condition as new.
[            RESTORE · $1,220            ]     ← primary FAB, disabled under water
[            SALVAGE · +$915             ]     ← ghost, HOLD to confirm
Strip the lot for scrap. This building does not come back;
rebuilding it later costs $1,220.
[        RESTORE ALL 12 · $84,200        ]
```

Three deliberate differences from the primary above it, each with a reason:

* **a ghost, not a FAB** — keeping the city is the offer the game leads with, and
  this one is still there tomorrow;
* **hold-to-confirm**, sharing `DEMOLISH`'s 800 ms window from
  `data/ui.json.layout`, because it is the second button in the deck that cannot
  be undone. `BuildingPanel`'s hold machinery was single-target and is now
  `_begin_hold(button, action)` / `_end_hold()` with `_hold_button` and
  `_hold_action`: two buttons each counting their own milliseconds would be two
  places for the window to drift from the authored key;
* **never disabled for money** — the verb spends nothing, so `salvage_view` has no
  affordability arm at all, and that is precisely what makes it the one row a
  negative balance cannot close.

The note states the consequence **before** the hold and states it *against the
other button's number*, because the decision is not "is $915 a lot" but "is $915
worth more to me than a level-3 building". Four new `ui_building_salvage_*`
strings; `salvage_view` quotes `restore_cost` off the same `preview = true` call
so the two figures on the panel can never come from two reads.

**Preview state `building_salvage`, same commit** — a ruin on a **negative**
balance, which is the 2026-09-03 state photographed rather than described: both
ruin buttons on screen and only one of them pressable. `--screen=all --audit
--strict` exits **0** at 412×915, 360×800, 880×400 and at 360×800 with
`--text-scale=1.3 --large-targets`.

### RR-170 — the commissions board: what "$15,000 for one" costs, and where it can honestly live (docs 03 §2.5b, 08 §2.8, 12 §2.19 D-90, 92 §57.3, 93 §AQ3)

**The arithmetic that decides where this feature goes, done before anything was
built.** The player asked for a $15,000 collection. The street layer delivers
**0.339 offers per game-hour**, so $15,000 a pickup is **$5,090/gh** — **1.85×
the entire net income of a level-6 city** (`MODEL_NET_PER_HOUR_BY_CITY_LEVEL`
row 6 = 2,755.4). There is no value of `street_payout`, of
`STREET_REWARD_CITY_LEVEL_K` or of `target_interval_h` that pays that number and
leaves a game underneath it. **A figure that size has to belong to a verb that
fires about once a game-day**, and that is the whole design constraint the
commissions board is built from.

**The loop.** A client posts a commission to a board. The player ACCEPTS one —
the city holds exactly one at a time — which starts a deadline in game-hours.
They do the work with the verbs they already have. When the target is met the
commission goes `ready` and they CLAIM it, which is the only step that moves a
dollar. Seven commissions ship:

| id | tier | asks for | window | from level |
|---|---|---|---|---|
| `watch_patrol` | minor | collect 4 street pickups | 12 h | 1 |
| `film_permit` | minor | stamp 6 road tiles | 18 h | 1 |
| `insurance_payout` | standard | restore 2 buildings | 24 h | 2 |
| `county_retainer` | standard | resolve 5 incidents | 24 h | 3 |
| `assessor_survey` | standard | start 3 repairs | 24 h | 3 |
| `convention_bid` | major | 3 upgrades | 36 h | 6 |
| `reconstruction_grant` | major | restore 3 buildings | 36 h | 6 |

**The board invents no objective vocabulary and that is the reuse that made it
affordable.** Progress is counted off `GoalSystem.EVENT_KINDS` — doc 09's
curriculum table — extended by exactly ONE row, `restore_buildings`, whose event
did not exist until Wave 18 gave the restore a verb. So a commission can only ask
for something the game already knows how to notice, a verb that grows a
curriculum objective grows a contract kind for free, and
`tests/test_contracts.gd` asserts the extension is one row rather than a second
vocabulary growing in a second place.

**The two commissions that are the 2026-09-03 report, by name.**
`insurance_payout` and `reconstruction_grant` pay for *restoring destroyed
buildings*, which is the exact sentence the player wrote at three in the morning:
*"I've been trying to restore all the buildings so we can get revenue back up,
but it seems really difficult."* They were doing the work and being paid nothing
for it.

**Pricing, and the bound that is one number in another file.**
`contract_payout` is `{minor 900+300, standard 2200+700, major 5000+1600}` with
`CONTRACT_REWARD_CITY_LEVEL_K = 0.40`, so at level 6 a `major` pays **$15,000 at
the FLOOR of its band and $19,800 at the top** — the player's number, delivered
by the band's floor rather than by its luckiest draw.

What stops that becoming the economy is `data/contracts.json
board.cooldown_h_after_claim = 30.0`. One commission at a time means income
cannot exceed one payout per cooldown, whatever the player does, and 30.0 is the
value at which the best tier available at every rung lands under
`CONTRACT_CEILING_SHARE_MAX = 0.25`: measured **6.5 / 18.1 / 18.0 / 19.6 / 21.7 /
21.0 %** of net at levels 1–6. Balance gate 32 gains arm **(h)**, which reads both
files and asserts the one against the other — the same shape arm (c) has held the
street rate in since RR-85.

**Why 0.25 when the street's ceiling is 0.40: the two are ADDED.** A player who
takes every street offer and completes every commission is at 0.65 of net from
active play, leaving the passive city 61 % of the total. That is where this wave
puts the line, stated as a rule rather than a number: *above one half from any
single active layer, or above two thirds from all of them together, and the city
stops being the thing being played.*

**`major` waits for level 6, and that is a BALANCE gate rather than a difficulty
curve.** `MODEL_NET_PER_HOUR_BY_CITY_LEVEL` is flat from level 2 to level 5 and
then triples; a `major` payout at level 5 would be 38 % of that rung's net on its
own. The tier ladder is gated where the income series says it fits, not where a
progression curve would like it to.

**Three structural properties, each enforced where it cannot be forgotten.**

1. **It is a FINE-PATH system.** `ContractBoard.advance(dt, online = false)`
   returns before its first statement: no offer posted, no deadline run, no offer
   aged, **and not one draw taken on the `contracts` stream**. That is doc 08
   §2.3 rule 9 made structural, and it is also why the balance matrix — which
   runs the coarse step — cannot see this file at all.
   `test_the_board_does_not_run_while_the_player_is_away` asserts the stream
   state is byte-identical across 500 game-hours away.
2. **It owns no dollar.** `data/contracts.json` is refused at boot if it carries
   `reward`, `payout`, `base`, `spread` or `reward_city_level_k` at any depth,
   and a tier `city_services.contract_payout` does not price is a boot error too
   — the same pair of guards RR-78 gave `reward_base` and RR-85 gave the street
   bands.
3. **A lapsed commission costs NOTHING** — no fee, no stability, no reputation.
   Ruled in the data file so it is visible there and not only in a doc, on the
   same terms as the street layer's `expire_stability_delta: 0.0`.

**The bus grew a fan-out, and the objection it answers is in the bus's own
docstring.** `SimEventBus.observer` is deliberately one `Callable` because *"a
list would make emission order depend on registration order, which is exactly the
kind of thing determinism forbids"*. That objection is about a bus anybody can
subscribe to; the answer is not a list on the bus but `CitySim.EventFanout` with
a fixed authored order set once at boot (`[goals.observe, contracts.observe]`).
It is a separate object rather than a method on `CitySim` so the bus does not
hold a bound `Callable` back onto the sim that owns it, and `dispose()` drops
both ends.

**City section rung 8 → 9** (doc 08 §2.8), and `_v8_to_v9` is the identity
function for the same reason `_v6_to_v7` was — the two new shapes are a
top-level `contracts` block and an `rng.contracts` entry, and both have documented
defaults an absent save falls back to.

**THE FOUR BASELINES MOVE, and the cause is one line.** `RngStreams.STREAM_NAMES`
gains `"contracts"`; `rng.serialize()` is inside `canonical_capture()` and
therefore inside `state_hash()`, so a named stream is a hash change on every
city, including one that never opens the board. `Treasury.hour_city_services`
gains a `contracts` key for the same reason it had to (the settlement's
`services_total` is the SUM of that dictionary, so a source with no key there
would move the balance and not the line). Both are published in the table at the
head of this section. **The three LIFETIME arms doc 91 `A91-D-37` / `A91-D-100` /
`A91-D-108` owe are still deferred**: they are a different dictionary and belong
in one edit with each other, in a lane that holds the matrix.

### RR-173 — what the wave measures, and the two numbers it did not move (docs 92 §57, 12 §2.19 D-90)

**The surfaces, both shipped in the same commit as their verbs**, which is
A91-D-28's lesson and this project's signature defect applied on the way in
rather than a wave late:

* the ruin's `SALVAGE` row and preview state `building_salvage` (RR-172);
* the goals sheet's COMMISSIONS band and preview states `goals_contract` /
  `goals_contract_ready`, with `ui_contract_*` strings, five new
  `RequirementFormatter` codes with title/body/remedy, and four
  `data/ui.json.event_log` rows.

`--screen=all --audit --strict` exits **0** at 412×915, 360×800, 880×400 and at
360×800 with `--text-scale=1.3 --large-targets` — four sweeps, 72 states each.

**The band is drawn on an EMPTY board, and the first draft was wrong about
this.** It hid itself when there was nothing on it, on the reasonable-sounding
argument that a header over nothing is worse than no header. For this project
specifically that is backwards: a player who has never seen the header has no way
to learn that commissions exist, and a feature nobody can discover is `A91-D-19`
with a nicer name. *"No commissions on the board right now"* is a sentence; an
absent header is not.

**One blocker was written and removed as unreachable.** `cmd_salvage_building`'s
first draft carried an `E_JOB_IN_FLIGHT` arm mirroring `cmd_restore_building`'s.
It can never fire — the only job that can exist on a ruin's lot is the rebuild
that verb files, and `Building.order_rebuild` moves the state out of `destroyed`
in the same call, so `E_STATE` always wins. A blocker that cannot fire is a
blocker nobody can test.

**The two numbers this wave deliberately did not move**, because both belong to
lanes that hold the matrix:

* `dispatch_payout_base` — the AUTO payout. Raising it would make every control
  agent in the balance matrix richer and move gate 29's insolvency day, which is
  Lane 2's. The whole raise is on the manual half instead (RR-169(c)), which is
  RR-78's own argument used a second time.
* `Treasury.lifetime` — the three ledger arms. See `A91-D-108`.

### §60 AWAITING CONSUMER — what this lane hands to the lane that holds the matrix

*Lane 3 does not hold the balance matrix and did not re-fit a matrix gate. It
moved two things a matrix holder has to know about, and it re-measured one number
the matrix will move again. All three are written here rather than in a commit
message, because a hand-off in a commit message is a hand-off nobody finds.*

| # | what | who it is for | what they owe |
|---|---|---|---|
| **AC-1** | **The four determinism baselines moved.** Causes published in the table at the head of this section: `rng.contracts` (a named stream, inside `state_hash()`) and `spawn.target_interval_h`. | the lane that re-records `profile_sim` baselines | Re-record against `e05f57a6…` / `35826d0d…` / `7c849bb2…` / `5b2a3bfb…`. **Nothing a scripted agent EARNS moved** — the street layer and the commissions board are both fine-path only, the dispatcher's premium scales on the manual half no agent uses, and salvage is a player tap — so gates 1, 2, 21, 29, 31 and 33 hold unchanged and this is a schema re-record, not a re-fit. |
| **AC-2** | **`pacing_guardrails.MODEL_NET_PER_HOUR_BY_CITY_LEVEL` is new and three level curves are fitted against it** — `STREET_REWARD_CITY_LEVEL_K`, `MANUAL_DISPATCH_LEVEL_K` and `CONTRACT_REWARD_CITY_LEVEL_K`, plus gate 32 arms (d2) and (h). | **the survivable-city lane** (Lane 2), and any lane that re-arcs `data/goals.json` | The row is a MEASUREMENT (`tools/measure_curriculum.gd --days=45 --seeds=1337,4242,9001`) and it moves whenever the curriculum, the destruction rates or the offline credit move. **A lane that makes a mature city poorer makes all three curves too generous, and gate 32(d2)/(h) is where that shows up** — which is the point of writing them as share assertions rather than as dollar assertions. Re-measure the row, do not re-fit the curves by hand. |
| **AC-3** | **A third ledger arm is owed and still deferred** (`A91-D-108`, beside `A91-D-37` and `A91-D-100`). `hour_city_services` gained `contracts` because the settlement's total is the sum of that dictionary; `Treasury.lifetime` gained nothing. | the lane that holds the matrix | Three arms — `&"incident"`, `&"restore"`, `&"salvage"` — in one `_note_lifetime` edit and ONE baseline re-record. Three lanes have now each declined this edit for the same correct reason; doing them one at a time costs three re-records for one change. |

**And one thing this lane deliberately did NOT hand over.** `dispatch_payout_base`
— the AUTO payout — is untouched. Raising it is the obvious way to answer *"the
crimes we stop are only a few hundred dollars"*, and it would make every control
agent in the balance matrix richer and move gate 29's insolvency day. The whole
raise is on the manual half instead (RR-169(c)), which is RR-78's own argument
used a second time and which is what let this lane ship without holding the
matrix. **If a later lane wants the auto half raised, the insolvency gate has to
be re-fitted in the same commit**, and this row is the record that it was
considered and refused.

### §60 AS VERIFIED — the closing run

*Taken on the final tree, in one pass, after the last edit in this section.*

| check | command | result |
|---|---|---|
| the suite | `godot --headless --path <worktree> --script tests/run_tests.gd` | **150 files, 2727 tests, 576067 asserts, failed **0**, silent **0**** |
| the deck, 412×915 | `tools/ui_preview.tscn -- --screen=all --size=412x915 --audit --strict` | **exit 0** |
| the deck, 360×800 | …`--size=360x800` | **exit 0** |
| the deck, 880×400 | …`--size=880x400` | **exit 0** |
| the deck, 360×800 at 130 % + larger targets | …`--text-scale=1.3 --large-targets` | **exit 0** |
| the four ledgers | `python3 tools/check_doc_refs.py` | **all resolving; no id assigned twice** |

**One defect in this lane's own tests is worth recording, because of the shape it
had rather than the size.** Gate 32's new arm (h) declared a local `band` in a
function whose arm (f) already had one; GDScript refuses the redeclaration
outright rather than shadowing it, so **the whole of `tests/test_balance_gates.gd`
failed to load** — all 33 gates, silently, with the runner printing a load error
and carrying on to a run that otherwise looked normal. That is the worst shape a
test-file error can take: not a red suite, but a green-looking one with a third of
the balance surface absent from it. It was caught by reading the run's log rather
than its verdict, and the closing run above is the one taken after the fix.

## 66. WAVE 24 — a million at the first rung, and the money a returning city was already owed (binding)

*Forked off the Wave-21 merge (`6dba66c`), 2026-09-04. The lane exists for one
instruction from the player, and the instruction carries its own numbers and its
own second half:*

> *"For each level we need a much bigger boost. We're trying to give the players
> enough money so they can really get their city going — something like a real
> city. The first level of building up your city, you're going to at least get a
> million dollars or a few. We want them to have plenty enough room to actually
> build everything and just play the game. And then you'll lose money from things
> and you'll gain money for more things — that's how it should be, not struggling
> right away. So $45k — let's jump that and start the players off in the million
> dollar range. **Start with one million dollars, and then at level seven we give
> them seven million.** And I want you to make it so if a player has already
> passed level one and was supposed to get a million dollars, you should be able
> to collect it for all of them AUTOMATICALLY — you should just check if you have
> received it, and if you haven't, then you get it. That way we can keep one city
> going for a while."*

*Wave 22 (§64) set its curve where it did because a flat few-hundred-thousand
table failed eight assertions across seven balance gates. **The player has been
told that and has decided**, so the table is not negotiated here — it is shipped,
and then the thing it breaks is diagnosed properly. What that diagnosis found is
that the ceiling Wave 22 attributed to the city outrunning its copper was the
city outrunning its **generation**, which nothing in this project has ever bought,
and which was **already failing inside gate 18b's own run at the fork**. Rulings
93 §AW. Measurements doc 92 §63. Defect rows doc 91 A91-D-124..126. Surfaces
doc 12 §2.19 D-112/D-113.*

### RR-197 — the celebration grant, re-scaled to the player's two anchors (docs 03 §2.5a, 92 §63.1, 93 §AW1)

**`LEVEL_UP_GRANT_BY_CITY_LEVEL = [0, 1000000, 2000000, 3000000, 4000000, 5000000, 6000000, 7000000]` — rung k pays k million dollars.** $5,890,000 across the curriculum becomes **$28,000,000** (4.75×; 207× the project's original $135,000). **The player named two anchors and the two anchors are the whole curve**: a straight run of step $1,000,000 is the only shape that hits $1,000,000 at rung 1 and $7,000,000 at rung 7 with a single constant, so **no third number is invented** — the table is the instruction, written as arithmetic. The geometric alternative through the same points is `7^(1/6) = 1.3831`, rejected because 1.3831 is a ratio nothing in this project publishes (Wave 22's 1.5 was `√2.25`, and 2.25 is doc 09 §2.11's own rung ratio, so it was *derived*). **§AU1's anti-farm property survives and is now asserted rather than implied:** the rung-on-rung ratio falls 2.00 / 1.50 / 1.33 / 1.25 / 1.20 / 1.17 against the city's 2.25, so from rung 2 up the grant grows *more slowly* than the city and its share falls by construction — and the fall ACCELERATES (0.89 / 0.67 / 0.59 / 0.56 / 0.53 / 0.52) where the geometric run's was flat at 0.61, making the linear ladder **the more anti-farm of the two**. **The half-of-the-next-chapter rule is RETIRED and doc 03 says so in those words**: rung 6 is $6,000,000 against chapter 7's whole ask of $644,370 — 9.3×, not half. What it buys: chapters 2–7 summed are **$853,130**, so **rung 1 alone pays for every lesson the curriculum will ever ask for, with $146,870 left over**; the deepest climb doc 02 has (data centre L2→L5, $5,306,213) is covered 19 / 38 / 57 / 75 / 94.2 / 113 / 132 % by the seven rungs. `tests/test_city_services.gd` asserts the RULE and the ratio bound, not seven literals.

*Files: `data/economy.json`, `tests/test_city_services.gd`, doc 03 §2.5a, doc 92 §63.1*

### RR-198 — the wall the money found is GENERATION, and it was already there (docs 04 §2.2, 92 §63.2–§63.3, 93 §AW2)

**On the unchanged agent matrix the new table takes gate 18b — *a city may not outrun its own power* — from 5.99 % of building-time dark to 37.20 % on its own seed and 37.60 % across three.** The diagnosis is measured, not assumed: `tools/probe_dark.gd` splits gate 18b's single share into doc 04's three distinct failures, and on the rich city **not one building is unattached, not one transformer is unparented, not one transformer is CRITICAL, the worst feeder ends at r = 0.25 — and `supply_kw` never moves off 8,000 kW for the whole 50-game-day run** against a demand that reaches 11,585. Every founded city has one `power_facility` at doc 04 §2.2's L1 rating, **nothing else in the game generates**, and no strategy in `tools/playtest.gd` has ever bought or upgraded generation. **THE SAME WALL IS AT THE FORK**, inside gate 18b's own run: game-day 50 reads 15.55 % dark, 166 orphaned buildings, 2 shed feeders and 9,227 kW against 8,000 — the gate's 5.99 % headline is a fifty-day MEAN over a column that ends at 15.55 %. `Balanced._lead_generation` ships the purchase the agent never made, the same family as both of Wave 6's grid fixes: it reads `capacity_summary().load_ratio`, buys at doc 04 §5.10's **WARNING** band (the authority `FEEDER_RELIEF_RATIO` already cites — no swept number), upgrades the standing plant before building a second (doc 02: **$69,000 for +10,000 kW** against **$60,000 for +8,000**), and has **no cooldown constant** because the construction job whose duration doc 02 publishes is the cooldown. **Three arms, `tools/measure_dark_share.gd --days=50`, three seeds: fork 5.99 / 20.98 / 9.52 (mean 12.16 %); money alone 37.20 / 36.47 / 39.14 (mean 37.60 %); shipped 4.61 / 20.88 / 0.55 (mean 8.68 %).** **The money leaves the city lighter than it found it**, and **not one bound on the three gates this lane holds — 18b, 20, 21 — moves.** Gate 18b instead GAINS two assertions (`supply_kw_end > FOUNDING_SUPPLY_KW`, `supply_kw_end > demand_kw_end`) that would have caught this wall five waves ago and cost nothing, because the run is already made. **Five bounds elsewhere in the gate file did move, all collateral, and doc 92 §63.7.1 derives each against a printed row of the gates' own rig** (`tools/measure_gate_row.gd`, new): gate 4's `damaged_end` → `destroyed_end` (a transit state replaced by a terminal one — 0 vs 69 where the transient read 1 vs 0); gate 4b's repair-share FLOOR 0.03 → 0.02 (the DENOMINATOR doubled, $2,304/gh → $5,039/gh; the ceiling does not move); gate 4b's `min_condition_end` → `min_condition_floored_end` (the assertion was reading the worst building of ANY kind against a floor doc 02 §2.6a exempts damaged and dark buildings from — 0.668 / 0.715 / 0.673 measured against `band_worn` 0.60); gate 12b's `TAX_SQUEEZE_POP_MAX_RATIO` 1.05 → **0.93**, which RESTORES the pre-Wave-22 bound because the statistic is fittable again (0.699 / 0.702 / 0.714, the tightest it has ever measured); and gate 33's `DIRECTOR_LAST_START_FRACTION` 0.6 → 0.5 on a statistic the FORK passed by 1.2 game-days. Gate 12c's tradeoff arm is re-stated rather than re-fitted and the finding is PUBLISHED: squeezing is now a −4.04 % loss, its cause is `tax.TAX_RATE_GROWTH_COEFF`, and re-fitting that by hand is what AC-2 forbids this lane — filed as AC-24-5.

*Files: `tools/playtest.gd`, `tools/measure_dark_share.gd` (new), `tools/probe_dark.gd` (new), `tools/measure_gate_row.gd` (new), `tests/test_balance_gates.gd`, doc 92 §63.2–§63.3, §63.7*

### RR-199 — retroactive back-pay: a ledger of dollars, and doc 08 city-section rung 11 (docs 03 §2.5a.1, 08 §2.8, 92 §63.4, 93 §AW3)

**`Treasury.grant_paid_by_level` — dollars paid per curriculum level, indexed like the grant table, persisted in the `treasury` block behind city-section version 10.** The operative word in the instruction is *received*: a city paid $2,500 for rung 1 has received rung 1 and is owed **$997,500**, which a paid/unpaid flag cannot express and a high-water level cannot either. Both payment sites write to it — `CitySim._pay_level_up_grant` (live, on `city_level_objectives_met`) and `CitySim._settle_grant_arrears` (every load) — through `Treasury.note_grant_paid`, which **only ever adds**. Four properties are consequences of that shape rather than guards: **idempotent** (the second load computes the same differences against a ledger that records them and gets zero), **only the difference**, **never for an unearned level** (the walk stops at `GoalSystem.earned_level`; the population backstop is not consulted, per §AU6), and **unfarmable for life** (a table that later pays LESS claws nothing back and re-pays nothing). **`_v9_to_v10` MARKS rather than answers** — v2 → v3's line, for v2 → v3's two reasons (doc 08 §2.8 forbids a migrator to open `data/`, and the restored city does not exist until `_restore_goals` returns) — stamping `treasury.grant_ledger_bootstrap`, **the section version the body came from**, because what a legacy city was paid depends on which binary paid it. `grants.LEVEL_UP_GRANT_SUPERSEDED_BY_SAVE_VERSION` publishes the seed: row `"0"` is the original ladder paid on the COMPOSED level (exact for every body at version ≤ 8), row `"9"` is Wave 22's as the **element-wise maximum** of the tables that could have written a v9 body — labelled as a maximum, because crediting the larger makes double payment impossible rather than unlikely, at a published cost of at most $487,000 on a $15,000,000 settlement. **The seed runs to `max(city_level, earned_level)` while the arrears pay only to `earned_level`**, which is exactly why the ledger holds dollars: a rung the population backstop already bought is *recorded*, *never back-paid*, and *credited* against the day the curriculum earns it. **Back-pay opens no era** — arrears settle rungs climbed in the past, and `_settle_grant_arrears` never calls `note_era`. Nine tests in `tests/test_grant_arrears.gd`.

*Files: `sim/economy/treasury.gd`, `sim/economy/cost_curves.gd`, `sim/city_sim.gd`, `data/economy.json`, `tests/test_grant_arrears.gd`, docs 03 §2.5a.1, 08 §2.8*

### RR-200 — the receipt, because fourteen million dollars arriving in silence is a bug (docs 12 §2.19 D-112/D-113)

**`ui_root._check_grant_arrears` pushes one toast — *"Back-pay collected — $14,922,000 for levels 1–5"* — with §2.21's payday chip flash behind it.** The rung span comes off the event's own `levels` array, so the copy cannot claim a rung the sim did not pay for. It is a SEPARATE toast from D-95's level-up toast and not a fold into it, because it is a different moment — nothing was earned, a debt was settled — and the two can never collide, since arrears are emitted inside a restore and a level-up cannot be. **D-113 is the row that ships no code:** `_pay_level_up_grant` now pays a DIFFERENCE, and D-95 already read the amount off the sim's own event rather than off `data/economy.json`, so a rung paying $3,977,500 because $22,500 was collected years ago says $3,977,500 on the toast with no change. That is D-95's own stated reason — *"a toast that predicted a payment could be right about the table and wrong about the city"* — paying off one wave later against a case that did not exist when it was written.

*Files: `ui/ui_root.gd`, `data/strings.en.json`, doc 12 §2.19*

### RR-201 — measured on the player's own city: −$22,624 → $14,899,376, and $0 the second time (doc 92 §63.5)

**`tools/measure_backpay.gd` (new) runs the whole feature against a real generation file** — the player's `slot_0/gen_000291.sav` of 2026-09-03, copied into a private directory, through doc 08's real migrator and a real `restore_state`. The body is **city section version 8**, `earned_level` 5, `city_level` 5, treasury **−$22,624**, austerity active, $569,547 of deferred liability, and no ledger. The seed is **$78,000** (the original ladder's rungs 1–5); the arrears are **$14,922,000** — $997,500 / $1,993,000 / $2,991,000 / $3,977,500 / $4,963,000, cell by cell the new table less the original ladder; the city loads at **$14,899,376**. Rungs 6 and 7 stay at $0 in the ledger, because it has not earned them. **The second load, on the city the first one produced, pays $0 and emits no receipt.** `tools/dump_save.gd` (new) is the read-only decoder that made the section version and the curriculum block readable in the first place.

**And through the REAL save ladder as well**, which is the arm a file reader cannot claim: `tools/measure_player_city.gd` (Wave 20's instrument, unchanged) copies the slot into a private `user://` and loads it through `SaveService` — same generation ladder, same seven-check gate, same `restore_state`. It reports **treasury $14,899,376 at load**, an **outstanding restore bill of $282,078** (1.9 % of what the city now holds, so all 77 ruins are affordable in an afternoon — the answer to the 2026-09-03 report's *"I've been trying to restore all the buildings so we can get revenue back up"*), **austerity clearing from `true` to `false` inside one game-day**, and **`relief used 0/3 in era (level 5)`** — which is ruling 93 §AW3(c) holding in the field: five rungs settled and no era opened.

*Files: `tools/measure_backpay.gd` (new), `tools/dump_save.gd` (new), doc 92 §63.5*

### 66.AW — `awaiting_consumer`: gate 29's delta (there is none), and the two rows this lane filed

**Gate 29 belongs to the sibling wave (Wave 23, the fire capability), and this
lane does not touch it.** The rule is that a delta is PUBLISHED rather than
assumed, so here is the measurement rather than the argument.

**The delta is zero, and it is measured bit-for-bit.** Gate 29 runs `do_nothing`
across doc 03 §2.9's four presets. `tools/measure_dark_share.gd --days=21
--seeds=1337,4242,9001 --strategies=do_nothing`, at the fork and as shipped:

| seed | dark share | buildings | upgrades | **treasury at 21 game-days** |
|---|---|---|---|---|
| 1337 | 0.02 % → **0.02 %** | 34 → **34** | 0 → **0** | $156,406 → **$156,406** |
| 4242 | 0.00 % → **0.00 %** | 34 → **34** | 0 → **0** | $159,093 → **$159,093** |
| 9001 | 0.23 % → **0.23 %** | 34 → **34** | 0 → **0** | $148,724 → **$148,724** |

Every cell is identical to the dollar, and the mechanism says why it must be:
the grant is paid on `city_level_objectives_met` (ruling 93 §AU6), `do_nothing`
completes no objective of any level, and `Balanced._lead_generation` is a method
on `Balanced` while `DoNothing extends Strategy` directly. Nothing gate 29 reads
moved — not `MODEL_NET_PER_HOUR_BY_CITY_LEVEL`, which it does not consult, and
not a preset horizon or an ordering bound. **Wave 23 has nothing to re-fit from
this lane.**

**Two rows are filed for owners this lane is not, and both are named:**

* **A91-D-125 — a city's grid is never repaired, and gate 18b asserts one seed.**
  Measured at this fork on the SHIPPED Wave-22 build with no Wave-24 change:
  **5.99 / 20.98 / 9.52 %** across `MATRIX_SEEDS`, against gate 18b's own ruled
  ceiling of 20 %. Seed 4242 has been over that bound for at least two waves and
  nothing could see it, because the gate runs `GATE_SEED` alone. The cause is
  measured (`tools/probe_dark.gd`): grid components that go FAILED are restored
  only by doc 06 resolving their incident, the failure rate scales with the
  transformer fleet, and no agent buys a repair — so a richer city accumulates
  105 failed components and 234 orphaned buildings behind them. **Owner:** the
  lane that holds doc 06's dispatch capacity, or the one that gives an agent a
  grid-repair rule. **The cheap half is one line** — gate 18b over `MATRIX_SEEDS`
  — and it is not done here because it triples the slowest assertion in the file
  behind a bound the fork already fails, which would hand the next wave a red
  gate and no diagnosis.
* **A91-D-126 — `unserved_share` is three unrelated failures wearing one
  number.** Doc 04 gives a building three distinct ways to be dark and
  `Playtest.Runner._blackout_minutes` sums them, so a wave reading the sum fixes
  whichever it guessed. That is not hypothetical: §61.12 diagnosed a 26.44 %
  reading as a grid problem and set a whole grant curve against it, when the
  cause was generation. **Owner:** the lane that holds gate 18b. The instrument
  is already shipped (`tools/probe_dark.gd`, plus `supply_kw_end` /
  `demand_kw_end` on the playtest summary); what remains is re-cutting the gate's
  assertion into three.
* **AC-24-5 — `tax.TAX_RATE_GROWTH_COEFF` was fitted against a money-limited
  city and this money removed the limit.** Gate 12c's tradeoff arm measures
  `tax_squeezer` creating **4.04 % LESS** value than `balanced` ($4,927,506
  against $5,135,120) where the fork measured **+39.6 %**, and the grant is not
  what compresses it: both arms take exactly curriculum rungs 1 and 2 inside the
  21-day horizon, and net of the identical $3,000,000 the gap is −9.7 %.
  **Owner:** the lane that holds doc 03's tax curve. This lane publishes the
  finding and bounds the LOSS (`TAX_SQUEEZE_VALUE_MIN_RATIO` 0.90, measured
  0.9596) rather than re-fitting a constant it does not own, which is report 98
  AC-2's own rule. Doc 92 §63.7.1 item (5), §63.9 AC-24-5.
* **AC-24-6 — the Disaster Director's tail, on BOTH arms.** 23–28 game-days of a
  60-game-day run carry no new event, with the threat pool full (40.0) and
  nothing in flight (0 active) on the fork and on the shipped tree alike. Gate
  33's `DIRECTOR_LAST_START_FRACTION` moves 0.6 → 0.5 because the FORK passed
  0.6 by 1.2 game-days on a statistic whose variance is 1.6 inter-event
  intervals; the stall assertion with teeth (`started >= 8`, fork 2, shipped 18)
  is untouched. **Owner:** the lane that holds doc 07's cadence. The instrument
  is `tools/probe_director.gd`, unchanged and pre-existing. Doc 92 §63.7.1 item
  (6), §63.9 AC-24-6.

**No `tests/test_event_matrix.gd` row is owed.** The one new sim event this wave
emits, `level_up_grant_arrears_paid`, has a consumer in the same commit
(`ui_root._check_grant_arrears`), so the register neither gains a row nor needs
one — which the matrix suite asserts on its own.

### 66.S — the suite, the audit and the four baselines, on the FINAL tree

`nohup setsid tools/run_suite.sh > suite.log 2>&1` →
**tests: 2798  asserts: 582961  failed: 0  silent: 0 — ALL TESTS PASSED.**
`tools/run_suite.sh --one=test_balance_gates.gd` → tests: 33, asserts: 445,
failed: 0. `python3 tools/check_doc_refs.py` → *5363 references, all resolving;
no id assigned twice.* `godot --headless --path . tools/ui_preview.tscn --
--screen=all --size=412x915 --audit --strict` → **clean, exit 0** on every
state; the only surface this wave adds is one toast, and a toast has no target.

**The four `profile_sim --hash-only` digests are re-taken on the final tree and
are the ones §63.8 publishes**, unchanged by anything after the save key:

| fixture | coarse 24 h | fine 2.0 h |
|---|---|---|
| starter | `d09597510c211062…` | `4c5aea2928d1991e…` |
| `tests/fixtures/bench_city.json` | `db208d59c6fe7bdc…` | `28ec8a1c33f3bf88…` |

That is the point of the ablation §63.8 records: the gate re-fits, the new
instrument and the `min_condition_floored` sample column are all in `tests/` and
`tools/`, which `profile_sim` does not load, so **not one of them can move a
digest** — and the digests did not move between the checkpoint that introduced
the save key and the final tree.

**The two real-save arms, re-run on the final tree** —
`tools/measure_backpay.gd --file=…/slot_0/gen_000291.sav` → first load
`$14,922,000` in five rungs, treasury `−$22,624 → $14,899,376`, **second load
`$0`**; `tools/measure_player_city.gd --saves=… --slot=0 --days=1` →
`treasury $14899376` at load through the real `SaveService`, outstanding restore
bill `$282,078`, `relief used 0/3 in era (level 5)`, austerity `true → false`
inside one game-day.

**`game/main.gd` needs no edit for the receipt, and the reason is worth writing
down rather than assuming.** `_settle_grant_arrears` emits onto the sim bus
inside `restore_state`, and `main._on_sim_batch` — the single door — already
forwards **every** drained batch to `ui_root.feed_events(batch)` before it
switches on any type, so a new event type reaches `_check_grant_arrears` with no
translation. Both drains that can carry a restore's leftovers do the same thing:
`SimHost._process` (`game/sim_host.gd:35`) drains on the first frame that
produces a tick, and `main._finish_catchup` (`game/main.gd:2245`) drains the
offline batch and feeds it through the same door. **What the lead may optionally
want** is one line in `_finish_restore`, immediately after
`_on_ui_save_loaded(_restore_slot)` (`game/main.gd:1805`): `flush_sim_events()` — the door's own
idempotent drain (`game/main.gd:736`) — which lands the receipt on the frame of
the load rather than on the first tick after it. It is a latency choice, not a
correctness one, and this lane does not make it because it does not own the file.

## 64. WAVE 22 — the reward: a rung is worth something now, and there is one more of them (binding)

*Forked off the Wave-19 merge (`ef08351`), 2026-09-04. The lane exists for one
sentence from the player, and the sentence carries its own numbers:*

> *"The reward system for getting through the tutorial levels — we should get a
> substantial amount of money so you can start your city, so you can actually
> have a good start, and the situation I'm in now with the negative money goes
> away. Each level, since we have six, should give let's say a few hundred
> thousand dollars. And then we can even make a SEVENTH level where it's pretty
> much get a lot of buildings upgraded — get one of each type of building
> upgraded — and you get the big money when you go through the last level.
> That'll be five million."*

*They are at **−$22,624** with most of the city a ruin. A sibling wave is fixing
the causes; this lane is the other half — what the game hands you on the way up.
**The scale is authored by the player and the curve is derived**, and doc 03
§2.5a says which is which rather than dressing the first up as the second
(ruling 93 §AU1).*

### RR-187 — the celebration grant, re-scaled: an authored scale under a derived curve (docs 03 §2.5a, 92 §61, 93 §AU1)

**`LEVEL_UP_GRANT_BY_CITY_LEVEL` is re-scaled and one row longer: `[0, 45000, 65000, 95000, 145000, 215000, 325000, 5000000]`.** $135,000 across the whole curriculum becomes **$5,890,000** — 43.6×. **The SCALE is the player's request and the CURVE is derived**, and doc 03 §2.5a says which is which. ONE ANCHOR and ONE RATIO: rung 6 at **$325,000** is the project's original rule kept verbatim — *half of what the next chapter asks you to buy*, and chapter 7 asks $644,370 — which is what stops the capstone being prepaid; the ratio is **1.5 = √2.25**, the square root of doc 09 §2.11's own rung ratio, so **the grant grows at half the exponent the city does** and its share of the city falls by two thirds a rung by construction (measured 2.8 / 2.2 / 2.4 / 1.2 / 0.44 chapters of the band's own income at rungs 1–5). The bottom of the run falls out at $42,798 → **$45,000** and is **bounded by measurement**: a first draft paid the flat *"few hundred thousand each"* the request suggested and failed **eight assertions across seven balance gates**, including gate 18b's *a city may not outrun its own power* at **26.44 %** of building-time dark against a ruled 20 % and a fork baseline of 6.25 %. On the shipped curve that reading is **5.99 %**. Rung 7's $5,000,000 is **authored**, labelled as authored, and checked three ways (7.76× the capstone's ask; 94.2 % of a data centre's L2→L5 climb; 29.9 game-days of a top-rung city's whole net). Doc 92 §61.12; ruling 93 §AU7.

*Files: `data/economy.json`, doc 03 §2.5a, doc 92 §61*

### RR-188 — a seventh curriculum level, and the one new evaluator kind it needs (docs 09 §2.14.2, 92 §61.5, 93 §AU3)

**A seventh curriculum level: `data/goals.json` gains twelve `upgrade_archetype` rows, one per archetype `data/buildings.json` ships.** The kind is new and it is the third reading of one button — it counts the same `upgrade_started_sim` that `upgrade_building` and `upgrade_to_level` count, filtered by an **`archetype` field that `CitySim.cmd_upgrade_building` now stamps onto the event**. The field is ADDITIVE (every existing reader asks for `sim_id`, `to_level` or `cost`) and it is stamped at the emit site rather than resolved by `GoalSystem`, because handing the goal system the roster would make a per-event evaluator O(buildings) and break doc 09 §2.14's own cost rule. Twelve rows and not one distinct-set counter, because `GoalSystem.serialize` writes `progress` as `id → int` and a set would be a save-shape change for no reader's benefit. **Civic and utility stock counts** — the roster is `BuildController.cards()`'s own, which filters nothing — and the row is the only level in the file with no `reach_population` objective.

*Files: `data/goals.json`, `sim/progression/goal_system.gd`, `sim/city_sim.gd`, `data/strings.en.json`, doc 09 §2.14.2*

### RR-189 — the ladder gets the rung FIRST, or the level is earned and never paid (docs 09 §2.11, 91 A91-D-118)

**`data/progression.json` gains rung 7 at 40,500, and it had to land BEFORE the curriculum row could.** `ProgressionSystem.grant_level` clamps its argument to `city_level_pop().size() - 1`: a seventh curriculum row over a six-rung ladder earns level 7 inside `GoalSystem`, shows the sheet complete, and **never fires `city_level_changed` for rung 7 — so the $5,000,000 is never paid.** That is this project's signature defect and it is closed by a data row, not by a special case in the clamp. `ProgressionSystem.CITY_LEVEL_POP_FALLBACK` moves with it (gate 20 holds the two equal). **Every `city_level` consumer was walked** and the audit is in §64's second table below.

*Files: `data/progression.json`, `sim/population/progression_system.gd`, doc 09 §2.11*

### RR-190 — the level-up moment names the money, and the reward card reads it (docs 12 §2.19 D-95/D-96, 91 A91-D-119, 99-PA PA-44)

**The level-up moment names the money, and the reward card reads it** (99-PA PA-44, open since 2026-09-01; ruling 93 §G3). `ui_root._check_city_level` sums the batch's own `level_up_grant_paid` amounts and pushes `ui_toast_city_level_grant` — *"City level 3 — $255,000 paid into the treasury"* — with §2.21's payday chip flash behind it, as ONE toast rather than two (doc 12 §2.15's toasts replace each other). `GoalsModel.reward()` prepends the grant as the card's first line, read from `CostCurves.level_up_grant`, which is also what makes rung 7 a legal level at all: **nothing in `data/buildings.json` unlocks at city level 7**, so §G3's *"a level whose reward card is empty is a number, not a goal"* would have failed on a $5,000,000 payment. `data/ui.json.goals.max_reward_rows` 4 → 5 so no unlock line is displaced. One new preview state, `goals_capstone`, same commit.

*Files: `ui/ui_root.gd`, `ui/goals_model.gd`, `data/ui.json`, `data/strings.en.json`, `tools/ui_preview.gd`, doc 12 §2.19 D-95 / D-96*


### RR-191 — the grant is paid for the LESSON, not for the level (docs 03 §2.5a, 92 §61.12, 93 §AU6)

**`CitySim._pay_level_up_grant` moves off `city_level_changed` and onto `city_level_objectives_met`.** Doc 03 §2.5a's celebration grant is now paid for completing doc 09 §2.14's objectives for a rung, not for crossing the city level; doc 93 §G1's `max()` composition is UNTOUCHED and `Treasury.note_era` still fires on the composed transition (§AP4's era is a permission, and a permission may not depend on how the level was reached). **The reason is measured and it is RR-187's own scale.** At $2,500 a rung, paying on the composed level was a nicety; at this wave's scale it hands agents that never read a goals sheet the curriculum's money. The cleanest statement of it: **`tests/fixtures/bench_city.json` was collecting $135,000 of grants on boot**, for a curriculum it has never touched, and both of its `profile_sim` digests moved when it stopped (§64.3). **A level is a permission and a permission may not depend on how it was reached; a grant is payment for a lesson, and the population backstop teaches none.** The move removes three of the eight assertions the flat first draft of RR-187's table failed; `balanced` completes levels 1 and 2's objectives incidentally, so the other five were dealt with by re-shaping the curve (ruling 93 §AU7, doc 92 §61.12). One-shot-per-rung survives the move structurally: `GoalSystem.earned_level` is monotone, `done` is sticky, `_settle` emits one event per rung, and `bootstrap` drains its own queue — which is what stops a migrated level-6 city being handed the whole table on load.

*Files: `sim/city_sim.gd`, `tests/test_city_services.gd`, `tests/test_balance_gates.gd`, doc 03 §2.5a, doc 93 §AU6*

### 64.1 Every `city_level` consumer, walked (RR-189)

A level the ladder can reach that no data row describes is this project's
signature defect. `grep -rln "city_level"` returns 88 files; these are the ones
that MAP a level to something, and every one was checked against 7:

| consumer | shape | at level 7 |
|---|---|---|
| `data/progression.json city_level_population_thresholds` | indexed by level | **row added** — 40,500, §19.2's 2.25× recipe one rung further |
| `ProgressionSystem.CITY_LEVEL_POP_FALLBACK` | missing-file degrade, gated equal by gate 20 | **row added**, same value |
| `data/economy.json grants.LEVEL_UP_GRANT_BY_CITY_LEVEL` | indexed by level | **row added** — $5,000,000 (RR-187) |
| `data/economy.json pacing_guardrails.MODEL_NET_PER_HOUR_BY_CITY_LEVEL` | indexed by level, a MEASUREMENT | **re-measured, seven cells** — AC-2 says a lane that re-arcs `data/goals.json` re-measures this row rather than re-fitting the curves that read it |
| `data/buildings.json` per-level `min_city_level` | a floor per building level | tops out at 5; nothing new unlocks at 6 or 7, which is why doc 12 D-96 had to put the grant on the reward card |
| `data/building_rules.json min_city_level_by_level` / `_by_growth_class` | indexed by BUILDING level (1–6), not city level | untouched |
| `data/contracts.json min_city_level` | a floor per offer, max 6 | every offer is available at 7 |
| `city_services.STREET_REWARD_CITY_LEVEL_K`, `MANUAL_DISPATCH_LEVEL_K`, `CONTRACT_REWARD_CITY_LEVEL_K` | `(1 + k·(level − 1))`, unbounded | evaluate at 7 with no special case; **gate 32 arms (d2) and (h) now assert the share at seven rungs instead of six**, which is the whole reason they were written as share assertions |
| `data/roads.json road_crew_unlock_city_level` | one threshold, 3 | already unlocked |
| `data/vehicles.json unlock.city_level` | one threshold, 1 | already unlocked |
| `data/world.json t0_city_level`, `LandBlock.min_city_level` | founding value / a floor per block, max 2 | already unlocked |
| `data/notifications.json`, `data/audio.json`, `data/ui.json` | route `city_level_changed` by event, never by level | no level-indexed table |
| `Treasury.note_era(city_level)` | monotone latch | **+1 era** — the one compounding surface, published in doc 92 §61.7 and NOT fixed here |
| doc 08 save shape | `city_level` / `city_level_max` are ints in the `progression` section | **no schema change**; `GoalSystem`'s `done`/`progress` gain twelve string keys inside the existing v3 `city` body, which is additive and needs no section rung |
| `GoalSystem.bootstrap` | completes every level ≤ the city's own | a v2 save restored at level 6 starts level 7 at zero, which is correct: an upgrade leaves no residue and `residue_key` returns `""` for the new kind |

### 64.2 What this lane does NOT touch

* **Gate 29 and the insolvency ordering.** Wave 21's no-spiral lane owns them and
  is running beside this one. The delta this lane creates for it — one more era,
  therefore three more relief grants per city — is published in doc 92 §61.7 as
  filed row **AC-22-1**, not fixed. `Treasury.note_era` stays on the CITY-LEVEL
  transition even though RR-191 moved the grant off it, so nothing about the
  relief ladder's trigger changes; what changes is that there is one more rung
  for it to fire on.
* **The relief ladder itself** (doc 03 §2.10 layer 5). Same owner.
* **The balance matrix, and not one of its gates.** `do_nothing`, `balanced`,
  `tax_squeezer` and `infrastructure_first` never complete a curriculum
  objective, and since RR-191 the grant is paid for completing one — so every
  control agent in doc 92's matrix earns exactly what it earned at the fork. The
  seventh ladder rung does not reach them either: nothing measured in this
  repository has ever crossed 18,000 residents on a played city, let alone
  40,500. **Two balance gates are touched and no more**: 21 (the curriculum arc,
  this lane's to re-fit, doc 92 §61.11) and 20 — its rung-count assertion, which
  stops naming a literal, and its level-2 pacing WINDOW, whose floor moves 8 → 3
  against a measured 6 / 4 / 7. Doc 92 §61.12 has the seven-gate table the flat
  first draft produced, which is the measurement that sent this lane looking for
  a different payment site and a steeper curve rather than for seven re-fits.

### 64.3 The four `profile_sim --hash-only` baselines

| digest | at the fork (`ef08351`) | as shipped |
|---|---|---|
| starter, coarse 24 h | `84e2f9fa91a8bf78…` | **unchanged** |
| starter, fine 2.0 h | `ae602e79a039a27a…` | **unchanged** |
| bench, coarse 24 h | `3ad4e5b59af210b5…` | `dfe20abe47801e5c…` |
| bench, fine 2.0 h | `d5e8192c392b0f2a…` | `2677b9af350c1e00…` |

**The starter pair does not move, and the reason is the shape of the change.** A
founding city is level 0 and crosses no rung inside 24 coarse hours or 2 fine
ones, so neither the grant table nor the payment site nor the seventh ladder rung
can reach it. Both digests are byte-identical to the fork's.

**The bench pair moves, and the cause is EXACTLY ONE THING, isolated by
ablation.** `tests/fixtures/bench_city.json` is 1,500 buildings and 35,411
residents, so it boots straight to city level 6 — and at the fork that paid it
**$135,000** of celebration grants for a curriculum it has never touched. Under
RR-191 it is paid nothing. Two arms, each one command:

* **new payment site + the OLD grant table** → `dfe20abe…` / `2677b9af…`,
  *identical to the shipped digests*. The table is invisible to this fixture now.
* **old payment site + the NEW grant table** → `3ad4e5b5…` / `d5e8192c…`,
  *identical to the FORK digests*, because the fixture's own boot-time grant is
  the only thing either digest ever saw of this system.

So the whole delta is RR-191 and none of it is RR-187, RR-188 or RR-189: a data
table that pays nobody on this fixture cannot move its hash, and neither can a
curriculum row nor a ladder rung the fixture never reaches. **It is also the
clearest statement of why the old routing was wrong** — the profiling fixture was
being handed the curriculum's money.

## 61. WAVE 20 — the spiral has a floor (binding)

*Lane 1 of Wave 20, forked off the Wave-19 merge (`ef08351`), 2026-09-03.
Measured in doc 92 §58, ruled in doc 93 §AR, defect rows doc 91 A91-D-110..112,
doc 12 delta row D-91.*

*Wave 19 shipped §AP1 — wear may condemn private stock, never demolish it — and
the acceptance test for this wave was the player's actual save file, on disk.
`tools/measure_player_city.gd` loads it through the real `SaveService` and
advances it. **On the Wave-19 tree that city went from twelve buildings to zero
in forty-five game-days**, and §AP1's wear roll accounted for none of them. This
lane finds the three doors it did use and puts a floor under each.*

| `profile_sim --hash-only` | at the fork (`ef08351`) | after this pass |
|---|---|---|
| starter, coarse 24 h | `84e2f9fa91a8bf78…` | **`84e2f9fa91a8bf78…`** |
| starter, fine 2.0 h | `ae602e79a039a27a…` | **`ae602e79a039a27a…`** |
| bench, coarse 24 h | `3ad4e5b59af210b5…` | **`3ad4e5b59af210b5…`** |
| bench, fine 2.0 h | `d5e8192c392b0f2a…` | **`d5e8192c392b0f2a…`** |

**All four are UNCHANGED, and that is the wave's own summary of itself.** Not one
authored number moves — `MAINT_CONDITION_PENALTY` 1.5,
`ASSET_CONDITION_PENALTY_COEFF` 2.0, `structural_failure_p_per_hour` 0.02, the
whole `recovery` block and every price stand exactly as Wave 19 shipped them.
Neither reference city holds a ruin, reaches a terminal incident or brings a spine
building to the structural-failure line inside 24 game-hours, so every ruling here
is dormant on a healthy city and load-bearing only under a fallen one. Nothing in
the balance matrix moves: `do_nothing`, `balanced`, `tax_squeezer` and
`infrastructure_first` earn what they earned, and gate 29's insolvency day is
untouched.

### RR-174 — the acceptance test is a file, not a fixture: `tools/measure_player_city.gd` (docs 92 §58.1, 93 §AR)

Every catastrophe instrument this project owns measures a city it generated.
`probe_neglect.gd` grows one, `playtest.gd` plays one, `measure_catastrophe.gd`
warms one with the `balanced` agent and calls it "within a few percent" of the
player's. It was not within a few percent of anything that mattered: doc 92 §56
concluded 42 of 42 destructions came through wear and 0 through fire; on the file
it is 0 through wear and 10 of 11 through fire.

The tool loads slot 0 through the real ladder and the real seven-check gate,
advances it on the real coarse path, and prints the census in the shape the
report asks for — ALIVE and DESTROYED, split `private` / `CIVIC` by doc 02 §2.6a's
`owner_maintained` and by archetype — plus the treasury/deferred/relief
trajectory, doc 03 §2.4's expense lines for the last settled hour, and a
`--restore` arm that plays the one verb a fallen city has.

**Three things it had to get right, each of which was wrong first:**

* **A private `user://`.** Every worktree resolves `user://` to the same shared
  directory and the save must be *in* `user://saves` to be found, so the tool
  takes `tests/user_dir_isolation.gd`'s three switches, copies the slot into a
  per-process directory and sweeps it at exit. Its recursive delete refuses any
  path not carrying its own marker.
* **The head-align.** Slot 0's `sim_time_minutes` is 239,884 — 4.4 minutes past
  game-hour 3,998 — and `TickScheduler.advance_coarse_n` asserts hour alignment.
  Without `CatchUpPlanner.plan()`'s first segment the assert fires once per hour
  and **the city does not move**, which reads exactly like a city that has
  stopped falling.
* **Attribution by roster diff.** The bus reported one destruction where the
  census showed twelve — which is RR-175.

### RR-175 — a building the city loses is a building the city is TOLD about (closes `A91-D-110`; docs 93 §AR2a)

`CityIncidentWorld.apply_building_damage` and `destroy_building` called
`Building.apply_damage` / `burn_down` / `demolish` and **threw away the event
array all three return**. So a building taken down by a doc 06 cascade op emitted
nothing: no `building_destroyed`, no `building_damaged`, no notification, nothing
for `GoalSystem` — which lists `building_destroyed` among the events it watches —
and nothing a report could count. Measured on slot 0: **12 of 12 destructions
were silent across 45 game-days.** The player's city was erased through a door
that never announced itself, which is why the report reads *"ALL of my buildings
are destroyed"* rather than *"I watched them go"*.

`_publish` stamps `sim_id` and the post-transition `condition` exactly as
`CitySim.apply_hourly_decay` does, so a subscriber cannot tell a wear death from
an incident death by the event's shape, only by its `cause`. That stamp also
fixes the join underneath: `Building._destroy` puts the **int** `Building.id` in
`building`, while every roster key is the authored **string** sim_id (`P-077`,
`H-001`), so anything joining on `building` attributed nothing.

`burn_down` answers in `CommandQueue`'s envelope and the other two answer with a
bare array; the adapter reads `payload.events` for the first and the return value
for the others, and an offline refusal carries no payload and reads as empty,
which is right — nothing happened.

### RR-176 — the city is not billed for its rubble (docs 03 §2.4, 92 §58.2, 93 §AR3)

`CitySim.build_settlement_inputs` skips `state == &"destroyed"`;
`CityIncidentWorld.station_rows` skips destroyed and planned shells.

`roster_ids()` keeps a ruin in the roster — that is what makes RESTORE possible —
and every row that loop appended was billed. `E_building_maint` charges the
`buildings` array, `E_departments` charges `stations`, and neither ever asked what
state the building was in. **Both scale on `1 − condition`, and a ruin's condition
is exactly 0**, so a destroyed building was billed **2.5×** and a destroyed
station **3.0×** what the same asset costs in perfect repair. Every building that
died made the city's bill go up: a ratchet with no floor, and the death spiral's
actual engine.

On the player's slot 0 at load: **$1,044.39/gh of $1,055.12 (99.0 %) of
`E_building_maint` and all $306.00/gh of `E_departments` were charged against
buildings that are rubble — $32,409 a game-day, against a gross of $2,998.**

The ruling is doc 93 §Y1's own sentence read on the other side: §Y1 kept
`E_building_maint` by defining it as *the city's cost of SERVING a building*, and
a ruin is served by nothing — no power, no water, nobody housed
(`state_occupancy()` is 0.0 for `destroyed`, so it already pays $0 of tax and
contributes $0 of `potential`, which is what doc 03 §2.10 layer 1's revenue floor
is measured on), no traffic. `station_upkeep` is STAFFING and a ruin has no
staff. `station_rows()` is `FleetSystem.populate_from_stations`'s only source, so
a ruined station there also gave doc 06 a garage that does not exist and doc 03
an `E_fleet` line for it — **closed for the BOOT path only**, because
`FleetSystem.deserialize` rebuilds the roster from the save and `sync_station`
never fires on a destruction, so a station lost mid-run keeps its engines and
slot 0 still pays $91.58/gh for four ruined shells after 45 game-days. Recorded
as A91-D-111's open remainder rather than claimed: retiring a unit on destruction
means retiring one that may be dispatched, en route or on scene.

**Losing a building still hurts.** The lot is dead capital until it is restored —
no tax, no coverage, no power, no water, and `restore_cost_building` to bring it
back — and `E_roads_repair` still bills the street outside it, because the street
is still there.

### RR-177 — an incident the city could not answer condemns; it does not demolish (docs 02 §2.6, 06 §2.10, 92 §58.4, 93 §AR2)

`Building.condemn_unanswered(destroy_allowed)`;
`Building.apply_damage(fraction, now_minutes, may_destroy)`;
`IncidentSystem.incident_was_answerable(inc)`;
`CityIncidentWorld._has_fire_department()`. The two doc 06 building-destroying
verbs on `IncidentWorld` take an `answerable` argument defaulting to `true`, so
every adapter and caller that predates the ruling behaves exactly as it did.

With no fire station standing, the player's city answered nothing: **431 incidents
abandoned, 17 failed and 11 buildings burned down in fourteen game-days**, ten of
the eleven through `burn_down`. There is no move that fixes that — the station is
a ruin and restoring it costs money the collapse has already taken — so the fire
door was an unbounded ratchet driven by the absence of a purchase the player could
not make.

**"Could not answer" is three facts the game already records, and none is a
choice the player made:** nothing committed to the incident AND `DispatchSystem`
marked it `unreachable` (it had units, had permission, and doc 10's graph offered
no route); the city has no fire station standing at all; **and
`Treasury.austerity_active`** — doc 03 §2.10 layer 2 lists `construction` in
`AUSTERITY_BLOCKED_CATEGORIES`, so under austerity the game itself refuses to let
the player build a station or repair the road. **The third clause is gate 29's**:
without it a `do_nothing` city that let its own station rot, sitting on a peak
balance of $397,081, got the same protection as a player whose station a
catastrophe took at −$22,624. §AR2 protects an option the rules removed, not a
choice the player made.
`dispatch_blocked_no_units` is deliberately excluded — a department with no free
engine is a fleet-sizing choice, and doc 06 §2.16's dispatch economy rests on that
choice having consequences. The department test is a city-level fact and not a
per-tile coverage reading, because gating on `coverage_fire(tile)` would make
"build far from the station" a fireproofing strategy.

**Both doors, or the ruling buys one game-hour.** §AP2's damage floor is
conditional, so a building already at the line is finished by the next event.
Doc 92 §58.4 measured the condemn-only arm: the same twelve buildings still went,
with `cause: damage` in place of `cause: fire`. `may_destroy` makes §AP2's floor
absolute for a city that could not defend the building, and leaves §AP2 exactly as
it was everywhere else.

**The anti-farm is an inequality, not a fee.** A fire still condemns the building
it reaches (doc 02 §2.12: `output_mult` 0.40, `coverage_mult` 0.25, doc 03's
`f_condition` 0.46), the city loses fire coverage everywhere at once, and nothing
the fire fleet answers gets answered — while a station's upkeep buys SUPPRESSION,
which leaves the building earning. A mutual-aid fee was considered and rejected:
a bill an insolvent city cannot pay becomes deferred liability, which is this
ratchet in a different hat.

### RR-178 — wear may not take the last power plant (docs 02 §2.6, 92 §58.6, 93 §AR1)

`data/building_rules.json utility_spine`;
`BuildingCatalog.is_utility_spine` / `wear_may_demolish_for`;
`Building.roll_structural_failure`'s guard loses its `owner_maintained and`
conjunct and reads the one stamped flag.

§AP1 ruled that an owner boards up a condemned building rather than bulldozing it
*because it is their asset*, and then listed the city's own civic and utility
stock as an exception. The city is the owner of a power plant, and on slot 0 the
exception had already taken both plants, all three water facilities and both
substations — leaving twelve buildings in permanent darkness, §Y1a's service
clause lifted city-wide, and no way back because the treasury was $22,624 under
water.

**The line is the SPINE, not all civic stock.** `power_facility`, `substation`
and `water_facility` are condemned by wear and never demolished by it; police,
fire and the construction yard stay losable, because losing coverage is a loss a
player can see on the overlay, price from the build menu and rebuild out of,
while losing the last plant costs everything at once and is unrecoverable while
insolvent. A condemned plant rests at the structural-failure line in `damaged`,
where §2.12 still pays `output_mult` 0.40 — **a neglected city browns out to two
fifths of its generation and never goes dark for good.**

`BuildingCatalog._check_utility_spine` refuses a block naming an archetype that
does not exist (the same failure `owner_maintenance.classes`'s check exists to
stop one field over), and it runs after the archetypes are loaded rather than in
`_load_rules`, which runs first and would reject every name. A fixture carrying no
`utility_spine` block keeps the pre-Wave-20 physics exactly.

**Not a shield:** an unanswered tier-5 fire in a city that CAN answer, doc 06's
explicit `destroy_building` op in a city that can answer, §AP2's second event, and
the player's own demolish all still take a plant down.

### The acceptance test, published

| | fork (Wave 19) | this pass |
| --- | --- | --- |
| standing @ game-day 14 | 4 | **12** |
| standing @ game-day 45 | **0** | **12** |
| destructions in 45 game-days | 89 total, 12 in-run | **0** |
| last power plant @ 45 | gone | **alive** |
| treasury @ 14 | −$20,000 | **+$68,464** |
| population @ 45 | 0 | 40 |
| with `--restore=5000`, standing @ 15 | 80, back to 21 by day 25 | **80, 68 at day 45** |
| with `--restore=5000`, fire destructions | 69 | **0** |

**The suite**: `tools/run_suite.sh` — **2,766 tests, 579,661 asserts, failed 0,
silent 0**. Gate 29 is re-fitted with the attribution in doc 92 §58.7 and the
derivation in `test_balance_gates.gd` itself; every other gate is untouched.
`python3 tools/check_doc_refs.py` prints *all resolving; no id assigned twice*.

Relief is unchanged and pays what it always paid: **$296,181 in three grants
inside fifteen game-days, 105 % of the city's entire $282,078 restore bill.** The
lane brief's "$2,624 of relief across fourteen game-days" is `Treasury.settle`'s
credit-limit clamp booking a $2,624 overshoot into deferred liability — the
opposite of a payment. Doc 93 §AR4 states what is not ruled and why.

## 63. WAVE 21 — a fire nobody could answer (binding)

*(Measured in doc 92 §60. Rulings in doc 93 §AS. Defect rows doc 91 A91-D-115,
A91-D-116, A91-D-117. Delta row doc 12 §2.19 D-94.)*

Wave 20's lane 1 was rejected at merge and this wave finishes it. Its
rubble-billing ruling (§AR3) and its utility-spine ruling (§AR1) are **kept
unchanged and re-measured**; its fire ruling (§AR2) is **replaced**. The five
resolutions below are the whole of the difference.

### RR-182 — §AS1: capability, not wealth, decides whether a fire may destroy (replaces `RR-177`; docs 02 §2.6, 06 §2.10, 92 §60.1/§60.2/§60.5, 93 §AS1)

`CityIncidentWorld._could_have_answered` loses its opening line —
`if sim.treasury != null and not sim.treasury.austerity_active: return true` —
and becomes `has_fire_capability() and answerable`. `has_fire_capability()` is a
`fire_station` STANDING (`active`, `damaged` or `repairing`) **and** a
`FleetSystem` unit that answers the `fire` role. No money is read anywhere.

**The deletion is not a preference, it is two measurements** (doc 92 §60.2).
(a) The clause switches itself off: relief lifts austerity on game-day 11 and the
player's roster goes 12 → 6 in that window, the last power plant included.
(b) Held under the line it is total immunity: 76 buildings alive at game-day 45
and the identical 76 at game-day 90, zero destructions in 45 consecutive
game-days, while the bus emitted `building_destroyed_by_fire` 8,938 times.

**What still burns down.** A city with a station and an engine loses buildings to
fire exactly as before, including when every engine is already out —
`dispatch_blocked_no_units` stays ANSWERABLE, because fleet size is a purchase.
**The anti-farm is priced**, not asserted: a level-1 fire station is $30.00/gh and
each building it keeps off the condemned rung is worth ≈$9.00/gh, so it breaks
even at 3.3 buildings (doc 92 §60.5).

### RR-183 — §AS2: a gutted shell is not fuel, and an owner boards it up rather than rebuilding it (docs 02 §2.6/§2.6a/§2.12, 06 §2.6/§2.8, 92 §60.3/§60.7, 93 §AS2)

`Building.burnt_out` — set by `condemn_unanswered`, lifted by `complete_repair`,
`complete_construction` and `_destroy`, read by `state_fire_mult`, by
`IncidentWorld.state_fire_mult_of` and by a seventh `fire_candidate_columns`
column. `Building._owner_maintain` HOLDS a gutted shell at the structural-failure
line and does no more. `CitySim.cmd_repair_building`'s `E_OWNER_MAINTAINED`
blocker gains exactly one exception, the gutted shell, so the player has a paid
way out of it.

**Without the bound §AS1 has no floor.** A condemned building rests where
`state_fire_mult` is 1.8 and `fire_condition_mult(0.10)` is 2.28 — 4.1× a healthy
building's ignition rate — so the fork produced 7,379 incidents in 45 game-days
on a 76-building city. With the flag lifting on the owner's free rebuild it was
still **14,071 terminal fires in 90 game-days**; with the hold it is **65**, on
an identical roster (doc 92 §60.7).

**`Building.serialize()` writes the key only when true**, because it is inside
`state_hash()`.

### RR-184 — §AS3: an event storm is its own defect, and so is an event that lies (docs 06 §2.16, 92 §60.3, 93 §AS3)

`DispatchSystem._emit_blocked`'s one-slot de-dup becomes a SET of the reasons an
incident has already announced, cleared on assignment.
**279,071 `dispatch_blocked_unreachable` in 45 game-days** (the lane brief's
reading on the merged tree; this branch re-measures the fork at **255,050** over
the same 45 and **466,321** over 90) **→ 14,100 over 45 and 29,685 over 90**,
which is **1.01–1.02 announcements per incident**: the floor, not a target.

`IncidentWorld.destroy_building` now returns whether it destroyed, and
`CascadeOps` emits `building_condemned_by_fire` when it did not. On the fork,
3,891 `building_destroyed_by_fire` in 45 game-days named buildings the census
still shows standing.

**And the instrument that should have caught it could not see the call at all.**
`tests/test_event_matrix.gd` reads emitted names out of `sim/` with a regex over
`bus.emit(` and `_emit(`; doc 06's `CascadeOps` publishes through
`IncidentSystem.emit_event`, whose body calls `_emit(type, …)` with a VARIABLE,
so **five call sites and four event types were invisible to the matrix** —
`incident_notify`, `destroy_refused_offline`, `power_component_destroyed` and
`building_destroyed_by_fire` itself. The pattern now includes `emit_event(`, the
three bookkeeping types carry written classifications, and **both** of a fire's
endings are rows in `data/ui.json.event_log` — the harsher one had never been on
the feed at all. The matrix reads 168 types emitted / 98 consumed / 70
classified, against 163 / 96 / 67 before.

### RR-185 — §AS4: an era of relief may not out-pay the bill it is measured against (docs 03 §2.10, 92 §60.4, 93 §AS4)

`Treasury.relief_era_paid`, persisted, reset by `note_era` with the allowance it
belongs to. `damage_term = max(0, RELIEF_DAMAGE_FRACTION × bill −
relief_era_paid)`. §AP4's inequality — "0.35 < 1, so the grant never covers the
bill" — was true per grant and false per era at 3 × 0.35 = 1.05; the shipped
build paid **$306,233 against a $296,438 bill (1.033×)**, and the unit control
returns **$311,259**, which is 1.050× to the dollar. No new constant is
authored: the cap is the fraction that was already there, applied to the era.
`RELIEF_MIN` and the revenue term stay outside it, for the reasons in §AS4.

### RR-186 — what this wave measures, what it kept, and what it did not fix (docs 92 §60, 93 §AS5)

**Kept from the rejected branch, verbatim and re-measured**: §AR3's `state ==
destroyed` guard in `CitySim.build_settlement_inputs` (the city is not billed for
its rubble — $1,044.39/gh of $1,055.12 `E_building_maint` and $306.00/gh of
$306.00 `E_departments` were charged against ruins at the maximum rate both lines
can charge, $32,409 a game-day against a $2,998 gross), §AR3's `station_rows()`
boot guard, §AR2a's event publishing, and §AR1's utility spine.

**The acceptance test** (doc 92 §60.1, §60.8), the player's own slot 0:

| | passive | Restore All every game-day |
| --- | --- | --- |
| alive @load / @14 / @45 / **@90** | 12 / 12 / 12 / **12** | 12 / 71 / 68 / **68** |
| utility spine @90 | `power_facility ×1` | `power_facility ×1`, `substation ×2` |
| destroyed in 90 gd | **none, any cause** | 3, all `structural_failure` on §AR1's losable civic stock |
| population @90 | 6 | 45 |

**Not fixed, and named**: the treasury does not recover on either arm — `E_grid`
+ `E_roads_repair` + `E_fleet` are $478.77 of a $556.27/gh bill against a
$118–138/gh gross, for 89 lots of road and a grid sized for 450 people.
`E_fleet`'s $91.58/gh with no station standing is §AR3's recorded remainder (doc
91 A91-D-111 / A91-D-115); the other two are doc 03's. A collapsed city also runs
at doc 06's saturation ceiling continuously — 28,573 incidents in 90 game-days,
bounded but loud, because every abandoned incident costs district stability and
`f_arson` triples at stability 0 (doc 91 A91-D-117).

**The suite**: `tools/run_suite.sh` — **153 files, 2,780 tests, 581,193 asserts,
failed 0, silent 0.** `python3 tools/check_doc_refs.py` prints *all resolving; no id
assigned twice* over 5,099 references. Not one balance constant moves
(doc 92 §60.11), and the four `profile_sim` baselines move on exactly one
`Treasury.serialize()` key, proven by A/B (doc 92 §60.10).

## 65. WAVE 23 — the predicate measured the shell, not the service (binding)

*(Measured in doc 92 §62. Rulings in doc 93 §AV. Defect rows doc 91 A91-D-121,
A91-D-122, A91-D-123. Delta row doc 12 §2.19 D-97.)*

Wave 21's fire floor is **kept, and it is why this save is playable at all**: the
acceptance test's passive arm is unchanged at 12/12/12 with zero destructions of
any cause, and its Restore-All arm improves. What this wave corrects is one word
in §AS1 — *capability* meant a BUILDING, and the ability to answer a fire is not
a building. It lives in `FleetSystem`, and doc 93 §AR3's own finding is that the
engines outlive the shell on every destruction path in the game.

Five resolutions. Four are the four consequences Wave 21's own adversarial
verifier measured and merged deliberately as strictly-better-than-dying.

### RR-192 — §AV1: capability is the SERVICE, and the hazard names its own service (corrects `RR-182`; docs 02 §2.6, 06 §2.6/§2.10, 92 §62.1/§62.2, 93 §AV1)

`CityIncidentWorld._could_have_answered(answerable, role)` is
`has_service_capability(role) and answerable`. It still reads no money anywhere.
Two changes:

* **The shell half is deleted.** `has_service_capability(role)` is one fact: a
  `FleetSystem` unit whose `resolve_rate` answers `role` and that is not parked
  `OFFLINE`. `has_fire_capability()` survives as its fire reading, because doc
  92's gates assert on that name.
* **`role` is the incident's own `primary_role`**, supplied by the new
  `IncidentSystem.incident_primary_role` and carried on both damage doors —
  `IncidentWorld.apply_building_damage(id, fraction, answerable, role)` and
  `destroy_building(id, cause, answerable, role)`, defaulting to the fire role so
  a caller that predates the argument behaves exactly as it did.

**The measurement, on one tree, on the player's own save** (doc 92 §62.1):
`fire_station shells standing 0 | fleet 14 units (fire 1, …) | §AS1 shell reading
false -> §AV1 service reading true`. Both readings taken at the same instant by
`tools/measure_player_city.gd --service-audit`, so the correction is a
measurement and not a derivation from the diff. The city was being told it had no
fire service by a predicate that could not see the fire service, while paying
$91.58/gh of `E_fleet` to keep it.

**And the same predicate was ruling about floods.** `CascadeOps`'
`building_condition` op is the door EVERY hazard's damage goes through, so under
§AS1 a city with no fire department could not lose a building to water or wind.
Doc 92 §62.2's probe is deterministic and fails on the fork.

**Two things §AS1 got right and this keeps.** Availability is not capability — a
unit on another call or in `REFIT` still counts, because doc 06 reads
`dispatch_blocked_no_units` as ANSWERABLE and fleet size is a purchase. And the
predicate is still a city-level fact and not `coverage_fire(tile)`, because
gating the CONDEMN door on coverage makes "build far from the station" a
fireproofing strategy.

**The door to the exemption is now one verb**: `FleetSystem.remove_station`,
reached from doc 02 §2.12's demolition — the player's own bulldoze. A fire can no
longer buy it for you. RR-195 is the ruling that the bulldoze has to lose.

### RR-193 — §AV2: `RELIEF_MIN` is inside the era ceiling (corrects `RR-185`; docs 03 §2.10, 92 §62.5, 93 §AV2)

`Treasury.maybe_grant_relief` charges the FLOOR to the era, and only the floor:

    payable = max(revenue_term, damage_term)
    if payable < RELIEF_MIN and relief_era_paid < RELIEF_MIN:
        payable = RELIEF_MIN          # the bottom rung, once per era

§AS4 charged the two TERMS against the era and left `clampi(…, RELIEF_MIN, …)`
outside both — and a floor is not a term, it does not shrink. So
`RELIEF_MIN × relief_grants_per_era` = $8,000 × 3 = **$24,000 an era pays whatever
it was measured against**, and a $2,000 bill drew **12.0× itself** while §AS4's
heading claimed an era may never out-pay its bill. **The guarantee, stated
exactly: an era receives `RELIEF_MIN` at least once, and after that a grant is
worth what it is MEASURED on.** `relief_grants_per_era` can no longer multiply
the floor, which is the defect. It does NOT promise that an era is bounded by its
bill: $8,000 against $2,000 is 4.0×, down from 12.0×, and that residual is
published (doc 92 §62.5) because doc 03 §2.10 layer 5's bottom rung is not
negotiable — a city whose stock is all standing but dark has a $0 bill, a $0
revenue term and every reason to need rescuing.

Measured: the $2,000 rig falls **$24,000 → $8,000**; the player's slot 0 passive
arm falls **$114,727 → $107,467** (its third grant priced at its own $740 revenue
term instead of lifted to $8,000 for the third time) and its Restore-All arm
**$114,727 → $114,668**, where the damage term is still what pays. **Two wider
drafts were tried and the suite killed both** — a per-era ceiling of
`max(revenue_term, bill)` takes the bottom rung from a city with nothing to
measure (`tests/test_relief_ladder.gd`) and nets the revenue term against past
grants (`tests/test_economy.gd` gate 18), which doc 03's own docstring forbids in
words. An ask that prices to zero is not paid and does not spend one of the era's
three rescues — it does stamp the cooldown, so the O(roster) bill walk cannot run
every settled game-hour.

### RR-194 — §AV3: the water-works staffing follows the plant, not the graph (completes `RR-178`; docs 03 §2.4, 05 §2.6, 92 §62.4, 93 §AV3)

`CitySim.build_settlement_inputs` claims to be "the sole author of both arrays"
and is not: the `water_works` row is appended by a second loop over `water.nodes`,
keyed on a pump existing in the GRAPH. A DEMOLISHED `water_facility` takes its
nodes with it (`_retire_water_nodes`); one that BURNS DOWN does not — the same
path §AR3's own hole opened on. The pump's `power_ref` IS its host shell, so a
pump whose host is rubble is no longer staffed; a node with no host is billed
exactly as before.

Measured on the player's slot 0 at game-day 90, passive arm: `E_departments`
**$11.00/gh → $0.00** (that is doc 03's $20.00 through the city's own 0.55
`m_exp × austerity_mult`), total expense $556.27 → $545.27/gh, deferred liability
$1,374,124 → $1,357,568. **$480 a game-day of wages for three plants that do not
exist.**

### RR-195 — §AV4: a fire station buys prevention, not only response (docs 02 §2.9, 06 §2.6, 09 §2.11, 92 §62.6, 93 §AV4)

`data/incidents.json` `factors.fire` gains `coverage_base` 1.0, `coverage_slope`
0.4286, `coverage_min` 0.5714, `coverage_max` 1.0, and
`IncidentSystem._structure_fire_rates` multiplies its per-building rate by
`clamp(coverage_base − coverage_slope × the district's fire_coverage, min, max)`
— at exactly the place doc 06 §2.6(a)'s crime rate already multiplies by
`f_police`. `CityIncidentWorld.district()` gains the `fire_coverage` key beside
the `police_coverage` it has always carried.

**NO NEW MAGIC NUMBER.** The slope is crime's own full-coverage reduction,
`police_slope / police_base` = 0.6 / 1.4 = 0.4286, re-anchored at 1.0 so an
UNCOVERED city's fire rate is exactly what it has always been. A catalog without
the four keys reads slope 0.0 and is bit-identical to the pre-§AV4 build.

**Why it is needed.** §AV1 makes the predicate honest and that alone makes the
incentive WORSE: with the floor keyed on not owning a service, the cheapest fire
insurance in the game is to have no fire service. Doc 92 §62.6 measures 90
game-days on a founding city, three arms, the `none` arm bulldozing through the
real command so it collects the refund: **keep 32 alive / $322,479, burn 31 /
$260,098, none 31 / $267,443.** Owning and keeping the department is the best arm
on both numbers — **+1 alive and +$55,036** — while paying $30.02/gh more to hold
it, and the worst arm is `burn`: bought and left to rot.

**A/B, one line of data:** with `coverage_slope` alone at 0.0 the keep arm returns
to 31 alive / $281,360, so §AV4 is worth +1 alive and +$41,119 of that advantage.
This is not the farm §AS1 refused — coverage in the IGNITION rate runs the other
way, so building far from the station gives you MORE fires, not fewer.

**It also answers doc 91 A91-D-117's own prescription** ("a floor under the
stability term, or a coverage-aware generation damper"): 30,610 incidents born in
90 game-days with no department, 26,944 with one — **−12.0 %** — on the player's
own save.

### RR-196 — the instruments, the gates and the four baselines (docs 92 §62.6/§62.8)

`tools/measure_fire_incentive.gd` is new: three arms on a founding city, a printed
verdict, and the inequality checked rather than asserted in prose.
`tools/measure_player_city.gd` gains `--fire-dept=keep|burn|none` and
`--service-audit`, and the arms' reinstatement is free in every arm on purpose —
charging it would make them differ by a restore bill as well as by a department.
`tools/probe_fire_coverage.gd` prints the district scalar the ignition rate
actually reads.

**The four baselines: one of four moves, and its cause is isolated by ablation.**
Setting `coverage_slope` to 0.0 returns the bench coarse digest to
`db934239…88a1`, bit-identical to the fork, with the other three untouched — so
§AV4 is the sole cause and §AV1, §AV2 and §AV3 move no baseline at all. Doc 92
§62.8 carries the digests and the commands.

### §65's open questions, ranked by what breaks if nobody takes them

1. **`tools/playtest.gd` has no water-headroom PLANNER, and the curriculum's
   capstone is decided by that.** Doc 91 A91-D-123, and doc 92 §62.9 is the
   measurement: seed 1337 on a 75-game-day horizon ends at curriculum level 6
   holding **13,946 residents, $3,633,922 and one water works**. It is the reason
   gate 21's capstone count is 1 and not 3, and until it is fixed **every wave
   that perturbs doc 06's incident stream will look like a curriculum
   regression**. `_relieve` already answers `E_WATER_HEADROOM` by buying a pump;
   what is missing is buying it BEFORE the refusal. First, because it is now
   costing other lanes their attribution.
2. **A fire station cuts its district's ignition rate by up to 42.9 % and no
   screen says so.** Doc 12 D-97. §AV4 makes coverage a real mechanic and the
   only surface that mentions coverage is doc 02 §2.9's radius overlay. This is
   PA-44's shape one wave earlier in its life — an unlabelled number the player
   is expected to make a purchase decision on.
3. **The condemn floor cannot be judged on a city whose roads are gone.** Doc 93
   §AV5. Doc 92 §62.6's rig 1 ties all three arms at 65 buildings with the
   treasury pinned at the credit floor, because neither number the gate is stated
   in can move there. Every future ruling about departments will hit the same
   wall on that save, and the instrument it needs is a mid-collapse rig — a city
   that is falling but still has roads — which this project does not have.
4. **`E_fleet` bills $91.58/gh for engines whose garage is rubble, and under
   §AV1 that is now CORRECT.** Doc 91 A91-D-111's remainder should be re-read
   rather than carried: those units are the city's service, they answer calls,
   and the predicate now says so. What is still worth asking is whether a city
   should be able to DECOMMISSION them without bulldozing the shell — today the
   only door is demolition, and §AV1 makes that door consequential.
5. **`coverage_slope` 0.4286 is derived from crime's ladder, not fitted to
   fire.** It is the honest way to author a number with no fire-specific
   evidence, and it is not evidence about fire. The lane that owns doc 06's
   escalation ladder should re-derive it against a measured fire arc, and doc 92
   §62.6 is the rig that would judge the answer.

### §65's whole-suite reading, and the shape of what this wave shipped

**Suite: 153 files, 2,798 tests, 582,843 asserts, failed 0, silent 0.**
**Balance gates: 33 tests, 445 asserts, failed 0, silent 0** — one cell re-fitted
(doc 92 §62.9) and not one other constant moved. **Doc references: 5,365, all
resolving, no id assigned twice.**

**The suite is in the record as an INSTRUMENT this wave, not as a formality.**
It failed 2 of 2,798 on §AV2's first shipped draft, both of them guarantees this
ladder already held and argument had missed — the bottom rung for a city with
nothing to measure, and the revenue term being collectable more than once in an
era. Doc 93 §AV2 carries both, and the narrow ruling is what survived them.

**No file in `ui/` or `game/` changes.** A wave that rewrites what *"this city
cannot answer a fire"* MEANS and touches no screen is a wave whose surfaces were
built to read the sim rather than to re-derive it — doc 12 D-97 carries that as a
row rather than as an absence, because a future reader finding no D-row could not
tell the two apart.

**What the diff actually is.** Four rulings, and three of them are one expression
each: a predicate that reads `FleetSystem` instead of the roster, one `if` around
a grant's floor, a `continue` on a pump whose host is rubble. The fourth is one
multiplication in doc 06's ignition rate and four numbers in `data/incidents.json`
derived from four that were already there. The rest is measurement, argument and
the tests that make both falsifiable.
## 67. WAVE 24 — why the population does not visibly count up (binding)

*(Measured in doc 92 §64. Rulings in doc 93 §AX. Defect rows doc 91 A91-D-127,
A91-D-128. Delta row doc 12 §2.25 D-100.)*

The player, on their own city, 2026-09-04: *"As I'm building up houses and have
new residents that pop up, I don't get an increase in population like people. I
don't see it actually counting up."*

**It is a latency report and it was measured, not argued.** From the tap to the
number changing is **176 real seconds at 1× speed** — 120 s while the shell goes
up contributing nothing, then up to 60 s waiting for doc 01's hourly settle —
and when it moves it moves in one jump, 144 → 148. The counter is right. Three
resolutions follow: the one place it was genuinely wrong, the surfaces that were
contradicting it, and one published curve that turns out not to run.

### RR-202 — a city may not report a population it does not have (docs 08 §2.8, 09 §2.10, 92 §64.3, 93 §AX1, 91 A91-D-127)

`PopulationSystem.settle_aggregates(buildings)` — pass 1 of `advance` and
nothing else — called at the end of `CitySim.boot()` and at the **end** of
`_restore_finish`, plus a `deserialize` that no longer lets the previous city's
totals survive into the new one.

The aggregates are derived and doc 08 does not persist them, and `advance` runs
once per game-HOUR, so both doors into a city opened on `city_population == 0`.
A fresh boot held it for one SimTick; **a restore held it for 220 ticks = 55
REAL SECONDS** on a save taken 21 ticks past the hour (doc 92 §64.3, measured by
the instrument this wave commits). `main.gd` paints the HUD before the first
tick and again the instant a save lands, so a 144-person city greeted its owner
with a `0` in the chip — *"my city is empty"* — and `build_director_inputs`,
`goal_state_view()` inside the restore itself and doc 07's `storm_ready_earned`
all read the same zero. The last of those prices Storm Ready against `pop /
1000` and therefore **cannot award it at all** while the population reads zero.

**Two things the call deliberately does not do**, and they are the ruling
(§AX1): it takes no `dt_h`, so `attractiveness` is not relaxed and no time
moves; and it does **not** write the `occupancy` map, which is the one part of
the class doc 08 persists and which doc 03 bills the first hour after a load
against through `occ_of`. A derived number may be recomputed; state may not.
`tests/test_city_sim.gd` asserts both halves — the loaded city reports its
population before its first tick, **and** its `state_hash` after six further
game-hours still equals the uninterrupted run's.

**And a third, which only the whole suite could find.** Placed at the TOP of
`_restore_finish`, the settle handed `_restore_goals`' reconcile a population
the save does not record; `GoalSystem.serialize` writes `done`, `progress` and
`earned_level`, all three of them in `state_hash`, and on the 1,500-building
benchmark city that completed objectives the booted-and-saved city had not —
`tests/test_save_migration.gd::test_37_…` failed on it, and on nothing smaller.
The settle is therefore the LAST line of `_restore_finish`, and §AX1 states the
rule it broke: **a restore may not teach the curriculum something the boot it is
restoring into does not know.**

### RR-203 — two surfaces were telling the player different things (docs 12 §2.25 D-100, 92 §64.1, 93 §AX3)

`CitySim.settled_residents(sim_id)` — one accessor, on the same product the
hourly settle sums — behind both of the surfaces that talk about residents.

**The panel of the house the player had just placed read `Occupants 4`.** That
is the AUTHORED capacity, and it sat beside a population chip that had not moved
and would not move for another three minutes. The chip was right. The vital now
reads `0 of 4` while the shell is up and `4` once it is full, so a building
stops claiming residents the city has not counted; and `CityHUD._note_population`
pulses the population chip on the frame the number changes, on Wave 14's
existing `flash_chip` mechanism, so A8's reduce-motion suppression already
covers it and 176 seconds later the payoff announces itself. `HudModel.
FLASHABLE_CHIPS` generalises `_process`'s expiry sweep from the treasury alone
to the set of chips whose pulse can only have come from a flash — `grid` and
`water` may never join it, because they carry §2.4's standing pulse.

**And S5 was a still photograph, which is the third finding of this wave**
(doc 91 A91-D-136). `BuildingPanel.refresh()` has documented itself since Wave 5
as the re-read *"after an upgrade, a tick, or a construction completion"* and
**nothing outside `tests/` has ever called it** — `ui/ui_root.gd` calls
`land_panel.refresh()`, which is a different panel and is what made the absence
read as present in a grep. An open panel showed the city as it was at the moment
of the tap and never moved again, so a vital that now says `0 of 4` could never
go on to say `4 of 4` while the player watched. `UIRoot.refresh_building_panel()`
is the door, on `refresh_land_panel`'s exact shape and cost, called from
`_refresh_hud`'s 1 Hz cadence (snippet handed to the lead).

Preview state **`building_moving_in` in the same commit**: a house placed
through the real `cmd_place_building`, panel open, `0 of 4` on its face.
`--screen=all --size=412x915 --audit --strict` exits **0** over **84** states.

**Merge note (2026-09-05, the verifier's 56-second window).** As shipped by the
lane, `settled_residents` was the LIVE product `state_occupancy × ramp ×
attractiveness`, which runs ahead of the chip by up to 59 game-minutes: the
shell completed at minute 120 and the vital read a full house while the chip
stayed at 144 until the hour-3 settle at minute 176 — the contradiction moved
from 0–120 s to 120–176 s. Closed at the merge: `PopulationSystem.settled_occ`
(unpersisted, unhashed, written by both `advance` and `settle_aggregates`) is
what the last settle counted per building, and `settled_residents` reads it —
`0 of 4` until the chip has counted them, then `4 of 4` (the bare `4` the lane
emitted for a full house is gone; the docs above said `4 of 4` and now the code
does). `tools/measure_population_lag.gd` shows the vital and the chip moving on
the same settle.

### RR-204 — doc 09's occupancy ramp does not run in the shipped game (docs 09 §2.10, 92 §64.2, 93 §AX2, 91 A91-D-128) — PUBLISHED, NOT FIXED

`CitySim._population_inputs` has never called `PopulationSystem.ramp` with a
real age: every building is handed the literal `48.0`, above the 36-hour ramp
horizon, so `ramp()` returns **1.0 for every building in the city, forever**.
The instrument prints both; at the moment a house completes they are **0.386
(doc) and 1.000 (code)**. The literal is now `CitySim.
POPULATION_INPUT_AGE_HOURS` and carries the argument in its own docstring.

**This wave does not wire the real age**, and the reason is the report it is
answering: doing so would add 36 game-hours of near-invisible fill on top of the
176 seconds already measured, which is the complaint made worse. Doc 93 §AX2
asks the lead to rule, and recommends deleting the ramp — doc 09 §2.10's
aggregate has no per-arrival channel to show a fill through, and a `static func`
whose every call site passes a literal is not a rule the game has.

**The suite**: `tools/run_suite.sh` — **153 files, 2,796 tests, 582,354
asserts, failed 0, silent 0.** `python3 tools/check_doc_refs.py` prints *all
resolving; no id assigned twice* over 5,332 references. All four
`profile_sim --hash-only` baselines are **byte-identical to the fork**, on both
cities, and not one balance constant moves.

**The instrument is the deliverable as much as the fixes are.**
`tools/measure_population_lag.gd` boots a real `CitySim`, places a real
building, steps the real fine path one SimTick at a time and prints the journey
per game-minute — state, age, `state_occupancy`, what the ramp WOULD say, the
settled `occ_of`, `occupied_population`, `city_population` and the exact string
`HudModel` would paint. `data/time.json` sets one real second per game-minute,
so its `real_s` column is literal wall-clock seconds of play. Three previous
probes of this question timed out before reaching the answer; this one runs in
under a minute and prints it as a table.

## 69. WAVE 25 — opening land looks like work, and pays back what the crews dig up (binding)

*Lane 2 of Wave 25, forked off `6dba66c` (which carries Waves 19–22), 2026-09-04.
The lane exists for one instruction, and it is quoted whole because both halves of
it are load-bearing:*

> *"When we open up a new plot of land, we want construction animations for that
> land — to show that the land is being worked: digging it, materials. We will
> find materials from digging it out for the infrastructure. So potentially
> opening up a piece of land will give you resources and money back."*

*Prices: doc 03 §2.8b. Rulings: doc 93 §AZ. Measured: doc 92 §66. Surfaces: doc
12 §2.8 D-117 / D-118. Save rung: doc 08 §2.8 v10.*

**What was there before this lane.** Land development has been a six-phase
pipeline since doc 09 §2.3 shipped — SURVEY → CLEARING → GRADING → ROAD_INSTALL →
UTILITY_CORRIDOR → FINAL_DEVELOPMENT → READY, each with crew-hours, a primary crew
type and a doc 03 §2.8 phase cost — and **the render layer knew nothing about any
of it**: `grep -rn "CLEARING\|GRADING\|development_state" game/` was empty. A
block being dug out looked exactly like one nobody had touched, for fourteen to
fifteen phase charges of $1.2K–$21K each per 21 game-days. The player watched
their money buy a change of colour on a panel.

### RR-209 — `land_works`: a doc 03 income line for what comes out of the ground (§69.1)

**The line.** `land_works`, SOURCE `excavation`, credited at the COMPLETION of
CLEARING, GRADING and UTILITY_CORRIDOR through
`Treasury.credit_city_service(amount, "excavation", …)` — the same settled
`city_services` channel doc 06's dispatch payout and doc 06 §2.16's street
collection use, and for the same reason: it is money the player collected by
making a decision, not a rate on the city's value, and §2.5's income statement
has to be able to say which.

**Where every number lives.** `data/economy.json.development.works_yield`, behind
`EconomySystem.works_yield_*` accessors (C-07). The bands are fractions of THAT
PHASE'S OWN COST, which is the design decision the whole feature turns on: doc 03
§2.8's `terrain_phase_mult` already prices clearing a forest at 1.90× and grading
rock at 2.80×, so the terrain signal is free and correct and there is no second
8×3 table to keep in step with the first (doc 92 §66.1).

**The ceiling is 0.10 of the block's own six-phase bill**, clamped against a
PERSISTED cumulative per-block total, and it was chosen so that it BINDS — see
ruling 93 §AZ2 and doc 92 §66.3. A ceiling of 0.15 would have satisfied every
stated bound and could never have been reached by any roll on any terrain, which
is this project's signature defect (A91-D-19's shape) written into a balance
constant. 0.10 sits strictly above the maximum draw with no bonus (0.0845) and
strictly below the maximum with it (0.1223).

**Measured** (doc 92 §66.4): every block in a 27-find, three-city run recovered
**5.49 %–7.27 %** of its own development bill, and the line paid **$207.49 a
game-day** — **2.7 %** of the founding city's $319/gh net. "Money back", which is
what was asked for, and not profit.

**The materials yard** (ruling 93 §AZ3) is `CitySim.works_stockpile`, ONE integer
for the whole city. `STOCKPILE_SHARE` 0.34 is a hash and not a taste —
`LandBlock.road_tiles_est()` puts 0.34 of a block's usable ground under road, so
0.34 of what comes out of the ground is what goes back into it. It pays towards
`road_install` and `utility_corridor` only, at most a quarter of the invoice, and
because the cap is a quarter the net can never reach zero: **the yard shortens a
bill and never replaces one.** Measured, it empties itself on the very next phase
of the same block, which is the player's own sentence happening.

**Files.** `sim/economy/economy_system.gd` (§2.8b accessors,
`development_terrains()`), `sim/economy/treasury.gd` (the `excavation` source key
and its lifetime arm), `sim/core/rng_streams.gd` (the tenth named stream),
`sim/world/land_block.gd` (`works_yield_total`), `sim/city_sim.gd`
(`works_stockpile`, `_credit_land_works`, the yard's draw inside
`_charge_development_phases`, save rung v10), `data/economy.json`,
`tests/test_land_works.gd`, `tools/measure_land_works.gd`, `tools/ab_land_works.gd`.

### RR-210 — the receipts: a toast, a coin, a log row and a panel line (§69.2)

**Every find is a receipt, and the receipt names the block, the material and the
dollars.** `land_works_find` reaches the bus and is consumed FOUR ways, all in
this same commit — the rule being that an event this lane emits names its
consumer on the way in:

| consumer | what it does |
|---|---|
| `ui/land_works_model.gd` → `UIRoot.report_land_works()` | the toast and the treasury-chip flash, spent through `_spend_feedback` exactly as `StreetModel`'s bounty is |
| `data/ui.json.event_log.events` | one `economy` row per find, keyed on `block_id` so it carries `Jump to it` |
| `data/audio.json` | the `cash` cue, on the same shared identity a bounty rings, guarded on the CASH half so a find that went entirely to the yard rings nothing |
| `ui/land_panel_model.gd` | `Recovered so far`, off the block's own persisted total |

**Two sentences, not one.** A CLEARING find is all cash and reads
`Timber — $540`. A GRADING or UTILITY_CORRIDOR find keeps 0.34 as material and
reads `Fill and aggregate — $297, $153 to the yard` — because a player told $450
who sees $297 land in the treasury has been lied to by rounding. The branch is on
`stockpiled`, the payload's own number, never on the phase, so a full yard falls
back to the first sentence honestly.

**No haptic, deliberately** — `StreetModel`'s bounty rule, for its reason: §2.14's
cues answer something the player DID, and nobody pressed anything here.

**The yard gets no toast and that is a ruling** (§AZ3): five toasts per block is
the shape that teaches a player to swipe them away. It gets the two surfaces a
smaller invoice owes instead — `land_works_stockpile_spent` in the event log, and
`Yard materials −$1,160` under the pending phase in the land panel — plus a
`stockpile_offset` field on `development_phase_charged` (removed at the merge — see the merge note under RR-211; the yard draw is its own `land_works_stockpile_spent` row) so the log row's `cost`
and the treasury's movement are the same number.

**The land panel now answers the question before the purchase.** §2.8's
`Est. development` line has always said what a block will COST; `Typically
returns $1,310 – $2,940` is the other half of the same sentence, derived from the
same table by `EconomySystem.works_yield_band` so a retune moves the quote the
same hour it moves the money. It shows on land nobody owns; `Recovered so far`
appears only once the block is the player's, because `$0` on somebody else's land
is an answer to a question the panel is not asking.

**Files.** `ui/land_works_model.gd` (new), `ui/ui_root.gd`,
`ui/land_panel_model.gd`, `ui/land_panel.gd`, `game/ui/ui_root.tscn`,
`data/ui.json`, `data/audio.json`, `data/strings.en.json`.

### RR-211 — `LandWorksView`: the render layer learns that land development exists (§69.3a)

**`grep -rn "CLEARING\|GRADING\|development_state" game/` came back EMPTY at the
fork.** Doc 09 §2.3's six-phase pipeline has run since Wave 4 and no pixel in the
game has ever known about it: a block being dug out was rendered exactly like a
block nobody had touched, while the treasury was charged fourteen or fifteen
times per 21 game-days for work the player could not see happening.

`game/render/land_works_view.gd` draws it — pegs and tape at SURVEY, scrub that
goes clump by clump through CLEARING, a graded plane and spoil heaps at GRADING,
base laid progressively along **doc 10's own block template** at ROAD_INSTALL, an
open trench toward the block centre at UTILITY_CORRIDOR, kerbs at
FINAL_DEVELOPMENT, and nothing at all at READY. The per-phase draw-call and
instance table is doc 11 §2.18's and is taken by the suite rather than by hand
(`tests/test_land_works_view.gd`), so it cannot rot: **zero calls on a city with
nothing in flight, four at the busiest phase, six as the ceiling however many
blocks are being developed**, and 7 nodes, constant.

**The heavy plant is doc 11 §2.16's, given a profile.** `ConstructionActivity`
grows one optional per-site override — how many excavators are working and which
way the lorries run — because *two machines AND lorries leaving loaded* is a
combination no BUILDING stage has, and doc 09 §2.3 names a crew per phase.
`heavy_equipment_crew` phases get two excavators hauling out, `road_crew` gets one
machine and deliveries in, and the two `construction_crew` phases register no
plant at all. A building site sets neither field and is byte-identical to what it
was, which `test_a_building_site_is_untouched_by_the_profile` holds.

**Two defects were found by photographing it, and both are recorded because
neither was visible in a headless count.** (a) The instance tints were authored
as sRGB hexes and written raw into a MultiMesh, which the renderer reads as
LINEAR — a dark olive scrub rendered as pale sand. Decoded once at the read now,
which is doc 91 A91-D-36's rule. (b) `Basis.scaled` applies its factors on the
WORLD axes after a rotation, so a base run laid along Z came out `width` long and
`length` wide: four clean block edges photographed as a zigzag. Every rotated
instance uses `scaled_local`.

#### The shell wiring — `game/main.gd`, six snippets

*The lead owns this file; these are the patches, each against a named anchor.*

**1. The member, beside `construction_plant` (anchor: `var construction_plant: ConstructionVehicleView   # doc 11 §2.16: plant + deliveries`, line ~42):**

```gdscript
var land_works: LandWorksView                     # doc 11 §2.18: land under development
```

**2. Bring-up, immediately after the `construction_plant.site_frontage_changed`
connect (anchor: the closing `construction_view.set_gate_side(id, side))`, line
~474), and BEFORE the `street_life` block:**

```gdscript
	# doc 11 §2.18 — LAND UNDER DEVELOPMENT. The first render layer that has ever
	# known doc 09 §2.3's pipeline exists. It dresses the block itself and hands
	# the heavy plant to `construction_plant` above with a per-phase profile, so
	# the crew type the phase names is the machine that turns up. `set_gate_side`
	# above is a no-op on an id it does not hold, so a land site riding the same
	# `site_frontage_changed` wire needs no guard.
	land_works = LandWorksView.new()
	land_works.name = "LandWorks"
	add_child(land_works)
	land_works.setup(render_data)
	land_works.set_preset(render_model.preset, render_data)
	land_works.bind(sim_host.sim.world, sim_host.sim.development,
			sim_host.sim.construction)
	land_works.set_plant(construction_plant)
	# A city resumed mid-pipeline has no events left to tell this layer about it.
	land_works.adopt()
```

**3. The tick batch, in `_on_sim_batch`, beside the other three `feed_events`
calls (anchor: `street_life.feed_events(batch)  # doc 11 §2.17's opportunity_* trio`, line ~444):**

```gdscript
	if land_works != null:
		land_works.feed_events(batch)   # doc 11 §2.18's phase transitions
```

**4. The frame, in `_process`, after the `construction_plant.refresh` block
(anchor: the `float(sim_host.sim.clock.game_seconds()) / 60.0)` line, ~2526):**

```gdscript
	# doc 11 §2.18. No sim clock: this layer animates nothing — it re-reads its
	# own active set at 4 Hz and re-uploads only when something moved.
	if land_works != null:
		land_works.set_focus(camera_state.focus)
		land_works.refresh(delta, environment_controller.last_night)
```

**5. The preset swap, both call sites (anchors: the
`construction_plant.set_preset(str(model.value("graphics")), …)` at ~1490 and the
`construction_plant.set_preset(String(knobs["preset"]), _render_data)` at ~2575):**

```gdscript
			if land_works != null:
				land_works.set_preset(str(model.value("graphics")), _render_data)
```
```gdscript
				if land_works != null:
					land_works.set_preset(String(knobs["preset"]), _render_data)
```

**6. The load, beside `construction_plant.clear()` (anchor: `construction_plant.set_road_network(sim.roads)`, line ~1908):**

```gdscript
	if land_works != null:
		land_works.clear()
		land_works.bind(sim.world, sim.development, sim.construction)
		land_works.adopt()
```

**Merge note (2026-09-05).** The verifier found five additions in this lane's own
files with no reader but a test — A91-D-19's shape, in the wave whose brief named
it. Removed at the merge rather than wired, because each already had a live
twin: `LandWorksModel.EVENT_YARD` and `phase_text()` (the panel's yard line is
`LandPanelModel.stockpile_offset_text`, drawn by `ui/land_panel.gd`); the phase
row's `cost_net` (the panel shows gross and the yard's offset beside it); the
`stockpile_offset` key on `development_phase_charged` (the yard draw is its own
`land_works_stockpile_spent` row); and `tools/measure_land_works.gd`'s literal
terrain list, which now asks `EconomySystem.development_terrains()` — the drift
that accessor was written to prevent. The six snippets above are applied in
`game/main.gd` in the same merge, so `LandWorksView` is constructed by the shell
and the event matrix's three `development_*` consumers are live, not lexical.
Post-merge on main (Waves 23 + 24 lane 2 + this lane) the suite is re-taken in
the merge commit and §69.3's bench-coarse row composes with Wave 23's
`f50bc16f…` (the A/B tool's stripped body equals main, not the fork).

### RR-212 — the preview states, and what this lane files to whoever holds the gates (§69.4)

**Seven preview states in the same commit as the layer** — A91-D-28's lesson,
applied on the way in rather than a wave late.

* `tools/land_works_preview.gd --out=DIR [--census]` — one PNG per phase from the
  block's own frontage, plus the draw-call table. `tools/construction_preview.gd`'s
  sibling for a land block, for its reason: the suite holds the counts, and only a
  picture holds whether a graded plane with three spoil heaps on it reads as
  ground being worked.
* `tools/ui_preview.gd --screen=land_yield` — doc 12 §2.26 D-117's panel with
  doc 03 §2.8b's three rows on it. **It has to be the SECOND block**, and that is
  a measurement rather than a fixture choice: the yard empties itself on the very
  next phase of the block that filled it (doc 92 §66.5), so the only moment all
  three rows are on screen together is a fresh pipeline standing beside a yard the
  previous block's utility corridor filled. `--audit --strict` exit 0, and the
  whole 68-state deck sweeps clean at 412 × 915.

The two `awaiting_consumer` rows this lane files — to Wave 23 for gate 29 and to
Wave 24 for the curriculum gates — are §69.4's table above, with the per-day
dollar magnitude each holder needs to decide whether their gate re-records or
re-fits.

### 69.3 The four `profile_sim --hash-only` baselines, and the A/B that isolates them

| `profile_sim --hash-only` | at the fork (`6dba66c`) | after this pass |
|---|---|---|
| starter, coarse 24 h | `34ba7d972f3a78e2…` | `28627a982cde9d61…` |
| starter, fine 2.0 h | `dde437bc234fc2c2…` | `6c8df958370c9beb…` |
| bench, coarse 24 h | `db934239d6d84c04…` | `fd86903b0bf1ced3…` |
| bench, fine 2.0 h | `bf57bbac708c35b7…` | `736a4f453561d6fa…` |

**All four move, on SHAPE and not on behaviour, and the isolation is an identity
rather than an argument.** `tools/ab_land_works.gd` reproduces `profile_sim`'s
exact two advances on both cities and then digests the canonical body with this
lane's four key groups stripped, one at a time:

```
~/.local/bin/godot --headless --path . -s res://tools/ab_land_works.gd -- \
    --fork=34ba7d97…,dde437bc…,db934239…,bf57bbac…
```

| stripped | starter coarse | starter fine | bench coarse | bench fine |
|---|---|---|---|---|
| (full body) | `28627a98…` | `6c8df958…` | `fd86903b…` | `736a4f45…` |
| less `rng.land_works` | `7192389d…` | `c40d6c46…` | `3a2dc79b…` | `6d9d7ee0…` |
| less `treasury.{ledger_totals.lifetime_excavation, hour_city_services.excavation}` | `fbf8568d…` | `6af86478…` | `e1d1e3fe…` | `7f2fd6ef…` |
| less `works_stockpile` | `6546706d…` | `83e3bb89…` | `a11b7f09…` | `8dfe8aeb…` |
| less `world_blocks[].works_yield_total` | **`34ba7d97…`** | **`dde437bc…`** | **`db934239…`** | **`bf57bbac…`** |

**The last row IS the fork, on all four, to the byte.** So the delta is exactly
those four key groups and nothing else: not a float, not a stream position, not a
dollar of any city that never develops a block. The tool exits non-zero if that
stops being true, so this is a standing property and not a one-time table.

**Nothing a scripted agent EARNS moved.** The yield is credited on a development
phase COMPLETING, and neither `profile_sim` city — nor any balance-gate agent —
develops a block during its run. Gates 18b, 20, 21 and 29 are therefore a
**re-record, not a re-fit**.

### 69.4 Awaiting the gate holders

**Two sibling waves hold the gates this lane cannot re-run.** This lane holds
none, so both rows below are `awaiting_consumer` in the strict sense: the numbers
are published, the cause is isolated, and the re-record belongs to whoever owns
the gate.

| # | to | what is owed | the number they need |
|---|---|---|---|
| **AZ-1** | **Wave 23 (gate 29, insolvency)** | Re-record gate 29's baselines against `28627a98…` / `6c8df958…` / `fd86903b…` / `736a4f45…`. **A re-record, not a re-fit**: §69.3's A/B shows the stripped bodies are byte-identical to the fork, and gate 29's `do_nothing` agent buys no land, so its insolvency day cannot move. | If a re-fit is ever wanted anyway: `land_works` pays **$8.65 per game-hour** ($207.49/game-day, doc 92 §66.4) and **only while a development pipeline is running**. A city that has stopped buying land earns exactly $0 from it. |
| **AZ-2** | **Wave 24 (the curriculum, gates 21 / 20 / 18b)** | Same re-record against the same four digests. The curriculum agent DOES develop blocks, so this is the row where a re-fit could genuinely be indicated — the check is whether an agent that buys land now reaches a rung earlier. | **$207.49/game-day while developing**, **2.7 % of the founding city's $319/gh net**, three finds per block, and a per-block ceiling of **10 %** of that block's own development bill (so a curriculum block can never fund itself). Doc 92 §66.4 has the per-block spread: 5.49 %–7.27 %. |

### 69.5 The suite, the sweeps and the final readings

| | |
|---|---|
| `tools/run_suite.sh` | **155 files, 2,821 tests, 583,925 asserts, failed 0, silent 0** |
| `python3 tools/check_doc_refs.py` | *all resolving; no id assigned twice* over 5,364 references |
| `grep -rn "^<<<<<<<" .` | nothing |
| `ui_preview --screen=all --size=412x915 --audit --strict` | **exit 0** |
| `ui_preview --screen=all --size=360x800 --text-scale=1.3 --large-targets --audit --strict` | **exit 0**, the accessibility sweep |
| `ui_preview --screen=land_yield --audit --strict` | **exit 0** |
| `tools/land_works_preview.gd --census` | **2 / 2 / 2 / 3 / 4 / 3** draw calls across the six phases (doc 11 §2.18) |
| `tools/ab_land_works.gd --fork=…` | **4 of 4 MATCH** — the stripped bodies are byte-identical to the fork |

**Three authored verbs with no door, found by this lane and recorded rather than
swept.** `DevelopmentController.cancel_development`, `pause_development` and
`resume_development` have **no callers anywhere in the project** —
`grep -rn "cancel_development\|pause_development\|resume_development" sim/ ui/ game/`
returns the controller itself and nothing else. Three verbs with refund rules, a
mid-phase guard and a `development_paused` event, that no command and no screen
can reach: doc 09 §2.3 authored them, doc 12 §2.8's panel never grew the button,
and this is A91-D-19's shape again. They are doc 09's and not this lane's, so the
honest thing was to make the renderer survive them — §69.3a's poll drops a block
the pipeline let go of without an event, which is exactly what a cancel does —
and to file the rest here.

**And a milder one this lane's own key rides.** `city_services_by_source` has
been published by `EconomySystem.settle_hour` since Wave 15 and
`tests/test_city_services.gd` is its only reader, so `excavation` joins a
per-source breakdown that reaches no screen. The money itself is on five
surfaces — the balance, the toast, the event log, the `city_services` ledger row
and `ledger_totals.lifetime_excavation` — and only the SPLIT is invisible. A
per-source band on the Economy tab is the one-line fix whenever a lane owns
`ui/budget_model.gd`.

**One debt is offered and not taken.** §AC-3 has stood since Wave 19: the three
`_note_lifetime` arms doc 91 A91-D-37 / A91-D-100 / A91-D-108 owe (`&"incident"`,
`&"restore"`, `&"salvage"`) are "one edit and ONE baseline re-record", and three
lanes have each correctly declined to pay three re-records for one change. **This
lane is re-recording all four baselines anyway**, so it is the cheapest moment
that has ever existed to land them — and it still does not, because they are
three other lanes' ledger rows and folding them in would put a change with no
brief inside a merge two sibling waves are re-fitting against. The offer is filed
here so the next lane that moves a baseline can take it in one line.
## 68. WAVE 25 — the transformer is a thing you tap (binding)

*(Measured in doc 92 §65. Rulings in doc 93 §AY. Defect rows doc 91 A91-D-129,
A91-D-130, A91-D-131. Delta rows doc 12 D-114, D-115, D-116.)*

The player, 2026-09-04: *"In every building we have the transformer power
information. We should have that on the transformer itself. So if you click on
the transformer, you can repair it — which means calling your crews there. If it
fails, you can fix it from there, call your crews; and all of the buildings that
connect to that transformer and the power-feed situation, and the ability to
upgrade the transformer — all should be there on the transformer. You click the
transformer and all of that information pops up just like a building does. So we
don't clutter the building information. The buildings just need a few things:
repair, upgrading, and things we already have. Right now there's too many things
there."*

Three separate things were true of the fork, and only the third is a matter of
taste:

1. **A transformer was not selectable.** `BuildController.pick_at_ground`
   answered `opportunity → building → block` and nothing else, and
   `game/main.gd` routed those three. There was no id a tap could produce for a
   grid component, so there was no panel it could open, so every verb doc 04 §4
   owns had to be reached through a BUILDING the transformer happened to feed.
2. **A failed transformer had exactly one door and the player did not hold the
   key to it.** `PowerGrid.repair_component` was called from one place in the
   whole project — `CityIncidentWorld.power_restore_component`, inside doc 06's
   incident resolution. There was no command. A player looking at a dead pad
   could upgrade it (refused: `E_STATE`), demolish it, or wait.
3. **The building panel had grown a whole subsystem inside it.** Wave 17 put the
   hop list, the per-hop UPGRADE buttons, the armed REMOVE row and the fix strip
   into `ui/building_panel.gd`, because the building was the only door there was.

### RR-205 — `buildings_served_by`: the grid could not name its own customers (docs 04 §2.15.1, 12 D-114, 92 §65.1)

`PowerGrid` publishes `attachment_of(building_id)` (one building → its
transformer) and `attachment_map()` (the whole table). It published **no way to
ask a transformer who is behind it**. `_children_of` is private and walks
COMPONENTS, not buildings.

The consequence was three open-coded copies of one loop, all sweeping the
attachment map by hand: `CitySim.cmd_demolish_grid_component` (then re-sorting
what it built), `CityIncidentWorld.power_customers_downstream` (a
per-building `attachment_of()` over the whole roster — **1,500 dictionary
lookups on the benchmark city** for a count the grid already holds), and
`PowerGrid._customer_index` (a count, kept). `buildings_served_by(id)` is the
public read, sorted for the same determinism reason `attachment_map()` is; the
first two callers are now one line each.

**`PowerGrid.damage_fraction(id)` lands with it**, and it closes an
A91-D-19-shaped hole in doc 04's own middle.
`_fail(id, cause, damage_fraction)` published a per-kind damage on every
`PowerComponentFailed` — 0.35 transformer, 0.05 feeder, 0.30 substation, 0.05
line — **written three times** (twice as literals in `_pass_c_thermal`, a third
time as a ternary inside `_resolve_lightning_with`) and **read by nothing**:
`_fail` does not touch `condition`, `repair_component` lifted to a flat 0.85, and
no consumer in `sim/`, `ui/`, `game/` or `data/` ever named the key. It is now
`PowerGrid.FAILURE_DAMAGE`, one table, and RR-206's price is read off it. Values
unchanged: all four `profile_sim` baselines are byte-identical (doc 92 §65.5).

### RR-206 — `cmd_repair_grid_component`: the verb the player asked for by name (docs 03 §2.5, 04 §2.15.2, 06 §2.6, 92 §65.2, 93 §AY1)

A doc-03-priced repair that **dispatches a crew** rather than healing on the tap.
Nothing about it is authored in `sim/`:

| term | value | whose number |
|---|---|---|
| capital | `CostCurves.capital_value_grid(kind, level)` | doc 03 §2.5's grid bullet, shipped C-16, spender-less until now |
| `damage_fraction` | `(1 − condition) + FAILURE_DAMAGE[kind]` when FAILED | doc 04 §2.6 (RR-205's hoisted table) |
| price | `capital × damage × REPAIR_COST_PER_CAPITAL (0.85) × M_repair` | doc 03 §2.5, the one repair formula in the project |
| crew-hours | `w_base(power_event_map[kind]) × damage_fraction` | doc 06's `transformer_failure.w_base` = **0.90 game-hours** |
| crew type | `heavy_equipment_crew` | doc 09 §2.3's `UTILITY_CORRIDOR` crew — the phase that lays this equipment |
| repair target | 0.85 from FAILED, 1.00 from standing | doc 02 §2.12's two targets, applied to a component |

**No new ledger line and no new row in `data/economy.json`.** The charge books
under the existing `&"repair"` category, so the Economy ledger's `Repairs` line
carries it with no schema change. The job is an ordinary `ConstructionQueue`
`repair` with a `grid_component` payload key, so it is listed by S16, rushable by
`cmd_rush_construction`, and completed by the one completion door
(`_route_completed_jobs`) — routed to `_complete_grid_repair` **ahead of**
`on_construction_completed`, whose first act is a `buildings` lookup that a
component id can never satisfy.

Refusal ladder, in order: `E_UNKNOWN_COMPONENT`, `E_NOT_DAMAGED`,
`E_ALREADY_REPAIRING`, `E_FUNDS` / the treasury's own spend refusals.

**Both events have named readers**, which is the test this project applies to
anything it emits: `data/ui.json.event_log` logs both under the `power` filter,
and `data/notifications.json` binds the ARRIVAL to a `P3_routine` banner. The
DISPATCH is deliberately not bound — a player who has just pressed CALL A CREW is
looking at the panel that already shows the crew and the ETA.

**Two things it deliberately refuses, and both are written down rather than
approximated.** A component that is only OPEN is not damaged — a tripped relay
is a position, and doc 04's auto-reclose or doc 06's dispatch closes it for
nothing. And a FEEDER is out of scope: doc 03 §2.5 prices a grid component's
repair capital as its §2.13(b) build cost, a feeder's §2.13(b) price is **per
tile of its run**, so `capital_value_grid("feeder", 1)` answers **0** and a
feeder repair admitted here would have been free. Filed as A91-D-131 rather than
shipped.

**`E_NOT_DAMAGED` has a third arm that is not obvious and is the whole reason
the verb is not a trap.** `repair_component` never LOWERS a condition, so a
repair of a standing component already at its target would take doc 03's money
and move nothing. The gate therefore refuses when the quoted price rounds to
$0 as well as when the damage is zero — the threshold is doc 03's own rounding,
not a number this wave authored.

### RR-207 — `PICK_COMPONENT`, S18, and the router that finally has somewhere to send a `POWER_CAPACITY` row (docs 12 §2.25, 04 §2.15.1, 92 §65.3, 93 §AY2)

`pick_at_ground` gains a fourth answer between OPPORTUNITY and BUILDING, on the
same 48 dp radius `set_tap_radius_from` already computes, measured against the
pad's own tile centre. **The order is the point**: a padmount cabinet is 2.4 m
across standing in front of a house that occupies a whole 8 m tile, so a pick
decided by tile ownership hands every tap to the house — the same asymmetry doc
12 §2.21 argued for the street collectable, one object over. The house has not
moved and is one tap away.

`ui/transformer_panel_model.gd` is the headless model (every number, every string
KEY, every refusal) and `ui/transformer_panel.gd` is the code-built view that
computes nothing — the same split `LandPanelModel` / `LandPanel` uses, and the
reason the whole surface is under `tests/test_ui_transformer.gd` rather than
under a screenshot.

**And one seam that would otherwise have made the whole screen inert.**
`UIRoot.bring_up_screens()` builds every panel against one shared `UIConfig` and
NO sim; the shell builds the `BuildController` afterwards and hands it to S5 and
the build sheet, and has no reason to hand anything to a screen that did not
exist last wave. `UIRoot._transformer_model()` therefore resolves S18's model
from the controller a sibling is already holding — the same argument
`bind_water_actions`' resolver makes for the incident drawer, and for the same
reason. Without it `show_transformer` would return `false` for ever in the
shipped game and the failure would look exactly like *a tap that does nothing*,
which is the defect this wave was opened on.
`test_s18_opens_in_a_shell_that_never_hands_it_a_model` drives the shipped boot
order and nothing else.

**And the same trap one layer up.** `FixRouter` now answers
`SHEET_TRANSFORMER_PANEL` for a `POWER_CAPACITY` row and for a grid component's
own row — but every surface that raises one re-emits to the shell, whose handler
knows exactly one action (`ACTION_FOCUS`, a camera move). A correct new answer
consumed by nothing is the shape this wave is named after, so
`UIRoot._serve_transformer_fix` serves it: both panels are on the root's own
`PanelLayer`, the route is one line, and everything the root cannot serve passes
through to the shell untouched. `test_a_fix_row_raised_by_a_surface_with_no_in_place_path_opens_s18_here`
drives it through S4's own signal and asserts the pass-through as well as the
catch.

`SHEET_BUILDING_PANEL` is **deleted, not deprecated**. It had one producer, the
`FIX_POWER` arm this wave moved, and no consumer anywhere in `ui/`, `game/` or
`tests/` — the shell has only ever branched on `action`, never on `sheet`. A
sheet name a router can no longer answer is a door in a wall nobody can enter,
which is the exact defect class the paragraph above is about, so it goes with
the branch that produced it. The in-place path its docstring described is
untouched and still correct: `building_panel.gd::_on_fix_pressed` catches
`FIX_POWER` before the router is consulted (A91-D-54) and now raises
`power_row_opened` instead of arming the strip.

### RR-208 — the building panel diet (docs 12 §2.9 D-115/D-116, 92 §65.4, 93 §AY3)

Wave 17's POWER section — header, draw line, shed line, N hop rows each with a
title, a reading, an UPGRADE button, a checklist and an armed REMOVE row, then
the next-level line and the fix strip — becomes **one row**:
`Power · fed by T-03 · 78 % · ›`, or `Power · NOT SERVED · ›`, which opens S18.
Measured in doc 92 §65.4.

**The water block does NOT take the same treatment, and the asymmetry is the
ruling** (doc 12 D-116, doc 93 §AY3, doc 92 §65.4). It is the same shape read the
other way: a transformer HAS a surface to be handed to, so collapsing its section
MOVES a verb; a doc-05 node has none, so collapsing its section would DELETE one —
A91-D-19 run backwards. `_render_water` and `_build_water_row` are untouched by
this wave and `WTR-1` is exactly the length it was. (An earlier draft of this
section said the opposite; the code, the measurement and doc 12 all say this.)

**The three blocks that were examined and KEPT are as much of the ruling as the
two that moved** (doc 93 §AY3): the priority row is a decision only this panel
can make about this building; the coverage checklist is the requirement contract
doc 12 §2.7 calls the game's most important teaching device; the progress block
is the answer to *"is anything happening here?"*, which a player asks of the
building and not of a queue.

**One thing this wave broke and put back: the sRGB census.** `set_selected`'s
ring (`game/render/power_infra_view.gd`) shipped a vertex colour array of 24
`Color.WHITE` entries under `vertex_color_use_as_albedo`. It rendered correctly —
white is 1.0 in both spaces, so the multiply was a no-op and the ring's authored
gold rode `albedo_color`, which the engine decodes for free (A91-D-36, RR-91,
RR-95) — but it put the file into
`test_render_polish.gd::test_every_procedural_mesh_decodes_its_authored_vertex_colour`'s
census of renderers that hand a shader authored colour raw, and that guard is a
source-text census which cannot tell a white multiplier from a hue. **The array
is deleted rather than decoded**: there was no authored colour in it, and a
`srgb_to_linear` added to satisfy a census is the census measuring nothing. The
ring is byte-identical on screen; the census is back to guarding five files, all
of which genuinely carry hue on a vertex. Found by the full suite, not by the
checkpoints — it is the one test in the tree that reads `game/render/*.gd` as
TEXT, so nothing in the transformer suite could have caught it.

### 68.1 `game/main.gd` — the five snippets, with anchors

This lane may not edit the shell (the lead owns `game/main.gd`). Everything else
in Wave 25 is complete and green without these; what they add is the WORLD half —
the tap routing, the pad highlight, and the HUD refresh after S18's verbs. All
five are additive except snippet 3, which is a two-line DELETION and a tidy-up
rather than a fix: `BuildingPanel.grid_upgraded` / `grid_demolished` are still
declared and still RAISED — by `UIRoot`, on the panel's behalf — precisely so an
unpatched shell keeps working. **Nothing below is needed for the tree to boot or
for the suite to pass.**

**1. Route `PICK_COMPONENT`.** In `_handle_tap`, immediately after the
`PICK_OPPORTUNITY` arm's `return` and BEFORE the `PICK_BUILDING` arm:

```gdscript
	if StringName(str(pick["kind"])) == BuildController.PICK_COMPONENT \
			and ui_root != null and ui_root.show_transformer(str(pick["id"])):
		# S18 closes its siblings itself (`UIWidgets.close_siblings`), so the
		# building panel and S4 stand down without being told twice.
		ui_root.selected_entity_id = str(pick["id"])
		if power_infra != null:
			power_infra.set_selected(str(pick["id"]))
		return
```

**2. Follow the selection into the world.** In `_wire_build_ui()`, in the
`if building_panel != null:` block, beside the other panel connections
(`ui_root` is in scope there as the member):

```gdscript
	if ui_root != null:
		ui_root.transformer_selected.connect(func(component_id: String) -> void:
			if power_infra != null:
				power_infra.set_selected(component_id)
			ui_root.selected_entity_id = component_id)
		ui_root.transformer_customer_selected.connect(
			func(sim_id: String, world_pos: Vector3) -> void:
				camera_state.focus_on(world_pos)
				if building_panel != null:
					building_panel.show_building(sim_id)
				ui_root.selected_entity_id = sim_id)
		ui_root.grid_action.connect(
			func(_action: StringName, _component_id: String, _result: Dictionary) -> void:
				_refresh_hud()
				if power_infra != null:
					power_infra.note_topology_changed())
```

**3. Retire S5's two grid signals.** In the `if building_panel != null:` block,
**delete** these two connections — S18 raises `upgraded` / `demolished` and
snippet 2's `grid_action` arm does the same work:

```gdscript
		building_panel.grid_upgraded.connect(
				func(_component_id: String, _result: Dictionary) -> void: _refresh_hud())
		building_panel.grid_demolished.connect(
				func(_component_id: String, _result: Dictionary) -> void: _refresh_hud())
```

`building_panel.power_fixed` stays: `cmd_fix_power_capacity`'s strip is still on
S5 (doc 12 D-116).

**4. Keep the panel live.** In the 1 Hz HUD block, on the line after
`ui_root.refresh_land_panel()`:

```gdscript
		ui_root.refresh_transformer_panel()
```

**5. A loaded save is a different grid.** Beside the existing
`power_infra.note_topology_changed()` in the post-load path:

```gdscript
	if power_infra != null:
		power_infra.set_selected("")   # the ring cannot outlive the city under it
	if ui_root != null:
		ui_root.close_transformer_panel()
```

## 70. WAVE 26 — the utility planner: the door nobody could open, and the term that binds (binding)

*Forked off `2cf4907` (main after Waves 23, 24 and 25, whose merge record is doc
92 §66.7). The lane exists for one red test: `tools/run_suite.sh` on main was
2,880 tests with ONE failure —*
`test_balance_gates.gd::test_gate_21_the_curriculum_is_completable_and_paced`,
*"0 of 3 seeds reached curriculum level 7 inside 45 game-days; the ruled floor is
1". Every merged lane passed that gate alone; the COMPOSITION failed it. Doc 92
§62.9's merge addendum predicted exactly this and ruled: "A91-D-123's
water-headroom planner is the fix; another re-fit is not."*

*Rulings doc 93 §BA. Measured doc 92 §67. Defect rows doc 91 A91-D-137..A91-D-139
(and A91-D-123's closing row). Surfaces doc 12 §2.7 D-120.*

**What was there before this lane.** The agent could see the wall and had no
hands. `Curriculum._relieve` answered a power refusal by looking for a site for a
parallel transformer inside a 7×7 ring and, failing that, by calling
`Api.upgrade_grid_component` — a door that had been returning `E_NO_VERB` on its
first line since the day it shipped, without logging, because
`cmd_upgrade_grid_component` was never added to `KNOWN_VERBS`. It answered a
water refusal by buying a pump in a zone whose intake and treatment train were
the binding terms, so the pump added nothing. And it had no rule at all for
buying supply BEFORE a refusal. Meanwhile `cmd_place_building("water_facility")`
would sell the player a water works that hosted no doc-05 node and supplied
nothing at all.

### RR-213 — the relief reads the refusal, and every door logs (§67.1, §67.2)

**The root cause, and it is one line of data.** `Playtest.KNOWN_VERBS` is the
only source of `Api.verbs`; `has_verb` answers false for anything absent from it.
`cmd_upgrade_grid_component` was absent. Measured at the fork with
`tools/probe_utility_wall.gd` on seed 1337 at game-day 25:

    KNOWN_VERBS has cmd_upgrade_grid_component  false ; api.has_verb -> false ; sim has method -> true
    blocked_upgrade(high_rise) = {sim_id P-071, blocker E_POWER_HEADROOM, cost 29900, power_at PT-053}
    _relieve -> false ; log grew by 0 ; _relief_hour still 430  (at hour 599, cooldown 24)
    sim.cmd_upgrade_grid_component("PT-053", true) -> ok, $6,900, L3 -> L4, 400 -> 1000 kW

**Three changes, and the third is the one that keeps the first two honest.**

1. **The verb is registered**, and `Api.upgrade_grid_component` now logs *every*
   exit — the empty target, the missing verb and the refused preview — carrying
   the command's own reason code instead of overwriting it with `E_BLOCKED`.
2. **`_relieve` buys the component doc 04 NAMES.** `PowerGrid.can_upgrade_power`
   returns `at` and `kind` because doc 04 §5.3 says the answer to a transformer
   at 1.009 is a bigger transformer and the answer to a feeder at 0.93 is more
   copper (Wave 17, A91-D-55). `Curriculum._relieve_power` re-rates that
   component first — a transformer or a feeder through
   `cmd_upgrade_grid_component`, a substation through doc 02's building ladder,
   because report 98 C-30 makes a substation a BUILDING — and only falls back to
   a parallel transformer. `Api.blocked_upgrade` asks the headroom with the same
   `×UPGRADE_HEADROOM_MARGIN` the gate used, so the component it names is the one
   that actually refused.
3. **`test_every_command_the_harness_drives_is_on_the_verb_roster`** reads
   `tools/playtest.gd`'s own source for `sim.cmd_*` call sites and asserts each is
   on the roster. The existing verb-probe test walks the list and asks whether
   each entry is live, which can never see a call site the list has not heard of.

### RR-214 — the parallel-transformer search, widened to doc 09's land block (§67.2)

`Api.relief_spot_ring(centre, level, inner, outer)` scans the `inner` square in
**exactly** `relief_spot_near`'s row-major order first — so wherever an answer
existed before, the identical tile is returned and no arc that was already
finding a site can move — and then walks Chebyshev rings out to `outer`,
returning `{tile, previews}` so the cost of the widening is a measurement rather
than a guess. `Curriculum.RELIEF_RADIUS` is `Api.BLOCK_TILES` (16), doc 09's land
block: the unit the player buys, develops and pays tax on, so a tap inside it is
copper on ground the city already owns.

### RR-215 — the water door answers its own power refusal, and buys the term that binds (§67.3, §67.4)

**Doc 05 §2.5's supply term is a chain.** `upstream_cap = min(Σ source yield, Σ
treatment throughput)`; each pump's `share` is its rated slice of that cap; the
zone's supply is the sum of the shares, capped by `feed_capacity`. So a pump
upgrade raises a treatment-bound zone's supply by **exactly zero**. Measured at
the fork on the zone the level-7 high-rise stands in:

    source_yield 105.1 | treatment 78.1 | pump rated 80.0 | feed_cap 214.0
    upstream_cap 78.2 -> supply 77.8 against demand 127.3, pressure 0.21, headroom 0.0

`Api.upgrade_water_node(zone_key, budget)` now walks `supply_chain_order` — the
smallest term first, lowest rung inside a term, id as the tie-break, tanks never
— and when every node in the chain is refused `E_POWER_HEADROOM` it buys the grid
component doc 04 names behind the first of them and comes back for the node on
the next game-day through the existing one-purchase cooldown. At the fork all
four upgradeable nodes were refused for power at their OWN transformers (`T-15`
three times, `PT-095` once) with the bulk pool at 19 % load, and both of those
transformers previewed an OK $6,900 rung.

**And the site scan says how hard it looked.** `WATER_SITE_PREVIEWS` goes 96 →
4,096: the level-7 city this wave measured has **16 READY blocks**, i.e. at most
`16 × 14² = 3,136` candidate origins for a 3×3 pump, so the cap now sits above
the whole search on the city that exposed the problem rather than below its first
block. It is not a proof for a fully-developed 49-block map, which is why the
`E_NO_SITE` log row carries `previews`, `blocks` and `capped` — a city that
outgrows it says so on the line, instead of stopping silently the way 96 did.

### RR-216 — `_lead_water`: the purchase before the refusal (§67.5)

`Balanced._lead_water`, filed beside `_lead_generation` in `_grow` because it is
the same sentence one utility over, gated on KNOB 3 `plans_water` which only
`curriculum` sets (ruling 93 §BA4, deferral doc 91 A91-D-139). Trigger:
`Api.water_pinch_zone(WATER_RELIEF_RATIO)` — a zone at or past
`PowerGrid.OVERLAY_WARNING_R` (0.75) of `demand / supply`, or already under doc
05's own `upgrade_min_pressure` (0.55). Doc 05's overlay bands are on PRESSURE,
which reads 1.0 for every zone with supply at or above demand, so they are the
alarm and not the gauge; the only reading a zone publishes that moves before the
wall is its utilization, and 0.75 is the band this project already publishes for
*"a utility is going amber"*.

`tools/measure_utility_plan.gd` is the instrument: every water and grid purchase
on the arc with its game-hour, its verdict and its price, plus the doc-05 zone
table the run ended on (`BalanceGateRig.run` gains an additive `zones` block for
it).

### What this lane shipped, and what it did not

**Files.** `tools/playtest.gd` (the roster entry, the logged door,
`relief_spot_ring`, `supply_chain_order`, `binding_supply_kind`,
`water_power_binder`, `water_pinch_zone`, `zone_key_of`, `_relieve_power`,
`_lead_water` and KNOB 3 `plans_water`), `sim/city_sim.gd` (doc 93 §BA's
placement delegation, `_rerate_water_nodes`, `water_shell_top_level`,
`water_shell_node_delta_kw`), `ui/build_controller.gd` (§BA3's one-line route),
`tests/balance_gate_rig.gd` (additive `zones` and `blocked` blocks),
`tests/test_balance_gates.gd` (gate 21's new per-seed water assertion),
`tests/test_playtest_harness.gd`, `tests/test_infra_verbs.gd`,
`tests/test_power_operations.gd` (doc 92 §67.12), and the new
`tools/measure_utility_plan.gd`.

**The bound was NOT moved** — doc 92 §62.9's addendum asked for the planner
rather than another re-fit, and it got one. `reached_top >= 1` reads 2 of 3 with
margin instead of 0 of 3 in failure, and the cell gained an assertion about the
CITY rather than about which seed got lucky (doc 92 §67.7).

**What is deferred, and both are named rather than hidden.** `balanced` still has
no water planner (doc 93 §BA4), and a zero-water-delta upgrade is still refused
for a building in no pressure zone (doc 91 A91-D-139). And the wall this wave
uncovered — doc 05's MAINS, both as `feed_capacity` and as the tile factor under
`pressure_at` — is the next lane's, with `cmd_place_water_main` sitting probed,
listed and undriven (doc 92 §67.8).

## 72. WAVE 28 — every building fits the transformer envelope; the data centre did not (binding)

*Forked off `a581948` (main after Waves 23–26). Four baselines at the fork,
`tools/profile_sim.gd --hash-only`: starter `9004573d…` / `d5c6678d…`, bench
`9695f766…` / `b8548805…`.*

*The player, on the device, 2026-09-05:* **"A fully loaded data center still
pulls too much, and I haven't even upgraded it past level two. Transformers may
need more power, or we just make the data centers fit in that envelope, so a
transformer can handle it fully upgraded."**

*Ruling doc 93 §BC. Measured doc 92 §68. Defect rows doc 91 A91-D-143,
A91-D-144. Surface doc 12 D-123.*

**The player had measured the game correctly and the hole was ten cells wide.**
A building attaches to **exactly one** transformer — `PowerGrid._attachments` is
a `building_id → transformer id` map and doc 04 §2.1's attachment rule picks one
— so the largest load the distribution model can serve is one rung of doc 04
§2.2's ladder at §5.3's 0.90 ceiling. Doc 02 §2.14 authored a SIXTH rung of
demand against doc 04's five rungs of copper, and no document, test or tool ever
asked the two tables to agree. Measured at each archetype's own doc 01 channel
peak — the hour §5.3's gate is judged at (RR-120) — **nine of doc 02's 66
published `power_demand_kw` cells had no transformer at any price**
(`apartment` L6, `office` L6, `high_rise` L5–L6, `data_center` L3–L6,
`water_facility` L5) — and doc 05's `pump` L5, which is that same
`water_facility` L5 read through the variant table rather than a tenth cell. Doc
92 §68.1 publishes the table both ways round.

### RR-221 — doc 04 §2.2's transformer ladder gains its sixth and LAST rung (binding)

`PowerGrid.CAPACITY.transformer` `[50, 150, 400, 1,000, 2,500]` → `[…, 6,750]`;
`TRANSFORMER_SERVICE_RADIUS` `[3,4,5,6,8]` → `[…, 10]`;
`data/grid_components.json` `placeable_levels` `[1..5]` → `[1..6]` with the
radius column extended to match; `data/economy.json`
`expenses.grid_components.transformer.build_cost` gains **41,500**.

**The capacity is derived, not chosen.** `UPGRADE_MAX_R × FEEDER_CAPACITY[2] =
0.90 × 7,500 = 6,750` — the largest transformer the top conductor class can carry
at §5.3's own ceiling. **A seventh rung is arithmetically impossible without a
fourth conductor class**, so doc 04's ladder is now provably complete. The
radius extends its own last step (+2), the swap time its own last ratio (×1.45 →
80 gm), and the price the ladder's own $/kW decline (10.00 / 7.33 / 7.00 / 6.90 /
6.52 → 6.15; `6.15 × 6,750 = 41,512.50` → `$41,500` half-up on the column's $100
grid). §2.6's THERMAL and HAZARD rows are per-KIND, so the rung adds none.

**Hash-neutral on both cities, and that was a prediction rather than a hope**
(doc 92 §68.4 arm A): appending to `CAPACITY` moves no existing component's
`capacity_kw`, and neither authored city owns a rung-6 transformer. Verified:
starter `9004573d…` / `d5c6678d…`, bench `9695f766…` / `b8548805…`, all four
unchanged with the whole of this wave's code in the tree and only
`data/buildings.json` rolled back.

**Gate 18c is amended rather than broken.** Its assertion is *"no published
capacity moved"*, and that is still what it asserts: the five shipped rungs are
pinned cell by cell and the appended sixth is pinned against its own derivation
(`0.90 × FEEDER_CAPACITY[2]`), not against a literal. A gate that had refused the
append would have been pinning the wall gate 34 exists to remove.

### RR-222 — doc 02's power column is clamped at the copper, and the data centre's seed is re-derived (binding)

Two data edits, both through `tools/gen_buildings.py`, which is the only writer
of `data/buildings.json` and `data/building_rules.json`:

1. **The clamp.** `power_demand_kw(L) = min(round_rule(seed × k_dem^(L-1)),
   ceiling_peak_kw / channel_peak[class])`, the quotient **floored** onto the §8
   `kw` grid. It is the same `min(curve, ceiling)` shape
   `coverage_ladder.max_requirement` has had since doc 02 §2.9, and it is applied
   for the reason doc 93 §G5 rider 1 already gave for the coverage columns and
   did not give for this one. New `service_envelope` block in
   `building_rules.json` mirrors doc 04's ceiling (6,075 kW), doc 04 §2.3's class
   map and doc 01's five channel peaks; `BuildingCatalog` now requires the block
   and re-checks every shipped cell against it at LOAD.
2. **The seed.** `seed_rows.data_center.power_kw` **400 → 100**. The interval
   that makes the ladder climb exactly one rung per level against doc 04's six is
   **(55.4, 135]** kW; 100 is the round number in it and keeps the data centre
   the largest first-level draw in the roster.

**A regression this wave caused and caught, kept on the page because the shape
matters more than the escape.** `tools/gen_buildings.py` is the SOLE writer of
`data/building_rules.json` — it rewrites the whole file — and Waves 19 and 20
had written two rulings straight into that JSON without adding them to the
generator: `owner_maintenance.wear_may_demolish` (doc 93 §AP1) and the entire
`utility_spine` block (doc 93 §AR1). The first regeneration after them, which is
this one, **deleted both**. That is not a formatting loss:
`Building.wear_may_demolish` defaults to **true**, so the drop re-armed the exact
physics those two rulings exist to stop — ordinary wear demolishing private
stock, and ordinary wear demolishing the city's own generation, which is the
player's 2026-09-03 report. Neither hash moved (a 24-hour run never reaches
`structural_failure_threshold`), so the four baselines said nothing; it was found
by diffing the regenerated file against the fork key by key, and
`tests/test_spiral_floor.gd` would have caught it at the suite. **Fixed** by
moving both blocks into `BUILDING_RULES` verbatim (asserted identical to the
fork's, key for key) and by `verify_no_shipped_block_is_dropped()`, which now
refuses to write a file that loses a top-level block or a field of one:

```
$ python3 tools/gen_buildings.py --check      # with a block the generator does not know
gen_buildings: 2 failure(s), nothing written
  FAIL building_rules.json ships block '_wave_29_ruling' and this generator would drop it
  FAIL building_rules.json ships owner_maintenance._a_future_flag and this generator would drop it
```

The only cosmetic change that survives is `utility_spine.archetypes`, which the
generator's own encoder renders block-form because `archetypes` is in its
`FORCE_BLOCK` set; the parsed value is identical. **The shape to look for
elsewhere:** a generated file that a later wave hand-edited, where the generator
has not been run since.

**Seven cells moved**, against nine that had no transformer: `data_center` L1–L6
(400/1,020/2,600/6,630/16,900/43,150 → 100/255/650/1,660/4,230/6,070) and
`high_rise` L6 (9,700 → 4,160, the clamp's only bite). **`k_dem` did not move**
(2.35 / 2.45 / 2.55, class ordering intact), the `water_demand` column did not
move a cell, and neither did jobs, population, footprints, decay, fire, crime,
coverage or `min_city_level`.

**Hash delta, isolated to one cause** (doc 92 §68.4): the `high_rise` clamp alone
is hash-neutral on both cities — the benchmark's tallest tower is **L4** — and
the entire bench delta is the **15** authored data centres (3 × L1, 12 × L2),
`9695f766…` → `ebb5f476…` coarse and `b8548805…` → `307a6a27…` fine. The starter
city owns no data centre and does not move in any arm. Arithmetic:
`3 × 300 + 12 × 765 = 10,080 kW` of base demand removed from a 1,500-building
city.

**Three tests moved with it, each for a reason worth naming.**
`test_building_catalog.gd::test_rounding_regimes_sampled` lost its `kW ≥ 10,000`
sample because BC-1 makes that rounding rung unreachable — the largest authored
cell in the game is now 6,070 — and gained the two clamped cells instead.
`test_signature_published_cells` used to assert *"an L5 data center draws 16,900
kW"*, which was true of the table and false of the game; it now asserts the L6
cell **is** the ceiling and that one transformer carries it.
`test_power_operations.gd::test_b_when_no_placeable_transformer_carries_it_the_fix_says_so`
had to raise its synthetic demand from 4,600 kW to 12,600 — and 4,600 was never
synthetic at all, it sat between `data_center` L3 and L4, which is to say the
"impossible" branch of `_power_fix_plan` was reachable from the shipped roster.
It no longer is, and gate 34 is what proves it.

### RR-223 — the panel says WHICH RUNG, and the fix router quotes it (binding)

`PowerActions.rung_needed` (static, so `ui/fix_router.gd` reads the arithmetic
rather than a second copy of it): the smallest rung of doc 04 §2.2's ladder whose
**nameplate** carries the host transformer's **post-upgrade peak** load — the
whole load, siblings and streetlights included, because that is what §5.3's gate
is judged on. `needs_rung == 0` is kept as its own answer rather than clamped to
the top rung, because *"nothing you can buy fixes this"* is a different sentence
from *"buy the top one"*.

Three surfaces, all reading that one function: the building panel's POWER row
(`ui_power_row_needs_rung` / `ui_power_row_no_rung`), S18's customer block
(`customers_need_rung`, drawn in every state — silence would read as "the panel
does not know"), and the fix router's `FIX_POWER` answer, which now carries
`needs` beside its quote.

**Measured on a data centre at every level** (`tools/measure_envelope.gd
--panel`, founding city, seed 1337; doc 92 §68.3). The line that matters:

```
router POWER: action=upgrade_transformer to_level=2 cost=1100 clears=false
              | needs rung 4 (1000 kW), host L1
```

Before this wave the row stopped after `clears=false` — the player was told,
correctly, that the $1,100 purchase would not work, and nothing about what would.
The quote itself is unchanged and deliberately so: `cmd_upgrade_grid_component`
moves one rung per call, so a quote naming L4 from L1 would price a purchase the
verb cannot charge.

### What this wave did NOT do, named rather than hidden

* **No gate-matrix cell was re-fitted.** Doc 92 §17's agent matrix and §18b's
  50-game-day dark share have not been re-measured against the sixth rung or the
  cheaper data centre. Published to the water lane as `awaiting_consumer`.
* **Doc 05 gained a rung it did not pay for.** `pump` L5 draws 2,160 kW, which
  is **2,484 kW at the civic peak** and had no transformer at the fork; it has
  one now, at the cost of zero edits to `data/water.json`. It is the only doc 05
  row that was over — `tank` L5 is 180 kW, `source_well` L5 1,800, `treatment`
  L5 1,440, all comfortably inside the old ceiling. The lane that owns the water
  gates should know a top-level pump is buyable where it was not, and that the
  purchase it needs is a $41,500 transformer.
* **The data centre is strictly more profitable than it was.** Its revenue,
  jobs and capital columns are untouched and its power bill fell by 12,670 kW at
  L5. That is a doc 03 re-fit for the lane that owns the money matrix; doc 92
  §68.4 carries the number so it cannot be found later as a surprise.
