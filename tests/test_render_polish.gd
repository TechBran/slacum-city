extends SimTest
## The render-polish pass, guarded: per-family window nits, the FAR band tier
## and its LOD swap, the animated water surface, the zoom-scaled rain box, and
## the vehicle shadow switch.
##
## The rule every one of these tests exists to protect is the same one: doc 11
## §2.6's `lit = step(1 - e, h)` contract, which `RenderStateModel.
## lit_window_count` mirrors on the CPU. Per-family nits and the far tier both
## touch window lighting, and BOTH are brightness-only — nothing here may
## change how many cells light, or the mirror stops being a mirror and the
## blackout read (job 1) goes with it.

const RENDER_DATA := "res://data/render.json"
const BUILDING := "res://game/shaders/building.gdshader"
const FAR := "res://game/shaders/building_far.gdshader"
const WATER := "res://game/shaders/water.gdshader"


func _data() -> Dictionary:
	return StarterCityLoader.read_json(RENDER_DATA)


func _src(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var text := f.get_as_text()
	f.close()
	return text


## Shader source with the `//` comments stripped. A test that greps for a
## forbidden feature has to look at the CODE — the header that explains why the
## feature is absent names it, and would otherwise fail the test it documents.
func _code_only(src: String) -> String:
	var out := ""
	for line in src.split("\n"):
		var at := String(line).find("//")
		out += (String(line).substr(0, at) if at >= 0 else String(line)) + "\n"
	return out


# ══════════════════════════ 1. per-family window nits ═══════════════════════

func test_window_nits_is_per_family_and_commercial_is_dimmer() -> void:
	var emissive: Dictionary = _data().get("emissive", {})
	var nits: Variant = emissive.get("window_nits")
	assert_eq(typeof(nits), TYPE_DICTIONARY,
			"window_nits is the per-family table now")
	var table: Dictionary = nits
	for family in ["residential", "commercial", "industrial", "tech", "civic"]:
		assert_true(table.has(family), "%s has its own nits" % family)
	assert_true(float(table["commercial"]) < float(table["residential"]),
			"a cool-white office bay must sit BELOW a warm residential one, "
			+ "or it blooms into a white block at Z2 while the flat stays legible")
	assert_true(float(table["civic"]) < float(table["residential"]),
			"civic #E8F0FF is the brightest hue of the five and needs the same cut")


func test_city_view_reads_both_the_table_and_a_plain_number() -> void:
	# The plain number is the pre-polish file. It must still mean "this
	# brightness for every family", or an older data/render.json goes black.
	var view := CityView.new()
	var data := _data()
	var model := RenderStateModel.new(data)
	view.setup(model, data)
	assert_almost_eq(view.window_nits_for("residential"), 3.2, 1e-6)
	assert_true(view.window_nits_for("commercial") < view.window_nits_for("residential"),
			"the table is honoured per family")
	assert_almost_eq(view.window_nits_for("no_such_family"),
			view.window_nits_for("residential"), 1e-6,
			"an unlisted family falls back to a LIT value, never to 0")
	view.free()

	var flat := data.duplicate(true)
	(flat["emissive"] as Dictionary)["window_nits"] = 2.9
	var flat_view := CityView.new()
	flat_view.setup(RenderStateModel.new(flat), flat)
	for family in ["residential", "commercial", "tech"]:
		assert_almost_eq(flat_view.window_nits_for(family), 2.9, 1e-6,
				"a plain number applies to every family (%s)" % family)
	flat_view.free()


func test_nits_scale_brightness_only_and_never_the_lit_count() -> void:
	# The mirror. `lit_window_count` must be a pure function of (cols, rows,
	# faces, e, variant) — no nits anywhere in it — and the shader must compute
	# `lit` BEFORE the nits multiply, so no value in the table can move it.
	var model := RenderStateModel.new(_data())
	var lit := model.lit_window_count(5, 48, 4, 0.05, 0)
	assert_eq(model.lit_window_count(5, 48, 4, 0.05, 0), lit,
			"the mirror is stable")
	var src := _src(BUILDING)
	var lit_at := src.find("float lit = step(1.0 - e, h);")
	var nits_at := src.find("float nits = window_nits")
	assert_true(lit_at >= 0 and nits_at > lit_at,
			"the lit test is computed before window_nits is even read")
	assert_false(src.contains("window_nits * ") and src.find("step(1.0 - e") > nits_at,
			"window_nits never appears inside the lit test")


# ══════════════════════════ 2. the FAR band tier ════════════════════════════

func test_far_shader_exists_and_bands_instead_of_hashing_windows() -> void:
	var src := _src(FAR)
	assert_true(src != "", "the FAR shader is a file, not an idea")
	assert_true(src.contains("length(MODEL_MATRIX[1].xyz)"),
			"§2.6: rows come from the instance's own height, off the transform")
	assert_true(src.contains("varying flat vec4 v_custom;"),
			"INSTANCE_CUSTOM is flat here for the same reason it is in the near "
			+ "shader — interpolation walks `variant` and shatters the hash")
	assert_true(src.contains("band_lo") and src.contains("band_hi"),
			"the storey band is the §2.6 window read at this range")
	assert_false(src.contains("window_cols"),
			"there is no per-window grid at 420 m+; that is the whole point")
	assert_true(src.contains("uniform vec3 window_colors[5]"),
			"the five family hues survive the swap, in one draw call")


func test_far_mullions_are_filtered_analytically_not_hashed() -> void:
	# The one place a PERIODIC pattern is allowed at this range, and only
	# because it is crossfaded to its own mean before it can moiré. A hard
	# `step(duty, fract(bay))` with no filter is the exact construction doc 11
	# forbids: a 3.2 m feature is sub-pixel at 1200 m and would shimmer.
	var src := _src(FAR)
	assert_true(src.contains("fwidth(bay)"),
			"the strip's on-screen width is measured, not assumed")
	assert_true(src.contains("mix(sharp, far_mullion_duty"),
			"and the pattern is crossfaded to far_mullion_duty — which IS the "
			+ "average the sharp pattern integrates to, so the far tier loses "
			+ "structure without changing brightness")
	var emissive: Dictionary = _data().get("emissive", {})
	var duty := float(emissive.get("far_mullion_duty", 0.72))
	assert_true(duty > 0.0 and duty < 1.0,
			"a duty of 1 is no mullion at all and 0 is an unlit building")


func test_far_band_and_energy_constants_come_from_data() -> void:
	var emissive: Dictionary = _data().get("emissive", {})
	for key in ["far_band_lo", "far_band_hi", "window_nits_far",
			"far_energy_scale", "far_cell_m"]:
		assert_true(emissive.has(key), "%s is authored in data/render.json" % key)
	assert_true(float(emissive["far_energy_scale"]) > 0.0
			and float(emissive["far_energy_scale"]) <= 1.0,
			"far_energy_scale compensates band coverage; above 1 it would make "
			+ "the far tier brighter than the tier in front of it")
	assert_true(float(emissive["far_cell_m"]) >= 2.0 * 3.2,
			"a hash segment must be at least two window bays wide, or it IS the "
			+ "per-window hash doc 11 rejects for shimmer at this range")


func _far_model() -> RenderStateModel:
	# Two chunks: one under the camera, one 1 km east.
	var model := RenderStateModel.new(_data())
	var id := 1
	for entry in [["apartment", 3, "residential", Vector3(40.0, 0.0, 40.0)],
			["office", 4, "commercial", Vector3(72.0, 0.0, 40.0)],
			["apartment", 2, "residential", Vector3(1064.0, 0.0, 40.0)],
			["office", 2, "commercial", Vector3(1096.0, 0.0, 72.0)],
			["data_center", 2, "tech", Vector3(1096.0, 0.0, 104.0)]]:
		var pos: Vector3 = entry[3]
		model.add_building({
			"id": id, "archetype_id": StringName(entry[0]), "level": int(entry[1]),
			"family": String(entry[2]), "world_pos": pos,
			"block_id": "B", "transform": Transform3D(Basis.IDENTITY, pos),
			"occ_b": 0.8, "powered": true, "condition": 1.0})
		id += 1
	return model


func test_far_tier_collapses_a_chunk_to_one_multimesh() -> void:
	var data := _data()
	var model := _far_model()
	var view := CityView.new()
	view.keep_far_buffers = true
	view.setup(model, data)
	# Camera over chunk (0,0): chunk (8,0) is 1 km out — FAR, not culled.
	var camera := Vector3(64.0, 20.0, 64.0)
	view.refresh(0.1, 21.0, camera)
	assert_eq(model.chunk_tier(Vector2i(0, 0)), RenderStateModel.TIER_NEAR,
			"the chunk under the camera is NEAR")
	assert_eq(model.chunk_tier(Vector2i(8, 0)), RenderStateModel.TIER_FAR,
			"a chunk 1 km out is FAR (balanced far_cull_m = 1200)")
	assert_eq(view.far_chunk_count(), 1, "exactly one chunk drew the far box")
	# 2 near buckets drawn + 1 far node; the far chunk's own 3 buckets are dark.
	assert_eq(view.building_draw_calls(), 3,
			"5 buildings in 5 buckets over 2 chunks cost 2 + 1 calls, not 5")
	var buffer := view.far_buffer(Vector2i(8, 0))
	assert_eq(buffer.size(), 3 * 16, "three instances, 16 floats each")
	view.free()


func test_far_instances_are_scaled_boxes_carrying_the_near_custom_data() -> void:
	var data := _data()
	var model := _far_model()
	var view := CityView.new()
	view.keep_far_buffers = true
	view.setup(model, data)
	view.refresh(0.1, 21.0, Vector3(64.0, 20.0, 64.0))
	var buffer := view.far_buffer(Vector2i(8, 0))
	assert_true(buffer.size() >= 16, "the far chunk has instances")
	var families: Dictionary = {}
	for i in buffer.size() / 16:
		var b := i * 16
		# §2.14: the unit box is scaled to (fx·8, height_m, fz·8) and never
		# rotated — an axis-aligned diagonal basis.
		assert_true(buffer[b + 0] > 0.0, "x scale is the footprint in metres")
		assert_true(buffer[b + 5] > 1.0, "y scale is the height in metres")
		assert_true(buffer[b + 10] > 0.0, "z scale is the footprint in metres")
		assert_almost_eq(buffer[b + 1], 0.0, 1e-9, "no shear")
		assert_almost_eq(buffer[b + 4], 0.0, 1e-9, "no shear")
		assert_true(buffer[b + 3] > 900.0, "the instance sits in the far chunk")
		# .r is the emissive ramp, copied not recomputed.
		assert_true(buffer[b + 12] > 0.0, "a powered building carries its ramp over")
		# .a is the family index here, NOT anim_phase (see the far shader header).
		var family_index := int(buffer[b + 15])
		assert_true(family_index >= 0 and family_index <= 4,
				"the family index indexes window_colors[5]")
		families[family_index] = true
	assert_true(families.size() >= 2,
			"a mixed chunk keeps its mixed window colour at range")
	view.free()


# ═════════════════ 2b. the FAR tier's chunk-aggregate overlay ═══════════════
#
# Doc 12 §2.5 stops at the MEDIUM boundary without this: the far city greyed
# out under the wash and then said nothing, so a blackout three chunks out was
# invisible in the one overlay opened to find it. The state is packed into `.a`
# ABOVE the family index (CityView.FAR_OVERLAY_STRIDE) because that is the only
# channel this tier owns — `.g` is the damage the far shader reads for soot and
# the emissive dim, and taking it would have cost a burnt block its soot the
# moment the overlay opened.

func _far_view(model: RenderStateModel) -> CityView:
	var view := CityView.new()
	view.keep_far_buffers = true
	view.setup(model, _data())
	return view


func test_far_alpha_is_the_bare_family_index_with_no_overlay() -> void:
	# Mode 0 must be byte-for-byte what it was before the far overlay landed.
	var view := _far_view(_far_model())
	view.refresh(0.1, 21.0, Vector3(64.0, 20.0, 64.0))
	var buffer := view.far_buffer(Vector2i(8, 0))
	assert_true(buffer.size() >= 16, "the far chunk has instances")
	for i in buffer.size() / 16:
		var a := buffer[i * 16 + 15]
		assert_true(a >= 0.0 and a <= 4.0,
				".a is the bare family index at overlay mode 0, got %f" % a)
	view.free()


func test_far_alpha_packs_the_chunk_state_above_the_family_index() -> void:
	# One OFFLINE building in the far chunk must colour the WHOLE chunk, and the
	# family index has to survive underneath it — the far city keeps its
	# per-family window hue while it is being diagnosed.
	var model := _far_model()
	# ids 3,4,5 are the far chunk (x >= 1064). Mark one destroyed-equivalent.
	model.set_overlay_channel(&"water", {4: RenderStateModel.OVERLAY_OFFLINE})
	var view := _far_view(model)
	view.set_overlay_mode(&"water", Vector3(64.0, 20.0, 64.0))
	view.refresh(0.1, 21.0, Vector3(64.0, 20.0, 64.0))
	var buffer := view.far_buffer(Vector2i(8, 0))
	assert_true(buffer.size() >= 16, "the far chunk has instances")
	var families: Dictionary = {}
	for i in buffer.size() / 16:
		var a := buffer[i * 16 + 15]
		var state := floorf(a / CityView.FAR_OVERLAY_STRIDE)
		var family := a - state * CityView.FAR_OVERLAY_STRIDE
		assert_almost_eq(state, 3.0, 1e-6,
				"the worst state in the chunk paints the whole chunk, got %f" % state)
		assert_true(family >= 0.0 and family <= 4.0,
				"the family index survives the packing, got %f" % family)
		families[int(family)] = true
	assert_true(families.size() >= 2,
			"a mixed chunk keeps its mixed window colour under the overlay")
	view.free()


func test_far_power_overlay_reads_the_emissive_ladder_like_the_near_shader() -> void:
	# A chunk does not get to change verdict as it crosses the LOD boundary: the
	# near shader grades POWER off `v_custom.r` (the model's dark 0.05 / backup
	# 0.22 / powered 0.55 ladder) and the aggregate has to use the same
	# thresholds. A blacked-out chunk therefore reads OFFLINE at 500 m for the
	# same reason a single dark tower does at 50 m.
	var model := _far_model()
	var view := _far_view(model)
	view.set_overlay_mode(&"power", Vector3(64.0, 20.0, 64.0))
	view.refresh(0.1, 21.0, Vector3(64.0, 20.0, 64.0))
	var lit := view.far_buffer(Vector2i(8, 0))
	assert_true(lit.size() >= 16, "the far chunk has instances")
	var lit_state := floorf(lit[15] / CityView.FAR_OVERLAY_STRIDE)
	# Now cut the block and let the ramps settle. `_far_model` puts every
	# building on block "B", so this is the whole city going dark — which is
	# what a far chunk reading OFFLINE has to survive.
	model.plan_blackout("B")
	model.advance(30.0)
	view.refresh(0.1, 21.0, Vector3(64.0, 20.0, 64.0))
	var dark := view.far_buffer(Vector2i(8, 0))
	var dark_state := floorf(dark[15] / CityView.FAR_OVERLAY_STRIDE)
	assert_true(dark_state > lit_state,
			"a blacked-out far chunk must read worse than a lit one (%f -> %f)"
			% [lit_state, dark_state])
	assert_almost_eq(dark_state, 3.0, 1e-6, "…and specifically OFFLINE")
	view.free()


func test_far_shader_decodes_the_packing_and_stays_identity_at_mode_zero() -> void:
	var src := _code_only(_src(FAR))
	assert_true(src.contains("far_overlay_stride"),
			"the far shader reads the packing stride from a uniform")
	assert_true(src.contains("mod(packed_a, far_overlay_stride)"),
			"the family index is the remainder, so it survives the packing")
	assert_true(src.contains("if (sc_overlay_mode > 0)"),
			"the whole overlay block is behind ONE uniform branch")
	assert_true(src.contains("OVERLAY_MODE_POWER")
			and src.contains("OVERLAY_MODE_WATER"),
			"only modes 1 and 2 paint a state (doc 12 §2.5)")
	# Motion, not just colour: constitution §11.
	assert_true(src.contains("overlay_critical_hz")
			and src.contains("overlay_offline_hz"),
			"CRITICAL pulses and OFFLINE breathes at range too")


func test_lod_can_be_switched_off_and_every_chunk_comes_back() -> void:
	var data := _data()
	var model := _far_model()
	var view := CityView.new()
	view.lod_enabled = false
	view.setup(model, data)
	view.refresh(0.1, 21.0, Vector3(64.0, 20.0, 64.0))
	assert_eq(view.far_chunk_count(), 0, "no far nodes with the ladder off")
	assert_eq(view.building_draw_calls(), 5,
			"all five buckets draw at LOD0 — the pre-far-tier renderer, exactly")
	view.free()


func test_the_swap_inherits_the_models_hysteresis_and_dwell() -> void:
	# The far tier does not get to invent its own switching rule: it reads
	# `chunk_tier`, and the model already refuses more than one step per dwell
	# and holds a 20 m band at each edge. This is what stops the boundary
	# flickering under a normal zoom.
	var model := RenderStateModel.new(_data())
	model.add_building({"id": 1, "archetype_id": &"apartment", "level": 2,
			"family": "residential", "world_pos": Vector3(64.0, 0.0, 64.0),
			"block_id": "B",
			"transform": Transform3D(Basis.IDENTITY, Vector3(64.0, 0.0, 64.0)),
			"occ_b": 0.8, "powered": true, "condition": 1.0})
	model.set_chunk_tier(Vector2i(0, 0), RenderStateModel.TIER_MEDIUM)
	# Just past the 420 m edge but inside the 20 m hysteresis band: no change.
	model.update_chunk_tiers(Vector3(64.0, 430.0, 64.0), 1.0)
	assert_eq(model.chunk_tier(Vector2i(0, 0)), RenderStateModel.TIER_MEDIUM,
			"430 m is inside 420 + 20 and must NOT swap")
	model.update_chunk_tiers(Vector3(64.0, 460.0, 64.0), 1.0)
	assert_eq(model.chunk_tier(Vector2i(0, 0)), RenderStateModel.TIER_FAR,
			"past the band it swaps once")


func test_far_window_colours_keep_the_per_family_brightness_ladder() -> void:
	var data := _data()
	var view := CityView.new()
	view.setup(RenderStateModel.new(data), data)
	var colors := view.far_window_colors()
	assert_eq(colors.size(), 5, "one per family, in CityView.FAMILY_ORDER")
	var res_luma := colors[0].r * 0.2126 + colors[0].g * 0.7152 + colors[0].b * 0.0722
	var com_luma := colors[1].r * 0.2126 + colors[1].g * 0.7152 + colors[1].b * 0.0722
	assert_true(com_luma < res_luma,
			"commercial is dimmer than residential at 500 m for exactly the "
			+ "reason it is at 50 m, so a chunk does not change character when "
			+ "it crosses the LOD boundary")
	view.free()


# ══════════════════════════ 3. the water surface ════════════════════════════

func test_water_is_a_shader_material_driven_by_the_globals() -> void:
	var mat := GroundSurface.water()
	assert_true(mat is ShaderMaterial, "water animates, so it cannot be a Standard")
	var src := _src(WATER)
	assert_true(src.contains("global uniform float sc_time;"),
			"the animation rides the global the window flicker already publishes")
	assert_true(src.contains("global uniform float sc_night;"), "it darkens at night")
	assert_true(src.contains("global uniform float sc_wetness;"),
			"rain roughens it — a downpour kills the glare")
	assert_true(src.contains("sc_overlay_mode"),
			"or an overlay leaves one glowing blue rectangle in a grey city")


func test_water_has_two_octaves_and_no_reflection_probe() -> void:
	var src := _src(WATER)
	for key in ["wave_scale_a_m", "wave_scale_b_m", "wave_speed_a", "wave_speed_b",
			"wave_dir_a", "wave_dir_b"]:
		assert_true(src.contains(key), "%s: two independent octaves" % key)
	assert_false(_code_only(src).to_lower().contains("reflection"),
			"§2.11 gates the ONE probe the game may own to High and to the city "
			+ "at large; the sky read here is a fresnel term")
	assert_true(src.contains("fresnel"), "…and it is actually a fresnel term")
	assert_true(src.contains("v_world"),
			"the wave field is WORLD space, or adjacent 8 m tiles read as tiles "
			+ "instead of as one body of water")


func test_water_constants_come_from_data() -> void:
	var water: Dictionary = _data().get("water_surface", {})
	assert_false(water.is_empty(), "data/render.json owns the water look")
	var mat := GroundSurface.water() as ShaderMaterial
	assert_eq(Color(mat.get_shader_parameter("deep_color")),
			Color(String(water["deep_color"])), "deep colour is the authored one")
	assert_almost_eq(float(mat.get_shader_parameter("night_mult")),
			float(water["night_mult"]), 1e-6)
	assert_almost_eq(float(mat.get_shader_parameter("base_roughness")),
			float(water["roughness"]), 1e-6)


# ══════════════════════════ 4. the rain box at far zoom ═════════════════════

func _fx() -> WeatherFX:
	var fx := WeatherFX.new()
	fx.setup(_data(), null, "balanced")
	return fx


func test_rain_box_is_the_authored_size_at_close_zoom() -> void:
	var fx := _fx()
	var authored: Array = _data().get("weather", {}).get("rain_box_m", [90, 40, 90])
	fx.set_zoom_reach(18.0)      # doc 12's D_MIN
	assert_almost_eq(fx.box_scale(), 1.0, 1e-6, "Z0 is the authored box")
	assert_almost_eq(fx.rain_box_m().x, float(authored[0]), 1e-4)
	fx.set_zoom_reach(-1.0)
	assert_almost_eq(fx.box_scale(), 1.0, 1e-6,
			"no camera distance at all also means the authored box")
	fx.free()


func test_rain_box_grows_with_camera_distance_and_caps() -> void:
	var fx := _fx()
	var weather: Dictionary = _data().get("weather", {})
	var ref := float(weather.get("rain_box_dist_ref_m", 90.0))
	var cap := float(weather.get("rain_box_max_scale", 8.0))
	fx.set_zoom_reach(420.0)      # doc 12's D_MAX / Z2
	var z2 := fx.box_scale()
	assert_true(z2 > 3.0, "a Z2 storm covers the city, not a square in the middle")
	assert_almost_eq(z2, minf(420.0 / ref, cap), 1e-5)
	fx.set_zoom_reach(100000.0)
	assert_almost_eq(fx.box_scale(), cap, 1e-6, "and it is capped")
	fx.free()


func test_the_rain_box_never_scales_in_y() -> void:
	# The fall height sets `lifetime` at build time. Re-writing `lifetime` on a
	# live emitter re-ages every drop in flight, which is the pop §2.9 rule 2
	# forbids outright.
	var fx := _fx()
	var authored: Array = _data().get("weather", {}).get("rain_box_m", [90, 40, 90])
	fx.set_zoom_reach(420.0)
	assert_almost_eq(fx.rain_box_m().y, float(authored[1]), 1e-4,
			"Y is the one axis that must not move")
	assert_true(fx.rain_box_m().x > float(authored[0]), "XZ did move")
	fx.free()


func test_growing_the_box_never_changes_the_particle_count() -> void:
	# THE density cap: the same drops over more ground, never more drops.
	var fx := _fx()
	var rain := fx.get_node("Rain") as GPUParticles3D
	var before := rain.amount
	fx.set_weather("HEAVY_RAIN", 0.9, 0.9, Vector2(4.0, 1.0))
	fx.refresh(0.1, Vector3.ZERO, 18.0)
	assert_eq(rain.amount, before, "close zoom: count untouched")
	fx.refresh(0.1, Vector3.ZERO, 420.0)
	assert_eq(rain.amount, before,
			"far zoom: the box is 4-8x wider and the count is IDENTICAL")
	assert_true(fx.box_scale() > 1.0, "…because the box grew instead")
	fx.free()


# ══════════════════════════ 5. vehicle shadows + defaults ═══════════════════

func test_vehicle_shadows_are_off_on_mobile_and_on_at_high() -> void:
	var data := _data()
	assert_false(bool((data["vehicles"] as Dictionary).get("cast_shadows", true)),
			"the baseline is OFF: a world-sized AABB puts every body layer in "
			+ "every shadow split whether or not a car is standing in it")
	var presets: Dictionary = data["presets"]
	for name in ["performance", "balanced"]:
		assert_false(bool((presets[name] as Dictionary).get("vehicle_shadows", true)),
				"%s ships without vehicle shadows" % name)
	assert_true(bool((presets["high"] as Dictionary).get("vehicle_shadows", false)),
			"High has the splits to spare and takes them")

	var view := VehicleView.new()
	view.setup(data)
	assert_false(view.cast_shadows, "the default preset (balanced) resolves to OFF")
	view.set_preset("high", data)
	assert_true(view.cast_shadows, "and High turns them back on without a rebuild")
	view.set_preset("performance", data)
	assert_false(view.cast_shadows)
	view.free()


func test_the_nine_vehicle_defaults_are_data_now() -> void:
	var vehicles: Dictionary = _data().get("vehicles", {})
	var expected := {
		"road_top_m": 0.10, "lane_offset_m": 1.85, "fade_seconds": 0.40,
		"interp_blend_seconds": 0.28, "headlight_cone_m": 8.0,
		"headlight_cone_energy": 0.22}
	for key: String in expected:
		assert_true(vehicles.has(key), "%s promoted into data/render.json" % key)
		assert_almost_eq(float(vehicles[key]), float(expected[key]), 1e-6,
				"%s is unchanged from the constant it replaces" % key)
	for key in ["headlight_color", "lightbar_amber", "lightbar_amber_pale"]:
		assert_true(vehicles.has(key), "%s promoted too" % key)
	var view := VehicleView.new()
	view.setup(_data())
	assert_almost_eq(view.road_top, 0.10, 1e-6, "and the view reads them")
	assert_almost_eq(view.lane_offset, 1.85, 1e-6)
	view.free()


# ══════════════════════ 6. the building contact decal (§2.11) ═══════════════
#
# Doc 11 §2.11's `MM_blob`, report 98 RR-96. Four claims, every one of which was
# either unenforced or untrue before this pass: the block's `enabled_presets`
# row is READ; the layer is ONE draw call city-wide rather than one per chunk;
# the decal lies flat at the authored height and footprint; and a settled city
# hands the server nothing.

func _blob_view(preset_name: String) -> CityView:
	var data := _data()
	var model := RenderStateModel.new(data, preset_name)
	var id := 1
	for entry in [["apartment", 3, "residential", Vector3(40.0, 0.0, 40.0)],
			["office", 4, "commercial", Vector3(72.0, 0.0, 40.0)],
			["apartment", 2, "residential", Vector3(1064.0, 0.0, 40.0)],
			["office", 2, "commercial", Vector3(1096.0, 0.0, 72.0)],
			["data_center", 2, "tech", Vector3(1096.0, 0.0, 104.0)]]:
		var pos: Vector3 = entry[3]
		model.add_building({
			"id": id, "archetype_id": StringName(entry[0]), "level": int(entry[1]),
			"family": String(entry[2]), "world_pos": pos,
			"block_id": "B", "transform": Transform3D(Basis.IDENTITY, pos),
			"occ_b": 0.8, "powered": true, "condition": 1.0})
		id += 1
	var view := CityView.new()
	view.keep_blob_buffers = true
	view.setup(model, data)
	return view


func test_the_blob_block_names_the_building_decals_gate_and_only_that() -> void:
	var blob: Dictionary = _data().get("blob_shadow", {})
	assert_true(blob.has("enabled_presets"), "the block still carries its gate")
	assert_eq(blob["enabled_presets"], ["performance"],
			"the building decal is Performance's, because Performance is the tier "
			+ "whose `shadows` knob is false")
	assert_false(bool((_data()["presets"]["performance"] as Dictionary).get(
			"shadows", true)),
			"…and that is exactly why it needs one: no sun shadow on this tier")
	assert_almost_eq(float(blob.get("alpha", -1.0)), 0.35, 1e-6,
			"§2.11's authored alpha for a 12 m mass")
	assert_almost_eq(float(blob.get("body_alpha", -1.0)), 0.50, 1e-6,
			"…which is NOT §2.17's, and the two differ because the objects do")
	assert_almost_eq(float(blob.get("y_m", -1.0)), 0.04, 1e-6)
	assert_almost_eq(float(blob.get("footprint_scale", -1.0)), 1.15, 1e-6)


func test_the_decal_is_one_multimesh_city_wide_not_one_per_chunk() -> void:
	var view := _blob_view("performance")
	# Two chunks, 1 km apart, both holding buildings.
	view.refresh(0.1, 13.0, Vector3(64.0, 20.0, 64.0))
	assert_true(view.blob_enabled(),
			"`performance` is in enabled_presets, so the layer is on")
	assert_eq(view.blob_draw_calls(), 1,
			"ONE call for the whole city — the per-chunk arm measured 36 at Z0 "
			+ "on the bench city against a 180-call budget (report 98 RR-96)")
	assert_eq(view.blob_buffer().size(), 5 * 12,
			"five buildings, twelve floats each: transforms only, no colour and "
			+ "no custom data. The FAR chunk's three are in it too — the buffer "
			+ "is a function of the roster, not of the camera")
	view.free()


func test_the_decal_lies_flat_at_the_authored_height_and_footprint() -> void:
	var view := _blob_view("performance")
	view.refresh(0.1, 13.0, Vector3(64.0, 20.0, 64.0))
	var buffer := view.blob_buffer()
	assert_eq(buffer.size(), 5 * 12, "five decals")
	if buffer.size() < 60:
		view.free()
		return
	for i in 5:
		var base := i * 12
		# basis.y.y is 1: the quad is unit-height and lies in its own XZ plane,
		# so nothing here can stand it up like a card.
		assert_almost_eq(buffer[base + 5], 1.0, 1e-5,
				"decal %d is not scaled vertically" % i)
		# Every off-diagonal basis term is zero — axis-aligned, like the far box.
		for off in [1, 2, 4, 6, 8, 9]:
			assert_almost_eq(buffer[base + off], 0.0, 1e-6,
					"decal %d carries no rotation" % i)
		assert_almost_eq(buffer[base + 7], 0.04, 1e-5,
				"decal %d sits at §2.11's y_m above its own ground plane" % i)
		# footprint_tiles × 8 m × 1.15. Every authored footprint is a whole
		# number of 8 m tiles, so the scale must be a multiple of 9.2 m.
		var tiles: float = buffer[base + 0] / (8.0 * 1.15)
		assert_almost_eq(tiles, roundf(tiles), 1e-4,
				"decal %d is the footprint × 1.15, not a guess" % i)
		assert_true(tiles >= 1.0, "decal %d covers at least its own tile" % i)
	view.free()


func test_enabled_presets_is_read_and_a_live_preset_swap_moves_it() -> void:
	var view := _blob_view("balanced")
	view.refresh(0.1, 13.0, Vector3(64.0, 20.0, 64.0))
	assert_false(view.blob_enabled(),
			"Balanced casts real shadows, so it gets no decal")
	assert_eq(view.blob_draw_calls(), 0, "…and submits nothing for it")
	# The settings row and the governor's LATCHED DROP both go through
	# `RenderStateModel.set_preset`, and this view re-derives the gate from the
	# model on its next upload — so neither path owes it a call of its own.
	view.model.set_preset("performance")
	view.refresh(0.1, 13.0, Vector3(64.0, 20.0, 64.0))
	assert_true(view.blob_enabled(), "a drop to Performance lights the layer")
	assert_eq(view.blob_draw_calls(), 1,
			"…on the very next frame, with no call from the shell")
	view.model.set_preset("high")
	view.refresh(0.1, 13.0, Vector3(64.0, 20.0, 64.0))
	assert_eq(view.blob_draw_calls(), 0,
			"and switching back UP stands it down again")
	view.free()


func test_a_settled_city_uploads_no_decal() -> void:
	var view := _blob_view("performance")
	view.refresh(0.1, 13.0, Vector3(64.0, 20.0, 64.0))
	var after_first := view.blob_upload_count()
	assert_true(after_first > 0, "the first frame has to upload something")
	for i in 8:
		view.refresh(0.1, 13.0, Vector3(64.0, 20.0, 64.0))
	assert_eq(view.blob_upload_count(), after_first,
			"eight frames of a city where nothing was built hand the server "
			+ "nothing: the buffer is rebuilt and COMPARED, not re-uploaded")
	view.model.add_building({
		"id": 99, "archetype_id": &"apartment", "level": 1,
		"family": "residential", "world_pos": Vector3(104.0, 0.0, 40.0),
		"block_id": "B",
		"transform": Transform3D(Basis.IDENTITY, Vector3(104.0, 0.0, 40.0)),
		"occ_b": 0.8, "powered": true, "condition": 1.0})
	view.refresh(0.1, 13.0, Vector3(64.0, 20.0, 64.0))
	assert_eq(view.blob_upload_count(), after_first + 1,
			"one building goes up, one upload")
	assert_eq(view.blob_buffer().size(), 6 * 12, "and six decals now")
	view.free()


func test_the_decal_shader_is_the_cheapest_thing_that_could_work() -> void:
	var src := _code_only(_src("res://game/shaders/blob_shadow.gdshader"))
	assert_true(src != "", "the decal shader ships")
	assert_true(src.contains("unshaded"), "a shadow is not lit")
	assert_true(src.contains("depth_draw_never"),
			"a decal that writes depth occludes the building standing on it")
	assert_false(src.contains("texture("),
			"NO texture fetch: this runs on the lowest tier, at render_scale "
			+ "0.70, over a 16 m footprint — which is the whole reason it is not "
			+ "a sixth mode on street_fx.gdshader, whose one glyph fetch is "
			+ "right there and would be paid for nothing here")
	assert_true(src.contains("sc_night"),
			"§2.11's night fade: a contact shadow needs a sun")

# ══════════════ 7. every vertex colour is decoded ONCE, at the write ════════
#
# Doc 91 A91-D-36's second half, report 98 RR-95, doc 93 §X1. A vertex `COLOR`
# takes no sRGB decode — neither in a ShaderMaterial that reads `COLOR.rgb` nor
# in a `StandardMaterial3D` with `vertex_color_use_as_albedo` and the project's
# default `vertex_color_is_srgb = false` — so every hex authored into a builder
# was rendering about two stops light. The seam is one `srgb_to_linear` per
# builder's `_push`, never at the constant: `ConstructionRigMesh`'s stock trio
# is also read as an INSTANCE tint by `ConstructionActivity`, which decodes it
# for itself, and a constant decoded in place would be decoded twice there.

## Whether `cols` holds a vertex whose RGB is `want`, to 8-bit tolerance: an
## ArrayMesh stores COLOR as RGBA8, so a decoded 0.1789 reads back as 46/255 =
## 0.1804. One and a half LSBs.
func _has_rgb(cols: PackedColorArray, want: Color) -> bool:
	for c in cols:
		if absf(c.r - want.r) < 0.006 and absf(c.g - want.g) < 0.006 \
				and absf(c.b - want.b) < 0.006:
			return true
	return false


func _cols_of(mesh: ArrayMesh) -> PackedColorArray:
	if mesh == null or mesh.get_surface_count() == 0:
		return PackedColorArray()
	return mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR]


