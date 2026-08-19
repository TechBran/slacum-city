extends SimTest
## Doc 10 §2.7 / §2.14 — A* optimality, determinism, snapping, blocks, the
## budget, the route cache, and the TravelTimeProvider contract doc 06 injects.
## Test plan cases 14–24, plus §4's contract guarantees 1–6.

const AVENUE := RoadTunables.CLASS_AVENUE
const STREET := RoadTunables.CLASS_STREET


## A 40x40 lattice with cross-streets every 4 tiles and avenues every 8/12.
func _lattice(seed_value: int = 11) -> RoadNetwork:
	var tiles: Dictionary = {}
	for i in range(0, 40, 4):
		RoadsTestRig.merge(tiles, RoadsTestRig.line(Vector2i(0, i), Vector2i(36, i),
				AVENUE if i % 8 == 0 else STREET))
		RoadsTestRig.merge(tiles, RoadsTestRig.line(Vector2i(i, 0), Vector2i(i, 36),
				AVENUE if i % 12 == 0 else STREET), false)
	return RoadsTestRig.network_with(tiles, seed_value)


func _randomise(net: RoadNetwork, seed_value: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	for edge_id in net.graph.edge_ids_sorted():
		net.graph.edge(edge_id)["congestion"] = rng.randf() * 2.0
		net.graph.edge(edge_id)["condition"] = 0.25 + rng.randf() * 0.75


# ---------------------------------------------------------------- optimality

## Reference Dijkstra over the same relaxation the planner uses.
func _dijkstra(net: RoadNetwork, start_node: int, goal_node: int,
		prof: RouteProfile) -> float:
	var dist: Dictionary = {start_node: 0.0}
	var settled: Dictionary = {}
	while true:
		var best := -1
		var best_cost := INF
		for node_id in dist:
			if settled.has(node_id):
				continue
			if float(dist[node_id]) < best_cost:
				best_cost = float(dist[node_id])
				best = int(node_id)
		if best < 0:
			break
		settled[best] = true
		if best == goal_node:
			return best_cost
		for edge_id in net.graph.node(best)["edge_ids"]:
			var other := net.graph.other_node(edge_id, best)
			if other == best or other < 0:
				continue
			var cost := net.planner.edge_cost_gm(edge_id, prof)
			if is_inf(cost):
				continue
			var delay := 0.0 if best == start_node \
					else net.planner.node_delay_gm(best, edge_id, prof)
			var candidate := best_cost + delay + cost
			if candidate < float(dist.get(other, INF)):
				dist[other] = candidate
	return float(dist.get(goal_node, INF))


func test_astar_optimal_vs_dijkstra() -> void:
	var net := _lattice()
	_randomise(net, 777)
	var prof := RouteProfile.emergency(30.0, 0)
	var rng := RandomNumberGenerator.new()
	rng.seed = 5150
	var nodes := net.graph.node_ids_sorted()
	var compared := 0
	for i in 40:
		var a: int = nodes[rng.randi_range(0, nodes.size() - 1)]
		var b: int = nodes[rng.randi_range(0, nodes.size() - 1)]
		if a == b:
			continue
		var a_tile: Vector2i = net.graph.node(a)["tile"]
		var b_tile: Vector2i = net.graph.node(b)["tile"]
		var astar := net.planner.find_path(a_tile, b_tile, prof, {"epsilon": 1.0})
		var reference := _dijkstra(net, a, b, prof)
		compared += 1
		assert_almost_eq(float(astar["minutes"]), reference, 1e-6,
				"A* with eps=1 equals Dijkstra for %s -> %s" % [str(a_tile), str(b_tile)])
	assert_true(compared >= 35, "the sample actually ran (%d pairs)" % compared)


func test_epsilon_bounded_suboptimality() -> void:
	var net := _lattice()
	_randomise(net, 909)
	var prof := RouteProfile.utility(24.0, 3)
	var rng := RandomNumberGenerator.new()
	rng.seed = 3131
	var nodes := net.graph.node_ids_sorted()
	var worst := 1.0
	for i in 40:
		var a: Vector2i = net.graph.node(nodes[rng.randi_range(0, nodes.size() - 1)])["tile"]
		var b: Vector2i = net.graph.node(nodes[rng.randi_range(0, nodes.size() - 1)])["tile"]
		if a == b:
			continue
		var optimal := net.planner.find_path(a, b, prof, {"epsilon": 1.0})
		net.planner.invalidate_all()
		var relaxed := net.planner.find_path(a, b, prof, {"epsilon": 1.25})
		if not bool(optimal["ok"]):
			continue
		var ratio := float(relaxed["minutes"]) / maxf(1e-9, float(optimal["minutes"]))
		worst = maxf(worst, ratio)
		assert_true(ratio <= 1.25 + 1e-9, "eps=1.25 stays within its bound (%f)" % ratio)
	assert_true(worst >= 1.0, "measured worst ratio %f" % worst)


# --------------------------------------------------------------- determinism

func test_deterministic_paths() -> void:
	var net := _lattice()
	_randomise(net, 246)
	var prof := RouteProfile.emergency(32.0, 0)
	var a := Vector2i(1, 1)
	var b := Vector2i(35, 35)
	var first := net.planner.find_path(a, b, prof, {})
	var signature := str(first["edge_ids"])
	for i in 50:
		net.planner.invalidate_all()
		var again := net.planner.find_path(a, b, prof, {})
		assert_eq(str(again["edge_ids"]), signature, "run %d is byte-identical" % i)
		assert_almost_eq(float(again["minutes"]), float(first["minutes"]), 0.0)
	# ... and identical after a save / load / rebuild cycle. Edges are matched by
	# their canonical TILE LIST, because ids are derived and the graph is never
	# saved (§3.2) — that is exactly the property being tested.
	var saved := net.save_section()
	var reloaded := RoadNetwork.new(TileGrid.new(), net.tun, RngStreams.new(1337))
	reloaded.load_section(saved)
	var by_key: Dictionary = {}
	for edge_id in reloaded.graph.edge_ids_sorted():
		by_key[RoadGraph._tiles_key(reloaded.graph.edge(edge_id)["tiles"])] = edge_id
	assert_eq(reloaded.graph.edge_count(), net.graph.edge_count(), "same edge count")
	for edge_id in net.graph.edge_ids_sorted():
		var key := RoadGraph._tiles_key(net.graph.edge(edge_id)["tiles"])
		assert_true(by_key.has(key), "every edge survives the round trip")
		var mirror := int(by_key[key])
		reloaded.graph.edge(mirror)["congestion"] = net.graph.edge(edge_id)["congestion"]
		reloaded.graph.edge(mirror)["condition"] = net.graph.edge(edge_id)["condition"]
	var after := reloaded.planner.find_path(a, b, prof, {})
	assert_almost_eq(float(after["minutes"]), float(first["minutes"]), 1e-9,
			"the rebuilt graph prices the same route identically")
	assert_eq(str(after["tiles"]), str(first["tiles"]), "and walks the same tiles")


func test_neighbour_iteration_is_by_edge_id() -> void:
	# Determinism rests on ascending edge_id iteration; assert the invariant.
	var net := _lattice()
	for node_id in net.graph.node_ids_sorted():
		var ids: Array = net.graph.node(node_id)["edge_ids"]
		for i in range(1, ids.size()):
			assert_true(int(ids[i - 1]) < int(ids[i]), "node %d edge_ids ascend" % node_id)


# ------------------------------------------------------------------ snapping

func test_snapping_same_edge() -> void:
	var tiles := RoadsTestRig.line(Vector2i(0, 10), Vector2i(30, 10), STREET)
	var net := RoadsTestRig.network_with(tiles)
	var prof := RouteProfile.civilian(34.0)
	var result := net.planner.find_path(Vector2i(5, 10), Vector2i(20, 10), prof, {})
	assert_true(bool(result["ok"]))
	assert_eq(int(result["expansions"]), 0, "same-edge answers need no node expansion")
	assert_eq((result["tiles"] as Array).size(), 16, "the direct sub-segment")
	assert_almost_eq(float(result["length_m"]), 120.0, 1e-9)
	var whole := net.planner.edge_cost_gm(net.graph.edge_at(Vector2i(5, 10)), prof)
	assert_almost_eq(float(result["minutes"]), whole * 15.0 / 30.0, 1e-9,
			"priced as the exact fraction of the edge it uses")


func test_snap_radius_and_failure_modes() -> void:
	var tiles := RoadsTestRig.line(Vector2i(0, 10), Vector2i(30, 10), STREET)
	var net := RoadsTestRig.network_with(tiles)
	var prof := RouteProfile.civilian(34.0)
	# Within SNAP_RADIUS_TILES = 6.
	var near := net.planner.find_path(Vector2i(5, 16), Vector2i(20, 10), prof, {})
	assert_true(bool(near["ok"]), "6 tiles away still snaps")
	var far := net.planner.find_path(Vector2i(5, 30), Vector2i(20, 10), prof, {})
	assert_false(bool(far["ok"]))
	assert_eq(int(far["fail_reason"]), RouteProfile.RouteFail.NO_ROAD_NEAR_ORIGIN)
	var far_goal := net.planner.find_path(Vector2i(5, 10), Vector2i(20, 40), prof, {})
	assert_eq(int(far_goal["fail_reason"]), RouteProfile.RouteFail.NO_ROAD_NEAR_DEST)
	assert_true(is_inf(net.route_minutes(Vector2i(5, 30), Vector2i(20, 10), prof)),
			"an unroutable quote is INF, never a big finite number")


func test_unreachable_fast_reject() -> void:
	var tiles: Dictionary = {}
	RoadsTestRig.merge(tiles, RoadsTestRig.line(Vector2i(0, 10), Vector2i(10, 10), STREET))
	RoadsTestRig.merge(tiles, RoadsTestRig.line(Vector2i(0, 30), Vector2i(10, 30), STREET))
	var net := RoadsTestRig.network_with(tiles)
	var prof := RouteProfile.emergency(32.0, 0)
	assert_eq(net.graph.component_count(), 2, "two islands")
	assert_false(net.is_reachable(Vector2i(5, 10), Vector2i(5, 30), prof))
	var result := net.planner.find_path(Vector2i(5, 10), Vector2i(5, 30), prof, {})
	assert_false(bool(result["ok"]))
	assert_eq(int(result["fail_reason"]), RouteProfile.RouteFail.UNREACHABLE)
	assert_eq(int(result["expansions"]), 0, "the union-find pre-check costs zero expansions")
	assert_true(is_inf(net.route_minutes(Vector2i(5, 10), Vector2i(5, 30), prof)))


# ------------------------------------------------------------------- blocks

## A single corridor with one closable middle edge and no detour.
func _single_corridor() -> Dictionary:
	var tiles: Dictionary = {}
	RoadsTestRig.merge(tiles, RoadsTestRig.line(Vector2i(0, 10), Vector2i(30, 10), STREET))
	RoadsTestRig.merge(tiles, RoadsTestRig.line(Vector2i(10, 9), Vector2i(10, 11), STREET), false)
	RoadsTestRig.merge(tiles, RoadsTestRig.line(Vector2i(20, 9), Vector2i(20, 11), STREET), false)
	var net := RoadsTestRig.network_with(tiles)
	return {"net": net, "middle": net.graph.edge_at(Vector2i(15, 10))}


func test_hard_block_never_traversed() -> void:
	var rig := _single_corridor()
	var net: RoadNetwork = rig["net"]
	net.add_closure([Vector2i(15, 10)], "flood_deep", 1.0, 999999)
	for route_class in [RouteProfile.RouteClass.EMERGENCY, RouteProfile.RouteClass.UTILITY,
			RouteProfile.RouteClass.CONSTRUCTION, RouteProfile.RouteClass.CIVILIAN]:
		var prof := RouteProfile.new(30.0, route_class, true)  # even ignoring closures
		var minutes := net.route_minutes(Vector2i(2, 10), Vector2i(28, 10), prof)
		assert_true(is_inf(minutes),
				"flood_deep is impassable for class %d even with ignores_closures" % route_class)


func test_soft_block_second_chance() -> void:
	var rig := _single_corridor()
	var net: RoadNetwork = rig["net"]
	net.add_closure([Vector2i(15, 10)], "accident_major", 0.8, 999999)
	var civilian := RouteProfile.civilian(34.0)
	assert_true(is_inf(net.route_minutes(Vector2i(2, 10), Vector2i(28, 10), civilian)),
			"accident_major BLOCKS civilians")
	var desperate := RouteProfile.new(34.0, RouteProfile.RouteClass.CIVILIAN, true)
	var quote := net.route_minutes(Vector2i(2, 10), Vector2i(28, 10), desperate)
	assert_false(is_inf(quote), "the second-chance pass admits it")
	# The soft block is admitted at DESPERATE_BLOCK_MULT = 12.0 — measured on the
	# SAME network, so the congestion snapshot is identical either way.
	var middle := int(rig["middle"])
	var closed_cost := net.planner.edge_cost_gm(middle, desperate)
	var cause: String = net.graph.edge(middle)["closure_cause"]
	net.graph.edge(middle)["closure_cause"] = ""
	var open_cost := net.planner.edge_cost_gm(middle, desperate)
	net.graph.edge(middle)["closure_cause"] = cause
	assert_almost_eq(closed_cost, open_cost * net.tun.desperate_block_mult, 1e-9,
			"priced at x12 rather than excluded")
	# EMERGENCY is never blocked by accident_major; it pays x1.8.
	var engine := RouteProfile.emergency(32.0, 0)
	assert_false(is_inf(net.route_minutes(Vector2i(2, 10), Vector2i(28, 10), engine)))


func test_under_construction_blocks_civilians() -> void:
	var rig := _single_corridor()
	var net: RoadNetwork = rig["net"]
	net.add_closure([Vector2i(15, 10)], "construction_new", 1.0, -1)
	var civilian := RouteProfile.civilian(34.0)
	assert_true(is_inf(net.route_minutes(Vector2i(2, 10), Vector2i(28, 10), civilian)),
			"a construction_new tile is CIVILIAN-blocked")
	var crew := RouteProfile.construction(18.0)
	var middle := int(rig["middle"])
	var crew_cost := net.planner.edge_cost_gm(middle, crew)
	var cause: String = net.graph.edge(middle)["closure_cause"]
	net.graph.edge(middle)["closure_cause"] = ""
	var base := net.planner.edge_cost_gm(middle, crew)
	net.graph.edge(middle)["closure_cause"] = cause
	assert_almost_eq(crew_cost, base, 1e-9,
			"but CONSTRUCTION traverses its own site at x1.0")
	assert_false(is_inf(net.route_minutes(Vector2i(2, 10), Vector2i(28, 10), crew)),
			"so a crew can always reach the far end of its own job")


# --------------------------------------------------------------- budget & cache

func test_route_budget_caps() -> void:
	var net := _lattice()
	_randomise(net, 31337)
	var prof := RouteProfile.utility(24.0, 2)
	var rng := RandomNumberGenerator.new()
	rng.seed = 8080
	var tickets: Array[int] = []
	for i in 40:
		var a := Vector2i(rng.randi_range(0, 36), rng.randi_range(0, 36))
		var b := Vector2i(rng.randi_range(0, 36), rng.randi_range(0, 36))
		tickets.append(net.planner.request_path(a, b, prof, 2, i, 0))
	assert_eq(net.planner.pending_count(), 40)
	var resolved := 0
	for tick in 60:
		var results := net.planner.step(tick)
		resolved += results.size()
		assert_true(net.planner.expansions_this_tick <= net.tun.max_expansions_per_tick,
				"tick %d spent %d expansions" % [tick, net.planner.expansions_this_tick])
	assert_eq(resolved, 40, "every request resolves or fails inside the budget")
	assert_eq(net.planner.pending_count(), 0)


func test_priority_aging() -> void:
	# A routine request queued behind a continuous stream of P0 work must still
	# resolve: effective_priority = max(0, priority - wait_ticks / 8).
	var net := _lattice()
	var routine := RouteProfile.construction(18.0, 3)
	var urgent := RouteProfile.emergency(32.0, 0)
	var starved := net.planner.request_path(Vector2i(1, 1), Vector2i(35, 35), routine, 3, 999, 0)
	var seen := false
	for tick in 40:
		for i in 3:
			net.planner.request_path(Vector2i(1, 1), Vector2i(33 - i, 29), urgent, 0, i, tick)
		for result in net.planner.step(tick):
			if int(result["ticket_id"]) == starved:
				seen = true
		if seen:
			break
	assert_true(seen, "the aged P3 request resolves within 40 ticks")


func test_cache_hit_reprices_on_congestion() -> void:
	var net := _lattice()
	var prof := RouteProfile.emergency(32.0, 0)
	var a := Vector2i(1, 1)
	var b := Vector2i(35, 35)
	var first := net.planner.quote(a, b, prof)
	var edge_ids := str(first["edge_ids"])
	var before := float(first["minutes"])
	# A change SMALLER than one CONG_QUANT step must not move the quote at all.
	var edge_id := int((first["edge_ids"] as Array)[0])
	var quantum := net.tun.cong_quant
	var anchor := RoadCosts.quantise_congestion(net.congestion.congestion_of(edge_id), quantum)
	net.congestion.set_congestion(edge_id, anchor)
	before = float(net.planner.quote(a, b, prof)["minutes"])
	net.congestion.set_congestion(edge_id, anchor + quantum * 0.4)
	var tiny := net.planner.quote(a, b, prof)
	assert_eq(int(net.planner.expansions_last_call), 0, "served from the cache")
	assert_almost_eq(float(tiny["minutes"]), before, 1e-9,
			"sub-quantum congestion noise cannot move an authoritative quote")
	# A change of one full quant step must move it, on the SAME path.
	net.congestion.set_congestion(edge_id, anchor + quantum * 4.0)
	var moved := net.planner.quote(a, b, prof)
	assert_eq(int(net.planner.expansions_last_call), 0, "still zero expansions")
	assert_eq(str(moved["edge_ids"]), edge_ids, "paths are more stable than prices")
	assert_true(float(moved["minutes"]) > before,
			"the price moved (%f -> %f)" % [before, float(moved["minutes"])])


func test_cache_invalidated_by_closure() -> void:
	var net := _lattice()
	var prof := RouteProfile.emergency(32.0, 0)
	var first := net.planner.quote(Vector2i(1, 1), Vector2i(35, 35), prof)
	assert_true(net.planner.cache_size() > 0)
	var edge_id := int((first["edge_ids"] as Array)[0])
	var tiles: Array = net.graph.edge(edge_id)["tiles"]
	var before := net.planner.cache_size()
	net.add_closure([tiles[0]], "accident_major", 0.9, 240)
	assert_true(net.planner.cache_size() < before,
			"a closure on a cached route drops the entry")
	net.planner.quote(Vector2i(1, 1), Vector2i(35, 35), prof)
	assert_true(net.planner.expansions_last_call > 0, "and forces a real re-route")


func test_live_route_invalidation_event() -> void:
	var net := _lattice()
	var prof := RouteProfile.emergency(32.0, 0)
	var ticket := net.planner.request_path(Vector2i(1, 1), Vector2i(35, 35), prof, 0, 7, 0)
	var result: Dictionary = {}
	for tick in 10:
		for r in net.planner.step(tick):
			if int(r["ticket_id"]) == ticket:
				result = r
	assert_true(bool(result.get("ok", false)), "the polyline resolved")
	net.drain_events()
	var tiles: Array = net.graph.edge(int((result["edge_ids"] as Array)[0]))["tiles"]
	net.add_closure([tiles[0]], "flood_deep", 1.0, 999999)
	var invalidated := false
	for event in net.drain_events():
		if event["type"] == &"route_invalidated":
			invalidated = true
			assert_eq(int(event["reason"]), RouteProfile.InvalidReason.CLOSURE)
			assert_true((event["ticket_ids"] as PackedInt32Array).has(ticket))
	assert_true(invalidated, "live route holders are told, explicitly and once")


# ----------------------------------------------- doc 06's TravelTimeProvider

func test_travel_time_provider_contract() -> void:
	var net := _lattice()
	var prof := RouteProfile.emergency(32.0, 0)
	var provider := net.travel_time_provider(prof)
	assert_true(provider is TravelTimeProvider, "it satisfies doc 06's interface type")
	var a := Vector2i(1, 1)
	var b := Vector2i(35, 35)
	var gs := provider.travel_gs(a, b)
	assert_true(gs > 0)
	assert_eq(gs, roundi(net.route_minutes(a, b, prof) * 60.0),
			"travel_gs is route_minutes x 60, rounded to whole game-seconds")
	assert_eq(net.travel_gs(a, b), net.travel_time_provider().travel_gs(a, b),
			"RoadNetwork itself satisfies the bare interface")
	# UNREACHABLE is -1, never a large finite number.
	var island := RoadsTestRig.network_with({Vector2i(60, 60): STREET})
	assert_eq(island.travel_gs(Vector2i(60, 60), Vector2i(90, 90)), -1)
	# The bare base class is doc 06's Chebyshev fallback (34 tiles × 8 m at
	# 24 m/gm = 680 gs) — doc 10's network provider replaces it, same type.
	var null_provider := TravelTimeProvider.new()
	assert_eq(null_provider.travel_gs(a, b), 680)


func test_estimate_then_quote_dispatch_pattern() -> void:
	# §2.14 worked example E: rank ~40 units with the O(1) estimate, then quote
	# only the top DISPATCH_CANDIDATES = 3.
	var net := _lattice()
	_randomise(net, 6161)
	var prof := RouteProfile.emergency(32.0, 0)
	var incident := Vector2i(35, 35)
	var ranked: Array = []
	for i in 40:
		var station := Vector2i(1 + (i % 9) * 4, 1 + (i / 9) * 4)
		ranked.append({"tile": station,
				"eta": net.estimate_eta_practical(station, incident, prof)})
	ranked.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["eta"]) < float(b["eta"]))
	assert_eq(ranked.size(), 40)
	var quotes := 0
	for i in net.tun.dispatch_candidates:
		var real := net.route_minutes(ranked[i]["tile"], incident, prof)
		quotes += 1
		assert_false(is_inf(real))
		assert_true(net.estimate_eta(ranked[i]["tile"], incident, prof) <= real + 1e-9,
				"estimate_eta never over-estimates, so doc 06 may prune with it")
	assert_eq(quotes, 3, "only the top 3 cost a real A* run")


func test_budget_exhaustion_returns_an_estimate_not_garbage() -> void:
	# §4 guarantee 5: route_minutes never blocks and never returns garbage.
	var net := _lattice()
	var prof := RouteProfile.emergency(32.0, 0)
	net.tun.max_expansions_per_route = 1
	net.tun.max_route_ticks = 1
	net.planner.invalidate_all()
	var minutes := net.route_minutes(Vector2i(1, 1), Vector2i(35, 35), prof)
	assert_true(net.planner.last_call_was_estimated, "flagged so doc 06 can re-quote")
	assert_false(is_inf(minutes), "still synchronous, still a number")
	var optimistic := net.estimate_eta(Vector2i(1, 1), Vector2i(35, 35), prof)
	assert_almost_eq(minutes, optimistic * net.tun.detour_factor, 1e-6,
			"the admissible estimate x DETOUR_FACTOR")
