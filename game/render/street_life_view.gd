class_name StreetLifeView
extends Node3D
## STREET LIFE (doc 11 §2.17) — the layer that answers *"there's not a lot of
## downtime of absolutely nothing to do."*
##
## The sim's opportunity system spawns things on the street worth a tap: a crook
## the police station never picked up, a stray dog, a goat off its tether, a
## dropped stash. This view is what makes them **findable and worth finding**. A
## body walks a small deterministic beat on the pavement, an attention marker
## bobs over its head, and the moment it is collected a poof takes its place and
## a `+$N` rises off it and fades.
##
## IT IS A PURE EVENT CONSUMER. Three event types in, poses out, and nothing
## goes back: no command, no query into the sim, no route lookup, not even a
## clock read of its own. The sim's state hash cannot move because of anything
## in this file, and `tests/test_street_life.gd` pins that the only way it can
## be pinned — by interleaving a full frame of this layer into a running sim and
## comparing `state_hash()` against a clean run.
##
## **FOUR DRAW CALLS**, whatever is loose in the city:
##
##   MM_crook   the hooded figure with the swag bag, `street_life.gdshader`
##   MM_dog     the stray, the same shader with its own rig table
##   MM_goat    ditto
##   MM_fx      markers, `+$N` labels, poof puffs, rings and stash sparkles —
##              ONE buffer, `street_fx.gdshader`, dispatched on a mode code
##
## The fourth is the interesting one. A marker, a floating digit, a puff of dust
## and a sparkle are all the same object — a flat quad turned to face the
## camera, alpha-blended, writing no depth — so they are one MultiMesh with a
## MODE in `INSTANCE_CUSTOM.r` rather than four buffers and four calls. The
## budget for the whole layer was six; it costs four, and the two it gives back
## are what the shell's tap affordance and the next wave get to spend.
##
## WHAT IT READS. Its own events, a road-class probe (optional — it is what
## snaps a body to a kerb line rather than into a traffic lane), the camera
## position (the marker holds an ANGULAR size, so it is the same number of
## screen pixels at Z0 as at Z1) and the day/night scalar. Nothing else.
##
## Integration — `main.gd` owns the wiring; every call mirrors one the
## construction plant already takes:
##
##     view.setup(render_data)
##     view.set_road_probe(StreetLifeView.road_probe(sim.world))
##     view.feed_events(batch)                       # in `_on_sim_batch`
##     view.refresh(delta, night, gm_per_s, game_minutes, camera_pos)
##
## and, for the shell's tap: `view.live_ids()`, `view.marker_world_pos(id)`,
## `view.marker_radius_m(id)`.

const BODY_SHADER := "res://game/shaders/street_life.gdshader"
const FX_SHADER := "res://game/shaders/street_fx.gdshader"

const DEF_TILE_M := 8.0

## MultiMesh slack. Bodies are capped by `StreetLifeModel.max_live`; the fx
## buffer is sized from the model's own pools so a full frame — every marker,
## every label glyph, every puff — never has to grow mid-frame.
const GROW := 16

var tile_m := DEF_TILE_M
var world_m := 1024.0
var cast_shadows := false
var preset := "balanced"

var model := StreetLifeModel.new()

var _layers: Dictionary = {}       # key -> Layer
var _kind_layer: Array[String] = ["crook", "dog", "goat", ""]
var _anim_time := 0.0
var _night := 0.0
var _configured := false


class Layer extends RefCounted:
	var key := ""
	var node: MultiMeshInstance3D
	var mm: MultiMesh
	var material: ShaderMaterial


# -------------------------------------------------------------- public API

## `render_data` is data/render.json. `street_life`, `road_surface` (the footway
## widths a body stands on) and `world.tile_m` are read, and every key is
## optional — the model's own defaults are the shipping values, so this works
## against a render.json that has never heard of the layer.
func setup(render_data: Dictionary = {}) -> void:
	var cfg: Dictionary = render_data.get("street_life", {})
	var roads: Dictionary = render_data.get("road_surface", {})
	tile_m = float((render_data.get("world", {}) as Dictionary).get("tile_m", DEF_TILE_M))
	world_m = maxf(1024.0, tile_m * 128.0)
	model.configure(cfg, roads, tile_m)
	_read_presets(render_data)
	_build_layers(cfg)
	_configured = true