func test_the_rig_builder_decodes_every_tint_at_the_write() -> void:
	var cols := _cols_of(ConstructionRigMesh.excavator().to_mesh())
	assert_true(cols.size() > 0, "the excavator has vertices")
	var steel_lin := ConstructionRigMesh.STEEL.srgb_to_linear()
	assert_true(_has_rgb(cols, steel_lin),
			"a STEEL vertex carries the DECODED constant (%s)" % steel_lin)
	assert_false(_has_rgb(cols, ConstructionRigMesh.STEEL),
			"…and no vertex carries the raw authored hex: the lift is out")
	assert_true(_has_rgb(cols, ConstructionRigMesh.PAINT),
			"PAINT is white, a fixed point of the decode — §2.16's 'painted "
			+ "panels ARE the instance colour' contract survives the seam")
	assert_true(steel_lin.r < ConstructionRigMesh.STEEL.r,
			"decoding is a DARKENING, which is what the fix is for")


func test_the_vehicle_builder_decodes_at_the_write_too() -> void:
	var cols := _cols_of(VehicleMesh.car().to_mesh())
	assert_true(cols.size() > 0, "the car has vertices")
	var tyre_lin := VehicleMesh.TYRE.srgb_to_linear()
	assert_true(_has_rgb(cols, tyre_lin), "a tyre vertex is the decoded TYRE")
	assert_false(_has_rgb(cols, VehicleMesh.TYRE),
			"and no vertex carries the raw TYRE hex")
	assert_true(_has_rgb(cols, VehicleMesh.PAINT), "painted panels stay white")


