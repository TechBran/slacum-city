class_name LandMotionView
extends Node3D
## **THE MOTION LAYER** (doc 11 §2.19) — `LandMotion`'s poses, uploaded.
##
## `LandWorksView` (doc 11 §2.18) draws what a developing block LOOKS like;
## `LandMotion` derives what is HAPPENING on it; this node is the seven buffers
## in between. It is created and owned by `LandWorksView` rather than wired
## separately in the shell, and that is a decision rather than a convenience:
## the dressing and the machines have to agree about where the strip ends and
## where the brush stops, and two layers the shell drove independently could be
## refreshed a frame apart with two different progress readings.
##
## **SEVEN BUFFERS, and never more than four at once:**
##
##   MM_dozer      the crawler, `construction_rig.gdshader`, joint 1 = blade
##   MM_excavator  doc 11 §2.16's own body and dig cycle, working the block
##   MM_tipper     ditto, shuttling spoil heap → frontage → back
##   MM_paver      the screed machine — and, at 0.72, the kerb machine
##   MM_roller     the drum, turning with the ground it has covered
##   MM_crew       hi-vis figures, `street_life.gdshader`, `StreetLifeMesh.worker()`
##   MM_barrier    the bays across the working end of a player-laid road run
##
## Every buffer is born hidden and switched off again the moment it empties —
## report 98 RR-83's rule, the same one §2.18 applies — so **a city with no
## pipeline in flight and no road being built costs ZERO draw calls** and the
## node count is a constant 8 (seven `MultiMeshInstance3D` plus this node)
## however many blocks are being developed.
##
## The per-phase table is in doc 11 §2.19 and is taken by
## `tests/test_land_motion.gd::test_the_per_phase_budget_is_what_doc_11_publishes`,
## so it cannot rot.
##
## **THE CLOCK**, and it is doc 11 §2.16's rule word for word: `gm_per_s` is the
## speed multiplier (0 while paused, so every machine parks exactly where it
## stands), and `game_minutes` is the sim's own clock — pass it and a load, a
## catch-up or an `--advance-hours` snaps the layer onto the save rather than
## onto the frame counter. Omit both and the layer free-runs, which is what a
## preview harness with no sim wants.
##
## **What it never does.** No sim call, no route lookup of its own (the arrival
## borrows the plant layer's already-resolved polyline), nothing persisted and no
## RNG. Constitution §3 and doc 93 §BB.

const RIG_SHADER := "res://game/shaders/construction_rig.gdshader"
const CREW_SHADER := "res://game/shaders/street_life.gdshader"

## Game-minutes of drift tolerated before the layer is snapped onto the sim's
## clock. The same eight ticks of slack doc 11 §2.16 allows itself.
const RESYNC_GM := 2.0
## MultiMesh growth quantum.
const GROW := 16

## Per-preset ceilings. `crew` is figures per site; `secondary` is whether the
## phase's SECOND machine — the haul tipper, the following roller — is drawn at
## all. The primary machine is on no knob: a CLEARING with no dozer is a phase
## with nothing happening in it, which is the defect this layer exists to close.
## `crew` is a SCALE on `LandMotion.CREW_BY_PHASE` — how many men each phase
## takes, times how generous the device is being — and not a ceiling. The first
## draft made it a ceiling and `quality`'s could never bind: no phase wants more
## than four, so a ceiling of five was a number with no reader, which is doc 93
## §AZ2's own objection in a render knob's clothes. At these three the per-phase
## crew is **1/2/2/2/2/2 · 2/3/3/3/4/3 · 3/4/4/4/5/4**.
const PRESETS := {
	"performance": {"crew": 0.60, "secondary": false},
	"balanced": {"crew": 1.00, "secondary": true},
	"quality": {"crew": 1.34, "secondary": true},
}

## `particle_ratio` thresholds the governor's ladder is read against (doc 11
## §2.13). Above `RATIO_FULL` nothing is given up; below `RATIO_SECONDARY` the
## second machine goes; the crew thins continuously in between and never below
## one figure, because a site with a machine and no man on it reads as
## abandoned plant.
const RATIO_FULL := 0.85
const RATIO_SECONDARY := 0.50

var world_m := 1024.0
var cast_shadows := false
var preset := "balanced"

var motion := LandMotion.new()

var _layers: Dictionary = {}       # key -> Layer
var _gm := 0.0
var _gm_per_s := 1.0
var _anim_time := 0.0
var _night := 0.0
var _focus := Vector3.ZERO
var _radius := 0.0
var _limit := 0
var _configured := false
var _preset_crew := 1.0
var _preset_secondary := true


