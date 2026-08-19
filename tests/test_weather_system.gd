extends SimTest
## Doc 07 §2.1–2.4 — the committed timeline, the 17-channel effect table, the
## derived temperature model, precip01's segment crossfade, the flood stub and
## coarse/fine parity. Tests 1–5e, 11, 12, 28, 33 of §7.

const DATA := "res://data/weather.json"


func _tables() -> WeatherTables:
	return WeatherTables.load_from_file(DATA)


## A TimeContext exactly as TickScheduler builds one (doc 01 §4).
func _ctx(tick_index: int, mode: int = TimeContext.Mode.FINE) -> TimeContext:
	var clock := GameClock.new()
	clock.tick_index = tick_index
	var ctx := TimeContext.new()
	ctx.tick_index = tick_index
	ctx.game_seconds = clock.game_seconds()
	ctx.mode = mode
	ctx.dt_game_seconds = 15 if mode == TimeContext.Mode.FINE else 3600
	ctx.minute_of_day = clock.minute_of_day()
	ctx.hour_of_day = clock.hour_of_day()
	ctx.day_index = clock.day_index()
	ctx.season_index = clock.season_index()
	ctx.season_progress = clock.season_progress()
	return ctx


func _system(seed_value: int = 1337) -> WeatherSystem:
	var ws := WeatherSystem.new(_tables(), RngStreams.new(seed_value))
	ws.set_city_bounds(Vector2(96, 96), 96.0)
	ws.bootstrap(_ctx(0))
	return ws


## Pin the live segment to a known (state, intensity) without touching the
## chain — the effect table is a pure function of those two.
func _pin(ws: WeatherSystem, state: String, intensity: float, minute_of_day: int = 0,
		season: int = 0) -> void:
	ws.timeline.segments.clear()
	ws.timeline.segments.append({"id": 1, "state": state, "start_min": 0,
			"end_min": 100000, "intensity": intensity, "source": "chain", "event_id": -1})
	ws.now_min = 0
	ws.now_gs = 0
	ws.minute_of_day = minute_of_day
	ws.season_index = season


# ------------------------------------------------------------------ tables

func test_1_transition_table_integrity() -> void:
	var tables := _tables()
	assert_true(tables.is_valid(), "data/weather.json valid: " + str(tables.errors))
	for state in WeatherTables.STATES:
		for season in 4:
			var row := tables.transition_row(state, season)
			var total := 0.0
			for entry in row:
				assert_ne(String(entry[0]), state, "%s: no self-transition" % state)
				total += float(entry[1])
			assert_almost_eq(total, 1.0, 1e-6, "%s/%d renormalised row" % [state, season])


func test_1b_transition_worked_example() -> void:
	# §2.1: CLOUDY in SUMMER → clear .4390 rain .3073 heavy .0859 thunder .1366
	# heat .0312; u = 0.62 lands in RAIN.
	var tables := _tables()
	var row := tables.transition_row("CLOUDY", 1)
	var by_state := {}
	for entry in row:
		by_state[String(entry[0])] = float(entry[1])
	assert_almost_eq(float(by_state["CLEAR"]), 0.4390, 0.0002, "clear share")
	assert_almost_eq(float(by_state["RAIN"]), 0.3073, 0.0002, "rain share")
	assert_almost_eq(float(by_state["HEAVY_RAIN"]), 0.0859, 0.0002, "heavy share")
	assert_almost_eq(float(by_state["THUNDERSTORM"]), 0.1366, 0.0002, "thunder share")
	assert_almost_eq(float(by_state["HEAT_WAVE"]), 0.0312, 0.0002, "heat share")
	assert_eq(String(WeatherTables.pick_weighted(row, 0.62)), "RAIN", "u = 0.62 → RAIN")


func test_1c_schema_mismatch_is_a_hard_error() -> void:
	var tables := WeatherTables.new()
	assert_false(tables.load_from({"schema_version": 99}), "wrong version rejected")
	assert_false(tables.is_valid(), "errors recorded, no silent default")


# ------------------------------------------------------------- determinism

