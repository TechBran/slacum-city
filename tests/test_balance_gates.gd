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
## Doc 92's own horizon, for the gates whose thresholds it quotes there.
const LONG_DAYS := 21
## The cheaper horizon for the gates that only need a shape, not a threshold.
const SHORT_DAYS := 10

## One run per (strategy, days, seed) across the whole file: several gates read
## the same run and a 21-game-day `disaster_neglect` run is the most expensive
## thing here.
var _runs: Dictionary = {}


func _run(strategy: String, days: int = LONG_DAYS, seed_value: int = GATE_SEED) -> Dictionary:
	var key := "%s/%d/%d" % [strategy, days, seed_value]
	if not _runs.has(key):
		_runs[key] = Rig.run(strategy, seed_value, days)
	return _runs[key]


func _summary(strategy: String, days: int = LONG_DAYS) -> Dictionary:
	return _run(strategy, days)["summary"]


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
func test_gate_05_playing_beats_standing_still() -> void:
	var playing := _summary("balanced")
	var control := _summary("do_nothing")
	assert_true(int(playing["treasury_end"]) > int(control["treasury_end"]),
			"standing still is still richer: $%d against the player's $%d"
					% [int(control["treasury_end"]), int(playing["treasury_end"])])
	assert_true(int(playing["value_created"]) > int(control["value_created"]) * 2,
			"and it should not be close on value: $%d vs $%d"
					% [int(playing["value_created"]), int(control["value_created"])])
	assert_true(int(playing["population_end"]) > int(control["population_end"]) * 2,
			"a played city is a bigger city")


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
func test_gate_04_maintenance_pays() -> void:
	var maintained := _summary("balanced")
	var neglected := _summary("disaster_neglect")
	assert_true(int(maintained["repaired"]) > 0,
			"wear must give the repair verb something to do")
	assert_eq(int(neglected["repaired"]), 0, "the neglect knob is the only difference")
	assert_true(int(maintained["treasury_end"]) > int(neglected["treasury_end"]),
			"neglect still ends richer: $%d against $%d"
					% [int(neglected["treasury_end"]), int(maintained["treasury_end"])])
	assert_true(float(maintained["min_condition"]) > float(neglected["min_condition"]),
			"the agent that repairs should hold a higher floor condition: %.3f vs %.3f"
					% [float(maintained["min_condition"]), float(neglected["min_condition"])])
	assert_true(float(maintained["stability_end"]) > float(neglected["stability_end"]),
			"and a steadier city")
	assert_true(float(maintained["unserved_share"]) < float(neglected["unserved_share"]),
			"and a better-lit one")


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
## **AND THE FINDING THIS GATE EXISTS TO PIN.** The ruled coefficient is in force
## — `growth_rate_multiplier(TAX_RATE_MAX)` is 0.44, exactly as ruled — but in a
## HEALTHY city it multiplies zero, so max tax costs no population at all. Doc 03
## publishes the multiplier into `PopulationSystem.advance`, where it scales the
## RELAXATION of `attractiveness` toward `attractiveness_target(stability)`:
##
##     attractiveness += (target − attractiveness) × (1 − exp(−dt·mult/τ))
##
## `attractiveness_target(s) = clamp((s − 0.35) / 0.50, 0.25, 1.0)`, which is
## **1.0 for any stability ≥ 0.85**, and a founding city starts at attractiveness
## 1.0. `target − attractiveness` is therefore 0 and the multiplier has nothing to
## scale: a controlled pair at detent 5 and detent 12 ends 2, 3, 5, 7, 10 and 14
## game-days with **the same 224 people** and only the treasury differs. The knob
## bites exactly where the city is already hurt — it slows RECOVERY from a
## stability hit — which is a defensible design, but it is not the "money now
## versus a city later" tradeoff doc 92 F-5 costed the ruling against, and no
## value of `TAX_RATE_GROWTH_COEFF` can make it one. Recorded for pass 3.
##
## So the gate asserts both halves honestly: the coefficient is in force, it does
## bite on a city that has something to recover, and it does NOT bite on a healthy
## one — the last of which is the assertion that will fail, loudly, on the day
## someone reroutes the lever through `attractiveness_target`.
func test_gate_12_max_tax_costs_a_city() -> void:
	var economy := CitySim.boot_from_files(GATE_SEED).economy
	assert_almost_eq(economy.growth_rate_multiplier(0.16), 0.44, 1e-9,
			"1 − (0.16 − 0.09) × 8.0 — the ruled coefficient")
	assert_almost_eq(economy.happiness_tax_delta(0.16), -15.4, 1e-9, "unchanged")

	# Where the lever CAN bite: a city recovering from a stability hit.
	const DAYS := 3
	var base := _tax_pair_city(5, DAYS, 0.50)
	var maxed := _tax_pair_city(12, DAYS, 0.50)
	assert_eq(int(base["buildings"]), int(maxed["buildings"]),
			"the controlled pair must build identically")
	assert_true(int(maxed["treasury"]) > int(base["treasury"]),
			"the top detent still earns more money")
	assert_true(int(maxed["population"]) < int(base["population"]),
			"max tax must slow a recovering city: %d people against %d"
					% [int(maxed["population"]), int(base["population"])])

	# Where it CANNOT: a healthy city is pinned at the attractiveness ceiling.
	var healthy_base := _tax_pair_city(5, DAYS, -1.0)
	var healthy_max := _tax_pair_city(12, DAYS, -1.0)
	assert_eq(int(healthy_max["population"]), int(healthy_base["population"]),
			"TAX_RATE_GROWTH_COEFF now bites a healthy city — the lever has been "
			+ "rerouted past attractiveness_target, and this gate wants doc 92 "
			+ "F-5's real threshold (tax_squeezer trails balanced on population)")
	assert_true(int(healthy_max["treasury"]) > int(healthy_base["treasury"]) * 2,
			"...while the revenue side of the same detent is worth roughly double")


