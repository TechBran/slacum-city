class_name WorldMap
extends RefCounted
## Owns the land blocks and the tile grid (doc 09 §4). Adjacency,
## purchasability, ring/d computation. Development/economy hooks arrive with
## P0-12/P0-22; this is the structural core.

const CENTER_BLOCK := Vector2i(3, 3)

var grid := TileGrid.new()
var _blocks: Dictionary = {}  # "B_x_z" -> LandBlock


static func block_id_for(bx: int, bz: int) -> String:
	return "B_%d_%d" % [bx, bz]


func add_block(block: LandBlock) -> void:
	_blocks[block.id] = block
	grid.set_block_elevation(block.grid.x, block.grid.y, block.elevation_m())


func block(block_id: String) -> LandBlock:
	return _blocks.get(block_id)


func block_at(bx: int, bz: int) -> LandBlock:
	return _blocks.get(block_id_for(bx, bz))


func block_of_tile(x: int, z: int) -> LandBlock:
	var b := TileGrid.block_of(x, z)
	return block_at(b.x, b.y)


func block_count() -> int:
	return _blocks.size()


func block_ids_sorted() -> Array:
	var ids := _blocks.keys()
	ids.sort()
	return ids


func owned_count() -> int:
	var count := 0
	for id in _blocks:
		if (_blocks[id] as LandBlock).is_owned():
			count += 1
	return count


## Chebyshev block distance from the centre block — doc 03's `d`.
func d_from_center(block_id: String) -> int:
	var b: LandBlock = _blocks[block_id]
	return maxi(absi(b.grid.x - CENTER_BLOCK.x), absi(b.grid.y - CENTER_BLOCK.y))


## Orthogonal (full-edge) neighbours that exist in the world.
func neighbors4(block_id: String) -> Array:
	var b: LandBlock = _blocks[block_id]
	var out: Array = []
	for offset in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var n := block_at(b.grid.x + offset.x, b.grid.y + offset.y)
		if n != null:
			out.append(n)
	return out


## Doc 09 §2.5: purchasable iff city level suffices AND a full edge touches an
## OWNED block. Diagonal contact does not qualify. (Future exception flags are
## null in MVP.)
func purchase_allowed(block_id: String, city_level: int) -> Dictionary:
	var b: LandBlock = _blocks.get(block_id)
	if b == null:
		return CommandQueue.fail(&"E_UNKNOWN_BLOCK")
	if b.ownership_state == &"OWNED":
		return CommandQueue.fail(&"E_ALREADY_OWNED")
	if city_level < b.min_city_level:
		return CommandQueue.fail(&"E_CITY_LEVEL", {"required": b.min_city_level})
	var touches_owned := false
	for n in neighbors4(block_id):
		if (n as LandBlock).is_owned():
			touches_owned = true
			break
	if not touches_owned:
		return CommandQueue.fail(&"E_NOT_ADJACENT")
	return CommandQueue.ok()


## Refresh every non-owned block's LOCKED/PURCHASABLE state (doc 09 §2.3),
## called after any purchase or city-level change.
func refresh_purchasable(city_level: int) -> void:
	for id in block_ids_sorted():
		var b: LandBlock = _blocks[id]
		if b.is_owned():
			continue
		var allowed: bool = bool(purchase_allowed(id, city_level)["ok"])
		b.ownership_state = &"PURCHASABLE" if allowed else &"LOCKED"


func serialize_blocks() -> Array:
	var out: Array = []
	for id in block_ids_sorted():
		out.append((_blocks[id] as LandBlock).serialize())
	return out
