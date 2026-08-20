class_name StreetlightPlacer
extends RefCounted
## Where the streetlights go (doc 11 §2.10), derived from the road graph.
##
## What it replaces is one line in the scene root:
##
##     if world.grid.has_flag(x, z, TileGrid.FLAG_ROAD) and (x + z) % 4 == 0:
##
## — a parity test over the raw tile grid, which stipples lamps along a DIAGONAL
## across the whole city, puts every one of them in the middle of the
## carriageway, and cannot say which way a lamp faces because it never asked
## what a road was. It is the reason the playtest verdict was *"the street
## lights need to be in real places, on the side of the streets"*.
##
## ── the rule ──────────────────────────────────────────────────────────────
## Everything below reads `RoadSurfaceView.classify()` — the SAME classification
## the carriageway is drawn from, so a lamp can never disagree with the kerb it
## is standing on.
##
##  1. **Corridor lamps.** A tile with a resolved corridor axis and no junction
##     takes a lamp every `spacing_tiles` along that axis, measured in the tile
##     index itself (`t.y` for a north-south corridor, `t.x` for east-west).
##     Taking the phase off the WORLD index rather than off a per-edge counter
##     is deliberate: doc 10 contracts a corridor into as many edges as it has
##     junctions, so a per-edge counter restarts at every cross street and the
##     spacing visibly stutters through a grid city. The world index does not
##     care where an edge begins, so a mile of Grand Ave is lit at one pitch.
##  2. **Alternating kerbs.** Consecutive lamps down a corridor swap sides. If
##     the chosen side carries no footway (a road hard against water) the other
##     is taken; if neither does, the lamp is skipped rather than planted in a
##     traffic lane.
##  3. **Dual carriageways stagger.** Both halves of a two-tile avenue own only
##     their OUTER kerb, so alternation has nothing to alternate. Instead each
##     half lights every `2 x spacing` and the two are offset by `spacing`,
##     which is how a real arterial is lit: staggered lamps down opposite kerbs
##     at the single-carriageway pitch.
##  4. **Corners.** A tile carrying two ADJACENT footways — the head of a
##     cul-de-sac, the inside of a street corner — takes one lamp standing in
##     that corner, aimed diagonally across it. Note what this is not: a lamp on
##     each corner of a JUNCTION. A one-tile junction has three or four road
##     neighbours and so at most one kerb; it has no corner to stand a pole on,
##     and its approaches are already lit at `spacing_tiles`. Standing one in the
##     box anyway would put a pole in a traffic lane, which is the exact defect
##     this file exists to remove.
##
## Deterministic and RNG-free: the output is a pure function of the tile grid
## and the graph, ordered by (y, x, side). Nothing here reads a clock, and
## nothing here consumes a stream — doc 00 §5's hashes cannot move.

## N, E, S, W. Mirrors `RoadSurfaceView.DIRS` / `.BIT`, declared locally so this
## file has no load-order dependency on that one; `tests/test_road_surface.gd`
## asserts the two agree rather than trusting the comment.
const DIRS: Array[Vector2i] = [
	Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0),
]
const BIT := [1, 2, 4, 8]
const PAIR_NONE := 0
const TILE_M := 8.0


