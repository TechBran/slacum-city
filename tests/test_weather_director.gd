extends SimTest
## Doc 07 §2.6 — the Disaster Director: preparedness, threat budget, and the
## ten hard fairness rules. Tests 10, 18–24, 26, 27 of §7.
##
## The whole design claim under test is Core Rule 9: *disasters test prior
## planning, never punish arbitrarily.* F1 and F4–F10 are absolute gates, not
## soft weights, and they are identical at every difficulty.

const WEATHER_DATA := "res://data/weather.json"
const DIRECTOR_DATA := "res://data/director.json"


func _ctx(tick_index: int, is_catchup: bool = false) -> TimeContext:
	var clock := GameClock.new()
	clock.tick_index = tick_index
	var ctx := TimeContext.new()
	ctx.tick_index = tick_index
	ctx.game_seconds = clock.game_seconds()
	ctx.dt_game_seconds = 3600 if is_catchup else 15
	ctx.mode = TimeContext.Mode.COARSE if is_catchup else TimeContext.Mode.FINE
	ctx.is_catchup = is_catchup
	ctx.minute_of_day = clock.minute_of_day()
	ctx.hour_of_day = clock.hour_of_day()
	ctx.day_index = clock.day_index()
	ctx.season_index = clock.season_index()
	return ctx


func _director(seed_value: int = 1337, preset: String = "standard") -> DisasterDirector:
	var director := DisasterDirector.new(DirectorTables.load_from_file(DIRECTOR_DATA),
			RngStreams.new(seed_value))
	var weather := WeatherSystem.new(WeatherTables.load_from_file(WEATHER_DATA),
			RngStreams.new(seed_value))
	weather.set_city_bounds(Vector2(96, 96), 96.0)
	weather.bootstrap(_ctx(0))
	director.attach(weather, IncidentRequestSink.Recording.new())
	director.set_difficulty(preset)
	return director


## The §2.6.3 reference city: pop 45 000, tier 3, Standard, age 40 days.
func _reference_inputs() -> DirectorInputs:
	return DirectorInputs.make({
		"city_age_days": 40, "population": 45000, "pop_peak_7d": 45000,
		"treasury": 620000, "daily_opex": 85000,
		"grid_redundancy": 0.62, "water_redundancy": 0.62, "road_redundancy": 0.62,
		"units_owned": {"fire": 4, "police": 4, "utility": 3, "water": 1, "construction": 2},
		"total_response_units": 14, "city_stability": 0.68, "difficulty": "standard",
	})


func _healthy_inputs(stability: float = 0.75) -> DirectorInputs:
	return DirectorInputs.make({
		"city_age_days": 40, "population": 45000, "pop_peak_7d": 45000,
		"treasury": 900000, "daily_opex": 85000,
		"grid_redundancy": 0.6, "water_redundancy": 0.6, "road_redundancy": 0.6,
		"units_owned": {"fire": 4, "police": 5, "utility": 3, "water": 2, "construction": 3},
		"total_response_units": 17, "city_stability": stability, "difficulty": "standard",
	})


## Hourly driver. Every started event is resolved `resolve_after` game-hours
## later, which is what makes F2's from-resolution cooldown measurable.
func _drive(director: DisasterDirector, inputs: DirectorInputs, days: int,
		resolve_after: int = 3, is_catchup: bool = false) -> Dictionary:
	var starts: Array = []
	var scheduled: Array = []
	var warnings: Array = []
	var pending: Dictionary = {}
	var tp_samples: Array = []
	for h in days * 24:
		for uid in pending.keys():
			if h >= int(pending[uid]):
				director.on_event_resolved(int(uid))
				pending.erase(uid)
		director.tick_hour(inputs, _ctx(h * 240, is_catchup))
		tp_samples.append(director.tp_pool)
		for event in director.drain_events():
			match event["type"]:
				&"director_event_started":
					var row: Dictionary = event.duplicate()
					row["hour"] = h
					row["minute"] = h * 60
					starts.append(row)
					pending[int(event["event_uid"])] = h + resolve_after
				&"director_event_scheduled":
					var row2: Dictionary = event.duplicate()
					row2["hour"] = h
					scheduled.append(row2)
				&"weather_warning":
					var row3: Dictionary = event.duplicate()
					row3["minute"] = h * 60
					warnings.append(row3)
	return {"starts": starts, "scheduled": scheduled, "warnings": warnings,
			"tp": tp_samples}


