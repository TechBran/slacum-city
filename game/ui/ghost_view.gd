class_name GhostView
extends Node3D
## The placement ghost of doc 12 §2.7 (S3): a translucent box the size of the
## archetype's footprint, snapped to the 8 m tile grid (constitution §6) and
## tinted by the validity verdict — `#33C27A` VALID, `#F2B13C` WARN, `#E5533D`
## BLOCKED, all at `placement.validity_tint_alpha` (35 %).
##
## Deliberately dumb: it owns no validity rule and no geometry decision.
## `BuildController.ghost()` hands it `{visible, origin, size, centre, state}`
## and this node turns that into a transform and a colour. Doc 11 owns the real
## level meshes; until the ghost can borrow one, a box is the honest placeholder
## and the tint + the placement bar's words carry the meaning (A5/A14 — colour
## is never the only channel).

## Enough height to read against the ground plane without occluding the lot.
const GHOST_HEIGHT_M := 6.0
## Lifted a hair so the ghost never z-fights the ground or a road slab.
const GROUND_LIFT_M := 0.06
const DEFAULT_TINT_ALPHA := 0.35

var config: UIConfig
var tint_alpha := DEFAULT_TINT_ALPHA
var tile_m := BuildController.TILE_M_DEFAULT

var _mesh_instance: MeshInstance3D
var _mesh: BoxMesh
var _material: StandardMaterial3D
var _palette: Dictionary = {}


func setup(cfg: UIConfig = null, p_tile_m: float = -1.0) -> void:
	config = cfg if cfg != null else UIConfig.load_from_files()
	_palette = config.palette()
	tint_alpha = UIConfig.get_num(config.section("placement"), "validity_tint_alpha",
			DEFAULT_TINT_ALPHA)
	tile_m = p_tile_m if p_tile_m > 0.0 else BuildController.load_tile_m()
	if _mesh_instance == null:
		_build()
	hide_ghost()


func _ready() -> void:
	if _mesh_instance == null:
		setup()


func _build() -> void:
	_mesh = BoxMesh.new()
	_mesh.size = Vector3(tile_m, GHOST_HEIGHT_M, tile_m)
	_material = StandardMaterial3D.new()
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_material.no_depth_test = false
	_mesh.material = _material
	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.name = "GhostBox"
	_mesh_instance.mesh = _mesh
	_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mesh_instance)


## The one entry point: `BuildController.ghost()`'s dictionary, verbatim.
func apply(ghost: Dictionary) -> void:
	if _mesh_instance == null:
		setup()
	if not bool(ghost.get("visible", false)):
		hide_ghost()
		return
	var size: Vector2i = ghost.get("size", Vector2i.ONE)
	var centre: Vector3 = ghost.get("centre", Vector3.ZERO)
	show_ghost(centre, size, StringName(str(ghost.get("state", HudModel.STATE_CRITICAL))))


func show_ghost(centre: Vector3, size: Vector2i, state: StringName) -> void:
	_mesh.size = Vector3(float(size.x) * tile_m, GHOST_HEIGHT_M, float(size.y) * tile_m)
	_mesh_instance.position = Vector3(centre.x, GHOST_HEIGHT_M * 0.5 + GROUND_LIFT_M, centre.z)
	_material.albedo_color = tint_for(state)
	visible = true


func hide_ghost() -> void:
	visible = false


## Palette token → tint. The four data states of §2.5, so the ghost can never
## invent a fifth colour.
func tint_for(state: StringName) -> Color:
	var token := String(state)
	var hex := str(_palette.get(token, _palette.get(String(HudModel.STATE_CRITICAL), "#E5533D")))
	var color := Color.html(hex) if Color.html_is_valid(hex) else Color.RED
	color.a = tint_alpha
	return color
