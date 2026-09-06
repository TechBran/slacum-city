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
migration and a new test. ~~**RE-OPEN ON ONE CONDITION AND NO OTHER:** telemetry
showing players farm-ignoring crooks at scale.~~ Pinned by
`tests/test_street_opportunities.gd::test_an_unanswered_crook_costs_the_player_nothing`,
which asserts both halves — the authored 0.0 AND that thirty game-hours of
unanswered expiries leave the city bit-identical to a mirror run.

> **The re-open condition, restated 2026-09-01 because the old one could not
> fire** (report 98 RR-97, doc 93 §X4). *"Telemetry showing players
> farm-ignoring crooks at scale"* names an instrument this project does not have
> and is not going to have: `game/crash_sentinel.gd` writes a local breadcrumb
> and sends nothing, doc 13 §2.11 ranks a network reporter post-alpha, no
> `INTERNET` permission is requested and doc 91 §17 records the Data Safety
> declaration that absence buys. A ruling whose own argument is that it must
> stay re-openable may not be gated on a capability that does not exist.
>
> **RE-OPEN ON EITHER OF TWO PLAYTEST-OBSERVABLE CONDITIONS AND NO OTHER**, both
> written in the two instruments the lead actually runs:
>
> 1. **A play session in which the tester says, unprompted, that the markers
> became WALLPAPER** — that they stopped registering as an offer and started
> reading as furniture, and that they let them expire without deciding to. That
> is the observation the penalty was ever meant to answer, and a human saying it
> out loud is a stronger signal than a counter: the counter cannot tell "ignored
> because bored" from "ignored because busy building", and the tester can.
> 2. **A `tools/run_matrix.sh` row in which the TAPPING agent's
> `street_share_of_net` collapses** — the offers are being taken and the money
> is no longer worth the tap. `tools/playtest.gd` already computes and reports
> `opportunities_collected`, `street_income`, `street_missed` and
> `street_share_of_net` per run (`tools/playtest.gd:3000–3007`), so this is a
> column that already prints and not a new field. It is the honest matrix form
> of the question, and it is the one §V1's own binding points at: *"a system
> whose whole proposition is 'notice this and be paid' is balanced by the size
> of the payment and by nothing else."* If the payment stops carrying it, the
> lever to reach for is the payment — and only if RAISING the payment has been
> tried and has not moved condition 1 does the penalty come back on the table.
>
> Neither condition needs a new event, a new persisted field or a new
> subsystem; the three-line change §V1 describes is still the whole of what
> re-opening costs. **Dated, because a re-open condition that has been restated
> once may be restated again, and the next reader is owed the date on which this
> one was true.**

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

## AA. Wave-17 ruling — what "speed it up with cash" BUYS (2026-08-21)

*The sim half of the construction roster and the rush verb (report 98 §41
RR-107…RR-110; doc 02 §2.13; doc 03 §2.13(f); doc 92 §45). One question was put
two ways and had to be answered once.*

### AA1. INSTANT COMPLETION, not paid overtime — and the fiction did not decide it

The brief offered two shapes and asked for one, argued:

- **instant completion**, priced per remaining work — the player taps, the
  project is finished, the row leaves the roster; or
- **paid overtime**, `×2` effective crewing to completion — the player taps, the
  project goes twice as fast, the row stays on the roster counting down.

The obvious move is to let the fiction pick, because doc 03 §2.5's own
money-for-time valve is an *acceleration*: the emergency contractor
*"completes in `CONTRACTOR_TIME_FRACTION = 0.35` of the normal duration"*, not
instantly. **That reading is wrong, and the reason it is wrong is the thing worth
writing down: 0.35 is not a fiction about how construction works, it is a
PRICE POINT.** The row prices one package on a curve — a fraction of the
duration for a multiple of the cost — and instant completion is the same curve at
`0.00`. Doc 03 §2.13(f) charges exactly the rate the contractor row implies
(`0.80 / 0.65` per unit of duration bought, doc 92 §45.1), so **nothing in the
founding ledger is contradicted and no new curve is invented**. The fiction is
not being overruled; it is being extended along its own axis.

So the fiction did not decide it. Three other things did.

**1. The tick path is sacred, and overtime edits it for the life of the job.**
`ConstructionQueue.advance()` is the one exact-integer accumulator this project
does not trade — `num = crew_permille × site_mult_permille × eff_permille ×
dt_game_seconds + carry`, deliberately un-divided until the end so fine and
coarse stay bit-equivalent. Paid overtime means changing one of those factors
*while the job runs*, on every tick, forever after. Instant completion writes the
accumulator **once, from a command**, and then leaves. One of these is a change
to the machine the multi-day determinism gate exists to protect; the other is a
write the same machine already performs.

**2. The overtime flag has nowhere clean to live.** The obvious home is
`site_mult_permille`, which is already persisted and already clamped to 4.0 — and
that is exactly the problem: it is **doc 02 §2.10's channel** for site conditions.
A rush that wrote it would clobber, and be clobbered by, the site's own
modifier, silently, with the last writer winning. Keeping the two apart needs a
second per-job multiplier, a second save field and a section rung (RR-75
sufficiency) — real persistence cost for a feature whose whole appeal is that it
makes something go away. **Instant completion adds no state at all.** There is no
flag, so there is nothing to persist, nothing to migrate and nothing to get wrong
across a load.

**3. Legibility: money should buy the THING, not the slope.** The player's own
words were *"the ability to speed it up with cash"*, but the sentence before them
was *"a queue that tells us what's actually being built and the progress tracker
of that"* — the ask is a **list of things you are waiting on**. A payment that
leaves the row on that list, still counting, does not read as a purchase; it
reads as a smaller wait, and the player has to remember they bought it. A payment
that removes the row is unambiguous the moment the thumb leaves the glass. The
contractor row survives untouched as the doc's own acceleration valve for
projects not yet started; the rush is the one for projects you are *watching*.

**The cost of the choice, stated:** the `×2` crewing shape would have been the
gentler balance object — smaller quotes, no instant-power/instant-water shock —
and it is the shape a later wave should reach for if the roster's rush button
turns out to trivialise a chapter. Nothing here forecloses it: the price curve is
already parameterised by *fraction of duration bought*, so an overtime tier is a
second call against the same `CostCurves.rush_cost`, not a re-derivation.

### AA2. A rushed completion is the SAME completion, and that is a structural claim

The Wave-13 pump lesson, restated for money: *every event that completes or
creates a Building must reach `main.gd`'s translator, and a rushed completion
fires the SAME events as a natural one, never a new bespoke path.*

The mechanism is one function. `ConstructionQueue.force_complete()` deliberately
**does not route** the completion — it fills the accumulator, takes the job off
the queue and hands back the *identical record* `advance()` would have returned.
Both callers then pass that record to `CitySim._route_completed_jobs()`, which is
the loop lifted verbatim out of `WorkPhaseSystem.advance_fine`. There is no
second dispatch to keep in step, so the translator, the notification bindings and
doc 09's goal objectives cannot tell a rushed finish from a natural one — and
`tests/test_construction_rush.gd::test_a_rushed_building_equals_a_naturally_finished_one`
is the assertion that says so, comparing two cities field-for-field *and*
comparing the two event streams from `building_completed` onward.

The rush's own receipt, `construction_rushed{job, cost, source}`, is **additive
and rides in front**: the money left, then the ordinary completion happened. It
is the only new event, and it exists because the completion event says nothing
about a purchase — a player who paid has to hear the money leave.

### AA3. A refusal that takes nothing, and a refusal that is honest about which wall

Four codes, and the shape of the third and fourth is the ruling.

`E_UNKNOWN_JOB` and `E_JOB_COMPLETE` are facts about the queue. `E_NOT_RUSHABLE`
is the one the roster pre-announces: the row carries `rushable: false` and
`rush_cost: 0` when a project's cash price does not resolve, so `ui/` never draws
the button — the command's refusal is the **race-guard** for a tap against a row
drawn a frame ago, which is precisely how `cmd_collect_opportunity` earns its
`E_EXPIRED`.

`E_FUNDS` answers **two** walls on purpose: below doc 03 §2.10 layer 4's credit
floor, *and* under layer 2's austerity block on the `construction` category (a
rush is a new commitment, so layer 2 is right to close it). They are different
facts and the same sentence to a player — *the city cannot pay for this right
now* — and merging them costs nothing because the quote rides in `cost` either
way. What does **not** merge is the money: the gate is `Treasury.can_spend()`,
checked *before* the charge, so a rush is never deferred into a layer-4
liability. **A half-paid rush would buy a whole building**, and that is the one
outcome this verb may not have.

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

## AE. Wave-17 rulings — what the panel is asked to do today, and why that predicts bands in the sub menus and nowhere else (2026-09-01)

The screen-tearing investigation (doc 11 §2.13, doc 13 §2.8) has a verdict from
the player after days of play on the Aug-21 build: **"tearing only happens in
the sub menus."** World play is clean. That is not a weaker version of "the app
tears" — it is a much narrower claim, and it rules out most of the suspects the
open band has carried. This section writes down what the app actually asks the
display for today, why that asks for exactly the symptom described, and what
observation would refute it.

### AE1. Today the panel is asked for nothing at all, and the one line that could ask does not run at boot

Three settings and one assignment are the whole of this app's relationship with
the display, and none of them is a declaration.

* **`project.godot:45` `window/vsync/vsync_mode=1`.** VSYNC_ENABLED is a property
  of the SWAPCHAIN — present FIFO, do not tear at the swap. It says nothing
  whatsoever about which mode the panel runs in.
* **`project.godot:46-47` Swappy, `swappy_mode=2` (auto-fps + auto-pipeline).**
  Swappy is a **consumer** of the refresh rate, not a declarer of it: it measures
  frame time, picks a swap interval against the mode the panel is currently in,
  and paces to it. Hand it a panel that changes mode and it re-derives; it has no
  vote on when that happens.
* **`game/main.gd:1935` `Engine.max_fps = perf_governor.target_fps()`.** The only
  write in the shipped tree — `grep -rn "max_fps" game/ ui/` returns this line
  and `game/showcase.gd:138` (`= 0`, the screenshot harness), and nothing else.
* **The plugin says nothing.** At the Aug-21 build,
  `git show HEAD:…/SlacumNative.kt | grep -c 'setFrameRate\|preferredRefreshRate\|preferredDisplayModeId'`
  → **0**.

**And the assignment does not run at boot.** Line 1935 sits inside
`if perf_governor.update(delta):` — the branch that fires only when a knob moved.
`project.godot` sets no `run/max_fps`, so a fresh launch runs with
`Engine.max_fps == 0` until the governor first steps. The 2026-08-21 Fold capture
(doc 11 §2.13) held `knob = 0` and `thermal = 0` for its entire 38-second settled
window at **99.5 – 112.4 fps**. So the reference device was not running at 60 with
a declared 60: it was running **uncapped, at whatever Swappy paced against
whatever mode the panel had chosen for itself**, with nobody in the process
having an opinion about either.

**The ruling: the app's frame policy has a producer (the governor), a pacer
(Swappy) and no declaration.** On a fixed-rate panel that is a complete design.
On the reference device it is a design with a hole in it, and the hole is the
size of the panel's own mode policy.

### AE2. A cap the display was never told about is a cadence the platform has to infer, and an inference changes when its input does

The Fold 6's inner panel is **1856 × 2160, LTPO, 1–120 Hz adaptive**. An LTPO
panel does not have a refresh rate; it has a *current* refresh rate, chosen by
the platform, and the platform's inputs are what the app declares (nothing, here)
and what the app is observed to present.

That leaves observed cadence as the **sole** input. Which means:

* the panel's mode is a function of the app's frame time;
* the app's frame time changes whenever the workload does;
* therefore **every workload change is a candidate mode change**, and the app has
  no way to know one happened and no way to ask for one not to.

A mode change on an LTPO panel re-times the scanout. Done seamlessly it is
invisible; done across a frame that is mid-scan it is a horizontal discontinuity
— a band, not the diagonal shear a torn swap produces, which is one of the
reasons "tearing" has been the wrong word for this for three waves. **Nothing in
the app is asking for it to be seamless**, because nothing in the app is asking
for anything.

**The ruling: a frame cap that is not declared is not a frame policy, it is a
side effect the platform reverse-engineers.** The remedy is the shape of the
defect: declare the rate, and declare it in the same statement that caps it
(report 98 RR-126).

### AE3. Why the symptom is menus-only — and the one observation that refutes all of this

The menus-only shape is the strongest evidence there is, because it discriminates
between the suspects rather than merely being consistent with them.

1. **A sheet is a step change in cost with a STILL image behind it.** The 3D
   viewport keeps rendering while a sheet is open — doc 13 §2.8's modal row
   (`idle_fps`, `render_target_update_mode = UPDATE_DISABLED`) has never been
   implemented, and `grep -rn "idle_fps\|UPDATE_DISABLED" game/ ui/` returns
   nothing — so opening one adds the sheet's own cost and its build in a single
   frame without removing the world's. That is precisely the input a cadence
   inference reacts to.
2. **A still image is what makes a re-time visible.** During world play the
   camera is moving or the city is animating, and a seam lands on content that
   has already changed; over a paused-looking city under a flat UI panel the same
   seam sits on an unchanging picture and stays legible for as long as the eye
   looks at it.
3. **A flat panel is the worst possible carrier.** A band across a large area of
   one colour is maximally visible; the same band across a noisy skyline is not.

Every one of those three is specific to a sheet over a static world, which is
exactly the region the player reported and exactly the complement of the region
they reported clean.

