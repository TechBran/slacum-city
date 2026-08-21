extends SimTest
## The integration surface: the doc 01 scheduler adapters, the phase ordering
## the blackout cascade depends on, and the measured performance budget (doc 10
## §2.14 / §7 test 25 / §9.3 C-3).

const AVENUE := RoadTunables.CLASS_AVENUE
const STREET := RoadTunables.CLASS_STREET


func _scheduler() -> Dictionary:
	var clock := GameClock.new()
	var curves := DayCurveSet.new()
	curves.load_from(StarterCityLoader.read_json("res://data/time.json"))
	var modifiers := ModifierStack.new()
	var scheduler := TickScheduler.new(clock, curves, modifiers)
	return {"clock": clock, "scheduler": scheduler}


# ------------------------------------------------------------ scheduler wiring

func test_phase_systems_register_at_p08() -> void:
	var rig := _scheduler()
	var net := RoadsTestRig.starter_network()
	var events: Array = []
	var systems := RoadsPhaseSystems.register_all(rig["scheduler"], net,
			func(type: StringName, payload: Dictionary) -> void:
				events.append({"type": type, "payload": payload}))
	assert_eq(systems.size(), 3, "step / congestion / daily")
	assert_eq(int(rig["scheduler"].system_count()), 3)
	for system in systems:
		assert_eq(int(system.phase()), SimSystem.Phase.ROADS,
				"every roads system sits in P08, between WATER and VEHICLES")
	assert_eq(int(systems[0].cadence()), SimSystem.Cadence.EVERY_TICK)
	# `roads_congestion` declares EVERY_TICK and picks its pass from
	# `tick_index % 4` (doc 91 D-15 proposal 2, Wave 9): the minute's three
	# passes are spread across the four ticks of the minute so no single frame
	# carries all of them. It cannot be three EVERY_MINUTE systems at offsets
	# 0/1/2, because a COARSE step's tick_index is hour-aligned and an offset
	# system would never fire offline — see the class comment.
	assert_eq(int(systems[1].cadence()), SimSystem.Cadence.EVERY_TICK)
	assert_eq(int(systems[2].cadence()), SimSystem.Cadence.EVERY_DAY)
	# Ids sort into the order the cadences must run in.
	var ids := [String(systems[0].system_id()), String(systems[1].system_id()),
			String(systems[2].system_id())]
	var sorted_ids := ids.duplicate()
	sorted_ids.sort()
	assert_eq(str(ids), str(sorted_ids),
			"edits+power, then the congestion pass, then the daily decay that consumes it")


func test_scheduler_drives_a_game_day() -> void:
	var rig := _scheduler()
	var net := RoadsTestRig.starter_network()
	var scheduler: TickScheduler = rig["scheduler"]
	var seen: Dictionary = {}
	RoadsPhaseSystems.register_all(scheduler, net,
			func(type: StringName, _payload: Dictionary) -> void:
				seen[type] = int(seen.get(type, 0)) + 1)
	net.set_density_sources([{"tile": Vector2i(40, 40), "pj": 300.0}])
	scheduler.advance_fine_n(GameClock.TICKS_PER_HOUR * 2)
	assert_true(int(seen.get(&"congestion_updated", 0)) >= 120,
			"the minute cadence fired every game-minute (%d)"
			% int(seen.get(&"congestion_updated", 0)))
	assert_true(net.congestion.mean_congestion() > 0.0, "traffic built up over the two hours")
	assert_true(net.snapshot.visible_edges.size() > 0, "the renderer snapshot is live")


func test_offline_catchup_runs_the_same_code() -> void:
	# Constitution §4: offline catch-up uses the SAME system code via a coarse
	# advance path, never a parallel implementation.
	var rig := _scheduler()
	var net := RoadsTestRig.starter_network()
	RoadsPhaseSystems.register_all(rig["scheduler"], net)
	# 25 hourly steps, so the EVERY_DAY cadence fires a second time (it fires on
	# the step STARTING at tick 0 and at tick 5760).
	rig["scheduler"].advance_coarse_n(25, true, 0, 25)
	assert_eq(int(rig["clock"].tick_index), 25 * GameClock.TICKS_PER_HOUR)
	assert_true(net.congestion.mean_congestion() > 0.0)
	assert_eq(net.feed.vehicle_count(), 0, "and runs no cosmetic traffic offline")
	var quiet := net.condition_of(Vector2i(40, 32))
	assert_true(quiet < 1.0 and quiet > 0.9, "a game-day of decay landed (%f)" % quiet)


