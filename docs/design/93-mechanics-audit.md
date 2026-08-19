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

Also binding from the same pass: **mode-invariance is per-system, not
whole-hash** — doc 06 §2.6 sanctions Poisson-count differences per step size,
doc 04 §2.12 sanctions one-step coarse thermal integration, and the cosmetic
traffic feed draws per-minute online. The milestone criterion guards the
deterministic core (clock, population, happiness, settled economy ±5%) with
ambient generation disabled; each stochastic subsystem's own suite bounds its
sanctioned parity. Save→load→advance identity remains EXACT and whole-hash —
that doctrine is untouched (and Wave-1 integration hardened it: negative-double
encoding, traffic-feed/congestion/density/day-accumulator persistence).

## F. Explicitly deferred (unchanged from master plan)

Multiplayer/social, city trading, seasons/holidays, mod hooks, cloud saves,
monetisation — none are Phase-1/2 scope; nothing in Waves 1–3 blocks them.
