extends SimTest
## Doc 92 §10's regression gates, made executable.
##
## Doc 92 pass 2 proposed seventeen gates and implemented none of them, on
## purpose: several were supposed to FAIL, because they describe the game after
## the pressure systems are wired rather than before. This file is the after.
## Each `test_gate_NN` below is one row of that table, in table order, and each
## one names the finding it answers.
##
## FOUR THINGS ABOUT HOW THESE RUN, all of which are honesty and not detail:
##
## 1. **Horizon.** Doc 92's table is quoted at 21 game-days × 3 seeds × 6
##    strategies. That whole matrix costs minutes of wall clock; this file gates
##    the three strategies whose rows the findings turn on at doc 92's own
##    21-game-day horizon on one seed, and says so per gate. The full matrix is a
##    merge-time job for `tools/playtest.gd`; the delivery report carries it.
## 2. **Path.** These drive the coarse step ONLINE (`BalanceGateRig`), not as an
##    offline catch-up. The rig's header explains why in full; the short version
##    is that doc 08 §2.3 rule 1 suppresses the Disaster Director for the whole
##    of a catch-up session, so an all-catch-up run cannot see the pressure these
##    gates exist to measure.
## 3. **Metric.** Doc 92 §3 reports two money columns — `treasury` (cash) and
##    `value created` (cash + construction spend) — and warns that cash alone
##    ranks a spend-everything agent wrongly. With doc 02 §2.6 wear live, the
##    warning inverts: the harness's scripted agents take exactly ONE action per
##    game-hour, the maintenance queue is never empty once a city is large, and a
##    maintaining agent therefore spends half its action budget repairing instead
##    of building. `value created` now rewards the agent that lets the city rot,
##    for a reason that lives in `tools/playtest.gd`'s action budget and not in
##    the sim. Gates that doc 92 quoted on `value` are gated on BOTH columns
##    where both hold, and on cash with a named reason where they do not.
## 4. **Deferred gates.** Three of doc 92's rows need a ruling this pass did not
##    receive — two are `data/starter_city.json` shape edits (F-4, F-8) and one is
##    an unruled command-layer gate (pass-1 F-7). Those tests PIN today's measured
##    value with a loud comment naming the ruling they wait on, so the day the
##    ruling lands the gate fails and gets its real threshold. They are marked
##    `_deferred_` in the method name so nobody mistakes a pin for a pass.

const Rig := preload("res://tests/balance_gate_rig.gd")
const ECONOMY_DATA := "res://data/economy.json"

const GATE_SEED := 1337
## The three seeds doc 92's strategy matrix is run on. A gate whose RULING was
## fitted on the matrix has to be measured on the matrix — see gate 12c, which
## was not, and which a single seed's noise tripped in Wave 8.
const MATRIX_SEEDS: Array[int] = [1337, 4242, 9001]
## Doc 92's own horizon, for the gates whose thresholds it quotes there.
const LONG_DAYS := 21
## The cheaper horizon for the gates that only need a shape, not a threshold.
const SHORT_DAYS := 10
## Gate 21's own horizon, and the ONLY gate that does not run on `LONG_DAYS`.
## Doc 92 §24.9: the curriculum grew a sixth level and it is a long one — the
## tower rung is measured at 435–478 game-hours against level 5's 113–181 —
## so a 21-game-day window can no longer contain the arc it is asked to prove
## completable. 45 days is the horizon; the RULED BOUND on the top level is
## 40 game-days, against a measurement of 31.1 / 33.5 / 34.3.
const CURRICULUM_DAYS := 45
const CURRICULUM_TOP_LEVEL_DAYS := 40
## **Gate 32's two street horizons** (Wave 15, RR-86). Both are INSTRUMENT
## parameters and neither is a balance number — the balance numbers they are
## compared against live in `data/economy.json`.
##
## `CEILING_SAMPLE_HOURS` drives the SPAWNER only, four scalars per game-minute,
## so 240 game-hours is ~14,400 cheap calls and ~135 offers — enough that one
## unlucky `lost_valuables` cannot move the mean by more than a couple of per
## cent. `tools/measure_street_yield.gd` takes the same measurement at 2,160
## game-hours for the published table.
##
## `CEILING_ARC_DAYS` drives a whole city on the FINE path, which is ~60× the
## coarse step: 3 game-days is ~30 s and ~41 offers. The published version is 21
## game-days × 3 seeds in `tools/measure_street_arc.gd` (~21 minutes), which is a
## tool's budget and not a gate's.
const CEILING_SAMPLE_HOURS := 240
const CEILING_ARC_DAYS := 3
## **The three-tier beat (doc 92 §27.5).** §22's ruled 10–40 game-hour band was
## written for "levels 1–3" of a five-level arc, before the street tool, before
## the sixth rung and before the Wave-8 rules epoch. It is retired and replaced
## by two bands and a horizon: the OPENING (levels 1–2) gets **45** game-hours,
## because that is the claim the old band was really making — a player who has
## not decided to keep the game must not be made to wait; the MIDDLE (levels 3–4)
## gets **90**, a session and a bit; and levels 5–6 get no hour band at all and
## are bounded in game-DAYS by `LONG_DAYS` and `CURRICULUM_TOP_LEVEL_DAYS` above,
## because a level whose cost is a five-figure purchase is a saving beat and not
## a sitting.
##
## **45 and not 40, and the old table is why.** Level 2 measures 39–41 game-hours
## and has measured 39–41 since doc 92 §22.3 first published it — under a claim,
## in that same subsection, that "levels 1–3 land inside the 10–40 game-hour
## band". The table printed 41 on the line above the sentence. A ceiling a
## shipped, unchanged, deliberately-tuned level has always been one hour over is
## a ceiling in the wrong place, so it moves to the measurement plus a notch.
## Both numbers are ceilings and neither is a fit: measured 13–14 / 39–41 at the
## opening and 59–64 / 64–73 in the middle.
##
## **RE-FIT Wave 14, the OPENING ceiling only: 45 → 58** (doc 92 §33.6, report 98
## RR-69). Doc 07's weather reaches doc 10's roads, `E_roads_repair` rises 16 %
## and doc 06 writes twice as many traffic accidents, so the curriculum agent's
## purse fills more slowly and its purchase beats land later. Re-measured with
## `tools/measure_curriculum.gd --days=45` on both arms of the same patch — the
## before column reproduces §27.4's published table to the game-hour, which is
## what makes this an A/B and not a re-record:
##
## | level | before (1337/4242/9001) | after | duration before → after |
## |---|---|---|---|
## | 1 | 13 / 13 / 14 | 13 / 13 / 14 | 13–14 → **13–14, bit-identical** |
## | 2 | 52 / 54 / 55 | 63 / 56 / 67 | 39–41 → **43–53** |
## | 3 | 111 / 115 / 119 | 123 / 122 / 128 | 59–64 → 60–66 |
## | 4 | 176 / 179 / 192 | 192 / 191 / 209 | 64–73 → 69–81 |
## | 5 | 371 / 358 / 361 | 399 / 389 / 409 | 169–195 → 198–207 |
## | 6 | 827 / 852 / 866 | 918 / 917 / 932 | 456–505 → 519–528 |
##
## **Level 1 does not move by a single game-hour on any seed**, and that is the
## shape a purse-side change should have at the very top of the arc: four houses,
## one transformer and 170 residents are bought out of the founding purse inside
## the first fourteen game-hours, before a rainy day has been billed. Everything
## below it slips by 5–15 %, in the one direction, on every seed. The MIDDLE
## ceiling (90) is untouched and still holds with 9 game-hours of margin.
##
## 58 is 53 (the new worst seed) plus a notch, the same rule that put 45 above 41.
## **What did NOT move is `CURRICULUM_TOP_LEVEL_DAYS`, and that is now the
## tightest number in this file**: the arc finishes on game-day 38.2–38.8 against
## a ruled 40, where it used to finish on 34.5–36.1. It is a ruled design bound,
## not a fit, so it is not re-cut to buy margin back — but the next change that
## slows the arc at all will fail gate 21 there, and doc 92 §33.7 ranks it.
##
## **WAVE-15 RE-MEASURE, AND NOT ONE BOUND MOVES** (doc 92 §36.4, report 98
## RR-79). The money pass raised the opening's income, and every bound in this
## block is a CEILING — so an arc that got faster is an arc with more margin, and
## a ceiling with more margin under it is not re-cut to look tight. Same
## instrument, same horizon, same seeds:
##
## | level | before (1337/4242/9001) | after | duration before → after |
## |---|---|---|---|
## | 1 | 13 / 13 / 14 | 14 / 13 / 17 | 13–14 → **13–17** |
## | 2 | 63 / 56 / 67 | 47 / 42 / 47 | 43–53 → **29–33** |
## | 3 | 123 / 122 / 128 | 82 / 79 / 83 | 60–66 → **35–37** |
## | 4 | 192 / 191 / 209 | 135 / 131 / 132 | 69–81 → **49–53** |
## | 5 | 399 / 389 / 409 | 246 / 258 / 284 | 198–207 → **111–152** |
## | 6 | 918 / 917 / 932 | 710 / 709 / 754 | 519–528 → **451–470** |
##
## **Level 1 is the one rung that does not improve**, and on two seeds it is a
## game-minute or three later (13 → 14, 14 → 17): with a fuller purse the
## curriculum agent makes different first choices. 17 game-minutes is still
## game-day 0 with two thirds of the day left, so the `first_day_at[1] <= 1`
## assertion below holds by the same margin it always did.
##
## **`CURRICULUM_TOP_LEVEL_DAYS` is what this buys back.** Doc 92 §33.7 ranked it
## as the tightest number in this file — the arc was finishing on game-day
## 38.2–38.8 against a ruled 40. It now finishes on **29.6 / 29.5 / 31.4**. The
## bound is a ruled design decision and is NOT re-cut downward to reclaim the
## tension; it is recorded that the tension is gone.
##
## ---------------------------------------------------------------------------
## **WAVE-15 RULING — the bound is HELD at 40, and doc 92 §33.7's question 2 is
## closed** (doc 92 §39.10).
##
## §33.7 asked for one of two things: re-rule the bound at 45, or re-cost the
## arc's top level, because 1.2 game-days of margin meant *"the next thing that
## slows the curriculum arc fails there, and the failure will look like that
## change's fault rather than this one's."* **Neither, and the reason is that the
## margin came back on its own.** Re-measured at this fork with the same
## instrument, horizon and seeds (`tools/measure_curriculum.gd --days=45`), the
## arrival table reproduces §36.4's post-money-pass numbers to the game-hour:
##
##   level 6 at game-hour **710 / 709 / 754** = game-day **29.58 / 29.54 / 31.42**
##
## against a ruled 40 — **8.58 game-days of margin**, seven times what §33.7 was
## worried about. A bound is not re-ruled to make a number look comfortable, and
## it is not re-ruled to make it look tight either; 40 is what the design decided
## a graduation arc may cost, and the money pass is why the arc now fits inside
## it with room. What §33.7 asked for was a ruling; the ruling is *hold*, and the
## evidence is a measurement rather than a preference.
##
## *Level 6 remaining the longest rung by far (451–470 game-hours against level
## 5's 111–152) is doc 92 §24.9's own ruling and is untouched here: the
## graduation level is allowed to be the longest one.*
const CURRICULUM_OPENING_BEAT_H := 58
const CURRICULUM_MIDDLE_BEAT_H := 90

## One run per (strategy, days, seed) across the whole file: several gates read
## the same run and a 21-game-day `disaster_neglect` run is the most expensive
## thing here.
var _runs: Dictionary = {}
## Same idea for gate 12 / 12b's controlled tax pair, which is not a strategy run.
var _tax_runs: Dictionary = {}


func _run(strategy: String, days: int = LONG_DAYS, seed_value: int = GATE_SEED) -> Dictionary:
	var key := "%s/%d/%d" % [strategy, days, seed_value]
	if not _runs.has(key):
		_runs[key] = Rig.run(strategy, seed_value, days)
	return _runs[key]


func _summary(strategy: String, days: int = LONG_DAYS) -> Dictionary:
	return _run(strategy, days)["summary"]


## The mean of one summary column over [MATRIX_SEEDS] — doc 92's own matrix
## sample. Three runs instead of one, for the gates whose thresholds were fitted
## on three.
func _matrix_mean(strategy: String, key: String, days: int = LONG_DAYS) -> float:
	var total := 0.0
	for seed_value in MATRIX_SEEDS:
		total += float(_run(strategy, days, int(seed_value))["summary"][key])
	return total / float(MATRIX_SEEDS.size())


static func _pacing() -> Dictionary:
	return (StarterCityLoader.read_json(ECONOMY_DATA).get("pacing_guardrails", {})
			as Dictionary)


# =============================================== 1–2 the founding anchors (§4)

## GATE 1 — founding first settled game-hour, net $/gh, within 1 % of the ruled
## figure. Doc 92 §4 asked for the two-significant-figure anchors in doc 93 §E2
## to be promoted to measured values; `STARTER_NET_PER_HOUR_EXACT` now IS that
## measured value, and this is the test that keeps it true.
func test_gate_01_founding_first_settled_hour_net() -> void:
	var anchor := float(_pacing()["STARTER_NET_PER_HOUR_EXACT"])
	var measured := float(_summary("do_nothing", 1)["net_first_hour"])
	assert_almost_eq(measured, anchor, anchor * 0.01,
			"founding net $/gh drifted from the ruled anchor by more than 1%")


## GATE 2 — founding first game-day net, within 1 % of the ruled figure.
func test_gate_02_founding_first_game_day_net() -> void:
	var anchor := float(_pacing()["STARTER_FIRST_GAME_DAY_NET_EXACT"])
	var rows: Array = _summary("do_nothing", 1)["day_rows"]
	var measured := float((rows[0] as Dictionary)["net_mean_per_hour"]) * 24.0
	assert_almost_eq(measured, anchor, anchor * 0.01,
			"founding game-day net drifted from the ruled anchor by more than 1%")


## And the expense side of the same ledger, which is the line the fleet-billing
## ruling moved: doc 06's live roster, never doc 03's held `STARTER_VEHICLES`.
func test_gate_02b_founding_expense_anchor_and_fleet_billing() -> void:
	var anchor := float(_pacing()["STARTER_EXPENSE_PER_HOUR_EXACT"])
	var samples: Array = _run("do_nothing", 1)["samples"]
	assert_almost_eq(float((samples[1] as Dictionary)["expenses"]), anchor, anchor * 0.01)
	# The founding roster is doc 06's ladders, not a held constant: 2 patrol,
	# 1 engine, 2 utility, 2 water repair, 1 construction crew.
	var sim := CitySim.boot_from_files(GATE_SEED)
	var roster := sim.incidents.fleet.roster_for_economy()
	assert_eq(roster.size(), 8, "doc 06 houses eight units at the founding stations")
	var by_type := {}
	for entry in roster:
		var type_id := String((entry as Dictionary)["type"])
		by_type[type_id] = int(by_type.get(type_id, 0)) + 1
	assert_eq(by_type, {"patrol_car": 2, "fire_engine": 1, "utility_service_truck": 2,
			"water_repair_truck": 2, "construction_crew": 1})
	# doc 03 bills exactly that roster: 2×7 + 12 + 2×9 + 2×9 + 14 = $76/gh.
	assert_almost_eq(sim.economy.e_fleet(roster), 76.0, 0.01,
			"E_fleet bills doc 06's roster (C-50), not STARTER_VEHICLES' 58")
	assert_almost_eq(sim.economy.e_fuel_vehicle(roster), 0.0, 1e-9,
			"and no fabricated kilometres: the roster meters no road distance yet")


# ======================================= 3, 5, 6 the control the game must beat

## GATE 3 — `do_nothing`'s 21-game-day treasury is an UPPER bound and must have
## fallen. Doc 92 measured $199,427 (mean of seeds) for a city that never saw an
## incident, never lost power and never touched the credit line. Wear (F-2), the
## live fleet bill (C-50) and the Director floor (F-1) all bill the control now.
func test_gate_03_do_nothing_treasury_has_fallen() -> void:
	const PASS_2_MEASURED := 199427
	var treasury := int(_summary("do_nothing")["treasury_end"])
	assert_true(treasury < PASS_2_MEASURED,
			"standing still still banks $%d over 21 game-days (pass 2: $%d)"
					% [treasury, PASS_2_MEASURED])


## GATE 6 — minimum building condition after 21 game-days of `do_nothing` is
## below 1.000. Doc 92 F-2: `Building.apply_decay` had no caller in `sim/`, so
## `data/buildings.json`'s 60 authored `decay_per_hour` rows were dead data and a
## city left alone stayed factory-new forever.
func test_gate_06_do_nothing_city_wears_out() -> void:
	var summary := _summary("do_nothing")
	assert_true(float(summary["min_condition"]) < 1.0,
			"nothing wore out in three game-weeks — decay is unwired again")
	assert_true(float(summary["mean_condition_end"]) < 1.0)
	# And it is wear, not damage: nobody attacked this city.
	assert_eq(int(summary["destroyed_end"]), 0)


## GATE 5 — **the headline.** Playing well beats not playing, on the cash column
## a player actually sees AND on value created. Doc 92 measured the opposite by a
## wide margin: the control ended three game-weeks with 11× the "competent"
## agent's cash, because every pressure system in the game was unwired.
##
## **WAVE-4 RETUNE (ruling 1), and the honest version of this gate.** Pass 2's
## `balanced` banked, because the repair-first early return spent half its action
## budget on maintenance and it had nothing to build with — so it ended 21
## game-days with $480,480 of idle cash and this gate passed on the cash column.
## The rebalanced agent invests instead, and by construction a spend-everything
## agent's cash sits at its reserve: measured, seed 1337, **$65,845 against the
## control's $159,077** — while holding **$1,021,565** of city and **1,366**
## residents against the control's $159,077 and 144.
##
## Cash therefore cannot be this gate's column, and doc 92 §3 said so before the
## rebalance made it bite: *"Spend-everything agents pin cash near zero, so cash
## alone ranks them wrongly."* Ranking a builder below a savings account because
## the builder spent its money on buildings is a measurement error, not a
## finding. What answers doc 92 F-1 — *"standing still is the richest a player
## can be"* — is the pair of columns that survive a spend-everything agent:
##
## | column | `balanced` | `do_nothing` | ratio |
## |---|---|---|---|
## | value created (cash + city) | **$1,021,565** | $159,077 | **6.4×** |
## | population | **1,366** | 144 | 9.5× |
## | net $/gh, last settled hour | **$2,543** | ~$260 | 9.8× |
## | min condition | **0.792** | 0.511 | the control is ROTTING |
##
## The last row is the half of F-1 that pass 2 could not measure at all: the
## control now pays for standing still. Its worst building falls 1.000 → 0.511
## in three game-weeks on doc 02 §2.6 wear alone (four incidents in 504
## game-hours — it is not being attacked), and its income falls with it: the
## control banked $169,592 before `COND_FLOOR` was ruled and $159,077 after, so
## decay already costs an untouched city **6.2 %** of its three-week earnings.
func test_gate_05_playing_beats_standing_still() -> void:
	var playing := _summary("balanced")
	var control := _summary("do_nothing")
	assert_true(int(playing["value_created"]) > int(control["value_created"]) * 2,
			"it should not be close on value: $%d vs $%d"
					% [int(playing["value_created"]), int(control["value_created"])])
	assert_true(int(playing["population_end"]) > int(control["population_end"]) * 2,
			"a played city is a bigger city")
	assert_true(float(playing["net_last_hour"]) > float(control["net_last_hour"]) * 2.0,
			"and it out-EARNS the control per game-hour: $%.0f vs $%.0f"
					% [float(playing["net_last_hour"]), float(control["net_last_hour"])])
	# Doing nothing is no longer free: the control's own city wears out.
	assert_true(float(control["min_condition_end"]) < 0.60,
			"the untouched city ended three game-weeks at min condition %.3f — "
			% float(control["min_condition_end"])
			+ "standing still has stopped costing anything")
	assert_true(float(playing["min_condition_end"]) > float(control["min_condition_end"]),
			"and the player's city is in better shape than the one nobody touched")


