class_name PowerInfraView
extends Node3D
## The power grid, made visible (doc 04 §2.1 / §2.6, drawn by doc 11's rules).
##
## Doc 04 has owned plants, substations, feeders, transformers and per-building
## service since Wave 1, and until this pass NONE of the distribution end of it
## rendered: a player could read an overlay tint and a dashboard row, but could
## not see where the transformer serving their block actually stood, could not
## see that it was theirs, and could not see it cook. This view draws the three
## things that fixes:
##
##   1. **Pads.** A pad-mounted transformer at every `transformer` component's
##      tile, doors turned to the street, at every zoom.
##   2. **Service wires.** One catenary-sagged drop from each pad to each
##      building `PowerGrid` has attached to it — NEAR only, faded in by camera
##      distance, gone by Z1.
##   3. **Distress.** Smoke, sparks and soot driven by the grid's OWN state:
##      §5.10's load bands, §2.6's hazard knee, and the FAILED / OPEN flags the
##      incident system sets. A repaired unit visibly washes clean.
##
## Substations and plants are NOT drawn here. Report 98 C-30 makes both of them
## BUILDINGS (`sim/city_sim.gd` places them through `cmd_place_building`), they
## are already in `game/meshes/generated/manifest.json`, and `CityView` has been
## drawing them all along — this is the DISTRIBUTION layer only.
##
## ── the draw-call shape, and why it is not per-chunk ──────────────────────
## §2.13's budget for this layer is +10 calls at Z2, and the renderer convention
## is per-chunk MultiMesh buckets. Those two pull against each other here: Z2
## has 16 chunks in view (doc 11's `_z2_derivation`), so a per-chunk pad bucket
## would spend 16 calls on 144 cabinets before a single wire was drawn.
##
## So the layer is bucketed by what its ELEMENTS actually need:
##   * **Pads: one MultiMesh for the whole city.** 144 instances of a
##     204-triangle cabinet is 29 k triangles — under a third of one bench
##     chunk's buildings — and it is ONE call at every zoom. There is nothing
##     worth culling: the buffer is smaller than the cull test's bookkeeping.
##   * **Wires: one MultiMesh per chunk, submitted only when close.** A bucket
##     goes visible only while the camera is inside `wire_gate_m` of the
##     bucket's own AABB, and `power_wire.gdshader` has already faded every wire
##     in it to zero width by that range — so the gate is invisible AND Z1+ pays
##     nothing at all for the wire layer.
##   * **Distress: one MultiMesh, smoke and sparks together.** Premultiplied
##     alpha lets one pass be additive and alpha-blended at once
##     (`power_smoke.gdshader`), and the node is hidden outright while nothing
##     in the city is in trouble.
##
## Measured at Z2 on the bench city: **+1 draw call** with a healthy grid, +2
## with something smoking, against the +10 budget.

const PART_PAD := 0
const PART_CABINET := 1
const PART_LID := 2
const PART_FIN := 3
const PART_BUSHING := 4

## The strip `power_wire.gdshader` bends into a catenary. Eight segments across
## a service drop of at most ~64 m (doc 04's L5 service radius) puts the chord
## error under a centimetre against the parabola — a fifth of the wire's own
## radius, i.e. under a pixel at any zoom the wire is drawn at.
const WIRE_SEGMENTS := 8

## The selection ring (Wave 25). Metres, against the pad — not pixels — so the
## affordance is the same size relative to the cabinet at every zoom.
const SELECT_GAP_M := 0.28    ## bare ground between the pad's edge and the ring
const SELECT_RING_M := 0.34   ## the ring's own width
const SELECT_LIFT_M := 0.02   ## off grade, so it does not z-fight the road
const SELECT_COLOR := Color(1.0, 0.86, 0.35, 0.85)

const PAD_SHADER := "res://game/shaders/power_pad.gdshader"
const WIRE_SHADER := "res://game/shaders/power_wire.gdshader"
const SMOKE_SHADER := "res://game/shaders/power_smoke.gdshader"
const PROP_MANIFEST := "res://game/textures/generated/manifest.json"

var model: PowerInfraModel

## How often the cheap per-transformer state poll runs, and how often the
## expensive topology pass runs unconditionally. Both are RENDER seconds.
var state_poll_s: float = 0.25
var topology_poll_s: float = 5.0
## A wire bucket is submitted only while the camera is within this of its AABB.
## Set from `wire_fade_end_m`, which is what makes the gate unobservable.
var wire_gate_m: float = 110.0
## The camera has to move this far before the wire buckets are re-gated. A
## bucket is 128 m across and the gate carries 110 m of slack; re-testing every
## frame of a pan would be arithmetic for nothing.
var gate_recheck_m: float = 2.0

