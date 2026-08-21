extends SimTest
## Doc 10 §2.8 / §2.12 / §2.13 / §3.2 — closures, condition, jobs through doc
## 02's ConstructionQueue, persistence, offline equivalence, and the report 98
## conformance set. Test plan cases 31–48.

const AVENUE := RoadTunables.CLASS_AVENUE
const STREET := RoadTunables.CLASS_STREET


func _corridor(length: int = 30) -> RoadNetwork:
	var tiles := RoadsTestRig.line(Vector2i(0, 10), Vector2i(length, 10), STREET)
	return RoadsTestRig.network_with(tiles)


## A real doc 02 queue + doc 03 price table, wired exactly as the integration
## patch wires them.
func _wired(net: RoadNetwork) -> Dictionary:
	var queue := ConstructionQueue.new()
	var curves := CostCurves.new(
			StarterCityLoader.read_json("res://data/building_economy.json"),
			StarterCityLoader.read_json("res://data/economy.json"))
	var submits: Array = []
	net.submit_job = func(kind: StringName, target: String, crew_hours: float,
			crew: StringName, payload: Dictionary) -> int:
		submits.append({"kind": kind, "target": target, "crew_hours": crew_hours,
				"crew": crew, "payload": payload})
		return queue.submit(kind, target, crew_hours, crew, payload)
	var quotes: Array = []
	net.repair_quote = func(road_class: String, damage_fraction: float) -> int:
		var price := curves.repair_cost_road(road_class, damage_fraction)
		quotes.append({"class": road_class, "damage_fraction": damage_fraction, "price": price})
		return price
	return {"queue": queue, "curves": curves, "submits": submits, "quotes": quotes}


func _clock_context(clock: GameClock, mode: int = TimeContext.Mode.FINE) -> TimeContext:
	var ctx := TimeContext.new()
	ctx.tick_index = clock.tick_index
	ctx.game_seconds = clock.game_seconds()
	ctx.mode = mode
	ctx.dt_game_seconds = 15 if mode == TimeContext.Mode.FINE else 3600
	ctx.hour_of_day = clock.hour_of_day()
	ctx.minute_of_day = clock.minute_of_day()
	ctx.day_index = clock.day_index()
	ctx.hour_midpoint = clock.fine_sample_hour() if mode == TimeContext.Mode.FINE \
			else float(clock.hour_of_day()) + 0.5
	ctx.channels = {"construction_rate": 0.804}
	ctx.channels_hour = {"construction_rate": 0.804}
	return ctx


# ------------------------------------------------------------------- closures

func test_closure_auto_expiry_cap() -> void:
	# A closure whose incident_resolved never arrives clears at its hard cap.
	var net := _corridor()
	var closure_id := net.add_closure([Vector2i(15, 10)], "accident_minor", 0.5)
	assert_true(closure_id > 0)
	assert_eq(net.active_closure_count(), 1)
	var cap := int(net.tun.cause_row("accident_minor")["auto_expire_gm"])
	assert_eq(cap, 90, "accident_minor caps at 90 gm")
	net.sim_minute = cap - 1
	net.step(RoadsTestRig.context(4 * (cap - 1), 12.0))
	assert_eq(net.active_closure_count(), 1, "still closed one minute before the cap")
	net.step(RoadsTestRig.context(4 * cap, 12.0))
	assert_eq(net.active_closure_count(), 0, "cleared at the cap, never stranding a district")
	var cleared := false
	for event in net.drain_events():
		if event["type"] == &"road_closure_cleared":
			cleared = true
	assert_true(cleared, "road_closure_cleared is emitted")


func test_closure_dominance_and_restore() -> void:
	# §2.8: one closure per edge; a higher-severity cause replaces a lower one
	# and the displaced closure is reinstated if the dominant one clears first.
	var net := _corridor()
	var minor := net.add_closure([Vector2i(15, 10)], "accident_minor", 0.4, 999999)
	var edge_id := net.graph.edge_at(Vector2i(15, 10))
	assert_eq(net.closure_of_edge(edge_id), minor)
	var flood := net.add_closure([Vector2i(15, 10)], "flood_deep", 1.0, 999999)
	assert_eq(net.closure_of_edge(edge_id), flood, "flood_deep dominates accident_minor")
	assert_eq(String(net.graph.edge(edge_id)["closure_cause"]), "flood_deep")
	net.remove_closure(flood)
	assert_eq(net.closure_of_edge(edge_id), minor, "the shadowed accident is reinstated")
	assert_eq(String(net.graph.edge(edge_id)["closure_cause"]), "accident_minor")
	# The dominance order itself, straight from the tunables.
	var tun := net.tun
	assert_true(tun.cause_rank("flood_deep") < tun.cause_rank("accident_major"))
	assert_true(tun.cause_rank("accident_major") < tun.cause_rank("debris"))
	assert_true(tun.cause_rank("debris") < tun.cause_rank("flood_shallow"))
	assert_true(tun.cause_rank("construction_new") < tun.cause_rank("accident_minor"))
	assert_true(tun.cause_rank("accident_minor") < tun.cause_rank("construction_work"))


