class_name TileGrid
extends RefCounted
## 112×112 world tile grid (doc 09 §2.1, §3.2). Flags are a uint8 bitfield;
## building occupancy is a parallel int array (0 = none). Only the delta from
## the authored map persists; the grid is rebuilt at load.

const SIZE: int = 112
const TILES_PER_BLOCK: int = 16
const BLOCKS: int = 7

const FLAG_BUILDABLE: int = 1
const FLAG_ROAD: int = 2
const FLAG_WATER: int = 4
const FLAG_BLOCKED: int = 8
const FLAG_OCCUPIED: int = 16
const FLAG_FLOODED: int = 32
const FLAG_UTILITY_ROW: int = 64

const ROAD_NONE: int = 0
const ROAD_STREET: int = 1
const ROAD_AVENUE: int = 2

var _flags := PackedByteArray()
var _building_ids := PackedInt32Array()
var _road_class := PackedByteArray()
var _block_elevation_m := PackedInt32Array()  # 49 entries, block-flat (doc 09 §2.2)


func _init() -> void:
	_flags.resize(SIZE * SIZE)
	_building_ids.resize(SIZE * SIZE)
	_road_class.resize(SIZE * SIZE)
	_block_elevation_m.resize(BLOCKS * BLOCKS)


static func in_bounds(x: int, z: int) -> bool:
	return x >= 0 and x < SIZE and z >= 0 and z < SIZE


static func block_of(x: int, z: int) -> Vector2i:
	return Vector2i(x / TILES_PER_BLOCK, z / TILES_PER_BLOCK)


static func block_index(bx: int, bz: int) -> int:
	return bz * BLOCKS + bx


func _idx(x: int, z: int) -> int:
	assert(in_bounds(x, z), "tile out of bounds: %d,%d" % [x, z])
	return z * SIZE + x


func flags_at(x: int, z: int) -> int:
	return _flags[_idx(x, z)]


func has_flag(x: int, z: int, flag: int) -> bool:
	return (_flags[_idx(x, z)] & flag) != 0


func set_flag(x: int, z: int, flag: int) -> void:
	_flags[_idx(x, z)] |= flag


func clear_flag(x: int, z: int, flag: int) -> void:
	_flags[_idx(x, z)] &= ~flag


func building_at(x: int, z: int) -> int:
	return _building_ids[_idx(x, z)]


func road_class_at(x: int, z: int) -> int:
	return _road_class[_idx(x, z)]


## "Is there a tile of this road class inside this rectangle?" — the doc 10
## access-quality avenue gate, which asks it once per BUILDING per settled hour
## over a 9×9 window. The per-tile form is 81 `road_class_at` calls, each with
## its own bounds test and its own `_idx`; this walks the backing array by row
## and answers the same question. The rectangle is clamped here, so callers pass
## raw tile coordinates and out-of-bounds rows simply contribute nothing.
func has_road_class_in_rect(x0: int, z0: int, x1: int, z1: int, road_class: int) -> bool:
	var lo_x := maxi(0, x0)
	var hi_x := mini(SIZE - 1, x1)
	var lo_z := maxi(0, z0)
	var hi_z := mini(SIZE - 1, z1)
	if lo_x > hi_x or lo_z > hi_z:
		return false
	var z := lo_z
	while z <= hi_z:
		var base := z * SIZE
		var i := base + lo_x
		var end := base + hi_x
		while i <= end:
			if _road_class[i] == road_class:
				return true
			i += 1
		z += 1
	return false


func set_road(x: int, z: int, road_class: int) -> void:
	_road_class[_idx(x, z)] = road_class
	if road_class == ROAD_NONE:
		clear_flag(x, z, FLAG_ROAD)
	else:
		set_flag(x, z, FLAG_ROAD)
		clear_flag(x, z, FLAG_BUILDABLE)


func set_block_elevation(bx: int, bz: int, elevation_m: int) -> void:
	_block_elevation_m[block_index(bx, bz)] = elevation_m


func elev_m(x: int, z: int) -> int:
	var b := block_of(x, z)
	return _block_elevation_m[block_index(b.x, b.y)]


## A footprint is placeable iff every tile is in bounds, BUILDABLE, and free of
## ROAD/WATER/BLOCKED/OCCUPIED (doc 09: placement requires READY, checked by WorldMap).
func can_place(origin: Vector2i, size: Vector2i) -> bool:
	for z in range(origin.y, origin.y + size.y):
		for x in range(origin.x, origin.x + size.x):
			if not in_bounds(x, z):
				return false
			var f := _flags[z * SIZE + x]
			if (f & FLAG_BUILDABLE) == 0:
				return false
			if (f & (FLAG_ROAD | FLAG_WATER | FLAG_BLOCKED | FLAG_OCCUPIED)) != 0:
				return false
	return true


func stamp_building(building_id: int, origin: Vector2i, size: Vector2i) -> bool:
	assert(building_id > 0, "building ids start at 1; 0 means empty")
	if not can_place(origin, size):
		return false
	for z in range(origin.y, origin.y + size.y):
		for x in range(origin.x, origin.x + size.x):
			set_flag(x, z, FLAG_OCCUPIED)
			_building_ids[_idx(x, z)] = building_id
	return true


func remove_building(building_id: int, origin: Vector2i, size: Vector2i) -> void:
	for z in range(origin.y, origin.y + size.y):
		for x in range(origin.x, origin.x + size.x):
			if _building_ids[_idx(x, z)] == building_id:
				_building_ids[_idx(x, z)] = 0
				clear_flag(x, z, FLAG_OCCUPIED)


## Count of buildable, unoccupied tiles within a block (the post-READY direct
## count that gates placement — doc 09 §2.2).
func count_buildable(bx: int, bz: int) -> int:
	var count := 0
	for z in range(bz * TILES_PER_BLOCK, (bz + 1) * TILES_PER_BLOCK):
		for x in range(bx * TILES_PER_BLOCK, (bx + 1) * TILES_PER_BLOCK):
			var f := _flags[z * SIZE + x]
			if (f & FLAG_BUILDABLE) != 0 and (f & FLAG_OCCUPIED) == 0:
				count += 1
	return count