func test_2_determinism_same_seed_same_timeline() -> void:
	# 10 000 game-hours of chain generation, twice, on the named weather stream.
	var a := _generate_hours(4242, 10000)
	var b := _generate_hours(4242, 10000)
	assert_eq(a.size(), b.size(), "same segment count")
	assert_true(a.size() > 300, "10 000 game-hours produced a long chain (%d)" % a.size())
	assert_eq(JSON.stringify(a), JSON.stringify(b), "identical segment list")
	var c := _generate_hours(4243, 10000)
	assert_ne(JSON.stringify(a), JSON.stringify(c), "a different seed differs")


func _generate_hours(seed_value: int, hours: int) -> Array:
	var tables := _tables()
	var rng := RngStreams.new(seed_value)
	var timeline := WeatherTimeline.new(tables)
	timeline.bootstrap(0, 0, rng.stream("weather"))
	var out: Array = []
	for h in hours:
		for segment in timeline.ensure_horizon(h * 60, (h / 720) % 4, rng.stream("weather")):
			out.append([String(segment["state"]), int(segment["start_min"]),
					int(segment["end_min"]), float(segment["intensity"])])
	return out


func test_4_duration_bounds_and_quantization() -> void:
	var tables := _tables()
	var rng := RngStreams.new(99)
	var timeline := WeatherTimeline.new(tables)
	timeline.bootstrap(0, 1, rng.stream("weather"))
	var sampled := 0
	for h in 4000:
		for segment in timeline.ensure_horizon(h * 60, 1, rng.stream("weather")):
			sampled += 1
			var bounds := tables.duration_bounds(String(segment["state"]))
			var duration: int = int(segment["end_min"]) - int(segment["start_min"])
			assert_true(duration % 15 == 0, "duration %d ≡ 0 mod 15" % duration)
			# quantize15 can round a bound-adjacent draw outward by ≤7 minutes.
			assert_true(duration >= int(bounds[0]) - 7 and duration <= int(bounds[1]) + 7,
					"%s duration %d in [%d, %d]" % [segment["state"], duration, bounds[0], bounds[1]])
	assert_true(sampled > 500, "sampled %d durations" % sampled)


# ---------------------------------------------------------------- channels

func test_5_effect_bounds_all_channels() -> void:
	var ws := _system()
	assert_eq(WeatherTables.CHANNELS.size(), 17, "17 published channels (RR-15)")
	for state in WeatherTables.STATES:
		for intensity in [0.0, 0.5, 1.0]:
			_pin(ws, state, float(intensity))
			for channel in WeatherTables.CHANNELS:
				var band := ws.tables.effect_band(state, channel)
				var value := ws.get_effect(channel)
				assert_false(is_nan(value), "%s.%s resolves" % [state, channel])
				var lo: float = minf(float(band[0]), float(band[1]))
				var hi: float = maxf(float(band[0]), float(band[1]))
				assert_true(value >= lo - 1e-9 and value <= hi + 1e-9,
						"%s.%s = %f in [%f, %f]" % [state, channel, value, lo, hi])
			var heat := ws.get_transformer_heat_mult()
			assert_true(heat >= 0.70 and heat <= 2.40, "transformer heat mult clamped")


func test_5a_aliases_and_unknown_channel() -> void:
	var ws := _system()
	_pin(ws, "THUNDERSTORM", 0.77)
	for alias in WeatherTables.ALIASES:
		var canonical := String(WeatherTables.ALIASES[alias])
		assert_almost_eq(ws.get_effect(alias), ws.get_effect(canonical), 1e-12,
				"alias %s == %s (C-57)" % [alias, canonical])
	assert_true(is_nan(ws.get_effect("totally_made_up_mult")),
			"unknown channel raises, never a silent 1.0")


func test_5d_fire_escalation_adoption_golden() -> void:
	# RR-15: ownership moved, calibration byte-identical, intensity-invariant.
	var ws := _system()
	var expected := {"CLEAR": 1.00, "CLOUDY": 1.00, "RAIN": 0.80,
			"HEAVY_RAIN": 0.80, "THUNDERSTORM": 0.80, "HEAT_WAVE": 1.25}
	for state in WeatherTables.STATES:
		for intensity in [0.0, 0.25, 0.5, 0.77, 1.0]:
			_pin(ws, state, float(intensity))
			assert_almost_eq(ws.get_effect("fire_escalation_mult"), float(expected[state]),
					1e-9, "%s @ %s" % [state, str(intensity)])
			if state in ["RAIN", "HEAVY_RAIN", "THUNDERSTORM", "HEAT_WAVE"]:
				assert_ne(ws.get_effect("fire_escalation_mult"), ws.get_effect("fire_spread_mult"),
						"%s: escalation and spread are separate channels" % state)
	# Doc 06 §2.4 cross-check: wood house L2, wind 45 kph, CLEAR, hydrant 1.0.
	_pin(ws, "CLEAR", 0.0)
	var wind_term := 1.0 + 0.010 * maxf(0.0, 45.0 - 20.0)
	var esc_env := wind_term * ws.get_effect("fire_escalation_mult") * 1.0
	assert_almost_eq(esc_env, 1.250, 1e-6, "doc 06's esc_env is unchanged by RR-15")


