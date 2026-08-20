class_name StreetlightView
extends Node3D
## Streetlights without dynamic lights (doc 11 §2.10): per-chunk MultiMeshes
## for poles, lamp billboards, ground light pools and the §2.9 wet smears. Lit
## state comes from the RenderStateModel's per-lamp ramps (blackout-aware);
## this view only uploads. The OmniLight pool arrives with the perf pass.
##
## §2.10.1 changed two things about the geometry and nothing about the tuned
## billboard/pool/smear system above them:
##
## * the pole is `CobraHeadMesh` — mast, arm and luminaire — and every instance
##   YAWS it toward its own carriageway, from the `yaw` `StreetlightPlacer`
##   supplies. A row with no `yaw` gets arm-along-+X, which is what every
##   pre-cobra caller drew.
## * the glow rig hangs off the **luminaire**, out at the end of the arm, and
##   the ground pool rides over the FOOTWAY instead of 4 cm under the road
##   (report RR-24 / STREET-1). Both are placement, not calibration: energies,
##   radii, ramps and the day gate are untouched.

## Fallback lamp height for a call site that carries no `road_surface.lamp`
## block. The live number is `head_offset.y`, read off `CobraHeadMesh`.
const LAMP_HEIGHT := 8.2
const POOL_RADIUS := 6.0
const POLE_ROUGHNESS := 0.58
const POLE_METALLIC := 0.30
## Below this the smear buffer is not drawn at all (doc 11 §2.9 #2: "dry
## weather costs nothing").
const SMEAR_MIN_WETNESS := 0.05

var model: RenderStateModel
## `road_surface.lamp` — the cobra-head dimensions and where the glow hangs.
var lamp_cfg: Dictionary = {}
## Local-frame offset from the pole base to the luminaire centre. Every glowing
## element hangs off THIS, not off the top of the mast, which is the difference
## between a lamp that lights the road and a stick with a halo on it.
var head_offset := Vector3(0.0, LAMP_HEIGHT, 0.0)
## The height the ground pool is uploaded at. Above the footway, which is above
## the carriageway — see `_pool_y`.
var pool_y := 0.255
var _yaw_of: Dictionary = {}             # lamp id -> radians
## lamp id -> {base, head, pool, yaw}. The same Vector3s that go into the
## MultiMesh, kept script-side: `--headless` runs on the DUMMY rendering driver
## and `MultiMesh.get_instance_transform` reads back identity there, so a
## headless test can only check what the view publishes.
var _anchor_of: Dictionary = {}
var _lamp_ids_by_chunk: Dictionary = {}  # Vector2i -> Array[int]
var _lamp_nodes: Dictionary = {}  # Vector2i -> {lamp, pool, smear}
var _smear_nodes: Array[MultiMeshInstance3D] = []
var _lamp_color := Color(1.0, 0.851, 0.627)
## Pole tint, on top of the galvanised page and the baked grime ramp. Dark
## enough that a bare pole still reads as a silhouette against a lit pavement,
## light enough that `prop_steel`'s AO bands survive the multiply.
var _pole_tint := Color(0.34, 0.36, 0.38)
## Built once and shared by every chunk: one ArrayMesh and one material for
## every lamp post in the city.
var _pole_mesh_cache: ArrayMesh = null
var _lamp_quad_m := 1.6
var _smear_alpha := 0.35
var _smear_visible := false
## Last wetness this view was told about (doc 11 §2.9). Drives whether the
## smear buffer is drawn at all.
var wetness: float = 0.0


## `lamps` rows need `id`, `block_id` and `pos` (the pole BASE). `yaw` is
## optional and is the direction the cobra arm reaches in — `StreetlightPlacer`
## supplies it so every lamp leans over its own carriageway; a call site that
## omits it gets arm-along-+X, which is what every pre-cobra caller drew.
func setup(p_model: RenderStateModel, render_data: Dictionary, lamps: Array) -> void:
	model = p_model
	var cfg: Dictionary = render_data.get("streetlights", {})
	_lamp_color = Color(String(cfg.get("lamp_color", "#FFD9A0")))
	_lamp_quad_m = float(cfg.get("lamp_billboard_m", 1.6))
	# Pole art only. The billboard/pool/omni system above and below this line is
	# tuned and is deliberately not touched by the surface pass.
	var pole_hex := String(cfg.get("pole_color", "#575E61"))
	if Color.html_is_valid(pole_hex):
		_pole_tint = Color(pole_hex)
	_pole_mesh_cache = null
	var road: Dictionary = render_data.get("road_surface", {})
	lamp_cfg = road.get("lamp", {})
	head_offset = CobraHeadMesh.head_offset(lamp_cfg)
	pool_y = _pool_y(road)
	var weather: Dictionary = render_data.get("weather", {})
	_smear_alpha = float(weather.get("wet_smear_alpha", 0.35))
	for lamp in lamps:
		var pos: Vector3 = lamp["pos"]
		_yaw_of[int(lamp["id"])] = float(lamp.get("yaw", 0.0))
		var rec := model.add_streetlight(int(lamp["id"]), lamp["block_id"], pos)
		var chunk: Vector2i = rec.chunk
		if not _lamp_ids_by_chunk.has(chunk):
			_lamp_ids_by_chunk[chunk] = []
		(_lamp_ids_by_chunk[chunk] as Array).append(int(lamp["id"]))
	for chunk in _lamp_ids_by_chunk:
		_build_chunk(chunk)
	refresh()