## Preset swap from the settings sheet. One knob, the same one the traffic and
## plant layers move: whether these bodies are re-drawn into the shadow splits.
func set_preset(name: String, render_data: Dictionary = {}) -> void:
	preset = name
	if not render_data.is_empty():
		_read_presets(render_data)
	var setting := GeometryInstance3D.SHADOW_CASTING_SETTING_ON if cast_shadows \
			else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for key: String in _layers:
		var layer: Layer = _layers[key]
		if layer.node != null and key != "fx":
			layer.node.cast_shadow = setting


## `func(tile: Vector2i) -> int` answering `TileGrid.ROAD_*`. Optional, and it
## is the difference between a crook standing on a pavement and a crook standing
## in a live traffic lane. `road_probe()` below builds the usual one.
func set_road_probe(probe: Callable) -> void:
	model.set_road_probe(probe)


## The probe the shell wants, off doc 09's tile grid — the road CLASS, because
## a street's footway is 1.40 m and an avenue's is 1.05 and a body has to stand
## on the right one. Bound to the world map rather than to the sim, exactly as
## `PowerInfraFeed.road_probe` is, so a test can hand in any grid.
static func road_probe(world: WorldMap) -> Callable:
	if world == null:
		return Callable()
	return func(tile: Vector2i) -> int:
		if tile.x < 0 or tile.y < 0 or tile.x >= TileGrid.SIZE \
				or tile.y >= TileGrid.SIZE:
			return TileGrid.ROAD_NONE
		return world.grid.road_class_at(tile.x, tile.y)


## One sim batch, straight from `_on_sim_batch`. Anything that is not an
## `opportunity_*` event is ignored.
func feed_events(batch: Array) -> void:
	_ensure_setup()
	model.feed_events(batch)


## One rendered frame.
##
## * `night` is doc 11's day/night scalar (0 day … 1 night); pass -1 to leave it
##   as it was. It gates the eye glints and lifts the markers into the glow.
## * `gm_per_s` is game-minutes per real second (0 while paused). The WANDER is
##   scheduled in game time, so pausing parks every body exactly where it
##   stands; the collect burst and the rising label are not, because they are
##   feedback about a tap and not motion in the world.
## * `game_minutes` is the sim's own clock — pass it and the wander is pinned to
##   the save; omit it and the layer free-runs, which is what a preview harness
##   with no sim wants.
## * `camera_pos` drives the distance gate and the marker's angular size. Omit
##   it and nothing is culled and the marker takes a mid-range size, which is
##   what the headless tests want.
func refresh(delta: float, night: float = -1.0, gm_per_s: float = -1.0,
		game_minutes: float = -1.0, camera_pos: Vector3 = Vector3.INF) -> void:
	_ensure_setup()
	if night >= 0.0:
		_night = clampf(night, 0.0, 1.0)
	_anim_time += maxf(delta, 0.0)
	model.advance(delta, maxf(gm_per_s, 0.0), game_minutes)
	model.refresh(camera_pos)
	_upload()


func clear() -> void:
	model.clear()
	for key: String in _layers:
		var layer: Layer = _layers[key]
		if layer.mm != null:
			layer.mm.visible_instance_count = 0
		if layer.node != null:
			# Emptied AND switched off — see `_write`. An empty buffer still
			# costs a draw call, and a cleared layer is the one case where that
			# would go on costing it for as long as the city runs.
			layer.node.visible = false


# ------------------------------------------------------- the shell's handles

## Where to aim a tap: the marker's centre, bob included, in world space.
## `Vector3.INF` when this layer is not drawing that id — which is the honest
## answer for an opportunity that has been collected, has expired, or is outside
## the visible radius.
func marker_world_pos(id: int) -> Vector3:
	return model.marker_world_pos(id)


## The marker's world RADIUS, so a tap target is sized off the thing the player
## is aiming at rather than off a constant that stops being true at Z0.
func marker_radius_m(id: int) -> float:
	return model.marker_radius_m(id)


## Ids with a live marker on screen this frame, ascending.
func live_ids() -> Array[int]:
	return model.live_ids()


## Where the BODY is standing — the crook's feet, not the marker over his head.
func body_world_pos(id: int) -> Vector3:
	return model.body_world_pos(id)


# ---------------------------------------------------------------- telemetry

## Draw calls this layer costs when everything it can draw is on screen.
func layer_count() -> int:
	return _layers.size()


## Live instance census, for the tests and the profiler table.
func census() -> Dictionary:
	var out := model.census()
	for key: String in _layers:
		out["mm_" + key] = (_layers[key] as Layer).mm.visible_instance_count
	return out