func test_dark_and_tyre_are_one_material_in_both_builders_and_sit_above_the_road() -> void:
	# The two re-judged hexes (RR-95). They moved because DECODED from their old
	# values they landed at linear 0.0125 / 0.0069 — under the ~0.02-linear
	# shaded carriageway (RR-90's measurement) — so a track frame became a hole
	# in the road. The new values decode ABOVE it, and the two files carry the
	# same number because it is the same rubber on the same street.
	assert_eq(VehicleMesh.TYRE, ConstructionRigMesh.TYRE,
			"one rubber: VehicleMesh.TYRE == ConstructionRigMesh.TYRE")
	assert_eq(VehicleMesh.DARK, ConstructionRigMesh.DARK,
			"one dark steel: VehicleMesh.DARK == ConstructionRigMesh.DARK")
	var road_linear := 0.02
	assert_true(ConstructionRigMesh.DARK.srgb_to_linear().r > road_linear,
			"DARK decodes above the shaded carriageway (%.4f > %.2f)"
			% [ConstructionRigMesh.DARK.srgb_to_linear().r, road_linear])
	assert_true(ConstructionRigMesh.TYRE.srgb_to_linear().r > road_linear,
			"TYRE decodes above the shaded carriageway (%.4f > %.2f)"
			% [ConstructionRigMesh.TYRE.srgb_to_linear().r, road_linear])
	# And the OLD values would not have — which is the whole reason they moved.
	assert_true(Color(0.115, 0.125, 0.135).srgb_to_linear().r < road_linear,
			"the pre-RR-95 DARK, decoded, sank below the road")
	assert_true(Color(0.085, 0.085, 0.095).srgb_to_linear().r < road_linear,
			"…and so did the pre-RR-95 TYRE")


