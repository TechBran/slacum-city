class_name CityView
extends Node3D
## Bring-up view over RenderStateModel: one MultiMeshInstance3D per
## (chunk, archetype, level) bucket, meshes from the gray-box manifest,
## per-window shading via the building shader. At starter-city scale the
## whole mirror re-uploads each frame; the model's budgeted flush path is
## exercised by its own tests and takes over with the streaming pass.
##
## Doc 11 §2.5's LOD ladder is applied HERE, on top of that: the model has
## always computed per-chunk tiers (`update_chunk_tiers`, hysteresis and dwell
## included, tested) but nothing on the render side ever consumed them, so
## every chunk drew its full LOD0 bucket set to the cull distance. `refresh`
## now drives the tiers from the camera the caller already passes and swaps a
## FAR chunk's whole bucket set for ONE MultiMesh of the shared 12-triangle
## `far_unit_box` — §2.13's "FAR = 1 building draw call per chunk", finally
## true.

const TEXTURE_MANIFEST := "res://game/textures/generated/manifest.json"
const FAR_MESH_ARCHETYPE := "far_unit_box"
## §2.6's five building families, in the order the FAR shader's `window_colors`
## array is indexed. The index is what `_upload_far` writes into the far
## buffer's `.a` channel.
const FAMILY_ORDER := ["residential", "commercial", "industrial", "tech", "civic"]
const CHUNK_M := 128.0
## Godot's MultiMesh buffer stride with `use_custom_data`: 12 transform floats
## then 4 custom-data floats. Mirrored from RenderStateModel.INSTANCE_STRIDE.
const INSTANCE_STRIDE := 16
## The FAR buffer's `.a` packs `family_index + 8 * chunk_overlay_state`.
##
## THE CHANNEL CHOICE, recorded. `.g` was proposed as "the damage slot the far
## tier ignores"; it is not ignored — `building_far.gdshader` reads it for the
## soot multiply AND for the damage dim on EMISSION, so writing the overlay
## there would trade a working damage read for the overlay and lose a burnt
## building's soot the moment the player opened the power overlay. `.r` is the
## emissive ramp the blackout rides across the tier swap and `.b` is the packed
## variant/stage the site shell needs. `.a` is the only channel this tier owns
## outright (§2.6 locks it to `anim_phase` for NEAR/MEDIUM; the far tier has no
## flicker), it already carries a 0..4 integer, and 8 is the smallest power of
## two clear of it — so the state rides ABOVE the family index in the same float
## and nothing else in the buffer had to move.
const FAR_OVERLAY_STRIDE := 8.0
## The two per-building overlay modes (doc 12 §2.5). `OverlayModel` owns the
## names; the model stores whichever one is live and the far shader sees the
## same pair as `sc_overlay_mode` 1 and 2.
const OVERLAY_POWER := &"power"
const OVERLAY_WATER := &"water"
## `building.gdshader`'s `power_dark_hi` / `power_weak_hi`. The far aggregate has
## to grade a chunk the same way the near shader grades a building, or a chunk
## changes verdict as it crosses the LOD boundary.
##
## The near shader ramps these with `smoothstep` and then thresholds the result;
## this takes the upper edge as a hard cut instead, which is the same answer on
## every value the ladder actually produces — `emissive_target_for` emits
## dark 0.05 (OFFLINE both ways), backup 0.22 (WARNING both ways) and
## powered ≥ 0.55 (NORMAL both ways). The two only disagree part-way through a
## blackout stutter, on a chunk that is mid-ramp for a fraction of a second.
const POWER_DARK_HI := 0.17
const POWER_WEAK_HI := 0.42

var model: RenderStateModel
## Doc 11 §2.5 tier swapping. Off puts every chunk back on its LOD0 buckets,
## which is what the renderer did before the far tier was wired.
var lod_enabled := true

