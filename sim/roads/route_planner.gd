class_name RoutePlanner
extends RefCounted
## Doc 10 §2.7 / §2.14 — A* on the contracted graph, the route cache, the
## request budget, and the authoritative `route_minutes`.
##
## THE CONTRACT (doc 06 §2.11, adopted as doc 06 specified it):
##   1. `route_minutes` IS the arrival time, online and offline.
##   2. Mode invariance — congestion is quantised to CONG_QUANT before costing,
##      so the value is a pure function of (graph_version, quantised congestion,
##      closure_epoch, profile) and is bit-identical in fine and coarse steps.
##   3. INF on unreachable — never a large finite number, so doc 06's min()
##      cannot silently pick an impossible unit.
##   4. Re-quoting is explicit: roads emits `route_invalidated`, doc 06 re-quotes.
##   5. On budget exhaustion `route_minutes` still returns synchronously, using
##      the admissible estimate × DETOUR_FACTOR, flagged by
##      `last_call_was_estimated`. It never blocks and never returns garbage.
##
## Determinism (constitution §5): the open set is a binary heap ordered by
## (f, h, node_id); neighbour iteration is by ascending edge_id; routing
## consumes NO RNG. Same graph + same congestion snapshot ⇒ identical path.

var graph: RoadGraph
var tun: RoadTunables
var congestion: CongestionModel

## Set each step by RoadNetwork from doc 07's global weather state (C-59).
var wx_slowdown: float = 0.0
## Bumped by RoadNetwork whenever a closure opens or clears.
var closure_epoch: int = 0
## Tests disable this to reproduce doc §2.6's worked examples at their exact,
## unquantised congestion values.
var quantise: bool = true

var last_call_was_estimated: bool = false
var expansions_last_call: int = 0
var expansions_this_tick: int = 0
var cache_hits: int = 0
var cache_misses: int = 0
var cache_reprices: int = 0

var _cache: Dictionary = {}  # key -> entry
var _cache_lru: Array[String] = []
var _edge_to_routes: Dictionary = {}  # edge_id -> Array[String]

## Per-query constant cache. `edge_cost_gm` is the hottest function in the sim:
## resolving the class and route-class rows through RoadTunables' dictionaries
## on every edge of every expansion cost more than the arithmetic did.
var _prep_prof: RouteProfile = null
var _prep_wx: float = -1.0
var _p_speed: float = 0.0
var _p_cong_relief: float = 0.0
var _p_node_relief: float = 0.0
var _p_wx_factor: float = 1.0
var _p_class_mult: Array[float] = []
var _p_s_cong: Array[float] = []

var _jobs: Dictionary = {}  # ticket -> job
var _queue: Array = []  # [effective_priority, submit_tick, ticket]
var _ready: Array = []  # finished PathResult dictionaries
var _live: Dictionary = {}  # ticket -> {requester_id, edge_ids}
var next_ticket: int = 1


func _init(p_graph: RoadGraph, p_tun: RoadTunables, p_congestion: CongestionModel) -> void:
	graph = p_graph
	tun = p_tun
	congestion = p_congestion


# ------------------------------------------------------------- cost function

func _prep(prof: RouteProfile) -> void:
	if _prep_prof == prof and _prep_wx == wx_slowdown:
		return
	_prep_prof = prof
	_prep_wx = wx_slowdown
	_p_speed = prof.speed_mpgm
	_p_cong_relief = tun.cong_relief(prof.route_class)
	_p_node_relief = tun.node_relief(prof.route_class)
	_p_wx_factor = RoadCosts.f_weather(wx_slowdown, tun.wx_resist(prof.route_class))
	_p_class_mult = []
	_p_s_cong = []
	for road_class in range(0, 4):
		_p_class_mult.append(tun.class_mult(road_class))
		_p_s_cong.append(tun.s_cong(road_class))


func edge_congestion(edge_id: int) -> float:
	var c := float(graph.edge(edge_id).get("congestion", 0.0))
	return RoadCosts.quantise_congestion(c, tun.cong_quant) if quantise else c


func _edge_congestion_of(record: Dictionary) -> float:
	var c := float(record.get("congestion", 0.0))
	return RoadCosts.quantise_congestion(c, tun.cong_quant) if quantise else c


