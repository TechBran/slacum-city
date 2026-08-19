extends SimTest
## Doc 10 §2.10 / §2.12 — the congestion model (worked example D), smoothing,
## spillback, density, decay math. Test plan cases 26–30, 33, 42.

const AVENUE := RoadTunables.CLASS_AVENUE
const STREET := RoadTunables.CLASS_STREET

const MIXED := {"res": 0.55, "com": 0.30, "ind": 0.05, "civ": 0.10}
const COMMERCIAL := {"res": 0.20, "com": 0.70, "ind": 0.00, "civ": 0.10}


func _corridor(road_class: int) -> RoadNetwork:
	var tiles := RoadsTestRig.line(Vector2i(0, 10), Vector2i(20, 10), road_class)
	return RoadsTestRig.network_with(tiles)


# ------------------------------------------------------- §2.10 worked example D

func test_tod_curve_interpolation() -> void:
	var net := _corridor(STREET)
	var model := net.congestion
	assert_almost_eq(model.d_tod(MIXED, 2.0), 0.0565, 1e-4, "02:00")
	assert_almost_eq(model.d_tod(MIXED, 13.0), 0.5725, 1e-4, "13:00")
	assert_almost_eq(model.d_tod(MIXED, 17.0 + 40.0 / 60.0), 0.8542, 1e-4, "17:40 interpolated")
	assert_almost_eq(model.d_tod(COMMERCIAL, 17.0 + 40.0 / 60.0), 0.8550, 1e-4,
			"commercial mix at 17:40")


func test_worked_example_d_table() -> void:
	var net := _corridor(STREET)
	var edge_id: int = net.graph.edge_ids_sorted()[0]
	# pj = 410 -> L_dens = 0.20 + 0.0022 x 410 = 1.102
	net.congestion.refresh_density({edge_id: 410.0})
	assert_almost_eq(net.congestion.density_of(edge_id), 1.102, 1e-6, "L_dens")
	var weights := {"": MIXED}

	var quiet := net.congestion.c_raw(edge_id,
			{"hour": 2.0, "weights": weights, "wx_cong_add": 0.0})
	assert_almost_eq(quiet, 0.062, 1e-3, "02:00 empty")
	var midday := net.congestion.c_raw(edge_id,
			{"hour": 13.0, "weights": weights, "wx_cong_add": 0.0})
	assert_almost_eq(midday, 0.631, 1e-3, "13:00 free-flowing")
	var rush := net.congestion.c_raw(edge_id,
			{"hour": 17.0 + 40.0 / 60.0, "weights": weights, "wx_cong_add": 0.0})
	assert_almost_eq(rush, 0.941, 1e-3, "17:40 at capacity")

	# heavy_rain (+0.19) plus one dark signalised endpoint (+0.19).
	var storm := net.congestion.c_raw(edge_id, {"hour": 17.0 + 40.0 / 60.0,
			"weights": weights, "wx_cong_add": 0.19, "i_inc": {edge_id: 0.19}})
	assert_almost_eq(storm, 1.321, 1e-3, "17:40 over capacity")
	# ... plus an accident_minor (cong_add 0.56).
	var jam := net.congestion.c_raw(edge_id, {"hour": 17.0 + 40.0 / 60.0,
			"weights": weights, "wx_cong_add": 0.19, "i_inc": {edge_id: 0.19 + 0.56}})
	assert_almost_eq(jam, 1.881, 1e-3, "17:40 near gridlock")
	assert_true(jam < net.tun.congestion_index_max,
			"the worst case is 1.881, NOT the clamp — the [0,2] headroom is real")


func test_smoothing_ramp() -> void:
	# §2.10: from c = 0.90 toward 1.881 at 1 game-minute per step.
	var net := _corridor(STREET)
	var edge_id: int = net.graph.edge_ids_sorted()[0]
	net.congestion.refresh_density({edge_id: 410.0})
	var inputs := {"hour": 17.0 + 40.0 / 60.0, "weights": {"": MIXED},
			"wx_cong_add": 0.19, "i_inc": {edge_id: 0.75}, "dt_game_minutes": 1.0}
	net.congestion.set_congestion(edge_id, 0.90)
	var expected := [1.244, 1.467, 1.612]
	for i in 3:
		net.congestion.recompute([edge_id], inputs)
		assert_almost_eq(net.congestion.congestion_of(edge_id), float(expected[i]), 1e-3,
				"minute %d of the ramp" % (i + 1))
	for i in 3:
		net.congestion.recompute([edge_id], inputs)
	assert_almost_eq(net.congestion.congestion_of(edge_id), 1.807, 1e-3, "minute 6")