var _manifest_by_key: Dictionary = {}  # "archetype:level:lod" -> manifest entry
var _bucket_nodes: Dictionary = {}  # bucket key -> MultiMeshInstance3D
var _shader: Shader
var _window_colors: Dictionary = {}
## §2.6 window brightness. `emissive.window_nits` is either a plain number (the
## old form, applied to every family) or a {family: nits} object; `_window_nits`
## holds the resolved per-family table and `_window_nits_default` the fallback.
var _window_nits: Dictionary = {}
var _window_nits_default: float = 3.2
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
# --- FAR tier (§2.5 / §2.6 / §2.14 LOD2) -----------------------------------
var _far_shader: Shader
var _far_mesh: Mesh
var _far_nodes: Dictionary = {}     # Vector2i chunk -> MultiMeshInstance3D
var _far_nits: float = 2.4
var _far_band := Vector2(0.30, 0.78)
var _floor_height_m: float = 3.5
## "archetype:level" -> Vector3(fx·8, height_m, fz·8): the §2.14 scale the far
## box takes. Static per bucket, so it is resolved once at setup.
var _far_scale: Dictionary = {}
## archetype -> index into FAMILY_ORDER, written into the far buffer's `.a`.
var _family_index: Dictionary = {}
var _far_energy_scale: float = 0.62
var _far_cell_m: float = 6.4
var _far_bay_m: float = 3.2
var _far_mullion_duty: float = 0.72
## Tests only. `MultiMesh.buffer` round-trips through the rendering server,
## which is the dummy one headless, so the far buffer has to be readable from
## the CPU side to be asserted at all. Off in play: keeping it would double the
## far tier's memory for nothing.
var keep_far_buffers := false
var _far_buffers: Dictionary = {}   # Vector2i chunk -> PackedFloat32Array


func setup(p_model: RenderStateModel, render_data: Dictionary) -> void:
	model = p_model
	_shader = load("res://game/shaders/building.gdshader")
	if ResourceLoader.exists("res://game/shaders/building_far.gdshader"):
		_far_shader = load("res://game/shaders/building_far.gdshader")
	var manifest: Dictionary = StarterCityLoader.read_json("res://game/meshes/generated/manifest.json")
	for entry in manifest.get("meshes", []):
		_manifest_by_key["%s:%d:%d" % [entry["archetype"], int(entry["level"]), int(entry["lod"])]] = entry
		if int(entry["lod"]) == 0:
			var idx := FAMILY_ORDER.find(String(entry.get("family", "residential")))
			_family_index[String(entry["archetype"])] = float(maxi(idx, 0))
			var foot: Array = entry.get("footprint_tiles", [1, 1])
			var aabb: Array = entry.get("aabb", [])
			var h := float(entry.get("height_m", 10.0))
			if aabb.size() >= 2:
				h = maxf(h, float(aabb[1]))
			_far_scale["%s:%d" % [entry["archetype"], int(entry["level"])]] = Vector3(
					float(foot[0]) * 8.0, maxf(h, 0.5), float(foot[1]) * 8.0)
		elif int(entry["lod"]) == 2 and String(entry["archetype"]) == FAR_MESH_ARCHETYPE:
			var path := String(entry.get("path", ""))
			if path != "" and ResourceLoader.exists(path):
				_far_mesh = load(path)
	var world: Dictionary = render_data.get("world", {})
	_floor_height_m = float(world.get("floor_height_m", 3.5))
	var emissive: Dictionary = render_data.get("emissive", {})
	_window_colors = emissive.get("window_color", {})
	_read_window_nits(emissive.get("window_nits", 3.2))
	_far_nits = float(emissive.get("window_nits_far", 2.4))
	_far_energy_scale = float(emissive.get("far_energy_scale", 0.62))
	_far_cell_m = float(emissive.get("far_cell_m", 6.4))
	_far_bay_m = float(emissive.get("far_bay_m",
			world.get("window_spacing_x_m", 3.2)))
	_far_mullion_duty = float(emissive.get("far_mullion_duty", 0.72))
	_far_band = Vector2(float(emissive.get("far_band_lo", 0.30)),
			float(emissive.get("far_band_hi", 0.78)))
	_day_gate = float(emissive.get("day_gate", 0.06))
	_construction = render_data.get("construction", {})
	_load_textures()
	_rebuild()


