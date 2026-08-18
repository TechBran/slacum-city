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
