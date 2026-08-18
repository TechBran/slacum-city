class_name StreetlightView
extends Node3D
## Streetlights without dynamic lights (doc 11 §2.10): per-chunk MultiMeshes
## for poles, lamp billboards and ground light pools. Lit state comes from the
## RenderStateModel's per-lamp ramps (blackout-aware); this view only uploads.
## The OmniLight pool and wet-smear mirrors arrive with the rain pass.

const LAMP_HEIGHT := 8.2
const POLE_HEIGHT := 8.0
const POOL_RADIUS := 6.0

var model: RenderStateModel
var _lamp_ids_by_chunk: Dictionary = {}  # Vector2i -> Array[int]
var _lamp_nodes: Dictionary = {}  # Vector2i -> {lamp, pool, pole}
var _lamp_color := Color(1.0, 0.851, 0.627)


func setup(p_model: RenderStateModel, render_data: Dictionary, lamps: Array) -> void:
	model = p_model
	var cfg: Dictionary = render_data.get("streetlights", {})
	_lamp_color = Color(String(cfg.get("lamp_color", "#FFD9A0")))
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
	lamp_mesh.size = Vector2(1.6, 1.6)
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

	for i in count:
		var rec: RenderStateModel.StreetlightRec = model.streetlight(int(ids[i]))
		var base: Vector3 = rec.world_pos
		lamp_mm.set_instance_transform(i, Transform3D(Basis.IDENTITY,
				base + Vector3(0.0, LAMP_HEIGHT, 0.0)))
		pool_mm.set_instance_transform(i, Transform3D(Basis.IDENTITY,
				base + Vector3(0.0, 0.07, 0.0)))
		pole_mm.set_instance_transform(i, Transform3D(Basis.IDENTITY,
				base + Vector3(0.0, POLE_HEIGHT * 0.5, 0.0)))
	_lamp_nodes[chunk] = {"lamp": lamp_mm, "pool": pool_mm}


## Upload per-lamp lit ramps (model.advance already ran this frame).
func refresh() -> void:
	for chunk in _lamp_ids_by_chunk:
		var ids: Array = _lamp_ids_by_chunk[chunk]
		var nodes: Dictionary = _lamp_nodes[chunk]
		for i in ids.size():
			var rec: RenderStateModel.StreetlightRec = model.streetlight(int(ids[i]))
			var data := Color(rec.cur, 0.0, 0.0, rec.anim_phase)
			(nodes["lamp"] as MultiMesh).set_instance_custom_data(i, data)
			(nodes["pool"] as MultiMesh).set_instance_custom_data(i, data)