## Buffers actually submitting geometry this frame — the number a draw-call
## budget is measured against, as opposed to the number of buffers that exist.
func active_buffers() -> int:
	var n := 0
	for key: String in _layers:
		if (_layers[key] as Layer).mm.visible_instance_count > 0:
			n += 1
	return n


func game_minutes() -> float:
	return model.game_minutes()


func set_game_minutes(value: float) -> void:
	model.set_game_minutes(value)


# ------------------------------------------------------------------ upload

func _upload() -> void:
	for kind in StreetLifeModel.KIND_COUNT:
		var key: String = _kind_layer[kind]
		if key == "":
			continue
		_write(_layers.get(key), model.body_poses[kind], model.body_used[kind])
	_write(_layers.get("fx"), model.fx_poses, model.fx_used)
	for key2: String in _layers:
		var layer: Layer = _layers[key2]
		if layer.material != null:
			layer.material.set_shader_parameter("anim_time", _anim_time)
			if key2 != "fx":
				layer.material.set_shader_parameter("night_amt", _night)


## Three `set_instance_*` calls an instance, not one packed `MultiMesh.buffer`
## write — the ruling `ConstructionVehicleView._upload` measured and the reason
## is the same here at a tenth of the row count: each setter is one binding call
## around a C++ memcpy, and packing the rows in GDScript costs twenty scripted
## float writes to save it.
func _write(layer_v: Variant, poses: Array, used: int) -> void:
	if layer_v == null:
		return
	var layer: Layer = layer_v
	_ensure_capacity(layer, used)
	var mm := layer.mm
	var n := mini(used, mm.instance_count)
	for i in n:
		var pose: StreetLifeModel.Pose = poses[i]
		mm.set_instance_transform(i, Transform3D(pose.basis, pose.origin))
		mm.set_instance_color(i, pose.tint)
		mm.set_instance_custom_data(i, pose.custom)
	mm.visible_instance_count = n
	# HIDE the node, do not merely empty it. Measured, and it is the whole
	# difference between "+4 draw calls whenever the layer exists" and "+4 only
	# when there is something to draw": a `MultiMeshInstance3D` holding a buffer
	# with `visible_instance_count == 0` still costs a call, and this layer's
	# custom AABB is world-sized (it has to be — instances are written straight
	# into the buffer and never update the auto AABB), so the culler can never
	# drop it either. MEASURED: `profile_frame --street-life=5` on the bench city
	# read 200 dc at Z2 against a 196 dc baseline — four calls, with all three
	# BODY buffers empty (every body is past `body_radius_m` at 420 m) and one
	# live marker buffer. With this line it reads 197. Report 98 RR-79.
	if layer.node != null:
		layer.node.visible = n > 0


func _ensure_capacity(layer: Layer, needed: int) -> void:
	if needed <= layer.mm.instance_count:
		return
	# Growing resets the buffer; every visible instance is rewritten each frame
	# anyway, so there is nothing to preserve.
	layer.mm.instance_count = ((needed / GROW) + 1) * GROW


# ------------------------------------------------------------------- setup

func _ensure_setup() -> void:
	if not _configured:
		setup()


func _read_presets(render_data: Dictionary) -> void:
	var row: Dictionary = (render_data.get("presets", {}) as Dictionary).get(preset, {})
	# The same single key the plant reads, for the same reason: a tier that has
	# already decided how many shadow splits it can afford is the right place to
	# decide whether a 1.8 m body is re-drawn into all of them.
	if row.has("vehicle_shadows"):
		cast_shadows = bool(row["vehicle_shadows"])


func _build_layers(cfg: Dictionary) -> void:
	for key: String in _layers.keys():
		(_layers[key] as Layer).node.queue_free()
	_layers.clear()
	var shader: Shader = load(BODY_SHADER)
	var ranges := StreetLifeMesh.channel_ranges()

	_add_body("crook", StreetLifeMesh.crook(),
			StreetLifeMesh.crook_pivots(), StreetLifeMesh.crook_sel(),
			ranges, cfg, StreetLifeMesh.CROOK_TOP_M, shader)
	_add_body("dog", StreetLifeMesh.dog(),
			StreetLifeMesh.dog_rig(), StreetLifeMesh.quadruped_sel(),
			ranges, cfg, StreetLifeMesh.DOG_TOP_M, shader)
	_add_body("goat", StreetLifeMesh.goat(),
			StreetLifeMesh.goat_rig(), StreetLifeMesh.quadruped_sel(),
			ranges, cfg, StreetLifeMesh.GOAT_TOP_M, shader)
	_add_fx(cfg)
	set_preset(preset)


