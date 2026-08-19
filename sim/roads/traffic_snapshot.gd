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
	active_closures.clear()
	var same_graph := graph_version == graph.graph_version
	graph_version = graph.graph_version
	congestion_epoch = congestion_epoch_value
	var ids := graph.edge_ids_ref()
	# The view rows are REWRITTEN IN PLACE when the graph has not changed shape
	# since the last rebuild — which is every minute the player is not laying
	# road. Same rows, same order, same values; what is saved is 644 dictionary
	# allocations and 644 tile-array copies per game-minute, once a minute,
	# forever. When the graph HAS changed the rows are rebuilt from scratch.
	var reuse := same_graph and visible_edges.size() == ids.size()
	if not reuse:
		visible_edges.clear()
		visible_edges.resize(ids.size())
	var cap := maxf(0.001, tun.congestion_index_max)
	# Hoisted once instead of read per edge (2E node lookups became one node
	# sweep, three tunable reads became three).
	var dark_nodes := graph.dark_signal_node_ids()
	var tier_good := tun.tier_good
	var tier_poor := tun.tier_poor
	var tier_failing := tun.tier_failing
	var index := 0
	for edge_id in ids:
		var record: Dictionary = graph.edge_or_null(edge_id)
		var congestion := float(record["congestion"])
		var condition := float(record["condition"])
		var view: Dictionary
		if reuse:
			view = visible_edges[index]
		else:
			view = {"edge_id": edge_id, "tiles": (record["tiles"] as Array).duplicate()}
			visible_edges[index] = view
		view["road_class"] = int(record["road_class"])
		view["congestion"] = congestion
		view["band"] = RoadCosts.overlay_band(congestion)
		view["closure_cause"] = String(record.get("closure_cause", ""))
		view["condition"] = condition
		view["condition_tier"] = RoadCosts.condition_tier(condition,
				tier_good, tier_poor, tier_failing)
		view["blocked_mask"] = int(record.get("blocked_mask", 0))
		view["collapsed"] = bool(record.get("collapsed", false))
		view["speed_override"] = float(record.get("speed_override", 1.0))
		view["node_a_dark"] = dark_nodes.has(int(record["node_a"]))
		view["node_b_dark"] = dark_nodes.has(int(record["node_b"]))
		view["density"] = clampf(congestion / cap, 0.0, 1.0)
		index += 1
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


static func _sorted_keys(dict: Dictionary) -> Array:
	var keys := dict.keys()
	keys.sort()
	return keys
