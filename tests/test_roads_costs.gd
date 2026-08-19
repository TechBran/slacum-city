extends SimTest
## Doc 10 §2.6 / §2.11 / §2.12 — the cost function, the dark-signal penalty
## (report 98 G-6), the heuristic, and the RR-3 [0,1] condition scale.
## Test plan cases 10–13, 45, 48.

const AVENUE := RoadTunables.CLASS_AVENUE
const STREET := RoadTunables.CLASS_STREET


# --------------------------------------------------- §2.6 worked example C

func test_worked_example_c_arithmetic() -> void:
	# The pure-function reproduction: no graph, just RoadCosts.
	var tun := RoadsTestRig.tunables()
	var speed := 26.0 * 1.25  # doc 06 fire_engine 26.0 x siren_mult 1.25
	assert_almost_eq(speed, 32.5, 1e-9)
	var wx := float(tun.weather_row("heavy_rain")["slowdown"])
	var f_wx := RoadCosts.f_weather(wx, tun.wx_resist(RouteProfile.RouteClass.EMERGENCY))
	assert_almost_eq(f_wx, 1.1350, 1e-6, "heavy_rain 0.18 with EMERGENCY wx_resist 0.25")
	var relief := tun.cong_relief(RouteProfile.RouteClass.EMERGENCY)

	var e_a := RoadCosts.free_flow_gm(480.0, speed, tun.class_mult(AVENUE)) \
			* RoadCosts.f_cong(tun.s_cong(AVENUE), 0.72, relief) \
			* RoadCosts.f_cond(0.92, tun.cond_penalty_max) * 1.00 * f_wx
	var n1 := RoadCosts.node_delay_gm(true, true, 4, 1.15,
			tun.node_relief(RouteProfile.RouteClass.EMERGENCY), tun.stop_delay_gm,
			tun.signal_delay_gm, tun.dark_signal_delay_gm, tun.powered_congestion_coeff,
			tun.dark_congestion_coeff)
	var e_b := RoadCosts.free_flow_gm(240.0, speed, tun.class_mult(STREET)) \
			* RoadCosts.f_cong(tun.s_cong(STREET), 1.15, relief) \
			* RoadCosts.f_cond(0.61, tun.cond_penalty_max) \
			* float((tun.cause_row("accident_minor")["mult"] as Array)[0]) * f_wx
	var n2 := RoadCosts.node_delay_gm(true, false, 4, 0.48,
			tun.node_relief(RouteProfile.RouteClass.EMERGENCY), tun.stop_delay_gm,
			tun.signal_delay_gm, tun.dark_signal_delay_gm, tun.powered_congestion_coeff,
			tun.dark_congestion_coeff)
	var e_c := RoadCosts.free_flow_gm(160.0, speed, tun.class_mult(STREET)) \
			* RoadCosts.f_cong(tun.s_cong(STREET), 0.48, relief) \
			* RoadCosts.f_cond(0.88, tun.cond_penalty_max) * 1.00 * f_wx

	assert_almost_eq(e_a, 15.3276, 0.001, "E_a")
	assert_almost_eq(n1, 0.1032, 1e-4, "N1 powered signal at c=1.15")
	assert_almost_eq(e_b, 16.9284, 0.001, "E_b with accident_minor")
	assert_almost_eq(n2, 0.3528, 1e-4, "N2 DARK signal at c=0.48")
	assert_almost_eq(e_c, 6.3934, 0.001, "E_c")
	assert_almost_eq(e_a + n1 + e_b + n2 + e_c, 39.105, 0.002, "worked example C total")


