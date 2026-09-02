extends SimTest
## **99-PA PA-26 — the storm loop's player half.**
##
## Doc 07 §2.7.7 authors six preparation actions; §2.7.6 authors a Storm Report
## and a Storm Ready payout. At the Wave-17 fork none of it was reachable:
##
##   * `grep -c storm_prep sim/city_sim.gd` → **0** — no verb, no door;
##   * `DisasterDirector.storm_prep_action`'s own window test was
##     `storm.active` AND `−90 ≤ now − t0 ≤ −20`, which are never true together
##     because `storm.begin()` sets `t0 = now`;
##   * `grep -rn 'build_report\|storm_ready_earned' sim/ game/ ui/ | grep -v
##     'func '` → **nothing**: the report was never built and the 15 %
##     reimbursement never paid;
##   * `metrics.outage_customer_minutes` — the number Storm Ready is checked
##     against — had no writer, so the check reduced to "did the player press
##     three buttons".
##
## The player was told *"You have about {minutes} minutes to get ready"* and had
## nothing to do with it.

const DIRECTOR_DATA := "res://data/director.json"


func _ctx(tick_index: int) -> TimeContext:
	var clock := GameClock.new()
	clock.tick_index = tick_index
	var ctx := TimeContext.new()
	ctx.tick_index = tick_index
	ctx.game_seconds = clock.game_seconds()
	ctx.dt_game_seconds = 15
	ctx.mode = TimeContext.Mode.FINE
	ctx.is_catchup = false
	ctx.minute_of_day = clock.minute_of_day()
	ctx.hour_of_day = clock.hour_of_day()
	ctx.day_index = clock.day_index()
	ctx.season_index = clock.season_index()
	return ctx


## A city four game-days old with a `severe_thunderstorm` committed and its
## warning out — i.e. a city standing in the T−90 window, which is the only
## state any of this is reachable from.
func _city_in_the_window() -> CitySim:
	var sim := CitySim.boot_from_files(4242)
	sim.advance_coarse_hours(24 * 4, false)
	sim.director.debug_force_director_event("severe_thunderstorm",
			sim.build_director_inputs(), _ctx(sim.clock.tick_index))
	return sim


# --------------------------------------------------- the window and the door

func test_the_prep_window_is_measured_against_the_scheduled_row() -> void:
	# The fork's bug in one assertion: the window was tested against the ACTIVE
	# storm, and while a storm is active `now − t0 ≥ 0`, which is past T−20. The
	# window belongs to the row F7's warning went out for.
	var sim := _city_in_the_window()
	var window := sim.director.storm_prep_window()
	assert_true(bool(window["open"]), "the window is open at T−90")
	assert_eq(int(window["minutes_to_impact"]), 90,
			"doc 07's own warn_min for a severe thunderstorm")
	assert_eq(int(window["closes_at_min"]) - int(window["t0_min"]), -20,
			"…and it closes at T−20, which is `storm.phases.cell_entry_min`")
	assert_false(sim.director.storm.active, "the storm has not begun yet")
	sim.dispose()


func test_a_city_with_no_storm_refuses_by_name() -> void:
	var sim := CitySim.boot_from_files(4242)
	var result := sim.cmd_storm_prep_action("load_shed")
	assert_false(bool(result["ok"]))
	assert_eq(String(result["reason_code"]), "E_NO_STORM",
			"a refusal the sheet can put in words")
	var overview := sim.storm_prep_overview()
	assert_false(bool(overview["open"]), "…and the sheet knows the door is shut")
	assert_eq((overview["actions"] as Array).size(), 6,
			"all six rows are still drawn, greyed and priced")
	sim.dispose()


func test_the_six_actions_are_priced_by_doc_03_and_taken_once_each() -> void:
	var sim := _city_in_the_window()
	var curves := sim.econ_curves
	assert_eq(curves.storm_prep_cost("callout_crew"), 18000,
			"§2.7.7's $18,000 crew callout, read from data/economy.json")
	assert_eq(curves.storm_prep_cost("sandbag_block"), 6000, "§2.7.7's sandbag")
	assert_eq(curves.storm_prep_cost("pre_stage_crews", 2.0), 6000,
			"$3,000 per crew, two crews")
	assert_eq(curves.storm_prep_cost("load_shed"), 0, "load shed costs no capital")

	var before := sim.treasury.balance
	var result := sim.cmd_storm_prep_action("callout_crew")
	assert_true(bool(result["ok"]), "the crew is called out: %s"
			% String(result["reason_code"]))
	assert_eq(before - sim.treasury.balance, 18000,
			"doc 03 moved exactly the quoted dollar and nothing else")
	assert_false(bool(sim.cmd_storm_prep_action("callout_crew")["ok"]),
			"each action is once per storm")
	assert_eq(String(sim.cmd_storm_prep_action("callout_crew")["reason_code"]),
			"E_ALREADY_TAKEN")
	assert_eq(String(sim.cmd_storm_prep_action("not_an_action")["reason_code"]),
			"E_UNKNOWN_ACTION")
	assert_eq(String(sim.cmd_storm_prep_action("sandbag_block")["reason_code"]),
			"E_NO_TARGET", "a sandbag needs a block to put it on")
	sim.dispose()