## `emissive.window_nits` accepts BOTH forms. A plain number is the pre-polish
## file and still means "this brightness for every family"; a {family: nits}
## object is the per-family table the commercial-blowout fix needs. Nothing
## downstream changes either way — nits scale EMISSION only, and `day_gate`
## alone decides how many cells light, so `RenderStateModel.lit_window_count`
## keeps mirroring the shader whatever is written here.
func _read_window_nits(value: Variant) -> void:
	_window_nits.clear()
	match typeof(value):
		TYPE_DICTIONARY:
			var table: Dictionary = value
			for family: Variant in table:
				var nits: Variant = table[family]
				if typeof(nits) == TYPE_FLOAT or typeof(nits) == TYPE_INT:
					_window_nits[String(family)] = float(nits)
			# No sensible single fallback in the table form; keep the doc value
			# so an unlisted family is lit rather than black.
			_window_nits_default = float(_window_nits.get("residential", 3.2))
		TYPE_INT, TYPE_FLOAT:
			_window_nits_default = float(value)
		_:
			_window_nits_default = 3.2


## §2.6 window brightness for one building family.
func window_nits_for(family: String) -> float:
	return float(_window_nits.get(family, _window_nits_default))


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
	for node in _far_nodes.values():
		(node as Node).queue_free()
	_far_nodes.clear()
	for chunk in model._sorted_chunk_coords():
		for bucket in _sorted_buckets(chunk):
			_ensure_bucket_node(bucket)
	_upload_all()


## `RenderStateModel.buckets_of` hands back the chunk's dictionary order. Every
## far-tier write below folds the buckets into ONE shared buffer, so the order
## they are folded in decides the instance order in it — sort, or the far city
## reshuffles itself between two runs of the same frame.
func _sorted_buckets(chunk: Vector2i) -> Array:
	var out: Array = model.buckets_of(chunk)
	out.sort_custom(func(a: RenderStateModel.Bucket, b: RenderStateModel.Bucket) -> bool:
		return a.key < b.key)
	return out


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
	material.set_shader_parameter("window_nits", window_nits_for(family))
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
	node.custom_aabb = _chunk_aabb(bucket.chunk)
	add_child(node)
	_bucket_nodes[_node_key(bucket)] = node


func _chunk_aabb(chunk: Vector2i) -> AABB:
	return AABB(
			Vector3(chunk.x * CHUNK_M - 8.0, -2.0, chunk.y * CHUNK_M - 8.0),
			Vector3(CHUNK_M + 16.0, 260.0, CHUNK_M + 16.0))


# ------------------------------------------------------------- the FAR tier
#
# §2.14's LOD2: one 12-triangle unit box (x,z ∈ [-0.5,0.5], y ∈ [0,1]) for the
# entire city, scaled per instance to (fx·8, height_m, fz·8). Every building in
# a FAR chunk lands in this one MultiMesh regardless of archetype or level, so
# a chunk that costs 6–8 bucket draw calls at MEDIUM costs exactly one here.
#
# The custom-data channels are copied across UNCHANGED, which is the point: a
# chunk that crosses the boundary mid-blackout carries its exact emissive ramp,
# damage and construction stage over the swap, and the far shader reads the
# same `.r = fraction of windows lit` contract §2.6 locks.

func _far_node_for(chunk: Vector2i) -> MultiMeshInstance3D:
	var existing: MultiMeshInstance3D = _far_nodes.get(chunk)
	if existing != null:
		return existing
	if _far_shader == null or _far_mesh == null:
		return null
	var node := MultiMeshInstance3D.new()
	node.name = "MM_far_%d_%d" % [chunk.x, chunk.y]
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = _far_mesh
	mm.instance_count = 1
	mm.visible_instance_count = 0
	node.multimesh = mm
	var material := ShaderMaterial.new()
	material.shader = _far_shader
	material.set_shader_parameter("window_nits_far", _far_nits)
	material.set_shader_parameter("far_energy_scale", _far_energy_scale)
	material.set_shader_parameter("far_cell_m", _far_cell_m)
	material.set_shader_parameter("far_bay_m", _far_bay_m)
	material.set_shader_parameter("far_mullion_duty", _far_mullion_duty)
	material.set_shader_parameter("day_gate", _day_gate)
	material.set_shader_parameter("floor_height_m", _floor_height_m)
	material.set_shader_parameter("band_lo", _far_band.x)
	material.set_shader_parameter("band_hi", _far_band.y)
	material.set_shader_parameter("window_colors", far_window_colors())
	# The `.a` packing constant, pushed rather than left to the shader default,
	# so the buffer writer and its only reader cannot drift apart silently.
	material.set_shader_parameter("far_overlay_stride", FAR_OVERLAY_STRIDE)
	node.material_override = material
	node.custom_aabb = _chunk_aabb(chunk)
	# §2.5: only NEAR casts. A FAR chunk is 420 m+ out, well past
	# directional_shadow_max_distance, and would only cost splits.
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.visible = false
	add_child(node)
	_far_nodes[chunk] = node
	return node


