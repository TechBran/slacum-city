class_name FloodView
extends Node3D
## Standing water, drawn (doc 07 §2.4, doc 11 §2.9b — defect A91-D-26).
##
## The audit's sentence for this file is the whole brief: *"the sim half ships
## and the player never sees it."* `sim/weather/flood_field.gd` integrates
## `depth_mm` on the utilities cadence and emits `flood_level_changed` on every
## band crossing — 460 of them in a two-real-hour soak — and before this file
## **nothing in the tree matched that type**. `WeatherFX` matches three event
## types and none of them is this one; `main.gd`'s translator has no arm; it is
## in neither `data/ui.json.event_log.events` nor
## `data/notifications.json.bindings`. The only way a player learned a street
## had flooded was `road_closed_flood`, which fires at the 350 mm band and
## leaves the three bands below it invisible.
##
## ── why a new file and not a `WeatherFX` arm ──────────────────────────────
## Doc 07 §2.4's own note proposes the cheap fix: raise `sc_wetness` on the
## affected tiles. It cannot be done there and it would not be right if it
## could. `sc_wetness` is a **project shader global** — one float for the whole
## world — and `WeatherFX` owns it as the city-wide rain integrator (§2.9). A
## flood is the opposite shape of data: it is *per land block*, it outlives the
## rain that caused it by hours (drain is 40 mm/h against an inflow that stops
## the moment the segment does), and two blocks a hundred metres apart are
## routinely at different bands. Folding it into the global would either flood
## the whole city or flood none of it. So the flood is GEOMETRY — one MultiMesh
## bucket of 8 m quads over the road tiles that are actually wet — and
## `WeatherFX` is left holding exactly what it held before.
##
## ── one draw call, and the tiles are the road's ───────────────────────────
## Doc 07 §2.4 is explicit that *only road tiles* accumulate, so this view draws
## the flooded cell's ROAD tiles and not a 128 m blue square over the block —
## which would put standing water through the middle of every building on it.
## All of them live in one `MultiMeshInstance3D` with one material, so the
## layer is **+1 draw call while any water is standing and +0 when the city is
## dry** (the node hides itself). `custom_aabb` covers the world, because a
## bucket whose instances move in Y as the water rises must never be culled by
## a bounds box that was computed dry.
##
## ── the two floats ────────────────────────────────────────────────────────
## Each instance carries `INSTANCE_CUSTOM = (water01, wet01, tile_seed, 0)`:
##
##   * `water01` is doc 07's own `flood_saturation` — `depth_mm / 350`, the
##     impassable threshold, read out of `data/weather.json` rather than
##     restated here — eased on a short tau so a band crossing is a rise and
##     not a step.
##   * `wet01` is the DARK-WET MEMORY. It rises with the water and falls on a
##     tau twenty-five times longer, so a street that has just drained stays
##     black and glossy for the best part of a minute. That tail is the
##     difference between "the water went away" and "there was a flood here",
##     and it is the same trick §2.9's wetness integrator plays with its 25 s
##     up / 90 s down asymmetry, applied per tile.
##
## An instance stays in the buffer while EITHER is above `min_visible`, which is
## what keeps the halo drawn after the water has gone.
##
## ── deterministic, and re-derivable on load ───────────────────────────────
## Live, this view is driven **entirely by the event stream** — `apply_event`
## takes `flood_level_changed` verbatim, and every tile's appearance is a
## function of (cell depth, tile coordinates), never of an RNG or a frame
## counter. The per-tile seed is `hash(tx, tz)`, so the same city floods the
## same way twice.
##
## On LOAD there is no event to wait for, and doc 07 answers the question
## itself: the flood field is **persisted**, in the `weather` save section
## (`WeatherSystem.serialize()` → `"flood": flood.serialize()` → `{"tiles":
## {cell: depth_mm}}`), and `FloodField.depth_at()` / the `depth_mm` dictionary
## are the query. So this view **persists nothing of its own** — a render-side
## save section could only ever disagree with the sim's — and the shell calls
## `prime()` with that dictionary after a load or a chunk rebuild. A city
## resumed at the peak of a flood therefore shows the flood on its first frame,
## instead of waiting for the next band crossing (which, on a draining field,
## can be a game-hour away).
##
## Reads doc 07's table for one number and doc 11's `data/render.json` for the
## rest; mutates nothing; owns no constant.

const WEATHER_DATA := "res://data/weather.json"
const SHADER := "res://game/shaders/flood.gdshader"

