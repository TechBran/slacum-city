# 93 — Mechanics audit: what the player can and cannot yet do

*Lead-engineer audit, 2026-08-18. Ranked by how much each gap hurts the core
fantasy: "You built it. Now keep it alive." Feeds the Wave-2+ build-out roster.*

## A. The verdict in one paragraph

The sim under the city is deep (deterministic grid, economy, construction),
and the player can now see it, touch it, and buy into it. But the player can
only ever ADD houses to a grid someone else built. The game's soul — running
and extending the INFRASTRUCTURE — has no verbs yet: you cannot place a
transformer, so `E_UNSERVED` is a wall instead of a challenge; you cannot
demolish, repair, prioritise, set taxes, buy land, or build roads. Wave 1
(in flight) adds the systems that create PRESSURE (incidents, weather, water);
this audit's work adds the VERBS that let the player answer it.

## B. Command-layer gaps (sim, doc 02/04/03/09) — ✅ SHIPPED (Wave 1.5, 2026-08-18)

All six verbs live in `sim/city_sim.gd` with preview support, ordered reason
codes, and save-round-trip tests (`tests/test_player_verbs.gd`). Priority
classes are doc 04's (CRITICAL|ESSENTIAL|STANDARD|DISCRETIONARY). Open
rulings tracked from the delivery report: transformer L1–L3 vs doc 04 §6's
L1–L4 cut; `feeder_tap_radius_tiles: 8` wants a doc 04 ruling;
`data/grid_components.json` folds into `data/power.json` when a power agent
owns it; `cmd_buy_block` auto-develops by default.

| Verb | Spec | Why it matters |
|---|---|---|
| `cmd_place_grid_component` (transformer L1–L3; feeder tie-in per doc 04 §2.1) | doc 04 | THE game. Unblocks tutorial_lot_a's `E_UNSERVED` beat and the whole expansion loop. `cmd_place_building`'s own comment calls it "the Phase-1 command". |
| `cmd_demolish_building` | doc 02 | Refund per construction refund table, tile clear, grid/water detach, population rehousing consequences. |
| `cmd_repair_building` | doc 02 | `Building.repair()` exists unsurfaced; condition decay already punishes neglect. |
| `cmd_set_priority(sim_id, class)` | doc 04 | Priority loads survive shedding — the blackout-triage fantasy. |
| `cmd_set_tax_level(level)` | doc 03 | TAX_LEVEL_GROWTH curve exists; the knob is unreachable. |
| `cmd_buy_block(block_id)` | doc 09 | `DevelopmentController` develops ring blocks; no purchase verb → city cannot grow outward. |

## B2. The infrastructure verbs — ✅ SHIPPED (Wave 5, 2026-08-19)

§A's verdict said the player "can only ever ADD houses to a grid someone else
built". Wave 1.5 answered the power half. Wave 5 answers the other two: the
player now lays, upgrades and rips up ROADS, and builds, extends and upgrades
the WATER system. All of it goes through `sim/city_sim.gd` with preview support,
the owning doc's reason codes in the owning doc's order, doc 03 billing through
the same construction path buildings use, and save-round-trip tests
(`tests/test_infra_verbs.gd`).

| Verb | Spec | Why it matters |
|---|---|---|
| `cmd_place_road(tiles, road_class)` | doc 10 §2.13 | The city's own streets. Priced per tile by doc 03 §2.13(d); tiles enter the grid immediately at condition 0.10 behind a `construction_new` closure, so the corridor is visible while the crew works. |
| `cmd_upgrade_road(tiles)` | doc 10 §2.13 | `STREET → AVENUE`, which is also how a player answers doc 02's L4/L5 `E_AVENUE` gate on an interior block. |
| `cmd_demolish_road(tiles)` | doc 10 §2.13 | Refunded at the class each tile actually carries, and **refused** if it would leave a building with no road beside it. |
| the block road template stamp | doc 09 §2.9.1 | Not a verb — the gap behind them. A developed ring block used to arrive with no roads at all; it now arrives with doc 09's 87-tile template and 169 buildable tiles. |
| `cmd_place_water_component(kind, tile)` | doc 05 §6 | One command builds the doc-02 shell, the doc-05 node it hosts and the service lateral that joins it to the network — the three things that have never been separable. |
| `cmd_place_water_main(tiles, tier)` | doc 05 §6 | Reach. Connectivity in doc 05 is physical (shared tiles), so a main is how the network grows toward new ground. |
| `cmd_upgrade_water_component(node)` | doc 05 §6 | Capacity, priced on doc 03 §2.3's own upgrade curve, gated by doc 04's power headroom — which is where the player meets the cascade from the supply side. |
| `cmd_isolate_water_main` / `cmd_restore_water_main` | doc 05 §2.12 | The tactical pair: trade a neighbourhood's taps for the fire's hydrants. |

**Surfaced, Wave 10.** Every verb in the table above now has a door the player
can touch — the build sheet's `Roads` tab and the two water-main cards, both
driven by doc 12 §2.7's drag-path tool (report 98 RR-30, doc 93 §G2). The three
per-building verbs `cmd_repair_building`, `cmd_set_priority` and
`cmd_demolish_building` landed in the same wave, as §2.9 item 6's actions row.

**And the last three, Wave 11 — the table is now empty of doorless rows.**
`cmd_upgrade_water_component` is a block on the building panel of the shell that
hosts the node, `cmd_isolate_water_main` / `cmd_restore_water_main` are one
control in two moods on the incident drawer's expanded row, and **no water-node
panel was built**: §J1 rules that the two verbs belong to two different moments
and that a screen hosting both would be a screen the player has to go and find
mid-incident. §J2 puts doc 04 §4's `route_feeder` on the same drag-path tool as
two cards, one per conductor class doc 04 §6 ships.

**Doc 04 §4's `route_feeder` shipped in Wave 6** and reached the player in Wave
11 (§J2). The Wave-5 measurement that made it the priority (doc 92 F-11) stands
as written: the whole city's load ran through the two class-1 feeders doc 09
§2.9.5 authored — **2 × 1,200 kW** — a well-played city crossed that around
410 buildings, and everything past it was shed. **Doc 92 §17.3's three-item fix
list is now complete on the first two items and the third is still ruled out**:
the verb shipped (item 1, Wave 6), the `substation` / `power_facility` shells
became their grid nodes (item 2, Wave 6, via `node_shells`), and no capacity
constant moved (item 3). The whole loop was walked end to end on the founding
city in Wave 11 — see §J2.

## C. Feedback gaps (game/ui) — Wave 2, after Wave 1 merges

1. **City-level moments** — `city_level_changed` + grants exist and are silent.
   Toast + unlock reveal in the build sheet (cards already carry `locked`).
2. **Offline return** — `CatchupPlanner` runs; the player never sees "While
   you were away: 6h, +$4.1k, 1 outage". Doc 08's return sheet.
3. **Tutorial** (doc 12 §onboarding) — scripted first 15 minutes:
   house → unserved lot → place transformer → first storm → transformer fails
   (`TUT_TRANSFORMER_FAIL` tag, Wave-1 incidents) → dispatch → repair.
   Blocked by: B verbs + Wave-1 incidents. The Milestone-3 acceptance arc.
4. **Overlay legends** — sc_overlay_mode ships with Wave-1 UI; legends + per-
   overlay data layers (power load %, water pressure, congestion) follow the
   sims.
5. **Stats screen** — treasury/population/happiness history graphs; the HUD
   chips already read the values, history buffer is trivial sim-side.

## D. World-motion gaps (renderer) — Wave 2

- **Vehicles** from doc-10 events (Wave 1 defines the stream): crew trucks to
  incidents/sites, ambient commuters; construction vehicles the user asked for.
- **Weather visuals**: rain particles, sc_wetness ground response, lightning
  flash on `lightning_strike`, storm skies (globals already exist).
- **Road surface pass**: markings, crosswalks, intersection caps (texture
  agent's ground set feeds this).
- **Streetlight block-outage fidelity**: per-block `StreetlightsChanged` from
  the grid (logged follow-up; render side already handles the event).

## E. Balance — continuous from Wave 1.5

Headless playtest harness (scripted strategies over N game-days → curves) so
tuning decisions come from data, not vibes: greedy-growth, infrastructure-
first, do-nothing, and disaster-heavy runs. Report lands as doc 92 and gets
re-run per merge. Doc 03's anchors ($686/gh, +$318.77/gh founding net) are the
regression baseline.

## E2. As-integrated anchor shifts (Wave-1 integration, 2026-08-18 — binding
## until docs 03/09 refresh their worked examples)

Docs 03/09's worked examples were computed against the held water/road stubs.
With docs 05/10 billing live, the founding anchors move; the CHAINS are
unchanged and each shift is explained by a named replacement:

| anchor | doc value (stub) | as-integrated | why |
|---|---|---|---|
| 20:00 system peak | 783.3 kW | **801.7 kW** | doc 05's live node roster meters the real plant, ~+18.4 kW over the L1-variant constants |
| founding gross revenue, first hour | $839.349 | **$841.225** | live inventories; +0.22%, unmoved in substance |
| founding expense, first hour | $520.577 | **$504.177** | see the fleet-billing ruling below, then the Wave-4 F-4 line |
| founding net, first hour | +$318.77/gh | **+$337.048/gh** | ditto |
| founding day net | ≈ +$7,650 | **+$8,004** | same, over 24 settlements |

**Wave-4 re-anchor (doc 92 §13/§14, 2026-08-19).** Three of the five rows above
moved again, by −$0.60/gh of expense and −$0.053/gh of gross, and both shifts
have one cause each:

| line | before Wave 4 | after | why |
|---|---|---|---|
| `E_grid` | $74.874/gh | **$74.274/gh** | doc 92 F-4 thinned `data/starter_city.json`'s founding transformer roster **23 → 18 nodes**. That is 0.15 MVA of rated plate (`2.40 → 7×0.05 + 10×0.15 + 1×0.40 = 2.25`), and doc 03 §2.4 bills $4.00/MVA-gh on the inventory, so the line falls by exactly `0.15 × 4.0 = $0.60/gh`. The plant, the substation and the 1.416 km of line are untouched. |
| gross revenue, first hour | $841.278/gh | **$841.225/gh** | `tax.COND_FLOOR` 0.55 → 0.40. `f_condition(1.0) = 1.0` at **every** floor, so this is only the first settled hour's own decay (condition 0.99955) re-weighted: −0.0063 %. Every founding anchor is preserved to five significant figures. |
| night peak / feeder split | 783.3 kW · 361.8 / 421.6 | **783.4 kW · 365.8 / 417.6** | the thinning re-homes the removed nodes' streetlights, signals and building customers to the nearest survivor (doc 04 §2.3, no radius limit), so the LOAD is conserved and only its distribution moves. `F_SOUTH` still carries **53.3 %** of the city's night load — doc 09 §2.9.5's designed lesson survives. |

`data/economy.json`'s `pacing_guardrails` carries the re-stamped pair
(504.176677 / 337.047860, first-day 8004.047) and `STARTER_E_GRID_PER_HOUR`
74.27; `data/world.json`'s `starter` block carries the new transformer
histogram (**L1 7 / L2 10 / L3 1**, `rated_mva` **2.25**), night peak and feeder
split. `tests/test_balance_gates.gd` gates 1, 2 and 2b hold the pair to ±1 %,
and `tests/test_starter_city.gd` / `tests/test_city_sim.gd` /
`tests/test_economy.gd` carry the derivations inline.

**Fleet-billing ruling (doc 92 pass-2 F-3, 2026-08-19).** Doc 06 owns fleet
capacity (C-50), so doc 03 bills the roster doc 06 actually houses:
`build_settlement_inputs`' `vehicles` is `incidents.fleet.roster_for_economy()`
and the held `CitySim.STARTER_VEHICLES` constant is **deleted**. Two lines move
in opposite directions and the net is **−$15.80/gh** against the stub ledger:

| line | stub (`STARTER_VEHICLES`) | as-integrated (doc 06 roster) | why |
|---|---|---|---|
| `E_fleet` | $58.00/gh — 6 held rows | **$76.00/gh** — the real 8, `2/1/2/2/1` | doc 06's `capacity_per_station_level` houses 2 patrol, 1 engine, **2** utility, **2** water repair, 1 crew; doc 03's held list had one utility and one water truck |
| `E_fuel_vehicle` | $6.00/gh | **$0.00/gh** | the held rows carried an invented `km_this_hour`; the live roster meters no road distance yet, so it bills none rather than a fiction |
| everything else | — | −$3.80/gh | docs 05/10 live inventories, unchanged in kind |

`data/economy.json`'s `STARTER_EXPENSE_PER_HOUR_EXACT` and
`STARTER_NET_PER_HOUR_EXACT` are **re-stamped to the as-integrated pair**
(504.776677 / 336.501773) and are the regression target
`tests/test_balance_gates.gd` gates 1–2 hold to ±1 %. The unsuffixed
`STARTER_EXPENSE_PER_HOUR` 521 / `STARTER_NET_PER_HOUR` 319 stay doc 03 §2.12's
published round figures, and `tests/test_economy.gd::test_founding_ledger` still
checks the doc's own arithmetic against its own literals — the CHAIN is
preserved, as this section has said from the start; only the inventory changed.

**Also binding from the same pass (doc 92 pass-2 rulings 1, 4, 5, 6, 8):**

- **doc 02 §2.6 wear is live.** `Building.apply_decay` is called once per settled
  game-hour from `HourlyPhaseSystem`, before doc 03 bills the hour, with doc 04's
  `power_availability_hour`, the serving transformer's overload excess and doc
  07's `condition_decay_mult` (× doc 03 §2.10 layer 2's `AUSTERITY_DECAY_MULT`).
  `data/buildings.json`'s 60 authored `decay_per_hour` rows stop being dead data.
- **doc 03 §2.10's recovery ladder is live.** `update_credit_limit` /
  `update_austerity` / `maybe_grant_relief` run every settled hour off the
  settlement snapshot; all six `treasury.spend()` call sites read their result and
  fail with `E_AUSTERITY` rather than proceeding for free.
- **`tax.TAX_RATE_GROWTH_COEFF` 3.5 → 8.0.** Top detent growth ×0.755 → **×0.44**;
  bottom detent ×1.175 → ×1.40. No revenue term moves.
- **`data/director.json` gains a `floor` block.** A size-independent minimum
  threat-point cadence, whitelisted to minor tier-1 events under `max_tp_cost`, so
  a founding city gets weather and a cooked transformer inside its first game-week.
  `data/incidents.json` `generator_base_rates` are untouched.
- **Incident lifecycle events name their own kind.** `incident_created` /
  `tier_changed` / `resolved` / `failed` / `abandoned` carry the incident's kind as
  **`incident_type`**; `type` is the bus event name and always was. No compat key.

**Binding from the Wave-4 maintenance fit (doc 92 §13/§14, 2026-08-19):**