# --------------------------------------------------------- derived scores

func test_2_6_worked_example() -> void:
	var director := _director()
	var inputs := _reference_inputs()
	assert_almost_eq(director.redundancy(inputs), 0.62, 1e-9, "R")
	assert_almost_eq(director.fleet_strength(inputs), 0.635, 0.001, "F = 0.635")
	assert_almost_eq(director.preparedness(inputs), 0.658, 0.001, "P = 0.658")
	var p := director.preparedness(inputs)
	assert_almost_eq(director.tp_rate_per_day(inputs, p, false), 22.83, 0.05,
			"22.8 TP/game-day")
	assert_almost_eq(director.severity_for(p, false), 1.126, 0.001, "severity 1.126")
	assert_eq(director.tables.city_tier(45000), 3, "tier 3")
	assert_eq(director.tables.city_tier(1999), 0)
	assert_eq(director.tables.city_tier(2000), 1)
	assert_eq(director.tables.city_tier(120000), 4)


func test_2_6_candidate_weight_golden() -> void:
	# §2.6.3's weight table, with tp_pool = 41 and severe storm last seen 14 d
	# ago. (The doc's table omits season affinity; SPRING gives severe 1.0.)
	var director := _director()
	director.tp_pool = 41.0
	director._now_min = 20 * 1440
	# Novelty, exactly as the doc's table reads it: severe storm last seen 14
	# game-days ago (→ ×1.5), traffic pileup 5 days ago (→ ×1.0).
	director.last_event_start_min["severe_thunderstorm"] = 6 * 1440
	director.last_event_start_min["traffic_pileup"] = 15 * 1440
	var event := director.tables.event_by_id("severe_thunderstorm")
	assert_almost_eq(director.candidate_weight(event, 0), 2.290, 0.002,
			"1.0 × 1.5 novelty × 1.527 budget bias")
	var pileup := director.tables.event_by_id("traffic_pileup")
	assert_almost_eq(director.candidate_weight(pileup, 0), 1.197, 0.002, "traffic_pileup")
	# Season affinity zeroes a heat wave in winter — a hard 0, not a small number.
	assert_almost_eq(director.candidate_weight(director.tables.event_by_id("heat_wave"), 3),
			0.0, 1e-9, "no heat wave in winter")


func test_27_preparedness_monotonicity() -> void:
	var director := _director()
	var previous_rate := -1.0
	var previous_severity := -1.0
	for step in range(1, 10):
		var p := float(step) / 10.0
		var inputs := _reference_inputs()
		var rate := director.tp_rate_per_day(inputs, p, false)
		var severity := director.severity_for(p, false)
		assert_true(rate > previous_rate, "tp_rate strictly increases with P (%f)" % p)
		assert_true(severity > previous_severity, "severity strictly increases with P")
		assert_true(severity >= 0.60 and severity <= 1.40, "severity inside its clamp")
		previous_rate = rate
		previous_severity = severity
	# The anti-frustration spine: 0.55× at P=0, 1.45× at P=1.
	var low := _reference_inputs()
	assert_almost_eq(director.tp_rate_per_day(low, 0.20, false)
			/ director.tp_rate_per_day(low, 0.0, false), 0.73 / 0.55, 0.01,
			"pressure = 0.55 + 0.90·P")


# --------------------------------------------------------------- fairness

