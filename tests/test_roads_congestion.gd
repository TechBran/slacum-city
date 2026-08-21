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


# ══════════ the dirty set, and the two sweeps that went with it (RR-43) ═════

func test_a_dirty_set_has_nothing_to_skip_because_every_edge_moves() -> void:
	# **The census, as a permanent statement of the finding.** A dirty-set
	# congestion pass may skip an edge only where the full sweep would have left
	# it unchanged. `hour` is an input to every edge on every pass through
	# `D_tod`, and the smoother never lands on its target — so an ordinary pass
	# moves EVERY edge, the skippable set is empty, and an implementation that
	# skipped anyway would be a different simulation rather than a faster one.
	# If this test ever goes green with a number below the edge count, the
	# refusal in doc 10 §9.3 C-3 is re-openable; until then it is settled.
	var net := RoadsTestRig.starter_network()
	var edges := net.graph.edge_ids_ref().size()
	assert_true(edges > 0, "the starter city has a road graph")
	for minute in 6:
		var ctx := RoadsTestRig.context(minute * GameClock.TICKS_PER_MINUTE,
				8.0 + float(minute) / 60.0)
		net.full_pass(ctx)
		assert_eq(net.congestion.last_moved, edges,
				"game-minute %d moved every edge in the graph" % minute)


func test_the_pass_carries_its_own_mean_and_it_is_the_second_sweep_s_answer() -> void:
	# `full_pass` used to walk every edge a second time to average what it had
	# just written. The sum is taken inside the loop now — same ids, same
	# ascending order, same additions — so the two must agree EXACTLY and not
	# approximately. A tolerance here would hide the only way this can be wrong.
	var net := RoadsTestRig.starter_network()
	for minute in 4:
		var ctx := RoadsTestRig.context(minute * GameClock.TICKS_PER_MINUTE,
				14.0 + float(minute) / 60.0)
		net.full_pass(ctx)
		assert_eq(net.congestion.last_pass_mean(), net.congestion.mean_congestion(),
				"the folded mean IS the sweep's answer at minute %d" % minute)
		assert_eq(net.congestion.last_pass_count, net.graph.edge_ids_ref().size(),
				"…over the whole graph")


func test_the_profile_table_prices_c_raw_exactly_as_the_single_edge_path_does() -> void:
	# The (class, district) table is the dirty set this pass CAN have: the
	# shared factor `K_base(class) · D_tod(district, hour)` is resolved once per
	# pair instead of once per edge. `c_raw()` — the single-edge entry, which
	# does not use the table — must return the identical float, because the
	# association is preserved to the term.
	var net := RoadsTestRig.network_with(RoadsTestRig.merge(
			RoadsTestRig.line(Vector2i(0, 10), Vector2i(20, 10), AVENUE),
			RoadsTestRig.line(Vector2i(10, 0), Vector2i(10, 20), STREET)))
	var ctx := RoadsTestRig.context(GameClock.TICKS_PER_MINUTE, 17.5)
	net.full_pass(ctx)
	# The batch path's own answers, collected through the daily sampler's sink.
	var inputs := net._congestion_inputs(17.5, 1.0, true)
	var sink: Dictionary = {}
	net.congestion.accumulate_c_raw(net.graph.edge_ids_ref(), inputs, sink)
	assert_false(sink.is_empty(), "the batch path priced something")
	for edge_id: int in net.graph.edge_ids_ref():
		assert_eq(float(sink[edge_id]), net.congestion.c_raw(edge_id, inputs),
				"edge %d prices the same either way" % edge_id)


func test_the_profile_table_follows_a_graph_edit() -> void:
	# The table's key is exact only because `_refresh_all_edge_state` — the one
	# writer of `district_id`, and the pass every edge build runs through —
	# invalidates it. A road laid across the corridor changes a tile's class, and
	# the congestion values must follow it rather than a stale slot.
	var net := RoadsTestRig.network_with(
			RoadsTestRig.line(Vector2i(0, 10), Vector2i(20, 10), STREET))
	var ctx := RoadsTestRig.context(GameClock.TICKS_PER_MINUTE, 17.5)
	net.full_pass(ctx)
	var before := net.congestion.mean_congestion()
	# Upgrade the whole corridor to an avenue: same tiles, same ids where the
	# graph can keep them, a different `road_class` and a different K_base.
	for x in range(0, 21):
		net.edit_tile(Vector2i(x, 10), AVENUE)
	net.step(RoadsTestRig.context(GameClock.TICKS_PER_MINUTE, 17.5))
	for minute in 30:
		net.full_pass(RoadsTestRig.context((minute + 2) * GameClock.TICKS_PER_MINUTE, 17.5))
	assert_ne(net.congestion.mean_congestion(), before,
			"an avenue carries a different K_base and the pass saw it")
	# And the single-edge path, which never reads the table, agrees with it.
	var inputs := net._congestion_inputs(17.5, 1.0, true)
	var sink: Dictionary = {}
	net.congestion.accumulate_c_raw(net.graph.edge_ids_ref(), inputs, sink)
	for edge_id: int in net.graph.edge_ids_ref():
		assert_eq(float(sink[edge_id]), net.congestion.c_raw(edge_id, inputs),
				"edge %d still prices the same either way after the edit" % edge_id)


