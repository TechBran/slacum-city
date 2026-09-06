class_name SitePaintView
extends Node3D
## **THE GHOST PAINTS WHERE A SOURCE CAN LEGALLY GO** — the geometry half
## (doc 12 §2.7 D-130, doc 11 §2.20, doc 93 §BG1, closing doc 91 `A91-D-162`).
##
## Wave 28 shipped the read and the sentence: `BuildController.placement_sites()`
## runs the ghost's own preflight over a window and hands back the verified
## legal origins, and `ui/build_sheet.gd` prints *"3 spots for this within 10
## tiles — the nearest is 3 tiles away, $38.1K"*. **`site_hint()["tiles"]` had
## no renderer.** A player told there are three spots and not shown which three
## has been handed a number instead of an answer, and the number is the part he
## can already read on the bar.
##
## ── why this is not `RenderStateModel.set_overlay_channel` ────────────────
## D-127's note says "one `set_overlay_channel` call" and that is the one thing
## this layer cannot be. That channel is `{render_id: state}` — it is per
## BUILDING, riding the two `overlay_state` bits doc 11 packs into the instance
## buffer (C-64) — and **a legal site is bare ground with no building on it**.
## There is no instance to tint. The machinery that CAN carry a per-tile paint
## is the one doc 12 §2.5 mode 5 already uses for congestion, which is a
## property of a road edge for exactly the same reason: a second translucent
## MultiMesh of 8 m quads over the surface. So this is `RoadOverlayView`'s
## shape, with `OverlayModel`'s palette rule and `data/ui.json.state_glyphs`'
## own four marks, and the legend's vocabulary is honoured where it matters —
## one table, no fifth colour and no fifth glyph.
##
## ── one draw call, and zero when nothing is being placed ──────────────────
## Every painted site in the window shares one `MultiMeshInstance3D` and one
## material, and the node hides itself the moment the paint is empty — so the
## layer is **+1 draw call while a refused ghost is up and +0 the rest of the
## game** (`ConstructionVehicleView`'s RR-83 rule, applied again).
## `custom_aabb` covers the world: the buffer is written directly and never
## updates its own bounds, and a window scanned at one end of the map must not
## be culled by a box computed at the other.
##
## ── and it is not on the 10 Hz path ───────────────────────────────────────
## The window itself costs **60.6 ms on the founding city** for a water source
## (441 previews of `cmd_place_water_component`) and **14.2 ms** for a house, so
## the ONE thing this layer must never do is recompute per frame. It does not
## recompute at all: `ui/build_sheet.gd` memoises the window per CARD and per
## WINDOW (doc 93 §BD8) and this view is fed from `_on_placement_changed()`,
## which the shell emits when the ghost MOVES and when placement starts or ends.
## `apply()` is additionally idempotent on a fingerprint of the paint, so a
## ghost sliding inside its own tile re-uploads nothing at all
## (`tests/test_site_paint.gd` counts the uploads).
##
## Owns no legality rule, no palette and no constant that is not a fallback:
## `ui/site_paint_model.gd` decides every number here and the suite drives that
## without a viewport.

const SHADER := "res://game/shaders/site_paint.gdshader"
## MultiMesh buffer stride with TRANSFORM_3D + colours + custom data: twelve
## transform floats, four colour, four custom.
const STRIDE := 20

var tile_m: float = BuildController.TILE_M_DEFAULT

var _node: MultiMeshInstance3D
var _mm: MultiMesh
var _material: ShaderMaterial
var _opts: Dictionary = {}
## The instance buffer, allocated once at capacity and rewritten in place.
var _mirror: PackedFloat32Array = PackedFloat32Array()
## The last paint's fingerprint. Cheap, exact and order-sensitive, because the
## order IS the clean-before-warned contract.
var _print := ""

## Instrumentation the suite reads (`tests/test_site_paint.gd`): how many times
## the buffer was actually written, as against how many times `apply` was asked.
var uploads: int = 0
var applies: int = 0


func setup(model: SitePaintModel, p_tile_m: float = -1.0) -> void:
	var m := model if model != null else SitePaintModel.load_from_files()
	tile_m = p_tile_m if p_tile_m > 0.0 else BuildController.load_tile_m()
	_opts = m.render_opts()
	_build_node(m.max_tiles())
	clear()


func _ready() -> void:
	if _node == null:
		setup(null)