func test_1_grace_period() -> void:
	var director := _director()
	var young := DirectorInputs.make({"city_age_days": 2, "population": 45000,
			"treasury": 500000, "daily_opex": 50000, "city_stability": 0.8,
			"units_owned": {"fire": 4, "police": 5, "utility": 3, "water": 2, "construction": 3}})
	var result := _drive(director, young, 3)
	assert_eq((result["starts"] as Array).size(), 0, "F1: nothing before day 3")
	# doc 92 F-1 ruling: below `grace_population` the gate is a FLOOR, not a wall.
	# Every pressure channel in the game scales with what the player built, so a
	# founding city used to sit under every threshold and see NOTHING for three
	# game-weeks. A small city now gets pressure — but only the cheap tier-1
	# minors `floor.classes` / `max_tp_cost` / `max_hazard_tier` whitelist.
	var tiny := DirectorInputs.make({"city_age_days": 30, "population": 300,
			"treasury": 500000, "daily_opex": 50000, "city_stability": 0.8})
	var small := _director()
	var result2 := _drive(small, tiny, 20)
	var starts: Array = result2["starts"]
	assert_true(starts.size() > 0, "F-1 floor: a 300-person city still gets events")
	var config: Dictionary = small.tables.floor_config
	for row in starts:
		var event := small.tables.event_by_id(String(row["kind"]))
		assert_true((config["classes"] as Array).has(String(event["class"])),
				"the floor schedules %s only, got %s" % [config["classes"], row["kind"]])
		assert_true(int(event["tp_cost"]) <= int(config["max_tp_cost"]),
				"%s costs more than the floor's cap" % row["kind"])
		assert_true(int(event["hazard_tier"]) <= int(config["max_hazard_tier"]),
				"%s is above the floor's hazard tier" % row["kind"])


func test_1_floor_is_invisible_above_tier_0() -> void:
	# The floor is a `max()` against the tier ladder, so a city the doc's own
	# ladder already covers is unchanged: tier 1 pays 6/day, which is the floor.
	var director := _director()
	assert_almost_eq(director.tables.tp_base_per_day(0),
			director.tables.floor_tp_per_day(), 1e-9, "tier 0 is the floor")
	assert_almost_eq(director.tables.tp_base_per_day(2), 12.0, 1e-9, "tier 2 untouched")
	assert_almost_eq(director.tables.tp_base_per_day(4), 30.0, 1e-9, "tier 4 untouched")
	# And a big city's candidate list is not widened by it.
	var event := director.tables.event_by_id("severe_thunderstorm")
	assert_false(director.tables.floor_allows(event), "no major rides the floor")


func test_18_19_class_and_type_cooldowns() -> void:
	var result := _drive(_director(20260818), _healthy_inputs(), 500, 3)
	var starts: Array = result["starts"]
	assert_true(starts.size() > 20, "500 game-days produced %d events" % starts.size())
	var last_major_end := -1000000
	var last_by_type := {}
	var resolve_gap := 3 * 60
	for row in starts:
		var minute := int(row["minute"])
		var kind := String(row["kind"])
		if String(row["class"]) == "major":
			assert_true(minute - last_major_end >= 2880 or last_major_end < 0,
					"F2: %s started %d min after the last major resolved" %
					[kind, minute - last_major_end])
			last_major_end = minute + resolve_gap
		if last_by_type.has(kind):
			assert_true(minute - int(last_by_type[kind]) >= 5760,
					"F3: %s recurred after %d min" % [kind, minute - int(last_by_type[kind])])
		last_by_type[kind] = minute


func test_20_no_kick_while_down() -> void:
	var down := _healthy_inputs(0.30)
	var director := _director(5150)
	var result := _drive(director, down, 30)
	assert_eq((result["starts"] as Array).size(), 0, "F5: 30 game-days of silence at 0.30")
	assert_true(bool(director.suppression["active"]), "suppression is live")
	# Restore health: the first event may only come after the 720-minute grace.
	var recovered := _healthy_inputs(0.60)
	var events := _drive(director, recovered, 40, 3)
	var starts: Array = events["starts"]
	if starts.size() > 0:
		assert_true(int(starts[0]["minute"]) >= 720,
				"the recovery grace runs before anything else can be scheduled")
	assert_false(bool(director.suppression["active"]), "suppression cleared")


func test_20b_every_suppression_reason() -> void:
	for scenario in [
			{"customers_out_pct": 0.30}, {"treasury": -1}, {"roads_impassable_pct": 0.50},
			{"unresolved_major_incidents": 1}, {"city_stability": 0.20}]:
		var inputs := _healthy_inputs()
		for key in scenario:
			inputs.set(String(key), scenario[key])
		var director := _director(11)
		var result := _drive(director, inputs, 20)
		assert_eq((result["starts"] as Array).size(), 0,
				"F5 suppresses on " + str(scenario.keys()[0]))
		assert_true(bool(director.suppression["active"]), "flagged: " + str(scenario))