## MultiMesh buffer stride: TRANSFORM_3D is twelve floats (basis ROWS
## interleaved with the origin) and `use_custom_data` adds four. No colours.
const STRIDE := 16

## Doc 07 §2.4's `flood_saturation` divisor, used only if `data/weather.json`
## cannot be read at all. The real number comes from the table.
const FULL_DEPTH_FALLBACK := 350.0

var tile_m: float = 8.0
var base_y_m: float = 0.11
## The depth that reads as 1.0 — doc 07's impassable threshold, from its table.
var full_depth_mm: float = FULL_DEPTH_FALLBACK

## Published state, so tests and the profiler assert against this view rather
## than reaching into the MultiMesh.
var detail_ceiling: int = 2
var detail: int = 2

var _cfg: Dictionary = {}
var _presets: Dictionary = {}
var _node: MultiMeshInstance3D
var _mm: MultiMesh
var _material: ShaderMaterial
var _mirror: PackedFloat32Array = PackedFloat32Array()

## cell key ("B1,2" or "17,44") -> {"water": float, "wet": float, "target": float}
var _cells: Dictionary = {}
## cell key -> Array[Vector2i], the road tiles this cell paints. Built once per
## road rebuild; a cell with no roads yet tracks its level and draws nothing.
var _tiles_of_cell: Dictionary = {}
## The tiles currently in the buffer, in upload order, and their owning cell.
var _slots: Array[Vector2i] = []
var _slot_cell: Array[String] = []
var _slot_dirty := false
var _set_dirty := false

var _rise_tau: float = 1.1
var _fall_tau: float = 2.6
var _wet_rise_tau: float = 0.8
var _wet_dry_tau: float = 20.0
var _wet_floor: float = 0.55
var _min_visible: float = 0.02

## Instrumentation, the way `RoadSurfaceView.rebuild_passes` is: how many times
## the drawn set was recomputed, and how many buffer uploads went out. A test
## that only checked the picture would pass with this uploading every frame.
var set_passes: int = 0
var uploads: int = 0


# ---------------------------------------------------------------------- boot

func setup(render_data: Dictionary, preset := "balanced") -> void:
	# The node itself never moves, so a child's `position` IS world space — and
	# `position` works outside the scene tree, which `global_position` does not.
	# That is what lets the whole integrator be exercised headless.
	transform = Transform3D.IDENTITY
	_cfg = render_data.get("flood", {})
	tile_m = float(_cfg.get("tile_m", 8.0))
	base_y_m = float(_cfg.get("base_y_m", 0.11))
	_rise_tau = float(_cfg.get("rise_tau_s", 1.1))
	_fall_tau = float(_cfg.get("fall_tau_s", 2.6))
	_wet_rise_tau = float(_cfg.get("wet_rise_tau_s", 0.8))
	_wet_dry_tau = float(_cfg.get("wet_dry_tau_s", 20.0))
	_wet_floor = float(_cfg.get("wet_floor", 0.55))
	_min_visible = float(_cfg.get("min_visible", 0.02))
	full_depth_mm = _read_full_depth_mm()
	_build_bucket(render_data)
	set_preset(preset)


## Doc 07 owns the band table and this view refuses to restate it: the depth
## that reads as "the street is gone" is the LAST threshold in
## `data/weather.json`'s `flood.thresholds`, which is the same 350 mm
## `FloodField.flood_saturation()` divides by. One number, one owner, no drift.
func _read_full_depth_mm() -> float:
	if not ResourceLoader.exists(WEATHER_DATA):
		return FULL_DEPTH_FALLBACK
	var doc: Dictionary = StarterCityLoader.read_json(WEATHER_DATA)
	var thresholds: Array = (doc.get("flood", {}) as Dictionary).get("thresholds", [])
	if thresholds.is_empty():
		return FULL_DEPTH_FALLBACK
	var last: Dictionary = thresholds[thresholds.size() - 1]
	return maxf(1.0, float(last.get("depth_mm", FULL_DEPTH_FALLBACK)))


func _build_bucket(render_data: Dictionary) -> void:
	# Read before the material is built, because a clone with no shader on it
	# still has a preset ladder and still has to answer `detail`.
	_presets = render_data.get("presets", {})
	detail_ceiling = int(_cfg.get("detail", 2))
	detail = detail_ceiling
	_mm = MultiMesh.new()
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	_mm.use_custom_data = true
	var quad := PlaneMesh.new()
	quad.size = Vector2(tile_m, tile_m)
	_mm.mesh = quad
	_mm.instance_count = 0
	_mm.visible_instance_count = 0
	_material = _make_material()
	if _material != null:
		quad.material = _material
	_node = MultiMeshInstance3D.new()
	_node.name = "Flood"
	_node.multimesh = _mm
	_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# World-sized, because the sheet LIFTS as the water rises: a bounds box
	# computed on a dry city would cull the flood at exactly the depth that
	# matters. 112 tiles x 8 m is doc 09's whole map.
	var span := float(TileGrid.SIZE) * tile_m
	_node.custom_aabb = AABB(Vector3(0.0, -1.0, 0.0), Vector3(span, 3.0, span))
	_node.visible = false
	add_child(_node)


