class_name CityView
extends Node3D
## Bring-up view over RenderStateModel: one MultiMeshInstance3D per
## (chunk, archetype, level) bucket, meshes from the gray-box manifest,
## per-window shading via the building shader. At starter-city scale the
## whole mirror re-uploads each frame; the model's budgeted flush path is
## exercised by its own tests and takes over with the streaming pass.

var model: RenderStateModel
var _manifest_by_key: Dictionary = {}  # "archetype:level:lod" -> manifest entry
var _bucket_nodes: Dictionary = {}  # bucket key -> MultiMeshInstance3D
var _shader: Shader
var _window_colors: Dictionary = {}
var _window_nits: float = 3.2
var _day_gate: float = 0.06


func setup(p_model: RenderStateModel, render_data: Dictionary) -> void:
	model = p_model
	_shader = load("res://game/shaders/building.gdshader")
	var manifest: Dictionary = StarterCityLoader.read_json("res://game/meshes/generated/manifest.json")
	for entry in manifest.get("meshes", []):
		_manifest_by_key["%s:%d:%d" % [entry["archetype"], int(entry["level"]), int(entry["lod"])]] = entry
	var emissive: Dictionary = render_data.get("emissive", {})
	_window_colors = emissive.get("window_color", {})
	_window_nits = float(emissive.get("window_nits", 3.2))
	_day_gate = float(emissive.get("day_gate", 0.06))
	_rebuild()


func _rebuild() -> void:
	for node in _bucket_nodes.values():
		(node as Node).queue_free()
	_bucket_nodes.clear()
	for chunk in model._sorted_chunk_coords():
		for bucket in model.buckets_of(chunk):
			_ensure_bucket_node(bucket)
	_upload_all()


func _node_key(bucket: RenderStateModel.Bucket) -> String:
	# bucket.key is (archetype, level) only — nodes must be per chunk too.
	return "%d_%d_%d" % [bucket.chunk.x, bucket.chunk.y, bucket.key]


func _ensure_bucket_node(bucket: RenderStateModel.Bucket) -> void:
	if _bucket_nodes.has(_node_key(bucket)):
		return
	var entry: Dictionary = _manifest_by_key.get(
			"%s:%d:0" % [bucket.archetype, bucket.level], {})
	if entry.is_empty():
		push_warning("no mesh for %s L%d" % [bucket.archetype, bucket.level])
		return
	var node := MultiMeshInstance3D.new()
	node.name = "MM_%s_%d_%d_%d" % [bucket.archetype, bucket.level,
			bucket.chunk.x, bucket.chunk.y]
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.instance_count = maxi(bucket.capacity, 1)
	var mesh: Mesh = load(String(entry["path"]))
	var material := ShaderMaterial.new()
	material.shader = _shader
	material.set_shader_parameter("window_cols", float(entry.get("window_cols", 4)))
	material.set_shader_parameter("window_rows", float(entry.get("window_rows", 3)))
	var family := String(entry.get("family", "residential"))
	material.set_shader_parameter("window_color",
			Color(String(_window_colors.get(family, "#FFCE8A"))))
	material.set_shader_parameter("window_nits", _window_nits)
	material.set_shader_parameter("day_gate", _day_gate)
	mm.mesh = mesh
	node.multimesh = mm
	node.material_override = material
	# Instance transforms are world-space and arrive via direct buffer writes,
	# which do NOT update the auto AABB — set an explicit cull volume covering
	# the chunk (+ tallest-building headroom) or buckets vanish by view angle.
	node.custom_aabb = AABB(
			Vector3(bucket.chunk.x * 128.0 - 8.0, -2.0, bucket.chunk.y * 128.0 - 8.0),
			Vector3(144.0, 260.0, 144.0))
	add_child(node)
	_bucket_nodes[_node_key(bucket)] = node


func _upload_all() -> void:
	for chunk in model._sorted_chunk_coords():
		for bucket in model.buckets_of(chunk):
			var node: MultiMeshInstance3D = _bucket_nodes.get(_node_key(bucket))
			if node == null:
				_ensure_bucket_node(bucket)
				node = _bucket_nodes.get(_node_key(bucket))
				if node == null:
					continue
			var mm := node.multimesh
			if mm.instance_count * 16 != bucket.mirror.size():
				mm.instance_count = bucket.mirror.size() / 16
			if bucket.mirror.size() > 0:
				mm.buffer = bucket.mirror
			mm.visible_instance_count = bucket.visible_count


func refresh(delta: float, hour: float) -> void:
	model.set_hour(hour)
	model.advance(delta)
	_upload_all()
