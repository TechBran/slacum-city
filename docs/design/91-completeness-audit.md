# 91 — Completeness audit

**The honest ledger of what "completely built out" still lacks.**

Provenance: written against `6d8c2b1` (post Wave-4), Godot 4.7.2, 1,249 tests +
20 balance gates green. Companion to doc 93 (rulings ledger) and doc 92 (balance
pass 3), which remain the truth about *rules* and *numbers*; this document is the
truth about *coverage* — which paragraph of docs 01–13 has code behind it, and
which does not.

## 0. Method

Every `§2.x` subsection of docs 01–13 is one row. A row is graded by reading the
section, then finding the code that implements it and the test that holds it —
not by trusting a changelog. Where a row is PARTIAL or ABSENT the pointer names
the specific gap, so the row is actionable without re-reading the doc.

Two new harnesses supplied the behavioural half of the audit; §14 reports what
they found and §15 ranks it. A handful of rows are marked `—` rather than a
section number: those are cross-cutting findings that belong to a whole document
rather than to one of its subsections (doc 05's missing player verbs, for
instance). They are counted in the tally like any other row.

| Harness | What it does | Where |
|---|---|---|
| Tutorial flow test | drives all eleven onboarding steps through the real UI models over a real `CitySim`, then over the real `game/main.tscn` shell | `tests/test_tutorial_flow.gd`, `tools/flow_test.gd` |
| QA soak | a 2-real-hour session at mixed speeds with seeded player verbs, forced storms, save/load cycles and app pause/resume; measures objects, step cost, bus volume and sanity bounds | `tools/qa_soak.gd`, `tests/test_qa_soak.gd` |

### Legend

| Grade | Meaning |
|---|---|
| **SHIPPED** | implemented, reachable in play, covered by a test |
| **PARTIAL** | implemented in part — or implemented in `sim/` but **not reachable by a player**, which for a game is the same thing |
| **ABSENT** | no implementation |
| **IN FLIGHT** | landing in a sibling Wave-5 branch, verified absent from this tree — **retired 2026-08-19**, zero rows carry it; the two that did are re-graded against the tree they landed in |
| **DEFERRED** | the doc itself defers it (not a gap) |

### The count

| Doc | Rows | SHIPPED | PARTIAL | ABSENT | IN FLIGHT | DEFERRED |
|---|---|---|---|---|---|---|
| 01 Time & ticks | 12 | 11 | 0 | 1 | 0 | 0 |
| 02 Buildings | 13 | 12 | 1 | 0 | 0 | 0 |
| 03 Economy | 13 | 13 | 0 | 0 | 0 | 0 |
| 04 Power grid | 13 | 11 | 1 | 0 | 0 | 1 |
| 05 Water | 15 | 12 | 2 | 0 | 0 | 1 |
| 06 Incidents & dispatch | 13 | 11 | 2 | 0 | 0 | 0 |
| 07 Weather & director | 7 | 7 | 0 | 0 | 0 | 0 |
| 08 Offline & persistence | 13 | 10 | 1 | 2 | 0 | 0 |
| 09 Map, land, starter city | 13 | 12 | 0 | 1 | 0 | 0 |
| 10 Roads & traffic | 15 | 13 | 2 | 0 | 0 | 0 |
| 11 Rendering & performance | 15 | 14 | 1 | 0 | 0 | 0 |
| 12 UI/UX | 18 | 16 | 2 | 0 | 0 | 0 |
| 13 Android | 13 | 5 | 3 | 5 | 0 | 0 |
| **Total** | **173** | **147** | **15** | **9** | **0** | **2** |

*Wave-6 revision (2026-08-19): doc 12 §2.8 and §2.14 moved ABSENT → SHIPPED; §2.2
and §2.13 stay PARTIAL on S10 (**S0 shipped in Wave 7** — `ui/title_screen.gd`). Everything below the count table is as
written at `6d8c2b1` unless a row says otherwise.*

*Wave-7 revision (2026-08-19), seven rows and one grade retired. Doc 08 §2.2,
§2.5, §2.7, §2.8, §2.9 and doc 01 §2.10 moved PARTIAL → SHIPPED on the
persistence unification and the `CatchUpPlanner` resume wiring; doc 02 §2.4 moved
IN FLIGHT → SHIPPED and §2.9 IN FLIGHT → PARTIAL, which empties the **IN FLIGHT**
column — the sibling Wave-5 branches it named have all landed or been re-graded
against the tree, so the grade has no rows left and no further use. Each moved
row carries its own dated note; nothing was moved without a named file and a
named test.*

**85 % shipped** (147 of 173, up from 140). Of the 26 rows that are not (two more
are deferred by their own docs, which is not a gap), the weight sits in one place
now rather than two:

* **The Android platform layer** — doc 13's notifications, permissions, signing
  and store assets: 5 ABSENT rows, and the only ones on the critical path to a
  build a stranger can install.
* ~~**Persistence under the shell**~~ — **closed 2026-08-19.** Doc 08's generation
  ladder, retention, migration and corruption gate are no longer reachable from
  nowhere: `game/save_service.gd` is a thin slot API over `SaveManager`, the
  second format is read-only legacy, and the five PARTIAL rows this bullet
  counted are SHIPPED. §8 carries the row-by-row evidence.
* ~~**Player verbs for infrastructure**~~ — **closed.** Water landed in Wave 5B,
  roads in 5A, land in Wave 6 (S4). Exactly as predicted, not one line of new
  simulation was needed for any of the three: a `cmd_*` re-export, a card, and
  in land's case a panel and a tap seam.

---

## 1. Doc 01 — Time and ticks

| § | Subject | Grade | Pointer / gap |
|---|---|---|---|
| 2.1 | Units, canonical counter | SHIPPED | `sim/time/game_clock.gd`; `tests/test_game_clock.gd` |
| 2.2 | Calendar derivation | SHIPPED | `GameClock.day_index/minute_of_day`; `test_game_clock.gd` |
| 2.3 | Cadences | SHIPPED | `SimSystem.Cadence`, `TickScheduler`; `test_scheduler.gd` |
| 2.4 | Deterministic phase order | SHIPPED | `TickScheduler._system_less` sorts (phase, id); `test_scheduler.gd` |
| 2.5 | Fine and coarse advance | SHIPPED | `TickScheduler.advance_fine_n/advance_coarse_n`; `test_city_sim.gd` |
| 2.6 | Day/night curves, modifier channels | SHIPPED | `sim/time/day_curve_set.gd`, `modifier_stack.gd`; `test_day_curves.gd` |
| 2.7 | Timers vs work units | SHIPPED | `timer_service.gd`, `work_service.gd`; `test_timer_work.gd` |
| 2.8 | Scheduled events | SHIPPED | `sim/time/scheduled_events.gd` |
| 2.9 | Pause and speed | SHIPPED | `SimHost` accumulator + `CityHUD` speed rail |
| 2.10 | Offline catch-up planner | ~~PARTIAL~~ **SHIPPED 2026-08-19** | `main.gd._on_app_resumed` (line 1232) calls `CatchUpPlanner.plan()` and walks its segments, so the grace window, the 12-hour cap, the head-align and the residual carry all apply on the path the app actually runs. **D-1 closed.** |
| 2.11 | Notification pre-scheduling | ABSENT (platform half) | `scheduled_events.gd` carries the `notify` flags per phase; `game/notifications/notification_scheduler.gd` now turns the deterministic ones into a plan, but the OS half is still doc 13 §2.4's, and this row is counted there rather than twice. |
| 2.12 | Performance budget | SHIPPED | `tools/profile_sim.gd` per-phase table + `--baseline` identity gate |

## 2. Doc 02 — Buildings

| § | Subject | Grade | Pointer / gap |
|---|---|---|---|
| 2.1 | Roster & taxonomy | SHIPPED | `BuildingCatalog.ARCHETYPE_COUNT` = 12; `test_building_catalog.gd` |
| 2.2 | Curve family | SHIPPED | `data/buildings.json` generated by `tools/gen_buildings.py`; catalog validates every cell |
| 2.3 | Full stat tables | SHIPPED | 60 rows validated at boot; `test_building_catalog.gd` |
| 2.4 | Coverage reach table | ~~IN FLIGHT~~ **SHIPPED 2026-08-19** | the sibling branch landed. `sim/incidents/coverage_index.gd` is §2.9's formula verbatim and `sim/incidents/city_incident_world.gd:188` reads `coverage_radius_tiles` off the catalog to build its station rows; 12 tests in `tests/test_coverage.gd`, anchored on the doc's own worked example E6 at radius 23. |
| 2.5 | Runtime outputs | SHIPPED | `Building` publishes population/jobs/demand; consumed by `PopulationSystem`, `PowerGrid`, `WaterSystem` |
| 2.6 | Condition & decay | SHIPPED | `Building.decay` + `CitySim.apply_hourly_decay`; `test_building.gd` |
| 2.7 | Fire ignition | SHIPPED | ignition rates in the catalog, dynamics in `sim/incidents/fire_spread.gd` |
| 2.8 | Crime attractiveness | SHIPPED | `crime_weight` column feeds doc 06 generation |
| 2.9 | Service coverage | ~~IN FLIGHT~~ **PARTIAL** | *(re-graded 2026-08-19)* The field itself ships: `CoverageIndex` + `CityIncidentWorld.coverage_police/coverage_fire`, consumed by doc 06's crime generation (`IncidentSystem`, `× (1 + 0.15 · coverage_police)`) and rendered by the POLICE/FIRE overlays, which read `req_police_coverage` / `req_fire_coverage` per building (`main.gd:832`). **Two consumers are still missing**, and grep is the proof: `safety_coverage_factor` is read only by the catalog validator and one test, and §2.9's upgrade gates `E_FIRE_COVERAGE` / `E_POLICE_COVERAGE` do not exist anywhere in the tree — so falling below a requirement costs a player nothing yet. |
| 2.10 | Construction & upgrade timing | SHIPPED | `ConstructionQueue`; `test_construction_stages.gd` |
| 2.11 | Upgrade preconditions | SHIPPED | `BuildController.UPGRADE_CHECKS` + `CitySim.cmd_upgrade_building` |
| 2.12 | Building state machine | SHIPPED | eight states in `Building`; `test_building.gd` |
| 2.13 | Construction projects & queue | SHIPPED | `sim/construction/`; `test_construction_queue.gd` |