func test_5e_fire_spread_published_and_valued() -> void:
	var ws := _system()
	_pin(ws, "THUNDERSTORM", 0.77)
	assert_almost_eq(ws.get_effect("fire_spread_mult"), 0.4845, 1e-4, "reference storm spread")
	_pin(ws, "CLEAR", 0.0)
	assert_almost_eq(ws.get_effect("fire_spread_mult"), 1.00, 1e-9, "CLEAR @0")
	_pin(ws, "CLEAR", 1.0)
	assert_almost_eq(ws.get_effect("fire_spread_mult"), 1.10, 1e-9, "CLEAR @1")


func test_2_2_worked_thunderstorm() -> void:
	# §2.2: thunderstorm, intensity 0.77, SUMMER, 18:00 (minute_of_day 1080).
	var ws := _system()
	_pin(ws, "THUNDERSTORM", 0.77, 1080, 1)
	assert_almost_eq(ws.get_effect("power_load_mult"), 1.1216, 1e-4, "power_load_mult")
	assert_almost_eq(ws.get_effect("road_speed_mult"), 0.5891, 1e-4, "road_speed_mult")
	assert_almost_eq(ws.get_wind_kph(), 72.4, 0.1, "wind_kph (§7 test 13: 72.4 ± 0.1)")
	assert_almost_eq(ws.get_precip_mm_h(), 29.71, 0.02, "precip_mm_h")
	assert_almost_eq(ws.get_effect("temp_offset_c"), -6.08, 1e-3, "temp_offset_c")
	assert_almost_eq(ws.get_ambient_temp_c(), 24.16, 0.01, "ambient °C")
	assert_almost_eq(ws.get_transformer_heat_mult(), 1.166, 1e-3, "transformer heat mult")
	assert_almost_eq(ws.wx_slowdown(), 1.0 - 0.5891, 1e-4, "doc 10 consumes wx_slowdown")


func test_2_2_worked_heat_wave() -> void:
	# §2.2: heat wave, intensity 0.80, SUMMER, 15:00 — the crisis with no code.
	var ws := _system()
	_pin(ws, "HEAT_WAVE", 0.80, 900, 1)
	assert_almost_eq(ws.get_ambient_temp_c(), 44.6, 0.01, "ambient 44.6 °C")
	assert_almost_eq(ws.get_transformer_heat_mult(), 1.984, 1e-3, "heat mult 1.984")
	assert_almost_eq(ws.get_effect("power_load_mult"), 1.49, 1e-9, "load 1.49")
	var env := ws.env_for_grid()
	assert_true(bool(env["heat_wave"]), "grid env carries the heat-wave flag")
	assert_almost_eq(float(env["t_ambient_c"]), 44.6, 0.01, "grid env ambient")


