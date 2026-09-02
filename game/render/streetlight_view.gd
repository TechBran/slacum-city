class_name StreetlightView
extends Node3D
## Streetlights without dynamic lights (doc 11 §2.10): per-chunk MultiMeshes
## for poles, lamp billboards, ground light pools and the §2.9 wet smears. Lit
## state comes from the RenderStateModel's per-lamp ramps (blackout-aware);
## this view only uploads.
##
## **The OmniLight pool is not coming, and Wave 17 stopped saying it was.** The
## line that stood here for four waves ("the OmniLight pool arrives with the
## perf pass") is why §2.13's `street_lights` and `street_light_radius_m` sat
## in every preset row with no reader: they describe a pool of real lights that
## the billboard-and-decal rig replaced and made unnecessary. The radius key is
## deleted; `street_lights` now means something this file can actually do — see
## `set_light_budget()` (report 98 RR-98).
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
##
## §2.10.1's open item 1 is closed here: lamps are no longer BOOT-TIME. See
## `apply_lamps()` — a road edit re-places the city's lamps as a set difference
## on the placement key, so the street the player just laid lights up on the
## same frame its asphalt appears, and no lamp that did not move loses its ramp.

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
## The whole `data/render.json`, kept so `replace_from()` can re-run the placer
## without the shell having to hold it a second time.
var render_json: Dictionary = {}
## Local-frame offset from the pole base to the luminaire centre. Every glowing
## element hangs off THIS, not off the top of the mast, which is the difference
## between a lamp that lights the road and a stick with a halo on it.
var head_offset := Vector3(0.0, LAMP_HEIGHT, 0.0)
## The height the ground pool is uploaded at. Above the footway, which is above
## the carriageway — see `_pool_y`.
var pool_y := 0.255
var _yaw_of: Dictionary = {}             # lamp id -> radians
## Placement key (`StreetlightPlacer.key_of`) -> lamp id, and the counter new
## lamps are numbered from. This pair is what makes a re-place a DIFF: a lamp
## that is still where it was keeps its id, so it keeps its `anim_phase` and
## whatever ramp it is in the middle of, and the player sees the street they
## just laid light up without the rest of the city blinking.
var _key_to_id: Dictionary = {}
var _chunk_of_lamp: Dictionary = {}      # lamp id -> Vector2i
var _next_id: int = 100000
## Census of the last `apply_lamps` call: `{added, removed, moved, kept}`.
var last_diff: Dictionary = {"added": 0, "removed": 0, "moved": 0, "kept": 0}
## lamp id -> {base, head, pool, yaw}. The same Vector3s that go into the
## MultiMesh, kept script-side: `--headless` runs on the DUMMY rendering driver
## and `MultiMesh.get_instance_transform` reads back identity there, so a
## headless test can only check what the view publishes.
var _anchor_of: Dictionary = {}
var _lamp_ids_by_chunk: Dictionary = {}  # Vector2i -> Array[int]
var _lamp_nodes: Dictionary = {}  # Vector2i -> {lamp, pool, smear}
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
## Doc 11 §2.13's `street_lights` — the per-chunk cap on the ground pool and
## the wet smear. See `set_light_budget()` for what it does and does not gate.
## The default is Balanced's row, so a caller that never sets a preset draws
## what shipped before Wave 17 on any chunk of 12 lamps or fewer.
var light_budget: int = 12
## Last wetness this view was told about (doc 11 §2.9). Drives whether the
## smear buffer is drawn at all.
var wetness: float = 0.0


## `lamps` rows need `id`, `block_id` and `pos` (the pole BASE). `yaw` is
## optional and is the direction the cobra arm reaches in — `StreetlightPlacer`
## supplies it so every lamp leans over its own carriageway; a call site that
## omits it gets arm-along-+X, which is what every pre-cobra caller drew.
func setup(p_model: RenderStateModel, render_data: Dictionary, lamps: Array) -> void:
	model = p_model
	render_json = render_data
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
	apply_lamps(lamps)


