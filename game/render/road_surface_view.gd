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
## ── `rebuild()` is a DIFF, not a pure function (§2.1.2a) ──────────────────
## A full pass is 18.3 ms on the benchmark city and it fires every time the
## player lays a road, so this view keeps last pass's classification and asks
## only what changed: 19.7 -> 4.87 ms on the benchmark city, 4.76 -> 1.18 ms on
## the founding one. The whole contract of a stateful diff is one sentence, and
## `tests/test_road_incremental.gd` property-tests it over random edit
## sequences: **after any sequence of edits both uploaded buffers are
## byte-identical to a from-scratch rebuild of the same city.** `force` is the
## pure function, and is what a sim swap takes.
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

## The MultiMesh buffer strides this view uploads through. Verified against the
## engine rather than assumed: `MultiMesh` packs TRANSFORM_3D as twelve floats
## (basis ROWS interleaved with the origin), then four for `use_colors` and four
## for `use_custom_data`, in that order. Asphalt carries custom data and no
## colour; the footway carries neither.
const ASPHALT_STRIDE := 16
const WALK_STRIDE := 12

## The asphalt shader's fragment ladder (`road_surface.gdshader`'s `detail`
## uniform): 2 FULL, 1 drops the wear terms, 0 also drops the zebra loop. This is
## the CEILING the preset authorises — `set_detail()` may lower the live value
## and may never raise it above this. Set from `data/render.json`
## (`presets.<name>.road_detail`, falling back to `road_surface.detail`) by
## `set_preset()`, which the shell calls the same way it calls `VehicleView`'s.
var detail_ceiling: int = 2
## What is actually in the material right now. Never above `detail_ceiling`.
var detail: int = 2

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
## …and the same for the incremental path: how many passes took the diff, and
## how many tiles the last one had to re-classify. A test that only checked the
## OUTPUT would pass with the diff quietly falling back to a full sweep.
var incremental_passes: int = 0
var last_dirty_tiles: int = 0
var last_pass_incremental: bool = false

# ------------------------------------------------- the diff's memory (§2.1.2)
#
# `rebuild()` used to be a pure function of (grid, graph) and is now a STATEFUL
# DIFF, because a full pass is 18.3 ms on the benchmark city and it fires on
# every road the player lays. Everything below is last pass's answer, kept so
# this pass can ask only what changed. `force` restores the pure-function
# behaviour and is what a sim swap (a mid-session load) takes.
#
# The invariant the tests hold this to is exact and it is the whole contract:
# **any sequence of edits leaves these buffers byte-identical to a from-scratch
# rebuild of the same city.** `tests/test_road_incremental.gd` property-tests it
# over random edit sequences on random cities.
var _is_road: Dictionary = {}     # Vector2i -> pass stamp (membership + set test)
var _cls_of: Dictionary = {}
var _mask_of: Dictionary = {}
var _kerb_of: Dictionary = {}
var _pair_map: Dictionary = {}
var _junction_map: Dictionary = {}
var _pass_no: int = 0
## Footway state, per bucket and per tile, so one tile's contribution can be
## pulled out of a kerb run without re-walking the city.
var _bucket: Dictionary = {}      # key -> {Vector2i tile: [lo, hi]}
var _bucket_meta: Dictionary = {} # key -> {axis, fixed, w}
var _bucket_out: Dictionary = {}  # key -> Array of run rows (the merged result)
var _spans_of: Dictionary = {}    # Vector2i tile -> Array[int] of bucket keys
var _corner_of: Dictionary = {}   # Vector2i tile -> Array of run rows
var _corner_order: Array[Vector2i] = []
var _corners_dirty := true
## What was last handed to the RenderingServer, float for float.
var _asphalt_buf := PackedFloat32Array()
var _walk_buf := PackedFloat32Array()


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
	detail_ceiling = clampi(int(cfg.get("detail", 2)), 0, 2)
	detail = detail_ceiling
	_build_nodes(render_data)


## The preset's ceiling for the fragment ladder, read the same way
## `VehicleView.set_preset` reads its own rows. A preset without a `road_detail`
## row keeps `road_surface.detail`, so adding the row is opt-in per preset.
func set_preset(preset: String, render_data: Dictionary) -> void:
	var row: Dictionary = (render_data.get("presets", {}) as Dictionary).get(preset, {})
	detail_ceiling = clampi(int(row.get("road_detail", cfg.get("detail", 2))), 0, 2)
	set_detail(detail_ceiling)