func test_the_street_life_bodies_inherit_the_seam() -> void:
	var cols := _cols_of(StreetLifeMesh.crook().to_mesh())
	assert_true(cols.size() > 0, "the crook has vertices")
	assert_true(_has_rgb(cols, StreetLifeMesh.SKIN.srgb_to_linear()),
			"SKIN is decoded — StreetLifeMesh extends ConstructionRigMesh and "
			+ "inherits its _push, so there is no second seam to keep in step")
	assert_false(_has_rgb(cols, StreetLifeMesh.SKIN), "and the raw SKIN hex is gone")


func test_the_stock_trio_is_decoded_exactly_once_on_the_heap_path() -> void:
	# GRAVEL / SAND / REBAR are dual-use: instance tints for the yard heaps
	# (decoded by ConstructionActivity._stock_linear) AND builder constants. The
	# heap MESH is white, so the seam here decodes a fixed point and the tint
	# reaches the screen decoded once — from the activity — and never twice.
	var cols := _cols_of(ConstructionRigMesh.pile_heap().to_mesh())
	assert_true(cols.size() > 0, "the heap has vertices")
	for c in cols:
		assert_almost_eq(c.r, 1.0, 0.002, "heap vertices are WHITE (r)")
		assert_almost_eq(c.g, 1.0, 0.002, "heap vertices are WHITE (g)")
		assert_almost_eq(c.b, 1.0, 0.002, "heap vertices are WHITE (b)")
	var act := ConstructionActivity.new()
	assert_eq(act._stock_linear[1], ConstructionRigMesh.GRAVEL.srgb_to_linear(),
			"the heap's tint is GRAVEL decoded ONCE, from the authored constant")
	assert_true(ConstructionRigMesh.GRAVEL.r > 0.5,
			"…so the constant itself stays sRGB; decoding it in place would have "
			+ "decoded the heap twice (gravel at linear 0.049 — black)")