## 3. Doc 03 — Economy

Doc 92's balance pass 3 walked this document end to end; every row below is
shipped and gated. Listed for completeness rather than for news.

| § | Subject | Grade | Pointer |
|---|---|---|---|
| 2.1 | Settlement loop | SHIPPED | `EconomySystem.settle_hour`; `test_economy.gd` |
| 2.2 | Tax revenue formula | SHIPPED | `EconomySystem` + `CitySim.cmd_set_tax_level` |
| 2.3 | Capital value & upgrade curve | SHIPPED | `CostCurves` |
| 2.4 | Expense model | SHIPPED | `Treasury` + maintenance fit (Wave 4) |
| 2.5 | Non-tax revenue, repairs, PM | SHIPPED | `cmd_repair_building`, `CostCurves.repair_cost` |
| 2.6 | Net-income presentation | SHIPPED | `ui/budget_model.gd`, HUD net chip |
| 2.7 | Land purchase price | SHIPPED | `CitySim.land_price_inputs` + `EconomySystem.land_price` |
| 2.8 | Land development phase costs | SHIPPED | `CitySim._development_phase_cost` |
| 2.9 | Difficulty | SHIPPED | `Treasury.difficulty()` from `data/difficulty.json` |
| 2.10 | Anti-bankruptcy floor | SHIPPED | austerity + credit ladder; the soak's random player was refused `E_AUSTERITY` 47 times |
| 2.11 | Offline income rules | SHIPPED | coarse path settles hourly; `test_city_sim.gd` |
| 2.12 | Treasury pacing | SHIPPED | doc 92 pass 3, `tests/test_balance_gates.gd` |
| 2.13 | Currency ladder | SHIPPED | `CostCurves` is the sole authority |

## 4. Doc 04 — Power grid

| § | Subject | Grade | Pointer / gap |
|---|---|---|---|
| 2.1 | Topology | SHIPPED | `PowerGrid` feeders/transformers/ties |
| 2.2 | Component stat ladders | SHIPPED | `data/grid_components.json` |
| 2.3 | Demand model | SHIPPED | `CitySim.compose_demands` |
| 2.4 | Load-flow solve, four passes | SHIPPED | `PowerGrid.solve`; `test_power_grid.gd` |
| 2.5 | Overload → protection trips | SHIPPED | `test_power_grid.gd` |
| 2.6 | Heat → failure probability | SHIPPED | `theta_c` / `trip_accum` on every component |
| 2.7 | Weather couplings | SHIPPED | `sim/weather/grid_strike_adapter.gd` |
| 2.8 | Failure types & incidents | SHIPPED | `IncidentSystem.on_power_event`; `test_incidents_transformer_arc.gd` |
| 2.9 | Cascades, ties, N-1 | SHIPPED | `_ties` + `_tag_cascade` |
| 2.10 | Backup generators (fuel) | **PARTIAL** | doc 04 owns the generator; only doc 05's `cmd_install_backup_generator` exists, and *it* is unreachable (doc 05 row below). No fuel model in `PowerGrid`. |
| 2.11 | Black start | DEFERRED | deferred by the doc (spec §13.4) |
| 2.12 | Offline catch-up | SHIPPED | `PowerPhaseSystem.advance_coarse` |
| 2.13 | Worked examples | SHIPPED | reproduced in `test_power_grid.gd` |

**Placement scope note.** `data/grid_components.json` states plainly that Wave 1.5
ships placement of *one* component — the transformer — and that
`upgrade_power_component`, `demolish_power_component`, `route_feeder` and
`place_tie` stay unplaceable until their commands land. That is honest, and it is
still a gap: three quarters of doc 04's §4 verb list has no player.

**Visibility gap — CLOSED 2026-08-20.** Every row above graded SHIPPED on the
SIM, and until this date **none of doc 04's distribution end had any
representation on screen.** A transformer is not a building (§2.1: one tile,
`FLAG_OCCUPIED`, no footprint row), so nothing in the renderer was drawing one; a
player could read an overlay tint and an Infrastructure row but could not see
where the transformer serving their block stood, which buildings it fed, or that
it was cooking. The grade was right and the game was still missing the object.
Doc 11 §2.10b now draws the pads, the service drops and the distress, off two new
read-only `PowerGrid` accessors and doc 04's own bands — `tests/test_power_infra.gd`,
+1 draw call at Z2, hash-neutral on both baseline cities. Worth recording as a
class of gap this audit's per-§ grading cannot see: **a subsystem can be fully
shipped and wholly invisible**, and the two facts do not contradict each other.

## 5. Doc 05 — Water

| § | Subject | Grade | Pointer / gap |
|---|---|---|---|
| 2.1 | The graph | SHIPPED | `WaterTopology`, `WaterNode`, `WaterEdge` |
| 2.2 | Pressure zones | SHIPPED | `PressureZone`; `test_water_system.gd` |
| 2.3 | Per-tile static factor | SHIPPED | `WaterData` |
| 2.4 | Demand aggregation | SHIPPED | `WaterDemandCache`; `test_water_data.gd` |
| 2.5 | Supply chain availability | SHIPPED | `WaterSystem` |
| 2.6 | Power dependency & backup | SHIPPED | `CitySim._water_kw_by_building` |
| 2.7 | Tank drain / refill | SHIPPED | `test_water_system.gd` |
| 2.8 | Pressure factor | SHIPPED | `WaterServiceLedger` |
| 2.9 | Failure model | SHIPPED | `WaterFailureModel`; `test_water_failures.gd` |
| 2.10 | Contamination | DEFERRED | stub by the doc's own wording |
| 2.11 | Effects on buildings/happiness | SHIPPED | `test_water_integration.gd` |
| 2.12 | Repair mechanics | SHIPPED | `WaterRepairJobs` |
| 2.13 | C-34 rescale | SHIPPED | applied; `test_water_data.gd` |
| — | **Player verbs** | **PARTIAL** | `WaterSystem` exposes ten `cmd_*` (`cmd_place_water_node`, `cmd_place_main`, `cmd_upgrade_water_node`, `cmd_install_backup_generator`, `cmd_isolate_main`, …). **None is re-exported by `CitySim`**, so `ui/build_controller.gd` cannot see them and no card exists. A player can watch the water system but cannot touch it. See **D-4**. |
| — | Overlay | PARTIAL | mode 2 ships (`OverlayModel.MODE_WATER`), but with no verbs the overlay is diagnosis without treatment |

## 6. Doc 06 — Incidents and dispatch

| § | Subject | Grade | Pointer / gap |
|---|---|---|---|
| 2.1 | Sub-step integrator | SHIPPED | `IncidentSystem.advance_to` |
| 2.2 | Incident object & FSM | SHIPPED | `Incident`; `test_incidents_core.gd` |
| 2.3 | Severity model | SHIPPED | `test_incidents_core.gd` |
| 2.4 | Escalation math | SHIPPED | `test_incidents_lifecycle.gd` |
| 2.5 | Resolution math | SHIPPED | `test_incidents_lifecycle.gd` |
| 2.6 | Generation | **PARTIAL** | the generator runs, and at starter-city scale it fires **≈2 incidents per 287 game-hours** (soak, §14.2). That is arithmetically consistent with doc 02's authored ignition rates for a 24–34 building city — but it means the whole dispatch loop, the drawer, the picker and the fleet are exercised roughly once every six game-days in normal play. A content gap, not a code gap. See **D-6**. |
| 2.7 | Catalog | SHIPPED | `IncidentCatalog` / `data/incidents.json` |
| 2.8 | Fire spread & suppression | SHIPPED | `sim/incidents/fire_spread.gd` |
| 2.9 | Dispatch priority scoring | SHIPPED | `DispatchSystem` |
| 2.10 | Assignment algorithm | SHIPPED | `DispatchSystem._assign`; `test_incidents_dispatch.gd` |
| 2.11 | Vehicle model & FSM | SHIPPED | `Vehicle`; `test_vehicle_motion.gd` |
| 2.12 | Auto-dispatch policy | **PARTIAL** | `DispatchPolicy` + `cmd_set_dispatch_policy` exist; no settings row exposes them, so `auto_dispatch_*` is permanently at its default `true`. That default is what makes **D-2** possible. |
| 2.13 | Offline catch-up integration | SHIPPED | `world.offline` gate; `test_incidents_lifecycle.gd` |