func test_5b_precip01_and_crossfade() -> void:
	var ws := _system()
	_pin(ws, "THUNDERSTORM", 0.77)
	assert_almost_eq(ws.get_precip01(), 0.8486, 1e-3, "precip01 = precip/35")
	# Crossfade into a HEAVY_RAIN segment at intensity 0.40 (precip01 0.3657).
	ws.timeline.segments.clear()
	ws.timeline.segments.append({"id": 1, "state": "THUNDERSTORM", "start_min": 0,
			"end_min": 120, "intensity": 0.77, "source": "chain", "event_id": -1})
	ws.timeline.segments.append({"id": 2, "state": "HEAVY_RAIN", "start_min": 120,
			"end_min": 180, "intensity": 0.40, "source": "chain", "event_id": -1})
	ws.now_min = 119
	ws.now_gs = 120 * 60 - 61
	assert_almost_eq(ws.get_precip01(), 0.8486, 1e-3, "61 gs out: not yet fading")
	ws.now_gs = 120 * 60 - 30  # u = 0.5
	assert_almost_eq(ws.get_precip01(), 0.6072, 1e-3, "mid-crossfade (C-58)")
	# No other channel is interpolated — they are step functions by design.
	assert_almost_eq(ws.get_effect("precip_mm_h"), 29.71, 0.02, "precip_mm_h still steps")
	# The published series ramps at exactly the crossfade slope and never jumps.
	# (§7 test 5b's "no step > 0.02 per SimTick" cannot hold for its OWN worked
	# example — a 0.4829 delta across a 60 gs / 4-SimTick crossfade is 0.1207
	# per tick by construction. The invariant that IS meaningful, and the one
	# doc 11's wetness integrator actually depends on, is that no step exceeds
	# the crossfade slope: the value never teleports at the boundary.)
	var here := 0.8486
	var there := 0.3657
	var max_step: float = absf(here - there) / 4.0 + 1e-3
	var previous := -1.0
	for gs in range(120 * 60 - 75, 120 * 60, 15):
		ws.now_gs = gs
		var value := ws.get_precip01()
		if previous >= 0.0:
			assert_true(absf(value - previous) <= max_step,
					"precip01 step %f ≤ crossfade slope %f" % [absf(value - previous), max_step])
		previous = value
	ws.now_gs = 120 * 60 - 1
	assert_almost_eq(ws.get_precip01(), there, 0.02, "arrives at the next segment's value")


func test_33_channels_are_position_independent() -> void:
	# C-59: weather state is city-wide global; only in_storm_cell() and the
	# flood field vary spatially.
	var ws := _system()
	_pin(ws, "THUNDERSTORM", 0.77)
	ws.cell.spawn(Vector2(96, 96), 96.0, ws.tables, 12345)
	var baseline := {}
	for channel in WeatherTables.CHANNELS:
		baseline[channel] = ws.get_effect(channel)
	var inside := 0
	var outside := 0
	for i in 500:
		var pos := Vector2(float((i * 37) % 400) - 100.0, float((i * 91) % 400) - 100.0)
		for channel in WeatherTables.CHANNELS:
			assert_almost_eq(ws.get_effect(channel), float(baseline[channel]), 1e-12,
					"%s is position-independent" % channel)
		if ws.in_storm_cell(pos):
			inside += 1
		else:
			outside += 1
	assert_true(inside > 0 and outside > 0, "the cell mask does vary spatially")


# ------------------------------------------------------------------- flood

func test_11_flood_accumulation() -> void:
	# §2.4 worked example: LOW tile, 25 mm/h for 60 min → 110 mm, mult 0.45.
	var flood := FloodField.new(_tables())
	flood.register_tile(10, 10, "LOW")
	flood.register_tile(11, 10, "MID")
	for minute in 60:
		flood.integrate(1.0 / 60.0, 25.0)
	assert_almost_eq(flood.depth_at(10, 10), 110.0, 1.0, "LOW tile depth")
	assert_almost_eq(flood.road_speed_mult_at(10, 10), 0.45, 1e-9, "standing water")
	assert_eq(flood.band_label_at(10, 10), "standing_water")
	assert_almost_eq(flood.depth_at(11, 10), 0.0, 1e-9, "MID tile drains as fast as it fills")


func test_12_flood_recedes_and_reopens() -> void:
	var flood := FloodField.new(_tables())
	flood.register_tile(10, 10, "LOW")
	for minute in 200:
		flood.integrate(1.0 / 60.0, 60.0)  # 360 mm/h in → impassable
	assert_true(flood.is_edge_removed(10, 10), "≥350 mm removes the edge")
	assert_eq(flood.closed_tiles().size(), 1, "one closed tile")
	var closes := 0
	var reopens := 0
	for event in flood.drain_events():
		if event["type"] == &"road_closed_flood":
			closes += 1
		elif event["type"] == &"road_reopened":
			reopens += 1
	assert_eq(closes, 1, "closed exactly once")
	# 900 mm at 40 mm/h needs 22.5 game-hours to clear: the aftermath tail is
	# free, and roads stay degraded well after the storm has exited.
	for minute in 1400:
		flood.integrate(1.0 / 60.0, 0.0)
	assert_almost_eq(flood.depth_at(10, 10), 0.0, 1e-9, "drained dry")
	for event in flood.drain_events():
		if event["type"] == &"road_reopened":
			reopens += 1
	assert_eq(reopens, 1, "reopened exactly once")