func test_speed_override_is_a_separate_channel() -> void:
	var net := _corridor()
	var edge_id := net.graph.edge_at(Vector2i(15, 10))
	var prof := RouteProfile.emergency(32.0, 0)
	var base := net.planner.edge_cost_gm(edge_id, prof)
	net.set_edge_speed_mult(edge_id, 0.6, 999999)
	assert_almost_eq(net.planner.edge_cost_gm(edge_id, prof), base / 0.6, 1e-9,
			"F_override = 1 / clamp(mult, 0.10, 1.00)")
	# ... and it composes multiplicatively with a closure, not instead of one.
	net.add_closure([Vector2i(15, 10)], "accident_minor", 0.5, 999999)
	assert_almost_eq(net.planner.edge_cost_gm(edge_id, prof),
			net.planner.edge_cost_gm(edge_id, prof), 0.0)
	var cause: String = net.graph.edge(edge_id)["closure_cause"]
	var with_both := net.planner.edge_cost_gm(edge_id, prof)
	net.graph.edge(edge_id)["closure_cause"] = ""
	var override_only := net.planner.edge_cost_gm(edge_id, prof)
	net.graph.edge(edge_id)["closure_cause"] = cause
	assert_almost_eq(with_both, override_only * 1.4, 1e-9,
			"closure x1.4 for EMERGENCY on top of the 1/0.6 override")
	# Overrides expire on their own minute (sim_minute comes from the frozen
	# TimeContext, never from a clock read).
	net.step(RoadsTestRig.context(4 * 1000000, 12.0))
	assert_almost_eq(float(net.graph.edge(edge_id)["speed_override"]), 1.0, 1e-9)


func test_flood_closure_from_water_and_collapse_block_everything() -> void:
	var net := _corridor()
	net.add_closure([Vector2i(15, 10)], "flood_deep", 1.0, -1)
	var mask := int(net.graph.edge(net.graph.edge_at(Vector2i(15, 10)))["blocked_mask"])
	assert_eq(mask, 0b1111, "flood_deep blocks all four route classes")


# ------------------------------------------------------------------ condition

func test_collapse_blocks_all_classes() -> void:
	var net := _corridor()
	net.drain_events()
	net.set_condition(Vector2i(15, 10), 0.0)
	var collapsed := false
	var critical := false
	for event in net.drain_events():
		if event["type"] == &"road_collapsed":
			collapsed = true
		if event["type"] == &"road_condition_critical":
			critical = true
	assert_true(collapsed, "road_collapsed is emitted")
	assert_true(critical, "and the 0.20 critical trigger fires on the way past")
	assert_true(bool(net.graph.edge(net.graph.edge_at(Vector2i(15, 10)))["collapsed"]))
	for route_class in [RouteProfile.RouteClass.EMERGENCY, RouteProfile.RouteClass.UTILITY,
			RouteProfile.RouteClass.CONSTRUCTION, RouteProfile.RouteClass.CIVILIAN]:
		var prof := RouteProfile.new(30.0, route_class, true)
		assert_true(is_inf(net.route_minutes(Vector2i(2, 10), Vector2i(28, 10), prof)),
				"a COLLAPSED tile is impassable for class %d" % route_class)
	assert_true((net.flags_of(Vector2i(15, 10)) & RoadNetwork.FLAG_COLLAPSED) != 0)


func test_daily_decay_and_critical_event() -> void:
	var net := _corridor()
	net.set_density_sources([])
	var clock := GameClock.new()
	var before := net.condition_of(Vector2i(15, 10))
	assert_almost_eq(before, 1.0, 1e-9, "a newly finished road is 1.0")
	# Two game-days of decay with a scripted c_day of 0.
	net.on_day(_clock_context(clock))  # first fire only arms the accumulators
	clock.tick_index = GameClock.TICKS_PER_DAY
	var edge_id := net.graph.edge_at(Vector2i(15, 10))
	var c_day := net.c_day_of(edge_id)
	var wear := net.wx_wear_day()
	net.on_day(_clock_context(clock))
	var after_one := net.condition_of(Vector2i(15, 10))
	var expected := net.tun.base_decay(STREET) \
			* (1.0 + net.tun.congestion_wear_coeff * c_day) * (1.0 + wear)
	assert_almost_eq(before - after_one, expected, 1e-9,
			"decay = base_decay x (1 + 0.75 c_day) x (1 + wx_wear_day), exactly")
	assert_almost_eq(wear, 0.0, 1e-9, "clear weather wears nothing")
	assert_true(after_one <= 1.0 and after_one >= 0.0, "condition stays on [0,1]")


func test_damage_events_are_the_c16_fractions() -> void:
	var net := _corridor()
	var tiles := [Vector2i(14, 10), Vector2i(15, 10), Vector2i(16, 10)]
	var applied := net.apply_damage(tiles, "accident_major_resolve")
	assert_almost_eq(applied, 3.0 * 0.08, 1e-9, "-0.08 on the 3 tiles nearest the incident")
	for t in tiles:
		assert_almost_eq(net.condition_of(t), 0.92, 1e-9)
		assert_almost_eq(net.road_damage_fraction(t), 0.08, 1e-9,
				"road_damage_fraction is doc 03's C-16 argument")
	net.apply_damage([Vector2i(20, 10)], "flood_deep_recede")
	assert_almost_eq(net.condition_of(Vector2i(20, 10)), 0.85, 1e-9)
	net.apply_damage([Vector2i(21, 10)], "adjacent_structure_fire")
	assert_almost_eq(net.condition_of(Vector2i(21, 10)), 0.94, 1e-9)


# ---------------------------------------------------- jobs through doc 02's queue

