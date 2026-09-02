extends SimTest
## Doc 11 §2.8 / §7.3: the day/night gradient, the authored sc_night ramp
## (windows light from 18:00, full by 21:00), Oklab interpolation sanity, and
## the fog far-cull clamp invariant.


func _controller() -> DayNightController:
	var controller := DayNightController.new()
	var data: Dictionary = JSON.parse_string(
			FileAccess.get_file_as_string("res://data/render.json"))
	assert_true(controller.load_from(data), ", ".join(controller.errors))
	return controller


func test_authored_keys_reproduce_exactly() -> void:
	var controller := _controller()
	# At an authored key hour the sample IS the key (07:00, key index 2).
	var s := controller.sample(7.0)
	assert_almost_eq(float(s["night"]), 0.35, 1e-6)
	assert_almost_eq(float(s["sun_energy"]), 1.6, 1e-6)
	assert_almost_eq(float(s["sun_elevation_deg"]), 8.0, 1e-6)
	assert_eq((s["sky_horizon"] as Color).to_html(false).to_upper(), "C88A5A")


func test_night_ramp_is_authored_not_solar() -> void:
	var controller := _controller()
	# sc_night at noon is fully day; rising through the evening window; full
	# well before midnight (doc: windows begin lighting at 18:00, full by 21:00).
	assert_true(float(controller.sample(12.0)["night"]) < 0.1)
	var at_1830 := float(controller.sample(18.5)["night"])
	var at_1930 := float(controller.sample(19.5)["night"])
	var at_2100 := float(controller.sample(21.0)["night"])
	assert_true(at_1830 > 0.1 and at_1830 < 0.7, "dusk is partial (%f)" % at_1830)
	assert_true(at_1930 > at_1830, "ramping through evening")
	assert_almost_eq(at_2100, 1.0, 0.01, "fully night by 21:00")
	# The sun is still up at 18:30 (elev > 0) while windows already light —
	# the doc's 'best-looking moment' property.
	assert_true(float(controller.sample(18.5)["sun_elevation_deg"]) > 0.0)


func test_wraps_midnight() -> void:
	var controller := _controller()
	var late := controller.sample(23.0)
	var early := controller.sample(1.0)
	assert_almost_eq(float(late["night"]), 1.0, 0.01)
	# The authored gradient already eases toward the 05:00 pre-dawn key (0.95),
	# so 01:00 is 0.99 by design — deep night, not a flat 1.0.
	assert_true(float(early["night"]) >= 0.95)
	# Continuity across the wrap: 23:59 ≈ 00:01 within interpolation.
	var before := controller.sample(23.983)
	var after := controller.sample(0.017)
	assert_true((before["sky_top"] as Color).to_rgba32() != 0)
	assert_almost_eq(float(before["night"]), float(after["night"]), 0.01)


func test_azimuth_sweep() -> void:
	var controller := _controller()
	var morning := float(controller.sample(6.0)["sun_azimuth_deg"])
	var noon := float(controller.sample(12.0)["sun_azimuth_deg"])
	assert_almost_eq(noon - morning, 90.0, 1e-6, "360° per 24 h")


func test_oklab_midpoint_not_muddy() -> void:
	# The §2.8 rationale case: warm #C88A5A ↔ cool #9FBEDC. The sRGB midpoint
	# desaturates hard; the Oklab midpoint keeps more chroma.
	var a := Color("C88A5A")
	var b := Color("9FBEDC")
	var oklab_mid := DayNightController.oklab_lerp(a, b, 0.5)
	var srgb_mid := a.lerp(b, 0.5)
	assert_true(oklab_mid.s >= srgb_mid.s - 0.02,
			"Oklab midpoint keeps ≥ sRGB saturation (%f vs %f)" % [oklab_mid.s, srgb_mid.s])
	# Endpoints reproduce exactly.
	assert_eq(DayNightController.oklab_lerp(a, b, 0.0).to_html(false), a.to_html(false))
	assert_eq(DayNightController.oklab_lerp(a, b, 1.0).to_html(false), b.to_html(false))


func test_fog_clamp_invariant() -> void:
	var controller := _controller()
	# §2.8: fog_depth_end ≤ far_cull ALWAYS; begin ≤ 0.75 × end.
	for far_cull in [1200.0, 900.0, 600.0]:
		for night in [0.0, 0.5, 1.0]:
			var fog := controller.fog_state(float(night), float(far_cull))
			assert_true(float(fog["end"]) <= float(far_cull) + 1e-6,
					"end %.0f ≤ cull %.0f" % [fog["end"], far_cull])
			assert_true(float(fog["begin"]) <= 0.75 * float(fog["end"]) + 1e-6)
	# Weather profile blend also respects the clamp.
	var rain_fog := controller.fog_state(0.5, 600.0, "rain", 1.0)
	assert_true(float(rain_fog["end"]) <= 600.0)