func test_worked_example_c_routed() -> void:
	# The same numbers through the real planner, on a real graph.
	var rig := RoadsTestRig.worked_example_c()
	var net: RoadNetwork = rig["net"]
	net.planner.quantise = false  # the example is authored at exact c values
	net.weather_state = "heavy_rain"
	net.planner.wx_slowdown = float(net.tun.weather_row("heavy_rain")["slowdown"])
	RoadsTestRig.force_edge(net, int(rig["e_a"]), 0.92, 0.72)
	RoadsTestRig.force_edge(net, int(rig["e_b"]), 0.61, 1.15)
	RoadsTestRig.force_edge(net, int(rig["e_c"]), 0.88, 0.48)
	net.graph.node(int(rig["n2"]))["powered"] = false
	net.add_closure([Vector2i(60, 35)], "accident_minor", 0.5, 999999)
	# add_closure re-prices congestion; restore the authored snapshot.
	RoadsTestRig.force_edge(net, int(rig["e_a"]), 0.92, 0.72)
	RoadsTestRig.force_edge(net, int(rig["e_b"]), 0.61, 1.15)
	RoadsTestRig.force_edge(net, int(rig["e_c"]), 0.88, 0.48)

	assert_almost_eq(float(net.graph.edge(int(rig["e_a"]))["length_m"]), 480.0, 1e-6, "E_a 480 m")
	assert_almost_eq(float(net.graph.edge(int(rig["e_b"]))["length_m"]), 240.0, 1e-6, "E_b 240 m")
	assert_almost_eq(float(net.graph.edge(int(rig["e_c"]))["length_m"]), 160.0, 1e-6, "E_c 160 m")
	assert_true(bool(net.graph.node(int(rig["n1"]))["signalised"]), "N1 signalised")
	assert_true(bool(net.graph.node(int(rig["n2"]))["signalised"]), "N2 signalised")

	var engine := RouteProfile.emergency(32.5, 0)
	var result := net.planner.find_path(rig["start"], rig["goal"], engine, {"epsilon": 1.0})
	assert_true(bool(result["ok"]), "the storm route exists")
	assert_almost_eq(float(result["minutes"]), 39.105, 0.01,
			"fire engine, storm + blackout + accident")

	# Same route as a CIVILIAN: 2.04x the fire engine.
	var civilian := RouteProfile.civilian(34.0)
	civilian.ignores_closures = true  # accident_minor is x3.0, not a block, for civilians
	var civ := net.planner.find_path(rig["start"], rig["goal"], civilian, {"epsilon": 1.0})
	assert_true(bool(civ["ok"]))
	assert_almost_eq(float(civ["minutes"]), 79.92, 0.02, "civilian pays 2.04x")
	assert_almost_eq(float(civ["minutes"]) / float(result["minutes"]), 2.04, 0.01)


func test_worked_example_c_clear_baseline() -> void:
	var rig := RoadsTestRig.worked_example_c()
	var net: RoadNetwork = rig["net"]
	net.planner.quantise = false
	net.planner.wx_slowdown = 0.0
	RoadsTestRig.force_edge(net, int(rig["e_a"]), 1.0, 0.0)
	RoadsTestRig.force_edge(net, int(rig["e_b"]), 1.0, 0.0)
	RoadsTestRig.force_edge(net, int(rig["e_c"]), 1.0, 0.0)
	var engine := RouteProfile.emergency(32.5, 0)
	var result := net.planner.find_path(rig["start"], rig["goal"], engine, {"epsilon": 1.0})
	assert_almost_eq(float(result["minutes"]), 24.219, 0.01, "clear, c=0, condition 1.0")
	# The storm-plus-blackout tax is +14.9 gm — a 1.615x degradation.
	assert_almost_eq(39.105 / 24.219, 1.615, 0.001, "degradation factor")


# ------------------------------------------------------- privileges & signals