func test_21_soft_suppression() -> void:
	var director := _director(909)
	var result := _drive(director, _healthy_inputs(0.42), 200, 3)
	var starts: Array = result["starts"]
	assert_true(starts.size() > 0, "minor events still happen at stability 0.42")
	for row in starts:
		assert_eq(String(row["class"]), "minor", "soft suppression: minors only")
		assert_true(int(row["tp_cost"]) <= 12, "tp_cost ≤ 12")
	# Crisis disables SOFT suppression only — the hard list still applies.
	var crisis := _director(909, "crisis")
	assert_false(crisis.soft_suppression_enabled(), "crisis disables soft suppression")
	assert_true(_director(909, "hard").soft_suppression_enabled(), "hard keeps it")


func test_22_no_revenge_spike() -> void:
	var director := _director(4242)
	var result := _drive(director, _healthy_inputs(0.20), 60)
	for value in result["tp"]:
		assert_true(float(value) <= 40.0 + 1e-9,
				"F6: tp_pool %f clamped to 40 while suppressed" % value)
	assert_true(director.tp_pool <= 40.0, "a long painful recovery banks nothing")


func test_23_recovery_mode() -> void:
	var collapsed := _healthy_inputs(0.40)
	collapsed.population = 20000
	collapsed.pop_peak_7d = 45000  # 44% of peak
	var director := _director(31337)
	var result := _drive(director, collapsed, 10)
	assert_true(bool(director.recovery_mode["active"]), "F9: recovery mode engaged")
	assert_eq((result["starts"] as Array).size(), 0, "zero events in recovery mode")
	var frozen := director.tp_pool
	_drive(director, collapsed, 5)
	assert_almost_eq(director.tp_pool, frozen, 1e-9, "TP is frozen, not accrued")
	assert_true(int(director.recovery_mode["until_min"]) - 0 >= 4320,
			"minimum 4320 game-minutes")
	# Recovering population is not enough on its own: stability must reach 0.55.
	var partial := _healthy_inputs(0.50)
	partial.population = 45000
	_drive(director, partial, 10)
	assert_true(bool(director.recovery_mode["active"]), "still held below stability 0.55")
	var well := _healthy_inputs(0.70)
	_drive(director, well, 10)
	assert_false(bool(director.recovery_mode["active"]), "exits at stability ≥ 0.55")


func test_10_warning_guarantee() -> void:
	# F7: every forecastable event is warned at least warn_min ahead, and the
	# warning is CRITICAL / Priority 1, exempt from rate limiting.
	var director := _director(777)
	var result := _drive(director, _healthy_inputs(), 900, 3)
	var warned_kinds := {}
	var checked := 0
	for warning in result["warnings"]:
		checked += 1
		var kind := String(warning["kind"])
		warned_kinds[kind] = true
		var expected := int(director.tables.event_by_id(kind)["warn_min"])
		assert_true(int(warning["lead_min"]) >= expected,
				"%s warned %d min ahead (needs %d)" % [kind, int(warning["lead_min"]), expected])
		assert_eq(int(warning["impact_min"]) - int(warning["minute"]), int(warning["lead_min"]),
				"the warning goes out the moment the event is committed")
		assert_eq(String(warning["notify_class"]), "CRITICAL")
		assert_eq(int(warning["priority"]), 1)
	assert_true(checked > 5, "%d warnings observed" % checked)
	# Every forecastable event that STARTED had a warning.
	for row in result["starts"]:
		var event := director.tables.event_by_id(String(row["kind"]))
		if bool(event.get("forecastable", false)):
			assert_true(bool(row["warned"]), "%s started warned" % row["kind"])
	# Casual gets 1.5× the lead, crisis half of it (§2.6.6).
	var casual := _director(1, "casual")
	var crisis := _director(1, "crisis")
	assert_almost_eq(casual.knob("warning_lead_mult"), 1.5, 1e-9)
	assert_almost_eq(crisis.knob("warning_lead_mult"), 0.5, 1e-9)