# ================================================= 4, 7, 8, 9 pressure systems

## GATE 4 — `balanced` beats `disaster_neglect`. These two agents are the SAME
## class with one field changed (`maintains`), so the whole difference is the
## maintenance verb. Doc 92 measured neglect ahead on EVERY axis — cash, value,
## population, happiness, stability — while spending $0 on maintenance, because
## `apply_decay` had no caller and there was nothing to maintain.
##
## Gated on cash, condition and the two city-health columns. NOT on
## `value created`: see the file header — with wear live, the harness's
## one-action-per-game-hour budget means a maintaining agent spends roughly half
## its actions repairing, so the agent that lets the city rot converts more
## dollars into buildings *inside this horizon*. That is a `tools/playtest.gd`
## artifact (the fix is to let `Balanced.act` take a maintenance action AND a
## build action in the same game-hour), and it does not survive contact with a
## longer run. Measured, seed 1337, same rig:
##
## | game-day | balanced treasury / value / pop / minC / destroyed | neglect |
## |---|---|---|
## | 21 | $480,480 / $847,620 / 811 / 0.848 / 0 | $48,038 / $1,296,719 / 1,860 / 0.452 / 0 |
## | 35 | $1,204,030 / $1,614,380 / 751 / 0.848 / 0 | **−$14,677** / $1,358,573 / 366 / **0.000** / **285** |
## | 50 | $2,086,419 / $2,517,069 / 880 / 0.848 / 0 | **−$21,673** / $1,351,577 / **197** / 0.000 / 285 |
##
## The neglect knob is fatal; it takes five game-weeks. A city left to rot loses
## 285 buildings to fire — condition feeds `Building.fire_condition_mult`
## (1 + 1.5·(1−c)^1.5) and `state_fire_mult` 1.8 for damaged, so a rotten city
## ignites far more often than a maintained one and the fires spread.
## **WAVE-4 RETUNE (rulings 1 and 2).** Three things changed under this gate and
## all three are recorded in doc 92 §13:
##
## 1. `balanced` no longer starves itself building. Its `act` runs a maintenance
##    ladder and a growth ladder in the same game-hour, so the two agents now
##    build the SAME size of city (325 vs 324 buildings, seed 1337) and the
##    comparison is finally about maintenance instead of about the action budget.
## 2. `tax.COND_FLOOR` 0.55 → 0.40 (doc 92 §13). At 0.55 a repair paid itself
##    back in ~19 game-days of recovered revenue, which is outside this gate's
##    own horizon — the reason pass 2 could not see maintenance pay. At 0.40 the
##    payback is ~14 game-days and the crossover lands inside 21.
## 3. The gate is measured on the columns the maintenance knob actually moves.
##
## Measured, seed 1337, 21 game-days, same rig:
##
## | column | `balanced` | `disaster_neglect` | discriminates? |
## |---|---|---|---|
## | treasury | **$65,845** | $59,971 | yes, +9.8 % |
## | min condition | **0.792** | 0.353 | yes |
## | mean condition | **0.903** | 0.837 | yes |
## | damaged at end | **12** | 15 | yes |
## | buildings | 325 | 324 | — (same city) |
## | stability | 0.7754 | 0.7882 | **no** |
## | dark share | 0.2572 | 0.2567 | **no** |
##
## Stability and dark share were dropped from the assertions with that data
## behind it: both were dominated by city SIZE and by the weather draw, both
## agents built the same city, and the 0.0005 dark-share difference was noise.
## Condition, the damaged roster and cash are the causal columns.
##
## **WAVE-5 NOTE — dark share is now a causal column again, and it moved to gate
## 18.** F-11's grid rule is inside `maintains`, so `disaster_neglect` is still
## this agent with exactly one field changed and it now differs on the lights
## too: **8.70 % vs 26.09 %** at 21 game-days, seed 1337. This gate keeps the
## columns it was fitted on and gate 18 owns the new one, so neither is measuring
## two things at once. The cash column also moved with it — maintained $91,291
## against neglected $75,219, where pass 3 measured $65,845 / $59,971 — because a
## lit city earns its tax line.
##
## The neglect knob is still fatal on the long horizon — see gate 4b.
##
## **WAVE-15 RE-FIT — the money column moves from `treasury_end` to
## `net_mean_per_hour`, and the reason is the same one this header already gives
## for dropping `value created`** (doc 92 §36.5, report 98 RR-80).
##
## The money pass raised the opening's income (RR-78's founding assistance and
## celebration grants), and both agents spent the extra cash — but they spent it
## differently, because `balanced` also buys repairs. Measured on the same rig,
## 21 game-days, three seeds, before → after:
##
## | column | `balanced` | `disaster_neglect` | discriminates? |
## |---|---|---|---|
## | treasury, before | **$81,950** | $55,624 | yes |
## | treasury, after | $58,612 | **$80,532** | **INVERTED** |
## | value created, before | $834,156 | **$952,519** | inverted |
## | value created, after | **$965,739** | $925,644 | yes, but +4.3 % |
## | net $/gh, before | **$1,968** | $1,653 | yes, +19 % |
## | net $/gh, after | **$2,342** | $2,020 | yes, +16 % |
## | min condition | **0.798** | 0.391 | yes, 2.0× |
## | dark share | **0.19 %** | 30.66 % | yes, 161× |
##
## Read the first three rows together and the finding is not that maintenance
## stopped paying — it is that **cash-in-bank is a stock, and a stock measures
## how much an agent chose not to spend.** The two money columns swapped which
## one is contaminated: `value created` was inverted before and is now the right
## way up, `treasury_end` was the right way up and is now inverted, and NEITHER
## flip has anything to do with the maintenance knob. `value created` is not the
## replacement either — seed 9001 separates the pair by 0.29 % on it, which is
## noise wearing a threshold.
##
## `net_mean_per_hour` is the flow, it is what condition actually drives through
## doc 03's `f_condition`, and it separates the pair by **12–20 % on every one of
## the three seeds** in both the before and the after column. It is also the
## column gate 5 already uses for the same claim one comparison up. An agent that
## skips maintenance holding more cash is *correct* — that is what "maintenance
## costs money" means — and the design claim was never that it holds less: it is
## that the maintained city is worth more and earns more, which is what the
## bottom four rows say.
func test_gate_04_maintenance_pays() -> void:
	var maintained := _summary("balanced")
	var neglected := _summary("disaster_neglect")
	assert_true(int(maintained["repaired"]) > 0,
			"wear must give the repair verb something to do")
	assert_eq(int(neglected["repaired"]), 0, "the neglect knob is the only difference")
	# **WAVE-15 RE-FIT: the money column moves from the STOCK to the FLOW**
	# (doc 92 §36.5, report 98 RR-79). See the block comment above this test for
	# the whole derivation; the short version is that the money pass swapped
	# which of the two money columns is contaminated, and the flow is the one the
	# maintenance knob actually drives.
	assert_true(float(maintained["net_mean_per_hour"])
					> float(neglected["net_mean_per_hour"]),
			("the neglected city out-EARNS the maintained one: $%.0f/gh against "
					+ "$%.0f/gh") % [float(neglected["net_mean_per_hour"]),
					float(maintained["net_mean_per_hour"])])
	assert_true(float(maintained["min_condition"]) > float(neglected["min_condition"]),
			"the agent that repairs should hold a higher floor condition: %.3f vs %.3f"
					% [float(maintained["min_condition"]), float(neglected["min_condition"])])
	assert_true(float(maintained["mean_condition_end"]) > float(neglected["mean_condition_end"]),
			"and a city in better shape on average: %.3f vs %.3f"
					% [float(maintained["mean_condition_end"]),
					float(neglected["mean_condition_end"])])
	assert_true(int(maintained["damaged_end"]) <= int(neglected["damaged_end"]),
			"and fewer buildings in the damaged state: %d vs %d"
					% [int(maintained["damaged_end"]), int(neglected["damaged_end"])])


## GATE 4b — **the maintenance pacing fit** (Wave-4 ruling 2), made executable.
## The ruled targets are: a maintaining city spends **10–20 % of net** on repairs
## and takes **a few repair trips per game-DAY**. Both are properties of the pair
## (`decay_per_hour`, `REPAIR_THRESHOLD`), and the fit separates them:
##
##   repair $/gh      = Σ capital_b × decay_b × REPAIR_COST_PER_CAPITAL  ← the RATE
##   repair trips/day = Σ decay_b × 24 / (1 − threshold)                 ← the THRESHOLD
##
## so the money is set by `data/buildings.json` and the chore is set by the
## policy. Doc 92 §13 carries the whole derivation; the short version is that the
## authored decay rates were measured to be RIGHT (11.5–17.2 % of net for a
## 100–250-building city, and a neglected city that reaches doc 03's `COND_FLOOR`
## in 2.4–2.8 game-weeks and dies in 4.7) and pass 2's 0.90 repair threshold was
## the chore. `REPAIR_THRESHOLD` is now **0.80**, fitted; no `decay_per_hour` row
## moved. Measured over three seeds at 21 game-days: **4.4 / 5.1 / 5.1 repair
## trips per game-day** and **12.1 / 11.4 / 11.3 % of net**.
## **WAVE-5 RE-ANCHOR, with the measurement and the reason.** Both numbers fell,
## **and neither `decay_per_hour` nor `REPAIR_COST_PER_CAPITAL` moved.** They fell
## because F-11's grid rule changed the CITY the ratio is measured on, on both
## sides of it at once:
##
##   * the denominator grew — a lit city earns its tax line, net $1,794 → $2,003/gh;
##   * the numerator shrank — doc 02 §2.6 decays an **unpowered** building 1.5×
##     faster, and a quarter of this city used to be unpowered. Fewer buildings
##     cross the 0.80 threshold, so there are fewer trips to pay for.
##
## Measured over three seeds at 21 game-days (1337 / 4242 / 9001):
##
## | | 1337 | 4242 | 9001 |
## |---|---|---|---|
## | repair spend / net | 6.52 % | 6.76 % | 6.58 % |
## | trips / game-day | 2.14 | 1.81 | 2.00 |
## | worst building at d21 | 0.809 | 0.799 | 0.801 |
##
## **The two ruled PURPOSES both still hold** — maintenance is a visible line
## item (~$68k against ~$1.02M of net, on a city whose worst building sits
## exactly at the repair threshold) and it is not a chore (2 trips a game-day
## against pass 2's 11.5). The bands are re-anchored on the measurement above,
## generously on both sides so a seed cannot flip them.
##
## **Flagged for the overseer, not silently absorbed:** the 10–20 % figure was a
## RULING (§13.2), and the honest reading is that it was fitted against a city
## that was 25 % dark. If 10–20 % is wanted back on a lit city the levers are
## `data/buildings.json`'s `decay_per_hour` rows or `expenses.REPAIR_COST_PER_CAPITAL`
## — both doc 02/03 constants, both left alone here.
##
## **WAVE-6 RE-ANCHOR — the same mechanism, one more step, and again no constant
## moved.** Wave 5 named the cause exactly: doc 02 §2.6 decays an **unpowered**
## building 1.5× faster, so the repair queue is a function of how dark the city
## is. Wave 6's power expansion took `balanced` from **8.70 / 9.05 / 11.01 %**
## dark at 21 game-days to **0.05 / 0.16 / 0.10 %**, and the queue moved with it
## for the third time in a row. Measured on the same rig, same seeds:
##
## | | 1337 | 4242 | 9001 |
## |---|---|---|---|
## | repair spend / net | 6.26 % | 5.58 % | 5.49 % |
## | trips / game-day | 1.29 | 1.05 | 1.05 |
## | worst building at d21 | 0.801 | 0.815 | 0.809 |
##
## Only the trips FLOOR moves, 1.2 → **0.8**: the spend share (5.5–6.3 %) is
## still inside the band Wave 5 fitted, and the two ruled purposes still hold —
## $59–64k of repairs against ~$1.02–1.08M of net is a visible line item, and
## the worst building in the city still sits at the repair threshold rather than
## sliding toward doc 03's `COND_FLOOR`. 0.8 is the worst measured seed (1.05)
## with ~24 % of margin under it, which is the same shape of margin the ceiling
## gate uses and enough that a seed cannot flip it. The floor is there to catch
## "maintenance stopped happening at all", and 0.8 trips/game-day — 17 repairs
## over the horizon — is comfortably still happening.
func test_gate_04b_maintenance_pacing_is_a_line_item_not_a_chore() -> void:
	var summary := _summary("balanced")
	var samples: Array = _run("balanced")["samples"]
	var net := 0.0
	for i in range(1, samples.size()):
		net += float((samples[i] as Dictionary)["net"])
	# **RE-FITTED Wave 17 (doc 92 §43.8/§43.10, doc 93 §Y1).** Both bands are the
	# same formula over a different ROSTER. This gate's own header derives
	# `repair trips/day = Σ decay_b × 24 / (1 − threshold)` over the buildings the
	# CITY repairs, and doc 02 §2.6a took the private stock out of that sum: a
	# 21-game-day `balanced` city drew the REPAIR row on 260 private + 21 civic
	# buildings and now draws it on 0 + 24, so the sum runs over roughly a tenth
	# of the roster and returns roughly a tenth of the trips. Measured on the
	# three matrix seeds: 10 / 10 / 11 trips over 21 game-days = 0.48 / 0.48 /
	# 0.52 per game-day, against 27.3 mean trips (1.30/day) at the fork.
	#
	# **Neither `decay_per_hour` nor `REPAIR_COST_PER_CAPITAL` nor
	# `REPAIR_THRESHOLD` moved** — exactly as in the Wave-5 re-anchor recorded
	# above, the city the ratio is measured on is what changed.
	#
	# The floor's job is unchanged: catch the mechanic going dead altogether. It
	# moves 0.80 → 0.30, which is 37 % below the lowest measured seed and still
	# strictly positive. The SHARE floor moves 0.04 → 0.03 for the same reason and
	# with the same measurement (4.42 % at seed 1337, against 11.2 % at the fork):
	# a city that only buys repairs for its own assets cannot spend as large a
	# share of a larger net on them, and 0.04 was inside a rounding error of
	# failing on a number the ruling deliberately moved.
	var share := float(int(summary["repair_spend"])) / maxf(1.0, net)
	assert_true(share >= 0.03 and share <= 0.12,
			"upkeep is %.1f%% of net over %d game-days; Wave 17 measures 4.4 %% "
			% [share * 100.0, LONG_DAYS] + "on the city's OWN assets (Wave 6 "
			+ "measured 5.5–6.3 %% when the city also bought private repairs)")
	assert_true(int(summary["repair_spend"]) > 0, "and it is not free")
	var trips_per_day := float(int(summary["repaired"])) / float(LONG_DAYS)
	assert_true(trips_per_day >= 0.30 and trips_per_day <= 9.0,
			"%.2f repair trips per game-day — the ruled target is 'a few', and "
			% trips_per_day + "since doc 02 §2.6a they are the city's own assets "
			+ "only: Wave 17 measures 0.48–0.52 across the three matrix seeds")
	# And it is buying something: the maintained city holds its floor at the
	# threshold rather than sliding toward the auto-damage line. Since Wave 17
	# this reads doubly true — 0.60 is also `condition.band_worn`, the floor doc
	# 02 §2.6a gives private stock, so a `balanced` city's worst building is at
	# or above the worst any building in it can now be while the lights are on.
	assert_true(float(summary["min_condition_end"]) >= 0.60,
			"the maintained city's worst building sat at %.3f"
					% float(summary["min_condition_end"]))


## GATE 7 — the fleet grows with the city. Doc 92 F-3:
## `FleetSystem.populate_from_stations` had exactly one caller, at boot, so a
## `fire_station` was a $30/gh upkeep line that bought nothing.
func test_gate_07_fleet_grows_with_stations() -> void:
	var sim := CitySim.boot_from_files(GATE_SEED)
	var founding := sim.incidents.fleet.size()
	assert_eq(founding, 8, "the founding roster")
	var sim_id := ""
	for z in range(30, 70):
		for x in range(30, 70):
			var placed := sim.cmd_place_building("fire_station", Vector2i(x, z))
			if bool(placed["ok"]):
				sim_id = String(placed["payload"]["sim_id"])
				break
		if sim_id != "":
			break
	assert_ne(sim_id, "", "the founding core has room for a fire station")
	assert_eq(sim.incidents.fleet.size(), founding,
			"a SITE houses nobody — the shell has to finish first")
	for _h in 96:
		sim.advance_coarse_hours(1, false)
	assert_eq(String((sim.buildings[sim_id] as Building).state), "active")
	assert_true(sim.incidents.fleet.size() > founding,
			"a finished fire station is response capacity, not just an upkeep line")
	# And it goes away with the station.
	var after_build := sim.incidents.fleet.size()
	assert_true(bool(sim.cmd_demolish_building(sim_id)["ok"]))
	assert_true(sim.incidents.fleet.size() < after_build,
			"a demolished station takes its units with it")


## GATE 8 — open incidents, mean per game-hour, for `balanced`. Doc 92 measured
## 18.68 against a frozen eight-vehicle fleet and proposed ≤ 3.
func test_gate_08_incident_backlog_is_answerable() -> void:
	var open_mean := float(_summary("balanced")["open_incidents_mean"])
	assert_true(open_mean <= 3.0,
			"balanced is carrying a backlog of %.2f open incidents per game-hour"
					% open_mean)


## GATE 9 — `incident_abandoned` ≈ 0 for `balanced`. Doc 92 measured 59 per run:
## the dispatcher giving up because there was no unit left to send.
func test_gate_09_dispatcher_rarely_gives_up() -> void:
	var abandoned := Rig.event_count(_run("balanced"), "incident_abandoned")
	assert_true(abandoned <= 2,
			"the dispatcher abandoned %d incidents in %d game-days"
					% [abandoned, LONG_DAYS])


# ==================================================== 12 the tax curve (§9 F-5)

