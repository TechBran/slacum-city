class_name RoadSurfaceView
extends Node3D
## The street itself (doc 11 §2.1.2): asphalt, lane markings, kerbs and
## footways, built from doc 10's road GRAPH.
##
## What this replaces is a MultiMesh of untextured 8 m slabs, and the playtest
## note that motivated it was blunt: *"more like a real street, two lanes,
## black, yellow dividing line in the middle, a sidewalk."* Every one of those
## is here, and the reason it is a renderer file and not a sim change is that
## none of it is a fact about the city — it is a reading of facts doc 10
## already owns.
##
## ── why the GRAPH and not the tile grid ───────────────────────────────────
## Both are available; only one of them knows what a road MEANS. Three things
## come out wrong from per-tile guesswork and right from the graph:
##
## * **Class.** A tile's own `road_class` is the tile's; the graph's edge class
##   is the SLOWEST class on the segment (`RoadGraph._edge_class`), which is the
##   class the segment is priced and routed as. A two-tile transition stub now
##   paints the same line the router charges for.
## * **Junctions.** Doc 11 §2.1.2's rule is that no centre line crosses a
##   junction box. "Junction" is a graph question — and a subtle one, because
##   the starter city's avenues are TWO tiles wide, so a naive degree test calls
##   every avenue tile a junction and the whole city loses its centre lines.
##   `_pair_of` resolves the dual carriageway first (below), and what is left
##   over with three or more legs is a real junction.
## * **Where a lamp goes.** `StreetlightPlacer` reads the classification below —
##   corridor axis, kerbed sides, junction flag — so a lamp stands ON a kerb,
##   faces the carriageway, and alternates sides down a corridor. The parity test
##   it replaces (`(x + z) % 4 == 0`) stipples a diagonal across the city, stands
##   every pole in open carriageway, and has no idea which way it faces.
##
## ── two draw calls, city-wide, on purpose ─────────────────────────────────
## §2.13's convention is per-chunk MultiMesh buckets. Roads are the one layer
## where that is measurably the wrong trade: the world is 7x7 chunks, road runs
## along every chunk boundary so all 49 hold some, and at Z2 every one of them
## is on screen — per-chunk buckets would be **98 draw calls** against 71 of
## headroom (219 used of the 320 Balanced budget). City-wide they are 2, which
## is what the slab MultiMesh they replace already cost, +1. The bill is paid in
## vertices instead and it is small: the asphalt is 12 triangles a tile and the
## footway is merged into RUNS, so a 20-tile avenue kerb is one instance and not
## twenty. Numbers in the branch report.
##
## ── the per-instance contract ─────────────────────────────────────────────
## `game/shaders/road_surface.gdshader` documents the four channels in full and
## `tests/test_road_surface.gd` pins them. In brief: `.r` neighbour mask,
## `.g` kerb mask, `.b` class + 2*pair + 16*crosswalk mask, `.a` wear seed.
##
## Reads doc 10; mutates nothing. Zero RNG: the wear seed is a hash of the tile.

const TILE_M := 8.0

## N, E, S, W — the bit order the shader decodes. Deliberately NOT
## `RoadGraph.DIRS` (which is N, W, E, S for its own determinism reasons): this
## order is a wire format shared with a shader, so it is declared here.
const DIRS: Array[Vector2i] = [
	Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0),
]
const BIT := [1, 2, 4, 8]
## `pair` is the direction INDEX + 1, so 0 stays "no twin".
const PAIR_NONE := 0

const MANIFEST := "res://game/textures/generated/manifest.json"
const ROAD_SHADER := "res://game/shaders/road_surface.gdshader"
const WALK_SHADER := "res://game/shaders/sidewalk.gdshader"

var cfg: Dictionary = {}
var asphalt_top_m := 0.10
var asphalt_thickness_m := 0.10
var sidewalk_top_m := 0.25
var sidewalk_w_street := 1.40
var sidewalk_w_avenue := 1.05

