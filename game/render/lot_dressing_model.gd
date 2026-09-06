class_name LotDressingModel
extends RefCounted
## **What the un-built part of a LOT looks like** (doc 11 §2.16a, doc 02 §2.3a,
## doc 93 §BE7, Wave 29).
##
## A building reserves the footprint of its final form the day it is founded, so
## a young store stands on one tile of a 2×2 lot and a new power plant on nine of
## sixteen. The reserved-but-unbuilt remainder is the half of the lot rule the
## player actually SEES, and bare ground there does not read as "room to grow" —
## it reads as a bug, or as a tile somebody forgot to build on.
##
## This model turns that remainder into an **apron**: the yard, parking, gravel,
## planting and fence a real site of that kind would have. It is drawn on
## `lot − built` and on nothing else, so it **recedes on its own** as the
## building grows into its ground — at the top of its ladder there is no
## remainder and this layer contributes exactly zero instances to the frame.
##
## ### It is a pure function, and that is what keeps it out of the save
##
## Nothing here is persisted, nothing here draws from a sim RNG stream, and the
## sim cannot see it. Every position, angle and shade is derived from
## `(sim_id, tile)` through [_hash2] — an integer mix, not a generator — so the
## same lot dresses identically on every device, on every reload and at every
## frame rate, and `state_hash()` cannot move because of anything in this file.
## That is the same contract `StreetLifeModel` keeps, for the same reason.
##
## ### Two buffers, two draw calls
##
## [pads] is one flat quad per un-built tile — the ground itself, tinted by what
## kind of site it is. [props] is everything standing on it, all of it the same
## unit box scaled per instance: a parking stripe is a very flat one, a bollard a
## short thin one, a stockpile a wide low one, a fence post a tall thin one. One
## mesh and one MultiMesh each, city-wide, so the whole layer is **2 draw calls**
## whatever the city does (doc 11 §2.13's census).
##
## The governor thins [props] and never [pads]: an apron with fewer bollards on
## it is still an apron, but a lot whose ground went bare would put the layer
## back to looking like the bug it exists to prevent. That is
## `PowerInfraView.apply_governor`'s reasoning, applied to ground.

# ------------------------------------------------------------- what a site IS

## Asphalt forecourt with painted bays — `store`. A shop's spare ground is where
## its customers park.
const SITE_FORECOURT := 0
## Gravel working yard with stockpiles — `construction_yard`. Its spare ground is
## where the material sits.
const SITE_YARD := 1
## Fenced gravel compound — `power_facility` and the doc-05 water shells. Their
## spare ground is switchgear standing, and it is fenced because that is what
## keeps people out of it.
const SITE_COMPOUND := 2

## Which site an archetype dresses as. Anything absent never grows, so it never
## has a remainder and never reaches this table.
const SITE_BY_ARCHETYPE := {
	&"store": SITE_FORECOURT,
	&"construction_yard": SITE_YARD,
	&"power_facility": SITE_COMPOUND,
	&"water_facility": SITE_COMPOUND,
}

const PROP_STRIPE := 0
const PROP_BOLLARD := 1
const PROP_STOCKPILE := 2
const PROP_POST := 3

const TILE_M := TileGrid.METRES_PER_TILE

# --------------------------------------------------------------- authored knobs
#
# Every number below is read from `data/render.json.lot_dressing` by [configure];
# the constants are the shipped defaults so a clone with no config draws the same
# thing rather than nothing (the pattern `Building`'s condition block uses).