func test_the_prop_builder_decodes_at_the_write_and_the_pad_rides_it() -> void:
	# ConstructionSiteView.PropMesh: hoarding posts, crane, scaffold, skips —
	# and PowerInfraView's transformer pad, which is built with the same class
	# and read raw by power_pad.gdshader (`albedo = v_color.rgb * page`).
	var builder := ConstructionSiteView.PropMesh.new()
	var crane_yellow := Color("#D8C24A")
	builder.add_box(Vector3.ZERO, Vector3.ONE, crane_yellow)
	var cols := _cols_of(builder.to_mesh(null))
	assert_true(cols.size() > 0, "the box has vertices")
	assert_true(_has_rgb(cols, crane_yellow.srgb_to_linear()),
			"the crane yellow reaches the vertex decoded")
	assert_false(_has_rgb(cols, crane_yellow), "and never raw")
	var view := PowerInfraView.new()
	view.setup(_data())
	var pad_cols := _cols_of(view._pad_mesh)
	assert_true(pad_cols.size() > 0, "the pad mesh has vertices")
	var cabinet := Color(String(((_data().get("power_infra", {}) as Dictionary)
			.get("cabinet_color", "#3C4A3F"))))
	assert_true(_has_rgb(pad_cols, cabinet.srgb_to_linear()),
			"the cabinet green is decoded on the pad")
	assert_false(_has_rgb(pad_cols, cabinet), "and never raw")
	var parts: Dictionary = {}
	for c in pad_cols:
		parts[int(round(c.a * 8.0))] = true
	assert_true(parts.has(PowerInfraView.PART_CABINET),
			"the decode leaves ALPHA alone: `part / 8` still round-trips")
	view.free()


