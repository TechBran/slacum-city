class_name TrafficFeed
extends RefCounted
## Doc 10 §2.15 — the cosmetic civilian traffic feed, published as the
## `vehicle_spawned` / `traffic_snapshot` / `vehicle_despawned` event stream
## doc 11 §5 consumes.
##
## `traffic_snapshot` replaced the per-vehicle `vehicle_state` event in the bus
## diet (doc 91 D-10): identity events stay individual, motion is one packed
## event per tick. `sim/roads/traffic_snapshot.gd` owns the wire format and
## explains the trade in full.
##
## ZERO SIMULATION AUTHORITY. Nothing here feeds congestion, incidents, economy
## or any query another system makes; deleting the whole class changes nothing
## except the picture. Densities are read FROM the congestion model, never
## written back (§2.10 "no feedback loop").
##
## Doc 10 §2.15 puts the ghost cars in `game/` on a renderer-local RNG. This
## build instead publishes a SIM-SIDE feed on the constitution's reserved
## `traffic` stream (report 98 C-45 keeps that stream reserved, not deleted), so
## the renderer receives a real, deterministic, capped feed instead of inventing
## one: two runs of the same seed produce a byte-identical event stream, which a
## renderer-local RNG could never promise. Because those draws come from a
## PERSISTED stream, the vehicles persist too: an empty post-load feed would
## re-draw a different number of times than the live run and the `traffic`
## stream state would diverge forever, breaking save→load→advance identity.

const KINDS: Array[String] = ["car", "van", "truck"]

var graph: RoadGraph
var tun: RoadTunables
var rng: RngStreams

var enabled: bool = true
var preset: String = "balanced"
var next_vehicle_id: int = 1
var headlights: bool = false

var _vehicles: Dictionary = {}  # vehicle id -> record
## edge_id -> Array[int] vehicle ids, **ASCENDING**, and the key set is mirrored
## by `_edge_keys` below. See [edges_with_vehicles] for why both halves of that
## sentence are a contract rather than a coincidence.
var _by_edge: Dictionary = {}
## The canonical iteration order of `_by_edge`: its keys, ascending, maintained
## by binary-search insert/remove rather than sorted on demand.
var _edge_keys := PackedInt32Array()
var _events: Array = []


func _init(p_graph: RoadGraph, p_tun: RoadTunables, p_rng: RngStreams) -> void:
	graph = p_graph
	tun = p_tun
	rng = p_rng


func vehicle_count() -> int:
	return _vehicles.size()


func vehicle(vehicle_id: int) -> Dictionary:
	return _vehicles.get(vehicle_id, {})


func vehicle_ids_sorted() -> Array:
	var ids := _vehicles.keys()
	ids.sort()
	return ids


## The edges that currently hold a vehicle, ASCENDING — the feed's per-edge index
## read in its one canonical order (doc 10's Wave-12 open q5).
##
## **This closes a fragility class rather than a bug.** `_by_edge` used to be
## insertion-ordered in both halves, and the two insertion histories a shipped
## city produces are DIFFERENT: a live feed appends a vehicle to an edge when it
## spawns there and again every time it hops onto it, so a per-edge list is in
## visit order and the key order is first-touch order; a feed rebuilt by
## [deserialize] appends in ascending vehicle id and its key order is first
## appearance in that walk. Nothing diverged, because the only consumer —
## [rebalance] — copied the list, sorted it, and iterated `_sorted_keys()`. That
## is a defence that has to be remembered by every future reader of the
## container, and the next one to forget it would have broken save→load→advance
## identity in a way that reproduces only after a hop.
##
## So the ORDER moved into the container: [_attach] and [_detach] keep every
## per-edge list ascending and keep this key vector ascending, and both are
## therefore identical live and restored. `tests/test_roads_traffic_order.gd`
## asserts exactly that, over the RAW containers, which is the assertion that
## would fail for a future consumer that iterates without sorting.
##
## Returns a SNAPSHOT: a caller may despawn while iterating it, which [rebalance]
## does on its very first pass.
func edges_with_vehicles() -> PackedInt32Array:
	return _edge_keys.duplicate()