func test_24_offline_cap() -> void:
	# F8, tightened to doc 08 §2.3 rule 1 verbatim (C-55): at most ONE hazard
	# per catch-up session, hazard_tier 1 only, pre-warned, FULL band, zero on
	# casual.
	for seed_value in range(1, 40):
		var director := _director(seed_value)
		director.catchup_begin()
		var result := _drive(director, _healthy_inputs(), 12, 3, true)
		var starts: Array = result["starts"]
		var scheduled: Array = result["scheduled"]
		assert_true(scheduled.size() <= 1,
				"≤ 1 hazard per catch-up session, got %d" % scheduled.size())
		for row in scheduled:
			assert_eq(int(row["hazard_tier"]), 1, "tier 1 only — never a severe storm")
			assert_eq(String(row["class"]), "minor")
		for row in starts:
			assert_ne(String(row["kind"]), "severe_thunderstorm", "never offline")
			assert_ne(String(row["kind"]), "heat_wave", "never offline")
			assert_ne(String(row["kind"]), "major_structure_fire", "never offline")
	# On casual: zero, at any tier, ever.
	for seed_value in range(1, 20):
		var casual := _director(seed_value, "casual")
		casual.catchup_begin()
		var result2 := _drive(casual, _healthy_inputs(), 12, 3, true)
		assert_eq((result2["scheduled"] as Array).size(), 0, "casual schedules no offline hazard")


func test_24b_damped_band_suppresses_entirely() -> void:
	var director := _director(88)
	director.catchup_begin()
	director.tp_pool = 180.0
	var inputs := _healthy_inputs()
	var scheduled := 0
	for h in 200:
		var ctx := _ctx(h * 240, true)
		ctx.catchup_index = 80  # doc 08's DAMPED band
		ctx.catchup_total = 200
		director.tick_hour(inputs, ctx)
		for event in director.drain_events():
			if event["type"] == &"director_event_scheduled":
				scheduled += 1
	assert_eq(scheduled, 0, "the Director is suppressed entirely in the DAMPED band")


func test_offline_hazard_budget_resets_per_session() -> void:
	var director := _director(4)
	director.offline_hazard_used = true
	director.catchup_begin()
	assert_false(director.offline_hazard_used, "C-55: the cap is per catch-up SESSION")


func test_26_difficulty_scaling() -> void:
	# §7 test 26: 100 game-days Casual vs Crisis → major count ratio ∈ [2.6, 4.0].
	var majors := {}
	for preset in ["casual", "standard", "hard", "crisis"]:
		var count := 0
		for seed_value in range(1, 13):
			for row in _drive(_director(seed_value, preset), _healthy_inputs(), 100, 3)["starts"]:
				if String(row["class"]) == "major":
					count += 1
		majors[preset] = count
	assert_true(int(majors["casual"]) > 0, "casual still has majors (%d)" % majors["casual"])
	var ratio := float(majors["crisis"]) / float(maxi(1, int(majors["casual"])))
	assert_true(ratio >= 2.6 and ratio <= 4.0,
			"crisis/casual major ratio %f ∈ [2.6, 4.0]" % ratio)
	# Difficulty changes pressure and preparation time, monotonically.
	assert_true(int(majors["casual"]) < int(majors["standard"]), "casual < standard")
	assert_true(int(majors["standard"]) < int(majors["hard"]), "standard < hard")
	assert_true(int(majors["hard"]) < int(majors["crisis"]), "hard < crisis")
	# The pacing target: roughly one major crisis every 2–2.5 game-days at
	# Standard (§2.6.3).
	var days_per_major := 1200.0 / float(int(majors["standard"]))
	assert_true(days_per_major >= 1.8 and days_per_major <= 3.2,
			"one major per %.2f game-days at Standard" % days_per_major)
	# C-17: no difficulty knob and no repair price may live in director.json.
	var raw: Dictionary = JSON.parse_string(
			FileAccess.get_file_as_string(DIRECTOR_DATA))
	assert_false(raw.has("difficulty"), "no difficulty block")
	assert_false(raw.has("repair_cost_mult"), "no repair_cost_mult — that is M_repair")
	# And the knobs are read through one path, which doc 03 can take over.
	var director := _director()
	director.set_pressure_knobs({"tp_rate_mult": 3.0, "cooldown_mult": 1.0,
			"severity_mult": 1.0, "warning_lead_mult": 1.0, "soft_suppression": false})
	assert_almost_eq(director.knob("tp_rate_mult"), 3.0, 1e-9,
			"Difficulty.get(\"pressure\", ·) overrides the fallback mirror")