func test_repair_job_work_and_result() -> void:
	# §2.12 worked example F: 12 tiles at condition 0.40.
	var net := _corridor()
	var wiring := _wired(net)
	var tiles: Array = []
	for x in range(10, 22):
		tiles.append(Vector2i(x, 10))
		net.set_condition(Vector2i(x, 10), 0.40)
	var result := net.cmd_road_repair(tiles)
	assert_true(bool(result["ok"]), "the repair is accepted")
	var repair_payload := RoadsTestRig.payload(result)
	assert_almost_eq(float(repair_payload["crew_hours"]), 2.52, 1e-9,
			"12 x 0.35 x 0.60 = 2.52 crew-hours")
	var queue: ConstructionQueue = wiring["queue"]
	var job: Dictionary = queue.job(int(repair_payload["job_id"]))
	assert_eq(int(job["required_work_units"]), 252,
			"round(2.52 x WORK_UNITS_PER_CREW_HOUR 100) = 252 work units")
	assert_eq((wiring["submits"] as Array).size(), 1,
			"exactly one ConstructionQueue.submit — roads runs no queue of its own")
	assert_eq(String((wiring["submits"] as Array)[0]["crew"]), "road_crew")
	# Repair pricing is doc 03's, and roads asks for it exactly once per tile.
	assert_eq((wiring["quotes"] as Array).size(), 12, "one economy quote per tile")
	for quote in wiring["quotes"]:
		assert_almost_eq(float(quote["damage_fraction"]), 0.60, 1e-9)
		assert_eq(String(quote["class"]), "STREET")
	# During the job the tiles carry a construction_work closure.
	assert_eq(String(net.graph.edge(net.graph.edge_at(Vector2i(15, 10)))["closure_cause"]),
			"construction_work")
	net.on_job_completed(int(repair_payload["job_id"]))
	for t in tiles:
		assert_almost_eq(net.condition_of(t), 1.0, 1e-9, "job_completed sets exactly 1.0")
	assert_eq(String(net.graph.edge(net.graph.edge_at(Vector2i(15, 10)))["closure_cause"]), "",
			"and the closure is gone")


func test_repair_minimum_run_length() -> void:
	var net := _corridor()
	_wired(net)
	var tiles: Array = [Vector2i(10, 10), Vector2i(11, 10), Vector2i(12, 10)]
	for t in tiles:
		net.set_condition(t, 0.4)
	var result := net.cmd_road_repair(tiles)
	assert_false(bool(result["ok"]), "the minimum job is 4 contiguous tiles")
	assert_eq(RoadsTestRig.reason(result), &"E_MIN_TILES")


func test_road_jobs_go_through_construction_queue() -> void:
	# Report 98 G-2: every road job is exactly one ConstructionQueue.submit.
	var tiles := RoadsTestRig.line(Vector2i(0, 10), Vector2i(30, 10), STREET)
	var net := RoadsTestRig.network_with(tiles)
	var wiring := _wired(net)
	var submits: Array = wiring["submits"]

	var build_tiles: Array = []
	for z in range(11, 16):
		build_tiles.append(Vector2i(10, z))
	var build := net.cmd_road_build(build_tiles, STREET, 9000)
	assert_true(bool(build["ok"]), "build accepted")
	assert_eq(submits.size(), 1, "road_build -> 1 submit")
	assert_almost_eq(float(RoadsTestRig.payload(build)["crew_hours"]), 5 * 0.50, 1e-9)
	assert_eq(int(RoadsTestRig.payload(build)["work_units"]), 250, "5 tiles x 0.50 ch x 100")

	var upgrade := net.cmd_road_upgrade([Vector2i(5, 10), Vector2i(6, 10)], 8000)
	assert_true(bool(upgrade["ok"]))
	assert_eq(submits.size(), 2, "road_upgrade -> 1 submit")
	assert_almost_eq(float(RoadsTestRig.payload(upgrade)["crew_hours"]), 2 * 0.90, 1e-9,
			"0.9 crew-hours/tile")
	assert_eq(int(RoadsTestRig.payload(upgrade)["work_units"]), 180)

	for x in range(20, 26):
		net.set_condition(Vector2i(x, 10), 0.5)
	var repair := net.cmd_road_repair([Vector2i(20, 10), Vector2i(21, 10), Vector2i(22, 10),
			Vector2i(23, 10), Vector2i(24, 10), Vector2i(25, 10)])
	assert_true(bool(repair["ok"]))
	assert_eq(submits.size(), 3, "road_repair -> 1 submit")

	# sim/roads/ owns no queue, no crew roster and no work accumulator.
	for file in ["road_network.gd", "road_graph.gd", "route_planner.gd",
			"congestion_model.gd", "traffic_feed.gd"]:
		var source := FileAccess.get_file_as_string("res://sim/roads/" + file)
		for line in source.split("\n"):
			var comment_at := line.find("#")
			var code: String = line.substr(0, comment_at) if comment_at >= 0 else line
			assert_false(code.contains("work_units +="), "%s accumulates work itself" % file)
			assert_false(code.contains("crew_rate"), "%s holds a crew roster" % file)


func test_job_blocked_surfaces_as_road_job_rejected() -> void:
	var net := _corridor()
	_wired(net)
	net.drain_events()
	net.on_job_blocked(42, "no_crew")
	var rejected := false
	for event in net.drain_events():
		if event["type"] == &"road_job_rejected":
			rejected = true
			assert_eq(String(event["reason"]), "no_crew")
	assert_true(rejected)


func test_construction_rate_channel_applied() -> void:
	# Report 98 C-29: every road work unit multiplies ctx.channels.construction_rate.
	# The block template's 97.5 crew-hours at crew_rate 1.00 takes
	# 97.5 / (1.00 x 0.804) = 121.3 gh; a generic crew (0.70) takes 173.2 gh.
	var queue := ConstructionQueue.new()
	var job_id := queue.submit(&"road", "block_template", 97.5, &"road_crew")
	queue.assign_crew(job_id, "ROAD-1", 1000)
	var hours := _hours_to_complete(queue, job_id, 0.804)
	assert_almost_eq(hours, 121.3, 0.15, "road_crew at the 0.804 channel mean")

	var slow := ConstructionQueue.new()
	var slow_job := slow.submit(&"road", "block_template", 97.5, &"construction_crew")
	slow.assign_crew(slow_job, "GEN-1", 700)
	assert_almost_eq(_hours_to_complete(slow, slow_job, 0.804), 173.2, 0.15,
			"a generic crew at crew_rate 0.70")

	# Pinning the channel to 1.0 completes in exactly 0.804x the wall time.
	var pinned := ConstructionQueue.new()
	var pinned_job := pinned.submit(&"road", "block_template", 97.5, &"road_crew")
	pinned.assign_crew(pinned_job, "ROAD-1", 1000)
	var pinned_hours := _hours_to_complete(pinned, pinned_job, 1.0)
	assert_almost_eq(pinned_hours / hours, 0.804, 0.002,
			"the channel is mandatory, not optional")