func test_coarse_step_lands_on_c_raw() -> void:
	# The dt-aware exponent is what makes coarse offline steps agree with fine
	# online steps: 1 - 0.65^60 ~ 1.0, i.e. one coarse hour lands ON c_raw.
	var net := _corridor(STREET)
	var edge_id: int = net.graph.edge_ids_sorted()[0]
	net.congestion.refresh_density({edge_id: 410.0})
	var inputs := {"hour": 13.0, "weights": {"": MIXED}, "wx_cong_add": 0.0,
			"dt_game_minutes": 60.0}
	net.congestion.set_congestion(edge_id, 0.0)
	var target := net.congestion.c_raw(edge_id, inputs)
	net.congestion.recompute([edge_id], inputs)
	assert_almost_eq(net.congestion.congestion_of(edge_id), target, 1e-9,
			"one coarse step lands exactly on c_raw")
	assert_almost_eq(RoadCosts.smoothing_alpha(0.35, 60.0), 1.0, 1e-9)
	assert_almost_eq(RoadCosts.smoothing_alpha(0.35, 1.0), 0.35, 1e-12)


func test_congestion_no_feedback_converges() -> void:
	# 500 ticks with a frozen clock must converge and never oscillate.
	var net := _corridor(STREET)
	var edge_id: int = net.graph.edge_ids_sorted()[0]
	net.congestion.refresh_density({edge_id: 410.0})
	var inputs := {"hour": 17.6, "weights": {"": MIXED}, "wx_cong_add": 0.0,
			"dt_game_minutes": 0.25}
	var previous := 0.0
	for i in 500:
		net.congestion.recompute([edge_id], inputs)
		var current := net.congestion.congestion_of(edge_id)
		if i >= 30:
			assert_true(current >= previous - 1e-9, "monotone approach, never oscillating")
		previous = current
	var settled := net.congestion.congestion_of(edge_id)
	net.congestion.recompute([edge_id], inputs)
	assert_almost_eq(net.congestion.congestion_of(edge_id), settled, 1e-4,
			"|dc| < 1e-4 once settled")


func test_avenue_beats_street() -> void:
	# §2.10: same corridor, density and hour; avenue c = 0.876 vs street 1.368.
	var avenue := _corridor(AVENUE)
	var street := _corridor(STREET)
	var a_edge: int = avenue.graph.edge_ids_sorted()[0]
	var s_edge: int = street.graph.edge_ids_sorted()[0]
	avenue.congestion.refresh_density({a_edge: 900.0})
	street.congestion.refresh_density({s_edge: 900.0})
	assert_almost_eq(avenue.congestion.density_of(a_edge), 1.60, 1e-9, "L_dens clamps at 1.60")
	var inputs := {"hour": 17.0 + 40.0 / 60.0, "weights": {"": COMMERCIAL},
			"wx_cong_add": 0.0}
	var a_c := avenue.congestion.c_raw(a_edge, inputs)
	var s_c := street.congestion.c_raw(s_edge, inputs)
	assert_almost_eq(a_c, 0.876, 1e-3, "avenue at capacity")
	assert_almost_eq(s_c, 1.368, 1e-3, "the same corridor as street is over capacity")

	# The travel-cost ratio the avenue's 2.8x build work buys.
	avenue.planner.quantise = false
	street.planner.quantise = false
	avenue.congestion.set_congestion(a_edge, a_c)
	street.congestion.set_congestion(s_edge, s_c)
	var prof := RouteProfile.emergency(32.0, 0)
	var ratio := street.planner.edge_cost_gm(s_edge, prof) \
			/ avenue.planner.edge_cost_gm(a_edge, prof)
	# DOC DEVIATION (REPORT finding D-2): doc test 30 asserts >= 1.85x, but its
	# own constants give 1.48x for EMERGENCY and 1.77x for CIVILIAN. The
	# direction and the magnitude of the payoff are real; the 1.85 threshold is
	# not reachable from the published table.
	assert_true(ratio > 1.45, "the avenue is materially cheaper for an engine (%f)" % ratio)
	var civ := RouteProfile.civilian(34.0)
	var civ_ratio := street.planner.edge_cost_gm(s_edge, civ) \
			/ avenue.planner.edge_cost_gm(a_edge, civ)
	assert_true(civ_ratio > 1.75, "and much cheaper for civilians (%f)" % civ_ratio)