func test_ambient_and_saturation_track_night() -> void:
	var controller := _controller()
	var day := controller.sample(12.0)
	var night := controller.sample(23.0)
	assert_true(float(day["ambient_energy"]) > float(night["ambient_energy"]))
	assert_true(float(day["saturation"]) > float(night["saturation"]),
			"night desaturates toward monochrome (§2.8)")


# ═══════════════════ the deep-night ambient floor (report NIGHT-1) ══════════
#
# The playtest bug these five guard: at 03:19 on an AMOLED panel the city
# between the streetlights was OFF pixels. `ambient_energy_night` alone could
# never fix it, because with AMBIENT_SOURCE_SKY the ambient COLOUR is the night
# sky — authored near-black — so the energy was multiplying ~0.0024 of
# radiance. The fix is a second ambient source with an authored colour, faded
# in as `sky_contribution` falls.


## Linear-light luminance of an sRGB colour — the number that decides whether a
## surface is visible, not the 0..1 the hex string shows.
func _linear_luma(c: Color) -> float:
	return 0.2126 * DayNightController._srgb_to_linear(c.r) \
			+ 0.7152 * DayNightController._srgb_to_linear(c.g) \
			+ 0.0722 * DayNightController._srgb_to_linear(c.b)


func test_noon_ambient_is_the_sky_and_only_the_sky() -> void:
	var controller := _controller()
	var day := controller.sample(12.0)
	assert_almost_eq(float(day["ambient_sky_contribution"]),
			controller.ambient_sky_contribution_day, 1e-6,
			"the authored moonlight colour must not touch a noon frame")
	assert_almost_eq(float(day["ambient_floor"]), 0.0, 1e-6,
			"and the floor weight is zero there, so day is bit-identical")


func test_deep_night_hands_the_ambient_to_the_authored_floor() -> void:
	var controller := _controller()
	var night := controller.sample(3.0)
	assert_true(float(night["night"]) > 0.9, "03:00 is deep night")
	assert_true(float(night["ambient_sky_contribution"]) < 0.25,
			("deep night takes its ambient from the authored colour, not from a "
			+ "sky that is authored near-black (%f)")
			% float(night["ambient_sky_contribution"]))
	var moonlight: Color = night["ambient_color"]
	assert_true(moonlight.b > moonlight.r,
			"the floor is MOONLIGHT — blue-grey. A neutral grey floor reads as "
			+ "fog on the frame, which is the failure mode this replaces")
	assert_true(_linear_luma(moonlight) > 0.03,
			"and it has to be a colour with actual radiance in it (%f)"
			% [_linear_luma(moonlight)])


func test_the_floor_is_a_deep_night_effect_not_a_dusk_one() -> void:
	# 18:30 is already night = 0.40 while the sky is still ORANGE. A LINEAR
	# blend would push 40% of a blue floor into that frame and grey out the
	# best-looking moment in the game; the authored gamma cuts it to 0.40² =
	# 0.16, so dusk keeps its sky and 03:00 gets the floor.
	var controller := _controller()
	var dusk := controller.sample(18.5)
	var night_at_dusk := float(dusk["night"])
	assert_almost_eq(float(dusk["ambient_floor"]),
			pow(night_at_dusk, controller.ambient_floor_gamma), 1e-6,
			"the floor weight IS night ^ ambient_floor_gamma")
	assert_true(controller.ambient_floor_gamma > 1.0, "…and the gamma bends it late")
	assert_true(float(dusk["ambient_floor"]) < 0.5 * night_at_dusk,
			"so dusk takes less than half of what a linear ramp would give it")
	# Monotonic all the same: no hour between noon and midnight goes backwards.
	var previous := -1.0
	for hour in [12.0, 15.0, 18.0, 19.0, 20.0, 21.0, 23.0]:
		var floor_w := float(controller.sample(float(hour))["ambient_floor"])
		assert_true(floor_w >= previous - 1e-6,
				"floor weight never dips on the way into night (%.1f h)" % hour)
		previous = floor_w