## Boot a city, hold `detent` from game-hour 0, fill the same 40 served tiles
## with houses in the same row-major order, and run. Everything but the detent is
## identical between the two calls, including the RNG seed.
## `attractiveness` < 0 leaves the founding value (1.0) alone; a value in (0,1]
## knocks the city down so the growth multiplier has something to scale.
static func _tax_pair_city(detent: int, days: int, attractiveness: float) -> Dictionary:
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
	for _h in days * 24:
		sim.advance_coarse_hours(1, false)
	return {"treasury": sim.treasury.balance, "population": sim.population.city_population,
			"buildings": built, "happiness": sim.happiness.happiness}


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


# =========================================================== deferred gates

## GATE 10 (DEFERRED — doc 92 F-4 is a `data/starter_city.json` ruling this pass
## did not receive, and that file is not in this agent's named keys).
## PROPOSED: first `E_UNSERVED` for `greedy_growth` before game-hour 48, once the
## founding transformer roster is thinned. TODAY: the founding core serves 510 of
## its 1,429 buildable tiles, so the fastest possible builder does not hit the
## wall for two game-weeks and `cmd_place_grid_component` — doc 93 §A's "THE
## game" — is optional for the whole pacing horizon. This PINS today's value: it
## fails the day the roster is thinned, which is when it wants its real threshold.
func test_gate_10_deferred_first_unserved_wall_is_pinned() -> void:
	assert_eq(int(_summary("greedy_growth", SHORT_DAYS)["unserved_walls"]), 0,
			"greedy_growth hit an E_UNSERVED wall inside %d game-days — F-4 may have "
			% SHORT_DAYS + "landed, and this gate now wants doc 92's < game-hour 48")


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


## GATE 14 (DEFERRED — pass-1 F-7 is a command-layer ruling this pass did not
## receive). PROPOSED: `cmd_place_building` refuses a locked archetype with
## `E_CITY_LEVEL`, as `cmd_upgrade_building` already does. TODAY it does not, and
## the build sheet's `locked` flag is a UI courtesy the sim does not enforce —
## `data/buildings.json` gives `apartment` L1 `min_city_level` 1, so enforcing it
## would change which archetypes exist at city level 0 and re-price every curve in
## doc 92. That is a balance ruling, not a bug fix. This pins the behaviour.
func test_gate_14_deferred_min_city_level_is_unenforced() -> void:
	var sim := CitySim.boot_from_files(GATE_SEED)
	assert_eq(sim.progression.city_level, 0)
	assert_eq(int(sim.catalog.stats("apartment", 1).get("min_city_level", 0)), 1,
			"apartment L1 is authored as a city-level-1 unlock")
	var origin := _vacant_served_tile(sim, Vector2i(2, 2))  # apartment is 2×2
	assert_true(origin.x >= 0, "the core has a serviceable 2×2 lot")
	var placed := sim.cmd_place_building("apartment", origin)
	assert_true(bool(placed["ok"]),
			"placement now enforces min_city_level — pass-1 F-7 has been ruled, and "
			+ "this gate wants its real threshold (E_CITY_LEVEL). Got: %s"
					% String(placed["reason_code"]))