var _cfg: Dictionary = {}
var _height_of := Callable()
var _pad_mesh: ArrayMesh = null
var _pad_node: MultiMeshInstance3D = null
var _pad_mm: MultiMesh = null
var _wire_mesh: ArrayMesh = null
var _wire_material: ShaderMaterial = null
var _wire_nodes: Dictionary = {}    # Vector2i -> MultiMeshInstance3D
var _wire_chunks: Array = []        # sorted keys of _wire_nodes
var _select_node: MeshInstance3D = null
var _selected_id: String = ""
var _smoke_node: MultiMeshInstance3D = null
var _smoke_mm: MultiMesh = null
var _wire_radius_m: float = 0.045
var _state_timer: float = 0.0
var _topology_timer: float = 0.0
var _topology_dirty: bool = true
var _last_signature: int = -1
var _last_gate_pos := Vector3(1e9, 1e9, 1e9)
var _particle_ratio: float = 1.0
var _base_puff_cap: int = 132
var _base_puffs_per_pad: int = 6
## Last render height pushed into `power_wire.gdshader`. See `_sync_viewport_h`.
var _viewport_h: float = 0.0
## Doc 11's own authored vertical FOV (`camera.fov_deg`), the other half of the
## screen-space wire width. Read from `data/render.json`, never guessed.
var _fov_deg: float = 40.0

static var _prop_page_cache: Dictionary = {}
static var _prop_pages_loaded := false


# --------------------------------------------------------------------- setup

## `height_of` is `func(archetype: StringName, level: int) -> float` — the mesh
## manifest's, which the shell owns. Everything else comes from
## `data/render.json`'s `power_infra` block.
func setup(render_data: Dictionary, height_of := Callable()) -> void:
	_cfg = render_data.get("power_infra", {})
	model = PowerInfraModel.new(render_data)
	_height_of = height_of
	_fov_deg = float((render_data.get("camera", {}) as Dictionary).get("fov_deg", _fov_deg))
	_wire_radius_m = float(_cfg.get("wire_radius_m", _wire_radius_m))
	wire_gate_m = float(_cfg.get("wire_fade_end_m", wire_gate_m))
	state_poll_s = float(_cfg.get("state_poll_s", state_poll_s))
	topology_poll_s = float(_cfg.get("topology_poll_s", topology_poll_s))
	_base_puff_cap = model.puff_cap
	_base_puffs_per_pad = model.puffs_per_pad
	_build_pads()
	_build_smoke()
	# Authored, not assumed: `power_infra.pad_shadows` in `data/render.json`. The
	# number behind the shipped default is doc 11 §2.13's pad-shadow A/B.
	set_pad_shadows(bool(_cfg.get("pad_shadows", true)))


## The shell's one hook for "the grid's SHAPE changed" — a transformer placed or
## demolished, a building placed, a feeder routed. Cheap; the rebuild lands on
## the next `sync`.
func note_topology_changed() -> void:
	_topology_dirty = true


## Whether the pad buffer casts into the sun's shadow pass. On by default — a
## 1.5 m cabinet with no shadow at Z0 reads as a decal on the pavement — and off
## is the A/B a preview harness uses to price it.
func set_pad_shadows(enabled: bool) -> void:
	if _pad_node != null:
		_pad_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if enabled \
				else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


## **The selected pad, ringed on the ground** (Wave 25, doc 12 §2.25 / D-114).
##
## A `MeshInstance3D` with one flat annulus, moved and shown rather than rebuilt:
## a selection ring is one object that exists for the life of the view, and
## re-uploading the whole 144-instance pad buffer to mark one of them would be a
## per-tap cost on a buffer that is deliberately quiet when nothing is happening
## (`_buffers_dirty`).
##
## **Why a ring and not the pad's own custom data.** The `.b` channel is
## `distress + 112 × overlay_state`, and every bit of it is doc 04's or doc 12
## §2.5's. Packing a selection flag in beside them would give one channel two
## owners and put a UI concern inside the shader that draws the physical grid —
## the fault line C-64 drew. The ring is also the affordance a player already
## knows from the placement ghost, and it reads at every zoom because it is
## sized in METRES against the pad rather than in pixels.
##
## `""` clears it. An id this view has never heard of clears it too, rather than
## leaving the last one lit — a panel opened on a transformer that has since been
## demolished must not leave a ring on empty ground.
func set_selected(component_id: String) -> void:
	if _select_node == null:
		_select_node = MeshInstance3D.new()
		_select_node.name = "SelectionRing"
		_select_node.mesh = _build_select_mesh()
		_select_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_select_node.visible = false
		add_child(_select_node)
	_selected_id = component_id
	var rec: PowerInfraModel.PadRec = model.pad_of(component_id) if model != null \
			and component_id != "" else null
	_select_node.visible = rec != null
	if rec != null:
		# A hair above grade, for the same reason the road overlay is: two
		# coplanar surfaces at y = 0 z-fight, and the fight is visible from the
		# default camera pitch.
		# LOCAL, not global: every other node this view owns is placed in the same
		# space (`_pad_mm.set_instance_transform` writes local transforms too),
		# the view itself is added at the origin, and reading a global transform
		# from a Node3D whose ancestor is not one is an engine warning a headless
		# harness prints on every call.
		_select_node.position = rec.world_pos + Vector3(0.0, SELECT_LIFT_M, 0.0)
		_select_node.rotation = Vector3(0.0, rec.yaw, 0.0)