func test_the_night_floor_clears_the_black_point_it_was_authored_for() -> void:
	# The measurable version of the playtest complaint. The irradiance an UNLIT
	# façade receives at 03:00 is
	#     ambient_energy_night × [(1 − c)·L(ambient_color_night) + c·L(sky)]
	# with c = ambient_sky_contribution at that hour. Before this pass that was
	# 0.10 × 0.0024 ≈ 0.00024 — an albedo-0.35 wall returned 8e-5 of linear
	# light, which AgX's toe crushes to zero and an AMOLED panel renders as an
	# OFF pixel. The floor has to clear 0.02 for a mid-grey façade to come back
	# at roughly 0.09 sRGB, which is the dimmest value that survives the panel.
	var controller := _controller()
	var s := controller.sample(3.0)
	var c := float(s["ambient_sky_contribution"])
	var sky := 0.5 * (_linear_luma(s["sky_top"]) + _linear_luma(s["sky_horizon"]))
	var irradiance := float(s["ambient_energy"]) \
			* ((1.0 - c) * _linear_luma(controller.ambient_color_night) + c * sky)
	assert_true(irradiance > 0.02,
			("deep-night ambient irradiance %f must clear the AMOLED black "
			+ "point — this is the number the 03:19 playtest shot failed on")
			% irradiance)
	# The moon carries the other half: without a directional term every façade
	# is one flat value and a tower stops reading as two faces and a roof.
	assert_true(controller.moon_energy > 0.2,
			"the moon has to MODEL the geometry, not just tint it (%f)"
			% controller.moon_energy)


func test_the_floor_never_brightens_the_day_frame() -> void:
	# The whole pass is allowed to change exactly one thing: night. Any hour
	# with the sun up must keep the ambient it always had — sky only, at
	# `ambient_energy_day`, with no authored colour mixed in.
	var controller := _controller()
	for hour in [7.0, 9.0, 12.0, 15.0, 17.0]:
		var s := controller.sample(float(hour))
		assert_true(float(s["ambient_floor"]) < 0.15,
				"%.0f:00 takes almost none of the floor (%f)"
				% [hour, float(s["ambient_floor"])])
		assert_true(float(s["ambient_sky_contribution"]) > 0.85,
				"%.0f:00 is still lit by its own sky" % [hour])


# ---------------------------------------------------------------------------
# Wave 17 — THE SKY (§2.8): the gradient's four colours from one sample
# ---------------------------------------------------------------------------

func test_the_sky_haze_is_the_fog_tint_so_the_city_edge_seats_into_it() -> void:
	var controller := DayNightController.new()
	assert_true(controller.load_from(StarterCityLoader.read_json("res://data/render.json")))
	# Dawn: the horizon keeps its authored orange and the haze is the authored
	# fog — two colours, neither a blend of the other.
	var dawn := controller.sky_colors(controller.sample(7.0))
	assert_eq((dawn["horizon"] as Color).to_html(false).to_upper(), "C88A5A")
	assert_eq((dawn["haze"] as Color).to_html(false).to_upper(), "5A5A66")
	assert_eq((dawn["zenith"] as Color).to_html(false).to_upper(), "2A3C5E")
	# At every hour the haze IS the sampled fog tint, and the ground hemisphere is
	# that tint darkened — never brighter than the band above it.
	for i in 48:
		var hour := float(i) * 0.5
		var s := controller.sample(hour)
		var colors := controller.sky_colors(s, 0.45)
		assert_true((colors["haze"] as Color).is_equal_approx(s["fog_tint"]),
				"haze == fog tint at %.1f" % hour)
		assert_true(_linear_luma(colors["ground"]) <= _linear_luma(colors["haze"]) + 1e-6,
				"ground hemisphere darker than the haze at %.1f" % hour)
		assert_true((colors["ground"] as Color).is_equal_approx(
				(s["fog_tint"] as Color).darkened(0.45)), "ground = haze darkened at %.1f" % hour)
	# The shape knobs are data, and the radiance size is the small one.
	var sky_cfg: Dictionary = StarterCityLoader.read_json("res://data/render.json").get("sky", {})
	for key: String in ["radiance_size", "zenith_curve", "haze_height", "haze_strength",
			"ground_falloff", "ground_darken"]:
		assert_true(sky_cfg.has(key), "data/render.json.sky carries %s" % key)
	assert_true(int(sky_cfg["radiance_size"]) <= 128,
			"the ambient cubemap is regenerated every frame — it stays small")
	assert_true(FileAccess.file_exists("res://game/shaders/sky_gradient.gdshader"),
			"the gradient sky shader ships")
	var source := FileAccess.get_file_as_string("res://game/shaders/sky_gradient.gdshader")
	assert_true(source.begins_with("shader_type sky;"), "it is a sky shader")
	assert_false(source.contains("use_half_res_pass") or source.contains("use_quarter_res_pass"),
			"no half/quarter-res sky pass — a second draw for a gradient (doc 11 §2.13)")
	for uniform: String in ["zenith_color", "horizon_color", "haze_color", "ground_color", "energy"]:
		assert_true(source.contains("uniform vec3 %s" % uniform)
				or source.contains("uniform float %s" % uniform),
				"the shader takes %s" % uniform)