func _make_material() -> ShaderMaterial:
	if not ResourceLoader.exists(SHADER):
		return null
	var mat := ShaderMaterial.new()
	mat.shader = load(SHADER)
	for key in ["deep_color", "shallow_color", "wet_color", "sky_color",
			"night_glow_color"]:
		if _cfg.has(key):
			mat.set_shader_parameter(key, Color(String(_cfg[key])))
	for key in ["rise_m", "water_alpha", "wet_alpha", "puddle_scale_m",
			"puddle_contrast", "edge_softness", "coverage_gamma", "ripple_scale_m",
			"ripple_speed", "ripple_amp", "wind_gain", "sparkle_gain",
			"sparkle_power", "base_roughness", "base_specular", "rain_chop_gain",
			"night_mult", "night_lift", "night_sky_blend", "night_sky_gain",
			"night_glow",
			"fresnel_power", "fresnel_gain", "overlay_desaturate"]:
		if _cfg.has(key):
			mat.set_shader_parameter(key, float(_cfg[key]))
	mat.set_shader_parameter("detail", detail)
	return mat


## Doc 11 §2.13's preset switch. The CEILING moves; `set_detail` may lower the
## live value below it and may never raise it above — the same contract
## `RoadSurfaceView` holds for its own fragment ladder.
##
## `render_data` is optional and exists only so the shell can call this with the
## same two arguments it hands `RoadSurfaceView`, `VehicleView` and
## `ConstructionVehicleView` — one call shape for every per-layer preset seed.
func set_preset(name: String, render_data: Dictionary = {}) -> void:
	if render_data.has("presets"):
		_presets = render_data["presets"]
	var preset: Dictionary = _presets.get(name, _presets.get("balanced", {}))
	detail_ceiling = int(preset.get("flood_detail", _cfg.get("detail", 2)))
	set_detail(detail_ceiling)


func set_detail(value: int) -> void:
	detail = clampi(value, 0, detail_ceiling)
	if _material != null:
		_material.set_shader_parameter("detail", detail)


# ------------------------------------------------------------------ geometry

## Cache which road tiles each flood cell paints. Call it whenever doc 10's
## road graph has been restamped — the same moment the shell rebuilds
## `RoadSurfaceView` — because a street laid across a low block is a street that
## can now flood.
##
## Doc 07 registers flood cells per LAND BLOCK (`FloodField.register_block`,
## 16x16 tiles), so a cell key is `"B<bx>,<bz>"`; a per-tile registration
## (`register_tile`) keys `"<tx>,<tz>"` and is resolved lazily in `_tiles_for`.
func rebuild(grid: TileGrid) -> void:
	set_passes += 1
	_tiles_of_cell.clear()
	if grid == null:
		_set_dirty = true
		return
	for z in TileGrid.SIZE:
		for x in TileGrid.SIZE:
			if not grid.has_flag(x, z, TileGrid.FLAG_ROAD):
				continue
			var key := FloodField.block_key_of(x / FloodField.BLOCK_TILES,
					z / FloodField.BLOCK_TILES)
			if not _tiles_of_cell.has(key):
				_tiles_of_cell[key] = []
			(_tiles_of_cell[key] as Array).append(Vector2i(x, z))
	_set_dirty = true


## The tiles a cell paints. Block keys come from `rebuild`'s sweep; a bare tile
## key is its own single tile, which is what doc 07's `register_tile` means.
func _tiles_for(key: String) -> Array:
	if _tiles_of_cell.has(key):
		return _tiles_of_cell[key]
	if key.begins_with("B"):
		return []
	var parts := key.split(",")
	if parts.size() != 2:
		return []
	var tile := [Vector2i(int(parts[0]), int(parts[1]))]
	_tiles_of_cell[key] = tile
	return tile


# --------------------------------------------------------------------- events

## Feed a drained sim batch. Returns true if anything flood-shaped was in it.
func feed_events(batch: Array) -> bool:
	var touched := false
	for event: Variant in batch:
		if typeof(event) == TYPE_DICTIONARY and apply_event(event):
			touched = true
	return touched