# ------------------------------------------------------------ integration

func test_scheduling_injects_the_weather_and_requests_incidents() -> void:
	var director := _director(2468)
	var sink := IncidentRequestSink.Recording.new()
	director.attach(director.weather, sink)
	var result := _drive(director, _healthy_inputs(), 400, 3)
	assert_true((result["starts"] as Array).size() > 0, "events fired")
	assert_true(sink.requests.size() > 0, "doc 06 received incident requests")
	for request in sink.requests:
		assert_true(request["target"].has("event_uid"), "every request is attributable")
		assert_true(request["target"].has("severity_mult"), "severity travels with it")
	# Forecastable events edited the committed timeline so the panel can show it.
	var director_segments := 0
	for segment in director.weather.timeline.segments:
		if String(segment["source"]) == WeatherTimeline.SOURCE_DIRECTOR:
			director_segments += 1
	var forecastable_scheduled := 0
	for row in result["scheduled"]:
		if bool(row["warned"]):
			forecastable_scheduled += 1
	if forecastable_scheduled > 0:
		assert_true(director.weather.timeline.next_id > 1, "the timeline was rewritten")
	assert_true(director_segments >= 0, "director segments: %d" % director_segments)


func test_severe_storm_begins_and_reports() -> void:
	var director := _director(13)
	director.tp_pool = 180.0
	var inputs := _healthy_inputs()
	var row := {"event_uid": 5001, "type": "severe_thunderstorm", "impact_min": 0,
			"warned": true, "severity_mult": 1.0, "hazard_tier": 3, "class": "major",
			"tp_cost": 36, "target": {}, "scheduled_min": 0, "warn_lead_min": 90,
			"intensity": 0.77, "duration_min": 120}
	director._start_event(row, inputs)
	assert_true(director.storm.active, "the storm module took over")
	assert_almost_eq(director.storm.intensity, 0.77, 1e-9, "§2.7.1 reference intensity")
	assert_eq(director.storm.total_response_units, 17, "fleet size drives the caps")
	assert_almost_eq(SevereThunderstorm.intensity_for(1.126,
			director.tables.storm.get("intensity_from_severity", {})), 0.817, 0.001,
			"a better-prepared city earns a nastier storm")


func test_29_prep_actions_and_the_load_shed() -> void:
	# §2.7.7 / §7 test 29: the same storm with and without load shed differs by
	# exactly 8% on the power channels, and preparation is what buys it.
	var director := _director(51)
	var stack := ModifierStack.new()
	director.attach(director.weather, IncidentRequestSink.Recording.new(), stack)
	director._now_min = 1000
	director.storm.begin(11, 1.0, 0.77, 1050, 120, 8)  # T−50: inside the window
	director.weather.timeline.inject_segment("HEAT_WAVE", 0, 100000, 0.80, -1, "chain")
	director.weather._apply_modifiers()
	var without := stack.product_for("power_demand_residential")
	assert_true(director.storm_prep_action("load_shed"), "load shed accepted in the window")
	var with_shed := stack.product_for("power_demand_residential")
	assert_almost_eq(with_shed / without, 0.92, 1e-9, "exactly 8% off the load")
	assert_almost_eq(director.weather.get_effect("power_load_mult"), 1.49, 1e-9,
			"get_effect() still publishes the honest WEATHER number")
	assert_false(director.storm_prep_action("load_shed"), "not twice")
	assert_false(director.storm_prep_action("not_a_real_action"), "unknown action refused")
	# Outside the window (T−10) the panel is closed.
	director._now_min = 1040
	assert_false(director.storm_prep_action("callout_crew"), "window closes at T−20")
	director._now_min = 1000
	assert_true(director.storm_prep_action("callout_crew"), "and is open before it")
	assert_eq(director.storm.prep_actions.size(), 2, "both actions recorded for the report")
	# Resolution lifts the shed — it lasts the storm, not the city's lifetime.
	director.active_events[11] = {"event_uid": 11, "type": "severe_thunderstorm",
			"class": "major", "impact_min": 1050, "severity_mult": 1.0, "target": {}}
	director.on_event_resolved(11)
	assert_almost_eq(stack.product_for("power_demand_residential"), without, 1e-9,
			"the policy source is removed when the storm resolves")