## The transformer the ring is on, or `""`. Read by the shell when it has to put
## the ring back after a topology rebuild moved the pads.
func selected() -> String:
	return _selected_id


## The ring itself: a flat annulus around the pad, in the pad's own local space,
## so it grows with `pad_size` and never has to be re-measured by hand.
func _build_select_mesh() -> ArrayMesh:
	var pad := model.pad_size if model != null else Vector2(2.40, 2.00)
	var inner := Vector2(pad.x * 0.5 + SELECT_GAP_M, pad.y * 0.5 + SELECT_GAP_M)
	var outer := inner + Vector2(SELECT_RING_M, SELECT_RING_M)
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	# Four quads, one per side of the rectangle — a rounded ring would need a
	# fan and this reads identically at the scale a 2.4 m cabinet occupies.
	var corners_in := [Vector2(-inner.x, -inner.y), Vector2(inner.x, -inner.y),
			Vector2(inner.x, inner.y), Vector2(-inner.x, inner.y)]
	var corners_out := [Vector2(-outer.x, -outer.y), Vector2(outer.x, -outer.y),
			Vector2(outer.x, outer.y), Vector2(-outer.x, outer.y)]
	for i in 4:
		var j := (i + 1) % 4
		var a: Vector2 = corners_in[i]
		var b: Vector2 = corners_in[j]
		var c: Vector2 = corners_out[j]
		var d: Vector2 = corners_out[i]
		for point: Vector2 in [a, b, c, a, c, d]:
			verts.append(Vector3(point.x, 0.0, point.y))
			normals.append(Vector3.UP)
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	# **The hue rides `albedo_color` and NOWHERE else, and that is the sRGB
	# ruling rather than a shortcut** (A91-D-36, report 98 RR-91/RR-95). A
	# `source_color` uniform and `StandardMaterial3D.albedo_color` are decoded
	# for free; a MultiMesh instance colour and a vertex COLOR are not. This ring
	# carried a vertex `ARRAY_COLOR` array of 24 `Color.WHITE` entries with
	# `vertex_color_use_as_albedo` — a multiply by one, which rendered correctly
	# and decoded nothing, but put this file in
	# `test_render_polish.gd::test_every_procedural_mesh_decodes_its_authored_vertex_colour`'s
	# census of files that hand authored colour to a shader raw. The array is
	# gone rather than decoded: there was no authored colour in it to decode, and
	# a white multiplier that exists only to satisfy a guard is the guard
	# measuring nothing. `SELECT_COLOR`'s alpha 0.85 reaches the shader through
	# `albedo_color.a`, which is why TRANSPARENCY_ALPHA below still has work.
	material.albedo_color = SELECT_COLOR
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.surface_set_material(0, material)
	return mesh


## Give the pads their orientation. Without a probe every cabinet takes the
## fixed yaw, which is a legal look and what a headless harness gets.
func set_road_probe(probe: Callable) -> void:
	if model != null:
		model.set_road_probe(probe)
		_topology_dirty = true


# ---------------------------------------------------------------- the pump

