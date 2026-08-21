class_name WaterDemandCache
extends RefCounted
## Doc 05 §2.4. Doc 02 owns the MAGNITUDE (`W_b`, already carrying
## `STATE_DEMAND[state]` and doc 07's `water_mult`); doc 01 owns the two
## diurnal CURVES; this class owns only the SPLIT — the per-archetype
## res/com/proc shares — and the three per-zone sums they feed.
##
## The sums are event-driven (build / upgrade / state change / destruction),
## never rebuilt per tick: `set_demand()` is a float compare when nothing moved.

var data: WaterData

var buildings: Dictionary = {}  # id -> {archetype, tile, w_b, res, com, proc, zone}
var zone_res: Dictionary = {}  # zone index -> float
var zone_com: Dictionary = {}
var zone_proc: Dictionary = {}
var zone_count: Dictionary = {}  # zone index -> building count

var _sorted_ids: Array = []  # cached iteration order (deterministic float sums)


func _init(p_data: WaterData) -> void:
	data = p_data


func attach_building(building_id: String, access_tile: Vector2i, archetype: String) -> void:
	var previous: Dictionary = buildings.get(building_id, {})
	if not previous.is_empty():
		# archetype / tile / level changed: back the old row out of the sums first.
		_apply(previous, -1.0)
	var split := data.split_for(archetype)
	var record := {
		"archetype": archetype, "tile": access_tile,
		"w_b": float(previous.get("w_b", 0.0)),
		"zone": int(previous.get("zone", -1)),
		"res": float(split["res"]), "com": float(split["com"]), "proc": float(split["proc"]),
	}
	buildings[building_id] = record
	_sorted_ids = []
	_apply(record, 1.0)


func detach_building(building_id: String) -> void:
	if not buildings.has(building_id):
		return
	_apply(buildings[building_id], -1.0)
	buildings.erase(building_id)
	_sorted_ids = []


## Doc 02 publishes `W_b` in m³/h. Only a CHANGED value touches the sums.
## `set_demands()` calls this once per building per tick, so the `{}` default —
## allocated before the lookup ran, on every call — was one empty Dictionary per
## building per tick. Same two outcomes: no row ⇒ nothing to set.
func set_demand(building_id: String, w_b: float) -> void:
	var found: Variant = buildings.get(building_id)
	if found == null:
		return
	var record: Dictionary = found
	if record.is_empty():
		return
	if is_equal_approx(float(record["w_b"]), w_b):
		return
	_apply(record, -1.0)
	record["w_b"] = w_b
	_apply(record, 1.0)


## Iteration order is fixed so the per-zone float sums are reproducible.
func sorted_ids() -> Array:
	if _sorted_ids.is_empty() and not buildings.is_empty():
		_sorted_ids = _sorted(buildings)
	return _sorted_ids


## Doc 02's whole published table, once per tick. Ids doc 02 publishes but
## water has never been told about are ignored — attach comes first.
func set_demands(demands: Dictionary) -> void:
	for building_id in sorted_ids():
		# One lookup instead of `has` plus an index, on every building on every
		# tick. `null` and "absent" are the same case here: doc 02 never
		# publishes a null demand.
		var value: Variant = demands.get(building_id)
		if value != null:
			set_demand(String(building_id), float(value))


func demand_of(building_id: String) -> float:
	return float(buildings.get(building_id, {}).get("w_b", 0.0))


func zone_of_building(building_id: String) -> int:
	return int(buildings.get(building_id, {}).get("zone", -1))


func access_tile(building_id: String) -> Vector2i:
	return buildings.get(building_id, {}).get("tile", Vector2i.ZERO)


## Topology changed: re-derive every building's zone and rebuild the sums.
func reassign(topology: WaterTopology) -> void:
	zone_res.clear()
	zone_com.clear()
	zone_proc.clear()
	zone_count.clear()
	for building_id in sorted_ids():
		var record: Dictionary = buildings[building_id]
		record["zone"] = topology.zone_at_tile(record["tile"])
		_apply(record, 1.0)
	for z: PressureZone in topology.zones:
		z.res_base = float(zone_res.get(z.index, 0.0))
		z.com_base = float(zone_com.get(z.index, 0.0))
		z.proc_base = float(zone_proc.get(z.index, 0.0))
		z.building_count = int(zone_count.get(z.index, 0))


## Push the live sums into the zone objects (called each tick — three float
## copies per zone, which is the O(zones) budget §2.4 asks for).
func publish(topology: WaterTopology) -> void:
	for z: PressureZone in topology.zones:
		z.res_base = float(zone_res.get(z.index, 0.0))
		z.com_base = float(zone_com.get(z.index, 0.0))
		z.proc_base = float(zone_proc.get(z.index, 0.0))
		z.building_count = int(zone_count.get(z.index, 0))