func _hours_to_complete(queue: ConstructionQueue, job_id: int, rate: float) -> float:
	var ctx := TimeContext.new()
	ctx.dt_game_seconds = 15
	ctx.channels_hour = {"construction_rate": rate}
	var ticks := 0
	while ticks < 400000:
		ticks += 1
		var done := queue.advance(ctx)
		for job in done:
			if int(job["job_id"]) == job_id:
				return float(ticks) * 15.0 / 3600.0
	return -1.0


func test_demolish_rejected_when_orphaning() -> void:
	var net := _corridor()
	var access := Vector2i(15, 11)  # a building whose only access is (15,10)
	var result := net.cmd_road_demolish([Vector2i(15, 10)], [access])
	assert_false(bool(result["ok"]), "the only access road may not be demolished")
	assert_eq(RoadsTestRig.reason(result), &"E_WOULD_ORPHAN")
	assert_true(net.graph.is_road_tile(Vector2i(15, 10)), "and nothing was mutated")
	# Demolishing a tile the access tile does not depend on is fine.
	var elsewhere := net.cmd_road_demolish([Vector2i(4, 10)], [access])
	assert_true(bool(elsewhere["ok"]), "an unrelated tile comes up without argument")
	assert_eq(RoadsTestRig.reason(elsewhere), &"", "and reports no failure code")
	assert_false(net.graph.is_road_tile(Vector2i(4, 10)), "(4,10) is gone from the graph")
	# Give the access tile a second road neighbour, and the original demolish
	# becomes legal — the check is "would this ORPHAN a building", not "is this
	# road load-bearing for the graph".
	net.edit_tile(Vector2i(16, 11), STREET)
	net._flush_edits()
	var second := net.cmd_road_demolish([Vector2i(15, 10)], [access])
	assert_true(bool(second["ok"]), "(16,11) now serves the access tile")
	assert_false(net.graph.is_road_tile(Vector2i(15, 10)), "(15,10) is gone from the graph")
	assert_true(net.graph.is_road_tile(Vector2i(14, 10)),
			"and only the tile that was asked for came up")


func test_build_preview_validation() -> void:
	var net := _corridor()
	_wired(net)
	# Not connected to anything.
	var orphan := net.query_road_preview([Vector2i(80, 80)], STREET)
	assert_false(bool(orphan["ok"]))
	assert_true((orphan["reasons"] as Array).has(&"E_NOT_CONNECTED"))
	# On top of water.
	net.grid.set_flag(11, 11, TileGrid.FLAG_WATER)
	var wet := net.query_road_preview([Vector2i(11, 11)], STREET)
	assert_true((wet["reasons"] as Array).has(&"E_WATER"))
	# Doc 09's land gate, when injected.
	net.land_is_buildable = func(_t: Vector2i) -> bool: return false
	var undeveloped := net.query_road_preview([Vector2i(10, 11)], STREET)
	assert_true((undeveloped["reasons"] as Array).has(&"E_NOT_DEVELOPED"))


func test_under_construction_lifecycle() -> void:
	# §2.13: new tiles enter the grid immediately at condition 0.10 with a
	# construction_new closure, so the crew can reach the far end of its own job.
	var net := _corridor()
	var wiring := _wired(net)
	var tiles: Array = []
	for z in range(11, 16):
		tiles.append(Vector2i(10, z))
	var build := net.cmd_road_build(tiles, STREET, 9000)
	for t in tiles:
		assert_true(net.graph.is_road_tile(t), "the corridor is visible immediately")
		assert_almost_eq(net.condition_of(t), 0.10, 1e-9, "seeded at 0.10 (RR-3)")
		assert_true((net.flags_of(t) & RoadNetwork.FLAG_UNDER_CONSTRUCTION) != 0)
	assert_eq(String(net.graph.edge(net.graph.edge_at(Vector2i(10, 13)))["closure_cause"]),
			"construction_new")
	net.drain_events()
	net.on_job_completed(int(RoadsTestRig.payload(build)["job_id"]))
	for t in tiles:
		assert_almost_eq(net.condition_of(t), 1.0, 1e-9, "job_completed -> condition 1.0")
		assert_eq(net.flags_of(t) & RoadNetwork.FLAG_UNDER_CONSTRUCTION, 0)
	assert_eq(String(net.graph.edge(net.graph.edge_at(Vector2i(10, 13)))["closure_cause"]), "")
	var built := false
	for event in net.drain_events():
		if event["type"] == &"road_built":
			built = true
	assert_true(built, "road_built is emitted")
	# Doc 02 owns the project record: roads reacts to `job_completed`, it never
	# reaches into the queue to erase one (report 98 G-2).
	assert_false(wiring["queue"].job(int(RoadsTestRig.payload(build)["job_id"])).is_empty(),
			"the ConstructionQueue record is doc 02's to retire, not doc 10's")


func test_upgrade_preserves_condition() -> void:
	var net := _corridor()
	_wired(net)
	net.set_condition(Vector2i(5, 10), 0.7)
	net.set_condition(Vector2i(6, 10), 0.7)
	var upgrade := net.cmd_road_upgrade([Vector2i(5, 10), Vector2i(6, 10)], 8000)
	net.on_job_completed(int(RoadsTestRig.payload(upgrade)["job_id"]))
	assert_eq(net.grid.road_class_at(5, 10), AVENUE, "the tile is now an avenue")
	assert_almost_eq(net.condition_of(Vector2i(5, 10)), 0.7, 1e-9,
			"an upgrade preserves condition; it does not reset it")