func test_flood_block_granularity() -> void:
	# Doc 09 carries elevation per land block (§9 item 8), so the flood field
	# integrates ~9 cells for the starter city, not ~2 300 tiles.
	var flood := FloodField.new(_tables())
	flood.register_block(2, 2, "LOW")
	flood.register_block(3, 2, "HIGH")
	assert_eq(flood.registered_count(), 2, "two blocks, not 512 tiles")
	for minute in 60:
		flood.integrate(1.0 / 60.0, 25.0)
	# Every tile in block (2,2) — tiles 32..47 — reads its block's water.
	assert_almost_eq(flood.depth_at(32, 32), 110.0, 1.0, "block origin tile")
	assert_almost_eq(flood.depth_at(47, 47), 110.0, 1.0, "block far corner")
	assert_almost_eq(flood.depth_at(48, 32), 0.0, 1e-9, "the HIGH block next door is dry")
	assert_almost_eq(flood.road_speed_mult_at(40, 40), 0.45, 1e-9, "band applies per block")
	# A per-tile registration still wins where doc 09 goes finer later.
	flood.register_tile(40, 40, "HIGH")
	for minute in 60:
		flood.integrate(1.0 / 60.0, 25.0)
	assert_almost_eq(flood.depth_at(40, 40), 0.0, 1e-9, "the tile override drains")
	assert_true(flood.depth_at(41, 41) > 110.0, "its neighbours keep the block's water")


func test_edge_speed_mult_for_doc_10() -> void:
	var ws := _system()
	_pin(ws, "THUNDERSTORM", 0.77)
	ws.flood.register_tile(5, 5, "LOW")
	ws.flood.register_tile(6, 5, "LOW")
	assert_almost_eq(ws.edge_speed_mult([Vector2i(5, 5), Vector2i(6, 5)]), 0.5891, 1e-4,
			"dry edge: the global weather term only")
	for minute in 60:
		ws.flood.integrate(1.0 / 60.0, 25.0)
	# §2.4: a flooded tile during a thunderstorm is effectively a wall.
	assert_almost_eq(ws.edge_speed_mult([Vector2i(5, 5), Vector2i(6, 5)]),
			0.5891 * 0.45, 1e-4, "the worst band along the edge binds")
	assert_almost_eq(ws.tile_speed_mult(5, 5), 0.5891 * 0.45, 1e-4, "per tile agrees")


func test_flood_saturation_scalar() -> void:
	var flood := FloodField.new(_tables())
	flood.register_tile(0, 0, "LOW")
	flood.register_tile(1, 0, "LOW")
	for minute in 60:
		flood.integrate(1.0 / 60.0, 25.0)
	assert_almost_eq(flood.flood_saturation(0, 0), 110.0 / 350.0, 1e-3, "0…1 scalar")
	assert_almost_eq(flood.flood_saturation_city(), 110.0 / 350.0, 1e-3, "city mean over LOW")


# --------------------------------------------------------------- modifiers

func test_modifier_stack_receives_weather() -> void:
	var ws := _system()
	var stack := ModifierStack.new()
	ws.attach_modifiers(stack)
	_pin(ws, "HEAT_WAVE", 0.80, 900, 1)
	ws._apply_modifiers()
	assert_eq(stack.source_count(), 1, "one &\"weather\" source")
	assert_almost_eq(stack.product_for("power_demand_residential"), 1.49, 1e-9,
			"power channels carry power_load_mult")
	assert_almost_eq(stack.product_for("water_demand_commercial"), 1.54, 1e-9,
			"water channels carry water_demand_mult")
	assert_almost_eq(stack.product_for("crime_rate"), ws.get_effect("incident_crime_mult"),
			1e-9, "crime_rate carries incident_crime_mult")
	assert_almost_eq(stack.product_for("construction_rate"),
			ws.get_effect("construction_speed_mult"), 1e-9, "construction slows")
	assert_almost_eq(stack.product_for("traffic_density"), 1.0, 1e-9,
			"unmapped channels stay untouched")
	# Re-applying an unchanged weather state must not churn the revision — the
	# scheduler's per-hour channel cache is keyed on it.
	var revision := stack.revision
	ws._apply_modifiers()
	assert_eq(stack.revision, revision, "no push when nothing changed")