## `block_of` maps a tile to a `LandBlock` (pass `world.block_of_tile`); it only
## decides which block a lamp darkens with, and an invalid Callable simply
## leaves `block_id` empty. Rows are `{id, block_id, tile, side, corner, pos,
## yaw}` and `pos` is the pole BASE — on the footway, at kerb height.
static func place(grid: TileGrid, graph: RoadGraph, render_data: Dictionary,
		block_of: Callable = Callable(), first_id: int = 100000) -> Array:
	var cfg: Dictionary = render_data.get("road_surface", {})
	var lamp_cfg: Dictionary = cfg.get("lamp", {})
	var spacing := maxi(1, int(lamp_cfg.get("spacing_tiles", 3)))
	var curb_frac := clampf(float(lamp_cfg.get("pole_curb_frac", 0.5)), 0.0, 1.0)
	var corner_lamps := bool(lamp_cfg.get("corner_lamps", true))
	var w_street := float(cfg.get("sidewalk_width_street_m", 1.40))
	var w_avenue := float(cfg.get("sidewalk_width_avenue_m", 1.05))
	var base_y := float(cfg.get("asphalt_top_m", 0.10)) \
			+ float(cfg.get("kerb_height_m", 0.15))

	var facts := RoadSurfaceView.classify(grid, graph)
	var tiles: Array = facts["tiles"]
	var cls_of: Dictionary = facts["cls"]
	var mask_of: Dictionary = facts["mask"]
	var kerb_of: Dictionary = facts["kerb"]
	var pair_of: Dictionary = facts["pair"]
	var junction: Dictionary = facts["junction"]

	var picks: Array = []      # [tile, side, is_corner]
	for raw: Variant in tiles:
		var t: Vector2i = raw
		var kerb := int(kerb_of[t])
		if kerb == 0:
			continue
		var corner := _corner_side(kerb) if corner_lamps else -1
		if corner >= 0:
			# Two adjacent footways: the tile HAS a corner, so it is lit from it
			# rather than from a kerb halfway along a side it does not have.
			picks.append([t, corner, true])
			continue
		if bool(junction[t]):
			continue
		var pair := int(pair_of[t])
		var axis_x := _axis_x(int(mask_of[t]), pair)
		if axis_x < 0:
			continue
		var s := t.x if axis_x == 1 else t.y
		var side := -1
		if pair != PAIR_NONE:
			var outer := _outer_side(kerb, axis_x)
			if outer < 0:
				continue
			var phase := spacing if _twin_is_low(pair) else 0
			if posmod(s - phase, spacing * 2) != 0:
				continue
			side = outer
		else:
			if posmod(s, spacing) != 0:
				continue
			side = _kerb_side(kerb, axis_x, posmod(s / spacing, 2))
			if side < 0:
				continue
		picks.append([t, side, false])

	# ── the junction guarantee ────────────────────────────────────────────
	# The corridor pitch alone leaves gaps exactly where the city can least
	# afford one. Measured on the founding city: 51 of its 53 junction boxes
	# have a lamp within `spacing_tiles`, and the two that do not are the
	# avenue-meets-avenue crossings at (63,48) and (48,63) — the two widest
	# expanses of asphalt on the map, dark because BOTH crossing corridors put
	# their nearest lamp a full stagger period away. So any box left unlit gets
	# one forced onto its first kerbed approach. Two lamps, 186 to 188.
	var lit: Dictionary = {}
	for entry: Array in picks:
		lit[entry[0]] = true
	for raw: Variant in tiles:
		var t: Vector2i = raw
		if not bool(junction[t]):
			continue
		if _lamp_within(lit, t, spacing):
			continue
		for d in 4:
			var a: Vector2i = t + DIRS[d]
			if not kerb_of.has(a) or bool(junction[a]) or lit.has(a):
				continue
			var a_axis := _axis_x(int(mask_of[a]), int(pair_of[a]))
			if a_axis < 0:
				continue
			var a_side := _kerb_side(int(kerb_of[a]), a_axis, 0)
			if a_side < 0:
				continue
			picks.append([a, a_side, false])
			lit[a] = true
			break

	picks.sort_custom(func(a: Array, b: Array) -> bool:
		var ta: Vector2i = a[0]
		var tb: Vector2i = b[0]
		if ta.y != tb.y:
			return ta.y < tb.y
		if ta.x != tb.x:
			return ta.x < tb.x
		return int(a[1]) < int(b[1]))

	var out: Array = []
	var next_id := first_id
	for entry: Array in picks:
		var t: Vector2i = entry[0]
		var side := int(entry[1])
		var is_corner := bool(entry[2])
		var w := w_avenue if int(cls_of[t]) == TileGrid.ROAD_AVENUE else w_street
		var inset := TILE_M * 0.5 - w * curb_frac
		var centre := Vector3(float(t.x) * TILE_M + TILE_M * 0.5, base_y,
				float(t.y) * TILE_M + TILE_M * 0.5)
		var off := _dir3(DIRS[side]) * inset
		if is_corner:
			# The corner square's own centre: in by `curb_frac` of a footway on
			# BOTH of the two kerbs that meet there.
			off += _dir3(DIRS[posmod(side + 1, 4)]) * inset
		var pos := centre + off
		# The arm reaches from the pole toward the middle of the roadway.
		var toward := centre - pos
		toward.y = 0.0
		var yaw := 0.0
		if toward.length() > 0.001:
			toward = toward.normalized()
			yaw = atan2(-toward.z, toward.x)
		var block_id := ""
		if block_of.is_valid():
			var block: Variant = block_of.call(t.x, t.y)
			if block != null:
				block_id = String(block.id)
		out.append({"id": next_id, "block_id": block_id, "tile": t, "side": side,
				"corner": is_corner, "pos": pos, "yaw": yaw})
		next_id += 1
	return out


