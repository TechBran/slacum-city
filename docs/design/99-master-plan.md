# 99 — Master Plan

**Status:** Binding build plan. Reads on top of `00-constitution.md` (LOCKED) and `98-consistency-report.md` (rulings).
**Scope:** unified architecture, the complete `data/` inventory, the Phase 0 / Phase 1 task graph in half-day units, three verifiable milestones, and the risk register.
**Unit:** 1 half-day (hd) = one focused half-day of implementation **including its headless tests**. Constitution §12: nothing merges without tests.

---

## 1. Unified architecture — one page

### 1.1 The four layers (constitution §3)

```
data/   JSON balance tables. Every tunable number. Loaded and validated once at boot.
sim/    Pure RefCounted simulation. No Node, no Input, no OS, no wall clock, no global RNG.
        Time and RNG are injected. Runs headless, identically online and offline.
game/   Godot scene layer: 3D city, vehicles, weather VFX, camera node, Android shell.
        Reads sim via a per-tick event batch + queryable snapshot. Never mutates sim state.
ui/     HUD, overlays, panels, onboarding. Reads the same snapshots. Writes only commands.
```

Dependency direction is strictly downward: `ui/ → sim/`, `game/ → sim/`, both `→ data/`. `sim/` imports nothing above it. The Android platform surface lives in `game/android/` plus a Kotlin AAR under `android/plugins/` and reaches `sim/` only through injected `IClockSource` / `IFileSink` / `INotificationSink` (report C-04 — there is no fifth source layer).

### 1.2 The spine: one clock, one scheduler, 18 phases

`tick_index : int64` (15 game-seconds per tick, 60× compression, 1 real second = 1 game-minute) is the only clock. `TickScheduler` sorts every registered system by `(phase, system_id)` and runs exactly this order, fine (15 gs) or coarse (1 gh), with no runtime reordering:

```
P00 CLOCK · P01 COMMANDS · P02 TIMERS · P03 EVENTS · P04 WEATHER · P05 DEMAND
P06 POWER · P07 WATER · P08 ROADS · P09 VEHICLES · P10 WORK · P11 INCIDENTS
P12 CASCADE · P13 DISTRICTS · P14 ECONOMY · P15 POPULATION · P16 DIRECTOR · P17 REPORT
```

Three deliberate one-step lags, and only three: stability→crime (P13→P11), cascade hop rate (one hop per tick), Director→world (P16 schedules, never mutates). Every arrow in the signature cascade — *feeder trips → pump loses power → hydrant pressure falls → fire suppression weakens* — is a **forward** arrow in that list, so the whole chain resolves inside one tick with zero lag. That is the architectural reason the game's thesis is legible.

### 1.3 Data flow

```
ui/  --commands-->  CommandQueue --drained at P01--> sim/
sim/ --event batch + immutable snapshot at P17--> game/ (render) and ui/ (read)
```

Commands are validated by the sim and return `{ok, reason_code, payload}`; the UI never predicts success and never receives a display string — it receives a stable failure code and formats it (`RequirementFormatter`). The renderer interpolates between 4 Hz ticks and animates vehicles along real polylines *stretched to hit the sim's arrival minute*, never the reverse.

### 1.4 Determinism

Seven named RNG streams (`weather, incidents, crime, failures, director, traffic, misc`) with persisted seed + state. Same save + same elapsed real time ⇒ same outcome. Offline catch-up calls **the same systems in the same phase order** through `advance_coarse`, differing only by rate multipliers carried on `TimeContext` (`OfflinePolicy` bands) — never a second rules engine, never an `if is_catchup` branch in the rules.

### 1.5 World units

1 tile = 8 m. Land block = 16×16 tiles = 128 m. **Block == district member == render chunk == save RLE unit.** There is no second spatial concept anywhere in the codebase. World: 7×7 blocks, 3×3 developed core, 40 purchasable blocks.

### 1.6 The core loop, and which system owns each verb

*buy land* (09/03) → *develop* (09/02) → *build* (02/12) → *tax* (03) → *upgrade* (02/03/04/05) → *overload* (04/05) → *incident* (06/07) → *dispatch* (06/10) → *repair* (02/06/03) → *grow* (09).

---

## 2. `data/` inventory — every table, one owner

Constitution §2: **all** tunable numbers live here; no magic numbers in code. Ownership per report Ruling Zero. Every file carries `schema_version` and is validated at boot by `DataRegistry` (a load failure is fatal, never a silent default).