## Doc 10 §2.6. Returns INF for a hard block, a COLLAPSED tile, or a class the
## closure excludes (unless `ignores_closures` admits the soft block at
## DESPERATE_BLOCK_MULT — hard blocks are never admitted).
func edge_cost_gm(edge_id: int, prof: RouteProfile) -> float:
	var record: Dictionary = graph.edge(edge_id)
	if record.is_empty():
		return INF
	if bool(record.get("collapsed", false)):
		return INF
	var f_clos := 1.0
	var cause := String(record.get("closure_cause", ""))
	if cause != "":
		var row := tun.cause_row(cause)
		if row.is_empty():
			return INF
		if bool(row.get("hard", false)):
			return INF
		var mults: Array = row["mult"]
		var mult := float(mults[prof.route_class])
		if mult < 0.0:
			# §2.7's second-chance pass: only the causes doc 10 names as SOFT
			# blocks may be admitted, and only at DESPERATE_BLOCK_MULT.
			if not prof.ignores_closures or not tun.soft_block_second_chance.has(cause):
				return INF
			f_clos = tun.desperate_block_mult
		else:
			f_clos = mult
	_prep(prof)
	var road_class := int(record["road_class"])
	var t0 := RoadCosts.free_flow_gm(float(record["length_m"]), _p_speed,
			_p_class_mult[road_class])
	var f_cong := RoadCosts.f_cong(_p_s_cong[road_class], _edge_congestion_of(record),
			_p_cong_relief)
	var f_cond := RoadCosts.f_cond(float(record["condition"]), tun.cond_penalty_max)
	var f_ovr := RoadCosts.f_override(float(record.get("speed_override", 1.0)),
			tun.speed_override_min)
	return t0 * f_cong * _p_wx_factor * f_cond * f_clos * f_ovr


## D_node for passing through `node_id` into `entering_edge_id`.
func node_delay_gm(node_id: int, entering_edge_id: int, prof: RouteProfile) -> float:
	var record: Dictionary = graph.node(node_id)
	if record.is_empty():
		return 0.0
	if not bool(record["signalised"]) and int(record["degree"]) < 3:
		return 0.0  # the overwhelmingly common case: no delay, no work
	_prep(prof)
	return RoadCosts.node_delay_gm(bool(record["signalised"]), bool(record["powered"]),
			int(record["degree"]), edge_congestion(entering_edge_id),
			_p_node_relief, tun.stop_delay_gm, tun.signal_delay_gm,
			tun.dark_signal_delay_gm, tun.powered_congestion_coeff, tun.dark_congestion_coeff)


func heuristic_gm(from_tile: Vector2i, goal_tile: Vector2i, prof: RouteProfile) -> float:
	return RoadCosts.estimate_eta_gm(from_tile, goal_tile, prof.speed_mpgm, tun.tile_m,
			tun.estimate_class_mult_max)


# -------------------------------------------------------------------- snapping

## {tile, node_id, edge_id, index} — or {} when nothing is within SNAP_RADIUS.
func snap(t: Vector2i) -> Dictionary:
	var road := graph.nearest_road_tile(t)
	if road.x < 0:
		return {}
	var node_id := graph.node_at(road)
	if node_id >= 0:
		return {"tile": road, "node_id": node_id, "edge_id": -1, "index": -1}
	var edge_id := graph.edge_at(road)
	if edge_id < 0:
		return {}
	return {"tile": road, "node_id": -1, "edge_id": edge_id,
			"index": graph.edge_tile_index(edge_id, road)}


static func _snap_key(s: Dictionary) -> String:
	var t: Vector2i = s["tile"]
	return "%d,%d" % [t.x, t.y]


# ------------------------------------------------------------------ the search

func find_path(from_tile: Vector2i, to_tile: Vector2i, prof: RouteProfile,
		opts: Dictionary = {}) -> Dictionary:
	var job := _make_job(from_tile, to_tile, prof, opts)
	if bool(job["done"]):
		return _finish(job)
	var budget := int(opts.get("max_expansions", tun.max_expansions_per_route * tun.max_route_ticks))
	_astar_run(job, budget)
	if not bool(job["done"]):
		job["fail"] = RouteProfile.RouteFail.BUDGET_EXCEEDED
		job["done"] = true
	return _finish(job)


