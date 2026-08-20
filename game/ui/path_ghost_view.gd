class_name PathGhostView
extends Node3D
## The **run** ghost of doc 12 §2.7's drag-path placement — the road/water-main
## twin of `game/ui/ghost_view.gd`, which draws a single footprint box.
##
## A run is up to `data/ui.json.placement.max_run_tiles` tiles long and changes
## on every ghost move, so it is one MultiMesh bucket of flat tile slabs rather
## than N nodes (doc 11 §2.4: buckets, never per-instance nodes). Per-instance
## COLOR carries two channels at once:
##
##   * the **verdict** — §2.5's four data states, the same `#33C27A / #F2B13C /
##     #E5533D` the footprint ghost tints with, so one colour language covers
##     both tools;
##   * the **bill** — a tile the command will pass over (doc 10 §2.13: build,
##     upgrade and demolish each ignore what the other two own) is drawn at a
##     fraction of the alpha, so the player can see they are being charged for
##     five tiles of the eight they swept. Colour is never the only channel:
##     the placement bar prints the billed count and the price in words.
##
## The **anchor** tile gets its own slab, one notch taller and at full alpha, so
## the end of the run that is pinned is never ambiguous — the single thing a
## player gets wrong on a drag-path tool in every other city builder.
##
## Deliberately dumb, exactly like `GhostView`: `PathTool.ghost()` hands over
## `{visible, centres, billable, anchor, verdict, state}` and this node turns it
## into transforms and colours. It owns no validity rule and no geometry
## decision, and it never reads the sim.

## Flat enough to read as paint on the ground rather than as a wall; a run of
## eight boxes at the footprint ghost's 6 m would occlude the block it is
## crossing, which is the block the player is judging.
const SLAB_HEIGHT_M := 0.55
## The anchor slab, tall enough to pick out of a run at a shallow camera pitch.
const ANCHOR_HEIGHT_M := 2.6
## Lifted so the slab never z-fights the ground or an existing road surface.
const GROUND_LIFT_M := 0.07
## Inset from the tile edge, so consecutive tiles read as a dashed run rather
## than as one continuous ribbon — the segment count is a number the bar quotes
## and the ghost should not contradict it.
const TILE_INSET := 0.88
const DEFAULT_TINT_ALPHA := 0.35
## What a tile the command will pass over is drawn at, relative to a billed one.
const PASSED_OVER_ALPHA_MULT := 0.32
## MultiMesh headroom. Grown, never shrunk, so a sweep that gets shorter does not
## reallocate the buffer every frame.
const MIN_CAPACITY := 64

var config: UIConfig
var tint_alpha := DEFAULT_TINT_ALPHA
var tile_m := BuildController.TILE_M_DEFAULT

var _instance: MultiMeshInstance3D
var _multimesh: MultiMesh
var _material: StandardMaterial3D
var _palette: Dictionary = {}
var _capacity := 0


func setup(cfg: UIConfig = null, p_tile_m: float = -1.0) -> void:
	config = cfg if cfg != null else UIConfig.load_from_files()
	_palette = config.palette()
	tint_alpha = UIConfig.get_num(config.section("placement"), "validity_tint_alpha",
			DEFAULT_TINT_ALPHA)
	tile_m = p_tile_m if p_tile_m > 0.0 else BuildController.load_tile_m()
	if _instance == null:
		_build()
	hide_ghost()


func _ready() -> void:
	if _instance == null:
		setup()


func _build() -> void:
	var mesh := BoxMesh.new()
	# Unit box: every instance scales it, so one mesh serves the flat run slabs
	# and the taller anchor without a second bucket.
	mesh.size = Vector3.ONE
	_material = StandardMaterial3D.new()
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_material.vertex_color_use_as_albedo = true
	mesh.material = _material
	_multimesh = MultiMesh.new()
	_multimesh.transform_format = MultiMesh.TRANSFORM_3D
	_multimesh.use_colors = true
	_multimesh.mesh = mesh
	_multimesh.instance_count = 0
	_instance = MultiMeshInstance3D.new()
	_instance.name = "PathSlabs"
	_instance.multimesh = _multimesh
	_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_instance)


## The one entry point: `PathTool.ghost()`'s dictionary, verbatim.
func apply(ghost: Dictionary) -> void:
	if _instance == null:
		setup()
	var centres: Array = ghost.get("centres", [])
	if not bool(ghost.get("visible", false)) or centres.is_empty():
		hide_ghost()
		return
	var billable: Array = ghost.get("billable", [])
	var tiles: Array = ghost.get("tiles", [])
	var anchor: Vector2i = ghost.get("anchor", Vector2i.ZERO)
	var aiming := bool(ghost.get("aiming", false))
	var base := tint_for(StringName(str(ghost.get("state", HudModel.STATE_CRITICAL))))
	_reserve(centres.size())
	_multimesh.visible_instance_count = centres.size()
	for i in centres.size():
		var centre: Vector3 = centres[i]
		# While aiming there is exactly one tile and it IS the anchor; once a run
		# exists the anchor is whichever tile the pin landed on.
		var is_anchor := aiming or (i < tiles.size() and (tiles[i] as Vector2i) == anchor)
		var billed := true if i >= billable.size() else bool(billable[i])
		var height := ANCHOR_HEIGHT_M if is_anchor else SLAB_HEIGHT_M
		var span := tile_m * TILE_INSET
		var basis := Basis.IDENTITY.scaled(Vector3(span, height, span))
		_multimesh.set_instance_transform(i, Transform3D(basis,
				Vector3(centre.x, height * 0.5 + GROUND_LIFT_M, centre.z)))
		var color := base
		if not billed and not is_anchor:
			color.a *= PASSED_OVER_ALPHA_MULT
		_multimesh.set_instance_color(i, color)
	# doc 11: every bucket carries its own AABB, so a run that leaves the camera
	# frustum is culled on its real bounds instead of on the mesh's unit box.
	_instance.custom_aabb = _bounds(centres)
	visible = true


func hide_ghost() -> void:
	visible = false
	if _multimesh != null:
		_multimesh.visible_instance_count = 0


## Grows the buffer to at least `count`, never shrinking it: a sweep that gets
## shorter must not reallocate on every ghost move.
func _reserve(count: int) -> void:
	if count <= _capacity:
		return
	var wanted := maxi(MIN_CAPACITY, count)
	while wanted < count:
		wanted *= 2
	_multimesh.instance_count = wanted
	_capacity = wanted


func _bounds(centres: Array) -> AABB:
	var first: Vector3 = centres[0]
	var box := AABB(Vector3(first.x, 0.0, first.z), Vector3.ZERO)
	for entry: Variant in centres:
		var centre: Vector3 = entry
		box = box.expand(Vector3(centre.x, 0.0, centre.z))
	return box.grow(tile_m).abs()


## Palette token → tint, and the same four data states `GhostView` uses — the
## run ghost can never invent a fifth colour.
func tint_for(state: StringName) -> Color:
	var token := String(state)
	var hex := str(_palette.get(token, _palette.get(String(HudModel.STATE_CRITICAL), "#E5533D")))
	var color := Color.html(hex) if Color.html_is_valid(hex) else Color.RED
	color.a = tint_alpha
	return color


## Test seam: how many slabs are being drawn right now.
func slab_count() -> int:
	return _multimesh.visible_instance_count if _multimesh != null else 0
