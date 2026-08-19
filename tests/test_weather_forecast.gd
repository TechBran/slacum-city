extends SimTest
## Doc 07 §2.5 — the forecast is a strategic resource, so it must be honest,
## stable and calibrated. Tests 6–9 of §7.

const DATA := "res://data/weather.json"


func _tables() -> WeatherTables:
	return WeatherTables.load_from_file(DATA)


func _rig() -> Array:
	var tables := _tables()
	var timeline := WeatherTimeline.new(tables)
	return [tables, timeline, WeatherForecast.new(tables, timeline)]


func _segment(id: int, state: String, start_min: int, intensity: float,
		source: String = "chain") -> Dictionary:
	return {"id": id, "state": state, "start_min": start_min, "end_min": start_min + 120,
			"intensity": intensity, "source": source, "event_id": -1}


func test_p_correct_table() -> void:
	# §2.5's published accuracy ladder.
	var forecast: WeatherForecast = _rig()[2]
	assert_almost_eq(forecast.p_correct(0), 0.97, 1e-9, "lead 0 h")
	assert_almost_eq(forecast.p_correct(180), 0.9175, 1e-4, "lead 3 h")
	assert_almost_eq(forecast.p_correct(360), 0.865, 1e-3, "lead 6 h")
	assert_almost_eq(forecast.p_correct(720), 0.76, 1e-3, "lead 12 h")
	assert_almost_eq(forecast.p_correct(1440), 0.55, 1e-3, "lead 24 h")
	assert_almost_eq(forecast.p_correct(100000), 0.50, 1e-9, "clamped at 0.50")


func test_6_forecast_at_lead_zero_is_always_true() -> void:
	var rig := _rig()
	var forecast: WeatherForecast = rig[2]
	var wrong := 0
	for i in 1000:
		var state: String = WeatherTables.STATES[i % WeatherTables.STATES.size()]
		var segment := _segment(i + 1, state, 500, 0.5)
		var entry := forecast.entry_for(segment, 500, forecast.refresh_index(500))
		if String(entry["state"]) != state:
			wrong += 1
		assert_eq(int(entry["lead_min"]), 0)
	assert_eq(wrong, 0, "1000/1000 correct at lead 0 — live weather is not a forecast")


func test_7_forecast_accuracy_calibration_at_lead_360() -> void:
	var rig := _rig()
	var forecast: WeatherForecast = rig[2]
	var correct := 0
	var samples := 5000
	for i in samples:
		var state: String = WeatherTables.STATES[i % WeatherTables.STATES.size()]
		var segment := _segment(i + 1, state, 360, 0.5)
		var entry := forecast.entry_for(segment, 0, i)
		if String(entry["state"]) == state:
			correct += 1
	var rate := float(correct) / float(samples)
	assert_true(absf(rate - 0.865) <= 0.03,
			"measured %f within 0.865 ± 0.03" % rate)


func test_8_forecast_stability_within_a_refresh_window() -> void:
	var rig := _rig()
	var timeline: WeatherTimeline = rig[1]
	var forecast: WeatherForecast = rig[2]
	var rng := RngStreams.new(4242)
	timeline.bootstrap(0, 1, rng.stream("weather"))
	timeline.ensure_horizon(0, 1, rng.stream("weather"))
	var a := JSON.stringify(forecast.get_forecast(600))
	var b := JSON.stringify(forecast.get_forecast(600))
	assert_eq(a, b, "two calls inside one window are byte-identical")
	var c := JSON.stringify(forecast.get_forecast(659))
	assert_eq(forecast.refresh_index(600), forecast.refresh_index(659), "same window")
	assert_true(a.length() > 10, "the forecast is non-empty")
	# Across a refresh the entries may change, but they converge: mean absolute
	# start error is non-increasing as the segment approaches.
	var previous_error := 1e9
	var non_increasing := true
	for step in 12:
		var now_min := 600 + step * 60
		var error := 0.0
		var count := 0
		for entry in forecast.get_forecast(now_min):
			error += absf(float(entry["start_min"]) - float(entry["true_start_min"]))
			count += 1
		if count == 0:
			continue
		error /= float(count)
		if error > previous_error + 25.0:
			non_increasing = false
		previous_error = error
	assert_true(non_increasing, "forecast error converges toward truth")
	assert_ne(c, "", "later windows still produce a forecast")


