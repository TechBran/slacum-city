extends SimTest
## The MEDIUM bucket merge — doc 11 §2.6, doc 91 D-14.
##
## `CityView` allocated one MultiMesh per (chunk, archetype, LEVEL). The
## benchmark city measured that at **16.4 nodes per chunk** where §2.13's
## draw-call arithmetic assumes 6, and Z2 broke the Balanced budget: 352 calls
## against 320. MEDIUM now draws ONE MultiMesh per (chunk, ARCHETYPE), over an
## ArrayMesh that concatenates the levels the chunk actually holds; the level
## rides in the packed `.b` channel at stride 448 and the vertex stage collapses
## the levels an instance is not.
##
## Two contracts are load-bearing here and everything below exists to hold them:
##
## 1. **§2.6's packing does not move.** `variant`, `stage` and `overlay_state`
##    must decode to the same values after `+ 448·level` as before, or the
##    blackout read, the construction shell and the overlay all shift at the
##    150 m boundary. 448 is chosen for exactly that reason and the arithmetic
##    is exhaustively checked below, not argued.
## 2. **The merged buffer is the mirror.** Every channel but `.b` is copied
##    verbatim out of `RenderStateModel`'s bucket mirrors, so a chunk crossing
##    into MEDIUM mid-blackout carries its exact emissive ramp across — the same
##    guarantee the FAR tier makes, and for the same reason.

const BUILDING := "res://game/shaders/building.gdshader"
const STRIDE := 16


func _data() -> Dictionary:
	return StarterCityLoader.read_json("res://data/render.json")