## 7. Doc 07 — Weather and the disaster director

| § | Subject | Grade | Pointer |
|---|---|---|---|
| 2.1 | Weather state machine | SHIPPED | `WeatherSystem` + `WeatherTimeline`; `test_weather_system.gd` |
| 2.2 | Effect multiplier table | SHIPPED | `WeatherTables`; `test_weather_integration.gd` |
| 2.3 | Storm cell | SHIPPED | `StormCell` |
| 2.4 | Localized flooding | SHIPPED | `FloodField` — live, not a stub: the soak logged 460 `flood_level_changed` and 92 `road_closed_flood` |
| 2.5 | Forecast | SHIPPED | `WeatherForecast`; `test_weather_forecast.gd` |
| 2.6 | Disaster Director v1 | SHIPPED | `DisasterDirector` + `IncidentRequestSink`; `test_weather_director.gd` |
| 2.7 | MVP severe thunderstorm | SHIPPED | `sim/weather/severe_thunderstorm.gd`; `test_weather_lightning.gd` |

## 8. Doc 08 — Offline and persistence

The weakest document in the tree, and the one whose gaps are invisible from
inside the game.

*Re-graded 2026-08-19 (Wave 7). Five rows moved PARTIAL → SHIPPED and three more
had their pointers corrected, almost all for the same reason: the unification
landed and `game/save_service.gd` now rides `sim/persistence/save_manager.gd`
instead of a second format of its own. The pre-unification grades are struck
rather than deleted, because the audit's value is the record of what was actually
wrong.*

| § | Subject | Grade | Pointer / gap |
|---|---|---|---|
| 2.1 | Division of labour with doc 01 | SHIPPED | respected in `CitySim` |
| 2.2 | Fidelity bands / cap policy | ~~PARTIAL~~ **SHIPPED 2026-08-19** | `main.gd._on_app_resumed` (line 1232) plans the resume through `CatchUpPlanner.plan()` and walks its segments, so the 12-hour cap, the two-minute grace and the residual carry all apply on device. **D-1 closed.** |
| 2.3 | Anti-frustration invariants | ~~PARTIAL~~ **PARTIAL — narrower** | `tests/test_catchup_planner.gd` and `tests/test_qa_soak.gd::test_planned_resume_advances_a_live_city_from_any_tick` now assert against the same planner call the shell makes, so the divergence the row was filed for is gone. What is still untested is `main.gd`'s own body — no headless test drives `_on_app_resumed`. |
| 2.4 | Auto-response during catch-up | SHIPPED | `IncidentWorld.offline` |
| 2.5 | Save file layout | ~~PARTIAL~~ **SHIPPED 2026-08-19** | One format. `SaveService.save_slot` builds three `DictSection`s and commits them through `SaveManager.request_save`; a slot is `user://saves/slot_N/{manifest.json, gen_%06d.sav, quarantine/}`. `tests/test_save_service.gd::test_a_slot_is_a_generation_ladder`. |
| 2.6 | Atomic write protocol | SHIPPED | ~~both writers~~ **the one writer** does temp + rename — `SaveManager._write_compressed_atomic` / `_write_manifest_atomic`, the manifest rename being the commit point |
| 2.7 | Checkpoint cadence & rotation | ~~PARTIAL~~ **SHIPPED 2026-08-19** | `_apply_retention` / `_sweep` run on every shell save, off `data/persistence.json.save` through `SavePolicy` (6 unpinned + 2 pinned; 0/30 min/6 h/24 h/7 d). `save_slot(sim, slot, reason)` carries §2.7's reason, so `pre_migration` / `pre_catchup` pin from the shell. `test_retention_comes_from_data_and_bounds_the_slot`, `test_a_pinned_checkpoint_is_never_swept`. |
| 2.8 | Versioning & migration | ~~PARTIAL~~ **SHIPPED 2026-08-19** | Both levels. Envelope: `SaveManager.CURRENT_SCHEMA_VERSION` + `LADDER`; section: `DictSection.section_version()` with the sim's own `migrate_save_section` hook. Format 1 → 2 is a real migration with a real fixture — `tests/test_save_migration.gd` runs nine tests against `tests/fixtures/legacy_slot_format1.json`, a byte-for-byte capture of a pre-change write that is never regenerated. |
| 2.9 | Load & corruption recovery | ~~PARTIAL~~ **SHIPPED 2026-08-19** | `SaveService.load_slot` is the §2.9 gate: candidate walk, SHA-256, version range, structural repair, quarantine, then the format-1 file as a last pinned candidate. `last_load_recovered` / `last_load_lost_minutes` / `repair_notes` carry the "you lost about N minutes" figure back to the UI. `test_a_ruined_generation_falls_through_to_the_one_behind_it`, `test_delete_takes_the_quarantine_with_it`. |
| 2.10 | Event history rings | **ABSENT** | `ui/event_log_model.gd` keeps a session-lifetime ring in memory; nothing persists it, so the log is empty on every launch |
| 2.11 | WHILE YOU WERE AWAY report | SHIPPED | `AwayModel` + `AwayReportSheet`, driven from `main.gd._on_app_resumed` |
| 2.12 | Performance budget | SHIPPED | soak: a 45-minute absence catches up in **1.04 s** (43 coarse hours) |
| 2.13 | Notification policy | **ABSENT** | Still absent, but for a narrower reason than when this row was written: `game/notifications/` now schedules, routes and budgets, and `NotificationBudget.serialize()` / `deserialize()` are the save section this row wants — **no shell code registers them**, so token ledgers, cooldown keys and quiet-hours state reset on every launch. Doc 13 §2.4/2.5 is the platform half. |

~~**And the one nobody has noticed:**~~ **Closed 2026-08-19.** `UIRoot.capture_ui_state()`
/ `restore_ui_state()` implement doc 12 §3.2's `ui` block — overlay choice,
settings, and the onboarding block — and the shell now wires both ends:
`main.gd:683` assigns `save_service.ui_provider = root.capture_ui_state`, and
`main.gd:685` / `main.gd:1013` apply `save_service.last_loaded_ui` once the UI
exists. The section rides the envelope beside `city`
(`tests/test_save_service.gd::test_ui_section_rides_the_envelope`) and survives
the format change (`tests/test_save_migration.gd::test_the_ui_section_survives_the_format_change`),
so a finished tutorial stays finished across a restart. **D-3 closed.**

## 9. Doc 09 — Map, land, starter city

| § | Subject | Grade | Pointer / gap |
|---|---|---|---|
| 2.1 | Coordinates & extents | SHIPPED | `TileGrid`, 112² tiles |
| 2.2 | Land block schema | SHIPPED | `LandBlock`; `test_world_map.gd` |
| 2.3 | Ownership & development FSM | SHIPPED | `DevelopmentController`; `test_development.gd` |
| 2.4 | Purchase pricing inputs | SHIPPED | `CitySim.land_price_inputs` |
| 2.5 | Adjacency purchase rule | SHIPPED | `WorldMap.purchase_allowed` |
| 2.6 | Districts & city_stability | SHIPPED | `DistrictRegistry`; `test_districts.gd` |
| 2.7 | Elevation | SHIPPED | `LandBlock.elevation_m` |
| 2.8 | The 7×7 world | SHIPPED | `data/world.json` |
| 2.9 | The Starter City | SHIPPED | `StarterCityLoader`; `test_starter_city.gd` |
| 2.10 | Population, occupancy, happiness | SHIPPED | `PopulationSystem`, `HappinessModel`; `test_population.gd` |
| 2.11 | City level & progression | SHIPPED (but see D-7) | `ProgressionSystem` works; the soak's city sat at **level 0 for 12 game-days** and refused 376 upgrades with `E_CITY_LEVEL`. See **D-7**. |
| 2.12 | Lifetime stats | SHIPPED | `StatsRecorder` |
| 2.13 | Benchmark-city fixture | **SHIPPED 2026-08-19** | `tools/gen_bench_city.py` → `tests/fixtures/bench_city.json`, 1,500 buildings. The matrix is measured and two budgets were broken by it — **D-14** (draw calls, **fixed**: Z2 352 → 219 with UI against 320), **D-15** (sim step, open). See **D-8** and doc 11 §2.13's as-shipped table. |

## 10. Doc 10 — Roads and traffic