func _make_job(from_tile: Vector2i, to_tile: Vector2i, prof: RouteProfile,
		opts: Dictionary) -> Dictionary:
	var epsilon: float = float(opts.get("epsilon",
			tun.epsilon_critical if prof.priority <= tun.critical_priority_max
			else tun.epsilon_routine))
	var job := {
		"from_tile": from_tile, "to_tile": to_tile, "prof": prof, "epsilon": epsilon,
		"expansions": 0, "best_total": INF, "best_node": -1,
		"done": false, "fail": RouteProfile.RouteFail.NONE,
		"g": {}, "came": {}, "heap": [], "targets": {}, "origin_nodes": {},
		"start": {}, "goal": {}, "direct": {},
		"requester_id": int(opts.get("requester_id", -1)),
		"ticket": int(opts.get("ticket", -1)),
	}
	var start := snap(from_tile)
	if start.is_empty():
		job["fail"] = RouteProfile.RouteFail.NO_ROAD_NEAR_ORIGIN
		job["done"] = true
		return job
	var goal := snap(to_tile)
	if goal.is_empty():
		job["fail"] = RouteProfile.RouteFail.NO_ROAD_NEAR_DEST
		job["done"] = true
		return job
	job["start"] = start
	job["goal"] = goal
	if start["tile"] == goal["tile"]:
		job["direct"] = {"minutes": 0.0, "tiles": [start["tile"]], "edge_ids": []}
		job["done"] = true
		return job
	# §2.7 same-edge special case: answered without any node expansion.
	if int(start["edge_id"]) >= 0 and int(start["edge_id"]) == int(goal["edge_id"]):
		var edge_id := int(start["edge_id"])
		var cost := edge_cost_gm(edge_id, prof)
		if not is_inf(cost):
			var tiles: Array = graph.edge(edge_id)["tiles"]
			var i := int(start["index"])
			var j := int(goal["index"])
			var span := float(absi(j - i)) / maxf(1.0, float(tiles.size() - 1))
			var slice: Array[Vector2i] = []
			var step := 1 if j >= i else -1
			var k := i
			while true:
				slice.append(tiles[k])
				if k == j:
					break
				k += step
			job["direct"] = {"minutes": cost * span, "tiles": slice, "edge_ids": [edge_id]}
			job["done"] = true
			return job
	# O(1) component pre-check (§2.9).
	var start_component := graph.component_of_tile(start["tile"])
	var goal_component := graph.component_of_tile(goal["tile"])
	if start_component >= 0 and goal_component >= 0 and start_component != goal_component:
		job["fail"] = RouteProfile.RouteFail.UNREACHABLE
		job["done"] = true
		return job

	var g: Dictionary = job["g"]
	var heap: Array = job["heap"]
	var goal_tile: Vector2i = goal["tile"]
	for seed in _endpoint_seeds(start, prof):
		var node_id := int(seed["node_id"])
		var cost := float(seed["g"])
		if is_inf(cost):
			continue
		if int(start["node_id"]) >= 0:
			job["origin_nodes"][node_id] = true
		if cost < float(g.get(node_id, INF)):
			g[node_id] = cost
			var h := heuristic_gm(graph.node(node_id)["tile"], goal_tile, prof)
			_heap_push(heap, [cost + epsilon * h, h, node_id, cost])
	for target in _endpoint_seeds(goal, prof):
		var node_id := int(target["node_id"])
		var extra := float(target["g"])
		if is_inf(extra):
			continue
		if int(goal["node_id"]) < 0:
			extra += node_delay_gm(node_id, int(goal["edge_id"]), prof)
		job["targets"][node_id] = extra
	if (job["heap"] as Array).is_empty() or (job["targets"] as Dictionary).is_empty():
		job["fail"] = RouteProfile.RouteFail.UNREACHABLE
		job["done"] = true
	return job