static func _dir3(d: Vector2i) -> Vector3:
	return Vector3(float(d.x), 0.0, float(d.y))


## Is any lamp within `radius` tiles (Manhattan) of `t`?
static func _lamp_within(lit: Dictionary, t: Vector2i, radius: int) -> bool:
	for dz in range(-radius, radius + 1):
		var span := radius - absi(dz)
		for dx in range(-span, span + 1):
			if lit.has(t + Vector2i(dx, dz)):
				return true
	return false


## The kerb this corridor tile is lit from: the preferred perpendicular side if
## it carries a footway, the other if not, -1 if neither does.
static func _kerb_side(kerb: int, axis_x: int, alt: int) -> int:
	var pref := _corridor_sides(axis_x, alt)
	if (kerb & BIT[pref[0]]) != 0:
		return pref[0]
	if (kerb & BIT[pref[1]]) != 0:
		return pref[1]
	return -1


## The two kerbs a corridor can be lit from, preferred one first. A north-south
## corridor is lit from its west or east kerb, an east-west one from north or
## south, and `alt` swaps them so consecutive lamps land on opposite sides.
static func _corridor_sides(axis_x: int, alt: int) -> Array:
	if axis_x == 1:
		return [0, 2] if alt == 0 else [2, 0]
	return [3, 1] if alt == 0 else [1, 3]


## 1 when the corridor runs east-west, 0 when north-south, -1 when the tile has
## no corridor to speak of (an isolated tile).
static func _axis_x(mask: int, pair: int) -> int:
	if pair != PAIR_NONE:
		# The corridor is perpendicular to the twin: an N/S twin means the pair
		# stacks across Z, so the road itself runs along X.
		return 1 if (pair == 1 or pair == 3) else 0
	var ns := _bit(mask, 0) + _bit(mask, 2)
	var ew := _bit(mask, 1) + _bit(mask, 3)
	if ns == 0 and ew == 0:
		return -1
	return 1 if ew > ns else 0


## The kerbed side of a dual-carriageway half — always the one AWAY from its
## twin, because the twin side has a road neighbour and never carries a footway.
static func _outer_side(kerb: int, axis_x: int) -> int:
	var candidates: Array = [0, 2] if axis_x == 1 else [3, 1]
	for side: int in candidates:
		if (kerb & BIT[side]) != 0:
			return side
	return -1


## The twin sits at the LOW end of the cross axis (north or west): the half of
## the stagger that carries the offset.
static func _twin_is_low(pair: int) -> bool:
	return pair == 1 or pair == 4


## The first corner (in N, E, S, W order) where two adjacent sides both carry a
## footway. Returns the FIRST of the two direction indices, or -1.
static func _corner_side(kerb: int) -> int:
	for side in 4:
		if (kerb & BIT[side]) != 0 and (kerb & BIT[posmod(side + 1, 4)]) != 0:
			return side
	return -1


static func _bit(mask: int, index: int) -> int:
	return 1 if (mask & BIT[index]) != 0 else 0