| § | Subject | Grade | Pointer / gap |
|---|---|---|---|
| 2.1 | Units & calibration | SHIPPED | `RoadTunables` |
| 2.2 | Road tiles | SHIPPED | `TileGrid.FLAG_ROAD` |
| 2.3 | Road classes | SHIPPED | `data/roads.json` |
| 2.4 | Graph build | SHIPPED | `RoadGraph`; `test_roads_graph.gd` |
| 2.5 | Incremental rebuild | SHIPPED | `RoadNetwork.edit_tile` + pending-edit queue |
| 2.6 | Cost function | SHIPPED | `RoadCosts`; `test_roads_costs.gd` |
| 2.7 | A* routing | SHIPPED | `RoutePlanner` |
| 2.8 | Closures | SHIPPED | flood closures fired 92× in the soak |
| 2.9 | Reachability & components | SHIPPED | `RoadGraph` |
| 2.10 | Congestion model | SHIPPED | `CongestionModel`; `test_roads_congestion.gd` |
| 2.11 | Traffic accidents (doc 06's) | SHIPPED | routed through `IncidentCatalog` |
| 2.12 | Road condition & damage | SHIPPED | `RoadNetwork._condition` + weather wear |
| 2.13 | **Build, upgrade, demolish** | **PARTIAL** | `RoadNetwork.edit_tile()` is the primitive; there is **no `CitySim.cmd_*` road verb and no road card**. Roads are stamped at block development and are otherwise immutable. See **D-5**. |
| 2.14 | Routing performance budget | SHIPPED | `test_roads_graph.gd` bounds the rebuild |
| 2.15 | Cosmetic civilian traffic | **PARTIAL** | `TrafficFeed` ships and drives `VehicleView`; the traffic **overlay** is a per-edge MultiMesh built from `TrafficSnapshot.visible_edges` rather than the polyline doc 10 §2.15 describes. Cosmetic-only difference, called out because the overseer asked. |

## 11. Doc 11 — Rendering and performance

| § | Subject | Grade | Pointer / gap |
|---|---|---|---|
| 2.1 | Scene architecture | SHIPPED | `game/main.gd` + `game/render/` |
| 2.1.2 | The street — asphalt, markings, kerbs, footways | SHIPPED (2026-08-20) | `RoadSurfaceView` + `road_surface.gdshader` / `sidewalk.gdshader`, off doc 10's `RoadGraph`; `test_road_surface.gd`. Two draw calls city-wide, zero added texture memory. |
| 2.2 | Chunk lifecycle & slots | SHIPPED | `CityView` chunk buckets with hysteresis |
| 2.3 | Sim → render data flow | SHIPPED | `main._on_sim_batch` → `RenderStateModel` |
| 2.4 | Global shader parameters | SHIPPED | `sc_overlay_mode`, `sc_wetness`, … |
| 2.5 | Camera & LOD bands | SHIPPED | `CameraState` + `CityView.update_chunk_tiers` |
| 2.6 | MultiMesh + per-instance data | SHIPPED | `test_render_state.gd` |
| 2.7 | THE BLACKOUT | SHIPPED | `BlockDarkChanged` → `StreetlightView`; `--blackout` screenshot arg |
| 2.8 | Sky, day/night, fog, glow | SHIPPED | `EnvironmentController` |
| 2.9 | Weather VFX | SHIPPED | `WeatherFX`; `test_weather_fx.gd` |
| 2.10 | Streetlights | SHIPPED | `StreetlightView`; `test_power_streetlights.gd` |
| 2.10.1 | Lamp placement + the cobra head | SHIPPED (2026-08-20) | `StreetlightPlacer` + `CobraHeadMesh`. Replaces the `(x + z) % 4` parity rule that stood every pole in the carriageway; fixes STREET-1, the ground pool uploaded under the road slab. |
| 2.11 | Overlay mechanism | SHIPPED | `RenderStateModel.set_overlay_channel` |
| 2.12 | Vehicles | SHIPPED | `VehicleView` + `VehicleMotion` |
| 2.13 | Budgets, device matrix, **adaptive governor** | **PARTIAL** | three quality presets exist and are switchable from Settings; there is **no fps-driven governor** — grep for `governor` returns nothing. And with no benchmark city (doc 09 §2.13) the device matrix cannot be measured. |
| 2.14 | Gray-box pipeline | SHIPPED | `tools/gen_graybox.gd` + `game/meshes/generated/manifest.json` |
| 2.15 | Audio | SHIPPED | `game/audio/`; `test_audio_model.gd` |
| 2.16 | LIVING CONSTRUCTION | **SHIPPED 2026-08-20** | `ConstructionRigMesh` + `construction_rig.gdshader` + `ConstructionActivity` + `ConstructionVehicleView`; `test_construction_living.gd` (3,835 asserts). Articulated plant and street-true deliveries for **+5 draw calls** and **0.46 ms** at 20 sites. Closes the "a site is a box that grows" gap left by the crane/hoarding pass. Renderer-local and hash-neutral — proved by an interleaved-lookup test, not by inspection. |

## 12. Doc 12 — UI/UX

| § | Subject | Grade | Pointer / gap |
|---|---|---|---|
| 2.1 | Units, breakpoints | SHIPPED | `UIRoot.breakpoint_for`; `test_ui_scaffold.gd` |
| 2.2 | Screen map | **PARTIAL** | S0–S9, S11–S13 ship (**S4 landed Wave 6** — `PanelLayer/LandPanel`; **S0 landed Wave 7** — `TitleLayer/TitleScreen`, between `SheetLayer` and `ModalLayer`, opened only by `UIRoot.present_title()`). S10 has no rows. |
| 2.3 | HUD layout | SHIPPED | `CityHUD`; `test_ui_topbar.gd` |
| 2.4 | Stat chips | SHIPPED | `HudModel`; `test_hud_model.gd` |
| 2.5 | Overlay system | SHIPPED (3 of the doc's modes) | power, water, traffic; `OverlayModel` lists and greys the rest |
| 2.6 | Incident drawer & dispatch UX | SHIPPED | `IncidentDrawer` + `UnitPickerSheet`; `test_ui_incidents.gd` |
| 2.7 | Build menu, placement, requirements | SHIPPED | `BuildSheet` + `BuildController` + `RequirementFormatter` |
| 2.8 | **Land purchase flow (S4)** | SHIPPED | `ui/land_panel.gd` + `ui/land_panel_model.gd`; entered by `BuildController.pick_at_ground()`; `tests/test_ui_land.gd` (26 tests) drives price, refusals, PURCHASE → DEVELOP and the six-phase list over a real `CitySim`. ~~One line in `game/main.gd` makes it reachable~~ — **landed 2026-08-19**: `main.gd:1348` calls `build_controller.pick_at_ground(ground)` and `sim_id_at_ground` is gone from the tap path (doc 12 Wave-6 D-21). S4 has its door. |
| 2.9 | Building panel (S5) | SHIPPED | `BuildingPanel`; upgrade checklist live. ~~Its four coverage tiles list police and fire, which nothing computes~~ — **closed 2026-08-19**: `CoverageIndex` computes both and `CityIncidentWorld.coverage_police/coverage_fire` publish them (doc 02 §2.4/§2.9). What the tiles still cannot show is a *consequence*, because §2.9's `E_FIRE_COVERAGE` / `E_POLICE_COVERAGE` upgrade gates are not implemented. |
| 2.10 | City dashboard (S8) | SHIPPED | `CityDashboard`; `test_ui_dashboard.gd` |
| 2.11 | Pause & speed | SHIPPED | HUD rail + `PauseMenu` |
| 2.12 | WHILE YOU WERE AWAY (S11) | SHIPPED | `AwayReportSheet`; `test_ui_away.gd` |
| 2.13 | Settings (S9) & **notification settings (S10)** | PARTIAL | **sixteen** rows ship — the original eight plus §2.14's `haptics` and §2.13's seven auto-response policies (D-11 closed; defaults from doc 06's `data/dispatch.json`, values through `UIRoot.bind_dispatch_policy` → `cmd_set_dispatch_policy`). `data/ui.json.settings.rows` still has **no notification rows at all**, and the utility restoration *order* is still a list with no control |
| 2.14 | Haptics | SHIPPED | `ui/haptics.gd` — the one vibrator call site; seven cues off `data/ui.json.haptics_ms`, fired by `BuildSheet`, `LandPanel` and `UIRoot.feed_events`/`report_dispatch_result`. `reduce_motion` suppresses it (A8) without clearing the row. `tests/test_ui_haptics.gd` |
| 2.15 | Alerts, toasts, world markers | SHIPPED | `AlertsCenter`; `test_ui_alerts.gd` |
| 2.16 | Touch camera controls | SHIPPED | `TouchInput` → `GestureRecognizer` → `CameraState`; `test_gestures.gd` |
| 2.17 | **Onboarding, eleven steps** | SHIPPED | `OnboardingModel` + `OnboardingFlow`; now driven end to end by `tests/test_tutorial_flow.gd` and `tools/flow_test.gd`. Two structural risks found — **D-2** (open) and **D-3** (**closed 2026-08-19**: the `ui` block now persists, so a finished tutorial stays finished across a restart). |
| 2.18 | Accessibility checklist | SHIPPED (one regression) | `ui/ui_audit.gd` + `tools/ui_preview.gd --audit --strict`. Re-run for this audit at four boxes: **the sweep's zero-defect result no longer holds** — S13's event-log chip overlaps its siblings at 412×915, 880×400 and 1280×720. See **D-12**. |

## 13. Doc 13 — Android integration

> **Stale, and deliberately not re-graded here (2026-08-19).** Every row below is
> as measured at `6d8c2b1`, and an Android wave has landed since: `game/notifications/`
> (scheduler, router, budget, text, native sink), `game/notifications/permission_flow.gd`,
> `game/crash_sentinel.gd`, `POST_NOTIFICATIONS` in `tools/make_release.sh` and
> `tests/test_release_plumbing.gd`, and doc 13's own §11 recording the build,
> signing and permission verification it ran. Re-grading §2.4–§2.7, §2.11 and
> §2.12 needs the same read-the-code-then-find-the-test pass §0 specifies, on
> five rows, plus a device — **so it is filed rather than guessed at**, and the
> count table above still carries the old grades. Nothing in this table should be
> quoted as current until that pass happens.

| § | Subject | Grade | Pointer / gap |
|---|---|---|---|
| 2.0 | Toolchain | SHIPPED | `android/build/` gradle project, `tools/setup_android.sh` |
| 2.1 | Catch-up on resume, not background sim | SHIPPED | the architecture is right |
| 2.2 | Lifecycle state machine | SHIPPED | `AndroidLifecycle`; `test_android_native.gd` |
| 2.3 | Measuring elapsed real time | SHIPPED | wall/monotonic cross-check + `elapsedRealtime` ceiling |
| 2.4 | **Notification scheduling** | **ABSENT** | no scheduler, no `AlarmManager` bridge, no code path |
| 2.5 | **Notification platform** | **ABSENT** | no channels, no ids, no delivery |
| 2.6 | `SlacumNative` plugin | PARTIAL | ships `elapsedRealtime`, `boot_id`, thermal status, sustained performance — the doc's notification and permission surface is not in it |
| 2.7 | Permissions | **ABSENT** | `POST_NOTIFICATIONS` is neither declared nor requested |
| 2.8 | Battery, frame pacing, thermal | PARTIAL | thermal status is forwarded and audio mutes on focus loss; **nothing consumes the thermal ladder** to drop a preset or cap fps |
| 2.9 | Long catch-up without an ANR | PARTIAL | measured at 1.04 s for 43 coarse hours (soak §14.2). ~~The resume path is **D-1**, so the measurement is of the planner, not of the shipped call~~ — **D-1 closed 2026-08-19**, and the shell now makes the same `CatchUpPlanner.plan()` call the measurement was taken against. Still PARTIAL because the number is a workstation number: no on-device ANR run has happened (doc 13 §7 D-15). |
| 2.10 | Export pipeline | SHIPPED | `export_presets.cfg`, gradle v0.3.x |
| 2.11 | Crash reporting | **ABSENT** | nothing |
| 2.12 | Play Store readiness | **ABSENT** | `export_presets.cfg` has **no keystore, no signing config**; no store listing assets, no privacy policy, no data-safety form |

---

## 14. What the harnesses found

### 14.1 The tutorial flow test — the good news first

The eleven-step tutorial completes, on the real shell, unassisted:

```
flow_test — doc 12 §2.17 over game/main.tscn        (1.0x, 67.7 s wall)
  welcome            0.02 s    look_around        0.00 s    open_build   0.03 s
  place_house        0.02 s    unserved_wall      0.07 s    place_transformer 0.04 s
  blackout           5.94 s    open_drawer        0.02 s    dispatch     0.02 s
  relight           60.92 s    payoff             0.01 s
  steps advanced: 11/11   checks: 13   taps landed: 3/3   failed: 0
```

`blackout` is the step's authored 6 s `on_enter` delay; `relight` is the crew
driving and working. Everything a player does costs under a tenth of a second of
shell time.

Three of three ground taps landed on the intended tile through
`TouchInput.tapped` → `CameraState.screen_to_ground` → the ghost — the screen
projection and the inverse agree. The transformer is repaired, the block
relights, `ui.onboarding.finished` is set.

### 14.2 The QA soak — two real hours

Seed 20250819, city seed 1337, speeds 1/2/3, 2,880 chunks, 286.9 game-hours
(≈12 game-days) including two save/load cycles and an app pause/resume.

| Measurement | Result | Reading |
|---|---|---|
| Script errors | 0 | clean stderr for the whole run |
| ObjectDB, raw slope | +1.65 objects / game-hour | two step jumps, not a drip |
| ObjectDB, **steady slope** | **−0.04 objects / game-hour** | **no in-run leak** |
| Objects retained per save/load | **199, both times** | a replaced `CitySim` is never reclaimed — **D-9** |
| Step cost | mean 1,619 µs/tick, p95 1,748, max 2,025 | ~6.5 ms of sim per real second at 1× |
| Step-cost drift | first decile 1,591 → last decile 1,638 = **1.03×** | flat across 287 game-hours |
| Event bus | 408,979 events, **0 residual after every drain** | clean |
| Bus composition | `vehicle_state` ×326,745 = **80 %** of all traffic | **D-10** |
| Save/load identity | 2/2 hash-identical, 2/2 advance-identical | the constitution §5 guarantee holds mid-session |
| Resume | 45 min away → 10,800 ticks (43 coarse hours) in **1.04 s** | no ANR risk |
| Treasury | $25,334 → $678, min −$14,601 | inside envelope; austerity engaged |
| Happiness / stability | min 66.9 / 0.947 | inside envelope |
| Incidents | **2 created in 287 game-hours** | **D-6** |
| City level | 0 → 0; 376 upgrades refused `E_CITY_LEVEL` | **D-7** |

The first two-hour run also found a defect in *the harness*: an unguarded random
demolisher razed all 34 buildings by the halfway mark, so the second half
measured an empty map. The harness now protects stations and holds a floor of 24
buildings, and raises tax when overdrawn — the minimum judgement a person has.
Recorded because it is the reason the numbers above are trustworthy and the
first run's were not.

### 14.3 The UI audit, re-run

`tools/ui_preview.gd --screen=all --audit --strict` was re-run at four device
boxes as part of this audit rather than trusted from the Wave-4 report:

| Box | Result |
|---|---|
| 360×800 | clean |
| 412×915 | **2 states with `overlapping_targets`**, exit 1 |
| 880×400 | **3 states with `overlapping_targets`**, exit 1 |
| 1280×720 (the project's own viewport) | **3 states**, 24 clean, exit 1 |

Every finding is the same control. See **D-12**.

### 14.4 Screenshots judged

Four shots off `game/main.tscn` and `tools/onboarding_preview.tscn`, at the
default 1280×720 viewport.

* **First boot, welcome card.** The city reads at 06:01 — the darkest minute of
  the founding day. Streetlights are the only light; one apartment block is
  legible and the rest of the frame is near-black, under copy that says "This is
  your city. It runs whether you watch it or not." The textures and the lighting
  are not at fault (the same frame at 13:01 is excellent — brick, window frames,
  shingle, strong shadows); the *clock* is. Doc 09 §2.9 sets the founding time,
  and the tutorial's opening shot is the one frame in the game most worth
  spending daylight on. Not filed as a defect because it is a design call, but
  it is the first impression the game currently makes.
* **Daylight city, 13:01.** Flagship-bar material: the brick and shingle read at
  this zoom, the shadow contact is clean, streetlight poles cast properly.
* **Coach step 9 (`dispatch`), blackout in progress.** The dark block, the lit
  streetlights and the construction fence around the failed transformer read
  exactly as doc 11 §2.7 wants. The bubble is legible over the dark scene.
  One observation: the step's target is the drawer's `Panel`, so if the player
  closes the drawer the cutout resolves to nothing and the coach mark loses its
  highlight with no `autohelp` to recover it — a second face of **D-2**.
* **All three shots** show the clipped event-log chip at the right edge that
  §14.3 measures.

### 14.5 Defect list

Filed, not fixed — these live in files this branch does not own.

**Renumbering, 2026-08-19:** two waves filed a `D-14`/`D-15` pair each and the ids
collided. The **performance** pair (draw calls, sim step cost) keeps **D-14/D-15**;
the **generator** pair (`water_main_break` and `traffic_accident` having no
candidate source, both fixed in Wave 7) becomes **D-17/D-18**, in that order. Every
cross-reference in `docs/` and in code comments was moved with them. Doc 12's own
`D-14…D-18` delta table and doc 13 §7's `D-01…D-16` device matrix are separate
id spaces and are untouched.

| # | Severity | Defect |
|---|---|---|
| **D-1** | ~~High~~ **FIXED 2026-08-19 (Wave 7)** | **Closed:** `main.gd._on_app_resumed` now calls `CatchUpPlanner.plan(elapsed_ms, residual_game_ms, tick_index)` and walks its segments (`advance_coarse_hours` for `coarse`, `scheduler.advance_fine_n` otherwise), then writes back `new_residual_game_ms` — so every segment lands hour-aligned, and the 12-hour cap, the two-minute grace and the residual carry all apply on device. `tests/test_qa_soak.gd::test_planned_resume_advances_a_live_city_from_any_tick` drives the same call from offsets 0, 1, 137 and 239. Original filing: ~~`game/main.gd:875` resumes with `sim.advance_coarse_hours(int(elapsed/60))`. `TickScheduler.advance_coarse_n` asserts an hour-aligned `tick_index`; a resume from any of the other 239 tick offsets **trips the assertion in a debug build** and, in a release build where `assert` is stripped, fires hourly cadences off-boundary — the exact thing doc 01 §2.4 exists to prevent. It also skips the two-minute grace, the 12-hour cap and the residual carry. `CatchUpPlanner.plan()` already does all four and is called by nothing.~~ |
| **D-2** | **High** | Tutorial step 9 (`dispatch`) can become unsatisfiable. The auto-dispatcher takes the scripted transformer job **within the first game-minute** and resolves it at **+62 game-minutes** — 62 real seconds at 1×. A player who takes longer than that to open the drawer and tap ASSIGN finds the incident terminal, every `cmd_dispatch_unit` refused `E_UNKNOWN_INCIDENT`, and the step has no `autohelp` and no `any_of` fallback. The flow then only ends via *Skip tutorial*. Measured by `tests/test_tutorial_flow.gd::test_scripted_incident_leaves_a_usable_dispatch_window`. Cheapest fix: an `any_of` on step 9 that also accepts `sim_event incident_resolved`. |
| **D-3** | ~~High~~ **FIXED 2026-08-19 (Wave 7)** | **Closed, and it cost the two lines this row predicted.** `SaveService` grew a `ui_provider: Callable` and a `last_loaded_ui: Dictionary`; `main.gd:683` assigns `save_service.ui_provider = root.capture_ui_state`, and `main.gd:685` / `main.gd:1013` apply `last_loaded_ui` once the UI exists (a boot restore happens before there is a UI to restore into, which is why the value is held rather than pushed). The `ui` section rides the envelope beside `city` and survives the format-1 migration: `tests/test_save_service.gd::test_ui_section_rides_the_envelope`, `tests/test_save_migration.gd::test_the_ui_section_survives_the_format_change`. Original filing: ~~`UIRoot.capture_ui_state()` / `restore_ui_state()` are complete and tested and **called by nothing outside `tests/`**. `SaveService` persists only `sim.canonical_capture()`. Consequence: the tutorial's finished flag, the settings and the overlay choice **do not survive an app restart** — a returning player is shown the tutorial again, contradicting doc 12 §2.17's "never shows again once done".~~ |
| **D-4** | **High** | Doc 05's ten `WaterSystem.cmd_*` are not re-exported by `CitySim`, so no build card can exist. The water simulation is fully built and entirely unplayable. |
| **D-5** | ~~High~~ **Closed (Wave 5A + 6)** | Two more verb surfaces with no player: **roads** (closed Wave 5A) and **land** (closed Wave 6 — S4 ships as `ui/land_panel.gd`, entered by `BuildController.pick_at_ground`; `cmd_buy_block` is called with `auto_develop = false` so doc 12 §2.8's PURCHASE → DEVELOP is two taps, as written). The `game/main.gd` `_handle_tap → pick_at_ground` routing landed in the Wave-6 integration. |
| **D-6** | ~~Medium~~ **CLOSED** (Wave 6) | Incident pressure at starter-city scale is ~1 per 6 game-days (2 in 287 game-hours). Consistent with doc 02's ignition rates, but it means the drawer, the picker, the fleet and doc 06's whole escalation ladder are almost never seen. Either the rates want a floor at small city sizes, or the Director wants a "something must happen" pacing rule. — **Answered by the first of those: `data/incidents.json` `ambient_floor`, a per-channel `max()`, no `generator_base_rates` row moved. 1.88 → 3.04 ambient incidents/game-week, measured over 336 game-days on each side of the boolean. Doc 92 §18; gate 19.** The true rate was 1.88/week, not the 0.5/week this row reads — 287 game-hours is a 12-game-day sample of a 0.27/day process, so part of the number above is Poisson noise. The finding survives the correction; the measurement did not. |
| **D-7** | ~~Medium~~ **CLOSED** (Wave 6) | The soak's city never left **city level 0** in 12 game-days, so every one of 376 upgrade attempts was refused `E_CITY_LEVEL`. Doc 09 §2.11's thresholds are not reachable by a player who is not optimising, which locks out doc 02 §2.10–2.11 entirely. — **Worse than this row knew: `balanced` ended FIFTY game-days at level 2, and four of the six rungs were unreachable by anything the game can do. Ladder retuned onto doc 92's measured curves and moved into `data/progression.json`: level 1 on game-day 2, level 2 on 11, level 3 on 23. Doc 92 §19; gate 20.** |
| **D-8** | ~~Medium~~ **FIXED 2026-08-19** | ~~No benchmark city fixture~~ `tools/gen_bench_city.py` ships and emits `tests/fixtures/bench_city.json` (1,500 buildings, 6×6 developed core, 3,132 road tiles), byte-identically on a re-run. Consumed by `tools/profile_sim.gd --city=…`, the new `tools/profile_frame.gd`, and `tests/test_bench_city.gd` (doc 11 tests 19 and 26, doc 09 test 40). **The matrix is now measured and it does not pass**: at Z2 the Balanced draw-call budget of 320 is exceeded (352 with UI) because a real mixed block carries ~16 `archetype:level` buckets, not §2.13's assumed ~6 — filed as **D-14**. The sim side is worse: 22.0 ms per fine tick and 259 ms per coarse step on this city — filed as **D-15**. Numbers in doc 11 §2.13's as-shipped table. |
| **D-9** | Medium | Every `CitySim` ever constructed is retained forever — **199 objects per reload measured in-run, 208 per boot measured in isolation** (boot six, release five, the count never falls). Cause: `CitySim._register_systems()` registers twelve phase adapters that each hold a strong `sim: CitySim`, and `sim` holds the scheduler — a reference cycle, and `sim/` is RefCounted-only with no cycle collector. Harmless in the shipped shell (one sim, loads restore in place) and the reason every tool and test run leaks. It becomes a real leak the moment a "New game" or "load into a fresh sim" path appears. Fix: a `CitySim.dispose()` that clears the scheduler's registry, or `WeakRef` in the adapters. |
| **D-10** | ~~Low~~ **FIXED 2026-08-19** | ~~`vehicle_state` is 80 % of all bus traffic~~ The per-vehicle event is gone. `sim/roads/traffic_feed.gd` publishes one packed `traffic_snapshot` per tick (five `Packed*Array` columns, format in `sim/roads/traffic_snapshot.gd`); `vehicle_spawned`/`vehicle_despawned` stay individual. Re-measured on the soak: **55,675 → 18,221 events, 3.05×**, with the same 44,153 poses carried in 6,699 events instead of 44,153 dictionaries. Cadence unchanged at 4 Hz (doc 11 §2.12's Hermite blend depends on it). Save identity proved unchanged by `profile_sim --hash-only --baseline` on both cities. |
| **D-11** | ~~Low~~ **Closed (Wave 6)** | `DispatchPolicy` now has seven S9 rows (`policy: "dispatch"` in `data/ui.json.settings.rows`), defaulting from doc 06's own `data/dispatch.json.policy_defaults` and writing through `cmd_set_dispatch_policy`. The **city's** policy seeds the rows on bind and beats a restored `ui.settings` copy, because the policy lives in the city's save and not the UI's. |
| **D-12** | **High** | **The Wave-4 "zero defects across five device boxes" result has regressed.** Re-running `tools/ui_preview.gd --screen=all --audit --strict` finds `overlapping_targets` on `PanelLayer/EventLog/Chip` at **412×915** (2 states), **880×400** (3 states) and **1280×720** (3 states) — the alerts list, the incident drawer's rows and the building panel's `Fix this →` all put a tap target over it. Exit code 1 at every box. Root cause is exact and the fix is already written elsewhere: `ui/alerts_center.gd:221` polls `_chip.visible = not UIWidgets.any_sibling_open(self)` in `_process` — the comment above it says it was added for *this* defect — and `ui/event_log.gd` has no `_process` and never stands its chip down. S13 landed in the same wave as the sweep and did not inherit the fix. |
| **D-14** | ~~High~~ **FIXED 2026-08-19 (MEDIUM half); NEAR half open, Low** | ~~Doc 11 §2.13's per-chunk draw-call model is optimistic by ~1.7× on a mixed city, and the Balanced budget is exceeded at Z2.~~ Was: **352 draw calls with UI against a 320 budget**, from **591 MultiMesh bucket nodes across 36 chunks — 16.4 per chunk**, where §2.13 assumes 8 NEAR / 6 MEDIUM, because `CityView` allocated one bucket per `(chunk, archetype, level)` and a real block holds five archetypes at four levels. **Now: Z2 measures 194 calls, 219 with UI, against 320 — 31.6% headroom.** MEDIUM draws one MultiMesh per `(chunk, ARCHETYPE)` over an `ArrayMesh` of the levels that chunk holds, each vertex tagged with its level in the free `COLOR.a` channel and each instance carrying its level in the packed `.b` at stride 448 — `448 = 16·28` with `28 ≡ 0 (mod 7)`, so §2.6's `variant` and `stage` decoders do not move and only `overlay_of`'s `clamp` became a `mod` (an exact identity on 0..447). The 16 MEDIUM chunks now cost **5.94 building calls each against §2.13's assumed 6**: the model was never wrong, the renderer was, and nothing in the derivation had to be retuned. Doc 11 §2.6 (bucketing rule + the A/B that keeps MEDIUM on LOD0), §2.13 (as-shipped table), §7.2 test 19c (20 tests, `tests/test_render_merge.gd`). Verified pixel-wise against the un-merged renderer: **Z0 and Z1 bit-identical** (0 of 921,600 pixels), Z2 differing on 0.63% of pixels by at most 18/255 — the deliberate `near_flicker = 0` and nothing else — and the blackout and POWER-overlay ceremonies read identically. The starter city is unchanged in every column, because it has nothing to merge. **Residual, filed as D-16:** NEAR still allocates per level and still measures 16.4/chunk against the assumed 8. |
| **D-16** | Low | **The NEAR half of D-14 — a derivation that fails against a measurement that passes.** `CityView` still allocates one MultiMesh per `(chunk, archetype, level)` for NEAR chunks: **16.4 per chunk measured, against §2.13's assumed 8**. Re-run §2.13's Z1 worst case (6 NEAR chunks, the Balanced `near_chunk_max`) with the measured number and it lands at **366 against 320** — `6 × 16.4 × 2 splits = 197` of that is the shadow pass alone, because §2.13 costs every NEAR bucket once per split. But the bench city at Z1 **measures 136 with UI**, because the frustum at `D = 86.9` never actually holds six full dense chunks. Filed Low for exactly that reason, and unlike D-14 (where derivation and measurement failed together) there is nothing here to fix today. The fix is a switch, not a design: the LOD0 level atlas that closes MEDIUM is pixel-exact and already shipping, so extending it to NEAR is `medium_merge_enabled`'s twin plus a `near_flicker = 1` material. Take it the first time a **device** measurement puts a close-zoom pose near the budget, or the first time a pose is found that really does hold six dense NEAR chunks. Doc 11 §2.13, "What is still open". |
| **D-15** | ~~High~~ **COARSE PATH FIXED (Wave 7) · SUB-STEP GUARD TAKEN (Wave 8) · CADENCE PASS TAKEN (Wave 9) · NARROWED (Medium): the fine tick is at 18.0 ms against an 8 ms target and the router put the bench-city COARSE path back over doc 01's 2 s catch-up budget** | ~~The sim step does not scale to the benchmark city.~~ Originally: **22.00 ms per fine tick** and **259.18 ms per coarse step** on `tests/fixtures/bench_city.json`, with the 12 h catch-up at 3.11 s against doc 01's 2 s budget. **The Wave-7 scaling pass closed the coarse half** — interleaved A/B, same session, same workstation, baseline stashed and restored between runs: coarse step **238.6 → 132.8 ms (−44 %)**, **12 h catch-up 2.86 → 1.59 s, inside the 2 s budget**, fine tick 21.80 → 17.49 ms (−20 %). Starter city, same pass: coarse 8.10 → 6.28 ms, fine 1.590 → 1.511 ms. No rule, cadence or tunable moved: `tools/profile_sim.gd --baseline` reports identical `state_hash` on both paths on both cities, and the 26 balance gates are untouched. The wins were all the same shape — *stop re-deriving per building what is constant across the roster*: a cached ascending roster order (`CitySim.roster_ids`), one roster pass for all twelve district service ratios instead of twelve, a columnar fire-candidate seam with the candidate table built only on sub-steps that ignite, memoised building→district, an array-row avenue-gate scan, and `PowerGrid.is_powered` no longer allocating an empty Dictionary per call. Per-phase before/after in doc 11 §2.13's Wave-7 table. **What is left is the fine tick**, and it is no longer a micro-optimization problem: `water` 4.4 ms, `power` 3.8 and `roads` 2.3 are O(buildings) on EVERY SimTick, and `roads_congestion` is a per-game-minute pass the amortized column hides (un-amortized: ordinary tick ≈ 11 ms, minute tick ≈ 38 ms, settled-hour tick ≈ 73 ms). Three costed cadence proposals, none of them taken because each moves a number the gates are written against: **(1) measured, not estimated** — drop the fire-spread breakpoint from `IncidentSystem._next_discontinuity_h()` (line 176) when no `structure_fire` is live. It fires on a 1/12-game-hour grid whether or not anything is burning and is what sets the sub-step count. With the guard in place: **15.7 → 5.1 sub-steps per coarse hour, `incidents` 54.8 → 28.0 ms, coarse step 133.8 → 104.8 ms, 12 h catch-up 1.61 → 1.26 s**; the fine tick does not move (it takes one sub-step per game-minute either way). Both state hashes change, so it needs a save-version bump and a balance-matrix re-run; **(2)** halve the `roads_congestion` cadence, or split its three passes (`congestion.recompute` 4.2 ms, `TrafficSnapshot.rebuild` 4.2, `TrafficFeed.rebalance` 7.1 per game-minute) across the four ticks of the minute so no single frame carries all of it; **(3)** accumulate the per-building power and water service ledgers per game-minute at dt = 1 min instead of per tick at dt = 15 s — the accumulators are already dt-exact, so the hour they settle is unchanged in value but not in float rounding. All three change RNG consumption or float association and therefore break save identity against existing saves. **PROPOSAL 1 IS TAKEN — Wave 8, 2026-08-20.** `IncidentSystem._next_discontinuity_h()` skips the fire-spread breakpoint when the live roster holds no `structure_fire`. Interleaved A/B, three rounds, alternating arms within each round, against a pristine `git show HEAD:` copy rather than a stash: **integrator sub-steps per coarse hour 12.00 → 1.25 on the starter city and 20.67 → 8.75 on the bench city**; **coarse step −25.6 % on the starter (8.58 → 6.28, 8.56 → 6.32, 8.23 → 6.26 ms — every round) and −20.9 % on the bench (159.7 → 127.7, 153.0 → 119.7, 154.1 → 122.0 ms)**; **`incidents` 4.00 → 1.60 ms on the starter and 78.8 → 47.1 ms on the bench**; **12 h catch-up 1.836 → 1.437 s on the bench city, inside doc 01's 2 s budget with 28 % to spare**; **fine tick flat** (+1.4 % starter, +0.5 % bench, both inside this session's noise) — exactly as predicted, because a fine tick already takes at most one sub-step. The predicted figures in this row were 15.7 → 5.1 sub-steps and 133.8 → 104.8 ms: the direction and the mechanism are confirmed, the magnitudes are not comparable because the Wave-8 bench city runs a different incident mix (20.67 sub-steps/hour at HEAD, not 15.7). `max_coarse_hours` is unchanged at 312 — `tests/test_perf_governor.gd` measures 6.21 ms/step against 6.25 before, and both floor to the same cap. **Proposals 2 and 3 are untouched and the fine path with them**, and it now has a second consumer waiting on it: doc 06 §2.10's router seam is complete but its wiring is HELD, because a ~5 ms A\* quote cannot live inside a per-sub-step assignment loop and doc 10's own test already reports *"median P0 expansions 1154 vs trigger 800 → hierarchical routing REQUIRED"*. Full per-phase tables and the router's own measurement in doc 11 §2.13's Wave-8 subsections. **PROPOSALS 2 AND 3 ARE TAKEN — Wave 9, 2026-08-20, and the row NARROWS rather than closes.** `roads_congestion` declares `EVERY_TICK` and picks its pass from `tick_index % 4` (congestion + the `c_day` sample on tick 0, `TrafficSnapshot.rebuild` on tick 1, `TrafficFeed.rebalance` on tick 2); the power and water per-building service ledgers bank once per game-minute at `dt = 1 min` instead of four times at `dt = 15 s`, with the un-banked remainder persisted so save -> load -> advance stays bit-identical. Interleaved A/B, same session, `git stash` for the before arm, on a workstation carrying three other agents' suites: **bench fine tick 19.145 -> 18.011 ms (-5.9 %)**, of which **`water` 4.100 -> 2.451 (-40.2 %)** and **`power` 3.744 -> 3.210 (-14.3 %)**; starter fine tick 1.842 -> 1.817 ms. **Proposal 2 moves no amortized number and was never going to** - the three passes still run once per game-minute each, and what changed is that the worst SimTick of the four now carries one of them instead of all three. The profiler reports a mean, so its only visible signature is `calls/step` 0.25 -> 1.00; the frame-pacing win it was asked for is real and unmeasured by this instrument. **Where the fine tick lands: 18.0 ms against this row's 8 ms target.** What is left is `roads_congestion` 5.4 (a genuine O(edges) sweep once a game-minute), `power` 3.2, `incidents` 2.9, `water` 2.5, `roads` 2.3 - and none of those is a *cadence* mistake any more, so the row narrows to *"the fine tick needs fewer edges and buildings touched per sweep, or GDExtension"*, which is doc 10 §9.3 C-3's ladder rather than a cadence proposal. **And the branch that took them also wired doc 06's router, which moved the COARSE half back out of budget**: bench coarse step 126.41 -> 189.96 ms and 12 h catch-up 1.517 -> 2.280 s against doc 01's 2 s, because the incident phase more than doubles (real A\* quotes in the assignment loop, and 66 % more integrator sub-steps - street-true arrival times are all distinct where Chebyshev ones collided on a grid). **On the REFERENCE city, which is what doc 01 §2.10's `max_coarse_hours` is derived from, the coarse step is flat (6.353 -> 6.690 ms).** The derived cap sits ON its own boundary and this branch measured both sides of it in one session - `tests/test_milestone1.gd` reads 6.42 ms -> **288** on a loaded run and 6.07 ms -> **312** on the full-suite run twenty minutes later, where Wave 8 read 6.21 -> 312. The rule steps at exactly 6.410 ms, so a 5.5 % spread straddles it. The test asserts only the C-21 floor of 72, so nothing breaks on either side; doc 01 §2.10 carries the arithmetic. Filed as the narrowed half of this row; the cheapest lever is quantising arrival times onto the SimTick grid, which is doc 06's call. Full tables in doc 11 §2.13's Wave-9 subsection; rulings in report 98 RR-26/27/28. |
| **D-13** | Low | `tests/test_ui_audit.gd::BOXES` covers 360×800, 412×915, 794×924 and 880×400 — **not the project's own `window/size/viewport` of 1280×720**, which is what every screenshot harness and every desktop run renders at. Adding it would have caught D-12 in the suite. |
| **D-17** *(filed as D-14; renumbered 2026-08-19)* | ~~Medium~~ **FIXED 2026-08-19 (Wave 7)** | ~~Doc 06's `water_main_break` generator has no candidate source.~~ `CityIncidentWorld.water_mains()` now joins doc 05's `WaterSystem.mains()` into doc 06's row (`segment_id` → `id`, plus the additive `tile` / `zone_key` columns doc 05 was already holding), filtered to `ok` segments. **C-46 is closed in the same place**: the adapter that supplies the candidates sets `external_main_breaks`, so doc 05's standalone fallback stands down instead of both sides rolling — and the load path latches it, because who rolls is a fact about the program and not about the city. Measured, 12 seeds × 28 game-days of `do_nothing`: **0.00 → 0.60 water_main_break/game-week**, 0 failed. `tests/test_incident_world_join.gd`, `tests/test_water_failures.gd`. |
| **D-18** *(filed as D-15; renumbered 2026-08-19)* | ~~Medium~~ **FIXED 2026-08-19 (Wave 7)** | ~~Doc 06's `traffic_accident` generator has no candidate source.~~ `RoadNetwork.intersections()` publishes every degree-≥3 junction with doc 06 §2.6(e)'s five inputs — both per-node scalars the MAX over incident edges, which is doc 06's own "the collision happens on the worst approach" — and `CityIncidentWorld.road_intersections()` joins it. The write half landed too: `road_close_edge` / `road_set_edge_speed_mult` resolve doc 06's TILE to doc 10's worst EDGE and map the incident onto doc 10's closure-cause table, so the T2/T3/T4 consequence rows and the `on_fail` closure fire for the first time. Measured: **0.00 → 3.60 traffic_accident/game-week** at starter scale (389 junctions), which is *below* doc 06 §2.6(e)'s own worked intent of 0.687/game-day — **and it takes the ambient total past doc 92 §18's ruled 2–4/game-week band, which no floor can subtract from. See gate 19's Wave-7 note and the delivery report's open question 1.** |

---

## 15. Ranked Wave-6 recommendation

Ranked by *player-visible harm per hour of work*, not by size.

| # | Work | Why it is here | Fixes |
|---|---|---|---|
| ~~**1**~~ | ~~**Wire the resume path through `CatchUpPlanner`**~~ **DONE 2026-08-19 (Wave 7)** | `main.gd._on_app_resumed` plans the resume and walks the segments; every one lands hour-aligned, and the cap, the grace window and the residual carry apply on device | D-1 ✔ |
| ~~**2**~~ | ~~**Persist the `ui` block**~~ **DONE 2026-08-19 (Wave 7)** | `SaveService.ui_provider` / `last_loaded_ui`, wired at `main.gd:683` and applied at `main.gd:685` / `1013`; the finished tutorial stays finished across a restart | D-3 ✔ |
| **3** | **Give step 9 an `any_of` fallback** | a table row in `data/ui.json`, no code; today a slow player can wedge the tutorial permanently with no way out but Skip | D-2 |
| **4** | **Stand the event-log chip down when a sibling opens** | five lines copied from `ui/alerts_center.gd:221`; today it takes taps meant for the alerts list and the drawer at three of four device boxes. Add 1280×720 to `test_ui_audit.gd::BOXES` in the same commit | D-12, D-13 |
| **5** | ~~**Land purchase flow (S4) end to end**~~ **DONE (Wave 6)** | `ui/land_panel*.gd`, the `pick_at_ground` seam, four new refusal codes with copy, `tests/test_ui_land.gd`. Outstanding: one `game/main.gd` tap-handler line | D-5, and unblocks D-7 |
| **6** | **Water verbs through `CitySim` + build cards** | doc 05 is one of the largest subsystems in the game and is currently scenery | D-4 |
| **7** | **Road build/upgrade/demolish verbs** | same shape as (5); also the prerequisite for doc 10 §2.13 and for making congestion actionable | D-5 |
| **8** | **Android notifications (doc 13 §2.4/2.5/2.7 + doc 08 §2.13)** | the entire retention loop of a session-based mobile game. Needs `POST_NOTIFICATIONS`, a channel, an `AlarmManager` bridge in `SlacumNative`, S10's settings rows, and doc 01 §2.11's pre-scheduling to be hooked up | doc 13 §2.4/2.5/2.7, doc 08 §2.13, doc 12 §2.13 |
| **9** | **Police/fire coverage** (already in flight) | `req_police_coverage` / `req_fire_coverage` are authored, validated and read by nobody; the building panel already shows the tiles | doc 02 §2.4/2.9 |
| **10** | **Benchmark city fixture + a measured device matrix** | doc 11's budgets are unverified claims until a 1,500-building city exists. Pairs naturally with the adaptive governor and the thermal ladder, neither of which can be tuned without it | D-8, doc 11 §2.13, doc 13 §2.8 |
| ~~**11**~~ | ~~**Incident pacing pass**~~ — **DONE** (Wave 6, doc 92 §18) | `data/incidents.json` `ambient_floor`: a per-channel `max()` under doc 06 §2.6's generation, no `generator_base_rates` row moved. Measured A/B, 336 game-days each side, 12 seeds: **1.88 → 3.04 ambient incidents/game-week** at starter scale, 100 % resolved, 0 failed, 0 destroyed. It also found **D-17/D-18** (filed then as D-14/D-15). | D-6 |
| ~~**12**~~ | ~~**Progression pacing pass**~~ — **DONE** (Wave 6, doc 92 §19) | doc 09 §2.11's ladder retuned onto doc 92's measured curves and moved into `data/progression.json` (doc 09 §8.2's file, never previously written): `250/1000/4000/12000/30000` → **`200/700/1600/3600/8000`**. `balanced` now reaches level 1 on game-day **2**, level 2 on **11**, level 3 on **23** — where level 3 was previously unreachable in fifty. | D-7 |
| ~~**10**~~ | ~~Benchmark city fixture + a measured device matrix~~ **DONE 2026-08-19** | The fixture, both profilers, the adaptive governor and the thermal ladder all ship. The matrix is measured and **failed in two places** — the successor work was **D-14** (bucket merging, **done the same day**: Z2 352 → 219 with UI, doc 11 §2.6/§2.13) and **D-15** (sim step cost, still open) | D-8 ✔, doc 11 §2.13 ✔, doc 13 §2.8 ✔ |
| **11** | **Incident pacing pass** | a small-city floor or a Director pacing rule so the dispatch loop is part of the game rather than a rare event | D-6 |
| **12** | **Progression pacing pass** | city level 0 for 12 game-days locks out upgrades entirely; retune doc 09 §2.11's thresholds against doc 92's curves | D-7 |
| **13** | **`CitySim.dispose()`** | 210 objects per abandoned sim; cheap now, load-bearing the moment a New Game button exists | D-9 |
| ~~**14**~~ | ~~`vehicle_state` traffic diet~~ **DONE 2026-08-19** | One packed `traffic_snapshot` per tick; bus volume 3.05× smaller, measured on the soak, save identity unchanged | D-10 ✔ |
| **15** | **Release plumbing: signing, store assets, crash reporting** | none of it is hard, all of it is on the critical path to a build anyone outside this repo can install | doc 13 §2.11/2.12 |
| **16** | ~~**Haptics + dispatch-policy settings rows**~~ **DONE (Wave 6)** | `ui/haptics.gd` (one vibrator call site, `reduce_motion`-suppressed), seven `policy: "dispatch"` rows, plus the toast surface and the city-level unlock reveal that §2.13's progression payoff needed | doc 12 §2.14, §2.13, D-11 |

The first four are, together, well under a day's work, and they are the four
that make the game's first ten minutes, its second launch and its tap targets
correct. Everything from (5)–(7) is the same shape of work repeated: subsystems
that are fully simulated and completely untouchable.

*2026-08-19: (1) and (2) are done — the second launch is correct. (3) and (4)
are still open and are still the cheapest player-visible wins in this table.*