func test_emergency_privileges_monotone() -> void:
	var tun := RoadsTestRig.tunables()
	var tiles := RoadsTestRig.line(Vector2i(0, 0), Vector2i(20, 0), STREET)
	var net := RoadsTestRig.network_with(tiles)
	net.planner.quantise = false
	net.planner.wx_slowdown = float(tun.weather_row("snow")["slowdown"])
	var edge_id: int = net.graph.edge_ids_sorted()[0]
	var checked := 0
	for cause in tun.closure_causes.keys():
		var row := tun.cause_row(cause)
		net.graph.edge(edge_id)["closure_cause"] = cause
		for c in [0.0, 0.5, 1.0, 1.5, 2.0]:
			net.graph.edge(edge_id)["congestion"] = c
			var costs: Array[float] = []
			for route_class in [RouteProfile.RouteClass.EMERGENCY,
					RouteProfile.RouteClass.UTILITY, RouteProfile.RouteClass.CIVILIAN]:
				costs.append(net.planner.edge_cost_gm(edge_id,
						RouteProfile.new(30.0, route_class)))
			checked += 1
			if bool(row.get("hard", false)):
				for cost in costs:
					assert_true(is_inf(cost), "%s is a hard block for every class" % cause)
				continue
			assert_true(costs[0] < costs[1],
					"%s at c=%f: EMERGENCY (%f) must beat UTILITY (%f)"
					% [cause, c, costs[0], costs[1]])
			assert_true(costs[1] <= costs[2],
					"%s at c=%f: UTILITY (%f) <= CIVILIAN (%f)" % [cause, c, costs[1], costs[2]])
	assert_eq(checked, 40, "8 causes x 5 congestion levels")


func test_dark_signal_penalty() -> void:
	var tun := RoadsTestRig.tunables()
	# §2.6 / G-6: 10 signals at c = 1.0, civilian, powered vs dark.
	var powered := 10.0 * RoadCosts.node_delay_gm(true, true, 4, 1.0, 0.0,
			tun.stop_delay_gm, tun.signal_delay_gm, tun.dark_signal_delay_gm,
			tun.powered_congestion_coeff, tun.dark_congestion_coeff)
	var dark := 10.0 * RoadCosts.node_delay_gm(true, false, 4, 1.0, 0.0,
			tun.stop_delay_gm, tun.signal_delay_gm, tun.dark_signal_delay_gm,
			tun.powered_congestion_coeff, tun.dark_congestion_coeff)
	assert_almost_eq(powered, 2.4, 1e-9, "10 x 0.12 x (1 + 1.0)")
	assert_almost_eq(dark, 13.5, 1e-9, "10 x 0.45 x (1 + 2 x 1.0)")
	assert_almost_eq(dark - powered, 11.1, 1e-9, "the dark-signal tax is +11.1 gm")
	assert_almost_eq(tun.dark_signal_delay_gm, 0.45, 1e-9, "doc 10 owns DARK_SIGNAL_DELAY")
	assert_almost_eq(tun.dark_signal_add, 0.19, 1e-9, "doc 10 owns DARK_SIGNAL_ADD")


func test_dark_signal_has_no_step_lag() -> void:
	# Power is read at P08 from THIS step's P06 output: cutting power and
	# stepping once must change the quote in the same step, and restoring it
	# must revert exactly.
	var rig := RoadsTestRig.worked_example_c()
	var net: RoadNetwork = rig["net"]
	net.planner.quantise = false
	var dark_tiles: Dictionary = {}
	net.power_is_tile_powered = func(t: Vector2i) -> bool: return not dark_tiles.has(t)
	var engine := RouteProfile.emergency(32.5, 0)
	# Converge congestion first, so the only thing that moves is the signal.
	# (`c_e` has smoothing memory: a dark signal adds DARK_SIGNAL_ADD to c_raw
	# as well as DARK_SIGNAL_DELAY to the node, and the congestion half of the
	# penalty takes a couple of game-minutes to bleed off again.)
	_settle(net, 0, 200)
	var lit := net.route_minutes(rig["start"], rig["goal"], engine)
	dark_tiles[Vector2i(60, 50)] = true
	net.step(RoadsTestRig.context(200, 12.0))
	var blacked := net.route_minutes(rig["start"], rig["goal"], engine)
	assert_true(blacked > lit, "a dark signal costs more in the SAME step (%f > %f)"
			% [blacked, lit])
	dark_tiles.clear()
	_settle(net, 201, 200)
	var restored := net.route_minutes(rig["start"], rig["goal"], engine)
	assert_almost_eq(restored, lit, 1e-6, "and reverts exactly once congestion settles")


func _settle(net: RoadNetwork, from_tick: int, count: int) -> void:
	for i in count:
		var ctx := RoadsTestRig.context(from_tick + i, 12.0)
		net.step(ctx)
		net.full_pass(ctx)