func apply_event(e: Dictionary) -> bool:
	if StringName(String(e.get("type", &""))) != &"flood_level_changed":
		return false
	set_cell_depth(String(e.get("cell", "")), float(e.get("depth_mm", 0.0)))
	return true


## Every block the layer COULD paint — the keys `rebuild` found road inside.
##
## Deliberately not `cell_keys()`, which is a different set and already exists:
## that one lists the cells the view is currently TRACKING (`_cells`, populated
## as depths arrive), and at boot on a dry city it is empty. This one is the
## static capability — what a flood could ever wet — which is what the shell's
## `--flood=<mm>` lever needs to fill. Public for the same reason
## `set_cell_depth` is: the dev levers drive the view this way, and asking the
## layer beats a caller re-deriving doc 07's block arithmetic.
func floodable_cell_keys() -> Array:
	var keys := _tiles_of_cell.keys()
	keys.sort()
	return keys


## Re-derive the whole field from doc 07's persisted state: `cell key ->
## depth_mm`, i.e. `WeatherSystem.flood.depth_mm` verbatim. The load path, the
## attach path, and the only path that does not need an event to have happened.
## Cells the dictionary does not mention are draining to dry, not left standing.
func prime(depths: Dictionary) -> void:
	for key: Variant in _cells:
		if not depths.has(key):
			(_cells[key] as Dictionary)["target"] = 0.0
	for key: Variant in depths:
		set_cell_depth(String(key), float(depths[key]))


## One cell's level, in doc 07's millimetres. Public because the shell's dev
## levers and the tests both drive the view this way, and because it is the
## exact shape both the event and the persisted field arrive in.
func set_cell_depth(key: String, depth_mm: float) -> void:
	if key == "":
		return
	var target := clampf(depth_mm / full_depth_mm, 0.0, 1.0)
	var rec: Dictionary = _cells.get(key, {})
	if rec.is_empty():
		rec = {"water": 0.0, "wet": 0.0, "target": target, "drawn": false}
		_cells[key] = rec
		_set_dirty = true
	else:
		rec["target"] = target
		if _is_visible(rec) != bool(rec["drawn"]):
			_set_dirty = true


## Snap every cell to its target with no easing — the load path's companion, so
## a resumed city's first frame already shows the water at its real depth
## instead of rising into it over two seconds.
func snap() -> void:
	for key: Variant in _cells:
		var rec: Dictionary = _cells[key]
		rec["water"] = float(rec["target"])
		rec["wet"] = _wet_target(float(rec["target"]))
	_set_dirty = true
	_recompute_set()
	_upload()


# ------------------------------------------------------------------ per frame

## `delta` is real seconds. Nothing here reads the sim; the eased values are a
## pure function of (last value, target, delta).
func refresh(delta: float) -> void:
	var moved := false
	for key: Variant in _cells:
		var rec: Dictionary = _cells[key]
		var target := float(rec["target"])
		var water := float(rec["water"])
		var tau := _rise_tau if target > water else _fall_tau
		var next := water + (target - water) * (1.0 - exp(-delta / maxf(0.001, tau)))
		if absf(target - next) < 0.0005:
			next = target
		if not is_equal_approx(next, water):
			rec["water"] = next
			moved = true
		# The dark-wet memory chases the water up quickly and lets go slowly.
		var wet := float(rec["wet"])
		var wet_target := _wet_target(next)
		var wet_tau := _wet_rise_tau if wet_target > wet else _wet_dry_tau
		var wet_next := wet + (wet_target - wet) \
				* (1.0 - exp(-delta / maxf(0.001, wet_tau)))
		if absf(wet_target - wet_next) < 0.0005:
			wet_next = wet_target
		if not is_equal_approx(wet_next, wet):
			rec["wet"] = wet_next
			moved = true
		# A cell that crossed the visibility floor in either direction is the
		# ONLY thing that changes the drawn set — a flood that is merely
		# deepening keeps exactly the tiles it already had. Checked here, on a
		# value already in hand, rather than by re-walking the slot list.
		if _is_visible(rec) != bool(rec["drawn"]):
			_set_dirty = true
	if _set_dirty:
		_recompute_set()
	if moved or _slot_dirty:
		_upload()


## A tile with water on it is fully soaked; a tile whose water has gone is
## drying. `wet_floor` is how dark the ground goes for even a nuisance-band
## film, so the first 40 mm still reads as something happening.
func _wet_target(water01: float) -> float:
	if water01 <= 0.0:
		return 0.0
	return clampf(_wet_floor + (1.0 - _wet_floor) * water01, 0.0, 1.0)