var _asphalt: MultiMeshInstance3D
var _sidewalk: MultiMeshInstance3D
var _tiles: Array[Vector2i] = []
var _pack_of: Dictionary = {}     # Vector2i -> Color (the uploaded custom data)
var _slot_of: Dictionary = {}     # Vector2i -> int
var _runs: Array = []             # [{axis, lo, hi, fixed, w, corner}] — tests read this
## `RoadGraph.graph_version` the current buffers were built from, so a second
## call for the same edit is free. -1 = never built.
var _built_version: int = -1
## Instrumented, the way `RoadGraph.last_retraced_tiles` is: how many `rebuild`
## calls actually walked the city. `tests/test_road_surface.gd` asserts against
## it rather than trusting the guard.
var rebuild_passes: int = 0


# ---------------------------------------------------------------------- setup

## `render_data` is the shared `data/render.json`. Safe to call once; the views
## are built empty and `rebuild()` fills them.
func setup(render_data: Dictionary) -> void:
	cfg = render_data.get("road_surface", {})
	asphalt_top_m = float(cfg.get("asphalt_top_m", 0.10))
	asphalt_thickness_m = float(cfg.get("asphalt_thickness_m", 0.10))
	var kerb_h := float(cfg.get("kerb_height_m", 0.15))
	sidewalk_top_m = asphalt_top_m + kerb_h
	sidewalk_w_street = float(cfg.get("sidewalk_width_street_m", 1.40))
	sidewalk_w_avenue = float(cfg.get("sidewalk_width_avenue_m", 1.05))
	_build_nodes(render_data)


## Metres of footway the tile's class carries on each kerbed side.
func sidewalk_width(road_class: int) -> float:
	return sidewalk_w_avenue if road_class == TileGrid.ROAD_AVENUE else sidewalk_w_street


func _build_nodes(render_data: Dictionary) -> void:
	if _asphalt != null:
		return
	var slab := BoxMesh.new()
	slab.size = Vector3(TILE_M, asphalt_thickness_m, TILE_M)
	var asphalt_mm := MultiMesh.new()
	asphalt_mm.transform_format = MultiMesh.TRANSFORM_3D
	asphalt_mm.use_custom_data = true
	asphalt_mm.mesh = slab
	asphalt_mm.instance_count = 0
	_asphalt = MultiMeshInstance3D.new()
	_asphalt.name = "RoadAsphalt"
	_asphalt.multimesh = asphalt_mm
	_asphalt.material_override = _road_material(render_data)
	_asphalt.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	add_child(_asphalt)

	var kerb := BoxMesh.new()
	kerb.size = Vector3(1.0, 1.0, 1.0)
	var walk_mm := MultiMesh.new()
	walk_mm.transform_format = MultiMesh.TRANSFORM_3D
	walk_mm.mesh = kerb
	walk_mm.instance_count = 0
	_sidewalk = MultiMeshInstance3D.new()
	_sidewalk.name = "Sidewalks"
	_sidewalk.multimesh = walk_mm
	_sidewalk.material_override = _walk_material(render_data)
	_sidewalk.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	add_child(_sidewalk)