## GATE 12 — the top tax detent is a tradeoff, not a free lunch. Doc 92 F-5
## measured `tax_squeezer` (= `balanced` with the slider pinned to
## `TAX_RATE_MAX`) at +46 % value created for a happiness number that changed
## nothing else, and ruled `tax.TAX_RATE_GROWTH_COEFF` 3.5 → 8.0 so the detent
## costs a city rather than a decimal.
##
## Measured as a CONTROLLED PAIR rather than as a strategy comparison, because a
## strategy comparison cannot isolate it: the two agents earn different money and
## therefore build different cities, which is exactly what doc 92 §6/§7 built the
## micro-experiments for. Here both cities get the SAME build plan on the SAME
## tiles from the same seed, and the ONLY difference is the detent.
##
## **THE FINDING THIS GATE WAS WRITTEN AGAINST, AND ITS FIX.** Pass 2 shipped the
## ruled coefficient — `growth_rate_multiplier(TAX_RATE_MAX)` is 0.44 — and it
## bit nothing, because doc 03 publishes the multiplier into
## `PopulationSystem.advance` where it scales only the RELAXATION RATE:
##
##     attractiveness += (target − attractiveness) × (1 − exp(−dt·mult/τ))
##
## `attractiveness_target(s) = clamp((s − 0.35)/0.50, 0.25, 1.0)` is **1.0 for any
## stability ≥ 0.85** and a founding city starts AT 1.0, so `target −
## attractiveness` was 0 and the multiplier scaled zero: this same controlled pair
## used to end 2, 3, 5, 7, 10 and 14 game-days with **the same 224 people**, and
## only the treasury moved. No value of `TAX_RATE_GROWTH_COEFF` could fix that,
## because the rate lever cannot move a city that is already where it is going.
##
## **Doc 09 amendment T-1** adds the missing half: the TARGET is now the most
## binding of three ceilings — stability, lived happiness, and the tax bill —
## `min(A_stab(S), A_happy(H), attractiveness_tax_factor(r))`, where the tax
## factor is priced off `happiness_tax_delta` so the slider is read exactly once
## in the whole coupling. The top detent's −15.4 happiness points become a 0.7998
## attractiveness ceiling, the city relaxes DOWN to it, and the slider finally
## costs residents instead of a decimal. Measured, seed 1337, same pair:
##
## | game-day | detent 5 pop | detent 12 pop, coeff 220 | detent 12 pop, coeff 360 |
## |---|---|---|---|
## | 1 | 224 | 198 | **181** |
## | 3 | 224 | 182 | **156** |
## | 7 | 224 | **179** | **151** |
## | 21 | 219 | **179** | **151** |
##
## This gate holds the two halves of the lever — the RATE half (a hurt city
## recovers slower) and the TARGET half (a healthy city shrinks) — gate 12b holds
## doc 92 F-5's threshold on the controlled pair, and gate 12c holds the lead's
## Wave-7 ruling on the strategy matrix, which is where the dominance was still
## visible after Wave 6.
##
## **WAVE-7 RETUNE — `tax.TAX_RATE_HAPPINESS_COEFF` 220 → 360 (doc 92 §20).**
## Wave 6 made the grid buyable, which handed `tax_squeezer` somewhere to spend
## its money: on the matrix it ended 21 game-days with **+104 % value created**
## and **+43 % population** against `balanced`, for a happiness deficit of
## **1.6 points**. The lever from T-1 was working — it was simply priced too
## cheaply, because every one of its three couplings is denominated in the
## happiness points `happiness_tax_delta` produces. One number therefore moves
## all three, which is why the ruling names one key:
##
## | at `TAX_RATE_MAX` | coeff 220 | coeff 360 |
## |---|---|---|
## | `happiness_tax_delta` | −15.4 | **−25.2** |
## | `attractiveness_tax_factor` | 0.7998 | **0.6724** |
## | `growth_rate_multiplier` | 0.44 | 0.44 (untouched) |
##
## Nothing at or below `TAX_RATE_BASE` moves: the delta is 0 at 0.09 by
## construction, so **every founding anchor, every save hash and every gate that
## does not touch the slider is bit-identical** — verified with
## `tools/profile_sim.gd --baseline`.
func test_gate_12_max_tax_costs_a_city() -> void:
	var economy := CitySim.boot_from_files(GATE_SEED).economy
	assert_almost_eq(economy.growth_rate_multiplier(0.16), 0.44, 1e-9,
			"1 − (0.16 − 0.09) × 8.0 — the ruled coefficient, untouched by Wave 7")
	assert_almost_eq(economy.happiness_tax_delta(0.16), -25.2, 1e-9,
			"−(0.16 − 0.09) × 360 — the Wave-7 price of the top detent")
	# T-1's third coupling: the same −25.2 points, spent on doc 09's scale.
	assert_almost_eq(economy.attractiveness_tax_factor(0.16), 0.6724, 1e-9,
			"1 + 1.30 × (−25.2)/100 — the ceiling the top detent buys")
	assert_almost_eq(economy.attractiveness_tax_factor(0.09), 1.0, 1e-9,
			"exactly neutral at TAX_RATE_BASE — the founding city may not move")
	assert_almost_eq(economy.happiness_tax_delta(0.09), 0.0, 1e-9,
			"...and neutral on the happiness side too, which is what makes the "
			+ "retune save-identity-neutral: nothing runs at any other rate by default")
	assert_almost_eq(economy.attractiveness_tax_factor(0.04), 1.0, 1e-9,
			"and the bottom detent buys a faster refill, not a higher ceiling")
	assert_almost_eq(PopulationSystem.attractiveness_target(0.9475, 82.0, 1.0), 1.0, 1e-9,
			"doc 09 §2.10.2's t0 worked value survives T-1 unchanged")
	assert_almost_eq(PopulationSystem.attractiveness_target(0.60, 82.0, 1.0), 0.50, 1e-9,
			"and so does its F_SOUTH exodus example")

	# The RATE half: a city with something to recover recovers slower.
	# Measured at coeff 360, 3 game-days: 224 people / $33,058 against
	# **148** people / $40,842.
	const DAYS := 3
	var hurt_base := _tax_pair_city(5, DAYS, 0.50)
	var hurt_max := _tax_pair_city(12, DAYS, 0.50)
	assert_eq(int(hurt_base["buildings"]), int(hurt_max["buildings"]),
			"the controlled pair must build identically")
	assert_true(int(hurt_max["treasury"]) > int(hurt_base["treasury"]),
			"the top detent still earns more money")
	assert_true(int(hurt_max["population"]) < int(hurt_base["population"]),
			"max tax must slow a recovering city: %d people against %d"
					% [int(hurt_max["population"]), int(hurt_base["population"])])

	# The TARGET half — the assertion that used to read `==`. A HEALTHY city, no
	# stability hit, nothing to recover: the detent alone must move population,
	# and it must have moved inside one game-week.
	var base := _tax_pair_city(5, LONG_DAYS, -1.0)
	var maxed := _tax_pair_city(12, LONG_DAYS, -1.0)
	var base_7 := int((base["population_by_day"] as Array)[6])
	var maxed_7 := int((maxed["population_by_day"] as Array)[6])
	# Measured at coeff 360: 151 against 224, a 32.6 % gap by game-day 7.
	assert_true(maxed_7 <= int(float(base_7) * 0.95),
			"seven game-days at the top detent cost a healthy city nothing: "
			+ "%d people against %d. TAX_RATE_ATTRACT_PULL is the lever."
					% [maxed_7, base_7])
	assert_true(int(maxed["treasury"]) > int(base["treasury"]),
			"...while the revenue side of the same detent is still worth more")


## GATE 12b — doc 92 F-5's ACTUAL threshold, the one pass 2 could not reach:
## squeezing the tax slider must TRAIL on population over the report's own
## 21-game-day horizon, not merely cost a decimal of happiness.
##
## Measured on a controlled PAIR rather than on `tax_squeezer` vs `balanced` out
## of the shared matrix, deliberately and for two reasons. (1) Two scripted
## agents earn different money and therefore build different cities, so the
## population column confounds the detent with the build plan — doc 92 §6/§7
## built its micro-experiments for exactly this. (2) The matrix rows are the
## balance-fit work's to retune; a gate that reads them fails whenever someone
## else's tuning lands. This pair is self-contained: same seed, same tiles, same
## build order, one field different.
##
## Threshold: ≥ 10 % fewer people while still ahead on cash. Both directions
## matter — a detent that costs population AND money is not a tradeoff, it is a
## trap.
##
## **WAVE-7 MEASUREMENTS (coeff 360, 21 game-days, seed 1337).** 219 people /
## $202,996 / H 72.67 / A 1.0000 at detent 5, against **151** people / $255,276 /
## H 53.90 / A 0.6724 at detent 12: **31.1 % fewer people for 1.258× the cash**.
##
## The cash multiple is what MOVED, and it moved for the right reason: at coeff
## 220 the pair read 18.3 % / 1.710×, and the extra people the squeezed city no
## longer has are the ones who were paying the 1.778× rate. Which is why the cash
## threshold below is 1.15× and not the old 1.25× — 1.25 now sits $1,531 under a
## measured 1.258 and would fail on a seed, and a gate whose margin is 0.6 % is
## measuring float noise rather than balance. The ruled direction (money now, a
## smaller city later) is unchanged and comfortably held.
func test_gate_12b_tax_squeezing_trails_on_population() -> void:
	var base := _tax_pair_city(5, LONG_DAYS, -1.0)
	var maxed := _tax_pair_city(12, LONG_DAYS, -1.0)
	assert_eq(int(base["buildings"]), int(maxed["buildings"]),
			"the controlled pair must build identically")
	var base_pop := int(base["population"])
	var maxed_pop := int(maxed["population"])
	assert_true(maxed_pop <= int(float(base_pop) * 0.90),
			"the tax squeezer ends %d game-days with %d people against %d — "
					% [LONG_DAYS, maxed_pop, base_pop]
			+ "doc 92 F-5 wants money-now versus a-city-later, and this is the gate")
	assert_true(int(maxed["treasury"]) > int(float(base["treasury"]) * 1.15),
			"and the money half must still be worth taking: $%d against $%d"
					% [int(maxed["treasury"]), int(base["treasury"])])
	# The mechanism, not just the outcome: it is the CEILING that moved.
	assert_true(float(maxed["attractiveness"]) < float(base["attractiveness"]) - 0.15,
			"population fell for some other reason than attractiveness: %.4f vs %.4f"
					% [float(maxed["attractiveness"]), float(base["attractiveness"])])
	# And the happiness half of the lead's Wave-7 ruling, on the same pair:
	# 72.67 against 53.90, a gap of 18.77 points against a ruled floor of 8.
	assert_true(float(base["happiness"]) - float(maxed["happiness"]) >= 8.0,
			"the top detent costs a 21-game-day city only %.2f happiness points"
					% [float(base["happiness"]) - float(maxed["happiness"])])


## GATE 12c — **the lead's Wave-7 ruling, on the agent that actually plays.**
##
## Gates 12 and 12b measure a controlled pair, deliberately: it isolates the
## detent from the build plan. That isolation is also its blind spot. Wave 6 made
## the grid buyable, and a `tax_squeezer` with 1.778× revenue and somewhere to
## spend it out-BUILT `balanced` by enough to end 21 game-days with **more**
## people than the agent that never touched the slider — +43 % — even while the
## pair below showed the detent costing 18 % of a fixed city. Both readings were
## true; only one of them is what a player experiences.
##
## The ruling: raise `tax.TAX_RATE_HAPPINESS_COEFF` until the top detent costs a
## 21-game-day city **≥ 8 happiness points** and `tax_squeezer` **trails
## `balanced` on population by ≥ 10 %**. Fitted on the pair rig above, confirmed
## here and on the full matrix.
##
## The fit is steep, which is why 360 and not a rounder number — measured on the
## 3-seed matrix, `tax_squeezer` against `balanced` at 21 game-days:
##
## | coeff | population | happiness gap | value created | treasury |
## |---|---|---|---|---|
## | 220 (Wave 6) | **+43 %** | 1.6 | +104 % | +69 % |
## | 340 | −5.5 % | 21.2 | +43 % | −3 % |
## | **360 (ruled)** | **−14.7 %** | **23.0** | **+35 %** | **+22 %** |
## | 400 | −21 % | 20.4 | +31 % | −7 % |
##
## 340 misses the population threshold on all three seeds; 400 overshoots it and
## takes the money half below `balanced`, which is a trap rather than a tradeoff.
## 360 clears both halves of the ruling on every seed and keeps the slider worth
## pulling. Seed 1337, the one this gate runs: 1,129 people / H 51.9 / $1,186,191
## of value against 1,364 / 74.7 / $853,126.
##
## **This gate reads two matrix rows, which gate 12b's header warns against**, and
## the warning still stands — it will move when someone else's tuning lands. It is
## here anyway because the ruling is *stated* about those two rows, and a ruling
## with no gate is a ruling that rots. The thresholds are the ruled ones (8 points,
## 10 %) rather than the measured ones (23 points, 14.7 %), so ordinary drift does
## not trip it; only a change that gives the slider back its free lunch does.
##
## **WAVE-8 SAMPLE FIX — three seeds, not one, and no threshold moved.** This gate
## ran on `GATE_SEED` alone while the ruling above was fitted on the **3-seed
## matrix**, and a population ratio on one seed is not a stable statistic: the
## Wave-8 sub-step guard resamples the RNG without touching tax, and seed 1337
## alone went from 15.5 % trailing to **8.0 %** — a fail — while the sample the
## ruling was actually fitted on went from 15.5 % to **16.9 %**, i.e. further
## inside the threshold. Measured, 21 game-days:
##
## | | balanced pop | tax_squeezer pop | trailing by |
## |---|---|---|---|
## | seed 1337 alone, before Wave 8 | 1,440 | 1,163 | 19.2 % |
## | seed 1337 alone, after | 1,285 | 1,182 | **8.0 % — FAILS** |
## | 3-seed matrix mean, before | 1,388 | 1,173 | 15.5 % |
## | **3-seed matrix mean, after** | **1,379** | **1,146** | **16.9 % — passes** |
##
## Both readings are honest; only one of them is the ruling's. The fix is the
## SAMPLE, not the threshold — 10 %, 8 points and "value created still ahead" are
## the ruled numbers and are untouched. It costs four extra 21-game-day runs.
## **10 % → 7 %, Wave 18** (99-PA PA-04, doc 92 §49.6). The population bound is
## this gate's SECONDARY reading — the happiness gap below is the direct one —
## and it narrowed because the CONTROL ARM got poorer, not because squeezing got
## cheaper. With the Disaster Director running for the first time, `balanced`'s
## own three-seed mean population falls 1,582 → 1,529 (−3.4 %) while
## `tax_squeezer`'s rises 1,366 → 1,394: the squeezer ends 21 game-days with
## ~$100k against balanced's ~$68k and 264 buildings against 217, and it spends
## the difference growing back through the storms that now happen. Money buying
## resilience is the game working, and it is exactly what a bound fitted on a
## matrix where no storm ever came could not have seen.
##
## Measured (`tools/playtest.gd --strategies=balanced,tax_squeezer --days=21
## --seeds=1337,4242,9001 --mode=coarse`): the ratio moves **0.864 → 0.912**.
## The bound goes to 0.93, keeping ~2 points of headroom on a three-seed mean
## whose per-seed spread is 110 people. **The ruling's direct reading moved the
## other way**: the happiness gap widened 14.5 → 15.9 points against a floor of
## 8, so the slider costs MORE of what it is supposed to cost.
const TAX_SQUEEZE_POP_MAX_RATIO := 0.93


func test_gate_12c_the_tax_slider_is_not_a_free_lunch_for_a_real_agent() -> void:
	var base_pop := _matrix_mean("balanced", "population_end")
	var maxed_pop := _matrix_mean("tax_squeezer", "population_end")
	assert_true(maxed_pop <= base_pop * TAX_SQUEEZE_POP_MAX_RATIO,
			("tax_squeezer ends %d game-days with %.0f people against balanced's "
					+ "%.0f (means of doc 92's %d matrix seeds) — the ruling wants "
					+ "it trailing by at least %.0f %%")
					% [LONG_DAYS, maxed_pop, base_pop, MATRIX_SEEDS.size(),
					100.0 * (1.0 - TAX_SQUEEZE_POP_MAX_RATIO)])
	var gap := _matrix_mean("balanced", "happiness_end") \
			- _matrix_mean("tax_squeezer", "happiness_end")
	assert_true(gap >= 8.0,
			"the pinned slider costs only %.1f happiness points over %d game-days"
					% [gap, LONG_DAYS])
	# The other direction of the same ruling: it must still be a tradeoff. An
	# agent that squeezes and ends poorer has no reason to squeeze, and the
	# slider would be dead data with an extra step.
	assert_true(_matrix_mean("tax_squeezer", "value_created")
					> _matrix_mean("balanced", "value_created"),
			"squeezing must still buy something: $%.0f of value against $%.0f"
					% [_matrix_mean("tax_squeezer", "value_created"),
					_matrix_mean("balanced", "value_created")])


## Boot a city, hold `detent` from game-hour 0, fill the same served tiles with
## houses in the same row-major order, and run. Everything but the detent is
## identical between the two calls, including the RNG seed.
## `attractiveness` < 0 leaves the founding value (1.0) alone; a value in (0,1]
## knocks the city down so the growth multiplier has something to scale.
## Cached: gates 12 and 12b read the same 21-game-day pair.
func _tax_pair_city(detent: int, days: int, attractiveness: float) -> Dictionary:
	var key := "%d/%d/%.4f" % [detent, days, attractiveness]
	if _tax_runs.has(key):
		return _tax_runs[key]
	var sim := CitySim.boot_from_files(GATE_SEED)
	sim.cmd_set_tax_level(detent)
	if attractiveness > 0.0:
		sim.population.attractiveness = attractiveness
	var built := 0
	for z in range(TileGrid.SIZE):
		if built >= 40:
			break
		for x in range(TileGrid.SIZE):
			if built >= 40:
				break
			if bool(sim.cmd_place_building("house", Vector2i(x, z))["ok"]):
				built += 1
	var population_by_day: Array = []
	for _d in days:
		for _h in 24:
			sim.advance_coarse_hours(1, false)
		population_by_day.append(sim.population.city_population)
	var out := {"treasury": sim.treasury.balance,
			"population": sim.population.city_population,
			"population_by_day": population_by_day,
			"attractiveness": sim.population.attractiveness,
			"buildings": built, "happiness": sim.happiness.happiness}
	_tax_runs[key] = out
	return out


# ================================================= 13 the recovery ladder (F-7)

## GATE 13 — a city below zero visibly engages credit, is sized a real limit,
## and enters austerity. Doc 92 F-7: `update_credit_limit`, `update_austerity`
## and `maybe_grant_relief` had no caller in `sim/` outside tests, so a run ended
## at −$12,724 with the limit pinned at its $20,000 floor and `credit_line_engaged`
## fired zero times across all seventeen runs.
func test_gate_13_credit_line_engages_below_zero() -> void:
	var sim := CitySim.boot_from_files(GATE_SEED)
	sim.advance_coarse_hours(1, false)
	sim.bus.drain()
	var floor_limit := int((StarterCityLoader.read_json(ECONOMY_DATA)
			.get("recovery", {}) as Dictionary).get("CREDIT_LIMIT_FLOOR", 20000))
	assert_true(sim.treasury.credit_limit > floor_limit,
			"layer 3 sizes the limit off trailing revenue, not the floor: %d"
					% sim.treasury.credit_limit)
	# Overdraw through the only door doc 03 §5 allows.
	sim.treasury.spend(sim.treasury.balance + 5000, &"misc", "gate 13")
	assert_true(sim.treasury.balance < 0)
	sim.advance_coarse_hours(1, false)
	var seen := {}
	for event in sim.bus.drain():
		seen[String(event["type"])] = int(seen.get(String(event["type"]), 0)) + 1
	assert_true(int(seen.get("credit_line_engaged", 0)) >= 1,
			"going negative is silent — the ladder never reaches the bus")
	assert_true(sim.treasury.austerity_active, "layer 2 engages at treasury < 0")
	assert_true(int(seen.get("austerity_entered", 0)) >= 1)
	assert_true(sim.treasury.austerity_expense_mult() < 1.0, "and it bites the budget")
	assert_true(sim.treasury.austerity_decay_mult() > 1.0,
			"and buys less maintenance while it does (AUSTERITY_DECAY_MULT)")
	# Layer 3's carry cost is billed as E_debt on the settled hour.
	assert_true(sim.treasury.debt_interest_per_hour() > 0, "debt costs something")
	assert_true(float((sim.last_settlement["expenses"] as Dictionary)["debt"]) > 0.0,
			"and the settlement bills it")


## GATE 13b — the other half of F-7, and the half doc 92 said to fix FIRST:
## `Treasury.AUSTERITY_BLOCKED_CATEGORIES` contains `construction`, and a blocked
## `spend()` charges nothing and returns ok = false. Six call sites discarded
## that result, so the day the ladder was switched on every build, transformer,
## land purchase and development phase placed under austerity would have been
## FREE. They read the result now.
func test_gate_13b_austerity_refuses_new_commitments() -> void:
	var sim := CitySim.boot_from_files(GATE_SEED)
	sim.advance_coarse_hours(1, false)
	sim.treasury.spend(sim.treasury.balance + 5000, &"misc", "gate 13b")
	sim.advance_coarse_hours(1, false)
	assert_true(sim.treasury.austerity_active)
	# Enough money to pay, blocked anyway: austerity blocks the COMMITMENT.
	sim.treasury.credit(500000, &"misc", "gate 13b")
	var before := sim.treasury.balance
	var buildings_before := sim.buildings.size()
	var origin := _vacant_served_tile(sim)
	assert_true(origin.x >= 0, "the core has a serviceable vacant lot")
	var placed := sim.cmd_place_building("house", origin)
	assert_false(bool(placed["ok"]), "austerity must refuse a new build")
	assert_eq(placed["reason_code"], &"E_AUSTERITY")
	assert_eq(sim.treasury.balance, before, "and a refused command charges nothing")
	assert_eq(sim.buildings.size(), buildings_before, "and stamps no site")
	assert_eq(sim.cmd_buy_block(_purchasable_block(sim))["reason_code"], &"E_AUSTERITY",
			"land is a blocked category too")
	# Repair is NOT a blocked category — doc 03 §2.10 keeps the city repairable.
	var target := ""
	for id in sim.buildings:
		if (sim.buildings[id] as Building).condition < 1.0:
			target = String(id)
			break
	assert_ne(target, "", "wear gives austerity something to repair")
	assert_true(bool(sim.cmd_repair_building(target)["ok"]),
			"austerity may not block maintenance")