## Both endpoint nodes of a snapped edge, each with the partial cost from the
## snap index to that node. A snap that lands on a node tile seeds just it.
func _endpoint_seeds(s: Dictionary, prof: RouteProfile) -> Array:
	if int(s["node_id"]) >= 0:
		return [{"node_id": int(s["node_id"]), "g": 0.0}]
	var edge_id := int(s["edge_id"])
	var record: Dictionary = graph.edge(edge_id)
	if record.is_empty():
		return []
	var cost := edge_cost_gm(edge_id, prof)
	if is_inf(cost):
		return []
	var tiles: Array = record["tiles"]
	var span := maxf(1.0, float(tiles.size() - 1))
	var index := float(s["index"])
	var out: Array = []
	if int(record["node_a"]) >= 0:
		out.append({"node_id": int(record["node_a"]), "g": cost * index / span})
	if int(record["node_b"]) >= 0 and int(record["node_b"]) != int(record["node_a"]):
		out.append({"node_id": int(record["node_b"]), "g": cost * (span - index) / span})
	return out


## Runs the search for at most `budget` expansions. Suspension is free: the job
## holds the whole state, so the worst case is a latency cost, never a hitch.
func _astar_run(job: Dictionary, budget: int) -> int:
	var prof: RouteProfile = job["prof"]
	var epsilon: float = job["epsilon"]
	var goal_tile: Vector2i = (job["goal"] as Dictionary)["tile"]
	var g: Dictionary = job["g"]
	var came: Dictionary = job["came"]
	var heap: Array = job["heap"]
	var targets: Dictionary = job["targets"]
	var origin_nodes: Dictionary = job["origin_nodes"]
	var spent := 0
	while not heap.is_empty() and spent < budget:
		var item: Array = _heap_pop(heap)
		var node_id := int(item[2])
		var entry_g := float(item[3])
		if entry_g > float(g.get(node_id, INF)) + 1e-12:
			continue  # stale heap entry
		if float(job["best_total"]) <= float(item[0]):
			break  # the cheaper completed goal endpoint beats the open minimum
		spent += 1
		job["expansions"] = int(job["expansions"]) + 1
		if targets.has(node_id):
			var total := entry_g + float(targets[node_id])
			if total < float(job["best_total"]):
				job["best_total"] = total
				job["best_node"] = node_id
		var node_record: Dictionary = graph.node(node_id)
		if node_record.is_empty():
			continue
		for edge_id in node_record["edge_ids"]:
			var other := graph.other_node(edge_id, node_id)
			if other == node_id or other < 0 or graph.node(other).is_empty():
				continue  # self-loops carry no traffic anywhere new
			var cost := edge_cost_gm(edge_id, prof)
			if is_inf(cost):
				continue
			var delay := 0.0
			if not origin_nodes.has(node_id):
				delay = node_delay_gm(node_id, edge_id, prof)
			var candidate := entry_g + delay + cost
			if candidate < float(g.get(other, INF)) - 1e-12:
				g[other] = candidate
				came[other] = [node_id, edge_id]
				var h := heuristic_gm(graph.node(other)["tile"], goal_tile, prof)
				_heap_push(heap, [candidate + epsilon * h, h, other, candidate])
	if heap.is_empty() or float(job["best_total"]) <= _open_min(heap):
		job["done"] = true
		if int(job["best_node"]) < 0:
			job["fail"] = RouteProfile.RouteFail.UNREACHABLE
	return spent


static func _open_min(heap: Array) -> float:
	return INF if heap.is_empty() else float((heap[0] as Array)[0])


