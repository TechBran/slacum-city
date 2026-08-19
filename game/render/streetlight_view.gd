class_name StreetlightView
extends Node3D
## Streetlights without dynamic lights (doc 11 §2.10): per-chunk MultiMeshes
## for poles, lamp billboards, ground light pools and the §2.9 wet smears. Lit
## state comes from the RenderStateModel's per-lamp ramps (blackout-aware);
## this view only uploads. The OmniLight pool arrives with the perf pass.

const LAMP_HEIGHT := 8.2
const POLE_HEIGHT := 8.0
const POLE_WIDTH := 0.22
const POOL_RADIUS := 6.0
## Base weathering, baked into the pole's vertex colour. `POLE_GRIME_M` is how
## far up the shaft the road grime reaches and `POLE_GRIME_FLOOR` how dark it
## gets at grade; the collar sits under all of it and is dirtier still.
const POLE_GRIME_M := 2.4
const POLE_GRIME_FLOOR := 0.52
const POLE_COLLAR_M := 0.30
const POLE_COLLAR_SCALE := 1.55
const POLE_COLLAR_GRIME := 0.86
const POLE_ROUGHNESS := 0.58
const POLE_METALLIC := 0.30
## Below this the smear buffer is not drawn at all (doc 11 §2.9 #2: "dry
## weather costs nothing").
const SMEAR_MIN_WETNESS := 0.05

var model: RenderStateModel
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
	pole_mm.mesh = _pole_mesh()
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
		# The pole mesh stands ON its origin (y = 0 at the pavement), so the
		# baked base weathering lands at grade wherever the lamp is placed.
		pole_mm.set_instance_transform(i, Transform3D(Basis.IDENTITY, base))
	_lamp_nodes[chunk] = {"lamp": lamp_mm, "pool": pool_mm, "smear": smear_mm}


## The pole, textured (`tools/gen_textures.py` `prop_steel`, tiled in metres by
## `PropSurface`). Three things earn their triangles over the BoxMesh this
## replaces:
##
## * **A base collar.** One 0.30 m skirt at grade. It is the single cheapest
##   thing that makes a vertical stick read as a lamp POST rather than as a
##   fence pale, and it is on the one mesh every lamp in the city shares.
## * **Baked base weathering** in vertex colour, in three lifts up the shaft.
##   Splash, road grime and the tide line a kerbside post always carries — and
##   the reason this is vertex colour rather than a fourth page is that the page
##   is TILED: any weathering authored into it would repeat every 2 m up the
##   pole and read as a barber's pole.
## * **UV in metres**, so `prop_steel`'s half-metre AO bands land at half-metre
##   intervals up a real 8 m post.
##
## Total 34 triangles against the box's 12 — paid once on ONE shared mesh,
## instanced per chunk, and still an order of magnitude under anything else on
## screen.
func _pole_mesh() -> ArrayMesh:
	if _pole_mesh_cache != null:
		return _pole_mesh_cache
	var half := POLE_WIDTH * 0.5
	var tile := maxf(PropSurface.tile_m(), 0.01)
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var cols := PackedColorArray()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()

	# The two lambdas below WRITE into the Packed arrays above. That works
	# because a GDScript lambda's capture of a local shares storage with the
	# enclosing scope, and `tests/test_prop_textures.gd` asserts the resulting
	# geometry (38 triangles standing on y = 0 and reaching POLE_HEIGHT) rather
	# than trusting it — if the capture ever stopped writing through, the mesh
	# would come out empty and that test fails loudly.
	var push := func(p: Vector3, n: Vector3, grime: float) -> int:
		verts.push_back(p)
		norms.push_back(n)
		var k := lerpf(POLE_GRIME_FLOOR, 1.0,
				clampf(p.y / maxf(POLE_GRIME_M, 0.01), 0.0, 1.0)) * grime
		cols.push_back(Color(k, k, k, 1.0))
		# Metres along the face and up the shaft: the page's own pitch.
		var u := (p.z if absf(n.x) >= absf(n.z) else p.x) / tile
		uvs.push_back(Vector2(u, -p.y / tile))
		return verts.size() - 1
	var quad := func(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3,
			n: Vector3, grime: float) -> void:
		var i0: int = push.call(p0, n, grime)
		var i1: int = push.call(p1, n, grime)
		var i2: int = push.call(p2, n, grime)
		var i3: int = push.call(p3, n, grime)
		# Godot front faces are CLOCKWISE — the same rule gen_graybox.gd and
		# ConstructionSiteView.PropMesh follow.
		for tri: Array in [[i0, i2, i1], [i0, i3, i2]]:
			idx.append_array(PackedInt32Array(tri))

	# Shaft, in three lifts so the grime ramp has vertices to sit on.
	var lifts := [0.0, POLE_GRIME_M * 0.5, POLE_GRIME_M, POLE_HEIGHT]
	var sides := [Vector3(0, 0, 1), Vector3(0, 0, -1), Vector3(1, 0, 0),
			Vector3(-1, 0, 0)]
	for n: Vector3 in sides:
		var out := n * half
		var side := Vector3(n.z, 0.0, -n.x) * half
		for li in lifts.size() - 1:
			var y0 := float(lifts[li])
			var y1 := float(lifts[li + 1])
			quad.call(out - side + Vector3(0.0, y0, 0.0),
					out + side + Vector3(0.0, y0, 0.0),
					out + side + Vector3(0.0, y1, 0.0),
					out - side + Vector3(0.0, y1, 0.0), n, 1.0)
	# Base collar: a wider skirt at grade, and the cap that closes the shaft.
	var ch := POLE_COLLAR_M
	var cw := half * POLE_COLLAR_SCALE
	for n: Vector3 in sides:
		var out := n * cw
		var side := Vector3(n.z, 0.0, -n.x) * cw
		quad.call(out - side, out + side, out + side + Vector3(0.0, ch, 0.0),
				out - side + Vector3(0.0, ch, 0.0), n, POLE_COLLAR_GRIME)
	quad.call(Vector3(-half, POLE_HEIGHT, -half), Vector3(-half, POLE_HEIGHT, half),
			Vector3(half, POLE_HEIGHT, half), Vector3(half, POLE_HEIGHT, -half),
			Vector3.UP, 1.0)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_COLOR] = cols
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, PropSurface.material("steel",
			POLE_ROUGHNESS, POLE_METALLIC, _pole_tint))
	_pole_mesh_cache = mesh
	return mesh


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