## Everything, once per frame. Polls the sim on its own schedule (see
## `state_poll_s` / `topology_poll_s`), advances the model's ramps, uploads what
## moved, and re-gates the wire buckets.
##
## The two schedules are the point. A full topology pass walks every attached
## building — 1,500 of them on the bench city — and is worth doing only when the
## grid's shape has actually changed; the per-transformer state rows are 144
## dictionaries and are what a smoking transformer needs four times a second.
## Between the two sits `PowerInfraFeed.signature()`, which is O(1) and catches
## a roster that grew or shrank on the very next poll.
func sync(sim: CitySim, delta: float, camera_pos: Vector3) -> void:
	if model == null or sim == null:
		return
	_topology_timer += delta
	_state_timer += delta
	var want_state := _state_timer >= state_poll_s
	if want_state and not _topology_dirty:
		var signature := PowerInfraFeed.signature(sim)
		if signature != _last_signature:
			_last_signature = signature
			_topology_dirty = true
	if _topology_dirty or _topology_timer >= topology_poll_s:
		_topology_timer = 0.0
		_topology_dirty = false
		_last_signature = PowerInfraFeed.signature(sim)
		apply_topology(PowerInfraFeed.topology(sim, _height_of, model.tile_m))
		want_state = true
	if want_state:
		_state_timer = 0.0
		model.apply_state(PowerInfraFeed.state(sim))
		_upload_smoke()
	refresh(delta, camera_pos)


## The animation half, with no sim in it: ramps forward, buffers re-uploaded
## only if a ramp actually moved, wire buckets re-gated only if the camera did.
## Split out so a preview harness (or a test) can drive the look without a
## `CitySim`.
func refresh(delta: float, camera_pos: Vector3) -> void:
	if model == null:
		return
	_sync_viewport_h()
	model.advance(delta)
	if model.take_dirty():
		_upload_pads()
		_upload_wire_custom()
	if camera_pos.distance_to(_last_gate_pos) >= gate_recheck_m:
		_last_gate_pos = camera_pos
		_gate_wires(camera_pos)


## Rebuild pads and wires from a `PowerInfraFeed.topology()` payload. A no-op
## when the grid's shape is what it already was — see
## `PowerInfraModel.build_topology`, which is the half that knows.
func apply_topology(feed: Dictionary) -> bool:
	if not model.build_topology(feed.get("transformers", []),
			feed.get("buildings", {}), feed.get("attachments", {})):
		return false
	_rebuild_pad_buffer()
	_rebuild_wire_buckets()
	_upload_smoke()
	_last_gate_pos = Vector3(1e9, 1e9, 1e9)
	return true


## Feed `PowerGrid.transformer_rows()` directly — the entry point a test and a
## preview harness use in place of `sync`.
func apply_state(rows: Array) -> void:
	if model == null:
		return
	model.apply_state(rows)
	_upload_pads()
	_upload_wire_custom()
	_upload_smoke()
	# Consume the flag the writes above just satisfied, so `refresh` does not
	# repeat all three a few microseconds later on the same frame.
	model.take_dirty()


## Doc 11 §2.13's governor. Exactly one knob reaches this layer:
## `particle_ratio` thins the plume, because the plume is the only part of the
## layer whose cost grows with how bad things are. The pads and the wires are
## fixed-size buffers with nothing in them worth taking away — a player on a
## thermally throttled phone still has to be able to see where their
## transformers are.
##
## It scales BOTH ends: `puffs_per_pad` so one plume is thinner, and `puff_cap`
## so a city full of trouble still lands under budget. Scaling only the cap
## would leave a two-transformer city paying full price for its smoke, which is
## the case a thermally throttled phone is most likely to be in.
func apply_governor(knobs: Dictionary) -> void:
	var ratio := clampf(float(knobs.get("particle_ratio", 1.0)), 0.0, 1.0)
	if is_equal_approx(ratio, _particle_ratio) or model == null:
		return
	_particle_ratio = ratio
	model.puff_cap = maxi(0, int(round(float(_base_puff_cap) * ratio)))
	# Never below one billboard: a transformer that is on fire has to READ as on
	# fire on every device the game ships to.
	model.puffs_per_pad = maxi(1, int(round(float(_base_puffs_per_pad) * ratio)))
	model.invalidate_puffs()
	_upload_smoke()


# ---------------------------------------------------------------- pad layer

func _build_pads() -> void:
	_pad_mesh = _build_pad_mesh()
	_pad_mm = MultiMesh.new()
	_pad_mm.transform_format = MultiMesh.TRANSFORM_3D
	_pad_mm.use_custom_data = true
	_pad_mm.mesh = _pad_mesh
	_pad_mm.instance_count = 0
	_pad_node = MultiMeshInstance3D.new()
	_pad_node.name = "TransformerPads"
	_pad_node.multimesh = _pad_mm
	# A 1.5 m cabinet with no shadow at Z0 reads as a decal on the pavement.
	# 29 k triangles in the shadow pass against the 100 k the buildings already
	# submit is a rounding error, and §2.5's "NEAR only casts" rule is about
	# per-chunk BUILDING buckets, which this is not.
	_pad_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	_pad_node.custom_aabb = AABB(Vector3(-1.0, -1.0, -1.0), Vector3(2.0, 2.0, 2.0))
	_pad_node.visible = false
	add_child(_pad_node)