func test_the_hoarding_instance_colours_are_linear_at_the_write() -> void:
	# The panels and posts are INSTANCE colours (RR-91's channel), fed the same
	# authored hexes. Decoded at the write, once per fence build. Asserted on
	# the CPU side — the headless server stores no instance data, so
	# `get_instance_color` cannot be read back here — through the two accessors
	# `_build_fence` itself writes with.
	var hoard := ConstructionSiteView.new()
	hoard.setup(_data())
	hoard.add_site(7, Vector3(200.0, 0.0, 200.0), Vector2i.ONE, 20.0)
	var site: ConstructionSiteView.Site = hoard._sites[7]
	assert_true(site.fence != null and site.fence.multimesh != null,
			"the fence stands")
	assert_true(site.fence.multimesh.instance_count > 0, "and has panels")
	assert_eq(hoard.fence_paint(false), hoard.fence_color.srgb_to_linear(),
			"a plain panel is written with the DECODED fence grey")
	assert_eq(hoard.fence_paint(true), hoard.fence_accent_color.srgb_to_linear(),
			"an accent panel with the DECODED safety orange")
	assert_eq(hoard.post_paint(true), hoard.fence_accent_color.srgb_to_linear(),
			"a gate post wears the accent, decoded")
	assert_eq(hoard.post_paint(false), hoard.post_color.srgb_to_linear(),
			"and a plain post its own grey, decoded")
	assert_true(hoard.fence_paint(false).r < hoard.fence_color.r,
			"the stored value is darker than the hex — the lift is out")
	# And the write path really goes through those accessors, not around them.
	var src := _src("res://game/render/construction_site_view.gd")
	assert_true(src.contains("panel_mm.set_instance_color(panel_i, fence_paint("),
			"the panel write uses fence_paint()")
	assert_true(src.contains("post_mm.set_instance_color(post_i, post_paint("),
			"the post write uses post_paint()")
	hoard.free()


func test_the_cobra_head_is_a_value_ramp_and_is_left_alone_on_purpose() -> void:
	# CobraHeadMesh bakes GRIME, a linear multiplier authored by eye against the
	# shipped pole (doc 11 §2.10.1), and its two tints are near-white. It is not
	# an sRGB hex in a vertex and it is NOT converted — the pole's colour is
	# `StandardMaterial3D.albedo_color`, which is decoded for free. Pinned so a
	# later "make every builder decode" sweep does not deepen the grime ramp.
	var cols := _cols_of(CobraHeadMesh.build())
	assert_true(cols.size() > 0, "the pole has vertices")
	var lo := 2.0
	var hi := -1.0
	for c in cols:
		lo = minf(lo, c.r)
		hi = maxf(hi, c.r)
	assert_almost_eq(hi, 1.0, 0.02, "the ramp tops out at 1.0 (unweathered)")
	assert_true(lo >= CobraHeadMesh.GRIME_FLOOR * CobraHeadMesh.COLLAR_GRIME - 0.02,
			"and bottoms at the authored floor × collar grime, not at its decode")


# ══════════════════════════════════════════════════════════════════════════
# §2.13b — the preset that did nothing (report 98 RR-98)
# ══════════════════════════════════════════════════════════════════════════

## Every key a preset row may carry, and the file that CONSUMES it. This table
## is the whole point of the section: the audit's P1 was not "one key is
## inert", it was that nobody could say which keys were live, so thirteen of
## them had quietly never reached an engine call and one of those was
## `render_scale`. A key that
## is in neither of these two lists fails `test_no_inert_preset_key`, and a key
## in a list that no preset authors fails it too — so the only way to add a
## preset knob is to name its consumer in the same commit.
##
## APPLIED = a knob: something reads it and changes what the engine draws.
const PRESET_KEYS_APPLIED := {
	"target_fps": "game/main.gd -> Engine.max_fps + PerfGovernor.budget_ms",
	"render_scale": "QualityApplier.apply_viewport -> Viewport.scaling_3d_scale",
	"msaa": "QualityApplier.apply_viewport -> Viewport.msaa_3d",
	"fxaa": "QualityApplier.apply_viewport -> Viewport.screen_space_aa",
	"shadows": "EnvironmentController.apply_quality -> _shadows_allowed",
	"shadow_splits": "EnvironmentController -> directional_shadow_mode",
	"shadow_atlas": "QualityApplier -> directional_shadow_atlas_set_size",
	"shadow_max_m": "EnvironmentController -> directional_shadow_max_distance",
	"glow_levels": "EnvironmentController.apply_quality -> set_glow_level",
	"glow_intensity": "EnvironmentController.apply_quality",
	"glow_strength": "EnvironmentController.apply_quality",
	"glow_bloom": "EnvironmentController.apply_quality",
	"glow_blend": "EnvironmentController.apply_quality -> glow_blend_mode",
	"glow_hdr_threshold_day": "EnvironmentController.apply -> glow_hdr_threshold",
	"glow_hdr_threshold_night": "EnvironmentController.apply -> glow_hdr_threshold",
	"glow_hdr_scale": "EnvironmentController.apply_quality",
	"env_adjustments": "EnvironmentController.apply_quality -> adjustment_enabled",
	"moon": "EnvironmentController.apply_quality -> moon node visibility",
	"far_cull_m": "RenderStateModel.load / CityView tier assignment",
	"street_lights": "StreetlightView.set_preset -> set_light_budget",
	"rain": "WeatherFX.set_preset",
	"splash": "WeatherFX.set_preset",
	"civ_cars": "VehicleView._read_presets",
	"civ_vans": "VehicleView._read_presets",
	"civ_trucks": "VehicleView._read_presets",
	"emergency_nodes": "VehicleView._read_presets",
	"emergency_lights": "VehicleView._read_presets -> beacon_budget",
	"civ_headlights": "VehicleView._read_presets -> cone_cap (MM_headlights)",
	"vehicle_shadows": "VehicleView / StreetLifeView / ConstructionVehicleView",
	"road_detail": "RoadSurfaceView.set_preset",
	"flood_detail": "FloodView.setup",
}
## BUDGET = an assertion: nothing applies it, something CHECKS it. Kept for
## exactly the reason the dead knobs were deleted — a budget is the published
## statement of what a preset may cost, and deleting it throws that away.
const PRESET_KEYS_BUDGET := {
	"gpu_budget_ms": "tools/profile_frame.gd _report_budgets",
	"cpu_budget_ms": "tools/profile_frame.gd _report_budgets",
	"chunk_budget": "tools/profile_frame.gd _report_budgets",
	"near_chunk_max": "tools/profile_frame.gd _report_budgets",
	"vram_budget_mb": "tools/profile_frame.gd _report_budgets",
	"draw_call_budget": "tools/profile_frame.gd + tests/test_bench_city.gd",
	"instance_budget": "tools/profile_frame.gd",
	"pss_budget_mb": "tools/perf_rows.py, against bench_device.sh meminfo",
}
## DELETED in Wave 17, with the FORBIDDEN_KEYS pattern so they cannot drift
## back. Each names a FEATURE THAT DOES NOT EXIST — which is the only reason a
## preset key may be deleted rather than wired, and the reason is recorded per
## key in doc 11 §2.13b:
##
##   * `street_light_radius_m` — the OmniLight pool `StreetlightView`'s class
##     doc promised for four waves and that the billboard-and-decal rig
##     replaced. A radius is meaningless without a light to give it to.
##   * `snow`, `turbulence` — `WeatherFX` has a rain bed and a splash bed and
##     no third system; `grep -rn "snow\|turbulence" game/` finds nothing but
##     these rows.
##   * `reflection_probe`, `probe_size_m`, `probe_move_refresh_m` — doc 11
##     §2.9's High-only `ReflectionProbe`, which no file constructs. DEFERRED,
##     not refused: §2.13b records the node, the owner and the three numbers so
##     the wave that builds it re-authors the rows in the same commit. (The
##     earlier draft of this list cited
##     `test_water_has_two_octaves_and_no_reflection_probe` as a standing
##     ruling that the probe is not coming. It is not one: that test forbids
##     the WATER SHADER from faking a reflection and says in its own message
##     that §2.11 "gates the ONE probe the game may own to High" — i.e. it
##     assumes the probe, it does not refuse it.)
##
## `civ_headlights` was on this list in that same draft, on the claim that it
## duplicated a cap `vehicles.headlight_*` already owns. It does not:
## `vehicles.headlight_night_threshold/_cone_m/_cone_energy/_color` are a
## threshold, a length, an energy and a colour, and `_ensure_cone_capacity`
## grew `MM_headlights` against NO ceiling at all. It is wired, not deleted.
const PRESET_KEYS_DELETED := ["street_light_radius_m", "snow",
		"turbulence", "reflection_probe", "probe_size_m", "probe_move_refresh_m"]