## Materials are ShaderMaterials for the same reason `GroundSurface`'s are: the
## §2.9 wet read and §2.5's overlay wash are project shader globals and a
## StandardMaterial3D cannot see one. The night floor is the ROAD row of
## `data/render.json.ground` — the same numbers the block interiors and the old
## slab already used, so this pass changes the picture without moving the
## NIGHT-1 calibration.
func _road_material(render_data: Dictionary) -> Material:
	var mat := ShaderMaterial.new()
	if not ResourceLoader.exists(ROAD_SHADER):
		return _fallback(Color(String(cfg.get("tint", "#57575F"))), 0.85)
	mat.shader = load(ROAD_SHADER)
	mat.set_shader_parameter("tint", Color(String(cfg.get("tint", "#57575F"))))
	mat.set_shader_parameter("dry_roughness", float(cfg.get("roughness", 0.85)))
	mat.set_shader_parameter("tile_m", TILE_M)
	mat.set_shader_parameter("sidewalk_w_street", sidewalk_w_street)
	mat.set_shader_parameter("sidewalk_w_avenue", sidewalk_w_avenue)
	_apply_page(mat, String(cfg.get("page", "asphalt")))
	_apply_wet(mat, render_data)
	var night := GroundSurface.night_floor(true)
	mat.set_shader_parameter("night_color", night["color"])
	mat.set_shader_parameter("night_albedo_lift", float(night["albedo_lift"]))
	mat.set_shader_parameter("night_glow", float(night["glow"]))
	for key: String in ["centre_line_w", "double_gap", "edge_line_w",
			"edge_line_inset", "dash_mark", "dash_gap", "lane_dash_mark",
			"lane_dash_gap", "dead_end_stop", "marking_night_glow",
			"marking_roughness", "marking_wear_loss", "crosswalk_bar",
			"crosswalk_period", "crosswalk_depth", "crosswalk_inset",
			"patch_gain", "patch_scale_m", "seam_darken", "wheel_path_gain",
			"wheel_path_w", "gutter_m", "gutter_darken", "wear_tile_gain"]:
		var json_key := _json_key(key)
		if cfg.has(json_key):
			mat.set_shader_parameter(key, float(cfg[json_key]))
	mat.set_shader_parameter("line_yellow", Color(String(cfg.get("line_yellow", "#E3B637"))))
	mat.set_shader_parameter("line_white", Color(String(cfg.get("line_white", "#D6D6CE"))))
	return mat


## `data/render.json` spells the metre-valued keys with a `_m` suffix and the
## shader does not; everything else is spelled the same. One table, one place.
static func _json_key(shader_key: String) -> String:
	match shader_key:
		"centre_line_w": return "centre_line_w_m"
		"double_gap": return "double_gap_m"
		"edge_line_w": return "edge_line_w_m"
		"edge_line_inset": return "edge_line_inset_m"
		"dash_mark": return "dash_mark_m"
		"dash_gap": return "dash_gap_m"
		"lane_dash_mark": return "lane_dash_mark_m"
		"lane_dash_gap": return "lane_dash_gap_m"
		"dead_end_stop": return "dead_end_stop_m"
		"crosswalk_bar": return "crosswalk_bar_m"
		"crosswalk_period": return "crosswalk_period_m"
		"crosswalk_depth": return "crosswalk_depth_m"
		"crosswalk_inset": return "crosswalk_inset_m"
		"wheel_path_w": return "wheel_path_w_m"
		_: return shader_key


func _walk_material(render_data: Dictionary) -> Material:
	var mat := ShaderMaterial.new()
	if not ResourceLoader.exists(WALK_SHADER):
		return _fallback(Color(String(cfg.get("sidewalk_tint", "#9C9C95"))), 0.93)
	mat.shader = load(WALK_SHADER)
	mat.set_shader_parameter("tint", Color(String(cfg.get("sidewalk_tint", "#9C9C95"))))
	mat.set_shader_parameter("kerb_tint",
			Color(String(cfg.get("sidewalk_kerb_tint", "#8E8D85"))))
	mat.set_shader_parameter("dry_roughness", float(cfg.get("sidewalk_roughness", 0.93)))
	mat.set_shader_parameter("top_y", sidewalk_top_m)
	mat.set_shader_parameter("asphalt_y", asphalt_top_m)
	mat.set_shader_parameter("joint_period_m",
			float(cfg.get("sidewalk_joint_period_m", 1.20)))
	mat.set_shader_parameter("joint_darken", float(cfg.get("sidewalk_joint_darken", 0.30)))
	mat.set_shader_parameter("kerb_dark", float(cfg.get("sidewalk_kerb_dark", 0.72)))
	mat.set_shader_parameter("kerb_edge_gain",
			float(cfg.get("sidewalk_kerb_edge_gain", 0.16)))
	_apply_page(mat, String(cfg.get("sidewalk_page", "pavement")))
	_apply_wet(mat, render_data)
	var night := GroundSurface.night_floor(false)
	mat.set_shader_parameter("night_color", night["color"])
	mat.set_shader_parameter("night_albedo_lift",
			float(cfg.get("sidewalk_night_albedo_lift", 0.22)))
	mat.set_shader_parameter("night_glow", float(cfg.get("sidewalk_night_glow", 0.030)))
	return mat