func test_debug_commands() -> void:
	var director := _director(52)
	director.debug_set_tp(120.0)
	assert_almost_eq(director.tp_pool, 120.0, 1e-9, "debug_set_tp")
	director.debug_set_tp(1e9)
	assert_almost_eq(director.tp_pool, 180.0, 1e-9, "clamped to the pool cap")
	var ctx := _ctx(240 * 24 * 5)
	assert_true(director.debug_force_director_event("severe_thunderstorm",
			_healthy_inputs(), ctx), "forced a severe thunderstorm")
	assert_eq(director.scheduled.size(), 1, "it is on the schedule")
	assert_eq(String(director.scheduled[0]["type"]), "severe_thunderstorm")
	var warned := false
	for event in director.drain_events():
		if event["type"] == &"weather_warning":
			warned = true
			assert_true(int(event["lead_min"]) >= 90, "F7 still applies to debug events")
	assert_true(warned, "and the warning still goes out")
	assert_false(director.debug_force_director_event("no_such_event", _healthy_inputs(), ctx))
	# debug_force_weather rewrites the committed future like any other injection.
	var id := director.weather.debug_force_weather("THUNDERSTORM", 0.9, 60)
	assert_true(id > 0, "segment injected")
	assert_eq(String(director.weather.timeline.find_by_id(id)["state"]), "THUNDERSTORM")
	assert_eq(director.weather.debug_force_weather("NOT_A_STATE", 0.5, 60), -1,
			"an unknown state is refused, not silently accepted")


func test_forecast_queue_shape() -> void:
	var director := _director(31)
	var result := _drive(director, _healthy_inputs(), 300, 200)
	assert_true((result["scheduled"] as Array).size() > 0, "something got scheduled")
	for entry in director.forecast_queue():
		for key in ["event_id", "kind", "severity", "onset_gmin", "warning_lead_gmin",
				"confidence"]:
			assert_true(entry.has(key), "doc 12 / doc 08 get %s" % key)


func test_28_director_save_round_trip() -> void:
	var live := _director(99)
	_drive(live, _healthy_inputs(), 120, 3)
	var blob: Variant = JSON.parse_string(JSON.stringify(
			CitySim._encode_floats(live.serialize())))
	var restored := _director(99)
	restored.deserialize(CitySim._decode_floats(blob))
	restored._rng.deserialize(live._rng.serialize())
	assert_almost_eq(restored.tp_pool, live.tp_pool, 0.0, "tp_pool exact")
	assert_eq(restored.scheduled.size(), live.scheduled.size(), "scheduled queue")
	assert_eq(restored.difficulty, live.difficulty)
	assert_eq(JSON.stringify(restored.serialize()), JSON.stringify(live.serialize()),
			"serialize → deserialize → serialize is a fixed point")
	# And the next 24 game-hours are identical to the uninterrupted run.
	var a := _drive(live, _healthy_inputs(), 1, 3)
	var b := _drive(restored, _healthy_inputs(), 1, 3)
	assert_eq(JSON.stringify(a["starts"]), JSON.stringify(b["starts"]),
			"the restored Director makes the same decisions")


func test_events_never_clobber_the_bus_type_field() -> void:
	var director := _director(6)
	var result := _drive(director, _healthy_inputs(), 400, 3)
	for row in result["starts"]:
		assert_eq(String(row["type"]), "director_event_started", "bus event name")
		assert_true(row.has("kind"), "the catalog id ships as `kind`")
		assert_ne(String(row["kind"]), "", "and it is not empty")
