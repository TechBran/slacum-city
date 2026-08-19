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