var pad_inset_m: float = 0.35        ## bare strip round each pad tile, so tiles read
var pad_lift_m: float = 0.02         ## above grade, to beat z-fighting with the ground
var props_per_tile: int = 3          ## before the governor's ratio
var stripe_len_m: float = 4.6
var stripe_w_m: float = 0.16
var bollard_h_m: float = 0.85
var bollard_w_m: float = 0.22
var stockpile_h_m: float = 1.15
var stockpile_w_m: float = 2.4
var post_h_m: float = 1.9
var post_w_m: float = 0.14
var visible_radius_m: float = 520.0  ## past this a lot contributes nothing
## Pad tints, sRGB, indexed by `SITE_*`.
##
## **These are darker than an eyedropper on a reference photo would give**, and
## deliberately: the city is lit by doc 11's own sun-plus-sky ambient with glow
## over it, and a mid-value ground albedo comes back off that pipeline nearly
## white. Measured, in `tools/lot_dressing_preview.gd`: pure `Color.RED` renders
## as a light salmon, so an authored `3d3e42` asphalt read as pale lavender and
## the whole apron looked like poured concrete. These values are picked against
## the rendered frame rather than against the swatch.
var pad_color: Array[Color] = [
	Color(0.114, 0.118, 0.133),   # asphalt
	Color(0.227, 0.208, 0.161),   # gravel
	Color(0.184, 0.180, 0.169),   # compound gravel
]
var prop_color: Array[Color] = [
	Color(0.910, 0.902, 0.863),   # stripe paint
	Color(0.639, 0.373, 0.063),   # bollard
	Color(0.290, 0.259, 0.220),   # stockpile
	Color(0.431, 0.443, 0.463),   # fence post
]

## The governor's one knob (doc 11 §2.13). 1.0 is the authored density; 0.0
## leaves the pads and takes every prop.
var prop_ratio: float = 1.0

# ------------------------------------------------------------------ the output

## `{world_pos: Vector3, site: int, color: Color, size_m: float}` — one per
## un-built lot tile.
var pads: Array[Dictionary] = []
## `{world_pos: Vector3, size: Vector3, yaw: float, color: Color, kind: int}`.
var props: Array[Dictionary] = []
## The rows [apply_rows] was last given, kept so a governor change can rebuild
## without the shell re-reading the sim.
var _rows: Array[Dictionary] = []


## Read `data/render.json.lot_dressing`. Absent keys keep the shipped default, so
## this is safe on a partial block and on no block at all.
func configure(render_data: Dictionary) -> void:
	var cfg: Dictionary = render_data.get("lot_dressing", {})
	pad_inset_m = float(cfg.get("pad_inset_m", pad_inset_m))
	pad_lift_m = float(cfg.get("pad_lift_m", pad_lift_m))
	props_per_tile = maxi(0, int(cfg.get("props_per_tile", props_per_tile)))
	stripe_len_m = float(cfg.get("stripe_len_m", stripe_len_m))
	stripe_w_m = float(cfg.get("stripe_w_m", stripe_w_m))
	bollard_h_m = float(cfg.get("bollard_h_m", bollard_h_m))
	bollard_w_m = float(cfg.get("bollard_w_m", bollard_w_m))
	stockpile_h_m = float(cfg.get("stockpile_h_m", stockpile_h_m))
	stockpile_w_m = float(cfg.get("stockpile_w_m", stockpile_w_m))
	post_h_m = float(cfg.get("post_h_m", post_h_m))
	post_w_m = float(cfg.get("post_w_m", post_w_m))
	visible_radius_m = float(cfg.get("visible_radius_m", visible_radius_m))
	_read_colors(cfg.get("pad_color", []), pad_color)
	_read_colors(cfg.get("prop_color", []), prop_color)


func _read_colors(raw: Variant, into: Array[Color]) -> void:
	if not (raw is Array):
		return
	var list: Array = raw
	for i in range(mini(list.size(), into.size())):
		var entry: Variant = list[i]
		if entry is String:
			into[i] = Color(String(entry))


# -------------------------------------------------------------- the sim → rows
#
# The one read of the sim in this layer, and it is a READ: a snapshot of what is
# standing, taken on the sim's own thread by the shell and handed down. The
# render layer never holds a `CitySim`.

