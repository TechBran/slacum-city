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

### G4. `place_water_main` stays reachable and unused (Wave 10)

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

## K. Wave-11 rulings — the event matrix gets a rule (2026-08-20)

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

## F. Explicitly deferred (unchanged from master plan)

Multiplayer/social, city trading, seasons/holidays, mod hooks, cloud saves,
monetisation — none are Phase-1/2 scope; nothing in Waves 1–3 blocks them.