## Doc 11 §2.13's `street_lights`, which is ladder rung 4 and which — until
## Wave 17 — nobody owned (report 98 RR-98).
##
## THE HOLE. §2.10 says the preset's `street_lights` is "how many streetlights
## are lit", and §2.13's governor drops it by 4 per step to a floor of 4. This
## file, the only file that draws a streetlight, never read the key: `preset`
## was not even a parameter of `setup()`, and `Main` routed `knobs` to
## `CityView` and `PowerInfraView` and to nothing else. So a phone in trouble
## dropped draw distance and then dropped a whole preset, having skipped a rung
## that was supposed to fire in between. The class doc's "the OmniLight pool
## arrives with the perf pass" is why: the key was authored for a pool of real
## lights that was never built, and when the billboard-and-decal rig shipped
## instead, the knob was left pointing at nothing.
##
## WHAT IT MEANS NOW, and why this reading and not another. It is the per-chunk
## cap on the two FILL layers — the ground light pool and the §2.9 wet smear —
## and NOT on the pole or the lamp billboard. That split is the whole design:
##
##   * the pole is opaque geometry a few hundred triangles wide and costs
##     nothing on a fragment-bound device, and a street whose lamp posts came
##     and went with the quality setting would be a street that changes shape;
##   * the billboard IS the lamp being lit, and §2.13's protected list exists
##     because the night city going dark is the game, not the scenery;
##   * the pool and the smear are large transparent quads over the carriageway
##     — overdraw, the one thing the Fold is actually short of.
##
## So a Performance phone still has every lamp, still lit, and sheds the glow
## on the tarmac under the farthest ones. 6 / 12 / 20 per 128 m chunk is what
## the preset table already authored and is a plausible count for a chunk; 20
## for a whole city never was.
##
## `visible_instance_count` rather than `instance_count` because raising the
## latter CLEARS the buffer (see `_sync_chunk`): the cap has to be a draw-time
## window over transforms that are already written, or every governor step
## would re-upload the city's lamps.
func set_light_budget(n: int) -> void:
	var want := maxi(0, n)
	if want == light_budget:
		return
	light_budget = want
	for chunk: Vector2i in _lamp_nodes:
		_apply_light_budget(_lamp_nodes[chunk])


## The preset's half of the same knob. Separate from `set_light_budget` so the
## governor's rung and the player's setting cannot be confused at the call
## site: `Main` calls this on a preset change and that on a governor step.
func set_preset(preset: String, render_data: Dictionary) -> void:
	var row: Dictionary = (render_data.get("presets", {}) as Dictionary).get(
			preset, {})
	set_light_budget(int(row.get("street_lights", light_budget)))


## What one chunk's four buffers are actually holding — the roster each was
## filled with, and for the two FILL layers the window `street_lights` left
## open on top of it. Published because `--headless` runs on the DUMMY driver
## and a test cannot read a MultiMesh back, so the only honest way to check
## that a budget capped the pools and left the poles alone is for this view to
## say so. Sums across chunks; with one chunk of lamps that is the chunk.
func chunk_instance_counts() -> Dictionary:
	var out := {"pole": 0, "lamp": 0, "pool": 0, "smear": 0,
			"pool_visible": 0, "smear_visible": 0}
	for chunk: Vector2i in _lamp_nodes:
		var nodes: Dictionary = _lamp_nodes[chunk]
		for key: String in ["pole", "lamp", "pool", "smear"]:
			out[key] = int(out[key]) + (nodes[key] as MultiMesh).instance_count
		out["pool_visible"] = int(out["pool_visible"]) \
				+ (nodes["pool"] as MultiMesh).visible_instance_count
		out["smear_visible"] = int(out["smear_visible"]) \
				+ (nodes["smear"] as MultiMesh).visible_instance_count
	return out


## RR-83 in its per-buffer form: a MultiMesh whose window is empty does not get
## submitted at all, it is hidden. A `visible_instance_count` of 0 still costs
## the draw call on some drivers, and 0 is exactly what a governor at the floor
## of a very small chunk produces.
func _apply_light_budget(nodes: Dictionary) -> void:
	var pool: MultiMesh = nodes["pool"]
	var smear: MultiMesh = nodes["smear"]
	var shown := mini(pool.instance_count, light_budget)
	pool.visible_instance_count = shown
	smear.visible_instance_count = shown
	(nodes["pool_node"] as MultiMeshInstance3D).visible = shown > 0
	var smear_node: MultiMeshInstance3D = nodes["smear_node"]
	smear_node.visible = _smear_visible and shown > 0


