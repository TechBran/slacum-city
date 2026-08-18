# 96 — Structural Verification of the Report-98 Amendment Pass

**Scope:** adversarial structural audit of docs 01–13 against `98-consistency-report.md` §0 (Ruling Zero), §9 (ownership gaps), §11 (canonical save registry) and §12 (per-doc amendment worklist).
**Question asked:** which rulings were *claimed* applied but were not — changelog rows with no matching body change, deleted fields that still appear, cross-references left pointing at superseded values.
**Verdict: FAIL — 8 unapplied / stale items, 2 residual gaps.** Every ruling has a changelog row; the gaps are all in the *consuming* half of a cross-doc pair, which is exactly where a per-doc amendment pass leaks.

---

## 0. What passed

These were checked line-by-line and are genuinely applied, not merely claimed.

**Ruling Zero.** All six wrong-map docs (01, 03, 04, 06, 08, 13) carry rebuilt §5 cross-reference tables on the on-disk numbering. Docs 05, 09, 10, 11, 12 carry explicit canonical-map header notes. A regex sweep for every `doc NN` occurrence in 01–13 against a keyword model of the canonical map produced **zero** genuine mis-numberings — every hit was a false positive (a doc correctly naming a sibling's subject). Specifically checked and clean: doc 01 never calls roads "06", doc 03 never calls incidents "07", doc 04 never calls UI "10" (§5.10 is `doc 12 — UI & overlays`).

**Deleted-for-real (doc 02).** `pressure_radius_tiles`, `feeder_radius_tiles`, `upkeep_cents_per_hour`, `tax_accum_cents`, `unit_slots`, `crew_slots`, `power_supply_kw`, `power_throughput_kw` — every surviving occurrence in 01–13 is inside a deletion note, a moved-to table, or a negative test assertion (`02 §7 test 3 test_no_deleted_columns` enumerates all eight). None survives as a live column.

**Deleted-for-real (doc 04).** `base_kw` table (§2.3 now reads doc 02's `Pwr kW`), `demand.tod_curves`, `h_wind` + `veg_mult`/`ice_mult`, `upkeep_per_gh`, `build_cost`/`cost_per_tile`/`cost_per_level`/`tie_switch_cost`, lightning `target_weights` + `strike_radius_tiles`, `footprint` column. `§7 test 25 test_power_json_has_no_prices` is the mechanical guard.

**Deleted-for-real (docs 05, 06, 07, 08, 12, 13).**
- 05: `residential_hourly` / `commercial_hourly` gone; `WU_SCALE 0.1333` **applied** rather than described (every anchor, all worked examples A–F recomputed, `fire_flow_per_engine` 60 → 8.0, mains 400/1600/4800 → 53.5/213/640); §8 dollar figures removed under C-07-by-extension.
- 06: `base_fire_risk_by_archetype` + `level_risk_slope`, `purchase_cost` / `upkeep_per_game_hour` / `dispatch_cost` / `repair_material_base`, `weather_mult` / `flood_mult` on `RouteProfile`, `weather_speed_mult` / `road_class_mult`.
- 07: `repair_cost_mult`, `season_length_days = 21` + the 84-day year + `floor((sim_day % 84)/21)`, per-span wind rolls, lightning `damage_bands`.
- 08: `WorkerThreadPool` branch + `async_threshold_hours`, flat 1.00/0.60 yield rows, old registry (replaced with report §11 **verbatim**, 24 section keys, arithmetic checked: 19 − 3 + (3+2+3) = 24 and the JSON example lists exactly 24).
- 12: `data/notifications.json` block, `manual_collection`, `fov_deg`/`near_m`/`far_m`.
- 13: `offline_max_hours = 72`, `.bak` rotation + `saves_recovered_from_backup`, the parallel rate limiter (`max_per_wake`, `max_p3_per_wake`, `max_per_day`, `min_gap_s`, `quiet_shift_max_s`, `thresholds`), `plan_horizon_hours = 24`.
- 03: `economy.manual_collection` confirmed absent, with §9 item 2 moved from "needs sign-off" to RULED.

**Added-for-real.** `water_facility.variant` (02 §2.1/§2.4/§3.1/§8 + loader invariant `variants present iff id == water_facility`) · `E_AVENUE` as check #13 (02 §2.11 + 12 §4.4 13-code enum + 10's `has_class_within` lookup) · `sim/buildings/coverage.gd` (02 §2.9/§4/§6) · `ConstructionQueue.submit/reorder/cancel/list` (02 §2.13, consumed by 06, 09, 10, 12, 13) · crews-as-units (06 §2.12) · `power_availability_hour` (04, consumed by 02/03/06/09) · `water_service_factor_hour` (05 §5.4) · `restore_order` + `powered_fraction` + `block_dark` (04 §2.4/§4/§8) · `speed`/`heading` on `vehicle_state` (06 §2.11/§4/§7 test 34) · `precip01` (07, consumed by 04/09/10/11/12) · F8 tightened verbatim to doc 08 §2.3 rule 1 (07 §2.6.4, save field `offline_major_window` → `offline_hazard_used`) · `is_resync` (08 §4, 11 §2.7.6, 12) · doc 09 retitled and absorbing `population`/`progression`/`stats` with the **18/5/3/1 manifest reverted** ($686/gh exact, pop 256→144, jobs 176→152, vacant lots 1,399→1,429) · `block_road_access_score` (09 §2.2/§2.6/§8 + 03/10/11 all naming it) · AVENUE/STREET template adoption at **87 tiles** (10 §2.3, 60 AVENUE + 27 STREET, 783 in core, 169 buildable, RLE re-derived to 55 runs) · `occupancy_hour_curve` + §2.15 audio Phase-2 note (11) · `data/strings.en.json` + `in_app_alerts` (12 §3.1/§8) · `SaveManager.request_save("pause")` (13 §2.2).

**`section_version` rename.** Landed in 01, 02, 04, 09, 10, 12. Every surviving `schema_version` in those six docs is either the save envelope, a `data/*.json` file version, or a negative test assertion. Docs 05, 08, 11 also confirmed (11 applied it to `render_prefs` although it was not on its worklist).

**Amendments-applied sections.** All 13 docs (01–13) carry one. Every ruling id listed in report §12 for a doc appears in that doc's table:

| doc | §12 ids | all present | extras applied beyond §12 |
|---|---|---|---|
| 01 | RZ, C-19, C-21, C-22, C-25, C-27, C-32/33, C-55 | ✔ | — |
| 02 | C-06…C-62, G-2 (20 ids) | ✔ | RZ, C-34, C-47, C-29, C-61, C-26/G-1/C-66/C-37, R-03 |
| 03 | RZ, C-07, C-12, C-16, C-17, C-18, C-20, C-56, C-59, C-61 | ✔ | C-25, R-04, R-14 |
| 04 | RZ, C-07/08/12, C-16, C-25, C-30, C-31, C-32, C-36, C-37, C-38, C-39, C-40, C-41, C-53, C-54 | ✔ | R-06, R-07, R-08 |
| 05 | C-06, C-16, C-33, C-34, C-35, C-36, C-37, C-46 | ✔ | RZ, R-09, R-10, C-07, C-25, C-02 |
| 06 | RZ, C-07, C-42…C-53, C-67, C-70, G-2 | ✔ | R-11…R-14, C-17, C-25 |
| 07 | RZ, C-16, C-17, C-28, C-53…C-59 | ✔ | — |
| 08 | RZ, C-03, C-04, C-19…C-24, C-26, C-47, C-68, C-71 | ✔ | R-15, C-17, C-55, C-72, C-25, G-7 |
| 09 | C-11, C-25, C-29, C-34, C-38, C-56, C-60, C-61, G-1, G-7, R-16 | ✔ | RZ, C-13, C-32, C-35, G-4, G-5 |
| 10 | C-25, C-29, C-48, C-60, C-62, C-63, X-1/X-2 | ✔ | RZ, C-61, G-2, G-6, C-49, C-59, C-45, C-70 |
| 11 | C-38, C-39/40, C-58, C-63, C-64, C-66, C-68, G-3, G-7 | ✔ | RZ, R-17, C-25, C-14, C-59/67/69/60/61 |
| 12 | C-25, C-35, C-59, C-62, C-63, C-64, C-65, C-71/72, G-8 | ✔ | RZ |
| 13 | RZ, C-04, C-19, C-23, C-24, C-71, spec §21.1 | ✔ | C-72, C-25 |

Constitution `00` has no *Amendments applied* section (out of the 01–13 scope), but all four requested amendments are visibly in the body and tagged: §4 `tick_index` canonical *(C-01)*, §4 game-time cadences *(C-02)*, §2 `user://settings.cfg` *(C-03)*, §2 zstd note *(C-05)*.

---

## 1. Findings — unapplied rulings and stale cross-references

### F-1 — **doc 11 / doc 04, C-38: the renamed blackout event was renamed on one side only** *(severity: high — breaks the wire)*

Doc 04 renamed the event and made the old name a test failure:

> `04 §4`: **`BlockDarkChanged`** (renamed from `DistrictDarkChanged`, report 98 C-38)
> `04 §7 test 23`: "…emits `BlockDarkChanged` (**never** `DistrictDarkChanged`)"

Doc 11 explicitly refused the rename of the *carrier*:

> `11 §2.7.2`: "The carrying event keeps its name `DistrictDarkChanged`; only the flag is renamed."

`grep -c BlockDarkChanged 11-rendering-performance.md` = **0**. Doc 11 subscribes to `DistrictDarkChanged` in §2.7.2, §2.7.3, §2.7.5, §4 (events consumed) and §5; doc 04 asserts it never emits that name. The renderer's blackout/relight signature — a named spec beat — receives nothing. C-38's ruling text renames the *flag* and is silent on the event, so both docs read it defensibly; the result is still a broken contract that no test catches (doc 04's test 23 passes, doc 11's tests 12/12b/14 are fed synthetic events).

**Fix owner:** one of 04 or 11 must move. Doc 04's `BlockDarkChanged` is the more consistent choice (every payload field is block-scoped).

### F-2 — **doc 04 §9 + C-40 changelog row: stale claim that doc 11 still ships `momentary_outage_s = 2.50`** *(severity: medium)*

`04:717`: "**Doc 11's `momentary_outage_s = 2.50` does not satisfy the C-40 bound** … the assertion will fail on first run unless doc 11 raises the constant to ≥ 4.5 s".
`04:745` (C-40 changelog row): "§9 flags that doc 11's current 2.50 fails it."

Doc 11 **did** apply C-40: §2.7.5 recomputes `momentary_outage_s` 2.50 → **4.50 s**, `data/render.json` §8 ships `4.50` with the derivation comment, and test 24 "passes at equality". Doc 04 is describing a pre-amendment world and asks for a fix that already landed.

### F-3 — **doc 04 §2.13: stale 508 kW starter-city building load** *(severity: medium)*

`04:370`: "an L1 gas plant at 8,000 kW still covers the C-11 starter city's **508 kW** building load with 15× headroom".

508 kW is the **pre-C-11** 28/8/6/1 nameplate (and it uses doc 02's *deleted* flat 60 kW `water_facility` figure). The owning doc's R-16 recomputation gives **402.0 kW** nameplate and **783.3 kW** at the 20:00 night peak including distributed sinks. Doc 09 §9 flags this explicitly ("the figure should be restated"); doc 04 never did. The report itself seeded the error at §11/C-11 ("power (508 kW building load)"), so the stale number is repeated in two places. The headroom *claim* survives (≈20× nameplate, ≈10× night peak), only the figure is wrong.

### F-4 — **doc 10 vs doc 03, C-07: road prices were never moved, and doc 03's guard test forbids them where they are** *(severity: high — a shipped test fails on day one)*

`03 §7 test 33 test_single_price_table`: "grep-style assertion over `data/`: `build_cost`, `purchase_cost`, `upkeep_per_gh`, `upkeep_cents_per_hour`, `dispatch_cost` and `cost_frac_of_build` appear in **no** file except `data/economy.json`."

`10 §8 data/roads.json` ships `"build_cost": 1800` (STREET), `"build_cost": 5200` (AVENUE), `"upkeep_per_game_day"` on both classes, and `"repair_cost_base": 600`.

Doc 10 records the tension honestly (§9.2 X-9, §10 "§13 blocked list") and declines to move unilaterally, correctly noting that doc 03 §5 *assigns* road job pricing to doc 10 (`03:968`). But doc 03's C-07 amendment neither carved roads out of test 33 nor added a `roads` row to §2.13's ladder, and report §12 gives doc 10 no C-07 row. Net: the currency-monopoly ruling has a hole in it, and the only mechanical guard on the ruling fails against the shipped data file. Compare doc 05, which removed its prices under "C-07 (by extension)" without being listed either — the two docs resolved the same unlisted ruling in opposite directions.

### F-5 — **doc 05 §2.4: stale starter water demand (8.2 m³/h, 4.9× headroom)** *(severity: low-medium)*

`05:439`: "doc 09's starter water demand lands at **8.2 m³/h** against 40 m³/h of L1 supply (4.9× headroom, R-16)".

`51.1 / 6.25 = 8.18` rescales the **old 28/8/6/1** manifest only. Applying C-11's reverted mix as well gives **5.56 m³/h** and **7.2×** headroom (doc 09 §2.9.4, and §9 flags doc 05 by name). Report §11/C-34 carries the same 8.2 figure, so this is another report-seeded stale number propagated into a doc.

### F-6 — **doc 03 §2.12: starter expense line not re-run for the C-34 water rescale** *(severity: medium)*

The restated expense line keeps `water treat 1 · pump O&M 5` and states outright: "**Every other line is unchanged.**" Doc 05 §9 item 12 computes the post-rescale value from its own `E_water` inputs: `pump_capacity_m3h (40) × PUMP_OM_PER_M3H_HOUR (0.35)` = **$14/gh**, and flags "stale after the rescale … flagged for doc 03/doc 09's R-16 pass".

R-04's mandate was C-12 (electrical), so doc 03 scoped its re-run to the grid line only — but C-34 landed in the same pass and moves the same table. The $347/gh total, the +$373/gh net, and every downstream cell of the regenerated S1–S12 pacing table inherit the error.

### F-7 — **doc 03 §2.12: revenue line still uses the pre-amendment 0.90 aggregate multiplier** *(severity: medium)*

`03:630`: `tax 686 × 0.90 = 617`.

Doc 09 §2.10.3 (its R-16 pass, and it now *owns* stability and happiness under G-1) derives `f_stability 0.972 × f_happiness 1.110 = 1.079` at t0, giving **$740/gh** before tariffs. Doc 09 §9 item 7 raises it as "a number to feed in, not a conflict" and offers the honest lever (`happiness.norms` centres in `data/progression.json`). Doc 03 re-ran its table under R-04 without ingesting it, so the two docs disagree by ~20% on starting revenue.

### F-8 — **doc 03 §5 + §8: `DEMAND_LEVEL_GROWTH must equal 2.35` was not updated for C-13** *(severity: low)*

`03:939` (§5 requirements on doc 02): "`DEMAND_LEVEL_GROWTH` **must equal 2.35**".
`03:1093` (`data/economy.json`): `"REQUIRED_DEMAND_LEVEL_GROWTH": 2.35`.

C-13 ruled three class-specific values: doc 02 ships `k_dem = 2.35 steady / 2.45 standard / 2.55 vertical`, and its test 4 asserts the correct post-ruling invariant — `k_dem > TAX_LEVEL_GROWTH (2.15)` for all three classes, read from `data/economy.json` at test time. Doc 03's §9 item 4 *parenthetically* acknowledges the three values, but the normative §5 row and the shipped data constant still assert equality against a single number. Any loader that honours `REQUIRED_DEMAND_LEVEL_GROWTH` literally rejects `apartment`, `office`, `high_rise`, `data_center`, both stations, both utility shells and `construction_yard`.

---

## 2. Residual gaps the pass surfaced but did not close

These are not unapplied rulings — the report never ruled them — but they are structural holes left open at the end of an amendment pass that claims completeness.

### R-1 — `weather_mults` (doc 06) vs `get_effect()` channels (doc 07): two statements of one quantity

Doc 06 §9 item 6 states it plainly: doc 06 still authors `weather_mults.crime / .fire / .transformer / .traffic` while doc 07 publishes `incident_crime_mult`, `incident_traffic_mult`, `incident_utility_mult`, `fire_ignition_mult` over the same weather states. C-57 struck doc 02's inline weather constants on exactly this principle but named only doc 02. Doc 06: "**Requesting a ruling; nothing has been changed pending it.**" Doc 06 also notes three of its columns (`snow`, `blizzard`, `fog`) are dead against doc 07's MVP state set.

### R-2 — road `condition` stays on [0,100] while C-14 says "everywhere"

C-14's resolution reads "**`condition ∈ [0,1]` everywhere**"; its *Amend* line names only doc 02 §2.6/§2.11/§3.2/§8. Doc 02 rescaled. Doc 10 keeps `condition : float 0..100` (§2.1, `cost_per_tile = ROAD_REPAIR_COST_BASE × (1 − condition/100)`, `job_completed → condition 100`), and doc 06's test 30 consumes the road scale as 100/55/10. The two scales are consistent *with each other* and probably intentional (roads are not buildings), but no doc states the carve-out, so the next reader of C-14 has to rediscover it. One sentence in doc 10 §2.1 or doc 02 §2.6 closes it.

---

## 3. Pattern

Every finding except F-4 and F-8 is the same shape: **the doc that owns a number amended it; the doc that quotes the number did not.** Docs 09, 05, 10 and 06 all did the right thing — they flagged the stale sibling in their own §9 — and in each case the sibling never read the flag. F-1 is the sharpest form: both docs amended, in incompatible directions, each citing the same ruling.

The report's §12 worklist is per-doc by design, which makes this leakage structural rather than accidental. Two cheap guards would catch all of it:

1. **A quoted-number registry.** Any figure a doc states that another doc owns gets a `⟨owner:section⟩` tag; a script greps for tags whose owning section changed in the same pass. F-2, F-3, F-5, F-6, F-7 all die here.
2. **A cross-doc identifier diff.** Emitted event names, published API names and data-file keys, extracted per doc and diffed pairwise between emitter and consumer. F-1 dies here, and so would any future rename.