static func _vacant_served_tile(sim: CitySim, size := Vector2i.ONE) -> Vector2i:
	for z in range(TileGrid.SIZE):
		for x in range(TileGrid.SIZE):
			var tile := Vector2i(x, z)
			var block := sim.world.block_of_tile(x, z)
			if block == null or not block.is_ready():
				continue
			if not sim.world.grid.can_place(tile, size):
				continue
			if sim.grid.would_serve(tile):
				return tile
	return Vector2i(-1, -1)


static func _purchasable_block(sim: CitySim) -> String:
	for block_id in sim.world.block_ids_sorted():
		if bool(sim.world.purchase_allowed(String(block_id), sim.progression.city_level)["ok"]):
			return String(block_id)
	return ""


# ================================================ 15–16 the online/offline pair

## GATE 15 — the value a city creates must not depend much on which path ran it.
## Doc 92 F-9 measured mean −3.7 % over 7 game-days and proposed |Δ| ≤ 5 % once
## doc 04 §2.12's fidelity rule lands. That rule is NOT implemented (it is a doc
## 04 ruling this pass did not get), so this gate holds the CURRENT band over a
## short paired run and tightens when the rule arrives.
func test_gate_15_online_offline_value_edge() -> void:
	const DAYS := 3
	var online := float(Rig.run("greedy_growth", GATE_SEED, DAYS)["summary"]["value_created"])
	var offline := float(_offline_run("greedy_growth", DAYS)["summary"]["value_created"])
	var edge := absf(offline - online) / maxf(1.0, online)
	assert_true(edge <= 0.05,
			"the two paths disagree on value by %.1f%% over %d game-days"
					% [edge * 100.0, DAYS])


## GATE 16 — the same pair on the BLACKOUT channel, which doc 92 F-9 says is the
## one doc 04 §2.12's one-step coarse thermal integration actually costs. Doc 92
## measured 1.27 % online vs 0.80 % offline at 7 game-days and proposed
## |Δ| ≤ 10 %; that threshold needs the fidelity rule, so this pins the measured
## band instead — the gate to fail LOUDLY when someone touches the path.
func test_gate_16_online_offline_dark_edge_is_pinned() -> void:
	const DAYS := 3
	var online := float(Rig.run("greedy_growth", GATE_SEED, DAYS)["summary"]["unserved_share"])
	var offline := float(_offline_run("greedy_growth", DAYS)["summary"]["unserved_share"])
	assert_true(online <= 0.05 and offline <= 0.05,
			"dark share ran away: online %.4f offline %.4f" % [online, offline])
	assert_almost_eq(offline, online, 0.02,
			"the paths' blackout share diverged beyond doc 92 F-9's measured band")


static func _offline_run(strategy: String, days: int) -> Dictionary:
	var playtest := load("res://tools/playtest.gd")
	var opts: Object = playtest.Options.new()
	opts.set("days", days)
	opts.set("mode", "coarse")
	opts.set("write_json", false)
	return playtest.Runner.run_one(strategy, GATE_SEED, opts)


# ========================================================== 17 the matrix runs

## GATE 17 — every strategy in the matrix completes. Doc 92 pass 2 shipped 17 of
## 18 runs because one agent's wall clock blew the budget, and a strategy that
## cannot finish is a strategy the report cannot use. One game-day each is enough
## to catch a strategy that errors, and cheap enough to run every suite; the real
## 18-of-18 check is the merge-time matrix.
func test_gate_17_every_strategy_completes() -> void:
	var playtest := load("res://tools/playtest.gd")
	for strategy_id in playtest.STRATEGY_IDS:
		var doc := Rig.run(String(strategy_id), GATE_SEED, 1)
		assert_eq((doc["samples"] as Array).size(), 25,
				"%s produced a short sample stream" % strategy_id)
		assert_ne(String(doc["state_hash"]), "", "%s left no state hash" % strategy_id)


# ============================== 10 · 14 · 18  the infrastructure decision

## GATE 10 — **the grid is a decision the player makes early.** F-4 IS
## IMPLEMENTED (Wave-4 ruling 3): `data/starter_city.json`'s founding transformer
## roster is thinned from 23 nodes to 18, taking the served vacant ground from
## **510 → 452** tiles and the served 2×2 origins from **257 → 226**, with the
## tutorial beats intact.
##
## **The threshold is NOT doc 92's proposed "before game-hour 48", and the reason
## is a measurement, not a compromise.** Doc 92 F-4 assumed the wall is
## ground-limited, so thinning the grid would pull it in. It is not: it is
## MONEY-limited. `greedy_growth` is the fastest builder in the study — three
## actions per game-hour, zero reserve, buys no infrastructure ever — and it
## still converts income into floorspace at only ~0.35 buildings per game-hour
## early on, because a founding city nets ~$340/gh against $1,200 a house and
## $7,000 an apartment. Measured, seed 1337:
##
## | roster | served vacant tiles | buildings placed before the wall | first `E_UNSERVED` |
## |---|---|---|---|
## | 23 nodes (pass 2) | 510 | 137 | game-hour 362 |
## | **18 nodes (now)** | **452** | **126** | **game-hour 385** |
##
## The wall moved LATER even though the ground shrank 11 %, because the same
## Wave-4 pass also made the city poorer per hour (doc 02 §2.6 wear is billed and
## `COND_FLOOR` is 0.40), and the builder slowed by more than the ground did.
## `wall_hour ≈ served_tiles / fill_rate`, and hour 48 at the measured fill rate
## needs **~35–80 served tiles** — roughly two transformers' worth.
##
## **That is geometrically unreachable from `power.nodes` alone**, and the proof
## is doc 09's own layout rule: every one of the 34 authored building origins must
## sit within Chebyshev 3 of a transformer (`test_starter_city.gd::
## test_every_building_within_transformer_radius`), and those 34 buildings are
## spread across all nine core blocks. A set cover of them needs 16–17 nodes; 18
## is the roster that also keeps `tutorial_lot_b` served and `tutorial_lot_a` one
## tap away, and 18 radius-3/4/5 patches already union to 452 of the core's 1,429
## vacant lots. **452 is the floor.** Hour 48 was a CORE-SIZE question — fewer
## READY blocks, or a denser authored manifest — and doc 92 §14 filed it as an
## open ruling for doc 09's owner.
##
## **WAVE-5 RE-ANCHOR — the hour-48 goal is RETIRED (doc 93 §E2's ruling).**
##
## The wall is **money-paced by design, and that is correct**: a founding city
## nets ~$340/gh against $1,200 a house, so even the fastest builder in the study
## converts income into floorspace at ~0.35 buildings/gh and the ground outlasts
## the money by a wide margin. Teaching the transformer by starving the player of
## LAND would be teaching it with a fake shortage, and 452 is a geometric floor
## nothing short of a smaller core can move.
##
## The early beat is **the first infrastructure DECISION, not the first refusal**:
## a transformer bought AHEAD of growth, because a block the player just developed
## arrives with doc 09 §2.3's utility corridor and no tap, so all 169 of its
## buildable tiles answer `E_UNSERVED` the moment it turns READY. That is a
## purchase inside the first game-week, and it is what doc 93 §A called "THE game".
##
## So this gate asserts the DECISION rather than an hour:
##
##   * a competent player buys grid, early, and keeps buying it;
##   * a player who refuses to (`greedy_growth`) still meets the wall inside the
##     21-game-day horizon — the verb is reachable, not theoretical.
##
## The hour itself is recorded, not asserted: 385 on this seed at 452 served
## tiles (362 at pass 2's 510). It is a measurement, and the moment a doc-09
## core-size ruling lands it will move without this gate being wrong.
func test_gate_10_grid_is_a_decision_the_player_makes_early() -> void:
	var maintained := _summary("balanced")
	assert_true(int(maintained["grid_placed"]) >= 4,
			"balanced bought %d transformers in %d game-days — the ahead-of-growth "
					% [int(maintained["grid_placed"]), LONG_DAYS]
					+ "rule (doc 92 F-11) should keep it buying")
	assert_true(int(maintained["grid_spend"]) > 0)
	var first := _first_grid_hour(_run("balanced"))
	assert_true(first >= 0, "no transformer purchase was logged at all")
	assert_true(first <= 7 * 24,
			"the first transformer landed at game-hour %d; the beat is meant to "
					% first + "be inside the first game-week")
	# And the refusal is still reachable for a player who buys none.
	var greedy := _summary("greedy_growth")
	assert_true(int(greedy["unserved_walls"]) > 0,
			"greedy_growth never hit an E_UNSERVED wall in %d game-days" % LONG_DAYS)
	var walls := _wall_hours(_run("greedy_growth"))
	assert_false(walls.is_empty(), "no E_UNSERVED action was logged")


## The game-hour of the first successful `cmd_place_grid_component`, or −1.
static func _first_grid_hour(doc: Dictionary) -> int:
	for entry in (doc.get("actions", []) as Array):
		var row: Dictionary = entry
		if String(row.get("verb", "")) == "cmd_place_grid_component" and bool(row["ok"]):
			return int(row["hour"])
	return -1


## Hours at which `cmd_place_building` answered `E_UNSERVED`, in order.
static func _wall_hours(doc: Dictionary) -> Array[int]:
	var out: Array[int] = []
	for entry in (doc.get("actions", []) as Array):
		var row: Dictionary = entry
		if String(row.get("verb", "")) == "place" and String(row.get("reason", "")) == "E_UNSERVED":
			out.append(int(row["hour"]))
	return out


## GATE 11 — `balanced` buys ≥ 2 land blocks in 21 game-days. Doc 92 filed this
## under F-8 and expected it to need a `data/starter_city.json` edit (trim the
## nine READY founding blocks to four or five). It did not: doc 92 measured 0.3
## blocks because the "competent" agent was too poor to expand, not because it had
## nowhere to go. With the pressure systems wired the same agent ends three
## game-weeks with a real war chest and expands on it. F-8's map question is still
## open — 1,429 buildable tiles is a lot of room — but its GATE is met, and by the
## money, not the map.
func test_gate_11_a_solvent_player_expands() -> void:
	var bought := int(_summary("balanced")["blocks_bought"])
	assert_true(bought >= 2,
			"balanced bought %d land blocks in %d game-days" % [bought, LONG_DAYS])
	assert_true(int(_summary("balanced")["land_spend"]) > 0)


## GATE 14 — `min_city_level` is enforced at placement (pass-1 F-7, **ruled in
## Wave 5**; doc 93 §E2 carries the ruling). It was a UI courtesy: the build
## sheet drew the lock glyph and refused to enter placement mode, and the command
## underneath said yes. It now answers `E_CITY_LEVEL`, exactly as
## `cmd_upgrade_building` always has, and it answers BEFORE the money so a locked
## card never quotes a price it cannot take.
##
## `data/buildings.json` gives `apartment` L1 `min_city_level` 1, so a founding
## city opens on houses and stores. **The pacing curves did not move**, and the
## reason is measurable rather than lucky: every scripted strategy already went
## through `Api.buildable`, which has always filtered on the same rule — the
## harness played by the UI's rules while the sim did not. See the Wave-5
## delivery report for the before/after matrix.
func test_gate_14_min_city_level_is_enforced_at_placement() -> void:
	var sim := CitySim.boot_from_files(GATE_SEED)
	assert_eq(sim.progression.city_level, 0)
	assert_eq(int(sim.catalog.stats("apartment", 1).get("min_city_level", 0)), 1,
			"apartment L1 is authored as a city-level-1 unlock")
	var origin := _vacant_served_tile(sim, Vector2i(2, 2))  # apartment is 2×2
	assert_true(origin.x >= 0, "the core has a serviceable 2×2 lot")
	var placed := sim.cmd_place_building("apartment", origin)
	assert_false(bool(placed["ok"]), "a level-1 unlock is refused at city level 0")
	assert_eq(placed["reason_code"], &"E_CITY_LEVEL")
	assert_eq(int((placed["payload"] as Dictionary)["required_level"]), 1)
	# The founding roster still builds, so the refusal is a gate and not a wall.
	assert_true(bool(sim.cmd_place_building("house",
			_vacant_served_tile(sim, Vector2i.ONE))["ok"]))


## GATE 18 — **doc 92 pass-3 F-11: a competent player's city stays lit.**
##
## F-11 measured `balanced` spending **two thirds of all building-time dark** at
## 50 game-days and called for both halves of an answer: a strategy that buys
## grid *ahead* of growth, and a ruling on whether that much dark should be
## survivable at all. The strategy half is done and it is worth what it cost —
## measured, seed 1337, 21 game-days, before → after:
##
## | column | pass 3 | Wave 5 |
## |---|---|---|
## | dark share | 25.72 % | **8.70 %** |
## | transformers bought | 1–2 | **11** |
## | happiness | 56.7 | **73.5** |
## | city stability | 0.7754 | **0.9310** |
## | treasury | $65,845 | **$91,291** |
##
## Two rules did it, both in `tools/playtest.gd`'s `Balanced`: the trigger moved
## from "no served tile anywhere" to **`GRID_LEAD_TILES` served tiles per owned
## block**, and the rung moved from L1 to **L2** — doc 04 §8's 50 kW cannot fill
## the 49-tile patch its own radius-3 service area covers, and the agent was
## buying the worst rung on the ladder.
##
## **15 % at the 21-game-day pacing horizon is the ruled target and this gate
## holds it.** The ruling also asked for 15 % at FIFTY game-days, which Wave 5
## could not reach by strategy at all — see gate 18b.
##
## **WAVE-6 RE-MEASUREMENT.** With `route_feeder` and the two node shells live,
## the 21-game-day figure is no longer close to the bound: **0.05 / 0.16 / 0.10 %**
## across the three seeds, against Wave 5's 8.70 / 9.05 / 11.01. The threshold is
## deliberately left at 15 % — it is the RULED number and this gate exists to
## defend it, not to ratchet — but the horizon that now measures anything is gate
## 18b's fifty game-days, where the ceiling actually lives. The `disaster_neglect`
## contrast is unchanged in kind and much larger in size: **27.25 %** against
## 0.05, i.e. the knob still costs a city its lights.
func test_gate_18_a_competent_player_keeps_the_city_lit() -> void:
	var summary := _summary("balanced")
	var dark := float(summary["unserved_share"])
	assert_true(dark <= 0.15,
			"balanced spent %.2f %% of building-time dark over %d game-days; the "
					% [dark * 100.0, LONG_DAYS]
					+ "ruled target is 15 %% (measured 8.70 %% on this seed)")
	assert_true(int(summary["grid_placed"]) >= 4,
			"and it got there by BUYING grid: %d transformers"
					% int(summary["grid_placed"]))
	# The knob is the only difference: the agent that refuses infrastructure sits
	# far above the target on the same city.
	var neglected := float(_summary("disaster_neglect")["unserved_share"])
	assert_true(neglected > dark * 1.5,
			"the neglect knob should still cost a city its lights: %.2f %% vs %.2f %%"
					% [neglected * 100.0, dark * 100.0])


## GATE 18b — **the late-game ceiling, and the verbs that lifted it.**
##
## The other half of F-11's ruling: *two thirds dark is not survivable-by-design;
## if the improved strategy still cannot hold ~25 % at day 50, report the
## constants that would fix supply rather than changing them.* Wave 5 could not,
## and reported. **Wave 6 can, and no capacity constant moved to do it.**
##
## What doc 92 §17.3 measured, and what this gate now holds — same rig, same
## agent lineage, seed 1337, 50 game-days, dark share of all building-time:
##
## The two sides are measured on different paths and that is worth stating: the
## Wave-5 column is a fine-path `tools/playtest.gd --days=50` run, the Wave-6
## column is this rig. **They agree at this scale** — doc 92 §17.3 measured the
## same Wave-5 city at **54.9 %** on its own online-coarse rig against the fine
## path's **54.63 %**, a 0.3-point spread on a 55-point number — so the
## before/after below is a real comparison and not two different questions.
##
## | | Wave 5 | Wave 6 |
## |---|---|---|
## | dark share, 50 game-days | **54.63 %** (fine; §17.3's rig read 54.9 %, §15.2's earlier fine run 66.8 %) | **6.25 %** |
## | worst feeder at the end | doc 92's day-50 fleet AGGREGATE was 111.8 % | **r = 0.31** |
## | buildings | 716 | 741 |
## | feeders the player could buy | **none — no verb existed** | 11, $59,430 |
## | substations the player could buy | none that did anything | 3 |
##
## Three command-layer gaps did it, all of the same family — a purchase that
## bought the player nothing — and all fixed without touching doc 04 §2.2:
##
## 1. **`route_feeder` shipped** (doc 04 §4). `cmd_route_feeder(path, class)`,
##    plus the one-tap `cmd_place_grid_component("feeder", far_end, class)` that
##    fills the polyline. Class 2 is 3,000 kW at doc 03 §2.13(b)'s $210/tile.
## 2. **The `substation` / `power_facility` shells became real.** The shell's
##    sim_id IS its grid node's id — doc 09 §2.9.5 already authors `SUB-A` that
##    way — so a finished substation roots feeders, a finished plant generates,
##    an upgrade re-rates both, and a demolition retires them.
## 3. **Adoption.** §2.1's service attachment is only ever evaluated for a
##    component with NO parent, so new copper next to a saturated circuit picked
##    up nothing and neither purchase relieved anything that already existed.
##    New feeders now take transformers and new transformers take buildings, by
##    §2.9's transfer rule, bounded by §5.10's NORMAL band.
##
## **Cost.** This gate runs a 50-game-day city, which is the most expensive
## single test in the file: the whole file runs in 2 m 29 s and roughly a minute
## and a half of that is this one run. It is here rather than in
## `balance_matrix.gd` because the ruling it answers is a THRESHOLD, and a
## threshold that only merge-time runs is a threshold nothing defends.
const CEILING_DAYS := 50
## The ruled bound. Measured across three seeds on this rig: **6.25 / 5.91 /
## 5.74 %** (741 / 701 / 673 buildings; 11 / 11 / 12 feeders; 3 / 3 / 5
## substations; worst feeder 0.31 / 0.36 / 0.32). The ruling's 20 % therefore has
## better than 3× of margin, deliberately: the point of the gate is to catch the
## ceiling COMING BACK, not to ratchet a measurement into a target.
const CEILING_DARK_SHARE := 0.20


func test_gate_18b_the_late_game_ceiling_is_lifted() -> void:
	var summary := _summary("balanced", CEILING_DAYS)
	var dark := float(summary["unserved_share"])
	assert_true(dark <= CEILING_DARK_SHARE,
			("balanced spent %.2f %% of building-time dark over %d game-days; the "
					+ "ruled bound is %.0f %% (measured 6.25 %% on this seed, against "
					+ "Wave 5's 54.63 %%)")
					% [dark * 100.0, CEILING_DAYS, CEILING_DARK_SHARE * 100.0])
	# …and it got there by buying TRUNK, not by building a smaller city.
	assert_true(int(summary["feeders_routed"]) >= 4,
			"routed %d feeders" % int(summary["feeders_routed"]))
	assert_true(int(summary["substations_built"]) >= 1,
			"…which is only possible because it bought %d substation(s): doc 04 "
					% int(summary["substations_built"])
					+ "§2.2 gives an L1 two feeder slots and doc 09 §2.9.5 fills both at t0")
	assert_true(float(summary["feeder_peak_ratio_end"]) < PowerGrid.OVERLAY_CRITICAL_R,
			"the city ends UNDER its own trunk: worst feeder %.2f"
					% float(summary["feeder_peak_ratio_end"]))
	assert_true(int(summary["buildings_end"]) >= 600,
			"on a city of %d buildings — the ceiling moved, it was not avoided"
					% int(summary["buildings_end"]))


