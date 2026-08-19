class_name FloodField
extends RefCounted
## Localized flooding stub (doc 07 §2.4). Tiles are registered by the map owner
## (doc 09) with an `elevation_class ∈ {LOW, MID, HIGH}`; only registered tiles
## accumulate, so the flood field is exactly as coarse as doc 09's elevation
## data — which is still open (§9 item 8).
##
##   inflow_mm_h = precip_mm_h * runoff_concentration[class]
##   net_mm_h    = inflow_mm_h - drain_rate_mm_h * drain_bonus
##   depth_mm    = clamp(depth + net * dt_h, 0, max_depth)
##
## Depth is a float and persists as one — CitySim._encode_floats round-trips it
## bit-exactly, which the doc's `int_mm` would not (it would quantise every
## save and desync a mid-storm reload from the uninterrupted run).

var tables: WeatherTables
var depth_mm: Dictionary = {}  # "tx,tz" -> float
var drain_bonus: Dictionary = {}  # "tx,tz" -> float (sandbags, §2.7.7)

var _elevation: Dictionary = {}  # "tx,tz" -> "LOW" | "MID" | "HIGH"
var _closed: Dictionary = {}  # "tx,tz" -> true while the edge is removed
var _events: Array = []


func _init(p_tables: WeatherTables) -> void:
	tables = p_tables


## Constitution §6: a land block is 16×16 tiles, and doc 09 carries elevation
## per BLOCK. Registering per block keeps the 4 Hz integration at ~9 cells for
## the starter city instead of ~2 300 — the flood field is exactly as coarse as
## the elevation data behind it (§9 item 8), and per-tile registration is still
## available for when doc 09 goes finer.
const BLOCK_TILES := 16


static func key_of(tx: int, tz: int) -> String:
	return "%d,%d" % [tx, tz]


static func block_key_of(bx: int, bz: int) -> String:
	return "B%d,%d" % [bx, bz]


func register_tile(tx: int, tz: int, elevation_class: String) -> void:
	_elevation[key_of(tx, tz)] = elevation_class
	_elevation_order.clear()


func register_block(bx: int, bz: int, elevation_class: String) -> void:
	_elevation[block_key_of(bx, bz)] = elevation_class
	_elevation_order.clear()


## The registered cell keys in sorted order — the order `integrate` sweeps, and
## therefore load-bearing. DERIVED from `_elevation` and rebuilt the first time
## anyone asks after a registration; never persisted, so a loaded field simply
## rebuilds it. (`_elevation` is written only by the two registrars above.)
var _elevation_order: PackedStringArray = PackedStringArray()


func _elevation_keys_sorted() -> PackedStringArray:
	if _elevation_order.size() != _elevation.size():
		_elevation_order = PackedStringArray(_sorted_keys(_elevation))
	return _elevation_order


func registered_count() -> int:
	return _elevation.size()


## Tile registration wins; otherwise the tile inherits its land block's water.
func key_at(tx: int, tz: int) -> String:
	var tile_key := key_of(tx, tz)
	if _elevation.has(tile_key) or depth_mm.has(tile_key):
		return tile_key
	return block_key_of(
			int(floorf(float(tx) / float(BLOCK_TILES))),
			int(floorf(float(tz) / float(BLOCK_TILES))))


func set_drain_bonus(tx: int, tz: int, bonus: float) -> void:
	drain_bonus[key_at(tx, tz)] = bonus


## The sandbag prep action (§2.7.7) buys drainage for a whole land block.
func set_block_drain_bonus(bx: int, bz: int, bonus: float) -> void:
	drain_bonus[block_key_of(bx, bz)] = bonus