func test_a_preview_quotes_and_charges_nothing() -> void:
	var sim := _city_in_the_window()
	var before := sim.treasury.balance
	var quote := sim.cmd_storm_prep_action("callout_crew", {}, true)
	assert_true(bool(quote["ok"]), "the preview says the door is open")
	assert_eq(int((quote["payload"] as Dictionary)["cost"]), 18000)
	assert_eq(sim.treasury.balance, before, "a preview is not a purchase")
	assert_eq(sim.director.prep_actions.size(), 0, "…and not a commitment")
	sim.dispose()


func test_the_window_closes_at_t_minus_20_and_the_door_says_so() -> void:
	var sim := _city_in_the_window()
	assert_true(bool(sim.cmd_storm_prep_action("load_shed")["ok"]),
			"open at T−90")
	# The Director's clock only moves on its own hourly phase, so the first
	# `advance_coarse_hours(1)` after a force lands before the next one — this
	# walks to T−30 (still open) and then to T+30 (shut, cell entering).
	sim.advance_coarse_hours(2, false)
	assert_eq(int(sim.director.storm_prep_window()["minutes_to_impact"]), 30,
			"T−30")
	assert_true(bool(sim.cmd_storm_prep_action("top_off_water")["ok"]),
			"still open at T−30")
	sim.advance_coarse_hours(1, false)
	var late := sim.cmd_storm_prep_action("recall_construction")
	assert_false(bool(late["ok"]), "shut once the cell is entering")
	assert_eq(String(late["reason_code"]), "E_PREP_WINDOW")
	sim.dispose()


# ----------------------------------------------------------- the effects

func test_load_shed_and_top_off_water_do_what_they_say() -> void:
	var sim := _city_in_the_window()
	var before_load := sim.modifiers.product_for("power_demand_residential")
	assert_true(bool(sim.cmd_storm_prep_action("load_shed")["ok"]))
	assert_almost_eq(sim.modifiers.product_for("power_demand_residential")
			/ before_load, 0.92, 1e-9, "§2.7.7's 8 % off the load")

	# Drain the tanks so the top-off has something to buy, then buy it.
	var tanks := 0
	for node_id in sim.water.nodes:
		var node: WaterNode = sim.water.nodes[node_id]
		if node.variant == &"tank":
			node.volume_m3 = 0.0
			tanks += 1
	assert_true(tanks > 0, "the starter city has a tank to top off")
	var deficit := sim._storm_water_deficit_m3()
	assert_true(deficit > 0.0, "an empty tank has a deficit")
	var quoted := sim.econ_curves.storm_prep_cost("top_off_water", deficit)
	var before := sim.treasury.balance
	assert_true(bool(sim.cmd_storm_prep_action("top_off_water")["ok"]))
	assert_eq(before - sim.treasury.balance, quoted,
			"the fill is billed per m³ of the water it actually adds")
	assert_almost_eq(sim._storm_water_deficit_m3(), 0.0, 1e-6,
			"and the tanks came out full")
	sim.dispose()


func test_a_called_out_crew_is_a_real_truck_and_goes_home_again() -> void:
	var sim := _city_in_the_window()
	# The catalog join, asserted first. `FleetSystem.add_unit` takes a
	# `data/vehicles.json` type id and a MISS spawns a truck from an empty row —
	# no department, no speed, no capabilities — a unit that counts toward the
	# fleet and can never be dispatched. (This test caught exactly that: the
	# constant read `utility_truck` and the roster says `utility_service_truck`.)
	var row: Dictionary = sim.incident_catalog.vehicle_type(
			CitySim.STORM_PREP_CALLOUT_TYPE)
	assert_false(row.is_empty(),
			"`%s` is not a `data/vehicles.json` type" % CitySim.STORM_PREP_CALLOUT_TYPE)
	assert_eq(String(row.get("department", "")), "utility",
			"§2.7.7 calls out a UTILITY crew")

	var before := sim.incidents.fleet.size()
	assert_true(bool(sim.cmd_storm_prep_action("callout_crew")["ok"]))
	assert_eq(sim.incidents.fleet.size(), before + 1,
			"§2.7.7's +1 temporary utility crew")
	var idle: Dictionary = sim.incidents.fleet.free_units_by_dept()
	assert_true(int(idle.get("utility", 0)) >= 1,
			"…and it reports for duty in the department that was called")
	# 12 game-hours, and then it is somebody else's truck again.
	sim.advance_coarse_hours(11, false)
	assert_eq(sim.incidents.fleet.size(), before + 1, "still on strength at 11 h")
	sim.advance_coarse_hours(2, false)
	assert_eq(sim.incidents.fleet.size(), before,
			"the callout is temporary, exactly as long as the table says")
	sim.dispose()