class Layer extends RefCounted:
	var key := ""
	var node: MultiMeshInstance3D
	var mm: MultiMesh
	var material: Material


# -------------------------------------------------------------- public API

## `render_data` is `data/render.json`. `land_motion` is this layer's own
## section and every key in it is optional; `construction_vehicles` is read for
## the beacon and lamp tuning and for the dig cycle, so a machine on a land block
## and a machine on a building site flash at the same rate.
func setup(render_data: Dictionary = {}) -> void:
	var cfg: Dictionary = render_data.get("land_motion", {})
	var plant_cfg: Dictionary = render_data.get("construction_vehicles", {})
	var traffic: Dictionary = render_data.get("vehicles", {})
	var tile := _num(render_data.get("world", {}), "tile_m", 8.0)
	world_m = _num(traffic, "world_m", maxf(1024.0, tile * 128.0))
	cast_shadows = bool(traffic.get("cast_shadows", false))
	motion.configure(cfg, plant_cfg, tile, _num(traffic, "road_top_m", 0.10))
	_read_presets(render_data)
	_build_layers(cfg, plant_cfg)
	set_preset(preset, render_data)
	_configured = true


## Preset swap from the settings sheet (doc 12 §2.13). Two knobs — how many crew
## and whether the second machine is drawn — plus the shadow setting the traffic
## layer already owns.
func set_preset(name: String, render_data: Dictionary = {}) -> void:
	preset = name
	var row: Dictionary = PRESETS.get(name, PRESETS["balanced"])
	var cfg: Dictionary = render_data.get("land_motion", {}) \
			if not render_data.is_empty() else {}
	var overrides: Dictionary = (cfg.get("presets", {}) as Dictionary).get(name, {})
	_preset_crew = float(overrides.get("crew", row.get("crew", 1.0)))
	_preset_secondary = bool(overrides.get("secondary", row.get("secondary", true)))
	motion.crew_scale = _preset_crew
	motion.secondary = _preset_secondary
	if not render_data.is_empty():
		_read_presets(render_data)
	var setting := GeometryInstance3D.SHADOW_CASTING_SETTING_ON if cast_shadows \
			else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for key: String in _layers:
		var layer: Layer = _layers[key]
		if layer.node != null:
			layer.node.cast_shadow = setting


## Doc 11 §2.13's ladder, rung 2. `particle_ratio` drops the CREW first and the
## SECOND machine next; the machine doing the work is never dropped.
func apply_governor(knobs: Dictionary) -> void:
	var ratio := clampf(float(knobs.get("particle_ratio", 1.0)), 0.0, 1.0)
	if ratio >= RATIO_FULL:
		motion.crew_scale = _preset_crew
		motion.secondary = _preset_secondary
		return
	motion.crew_scale = _preset_crew * ratio
	motion.secondary = _preset_secondary and ratio >= RATIO_SECONDARY


## The distance gate and the block ceiling, pushed by `LandWorksView` so the two
## layers draw the same blocks. `radius <= 0` and `limit <= 0` mean no gate.
func set_gate(focus: Vector3, radius: float, limit: int) -> void:
	_focus = focus
	_radius = radius
	_limit = limit


## How many spoil heaps the dressing raises — the GRADING excavator stands at
## the one currently growing, so it has to be told.
func set_spoil_slots(count: int) -> void:
	motion.spoil_slots = maxi(1, count)


func clear() -> void:
	motion.clear()
	for key: String in _layers:
		var layer: Layer = _layers[key]
		if layer.mm != null:
			layer.mm.visible_instance_count = 0
		if layer.node != null:
			layer.node.visible = false


## One rendered frame. See the class docs for what the two clock arguments do.
func refresh(delta: float, night: float = -1.0, gm_per_s: float = -1.0,
		game_minutes: float = -1.0) -> void:
	_ensure_setup()
	if night >= 0.0:
		_night = clampf(night, 0.0, 1.0)
	if gm_per_s >= 0.0:
		_gm_per_s = gm_per_s
	_anim_time += delta
	_gm += delta * maxf(_gm_per_s, 0.0)
	if game_minutes >= 0.0 and absf(game_minutes - _gm) > RESYNC_GM:
		_gm = game_minutes
	motion.refresh(_gm, _focus, _radius, _limit)
	_upload()


## This layer's clock, in game-minutes. Exposed for the tests and the preview,
## which drive it instead of a frame loop.
func game_minutes() -> float:
	return _gm