## §2.6's five family hues in `FAMILY_ORDER`, ready for the far shader's
## `window_colors[5]` uniform. Every family scaled by its own `window_nits`
## relative to residential, so the far tier inherits the SAME per-family
## brightness ladder the near tier got — the cool commercial bays are dimmer
## than the warm residential ones at 500 m for exactly the reason they are at
## 50 m, and a chunk does not change character when it crosses the boundary.
func far_window_colors() -> PackedColorArray:
	var out := PackedColorArray()
	var reference := maxf(window_nits_for("residential"), 0.001)
	for family: String in FAMILY_ORDER:
		var col := Color(String(_window_colors.get(family, "#FFCE8A")))
		var k := window_nits_for(family) / reference
		out.append(Color(col.r * k, col.g * k, col.b * k))
	return out


## Doc 12 §2.5's per-building overlay, aggregated for the FAR tier.
##
## **Why an aggregate and not the per-building state.** Every far instance
## already carries its own packed 2-bit `overlay_state` in `.b` — it is copied
## across from the near mirror untouched. Decoding it per instance would be free.
## It is not what this draws, because at 420–1200 m a building is a few pixels
## wide and a per-building wash reads as coloured noise over the far city, which
## is the same failure mode §2.6 rejected the per-window hash for. A CHUNK is
## 128 m and stays legible to the far cull distance, and "somewhere in that block
## something is offline" is the honest resolution of the data at that range.
##
## **Worst, not mean.** 0..3 IS the severity order, so `max` is the aggregate
## that cannot hide a dead building behind twenty healthy ones — the overlay
## exists to point at trouble.
##
## POWER additionally reads the emissive ladder, exactly as the near shader
## does: `RenderStateModel.emissive_target_for` writes dark 0.05 / backup 0.22 /
## powered 0.55+, so an unlit building lands OFFLINE and a weak one WARNING even
## when its own packed state is NORMAL. The thresholds are the near shader's
## `power_dark_*` / `power_weak_*` uniforms, mirrored here.
##
## Modes 1 and 2 only. In mode 0 this returns 0 and `.a` is the bare family
## index, byte for byte what it was before this pass.
func _far_overlay_state(buckets: Array) -> float:
	if model == null:
		return 0.0
	var mode := model.overlay_mode()
	if mode != OVERLAY_POWER and mode != OVERLAY_WATER:
		return 0.0
	var worst := 0.0
	for bucket: RenderStateModel.Bucket in buckets:
		var mirror := bucket.mirror
		for i in bucket.visible_count:
			var base := i * INSTANCE_STRIDE
			if base + INSTANCE_STRIDE > mirror.size():
				break
			var packed: float = mirror[base + 14]
			var state := clampf(floor(packed / float(
					RenderStateModel.PACK_OVERLAY_STRIDE)), 0.0, 3.0)
			if mode == OVERLAY_POWER:
				var e: float = mirror[base + 12]
				if e < POWER_DARK_HI:
					state = maxf(state, 3.0)
				elif e < POWER_WEAK_HI:
					state = maxf(state, 1.0)
			worst = maxf(worst, state)
			if worst >= 3.0:
				return worst
	return worst