func test_blackout_cascade_end_to_end() -> void:
	# The signature cascade, from doc 04's power state to doc 06's arrival time:
	# power out -> dark signals -> +delay AND +congestion -> slower response.
	var rig := _scheduler()
	var net := RoadsTestRig.starter_network()
	RoadsPhaseSystems.register_all(rig["scheduler"], net)
	var blackout: Dictionary = {}
	net.power_is_tile_powered = func(t: Vector2i) -> bool: return not blackout.has(t)
	rig["scheduler"].advance_fine_n(GameClock.TICKS_PER_HOUR)
	var engine := RouteProfile.emergency(26.0 * 1.25, 0)
	var station := Vector2i(35, 35)
	var fire := Vector2i(76, 76)
	var lit := net.route_minutes(station, fire, engine)
	# Black out every signalised intersection in the eastern half of the core.
	for row in net.signalised_intersections(""):
		var tile: Vector2i = row["tile"]
		if tile.x >= 55:
			blackout[tile] = true
	rig["scheduler"].advance_fine_n(4)
	var dark := net.route_minutes(station, fire, engine)
	assert_true(dark > lit, "a district blackout slows the fire response (%f -> %f gm)"
			% [lit, dark])
	assert_true(net.dark_fraction("") > 0.3, "and doc 06 can see the dark fraction")
	# It recovers when the lights come back.
	blackout.clear()
	rig["scheduler"].advance_fine_n(GameClock.TICKS_PER_HOUR)
	assert_almost_eq(net.route_minutes(station, fire, engine), lit, 0.05,
			"and recovers on relight")


# ------------------------------------------------------- measured perf budget

