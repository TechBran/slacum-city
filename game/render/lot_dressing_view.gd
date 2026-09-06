class_name LotDressingView
extends Node3D
## **The un-built part of every lot, drawn** (doc 11 §2.16a, doc 02 §2.3a,
## doc 93 §BE7, Wave 29).
##
## [LotDressingModel] decides what an apron looks like; this uploads it. The
## split is the one every layer in this directory keeps: the model is
## `RefCounted`, clock-free and driveable a thousand times in microseconds by a
## headless test, and the view owns the two `MultiMeshInstance3D`s and nothing
## else worth asserting about.
##
## ### The whole layer is two draw calls, city-wide
##
## `LotPads` is one flat quad per un-built lot tile; `LotProps` is one unit box
## per stripe, bollard, stockpile and fence post. Both are single MultiMeshes
## rather than per-chunk buckets — the same call doc 11 §2.5 makes for the road
## surface, and for the same arithmetic: aprons appear wherever a growing
## building stands, which on the benchmark city is 332 buildings spread over
## every chunk, so per-chunk buckets would be **98 calls against 71 of
## headroom**. Two, flat, is the whole census entry (§2.13).
##
## Colour rides in per-instance `COLOR` and both materials are unshaded-free
## `StandardMaterial3D` with `vertex_color_use_as_albedo`, so there is no third
## pipeline state and no project shader global to keep in step — `PropSurface`'s
## argument, and this layer has even less reason to want one: an apron is dry in
## the rain and carries no window grid.
##
## ### Shadows OFF, deliberately
##
## A 0.16 m painted stripe and a 0.14 m fence post cast nothing a player can see
## at any of §2.5's three poses, and the pads are flat on the ground where a
## shadow is meaningless. Doc 11 §2.5's "only NEAR chunks cast" rule is about
## per-chunk BUILDING buckets and does not reach here, so this is a decision
## rather than an inheritance: it keeps the whole layer out of the shadow pass,
## which is where §2.5 says the biggest single saving in the design lives.

const PAD_MESH_NAME := "LotPads"
const PROP_MESH_NAME := "LotProps"

var model: LotDressingModel

var _pad_mm: MultiMesh
var _pad_node: MultiMeshInstance3D
var _prop_mm: MultiMesh
var _prop_node: MultiMeshInstance3D
var _prop_ratio: float = 1.0


func setup(p_model: LotDressingModel, render_data: Dictionary) -> void:
	model = p_model
	if model == null:
		model = LotDressingModel.new()
	model.configure(render_data)
	_build_pads()
	_build_props()


## Hand the layer a fresh roster and upload it. This is the ONE entry point the
## shell needs: `LotDressingModel.rows_from_sim(sim)` on the sim's thread, then
## this. Called on placement, on a completed upgrade and on a demolition — the
## three moments a lot's built extent can change — and never per frame.
func apply_rows(rows: Array[Dictionary]) -> void:
	if model == null:
		return
	model.apply_rows(rows)
	_upload()


## Doc 11 §2.13's governor. Exactly one knob reaches this layer:
## `lot_prop_ratio` thins what STANDS on an apron and never the apron itself.
##
## The asymmetry is the argument. The pads are the layer's whole reason to
## exist — they are what stops three empty tiles beside a young store reading as
## a bug — and a thermally throttled phone still has to be able to tell reserved
## ground from unbuilt ground. The bollards, stripes and stockpiles are dressing
## ON that ground and are the only part whose cost scales with how much of the
## city is mid-growth, so they are the part with something to give back. That is
## `PowerInfraView.apply_governor`'s reasoning (pads fixed, plume thinned)
## applied to ground.
func apply_governor(knobs: Dictionary) -> void:
	var ratio := clampf(float(knobs.get("lot_prop_ratio", 1.0)), 0.0, 1.0)
	if is_equal_approx(ratio, _prop_ratio) or model == null:
		return
	_prop_ratio = ratio
	model.prop_ratio = ratio
	model.rebuild()
	_upload()


func pad_count() -> int:
	return _pad_mm.instance_count if _pad_mm != null else 0


func prop_count() -> int:
	return _prop_mm.instance_count if _prop_mm != null else 0


## The layer's own line in doc 11 §2.13's census: two calls whenever anything is
## on the ground, zero when the city has no growing building left mid-ladder.
func draw_calls() -> int:
	var calls := 0
	if _pad_node != null and _pad_node.visible:
		calls += 1
	if _prop_node != null and _prop_node.visible:
		calls += 1
	return calls


# ------------------------------------------------------------------ the buffers

