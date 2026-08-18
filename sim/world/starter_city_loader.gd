class_name StarterCityLoader
extends RefCounted
## Parses `data/starter_city.json` into a `WorldMap` + `TileGrid` (doc 09 §4).
## Pure data in, pure state out: `load_from()` takes an already-parsed
## Dictionary so the sim never has to touch the filesystem. `read_json()` is a
## convenience for the app shell and the headless tests only (same precedent as
## `sim/persistence/save_manager.gd`).
##
## All tile coordinates in the file are core-local; global = core-local + 32
## (doc 09 §3.1). This class resolves them once, at load, and everything
## downstream works in global tiles.

const CORE_TILE_OFFSET: int = 32
const CORE_TILES: int = 48

var schema_version: int = 0
var world: WorldMap = null
var world_header: Dictionary = {}
var buildings: Array[Dictionary] = []  # authored record + "origin_global", "grid_id"
var districts: Array = []
var power: Dictionary = {}
var water: Dictionary = {}
var tags: Dictionary = {}
var population: Dictionary = {}
var road_entries: Array = []
var water_tiles: Array = []  # core-local [x, z] pairs, as authored
var errors: PackedStringArray = []

var _buildings_by_id: Dictionary = {}
var _power_nodes_by_id: Dictionary = {}


## Reads and parses a JSON file. Returns {} and pushes an error on failure.
static func read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var text := FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	return parsed


static func core_to_global(x: int, z: int) -> Vector2i:
	return Vector2i(x + CORE_TILE_OFFSET, z + CORE_TILE_OFFSET)


func load_from(data: Dictionary) -> bool:
	errors.clear()
	buildings.clear()
	_buildings_by_id.clear()
	_power_nodes_by_id.clear()
	world = WorldMap.new()
	schema_version = int(data.get("schema_version", 0))
	world_header = data.get("world", {})
	population = data.get("population", {})
	districts = data.get("districts", [])
	power = data.get("power", {})
	water = data.get("water", {})
	tags = data.get("tags", {})
	road_entries = data.get("roads", [])
	water_tiles = data.get("water_tiles", [])

	_load_blocks(data.get("blocks", []))
	_mark_developed_ground()
	_stamp_roads()
	_stamp_water()
	_stamp_buildings(data.get("buildings", []))
	_index_power_nodes()
	return errors.is_empty()


func _load_blocks(rows: Array) -> void:
	if rows.size() != TileGrid.BLOCKS * TileGrid.BLOCKS:
		errors.append("expected %d blocks, got %d" % [TileGrid.BLOCKS * TileGrid.BLOCKS, rows.size()])
	for row in rows:
		var block := LandBlock.from_dict(row)
		if world.block(block.id) != null:
			errors.append("duplicate block id %s" % block.id)
			continue
		world.add_block(block)


## Every OWNED/READY block is developed ground: its tiles start BUILDABLE and
## the road/water stamps carve out of that (doc 09 §2.2).
func _mark_developed_ground() -> void:
	for id in world.block_ids_sorted():
		var block: LandBlock = world.block(id)
		if not block.is_ready():
			continue
		var origin := block.grid * TileGrid.TILES_PER_BLOCK
		for z in range(origin.y, origin.y + TileGrid.TILES_PER_BLOCK):
			for x in range(origin.x, origin.x + TileGrid.TILES_PER_BLOCK):
				world.grid.set_flag(x, z, TileGrid.FLAG_BUILDABLE)


func _stamp_roads() -> void:
	for entry in road_entries:
		var axis := String(entry.get("axis", ""))
		var index := int(entry.get("index", -1))
		var road_class := TileGrid.ROAD_AVENUE if String(entry.get("class", "")) == "AVENUE" \
				else TileGrid.ROAD_STREET
		if axis != "x" and axis != "z":
			errors.append("road entry with bad axis %s" % axis)
			continue
		for t in range(int(entry.get("from", 0)), int(entry.get("to", 0)) + 1):
			var local := Vector2i(index, t) if axis == "x" else Vector2i(t, index)
			var tile := core_to_global(local.x, local.y)
			# AVENUE wins where the two classes cross (doc 09 §2.9.1).
			if world.grid.road_class_at(tile.x, tile.y) == TileGrid.ROAD_AVENUE:
				continue
			world.grid.set_road(tile.x, tile.y, road_class)


func _stamp_water() -> void:
	for pair in water_tiles:
		var tile := core_to_global(int(pair[0]), int(pair[1]))
		world.grid.set_flag(tile.x, tile.y, TileGrid.FLAG_WATER)
		world.grid.clear_flag(tile.x, tile.y, TileGrid.FLAG_BUILDABLE)


func _stamp_buildings(rows: Array) -> void:
	var next_id := 1
	for row in rows:
		var record: Dictionary = row.duplicate(true)
		var origin_local := Vector2i(int(record["origin"][0]), int(record["origin"][1]))
		var size := Vector2i(int(record["size"][0]), int(record["size"][1]))
		var origin := core_to_global(origin_local.x, origin_local.y)
		record["origin_local"] = origin_local
		record["origin_global"] = origin
		record["footprint"] = size
		record["grid_id"] = next_id
		if not world.grid.stamp_building(next_id, origin, size):
			errors.append("building %s could not be stamped at %s" % [record.get("id", "?"), origin])
		buildings.append(record)
		_buildings_by_id[String(record.get("id", ""))] = record
		next_id += 1


func _index_power_nodes() -> void:
	for node in power.get("nodes", []):
		_power_nodes_by_id[String(node.get("id", ""))] = node