## The vehicles on one edge, ASCENDING, as stored. Never a copy — treat it as
## read-only; [rebalance] duplicates it because it despawns while walking it.
func vehicles_on_edge(edge_id: int) -> Array:
	return _by_edge.get(edge_id, [])


func global_cap() -> int:
	return tun.civ_cap(preset)


func drain_events() -> Array:
	var out := _events
	_events = []
	return out


## Clear the whole feed (load, preset change, renderer teardown).
func reset(emit_despawns: bool = true) -> void:
	if emit_despawns:
		for vehicle_id in vehicle_ids_sorted():
			_emit(&"vehicle_despawned", {"id": vehicle_id, "reason": "reset"})
	_vehicles.clear()
	_by_edge.clear()
	_edge_keys.clear()


## Advance every live vehicle by `dt_game_minutes`. Called EVERY_TICK in fine
## mode only — offline catch-up runs no cosmetic traffic (§2.15).
func advance(dt_game_minutes: float, hour_of_day: float) -> void:
	if not enabled:
		return
	headlights = hour_of_day >= float(tun.civ_headlights_on_hour) \
			or hour_of_day < float(tun.civ_headlights_off_hour)
	for vehicle_id in vehicle_ids_sorted():
		var v: Dictionary = _vehicles[vehicle_id]
		if not graph.has_edge(int(v["edge_id"])):
			_despawn(vehicle_id, "graph")
			continue
		var record: Dictionary = graph.edge(int(v["edge_id"]))
		if _hard_blocked(record):
			_despawn(vehicle_id, "blocked")
			continue
		var speed := _speed_of(v, record)
		v["speed_mpgm"] = speed
		v["s_m"] = float(v["s_m"]) + speed * dt_game_minutes
		var guard := 0
		while float(v["s_m"]) >= float(record["length_m"]) and guard < 8:
			guard += 1
			v["s_m"] = float(v["s_m"]) - float(record["length_m"])
			v["hops_remaining"] = int(v["hops_remaining"]) - 1
			if int(v["hops_remaining"]) <= 0:
				_despawn(vehicle_id, "arrived")
				break
			if not _hop(v):
				_despawn(vehicle_id, "dead_end")
				break
			record = graph.edge(int(v["edge_id"]))
			if record.is_empty() or _hard_blocked(record):
				_despawn(vehicle_id, "blocked")
				break
		if _vehicles.has(vehicle_id):
			v["s_m"] = clampf(float(v["s_m"]), 0.0, maxf(0.0, float(record["length_m"])))


## Spawn / despawn to the per-edge targets. Called EVERY_MINUTE (§2.15's
## TrafficSnapshot cadence) so the population tracks congestion without
## thrashing at 4 Hz.
##
## DEVIATION FROM DOC 10 §2.15, deliberate: the doc rounds `n_e = round(0.9 · c ·
## L / 100)` PER EDGE, which assumes ~200 m edges. On the real contracted graph
## the starter core's mean edge is ~15 m, so every per-edge target rounds to
## zero and the city would show no traffic at any congestion level. The demand
## is therefore summed across the network FIRST — the constant still means "0.9
## cars per 100 m at capacity" — and allocated by largest remainder, which is
## deterministic and reproduces the doc's per-edge answer exactly whenever edges
## are long enough for it to be non-degenerate.
func rebalance() -> void:
	if not enabled:
		_shrink_to(0)
		return
	var targets := _allocate_targets()
	# 1. Trim edges that are over their target (lowest id first — which is
	# oldest, because ids are handed out in spawn order and never recycled).
	# The list is already ascending (`edges_with_vehicles`), so this copies to
	# survive despawning while walking it and no longer sorts.
	for edge_id in edges_with_vehicles():
		var target := int(targets.get(edge_id, 0))
		var ids: Array = vehicles_on_edge(edge_id).duplicate()
		var index := 0
		while ids.size() - index > target:
			_despawn(int(ids[index]), "density")
			index += 1
	# 2. Fill deficits. `_allocate_targets` writes its keys in ascending edge-id
	# order and the largest-remainder pass only ever bumps values on keys that
	# are already there, so the Dictionary's own order IS the sorted order.
	var cap := global_cap()
	for edge_id in targets.keys():
		var have: int = vehicles_on_edge(int(edge_id)).size()
		for i in maxi(0, int(targets[edge_id]) - have):
			if _vehicles.size() >= cap:
				return
			_spawn(int(edge_id))