func _rebuild_pad_buffer() -> void:
	var count := model.pad_count()
	_pad_mm.instance_count = count
	_pad_node.visible = count > 0
	if count == 0:
		return
	for i in count:
		var rec: PowerInfraModel.PadRec = model.pad(i)
		_pad_mm.set_instance_transform(i, Transform3D(
				Basis.from_euler(Vector3(0.0, rec.yaw, 0.0)), rec.world_pos))
	_pad_node.custom_aabb = model.pad_aabb()
	_upload_pads()
	# A rebuild can drop the selected pad (the REMOVE row on S18 is the obvious
	# way), so the ring is re-resolved against the new roster rather than left
	# hanging over ground that no longer has a transformer on it.
	if _selected_id != "":
		set_selected(_selected_id)


func _upload_pads() -> void:
	if _pad_mm == null:
		return
	for i in _pad_mm.instance_count:
		_pad_mm.set_instance_custom_data(i, model.pad_custom(i))


## The cabinet. 204 triangles, ONE mesh shared by every transformer in the city,
## and every one of them earns its place at the scale a padmount is read:
##
##   * **A concrete pad with a lip.** Two slabs, not one. The lip is what makes
##     the cabinet look SET on something rather than sunk into the road, and it
##     is the silhouette that survives when the cabinet itself is eight pixels.
##   * **Radiator panels proud of the flanks, with end ribs.** The seven fins
##     inside each panel are SHADED, not modelled (`power_pad.gdshader`'s
##     `fin_pitch_m`): geometry buys the silhouette, the shader buys the
##     corrugation, and at Z0 one fin is three pixels wide — exactly the scale
##     at which triangles cost and a groove term does not.
##   * **A lid that overhangs.** The one cue that reads at any distance as
##     "utility cabinet" rather than "box".
##   * **Three HV bushings on the lid.** The player asked for bushings by name,
##     and they are why the object is unmistakably a TRANSFORMER and not a
##     junction cabinet or a bin.
##
## Local space: origin at the pad's centre, y = 0 at grade, and the DOOR FACES
## +Z — `PowerInfraModel.yaw_for()` spins that at the street.
func _build_pad_mesh() -> ArrayMesh:
	var builder := ConstructionSiteView.PropMesh.new()
	builder.uv_tile_m = maxf(PropSurface.tile_m(), 0.01)
	var pad := model.pad_size
	var colors := _part_colors()

	# Concrete: slab, then the lip the cabinet stands on.
	var concrete := _part_color(colors, "pad", PART_PAD)
	builder.add_box(Vector3(0.0, 0.075, 0.0), Vector3(pad.x, 0.15, pad.y), concrete)
	builder.add_box(Vector3(0.0, 0.185, 0.0),
			Vector3(pad.x - 0.24, 0.07, pad.y - 0.24), concrete)

	# Cabinet body: 1.46 x 1.06 on a 1.12 m rise, standing on the lip at 0.22.
	var cab := Vector3(1.46, 1.12, 1.06)
	builder.add_box(Vector3(0.0, 0.22 + cab.y * 0.5, 0.0), cab,
			_part_color(colors, "cabinet", PART_CABINET))

	# Lid: overhangs on every side, plus a low crown.
	var lid := _part_color(colors, "lid", PART_LID)
	builder.add_box(Vector3(0.0, 1.385, 0.0), Vector3(1.60, 0.09, 1.20), lid)
	builder.add_box(Vector3(0.0, 1.455, 0.0), Vector3(1.20, 0.05, 0.86), lid)

	# Radiator panels and their end ribs, on the two flanks.
	var fin := _part_color(colors, "fin", PART_FIN)
	for side: float in [-1.0, 1.0]:
		builder.add_box(Vector3(side * 0.775, 0.72, 0.0),
				Vector3(0.09, 0.86, 0.94), fin)
		for z: float in [-0.47, 0.47]:
			builder.add_box(Vector3(side * 0.79, 0.72, z),
					Vector3(0.14, 0.90, 0.07), fin)

	# HV bushings on the lid: a post and a skirt each.
	var porcelain := _part_color(colors, "bushing", PART_BUSHING)
	for x: float in [-0.42, 0.0, 0.42]:
		builder.add_beam(Vector3(x, 1.48, -0.18), Vector3(x, 1.80, -0.18),
				0.10, porcelain)
		builder.add_box(Vector3(x, 1.66, -0.18), Vector3(0.21, 0.045, 0.21),
				porcelain)

	return builder.to_mesh(_pad_material())