# ------------------------------------------------------ parity & round-trip

func test_3_coarse_fine_parity() -> void:
	var fine := _system(777)
	for i in range(0, 11521):
		fine.tick(_ctx(i))
	var coarse := _system(777)
	for h in range(0, 49):
		coarse.advance_coarse(_ctx(h * 240, TimeContext.Mode.COARSE))
	assert_eq(JSON.stringify(fine.timeline.serialize()),
			JSON.stringify(coarse.timeline.serialize()),
			"48 game-hours: fine and coarse commit the same timeline")


func test_28_save_round_trip_mid_storm() -> void:
	var live := _system(31337)
	for i in range(0, 2000):
		live.tick(_ctx(i))
	# Drop a Director storm across the save point, then save mid-storm.
	var now_min := 2000 / 4
	live.inject_storm(now_min + 40, 120, 0.77, 4242)
	for i in range(2000, 2600):
		live.tick(_ctx(i))
	assert_eq(live.get_state(), "THUNDERSTORM", "saved inside the storm")
	var blob: Variant = JSON.parse_string(JSON.stringify(
			CitySim._encode_floats(live.serialize())))
	var restored := WeatherSystem.new(_tables(), RngStreams.new(31337))
	restored.deserialize(CitySim._decode_floats(blob))
	# The shared RNG streams persist once, at the top level — mirror that here.
	restored._rng.deserialize(live._rng.serialize())
	assert_eq(restored.get_state(), live.get_state(), "state survives the round trip")
	assert_almost_eq(restored.get_intensity(), live.get_intensity(), 0.0, "intensity exact")
	assert_almost_eq(restored.get_precip01(), live.get_precip01(), 0.0, "precip01 exact")
	for i in range(2600, 8360):  # 24 further game-hours
		live.tick(_ctx(i))
		restored.tick(_ctx(i))
	assert_eq(JSON.stringify(restored.timeline.serialize()),
			JSON.stringify(live.timeline.serialize()),
			"the next 24 game-hours are identical to the uninterrupted run")
	assert_almost_eq(restored.get_ambient_temp_c(), live.get_ambient_temp_c(), 0.0,
			"ambient temperature identical")


func test_injection_rewrites_the_future() -> void:
	var ws := _system(5)
	for i in range(0, 400):
		ws.tick(_ctx(i))
	var before := ws.timeline.segments.size()
	assert_true(before >= 2, "a committed future exists (%d segments)" % before)
	var id := ws.inject_storm(600, 120, 0.90, 77)
	var injected := ws.timeline.find_by_id(id)
	assert_eq(String(injected["state"]), "THUNDERSTORM", "storm injected")
	assert_eq(int(injected["start_min"]), 570, "truncated to T−30")
	assert_eq(String(injected["source"]), WeatherTimeline.SOURCE_DIRECTOR, "source = director")
	assert_eq(int(injected["event_id"]), 77, "carries the event uid")
	# The tail is HEAVY_RAIN 45 then RAIN 90, then the chain resumes.
	var index := ws.timeline.segments.find(injected)
	assert_eq(String(ws.timeline.segments[index + 1]["state"]), "HEAVY_RAIN", "tail 1")
	assert_eq(int(ws.timeline.segments[index + 1]["end_min"])
			- int(ws.timeline.segments[index + 1]["start_min"]), 45, "45 min of heavy rain")
	assert_eq(String(ws.timeline.segments[index + 2]["state"]), "RAIN", "tail 2")
	assert_true(ws.timeline.segments.size() > index + 3, "the chain resumes past the tail")
	# Nothing overlaps and nothing gaps.
	for i in range(1, ws.timeline.segments.size()):
		assert_eq(int(ws.timeline.segments[i]["start_min"]),
				int(ws.timeline.segments[i - 1]["end_min"]), "segments are contiguous")


# --------------------------------------------------------------- renderer