func _add_body(key: String, builder: StreetLifeMesh, pivots: PackedVector4Array,
		sel: PackedVector4Array, ranges: Array[Vector4], cfg: Dictionary,
		top_m: float, shader: Shader) -> void:
	builder.uv_tile_m = PropSurface.tile_m()
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("rig_pivot", pivots)
	mat.set_shader_parameter("rig_sel", sel)
	mat.set_shader_parameter("chan_min", ranges[0])
	mat.set_shader_parameter("chan_range", ranges[1])
	mat.set_shader_parameter("rim_gain", float(cfg.get("rim_gain", 0.34)))
	mat.set_shader_parameter("glint_energy", float(cfg.get("glint_energy", 1.5)))
	mat.set_shader_parameter("fx_flash_energy",
			float(cfg.get("flash_energy", 2.6)))
	# The bodies animate in the VERTEX stage off INSTANCE_CUSTOM, so the mesh's
	# own bounds are not the bounds that get drawn: a leg swings outside them and
	# a collected body lifts half a metre. `fx_lift_m` plus a metre of limb is
	# the whole of the excess, and it is added here rather than guessed at.
	_add_layer(key, builder.to_mesh(mat), mat, top_m + 1.6)


func _add_fx(cfg: Dictionary) -> void:
	var mat := ShaderMaterial.new()
	mat.shader = load(FX_SHADER)
	mat.set_shader_parameter("glyph_page", StreetGlyphAtlas.page())
	mat.set_shader_parameter("glyph_cells", float(StreetGlyphAtlas.GLYPH_COUNT))
	mat.set_shader_parameter("glyph_spread", StreetGlyphAtlas.SPREAD)
	mat.set_shader_parameter("pulse_hz", float(cfg.get("marker_pulse_hz", 0.62)))
	mat.set_shader_parameter("pulse_depth", float(cfg.get("marker_pulse_depth", 0.20)))
	mat.set_shader_parameter("marker_energy_day",
			float(cfg.get("marker_energy_day", 1.18)))
	mat.set_shader_parameter("marker_energy_night",
			float(cfg.get("marker_energy_night", 1.62)))
	mat.set_shader_parameter("label_energy", float(cfg.get("label_energy", 1.35)))
	# The glyph pitch the shader steps a label's slots by, in quad WIDTHS: the
	# authored pitch is a fraction of the glyph HEIGHT, and the quad is
	# `cell_aspect` as wide as it is tall. Derived here so the one authored
	# number stays `label_pitch_frac` and the shader is told the consequence.
	mat.set_shader_parameter("glyph_pitch",
			model.label_pitch_frac / maxf(StreetGlyphAtlas.cell_aspect(), 0.01))
	# The label rises `label_rise_frac` of a marker that is itself up to
	# `marker_max_m` across, off a marker that already floats over the tallest
	# body; the AABB has to carry all of it or a `+$N` disappears the moment the
	# marker's own box leaves the frustum.
	var head := model.marker_max_m * (1.0 + model.label_rise_frac) \
			+ StreetLifeMesh.CROOK_TOP_M
	_add_layer("fx", StreetLifeMesh.billboard_quad(), mat, head + 2.0)


func _add_layer(key: String, mesh: Mesh, material: ShaderMaterial,
		height_m: float) -> void:
	var layer := Layer.new()
	layer.key = key
	layer.material = material
	layer.mm = MultiMesh.new()
	layer.mm.transform_format = MultiMesh.TRANSFORM_3D
	layer.mm.use_colors = true
	layer.mm.use_custom_data = true
	layer.mm.mesh = mesh
	if mesh.get_surface_count() > 0:
		mesh.surface_set_material(0, material)
	layer.mm.instance_count = GROW
	layer.mm.visible_instance_count = 0
	layer.node = MultiMeshInstance3D.new()
	layer.node.name = "MM_%s" % key
	layer.node.multimesh = layer.mm
	# Instances are written straight into the buffer and never update the auto
	# AABB, so every MultiMesh in this project carries an explicit one.
	layer.node.custom_aabb = AABB(
			Vector3(-world_m * 0.05, -4.0, -world_m * 0.05),
			Vector3(world_m * 1.1, height_m + 8.0, world_m * 1.1))
	layer.node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	layer.node.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	add_child(layer.node)
	_layers[key] = layer