# -------------------------------------------------------------- the heuristic

func test_heuristic_admissible() -> void:
	# h(n) must never exceed the true cost from n to the goal, over a randomised
	# 40x40 grid of streets and avenues with random congestion and condition.
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var tiles: Dictionary = {}
	for i in range(0, 40, 4):
		RoadsTestRig.merge(tiles, RoadsTestRig.line(Vector2i(0, i), Vector2i(39, i),
				AVENUE if i % 8 == 0 else STREET))
		RoadsTestRig.merge(tiles, RoadsTestRig.line(Vector2i(i, 0), Vector2i(i, 39),
				AVENUE if i % 12 == 0 else STREET), false)
	var net := RoadsTestRig.network_with(tiles)
	net.planner.wx_slowdown = 0.22
	for edge_id in net.graph.edge_ids_sorted():
		net.graph.edge(edge_id)["congestion"] = rng.randf() * 2.0
		net.graph.edge(edge_id)["condition"] = 0.2 + rng.randf() * 0.8
	var prof := RouteProfile.emergency(28.0, 0)
	var nodes := net.graph.node_ids_sorted()
	var violations := 0
	for i in 120:
		var a: int = nodes[rng.randi_range(0, nodes.size() - 1)]
		var b: int = nodes[rng.randi_range(0, nodes.size() - 1)]
		if a == b:
			continue
		var goal_tile: Vector2i = net.graph.node(b)["tile"]
		var start_tile: Vector2i = net.graph.node(a)["tile"]
		var h := net.planner.heuristic_gm(start_tile, goal_tile, prof)
		var result := net.planner.find_path(start_tile, goal_tile, prof, {"epsilon": 1.0})
		if not bool(result["ok"]):
			continue
		if h > float(result["minutes"]) + 1e-9:
			violations += 1
	assert_eq(violations, 0, "the Manhattan/fastest-class heuristic is admissible")


# ------------------------------------------------- RR-3: condition on [0,1]

func test_condition_factor_table() -> void:
	var tun := RoadsTestRig.tunables()
	assert_almost_eq(RoadCosts.f_cond(1.00, tun.cond_penalty_max), 1.0000, 1e-9)
	assert_almost_eq(RoadCosts.f_cond(0.75, tun.cond_penalty_max), 1.0375, 1e-9,
			"RR-3: 1 + 0.60 x 0.25^2")
	assert_almost_eq(RoadCosts.f_cond(0.50, tun.cond_penalty_max), 1.1500, 1e-9)
	assert_almost_eq(RoadCosts.f_cond(0.25, tun.cond_penalty_max), 1.3375, 1e-9,
			"RR-3: 1 + 0.60 x 0.75^2")
	assert_almost_eq(RoadCosts.f_cond(0.01, tun.cond_penalty_max), 1.5881, 1e-4)


func test_condition_hazard_mult_table() -> void:
	# Report 98 C-48 / RR-3: doc 06 feeds 1.00 / 0.55 / 0.10, not 100 / 55 / 10.
	var tun := RoadsTestRig.tunables()
	var coeff := tun.hazard_condition_coeff
	var threshold := tun.hazard_condition_threshold
	assert_almost_eq(RoadCosts.condition_hazard_mult(0.10, coeff, threshold), 1.26, 1e-9)
	assert_almost_eq(RoadCosts.condition_hazard_mult(0.55, coeff, threshold), 1.08, 1e-9)
	assert_almost_eq(RoadCosts.condition_hazard_mult(0.75, coeff, threshold), 1.00, 1e-9)
	assert_almost_eq(RoadCosts.condition_hazard_mult(1.00, coeff, threshold), 1.00, 1e-9,
			"never below 1.0")