| File | Owner | Contents | Phase |
|---|---|---|---|
| `data/time.json` | 01 | clock, speeds, catch-up, 18 phases, day phases, 14 diurnal curves, modifier channels, event templates, timer/work kinds, budgets | 0 |
| `data/buildings.json` | 02 | 12 archetypes × 5 levels — **physical columns only** (footprint, pop, jobs, power kW, water, build time, decay, fire ignition + load, crime weight, coverage requirements, min city level, `water_facility.variant`) | 0 |
| `data/building_rules.json` | 02 | growth classes, coverage ladder, condition bands, fire constants, construction/refund rules, state modifiers, seed rows, rounding rules | 0 |
| `data/building_economy.json` | 03 (generated) | `build_cost_l1`, `class`, `base_tax_by_level`, `upgrade_cost_by_step`, `capital_value_by_level` — emitted by `tools/gen_building_economy.gd`, committed, diff-tested | 0 |
| `data/economy.json` | 03 | tax formula constants, nine expense lines, tariffs, land price terms, six development phases, offline taper, recovery ladder, presentation, pacing guardrails | 0 |
| `data/difficulty.json` | 03 | **every** difficulty knob — economic (03), pressure (07), escalation (06), offline (08) | 1 |
| `data/power.json` | 04 | component ladders, arrester/flood-wall upgrades, thermal, hazard, protection, weather couplings, shedding, redundancy, service hysteresis, repair, backup, black start, overlay, offline, perf | 0 |
| `data/water.json` | 05 | global coefficients, six node kinds × 5 levels, mains tiers, backup generators, process demand, failures, repair, effects, contamination, overlay, feature flags | 1 |
| `data/incidents.json` | 06 | six types, generators, escalation/resolution, declarative `on_tier_enter` / `on_fail` op lists, fire tables, rewards | 1 |
| `data/vehicles.json` | 06 | five MVP unit types, speeds, capabilities, resolve rates, station capacities, weather/road multipliers | 1 |
| `data/dispatch.json` | 06 | priority scoring weights, exposure, assignment budgets, policy defaults | 1 |
| `data/weather.json` | 07 | six states, transitions, seasons, 16 effect channels, storm cell, flood bands, forecast accuracy + confusion | 1 |
| `data/director.json` | 07 | threat budget, preparedness weights, severity, scheduling, ten fairness gates, event catalog, thunderstorm script | 1 |
| `data/persistence.json` | 08 | save/retention, offline bands, eight fairness invariants, event rings, report layout, notification runtime | 0 |
| `data/notifications.json` | 08 | four priority classes, event→class map, cooldowns, deep links | 1 |
| `data/world.json` | 09 | world extents, elevation, env-risk weights, land value, road access scores, flood, six development phases + crew mapping, terrain defaults, district rules, road template, starter targets | 0 |
| `data/starter_city.json` | 09 (generated) | 49 blocks, road template, water tiles, building manifest, power topology, water topology, districts, tag registry — emitted and validated by `tools/gen_starter_city.py` | 0 |
| `data/district_names.json` | 09 | name pool for auto-created districts | 0 |
| `data/roads.json` | 10 | two classes, four route classes, cost factors, node delays, congestion + ToD curves, weather table, closure causes, condition, build, routing budgets, civilian traffic, access quality | 1 |
| `data/render.json` | 11 | camera projection, LOD, streaming, emissive, blackout/relight envelopes, day/night keys, environment, weather VFX, streetlights, vehicles, overlay, three presets, autodetect, governor, `occupancy_hour_curve` | 1 |
| `data/building_shapes.json` | 11 | gray-box generator input: massing blocks, roof signatures, level markers, roof props | 1 |
| `data/ui.json` | 12 | layout, breakpoints, type scale, palettes + glyphs + dash patterns, overlay, camera interaction, gestures, placement, thresholds, in-app alert budgets, haptics | 1 |
| `data/onboarding.json` | 12 | 13-step table, global coach constants, per-step sim overrides, scripted incident | 1 |
| `data/strings.en.json` | 12 | all display copy (`ui_*`, `n_*_title`, `n_*_body`, failure remedies) | 1 |
| `data/android.json` | 13 | time bridge, lifecycle budgets, notification platform, permission flow, power/thermal rules, build constants, diagnostics | 1 |
| `data/notifications_text.json` | 13 | notification copy (referenced from `strings.en.json` convention) | 1 |
| `data/id_remap.json` | 08 | retired content id remapping — **Phase 3**, empty in MVP | — |

Tools that write into `data/`: `tools/gen_building_economy.gd`, `tools/gen_starter_city.py`, `tools/gen_bench_city.py`, `tools/gen_graybox.gd` (writes meshes, reads `building_shapes.json`).

---

## 3. Phase 0 — foundation (headless, no renderer)

**Definition of done:** `godot --headless --path "…" -s res://tests/run_tests.gd` is green, and the starter city runs 24 game-hours deterministically with power, taxes and buildings live.

Already in the repo: `sim/core/game_clock.gd`, `sim/core/rng_streams.gd`, `sim/core/event_bus.gd`, `tests/run_tests.gd` + 4 tests. P0-01…P0-04 extend these rather than replacing them.

