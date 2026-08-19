class_name CongestionModel
extends RefCounted
## Doc 10 §2.10 — one scalar per edge, `congestion_index c_e ∈ [0,2]` with
## `1.0 = at capacity` (doc 06's scale, adopted verbatim so f_flow,
## traffic_accident generation and congestion_ref = 1.5 need no conversion).
##
##   c_raw(e) = clamp(K_base · D_tod · L_dens · E_evt + I_inc + wx_cong_add, 0, 2)
##   c_e ← c_e + (c_raw − c_e) · smooth(dt),  smooth = 1 − (1 − 0.35)^dt_gm
##
## NO civilian vehicles are simulated and there is NO feedback loop: congestion
## is a forward function of city state and time, which is what makes it stable,
## cheap, and reproducible offline (§2.10).
##
## The authoritative value lives on the edge record (`edge["congestion"]`) so
## the planner reads one structure; this class owns writing it.

var tun: RoadTunables
var graph: RoadGraph
## Bumped whenever any c_e moves; the route cache re-prices (never re-paths) on
## a stale epoch (§2.14).
var epoch: int = 0


func _init(p_graph: RoadGraph, p_tun: RoadTunables) -> void:
	graph = p_graph
	tun = p_tun


## §2.10 `D_tod(e,t)`: four land-use curves, 24 hourly samples, linear interp.
## `hour` comes from doc 01's frozen TimeContext — roads never samples a clock.
func d_tod(weights: Dictionary, hour: float) -> float:
	var wrapped := fposmod(hour, 24.0)
	var h := int(floor(wrapped))
	var frac := wrapped - float(h)
	var next := (h + 1) % 24
	var total := 0.0
	for profile in ["civ", "com", "ind", "res"]:
		var weight := float(weights.get(profile, 0.0))
		if weight == 0.0:
			continue
		var curve: Array = tun.tod_curves.get(profile, [])
		if curve.size() != 24:
			continue
		total += weight * lerp(float(curve[h]), float(curve[next]), frac)
	return total


## §2.10 `L_dens(e) = clamp(0.20 + DENS_K · pj(e), 0.20, 1.60)`.
## `pj_by_edge` is Σ(population + jobs) of buildings whose access tile is within
## DENS_RADIUS_TILES of any tile of the edge. Refreshed once per game-day.
func refresh_density(pj_by_edge: Dictionary) -> void:
	for edge_id in graph.edge_ids_sorted():
		var record: Dictionary = graph.edge(edge_id)
		var pj := float(pj_by_edge.get(edge_id, 0.0))
		record["dens_index"] = clampf(tun.dens_min + tun.dens_k * pj, tun.dens_min, tun.dens_max)


func density_of(edge_id: int) -> float:
	return float(graph.edge(edge_id).get("dens_index", tun.dens_min))


## The unsmoothed forward function. `inputs` carries:
##   hour: float · wx_cong_add: float · i_inc: {edge_id: float}
##   weights: {district_id: {res,com,ind,civ}} · evt: {edge_id: float}
func c_raw(edge_id: int, inputs: Dictionary) -> float:
	var record: Dictionary = graph.edge(edge_id)
	if record.is_empty():
		return 0.0
	var weights_by_district: Dictionary = inputs.get("weights", {})
	var district := String(record.get("district_id", ""))
	var weights: Dictionary = weights_by_district.get(district, tun.default_profile_weights)
	var demand := d_tod(weights, float(inputs.get("hour", 12.0)))
	var evt := float((inputs.get("evt", {}) as Dictionary).get(edge_id, 1.0))
	var base := tun.k_base(int(record["road_class"])) * demand \
			* float(record.get("dens_index", tun.dens_min)) * evt
	var additive := float((inputs.get("i_inc", {}) as Dictionary).get(edge_id, 0.0)) \
			+ float(inputs.get("wx_cong_add", 0.0))
	return clampf(base + additive, 0.0, tun.congestion_index_max)


## §2.10 `I_inc(e)`: own closure + 0.50 × 1 hop + 0.25 × 2 hops + the dark-signal
## additive (report 98 G-6). Computed by BFS outward from each closure — never
## by scanning every edge — because closures are few (cap 128).
## `closure_cause_by_edge` is {edge_id: cause_name}.
func compute_i_inc(closure_cause_by_edge: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	var closed_ids: Array = closure_cause_by_edge.keys()
	closed_ids.sort()
	for edge_id in closed_ids:
		var cause := String(closure_cause_by_edge[edge_id])
		var add := float(tun.cause_row(cause).get("cong_add", 0.0))
		if add == 0.0:
			continue
		out[edge_id] = float(out.get(edge_id, 0.0)) + add
		var neighbours := graph.edges_within_hops(edge_id, 2)
		var neighbour_ids := neighbours.keys()
		neighbour_ids.sort()
		for other in neighbour_ids:
			var hop := int(neighbours[other])
			var scale := tun.spillback_hop1 if hop == 1 else tun.spillback_hop2
			out[other] = float(out.get(other, 0.0)) + add * scale
	# Dark signalised endpoints add congestion on top of their delay (G-6).
	for edge_id in graph.edge_ids_sorted():
		var dark := graph.dark_signal_endpoints(edge_id)
		if dark > 0:
			out[edge_id] = float(out.get(edge_id, 0.0)) + tun.dark_signal_add * float(dark)
	return out


## Smoothed update over a set of edges. `dt_game_minutes` makes coarse offline
## steps agree with fine online steps: one 1-game-hour coarse step applies
## 1 − 0.65^60 ≈ 1.0, landing exactly on c_raw — where 60 fine steps converge.
## Returns the number of edges whose value moved.
func recompute(edge_ids: Array, inputs: Dictionary) -> int:
	var dt_gm := float(inputs.get("dt_game_minutes", 0.25))
	var bypass := bool(inputs.get("bypass_smoothing", false))
	var alpha := 1.0 if bypass else RoadCosts.smoothing_alpha(tun.smooth_per_game_minute, dt_gm)
	var moved := 0
	var sorted_ids: Array = edge_ids.duplicate()
	sorted_ids.sort()
	for edge_id in sorted_ids:
		var record: Dictionary = graph.edge(edge_id)
		if record.is_empty():
			continue
		var target := c_raw(edge_id, inputs)
		var current := float(record["congestion"])
		var updated := current + (target - current) * alpha
		if absf(updated - current) > 1e-9:
			moved += 1
		record["congestion"] = clampf(updated, 0.0, tun.congestion_index_max)
	if moved > 0:
		epoch += 1
	return moved


func congestion_of(edge_id: int) -> float:
	return float(graph.edge(edge_id).get("congestion", 0.0))


func set_congestion(edge_id: int, value: float) -> void:
	var record: Dictionary = graph.edge(edge_id)
	if not record.is_empty():
		record["congestion"] = clampf(value, 0.0, tun.congestion_index_max)
		epoch += 1


func mean_congestion(edge_ids: Array = []) -> float:
	var ids: Array = edge_ids if not edge_ids.is_empty() else graph.edge_ids_sorted()
	if ids.is_empty():
		return 0.0
	var total := 0.0
	for edge_id in ids:
		total += congestion_of(edge_id)
	return total / float(ids.size())