## Integrate one step. `dt_hours` is game-hours; `precip_mm_h` is §2.2's
## published rate. Emits flood_level_changed / road_closed_flood /
## road_reopened as bands are crossed.
func integrate(dt_hours: float, precip_mm_h: float) -> void:
	var runoff: Dictionary = tables.flood.get("runoff_concentration", {})
	var drain_rate := float(tables.flood.get("drain_rate_mm_h", 40.0))
	var max_depth := float(tables.flood.get("max_depth_mm", 900))
	# A dry city with no rain falling is the overwhelmingly common tick. Walk
	# the loop below for it and EVERY cell takes the same path: before = 0,
	# inflow = 0, `net` is drainage only (≤ 0, which is what the drain-rate test
	# pins down), `after` clamps back to 0, the erase is a no-op and the two
	# band indices match — so it `continue`s before it can touch anything. This
	# guard is that outcome, without the sweep.
	if precip_mm_h <= 0.0 and drain_rate >= 0.0 and depth_mm.is_empty():
		return
	for key in _elevation_keys_sorted():
		var elevation := String(_elevation[key])
		var before := float(depth_mm.get(key, 0.0))
		var inflow := precip_mm_h * float(runoff.get(elevation, 1.0))
		var net := inflow - drain_rate * float(drain_bonus.get(key, 1.0))
		var after := clampf(before + net * dt_hours, 0.0, max_depth)
		if after <= 0.0:
			depth_mm.erase(key)
		else:
			depth_mm[key] = after
		var band_before := band_index(before)
		var band_after := band_index(after)
		if band_before == band_after:
			continue
		_emit(&"flood_level_changed", {"cell": key, "is_block": key.begins_with("B"),
				"depth_mm": after,
				"band": String(_band(band_after).get("label", "dry")),
				"road_speed_mult": float(_band(band_after).get("road_speed_mult", 1.0))})
		var closed_before := bool(_closed.get(key, false))
		var closed_after := bool(_band(band_after).get("remove_edge", false))
		if closed_after and not closed_before:
			_closed[key] = true
			_emit(&"road_closed_flood", {"cell": key, "is_block": key.begins_with("B"),
					"depth_mm": after})
		elif closed_before and not closed_after:
			_closed.erase(key)
			_emit(&"road_reopened", {"cell": key, "is_block": key.begins_with("B"),
					"depth_mm": after})


func depth_at(tx: int, tz: int) -> float:
	return float(depth_mm.get(key_at(tx, tz), 0.0))


func band_index(depth: float) -> int:
	var thresholds: Array = tables.flood.get("thresholds", [])
	var index := 0
	for i in thresholds.size():
		if depth >= float(thresholds[i].get("depth_mm", 0)):
			index = i
	return index


func _band(index: int) -> Dictionary:
	var thresholds: Array = tables.flood.get("thresholds", [])
	return thresholds[clampi(index, 0, thresholds.size() - 1)] if not thresholds.is_empty() else {}


## Per-tile flood speed multiplier. Multiplies with the city-wide
## `road_speed_mult` — a flooded tile in a thunderstorm is effectively a wall.
func road_speed_mult_at(tx: int, tz: int) -> float:
	return float(_band(band_index(depth_at(tx, tz))).get("road_speed_mult", 1.0))


func band_label_at(tx: int, tz: int) -> String:
	return String(_band(band_index(depth_at(tx, tz))).get("label", "dry"))


func is_edge_removed(tx: int, tz: int) -> bool:
	return bool(_band(band_index(depth_at(tx, tz))).get("remove_edge", false))


## 0 = dry, 1 = impassable. Doc 10 consumes this as its ground-condition term.
func flood_saturation(tx: int, tz: int) -> float:
	return clampf(depth_at(tx, tz) / 350.0, 0.0, 1.0)


## Area-weighted mean saturation over LOW tiles (§2.4).
func flood_saturation_city() -> float:
	var total := 0.0
	var count := 0
	for key in _sorted_keys(_elevation):
		if String(_elevation[key]) != "LOW":
			continue
		count += 1
		total += clampf(float(depth_mm.get(key, 0.0)) / 350.0, 0.0, 1.0)
	return total / float(count) if count > 0 else 0.0


func closed_tiles() -> Array:
	return _sorted_keys(_closed)


func drain_events() -> Array:
	var out := _events
	_events = []
	return out


func serialize() -> Dictionary:
	var tiles := {}
	for key in _sorted_keys(depth_mm):
		tiles[key] = float(depth_mm[key])
	var bonuses := {}
	for key in _sorted_keys(drain_bonus):
		bonuses[key] = float(drain_bonus[key])
	return {"tiles": tiles, "closed": _sorted_keys(_closed), "drain_bonus": bonuses}


func deserialize(data: Dictionary) -> void:
	depth_mm.clear()
	for key in data.get("tiles", {}):
		depth_mm[String(key)] = float(data["tiles"][key])
	drain_bonus.clear()
	for key in data.get("drain_bonus", {}):
		drain_bonus[String(key)] = float(data["drain_bonus"][key])
	_closed.clear()
	for key in data.get("closed", []):
		_closed[String(key)] = true


func _emit(event_type: StringName, payload: Dictionary) -> void:
	var event := payload.duplicate()
	event["type"] = event_type
	_events.append(event)


static func _sorted_keys(dict: Dictionary) -> Array:
	var keys := dict.keys()
	keys.sort()
	return keys