| ID | Task | hd | Depends on |
|---|---|---|---|
| **P0-00** | **Apply report 98 Ruling Zero + the four constitution amendments; renumber §5 tables in docs 01/03/04/06/08/13** | 1 | — |
| P0-01 | `DataRegistry`: load + validate every `data/*.json` at boot, fail loud on schema mismatch; test-fixture loader | 2 | P0-00 |
| P0-02 | RNG streams: persistence of seed+state, per-stream draw accounting in debug builds | 1 | — |
| P0-03 | Event bus: typed event records, per-tick batch, `EventRing` (critical 64 / routine 448) | 2 | — |
| P0-04 | Command API: `CommandQueue`, `CommandResult{ok, reason_code, payload}`, stable failure-code enum (13 codes) | 1 | P0-03 |
| P0-05 | `GameClock` completion: calendar derivation (day/dow/season/day_type), `FOUNDING_OFFSET`, sub-tick residual | 1 | P0-01 |
| P0-06 | `DayCurveSet` + `ModifierStack`: 14 channels, keyframe validation, midpoint sampling, fine/coarse equivalence | 2 | P0-05, P0-01 |
| P0-07 | `TickScheduler`: registry, 18-phase sort, four cadences, `advance_fine_n` / `advance_coarse_n`, `TimeContext` | 2 | P0-06 |
| P0-08 | `TimerService` (min-heap) + `WorkService` (exact integer milli-unit accumulator with carry) | 2 | P0-07 |
| P0-09 | `ScheduledEventService` + `CatchUpPlanner` (grace, 12 h cap, head-align/coarse/mid-fine/tail) + backlog spill | 2 | P0-08 |
| P0-10 | `TileGrid` (112×112 flags + building ids) and `LandBlock` records; `block_of`, `elev_m`, buildability | 2 | P0-01 |
| P0-11 | `tools/gen_starter_city.py` + `data/starter_city.json` + the nine data-integrity validators | 3 | P0-10 |
| P0-12 | Land ownership, adjacency purchase rule, six-phase development state machine (integer crew-minutes) | 2 | P0-10, P0-08 |
| P0-13 | `DistrictRegistry`: membership, auto-assignment, fast/slow aggregates, the `stability` formula on [0,1] | 2 | P0-12 |
| P0-14 | Population core: occupancy/job-fill ramp, happiness, `city_level` thresholds, `population` + `progression` sections | 2 | P0-13 |
| P0-15 | `BuildingCatalog` + curve-family regenerator; **`k_dem` corrected per report C-13**; `data/buildings.json` | 2 | P0-01 |
| P0-16 | `Building` + `BuildingStateMachine` (7 states) + placement validation + footprint/tile arbitration | 3 | P0-15, P0-10 |
| P0-17 | `UpgradeGate`: 13 precondition checks with stable codes, headroom math, coverage provision (`c_station`) | 2 | P0-16, P0-13 |
| P0-18 | `ConstructionQueue` (`sim/construction/`): jobs, work units, crew binding stub, cancel/refund, `reorder` | 2 | P0-17, P0-08 |
| P0-19 | `CostCurves` + `tools/gen_building_economy.gd` + `data/building_economy.json` + the diff test | 2 | P0-15 |
| P0-20 | `Treasury`: int64 balance, millidollar carry, austerity/credit/deferred/relief ladder | 2 | P0-19 |
| P0-21 | `TaxAssessor` + `ExpenseLedger` + `EconomySystem.tick_hour` + foregone-revenue attribution | 3 | P0-20, P0-16, P0-14 |
| P0-22 | `LandMarket`: seven-term price formula, development phase costs, purchase/resale validation | 1 | P0-20, P0-12 |
| P0-23 | Power topology: components (SoA), parent/child index, tie registry, energization DFS, service attachment | 3 | P0-16, P0-10 |
| P0-24 | Power solve: Pass A aggregation, Pass B supply + feeder shedding, demand model against doc-01 channels | 3 | P0-23, P0-06 |
| P0-25 | Power Pass C: thermal integration, inverse-time relays, auto-reclose/lockout, condition wear | 2 | P0-24 |
| P0-26 | Power failures: hazard rolls on the `failures` stream, cascade tagging, tie auto-transfer, N-1 headroom, `block_dark` | 2 | P0-25, P0-02 |
| P0-27 | Save: envelope (SHA-256 + zstd), `SaveSection` contract, snapshot/encode/atomic-write/manifest commit | 3 | P0-07 … P0-26 |
| P0-28 | Checkpoint retention ladder, load candidate walk, 7-check gate, quarantine, structural validator + repair | 2 | P0-27 |
| P0-29 | Migration ladder (envelope + per-section `section_version`), one real worked migration + fixture test | 2 | P0-28 |
| P0-30 | **Coarse-step benchmark** `tests/perf/test_coarse_step_cost.gd`; set `max_coarse_hours` by the report C-21 rule | 1 | P0-27 |
| P0-31 | Determinism suite: phase-order stability, one-step-lag contract, speed independence, curve equivalence, RNG replay | 2 | P0-07 … P0-26 |
| P0-32 | **Milestone 1 harness**: load starter city, run 24 gh twice, assert byte-identical state hash + invariants | 1 | P0-31, P0-30 |