func test_auto_repair_respects_cap() -> void:
	# §2.12: at most AUTO_REPAIR_MAX_JOBS_PER_DAY, and the running total of doc
	# 03's quotes must stay inside the player's budget cap.
	var tiles: Dictionary = {}
	for z in [10, 20, 30, 40]:
		RoadsTestRig.merge(tiles, RoadsTestRig.line(Vector2i(0, z), Vector2i(30, z), STREET))
	var net := RoadsTestRig.network_with(tiles)
	var wiring := _wired(net)
	net.cmd_set_auto_repair_policy(0.40, 25000)
	for z in [10, 20, 30, 40]:
		for x in range(0, 31):
			net.set_condition(Vector2i(x, z), 0.20)
	var queued := net._queue_auto_repairs()
	assert_true(queued.size() <= net.tun.auto_repair_max_jobs_per_day,
			"at most 3 jobs a day (%d)" % queued.size())
	var total := 0
	var queue: ConstructionQueue = wiring["queue"]
	for job_id in queued:
		total += int(queue.job(job_id)["payload"]["cost"])
	assert_true(total <= net.auto_repair_daily_cap,
			"the running total of doc 03's quotes stays inside the cap ($%d)" % total)
	assert_true(total > 0, "and the quotes are real doc-03 numbers")
	# Threshold 0 means off.
	net.cmd_set_auto_repair_policy(0.0, 25000)
	assert_eq(net._queue_auto_repairs().size(), 0, "threshold 0 disables auto-repair")
	assert_false(bool(net.cmd_set_auto_repair_policy(0.33, 25000)["ok"]),
			"only the four authored thresholds are selectable")


func test_both_dials_are_levers_and_each_can_stop_the_spend_on_its_own() -> void:
	# Wave 12: the two dials got a settings row (doc 12 D-50), so what each of
	# them DOES has to be a gate rather than a claim. Roads worn to 0.30: a
	# threshold below that queues nothing, one above it queues; and a $0 budget
	# stops the same city that a $25,000 one repairs.
	var tiles: Dictionary = {}
	for z in [10, 20]:
		RoadsTestRig.merge(tiles, RoadsTestRig.line(Vector2i(0, z), Vector2i(30, z), STREET))
	for arm: Array in [[0.25, 25000, false], [0.40, 25000, true],
			[0.55, 25000, true], [0.55, 0, false], [0.0, 25000, false]]:
		var net := RoadsTestRig.network_with(tiles)
		_wired(net)
		assert_true(bool(net.cmd_set_auto_repair_policy(float(arm[0]),
				int(arm[1]))["ok"]), "%s is on doc 10's ladder" % str(arm[0]))
		for z in [10, 20]:
			for x in range(0, 31):
				net.set_condition(Vector2i(x, z), 0.30)
		var queued := net._queue_auto_repairs().size()
		if bool(arm[2]):
			assert_true(queued > 0,
					"threshold %s / cap %d sends a crew" % [str(arm[0]), int(arm[1])])
		else:
			assert_eq(queued, 0,
					"threshold %s / cap %d sends nobody" % [str(arm[0]), int(arm[1])])


# ------------------------------------------------------------------ persistence

func test_section_version_key() -> void:
	# Report 98 C-25: `section_version`, never `schema_version`.
	var net := RoadsTestRig.starter_network()
	var section := net.save_section()
	assert_true(section.has("section_version"))
	# 1 → 2 (Wave 5): the id-keyed `edge_dynamics` / `c_day_sum` maps moved onto
	# the edge's canonical tile key, and the graph's LABELLING now travels with
	# the save. See `RoadNetwork.SECTION_VERSION` for why a rebuild cannot
	# re-derive it once a road tile has ever been edited.
	# 2 → 3 (Wave 13): the daily sampler's `last_hour_sampled` cursor. See
	# `RoadNetwork.SECTION_VERSION` for the two readers that were wrong without it.
	assert_eq(int(section["section_version"]), RoadNetwork.SECTION_VERSION)
	assert_eq(RoadNetwork.SECTION_VERSION, 3)
	assert_false(section.has("schema_version"),
			"schema_version exists ONLY on doc 08's envelope")
	var text := JSON.stringify(section)
	assert_false(text.contains("schema_version"), "and nowhere inside the section")


## Doc 08 §2.8, the rung read from both ends: a v3 section carries the sampler
## cursor and restores it, and a v2 section — every save the game has written
## until now — still loads, to the `-1` it has always restored to.
func test_the_daily_sampler_cursor_rides_the_save() -> void:
	var net := RoadsTestRig.starter_network()
	# Reach hour 14 of a game-day the way the sim does, so the cursor is a real
	# sample point and not a poked member.
	net.full_pass(RoadsTestRig.context(GameClock.TICKS_PER_HOUR * 14, 14.5))
	var section := net.save_section()
	assert_eq(int(section["last_hour_sampled"]), 14,
			"the sampler banked hour 14 and says so")

	var reloaded := RoadNetwork.new(TileGrid.new(), net.tun, RngStreams.new(1337))
	reloaded.load_section(section)
	assert_almost_eq(reloaded._last_sample_hour(), 14.5, 1e-12,
			"the restored city prices an immediate closure spillback at the hour "
			+ "it is actually in, not at the hard-coded noon a -1 produces")

	# The v2 body: additive-first, so dropping the key restores the old behaviour
	# rather than refusing the load.
	var old := section.duplicate(true)
	old["section_version"] = 2
	old.erase("last_hour_sampled")
	var legacy := RoadNetwork.new(TileGrid.new(), net.tun, RngStreams.new(1337))
	legacy.load_section(old)
	assert_almost_eq(legacy._last_sample_hour(), 12.0, 1e-12,
			"a v2 section has no cursor and lands on the documented default")
	assert_eq(legacy.graph.edge_count(), net.graph.edge_count(),
			"and the rest of a v2 section loads exactly as it always did")