func set_game_minutes(value: float) -> void:
	_gm = value


## Draw calls this layer costs when every kind is on screen at once.
func layer_count() -> int:
	return _layers.size()


## Buffers actually SUBMITTING geometry this frame — the number a draw-call
## budget is measured against.
func active_buffers() -> int:
	var n := 0
	for key: String in _layers:
		var layer: Layer = _layers[key]
		if layer.node != null and layer.node.visible \
				and layer.mm.visible_instance_count > 0:
			n += 1
	return n


## Live instance census, for the tests and doc 11 §2.19's table.
func census() -> Dictionary:
	var out := motion.census()
	out["buffers"] = active_buffers()
	return out


# ------------------------------------------------------------------ upload

func _upload() -> void:
	_write("dozer", motion.dozer_poses, motion.dozer_used)
	_write("excavator", motion.exc_poses, motion.exc_used)
	_write("tipper", motion.tipper_poses, motion.tipper_used)
	_write("paver", motion.paver_poses, motion.paver_used)
	_write("roller", motion.roller_poses, motion.roller_used)
	_write("crew", motion.crew_poses, motion.crew_used)
	_write("barrier", motion.barrier_poses, motion.barrier_used)
	for key: String in _layers:
		var layer: Layer = _layers[key]
		if layer.material is ShaderMaterial:
			(layer.material as ShaderMaterial).set_shader_parameter("anim_time", _anim_time)
			(layer.material as ShaderMaterial).set_shader_parameter("night_amt", _night)


func _write(key: String, poses: Array[ConstructionActivity.Pose], used: int) -> void:
	var layer: Layer = _layers.get(key)
	if layer == null:
		return
	if used > layer.mm.instance_count:
		# Growing resets the buffer; every visible instance is rewritten each
		# frame anyway, so there is nothing to preserve.
		layer.mm.instance_count = ((used / GROW) + 1) * GROW
	var n := mini(used, layer.mm.instance_count)
	for i in n:
		var pose: ConstructionActivity.Pose = poses[i]
		layer.mm.set_instance_transform(i, Transform3D(pose.basis, pose.origin))
		layer.mm.set_instance_color(i, pose.tint)
		layer.mm.set_instance_custom_data(i, pose.custom)
	layer.mm.visible_instance_count = n
	# HIDE the node, do not merely empty it (RR-83). A `MultiMeshInstance3D`
	# holding an empty buffer still costs a draw call, and this layer's AABB is
	# world-sized, so the frustum culler can never drop it either.
	if layer.node != null:
		layer.node.visible = n > 0


# ------------------------------------------------------------------- setup

func _ensure_setup() -> void:
	if not _configured:
		setup()


func _read_presets(render_data: Dictionary) -> void:
	var row: Dictionary = (render_data.get("presets", {}) as Dictionary).get(preset, {})
	if row.has("vehicle_shadows"):
		cast_shadows = bool(row["vehicle_shadows"])