func test_perf_budget_reference_map() -> void:
	# Doc 10 §7 test 25 and §9.3 C-3. This test MEASURES and records; it does not
	# fail the build on a debug headless run, because the doc's 4 ms budget is
	# specified for an exported release build on the reference device and
	# GDScript in a debug editor build runs several times slower. The remedy
	# ladder (§9.3 C-3) is: lower max_expansions_per_tick, then hierarchical
	# routing, then GDExtension. See the roads REPORT for the numbers.
	var tiles: Dictionary = {}
	for i in range(0, 112, 4):
		RoadsTestRig.merge(tiles, RoadsTestRig.line(Vector2i(0, i), Vector2i(111, i),
				AVENUE if i % 16 == 0 else STREET))
		RoadsTestRig.merge(tiles, RoadsTestRig.line(Vector2i(i, 0), Vector2i(i, 111),
				AVENUE if i % 16 == 0 else STREET), false)
	var tun := RoadsTestRig.tunables()
	var grid := RoadsTestRig.grid_with(tiles)
	var graph := RoadGraph.new(grid, tun)
	var build_start := Time.get_ticks_usec()
	graph.rebuild_all()
	var build_us := Time.get_ticks_usec() - build_start
	var road_tiles := graph.road_tile_count()
	assert_true(road_tiles > 5000, "a real reference map (%d road tiles)" % road_tiles)
	print("      [roads perf] %d tiles / %d nodes / %d edges: full build %.1f ms"
			% [road_tiles, graph.node_count(), graph.edge_count(), build_us / 1000.0])

	var congestion := CongestionModel.new(graph, tun)
	var planner := RoutePlanner.new(graph, tun, congestion)
	var prof := RouteProfile.emergency(32.0, 0)
	var route_start := Time.get_ticks_usec()
	var expansions := 0
	for i in 6:
		var result := planner.find_path(Vector2i(2, 2 + i * 4), Vector2i(108, 108 - i * 4),
				prof, {"epsilon": 1.0})
		expansions += int(result["expansions"])
		assert_true(bool(result["ok"]), "cross-city route %d resolves" % i)
	var route_us := Time.get_ticks_usec() - route_start
	var median := float(expansions) / 6.0
	print("      [roads perf] 6 cross-city P0 routes (eps=1.00): %d expansions, %.2f ms"
			% [expansions, route_us / 1000.0])
	# The same six at the routine weighting doc 10 reserves for priority >= 2.
	planner.invalidate_all()
	var routine := RouteProfile.utility(32.0, 3)
	var relaxed_start := Time.get_ticks_usec()
	var relaxed_expansions := 0
	for i in 6:
		var result := planner.find_path(Vector2i(2, 2 + i * 4), Vector2i(108, 108 - i * 4),
				routine, {"epsilon": tun.epsilon_routine})
		relaxed_expansions += int(result["expansions"])
	print("      [roads perf] the same six at eps=1.25: %d expansions, %.2f ms"
			% [relaxed_expansions, (Time.get_ticks_usec() - relaxed_start) / 1000.0])
	assert_true(relaxed_expansions < expansions,
			"the routine weighting really does buy fewer expansions")
	# Doc 10 §2.14's hierarchical-routing TRIGGER, evaluated rather than assumed:
	# "median expansions per emergency route > 800 OR road tiles > 8,000".
	var triggered := median > float(tun.hierarchical_trigger_median_expansions)
	print("      [roads perf] median P0 expansions %.0f vs trigger %d -> hierarchical routing %s"
			% [median, tun.hierarchical_trigger_median_expansions,
			"REQUIRED" if triggered else "not yet required"])
	assert_true(median > 0.0, "the trigger is measured, not assumed (see REPORT)")

	# An incremental edit is the per-tick cost that actually recurs.
	grid.set_road(50, 50, RoadTunables.CLASS_NONE)
	var edit_start := Time.get_ticks_usec()
	graph.apply_edits([Vector2i(50, 50)])
	var edit_us := Time.get_ticks_usec() - edit_start
	print("      [roads perf] single-tile incremental rebuild: %.3f ms" % (edit_us / 1000.0))
	assert_true(edit_us < 50000, "an incremental edit is not a frame hitch")

	# The full congestion pass, the one thing that runs across ALL edges.
	var pass_start := Time.get_ticks_usec()
	congestion.recompute(graph.edge_ids_sorted(), {"hour": 17.6, "weights": {},
			"wx_cong_add": 0.0, "dt_game_minutes": 1.0})
	var pass_us := Time.get_ticks_usec() - pass_start
	print("      [roads perf] full congestion pass over %d edges: %.2f ms"
			% [graph.edge_count(), pass_us / 1000.0])
	assert_true(pass_us < 200000, "the EVERY_MINUTE pass stays off the hot path")


func test_cached_quote_is_cheap() -> void:
	# §4 guarantee 5: a cached route_minutes is a re-price of the stored edge
	# list, not a search. That is what makes doc 06's dispatch pattern affordable.
	var net := RoadsTestRig.starter_network()
	var prof := RouteProfile.emergency(32.0, 0)
	var a := Vector2i(35, 35)
	var b := Vector2i(76, 76)
	net.route_minutes(a, b, prof)
	var start := Time.get_ticks_usec()
	for i in 100:
		net.congestion.epoch += 1  # force a re-price every time
		net.route_minutes(a, b, prof)
	var per_call := float(Time.get_ticks_usec() - start) / 100.0
	print("      [roads perf] cached re-priced quote: %.1f us" % per_call)
	assert_eq(int(net.planner.expansions_last_call), 0, "no expansions on a cache hit")
	assert_eq(int(net.planner.cache_reprices), 100, "every call re-priced the stored path")
	assert_true(per_call < 2000.0, "a re-price is orders of magnitude cheaper than a search")


# --------------------------------------- the two seams, and their mode invariance