# ------------------------------------------------------------------ spillback

func test_spillback_depth() -> void:
	# A closure raises I_inc on its own edge, 0.5x at 1 hop, 0.25x at 2, 0 at 3.
	var tiles: Dictionary = {}
	RoadsTestRig.merge(tiles, RoadsTestRig.line(Vector2i(0, 10), Vector2i(40, 10), STREET))
	# Cross-streets every 5 tiles make real graph nodes, so hops are real hops.
	for x in [5, 10, 15, 20, 25, 30, 35]:
		RoadsTestRig.merge(tiles, RoadsTestRig.line(Vector2i(x, 8), Vector2i(x, 12), STREET), false)
	var net := RoadsTestRig.network_with(tiles)
	var closed := net.graph.edge_at(Vector2i(22, 10))
	var i_inc := net.congestion.compute_i_inc({closed: "accident_major"})
	var add := float(net.tun.cause_row("accident_major")["cong_add"])
	assert_almost_eq(float(i_inc[closed]), add, 1e-9, "the closed edge takes the full add")
	var hops := net.graph.edges_within_hops(closed, 3)
	var seen_one := 0
	var seen_two := 0
	for edge_id in hops:
		match int(hops[edge_id]):
			1:
				assert_almost_eq(float(i_inc.get(edge_id, 0.0)), add * 0.50, 1e-9,
						"1 hop = 0.50x")
				seen_one += 1
			2:
				assert_almost_eq(float(i_inc.get(edge_id, 0.0)), add * 0.25, 1e-9,
						"2 hops = 0.25x")
				seen_two += 1
			3:
				assert_almost_eq(float(i_inc.get(edge_id, 0.0)), 0.0, 1e-9, "3 hops = 0")
	assert_true(seen_one > 0 and seen_two > 0, "the fixture actually reaches 1 and 2 hops")


func test_dark_signal_congestion_additive() -> void:
	# G-6's second half: DARK_SIGNAL_ADD per dark signalised endpoint node.
	var tiles: Dictionary = {}
	RoadsTestRig.merge(tiles, RoadsTestRig.line(Vector2i(0, 10), Vector2i(20, 10), AVENUE))
	RoadsTestRig.merge(tiles, RoadsTestRig.line(Vector2i(10, 8), Vector2i(10, 12), AVENUE), false)
	var net := RoadsTestRig.network_with(tiles)
	var node_id := net.graph.node_at(Vector2i(10, 10))
	assert_true(bool(net.graph.node(node_id)["signalised"]), "an avenue node signalises at 3+")
	var edge_id := net.graph.edge_at(Vector2i(5, 10))
	assert_almost_eq(float(net.congestion.compute_i_inc({}).get(edge_id, 0.0)), 0.0, 1e-9)
	net.graph.node(node_id)["powered"] = false
	assert_almost_eq(float(net.congestion.compute_i_inc({}).get(edge_id, 0.0)),
			net.tun.dark_signal_add, 1e-9, "one dark endpoint adds 0.19")


func test_density_from_building_sources() -> void:
	var net := _corridor(STREET)
	var edge_id: int = net.graph.edge_ids_sorted()[0]
	net.set_density_sources([
		{"tile": Vector2i(5, 12), "pj": 120.0},   # within 6 tiles
		{"tile": Vector2i(15, 13), "pj": 90.0},   # within 6 tiles
		{"tile": Vector2i(5, 40), "pj": 5000.0},  # far away, must not count
	])
	net.refresh_density()
	assert_almost_eq(net.congestion.density_of(edge_id),
			net.tun.dens_min + net.tun.dens_k * 210.0, 1e-6,
			"pj sums only buildings within DENS_RADIUS_TILES")