## Fold every bucket of `chunk` into the chunk's far MultiMesh. Reads the
## bucket mirrors rather than the model's records so the far buffer carries
## exactly what the near buffer would have drawn this frame, ramps included.
func _upload_far(chunk: Vector2i) -> void:
	var node := _far_node_for(chunk)
	if node == null:
		return
	var buckets := _sorted_buckets(chunk)
	var total := 0
	for bucket: RenderStateModel.Bucket in buckets:
		total += bucket.visible_count
	var mm := node.multimesh
	if total <= 0:
		mm.visible_instance_count = 0
		return
	if mm.instance_count < total:
		# Same granularity the model allocates buckets at: grow in blocks of 32
		# so a city that gains one building does not reallocate every frame.
		mm.instance_count = int(ceil(float(total) / 32.0)) * 32
	# Sized to the ALLOCATION, not to the live count: `MultiMesh.buffer` must be
	# exactly `instance_count * stride` long, and `resize` zero-fills, so the
	# padding beyond `visible_instance_count` costs one allocation and no copy.
	var buffer := PackedFloat32Array()
	buffer.resize(mm.instance_count * INSTANCE_STRIDE)
	var chunk_state := _far_overlay_state(buckets)
	var out := 0
	for bucket: RenderStateModel.Bucket in buckets:
		var scale: Vector3 = _far_scale.get(
				"%s:%d" % [bucket.archetype, bucket.level], Vector3(8.0, 10.0, 8.0))
		var family_index: float = _family_index.get(bucket.archetype, 0.0)
		var mirror := bucket.mirror
		for i in bucket.visible_count:
			var base := i * INSTANCE_STRIDE
			if base + INSTANCE_STRIDE > mirror.size():
				break
			# Axis-aligned box at the source instance's origin (mirror floats
			# 3 / 7 / 11 are the transform's translation column).
			buffer[out + 0] = scale.x
			buffer[out + 3] = mirror[base + 3]
			buffer[out + 5] = scale.y
			buffer[out + 7] = mirror[base + 7]
			buffer[out + 10] = scale.z
			buffer[out + 11] = mirror[base + 11]
			# .r emissive, .g damage, .b packed — copied byte for byte, so the
			# blackout ramp survives the tier swap.
			buffer[out + 12] = mirror[base + 12]
			buffer[out + 13] = mirror[base + 13]
			buffer[out + 14] = mirror[base + 14]
			# .a is `anim_phase` in the model's buffers and, in this one,
			# `family_index + FAR_OVERLAY_STRIDE * chunk_overlay_state` — see
			# `_far_overlay_state` and the far shader's header. Nothing reads
			# the far buffer but that shader, and there is no flicker at 500 m
			# for a phase to drive.
			buffer[out + 15] = family_index + FAR_OVERLAY_STRIDE * chunk_state
			out += INSTANCE_STRIDE
	if keep_far_buffers:
		_far_buffers[chunk] = buffer.slice(0, out)
	mm.buffer = buffer
	mm.visible_instance_count = total


## Tier for one chunk, resolved for RENDERING: an unknown tier (-1, before the
## first `update_chunk_tiers`) and every tier below FAR draw their buckets.
func _renders_far(chunk: Vector2i) -> bool:
	if not lod_enabled or _far_shader == null or _far_mesh == null:
		return false
	return model.chunk_tier(chunk) == RenderStateModel.TIER_FAR


func _renders_culled(chunk: Vector2i) -> bool:
	if not lod_enabled:
		return false
	return model.chunk_tier(chunk) == RenderStateModel.TIER_CULLED


## The far instance buffer last written for `chunk`, when `keep_far_buffers`
## is on. 16 floats per instance: 12 transform, then (.r emissive, .g damage,
## .b packed, .a FAMILY INDEX).
func far_buffer(chunk: Vector2i) -> PackedFloat32Array:
	return _far_buffers.get(chunk, PackedFloat32Array())


## How many chunks are currently drawing the shared far box. Exposed for tests
## and for the perf log — it is the number §2.13's draw-call arithmetic keys off.
func far_chunk_count() -> int:
	var n := 0
	for chunk: Vector2i in _far_nodes:
		if (_far_nodes[chunk] as MultiMeshInstance3D).visible:
			n += 1
	return n


## Building MultiMeshes actually submitted this frame — the opaque half of
## §2.13's per-chunk draw-call budget.
func building_draw_calls() -> int:
	var n := 0
	for key: String in _bucket_nodes:
		if (_bucket_nodes[key] as MultiMeshInstance3D).visible:
			n += 1
	return n + far_chunk_count()