## `.a` carries `part / 8` so `power_pad.gdshader` can tell concrete from
## cabinet from fin from porcelain off one channel. Eight parts is what an
## 8-bit vertex-colour channel round-trips exactly under `floor(a * 8 + 0.5)`,
## which is the trick the building shader's level atlas plays with `COLOR.a`.
func _part_color(colors: Dictionary, key: String, part: int) -> Color:
	var c: Color = colors[key]
	return Color(c.r, c.g, c.b, float(part) / 8.0)


func _part_colors() -> Dictionary:
	return {
		"pad": _color("pad_color", "#9A9891"),
		"cabinet": _color("cabinet_color", "#3C4A3F"),
		"lid": _color("lid_color", "#333F36"),
		"fin": _color("fin_color", "#42513F"),
		"bushing": _color("bushing_color", "#A29A8C"),
	}


func _color(key: String, fallback: String) -> Color:
	var hex := String(_cfg.get(key, fallback))
	return Color(hex) if Color.html_is_valid(hex) else Color(fallback)


func _pad_material() -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = load(PAD_SHADER)
	var page := _prop_page("steel")
	if page != null:
		mat.set_shader_parameter("grain_tex", page)
	mat.set_shader_parameter("fin_pitch_m", float(_cfg.get("fin_pitch_m", 0.135)))
	mat.set_shader_parameter("heat_color", _color("heat_color", "#FF6425"))
	mat.set_shader_parameter("char_color", _color("char_color", "#161311"))
	return mat


# --------------------------------------------------------------- wire layer

func _rebuild_wire_buckets() -> void:
	for chunk in _wire_chunks:
		(_wire_nodes[chunk] as Node3D).queue_free()
	_wire_nodes = {}
	_wire_chunks = []
	if _wire_mesh == null:
		_wire_mesh = _build_wire_mesh()
		_wire_material = _wire_material_new()
	var by_chunk := model.spans_by_chunk()
	var chunks: Array = by_chunk.keys()
	chunks.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
			return a.x < b.x or (a.x == b.x and a.y < b.y))
	for chunk: Vector2i in chunks:
		var indices: Array = by_chunk[chunk]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_custom_data = true
		mm.mesh = _wire_mesh
		mm.instance_count = indices.size()
		for slot in indices.size():
			mm.set_instance_transform(slot, _span_transform(int(indices[slot])))
			mm.set_instance_custom_data(slot, model.span_custom(int(indices[slot])))
		var node := MultiMeshInstance3D.new()
		node.name = "Wires_%d_%d" % [chunk.x, chunk.y]
		node.multimesh = mm
		node.material_override = _wire_material
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		# The vertex stage moves geometry the CPU-side mesh knows nothing about
		# (the sag, and the screen-space width), so the AABB has to be the
		# model's own — a bucket culled on the strip's own [0,1] box would
		# vanish the moment the camera looked slightly away from it.
		node.custom_aabb = model.span_aabb(indices)
		node.visible = false
		add_child(node)
		_wire_nodes[chunk] = node
		_wire_chunks.append(chunk)


## Instance basis: column X is the span vector (world metres), and column Y's
## LENGTH is the wire radius. `power_wire.gdshader` reads exactly those two
## things — the ribbon's orientation is derived from the CAMERA, not from the
## transform, which is why column Z is only here to keep the basis non-singular.
func _span_transform(index: int) -> Transform3D:
	var span: PowerInfraModel.SpanRec = model.spans()[index]
	var axis := span.to - span.from
	var up := Vector3.UP
	if axis.length() > 0.0001 and absf(axis.normalized().dot(up)) > 0.99:
		up = Vector3.RIGHT
	var side := axis.cross(up)
	side = side.normalized() if side.length() > 0.0001 else Vector3.RIGHT
	return Transform3D(Basis(axis, up * _wire_radius_m, side * _wire_radius_m),
			span.from)


func _upload_wire_custom() -> void:
	var by_chunk := model.spans_by_chunk()
	for chunk in _wire_chunks:
		var node: MultiMeshInstance3D = _wire_nodes[chunk]
		if not node.visible:
			continue
		var indices: Array = by_chunk.get(chunk, [])
		var mm: MultiMesh = node.multimesh
		for slot in mini(indices.size(), mm.instance_count):
			mm.set_instance_custom_data(slot, model.span_custom(int(indices[slot])))