**Phase 0 total: 65 hd ≈ 33 working days.**

### Phase 0 dependency edges (critical path in bold)

```
P0-00 ─▶ P0-01 ─▶ P0-05 ─▶ P0-06 ─▶ **P0-07** ─▶ P0-08 ─▶ P0-09
                      │                  │
                      ├──▶ P0-10 ─▶ P0-11
                      │        └──▶ P0-12 ─▶ P0-13 ─▶ P0-14
                      └──▶ **P0-15** ─▶ **P0-16** ─▶ P0-17 ─▶ P0-18
                                   │            └──▶ **P0-23** ─▶ P0-24 ─▶ P0-25 ─▶ P0-26
                                   └──▶ P0-19 ─▶ P0-20 ─▶ **P0-21** ─▶ P0-22
P0-02 ─▶ P0-26        P0-03 ─▶ P0-04
(all sim sections) ─▶ **P0-27** ─▶ P0-28 ─▶ P0-29
                          └──▶ P0-30
(all) ─▶ P0-31 ─▶ **P0-32**  ⇒ MILESTONE 1
```

Hard sequencing notes: `P0-15` must not start before report C-13/C-14 are applied (the `k_dem` and condition-scale rulings change every row). `P0-11` must not start before C-11 (starter mix) and C-34 (water rescale). `P0-21` needs `P0-14` because occupancy and stability are tax multipliers. `P0-27` is a synchronisation point — every section written before it must implement the `SaveSection` contract as it is built, not retrofitted.

---

## 4. Phase 1 — vertical slice

**Definition of done:** the spec §44 loop is playable on an Android device: buy land → develop → build → tax → upgrade → overload → incident → dispatch → repair → grow, with a thunderstorm, offline catch-up and a WHILE YOU WERE AWAY report.

