class_name CityView
extends Node3D
## Bring-up view over RenderStateModel: one MultiMeshInstance3D per
## (chunk, archetype, level) bucket, meshes from the gray-box manifest,
## per-window shading via the building shader. At starter-city scale the
## whole mirror re-uploads each frame; the model's budgeted flush path is
## exercised by its own tests and takes over with the streaming pass.

const TEXTURE_MANIFEST := "res://game/textures/generated/manifest.json"

var model: RenderStateModel
var _manifest_by_key: Dictionary = {}  # "archetype:level:lod" -> manifest entry
var _bucket_nodes: Dictionary = {}  # bucket key -> MultiMeshInstance3D
var _shader: Shader
var _window_colors: Dictionary = {}
var _window_nits: float = 3.2
var _day_gate: float = 0.06
## Optional `construction` block in data/render.json. Keys map 1:1 onto the
## building shader's construction uniforms and override its art defaults;
## absent keys keep the shader's. Strings are read as colours.
var _construction: Dictionary = {}
# --- procedural surface set (tools/gen_textures.py) ------------------------
var _surface_by_archetype: Dictionary = {}  # archetype -> {facade, roof}
var _surface_by_family: Dictionary = {}     # family    -> {facade, roof}
var _textures: Dictionary = {}              # "facade:brick" -> Texture2D
var _roof_tile_m: float = 4.0
var _bay_m := Vector2(3.2, 3.5)


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
	_construction = render_data.get("construction", {})
	_load_textures()
	_rebuild()


## Procedural facade/roof pages, doc 11 §2.14's gray-box dressed. Absent pages
## are not an error: the shader's `tex_mix` falls to 0 and the untextured
## gray-box comes back unchanged, so a clone that has not run
## `tools/gen_textures.py` + `--import` still boots.
func _load_textures() -> void:
	if not ResourceLoader.exists(TEXTURE_MANIFEST):
		push_warning("city_view: no texture manifest, running untextured")
		return
	var tex: Dictionary = StarterCityLoader.read_json(TEXTURE_MANIFEST)
	_roof_tile_m = float(tex.get("roof_tile_m", 4.0))
	var bay: Array = tex.get("bay_m", [3.2, 3.5])
	_bay_m = Vector2(float(bay[0]), float(bay[1]))
	_surface_by_archetype = tex.get("archetype_surface", {})
	_surface_by_family = tex.get("family_surface", {})
	for group in ["facades", "roofs"]:
		var pages: Dictionary = tex.get(group, {})
		var kind := "facade" if group == "facades" else "roof"
		for name in pages:
			var path := String((pages[name] as Dictionary).get("path", ""))
			if path == "" or not ResourceLoader.exists(path):
				push_warning("city_view: missing texture page %s" % path)
				continue
			_textures["%s:%s" % [kind, name]] = load(path)


## Which pages an archetype wears; falls back to its family, then to nothing.
func _surface_for(archetype: String, family: String) -> Dictionary:
	if _surface_by_archetype.has(archetype):
		return _surface_by_archetype[archetype]
	if _surface_by_family.has(family):
		return _surface_by_family[family]
	return {}


func _apply_surface(material: ShaderMaterial, archetype: String, family: String) -> void:
	var surface := _surface_for(archetype, family)
	var facade: Texture2D = _textures.get("facade:%s" % surface.get("facade", ""))
	var roof: Texture2D = _textures.get("roof:%s" % surface.get("roof", ""))
	if facade == null or roof == null:
		material.set_shader_parameter("tex_mix", 0.0)
		return
	material.set_shader_parameter("facade_tex", facade)
	material.set_shader_parameter("roof_tex", roof)
	material.set_shader_parameter("roof_tile_m", _roof_tile_m)
	material.set_shader_parameter("bay_m", _bay_m)
	material.set_shader_parameter("tex_mix", 1.0)


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
	# Construction look (stage 1..6): the shader clamps geometry to
	# `stage/6 * build_height_m`, so it needs this mesh's own height.
	material.set_shader_parameter("build_height_m",
			maxf(float(entry.get("height_m", 10.0)), 0.001))
	for key in _construction:
		var value: Variant = _construction[key]
		match typeof(value):
			TYPE_STRING:
				material.set_shader_parameter(String(key), Color(String(value)))
			TYPE_INT, TYPE_FLOAT:
				material.set_shader_parameter(String(key), float(value))
	_apply_surface(material, bucket.archetype, family)
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


func refresh(delta: float, hour: float, camera_pos: Vector3 = Vector3.ZERO) -> void:
	model.set_hour(hour)
	model.advance(delta)
	# advance() ramps the records; flush_dirty() is what writes them into the
	# bucket mirrors. Unbudgeted here — bring-up scale; the streaming pass
	# adopts the per-frame write budget.
	model.flush_dirty(camera_pos, 1000000)
	_upload_all()
