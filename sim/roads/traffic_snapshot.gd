class_name TrafficSnapshot
extends RefCounted
## Doc 10 §2.15 — the read-only view `game/` and `ui/` consume. Rebuilt every
## game-minute; never mutated by its readers, and holding one has no effect on
## the sim (constitution §3: outward via snapshots and events only).

var graph: RoadGraph
var tun: RoadTunables

var visible_edges: Array = []
var active_closures: Array = []
var graph_version: int = -1
var congestion_epoch: int = -1


func _init(p_graph: RoadGraph, p_tun: RoadTunables) -> void:
	graph = p_graph
	tun = p_tun


## §2.15 overlay bands: clear < .25 · light < .50 · heavy < .75 · severe < .90 ·
## gridlock ≥ .90. Colour + PATTERN, per spec §49 (dashed = closure, hatched =
## flooded, dotted = under construction) — never colour alone.
func rebuild(closures: Dictionary, congestion_epoch_value: int) -> void:
	visible_edges.clear()
	active_closures.clear()
	graph_version = graph.graph_version
	congestion_epoch = congestion_epoch_value
	for edge_id in graph.edge_ids_sorted():
		var record: Dictionary = graph.edge(edge_id)
		var congestion := float(record["congestion"])
		visible_edges.append({
			"edge_id": edge_id,
			"tiles": (record["tiles"] as Array).duplicate(),
			"road_class": int(record["road_class"]),
			"congestion": congestion,
			"band": RoadCosts.overlay_band(congestion),
			"closure_cause": String(record.get("closure_cause", "")),
			"condition": float(record["condition"]),
			"condition_tier": RoadCosts.condition_tier(float(record["condition"]),
					tun.tier_good, tun.tier_poor, tun.tier_failing),
			"blocked_mask": int(record.get("blocked_mask", 0)),
			"collapsed": bool(record.get("collapsed", false)),
			"speed_override": float(record.get("speed_override", 1.0)),
			"node_a_dark": _is_dark(int(record["node_a"])),
			"node_b_dark": _is_dark(int(record["node_b"])),
			"density": clampf(congestion / maxf(0.001, tun.congestion_index_max), 0.0, 1.0),
		})
	for closure_id in _sorted_keys(closures):
		var closure: Dictionary = closures[closure_id]
		active_closures.append({
			"id": int(closure["id"]),
			"edge_ids": (closure["edge_ids"] as Array).duplicate(),
			"cause": String(closure["cause"]),
			"severity": float(closure["severity"]),
		})


func edge_view(edge_id: int) -> Dictionary:
	for view in visible_edges:
		if int(view["edge_id"]) == edge_id:
			return view
	return {}


func _is_dark(node_id: int) -> bool:
	var record: Dictionary = graph.node(node_id)
	if record.is_empty():
		return false
	return bool(record["signalised"]) and not bool(record["powered"])


static func _sorted_keys(dict: Dictionary) -> Array:
	var keys := dict.keys()
	keys.sort()
	return keys