func test_no_inert_preset_key() -> void:
	var presets: Dictionary = _data()["presets"]
	var seen := {}
	for name: String in presets:
		if name.begins_with("_"):
			continue
		for key: String in (presets[name] as Dictionary):
			if key.begins_with("_"):
				continue
			seen[key] = true
			assert_true(PRESET_KEYS_APPLIED.has(key) or PRESET_KEYS_BUDGET.has(key),
					"preset `%s` authors `%s`, which is in neither the APPLIED "
					% [name, key] + "nor the BUDGET list — name its consumer or "
					+ "delete the key (doc 11 §2.13b, report 98 RR-98)")
	for key: String in PRESET_KEYS_APPLIED:
		assert_true(seen.has(key), "`%s` is listed as applied but no preset "
				% key + "authors it any more — drop the row")
	for key: String in PRESET_KEYS_BUDGET:
		assert_true(seen.has(key), "`%s` is listed as a budget but no preset "
				% key + "authors it any more — drop the row")


func test_the_deleted_keys_stay_deleted() -> void:
	var presets: Dictionary = _data()["presets"]
	for name: String in presets:
		if name.begins_with("_"):
			continue
		for key: String in PRESET_KEYS_DELETED:
			assert_false((presets[name] as Dictionary).has(key),
					"preset `%s` has `%s` back. It was deleted in Wave 17 "
					% [name, key] + "because nothing could apply it; if it has "
					+ "a consumer now, move it into PRESET_KEYS_APPLIED and "
					+ "name the file (report 98 RR-98)")


func test_every_preset_resolves_to_the_engine_values_it_authors() -> void:
	var data := _data()
	# Performance: no MSAA, FXAA instead, no shadow, cheapest framebuffer.
	var p := QualityApplier.resolve(data, "performance")
	assert_eq(float(p["render_scale"]), 0.70, "Performance renders 3D at 0.70")
	assert_eq(int(p["msaa_3d"]), 0, "…with MSAA off")
	assert_eq(int(p["screen_space_aa"]), 1, "…and FXAA on, which is the whole "
			+ "point of authoring `fxaa: true` on the tier with no MSAA")
	assert_false(bool(p["shadows_allowed"]), "…and no sun shadow at all")
	assert_false(bool(p["env_adjustments"]), "…and no colour-correction pass")
	# High: full resolution, 4 splits, the widest glow ladder.
	var h := QualityApplier.resolve(data, "high")
	assert_eq(float(h["render_scale"]), 1.0, "High renders 3D at native")
	assert_eq(int(h["msaa_3d"]), 1, "…with 2x MSAA (Godot's MSAA_2X == 1)")
	assert_eq(int(h["shadow_mode"]), 2, "…and 4 shadow splits "
			+ "(DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS == 2)")
	assert_eq(int(h["shadow_atlas"]), 4096, "…on the 4096 atlas it authors")
	var want: Array[float] = [1.0, 1.0, 1.0, 1.0, 1.0, 0.0, 0.0]
	assert_eq(h["glow_levels"], want,
			"…and glow levels 1-5, one-based as doc 11 §2.4 counts mips")
	# The defect in one assertion: High and Balanced must not resolve alike.
	var b := QualityApplier.resolve(data, "balanced")
	var differs := 0
	for key: String in h:
		if str(h[key]) != str(b[key]):
			differs += 1
	assert_true(differs >= 5, "High and Balanced differ on at least five "
			+ "engine-side values; before Wave 17 they reached the engine "
			+ "with NONE of them, which is what 'High is Balanced with more "
			+ "cars' meant (report 98 RR-98) — got %d" % differs)


func test_the_governor_may_only_lower_the_render_scale() -> void:
	var data := _data()
	var stepped := QualityApplier.resolve(data, "high", {"render_scale": 0.75})
	assert_eq(float(stepped["render_scale"]), 0.75,
			"a governor that has stepped down is obeyed")
	var stale := QualityApplier.resolve(data, "performance", {"render_scale": 0.95})
	assert_eq(float(stale["render_scale"]), 0.70,
			"a stale knob from a richer preset may not RAISE the new preset's "
			+ "scale — the preset is a ceiling and the ladder only descends")
	var floored := QualityApplier.resolve(data, "high", {"render_scale": 0.1})
	assert_eq(float(floored["render_scale"]), QualityApplier.RENDER_SCALE_MIN,
			"and the ladder's own floor is honoured")
	# Rung 4 takes the same rule, which is the half that had no owner at all.
	var rung4 := QualityApplier.resolve(data, "high", {"street_lights": 8})
	assert_eq(int(rung4["street_lights"]), 8,
			"a stepped `street_lights` reaches the view that draws lamps")
	var stale4 := QualityApplier.resolve(data, "performance", {"street_lights": 16})
	assert_eq(int(stale4["street_lights"]), 6,
			"…and may not raise Performance's 6 either")


func test_msaa_and_splits_round_down_never_up() -> void:
	# A preset is a ceiling: a typo must not make a phone slower than the row
	# it named, so both mappings floor rather than round.
	assert_eq(QualityApplier._msaa_mode(3), 1, "3 samples -> MSAA_2X, not 4x")
	assert_eq(QualityApplier._msaa_mode(16), 3, "past 8x -> MSAA_8X, the max")
	assert_eq(QualityApplier._msaa_mode(0), 0, "0 -> disabled")
	assert_eq(QualityApplier._shadow_mode(3), 1, "3 splits -> 2; Godot has no 3")
	var none: Array[float] = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
	assert_eq(QualityApplier._glow_level_weights([9]), none,
			"an out-of-range level is DROPPED, not clamped onto level 6 — the "
			+ "most expensive one is not where a typo should land")