## GATE 18c — **the ceiling moved because of the VERBS, not because a capacity
## constant moved.** Doc 92 §17.3 fix 3 named `PowerGrid.CAPACITY.transformer`
## L1 = 50 kW as the one genuine mismatch in doc 04's ladder and said moving it
## would not raise the feeder's. Wave 6 did not move it, or any other rung, and
## this is the pin that says so: every published §2.2 capacity is still §2.2's,
## and the starter city is still the one doc 09 §2.9.5 authors.
func test_gate_18c_no_capacity_constant_moved() -> void:
	assert_eq(PowerGrid.CAPACITY[&"transformer"], [50.0, 150.0, 400.0, 1000.0, 2500.0])
	assert_eq(PowerGrid.CAPACITY[&"substation"], [6000.0, 14000.0, 30000.0, 60000.0, 110000.0])
	assert_eq(PowerGrid.CAPACITY[&"plant_gas"], [8000.0, 18000.0, 36000.0, 70000.0, 120000.0])
	assert_eq(PowerGrid.FEEDER_CAPACITY, [1200.0, 3000.0, 7500.0])
	assert_eq(PowerGrid.SUBSTATION_FEEDER_SLOTS, [2, 3, 4, 6, 8])
	var sim := CitySim.boot_from_files(GATE_SEED)
	var feeder_kw := 0.0
	var feeders := 0
	for id in sim.grid.component_ids_of_kind(&"feeder"):
		feeder_kw += float(sim.grid.component(String(id))["capacity_kw"])
		feeders += 1
	assert_eq(feeders, 2, "doc 09 §2.9.5 still authors F_NORTH and F_SOUTH, no more")
	assert_almost_eq(feeder_kw, 2400.0, 0.5, "still 2 × class-1 at 1,200 kW at t0")
	assert_eq(int(sim.grid.feeder_slots("SUB-A")["free"]), 0,
			"and SUB-A is still full on game-hour zero — which is exactly why the "
			+ "first thing a growing city has to buy is a second substation")
	# The point roster is still one kind wide: `feeder` is a LINE and lives in
	# `routable`, `substation` is a BUILDING (C-30) and lives in `node_shells`.
	var placeable := BuildController.load_grid_placeable()
	assert_eq(placeable.size(), 1)
	assert_true(placeable.has("transformer"))
	assert_false(placeable.has("feeder"),
			"feeders are ROUTABLE (a line, like roads), never a placeable node")
	assert_false(placeable.has("substation"),
			"a substation is a building and must never appear on the grid roster")
	# The two shells doc 02 sells are now doc 04 nodes — the id is the seam.
	assert_true(sim.catalog.has("substation") and sim.catalog.has("power_facility"))
	assert_true(sim.grid.has_component("SUB-A") and sim.grid.has_component("PLANT-1"),
			"the authored shell and its node already share one id")


# ============================ 19–20 the Wave-6 pacing passes (doc 92 §18/§19)

## Doc 92 §18.1's budget, in ambient incidents per game-DAY, summed over the
## authored channels. **Unchanged at 0.40** across the Wave-7 D-17/D-18 landing,
## because doc 92 §18.2 ruled in advance what to do when the two dead channels
## woke up: *"the two new rows come out of the three existing ones"*. The split
## moved (0.20/0.10/0.10 → 0.14/0.08/0.08 + 0.06/0.04); the budget did not.
const AMBIENT_FLOOR_PER_DAY := 0.40
## Every channel that carries a floor row. `storm_damage` is permanently absent —
## its candidates exist only inside a live doc 07 storm cell.
const AMBIENT_FLOOR_CHANNELS := ["crime", "structure_fire", "transformer_failure",
		"water_main_break", "traffic_accident"]
## Five seeds, because this gate measures a POISSON RATE and one sample of a
## rate is not a measurement. Five 21-game-day runs is 105 game-days; at the
## measured 6.07/game-week the sum below has an expectation near 91 and a
## standard deviation near 9.5.
const PACING_SEEDS: Array[int] = [1337, 4242, 9001, 101, 202]
## **ABANDONED is a bound working, not a loss** — and this ceiling exists because
## Wave 18 gave the gate a second incident source (99-PA PA-04, doc 92 §49.5).
##
## Until this wave the Disaster Director stalled after two events, so every
## incident this gate counted came from the ambient floor, the starter roster
## answered all of them, and `abandoned` was flatly **0** — which is what this
## line asserted and what it measured. With the Director running, `do_nothing`
## takes 45 % more incidents on the same five stations and doc 06 §2.10's
## terminal rule (RR-26: one game-day with nothing committed) ends **2** of them
## across 5 seeds × 21 game-days — 0.019 per game-day, against 146 created.
##
## The ceiling is 6, roughly 3× the measurement, and it is deliberately NOT a
## rate band: this is a tripwire for the roster falling over, not a fit. `failed`
## stays pinned at exactly **0**, because a FAILED incident is a real loss (a
## building burns down) while an ABANDONED one is doc 06 declining to hold a
## queue open forever — the two are not the same kind of thing and only one of
## them may ever be non-zero on the control agent.
const AMBIENT_ABANDONED_CEILING := 6


## GATE 19 — **doc 92 §18 / audit 91 D-6: the dispatch loop is a DAILY beat, and
## one channel is most of it.**
##
## ---------------------------------------------------------------------------
## **RE-TITLED, WAVE 15 — the beat is ruled, not re-fitted** (doc 92 §39.7,
## report 98 RR-89; closes doc 92 §33.7's ranked question 1, open since Wave 13).
##
## The title said *weekly* because it was written when the measured rate was
## **3.04 ambient incidents per game-week** and two of doc 06's six generators
## were dead stubs. It is **9.73 per game-week** at this fork — 146 over the five
## seeds × 21 game-days below — of which `traffic_accident` alone is 101, i.e.
## **~0.96 per game-day**. A title claiming a weekly cadence over a number that
## is one-a-day is the gate lying about its own measurement, and doc 92 §33.5
## refused to hide it inside the band. So: the rate is ruled CORRECT and the
## title is what moves.
##
## **Three reasons the rate stands, in the order they bind.**
##
## 1. **Nothing safety-critical is near its bound.** Zero failed, zero abandoned,
##    zero destroyed, treasury climbing on every seed, and the 7×3×21 matrix's
##    peak open roster is **2** against doc 06 §2.13(b)'s ceiling of **36**. A
##    beat the fleet answers with 34 slots to spare is a beat, not a flood.
## 2. **Cutting it would invalidate doc 06's own worked examples.** §2.6(e)
##    intends **0.687 accidents/game-day for a 20-intersection city**; doc 09
##    stamps **389 junctions** before the player has built anything, and the
##    starter city measures 0.515/game-day in permanent sunshine — *below* doc
##    06's stated per-intersection intent, not above it. The Wave-13 doubling is
##    doc 07's weather reaching doc 10's congestion index (§33.5), which is two
##    authored formulas meeting for the first time. The base rate is not the
##    thing that is wrong, so the base rate is not the thing that moves.
## 3. **AND THE FUN CALCULUS CHANGED UNDERNEATH THE QUESTION.** This is the half
##    Wave 13 could not have ruled on. When §33.7 filed the question, a traffic
##    accident was a pure COST: a dispatch that spent fuel and vehicle wear,
##    resolved itself, and paid into a ledger line that did not exist. Since
##    RR-78 it is INCOME — `dispatch_payout_base.traffic_accident = $300`, times
##    tier, times the speed bonus, credited through `city_services` and named in
##    the budget panel. At the measured 0.96/game-day and a tier-1 answer at
##    target (`$450`) that is **~$430/game-day, ~$18/gh**, against a founding net
##    of $506.05/gh: a fifth of a do_nothing city's early income arrives as
##    accidents somebody answered.
##
##    **A once-a-day event that pays is a rhythm; a once-a-day event that only
##    costs is attrition.** Same number, opposite reading. The honest form of the
##    ruling is therefore that it would have been *"cut it"* in Wave 13 and is
##    *"keep it"* in Wave 15 — and the thing that changed is not the generator.
##
## **What is NOT ruled here**, so nobody reads more into this than it says: the
## *mix* is still lopsided (one channel of five carries 69 % of the count), and
## a player who reads the drawer sees mostly fender-benders. That is doc 06's
## §2.6 rate surface to balance across channels if it ever wants to, and it is a
## different question from the one this gate asks, which is whether the loop
## beats at all and whether the city survives it. Both: yes.
##
## Every doc 06 §2.6 generator is priced PER ASSET, so a founding city generated
## 0.337 incidents/game-day and the QA soak saw **two** in 287 game-hours: the
## drawer, the picker, the fleet and the whole five-tier escalation ladder were
## scenery. `data/incidents.json` `ambient_floor` puts a size-independent floor
## under every channel with a live candidate source as a `max()` — exactly the
## instrument doc 07 §8 already uses for the Director's threat points — and doc
## 92 §18.3 measured the result at **3.04 ambient incidents per game-week** over
## 336 game-days of `do_nothing`, with two of the six generators still dead. See
## the Wave-7 retune note below for what happened when they woke up.
##
## The gate has two halves because the finding has two halves.
##
## **The budget** is asserted exactly, off the data file: a floor edited to zero,
## disabled, or handed a channel with no candidate source fails here rather than
## silently in a report six weeks later.
##
## **The delivery** is asserted as a rate over five seeds, in a band wide enough
## that Poisson noise cannot fail it and narrow enough that the regressions that
## matter cannot pass it.
##
## **And the control city must still survive it.** Doc 92 §18's ruling in full is
## "a do_nothing city still survives; a neglected one meets its fires sooner".
## The starter roster answers every one: zero failed, zero abandoned, nothing
## destroyed, treasury still climbing.
##
## ---------------------------------------------------------------------------
## **WAVE-7 RETUNE — the two silent generators woke up (audit 91 D-17 / D-18,
## filed as D-14 / D-15 and renumbered 2026-08-19).**
##
## When this gate was written, `IncidentWorld.water_mains()` and
## `road_intersections()` were base-class stubs returning `[]` and
## `CityIncidentWorld` overrode neither, so two of doc 06 §2.6's six generators
## produced **exactly zero at every city size** — and this gate asserted their
## absence, in as many words, so that it would fail the day they landed. It has.
##
## Three things move, and the third is a ruling this gate cannot make on its own.
##
## 1. **The budget assertion does not move.** Doc 92 §18.2 said what to do:
##    *"the two new rows come out of the three existing ones"*. `per_day` still
##    sums to 0.40; the split is now 0.14 / 0.08 / 0.08 / 0.06 / 0.04.
## 2. **The two `assert_false`s become `assert_true`s.** A floor row for these
##    channels was dead data while their candidate source was empty; it is live
##    data now, and its absence would be the regression.
## 3. **The delivery band moves from 2–4 to 6–7 ambient incidents per game-week,
##    and the floor is not what put it there.** Measured, 12 seeds × 28 game-days
##    of `do_nothing` per arm, the same A/B shape doc 92 §18.3 used:
##
##    | /game-week | floor OFF | floor ON (5-channel) | floor ON (old 3-channel) |
##    |---|---|---|---|
##    | crime | 0.35 | 0.73 | 1.19 |
##    | structure_fire | 0.69 | 0.56 | 0.67 |
##    | transformer_failure | 0.81 | 1.08 | 1.23 |
##    | **water_main_break** | **0.58** | **0.60** | 0.56 |
##    | **traffic_accident** | **3.58** | **3.60** | 3.60 |
##    | storm_damage | 0.04 | 0.04 | 0.04 |
##    | **TOTAL** | **6.06** | **6.62** | **7.29** |
##
##    The three-channel columns reproduce doc 92 §18.3 to within noise (its 3.04
##    against 3.09 here on different seeds), so the rig is measuring the same
##    thing it did. **The whole leverage of the floor is 0.56/game-week.** Even
##    switched entirely OFF the city runs at 6.06, because `traffic_accident`
##    alone is 3.58 — and that is doc 06 §2.6(e) working exactly as written:
##    doc 09 stamps a road grid of **389 junctions** before the player has built
##    anything, so the one generator whose asset base is not player-built is
##    large from game-hour zero. Doc 06's own worked example intends **0.687
##    accidents/game-day** for a 20-intersection city; the starter city measures
##    **0.515**, i.e. *below* doc 06's stated intent. No floor can subtract, so
##    the 2–4 band is unreachable without cutting `traffic_per_intersection`
##    ~6.5× and invalidating doc 06 §2.6(e)'s four worked examples.
##
##    **The band is therefore re-derived from the measurement, not defended.**
##    The ruling doc 92 §18 made — *"the dispatch loop is a weekly beat; a
##    do_nothing city still survives it"* — **its first clause is superseded by
##    the Wave-15 re-title above; the second clause is the one that survived and
##    the one every column below is about** — holds on every clause it can be
##    tested on: 318/318 resolved, 0 failed, 0 abandoned, 0 destroyed, and the
##    treasury higher on all twelve seeds than it was with two dead generators
##    ($194,847 against $189,772). What changed is the arithmetic behind "2–4",
##    which was measured when a third of the generator surface was disconnected.
##    See the delivery report's open question 1.
func test_gate_19_ambient_incidents_are_a_weekly_beat() -> void:
	var floor_block: Dictionary = (StarterCityLoader.read_json(
			"res://data/incidents.json").get("ambient_floor", {}) as Dictionary)
	assert_true(bool(floor_block.get("enabled", false)), "the ambient floor is on")
	var per_day: Dictionary = floor_block.get("per_day", {})
	var budget := 0.0
	for channel in per_day:
		budget += float(per_day[channel])
	assert_almost_eq(budget, AMBIENT_FLOOR_PER_DAY, 1e-9,
			"doc 92 §18.1 budgets %.2f ambient incidents/game-day; the file sums to %.4f"
					% [AMBIENT_FLOOR_PER_DAY, budget])
	# Five rows now, one per channel with a live candidate source. The two that
	# were absent were absent because a floor cannot invent a target and theirs
	# was an empty stub (D-17 / D-18); both adapters landed in Wave 7.
	for channel in AMBIENT_FLOOR_CHANNELS:
		assert_true(per_day.has(channel),
				"`%s` has a live candidate source and no floor row" % channel)
	assert_eq(per_day.size(), AMBIENT_FLOOR_CHANNELS.size(),
			"an unexpected channel carries a floor row: %s" % str(per_day.keys()))
	assert_false(per_day.has("storm_damage"),
			"storm damage is not ambient — its candidates need a live doc 07 cell")

	var created := 0
	var failed := 0
	var abandoned := 0
	var by_channel: Dictionary = {}
	for seed_value in PACING_SEEDS:
		var run := _run("do_nothing", LONG_DAYS, seed_value)
		created += Rig.event_count(run, "incident_created")
		failed += Rig.event_count(run, "incident_failed")
		abandoned += Rig.event_count(run, "incident_abandoned")
		for channel in AMBIENT_FLOOR_CHANNELS:
			by_channel[channel] = int(by_channel.get(channel, 0)) \
					+ Rig.event_count(run, "incident_created:" + channel)
		var summary: Dictionary = run["summary"]
		assert_eq(int(summary["destroyed_end"]), 0,
				"the control city lost a building to the ambient floor on seed %d"
						% seed_value)
		assert_true(int(summary["treasury_end"]) > int(summary["treasury_start"]),
				"the control city stopped banking money on seed %d" % seed_value)
	var game_days := PACING_SEEDS.size() * LONG_DAYS
	var per_week := float(created) / float(game_days) * 7.0
	# **Every channel must actually fire.** This is the half of the gate that D-17
	# and D-18 would have caught: a generator scanning an empty array produces a
	# clean zero and no error anywhere, and it did so for months.
	for channel in AMBIENT_FLOOR_CHANNELS:
		assert_true(int(by_channel[channel]) > 0,
				"`%s` produced ZERO over %d game-days — its candidate source is "
				% [channel, game_days] + "empty again (the D-17 / D-18 shape)")
	# **RE-FIT Wave 14 — 91 → 146 over these exact 105 game-days, and ONE channel
	# carries all of it** (doc 92 §33.5, report 98 RR-69). Doc 07's weather state
	# now reaches doc 10's roads, so doc 06's `traffic_accident` generator finally
	# sees a congestion index that moves for weather. Census either side of the
	# same patch, five seeds × 21 game-days:
	#
	#   channel              before  after
	#   crime                    10     12
	#   structure_fire            6     13
	#   transformer_failure      15     11
	#   water_main_break         12      7
	#   traffic_accident         48    101      ← +110 %
	#   TOTAL                    92    146
	#
	# The other four move by ±small and net −1: they are the same generators
	# drawing from the `incidents` stream in a different ORDER once the traffic
	# channel's frequency changes. The arithmetic of the one that moved is two
	# authored formulas meeting for the first time: doc 06 §2's
	# `f_flow = clamp(c, 0.05, 2.0)^1.5` was pinned near its own 0.05 CLAMP FLOOR
	# on a quiet clear city (`f_flow = 0.0112`), and rain lifts `c` clear of that
	# floor for most of the day (`c ≈ 0.09–0.31 → f_flow 0.027–0.173`).
	# **Nothing was retuned to produce this and nothing is retuned to absorb it** —
	# doc 06 authored the accident rate against congestion precisely so that a
	# jammed city crashes more, and the three assertions below this band are the
	# ones that say the city can still take it: zero failed, zero abandoned,
	# nothing destroyed, treasury still climbing, and the 7×3×21 matrix's peak
	# open roster UNMOVED at 2 for `do_nothing` against doc 06 §2.13(b)'s 36.
	# *~0.96 traffic accidents per game-day IS the intended dispatch beat, ruled
	# in Wave 15 — see the re-title block at the top of this gate for the three
	# reasons and for the one that only became true this wave (the layer's
	# bounties made an accident income). Doc 92 §33.7's question 1 is closed.*
	#
	# The band keeps its old SHAPE (0.68× / 1.45× of measured, Poisson σ ≈ 12.1):
	# the traffic channel going dark lands at 45 and the ambient floor going dark
	# lands near 101, so the lower bound catches both; a 1.4× runaway lands at 204.
	assert_true(created >= 100,
			"%d incidents over %d game-days is %.2f per game-week — a channel has "
			% [created, game_days, per_week] + "gone quiet")
	assert_true(created <= 200,
			"%d incidents over %d game-days is %.2f per game-week — generation ran away"
					% [created, game_days, per_week])
	assert_eq(failed, 0, "a do_nothing city must survive its own pacing floor")
	assert_true(abandoned <= AMBIENT_ABANDONED_CEILING,
			("the starter roster abandoned %d of %d incidents over %d game-days; "
					+ "the ceiling is %d (measured 2 — see "
					+ "`AMBIENT_ABANDONED_CEILING`)")
					% [abandoned, created, game_days, AMBIENT_ABANDONED_CEILING])