func _apply_wet(mat: ShaderMaterial, render_data: Dictionary) -> void:
	var weather: Dictionary = render_data.get("weather", {})
	mat.set_shader_parameter("wet_roughness", float(weather.get("wet_roughness_wet", 0.18)))
	mat.set_shader_parameter("wet_specular", float(weather.get("wet_specular_wet", 0.85)))
	mat.set_shader_parameter("wet_albedo_mult", float(weather.get("wet_albedo_mult", 0.62)))
	mat.set_shader_parameter("dry_specular", 0.30)
	var ground: Dictionary = render_data.get("ground", {})
	mat.set_shader_parameter("night_glow_wet_mult",
			float(ground.get("night_glow_wet_mult", 0.55)))


## The generated ground pages, straight off the manifest. Deliberately not via
## `GroundSurface`: that class hands out whole MATERIALS and this pass needs the
## page under a different shader, and `load()` is resource-cached so the two
## share one texture in VRAM. **Zero new texture memory** is spent by this pass.
func _apply_page(mat: ShaderMaterial, page_name: String) -> void:
	mat.set_shader_parameter("page_tile_m", GroundSurface.tile_m())
	mat.set_shader_parameter("has_page", 0.0)
	if not ResourceLoader.exists(MANIFEST):
		return
	var doc: Dictionary = StarterCityLoader.read_json(MANIFEST)
	var grounds: Dictionary = doc.get("grounds", {})
	var path := String((grounds.get(page_name, {}) as Dictionary).get("path", ""))
	if path == "" or not ResourceLoader.exists(path):
		return
	mat.set_shader_parameter("page", load(path))
	mat.set_shader_parameter("has_page", 1.0)


static func _fallback(tint: Color, roughness: float) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = tint
	mat.roughness = roughness
	return mat


# -------------------------------------------------------------------- rebuild

## Re-read the road layer and rewrite both buffers. `graph` may be null (a test
## rig, or a clone booted before doc 10 exists) and the tile grid alone is then
## used — the picture degrades to per-tile class and nothing else changes.
## Returns the number of road tiles drawn.
func rebuild(grid: TileGrid, graph: RoadGraph = null, force: bool = false) -> int:
	if _asphalt == null:
		return 0
	# One player road edit can fire `road_graph_changed` AND
	# `block_roads_stamped`, and the shell calls this from both. The graph bumps
	# `graph_version` on every edit and on nothing else, so a repeat call for the
	# same version is free rather than a second full pass. `force` is for the
	# paths that change the WORLD without going through the graph — a mid-session
	# load, where the graph object itself is new.
	if not force and graph != null and _built_version == graph.graph_version:
		return _tiles.size()
	_built_version = graph.graph_version if graph != null else -1
	rebuild_passes += 1
	var facts := classify(grid, graph)
	_tiles = facts["tiles"]
	var cls_of: Dictionary = facts["cls"]
	var mask_of: Dictionary = facts["mask"]
	var kerb_of: Dictionary = facts["kerb"]
	var pair_of: Dictionary = facts["pair"]
	var junction: Dictionary = facts["junction"]

	# Crosswalks. A leg only gets a zebra if what it leads to is NOT another
	# junction tile — which is what stops a 2x2 avenue crossing from painting
	# four zebras into its own middle.
	var mm := _asphalt.multimesh
	mm.instance_count = _tiles.size()
	_pack_of.clear()
	_slot_of.clear()
	var half := TILE_M * 0.5
	var y := asphalt_top_m - asphalt_thickness_m * 0.5
	for i in _tiles.size():
		var t: Vector2i = _tiles[i]
		var mask := int(mask_of[t])
		var cw := 0
		if bool(junction[t]):
			for d in 4:
				if (mask & BIT[d]) != 0 and not bool(junction.get(t + DIRS[d], false)):
					cw |= BIT[d]
		var cls_code := 1 if int(cls_of[t]) == TileGrid.ROAD_AVENUE else 0
		var packed := float(cls_code) + 2.0 * float(pair_of[t]) + 16.0 * float(cw)
		var data := Color(float(mask), float(kerb_of[t]), packed, _wear_seed(t))
		mm.set_instance_transform(i, Transform3D(Basis.IDENTITY,
				Vector3(float(t.x) * TILE_M + half, y, float(t.y) * TILE_M + half)))
		mm.set_instance_custom_data(i, data)
		_pack_of[t] = data
		_slot_of[t] = i
	_asphalt.custom_aabb = _cover(_tiles, -0.5, 1.0)

	_build_sidewalks(kerb_of, cls_of)
	return _tiles.size()


