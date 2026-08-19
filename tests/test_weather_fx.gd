extends SimTest
## Doc 11 §2.9 — the weather VFX arithmetic, headless.
##
## The particles themselves are not testable without a GPU, and they are not
## where the bugs live. What IS testable, and what these guard, is every number
## the doc pins down: the two-stroke lightning envelope, the asymmetric wetness
## integrator, `precip01` as the only precipitation input, and the fog/storm
## coupling handed to EnvironmentController.


func _fx() -> WeatherFX:
	var fx := WeatherFX.new()
	fx.setup(StarterCityLoader.read_json("res://data/render.json"))
	return fx


# ------------------------------------------------------------- the envelope

func test_lightning_envelope_matches_the_authored_knots() -> void:
	var fx := _fx()
	fx.strike(1.0)
	# Knot 1: the leading stroke peaks at 0.02 s.
	fx.refresh(0.02, Vector3.ZERO)
	assert_almost_eq(fx.lightning01, 1.0, 1e-6, "0.02 s → 1.00")
	# Knot 2: the gap between strokes.
	fx.refresh(0.07, Vector3.ZERO)
	assert_almost_eq(fx.lightning01, 0.15, 1e-6, "0.09 s → 0.15")
	# Knot 3: the RETURN stroke, brighter than the gap — the two-stroke read.
	fx.refresh(0.04, Vector3.ZERO)
	assert_almost_eq(fx.lightning01, 0.85, 1e-6, "0.13 s → 0.85")
	# Tail: back to black by 0.30 s and the envelope releases.
	fx.refresh(0.17, Vector3.ZERO)
	assert_almost_eq(fx.lightning01, 0.0, 1e-6, "0.30 s → 0.00")
	fx.refresh(0.10, Vector3.ZERO)
	assert_almost_eq(fx.lightning01, 0.0, 1e-6, "and stays there")
	fx.free()


func test_flash_scales_by_magnitude_not_the_envelope() -> void:
	# sc_lightning is the bare envelope (the rain pass reads it); `f` — what
	# the five §2.9 light writes use — is envelope × magnitude.
	var fx := _fx()
	fx.strike(0.5)
	fx.refresh(0.02, Vector3.ZERO)
	assert_almost_eq(fx.lightning01, 1.0, 1e-6, "the global is the envelope")
	assert_almost_eq(fx.flash01(), 0.5, 1e-6, "f is envelope × magnitude")
	fx.free()


func test_reduce_flashes_scales_the_envelope() -> void:
	var fx := _fx()
	fx.reduce_flashes = true
	fx.strike(1.0)
	fx.refresh(0.02, Vector3.ZERO)
	# data/render.json: lightning_reduce_flashes_scale = 0.25.
	assert_almost_eq(fx.lightning01, 0.25, 1e-6, "accessibility scale applied")
	fx.free()


func test_a_second_strike_retriggers_and_never_stacks() -> void:
	var fx := _fx()
	fx.strike(1.0)
	fx.refresh(0.02, Vector3.ZERO)
	fx.strike(1.0)                       # mid-envelope
	fx.refresh(0.02, Vector3.ZERO)
	assert_almost_eq(fx.lightning01, 1.0, 1e-6,
			"the envelope restarts; two overlapping flashes would exceed the "
			+ "§2.9 luminance guard")
	fx.free()


# ----------------------------------------------------------- the integrator

func test_wetness_soaks_fast_and_dries_slow() -> void:
	var fx := _fx()
	fx.set_weather("RAIN", 0.5, 0.5)
	# τ 25 s rising: one time constant reaches 1 − 1/e of the target.
	var target := 0.5 * 1.2
	fx.refresh(25.0, Vector3.ZERO)
	assert_almost_eq(fx.wetness, target * (1.0 - exp(-1.0)), 1e-4, "τ_up = 25 s")
	# τ 90 s falling, from wherever it got to.
	var before := fx.wetness
	fx.set_weather("CLEAR", 0.0, 0.0)
	fx.refresh(90.0, Vector3.ZERO)
	assert_almost_eq(fx.wetness, before * exp(-1.0), 1e-4, "τ_down = 90 s")
	assert_true(fx.wetness > 0.0, "the street is still wet after the rain stops")
	fx.free()