func test_9_no_invented_severe_inside_three_hours() -> void:
	var rig := _rig()
	var forecast: WeatherForecast = rig[2]
	var invented := 0
	var confused := 0
	for i in 6000:
		var state: String = ["CLEAR", "CLOUDY", "RAIN", "HEAVY_RAIN"][i % 4]
		var lead: int = [30, 90, 150, 180][i % 4]
		var segment := _segment(i + 1, state, lead, 0.5)
		var entry := forecast.entry_for(segment, 0, i)
		var shown := String(entry["state"])
		if shown != state:
			confused += 1
			if shown == "THUNDERSTORM" or shown == "HEAT_WAVE":
				invented += 1
	assert_eq(invented, 0, "no near-term false alarm ever invents severe weather")
	assert_true(confused > 0, "the confusion table is live at these leads (%d)" % confused)


func test_9b_severe_may_be_invented_beyond_three_hours() -> void:
	var rig := _rig()
	var forecast: WeatherForecast = rig[2]
	var invented := 0
	for i in 6000:
		var segment := _segment(i + 1, "RAIN", 600, 0.5)
		var entry := forecast.entry_for(segment, 0, i)
		if String(entry["state"]) == "THUNDERSTORM":
			invented += 1
	assert_true(invented > 0,
			"beyond 3 h a false alarm reads as uncertainty, not a lie (%d)" % invented)


func test_confusion_is_neighbours_only() -> void:
	var rig := _rig()
	var forecast: WeatherForecast = rig[2]
	var allowed := {
		"CLEAR": ["CLOUDY"], "CLOUDY": ["CLEAR", "RAIN"],
		"RAIN": ["CLOUDY", "HEAVY_RAIN", "THUNDERSTORM"],
		"HEAVY_RAIN": ["RAIN", "THUNDERSTORM"],
		"THUNDERSTORM": ["HEAVY_RAIN", "RAIN"], "HEAT_WAVE": ["CLEAR", "CLOUDY"],
	}
	for state in WeatherTables.STATES:
		for i in 400:
			var segment := _segment(i + 1, state, 900, 0.5)
			var shown := String(forecast.entry_for(segment, 0, i)["state"])
			if shown == state:
				continue
			assert_true((allowed[state] as Array).has(shown),
					"%s → %s is a neighbour" % [state, shown])


func test_director_segments_are_never_hidden() -> void:
	# Honesty rule 1 (F7 outranks forecast noise).
	var rig := _rig()
	var forecast: WeatherForecast = rig[2]
	for i in 2000:
		var segment := _segment(i + 1, "THUNDERSTORM", 90, 0.85, "director")
		var entry := forecast.entry_for(segment, 0, i)
		assert_eq(String(entry["state"]), "THUNDERSTORM", "no hidden severe")


func test_ui_bands() -> void:
	var forecast: WeatherForecast = _rig()[2]
	assert_eq(forecast.ui_band(0), "exact")
	assert_eq(forecast.ui_band(360), "exact")
	assert_eq(forecast.ui_band(361), "window")
	assert_eq(forecast.ui_band(720), "window")
	assert_eq(forecast.ui_band(721), "probability")
	assert_eq(forecast.ui_band(1440), "probability")


func test_forecast_reads_the_committed_timeline() -> void:
	var tables := _tables()
	var rng := RngStreams.new(99)
	var ws := WeatherSystem.new(tables, rng)
	ws.set_city_bounds(Vector2(96, 96), 96.0)
	var ctx := TimeContext.new()
	ws.bootstrap(ctx)
	var entries := ws.get_forecast()
	assert_true(entries.size() >= 1, "the forecast has entries the moment the city boots")
	for entry in entries:
		assert_true(int(entry["lead_min"]) >= 0 and int(entry["lead_min"]) <= tables.horizon_min,
				"every entry is inside the 24 game-hour horizon")
		assert_true(tables.has_state(String(entry["state"])), "displayed state is a real state")