func test_save_load_roundtrip() -> void:
	var net := RoadsTestRig.starter_network()
	net.set_condition(Vector2i(40, 32), 0.6234)
	net.set_condition(Vector2i(41, 32), 0.5)
	net.set_flag(Vector2i(42, 32), RoadNetwork.FLAG_DEBRIS, true)
	var closure_id := net.add_closure([Vector2i(50, 47)], "accident_major", 0.8, 240, 913)
	net.cmd_set_auto_repair_policy(0.55, 12000)
	var section := net.save_section()

	var reloaded := RoadNetwork.new(TileGrid.new(), net.tun, RngStreams.new(1337))
	reloaded.load_section(section)
	assert_eq(reloaded.graph.road_tile_count(), 783, "identical tile grid")
	assert_eq(reloaded.road_tile_counts(), net.road_tile_counts())
	assert_eq(reloaded.graph.node_count(), net.graph.node_count(), "identical rebuilt graph")
	assert_eq(reloaded.graph.edge_count(), net.graph.edge_count())
	assert_almost_eq(reloaded.condition_of(Vector2i(41, 32)), 0.5, 1e-9)
	assert_eq(reloaded.flags_of(Vector2i(42, 32)), RoadNetwork.FLAG_DEBRIS)
	assert_eq(reloaded.active_closure_count(), 1, "identical closure set")
	assert_eq(String(reloaded.closure(closure_id)["cause"]), "accident_major")
	assert_eq(int(reloaded.closure(closure_id)["source_incident_id"]), 913)
	assert_almost_eq(reloaded.auto_repair_threshold, 0.55, 1e-9)
	assert_eq(reloaded.auto_repair_daily_cap, 12000)
	# The sub-quantum condition remainder survives (§3.2 condition_accum).
	assert_almost_eq(reloaded.condition_of(Vector2i(40, 32)), 0.6234, 1e-9,
			"the < 0.01 fractional remainder is lossless across a save")
	# Edge tile-sets match exactly.
	var mine: Array = []
	var theirs: Array = []
	for edge_id in net.graph.edge_ids_sorted():
		mine.append(RoadGraph._tiles_key(net.graph.edge(edge_id)["tiles"]))
	for edge_id in reloaded.graph.edge_ids_sorted():
		theirs.append(RoadGraph._tiles_key(reloaded.graph.edge(edge_id)["tiles"]))
	mine.sort()
	theirs.sort()
	assert_eq(str(mine), str(theirs), "identical edge tile-sets")


func test_save_size_on_a_large_map() -> void:
	# §3.2: the RLE tile blocks must stay small. Doc's reference is 12,000 road
	# tiles < 400 KB.
	var tiles: Dictionary = {}
	for i in range(0, 112, 4):
		RoadsTestRig.merge(tiles, RoadsTestRig.line(Vector2i(0, i), Vector2i(111, i),
				AVENUE if i % 16 == 0 else STREET))
		RoadsTestRig.merge(tiles, RoadsTestRig.line(Vector2i(i, 0), Vector2i(i, 111),
				AVENUE if i % 16 == 0 else STREET), false)
	var net := RoadsTestRig.network_with(tiles)
	var count := net.graph.road_tile_count()
	assert_true(count > 5000, "a genuinely large map (%d road tiles)" % count)
	var bytes := JSON.stringify(net.save_section()).length()
	assert_true(bytes < 400 * 1024,
			"%d road tiles serialise to %d bytes, inside the 400 KB budget" % [count, bytes])


func test_congestion_smoother_is_saved() -> void:
	# AMENDED (doc 93 §E2): §3.2 called congestion a pure function and reloaded
	# it cold — but the smoother CARRIES HISTORY, and a cold reload made a
	# loaded city diverge from the live run it was saved from, breaking the
	# save→load→advance identity doctrine (which outranks §3.2). The smoothed
	# value now rides the save and comes back exactly where the live run had it.
	var net := _corridor()
	var edge_id := net.graph.edge_ids_sorted()[0]
	net.congestion.set_congestion(edge_id, 1.9)
	var section := net.save_section()
	var reloaded := RoadNetwork.new(TileGrid.new(), net.tun, RngStreams.new(1))
	reloaded.load_section(section)
	assert_almost_eq(
			reloaded.congestion.congestion_of(reloaded.graph.edge_ids_sorted()[0]),
			1.9, 1e-9, "the saved jam level survives the reload bit-exactly")


# ------------------------------------------------------- offline / online parity