func test_precip01_saturates_the_ground_at_0834() -> void:
	# §2.9: target = precip01 × 1.2, so 0.834 × 1.2 = 1.001 → fully soaked.
	var fx := _fx()
	fx.set_weather("HEAVY_RAIN", 0.834, 1.0)
	for i in 40:
		fx.refresh(10.0, Vector3.ZERO)
	assert_almost_eq(fx.wetness, 1.0, 1e-3, "saturated, and clamped at 1")
	fx.free()


# --------------------------------------------------------------- the events

func test_consumes_doc_07s_payloads_exactly() -> void:
	var fx := _fx()
	var touched := fx.feed_events([
		{"type": &"weather_changed", "weather_state": "THUNDERSTORM",
			"intensity": 0.8, "precip01": 0.7, "wind": Vector2(4.0, -2.0)},
		{"type": &"economy_hour_settled", "net": 12.0},
	])
	assert_true(touched, "the batch had weather in it")
	assert_eq(fx.weather_state, "THUNDERSTORM")
	assert_almost_eq(fx.precip01, 0.7, 1e-6)
	assert_almost_eq(fx.intensity, 0.8, 1e-6)
	assert_eq(fx.wind_ms, Vector2(4.0, -2.0), "wind is metres/second, as published")

	fx.feed_events([{"type": &"lightning_strike", "magnitude": 0.9,
			"world_pos": Vector3(80.0, 0.0, 40.0)}])
	fx.refresh(0.02, Vector3.ZERO)
	assert_almost_eq(fx.flash01(), 0.9, 1e-6, "the strike's own magnitude")

	# Doc 07's in-cloud flashes light the sky with no strike behind them.
	fx.feed_events([{"type": &"lightning_flash_cosmetic", "magnitude": 0.4}])
	fx.refresh(0.02, Vector3.ZERO)
	assert_almost_eq(fx.flash01(), 0.4, 1e-6)
	fx.free()


func test_unknown_events_are_ignored() -> void:
	var fx := _fx()
	assert_false(fx.feed_events([{"type": &"BlockDarkChanged", "block_id": "B1"}]),
			"nothing weather-shaped in the batch")
	assert_almost_eq(fx.precip01, 0.0, 1e-9)
	fx.free()


# ------------------------------------------------- the environment coupling

func test_fog_profile_and_storm_darkness() -> void:
	var fx := _fx()
	fx.set_weather("CLEAR", 0.0, 0.0)
	assert_eq(fx.fog_profile(), "", "clear skies use §2.8's clear profiles only")
	assert_almost_eq(fx.storm01(), 0.0, 1e-9)

	fx.set_weather("RAIN", 0.5, 0.5)
	assert_eq(fx.fog_profile(), "rain")
	var rain_storm := fx.storm01()

	# Same rain rate, thunderstorm: darker. That difference is the ONLY reason
	# the weather enum reaches the renderer at all (§2.9 consumes precip01).
	fx.set_weather("THUNDERSTORM", 0.5, 0.5)
	assert_eq(fx.fog_profile(), "rain")
	assert_true(fx.storm01() > rain_storm,
			"a thunderstorm is darker than plain rain at the same precip01")

	fx.set_weather("HEAVY_RAIN", 1.0, 1.0)
	assert_almost_eq(fx.storm01(), 1.0, 1e-6, "clamped at 1")
	assert_almost_eq(fx.fog_mix(), 1.0, 1e-6)
	fx.free()


func test_pinning_ignores_the_sim_stream() -> void:
	# The dev/visual-review path, and proof it is opt-in: an unpinned WeatherFX
	# always follows doc 07.
	var fx := _fx()
	fx.feed_events([{"type": &"weather_changed", "weather_state": "RAIN",
			"intensity": 0.3, "precip01": 0.3, "wind": Vector2.ZERO}])
	assert_almost_eq(fx.precip01, 0.3, 1e-6, "the renderer follows the sim")
	fx.pin_weather("THUNDERSTORM", 0.9, 0.9)
	fx.feed_events([{"type": &"weather_changed", "weather_state": "CLEAR",
			"intensity": 0.0, "precip01": 0.0, "wind": Vector2.ZERO}])
	assert_almost_eq(fx.precip01, 0.9, 1e-6, "pinned: the sim is ignored")
	fx.free()