func _finish(job: Dictionary) -> Dictionary:
	expansions_last_call = int(job["expansions"])
	var prof: RouteProfile = job["prof"]
	var direct: Dictionary = job["direct"]
	if not direct.is_empty():
		return {
			"ok": true, "fail_reason": RouteProfile.RouteFail.NONE,
			"requester_id": int(job["requester_id"]), "ticket_id": int(job["ticket"]),
			"tiles": direct["tiles"], "edge_ids": direct["edge_ids"], "node_ids": [],
			"length_m": float((direct["tiles"] as Array).size() - 1) * tun.tile_m,
			"minutes": float(direct["minutes"]), "expansions": 0,
			"graph_version": graph.graph_version, "closure_epoch": closure_epoch,
			"congestion_epoch": congestion.epoch, "estimated": false,
			"start": job["start"], "goal": job["goal"], "route_class": prof.route_class,
		}
	if int(job["best_node"]) < 0:
		var reason: int = job["fail"] if int(job["fail"]) != RouteProfile.RouteFail.NONE \
				else RouteProfile.RouteFail.UNREACHABLE
		return {
			"ok": false, "fail_reason": reason, "requester_id": int(job["requester_id"]),
			"ticket_id": int(job["ticket"]), "tiles": [] as Array[Vector2i],
			"edge_ids": [] as Array[int], "node_ids": [] as Array[int],
			"length_m": 0.0, "minutes": INF, "expansions": int(job["expansions"]),
			"graph_version": graph.graph_version, "closure_epoch": closure_epoch,
			"congestion_epoch": congestion.epoch, "estimated": false,
			"start": job["start"], "goal": job["goal"], "route_class": prof.route_class,
		}
	var came: Dictionary = job["came"]
	var node_path: Array[int] = [int(job["best_node"])]
	var edge_path: Array[int] = []
	var cur := int(job["best_node"])
	var guard := 0
	while came.has(cur) and guard < 100000:
		var step: Array = came[cur]
		edge_path.insert(0, int(step[1]))
		node_path.insert(0, int(step[0]))
		cur = int(step[0])
		guard += 1
	var tiles := _assemble_tiles(job["start"], node_path, edge_path, job["goal"])
	return {
		"ok": true, "fail_reason": RouteProfile.RouteFail.NONE,
		"requester_id": int(job["requester_id"]), "ticket_id": int(job["ticket"]),
		"tiles": tiles, "edge_ids": edge_path, "node_ids": node_path,
		"length_m": float(tiles.size() - 1) * tun.tile_m,
		"minutes": float(job["best_total"]), "expansions": int(job["expansions"]),
		"graph_version": graph.graph_version, "closure_epoch": closure_epoch,
		"congestion_epoch": congestion.epoch, "estimated": false,
		"start": job["start"], "goal": job["goal"], "route_class": prof.route_class,
	}


func _assemble_tiles(start: Dictionary, node_path: Array, edge_path: Array,
		goal: Dictionary) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if node_path.is_empty():
		return out
	if int(start["node_id"]) < 0:
		out.append_array(_sub_polyline(int(start["edge_id"]), start["tile"],
				graph.node(int(node_path[0]))["tile"]))
	else:
		out.append(start["tile"])
	for i in edge_path.size():
		out.append_array(_oriented_tiles(int(edge_path[i]),
				graph.node(int(node_path[i]))["tile"]))
	if int(goal["node_id"]) < 0:
		out.append_array(_sub_polyline(int(goal["edge_id"]),
				graph.node(int(node_path[node_path.size() - 1]))["tile"], goal["tile"]))
	else:
		out.append(goal["tile"])
	var deduped: Array[Vector2i] = []
	for t in out:
		if deduped.is_empty() or deduped[deduped.size() - 1] != t:
			deduped.append(t)
	return deduped


func _oriented_tiles(edge_id: int, from_tile: Vector2i) -> Array[Vector2i]:
	var tiles: Array = graph.edge(edge_id).get("tiles", [])
	var out: Array[Vector2i] = []
	if tiles.is_empty():
		return out
	if tiles[0] == from_tile:
		for t in tiles:
			out.append(t)
	else:
		for i in range(tiles.size() - 1, -1, -1):
			out.append(tiles[i])
	return out


func _sub_polyline(edge_id: int, a: Vector2i, b: Vector2i) -> Array[Vector2i]:
	var tiles: Array = graph.edge(edge_id).get("tiles", [])
	var out: Array[Vector2i] = []
	var i := tiles.find(a)
	var j := tiles.find(b)
	if i < 0 or j < 0:
		return out
	var step := 1 if j >= i else -1
	var k := i
	while true:
		out.append(tiles[k])
		if k == j:
			break
		k += step
	return out


# --------------------------------------------------- authoritative quote + cache

## Doc 06's contract call. Returns INF if unreachable. THIS number is the
## arrival time, online and offline.
func route_minutes(a: Vector2i, b: Vector2i, prof: RouteProfile) -> float:
	last_call_was_estimated = false
	var result := quote(a, b, prof)
	return float(result["minutes"])