| ID | Task | hd | Depends on |
|---|---|---|---|
| **Water** | | | |
| P1-01 | Water graph: nodes/edges, derived pressure zones, tile BFS, per-tile factor cache | 3 | P0-10, P0-16 |
| P1-02 | Demand aggregation, supply chain, tank mass balance, pressure factor + smoothing, power dependency + pump trip | 3 | P1-01, P0-26 |
| P1-03 | Water failures, repair jobs, `isolate_main`, backup generator module, hydrant ratio API | 2 | P1-02, P0-18 |
| **Roads** | | | |
| P1-04 | Road tiles, contracted graph build, node predicate, edge tracing, union-find components | 3 | P0-10 |
| P1-05 | Incremental rebuild with edge-id stability + retrace budget | 2 | P1-04 |
| P1-06 | Cost function (6 factors + node delay), A*, endpoint snapping, route cache, budgets, resumable jobs | 3 | P1-05 |
| P1-07 | Congestion model: ToD curves, density, spillback, dark signals, dt-aware smoothing | 2 | P1-06, P0-26 |
| P1-08 | Closures (8 causes, dominance, spillback, auto-expiry) + speed overrides | 2 | P1-07 |
| P1-09 | Road condition, decay, damage, repair jobs, auto-repair policy, build/upgrade/demolish commands | 2 | P1-08, P0-18 |
| **Incidents & dispatch** | | | |
| P1-10 | Fleet + stations + vehicle FSM + upkeep + `speed`/`heading` publication | 2 | P0-16, P0-21 |
| P1-11 | `IncidentSystem`: object, FSM, sub-step integrator, severity/escalation/resolution math | 3 | P0-07, P1-06 |
| P1-12 | Six generators + the 14-verb declarative cascade op set (incl. `destroy_allowed()`) | 3 | P1-11, P0-26, P1-03, P1-07 |
| P1-13 | Fire spread, suppression sizing from `fire_load`, hydrant coupling, burn-down, residual damage | 2 | P1-12, P1-03 |
| P1-14 | `DispatchSystem`: priority scoring, assignment loop, reassignment, manual override, pinning | 3 | P1-11, P1-10, P1-06 |
| P1-15 | `DispatchPolicy` (all keys) + construction-crew preemption + crew integration with `ConstructionQueue` | 2 | P1-14, P0-18 |
| **Weather & Director** | | | |
| P1-16 | Weather: committed timeline, transitions, seasons on doc-01's calendar, 16 effect channels, ambient temp | 2 | P0-07 |
| P1-17 | Forecast (lead accuracy, confusion, hourly stability, both honesty rules) + storm cell + flood stub | 2 | P1-16 |
| P1-18 | Director: preparedness, threat budget, hourly scheduling, fairness gates F1–F10, event catalog | 3 | P1-17, P1-14, P0-13 |
| P1-19 | Severe thunderstorm: lightning targeting → doc-04 damage, choreography caps, prep actions, Storm Report | 3 | P1-18, P0-26, P1-12 |
| **Offline & persistence** | | | |
| P1-20 | `OfflinePolicy` bands on `TimeContext` + `OfflineGuard` clamps (eight invariants) | 2 | P0-27, P1-12 |
| P1-21 | `CatchupAccumulator` + WHILE YOU WERE AWAY report builder (8 sections, urgency ordering) | 2 | P1-20, P0-03 |
| P1-22 | Notification policy: classes, token buckets, quiet hours, coalescing, `NotificationPlanner` (classes a+b) | 2 | P1-21, P1-18 |
| **Rendering** | | | |
| P1-23 | `tools/gen_graybox.gd`: 12 archetypes × 5 levels × 2 LODs, AO bake, UV2 rule, silhouette descriptor test | 3 | P0-15 |
| P1-24 | Scene architecture, `ChunkView`, streaming, slot allocator, MultiMesh + 4-channel custom data | 3 | P1-23, P0-11 |
| P1-25 | `RenderBridge` + `RenderStateModel` (headless): LOD bands + hysteresis, dirty flush budget, event apply | 3 | P1-24 |
| P1-26 | **Blackout / relight**: stutter envelope, stagger, distance sweep, inrush overshoot, momentary classification | 2 | P1-25, P0-26 |
| P1-27 | Day/night gradient, AgX tonemap, fog, glow, streetlights (pole/lamp/pool/omni pool) | 2 | P1-25 |
| P1-28 | Weather VFX: rain/splash, wetness integrator, wet-ground, lightning sky flash; vehicle views + Hermite interp | 2 | P1-27, P1-16, P1-10 |
| P1-29 | Overlay mechanism: shader mode, `sc_overlay_colors`, power network `ImmediateMesh` lines | 2 | P1-25 |
| **UI** | | | |
| P1-30 | Theme, `UIRoot`, SafeArea, back stack, `ThemeScaler`, theme lint test | 2 | P0-04 |
| P1-31 | Camera rig + `GestureRecognizer` + `CameraController` (pan lock, momentum, pinch, twist, bounds) | 3 | P1-30, P1-24 |
| P1-32 | HUD: top bar + collapse solver, stat chips, rails, alerts/toasts, `MarkerLayer` projection + clustering | 3 | P1-31 |
| P1-33 | Build sheet + placement mode + drag-path + `RequirementFormatter` (13 codes) | 3 | P1-32, P0-17 |
| P1-34 | Building panel, land panel + development, dashboard (Overview + Response) | 3 | P1-33, P0-22 |
| P1-35 | Incident drawer + escalation bar + unit picker + two-tap dispatch + follow mode | 3 | P1-32, P1-14 |
| P1-36 | Overlay content (POWER, WATER, FIRE, POLICE), legend, state language + a11y palette test | 2 | P1-29, P1-02 |
| P1-37 | Settings, notification settings, WHILE YOU WERE AWAY screen, policy editor | 2 | P1-34, P1-21 |
| P1-38 | `OnboardingDirector` + `CoachLayer` + 13 steps + `TUT_TRANSFORMER_FAIL` scripted incident | 3 | P1-35, P1-33, P1-12 |
| **Android** | | | |
| P1-39 | `AppShell`: lifecycle notifications, pause sequence, `LifecycleStamp`, elapsed measurement with clamps | 2 | P0-27, P0-09 |
| P1-40 | Sliced catch-up + progress veil + resume handoff to the report | 2 | P1-39, P1-21 |
| P1-41 | Export pipeline: presets, keystore-by-env, `tools/build_android.sh`, debug APK, adb smoke (D-01…D-03) | 2 | P1-39 |
| P1-42 | `SlacumNative` plugin: channels, alarms, thermal, `elapsedRealtime`, `boot_id`, launch payload | 3 | P1-41, P1-22 |
| P1-43 | `PowerPolicy` (frame caps, thermal rules, battery saver) + permission flow + `CrashSentinel` | 2 | P1-42 |
| P1-44 | On-device perf pass: S1/S2/S3 scenarios, `PerfGovernor`, gfxinfo/meminfo/battery gates | 2 | P1-43, P1-28 |
| P1-45 | Balance pass: run doc-03's pacing model as a scripted agent, assert guardrails G1–G5 | 2 | P1-19, P1-21 |

**Phase 1 total: 109 hd ≈ 55 working days.** (Phase 0 + Phase 1 = **174 hd ≈ 87 working days.**)