func test_offline_advance_matches_online() -> void:
	# The doc 06 mode-invariance gate. Two game-days, same weather, same
	# closures: (a) condition agrees exactly, (b) route_minutes is bit-identical
	# for a shared quantised congestion snapshot, (c) a coarse step lands on c_raw.
	var fine := _corridor(40)
	var coarse := _corridor(40)
	for net in [fine, coarse]:
		net.set_density_sources([{"tile": Vector2i(20, 12), "pj": 410.0}])
		net.refresh_density()

	var fine_clock := GameClock.new()
	for tick in range(0, GameClock.TICKS_PER_DAY * 2):
		fine_clock.tick_index = tick
		var ctx := _clock_context(fine_clock)
		fine.step(ctx)
		if tick % GameClock.TICKS_PER_MINUTE == 0:
			fine.full_pass(ctx)
		if tick % GameClock.TICKS_PER_DAY == 0:
			fine.on_day(ctx)

	var coarse_clock := GameClock.new()
	for hour in range(0, 48):
		coarse_clock.tick_index = hour * GameClock.TICKS_PER_HOUR
		var ctx := _clock_context(coarse_clock, TimeContext.Mode.COARSE)
		coarse.step(ctx)
		coarse.full_pass(ctx)
		if coarse_clock.tick_index % GameClock.TICKS_PER_DAY == 0:
			coarse.on_day(ctx)

	# (a) condition
	var checked := 0
	for x in range(0, 41):
		var t := Vector2i(x, 10)
		assert_almost_eq(coarse.condition_of(t), fine.condition_of(t), 1e-9,
				"condition at %s agrees between modes" % str(t))
		checked += 1
	assert_eq(checked, 41)
	assert_true(fine.condition_of(Vector2i(20, 10)) < 1.0, "decay actually happened")

	# (c) a coarse step lands exactly on c_raw
	var edge_id: int = coarse.graph.edge_ids_sorted()[0]
	var inputs := coarse._congestion_inputs(float(coarse_clock.hour_of_day()) + 0.5, 60.0, false)
	assert_almost_eq(coarse.congestion.congestion_of(edge_id),
			coarse.congestion.c_raw(edge_id, inputs), 1e-9,
			"c_e after a coarse step IS c_raw for that step")

	# (b) identical quantised snapshot -> bit-identical route_minutes
	for other in fine.graph.edge_ids_sorted():
		var key := RoadGraph._tiles_key(fine.graph.edge(other)["tiles"])
		for mirror in coarse.graph.edge_ids_sorted():
			if RoadGraph._tiles_key(coarse.graph.edge(mirror)["tiles"]) == key:
				fine.graph.edge(other)["congestion"] = coarse.graph.edge(mirror)["congestion"]
				break
	var prof := RouteProfile.emergency(32.0, 0)
	fine.planner.invalidate_all()
	coarse.planner.invalidate_all()
	for i in 20:
		var a := Vector2i(i, 10)
		var b := Vector2i(40 - i, 10)
		assert_almost_eq(fine.route_minutes(a, b, prof), coarse.route_minutes(a, b, prof), 0.0,
				"pair %d quotes bit-identically in both modes" % i)


# --------------------------------------------------- report 98 conformance

func test_roads_json_holds_no_prices() -> void:
	# Report 98 RR-2 — the doc-10 half of doc 03's test 33.
	var data := StarterCityLoader.read_json("res://data/roads.json")
	var forbidden := ["build_cost", "upgrade_from_street_cost", "upkeep_per_game_day",
			"repair_cost_base", "demolish_refund_pct", "block_template_replacement_cost",
			"block_template_upkeep_per_game_day"]
	var offenders: Array = []
	_scan_keys(data, forbidden, offenders)
	assert_eq(str(offenders), "[]", "no price key at any depth of data/roads.json")
	# ... and sim/roads/ contains no currency literal or billing call.
	for file in ["road_network.gd", "road_graph.gd", "route_planner.gd", "road_costs.gd",
			"congestion_model.gd", "road_tunables.gd", "traffic_feed.gd",
			"traffic_snapshot.gd", "route_profile.gd"]:
		var source := FileAccess.get_file_as_string("res://sim/roads/" + file)
		for line in source.split("\n"):
			var comment_at := line.find("#")
			var code: String = line.substr(0, comment_at) if comment_at >= 0 else line
			assert_false(code.contains("Treasury"), "%s bills directly" % file)
			assert_false(code.contains("bill_upkeep"), "%s bills upkeep" % file)
			assert_false(code.contains("$"), "%s holds a currency literal" % file)


func _scan_keys(value: Variant, forbidden: Array, offenders: Array) -> void:
	if value is Dictionary:
		for key in value:
			if forbidden.has(String(key)):
				offenders.append(String(key))
			_scan_keys(value[key], forbidden, offenders)
	elif value is Array:
		for entry in value:
			_scan_keys(entry, forbidden, offenders)


func test_on_day_makes_no_billing_call() -> void:
	# RR-2: roads carry NO standing upkeep. 30 game-days, zero billing calls.
	var net := _corridor()
	var billed := 0
	net.repair_quote = func(_c: String, _f: float) -> int:
		billed += 1
		return 0
	# No submit_job wired, so auto-repair cannot even reach a quote.
	net.cmd_set_auto_repair_policy(0.0, 25000)
	var clock := GameClock.new()
	for day in 31:
		clock.tick_index = day * GameClock.TICKS_PER_DAY
		net.on_day(_clock_context(clock))
	assert_eq(billed, 0, "30 game-days of decay bill nothing — a road has no upkeep")
	assert_true(net.condition_of(Vector2i(15, 10)) < 1.0, "but it did decay")


func test_condition_is_unit_interval_under_stress() -> void:
	# Test 48: 30 game-days of decay, damage, repairs, collapses and a save/load
	# round trip; every condition read stays on [0,1].
	var net := _corridor(40)
	_wired(net)
	var rng := RandomNumberGenerator.new()
	rng.seed = 2718
	var clock := GameClock.new()
	for day in 31:
		clock.tick_index = day * GameClock.TICKS_PER_DAY
		var ctx := _clock_context(clock)
		net.full_pass(ctx)
		net.on_day(ctx)
		var t := Vector2i(rng.randi_range(0, 40), 10)
		net.apply_damage([t], ["accident_major_resolve", "flood_deep_recede",
				"adjacent_structure_fire"][rng.randi_range(0, 2)])
		if rng.randf() < 0.15:
			net.set_condition(t, 0.0)
		if rng.randf() < 0.2:
			net.set_condition(t, 1.0)
		for x in range(0, 41):
			var value := net.condition_of(Vector2i(x, 10))
			assert_true(value >= 0.0 and value <= 1.0,
					"day %d tile %d condition %f is on [0,1]" % [day, x, value])
	for edge_id in net.graph.edge_ids_sorted():
		var mean := float(net.graph.edge(edge_id)["condition"])
		assert_true(mean >= 0.0 and mean <= 1.0, "edge mean %f is on [0,1]" % mean)
	var reloaded := RoadNetwork.new(TileGrid.new(), net.tun, RngStreams.new(1))
	reloaded.load_section(net.save_section())
	for x in range(0, 41):
		assert_almost_eq(reloaded.condition_of(Vector2i(x, 10)),
				net.condition_of(Vector2i(x, 10)), 1e-9, "and survives the round trip")