## Lower (or restore) the live rung. Clamped to `detail_ceiling` so the governor
## can only ever spend quality, never invent it — the same one-way contract
## `PerfGovernor` has with every other knob.
func set_detail(level: int) -> void:
	var wanted := clampi(level, 0, detail_ceiling)
	if wanted == detail:
		return
	detail = wanted
	if _asphalt != null and _asphalt.material_override is ShaderMaterial:
		(_asphalt.material_override as ShaderMaterial).set_shader_parameter("detail", detail)


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
	mat.set_shader_parameter("detail", detail_ceiling)
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
	# The diff needs a graph (it keys off `graph_version` and off the graph's own
	# membership map) and a previous pass to diff against. `force` throws the
	# memory away, which is what a swapped sim requires.
	if force or graph == null or _is_road.is_empty():
		_rebuild_full(grid, graph)
	else:
		_rebuild_incremental(grid, graph)
	_upload()
	return _tiles.size()


## The original pass, unchanged in what it computes: classify the whole city and
## write both buffers. Still the boot path, still what `force` takes, and still
## the answer every incremental pass is checked against.
func _rebuild_full(grid: TileGrid, graph: RoadGraph) -> void:
	var facts := classify(grid, graph)
	_tiles = facts["tiles"]
	_cls_of = facts["cls"]
	_mask_of = facts["mask"]
	_kerb_of = facts["kerb"]
	_pair_map = facts["pair"]
	_junction_map = facts["junction"]
	_pass_no += 1
	_is_road = {}
	_pack_of.clear()
	_slot_of.clear()
	for i in _tiles.size():
		var t: Vector2i = _tiles[i]
		_is_road[t] = _pass_no
		_slot_of[t] = i
	# Crosswalks. A leg only gets a zebra if what it leads to is NOT another
	# junction tile — which is what stops a 2x2 avenue crossing from painting
	# four zebras into its own middle. Its own loop because it reads the
	# junction verdict of NEIGHBOURS, which the loop above is still deciding.
	for t: Vector2i in _tiles:
		_pack_of[t] = _pack_for(t)
	_set_cover()
	_full_sidewalks()
	last_dirty_tiles = _tiles.size()
	last_pass_incremental = false


## An explicit cover on BOTH layers. `_cover` walks every road tile, so it is
## re-taken only when the road layer's extent could have moved.
func _set_cover() -> void:
	var cover := _cover(_tiles, -0.5, 1.0)
	_asphalt.custom_aabb = cover
	_sidewalk.custom_aabb = cover


## The four channels one tile uploads. Reads the persistent classification, so
## the full and incremental paths cannot disagree about what a pack IS.
func _pack_for(t: Vector2i) -> Color:
	var mask := int(_mask_of[t])
	var cw := 0
	if bool(_junction_map[t]):
		for d in 4:
			if (mask & BIT[d]) != 0 and not bool(_junction_map.get(t + DIRS[d], false)):
				cw |= BIT[d]
	var cls_code := 1 if int(_cls_of[t]) == TileGrid.ROAD_AVENUE else 0
	var packed := float(cls_code) + 2.0 * float(_pair_map[t]) + 16.0 * float(cw)
	return Color(float(mask), float(_kerb_of[t]), packed, _wear_seed(t))