func _upload_all() -> void:
	for chunk in model._sorted_chunk_coords():
		var far := _renders_far(chunk)
		var culled := _renders_culled(chunk)
		for bucket in _sorted_buckets(chunk):
			var node: MultiMeshInstance3D = _bucket_nodes.get(_node_key(bucket))
			if node == null:
				_ensure_bucket_node(bucket)
				node = _bucket_nodes.get(_node_key(bucket))
				if node == null:
					continue
			node.visible = not (far or culled)
			if far or culled:
				# A hidden bucket is not uploaded: skipping the write is most of
				# what the far tier buys on the CPU side. The mirror is still
				# maintained by the model, so the bucket is correct the instant
				# the chunk comes back.
				continue
			var mm := node.multimesh
			if mm.instance_count * INSTANCE_STRIDE != bucket.mirror.size():
				mm.instance_count = bucket.mirror.size() / INSTANCE_STRIDE
			if bucket.mirror.size() > 0:
				mm.buffer = bucket.mirror
			mm.visible_instance_count = bucket.visible_count
		var far_node: MultiMeshInstance3D = _far_nodes.get(chunk)
		if far:
			_upload_far(chunk)
			far_node = _far_nodes.get(chunk)
			if far_node != null:
				far_node.visible = true
		elif far_node != null:
			far_node.visible = false


## Doc 12 §2.5's `overlay_changed`, forwarded into the model and flushed at
## once. The flush matters: the rail writes `sc_overlay_mode` the same frame,
## and without it a PAUSED city would grey out with the previous overlay's
## states still in the instance buffer until something else made a record
## dirty. One call, and the buffer the shader reads already carries the mode
## the player just chose.
##
## `camera_pos` only orders the flush (nearest chunks first); passing
## `Vector3.ZERO` is harmless because the budget below is effectively infinite.
func set_overlay_mode(mode: StringName, camera_pos: Vector3 = Vector3.ZERO) -> void:
	if model == null:
		return
	model.set_overlay_mode(mode)
	model.flush_dirty(camera_pos, 1000000)
	_upload_all()


## The four §2.5 state colours the overlay pass tints with, resolved against the
## player's colourblind palette. `paint` is `OverlayModel.
## building_state_paint_ordered(variant)` — doc 11's packing order,
## `[{color, mix, emission}] × 4`.
##
## Until this existed the four hues were baked into `building.gdshader` as
## uniform defaults, so a deuteran player read a deuteran legend beside a city
## still tinted for trichromats. The road bands already followed the palette
## (`RoadOverlayView._build_band_paint`); this is the other half of A6, and it
## reads the same `data/ui.json.palette` table the legend is painted from.
func set_overlay_palette(paint: Array) -> void:
	if paint.size() < 4:
		return
	var names := ["overlay_normal_color", "overlay_warning_color",
			"overlay_critical_color", "overlay_offline_color"]
	var keys: Array = _bucket_nodes.keys()
	keys.sort()
	for key: Variant in keys:
		var node: MultiMeshInstance3D = _bucket_nodes[key]
		var material := node.material_override as ShaderMaterial
		if material == null:
			continue
		for i in 4:
			var row: Dictionary = paint[i]
			material.set_shader_parameter(names[i], row.get("color", Color(1, 1, 1)))
		# NORMAL is the calm state and carries its own, lighter blend; the three
		# that mean LOOK HERE share the data blend. Both are §2.5's, restated per
		# state in `data/ui.json.overlay.building_state_paint`.
		material.set_shader_parameter("overlay_normal_blend",
				float((paint[0] as Dictionary).get("mix", 0.50)))
		material.set_shader_parameter("overlay_data_blend",
				float((paint[2] as Dictionary).get("mix", 0.88)))
		material.set_shader_parameter("overlay_state_emission",
				float((paint[2] as Dictionary).get("emission", 0.55)))


func refresh(delta: float, hour: float, camera_pos: Vector3 = Vector3.ZERO) -> void:
	model.set_hour(hour)
	model.advance(delta)
	# advance() ramps the records; flush_dirty() is what writes them into the
	# bucket mirrors. Unbudgeted here — bring-up scale; the streaming pass
	# adopts the per-frame write budget.
	model.flush_dirty(camera_pos, 1000000)
	if lod_enabled:
		# The model owns the hysteresis and the 0.5 s dwell, so the swap below
		# inherits both: a chunk cannot flip tiers more than twice a second and
		# never inside 20 m of a band edge. That is what stops the boundary
		# popping under a normal-speed zoom.
		model.update_chunk_tiers(camera_pos, delta)
	_upload_all()