## Submit a wire bucket only while the camera is inside `wire_gate_m` of its own
## box. `power_wire.gdshader` fades every wire to zero width by exactly that
## distance, so the gate can never be seen switching — and because
## `wire_gate_m` (110 m) is inside doc 11 §2.5's NEAR boundary (150 m), "wires
## are a NEAR-tier element" holds by construction instead of by a tier lookup
## this view would otherwise have to mirror and keep in step.
func _gate_wires(camera_pos: Vector3) -> void:
	var revealed := false
	for chunk in _wire_chunks:
		var node: MultiMeshInstance3D = _wire_nodes[chunk]
		var want := _aabb_distance(node.custom_aabb, camera_pos) <= wire_gate_m
		if want != node.visible:
			node.visible = want
			revealed = revealed or want
	if revealed:
		_upload_wire_custom()


## Push `2·tan(fov_y/2) / viewport_height` into the wire material when the
## render height changes — a resize, a fold, or a `render_scale` step from the
## governor.
##
## `power_wire.gdshader` sizes a cable in SCREEN PIXELS, and both of the
## built-ins that would answer that in-shader — `PROJECTION_MATRIX[1][1]` and
## `VIEWPORT_SIZE.y` — COMPILE in a spatial vertex shader and carry nothing
## usable there on Forward Mobile. Their product measured as zero, took the
## shader's `max(1.0, …)` guard, widened every service drop to about 130 m of
## near-opaque black and washed the entire screen at any close zoom. So the whole
## term is computed here, where both halves are known for certain: the FOV is
## doc 11's own authored `camera.fov_deg` and the height comes off the tree.
##
## Headless (no viewport) leaves the shader's default, which is the right answer
## for a harness with no pixels.
func _sync_viewport_h() -> void:
	if _wire_material == null or not is_inside_tree():
		return
	var viewport := get_viewport()
	if viewport == null:
		return
	var h := float(viewport.get_visible_rect().size.y)
	if h <= 0.0 or is_equal_approx(h, _viewport_h):
		return
	_viewport_h = h
	_wire_material.set_shader_parameter("world_per_px_at_1m",
			2.0 * tan(deg_to_rad(_fov_deg * 0.5)) / h)


static func _aabb_distance(box: AABB, point: Vector3) -> float:
	var lo := box.position
	var hi := box.position + box.size
	return Vector3(
			maxf(0.0, maxf(lo.x - point.x, point.x - hi.x)),
			maxf(0.0, maxf(lo.y - point.y, point.y - hi.y)),
			maxf(0.0, maxf(lo.z - point.z, point.z - hi.z))).length()