### Phase 1 dependency edges (four parallel tracks after the Phase 0 gate)

```
MILESTONE 1
   │
   ├─ SIM TRACK ── P1-01 ▶ P1-02 ▶ P1-03
   │               P1-04 ▶ P1-05 ▶ P1-06 ▶ P1-07 ▶ P1-08 ▶ P1-09
   │               P1-10 ▶ **P1-11** ▶ P1-12 ▶ P1-13
   │                              └──▶ P1-14 ▶ P1-15
   │               P1-16 ▶ P1-17 ▶ P1-18 ▶ **P1-19**
   │               P1-20 ▶ P1-21 ▶ P1-22
   │
   ├─ RENDER TRACK ─ P1-23 ▶ P1-24 ▶ **P1-25** ▶ P1-26
   │                                   ├──▶ P1-27 ▶ P1-28
   │                                   └──▶ P1-29
   │
   ├─ UI TRACK ───── P1-30 ▶ P1-31 ▶ **P1-32** ▶ P1-33 ▶ P1-34
   │                                   └──▶ P1-35 ▶ P1-38
   │                                   └──▶ P1-36, P1-37
   │
   └─ ANDROID TRACK ─ P1-39 ▶ P1-40 ▶ P1-41 ▶ P1-42 ▶ P1-43 ▶ P1-44

Cross-track edges (the ones that actually bite):
  P0-26 (power) ──▶ P1-26 (blackout render), P1-07 (dark signals), P1-02 (pump trip)
  P1-06 (routing) ─▶ P1-11, P1-14   [route_minutes is authoritative for arrival]
  P1-03 (hydrants) ▶ P1-13          [the water→fire cascade]
  P1-24 (chunks) ──▶ P1-31          [camera needs geometry to frame]
  P1-14 (dispatch) ▶ P1-35          [drawer needs eta_seconds + eligibility]
  P1-12 (incidents) ▶ P1-38         [onboarding needs spawn_scripted]
  P1-21 (report) ──▶ P1-37, P1-40
```

---

## 5. Milestones

### Milestone 1 — "Headless sim: the starter city runs 24 game-hours deterministically under test"

**After P0-32. ~65 hd (≈33 working days).**

Acceptance, all headless, all in CI:
1. `data/starter_city.json` loads; 49 blocks (9 OWNED/READY, 12 PURCHASABLE, 28 LOCKED); every footprint in bounds, off-road, off-water, road-adjacent; every building origin within 3 tiles of a transformer.
2. Gross base tax at t0 = **$686/gh ±5%** against `data/building_economy.json` (report C-11).
3. 5,760 fine ticks (24 gh) execute the 18 phases in order every step; `EVERY_HOUR` fires 24×, `EVERY_DAY` 1×.
4. **Determinism:** the same save advanced 24 gh twice produces a byte-identical state hash and identical RNG stream states.
5. **Fine/coarse:** 24 coarse hours vs 5,760 fine ticks agree on treasury within 5% and on every deterministic quantity exactly.
6. Power solves each tick: night peak matches the starter table; forcing `F_SOUTH` open darkens exactly its subtree and raises `block_dark` on the expected blocks.
7. Economy settles 24 hourly ticks; treasury + millidollar carry equals the exact rational sum within $1.
8. Save → load → advance 1,000 more ticks on both instances → identical hashes. A corrupted generation is quarantined and the previous one loads.
9. Coarse-step cost measured and `max_coarse_hours` set (report C-21).

**This milestone is the point of no return for the balance rulings** — after it, changing `k_dem` or the currency scale means regenerating committed data and re-running the pacing model.

### Milestone 2 — "Playable window: rendered starter city with camera, build and taxes"

**After P1-34, plus the render track P1-23…P1-27 (13 hd) and the UI track P1-30…P1-34 (14 hd). ~92 hd cumulative.**

Acceptance, on desktop with a display:
1. The starter city renders at Balanced: chunks stream, three LOD tiers, gray-box archetypes readable by silhouette at Z1.
2. Day/night runs on sim time; windows light between 18:00 and 21:00; night reads as the signature look.
3. Camera: pan with exact 1:1 ground lock, pinch zoom on the geometric curve, twist with snap45, momentum, bounds rubber-band. No gesture ambiguity (tap vs drag vs long-press per the headless suite).
4. Build: FAB → sheet → card → ghost with VALID/WARN/BLOCKED tint → explicit Confirm → building appears, treasury debits, construction progresses on work units and completes.
5. Upgrade: the building panel shows the requirement checklist; forcing a feeder to 92% load produces `E_POWER_HEADROOM` with the exact deficit in kW and a working `Fix this →` jump.
6. Taxes: the HUD net-income chip moves, hourly settlement fires, the Budget panel shows the foregone-revenue line attributed by cause.
7. Manually tripping the substation darkens the blocks on screen within ~1.2 s with the stutter envelope; restoring plays the swept relight.
8. Draw calls at Z0/Z1/Z2 within the Balanced budget on the re-derived frustum (report C-63/R-17).