func _build_pads() -> void:
	var plane := PlaneMesh.new()
	plane.size = Vector2.ONE          # scaled per instance; one mesh for every tile
	plane.orientation = PlaneMesh.FACE_Y
	var quad := _vertex_coloured(plane, _material())
	_pad_mm = MultiMesh.new()
	_pad_mm.transform_format = MultiMesh.TRANSFORM_3D
	_pad_mm.use_colors = true
	_pad_mm.mesh = quad
	_pad_mm.instance_count = 0
	_pad_node = MultiMeshInstance3D.new()
	_pad_node.name = PAD_MESH_NAME
	_pad_node.multimesh = _pad_mm
	_pad_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_pad_node.visible = false
	add_child(_pad_node)


func _build_props() -> void:
	var unit := BoxMesh.new()
	unit.size = Vector3.ONE           # scaled per instance, so one mesh serves all four kinds
	var box := _vertex_coloured(unit, _material())
	_prop_mm = MultiMesh.new()
	_prop_mm.transform_format = MultiMesh.TRANSFORM_3D
	_prop_mm.use_colors = true
	_prop_mm.mesh = box
	_prop_mm.instance_count = 0
	_prop_node = MultiMeshInstance3D.new()
	_prop_node.name = PROP_MESH_NAME
	_prop_node.multimesh = _prop_mm
	_prop_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_prop_node.visible = false
	add_child(_prop_node)


## **A primitive with a COLOR vertex array, which is what makes the per-instance
## colour arrive at all.**
##
## `MultiMesh.set_instance_color` reaches `StandardMaterial3D` through the
## `COLOR` varying, and `vertex_color_use_as_albedo` is what routes that varying
## to albedo — but Godot's `BoxMesh` and `PlaneMesh` ship **no** `ARRAY_COLOR`,
## so there is no channel for the instance colour to multiply into and every
## instance draws white. That is not a hypothetical: the first cut of this layer
## drew the whole apron — asphalt, gravel, stockpiles and all — in flat cream,
## and it took a screenshot rather than a test to see it.
##
## Every other MultiMesh layer in this directory avoids the trap by feeding an
## `ArrayMesh` its own builder made (`ConstructionRigMesh`, `VehicleMesh`), all of
## which bake vertex COLOR. This does the same thing to a stock primitive: take
## its arrays, add a white COLOR channel, and hand back an `ArrayMesh`.
static func _vertex_coloured(source: PrimitiveMesh, material: Material) -> ArrayMesh:
	var arrays := source.get_mesh_arrays()
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var colors := PackedColorArray()
	colors.resize(verts.size())
	colors.fill(Color.WHITE)
	arrays[Mesh.ARRAY_COLOR] = colors
	var out := ArrayMesh.new()
	out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	out.surface_set_material(0, material)
	return out


## One material for both buffers: vertex colour as albedo, no transparency, no
## project global. See the class doc for why this is not a `ShaderMaterial`.
func _material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.92
	mat.metallic = 0.0
	mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	return mat


func _upload() -> void:
	_upload_pads()
	_upload_props()


func _upload_pads() -> void:
	if _pad_mm == null or model == null:
		return
	var count := model.pads.size()
	_pad_mm.instance_count = count
	_pad_node.visible = count > 0
	if count == 0:
		return
	var bounds := AABB()
	for i in count:
		var rec: Dictionary = model.pads[i]
		var size := float(rec["size_m"])
		var pos: Vector3 = rec["world_pos"]
		_pad_mm.set_instance_transform(i, Transform3D(
				Basis.IDENTITY.scaled(Vector3(size, 1.0, size)), pos))
		_pad_mm.set_instance_color(i, rec["color"])
		bounds = AABB(pos, Vector3.ZERO) if i == 0 else bounds.expand(pos)
	_pad_node.custom_aabb = bounds.grow(TileGrid.METRES_PER_TILE)


func _upload_props() -> void:
	if _prop_mm == null or model == null:
		return
	var count := model.props.size()
	_prop_mm.instance_count = count
	_prop_node.visible = count > 0
	if count == 0:
		return
	var bounds := AABB()
	for i in count:
		var rec: Dictionary = model.props[i]
		var pos: Vector3 = rec["world_pos"]
		var basis := Basis.from_euler(Vector3(0.0, float(rec["yaw"]), 0.0))
		_prop_mm.set_instance_transform(i, Transform3D(
				basis.scaled(rec["size"] as Vector3), pos))
		_prop_mm.set_instance_color(i, rec["color"])
		bounds = AABB(pos, Vector3.ZERO) if i == 0 else bounds.expand(pos)
	_prop_node.custom_aabb = bounds.grow(TileGrid.METRES_PER_TILE)
