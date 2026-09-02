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

## **The one authority for tile→world geometry** (doc 09 §2.1; the STORE is
## `data/world.json world.tile_meters`, and `tests/test_tile_geometry.gd` asserts
## the two agree and that every mirrored spelling in the tree still equals this).
##
## At the Wave-17 fork this number was written eight times under six names —
## `METRES_PER_TILE`, `TILE_METERS`, `TILE_M`, `DEF_TILE_M`, `TILE_M_DEFAULT` and
## bare `8.0` literals — and the footprint→centre formula four times, with no
## test asserting any of them agreed (PA-76). Nothing here is new arithmetic: the
## constant and the three helpers below reproduce the expressions the shell and
## the renderer already wrote by hand, so adopting them is hash-neutral by
## construction. New readers take it from here; the migration of the existing
## spellings is one row per owning lane (doc 98 §50).
const METRES_PER_TILE := 8.0

## A land block's side in metres — `METRES_PER_TILE * TILES_PER_BLOCK`. The alert
## locator spelled the `16` three times as a bare literal beside a `tile_m` it
## had already declared (PA-76 evidence).
const METRES_PER_BLOCK := METRES_PER_TILE * float(TILES_PER_BLOCK)

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


# ---------------------------------------------------------------------------
# Tile → world (PA-76). Every one of these is `y = 0` — GRADE, not the mesh top.
# Elevation is a per-block integer the render layer applies; a locator that
# guessed at it would put the camera underground on the two raised blocks.
# ---------------------------------------------------------------------------

## The NW corner of a tile, in metres. This is what a raw `tile * tile_m`
## multiplication produces, and it is the anchor a mesh instance is placed at —
## not where a camera should look.
static func corner_of(tile: Vector2i) -> Vector3:
	return Vector3(float(tile.x) * METRES_PER_TILE, 0.0,
			float(tile.y) * METRES_PER_TILE)


## The CENTRE of one tile, in metres — half a tile in from the corner. What a
## pad, a lamp, a road slab and a camera focus all want.
static func centre_of(tile: Vector2i) -> Vector3:
	return Vector3(float(tile.x) * METRES_PER_TILE + METRES_PER_TILE * 0.5, 0.0,
			float(tile.y) * METRES_PER_TILE + METRES_PER_TILE * 0.5)


## The centre of a footprint whose NW tile is `origin` and whose size is in
## TILES (doc 02 stores tiles). Degenerates to `centre_of` at 1×1, which is what
## makes it safe to use everywhere a tile centre was wanted.
static func centre_of_footprint(origin: Vector2i, size: Vector2i) -> Vector3:
	var w := float(maxi(size.x, 1)) * METRES_PER_TILE
	var d := float(maxi(size.y, 1)) * METRES_PER_TILE
	return Vector3(float(origin.x) * METRES_PER_TILE + w * 0.5, 0.0,
			float(origin.y) * METRES_PER_TILE + d * 0.5)


## The centre of a land block, addressed by its BLOCK grid coordinate
## (`LandBlock.grid`, 0..6 on each axis) — not by a tile.
static func centre_of_block(block_grid: Vector2i) -> Vector3:
	return Vector3(float(block_grid.x) * METRES_PER_BLOCK + METRES_PER_BLOCK * 0.5,
			0.0, float(block_grid.y) * METRES_PER_BLOCK + METRES_PER_BLOCK * 0.5)


## World metres → the tile containing them. `floor`, not truncation: a negative
## x is off the map and must stay off it rather than folding onto tile 0.
static func tile_at(point: Vector3) -> Vector2i:
	return Vector2i(int(floorf(point.x / METRES_PER_TILE)),
			int(floorf(point.z / METRES_PER_TILE)))


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