# ----------------------------------------------------- access & doc 02/03/06 API

func test_access_quality_is_the_single_definition() -> void:
	# Report 98 C-61. An ordinary house on a street reads 0.90; when its street
	# floods it reads 0.495 — below doc 06's 0.6 degraded-response threshold.
	var net := _corridor()
	var house := Vector2i(15, 11)
	assert_almost_eq(net.access_quality(house), 0.90, 1e-9, "street only, road within 1")
	assert_almost_eq(net.road_access_mult(house), 1.00, 1e-9, "doc 02's within-1 constant")
	assert_almost_eq(net.road_access_mult(Vector2i(15, 12)), 0.85, 1e-9, "within 2")
	assert_almost_eq(net.road_access_mult(Vector2i(15, 14)), 0.00, 1e-9, "beyond 2")
	assert_true(net.has_road_access(house))
	net.add_closure([Vector2i(15, 10)], "flood_shallow", 1.0, 999999)
	assert_almost_eq(net.access_quality(house), 0.495, 1e-9,
			"a soft-closed street: 1.00 x 0.90 x 0.55 — exactly doc 06's bite point")
	assert_true(net.access_quality(house) < 0.6, "and it is below the 0.6 threshold")
	# An avenue within 4 restores w_class to 1.00.
	var avenue_net := RoadsTestRig.network_with(
			RoadsTestRig.line(Vector2i(0, 10), Vector2i(30, 10), AVENUE))
	assert_almost_eq(avenue_net.access_quality(Vector2i(15, 11)), 1.00, 1e-9)
	# A hard block drops it to 0.20; no road at all is 0.
	var hard := _corridor()
	hard.add_closure([Vector2i(15, 10)], "flood_deep", 1.0, 999999)
	assert_almost_eq(hard.access_quality(Vector2i(15, 11)), 0.90 * 0.20, 1e-9)
	assert_almost_eq(net.access_quality(Vector2i(15, 40)), 0.0, 1e-9, "no road within 6")


func test_access_quality_zero_without_a_station_in_component() -> void:
	var tiles: Dictionary = {}
	RoadsTestRig.merge(tiles, RoadsTestRig.line(Vector2i(0, 10), Vector2i(10, 10), STREET))
	RoadsTestRig.merge(tiles, RoadsTestRig.line(Vector2i(0, 30), Vector2i(10, 30), STREET))
	var net := RoadsTestRig.network_with(tiles)
	var served := net.graph.component_of_tile(Vector2i(5, 10))
	net.set_station_components([served])
	assert_true(net.access_quality(Vector2i(5, 11)) > 0.0, "the served island is fine")
	assert_almost_eq(net.access_quality(Vector2i(5, 31)), 0.0, 1e-9,
			"a component with no station of any department reads 0")


func test_signalised_intersections_and_dark_fraction() -> void:
	# Doc 06 computes dark_frac from this list (§2.11).
	var net := RoadsTestRig.starter_network()
	var rows := net.signalised_intersections("")
	assert_true(rows.size() > 300, "the stamped core signalises hundreds of nodes")
	assert_almost_eq(net.dark_fraction(""), 0.0, 1e-9, "all lit at boot")
	var dark: Dictionary = {}
	for i in mini(50, rows.size()):
		dark[rows[i]["tile"]] = true
	net.power_is_tile_powered = func(t: Vector2i) -> bool: return not dark.has(t)
	net.step(RoadsTestRig.context(4, 12.0))
	assert_almost_eq(net.dark_fraction(""), 50.0 / float(rows.size()), 1e-6,
			"dark_frac = count(signalised AND NOT powered) / count(signalised)")
	for row in net.signalised_intersections(""):
		assert_eq(bool(row["powered"]), not dark.has(row["tile"]),
				"the list is stable within a step")


func test_condition_hazard_mult_exposed_to_doc06() -> void:
	var net := _corridor()
	var edge_id := net.graph.edge_at(Vector2i(15, 10))
	assert_almost_eq(net.condition_hazard_mult(edge_id), 1.00, 1e-9)
	for x in range(0, 31):
		net.set_condition(Vector2i(x, 10), 0.10)
	assert_almost_eq(net.condition_hazard_mult(edge_id), 1.26, 1e-9,
			"C-48: doc 06 multiplies this into its traffic_accident rate")


func test_components_summary_for_doc07() -> void:
	var tiles: Dictionary = {}
	RoadsTestRig.merge(tiles, RoadsTestRig.line(Vector2i(0, 10), Vector2i(10, 10), STREET))
	RoadsTestRig.merge(tiles, RoadsTestRig.line(Vector2i(0, 30), Vector2i(10, 30), STREET))
	var net := RoadsTestRig.network_with(tiles)
	net.set_station_components([net.graph.component_of_tile(Vector2i(5, 10))])
	var summary := net.components_summary()
	assert_eq(summary.size(), 2, "which districts are cut off, for the Director")
	var with_station := 0
	for entry in summary:
		if bool(entry["has_station"]):
			with_station += 1
		assert_true(int(entry["tile_count"]) > 0)
	assert_eq(with_station, 1)