## Everything both this view and `StreetlightPlacer` need to know about the road
## layer, read once. Returned as `{tiles, cls, mask, kerb, pair, junction}`:
##
##   tiles     Array[Vector2i] in (y, x) order — the graph's own scan order, so
##             two runs over the same city agree tile for tile.
##   cls       TileGrid.ROAD_* per tile, from the graph EDGE where there is one
##   mask      neighbour bits N=1 E=2 S=4 W=8
##   kerb      the sides that carry a footway (no road neighbour, no water)
##   pair      0, or the direction INDEX + 1 of a dual-carriageway twin
##   junction  true where three or more legs meet and no twin resolves it
##
## Static and side-effect-free on purpose: the lamp placer must reach the same
## verdict as the surface it stands on, and the only way to guarantee that is
## for both to call one function.
static func classify(grid: TileGrid, graph: RoadGraph = null) -> Dictionary:
	var tiles := _road_tiles(grid, graph)
	var is_road: Dictionary = {}
	var cls_of: Dictionary = {}
	for t: Vector2i in tiles:
		is_road[t] = true
		cls_of[t] = _class_of(grid, graph, t)
	var mask_of: Dictionary = {}
	var kerb_of: Dictionary = {}
	var pair_of: Dictionary = {}
	var junction: Dictionary = {}
	for t: Vector2i in tiles:
		var mask := 0
		var kerb := 0
		var degree := 0
		for i in 4:
			var q: Vector2i = t + DIRS[i]
			if is_road.has(q):
				mask |= BIT[i]
				degree += 1
			elif not _is_water(grid, q):
				kerb |= BIT[i]
		mask_of[t] = mask
		kerb_of[t] = kerb
		# A dual carriageway needs two along-axis neighbours AND a twin, so a
		# tile with fewer than three legs cannot be one. Skipping `_pair_of` on
		# those is worth 3.4 ms of the benchmark city's 12.4 ms classification —
		# it is the majority of tiles on any city that is mostly straight road.
		var pair := _pair_of(is_road, cls_of, t) if degree >= 3 else PAIR_NONE
		pair_of[t] = pair
		junction[t] = pair == PAIR_NONE and degree >= 3
	return {"tiles": tiles, "cls": cls_of, "mask": mask_of, "kerb": kerb_of,
			"pair": pair_of, "junction": junction}


## The graph's own membership map, in its own (y, x) scan order, when there is a
## graph; a grid sweep otherwise.
##
## Taking membership from the graph is safe even mid-edit, and that is worth
## saying because it looks unsafe: §2.5's retrace is BUDGETED, so `graph_dirty`
## can be set when this runs. But `RoadGraph.apply_edits` re-reads tile
## MEMBERSHIP for every dirty tile up front and only the edge TRACING is
## budgeted — so a tile the player just paved is in `_road_tiles` on the same
## tick, whatever the trace has got to.
##
## Measured, and the reason the grid sweep is not the fast path it looks like:
## `has_flag` is a method call with a bounds assert per tile, so sweeping all
## 12,544 grid cells costs 6.6 ms on the founding city where asking the graph
## for its 783 costs 0.6 — GDScript call overhead dwarfs the work either way.
static func _road_tiles(grid: TileGrid, graph: RoadGraph) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if graph != null:
		for raw: Variant in graph.road_tiles_sorted():
			out.append(raw)
		return out
	for z in TileGrid.SIZE:
		for x in TileGrid.SIZE:
			if grid.has_flag(x, z, TileGrid.FLAG_ROAD):
				out.append(Vector2i(x, z))
	return out


