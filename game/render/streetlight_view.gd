class_name StreetlightView
extends Node3D
## Streetlights without dynamic lights (doc 11 §2.10): per-chunk MultiMeshes
## for poles, lamp billboards, ground light pools and the §2.9 wet smears. Lit
## state comes from the RenderStateModel's per-lamp ramps (blackout-aware);
## this view only uploads. The OmniLight pool arrives with the perf pass.

const LAMP_HEIGHT := 8.2
const POLE_HEIGHT := 8.0
const POOL_RADIUS := 6.0
## Below this the smear buffer is not drawn at all (doc 11 §2.9 #2: "dry
## weather costs nothing").
const SMEAR_MIN_WETNESS := 0.05

var model: RenderStateModel
var _lamp_ids_by_chunk: Dictionary = {}  # Vector2i -> Array[int]
var _lamp_nodes: Dictionary = {}  # Vector2i -> {lamp, pool, smear}
var _smear_nodes: Array[MultiMeshInstance3D] = []
var _lamp_color := Color(1.0, 0.851, 0.627)
var _lamp_quad_m := 1.6
var _smear_alpha := 0.35
var _smear_visible := false
## Last wetness this view was told about (doc 11 §2.9). Drives whether the
## smear buffer is drawn at all.
var wetness: float = 0.0


func setup(p_model: RenderStateModel, render_data: Dictionary, lamps: Array) -> void:
	model = p_model
	var cfg: Dictionary = render_data.get("streetlights", {})
	_lamp_color = Color(String(cfg.get("lamp_color", "#FFD9A0")))
	_lamp_quad_m = float(cfg.get("lamp_billboard_m", 1.6))
	var weather: Dictionary = render_data.get("weather", {})
	_smear_alpha = float(weather.get("wet_smear_alpha", 0.35))
	for lamp in lamps:
		var pos: Vector3 = lamp["pos"]
		var rec := model.add_streetlight(int(lamp["id"]), lamp["block_id"], pos)
		var chunk: Vector2i = rec.chunk
		if not _lamp_ids_by_chunk.has(chunk):
			_lamp_ids_by_chunk[chunk] = []
		(_lamp_ids_by_chunk[chunk] as Array).append(int(lamp["id"]))
	for chunk in _lamp_ids_by_chunk:
		_build_chunk(chunk)
	refresh()