## ── the dirty-tile path (§2.1.2's filed open question 2) ──────────────────
##
## A full pass is 18.3 ms on the benchmark city and it fires every time the
## player lays a road, which is exactly when a frame must not be dropped. What
## makes the diff possible is that every per-tile fact has a bounded dependency
## radius, and they are worth stating because the expansion below IS them:
##
##   `mask` / `kerb`   read `is_road` at r1
##   `pair`            reads `is_road` at r2 (the twin's own through-test) and
##                     `cls` at r1
##   `junction`        follows from `pair` and the degree, so r2 / r1
##   the crosswalk mask reads `junction` at r1, so r3 / r2
##
## Manhattan **r = 3** therefore covers every fact that a single-tile change can
## move, and the seeds are the tiles whose MEMBERSHIP or CLASS moved.
##
## Both seed sets are read straight off the graph rather than from
## `road_graph_changed`'s `added_edges` / `removed_edges`, and that is a
## measured decision, not laziness: `RoadGraph.apply_edits` excludes from
## `added_edges` any edge it deleted and recreated with the SAME id and tile
## list (its own id-stability rule), and an upgrade in place is exactly that
## case — the edge keeps its id while `_edge_class` recomputes underneath it.
## An edge-delta-seeded diff would silently miss every road upgrade. The two
## sweeps that replace it are the O(N) floor of this pass and cost 1.0 ms
## (`road_tiles_sorted`) + 2.9 ms (the class sweep) on the benchmark city.
func _rebuild_incremental(grid: TileGrid, graph: RoadGraph) -> void:
	_pass_no += 1
	var new_tiles := _road_tiles(grid, graph)
	var seeds: Array[Vector2i] = []

	# 1. Membership, by stamp: one sweep finds the additions, and the removals
	#    only cost a second sweep when the counts say there were some.
	for raw: Variant in new_tiles:
		var t: Vector2i = raw
		if not _is_road.has(t):
			seeds.append(t)
		_is_road[t] = _pass_no
	var removed: Array[Vector2i] = []
	if _is_road.size() != new_tiles.size():
		for raw: Variant in _is_road.keys():
			if int(_is_road[raw]) != _pass_no:
				removed.append(raw)
		removed.sort()
		for t: Vector2i in removed:
			_is_road.erase(t)
			seeds.append(t)
	var membership_moved := not seeds.is_empty()

	# 2. Class. See the note above for why this is a sweep and not a delta.
	for raw: Variant in new_tiles:
		var t: Vector2i = raw
		var live := _class_of(grid, graph, t)
		if int(_cls_of.get(t, -1)) != live:
			_cls_of[t] = live
			seeds.append(t)
	for t: Vector2i in removed:
		_cls_of.erase(t)
		_mask_of.erase(t)
		_kerb_of.erase(t)
		_pair_map.erase(t)
		_junction_map.erase(t)
		_pack_of.erase(t)

	# 3. Expand to the dependency ball and re-classify what is inside it.
	var dirty: Dictionary = {}
	for s: Vector2i in seeds:
		for dz in range(-3, 4):
			var span := 3 - absi(dz)
			for dx in range(-span, span + 1):
				dirty[s + Vector2i(dx, dz)] = true
	var live_dirty: Array[Vector2i] = []
	for raw: Variant in dirty:
		var t: Vector2i = raw
		if _is_road.has(t):
			live_dirty.append(t)
	for t: Vector2i in live_dirty:
		var mask := 0
		var kerb := 0
		var degree := 0
		for i in 4:
			var q: Vector2i = t + DIRS[i]
			if _is_road.has(q):
				mask |= BIT[i]
				degree += 1
			elif not _is_water(grid, q):
				kerb |= BIT[i]
		_mask_of[t] = mask
		_kerb_of[t] = kerb
		var pair := _pair_of(_is_road, _cls_of, t) if degree >= 3 else PAIR_NONE
		_pair_map[t] = pair
		_junction_map[t] = pair == PAIR_NONE and degree >= 3
	# The crosswalk mask reads the junction verdict of NEIGHBOURS, so it can only
	# be settled once every dirty tile above has one.
	for t: Vector2i in live_dirty:
		_pack_of[t] = _pack_for(t)

	if membership_moved:
		_tiles = new_tiles
		_slot_of.clear()
		for i in _tiles.size():
			_slot_of[_tiles[i]] = i
		_set_cover()

	_patch_sidewalks(live_dirty, removed)
	incremental_passes += 1
	last_dirty_tiles = live_dirty.size()
	last_pass_incremental = true


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
func _full_sidewalks() -> void:
	_bucket.clear()
	_bucket_meta.clear()
	_bucket_out.clear()
	_spans_of.clear()
	_corner_of.clear()
	_corners_dirty = true
	var touched: Dictionary = {}
	for t: Vector2i in _tiles:
		_insert_footways(t, touched)
	for key: int in touched:
		_merge_bucket(key)
	_emit_runs()


## The same job for a handful of tiles. `dirty` are the tiles whose kerb mask or
## class may have moved; `gone` are tiles that stopped being road. Only the
## BUCKETS those tiles touch are re-merged — a 20-tile avenue kerb three blocks
## away is not re-sorted because somebody paved a cul-de-sac.
func _patch_sidewalks(dirty: Array[Vector2i], gone: Array[Vector2i]) -> void:
	var touched: Dictionary = {}
	for t: Vector2i in gone:
		_remove_footways(t, touched)
	for t: Vector2i in dirty:
		_remove_footways(t, touched)
		_insert_footways(t, touched)
	for key: int in touched:
		_merge_bucket(key)
	_emit_runs()