## Re-place the city's lamps against a fresh `StreetlightPlacer.place()` result.
##
## This is the whole of doc 11 §2.10.1's open item 1. Lamps were BOOT-TIME: a
## road the player laid got asphalt on the next frame and lamps on the next
## LOAD, because there was no way to retire a record — `RenderStateModel` could
## add a streetlight and nothing else. Now the pass is a set difference on the
## PLACEMENT key (`tile + kerb side`, never the ordinal id):
##
##   * a key that is in the new placement and not the old is a NEW lamp, numbered
##     from the same monotone counter the boot pass used;
##   * a key in the old and not the new is retired through
##     `RenderStateModel.remove_streetlight`, which is the API that did not exist;
##   * a key in both KEEPS ITS ID, so `anim_phase`, the lit ramp and the block
##     stutter it is in the middle of all survive the edit. That is why the key
##     is the placement and not the row's ordinal: `place()` numbers its rows in
##     (y, x, side) order, so one new tile at the top-left renumbers every lamp
##     below it, and an id-keyed diff would retire and re-create the whole city.
##
## Only the chunks whose roster or geometry actually changed are re-uploaded.
## Returns `last_diff`.
func apply_lamps(lamps: Array) -> Dictionary:
	var want: Dictionary = {}
	var order: Array[int] = []
	for raw: Variant in lamps:
		var row: Dictionary = raw
		var key := int(row["key"]) if row.has("key") else \
				StreetlightPlacer.key_of(row.get("tile", Vector2i.ZERO),
						int(row.get("side", 0)))
		if want.has(key):
			continue   # two lamps on one kerb is not a placement this view draws
		want[key] = row
		order.append(key)
	# First call: adopt the placer's own numbering, so a booted city is
	# numbered exactly as it was before this diff existed and no `anim_phase`
	# in the game moves. `place()` emits its rows in the same order.
	if _key_to_id.is_empty() and not lamps.is_empty():
		_next_id = int((lamps[0] as Dictionary).get("id", _next_id))

	var dirty: Dictionary = {}     # Vector2i chunk -> true
	var diff := {"added": 0, "removed": 0, "moved": 0, "kept": 0}

	var stale: Array[int] = []
	for key: int in _key_to_id:
		if not want.has(key):
			stale.append(key)
	stale.sort()
	for key: int in stale:
		var id := int(_key_to_id[key])
		var chunk: Vector2i = _chunk_of_lamp.get(id, Vector2i.ZERO)
		var ids: Variant = _lamp_ids_by_chunk.get(chunk)
		if ids is Array:
			(ids as Array).erase(id)
			dirty[chunk] = true
		model.remove_streetlight(id)
		_key_to_id.erase(key)
		_chunk_of_lamp.erase(id)
		_yaw_of.erase(id)
		_anchor_of.erase(id)
		diff["removed"] = int(diff["removed"]) + 1

	for key: int in order:
		var row: Dictionary = want[key]
		var pos: Vector3 = row["pos"]
		var yaw := float(row.get("yaw", 0.0))
		var fresh := not _key_to_id.has(key)
		var id := 0
		if fresh:
			id = _next_id
			_next_id += 1
			_key_to_id[key] = id
			diff["added"] = int(diff["added"]) + 1
		else:
			id = int(_key_to_id[key])
			var old: RenderStateModel.StreetlightRec = model.streetlight(id)
			if old != null and old.world_pos.is_equal_approx(pos) \
					and is_equal_approx(float(_yaw_of.get(id, 0.0)), yaw):
				diff["kept"] = int(diff["kept"]) + 1
				continue
			diff["moved"] = int(diff["moved"]) + 1
		_yaw_of[id] = yaw
		var rec := model.add_streetlight(id, row["block_id"], pos)
		var was: Variant = _chunk_of_lamp.get(id)
		if was != null and Vector2i(was) != rec.chunk:
			var ids: Variant = _lamp_ids_by_chunk.get(Vector2i(was))
			if ids is Array:
				(ids as Array).erase(id)
			dirty[Vector2i(was)] = true
		if was == null or Vector2i(was) != rec.chunk:
			if not _lamp_ids_by_chunk.has(rec.chunk):
				_lamp_ids_by_chunk[rec.chunk] = []
			var list: Array = _lamp_ids_by_chunk[rec.chunk]
			list.append(id)
			list.sort()
			_chunk_of_lamp[id] = rec.chunk
		dirty[rec.chunk] = true

	var coords: Array = dirty.keys()
	coords.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return a.y < b.y if a.y != b.y else a.x < b.x)
	for chunk: Vector2i in coords:
		_sync_chunk(chunk)
	last_diff = diff
	refresh()
	return diff