func test_the_preset_gate_and_the_frame_gate_compose_on_the_sun() -> void:
	# The bug this is about: `apply()` re-derives `shadow_enabled` every frame,
	# so a preset that wrote it once at boot is overwritten on frame 2.
	var src := _src("res://game/environment_controller.gd")
	assert_true(src.contains("_shadows_allowed and elevation > 2.0"),
			"the sun's shadow gate is the preset's AND the frame's, in the "
			+ "per-frame path — not a one-shot write at preset time")
	assert_true(src.contains("func apply_quality"),
			"…and the preset half arrives through apply_quality()")
	assert_false(src.contains("presets.get(\"balanced\""),
			"and nothing in this file reads the Balanced row by name any more: "
			+ "that hard-coded string is what made all three presets share "
			+ "Balanced's glow (report 98 RR-98)")


# ══════════════════════════════════════════════════════════════════════════
# §2.6b — the MEDIUM/FAR boundary (report 98 RR-98)
# ══════════════════════════════════════════════════════════════════════════

func test_the_far_tier_paints_the_page_the_near_tier_wears() -> void:
	var view := _blob_view("balanced")
	var wall := view.far_wall_albedo()
	var roof := view.far_roof_albedo()
	assert_eq(wall.size(), CityView.FAMILY_ORDER.size(),
			"one measured wall colour per family, in FAMILY_ORDER")
	assert_eq(roof.size(), CityView.FAMILY_ORDER.size(), "and one roof colour")
	# The spread one neutral grey threw away, and the specific frame A91-D-41
	# is about: the tech page is the darkest in the atlas by a wide margin.
	var tech: Color = wall[CityView.FAMILY_ORDER.find("tech")]
	var civic: Color = wall[CityView.FAMILY_ORDER.find("civic")]
	assert_true(tech.r < civic.r * 0.5,
			"tech's page is far darker than civic's — that spread is what one "
			+ "neutral 0.34 threw away (tech %.3f vs civic %.3f)"
			% [tech.r, civic.r])
	# Measured off the real pages, so the numbers are the pages' and not this
	# test's: brick is warm, curtain glass is cool. Retint the atlas and these
	# move with it, which is the whole reason they are not authored.
	var res: Color = wall[CityView.FAMILY_ORDER.find("residential")]
	assert_true(res.r > res.b, "residential wears brick and brick is warm")
	var com: Color = wall[CityView.FAMILY_ORDER.find("commercial")]
	assert_true(com.b > com.r, "commercial wears curtain glass and it is cool")
	view.free()


func test_the_far_palette_is_handed_over_in_the_space_the_uniform_decodes() -> void:
	# The seam, and the reason this section's first draft was three times too
	# dark: a `source_color` uniform IS decoded by the engine, unlike a
	# MultiMesh instance colour (RR-91) and unlike a vertex colour (RR-95).
	# So the measured page mean must be handed over in sRGB and NOT
	# pre-decoded. `Image.get_pixel` on an imported page returns the stored
	# sRGB byte undecoded, so the value published here must sit ABOVE the
	# linear it stands for — a pre-decoded palette would fail this.
	var view := _blob_view("balanced")
	var wall := view.far_wall_albedo()
	for i in wall.size():
		var c: Color = wall[i]
		var linear := c.srgb_to_linear()
		assert_true(c.r > linear.r and c.g > linear.g,
				"family %d's wall colour is published in sRGB (a decode would "
				% i + "LOWER it); if this fails the palette was decoded twice "
				+ "and the far city renders at a third of its brightness "
				+ "(report 98 RR-98)")
	view.free()


func test_no_far_albedo_gain_is_authored() -> void:
	# The level-matched gain fits at 0.96 — identity — so nothing is authored.
	# A constant of 1.0 that nothing varies is the exact thing §2.13b spent
	# this wave deleting, so the sweep lever lives in the shader at its default
	# and only `profile_frame --far-gain=` moves it.
	var lod: Dictionary = _data()["lod"]
	assert_false(lod.has("far_albedo_gain"),
			"§2.6b needs no authored gain: the measured page mean lands the "
			+ "420 m band within 1.6 %% of the same band drawn MEDIUM, and a "
			+ "1.0 in the table would be an inert knob by §X5's own rule")
	var src := _src(FAR)
	assert_true(src.contains("far_wall_albedo") and src.contains("far_roof_albedo"),
			"the shader takes a per-family pair")
	assert_true(_code_only(src).contains("far_family_mix"),
			"…behind a mix that is 0 on a clone with no texture pages, so an "
			+ "un-generated checkout still boots (the `tex_mix` contract)")
	assert_true(_code_only(src).contains("far_albedo_gain"),
			"…and the sweep lever is still there for profile_frame")


func test_street_lights_caps_the_fill_layers_and_not_the_lamps() -> void:
	var data := _data()
	var model := RenderStateModel.new(data, "performance")
	var lamps: Array = []
	# `tile` + `side` is the PLACEMENT KEY the view diffs on, not `id`: ten
	# rows without it collapse onto one kerb and the view draws one lamp.
	# Tiles 0..9 are 0..72 m, so all ten land in chunk (0, 0) and the counts
	# below are one chunk's.
	for i in 10:
		lamps.append({"id": 100 + i, "block_id": "B", "side": 0,
				"tile": Vector2i(i, 1), "pos": Vector3(float(i) * 8.0, 0.0, 8.0)})
	var view := StreetlightView.new()
	view.setup(model, data, lamps)
	view.set_preset("performance", data)
	assert_eq(view.light_budget, 6, "Performance authors 6 per chunk")
	var counts := view.chunk_instance_counts()
	assert_eq(int(counts["pole"]), 10, "every lamp still has its post — a "
			+ "street that changes shape with the quality setting is not a "
			+ "quality setting (report 98 RR-98)")
	assert_eq(int(counts["lamp"]), 10, "…and every lamp is still lit: the "
			+ "night city going dark is job 1, not scenery")
	assert_eq(int(counts["pool_visible"]), 6,
			"the ground pool — the FILL layer — is what the budget caps")
	assert_eq(int(counts["smear_visible"]), 6, "and the wet smear with it")
	view.set_light_budget(20)
	counts = view.chunk_instance_counts()
	assert_eq(int(counts["pool_visible"]), 10,
			"a budget above the chunk's roster shows every pool and no more")
	view.free()


## §2.13's `civ_headlights`, wired in Wave 17 (report 98 RR-98).
##
## `MM_headlights` is the one ADDITIVE buffer the vehicle layer draws and it
## was the one buffer with no ceiling: `_ensure_capacity` clamps every body
## layer against `caps`, and `_ensure_cone_capacity` clamped against nothing.
## The buffer is what this asserts rather than a frame, because `--headless`
## runs on the DUMMY driver — but the buffer IS the cap: the write loop's guard
## is `cone_i < _cone_mm.instance_count`, so a capped buffer is capped writes.
func test_civ_headlights_caps_the_one_additive_buffer() -> void:
	var data := _data()
	var presets: Dictionary = data["presets"]
	assert_eq(int((presets["performance"] as Dictionary)["civ_headlights"]), 96)
	assert_eq(int((presets["balanced"] as Dictionary)["civ_headlights"]), 256)
	assert_eq(int((presets["high"] as Dictionary)["civ_headlights"]), 512)

	var view := VehicleView.new()
	view.setup(data)
	assert_eq(view.cone_cap, 256, "the default preset is balanced")
	view.set_preset("performance", data)
	assert_eq(view.cone_cap, 96, "…and a preset swap moves the ceiling")
	# Ask for far more cones than Performance allows. Before Wave 17 this grew
	# to 1024 and the preset row watched it happen.
	view._ensure_cone_capacity(1000)
	assert_eq(view.cone_buffer_size(), 96,
			"the cone buffer stops at the preset's ceiling; before RR-98 it "
			+ "grew to the next multiple of 32 above the roster, with no cap")
	# A DROP has to shrink, not merely stop filling: High first, then down.
	view.set_preset("high", data)
	view._ensure_cone_capacity(1000)
	assert_eq(view.cone_buffer_size(), 512, "High's ceiling is 512")
	view.set_preset("performance", data)
	assert_eq(view.cone_buffer_size(), 96,
			"a preset DROP shrinks the buffer it inherited — the governor's "
			+ "latched drop takes this path and must not keep High's memory")
	view.free()