func test_renderer_contract_events() -> void:
	# Doc 11 §5: weather_changed{precip01, wind, …} is the renderer's whole
	# weather input, and the sim never reaches into the renderer.
	var ws := _system(11)
	var saw := {}
	for i in range(0, 3000):
		ws.tick(_ctx(i))
		for event in ws.drain_events():
			saw[String(event["type"])] = event
	assert_true(saw.has("weather_changed"), "weather_changed is emitted")
	var event: Dictionary = saw["weather_changed"]
	for key in ["precip01", "wind", "wind_kph", "temp_c", "fog", "weather_state", "intensity"]:
		assert_true(event.has(key), "weather_changed carries %s" % key)
	assert_true(event["wind"] is Vector2, "wind is a Vector2 in m/s (doc 11 §5)")
	assert_true(float(event["precip01"]) >= 0.0 and float(event["precip01"]) <= 1.0,
			"precip01 ∈ [0,1]")


func test_coarse_emits_no_render_events() -> void:
	var ws := _system(12)
	for h in range(0, 200):
		ws.advance_coarse(_ctx(h * 240, TimeContext.Mode.COARSE))
	for event in ws.drain_events():
		assert_ne(String(event["type"]), "weather_changed",
				"the coarse path emits no renderer events (doc 01 coarse contract)")


# ---------------------------------------------------------------- calendar

func test_5c_calendar_is_consumed_never_derived() -> void:
	# C-28: no calendar arithmetic may live in sim/weather/.
	# Reading ctx.season_index / ctx.day_index is the contract; DERIVING either
	# from a day count is what C-28 forbids.
	var forbidden := ["DAYS_PER_SEASON", "SEASONS_PER_YEAR", "season_index()",
			"day_index / 30", "day_index % ", "% 30", "/ 30"]
	var dir := DirAccess.open("res://sim/weather")
	assert_true(dir != null, "sim/weather exists")
	dir.list_dir_begin()
	var entry := dir.get_next()
	var scanned := 0
	while entry != "":
		if entry.ends_with(".gd"):
			scanned += 1
			var text := FileAccess.get_file_as_string("res://sim/weather/" + entry)
			for line in text.split("\n"):
				var comment_at := line.find("#")
				var code: String = line.substr(0, comment_at) if comment_at >= 0 else line
				for pattern in forbidden:
					assert_false(code.contains(pattern),
							"%s derives the calendar ('%s')" % [entry, pattern])
		entry = dir.get_next()
	dir.list_dir_end()
	assert_true(scanned >= 10, "scanned %d weather scripts" % scanned)
	# Doc 01's own example, on the 30-day calendar: day 159 at 09:20 is SUMMER.
	var ctx := _ctx(916640)
	assert_eq(ctx.day_index, 159, "day 159")
	assert_eq(ctx.minute_of_day, 560, "09:20")
	assert_eq(ctx.season_index, 1, "SUMMER")
	assert_almost_eq(ctx.season_progress, 0.3130, 1e-4, "season_progress")
	assert_eq(_tables().season_name(ctx.season_index), "SUMMER", "table indexes ctx")
	assert_almost_eq(_tables().season_temp_base_c(ctx.season_index), 26.0, 1e-9, "26 °C base")


func test_no_price_or_damage_tables_in_weather() -> void:
	# C-16 / C-53 / C-54: this subsystem prices nothing, rolls no line failure
	# and holds no damage-state band table.
	# Price CONSTANTS and damage BANDS, not the words. `metrics.repair_cost` is a
	# read-back of doc 03's ledger (C-16) and stays.
	var forbidden := ["repair_cost(", "damage_bands", "capital_value", "M_repair",
			"REPAIR_COST_PER_CAPITAL", "p_fail_5min", "cost_frac_of_build",
			"\"ds1\"", "\"ds2\"", "\"ds3\""]
	var dir := DirAccess.open("res://sim/weather")
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if entry.ends_with(".gd"):
			var text := FileAccess.get_file_as_string("res://sim/weather/" + entry)
			for line in text.split("\n"):
				var comment_at := line.find("#")
				var code: String = line.substr(0, comment_at) if comment_at >= 0 else line
				for pattern in forbidden:
					assert_false(code.contains(pattern),
							"%s owns '%s', which belongs to another doc" % [entry, pattern])
		entry = dir.get_next()
	dir.list_dir_end()