func test_the_weather_seam_is_mode_invariant_while_the_sky_holds() -> void:
	# Doc 93's per-system rule: mode-invariance is claimed per system, and this
	# is the roads-vs-doc-07 claim. Roads samples the CITY-WIDE state once per
	# `step()` and freezes it, so while a doc 07 segment spans the window the
	# fine path (240 samples per game-hour) and the coarse path (one) read the
	# same row and must agree exactly — congestion, condition and wx_wear_day.
	var sky := "heavy_rain"
	var fine := RoadsTestRig.starter_network()
	var coarse := RoadsTestRig.starter_network()
	for net in [fine, coarse]:
		net.weather_state_of = func() -> String: return sky
		net.set_density_sources([{"tile": Vector2i(40, 40), "pj": 300.0}])
		net.refresh_density()
	# One tick / one hour PAST the day boundary in each mode, so the EVERY_DAY
	# cadence fires its second time and the day's decay is actually applied.
	var fine_rig := _scheduler()
	RoadsPhaseSystems.register_all(fine_rig["scheduler"], fine)
	fine_rig["scheduler"].advance_fine_n(GameClock.TICKS_PER_DAY + 1)
	var coarse_rig := _scheduler()
	RoadsPhaseSystems.register_all(coarse_rig["scheduler"], coarse)
	coarse_rig["scheduler"].advance_coarse_n(25, true, 0, 25)

	assert_eq(fine.weather_state, "heavy_rain", "the sky reached the fine path")
	assert_eq(coarse.weather_state, "heavy_rain", "…and the offline one")
	# `wx_wear_day` is read at the top of each game-hour in BOTH modes (doc 07
	# derives `now_min` from `tick_index`, so the two paths sample the same
	# game-minutes), which is what makes the wear term bit-identical rather than
	# merely close.
	assert_eq(fine.wx_wear_day(), coarse.wx_wear_day(),
			"the day's max wear is the same float in both modes")
	var checked := 0
	for t in coarse.graph.road_tiles_sorted():
		assert_almost_eq(fine.condition_of(t), coarse.condition_of(t), 1e-9,
				"wet-weather wear at %s agrees between modes" % str(t))
		checked += 1
	assert_true(checked > 500, "a real city's worth of tiles (%d)" % checked)
	assert_true(fine.condition_of(Vector2i(40, 32)) < 1.0, "and the wear happened")


func test_rain_slows_traffic_and_the_dry_road_is_the_control() -> void:
	# The consequence in one assertion: doc 10 §8's `wx_cong_add` and `slowdown`
	# rows were unreachable until this wave, so rain had never slowed a shipped
	# city's traffic. Two arms of the same city, same seed, same hour, same
	# density — the ONLY difference is doc 07's state.
	var arms: Dictionary = {}
	for sky in ["clear", "heavy_rain"]:
		var net := RoadsTestRig.starter_network()
		net.weather_state_of = func() -> String: return sky
		net.set_density_sources([{"tile": Vector2i(40, 40), "pj": 300.0}])
		net.refresh_density()
		var rig := _scheduler()
		RoadsPhaseSystems.register_all(rig["scheduler"], net)
		rig["scheduler"].advance_fine_n(GameClock.TICKS_PER_HOUR)
		arms[sky] = net
	var dry: RoadNetwork = arms["clear"]
	var wet: RoadNetwork = arms["heavy_rain"]
	var prof := RouteProfile.civilian()
	var a := Vector2i(35, 35)
	var b := Vector2i(76, 76)
	var dry_c := dry.mean_congestion()
	var wet_c := wet.mean_congestion()
	var dry_minutes := dry.route_minutes(a, b, prof)
	var wet_minutes := wet.route_minutes(a, b, prof)
	assert_almost_eq(wet_c - dry_c, 0.19, 0.005,
			"mean congestion rose by heavy_rain's authored +0.19 (%.4f -> %.4f)"
			% [dry_c, wet_c])
	assert_true(wet_minutes > dry_minutes,
			"and the same civilian trip takes longer in the rain (%.3f -> %.3f gm)"
			% [dry_minutes, wet_minutes])
	print("      [weather] mean c %.4f -> %.4f, cross-city civilian trip %.3f -> %.3f gm"
			% [dry_c, wet_c, dry_minutes, wet_minutes])