func _insert_footways(t: Vector2i, touched: Dictionary) -> void:
	var kerb := int(_kerb_of.get(t, 0))
	if kerb == 0:
		return
	var w := sidewalk_width(int(_cls_of[t]))
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
	var keys: Array[int] = []
	if hasN:
		_add_run(keys, touched, t, "X", z0, w, x_lo, x_hi)
	if hasS:
		_add_run(keys, touched, t, "X", z1 - w, w, x_lo, x_hi)
	if hasW:
		_add_run(keys, touched, t, "Z", x0, w, z_lo, z_hi)
	if hasE:
		_add_run(keys, touched, t, "Z", x1 - w, w, z_lo, z_hi)
	if not keys.is_empty():
		_spans_of[t] = keys
	var corners: Array = []
	if hasN and hasW:
		corners.append(_corner_row(x0, z0, w))
	if hasN and hasE:
		corners.append(_corner_row(x1 - w, z0, w))
	if hasS and hasW:
		corners.append(_corner_row(x0, z1 - w, w))
	if hasS and hasE:
		corners.append(_corner_row(x1 - w, z1 - w, w))
	if not corners.is_empty():
		_corner_of[t] = corners
		_corners_dirty = true


func _remove_footways(t: Vector2i, touched: Dictionary) -> void:
	var keys: Variant = _spans_of.get(t)
	if keys is Array:
		for key: int in (keys as Array):
			var entries: Variant = _bucket.get(key)
			if entries is Dictionary:
				(entries as Dictionary).erase(t)
			touched[key] = true
		_spans_of.erase(t)
	if _corner_of.has(t):
		_corner_of.erase(t)
		_corners_dirty = true


static func _corner_row(x: float, z: float, w: float) -> Dictionary:
	return {"axis": "C", "x": x, "z": z, "dx": w, "dz": w}


## The bucket key is an INT, not a formatted string. Up to four of these run per
## road tile per rebuild and `"%s|%.3f|%.3f" %` was 3.1 ms of the benchmark
## city's rebuild on its own. Both coordinates are centimetre-quantised, which
## is three orders of magnitude finer than anything that can share a kerb line.
##
## A bucket holds `{tile: [lo, hi]}` rather than a bare list of spans, which is
## what lets one tile's contribution be pulled back out later. One tile can
## reach a given bucket at most once — a bucket is (axis, fixed, w) and a tile's
## N and S strips sit `TILE_M - w` apart — so nothing is lost by keying on it.
func _add_run(keys: Array[int], touched: Dictionary, t: Vector2i, axis: String,
		fixed: float, w: float, lo: float, hi: float) -> void:
	if hi - lo < 0.001:
		return
	var key := (0 if axis == "X" else 1) * 0x100000000 \
			+ int(roundf(fixed * 100.0)) * 0x10000 + int(roundf(w * 100.0))
	if not _bucket.has(key):
		_bucket[key] = {}
		_bucket_meta[key] = {"axis": axis, "fixed": fixed, "w": w}
	(_bucket[key] as Dictionary)[t] = [lo, hi]
	keys.append(key)
	touched[key] = true


## Sort one bucket's spans and weld the abutting ones. Sorting by `lo` is what
## makes the result independent of the order the spans went in, which is what
## makes an incremental pass and a from-scratch pass agree float for float.
func _merge_bucket(key: int) -> void:
	var entries: Variant = _bucket.get(key)
	if not (entries is Dictionary) or (entries as Dictionary).is_empty():
		_bucket.erase(key)
		_bucket_meta.erase(key)
		_bucket_out.erase(key)
		return
	var spans: Array = (entries as Dictionary).values()
	spans.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	var row: Dictionary = _bucket_meta[key]
	var out: Array = []
	var cur: Array = []
	for span: Array in spans:
		if cur.is_empty():
			cur = [span[0], span[1]]
		elif span[0] <= cur[1] + 0.001:
			cur[1] = maxf(cur[1], span[1])
		else:
			out.append(_run_row(row, cur))
			cur = [span[0], span[1]]
	if not cur.is_empty():
		out.append(_run_row(row, cur))
	_bucket_out[key] = out


## `_runs` in its published order: every merged kerb run in ascending bucket-key
## order, then the corner squares in (y, x) tile order — which is `_tiles`'
## order, so this is the order the pre-diff pass emitted and the shader-visible
## instance layout does not move.
func _emit_runs() -> void:
	_runs.clear()
	var keys: Array = _bucket_out.keys()
	keys.sort()
	for key: int in keys:
		for row: Dictionary in (_bucket_out[key] as Array):
			_runs.append(row)
	if _corners_dirty:
		_corner_order.clear()
		var tiles: Array = _corner_of.keys()
		tiles.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
			return a.y < b.y if a.y != b.y else a.x < b.x)
		for t: Vector2i in tiles:
			_corner_order.append(t)
		_corners_dirty = false
	for t: Vector2i in _corner_order:
		for row: Dictionary in (_corner_of[t] as Array):
			_runs.append(row)