## Largest-remainder allocation of the network-wide target across eligible
## edges. Ties break by ascending edge_id, so the result is reproducible.
func _allocate_targets() -> Dictionary:
	# The share table is packed columns too, and for the same reason as the
	# remainder table below: `edge_ids_ref()` is already ascending, so the
	# Dictionary this used to fill existed only to be `keys()`-ed and re-sorted
	# into the order it was written in. Same ids, same order, same shares.
	var share_ids := PackedInt32Array()
	var share_values := PackedFloat64Array()
	var total := 0.0
	var density_k := tun.civ_density_k
	for edge_id in graph.edge_ids_ref():
		var record: Dictionary = graph.edge_or_null(edge_id)
		if not _eligible(record):
			continue
		var share := density_k * float(record["congestion"]) \
				* float(record["length_m"]) / 100.0
		if share <= 0.0:
			continue
		share_ids.append(int(edge_id))
		share_values.append(share)
		total += share
	var wanted := clampi(roundi(total), 0, global_cap())
	var max_per_edge := tun.civ_max_cars_per_edge
	var out: Dictionary = {}
	var assigned := 0
	# Parallel packed columns rather than one small Dictionary per edge: this
	# runs every game-minute over every eligible edge, and the remainder table
	# was the single biggest allocator in the feed.
	var remainder_ids := PackedInt32Array()
	var remainder_fracs := PackedFloat64Array()
	for i in share_ids.size():
		var edge_id := share_ids[i]
		var share := share_values[i]
		var whole := clampi(int(share), 0, max_per_edge)
		out[edge_id] = whole
		assigned += whole
		remainder_ids.append(edge_id)
		remainder_fracs.append(share - float(int(share)))
	if assigned >= wanted:
		# The whole-number pass already met the target, so the largest-remainder
		# loop below cannot run — and the sort that only feeds it is dead work.
		return out
	# Sorting an index permutation with the comparator the row array used gives
	# the identical order: the sort sees the same comparison answers in the same
	# positions (which matters, because the 1e-9 tolerance below is not a strict
	# weak ordering and the algorithm's own path is part of the result).
	var order: Array[int] = []
	order.resize(remainder_ids.size())
	for i in remainder_ids.size():
		order[i] = i
	order.sort_custom(func(a: int, b: int) -> bool:
		if absf(remainder_fracs[a] - remainder_fracs[b]) > 1e-9:
			return remainder_fracs[a] > remainder_fracs[b]
		return remainder_ids[a] < remainder_ids[b])
	var pass_count := 0
	while assigned < wanted and pass_count < max_per_edge:
		var progressed := false
		for slot in order:
			if assigned >= wanted:
				break
			var edge_id := remainder_ids[slot]
			if int(out[edge_id]) >= max_per_edge:
				continue
			out[edge_id] = int(out[edge_id]) + 1
			assigned += 1
			progressed = true
		if not progressed:
			break
		pass_count += 1
	return out


