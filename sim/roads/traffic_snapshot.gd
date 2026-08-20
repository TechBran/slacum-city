class_name TrafficSnapshot
extends RefCounted
## Doc 10 §2.15 — the read-only view `game/` and `ui/` consume. Rebuilt every
## game-minute; never mutated by its readers, and holding one has no effect on
## the sim (constitution §3: outward via snapshots and events only).
##
## This file also owns **the packed vehicle-pose wire format** (§ "the diet",
## below) — the one place producer and consumer agree on the layout, so a
## renderer reading a stride the feed does not write is a compile-time-adjacent
## mistake rather than a silent visual one.

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


# ---------------------------------------------------------------------------
# THE DIET (doc 91 D-10) — one packed `traffic_snapshot` event per sim tick
# ---------------------------------------------------------------------------
#
# WHAT CHANGED. Doc 10 §2.15 published one `vehicle_state` DICTIONARY per
# civilian vehicle per tick. At the Balanced cap that is 256 dictionaries of
# ten keys each, 4 times per game-second, forever — measured at **80% of all
# events on the bus** and the single largest allocator in a running city. Every
# consumer of the drained batch paid for them too: `ui/`, the notification
# router and the audio model each ran their "is this mine?" probe 256 times a
# tick to answer "no" 256 times.
#
# It is now ONE event carrying parallel packed columns. The information is
# identical — same vehicles, same order (ascending id, the feed's canonical
# iteration), same values — so this is a change of shape, not of content:
# `sim/` state is untouched, no RNG draw moves, and the save hash is unchanged
# by construction (the bus is not persisted; `SimEventBus` has no history).
#
# WHY PACKED ARRAYS and not an Array of small dicts. The bus JSON-ifies
# nothing — it stays in memory — so the only cost that matters is allocation
# and pointer chasing. Five `Packed*Array`s are five contiguous buffers written
# by index; an Array of 256 dicts is 256 heap objects with 256 hash tables.
#
# WHY float32. `pos` was already a `Vector3`, whose components are float32 in a
# single-precision build, so the position columns lose exactly nothing.
# `heading` and `speed` are render-only — nothing here is ever read back into
# the sim (§2.15: "zero simulation authority") — and float32 rounding is
# deterministic, so two runs of the same seed still produce byte-identical
# columns, which is the property doc 10 §2.15 actually promises.
#
# CADENCE IS UNCHANGED: one event per sim TICK, i.e. doc 11 §2.12's 4 Hz at 1×.
# The pose feed is what `VehicleMotion`'s Hermite blend interpolates between
# (Δt = 0.25 s); publishing once a game-MINUTE instead would be a 16× longer
# gap than the interpolator is authored for and would trip
# `interp_teleport_threshold_m` on any vehicle moving faster than 2.7 m/s.
# The saving here is the 256-to-1 collapse of the event COUNT, not a cadence cut.

## The event `type`. `vehicle_spawned` / `vehicle_despawned` stay individual —
## they are rare, they carry identity rather than motion, and the renderer needs
## to allocate and retire pooled records off them.
const VEHICLE_EVENT := &"traffic_snapshot"

## Payload keys. Named constants because two files index these buffers.
const KEY_COUNT := "count"
const KEY_IDS := "ids"
const KEY_EDGES := "edge_ids"
const KEY_KINDS := "kinds"
const KEY_FLAGS := "flags"
const KEY_POSE := "pose"

## `pose` is 4 floats per vehicle: world x, world z, heading (radians), speed
## (metres per game-minute). Y is not carried — every vehicle is on the ground
## plane and `game/` adds the road-surface height itself (doc 11 §2.12).
const POSE_STRIDE := 4
const POSE_X := 0
const POSE_Z := 1
const POSE_HEADING := 2
const POSE_SPEED := 3

## `kinds` is an index into this list, not a string: one byte instead of a
## heap-allocated `String` per vehicle per tick.
const KINDS: Array[String] = ["car", "van", "truck"]

## `flags` is a bitfield. Civilian vehicles never run a siren or a light bar,
## so those two states are not carried at all — the renderer sets them false.
const FLAG_HEADLIGHTS := 1 << 0
const FLAG_DARK := 1 << 1


static func kind_index(kind: String) -> int:
	var index := KINDS.find(kind)
	return index if index >= 0 else 0


static func kind_name(index: int) -> String:
	return KINDS[index] if index >= 0 and index < KINDS.size() else KINDS[0]


## Assemble the event from columns the producer has already sized and filled.
## Taking the buffers rather than building them keeps the one allocation-free
## path allocation-free: `TrafficFeed` resizes once per tick and writes by index.
static func make_vehicle_event(count: int, ids: PackedInt32Array,
		edge_ids: PackedInt32Array, kinds: PackedByteArray, flags: PackedByteArray,
		pose: PackedFloat32Array) -> Dictionary:
	return {
		"type": VEHICLE_EVENT,
		KEY_COUNT: count,
		KEY_IDS: ids,
		KEY_EDGES: edge_ids,
		KEY_KINDS: kinds,
		KEY_FLAGS: flags,
		KEY_POSE: pose,
	}


static func vehicle_count(event: Dictionary) -> int:
	return int(event.get(KEY_COUNT, 0))


## One row, unpacked into the shape `vehicle_spawned` uses. This is the
## READABLE accessor — for tests, for the event-log, for anything that touches a
## handful of rows. `VehicleView` deliberately does NOT use it: re-materialising
## the dictionary we just deleted, 256 times a tick, would undo the whole diet.
static func vehicle_at(event: Dictionary, index: int) -> Dictionary:
	var count := vehicle_count(event)
	if index < 0 or index >= count:
		return {}
	var pose: PackedFloat32Array = event[KEY_POSE]
	var base := index * POSE_STRIDE
	var bits := int((event[KEY_FLAGS] as PackedByteArray)[index])
	return {
		"id": int((event[KEY_IDS] as PackedInt32Array)[index]),
		"kind": kind_name(int((event[KEY_KINDS] as PackedByteArray)[index])),
		"vehicle_class": "civilian",
		"edge_id": int((event[KEY_EDGES] as PackedInt32Array)[index]),
		"pos": Vector3(pose[base + POSE_X], 0.0, pose[base + POSE_Z]),
		"heading": float(pose[base + POSE_HEADING]),
		"speed": float(pose[base + POSE_SPEED]),
		"headlights": (bits & FLAG_HEADLIGHTS) != 0,
		"dark": (bits & FLAG_DARK) != 0,
		"siren": false,
		"lightbar": false,
	}


func edge_view(edge_id: int) -> Dictionary:
	for view in visible_edges:
		if int(view["edge_id"]) == edge_id:
			return view
	return {}


static func _sorted_keys(dict: Dictionary) -> Array:
	var keys := dict.keys()
	keys.sort()
	return keys