## The graph's EDGE class where the tile belongs to exactly one edge, the tile's
## own otherwise. A node tile sits on several edges and has no single answer —
## it is also always a junction, which paints no centre line, so the tile's own
## class is all its footway width needs.
## Reads `tile_edges` and `edge_or_null` rather than `edges_at`/`edge`: both of
## those ALLOCATE on every call (a defensive Array copy and a fresh empty
## Dictionary respectively — `RoadGraph` says so itself), and this runs once per
## road tile per rebuild.
static func _class_of(grid: TileGrid, graph: RoadGraph, t: Vector2i) -> int:
	if graph != null:
		var ids: Variant = graph.tile_edges.get(t)
		if ids is Array and (ids as Array).size() == 1:
			var record: Variant = graph.edge_or_null(int((ids as Array)[0]))
			if record is Dictionary:
				return int((record as Dictionary)["road_class"])
	return grid.road_class_at(t.x, t.y)


static func _is_water(grid: TileGrid, q: Vector2i) -> bool:
	if not TileGrid.in_bounds(q.x, q.y):
		return false   # off-map: still kerb it, so the road ends in a face
	return grid.has_flag(q.x, q.y, TileGrid.FLAG_WATER)


## Is this tile one half of a two-tile dual carriageway, and if so, where is its
## twin? (1 = N, 2 = E, 3 = S, 4 = W; 0 = no.)
##
## The test, per axis: the corridor RUNS THROUGH on that axis, EXACTLY ONE
## lateral neighbour is road of the same class, and that neighbour runs through
## on the same axis too. Requiring exactly one is what keeps a crossing out: at
## an avenue-meets-avenue box both laterals are road, the tile pairs on neither
## axis, and it falls through to the junction rule where it belongs.
##
## Note where the class test is and is not applied. The LATERAL neighbour must
## match, or a street laid alongside an avenue would be adopted as its second
## carriageway. The two along-axis neighbours must only be ROAD. That asymmetry
## is load-bearing and was measured: `StarterCityLoader` stamps its road list in
## order and the last writer wins, so every avenue-meets-street crossing tile in
## the starter city ends up classed STREET. With the class test applied along
## the corridor too, that one tile broke the pairing of the avenue tile on
## either side of it — which turned them into junction boxes, deleted their
## centre lines and painted zebras across a through carriageway, sixteen times
## over in the founding city.
static func _pair_of(is_road: Dictionary, cls_of: Dictionary, t: Vector2i) -> int:
	var own := int(cls_of[t])
	var found := PAIR_NONE
	# axis 0: the corridor runs N-S, laterals are E/W (dir indices 1 and 3).
	# axis 1: the corridor runs E-W, laterals are N/S (dir indices 0 and 2).
	for axis in 2:
		var a0 := 0 if axis == 0 else 1
		var a1 := 2 if axis == 0 else 3
		if not is_road.has(t + DIRS[a0]) or not is_road.has(t + DIRS[a1]):
			continue
		var l0 := 1 if axis == 0 else 0
		var l1 := 3 if axis == 0 else 2
		var lateral := -1
		var count := 0
		# Unrolled: `for d in [l0, l1]` allocated a two-element Array per axis per
		# tile, which on the benchmark city is 6,264 Arrays per rebuild.
		if _same_class(is_road, cls_of, t + DIRS[l0], own):
			lateral = l0
			count += 1
		if _same_class(is_road, cls_of, t + DIRS[l1], own):
			lateral = l1
			count += 1
		if count != 1:
			continue
		var twin: Vector2i = t + DIRS[lateral]
		if not is_road.has(twin + DIRS[a0]) or not is_road.has(twin + DIRS[a1]):
			continue
		if found != PAIR_NONE:
			return PAIR_NONE   # both axes qualify: it is a box, not a pair
		found = lateral + 1
	return found


static func _same_class(is_road: Dictionary, cls_of: Dictionary, q: Vector2i,
		own: int) -> bool:
	return is_road.has(q) and int(cls_of[q]) == own


static func _popcount(mask: int) -> int:
	var n := 0
	for i in 4:
		if (mask & BIT[i]) != 0:
			n += 1
	return n