## Publish this step's positions as ONE packed `traffic_snapshot` event (doc 91
## D-10, the bus diet). Doc 11 §2.12's Hermite interpolation needs explicit
## `speed` and `heading`, not derived ones (report 98 C-67), so both are still
## carried per vehicle — they moved into a column, they did not go away.
##
## The columns are written by index into buffers resized once, and the rows are
## in ascending vehicle id (`vehicle_ids_sorted`), which is the feed's canonical
## order everywhere else: same seed ⇒ same rows in the same slots.
##
## The old per-vehicle `vehicle_state` event is GONE, not deprecated. Keeping
## both would have doubled the cost of the thing the diet exists to halve, and
## the only consumer that ever read it is `game/render/vehicle_view.gd`, which
## moved with it. (`game/audio/` never read a civilian one: its door opens on
## `siren`, which is false for every vehicle in this feed, and its moving-siren
## path takes doc 06's fleet snapshot directly.)
func emit_states() -> void:
	if not enabled:
		return
	var ids_sorted := vehicle_ids_sorted()
	var count := ids_sorted.size()
	if count == 0:
		return
	var ids := PackedInt32Array()
	var edge_ids := PackedInt32Array()
	var kinds := PackedByteArray()
	var flags := PackedByteArray()
	var pose := PackedFloat32Array()
	ids.resize(count)
	edge_ids.resize(count)
	kinds.resize(count)
	flags.resize(count)
	pose.resize(count * TrafficSnapshot.POSE_STRIDE)
	var headlight_bit := TrafficSnapshot.FLAG_HEADLIGHTS if headlights else 0
	var index := 0
	for vehicle_id in ids_sorted:
		var v: Dictionary = _vehicles[vehicle_id]
		var p := _pose_of(v)
		var position: Vector3 = p["pos"]
		ids[index] = int(vehicle_id)
		edge_ids[index] = int(v["edge_id"])
		kinds[index] = TrafficSnapshot.kind_index(String(v["kind"]))
		flags[index] = headlight_bit \
				| (TrafficSnapshot.FLAG_DARK if bool(p["dark"]) else 0)
		var base := index * TrafficSnapshot.POSE_STRIDE
		pose[base + TrafficSnapshot.POSE_X] = position.x
		pose[base + TrafficSnapshot.POSE_Z] = position.z
		pose[base + TrafficSnapshot.POSE_HEADING] = float(p["heading"])
		pose[base + TrafficSnapshot.POSE_SPEED] = float(v["speed_mpgm"])
		index += 1
	# Straight onto the queue: `_emit` duplicates its payload (the right default
	# for a caller-owned literal), and these buffers are freshly built and handed
	# over wholesale, so a copy here would be 256 poses of pure waste.
	_events.append(TrafficSnapshot.make_vehicle_event(
			count, ids, edge_ids, kinds, flags, pose))


# ----------------------------------------------------------------- internals

func _eligible(record: Dictionary) -> bool:
	if record.is_empty():
		return false
	if float(record["length_m"]) <= 0.0:
		return false
	if float(record["condition"]) <= 0.0:
		return false
	if _hard_blocked(record):
		return false
	if String(record.get("closure_cause", "")) == "construction_new":
		return false
	return true


func _hard_blocked(record: Dictionary) -> bool:
	if bool(record.get("collapsed", false)):
		return true
	var cause := String(record.get("closure_cause", ""))
	if cause == "":
		return false
	return bool(tun.cause_row(cause).get("hard", false))


func _speed_of(v: Dictionary, record: Dictionary) -> float:
	var road_class := int(record["road_class"])
	var congestion := float(record["congestion"])
	var speed := tun.civ_base_speed_mpgm * tun.class_mult(road_class) \
			* (1.0 - tun.civ_speed_congestion_coeff * congestion) * float(v["jitter"])
	var tier := RoadCosts.condition_tier(float(record["condition"]), tun.tier_good,
			tun.tier_poor, tun.tier_failing)
	if tier == &"poor" or tier == &"failing":
		speed *= tun.poor_civilian_speed_mult
	# At gridlock (c = 2) cars crawl at 0.35× rather than stopping dead.
	return maxf(speed, tun.civ_base_speed_mpgm * 0.10)