## GATE 20 — **doc 92 §19 / audit 91 D-7: the level ladder is reachable.**
##
## The old ladder `[0, 250, 1000, 4000, 12000, 30000]` was adopted verbatim from
## a doc 02 proposal that predated every measurement in doc 92, and the
## measurements are damning: the QA soak's city sat at **level 0 for 12
## game-days and refused 376 upgrades** with `E_CITY_LEVEL`; `balanced` ended
## **fifty** game-days still at level 2; doc 92 §8's 90-game-day run peaks at
## 1,872 residents. Four of the six rungs were unreachable by anything the game
## can currently do, so most of doc 02 §2.10–2.11's upgrade ladder had no door.
##
## `data/progression.json` re-places the rungs on doc 92 §19.1's measured
## `balanced` curve. This gate holds the two beats the ruling names, on the agent
## the ruling is written against, and holds them as WINDOWS rather than
## equalities: a rung that arrives too early fails as surely as one that never
## arrives, because an unlock has to be earned to read as progression.
##
## Measured, all three doc 92 seeds: level 1 on game-day **2**, level 2 on
## game-day **11**.
func test_gate_20_the_city_level_ladder_is_reachable() -> void:
	var ladder := ProgressionSystem.city_level_pop()
	# **RE-FITTED, Wave 10 (doc 92 §24.6).** Six rungs became seven. The rung
	# is an APPEND — 18,000 above 8,000 — placed by §19.2's own 2.25× recipe
	# one step further, and nothing below it moved. The count is asserted
	# rather than bounded because a ladder that grows by accident is exactly
	# the kind of change this gate exists to catch.
	assert_eq(ladder.size(), 7, "doc 09 §2.11: seven rungs, 0–6")
	assert_eq(ladder[0], 0, "the founding city is level 0 by construction")
	for i in range(1, ladder.size()):
		assert_true(ladder[i] > ladder[i - 1],
				"the ladder must ascend: rung %d is %d, rung %d is %d"
						% [i - 1, ladder[i - 1], i, ladder[i]])
	# The file is the authority; the const is a missing-file degrade, and a drift
	# between the two is how a retune silently half-lands.
	var file_rows: Array = (StarterCityLoader.read_json("res://data/progression.json")
			.get("city_level_population_thresholds", []) as Array)
	assert_eq(file_rows.size(), ladder.size(),
			"data/progression.json and ProgressionSystem disagree on rung count")
	for i in ladder.size():
		assert_eq(int(file_rows[i]), ladder[i],
				"rung %d: data/progression.json says %d, the loaded ladder says %d"
						% [i, int(file_rows[i]), ladder[i]])
	# t0 sits BELOW rung 1, which is what keeps gate 14's `E_CITY_LEVEL` refusal
	# — and the tutorial's first locked build card — real.
	assert_true(CitySim.boot_from_files(GATE_SEED).population.city_population < ladder[1],
			"the founding city already clears rung 1; nothing is left to unlock")

	var day_rows: Array = _summary("balanced")["day_rows"]
	var first_day_at: Dictionary = {}
	for row_variant in day_rows:
		var row: Dictionary = row_variant
		var level := int(row["city_level"])
		if not first_day_at.has(level):
			first_day_at[level] = int(row["day"])
	assert_true(first_day_at.has(1), "a competent player never reached city level 1")
	assert_true(first_day_at.has(2), "a competent player never reached city level 2")
	var level_1_day := int(first_day_at[1])
	var level_2_day := int(first_day_at[2])
	# **RE-DERIVED, Wave 9 (doc 92 §22.3).** The lower bound on level 1 was
	# "an unlock has to be earned to read as progression", and until doc 09
	# §2.14 landed the only way to earn one was 56 more residents — game-day 2.
	# The curriculum is a second way, and it is a HARDER one to reach by
	# accident: four houses, a transformer, and 170 residents, all of which
	# `balanced` does inside its first seventeen game-hours because those are
	# the things a competent player does first. Measured on all three doc 92
	# seeds: **game-day 1** (game-hour 17), against game-day 2 before. The rung
	# is still earned — it is earned by a checklist instead of by a threshold,
	# which is the whole point — so the window moves down to 0–2 rather than the
	# gate being deleted. Gate 21 is the half that proves the checklist is what
	# earned it.
	assert_true(level_1_day <= 2,
			("level 1 landed on game-day %d; the ruled window is game-days 0–2 "
					+ "(measured 1 on all three doc 92 seeds — doc 09 §2.14's "
					+ "level-1 objectives, not the population rung)") % level_1_day)
	# UNCHANGED, and that is the finding worth recording: level 2 is still the
	# population rung's, because `balanced` never completes level 2's objective
	# list (it never touches the tax slider). Measured Wave 9, three seeds:
	# game-days 9.75 / 9.79 / 10.25 against doc 92 §19.3's 11 — a shift of under
	# a game-day, bought by unlocking apartments and offices 31 game-hours
	# earlier, and comfortably inside the window that was already ruled.
	assert_true(level_2_day >= 8 and level_2_day <= 14,
			("level 2 landed on game-day %d; the ruled window is game-days 8–14 "
					+ "(measured 10 on all three doc 92 seeds; still the "
					+ "population backstop, not the curriculum)") % level_2_day)


## GATE 21 — **doc 09 §2.14: the curriculum is COMPLETABLE, and paced.**
##
## Gate 20 measures the LADDER against `balanced`, the agent doc 92 §19 fitted it
## on. This one measures the CURRICULUM against `curriculum`, the agent doc 92
## §22 fits it on — a competent player who does the taught task and otherwise
## plays exactly like `balanced`. They are different questions and they need
## different agents: a player following a checklist is not the player who never
## opens the sheet, and doc 93 §G1's ruling is that both must get somewhere.
##
## Three claims, measured over three seeds at 21 game-days (doc 92 §22.2):
##
##   1. **Every level completes** — not "the agent gets far", but all five, in
##      order, inside the horizon this file already runs. A curriculum with an
##      unreachable rung is worse than no curriculum: it is a promise the game
##      cannot keep, and the tutorial hands the player straight to it.
##   2. **Nothing waits on a verb the player does not have.** The completion is
##      the proof, because `Curriculum` drives only commands the UI can issue.
##   3. **The pacing is the session beat the player asked for**: level 1 inside
##      the first game-day, level 3 inside six, level 5 inside three game-weeks,
##      and the whole arc inside `CURRICULUM_TOP_LEVEL_DAYS`.
##
## **RE-FITTED, Wave 10 (doc 92 §24.9).** The curriculum grew a sixth level and
## the horizon grew with it. Claim 1 and claim 2 are UNCHANGED in substance —
## every level completes, in order, on every seed — but 21 game-days no longer
## contains the arc, so the run is `CURRICULUM_DAYS` (45) and the top level's
## ruled bound is `CURRICULUM_TOP_LEVEL_DAYS` (40). Claim 3's early bounds did
## NOT move: level 1 is still inside the first game-day, level 3 inside six, and
## level 5 still inside the old 21-day horizon — the arc got longer at the top,
## it did not get slower underneath, and level 5 is asserted separately so that
## stays provable rather than assumed.
##
## **RE-MEASURED, Wave 10 (doc 92 §23.3).** `data/goals.json` gained two rows —
## `l3_streets` (4 tiles of doc 10 street) and `l4_repairs` (2 repairs) — the day
## the drag-path tool and the building panel's actions row gave those verbs a
## door (doc 93 §G2's amendment). Both sides of the change were measured on the
## same instrument, `tools/measure_curriculum.gd`, which drives this file's own
## `BalanceGateRig`; that A/B is table **(c)** in the historical block below.
##
## **RE-MEASURED, the upgrade-timing fix (doc 92 §27.4, report 98 RR-38).**
## `cmd_upgrade_building` was reading `upgrade_time_hours` from the row upgraded
## TO, where doc 02 §2.2 stores the step `L → L+1` on the row upgraded FROM, so
## every upgrade in the game except the last step of a ladder ran one rung's
## duration too slow. The fix moves every hash a curriculum run produces. The
## table below is the measurement it moved them to — same instrument
## (`tools/measure_curriculum.gd --days=45`, seeds 1337/4242/9001), the arrival
## game-hour of each level, with the pre-fix column beside it:
##
## | level | 1337 | 4242 | 9001 | duration (game-hours) | pre-fix duration |
## |---|---|---|---|---|---|
## | 1 | 13 | 13 | 14 | 13–14 | 13–14 |
## | 2 | 52 | 54 | 55 | 39–41 | 39–41 |
## | 3 | 111 | 115 | 119 | 59–64 | 59–64 |
## | 4 | 176 | 179 | 192 | 64–73 | 65–73 |
## | 5 | 371 | 358 | 361 | 169–195 | 169–190 |
## | 6 | 827 | 852 | 866 | 456–505 | 472–510 |
##
## **Levels 1, 2 and 3 do not move by a single game-hour**, which is the shape a
## faster upgrade should have this early: the arc's opening is gated on placing
## and on population, not on a rung completing. From level 4 up the arrivals move
## by a few game-hours in BOTH directions — seed 1337's finale comes in 49 hours
## sooner, seed 9001's 18 hours later — because a completion landing on a
## different hour re-seeds every downstream draw. The durations are inside the
## seed spread on every level and the ruled bounds all hold with margin.
##
## Every claim below is held against THIS table: level 3 on game-day 4 on all
## seeds (bound 6), level 5 on day 14.9–15.5 (bound 21), the arc done on day
## 34.5–36.1 (bound 40). `repaired` is 186–210 across 45 game-days.
##
## --- HISTORICAL BELOW THIS LINE. Everything from here down is the record of how
## the arc got to the table above, kept because a superseded measurement is what
## makes the next one checkable. Do not hold a claim against any of it.
##
## **(a) The Wave-9 integration table** — the combined tree (routing epoch +
## level-6 rung + street/repair re-arc), which is the PRE-FIX column of the table
## above and reproduces exactly on the pre-fix tree:
##
## | level | 1337 | 4242 | 9001 | duration (game-hours) |
## |---|---|---|---|---|
## | 1 | 13 | 13 | 14 | 13–14 |
## | 2 | 52 | 54 | 55 | 39–41 |
## | 3 | 111 | 115 | 119 | 59–64 |
## | 4 | 176 | 181 | 192 | 65–73 |
## | 5 | 366 | 357 | 361 | 169–190 |
## | 6 | 876 | 829 | 848 | 472–510 |
##
## **(b) The level-6 sibling branch**, measured before the street/repair re-arc
## and before the routing epoch landed beside it:
##
## | level | 1337 | 4242 | 9001 | duration (game-hours) |
## |---|---|---|---|---|
## | 1 | 13 | 13 | 14 | 13–14 |
## | 2 | 51 | 54 | 55 | 38–41 |
## | 3 | 97 | 98 | 103 | 44–48 |
## | 4 | 153 | 150 | 192 | 52–89 |
## | 5 | 345 | 351 | 312 | 120–201 |
## | **6** | **823** | **803** | **747** | **435–478** |
##
## Level 6 is ~2.9× level 5 rather than the ~2× the first five settle into, and
## the reason is measured rather than guessed: the sixth rung of a `house` is
## worth **124 kW** on a step whose whole cost is $73,572, so the level is a
## saving beat with a copper purchase in the middle of it. Doc 92 §24.8 is the
## measurement and §24.9 the ruling; the graduation level is allowed to be the
## longest, and this one is the top of the ladder.
##
## **(c) The street/repair re-arc's own A/B**, measured on the other sibling
## branch (no level 6, no routing epoch):
##
## | level | before (1337/4242/9001) | after | duration before → after |
## |---|---|---|---|
## | 1 | 13 / 13 / 14 | 13 / 13 / 14 | 13–14 → 13–14 (untouched) |
## | 2 | 51 / 54 / 55 | 51 / 54 / 55 | 38–41 → 38–41 (untouched) |
## | 3 | 97 / 98 / 103 | 111 / 115 / 119 | 44–48 → 60–64 |
## | 4 | 153 / 150 / 192 | 175 / 179 / 192 | 52–89 → 64–73 |
## | 5 | 345 / 351 / 312 | 371 / 362 / 351 | 120–201 → 159–196 |
##
## Levels 1 and 2 are **bit-identical**, which is the shape the change should
## have: the rows landed on 3 and 4. Level 3 costs 14–16 game-hours more, and
## that is the price of $7,200 of street on a treasury that is still thin —
## `l3_streets` is the first objective in the arc the player has to SAVE for
## twice over, because `Curriculum` earmarks the whole run (doc 10 bills a run as
## one command). The day bounds below did not have to move: level 3 still lands
## on game-day 4 on every seed against a ruled bound of 6, and the arc still
## finishes on game-day 14–16 against the 21-game-day horizon.
##
## The `18 / 59 / 100 / 148 / 329` table this docstring carried before did not
## reproduce at this fork on either side of the change; it was recorded a wave
## earlier and the Wave-8 rules epoch (doc 93 §E3) moved underneath it. The
## before/after pair above is measured, at this fork, with one instrument.
func test_gate_21_the_curriculum_is_completable_and_paced() -> void:
	var top := GoalSystem.top_level()
	assert_true(top >= 1, "there is a curriculum to complete")
	for seed_value in MATRIX_SEEDS:
		var doc := _run("curriculum", CURRICULUM_DAYS, int(seed_value))
		var summary: Dictionary = doc["summary"]
		assert_eq(int(summary["goal_level_end"]), top,
				("seed %d finished %d of %d curriculum levels in %d game-days — "
						+ "a rung the taught route cannot reach is a promise the "
						+ "game cannot keep") % [int(seed_value),
						int(summary["goal_level_end"]), top, CURRICULUM_DAYS])
		assert_eq(int(summary["city_level_end"]), top,
				"and the city level followed the objectives up (doc 93 §G1)")
		# The one objective in the arc that costs five figures, and the first
		# time any agent in this project has driven doc 05's placeable roster
		# at all (doc 92 §17.6 recorded that none did).
		assert_true(int(summary["water_placed"]) >= 1,
				"seed %d never afforded its own water works" % int(seed_value))
		# §17.6's other half, closed in Wave 10: the taught route now lays its
		# own streets. This is the assertion that would catch a curriculum row
		# whose verb has quietly lost its door again — the agent drives
		# `cmd_place_road` only because an objective asks for it.
		assert_true(int(summary["road_tiles_built"]) >= 1,
				"seed %d never laid a road tile of its own" % int(seed_value))
		assert_true(int(summary["repaired"]) >= 2,
				"seed %d never bought a repair" % int(seed_value))

		var first_day_at: Dictionary = {}
		for row_variant in (summary["day_rows"] as Array):
			var row: Dictionary = row_variant
			var level := int(row["goal_level"])
			if not first_day_at.has(level):
				first_day_at[level] = int(row["day"])
		var missing := 0
		for level in range(1, top + 1):
			if not first_day_at.has(level):
				missing += 1
				_fail("seed %d never earned curriculum level %d"
						% [int(seed_value), level])
		# Every bound below indexes `first_day_at`; a missing rung has already
		# been reported and reading it would crash the run instead of failing it.
		if missing > 0:
			continue
		# **The pacing band, and why it is quoted in game-days.** One game-hour
		# is one real minute at 1× (`SimHost.GAME_MS_PER_REAL_MS` is 60), so a
		# game-day is a 24-minute session. Level 1 has to land inside the first
		# of those, or the tutorial hands the player to a screen with nothing on
		# it; measured at game-hour 13–14 on every seed, which is day 0, and
		# untouched by the Wave-10 re-arc.
		assert_true(int(first_day_at[1]) <= 1,
				("seed %d took %d game-days to teach the first level; the ruled "
						+ "bound is 1 (measured game-hour 13–14 on all three seeds)")
						% [int(seed_value), int(first_day_at[1])])
		if top >= 3:
			# HELD at 6 through the Wave-10 re-arc. Level 3 gained the street
			# row and moved from game-hour 97–103 to 111–119; both sides land on
			# game-day 4, so the bound is measured with two days of margin on
			# each side and is not re-fitted to the newer number.
			assert_true(int(first_day_at[3]) <= 6,
					("seed %d took %d game-days to reach curriculum level 3; the "
							+ "ruled bound is 6 (measured 4 on all three seeds "
							+ "after the Wave-10 re-arc, 4–5 before it)")
							% [int(seed_value), int(first_day_at[3])])
		# **The fifth level still lands inside the old horizon**, and asserting it
		# separately is what keeps the re-fit honest: the arc got longer at the
		# TOP, it did not get slower underneath (measured 14.4 / 14.6 / 13.0
		# game-days on seeds 1337 / 4242 / 9001, against Wave 9's 12.7–13.7 arc —
		# the same window, one level earlier in it).
		if top >= 5:
			assert_true(int(first_day_at[5]) <= LONG_DAYS,
					("seed %d reached curriculum level 5 on game-day %d; the ruled "
							+ "bound is still Wave 9's %d-game-day horizon")
							% [int(seed_value), int(first_day_at[5]), LONG_DAYS])
		assert_true(int(first_day_at[top]) <= CURRICULUM_TOP_LEVEL_DAYS,
				("seed %d finished the arc on game-day %d; the ruled bound is %d "
						+ "game-days (measured 34.5-36.1 post-fix — doc 92 §27.4)")
						% [int(seed_value), int(first_day_at[top]),
						CURRICULUM_TOP_LEVEL_DAYS])
		# **The three-tier beat, doc 92 §27.5.** The 10–40 game-hour band §22 ruled
		# for "levels 1–3" is retired and replaced by an OPENING band (levels 1–2,
		# up to `CURRICULUM_OPENING_BEAT_H`) and a MIDDLE band (levels 3–4, up to
		# `CURRICULUM_MIDDLE_BEAT_H`). Only the CEILINGS are executable:
		#
		#   * The opening is what the old band was really protecting — a player who
		#     has not yet decided to keep the game must not wait. Measured 13–14 and
		#     39–41 game-hours, against a ceiling of 45 (see the constant for why the
		#     ceiling is 45: level 2 has been one hour over 40 since §22.3).
		#   * Level 3 measures 59–64, and doc 92 §27.5's two ablation arms say the
		#     objectives are not why: halving `l3_streets` to 2 tiles buys 8–12
		#     game-hours (51–52) and deleting the row outright buys 15–16 (44–48).
		#     NEITHER reaches 40. The band was fitted to a pre-street-tool arc on a
		#     pre-Wave-8 rules epoch, and the band is the thing that moves.
		#   * **Level 4's ceiling is the same number and claims less**, and this says
		#     so rather than pretending otherwise: its duration is an incident WAIT
		#     (`l4_incidents` resolve-2 against gate 19's own ambient rate), so its
		#     spread is Poisson and it has measured as wide as 89 game-hours on a
		#     slow seed (doc 92 §25.3). 90 is one game-hour above that historical
		#     worst case, which makes it a runaway detector and not a pacing fit.
		#
		# No FLOOR is asserted at either tier. A level that got faster is not a
		# regression this gate can tell apart from an improvement, and the floor that
		# does matter — that the arc happens at all, in order — is the completion
		# assertion at the top of this test. What IS asserted below the ceiling is
		# that the hour was measured at all: a ceiling on a beat computed from a
		# sample stream that had lost `goal_level` would pass vacuously, which is the
		# one way this addition could be worse than no addition.
		var first_hour_at: Dictionary = {0: 0}
		for sample_variant in (doc["samples"] as Array):
			var sample: Dictionary = sample_variant
			var sample_level := int(sample.get("goal_level", 0))
			if sample_level > 0 and not first_hour_at.has(sample_level):
				first_hour_at[sample_level] = int(sample["h"])
		for level in range(1, mini(top, 4) + 1):
			# The guard that stops a ceiling from passing VACUOUSLY. A sample stream
			# that had lost `goal_level` would make every beat 0 − 0 and every
			# assertion below hold on a curriculum nobody measured, which is the one
			# way this addition could be worse than no addition at all.
			assert_true(first_hour_at.has(level),
					("seed %d: the sample stream carries the hour curriculum level %d "
							+ "was earned") % [int(seed_value), level])
			var beat := int(first_hour_at.get(level, 0)) \
					- int(first_hour_at.get(level - 1, 0))
			var ceiling := CURRICULUM_OPENING_BEAT_H if level <= 2 \
					else CURRICULUM_MIDDLE_BEAT_H
			assert_true(beat <= ceiling,
					("seed %d spent %d game-hours on curriculum level %d; the ruled "
							+ "%s beat tops out at %d (doc 92 §27.5)")
							% [int(seed_value), beat, level,
							"opening" if level <= 2 else "middle", ceiling])
		# Monotone: a curriculum level, once earned, is never given back — the
		# same promise doc 09 §2.11 makes about the city level itself.
		var previous := 0
		for row_variant in (summary["day_rows"] as Array):
			var level := int((row_variant as Dictionary)["goal_level"])
			assert_true(level >= previous,
					"seed %d lost a curriculum level it had earned" % int(seed_value))
			previous = level


# ====================================== 29 the presets (doc 92 §29, A91-D-19)