**And this is falsifiable in one session.** Report 98 §46's A/B changes ONE thing
— whether the rate is declared — in ONE binary, with the perf-capture flag
disarmed in both arms so the GPU-timestamp suspect (doc 91 §19's row 5) is absent
from both. **If bands appear with `--refresh=auto` at the same rate as with
`--refresh=off`, this whole section is wrong**, the declaration keeps only its
battery and pacing arguments, and the next suspect is the one this cannot see:
the compositor's own handling of a translucent full-screen layer over a
SurfaceView. Say so in that order, and do not let the pin claim a fix it did not
make.

## AF. Wave-17 rulings — what the first complete device matrix says about measuring at all (2026-09-01)

*Three rulings. None of them is about a mechanic; all three are about the
conditions under which a device number may be quoted, and all three came out of a
session that ran perfectly and still produced three unusable captures out of
fourteen. Report 98 §47 / RR-129, RR-130, RR-131 is the binding form; doc 11
§2.13's "The 2026-09-01 session" carries the table. These are the three
decisions a mechanics reader needs.*

### AF1. A delta measured ACROSS an unnamed state is not a measurement of the thing you varied

The session set out to price three levers and found a **~2.5 ms two-state in
`gpu_est`** underneath all of them: seven of seven night captures read ≥ 8.5 ms,
and so do three of seven **day** captures, while the first three day captures and
the last capture of the session read 6.0–6.3 ms. Hour is *sufficient* for the
slow state and *not necessary* for it, and nothing in the fourteen captures
identifies the second cause.

**The rule, and it is what separates the three rulings from each other.** A
lever's A/B may be ruled when **both arms sit in the same state**, and may not
when they straddle it — regardless of how clean each arm looks on its own.

* **`road_detail` rules** (RR-129): both arms are adjacent captures inside the
  slow state, and the delta is +0.4 ms in the direction that makes the ladder
  pointless.
* **`flood_detail` rules** (RR-130): both arms adjacent, both 8.8 ms.
* **`pad_shadows` does not rule** (RR-131): its two arms are the *only* adjacent
  pair in the session that crosses the boundary — 8.6 ms and 6.5 ms — so the
  entire measured "cost of pad shadows" is the two-state, and the arm that
  allegedly cost 2.5 ms sets a flag to the value the build already boots with.

**Why this is a mechanics ruling and not a lab-technique note.** The tempting
move was to publish `pads1 − pads0 = 2.1 ms` as *the price of pad shadows* — a
number with an arm, a control and a plausible sign, produced by a harness that
exited 0. It would have been wrong, it would have overturned RR-33, and nothing
in the pipeline would have objected. **The defence is not more captures; it is
requiring an arm to be attributable before it is subtracted.**

### AF2. A capture's POSE is part of its identity, and until the harness asserts it, "same pose" is a hope

`cap_pose.sh` asserts one thing about a hold: that the app was in the foreground
before and after it. That caught `pads0` and correctly stamped it. It cannot see
the two failures that actually cost this session its pose matrix:

* **`rd0_h21`** — the camera moved *inside* the hold. `near: 6 → 0`,
  `prim: 45,820 → 53,666`, `dc: 90 → 130`, all in the single sample at
  `t = 14.0 s`, then flat for eighteen more. The harness reported a clean
  capture and `perf_rows.py` published a median across both halves (58.0 fps /
  11.1 ms / dc 130) that reads exactly like a `road_detail` result and is a pose
  result.
* **every zoom row** — the camera did not move *between* holds. Eleven of the
  fourteen captures share one `md5` over their whole render column set.

**The ruling.** A pose is asserted by the **census**, not by the argument that
was supposed to set it. `run_matrix.sh:152` already knows this — its own comment
names `near` as *"the column that proves the poses actually separated"* — and
knowing it in a comment is what let two sessions in a row publish one pose as
three. **Two mechanical checks discharge it, and both are one line:** stamp a
capture whose `near`/`prim` change by more than a threshold *within* the hold,
and refuse a *sweep* whose arms come back with an identical census. Neither is
this lane's to write and both are named in doc 11 §2.13.

**The corollary a mechanics reader should carry:** `near` is
`RenderStateModel.tier_census()["near"]` — chunks within `near_max_m = 150 m` of
`camera_rig.camera.global_position`, i.e. of the **eye**, not the focus. It is
therefore a direct function of zoom, which is precisely why it is the right
discriminator and why `near = 4` at `--zoom=0.0`, `0.5` **and** `1.0` is
impossible unless the argument is inert.

### AF3. A cap that is only written when something else changes is not a cap

`game/main.gd:1935` sets `Engine.max_fps = perf_governor.target_fps()` inside
`if perf_governor.update(delta):`. The governor returns true when a rung moves.
On a phone that never trips a rung — which is every settled capture this project
has ever taken on the Fold — **the cap is never written**, `project.godot`
carries no `max_fps`, and the frame free-runs at the panel's rate. Measured:
**106.5, 107.8 and 109.2 fps** at three daylight captures under
`preset=balanced`, whose `target_fps` is 60.

**Three consequences, and the mechanics one is the third.**

1. Battery and heat: doc 13 §2.8 calls the 60 cap *"the single biggest battery
   lever available (roughly halves GPU work)"*, and it has never been pulled on
   this device.
2. The high-refresh **toggle** is specified as opt-**in** and off by default;
   what ships is a build in which "off" is indistinguishable from "on".
3. **It corrupts every `fps` column this project has taken from this phone.**
   Free-running against a 120 Hz panel puts a hard cliff at 8.33 ms in the middle
   of the measured range. The session's day/night delta is **+2.60 ms of
   `gpu_est`** and reads as **−38.5 fps**, because 6.03 ms clears the interval
   and 8.63 ms misses it by 0.30 ms. **The ruling: quote `gpu_est`, never `fps`,
   from any uncapped device capture** — and the actionable statement of the
   night cost is *0.30 ms over a vsync cliff*, not *38 fps slower*.

**Why the fix is worth more than the three A/Bs it sits beside.** With the cap in
force, `fps` becomes a flat 60 on every settled capture and `gpu_est` becomes the
only column that moves — which is the shape every table in doc 11 §2.13 has been
trying to be. `A91-D-83`.

## X. Wave-17 rulings — where a colour is decoded, what a chunk count is, and a door with a sign on it (2026-09-01)

*Five rulings off the render/art fork that closed `A91-D-36`, built §2.11's
decal, and made the graphics presets reach the engine. Hash-neutral throughout,
on both cities. The full arguments and the measurements are report 98 §38
(RR-95 … RR-98 — §X3 and §X4 are two halves of RR-97, which absorbed the
re-open-condition ruling when RR-98 was re-assigned to the preset table);
what follows is what each one BINDS.*

### X1 — A colour is decoded ONCE, at the WRITE, and never at the constant (report 98 RR-95)

**Binding:** `srgb_to_linear` belongs at the point where an authored hex is
handed to something that will not decode it — and that point is the **write**,
not the **constant**, whenever the constant has more than one consumer.

§V4 established the first half: a MultiMesh instance colour takes no decode, so
an authored hex used as one renders about two stops light. This is the second
half, and it is the same rule on a different channel: a **vertex** `COLOR` takes
no decode either. What is new is *where the fix goes*. Three of
`ConstructionRigMesh`'s tints are read BOTH as vertex colours here and as
instance tints by `ConstructionActivity`, which already decodes them — so
converting the constant in place would have decoded them **twice** on that path
and turned a heap of gravel black while fixing nothing the mesh half needed. One
`srgb_to_linear` in each builder's `_push` gives every consumer exactly one
decode from one authored source of truth, at build time rather than per frame.

**The corollary, and it is the one that will save the next reader an hour.** A
constant that *looks* dual-use may not be: `GRAVEL` is named in RR-91's deferral
as "the dump truck's load and the yard's gravel heap", and the load half is dead
— `construction_rig.gdshader` replaces the vertex colour on `SURF_STOCK` with a
`source_color` uniform, which is decoded for free. **Check the consumer, not the
grep.**

**And the converse, which RR-91's closing note got wrong: an audit answer of
the form "every X is fixed" is a GREP, not a memory.** `_push(` across
`game/render/` and `set_instance_color(` across `game/` found two more vertex
builders (`ConstructionSiteView.PropMesh` — which also builds doc 04's
transformer pad — and `CobraHeadMesh`) and three more instance seams (the
hoarding panels, the traffic overlay band, the road-drawing ghost) that "every
authored livery" had not covered (report 98 RR-95 (continued)).

**One of the five was then recorded as "correctly left alone" — and that was
this section's own binding being broken by the paragraph that states it.**
`CobraHeadMesh` was written off as *"a value ramp, not a hex, and decoding it
would deepen weathering fitted by eye"*. Reading the writer, which is what the
rule says to do, shows the ramp MULTIPLYING two authored hex tints
(`COWL_TINT`, `LENS_TINT`) and reaching the shader through `ARRAY_COLOR` — not
through the `albedo_color` the note also claimed. **The channel carried both
things at once, and the rule as written offered only two answers.** So the rule
gains its missing third:

> **When a channel carries an authored colour TIMES a computed multiplier, the
> two are decoded separately: the colour takes the decode, the multiplier does
> not.** A ramp, a mask, an occlusion term or a fade is a reflectance
> multiplier — halving it means half the light — and belongs in linear.
> Decoding the product puts the multiplier through a 2.4 power: the cobra
> mast's foot goes from linear 0.41 to 0.18, which is not grime, it is night.

**And the census is now a TEST, because "check the consumer, not the grep" is
only half an instruction.** The grep is what produces the candidate set; reading
the writer is what decides each one; and *neither* survives as an audit answer
unless something re-runs it. `test_every_procedural_mesh_decodes_its_authored_vertex_colour`
walks `game/render/` for `Mesh.ARRAY_COLOR` and requires `srgb_to_linear` in
every file that has one. **A hand-kept list of builders is what missed this file
twice** — once in RR-91's closing note, once in RR-95's.

**And §V4's own second half applies to itself.** Every hex authored against the
broken seam is unfitted when the seam is fixed, and the re-judgement is a
screenshot pass and not an inspection. Two of twenty moved — `DARK` and `TYRE`,
in both mesh files — and they moved because decoded they landed **below** the
carriageway they were standing on, which is `CIV_PAINT[3]`'s failure one layer
down. The other eighteen survive, and the reason they survive is that the fix is
a DARKENING and a darkening is what it is for. **A hex is moved when the picture
asks; a part that is not in the picture is not re-judged** — the sprocket
inversion this pass found is real arithmetic on geometry that is fully enclosed
by its own track frame and has never drawn a pixel.

### X2 — A per-chunk cost is priced against the CENSUS, never against the model (report 98 RR-96)

**Binding:** where a doc prices a layer "per chunk", the number of chunks is a
MEASUREMENT, and until it has been measured the layer's cost is unknown.

Doc 11 §2.11 priced its contact decal at *"one extra draw call per NEAR/MEDIUM
chunk"* and §2.13's worked example spent six of them, from a model of 3 NEAR + 3
MEDIUM. The benchmark city at Z0 on Performance has **12 NEAR + 24 MEDIUM**, so
the per-chunk shape — which was built first, because that is what the doc asked
for — cost **36 draw calls** against a 180-call budget the city is already over.
One MultiMesh city-wide costs **one**.

This is RR-76's sibling and deserves its own name. RR-76 governs a derived total
re-derived from a source that has since MOVED. This governs a derived total
computed from a factor that was never measured at all: `near_chunk_max` is 3 and
the census reports 12, and nothing in the arithmetic ever asked. **A number
inside a budget claim is either measured or it is a guess wearing a table.**

**The layer-shape half, generalised.** §2.1.2 ruled that a layer with no
per-chunk state worth culling on should be ONE bucket city-wide — it was written
about roads and it is not about roads. A building decal has no per-chunk
material, no per-chunk uniform and two triangles per building; per-chunk buckets
bought it nothing and charged it a call each. **The corollary the second
application adds:** put the WHOLE roster in the buffer, not just the tiers that
draw, so the buffer is a function of the roster rather than of the camera —
scrubbing across a tier band then rewrites nothing and no block drops its shadow
as it crosses one.

**And a shared shader is not the same thing as a shared layer.** There are two
blob shadows in this renderer and they do not share a shader, deliberately: one
is a mode on a per-frame pool of objects that WALK, the other is a static decal
under objects that do not; one wants the glyph page and the other must not pay
for it; and the two take different gates from the same authored block. Sharing
the shader would not have merged the gates, only hidden the split.

### X3 — The lever with authority is not always the lever with the ruling (report 98 RR-97)

**Binding:** when a cue reads badly, name the lever that actually moves it, then
check whether that lever is yours to pull. If it is a whole-scene look decision,
the branch that found the problem ships the **ARM** and the **measurement**, and
does not ship the ruling.

§2.17's street-body blob is near-invisible on the carriageway, and `body_alpha`
is not the cause: a `blend_mix` decal darkens what is behind it by a FRACTION,
so the same disc is a **15/255** mark on the carriageway and a **40/255** mark
on the footway. The lever with authority is the road, and the road is every
street in the city on a phone screen. So this branch ships
`RoadSurfaceView.set_tint_gain(k)` — live, one uniform, byte-identical at the
shipped value — plus both commands and the question a device session has to
answer, and moves **nothing**.

**An A/B arm has to be checked for AUTHORITY before its result is believed**:
an arm that cannot move the thing under test returns a null result that looks
like an answer. This section was written on that binding and then, at the
re-measurement two days later, **broke it twice — which is why the binding now
carries two failures it caused rather than one it caught.**

**Failure 1: the arm was measured at a pose containing none of the thing under
test.** The re-measurement began at Z0, `--focus=52,44`, and moved **zero
pixels at `k = 4.0`** — three shots at `k` = 1.0, 1.5 and 4.0 were byte-identical
by `md5sum`. The arm was not broken; that pose has no carriageway in it. A null
from an empty frame is indistinguishable from a null from a dead lever, and the
only thing that told them apart was making the harness print the uniform **read
back off the live `ShaderMaterial`** beside the value the arithmetic wanted.
**So the binding grows a clause: an arm reports what the ENGINE holds, not what
the resolver computed, and it reports the size of the thing it is measuring in
the frame.** `profile_frame`'s `ROAD TINT` line does both now.

**Failure 2: the numbers this section published were wrong about the shape of
the answer.** It claimed a 1.5× tint lift moves the rendered carriageway by
17 % by day and by 1.6 % at night, on the theory that after dark the road's
value belongs to `road_night_albedo_lift` and `road_night_glow` in a different
block. Re-measured at Z1/Z2 on a road-bearing pose, the same +21.4 % lift of
the authored triple moves it **+3.1 % / +1.2 % by day and +3.6 % / +2.5 % at
night** — there is no day/night asymmetry, and at Z1 the night arm moves the
road *more* than the day arm. The theory was reasonable and it is not what the
frames do.

**What survives is the ruling, and it survives STRONGER.** The response is
near-linear and measured rather than extrapolated (`k` 1.0 → 3.0 gives
73.55 → 81.96 luma at Z1 by day, **+4.21 luma per unit of `k`**, against +4.46
from the 1.0 → 1.5 arm), so moving the road the ~15/255 §2.17b's blob needs
takes **`k ≈ 4.6`** — an authored tint near `(0.68, 0.68, 0.73)`. That is not a
tint adjustment, it is a different, pale-grey road: the lever with authority
here is bigger than the branch that found the problem, which is exactly what
this section says to do about it.

### X4 — A re-open condition is written in terms of an instrument that EXISTS (report 98 RR-97)

**Binding:** a deferral's re-open condition names something the project can
observe **on the day the condition is written**. A condition whose trigger
requires a capability the project does not have is not a deferral — it is a
refusal wearing a deferral's clothes, and it is worse than an honest refusal
because it reads as revisable.

§V1 ruled `expire_stability_delta` at 0.0 and made the ruling's own
re-openability part of its argument — *"'we decided not to' is a decision that
has to be re-openable"* — then wrote the trigger as *"telemetry showing players
farm-ignoring crooks at scale"*. **There is no analytics path in this project**:
the crash sentinel writes a local file and sends nothing, no `INTERNET`
permission is requested, and doc 91 §17 records the Data Safety declaration that
absence buys. The door was shut and signposted with a key that does not exist.

The condition is restated at §V1 in terms of the two instruments this project
runs — a play session and `tools/run_matrix.sh` — and the ruling, the authored
0.0 and the test are unchanged. **Every other re-open condition in this document
was checked against this rule at the same fork and they pass**: they name a
`profile_sim` digest, a balance gate, or a device session, all of which exist.

### X5 — A table of knobs is a table of knobs only while something READS it, and the test that keeps it so names the consumer (report 98 RR-98)

**Binding:** a configuration table that a player, a governor or a device tier
selects between is only real to the extent that every row in it reaches an
engine call. A key with no consumer is not a setting that is "not implemented
yet" — from the outside it is indistinguishable from a setting that works,
because the row appears in the menu and the value appears in the file. **The
guard is a test that names the CONSUMING FILE per key, not a test that checks
the value**, because the failure mode is not a wrong number; it is a right
number nobody fetches.

Wave 17 found **twenty-two** such keys in `data/render.json`'s three preset
rows (the count is a `grep` over the fork tree, and it corrects a "thirteen"
that an earlier draft of this section published from memory), one
of which — `render_scale` — was read in exactly one place: `SettingsModel`, to
**sort the graphics menu cheapest-first**. The number that decided the order of
the rows was the number that did nothing when a row was picked. Two more
(`msaa`, `fxaa`) did not appear anywhere in the source tree in any form. The
observable consequence was the audit's own sentence, *"High is Balanced with
more cars"*: with the engine-side half of every preset unread, the only
differences that reached a frame were vehicle caps, particle counts and draw
distance.

**Three corollaries, each of which cost something here.**

1. **A budget is not a knob, and deleting it is not the fix.** Nothing applies
   a budget; something must CHECK it. Eight of the unread keys
   (`gpu_budget_ms`, `chunk_budget`, `vram_budget_mb`, …) were the published
   statement of what a preset is allowed to cost, and the answer was to gate
   them in the instrument that was already measuring every quantity they bound,
   not to remove the statement.

2. **A key whose feature was never built is DELETED, and the promise that it
   was coming is deleted with it.** `street_light_radius_m` described an
   OmniLight pool; `StreetlightView`'s class doc had said *"the OmniLight pool
   arrives with the perf pass"* for four waves after the billboard-and-decal
   rig had made it unnecessary. The stale promise is why nobody re-checked the
   key. Six keys and one sentence went together.

   The same corollary has a **converse that cost more**: a key deleted on a
   claim about its consumer, when the claim is wrong, deletes a working lever.
   `civ_headlights` was on the deleted list on the ground that it "duplicates a
   cap `vehicles.headlight_*` already owns" — but those four rows are a night
   threshold, a cone length, an energy and a colour, none of them a count, and
   `MM_headlights` was in fact the **one buffer in `VehicleView` with no
   ceiling at all**. **Deleting a key requires the same evidence as wiring
   one: the grep, not the recollection.**

3. **The same rule reaches into shaders.** `building_far.gdshader` held one
   neutral albedo pair for five building families while the tier in front of it
   painted five measured façade pages — a constant standing in for a table
   nothing read, drifted 6.6× on one family without anyone writing a wrong
   number. The fix is the same shape as the preset fix: **measure the thing the
   other tier actually uses and hand it over**, so the two cannot drift again.
   A second copy of the art is not a palette, it is a bug with a schedule.

**Re-open condition** (per §X4, and named against an instrument that exists):
if `tests/test_render_polish.gd::test_no_inert_preset_key` is ever relaxed to a
warning, or if a preset key is added with its consumer listed as a file that
does not read it, this ruling has failed and the census in report 98 RR-98 is
re-walked key by key.

## F. Explicitly deferred (unchanged from master plan)

Multiplayer/social, city trading, seasons/holidays, mod hooks, cloud saves,
monetisation — none are Phase-1/2 scope; nothing in Waves 1–3 blocks them.

---

## AG. Wave-17 rulings — the absence a dead process owes, and why two absences are never one plan (2026-09-01)

*Three mechanics questions came out of the cold-launch branch. Two of them are
about what a player is OWED, which makes them fairness questions and therefore
this document's; the third is about which of two arrangements of the same work
is the honest one.*

### AG1. The absence belongs to the SAVE, not to the process

**Question.** A process dies while the player is away. When they open the game
again, what does the city owe them, and measured from what?

**Ruled: from the moment the generation on disk was committed, and it owes it on
every path back in.** The alternative the code had — "measure from the pause this
process saw" — is not a rule about the player's time at all; it is a rule about
the process's luck. A player who was away eight hours got eight hours if Android
happened to keep the process and **nothing** if it did not, and they cannot tell
those two cases apart. Core Design Rule 2 says the city continues while the
player is away; it does not say *while the process survives*.

Two corollaries that fall straight out of it and are worth stating because both
were live bugs:

* **The title door's CONTINUE is a cold launch.** It is the *default* player
  launch (doc 12 §2.19: every clean launch that is not `--resume` and not crash
  recovery), and it loads inside a process that never paused. It was the worst
  case of the P0, not an edge of it.
* **A fresh city owes zero, and so does a clock that went backwards.** Neither is
  a fault and neither gets a veil. Doc 08 §2.9's rule is *clamp, never punish*,
  and the branch adds only that the clamp says so in the log.

### AG2. SEQUENTIAL, not merged — and the reason is that "merged" cannot be written down

**Question (the one report 98 §48 asks to be argued here).** The player
backgrounds the app while the catch-up veil is up. On the way back there are two
absences: what is left of plan 1, and the new one. Keep stepping plan 1 and plan
the second absence when it finishes — or merge the remaining ticks and the new
elapsed into a single plan?

**Ruled: sequential, with the remainder carried as SEGMENTS in front of the new
plan's segments.** Not because merging is worse, but because **the merge that was
proposed cannot be expressed.** "Remaining ticks + new elapsed" is a duration,
and a plan is not a function of a duration. It is a function of:

* the **tick index it was planned at** — which fixes the fine head-align that
  gets the coarse body onto an hour boundary (doc 91 D-1) and the 40-tick fine
  tail;
* the **residual** the planner left, which belongs to the whole of absence 1 and
  not to the part of it that has run;
* and, for a coarse segment already part way through, the segment-relative
  `ctx.catchup_index` / `ctx.catchup_total` that doc 03's offline yield decay and
  doc 07's 72-hour offline event gate both read.

Turn the remainder into milliseconds and every one of those is lost: the head is
re-aligned against a clock that has moved, the residual is double-counted or
dropped, and hour 5 of a 10-hour segment is told it is hour 0 of a 5-hour one —
so doc 03 restarts the decay curve and doc 07 re-opens the event gate. **The
player would be paid differently for the same absence depending on when Android
happened to kill them**, which is precisely the unfairness AG1 exists to close.

Carrying the segments has none of those problems and one property the arithmetic
version could never have: the result is *bit-identical* to the uninterrupted run,
which is a claim a test can make.

**What "sequential" costs, honestly.** Two veils where a merge would show one,
and two away reports where a merge would show one. Both are the right answer
anyway: absence 1's report diffs the pre-absence city, absence 2's diffs the city
absence 1 left behind, and a single merged report would have had to pick one
'before' and be wrong about the other. And the second veil is usually not a veil
at all — an absence under doc 01's 120 s grace credits zero ticks and
`data/ui.json.veil.min_steps` refuses to raise a veil for it.

**One place they DO merge, and it is not this question.** A process death mid-veil
followed by a long absence produces a carried tail *and* a new elapsed measured
from the same stamp, and those go into `CatchUpPlanner.plan_after` as one
schedule with one veil — because there was only ever one moment the player left.
Two absences are two absences; one absence interrupted by a kill is one absence.

### AG3. A pause taken mid-absence is not a moment the away report may quote

**Question.** `_on_app_paused` captured the five figures the WHILE YOU WERE AWAY
report diffs. What should it capture when it fires *during* a catch-up?

**Ruled: nothing.** The report's 'before' means *the city the player left*, and
mid-catch-up the live city is a city part way through the absence being
reported — diffing against it would show the player a fraction of their own
progress and call it the whole of it. So the snapshot is skipped, the existing
one stands, and it rides `last_pause.unfinished.before` across a process death so
that even a relaunch reports against the city the player actually left.

The same ruling settles the notification pass: `plan_for_background` schedules
alarms from construction that completes at a known tick and Director events
pre-rolled into the save (doc 13 §2.4 classes (a) and (b)). Mid-catch-up neither
has settled, so the alarms would be predictions about a future that is still
being computed. It is skipped, and the resume — cold or warm — re-plans from the
finished city, which is what doc 08 §2.13 already says happens on every resume.

## AC. Wave-17 rulings — the pitch axis: what composes, what may miss, and what a headless mount is allowed to claim (2026-09-01)

### AC1. A camera axis the player drives COMPOSES with the authored curve; it does not replace it

`pitch(t) = 34° + 28°·smoothstep(t)` stays the answer the camera rests on. The
manual axis is a normalised lean on top of it —
`pitch = lerp(curve(t), target, |bias|·reach(t))` — with three consequences that
are the ruling:

* **AUTO is a bit-exact identity.** At `bias = 0` the composed pitch *is*
  `pitch_deg_at(t)`, so a city whose player never touches the slider renders the
  camera it rendered before Wave 17. A design that offset the curve, or replaced
  it, could not say that, and every screenshot and coverage table in doc 12 §2.16
  would have needed re-taking.
* **The middle detent means something.** `pitch_detent_units = 0.04` snaps a
  release near the middle back to AUTO — the state, not a value that resembles
  it — which is how a player finds the middle without aiming for it and how the
  camera keeps re-deriving its own pitch on the next pinch.
* **The zoom still owns the default.** Zooming out after a lean re-composes
  against the new curve rather than holding an absolute angle, so the axis cannot
  strand the player at a pitch the zoom was never designed for.

**Re-open** only if a pose is wanted that the composition cannot reach — the first
candidate is a true 90° top-down, deliberately excluded because yaw stops meaning
anything there and the twist gesture becomes a spin about nothing.

### AC2. A budget a feature cannot meet is published with its mechanism, not tuned into a feature nobody asked for

The pitch floor takes the bench city to 363 dc+ui at Z0 by day against a 320
budget (doc 92 §47). The knee is at `pitch = FOV/2 = 20°`, where the horizon
enters the frame — so the only band that stays inside the budget is one that
cannot see the sky, and the user's directive was to see the sky. The ruling is
therefore: **state the excess, name the mechanism, couple the band where the
coupling buys something real, and hand the runtime case to the governor.** The
far end is coupled (`reach_up_far = 0.76`) because there the measurement bought a
tier boundary — 4 NEAR chunks and 97 dc — rather than a preference; the near end
is not, because there it would buy only the number.

### AC3. A query that can fail answers whether it failed; the old total function stays for the callers that were always right

`ground_hit()` returns `{hit, position, reason, distance}`;
`screen_to_ground()` remains, unchanged, on top of it. Both are correct at once
and the split is the ruling: **pan, pinch and the anchor lock want a point and
have always wanted the clamped one**, while placement, picking and focus must not
act on a guess. Making the honest read the only read would have made the pan
stutter at the frame edge — a worse bug, introduced while fixing a better one.

The rule generalises to every ray this project casts from a screen point: the
caller that *acts* on the world branches on `hit`; the caller that *tracks* the
finger does not.

### AC4. A test may only assert what its harness can produce

Two shapes, both found green in salvaged Wave-17 work (report 98 RR-117):

* A **headless** `UIRoot.force_layout(box)` produces no layout at all — the
  containers do not fit invisible children — so a test asserting a laid-out rect
  is asserting the harness. Assert what the code sets (anchors, offsets, the band
  solve); photograph the rect where a viewport exists (`tools/ui_preview.gd
  --audit --strict`).
* A **synthetic gesture** fed one finger-jump at a time is not the device's
  event stream. Two-finger strokes are walked in device-sized steps, and the
  intermediate sample — one finger moved, one not — is part of what the
  recogniser must survive, not an artefact to be fed around.

## AD. Wave 17 — the doc 04 model, audited end to end (2026-09-01)

The user's two reports, three weeks apart, are the same report: *"feeders adding
extra power to a building is not clear and I'm not sure it actually works"*
(2026-08-21) and *"we have to really take a deep look at how the transformers
feed power, how power stations add to the overall grid capacity — it doesn't
seem to be working well at all"* (2026-09-01). This section is the audit that
answers them, run as a tool rather than read: `tools/audit_power.gd` boots a
city, plays it if asked, and answers five discriminating questions as numbers.

**The runs.** `godot --headless --script tools/audit_power.gd` (starter city,
seed 1337, 6 fine game-hours) and the same with
`--city=res://tests/fixtures/bench_city.json` (1,500 buildings).

### AD1. The five questions, answered on two cities — **AT THE FORK**

Every number in this table is the state of the game BEFORE this wave's fixes.
The after-numbers, and the delta each fix accounts for, are doc 92 §48.

| Question | Starter (34 buildings) | Benchmark (1,500) |
|---|---|---|
| (i) does a second station raise `system_supply_kw` by its rating? | **yes, 8,000 → 16,000 kW** | **yes, 240,000 → 248,000** |
| …and how many `POWER_CAPACITY` blockers does that clear? | **0 of 1** | **0 of 140 — and 14 MORE appeared** |
| (ii) where does every blocker actually bind? | transformer **1 / 1** | transformer **140 / 140**, feeder 0, substation 0 |
| …with what pool headroom? | **7,488 kW spare, r 0.064** | **105,198 kW spare, r 0.562** |
| (iii) can a feeder route reach a blocked transformer? | no feeder-bound blocker to route to | **`E_NOT_CONNECTED` on a map with six substations and 36 feeders** — see AD2(b). It answers `E_NO_SLOT` after the fix, which is both true and buyable |
| (iv) what sheds, and does the player see it? | nothing sheds (no deficit) | **4 feeders, 15,239 kW dark**, `LoadShedStarted` + 4 × `BlockDarkChanged` |
| (v) what silently refuses? | transformer levels **[1,2,3]** of a **[50,150,400,1000,2500]** ladder; feeder classes **[1,2]** of **[1200,3000,7500]** | same roster, against **authored L5s and class-3 trunks** |

**The finding.** The model is not broken. Supply rises by exactly the rating,
the four-pass solve is correct, and shedding works. What is broken is that
**the pool has never been the constraint and the constraint could never be
bought**: on both cities, 100 % of the blockers bound at a pole-top transformer
while the bulk pool sat at 6 % and 56 % of supply, and the biggest transformer
the build sheet would sell was **400 kW against a 2,500 kW authored node**. A
player buying a second station is buying the one thing that cannot help, and
nothing in the game told them so. Filed as **A91-D-55**; the roster ruling is
doc 04 §6.1 and the reading that makes it legible is doc 12 §2.10 D-72.

### AD2. Defects the audit found, each with the test that would have caught it

Every row is closed in this wave. Tests are in `tests/test_power_operations.gd`.

| # | Defect | Test |
|---|---|---|
| **AD2(a)** | The placeable roster stopped three rungs below the authored city (A91-D-55). | `test_c_upgrade_grid_component_prices_and_refuses_per_its_header` walks the whole ladder at doc 03's prices and asserts **only L5 / class 3** answers `E_MAX_LEVEL`. |
| **AD2(b)** | `_best_feeder_source_for` walked the BUILDING roster, so an authored substation was invisible to the player's own routing verb and `_route_line` answered `E_NOT_CONNECTED` rather than `E_NO_SLOT` (A91-D-55). | `test_b_a_feeder_bound_blocker_gets_heavier_copper_or_a_new_run` routes from a substation and asserts the run is adopted. |
| **AD2(c)** | `can_upgrade_power` returned a kW deficit and no id, so no surface could name the hop that binds (A91-D-55). | `test_a_the_upgrade_gate_names_the_component_that_binds`. |
| **AD2(d)** | A zero-delta upgrade was refused `UNSERVED`, making the substation ladder unbuyable (A91-D-53). | `test_a_a_zero_delta_upgrade_needs_no_headroom_so_a_substation_can_be_upgraded`. |
| **AD2(e)** | `is_energized` was a bare `_components[id]` index — a key error on any id the grid no longer carried, which the demolition verb makes reachable. | `test_d_demolishing_a_transformer_darkens_its_stranded_customers_through_the_ledger`. |

### AD3. P0 — placement checked COVERAGE and never CAPACITY

`CitySim.cmd_place_building` and `BuildController.evaluate` both gated on
`PowerGrid.would_serve(origin)`, which answers *"is this tile inside some
transformer's service radius"*. Capacity was never asked, so **a green ghost
could stand a 98 kW water facility on a 50 kW pole-top that was already at
r 0.9**, and the first the player heard of it was the whole street browning out.

**Ruling: it is a WARNING, not a refusal.** Doc 04 §2.1 gates placement on
coverage and authorises no capacity gate; inventing one here would be a balance
change wearing a bug fix's clothes, and it belongs to the economy lane if it is
wanted. What ships is the fact: `PowerGrid.can_serve_tile` walks the path the
new load would take, `CitySim.serving_headroom_for_new` scales the archetype's
level-1 draw to its channel's daily peak, the ghost goes **amber**
(`E_TRANSFORMER_FULL`, `SEVERITY_WARN`, `FIX_TILE`) and `cmd_place_building`'s
own answer carries the same dictionary. **Re-open condition:** if the economy
lane wants placement to refuse, the code path is one `return` in
`cmd_place_building` and the rule is already computed.

*Test:* `test_f_placement_warns_when_the_serving_transformer_cannot_carry_it`.

### AD4. P1 — headroom was judged at the hour the player happened to tap in

Every headroom gate in the project read `PowerGrid._components[id].load_kw`,
which is the load **at this instant**, and doc 01's demand channels swing that
load by more than a factor of two across a day:
`power_demand_residential` runs **0.67 at 05:00 and 1.46 at 20:00** (2.18×),
`power_demand_commercial` **0.36 at 00:00 and 1.51** from 10:00 to 18:00
(4.19×). An upgrade approved in the residential trough is an upgrade that
browns out at dinner, and nothing told the player which hour they were reading.

Closed by `CitySim.peak_component_loads()`: each building's present demand is
scaled by **its own channel's** daily maximum over that channel's value now, the
scaled demand is walked up the service path exactly as `_pass_a` walks the live
one, and the result is handed to `can_upgrade_power` as a `load_override`. The
scale is **clamped at 1.0 from below** — the gate may never be more permissive
than the live reading, which is the one number doc 04 §5.3 has always been
written against — and the table is memoised on `(game-minute, grid.
mutation_epoch)`, because the placement ghost asks for it once a frame.

**Measured consequence** (`tools/audit_power.gd`): starter city 1 → **2**
blockers, benchmark 140 → **400**, of which **86 now bind at a feeder** where
the live-load reading saw none at all. Those blockers were always real; the game
was reading them at the wrong hour.

*Tests:* `test_f_the_headroom_gate_is_read_at_the_peak_not_at_the_trough`,
`test_f_the_peak_table_is_memoised_and_survives_a_grid_change`.

### AD5. P1 — `CapacityWarning` was authored and never emitted

Doc 04 §4 lists `CapacityWarning` among the events the grid raises. Nothing in
`sim/power/power_grid.gd` ever called `_emit` with it, so **the only cue a
transformer gave before failing was the failure** — §2.8's burnout, which is a
repair bill and an outage.

It now fires on an **upward band crossing** of §5.10's own thresholds
(`r ≥ 0.75` WARNING, `r ≥ 0.95` CRITICAL, derated), with a 0.03 re-arm margin so
a load hovering on the line raises one warning rather than one per fine tick.
Downward moves are silent: "your transformer is fine again" is not an
interruption. `data/notifications.json` binds **band 2 only** to a P3 row
(`capacity_warning`), because a P3 that fired at 0.75 on every transformer in a
growing city is the notification a player turns off.

**The implementation is stateless, and that is the interesting part** (doc 98
§44 RR-118): the obvious version is a per-component "already warned" latch, and
a latch is state that must be captured, restored and hashed — it would have
moved every baseline in the project for the sake of an event. The previous
tick's `load_kw` is **already in the save section**, so the crossing is derived
from what is there and a restore compares against the same number the live sim
does. All four baselines are bit-identical across this wave.

*Test:* `test_f_capacity_warning_is_emitted_when_a_component_crosses_a_band`.

### AD6. Two more, found while looking

**An UNSERVED building was permanently, silently lit.** `PowerGrid.is_powered`
answers `true` for a building the grid has never heard of (a deliberate default:
it is what the pre-boot roster needs), and `attach_building` opened **no service
record** when it found no transformer. A building that fell out of every service
radius was therefore invisible to `unserved_building_ids`, uncounted by
`block_dark_fractions`, and un-adoptable by the very transformer upgrade whose
wider radius now reached it. Closed by opening the record either way — doc 98
§44 RR-119. *Test:* `test_f_an_unserved_building_is_on_the_books_rather_than_permanently_lit`.

**The load-shed rank read one building per feeder.** `_shed_score`'s loop
carried a `break` on its first match, so a whole trunk was ranked by the priority
class of whichever attached building sorted first by id — reproducible, and
arbitrary. `_feeder_has_critical` is why nothing catastrophic came of it
(criticals shed last as a hard rule above the score). Closed by summing the
whole feeder, weighting each building by its transformer's load share — doc 98
§44 RR-121. *Test:* `test_f_the_shed_score_reads_the_whole_feeder_not_its_first_building`.

### AD7. What the outage costs, measured

`cmd_demolish_grid_component("T-04")` on the starter city — an L2 with four
customers, **refund $275** (doc 03 §2.3's 0.25 × the $1,100 build cost) — against
an otherwise identical control city, both advanced the same hours:

| | h+1 | h+2 | h+3 |
|---|---|---|---|
| dark buildings | 4 | 4 | 4 |
| control treasury | +$504 | +$1,008 | +$1,511 |
| victim treasury, net of refund | +$505 | +$982 | +$1,458 |
| **cost of the outage** | **−$1** | **$26** | **$53** |

**A one-game-hour outage of four houses costs about nothing**, and that is a
finding, not a null result: the tax those four houses pay in an hour is smaller
than the hour's noise, so the outage's real price is the *happiness* and the
*development* it stalls, not the ledger line. On the benchmark city the same verb
on T-001 (L5, 13 customers, 4 stranded, refund $4,075) is the same story at
scale. **`MOVE` is demolish + place** and is priced honestly by the panel:
`move_cost = replace_cost − refund`, **$825 for an L2**. Ruling: no move-window
refund. The lights going out and the hurry to get them back on is the mechanic
the user asked for by name, and a free move deletes it.

*Tests:* `test_d_move_is_demolish_plus_place_and_the_lights_come_back`,
`test_g_the_transformer_demolish_quote_prices_the_move`.

## Y. Wave-17 rulings — who pays for a building, and the three prices the 2026-09-01 playtest called wrong (2026-09-02)

Three notes came back from days of play on the Fold, and each of them is a
ruling before it is a number:

> **(a)** "Buildings being destroyed and repaired is way too aggressive. Repair
> prices should fall on the OWNERS of the building, not the city, and we
> shouldn't have to interrupt the gameplay to repair buildings because nothing
> actually happened."
> **(b)** "Money income could be higher — we wait too long for money to generate."
> **(c)** "Upgrading buildings is way too aggressive on the prices."

§Y1–§Y3 answer (a), §Y4–§Y6 answer (b), §Y7 answers (c). Every number is
measured in doc 92 §43, and every gate a ruling moves is re-fitted there with
its derivation.

### Y1. The city buys no repair for a building it does not own

**Question.** Doc 03 §2.4's `E_building_maint` bills the treasury
`capital_value(L) × BUILDING_MAINT_RATE × (1 + MAINT_CONDITION_PENALTY × (1 − C))`
every settled game-hour, and doc 02 §2.6's `cmd_repair_building` sells the
player a repair on any building at all. Which of those is *right*, and for which
buildings?

**The observation that starts it.** `EconomySystem.settle_hour`'s maintenance
loop skips every row for which `CostCurves.is_revenue_producing(type)` is false —
C-08, so a civic or utility shell is not billed twice beside its own department
or O&M line. That predicate is `REVENUE_CLASSES.has(class_of(type))` and
`REVENUE_CLASSES` is `["residential", "commercial", "industrial", "tech"]`. So
the set of buildings `E_building_maint` bills is exactly the set the city does
**not** own, and the first draft of this ruling retired the line on that reading.

**That draft was measured before it was believed, and the measurement refused
it.** With the line retired *and* private stock keeping itself up,
`tools/measure_insolvency.gd --max-days=200` put `do_nothing` on `standard` at
game-day **176** against gate 29's ruled 69, and `casual` **never went insolvent
inside 200 game-days at all**. Gate 29's own header says why that is
disqualifying: *"a preset on which standing still never costs anything is a
preset with no game in it"*. §Y8 has the autopsy.

**Ruled, in two halves.**

**(a) `E_building_maint` STAYS, and §2.4 says what it is.** It is the city's cost
of *serving* a building — which is the reading C-08's own exclusion implies,
since civic shells are excluded because *their own O&M lines bill them*, not
because the city only pays for what it owns — and it rises as a building wears
because a worn building costs more to serve. Not one cell of it moves.

**(b) The REPAIR moves to the owner, and it is the repair the playtest was
about**: a lumpy purchase, at a price, behind a tap, on a building the player
does not own. `cmd_repair_building` refuses private stock with
`E_OWNER_MAINTAINED` at any condition, and the panel draws no row for it (§Y3a).

| asset class | what is in it | who pays the REPAIR | what the player sees |
|---|---|---|---|
| **Private stock** | `house`, `apartment`, `store`, `office`, `high_rise`, `data_center` — the four `REVENUE_CLASSES` | **the owner** | no REPAIR row at any condition, no toast, no banner, no push. Only `f_condition` on the tax line, and the city's own `Building upkeep` line, which it always paid |
| **Roads** | every STREET / AVENUE tile | **the city** | the `E_roads_repair` accrual, doc 10 §2.13's auto-repair policy, the `road_condition_critical` log row |
| **Water infrastructure** | mains, and the five `water_facility` variants | **the city** | the water panel's repair quote; doc 05's own alerts |
| **Power infrastructure** | `power_facility`, `substation`, transformers, lines | **the city** | the grid-health chip; the panel's REPAIR row |
| **Civic buildings** | `police_station`, `fire_station`, `construction_yard` | **the city** | the panel's REPAIR row, and the Upkeep band |

**What the owner actually does — a FLOOR, not a restoration.** A private building
wears exactly as §2.6 has always said (**this ruling moves not one
`decay_per_hour` cell**), and its owner will not let it fall past the Worn band's
floor, `condition.band_worn` = 0.60, because below that it stops being an asset
and starts being a liability, and it is *their* asset. So a private building is
**never `damaged` by wear, never destroyed by wear, and always still
upgradable** — 0.60 sits above `min_condition_to_upgrade` 0.55, and that ordering
is what makes the floor a floor rather than a trap. An incident that damages one
is still doc 06's, and the owner rebuilds from `damaged` to §2.12's post-damage
target on §2.6's own crew-hours.

**No number is authored for any of this.** The floor is doc 02 §2.6's own band
table; the rebuild rate is §2.6's own `repair_hours` read as a rate; the service
gate is doc 04's own availability fraction.

### Y1a. The service clause — a floor the city has to keep paying for

**Question.** If private stock holds a floor, can a player neglect a city to
death any more?

**Ruled: the floor lifts the moment the city stops serving the building.** Both
the floor and the post-incident rebuild are gated on doc 04's
`power_availability_hour` — the argument `apply_decay` already takes. A building
the city has left **dark** is held by nobody: it wears at the unpowered rate,
crosses the auto-damage line, emits, and `roll_structural_failure` can take it.

**And §Y8 is the honest footnote to that**: on this fork the signal it depends on
does not fire, because destroying the plant and the substation darkens nothing.
The clause is right and it is not currently load-bearing, so the neglect clock
this ruling leaves behind is measured rather than assumed, and gate 29 is
re-fitted onto what was measured (doc 92 §43.8).

### Y2. `data/building_rules.json.condition` becomes a source (PA-13)

**Question.** The 2026-09-01 production audit's PA-13 found that every key in
`building_rules.json.condition` is validated for presence, asserted by
`tests/test_building_catalog.gd`, and **read by nothing** —
`sim/buildings/building.gd` hardcoded all of them as consts and literals. Any
retune that edits that file therefore changes nothing.

**Ruled: `Building` reads the condition block, and the block is stamped on the
instance beside `stats` and `max_level`.** Not a static and not a singleton —
`sim/` is RefCounted-only and the test rigs boot several `CitySim`s in one
process, so a process-global rules dict would let one city's fixture move
another's physics. The coordinator stamps the same shared `Dictionary` on every
`Building` at the four sites that make one live (boot, restore, building
placement, and doc 05's water shell), and a `Building` that is never stamped
falls back to `DEFAULT_CONDITION`, whose values are the consts this ruling
deletes — so every fixture and every worked example is bit-identical to the day
before.

This ruling is what makes §Y1's floor expressible at all: the floor **is**
`band_good`'s neighbour `band_worn`, read from the file, and before PA-13 was
closed there was no reader to read it.

**The gate is PA-13's own:** `tests/test_building.gd` perturbs an authored key
and asserts the *behaviour* moves, not that the loader accepted it. **Scope: the
`condition` block only.** `construction.*` and `headroom_safety` are the same
defect in the same file and belong to the construction-queue and power lanes;
PA-13 stays open until they land.

### Y2a. PA-82's decay cap is DECLINED, with the measurement that declines it

**Question.** PA-82 asks that civic and utility L1 decay be capped at the house
rate — `power_facility` 0.00090, `substation` 0.00080, `water_facility` 0.00070
and `construction_yard` 0.00065 all to 0.00045 — because those are the first
repair bills a player ever sees.

**Ruled: no. The city's own decay rates are the only neglect clock left after
§Y1, and they may not be softened.** The cap was implemented, measured and
withdrawn:

```
tools/measure_insolvency.gd --max-days=200, do_nothing, seed 1337
  with the cap      casual  NEVER   standard 168   hard 128   crisis 71
  without the cap   casual  NEVER   standard 175   hard 131   crisis 38
  gate 29's ruled   casual    105   standard  69   hard  51   crisis 26
```

Two things fall out of that pair. The cap on its own **doubles the standard
clock** — and withdrawing it moved the broken clock by seven game-days, which is
the other half of the finding: the cap was never the *cause* of the break (§Y1's
first draft was), but it is a large enough term that it cannot be added on top of
a ruling that already halves the engine. Doc 02 §2.3's Decay columns are restored
cell for cell and no private seed was ever touched.

*PA-82's row is not thereby dismissed.* Its complaint is that the plant's and the
water works' first quotes land before the sheet has taught repair, and that is a
**curriculum and surface** problem — the Grid-health chip warning from plant
condition, which PA-82 itself proposes and which is the power lane's — not a rate
problem. Recorded as declined-on-the-rate, open-on-the-surface.

### Y3. What the player sees of an owner's floor, and what they do about it

**Question.** §Y1 says the owner holds a floor. What does the city see, and what
is the player's recourse?

**Ruled: the city sees `f_condition`, and the recourse is to INVEST, not to
repair.** A private building that has been left to wear settles at the Worn
floor, where `f_condition = COND_FLOOR + (1 − COND_FLOOR) × 0.60 = 0.76` — **a
permanent 24 % cut in what that building pays the city**, and the only thing the
city sees, because there is no repair to buy at any condition.

**The recovery is an upgrade.** `complete_construction` sets condition back to
1.00, so the answer to a worn city is to put money into it — which is the loop
doc 09 level 2 already teaches, and which §Y7 made **20.7 % cheaper** in the same
wave. That is the shape this pass wanted: the three playtest notes turn out to be
one loop, and the fix for the first is paid for by the fix for the third.

**The choice, stated.** The alternative was to let private stock rot all the way
down as it did before and simply refuse to sell a repair. That leaves the player
holding a building they cannot repair, cannot upgrade (`min_condition_to_upgrade`
0.55) and cannot demolish profitably — a dead asset with no verb, which is worse
than the tap it removes.

### Y3a. A refusal the player never reads is not a refusal

**Question.** `cmd_repair_building` now refuses private stock with
`E_OWNER_MAINTAINED`. `ui/build_controller.gd.repair_view` draws the REPAIR row
for every refusal except `E_NOT_DAMAGED`, so the new code would put a *disabled*
button and an explanation on two hundred houses — more interruption than before,
not less.

**Ruled: `E_OWNER_MAINTAINED` folds into "there is nothing to buy", beside
`E_NOT_DAMAGED`.** The row is not drawn at all, at any condition, on any private
building. A refusal code exists so that the command layer, the playtest agents
and the tests can all name the reason precisely; it is not a thing to show a
player who never asked a question.

### Y4. The taper is correct; its silence was the defect

**Question.** Doc 03 §2.5a's founding assistance retires
`FOUNDING_ASSISTANCE_PER_HOUR / FOUNDING_ASSISTANCE_DAYS` every game-day, and
PA-32 measured it as the largest single mover of the net chip in the opening
fortnight with no toast, no log row and no end date anywhere. Flatten it, or
show it?

**Ruled: show it. No dollar moves for this.** The taper is doc 03 §2.5a's whole
design — the state covers the founding city's `departments` and `fleet` lines
and hands them back over the first game-week — and flattening it would pay the
player for the seven days they are least short of money (measured: a do-nothing
starter city banks $89,798 by game-day 7). What was wrong is that a line falling
$589.71 a game-day was invisible. `CostCurves.founding_assistance_days_left()`
publishes the window and the hourly snapshot carries `assistance_days_left`, so
doc 12's budget row can spend it on its own label.

### Y5. A worn station pays its own bill

**Question.** `ASSET_CONDITION_PENALTY_COEFF` is applied to a worn grid node and
a worn water main. It was never applied to a station's `station_upkeep`, so a
police station at condition 0.20 was billed the same staffing as one at 1.00.

**Ruled: it applies.** This is an inconsistency inside doc 03's own model rather
than a new charge, and after §Y1 the city's stations are among the only
buildings left that can rot on the city's books at all — so the coefficient
finally has the asset class it was written for. A row that carries no
`condition` reads 1.00 and bills exactly what it billed before, so every fixture
is unmoved. The same reading closes the one flat row left in `e_grid`: a plant
carries the condition penalty its own nodes and lines already carry.

### Y6. Income rises because the city stops buying repairs it never owed

**Question.** Note (b) asks for more money. Which lever?

**Ruled: the two rulings already made are the lever, and no third one is pulled.**
Street rewards are deferred and untouched; no tax constant, no `base_tax` row, no
yield multiplier, no grant *rate* and **no expense line** moves. What moves is
what the city *spends*:

* §Y1 stops it buying repairs on buildings it does not own — measured at
  **−66 % of repair spend and −81 % of repair taps** across a 45-game-day arc
  (245/211/231 taps → 44/43/44; $620,212/$567,679/$595,385 → $207,135/$204,359/$207,741);
* §Y7 cuts every upgrade price by **20.7 %**.

The founding ledger is therefore **unmoved** (doc 92 §43.6: gross bit-identical,
net 514.888371 → 513.971917, a −0.18 % that is entirely §Y5's condition
coefficient reaching a worn station). *The opening was never short of money* — a
`do_nothing` starter city banks $89,798 by game-day 7 — and the pass says so
rather than inventing an opening subsidy to answer a complaint the measurement
does not support.

**The pacing rule the result is tested against** is doc 03 §2.12's own beat
table, whose shortest opening play session is **10 real minutes** (rows S2 and
S4) and which places at least one player purchase in every session: *the player
may never be left unable to afford what the curriculum asks for, for longer than
one short session.* **N = 10 real minutes.** One real minute is one game-hour at
1× (`data/time.json.clock.real_seconds_per_game_minute` = 1.0), so the rule is
measurable in game-hours and doc 92 §43.7 tests it against doc 03 §2.5a's own
"half of what the next chapter asks you to buy" basis table.

### Y6a. The Wave-17 rulings, and the one that was withdrawn

For the record, because a ruling reversed by its own measurement is worth more
than one that was right the first time:

| ruling | shipped? |
|---|---|
| §Y1(b) `E_OWNER_MAINTAINED` — the city buys no repair for private stock | **yes** |
| §Y1 the ownership floor at `band_worn`, service-gated | **yes** |
| §Y1(a) retiring `E_building_maint` | **WITHDRAWN** — gate 29, measured (§Y8) |
| §Y2 PA-13's condition readers | **yes** |
| §Y2a PA-82's decay cap | **DECLINED** — gate 29, measured |
| §Y3a `E_OWNER_MAINTAINED` folds into "nothing to buy" | **yes** |
| §Y4 the assistance window, no dollars moved | **yes** |
| §Y5 a worn station and a worn plant pay their own bill | **yes** |
| §Y7 `UPG_COEFF = TAX_LEVEL_GROWTH − 1` | **yes** |
| §Y7a water/power component ladders follow | **yes** |

### Y7. An upgrade costs what the revenue it adds is worth

**Question.** `UPG_COEFF` is 1.45 and note (c) says upgrades are too expensive.
What is the right value, and how would anyone know?

**Ruled: `UPG_COEFF = TAX_LEVEL_GROWTH − 1 = 1.15`, which is an identity rather
than a fit.** Doc 03 §2.3's ladders make every payback period a ratio of two
constants and nothing else:

```
payback(new build, L1)  = build_cost_l1 / base_tax_l1                    = 100 gh
payback(upgrade L->L+1) = build_cost_l1 x UPG_COEFF x UPG_GROWTH^(L-1)
                          / (base_tax_l1 x TAX_LEVEL_GROWTH^(L-1) x (TAX_LEVEL_GROWTH - 1))
                        = 100 x [UPG_COEFF / (TAX_LEVEL_GROWTH - 1)]
                              x (UPG_GROWTH / TAX_LEVEL_GROWTH)^(L-1)
```

`build_cost_l1 / base_tax_l1` is **exactly 100 gh for every one of doc 02's
revenue archetypes** (house 1,200/12, apartment 7,000/70, and the four above
them alike), so the bracket is the whole of the ruling: at
`UPG_COEFF = TAX_LEVEL_GROWTH − 1` the first rung pays back in exactly the time
a fresh building does, and every rung above it is spaced by the ratio
`UPG_GROWTH / TAX_LEVEL_GROWTH = 2.55/2.15 = 1.18605` — which is doc 02 §8's
own rule that every upgrade must be *less* utility-efficient than the last, so
it must stay above 1.

**The ruled window is `[100, 200] gh` — one new-build payback to two** — and
`UPG_COEFF = 1.15` is the largest value for which the whole six-rung ladder fits
inside it. Measured on the shipped, rounded house table
(`upgrade_cost / Δbase_tax`): **98.6 / 121.3 / 140.2 / 167.0 / 197.8**, and the
same five figures to within a game-hour on `apartment`, `store` and `office`.
At 1.45 the same table gave
**124.3 / 153.0 / 176.8 / 210.6 / 249.4**, so **the first rung was already 24 %
worse than simply building another house** and the top two were outside the
window entirely — which is what PA-46 found and what level 2's "upgrade instead
of building more" card was teaching against. *(The closed form gives 126.1 /
149.5 / 177.4 / 210.4 / 249.5 for the same coefficient; the shipped table differs
by up to two game-hours because `base_tax` is published rounded. The window is
ruled against the SHIPPED table, because that is the one the player pays.)*

*PA-46's own constant is 15 % loose and is superseded.* It proposes
`UPG_COEFF ≤ 1.15 × (TAX_LEVEL_GROWTH − 1) = 1.32` "so L1→L2 payback ≤
new-build"; substituting into the identity above gives a ratio of
`1.3225/1.15 = 1.15`, i.e. a first rung 15 % *worse* than a new build, which is
the opposite of the stated target. The exclusive condition is
`UPG_COEFF ≤ TAX_LEVEL_GROWTH − 1`, and this ruling takes the equality.

### Y7a. The water and power component ladders FOLLOW, and may not be pinned

**Question.** `economy.json._component_derivation` prices a water component's
upgrade as `upgrade_cost(WATER_ANCHOR_TYPE, L) × variant_ratio`. §Y7 is a
*tax-payback* identity and a pump pays no tax. Should the component ladder pin
at the old prices instead of following?

**Ruled: it follows, and pinning is forbidden.** `water_component_upgrade_cost`
is defined as a *ratio of doc 03's anchor step*, not as a price — doc 05 owns
the ratio and doc 03 owns the dollar (C-07, "ALL tunable numbers live here").
Pinning would mean authoring a second upgrade curve, which is a second currency
authority in the one place the constitution names by hand.

**Measured, and asserted as a follow rather than as a number**
(`tests/test_infra_verbs.gd::test_upgrade_water_component`): the `water_plant`
anchor step goes `65,250 → 51,750` and the authored tank's own step, at doc 05's
ratio 1.33, goes **`86,783 → 68,828`** — exactly `1.15/1.45 = 79.31 %`, the same
factor every other upgrade in the game took. The ladder still rises
(`51,750 / 131,963 / 336,504 / 858,086`), which is the property that mattered.

### Y7b. The construction-rush verb reads the same curves — a merge check, not a change

The construction-rush verb is not in this lane's fork — `grep -rn "cmd_rush"
sim/` is empty here — and this lane changes no line of it. It prices a rush off
`CostCurves`, so §Y7's move carries into it automatically: a rush of an upgrade
gets **20.7 % cheaper** in step with the upgrade itself, and its *derived
per-crew-hour rate* is unchanged, because that rate is a fraction of a price and
both the numerator and the denominator move together. Recorded here so the merge
checks it rather than discovers it.

### Y8. The autopsy: destroying the power plant darkens nothing

**This is the finding that shaped every ruling above, and it is not this lane's
to fix.** §Y1a's service clause — an owner cannot hold up a building the city has
stopped serving — is the mechanism that was supposed to keep neglect fatal after
private stock stopped rotting to death. It cannot fire on this fork.

Measured on an untouched `do_nothing` starter city, `standard`, seed 1337, one
row per five game-days:

```
day | treasury | net/gh | tax/gh | PLANT-1          | SUB-A            | destroyed
 30 |   201202 |   76.7 |  577.6 | 0.273 damaged    | 0.376 active     | 0
 35 |   213004 |   61.2 |  571.5 | 0.099 damaged    | 0.236 damaged    | 0
 40 |   221008 |   43.8 |  569.7 | 0.000 destroyed  | 0.067 damaged    | 1
 45 |   229619 |    5.4 |  569.3 | 0.000 destroyed  | 0.000 destroyed  | 3
 60 |   246117 |    8.1 |  580.1 | 0.000 destroyed  | 0.000 destroyed  | 4
```

**The city's power plant and its substation are destroyed on game-days 40 and 45,
and the tax line does not move** — 569.7 before, 580.1 twenty game-days after,
and the treasury keeps climbing. Nothing goes dark, no `f_power` term bites, and
the private stock is served exactly as it was the day before the plant died.

Two consequences, both recorded rather than fixed here:

1. **What actually killed a neglected city was private structural failure.** Not
   the blackout — buildings rotting past 0.35, going `damaged`, and being
   destroyed one at a time until there was no tax base left. Doc 02 §2.6a stops
   exactly that, on purpose, because it is also what the 2026-09-01 playtest
   called "way too aggressive". So the engine had to be re-fitted, not restored:
   doc 92 §43.8 and gate 29.
2. **It is the same defect the production audit filed twice** — PA-02/PA-08 on
   the power side and PA-09 on the water side, both "a computed value with no
   consequence". This row is the third instance and the most expensive, because a
   whole difficulty table was fitted on a mechanism the docs believed in and the
   sim never had. It belongs to the power lane, and until it lands, §Y1a is a
   correct clause with nothing to bite on.

---

## AM. Wave-18 rulings — the tilt looks up: what the aim is allowed to move, and what it may never move (2026-09-02)

**The directive (2026-09-02), verbatim:** *"The screen tilt does work, but we need
more vertical. We need to be able to look UP towards the sky, towards the top of
the buildings as well."*

**What the frame did before this wave, and why the floor was not the problem.**
In doc 12 §2.16's rig the camera looks AT THE FOCUS and the focus is on the
ground, so the horizon is always `pitch` ABOVE the view axis and lands at
`(1 − tan p / tan(fov/2))/2` of the way down the frame. At Wave 17's floor —
`p = 12°`, `fov = 40°` — that is **20.8 % down, leaving the ground the other
79 %**. Measured, not asserted: `--tilt=12 --poses=z0` frames the intersection
across the bottom two thirds, the mid-rise facades cut off at mid-height, the
tower tops off the TOP edge and the sky only in the gaps between roofs. **Lowering
`pitch_manual_min_deg` cannot fix it, and cannot move:** the ground fills whatever
the axis points at, so every angle in the band composes the same way, and 12° is
already the last angle that clears a ground floor (`18·sin 12° = 3.74 m` against
doc 11 §2.6's 3.5 m). The axis that was missing is the AIM.

### AM1. A camera recomposition moves the AIM, not the ARM

The ramp lifts the **look-at point** — `look_at = focus + (0, aim, 0)` — and
leaves `camera_position()` untouched at every zoom and every bias. Three options
were on the table and this is why the other two lost:

* **A lower pitch floor** is the null option and is ruled out above: it cannot
  change the horizon's share of the frame at all, and it has nowhere left to go.
* **A camera-height lift** (raise the camera, keep aiming at the focus) changes
  what is OCCLUDED and nothing else. The horizon's screen position is a function
  of the view axis ANGLE alone — the camera's height does not appear in it — so a
  rig lifted 100 m still frames 79 % ground. It also moves the one thing every
  existing guarantee in this project is written against.
* **A pure aim lift** changes the composition and nothing else, and that is the
  ruling. Because the arm does not move: Wave 17's ground-floor clearance holds
  verbatim (`tests/test_camera_aim.gd::test_the_camera_is_never_inside_a_ground_floor_at_any_lean`
  sweeps 41 zooms × 21 biases and the lowest camera in the whole product is still
  the Z0 floor's 3.742 m); doc 11 §2.5's LOD tiering is byte-identical, because
  chunks tier off the camera POSITION; and doc 92 §47.2's bought number — the
  150 m NEAR boundary `pitch_reach_up_far = 0.76` was fitted to — is still a
  measurement of the same rig rather than of a new one.

**A NEGATIVE view pitch is allowed and is the point.** `view_pitch_deg()` reaches
**−6.92°** at the Z0 floor — the axis is above horizontal and the camera is
looking at sky — while `pitch_deg()` remains the ORBIT angle that positions it.
Two angles with two jobs, named apart (`orbit_basis()` places, `camera_basis()`
points), so no caller can take one for the other.

### AM2. The lean interpolates the ANGLE; the height is derived out of it

The first cut scaled the full-lean look-at height by the lean, and it was **not
monotone**: the orbit pitch is itself falling as the lean rises and takes `R` with
it, so the Z0 aim peaked at 5.896 m around bias 0.95 and came back to 5.879 m at
bias 1 — which the slider would have shown as the horizon nodding at the end of
its own travel. The shipped composition interpolates the VIEW ANGLE instead:

    v_target = −atan((1 − 2·aim_up_ground_frac)·tan(fov/2))     = −6.92°
    view     = lerp(pitch, v_target, |bias| · reach(t))         , capped (AM3)
    aim      = D·(sin p − cos p·tan view)

`v_target` is a constant of the projection and one authored fraction, so a full
lean composes the SAME frame at every zoom — which is what the slider's ends
promise. The invariant that is tested is on the view angle and deliberately NOT
on the derived height: at Z2 a full lean aims 144.0 m up where a half lean aims
149.5 m, while looking 20° further up, because the camera itself has dropped from
286.5 m to 170.8 m on the way. **A derived quantity is not a proxy for the thing
it was derived from**, and a test that asserted it was would have been asserting
the wrong axis.

**The scale is derived, not chosen.** `aim_up_ground_frac = 1/3` is "pavement in
the bottom third". At the far pose it solves to
`420·(sin 24° + cos 24°·tan 20°/3) = 217.4 m`, and doc 02 §2.3's five-rung roster
maximum is `high_rise` L5 at `62 × 3.5 = 217.0 m` — the same 217 m tower doc 11
§2.5 works its LOD example against. **That is what the ground-share rule ASKS for at the far pose — and it is not
what ships there.** §AM3's anchor cap binds first at Z2 and takes 3.5° off the
lean, so the shipped far-zoom aim is **144.0 m**, not 217.4 m: the roofline
figure is the rule's own solution before the cap, quoted here because it is what
makes 0.3333 the right ground share, and the two numbers appear two paragraphs
apart in this document. A verifier caught the bolded sentence claiming the capped
behaviour was the uncapped one (report 98 §54's verify pass, 2026-09-02); the
arithmetic was never wrong, the sentence was. §2.14's
sixth rung (78 floors, 273 m) is deliberately not the scale: it is city-level
gated growth stock, not the pose the far zoom is composed against. Both figures
are asserted in `test_the_far_lean_aims_at_the_tall_archetype_roofline`, read out
of `data/building_shapes.json` rather than restated, so a roster change fails the
test instead of quietly staling the number.

### AM3. The anchor may not leave the frame, and the guard is the frame itself

`focus` is the pan anchor, the pinch anchor, the twist pivot and `focus_on()`'s
landing spot. A recomposition that pushes it off the bottom edge makes all four of
those act on a point nobody can see. The guard is therefore geometric rather than
a taste number: the anchor sits `pitch − view` below the axis, so
`view ≥ pitch − atan(aim_up_anchor_ndc·tan(fov/2))`, and at the authored
`aim_up_anchor_ndc = 1.0` it may ride the bottom edge and no further. **It does
not bind where the composition lives** — Z0's full lean needs `12 + 6.92 = 18.92°`
of drop against the frame's 20° — and binds by 0.45° at Z1 and 3.5° at Z2, where
`reach()` has already shortened the lean for the budget's sake.

That the near end clears the guard by 1.08° is a coincidence of three authored
numbers (`12°`, `1/3`, `40°`) and is therefore TESTED rather than trusted:
`test_the_full_lean_leaves_the_ground_in_the_authored_bottom_share` asserts the
horizon is DRAWN at exactly `1 − frac` down the frame at Z0, so retuning any of
the three into a zoom where the cap binds fails loudly instead of quietly
composing something else.

### AM4. The ray math did not move, so the picks did not move

The ramp changes where the frustum POINTS. `screen_ray()`, `ground_hit()`,
`screen_to_ground()` and `project_to_screen()` all read `camera_position()` and
`camera_basis()`, and `camera_basis()` is the basis the `Camera3D` wears, so they
follow the aim for free and cannot disagree with what is drawn. Proved rather
than argued: `test_a_tap_resolves_to_the_tile_it_visually_covers` projects a tile
centre to the screen and casts that pixel back, at three zooms × {AUTO, floor},
and asserts the same 8 m tile; `test_a_screen_point_round_trips_through_the_ground_and_back`
does the inverse at the floor.

Three consequences are recorded because they are real:

1. **`m_per_dp` MOVES under the ramp, and had to.** It claims to be metres of
   ground per dp *at the focus*, and the focus's depth along the view axis is now
   `D·cos(pitch − view)`, not `D`. Leaving it at `D` would have made the one
   number §2.21's tap radius and §2.7's drag ghost are sized from disagree with
   the frame by 5.4 % at the Z0 floor and 6.0 % at Z2. It is corrected, it is
   exact — `test_m_per_dp_is_the_scale_the_projection_actually_draws` proves it
   against `project_to_screen` itself rather than against its own formula — and it
   moves in the conservative direction, fewer metres per dp, so a lifted aim can
   only make a radius pick tighter. Doc 12 §2.23.4's "unaffected by tilt" is
   narrowed to the PITCH BAND in delta D-85; the aim ramp is the part that moves
   it.
2. **The typed miss is now most of the frame, not a corner of it.** At the floor
   the horizon is two thirds of the way down, so every screen point above it
   answers `MISS_ABOVE_HORIZON`. §AC3's rule is unchanged and is load-bearing
   rather than defensive now: the caller that ACTS on the world branches on
   `hit`, the caller that TRACKS the finger does not. Which ground is *pickable*
   did not change — the `ray_parallel_eps` and `dist·4` limits are properties of
   the camera position, not of the aim — only where that ground is DRAWN.
3. **Doc 11 §2.5b's cull reads the frustum off the basis, so it follows the aim
   with no call at all.** Below the half-FOV the top ray clears the horizon and
   `pitch_cull_reach_m` returns INF, which is the same answer `set_camera_pose`'s
   `pitch_deg < 0` "no pitch supplied" sentinel gives — so a negative view pitch
   cannot accidentally shorten the draw distance through the sentinel it now
   collides with. Asserted rather than assumed
   (`test_the_pitch_cull_reads_the_frustum_and_a_lifted_aim_leaves_it_standing`,
   five angles from −6.92° to 19.9°). **Re-open** if anyone ever authors a `slack`
   curve that makes the reach finite below the half-FOV: the sentinel must then be
   split from the value.

### AM5. The cull cannot pay for this, and the geometry says which way it fails

The brief's hypothesis was that "a camera aimed up needs LESS distance behind the
focus". The geometry says the opposite, and it is worth writing down because it is
the same mistake in the other direction. Aiming up moves the frame's **near** edge
OUT — the bottom ray at the Z0 floor is 13.08° below horizontal, so the nearest
visible ground is `3.742/tan 13.08° = 16.1 m` from the camera's ground point where
before it was `3.742/tan 32° = 6.0 m` — and leaves the **far** edge exactly where
it was, at infinity, because the top ray still clears the horizon. What the ramp
removes is 10 m of near ground, a fourteenth of one 128 m chunk; what it adds is
the airspace the towers stand in, and that is where the draw calls are. §2.5b's
cull is exact and is honest to return INF there, and a cull tightened past it
would delete the skyline this wave exists to show. The excess is therefore
published (doc 92 §53) under §AC2's standing ruling, not tuned away.

## AH. Wave-18 rulings — an event that cannot end, a window that cannot open, and what a reward is allowed to measure (2026-09-02)

*Four mechanics questions came out of lane B (`99-production-audit.md` PA-04,
PA-25, PA-26, PA-89). Three of them are fairness questions and therefore this
document's; the fourth is about what a design number is allowed to say when the
thing it describes was never built.*

### AH1. An event ENDS when the thing it caused is over — and there is always a wall behind that

**Question.** Doc 07 F2 measures its class cooldowns "from resolution". What
resolves an event, and what happens when the answer never arrives?

**Ruled: an event resolves when its consequence is over, and a consequence that
cannot be found is over.** Three shapes, one rule:

* an event that INJECTED WEATHER is not over while the segment runs — the player
  is still in it — so it resolves no earlier than `impact + duration`;
* an event that REQUESTED INCIDENTS is over when the last of them closes, which
  is `CitySim`'s `_director_links` book and nobody else's;
* an event that requested an incident and was REFUSED is over immediately,
  because it produced nothing. This is the case the fork could not express at
  all, and it is the honest one: a pick that did nothing should cost a cooldown,
  not a permanent slot.

**And behind all three, a wall.** `fairness.max_active_min` (2880 game-minutes =
48 game-hours) ends anything still held. The wall is not a fallback for a bug we
expect; it is the statement that **the Director's pacing gate is a promise to the
player** — "you will not be left alone for the rest of this city's life" — and a
promise that depends on a book staying in sync with a roster is not a promise.
Doc 06 §2.10 already ends an incident after one game-day with nothing committed,
so 48 game-hours is past every legitimate hold by a factor of two.

**Rejected: resolving on the FIRST incident.** `on_incident_resolved` already
existed and already fired, and using it would have been one line. It is the wrong
line: F2's cooldown is measured from the end of the CRISIS, and a storm whose
first downed line is repaired in twenty minutes has not ended.

**Rejected: dropping stale rows on load.** See RR-136. A row that is genuinely in
flight has incidents on the map pointing at it, and deleting it would leave
`last_major_end_min` unset — the gate would then be lying in the other direction,
which is worse than the stall because it is invisible.

### AH2. A preparation window belongs to the WARNING, not to the storm

**Question.** §2.7.7 opens the prep window at T−90 and shuts it at T−20. Which
object owns those two minutes?

**Ruled: the scheduled row — the one F7's warning went out for.** The fork asked
the ACTIVE storm, and the active storm's `t0` is the minute it began, so the
window's own arithmetic (`now − t0 ≤ −20`) could not be true while the object it
was asked of existed (A91-D-87).

The deeper point, and the reason this is a ruling and not a bug report: **the
warning and the window are the same promise.** F7 exists so that a forecastable
event is never new information; §2.7.7 exists so that the information is
ACTIONABLE. A window measured against the storm rather than against the warning
would be a window that opens after the thing it prepares for. So the lead scales
with `warning_lead_mult` exactly as the warning does — a casual player is given a
longer warning **and** a longer window, one knob, one meaning.

**Corollary: the ledger of what was taken belongs to the Director, not to the
storm.** Every prep action is taken before `SevereThunderstorm.begin()` runs, so
a ledger on the storm object is a ledger that does not exist when it is written
to. It moves up one level, and `on_event_resolved` clears it — so one storm's
preparation can never be counted toward the next one's reward, which is the
fairness half of the same decision.

### AH3. A reward may only measure what the game actually computes

**Question.** §2.7.6's Storm Ready has two conditions: three prep actions AND an
outage under budget. Nothing computed the second. Ship the reward on the half
that works, or count the other half?

**Ruled: count it, or the reward is teaching the wrong lesson.** Doc 07's own
sentence is *"this makes preparation profitable, not merely less painful."* With
`outage_customer_minutes` unwritten (A91-D-88) the payout was earned by pressing
three buttons, which makes ATTENDANCE profitable — the exact inversion of Core
Rule 12, which says the storm report is a teaching moment. A reward whose
condition is not computed is not a lenient reward; it is a different reward,
wearing the label of the one that was designed.

**The unit is a resident in a dark building**, because that is the unit §2.7.6's
own budget is stated in: its worked example puts "400 customers out" against a
city of 45,000 at 0.9 %. Accrued at REPORT on the same tick and the same `dt` as
the Director's resolution sweep, so the fine and the coarse path integrate the
same quantity at their own step sizes rather than two quantities that happen to
agree at 21 game-days.

**A related ruling, applied and worth writing down: two of §2.7.7's six actions
ship UNIMPLEMENTED and SAY SO.** `pre_stage_crews`' −35 % travel time needs a
knob on a file this lane may not edit, and `load_shed`'s −5 % commercial tax
needs doc 03's revenue half. Both are still priced, recorded and counted toward
Storm Ready, and both carry a row in doc 12 D-78's deferral table. The
alternative — quietly accepting the action and doing nothing — is the defect this
whole lane exists to close, one level down: a verb that reports success and
changes nothing is worse than no verb, because the player learns a false lesson
about what preparation buys.

### AH4. When a design sentence contradicts itself, implement the ENDPOINTS and record the slip

**Question.** §2.6.2 says the Director may "spend up to `1.60 × tp_cost` to add
up to `+0.30` to `severity_mult`, linearly", and then parenthesises
"(`+0.50×tp_cost` buys `+0.125`)". Those two cannot both be true: the first fixes
the rate at `+0.50` of severity per unit of cost overspent, which puts
`+0.50×tp_cost` at `+0.25`.

**Ruled: implement the endpoints, flag the parenthetical.** The endpoints are the
load-bearing half — they are what the `buy_max_cost_mult` and `buy_max_severity`
columns in `data/director.json` say, and a data file is a stronger statement of
intent than a worked example in prose. The parenthetical is recorded as an open
question against doc 07 rather than silently patched, because this lane does not
own that document's text and a silent patch would erase the evidence that the two
disagreed.

**And the second clause of the same sentence is a mechanics ruling in its own
right.** "Only when `tp_pool > 1.6 × tp_cost` **and no other candidate is
affordable**" was implementable two ways, and the looser one — "nothing DEARER is
affordable" — was built first, measured, and rejected: over doc 07 §7 test 26's
own rig it took the Standard cadence from one major per 2.64 game-days to one per
**3.23**, outside §2.6.3's own published claim, and bought only +2.5 % mean
severity for an 18 % cut in majors. The literal reading (`pool.size() == 1`)
lands at 2.86 game-days for +6.2 % severity. The measurement is doc 92 §49's; the
ruling is that **a lever whose whole purpose is to convert an idle budget into
tension may not be allowed to convert a working budget into silence.**


---

## AI. Wave-18 rulings — the shell's ten extractions, ranked by what happens when one is wrong (2026-09-02)

*PA-38 asks for a ranked extraction plan for `game/main.gd`. Two of the ten are
shipped in this wave (they are what PA-05's router needed); the other eight are
filed here with a named consumer each, so the next lane to touch one has the
argument already made. The ranking is by RISK, not by size — how bad the
failure is when the extracted logic is wrong, times how invisible the wrongness
is inside a file the suite cannot load.*

### AI1. Why a line count is the wrong metric, and what the right one is

PA-38's headline number — 2,034 lines at the audit's own fork, 2,257 at this
lane's, zero test references either way — is the symptom.
The disease is narrower and it has a name: **`main.gd` does sim reasoning**.
`grep -c "sim_host\.sim\." game/main.gd` counted **72** reads at the Wave-17
fork (67 after this wave),
and every one of them is a place where a fact about the city is derived outside
anything that can assert it. The three defects PA-05 and PA-76 found were all in
that set, and none of them was in a long function: `_on_fix_requested` was
twenty lines.

So the target is not "get under 1,200 lines". It is **every derivation out; every
wiring, node and lifecycle line stays**. A shell that is 2,000 lines of
`add_child`, `connect` and `if node == null` is a shell doing its job; a shell
that is 300 lines of `sim.buildings.get(id)` is a bug farm whatever its total.
The two functions extracted this wave came to 45 lines and carried three
independent defects between them.

### AI2. The ten, ranked

Risk is stated as **what a player sees when it is wrong**, because that is the
only ranking that survives contact with a lane budget.

| # | Extraction | Reads it does | Risk when wrong | Consumer |
|---|---|---|---|---|
| 1 | **`_on_fix_requested` → `FixRouter`** | `buildings`, `world.block`, `grid` | A button that depresses and does nothing, on the game's most-seen teaching row. Two of seven rows were dead. | **SHIPPED** (this wave, `ui/fix_router.gd`) |
| 2 | **`_alert_world_pos` → `WorldLocator`** | `buildings` (linear scan), `world.block` | The camera jumps to the wrong place, or refuses to jump; silent either way. Anchored every building on its NW corner tile. | **SHIPPED** (this wave, `ui/world_locator.gd`) |
| 3 | `_on_sim_batch` → `RenderEventRouter` | the whole event vocabulary | **The highest-consequence one left.** It is the ONLY door from a sim event to a mesh: a `building_*` event the table does not name is a building that exists in the sim and not on screen, forever, with no error. 109 lines, one `match`, and the constitution's own rule ("every event that creates, completes or destroys a `Building` must reach the translator") is enforced by review alone. Wants a table-driven form plus a gate that every `Building`-lifecycle event in `data/` has an arm. | lane K (the payload-SHAPE gate beside `test_event_matrix.gd`) |
| 4 | `_dispatchable_units` → `DispatchPickerFeed` | `incidents.fleet`, `incidents.catalog`, ETA | The unit picker offers a unit that cannot go, or hides one that can, during an incident. Pure arithmetic over doc 06 reads; 24 lines; trivially testable. | lane H or the next incidents lane |
| 5 | `_feed_dashboard_tabs` → `DashboardFeed` | `grid` ×3, `water`, `incidents.fleet` | Two numbers for one fact. It re-derived the ambient the power layer owns; **fixed this wave** by calling `PowerInfraFeed.ambient_c`, but the roster loop and the water snapshot are still assembled in the shell. | lane S (Economy tab) / whoever owns the Infrastructure tab next |
| 6 | `_refresh_hud` → `HudFeed` | treasury, clock, population, alerts | Wrong money or wrong time in the top bar — highly visible, and 68 lines of it are in the shell. | lane K (owns `hud_model.gd`'s top-bar solver) |
| 7 | `_feed_coverage_overlay` → `OverlayFeed` | `buildings`, `catalog.stats`, `world.coverage` | A coverage overlay that disagrees with the panel that quotes the same requirement. 45 lines, one loop over the roster per repaint. | lane J (owns the curriculum that teaches coverage) |
| 8 | `_handle_tap` / `_route_world_drag` → `TapResolver` | `world.grid`, `buildings` via the render model | A tap that selects the wrong building, or nothing. Doc 12 §2.16's thresholds live here as literals. PA-73's `drag_routed` seam is the same code. | lane Q (owns `test_touch_input.gd`) |
| 9 | `_resync_world_views` → `WorldResync` | roads, water, power, flood | After a RESTORE the world is drawn from the save; a missed layer is a city that looks like the one before the load. 63 lines, and it runs exactly once per load, which is why nothing has caught it. | lane F (save integrity) |
| 10 | `_on_hour_settled` → `SettleFeed` | the hour digest | A wrong hourly delta in the log and the toast; 37 lines. Lowest risk of the ten: it is a display of a number the sim already published and a wrong one is visibly wrong. | lane K (event log) |

### AI3. What stays in the shell, and why that is not a compromise

`_ready`, `_build_*`, `_wire_*`, `_process`, `_notification` and the catch-up
driver stay. Every one of them is *node construction, signal wiring or a
per-frame budget*, and all three are things a headless model must not do
(constitution §3). Extracting them would buy a smaller file and a worse one: the
test would have to stand up a scene tree, and a test that stands up a scene tree
is testing Godot.

The honest consequence is that `main.gd` does not get under 1,200 lines by
extraction alone, and PA-38's line target should be read as its assert target
instead. This wave moved 45 lines out (`_on_fix_requested` 18,
`_alert_world_pos` 27, measured at `4503d35`) and put **468 assertions** behind
what those two did — `--file=test_fix_router` 347, `--file=test_world_locator`
121 — inside a lane total of **643** across its five new test files.

And the count went the other way, which is the part worth writing down:
`wc -l game/main.gd` reads **2,264 against the fork's 2,257**. The lane removed
52 lines of executable shell and added 21 (net −31); the file is longer because
46 of its 67 added lines are the `##` rulings above, and because PA-20's
`_on_memory_warning` is a handler the shell never had — new behaviour cannot
shrink a file. Report 98 §50.3 states the same thing with the commands. The
assert target is met; the line target is not, and §AI1 is the argument for why
that is the correct trade rather than an excuse for it.


## AJ. Wave-18 rulings — the requirement contract: what a `Fix this →` is, what a tooltip may carry, and how a checklist stays honest (2026-09-02)

Three findings from the production audit's UI lane sit on one mechanism. Doc 12
§2.7 calls `Fix this →` the game's most important teaching device; this section
records what it was actually doing, and the three rulings that make the claim
true. Report 98 §51 carries the binding text (RR-142, RR-143, RR-144).

### AJ1. `{kind, id}` is not a target (99-PA PA-05, RR-142)

The formatter has always emitted a kind and an id, and the shell has always
resolved the id **per kind**. That works exactly as long as every producer knows
which namespace the consumer will look the id up in, and two producers did not:

| Row | `id` it supplied | Kind it routed | What the shell did |
|---|---|---|---|
| `POWER_CAPACITY` (pre-Wave-17) | `grid.attachment_of()` → `T-06` | `FIX_BUILDING` | `sim.buildings.get("T-06")` → `null` → `return` |
| `E_TRANSFORMER_FULL` / `E_NEEDS_TRANSFORMER` | *(none)* | `FIX_TILE` | flew the camera to the **ghost's** tile — the one under the player's finger |
| `E_AVENUE` | *(none supplied)* → `""` | `FIX_ROAD_SEGMENT` | `if id == "": return` |

None of them logged anything. The building panel drew the button on `kind !=
FIX_NONE` alone; the land panel escaped only because `land_panel.gd:392` also
requires a non-empty id — a second check nobody wrote down as a rule.

**`E_NO_SLOT` is the row that is NOT on that list, and it is worth its own
line**, because this lane put it there first and the suite took it back off. Its
target is a doc 04 **substation**, and a substation is also a doc 02 shell:
`sim.buildings.has("SUB-A")` is `true` on the founding city and `substation` is
an archetype the build sheet sells. `FIX_BUILDING` resolves, the camera move is
the whole useful answer, and doc 12 D-71 had already ruled it deliberate. The
general point is the one that survives the wave: *"the id looks like a
component"* is not evidence, and `has()` is — which is why the corrected routing
of `E_TRANSFORMER_FULL` and `E_NEEDS_TRANSFORMER` above rests on
`attachment_of("H-001")` = `T-06`, `buildings.has("T-06")` = `false`,
`component_tile("T-06")` = `(39, 34)`, measured rather than reasoned.

**The ruling** (RR-142): the row carries `params`, and `params` is what the
router **acts on**. A tile for `FIX_TILE`, a district key for `FIX_DISTRICT`, a
component id for the new `FIX_COMPONENT`, the `CitySim` verb for the two purchase
kinds. A producer that cannot fill them routes `FIX_NONE`.

**Why a tile is the currency.** Because the producer already has one. Every one
of these rows walked the map to write its sentence — `E_AVENUE` searched outward
to the nearest avenue precisely so it could print *"no avenue within 4 tiles"* —
and then discarded the coordinate and passed a name. The fix is not a better
lookup on the consumer's side; it is to stop throwing away the answer.

### AJ2. A tooltip is an accelerator, never a carrier (99-PA PA-23, RR-143)

The placement bar put the requirement's title on screen and its remedy in
`tooltip_text`. On a phone that is not a shortened message — it is an absent one.
The general rule is in RR-143: any string written to `tooltip_text` is written to
a visible control in the same commit.

The second half of the same row is subtler and worth recording separately. The
bar's commit-refusal fallback wrote into a label that lives **inside the build
sheet**, and the flow closes the sheet before the write can happen. A surface
whose lifetime is shorter than the message it carries is not a surface; the
notice is gone and the bar — which is up for exactly as long as placement is —
carries the sentence instead.

### AJ3. Two hand-maintained lists that must agree are a defect with a date on it (99-PA PA-24, RR-144)

`cmd_upgrade_building` appends seven codes; `UPGRADE_CHECKS` listed six. The
missing one, `E_WATER_HEADROOM`, is a live gate, and the panel's answer to a
building blocked on it was **six green ticks and the sentence "Every requirement
met."** over a dead button. This is worse than an unexplained refusal: it is a
surface actively asserting the opposite of what the gate found.

The ruling (RR-144) is not "add the row" — that is the fix, not the rule. It is
that the checklist is verified against the **command's own source**, so the next
gate doc 02 grows fails the suite in the commit that adds it rather than in the
audit two waves later. The test parses `blockers.append(&"…")` out of
`cmd_upgrade_building`'s body; a source scan is the honest instrument here,
because the alternative — a second list of codes for the test to compare against
— is the same defect with one more copy of it.

### AJ4. What this predicts elsewhere

Three rows, one shape: **a contract whose consumer half was written against
assumptions the producer half never promised to keep.** The audit's own evidence
line for PA-05 records that `grep -rn "main.gd" tests/` finds six prose comments
and no test — the dispatcher had never been exercised at all. Every seam in this
tree where a `Dictionary` crosses from `ui/` to `game/` is worth the same
question: *is there a test that a real producer's output resolves in the real
consumer?* This wave answers it for the requirement rows. It does not answer it
for the event batch, the notification payloads, or the overlay feeds.


---

## AK. Wave-18 rulings — the settings deck: what belongs to the phone, what belongs to the city, and what belongs to Android (2026-09-02)

*Lane G, production audit PA-14 / PA-15 / PA-58 / PA-59 / PA-84. Report 98 §52
carries the rulings as rulings; this section carries the mechanics they turn on.
Every question below is the same question asked five times: **who owns this
value, and what happens when the owner is not the one storing it?***

### AK1. Three custodies, and the row's KIND is how the code says which

A settings screen looks like one list and is really three, and until this wave
the code could not tell them apart:

| custody | example | lives in | survives city deletion? | in a save? |
|---|---|---|---|---|
| **the phone's** | text scale, graphics preset, the notification switches | `user://settings.cfg` (`device_scoped_keys`) | **yes** | mirrored only |
| **the city's** | `replay_tutorial`, the dispatch and road policies | the `ui` save section (and the sim's own sections) | no | **yes** |
| **the platform's** | `notification_permission` | nowhere — it is re-read | n/a | **no** |

The third is the one that had no representation at all, and it is the one that
needs the strongest rule: a value the platform re-answers every time it is
looked at **must not be persisted anywhere**. Persisting it shows the player a
stale token for one frame after every load, and a *wrong* one after they changed
it in system settings while the app was closed. Hence `SettingsModel.KIND_STATE`:
no capture, no device file, no cycling, and a tap that runs the row's `action`.

**The generalisable shape.** When a screen shows values with different owners,
the difference has to be in the *type*, not in a comment or a special case at
the call site — otherwise the next row of the awkward kind is written as the
common kind and the bug is silent.

### AK2. A withdrawn control is not an unknown key

PA-59 removes `auto_spend_contractor` — a `policy: dispatch` toggle whose value
reached `DispatchPolicy` and stopped there, because there is no contractor unit
to hire (doc 06 line 1749).

The tempting move is to delete the row and let doc 12 §3.2's migration policy
handle the leftovers: *"unknown settings keys are dropped"*. **That is wrong, and
the distinction is worth stating.** A save carrying `auto_spend_contractor` was
written *by this game*, at a version where the control existed, and the value in
it is still meaningful to doc 06 — which still carries the default and still
round-trips the key. Reporting it as an unknown key would put a drop in the log
for something nobody did wrong, and would make a real corruption harder to see
in the same log. So `settings.retired_rows` keeps the row object whole (copy keys
included, so the string table does not read them as orphans) and
`SettingsModel.retired_keys()` ignores those keys in silence. **Re-shipping the
control is moving one object back into `rows`** — which is the test that the
withdrawal was reversible rather than destructive.

### AK3. A gesture preference cannot preserve the property the gesture is built on

Doc 12 §2.16's pan is a **1:1 world lock**: the ground point under the finger
stays under the finger, and the lock is not a nicety — it is what makes the pan
exact at any zoom, pitch or yaw, in one step, with no accumulated error.

`invert_pan` asks for the opposite: the city travels *with* the finger. The two
cannot both hold, because the lock is precisely the statement that they cannot.
So the inverted path **keeps the magnitude and gives up the lock**: it applies
the same displacement with the opposite sign and re-anchors every frame, so the
finger still drives the world exactly as far as it moved. Without the re-anchor
the anchor and the touch diverge and the error compounds for the length of the
drag.

Pinned by `test_inverted_pan_moves_the_same_distance_the_other_way`: equal
lengths, negative dot product. **The shape: when a preference inverts an
invariant, name which half of the invariant survives — here, distance survives
and identity does not — or the feature ships as "roughly the other way".**

### AK4. A mode with no face is a bug, and the face has to be measured into place

Follow mode moves the camera on its own. An invisible mode that moves the camera
does not read as a feature; it reads as a broken camera. So doc 12 §2.6 step 6's
chip is not decoration — it is the mode's only *statement that it exists*, and
it doubles as one of the four ways out (the other three: a pan, which
`CameraState.begin_pan` already ends on touch-down because the finger always
wins; the unit going off duty; and a dispatch of a different unit).

**And the face has to be placed against its neighbours rather than by a
constant.** The chip's first draft used a 316 dp bottom offset, chosen by reading
the 360 × 800 layout. At 880 × 400 — the same safe area, 400 dp tall — that
offset lands inside the top bar: six `overlapping_targets` findings against the
stat chips, which are controls the player needs far more than this one. The fix
is the ruling doc 12 §2.23 already made for the right edge, applied to the left:
measure the neighbour (`LeftRail`'s solved `offset_top`), and yield the column
outright while something else is drawn over it.

### AK5. "Critical", "significant", "nearby" — an undefined adjective is an unmade decision

PA-84's row is filed as *"`auto_speed_reset` has no caller"*, and the interesting
part is **why** it had none for seventeen waves. Doc 01 §2.9 said "a P1
notification"; the P1 class on the curriculum path is 138–161 events per 21
game-days, which is 19.2 forced speed resets per real hour on the worst seed. The
literal implementation is a fault, not a feature — so the function was written,
tested, documented, and quietly never called, which is the shape a *deferred
decision* takes when nobody records that a decision is owed.

The close is not "wire it". The close is: **make the decision in data, and put
the measurement that justifies the number next to it.** Three authored triggers
and a 600 s re-arm bring the same streams to 0.714 per real hour, and
`tools/measure_speed_resets.gd` exits non-zero above the bar so the number stays
a claim rather than a memory. Doc 12 §2.11 and doc 01 §2.9 now say which events;
neither says "critical" on its own any more.

## AL. Wave-18 rulings — what the money is allowed to do in silence (2026-09-02)

*Three fairness questions came out of Lane S (99-PA PA-31/PA-32/PA-33). All three
are the same question asked about three different dollars: when is the game
allowed to change what a player earns, or spend what a player has, without
saying so?*

### AL1. A scheduled change must announce its own schedule

**Question.** Doc 03 §2.5a's founding assistance is correct, published and on a
clock the player never agreed to. Is it fair for it to shrink in silence?

**Ruled: no, and the reason is not the size of it.** A number that falls because
the player neglected something is a consequence and the game owes them the
*cause*. A number that falls because the game always intended it to is a
**schedule**, and the game owes them the schedule — the rate today, the day it
ends, the days between. The taper is the clearest case in the project because it
is the only income line whose entire future is already written down: there is
nothing to predict, only something to say.

The corollary is where the fairness actually bites. **Saying it seven times on
the lock screen is not more honest, it is louder.** Doc 08's budget is finite and
every push spends it; a push about a scheduled step the player cannot alter buys
nothing and crowds out a transformer that is about to cook. So the routine steps
are log rows — findable, scroll-backable, free — and exactly one step is a
notification: the last one, because *that* one changes what the city has to do
next. See RR-148.

### AL2. Wear is reported in the unit the player is losing it in

**Question.** A worn building pays less tax. Does the player get told the count
of worn buildings, or the money?

**Ruled: the money, and the price of ending it, in the same band.** "34 buildings
are worn" is a fact. "You are losing $412/gh to condition; repairing it costs
$18,900" is a decision, and a decision is what a management game owes. The count
belongs on the band too, but as the *subject of the sentence*, never as the
sentence.

This ruling has a sharp edge that §Y1 created and did not close. After the
ownership floor, a private building the city keeps **served** cannot reach
`damaged` at 0.35 — its owner holds it at `band_worn` — so the one cue the game
had ever given about condition became, on the path a player actually plays,
structurally unreachable. Measured: **185 private buildings sitting worn** at the
end of a 45-game-day curriculum arc, and on a 60-game-day `do_nothing` starter
run **48 band crossings against zero `building_damaged` events** — forty-eight
moments at which the city got poorer and nothing on any screen moved. §Y1 is
right and it silenced the thing it was right about; RR-149 is the repair.

(§Y1a still bites, and the measurement shows it biting: 4 of those 11 Poor
crossings were private buildings whose owners had been left in the dark. A city
that stops serving its stock gets the old physics back, which is the clause
working.)

### AL3. A policy may spend the player's money; a default may not

**Question.** Roads repair themselves under a policy (§J3). Should buildings?

**Ruled: yes for the buildings the city OWNS, and no by default.** The §J3
argument transfers exactly — a per-building repair tap is not a decision, it is
the same decision restated 51 times over a 45-game-day arc — and it transfers
*only* as far as ownership goes. §Y1 already ruled that the city pays for what it
owns; a policy that repaired private stock would be the retired
`E_building_maint` reading, re-introduced through a settings row.

**The default is the whole of the second half.** An auto-repair default would take
money from a treasury without being asked, on a city founded before the control
existed, and would move every balance gate in the matrix in a wave whose stated
job is to *surface* what the money already does. So the shipped default is
manual: the control exists, the ladder is doc 02's own band table, and a player
who never opens it plays the game they played yesterday, bit for bit. See RR-150
and its §53.5 baselines.

### AL3a. A default of `off` obliges the control to be findable, and to switch ON to something

**Question.** AL3 shipped the policy `off`. A control that ships off is a control
the player has to find and press before the feature exists at all — so where does
it live, and what happens on the first press?

**Ruled: the door goes where the loss is, and the first press supplies a budget.**

*Where.* The obvious home is doc 12 §2.13's Auto-response rows, beside the road
pair. It is the wrong one, and not only because §2.13's plumbing belongs to
another lane this wave. The settings sheet is where a player goes having
*already decided*; the Upkeep band is where the game tells them there is a
decision — *"you are losing $169/gh; ending it costs $24,281"* — and a control
that is one line under that sentence is answerable in the moment the sentence
lands. AL2 ruled that wear is reported in the unit the player is losing it in;
the same reasoning puts the remedy on the same band as the report. A settings row
remains **appropriate as a second door** once §2.13's `POLICY_BUILDINGS` arm
exists (doc 12 D-84's note), and a second door onto one command is not a
contradiction — `cmd_set_building_repair_policy` is the single source either
would write through.

*What the first press does.* The pair ships `off / no budget`, and
`building_repair_policy().enabled` requires **both** dials, so cycling the band
alone would stand the policy at a rung with nothing behind it: a control that
does nothing when pressed, which is RR-1's failure mode wearing a different hat.
So the transition `off → a live rung` also supplies doc 03's own
`AUTO_REPAIR_DEFAULT_DAILY_CAP`, and the sentence above the dials says the number
out loud in the same frame. **The reverse is not symmetric**: cycling back to
`off` keeps the budget, because a budget the player chose is a decision and
switching a policy off is not a reason to forget it. See RR-150a.

## AN. Wave-18 rulings — the restore: a door that was never cut, a price that was never charged, and one word of §Y1 that had to be read narrowly (2026-09-02)

*(Measured in doc 92 §54. Shipped as report 98 RR-155/156/157. The defect rows
are doc 91 A91-D-99 and A91-D-100.)*

The player, on their own city, 2026-09-02:

> *"When buildings are destroyed, we should have a ONE BUTTON CLICK to just pay a
> fee and restore the building. That's it. I have many buildings that are
> destroyed that I can't actually fix even if I upgrade power. And the price
> should be MODEST — it shouldn't break the bank just to repair a few buildings
> when we have a ton of them."*

Every clause of that is a ruling below, and the second sentence is a defect
report: they were right, there was no way to fix them, and the reason is
A91-D-19's shape for the sixth time.

### AN1. There is a verb, and it is the ordinary construction path

`CitySim.cmd_restore_building(sim_id, preview)` ships. `Building.order_rebuild`
— authored, documented against doc 02 §2.12, returning a priced quote — had
**not one caller** (`grep -rn "cmd_rebuild\|\.rebuild(" sim/ ui/ game/`), and
`cmd_repair_building` answers `E_STATE` for anything that is not `active` or
`damaged`, so the verb a player naturally reaches for is closed against exactly
this state. A destroyed building was permanently dead.

The restore is **not a new machine**. It charges, calls `order_rebuild`, and puts
a `rebuild` job on doc 02 §2.13's one queue — so the queue panel lists it,
`cmd_rush_construction` rushes it, the six-stage crane walk draws it, and
`building_completed` fires exactly as it does for a new build. There is no second
completion path (report 98 RR-108's rule, obeyed by not writing one).

Two consequences of that choice, both deliberate:

* **the job kind is the authored `rebuild`, not `build`.** `ConstructionQueue.KINDS`
  has carried `rebuild` since doc 02 shipped and `CONSTRUCTION_SOURCE_BY_KIND`
  already publishes a word for it, so the roster needed nothing. What it DID need
  is `CitySim._emit_construction_stages`, whose scan filtered `build`/`upgrade`
  only — a restored site would have drawn no crane, which is the renderer telling
  the player nothing is happening on a lot they just paid for. `rebuild` joins
  the walk.
* **the player-facing word is RESTORE, in both places.** `ui_queue_source_rebuild`
  moves from "Rebuild" to "Restore" so the queue row and the button the player
  pressed say the same word. `rebuild` stays the code word; a second *player*
  vocabulary for one thing is how two halves of a seam teach the player they are
  two things.

### AN2. THE PRICE — 0.20 of capital, and the band it had to land in

`data/economy.json.expenses.RESTORE_COST_FRACTION = 0.20`, read through
`CostCurves.restore_cost_building()` (C-07: `data/buildings.json` and
`sim/buildings/building.gd` carry no dollar and no dollar fraction). Price is
`capital_value(level_at_destruction) × 0.20 × M_repair`.

**This REPLACES doc 02 §2.12's authored pair and does not inherit it.** The full
derivation is doc 92 §54; the ruling is the band:

| bound | value | what it is |
|---|---|---|
| **floor** | 0.17 × capital | the repair a MAINTAINING player buys — doc 92 §43.1's `balanced` agent repairs at condition 0.80, i.e. `0.20 damage × REPAIR_COST_PER_CAPITAL 0.85` |
| **ruled** | **0.20 × capital** | the round number at the bottom of the band |
| **ceiling** | 0.5525 × capital | the repair at doc 02 §2.6's auto-damage line, `0.65 × 0.85` — the deepest repair anyone sanely buys |

The floor is the load-bearing half and it is enforced **twice**: `CostCurves`
refuses a table below it at boot (beside the rush-rate derivation check), and
`tests/test_economy.gd::test_a_restore_is_never_cheaper_than_the_repair_it_replaced`
asserts the inequality for every archetype at every rung rather than asserting a
constant. Below 0.17 the game would **pay for neglect**: letting a building fall
down would be cheaper than keeping it up, at every level, for every archetype.

What 0.20 buys, from §54: the three ruins a `disaster_neglect` arc actually
leaves standing — the starter city's power plant, substation and water plant —
come back for **$24,000 against a $17,058 day's net, 1.41×**, where the authored
0.60 charged **$72,000, 4.22×**. Fifteen ordinary private ruins in a mature city
come back for about one day.

**M_repair and not M_build.** A restore reads `capital_value` like every other
line of the repair family; a player who chose `crisis` expects maintenance to
cost more, and this is maintenance at its capital end.

### AN3. THE LEVEL SURVIVES, AND THERE IS NO CLOCK ON IT

Doc 02 §2.12's grace window (72 game-hours) and its post-window demotion to L1
are **both retired**. `Building.order_rebuild` now returns
`pending_level = level_at_destruction` unconditionally, and
`REBUILD_GRACE_HOURS` is deleted rather than deprecated — a const that gates
nothing is a rule the next reader will try to obey.

Two reasons, and the second is the stronger one:

1. **A demotion is a second punishment for one event.** `capital_value(L)` IS the
   total the player paid rung by rung — a `house` at L5 is `1,200 + 1,380 + 3,519
   + 8,973 + 22,882 = $37,954`, which is the published ladder cell. Coming back
   at L1 hands back $1,200 and burns **$36,755** of the player's own money, for a
   fire they did not start. A game whose promise is *"You built it. Now keep it
   alive"* cannot answer a fire by un-building it.
2. **The window was ten times shorter than the absence the product is designed
   around.** Doc 08 caps offline catch-up at **720** game-hours. A player who
   closes the app overnight — the headline scenario — returns to a city where
   every ruin has already aged out of a 72-hour window. It punished exactly the
   behaviour the product is shaped for, and it did so silently.

`order_rebuild` returns no price at all now. `sim/buildings/` carries no dollar
and no dollar fraction (C-07), and what comes back in its place —
`hours_destroyed` — is a fact the surface wants, not a price.

### AN4. `owner_maintained` does NOT block a restore — reading §Y1 narrowly, on purpose

This is the ruling most likely to be got wrong by someone doing the obvious
thing, so it is stated as a rule and pinned by a test
(`tests/test_restore_building.gd::test_a_destroyed_private_building_can_still_be_restored`).

Doc 02 §2.6a / doc 93 §Y1 put **routine wear** on the owner: private stock keeps
itself up, floors at `band_worn`, and `cmd_repair_building` answers
`E_OWNER_MAINTAINED` because there is genuinely nothing for the city to buy.

**A building destroyed by fire or collapse is not routine wear.** It is a
capital event; the owner is gone with the building; and whether that lot gets
rebuilt is the city's call and the player's money. Doc 02 §2.6a is a rule about
*maintenance*, and a restore is not maintenance — it is the city choosing to put
a lot back into use.

The narrow reading is not a nicety. Houses, stores and offices are
`owner_maintained`, which is **most of the stock a player is looking at**, so the
natural reading of §Y1 would have closed this door on the majority of the city
by accident, and it would have looked like a correct application of a Wave-17
ruling while doing it.

### AN5. The restore has its own ledger source, and deliberately no lifetime row

Charged as `&"restore"`, not as `construction` and not as `repair`.

* **Not `construction`**, because doc 03 §2.10 layer 2's austerity **blocks**
  that category. A city that cannot restore its own power plant while austerity
  is engaged is a city that cannot recover from an austerity. Pinned by
  `tests/test_restore_building.gd::test_a_restore_survives_austerity`.
* **Not `repair`**, because folding a capital event into the routine line would
  make doc 92's repair burden look like it moved when the player simply rebuilt.

**It adds no `lifetime_restores` counter, and that is a determinism ruling, not
an omission.** `Treasury.lifetime` is captured into
`canonical_capture().ledger_totals` and therefore into `state_hash()`; a new key
would move every baseline in the project on a **player verb**, which must move
none. Doc 91 A91-D-100 is the row that publishes one, in a lane that holds the
matrix.

### AN6. No confirm dialog. The price is on the button.

Per §AB's precedent (the rush): a one-tap purchase whose price is on its own face
does not get a second dialog. `RESTORE · $12,000` is the whole affordance,
48 dp, disabled-with-the-price-still-showing when unaffordable (the build-card
pattern), and the panel re-reads the sim rather than predicting what moved.

This is deliberately **unlike** `DEMOLISH`, which is hold-to-confirm — demolition
is the one button in the deck that cannot be undone, and a restore is the one
that undoes something.

### AN7a. Found on the way past and deliberately NOT fixed: a destroyed utility shell keeps supplying

Measured while pricing the restore (doc 92 §54.9(b)), on the shipped starter
city: burn `PLANT-1` down through §2.12's own transitions and
`grid.system_supply_kw` stays at **8,000 kW**, the component reads `state OK`
and `energized`, and **0 of 34** buildings go dark. `WTR-2`'s doc-05 node reads
`state ok` with its shell `destroyed`.

The cause is a seam, not a sum: doc 04's grid node and doc 05's water node are
separate objects from the doc-02 shell that hosts them, `_retire_grid_node` and
`_retire_water_nodes` are called from `cmd_demolish_building` **and from nowhere
else**, and nothing on the supply side reads `Building.state == &"destroyed"`
(`grep -n destroyed sim/power/*.gd sim/water/*.gd` → one comment, no code). It
is A91-D-19's shape again.

**The ruling is to file it, not to fix it here.** It belongs to the power and
water models; its fix darkens cities, which moves the balance surface; and this
is a player-verb lane that holds no matrix and may move no baseline. It also
does not change anything in §AN — a restore is priced off `capital_value`, which
is a property of the archetype and its level, not of what the shell was supplying
while it was down. Doc 92 §54.9(b) carries the repro; it has no `A91-D` id
because this wave's ids were pre-assigned.

### AN7. A ruin must be SELECTABLE

Checked rather than assumed, and it holds today:
`CitySim` does not un-stamp a destroyed building's tiles, so
`BuildController.sim_id_at_tile` → `TileGrid.building_at` still resolves and
`pick_at_ground` returns `PICK_BUILDING` on a ruin. `building_view()` has no
state guard either. What the panel then DREW was the defect: `_render_repair`
drew a disabled REPAIR button with an `E_STATE` sentence on a city-maintained
ruin, and on private stock `E_OWNER_MAINTAINED` folded into "nothing to buy" and
the ruin's panel offered **no action at all**. Doc 12 D-86 is the row; the
destroyed state now has its own block.

**And the rule that block follows is: draw what the sim will ACCEPT, hide what it
refuses.** Two of §2.9 item 6's three buttons answer `E_STATE` on a ruin, so
neither is drawn — `cmd_repair_building` because a ruin is not `active` or
`damaged`, and `cmd_demolish_building` because doc 02 §2.12 routes a ruin to
`cmd_clear_rubble` instead, **which has no door either and is A91-D-99's
remaining half** (`grep -rn "cmd_clear_rubble" sim/ ui/ game/` finds nothing).
`PRIORITY` stays, and the asymmetry is the rule rather than an exception:
`cmd_set_priority` ACCEPTS a ruin, the tier lives on the grid service record
which a destruction does not detach, and the tier set now is the one the restored
building comes back with. It is the one thing besides the restore that a player
can usefully decide while the lot is still rubble.

`tests/test_ui_restore.gd` asserts both halves **against the sim's own answer**
rather than against the panel's rule, so a change to either has to move both.

---

## AO. Wave-19 rulings — a budget that was charged to the wrong account (2026-09-03)

### AO1. The mechanic: two questions that had one number

`CatchUpPlanner.plan` did this, and it is the whole defect in one line:

```gdscript
var cap_ms := mini(OFFLINE_CAP_REAL_MS, cap_hours * REAL_MS_PER_GAME_HOUR)
```

`OFFLINE_CAP_REAL_MS` is doc 01 C-19's **fairness** rule — *how much of an
absence does the game pay for?* — answered in real hours of a person's life, and
it is 12. `cap_hours` is doc 08 §2.12's **performance** budget — *how long may the
catch-up veil run?* — answered in milliseconds of wall clock, derived from a
coarse-step measurement on a workstation, and it resolved to 360 game-hours = **6
real hours**. `mini` made the second one win, every night, silently.

**The mechanical tell is the units.** A `mini` between two quantities is only
meaningful when they measure the same thing, and these do not: one is a promise to
a player and the other is a property of a machine. Wave 17 converted the machine
number into game-hours to make the comparison type-check, and a unit conversion
is exactly the move that hides a category error. There was no bug in the
arithmetic — `clamp(floor(ceil(2000/5.488)/24)×24, 72, 720) = 360` is correct —
and the code did precisely what it said.

### AO2. Why the fix is a deleted parameter and not a bigger number

The obvious repair is to raise `max_coarse_hours` to 720 and move on. It is
rejected, and the reason is that it leaves the mechanism intact: the next
measurement on the next city lowers it again, and the clamp is *supposed* to
respond to measurements — that is what it is for. A knob that is only safe at one
value is not a knob.

So `plan()` loses the parameter. It takes three arguments, it reads no data file
(`grep -n SavePolicy sim/time/catchup_planner.gd` → nothing), and
`tests/test_catchup_veil_budget.gd` scans the source to prove the name is gone
rather than merely unused. **There is no expression a caller can write that
credits a player less than doc 01's cap.** That is a stronger property than a
correct number and it is the only one a future wave cannot un-tune.

It also strengthens constitution §5 for free. A clamp derived from a live
measurement would credit two phones differently for the same absence; Wave 17
avoided that by shipping the measurement in a data file, which fixed the
determinism and kept the theft. Removing the read removes both.

### AO3. The unit a surface quotes is part of the ruling

The cap is one fact with two spellings — 720 game-hours, 12 real hours — and the
two surfaces had picked one each. The veil said *"The longest stretch this city
simulates at once is 6 hours"* (real) and the away report said *"Your city ran for
720h"* (game). Both were true and one of them was useless, because a player who
slept eight hours is not counting in city time.

**Rule: a surface that quotes a limit quotes it in the unit of the thing the
player did.** They were away for hours, so the cap is in hours away.
`CatchUpPlanner.plan` therefore publishes `cap_real_hours` beside
`cap_game_hours` and the copy fills from the first; the alternative — each
surface dividing by 60 on its own — is how the two disagreed in the first place.

The same rule catches the older half of the same header: `elapsed_game_minutes`
was the raw wall clock, so a capped absence reported city time the city never
lived. City-time facts come from the plan's `credited_real_ms`, not from how long
the phone was in a pocket.

### AO4. What was measured before it was ruled, and what that changed

Two candidates were available for *"the money stops"* and only one of them was
ours. Doc 03 §2.11's exponential taper has an arithmetic ceiling of `OFF_FULL +
OFF_TAU = 94` effective game-hours, which reads exactly like a wall on paper.

It was measured against a control arm — the same settled city, the same number of
real hours, run **online** with the player present and buying nothing — and it is
not a wall in practice: an absence pays **97.4–101.1%** of the online figure at
every length from one real hour to twelve (doc 92 §55.4). The reason is in doc 03
§2.11's own `TAPER_EXEMPT` list: construction, upgrades and population arrival are
work the player already paid for, so the untapered base grows while the multiplier
shrinks, and at a growing city the two very nearly cancel.

**So no taper change shipped, no difficulty scalar moved, and doc 08 §2.3's eight
fairness rules are untouched.** The ruling worth recording is the method rather
than the result: a plausible mechanism that has never been measured against a
control is a suspect, not a cause, and this wave's whole change would have been
mis-aimed if the taper had been retuned on the strength of how it reads.


## AP. Wave-19 rulings — the one-way door: what wear is allowed to do to a building, and what a city is owed when it falls over (2026-09-03)

*(Measured in doc 92 §56. Shipped as report 98 §59, RR-164..RR-168. The defect
rows are doc 91 A91-D-103, A91-D-104 and A91-D-105.)*

The player, on their own Galaxy Z Fold 6 city, 2026-09-03, after one night:

> *"The buildings are still being destroyed super fast. There was a natural
> disaster, a water flooding, I woke up to — and there's negative money. I've
> been trying to restore all the buildings so we can get revenue back up, but it
> seems really difficult when all the buildings just keep being destroyed. ALL of
> my buildings are destroyed right now."*

**The first job was to find out whether that is the flood's doing, and it is
not.** `tools/measure_catastrophe.gd` (doc 92 §56.1) ran 45 game-days across all
four presets in both session kinds — an online city fast-forwarded, and a real
closed app — and the cause column is unanimous in all eight arms:

| door | destructions, 8 arms × 45 game-days |
| --- | --- |
| `apply_damage` reaching condition 0 (incidents, disasters, the flood) | **0** |
| `burn_down` (a fire that was never answered) | **0** |
| `roll_structural_failure` (doc 02 §2.6's wear roll) | **all of them** |

So every ruling below is about wear, and none of them is about the storm. The
storm the player enjoyed is not the thing that took their city.

### AP1. Wear may CONDEMN a private building. It may not demolish one.

`data/building_rules.json owner_maintenance.wear_may_demolish = false`;
`Building.roll_structural_failure` returns empty for an `owner_maintained`
building; `BuildingCatalog.wear_may_demolish()` stamps it beside
`owner_maintained` at doc 93 §Y2's same four sites.

**The chain this cuts**, measured hour by hour on the standard preset (doc 92
§56.2) and containing no disaster at all:

1. a city grows past the generation it bought, and **74 to 107 of its 251
   buildings are permanently dark** from game-day 24 onward — with `failed`
   grid components sitting at 0, so this is not a broken transformer, it is
   arithmetic;
2. doc 02 §2.6a's ownership floor has a service clause (§Y1a) — *an owner the
   city has left in the dark cannot hold anything* — so the floor lifts for
   exactly those buildings;
3. they fall unbounded through `auto_damage_threshold` 0.35 into `damaged`,
   where `damaged_decay_multiplier` 1.50 speeds them up, and on down to 0.10;
4. `structural_failure_p_per_hour` 0.02 then deletes them: 42 of 251 gone
   between game-day 31 and game-day 45, **peaking at nine buildings in one
   game-day — one every 2.7 real minutes.**

That is the player's report, reproduced, and step 4 is the only irreversible
step in it. Steps 1–3 are a city the player can see going wrong and can fix;
step 4 converts the fixing into a purchase they cannot afford, because a ruin
earns nothing and costs money to restore.

**The argument for the ruling is §Y1's own sentence, read to its end.** §Y1
justifies the floor with *"below that it stops being an asset and starts being a
liability, and it is **their** asset"*. An owner in that position boards a
building up. They do not bulldoze it and walk away from the land. §Y1 stopped
one word early, and that word was the whole ratchet.

**Neglect is not forgiven, it is made reversible.** A condemned building sits in
`damaged` at 0.10, where doc 02 §2.12 already charges it hard: `output_mult`
0.40, `state_occupancy` 0.40, `coverage_mult` 0.25, and doc 03's `f_condition`
pays `0.40 + 0.60 × 0.10 = 0.46`. A fully condemned city earns on the order of a
fifth of its nominal income (§56.1 measures the standard arm's population fall,
1512 → 1302, with the ruling in force). The punishment is severe and it is
**recoverable by fixing the thing that caused it**, which is the loop the game is
named after.

**This is not a shield, and four doors stay open**, which is what keeps a storm
worth being afraid of:

* `burn_down` — a tier-5 structure fire nobody answered for half a game-hour;
* doc 06's explicit `destroy_building` cascade op;
* an event landing on a building already at or below the threshold (§AP2);
* this same roll on the city's **own** stock — civic and utility archetypes are
  not in `owner_maintenance.classes`, so a police station, a substation or a
  water works the player let rot is still lost. The city is responsible for what
  the city owns.

**Why not a `derelict` state instead** (the option the brief weighed second):
because `damaged` at 0.10 already IS that state. It has its own output, occupancy,
coverage and revenue multipliers, its own decay multiplier, its own band name in
the building panel (99-PA PA-31), its own repair verb and its own price. Adding
an eighth state to doc 02 §2.5's machine would have bought a second name for
behaviour the seven-state machine already has, at the cost of a save migration,
a renderer case and a UI case in four lanes' files.

**Why not a cap on destructions per absence** (the option weighed fourth):
because doc 08 C-47 already caps it at zero, and §56.1 confirms it — the absence
arm destroys **0 buildings in 45 game-days on every preset**. The absence was
never the moment of destruction. The moment of destruction is the RETURN, when
C-47's suppression lifts on a city that spent the night rotting and the roll is
taken on the whole backlog at once. A cap on the absence would have been a cap
on a number that is already zero.

### AP2. One event may not demolish a standing building

`Building.apply_damage` floors at `structural_failure_threshold`: a building
ABOVE 0.10 when damage lands cannot be taken past 0.10 by that damage, however
large the fraction. A building already at or below it is finished off exactly as
before.

The floor is `structural_failure_threshold` itself and **not a new constant**.
Doc 02 §2.6 already names 0.10 as the line below which a building is no longer
structurally sound; a second authored number meaning the same thing would be a
second source of truth for one idea, which is C-07's rule applied to a fraction
instead of to a dollar.

**This door fires zero times on the shipped tables and the guarantee is worth
writing down anyway.** §56.1's cause column is the evidence that no live damage
fraction reaches condition 0 today. §56.4 then moves the Director's pressure, and
the promise *"You built it. Now keep it alive"* should not rest on the
assumption that nobody ever authors a `building_condition` op of −1.0.

**One line had to be split to make the floor possible.** `destroy_building` — an
op whose name is its specification — used to spell itself `apply_damage(1.0)`, so
a floor on damage would have silently disarmed destruction. `Building.demolish()`
now says what it means, and `CityIncidentWorld.destroy_building` calls it.
**It carries doc 08 C-47's guard, which that branch never had**: before Wave 19
an explicit destroy was the one door through which an ABSENCE could still take a
building, in a function whose whole point was that absences may not.

### AP3. The Director's pressure knobs are not retuned this wave, and the measurement is the reason

The brief for this lane named five knobs to re-derive — `floor.tp_per_day`,
`tp.offline_rate_mult`, `fairness.offline.max_hazards_per_catchup`, the
cooldowns, and the flood's own damage fractions — on the grounds that all of them
were authored while the Director stalled after two events, and that 99-PA PA-04
unstalled it the day before. That is a correct reason to *re-derive*. It is not
by itself a reason to *move*, and the re-derivation (doc 92 §56.4) says move
none of them. Each verdict, with the number behind it:

**`floor.tp_per_day = 6.0` — HELD, and the premise that it bypasses the spine is
false.** The floor looked like it hit the weak hardest: over 45 game-days the
Director fires 15 / 13 / 41 / 44 events on casual / standard / hard / crisis,
i.e. **the smallest and poorest city in the matrix takes three times the events
of the largest**, which reads as doc 07's spine — *threat scales UP with
preparedness* — running backwards. It is not the floor doing it.
`DirectorTables.tp_base_per_day` returns `max(ladder[tier], floor)` and
`DisasterDirector.tp_rate_per_day` then multiplies that base by `age_ramp ×
pressure(P) × tp_rate_mult`, so **the floor already passes through
`0.55 + 0.90·P` exactly as the tier ladder does.** The spread is the difficulty
ladder (`tp_rate_mult` 0.6 → 1.6) plus F5: a large city generates enough ambient
incidents to trip `suppress.customers_out_pct` and hold itself down (624 incidents
on standard against 121 on crisis), which is F5 working. A knob was almost moved
here on a premise that reading the code disproved, and that is worth recording as
loudly as a change would have been.

**`tp.offline_rate_mult = 0.35` and `fairness.offline.max_hazards_per_catchup =
1` — HELD.** §56.1 measures what an absence actually delivers: **0 Director
events in 45 game-days on three of four presets, 1 on the fourth.** The offline
budget is not the thing that hurt this player, and the direction the report asks
for is *fewer* overnight surprises, not more. Raising it because §AP1 made
destruction non-terminal would be spending the safety §AP1 just bought, in the
one session kind the player was asleep for.

**The cooldowns — HELD**, for the same reason: they are measured inside the event
counts above, and those counts did not change across this wave's ship (§56.4's
before/after is bit-identical, 15 / 13 / 41 / 44 both sides).

**The flood's damage fractions — there are none, and that is the finding.**
`FloodField` integrates depth from `precip_mm_h` and emits exactly two things:
`flood_level_changed` and `road_closed_flood`. `grep -rn "flood" sim/ | grep -i
damage` finds no path from the flood field to a building at all. **The water
flooding the player woke up to could not have damaged one building**, and the
`water_main_break` incident beside it damages pressure and roads, never
structures. Their rubble was §AP1's wear chain; the flood was the weather they
happened to see while it was happening.

**What the measurement DID find, and what it is filed as.** Across all eight arms
the `building_damaged` cause column reads `decay=61 incident=0 fire=0` — that
shape, on every preset. **The entire incident and disaster layer does zero
damage to buildings over 45 game-days**, because `building_condition` ops live on
tier-2 and tier-4 escalations that auto-dispatch resolves before they arrive. So
today a storm is spectacle and wear is the only physics with teeth, which is the
wrong way round for a game about keeping a city alive. That is doc 91 A91-D-105.
It is **not** fixed here: the honest sequence is §AP1 first (so that damage is no
longer terminal), then a measured damage pass on doc 06's escalation ladder in
the lane that owns it — and doing them in one wave would mean opening a damage
path and removing a destruction door in the same measurement, with no way to
attribute either.

### AP4. A city that has fallen over is owed a way back, and "per era" has to mean something

Two defects, one ruling.

**(a) `relief_grants_per_era` has never had an era** (doc 91 A91-D-103). Doc 03
§2.10 layer 5 is the recovery ladder's top rung: a free automatic grant when the
treasury is past half the credit line and the trailing net is negative.
`Treasury.relief_grants_used` is incremented, persisted, and **reset by nothing**
— `grep -rn "era" sim/` finds the word in one place, the key's own name. So the
allowance is a LIFETIME one: three grants on standard, two on hard, zero on
crisis, for the whole life of a city this game expects to be played for weeks. A
player who has spent theirs has reached a dead end with no losing screen, which
is exactly the state the report describes.

An era is now a **city level**. `relief_grants_used` resets on the level
transition that already pays `LEVEL_UP_GRANT_BY_CITY_LEVEL`. It is the smallest
honest definition available: the quantity is already tracked, already persisted,
already composed from both routes by §G1, and it only ever goes up — so the
allowance refreshes when the city demonstrably grew, and cannot be farmed by
oscillating anything. Crisis stays at 0 per era, because crisis is a preset that
is allowed to be lost.

**(b) The grant is proportional to the revenue the disaster destroyed** (doc 91
A91-D-104). `grant = clamp(1.5 × daily_gross_revenue, 8 000, 250 000)` is
measured on the city AFTER the loss, so the worse the catastrophe the smaller the
relief. At the limit the report describes — every building a ruin — gross revenue
is near zero and the grant is `RELIEF_MIN`, $8 000, against a restore bill in the
hundreds of thousands. The rung is thinnest exactly where it is the only rung.

Relief is now `max(` the revenue term `, RELIEF_DAMAGE_FRACTION × the outstanding
restore bill `)`, still inside the same `[RELIEF_MIN, RELIEF_MAX]` clamp. The
bill is not a new price: it is `CostCurves.restore_cost_building` summed over the
city's actual ruins at the city's own `M_repair` — the identical call
`cmd_restore_building` charges — so C-07 keeps its single price and the grant can
never disagree with the invoice the player is looking at.

`RELIEF_DAMAGE_FRACTION = 0.35` is **adopted, not invented**: it is
`DEFERRED_REPAY_FRACTION`, already this document's answer to the only other
question of the same shape — how much of a hole the city closes per step while it
is in one (§2.10 layer 4 repays 35 % of positive net against deferred liability).
A second number for one idea would be a second source of truth.

**What stops it being a farm**, stated as the brief requires:

1. it pays only while **both** insolvency conditions hold — treasury under
   `−0.5 × credit_limit` **and** a non-positive 24-hour trailing net — so a city
   with income cannot draw it at all;
2. `RELIEF_DAMAGE_FRACTION < 1`, so the grant never covers the loss. Wrecking
   your own city to draw relief loses 65 cents on the dollar, for every building
   in the catalogue. **That is an inequality, not a hope**, and it is the whole
   anti-farm argument;
3. the 120-game-hour cooldown and the per-era allowance both still bind;
4. the bill it is measured against SHRINKS as it is spent — every restore the
   grant pays for leaves the sum — so relief decays back to the revenue term as
   the city recovers, which is the direction a subsidy should run.

**A performance seam came with it, and it is load-bearing.**
`update_recovery_ladder` runs once per settled game-hour and the bill is
`O(roster)`; the bench city carries 1 500 buildings. `Treasury.relief_gates_pass`
states the four price-free gates once, and `CitySim` walks the roster only when
they already pass — which on any city that is not deep in the credit line is
never. Both `profile_sim` cities are solvent throughout, which is why the walk
does not appear in this wave's timing deltas.

## AQ. Wave-19 rulings — what a collection is allowed to be worth, and what "something to DO" has to survive (2026-09-03)

*The lane is Wave 19 Lane 3. Its whole brief is one overnight report and the
report's last sentence is the hard part: "any other fun ideas to collect money in
the game, something to actually DO to collect, other than tax revenue." Sections
§AQ1 and §AQ2 rule on the money that already existed; §AQ3 is the argument for
what was added and, more importantly, for what was refused.*

### AQ1. The ratio ruling survives; its denominator does not

**Q.** A tapped crook's mean bounty rises from $305 to $507.50. Doc 03's ruling
is that "a tapped crook is petty, a dispatched crime is the real one, and the
ratio has to read as about half at a glance", and the shipped bound is
`street_mean / dispatch_reference ≤ 0.60`. At 507.50/595 = 0.853 the re-price
fails it. Is the ruling wrong, or is the re-price wrong?

**Neither. The DENOMINATOR is wrong, and RR-78 said so when it created the
number that should have been there.**

$595 is `dispatch_payout_base.crime × (1 + 0.35 × 2) × 1.00` — doc 06's reference
case, **auto-dispatched**. But the ruling's own word is *dispatched*, and a
dispatched crime is one a human dispatched. RR-78's `_manual_mult_note` is
explicit about what that is worth: *"a human on the incident drawer is worth
exactly [1.50×] … the drawer is where the raise is."* The reference case a player
who works the drawer actually collects is $892.50, and against that the re-priced
crook is **0.569**.

**RULED.** The bound is stated against the MANUAL reference, and the ordering
against the AUTO one, and they are two assertions because they are two claims:

* a tapped crook must pay **less than an auto-answered crime** (507.50 < 595) —
  this is what stops the street layer being priced past the incident it is a
  lesser version of;
* and **no more than 0.60 of a hand-dispatched one** — this is the "reads as about
  half" claim, and it is the one the player's attention is being priced by.

**And it is checked at every city level, which the old form never did.** Both
sides carry a level curve now; the dispatch curve is steeper by construction
(`MANUAL_DISPATCH_LEVEL_K` 0.90 against `STREET_REWARD_CITY_LEVEL_K` 0.25), so the
ratio falls from 0.569 to 0.320 across the ladder. A base-table check would have
passed a wave that inverted the two at level 6.

**The corollary, and it is the uncomfortable half.** The player asked for
$15,000 a collection. At the layer's delivered rate of 0.339 offers/gh that is
$5,090/gh — **1.85× the entire net income of a level-6 city**. There is no value
of any street constant that pays it and leaves a game underneath. The number is
therefore ruled OUT of this layer and INTO one that fires about once a game-day.
Saying so in the doc is the point: the next lane that reads "add a zero" must not
try again here.

### AQ2. A ruin is worth something, and the verb that pays is the one a broke player can press

**Q.** Doc 02 §2.12 has always carried `destroyed → (removed)` with a `0.10` COST
fraction — clearing rubble is something the city *pays* for. Wave 19 ships it as
something the city is *paid* for. Which is right?

**Both, and the fraction is the difference.** Clearing costs 0.10 of capital; the
scrap off a building that was worth 0.25 of its capital intact is worth more than
that. `SALVAGE_FRACTION = 0.25 − 0.10 = 0.15` is the NET, and it is a closed form
off two numbers the project already published rather than a fourth magnitude
invented for this wave. The wrecking company pays the city, and the amount is the
scrap less the mess.

**Q.** Doesn't a paying ruin-removal verb reward destruction?

**No, and the three bounds are what prove it rather than assert it.** Salvage
(0.15) is strictly worse than demolishing the same building while it still
stands (0.25), so letting stock fall is never a way to make money. It is strictly
less than restoring costs (0.20), so the pair is a decision and not a loop. And
it is strictly more than the restore→demolish arbitrage nets (0.05), which is the
bound nobody was looking for — see §AQ4.

**Q.** Why is it hold-to-confirm when `RESTORE` is one tap?

Because the deck's rule is not "expensive things get a confirm", it is
**"irreversible things get a confirm"** — §2.9 item 6's own words for `DEMOLISH`,
*"the one button in the deck that cannot be undone"*. `RESTORE` undoes something;
this removes something. It is the second member of that set and it takes the same
800 ms from the same authored key.

**Q.** Why no `SALVAGE ALL`, when `RESTORE ALL` exists two lines above it?

**RULED, and the asymmetry is the ruling.** A batch is safe when its worst case is
spending money and unsafe when its worst case is a city that cannot be brought
back. `RESTORE ALL` at its worst leaves the player poor, which earning fixes;
`SALVAGE ALL` at its worst leaves them with an empty map, which nothing fixes. A
player with a dozen ruins presses twelve buttons and each one is a decision they
made. **Re-open on one condition and no other:** telemetry showing players
abandoning cities *because* clearing them one at a time was too slow — which is
a different complaint from the one this wave answers.

**Q.** Why does the money go to `&"construction"` rather than to a
`city_services.salvage` row beside `street`?

Because `Treasury.lifetime` is inside `state_hash()`, so a new ledger key moves
all four determinism baselines on every city (doc 91 `A91-D-100` already records
this for `&"restore"`, and `A91-D-37` for `&"incident"`). Three arms belong in
one edit and one re-record, in a lane that holds the matrix. The category is not
a compromise on its own terms either: a demolition refund is credited to
`&"construction"` today and this is a demolition refund at a different fraction.
Filed as `A91-D-108` with the three-arm fix written out.

### AQ3. What "something to DO" has to survive

*The player's last sentence is the one this section rules on: "any other fun
ideas to collect money in the game, something to actually DO to collect, other
than tax revenue." Five candidates were weighed against the two tests this
project applies — **does it give the player something to DO when they open the
app**, and **does it survive doc 03's dollar monopoly** — and two shipped.*

| candidate | something to DO? | survives C-07? | ruling |
|---|---|---|---|
| **contracts / commissions** | **yes, and it is the only one with a CLOCK** | yes — one payout table, `data/contracts.json` carries no dollar | **SHIPPED** (§2.5b) |
| **salvage from ruins** | **yes, and it is the only one a broke player can press** | yes — a closed form off two published fractions | **SHIPPED** (§AQ2) |
| inspections / permits | weakly — a repeatable tap with a per-building cooldown | yes | **REFUSED**, see below |
| response-time bounties | no — it is a multiplier on a thing the player already does | yes | **FOLDED INTO RR-169(c)** as the manual premium's level curve |
| tourism / landmark revenue | **no — it is a RATE**, and the ask was explicitly for something other than a rate | yes | **REFUSED** |
| a mayor's daily objective | yes, but it is the contract board with one client and no choice | yes | **SUBSUMED** |

**Why contracts and not the others, in one sentence each.**

*Contracts win the first test outright because they are the only candidate with a
DEADLINE.* Everything else in this game waits for the player: a tax rate settles
on the hour, a block develops over game-days, a crook stands on a kerb for four
minutes and then does not. A commission is the first thing in the project that
gives a player a reason to open the app **at a particular time**, which is
precisely what the 2026-09-03 report was missing — the player went to bed hoping
to wake up to something and woke up to nothing.

*They also fold the answer into work the player was doing anyway.* Two of the
seven commissions pay for restoring destroyed buildings, which is the literal
sentence the report contains: *"I've been trying to restore all the buildings so
we can get revenue back up."* A reward layer that pays for the grind the player
described is worth more than one that adds a new grind beside it.

*Salvage wins the first test in a way nothing else can:* it is the only verb in
the project a player with a negative balance can press. Every other candidate
here, and every priced verb the game already had, asks that player for money.

**INSPECTIONS: refused, and the reason is worth writing down because it will be
proposed again.** *Tap a building, pay a fee, learn its condition* is a clean
loop and it teaches the thing the same playtest complained about ("the buildings
are still being destroyed super fast"). It is refused on the second test — not
C-07, which it passes, but the test under it. **The condition it would reveal is
already on the panel.** S5 draws a condition meter, four service tiles and a
`Fix this →` on every blocked requirement; an inspection would charge a fee for
re-showing information the game gives away, and would be a paid tooltip. A verb
that pays the player for reading a number the panel already prints teaches them
that the panel was hiding something. **Re-open only if** the panel stops
publishing per-building condition, which nothing plans.

**TOURISM: refused on the ask's own words.** *"Something to actually DO to
collect, other than tax revenue"* — landmark revenue IS tax revenue with a
different multiplier on it. It would be a good feature and it is not an answer to
this sentence.

**RESPONSE BOUNTIES: not refused, absorbed.** The dispatch layer already prices
speed (`speed_bonus` on [0.60, 1.50]) and already pays a human premium; what was
broken was that neither grew with the city (`A91-D-106`). RR-169(c) fixes the
decay rather than adding a second reward on top of it, which is the cheaper and
more honest half of the same idea.

**The three properties every new money source in this project has to have**, and
they are stated here because two candidates were shaped by them rather than
merely checked against them:

1. **A CLAIM, not an accrual.** Nothing on the board is money until it is tapped.
   The street layer's rule ("nothing spawns VALUE; a TAP is money") is what makes
   an attention reward an attention reward instead of a rate with extra steps.
2. **A bound that is one authored number, in data, that a gate can read.** For
   the street it is the offer interval; for commissions it is
   `cooldown_h_after_claim`. A layer whose income bound is an emergent property
   of five interacting knobs is a layer nobody can retune safely.
3. **Nothing while the player is away.** Doc 08 §2.3 rule 9. Both new sources
   return before their first statement on the coarse path, which also means the
   balance matrix cannot see either of them — and that is what let this lane ship
   two income systems without holding the matrix.

**The one thing §AQ3 declines to rule on.** Whether the board should ever offer
more than one commission at a time. One-at-a-time is what makes the cooldown a
bound the gate can state in a sentence, and it is also what makes accepting a
DECISION rather than a checklist. If a later wave wants two, the ceiling
derivation has to be re-done against the pair and not against the tier, and this
section is the record that it was a choice.

### AQ4. The arbitrage nobody was looking for

**Found while deriving `SALVAGE_FRACTION`'s floor, not while hunting for it.**

`RESTORE_COST_FRACTION` is 0.20 and `DEMOLITION_REFUND_FRACTION` is 0.25, both
read off the same `capital_value(level)`. So on any ruin, at any level, of any
archetype:

```
restore  −0.20 × capital
demolish +0.25 × capital
net      +0.05 × capital   ← per ruin, repeatable
```

It is real, it is not new — it has been true since Wave 18 shipped the restore —
and nothing bounds it but the construction time the rebuild spends and the crew
it occupies. On the starter city's power plant (capital $60,000 at L1) it is **+$3,000 a cycle**.

**It is recorded and NOT closed in this lane** (`A91-D-107`), for two reasons.
First, closing it means moving one of two fractions that were each derived
against something else — `RESTORE_COST_FRACTION` against the repair a maintaining
player buys, `DEMOLITION_REFUND_FRACTION` against every other demolition in the
project — and a fraction moved to fix a third thing is a fraction that no longer
means what its note says. Second, the honest fix is probably neither: a rebuild
that has just completed could carry a short window in which the demolition refund
is the salvage fraction instead, which is one authored number and a state field,
and belongs with whoever owns doc 02 §2.12's transition table.

**What this wave does about it is make it pointless.** Salvage pays 0.15 of
capital immediately, with no construction time and no crew, against the
arbitrage's 0.05 after a full rebuild. The exploit is now strictly dominated by
the button next to it, which is the cheapest possible mitigation and is not a
fix.

## AW. Wave-24 rulings — a million at the first rung, the wall the money found, and what a returning city is owed (2026-09-04)

*The lane's brief is one instruction from the player, 2026-09-04, and it contains
two numbers and one promise: "**Start with one million dollars, and then at level
seven we give them seven million** … And I want you to make it so if a player has
already passed level one and was supposed to get a million dollars, you should be
able to collect it for all of them AUTOMATICALLY — you should just check if you
have received it, and if you haven't, then you get it. That way we can keep one
city going for a while." §AW1 rules on the curve between the two anchors; §AW2 on
what the money broke and what that turned out to be; §AW3 on the shape of the
back-pay; §AW4 on the four things this lane found and deliberately did not fix.*

### AW1. Two anchors and a straight line — and the anti-farm argument survives it

**Q.** Wave 22 (§AU1) shipped a geometric run at ratio 1.5, because 1.5 is
`sqrt(2.25)` and 2.25 is doc 09 §2.11's own rung ratio — so *the grant grows at
half the exponent the city does* and its share of the city falls by two thirds a
rung by construction. The player has now named the two endpoints instead of a
band. Does the derived ratio survive, or does the instruction replace it?

**RULING: the instruction replaces it, and the property the ratio existed to
guarantee is CHECKED rather than assumed.**

Two anchors fix a curve as soon as you name a family, and the honest reading of
*"one million at rung one, seven million at rung seven"* is the family with the
fewest invented numbers in it: a straight run of step $1,000,000, so that **rung k
pays k million dollars**. There is no third constant. The alternative —
`7^(1/6) = 1.3831` — introduces one, and the one it introduces is not derived
from anything this project publishes, which is precisely the sin §AU1 was written
to avoid.

**The property is what matters, not the shape that used to imply it.** §AU1's
guarantee was *the grant's share of the city it lands on falls every rung*.
Measured on the linear ladder, the rung-on-rung ratio is 2.00 / 1.50 / 1.33 /
1.25 / 1.20 / 1.17 against the city's own 2.25 — so from rung 2 up the grant
grows **more slowly** than the city, the share falls, and the fall accelerates
(0.89 / 0.67 / 0.59 / 0.56 / 0.53 / 0.52) where the geometric run's was flat at
0.61. **The linear ladder is the more anti-farm of the two**, which is a finding
and not a convenience; it is asserted in `tests/test_city_services.gd` as a bound
on the ratio, so a future re-scale that grew at or above 2.25 fails there.

**And the half-of-the-next-chapter rule is RETIRED, out loud.** Rung 6 is
$6,000,000 against chapter 7's whole ask of $644,370 — 9.3×, not half. Doc 03
§2.5a says so in those words. A derivation that survives only by being restated
after the numbers moved is worse than no derivation, and doc 91 A91-D-120 is
already filed against exactly that failure mode one wave back.

### AW2. The gate said "power" and meant GENERATION — and the gate is not what moves

**Q.** The new table takes gate 18b — *a city may not outrun its own power* —
from 5.99 % of building-time dark to 37.60 % across three seeds, against a ruled
ceiling of 20 %. The lane's brief names three candidate answers: the gate is
measuring a reactive agent rather than a player; the game should help; or the
bound genuinely moves. Which?

**RULING: none of the three, because all three assume the diagnosis. Measure the
cause first, and the cause is that nothing in this game has ever bought
GENERATION.**

`tools/probe_dark.gd` was written to split gate 18b's single share into doc 04's
three distinct failures — **unattached**, **orphaned** and **starved**. On the
rich city: zero unattached, zero unparented transformers, zero CRITICAL
transformers, worst feeder at r = 0.25, and `supply_kw` **pinned at 8,000 for the
whole run** against a demand that reaches 11,585. Every founded city has one
`power_facility` at doc 04 §2.2's L1 rating, nothing else generates, and no
strategy in `tools/playtest.gd` has ever bought or upgraded one.

**The wall is at the fork too, inside gate 18b's own run** — game-day 50 reads
15.55 % dark, 166 orphaned buildings and 9,227 kW of demand against 8,000 of
supply. The gate's 5.99 % is a fifty-day MEAN over a column that ends at 15.55 %.
So the ruling has three parts:

1. **The bound does not move**, and it does not need to. `Balanced` gains
   `_lead_generation` — the same *"a purchase the agent never makes"* family as
   both of Wave 6's grid fixes — and the shipped arm reads **4.61 / 20.88 /
   0.55 %, mean 8.68 %**, against a fork mean of **12.16 %**. The money leaves the
   city lighter than it found it. Not one ceiling in the gate file moves.
2. **The rule may not introduce a number.** Its trigger is doc 04 §5.10's own
   WARNING band, the same authority `FEEDER_RELIEF_RATIO` cites; its choice
   between upgrading and building is doc 02's own prices ($69,000 for +10,000 kW
   against $60,000 for +8,000); and it has **no cooldown constant**, because the
   fix is a construction job whose duration doc 02 publishes and a shell in
   flight is `under_construction`.
3. **The gate's docstring is corrected rather than its threshold**, because the
   Wave-6 three-seed table it quotes (6.25 / 5.91 / 5.74) has been five waves
   stale and the gate asserts one seed. See §AW4.

*A note on what was NOT ruled: the lane's candidate (b) — the game warning the
player before they place — is a real improvement and remains available, but it is
not what this measurement asked for. A human with Wave 18's power panel reads
supply against demand and buys the plant; the AGENT could not, because no agent
had the rule. Fixing the agent is fixing the measurement instrument, and fixing
the instrument is what makes the gate's answer trustworthy again.*

### AW3. Back-pay is a LEDGER, and the ledger is dollars

**Q.** *"Check if you have received it, and if you haven't, then you get it."*
What is "it", and what records having received it?

**RULING: "it" is a DIFFERENCE, so the record has to be dollars per level, not a
paid/unpaid bit and not a level number.**

A city paid $2,500 for rung 1 under the original ladder **has** received rung 1.
It is owed $997,500, not $1,000,000 and not nothing. A flag cannot say that; a
high-water level cannot say it either. So `Treasury.grant_paid_by_level` is an
array of dollars indexed like the grant table, written by both payment sites
through `note_grant_paid`, which **only ever adds**. Idempotence, pay-only-the-
difference, once-per-level-per-city-for-life and immunity to a future table that
pays less are all properties of that shape rather than guards somebody has to
remember.

**Three sub-rulings, each of which is a way this could have been got wrong:**

**(a) The walk stops at the CURRICULUM level, never the composed one.** This is
§AU6 applied to the second payment site: a level is a permission and a permission
may not depend on how it was reached; a grant is payment for a lesson, and the
population backstop teaches none. A city that grew to level 5 on residents alone
is owed nothing.

**(b) The SEED runs further than the ARREARS, and that asymmetry is the reason
the ledger holds dollars.** Below section version 9 the grant rode the composed
level, so a legacy city was paid for rungs its curriculum never earned. Those
rungs are **recorded** (so they are never back-paid) and **credited** (so the day
the curriculum finally earns one, it pays the difference and not the face value).
A bit-per-level would have had to choose between paying twice and forgetting.

**(c) Back-pay opens no era.** Doc 03 §2.10 layer 5's relief allowance refreshes
on a city LEVEL (§AP4). Arrears settle rungs the city climbed in the past; the
eras those rungs opened were opened then. Paying a debt late is not a promotion,
`_settle_grant_arrears` never calls `note_era`, and the relief ladder is
untouched by the whole feature.

**And the migrator marks rather than answers** — v2 → v3's line, for v2 → v3's
two reasons (the answer needs `data/`, which doc 08 §2.8 forbids it to open, and
it needs a restored city that does not exist yet). The mark is the **section
version**, because what a legacy city was paid depends on which binary paid it.
Row `"9"` of `LEVEL_UP_GRANT_SUPERSEDED_BY_SAVE_VERSION` is deliberately the
element-wise MAXIMUM of the tables that could have written a v9 body, and is
labelled as such: crediting the larger is what makes double payment impossible
rather than unlikely, and the cost is published (at most $487,000 under-credited
on a $15,000,000 settlement).

### AW4. Four things this lane found and did not fix, all filed

**(a) A city's grid is never repaired, and gate 18b cannot see it** (doc 91
**A91-D-125**). Seed 4242 reads **20.98 % at the fork** — over gate 18b's own
ruled ceiling, five waves before this one — and the probe says why: 20 grid
components sitting FAILED and unrepaired for the last fifteen game-days, 82
buildings orphaned behind them, with the pool nowhere near short. On the richer
city the same shape is 105 failed and 234 orphaned. A FAILED component is
repaired only by doc 06 resolving its incident, and the failure rate scales with
the fleet the player buys. **This lane does not close it**: the fix is either a
grid-repair verb in the agent or a dispatch-capacity question, both of which are
somebody's whole lane, and fitting a bound around it here would bury it. What
this lane does is make it VISIBLE — `tools/probe_dark.gd` and the two new summary
columns — and say plainly that gate 18b asserts one seed and has been silent
about a 21-point reading on another.

**(b) The dark share is three failures wearing one number, and the gate asserts
the sum** (doc 91 **A91-D-126**). `unserved_share` cannot distinguish *no
transformer covers this tile* from *the pool is short* from *the feeder is
broken*, and a wave reading the sum will fix whichever of the three it happened
to guess. That is exactly what nearly happened here. Filed as Medium with the
instrument attached, because the instrument is the cheap half and splitting the
gate's assertion is the expensive one.

**(c) The tax slider stopped being a win, and the constant that made it one is
not this lane's** (doc 92 §63.9 **AC-24-5**). Gate 12c's tradeoff arm has
asserted for six waves that squeezing buys *something*; at this scale
`tax_squeezer` creates **4.04 % less** value than `balanced` where the fork
measured +39.6 %, and net of the identical curriculum money the gap is −9.7 %.
The cause is `tax.TAX_RATE_GROWTH_COEFF` = 8.0, fitted in Wave 2 against a city
whose growth was MONEY-limited. **This lane publishes it and does not re-fit
it**, because report 98 AC-2's rule is that a lane re-measures the row it moved
and does not hand-fit the curves that read it. What the arm asserts instead is
the thing that is still ruled: **a detent may stop being a win, but it may not
become a trap** — `TAX_SQUEEZE_VALUE_MIN_RATIO` 0.90 against a measured 0.9596.

**(d) A bound was lowered against a shape nobody has explained, and it is
written down rather than absorbed** (doc 92 §63.9 **AC-24-6**). Gate 33's
`DIRECTOR_LAST_START_FRACTION` moves 0.6 → 0.5, and the honest reason is that
the FORK passed 0.6 by 1.2 game-days on a statistic whose variance is 1.6
inter-event intervals. The underlying shape — 23–28 game-days of a 60-day run
with no new event, on both arms, with the threat pool full and nothing in flight
— is doc 07's cadence to answer and predates this wave. The assertion that
catches an actual stall (`started >= 8`, against a Wave-17 fork of 2) is
untouched and reads 18.

## AU. Wave-22 rulings — what a rung is allowed to be worth, and what the last one has to ask for (2026-09-04)

*The lane's whole brief is one sentence from the player, 2026-09-04, and the
sentence contains a number: "each level, since we have six, should give let's say
a few hundred thousand dollars … and then a SEVENTH level … you get the big money
… that'll be five million." §AU1 rules on what that does to a derivation this
project has kept since Wave 14; §AU2 on the rung it needs underneath it; §AU3 on
what the capstone level is allowed to ask for; §AU4 on the one thing this lane
found and deliberately did not fix.*

### AU1. An authored scale under a derived curve — and it is labelled, not laundered

**Q.** Doc 03 §2.5a's rule is *the city pays half of what the next chapter asks
you to buy*, applied row by row against doc 09 §2.14's curriculum. The player
wants figures fifty times larger than that rule produces. Do we re-derive the
rule so the new numbers fall out of it, or do we admit the numbers are authored?

**RULING: admit it, and then derive everything that CAN be derived.**

The rule is not broken and the fit is not wrong; the SCALE the rule is applied at
is a policy decision, and it is the player's to make. This project's standard is
that a placed number is labelled as placed — doc 92 §24.6's population rungs 4–7
say "honest extrapolation" on their face, and this is the same discipline one
step further out: the level of the curve is authored, the SHAPE of it is not.

What that buys is a table where every cell has a reason:

* **the bottom anchor is derived, twice, and the two agree to 3.5 %** — the
  remaining curriculum's whole purchase list at list price ($208,760) and the
  measured repair bill of a played curriculum ($216,467, `tools/measure_curriculum.gd
  --days=45`). $215,000 sits between them;
* **the top anchor of the six is the OLD RULE, kept verbatim** — half of what
  chapter 7 asks ($644,370 / 2 = $322,185 → $325,000);
* **the five rungs between them are the geometric run the two anchors imply**,
  ratio 1.08616, rounded to $5,000 and closing back on its own top anchor;
* **the capstone is authored and says so** — there is no chapter above it, so
  the half-rule has nothing to read, and doc 03 §2.5a refuses to invent one.
  What it publishes instead are three independent sanity checks on the figure.

**The alternative that was rejected: a FLAT run at the literal "few hundred
thousand each".** It was authored, measured, and it fails eight assertions across
seven balance gates — see §AU7. **A derivation that has to be bent to hit an
authored number is an authored number with extra steps**, and a scale that has to
be held past the point where the city can spend it is a number the game cannot
keep.

### AU2. A grant that is generous is bounded by its SHARE, not by a cap

**Q.** $5,890,000 across a curriculum is 43.6× what the game used to pay. What
stops it being a farm?

**RULING: the curve's own slope, and it is checked rather than asserted.**

Three things are true and all three are measured in doc 92 §61.3:

1. **The grant shrinks as a share of the city it lands on.** It rises 7.2×
   across the six while doc 09 §2.11's ladder rises 57.7× over the same five
   rungs, so against each band's own income the grant is worth 2.8 / 2.2 / 2.4 /
   1.2 / 0.44 chapters at rungs 1–5. It starts as three chapters of income and
   ends as half of one, with no guard written anywhere.
2. **One-shot per level per city is structural.** `city_level` is monotone by
   `data/progression.json`'s `city_level_monotone`, `grant_level` is its only
   writer and returns early on a level it holds, and `_pay_level_up_grant` walks
   `range(from + 1, to + 1)`. There is no re-crossing to exploit.
3. **Over a city's life it is capital, not revenue.** $5,890,000 is 35
   game-days of a level-7 city's own net, collected across an arc that takes
   15.7–17.9 game-days, and paying nothing after that forever.

**A cap was considered and refused.** A ceiling on the grant as a fraction of the
treasury would have made the grant smaller exactly when the player needed it — a
city at −$22,624 would be handed a fraction of nothing — which is the failure the
lane exists to fix.

### AU3. The capstone asks for the CITY, and the reward card is what makes it a goal

**Q.** Doc 09 §2.14.2's level 7 is "one of each type of building upgraded". Does
civic and utility stock count, and is one upgrade step enough of an ask for
$5,000,000?

**RULING: all twelve archetypes count, and the ask stays at one step per type —
what stops it being trivial is the GRANT below it, not a bigger ask.**

*All twelve*, because the roster is not a judgement call: `BuildController.cards()`
walks `sim.catalog.archetypes()` with no filter, so twelve is what the build
sheet offers; all twelve have a priced ladder in `data/building_economy.json`;
`cmd_upgrade_building` accepts all twelve. And doc 03 §2.12 has billed the player
for `departments` and `fleet` since game-hour 1 — a graduation that skipped the
station you have been paying for since founding would be teaching the wrong
lesson about what a city is.

*One step per type*, because the correct place to fix "the level is prepaid" is
the grant, not the level. Rung 6 pays **half** of the level's $644,370, which is
§2.5a's own rule and leaves the other half to be earned. The alternative — asking
for level 3 on every archetype ($1,828,516) — would have been a bigger number
that the player did not ask for, bolted on to make a grant safe that could simply
be halved instead.

*And the reward card had to change for the rung to be legal at all.* Ruling §G3
says **a level whose reward card is empty is a number, not a goal**, and nothing
in `data/buildings.json` unlocks at city level 7. The card now READS doc 03
§2.5a's grant as its first line, on every rung (doc 12 §2.19 D-96), so the money
is the unlock — and the same read backs D-95's toast, which means the promise and
the payment cannot drift apart.

### AU4. The wall at level 7 is UTILITIES, and that is the finding, not a defect

**Q.** Measured on the shipped grants, the capstone's twelve rows are refused
`E_POWER_HEADROOM` and `E_WATER_HEADROOM` on a city with a seven-figure treasury.
Is that a balance failure?

**RULING: no — it is doc 02 §8's `k_dem > TAX_LEVEL_GROWTH` arriving on schedule,
and level 7 already contains its own answer.**

Doc 02 §8's deliberate rule is that every upgrade is less utility-efficient than
the last. A city that has just been handed enough money to build without waiting
meets that rule sooner and harder, which is exactly what §61.4 measured. Two of
the twelve rows — `power_facility` and `water_facility` — ARE the answer, and the
building panel already tells the player what a headroom refusal wants.

What the lane changed is the AGENT, not the game: `tools/playtest.gd`'s
`curriculum` student now answers a headroom refusal with capacity, holds the open
checklist back from its growth ladder, and does both on a cooldown. **All three
changes were measured on the OLD grant table first** (doc 92 §61.4), so nothing
the student learned is credited to the money.

### AU5. Filed, not fixed — the relief ladder's extra era

`Treasury.note_era(to_level)` resets doc 03 §2.10 layer 5's allowance on the
transition that pays this grant, because §AP4 ruled that an era is a city level.
**A seventh rung is therefore one more era: three more relief grants (standard
preset) for the life of a city.**

That is published as a delta and not fixed here. It is bounded — +1 era, once, at
the top of the ladder, behind the hardest level in the game, monotone and
therefore unfarmable — and the ladder it touches belongs to Wave 21's no-spiral
lane, running beside this one. Doc 92 §61.7 carries the row.

### AU6. The grant is paid for the LESSON, not for the level — §G1 amended, narrowly

**Q.** Doc 93 §G1 composes the two routes up doc 09 §2.11's ladder with `max()`,
and doc 03 §2.5a has always paid its celebration grant on that composed level, so
that *"neither route to a rung is worth more than the other."* At $2,500 a rung
that was uncontroversial. At this wave's scale it hands every scripted agent in doc 92's
balance matrix — none of which can read a goals sheet — the curriculum's money.
Is the composition wrong, or is the payment site wrong?

**RULING: the composition is right and the PAYMENT SITE is wrong. §G1 is
untouched; doc 03 §2.5a's grant moves to `city_level_objectives_met`.**

**The distinction §G1 was making, restated.** A LEVEL is a *permission* — what
you may build, what land you may buy, how far a building may be upgraded, how
many relief grants an era allows. A permission must not depend on how you got
there, or the game is quietly telling a player who plays well without the sheet
that they played wrong. That argument is sound and this ruling does not touch it:
`city_level` is still `max(population_ladder, objectives_earned)`, and
`Treasury.note_era` still fires on the composed transition for exactly the same
reason (§AP4's era is a permission to ask for help).

**A celebration grant is not a permission.** It is payment for a lesson
completed, and the population backstop completes no lessons — it is a threshold
that arrives while you play. Reading §G1's sentence onto the grant was a category
error that cost nothing while the number was small.

**And the cost, once the number is not small, is measured** (doc 92 §61.12). On
the flat first draft of the table, paying on the composed level fails **eight
assertions across seven balance gates**, on agents that have never touched a
curriculum objective — including gate 18b's *a city may not outrun its own
power*, at **32.59 %** of building-time dark against a ruled 20 %. Moving the
payment to the curriculum's own transition removes three of the eight on its own,
and — more importantly — it removes them for a REASON rather than by making the
number smaller. §AU7 is what dealt with the other five.

The clean statement of what this ruling buys: **`tests/fixtures/bench_city.json`
was collecting $135,000 of celebration grants on boot**, for a curriculum it has
never touched, and both of its `profile_sim` digests moved when it stopped (doc
92 §61.13). A profiling fixture being paid the curriculum's money is the defect
in one sentence.

**What a player who ignores the sheet still gets is the LEVEL**: every unlock,
every ring of land, every upgrade tier, every relief era, exactly as before. What
they do not get is the money for a lesson they did not take. The sheet is one
chip away on the top bar, the chip names the rung and the fraction, and doc 12
§2.19's reward card now prints the figure they are declining.

**Two properties the move had to preserve, and both do.**

1. **A rung is still paid exactly once per city.** `GoalSystem.earned_level` is
   monotone, `done` is sticky, and `_settle` emits exactly one
   `city_level_objectives_met` per rung it promotes through.
2. **A restore pays nothing.** `bootstrap` completes every level at or below the
   city's own and then *drains its own event queue* (doc 09 §2.14.4 point 3) —
   which is what stops a migrated level-6 city being handed the whole table
   ($890,000) for work it did last week. That drain was written for a different reason (four
   level-up toasts on a returning player) and it turns out to have been load
   bearing for this one too.

**The alternative that was rejected: re-fit the seven gates.** It is the more
obvious reading of "publish the measured consequences", and it is wrong here for
two reasons. The gates are not noise — 32.59 % dark is a worse game, not a
different one. And re-fitting them would have written the category error into
seven more places, so that the next wave to look at the matrix would find a
balance built around scripted agents being paid for a curriculum they cannot
read.

### AU7. The scale is bounded by the grid, not by the request — and this is where the curve came from

**Q.** §AU6 moves the payment to the curriculum's own transition, and three of
the eight failing assertions go with it. Five remain, because `balanced`
*completes levels 1 and 2's objectives incidentally* — two shops, one upgrade,
four houses, a transformer and 210 residents is what a competent builder does
anyway — so a non-curriculum agent still collects rungs 1 and 2. On the flat
draft that is **$450,000 by game-day 4**. Do we re-fit the five, or re-shape the
curve?

**RULING: re-shape the curve, and let gate 18b set the scale.**

The brief this lane was given says *the money must not break the game it is meant
to open up*, and *if a grant trivialises a lesson, re-shape the curve, not the
lesson*. Gate 18b is the assertion that says a city has to be able to power what
it builds; its own docstring says the 20 % ruling has *"better than 3× of margin,
deliberately: the point of the gate is to catch the ceiling COMING BACK, not to
ratchet a measurement into a target."* The flat draft brings it back four times
over — 26.44 % after §AU6's move, against a fork baseline of 6.25 %.

**So the curve is set where that measurement does not move.** With rungs 1 + 2 at
$110,000 instead of $450,000 the dark share is **5.99 %**, and every other moved
reading returns inside its bound (doc 92 §61.12 has the five-row table). The
shipped curve is 43.6× the old table rather than the ~55× the request read as,
and the difference is not caution — it is the point at which the city stops being
able to spend what it is given.

**One gate is re-fitted and it is the pacing one.** Gate 20's level-2 window
moves 8–14 → 3–14, measured 6 / 4 / 7. Its floor existed so that *"an unlock has
to be EARNED to read as progression"*; at game-day 4–7 on a 24-minute game-day it
still is, and what it is no longer is a week's wait. A window's floor is a pacing
decision and pacing is what this wave deliberately changed; a ceiling on a city's
dark share is not, and that one was not touched.

**What the player is told, plainly.** They asked for "a few hundred thousand"
per level and the six run $45,000 → $325,000. The honest sentence is not that the
request was too big but that it was measured: at the flat figure the default city
spends a quarter of its building-time unlit and one curriculum seed cannot finish
the capstone, and *money is not the only thing a city needs in order to build*.
The thing they actually asked for — that levelling up stops being a wait and that
the negative balance goes away — holds at every rung: the smallest grant is 2.0×
their hole and the six together are twice a whole curriculum's repair bill.

## AR. Wave-20 rulings — the spiral has a floor: what a city is billed for after it falls, what an unanswerable fire may take, and the one building wear may never have (2026-09-03)

*(Measured in doc 92 §58. Shipped as report 98 §61, RR-174..RR-178. The defect
rows are doc 91 A91-D-110, A91-D-111 and A91-D-112.)*

Wave 19 §AP1 ruled that wear may condemn a private building but never demolish
one, and shipped. **This wave loaded the player's actual save file and advanced
it**, which nothing in this project had ever done: every catastrophe measurement
before it — `probe_neglect.gd`, `measure_catastrophe.gd`, the whole of doc 92
§56 — was taken on a city this repository generated. `tools/measure_player_city.gd`
takes slot 0 through the real `SaveService`, the real ladder, the real
seven-check gate, and advances it on the real coarse path.

On the Wave-19 tree, the player's city — game-day 166, treasury −$22,624,
**twelve** buildings standing against seventy-seven ruins — went to **zero
buildings and population zero in forty-five game-days**, and the last power plant
went with it. §AP1 was not wrong; it had closed a door this city was not walking
through. Doc 92 §58 names the three it was:

| door | share of the fourteen-day loss | ruling |
| --- | --- | --- |
| the city is billed for its own rubble, at the **worst** rate either line can charge | $32,409/game-day against a $2,998/game-day gross | **§AR3** |
| a fire in a city with no fire station | **10 of 11** destructions | ~~§AR2~~ — **rejected at merge; replaced by §AS1** |
| wear on the generation and water spine | §AP1's own listed exception | **§AR1** |

**And a fourth finding that is not a ruling but a correction.** The lane brief
recorded that relief paid this city **$2,624 across fourteen game-days**. It did
not. That $2,624 is `Treasury.settle`'s credit-limit clamp — the balance moving
from −$22,624 to exactly −`CREDIT_LIMIT_FLOOR`, with the $2,624 overshoot booked
as deferred liability — and it is the *opposite* of a payment. Relief actually
paid **$296,181 in three grants inside fifteen game-days**, which is **105 % of
the city's entire $282,078 restore bill**. *(Wave 21 re-measured this on the
branch's own final tree and it reproduces at a slightly different pair —
**$306,233 in three grants against a $296,438 bill, 1.033×** — because the bill
moves as the city keeps falling. The finding is the ratio, it survived
re-measurement, and doc 93 §AS4 closes it: 3 × 0.35 = 1.05 was always going to
cross 1.)* Doc 03 §2.10's bottom rung was not too
thin. The hole under it was too big, and §AR3 is the hole. **No number in the
relief ladder is moved by this wave**, and that is a finding, not an omission:
fitting a grant to a symptom before the symptom's cause was found is exactly how
a balance number stops meaning what its note says.

### AR1. Wear may CONDEMN the utility spine. It may not demolish it.

`data/building_rules.json utility_spine.archetypes = ["power_facility",
"substation", "water_facility"]`, `utility_spine.wear_may_demolish = false`;
`BuildingCatalog.wear_may_demolish_for(archetype)` folds this with §AP1's
private-stock answer into the ONE flag `Building.wear_may_demolish`, stamped at
doc 93 §Y2's same four sites; `Building.roll_structural_failure`'s guard loses
its `owner_maintained and` conjunct and reads the flag alone.

**§AP1's own text is the argument.** It ruled that an owner whose building is
condemned boards it up rather than bulldozing it, *because it is their asset* —
and then listed, as a deliberate exception, "this same roll on the city's OWN
civic and utility stock". The city is the owner of a power plant. The sentence
applies with more force, not less, because of what the exception costs:

* a demolished power plant takes **the whole city's** power with it, not one
  lot's revenue;
* with no generation, every remaining building is dark, so §Y1a's service clause
  lifts the ownership floor **city-wide** and §AP1's protection of private stock
  stops meaning anything;
* and the player cannot buy it back, because the same collapse has the treasury
  under water. A loss you cannot recover from is not a difficulty setting.

On the player's save all of that had already happened: both plants gone, all
three water facilities gone, both substations gone, and the twelve survivors
sitting in permanent darkness.

**THE LINE IS THE SPINE, NOT ALL CIVIC STOCK, and that is the ruling rather than
a convenience.** Police, fire and the construction yard stay losable to wear.
Losing a station costs coverage — a loss the player can see on the overlay, price
from the build menu and rebuild out of. Losing the last plant costs everything at
once and is unrecoverable while insolvent. Generation, distribution and water are
exactly the three a city can neither function without nor rebuy while broke; the
`utility_spine` block names them, `BuildingCatalog._check_utility_spine` refuses a
block that names an archetype which does not exist, and a fixture carrying no
block keeps the pre-Wave-20 physics exactly.

**What a condemned plant is.** It rests at `structural_failure_threshold` in
`damaged`, where doc 02 §2.12 pays `output_mult` **0.40**. So a neglected city
browns out to two fifths of its generation; it never goes dark for good. The
player's repair is a real purchase at doc 03's own price, and it is theirs to
make.

**NOT A SHIELD, for the spine either.** An unanswered tier-5 fire in a city that
CAN answer (`burn_down`), doc 06's explicit `destroy_building` cascade op in a
city that can answer, an event landing on a building already at the threshold
(§AP2), and the player's own demolish all still take a power plant down. A
disaster still matters.

### AR2. An incident the city could not answer CONDEMNS. It does not demolish.

`Building.condemn_unanswered(destroy_allowed)`;
`Building.apply_damage(fraction, now_minutes, may_destroy)`;
`IncidentSystem.incident_was_answerable(inc)`;
`CityIncidentWorld._has_fire_department()`. Doc 06's two building-destroying
verbs take an `answerable` argument that defaults to `true`, so every adapter and
caller that predates the ruling behaves exactly as it did.

With no fire station standing, the player's city could answer nothing: **431
incidents abandoned, 17 failed and 11 buildings burned down in fourteen
game-days**, ten of the eleven through `burn_down`. There is no move that fixes
that. The station is a ruin, restoring it costs money the collapse has already
taken, and every fire deletes another building — an unbounded ratchet driven by
the absence of a purchase the player cannot make.

**"Could not answer" is THREE facts the game already records, and none of them
is a choice the player made** (`CityIncidentWorld._could_have_answered`):

* `IncidentSystem.incident_was_answerable` — **nothing is committed** to the
  incident AND `DispatchSystem` marked it `unreachable`, i.e. it had candidate
  units, had permission to send them, and doc 10's road graph offered no route.
  `dispatch_blocked_no_units` is deliberately NOT in this bucket: a city with a
  department and no free engine made a fleet-sizing choice, and doc 06 §2.16's
  whole dispatch economy rests on that choice having consequences.
* **no fire station standing at all.** A city-level fact and deliberately not a
  per-tile coverage reading: gating on `coverage_fire(tile)` would make "build
  far from the station" a fireproofing strategy, which is the farm this ruling
  must not open.
* **AND `Treasury.austerity_active`.** Doc 03 §2.10 layer 2 lists `construction`
  in `AUSTERITY_BLOCKED_CATEGORIES`, so under austerity the game itself REFUSES
  to let the player build a fire station or repair the road that would have
  carried the engine. Above austerity it refuses neither.

**The third clause is gate 29's, and gate 29 was right.** The first draft asked
only the first two, and the shipped suite answered with a number: `do_nothing` on
`standard` stopped going insolvent until game-day 165 and on `casual` never went
insolvent inside 210 game-days at all. The reason is that a `do_nothing` city
lets its own fire station rot — and the moment wear took the last one, the draft
handed that city, sitting on a peak balance of **$397,081**, the same protection
this ruling was written for a player whose station a catastrophe took while the
treasury was $22,624 under water. Those are not the same situation, and the
difference is not the roster: it is whether the player had the option. Austerity
is not a proxy for "could not afford it" — it is doc 03 refusing the purchase,
which is exactly the thing §AR2 must not punish. (It turned out to cost gate 29
nothing either way — doc 92 §58.7 attributes the entire gate-29 delta to §AR3 —
but a ruling that is only right by accident is not right.)

**Both doors, or the ruling buys one game-hour.** §AP2's damage floor is
conditional — `if condition > floor_condition` — so a building already at the
line is finished by the next event. That is fair when the city could have
answered the first one. §AR2 puts unanswered incidents' targets exactly at that
line, so without `may_destroy` the condemn would hand them straight to the next
hazard: doc 92 §58.5 measured that arm and the player's save still lost 12 of 12,
with `cause: damage` in place of the `cause: fire` it used to lose. Where the
city CAN answer, §AP2 is untouched.

**THE ANTI-FARM IS AN INEQUALITY, NOT A FEE.** Demolishing your own fire station
to buy this does not pay: every fire still condemns the building it reaches (doc
02 §2.12 — `output_mult` 0.40, `coverage_mult` 0.25, doc 03's `f_condition` 0.46,
so the building keeps paying about a fifth of its tax), the city loses fire
coverage everywhere at once (doc 02's `req_fire_coverage` gates upgrades, doc 09's
happiness reads it), and nothing the fire fleet answers gets answered. A
station's upkeep buys SUPPRESSION — an answered fire leaves residual damage and
the building goes on earning — which is worth more than the difference between a
condemned building and a ruin at every level in the catalogue. **A mutual-aid fee
was considered and rejected**: a bill an insolvent city cannot pay becomes
deferred liability, which is the unbounded ratchet this ruling exists to end
wearing a different hat.

**It stays possible to lose a building to fire.** A city with a department that
can reach the fire and loses it anyway still loses the building, through the
`burn_down` this ruling does not touch. `tests/test_spiral_floor.gd` asserts both
sides of that line.

**One branch still demolishes, and it is not an exception so much as a fact about
what is there.** A NEW BUILD — `is_new_build()`, `under_construction` at level 0 —
has no standing structure to board up, and putting a level-0 site in `damaged`
would strand it: it is no longer `under_construction`, so
`complete_construction` can never run, and `damaged` at level 0 is a state doc 02
§2.12's table does not describe. The city loses the site, exactly as it did before
the ruling. An UPGRADE in flight is a real building at a real level and IS
condemned, falling back to the level it already had — `cancel_upgrade`'s own rule.

### AR2a. A building the city loses is a building the city is TOLD about.

`CityIncidentWorld._publish`. Every `Building` verb returns the events its
transition produced and `CitySim.apply_hourly_decay` publishes them;
`CityIncidentWorld.apply_building_damage` and `destroy_building` called the same
verbs and **threw the return away**. So a building taken down by a doc 06 cascade
op emitted nothing at all: no `building_destroyed`, no `building_damaged`, no
notification, nothing for `GoalSystem` — which lists `building_destroyed` among
the events it watches — and nothing a report could count.

Measured on slot 0: over 45 game-days the census showed twelve buildings gone and
the bus reported **one**. The player's city was being erased through a door that
never announced itself, which is why the report reads *"ALL of my buildings are
destroyed"* and not *"I watched them go"*. Doc 91 A91-D-110.

The publish stamps `sim_id` and the post-transition `condition` exactly as
`apply_hourly_decay` does, which also fixes the join: `Building._destroy` puts
the **int** `Building.id` in the `building` field, while every roster key is the
authored **string** sim_id (`P-077`, `H-001`). A subscriber that joined on
`building` would have attributed nothing.

### AR3. The city is not billed for its rubble.

`CitySim.build_settlement_inputs` skips `state == &"destroyed"`;
`CityIncidentWorld.station_rows` skips destroyed and planned shells.

`roster_ids()` keeps a ruin in the roster — that is what makes RESTORE possible —
and every row that loop appended was billed. Doc 03 §2.4's `E_building_maint`
charges the `buildings` array and `E_departments` charges the `stations` array,
and **neither line ever asked what state the building was in**. Worse, both scale
on `1 − condition`, and a ruin's condition is exactly 0:

```
E_building_maint  x (1 + MAINT_CONDITION_PENALTY x 1)      = 2.5x
E_departments     x (1 + ASSET_CONDITION_PENALTY_COEFF x 1) = 3.0x
```

**A destroyed building was billed two and a half times what the same building
costs in perfect repair, and a destroyed station three times.** Every building
that died made the city's bill go up. That is a ratchet with no floor, and it is
the death spiral's actual engine. On the player's slot 0, at load (doc 92 §58.2):

| line | billed to RUINS | of total |
| --- | --- | --- |
| `E_building_maint` | **$1,044.39/gh** | $1,055.12/gh (**99.0 %**) |
| `E_departments` | **$306.00/gh** | $306.00/gh (**100 %**, four ruined shells) |
| both | **$1,350.39/gh = $32,409/game-day** | against a gross of $2,998/game-day |

**The ruling is doc 93 §Y1's own sentence, read on the other side.** §Y1 kept
`E_building_maint` alive by defining it as *the city's cost of SERVING a
building* rather than a landlord's repair bill. A ruin is served by nothing: it
draws no power, no water, houses nobody (`state_occupancy()` is 0.0 for
`destroyed`, so it already contributes $0 of tax and $0 of `potential`, and doc 03
§2.10 layer 1's revenue floor is measured on `potential`) and generates no
traffic. `station_upkeep` is STAFFING, and a destroyed station has no staff.
`station_rows()` is `FleetSystem.populate_from_stations`'s only source, so a
ruined station listed there also gave doc 06 a garage that does not exist and doc
03 an `E_fleet` line to bill for it.

**The fleet half is closed for the BOOT path only, and the remainder is
recorded rather than claimed.** `populate_from_stations` runs once, before any
restore; `FleetSystem.deserialize` then clears the roster and rebuilds it from
the save, and `sync_station` fires on a building's COMPLETION and never on its
destruction. So a station destroyed while the city runs keeps its engines, and
the player's slot 0 still pays `E_fleet` $91.58/gh against four ruined shells
after 45 game-days. Retiring a unit on destruction means retiring one that may be
dispatched, en route or on scene — doc 06's ladder, not this guard's. Doc 91
A91-D-111 carries it as that row's open remainder.

**What still costs money, so that losing a building still hurts.** The lot is
dead capital until it is restored: no tax, no coverage, no power, no water, and
`CostCurves.restore_cost_building` to bring it back. `E_roads_repair` still bills
the street outside it, because the street is still there. The city loses the whole
of the asset's income and keeps the whole of its restore bill; it simply stops
paying wages to a building that burned down.

**Nothing here is a balance knob.** Not one authored number moves in §AR1, §AR2 or
§AR3 — the two condition penalties, the structural-failure probability, the
relief ladder and every price stand exactly as Wave 19 shipped them. All four
`profile_sim` determinism baselines are **unchanged on both cities and both
paths**, which is the strongest available statement of what these rulings are:
dormant on a healthy city, and a floor only under one that has fallen.

### AR4. What is NOT ruled, and why

**The relief allowance still cannot re-open for a city that cannot grow.**
`Treasury.note_era` makes an era a city level (§AP4) and `ProgressionSystem.city_level`
is monotone by construction, so a collapsed city spends its three grants and never
gets another. On slot 0 that is visible from game-day 15 onward. It is not closed
here because the honest fix is a latch — one persisted "this collapse has already
been counted" bit — and `Treasury.serialize()` is inside `state_hash()`, so it
moves all four baselines. This wave's baselines are unchanged, which is the single
most useful fact it can hand the next reader, and spending that on a bit is a bad
trade when §AR3 has just made the same three grants sufficient.

> **RE-MEASURED, WAVE 21, AND THE CLAIM DOES NOT SURVIVE.** This paragraph ended
> "the same relief now leaves the city at **+$68,464 on game-day 14** with every
> building it still had". That number was taken before this branch's own last
> checkpoint and never re-taken. On the rejected Wave-20 tree it re-measures at
> **+$57,032 on game-day 14 with SIX of the twelve buildings**, not twelve — the
> other six burned between game-day 5 and 15, in the window where the first
> relief grant had lifted austerity and turned §AR2's protection off. On the
> Wave-21 tree, with §AS1 and §AS4 in, it is **−$26,832 on game-day 14 with all
> twelve buildings still standing** (doc 92 §60.9). Relief is smaller because
> §AS4 stopped it out-paying the bill, and the roster survives because §AS1
> stopped reading the treasury. "The three grants are sufficient" was not
> established, and it is withdrawn. Doc 91 A91-D-112 keeps the row, the shape of
> the fix and the cost.

## AS. Wave-21 rulings — a fire nobody could answer, and what it may take (2026-09-04)

*(Measured in doc 92 §60. Shipped as report 98 §63, RR-182..RR-186. The defect
rows are doc 91 A91-D-115, A91-D-116 and A91-D-117. This section **replaces
§AR2**, which was rejected at merge; §AR1 and §AR3 stand unchanged and this wave
keeps both.)*

Wave 20 §AR2 ruled that a fire a city could not answer should CONDEMN the
building rather than destroy it, and gated that on
`Treasury.austerity_active` — *"could the player have BOUGHT a fire station?"*.
The ruling is right. The gate was wrong, and two independent refutations say so
with numbers rather than with taste (doc 92 §60.2):

* **(a) It switches itself off.** Austerity lifts the moment the recovery
  ladder works. On the player's own slot 0 the first two relief grants took the
  treasury positive by game-day 11, austerity cleared, and the protection ended
  — after which six more buildings burned in three game-days. A protection that
  ends when the ladder succeeds protects nothing.
* **(b) Held the other way it is a strategy.** Kept under the austerity line
  with no fire station, the same save returns **76 buildings alive at game-day
  45 and the identical 76 at game-day 90 — zero destructions in 45 consecutive
  game-days**. Total fire immunity, bought by staying broke. The correct play
  becomes never recovering.

A rule that is strongest when you are worst-run inverts the game. §AS1 replaces
the gate with the only fact a fire chief would ask about, and it is not money.

**And §AR2 had no floor.** Doc 06's own saturation note records that fire is
self-limiting *because* it takes buildings off the board. §AR2 stopped it doing
that and put nothing in its place, so on the merged tree the same save produced
**7,379 incidents in 45 game-days on a 76-building city** — doc 06 §2.10.1's own
worst legitimate arrival rate is 26 a game-day — with 3,919 failing, each failure
spawning a `blocked_road`, and 72,195 `dispatch_blocked_unreachable` behind the
roads that made. §AS2 is the missing floor.

| door | what Wave 20 shipped | ruling |
| --- | --- | --- |
| what makes a fire unanswerable | the treasury | **§AS1** — the roster and the fleet |
| what stops the chain | nothing | **§AS2** — a gutted shell is not fuel |
| what the bus says about it | 279,071 blocked-dispatch events, and a destruction event for buildings still standing | **§AS3** |
| what an era of relief may pay | 3 × 0.35 = 1.05× the bill | **§AS4** |

### AS1. A fire the city has no CAPABILITY to answer condemns. It does not destroy.

`CityIncidentWorld._could_have_answered(answerable)` is now
`has_fire_capability() and answerable`, and it reads no money anywhere.
`has_fire_capability()` is the conjunction of two facts the game already holds:

* **a `fire_station` STANDING** — `active`, `damaged` or `repairing`. Doc 02
  §2.12 still gives a damaged station `coverage_mult` 0.25, so it is a
  department, just a poor one. `destroyed`, `planned` and `under_construction`
  are not standing: a station that has not opened cannot roll an engine.
* **an engine to roll** — at least one `FleetSystem` unit whose `resolve_rate`
  answers the `fire` role. §AR3 measured why this half cannot be inferred from
  the first: `populate_from_stations` runs once at boot,
  `FleetSystem.deserialize` rebuilds from the save, and `sync_station` fires on
  a building's completion and never on its destruction — so a city can hold
  engines whose garage is rubble, and a city can hold a station doc 06 never
  housed.

`answerable` is unchanged: `IncidentSystem.incident_was_answerable` — something
was committed, or the dispatcher never marked the incident `unreachable`.

**What still burns down, and why that is fair.** A city that owns a fire service
loses buildings to fire exactly as it always did. Concretely: a station stands,
engines exist, the fire is reachable, and either an engine was committed and lost
the fight, or every engine was already out — `dispatch_blocked_no_units`, which
doc 06 deliberately reads as ANSWERABLE, because fleet size is a purchase the
player makes. Station siting, station upkeep, fleet size and response time are
all still choices with teeth. What no longer happens is a city being deleted for
declining to buy a service it had no service to buy it with.

**The anti-farm is an inequality, not a fee.** Demolishing your own fire station
to buy the exemption loses money at every level in the catalogue, because a
station's upkeep buys SUPPRESSION and suppression is strictly better than
condemnation: an answered fire leaves residual damage and the building goes on
earning at near-full output; an unanswered one leaves a fifth of a building AND a
gutted shell that must be paid for before it earns again. On top of that the city
loses fire coverage everywhere at once (doc 02's `req_fire_coverage` gates
upgrades, doc 09's happiness reads it) and every other incident the fire fleet
answers stops being answered too. Doc 92 §60.5 measures the inequality.

**Mutual aid was weighed and rejected, with a number.** The alternative shape —
no station of your own, so you pay outside crews under C-07 — bills a city that
by construction has no money. Doc 03 §2.10 layer 4 turns an unpayable bill into
`deferred_liability`, and doc 92 §60.6 measures where that ends on this very
save: **$1,257,604 of deferred liability by game-day 90 and still climbing about
$10k a game-day**, against a treasury pinned at the −$20,000 credit floor. A fee
an insolvent city cannot pay is the unbounded ratchet this ruling exists to end,
wearing a different hat. §AS2's repair bill is the honest version of the same
idea: the player CHOOSES when to spend, and nothing is ever charged to a city
that cannot pay it.

### AS2. A gutted shell is not fuel — the bound

`Building.burnt_out`, set by `condemn_unanswered` and by nothing else, read by
`Building.state_fire_mult`, by `IncidentWorld.state_fire_mult_of` (doc 06 §2.8's
spread screen) and by `IncidentSystem._structure_fire_rates` (doc 06 §2.6's
ignition roll, through a seventh `fire_candidate_columns` column). While it is
set, the building is not a fire candidate and not a spread target: an unanswered
fire has already taken everything in it that could burn.

**Without it §AS1 has no floor, and the floor is not optional.** A condemned
building comes to rest in `damaged` at 0.10, where `state_fire_mult` is **1.8**
and `fire_condition_mult(0.10)` is **2.28** — 4.1 times a healthy building's
ignition rate. A shell that survives its own burn-down is the most flammable
object in the city, forever. Doc 92 §60.3 and §60.7 measure both halves of the
loop that makes.

**An owner boards a gutted shell up; they do not rebuild it out of petty cash.**
`Building._owner_maintain` HOLDS a burnt-out shell at doc 02 §2.6's
structural-failure line — it does not rot away, and it goes on paying §2.12's
`output_mult` 0.40 and doc 03's `f_condition` floor, about a fifth of a building
— and does no more. This is §AP1's own sentence read to its end. Without it the
bound is a two-game-hour delay: `_owner_maintain`'s rate takes ordinary private
stock from 0.10 back over `repair_target_damaged` in about two game-hours, the
flip to `active` lifted the flag, and doc 92 §60.7 measured the result —
**14,071 unanswerable fires in ninety game-days on a 68-building city**, one per
powered building every 2.4 game-hours. With the hold it is **65**.

§Y1a's service clause is untouched and is deliberately not restated: a DARK shell
falls exactly as any other dark private building falls, because a building nobody
is serving is §Y1a's ruling and not this one's.

**The exit is a bill the player chooses.** `CitySim.cmd_repair_building`'s
`E_OWNER_MAINTAINED` blocker now has exactly one exception — a gutted shell — so
the city may buy the rebuild of private stock an unanswered fire has taken, at
doc 03 §2.5's own repair price and through the same construction queue as any
other repair. `Building.complete_repair` lifts the flag, and so do
`complete_construction` (a restore) and `_destroy` (there is no shell left).
Routine owner upkeep does not. **Three verbs lift it and all three are somebody
paying.**

**Not a farm, in one line:** an un-burnable building is one earning 40 % of its
output and the tax floor, and the moment the player pays to make it earn again it
burns like anything else. Nobody chooses to be gutted.

**The key is sparse.** `Building.serialize()` writes `burnt_out` only when true,
because it is captured into `state_hash()` and an unconditional key would move
every determinism baseline on every city for a flag no city without a gutted
shell has ever set.

### AS3. An event storm is its own defect

Two lines on the bus were lying about the city, in opposite ways.

**(a) 279,071 blocked-dispatch events in 45 game-days.**
`DispatchSystem._emit_blocked` kept ONE de-dup slot holding
`"<event>:<role>"` and suppressed only an exact repeat. An incident whose `fire`
need is blocked for one reason and whose `police` need is blocked for another
overwrites that slot on every need, on every integrator sub-step, and announces
both forever. Measured on slot 0: **279,071 `dispatch_blocked_unreachable` in 45
game-days** on the merged tree, re-measured on this branch's fork at 255,050 over
the same 45 and **466,321 over 90** — 236 a game-hour on a city with twelve
buildings.
`CitySim` republishes every one of them on the shared bus, so every subscriber in
the game paid for it. The slot is now a SET of the reasons this incident has
already announced, cleared where it always was — the moment something is finally
assigned. A reason that CHANGES is still announced, because it is a different
sentence about a different problem, and it is still announced once.

**(b) `building_destroyed_by_fire` for buildings that were still standing.**
`CascadeOps._destroy_building` announced a destruction whatever the terminal op
actually did, and under §AS1 it often condemns. Measured on slot 0: **3,891 such
events in 45 game-days about buildings the census still shows alive.**
`IncidentWorld.destroy_building` now returns whether it destroyed, and the op
emits `building_condemned_by_fire` when it did not. `GoalSystem`, the
notification feed and every balance instrument read this line; a terminal event
that lies about the roster is worse than no event at all.

**(c) The matrix could not see the call.** `tests/test_event_matrix.gd` exists to
assert that every event `sim/` emits is consumed or classified and every router
row names an event `sim/` emits — and it scans for `bus.emit(` and `_emit(`
only. Doc 06's `CascadeOps` publishes through `IncidentSystem.emit_event`, whose
own body calls `_emit(type, …)` with a VARIABLE, so **five call sites and four
event types were invisible to it**: `incident_notify`,
`destroy_refused_offline`, `power_component_destroyed`, and
`building_destroyed_by_fire` itself. That is why (b) could stand for a wave — no
router had ever named that event either, so neither side of the matrix was
looking. The pattern gains `emit_event(`, the three bookkeeping types carry
written classifications, and **both** of a fire's endings become
`data/ui.json.event_log` rows: the harsher one had never been on the feed at
all. 168 types emitted / 98 consumed / 70 classified, against 163 / 96 / 67.

### AS4. An era of relief may not out-pay the bill it is measured against

§AP4 authored `RELIEF_DAMAGE_FRACTION` at 0.35 with the argument *"0.35 < 1, so
the grant never covers the restore bill it is measured against"*. Read per GRANT
that is sound. Read per ERA it is false: `relief_grants_per_era` is 3 on
standard, and 3 × 0.35 = **1.05**. Doc 92 §60.4 measures the city collecting
**$306,233 against a $296,438 restore bill — 1.033×** on the shipped build, and
$618,010 across two eras. The one inequality the ruling rests on was not true.

`Treasury.relief_era_paid` — dollars, persisted, reset by `note_era` with the
allowance it belongs to — makes each grant see what the era already paid:

```
damage_term = max(0, RELIEF_DAMAGE_FRACTION × outstanding_restore_cost
                     − relief_era_paid)
```

so however many grants an era holds, the damage side sums to at most
`RELIEF_DAMAGE_FRACTION × (the largest bill any of them was measured against)`,
which is strictly below the bill. **No new constant**: the cap is the fraction
that was already there, applied to the era instead of to the grant.

**The revenue term is deliberately outside the cap.** `1.5 × daily gross` is the
pre-Wave-19 ladder, it is measured on what the city EARNS rather than on what it
lost, and it is what carries a city whose ruins are already restored. Netting it
against past grants would mean a city that used its relief well gets nothing the
next time it is in trouble, which is the opposite of the ladder's purpose. It
stays bounded by the insolvency pair, `RELIEF_COOLDOWN_HOURS`,
`relief_grants_per_era` and `RELIEF_MAX`. `RELIEF_MIN` also stays outside the
cap: it is the floor doc 03 §2.10 layer 5 guarantees every grant, and a city with
nothing left to measure still gets the bottom rung.

### AS5. What is NOT ruled, and why

**The engines of a destroyed station are still billed.** §AR3 closed the BOOT
path and recorded the remainder; this wave re-measured it rather than closing it.
On the final tree the player's slot 0 pays `E_fleet` **$91.58/gh — $2,198 a
game-day — with no station of any kind standing** at game-day 45 and again at 90.
It is not closed here because retiring a unit means retiring one that may be
dispatched, en route or on scene, which is doc 06's dispatch ladder and not a
billing guard; and because $2,198 a game-day is 14 % of that city's $16,012
game-day expense, so it changes no verdict in this lane. Doc 91 A91-D-111 keeps
the row and A91-D-115 carries the re-measurement.

**Relief still cannot re-open for a city that cannot grow** (§AR4, doc 91
A91-D-112). Unchanged, and now with a cost attached: on the final tree the
player's save spends all three grants by game-day 15 and takes nothing for the
next seventy-five game-days. §AS4 makes each era's relief smaller, which makes
that row more valuable, not less — but a collapse latch is a persisted bit and it
belongs in the one `Treasury` schema commit doc 91 A91-D-108 and A91-D-112 have
both been waiting for.

**A collapsed city's incident generators are not re-fitted.** With the roster
saved rather than deleted, slot 0 runs at doc 06's saturation ceiling
continuously: **28,573 incidents born in ninety game-days**, essentially all of
them abandoned unanswered, because the city has no police station, no fire
station and no construction yard. The roster is BOUNDED — doc 06 §2.13's
`saturation_ceiling` 40 is doing its job — so this is throughput, not a ratchet.
But the loop behind it is real: every abandoned incident costs district
stability, and `f_arson` is `1 + 2.0 × max(0, 0.35 − stability)/0.35`, so a city
that cannot answer anything triples its own ignition rate and keeps it there.
That is a doc 06 / doc 09 re-fit with its own derivation and its own gate, and
doc 91 A91-D-117 carries it.

## AV. Wave-23 rulings — the predicate measured the shell, not the service (2026-09-04)

*(Measured in doc 92 §62. Shipped as report 98 §65, RR-192..RR-196. The defect
rows are doc 91 A91-D-121, A91-D-122 and A91-D-123. This section **corrects
§AS1** on one word and **keeps everything §AS1 bought**: the acceptance test's
passive arm is unchanged at 12/12/12 with zero destructions of any cause, and the
Restore-All arm improves.)*

Wave 21 ruled that a fire a city could not answer CONDEMNS the building rather
than destroying it, and the ruling is right — it is the reason the player's own
save stops at twelve buildings instead of zero. What it got wrong is what "could
not answer" was allowed to mean. `has_fire_capability()` asked whether a
`fire_station` BUILDING was standing, and **the ability to answer a fire does not
live in a building.** It lives in `FleetSystem`, and §AR3's own finding is that
the engines outlive the shell on every destruction path there is:
`sync_station` fires on a building's COMPLETION and never on its destruction.

Wave 21's own adversarial verifier measured all four of the consequences, and
every one of them was merged deliberately as strictly-better-than-dying. This
wave is the bill for that:

| what §AS1 read | what it produced | ruling |
| --- | --- | --- |
| a `fire_station` shell standing | station destroyed → capability false → protection ON, **while 1 engine was still in the fleet and answered 28 of 28 incidents** | **§AV1** — the fleet is the service |
| the FIRE question, on every hazard's damage door | a city with no fire department could not have a building finished off by a flood or a storm | **§AV1** — a hazard is answerable by the service THAT hazard needs |
| `under_construction` excluded from "standing" | starting an upgrade on the only station switched the protection ON | **§AV1** — the engines never left the bay |
| owning a department made you WORSE off | 66 buildings alive against 68, plus $27–57/gh | **§AV4** — a department must buy something a city without one does not get |
| `RELIEF_MIN` clamped outside the era cap | $8,000 × 3 = $24,000 against a $2,000 bill — **12.0×** | **§AV2** |
| `water_works` staffing keyed on the water GRAPH | $20.00/gh billed for three plants that are rubble | **§AV3** |

### AV1. Capability is the SERVICE, not the shell — and the hazard names its own service

`CityIncidentWorld._could_have_answered(answerable, role)` is now
`has_service_capability(role) and answerable`. It still reads no money anywhere.
Two changes, and the second is as large as the first:

* **The station half is deleted.** `has_service_capability(role)` is one fact: at
  least one unit in `FleetSystem` whose `resolve_rate` answers `role` and that is
  not parked `OFFLINE` — the same exclusion `_staffing` already applies, for its
  reason. The two halves §AS1 named do not come apart under this reading, they
  collapse into it. *"A garage with no engine in it is not a fire service"* is
  still false, because a garage contributes no unit. *"An engine with no station
  to roll out of is not a fire service"* is now TRUE, and doc 92 §62.1 is why: on
  the player's slot 0 the station is rubble, and the engine that outlived it
  answered **28 of 28** incidents while the predicate said the city had no fire
  service.
* **`role` is the hazard's own `primary_role`** (`IncidentSystem
  .incident_primary_role`), so `CascadeOps`' `building_condition` op — the door
  EVERY hazard's damage goes through — asks doc 06 for a construction crew when a
  roof comes off and for a water truck when a main breaks. Under §AS1 it asked
  about the fire department every time, and doc 92 §62.2's probe is the
  consequence: a city with no fire department, and every water truck in the game
  parked next to the flood, could not lose a building to water.

**Availability is not capability, and that is deliberate.** A unit on another
call or in `REFIT` still counts. Doc 06 reads `dispatch_blocked_no_units` as
ANSWERABLE precisely because fleet size is a PURCHASE; a predicate that exempted
a city whose only engine was busy would pay it for under-buying engines. "Could
this one have been reached?" is the `answerable` half's question.

**The door to the exemption is now exactly one verb.** Under §AS1 a city bought
fire immunity by LOSING its station — a fire did it for you. Under §AV1 the only
path that retires a unit is `FleetSystem.remove_station`, reached from doc 02
§2.12's demolition: the player's own bulldoze. A fire cannot buy the exemption;
only a decision can, and §AV4 is the ruling that decision has to lose.

**An empty `role` reads as the fire role**, which is exactly §AS1's behaviour. It
is unreachable from the shipped catalogue — every merged row carries a
`primary_role` and a subtype inherits its parent's, asserted by
`test_every_hazard_names_the_service_that_answers_it` — so it is the branch a
future row that forgets to name a service takes, and it fails toward the FLOOR
rather than through it.

### AV2. `RELIEF_MIN` is inside the era ceiling, or the heading is false

§AS4 charged the DAMAGE term against `relief_era_paid` and left `clampi(…,
RELIEF_MIN, RELIEF_MAX)` outside it. A floor is not a term: it does not shrink,
so `RELIEF_MIN × relief_grants_per_era` = $8,000 × 3 = **$24,000 of relief an era
pays whatever it was measured against**, and every bill under ~$24,615 was
out-paid — a $2,000 bill drew 12.0× itself. §AS4's own heading says an era may
never out-pay its bill, and the body disclosed the floor as an exception. **The
ruling, and it is one `if`:**

    payable = max(revenue_term, damage_term)
    if payable < RELIEF_MIN and relief_era_paid < RELIEF_MIN:
        payable = RELIEF_MIN          # the bottom rung, once per era

**THE FLOOR IS AN ERA'S GUARANTEE, NOT A GRANT'S.** An era receives `RELIEF_MIN`
at least once; after that a grant is worth what it is MEASURED on, so
`relief_grants_per_era` can no longer multiply the floor. Doc 92 §62.5 measures
it: the $2,000 rig falls from **$24,000 (12.0×) to $8,000 (4.0×)**, and on the
player's own slot 0 the passive arm's third grant is priced at its own $740
revenue term instead of being lifted to $8,000 for the third time —
$114,727 → $107,467, while the Restore-All arm, where the damage term is still
what pays, moves $114,727 → $114,668.

**What it does not promise, published rather than claimed away:** a bill under
`RELIEF_MIN` is still out-paid once. That is the price of doc 03 §2.10 layer 5's
bottom rung, and the bottom rung is not negotiable.

**TWO WIDER DRAFTS WERE TRIED AND THE SUITE KILLED BOTH, which is the reason
this ruling is narrow.** A per-era CEILING of `max(revenue_term, bill)` does
bound an era by its bill, and it breaks two guarantees the ladder already had:
`tests/test_relief_ladder.gd` says *"no revenue and no damage is RELIEF_MIN"* —
a city whose stock is all standing but dark has a $0 bill and a $0 revenue term
and collected **nothing** under that draft, a hole in the floor Waves 20 and 21
exist to close — and `tests/test_economy.gd`'s gate 18 collects the revenue term
TWICE in one era, which any ceiling charged against `relief_era_paid` removes.
Neither was found by argument. Both were found by the suite, after the wide draft
had already been written up as correct.

An ask that prices to zero is not paid and does not spend one of the era's three
rescues; it does stamp the cooldown, because `outstanding_restore_cost` is an
O(roster) walk and without that stamp this branch would re-price the whole roster
every settled game-hour.

### AV3. §AR3's remainder: the staffing follows the plant, not the graph

`CitySim.build_settlement_inputs` says of itself *"one guard, one place: this
loop is the sole author of both arrays"*, and it was not. The `water_works` row
is appended by a SECOND loop over `water.nodes`, keyed on a pump existing in the
GRAPH. A demolished `water_facility` takes its nodes with it
(`_take_building_off_the_map` → `_retire_water_nodes`); one that BURNS DOWN does
not — so the hole opens on exactly the path §AR3's own hole opened on. On the
player's slot 0, with all three water plants in rubble and 2 pump nodes still in
the graph, `E_departments` billed **$20.00/gh — $480 a game-day of wages for
plants that do not exist**. A pump node's `power_ref` IS its host shell (doc 05
§2.6), so the staffing now follows the plant. A node with no host is billed
exactly as it was.

### AV4. A department has to be worth owning, and coverage is what it buys

§AV1 makes the predicate honest and **that alone makes the incentive worse, not
better**: with the exemption keyed on not owning a service, the cheapest fire
insurance in the game is still to have no fire service. Doc 92 §62.6 measures the
three arms and says so.

The lever is the asymmetry doc 06 has carried since §2.6(a): **the crime rate
reads `police_coverage` and the fire rate read no coverage at all.** A fire
station bought RESPONSE and nothing else — and on a city whose roads are gone
that is 2 incidents answered in 90 game-days against 30,655 unreachable, for
$16.58/gh. So the fire generator gains the term the crime generator already has,
in the same file, the same data block and the same shape:

    f_fire_coverage = clamp(coverage_base − coverage_slope × fire_coverage,
                            coverage_min, coverage_max)

**No new magic number.** The slope is crime's own full-coverage reduction —
`police_slope / police_base` = 0.6 / 1.4 = **0.4286** — re-anchored at 1.0 so an
UNCOVERED city's fire rate is exactly what it has always been. Crime's ladder
anchors at 1.4 and RAISES the uncovered rate; doing that to fire would make every
city harder for a ruling that is about departments, so it is not done.
`coverage_min` is `coverage_base − coverage_slope`.

**This is not the farm §AS1 refused.** §AS1 rightly refused to gate the CONDEMN
predicate on `coverage_fire(tile)`, because that makes "build far from the
station" a fireproofing strategy. Coverage in the IGNITION rate runs the other
way: building far from the station gives you MORE fires, not fewer. The two
readings point in opposite directions and only one of them is farmable.

Doc 92 §62.6, 90 game-days on a founding city, three arms that differ in the fire
department and in nothing else — and the `none` arm is *paid* to divest, because
it bulldozes through the real command and collects the refund:

| arm | alive | treasury | condemned | incidents | fires | pop |
| --- | --- | --- | --- | --- | --- | --- |
| keep (maintained) | **32** | **$322,479** | **1** | 172 | 11 | 144 |
| burn (bought and forgotten) | 31 | $260,098 | 2 | 175 | 11 | 144 |
| none (bulldozed, refund taken) | 31 | $267,443 | 14 | 187 | 13 | 125 |

Owning and keeping the department is the best arm on both numbers the ruling is
judged on: **+1 building alive and +$55,036** against owning none, while paying
$30/gh more in `E_departments` for the privilege. The lesson the arms teach is
the one the game means: the worst arm is `burn` — bought and left to rot, paying
the upkeep and getting the wear.

**A/B, one cause, one line of data.** Re-running the identical three arms with
`coverage_slope` alone set to 0.0 returns keep to **31 alive / $281,360 / 3
condemned**: §AV4 is worth +1 alive and +$41,119 of the advantage. The `none` arm
is bit-identical under the ablation, and provably so — it has no coverage, so
`f_fire_coverage` is exactly 1.0 either way.

### AV5. What this wave did NOT rule, and why

* **`E_fleet` still bills engines whose garage is rubble** — $91.58/gh on the
  player's save, for 14 units housed in 6 destroyed stations. Under §AS1 that was
  a defect of the same family as §AR3. Under §AV1 it is CORRECT: those units are
  the city's fire, police and utility service, they answer calls, and the
  predicate now says so. The line was left alone deliberately and the reason is
  recorded here rather than in a defect row.
* **The condemn floor still cannot be earned on a city whose roads are gone.**
  Doc 92 §62.6's second rig is the player's own terminal save, and there all
  three arms land at 65 / 64 / 65 buildings alive (doc 92 §62.6's table) with the treasury pinned at the −$20,000
  credit floor: a city that has already fallen cannot answer "should I buy a fire
  station?", because neither number it would be answered on can move. That is a
  property of the rig, not of the ruling, and it is why §AV4 is measured on a
  founding city. Doc 91 A91-D-123 carries the open question.
## AX. Wave-24 rulings — a city may not report a population it does not have, and a ramp that does not run is not a rule (2026-09-04)

*Measured in doc 92 §64. Verbs in report 98 §67 RR-202/RR-203/RR-204. Defect
rows doc 91 A91-D-127, A91-D-128. Delta row doc 12 D-100.*

### AX1. A derived aggregate that only a tick writes is a lie between ticks

**Ruling.** `city_population`, `occupied_population`, `workforce`,
`jobs_capacity`, `jobs_market` and `job_fill_city` are DERIVED views of the
roster. They are not persisted, and a class that only computes them inside a
periodic `advance()` must also expose a way to compute them **without a step**,
which every door into a city then calls before that city is readable — boot and
restore both.

**Why it is a ruling and not a patch.** The failure was not that a number was
briefly wrong; it was that `city_population` was authored as *"what the last
hourly settle found"* and read everywhere as *"how many people live here"*. The
two agree at every moment except the first, and the first is exactly when a
player is looking: `main.gd::_wire_hud` paints the HUD before the sim has
stepped, and `_on_ui_save_loaded` paints it again the instant a save lands.
Measured, a 144-person city reported **0 for 55 real seconds** after a load
taken 21 ticks past the hour (doc 92 §64.3).

**And the lie was not confined to the chip.** `build_director_inputs`,
`goal_state_view()` — read by `_restore_goals` *during the restore itself* — and
doc 07's `storm_ready_earned` all take the figure, and the last of those prices
a reward against `pop / 1000`, so a zero population makes the Storm Ready
budget zero and the reward unearnable. A display bug that can cost the player
money is not a display bug.

**The shape of the fix is the other half of the ruling.**
`PopulationSystem.settle_aggregates` is pass 1 of `advance` and nothing else:

* **No `dt_h`.** `attractiveness` is not relaxed. Nothing about time moves.
* **The `occupancy` map is NOT written.** It is the one part of this class doc 08
  persists, doc 03 bills the first hour after a load off the restored copy
  through `occ_of`, and recomputing it at restore would make a
  save→load→advance round trip diverge from the uninterrupted run
  (constitution §5). The aggregate may be recomputed because it is derived; the
  map may not, because it is state.

**And the aggregates may not survive a `deserialize` either**, which is the
same rule read from the other end: a `PopulationSystem` handed another city's
`attractiveness` and `occupancy` is still holding the totals of the city this
process booted, so `deserialize` zeroes them and the restore recomputes them
once the whole roster is in.

**The ordering inside `_restore_finish` is itself a ruling: the settle runs
AFTER `_restore_goals`, not before.** `goal_state_view()` reads
`city_population`, and `GoalSystem.serialize` writes `done`, `progress` and
`earned_level` — all three in `state_hash`. Settling first hands the
curriculum's restore-time reconcile a population **the save does not record**,
which on the 1,500-building benchmark city completes objectives the
booted-and-saved city had not completed and breaks doc 08's boot → save → load
identity (`tests/test_save_migration.gd::test_37_…`, which is exactly how this
was caught — it failed on the first whole-suite run of this wave and on nothing
smaller). **A restore may not teach the curriculum something the boot it is
restoring into does not know.** The next hourly reconcile tells both of them,
together, and the restore-time reconcile therefore stays the no-op it has always
been — which is an open question for a doc 09 lane, not a thing to fix from
here.

The two callers are `CitySim.boot()`'s last line and the last line of
`_restore_finish`.

### AX2. A ramp that clamps to 1.0 for every building in the game is not a rule the code has

**Finding, not a change.** Doc 09 §2.10 describes an occupancy ramp: a new
building opens at 35 % and fills over `OCCUPANCY_RAMP_HOURS` (36).
`PopulationSystem.ramp` implements it exactly. **`CitySim._population_inputs`
has never called it with a real age** — every building in the city is handed the
literal `48.0` (now `CitySim.POPULATION_INPUT_AGE_HOURS`), which is above the
horizon, so `ramp()` returns 1.0 for all of them and the curve is inert. Doc 92
§64.2 measures the two side by side at the moment a house completes: **0.386
against 1.000.**

**This wave does not wire the real age, and the reason is the report it is
answering.** Wiring it is a balance change with a known sign: it would add 36
game-hours of near-invisible fill on top of the 176 real seconds already
measured between the tap and the chip moving, which is the complaint, made
worse. A defect that would be *deepened* by making the code match the doc is a
question for the lead, not a fix for a lane.

**Asked of the lead, ranked.** (a) Delete the ramp from doc 09 §2.10 and from
`PopulationSystem`, since nothing in the shipped game runs it and a constant
that gates nothing is a rule the next reader will try to obey. (b) Keep it,
wire `age_hours` from `Building.built_at_minutes`, and pay for it with a
feedback surface that shows the fill — which is a doc 12 job larger than D-100.
**(a) is recommended**: the ramp models a thing the game has no other way to
show, and doc 09's own §2.10 aggregate has no per-arrival channel to show it
through.

### AX3. The counter is honest, so the deficiency is a doc 12 deficiency

**Ruling.** Where a measurement shows a sim number to be correct and a player
report to be true anyway, the defect is in the surfaces and it is filed against
doc 12 — never "fixed" by making the sim lie faster.

Doc 92 §64.1 measures 176 real seconds from tap to chip, decomposed into 120 s
of shell (during which a `level == 0` build's `state_occupancy()` is 0.00, which
is correct: nobody lives in a foundation) and up to 60 s of waiting for doc 01's
hourly settle (which is correct: doc 01 settles population once per game-hour).
Neither term is a bug and neither is negotiable without moving a cadence the
whole sim is built on.

**What WAS a bug is that two surfaces disagreed.** The panel of the house the
player had just placed read `Occupants 4` — the AUTHORED capacity — beside a
population chip that had not moved and would not move for another three
minutes. The chip was right. D-100 makes the panel say `0 of 4` and pulses the
chip on the frame it changes; `CitySim.settled_residents` is the one accessor
both readings come from, so the panel and the counter can no longer be computed
two different ways.

## AZ. Wave-25 rulings — what the ground is allowed to be worth, and whether "resources" is a number worth persisting (2026-09-04)

*The lane's brief is one sentence from the player, 2026-09-04: "when we open up a
new plot of land, we want construction animations for that land — to show that
the land is being worked: digging it, materials. We will find materials from
digging it out for the infrastructure. So potentially opening up a piece of land
will give you resources and money back." §AZ1 rules on where the money is
credited from; §AZ2 on what bounds it; §AZ3 on whether "resources" beyond cash
earns its state; §AZ4 on what the render layer is allowed to read. Prices: doc 03
§2.8b. Measured: doc 92 §66. Verbs and deltas: report 98 §69.*

### AZ1. Who credits a find — the pipeline, or the coordinator?

**Q.** `DevelopmentController` runs the six phases and knows exactly which one
just finished. It is the obvious place to pay for what that phase turned up. Is
it allowed to?

**Ruling: no. `CitySim._credit_land_works` is the only writer, and the reason is
already written on the controller's own header** — *"this controller never
touches money; it only records what was started"*. That line was written for the
CHARGE direction (`take_phase_charges` hands the coordinator a list and the
coordinator prices it), and a credit that ignored it would leave the pipeline
paying out on one side and asking on the other.

Three things make the coordinator the honest place rather than merely the legal
one. It holds the RNG streams, and a `RefCounted` sim class that reached for a
stream it was not given would be the start of a second seeding path. It holds the
treasury, and doc 03 §5's rule is that nothing outside `Treasury` moves the
balance. And it already owns exactly this seam for exactly this pipeline: the two
phase effects that reach outside the land block — `_stamp_block_roads` and
`_extend_utility_corridor` — are the coordinator's for the same reason, and the
credit is filed directly beneath them, in the same match, on the same drained
event.

**Order is part of the ruling.** The find is credited AFTER
`development_phase_completed` has been emitted, never before. A receipt that
arrived before the thing it is a receipt for would read, in the event log, as the
crews being paid for work they had not finished.

### AZ2. What bounds a find — and why a ceiling that never binds is a defect

**Q.** The player asked for "money back". What stops that becoming "a block that
pays for its own development"?

**Ruling: a hard clamp on a PERSISTED cumulative per-block total, at
`0.10 × the block's own six-phase bill`, and it is chosen so that it BINDS.**

The clamp itself is the easy half. `LandBlock.works_yield_total` is persisted
(doc 08 §2.8 rung 11 — rung 10 is Wave 25's yard) rather than derived, and that is not bookkeeping: a total
that reset on load would let a player save, reload and be paid the ceiling twice,
which is a duplication bug wearing a balance constant's clothes.

The hard half is the VALUE, and the ruling here is about method. Doc 92 §66.3
measures three bounds — under the smallest `road_install` share of any bill
(0.2375), under `SALVAGE_FRACTION` (0.15), and **strictly above the maximum draw
that can happen without the `copper` bonus (0.0845) while strictly below the
maximum draw with it (0.1223)**. The third is the one this ruling exists for.

**A ceiling set at 0.15 would have satisfied every stated requirement and would
still have been wrong**, because at 0.15 no roll on any terrain at any distance
can ever reach it. It would have been authored, documented, tested-for-presence
behaviour that nothing consumes — this project's signature defect (A91-D-19's
shape), written into a balance constant instead of into an event. A number in
`data/economy.json` that cannot change any outcome is a number the next person to
retune will move without knowing whether it mattered. **A bound must be reachable
or it is decoration**, and this one is reachable exactly where a bound should be:
on the best possible roll of the rarest event.

### AZ3. Does "resources" beyond cash earn its state? — YES, at one integer

**Q.** The brief asks whether a materials stockpile that discounts the next
`road_install` / `utility_corridor` phase is worth its state, with the condition:
ship it if it stays at one persisted number per city, say why if not.

**Ruling: ship it. `CitySim.works_stockpile`, one integer, dollars of fill and
aggregate, for the whole city.** It is the honest reading of the player's own
words — the sentence is *"materials from digging it out **for the
infrastructure**"*, and a find that could only ever be cash would drop the second
half of it.

**Four decisions make one integer enough:**

1. **It is not a second currency.** A find has ONE value; `STOCKPILE_SHARE`
   (0.34, the road share of a block's own ground — doc 92 §66.5) says how much of
   that value is kept rather than sold. Cash and material always sum to the
   find, so the ceiling in §AZ2 bounds both together and there is nothing to
   balance twice.
2. **It is per CITY, not per block.** A per-block inventory would be six or seven
   integers the player can never see the whole of, and it would make the yard's
   own story — *the fill from block 3 went into block 4's road* — impossible.
   The heap is on a hardstanding; there is one hardstanding.
3. **It is capped, and the cap means something.** `$4,125` is what one phase may
   ever take off (doc 03 §2.8b). The yard is a working stock, not a bank.
   Measured (doc 92 §66.5), it peaks at $1,383 on serial development and empties
   itself on the very next phase — so the cap is honestly reported as a guard
   against parallel pipelines rather than as a limit players will feel.
4. **Nothing is ever lost.** When the yard is full the share that will not fit is
   paid as cash instead. A resource system whose failure mode is "your material
   evaporated" is one the player has to manage; this one has no failure mode.

**And it is visible in three places, because a number that silently shrinks an
invoice is the one thing a ledger may never contain.** The land panel names the
yard and quotes the draw under the pending phase it would come off; the event log
carries `land_works_stockpile_spent`; and `development_phase_charged` now carries
`stockpile_offset` (removed at the merge: it had one reader, a test — the yard draw is its own `land_works_stockpile_spent` row) so the row's `cost` and the treasury's movement are the same
number. Without those three the player would read `road_install $6,340` against a
doc that publishes $7,500 and have nowhere to find the missing $1,160.

**The one thing deliberately NOT shipped**: the yard cannot be spent by the
player, sold, or moved. There is no verb. It is a discount that happens to them,
and that is the whole of it — a resource with an inventory screen is a different
game, and doc 93 §F's deferral list is where that belongs if it is ever wanted.

### AZ4. What `LandWorksView` may read, and what it may never do

**Q.** The render layer has never known anything about land development —
`grep -rn "CLEARING\|GRADING\|development_state" game/` was empty before this
wave. What is the new view allowed to read?

**Ruling: sim EVENTS for transitions, and a THROTTLED read of its own active set
for progress. Never a per-frame scan of the world.**

A block's phase changes on `development_phase_started` /
`development_phase_completed` / `block_ready`, which are already on the bus and
already drained once per tick by the shell — so the view's membership is
event-driven and costs nothing between transitions. Progress WITHIN a phase is
not on any event and should not be: it moves every tick and an event per tick is
a bus flooded with a number.

So the view polls, and the ruling is about what it may poll. It walks **its own
active set** — the blocks it has already been told are developing, which is a
handful and is bounded by the pipeline, not by the map — at a throttled cadence,
and asks `DevelopmentController.active_view` and `ConstructionQueue.progress` for
those ids only. It may never iterate `world.block_ids_sorted()`. The distinction
is not academic: the map is 7×7 blocks today and doc 09's own §2.13 benchmark
city is larger, and a renderer whose cost grows with the MAP rather than with the
WORK is exactly the class of thing doc 11's chunk stride exists to prevent.

**And it writes nothing.** Constitution §3: the renderer reads the sim through
snapshots and events and never calls back into it. Every choice `LandWorksView`
makes about where a stake, a stump or a spoil heap goes is a hash of the block id
and the index, so it is the same on every device and after every load, and the
sim's state hash cannot move because the view exists.
## AY. Wave-25 rulings — what a transformer owes the player, and what a building panel is allowed to hold (2026-09-04)

*(Report 98 §68 RR-205..RR-208. Measured in doc 92 §65. Defect rows doc 91
A91-D-129, A91-D-130, A91-D-131. Delta rows doc 12 D-114, D-115, D-116.)*

The player asked for one thing and it decomposes into three rulings: the grid
gets a repair verb, the pad gets a panel, and the building panel gives back what
was never its to hold.

### AY1 — A component the city can lose is a component the city can pay to fix, and the price is doc 03's

**Ruling.** Every asset the city owns that can be DAMAGED has a player-reachable
repair priced by doc 03 §2.5. That has been true of buildings since doc 02 §2.6
and of roads since doc 10 §2.13. It was **not** true of the grid: doc 04's
components could fail, and the only thing that put one back was doc 06 resolving
the incident the failure filed. The verb is now
`CitySim.cmd_repair_grid_component`.

**Four things it may not do, and the reasoning for each.**

1. **It may not author a price.** Doc 03 §2.5 has said since C-16 that a grid
   component's repair capital is its §2.13(b) build cost at the current level;
   `CostCurves.capital_value_grid` has implemented it since Wave 17. The verb
   reads it through a new accessor (`repair_cost_grid`) and adds nothing. No row
   is added to `data/economy.json`, and the charge books under the existing
   `&"repair"` category — so this wave moves no ledger line and needs no doc 03
   §2.13 amendment beyond a pointer at the spender.
2. **It may not heal on the tap.** The player's word was *"calling your crews
   there"*, and a verb that healed instantly would be the thing doc 09 §2.3
   exists to stop: work that costs money and no time. The job is an ordinary
   `ConstructionQueue` `repair` with crew-hours, a crew type and a job id — so
   S16 lists it, `cmd_rush_construction` can buy its remaining time at doc 03
   §2.13(f)'s rate, and the ETA the panel shows is the queue's own.
3. **It may not author a duration either.** Doc 06 already measured how long
   fixing a transformer takes: `transformer_failure.w_base` = 0.90 game-hours of
   work at tier 1. The crew-hours are that number scaled by the damage being
   bought back — doc 02 §2.6's shape (`authored work × damage_fraction`), with
   doc 06's number in place of doc 02's build time, because doc 06 is the
   document that measured *this* job. A retune of doc 06's work moves the repair
   clock with it, and neither number is written twice.
4. **It may not be a purchase that changes nothing.** `repair_component` never
   LOWERS a condition, so a repair of a standing component already at its target
   would take the money and move nothing. `E_NOT_DAMAGED` therefore covers three
   states, not one: zero damage, a standing component at its target, and a
   quoted price that rounds to $0. The third arm's threshold is doc 03's own
   rounding — this wave authors no floor.

**And one thing it must do that is easy to miss.** Doc 02 §2.12 rules that *a
post-damage repair never restores to new*, and gives a building two targets:
1.00 from `active`, 0.85 from `damaged`. The same rule applies to a component,
and `PowerGrid.repair_component` had only the 0.85 half — correct for the
failure path doc 06 resolves, wrong for a player buying an overhaul of a
transformer that is still standing, who would be charged for `1 − condition` and
lifted only to 0.85. `REPAIR_TARGET_WORN = 1.00` is §2.12's other half, and the
job carries the target it was QUOTED at so a failure between dispatch and arrival
cannot silently downgrade what the player paid for.

**The number that was never read.** `_fail`'s `damage_fraction` — 0.35 / 0.05 /
0.30 / 0.05 by kind — was authored three times and consumed nowhere (doc 91
A91-D-130). It is now `PowerGrid.FAILURE_DAMAGE`, one table, and it is the price
basis. A wave that adds a repair without giving the burnout number a reader would
have been authoring a *second* damage model beside a live one.

**What is deliberately NOT repairable, and why it is a ruling rather than an
omission.** A substation and a plant are BUILDINGS (report 98 C-30) and have had
`cmd_repair_building` all along. A component that is merely OPEN is not damaged:
a tripped relay is a position, and doc 04's auto-reclose or doc 06's dispatch
closes it for nothing — pricing a repair on it would sell a fix for a fault that
does not exist. A FEEDER is excluded because doc 03 cannot price it: §2.13(b)
prices a line per tile of its run, `capital_value_grid("feeder", 1)` answers 0,
and a feeder repair admitted here would be free. That is doc 03's authorship
decision to make (the whole run, or the faulted span?) and it is filed as
A91-D-131 rather than guessed at in `sim/`.


*Merge note (2026-09-05).* The lane's `E_NOT_DAMAGED` gate was doc 03's rounding
(`cost <= 0`), and the verifier found every transformer on the founding city
offering `CALL A CREW  $1` at game-hour 6 with the panel reading 100 %. The gate
now also requires `GRID_REPAIR_MIN_DAMAGE_FRACTION` (0.05, `data/economy.json`,
`CostCurves.grid_repair_min_damage`) of wear on a STANDING component; a FAILED
one is always offered the crew. `tests/test_ui_transformer.gd::
test_a_hair_of_wear_is_not_a_repair_and_real_wear_is` runs it on the shipped
city rather than a forced `condition = 1.0`.

### AY2 — A thing the player can see is a thing the player can tap, and what it opens is a panel like any other

**Ruling.** The distribution layer has been DRAWN since Wave 17 —
`PowerInfraView` puts a padmount cabinet with three bushings on every
transformer's tile and runs a service drop to every building it feeds. A city
object that is rendered at that fidelity and cannot be selected is a promise the
game does not keep. `BuildController.pick_at_ground` gains `PICK_COMPONENT`.

**Where it sits in the order, and why.** Between OPPORTUNITY and BUILDING, on the
same 48 dp radius, measured from the tapped POINT to the pad's tile centre. This
is doc 12 §2.21's argument about the street collectable, one object over: the
cabinet is 2.4 m across inside an 8 m tile, and a finger 48 dp wide over it must
catch it rather than the tile. *(Corrected at the merge, 2026-09-05: the lane's
first draft said a tile-ownership pick would hand every pad tap to the house
behind it; its own instrument and the verifier measured 0 of 18 founding pads
and 0 of 144 bench pads standing on a building's tile, so that never happened.
The order stays for the reason that survives measurement — within one radius the
smaller, more urgent object wins — and it is free: 0 of 77 buildings within six
tiles of the grid lose their tap.)* The asymmetry that makes the order safe is
the same one: **the house has not moved and is one tap away**, and the
transformer is the thing that is on fire.

**It is a PANEL, not a popup.** Same layer (`PanelLayer`), same one-surface rule
(`UIWidgets.close_siblings`), same `ui_root.selected_entity_id` semantics, same
✕, same 48 dp targets, same headless model — because the player's own sentence
was *"all of that information pops up just like a building does"*, and "like a
building does" is a specification. `TransformerPanelModel` computes every value
and `TransformerPanel` computes none, which is the split that lets the whole
surface be driven by `tests/test_ui_transformer.gd` instead of photographed.

**What it must show, in the order a player asks for it.** Which unit and what
condition; what it carries against what it can carry AT TODAY'S AMBIENT (doc 04
§2.7's derating is why "150 kW" is not an answer); what feeds it; **who is behind
it** — the list Wave 17 could not draw because the grid had no public way to ask
(RR-205), each row a jump; and the four verbs. When the unit has FAILED the panel
opens ON the repair, because that is the moment the player tapped it.

### AY3 — A panel's job is the decisions only it can make; everything else is a door

**Ruling.** The building panel keeps what is about THIS BUILDING and hands off
what is about a shared piece of infrastructure. The POWER section becomes one
row — `Power · fed by T-03 · 78 % · ›` — and the water block becomes one row of
the same shape, both opening the surface that owns the thing.

**The test is not "how long is the panel", it is "who owns this decision".** A
transformer is shared by every building in its service radius, so its UPGRADE
button was drawn on N panels, its REMOVE row was armed from N panels, and a
player who upgraded it from a house's panel had no way to see the other N−1
buildings they had just helped. That is the defect, and panel length was only its
symptom. The water node has the same shape: it is hosted by a shell and serves a
zone.

**What was examined and KEPT, which is as much of the ruling as what moved.**

* **The priority row** stays. Doc 04 §2.4's shed priority is a property of THIS
  building — the player is saying *this hospital comes before that shop* — and no
  other surface can ask the question.
* **The coverage / requirement checklist** stays. Doc 12 §2.7 calls the
  `Fix this →` row the single most important teaching device in the game; it is
  about this building's next level and belongs nowhere else.
* **The progress block** stays. It answers *"is anything happening on this lot?"*,
  which a player asks of the building in front of them, not of a queue — and S16
  is the list, not the answer.
* **The repair, upgrade, priority, demolish, restore and salvage verbs** stay.
  They are the player's own list: *"the buildings just need a few things: repair,
  upgrading, and things we already have."*

**The one-row summary is a READING, not a label.** `fed by T-03 · 78 %` carries
the transformer's id and its load band, so the row is worth looking at even when
the player never opens the panel behind it — and `NOT SERVED` is drawn in the
critical state, because "nothing feeds this" is the most useful thing the row can
ever say and must not be one tap away.

## BA. Wave-26 rulings — a water works that supplies nothing, and which door a plant is bought through (2026-09-05)

*Lane: A91-D-123, the utility planner. Resolutions report 98 §70 RR-213..RR-216.
Measured doc 92 §67. Defect rows doc 91 A91-D-137..A91-D-139. Surfaces doc 12
§2.7 D-120.*

### BA1. Is doc 02's `water_facility` a plant, or a shell that happens to sit near one?

**Q.** `data/buildings.json` ships `water_facility` with `"produces":
["water_node_shell"]`, a `reference_variant` of `pump`, a five-rung
`power_demand_kw` column of 60 / 145 / 360 / 880 / 2,160 — which is doc 05's
`components.pump` `base_kw` column, exactly — and a footprint column report 98
RR-8 requires to equal doc 05's `components.pump` footprints. Doc 05's own
`cmd_place_water_component` says of the shell, the node and the lateral that they
*"always go together and have never been separable in this project"*. And yet
`cmd_place_building("water_facility", origin)` built the shell alone.

**Ruling: a `water_facility` IS the doc-05 nodes hosted on it, at their level.**
Not a civic shell. Every column doc 02 authors for this archetype is read out of
doc 05's component table; a building whose entire stat block is another
document's supply table is that supply, and an instance of it that hosts no node
is a data error the command layer was manufacturing on demand.

**The evidence that this is a defect and not a design.** Doc 04's two node-shells
— `substation` and `power_facility` — go through `cmd_place_building` and get
their grid component from `CitySim._commission_grid_node`, whose own docstring
records why: *"`cmd_place_building` sold a $15,000 substation and a $60,000 plant
that added no capacity and no generation at all"* (doc 92 §17.3 fix 2, Wave 6).
`_commission_water_nodes` was written from the same paragraph, on the same seam,
one document over — and only ever brought a node ONLINE. So doc 05 got half of
doc 04's fix and nobody noticed, because the authored city hands you `WTR-1` and
`WTR-2` with their nodes already attached and no agent in this project had ever
called the building door on this archetype.

**Measured at the fork**: `api.place("water_facility")` returns `ok` and
`sim.water.nodes.size()` goes 22 → 22. The shell it stamps decays, is billed doc
03's `water_works` staffing, draws 60 kW through `_water_kw_by_building`'s
fallback to `b.stats`, occupies 3×3 of a full map — and supplies nothing.

**What follows, and all three are the same sentence:**

1. **Placement.** `cmd_place_building("water_facility", …)` delegates to
   `cmd_place_water_component(reference_variant, …)`, the door that has always
   built the shell, the node and the lateral together. An empty shell is no
   longer constructible from anywhere. The doc-05 siting rules a water works
   actually has — `E_NO_MAIN`, `E_NO_WATER`, `E_FOOTPRINT` — start applying to
   it instead of being skipped, which is the whole reason the delegation is to
   the command rather than a second copy of its body.
2. **Upgrade.** A completed `water_facility` job re-rates every node hosted on
   that shell to the shell's level (`CitySim._rerate_water_nodes`), exactly as
   `_commission_grid_node` re-rates a substation's component. Doc 09 §2.14.2's
   `l7_water_facility` asks the player for that purchase; before this it bought
   a taller building and not one extra cubic metre of water.
3. **Ceiling.** The shell may not climb past the nodes it is.
   `water_shell_top_level` is the SMALLEST of its nodes' own
   `data/water.json` `placeable_levels` caps under the `levels_4_5_enabled` gate
   — 2 for an intake, 2 for a treatment train, 3 for a pump — and
   `cmd_upgrade_building` takes it as `top_level`. Doc 02 §2.14 already said this
   archetype's ladder *"is doc 05's per-variant component table"*; nothing
   enforced it.

**Price: unchanged, and that is a measurement rather than a convenience.**
`econ_curves.upgrade_cost("water_facility", 1)` and
`econ_curves.water_component_upgrade_cost(variant_cost_ratio("pump"), 1)` are the
same **$51,750**, and `build_cost("water_facility")` and
`water_component_build_cost(pump ratio, 1)` are the same **$45,000** — both ride
doc 03's `water_plant` row at ratio 1.00, because doc 02's ladder for this
archetype IS the pump reference column. A one-node site is therefore billed
identically either way, and the only case where anything moves is the authored
`WTR-1`, which hosts three nodes and now raises all three for one bill.

**That last case is the ruling and not an exception.** `WTR-1` is ONE PLANT: doc
09 authored it as a single building with an intake, a treatment train and a pump
under one id, `ui/water_actions.gd` draws all three as one block on that
building's own panel, and doc 03 bills its staffing once. A player who upgrades
the water works upgrades the water works. Charging them three times for one
building, or raising one third of it, would be the model leaking its own
bookkeeping into the fiction.

### BA2. May the shell's power gate keep reading doc 02's column?

**Q.** `cmd_upgrade_building` computes `delta_kw` from `catalog.stats`. For a
`water_facility` that is doc 05's PUMP row. Now that the shell's rung moves its
nodes, is that still the right number to ask doc 04 about?

**Ruling: no — the gate asks about the nodes.** `_refresh_water_kw` has always
billed this archetype the SUM of its hosted variants' `kw_required` (the demand
tick reads `_water_kw_by_building` and falls back to `b.stats` only for a shell
with no nodes, which after BA1 cannot exist). A gate that checked one column
while the tick billed another was already approximate; with three nodes moving
at once it would be wrong by more than a factor of two — `WTR-1` L1 → L2 asks doc
04 for 32→79 plus 40→98 plus 60→145 = **+190 kW**, against the shell column's
+85. `CitySim.water_shell_node_delta_kw` is that sum, and the E_POWER_HEADROOM
check is asked with it.

**And it is wrong the OTHER way by nineteen times on the starter city's water
tower**, which is the measurement that makes this a defect rather than a
refinement (doc 92 §67.12). `WTR-2` hosts one doc-05 `tank` node; the demand tick
bills it **5.0 kW** through `_water_kw_by_building`, and the gate was charging it
doc 02's `water_facility` column — the PUMP reference row (report 98 RR-8) — at
60 → 145 kW, i.e. **97.75 kW after the margin**. A water tower was being priced
in power as though it were a pump house, because doc 02 authors ONE level table
for the archetype and generates it for one variant. `test_power_operations.gd`'s
doc 92 §48.1 demonstration had been standing on that number since Wave 5 and is
re-made here against `can_upgrade_power` directly, with the audit's own delta,
where it is unaffected.

### BA3. Which card does the player tap?

**Q.** The build sheet lists `water_facility` as a plain building card AND five
`water_facility_<variant>` component cards. After BA1 the plain card's confirm
runs doc 05's twelve checks. Its GHOST ran doc 02's five.

**Ruling: the plain card is the pump card.**
`BuildController.enter("water_facility")` with no variant now enters
`enter_water_component(reference_variant)`, so ghost and command are one code
path again and `E_NO_MAIN` is drawn before the player pays rather than after. The
card keeps its place, its name key and its price — doc 03 quotes both doors at
the same $45,000 — and the tab it sits on does not move, so nothing about the
sheet's layout or doc 12 §2.7's card ordering changes. **The alternative that was
rejected** was deleting the plain card: it would have made the roster shorter
than `BuildingCatalog.ARCHETYPE_COUNT` for one archetype only, which is a special
case in a table whose whole value is that it has none.

### BA4. Where does a "plan the utilities" rule belong — in the agent, or in every agent?

**Q.** `Balanced._grow` is the ladder every strategy in `tools/playtest.gd`
walks. A water rule written there is a rule for `balanced`, `greedy_growth`,
`infrastructure_first`, `tax_squeezer`, `disaster_neglect`, `storm_ready`,
`curriculum` and `collector` at once.

**Ruling: written in `_grow`, beside `_lead_generation`, and switched on by a
knob that only `curriculum` sets.** The rule belongs there — it is
`_lead_generation`'s own sentence one utility over, and splitting it into a
`Curriculum`-only method would be two copies of one idea in one file. But doc 92
has published seven matrix rows, a 50-game-day dark share and nine balance gates
fitted to what that ladder buys, and doc 92 §62.9's merge addendum ruled that
this wave ships the planner **rather than another re-fit**. Turning a new
purchase on for eight agents would have moved every one of those numbers at once
and made the planner's own measurement unreadable underneath them.

So `plans_water` joins `maintains` and `tax_target` as KNOB 3, on the same
controlled-pair discipline `disaster_neglect` and `tax_squeezer` are built on:
one agent differs from `balanced` in exactly one field, and any difference
between their rows is that field and nothing else. **What this defers**, stated
rather than hidden: `balanced` still has no water planner, so doc 92's matrix
still measures a city that answers water refusals instead of preventing them.
Closing it is one line — `plans_water = true` by default — and the whole cost of
it is the re-derivation that line forces: §17's matrix, §18b's 50-game-day dark
share and every gate fitted to them, which is a lane of its own and not a
footnote on this one (doc 92 §67.5).

## BB. Wave-27 rulings — what a machine is allowed to be a function of, and who owns the ground it changed (2026-09-05)

*The lane's brief is one sentence from the player, 2026-09-05, after playing the
merged Wave 25 build: "For the land excavation — like I said, we should be
getting money and funds from resources that we find out there, but also the
construction crews, big bulldozers and things like that, need to go to clear the
land so we can actually see something happening. The animation you have — I see
it's not bad — but we need to actually show MOVEMENT over there. Construction
crews, building, clearing land, building roads." The money half shipped in Wave
25 (§AZ); this is the movement half. §BB1 rules on who owns a pass and the ground
it changes; §BB2 on which clock drives what and why there are two; §BB3 on
whether a player-laid road may be animated over an instant sim edit; §BB4 on what
the layer may keep. Drawn: doc 11 §2.19. Arguments: report 98 §71 RR-217..RR-220.
Defect rows doc 91 A91-D-140..A91-D-142.*

### BB1. A machine and the ground it changed — one rule or two?

**Q.** Wave 25's dressing turned a phase's progress straight into a COUNT: keep
`budget × (1 − progress)` clumps, lay `total × progress` slabs. Wave 27 puts a
bulldozer on the block. Is the machine placed to match the count, or is the count
derived from the machine?

**Ruling: neither — both read ONE rule, and the rule lives with the machine.**

The obvious two options are both wrong in the same way. Placing the machine "at
about the right place for the count" makes the machine decorative: a dozer
hovering over a field that is thinning uniformly is worse than no dozer, because
it invites the player to look at exactly the thing that does not hold up.
Deriving the count from the machine's position each frame makes the DRESSING
depend on a layer that is allowed to be gated out by distance and by the
governor — so a block at the edge of the visible radius would stop clearing.

So `LandMotion` publishes the pass rules as **static, pure functions** and both
layers call them: `sweep_of()` (where a point falls in the two dozers'
serpentine), `pave_state()` (the machine's pose AND the number of slabs behind
it, from one traverse), `trench_dug()`, `brush_local()`, `spoil_local()`,
`template_runs()`. `LandWorksView` keeps a clump exactly while
`sweep_of(clump) > pass_progress`, and lays exactly the slabs `pave_state`
reports. There is no frame on which the two can disagree, and there is no
ordering dependency between the layers.

**And it moved four published numbers, which is the evidence the change is
real.** CLEARING brush 20 → 21, ROAD_INSTALL pave 18 → 19, FINAL pave 54 → 55,
UTILITY trench 6 → 5. A rewrite that produced the same table would have meant the
counts were never positional.

**The corollary is a scope rule, and it is the one that keeps the picture
honest.** Only what a machine LAYS OR REMOVES is measured on the pass — brush,
base, kerbs, trench, staged pipe. The graded plane and the spoil heaps keep the
RAW progress, because they are the state of the ground and not something being
dragged behind a machine; holding them back through the arrival would leave a
block that had visibly started work looking untouched.

### BB2. Two clocks, and why one would not do

**Q.** Doc 11 §2.16's plant runs entirely on GAME-MINUTES. Why does this layer
need a second input?

**Ruling: position along a pass is a function of the JOB'S PROGRESS; every cycle
is a function of GAME-MINUTES; and the split is what makes a load correct.**

A single clock fails at exactly one moment and it is the moment that matters. If
a dozer's position were `f(game_minutes)`, then loading a save — or catching up
from `advance_hours`, or resuming after the pipeline was paused — would put the
machine wherever the clock happened to land, on a block whose *work* is stored as
an integer count of work units in `ConstructionQueue`. The machine would be in
one place and the ground it had cleared in another, and the save file already
knows which of the two is right.

So: **PROGRESS drives every position along a pass** (the dozer's sweep, the
screed, the trench head, and the paver on a player's road run), because
`ConstructionQueue.progress(job_id)` is persisted and *is* the position.
**GAME-MINUTES drives every cycle** (the dig, the drum, the haul shuttle, a
crew's walk), for §2.16's own reasons — three times as fast at 3×, still while
paused.

Two consequences are worth stating because they look like bugs and are not:

* **A paused city is completely still.** `gm_per_s = 0` stops the cycles and a
  paused pipeline stops the progress. That is the promise, not a gap.
* **A roller's drum turns with the GROUND, not with the clock** — its angle is
  `fract(distance / circumference)` — so a roller that is not moving has a still
  drum. A drum spinning on a parked machine is the tell that a layer is animating
  a number instead of a machine.

### BB3. May a player-laid road be animated? — the question did not need asking

**Q.** The brief allows a visual-only crew pass over a road the sim finishes
instantly, "measured against what doc 10 actually does".

**Ruling: doc 10 does not finish it instantly, so nothing here is visual-only.**

`CitySim.cmd_place_road` submits an ordinary `ConstructionQueue` job — kind
`&"road"`, crew `road_crew`, crew-hours from `RoadTunables.build_crew_hours` —
and doc 10 §2.13's under-construction lifecycle puts the tiles into the grid
immediately at `under_construction_seed` condition under a `construction_new`
closure so the crew can reach the far end of its own job. `road_built` is emitted
on completion. The pass is therefore **that job's own progress, drawn**, and the
suite asserts the job really has time in it
(`test_a_player_laid_road_gets_a_crew_that_works_along_it`) so the day that
changes, the gate says so rather than the picture quietly becoming a lie.

Two smaller rulings fall out of it:

1. **The tiles come from `RoadNetwork.job_record`, not from the queue payload.**
   The payload carries live `Vector2i` that `JSON.stringify` degrades to the text
   `"(3, 4)"` on the way into a save (report 98 A91-D-47); `job_record` is the
   durable form and doc 02's construction roster already reads it for the same
   reason. The payload is the fallback for a caller with no road network wired.
2. **A run is dropped by the POLL, not by `road_built`.** That event also fires
   for a repair, and a cancelled job emits nothing at all — so the honest test is
   "the queue no longer holds this job id", which covers all three.

### BB4. What the motion layer may keep — nothing, and the arrival proves it

**Q.** A machine arriving up the street is the one thing here that looks like it
needs a state machine: it starts somewhere, it drives, it stops.

**Ruling: it keeps nothing. The arrival is a function of progress, and it is paid
for OUT of the pass rather than added to it.**

The first `ARRIVE_FRAC` (0.10) of every phase is the machine arriving, sampled
along the last 72 m of **the polyline doc 11 §2.16 already resolved** for this
block's frontage — `ConstructionActivity.to_site`, street-true and lane-offset,
held as a read-only reference so a road edit that re-routes the lorries re-routes
the arrival with it. `pass_progress()` then rescales 0…1 of the phase onto
0.10…1, so the brush does not start going before the dozers reach it.

That is what makes the arrival re-derivable: a save reloaded at progress 0.04
draws the machine four tenths of the way up the street, every time, on every
device. A latch would have made it a coin flip.

The same rule refuses the two things that would have needed state. A block with
no street in reach gets **no arrival and no haul lorry** rather than a machine
appearing at the kerb — the same honest answer `ConstructionActivity.frontage_ok`
already gives a building site with no road. And a livery is salted off the SITE
and never off the machine's position: the first draft salted the roller off
`int(pos.x) * 31 + int(pos.z)` and repainted it every frame it moved.
## BC. Wave-28 ruling — every building fits the transformer envelope (2026-09-05)

**The player, on the device:** *"A fully loaded data center still pulls too much,
and I haven't even upgraded it past level two. Transformers may need more power,
or we just make the data centers fit in that envelope, so a transformer can
handle it fully upgraded."*

They had measured the game correctly and the hole was **ten cells wide**, not
one. A building attaches to **exactly one** transformer — `PowerGrid._attachments`
is a `building_id → transformer id` map and doc 04 §2.1's rule picks one — so the
largest load the distribution model can serve is one rung of doc 04 §2.2's ladder
at §5.3's own 0.90 ceiling. Against that, doc 02 §2.14 authored a **sixth** rung
of demand while doc 04 stayed at **five** rungs of copper, and nobody asked the
two tables to agree. Measured at each archetype's own doc 01 channel peak — the
hour §5.3's gate is actually judged at (`CitySim.peak_component_loads`, RR-120) —
**nine of doc 02's sixty-six published `power_demand_kw` cells had no transformer
at all** — and one of doc 05's thirty per-variant rows, `pump` L5, which is doc
02's `water_facility` L5 read through the variant table and therefore the same
2,160 kW counted a second way. Doc 92 §68.1 publishes the whole table.

**The tell was already on this page.** §G5 rider 1 ruled, of the coverage columns
of that same sixth rung, that *"those columns are a demand ON the service stock;
the service stock did not gain a rung, and demanding coverage the player has no
verb to buy is a wall with no door"* — and then, four paragraphs above it, §G5
published *"a `data_center` that draws 43,150 kW, which is not a mistake but the
point of `k_dem > TAX_LEVEL_GROWTH`."* `power_demand_kw` is a demand on the
service stock in exactly the sense the rider means, and doc 04's stock had not
gained a rung either. The rider was written, and applied to one of the two
columns it was true of.

### BC-1. THE ENVELOPE. No authored cell may exceed one transformer at §5.3's ceiling — at rest OR at the gate

> **(a) SERVABLE.** For every archetype and every level,
> `power_demand_kw(L) × channel_peak(demand class) ≤ PowerGrid.UPGRADE_MAX_R ×
> CAPACITY.transformer[top]`.
>
> **(b) BUYABLE.** And for every level above the first,
> `power_demand_kw(L−1) × channel_peak + UPGRADE_HEADROOM_MARGIN ×
> (power_demand_kw(L) − power_demand_kw(L−1)) ≤ PowerGrid.UPGRADE_MAX_R ×
> CAPACITY.transformer[top]`.

**(b) is the half the first Wave 28 cut shipped without, and it is the half the
player meets.** `CitySim.cmd_upgrade_building` never compares a steady-state
reading to anything: it asks `power_headroom(sim_id, delta_kw ×
UPGRADE_HEADROOM_MARGIN)`, and `can_upgrade_power` adds that to the component's
**peak** load (`CitySim.peak_component_loads`, RR-120). For a building alone on
its own pad at full occupancy — the case (a) is written against — that is exactly
the inequality above. With the clamp derived from (a) alone, `data_center` L6
shipped at 6,070 kW and its L5→L6 step read `4,230 + 1.15 × (6,070 − 4,230) =
6,346 kW` against a 6,075 kW envelope: `PowerGrid.transformer_rung_for(6,346)`
returns **0**, so the last upgrade of a data centre staffed above 93.6 % was
refused on every transformer at every price. A gate that was green while the
verb was red is the failure mode this whole ruling exists to end, so the ruling
now states both readings and the clamp is derived from whichever is tighter.
They differ by `(cell(L) − cell(L−1)) × (margin − channel_peak)`, so (b) binds
where a channel peaks below 1.15 — `datacenter` 1.00, `industrial` 1.13 — and (a)
binds everywhere else.

**At the PEAK, not at the base, and that is the half that had never been
checked.** `power_demand_residential` runs to **1.46** at 20:00 and
`power_demand_commercial` to **1.51** from 10:00 — so `high_rise` L5, authored at
3,810 kW, asks its transformer for **5,563 kW** at dinner, and `apartment` L6 at
1,940 kW asks for **2,832**, which is past the old 2,250 kW ceiling on a building
nobody had thought to suspect. The comparison is made at the peak because doc 04
§5.3's gate is (RR-120), and a rule that passed at the trough would be a rule the
game does not run.

**Enforced in three places, and only ONE of them is a refusal.**
`tools/gen_buildings.py` refuses to write a table that breaks either clause —
that is a hard stop, `N failure(s), nothing written`, exit 1.
`BuildingCatalog._check_service_envelope` **reports** one: its message lands in
`catalog.errors`, `is_valid()` goes false, `CitySim.boot_from_files` carries
`boot_errors = ["building catalog invalid"]` — and the only consumer,
`game/sim_host.gd`, calls `push_error` and **carries on with the bad table**. So
a hand-edited `data/buildings.json` boots, loudly. (An earlier draft of this
section claimed it "cannot get past boot"; it can, and saying otherwise would
have let a reader trust a door that is a doorbell.) The check is still worth
having — it is the only one that runs on a player's actual file — but the thing
that stops a bad table shipping is the third:
`tests/test_balance_gates.gd::test_gate_34_every_building_fits_the_transformer_envelope`,
which proves both clauses on the shipped roster and proves the mirror the first
two read still equals `PowerGrid`'s own derivation,
`CitySim.UPGRADE_HEADROOM_MARGIN`, `CitySim.DEMAND_CLASS_CHANNEL`'s own class map
and `DayCurveSet.channel_peak`'s own curves.

### BC-2. THE LADDER GAINS ITS SIXTH RUNG — 6,750 kW — and it is the LAST one

Doc 04 §2.2's transformer ladder appends **6,750 kW / radius 10**, and the
number is derived rather than chosen:

```
rung 6 = UPGRADE_MAX_R x FEEDER_CAPACITY[2] = 0.90 x 7,500 = 6,750 kW
```

— the largest transformer the top conductor class can carry at §5.3's own
ceiling. **A seventh rung is arithmetically impossible without a fourth
conductor class**, because a transformer bigger than 6,750 kW could not be fed by
any feeder in the game, so the ladder is now provably complete rather than
merely longer. Two consequences are stated rather than discovered: a top-rung
transformer needs a **class-3 feeder** and a **substation at L2 or better** to
sit under (0.90 × 6,000 = 5,400 < 6,750), which is what it costs to run a load
this size; and §2.6's THERMAL and HAZARD rows are per-KIND rather than per-rung,
so the sixth rung adds no row there — an oil-filled unit is an oil-filled unit.
Service radius extends the 3/4/5/6/8 ladder by its own last step (+2). Price is
doc 03 §2.13(b)'s: **$41,500**, the ladder's own $/kW curve continued.

**Both doors the player offered, and neither one alone.** Bigger transformers
cannot reach `data_center` L4's 6,630 kW, let alone L6's 43,150 — that would want
a 47,944 kW "transformer", six times the biggest feeder in the game. A smaller
data center cannot reach the bottom either: `k_dem > TAX_LEVEL_GROWTH` (2.15)
forces a six-rung ladder to span at least 46×, so a data center whose top fits
2,250 kW must start under 49 kW, less than a `water_facility` L1. The pair works
because each closes what the other cannot: the rung buys the headroom, the seed
buys the alignment.

### BC-3. SINGLE STEP AND FOOT. A player can always answer "upgrade the transformer"

> `rung(L+1) ≤ rung(L) + 1` for every archetype, and `rung(1) ≤ 2`.

The first is what makes the answer *buyable*: one building upgrade never costs
more than one transformer upgrade, so `cmd_fix_power_capacity` — which quotes
**the next rung and only the next rung**, because that is all
`cmd_upgrade_grid_component` can charge in one purchase — is never quoting a
purchase that cannot clear. The second is what makes an archetype *startable*: a
first level servable from the bottom of the ladder. `data_center` failed it at
the fork (its L1 needed rung **4**, a $6,900 transformer on day one, which is
what *"I haven't even upgraded it past level two"* feels like from the inside).

**And it is now SAID.** The building panel's power row, S18's customer block (in every state
that has customers at all) and the fix router's POWER row all carry
`PowerActions.rung_needed` — the smallest
rung whose nameplate carries the host transformer's post-upgrade PEAK load. Doc
12 D-123. `needs_rung == 0` is kept as its own answer rather than clamped to the
top rung, because *"nothing you can buy fixes this"* is a different sentence from
*"buy the top one"*, and BC-1 is what guarantees a shipped table never says it.

**RIDER (fix pass): `needs_rung == 0` is not a wall, and the first cut said it
was.** *"No rung under this pad carries the load"* and *"nothing you can buy
fixes this"* are two different statements, and the wave shipped the first one
wearing the second one's words. Doc 04 §2.9's other purchase is a **parallel
transformer** — a second unit inside the building's reach that adoption hands the
building to — and `CitySim.cmd_fix_power_capacity` has sold it since Wave 17.
Reproduced on a top-rung pad at 6,150 kW (r = 0.911: legal, un-shed, merely past
the 0.90 UPGRADE gate): a 100 kW `data_center` L1 was told *"Level 2 draws more
than any transformer carries — nothing on the ladder feeds it"* and its neighbour
was marked STRANDED on S18, while at the same tick `cmd_fix_power_capacity`
returned `action=place_transformer clears=true cost=42160` and the upgrade
previewed OK afterwards. A panel that declares a wall where the game has a door
is the defect class this whole wave is named after, authored by the wave.

So the question is now asked about the BUILDING and not about the pad.
`rung_needed` carries **three** states instead of two:

| state | means | the sentence |
|---|---|---|
| `needs_bigger` | a bigger rung under this pad carries it | `ui_power_row_needs_rung` / `ui_transformer_customers_need_rung` |
| `needs_second` | no rung under this pad does, but a pad of its OWN would (`alone_rung > 0`) | `ui_power_row_needs_second` / `ui_transformer_customer_needs_second` — a purchase, with a price |
| `no_rung_carries` | not even a transformer of its own carries it (`alone_rung == 0`) | `ui_power_row_no_rung` / `ui_transformer_customer_stranded` — the only real wall |

`alone_rung` reads `CitySim.building_peak_demand_kw` — this building's own share
of the pad's peak, scaled exactly as `peak_component_loads` scales it — plus the
same ×1.15 delta, because a new transformer starts empty. **BC-1 is what keeps
the third row unreachable for an authored building:** a cell that clears (b) at
full occupancy clears it alone on a pad of its own by construction, so the only
way to reach `no_rung_carries` is a hand-written stat row, which is exactly what
`tests/test_power_operations.gd::test_b_when_no_placeable_transformer_carries_it_the_fix_says_so`
does.

### BC-4. THE CLAMP MAY BIND THE TOP RUNG AND NOTHING ELSE

The generator's power cell becomes `min(round_rule(seed x k_dem^(L-1)),
servable_ceiling, buyable_ceiling)` — the same `min(curve, ceiling)` shape
`coverage_ladder.max_requirement` has had since doc 02 §2.9, applied for the
reason §G5 rider 1 already gave, and with BC-1's two clauses solved for the cell:

```
servable_ceiling      = floor_kw( ceiling_peak_kw / channel_peak )
buyable_ceiling(prev) = floor_kw( (ceiling_peak_kw - prev x (channel_peak - margin))
                                  / margin )                            -- L >= 2
```

Three riders:

1. **The clamp is floored onto the `kw` grid, never rounded half-up**, or a
   clamped cell would land one grid step past the capacity it clamps to, which is
   the wall BC-1 exists to forbid. `high_rise` L6 is `6,075 / 1.46 = 4,160.96`
   floored to **4,160**; `data_center` L6 is
   `(6,075 − 4,230 × (1.00 − 1.15)) / 1.15 = 5,834.35` floored to **5,830**.
2. **It may bind at most the TOP rung.** Two rungs at the same kW is an upgrade
   that costs nothing to power, and an archetype whose second-from-top cell needs
   clamping does not have a rounding problem, it has the wrong seed.
3. **`buyable_ceiling` reads the CLAMPED cell below it**, so the column is
   generated rung by rung rather than cell by cell: pulling a rung down changes
   what the rung above it may ask for. (In the shipped table only the top rung is
   ever clamped, so the recursion is one level deep — but a generator that
   computed the ceiling from the unclamped curve would be wrong the first time
   that stopped being true.)

Which is why `data_center`'s power seed moves **400 → 100 kW** and `high_rise`'s
does not move at all. The interval that makes the data center climb exactly one
rung per level is **(55.4, 135]** kW; 100 is the round number in it, it keeps the
data center the largest first-level draw in the roster (`high_rise` 90,
`water_facility` 60, `office` 35), and it leaves the clamped sixth rung a real
**+37.8 %** step over L5 (4,230 → 5,830) instead of a free one — see the rider
below on what "real" is and is not worth. `high_rise` L1–L5 are untouched:
its ladder was already aligned (L1 rung 2 → L5 rung 6) and only ran one rung past
the top, which is precisely §G5 rider 1's case. **Seven cells moved in all** —
six `data_center`, one `high_rise` — against nine that had no transformer.

**RIDER (fix pass): a clamped step is efficiency-POSITIVE, and that is a price
this ruling pays rather than a claim it can make.** "A real step" means non-zero.
The bar doc 03 §9 item 4 sets is `k_dem > TAX_LEVEL_GROWTH` (2.15) — every
upgrade must be *less* utility-efficient than the last, which doc 03 calls the
single most important cross-doc constant in the game's balance. A clamped cell is
off the `k_dem` curve by construction, so `high_rise` L5→L6 (**×1.092**) and
`data_center` L5→L6 (**×1.378**) both grow demand by less than tax grows, and
they are the only two cells in the roster that do. Nothing was watching:
`test_demand_growth_invariant` and `verify_invariants()` check the COEFFICIENT,
and `test_k_dem_ordering_holds_in_the_shipped_table` compares L5 to L1. Gate 34
now asserts the consequence by name — **exactly these two steps** may sit at or
below `TAX_LEVEL_GROWTH` — so the exception is bounded, published and
regression-tested rather than silent. The alternative was to shrink both seeds
until an unclamped sixth rung fitted, which C-13's own arithmetic forbids: a
six-rung ladder at `k_dem` 2.55 spans ×43, so a data centre topping out at 5,830
would have to start under 135 kW *and* clear every rung by exactly one, which is
the seed it already has. The clamp is the cheaper of two prices, and both are now
written down.

**What this does NOT touch, said plainly.** `k_dem` is unmoved at 2.35 / 2.45 /
2.55 and the class ordering still holds; the `water_demand` column is generated
from a separate seed and did not move a cell, so doc 05's balance is unchanged by
the doc 02 half of this wave; and jobs, population, tax class and every money
column are untouched. The data center's revenue side is exactly what it was and
its power bill fell, which is the direction the player asked for — doc 92 §68.4
measures what that is worth and files it to the lane that owns the gate matrix.