func _spawn(edge_id: int) -> void:
	var record: Dictionary = graph.edge(edge_id)
	if record.is_empty():
		return
	var stream := rng.stream("traffic")
	var vehicle_id := next_vehicle_id
	next_vehicle_id += 1
	var from_a := stream.randi_range(0, 1) == 0
	var kind := KINDS[_weighted_kind(stream.randf())]
	var jitter := tun.civ_speed_jitter_min \
			+ (tun.civ_speed_jitter_max - tun.civ_speed_jitter_min) * stream.randf()
	var hops := stream.randi_range(tun.civ_trip_hops_min, tun.civ_trip_hops_max)
	var v := {
		"id": vehicle_id, "kind": kind, "edge_id": edge_id,
		"forward": from_a, "s_m": 0.0, "jitter": jitter,
		"hops_remaining": hops, "speed_mpgm": 0.0,
	}
	_vehicles[vehicle_id] = v
	_attach(edge_id, vehicle_id)
	v["speed_mpgm"] = _speed_of(v, record)
	var pose := _pose_of(v)
	_emit(&"vehicle_spawned", {
		"id": vehicle_id, "kind": kind, "vehicle_class": "civilian",
		"pos": pose["pos"], "heading": float(pose["heading"]),
		"speed": float(v["speed_mpgm"]), "edge_id": edge_id,
		"siren": false, "lightbar": false, "headlights": headlights,
	})


func _weighted_kind(u: float) -> int:
	var acc := 0.0
	for i in KINDS.size():
		acc += float(tun.civ_kind_weights.get(KINDS[i], 0.0))
		if u < acc:
			return i
	return 0


func _despawn(vehicle_id: int, reason: String) -> void:
	var v: Dictionary = _vehicles.get(vehicle_id, {})
	if v.is_empty():
		return
	_detach(int(v["edge_id"]), vehicle_id)
	_vehicles.erase(vehicle_id)
	_emit(&"vehicle_despawned", {"id": vehicle_id, "reason": reason})


func _shrink_to(count: int) -> void:
	var ids := vehicle_ids_sorted()
	var index := 0
	while _vehicles.size() > count and index < ids.size():
		_despawn(int(ids[index]), "cap")
		index += 1


## At a node a car picks a uniformly random outgoing edge excluding the one it
## arrived on; reversal is allowed only at dead ends (§2.15).
func _hop(v: Dictionary) -> bool:
	var edge_id := int(v["edge_id"])
	var record: Dictionary = graph.edge(edge_id)
	if record.is_empty():
		return false
	var arrival_node := int(record["node_b"]) if bool(v["forward"]) else int(record["node_a"])
	var node_record: Dictionary = graph.node(arrival_node)
	if node_record.is_empty():
		return false
	var options: Array = []
	for candidate in node_record["edge_ids"]:
		if int(candidate) == edge_id:
			continue
		var other: Dictionary = graph.edge(int(candidate))
		if _eligible(other):
			options.append(int(candidate))
	if options.is_empty():
		options.append(edge_id)  # dead end: reversal is the only legal move
	options.sort()
	var pick := int(options[rng.stream("traffic").randi_range(0, options.size() - 1)])
	var next_record: Dictionary = graph.edge(pick)
	_detach(edge_id, int(v["id"]))
	v["edge_id"] = pick
	v["forward"] = int(next_record["node_a"]) == arrival_node
	_attach(pick, int(v["id"]))
	return true