# --- queries ---------------------------------------------------------------

func building(building_id: String) -> Dictionary:
	return _buildings_by_id.get(building_id, {})


func buildings_of_type(type_name: String) -> Array:
	var out: Array = []
	for record in buildings:
		if String(record.get("type", "")) == type_name:
			out.append(record)
	return out


func power_node(node_id: String) -> Dictionary:
	return _power_nodes_by_id.get(node_id, {})


func power_nodes_of_kind(kind: String) -> Array:
	var out: Array = []
	for node in power.get("nodes", []):
		if String(node.get("kind", "")) == kind:
			out.append(node)
	return out


func water_node(node_id: String) -> Dictionary:
	for node in water.get("nodes", []):
		if String(node.get("id", "")) == node_id:
			return node
	return {}


func district(district_id: String) -> Dictionary:
	for d in districts:
		if String(d.get("id", "")) == district_id:
			return d
	return {}


## Doc 09 §2.9.7: the tutorial addresses entities by tag, never by raw id.
## Returns {} when the tag does not resolve to a live entity.
func resolve_tag(tag: String) -> Dictionary:
	if not tags.has(tag):
		return {}
	var entry: Dictionary = (tags[tag] as Dictionary).duplicate(true)
	var kind := String(entry.get("kind", ""))
	match kind:
		"tile":
			var local := Vector2i(int(entry["tile"][0]), int(entry["tile"][1]))
			if local.x < 0 or local.x >= CORE_TILES or local.y < 0 or local.y >= CORE_TILES:
				return {}
			entry["tile_global"] = core_to_global(local.x, local.y)
			return entry
		"block":
			if world.block(String(entry.get("id", ""))) == null:
				return {}
			return entry
		"building":
			if building(String(entry.get("id", ""))).is_empty():
				return {}
			return entry
		"power_node":
			var node := power_node(String(entry.get("id", "")))
			if node.is_empty():
				return {}
			entry["node"] = node
			return entry
		"pump":
			var host := water_node(String(entry.get("node", "")))
			if host.is_empty():
				return {}
			for pump in host.get("pumps", []):
				if String(pump.get("id", "")) == String(entry.get("id", "")):
					entry["pump"] = pump
					return entry
			return {}
		"vehicle":
			if building(String(entry.get("home_building", ""))).is_empty():
				return {}
			return entry
	return {}


# --- tile-grid census helpers (used by the data-integrity tests) ------------

func core_origin_tile() -> Vector2i:
	return Vector2i(CORE_TILE_OFFSET, CORE_TILE_OFFSET)


func count_core_road_tiles(road_class: int = -1) -> int:
	var count := 0
	for z in range(CORE_TILE_OFFSET, CORE_TILE_OFFSET + CORE_TILES):
		for x in range(CORE_TILE_OFFSET, CORE_TILE_OFFSET + CORE_TILES):
			var rc := world.grid.road_class_at(x, z)
			if rc == TileGrid.ROAD_NONE:
				continue
			if road_class < 0 or rc == road_class:
				count += 1
	return count


## Tiles carrying a flag anywhere in the core (OCCUPIED tiles still count as
## BUILDABLE — the authored buildable area, before placement).
func count_core_flag(flag: int) -> int:
	var count := 0
	for z in range(CORE_TILE_OFFSET, CORE_TILE_OFFSET + CORE_TILES):
		for x in range(CORE_TILE_OFFSET, CORE_TILE_OFFSET + CORE_TILES):
			if world.grid.has_flag(x, z, flag):
				count += 1
	return count


## Buildable tiles in a block, counting occupied ones (doc 09 §2.2's direct count).
func count_block_buildable(bx: int, bz: int) -> int:
	var count := 0
	for z in range(bz * TileGrid.TILES_PER_BLOCK, (bz + 1) * TileGrid.TILES_PER_BLOCK):
		for x in range(bx * TileGrid.TILES_PER_BLOCK, (bx + 1) * TileGrid.TILES_PER_BLOCK):
			if world.grid.has_flag(x, z, TileGrid.FLAG_BUILDABLE):
				count += 1
	return count


## Vacant buildable lots across the core (doc 09 §2.9.4 — 1,429 at t0).
func count_vacant_lots() -> int:
	var count := 0
	for bz in range(2, 5):
		for bx in range(2, 5):
			count += world.grid.count_buildable(bx, bz)
	return count


## Sum of the axis-aligned segment lengths of a polyline, in tiles — doc 09
## §2.9.5's convention (a 2-vertex segment of length 1 is "1 tile").
static func polyline_length(path: Array) -> int:
	var total := 0
	for i in range(1, path.size()):
		var a := Vector2i(int(path[i - 1][0]), int(path[i - 1][1]))
		var b := Vector2i(int(path[i][0]), int(path[i][1]))
		total += absi(b.x - a.x) + absi(b.y - a.y)
	return total


## Every tile a polyline passes through, in core-local coordinates.
static func polyline_tiles(path: Array) -> Array:
	var tiles: Array = []
	for i in range(1, path.size()):
		var a := Vector2i(int(path[i - 1][0]), int(path[i - 1][1]))
		var b := Vector2i(int(path[i][0]), int(path[i][1]))
		var step := Vector2i(signi(b.x - a.x), signi(b.y - a.y))
		var cursor := a
		while cursor != b:
			tiles.append(cursor)
			cursor += step
	if not path.is_empty():
		tiles.append(Vector2i(int(path[-1][0]), int(path[-1][1])))
	return tiles