## The full quote behind `route_minutes` — cached, re-priced, budgeted.
func quote(a: Vector2i, b: Vector2i, prof: RouteProfile) -> Dictionary:
	var start := snap(a)
	var goal := snap(b)
	if start.is_empty() or goal.is_empty():
		last_call_was_estimated = false
		return {"ok": false, "minutes": INF, "edge_ids": [] as Array[int],
				"fail_reason": RouteProfile.RouteFail.NO_ROAD_NEAR_ORIGIN if start.is_empty()
				else RouteProfile.RouteFail.NO_ROAD_NEAR_DEST}
	var key := "%s>%s|%s|%d|%d" % [_snap_key(start), _snap_key(goal), prof.cache_key(),
			graph.graph_version, closure_epoch]
	if _cache.has(key) and not graph.graph_dirty:
		var entry: Dictionary = _cache[key]
		cache_hits += 1
		_touch(key)
		if int(entry["congestion_epoch"]) != congestion.epoch:
			entry["minutes"] = _price_route(entry, prof)
			entry["congestion_epoch"] = congestion.epoch
			cache_reprices += 1
		expansions_last_call = 0
		return entry
	cache_misses += 1
	var result := find_path(a, b, prof, {"max_expansions":
			tun.max_expansions_per_route * tun.max_route_ticks})
	if int(result["fail_reason"]) == RouteProfile.RouteFail.BUDGET_EXCEEDED:
		# Never block, never garbage: the admissible estimate × DETOUR_FACTOR.
		last_call_was_estimated = true
		result["minutes"] = RoadCosts.estimate_eta_gm(a, b, prof.speed_mpgm, tun.tile_m,
				tun.estimate_class_mult_max) * tun.detour_factor
		result["estimated"] = true
		return result
	if bool(result["ok"]):
		_store(key, result)
	return result


## Re-sum a cached route's price against the current congestion snapshot.
## Paths are far more stable than prices — this is the single most important
## optimisation in §2.14.
func _price_route(entry: Dictionary, prof: RouteProfile) -> float:
	var start: Dictionary = entry["start"]
	var goal: Dictionary = entry["goal"]
	var node_ids: Array = entry["node_ids"]
	var edge_ids: Array = entry["edge_ids"]
	if node_ids.is_empty():
		# Same-edge direct answer: re-price the sub-span.
		if edge_ids.is_empty():
			return 0.0
		var edge_id := int(edge_ids[0])
		var cost := edge_cost_gm(edge_id, prof)
		if is_inf(cost):
			return INF
		var tiles: Array = graph.edge(edge_id).get("tiles", [])
		var span := float((entry["tiles"] as Array).size() - 1) / maxf(1.0, float(tiles.size() - 1))
		return cost * span
	var total := 0.0
	var origin_is_node := int(start["node_id"]) >= 0
	if not origin_is_node:
		var seed_cost := edge_cost_gm(int(start["edge_id"]), prof)
		if is_inf(seed_cost):
			return INF
		var seed_tiles: Array = graph.edge(int(start["edge_id"]))["tiles"]
		var seed_span := maxf(1.0, float(seed_tiles.size() - 1))
		var first_tile: Vector2i = graph.node(int(node_ids[0]))["tile"]
		var distance := float(absi(seed_tiles.find(first_tile) - int(start["index"])))
		total += seed_cost * distance / seed_span
	for i in edge_ids.size():
		var cost := edge_cost_gm(int(edge_ids[i]), prof)
		if is_inf(cost):
			return INF
		if i > 0 or not origin_is_node:
			total += node_delay_gm(int(node_ids[i]), int(edge_ids[i]), prof)
		total += cost
	if int(goal["node_id"]) < 0:
		var tail_cost := edge_cost_gm(int(goal["edge_id"]), prof)
		if is_inf(tail_cost):
			return INF
		var tail_tiles: Array = graph.edge(int(goal["edge_id"]))["tiles"]
		var tail_span := maxf(1.0, float(tail_tiles.size() - 1))
		var last_tile: Vector2i = graph.node(int(node_ids[node_ids.size() - 1]))["tile"]
		var tail_distance := float(absi(tail_tiles.find(last_tile) - int(goal["index"])))
		total += node_delay_gm(int(node_ids[node_ids.size() - 1]), int(goal["edge_id"]), prof)
		total += tail_cost * tail_distance / tail_span
	return total