## A stable per-tile value on [0,1). A HASH, not a stream draw: doc 00 §5's RNG
## streams belong to the sim and a renderer that consumed one would move every
## state hash in the game.
static func _wear_seed(t: Vector2i) -> float:
	var h := (t.x * 73856093) ^ (t.y * 19349663)
	h = (h ^ (h >> 13)) * 1274126177
	return float((h & 0x7FFFFFFF) % 10007) / 10007.0


# ------------------------------------------------------------------ footways

## Kerb runs, MERGED. A tile emits at most four strips and four corner squares;
## strips that abut along the same kerb line are then welded into one instance,
## so a 20-tile avenue kerb is ONE box and not twenty. On the starter city that
## is the difference between ~1,500 instances and ~350.
##
## The trims are what let the merge be exact rather than approximate: where two
## kerbed sides of one tile meet, both strips give up `w` and a `w × w` corner
## square fills the gap. Nothing ever overlaps, so no two footway tops are
## coplanar and there is no z-fighting to tune away.
func _build_sidewalks(kerb_of: Dictionary, cls_of: Dictionary) -> void:
	var runs: Dictionary = {}      # key -> Array of [lo, hi]
	var meta: Dictionary = {}      # key -> {axis, fixed, w}
	var corners: Array = []        # [Vector3 centre, w]
	for t: Vector2i in _tiles:
		var kerb := int(kerb_of[t])
		if kerb == 0:
			continue
		var w := sidewalk_width(int(cls_of[t]))
		var x0 := float(t.x) * TILE_M
		var z0 := float(t.y) * TILE_M
		var x1 := x0 + TILE_M
		var z1 := z0 + TILE_M
		var hasN := (kerb & BIT[0]) != 0
		var hasE := (kerb & BIT[1]) != 0
		var hasS := (kerb & BIT[2]) != 0
		var hasW := (kerb & BIT[3]) != 0
		var x_lo := x0 + (w if hasW else 0.0)
		var x_hi := x1 - (w if hasE else 0.0)
		var z_lo := z0 + (w if hasN else 0.0)
		var z_hi := z1 - (w if hasS else 0.0)
		if hasN:
			_add_run(runs, meta, "X", z0, w, x_lo, x_hi)
		if hasS:
			_add_run(runs, meta, "X", z1 - w, w, x_lo, x_hi)
		if hasW:
			_add_run(runs, meta, "Z", x0, w, z_lo, z_hi)
		if hasE:
			_add_run(runs, meta, "Z", x1 - w, w, z_lo, z_hi)
		if hasN and hasW:
			corners.append([Vector2(x0, z0), w])
		if hasN and hasE:
			corners.append([Vector2(x1 - w, z0), w])
		if hasS and hasW:
			corners.append([Vector2(x0, z1 - w), w])
		if hasS and hasE:
			corners.append([Vector2(x1 - w, z1 - w), w])

	_runs.clear()
	var keys: Array = runs.keys()
	keys.sort()
	for key: int in keys:
		var spans: Array = runs[key]
		spans.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
		var row: Dictionary = meta[key]
		var cur: Array = []
		for span: Array in spans:
			if cur.is_empty():
				cur = [span[0], span[1]]
			elif span[0] <= cur[1] + 0.001:
				cur[1] = maxf(cur[1], span[1])
			else:
				_emit_run(row, cur)
				cur = [span[0], span[1]]
		if not cur.is_empty():
			_emit_run(row, cur)
	for entry: Array in corners:
		var at: Vector2 = entry[0]
		var w := float(entry[1])
		_runs.append({"axis": "C", "x": at.x, "z": at.y, "dx": w, "dz": w})

	var mm := _sidewalk.multimesh
	mm.instance_count = _runs.size()
	var height := sidewalk_top_m + 0.02
	for i in _runs.size():
		var run: Dictionary = _runs[i]
		var dx := float(run["dx"])
		var dz := float(run["dz"])
		mm.set_instance_transform(i, Transform3D(
				Basis.IDENTITY.scaled(Vector3(dx, height, dz)),
				Vector3(float(run["x"]) + dx * 0.5, sidewalk_top_m - height * 0.5,
						float(run["z"]) + dz * 0.5)))
	_sidewalk.custom_aabb = _cover(_tiles, -0.5, 1.0)