func _apply(record: Dictionary, sign_value: float) -> void:
	var zone_index := int(record.get("zone", -1))
	if zone_index < 0:
		return
	var w_b := float(record.get("w_b", 0.0))
	zone_res[zone_index] = float(zone_res.get(zone_index, 0.0)) \
			+ sign_value * w_b * float(record["res"])
	zone_com[zone_index] = float(zone_com.get(zone_index, 0.0)) \
			+ sign_value * w_b * float(record["com"])
	zone_proc[zone_index] = float(zone_proc.get(zone_index, 0.0)) \
			+ sign_value * w_b * float(record["proc"])
	zone_count[zone_index] = int(zone_count.get(zone_index, 0)) + int(signf(sign_value))


## **The three zone sums CARRY HISTORY, so they travel with the save** (report 98
## §26 RR-60 / doc 91 A91-D-30). They are maintained INCREMENTALLY — `set_demand`
## backs a building's old contribution out and adds the new one, once per changed
## building per utilities tick — while [reassign] rebuilds them with a single
## forward pass in `sorted_ids()` order. Both are correct and the two float
## histories are not the same float: after one game-day of a founding city they
## differ by 1 ULP on `com_base`, which is the seed the whole 24-hour
## save→load→advance divergence grew from.
##
## So a restore takes the numbers rather than re-deriving them, exactly as
## `RoadNetwork` takes its smoothed congestion rather than recomputing it. Keys
## are the zone index as a STRING, because a JSON round-trip stringifies every
## dictionary key and an int key would come back as one anyway.
func serialize() -> Dictionary:
	var out: Array = []
	for building_id in sorted_ids():
		var record: Dictionary = buildings[building_id]
		var tile: Vector2i = record["tile"]
		out.append({"id": building_id, "archetype": String(record["archetype"]),
				"tile": [tile.x, tile.y], "w_b": float(record["w_b"])})
	return {"buildings": out, "zone_sums": _serialize_zone_sums()}


func _serialize_zone_sums() -> Dictionary:
	var res: Dictionary = {}
	var com: Dictionary = {}
	var proc: Dictionary = {}
	var count: Dictionary = {}
	for zone_index in _sorted(zone_count):
		var key := str(zone_index)
		res[key] = float(zone_res.get(zone_index, 0.0))
		com[key] = float(zone_com.get(zone_index, 0.0))
		proc[key] = float(zone_proc.get(zone_index, 0.0))
		count[key] = int(zone_count[zone_index])
	return {"res": res, "com": com, "proc": proc, "count": count}


## Overwrite the sums [reassign] just rebuilt with the ones the live run held.
## Called by `WaterSystem.deserialize()` AFTER its `rebuild_zones()`, because that
## rebuild is what assigns each building its zone and it clears these on the way
## through. A body with no `zone_sums` — every save written before this shipped —
## keeps the rebuild's answer, which is what it has always restored to.
## Returns true when saved sums were adopted.
func adopt_zone_sums(state: Dictionary) -> bool:
	var saved: Dictionary = state.get("zone_sums", {})
	if saved.is_empty():
		return false
	var res: Dictionary = saved.get("res", {})
	var com: Dictionary = saved.get("com", {})
	var proc: Dictionary = saved.get("proc", {})
	var count: Dictionary = saved.get("count", {})
	zone_res.clear()
	zone_com.clear()
	zone_proc.clear()
	zone_count.clear()
	for key in _sorted(count):
		var zone_index := int(key)
		zone_res[zone_index] = float(res.get(key, 0.0))
		zone_com[zone_index] = float(com.get(key, 0.0))
		zone_proc[zone_index] = float(proc.get(key, 0.0))
		zone_count[zone_index] = int(count[key])
	return true


func deserialize(state: Dictionary) -> void:
	buildings.clear()
	zone_res.clear()
	zone_com.clear()
	zone_proc.clear()
	zone_count.clear()
	_sorted_ids = []
	for record in state.get("buildings", []):
		var tile_pair: Array = record["tile"]
		attach_building(String(record["id"]), Vector2i(int(tile_pair[0]), int(tile_pair[1])),
				String(record["archetype"]))
		buildings[String(record["id"])]["w_b"] = float(record.get("w_b", 0.0))


static func _sorted(dict: Dictionary) -> Array:
	var keys := dict.keys()
	keys.sort()
	return keys