func _store(key: String, entry: Dictionary) -> void:
	_cache[key] = entry
	_touch(key)
	for edge_id in entry["edge_ids"]:
		var list: Array = _edge_to_routes.get(edge_id, [])
		if not list.has(key):
			list.append(key)
		_edge_to_routes[edge_id] = list
	while _cache_lru.size() > tun.route_cache_size:
		var evicted: String = _cache_lru.pop_front()
		_drop(evicted)


func _touch(key: String) -> void:
	_cache_lru.erase(key)
	_cache_lru.append(key)


func _drop(key: String) -> void:
	var entry: Dictionary = _cache.get(key, {})
	if entry.is_empty():
		return
	for edge_id in entry["edge_ids"]:
		var list: Array = _edge_to_routes.get(edge_id, [])
		list.erase(key)
		if list.is_empty():
			_edge_to_routes.erase(edge_id)
		else:
			_edge_to_routes[edge_id] = list
	_cache.erase(key)
	_cache_lru.erase(key)


## Structural changes and closures invalidate; congestion changes do NOT.
## Returns the live ticket ids whose route touched a changed edge, for the
## caller to publish as `route_invalidated`.
func invalidate_edges(edge_ids: Array) -> PackedInt32Array:
	var dropped: Dictionary = {}
	for edge_id in edge_ids:
		for key in (_edge_to_routes.get(edge_id, []) as Array).duplicate():
			dropped[key] = true
	for key in _sorted_keys(dropped):
		_drop(key)
	var tickets := PackedInt32Array()
	var changed: Dictionary = {}
	for edge_id in edge_ids:
		changed[edge_id] = true
	for ticket in _sorted_keys(_live):
		var record: Dictionary = _live[ticket]
		for edge_id in record["edge_ids"]:
			if changed.has(edge_id):
				tickets.append(int(ticket))
				break
	return tickets


func invalidate_all() -> void:
	_cache.clear()
	_cache_lru.clear()
	_edge_to_routes.clear()


func cache_size() -> int:
	return _cache.size()


# ---------------------------------------------------------------- O(1) estimates

func estimate_eta(a: Vector2i, b: Vector2i, prof: RouteProfile) -> float:
	return RoadCosts.estimate_eta_gm(a, b, prof.speed_mpgm, tun.tile_m,
			tun.estimate_class_mult_max)


func estimate_eta_practical(a: Vector2i, b: Vector2i, prof: RouteProfile,
		district_mean_congestion: float = 0.0) -> float:
	return RoadCosts.estimate_eta_practical_gm(estimate_eta(a, b, prof), tun.detour_factor,
			tun.practical_congestion_coeff, district_mean_congestion)


func is_reachable(a: Vector2i, b: Vector2i, _prof: RouteProfile) -> bool:
	var start := snap(a)
	var goal := snap(b)
	if start.is_empty() or goal.is_empty():
		return false
	var sc := graph.component_of_tile(start["tile"])
	var gc := graph.component_of_tile(goal["tile"])
	if sc < 0 or gc < 0:
		return true  # conservative while the labelling is incomplete
	return sc == gc


# ------------------------------------------------------- async polyline requests

## Render-only. The polyline never determines arrival time (§4 guarantee 1).
func request_path(from_tile: Vector2i, to_tile: Vector2i, prof: RouteProfile,
		priority: int = 2, requester_id: int = -1, submit_tick: int = 0) -> int:
	var ticket := next_ticket
	next_ticket += 1
	var job := _make_job(from_tile, to_tile, prof,
			{"requester_id": requester_id, "ticket": ticket})
	job["priority"] = priority
	job["submit_tick"] = submit_tick
	job["ticks"] = 0
	_jobs[ticket] = job
	_heap_push(_queue, [priority, submit_tick, ticket])
	return ticket


func cancel(ticket: int) -> void:
	_jobs.erase(ticket)
	_live.erase(ticket)


func pending_count() -> int:
	return _jobs.size()