func _build_node(capacity: int) -> void:
	if _node != null:
		return
	var quad := PlaneMesh.new()
	quad.size = Vector2(tile_m, tile_m)
	_mm = MultiMesh.new()
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	_mm.use_colors = true
	_mm.use_custom_data = true
	_mm.mesh = quad
	_mm.instance_count = capacity
	_mm.visible_instance_count = 0
	_material = ShaderMaterial.new()
	if ResourceLoader.exists(SHADER):
		_material.shader = load(SHADER)
	_material.set_shader_parameter("wash_floor", float(_opts.get("wash_floor", 0.34)))
	_material.set_shader_parameter("glyph_edge", float(_opts.get("glyph_edge", 0.05)))
	_material.set_shader_parameter("ring_radius", float(_opts.get("ring_radius", 0.42)))
	_material.set_shader_parameter("ring_width", float(_opts.get("ring_width", 0.05)))
	# Over the opaque ground, UNDER doc 12 §2.5's congestion wash (which is at
	# render_priority 5): a player placing a pump with the traffic map up is
	# looking for a site, not for a jam.
	_material.render_priority = 4
	_node = MultiMeshInstance3D.new()
	_node.name = "SitePaintQuads"
	_node.multimesh = _mm
	_node.material_override = _material
	_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var span := float(TileGrid.SIZE) * tile_m
	_node.custom_aabb = AABB(Vector3(0.0, -1.0, 0.0), Vector3(span, 4.0, span))
	add_child(_node)


## The one entry point: `BuildSheet.site_paint()`'s dictionary, verbatim.
## Returns how many tiles are lit.
func apply(paint: Dictionary) -> int:
	if _node == null:
		setup(null)
	applies += 1
	if not bool(paint.get("visible", false)):
		clear()
		return 0
	var rows: Array = paint.get("tiles", []) as Array
	if rows.is_empty():
		clear()
		return 0
	var stamp := _fingerprint(paint, rows)
	if stamp == _print:
		# Same window, same ghost tile, same marks: the buffer on the GPU is
		# already this picture. A ghost being dragged inside one tile arrives
		# here several times a second and must cost nothing.
		return int(_mm.visible_instance_count)
	_print = stamp
	var y := float(paint.get("tile_y_m", _opts.get("tile_y_m", 0.13)))
	var glyph_scale := float(_opts.get("glyph_scale", 0.30))
	var count := mini(rows.size(), _mm.instance_count)
	# The buffer is written whole — `MultiMesh.buffer` refuses a `PackedFloat32Array`
	# that is not `instance_count * STRIDE` long, whatever `visible_instance_count`
	# is — so the mirror is allocated once at the capacity and the tail beyond
	# `count` is simply never drawn.
	var buffer := _mirror
	if buffer.size() != _mm.instance_count * STRIDE:
		buffer.resize(_mm.instance_count * STRIDE)
	buffer.fill(0.0)
	for i in count:
		var row: Dictionary = rows[i]
		var world: Vector3 = row.get("world", Vector3.ZERO)
		var base := i * STRIDE
		# TRANSFORM_3D is the basis ROWS then the origin, interleaved as
		# (bx.x, by.x, bz.x, o.x, bx.y, …) — the quad is axis-aligned and flat,
		# so the basis is identity and only the origin moves.
		buffer[base + 0] = 1.0
		buffer[base + 3] = world.x
		buffer[base + 5] = 1.0
		buffer[base + 7] = y
		buffer[base + 10] = 1.0
		buffer[base + 11] = world.z
		var hue: Color = row.get("hue", Color.WHITE)
		buffer[base + 12] = hue.r
		buffer[base + 13] = hue.g
		buffer[base + 14] = hue.b
		buffer[base + 15] = float(row.get("alpha", 0.4))
		buffer[base + 16] = float(int(row.get("glyph", 0)))
		buffer[base + 17] = 1.0 if bool(row.get("nearest", false)) else 0.0
		buffer[base + 18] = glyph_scale
		buffer[base + 19] = 0.0
	_mirror = buffer
	_mm.visible_instance_count = count
	if count > 0:
		_mm.buffer = buffer
	uploads += 1
	visible = true
	_node.visible = true
	return count


## Nothing to say: the node goes dark and the layer costs no draw call at all.
func clear() -> void:
	_print = ""
	if _mm != null:
		_mm.visible_instance_count = 0
	if _node != null:
		_node.visible = false
	visible = false


## The picture, as a string. Includes the ghost-relative alpha, because that is
## what changes when the finger crosses a tile boundary without leaving the
## window — the one case where the SET is unchanged and the picture is not.
func _fingerprint(paint: Dictionary, rows: Array) -> String:
	var parts := PackedStringArray()
	parts.append("%s|%d" % [str(paint.get("centre", Vector2i.ZERO)),
			int(paint.get("radius", 0))])
	for raw: Variant in rows:
		var row: Dictionary = raw
		parts.append("%s:%d:%d:%.3f" % [str(row.get("anchor", Vector2i.ZERO)),
				int(row.get("glyph", 0)),
				1 if bool(row.get("nearest", false)) else 0,
				float(row.get("alpha", 0.0))])
	return "\n".join(parts)


func tile_count() -> int:
	return int(_mm.visible_instance_count) if _mm != null else 0


## +1 while a refused ghost is up, 0 the rest of the time. Doc 11 §2.20's budget
## row is this number.
func draw_calls() -> int:
	return 1 if _node != null and _node.visible and tile_count() > 0 else 0


func mesh_instance() -> MultiMeshInstance3D:
	return _node


func buffer_mirror() -> PackedFloat32Array:
	if _mm == null or _mm.visible_instance_count <= 0:
		return PackedFloat32Array()
	return _mm.buffer.slice(0, _mm.visible_instance_count * STRIDE)