## The bucket key is an INT, not a formatted string. Up to four of these run per
## road tile per rebuild and `"%s|%.3f|%.3f" %` was 3.1 ms of the benchmark
## city's rebuild on its own. Both coordinates are centimetre-quantised, which
## is three orders of magnitude finer than anything that can share a kerb line.
func _add_run(runs: Dictionary, meta: Dictionary, axis: String, fixed: float,
		w: float, lo: float, hi: float) -> void:
	if hi - lo < 0.001:
		return
	var key := (0 if axis == "X" else 1) * 0x100000000 \
			+ int(roundf(fixed * 100.0)) * 0x10000 + int(roundf(w * 100.0))
	if not runs.has(key):
		runs[key] = []
		meta[key] = {"axis": axis, "fixed": fixed, "w": w}
	(runs[key] as Array).append([lo, hi])


func _emit_run(row: Dictionary, span: Array) -> void:
	var fixed := float(row["fixed"])
	var w := float(row["w"])
	if String(row["axis"]) == "X":
		_runs.append({"axis": "X", "x": float(span[0]), "z": fixed,
				"dx": float(span[1]) - float(span[0]), "dz": w})
	else:
		_runs.append({"axis": "Z", "x": fixed, "z": float(span[0]),
				"dx": w, "dz": float(span[1]) - float(span[0])})


## An explicit cover with headroom. Instance transforms do grow the automatic
## AABB, but both buffers are centimetres thin over hundreds of metres and a
## grazing Z0 camera can cull the whole sheet — §2.13's rule is that every
## MultiMesh carries one.
func _cover(tiles: Array, y_lo: float, y_hi: float) -> AABB:
	if tiles.is_empty():
		return AABB(Vector3.ZERO, Vector3.ONE)
	var lo: Vector2i = tiles[0]
	var hi: Vector2i = tiles[0]
	for raw: Variant in tiles:
		var t: Vector2i = raw
		lo = Vector2i(mini(lo.x, t.x), mini(lo.y, t.y))
		hi = Vector2i(maxi(hi.x, t.x), maxi(hi.y, t.y))
	return AABB(Vector3(float(lo.x) * TILE_M, y_lo, float(lo.y) * TILE_M),
			Vector3(float(hi.x - lo.x + 1) * TILE_M, y_hi - y_lo,
					float(hi.y - lo.y + 1) * TILE_M))


# ------------------------------------------------------------------ read side

## The y an asphalt instance is written at (its slab is centred on this, so the
## driving surface is `asphalt_top_m`). Exposed because a `--headless` run has
## the DUMMY rendering driver behind it and `MultiMesh.get_instance_transform`
## reads back identity there — a headless test cannot see what was uploaded, so
## anything a test needs to check is published from script side instead.
func asphalt_origin_y() -> float:
	return asphalt_top_m - asphalt_thickness_m * 0.5


## The `RoadGraph.graph_version` the live buffers were built from.
func built_version() -> int:
	return _built_version


func tile_count() -> int:
	return _tiles.size()


func sidewalk_instance_count() -> int:
	return _runs.size()


## The four channels uploaded for one tile, exactly as the shader receives them.
func pack_of(tile: Vector2i) -> Color:
	return _pack_of.get(tile, Color(0, 0, 0, 0))


## The merged footway rows: `{axis: "X"|"Z"|"C", x, z, dx, dz}` in metres.
func runs() -> Array:
	return _runs.duplicate(true)


func asphalt_node() -> MultiMeshInstance3D:
	return _asphalt


func sidewalk_node() -> MultiMeshInstance3D:
	return _sidewalk


## Two, city-wide, whatever the city is — see the class note.
func draw_calls() -> int:
	var n := 0
	if _asphalt != null and _asphalt.multimesh.instance_count > 0:
		n += 1
	if _sidewalk != null and _sidewalk.multimesh.instance_count > 0:
		n += 1
	return n