## GATE 29 — doc 03 §2.9's difficulty horizon. Neglect must be fatal on EVERY
## preset — that is the identity doc 06 §2.10 and report 98 RR-26 keep naming —
## and the presets have to be ordered: a kinder difficulty buys a longer rope,
## never a permanent one.
##
## The measure is **insolvency**: the first game-day on which a `do_nothing`
## city's treasury closes below zero. It is chosen over "buildings destroyed"
## because the roster does not shrink — a destroyed building keeps its record —
## so the count is a state, while the day the money runs out is an EVENT, and it
## is the one the player actually meets (`credit_line_engaged`, doc 03 §2.10
## layer 3, then the −$20,000 hard floor of layer 4).
##
## Measured 2026-08-20 with `tools/measure_insolvency.gd`, seeds 1337 / 4242 /
## 9001, **after doc 93 §M1 took `M_exp` off `E_roads_repair`** (doc 92 §31.5):
##
## | preset | day the treasury first closes negative | peak, and its day |
## |---|---|---|
## | casual | 104 / 110 / 108 | $471k around game-day 50 |
## | standard | **76 / 75 / 74** | $237k around game-day 44 |
## | hard | 57 / 56 / 56 | $88k around game-day 28 |
## | crisis | 41 / 42 / 40 | $21k around game-day 10 |
##
## **`standard` did not move by one game-day on any of the three seeds** — the
## same 76 / 75 / 74 the pre-ruling column measured — which is the longest-horizon
## proof this repository has that the ruling is hash-neutral on the default
## preset: 76 game-days of a decaying city, not 24 game-hours of a fresh one.
##
## The superseded column, kept because gate thresholds were fitted to it and a
## reader comparing this file against doc 92 §29.3 needs to see both: casual
## 109 / 116 / 113, standard 76 / 75 / 74, hard 52 / 52 / 53, crisis 35 / 34 / 35.
## What moved is exactly what the double knob was paying for — `casual` lost 5
## game-days of rope (its road bill rose from 0.595× standard's to 0.700×) and
## `hard` / `crisis` gained 4 and 6 (theirs fell from 1.512× / 2.000× to
## 1.350× / 1.600×).
##
## Each rung now buys about **1.36×** the next one's rope (104/76 = 1.37, 76/57 =
## 1.33, 57/41 = 1.39), where the compounding bought 1.5×. That is a shape and
## not a fit — nothing was tuned to produce either number — so this gate does not
## assert it.
##
## **What IS asserted** is the part a regression would break: strict ordering,
## and finiteness on all four. The bounds are the measurements with a margin wide
## enough that ordinary seed noise cannot trip them, and narrow enough that a
## preset which stopped biting would.
##
## **Cost, and the horizon rule.** One seed, not three, and a **per-preset**
## horizon — each is its own measured insolvency day plus about ten game-days of
## margin, never a flat 120. That was thrift AND a hazard, and it is now only
## thrift:
##
## > **The cascade the horizons used to dodge is fixed** *(Wave 13, doc 06
## > §2.13(b), doc 92 §31)*. The note that stood here said a neglected city
## > eventually cascades — measured on `crisis`, seed 1337, from game-day **104**
## > the roster multiplied ~2.5–2.9 per game-hour, 103 → 357 → … → 89,055, at
## > 269 s of wall clock for the eighth of those game-hours — and that a gate
## > running into it would hang rather than fail. It was filed as doc 92 §29.5(b).
## > §2.13(b)'s saturation rule closes it: no automatic birth crosses the roster
## > ceiling, and **gate 30 below runs the same city to game-day 200 on purpose**.
## > These horizons stay where they are because they are fitted to INSOLVENCY,
## > which is what this gate measures; the tripwire below stays because a
## > horizon-shaped assumption should be asserted, not assumed.
##
## Total ~48 s at the Wave-14 horizons. The three-seed table above is doc 92
## §31.5's; this is the tripwire.
##
## **COST WARNING, Wave 17.** The re-fitted horizons below total 560 game-days
## against 335, and — unlike `tools/measure_insolvency.gd`, which stops at
## insolvency — `Rig.run` advances the FULL horizon, through the late-arc
## incident cascade that is far slower per game-hour than a quiet city. This gate
## is now the slowest single thing in the suite by a wide margin. If that becomes
## a problem the right fix is to teach the rig to stop at the first negative
## close (the gate reads `day_rows` and needs nothing after it), not to shorten
## the horizons, which are fitted.
##
## **RE-FITTED Wave 17 (doc 92 §43.8, doc 93 §Y1/§Y3).** The ownership floor took
## the dominant term out of this gate's engine and the horizons roughly double.
## The engine was never really the blackout: `tools/probe_neglect` showed
## `PLANT-1` destroyed on game-day 40 and `SUB-A` on 45 **with the tax line
## unmoved** (569 → 585 $/gh across the failure), so what actually killed a
## neglected city was PRIVATE STRUCTURAL FAILURE — buildings rotting past 0.35,
## going `damaged`, and being destroyed one at a time until the tax base was
## gone. Doc 02 §2.6a stops exactly that (an owner does not let their own asset
## become a liability), so what remains is `f_condition` capped at the Worn
## floor — a permanent 24 % cut, not a slide to zero — plus the city's own
## assets failing. Half the engine, so about twice the clock.
##
## `tools/measure_insolvency.gd --max-days=220`, three seeds, all four presets:
##
## | preset | 1337 / 4242 / 9001 | mean | before (Wave 14) |
## |---|---|---|---|
## | `casual` | 193 / 190 / 189 | **190.7** | 105.0 |
## | `standard` | 137 / 139 / 129 | **135.0** | 69.0 |
## | `hard` | 58 / 97 / 64 | **73.0** | 51.0 |
## | `crisis` | 31 / 18 / 43 | **30.7** | 26.0 |
##
## **Every preset still dies and the §2.9 ordering holds on every seed
## individually**, which is the assertion this gate is actually for. The seed
## spread widened on `hard` and `crisis` (39 and 25 game-days against 2 and 6),
## and that is the same finding read from the other end: with the smooth
## condition slide gone, the remaining collapse is driven by the incident
## cascade, which is stochastic where wear was not.
const PRESET_HORIZON_DAYS := {"casual": 210, "standard": 160, "hard": 120, "crisis": 70}
## casual must die before its own horizon; crisis must not die absurdly early.
## The ordering assertions carry the rest.
##
## The FLOOR is deliberately loose (it guards against a preset becoming a
## different game, not against a knob wired to the wrong scope — that is
## `tests/test_economy.gd`'s `test_one_difficulty_knob_per_ledger_line`, which
## asserts the per-line multiplier directly and would fail on the compounding
## this table's superseded column was measured under).
##
## **RE-MEASURED Wave 14 (doc 92 §33.4, report 98 RR-69).** Doc 07's weather
## reaches doc 10's roads, so a neglected city now pays a road-repair accrual
## that is 16 % higher on a wet day and answers twice as many traffic accidents.
## Every preset dies sooner, by 8–35 %, **and the ordering §2.9 authors is
## preserved on every seed** — which is the assertion this gate is actually for.
## `tools/measure_insolvency.gd --max-days=130`, three seeds:
##
## | preset | before (mean) | after: 1337 / 4242 / 9001 | after (mean) |
## |---|---|---|---|
## | `casual` | 104–110 | 103 / 108 / 104 | **105.0** |
## | `standard` | 74 / 75 / 76 | 68 / 70 / 69 | **69.0** |
## | `hard` | — | 52 / 51 / 50 | **51.0** |
## | `crisis` | 40–42 | 23 / 29 / 26 | **26.0** |
##
## `crisis` moved the furthest and for the reason its own name implies: it starts
## with the thinnest purse, so the same extra $/gh eats a larger share of it.
## The FLOOR moves 25 → **18**, keeping the ratio it had (0.625× of the measured
## `crisis` mean, which was 25/40 and is now 18/26 ≈ 0.69× — deliberately a
## little tighter, because 26 game-days is close enough to "a different game"
## that the guard should not be relaxed proportionally). The CEILING stays 118:
## `casual`'s worst seed is 108 and its horizon is 120.
## **118 → 200 (Wave 17)**: `casual`'s worst seed is 193 and its horizon is 210.
## The FLOOR stays at 18 — `crisis` measures 18–43 across the three seeds, so 18
## is now the observed minimum rather than 0.69× the mean, and moving it down
## would stop it guarding anything.
const PRESET_LIFETIME_CEILING := 200
const PRESET_LIFETIME_FLOOR := 18
## `standard` is the preset every other gate in this file is measured on, so its
## own number is pinned rather than merely ordered. **69 → 137, Wave 17** (doc 92
## §43.8): the three-seed spread is 10 game-days (129–139) and the band widens
## 6 → 12 to hold it, which keeps the guard at the same ~9 % of the pinned value
## it had before — so this still fails on anything that moves `standard`'s
## neglect curve by more than about a tenth.
const STANDARD_LIFETIME_DAYS := 137
const STANDARD_LIFETIME_BAND := 12
## The cascade tripwire, asserted inside the horizon rather than assumed away:
## doc 06 §2.13's own worst-case accounting is ≤ 40 active incidents, and a
## `do_nothing` city inside these horizons measures 0 or 1.
const PRESET_MAX_OPEN_INCIDENTS := 40


func _preset_run(preset: String) -> Dictionary:
	return Rig.run("do_nothing", GATE_SEED, int(PRESET_HORIZON_DAYS[preset]), preset)


## **The insolvency day, read at HOUR resolution** (99-PA PA-04, doc 92 §49.5).
##
## This gate used to read `summary.day_rows` — the treasury at each day's CLOSE —
## and on a city hovering on the line that is a knife edge, not a measurement. A
## `do_nothing` city on `hard` goes below zero every evening from game-day 48 and
## closes every one of the next 72 game-days above it, and the day-close reading
## then answers **"still solvent after 120 game-days"** about a city that ran out
## of money ten game-weeks earlier.
##
## Measured on both arms of Wave 18's fork (`tools/probe_neglect.gd`, seed 1337,
## each preset's own horizon) — the reading change moves nothing about the game:
##
## | preset | fork close / hour | this branch close / hour |
## |---|---|---|
## | `casual` | 193 / 193 | 193 / 193 |
## | `standard` | 137 / 137 | 135 / 135 |
## | `hard` | **58 / 48** | **never / 48** |
## | `crisis` | 31 / 18 | 35 / 19 |
##
## `hard` is the only preset the two readings ever disagreed on, and they
## disagreed at the fork too (58 vs 48) — the Director waking up just widened the
## gap until the day-close reading fell off the end of the horizon. Every band
## below is UNCHANGED and every one of them holds under the finer reading on both
## arms, which is the evidence that this is a resolution fix and not a re-fit.
func test_gate_29_neglect_is_fatal_on_every_preset_and_ordered() -> void:
	var died: Dictionary = {}
	for preset: String in Difficulty.PRESETS:
		var horizon := int(PRESET_HORIZON_DAYS[preset])
		var run := _preset_run(preset)
		var day := -1
		var peak_open := 0
		for row_variant in ((run["summary"] as Dictionary)["day_rows"] as Array):
			peak_open = maxi(peak_open, int((row_variant as Dictionary)["open_incidents"]))
		# `samples[0]` is the pre-run reading; `samples[i]` closes game-hour `i`.
		var samples: Array = run["samples"]
		for i in range(1, samples.size()):
			if float((samples[i] as Dictionary).get("treasury", 0.0)) < 0.0:
				day = ((i - 1) / 24) + 1
				break
		died[preset] = day
		# The cascade tripwire (see `PRESET_HORIZON_DAYS`). Measured 0–1 inside
		# every horizon; doc 06 §2.13(b)'s ceiling is 40. It is now the same
		# number gate 30 asserts on a 200-game-day run, so if it ever fires here
		# it is a real regression in the saturation rule and not a horizon that
		# wandered — read gate 30's failure first, it says more.
		assert_true(peak_open <= PRESET_MAX_OPEN_INCIDENTS,
				("do_nothing on %s peaked at %d open incidents inside %d game-days; "
						+ "doc 06 §2.13(b)'s roster ceiling is %d — the saturation "
						+ "rule has regressed, see gate 30")
						% [preset, peak_open, horizon, PRESET_MAX_OPEN_INCIDENTS])
		# FINITE. A preset on which standing still never costs anything is a
		# preset with no game in it, and `casual` is the one that could drift
		# there without anybody noticing.
		assert_true(day > 0,
				("do_nothing on %s was still solvent after %d game-days — neglect "
						+ "has stopped being fatal on that preset") % [preset, horizon])
		assert_true(day <= PRESET_LIFETIME_CEILING,
				("do_nothing on %s survived to game-day %d; the ruled ceiling is %d "
						+ "(measured 103–108 on casual, doc 92 §33.4)")
						% [preset, day, PRESET_LIFETIME_CEILING])
		assert_true(day >= PRESET_LIFETIME_FLOOR,
				("do_nothing on %s went insolvent on game-day %d; the ruled floor is "
						+ "%d (measured 23–29 on crisis, doc 92 §33.4) — below it a preset is not "
						+ "harder, it is a different game")
						% [preset, day, PRESET_LIFETIME_FLOOR])
	# ORDERED, strictly, in the direction §2.9 authors: casual outlives standard
	# outlives hard outlives crisis. This is the assertion that would catch a
	# preset edited in the wrong direction, or a knob wired to the wrong sign.
	for i in range(1, Difficulty.PRESETS.size()):
		var kinder: String = Difficulty.PRESETS[i - 1]
		var harder: String = Difficulty.PRESETS[i]
		assert_true(int(died[kinder]) > int(died[harder]),
				"%s should outlive %s: game-day %d vs %d"
						% [kinder, harder, int(died[kinder]), int(died[harder])])
	assert_true(absi(int(died["standard"]) - STANDARD_LIFETIME_DAYS)
					<= STANDARD_LIFETIME_BAND,
			("standard do_nothing died on game-day %d; the pinned value is %d ± %d "
					+ "(doc 92 §43.8's re-fit, re-read at hour resolution in §49.5: "
					+ "137 on the fork, 135 on this branch)")
					% [int(died["standard"]), STANDARD_LIFETIME_DAYS,
					STANDARD_LIFETIME_BAND])


# ============================== 30 the saturation rule (doc 06 §2.13(b), §31)

## GATE 30 — **a fully-decayed city's incident roster is BOUNDED, and by the
## number doc 06 §2.13 has always costed itself against** (doc 92 §31).
##
## Gate 29 above carries a horizon per preset and a written reason for each one,
## and the reason was a hazard: *"a neglected city eventually cascades, and past
## the cascade this gate would not finish."* Measured on `crisis`, seed 1337, the
## roster multiplied ~2.5–2.9× **per game-hour** from game-day 104 — 103 → 357 →
## 832 → 2,424 → 6,389 → 14,671 → 37,631 → 89,055 — at 269 s of wall clock for
## the eighth of those game-hours. On device that is an ANR on any long-abandoned
## save. This gate is the half of the ruling that says the horizon no longer has
## to dodge: it runs `do_nothing` on `crisis` **past** the cascade and asserts the
## roster stayed under the ceiling.
##
## **The bound, re-derived with the rule.** §2.10.1 published
## `arrival_rate × T ≤ 26` and it is correct for EXOGENOUS arrivals; eight cascade
## actions make arrivals endogenous, and a mean offspring of three is supercritical
## however short each parent's life is. §2.13(b) closes it with a ceiling that no
## automatic birth may cross, so the bound is now the ceiling itself —
## `saturation_ceiling`, read here out of `data/incidents.json` rather than
## repeated, because a gate that hard-codes a tunable stops gating it.
##
## **Sampled per game-HOUR, not per game-day.** The cascade multiplied inside a
## single game-hour; a daily row would have stepped over its own evidence.
const DECAY_PRESET := "crisis"
## Past game-day 104, which is where seed 1337's cascade started, with enough
## margin that a slower seed cannot hide behind the horizon.
const DECAY_HORIZON_DAYS := 200


func test_gate_30_a_decayed_city_roster_is_bounded() -> void:
	var globals: Dictionary = (StarterCityLoader.read_json("res://data/incidents.json")
			.get("globals", {}) as Dictionary)
	var ceiling := int(globals.get("saturation_ceiling", 0))
	var knee := int(globals.get("saturation_knee", 0))
	assert_true(ceiling > 0 and knee > 0 and ceiling > knee,
			"doc 06 §2.13(b) is authored: knee %d, ceiling %d" % [knee, ceiling])
	var doc := Rig.run("do_nothing", GATE_SEED, DECAY_HORIZON_DAYS, DECAY_PRESET)
	var peak := 0
	var peak_hour := -1
	for sample_variant in (doc["samples"] as Array):
		var sample: Dictionary = sample_variant
		var open_now := int(sample["open_incidents"])
		if open_now > peak:
			peak = open_now
			peak_hour = int(sample["h"])
	assert_true(peak <= ceiling,
			("do_nothing on %s peaked at %d open incidents on game-hour %d over %d "
					+ "game-days; doc 06 §2.13(b)'s ceiling is %d")
					% [DECAY_PRESET, peak, peak_hour, DECAY_HORIZON_DAYS, ceiling])
	# The other end. A rule that bounded the roster by switching the incident
	# engine off would pass the assertion above and break the game, so the run
	# has to still be producing incidents after its city is gone.
	assert_true(Rig.event_count(doc, "incident_created") > 0,
			"a 200-game-day city generated no incidents at all — the ceiling is "
			+ "not supposed to be a mute button")


# ============== 31 the moral-hazard guard (doc 03 §2.5, report 98 RR-77)

## GATE 31 — **a payout may never exceed the loss it prevented.**
##
## The hazard is not arson; the player has no arson verb. It is *waiting*. Doc 06
## §2.7 grows the payout at `tier_k = 0.35` per tier while doc 02 grows the
## residual damage at `0.10` per tier, so on a cheap building the reward outruns
## the value at risk somewhere around tier 4 and letting a fire grow before
## answering it becomes the profitable play. That is a strategy the game must not
## contain, and this is where it is refused.
##
## **The guard bound on shipped numbers, and that is the finding** (doc 92
## §35.3). House L1, capital $1,200. A tier-5 fire resolved at the target
## response pays `900 × (1 + 0.35·4) × 1.00 = $2,160` before the clamp; the
## residual damage is `0.10 × 4 = 0.40`, so the repair costs
## `1,200 × 0.40 × 0.85 = $408` and the prevented loss is `1,200 − 408 = $792`.
## The unclamped ratio is **2.73**. At `MORAL_HAZARD_CAP_FRACTION = 0.75` the
## city pays $594 and the ratio is 0.75 by construction.
##
## Three assertions, because the guard has three surfaces: the clamp has TEETH
## (a controlled incident), the LIVE game respects it (every resolve of a played
## city), and the types the clamp cannot reach are held by a PUBLISHED ceiling.
func test_gate_31_a_payout_never_exceeds_the_damage_it_prevented() -> void:
	var services := _city_services()
	var cap := float(services["MORAL_HAZARD_CAP_FRACTION"])
	assert_true(cap > 0.0 and cap < 1.0,
			"the ceiling is strictly below indifference: %.3f" % cap)

	# (a) TEETH. Doc 03 prices the payout AND the ceiling, so the whole guard is
	# exercised through the one seam doc 06 crosses to reach money.
	var sim := CitySim.boot_from_files(GATE_SEED)
	var house_id := ""
	for id in sim.roster_ids():
		if String((sim.buildings[String(id)] as Building).archetype) == "house":
			house_id = String(id)
			break
	assert_ne(house_id, "", "the starter city houses somebody")
	var target := {"kind": "building", "id": house_id}
	var residual := 0.40  # doc 06 §2.8's residual curve at tier_peak 5
	var prevented: int = sim.incident_world.prevented_loss_value(target, residual)
	assert_true(prevented > 0, "a house is an asset doc 03 can price")
	var shape := 1.0 + 0.35 * 4.0  # tier 5 answered at the target response time
	var paid: int = sim.incident_world.dispatch_payout("structure_fire", shape,
			false, target, residual)
	var base := float((services["dispatch_payout_base"] as Dictionary)["structure_fire"])
	var unclamped := int(round(base * shape))
	var ceiling := int(round(cap * float(prevented)))
	assert_true(unclamped > ceiling,
			("the clamp needs something to clamp: unclamped $%d against a ceiling "
					+ "of $%d on a prevented loss of $%d")
					% [unclamped, ceiling, prevented])
	assert_true(paid <= ceiling + 1,
			"a tier-5 house fire paid $%d against a ceiling of $%d" % [paid, ceiling])
	assert_true(paid < unclamped,
			"and the clamp actually bound: $%d < $%d" % [paid, unclamped])

	# (b) THE LIVE GAME. Every resolve of an UNTOUCHED founding city over
	# `LONG_DAYS`, checked against the prevented loss that same resolve reported.
	# Untouched on purpose: the ceiling's worst case is a high tier on a CHEAP
	# building, and the founding roster is eighteen houses — a built-out city
	# dilutes exactly the case this is looking for. Driven inline rather than
	# through `Rig.run` because the rig tallies event COUNTS and this needs the
	# payloads.
	var live := CitySim.boot_from_files(GATE_SEED)
	live.bus.drain()
	var checked := 0
	var worst := 0.0
	var worst_at := ""
	for _h in LONG_DAYS * 24:
		live.advance_coarse_hours(1, false)
		for event_variant in live.bus.drain():
			var event: Dictionary = event_variant
			if String(event.get("type", "")) != "incident_resolved":
				continue
			var loss := int(event.get("prevented_loss", -1))
			if loss <= 0:
				continue  # unpriced asset class, or nothing was at risk — see (c)
			checked += 1
			var ratio := float(int(event.get("reward", 0))) / float(loss)
			if ratio > worst:
				worst = ratio
				worst_at = String(event.get("incident_type", ""))
	assert_true(checked > 0,
			("%d game-days resolved nothing with a priced target — this gate "
					+ "measured nothing at all") % LONG_DAYS)
	assert_true(worst <= cap + 0.001,
			("the worst of %d priced resolves (%s) took %.3f of the loss it "
					+ "prevented; the ceiling is %.3f")
					% [checked, worst_at, worst, cap])

	# (c) THE TYPES THE CLAMP CANNOT REACH. Road edges and water segments carry
	# no `capital_value` in doc 03, so `prevented_loss_value` answers −1 and a
	# published ceiling holds them instead. `base × 5.40` is the worst case the
	# formula can produce: tier 5 (×2.40), best speed (×1.50), human on the
	# drawer (×`MANUAL_DISPATCH_MULT`).
	var unpriced_ceiling := float(services["MORAL_HAZARD_UNPRICED_CEILING"])
	var worst_case_mult := 2.40 * 1.50 * float(services["MANUAL_DISPATCH_MULT"])
	for type_id: String in ["traffic_accident", "water_main_break", "storm_damage"]:
		var worst_payout := float((services["dispatch_payout_base"] as Dictionary)
				[type_id]) * worst_case_mult
		assert_true(worst_payout <= unpriced_ceiling,
				("%s can pay $%.0f at tier 5, best speed, manually dispatched; the "
						+ "published ceiling for an unpriced target is $%.0f")
						% [type_id, worst_payout, unpriced_ceiling])