## Every building whose lot is larger than what it has built, as plain data.
## A building at the top of its own growth is simply absent, which is what makes
## the layer recede for free.
static func rows_from_sim(sim: CitySim) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if sim == null:
		return out
	for sim_id in sim.buildings:
		var b: Building = sim.buildings[sim_id]
		if not SITE_BY_ARCHETYPE.has(b.archetype):
			continue
		var record: Dictionary = sim.building_record(String(sim_id))
		if record.is_empty():
			continue
		# The RESERVED extent, not the lot it wishes it had: a lot-locked
		# building holds less, and dressing ground it does not own would draw an
		# apron over its neighbour (doc 02 §2.3a).
		var held: Vector2i = record.get("footprint", Vector2i.ONE)
		var built := sim.built_of_building(b)
		if held.x <= built.x and held.y <= built.y:
			continue
		out.append({
			"sim_id": String(sim_id),
			"archetype": b.archetype,
			"origin": b.origin,
			"held": held,
			"built": built,
			# **GRADE, not the block's elevation — and that is a deliberate match
			# to what the rest of the renderer does, not an oversight.** Doc 09
			# §2.2 gives each block an integer elevation and `TileGrid.elev_m`'s
			# own docstring says *"elevation is a per-block integer the render
			# layer applies"*. It does not: at this fork `grep -rn 'elev_m('
			# game/ ui/ tools/` finds **no consumer at all**, and every building,
			# road and prop in the project is drawn at `y = 0`. An apron that
			# honoured the elevation would float 12 m over the two raised blocks'
			# own buildings — which is exactly what the first cut of this layer
			# did, visible in the preview as no apron at all.
			#
			# So this layer sits where the buildings sit. If a later wave gives
			# elevation a renderer, this row is where it arrives, and the whole
			# layer follows by changing this one number.
			"elev_m": 0.0,
		})
	return out


## Rebuild [pads] and [props] from a roster. Total: an empty roster empties both
## buffers rather than leaving the last city's aprons on the ground.
func apply_rows(rows: Array[Dictionary]) -> void:
	_rows = rows
	rebuild()


## Re-derive the buffers from the rows already held — what a governor change
## needs, and the reason [apply_rows] keeps them.
func rebuild() -> void:
	pads.clear()
	props.clear()
	for row in _rows:
		_dress(row)


func _dress(row: Dictionary) -> void:
	var site: int = int(SITE_BY_ARCHETYPE.get(row["archetype"], SITE_FORECOURT))
	var origin: Vector2i = row["origin"]
	var held: Vector2i = row["held"]
	var built: Vector2i = row["built"]
	var elev := float(row.get("elev_m", 0.0))
	var sim_id := String(row["sim_id"])
	var seed_id := _hash_str(sim_id)
	for dz in range(held.y):
		for dx in range(held.x):
			# The BUILT rectangle is anchored at the origin and grows +X/+Z, so
			# the remainder is everything outside it. This is the whole "recedes
			# as it grows" behaviour: raise `built` and these tiles stop existing.
			if dx < built.x and dz < built.y:
				continue
			var tile := Vector2i(origin.x + dx, origin.y + dz)
			var centre := TileGrid.centre_of(tile)
			centre.y = elev + pad_lift_m
			pads.append({
				"world_pos": centre,
				"site": site,
				"color": pad_color[site],
				"size_m": TILE_M - pad_inset_m * 2.0,
			})
			_props_on(site, tile, centre, seed_id, Vector2i(dx, dz), held)