func test_condition_tiers() -> void:
	var tun := RoadsTestRig.tunables()
	assert_eq(RoadCosts.condition_tier(1.00, tun.tier_good, tun.tier_poor, tun.tier_failing),
			&"good")
	assert_eq(RoadCosts.condition_tier(0.60, tun.tier_good, tun.tier_poor, tun.tier_failing),
			&"worn")
	assert_eq(RoadCosts.condition_tier(0.30, tun.tier_good, tun.tier_poor, tun.tier_failing),
			&"poor")
	assert_eq(RoadCosts.condition_tier(0.10, tun.tier_good, tun.tier_poor, tun.tier_failing),
			&"failing")
	assert_eq(RoadCosts.condition_tier(0.00, tun.tier_good, tun.tier_poor, tun.tier_failing),
			&"collapsed")


func test_roads_json_condition_constants_are_unit_interval() -> void:
	# Test 48: no condition constant > 1.0 in the condition / decay / hazard blocks.
	var data := StarterCityLoader.read_json("res://data/roads.json")
	var condition: Dictionary = data["condition"]
	for key in ["congestion_wear_coeff", "poor_civilian_speed_mult", "repair_crew_hours_base",
			"auto_repair_default_threshold"]:
		assert_true(float(condition[key]) <= 1.0, "condition.%s <= 1.0" % key)
	for key in (condition["tiers"] as Dictionary):
		assert_true(float(condition["tiers"][key]) <= 1.0, "tier %s on [0,1]" % key)
	for key in (condition["damage"] as Dictionary):
		if String(key).begins_with("_") or String(key).ends_with("_tiles"):
			continue
		assert_true(absf(float(condition["damage"][key])) <= 1.0,
				"damage delta %s on [-1,1]" % key)
	for road_class in (data["classes"] as Dictionary):
		assert_true(float(data["classes"][road_class]["condition_base_decay"]) <= 1.0,
				"%s decay is a fraction per game-day" % road_class)
	assert_almost_eq(float(data["hazard"]["condition_threshold"]), 0.75, 1e-9)
	assert_almost_eq(float(data["hazard"]["condition_coeff"]), 0.40, 1e-9)


# ------------------------------------------------------------ C-62 lookup

func test_e_avenue_lookup() -> void:
	# Report 98 C-62: doc 10 supplies the lookup; doc 02 owns the gate itself.
	var tiles := RoadsTestRig.line(Vector2i(50, 20), Vector2i(50, 30), AVENUE)
	var net := RoadsTestRig.network_with(tiles)
	assert_true(net.has_class_within(Vector2i(54, 25), AVENUE, 4), "Chebyshev 4 is inside")
	assert_false(net.has_class_within(Vector2i(55, 25), AVENUE, 5 - 1), "Chebyshev 5 is outside")
	assert_true(net.has_class_within(Vector2i(55, 25), AVENUE, 5), "and inside at radius 5")
	assert_false(net.has_class_within(Vector2i(54, 25), STREET, 4), "class-specific")
	# sim/roads/ must never evaluate the L4/L5 gate itself — the blocker code is
	# doc 02's. Comments may NAME it; no line of code may produce it.
	for file in ["road_network.gd", "road_graph.gd", "route_planner.gd", "road_costs.gd"]:
		var source := FileAccess.get_file_as_string("res://sim/roads/" + file)
		for line in source.split("\n"):
			var comment_at := line.find("#")
			var code: String = line.substr(0, comment_at) if comment_at >= 0 else line
			assert_false(code.contains("E_AVENUE"),
					"%s emits the doc-02 blocker code: %s" % [file, code])


func test_estimators_are_admissible_and_ranked() -> void:
	var tun := RoadsTestRig.tunables()
	var a := Vector2i(10, 10)
	var b := Vector2i(30, 40)
	var optimistic := RoadCosts.estimate_eta_gm(a, b, 32.0, tun.tile_m,
			tun.estimate_class_mult_max)
	# (20 + 30) tiles x 8 m / (32 x 1.25)
	assert_almost_eq(optimistic, 400.0 / 40.0, 1e-9)
	var practical := RoadCosts.estimate_eta_practical_gm(optimistic, tun.detour_factor,
			tun.practical_congestion_coeff, 1.0)
	assert_almost_eq(practical, 10.0 * 1.25 * 1.45, 1e-9,
			"DETOUR_FACTOR 1.25 and +45% at capacity")
	assert_true(practical > optimistic, "the ranking estimate is never the optimistic one")