func test_the_dark_signal_sweep_is_skipped_only_when_nothing_is_dark() -> void:
	# `dark_signal_counts_by_edge()` is an O(nodes) walk taken once a game-minute
	# by the congestion pass. It early-outs on a count `refresh_signal_power`
	# maintains for nothing — and the early-out must never hide a dark signal, so
	# the count is reset to "unknown" whenever a node's signalised verdict moves.
	var net := RoadsTestRig.network_with(RoadsTestRig.merge(
			RoadsTestRig.line(Vector2i(0, 10), Vector2i(20, 10), AVENUE),
			RoadsTestRig.line(Vector2i(10, 0), Vector2i(10, 20), AVENUE)))
	assert_eq(net.graph.dark_signals, -1, "unknown until a power refresh runs")
	assert_eq(net.graph.refresh_signal_power(func(_t: Vector2i) -> bool: return true), 0,
			"everything lit changes nothing")
	assert_eq(net.graph.dark_signals, 0, "…and the count says so")
	assert_true(net.graph.dark_signal_counts_by_edge().is_empty(),
			"so the sweep is skipped and the answer is empty")
	# Now black out the junction and the sweep has to run again.
	net.graph.refresh_signal_power(func(_t: Vector2i) -> bool: return false)
	assert_true(net.graph.dark_signals > 0, "a dark signalised node was counted")
	assert_false(net.graph.dark_signal_counts_by_edge().is_empty(),
			"and the edges around it are reported")


# ---------------------------------------------- §2.10 / §2.12 the weather input

func test_the_weather_provider_reaches_c_raw_and_the_planner() -> void:
	# `weather_state_of` was injected by nothing until this wave, so
	# `wx_cong_add` and `wx_slowdown` were 0.00 for the life of every city and
	# doc 10 §8's eleven authored weather rows were unreachable. One `step()`
	# samples doc 07 and freezes the row for the whole of that step.
	var net := _corridor(STREET)
	var edge_id: int = net.graph.edge_ids_sorted()[0]
	net.congestion.refresh_density({edge_id: 410.0})
	# A Dictionary and not a String: a GDScript lambda captures a local by VALUE,
	# so a plain `var sky` would freeze at "clear" and this test would pass on a
	# provider that was never re-read.
	var sky := {"state": "clear"}
	net.weather_state_of = func() -> String: return String(sky["state"])
	var hour := 17.0 + 40.0 / 60.0

	net.step(RoadsTestRig.context(4, hour))
	assert_eq(net.weather_state, "clear")
	assert_almost_eq(net.planner.wx_slowdown, 0.00, 1e-12, "clear costs nothing")
	var dry := net.congestion.c_raw(edge_id, net._congestion_inputs(hour, 1.0, true))
	assert_almost_eq(dry, 0.941, 1e-3, "worked example D's 17:40 row, clear")

	sky["state"] = "heavy_rain"
	net.step(RoadsTestRig.context(8, hour))
	assert_eq(net.weather_state, "heavy_rain", "the step re-sampled doc 07")
	assert_almost_eq(net.planner.wx_slowdown, 0.18, 1e-12,
			"§2.7 F_weather sees heavy_rain's 0.18 slowdown")
	var wet := net.congestion.c_raw(edge_id, net._congestion_inputs(hour, 1.0, true))
	assert_almost_eq(wet - dry, 0.19, 1e-9,
			"c_raw gains EXACTLY heavy_rain's authored wx_cong_add, additively")
	assert_almost_eq(wet, 1.131, 1e-3, "0.9414 + 0.19 — one dark signal short of §2.10's 1.321")

	# The additive is snapped to the STATE row, never interpolated on precip
	# (report 98 C-59): the quantised snapshot route_minutes' mode-invariance
	# depends on has no room for a continuous input.
	sky["state"] = "thunderstorm"
	net.step(RoadsTestRig.context(12, hour))
	var storm := net.congestion.c_raw(edge_id, net._congestion_inputs(hour, 1.0, true))
	assert_almost_eq(storm - dry, 0.24, 1e-9, "thunderstorm's row, exactly")
	assert_true(storm > wet, "a storm is worse than heavy rain")


func test_wet_roads_wear_faster_through_the_provider() -> void:
	# §2.12: decay = base_decay · (1 + 0.75·c_day) · (1 + wx_wear_day), where
	# wx_wear_day is the MAX wear observed over the game-day's 24 hourly samples.
	# Nothing set `weather_state` before this wave, so the term was always 1.00.
	var dry := _corridor(STREET)
	var wet := _corridor(STREET)
	var snowy_hour := 9
	wet.weather_state_of = func() -> String:
		return "snow" if wet.sim_minute / 60 % 24 == snowy_hour else "clear"
	for net in [dry, wet]:
		net.set_density_sources([{"tile": Vector2i(10, 10), "pj": 410.0}])
		net.refresh_density()
		for hour in range(0, 25):
			var ctx := RoadsTestRig.context(hour * GameClock.TICKS_PER_HOUR,
					float(hour % 24) + 0.5, TimeContext.Mode.COARSE)
			net.step(ctx)
			net.full_pass(ctx)
			if hour % 24 == 0:
				net.on_day(ctx)
	assert_almost_eq(dry.wx_wear_day(), 0.0, 1e-12, "a clear day wears at the base rate")
	# The day that just closed saw one snow hour; the accumulator for the NEW day
	# has been reset, so the wear that priced the decay is read off the decay.
	var tile := Vector2i(10, 10)
	var dry_loss := 1.0 - dry.condition_of(tile)
	var wet_loss := 1.0 - wet.condition_of(tile)
	assert_true(wet_loss > dry_loss,
			"one snow hour wore the road harder (%.6f vs %.6f)" % [wet_loss, dry_loss])
	# snow's wear is 0.80, so the day's decay is (1 + 0.80) = 1.8x the clear one —
	# to the precision the two runs' c_day can share (identical: wx_cong_add is 0
	# for snow's 8 hours only through the additive, which DOES move c_day, so the
	# ratio is bounded rather than exact).
	assert_true(wet_loss / dry_loss > 1.5 and wet_loss / dry_loss < 2.2,
			"and by about the authored 1 + 0.80 (ratio %.4f)" % (wet_loss / dry_loss))