# --------------------------------------------------- the report and the payout

func test_the_storm_runs_schedule_to_report_and_pays_the_prepared_city() -> void:
	var sim := _city_in_the_window()
	sim.bus.drain()
	var taken := 0
	for action_id in ["load_shed", "top_off_water", "recall_construction"]:
		if bool(sim.cmd_storm_prep_action(action_id)["ok"]):
			taken += 1
	assert_eq(taken, 3, "§2.7.6's Storm Ready threshold is three actions")

	# Warning 90 min, storm 90–180 min, report at T+180: twelve game-hours is
	# past every one of them.
	var report := {}
	for _hour in 12:
		sim.advance_coarse_hours(1, false)
		for event in sim.bus.drain():
			if String(event.get("type", "")) == "storm_report_ready":
				report = event
	assert_false(report.is_empty(),
			"§2.7.6's STORM REPORT was built and published")
	assert_eq(String(report["kind"]), "severe_thunderstorm")
	assert_eq((report["prep_actions"] as Array).size(), 3,
			"the report carries the preparation it is a report on")
	assert_true(report.has("root_causes"), "…and §2.7.6's root-cause list")
	assert_true(report.has("metrics"), "…and the strike/incident counters")
	assert_true(bool(report["storm_ready"]),
			"three actions and an outage inside budget earns Storm Ready")
	assert_true(int(report["relief_paid"]) >= 0,
			"the reimbursement is the ledger's 15 %, and the ledger may be $0")
	assert_false(sim.director.storm.active, "the storm module stood down")
	assert_eq(sim.director.prep_actions.size(), 0,
			"and one storm's preparation is not carried to the next")
	sim.dispose()


func test_storm_ready_is_a_resilience_test_and_not_an_attendance_test() -> void:
	# `outage_customer_minutes` had no writer at the fork, so the budget half of
	# §2.7.6's check was vacuous: three taps earned the payout however dark the
	# city got. It is counted now.
	var sim := _city_in_the_window()
	var storm := sim.director.storm
	storm.begin(999, 1.0, 0.77, sim.clock.tick_index / GameClock.TICKS_PER_MINUTE,
			120, 8)
	storm.prep_actions = ["load_shed", "top_off_water", "callout_crew"]
	assert_true(storm.storm_ready_earned(45000),
			"a city that stayed lit earns it")
	var budget := 250.0 * 45000.0 / 1000.0
	storm.metrics["outage_customer_minutes"] = int(budget) + 1
	assert_false(storm.storm_ready_earned(45000),
			"a city that went dark past the budget does not, however prepared")
	storm.prep_actions = ["load_shed"]
	storm.metrics["outage_customer_minutes"] = 0
	assert_false(storm.storm_ready_earned(45000),
			"and one action is not three")
	sim.dispose()


func test_the_prep_ledger_survives_a_save_and_a_load() -> void:
	var sim := _city_in_the_window()
	assert_true(bool(sim.cmd_storm_prep_action("load_shed")["ok"]))
	assert_true(bool(sim.cmd_storm_prep_action("callout_crew")["ok"]))
	var body := sim.capture_state()
	var loaded := CitySim.boot_from_files(4242)
	loaded.restore_state(body)
	assert_eq(loaded.director.prep_actions, sim.director.prep_actions,
			"the preparation a player paid for is part of the city")
	assert_eq(loaded.director.prep_event_uid, sim.director.prep_event_uid)
	assert_eq((loaded._storm_prep_effects as Array).size(),
			(sim._storm_prep_effects as Array).size(),
			"…and so is the crew that still has to go home")
	assert_eq(loaded.state_hash(), sim.state_hash(),
			"save → load is a fixed point with the prep ledger in it")
	sim.dispose()
	loaded.dispose()