### Milestone 3 — "First on-device Android build with day/night and a transformer failure incident"

**After P1-41, plus water P1-01…P1-03 (8 hd), roads P1-04…P1-06 (8 hd), fleet/incidents/dispatch P1-10…P1-14 (13 hd), the drawer P1-35 (3 hd) and the shell P1-39…P1-41 (6 hd). ~130 hd cumulative.**

Acceptance, on a Tier-B device (Pixel 7a class) via `adb`:
1. Debug APK installs and launches; cold start → interactive ≤ 4.0 s; no `AndroidRuntime: FATAL`, no `SCRIPT ERROR` in logcat.
2. The starter city renders and runs at ≥ 30 fps sustained; day/night cycles visibly across a 24-real-minute session.
3. **The transformer incident works end to end:** `TUT_TRANSFORMER_FAIL` fires on `T-04`, six buildings go dark, block B2 street lighting drops, pump `P-2` goes offline and zone pressure falls to 60%, district stability drains, the incident drawer shows the tier badge and a live escalation bar, a two-tap dispatch sends `Utility 1` with a real `route_minutes` ETA, the unit drives the real polyline, and on resolution **the district relights with the swept animation**.
4. Back button never quits; pause writes a save within the 250 ms budget; `am kill` loses ≤ 60 s of play.
5. Background for 10 real minutes → resume → catch-up runs sliced with no ANR → WHILE YOU WERE AWAY report renders with a correct ledger.
6. Battery ≤ 6.0 %/h at Balanced over a 30-minute scripted session; PSS stable within ±10% after 30 minutes.

---

## 6. Top implementation risks