## ── the pool that was buried (report STREET-1) ────────────────────────────
## `pool_y_m` was 0.06 and the road slab's TOP is 0.10, so every ground pool in
## the game failed the depth test against the carriageway it was lighting. What
## survived was the ring of it that spilled onto the block either side — a
## doughnut of light around a dark road, which is a large part of why a lamp
## read as "a stick popping out of the ground". The disc now rides just over the
## FOOTWAY, the highest surface under a lamp, so one pool covers kerb, gutter
## and both lanes. The 0.155 m it floats above the asphalt is invisible: at Z0's
## 34 degrees of pitch that is 0.23 m of parallax across a 16 m disc with no
## hard edge anywhere in it.
func _pool_y(road: Dictionary) -> float:
	var top := float(road.get("asphalt_top_m", 0.10)) \
			+ float(road.get("kerb_height_m", 0.15))
	return top + float((road.get("lamp", {}) as Dictionary).get("pool_lift_m", 0.005))


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
	pole_mm.mesh = _pole_mesh()
	pole_mm.instance_count = count
	var pole_node := MultiMeshInstance3D.new()
	pole_node.multimesh = pole_mm
	pole_node.custom_aabb = aabb
	add_child(pole_node)

	# The smear spans road → lamp, so its quad is stretched off the 1.6 m
	# billboard: narrower across, LAMP_HEIGHT tall.
	var smear_basis := Basis.IDENTITY.scaled(
			Vector3(0.55, head_offset.y / maxf(0.01, _lamp_quad_m), 1.0))
	for i in count:
		var lamp_id := int(ids[i])
		var rec: RenderStateModel.StreetlightRec = model.streetlight(lamp_id)
		var base: Vector3 = rec.world_pos
		# The arm reaches over the roadway, so the whole glow rig — billboard,
		# ground pool and wet smear — hangs off the LUMINAIRE, out at the end of
		# the arm, and not off the mast it is bolted to.
		var yaw := float(_yaw_of.get(lamp_id, 0.0))
		var basis := Basis.from_euler(Vector3(0.0, yaw, 0.0))
		var head: Vector3 = base + basis * head_offset
		var under := Vector3(head.x, maxf(base.y, pool_y), head.z)
		lamp_mm.set_instance_transform(i, Transform3D(Basis.IDENTITY, head))
		pool_mm.set_instance_transform(i, Transform3D(Basis.IDENTITY, under))
		smear_mm.set_instance_transform(i, Transform3D(smear_basis,
				Vector3(head.x, under.y + head_offset.y * 0.5, head.z)))
		# The pole mesh stands ON its origin (y = 0 at the footway), so the baked
		# base weathering lands at grade wherever the lamp is placed.
		pole_mm.set_instance_transform(i, Transform3D(basis, base))
		_anchor_of[lamp_id] = {"base": base, "head": head, "pool": under, "yaw": yaw}
	_lamp_nodes[chunk] = {"lamp": lamp_mm, "pool": pool_mm, "smear": smear_mm}


## The pole. `CobraHeadMesh` owns the geometry — mast, arm and luminaire — and
## this owns the material it wears: `tools/gen_textures.py`'s galvanised
## `prop_steel` page, tiled in METRES so a 0.14 m arm section and an 8 m mast
## carry the same grain, over the base-weathering ramp the builder bakes into
## vertex colour.
##
## ONE ArrayMesh for every lamp in the city; each instance yaws it toward its
## own carriageway (`StreetlightPlacer` supplies the angle). 76 triangles
## against the old stick's 34, paid once on the shared mesh.
func _pole_mesh() -> ArrayMesh:
	if _pole_mesh_cache != null:
		return _pole_mesh_cache
	var mesh := CobraHeadMesh.build(lamp_cfg)
	mesh.surface_set_material(0, PropSurface.material("steel",
			POLE_ROUGHNESS, POLE_METALLIC, _pole_tint))
	_pole_mesh_cache = mesh
	return mesh


## Where one lamp's mast, luminaire and ground pool were placed:
## `{base, head, pool, yaw}`. See `_anchor_of` for why this exists.
func anchor_of(lamp_id: int) -> Dictionary:
	return (_anchor_of.get(lamp_id, {}) as Dictionary).duplicate()


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