## Re-run the placer over the live road layer and diff the result in. This is
## the one call the shell makes wherever it rebuilds the road surface, and it is
## safe to call for an edit that moved no lamp: the diff comes back all `kept`
## and not one buffer is touched.
func replace_from(grid: TileGrid, graph: RoadGraph,
		block_of: Callable = Callable()) -> Dictionary:
	if model == null:
		return last_diff
	return apply_lamps(StreetlightPlacer.place(grid, graph, render_json, block_of))


## How many lamps this view is drawing.
func lamp_count() -> int:
	return _key_to_id.size()


## The lamp id standing on `tile`'s `side` kerb, or -1.
func lamp_id_at(tile: Vector2i, side: int) -> int:
	return int(_key_to_id.get(StreetlightPlacer.key_of(tile, side), -1))


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


## Bring one chunk's four buffers in line with its lamp roster, building the
## nodes on first use and RESIZING them afterwards. Re-entrant on purpose: a
## road edit re-places the lamps in the chunks it touched and nowhere else, so
## this runs for one or two chunks out of the 49 and the rest of the city is
## not re-uploaded at all.
func _sync_chunk(chunk: Vector2i) -> void:
	var ids: Array = _lamp_ids_by_chunk.get(chunk, [])
	if ids.is_empty():
		_free_chunk(chunk)
		return
	if not _lamp_nodes.has(chunk):
		_build_chunk(chunk)
		return
	var nodes: Dictionary = _lamp_nodes[chunk]
	var count := ids.size()
	# Raising `instance_count` clears the buffer, which is why every instance is
	# rewritten below rather than patched.
	for key: String in ["lamp", "pool", "smear", "pole"]:
		(nodes[key] as MultiMesh).instance_count = count
	_write_chunk(ids, nodes["lamp"], nodes["pool"], nodes["smear"], nodes["pole"])
	_apply_light_budget(nodes)


func _free_chunk(chunk: Vector2i) -> void:
	_lamp_ids_by_chunk.erase(chunk)
	if not _lamp_nodes.has(chunk):
		return
	var nodes: Dictionary = _lamp_nodes[chunk]
	for key: String in ["lamp_node", "pool_node", "smear_node", "pole_node"]:
		var node: MultiMeshInstance3D = nodes[key]
		if node == null:
			continue
		if node.get_parent() == self:
			remove_child(node)
		node.queue_free()
	_lamp_nodes.erase(chunk)


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

	var pole_mm := MultiMesh.new()
	pole_mm.transform_format = MultiMesh.TRANSFORM_3D
	pole_mm.mesh = _pole_mesh()
	pole_mm.instance_count = count
	var pole_node := MultiMeshInstance3D.new()
	pole_node.multimesh = pole_mm
	pole_node.custom_aabb = aabb
	add_child(pole_node)

	_write_chunk(ids, lamp_mm, pool_mm, smear_mm, pole_mm)
	_lamp_nodes[chunk] = {"lamp": lamp_mm, "pool": pool_mm, "smear": smear_mm,
			"pole": pole_mm, "lamp_node": lamp_node, "pool_node": pool_node,
			"smear_node": smear_node, "pole_node": pole_node}
	_apply_light_budget(_lamp_nodes[chunk])


func _write_chunk(ids: Array, lamp_mm: MultiMesh, pool_mm: MultiMesh,
		smear_mm: MultiMesh, pole_mm: MultiMesh) -> void:
	# The smear spans road → lamp, so its quad is stretched off the 1.6 m
	# billboard: narrower across, LAMP_HEIGHT tall.
	var smear_basis := Basis.IDENTITY.scaled(
			Vector3(0.55, head_offset.y / maxf(0.01, _lamp_quad_m), 1.0))
	for i in ids.size():
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
		# The wetness gate and §2.13's `street_lights` cap compose: a chunk
		# whose window is empty stays hidden through a downpour.
		for chunk_key: Vector2i in _lamp_nodes:
			var nodes: Dictionary = _lamp_nodes[chunk_key]
			(nodes["smear_node"] as MultiMeshInstance3D).visible = want_smear \
					and (nodes["smear"] as MultiMesh).visible_instance_count > 0
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