## Drain the request queue within budget. Fine steps only — no vehicle needs a
## polyline offline; doc 06's offline dispatch uses route_minutes(), which is
## available in both modes.
func step(tick_index: int) -> Array:
	expansions_this_tick = 0
	var started := 0
	var overflow := 0
	var deferred: Array = []
	var results: Array = []
	while not _queue.is_empty():
		if expansions_this_tick >= tun.max_expansions_per_tick:
			break
		var item: Array = _heap_pop(_queue)
		var ticket := int(item[2])
		if not _jobs.has(ticket):
			continue
		var job: Dictionary = _jobs[ticket]
		var prof: RouteProfile = job["prof"]
		var is_urgent: bool = int(job["priority"]) <= tun.critical_priority_max
		if started >= tun.max_routes_per_tick:
			if not is_urgent or overflow >= tun.emergency_overflow:
				deferred.append(item)
				continue
			overflow += 1
		started += 1
		if not bool(job["done"]):
			var allowance := mini(tun.max_expansions_per_route,
					tun.max_expansions_per_tick - expansions_this_tick)
			expansions_this_tick += _astar_run(job, allowance)
		job["ticks"] = int(job["ticks"]) + 1
		if not bool(job["done"]) and int(job["ticks"]) >= tun.max_route_ticks:
			job["fail"] = RouteProfile.RouteFail.BUDGET_EXCEEDED
			job["done"] = true
		if bool(job["done"]):
			var result := _finish(job)
			result["ticket_id"] = ticket
			_jobs.erase(ticket)
			if bool(result["ok"]):
				_live[ticket] = {"requester_id": int(job["requester_id"]),
						"edge_ids": (result["edge_ids"] as Array).duplicate()}
			results.append(result)
		else:
			deferred.append([_effective_priority(job, tick_index), int(job["submit_tick"]), ticket])
	for item in deferred:
		_heap_push(_queue, item)
	# Starvation guard: a queued request gains one priority level per
	# PRIORITY_AGE_TICKS (§2.14).
	if not _queue.is_empty():
		var reheap: Array = []
		while not _queue.is_empty():
			var item: Array = _heap_pop(_queue)
			var ticket := int(item[2])
			if not _jobs.has(ticket):
				continue
			reheap.append([_effective_priority(_jobs[ticket], tick_index), int(item[1]), ticket])
		for item in reheap:
			_heap_push(_queue, item)
	return results


func _effective_priority(job: Dictionary, tick_index: int) -> int:
	var waited := maxi(0, tick_index - int(job["submit_tick"]))
	return maxi(0, int(job["priority"]) - waited / tun.priority_age_ticks)


func release_route(ticket: int) -> void:
	_live.erase(ticket)


func live_route_count() -> int:
	return _live.size()


# ------------------------------------------------------------------ min-heap

static func _heap_push(heap: Array, item: Array) -> void:
	heap.append(item)
	var i := heap.size() - 1
	while i > 0:
		var parent := (i - 1) / 2
		if not _less(heap[i], heap[parent]):
			break
		var swap: Variant = heap[parent]
		heap[parent] = heap[i]
		heap[i] = swap
		i = parent


static func _heap_pop(heap: Array) -> Array:
	var top: Array = heap[0]
	var last: Array = heap.pop_back()
	if not heap.is_empty():
		heap[0] = last
		var i := 0
		var count := heap.size()
		while true:
			var left := 2 * i + 1
			var right := left + 1
			var smallest := i
			if left < count and _less(heap[left], heap[smallest]):
				smallest = left
			if right < count and _less(heap[right], heap[smallest]):
				smallest = right
			if smallest == i:
				break
			var swap: Variant = heap[smallest]
			heap[smallest] = heap[i]
			heap[i] = swap
			i = smallest
	return top


## Lexicographic ordering — (f, h, node_id) for the search, (priority,
## submit_tick, ticket) for the queue. All ties break by ascending id.
static func _less(a: Array, b: Array) -> bool:
	var count := mini(a.size(), b.size())
	for i in count:
		if a[i] == b[i]:
			continue
		return a[i] < b[i]
	return a.size() < b.size()


static func _sorted_keys(dict: Dictionary) -> Array:
	var keys := dict.keys()
	keys.sort()
	return keys