## World-space pose. 1 tile = 8 m (constitution §6); the tile centre is the
## lane reference, and `game/` adds the lane offset and the Y ground height.
func _pose_of(v: Dictionary) -> Dictionary:
	var record: Dictionary = graph.edge(int(v["edge_id"]))
	if record.is_empty():
		return {"pos": Vector3.ZERO, "heading": 0.0, "dark": false}
	var tiles: Array = record["tiles"]
	var count := tiles.size()
	var forward := bool(v["forward"])
	var s := float(v["s_m"])
	var segment := clampi(int(s / tun.tile_m), 0, maxi(0, count - 2))
	var frac := clampf((s - float(segment) * tun.tile_m) / tun.tile_m, 0.0, 1.0)
	var i0 := segment if forward else count - 1 - segment
	var i1 := clampi(i0 + (1 if forward else -1), 0, count - 1)
	var a := _tile_centre(tiles[i0])
	var b := _tile_centre(tiles[i1])
	var pos := a.lerp(b, frac)
	var heading := atan2(b.z - a.z, b.x - a.x)
	var dark := graph.dark_signal_endpoints(int(v["edge_id"])) > 0
	return {"pos": pos, "heading": heading, "dark": dark}


func _tile_centre(t: Vector2i) -> Vector3:
	return Vector3((float(t.x) + 0.5) * tun.tile_m, 0.0, (float(t.y) + 0.5) * tun.tile_m)


func _emit(event_type: StringName, payload: Dictionary) -> void:
	var event := payload.duplicate()
	event["type"] = event_type
	_events.append(event)


## Put `vehicle_id` on `edge_id`, keeping the per-edge list and the key vector
## ascending. Both inserts are binary-search placements into containers that are
## already sorted, so the whole index is order-canonical at every observation
## point rather than at the ones a consumer remembers to sort.
func _attach(edge_id: int, vehicle_id: int) -> void:
	var list: Array = _by_edge.get(edge_id, [])
	list.insert(list.bsearch(vehicle_id, true), vehicle_id)
	if list.size() == 1:
		# First vehicle on this edge: `_detach` erases an emptied key, so a
		# present key always has a non-empty list and this is the only new one.
		_edge_keys.insert(_edge_keys.bsearch(edge_id, true), edge_id)
	_by_edge[edge_id] = list


func _detach(edge_id: int, vehicle_id: int) -> void:
	var list: Array = _by_edge.get(edge_id, [])
	var at := list.bsearch(vehicle_id, true)
	if at >= list.size() or int(list[at]) != vehicle_id:
		return
	list.remove_at(at)
	if not list.is_empty():
		_by_edge[edge_id] = list
		return
	_by_edge.erase(edge_id)
	var key_at := _edge_keys.bsearch(edge_id, true)
	if key_at < _edge_keys.size() and _edge_keys[key_at] == edge_id:
		_edge_keys.remove_at(key_at)


## Save-identity support: the vehicle roster rides the roads save section so a
## loaded feed continues draw-for-draw where the live one was. Records are
## plain int/bool/float/String throughout; `_by_edge` is derived and rebuilt.
func serialize() -> Dictionary:
	var vehicles: Array = []
	for vehicle_id in vehicle_ids_sorted():
		vehicles.append((_vehicles[vehicle_id] as Dictionary).duplicate())
	return {
		"next_vehicle_id": next_vehicle_id,
		"enabled": enabled,
		"preset": preset,
		"headlights": headlights,
		"vehicles": vehicles,
	}


func deserialize(data: Dictionary) -> void:
	if data.is_empty():
		return
	next_vehicle_id = int(data.get("next_vehicle_id", 1))
	enabled = bool(data.get("enabled", true))
	preset = String(data.get("preset", "balanced"))
	headlights = bool(data.get("headlights", false))
	_vehicles.clear()
	_by_edge.clear()
	_edge_keys.clear()
	_events.clear()
	for entry in data.get("vehicles", []):
		var v: Dictionary = entry
		var vehicle_id := int(v["id"])
		_vehicles[vehicle_id] = {
			"id": vehicle_id, "kind": String(v["kind"]),
			"edge_id": int(v["edge_id"]), "forward": bool(v["forward"]),
			"s_m": float(v["s_m"]), "jitter": float(v["jitter"]),
			"hops_remaining": int(v["hops_remaining"]),
			"speed_mpgm": float(v["speed_mpgm"]),
		}
		_attach(int(v["edge_id"]), vehicle_id)