# --------------------------------------------------------- §2.12 decay math

func test_condition_decay_math() -> void:
	var tun := RoadsTestRig.tunables()
	# street, c_day 0.35, clear -> 0.0090 x 1.2625 = 0.011363 /day (~88 game-days).
	var quiet := tun.base_decay(STREET) * (1.0 + tun.congestion_wear_coeff * 0.35) * 1.0
	assert_almost_eq(quiet, 0.011363, 1e-6, "quiet street")
	assert_almost_eq(1.0 / quiet, 88.0, 0.4, "1.0 -> 0 in ~88 game-days")
	# street, c_day 0.80, one snow day -> 0.0090 x 1.60 x 1.80 = 0.02592.
	var busy := tun.base_decay(STREET) * (1.0 + tun.congestion_wear_coeff * 0.80) \
			* (1.0 + float(tun.weather_row("snow")["wear"]))
	assert_almost_eq(busy, 0.02592, 1e-9, "busy street on a snow day (RR-3 scale)")
	# avenue, c_day 0.88, clear -> 0.0060 x 1.66 = 0.00996.
	var avenue := tun.base_decay(AVENUE) * (1.0 + tun.congestion_wear_coeff * 0.88)
	assert_almost_eq(avenue, 0.00996, 1e-9, "busy avenue")


func test_block_template_work_and_decay() -> void:
	# Report 98 C-60 / RR-2: the doc-10 physics constants doc 03 derives from.
	var tun := RoadsTestRig.tunables()
	var work := 60.0 * tun.build_crew_hours(AVENUE) + 27.0 * tun.build_crew_hours(STREET)
	assert_almost_eq(work, 97.5, 1e-9, "97.5 crew-hours per stamped block")
	assert_eq(roundi(work * float(tun.work_units_per_crew_hour)), 9750,
			"= 9,750 work units at doc 02's WORK_UNITS_PER_CREW_HOUR")
	var decay := 60.0 * tun.base_decay(AVENUE) + 27.0 * tun.base_decay(STREET)
	assert_almost_eq(decay, 0.6030, 1e-9, "0.6030 tile-fractions per game-day")
	# The 9-block core at the quiet-starter sample point (c_day 0.35, clear).
	var core := (540.0 * tun.base_decay(AVENUE) + 243.0 * tun.base_decay(STREET)) * 1.2625
	assert_almost_eq(core / 24.0, 0.28548, 1e-5,
			"core_damage_fraction_accrual_per_gh, the input doc 03 DERIVES its line from")
	assert_almost_eq(tun.core_damage_fraction_accrual_per_gh, 0.28548, 1e-9,
			"and the shipped constant agrees")
	assert_almost_eq(tun.block_template_crew_hours, 97.5, 1e-9)
	assert_almost_eq(tun.block_template_baseline_decay_per_game_day, 0.6030, 1e-9)


func test_settlement_inputs_feed_doc03() -> void:
	# The live replacement for CitySim's held roads constant.
	var net := RoadsTestRig.starter_network()
	var inputs := net.settlement_inputs()
	assert_eq(int((inputs["tiles"] as Dictionary)["AVENUE"]), 540)
	assert_eq(int((inputs["tiles"] as Dictionary)["STREET"]), 243)
	assert_almost_eq(float((inputs["base_decay_per_game_day"] as Dictionary)["AVENUE"]),
			0.0060, 1e-9, "the rates doc 03's e_roads_repair multiplies")
	assert_almost_eq(float((inputs["base_decay_per_game_day"] as Dictionary)["STREET"]),
			0.0090, 1e-9)
	assert_true(inputs.has("c_day") and inputs.has("wx_wear_day"))
	assert_almost_eq(float(inputs["wx_wear_day"]), 0.0, 1e-9, "clear weather, no wear")