func _build_layers(cfg: Dictionary, plant_cfg: Dictionary) -> void:
	for key: String in _layers.keys():
		(_layers[key] as Layer).node.queue_free()
	_layers.clear()
	var tile := PropSurface.tile_m()
	var steel_page: Texture2D = PropSurface.material("steel").albedo_texture
	var stock_page: Texture2D = PropSurface.material("stock").albedo_texture
	var shader: Shader = load(RIG_SHADER)

	# ---- the three new bodies --------------------------------------------
	# Each spends ONE of the shader's four joints and leaves the other three at
	# zero range, so a channel nothing drives cannot move a vertex.
	var dozer := LandMachineMesh.dozer()
	dozer.uv_tile_m = tile
	var dozer_mat := ConstructionVehicleView.rig_material(shader, steel_page,
			stock_page, plant_cfg)
	_one_joint(dozer_mat, LandMachineMesh.DOZ_BLADE_RANGE,
			LandMachineMesh.DOZ_BLADE_PIVOT)
	_add_layer("dozer", dozer, dozer_mat, LandMachineMesh.DOZ_TOP_M)

	var paver := LandMachineMesh.paver()
	paver.uv_tile_m = tile
	var paver_mat := ConstructionVehicleView.rig_material(shader, steel_page,
			stock_page, plant_cfg)
	_one_joint(paver_mat, LandMachineMesh.PAV_SCREED_RANGE,
			LandMachineMesh.PAV_SCREED_PIVOT)
	_add_layer("paver", paver, paver_mat, LandMachineMesh.PAV_TOP_M)

	var roller := LandMachineMesh.roller()
	roller.uv_tile_m = tile
	var roller_mat := ConstructionVehicleView.rig_material(shader, steel_page,
			stock_page, plant_cfg)
	_one_joint(roller_mat, LandMachineMesh.ROL_DRUM_RANGE,
			LandMachineMesh.ROL_DRUM_PIVOT)
	_add_layer("roller", roller, roller_mat, LandMachineMesh.ROL_TOP_M)

	# ---- doc 11 §2.16's own two, on their own buffers ---------------------
	# The plant layer's excavator and tipper work a FRONTAGE; these work the
	# block. Same mesh, same shader, same material recipe — called out of
	# `ConstructionVehicleView` rather than restated, so the joint envelopes and
	# `ConstructionActivity.dig_pose` can never disagree about what a bucket is.
	var excavator := ConstructionRigMesh.excavator()
	excavator.uv_tile_m = tile
	_add_layer("excavator", excavator,
			ConstructionVehicleView.excavator_material(shader, steel_page,
					stock_page, plant_cfg), 16.0)
	var tipper := ConstructionRigMesh.dump_truck()
	tipper.uv_tile_m = tile
	_add_layer("tipper", tipper,
			ConstructionVehicleView.tipper_material(shader, steel_page,
					stock_page, plant_cfg), 16.0)

	# ---- the crew, on doc 11 §2.17's shader -------------------------------
	var worker := StreetLifeMesh.worker()
	worker.uv_tile_m = tile
	var crew_mat := ShaderMaterial.new()
	crew_mat.shader = load(CREW_SHADER)
	crew_mat.set_shader_parameter("rig_pivot", StreetLifeMesh.worker_pivots())
	crew_mat.set_shader_parameter("rig_sel", StreetLifeMesh.worker_sel())
	var ranges := StreetLifeMesh.channel_ranges()
	crew_mat.set_shader_parameter("chan_min", ranges[0])
	crew_mat.set_shader_parameter("chan_range", ranges[1])
	crew_mat.set_shader_parameter("rim_gain", _num(cfg, "crew_rim_gain", 0.34))
	crew_mat.set_shader_parameter("glint_energy", _num(cfg, "crew_glint_energy", 1.9))
	_add_layer("crew", worker, crew_mat, StreetLifeMesh.CREW_TOP_M + 1.0)

	# ---- the barricade, doc 11 §2.16's bay --------------------------------
	var barrier := ConstructionRigMesh.barrier_bay()
	barrier.uv_tile_m = tile
	_add_layer("barrier", barrier, PropSurface.material("steel", 0.72, 0.10), 6.0)
	set_preset(preset)


## One live joint, three dead ones. Everything about the chain the shader needs
## and nothing it does not: `joint_min`/`joint_range` are zero on channels 2…4,
## so `INSTANCE_CUSTOM.gba` cannot move a vertex however it is written.
static func _one_joint(mat: ShaderMaterial, range_v: Vector2,
		pivot: Vector3) -> void:
	mat.set_shader_parameter("rig_mode", 0.0)
	mat.set_shader_parameter("joint_axis", LandMachineMesh.AXES_PITCH)
	mat.set_shader_parameter("joint_min", Vector4(range_v.x, 0.0, 0.0, 0.0))
	mat.set_shader_parameter("joint_range",
			Vector4(range_v.y - range_v.x, 0.0, 0.0, 0.0))
	mat.set_shader_parameter("pivot_1", pivot)
	mat.set_shader_parameter("pivot_2", Vector3.ZERO)
	mat.set_shader_parameter("pivot_3", Vector3.ZERO)
	mat.set_shader_parameter("pivot_4", Vector3.ZERO)
	mat.set_shader_parameter("load_joint", -1.0)


func _add_layer(key: String, builder: ConstructionRigMesh, material: Material,
		height_m: float) -> void:
	var layer := Layer.new()
	layer.key = key
	layer.material = material
	layer.mm = MultiMesh.new()
	layer.mm.transform_format = MultiMesh.TRANSFORM_3D
	layer.mm.use_colors = true
	layer.mm.use_custom_data = true
	layer.mm.mesh = builder.to_mesh(material)
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
	# Born hidden — `_write` switches it on the first frame it has anything to
	# draw, so a city with no pipeline in flight costs nothing at all.
	layer.node.visible = false
	add_child(layer.node)
	_layers[key] = layer


static func _num(cfg: Dictionary, key: String, fallback: float) -> float:
	return float(cfg.get(key, fallback))