func _src(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var text := f.get_as_text()
	f.close()
	return text


## One chunk holding four levels of `house` and two of `office`, plus a second
## chunk 1 km east so the FAR tier is in the picture too. SEVEN buckets over two
## chunks; merged, chunk (0,0) is two nodes and the far one is a third.
func _mixed_model() -> RenderStateModel:
	var model := RenderStateModel.new(_data())
	var id := 1
	var rows := [
		["house", 1, "residential", Vector3(12.0, 0.0, 12.0)],
		["house", 1, "residential", Vector3(28.0, 0.0, 12.0)],
		["house", 2, "residential", Vector3(44.0, 0.0, 12.0)],
		["house", 3, "residential", Vector3(60.0, 0.0, 12.0)],
		["house", 5, "residential", Vector3(76.0, 0.0, 12.0)],
		["office", 2, "commercial", Vector3(12.0, 0.0, 60.0)],
		["office", 4, "commercial", Vector3(44.0, 0.0, 60.0)],
		["apartment", 3, "residential", Vector3(1064.0, 0.0, 40.0)],
	]
	for entry: Array in rows:
		var pos: Vector3 = entry[3]
		model.add_building({
			"id": id, "archetype_id": StringName(entry[0]), "level": int(entry[1]),
			"family": String(entry[2]), "world_pos": pos, "block_id": "B",
			"transform": Transform3D(Basis.IDENTITY, pos),
			"occ_b": 0.8, "powered": true, "condition": 1.0})
		id += 1
	return model


## A camera 250 m straight up over chunk (0,0): 250 m is inside §2.5's MEDIUM
## band (150 < d ≤ 420) and chunk (8,0) is ~990 m out, which is FAR.
const MEDIUM_CAMERA := Vector3(64.0, 250.0, 64.0)


func _view(model: RenderStateModel) -> CityView:
	var view := CityView.new()
	view.keep_medium_buffers = true
	view.setup(model, _data())
	return view


# ═══════════════ 1. the packing — 448 cannot move §2.6's fields ═════════════

func test_the_level_stride_leaves_every_locked_field_where_it_was() -> void:
	# Exhaustive over §2.6's whole packed space (16 variants × 7 stages × 4
	# overlay states = 448 combinations) crossed with all five levels. This is
	# the test that makes 448 a fact rather than a claim: `448 = 16·28` and
	# `28 ≡ 0 (mod 7)`, so neither `mod(p, 16)` nor `mod(floor(p/16), 7)` can
	# see the addition at all.
	for variant in 16:
		for stage in 7:
			for overlay in 4:
				var base := RenderStateModel.pack_state(variant, stage, overlay)
				for level in range(1, CityView.LEVEL_MAX + 1):
					var packed: float = base + CityView.PACK_LEVEL_STRIDE * float(level)
					assert_almost_eq(fmod(packed, 16.0), float(variant), 1e-6,
							"variant survives +448·%d" % level)
					assert_almost_eq(fmod(floor(packed / 16.0), 7.0), float(stage), 1e-6,
							"stage survives +448·%d" % level)
					# The shader's `overlay_of` is `mod(floor(p/112), 4)`, which is
					# what a `clamp(…, 0, 3)` cannot be — the whole reason that one
					# line changed.
					assert_almost_eq(fmod(floor(packed / 112.0), 4.0), float(overlay), 1e-6,
							"overlay_state survives +448·%d" % level)
					assert_almost_eq(floor(packed / CityView.PACK_LEVEL_STRIDE),
							float(level), 1e-6, "…and the level reads back")


func test_the_packed_maximum_is_exact_in_a_float() -> void:
	# 447 + 448·6 = 3135, since doc 02 §2.14's tower tier took LEVEL_MAX to 6.
	# A MultiMesh custom-data channel is an f32 and integers below 2^24 are exact
	# in one, so the decoders above are exact too — this is the bound that says
	# so out loud, and 2^24 is 5,354× the headroom it needs.
	var top: float = RenderStateModel.pack_state(15, 6, 3) \
			+ CityView.PACK_LEVEL_STRIDE * float(CityView.LEVEL_MAX)
	assert_almost_eq(top, 3135.0, 1e-9, "the largest value the merge can pack")
	assert_true(top < 16777216.0, "and it is exact in an f32")
	# `COLOR.a = level / 8` is the vertex tag, and 8 is the hard ceiling: a
	# seventh rung is fine, a ninth is not representable.
	assert_true(CityView.LEVEL_MAX <= 8,
			"the level tag is level/8 through an 8-bit channel")
	assert_true(top < 16777216.0, "…and it is inside f32's exact-integer range")


# ═══════════════════════ 2. the merge itself ════════════════════════════════

func test_a_medium_chunk_draws_one_multimesh_per_archetype() -> void:
	var model := _mixed_model()
	var view := _view(model)
	view.refresh(0.1, 21.0, MEDIUM_CAMERA)
	assert_eq(model.chunk_tier(Vector2i(0, 0)), RenderStateModel.TIER_MEDIUM,
			"250 m up is inside §2.5's MEDIUM band")
	assert_eq(model.chunk_tier(Vector2i(8, 0)), RenderStateModel.TIER_FAR,
			"and the chunk 1 km east is FAR")
	var stats := view.perf_stats()
	assert_eq(int(stats["bucket_calls"]), 0,
			"not one per-(archetype, level) bucket is submitted at MEDIUM")
	assert_eq(int(stats["merged_calls"]), 2,
			"house and office: TWO nodes for the chunk's six buckets")
	assert_eq(int(stats["far_calls"]), 1, "the far chunk is still one box")
	assert_eq(view.building_draw_calls(), 3,
			"7 buckets over 2 chunks cost 2 + 1 calls, not 7")
	view.free()


func test_the_merge_switches_off_and_the_per_level_buckets_come_back() -> void:
	var model := _mixed_model()
	var view := CityView.new()
	view.medium_merge_enabled = false
	view.setup(model, _data())
	view.refresh(0.1, 21.0, MEDIUM_CAMERA)
	var stats := view.perf_stats()
	assert_eq(int(stats["merged_calls"]), 0, "no merged nodes with the merge off")
	assert_eq(int(stats["bucket_calls"]), 6,
			"the pre-D-14 renderer: one node per (archetype, level)")
	assert_eq(view.building_draw_calls(), 7, "…plus the one far box")
	view.free()


func test_a_near_chunk_is_untouched_by_the_merge() -> void:
	# The whole point of stopping at MEDIUM. NEAR keeps its per-(archetype,
	# level) LOD0 buckets, byte for byte the renderer that shipped.
	var model := _mixed_model()
	var view := _view(model)
	view.refresh(0.1, 21.0, Vector3(64.0, 20.0, 64.0))
	assert_eq(model.chunk_tier(Vector2i(0, 0)), RenderStateModel.TIER_NEAR)
	var stats := view.perf_stats()
	assert_eq(int(stats["merged_calls"]), 0, "no merged node for a NEAR chunk")
	assert_eq(int(stats["bucket_calls"]), 6, "all six buckets draw, as before")
	view.free()


# ══════════════ 3. the merged buffer IS the mirror, plus the level ══════════

func test_the_merged_buffer_copies_the_mirror_and_adds_only_the_level() -> void:
	var model := _mixed_model()
	var view := _view(model)
	view.refresh(0.1, 21.0, MEDIUM_CAMERA)
	var merged := view.medium_buffer(Vector2i(0, 0), "house")
	assert_eq(merged.size(), 5 * STRIDE, "five houses in one buffer")
	# Rebuild the expectation straight out of the model's own bucket mirrors.
	var seen := 0
	for level in [1, 2, 3, 5]:
		var bucket := model.bucket(Vector2i(0, 0), &"house", level)
		assert_true(bucket != null, "house L%d has a bucket" % level)
		for slot in bucket.visible_count:
			var src := slot * STRIDE
			var dst := seen * STRIDE
			for i in STRIDE:
				if i == 14:
					continue  # `.b`, checked below
				assert_almost_eq(merged[dst + i], bucket.mirror[src + i], 1e-9,
						"float %d of instance %d is the mirror verbatim" % [i, seen])
			assert_almost_eq(merged[dst + 14],
					bucket.mirror[src + 14] + CityView.PACK_LEVEL_STRIDE * float(level),
					1e-6, "`.b` carries the level above §2.6's fields")
			seen += 1
	assert_eq(seen, 5, "every house was folded in")
	view.free()


func test_a_blacked_out_chunk_carries_its_ramp_through_the_merge() -> void:
	# The MEDIUM equivalent of the far tier's guarantee. `.r` is the emissive
	# ramp and it is copied, never recomputed, so a chunk that crosses into
	# MEDIUM in the middle of a blackout does not restart its fall.
	var model := _mixed_model()
	var view := _view(model)
	view.refresh(0.1, 21.0, MEDIUM_CAMERA)
	var lit := view.medium_buffer(Vector2i(0, 0), "house")
	assert_true(lit[12] > 0.5, "a powered house is lit before the cut")
	model.plan_blackout("B")
	model.advance(30.0)
	view.refresh(0.1, 21.0, MEDIUM_CAMERA)
	var dark := view.medium_buffer(Vector2i(0, 0), "house")
	assert_true(dark[12] < lit[12], "the ramp fell, in the merged buffer")
	var bucket := model.bucket(Vector2i(0, 0), &"house", 1)
	assert_almost_eq(dark[12], bucket.mirror[12], 1e-9,
			"and it is the model's own value, copied rather than derived")
	view.free()


func test_the_overlay_state_still_decodes_out_of_the_merged_packing() -> void:
	# `.b` now carries four fields. The one doc 12 §2.5 reads has to come back
	# out of a MERGED instance exactly as it goes into an un-merged one.
	var model := _mixed_model()
	model.set_overlay_channel(&"water", {1: RenderStateModel.OVERLAY_OFFLINE})
	var view := _view(model)
	view.set_overlay_mode(&"water", MEDIUM_CAMERA)
	view.refresh(0.1, 21.0, MEDIUM_CAMERA)
	var merged := view.medium_buffer(Vector2i(0, 0), "house")
	var states: Dictionary = {}
	for i in merged.size() / STRIDE:
		var packed := merged[i * STRIDE + 14]
		states[int(fmod(floor(packed / 112.0), 4.0))] = true
	assert_true(states.has(RenderStateModel.OVERLAY_OFFLINE),
			"the OFFLINE building is still OFFLINE inside the merged buffer")
	assert_true(states.has(RenderStateModel.OVERLAY_NORMAL),
			"…and its neighbours are still NORMAL, so the level did not smear "
			+ "the overlay field across the archetype")
	view.free()


# ═══════════════════════ 4. the atlas mesh ══════════════════════════════════

func test_the_atlas_tags_each_level_in_the_free_vertex_channel() -> void:
	var view := _view(_mixed_model())
	var mesh: Mesh = view._atlas_for("house", 0b10111)  # levels 1,2,3,5
	assert_true(mesh != null, "the atlas builds from the gray-box manifest")
	var arrays: Array = mesh.surface_get_arrays(0)
	var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	var levels: Dictionary = {}
	for c: Color in colors:
		# `level / 8` round-trips through the 8-bit vertex colour exactly for
		# 1..5, which is why the shader rounds instead of comparing.
		var level := int(round(c.a * 8.0))
		levels[level] = true
		assert_true(level >= 1 and level <= CityView.LEVEL_MAX,
				"COLOR.a decodes to a real level, got %d" % level)
	assert_eq(levels.size(), 4, "exactly the four levels the mask asked for")
	assert_false(levels.has(4), "and NOT the level it did not")
	view.free()


func test_the_atlas_carries_only_the_levels_the_chunk_holds() -> void:
	# The reason the merge does not cost 3.5× the triangles: a chunk that holds
	# two levels of an archetype submits two levels' geometry, not five.
	var view := _view(_mixed_model())
	var one: Mesh = view._atlas_for("house", 0b00001)
	var four: Mesh = view._atlas_for("house", 0b10111)
	var all_five: Mesh = view._atlas_for("house", 0b11111)
	var n_one: int = (one.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	var n_four: int = (four.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	var n_all: int = (all_five.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	assert_true(n_one < n_four and n_four < n_all,
			"the mask is what sizes the atlas (%d < %d < %d)" % [n_one, n_four, n_all])
	# A one-level mask is exactly the un-merged mesh, so a chunk with one level
	# of an archetype pays nothing at all for the merge.
	var lod0: Dictionary = view._manifest_by_key["house:1:%d" % view.atlas_lod]
	var plain: Mesh = load(String(lod0["path"]))
	assert_eq(n_one,
			(plain.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size(),
			"a single-level atlas is the level's own mesh, vertex for vertex")
	view.free()


func test_the_atlas_bakes_the_window_grid_into_uv2_and_keeps_the_sentinels() -> void:
	# `window_cols` / `window_rows` are per-MESH uniforms and five meshes cannot
	# share one, so the grid is multiplied into UV2 and the uniforms go to 1.0 —
	# `floor(UV2 * vec2(cols, rows))` lands on the same cell either way and
	# §2.6's `lit = step(1 - e, h)` never notices. The (-1,-1) and (-1,-2)
	# sentinels are NOT scaled: they are read by `step`s against 0.0 and -1.5,
	# and a windowless archetype (cols = 0) would have its sentinel multiplied
	# to (0, 0) and light up.
	var view := _view(_mixed_model())
	var entry: Dictionary = view._manifest_by_key["office:2:%d" % view.atlas_lod]
	var cols := float(entry["window_cols"])
	var rows := float(entry["window_rows"])
	assert_true(cols > 1.0 and rows > 1.0, "office L2 has a real window grid")
	var plain: Mesh = load(String(entry["path"]))
	var src_uv2: PackedVector2Array = plain.surface_get_arrays(0)[Mesh.ARRAY_TEX_UV2]
	var atlas: Mesh = view._atlas_for("office", 0b00010)  # level 2 only
	var out_uv2: PackedVector2Array = atlas.surface_get_arrays(0)[Mesh.ARRAY_TEX_UV2]
	assert_eq(out_uv2.size(), src_uv2.size(), "one atlas vertex per source vertex")
	var scaled := 0
	var kept := 0
	for i in src_uv2.size():
		var w := src_uv2[i]
		if w.x < 0.0:
			assert_eq(out_uv2[i], w, "the sentinel is copied, never scaled")
			kept += 1
		else:
			assert_almost_eq(out_uv2[i].x, w.x * cols, 1e-5, "UV2.x carries the columns")
			assert_almost_eq(out_uv2[i].y, w.y * rows, 1e-5, "UV2.y carries the rows")
			scaled += 1
	assert_true(scaled > 0 and kept > 0, "both kinds of surface are present")
	view.free()


func test_a_windowless_archetype_keeps_its_dark_walls() -> void:
	# data_center is `windowless` with cols = rows = 0. Scaling a façade UV2 by
	# zero is harmless — `floor(0 * anything)` is cell (0,0) either way — but
	# scaling the (-1,-1) SENTINEL by zero would turn it into (0,0), flip the
	# shader's `has_uv2` test and light a blank cassette wall.
	var view := _view(_mixed_model())
	var entry: Dictionary = view._manifest_by_key["data_center:1:%d" % view.atlas_lod]
	assert_almost_eq(float(entry["window_cols"]), 0.0, 1e-9, "windowless, by the manifest")
	var atlas: Mesh = view._atlas_for("data_center", 0b00001)
	var out_uv2: PackedVector2Array = atlas.surface_get_arrays(0)[Mesh.ARRAY_TEX_UV2]
	var sentinels := 0
	for w: Vector2 in out_uv2:
		if w.x < 0.0:
			sentinels += 1
	var src_uv2: PackedVector2Array = (load(String(entry["path"])) as Mesh) \
			.surface_get_arrays(0)[Mesh.ARRAY_TEX_UV2]
	var want := 0
	for w: Vector2 in src_uv2:
		if w.x < 0.0:
			want += 1
	assert_eq(sentinels, want, "every sentinel survived the bake")
	view.free()


func test_the_atlas_material_carries_the_per_level_construction_heights() -> void:
	# One merged mesh, five heights: the shader's construction clamp needs the
	# INSTANCE's own `build_height_m`, and a single uniform cannot be five
	# numbers. `level_build_height[]` is, and it is indexed by the same absolute
	# level the vertex tag uses.
	var view := _view(_mixed_model())
	var heights := view.atlas_heights("house")
	assert_eq(heights.size(), CityView.LEVEL_MAX + 1, "indexed 0..5, 0 unused")
	for level in range(1, CityView.LEVEL_MAX + 1):
		var entry: Dictionary = view._manifest_by_key["house:%d:%d" % [level, view.atlas_lod]]
		assert_almost_eq(heights[level], float(entry["height_m"]), 1e-6,
				"L%d's height is the manifest's own" % level)
	assert_true(heights[5] > heights[1], "…and the ladder climbs")
	view.free()


# ══════════════════════ 5. §2.5's MEDIUM row, finally honoured ══════════════

func test_a_merged_medium_node_never_casts_a_shadow_and_never_flickers() -> void:
	# §2.5's table: "MEDIUM … no shadows … per-window hash, no flicker". The
	# un-merged path inherited NEAR's settings for both, and got away with the
	# shadow half only because a MEDIUM chunk is past
	# `directional_shadow_max_distance` anyway.
	var view := _view(_mixed_model())
	view.refresh(0.1, 21.0, MEDIUM_CAMERA)
	var found := 0
	for child in view.get_children():
		var node := child as MultiMeshInstance3D
		if node == null or not node.name.begins_with("MM_med_"):
			continue
		found += 1
		assert_eq(node.cast_shadow, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF,
				"%s casts no shadow" % node.name)
		var material := node.material_override as ShaderMaterial
		assert_almost_eq(float(material.get_shader_parameter("near_flicker")), 0.0, 1e-9,
				"%s does not flicker" % node.name)
		assert_almost_eq(float(material.get_shader_parameter("level_atlas")), 1.0, 1e-9,
				"%s runs the atlas gate" % node.name)
		assert_almost_eq(float(material.get_shader_parameter("window_cols")), 1.0, 1e-9,
				"the grid moved into UV2, so the multiply is by one")
	assert_eq(found, 2, "both merged nodes were checked")
	view.free()


func test_the_atlas_material_is_one_per_archetype_not_one_per_chunk() -> void:
	# 591 bucket nodes meant 591 ShaderMaterials, against §2.6's stated 150.
	# Nothing in the merged uniform set varies by chunk or by level any more —
	# the grid is in UV2 and the heights are in an array — so one material per
	# archetype serves the whole city.
	var model := _mixed_model()
	# A second MEDIUM chunk holding the same archetype.
	model.add_building({"id": 90, "archetype_id": &"house", "level": 2,
			"family": "residential", "world_pos": Vector3(200.0, 0.0, 12.0),
			"block_id": "B",
			"transform": Transform3D(Basis.IDENTITY, Vector3(200.0, 0.0, 12.0)),
			"occ_b": 0.8, "powered": true, "condition": 1.0})
	var view := _view(model)
	view.refresh(0.1, 21.0, Vector3(128.0, 250.0, 64.0))
	var materials: Dictionary = {}
	var nodes := 0
	for child in view.get_children():
		var node := child as MultiMeshInstance3D
		if node == null or not node.name.begins_with("MM_med_house_"):
			continue
		nodes += 1
		materials[node.material_override.get_instance_id()] = true
	assert_true(nodes >= 2, "two chunks drew `house` (%d)" % nodes)
	assert_eq(materials.size(), 1, "and they share ONE material")
	view.free()


# ══════════════════════ 6. the shader source contract ══════════════════════

func test_the_building_shader_gate_is_an_identity_when_the_atlas_is_off() -> void:
	var src := _src(BUILDING)
	assert_ne(src, "", "the building shader is on disk")
	assert_true(src.contains("uniform float level_atlas = 0.0;"),
			"OFF is the default, so every existing material is untouched")
	assert_true(src.contains("uniform float level_build_height[%d];"
				% (CityView.LEVEL_MAX + 1)),
			"one height per level plus the unused 0 slot")
	assert_true(src.contains("step(0.5, level_atlas)"),
			"the gate is branchless and multiplied out at 0 — no divergence, and "
			+ "no path where the NEAR tier pays for a feature it does not use")
	assert_true(src.contains("mod(floor(packed / 112.0), 4.0)"),
			"overlay_of wraps rather than clamps, or every merged instance reads "
			+ "OFFLINE the moment a level is packed above it")
	assert_false(src.contains("clamp(floor(packed / 112.0)"),
			"…and the clamp is gone, not merely shadowed")
	# §2.6's two mirrored decoders must be untouched by the whole pass.
	assert_true(src.contains("mod(floor(packed / 16.0), 7.0)"), "stage_of is unmoved")
	assert_true(src.contains("float variant = mod(packed, 16.0);"),
			"and variant is still the low 4 bits")


func test_the_shader_selects_a_level_by_vertex_tag_and_collapses_the_rest() -> void:
	var src := _src(BUILDING)
	assert_true(src.contains("round(COLOR.a * 8.0)"),
			"the level tag is rounded out of the 8-bit vertex colour channel")
	assert_true(src.contains("VERTEX *="),
			"a vertex of another level is collapsed, not discarded: zero-area "
			+ "triangles cost no fragment and leave early-Z alone")
	assert_false(src.contains("discard;"),
			"nothing in this shader may discard — it would break early-Z for the "
			+ "whole city to save a few triangles")


# ═════════ 7. the mask at runtime — the one piece of mutable state ══════════
#
# `_medium_node_for` swaps a node's mesh when the chunk's level set moves. That
# is the only mutation in the merged tier and it fires exactly where a bug is
# hardest to see: a building is built, upgraded or demolished, and from the next
# frame the atlas either carries a level nothing needs or is MISSING the level an
# instance asks for — which draws nothing at all, and says nothing about it.

func test_a_chunk_that_gains_a_level_gets_a_wider_atlas() -> void:
	var model := RenderStateModel.new(_data())
	model.add_building({"id": 1, "archetype_id": &"house", "level": 1,
			"family": "residential", "world_pos": Vector3(12.0, 0.0, 12.0),
			"block_id": "B",
			"transform": Transform3D(Basis.IDENTITY, Vector3(12.0, 0.0, 12.0)),
			"occ_b": 0.8, "powered": true, "condition": 1.0})
	var view := _view(model)
	view.refresh(0.1, 21.0, MEDIUM_CAMERA)
	var narrow: Mesh = view._atlas_for("house", 0b00001)
	var node := _merged_node(view, "house")
	assert_true(node != null, "the chunk drew a merged house node")
	assert_eq(node.multimesh.mesh, narrow, "one level in, one level in the atlas")

	# The city grows a taller house on the same block.
	model.add_building({"id": 2, "archetype_id": &"house", "level": 3,
			"family": "residential", "world_pos": Vector3(28.0, 0.0, 12.0),
			"block_id": "B",
			"transform": Transform3D(Basis.IDENTITY, Vector3(28.0, 0.0, 12.0)),
			"occ_b": 0.8, "powered": true, "condition": 1.0})
	view.refresh(0.1, 21.0, MEDIUM_CAMERA)
	var wide: Mesh = view._atlas_for("house", 0b00101)
	assert_eq(node.multimesh.mesh, wide,
			"the node swapped to the atlas that HAS level 3 — without the swap "
			+ "the new building would draw nothing and never say so")
	assert_ne(wide, narrow, "and that is a different mesh")
	assert_eq(int(view.perf_stats()["merged_calls"]), 1,
			"still ONE node: a new level is a wider atlas, not a second draw call")
	var merged := view.medium_buffer(Vector2i(0, 0), "house")
	assert_eq(merged.size(), 2 * STRIDE, "both houses are in the one buffer")
	var levels: Dictionary = {}
	for i in 2:
		levels[int(floor(merged[i * STRIDE + 14] / CityView.PACK_LEVEL_STRIDE))] = true
	assert_true(levels.has(1) and levels.has(3),
			"and each carries its own level, not the chunk\'s")
	view.free()


func test_a_chunk_that_loses_a_level_goes_back_to_the_narrow_atlas() -> void:
	var model := RenderStateModel.new(_data())
	for row: Array in [[1, 1, Vector3(12.0, 0.0, 12.0)], [2, 3, Vector3(28.0, 0.0, 12.0)]]:
		model.add_building({"id": int(row[0]), "archetype_id": &"house",
				"level": int(row[1]), "family": "residential", "world_pos": row[2],
				"block_id": "B", "transform": Transform3D(Basis.IDENTITY, row[2]),
				"occ_b": 0.8, "powered": true, "condition": 1.0})
	var view := _view(model)
	view.refresh(0.1, 21.0, MEDIUM_CAMERA)
	var node := _merged_node(view, "house")
	assert_eq(node.multimesh.mesh, view._atlas_for("house", 0b00101))
	model.remove_building(2)
	view.refresh(0.1, 21.0, MEDIUM_CAMERA)
	assert_eq(node.multimesh.mesh, view._atlas_for("house", 0b00001),
			"the demolished level\'s triangles stop being submitted — an emptied "
			+ "bucket must not keep paying for itself every frame")
	assert_eq(view.medium_buffer(Vector2i(0, 0), "house").size(), STRIDE,
			"and one house is left in the buffer")
	view.free()


func test_the_last_building_leaving_stands_the_merged_node_down() -> void:
	var model := RenderStateModel.new(_data())
	model.add_building({"id": 1, "archetype_id": &"house", "level": 1,
			"family": "residential", "world_pos": Vector3(12.0, 0.0, 12.0),
			"block_id": "B",
			"transform": Transform3D(Basis.IDENTITY, Vector3(12.0, 0.0, 12.0)),
			"occ_b": 0.8, "powered": true, "condition": 1.0})
	var view := _view(model)
	view.refresh(0.1, 21.0, MEDIUM_CAMERA)
	assert_eq(view.building_draw_calls(), 1, "one merged node")
	model.remove_building(1)
	view.refresh(0.1, 21.0, MEDIUM_CAMERA)
	assert_eq(view.building_draw_calls(), 0,
			"an empty chunk submits nothing — neither the merged node nor the "
			+ "per-level bucket it left behind")
	view.free()


## The merged node one archetype owns in chunk (0,0), by the name it is given.
func _merged_node(view: CityView, archetype: String) -> MultiMeshInstance3D:
	for child in view.get_children():
		var node := child as MultiMeshInstance3D
		if node != null and node.name == "MM_med_%s_0_0" % archetype:
			return node
	return null