func _build_chunk(chunk: Vector2i) -> void:
	var ids: Array = _lamp_ids_by_chunk[chunk]
	var count := ids.size()
	var aabb := AABB(Vector3(chunk.x * 128.0 - 16.0, -1.0, chunk.y * 128.0 - 16.0),
			Vector3(160.0, 24.0, 160.0))

	var lamp_mm := MultiMesh.new()
	lamp_mm.transform_format = MultiMesh.TRANSFORM_3D
	lamp_mm.use_custom_data = true
	var lamp_mesh := QuadMesh.new()
	lamp_mesh.size = Vector2(_lamp_quad_m, _lamp_quad_m)
	lamp_mm.mesh = lamp_mesh
	lamp_mm.instance_count = count
	var lamp_node := MultiMeshInstance3D.new()
	lamp_node.multimesh = lamp_mm
	var lamp_material := ShaderMaterial.new()
	lamp_material.shader = load("res://game/shaders/lamp.gdshader")
	lamp_material.set_shader_parameter("lamp_color", _lamp_color)
	lamp_node.material_override = lamp_material
	lamp_node.custom_aabb = aabb
	add_child(lamp_node)

	var pool_mm := MultiMesh.new()
	pool_mm.transform_format = MultiMesh.TRANSFORM_3D
	pool_mm.use_custom_data = true
	var pool_mesh := PlaneMesh.new()
	pool_mesh.size = Vector2(POOL_RADIUS * 2.0, POOL_RADIUS * 2.0)
	pool_mm.mesh = pool_mesh
	pool_mm.instance_count = count
	var pool_node := MultiMeshInstance3D.new()
	pool_node.multimesh = pool_mm
	var pool_material := ShaderMaterial.new()
	pool_material.shader = load("res://game/shaders/light_pool.gdshader")
	pool_material.set_shader_parameter("pool_color", _lamp_color)
	pool_node.material_override = pool_material
	pool_node.custom_aabb = aabb
	add_child(pool_node)

	# ── wet smear (doc 11 §2.9 #2) ────────────────────────────────────────
	# The doc mirrors the lamp billboard BELOW y = 0. Taken literally that
	# geometry sits behind an opaque road and never survives the depth test —
	# a true mirror would need the whole pass to run depth-test-disabled, which
	# buys one correct reflection and a smear drawn over every building in
	# front of it. This is the depth-correct read of the same trick: the streak
	# stands ON the road at the pole base and runs up toward the lamp, brightest
	# where it meets the wet surface and fading out along its length. Same
	# buffer, same custom data, same shader — one uniform apart.
	var smear_mm := MultiMesh.new()
	smear_mm.transform_format = MultiMesh.TRANSFORM_3D
	smear_mm.use_custom_data = true
	smear_mm.mesh = lamp_mesh
	smear_mm.instance_count = count
	var smear_node := MultiMeshInstance3D.new()
	smear_node.multimesh = smear_mm
	var smear_material := ShaderMaterial.new()
	smear_material.shader = load("res://game/shaders/lamp.gdshader")
	smear_material.set_shader_parameter("lamp_color", _lamp_color)
	smear_material.set_shader_parameter("smear_mode", 1.0)
	smear_material.set_shader_parameter("smear_alpha", _smear_alpha)
	smear_material.set_shader_parameter("smear_min_wetness", SMEAR_MIN_WETNESS)
	smear_node.material_override = smear_material
	smear_node.custom_aabb = aabb
	smear_node.visible = false
	add_child(smear_node)
	_smear_nodes.append(smear_node)

	var pole_mm := MultiMesh.new()
	pole_mm.transform_format = MultiMesh.TRANSFORM_3D
	var pole_mesh := BoxMesh.new()
	pole_mesh.size = Vector3(0.22, POLE_HEIGHT, 0.22)
	var pole_material := StandardMaterial3D.new()
	pole_material.albedo_color = Color(0.16, 0.17, 0.18)
	pole_material.roughness = 0.6
	pole_material.metallic = 0.4
	pole_mesh.material = pole_material
	pole_mm.mesh = pole_mesh
	pole_mm.instance_count = count
	var pole_node := MultiMeshInstance3D.new()
	pole_node.multimesh = pole_mm
	pole_node.custom_aabb = aabb
	add_child(pole_node)

	# The smear spans road → lamp, so its quad is stretched off the 1.6 m
	# billboard: narrower across, LAMP_HEIGHT tall.
	var smear_basis := Basis.IDENTITY.scaled(
			Vector3(0.55, LAMP_HEIGHT / maxf(0.01, _lamp_quad_m), 1.0))
	for i in count:
		var rec: RenderStateModel.StreetlightRec = model.streetlight(int(ids[i]))
		var base: Vector3 = rec.world_pos
		lamp_mm.set_instance_transform(i, Transform3D(Basis.IDENTITY,
				base + Vector3(0.0, LAMP_HEIGHT, 0.0)))
		pool_mm.set_instance_transform(i, Transform3D(Basis.IDENTITY,
				base + Vector3(0.0, 0.07, 0.0)))
		smear_mm.set_instance_transform(i, Transform3D(smear_basis,
				base + Vector3(0.0, LAMP_HEIGHT * 0.5 + 0.06, 0.0)))
		pole_mm.set_instance_transform(i, Transform3D(Basis.IDENTITY,
				base + Vector3(0.0, POLE_HEIGHT * 0.5, 0.0)))
	_lamp_nodes[chunk] = {"lamp": lamp_mm, "pool": pool_mm, "smear": smear_mm}


## Upload per-lamp lit ramps (model.advance already ran this frame). Pass
## `WeatherFX.wetness`; omitting it holds the last value, which is what lets
## the pre-weather call site keep compiling with the smears simply off.
## (`RenderingServer.global_shader_parameter_get` is editor-only — reading
## sc_wetness back is not an option outside the editor.)
func refresh(p_wetness: float = -1.0) -> void:
	if p_wetness >= 0.0:
		wetness = p_wetness
	var want_smear := wetness >= SMEAR_MIN_WETNESS
	if want_smear != _smear_visible:
		_smear_visible = want_smear
		for node in _smear_nodes:
			node.visible = want_smear
	for chunk in _lamp_ids_by_chunk:
		var ids: Array = _lamp_ids_by_chunk[chunk]
		var nodes: Dictionary = _lamp_nodes[chunk]
		for i in ids.size():
			var rec: RenderStateModel.StreetlightRec = model.streetlight(int(ids[i]))
			var data := Color(rec.cur, 0.0, 0.0, rec.anim_phase)
			(nodes["lamp"] as MultiMesh).set_instance_custom_data(i, data)
			(nodes["pool"] as MultiMesh).set_instance_custom_data(i, data)
			if want_smear:
				(nodes["smear"] as MultiMesh).set_instance_custom_data(i, data)