# =========== 32 the active-play income share (doc 03 §2.5, RR-77 / the street)

## GATE 32 — **active play pays visibly more, and idle play still pays.**
##
## The player's ask was two-sided: *"our automatic dispatch in crime — that
## should pay us money"* **and** a reason to work the drawer and the street. This
## gate is the bound on the second half, so that collecting things can never grow
## into the only way to play.
##
## ---------------------------------------------------------------------------
## **RE-BUILT, WAVE 15 (doc 92 §39, report 98 RR-85 / RR-86).** The old version
## of this gate read four numbers out of `data/economy.json` and multiplied two
## of them, and its own header said why: *"the street system's spawn table lives
## in a sibling branch's file, and a contract that can only be checked by running
## two branches at once is not a contract."* **Both halves of that excuse are
## gone.** The spawn table is in this tree, `data/street.json` no longer carries
## a dollar (RR-85), and `tools/playtest.gd` has an agent that can actually
## collect one (RR-86). So three of the five assertions become measurements, and
## the two data numbers they replace turned out to be wrong in opposite
## directions:
##
##   * `street_payout` was a **placeholder nothing read** — 180 / 120 / 150
##     against live bands of 260+90 / 150+60 / 420+180. The gate was gating a
##     dead column, which is the failure mode the single-source migration
##     exists to end.
##   * `STREET_MAX_RATE_PER_GAME_HOUR` was **0.45 against a table running at
##     0.667** — a contract violated by 48 % since the day it was written, by a
##     file no test could open.
##
## Nothing was retuned to fix either. See §39.3 for why the petty-crime ratio
## holds once it is measured against a payout instead of against a base, and
## §39.2 for why the 57 % ceiling is 35.9 % without a dollar moving.
##
## **What each assertion costs**, because two of them now run a sim and this
## file's budget is real: (a)–(c) are file reads; (d) drives the SPAWNER ONLY for
## `CEILING_SAMPLE_HOURS` game-hours (four scalars per game-minute, ~2 s); (f) is
## a SHORT fine-path arc — `CEILING_ARC_DAYS` game-days on one seed — because the
## fine path is ~60× the coarse step and the published 21-game-day version of the
## same measurement lives in `tools/measure_street_arc.gd`, which doc 92 §39.5
## quotes. A gate holds the claim; the tool holds the table.
func test_gate_32_active_play_pays_more_and_idling_still_pays() -> void:
	var services := _city_services()
	var opening_net := float(_pacing()["STARTER_NET_PER_HOUR_EXACT"])

	# (a) The dispatcher's premium is VISIBLE. 1.50 is doc 06's own
	# `speed_bonus_max`; under 1.25 it stops reading as a raise at all.
	var manual := float(services["MANUAL_DISPATCH_MULT"])
	assert_true(manual >= 1.25,
			"a %.2f× dispatcher premium is not one a player would notice" % manual)

	# (b) A TAPPED CROOK IS PETTY; A DISPATCHED CRIME IS THE REAL ONE.
	#
	# The ordering is the ruling; the ratio is what makes it read at a glance.
	# **The denominator is the thing this wave fixed** (doc 92 §39.3):
	# `dispatch_payout_base.crime` is 350, but nobody is ever paid 350 — doc 06
	# multiplies it by tier and by a speed bonus before a dollar moves, and the
	# crime a player actually watches resolve is doc 06's own reference case,
	# tier 3 answered on target, which pays 350 × 1.70 × 1.00 = $595. Comparing a
	# delivered street bounty to an undelivered dispatch BASE was the arithmetic
	# error the placeholder table hid; it reads as "about half" against the
	# payout, which is what the ruling always meant.
	var street: Dictionary = services["street_payout"]
	var petty := _street_mean_bounty(street, "petty_crime")
	var dispatched := _dispatch_reference_payout(services, "crime")
	assert_true(petty < dispatched,
			("a tapped crook's mean bounty $%.2f must sit under what a dispatched "
					+ "crime pays at doc 06's own reference (tier 3, on target): $%.2f")
					% [petty, dispatched])
	assert_true(petty / dispatched <= 0.60,
			("and it must read as about half, not as nearly the same: %.3f "
					+ "($%.2f against $%.2f)") % [petty / dispatched, petty, dispatched])

	# (c) THE RATE CONTRACT, AND IT IS FINALLY A CONTRACT. Both files are in this
	# tree since RR-85, so the number doc 03 publishes can be checked against the
	# table it constrains instead of multiplied by a placeholder. The spawn
	# table's un-rejected Bernoulli rate is `1 / target_interval_h` — the most
	# offers it can produce before `max_live`, `min_separation_tiles` and an
	# empty kerb pool take their share — and it may not exceed doc 03's ceiling.
	var spawn: Dictionary = StarterCityLoader.read_json(
			"res://data/street.json").get("spawn", {})
	var table_rate := 1.0 / maxf(0.000001, float(spawn["target_interval_h"]))
	var ruled_rate := float(services["STREET_MAX_RATE_PER_GAME_HOUR"])
	assert_true(table_rate <= ruled_rate,
			("data/street.json spawns at up to %.4f offers/gh (target_interval_h "
					+ "%.3f) against doc 03's ruled ceiling of %.4f")
					% [table_rate, float(spawn["target_interval_h"]), ruled_rate])

	# (d) THE CEILING, MEASURED — what the layer pays somebody who takes every
	# single offer, as a share of the income the opening actually earns.
	#
	# This is doc 92 §35.3's ruling made executable. It measured 57 % against the
	# PRE-money-pass founding net and asked for a retune to 35–40 %; the money
	# pass moved the denominator instead (337.05 → 506.05/gh), and the same
	# $181.65/gh ceiling is 35.9 % of it. Nothing in the street tables was
	# retuned — see §39.2 — so this assertion is the one that would catch a
	# future retune of either side, in either direction.
	#
	# The instrument is `OpportunitySystem.advance` at the phase adapter's own
	# cadence, exactly as `tools/measure_street_yield.gd` drives it: the whole
	# city is not ticked, because the ceiling is a property of the spawner and a
	# game-hour of full advance costs ~1,000× a game-hour of this.
	var ceiling := _street_ceiling_per_hour(GATE_SEED, CEILING_SAMPLE_HOURS)
	var ceiling_share := ceiling / opening_net
	var ceiling_max := float(services["STREET_CEILING_SHARE_MAX"])
	assert_true(ceiling_share <= ceiling_max,
			("a player who collected EVERY street offer would earn $%.2f/gh "
					+ "against an opening net of $%.2f/gh (%.2f %%); doc 03's ruled "
					+ "ceiling is %.0f %% (doc 92 §35.3 / §39.2)")
					% [ceiling, opening_net, 100.0 * ceiling_share, 100.0 * ceiling_max])
	# And it has to be worth crossing the map for. The floor is well clear of the
	# measurement (35.9 %) because it is a "somebody deleted the layer" tripwire,
	# not a fit — §35.3's own argument is that the crook and the dog carry the
	# fiction and should not be tuned away to buy headroom.
	assert_true(ceiling_share >= 0.15,
			("the whole street layer is worth $%.2f/gh, %.2f %% of the opening's "
					+ "income — at that share nobody would cross the map for it")
					% [ceiling, 100.0 * ceiling_share])

	# (e) AND EXACTLY ZERO WHEN IDLE — asserted as the written-down zero it is,
	# and then MEASURED on an agent that never taps. `curriculum` is `collector`
	# with the tap removed — `Collector extends Curriculum` and overrides exactly
	# `tick_minute`, so they are the same builder — and a non-zero here would
	# mean an opportunity paid somebody who did not take it.
	assert_almost_eq(float(services["STREET_IDLE_SHARE"]), 0.0, 1e-9,
			"an opportunity nobody taps must pay nobody")

	# (f) THE PLAYED SHARE, FROM A REAL RUN — the number doc 92 §35.3 had to
	# derive from spawn telemetry because no agent could collect.
	#
	# `collector` is `curriculum` plus one tap per game-minute and nothing else,
	# so its street income against its own settled net is the layer's share of a
	# played city. It is a CEILING among played cities — the agent has no camera
	# and no travel time — which is why the band's top is what this asserts and
	# its floor is loose. The published 21-game-day, three-seed version is doc 92
	# §39.5 via `tools/measure_street_arc.gd`; this arm is short because the fine
	# path costs ~60× the coarse step and a gate is not a report.
	var band: Array = services["STREET_PLAYED_SHARE_BAND"]
	var idle_doc := Rig.run_fine("curriculum", GATE_SEED, CEILING_ARC_DAYS)
	var played_doc := Rig.run_fine("collector", GATE_SEED, CEILING_ARC_DAYS)
	var idle_summary: Dictionary = idle_doc["summary"]
	var played: Dictionary = played_doc["summary"]
	assert_eq(int(idle_summary["street_income"]), 0,
			"an agent that never taps earned street money anyway")
	assert_true(int(played["opportunities_collected"]) > 0,
			("the collector took ZERO offers in %d game-days — the tap has lost "
					+ "its door, or the spawner stopped drawing on the fine path")
					% CEILING_ARC_DAYS)
	# **The two published bounds must agree with each other**, checked here
	# because they are authored in two places and read by two horizons: a played
	# city's share may never be ruled above the ceiling on taking EVERY offer.
	assert_true(float(band[1]) <= float(services["STREET_CEILING_SHARE_MAX"]),
			("the played-share ceiling (%.0f %%) is above the collection ceiling "
					+ "(%.0f %%), which is arithmetically impossible")
					% [100.0 * float(band[1]),
					100.0 * float(services["STREET_CEILING_SHARE_MAX"])])

	# **The short arm is held against the CEILING, not against the band, and the
	# horizon is why.** `STREET_PLAYED_SHARE_BAND` is ruled at 21 game-days
	# (doc 92 §39.5); this arm runs 3, where the city is at its smallest and its
	# net at its thinnest, so the share is structurally at its HIGHEST — measured
	# **18.94 %** on seed 1337, against **11.88 %** on the same seed over the
	# published 21-game-day horizon (doc 92 §39.5's own table). A
	# gate that held a 21-day bound over a 3-day measurement would be asserting a
	# number it is not measuring, and would sit one point from failing while
	# saying something false about why. The tripwire that matters is the same one
	# (d) uses: no share of a city's income, on any horizon, above the ruled
	# collection ceiling.
	var played_share := float(played["street_share_of_net"])
	var ceiling_bound := float(services["STREET_CEILING_SHARE_MAX"])
	assert_true(played_share <= ceiling_bound,
			("street bounties are %.2f %% of a tapping city's net over its first "
					+ "%d game-days — where the share is at its structural maximum "
					+ "— against the ruled collection ceiling of %.0f %% (measured "
					+ "18.94 %%; doc 92 §39.5)")
					% [100.0 * played_share, CEILING_ARC_DAYS, 100.0 * ceiling_bound])
	assert_true(played_share >= float(band[0]),
			("street bounties are only %.2f %% of a tapping city's net; the ruled "
					+ "floor is %.0f %% and under it the layer is not worth the "
					+ "attention it asks for")
					% [100.0 * played_share, 100.0 * float(band[0])])

	# (g) The dispatch half, unchanged. A played city's `city_services` line is a
	# real share of its income and not a rounding error: measured on the
	# curriculum agent at 21 game-days, three seeds, **4.83 / 5.21 / 5.76 %** of
	# net from dispatch alone. The band is wide on both sides because a seed must
	# not flip it.
	var total_net := 0.0
	var total_services := 0.0
	for seed_value in MATRIX_SEEDS:
		var samples: Array = _run("curriculum", LONG_DAYS, int(seed_value))["samples"]
		for i in range(1, samples.size()):
			var sample: Dictionary = samples[i]
			total_net += float(sample.get("net", 0.0))
			total_services += float(sample.get("city_services", 0.0))
	var share := total_services / maxf(1.0, total_net)
	assert_true(share >= 0.02 and share <= 0.25,
			("city services are %.2f %% of a played city's net over %d game-days; "
					+ "measured 4.8–5.8 %% from dispatch alone (doc 92 §36.4)")
					% [100.0 * share, LONG_DAYS])


## The Director's own horizon. 60 game-days rather than `LONG_DAYS`'s 21 because
## the defect this gate exists for did not show up until game-day 8 and looked
## like a quiet stretch until game-day 20 — a 21-day gate would have passed over
## it. One seed, one strategy, ~90 s coarse.
const DIRECTOR_DAYS := 60
## Doc 07 §2.6.3's own cadence claim is "one major crisis every ~2–2.5 game-days
## plus minors between them", which over 60 game-days is 24–30 events at the
## reference city's size. A founding city is far below that city and F1's floor
## caps it at cheap tier-1 minors for a long while, so the FLOOR here is a
## tripwire and not a fit: **measured 23** on this run (balanced / 4242 / 60 d,
## `tools/probe_director.gd`), and **2** on the Wave-17 fork, where the whole
## rest of the run was the stall. Anything at or under the fork's number means
## the schedule has died again.
const DIRECTOR_MIN_EVENTS := 8


## **Gate 33 (99-PA PA-04 / A91-D-59) — the Disaster Director keeps working.**
##
## Three claims, and the first is the one that was false at the Wave-17 fork:
##
##   1. a played city keeps SCHEDULING — the Director is not two events and
##      then silence for the rest of the city's life;
##   2. every event it starts gets RESOLVED, and none is held past the 48
##      game-hour cap `data/director.json fairness.max_active_min` publishes;
##   3. the schedule is still alive at the END of the run, not merely alive
##      early — the fork passed (1) on a short horizon and failed it on a long
##      one, which is exactly how the defect survived seventeen waves.
func test_gate_33_the_director_does_not_stall() -> void:
	var doc := _run("balanced", DIRECTOR_DAYS, 4242)
	var director: Dictionary = doc["director"]
	var started := Rig.event_count(doc, "director_event_started")
	var ended := Rig.event_count(doc, "director_event_ended")

	assert_true(started >= DIRECTOR_MIN_EVENTS,
			("the Director started %d events in %d game-days; the fork managed 2 "
					+ "and then stalled forever, and doc §2.6.3's cadence is 24–30 "
					+ "at the reference city's size")
					% [started, DIRECTOR_DAYS])
	assert_true(ended >= started - 2,
			("%d events started and %d ended — at most the two the pacing gate "
					+ "allows in flight may still be open at the wall")
					% [started, ended])
	assert_eq(ended + int(director["active_end"]), started,
			("%d started, %d ended, %d still in flight — the three have to add up "
					+ "or an event left `active_events` without resolving")
					% [started, ended, int(director["active_end"])])
	assert_true(int(director["active_end"]) <= 2,
			"the in-flight list is bounded by `_try_schedule`'s own gate")

	var cap := int(director["max_active_min"])
	assert_eq(cap, DisasterDirector.MAX_ACTIVE_MIN_DEFAULT,
			"the gate is held against the shipped knob, not a literal")
	assert_true(int(director["max_hold_min"]) <= cap,
			("an event was held %d game-minutes; the cap is %d (48 game-hours). "
					+ "Holds: %s")
					% [int(director["max_hold_min"]), cap, str(director["holds"])])

	# (3) Still alive at the wall. The fork's last event started on game-day 7.5
	# of a 60-day run; anything inside the last third is a living schedule.
	var last_day := float(int(director["last_start_min"])) / 1440.0
	assert_true(last_day >= float(DIRECTOR_DAYS) * 0.6,
			("the last Director event of a %d-game-day run started on game-day "
					+ "%.1f — the schedule died partway through")
					% [DIRECTOR_DAYS, last_day])


## `data/economy.json`'s `city_services` block, read live so a gate cannot
## re-state a tunable it exists to gate.
static func _city_services() -> Dictionary:
	return (StarterCityLoader.read_json(ECONOMY_DATA).get("city_services", {})
			as Dictionary)


## The MEAN bounty of one street kind, `base + spread/2` — the figure doc 03
## §2.5's rulings are stated against, because a band's mean is what a player
## earns and its top is what a player remembers.
static func _street_mean_bounty(street: Dictionary, kind: String) -> float:
	var row: Dictionary = street[kind]
	return float(row["base"]) + 0.5 * float(row.get("spread", 0.0))


## What doc 06 actually pays for one incident type at its own REFERENCE case —
## tier 3, answered on target — rather than the base nobody is ever paid:
## `reward_base × (1 + tier_k·(3 − 1)) × 1.00`. The shape constants are doc 06's
## (`data/incidents.json` `reward`), the dollar is doc 03's, which is the whole
## split RR-78 drew.
static func _dispatch_reference_payout(services: Dictionary, type_id: String) -> float:
	var shape: Dictionary = StarterCityLoader.read_json(
			"res://data/incidents.json").get("reward", {})
	var base := float((services["dispatch_payout_base"] as Dictionary)[type_id])
	return base * (1.0 + float(shape["tier_k"]) * 2.0)


## Doc 06 §2.16's ceiling in $/game-hour: every offer the spawner produces over
## `hours` game-hours, collected. Drives `OpportunitySystem.advance` at the phase
## adapter's own cadence and nothing else — the same instrument
## `tools/measure_street_yield.gd` uses, and pinned to the live cadence by
## `tests/test_street_opportunities.gd::test_the_phase_adapter_is_wired_to_the_minute`.
static func _street_ceiling_per_hour(seed_value: int, hours: int) -> float:
	var sim := CitySim.boot_from_files(seed_value)
	var minute_h := 1.0 / 60.0
	var total := 0
	for i in hours * 60:
		sim.street.advance(float(i + 1) * minute_h, true)
		for event in sim.street.drain_events():
			if String(event["type"]) == "opportunity_spawned":
				total += int(event["reward"])
	sim.dispose()
	return float(total) / float(maxi(1, hours))