- **`tax.COND_FLOOR` 0.55 → 0.40.** Doc 03 §2.2's `f_condition = COND_FLOOR +
  (1 − COND_FLOOR)·C`. The floor sets *the payback period of a repair*: at 0.55 a
  repair bought back its price in ≈19 game-days of recovered revenue, which is
  outside the pacing horizon and is why doc 92 pass-2 F-2 could not measure
  maintenance paying for itself; at 0.40 it is ≈14, and the maintained agent
  overtakes the neglecting one inside 21 game-days for the first time. `f_condition(1.0)`
  is 1.0 at every floor, so **no founding anchor moves**. Doc 03 §2.2's worked
  examples A and B re-price (`0.9775 → 0.9700`, `$23.86 → $23.68/gh`,
  `$8.23 → $8.17/gh`) — `tests/test_economy.gd` carries the new literals; doc 03's
  own §2.2 text is an open edit for that doc's owner.
- **`expenses.MAINT_CONDITION_PENALTY` 1.5 — HELD, measured.** Isolated on the
  same A/B it contributes **+$703 of a $5,874 maintenance-pays gap (12 %)** while
  raising the single largest expense line in a grown city (`building_maint`, 36 %
  of a 320-building city's hourly expense) by 8–16 % for BOTH agents. Not worth a
  doc 03 constant move for that.
- **`data/buildings.json`'s 60 `decay_per_hour` rows — HELD, measured.** The
  ruled pacing targets are met at the authored rates: a maintaining city spends
  **11.3–12.1 % of net** on repairs (ruled band 10–20 %), a neglected city reaches
  doc 03's `COND_FLOOR` in **2.2–2.8 game-weeks** (ruled 2–3) and is fatal at
  **4.7 game-weeks** (ruled ≈5, tolerance 2×). What made maintenance a chore was
  the repair THRESHOLD, not the rate — see doc 92 §13.
- **The founding transformer roster is 18 nodes, not 23** (doc 92 F-4). See the
  re-anchor table above.

**Binding from Wave 5 (the infrastructure verbs, 2026-08-19):**

- **The hour-48 `E_UNSERVED` goal is RETIRED.** Doc 92 §14.1 and gate 10 chased a
  target — *the player's first `E_UNSERVED` should land inside the first two
  game-days, so `cmd_place_grid_component` is taught early* — and doc 92 proved
  it geometrically unreachable: hour 48 at the measured fill rate needs 35–80
  served vacant tiles, doc 09's own siting rule (every one of 34 authored
  building origins within Chebyshev 3 of a transformer, spread across all nine
  core blocks) has a set-cover floor of 16–17 nodes, and 18 radius-3/4/5 patches
  already union to **452** of the core's 1,429 vacant lots. **452 is the floor**,
  and neither a grid edit nor a READY-block trim reaches 80.
  **The ruling: the wall is money-paced by design and that is correct.** A
  founding city nets ~$340/gh against $1,200 a house, so the fastest builder in
  the study converts income into floorspace at ~0.35 buildings/gh; the ground
  outlasts the money by a wide margin and always will. Teaching the transformer
  by starving the player of LAND would be teaching it with a fake shortage.
  **The early beat is the first infrastructure DECISION, not the first refusal:**
  a transformer bought *ahead* of growth — because a block the player just
  developed arrives with a utility corridor and no tap, so all 169 of its
  buildable tiles answer `E_UNSERVED` the moment it turns READY. That is a
  purchase the player makes in their first game-week, it is legible, and it is
  the thing doc 93 §A called "THE game". `tests/test_balance_gates.gd` gate 10
  re-anchors onto it and stops asserting an hour.
- **`min_city_level` is enforced at placement** (doc 92 pass-1 F-7, ruled).
  `cmd_place_building` answers `E_CITY_LEVEL` below the archetype's
  `min_city_level`, as `cmd_upgrade_building` always has. The build sheet's lock
  glyph is no longer a courtesy the sim declines to keep. `apartment` L1 needs
  city level 1, so a founding city opens on houses and stores — that is the
  design. Every scripted strategy in `tools/playtest.gd` already filtered on the
  UI's rule (`Api.buildable`), so the pacing curves do not move; gate 14 stops
  pinning today's behaviour and asserts the refusal.
- **A developed land block now arrives with roads.** Doc 09 §2.9.1's 87-tile
  template (60 boundary → AVENUE, 27 collector → STREET) is stamped at the
  `ROAD_INSTALL` development phase, which had never shipped, so a ring block used
  to reach READY with **no roads at all** — 256 placeable tiles, none of them
  with road access, on a map whose revenue formula multiplies by `f_road`. A
  stamped block is doc 09's published **169 buildable tiles**, and the road-repair
  line grows with the network exactly as doc 03 §2.12's per-block term intends.
  The stamp books no money: doc 03 §2.8's `road_install` phase price pays for it
  once (doc 10 §2.3's no-double-billing rule).
- **`save.roads` is `section_version` 2.** `edge_dynamics` and `c_day_sum` moved
  off edge-id keys onto the edge's canonical tile key, and the graph's LABELLING
  (edge ids, node ids, polyline orientation and both allocators) now travels with
  the save. The version-1 note claimed edge ids were "stable across
  rebuild-from-blocks"; that was vacuously true only while nothing could edit a
  road tile. It is not true in general — a live graph reaches its ids through doc
  10 §2.5's incremental retrace, a loaded one through `rebuild_all()` — and the
  first player-placed road made save→load→advance identity fail one game-hour
  later. A version-1 section still loads; its two id-keyed maps are dropped
  rather than mis-applied.

**Binding from Wave 6 (the pacing passes, doc 92 §18/§19, 2026-08-19):**

- **`data/incidents.json` gains an `ambient_floor` block** — a size-independent
  minimum on doc 06 §2.6's generation, per channel, expressed as
  `λ = max(λ_natural, floor_per_hour × dt_h)` inside the existing
  `_poisson(… × damper)`. It is the same instrument doc 07 §8's Director floor
  already is, applied to the other half of the pressure system, and it is a floor
  in every sense: **no `generator_base_rates` row moved**, a channel that
  out-generates its floor never sees it, and a channel with no eligible candidate
  this sub-step stays at zero. `grace_days 2.0` keeps the founding day and the one
  after quiet so the tutorial's scripted transformer is still the first incident a
  new player meets. Measured A/B over 336 game-days on each side, twelve seeds,
  one boolean apart: **1.88 → 3.04 ambient incidents per game-week** at starter
  scale, 146 of 146 resolved, zero failed, zero abandoned, nothing destroyed, and
  the control city ends **richer** (+1.2 %) because doc 06 credits `reward_base`
  on resolve. Doc 92 §18.
- ~~**Two of doc 06's six generators have no candidate source — D-14 / D-15.**~~
  **CLOSED 2026-08-19 (Wave 7); the pair is renumbered D-17 / D-18** (doc 91's
  defect table carried two D-14/D-15 pairs and the performance pair keeps the
  original ids — see doc 91 §14.5's renumbering note). `CityIncidentWorld` now
  overrides both stubs: `water_mains()` joins doc 05's `WaterSystem.mains()` and
  `road_intersections()` joins doc 10's `RoadNetwork.intersections()`, so
  `water_main_break` and `traffic_accident` generate for the first time —
  **0.00 → 0.60** and **0.00 → 3.60 per game-week** at starter scale. The floor
  carries **five** rows now, not three, and the traffic rate takes the ambient
  total past doc 92 §18's ruled 2–4/game-week band. Doc 92 §18.6 is the
  re-derivation; `tests/test_incident_world_join.gd` is the proof.
- **Doc 09 §2.11's city-level ladder is RETUNED and now lives in
  `data/progression.json`.** Report 98 G-1 named that file and nobody ever wrote
  it, so the ladder was a `const` in `sim/population/progression_system.gd` — the
  one balance number in the game that could not be retuned without a code edit.
  The shift table, and what each rung is worth in game-days on doc 92 §2's
  `balanced` agent:

  | city level | 0 | 1 | 2 | 3 | 4 | 5 |
  |---|---|---|---|---|---|---|
  | min city population, **was** | 0 | 250 | 1,000 | 4,000 | 12,000 | 30,000 |
  | min city population, **is** | 0 | **200** | **700** | **1,600** | **3,600** | **8,000** |
  | `balanced` reaches it on game-day | t0 | **2** | **11** | **23** | *unfitted* | *unfitted* |
  | reachable before? | — | day 4 | day 17 | **never in 50** | **never** | **never** |

  The old rows were adopted verbatim from a doc 02 *proposal* that predated every
  measurement in doc 92, and four of the six were unreachable by anything the game
  can do: doc 92 §8's 90-game-day run peaks at 1,872 residents and `balanced` ends
  fifty game-days at 2,710, so doc 02 §2.10–2.11's whole upgrade ladder — every L4
  and L5 rung, `high_rise`, `data_center`, doc 10's `road_crew` — sat behind a door
  with no key, which is audit 91 D-7's 376 refused upgrades. Levels 4 and 5 are
  placed by the ratio the fitted rungs settle into (~2.25×) rather than by fit,
  because no strategy in doc 92 has ever produced 3,600 residents; that is pass-3
  F-11's power ceiling and they get a real fit when the feeder verb lands.
  **Monotonicity is untouched** — a retune downward can only grant a level, never
  take one back, and `city_level_max` still wins on load. **t0 is still below rung
  1** (144 against 200), so gate 14's `E_CITY_LEVEL` refusal, the Wave-5
  `min_city_level` ruling and the tutorial's first locked build card all still
  bite. `ProgressionSystem.CITY_LEVEL_POP_FALLBACK` is a missing-file degrade and
  **not a mirror**; gate 20 asserts the two agree.
- **Gates 19 and 20** hold both rulings — the pacing budget off the data file plus
  a five-seed rate band, and the ladder's shape plus the two ruled unlock windows.
  `tests/test_population.gd` now asserts the ladder's *arithmetic* against
  whatever rows are loaded instead of pinning the rungs as literals; the rungs
  and their measured justification belong to gate 20.

**Binding from Wave 7 (the tax ruling + S0, 2026-08-19):**

- **`tax.TAX_RATE_HAPPINESS_COEFF` 220 → 360.** Wave 6 made the power grid
  buyable, which gave `tax_squeezer` — `balanced` with the slider pinned to
  `TAX_RATE_MAX` — somewhere to put its ×1.778 revenue. On the 21-game-day matrix
  it stopped being merely *rich* and became **strictly dominant again**: +104 %
  value created **and +43 % population** against `balanced`, for a happiness
  deficit of 1.6 points. Doc 92 F-5's ruling ("money now versus a city later")
  was therefore no longer true of the agent a player resembles, even though gate
  12b's controlled pair still showed the detent costing 18 % of a *fixed* city.
  Both readings were correct; they measure different things, and the one that
  matters is the one with a build plan in it.

  **The ruling: one key, because one key is all it takes.** All three couplings
  doc 03 §2.2 publishes are denominated in the points `happiness_tax_delta`
  produces — the happiness target directly, and `attractiveness_tax_factor`
  through `TAX_RATE_ATTRACT_PULL` — so the coefficient moves the whole chain and
  the rate is still read exactly once (report 98's no-double-count rule).
  `TAX_RATE_GROWTH_COEFF`, `TAX_RATE_ATTRACT_PULL`, `TAX_RATE_MIN/MAX`,
  `TAX_RATE_STEP` and every revenue term are untouched.

  | at `TAX_RATE_MAX` | was | is |
  |---|---|---|
  | `happiness_tax_delta` | −15.4 | **−25.2** |
  | `attractiveness_tax_factor` | 0.7998 | **0.6724** |
  | `growth_rate_multiplier` | 0.44 | 0.44 |
  | equilibrium `occupied_population` at t0 (doc 09 §2.10.2a) | 115 | **97** |

  **Fitted on gate 12b's controlled pair, confirmed on the matrix** — the fit is
  steep, which is why the value is 360 and not something rounder (3-seed matrix,
  `tax_squeezer` against `balanced`, 21 game-days): at **340** the squeezer trails
  by only 5.5 % on population, missing the ruled 10 %; at **400** it trails by
  21 % but ends *poorer* than `balanced`, which is a trap and not a tradeoff; at
  **360** it trails by **14.7 %** on population and **23.0** happiness points
  while still creating **35 %** more value. Both halves of the ruling clear on all
  three seeds.

  **No anchor moves and no hash moves.** `happiness_tax_delta` is exactly 0 at
  `TAX_RATE_BASE`, and nothing in the game runs at any other rate unless a player
  moves the slider, so the founding ledger, doc 03's worked examples and every
  `pacing_guardrails` figure are untouched. Verified rather than argued:
  `tools/profile_sim.gd --baseline` prints **BEHAVIOUR UNCHANGED** for both the
  starter city (`beb73b276c275ab8` / `2efcb1a8cbb3048c`) and
  `tests/fixtures/bench_city.json` (`dec792975cd3ba89` / `31a0c6eb8c85a68e`).
  Gates 12 and 12b are retuned with the new measurements (12b's cash threshold
  1.25× → **1.15×**: the measured multiple fell from 1.710 to 1.258 *because the
  residents the squeezed city no longer has were the ones paying the higher rate*,
  and a gate whose margin is 0.6 % measures float noise); **gate 12c is new** and
  holds the ruling's own statement — the matrix comparison — at the ruled
  thresholds rather than the measured ones. Doc 92 §20.
- **S0 exists (doc 12 §2.2's one screen with no node).** `ui/title_screen.gd` +
  `ui/title_model.gd` on a new `SafeArea/TitleLayer`, which sits **above the city
  deck and below `ModalLayer`** — the front door covers the HUD, the panels and
  the sheets, and SETTINGS opened from the door covers the door. `UIRoot` gains
  `present_title()` / `dismiss_title()` / `title_open()` / `refresh_title()` and
  the three signals `title_continue(slot)` / `title_new_game(slot)` /
  `title_settings`. Two invariants are load-bearing:
  - **The door is absent unless the shell asks for it.** No `ui/` file opens it;
    `bring_up_screens()` brings it up *closed* like every other screen. That is
    what lets `tests/test_tutorial_flow.gd`, `tests/test_ui_audit.gd` and
    `tools/ui_preview.gd` keep driving the same scene with no front door in the
    way.
  - **The door closes nothing by itself.** CONTINUE and NEW CITY are intents; only
    the shell knows whether a restore succeeded, and a corrupt save must leave the
    player looking at the door rather than at an empty city.
- **NEW CITY may not silently orphan the old one, and the honest fix is not a
  new `SaveService` method.** *(Restated 2026-08-19: doc 08 §2.7 retired the
  two-slot rotation this bullet was written against — every autosave lands on
  `AUTOSAVE_SLOT 0` and the depth comes from that slot's generation ladder. **The
  ruling is unchanged and so is its reasoning**; only the mechanism it prices is.)*
  The autosave **slot** belongs to whatever city is *live*; it has no idea a city
  was replaced, so a new city takes it over and a few autosaves later every
  generation in the ladder holds the new city. `TitleModel`
  therefore prices that rather than hiding it: `new_game_plan()` names the manual
  saves that survive (doc 12's "name the save it will NOT delete"), says the
  autosave is what a new city costs, and — when the outgoing city lives *only* in
  the autosave slot — offers it the lowest free manual slot. The shell performs that
  archive with three published calls and no new API: `load_slot` the old city into
  the sim, `save_slot` it into the free slot, `restore_state` the founding capture
  back, which is exact **because** save→load→advance identity is exact. When every
  manual slot is full the plan says so and points at Settings ▸ Manage saves
  instead of choosing one of the player's own saves to sacrifice.
- **The back stack grows one context, not one rung.** `UIRoot.resolve_back` takes
  `title_open`, and at the front door the city rungs (sheet, panel, placement,
  selection) *cannot exist*, so back falls straight to doc 12 §2.2's two-press
  minimise pair. `BACK_CLOSE_MODAL` still wins, or back at the settings sheet
  opened from the title would quit the game.
- **`type_scale_dp.display` finally has a reader.** `ThemeBuilder` gains a
  `Wordmark` → `Label` type variation at that size; it is the game name on S0, and
  it scales with A2's text setting like every other size in the theme rather than
  being a per-node font override.

Also binding from the same pass: **mode-invariance is per-system, not
whole-hash** — doc 06 §2.6 sanctions Poisson-count differences per step size,
doc 04 §2.12 sanctions one-step coarse thermal integration, and the cosmetic
traffic feed draws per-minute online. The milestone criterion guards the
deterministic core (clock, population, happiness, settled economy ±5%) with
ambient generation disabled; each stochastic subsystem's own suite bounds its
sanctioned parity. Save→load→advance identity remains EXACT and whole-hash —
that doctrine is untouched (and Wave-1 integration hardened it: negative-double
encoding, traffic-feed/congestion/density/day-accumulator persistence).

## E3. Wave-8 rules epoch — the sub-step guard, the substation at the origin,
## and the router that is measured but not wired (2026-08-20)

Three things happened to the incident loop in one branch, because all three move
state hashes and doc 08 §2.8's section bump had to happen once. Full rulings in
report 98 §16 (RR-21/22/23); balance in doc 92 §21; performance in doc 11 §2.13's
Wave-8 subsection.

| | what | evidence |
|---|---|---|
| **Shipped** | `IncidentSystem._next_discontinuity_h()` skips the fire-spread breakpoint when no `structure_fire` is live (audit 91 D-15 proposal 1) | integrator sub-steps **12.00 → 1.25 per coarse hour** on the starter city, **20.67 → 10.50** on the benchmark city; starter coarse step **−24 to −27 %**, every interleaved round; fine tick flat |
| **Shipped** | doc 04's component `tile` is filled from the authored `terminal` for plants and substations, from the route head for lines, and re-stamped from the boot file on every load | every substation failure used to raise its incident at **(0, 0)**; with the router wired that made `balanced` seed 1337's 50-game-day dark share **61.8 %** instead of **6.25 %** |
| **Shipped** | `CitySim.SAVE_SECTION_VERSION` 1 → 2, identity migrator, v1 bodies still load bit-identically | `tests/test_save_migration.gd` — four properties, including that the ladder is *walked* and not merely present |
| **HELD** | doc 10's router as doc 06's ETA authority | seam complete and tested; wiring it makes a rotting city's incident backlog unbounded (`greedy_growth` seed 4242: **12.6 s → > 20 min**) because doc 06 §2.10 has no terminal rule for an incident nobody can answer |

**The anchors in §E2 do not move.** Nothing in this epoch touches a price, a
rate, a capacity or a curve: the founding first-hour net, the first-day net, the
`E_grid` line and the night peak are all byte-identical, and balance gates 1, 2
and 2b — which hold them to ±1 % — pass unchanged. What moves is the RNG draw
sequence on a coarse hour and, for a city that has lost its substation, the fact
that it no longer loses it.

**The identity-level balance rows do not move either.** `balanced` beats
`do_nothing` **5.5× on value created** and **9.6× on population** on the
18-run matrix, before and after, and **all 27 balance gates pass with no
threshold retuned** (doc 92 §21.3).

## G. Wave-9 rulings — the goal curriculum (2026-08-20)

### G1. Objectives ADVANCE the city level; the population ladder BACKSTOPS it

**The finding.** Doc 09 §2.11's ladder is a population threshold and nothing
else. A threshold is not a goal: the player was told *"Level 2"* by a toast and
was never told what Level 3 costs, so the ladder was invisible and the first hour
of the game had no arc past doc 12 §2.17's eleven-step tutorial. The player, in
their own words after a Fold playtest: *"players know exactly what they need to
accomplish to get to the next level, like build a certain building or do a
certain task."*

**The ruling.**

```
city_level = max( level_reached(city_population),  goals.earned_level )
```

Both routes go through one monotone writer, `ProgressionSystem.grant_level`.
Completing doc 09 §2.14's objective list for level N grants level N; so does
crossing doc 92 §19's population rung for it; neither can take a level back.

**The alternative that was rejected, and why.** The obvious reading of the ask —
*objectives REPLACE thresholds for levels 1–5* — was rejected on two counts, both
measured rather than argued:

1. **It would strand every player who does not read the sheet, and every agent
   that cannot.** Three of the five curriculum levels ask for verbs no scripted
   strategy in `tools/playtest.gd` drives (the tax slider, a police station, a
   $45,000 water pump). Under pure replacement `balanced` stops at level 2 for
   ever, which is *worse* than the ladder it replaced — and doc 92's whole matrix
   would stop measuring the progression it was fitted on.
2. **It would make the ladder retune unfalsifiable.** §19's rungs were fitted
   against a measured population curve. Removing their only consumer for the
   first five levels does not disprove the fit, it hides it.

Under MAX both are answered: the taught route is genuinely faster (level 1 in 18
game-hours against two game-days), the untaught route is exactly what it was, and
`data/progression.json` did not move a single rung. Doc 92 §22.4 is the
re-derivation; gates 20 and 21 are the pair that keeps both halves honest.

**What it cost.** One gate threshold — gate 20's level-1 window, from `[2, 4]` to
`[0, 2]`, because the lower bound existed to say *"an unlock has to be earned"*
and the curriculum is a second way to earn it. Gate 21 asserts the earning
directly. Nothing else in 27 gates moved.

### G2. A curriculum may never ask for a verb the player cannot perform

**✅ THE DOORS EXIST (Wave 10, 2026-08-20).** The rule stands; the three verbs it
was blocking do not need it any more.

*The finding, as written in Wave 9.* `cmd_place_road`, `cmd_place_water_main` and
`cmd_repair_building` were shipped, tested sim verbs with **no UI surface** (doc
92 §17.6). `GoalSystem` carried `stamp_road_tiles`, `place_water_main` and
`repair_buildings` as evaluator kinds and no level in `data/goals.json` used one.

This is a rule and not a note, because the failure mode is the worst one a
tutorial has: the game ends its eleven-step onboarding by pointing at a checklist
whose next item cannot be done.

*What Wave 10 shipped* (report 98 RR-30, doc 12 §2.7 / §2.9 deltas D-28…D-36):

| Verb | Door |
|---|---|
| `cmd_place_road` | build sheet ▸ **ROADS** tab ▸ `Street` / `Avenue`, drag-path |
| `cmd_upgrade_road` | ROADS ▸ `Widen` |
| `cmd_demolish_road` | ROADS ▸ `Remove` (quotes a refund) |
| `cmd_place_water_main` | infrastructure ▸ `Water Main` / `Trunk Main`, drag-path |
| `cmd_repair_building` | building panel ▸ actions row, **and** the upgrade checklist's `Fix this →` on `E_CONDITION` |
| `cmd_set_priority` | building panel ▸ actions row (doc 04 §2.4's four tiers) |
| `cmd_demolish_building` | building panel ▸ actions row, hold-to-confirm |

*The rule's teeth moved with it.* `tests/test_goals_system.gd`'s whitelist is now
the **full** evaluator table, so it can no longer catch the failure it was written
for on its own. A second assertion took over the job:
`test_every_evaluator_kind_is_accounted_for_by_a_surface` walks
`GoalSystem.EVENT_KINDS ∪ STATE_KINDS ∪ KIND_SURVIVE` and fails on any kind the
whitelist does not name. An evaluator written without a door now fails a test one
wave *earlier* than a goal row that names it — which is where the rule wanted to
be all along.

### G9. `place_water_main` stays reachable and unused (Wave 10)

*Filed as `G4`; **renumbered `G9` on 2026-08-21** — the Wave-10 block below is
headed `G4–G6` and claimed the same number. This ruling is the interloper (it
sits between G2 and G3 and belongs to no block), so it moves and the contiguous
range stays true. The five references rewritten with it: doc 91 §17.1 and
§17.4, doc 92 §17.6.1, §25.3 and §22.2.*

The curriculum gained `l3_streets` (4 tiles of street) and `l4_repairs` (2
repairs) the day their doors landed, and it did **not** gain a water-main row
even though `place_water_main` is now performable.

**The reason is pedagogical and it is measured.** Doc 05 §6's
`cmd_place_water_component` already runs a `service` lateral from the nearest live
main to every pump the player places — so at level 5, where the curriculum
teaches water, the taught action *already* connects itself and a main objective
would teach reach the city does not yet need. The `curriculum` agent confirms it:
across three seeds × 21 game-days it completes L5's $45,000 pump with **zero**
main tiles laid and doc 05's authored topology still covering the demand (doc 92
§23.3). A row asking for a main there would be busywork with a $286/tile price on
it.

The row becomes worth authoring the wave the water topology stops covering a
grown city — doc 92 §17.6's second named measurement, still open. Until then the
verb has a door, the evaluator has a surface, and the curriculum has a reason not
to use it.

### G3. The curriculum is five levels, and the sixth teaching beat is the tutorial

The ask was *"the first five or six levels"*. Doc 09 §2.11's ladder has **five**
rungs above the founding level, and a sixth would unlock nothing: every
`min_city_level` in `data/buildings.json` tops out at 4 and every land block's at
2, so a level-6 reward card would be empty. **A level whose reward card is empty
is a number, not a goal.** The sixth beat is the one that already existed — doc 12
§2.17's tutorial, which the sheet shows as level 0, complete, and which now hands
the player to the goals chip on its way out.

Adding a real rung 6 is a *content* decision (it needs something to pay out) and
is logged as the top open question of this wave.

## H. Wave-9 rulings — the router goes live, and the fine tick gets its cadence pass (2026-08-20)

Four things landed in one branch, for the same reason Wave 8's three did: they
all move state hashes and doc 08 §2.8's rung has to move once. Full rulings in
report 98 §17 (RR-26/27/28); balance in doc 92 §23; performance in doc 11
§2.13's Wave-9 subsection.

| | what | evidence |
|---|---|---|
| **Shipped** | **Doc 06 §2.10's terminal rule.** An incident with nothing committed to it for 24 game-hours — one game-day — becomes ABANDONED | `T = 24` is 1.77× the longest terminal path any ROW in `data/incidents.json` authors, and the binding row is a SUBTYPE (`storm_damage/roof_damage`, 13.574 gh at casual), so every authored `on_fail` still fires first and the neglect-fatal identity is untouched. Three rows authored **no** ending at all — `traffic_accident` and `storm_damage/blocked_road` above tier 2, and bare `storm_damage` at any tier — and they were the whole of Wave 8's unbounded backlog |
| **Shipped** | `max_acceptable_cost_min` **90 → 115**, re-fitted to street-true ETAs | `90 × 1.27`, the midpoint of doc 06 §1.1's measured +22–32 % shift. The full desperation stack leaves 35.5 gm of admissible ETA, just under §2.4's 39.3 gm tier-3 boundary |
| **Shipped** | **Doc 10's router is doc 06's ETA authority.** `CitySim._boot_incidents` constructs `RoadTravelTimeProvider` | the pin test is inverted: a regression to the Chebyshev stand-in now fails loudly. A four-arm ablation (doc 92 §23.3) shows what actually held it for two waves: **the seam ignored doc 06's `RouteProfile`** and priced every vehicle at 32 m/gm with no siren multiplier, so a responding patrol car ran 20 % slow on the department that answers most of the ambient load. Honouring the profile takes `greedy_growth` seed 4242 from **> 600 s to 11.2 s** with nothing else changed |
| **Shipped** | doc 91 D-15 **proposals 2 and 3** — the minute's roads work spread across the minute's four ticks; the power and water service ledgers banking per game-minute | doc 11 §2.13's Wave-9 table |
| **NOT shipped** | **hierarchical routing** | built, measured, rejected: it cost 9 % more time for 1.7 % fewer expansions on the benchmark city. Doc 10 §2.14's trigger measures six corner-to-corner routes; §2.14's own rank-then-quote contract means dispatch never pays for one, and the shipped seam call measures **0.709 ms** against a 1.5 ms target (RR-27) |

**Two defects the wave found, and one of them is the whole story.** (1)
`RoadTravelTimeProvider` ignored the profile doc 06 hands it and priced every
vehicle on one fixed `emergency(32.0)` — no per-type speed and no siren
multiplier, so a *responding* patrol car ran at 32 m/gm where §2.11 says 40, and
a construction crew at 32 where §2.11 says 18. **This, and not the missing
terminal rule, is what held the wiring for two waves** (doc 92 §23.3's ablation).
(2) `WaterServiceLedger.settle_hour` settled the
founding hour — fired by the EVERY_HOUR cadence before a single game-second had
been integrated — as a pressure factor of **0.0**, billing the starter city's
first hour as if it had no water. Invisible while the ledger banked every
SimTick; worth **$436** the moment it did not. Both are fixed at the source.

**§E2's anchors do not move.** The founding first-hour net and the first-day net
are unchanged and gates 1, 2 and 2b hold them to ±1 %. The water-ledger repair is
what keeps them there: without it the cadence change would have cost the founding
hour $436, which is a balance change nobody asked for wearing a performance
change's clothes.

> **SUPERSEDED by G6 (Wave 10).** The content landed. The curriculum is six
> levels, and G3's reasoning is the reason G6 exists rather than a claim G6
> contradicts: a sixth rung was refused **because it paid nothing**, and it is
> granted now **because it pays the tower tier**. The test G3 states — *a level
> whose reward card is empty is a number, not a goal* — is unchanged and is what
> G6 had to satisfy.

---

## G4–G6. Wave-10 rulings — the top of the ladder (2026-08-20)

### G4. Core Design Rule 5 is amended: five levels for every archetype, six for the growth stock

The rule read *"five levels per archetype"* and it was load-bearing in eleven
places. It now reads **five for every archetype, six for the six
revenue-producing ones** (doc 02 §2.14), and the boundary is not a preference —
it is the edge of what a buildings pass may touch:

* `water_facility`'s level ladder is **doc 05's**, five rows × five variants in
  `data/water.json`, behind that doc's own `levels_4_5_enabled` flag;
* `police_station` and `fire_station` fleet capacity is **doc 06's**
  `capacity_per_station_level`, five rows, locked by report 98 C-50;
* the two grid shells are priced off **doc 04's** `expenses.grid_components`.

A content wave that quietly grew those would be editing three other systems'
balance tables from behind. So the six that grew are exactly the six whose level
ladder doc 02 owns end to end, and they are named in **data**
(`building_rules.sixth_level_archetypes`), asserted at load, and cross-checked by
the shapes generator against the stat table so a mesh set and a stat row can
never disagree about how tall a ladder is.

**The consequence for callers is the ruling's teeth:** `catalog.max_level()` is
now the roster's TALLEST ladder and answers no useful question about a
particular building. Anything gating an upgrade, drawing a level strip or
reading a reward card must ask `catalog.max_level_of(archetype)` (or
`Building.max_level`, which the coordinator stamps beside `stats`). A literal
`5` — there were six of them — is how a police station gets offered a sixth rung
that does not exist, and how the tower tier stays invisible on the card that
announces it.

### G5. A sixth rung is generated by the fifth rung's curve, or it is not generated at all

Every cell of the new row is `round_rule(seed × k^5)` — doc 02 §2.2's family at
one more step, the §8 ladders applied once, half-up at every tie — and the same
rule extends doc 03's three money columns and `CAPITAL_VALUE_V`'s sixth cell
(100.929, the closed form half-up at 3 dp; doc 92 §23.4). **No cell in this wave
was placed by judgement.** That is report 98 RR-19's principle applied forward
rather than backward: the rules and the seeds are the single source of truth, so
the honest way to add a rung is to run the rules one step further and publish
whatever comes out — including a `data_center` that draws 43,150 kW, which is
not a mistake but the point of `k_dem > TAX_LEVEL_GROWTH`.

Two riders, both derivations rather than exceptions:

1. **The coverage ladder's sixth rung repeats its fifth.** Those columns are a
   demand ON the service stock; the service stock did not gain a rung (G4), and
   demanding coverage the player has no verb to buy is a wall with no door.
2. **The L5 rows gain the `upgrade_time_hours` they never had**, because they
   never had a next level to price. Same rule, `0.65 × build_time(6)`.

### G6. The sixth city level is granted, because there is now something to pay for it

Doc 09 §2.11's ladder gains a seventh rung at **18,000** and doc 09 §2.14's
curriculum gains a sixth row. Both are APPENDS: no rung below moved, and
appending above the top rung cannot un-earn a level in any existing save, which
is the only thing §2.11's monotonicity promise actually forbids.

**What pays for it**, and the reward-pacing ruling that spreads it: the sixth
building rung opens at **city level 4 for the `steady` class** (`house`, `store`)
and at **city level 5 for `standard` and `vertical`** (the towers), split by
growth class in data. City level 5's reward card was literally `{empty: true}`
before this wave — the goals sheet showed *"Nothing new to build"* as a reward —
and it now reads *"Upgrades to level 6"*, without one line of authored copy,
because doc 12 §2.19 rule 3 makes that card a READ.

**What does NOT pay for it, and why the answer is arithmetic:** the ask included
a ring-3 land tier gated at city level 4+. There is no ring 3 and there cannot be
one on this board — the 7 × 7 world is 9 core + 16 ring-1 + 24 ring-2 = 49
blocks, exactly, so ring 3 is the 9 × 9 shell and buying it means a new world
size, new block ids, a regenerated bench fixture and a re-anchored
`blocks_owned` escalation. Re-gating existing ring-2 land upward is refused for
the stronger reason: it would take purchasability away from a city that already
has it. Doc 09 §2.8.3 carries the full arithmetic.

**The pacing is measured, not asserted.** The taught route reaches level 6 on
game-hour 823 / 803 / 747 across doc 92's three seeds — 31.1 to 34.3 game-days —
and gate 21's horizon moves from 21 to 45 game-days with a ruled bound of 40.
Levels 1–5 land inside the windows Wave 9 already ruled: **the arc got longer at
the top, it did not get slower underneath**, and gate 21 now asserts level 5
separately so that stays provable.

## G7–G8. Wave-10 follow-up rulings — the upgrade clock and the curriculum beat (2026-08-20)

### G7. An upgrade step is priced on the row it starts FROM, and the binary now agrees with doc 02's own worked example

`CitySim.cmd_upgrade_building` read `upgrade_time_hours` from the row of the
level being upgraded **to**; doc 02 §2.2 stores the step `L → L+1` on the row
upgraded **from**, which is the shape `BuildingCatalog` validates at load (every
row below the top carries the column, the top row must not). Every upgrade in the
game except the last step of a ladder was therefore billed one rung too slow.
Reported as report 98 RR-29(h) and fixed as **RR-38**, with
`CitySim.SAVE_SECTION_VERSION` 4 → 5 and an identity migrator.

**The tell was already in the design document.** Doc 02 §2.10's worked example E3
prices an office **L4→L5** at *"`upgrade_time = 30 crew-hours`"* — which is the
L4 row's cell. The shipped binary read the L5 row and billed 47. A worked example
and the code it describes had disagreed by 57 % since the verb shipped, in a
document that gets read on every balance pass, and the way it was finally caught
was a reviewer following the *fallback* (RR-29(h)) rather than the value. **The
general lesson: when a doc has a worked example, the cheapest possible test is to
compute it from the shipped tables and assert the doc's number.**

### G8. A teaching band is a claim about the OPENING, not about every level

Doc 92 §22's *"levels 1–3 land inside a 10–40 game-hour band"* is retired for a
three-tier beat — opening (levels 1–2) ≤ 45 game-hours, middle (levels 3–4) ≤ 90,
finale (5–6) in game-days only — ruled in report 98 **RR-39** and derived in doc
92 §27.5. The decisive measurement is an ablation: **deleting the level-3
objective under suspicion entirely leaves level 3 at 44–48 game-hours, still over
a ceiling of 40**, so the objective was never what put it outside the band. The
band also printed a level at 41 one line under a sentence claiming everything was
inside 40, and had done since it was written.

**What survives is the claim worth keeping**: a player who has not yet decided to
keep the game must not be made to wait. That is the opening, and gate 21 now
asserts it in game-hours rather than leaving it to prose.

## J. Wave-11 rulings — the last two verb families get their doors (2026-08-20)

*Three questions this wave had to answer rather than defer. Two of them were
filed by the Wave-9 and Wave-10 agents as "this is a balance change, not a UI
change, and it wants its own pass"; the third had been an open row since doc 91
§14.5.*

### J1. There is no water-node panel, and there should not be one

**Ruled.** Doc 05 §6.1 and §B2 above have carried the same sentence since Wave 5:
`cmd_upgrade_water_component`, `cmd_isolate_water_main` and
`cmd_restore_water_main` "want a water-NODE panel, which nothing in doc 12's
screen map has yet". Doc 91 §14.5 D-4 carried the row. **The panel is not built.**

The reason is that the three verbs are not one screen's worth of anything. They
are two verbs at two moments, and the moments are what decide the surface:

| verb | when the player wants it | where it now is |
|---|---|---|
| `cmd_upgrade_water_component` | standing in front of a site that is short of capacity, with money | **S5, the building panel of the shell that hosts the node** — a block below §2.9 item 6's actions row, one row per node, each priced by the verb's own `preview = true` |
| `cmd_isolate_water_main` / `cmd_restore_water_main` | a main is open and a neighbourhood is losing pressure | **S6, the incident drawer's expanded row**, beside `ASSIGN`, on the one row that names a main |

Three things follow, and each is the reason the ruling is a ruling and not a
preference:

1. **A water site is already a building, and it already has a panel.**
   `cmd_place_water_component` builds three things at once (doc 05 §6.1): the
   doc-02 `water_facility` SHELL, the doc-05 NODE hosted on that shell's
   `power_ref`, and the lateral. The shell's panel is where the player already
   goes to read the site's condition, buy its repair and set its shed tier. A
   node ladder is another purchase against the same asset, so it goes under the
   same header. **The block is a LIST, not a row**: `WTR-1` hosts a source, a
   treatment train and a pump, and a panel that showed one of them would be
   lying about the other two.

2. **The shell's own `UPGRADE` and the node's are different purchases and are
   drawn as such.** Doc 02's ladder buys floorspace and doc 05's buys supply.
   They sit in two blocks with two headers rather than one button that would
   have to pick.

3. **Isolate/restore is not a panel verb at all.** Doc 05 §2.12 describes it as
   trading a neighbourhood's taps for the fire's hydrants — a decision taken
   under time pressure, about a MAIN. A main is not a thing the player can tap:
   it has no footprint, no panel, and doc 12's screen map has never had a way to
   select one. The only place a main is ever *named* to the player is doc 06's
   `water_main_break`, whose `target_ref` is `{kind: "water_segment", id}` — so
   the drawer row that is already telling them the main is open is where the
   valve goes. It is **one control in two moods** (`ISOLATE` while the main is
   live, `RESTORE` once it is valved out), because the two are never both
   available and a dead second button would sit on a 300 dp row for the whole
   life of the incident.

**The trap this ruling has to answer, and does.** A player who isolates a main
and then loses the row would have no way back to it. They cannot: doc 05's own
repair path (`WaterSystem.set_segment_repaired`) sets `state` back to `ok`, and
doc 06 calls it when the incident resolves. So the only mains reachable from the
drawer are ones that un-valve themselves when the crew finishes.
`tests/test_water_actions.gd` pins both halves.

**No save-section bump.** Isolation is doc 05 state and `WaterEdge.serialize()`
has carried `state` since Wave 1 — asserted, not assumed, by
`test_an_isolated_main_survives_a_save_round_trip`.

**One read-only sim change.** `IncidentSystem.snapshot()` now publishes
`target_ref`, which `incident_created` has always carried. Without it a UI that
came up on a loaded save — which replays no lifecycle event — knew a break's tier
and tile but not which main it was about. The save is `canonical_capture()`, not
the snapshot, so this moves no hash.

### J2. `route_feeder` is a run card on the INFRASTRUCTURE tab, and its geometry is doc 04's assist

**Ruled.** Doc 92 §25.7 deferred `cmd_route_feeder` with a precise reason: "it is
a run verb and the drag-path tool would take it in an afternoon — and §17.3 names
the 2 × 1,200 kW feeder ceiling as the late-game's binding constraint, so putting
it on a card is a **balance** change". Both halves are done in this wave; the
measurement is doc 92 §28. Three sub-rulings:

1. **The tab is `infrastructure`, not `roads`.** Doc 12 §2.7 files a run card by
   what it is made of, not by the tool that draws it. `PathTool` hosts road
   classes AND water mains today, and the mains sit on `infrastructure` beside
   the pumps they feed. A feeder belongs beside the transformer it roots, for
   the same reason and by the same rule.

2. **The class choice is two cards, not a picker.** `data/grid_components.json`
   offers conductor classes 1 and 2 (class 3 is deferred in doc 04 §6 and is
   refused with `E_CLASS_UNAVAILABLE`). Doc 12 §2.7 has no control for a per-card
   enum, and `Street`/`Avenue` and `Water Main`/`Trunk Main` already spell
   exactly this choice as two rows on one tab. `PathTool.available()` reads the
   roster, so a class the command would refuse never gets a card.

3. **A feeder run is drawn by doc 04 §4's assist, not by §2.7's L.** This is the
   one place a run card does not use `l_path`, and the reason is measured:
   `cmd_route_feeder` requires every tile to be on land that is owned and READY
   (§2.1), and a straight Chebyshev line between two owned blocks routinely
   crosses one the city does not own — doc 04 §4 records that as the whole of
   seed 4242's late-game routing failure. `CitySim.suggest_feeder_route` (report
   98 C-41) returns the shortest LEGAL run, which on doc 03 §2.13(b)'s per-tile
   price is also the cheapest, and falls back to the straight line when no legal
   run exists so the blocker the bar shows is still the honest one. The ghost
   therefore draws exactly the tiles the commit will lay, which is the ghost's
   standing contract.

**What the founding city answers, and why that is the design.** Doc 09 §2.9.5
gives SUB-A two feeder slots and fills both. So the player's first feeder run
answers `E_NO_SLOT`, and the copy names the purchase: *"SUB-A has no spare feeder
slot: 0 free of the 1 this run needs. Upgrade that substation, or build another
one and start the run there."* `Fix this →` flies the camera to SUB-A.

**And the loop that answer opens is complete**, which is checked rather than
assumed, by a test on the founding city
(`test_the_whole_feeder_loop_is_walkable_from_the_founding_city`): a `substation` card off
the Utility tab costs **$15,000**, is commissioned as a grid node **9 game-hours**
later by doc 04's `node_shells` mapping, and arrives with **2 free slots**; a
7-tile class-2 run off its fence line then quotes **$1,470**, commits, and
**adopts 6 transformers carrying 89.3 kW** off the circuit that was full. Two
purchases, both priced by doc 03, and §2.9's transfer rule is what makes the
second one relief rather than headroom for a city that does not exist yet.

### J3. Road repair stays the automatic policy's job — `cmd_road_repair` is not a player verb

**Ruled, and the row is closed.** `RoadNetwork.cmd_road_repair(tiles)` has had no
`CitySim` wrapper since Wave 5 and doc 10 §2.13 recorded it as an open question
(doc 91 §14.5, Wave-9 open q6). It stays that way, deliberately, and doc 10 now
says so. Four reasons, in the order they bind:

1. **Doc 10 already names the player's surface, and it is not this verb.** §2.12
   makes road condition a *policy*: `auto_repair_threshold` (0 / 0.25 / 0.40 /
   0.55) and `auto_repair_daily_cap` (default $25,000/game-day), which the doc
   itself calls "a **player budget setting**, not a price". The player-facing
   verb doc 10 authors is `set_auto_repair_policy`, not `road_repair`.

2. **The policy picks better runs than a thumb can.** Once per game-day it groups
   every tile below the threshold into contiguous runs and sorts them by
   `(mean congestion desc, condition asc)`. A player sweeping a run has none of
   that information: doc 12's overlay rail has no road-condition mode, so a
   REPAIR card would be a blind sweep whose ghost could not say which tiles it
   was billing for — which is exactly the contract §2.7's ghost has to keep, and
   the reason `road_remove` dims the tiles it will not touch.

3. **A manual verb would spend the same money outside the only cap on it.** Doc
   03 prices both paths with the same C-16 formula, so a manual repair buys
   nothing a policy repair does not. What it would add is a way around
   `auto_repair_daily_cap` — the one thing holding road repair inside doc 03's
   derived routine-repair expectation line (doc 10 §2.3's `0.28548`
   tile-fractions/game-hour). A verb whose only new effect is to break a budget
   is not a player verb.

4. **The building panel's REPAIR is not a precedent.** A building is a discrete
   asset the player taps and whose condition the panel already shows. A road tile
   is neither.

**~~What this leaves open~~ CLOSED, Wave 12.** `cmd_set_auto_repair_policy` has a
`CitySim` wrapper and two settings rows carrying `policy: "roads"` — the
mechanism this paragraph recommended, with one difference that belongs to the
command: it takes the threshold and the cap **together**, so a row change writes
the pair. The threshold row's ladder is `data/roads.json`'s own
`auto_repair_thresholds`, so a rung the command answers `E_BAD_THRESHOLD` for
cannot appear on the control. Doc 12 D-50 has the delta; doc 92 §30 has the
matrix, and it strengthens ruling J3 rather than weakening it: the per-tile
verb's only new effect would be a way around a daily cap that is now a number the
player *sets*, which makes routing around it worse than it was when the cap was
fixed. Doc 10 §9.4 question 5 is answered there too — at the default the policy
is dormant for a whole 21-game-day city and does not wake until roads pass 0.40.

## K. Wave-11 rulings — difficulty goes live (2026-08-20)

### K1. A city is FOUNDED on a difficulty and keeps it for life

**The question.** Doc 03 §2.9 shipped its four presets and, in the same
paragraph, two sentences about changing them: *"Difficulty may be raised at any
time. Lowering it is permitted at any time but sets `save.assisted = true`
permanently (excludes the city from any future leaderboard, spec §35)."* Doc 91
A91-D-19 asked for §2.9 to ship. Those two sentences are the part that cannot.

**Ruled: the preset is chosen once, when a city is founded, and is thereafter a
property of that city.** There is no `cmd_set_difficulty`, no settings control,
no `save.assisted` field, and the settings sheet reports the preset read-only.
The surface is one cycling chip on the front door, under NEW CITY
(`ui/title_screen.gd`), and `CitySim.found_with_difficulty()` refuses any call
after `tick_index == 0`.

**Three reasons, in the order they bind.**

1. **`save.assisted` is a flag for a leaderboard this game does not have.** Spec
   §35 hangs the whole "lowering is permitted" rule on excluding a city from
   *"any future leaderboard"* — and there is none, no plan for one inside Phase
   1–2, and doc 13 §11's monetisation boundary rules out the shape that usually
   pays for one. A permanent scarlet letter on a save, whose only consequence is
   exclusion from a feature that does not exist, is a punishment with no
   mechanism behind it. The honest options were to build the leaderboard or to
   drop the flag.

2. **A mid-city change re-prices a city the player has already paid for.** §2.9's
   own escape clause — *"multipliers apply from the moment of change;
   already-accrued treasury is untouched"* — protects the treasury and nothing
   else. Twelve of the sixteen knobs are not treasury: `starting_treasury` is
   meaningless after hour zero, `M_build` / `M_land` / `M_dev` / `M_repair` price
   the NEXT purchase against a city built at the old prices, `REV_FLOOR_FRACTION`
   and `CREDIT_APR_PER_GAME_DAY` change the floor a player is already standing
   on, and doc 07's four pressure knobs change the schedule of events already
   committed to the Director's timeline. Doc 92's `do_nothing` arc is the clearest
   case: a city founded on `crisis` is insolvent on game-day 35 and one founded on
   `casual` on game-day 109 (§29.2), and there is no defensible answer to *what
   day is a city that switched on day 30?*

3. **It is the only reading under which doc 92 means anything.** Every figure in
   that document is a measurement of a city played end to end on one preset. A
   save that can change preset mid-life is a save whose arc is not any of the four
   measured arcs, and gate 29's ordering — casual outlives standard outlives hard
   outlives crisis — stops being a statement about the game and becomes a
   statement about the last thing the player did in a menu.

**What this costs, said plainly.** A player who finds `crisis` too hard has to
start a city. That is a real cost and it is why the chip sits on the door with
the sentence *"A city keeps the difficulty it was founded on."* under it rather
than in a tooltip: the one moment the choice is reversible is before it is made.

**What it leaves open** is a genuinely smaller question, ranked with this wave's
others: **a NEW CITY FROM THIS ONE door** — found a city on a different preset
while keeping the outgoing one, which the title screen's archive plan
(`TitleModel.new_game_plan`) already performs for every other reason. Nothing in
this ruling blocks it and nothing in this wave builds it.

### K2. The preset rides the save section it is already in

**Ruled: doc 08 §2.8's city section v6 records the preset in `director.difficulty`
— the field that has carried it since doc 07 shipped — and does not add a second
copy at city level.** `CitySim._restore_difficulty` reads it back and re-pins the
treasury's economic row, the Director's pressure knobs and doc 06's escalation
pair.

Two reasons, and the second is the harder one.

1. **Two records of one fact is the scattering C-17 exists to stop.** A
   `policy.difficulty` beside `director.difficulty` is a divergence waiting for
   the first migrator that touches one of them.
2. **A new key would move `state_hash()` on the DEFAULT preset**, and the whole
   claim of this pass is that `standard` reproduces the pre-difficulty binary
   bit-for-bit. `state_hash()` is SHA-256 over `canonical_capture()`; a key added
   to that dictionary changes the bytes whether or not it changes the game. The
   rule "hashes move only behind non-default presets" and the rule "the preset is
   part of the city" are compatible in exactly one way, and this is it.

**The cost, and it is real:** a reader looking for the city's difficulty in a
save will look for a top-level key and not find one. That is why `_v5_to_v6`,
`_restore_difficulty` and this ruling all say where it is instead.

## L. Wave-11 rulings — the event matrix gets a rule (2026-08-20)

### L1. An event that describes a PLAYER-VISIBLE state change needs a consumer or a written exemption; everything else needs one line, and a RENDERER counts as a consumer

**The problem this is a ruling about.** Doc 91 §18 counted every event type
`sim/` emits and crossed it against every consumer in the tree, and the headline
was *43 consumed by nothing at all*. A number like that is unusable as a rule.
Some of the 43 are whole shipped features nobody can see (`flood_level_changed`,
A91-D-26); most are a substation's cascade trace, a treasury credit, a scheduler
phase boundary — things that do not describe anything the player could be shown.
"Wire all 43" would bury the alerts feed in bookkeeping. "Wire the important
ones" is not a rule at all. So the audit's open question 3 asked for the
narrowing, and this is it.

**The rule.**

> **Every event whose payload describes a PLAYER-VISIBLE state change must have a
> consumer or a written exemption. Every other event carries a one-line
> classification, and no consumer is expected of it.**

**And the sentence that makes it affordable: a RENDERER is a consumer.** This is
the half that turns the rule from an alerts-feed mandate into a design
principle. Doc 07 §2.4's flood has five bands. The 40 mm nuisance band — a film
of water in the gutters — is drawn by `game/render/flood_view.gd` and is
narrated by nothing, for ever. The 100 mm and 200 mm bands, where vehicles start
stalling and civilian traffic is turned back, are drawn AND logged AND pushed.
The principle in one line, and it applies well past floods:

> **Narrate the bands that change what the player can DO. Draw the ones that only
> change how the city looks.**

**The classification vocabulary is seven words** — `covered`, `player_initiated`,
`bookkeeping`, `invisible_by_design`, `measurement`, `unreachable`,
`not_an_event` — and a row must pick one and then say WHY. `bookkeeping` on its
own is not an argument; the test enforces a minimum length on the reason for
exactly that reason. Doc 91 §18.2 carries the table.

**Where the register lives, and why it is not a doc.** In
`tests/test_event_matrix.gd`, as a `const REGISTER`. It could have been a
markdown table, and a markdown table is what went stale: A91-D-26's list of 43
was wrong by three rows within a week of being written, because three of the
events acquired a `main.gd` arm the next day. The register is a test fixture so
that **adding an emit without adding either a consumer or a row fails the
suite**, and so that a row for an event that has since been wired ALSO fails —
an exemption that has stopped being true is a line of prose nobody re-read.

**What this ruling explicitly does not do.** It does not license a sim change to
make an event nicer to consume. Every wiring done under it in Wave 11 is
render/UI/audio only — `game/render/flood_view.gd`, rows in
`data/ui.json.event_log.events` and `data/notifications.json.bindings`, copy in
`data/strings.en.json`, one toast in `ui/ui_root.gd`. Both cities' state hashes
are unchanged (report 98 RR-53). **If an event's payload is the wrong shape to
consume, that is a defect id, not a licence.**

**Honest limit, recorded so it is not rediscovered.** The emit scan is a regex
over source and fails OPEN: `bus.emit(kind_variable, …)` is invisible to it. Doc
91 §18.3 said so before the test existed and the test's own header says so now.
The direction that fails CLOSED is the other one — every type the two data
routers name must be emitted — and that is the RR-1 failure mode, copy wired to
an event nobody sends, which renders as silence.

## M. Wave-13 rulings — a consequence that makes more of itself is a rate, and rates need ceilings (2026-08-20)

### M1. A cascade is a BRANCHING PROCESS, and every automatic birth answers to one ceiling

**The problem this is a ruling about.** Doc 06 §2.7's cascades are the best thing
in the crisis loop: a fire that takes the building down blocks the road, a
transformer that dies takes a house with it, a riot that nobody polices becomes
two riots. They are data — Constitution §8 — and adding one costs no code. That
is exactly why nobody counted them. `data/incidents.json` authors **eight**
incident-spawning cascade actions; five of them resolve to a BUILDING and take it
off the board, which makes them self-limiting the way fire spread is. Three do
not, and one row (`crime`) owns two: one child at tier 4 and two more at tier 5.

Three children per parent is not a consequence. It is a **reproduction rate**,
and a reproduction rate above 1 with no ceiling is a population, not a game
event. Doc 06 §2.10.1 had already bounded how long an unanswered incident LIVES
(RR-26, 24 game-hours) and published the resulting backlog ceiling as
`arrival_rate × T`. That ceiling is exactly right and it silently assumes
arrivals come from outside the roster. Measured: a `crisis` `do_nothing` city
reached **89,055 open incidents**, multiplying ~2.8× per game-hour, with every
single one of them terminating on schedule under RR-26.

**The rule.**

> **Any action that creates an incident from an incident is a rate, not an
> effect. Its expected offspring must be counted when it is authored, and every
> automatic birth in the system — ambient generation, fire spread, and cascade
> spawns alike — answers to ONE published roster ceiling.**

**And the sentence that makes it a design rule rather than a clamp: a cascade
that CONSUMES its subject is self-limiting; a cascade that does not is a
population.** Fire spread has the same shape as the crime cascade and has never
run away, because every ignition takes an eligible building off the board and
buildings run out. `crime`'s `scope: "district"` takes nothing off the board —
a district can host any number of crimes about nothing — so the same arithmetic
diverges. When authoring a cascade, name what it consumes. If the answer is
"nothing", it is a rate and it needs the ceiling.

**Second half, and it is the one that fixed the measured case: a cascade may not
invent a subject the GENERATOR would not have found.** Doc 92 §18 already states
this for the ambient floor — *"λ_natural ≤ 0 means the channel scanned and found
no eligible candidate … it changes how OFTEN, never WHERE"* — and the
building-scoped cascades already obeyed it. The district-scoped one did not,
because it needs no entity at all. The 89,055 were crimes in a district whose
population had been zero since the cascade's first game-hour.

**What this ruling explicitly does not do.** It does not retune a single
consequence. Every `on_tier_enter` and `on_fail` list in `data/incidents.json` is
unchanged, and so is every escalation constant: neglect is exactly as fatal on
every preset as it was, gate 29 holds every threshold it had — its pinned
`standard` insolvency day and its strict four-preset ordering included — and the
whole doc 92 strategy matrix — which peaks at **13** open incidents against a
knee of 26 — is byte-identical. **A ceiling that a played city can feel is a
retune wearing a safety rule's clothes**, which is why the knee was placed at the
worst backlog the matrix has ever measured rather than at a round number.

**Honest limit, recorded so it is not rediscovered.** `traffic_accident`'s tier-5
cascade is `scope: "adjacent_edge"` with `count: 1` — expected offspring exactly
**1**, the critical case — and it also invents its subject (the child lands on the
parent's own tile). It does not diverge, but it does not die either: on a
200-game-day `crisis` run it is what pins the roster at the ceiling from game-day
160 onward. The ceiling bounds it correctly and it costs 66–73 ms per game-hour
to carry, against 5.8 ms for the quiet city. That is a **rate that should
probably consume a road**, and it is doc 06's ranked open question rather than
this ruling's business.

## N. Wave-12 rulings — the difficulty follow-through (2026-08-20)

*Doc 92 §29.5 closed with four ranked questions it deliberately did not answer,
and one of them (`E_roads_repair`'s double knob) it called "48 % of the whole
difficulty delta on the expense side". These are the four answers. Doc 92 §31
carries the measurements; this section carries the reasons. **Everything here is
hash-neutral on the default preset by construction** — every knob involved is
1.00 on `standard` — and doc 92 §32.1 proves it three ways.*

### N1. `E_roads_repair` takes ONE difficulty knob, and it is `M_repair`

**Ruled.** `EconomySystem.settle_hour()` computes `e_roads_repair(roads,
M_repair)` and then **excludes that line from the `M_exp` sweep**, exactly the
way `E_debt` is already excluded. Doc 03 §2.4's "All × `M_exp` except `E_debt`
and `E_oneoff`" gains a third exception and says why.

Doc 92 §29.2(b) measured the defect and did not rule on it: `roads_repair` was
the only line in the ledger taking `M_repair × M_exp`, **2.0000 on `crisis`
against 1.2500 on the other seven**, and at $157.90/gh it is 31.3 % of the
`standard` founding expense — $118.43/gh of the $244.47/gh separating crisis's
founding expense from standard's. §29.2(b) called the compounding *arguable*
because `E_roads_repair` is genuinely both a recurring line (§2.4) and a repair
price (§2.5). It is not arguable any more, for four reasons in the order they
bind:

1. **The accrual and the payment disagreed, and only one of them can be right.**
   Doc 03 §2.4 is explicit that this line "is not a separate charge — it is the
   *accrual* the auto-repair policy realises as lumpy `E_oneoff` repair jobs",
   and that `ExpenseLedger` reconciles the accrual against actual repair spend.
   What the policy actually pays is `CostCurves.repair_cost_road(class,
   damage_fraction, M_repair)` — **`M_repair` and no `M_exp` anywhere in it**. So
   on `crisis` the ledger accrued 1.25× what the same tiles cost to fix. An
   accrual that does not converge on the payment it is accruing for is the
   double-count C-07 / C-08 / C-12 / RR-2 keep removing, one knob down.

2. **`E_debt`'s exclusion is the same argument, already written.** `settle_hour`
   documents E_debt as carrying "its own difficulty term (the APR)" and not being
   scaled by `M_exp`. `E_roads_repair` carries its own difficulty term too, and it
   is named in doc 03 §2.4's own formula: `× REPAIR_COST_PER_CAPITAL × M_repair`.
   A line whose formula names a knob does not also take the sweep.

3. **The knob it kept is the knob the doc authored.** `M_repair` runs 0.70 → 1.60
   casual→crisis; `M_exp` runs 0.85 → 1.25. The compound ran 0.595 → 2.000, a
   **3.36× spread** where the widest single knob in the `economic` row spans
   2.29×. Nobody authored a 3.36× knob; it was the product of two.

4. **It is free on the default preset.** Both knobs are 1.00 on `standard`, so
   the line's arithmetic is unmoved and every hash, every gate threshold and every
   published `standard` table stands. Doc 92 §32.1 proves it on the two state
   hashes, on all 63 cells of the seven-strategy matrix, and — the one that
   matters most — on 76 game-days of a decaying `do_nothing` city whose
   insolvency day did not move by one.

**What it costs, said plainly.** Three of the four presets moved and that is the
point of moving it: `casual` got harder (its road bill rises 0.595× → 0.700× of
standard's, and its `do_nothing` rope shortens 109–116 → 104–110 game-days),
`hard` and `crisis` got easier (1.512× → 1.350×, 2.000× → 1.600×; ropes 52–53 →
56–57 and 34–35 → 40–42). The ordering casual > standard > hard > crisis holds on
every seed, which is gate 29's actual assertion. Doc 92 §32.5 has both columns.

**One arithmetic correction this ruling forces.** §29.5(a) step 2 predicted
crisis's founding net would move −$18.70 → **+$99.73/gh**. It will not: that line
computed the un-compounded road bill as `157.90 × 1.25` — `M_exp` — where the
ruling applies `M_repair`, `157.90 × 1.60`. Measured, the answer is
**+$44.47/gh** (casual +$547.63, hard +$180.88, standard unmoved at +$337.05).
Positive, which is what §29.5's ranked item 3 was waiting on; smaller than
advertised, which is why item 3 gets a real answer below instead of "the question
answered itself".

### N2. `M_rev` is the TAX multiplier, and §2.9's table row is corrected to say so

**Ruled: the code is right and the label is wrong.** `M_rev` reaches
`EconomySystem.revenue_for_building()` and nothing else. Doc 03 §2.9's table row
`M_rev` **revenue** becomes `M_rev` **tax revenue**, and the section publishes the
measured effective figure beside the advertised one. No line of `sim/` moves.

Doc 92 §29.2(a) found the gap by solving the four founding gross figures for a
tax/non-tax split — $741.80 tax and $99.42 non-tax per game-hour — and observing
that crisis's advertised −15 % measures **−13.2 %**. `tools/measure_founding_ledger.gd`
now reads the same split straight off the settlement snapshot and reproduces it to
the cent. The full correction, which §2.9 now prints:

| preset | advertised `M_rev` | measured effect on GROSS revenue |
|---|---|---|
| `casual` | +15 % | **+13.23 %** |
| `standard` | — | — |
| `hard` | −8 % | **−7.05 %** |
| `crisis` | −15 % | **−13.23 %** |

Symmetric, because the non-tax share is the same on every preset: **11.82 % of
founding gross**.

Four reasons the scope stays where it is:

1. **Doc 03 defines the knob twice and both definitions say tax.** §2.2's
   per-building formula ends `× M_rev[difficulty]`, and §2.2's revenue-floor
   formula repeats it inside `R_potential_city = Σ base_tax(b) × occ_b ×
   tax_policy_factor × M_rev`. §2.5 — which authors *every* non-tax line: power
   tariff, water tariff, fines, the post-MVP event gate — never mentions it. One
   summary-table row label disagrees with two formulas. The label is what moves.

2. **The other revenue knob in the same row is tax-scoped by construction.**
   `REV_FLOOR_FRACTION` (0.25 → 0.10) is a fraction of *potential tax*, and doc 03
   §2.10 layer 1's whole promise — "the treasury can never be driven to literally
   zero income" — is computed on that base. Widening `M_rev` would leave the
   `economic` row carrying two knobs whose names both say "revenue" at two scopes
   11.8 % apart, and §2.10's ladder arithmetic would stop being checkable against
   either.

3. **Two of the three non-tax lines are HELD CONSTANTS, and you cannot
   difficulty-scale a seam.** `CitySim.HELD_DELIVERED_MWH = 1.5` and
   `HELD_FINE_RATE = 3/350` are doc 03 §9 item 6b's held metering pair, standing
   in until doc 04 meters delivered energy and doc 06 meters resolutions. Measured
   on a `do_nothing` city, `power_tariff` is **$93.00/gh and `fines` $3.00/gh on
   all four presets** at the founding hour, at 21 game-days, and at 48 game-days
   of total neglect — they do not move because there is nothing behind them yet to
   move. A `× M_rev` on those two would make 88 % of the advertised revenue
   difficulty a property of a placeholder. The only live non-tax line is
   `water_tariff`, at **$3.42/gh — 0.41 % of founding gross.**

4. **The re-open condition is written down rather than implied.** When doc 04
   §2.4 publishes real `delivered_mwh` and doc 06 publishes real resolutions, the
   two lines become measurements of a city under pressure, and the question
   "should a revenue multiplier reach them" becomes a different question with a
   different answer. It is ranked in doc 92 §32.7, not buried here.

**Given teeth:** `tests/test_economy.gd::test_one_difficulty_knob_per_ledger_line`
settles the founding ledger on all four live `data/difficulty.json` rows and
asserts, per preset, that the seven swept lines are exactly `M_exp`,
`roads_repair` is exactly `M_repair` (and explicitly **not** `M_repair × M_exp`),
`debt` is neither, `tax` is exactly `M_rev`, and `power_tariff` / `water_tariff` /
`fines` are exactly 1.000. It reads the live file, so a retune moves with the
file and only a change of SCOPE fails.

### N3. `cmd_install_backup_generator` is doc 05's INTERFACE CALL, not a player verb

**Ruled, and the row is closed with a re-open condition.**
`WaterSystem.cmd_install_backup_generator(node_id)` keeps no `CitySim` wrapper,
no card and no matrix row — **until doc 04 ships the generator it delegates to.**
Doc 91 §17.2's open count drops from seven to six.

The same four-question frame §J3 used, answered against this verb:

1. **Does the owning doc name this as the player's surface?** No — it names the
   opposite. Doc 05 §2.6 (report 98 C-36): *"Doc 04 owns the generator itself:
   fuel, burn rate, tank size, start delay, refuelling, its save state and its
   events."* Doc 05 §9's own command list describes this one as *"validates the
   node, then delegates sizing, fuel and refuelling to doc 04"*, and the method
   returns `backup_spec(node_id)` — `{kw_required, backup_kw, coverage_frac}`,
   three numbers published to another document. That is an interface call. The
   player-facing verb for a generator is doc 04 §4's `place_backup_gen`.

2. **Does the thing it delegates to exist?** No, and doc 04 says so twice. §12's
   **Deferred** list names "backup generators"; §6's still-unshipped list names
   `place_backup_gen`. `grep -rn fuel sim/power/` returns nothing at all (doc 91
   row 2.10, re-verified at this fork). The delegation has no delegate.

3. **What would the card actually sell?** A free, permanent removal of the water
   system's only power-failure mode. The command sets `backup_installed = true`
   and debits **no dollar**: `WaterSystem.power_fraction_of` then answers
   `coverage_frac_for(level)` — 0.60 / 0.70 / 0.85 / 1.00 at L2–L5 — instead of
   0.0 whenever the node goes dark, forever, with no capital price (doc 04 §8's
   `backup_gen` tiers carry no price row in this repository, by C-07/C-12), no
   tank, no burn and no refuel. Doc 03 §2.5's discipline is that *prevention wins
   and prevention costs*; half a feature that grants the benefit and prices none
   of it is not a door, it is a cheat.

4. **Does the precedent hold?** It runs the other way from §J3's, and that
   difference is the ruling's shape. `cmd_road_repair` is closed **permanently**
   because doc 10 already authors a better surface. This one is closed **for
   now**: the day doc 04 §2.10 ships capital price, tank, burn rate and
   refuelling, `place_backup_gen` gets the door and this call stays exactly what
   it is — doc 05 handing doc 04 three numbers.

**What ships:** nothing in `sim/`. Doc 05 §9 gains a sentence, doc 91 §17.2's row
moves from *open* to *ruled*, and doc 92 §32.6 carries it.

### N4. `Balanced`'s reserve floor is a fraction of the founding purse — and it was never the thing that froze `crisis`

**Ruled, and the second half is the finding.** `tools/playtest.gd`'s
`Balanced.RESERVE_FLOOR := 12_000` becomes
`RESERVE_FLOOR_FRACTION := 0.48` of the city's own `starting_treasury`,
resolved once from `Treasury.difficulty()` — the row the city was *founded* on
(§K1), so a strategy driving a restored save gets the right purse. `12,000 /
25,000 = 0.48` reproduces `standard` **to the dollar**; the other three become
$16,800 / $8,640 / $5,760. Doc 92 §29.5's ranked item 4 is right about the
principle — *an agent whose reserve is a constant cannot measure a difficulty
that scales the purse* — and this closes it.

**It is not, however, what §29.5(a) step 3 said it was.** That paragraph blamed
the flat floor for the frozen crisis agent; the arithmetic in the same paragraph
shows the other term binding. The agent holds `max(floor, one game-day of
expense)`, and on crisis the payroll term was **$17,968** against a $12,000
purse — the floor never entered the maximum. Measured after §N1, the two terms
are $5,760 and $16,452, and the payroll still wins. What actually unfroze the
agent was **§N1**: `crisis`'s founding net moved −$18.70/gh → +$44.47/gh, so the
gap between purse and reserve stopped being permanent, and `balanced` went from
**0 buildings on all three seeds** to placing. Doc 92 §32.4 has the arm.

**The residual, ranked rather than fixed.** The founding purse buys **3.60 /
2.07 / 1.25 / 0.729** game-days of the founding city's own expense across the
four presets — `crisis` is the only preset handed a city it cannot pay the bills
on for one game-day out of the purse it comes with. That is a statement about the
purse (doc 92 §29.5 ranked item 3), and this wave does **not** move it: item 3's
own trigger was "if crisis still founds negative", and after §N1 it founds
positive. The coverage ratio is the better test and it belongs to whoever rules
on the purse; doc 92 §32.7 ranks it first.

## O. Wave-14 rulings — the two dead traffic inputs, and the cadence that is not a cadence (2026-08-21)

Doc 10 §2.10 and §2.12 read two things through injected `Callable`s: doc 09's
per-district land-use weights and doc 07's weather state. **`CitySim` assigned
neither, on any path, for the life of the project** (report 98 RR-69, doc 91
A91-D-32). Both fields had a well-defined degraded default on the other side —
one authored profile row, and the literal string `"clear"` — which is why the
gap survived thirteen waves of audit: every consumer got a plausible number.
Three things had to be ruled to close it.

### O1. A derived quantity's refresh grain is its INPUTS' revision, not a timer

Doc 10 §2.10 said `profile_weights` is *"recomputed once per game-day"*. It is
now **derived**, and `CitySim` keys the rebuild on `(roster_revision,
districts.membership_revision)` — the same shape `district_of_building()` has
carried since Wave 9. The ruling, stated generally because it will be met again:

> **When a value is a pure function of state that already carries a revision
> counter, memoise it on that counter. Do not give it a cadence.** A cadence is a
> second thing that has to be proved bit-identical between the fine and the
> coarse path, it recomputes when nothing moved, and — the decisive one — it needs
> a hook on the RESTORE path that a future wave can forget. A revision memo cannot
> be forgotten: the counter moves during the restore, so the first reader after a
> load rebuilds from the roster the save carried.

Three consequences worth naming. (a) A block that develops mid-game shifts its
district's rush hour on the pass after the building lands, not at the next
midnight — which is doc 09's grain (a district *aggregates*) and matches doc 10's
own treatment of the sibling term `L_dens`, refreshed on `building_changed`.
(b) The weights are neither serialized nor hashed; `DistrictRegistry.deserialize`
**drops** the live row rather than keeping a stale one alive. (c) There is no
save-section rung in this wave, because no persisted shape changed.

### O2. Mode invariance for the weather → roads seam, stated per system (§E2)

§E2 ruled that mode-invariance is claimed **per system**. This is the roads-vs-doc-07 claim, and it has two halves that are deliberately not the same strength:

| quantity | claim | why |
|---|---|---|
| `wx_wear_day`, and therefore daily condition decay | **bit-identical** between the fine and coarse paths | doc 07's `_sync_clock` derives `now_min` from `ctx.tick_index` alone, and roads samples its daily wear accumulator at the top of each game-hour in **both** modes — so the two paths read `get_state()` at the same game-minutes, and take the same `max` over the same 24 samples |
| within-hour `c_e` | **bounded by one coarse step** | a doc 07 segment boundary inside a coarse hour is priced at the hour's opening state by the coarse path and at the tick's own state by the fine one. `c_e` re-converges within the next step because the smoother lands on `c_raw` |

The second row is sanctioned in exactly the class §E2 already sanctions — doc 06
§2.6's Poisson counts per step size, doc 04 §2.12's one-step coarse thermal
integration — and it is *smaller* than either, because roads' congestion has no
memory beyond the smoother. **Save→load→advance identity is untouched and stays
exact and whole-hash**: a save taken in the rain restores into the same rain
(doc 07 §3.2 persists the timeline and the segment cursor), and the derived
weights come back from the roster. `tests/test_roads_integration.gd::test_the_weather_seam_is_mode_invariant_while_the_sky_holds`
and `tests/test_city_sim.gd::test_the_land_use_weights_survive_a_restore_identically`
are the assertions.

### O3. A category fold is read off what the CURVE means, not off the category's name

Doc 02 has five archetype categories and doc 10 has four land-use curves, so
somebody had to write the fold. `utility` — power plant, substation, water works
— folds onto **`ind`**, not onto `civ`, and the argument is doc 10's own prose:
`ind` is *"flat-shifted, peaking 16:00 and never below 0.18 overnight"*, which is
a continuously-staffed plant, while `civ` *"peaks 07:00 and 15:00 for school and
shift changes"*, which is the emergency-service watch change that `service`
actually is. Utilities are also industrial land use in any zoning taxonomy.

The check that this is not a rationalisation: with `utility → civ`, the founding
city's `ind` weight is **0.000 in all four districts** — doc 10's `ind` curve
would have been authored-and-dead on the very wave that exists to end
authored-and-dead rows. With `utility → ind` the Foundry reads `ind 0.667` and
wants 2.7× the road at 02:30 that the commercial core does. **A fold that leaves
one of the four curves at zero everywhere is the wrong fold**, and that is the
cheap test to apply the next time one is written.

## P. Wave-13 rulings — the last two open questions in the ledger (2026-08-21)

*Two questions that had each survived a wave by being ranked rather than
answered. Neither needed a measurement — both measurements already existed — so
both are settled here on the lead's proxy, and both are recorded with the
counterfactual they declined so the next reader can see what was weighed. The
binding form of each is report 98 **RR-69** and **RR-70**.*

### P1. The founding purse is a RESERVE, not an operating budget — `crisis`'s 0.729 game-days is the ruled knife-edge

**Ruled: `data/difficulty.json` `economic.crisis.starting_treasury` stays at
$12,000.** Doc 92 §32.7 ranked item 1 asked whether `crisis` gets a bigger purse
or whether 0.729 game-days of coverage is the point. It is the point. Zero bytes
of data move, so the ruling is hash-neutral by construction on every preset, not
merely on the default.

**The measurement, re-taken at this fork** (`tools/measure_founding_ledger.gd
--hours=1`, which reproduces §32.2's table to the cent — every revenue line,
every one of the eight expense lines, every net):

| preset | purse | expense $/gh | one game-day of expense | **purse ÷ game-day** | rung |
|---|---|---|---|---|---|
| `casual` | 35,000 | 404.86 | 9,716.64 | **3.6021** | — |
| `standard` | 25,000 | 504.18 | 12,100.32 | **2.0661** | 1.7434× |
| `hard` | 18,000 | 601.00 | 14,424.00 | **1.2479** | 1.6556× |
| `crisis` | 12,000 | 685.49 | 16,451.76 | **0.7294** | 1.7109× |

**Four reasons, in order of weight.**

1. **The founding city pays its own bills on every preset, `crisis` included.**
   §32.2's own row: gross 729.95, expense 685.49, **net +$44.47/gh**. The purse
   is not what the bills are paid out of — the city's revenue is — so "a city
   that cannot pay a day's bills" is not what 0.729 measures. It measures how
   deep the *reserve* is, which is a different and much better question.
2. **A `crisis` city left completely alone GROWS the purse it was handed.**
   `tools/measure_insolvency.gd --presets=crisis,hard --max-days=70`, re-taken at
   this fork and reproducing §32.5 seed for seed: `crisis` peaks at **$20,657 on
   game-day 10** — the $12,000 purse is up **72 %** — and does not close negative
   until game-day **41 / 42 / 40**. §32.3 measures **zero** `credit_line_engaged`
   events on `crisis` over 21 game-days on all three seeds. A purse that is never
   drawn down inside three game-weeks is not a purse the city cannot live on.
3. **The coverage ladder is the most regular ladder in `data/difficulty.json`,
   and $12,000 is the purse it predicts.** The three rungs are 1.7434 / 1.6556 /
   1.7109 — mean **1.703**, span ±2.6 %. **Nobody fitted that, and the
   decomposition is the proof**: a coverage rung is the purse rung times the
   inverse expense rung, and *neither factor is even on its own* —

   | rung | purse ratio | expense ratio | **product = coverage rung** |
   |---|---|---|---|
   | `casual` → `standard` | 35,000 / 25,000 = **1.4000** | 504.18 / 404.86 = **1.2453** | **1.7434** |
   | `standard` → `hard` | 25,000 / 18,000 = **1.3889** | 601.00 / 504.18 = **1.1920** | **1.6556** |
   | `hard` → `crisis` | 18,000 / 12,000 = **1.5000** | 685.49 / 601.00 = **1.1406** | **1.7109** |

   The purse column spans 1.389–1.500 and the expense column 1.141–1.245; the
   product of the two spans 1.656–1.743. Two ladders authored in two different
   places by two different rules multiply to something flatter than either, which
   is what a coherent difficulty curve looks like and is not what an accident
   looks like. And the prediction is not
   circular: take the mean of the two rungs `crisis` is not in (1.7434, 1.6556 →
   **1.6995**), extend it one rung past `hard`, and it lands on **0.7343
   game-days = $12,080**. The authored value is $12,000 — **0.66 % below the
   ladder's own extrapolation of itself.** The counterfactual is derived rather
   than waved at: **$16,452** buys exactly 1.000 game-days and keeps
   `starting_treasury` strictly monotone-down (35,000 > 25,000 > 18,000 >
   16,452, so doc 03 §3.4 rule 4's monotonicity check — enforced by
   `Difficulty._check_monotonicity` against the `_direction` map, which lists
   `starting_treasury: "down"` — still passes), but it turns the last rung into
   **1.2479** —
   27 % off the ladder, **ten times the ladder's own spread** — and flattens the
   purse rung from 1.3889× to 1.0941× against `hard`. A repair that breaks the
   only even ladder in the table, to reach a number the table itself does not
   predict, is not a repair.
4. **Nothing in the shipped game reads "one game-day of expense".** `grep -rn
   RESERVE_DAYS_OF_EXPENSE sim/ game/ ui/ data/` returns **nothing**; the only
   two hits in the repository are `tools/playtest.gd:1606` (the constant, `:=
   1.0`) and `:1885`, where `operating_reserve()` is `max(floor, one game-day of
   expense)`. That is a **harness** heuristic, and §N4 already ruled on it once.
   The 1.0 line is the scripted agent's private opinion about prudence, not a
   threshold the city, the treasury, the credit ladder or any UI compares
   anything to. Tuning `data/difficulty.json` to satisfy it would be tuning the
   game to the test.

**And `crisis` is defined by the absence of cushions, in four knobs authored
together.** This is why the purse being the shallowest reserve in the table is
coherent rather than accidental — read the crisis column of `data/difficulty.json`
down:

| knob | standard | crisis | crisis ÷ standard | what it removes |
|---|---|---|---|---|
| `starting_treasury` | 25,000 | 12,000 | **0.48** | the reserve. The largest single departure in the row — every multiplier in it is 0.85–1.60 |
| `REV_FLOOR_FRACTION` | 0.18 | 0.10 | 0.556 | the revenue floor under a collapsing tax base (`economy_system.gd:335`) |
| `relief_grants_per_era` | 3 | **0** | — | the only preset with **no** State Emergency Assistance at all (`treasury.gd:270`) |
| `soft_suppression` | true | **false** | — | the only preset without doc 07 F5's earned suppression (`disaster_director.gd:196`) |

Three of those four are already absolutes rather than scales. The purse is the
fourth statement of the same sentence, and the sentence is *on `crisis` there is
no net*. Doc 92 §32.5's ordering says the same thing in game-days: each rung buys
about 1.36× the next one's rope, and `crisis`'s rope is 41 game-days.

**The re-open condition, written down so this stops being re-asked.** Move
`starting_treasury` when — and only when — a measurement shows that a *player*
(not `tools/playtest.gd`'s agent) cannot take the first meaningful action on
`crisis` inside the founding session. The measurement that would show it is a
`curriculum`-strategy arm on `crisis` failing doc 09 §2.14's level-1 objectives
inside gate 21's horizon; the current evidence points the other way, since §32.3
puts `balanced` on `crisis` at 0 placed for a reason §32.4 traces to the harness
reserve rather than to the purse. If it is ever moved, the number is **$16,452**
— one game-day, derived above — and what the change has to re-prove is gate 29:
strict ordering on every seed, finiteness, the 25–118 game-day band, and
`standard` pinned at 76 ± 6. Nothing else in the file may move with it, because
`starting_treasury` is the one economic knob whose direction the other eleven do
not depend on.

### P2. A SECTION rung is sufficient when the body's shape holds — and `city.section_version` records what the CITY section owns

**Ruled: there is no `city.section_version` 6 → 7 for the Wave-13 water and
roads rungs, and doc 08 §2.8 now says so in its own text rather than in a note
under one shipment.** The question — raised as the Wave-12/13 roads deviation 2,
and re-raised every time a sibling section takes bytes — is whether
`water.section_version` 2 → 3 and `roads.section_version` 2 → 3 (report 98 §26
RR-60 / RR-60b) needed a city-body rung as an epoch marker beside them.

**The doc decides, and it decided before the question was asked.** §2.8's second
bullet is the whole answer and it is one sentence: *"`section_version` (int)
inside every section — owned by that section's system, with its own independent
ladder. **Adding a field to `power` bumps `power.section_version`, not the
envelope.**"* A per-section ladder that a sibling section's change can force is
not independent, and §2.8 gave every section one precisely so that it is.

**The one argument that could have gone the other way, and why it does not.**
§2.8's v1 → v2 note is the strongest statement in this project that a version
records *rules* and not only *shape*: "a save is a promise about what the binary
that wrote it would do next", and "`section_version` is the only field a future
migrator can key on to know which set of rules a body was last advanced under".
Read carelessly that says every rules change needs a city rung. Read correctly it
says the opposite: it names `section_version` — **the changed section's** — as
the key. When water's rules move, `water.section_version` is that key. Nothing a
migrator needs is missing, and a city rung would add a second record of one fact,
which is the scattering §K2 refused for the difficulty preset.

**The rule, stated once so it stops recurring.** Three counters, three triggers:

| counter | moves when | does NOT move when |
|---|---|---|
| envelope `schema_version` | the section **registry** changes — a section appears, disappears, splits, is renamed, or a top-level key moves between sections | any section changes its own contents |
| `<section>.section_version` | that section's **shape** changes, or the **rules under which that section's own state is advanced** change | a sibling section moves |
| `city.section_version` | the same two triggers, for the `city` section specifically — **plus** a rules change that no single section owns (a scheduler, phase-order or cross-section-association change) | `water`, `roads` or any other section takes a rung of its own |

The third row's "plus" clause is what v2 and v5 were: the fire-spread breakpoint
and the difficulty seam are properties of how the whole city is advanced, and
`city` is the section that carries the whole city. Water's zone sums are not.

**The property that makes the ruling checkable rather than a preference.** A v6
body written by the pre-RR-60 binary restores under the post-RR-60 binary to
**exactly** the city it restored to before: the two new keys are simply absent
and both loaders fall back to what they have always done. That is the test —
*does an old body still mean what it meant?* — and where the answer is yes and
the only thing that moved is inside a section that took its own rung, the city
rung stays where it is. `tests/test_save_migration.gd` and
`tests/test_save_determinism_days.gd` are the two gates that hold it.

**What this ruling forbids.** A rung taken as a "pure epoch marker" — a
`_v6_to_v7` identity migrator with nothing in the body it is about. Doc 08 §2.8's
v2 note already warns, in its Wave-9 correction, that *"a ladder that describes
rules the binary did not have is worse than no ladder"*; a rung that describes
rules the **city section** did not have is the same fault with the same cost, and
it charges every future migrator a rung to walk that answers nothing.

## Q. Wave-15 rulings — the opportunity layer, and what a play-NOW system may cost (2026-08-21)

*The playtest asked for something the project had never built: a reason to LOOK
at the city. Everything shipped before this wave is a system the player sets up
and then watches settle, and a settled system pays the same whether or not
anybody is watching. Three rulings came out of building the first one that does
not. The binding form of all three is report 98 **RR-77**.*

### Q1. A play-NOW system does not accrue offline, and the enforcement is STRUCTURAL rather than clamped

**Ruled: doc 06 §2.16's opportunity layer spawns nothing on the coarse path, and
its `street` RNG stream does not move a single position across a catch-up of any
length.** Doc 08 §2.3 gains rule 9 to say so.

**The alternative that was rejected, and why.** Every other offline rule in §2.3
is a *clamp*: the system runs offline and `OfflineGuard` bounds its output —
damage ≤ 0.35 of the pool, no asset below 0.15, no destruction, no deaths. The
obvious way to write rule 9 in that idiom is "opportunities spawn offline but
expire before you get back", which produces the same visible result and is one
line shorter. It was rejected because it is **the same result reached by a
mechanism that can drift**: a spawner that runs offline draws from its stream
offline, so the city a returning player resumes depends on how long they were
away in a way that nothing observable can check, and the first person to add
"…except keep the last one" has broken the rule without touching it.

Making it structural — the spawner is a fine-path system whose `advance_coarse`
expires and returns — costs nothing and buys three things a clamp could not:
there is no output for `OfflineGuard` to bound, the doc 01 §2.5 coarse contract
is satisfied *trivially* (zero draws, zero spawns) rather than argued, and
`tests/balance_matrix.gd` — which runs the coarse step — stays bit-identical to
the build before the layer existed, so every table doc 92 ever published against
`do_nothing` still measures the thing it measured.

**The general rule, stated once.** *A system that pays for ATTENTION belongs to
the fine path. Not because offline accrual would be unfair — because attention
is the one input the coarse path cannot supply, and a system whose input is
absent should not be running.* The corollary is the kind one: a returning player
is told **nothing** about opportunities that expired while they were away. A
"while you were away" line naming $2,400 of money they were never offered is
worse than silence.

### Q2. Money earned by ATTENTION is its own ledger line, and may never be folded into tax

**Ruled: collections credit `Treasury` under category `street`, with its own
`ledger_totals.lifetime_street` row (doc 03 §2.5).** Folding it into `tax` was
the cheaper change — no new category, no new counter, no rung on the ledger —
and it is exactly wrong.

The budget sheet's whole job is to tell the player **which lever did what**. Tax
is a rate on the city's value; a bounty is a payment for the player's attention.
Mixed, the tax slider appears to move when the player simply tapped more, and the
one screen in the game whose purpose is attributing income starts lying. It is
not a `tariff` either: nothing was delivered and nothing was metered.

Three consequences follow and all three are deliberate: the line is **not a
rate**, so it never enters `settle()`'s `revenue`, never scales by `M_rev` and
never moves `daily_gross_revenue` — which would otherwise be a loop where tapping
raises the ceiling on borrowing; it is **not offline income**, so §2.11's taper
has nothing to taper (see Q1); and its magnitude is **doc 06's** to author, in
`data/street.json`, where the balance agent can retune it without touching code.

### Q3. An event whose consumer lives in a sibling branch gets a NAMED, self-clearing exemption

**Ruled: `tests/test_event_matrix.gd` gains one classification,
`awaiting_consumer`, and it is the narrowest word in that list.**

RR-53's rule is that every event describing a player-visible state change needs a
consumer or a written exemption. A wave that splits one mechanic across two
branches — a sim spawner here, a street-life renderer there — produces, in each
branch alone, an emit whose consumer genuinely exists and genuinely is not in
this tree. The three words that could have been stretched to cover it all say
something false: `covered` claims a sibling event carries the same change,
`measurement` claims tests are the intended reader, `bookkeeping` claims nothing
visible happened.

What makes the new word safe rather than an escape hatch is that **it expires
mechanically**. `test_the_register_names_a_consumer_that_is_no_longer_needed`
already fails the suite the moment a classified event acquires a consumer, so the
row deletes itself at the merge that makes it untrue — it cannot age into a
permanent excuse the way a prose exemption can. The gate adds one further
requirement, asserted: a row using this word must name **the wave that owes the
consumer and the file that will be it**. "Somebody will get to it" does not
compile.

**What this does not license.** Shipping an emit with no consumer *planned*. The
word is for a split delivery, not for a deferred decision, and the two rows that
carry it today (`opportunity_spawned`, `opportunity_expired`) name Wave 15 and
`game/render/`.

**The same shape, one gate over.** Doc 09 §2.14's evaluator kinds are held by
`tests/test_goals_system.gd` under §G2's rule — *an evaluator kind with no player
surface is a wall with no door* — and `collect_opportunities` is in exactly the
position the two events are: its door is `cmd_collect_opportunity`, reached from
the renderer branch of this wave. It goes in a `SURFACE_DEFERRED_KINDS` list on
the same terms, and with a **stronger** expiry than the event register's, because
one is available: the test scans `game/` and `ui/` for the verb the row names and
fails the moment anything there calls it. A deferral that can detect its own door
arriving is a deferral; one that cannot is an exemption.

### Q4. An unstable sort over a key that is not unique is not a tie-break

**Ruled: `TickScheduler` sorts by `(phase, system_id, REGISTRATION ORDER)`** (doc
01 §2.3, report 98 RR-77).

Doc 01 has said since it was written that the scheduler "sorts by `(phase,
system_id)` … so ties are broken deterministically and alphabetically rather than
by registration accident". That sentence is true for the registry `CitySim`
builds — thirteen distinct ids — and it quietly stops being true the moment two
systems share both. `sort_custom` is an introsort and is not stable, so such a
pair had **no defined order at all**: which ran last was a function of the array's
length and contents.

Nothing shipped registers a duplicate. A **test rig** does, and legitimately:
`tests/test_weather_integration.gd` registers a second `&"weather"` to drive a
wired `WeatherSystem` alongside the sim's, and both write the shared
`ModifierStack`, so the last one to run decides what the grid draws. Adding one
unrelated system to the registry — a street spawner, in a different phase —
flipped that sort. The rig lost, and the failure read as *"a heat wave stopped
moving power demand"*, in a file three directories from the change.

**Why registration order and not a uniqueness assert.** A `assert(id is unique)`
would have caught it too, and louder — but it would also outlaw the override, and
the override is a real and useful thing for a rig to want. Registration order
says the thing the caller already means: *the one you registered later wins*.
And it is safe by construction — the order it defines was previously **undefined**,
so no correct behaviour can depend on the old answer, and for a unique-id registry
it changes nothing. All four determinism baselines are byte-identical across it.

**The general form, which is the reason this is a ruling and not a patch.** *A
sort key that is not unique is not a key.* Wherever this project sorts to get
determinism — and it does so constantly, because sorted iteration is how float
sums are made reproducible — the comparator must be a **total** order on the
things being sorted, not merely a plausible one. Where it cannot be, the sort is
a latent dependency on the container's contents, and it will be found by an
unrelated change.

---

## R. Wave-15 rulings — the money pass (2026-08-21)

*Three rulings, and the first of them is four waves old. Doc 06 filed open question 6 in Wave 1 — "`reward_base` may be doc 03's money too" — and doc 93 §N1 point 4 wrote down the condition on which it would be re-openable. This pass meets that condition, and finds that the answer was worth more than the tidiness: the double booking was hiding **12.5 % of a founding day's income** from the ledger that was supposed to be teaching the player where their money comes from.*

### R1. It was the same dollar, and only one of the two was ever real

**Ruled: `reward_base` moves to doc 03; `POLICE_FINE_PER_RESOLVED_INCIDENT` and `CitySim.HELD_FINE_RATE` are retired; the `fines` ledger line is replaced by a live `city_services` line.** Report 98 RR-78 is the binding text.

The evidence that closed it is not an argument about ownership — C-07 settled ownership three waves ago and `reward_base` was simply missed. It is that **the two halves were in wildly different states of aliveness and nobody could see it.**

* Doc 06's half was **live and invisible**: `IncidentSystem._pay_reward` → `world.credit(reward, "incident_resolved")` → `Treasury.credit(…, &"incident")`. That is a terminal call. `EconomySystem.settle_hour` never saw the dollars, so the budget panel had no line for them, `data/notifications.json` had no event for them, and the only way to notice the money was to watch the balance change for no printed reason.
* Doc 03's half was **dead and visible**: `HELD_FINE_RATE = 3/350` fed `police_incidents_resolved`, which multiplied straight back into `POLICE_FINE_PER_RESOLVED_INCIDENT = 350` for a permanent **$3.00/gh**. §N1 point 3 measured it at the founding hour, at 21 game-days and at 48 game-days on all four presets and got 3.00 every time, and used that as evidence for keeping `M_rev` off the line. That reasoning was correct and is now spent: the line is a measurement.

**The re-open condition, quoted from §N1 point 4:** *"When doc 04 §2.4 publishes real `delivered_mwh` and doc 06 publishes real resolutions, the two lines become measurements of a city under pressure, and the question 'should a revenue multiplier reach them' becomes a different question with a different answer."* Half of it is discharged here. **`city_services` and `assistance` are still outside `M_rev`** and §7 test 46 now asserts it of them by name — not because they are placeholders any more, but for the §2.5 reason every non-tax line is outside it: `M_rev` is written into §2.2's per-building formula and into §2.2's revenue floor, and §2.5 never mentions it. The *other* half of the re-open condition — `delivered_mwh` — is untouched and still ranked.

**Why ONE line and not two.** The wave that files this ruling also lands doc 12's street opportunities, and the obvious shape is `dispatch` and `street` as separate rows. They are the same concept — *the city answered a call and got paid* — and a §2.6 budget panel is a thing a player reads in one glance on a phone. Splitting a line into two half-sized ones costs a row of screen and buys nothing. The sub-grain is not lost: `city_services_by_source: {dispatch, street}` sits inside the snapshot exactly as `tax_by_class` sits beside `tax`, which is the precedent this doc already set for "one line the player reads, N numbers the report can read".

**Why the payout is credited immediately and reported afterwards.** The player's ask is a number that MOVES when they tap. So the dollars go through `Treasury.credit()` at the moment of resolve, and `Treasury.hour_city_services` tallies them by source until the next settlement reads and clears the tally. `EconomySystem` then books the tally on its own revenue line, includes it in `gross` and `net` — it is operating revenue and the income statement must say so — and settles `revenue − city_services` in cash, because that cash has already moved. **One dollar, one line, two moments.** The tally is serialised (defaulting to 0 on any older save) because a save taken between a resolve and the hour's settlement would otherwise drop a line the statement is about to print, and `save → load → advance` is bit-identical or it is nothing.

### R2. A subsidy is honest when it is a published constant on a clock

**Ruled: the early-income retune is two state grants, and neither may be a fraction of anything the player controls.** Report 98 RR-79.

The measurement came first and it killed the obvious candidate. `tools/measure_money_pass.gd` counts BROKE game-minutes — game-hours in which the treasury cannot buy the cheapest row on the build sheet — and the count is **zero, on every seed, in both arms**, as is `E_FUNDS` in the curriculum agent's own action log. *The opening is not poor. It is slow.* Nothing is unaffordable; the milestones are two real hours apart. So the lever is the income rate, and "ease maintenance at low levels" was measured and discarded: `building_maint` is **$27.46 of a $504.73/gh** founding expense bill, 5.4 %, a dead lever.

What the bill actually says is that **$172.00/gh — 34.1 % of it — is `departments` plus `fleet`: three stations and eight vehicles `data/starter_city.json` hands the player, billed at full price from game-hour 1, that the player never chose.** `FOUNDING_ASSISTANCE_PER_HOUR = 172` is that number and not a fit.

Two properties make it a grant rather than a loophole:

1. **It is a constant, not a fraction of the live bill.** A subsidy that scaled with the fleet would pay a player to buy vehicles — the same shape of mistake C-08 and RR-2 exist to stop one knob down. It would also put an `M_exp` inside a revenue line and break §N1's one-knob-per-line contract from the other side.
2. **It runs out on a clock the player cannot touch.** `share(day) = clamp(1 − day/7, 0, 1)`, evaluated on the settled game-day so the line steps once a day rather than drifting inside one. Seven game-days is the curriculum's own opening (level 3 arrived on game-day 5.1–5.3), so it covers levels 1–3 and is fully retired before level 4's incident wait begins.

**The celebration grant is the fun half, and its rule is one sentence: the city pays half of what the next chapter asks you to buy.** Doc 09 §2.14 already names that purchase per level, so `LEVEL_UP_GRANT_BY_CITY_LEVEL` is a derivation and not a ladder somebody liked the shape of. It pays on the composed level (§G1's `max(population_ladder, objectives_earned)`), so neither route to a rung is worth more than the other, and `city_level` is monotone by `data/progression.json` so a rung can never be sold twice. It is a **one-off receipt and therefore not an hourly ledger line** — §2.4 keeps one-off capital spends out of the recurring rate and the symmetric treatment is the same one.

**What this does NOT do is touch a price.** Not one `build_cost_l1`, not one `base_tax_by_level` row, not one expense constant. The founding ledger's entire movement is `+172.00 − 3.00 = +169.00/gh` on the revenue side, which is why `STARTER_EXPENSE_PER_HOUR_EXACT` is not re-stamped and gate 2b — the expense anchor — is the check that this was a revenue-side change.

### R3. A stock measures how much an agent chose not to spend

**Ruled: gate 4's money column moves from `treasury_end` to `net_mean_per_hour`.** Report 98 RR-80.

Gate 4 is the maintenance A/B — `balanced` against `disaster_neglect`, the same agent class with one field changed — and its header already carries one re-fit of exactly this kind: pass 3 dropped `value created` because a spend-everything agent's construction column was contaminated by the harness's action budget. The money pass inverted the OTHER money column, and un-inverted the first one at the same time:

| column | before | after |
|---|---|---|
| `treasury_end` | balanced $81,950 > neglect $55,624 | balanced $58,612 **< neglect $80,532** |
| `value created` | balanced $834,156 **< neglect $952,519** | balanced $965,739 > neglect $925,644 |
| `net_mean_per_hour` | balanced $1,968 > neglect $1,653 | balanced $2,342 > neglect $2,020 |

Neither flip is the maintenance knob. Both are the same artefact seen twice: **cash-in-bank is a stock, and a stock records how much of its income an agent declined to convert into city.** Give both agents more money and the one that also buys repairs converts more of it, so its stock falls and its stake rises. An agent that skips maintenance holding more cash is *correct* — that is what "maintenance costs money" means — and the design claim was never that neglect ends poorer. It is that the maintained city is worth more and earns more.

`value created` is not the replacement: on seed 9001 it separates the pair by **0.29 %**, which is noise wearing a threshold, and this doc has already ruled once (gate 12c, Wave 8) that a threshold fitted on the matrix must be measured on the matrix. `net_mean_per_hour` is the **flow**, it is what condition drives through doc 03's `f_condition`, it separates the pair by 12–20 % on all three seeds in **both** arms, and gate 5 already uses it for the same claim one comparison up. No constant moved to make this pass; the column moved to the thing the knob acts on.

## S. Wave-14 rulings — the street gets something to do, and the three rules that came out of drawing it (2026-08-21)

*Doc 11 §2.17's STREET LIFE layer. The mechanics question this pass answers is
the player's own — **"there's not a lot of downtime of absolutely nothing to
do"** — and the answer is a render layer, so the rulings here are render rulings.
The full arguments and the measurements are report 98 §31 (RR-81, RR-82, RR-83);
what follows is what each one BINDS, in one line, because that is what a
mechanics audit is for.*

### S1 — A distance field is DATA, not colour (report 98 RR-81)

**Binding:** a shader sampler carries `source_color` **if and only if** the
texture is a colour a human picked. A signed distance field, a mask, a lookup
table or a set of packed channels is data, and hinting it as colour makes the
sampler decode it as sRGB — which is silent, which is valid, and which moved the
`StreetGlyphAtlas` page's 0.561 contour value to 0.275 so that every mark on
every marker in the city drew as nothing.

**Companion, and it points the other way:** a **MultiMesh instance colour is
LINEAR** and nothing on that path converts it. `source_color` uniforms and
`StandardMaterial3D.albedo_color` are converted for free;
`MultiMesh.set_instance_color` is not. Authored palettes destined for an instance
buffer are converted ONCE, where they are read, and the file says so.

**Open, and deliberately not closed from the branch that found it:**
`VehicleView` and `ConstructionVehicleView` pass their authored liveries in raw
and carry the same lift. Re-saturating a shipped fleet and a shipped plant hire
is an art call on two layers this branch does not own.

### S2 — A screen-space affordance is laid out in screen space, and measured in itself (report 98 RR-82)

**Binding:** the siblings of a billboard — the glyphs of a floating label, the
ticks of a floating gauge — are laid out in the **billboard's own frame**, never
in world space. Laid out along world +X, a `+$120` skews and foreshortens with
the camera yaw and puts its middle glyphs behind the marker it belongs to; it
reads as `+ 20`. The fix is one float per instance (the glyph's SLOT) and an
offset applied after the billboard transform, where local +X is screen right.

**And the size half:** a quantity that decorates a thing which holds a SCREEN
size is measured in that thing, not in metres. The label's rise was authored at
1.55 m against a marker sized angularly, so it was a hand's width at Z0 and a
twitch at Z1; it is a fraction of the marker now and travels the same number of
screen pixels at every pose.

### S3 — Emptying a buffer is not switching it off (report 98 RR-83)

**Binding:** a `MultiMeshInstance3D` whose buffer holds
`visible_instance_count == 0` **still costs a draw call**, and every MultiMesh in
this renderer carries a world-sized `custom_aabb` by necessity — instances are
written straight into the buffer and never update the auto AABB — so the frustum
culler can never drop it either. **A layer that gates its instances by distance
must gate its NODES by count**, on the same line that writes the count. Measured:
three empty body buffers cost 3 of the 4 draw calls this layer read at Z2, where
every body is out of range and only the marker buffer has anything in it.

**The corollary that makes the claim checkable:** a layer that does this can
publish `active_buffers()` and mean it, and the profiler can print it beside the
timing. A budget claim that cannot be printed is a budget claim nobody re-checks.


## T. Wave-14 rulings — a payment nobody could hear, and a pick that is not on the grid (2026-08-21)

### T1. A reward that reaches the treasury and no surface is a reward the game did not pay

**The finding.** `IncidentSystem._emit("incident_resolved", …)` has carried a
`reward` field since doc 06 shipped, and `_pay_reward` has credited it on every
resolution. Nothing anywhere sounded it, said it, or counted it. The 2026-08-21
playtest asked for it in the only terms a player has — *"our automatic dispatch
in crime — that should pay us money"* — and the correct answer was that it
always had.

**The ruling: a value transfer the player did not personally authorise MUST have
a sensory surface at the moment it lands.** Not a screen they could go and open;
a thing that happens on its own. Three of them, and they are cheap on purpose:

1. **Audible.** One cue, `cash`, on the UI bus with attenuation `none`.
2. **Visible where the value lives.** The treasury chip pulses — §2.5's own
   pulse mechanism, reused, so A8's `reduce_motion` covers it for free.
3. **Legible.** A toast, above a floor (doc 92 §38.2), naming the amount.

**Why this is a ruling and not a feature note.** The failure mode is not
"the feedback was missing", it is that **the system could not be
distinguished from a broken one by playing it**. A player who dispatches a crew,
watches it work, and sees no consequence concludes the verb does nothing —
and reasonably stops using it. The same argument applied to `profile_weights_of`
in §O and to the ambient floor in §K: a correct system with no observable is
indistinguishable from an absent one, and the audit keeps finding it because
nothing in the suite asks the question. A test that a value moved is not a test
that anybody could tell.

**Scope.** Player-authorised spends already have their surfaces (`purchase`,
the placement bar, the refusal copy) and are untouched. What this ruling covers
is the other direction: money that arrives.

### T2. A pick is decided by what the player's finger covers, not by what a tile owns

**The finding.** `BuildController.pick_at_ground` resolved a tap by asking which
tile it fell in — building first, then land block. Correct for everything that
had ever been pickable, because everything that had ever been pickable was
built on the grid. A street collectable is not: it is a character standing on a
tile a house already owns, so every tap on one opened the house.

**The ruling: an entity that is not placed on the grid is picked by a RADIUS
from the tapped point, and it outranks the grid.** Two halves, both load-bearing:

* **The radius is 48 dp converted at the current zoom, never a metre constant.**
  Doc 92 §38.3 has the arithmetic: the same 48 dp is 0.69 m of ground at
  `zoom_t = 0` and 16.04 m at full zoom-out, a factor of 23. Any constant chosen
  in metres is wrong at one end of that range by more than an order of
  magnitude. The unit the player has is the finger; the shell owns the
  conversion because only the shell knows the camera.
* **The moving thing wins.** Everything the grid holds is something the player
  built and can find again in a second. The collectable is leaving. Losing the
  building panel for one tap costs a tap; losing the dog costs the dog.

**And the roster asked is the SIM's, never the render view.** A pick that asked
the renderer would be picking what is *drawn* — subject to LOD, culling, the
perf governor's own decisions and a frame of interpolation lag — rather than
what exists. That is the same class of error as a UI that predicts a command's
success (doc 12 §4.4), and it fails in the same silent way: the tap that misses
is the one where the governor had just dropped the character's bucket.

### T3. A one-shot notice is not a curriculum step

**The ruling.** A sentence shown once because the *world* did something new is
not the same object as a step of doc 12 §2.17's scripted fifteen minutes, and
must not be authored as one. It gets the mark's presentation and none of its
machinery: no index, no count, no persisted cursor, no gate, no `Skip tutorial`.

**The mechanical reason, which is the whole ruling.** The balance suite counts
the tutorial's steps. A curriculum whose length depends on what the director
happened to spawn is not a curriculum — it is a number that changes per save,
and every assertion written against it becomes a flake. The same argument
retires the button: offering `Skip tutorial` on a notice offers to skip
something that is not running, and on a player who graduated, something that no
longer exists.

**Ordering, since both can want the screen.** A live step always wins. A notice
raised during one is **owed**, not dropped — it goes up when the tutorial ends,
skipped included, which is precisely the case where nothing else has explained
anything. Its one-shot flag persists; its coordinates deliberately do not,
because a mark restored a day later would point at a street that emptied hours
ago, and a mark that points at nothing is worse than a mark that centres.

## U. Wave-15 rulings — the reward ledger settles, and four numbers that were never checked (2026-08-21)

*Balance fork. The full arguments and the measurements are report 98 §35
(RR-85 … RR-89) and doc 92 §39; what follows is what each one BINDS, in one line,
because that is what a mechanics audit is for. **Four of the five have the same
shape** — a published number, quoted in three documents, held by a passing test,
and not the number the game was using — which is itself the finding U1 ends on.*

### U1. A price that lives in two files is a price nobody owns (report 98 RR-85)

**Binding:** C-07's currency monopoly is not satisfied by doc 03 *publishing* a
price; it is satisfied by the game *reading* doc 03's price. The opportunity
layer shipped with its live `{base, spread}` bands in `data/street.json` and a
placeholder flat table in `data/economy.json` — **and two of the three keys in
doc 03's table were not even live kind ids**, so the spawner could not have read
it if it had tried. Every dollar the player earned came from the file the balance
gates did not open.

**The discriminating test is the one that checks ABSENCE.** A test asserting doc
03's numbers are present and well-shaped passes identically whether the column is
live or dead; a test asserting doc 06's file carries no price at any depth does
not. Where a price moves between documents, the migration ships **both** halves —
the destination's values and the source's refusal (`FORBIDDEN_KEYS`, a boot
error) — or it has not moved anything, it has copied.

**And a migration that moves no number must prove it with the hash.** All four
`profile_sim` baselines are bit-identical across this one, which is the only
evidence that separates "moved" from "retuned while nobody was looking".

### U2. A ceiling and a share are different claims and may not share a bound (report 98 RR-86)

**Binding:** *what a system pays a player who takes everything* and *what it pays
a player who plays* are two measurements with two denominators, and one published
band cannot hold both. The old `STREET_MAX_RATE_PER_GAME_HOUR × max(payout)`
product tried: it was quoted as a worst case, compared against a founding hour,
and then described as the band "when played". Split, they are
`STREET_CEILING_SHARE_MAX` (spawner, founding net) and
`STREET_PLAYED_SHARE_BAND` (a played arc, that arc's own net), and each is
measured on the thing it is about.

**The corollary that made it possible:** *a bound nobody can measure is not a
bound.* `STREET_MAX_RATE_PER_GAME_HOUR = 0.45` was violated by the shipped spawn
table by 48 % from the day it was written, and no test could see it because the
table lived in a file the gate could not open. A contract is checked against the
thing it constrains, in the same tree, or it is a comment.

**And the instrument is part of the ruling.** A layer that only exists on the
FINE path needs a fine-path agent before any claim about it is a measurement;
`collector` is that agent, and the slice that makes it possible is asserted
bit-identical to the hour it replaces rather than assumed to be.

### U3. A budget setting is denominated in the player's dollars, so it is priced (report 98 RR-87)

**Binding:** calling a dial *"a player budget setting, not a price"* is the reason
its quote must carry the full price — including C-16's `M_repair` — not a reason
it may quote at nominal. `auto_repair_daily_cap` reads *$25,000/day* on the
settings sheet; it has to buy $25,000/day of repairs on every difficulty preset,
and quoting at nominal made one dial mean four things and say so on none of them.

**Hash-neutrality is what makes a fix like this shippable in a balance wave:**
the default preset's multiplier is exactly 1.00, so the change is the identity
there and the arms that move are precisely the ones the finding is about.

### U4. A counter that is always zero is worse than a counter that is missing (report 98 RR-88)

**Binding:** a named ledger row answers a question. A missing one answers *"I
don't know"*; a permanently-zero one answers *"none"*, which is a false claim the
save carries forward forever. `ledger_totals.lifetime_street` read zero on every
city the layer ever ran on, because the credit was keyed on a CATEGORY and the
counter on a SOURCE — while the cash, the receipt book and the printed revenue
line were all correct, which is what let it survive a wave.

**The test that discriminates is the one that checks the VALUE.** The existing
tests asserted the key was in the serialised body, and asserted a byte-identity
property with the key *erased*; both pass whether the counter counts or not.

### U5. The same number is a rhythm or an attrition depending on whether it pays (report 98 RR-89)

**Binding:** a pacing question may not be answered in the wave that discovers it,
because the thing that decides it is often not the generator. `traffic_accident`
at ~0.96/game-day was, in Wave 13, an event that cost fuel and vehicle wear and
paid into a ledger line that did not exist — one a day, forever, for nothing.
Since RR-78 the same event pays ~$450 and the budget panel names it. **Same rate,
opposite reading**: the ruling would have been *cut it* then and is *keep it*
now, and nothing about the incident changed.

**The corollary for gates:** a gate whose TITLE states a cadence must be re-titled
when the cadence is re-ruled. Gate 19 claimed a *weekly* beat over a measurement
of 9.73/game-week for two waves; a title is an assertion, and the one place a
gate must not be able to lie is about its own measurement.


## V. Wave-15 rulings — street polish: what a shadow is, what a livery is, and the ding that never rings (2026-08-21)

*The five render items Street Life filed, plus the one sim question it left
open. Hash-neutral except where §V2 says otherwise. The full arguments and the
measurements are report 98 §36 (RR-90 … RR-93); what follows is what each one
BINDS.*

### V1 — A layer that pays you for LOOKING may not fine you for looking away

**The question (sim q5).** `data/street.json`'s `petty_crime` note carried an
authorable next step: `expire_stability_delta`, a stability micro-ding on the
district that let a crook walk unanswered.

**Ruled: ZERO for v1, and the key is authored at 0.0 so the ruling is in the
file rather than only in this document.** The reason is not caution. This whole
layer exists because a playtester said *"there's not a lot of downtime of
absolutely nothing to do"* — they asked for something to **do**, and a penalty
for not doing it converts a bounty into a chore. It also taxes exactly the
player who put the phone down, which is the player doc 08 §2.3 rule 9 already
promises not to punish for being away; a layer that is free while you are absent
and costly while you are present-but-not-looking is a rule with a seam in it.

**Binding, generalised:** *an ATTENTION reward may not have an inattention
penalty.* A system whose whole proposition is "notice this and be paid" is
balanced by the size of the payment and by nothing else; the moment it also
charges for the notice you missed, the player is no longer choosing whether to
engage, they are paying rent.

**The shape of the deferral, because "we decided not to" is a decision that has
to be re-openable.** `OpportunitySystem._normalise_kind` parses the key and
`_expire_through` — the one function that would spend it — does not, and says so
at the point where the spending would go. So the day this is re-opened it is a
three-line change against one authored number rather than a new field, a new
migration and a new test. **RE-OPEN ON ONE CONDITION AND NO OTHER:** telemetry
showing players farm-ignoring crooks at scale. Pinned by
`tests/test_street_opportunities.gd::test_an_unanswered_crook_costs_the_player_nothing`,
which asserts both halves — the authored 0.0 AND that thirty game-hours of
unanswered expiries leave the city bit-identical to a mirror run.

### V2 — A field the RENDERER needs is a field the SAVE owes it (report 98 RR-93)

**Binding:** where a render layer derives its whole state from a closed form in
`(id, now − t0)`, `t0` is not the renderer's to guess. Doc 11 §2.17's wander is
exactly that shape, and a cold load had no `t0` to offer it: the sim restores
its opportunity roster in silence — there is no `opportunity_spawned` for a row
that was already on the books — so every restored body either did not exist for
the renderer at all or restarted its beat on the frame the save was opened.
`born_gm` is the spawn game-minute, written once, republished on every payload
and **persisted with the row**.

**And the hash consequence is stated rather than discovered.** A payload field
is not hashed; a persisted row is. `state_hash` is `capture_state`, the street
section is in it, so the field moves the FINE baselines and cannot move the
COARSE ones — the coarse path never spawns (doc 06 §2.16's fairness rule), so the
roster it hashes is empty either way. Both predictions were made before the run
and both held; the numbers are in report 98 RR-93. The multi-day
save → load → advance identity gate is unmoved, which is the property that
actually matters.

### V3 — A shadow you cannot see is not a shadow (report 98 RR-90)

**Binding:** a preset knob that removes a cue owes a replacement, and "the knob
is off" is not a shipping state for a cue the picture depends on.
`vehicle_shadows` is false on Performance AND Balanced — i.e. on every phone —
and doc 11 §2.11's `blob_shadow` block had existed since the preset table was
written without anything reading it, so every dynamic body in the game floated.
One knob now decides **both** shadows: real where the tier can afford to re-draw
a body into every split, a blob decal where it cannot, and never neither.

**The second half, which is the one that generalises.** *An art constant is not
verified until a screenshot has been taken of it.* The first cut of this feature
emitted the right instance, in the right place, with the right mode code — and
was invisible in the frame, twice over, for two reasons a census could not
show: the colour was **lighter than the road it was cast on** (a `blend_mix`
pass mixes TOWARDS a value, it does not multiply by one, and the shaded
carriageway sits near 0.02 linear), and the falloff peaked at a single pixel
(244 pixels of real shadow in a 1920 × 1080 frame). Both were found by
photographing it and neither by reading it.

### V4 — A palette fitted against a broken seam is a palette that has to be re-judged (report 98 RR-91)

**Binding:** when a colour-space defect is corrected, **every hex that was
authored against it is now unfitted**, and the fix is not finished until they
have been looked at again. A MultiMesh instance colour takes no sRGB decode;
`VehicleView` and `ConstructionActivity` were handing it authored hexes raw, so
the whole fleet and every machine rendered roughly two stops light. Applying
`srgb_to_linear` at the seam is one line — and it darkened ten civilian paints,
four plant liveries and six department colours at once, four of which had been
chosen BY EYE against the lift. Two civilian entries then matched the asphalt
they were driving over and two plant liveries went black at 21:00. They were
moved, against screenshots, and the move is documented where the hexes are.

*The corollary for the next pass:* the same latent lift is on every **vertex**
colour in every procedural mesh in this renderer, for the same reason and with
no conversion either. It is FILED and not fixed here (report 98 RR-91's deferral
list) because converting the shared constants would move the mesh half at the
same time, and the mesh half has never been judged against a picture.

## W. Wave-14 merge rulings — how coverage is COUNTED, and how an id survives four siblings (2026-08-21)

*Three rulings, all about the ledger rather than about the game. They exist
because four Wave-14 branches each did the right thing on their own fork and the
merged tree still came out with three double-assigned ids, six mislabelled
section headers in **this document**, and a count table nobody could check
against the rows beneath it. Report 98 §37 / RR-94 is the binding form; these are
the three decisions inside it that a mechanics reader needs.*

### W1. The row basis is a GREP plus two enumerated lists, and the promotion list is CLOSED

Doc 91's coverage count has been re-derived four times and the basis has moved
every time, which makes the percentage unquotable however carefully it is
computed. The basis is now fixed and mechanical:

```
rows = grep -c "^### 2\.[0-9]" over docs 01-13          =  184
     + an ENUMERATED, CLOSED list of promoted #### rows =    4   (doc 11 §2.1.1, §2.1.2, §2.1.2a, §2.10.1)
     + an ENUMERATED list of cross-cutting "—" rows     =    2   (doc 05's, each printed twice and counted once)
                                                          -----
                                                           190
```

**The promotion list is closed, and doc 03 §2.5a is the case that closes it.**
§2.5a — the state grants, RR-79 — is a real shipped deliverable with published
constants, its own `assistance` revenue line and its own tests. So is doc 11
§2.16b's pose cache. So is doc 06 §2.13(b)'s saturation rule, which this very
wave leaned on. `grep -c "^#### 2\."` over docs 01–13 returns **63**, and there
is **no criterion that admits §2.5a and excludes doc 07 §2.6.3 or doc 09
§2.9.4**. A basis that grows by whichever sub-heading a wave felt proudest of is
not a basis; it is a mood.

**The ruling: a `####` sub-heading is graded inside its parent `### 2.N` row, and
the parent's pointer MUST name it.** Doc 03 §2.5's row now names both grants and
the `city_services` line, so the deliverable is graded, credited and findable —
it simply is not a *row*. The four grandfathered doc-11 promotions stay because
four waves of printed grades hang off them, and they are recorded as a historical
accident this table declines to repeat rather than as a principle it applies.
When §17's verb matrix becomes a test and "done" is a number the suite prints,
the promotion list should be **deleted** and the basis should be the bare grep.

*Consequence worth stating: adding a mechanic no longer moves the percentage
unless it gets a `### 2.N`. That is the correct incentive — a section heading is
cheap, and a heading is what makes a mechanic auditable in the first place.*

### W2. A colliding id stays with the row that CODE points at

Two Wave-13 siblings each filed an `A91-D-31`. Two Wave-15 siblings each filed an
`A91-D-33`. Doc 91's own §14.5 already warns that renaming an id "would break
every cross-reference in `docs/` and in code comments", which is the right
instinct and, on its own, not a rule — both sides of a collision have references.

**The ruling, mechanical, no judgement required:**

1. **The id stays with the row that CODE already points at** — a file under
   `sim/`, `ui/`, `game/`, `tests/`, `tools/` or `data/`. A code comment is the
   reference hardest to keep true and the one a grep-driven reader trusts most.
2. **The row whose references are docs-only takes the next free number** in the
   document's own sequence — never a restart, never a reuse.
3. **If neither side has a code reference, the id stays with the block whose
   HEADER claims a contiguous range**, and the interloper moves.

Applied at this merge: `A91-D-31` stays with the sliced offline catch-up (named
from `sim/time/catchup_cursor.gd`, `sim/city_sim.gd`,
`tests/test_catchup_cursor.gd`) and the incident-roster cascade becomes
**`A91-D-35`** — the sequence's one unissued number, so the ledger gains no hole.
`A91-D-33` stays with the opportunity layer (named from
`tests/test_save_migration.gd`) and the dispatch-ledger row becomes
**`A91-D-38`**. By rule 3, this document's own twice-assigned `G4` stays with
Wave 10's `G4–G6` block and the `place_water_main` ruling becomes **`G9`**.

### W3. A section HEADER is part of the id space, and a per-line `sed` does not know that

**Six headers in this document carried a letter that none of their own rulings
used**, every one of them a Wave-13/14 merge artefact: `## K.` over `L1`, `## M.`
over `N1`–`N4`, `## O.` over `P1`–`P2`, and **three separate `## P.` headers**
over the `R`, `S` and `T` blocks. Report 98 carried the same fault in its own
numbering — `## 24.` three times, `## 26.` three times. Every ruling id inside
was correct and every cross-reference resolved, which is exactly why it survived
three merges: **nothing was broken, only unfindable.** A reader who greps
`## N\.` to find `N3`'s context gets nothing and concludes the ruling does not
exist.

**The ruling: a renumbering `sed` must be run against `^#{2,4} ` as well as
against the body, and a merge that renumbers rulings must re-derive its own table
of headers afterwards.** Headers are fixed here (`L`, `N`, `P`, `R`, `S`, `T`),
and where a *number* was assigned three times the first keeps it and the later
two take a `b`/`c` suffix — report 98's own house style, established by RR-60b.

**The durable half is a validator, not a habit — and it ships as
`tools/check_doc_refs.py` rather than being recommended.** It walks
`docs/ sim/ ui/ game/ tests/ tools/ data/ .github/`, resolves every `RR-nn`,
`A91-D-nn`, `92 §<n>.<m>`, `93 §<letter>` and `98 §<n>` against the header that
defines it, **and refuses any id that is assigned twice** — which is the half
that would have caught all three of this section's collisions on the day they
were filed rather than three merges later. At this
merge it checked **2,517 references** and found **nine bad targets across
sixteen references** — five dangling and, worse, **four that resolved to the
wrong section** because the money pass was drafted as doc 92 §35 and merged as
§36. A dangling pointer is a broken link
and a reader notices; a pointer that resolves to the wrong section is a lie with
a footnote. **It belongs in CI, next to the suite.**

## AB. Wave-17 rulings — the queue surface: what a price on a button is for, and what a corner may hold (2026-09-01)

*Three rulings from the UI half of the construction queue (doc 12 §2.22, report
98 §42). They are about a screen rather than about the sim, and they are here
because each one is a decision a mechanics reader will otherwise re-litigate:
whether a spend needs a confirmation, what a rail does when it runs out of
display, and whether a count of zero is a reading.*

### AB1. A price on the face IS the confirmation — a rush is one tap, and the threshold above which it would not be is the treasury itself

**The ruling.** `RUSH $1,240` is pressed once. No dialog, no hold, no undo
toast. The build card (§2.7) and S4's `PURCHASE` (§2.8) set the precedent: a
button that names what it will take has already asked, and the deck confirms
nothing that is not *destructive* — `Demolish` holds for 800 ms because it
destroys value the player cannot get back, and a rush converts money into time
the player opened this screen to buy.

**Why one tap is right here in particular, not just by precedent.** The RUSH
button is a *separate* 48 dp target in its own flow row **below** the row head
(doc 12 D-47's shape), and the row head's own tap does something harmless —
it focuses the camera on the site. A mis-tap that lands anywhere on the row
costs nothing; only a tap on the face that carries the price spends, and that
face is the one thing on the row that is read before it is pressed. The
treasury chip is on screen above it, pulsing the moment the money leaves
(doc 12 D-62's chip flash, backwards).

**The threshold, stated rather than implied.** *Above what price would a
confirmation be warranted?* The honest answer is: **at the price that changes
the city's solvency state** — a rush that would take the treasury below zero
has consequences beyond itself (doc 03's credit line and austerity), and a
spend with consequences beyond itself is not a one-tap spend. Today that
threshold coincides exactly with the affordability rule: the button is
**disabled with its price on it** the moment `rush_cost > balance`, and
`cmd_rush_construction` refuses behind it. So the threshold is the balance
itself, and nothing in between needs a second question. A share-of-treasury
hold (say, above 25 % of the balance) was considered and declined: it would be
the only hold in the deck on a *reversible* verb, it would arrive with no note
saying why the button suddenly resists, and the number would be a guess.

**Re-open conditions.** (1) Doc 03 publishes a solvency floor the UI can read
(`Treasury` austerity trigger, or a `credit_floor` on the seam) — then "would
take the treasury below the floor" becomes the disabled-with-price condition
instead of "below zero", and the ruling's threshold moves with it, with no
change to the one-tap rule. (2) An on-device playtest reports a rush the
player did not mean — the fix then is D-47's already-shipped separation made
wider (a taller gap between row head and verb), not a dialog. (3) A rush price
above the *land purchase* price band ever appears in `construction_overview()`
— that is the one case where the precedent inverts, and it is a doc 03 number
to check at that time, not a UI guard to add now.

### AB2. A corner rail WRAPS before it overflows, and never hides a door to make room

**The ruling.** The bottom-right rail (doc 12 D-46) takes a display height. A
column holds `floor((H − margin + gap) / (pitch + gap))` chips; the next chip
starts a second column one chip-width plus a gap further in, at rung 1. No
chip is dropped, shrunk or stacked under another.

**Why.** Three chips in one column no longer fit the project's own minimum
box at the scale A2 names for it: at 640 × 340 with 150 % text and larger
targets a chip measures 92 dp, so rung 3's bottom edge sits at
92 + 2 × (92 + 8) = 292 above the safe area's bottom edge and its top at 384,
which is window `y −48` on a 340 dp display — 48 dp above the top of it. The
top bar is a different layer, so the rail solves against the safe area's edge
and not the bar's underside; the two chips that were already there have
passed under the bar at 150 % since D-46 shipped, and moving them to tidy that
would break D-46's own promise that the reference box does not move. This is
D-1's rule for the top bar — *wrap before you overflow* — applied to the other
corner, and the arithmetic is a pure static function so the wrap point is a
test (`tests/test_ui_audit.gd::test_the_corner_rail_wraps_before_it_overflows`)
rather than a screenshot. `host_h = 0` — every caller before Wave 17 — is the
old unbounded column byte for byte.

**Re-open condition.** A fourth chip claims the rail. Two columns of two is the
most the 640 × 340 box holds at 150 %, and the third column would reach the
overlay legend's side of the display; at that point the rail needs a
*priority* (which chip yields first), which is §2.4's chip-collapse solver
applied to the corner, not more columns.

### AB3. An empty queue has NO affordance — a count of zero is not a reading

**The ruling.** The queue chip exists only while something is building. It
does not show `⚒ 0`, it does not grey out, it is not there.

**Why.** Every other reading on this HUD is about something that is *happening*
— an incident count, an unread count, a grid percentage. A chip that says `0`
is a chip that teaches the player to stop looking at it, and the day the
hiding rule breaks, a badge on a hidden control that reads `0` is the badge
that will read `0` for the rest of the session (report 98 RR-88's counter,
one screen over). The panel itself keeps an empty state, because the queue
can drain *while it is open* and a panel that vanished under a finger would be
worse than one that says what to do next.

**Re-open condition.** A tutorial step that points at the chip before the
player has built anything — then the chip has to exist to be pointed at, and
the answer is a *notice* on the first project rather than a permanent chip
(doc 12 D-63's shape).

## F. Explicitly deferred (unchanged from master plan)

Multiplayer/social, city trading, seasons/holidays, mod hooks, cloud saves,
monetisation — none are Phase-1/2 scope; nothing in Waves 1–3 blocks them.