## The ribbon strip `power_wire.gdshader` bends. Vertex POSITIONS are never read
## by that shader — it rebuilds every vertex from `MODEL_MATRIX`, `UV` and the
## camera — but they are what Godot computes the mesh AABB from, so they are
## written honestly anyway: a unit run along +X, one metre wide.
func _build_wire_mesh() -> ArrayMesh:
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	for i in WIRE_SEGMENTS + 1:
		var t := float(i) / float(WIRE_SEGMENTS)
		for side in 2:
			verts.push_back(Vector3(t, 0.0, float(side) - 0.5))
			norms.push_back(Vector3.UP)
			uvs.push_back(Vector2(t, float(side)))
	for i in WIRE_SEGMENTS:
		var a := i * 2
		idx.append_array(PackedInt32Array([a, a + 1, a + 2]))
		idx.append_array(PackedInt32Array([a + 1, a + 3, a + 2]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _wire_material_new() -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = load(WIRE_SHADER)
	mat.set_shader_parameter("wire_color", _color("wire_color", "#14161A"))
	mat.set_shader_parameter("wire_night_color", _color("wire_night_color", "#211E1B"))
	mat.set_shader_parameter("min_px", float(_cfg.get("wire_min_px", 1.35)))
	mat.set_shader_parameter("fade_begin_m", float(_cfg.get("wire_fade_begin_m", 55.0)))
	mat.set_shader_parameter("fade_end_m", float(_cfg.get("wire_fade_end_m", 110.0)))
	mat.set_shader_parameter("wire_alpha", float(_cfg.get("wire_alpha", 0.88)))
	mat.set_shader_parameter("max_radius_m", float(_cfg.get("wire_max_radius_m", 0.30)))
	return mat


# ------------------------------------------------------------ distress layer

func _build_smoke() -> void:
	_smoke_mm = MultiMesh.new()
	_smoke_mm.transform_format = MultiMesh.TRANSFORM_3D
	_smoke_mm.use_custom_data = true
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	_smoke_mm.mesh = quad
	# Allocated ONCE at the cap and spent with `visible_instance_count`, so a
	# transformer catching fire never reallocates a buffer mid-frame.
	_smoke_mm.instance_count = maxi(model.puff_cap, 1)
	_smoke_mm.visible_instance_count = 0
	_smoke_node = MultiMeshInstance3D.new()
	_smoke_node.name = "TransformerDistress"
	_smoke_node.multimesh = _smoke_mm
	_smoke_node.material_override = _smoke_material()
	_smoke_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_smoke_node.custom_aabb = AABB(Vector3(-1.0, -1.0, -1.0), Vector3(2.0, 2.0, 2.0))
	_smoke_node.visible = false
	add_child(_smoke_node)


func _upload_smoke() -> void:
	if _smoke_mm == null:
		return
	var live := model.puffs()
	var count := mini(live.size(), _smoke_mm.instance_count)
	_smoke_mm.visible_instance_count = count
	_smoke_node.visible = count > 0
	if count == 0:
		return
	for i in count:
		var puff: PowerInfraModel.PuffRec = live[i]
		_smoke_mm.set_instance_transform(i, Transform3D(Basis.IDENTITY, puff.origin))
		_smoke_mm.set_instance_custom_data(i, model.puff_custom(i))
	_smoke_node.custom_aabb = model.puff_aabb()


func _smoke_material() -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = load(SMOKE_SHADER)
	mat.set_shader_parameter("rise_m", model.puff_rise_m)
	mat.set_shader_parameter("smoke_color", _color("smoke_color", "#4C4945"))
	mat.set_shader_parameter("smoke_day_color", _color("smoke_day_color", "#9E9A94"))
	mat.set_shader_parameter("smoke_alpha", float(_cfg.get("smoke_alpha", 0.58)))
	mat.set_shader_parameter("smoke_rate_hz", float(_cfg.get("smoke_rate_hz", 0.34)))
	mat.set_shader_parameter("spark_rate_hz", float(_cfg.get("spark_rate_hz", 0.55)))
	return mat


# ------------------------------------------------------------------ counters

## Every MultiMeshInstance3D this view currently SUBMITS — what §2.13's budget
## is counted in, and what `tests/test_power_infra.gd` asserts against. A hidden
## node is not a draw call.
func draw_calls() -> int:
	var calls := 0
	if _pad_node != null and _pad_node.visible:
		calls += 1
	# The selection ring is one unshaded quad strip and it is only ever submitted
	# while a panel is open, but §2.13 counts draw calls and not excuses.
	if _select_node != null and _select_node.visible:
		calls += 1
	if _smoke_node != null and _smoke_node.visible:
		calls += 1
	for chunk in _wire_chunks:
		if (_wire_nodes[chunk] as Node3D).visible:
			calls += 1
	return calls


func wire_bucket_count() -> int:
	return _wire_nodes.size()


func visible_wire_bucket_count() -> int:
	var count := 0
	for chunk in _wire_chunks:
		if (_wire_nodes[chunk] as Node3D).visible:
			count += 1
	return count


func pad_triangle_count() -> int:
	if _pad_mesh == null or _pad_mesh.get_surface_count() == 0:
		return 0
	return _pad_mesh.surface_get_array_index_len(0) / 3


func wire_triangle_count() -> int:
	if _wire_mesh == null:
		_wire_mesh = _build_wire_mesh()
	if _wire_mesh.get_surface_count() == 0:
		return 0
	return _wire_mesh.surface_get_array_index_len(0) / 3


func live_puff_count() -> int:
	return _smoke_mm.visible_instance_count if _smoke_mm != null else 0


## The prop pages, read straight off `tools/gen_textures.py`'s manifest rather
## than through `PropSurface`. `PropSurface` hands back a StandardMaterial3D and
## this layer needs a ShaderMaterial: doc 12 §2.5 says the OVERLAY wash is a
## building-and-ground read and a crane is neither — but a transformer IS grid,
## and the player's ask was explicitly that the power overlay light up the
## physical network. The pages themselves are shared either way.
static func _prop_page(page_name: String) -> Texture2D:
	if not _prop_pages_loaded:
		_prop_pages_loaded = true
		if ResourceLoader.exists(PROP_MANIFEST):
			var doc: Dictionary = StarterCityLoader.read_json(PROP_MANIFEST)
			for name in doc.get("props", {}):
				var path := String((doc["props"][name] as Dictionary).get("path", ""))
				if path != "" and ResourceLoader.exists(path):
					_prop_page_cache[name] = load(path)
	return _prop_page_cache.get(page_name)