## The things standing on one dressed tile. `props_per_tile` scaled by the
## governor's ratio, floored at zero — a tile may legitimately end up bare while
## its pad stays, which is the point of thinning props and not ground.
func _props_on(site: int, tile: Vector2i, centre: Vector3, seed_id: int,
		local: Vector2i, held: Vector2i) -> void:
	var count := int(round(float(props_per_tile) * clampf(prop_ratio, 0.0, 1.0)))
	if count <= 0:
		return
	var h := _hash2(seed_id, tile)
	match site:
		SITE_FORECOURT:
			# Painted bays across the tile, plus one bollard on the corner that
			# faces away from the building. Stripes are laid on a fixed pitch so
			# two adjacent forecourt tiles read as one car park rather than as
			# two unrelated patches.
			for i in range(count):
				var t := (float(i) + 0.5) / float(count) - 0.5
				var pos := centre + Vector3(t * (TILE_M - pad_inset_m * 2.0), 0.0, 0.0)
				props.append(_prop(pos, Vector3(stripe_w_m, 0.01, stripe_len_m),
						0.0, PROP_STRIPE))
			if (h & 1) == 1:
				props.append(_prop(centre + Vector3(TILE_M * 0.34, 0.0, TILE_M * 0.34),
						Vector3(bollard_w_m, bollard_h_m, bollard_w_m), 0.0, PROP_BOLLARD))
		SITE_YARD:
			# Stockpiles: wide, low, at hashed offsets and hashed yaw, because a
			# materials yard is the one site that should NOT look laid out.
			for i in range(count):
				var hi := _hash2(seed_id + i * 977, tile)
				var off := Vector3(
						(float(hi % 100) / 100.0 - 0.5) * (TILE_M * 0.42), 0.0,
						(float((hi >> 7) % 100) / 100.0 - 0.5) * (TILE_M * 0.42))
				var scale := 0.65 + float((hi >> 13) % 70) / 100.0
				props.append(_prop(centre + off,
						Vector3(stockpile_w_m * scale, stockpile_h_m * scale,
								stockpile_w_m * scale),
						float(hi % 360) * 0.0174533, PROP_STOCKPILE))
		SITE_COMPOUND:
			# **Fence posts on the OUTER boundary of the lot only.** Running a
			# line down every tile edge is what the first cut did, and it read as
			# a row of separate fenced bays rather than as one enclosed compound —
			# the fence has to say "this whole yard is the plant's", not "here are
			# four pens". So each of the four sides is fenced only where this tile
			# actually sits on that side of the reservation.
			var edge := TILE_M * 0.5 - pad_inset_m
			var sides: Array[Vector2i] = []
			if local.y == 0:
				sides.append(Vector2i(0, -1))
			if local.y == held.y - 1:
				sides.append(Vector2i(0, 1))
			if local.x == 0:
				sides.append(Vector2i(-1, 0))
			if local.x == held.x - 1:
				sides.append(Vector2i(1, 0))
			for side in sides:
				for i in range(count):
					var t2 := (float(i) + 0.5) / float(count) - 0.5
					# Along the side, not across it: the run axis is the one the
					# side's normal is zero on.
					var along := Vector3(float(side.y) * t2 * TILE_M, 0.0,
							float(side.x) * t2 * TILE_M)
					var out_v := Vector3(float(side.x) * edge, 0.0, float(side.y) * edge)
					props.append(_prop(centre + along + out_v,
							Vector3(post_w_m, post_h_m, post_w_m), 0.0, PROP_POST))


func _prop(pos: Vector3, size: Vector3, yaw: float, kind: int) -> Dictionary:
	# The box is unit-height and sits ON the ground, so the instance is raised by
	# half its own height rather than by a magic number.
	return {
		"world_pos": pos + Vector3(0.0, size.y * 0.5, 0.0),
		"size": size,
		"yaw": yaw,
		"color": prop_color[kind],
		"kind": kind,
	}


# ------------------------------------------------------------------- hashing
#
# An integer mix, NOT a random generator: this layer may not draw from a named
# stream (it would move the state hash) and may not use an unnamed one (it would
# differ between devices). Both properties are asserted in
# `tests/test_lot_dressing.gd`.

static func _hash_str(text: String) -> int:
	var h := 2166136261
	for i in text.length():
		h = (h ^ text.unicode_at(i)) * 16777619
		h &= 0x7FFFFFFF
	return h


static func _hash2(seed_id: int, tile: Vector2i) -> int:
	var h := seed_id ^ (tile.x * 73856093) ^ (tile.y * 19349663)
	h &= 0x7FFFFFFF
	h = (h ^ (h >> 13)) * 1274126177
	return h & 0x7FFFFFFF