func _is_visible(rec: Dictionary) -> bool:
	return maxf(float(rec["water"]), float(rec["wet"])) > _min_visible \
			or float(rec["target"]) > 0.0


## Rebuild the instance list. Cells are walked in SORTED key order and tiles in
## the order `rebuild` swept them (z, then x), so the buffer a given city
## produces is the same buffer every time — which is what lets a test compare
## two runs float for float.
func _recompute_set() -> void:
	_set_dirty = false
	_slots.clear()
	_slot_cell.clear()
	var keys := _cells.keys()
	keys.sort()
	for key: Variant in keys:
		var rec: Dictionary = _cells[key]
		var visible := _is_visible(rec)
		rec["drawn"] = visible
		if not visible:
			continue
		for tile: Variant in _tiles_for(String(key)):
			_slots.append(tile)
			_slot_cell.append(String(key))
	var count := _slots.size()
	if _mm.instance_count < count:
		# Grow in blocks of 64 so a flood that spreads tile by tile does not
		# reallocate the server-side buffer on every band crossing.
		_mm.instance_count = int(ceil(float(count) / 64.0)) * 64
	_mirror.resize(_mm.instance_count * STRIDE)
	for i in count:
		_write_transform(i, _slots[i])
	_mm.visible_instance_count = count
	_node.visible = count > 0
	_slot_dirty = true


## TRANSFORM_3D packs the basis ROWS interleaved with the origin: twelve floats,
## then the four custom ones. The basis is identity for every tile — a flood
## quad is axis-aligned and 8 m square — so only the origin varies.
func _write_transform(slot: int, tile: Vector2i) -> void:
	var o := slot * STRIDE
	_mirror[o + 0] = 1.0
	_mirror[o + 1] = 0.0
	_mirror[o + 2] = 0.0
	_mirror[o + 3] = float(tile.x) * tile_m + tile_m * 0.5
	_mirror[o + 4] = 0.0
	_mirror[o + 5] = 1.0
	_mirror[o + 6] = 0.0
	_mirror[o + 7] = base_y_m
	_mirror[o + 8] = 0.0
	_mirror[o + 9] = 0.0
	_mirror[o + 10] = 1.0
	_mirror[o + 11] = float(tile.y) * tile_m + tile_m * 0.5
	# `.b` and `.a` are reserved and stay zero. A per-TILE value here — a hash
	# seed was the obvious one — draws the tile grid in water; the shader's
	# `fragment()` carries the note and the two screenshots that settled it.
	_mirror[o + 14] = 0.0
	_mirror[o + 15] = 0.0


func _upload() -> void:
	_slot_dirty = false
	if _slots.is_empty():
		if _mm.visible_instance_count != 0:
			_mm.visible_instance_count = 0
		_node.visible = false
		return
	for i in _slots.size():
		var rec: Dictionary = _cells[_slot_cell[i]]
		var o := i * STRIDE
		_mirror[o + 12] = float(rec["water"])
		_mirror[o + 13] = float(rec["wet"])
	_mm.buffer = _mirror
	_mm.visible_instance_count = _slots.size()
	_node.visible = true
	uploads += 1


# --------------------------------------------------------------------- reads

## Doc 07's saturation for one cell, eased — 0 dry, 1 impassable.
func water01_of(key: String) -> float:
	var rec: Dictionary = _cells.get(key, {})
	return float(rec.get("water", 0.0))


## The dark-wet memory for one cell. Outlives `water01_of` by design.
func wet01_of(key: String) -> float:
	var rec: Dictionary = _cells.get(key, {})
	return float(rec.get("wet", 0.0))


func target01_of(key: String) -> float:
	var rec: Dictionary = _cells.get(key, {})
	return float(rec.get("target", 0.0))


## Tiles currently in the buffer. The profiler and the tests read this rather
## than the MultiMesh, which reads back empty on the headless DUMMY driver.
func drawn_tiles() -> int:
	return _slots.size()


## The layer's cost, in doc 11 §2.13's own unit: one call while water stands,
## none at all when the city is dry.
func draw_calls() -> int:
	return 1 if _node != null and _node.visible else 0


## Cells the view is tracking, sorted — the order the buffer is built in.
func cell_keys() -> Array:
	var keys := _cells.keys()
	keys.sort()
	return keys


## The instance buffer mirror, for the byte-for-byte determinism test.
func buffer_mirror() -> PackedFloat32Array:
	return _mirror.duplicate()