static func _run_row(row: Dictionary, span: Array) -> Dictionary:
	var fixed := float(row["fixed"])
	var w := float(row["w"])
	if String(row["axis"]) == "X":
		return {"axis": "X", "x": float(span[0]), "z": fixed,
				"dx": float(span[1]) - float(span[0]), "dz": w}
	return {"axis": "Z", "x": fixed, "z": float(span[0]),
			"dx": w, "dz": float(span[1]) - float(span[0])}


# -------------------------------------------------------------------- upload

## ONE `MultiMesh.buffer` write per layer, from a PackedFloat32Array this view
## keeps between passes.
##
## Note the deliberate asymmetry with the per-frame layers (`VehicleView`,
## `ConstructionVehicleView`), which keep their per-instance setters: measured
## on this build, `set_instance_transform` + `set_instance_color` +
## `set_instance_custom_data` costs **0.031 ms per 200 instances** against
## **0.064 ms** to pack the same 200 rows into a PackedFloat32Array in GDScript,
## and the `mm.buffer =` write itself is 0.003 ms — the C++ setters win because
## each is one binding call around a memcpy, while packing is twenty scripted
## float writes. What the buffer buys HERE is not speed (it costs ~0.1 ms on the
## benchmark city's 3,132 tiles) but the CONTRACT: this array is literally what
## the server holds, so `tests/test_road_incremental.gd` can compare an
## incremental pass against a from-scratch one byte for byte instead of
## comparing a model of it.
func _upload() -> void:
	var n := _tiles.size()
	var mm := _asphalt.multimesh
	# Only when it MOVED: assigning `instance_count` reallocates the server-side
	# buffer, and the common incremental pass (a class change, a crosswalk mask)
	# leaves the tile count exactly where it was.
	if mm.instance_count != n:
		mm.instance_count = n
	_asphalt_buf.resize(n * ASPHALT_STRIDE)
	var half := TILE_M * 0.5
	var y := asphalt_top_m - asphalt_thickness_m * 0.5
	var o := 0
	for t: Vector2i in _tiles:
		var d: Color = _pack_of[t]
		_asphalt_buf[o] = 1.0
		_asphalt_buf[o + 1] = 0.0
		_asphalt_buf[o + 2] = 0.0
		_asphalt_buf[o + 3] = float(t.x) * TILE_M + half
		_asphalt_buf[o + 4] = 0.0
		_asphalt_buf[o + 5] = 1.0
		_asphalt_buf[o + 6] = 0.0
		_asphalt_buf[o + 7] = y
		_asphalt_buf[o + 8] = 0.0
		_asphalt_buf[o + 9] = 0.0
		_asphalt_buf[o + 10] = 1.0
		_asphalt_buf[o + 11] = float(t.y) * TILE_M + half
		_asphalt_buf[o + 12] = d.r
		_asphalt_buf[o + 13] = d.g
		_asphalt_buf[o + 14] = d.b
		_asphalt_buf[o + 15] = d.a
		o += ASPHALT_STRIDE
	if n > 0:
		mm.buffer = _asphalt_buf

	var walk := _sidewalk.multimesh
	var runs := _runs.size()
	if walk.instance_count != runs:
		walk.instance_count = runs
	_walk_buf.resize(runs * WALK_STRIDE)
	var height := sidewalk_top_m + 0.02
	var oy := sidewalk_top_m - height * 0.5
	o = 0
	for row: Dictionary in _runs:
		var dx := float(row["dx"])
		var dz := float(row["dz"])
		_walk_buf[o] = dx
		_walk_buf[o + 1] = 0.0
		_walk_buf[o + 2] = 0.0
		_walk_buf[o + 3] = float(row["x"]) + dx * 0.5
		_walk_buf[o + 4] = 0.0
		_walk_buf[o + 5] = height
		_walk_buf[o + 6] = 0.0
		_walk_buf[o + 7] = oy
		_walk_buf[o + 8] = 0.0
		_walk_buf[o + 9] = 0.0
		_walk_buf[o + 10] = dz
		_walk_buf[o + 11] = float(row["z"]) + dz * 0.5
		o += WALK_STRIDE
	if runs > 0:
		walk.buffer = _walk_buf


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


## The exact float arrays last handed to the RenderingServer, asphalt and
## footway. This is not a model of the upload — it IS the upload (`_upload`
## writes these two arrays and then assigns them to `MultiMesh.buffer`), which
## is what lets the incremental path be checked byte for byte against a
## from-scratch one on a `--headless` run, where the server itself reads back
## nothing.
func asphalt_buffer() -> PackedFloat32Array:
	return _asphalt_buf.duplicate()


func sidewalk_buffer() -> PackedFloat32Array:
	return _walk_buf.duplicate()


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
