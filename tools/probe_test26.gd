extends SceneTree
## Re-derivation instrument for doc 07 §7 test 26 (`tests/test_weather_director.gd
## ::test_26_difficulty_scaling`) after 99-PA PA-89 gave the Director its
## `buy severity` lever. Same rig the test uses, printed rather than asserted.

const DIRECTOR_DATA := "res://data/director.json"
const WEATHER_DATA := "res://data/weather.json"


func _ctx(tick_index: int) -> TimeContext:
	var clock := GameClock.new()
	clock.tick_index = tick_index
	var ctx := TimeContext.new()
	ctx.tick_index = tick_index
	ctx.game_seconds = clock.game_seconds()
	ctx.dt_game_seconds = 15
	ctx.mode = TimeContext.Mode.FINE
	ctx.is_catchup = false
	ctx.minute_of_day = clock.minute_of_day()
	ctx.hour_of_day = clock.hour_of_day()
	ctx.day_index = clock.day_index()
	ctx.season_index = clock.season_index()
	return ctx


func _director(seed_value: int, preset: String) -> DisasterDirector:
	var director := DisasterDirector.new(
			DirectorTables.load_from_file(DIRECTOR_DATA), RngStreams.new(seed_value))
	var weather := WeatherSystem.new(WeatherTables.load_from_file(WEATHER_DATA),
			RngStreams.new(seed_value))
	weather.set_city_bounds(Vector2(96, 96), 96.0)
	weather.bootstrap(_ctx(0))
	director.attach(weather, IncidentRequestSink.Recording.new())
	director.set_difficulty(preset)
	var difficulty := Difficulty.load_from_file()
	difficulty.select(preset)
	director.set_pressure_knobs(difficulty.row("pressure"))
	return director


func _healthy_inputs() -> DirectorInputs:
	return DirectorInputs.make({
		"city_age_days": 40, "population": 45000, "pop_peak_7d": 45000,
		"treasury": 900000, "daily_opex": 85000,
		"grid_redundancy": 0.6, "water_redundancy": 0.6, "road_redundancy": 0.6,
		"units_owned": {"fire": 4, "police": 5, "utility": 3, "water": 2,
				"construction": 3},
		"total_response_units": 17, "city_stability": 0.75, "difficulty": "standard",
	})


## The suite's own `_drive`, copied so the two agree: tick hourly for `days`,
## resolve everything `resolve_after_h` hours after it starts.
func _drive(director: DisasterDirector, inputs: DirectorInputs, days: int,
		resolve_after_h: int) -> Dictionary:
	var starts: Array = []
	var pending: Dictionary = {}
	for hour in days * 24:
		var ctx := _ctx(hour * GameClock.TICKS_PER_HOUR)
		director.tick_hour(inputs, ctx)
		var minute := hour * 60
		for uid in pending.keys():
			if minute - int(pending[uid]) >= resolve_after_h * 60:
				director.on_event_resolved(int(uid))
				pending.erase(uid)
		for event in director.drain_events():
			if String(event["type"]) == "director_event_started":
				starts.append(event)
				pending[int(event["event_uid"])] = minute
	return {"starts": starts, "bought": director}


func _initialize() -> void:
	var majors := {}
	var totals := {}
	var severities := {}
	for preset in ["casual", "standard", "hard", "crisis"]:
		var count := 0
		var total := 0
		var sev := 0.0
		for seed_value in range(1, 13):
			for row in _drive(_director(seed_value, preset), _healthy_inputs(),
					100, 3)["starts"]:
				total += 1
				sev += float(row["severity_mult"])
				if String(row["class"]) == "major":
					count += 1
		majors[preset] = count
		totals[preset] = total
		severities[preset] = sev / maxf(1.0, float(total))
	print("preset  majors  all  mean_severity")
	for preset in ["casual", "standard", "hard", "crisis"]:
		print("  %-8s %4d %4d  %.4f" % [preset, int(majors[preset]),
				int(totals[preset]), float(severities[preset])])
	print("crisis/casual major ratio : %.6f"
			% (float(majors["crisis"]) / float(maxi(1, int(majors["casual"])))))
	print("standard days per major   : %.4f" % (1200.0 / float(int(majors["standard"]))))
	quit(0)