| # | Risk | Why it is real | Mitigation | Owner / gate |
|---|---|---|---|---|
| **R1** | **Balance-ruling churn invalidates committed data.** The currency rescale (C-07), `k_dem` correction (C-13), condition rescale (C-14) and water rescale (C-34) each touch every row of a generated table, and they interlock. Doing them piecemeal means regenerating `starter_city.json` four times and re-running the pacing model four times. | Four docs authored their tables independently against three different scales. | **Land all four rulings in one commit before P0-11 and P0-15.** Every generated table has a regenerator script plus a diff test, so a rescale is `run generator → run tests`, not hand-editing 60 rows. | P0-00 blocks P0-11/P0-15 |
| **R2** | **Coarse-step performance: the 45× disagreement (C-21).** If doc 08's 27 ms/hour is right, a 12-real-hour absence is 720 steps ≈ 19 s of catch-up — an unacceptable resume experience and, unsliced, an ANR. | Two independent estimates differ by 45×; nobody has measured. | Measure in Phase 0 (**P0-30**), before any system is written to assume a budget. `max_coarse_hours` is a deterministic tunable derived from the measurement. Struct-of-arrays iteration in the coarse path for buildings and power. Sliced main-thread execution with an honest progress bar (C-22). | P0-30, gate `test_catchup_perf_cap` |
| **R3** | **A\* routing blows the 4 ms/tick budget in GDScript.** Doc 10 names it the likeliest first breach. Dispatch, the UI unit picker and offline catch-up all call it. | ~2,000-node contracted graph, 6 routes/tick, GDScript. | Build the O(1) `estimate_eta_practical` **first** and make it the ranking path (only the top 3 candidates get real quotes). Route cache keyed on quantised congestion so price changes never invalidate paths. Test 25 is a **build-failing** perf gate. Ordered remedies: lower expansion cap → hierarchical routing (trigger conditions already specified) → GDExtension. | P1-06, gate `test_perf_budget_reference_map` |
| **R4** | **The construction-crew hole (report G-2) is load-bearing for six systems.** Land development, building construction, upgrades, repairs, road jobs and incident response all consume the same finite pool, and until now nobody owned it. | Six docs assumed an interface that did not exist. | The three-way split is ruled; implement `ConstructionQueue` **early (P0-18)** with a crew stub, so doc 06's real crews (P1-15) slot into a tested interface rather than defining one late. | P0-18 → P1-15 |
| **R5** | **Offline fairness clamps vs the incident model.** Doc 06 can burn a building down; doc 08 forbids destruction offline. A silently-swallowed `destroy_building` verb is a bug that only manifests after an 8-hour absence — the hardest possible thing to reproduce. | Output clamp vs rules branch; the failure is invisible in short tests. | Explicit `world.destroy_allowed()` guard (C-47), and a headless test that runs 10,000 seeded catch-ups at the cap on `hard` asserting zero destructions, zero deaths, no asset below 0.15 condition. | P1-20, `test_no_offline_destruction` |
| **R6** | **Save-schema churn across 19 sections.** Every system owns a section and its own version ladder; a mid-Phase-1 field change in power or incidents can strand a test city. | 19 owners, two version levels, migrations that must be *total*. | `SaveSection` contract implemented **as each system is built**, never retrofitted. `pre_migration` pinned checkpoint + quarantine from day one (P0-28/29). One real migration exercised by a fixture test before Phase 1 begins, so the mechanism is proven while it is cheap. | P0-27…P0-29 |
| **R7** | **Determinism regressions from float ordering.** Modifier products, dictionary iteration and unordered set traversal all silently break "same save + same elapsed ⇒ same outcome", and the symptom appears days later as an unreproducible offline result. | GDScript dictionaries and unsorted arrays are everywhere. | Fixed source-rank ordering in `ModifierStack`; `(phase, system_id)` scheduler sort; all dispatch and assignment iteration over id-sorted arrays; ties broken by ascending id everywhere. **`test_determinism_end_to_end` runs on every commit**, not per milestone. Static scan for `Time.` / `OS.` / `Engine.` / `Input.` under `sim/`. | P0-31, every commit |
| **R8** | **Renderer draw-call budget is unproven at the ruled camera range.** C-63 moved `D_MAX` to 420 m, which invalidates doc 11's "everything is FAR at Z2" claim and its 143-call Z2 figure. | The budget was computed at 560 m. | Re-derive the frustum math (R-17) **before** P1-24, and make `test_draw_call_prediction` a per-commit regression test against `bench_city.json` at Z0/Z1/Z2. | P1-24, `test_draw_call_prediction` |
| **R9** | **Android toolchain: Gradle template + custom Kotlin plugin.** SDK licences, JDK mismatch, Gradle daemon, exporter key drift in 4.7.2, and `.gitignore` currently excludes `android/build/` which becomes source. | Every one of these has bitten every Godot Android project. | Milestone 3 ships on the **prebuilt template** (no Gradle, no plugin) so "does it render and run on the phone" is decoupled from toolchain risk; the plugin arrives in P1-42 behind a `NotificationBridge` that stubs to no-ops off-device, keeping everything headless-testable. Narrow the `.gitignore` in the first Android commit. | P1-41 before P1-42 |
| **R10** | **Notification projection cost and the horizon error (C-23).** The design as written projects 24 real minutes while claiming 24 real hours, inside an 80 ms pause budget. | Arithmetic error compounded by the 60× scale. | Deterministic classes (a) construction timers and (b) pre-rolled Director events carry every MVP notification and need **no projection at all**. Emergent-event projection ships disabled, budget-bounded when enabled. The Director **must** pre-roll and commit forecastable events to the save — without it spec §22's flagship storm warning is impossible. | P1-18 (pre-roll) → P1-22 |
| **R11** | **Scope.** 13 subsystem docs totalling ~13,600 lines, 174 hd (≈87 working days) of planned work, one implementer. Every doc's §6 already defers content, but the slice still contains a full grid, water network, incident engine, router, Director, renderer and UI. | Spec §51 Risk 1, called out by the spec itself. | The milestone ladder is a **kill-gate ladder**: if Milestone 1 slips past 40 working days, cut Phase 1 to power + incidents + dispatch + rendering and defer water and roads-condition to Phase 2 (both have clean interfaces and stub cleanly — water to a constant pressure of 1.0, road condition to 100). Never add a system that is not on this plan. | Milestone review |
| **R12** | **The two unproven fun assumptions.** (a) Increasing payback-per-level (doc 02: L1 ≈93 gh → L5 ≈272 gh) — going tall is deliberately *worse* ROI. (b) The Director raising challenge with preparedness (`pressure = 0.55 + 0.90·P`) — observant players will read it as rubber-banding. | Both are deliberate, both are contrarian, neither is playtested. | Both are single tunables (`k_cost` / `UPG_GROWTH`, and `pressure_slope`). Instrument them in the Milestone 3 build and treat the first real play session as the test. Do not build content on top of either until it is confirmed. | Post-Milestone 3 |

---

## 7. Working rules for the build

1. **Report 98's rulings are binding.** A doc that contradicts them is stale, not authoritative.
2. **No number in code.** If it is tunable, it is in `data/`, loaded through `DataRegistry`, and validated at boot.
3. **Tests ship in the same commit as the code** (constitution §12). A system without headless tests is not done.
4. **Docs stay truthful.** When code and a doc diverge, the doc is updated in the same change.
5. **Determinism is a per-commit gate, not a milestone gate.**
6. **Generated data is generated, never hand-edited** — `buildings.json`, `building_economy.json`, `starter_city.json`, `bench_city.json` and the gray-box meshes all have regenerators plus diff tests.
7. **Every cross-doc interface named in report 98 §11–§12 is a real function signature before its consumer is written**, even if it returns a stub.
